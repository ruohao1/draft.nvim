"""Pending-review eligibility through its public interface and real receipts.

All sources, frozen proposals and deliberate storage damage are disposable.
No private journal methods, internal mocks, agent processes or providers are used.
"""
import importlib.util
import errno
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), SCRIPTS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


controller = load("nvim-ai-staged")
decisions = load("nvim-ai-staged-decisions")


class PendingReviewTest(unittest.TestCase):
    def setUp(self):
        project = tempfile.TemporaryDirectory(prefix="nvim-ai-pending-project-", dir="/tmp")
        self.addCleanup(project.cleanup)
        self.root = Path(project.name)
        self.paths = ["src/accepted.txt", "src/rejected.txt", "pending.txt", "context.txt"]
        self.before = [b"accept original\n", b"reject original\n", b"pending original\n", b"context\n"]
        self.after = [b"accept proposed\n", b"reject proposed\n", b"pending proposed\n", b"context\n"]
        for path, data in zip(self.paths, self.before):
            source = self.root / path
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_bytes(data)
            source.chmod(0o644)
        self.parent = self.proposal(self.after)

    def proposal(self, desired, *, paths=None, legacy=False, token=None, long_name=False):
        """Construct the frozen-file input format from real saved snapshots."""
        paths = self.paths if paths is None else paths
        self.assertEqual(len(paths), len(desired))
        self.assertTrue(not legacy or len(paths) == 1)
        prefix = "nvim-ai-staged-pending-test-" + ("x" * 140 if long_name else "")
        directory = tempfile.TemporaryDirectory(prefix=prefix, dir="/tmp")
        self.addCleanup(directory.cleanup)
        task = Path(directory.name)
        files = []
        for index, (path, after) in enumerate(zip(paths, desired)):
            before, mode, identity = controller.snapshot(str(self.root), path)
            files.append({"path": path, "identity": identity,
                          "expected": controller.fingerprint(before, mode),
                          "desired": controller.fingerprint(after, mode)})
            suffix = "" if legacy else "-" + str(index)
            controller.private_write(task / ("before" + suffix), before)
            controller.private_write(task / ("after" + suffix), after)
        manifest = {"schema": 1 if legacy else 2, "id": token or os.urandom(16).hex(), "root": str(self.root)}
        manifest.update(files[0] if legacy else {"files": files})
        controller.json_write(task / "proposal.json", manifest)
        return {"manifest": str(task / "proposal.json"), "id": manifest["id"], "task": task}

    def pending(self, proposal=None, states=None):
        proposal = self.parent if proposal is None else proposal
        states = ["pending", "pending", "pending", "unchanged"] if states is None else states
        handle = decisions.PendingReview(proposal["manifest"], proposal["id"], str(self.root), states)
        self.addCleanup(handle.close)
        return handle

    def choose(self, choice, index=None, *, proposal=None, remaining=False):
        proposal = self.parent if proposal is None else proposal
        return controller.decide(proposal["manifest"], proposal["id"], choice,
                                 path=None if index is None else self.paths[index], remaining=remaining)

    def saved(self):
        return [(self.root / path).read_bytes() for path in self.paths]

    def test_snapshot_keeps_confirmed_decisions_and_seeds_only_pending_files(self):
        self.assertEqual(self.choose("approve", 0)["phase"], "review_ready")
        self.assertEqual(self.choose("reject", 1)["phase"], "review_ready")
        states = ["accepted", "rejected", "pending", "unchanged"]
        handle = self.pending(states=states)
        snapshot = handle.snapshot()
        self.assertEqual(snapshot["root"], str(self.root))
        self.assertEqual(snapshot["states"], states)
        self.assertEqual([entry["path"] for entry in snapshot["files"]], self.paths)
        self.assertEqual([entry["context_only"] for entry in snapshot["files"]], [True, True, False, True])
        self.assertEqual([entry["seed"] for entry in snapshot["files"]], [None, None, b"pending proposed\n", None])
        # The accepted identity must be the writer's replacement, not the old
        # inode retained in the original proposal.
        for path, entry in zip(self.paths, snapshot["files"]):
            data, mode, identity = controller.snapshot(str(self.root), path)
            self.assertEqual(entry["identity"], identity)
            self.assertEqual(entry["expected"], controller.fingerprint(data, mode))
        self.assertEqual(self.saved(), [b"accept proposed\n", *self.before[1:]])
        handle.close()
        result = self.choose("approve", 2)
        self.assertEqual(result["phase"], "applied", result)
        self.assertEqual(self.saved(), [b"accept proposed\n", b"reject original\n", b"pending proposed\n", b"context\n"])

    def test_null_consumption_receipt_cannot_reopen_legacy_approval(self):
        legacy = self.proposal([b"legacy accepted\n"], paths=self.paths[:1], legacy=True)
        self.assertEqual(self.choose("approve", proposal=legacy)["phase"], "applied")
        # Damage a real writer receipt with valid JSON that is not a record.
        # Presence must not be mistaken for a never-consumed proposal.
        (legacy["task"] / "consumed.json").write_bytes(b"null")
        with self.assertRaises(ValueError):
            self.pending(legacy, ["pending"])
        self.assertEqual(self.saved(), [b"legacy accepted\n", *self.before[1:]])

    def test_snapshot_and_input_view_are_detached_and_close_is_not_a_decision(self):
        states = ["pending", "pending", "pending", "unchanged"]
        handle = self.pending(states=states)
        states[0] = "accepted"
        first = handle.snapshot()
        first["states"][1] = "rejected"
        first["files"][0]["identity"][0][0][1] = 0
        first["files"][1]["expected"]["size"] = 0
        first["files"][2]["seed"] = b"caller mutation\n"
        first["files"][2]["context_only"] = True
        fresh = handle.snapshot()
        self.assertEqual(fresh["states"], ["pending", "pending", "pending", "unchanged"])
        self.assertEqual([entry["seed"] for entry in fresh["files"]], [*self.after[:3], None])
        self.assertIs(fresh["files"][2]["context_only"], False)
        for path, entry in zip(self.paths, fresh["files"]):
            data, mode, identity = controller.snapshot(str(self.root), path)
            self.assertEqual(entry["identity"], identity)
            self.assertEqual(entry["expected"], controller.fingerprint(data, mode))
        handle.close()
        handle.close()
        with self.assertRaises(ValueError):
            handle.snapshot()
        with self.assertRaises(ValueError):
            handle.retire(self.parent["manifest"], self.parent["id"])
        reopened = self.pending()
        self.assertEqual(reopened.snapshot(), fresh)
        reopened.close()
        self.assertEqual(self.saved(), self.before)
        self.assertEqual(self.choose("approve", 0)["phase"], "review_ready")

    def test_wrong_identity_root_or_decision_view_is_refused_and_releases_lock(self):
        self.assertEqual(self.choose("approve", 0)["phase"], "review_ready")
        current = ["accepted", "pending", "pending", "unchanged"]
        for token, root, states in (
            ("0" * 32, str(self.root), current),
            (self.parent["id"], str(self.root / "src"), current),
            (self.parent["id"], str(self.root), ["pending", "pending", "pending", "unchanged"]),
            (self.parent["id"], str(self.root), ["pending", "accepted", "pending", "unchanged"]),
            (self.parent["id"], str(self.root), current[:2]),
        ):
            with self.subTest(token=token, root=root, states=states):
                with self.assertRaises(ValueError):
                    handle = decisions.PendingReview(self.parent["manifest"], token, root, states)
                    self.addCleanup(handle.close)
                valid = self.pending(states=current)
                self.assertEqual(valid.snapshot()["states"], current)
                valid.close()
        self.assertEqual(self.saved(), [b"accept proposed\n", *self.before[1:]])

    def test_replacement_retires_old_approval_and_only_new_explicit_approval_writes(self):
        self.assertEqual(self.choose("approve", 0)["phase"], "review_ready")
        self.assertEqual(self.choose("reject", 1)["phase"], "review_ready")
        states = ["accepted", "rejected", "pending", "unchanged"]
        saved = [b"accept proposed\n", b"reject original\n", b"pending original\n", b"context\n"]
        replacement = self.proposal([saved[0], saved[1], b"pending revised\n", saved[3]])
        handle = self.pending(states=states)
        handle.retire(replacement["manifest"], replacement["id"])
        with self.assertRaises(ValueError):
            handle.snapshot()
        handle.close()
        with self.assertRaises(ValueError):
            self.pending(states=states)
        self.assertEqual(self.saved(), saved)
        for index, remaining in ((2, False), (None, True), (None, False)):
            with self.subTest(index=index, remaining=remaining):
                result = self.choose("approve", index, remaining=remaining)
                self.assertEqual(result["phase"], "cancelled", result)
                self.assertEqual(result["applied"], self.paths[:1])
                self.assertEqual(self.saved(), saved)
        revised = self.pending(replacement, ["unchanged", "unchanged", "pending", "unchanged"])
        self.assertEqual([entry["seed"] for entry in revised.snapshot()["files"]],
                         [None, None, b"pending revised\n", None])
        revised.close()
        self.assertEqual(self.choose("approve", 2, proposal=replacement)["phase"], "applied")
        self.assertEqual(self.saved(), [saved[0], saved[1], b"pending revised\n", saved[3]])

    def test_busy_parent_or_candidate_is_refused_without_consuming_the_review(self):
        owner = self.pending()
        with self.assertRaises(BlockingIOError):
            self.pending()
        candidate = self.proposal(self.after)
        candidate_owner = self.pending(candidate)
        with self.assertRaises(BlockingIOError):
            owner.retire(candidate["manifest"], candidate["id"])
        self.assertEqual(owner.snapshot()["states"], ["pending", "pending", "pending", "unchanged"])
        self.assertEqual(self.saved(), self.before)
        candidate_owner.close()
        owner.retire(candidate["manifest"], candidate["id"])
        owner.close()
        with self.assertRaises(ValueError):
            self.pending()
        reopened = self.pending(candidate)
        self.assertEqual(reopened.snapshot()["files"][2]["seed"], b"pending proposed\n")
        reopened.close()
        self.assertEqual(self.saved(), self.before)

    def test_every_frozen_panel_and_manifest_is_revalidated_before_reuse(self):
        self.assertEqual(self.choose("approve", 0)["phase"], "review_ready")
        self.assertEqual(self.choose("reject", 1)["phase"], "review_ready")
        states = ["accepted", "rejected", "pending", "unchanged"]
        names = ["proposal.json", *(prefix + "-" + str(index)
                  for index in range(4) for prefix in ("before", "after"))]
        for name in names:
            with self.subTest(name=name):
                handle = self.pending(states=states)
                artifact = self.parent["task"] / name
                original = artifact.read_bytes()
                if name == "proposal.json":
                    changed = json.loads(original)
                    changed["id"] = "0" * 32
                    damaged = json.dumps(changed).encode()
                else:
                    damaged = b"damaged frozen panel\n"
                try:
                    artifact.write_bytes(damaged)
                    with self.assertRaises(ValueError):
                        handle.snapshot()
                    handle.close()
                    with self.assertRaises(ValueError):
                        self.pending(states=states)
                finally:
                    handle.close()
                    artifact.write_bytes(original)
        self.assertEqual(self.saved(), [b"accept proposed\n", *self.before[1:]])

    def test_damaged_or_missing_real_decision_receipts_never_restore_eligibility(self):
        self.assertEqual(self.choose("approve", 0)["phase"], "review_ready")
        states = ["accepted", "pending", "pending", "unchanged"]
        names = ("consumed.json", "decision-0.json", "decision-0-applied-0.json", "decision-0-result.json")
        for name in names:
            for damage in (b"null", b'{"id":', None):
                with self.subTest(name=name, damage=damage):
                    handle = self.pending(states=states)
                    artifact = self.parent["task"] / name
                    original = artifact.read_bytes()
                    try:
                        if damage is None:
                            artifact.unlink()
                        else:
                            artifact.write_bytes(damage)
                        with self.assertRaises(ValueError):
                            handle.snapshot()
                        handle.close()
                        with self.assertRaises(ValueError):
                            self.pending(states=states)
                    finally:
                        handle.close()
                        artifact.write_bytes(original)
                        artifact.chmod(0o600)
        self.assertEqual(self.saved(), [b"accept proposed\n", *self.before[1:]])

    def test_real_torn_handoff_never_reports_old_approval_active(self):
        # Impose a real file-size limit only in a disposable child process.
        # The small origin fits; the long candidate path makes the old handoff
        # exceed 256 bytes. This exercises actual partial write/EFBIG behavior,
        # not a mock of the receipt writer or an internal callback.
        child_code = """
import importlib.util, json, resource, signal, sys
spec = importlib.util.spec_from_file_location('pending_child', sys.argv[1])
decisions = importlib.util.module_from_spec(spec)
spec.loader.exec_module(decisions)
parent, candidate, root, states = json.loads(sys.argv[2])
handle = decisions.PendingReview(parent['manifest'], parent['id'], root, states)
signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
resource.setrlimit(resource.RLIMIT_FSIZE, (256, 256))
result = {}
try:
    try:
        handle.retire(candidate['manifest'], candidate['id'])
    except OSError as error:
        result['errno'] = error.errno
    try:
        handle.snapshot()
        result['active'] = True
    except ValueError:
        result['active'] = False
finally:
    handle.close()
print(json.dumps(result))
"""
        for legacy in (False, True):
            with self.subTest(legacy=legacy):
                paths = self.paths[:1] if legacy else self.paths
                after = self.after[:1] if legacy else self.after
                states = ["pending"] if legacy else ["pending", "pending", "pending", "unchanged"]
                parent = self.proposal(after, paths=paths, legacy=legacy)
                candidate = self.proposal(after, paths=paths, long_name=True)
                inputs = [{key: value for key, value in proposal.items() if key != "task"}
                          for proposal in (parent, candidate)]
                inputs += [str(self.root), states]
                result = subprocess.run([sys.executable, "-I", "-B", "-c", child_code,
                                         str(SCRIPTS / "nvim-ai-staged-decisions.py"), json.dumps(inputs)],
                                        capture_output=True, timeout=10, check=True)
                self.assertEqual(json.loads(result.stdout), {"errno": errno.EFBIG, "active": False})
                fence = (parent["task"] / "followup.json").read_bytes()
                self.assertEqual(len(fence), 256)
                with self.assertRaises(json.JSONDecodeError):
                    json.loads(fence)
                with self.assertRaises(ValueError):
                    self.pending(parent, states)
                if legacy:
                    with self.assertRaises(ValueError):
                        self.choose("approve", proposal=parent)
                else:
                    for index, remaining in ((0, False), (None, True), (None, False)):
                        verdict = self.choose("approve", index, proposal=parent, remaining=remaining)
                        self.assertIn(verdict["phase"], ("blocked", "uncertain"), verdict)
                        self.assertEqual(verdict["applied"], [])
                self.assertEqual(self.saved(), self.before)

    def test_invalid_candidates_do_not_retire_or_expand_the_old_review(self):
        self.assertEqual(self.choose("approve", 0)["phase"], "review_ready")
        self.assertEqual(self.choose("reject", 1)["phase"], "review_ready")
        states = ["accepted", "rejected", "pending", "unchanged"]
        handle = self.pending(states=states)
        original = handle.snapshot()
        for case in ("wrong-token", "reused-token", "wrong-root", "missing-file", "reordered",
                     "stale-baseline", "edit-accepted", "edit-rejected", "edit-unchanged",
                     "damaged-frozen", "consumed"):
            with self.subTest(case=case):
                paths = self.paths[:]
                desired = [b"accept proposed\n", b"reject original\n", b"pending revised\n", b"context\n"]
                if case == "missing-file":
                    paths, desired = paths[:-1], desired[:-1]
                elif case == "reordered":
                    paths.reverse()
                    desired.reverse()
                elif case.startswith("edit-"):
                    index = {"edit-accepted": 0, "edit-rejected": 1, "edit-unchanged": 3}[case]
                    desired[index] = b"unauthorized revision\n"
                candidate = self.proposal(desired, paths=paths,
                                          token=self.parent["id"] if case == "reused-token" else None)
                token = "0" * 32 if case == "wrong-token" else candidate["id"]
                if case in ("wrong-root", "stale-baseline"):
                    manifest = json.loads(Path(candidate["manifest"]).read_bytes())
                    if case == "wrong-root":
                        manifest["root"] = str(self.root / "src")
                    else:
                        manifest["files"][0]["identity"][0][0][1] = 0
                    Path(candidate["manifest"]).write_bytes(json.dumps(manifest).encode())
                elif case == "damaged-frozen":
                    (candidate["task"] / "after-2").write_bytes(b"damaged proposal\n")
                elif case == "consumed":
                    self.assertEqual(self.choose("reject", 2, proposal=candidate)["phase"], "rejected")
                with self.assertRaises(ValueError):
                    handle.retire(candidate["manifest"], token)
                self.assertEqual(handle.snapshot(), original)
                self.assertEqual(self.saved(), [b"accept proposed\n", *self.before[1:]])
        handle.close()
        self.assertEqual(self.choose("approve", 2)["phase"], "applied")
        self.assertEqual(self.saved(), [b"accept proposed\n", b"reject original\n", b"pending proposed\n", b"context\n"])

    def test_legacy_single_file_can_be_replaced_but_cannot_replay_its_old_token(self):
        legacy = self.proposal([b"legacy proposed\n"], paths=self.paths[:1], legacy=True)
        handle = self.pending(legacy, ["pending"])
        self.assertEqual(handle.snapshot()["files"][0]["seed"], b"legacy proposed\n")
        candidate = self.proposal([b"legacy revised\n"], paths=self.paths[:1])
        handle.retire(candidate["manifest"], candidate["id"])
        handle.close()
        with self.assertRaises(ValueError):
            self.pending(legacy, ["pending"])
        self.assertEqual(self.choose("approve", proposal=legacy)["phase"], "already_decided")
        self.assertEqual(self.saved(), self.before)
        revised = self.pending(candidate, ["pending"])
        self.assertEqual(revised.snapshot()["files"][0]["seed"], b"legacy revised\n")
        revised.close()
        self.assertEqual(self.choose("approve", 0, proposal=candidate)["phase"], "applied")
        self.assertEqual(self.saved(), [b"legacy revised\n", *self.before[1:]])

    def test_unsafe_private_inputs_are_refused_on_open_and_revalidation(self):
        for case in ("directory-mode", "manifest-mode", "frozen-mode", "symlink", "hardlink", "fifo"):
            with self.subTest(case=case):
                proposal = self.proposal(self.after)
                handle = self.pending(proposal)
                frozen = proposal["task"] / "after-3"
                if case == "directory-mode":
                    proposal["task"].chmod(0o755)
                elif case == "manifest-mode":
                    Path(proposal["manifest"]).chmod(0o644)
                elif case == "frozen-mode":
                    frozen.chmod(0o644)
                elif case == "hardlink":
                    os.link(frozen, proposal["task"] / "extra-link")
                else:
                    frozen.unlink()
                    if case == "symlink":
                        frozen.symlink_to(proposal["task"] / "before-3")
                    else:
                        os.mkfifo(frozen, 0o600)
                with self.assertRaises((OSError, ValueError)):
                    handle.snapshot()
                handle.close()
                with self.assertRaises((OSError, ValueError)):
                    self.pending(proposal)
                self.assertEqual(self.saved(), self.before)

    def test_settled_decisions_cannot_start_another_followup(self):
        for choice, phase in (("cancel", "cancelled"), ("reject", "rejected"), ("approve", "applied")):
            with self.subTest(choice=choice):
                proposal = self.proposal(self.after)
                self.assertEqual(self.choose("reject", 0, proposal=proposal)["phase"], "review_ready")
                verdict = self.choose(choice, proposal=proposal, remaining=choice != "cancel")
                self.assertEqual(verdict["phase"], phase, verdict)
                states = [item["state"] for item in verdict["decisions"]]
                with self.assertRaises(ValueError):
                    self.pending(proposal, states)
                expected = [self.before[0], *self.after[1:]] if choice == "approve" else self.before
                self.assertEqual(self.saved(), expected)

    def test_contradictory_completion_preserves_confirmed_writes_but_refuses_more(self):
        self.assertEqual(self.choose("approve", 0)["phase"], "review_ready")
        states = ["accepted", "pending", "pending", "unchanged"]
        receipt = self.parent["task"] / "decision-0-result.json"
        damaged = json.loads(receipt.read_bytes())
        damaged["phase"] = "applied"  # Other files still have pending decisions.
        receipt.write_bytes(json.dumps(damaged).encode())
        with self.assertRaises(ValueError):
            self.pending(states=states)
        verdict = self.choose("approve", 2)
        self.assertEqual(verdict["phase"], "uncertain", verdict)
        self.assertEqual(verdict["applied"], self.paths[:1])
        self.assertEqual(self.saved(), [b"accept proposed\n", *self.before[1:]])


if __name__ == "__main__":
    unittest.main()
