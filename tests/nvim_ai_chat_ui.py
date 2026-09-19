"""Exercise actual terminal keys and layout in an isolated tmux/Neovim TUI."""
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parent.parent


class ChatUITest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="draft-chat-tui-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.nvim = shutil.which("nvim")
        self.assertIsNotNone(self.nvim)
        self.socket = self.root / "tmux.sock"
        self.editor = self.root / "nvim.sock"
        self.env = {"PATH": str(Path(self.nvim).parent) + os.pathsep + os.defpath,
                    "LANG": "C.UTF-8", "TERM": "xterm-256color", "NVIM_LOG_FILE": "/dev/null",
                    "DRAFT_TEST_ROOT": str(ROOT), "DRAFT_CHAT_UI_ROOT": str(self.root),
                    "DRAFT_CHAT_UI_SCRIPT": str(ROOT / "tests/fixtures/ai/chat_ui.lua")}
        for key in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR"):
            path = self.root / key.lower()
            path.mkdir(mode=0o700)
            self.env[key] = str(path)
        (self.root / "parser.lua").write_text('''local function parse(text)
  local settings = {}
  for line in text:gmatch("[^\\n]+") do
    local key, value = line:match("([^=]+)=(.*)")
    if key then
      settings[key] = value
    end
  end
  return settings
end

return parse
''')
        command = [self.nvim, "--clean", "-u", "NONE", "-i", "NONE", "--listen", str(self.editor),
                   "--cmd", "lua vim.opt.rtp:prepend(vim.env.DRAFT_TEST_ROOT)",
                   "-c", "lua dofile(vim.env.DRAFT_CHAT_UI_SCRIPT)"]
        self.tm("new-session", "-d", "-s", "draft", "-x", "140", "-y", "42", shlex.join(command))
        self.addCleanup(lambda: self.tm("kill-server", check=False))
        self.wait(lambda: self.editor.exists(), "Neovim socket")
        self.wait(lambda: self.evaluate("vim.g.chat_fixture_ready") == "true", "UI startup")

    def tm(self, *args, check=True):
        return subprocess.run(["tmux", "-S", str(self.socket), "-f", "/dev/null", *args],
                              env=self.env, cwd=self.root, capture_output=True, text=True,
                              timeout=5, check=check).stdout

    def evaluate(self, lua):
        return subprocess.run([self.nvim, "--server", str(self.editor), "--remote-expr",
                               "luaeval(" + json.dumps(lua) + ")"], env=self.env, cwd=self.root,
                              capture_output=True, text=True, timeout=5, check=True).stdout.strip()

    def wait(self, predicate, label):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(.03)
        self.fail("Timed out: " + label + "\n" + self.tm("capture-pane", "-p", "-t", "draft"))

    def keys(self, *keys):
        self.tm("send-keys", "-t", "draft", *keys)

    def literal(self, text):
        self.keys("-l", text)

    def command(self, command):
        self.evaluate("vim.cmd(" + json.dumps(command) + ")")

    def capture(self, name):
        screen = self.tm("capture-pane", "-p", "-e", "-t", "draft")
        plain = re.sub(r"\x1b\[[0-9;:]*m", "", screen)
        self.assertNotIn("Press ENTER", plain)
        directory = os.environ.get("DRAFT_CHAT_CAPTURE_DIR")
        if directory:
            output = Path(directory)
            output.mkdir(parents=True, exist_ok=True)
            (output / (name + ".ansi")).write_text(screen)
            (output / (name + ".txt")).write_text(plain)
        return plain

    def test_real_input_passive_reopen_and_resize(self):
        self.keys("i")
        self.literal("What does this parser do?")
        self.keys("Enter")
        self.literal("Explain the current behavior.")
        self.assertEqual(self.evaluate("vim.g.chat_fixture_prompts"), "0", "Enter must not submit")
        self.keys("C-s", "Escape")
        self.wait(lambda: self.evaluate("vim.g.chat_fixture_prompts") == "1", "first explicit send")
        self.assertIn("\\n", self.evaluate("vim.json.encode(vim.g.chat_fixture_message)"))
        self.keys("i")
        self.literal("Which edge cases should we check next?")
        self.keys("C-s", "Escape")
        self.wait(lambda: self.evaluate("vim.g.chat_fixture_prompts") == "2", "second explicit send")
        self.keys("i")
        self.literal("Next: walk through the whitespace case.")
        self.keys("Escape")
        self.wait(lambda: self.evaluate("vim.api.nvim_get_mode().mode") == "n", "normal-mode capture")
        self.wait(lambda: "Two edge cases" in self.capture("conversation-wide"), "wide transcript")
        self.tm("resize-window", "-t", "draft", "-x", "70", "-y", "28")
        self.wait(lambda: self.evaluate("vim.o.columns") == "70", "narrow resize")
        self.wait(lambda: "Draft · idle · fixture/model" in self.capture("conversation-narrow"), "narrow rendered state")
        self.keys("q")
        self.wait(lambda: self.evaluate("#vim.api.nvim_list_wins()") == "1", "passive hide")
        self.command("NvimAIChat")
        self.assertEqual(self.evaluate("vim.g.chat_fixture_prompts"), "2")
        self.assertEqual(self.evaluate("vim.api.nvim_get_current_line()"), "Next: walk through the whitespace case.")
        self.tm("resize-window", "-t", "draft", "-x", "30", "-y", "9")
        self.wait(lambda: self.evaluate("#vim.api.nvim_list_wins()") == "1", "tiny editor hides chat")
        self.tm("resize-window", "-t", "draft", "-x", "140", "-y", "42")
        self.wait(lambda: self.evaluate("vim.o.columns") == "140", "wide resize")
        self.assertEqual(self.evaluate("#vim.api.nvim_list_wins()"), "1", "resize cannot implicitly reopen")
        self.command("NvimAIChat")
        self.command("NvimAIChatClose")
        self.wait(lambda: self.evaluate("vim.bo.modifiable") == "false", "closed history is read-only")
        self.assertEqual(self.evaluate("vim.g.chat_fixture_prompts"), "2")
        self.assertIn("local function parse", (self.root / "parser.lua").read_text())


if __name__ == "__main__":
    unittest.main()
