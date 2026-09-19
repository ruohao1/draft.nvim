"""Retained-store file/process seam; opaque fixture files, never SQLite internals."""
import importlib.util
import os
from pathlib import Path
import shutil
import stat
import tempfile
import time
import unittest
from unittest import mock


HERE = Path(__file__).resolve().parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE.parent / "scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


storage = load("nvim-ai-conversation-store")
staging = load("nvim-ai-staged")


class StoreTest(unittest.TestCase):
    def setUp(self):
        self.parent = Path(tempfile.mkdtemp(prefix="nvim-ai-store-test-", dir="/tmp"))
        self.neighbor = self.parent / "unrelated.txt"
        self.neighbor.write_bytes(b"leave this alone\n")
        self.store = storage.Store(self.parent)
        self.workers, self.serial = [], 0
        self.addCleanup(self.cleanup)
        self.peer = self.parent / "peer"
        shutil.copyfile(HERE / "fixtures/ai/acp_store_peer.py", self.peer)
        self.peer.chmod(0o700)

    def cleanup(self):
        for worker in self.workers:
            result = worker.close()
            if not result.reaped or not result.output_closed:
                raise AssertionError("Unproven test worker exit; scratch evidence retained: " + str(self.parent))
        if self.workers:
            try:
                self.store.stop(outcome="failed")
            except storage.Refused:
                pass
        self.store.close()
        shutil.rmtree(self.parent)

    def start_worker(self, **options):
        self.serial += 1
        task = self.parent / ("worker-" + str(self.serial))
        for name in ("home", "config", "data", "cache", "state"):
            (task / "agent" / name).mkdir(mode=0o700, parents=True)
        (task / "staging").mkdir(mode=0o700)
        command, env = staging.sandbox({"bwrap": os.path.realpath(shutil.which("bwrap")),
                                       "opencode": str(self.peer)}, task, {})
        worker = self.store.start(command, env=env, rpc_timeout=1, stop_timeout=.2, **options)
        self.workers.append(worker)
        return worker

    def seed_stopped_store(self):
        worker = self.start_worker()
        worker.request("fixture/create-state", {})
        self.store.stop(outcome="completed")

    def test_new_store_is_private_and_cleanup_is_limited_to_its_own_root(self):
        for directory in (self.store.root, self.store.path):
            node = directory.lstat()
            self.assertTrue(stat.S_ISDIR(node.st_mode))
            self.assertEqual((stat.S_IMODE(node.st_mode), node.st_uid), (0o700, os.getuid()))
        self.assertEqual(self.store.check(), {})
        self.store.close()
        self.store.close()
        self.assertFalse(self.store.root.exists())
        self.assertEqual(self.neighbor.read_bytes(), b"leave this alone\n")

    def test_only_stopped_workers_can_handoff_or_remove_the_retained_store(self):
        first = self.start_worker()
        with self.assertRaises(storage.Refused):
            self.start_worker()
        with self.assertRaises(storage.Refused):
            self.store.close()
        self.assertTrue(self.store.root.exists())
        first.request("fixture/create-state", {})
        self.assertTrue(self.store.stop(outcome="completed").settled)
        self.assertEqual(self.store.check(), {"opencode.db": 7, "opencode.db-wal": 4, "opencode.db-shm": 4})
        second = self.start_worker()
        self.assertEqual(second.request("fixture/report-state", {})["names"],
                         ["opencode.db", "opencode.db-shm", "opencode.db-wal"])
        self.store.stop(outcome="completed")
        self.store.close()
        self.assertFalse(self.store.root.exists())
        self.assertEqual(self.neighbor.read_bytes(), b"leave this alone\n")

    def test_live_growth_is_refused_even_when_worker_stops_sending_messages(self):
        worker = self.start_worker()
        started = time.monotonic()
        with self.assertRaisesRegex(RuntimeError, "state check"):
            worker.request("fixture/grow-and-stall", {}, timeout=2)
        self.assertLess(time.monotonic() - started, 1.5)
        with self.assertRaisesRegex(storage.Refused, "size budget"):
            self.store.stop(outcome="completed")
        with self.assertRaises(storage.Refused):
            self.start_worker()
        self.store.close()  # Explicit discard is safe only now that exit is proven.
        self.assertEqual(self.neighbor.read_bytes(), b"leave this alone\n")

    def test_directory_substitution_is_neither_adopted_nor_cleaned(self):
        for directory in ("root", "backend"):
            with self.subTest(directory=directory):
                self.store.close()
                self.store = storage.Store(self.parent)
                self.seed_stopped_store()
                target = self.store.root if directory == "root" else self.store.path
                retained = self.parent / "original-owned-directory"
                target.rename(retained)
                target.mkdir(mode=0o700)
                sentinel = target / "unowned.txt"
                sentinel.write_bytes(b"do not delete\n")
                try:
                    with self.assertRaises(storage.Refused):
                        self.store.check()
                    with self.assertRaises(storage.Refused):
                        self.start_worker()
                    with self.assertRaises(storage.Refused):
                        self.store.close()
                    self.assertEqual(sentinel.read_bytes(), b"do not delete\n")
                finally:
                    sentinel.unlink()
                    target.rmdir()
                    retained.rename(target)
                with self.assertRaises(storage.Refused):
                    self.start_worker()  # Restoring paths does not clear taint.

    def test_symlinked_store_path_cannot_redirect_validation_or_cleanup(self):
        self.seed_stopped_store()
        retained = self.parent / "original-backend"
        self.store.path.rename(retained)
        self.store.path.symlink_to(self.parent, target_is_directory=True)
        try:
            with self.assertRaises(storage.Refused):
                self.store.check()
            with self.assertRaises(storage.Refused):
                self.store.close()
            self.assertEqual(self.neighbor.read_bytes(), b"leave this alone\n")
        finally:
            self.store.path.unlink()
            retained.rename(self.store.path)

    def test_unsafe_artifacts_are_rejected_before_any_cleanup(self):
        for case in ("unexpected", "mode", "hardlink", "symlink", "fifo", "directory"):
            with self.subTest(case=case):
                self.store.close()
                self.store = storage.Store(self.parent)
                self.seed_stopped_store()
                database = self.store.path / "opencode.db"
                backup = self.parent / "opaque-backup"
                extra = self.store.path / "unexpected-secret-name"
                if case == "unexpected":
                    extra.write_bytes(b"fixture only\n")
                elif case == "mode":
                    database.chmod(0o644)
                elif case == "hardlink":
                    os.link(database, backup)
                else:
                    database.rename(backup)
                    if case == "symlink":
                        database.symlink_to(self.neighbor)
                    elif case == "fifo":
                        os.mkfifo(database, mode=0o600)
                    else:
                        database.mkdir(mode=0o700)
                try:
                    with self.assertRaises(storage.Refused) as error:
                        self.store.check()
                    self.assertNotIn("unexpected-secret-name", str(error.exception))
                    with self.assertRaises(storage.Refused):
                        self.store.close()
                    self.assertTrue((self.store.path / "opencode.db-wal").exists(),
                                    "Cleanup must preflight every entry before deleting any")
                    self.assertEqual(self.neighbor.read_bytes(), b"leave this alone\n")
                finally:
                    if case == "unexpected":
                        extra.unlink()
                    elif case == "mode":
                        database.chmod(0o600)
                    elif case == "hardlink":
                        backup.unlink()
                    else:
                        database.rmdir() if case == "directory" else database.unlink()
                        backup.rename(database)

    def test_idle_file_replacement_with_identical_bytes_does_not_authorize_resume(self):
        self.seed_stopped_store()
        database = self.store.path / "opencode.db"
        replacement = self.parent / "opaque-replacement"
        replacement.write_bytes(b"opaque\n")  # Synthetic fixture, not a real database.
        replacement.chmod(0o600)
        replacement.replace(database)
        with self.assertRaisesRegex(storage.Refused, "changed while no worker"):
            self.start_worker()

    def test_idle_in_place_change_with_restored_mtime_is_still_refused(self):
        self.seed_stopped_store()
        database = self.store.path / "opencode.db"
        before = database.stat()
        database.write_bytes(b"tamper\n")  # Same-size opaque fixture, never a SQLite DB.
        os.utime(database, ns=(before.st_atime_ns, before.st_mtime_ns))
        with self.assertRaisesRegex(storage.Refused, "changed while no worker"):
            self.start_worker()

    def test_directory_permission_drift_blocks_reuse_and_cleanup(self):
        for directory in ("root", "backend"):
            with self.subTest(directory=directory):
                self.store.close()
                self.store = storage.Store(self.parent)
                self.seed_stopped_store()
                target = self.store.root if directory == "root" else self.store.path
                target.chmod(0o755)
                try:
                    with self.assertRaises(storage.Refused):
                        self.start_worker()
                    with self.assertRaises(storage.Refused):
                        self.store.close()
                    self.assertTrue((self.store.path / "opencode.db").exists())
                finally:
                    target.chmod(0o700)

    def test_missing_sidecar_is_not_silently_recreated_by_another_worker(self):
        self.seed_stopped_store()
        (self.store.path / "opencode.db-wal").unlink()
        with self.assertRaisesRegex(storage.Refused, "changed while no worker"):
            self.start_worker()

    def test_aggregate_budget_counts_database_and_both_sidecars(self):
        worker = self.start_worker()
        try:
            worker.request("fixture/combined-budget", {})
        except RuntimeError:
            pass  # The live guard may win the race with the peer's reply.
        with self.assertRaisesRegex(storage.Refused, "size budget"):
            self.store.stop(outcome="completed")
        with self.assertRaises(storage.Refused):
            self.start_worker()

    def test_forced_worker_exit_taints_continuation_despite_valid_file_metadata(self):
        worker = self.start_worker()
        worker.request("fixture/ignore-eof", {})
        with self.assertRaisesRegex(storage.Refused, "outcome cannot authorize"):
            self.store.stop(outcome="completed")
        with self.assertRaises(storage.Refused):
            self.start_worker()
        self.assertTrue(self.store.path.exists(), "Forced exit must not implicitly discard evidence")
        self.store.close()  # Explicit discard after the actual supervisor was reaped.

    def test_failed_semantic_outcome_taints_an_otherwise_clean_exit(self):
        worker = self.start_worker()
        worker.request("fixture/create-state", {})
        with self.assertRaises(storage.Refused):
            self.store.stop(outcome="failed")
        with self.assertRaises(storage.Refused):
            self.start_worker()

    def test_clean_exit_without_a_database_is_not_reusable_state(self):
        worker = self.start_worker()
        worker.request("fixture/report-state", {})
        with self.assertRaisesRegex(storage.Refused, "missing or empty"):
            self.store.stop(outcome="completed")
        with self.assertRaises(storage.Refused):
            self.start_worker()

    def test_cleanup_io_failure_is_visible_and_cannot_authorize_a_new_worker(self):
        self.seed_stopped_store()
        # Inject only an OS filesystem failure; do not mock the store or worker.
        with mock.patch("os.fsync", side_effect=OSError("fixture disk failure")):
            with self.assertRaisesRegex(storage.Refused, "cleanup incomplete"):
                self.store.close()
        self.assertTrue(self.store.root.exists())
        with self.assertRaises(storage.Refused):
            self.start_worker()
        self.assertEqual(self.neighbor.read_bytes(), b"leave this alone\n")

    def test_backend_mount_does_not_expose_its_host_owner_or_neighboring_files(self):
        worker = self.start_worker()
        result = worker.request("fixture/check-isolation", {"paths": [str(self.store.root), str(self.neighbor)]})
        self.assertEqual(result, {"host_visible": False})
        worker.request("fixture/create-state", {})
        self.store.stop(outcome="completed")

    def test_symlinked_parent_is_refused_without_creating_an_owner_root(self):
        link = self.parent / "linked-parent"
        link.symlink_to(self.store.root, target_is_directory=True)
        with self.assertRaises(storage.Refused):
            storage.Store(link)
        self.assertEqual(list(self.store.root.iterdir()), [self.store.path])


if __name__ == "__main__":
    unittest.main()
