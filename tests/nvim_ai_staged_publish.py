"""Multi-file publisher faults: real files, no provider, network, or terminal."""
import copy
import importlib.util
import json
import multiprocessing
import os
from pathlib import Path
import shutil
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


publisher = load("nvim-ai-staged-publish")
controller = load("nvim-ai-staged")


class PublicationTest(unittest.TestCase):
    def setUp(self):
        project = tempfile.TemporaryDirectory(prefix="nvim-ai-publish-test-", dir="/tmp")
        task = tempfile.TemporaryDirectory(prefix="nvim-ai-staged-publish-test-", dir="/tmp")
        self.addCleanup(project.cleanup)
        self.addCleanup(task.cleanup)
        self.root, self.task = Path(project.name), Path(task.name)
        self.paths = ["src/one.txt", "lib/two.txt", "context.txt"]
        self.before = [b"first original\n", b"second original\n", b"unchanged context\n"]
        self.after = [b"first approved\n", b"second approved\n", self.before[2]]
        self.files = [self.root / path for path in self.paths]
        entries = []
        for index, file in enumerate(self.files):
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(self.before[index])
            file.chmod(0o755 if index == 1 else 0o644)
            data, mode, identity = controller.snapshot(str(self.root), self.paths[index])
            entries.append({"path": self.paths[index], "identity": identity,
                            "expected": controller.fingerprint(data, mode),
                            "desired": controller.fingerprint(self.after[index], mode)})
            self.private("before-" + str(index), self.before[index])
            self.private("after-" + str(index), self.after[index])
        self.proposal = {"schema": 2, "id": "a" * 32, "root": str(self.root), "files": entries}
        self.private("consumed.json", json.dumps({"choice": "approve", "id": self.proposal["id"]}).encode())

    def private(self, name, data):
        file = self.task / name
        file.write_bytes(data)
        file.chmod(0o600)

    def run_publish(self, proposal=None, snapshot=None):
        return publisher.publish(self.task, proposal or self.proposal, snapshot or controller.snapshot)

    def assert_originals(self):
        self.assertEqual([file.read_bytes() for file in self.files], self.before)

    def assert_clean(self):
        self.assertEqual(list(self.root.rglob(".nvim-ai-staged-*")), [])

    def assert_evidence(self):
        self.assertTrue((self.task / "consumed.json").is_file())
        self.assertTrue((self.task / "publication.json").is_file())
        for index in range(3):
            self.assertEqual((self.task / ("before-" + str(index))).read_bytes(), self.before[index])

    def fd_path(self, fd):
        return os.readlink("/proc/self/fd/" + str(fd))

    def test_handoff_receipt_blocks_direct_publication_even_when_torn_or_not_a_file(self):
        fence = self.task / "followup.json"
        for kind in ("complete", "torn", "symlink", "directory"):
            with self.subTest(kind=kind):
                if kind == "symlink":
                    fence.symlink_to(self.task / "absent")
                elif kind == "directory":
                    fence.mkdir()
                else:
                    self.private("followup.json", b'{}' if kind == "complete" else b'{"schema":')
                try:
                    result = self.run_publish()
                    self.assertEqual(result["phase"], "blocked", result)
                    self.assertFalse((self.task / "publication.json").exists())
                    self.assert_originals()
                    self.assert_clean()
                finally:
                    if kind == "directory": fence.rmdir()
                    else: fence.unlink()

    def test_all_prepared_before_first_rename_and_unchanged_not_replaced(self):
        rename = os.rename
        context_inode = self.files[2].stat().st_ino
        renamed = []

        def inspect(source, destination, **kwargs):
            if not renamed:
                plan = json.loads((self.task / "publication.json").read_bytes())
                for index in range(2):
                    temporary = self.files[index].parent / plan["files"][index]["temporary"]
                    self.assertEqual(temporary.read_bytes(), self.after[index])
                    self.assertEqual(temporary.stat().st_mode & 0o777, 0o755 if index == 1 else 0o644)
                self.assertTrue((self.task / "attempting-0.json").exists())
            renamed.append(destination)
            return rename(source, destination, **kwargs)

        with patch.object(publisher.os, "rename", side_effect=inspect):
            result = self.run_publish()
        self.assertEqual(result["phase"], "applied", result)
        self.assertEqual(result["applied"], self.paths[:2])
        self.assertEqual(result["uncertain"], [])
        self.assertEqual(result["not_attempted"], [])
        self.assertEqual(result["unchanged"], self.paths[2:])
        self.assertEqual([file.read_bytes() for file in self.files], self.after)
        self.assertEqual(self.files[2].stat().st_ino, context_inode)
        self.assertEqual(self.files[1].stat().st_mode & 0o777, 0o755)
        self.assert_evidence()
        self.assert_clean()
        for name in ("publication.json", "attempting-0.json", "applied-0.json", "applied-1.json", "result.json"):
            self.assertEqual((self.task / name).stat().st_mode & 0o777, 0o600)

    def test_consumption_and_manifest_are_required_before_writes(self):
        cases = []
        for change in ({"schema": True}, {"extra": True}, {"id": "bad"}, {"files": []},
                       {"files": self.proposal["files"] * 6}):
            cases.append(dict(self.proposal, **change))
        for update in ({"path": "../outside"}, {"path": "/outside"},
                       {"identity": []}, {"unexpected": True}):
            value = copy.deepcopy(self.proposal)
            value["files"][1].update(update)
            cases.append(value)
        duplicate = copy.deepcopy(self.proposal)
        duplicate["files"][1]["path"] = duplicate["files"][0]["path"]
        cases.append(duplicate)
        huge = copy.deepcopy(self.proposal)
        huge["files"][0]["desired"]["size"] = publisher.MAX_BYTES
        cases.append(huge)
        mode = copy.deepcopy(self.proposal)
        mode["files"][0]["desired"]["mode"] = "100755"
        cases.append(mode)
        for value in cases:
            with self.subTest(value=value):
                result = self.run_publish(value)
                self.assertEqual(result["phase"], "blocked", result)
                self.assert_originals()
        (self.task / "consumed.json").unlink()
        self.assertEqual(self.run_publish()["phase"], "blocked")
        self.assert_originals()
        self.assert_clean()

    def test_frozen_second_file_tamper_prevents_first_publication(self):
        self.private("after-1", b"unreviewed bytes\n")
        result = self.run_publish()
        self.assertEqual(result["phase"], "blocked", result)
        self.assertEqual(result["not_attempted"], self.paths[:2])
        self.assert_originals()
        self.assert_evidence()
        self.assert_clean()

    def test_unsafe_frozen_kind_is_refused_before_any_publication(self):
        (self.task / "after-1").unlink()
        (self.task / "after-1").symlink_to(self.task / "after-0")
        self.assertEqual(self.run_publish()["phase"], "blocked")
        self.assert_originals()
        self.assert_clean()

    def test_unchanged_context_is_still_validated(self):
        self.files[2].write_bytes(b"user changed context\n")
        result = self.run_publish()
        self.assertEqual(result["phase"], "conflicted", result)
        self.assertEqual([file.read_bytes() for file in self.files[:2]], self.before[:2])
        self.assert_evidence()
        self.assert_clean()

    def test_same_byte_second_source_replacement_conflicts_before_first_write(self):
        self.files[1].unlink()
        self.files[1].write_bytes(self.before[1])
        self.files[1].chmod(0o755)
        self.assertEqual(self.run_publish()["phase"], "conflicted")
        self.assert_originals()
        self.assert_clean()

    def test_second_temporary_write_failure_keeps_all_originals(self):
        write = os.write

        def fail(fd, data):
            path = self.fd_path(fd)
            if path.startswith(str(self.files[1].parent) + "/.nvim-ai-staged-"):
                raise OSError("injected disk full")
            return write(fd, data)

        with patch.object(publisher.os, "write", side_effect=fail):
            result = self.run_publish()
        self.assertEqual(result["phase"], "blocked", result)
        self.assert_originals()
        self.assert_evidence()
        self.assert_clean()

    def test_second_temporary_fsync_failure_keeps_all_originals(self):
        fsync = os.fsync

        def fail(fd):
            if self.fd_path(fd).startswith(str(self.files[1].parent) + "/.nvim-ai-staged-"):
                raise OSError("injected temporary fsync failure")
            return fsync(fd)

        with patch.object(publisher.os, "fsync", side_effect=fail):
            result = self.run_publish()
        self.assertEqual(result["phase"], "blocked", result)
        self.assert_originals()
        self.assert_clean()

    def test_consumption_directory_fsync_failure_prevents_publication(self):
        fsync = os.fsync

        def fail(fd):
            if self.fd_path(fd) == str(self.task):
                raise OSError("injected task directory fsync failure")
            return fsync(fd)

        with patch.object(publisher.os, "fsync", side_effect=fail):
            result = self.run_publish()
        self.assertEqual(result["phase"], "blocked", result)
        self.assert_originals()
        self.assertFalse((self.task / "publication.json").exists())
        self.assert_clean()

    def test_attempt_receipt_fsync_failure_prevents_first_rename(self):
        fsync = os.fsync

        def fail(fd):
            if self.fd_path(fd) == str(self.task / "attempting-0.json"):
                raise OSError("injected attempt receipt fsync failure")
            return fsync(fd)

        with patch.object(publisher.os, "fsync", side_effect=fail):
            result = self.run_publish()
        self.assertEqual(result["phase"], "blocked", result)
        self.assertEqual(result["applied"], [])
        self.assert_originals()
        self.assert_evidence()
        self.assert_clean()

    def test_first_rename_failure_is_conservatively_uncertain_and_stops(self):
        with patch.object(publisher.os, "rename", side_effect=OSError("injected rename failure")) as rename:
            result = self.run_publish()
        self.assertEqual(rename.call_count, 1)
        self.assertEqual(result["phase"], "uncertain", result)
        self.assertEqual(result["applied"], [])
        self.assertEqual(result["uncertain"], self.paths[:1])
        self.assertEqual(result["not_attempted"], self.paths[1:2])
        self.assert_originals()
        self.assert_evidence()
        self.assert_clean()

    def test_second_rename_failure_never_rolls_back_the_first(self):
        rename, count = os.rename, 0

        def fail(source, destination, **kwargs):
            nonlocal count
            count += 1
            if count == 2:
                raise OSError("injected second rename failure")
            return rename(source, destination, **kwargs)

        with patch.object(publisher.os, "rename", side_effect=fail):
            result = self.run_publish()
        self.assertEqual(count, 2)
        self.assertEqual(result["phase"], "uncertain", result)
        self.assertEqual(result["applied"], self.paths[:1])
        self.assertEqual(result["uncertain"], self.paths[1:2])
        self.assertEqual(self.files[0].read_bytes(), self.after[0])
        self.assertEqual(self.files[1].read_bytes(), self.before[1])
        self.assert_evidence()
        self.assert_clean()

    def test_source_change_after_first_publication_stops_before_second(self):
        rename, count = os.rename, 0

        def change(source, destination, **kwargs):
            nonlocal count
            result = rename(source, destination, **kwargs)
            count += 1
            self.files[1].write_bytes(b"concurrent user change\n")
            return result

        with patch.object(publisher.os, "rename", side_effect=change):
            result = self.run_publish()
        self.assertEqual(count, 1)
        self.assertEqual(result["phase"], "partial", result)
        self.assertEqual(result["applied"], self.paths[:1])
        self.assertEqual(result["uncertain"], [])
        self.assertEqual(result["not_attempted"], self.paths[1:2])
        self.assertEqual(self.files[0].read_bytes(), self.after[0])
        self.assertEqual(self.files[1].read_bytes(), b"concurrent user change\n")
        self.assert_evidence()
        self.assert_clean()

    def test_parent_replacement_after_preparation_prevents_first_rename(self):
        fsync, changed = os.fsync, False
        saved = self.root / "saved-lib"

        def change(fd):
            nonlocal changed
            result = fsync(fd)
            if not changed and self.fd_path(fd) == str(self.files[1].parent):
                changed = True
                self.files[1].parent.rename(saved)
                self.files[1].parent.mkdir()
                self.files[1].write_bytes(b"replacement parent file\n")
            return result

        with patch.object(publisher.os, "fsync", side_effect=change):
            result = self.run_publish()
        self.assertIn(result["phase"], ("blocked", "conflicted"), result)
        self.assertEqual(result["applied"], [])
        self.assertEqual(self.files[0].read_bytes(), self.before[0])
        self.assertEqual((saved / "two.txt").read_bytes(), self.before[1])
        self.assertEqual(self.files[1].read_bytes(), b"replacement parent file\n")
        self.assert_evidence()

    def test_parent_replacement_after_first_publication_stops_the_batch(self):
        rename, count = os.rename, 0
        saved = self.root / "saved-lib"

        def change(source, destination, **kwargs):
            nonlocal count
            result = rename(source, destination, **kwargs)
            count += 1
            if count == 1:
                rename(self.files[1].parent, saved)
                self.files[1].parent.mkdir()
                self.files[1].write_bytes(b"replacement parent file\n")
            return result

        with patch.object(publisher.os, "rename", side_effect=change):
            result = self.run_publish()
        self.assertEqual(count, 1)
        self.assertEqual(result["phase"], "partial", result)
        self.assertEqual(result["applied"], self.paths[:1])
        self.assertEqual(result["not_attempted"], self.paths[1:2])
        self.assertEqual((saved / "two.txt").read_bytes(), self.before[1])
        self.assertEqual(self.files[1].read_bytes(), b"replacement parent file\n")
        self.assert_evidence()

    def test_post_rename_parent_fsync_failure_is_uncertain_and_stops(self):
        rename, fsync, renamed = os.rename, os.fsync, False

        def record(source, destination, **kwargs):
            nonlocal renamed
            result = rename(source, destination, **kwargs)
            renamed = True
            return result

        def fail(fd):
            if renamed and self.fd_path(fd) == str(self.files[0].parent):
                raise OSError("injected published parent fsync failure")
            return fsync(fd)

        with patch.object(publisher.os, "rename", side_effect=record), patch.object(publisher.os, "fsync", side_effect=fail):
            result = self.run_publish()
        self.assertEqual(result["phase"], "uncertain", result)
        self.assertEqual(result["uncertain"], self.paths[:1])
        self.assertEqual(result["not_attempted"], self.paths[1:2])
        self.assertEqual(self.files[0].read_bytes(), self.after[0])
        self.assertEqual(self.files[1].read_bytes(), self.before[1])
        self.assert_evidence()

    def test_confirmation_receipt_fsync_failure_stops_after_first_publication(self):
        fsync = os.fsync

        def fail(fd):
            if self.fd_path(fd) == str(self.task / "applied-0.json"):
                raise OSError("injected applied receipt fsync failure")
            return fsync(fd)

        with patch.object(publisher.os, "fsync", side_effect=fail):
            result = self.run_publish()
        self.assertEqual(result["phase"], "uncertain", result)
        self.assertEqual(result["applied"], [])
        self.assertEqual(result["uncertain"], self.paths[:1])
        self.assertEqual(self.files[0].read_bytes(), self.after[0])
        self.assertEqual(self.files[1].read_bytes(), self.before[1])
        self.assert_evidence()
        self.assert_clean()

    def test_final_receipt_failure_does_not_erase_confirmed_paths(self):
        fsync = os.fsync

        def fail(fd):
            if self.fd_path(fd) == str(self.task / "result.json"):
                raise OSError("injected final receipt fsync failure")
            return fsync(fd)

        with patch.object(publisher.os, "fsync", side_effect=fail):
            result = self.run_publish()
        self.assertEqual(result["phase"], "uncertain", result)
        self.assertEqual(result["applied"], self.paths[:2])
        self.assertEqual([file.read_bytes() for file in self.files], self.after)
        self.assert_evidence()
        self.assert_clean()

    def test_temporary_xattr_is_rejected_before_any_publication(self):
        fchmod = os.fchmod

        def add_xattr(fd, mode):
            fchmod(fd, mode)
            os.setxattr(fd, "user.staged-publication-test", b"unsupported")

        with patch.object(publisher.os, "fchmod", side_effect=add_xattr):
            result = self.run_publish()
        self.assertEqual(result["phase"], "blocked", result)
        self.assert_originals()
        self.assert_evidence()
        self.assert_clean()

    @unittest.skipUnless(shutil.which("setfacl"), "setfacl is required for inherited ACL coverage")
    def test_new_parent_default_acl_cannot_leak_into_published_files(self):
        subprocess.run([shutil.which("setfacl"), "-m", "d:u:65534:r--", str(self.files[1].parent)],
                       check=True, capture_output=True)
        self.assertEqual(os.listxattr(self.files[1]), [])
        result = self.run_publish()
        self.assertEqual(result["phase"], "blocked", result)
        self.assert_originals()
        self.assert_evidence()
        self.assert_clean()

    def test_post_write_verification_failure_stops_before_second_publication(self):
        rename = os.rename

        def changed_after_rename(source, destination, **kwargs):
            result = rename(source, destination, **kwargs)
            self.files[0].write_bytes(b"concurrent edit after publication\n")
            return result

        with patch.object(publisher.os, "rename", side_effect=changed_after_rename) as calls:
            result = self.run_publish()
        self.assertEqual(calls.call_count, 1)
        self.assertEqual(result["phase"], "uncertain", result)
        self.assertEqual(result["uncertain"], self.paths[:1])
        self.assertEqual(result["not_attempted"], self.paths[1:2])
        self.assertEqual(self.files[0].read_bytes(), b"concurrent edit after publication\n")
        self.assertEqual(self.files[1].read_bytes(), self.before[1])
        self.assert_evidence()
        self.assert_clean()

    def test_failed_preflight_plan_cannot_be_repaired_and_replayed(self):
        self.private("after-1", b"unreviewed bytes\n")
        self.assertEqual(self.run_publish()["phase"], "blocked")
        self.private("after-1", self.after[1])
        self.assertEqual(self.run_publish()["phase"], "already_decided")
        self.assert_originals()
        self.assert_evidence()

    def test_cleanup_does_not_unlink_a_replaced_temporary_inode(self):
        fsync, replacement = os.fsync, None
        displaced = self.root / "displaced-owned-temporary"

        def replace(fd):
            nonlocal replacement
            path = self.fd_path(fd)
            result = fsync(fd)
            if replacement is None and path.startswith(str(self.files[1].parent) + "/.nvim-ai-staged-"):
                replacement = Path(path)
                replacement.rename(displaced)
                replacement.write_bytes(b"not the owned temporary\n")
            return result

        with patch.object(publisher.os, "fsync", side_effect=replace):
            result = self.run_publish()
        self.assertEqual(result["phase"], "blocked", result)
        self.assert_originals()
        self.assertEqual(replacement.read_bytes(), b"not the owned temporary\n")
        self.assertIn(self.paths[1], result["cleanup_pending"])
        self.assert_evidence()

    def test_teardown_close_error_cannot_escape_after_publication(self):
        close = os.close
        raised = []

        def fail(fd):
            path = self.fd_path(fd)
            result = close(fd)
            if (self.task / "result.json").exists() and path in (str(self.task), str(self.root)):
                raised.append(path)
                raise OSError("injected teardown close failure")
            return result

        with patch.object(publisher.os, "close", side_effect=fail):
            result = self.run_publish()
        self.assertTrue(raised)
        self.assertEqual(result["phase"], "applied", result)
        self.assertEqual([file.read_bytes() for file in self.files], self.after)

    def test_completed_or_started_publication_cannot_replay(self):
        first = self.run_publish()
        self.assertEqual(first["phase"], "applied", first)
        self.files[0].write_bytes(b"later user edit\n")
        result = self.run_publish()
        self.assertEqual(result["phase"], "already_decided", result)
        self.assertEqual(self.files[0].read_bytes(), b"later user edit\n")
        self.assert_evidence()

    def test_process_death_after_first_rename_retains_evidence_and_cannot_replay(self):
        rename = os.rename

        def child():
            def die(source, destination, **kwargs):
                rename(source, destination, **kwargs)
                os._exit(93)
            with patch.object(publisher.os, "rename", side_effect=die):
                self.run_publish()
            os._exit(94)

        process = multiprocessing.get_context("fork").Process(target=child)
        process.start()
        process.join(8)
        if process.is_alive():
            process.kill()
            process.join(3)
        self.assertEqual(process.exitcode, 93)
        self.assertEqual(self.files[0].read_bytes(), self.after[0])
        self.assertEqual(self.files[1].read_bytes(), self.before[1])
        self.assertTrue((self.task / "attempting-0.json").exists())
        self.assertFalse((self.task / "applied-0.json").exists())
        self.assert_evidence()
        self.files[0].write_bytes(b"user recovered the first file\n")
        result = self.run_publish()
        self.assertEqual(result["phase"], "already_decided", result)
        self.assertEqual(self.files[0].read_bytes(), b"user recovered the first file\n")
        self.assertEqual(self.files[1].read_bytes(), self.before[1])


if __name__ == "__main__":
    unittest.main()
