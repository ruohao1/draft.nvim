"""Provider-free regressions using Neovim's real TUI, dialogs and public commands.

Every provider name is an installed strict fake in a private HOME, and every
tmux invocation is fenced to the harness socket. No actual provider is called.
"""

import importlib.util
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import socket
import subprocess
import sys
import termios
import threading
import time

spec = importlib.util.spec_from_file_location("native_lifecycle", Path(__file__).with_name("native_lifecycle.py"))
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
check, wait_for = native.check, native.wait_for


class NativeUI(native.Lifecycle):
    def screen(self, pane):
        return self.tm("capture-pane", "-p", "-t", pane, "-S", "-5")

    def schedule(self, command):
        lua = "vim.schedule(function() vim.cmd(" + json.dumps(command) + ") end) or 'scheduled'"
        return self.run([self.nvim, "--server", str(self.owners["a"][1]), "--remote-expr", "luaeval(" + json.dumps(lua) + ")"]).stdout

    def source_snapshot(self):
        return self.command("a", 'lua vim.print({vim.bo.modified, vim.api.nvim_buf_get_lines(0, 0, -1, false)})')

    def notice_layout_case(self, owner):
        message = ("Context published to OpenCode, not submitted; :NvimAIReview after edits. "
                   "Check its prompt: HTTP does not confirm insertion.")
        self.command("a", 'lua vim.keymap.set("n", "<F8>", function() vim.g.notice_shown = require("ai.notice").info(' +
                     json.dumps(message) + ', "AI: not submitted. Check prompt; :NvimAIReview after edits") end)')
        source = self.source_snapshot()
        for columns, lines in ((113, 40), (40, 10), (20, 6), (12, 4)):
            for height in (1, 0):
                self.command("a", "set cmdheight=" + str(height))
                self.tm("resize-window", "-t", owner, "-x", str(columns), "-y", str(lines))
                self.command("a", "messages clear")
                before = self.run([self.nvim, "--server", str(self.owners["a"][1]), "--remote-expr",
                                   "json_encode([&cmdheight, &more, &ruler, &showcmd, &shortmess])"]).stdout
                self.tm("send-keys", "-t", owner, "F8")
                time.sleep(.15)
                output = self.screen(owner)
                check("Press ENTER" not in output and "-- More --" not in output,
                      f"notification blocks at {columns}x{lines}, cmdheight={height}: " + output)
                after = self.run([self.nvim, "--server", str(self.owners["a"][1]), "--remote-expr",
                                  "json_encode([&cmdheight, &more, &ruler, &showcmd, &shortmess])"]).stdout
                check(after == before, "notice leaves all user message options unchanged")
                history = self.command("a", "messages")
                space = int(self.run([self.nvim, "--server", str(self.owners["a"][1]), "--remote-expr", "v:echospace"]).stdout)
                shown = self.command("a", "lua vim.print(vim.g.notice_shown)").strip()
                if space <= 1:
                    check(not history.strip() and shown == "false", "zero available cells are reported as undisplayed")
                else:
                    check(shown == "true" and message in history.replace("\n", ""),
                          f"full guidance survives {columns}x{lines}, cmdheight={height}: " + repr(history))
        self.tm("resize-window", "-t", owner, "-x", "113", "-y", "40")
        self.tm("send-keys", "-t", owner, "F8")
        time.sleep(.15)
        check(message in self.command("a", "messages").replace("\n", ""), "explicit notice after widening is retained")
        check(self.source_snapshot() == source, "narrow notices do not alter buffer contents or modified state")

    def prompt_review_case(self, owner):
        # Real keys, not execute() redirection: message overflow must remain
        # observable with Neovim's ordinary one-line command area.
        self.command("a", "set cmdheight=1")
        source = self.source_snapshot()
        source_file = self.root / "root/main.lua"
        original = source_file.read_text()
        self.command("a", "NvimAIBackend opencode")
        self.ready("a", "opencode", 1)

        def prompt():
            self.tm("select-pane", "-t", owner)
            self.tm("send-keys", "-t", owner, "-l", ":NvimAIPrompt")
            self.tm("send-keys", "-t", owner, "Enter")

        def nonblocking(label):
            time.sleep(.15)
            check("Press ENTER" not in self.screen(owner), label + " left Neovim waiting for Enter")
            mode = json.loads(self.run([self.nvim, "--server", str(self.owners["a"][1]),
                                      "--remote-expr", "json_encode(nvim_get_mode())"]).stdout)
            check(mode["mode"] == "n" and not mode["blocking"] and "Press ENTER" not in self.screen(owner),
                  label + " must not leave Neovim waiting for Enter: " + json.dumps(mode))
            check(self.command("a", "lua vim.print(vim.o.cmdheight)").strip() == "1",
                  "success feedback must not change the user's command height")

        prompt()
        self.ready("a", "opencode", 2)
        nonblocking("OpenCode ready/retry notice")
        check(not self.http_events("a"), "startup notice never queues or publishes context")
        prompt()
        wait_for(lambda: len(self.http_events("a")) == 1, "explicit retry publishes context once")
        nonblocking("published-context success notice")
        check(self.source_snapshot() == source, "prompt feedback preserves the source buffer")
        history = self.command("a", "messages").replace("\n", "")
        check("HTTP does not confirm insertion" in history and "NvimAIPrompt again" in history,
              "complete guidance remains available in message history")
        check(not self.events("a", "opencode", "input") and not self.events("a", "opencode", "turn-started"),
              "prompt preparation never types or submits to the native agent")
        pane = self.owned(owner)[0]["pane_id"]
        check(self.tm("display-message", "-p", "-t", pane, "#{pane_active}") == "1",
              "successful handoff retains focus on the companion")
        (self.state("a") / "backends/opencode/edit-review.fixture").touch(mode=0o600)
        self.tm("send-keys", "-t", pane, "C-u")
        self.tm("send-keys", "-t", pane, "-l", "fixture-edit")
        self.tm("send-keys", "-t", pane, "Enter")
        wait_for(lambda: self.events("a", "opencode", "file-edited"), "explicit fake-agent turn edits inside sandbox")
        check(source_file.read_text() == "hello from the companion\n", "native sandbox edit reaches the fixture file")
        check(len(self.events("a", "opencode", "turn-started")) == 1, "only the explicit fixture Enter starts a turn")
        self.tm("select-pane", "-t", owner)
        self.tm("send-keys", "-t", owner, "-l", ":NvimAIReview")
        self.tm("send-keys", "-t", owner, "Enter")
        output = wait_for(lambda: self.screen(owner) if "[unresolved] main.lua" in self.screen(owner) else "",
                          "native review picker finds the sandbox edit")
        selected = re.search(r"(\d+): \[unresolved\] main\.lua", output)
        check(selected is not None, "edited file is an observed review choice")
        self.tm("send-keys", "-t", owner, "-l", selected.group(1))
        self.tm("send-keys", "-t", owner, "Enter")
        try:
            wait_for(lambda: "hello from the companion" in self.screen(owner),
                     "native review displays the existing-file diff")
        except AssertionError as error:
            raise AssertionError(str(error) + "\n" + self.screen(owner)) from None
        self.tm("send-keys", "-t", owner, "-l", "R")
        wait_for(lambda: source_file.read_text() == original, "native review rejection restores the exact original bytes")
        wait_for(lambda: self.record("a")["review_id"] is None, "review rejection finishes recovery cleanup")
        self.command("a", "NvimAIClose")
        wait_for(lambda: not self.owned(owner), "prompt companion closes")

    def terminal_response_case(self, owner, kind="graphics"):
        self.tm("set-option", "-gw", "allow-passthrough", "on")
        self.tm("set-option", "-s", "escape-time", "10")
        self.tm("set-option", "-s", "extended-keys", "on")
        self.tm("set-option", "-s", "extended-keys-format", "csi-u")
        self.tm("set-option", "-sa", "terminal-features", ",xterm-256color:extkeys")
        master, slave = pty.openpty()
        termios.tcsetwinsize(slave, (60, 200))
        stop, replied = threading.Event(), threading.Event()
        errors, queries = [], []
        client = worker = None
        query = b"Gi=31337" if kind == "graphics" else b"\x1bP+q4d73"
        # XTGETTCAP encodes the terminfo string, not any clipboard contents.
        # infocmp: Ms=\E]52;%p1%s;%p2%s\007 -> trailing hex 303037.
        reply = (b"\x1b_Gi", b"=31337;OK\x1b\\") if kind == "graphics" else (
            b"\x1bP1+r4D73=5C455D35323B25703125733B25703225735C", b"303037\x1b\\")

        def terminal_session():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        def pump():
            tail, total = b"", 0
            try:
                while not stop.is_set():
                    if not select.select([master], [], [], .05)[0]:
                        continue
                    data = os.read(master, 65536)
                    if not data:
                        return
                    total += len(data)
                    check(total <= 2 * 1024 * 1024, "bounded test terminal output")
                    data = tail + data
                    if query in data:
                        queries.append(True)
                        os.write(master, reply[0])
                        if stop.wait(.1):
                            return
                        os.write(master, reply[1])
                        replied.set()
                    tail = data[-7:]
            except Exception as error:
                if not stop.is_set():
                    errors.append(str(error))

        try:
            environment = dict(self.env, TERM="xterm-256color")
            client = subprocess.Popen([self.tmux, "-S", self.socket, "attach-session", "-t", "nvim-ai"], env=environment,
                                      stdin=slave, stdout=slave, stderr=slave, preexec_fn=terminal_session)
            worker = threading.Thread(target=pump, daemon=True)
            worker.start()
            source = self.source_snapshot()
            self.command("a", "NvimAIBackend opencode")
            self.ready("a", "opencode", 1)
            wait_for(lambda: self.events("a", "opencode", kind + "-probe"), kind + " probe decision")
            if kind == "graphics" and self.events("a", "opencode", kind + "-probe")[0]["emitted"]:
                wait_for(replied.is_set, "fragmented outer-terminal reply")
                time.sleep(.15)
            if kind == "termcap":
                # Allow the owned outer terminal to process any escaped query.
                time.sleep(.35)
            actual = self.source_snapshot()
            check(actual == source, "fragmented " + kind + " response changed the source buffer: " + actual)
            check(not queries and not errors, "no " + kind + " query escapes its companion pane: " + str(errors))
            check(self.tm("show-options", "-pv", "-t", self.owned(owner)[0]["pane_id"], "allow-passthrough") == "off", "companion has a local passthrough boundary")
            check(self.tm("show-options", "-gwv", "allow-passthrough") == "on", "global window passthrough preference remains unchanged")
            check(self.tm("show-options", "-wv", "-t", owner, "allow-passthrough") == "", "window has no new local override")
            check(self.tm("show-options", "-pv", "-t", owner, "allow-passthrough") == "", "editor has no new pane-local override")
            check(self.tm("display-message", "-p", "-t", owner, "#{pane_active}") == "1", "guard does not steal editor focus")
            self.command("a", "NvimAIClose")
            wait_for(lambda: not self.owned(owner), kind + " companion closes")
        finally:
            stop.set()
            if worker is not None:
                worker.join(timeout=2)
            if client is not None:
                client.terminate()
                try:
                    client.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    client.kill()
                    client.wait(timeout=2)
            os.close(master)
            os.close(slave)

    def size_guard_case(self, owner):
        self.tm("resize-window", "-t", owner, "-x", "94", "-y", "21")
        self.command("a", "NvimAIBackend opencode")
        wait_for(lambda: self.owned(owner), "narrow managed companion created")
        pane = self.owned(owner)[0]["pane_id"]
        diagnostic = lambda: "at least 40 columns" in self.tm("capture-pane", "-p", "-J", "-t", pane)
        wait_for(diagnostic, "narrow startup explains required width")
        wait_for(lambda: 'state = "failed"' in self.command("a", "NvimAIStatus"), "narrow startup publishes failure")
        check(not self.events("a", "opencode", "ready"), "unsafe initial TUI never starts")
        self.tm("resize-pane", "-t", pane, "-x", "40")
        self.command("a", "NvimAIOpen")
        self.ready("a", "opencode", 1)
        self.command("a", "NvimAIPrompt")
        self.ready("a", "opencode", 2)
        wait_for(lambda: self.record("a")["sessions"]["opencode"] == "ses_lifecycle", "saved exact session")
        before = self.record("a")
        check(before["review_id"] is not None, "active review before shrink")
        self.command("a", 'lua vim.api.nvim_buf_set_lines(0, 0, 1, false, {"unsaved source sentinel"})')
        source = self.source_snapshot()
        resize_count = len(self.events("a", "opencode", "resize"))
        signal_count = len(self.events("a", "opencode", "signal"))
        self.tm("resize-pane", "-t", pane, "-x", "39")
        wait_for(diagnostic, "shrinking stops TUI with an actionable diagnostic")
        wait_for(lambda: 'state = "failed"' in self.command("a", "NvimAIStatus"), "shrink publishes failure")
        check(all(e["columns"] >= 40 for e in self.events("a", "opencode", "resize")[resize_count:]), "unsafe size is never forwarded")
        check(self.events("a", "opencode", "signal")[signal_count:] == [{"event": "signal", "number": signal.SIGTERM}], "only the owned TUI is stopped")
        after = self.record("a")
        check((after["review_id"], after["sessions"], after["grants"]) == (before["review_id"], before["sessions"], before["grants"]), "guard preserves review, exact sessions and grants")
        check(self.source_snapshot() == source, "guard preserves unsaved editor contents")
        self.tm("resize-pane", "-t", pane, "-x", "40")
        self.command("a", "NvimAIOpen")
        self.ready("a", "opencode", 3)
        check(self.owned(owner)[0]["pane_id"] == pane and self.record("a")["review_id"] == before["review_id"], "explicit reopen recovers same pane and review")
        check(not self.events("a", "opencode", "input"), "guard never types or replays input")
        self.command("a", "NvimAIClose")
        wait_for(lambda: not self.owned(owner), "guarded companion closes")

    def exercise_case(self, case):
        owner = self.tm("display-message", "-p", "-t", "nvim-ai:0.0", "#{pane_id}")
        self.start_owner("a", owner, native_ui=True)
        special_cases = {
            "notice-layouts": self.notice_layout_case,
            "prompt-review-opencode": self.prompt_review_case,
            "graphics-opencode": self.terminal_response_case,
            "termcap-opencode": lambda owner: self.terminal_response_case(owner, "termcap"),
            "size-guard-opencode": self.size_guard_case,
            "version-upgrade-opencode": self.version_upgrade_case,
        }
        if case in special_cases:
            special_cases[case](owner)
            print("ok - native UI " + case)
            return
        backend = "opencode" if case.startswith("prompt") or case.endswith("opencode") else "codex"
        self.command("a", "NvimAIBackend " + backend)
        self.ready("a", backend, 1)
        launches = 1
        if case == "crash-opencode":
            self.command("a", "NvimAIPrompt")
            self.ready("a", backend, 2)
            launches = 2
        state = self.state("a") / "backends" / backend
        if case.startswith("resize-"):
            pane = self.owned(owner)[0]["pane_id"]

            def resize(*args):
                before = len(self.events("a", backend, "resize"))
                self.tm(*args)
                size = self.tm("display-message", "-p", "-t", pane, "#{pane_width} #{pane_height}")
                columns, lines = map(int, size.split())
                if backend == "opencode":
                    check(columns >= 40, "ordinary resize case stays outside the separately tested size guard")
                wait_for(lambda: any(e["columns"] == columns and e["lines"] == lines
                                     for e in self.events("a", backend, "resize")[before:]),
                         f"native {backend} redraw at {columns}x{lines}", seconds=2)
                wait_for(lambda: f"FAKE CLI {columns}x{lines}" in self.tm("capture-pane", "-p", "-J", "-t", pane),
                         f"redraw reaches the visible terminal at {columns}x{lines}", seconds=2)

            resize("resize-pane", "-Z", "-t", pane)
            resize("resize-pane", "-Z", "-t", pane)
            sizes = ((144, 43), (128, 20), (200, 60)) if backend == "opencode" else ((113, 43), (60, 20), (200, 60))
            for columns, lines in sizes:
                resize("resize-window", "-t", pane, "-x", str(columns), "-y", str(lines))
            self.ready("a", backend, 1)
            check(not self.events("a", backend, "input"), "resize never sends input or submits prompts")
            self.command("a", "NvimAIClose")
            wait_for(lambda: not self.owned(owner), "resized companion closes cleanly")
        elif case.startswith("crash"):
            pane = self.owned(owner)[0]["pane_id"]
            source = self.command("a", 'lua vim.print({vim.bo.modified, vim.api.nvim_buf_get_lines(0, 0, -1, false)})')
            owner_modes = self.tm("display-message", "-p", "-t", owner,
                                  "#{mouse_any_flag}:#{mouse_sgr_flag}:#{cursor_flag}:#{alternate_on}")
            (state / "crash-terminal.fixture").touch(mode=0o600)
            self.tm("send-keys", "-t", pane, "-l", "dirty-terminal")
            self.tm("send-keys", "-t", pane, "Enter")
            wait_for(lambda: self.tm("display-message", "-p", "-t", pane,
                                     "#{mouse_any_flag}:#{mouse_sgr_flag}:#{cursor_flag}:#{alternate_on}") == "1:1:0:1",
                     "fake crash starts with mouse modes, hidden cursor and alternate screen")
            self.tm("send-keys", "-t", pane, "-l", "crash")
            self.tm("send-keys", "-t", pane, "Enter")
            wait_for(lambda: "No shell is running" in self.tm("capture-pane", "-p", "-J", "-t", pane),
                     "crash leaves a passive diagnostic")
            check(self.tm("display-message", "-p", "-t", pane,
                          "#{mouse_any_flag}:#{mouse_sgr_flag}:#{cursor_flag}:#{alternate_on}") == "0:0:1:0",
                  "crash restores the companion's terminal modes")
            check(self.tm("display-message", "-p", "-t", owner,
                          "#{mouse_any_flag}:#{mouse_sgr_flag}:#{cursor_flag}:#{alternate_on}") == owner_modes,
                  "companion cleanup does not change the editor's terminal modes")
            self.tm("send-keys", "-t", pane, "-l", "touch should-not-execute")
            self.tm("send-keys", "-t", pane, "Enter")
            time.sleep(0.15)
            check(not (self.root / "root/should-not-execute").exists(), "failed pane cannot execute commands")
            check(self.command("a", 'lua vim.print({vim.bo.modified, vim.api.nvim_buf_get_lines(0, 0, -1, false)})') == source,
                  "crash and cleanup never insert terminal replies into the editor buffer")
            wait_for(lambda: 'state = "failed"' in self.command("a", "NvimAIStatus"),
                     "structured crash event reaches Neovim before explicit reopen")
            self.command("a", "NvimAIOpen")
            self.ready("a", backend, launches + 1)
            check(self.owned(owner)[0]["pane_id"] == pane, "explicit reopen recovers the exact failed pane")
            self.command("a", "NvimAIClose")
            wait_for(lambda: not self.owned(owner), "recovered companion closes cleanly")
        elif case.startswith("prompt"):
            (state / "flush-startup-input.fixture").touch(mode=0o600)
            preparation = self.command("a", "NvimAIPrompt")
            self.ready("a", backend, 2)
            check(not self.events("a", backend, "input"), "fresh TUI does not receive premature context bytes")
            check("NvimAIPrompt again" in preparation, "fresh TUI explains the explicit prepare-again step\n" + preparation)
            mode = case.removeprefix("prompt-") if case != "prompt" else "split"
            (state / "http-response.fixture").write_text(mode)
            # There is no asynchronous replay: only this later public command
            # may deliver context after the native TUI is visibly ready.
            if mode in ("drop", "redirect", "timeout", "oversized"):
                self.command("a", 'lua vim.cmd.normal({args={"ggV"},bang=true}); vim.cmd.normal({args={string.char(27)},bang=true})')
                started = time.monotonic()
                delivered = self.command("a", "'<,'>NvimAIPrompt")
                check(time.monotonic() - started < 2.5, "HTTP publication failure has a total deadline")
                check("delivery is unconfirmed" in delivered and "retained" in delivered,
                      "unknown publication reports uncertainty without rollback\n" + delivered)
                contexts = list((self.root / "runtime/a/draft.nvim" / self.key(owner) / "contexts").iterdir())
                check(len(contexts) == 1 and contexts[0].read_text().startswith("local selected"),
                      "uncertain delivery retains its exact private selection")
                check(self.record("a")["review_id"] is not None, "uncertain publication retains the review")
                time.sleep(.3)
                check(len(self.http_events("a")) == 1, "uncertain publication is never retried automatically")
                check(not (state / "redirect-followed.fixture").exists(), "HTTP redirects are never followed")
                check(not self.events("a", backend, "input") and not self.events("a", backend, "turn-started"),
                      "uncertain publication neither types fallback input nor submits")
                self.command("a", "NvimAIClose")
                wait_for(lambda: not self.owned(owner), "uncertain companion closes explicitly")
                check(not any(path.exists() for path in contexts), "explicit close cleans only the retained context")
                print("ok - native UI " + case)
                return
            delivered = self.command("a", "NvimAIPrompt")
            check("not submitted; :NvimAIReview after edits" in delivered,
                  "first delivered OpenCode context explains explicit review after startup retry\n" + delivered)
            expected = "Regarding main.lua:1:1: "
            wait_for(lambda: self.http_events("a"), "prepared prompt uses the authenticated API", seconds=3)
            check(self.http_events("a") == [dict(path="/tui/append-prompt", text=expected, authenticated=True)],
                  "one append request publishes the exact context")
            check(not self.events("a", backend, "input"), "HTTP handoff never falls back to terminal input")
            check(not self.events("a", backend, "turn-started"), "preparing context never submits a prompt")
            if mode == "boundary":
                runtime = self.root / "runtime/a/draft.nvim" / self.key(owner)
                token = (runtime / "control-token").read_text().strip()
                for change in ({"token": "é" * 32}, {"launch": "0" * 32}, {"review_id": "review_" + "0" * 32},
                               {"text": "bad\x1binput"}, {"text": "x" * 2049}, {"method": "submit"}):
                    with socket.socket(socket.AF_UNIX) as connection:
                        connection.settimeout(2)
                        connection.connect(str(runtime / "prompt.sock"))
                        hello = b""
                        while not hello.endswith(b"\n"):
                            hello += connection.recv(256)
                        launch, identity, review = hello.decode().strip().split(":")
                        check(identity == self.key(owner), "private channel challenge matches the exact owner")
                        request = dict(schema=1, token=token, launch=launch, review_id=review, text="private reference")
                        request.update(change)
                        connection.sendall((json.dumps(request) + "\n").encode())
                        check(connection.recv(64) == b"refused\n", "invalid private request is refused before HTTP")
                check(len(self.http_events("a")) == 1, "malformed or stale requests never reach OpenCode")
            # Reconnect to an already writable activation: the launcher retains
            # its password, without adding credentials to the durable record.
            self.reconnect("a", backend, 2)
            self.command("a", "NvimAIPrompt")
            check(self.http_events("a") == [dict(path="/tui/append-prompt", text=expected, authenticated=True)] * 2,
                  "an explicit prompt after Neovim restart uses the same live private channel")
            if mode == "boundary":
                (runtime / "prompt.sock").rename(runtime / "moved-prompt.fixture")
                replacement = runtime / "prompt.sock"
                replacement.write_text("replacement must survive cleanup\n")
                self.command("a", "NvimAIPrompt")
                check(len(self.http_events("a")) == 2, "replaced socket cannot receive context")
                self.command("a", "NvimAIClose")
                wait_for(lambda: not self.owned(owner), "replaced-channel companion closes explicitly")
                check(replacement.read_text() == "replacement must survive cleanup\n",
                      "launcher cleanup never unlinks a replacement inode")
        elif case == "close":
            (state / "signal-exit.fixture").touch(mode=0o600)
            self.schedule("NvimAIClose")
            wait_for(lambda: not self.owned(owner), "explicit close removes only its pane")
            time.sleep(0.2)
            output = self.screen(owner)
            check("AI companion failed" not in output and "vim.schedule callback" not in output,
                  "intentional native close must not display an unexpected-failure warning\n" + output)
        elif case == "review-conflict":
            self.command("a", "NvimAIPrompt")
            self.ready("a", backend, 2)
            self.command("a", 'lua vim.api.nvim_buf_set_lines(0, 0, -1, false, {"saved Neovim edit"})')
            self.command("a", "write")
            self.command("a", 'lua vim.api.nvim_buf_set_lines(0, 0, -1, false, {"unsaved user edit"})')
            source = self.root / "root/main.lua"
            source.write_text("external disk edit\n")
            self.schedule("NvimAIReview")
            output = wait_for(lambda: self.screen(owner) if "[conflicted] main.lua" in self.screen(owner) else "",
                              "native review identifies the conflicted file")
            selected = re.search(r"(\d+): \[conflicted\] main\.lua", output)
            check(selected is not None, "conflicted path is an observed picker choice")
            self.tm("send-keys", "-t", owner, "-l", selected.group(1))
            self.tm("send-keys", "-t", owner, "Enter")
            try:
                wait_for(lambda: "Writer: mixed" in self.screen(owner) and "press m" in self.screen(owner),
                         "native conflict review explains manual resolution")
            except AssertionError as error:
                raise AssertionError(str(error) + "\n" + self.screen(owner)) from None
            check(source.read_text() == "external disk edit\n", "opening conflict review never rejects disk changes")
            expression = 'lua vim.print({ vim.bo[vim.fn.bufnr(' + json.dumps(str(source)) + ')].modified, vim.fn.getbufline(' + json.dumps(str(source)) + ', 1, "$"), vim.fn.maparg("R", "n") })'
            result = self.command("a", expression)
            check('true' in result and 'unsaved user edit' in result and '""' in result,
                  "conflict review preserves unsaved edits and has no reject mapping")
        elif case in ("review", "review-reentry"):
            self.command("a", "edit created.txt")
            self.command("a", "NvimAIPrompt")
            self.ready("a", backend, 2)
            if case == "review-reentry":
                self.command("a", 'autocmd BufReadPost created.txt ++once lua vim.schedule(function() vim.cmd("NvimAIReview") end)')
            (self.root / "root/created.txt").write_text("native-ui-review\n")
            if case == "review":
                self.schedule("NvimAIReview")
            output = wait_for(lambda: self.screen(owner) if "created.txt" in self.screen(owner) else "",
                              "native review observes created loaded file")
            time.sleep(0.3)
            output = self.screen(owner)
            check("Load File" not in output and "tracker is busy" not in output,
                  "clean-buffer review must not block in a file-change prompt or busy tracker\n" + output)
            output = wait_for(lambda: self.screen(owner) if "[unresolved] created.txt" in self.screen(owner) else "",
                              "native review picker displays the created file")
            selected = re.search(r"(\d+): \[unresolved\] created\.txt", output)
            check(selected is not None, "created file is an observed picker choice")
            self.tm("send-keys", "-t", owner, "-l", selected.group(1))
            self.tm("send-keys", "-t", owner, "Enter")
            wait_for(lambda: "Kind: absent" in self.screen(owner) and "native-ui-review" in self.screen(owner),
                     "native review opens the exact created-file diff")
            self.tm("send-keys", "-t", owner, "-l", "R")
            wait_for(lambda: not (self.root / "root/created.txt").exists(), "native R rejects the created file")
            wait_for(lambda: self.record("a")["review_id"] is None, "native rejection finishes review cleanup")
        else:
            raise AssertionError("unsupported native UI case")
        print("ok - native UI " + case)

    def version_upgrade_case(self, owner):
        self.command("a", "NvimAIBackend opencode")
        self.ready("a", "opencode", 1)
        self.command("a", "NvimAIPrompt")
        self.ready("a", "opencode", 2)
        wait_for(lambda: self.record("a")["sessions"]["opencode"] == "ses_lifecycle", "saved session before upgrade")
        before = self.record("a")
        check(before["review_id"] is not None, "real review baseline before upgrade")
        pane = self.owned(owner)[0]["pane_id"]
        profile = self.state("a") / "backends/opencode/profiles" / before["opencode_profile"]["token"]
        published = {str(path.relative_to(profile)): path.read_bytes() for path in profile.rglob("*") if path.is_file()}
        self.command("a", "qa!")
        wait_for(lambda: self.tm("display-message", "-p", "-t", owner, "#{pane_dead}") == "1", "old owner exits")
        # Seed only this owned fixture's pre-upgrade reference and pane tuple.
        # Recovery must never rewrite or authorize the immutable old generation.
        legacy = self.record("a")
        legacy["opencode_profile"]["version"] = "1.18.28"
        record_path = self.state("a") / "record.json"
        record_path.write_text(json.dumps(legacy, separators=(",", ":")) + "\n")
        self.tm("set-option", "-p", "-t", pane, "@draft_nvim_opencode_version", "1.18.28")
        self.start_owner("a", owner, native_ui=True)
        self.command("a", "NvimAIOpen")
        check(self.record("a") == legacy, "rejected old pane does not discard durable state")
        self.ready("a", "opencode", 2)
        self.command("a", 'lua vim.api.nvim_buf_set_lines(0, 0, 1, false, {"unsaved upgrade sentinel"})')
        source = self.source_snapshot()
        self.tm("send-keys", "-t", owner, "Escape")
        self.tm("send-keys", "-t", owner, "-l", ":NvimAIClose")
        self.tm("send-keys", "-t", owner, "Enter")
        wait_for(lambda: "verified identity-matching AI pane" in self.screen(owner), "native recovery confirmation")
        self.tm("send-keys", "-t", owner, "Enter")  # Default is Cancel.
        wait_for(lambda: "AI stale pane close cancelled" in self.screen(owner), "declined recovery")
        check(self.record("a") == legacy and self.owned(owner)[0]["pane_id"] == pane, "declined recovery preserves pane and record")
        self.tm("send-keys", "-t", owner, "Enter", "Escape")
        self.tm("send-keys", "-t", owner, "-l", ":NvimAIClose")
        self.tm("send-keys", "-t", owner, "Enter")
        wait_for(lambda: "verified identity-matching AI pane" in self.screen(owner), "repeated recovery confirmation")
        self.tm("send-keys", "-t", owner, "c")  # Continue, not Enter's Cancel default.
        wait_for(lambda: not self.owned(owner), "explicit recovery closes only its verified pane")
        after = self.record("a")
        check(after["opencode_profile"] is None, "close clears the legacy reference")
        check((after["review_id"], after["sessions"]) == (before["review_id"], before["sessions"]), "recovery preserves review and saved sessions")
        self.command("a", "NvimAIOpen")
        self.ready("a", "opencode", 3)
        current = self.record("a")
        check(current["opencode_profile"]["version"] == "1.18.30", "fresh generation uses current audited version")
        check(current["opencode_profile"]["token"] != before["opencode_profile"]["token"], "explicit reopen creates a new generation")
        check(current["review_id"] == before["review_id"] and current["sessions"] == before["sessions"], "fresh activation retains review and session references")
        check(published == {str(path.relative_to(profile)): path.read_bytes() for path in profile.rglob("*") if path.is_file()}, "old generation is never rewritten or removed")
        check(self.source_snapshot() == source, "upgrade recovery preserves unsaved editor contents")
        check(not self.events("a", "opencode", "input"), "upgrade recovery never replays terminal input")
        self.command("a", "NvimAIClose")
        wait_for(lambda: not self.owned(owner), "fresh companion closes")

    def cleanup(self):
        # Dismiss real dialogs only during cleanup; never mask their test result.
        for pane, _, _ in self.owners.values():
            self.tm("send-keys", "-t", pane, "C-c", "Enter")
        super().cleanup()


def main():
    signal.alarm(55)
    lifecycle = NativeUI(*sys.argv[1:7])
    try:
        lifecycle.exercise_case(sys.argv[7])
    finally:
        lifecycle.cleanup()


if __name__ == "__main__":
    main()
