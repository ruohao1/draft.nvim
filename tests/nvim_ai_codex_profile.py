"""Private Codex credential import; every credential here is synthetic."""
import importlib.util
import json
import os
from pathlib import Path
import stat
import shutil
import tomllib
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def helper(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


storage = helper("nvim-ai-codex-store")
runtime = helper("nvim-ai-codex-runtime")


class ProfileTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="draft-codex-auth-", dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.parent = Path(self.temporary.name)
        self.source = self.parent / "credential space 二.json"
        self.store = storage.Store(self.parent)
        self.addCleanup(self.store.close)

    def credential(self, value):
        self.source.write_text(json.dumps(value))
        self.source.chmod(0o600)
        return str(self.source)

    def test_commands_only_read_system_tools_and_selected_files(self):
        self.store.initialize(self.credential({"OPENAI_API_KEY": "synthetic-api-key"}))
        task = self.parent / "turn"
        (task / "staging").mkdir(mode=0o700, parents=True)
        runtime.sandbox({"model": "openai/gpt-5.4", "bwrap": os.path.realpath(shutil.which("bwrap")),
                         "codex": os.path.realpath(shutil.which("true"))}, task, self.store)
        profile = tomllib.loads((task / "agent/codex.toml").read_text())
        self.assertEqual(profile.get("default_permissions"), "draft")
        self.assertNotIn("sandbox_mode", profile)
        self.assertNotIn("sandbox_workspace_write", profile)
        self.assertEqual(profile["permissions"], {"draft": {
            "filesystem": {":minimal": "read", "/opt/codex": "read", "/tmp/project": "write"},
            "network": {"enabled": False}}})

    def test_private_api_key_import(self):
        source = self.credential({"OPENAI_API_KEY": "synthetic-api-key"})
        original = self.source.read_bytes()
        self.store.initialize(source)
        copied = self.store.path / "auth.json"
        self.assertEqual(json.loads(copied.read_bytes()), {"OPENAI_API_KEY": "synthetic-api-key"})
        self.assertEqual(self.source.read_bytes(), original)
        self.assertEqual(stat.S_IMODE(copied.stat().st_mode), 0o600)
        self.assertEqual(copied.stat().st_nlink, 1)
        self.assertEqual(copied.stat().st_uid, os.getuid())

    def test_private_saved_chatgpt_token_import(self):
        value = {"auth_mode": "chatgpt", "OPENAI_API_KEY": None,
                 "tokens": {"id_token": "eyJhbGciOiJub25lIn0.e30.synthetic",
                            "access_token": "synthetic-access", "refresh_token": "synthetic-refresh",
                            "account_id": "synthetic-account"},
                 "last_refresh": "2026-10-20T00:00:00Z"}
        self.store.initialize(self.credential(value))
        self.assertEqual(json.loads((self.store.path / "auth.json").read_bytes()), value)
        self.assertEqual(json.loads(self.source.read_bytes()), value)

    def test_import_once_cannot_overwrite_retained_credentials(self):
        self.store.initialize(self.credential({"auth_mode": "apikey", "OPENAI_API_KEY": "first"}))
        original = (self.store.path / "auth.json").read_bytes()
        self.credential({"OPENAI_API_KEY": "second"})
        with self.assertRaises(storage.Refused):
            self.store.initialize(str(self.source))
        self.assertEqual((self.store.path / "auth.json").read_bytes(), original)

    def test_unrelated_keyring_and_malformed_auth_are_refused(self):
        values = [
            {}, {"auth_mode": "chatgpt"}, {"auth_mode": "chatgptAuthTokens", "tokens": {}},
            {"auth_mode": "agentIdentity", "agent_identity": "synthetic-secret"},
            {"auth_mode": "apikey", "OPENAI_API_KEY": ""},
            {"OPENAI_API_KEY": "synthetic-secret", "provider": "other"},
            {"OPENAI_API_KEY": "synthetic-secret", "tokens": {"access_token": "ambiguous"}},
            {"auth_mode": "chatgpt", "tokens": {"id_token": "x", "access_token": "y"}},
            {"auth_mode": "chatgpt", "tokens": {"id_token": "x", "access_token": "y",
                                               "refresh_token": 4}},
        ]
        for value in values:
            with self.subTest(value=value):
                store = storage.Store(self.parent)
                try:
                    with self.assertRaises(storage.Refused) as caught:
                        store.initialize(self.credential(value))
                    self.assertNotIn("synthetic-secret", str(caught.exception))
                    self.assertFalse((store.path / "auth.json").exists())
                finally:
                    store.close()
        for raw in (b'{"OPENAI_API_KEY":"first","OPENAI_API_KEY":"second"}', b'not JSON',
                    b'{"OPENAI_API_KEY":NaN}', b'x' * (1024 * 1024 + 1)):
            store = storage.Store(self.parent)
            self.source.write_bytes(raw)
            self.source.chmod(0o600)
            try:
                with self.assertRaises(storage.Refused):
                    store.initialize(str(self.source))
            finally:
                store.close()

    def test_unsafe_credential_files_are_never_imported(self):
        self.credential({"OPENAI_API_KEY": "synthetic-secret"})
        alias = self.parent / "alias.json"
        for case in ("mode", "symlink", "hardlink", "fifo"):
            with self.subTest(case=case):
                store = storage.Store(self.parent)
                if case == "mode":
                    self.source.chmod(0o644)
                    target = self.source
                elif case == "symlink":
                    alias.symlink_to(self.source)
                    target = alias
                elif case == "hardlink":
                    os.link(self.source, alias)
                    target = self.source
                else:
                    os.mkfifo(alias, mode=0o600)
                    target = alias
                try:
                    with self.assertRaises(storage.Refused):
                        store.initialize(str(target))
                    self.assertFalse((store.path / "auth.json").exists())
                finally:
                    store.close()
                    self.source.chmod(0o600)
                    if alias.is_symlink() or alias.exists():
                        alias.unlink()


if __name__ == "__main__":
    unittest.main()
