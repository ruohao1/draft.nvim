"""Settings persistence and public setup across fresh editors; no credentials/network."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor

HERE = Path(__file__).resolve().parent
RUNTIME = HERE.parent
HELPER = RUNTIME / "scripts/nvim-ai-staged-settings.py"
ENABLED = {"schema": 1, "enabled": True, "model": "fixture/model"}
DISABLED = {"schema": 1, "enabled": False}


class StagedSettingsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="nvim-ai-preferences-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.directory = self.root / "state" / "staged"
        self.record = self.directory / "settings.json"
        self.auth = self.root / "auth.json"
        # Not even JSON: persisting its path must never parse credentials.
        self.auth.write_bytes(b"secret sentinel -- never copy into settings\n")
        self.auth.chmod(0o600)

    def invoke(self, operation="load", settings=None, raw=None):
        request = {"directory": str(self.directory)}
        if settings is not None:
            request["settings"] = settings
        result = subprocess.run([sys.executable, "-I", "-B", str(HELPER), operation],
            input=raw if raw is not None else json.dumps(request).encode(),
            capture_output=True, timeout=5, check=True)
        self.assertEqual(result.stderr, b"")
        return json.loads(result.stdout)

    def editor(self, action="read"):
        env = dict(os.environ, STAGED_TEST_DIRECTORY=str(self.directory), STAGED_TEST_ACTION=action,
                   STAGED_TEST_AUTH=str(self.auth), XDG_DATA_HOME=str(self.root / "data"),
                   XDG_STATE_HOME=str(self.root / "state"), NVIM_LOG_FILE="/dev/null",
                   DRAFT_TEST_RUNTIME=str(RUNTIME))
        for key in ("TMUX", "TMUX_PANE", "NVIM_APPNAME"):
            env.pop(key, None)
        result = subprocess.run([shutil.which("nvim"), "--clean", "--headless", "-u", "NONE", "-i", "NONE",
            "--cmd", "lua vim.opt.rtp:prepend(vim.env.DRAFT_TEST_RUNTIME)",
            "-l", str(HERE / "fixtures/ai/staged_settings.lua")],
            env=env, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        return json.loads(result.stdout)

    def seed(self, settings=ENABLED):
        result = self.invoke("save", settings)
        self.assertTrue(result["ok"], result)
        return result

    def test_missing_settings_are_disabled_without_creating_directories(self):
        self.assertEqual(self.invoke(), {"ok": True, "settings": DISABLED})
        self.assertFalse(self.directory.exists())

    def test_private_roundtrip_persists_only_preferences(self):
        expected = dict(ENABLED, auth_file=str(self.auth))
        self.seed(expected)
        self.assertEqual(self.invoke()["settings"], expected)
        self.assertEqual(self.directory.stat().st_mode & 0o7777, 0o700)
        self.assertEqual(self.record.stat().st_mode & 0o7777, 0o600)
        self.assertNotIn(b"secret sentinel", self.record.read_bytes())
        self.seed(DISABLED)
        self.assertEqual(self.invoke()["settings"], DISABLED)
        self.assertTrue(self.auth.read_bytes().startswith(b"secret sentinel"))

    def test_review_mode_roundtrips_with_enabled_and_disabled_staging(self):
        for settings in (ENABLED, DISABLED):
            for mode in ("native", "pre_write"):
                expected = dict(settings, review_mode=mode)
                self.seed(expected)
                self.assertEqual(self.invoke()["settings"], expected)

    def test_public_review_mode_persists_and_reset_does_not_restore_native_writes(self):
        self.seed(dict(ENABLED, auth_file=str(self.auth)))
        saved = self.editor("mode_pre_write")
        self.assertEqual(saved["settings"]["review_mode"], "pre_write")
        self.assertEqual(self.editor()["settings"], saved["settings"])
        overridden = self.editor("read_override")["settings"]
        self.assertEqual(overridden["review_mode"], "pre_write")
        self.assertNotIn("auth_file", overridden)
        prompt = self.editor("normal_prompt_cancel")
        self.assertEqual(prompt["inputs"], 1)
        self.assertEqual(prompt["native_calls"], 0)
        reset = self.editor("reset")
        self.assertEqual(reset["settings"]["review_mode"], "pre_write")
        self.assertFalse(reset["settings"]["enabled"])
        self.assertEqual(self.editor()["settings"], reset["settings"])
        native = self.editor("mode_native")
        self.assertEqual(native["settings"]["review_mode"], "native")
        self.assertFalse(native["settings"]["enabled"])

    def test_cancelled_and_stale_mode_choices_do_not_change_preferences(self):
        self.seed(dict(ENABLED, review_mode="pre_write"))
        for action in ("mode_cancel", "mode_late"):
            with self.subTest(action=action):
                loaded = self.editor(action)
                self.assertEqual(loaded["settings"]["review_mode"], "pre_write")
                self.assertNotIn("save", loaded["calls"])

    def test_public_setup_remembers_choices_across_editors_without_provider_calls(self):
        saved = self.editor("save")
        self.assertTrue(saved["settings"]["enabled"])
        loaded = self.editor()
        self.assertEqual(loaded["settings"], saved["settings"])
        self.assertEqual(loaded["calls"], ["load"])
        self.assertEqual(self.editor("prompt_cancel")["inputs"], 1)
        self.editor("late_prompt")
        reset = self.editor("reset")
        self.assertFalse(reset["settings"]["enabled"])
        self.assertFalse(self.editor()["settings"]["enabled"])
        self.assertEqual(json.loads(self.record.read_bytes()), DISABLED)
        self.assertTrue(self.auth.read_bytes().startswith(b"secret sentinel"))

    def test_disabled_cancelled_invalid_and_stale_dialogs_do_not_opt_in(self):
        for action in ("disabled", "cancel_model", "cancel_auth", "cancel_confirm", "late_setup", "invalid_model"):
            with self.subTest(action=action):
                result = self.editor(action)
                self.assertFalse(result["settings"]["enabled"])
                self.assertNotIn("save", result["calls"])
                self.assertFalse(self.directory.exists())

    def test_invalid_input_and_unknown_fields_fail_closed(self):
        for value in ({}, [], dict(ENABLED, enabled=1), dict(ENABLED, schema=True),
                      dict(ENABLED, model="unqualified"), dict(ENABLED, model="p/m\n"),
                      dict(ENABLED, model="p/" + "m" * 512), dict(ENABLED, token="secret"),
                      dict(ENABLED, provider={"fixture": {"apiKey": "secret"}}),
                      dict(ENABLED, review_mode="automatic"), dict(ENABLED, review_mode=False),
                      dict(DISABLED, review_mode=[]),
                      dict(ENABLED, auth_file="relative/auth.json"),
                      dict(ENABLED, auth_file=str(self.root / "missing")),
                      dict(ENABLED, enabled=False)):
            with self.subTest(value=value):
                self.assertFalse(self.invoke("save", value)["ok"])
        for raw in (b"{}" * 10000, b"{", b'{"directory":"x","directory":"y"}', b"NaN"):
            self.assertFalse(self.invoke(raw=raw)["ok"])
        self.assertFalse(self.directory.exists())

    def test_corrupt_unknown_and_oversize_records_are_not_activated(self):
        self.seed()
        for raw in (b"{", b"[]", b"x" * 16385, b'{"schema":1,"schema":1,"enabled":false}',
                    json.dumps(dict(ENABLED, schema=2)).encode(),
                    json.dumps(dict(ENABLED, token="secret")).encode()):
            self.record.write_bytes(raw)
            self.assertFalse(self.invoke()["ok"])
            prompt = self.editor("normal_prompt_cancel")
            self.assertEqual(prompt["native_calls"], 0)
            self.assertEqual(prompt["inputs"], 0)
            self.assertEqual(prompt["settings"]["review_mode"], "unavailable")
        self.seed()  # Explicit setup may repair a corrupt but safely owned file.

    def test_unsafe_files_links_and_parents_are_never_followed_or_repaired(self):
        self.seed()
        for mode in (0o644, 0o666):
            self.record.chmod(mode)
            self.assertFalse(self.invoke()["ok"])
            self.assertFalse(self.invoke("save", ENABLED)["ok"])
        self.record.chmod(0o600)
        link = self.root / "hardlink"
        os.link(self.record, link)
        self.assertFalse(self.invoke()["ok"])
        self.assertFalse(self.invoke("save", ENABLED)["ok"])
        link.unlink()
        self.record.unlink()
        self.record.symlink_to(self.auth)
        self.assertFalse(self.invoke()["ok"])
        self.assertFalse(self.invoke("save", ENABLED)["ok"])
        self.record.unlink()
        os.mkfifo(self.record, 0o600)
        self.assertFalse(self.invoke()["ok"])
        self.record.unlink()
        self.directory.chmod(0o755)
        self.assertFalse(self.invoke()["ok"])
        self.assertFalse(self.invoke("save", ENABLED)["ok"])
        self.directory.chmod(0o700)
        self.directory.parent.chmod(0o777)
        self.assertFalse(self.invoke()["ok"])
        self.assertFalse(self.invoke("save", ENABLED)["ok"])

    def test_parent_symlinks_and_unsafe_auth_paths_are_rejected(self):
        self.directory.parent.mkdir()
        self.directory.symlink_to(self.root, target_is_directory=True)
        self.assertFalse(self.invoke()["ok"])
        self.assertFalse(self.invoke("save", ENABLED)["ok"])
        self.directory.unlink()
        alias = self.root / "auth-link"
        alias.symlink_to(self.auth)
        self.assertFalse(self.invoke("save", dict(ENABLED, auth_file=str(alias)))["ok"])
        self.auth.chmod(0o644)
        self.assertFalse(self.invoke("save", dict(ENABLED, auth_file=str(self.auth)))["ok"])
        self.assertFalse(self.directory.exists())

    def test_concurrent_saves_publish_only_whole_private_records(self):
        self.seed()
        choices = [dict(ENABLED, model="fixture/model-" + str(i)) for i in range(8)]
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda value: self.invoke("save", value), choices))
        self.assertTrue(all(result["ok"] for result in results), results)
        self.assertIn(self.invoke()["settings"], choices)
        self.assertEqual(list(self.directory.iterdir()), [self.record])

    def test_concurrent_loads_observe_whole_private_records(self):
        self.seed()
        choices = [dict(ENABLED, model="fixture/model-" + str(i)) for i in range(16)]
        operations = [value for choice in choices for value in (None, choice, None)]
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(
                lambda value: self.invoke("load" if value is None else "save", value),
                operations,
            ))
        self.assertTrue(all(result["ok"] for result in results), results)
        for result in results:
            self.assertIn(result["settings"], [ENABLED, *choices])
        self.assertIn(self.invoke()["settings"], choices)
        self.assertEqual(self.record.stat().st_mode & 0o7777, 0o600)
        self.assertEqual(list(self.directory.iterdir()), [self.record])


if __name__ == "__main__":
    unittest.main()
