"""Production controller exercised through separate processes and private pipes."""
import json
import hashlib
import ctypes
import os
from pathlib import Path
import select
import shutil
import signal
import socketserver
import subprocess
import sys
import tempfile
import time
import threading
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/nvim-ai-conversation.py"


class ControllerTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="draft-controller-test-", dir="/tmp")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.config = self.root / "config.json"
        self.config.write_text(json.dumps({"opencode": "/missing/unused-agent", "bwrap": "/usr/bin/bwrap",
                                           "model": "fixture/model"}))
        self.config.chmod(0o600)

    def close_frame(self):
        return {"version": 1, "serial": 1, "command": {
            "kind": "close", "conversation_id": "a" * 32, "owner_generation": 1,
            "turn_id": 0, "worker_generation": 0, "root": str(self.root),
            "selection": ["example.txt"], "model": "fixture/model"}}

    def invoke(self, raw):
        return subprocess.run([sys.executable, "-I", "-B", str(SCRIPT), "--config", str(self.config)],
                              input=raw, capture_output=True, timeout=3,
                              env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"}, umask=0o077)

    def test_close_before_a_turn_needs_no_agent_or_store(self):
        result = self.invoke(json.dumps(self.close_frame()).encode() + b'\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual((value["version"], value["serial"]), (1, 1))
        self.assertEqual(value["event"], {"kind": "closed", "conversation_id": "a" * 32,
            "owner_generation": 1, "turn_id": 0, "worker_generation": 0, "sequence": 1,
            "stopped": True, "cleaned": True, "tokens_retired": True})
        self.assertEqual(list(self.root.iterdir()), [self.config])
        self.assertEqual(result.stderr, b'')

    def test_malformed_or_partial_editor_input_never_asserts_cleanup(self):
        for raw in (b'{bad}\n', b'{"version":1', b'[]\n'):
            with self.subTest(raw=raw):
                result = self.invoke(raw)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b'')
                self.assertNotIn(b'{bad}', result.stderr)

    def test_untrusted_launch_file_is_refused_even_for_passive_close(self):
        self.config.chmod(0o644)
        result = self.invoke(json.dumps(self.close_frame()).encode() + b'\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b'')

    def test_blocked_editor_output_exits_within_its_absolute_deadline(self):
        reader, writer = os.pipe()
        try:
            os.set_blocking(writer, False)
            try:
                while True:
                    os.write(writer, b'x' * 4096)
            except BlockingIOError:
                pass
            started = time.monotonic()
            process = subprocess.Popen(
                [sys.executable, "-I", "-B", str(SCRIPT), "--config", str(self.config)],
                stdin=subprocess.PIPE, stdout=writer, stderr=subprocess.PIPE,
                env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"}, umask=0o077)
            try:
                _, error = process.communicate(json.dumps(self.close_frame()).encode() + b'\n', timeout=7)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
            self.assertNotEqual(process.returncode, 0)
            self.assertGreaterEqual(time.monotonic() - started, 5)
            self.assertLess(time.monotonic() - started, 7)
            self.assertIn(b'explicit recovery required', error)
        finally:
            os.close(reader)
            os.close(writer)


class EngineTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.libc = ctypes.CDLL(None, use_errno=True)
        cls.previous_subreaper = ctypes.c_int()
        if (cls.libc.prctl(37, ctypes.byref(cls.previous_subreaper), 0, 0, 0) != 0
                or cls.libc.prctl(36, 1, 0, 0, 0) != 0):
            raise OSError(ctypes.get_errno(), "Cannot own test orphan reaping")

    @classmethod
    def tearDownClass(cls):
        if cls.libc.prctl(36, cls.previous_subreaper.value, 0, 0, 0) != 0:
            raise OSError(ctypes.get_errno(), "Cannot restore subreaper state")

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="draft-engine-test-", dir="/tmp")
        self.addCleanup(self.directory.cleanup)
        self.scratch = Path(self.directory.name)
        self.root = self.scratch / "project"
        self.root.mkdir(mode=0o700)
        self.source = self.root / "example.txt"
        self.source.write_bytes(b"original text\n")
        self.source.chmod(0o644)
        self.peer = self.scratch / "opencode"
        shutil.copyfile(ROOT / "tests/fixtures/ai/conversation_acp.py", self.peer)
        self.peer.chmod(0o700)
        self.audit, self.events, self.buffer = [], [], bytearray()
        audit = self.audit
        self.gate = threading.Event()
        gate = self.gate

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                value = json.loads(self.rfile.readline())
                audit.append(value)
                if value.get("ready") in ("held-answer", "slow-exit"):
                    gate.wait(timeout=15)
                    self.wfile.write(b'continue\n')

        self.server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.config = self.scratch / "config.json"
        self.serial = 0
        self.turn = 0

    def stop_server(self):
        self.gate.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)

    def spawn(self, case="answer"):
        self.config.write_text(json.dumps({"opencode": str(self.peer),
            "bwrap": os.path.realpath(shutil.which("bwrap")), "model": "fixture/model",
            "provider": {"fixture": {"options": {"testCase": case, "auditPort": self.server.server_address[1]}}}}))
        self.config.chmod(0o600)
        self.child = subprocess.Popen([sys.executable, "-I", "-B", str(SCRIPT), "--config", str(self.config)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "NVIM_STAGED_SENTINEL": "private"}, umask=0o077)
        self.addCleanup(self.stop)

    def stop(self):
        self.gate.set()
        if self.child.poll() is None:
            self.child.stdin.close()
            try:
                self.child.wait(timeout=12)
            except subprocess.TimeoutExpired:
                self.child.kill()
                self.child.wait(timeout=3)
        for stream in (self.child.stdin, self.child.stdout, self.child.stderr):
            stream.close()

    def send(self, kind, **extra):
        self.serial += 1
        if kind in ("start", "revise"):
            self.turn += 1
            extra.setdefault("message", "Answer without editing.")
            extra.setdefault("sources", [{"path": "example.txt",
                "snapshot_sha256": hashlib.sha256(self.source.read_bytes()).hexdigest()}])
        command = dict(kind=kind, conversation_id="a" * 32, owner_generation=1,
            turn_id=self.turn, worker_generation=self.turn, root=str(self.root),
            selection=["example.txt"], model="fixture/model", **extra)
        self.child.stdin.write(json.dumps({"version": 1, "serial": self.serial, "command": command}).encode() + b'\n')
        self.child.stdin.flush()

    def receive(self, kind, seconds=12):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            while b'\n' in self.buffer:
                raw, _, remaining = self.buffer.partition(b'\n')
                self.buffer = bytearray(remaining)
                event = json.loads(raw)["event"]
                self.events.append(event)
                if event["kind"] == kind:
                    return event
            if select.select([self.child.stdout], [], [], min(.1, max(0, deadline - time.monotonic())))[0]:
                data = os.read(self.child.stdout.fileno(), 65536)
                if not data:
                    self.child.wait(timeout=3)
                    self.fail("Controller closed before " + kind + ": " + self.child.stderr.read().decode())
                self.buffer.extend(data)
        self.fail("Controller timed out before " + kind)

    def test_answer_finishes_without_proposal(self):
        self.spawn()
        self.send("start")
        settled = self.receive("settled")
        self.assertEqual(settled["outcome"], "answer")
        self.assertTrue(settled["stopped"] and settled["graceful"] and settled["store_valid"])
        self.assertNotIn("proposal", settled)
        self.assertNotIn("review_ref", settled)
        self.assertEqual([event["text"] for event in self.events if event["kind"] == "text"], ["A bounded answer."])
        self.assertEqual([event["status"] for event in self.events if event["kind"] == "progress"], ["completed"])
        self.assertEqual([item["method"] for item in self.audit if "method" in item], ["initialize", "session/new",
            "session/set_config_option", "session/set_config_option", "session/prompt"])
        self.assertIn({"exiting": True}, self.audit)
        self.assertEqual(Path(f"/proc/{self.child.pid}/task/{self.child.pid}/children").read_text().strip(), "")
        self.assertEqual(self.source.read_bytes(), b"original text\n")
        self.send("close")
        self.assertTrue(self.receive("closed")["cleaned"])
        self.child.wait(timeout=3)
        self.assertEqual(self.child.returncode, 0)

    def test_handshake_and_option_refusals_never_submit_a_prompt(self):
        for case in ("wrong-version", "missing-resume", "missing-model", "missing-mode", "wrong-confirmation"):
            with self.subTest(case=case):
                self.serial = self.turn = 0
                self.audit.clear()
                self.spawn(case)
                self.send("start")
                event = self.receive("settled")
                self.assertEqual(event["outcome"], "failed")
                self.assertFalse(any(item.get("method") == "session/prompt" for item in self.audit))
                self.stop()

    def test_foreign_session_updates_and_unsuccessful_stop_never_freeze(self):
        for case in ("wrong-session", "bad-stop"):
            with self.subTest(case=case):
                self.serial = self.turn = 0
                self.audit.clear()
                self.spawn(case)
                self.send("start")
                event = self.receive("settled")
                self.assertEqual(event["outcome"], "failed")
                self.assertNotIn("proposal", event)
                self.stop()

    def wait_ready(self, case):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if {"ready": case} in self.audit:
                return
            threading.Event().wait(.01)
        self.fail("ACP readiness marker not received: " + case)

    def test_normal_and_flooded_generation_cancel_cleanly(self):
        for case in ("cancel", "flood-cancel"):
            with self.subTest(case=case):
                self.serial = self.turn = 0
                self.audit.clear()
                self.spawn(case)
                self.send("start")
                self.receive("submitted")
                self.wait_ready(case)
                started = time.monotonic()
                self.send("cancel")
                event = self.receive("cancelled")
                self.assertTrue(event["cancel_confirmed"] and event["store_valid"] and event["tokens_retired"])
                self.assertLess(time.monotonic() - started, 2)
                self.assertEqual(self.source.read_bytes(), b"original text\n")
                self.stop()

    def test_startup_and_backpressured_prompt_cancel_require_recovery(self):
        for case in ("startup-cancel", "blocked-prompt"):
            with self.subTest(case=case):
                self.serial = self.turn = 0
                self.audit.clear()
                self.spawn(case)
                self.send("start", message="é" * 16000)
                self.wait_ready(case)
                started = time.monotonic()
                self.send("cancel")
                event = self.receive("cancelled")
                self.assertTrue(event["stopped"] and event["tokens_retired"])
                self.assertFalse(event["store_valid"])
                self.assertFalse(event.get("cancel_confirmed", False))
                self.assertLess(time.monotonic() - started, 4.2)
                self.assertFalse(any(item.get("method") == "session/prompt" for item in self.audit))
                self.stop()

    def test_two_explicit_turns_resume_one_session_with_fresh_workers(self):
        self.spawn("held-answer")
        workers, tasks = [], []
        for _ in range(2):
            self.audit[:] = [item for item in self.audit if "ready" not in item]
            self.gate.clear()
            self.send("start")
            self.receive("submitted")
            self.wait_ready("held-answer")
            pid = int(Path(f"/proc/{self.child.pid}/task/{self.child.pid}/children").read_text().strip())
            workers.append(pid)
            args = Path(f"/proc/{pid}/cmdline").read_bytes().split(b'\0')
            tasks.append(next(Path(os.fsdecode(arg)).parent for arg in args if arg.endswith(b'/staging')))
            self.gate.set()
            self.assertEqual(self.receive("settled")["outcome"], "answer")
            self.assertFalse(Path(f"/proc/{pid}").exists())
            self.assertFalse(tasks[-1].exists())
        self.assertNotEqual(*workers)
        self.assertNotEqual(*tasks)
        methods = [item["method"] for item in self.audit if "method" in item]
        self.assertEqual(methods.count("session/new"), 1)
        self.assertEqual(methods.count("session/resume"), 1)
        self.assertEqual(methods.count("session/prompt"), 2)
        resumes = [item["params"]["sessionId"] for item in self.audit if item.get("method") == "session/resume"]
        self.assertEqual(resumes, ["fixture-session"])
        profiles = [item for item in self.audit if "profile_inode" in item]
        self.assertNotEqual(profiles[0]["listener_key_hash"], profiles[1]["listener_key_hash"])

    def test_clean_cancellation_can_resume_but_resume_failure_never_falls_back(self):
        for case in ("cancel", "resume-fails"):
            with self.subTest(case=case):
                self.serial = self.turn = 0
                self.audit.clear()
                self.spawn(case)
                self.send("start")
                if case == "cancel":
                    self.receive("submitted")
                    self.wait_ready(case)
                    self.send("cancel")
                    self.assertTrue(self.receive("cancelled")["store_valid"])
                else:
                    self.assertEqual(self.receive("settled")["outcome"], "answer")
                self.send("start")
                if case == "cancel":
                    self.receive("submitted")
                    self.send("cancel")
                    self.assertTrue(self.receive("cancelled")["store_valid"])
                else:
                    self.assertEqual(self.receive("settled")["outcome"], "failed")
                methods = [item.get("method") for item in self.audit]
                self.assertEqual(methods.count("session/new"), 1)
                self.assertEqual(methods.count("session/resume"), 1)
                self.assertEqual(methods.count("session/prompt"), 2 if case == "cancel" else 1)
                self.stop()

    def worker_paths(self):
        pid = int(Path(f"/proc/{self.child.pid}/task/{self.child.pid}/children").read_text().strip())
        args = Path(f"/proc/{pid}/cmdline").read_bytes().split(b'\0')
        task = next(Path(os.fsdecode(arg)).parent for arg in args if arg.endswith(b'/staging'))
        store = next(Path(os.fsdecode(arg)).parent for arg in args if arg.endswith(b'/backend-store'))
        return pid, task, store

    def test_changed_missing_and_oversized_idle_stores_never_launch_again(self):
        for damage in ("changed", "missing", "oversized"):
            with self.subTest(damage=damage):
                self.serial = self.turn = 0
                self.audit.clear()
                self.gate.clear()
                self.spawn("held-answer")
                self.send("start")
                self.wait_ready("held-answer")
                _, _, store = self.worker_paths()
                self.gate.set()
                self.assertEqual(self.receive("settled")["outcome"], "answer")
                db = store / "backend-store/opencode.db"
                if damage == "missing":
                    db.unlink()
                elif damage == "changed":
                    db.write_bytes(b"changed private artifact")
                else:
                    with db.open("r+b") as stream:
                        stream.truncate(65 * 1024 * 1024)
                self.send("start")
                self.assertEqual(self.receive("settled")["outcome"], "failed")
                self.assertEqual([item.get("method") for item in self.audit].count("session/prompt"), 1)
                self.assertEqual([item.get("method") for item in self.audit].count("initialize"), 1)
                self.stop()
                self.assertFalse(store.exists())

    def test_editor_eof_stops_workers_before_discarding_owned_state(self):
        for case in ("startup-cancel", "cancel", "slow-exit", "held-answer"):
            with self.subTest(case=case):
                self.serial = self.turn = 0
                self.audit.clear()
                self.gate.clear()
                self.spawn(case)
                self.send("start")
                self.wait_ready(case)
                pid, task, store = self.worker_paths()
                worker_fd = os.pidfd_open(pid)
                try:
                    self.child.stdin.close()
                    self.gate.set()
                    self.child.wait(timeout=10)
                    self.assertTrue(select.select([worker_fd], [], [], 0)[0])
                    self.assertFalse(task.exists())
                    self.assertFalse(store.exists())
                    self.assertEqual(self.source.read_bytes(), b"original text\n")
                finally:
                    os.close(worker_fd)
                self.stop()

    def test_editor_eof_when_idle_discards_store_without_another_worker(self):
        self.spawn("held-answer")
        self.send("start")
        self.wait_ready("held-answer")
        _, task, store = self.worker_paths()
        self.gate.set()
        self.receive("settled")
        self.child.stdin.close()
        self.child.wait(timeout=3)
        self.assertFalse(task.exists() or store.exists())
        self.assertEqual([item.get("method") for item in self.audit].count("initialize"), 1)

    def test_blocked_editor_output_also_reaps_a_live_worker(self):
        self.spawn("output-blocked")
        self.send("start")
        self.wait_ready("output-blocked")
        pid, task, store = self.worker_paths()
        worker_fd = os.pidfd_open(pid)
        try:
            self.child.wait(timeout=9)
            self.assertNotEqual(self.child.returncode, 0)
            self.assertTrue(select.select([worker_fd], [], [], 0)[0])
            self.assertFalse(task.exists() or store.exists())
        finally:
            os.close(worker_fd)

    def test_controller_death_reaps_descendant_held_pipe_and_retains_unadopted_evidence(self):
        self.spawn("descendant")
        self.send("start")
        self.receive("submitted")
        self.wait_ready("descendant")
        pid, task, store = self.worker_paths()
        worker_fd = os.pidfd_open(pid)
        try:
            self.child.kill()
            self.child.wait(timeout=3)
            self.assertTrue(select.select([worker_fd], [], [], 5)[0], "Owned namespace survived controller death")
            self.assertEqual(os.waitpid(pid, 0)[0], pid)
            # Test-only ownership, matching the lifetime suite: this process has
            # no other live subprocesses, only this controller's adopted tree.
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                try:
                    adopted, _ = os.waitpid(-1, os.WNOHANG)
                except ChildProcessError:
                    break
                if not adopted:
                    time.sleep(.01)
            else:
                self.fail("Owned descendant was not reaped")
            self.assertTrue(task.exists() and store.exists())
            self.assertEqual(self.source.read_bytes(), b"original text\n")
            shutil.rmtree(task)
            shutil.rmtree(store)
        finally:
            os.close(worker_fd)


if __name__ == "__main__":
    unittest.main()
