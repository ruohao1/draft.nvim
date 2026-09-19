"""Follow-ups through the real controller/isolated ACP fixture; no provider."""
import fcntl
import importlib.util
import json
import os
import socket
from pathlib import Path
import subprocess
import sys
import threading
import time
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("refine_multi_tests", HERE / "nvim_ai_staged_multi.py")
multi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(multi)
single = multi.single


class RefineTest(multi.MultiFileTest):
    def operation(self, parent, choice, path=None):
        command = [sys.executable, "-I", "-B", str(single.CONTROLLER), choice,
                   "--proposal", parent["proposal"], "--id", parent["id"]]
        if path is not None:
            command += ["--path", path]
        result = subprocess.run(command, capture_output=True, timeout=6, check=True)
        return json.loads(result.stdout)

    def refining(self, parent, case="refine", states=None):
        request = self.request(case)
        request["decisions"] = states or ["pending"] * len(parent["files"])
        child = subprocess.Popen([sys.executable, "-I", "-B", str(single.CONTROLLER), "refine",
            "--proposal", parent["proposal"], "--id", parent["id"]],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        def stop():
            if child.poll() is None:
                child.stdin.close()
                try: child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)
            for stream in (child.stdin, child.stdout, child.stderr): stream.close()
        self.addCleanup(stop)
        child.stdin.write(json.dumps(request).encode() + b"\n")
        child.stdin.flush()
        return child

    def refined(self, parent, case="refine", states=None):
        result = self.receive(self.refining(parent, case, states))
        self.assertEqual(result["phase"], "review_ready", result)
        self.assertIs(result["parent_active"], False)
        self.assertNotEqual(result["id"], parent["id"])
        task = Path(result["proposal"]).parent
        self.assertFalse((task / "staging").exists())
        self.assertFalse((task / "agent").exists())
        origin = json.loads((task / "origin.json").read_bytes())
        self.assertEqual(origin["proposal"], parent["proposal"])
        handoff = json.loads((Path(parent["proposal"]).parent / "followup.json").read_bytes())
        self.assertEqual(handoff["candidate"], result["proposal"])
        return result

    def test_refine_seeds_frozen_bytes_preserves_baseline_and_consumes_old_approval(self):
        parent = self.ready_multi()
        revised = self.refined(parent)
        self.assertEqual([p.read_bytes() for p in self.selected], self.original)
        for item in revised["files"]:
            self.assertEqual(item["newText"], "approved edit\nrefined\n")
        self.assertEqual([item["oldText"].encode() for item in revised["files"]], self.original)
        self.assertNotEqual(self.decide(parent)["phase"], "applied")
        self.assertEqual([p.read_bytes() for p in self.selected], self.original)
        self.assertEqual(self.operation(revised, "approve", revised["files"][0]["path"])["phase"], "review_ready")
        self.assertEqual(self.file.read_bytes(), b"approved edit\nrefined\n")
        self.assertEqual(self.second.read_bytes(), self.original[1])

    def test_refine_repeated_rounds_use_latest_proposal_not_the_saved_file(self):
        parent = self.refined(self.ready_multi())
        second = self.refined(parent)
        self.assertEqual(second["files"][0]["newText"], "approved edit\nrefined\nrefined\n")
        self.assertEqual(second["files"][0]["oldText"].encode(), self.original[0])
        self.assertEqual(self.decide(second, "reject")["phase"], "rejected")
        self.assertEqual([p.read_bytes() for p in self.selected], self.original)

    def test_refine_excludes_accepted_rejected_and_unchanged_files_from_agent(self):
        for decision in ("approve", "reject"):
            with self.subTest(decision=decision):
                for path, data in zip(self.selected, self.original): path.write_bytes(data)
                parent = self.ready_multi()
                self.operation(parent, decision, parent["files"][0]["path"])
                before = self.file.stat()
                stable = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_uid", "st_gid", "st_size", "st_mtime_ns", "st_ctime_ns")
                def unchanged_file():
                    actual = self.file.stat()
                    # Read-only snapshot validation may update atime.
                    self.assertEqual([getattr(actual, key) for key in stable], [getattr(before, key) for key in stable])
                state = "accepted" if decision == "approve" else "rejected"
                revised = self.refined(parent, "refine-one", [state, "pending"])
                unchanged_file()
                self.assertEqual(revised["files"][0]["oldText"], revised["files"][0]["newText"])
                self.assertEqual(revised["files"][1]["newText"], "approved edit\nrefined\n")
                self.assertEqual(self.operation(revised, "approve", revised["files"][1]["path"])["phase"], "applied")
                unchanged_file()
        for path, data in zip(self.selected, self.original): path.write_bytes(data)
        parent = self.ready_multi("multi-one")
        revised = self.refined(parent, "refine-one", ["pending", "unchanged"])
        self.assertEqual(revised["files"][1]["oldText"], revised["files"][1]["newText"])

    def test_refine_failed_or_cancelled_agent_keeps_old_proposal_approvable(self):
        parent = self.ready_multi()
        result = self.receive(self.refining(parent, "bad-json"))
        self.assertEqual(result["phase"], "blocked", result)
        self.assertIs(result["parent_active"], True)
        child = self.refining(parent, "stall")
        time.sleep(.2)
        child.stdin.close()
        result = self.receive(child)
        self.assertIs(result["parent_active"], True, result)
        self.assertEqual(self.decide(parent)["phase"], "applied")

    def test_refine_stale_disk_frozen_bytes_and_decision_view_fail_before_handoff(self):
        parent = self.ready_multi()
        self.second.write_bytes(b"external change\n")
        result = self.receive(self.refining(parent))
        self.assertEqual(result["phase"], "blocked", result)
        self.assertEqual(self.second.read_bytes(), b"external change\n")
        self.assertNotIn("proposal", result)
        for path, data in zip(self.selected, self.original): path.write_bytes(data)
        parent = self.ready_multi()
        (Path(parent["proposal"]).parent / "after-1").write_bytes(b"tampered\n")
        self.assertEqual(self.receive(self.refining(parent))["phase"], "blocked")
        parent = self.ready_multi()
        self.operation(parent, "reject", parent["files"][0]["path"])
        self.assertEqual(self.receive(self.refining(parent))["phase"], "blocked")

    def test_refine_revalidates_resolved_context_at_later_approval(self):
        parent = self.ready_multi()
        self.operation(parent, "approve", parent["files"][0]["path"])
        revised = self.refined(parent, "refine-one", ["accepted", "pending"])
        self.file.write_bytes(b"user edits accepted file\n")
        verdict = self.operation(revised, "approve", revised["files"][1]["path"])
        self.assertIn(verdict["phase"], ("conflicted", "blocked"))
        self.assertEqual(self.file.read_bytes(), b"user edits accepted file\n")
        self.assertEqual(self.second.read_bytes(), self.original[1])

    def test_refine_legacy_single_file_gets_a_new_nonreplayable_revision(self):
        parent = self.receive(self.spawn(single.StagedTest.request(self)))
        self.assertEqual(parent["phase"], "review_ready", parent)
        revised = self.refined(parent, "refine-one", ["pending"])
        self.assertEqual(len(revised["files"]), 1)
        self.assertEqual(self.decide(parent)["phase"], "already_decided")
        self.assertEqual(self.operation(revised, "approve", revised["files"][0]["path"])["phase"], "applied")
        self.assertEqual(self.file.read_bytes(), b"approved edit\nrefined\n")

    def controller_call(self, parent, mutation, states=None):
        spec = importlib.util.spec_from_file_location("refine_fault_controller", single.CONTROLLER)
        controller = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(controller)
        helper = controller.helper("nvim-ai-staged-refine")
        read_fd, write_fd = os.pipe()
        self.addCleanup(os.close, write_fd)
        with os.fdopen(read_fd, "rb", buffering=0) as editor, mutation(controller):
            return helper.refine(controller, dict(self.request("refine"), decisions=states or ["pending"] * len(parent["files"])),
                                 editor, parent["proposal"], parent["id"])

    def test_refine_disk_change_after_generation_prevents_handoff(self):
        parent = self.ready_multi()
        def mutation(controller):
            prepare = controller.prepare
            def prepare_then_change(*args, **kwargs):
                result = prepare(*args, **kwargs)
                self.second.write_bytes(b"external change after generation\n")
                return result
            return mock.patch.object(controller, "prepare", side_effect=prepare_then_change)
        result = self.controller_call(parent, mutation)
        self.assertEqual(result["phase"], "blocked", result)
        self.assertNotIn("proposal", result)
        self.assertFalse((Path(parent["proposal"]).parent / "followup.json").exists())
        self.assertEqual(self.file.read_bytes(), self.original[0])
        self.assertEqual(self.second.read_bytes(), b"external change after generation\n")

    def test_refine_interruption_after_retirement_never_claims_parent_still_active(self):
        parent = self.ready_multi()
        def mutation(controller):
            helper = controller.helper
            decisions = helper("nvim-ai-staged-decisions")
            decide = decisions.decide
            def interrupted(*args, **kwargs):
                verdict = decide(*args, **kwargs)
                self.assertEqual(verdict["phase"], "cancelled")
                raise OSError("simulated reply loss after retirement")
            decisions.decide = interrupted
            return mock.patch.object(controller, "helper", side_effect=lambda name:
                decisions if name == "nvim-ai-staged-decisions" else helper(name))
        result = self.controller_call(parent, mutation)
        self.assertEqual(result["phase"], "blocked", result)
        self.assertIs(result["parent_active"], False)
        self.assertNotEqual(self.decide(parent)["phase"], "applied")
        handoff = json.loads((Path(parent["proposal"]).parent / "followup.json").read_bytes())
        self.assertFalse(Path(handoff["candidate"]).exists(), "failed candidate cleaned up")
        self.assertEqual([p.read_bytes() for p in self.selected], self.original)

    def test_refine_concurrent_followup_is_refused_without_replaying_old_approval(self):
        parent = self.ready_multi()
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            listener.settimeout(5)
            first = self.refining(parent, "stall STALL_PORT:" + str(listener.getsockname()[1]))
            connection, _ = listener.accept()
            with connection:
                self.assertEqual(connection.recv(1), b"R", "first refinement holds its lock and agent is running")
        second = self.receive(self.refining(parent))
        self.assertEqual(second["phase"], "blocked", second)
        first.stdin.close()
        self.assertIs(self.receive(first)["parent_active"], True)
        self.assertEqual(self.decide(parent)["phase"], "applied")

    def test_refine_interrupted_handoff_blocks_all_old_approval_protocols(self):
        for selector in ("single", "legacy-batch", "file", "remaining"):
            for torn in (False, True):
                with self.subTest(selector=selector, torn=torn):
                    for path, data in zip(self.selected, self.original): path.write_bytes(data)
                    parent = (self.receive(self.spawn(single.StagedTest.request(self)))
                              if selector == "single" else self.ready_multi())
                    def mutation(controller):
                        helper = controller.helper
                        decisions = helper("nvim-ai-staged-decisions")
                        receipt = decisions.publisher._receipt
                        def interrupted(directory, name, value):
                            if name == b"followup.json" and torn:
                                fd = os.open(name, os.O_CREAT | os.O_EXCL | os.O_WRONLY,
                                             0o600, dir_fd=directory.fd)
                                try: os.write(fd, b'{"schema":')
                                finally: os.close(fd)
                            else:
                                receipt(directory, name, value)
                            if name == b"followup.json":
                                raise OSError("simulated interruption before old approval consumption")
                        decisions.publisher._receipt = interrupted
                        return mock.patch.object(controller, "helper", side_effect=lambda name:
                            decisions if name == "nvim-ai-staged-decisions" else helper(name))
                    result = self.controller_call(parent, mutation)
                    self.assertEqual(result["phase"], "blocked", result)
                    self.assertIs(result["parent_active"], False)
                    self.assertTrue((Path(parent["proposal"]).parent / "followup.json").exists())
                    command = [sys.executable, "-I", "-B", str(single.CONTROLLER), "approve",
                               "--proposal", parent["proposal"], "--id", parent["id"]]
                    if selector == "file": command += ["--path", parent["files"][0]["path"]]
                    if selector == "remaining": command += ["--remaining"]
                    approved = subprocess.run(command, capture_output=True, timeout=6, check=True)
                    verdict = json.loads(approved.stdout)
                    self.assertNotEqual(verdict["phase"], "applied", verdict)
                    self.assertEqual([p.read_bytes() for p in self.selected], self.original,
                                     "An interrupted handoff must make old approvals non-publishable")

    def test_refine_interrupted_handoff_preserves_previously_accepted_files(self):
        parent = self.ready_multi()
        self.operation(parent, "approve", parent["files"][0]["path"])
        expected = [p.read_bytes() for p in self.selected]
        def mutation(controller):
            helper = controller.helper
            decisions = helper("nvim-ai-staged-decisions")
            receipt = decisions.publisher._receipt
            def interrupted(directory, name, value):
                receipt(directory, name, value)
                if name == b"followup.json": raise OSError("simulated interrupted handoff")
            decisions.publisher._receipt = interrupted
            return mock.patch.object(controller, "helper", side_effect=lambda name:
                decisions if name == "nvim-ai-staged-decisions" else helper(name))
        result = self.controller_call(parent, mutation, ["accepted", "pending"])
        self.assertIs(result["parent_active"], False)
        verdict = self.operation(parent, "approve", parent["files"][1]["path"])
        self.assertEqual(verdict["decisions"][0]["state"], "accepted")
        self.assertEqual([p.read_bytes() for p in self.selected], expected)

    def test_refine_handoff_and_legacy_approval_share_the_proposal_lock(self):
        for legacy in (True, False):
            with self.subTest(single_file=legacy):
                parent = (self.receive(self.spawn(single.StagedTest.request(self)))
                          if legacy else self.ready_multi())
                spec = importlib.util.spec_from_file_location("locked_controller", single.CONTROLLER)
                controller = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(controller)
                task = Path(parent["proposal"]).parent
                descriptor = os.open(task, controller.review.DIRECTORY_FLAGS)
                flock, entered, verdicts = fcntl.flock, threading.Event(), []
                def locking(fd, operation):
                    if operation == fcntl.LOCK_EX:
                        entered.set()
                    return flock(fd, operation)
                def approve():
                    try:
                        verdicts.append(controller.decide(parent["proposal"], parent["id"], "approve"))
                    except (OSError, ValueError, controller.Refused):
                        verdicts.append({"phase": "blocked"})
                flock(descriptor, fcntl.LOCK_EX)
                worker = threading.Thread(target=approve)
                try:
                    with mock.patch.object(controller.fcntl, "flock", side_effect=locking):
                        worker.start()
                        try:
                            self.assertTrue(entered.wait(3), "approval must reach the shared proposal lock")
                            self.assertFalse((task / "consumed.json").exists())
                            self.assertEqual([p.read_bytes() for p in self.selected], self.original)
                            # Simulate the refiner's durable handoff while it owns the lock.
                            (task / "followup.json").write_bytes(b'{"schema":')
                        finally:
                            flock(descriptor, fcntl.LOCK_UN)
                            worker.join(3)
                finally:
                    os.close(descriptor)
                self.assertFalse(worker.is_alive(), "approval finishes once the handoff releases the lock")
                self.assertEqual(verdicts, [{"phase": "blocked"}])
                self.assertEqual([p.read_bytes() for p in self.selected], self.original)


def load_tests(loader, tests, pattern):
    return unittest.TestSuite(RefineTest(name) for name in dir(RefineTest) if name.startswith("test_refine_"))


if __name__ == "__main__": unittest.main()
