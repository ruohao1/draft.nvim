"""Codex state ownership through real pipes and opaque fixture artifacts."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
THREAD = "00000000-0000-4000-8000-000000000001"
ROLLOUT = "sessions/2026/10/20/rollout-2026-10-20T00-00-00-" + THREAD + ".jsonl"


def helper(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


storage = helper("nvim-ai-codex-store")
runtime = helper("nvim-ai-codex-runtime")
spec = importlib.util.spec_from_file_location("fixture-auth", ROOT / "tests/fixtures/ai/codex_auth.py")
auth_fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(auth_fixture)


class StoreTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="draft-codex-state-", dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.parent = Path(self.temporary.name)
        self.source = self.parent / "auth.json"
        self.source.write_text('{"OPENAI_API_KEY":"synthetic-original"}')
        self.source.chmod(0o600)
        self.neighbor = self.parent / "unrelated.txt"
        self.neighbor.write_text("leave this alone")
        self.store = storage.Store(self.parent)
        self.store.initialize(str(self.source))
        self.workers = []
        self.addCleanup(self.cleanup)
        self.peer = self.parent / "codex"
        shutil.copyfile(ROOT / "tests/fixtures/ai/conversation_codex.py", self.peer)
        self.peer.chmod(0o700)
        host = self.peer.with_name("codex-code-mode-host")
        host.write_text("#!/bin/sh\nexit 0\n")
        host.chmod(0o700)
        self.serial = 0

    def cleanup(self):
        for worker in self.workers:
            result = worker.close()
            self.assertTrue(result.reaped and result.output_closed)
        if self.workers:
            try:
                self.store.stop(outcome="failed")
            except storage.Refused:
                pass
        self.store.close()

    def start(self, **options):
        self.serial += 1
        task = self.parent / f"turn-{self.serial}"
        (task / "staging").mkdir(mode=0o700, parents=True)
        (task / "staging/example.txt").write_text("selected copy")
        argv, env = runtime.sandbox(
            {"codex": str(self.peer), "bwrap": os.path.realpath(shutil.which("bwrap")),
             "model": "openai/gpt-5.4"}, task, self.store)
        self.last_command, self.last_env = argv, env
        worker = self.store.start(argv, env=env, rpc_timeout=1, stop_timeout=.2, **options)
        self.workers.append(worker)
        return worker

    def seed(self):
        self.start().request("fixture/codex-state", {"thread": THREAD})
        self.store.stop(outcome="completed", session=THREAD)

    def owned(self):
        self.store.close()
        self.directory = self.parent / "dedicated"
        self.directory.mkdir(mode=0o700)
        self.auth_path = self.directory / "auth.json"
        self.auth_path.write_text(json.dumps(auth_fixture.bundle()))
        self.auth_path.chmod(0o600)
        self.store = storage.Store(self.parent)
        self.store.initialize(auth_store=str(self.directory))
        self.store.acquire_auth()

    def test_owned_mount_preserves_tokens_and_does_not_leak_descriptors(self):
        self.owned()
        identities = [[os.fstat(fd).st_dev, os.fstat(fd).st_ino] for fd in self.store.auth_fds]
        worker = self.start()
        self.assertIn("--bind-fd", self.last_command)
        self.assertIn("--sync-fd", self.last_command)
        self.assertNotIn(str(self.directory), self.last_command)
        self.assertNotIn("--as-pid-1", self.last_command)
        self.assertNotIn("OPENAI_API_KEY", self.last_env)
        result = worker.request("fixture/auth-isolation", {"identities": identities})
        self.assertEqual(result, {"inherited": False, "lock_absent": True})
        self.assertEqual((self.store.path / "auth.json").read_bytes(), b"")
        worker.request("fixture/rotate-auth", {"owned": True})
        self.store.stop(outcome="completed")
        self.assertEqual(self.store.auth_fds, ())
        self.assertTrue(json.loads(self.auth_path.read_bytes())["tokens"]["refresh_token"]
                        == "synthetic-refresh-1", "Refreshed auth was not persisted")
        self.store.acquire_auth()
        second = self.start()
        self.assertEqual(second.request("fixture/auth-generation", {}), {"refreshed": True})
        self.store.stop(outcome="completed")
        self.store.close()
        self.assertTrue(self.auth_path.exists())
        self.assertTrue((self.directory / ".draft.lock").exists())

    def test_owned_launch_failure_releases_without_overwriting_credentials(self):
        self.owned()
        original = self.auth_path.read_bytes()
        for options in ({"pass_fds": ()}, {"guard": None}, {"wire": "codex"}):
            with self.assertRaises(storage.Refused):
                self.store.start(["/not-used"], env={}, **options)
        with self.assertRaises(OSError):
            self.store.start(["/does-not-exist"], env={})
        self.assertEqual(self.store.auth_fds, ())
        self.assertTrue(self.auth_path.read_bytes() == original, "Auth changed on launch failure")
        self.store.acquire_auth()
        self.store.close()
        storage.auth.Lease(str(self.directory)).close()

    def test_owned_sync_failure_preserves_auth_and_refuses_reuse(self):
        self.owned()
        self.start().request("fixture/rotate-auth", {"owned": True})
        with mock.patch.object(storage.auth.os, "fsync", side_effect=OSError("PRIVATE")):
            with self.assertRaises(storage.Refused):
                self.store.stop(outcome="completed")
        self.assertEqual(self.store.auth_diagnostic, "auth_persistence")
        self.assertEqual(self.store.auth_fds, ())
        with self.assertRaises(storage.Refused):
            self.store.acquire_auth()
        self.store.close()
        storage.auth.Lease(str(self.directory)).close()

    def test_owned_corrupt_or_changed_identity_never_restores_a_seed(self):
        self.owned()
        self.start().request("fixture/rotate-auth", {"corrupt": True})
        with self.assertRaises(storage.Refused):
            self.store.stop(outcome="completed")
        self.assertEqual(self.store.auth_diagnostic, "auth_persistence")
        self.assertEqual(self.auth_path.read_bytes(), b"{")
        self.assertEqual(self.store.auth_fds, ())
        self.store.close()
        self.assertEqual(self.auth_path.read_bytes(), b"{")

    def test_owned_forced_exit_settles_credentials_but_never_reuses_state(self):
        self.owned()
        worker = self.start()
        worker.request("fixture/rotate-auth", {"owned": True})
        worker.request("fixture/blocked", {})
        with self.assertRaises(storage.Refused):
            self.store.stop(outcome="completed")
        self.assertTrue(worker.close().forced)
        self.assertEqual(self.store.auth_fds, ())
        with self.assertRaises(storage.Refused):
            self.store.acquire_auth()
        lease = storage.auth.Lease(str(self.directory))
        try:
            lease.settle()
        finally:
            lease.close()

    def test_owned_unknown_exit_closes_only_local_lease_and_refuses_cleanup(self):
        self.owned()
        worker = self.start()
        worker.request("fixture/auth-generation", {})
        lease = self.store._lease
        borrowed = os.dup(lease.lock_fd)
        try:
            with mock.patch.object(worker, "close", return_value=storage.acp.Exit(False, False, True, None, None, True)):
                with self.assertRaises(storage.Refused):
                    self.store.stop(outcome="failed")
            self.assertEqual(self.store.auth_fds, ())
            with self.assertRaises(storage.Refused):
                self.store.close()
            with self.assertRaisesRegex(storage.auth.Refused, "auth_busy"):
                storage.auth.Lease(str(self.directory))
        finally:
            os.close(borrowed)

    def test_private_auth_import_and_rotation(self):
        original = self.source.read_bytes()
        first = self.start()
        first.request("fixture/codex-state", {"thread": THREAD})
        first.request("fixture/rotate-auth", {})
        self.store.stop(outcome="completed", session=THREAD)
        copied = (self.store.path / "auth.json").read_bytes()
        self.assertEqual(json.loads(copied), {"OPENAI_API_KEY": "synthetic-refreshed"})
        second = self.start()
        self.assertEqual(second.request("fixture/auth-generation", {}), {"refreshed": True})
        self.store.stop(outcome="completed", session=THREAD)
        self.assertEqual(self.source.read_bytes(), original)
        self.assertEqual(stat.S_IMODE((self.store.path / "auth.json").stat().st_mode), 0o600)

    def test_closed_store_policy_and_seal(self):
        self.seed()
        values = self.store.check()
        self.assertIn("state_5.sqlite", values)
        self.assertIn("models_cache.json", values)
        self.assertIn(ROLLOUT, values)
        with (self.store.path / ROLLOUT).open("ab") as output:
            output.write(b"tampered")
        with self.assertRaises(storage.Refused):
            self.store.check()
        with self.assertRaises(storage.Refused):
            self.start()
        self.store.close()
        self.assertFalse(self.store.root.exists())
        self.assertEqual(self.neighbor.read_text(), "leave this alone")

    def test_rollback_journal_lifetime_reuse_and_seal(self):
        self.seed()
        journal = self.store.path / "memories_1.sqlite-journal"
        self.assertEqual(stat.S_IMODE(journal.stat().st_mode), 0o600)
        self.assertIn(journal.name, self.store.check())
        worker = self.start()
        worker.request("fixture/codex-state", {"thread": THREAD, "remove_journal": True})
        self.assertNotIn(journal.name, self.store.check())
        worker.request("fixture/codex-state", {"thread": THREAD})
        self.assertIn(journal.name, self.store.check())
        self.store.stop(outcome="completed", session=THREAD)
        with journal.open("ab") as output:
            output.write(b"tampered")
        with self.assertRaises(storage.Refused):
            self.start()
        self.store.close()
        self.assertFalse(self.store.root.exists())
        self.assertEqual(self.source.read_text(), '{"OPENAI_API_KEY":"synthetic-original"}')

    def test_unknown_or_nested_journals_refuse_cleanup_before_deletion(self):
        self.seed()
        for name in ("unknown.sqlite-journal", "memories_2.sqlite-journal",
                     "auth.json-journal", "sessions/memories_1.sqlite-journal"):
            with self.subTest(name=name):
                target = self.store.path / name
                target.write_bytes(b"opaque")
                target.chmod(0o600)
                try:
                    with self.assertRaises(storage.Refused):
                        self.store.close()
                    self.assertTrue((self.store.path / "state_5.sqlite").exists())
                finally:
                    target.unlink()

    def test_rollback_journal_counts_toward_the_byte_budget(self):
        worker = self.start()
        worker.request("fixture/grow-codex-state", {"name": "memories_1.sqlite-journal"})
        with self.assertRaisesRegex(storage.Refused, "byte budget"):
            self.store.stop(outcome="completed")
        self.store.close()
        self.assertFalse(self.store.root.exists())

    def test_metadata_inspection_never_reads_payload_bytes(self):
        self.seed()
        original_open = storage.os.open
        def metadata_open(path, flags, *args, **kwargs):
            self.assertTrue(flags & (os.O_PATH | os.O_DIRECTORY),
                            "Store tried to open payload contents")
            return original_open(path, flags, *args, **kwargs)
        with mock.patch.object(storage.os, "open", side_effect=metadata_open):
            values = self.store.check()
            self.assertIn(ROLLOUT, values)
            self.assertIn("models_cache.json", values)
            self.assertIn("memories_1.sqlite-journal", values)

    def test_missing_rollout_and_forced_exit_cannot_resume(self):
        worker = self.start()
        worker.request("fixture/codex-state", {"thread": THREAD, "rollout": False})
        with self.assertRaises(storage.Refused):
            self.store.stop(outcome="completed", session=THREAD)
        with self.assertRaises(storage.Refused):
            self.start()
        self.store.close()
        self.store = storage.Store(self.parent)
        self.store.initialize(str(self.source))
        worker = self.start()
        worker.request("fixture/blocked", {})
        with self.assertRaises(storage.Refused):
            self.store.stop(outcome="completed")
        self.assertTrue(worker.close().forced)
        with self.assertRaises(storage.Refused):
            self.start()

    def test_live_store_cannot_be_removed_or_launched_twice(self):
        self.start()
        with self.assertRaises(storage.Refused):
            self.start()
        with self.assertRaises(storage.Refused):
            self.store.close()

    def test_replaced_directory_is_not_adopted_or_deleted(self):
        self.seed()
        owned = self.parent / "held-store"
        self.store.path.rename(owned)
        self.store.path.mkdir(mode=0o700)
        sentinel = self.store.path / "foreign"
        sentinel.write_text("do not remove")
        try:
            with self.assertRaises(storage.Refused):
                self.store.check()
            with self.assertRaises(storage.Refused):
                self.store.close()
            self.assertEqual(sentinel.read_text(), "do not remove")
        finally:
            sentinel.unlink()
            self.store.path.rmdir()
            owned.rename(self.store.path)

    def test_links_modes_and_unknown_entries_refuse_cleanup_before_deletion(self):
        self.seed()
        for case in ("extra", "mode", "auth-mode", "symlink", "hardlink", "fifo", "depth",
                     "cache-mode", "cache-symlink", "cache-hardlink",
                     "journal-mode", "journal-symlink", "journal-hardlink", "journal-fifo",
                     "journal-directory"):
            with self.subTest(case=case):
                target = self.store.path / ("models_cache.json" if case.startswith("cache-") else
                    "memories_1.sqlite-journal" if case.startswith("journal-") else ROLLOUT)
                case = case.removeprefix("cache-").removeprefix("journal-")
                extra = self.store.path / "unapproved-secret-name"
                backup = self.parent / "saved-rollout"
                if case == "extra":
                    extra.write_bytes(b"x")
                elif case == "mode":
                    target.chmod(0o644)
                elif case == "auth-mode":
                    (self.store.path / "auth.json").chmod(0o644)
                elif case == "hardlink":
                    os.link(target, backup)
                elif case == "depth":
                    extra = self.store.path / "sessions/2026/10/20/a/b/c/d/e"
                    extra.mkdir(mode=0o700, parents=True)
                else:
                    target.rename(backup)
                    if case == "symlink":
                        target.symlink_to(self.neighbor)
                    elif case == "directory":
                        target.mkdir(mode=0o700)
                    else:
                        os.mkfifo(target, mode=0o600)
                try:
                    with self.assertRaises(storage.Refused) as error:
                        self.store.check()
                    self.assertNotIn("unapproved-secret-name", str(error.exception))
                    with self.assertRaises(storage.Refused):
                        self.store.close()
                    self.assertTrue((self.store.path / "state_5.sqlite").exists())
                finally:
                    if case == "extra":
                        extra.unlink()
                    elif case == "mode":
                        target.chmod(0o600)
                    elif case == "auth-mode":
                        (self.store.path / "auth.json").chmod(0o600)
                    elif case == "depth":
                        shutil.rmtree(self.store.path / "sessions/2026/10/20/a")
                    elif case == "hardlink":
                        backup.unlink()
                    else:
                        target.rmdir() if case == "directory" else target.unlink()
                        backup.rename(target)

    def test_foreign_payload_owner_refuses_cleanup_before_any_deletion(self):
        self.seed()
        original_stat, original_fstat = storage.os.stat, storage.os.fstat
        def foreign_owner(node):
            if stat.S_ISREG(node.st_mode):
                return SimpleNamespace(**{key: (node.st_uid + 1 if key == "st_uid" else getattr(node, key))
                                          for key in dir(node) if key.startswith("st_")})
            return node
        with mock.patch.object(storage.os, "fstat", side_effect=lambda fd: foreign_owner(original_fstat(fd))), \
             mock.patch.object(storage.os, "stat", side_effect=lambda *a, **kw: foreign_owner(original_stat(*a, **kw))):
            with self.assertRaises(storage.Refused):
                self.store.close()
        self.assertTrue((self.store.path / "state_5.sqlite").exists())

    def test_replaced_ancestor_during_cleanup_cannot_lose_owned_payload(self):
        self.seed()
        original = storage.review.open_parent
        saved = self.parent / "saved-sessions"
        replaced = False
        def replace_ancestor(*args, **kwargs):
            nonlocal replaced
            if not replaced:
                replaced = True
                (self.store.path / "sessions").rename(saved)
                (self.store.path / "sessions/2026/10").mkdir(mode=0o700, parents=True)
                (saved / "2026/10/20").rename(self.store.path / "sessions/2026/10/20")
            return original(*args, **kwargs)
        try:
            with mock.patch.object(storage.review, "open_parent", side_effect=replace_ancestor):
                with self.assertRaises(storage.Refused):
                    self.store.close()
            self.assertTrue((self.store.path / ROLLOUT).exists())
        finally:
            if replaced:
                if (self.store.path / "sessions/2026/10/20").exists():
                    (self.store.path / "sessions/2026/10/20").rename(saved / "2026/10/20")
                shutil.rmtree(self.store.path / "sessions")
                saved.rename(self.store.path / "sessions")

    def test_runtime_profile_is_readonly_and_ambient_environment_is_absent(self):
        with mock.patch.dict(os.environ, {"OPENAI_API_KEY": "ambient-secret", "CODEX_HOME": "/external",
                                          "CODEX_CONFIG_FILE": "/external/config.toml"}):
            worker = self.start()
            self.assertEqual(worker.request("fixture/profile-isolation", {}), {
                "readonly": True, "ambient_absent": True, "scratch_separate": True})
        self.store.stop(outcome="completed")
        self.assertEqual(list((self.store.path / "tmp").iterdir()), [])

    def test_size_and_entry_budgets_refuse_without_reading_large_files(self):
        worker = self.start()
        worker.request("fixture/codex-state", {"thread": THREAD})
        worker.request("fixture/grow-codex-state", {})
        with self.assertRaises(storage.Refused):
            self.store.stop(outcome="completed", session=THREAD)
        self.store.close()
        self.store = storage.Store(self.parent)
        self.store.initialize(str(self.source))
        self.start().request("fixture/codex-many-entries", {})
        with self.assertRaises(storage.Refused):
            self.store.stop(outcome="completed")
        with self.assertRaises(storage.Refused):
            self.store.close()
        for path in (self.store.path / "thread-writer-locks").iterdir():
            path.unlink()


if __name__ == "__main__":
    unittest.main()
