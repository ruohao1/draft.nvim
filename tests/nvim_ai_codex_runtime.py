"""Offline runner checks and explicit pinned Codex sandbox acceptance."""
import importlib.util
import json
import os
from pathlib import Path
import select
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
POLICY = {"type": "workspaceWrite", "writableRoots": ["/tmp/project"],
          "networkAccess": False, "excludeTmpdirEnvVar": True, "excludeSlashTmp": True}


def provider_fixture():
    spec = importlib.util.spec_from_file_location(
        "codex_responses", ROOT / "tests/fixtures/ai/codex_responses.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Peer:
    """Discovery client only; production transport replaces this at integration."""
    def __init__(self, command, env, log):
        self.log = log.open("w+b")
        self.child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      stderr=self.log, env=env, start_new_session=True, umask=0o077)
        self.buffer, self.notifications = bytearray(), []
        self.serial = self.received = 0

    def send(self, method, params, request=True):
        self.serial += 1
        frame = {"method": method, "params": params}
        if request:
            frame["id"] = self.serial
        self.child.stdin.write(json.dumps(frame).encode() + b"\n")
        self.child.stdin.flush()
        return self.serial

    def read(self, deadline):
        while time.monotonic() < deadline:
            if b"\n" in self.buffer:
                line, _, self.buffer = self.buffer.partition(b"\n")
                message = json.loads(line)
                if "method" in message:
                    if "id" in message:
                        raise AssertionError("Unexpected server request: " + message["method"])
                    self.notifications.append(message)
                return message
            if select.select([self.child.stdout], [], [], .05)[0]:
                part = os.read(self.child.stdout.fileno(), 65536)
                if not part:
                    self.log.seek(0)
                    raise AssertionError("Premature Codex EOF: " + self.log.read(4096).decode())
                self.buffer.extend(part)
                self.received += len(part)
                if len(self.buffer) > 16 * 1024 * 1024 or self.received > 32 * 1024 * 1024:
                    raise AssertionError("Codex probe output budget exceeded")
        raise AssertionError("Codex probe deadline exceeded")

    def request(self, method, params):
        identifier = self.send(method, params)
        deadline = time.monotonic() + 15
        while True:
            value = self.read(deadline)
            if value.get("id") == identifier:
                return value

    def terminal(self, thread, turn):
        deadline = time.monotonic() + 25
        while True:
            for message in self.notifications:
                params = message.get("params", {})
                if (message["method"] == "turn/completed"
                        and params.get("threadId") == thread
                        and params.get("turn", {}).get("id") == turn):
                    return params["turn"]
            self.read(deadline)

    def close(self):
        if self.child.stdin and not self.child.stdin.closed:
            self.child.stdin.close()
        deadline = time.monotonic() + 10
        eof = False
        while time.monotonic() < deadline:
            if select.select([self.child.stdout], [], [], .05)[0]:
                if not os.read(self.child.stdout.fileno(), 65536):
                    eof = True
                    break
        try:
            code = self.child.wait(timeout=max(.1, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            self.child.kill()
            self.child.wait(timeout=5)
            code = None
        self.child.stdout.close()
        self.log.close()
        return code, eof


@unittest.skipUnless(os.environ.get("NVIM_AI_REAL_CODEX"), "pass --codex for pinned runtime acceptance")
class InstalledTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="draft-real-codex-", dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home, self.project = self.root / "home", self.root / "copies"
        self.codex_home = self.home / ".codex"
        for path in (self.home, self.codex_home, self.project):
            path.mkdir(mode=0o700)
        self.source = self.root / "real-project.txt"
        self.source.write_bytes(b"original text\n")
        (self.project / "example.txt").write_bytes(self.source.read_bytes())
        self.editor = socket.socket(socket.AF_UNIX)
        self.addCleanup(self.editor.close)
        self.socket_path = self.root / "editor.sock"
        self.editor.bind(str(self.socket_path))
        self.fixture = provider_fixture()
        self.provider = self.enterContext(self.fixture.Provider())
        self.peer = None
        self.addCleanup(self.cleanup_peer)
        self.serial = 0
        self.binary = Path(os.environ["NVIM_AI_REAL_CODEX"]).resolve(strict=True)
        version = subprocess.run([str(self.binary), "--version"],
            env={"PATH": os.defpath, "HOME": str(self.home), "CODEX_HOME": str(self.codex_home)},
            capture_output=True, timeout=10)
        self.assertEqual((version.returncode, version.stdout.strip()), (0, b"codex-cli 0.163.0"))
        (self.codex_home / "auth.json").write_text('{"OPENAI_API_KEY":"synthetic-codex-key"}')
        (self.codex_home / "auth.json").chmod(0o600)
        (self.codex_home / "config.toml").write_text(
            'model = "gpt-5.4"\nopenai_base_url = ' + json.dumps(self.provider.url) + '\n'
            'cli_auth_credentials_store = "file"\ncheck_for_update_on_startup = false\n'
            'web_search = "disabled"\napproval_policy = "never"\nsandbox_mode = "workspace-write"\n'
            '[sandbox_workspace_write]\nnetwork_access = false\n'
            'exclude_tmpdir_env_var = true\nexclude_slash_tmp = true\n'
            '[skills.bundled]\nenabled = false\n[analytics]\nenabled = false\n'
            '[agents]\nenabled = false\n[features]\nmemories = false\nplugins = false\n'
            'shell_snapshot = false\nmulti_agent = false\nmulti_agent_v2 = false\n'
            'responses_websockets = false\nresponses_websockets_v2 = false\n'
            'enable_request_compression = false\n')
        (self.codex_home / "config.toml").chmod(0o600)
        self.launch()
        result = self.rpc("command/exec", {"command": ["/usr/bin/true"],
            "cwd": "/tmp/project", "sandboxPolicy": POLICY, "timeoutMs": 5000})
        self.assertEqual(result["exitCode"], 0, "Nested sandbox unavailable: " + str(result))

    def launch(self):
        bwrap = shutil.which("bwrap")
        self.assertIsNotNone(bwrap)
        argv = [bwrap, "--new-session", "--unshare-pid", "--unshare-ipc", "--unshare-uts",
                "--die-with-parent", "--ro-bind", "/usr", "/usr"]
        for name in ("bin", "sbin", "lib", "lib64"):
            path = Path("/") / name
            if path.is_symlink():
                argv += ["--symlink", os.readlink(path), str(path)]
            elif path.is_dir():
                argv += ["--ro-bind", str(path), str(path)]
        argv += ["--tmpfs", "/tmp", "--dir", "/home", "--dir", "/run", "--dir", "/opt",
                 "--dev", "/dev", "--proc", "/proc", "--bind", str(self.home), "/home/agent",
                 "--bind", str(self.project), "/tmp/project", "--ro-bind", str(self.binary), "/opt/codex",
                 "--chdir", "/tmp/project", "--", "/opt/codex", "app-server", "--listen", "stdio://"]
        self.serial += 1
        self.peer = Peer(argv, {"PATH": "/usr/bin:/bin", "HOME": "/home/agent",
            "CODEX_HOME": "/home/agent/.codex", "LANG": "C.UTF-8", "SHELL": "/bin/sh", "TERM": "dumb"},
            self.root / f"worker-{self.serial}.stderr")
        initialized = self.rpc("initialize", {"clientInfo": {"name": "draft_probe", "version": "0.1"}})
        self.assertIn("0.163.0", initialized["userAgent"])
        self.peer.send("initialized", {}, request=False)

    def rpc(self, method, params):
        frame = self.peer.request(method, params)
        self.assertNotIn("error", frame, frame)
        return frame["result"]

    def thread(self, previous=None):
        params = {"cwd": "/tmp/project", "model": "gpt-5.4", "modelProvider": "openai",
                  "approvalPolicy": "never", "approvalsReviewer": "user", "sandbox": "workspace-write"}
        if previous:
            params.update(threadId=previous, excludeTurns=True)
        result = self.rpc("thread/resume" if previous else "thread/start", params)
        self.assertEqual(result["model"], "gpt-5.4")
        self.assertEqual(result["modelProvider"], "openai")
        self.assertEqual(result["cwd"], "/tmp/project")
        return result["thread"]["id"]

    def turn(self, thread, message):
        result = self.rpc("turn/start", {"threadId": thread,
            "input": [{"type": "text", "text": message, "text_elements": []}],
            "sandboxPolicy": POLICY, "approvalPolicy": "never", "approvalsReviewer": "user"})
        return result["turn"]["id"]

    def cleanup_peer(self):
        if self.peer is not None:
            self.peer.close()
            self.peer = None

    def stop(self, label):
        self.assertEqual(self.peer.close(), (0, True))
        self.peer = None
        inventory = []
        for path in sorted(self.codex_home.rglob("*")):
            node = path.lstat()
            inventory.append({"path": str(path.relative_to(self.codex_home)),
                              "mode": oct(stat.S_IMODE(node.st_mode)), "bytes": node.st_size,
                              "type": "dir" if stat.S_ISDIR(node.st_mode) else
                                      "file" if stat.S_ISREG(node.st_mode) else "other",
                              "nlink": node.st_nlink})
        print("\nCodex inventory " + label + ": " + json.dumps(inventory), flush=True)
        self.assertEqual(self.source.read_bytes(), b"original text\n")
        self.assertFalse(self.provider.errors, self.provider.errors)

    def test_pinned_cli_confinement(self):
        checks = f"""import errno, json, pathlib, socket
p = pathlib.Path('/tmp/project/probe.txt')
p.write_text('isolated')
checks = {{'workspace_write': p.read_text() == 'isolated'}}
for name, path in [('private_state_denied', '/home/agent/.codex/escape'), ('tmp_denied', '/tmp/escape')]:
    try:
        pathlib.Path(path).write_text('escape')
        checks[name] = False
    except OSError as error:
        if error.errno not in (errno.EACCES, errno.EPERM, errno.EROFS):
            raise
        checks[name] = True
try:
    s = socket.socket()
    s.close()
    checks['command_network_sockets_denied'] = False
except PermissionError:
    checks['command_network_sockets_denied'] = True
try:
    with socket.create_connection(('127.0.0.1', {self.provider.server.server_port}), timeout=1):
        pass
    checks['command_provider_connection_denied'] = False
except PermissionError:
    checks['command_provider_connection_denied'] = True
checks['host_project_absent'] = not pathlib.Path({str(self.source)!r}).exists()
checks['editor_socket_absent'] = not pathlib.Path({str(self.socket_path)!r}).exists()
print(json.dumps(checks))
assert all(checks.values()), checks
"""
        executed = self.rpc("command/exec", {"command": ["/usr/bin/python3", "-I", "-B", "-c", checks],
            "cwd": "/tmp/project", "sandboxPolicy": POLICY, "timeoutMs": 5000})
        self.assertEqual(executed["exitCode"], 0, executed)
        self.assertTrue(all(json.loads(executed["stdout"]).values()))
        self.provider.enqueue(self.fixture.answer("Engine reached the local provider."))
        thread = self.thread()
        turn = self.turn(thread, "Answer without editing.")
        self.assertEqual(self.peer.terminal(thread, turn)["status"], "completed")
        self.assertEqual(len(self.provider.requests), 1)
        self.stop("confined-completed")

    def test_empty_thread_resume_fails(self):
        thread = self.thread()
        self.stop("empty")
        self.launch()
        result = self.peer.request("thread/resume", {"threadId": thread})
        self.assertEqual(result["error"]["code"], -32600)
        self.assertEqual(len(self.provider.requests), 0)
        self.stop("empty-resume-refused")

    def test_completed_thread_resumes_after_exit(self):
        self.provider.enqueue(self.fixture.command("printf 'proposed text\\n' > /tmp/project/example.txt"))
        self.provider.enqueue(self.fixture.answer("copper-orbit-731"))
        thread = self.thread()
        turn = self.turn(thread, "Edit the selected copy.")
        self.assertEqual(self.peer.terminal(thread, turn)["status"], "completed")
        self.assertEqual((self.project / "example.txt").read_bytes(), b"proposed text\n")
        self.stop("completed-edit")
        self.launch()
        self.assertEqual(self.thread(thread), thread)
        self.provider.enqueue(self.fixture.answer("Resumed."))
        turn = self.turn(thread, "Continue without editing.")
        self.assertEqual(self.peer.terminal(thread, turn)["status"], "completed")
        self.assertEqual(len(self.provider.requests), 3)
        self.assertIn("copper-orbit-731", json.dumps(self.provider.requests[-1]["input"]))
        self.stop("resumed")

    def test_interrupt_requires_terminal(self):
        self.provider.hold()
        self.provider.enqueue(self.fixture.answer("Partial answer."))
        thread = self.thread()
        turn = self.turn(thread, "cancelled-user-marker")
        self.assertTrue(self.provider.streaming.wait(timeout=8))
        self.rpc("turn/interrupt", {"threadId": thread, "turnId": turn})
        self.assertEqual(self.peer.terminal(thread, turn)["status"], "interrupted")
        self.provider.release()
        self.stop("interrupted")
        self.launch()
        self.assertEqual(self.thread(thread), thread)
        self.provider.enqueue(self.fixture.answer("New explicit turn."))
        turn = self.turn(thread, "Continue explicitly.")
        self.assertEqual(self.peer.terminal(thread, turn)["status"], "completed")
        self.assertIn("cancelled-user-marker", json.dumps(self.provider.requests[-1]["input"]))
        self.stop("resumed-after-interrupt")


class RunnerTest(unittest.TestCase):
    def test_opt_in_is_explicit(self):
        with tempfile.TemporaryDirectory(prefix="draft-codex-runner-") as directory:
            root = Path(directory)
            tests = root / "tests"
            tests.mkdir()
            shutil.copyfile(ROOT / "tests/run.py", tests / "run.py")
            (tests / "nvim_ai_probe.py").write_text(
                "import json, os\nprint(json.dumps({k: v for k, v in os.environ.items() "
                "if 'CODEX' in k or k == 'OPENAI_API_KEY'}))\n")
            executable = root / "space 二" / "codex"
            executable.parent.mkdir()
            executable.write_text("#!/bin/sh\nexit 99\n")
            executable.chmod(0o700)
            env = dict(os.environ, NVIM_AI_REAL_CODEX="/ambient/codex",
                       OPENAI_API_KEY="never-inherit-this")
            for arguments, expected in (
                ([], {}),
                (["--codex", str(executable)], {"NVIM_AI_REAL_CODEX": str(executable)}),
            ):
                with self.subTest(arguments=arguments):
                    result = subprocess.run(
                        [sys.executable, "-I", "-B", str(tests / "run.py"),
                         *arguments, "nvim_ai_probe"], env=env, capture_output=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr.decode())
                    logs = sorted((root / ".test-results").glob("run-*/nvim_ai_probe.log"),
                                  key=lambda p: p.stat().st_mtime_ns)
                    self.assertEqual(json.loads(logs[-1].read_text()), expected)
            invalid = subprocess.run(
                [sys.executable, "-I", "-B", str(tests / "run.py"),
                 "--codex", "relative/codex", "nvim_ai_probe"],
                env=env, capture_output=True, timeout=10)
            self.assertEqual(invalid.returncode, 2)
            self.assertIn(b"--codex must be an absolute executable path", invalid.stderr)


if __name__ == "__main__":
    unittest.main()
