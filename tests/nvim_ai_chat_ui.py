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


class ChatTerminal(unittest.TestCase):
    fixture_script = "chat_ui.lua"

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
                    "DRAFT_CHAT_UI_SCRIPT": str(ROOT / "tests/fixtures/ai" / self.fixture_script)}
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
        try:
            return subprocess.run([self.nvim, "--server", str(self.editor), "--remote-expr",
                                   "luaeval(" + json.dumps(lua) + ")"], env=self.env, cwd=self.root,
                                  capture_output=True, text=True, timeout=5, check=True).stdout.strip()
        except subprocess.TimeoutExpired:
            self.fail("Editor did not answer: " + lua + "\n" + self.tm("capture-pane", "-p", "-t", "draft"))

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

class ChatUITest(ChatTerminal):
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
        self.wait(lambda: "Draft · idle · next: fixture/model" in self.capture("conversation-narrow"), "narrow rendered state")
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

    def test_model_picker_keys_are_passive_and_preserve_history(self):
        self.keys("i")
        self.literal("Explain the current parser.")
        self.keys("C-s", "Escape")
        self.wait(lambda: self.evaluate("vim.g.chat_fixture_prompts") == "1", "first explicit turn")
        self.keys("i")
        self.literal("Keep this question for the next model.")
        self.keys("Escape", "g", "m")
        prompt = "Model for next turn (conversation only)"
        self.wait(lambda: prompt in self.capture("conversation-model-picker"), "model picker")
        self.assertIn("fixture/model (selected)", self.capture("conversation-model-picker"))
        self.assertIn("fixture/second-model", self.capture("conversation-model-picker"))
        self.keys("Escape")
        self.wait(lambda: prompt not in self.tm("capture-pane", "-p", "-t", "draft"), "cancelled picker")
        self.assertEqual(self.evaluate("vim.g.chat_fixture_prompts"), "1")
        self.assertEqual(self.evaluate("vim.api.nvim_get_current_line()"), "Keep this question for the next model.")
        self.keys("g", "m")
        self.wait(lambda: prompt in self.tm("capture-pane", "-p", "-t", "draft"), "reopened picker")
        self.keys("2", "Enter")
        self.wait(lambda: "next: fixture/second-model" in self.capture("conversation-model"), "selected model")
        self.assertEqual(self.evaluate("vim.g.chat_fixture_prompts"), "1")
        self.keys("q")
        self.wait(lambda: self.evaluate("#vim.api.nvim_list_wins()") == "1", "hidden selection")
        self.command("NvimAIChat")
        self.assertEqual(self.evaluate("vim.api.nvim_get_current_line()"), "Keep this question for the next model.")
        self.assertIn("next: fixture/second-model", self.capture("conversation-model"))
        self.keys("C-s")
        self.wait(lambda: self.evaluate("vim.g.chat_fixture_prompts") == "2", "explicit send after selection")
        self.wait(lambda: "Assistant · fixture/second-model" in self.capture("conversation-model-turns"), "second model label")
        self.assertIn("Assistant · fixture/model", self.capture("conversation-model-turns"))
        self.command("NvimAIChatClose")


class ChatApprovalUITest(ChatTerminal):
    fixture_script = "chat_approval_ui.lua"

    def setUp(self):
        super().setUp()
        self.addCleanup(self.close_fixture)

    def close_fixture(self):
        self.keys("Escape")
        self.evaluate("pcall(chat_approval_fixture.cleanup)")

    def phase(self, value):
        self.wait(lambda: self.evaluate("chat_approval_fixture.snapshot().phase") == value, value)

    def send(self, text):
        self.keys("i")
        self.literal(text)
        self.keys("C-s", "Escape")
        self.phase("review")

    def review(self, index=1):
        self.keys("g", "d")
        self.wait(lambda: "Open frozen proposal preview" in self.tm("capture-pane", "-p", "-t", "draft"), "review picker")
        self.keys(str(index), "Enter")
        self.wait(lambda: "FROZEN STAGED PROPOSAL" in self.evaluate("vim.wo.winbar"), "frozen panels")

    def confirm(self, prompt):
        self.wait(lambda: prompt in self.tm("capture-pane", "-p", "-t", "draft"), prompt)
        self.keys("2", "Enter")
        # The default inputlist can leave a normal hit-enter prompt when the
        # synchronous publisher reports its result. Acknowledge it as a user;
        # remote-expr cannot run while Neovim is waiting in that prompt.
        def finished():
            screen = self.tm("capture-pane", "-p", "-t", "draft")
            if "Press ENTER or type command" in screen:
                self.keys("Enter")
                return False
            return "Type number and <Enter>" not in screen
        self.wait(finished, "confirmation returned to editor")

    def test_real_review_keys_receipts_followup_and_batches(self):
        self.send("Propose edits to the selected files.")
        self.review()
        self.assertEqual(self.evaluate("chat_approval_fixture.disk(1)"), "original text")
        self.wait(lambda: "first.txt" in self.capture("conversation-review"), "review capture")
        screen = self.capture("conversation-review")
        self.assertIn("a accept", screen, "accept help must fit the real split")
        self.assertIn("r reject", screen, "reject help must fit the real split")
        self.keys("a")
        self.wait(lambda: "second.txt" in self.evaluate("vim.wo.winbar"), "accept and advance")
        self.assertEqual(self.evaluate("chat_approval_fixture.disk(1)"), "proposed edit")
        self.keys("r")
        self.wait(lambda: self.evaluate("chat_approval_fixture.snapshot().review.files[2].state") == "rejected", "reject current file")
        self.assertIn("second.txt", self.evaluate("vim.wo.winbar"))
        self.keys("f")
        self.wait(lambda: self.evaluate("vim.bo.filetype") == "draft-chat-input", "follow-up composer")
        self.wait(lambda: "first.txt · accepted" in self.capture("conversation-decisions"), "receipt transcript")
        self.assertIn("second.txt · rejected", self.capture("conversation-decisions"))
        self.send("Revise the pending edit.")
        self.assertEqual(self.evaluate("chat_approval_fixture.snapshot().review.revision"), "2")
        self.review(3)
        self.keys("]", "f")
        self.wait(lambda: "first.txt" in self.evaluate("vim.wo.winbar"), "next file")
        self.keys("[", "f")
        self.wait(lambda: "third.txt" in self.evaluate("vim.wo.winbar"), "previous file")
        self.keys("A")
        self.confirm("Accept remaining 1 file(s)?")
        self.phase("idle")
        self.assertEqual(self.evaluate("chat_approval_fixture.disk(3)"), "revised edit")
        self.command("NvimAIChat")
        self.send("Propose another set of edits.")
        self.review()
        self.keys("R")
        self.confirm("Reject remaining 3 file(s)?")
        self.phase("idle")
        self.assertEqual(self.evaluate("chat_approval_fixture.disk(2)"), "original text")
        self.command("NvimAIChat")
        self.send("Propose edits once more.")
        self.review()
        self.keys("a")
        self.wait(lambda: "second.txt" in self.evaluate("vim.wo.winbar"), "partial acceptance before cancel")
        accepted = self.evaluate("chat_approval_fixture.disk(1)")
        self.keys("q")
        self.confirm("Discard the pending frozen review?")
        self.phase("idle")
        self.assertEqual(self.evaluate("chat_approval_fixture.disk(1)"), accepted)
        self.assertEqual(self.evaluate("chat_approval_fixture.disk(2)"), "original text")
        self.command("NvimAIChatClose")
        self.phase("closed")

    def test_model_switch_after_review_keeps_saved_files_and_session(self):
        self.send("Propose edits to the selected files.")
        self.review()
        self.keys("R")
        self.confirm("Reject remaining 3 file(s)?")
        self.phase("idle")
        self.command("NvimAIChat")
        self.keys("i")
        self.literal("Discuss the rejected edits.")
        self.keys("Escape", "g", "m")
        self.wait(lambda: "Model for next turn (conversation only)" in
                  self.tm("capture-pane", "-p", "-t", "draft"), "model picker")
        self.keys("2", "Enter")
        self.wait(lambda: self.evaluate(
            "chat_approval_fixture.snapshot().desired_model") ==
            "fixture/second-model", "local model selection")
        self.assertEqual(self.evaluate("chat_approval_fixture.snapshot().turn_id"), "1")
        self.assertEqual(self.evaluate("vim.api.nvim_get_current_line()"),
                         "Discuss the rejected edits.")
        self.keys("C-s")
        self.wait(lambda: self.evaluate(
            "chat_approval_fixture.snapshot().turn_id == 2 and "
            "chat_approval_fixture.snapshot().phase == 'idle'") == "true",
            "second completed turn")
        for index in (1, 2, 3):
            self.assertEqual(self.evaluate(f"chat_approval_fixture.disk({index})"),
                             "original text")
        audit = json.loads(self.evaluate("vim.json.encode(chat_approval_fixture.audit)"))
        methods = [event.get("method") for event in audit]
        self.assertEqual(methods.count("session/new"), 1)
        self.assertEqual(methods.count("session/resume"), 1)
        self.assertEqual(methods.count("session/prompt"), 2)
        self.wait(lambda: "Assistant · fixture/second-model" in
                  self.capture("conversation-acceptance"), "second model label")
        self.assertIn("Assistant · fixture/model", self.capture("conversation-acceptance"))
        self.command("NvimAIChatClose")
        self.phase("closed")


if __name__ == "__main__":
    unittest.main()
