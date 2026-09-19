"""Per-file decisions through the controller and durable writer interface."""
import importlib.util
import json
import multiprocessing
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), SCRIPTS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


controller = load("nvim-ai-staged")
decisions = load("nvim-ai-staged-decisions")


class DecisionTest(unittest.TestCase):
    def setUp(self):
        project = tempfile.TemporaryDirectory(prefix="nvim-ai-decision-test-", dir="/tmp")
        task = tempfile.TemporaryDirectory(prefix="nvim-ai-staged-decision-test-", dir="/tmp")
        self.addCleanup(project.cleanup)
        self.addCleanup(task.cleanup)
        self.root, self.task = Path(project.name), Path(task.name)
        self.paths = ["src/first.txt", "lib/second.txt", "context.txt"]
        self.before = [b"first original\n", b"second original\n", b"unchanged\n"]
        self.after = [b"first approved\n", b"second approved\n", self.before[2]]
        self.files, entries = [self.root / path for path in self.paths], []
        for index, file in enumerate(self.files):
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(self.before[index])
            file.chmod(0o644)
            data, mode, identity = controller.snapshot(str(self.root), self.paths[index])
            entries.append({"path": self.paths[index], "identity": identity,
                            "expected": controller.fingerprint(data, mode),
                            "desired": controller.fingerprint(self.after[index], mode)})
            self.private("before-" + str(index), self.before[index])
            self.private("after-" + str(index), self.after[index])
        self.proposal = {"schema": 2, "id": "a" * 32, "root": str(self.root), "files": entries}
        self.private("proposal.json", json.dumps(self.proposal).encode())

    def private(self, name, data):
        file = self.task / name
        file.write_bytes(data)
        file.chmod(0o600)

    def decide(self, choice="approve", index=0, remaining=False):
        return decisions.decide(self.task, self.proposal, choice,
                                self.paths[index] if index is not None else None, remaining, controller.snapshot)

    def assert_states(self, result, values):
        self.assertEqual(result["decisions"], [{"path": path, "state": state} for path, state in zip(self.paths, values)], result)

    def test_current_accept_then_second_uses_accepted_baseline(self):
        result = self.decide()
        self.assertEqual(result["phase"], "review_ready", result)
        self.assert_states(result, ["accepted", "pending", "unchanged"])
        self.assertEqual([file.read_bytes() for file in self.files], [self.after[0], *self.before[1:]])
        result = self.decide(index=1)
        self.assertEqual(result["phase"], "applied", result)
        self.assert_states(result, ["accepted", "accepted", "unchanged"])
        self.assertEqual(result["applied"], self.paths[:2])
        self.assertEqual([file.read_bytes() for file in self.files], self.after)

    def test_reject_then_accept_leaves_rejected_original(self):
        self.assert_states(self.decide("reject"), ["rejected", "pending", "unchanged"])
        result = self.decide(index=1)
        self.assertEqual(result["phase"], "applied", result)
        self.assertEqual(result["applied"], self.paths[1:2])
        self.assertEqual(result["rejected"], self.paths[:1])
        self.assertEqual(self.files[0].read_bytes(), self.before[0])

    def test_accept_then_reject_and_cancel_preserve_accepted_files(self):
        self.decide()
        result = self.decide("reject", index=1)
        self.assertEqual(result["phase"], "applied", result)
        self.assert_states(result, ["accepted", "rejected", "unchanged"])
        self.assertTrue((self.task / "decision-0-applied-0.json").is_file())
        self.assertEqual(self.decide("cancel", index=None)["phase"], "applied")

    def test_read_receipt_derives_cumulative_outcomes_without_replaying_a_write(self):
        self.decide()
        expected = self.decide("reject", index=1)
        names = set(self.task.iterdir())
        receipt = decisions.read_receipt(str(self.task / "proposal.json"), self.proposal["id"])
        self.assertEqual(receipt["sequence"], 2)
        self.assertEqual(receipt["phase"], "applied")
        self.assertEqual(receipt["decisions"], expected["decisions"])
        self.assertEqual(receipt["cleanup_pending"], [])
        self.assertEqual(set(self.task.iterdir()), names)
        self.assertEqual(self.files[0].read_bytes(), self.after[0])
        self.assertEqual(self.files[1].read_bytes(), self.before[1])

    def test_read_review_checks_frozen_material_and_token_under_the_same_lock(self):
        frozen = decisions.read_review(str(self.task / "proposal.json"), self.proposal["id"])
        self.assertEqual(frozen["files"][0]["newText"], self.after[0].decode())
        self.assertEqual(frozen["root"], str(self.root))
        with self.assertRaises(ValueError):
            decisions.read_review(str(self.task / "proposal.json"), "wrong")
        self.private("after-1", b"tampered proposal\n")
        with self.assertRaises(ValueError):
            decisions.read_review(str(self.task / "proposal.json"), self.proposal["id"])

    def test_receipt_reader_refuses_torn_or_contradictory_journals(self):
        self.decide()
        self.private("decision-1.json", b'{"schema":')
        with self.assertRaises(ValueError):
            decisions.read_receipt(str(self.task / "proposal.json"), self.proposal["id"])

    def test_cancel_pending_keeps_accepted_and_evidence(self):
        self.decide()
        result = controller.decide(str(self.task / "proposal.json"), self.proposal["id"], "cancel")
        self.assertEqual(result["phase"], "cancelled", result)
        self.assert_states(result, ["accepted", "cancelled", "unchanged"])
        self.assertEqual(self.files[0].read_bytes(), self.after[0])
        self.assertTrue((self.task / "decision-0-applied-0.json").is_file())

    def test_replay_and_invalid_or_unchanged_paths_preserve_pending(self):
        self.decide()
        for choice, path in (("approve", self.paths[0]), ("reject", self.paths[0]),
                             ("approve", self.paths[2]), ("approve", "../escape"),
                             ("approve", "missing"), ("approve", str(self.files[1]))):
            result = decisions.decide(self.task, self.proposal, choice, path, False, controller.snapshot)
            self.assertEqual(result["phase"], "review_ready", result)
            self.assert_states(result, ["accepted", "pending", "unchanged"])
        self.assertEqual(self.files[1].read_bytes(), self.before[1])
        self.assertFalse((self.task / "decision-1.json").exists())

    def test_remaining_accepts_only_pending(self):
        self.decide("reject")
        result = self.decide(index=None, remaining=True)
        self.assert_states(result, ["rejected", "accepted", "unchanged"])
        self.assertEqual(result["applied"], self.paths[1:2])

    def test_remaining_approve_prepares_all_and_retains_individual_baselines(self):
        result = self.decide(index=None, remaining=True)
        self.assertEqual(result["phase"], "applied", result)
        self.assertEqual(result["applied"], self.paths[:2])
        self.assertEqual([file.read_bytes() for file in self.files], self.after)

    def test_remaining_reject_never_writes(self):
        result = self.decide("reject", index=None, remaining=True)
        self.assertEqual(result["phase"], "rejected", result)
        self.assert_states(result, ["rejected", "rejected", "unchanged"])
        self.assertEqual([file.read_bytes() for file in self.files], self.before)

    def test_external_change_to_accepted_file_blocks_remaining(self):
        self.decide()
        self.files[0].write_bytes(b"external change\n")
        result = self.decide(index=1)
        self.assertEqual(result["phase"], "conflicted", result)
        self.assert_states(result, ["accepted", "blocked", "unchanged"])
        self.assertEqual(self.files[1].read_bytes(), self.before[1])
        self.assertEqual(self.decide(index=1)["applied"], self.paths[:1])

    def test_rejected_context_still_checked(self):
        self.decide("reject")
        self.files[0].write_bytes(b"external change\n")
        result = self.decide(index=1)
        self.assert_states(result, ["rejected", "blocked", "unchanged"])
        self.assertEqual(self.files[1].read_bytes(), self.before[1])

    def test_all_frozen_bytes_checked_before_current_publication(self):
        self.private("after-1", b"tampered proposal\n")
        result = self.decide()
        self.assertEqual(result["phase"], "blocked", result)
        self.assertEqual([file.read_bytes() for file in self.files], self.before)

    def test_torn_later_journal_preserves_prior_accepted_outcome(self):
        self.decide()
        self.private("decision-1.json", b'{"schema":')
        result = self.decide(index=1)
        self.assertEqual(result["applied"], self.paths[:1], result)
        self.assertNotIn(self.paths[0], result["not_attempted"])
        self.assertEqual(self.files[1].read_bytes(), self.before[1])

    def test_torn_result_retains_individually_confirmed_acceptance(self):
        self.decide()
        self.private("decision-0-result.json", b'{')
        result = self.decide(index=1)
        self.assertEqual(result["applied"], self.paths[:1], result)
        self.assertEqual(self.files[1].read_bytes(), self.before[1])

    def test_interrupted_after_consumption_never_restarts(self):
        self.private("consumed.json", json.dumps({"choice": "incremental", "id": self.proposal["id"]}).encode())
        result = self.decide()
        self.assertEqual(result["phase"], "uncertain", result)
        self.assertEqual([file.read_bytes() for file in self.files], self.before)

    def test_crash_after_first_applied_receipt_prevents_remaining(self):
        def child():
            original = decisions.publisher._receipt
            def stop(parent, name, value):
                original(parent, name, value)
                if name == b"decision-0-applied-0.json":
                    os._exit(73)
            with patch.object(decisions.publisher, "_receipt", side_effect=stop):
                self.decide(index=None, remaining=True)
        process = multiprocessing.get_context("fork").Process(target=child)
        process.start()
        process.join(10)
        self.assertEqual(process.exitcode, 73)
        result = self.decide(index=1)
        self.assertEqual(result["phase"], "uncertain", result)
        self.assertEqual(result["applied"], self.paths[:1])
        self.assertEqual(result["cleanup_pending"], self.paths[1:2])
        self.assertEqual(self.files[1].read_bytes(), self.before[1])

    def test_second_rename_failure_reports_first_accepted_and_stops(self):
        rename = os.rename
        def fail(source, destination, **kwargs):
            if destination == b"second.txt":
                raise OSError("injected rename failure")
            return rename(source, destination, **kwargs)
        with patch.object(decisions.publisher.os, "rename", side_effect=fail):
            result = self.decide(index=None, remaining=True)
        self.assertEqual(result["phase"], "uncertain", result)
        self.assert_states(result, ["accepted", "uncertain", "unchanged"])
        self.assertEqual(self.decide(index=1)["applied"], self.paths[:1])
        self.assertEqual(self.files[1].read_bytes(), self.before[1])

    def test_reader_preserves_uncertainty_confirmed_prefix_and_cleanup_candidates(self):
        rename = os.rename
        def fail(source, destination, **kwargs):
            if destination == b"second.txt":
                raise OSError("injected rename failure")
            return rename(source, destination, **kwargs)
        with patch.object(decisions.publisher.os, "rename", side_effect=fail), patch.object(
                decisions.publisher, "_cleanup", return_value=self.paths[1:2]):
            expected = self.decide(index=None, remaining=True)
        receipt = decisions.read_receipt(str(self.task / "proposal.json"), self.proposal["id"])
        self.assertEqual(receipt["phase"], "uncertain")
        self.assertEqual(receipt["decisions"], expected["decisions"])
        self.assertEqual(receipt["cleanup_pending"], self.paths[1:2])
        self.assertEqual(receipt["decisions"][0]["state"], "accepted")

    def test_final_receipt_failure_halts_remaining_preserving_acceptance(self):
        receipt = decisions.publisher._receipt
        def fail(parent, name, value):
            if name == b"decision-0-result.json":
                raise OSError("injected result failure")
            return receipt(parent, name, value)
        with patch.object(decisions.publisher, "_receipt", side_effect=fail):
            result = self.decide()
        self.assertEqual(result["phase"], "uncertain", result)
        self.assertEqual(result["applied"], self.paths[:1])
        self.assertEqual(self.decide(index=1)["phase"], "uncertain")
        self.assertEqual(self.files[1].read_bytes(), self.before[1])

    def test_concurrent_opposing_choices_are_serialized(self):
        command = ["python3", "-I", "-B", str(SCRIPTS / "nvim-ai-staged.py")]
        args = ["--proposal", str(self.task / "proposal.json"), "--id", self.proposal["id"], "--path", self.paths[0]]
        first = subprocess.Popen(command + ["approve"] + args, stdout=subprocess.PIPE, text=True)
        second = subprocess.Popen(command + ["reject"] + args, stdout=subprocess.PIPE, text=True)
        values = [json.loads(process.communicate(timeout=10)[0]) for process in (first, second)]
        self.assertEqual(values[0]["decisions"], values[1]["decisions"], values)
        self.assertEqual(values[0]["phase"], "review_ready", values)
        self.assertFalse((self.task / "decision-1.json").exists())

    def test_missing_marker_cannot_cross_back_to_legacy_batch(self):
        self.decide("reject")
        (self.task / "consumed.json").unlink()
        for choice in ("approve", "reject", "cancel"):
            result = controller.decide(str(self.task / "proposal.json"), self.proposal["id"], choice)
            self.assertEqual(result["phase"], "uncertain", result)
            self.assert_states(result, ["rejected", "blocked", "unchanged"])
        self.assertEqual([file.read_bytes() for file in self.files], self.before)

    def test_torn_marker_retains_accepted_evidence_for_all_controller_decisions(self):
        self.decide()
        self.private("consumed.json", b'{')
        for choice, path in (("approve", None), ("reject", None), ("cancel", None),
                             ("approve", self.paths[1])):
            result = controller.decide(str(self.task / "proposal.json"), self.proposal["id"], choice, path)
            self.assertEqual(result["phase"], "uncertain", result)
            self.assertEqual(result["applied"], self.paths[:1])
            self.assertNotIn(self.paths[0], result["not_attempted"])
        self.assertEqual(self.files[1].read_bytes(), self.before[1])

    def test_controller_proposal_lock_close_error_preserves_applied_verdict(self):
        close = controller.review._Parent.close
        def fail(parent):
            is_task = parent.root == str(self.task)
            close(parent)
            if is_task:
                raise OSError("injected lock teardown failure")
        with patch.object(controller.review._Parent, "close", fail):
            result = controller.decide(str(self.task / "proposal.json"), self.proposal["id"], "approve", self.paths[0])
        self.assertEqual(result["phase"], "review_ready", result)
        self.assertEqual(result["applied"], self.paths[:1])

    def test_legacy_approval_crossover_never_claims_not_attempted(self):
        controller.decide(str(self.task / "proposal.json"), self.proposal["id"], "approve")
        result = self.decide()
        self.assertEqual(result["phase"], "already_decided", result)
        self.assertEqual(result["not_attempted"], [])
        self.assertEqual(result["uncertain"], self.paths[:2])

    def test_torn_attempt_receipt_is_uncertain_not_blocked(self):
        self.private("consumed.json", json.dumps({"choice": "incremental", "id": self.proposal["id"]}).encode())
        self.private("decision-0.json", json.dumps({"schema": 1, "id": self.proposal["id"], "choice": "approve", "targets": [0]}).encode())
        self.private("decision-0-attempting-0.json", b'{')
        result = self.decide(index=1)
        self.assertEqual(result["phase"], "uncertain", result)
        self.assert_states(result, ["uncertain", "uncertain", "unchanged"])

    def test_post_rename_crash_before_applied_receipt_is_uncertain(self):
        def child():
            rename = os.rename
            def stop(source, destination, **kwargs):
                rename(source, destination, **kwargs)
                os._exit(74)
            with patch.object(decisions.publisher.os, "rename", side_effect=stop):
                self.decide()
        process = multiprocessing.get_context("fork").Process(target=child)
        process.start()
        process.join(10)
        self.assertEqual(process.exitcode, 74)
        result = self.decide(index=1)
        self.assertEqual(result["phase"], "uncertain", result)
        self.assert_states(result, ["uncertain", "blocked", "unchanged"])
        self.assertEqual(self.files[0].read_bytes(), self.after[0])
        self.assertEqual(self.files[1].read_bytes(), self.before[1])

    def test_same_bytes_external_replacement_after_acceptance_conflicts(self):
        self.decide()
        replacement = self.root / "replacement"
        replacement.write_bytes(self.after[0])
        replacement.chmod(0o644)
        os.replace(replacement, self.files[0])
        result = self.decide(index=1)
        self.assertEqual(result["phase"], "conflicted", result)
        self.assertEqual(result["applied"], self.paths[:1])
        self.assertEqual(self.files[1].read_bytes(), self.before[1])

    def test_post_rename_external_replacement_is_not_blessed_as_accepted(self):
        rename = os.rename
        def replace(source, destination, **kwargs):
            rename(source, destination, **kwargs)
            replacement = self.root / "replacement"
            replacement.write_bytes(self.after[0])
            replacement.chmod(0o644)
            os.replace(replacement, self.files[0])
        with patch.object(decisions.publisher.os, "rename", side_effect=replace):
            result = self.decide()
        self.assertEqual(result["phase"], "uncertain", result)
        self.assertEqual(result["applied"], [])
        self.assert_states(result, ["uncertain", "blocked", "unchanged"])

    def test_second_preparation_failure_never_writes_first(self):
        temporary = decisions.publisher._temporary
        def fail(record):
            if record["index"] == 1:
                raise OSError("injected temporary failure")
            temporary(record)
        with patch.object(decisions.publisher, "_temporary", side_effect=fail):
            result = self.decide(index=None, remaining=True)
        self.assertEqual(result["applied"], [])
        self.assertEqual([file.read_bytes() for file in self.files], self.before)
        self.assertEqual(list(self.root.rglob(".nvim-ai-staged-*")), [])

    def test_unchanged_context_blocks_current_if_modified(self):
        self.files[2].write_bytes(b"external context\n")
        result = self.decide()
        self.assertEqual(result["phase"], "conflicted", result)
        self.assertEqual(self.files[0].read_bytes(), self.before[0])

    def test_attempt_receipt_failure_prevents_rename_and_replay(self):
        receipt = decisions.publisher._receipt
        def fail(parent, name, value):
            if name == b"decision-0-attempting-0.json":
                raise OSError("injected attempt receipt failure")
            return receipt(parent, name, value)
        with patch.object(decisions.publisher, "_receipt", side_effect=fail):
            result = self.decide()
        self.assertEqual(result["applied"], [])
        self.assertEqual([file.read_bytes() for file in self.files], self.before)
        self.assertNotEqual(self.decide(index=1)["phase"], "review_ready")

    def test_first_begin_corruption_never_claims_published_file_unattempted(self):
        self.decide()
        self.private("decision-0.json", b'{')
        result = self.decide(index=1)
        self.assertEqual(result["phase"], "uncertain", result)
        self.assertNotIn(self.paths[0], result["not_attempted"])
        self.assertIn(self.paths[0], result["uncertain"])
        self.assertEqual(self.files[1].read_bytes(), self.before[1])

    def test_missing_first_begin_with_applied_receipt_is_not_fresh(self):
        self.decide()
        (self.task / "decision-0.json").unlink()
        result = controller.decide(str(self.task / "proposal.json"), self.proposal["id"], "approve")
        self.assertEqual(result["phase"], "uncertain", result)
        self.assertNotIn(self.paths[0], result["not_attempted"])
        self.assertEqual(self.files[1].read_bytes(), self.before[1])

    def test_growing_then_shrinking_file_accepts_valid_mixed_size(self):
        for index, (before_size, after_size) in enumerate(((100000, 700000), (700000, 100000))):
            before, after = b"b" * (before_size - 1) + b"\n", b"a" * (after_size - 1) + b"\n"
            self.files[index].write_bytes(before)
            data, mode, identity = controller.snapshot(str(self.root), self.paths[index])
            self.proposal["files"][index].update(identity=identity,
                expected=controller.fingerprint(data, mode), desired=controller.fingerprint(after, mode))
            self.private("before-" + str(index), before)
            self.private("after-" + str(index), after)
        self.private("proposal.json", json.dumps(self.proposal).encode())
        self.assertEqual(self.decide()["phase"], "review_ready")
        result = self.decide(index=1)
        self.assertEqual(result["phase"], "applied", result)
        self.assertEqual(result["applied"], self.paths[:2])

    def test_torn_result_preserves_planned_cleanup_candidates(self):
        rename = os.rename
        def fail(source, destination, **kwargs):
            if destination == b"second.txt":
                raise OSError("injected rename failure")
            return rename(source, destination, **kwargs)
        with patch.object(decisions.publisher.os, "rename", side_effect=fail), patch.object(
                decisions.publisher, "_cleanup", return_value=self.paths[1:2]):
            result = self.decide(index=None, remaining=True)
        self.assertEqual(result["cleanup_pending"], self.paths[1:2])
        self.private("decision-0-result.json", b'{')
        result = self.decide(index=1)
        self.assertEqual(result["phase"], "uncertain", result)
        self.assertEqual(result["applied"], self.paths[:1])
        self.assertEqual(result["cleanup_pending"], self.paths[1:2])


if __name__ == "__main__":
    unittest.main()
