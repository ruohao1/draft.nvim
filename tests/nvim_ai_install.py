"""Exercise a real relocated install, including paths with spaces and help tags."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent


class InstallTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="draft-install-", dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.plugin = self.base / "plugins with spaces/draft.nvim"
        for name in ("lua", "scripts", "doc", "tests"):
            shutil.copytree(ROOT / name, self.plugin / name,
                            ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        self.cwd = self.base / "unrelated project"
        self.cwd.mkdir()
        nvim = shutil.which("nvim")
        self.assertIsNotNone(nvim)
        self.nvim = nvim
        self.env = {"PATH": str(Path(nvim).parent) + os.pathsep + os.defpath,
                    "LANG": "C.UTF-8", "NVIM_LOG_FILE": "/dev/null",
                    "DRAFT_TEST_INSTALL": str(self.plugin)}
        for key in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
                    "XDG_CACHE_HOME", "XDG_RUNTIME_DIR"):
            directory = self.base / key.lower()
            directory.mkdir(mode=0o700)
            self.env[key] = str(directory)

    def run_editor(self, script):
        result = subprocess.run(
            [self.nvim, "--clean", "--headless", "-u", "NONE", "-i", "NONE",
             "--cmd", "lua vim.opt.rtp:prepend(vim.env.DRAFT_TEST_INSTALL)", "-l", str(script)],
            cwd=self.cwd, env=self.env, capture_output=True, text=True, timeout=40)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_relocated_commands_and_helpers_ignore_the_working_directory(self):
        for name in ("draft_setup", "ai_opencode_runtime_paths", "ai_conversation_driver", "ai_conversation_controller", "ai_chat_controller", "ai_scope"):
            with self.subTest(suite=name):
                self.run_editor(self.plugin / "tests" / (name + ".lua"))

    def test_help_tags_resolve_the_public_documentation(self):
        script = self.base / "help.lua"
        script.write_text('''
vim.cmd("helptags " .. vim.fn.fnameescape(vim.env.DRAFT_TEST_INSTALL .. "/doc"))
vim.cmd("help draft-options")
assert(vim.bo.filetype == "help")
assert(vim.api.nvim_buf_get_name(0) == vim.env.DRAFT_TEST_INSTALL .. "/doc/draft.txt")
''')
        self.run_editor(script)
        tags = (self.plugin / "doc/tags").read_text()
        self.assertIn("draft-options\tdraft.txt\t", tags)


if __name__ == "__main__":
    unittest.main()
