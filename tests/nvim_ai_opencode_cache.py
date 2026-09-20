"""Cross-process compatibility cache regression; no accounts or provider requests."""
import json
import importlib.util
import os
from pathlib import Path
import shutil
import signal
import subprocess
import stat
import sys
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
RUNTIME = HERE.parent
SCRIPT = HERE / "fixtures/ai/opencode_cache.lua"


class CompatibilityCacheTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="nvim-ai-cache-test-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cache = self.root / "cache"
        self.executable = self.root / "fixture-executable"
        shutil.copyfile("/usr/bin/true", self.executable)
        self.executable.chmod(0o700)
        self.runtime = self.root / "plugins with spaces/draft.nvim"
        shutil.copytree(RUNTIME / "lua/ai", self.runtime / "lua/ai")
        (self.runtime / "scripts").mkdir()
        for name in ("nvim-ai-review.py", "nvim-ai-opencode-cache.py"):
            if (RUNTIME / "scripts" / name).exists():
                shutil.copyfile(RUNTIME / "scripts" / name, self.runtime / "scripts" / name)

    def run_editor(self, *, real=False, fail=False, passive=False, drift="", runtime=False,
                   host_path=None, platform_change=False):
        env = dict(os.environ, CACHE_TEST_DIRECTORY=str(self.cache),
                   CACHE_TEST_EXECUTABLE=str(self.executable), CACHE_TEST_REAL="1" if real else "0",
                   CACHE_TEST_FAIL="1" if fail else "0", NVIM_LOG_FILE="/dev/null",
                   CACHE_TEST_PASSIVE="1" if passive else "0", CACHE_TEST_DRIFT=drift,
                   DRAFT_TEST_RUNTIME=str(self.runtime))
        env["CACHE_TEST_RUNTIME"] = "1" if runtime else "0"
        env["XDG_CACHE_HOME"] = str(self.root / "xdg-cache")
        env["CACHE_TEST_PLATFORM_CHANGE"] = "1" if platform_change else "0"
        if host_path:
            env["PATH"] = str(host_path) + os.pathsep + env["PATH"]
        for key in ("TMUX", "TMUX_PANE", "NVIM_APPNAME"):
            env.pop(key, None)
        result = subprocess.run([shutil.which("nvim"), "--clean", "--headless", "-u", "NONE", "-i", "NONE",
            "--cmd", "lua vim.opt.rtp:prepend(vim.env.DRAFT_TEST_RUNTIME)", "-l", str(SCRIPT)],
            env=env, capture_output=True, timeout=25)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        return json.loads(result.stdout)

    def seed(self):
        result = self.run_editor()
        self.assertEqual((result["phase"], result["starts"]), ("ready", 12), result)
        return result

    def record(self):
        files = list(self.cache.glob("*.json"))
        self.assertEqual(len(files), 1)
        return files[0]

    def test_fresh_editor_reuses_success_without_restarting_opencode(self):
        self.seed()
        self.assertEqual(self.cache.stat().st_mode & 0o7777, 0o700)
        self.assertEqual(self.record().stat().st_mode & 0o7777, 0o600)
        second = self.run_editor()
        self.assertEqual((second["phase"], second["starts"]), ("ready", 0), second)

    def test_status_and_report_are_passive_even_with_a_valid_receipt(self):
        self.assertEqual(self.run_editor(passive=True)["starts"], 0)
        self.assertFalse(self.cache.exists())
        self.seed()
        self.assertEqual(self.run_editor(passive=True)["phase"], "not_checked")

    def test_executable_replacement_and_in_place_update_invalidate(self):
        self.seed()
        replacement = self.root / "replacement"
        shutil.copyfile(self.executable, replacement)
        replacement.chmod(0o700)
        replacement.replace(self.executable)
        self.seed()
        before = self.executable.stat()
        # Keep inode, size, and mtime: ctime must still invalidate the receipt.
        with self.executable.open("r+b") as stream:
            stream.seek(-1, 2)
            stream.write(b"x")
        os.utime(self.executable, ns=(before.st_atime_ns, before.st_mtime_ns))
        self.seed()

    def test_validator_and_policy_source_changes_invalidate(self):
        self.seed()
        for relative in ("lua/ai/backends/opencode_managed.lua",
                         "lua/ai/backends/opencode_validation.lua", "lua/ai/backends/init.lua",
                         "lua/ai/tools.lua", "scripts/nvim-ai-review.py",
                         "scripts/nvim-ai-opencode-cache.py"):
            with self.subTest(source=relative):
                target = self.runtime / relative
                with target.open("a") as stream:
                    stream.write("\n" + ("--" if relative.endswith(".lua") else "#") + " cache invalidation fixture\n")
                self.seed()

    def test_expiry_future_clock_schema_key_and_report_are_revalidated(self):
        self.seed()
        valid = json.loads(self.record().read_bytes())
        for field, value in (("expires_at", int(time.time()) - 1),
                             ("created_at", int(time.time()) + 60),
                             ("created_at", True), ("schema", 2), ("key", "0" * 64),
                             ("report", {})):
            with self.subTest(field=field, value=value):
                mutated = dict(valid, **{field: value})
                self.record().write_text(json.dumps(mutated))
                self.seed()
        for created in (int(time.time()) - 86401, int(time.time()) + 60):
            mutated = dict(valid, created_at=created, expires_at=created + 86400)
            self.record().write_text(json.dumps(mutated))
            self.seed()

    def test_host_tool_and_platform_changes_invalidate(self):
        self.seed()
        host_bin = self.root / "bin"
        host_bin.mkdir(mode=0o700)
        host = host_bin / "bwrap"
        shutil.copyfile("/usr/bin/true", host)
        host.chmod(0o700)
        self.assertEqual(self.run_editor(host_path=host_bin)["starts"], 12)
        self.assertEqual(self.run_editor(host_path=host_bin)["starts"], 0)
        replacement = host_bin / "replacement"
        shutil.copyfile(host, replacement)
        replacement.chmod(0o700)
        replacement.replace(host)
        self.assertEqual(self.run_editor(host_path=host_bin)["starts"], 12)
        self.seed()  # Restoring the original host tool is also a key change.
        self.assertEqual(self.run_editor(platform_change=True)["starts"], 12)
        self.assertEqual(self.run_editor(platform_change=True)["starts"], 0)
        self.seed()

    def test_mapped_ancestor_owner_is_allowed_but_cache_leaf_owner_is_not(self):
        spec = importlib.util.spec_from_file_location("cache", self.runtime / "scripts/nvim-ai-opencode-cache.py")
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        helper.directory_node(SimpleNamespace(st_mode=stat.S_IFDIR | 0o755, st_uid=65534))
        with self.assertRaises(ValueError):
            helper.directory_node(SimpleNamespace(st_mode=stat.S_IFDIR | 0o777, st_uid=65534))
        with self.assertRaises(ValueError):
            helper.directory_node(SimpleNamespace(st_mode=stat.S_IFDIR | 0o700, st_uid=65534), private=True)
        with self.assertRaises(ValueError):
            helper.private_node(SimpleNamespace(st_mode=stat.S_IFREG | 0o600, st_uid=65534, st_nlink=1))

    def test_weakened_cached_policy_never_grants_compatibility(self):
        self.seed()
        record = self.record()
        value = json.loads(record.read_bytes())
        value["report"]["agents"]["build"]["permission"] = []
        record.write_text(json.dumps(value))
        self.seed()
        self.assertEqual(self.run_editor()["starts"], 0)

    def test_source_changed_in_a_loaded_editor_cannot_reuse_or_publish(self):
        for phase in ("lookup", "audit"):
            with self.subTest(phase=phase):
                self.cache = self.root / ("cache-" + phase)
                if phase == "lookup":
                    self.seed()
                    before = self.record().read_bytes()
                result = self.run_editor(drift=phase)
                self.assertEqual((result["phase"], result["starts"]), ("ready", 12))
                if phase == "lookup":
                    self.assertEqual(self.record().read_bytes(), before)
                else:
                    self.assertFalse(self.cache.exists())
                self.seed()
                self.assertEqual(self.run_editor()["starts"], 0)

    def test_cache_helper_timeout_does_not_hold_up_or_fail_the_audit(self):
        helper = self.runtime / "scripts/nvim-ai-opencode-cache.py"
        helper.write_text("import time\ntime.sleep(5)\n")
        result = self.seed()
        self.assertLess(result["duration_ms"], 1500, result)
        self.assertFalse(self.cache.exists())

    def test_killed_cache_writer_leaves_private_untrusted_receipt(self):
        self.seed()
        receipt = json.loads(self.record().read_bytes())
        self.record().unlink()
        helper = self.runtime / "scripts/nvim-ai-opencode-cache.py"
        original = helper.read_text()
        marker = self.root / "writer-ready"
        needle = "                os.fsync(fd)\n"
        self.assertEqual(original.count(needle), 1)
        hook = (f"                Path({str(marker)!r}).write_text('ready')\n"
                "                time.sleep(30)\n" + needle)
        helper.write_text(original.replace(needle, hook, 1))
        request = {"directory": str(self.cache), "key": receipt["key"],
                   "report": receipt["report"]}
        child = subprocess.Popen([sys.executable, "-I", "-B", str(helper), "store"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env={"LANG": "C.UTF-8"}, umask=0o077)
        try:
            child.stdin.write(json.dumps(request).encode())
            child.stdin.close()
            child.stdin = None
            deadline = time.monotonic() + 5
            while not marker.exists() and child.poll() is None and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertTrue(marker.exists(), "copied helper did not reach the write boundary")
            child.kill()
            out, error = child.communicate(timeout=5)
            self.assertEqual(child.returncode, -signal.SIGKILL, out + error)
        finally:
            if child.poll() is None:
                child.kill()
            child.communicate(timeout=5)
            helper.write_text(original)
        leftovers = list(self.cache.glob(".receipt-*"))
        self.assertEqual(len(leftovers), 1)
        orphan = leftovers[0]
        before = orphan.read_bytes()
        node = orphan.lstat()
        self.assertTrue(stat.S_ISREG(node.st_mode))
        self.assertEqual((stat.S_IMODE(node.st_mode), node.st_uid, node.st_nlink),
                         (0o600, os.getuid(), 1))
        self.assertLessEqual(len(before), 65536)
        orphan_record = json.loads(before)
        for field in ("schema", "key", "report"):
            self.assertEqual(orphan_record[field], receipt[field])
        self.assertEqual(orphan_record["expires_at"] - orphan_record["created_at"], 86400)
        lookup = subprocess.run([sys.executable, "-I", "-B", str(helper), "lookup"],
            input=json.dumps({"directory": str(self.cache), "key": receipt["key"]}).encode(),
            capture_output=True, check=True, timeout=5, env={"LANG": "C.UTF-8"})
        self.assertEqual(json.loads(lookup.stdout), {"hit": False})
        self.seed()
        self.assertEqual(self.run_editor()["starts"], 0)
        self.assertEqual(orphan.read_bytes(), before)
        self.assertEqual(orphan.lstat().st_ino, node.st_ino)

    def test_corrupt_duplicate_oversize_and_nonfinite_json_are_misses(self):
        self.seed()
        valid = self.record().read_bytes()
        for raw in (b"{", b"x" * 65537,
                    b'{"schema":1,' + valid[1:],
                    valid.replace(b'"schema":1', b'"schema":NaN'),
                    b"[" * 2000 + b"]" * 2000):
            with self.subTest(prefix=raw[:30]):
                self.record().write_bytes(raw)
                self.seed()

    def test_public_file_and_directory_modes_are_not_repaired_or_trusted(self):
        self.seed()
        record = self.record()
        record.chmod(0o644)
        self.seed()
        self.assertEqual(record.stat().st_mode & 0o777, 0o644)
        record.chmod(0o600)
        self.cache.chmod(0o755)
        self.seed()
        self.assertEqual(self.cache.stat().st_mode & 0o777, 0o755)

    def test_symlink_and_hardlink_receipts_are_neither_followed_nor_replaced(self):
        self.seed()
        record = self.record()
        victim = self.root / "victim"
        record.replace(victim)
        original = victim.read_bytes()
        record.symlink_to(victim)
        self.seed()
        self.assertTrue(record.is_symlink())
        self.assertEqual(victim.read_bytes(), original)
        record.unlink()
        os.link(victim, record)
        self.seed()
        self.assertEqual(record.stat().st_nlink, 2)
        self.assertEqual(victim.read_bytes(), original)

    def test_symlink_parent_and_public_ancestor_are_not_trusted(self):
        self.seed()
        original = self.record().read_bytes()
        victim = self.root / "victim"
        self.cache.replace(victim)
        self.cache.symlink_to(victim, target_is_directory=True)
        self.seed()
        self.assertEqual((victim / "compatibility.json").read_bytes(), original)
        self.cache = self.root / "public" / "private"
        self.cache.parent.mkdir(mode=0o777)
        self.cache.parent.chmod(0o777)
        self.seed()
        self.assertFalse(self.cache.exists())

    def test_missing_directory_lookup_does_not_create_it_and_failures_are_not_cached(self):
        first = self.run_editor(fail=True)
        self.assertEqual((first["phase"], first["starts"]), ("failed", 1))
        self.assertFalse(self.cache.exists())
        self.seed()

    def test_non_directory_cache_is_a_best_effort_miss(self):
        self.cache.write_text("untouched")
        self.seed()
        self.assertEqual(self.cache.read_text(), "untouched")

    def test_concurrent_publication_leaves_one_complete_private_receipt(self):
        self.seed()
        record = self.record()
        receipt = json.loads(record.read_bytes())
        record.unlink()
        request = json.dumps({"directory": str(self.cache), "key": receipt["key"],
                              "report": receipt["report"]}).encode()

        def publish(_):
            # Exercise completed atomic writes independently of Neovim's 250 ms
            # best-effort cache deadline; timeout behavior has its own test.
            result = subprocess.run([sys.executable, "-I", "-B",
                str(self.runtime / "scripts/nvim-ai-opencode-cache.py"), "store"],
                input=request, capture_output=True, timeout=5, check=True, env={"LANG": "C.UTF-8"})
            self.assertEqual(result.stderr, b"")
            return json.loads(result.stdout)

        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(publish, range(4)))
        for result in results:
            self.assertEqual(result, {"stored": True})
        self.assertEqual(list(self.cache.iterdir()), [self.record()])
        self.assertEqual(self.run_editor()["starts"], 0)

    @unittest.skipUnless(os.environ.get("NVIM_AI_CACHE_REAL") == "1", "opt-in installed OpenCode audit")
    def test_installed_opencode_cold_then_fresh_editor_warm(self):
        cold = self.run_editor(real=True)
        self.assertEqual((cold["phase"], cold["starts"]), ("ready", 12), cold)
        warm = self.run_editor(real=True)
        self.assertEqual((warm["phase"], warm["starts"]), ("ready", 0), warm)
        print(f"\nInstalled OpenCode: cold {cold['duration_ms']:.1f} ms / 12 probes; "
              f"fresh-editor warm {warm['duration_ms']:.1f} ms / 0 probes")

    @unittest.skipUnless(os.environ.get("NVIM_AI_CACHE_REAL") == "1", "opt-in normal runtime audit")
    def test_normal_runtime_uses_the_default_persistent_cache(self):
        self.cache = self.root / "xdg-cache/nvim/draft.nvim/opencode-compat"
        self.assertEqual(self.run_editor(runtime=True, passive=True)["phase"], "not_checked")
        self.assertFalse(self.cache.exists())
        cold = self.run_editor(runtime=True)
        self.assertEqual((cold["phase"], cold["starts"]), ("ready", 12), cold)
        self.record()
        warm = self.run_editor(runtime=True)
        self.assertEqual((warm["phase"], warm["starts"]), ("ready", 0), warm)
        print(f"\nNormal runtime: cold {cold['duration_ms']:.1f} ms / 12 probes; "
              f"fresh-editor warm {warm['duration_ms']:.1f} ms / 0 probes")


if __name__ == "__main__":
    unittest.main()
