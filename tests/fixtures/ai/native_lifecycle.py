"""Public Neovim commands against real private tmux and OS confinement.

Only provider processes and UI choices are faked. Evidence comes from external
pane metadata, durable records, and bounded fake-process sentinels, not internals
or scraped terminal output.
"""

import hashlib
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import time


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def wait_for(probe, label, seconds=5):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = probe()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError(f"timed out: {label}")


class Lifecycle:
    def __init__(self, root, socket, tmux, nvim, python, nvim_root):
        self.root, self.socket, self.nvim_root = Path(root), socket, Path(nvim_root)
        self.nvim, self.python = str(Path(nvim).resolve()), str(Path(python).resolve())
        for path in (root, socket, tmux, nvim, python, nvim_root):
            check(Path(path).is_absolute() and not any(ord(c) < 32 or 127 <= ord(c) < 160 for c in path), "unsafe fixture path")
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("NVIM", "OPENCODE", "CODEX", "CLAUDE", "XDG_")) and k not in ("TMUX", "TMUX_PANE")}
        self.env.update(HOME=str(self.root / "home"), PATH=f"{self.root}/bin:{os.environ['PATH']}", SHELL="/bin/sh", NVIM_LOG_FILE="/dev/null", XDG_CONFIG_HOME=f"{self.root}/home/.config", XDG_DATA_HOME=f"{self.root}/home/.local/share")
        self.owners = {}
        shim = self.root / "bin/tmux"
        shim.write_text(f'#!/bin/sh\n[ "$#" -ge 2 ] && [ "$1" = -S ] && [ "$2" = {shlex.quote(socket)} ] || exit 97\nexec {shlex.quote(tmux)} "$@"\n')
        shim.chmod(0o700)
        self.tmux = str(shim)
        self.run([self.python, "-I", "-B", str(self.nvim_root / "tests/fixtures/ai/native_cli.py"), "--install", str(self.root / "bin"), self.python])
        config = self.root / "home/.config"
        config.mkdir(mode=0o700)
        (config / "nvim").symlink_to(self.nvim_root, target_is_directory=True)
        (self.root / "home/.opencode").mkdir(mode=0o700)
        opencode_bin = self.root / "home/.opencode/bin"
        opencode_bin.mkdir(mode=0o700)
        (self.root / "bin/opencode").rename(opencode_bin / "opencode")
        (self.root / "bin/opencode").symlink_to(opencode_bin / "opencode")
        codex_home = self.root / "home/.codex"
        codex_home.mkdir(mode=0o700)
        self.codex_config = codex_home / "config.toml"
        self.codex_config.write_text('model = "native-fixture-model"\n')
        self.codex_config.chmod(0o600)
        auth_dir = self.root / "home/.local/share/opencode"
        auth_dir.mkdir(mode=0o700, parents=True)
        (auth_dir / "auth.json").write_text('{"openai":{"type":"api","key":"lifecycle-fake-credential"}}\n')
        (auth_dir / "auth.json").chmod(0o600)
        (self.root / "root/main.lua").write_text("local selected = 'private selection canary'\nreturn selected\n")
        (self.root / "outside/scope.txt").write_text("outside grant canary\n")
        self.run(["git", "init", "--quiet", str(self.root / "root")])
        check(self.run([self.tmux, "list-sessions"], ok=False).returncode == 97, "tmux shim allowed a default-server command")
        self.tm("set-option", "-g", "remain-on-exit", "on")

    def run(self, argv, ok=True, timeout=10):
        result = subprocess.run(argv, env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, check=False)
        if ok:
            check(result.returncode == 0, f"command failed ({Path(argv[0]).name}): {result.stderr[:2000]}")
        return result

    def tm(self, *args):
        return self.run([self.tmux, "-S", self.socket, *args]).stdout.rstrip("\n")

    def start_owner(self, name, pane, native_ui=False):
        state, runtime = self.root / "state" / name, self.root / "runtime" / name
        state.mkdir(mode=0o700, exist_ok=True)
        runtime.mkdir(mode=0o700, exist_ok=True)
        sock = runtime / "nvim.sock"
        notifications = runtime / "notifications.ndjson"
        setup = 'vim.o.shell="/bin/sh"; vim.notify=function(message) vim.fn.writefile({message},' + json.dumps(str(notifications)) + ',"a") end; vim.ui.select=function(items,_,callback) callback(items[#items],#items) end; require("draft").setup({confirm=function() return true end})'
        if native_ui:
            setup = 'vim.o.shell="/bin/sh"; vim.o.cmdheight=3; require("draft").setup({keymaps=true})'
        argv = ["env", "-u", "NVIM_APPNAME", *(f"{key}={value}" for key, value in self.env.items() if key in ("HOME", "PATH", "SHELL", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "NVIM_LOG_FILE")), f"XDG_STATE_HOME={state}", f"XDG_RUNTIME_DIR={runtime}", f"DRAFT_TEST_RUNTIME={self.nvim_root}", self.nvim, "--clean", "--headless", "-u", "NONE", "-i", "NONE", "--listen", str(sock), "--cmd", "lua vim.opt.rtp:prepend(vim.env.DRAFT_TEST_RUNTIME)", "-c", f"cd {self.root / 'root'}", "-c", f"edit {self.root / 'root/main.lua'}", "-c", f"lua {setup}"]
        if native_ui:
            argv.remove("--headless")
        self.tm("respawn-pane", "-k", "-t", pane, "exec " + shlex.join(argv))
        self.owners[name] = (pane, sock, notifications)
        wait_for(sock.exists, f"{name} Neovim socket")

    def command(self, name, command):
        if command == "qa!":
            command = "lua vim.defer_fn(function() vim.cmd('qa!') end, 50)"
        return self.run([self.nvim, "--server", str(self.owners[name][1]), "--remote-expr", f"execute({json.dumps(command)})"]).stdout

    def panes(self):
        fields = ("pane_id", "pane_left", "pane_width", "pane_dead", "pane_active", "@draft_nvim", *("@draft_nvim_" + name for name in ("key", "owner", "root", "backend", "state", "grants", "session", "opencode_token", "opencode_fingerprint", "opencode_version")))
        output = self.tm("list-panes", "-a", "-F", "\t".join("#{" + field + "}" for field in fields))
        return [dict(zip(fields, line.split("\t"))) for line in output.splitlines()]

    def owned(self, owner):
        return [pane for pane in self.panes() if pane.get("@draft_nvim") == "1" and pane.get("@draft_nvim_owner") == owner]

    def key(self, owner):
        stat = Path(self.socket).stat()
        namespace = f"tmux:{self.socket}:{stat.st_dev}:{stat.st_ino}"
        return hashlib.sha256(f"{namespace}\0{owner}\0{self.root}/root".encode()).hexdigest()[:32]

    def state(self, name):
        return self.root / "state" / name / "draft.nvim" / self.key(self.owners[name][0])

    def record(self, name):
        return json.loads((self.state(name) / "record.json").read_text())

    def events(self, name, backend, kind=None):
        path = self.state(name) / "backends" / backend / "lifecycle.ndjson"
        if not path.exists():
            return []
        check(path.stat().st_size < 131072, "bounded fake CLI sentinels")
        values = [json.loads(line) for line in path.read_text().splitlines() if line.endswith("}")]
        return [value for value in values if kind is None or value["event"] == kind]

    def ready(self, name, backend, count):
        wait_for(lambda: len(self.events(name, backend, "ready")) >= count, f"{name} {backend} native launch {count}")
        check(len(self.events(name, backend, "ready")) == count, "exactly one native launch per action")
        check(self.owned(self.owners[name][0])[0]["pane_dead"] == "0", "native companion stays alive")

    def http_events(self, name):
        path = self.state(name) / "backends/opencode/http.ndjson"
        if not path.exists():
            return []
        check(path.stat().st_size < 131072, "bounded fake HTTP sentinels")
        return [json.loads(line) for line in path.read_text().splitlines()]

    def no_replayed_input(self, backend, first_launch):
        launch = 0
        for event in self.events("a", backend):
            if event["event"] == "ready":
                launch += 1
            elif launch >= first_launch:
                check(event["event"] not in ("input", "turn-started"),
                      "scope changes and backend switches must not replay even unsubmitted input")

    def reconnect(self, name, backend, count):
        owner = self.owners[name][0]
        pane = self.owned(owner)[0]["pane_id"]
        previous_signals = self.events(name, backend, "signal")
        self.command(name, "qa!")
        wait_for(lambda: self.tm("display-message", "-p", "-t", owner, "#{pane_dead}") == "1", "owner exits")
        check(self.owned(owner)[0]["pane_id"] == pane and self.owned(owner)[0]["pane_dead"] == "0", "AI survives owner exit")
        check(self.events(name, backend, "signal") == previous_signals, "owner exit does not signal native backend")
        self.start_owner(name, owner)
        self.tm("select-pane", "-t", owner)
        self.command(name, "NvimAIOpen")
        wait_for(lambda: self.owned(owner)[0]["pane_active"] == "1", "reconnect completes validation and focuses companion")
        self.ready(name, backend, count)
        check(self.owned(owner)[0]["pane_id"] == pane, "same owner reconnects to exact surviving pane")

    def exercise(self):
        owner_a = self.tm("display-message", "-p", "-t", "nvim-ai:0.0", "#{pane_id}")
        owner_b = self.tm("split-window", "-v", "-d", "-P", "-F", "#{pane_id}", "-t", owner_a, "exec sleep 300")
        self.start_owner("a", owner_a)
        self.start_owner("b", owner_b)
        self.command("a", "NvimAIBackend codex")
        wait_for(lambda: self.owned(owner_a), "owner A Codex companion")
        panes = self.owned(owner_a)
        check(len(panes) == 1 and panes[0]["@draft_nvim_backend"] == "codex", "one Codex companion")
        self.ready("a", "codex", 1)
        check(self.codex_config.read_text() == 'model = "native-fixture-model"\n', "native trust does not mutate global Codex configuration")
        pane_a = panes[0]["pane_id"]
        expected = dict(key=self.key(owner_a), owner=owner_a, root=str(self.root / "root"), backend="codex", state="open", grants="0", session="last", opencode_token="", opencode_fingerprint="", opencode_version="")
        for key, value in expected.items():
            check(panes[0]["@draft_nvim_" + key] == value, f"exact {key} pane option")
        owner = next(pane for pane in self.panes() if pane["pane_id"] == owner_a)
        check(int(panes[0]["pane_left"]) > int(owner["pane_left"]), "AI pane is right of owner")
        total_width = int(owner["pane_width"]) + int(panes[0]["pane_width"]) + 1
        check(abs(int(panes[0]["pane_width"]) - total_width * 0.4) <= 1, "AI split is 40 percent within rounding")
        self.tm("select-pane", "-t", owner_a)
        self.command("a", "NvimAIOpen")
        check(len(self.owned(owner_a)) == 1 and self.owned(owner_a)[0]["pane_active"] == "1", "repeated open focuses existing pane")
        self.ready("a", "codex", 1)
        self.command("b", "NvimAIBackend codex")
        wait_for(lambda: self.owned(owner_b), "owner B Codex companion")
        self.ready("b", "codex", 1)
        pane_b = self.owned(owner_b)[0]["pane_id"]
        owner_b_record = self.record("b")
        check(pane_a != pane_b and self.key(owner_a) != self.key(owner_b), "owners have independent companions and keys")
        self.reconnect("a", "codex", 1)
        self.command("a", "NvimAIBackend claude")
        self.ready("a", "claude", 1)
        check(self.owned(owner_a)[0]["pane_id"] == pane_a, "switch reuses owner pane")
        saved = self.record("a")["sessions"]
        check(saved["codex"] == "last" and saved["claude"] == self.events("a", "claude", "ready")[0]["session"], "independent saved Codex and Claude references")
        self.command("a", "NvimAIBackend opencode")
        self.ready("a", "opencode", 1)
        wait_for(lambda: self.record("a")["sessions"]["opencode"] == "ses_lifecycle", "exact synthetic OpenCode session event")
        profile = self.record("a")["opencode_profile"]
        check(self.events("a", "opencode", "ready")[0]["config_read_only"] is True, "managed configuration is read-only in the native TUI")
        check(profile["version"] == "1.18.30", "audited managed profile version")
        for field in ("token", "fingerprint", "version"):
            check(self.owned(owner_a)[0]["@draft_nvim_opencode_" + field] == profile[field], f"exact nonsecret OpenCode {field}")
        profile_root = self.state("a") / "backends/opencode/profiles" / profile["token"]
        check(json.loads((profile_root / "credentials/auth.json").read_text()) == {"openai": {"type": "api", "key": "lifecycle-fake-credential"}}, "managed profile contains only the synthetic credential")
        published = {str(path.relative_to(profile_root)): (path.stat().st_ino, path.stat().st_mtime_ns, hashlib.sha256(path.read_bytes()).hexdigest()) for path in profile_root.rglob("*") if path.is_file()}
        self.reconnect("a", "opencode", 1)
        check(self.record("a")["opencode_profile"] == profile, "exact profile adoption after owner restart")
        check(published == {str(path.relative_to(profile_root)): (path.stat().st_ino, path.stat().st_mtime_ns, hashlib.sha256(path.read_bytes()).hexdigest()) for path in profile_root.rglob("*") if path.is_file()}, "reconnect does not republish managed profile")
        check(self.events("a", "opencode", "ready")[0]["root_writable"] is False, "opening alone keeps the project read-only")
        self.command("a", "lua vim.cmd.normal({args={'ggV'},bang=true}); vim.cmd.normal({args={string.char(27)},bang=true})")
        self.command("a", "'<,'>NvimAIPrompt")
        self.ready("a", "opencode", 2)
        check(not self.events("a", "opencode", "input"), "fresh TUI never receives context before explicit readiness retry")
        self.command("a", "'<,'>NvimAIPrompt")
        wait_for(lambda: self.http_events("a"), "prepared selection reference is published")
        review = self.record("a")["review_id"]
        check(isinstance(review, str) and review.startswith("review_") and len(review) == 39, "one exact review ID is established")
        check([path.name for path in (self.state("a") / "reviews").iterdir()] == [review[7:]], "exactly one private review baseline")
        contexts = list((self.root / "runtime/a/draft.nvim" / self.key(owner_a) / "contexts").iterdir())
        check(len(contexts) == 1 and contexts[0].read_text() == "local selected = 'private selection canary'\n", "exact visual selection is staged privately")
        expected_prompt = f"Use the exact selection from main.lua:1-1 stored at {contexts[0]}: "
        check(self.http_events("a") == [dict(path="/tui/append-prompt", text=expected_prompt, authenticated=True)],
              "only the short context reference is published, once")
        check(not self.events("a", "opencode", "input"), "OpenCode handoff never types into the terminal")
        check(not self.events("a", "opencode", "turn-started"), "Neovim never submits the prepared prompt")
        check(self.events("a", "opencode", "ready")[-1]["root_writable"] is True, "prompt relaunches the exact review writable")
        check(self.record("a")["opencode_profile"] == profile, "writable relaunch retains the exact profile tuple")
        check(not any(name.startswith("draft.nvim-") for name in self.tm("list-buffers", "-F", "#{buffer_name}").splitlines()), "paste leaves no managed tmux buffer")
        self.tm("send-keys", "-t", pane_a, "C-u")
        self.tm("send-keys", "-l", "-t", pane_a, f"scope {self.root}/outside/.")
        self.tm("send-keys", "-t", pane_a, "Enter")
        self.ready("a", "opencode", 3)
        check(self.record("a")["grants"] == [str(self.root / "outside")], "approved scope is canonical and durable")
        check(self.record("a")["opencode_profile"] == profile, "scope relaunch preserves the exact managed profile")
        check(self.events("a", "opencode", "ready")[-1]["outside_writable"] is True, "approved outside path is actually writable")
        check(len(self.events("a", "opencode", "turn-started")) == 1, "only the explicitly submitted scope command starts a turn")
        check(self.owned(owner_a)[0]["@draft_nvim_grants"] == hashlib.sha256(str(self.root / "outside").encode()).hexdigest()[:16], "pane publishes the canonical grant hash")
        self.command("a", "NvimAIBackend claude")
        self.ready("a", "claude", 2)
        check(self.record("a")["grants"] == [str(self.root / "outside")] and self.events("a", "claude", "ready")[-1]["outside_writable"] is True, "grant survives backend switch and remains confined writable")
        self.command("a", "NvimAIBackend opencode")
        self.ready("a", "opencode", 4)
        profile = self.record("a")["opencode_profile"]
        self.command("a", f"NvimAIGrants {self.root}/outside")
        self.ready("a", "opencode", 5)
        check(self.record("a")["grants"] == [] and self.owned(owner_a)[0]["@draft_nvim_grants"] == "0", "revocation removes the grant and its pane hash")
        check(self.events("a", "opencode", "ready")[-1]["outside_writable"] is False, "revocation actually removes outside write access")
        check(self.record("a")["opencode_profile"] == profile, "revocation preserves the exact current profile")
        check(len(self.events("a", "opencode", "turn-started")) == 1 and not self.events("a", "claude", "turn-started"), "grant changes and backend switches do not automatically continue the prompt")
        self.no_replayed_input("opencode", 3)
        self.no_replayed_input("claude", 2)
        exact_tags = {key: value for key, value in self.owned(owner_a)[0].items() if key.startswith("@draft_nvim")}
        duplicate = self.tm("split-window", "-h", "-d", "-P", "-F", "#{pane_id}", "-t", owner_a, "exec sleep 300")
        try:
            for key, value in exact_tags.items():
                self.tm("set-option", "-p", "-t", duplicate, key, value)
            self.tm("select-pane", "-t", owner_a)
            notices = self.owners["a"][2]
            old_size = notices.stat().st_size if notices.exists() else 0
            self.command("a", "NvimAIOpen")
            diagnostic = notices.read_text()[old_size:] if notices.exists() else ""
            check(pane_a in diagnostic and duplicate in diagnostic, "duplicate refusal names both exact pane IDs")
            check(len(self.owned(owner_a)) == 2 and self.tm("display-message", "-p", "-t", owner_a, "#{pane_active}") == "1", "duplicate open refuses to focus or create a companion")
            self.ready("a", "opencode", 5)
        finally:
            self.tm("kill-pane", "-t", duplicate)
        self.command("a", "NvimAIOpen")
        check(len(self.owned(owner_a)) == 1 and self.owned(owner_a)[0]["pane_active"] == "1", "removing the duplicate restores normal focus")
        sessions = self.record("a")["sessions"]
        self.command("a", "NvimAIClose")
        wait_for(lambda: not self.owned(owner_a), "owned companion is closed")
        closed = self.record("a")
        check(closed["opencode_profile"] is None and closed["grants"] == [], "close clears active profile and grants")
        check(closed["sessions"] == sessions, "close remembers independent backend sessions")
        check(not any(path.exists() for path in contexts), "close removes private context files")
        check(self.record("b") == owner_b_record, "owner A operations do not mutate owner B's durable record")
        check(self.owned(owner_b)[0]["pane_id"] == pane_b and len(self.events("b", "codex", "ready")) == 1 and not self.events("b", "codex", "signal"), "owner B remains untouched")
        check(not any(name.startswith("draft.nvim-") for name in self.tm("list-buffers", "-F", "#{buffer_name}").splitlines()), "no managed paste buffer survives the lifecycle")
        check(self.codex_config.read_text() == 'model = "native-fixture-model"\n', "all native relaunches leave global Codex configuration unchanged")

    def cleanup(self):
        for name, (_, sock, _) in self.owners.items():
            if sock.exists():
                for command in ("NvimAIClose", "qa!"):
                    try:
                        self.command(name, command)
                    except (AssertionError, subprocess.TimeoutExpired):
                        pass


def main():
    # An outer deadline also bounds unexpected RPC/fixture failures.
    signal.alarm(180)
    lifecycle = Lifecycle(*sys.argv[1:])
    try:
        lifecycle.exercise()
    except Exception:
        print("private panes: " + json.dumps(lifecycle.panes()), file=sys.stderr)
        for name, (_, _, path) in lifecycle.owners.items():
            if path.exists():
                print(f"{name} notifications: {path.read_text()[-4000:]}", file=sys.stderr)
            for error_log in (lifecycle.state(name) / "backends/opencode").glob("server-*.stderr"):
                print(f"{name} fake server stderr: {error_log.read_text()[-2000:]}", file=sys.stderr)
        raise
    finally:
        lifecycle.cleanup()


if __name__ == "__main__":
    main()
