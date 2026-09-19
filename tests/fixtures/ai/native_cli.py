"""Strict fake provider executable for the public-command native lifecycle test.

Installed under all three provider names before any owner starts. Unsupported
invocations fail closed: never delegate to a real CLI or print argument values.
"""

import base64
import errno
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import sys
import termios
import tty
import time
import uuid


TOOLS = ("invalid", "question", "bash", "read", "glob", "grep", "edit", "write", "task", "webfetch", "todowrite", "websearch", "skill")
AGENTS = ("build", "plan", "compaction", "summary", "title")


def unsupported():
    print(f"unsupported fake CLI shape: {Path(sys.argv[0]).name}/{len(sys.argv) - 1}", file=sys.stderr)
    raise SystemExit(96)


def writable(path):
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_NOFOLLOW)
    except OSError as error:
        if error.errno not in (errno.EROFS, errno.EACCES, errno.ENOENT):
            raise
        return False
    os.close(descriptor)  # Opening alone never changes the test file's bytes.
    return True


def native_terminal(state, session, resumed, config_read_only=None):
    descriptor = os.open(state / "lifecycle.ndjson", os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)

    def event(kind, **fields):
        payload = (json.dumps({"event": kind, **fields}) + "\n").encode()
        if os.fstat(descriptor).st_size + len(payload) > 131072:
            raise AssertionError("fake CLI sentinel limit exceeded")
        os.write(descriptor, payload)

    def stopped(number, _frame):
        event("signal", number=number)
        raise SystemExit(128 + number if (state / "signal-exit.fixture").exists() else 0)

    def resized(_number, _frame):
        size = os.get_terminal_size(0)
        event("resize", columns=size.columns, lines=size.lines)
        print(f"\033[2J\033[HFAKE CLI {size.columns}x{size.lines}", flush=True)

    previous = termios.tcgetattr(0)
    pending = bytearray()
    try:
        signal.signal(signal.SIGHUP, stopped)
        signal.signal(signal.SIGTERM, stopped)
        signal.signal(signal.SIGWINCH, resized)
        # Native TUIs may discard startup input while initializing terminal mode.
        # The regression case makes that window deterministic; the broad legacy
        # lifecycle case retains its original byte-preserving terminal behavior.
        flush = (state / "flush-startup-input.fixture").exists()
        if flush:
            time.sleep(0.3)
        tty.setraw(0, termios.TCSAFLUSH if flush else termios.TCSANOW)
        if config_read_only is not None:
            emit_graphics = os.environ.get("OPENTUI_GRAPHICS") != "0"
            event("graphics-probe", emitted=emit_graphics)
            if emit_graphics:
                # Real OpenTUI query and tmux passthrough framing.
                os.write(1, b"\x1bPtmux;\x1b\x1b_Gi=31337,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\x1b\\\x1b\\")
            # Captured OpenTUI 0.4.5 startup query for the Ms termcap value.
            event("termcap-probe", emitted=True)
            os.write(1, b"\x1bPtmux;\x1b\x1bP+q4d73\x1b\x1b\\\x1b\\")
        event("ready", session=session, resumed=resumed, config_read_only=config_read_only,
              root_writable=writable(Path.cwd() / "main.lua"),
              outside_writable=writable(Path.cwd().parent / "outside/scope.txt"))
        while True:
            data = os.read(0, 2048)
            if not data:
                break
            event("input", hex=data.hex())
            for value in data:
                if value == 21:  # Explicit harness Ctrl-U, never automatic submission.
                    pending.clear()
                elif value in (10, 13):
                    event("turn-started")
                    line = pending.decode("utf-8", errors="strict")
                    pending.clear()
                    if (state / "crash-terminal.fixture").exists() and line == "dirty-terminal":
                        os.write(1, b"\x1b[?1049h\x1b[?25l\x1b[?1003h\x1b[?1006h\x1b[?2004h\x1b[>1u")
                        event("dirty-terminal")
                    elif (state / "crash-terminal.fixture").exists() and line == "crash":
                        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
                        os.kill(os.getpid(), signal.SIGILL)  # Deliberately bypass finally.
                    elif line == "fixture-edit" and (state / "edit-review.fixture").exists():
                        # An explicitly submitted fixture command writes through
                        # the actual companion sandbox, not the host harness.
                        (Path.cwd() / "main.lua").write_text("hello from the companion\n")
                        event("file-edited", path="main.lua")
                    elif line.startswith("scope "):
                        result = subprocess.run(
                            [os.environ["NVIM_AI_CONTROL_PYTHON"], "-I", "-B",
                             os.environ["NVIM_AI_CONTROL_HELPER"], "request-scope",
                             "--path", line[6:], "--reason", "private lifecycle fixture"],
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, timeout=35, check=False,
                        )
                        event("scope-result", code={0: "granted", 2: "refused"}.get(result.returncode, "unconfirmed"))
                elif len(pending) < 65536:
                    pending.append(value)
    finally:
        termios.tcsetattr(0, termios.TCSANOW, previous)
        os.close(descriptor)


def opencode(args):
    help_output = {
        ("--version",): "1.18.30",
        ("--help",): "--pure serve attach",
        ("serve", "--help"): "--hostname --port",
        ("attach", "--help"): "--dir --session OPENCODE_SERVER_PASSWORD",
    }
    if tuple(args) in help_output:
        replay_opencode_artifacts(False)
        print(help_output[tuple(args)], file=sys.stdout if args == ["--version"] else sys.stderr)
        return
    if args == ["--pure", "agent", "list"]:
        replay_opencode_artifacts(True)
        for name in AGENTS:
            print(f"{name} (primary)\n[]")
        return
    if len(args) == 4 and args[:3] == ["--pure", "debug", "agent"]:
        name = args[3]
        if name not in (*AGENTS, "general", "explore"):
            unsupported()
        replay_opencode_artifacts(True)
        if name in ("general", "explore"):
            print(f"Agent {name} not found, run 'opencode agent list' to get an agent list", file=sys.stderr)
            raise SystemExit(1)
        if name not in AGENTS:
            unsupported()
        if name in ("build", "plan"):
            rules = [{"permission": "*", "pattern": "*", "action": "allow"}]
            for permission in ("bash", "webfetch", "websearch", "external_directory", "doom_loop", "task", "skill", "edit"):
                action = "deny" if permission in ("task", "skill") or (permission == "edit" and name == "plan") else "allow" if permission == "edit" else "ask"
                rules.append(dict(permission=permission, pattern="*", action=action))
            agent = dict(native=True, mode="primary", tools={name: name not in ("task", "skill") for name in TOOLS}, permission=rules)
        else:
            agent = dict(native=True, hidden=True, tools={name: False for name in TOOLS}, permission=[dict(permission="*", pattern="*", action="deny")])
        print(json.dumps(agent))
        return
    if len(args) == 6 and args[:4] == ["--pure", "serve", "--hostname", "127.0.0.1"] and args[4] == "--port" and args[5].isdigit():
        password = os.environ["OPENCODE_SERVER_PASSWORD"]
        authorization = "Basic " + base64.b64encode(("opencode:" + password).encode()).decode()
        state = Path(os.environ["XDG_DATA_HOME"]).parent

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, _format, *_args):
                pass  # Never log headers, credentials, or URLs with user data.

            def do_POST(self):
                if self.path != "/tui/append-prompt" or self.headers.get("Authorization") != authorization:
                    self.send_error(403)
                    return
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 8192 or self.headers.get("Content-Type") != "application/json":
                    self.send_error(400)
                    return
                payload = json.loads(self.rfile.read(length))
                if set(payload) != {"text"} or not isinstance(payload["text"], str):
                    self.send_error(400)
                    return
                with (state / "http.ndjson").open("a") as output:
                    output.write(json.dumps(dict(path=self.path, text=payload["text"], authenticated=True)) + "\n")
                mode_file = state / "http-response.fixture"
                mode = mode_file.read_text().strip() if mode_file.exists() else "split"
                if mode == "drop":
                    return  # Published, but the client cannot know that from EOF.
                if mode == "redirect":
                    self.send_response(302)
                    self.send_header("Location", "/redirect-target")
                    self.end_headers()
                    return
                if mode == "timeout":
                    try:
                        self.wfile.write(b"HTTP/1.1 200 OK\r\nX-Delay: ")
                        self.wfile.flush()
                        for _ in range(30):
                            time.sleep(.1)
                            self.wfile.write(b"x")
                            self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                    return
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Transfer-Encoding" if mode == "chunked" else "Content-Length",
                                 "chunked" if mode == "chunked" else "9000" if mode == "oversized" else "4")
                self.end_headers()
                self.wfile.flush()
                time.sleep(.05)  # Header/body TCP fragmentation must not imply failure.
                try:
                    self.wfile.write(b"2\r\ntr\r\n2\r\nue\r\n0\r\n\r\n" if mode == "chunked" else b"x" * 9000 if mode == "oversized" else b"true")
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def do_GET(self):
                if self.path == "/redirect-target":
                    (state / "redirect-followed.fixture").touch(mode=0o600)
                if self.path != "/event" or self.headers.get("Authorization") != authorization:
                    self.send_error(403)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                # One content-free idle event establishes exact-session continuity.
                # There are no model events or provider requests, only heartbeats.
                event = dict(type="session.status", properties=dict(sessionID="ses_lifecycle", status=dict(type="idle")))
                try:
                    self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())
                    self.wfile.flush()
                    for _ in range(600):
                        self.wfile.write(b": heartbeat\n\n")
                        self.wfile.flush()
                        time.sleep(0.25)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        signal.signal(signal.SIGHUP, lambda *_: sys.exit(0))
        with ThreadingHTTPServer(("127.0.0.1", int(args[5])), Handler) as server:
            server.serve_forever(poll_interval=0.1)
        return
    if len(args) not in (5, 7) or args[:2] != ["--pure", "attach"] or args[3:5] != ["--dir", os.getcwd()]:
        unsupported()
    prefix = "http://127.0.0.1:"
    if not args[2].startswith(prefix) or not args[2][len(prefix):].isdigit() or not 0 < int(args[2][len(prefix):]) < 65536:
        unsupported()
    if len(args) == 7 and args[5:] != ["--session", "ses_lifecycle"]:
        unsupported()
    config = Path(os.environ["XDG_CONFIG_HOME"]) / "opencode"
    state = Path(os.environ["XDG_DATA_HOME"]).parent
    read_only = all(not writable(config / name) for name in ("opencode.json", "AGENTS.md", ".gitignore"))
    if not read_only:
        raise AssertionError("managed configuration must be read-only inside the native process")
    native_terminal(state, "ses_lifecycle", len(args) == 7, config_read_only=read_only)


def main():
    provider, args = Path(sys.argv[0]).name, sys.argv[1:]
    if provider == "native_cli.py" and len(args) == 3 and args[0] == "--install":
        target, python = Path(args[1]), Path(args[2]).resolve()
        if not target.is_absolute() or target.is_symlink() or target.stat().st_mode & 0o777 != 0o700:
            unsupported()
        source = Path(__file__).with_name("opencode_artifacts.py").read_text() + "\n" + Path(__file__).read_text()
        for name in ("codex", "claude", "opencode"):
            fake = target / name
            with fake.open("x") as output:
                output.write(f"#!{python} -IB\n" + source)
            fake.chmod(0o700)
        return
    if provider == "codex":
        if args == ["--version"]:
            print("codex-cli 0.100.0")
            return
        if args == ["login", "status"]:
            print("Logged in using ChatGPT", file=sys.stderr)
            return
        if args in (["--help"], ["resume", "--help"]):
            print("-C --sandbox --ask-for-approval --add-dir --last")
            return
        resumed = args[:2] == ["resume", "--last"]
        if resumed:
            args = args[2:]
        if len(args) < 6 or args[:1] != ["-C"] or args[2:6] != ["--sandbox", "workspace-write", "--ask-for-approval", "on-request"]:
            unsupported()
        if args[1] != os.getcwd():
            unsupported()
        state, session, tail = Path(os.environ["CODEX_HOME"]), "last", args[6:]
        # Match the native TUI's atomic trust-config save before it becomes
        # ready. The inherited global source must remain read-only.
        config = state / "config.toml"
        text = config.read_text()
        if 'model = "native-fixture-model"\n' not in text:
            raise AssertionError("Codex private configuration was not seeded")
        if writable(Path(os.environ["HOME"]) / ".codex/config.toml"):
            raise AssertionError("Codex global configuration is writable")
        temporary = state / ".config-trust-fixture"
        with temporary.open("x") as output:
            output.write(text if "# private trust persisted\n" in text else text + "# private trust persisted\n")
        temporary.chmod(0o600)
        temporary.replace(config)
    elif provider == "claude":
        if args == ["--version"]:
            print("2.1.0 (Claude Code)")
            return
        if args == ["auth", "status", "--json"]:
            print('{"loggedIn":true}')
            return
        if args == ["--help"]:
            print("--session-id --resume --permission-mode --add-dir --settings")
            return
        if len(args) < 6 or args[0] not in ("--session-id", "--resume") or args[2:5] != ["--permission-mode", "acceptEdits", "--settings"]:
            unsupported()
        session = str(uuid.UUID(args[1], version=4))
        if session != args[1] or sorted(json.loads(args[5])) != ["hooks"]:
            unsupported()
        state, resumed, tail = Path(os.environ["CLAUDE_CONFIG_DIR"]), args[0] == "--resume", args[6:]
    elif provider == "opencode":
        return opencode(args)
    else:
        unsupported()
    if len(tail) % 2 or any(tail[i] != "--add-dir" or not Path(tail[i + 1]).is_absolute() for i in range(0, len(tail), 2)):
        unsupported()
    native_terminal(state, session, resumed)


if __name__ == "__main__":
    main()
