"""Opt-in pinned Codex refresh acceptance against a rotating loopback authority."""
from datetime import datetime
import importlib.util
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import tempfile
import time
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]


def load(path):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


fixture = load(ROOT / "tests/fixtures/ai/codex_auth.py")
responses = load(ROOT / "tests/fixtures/ai/codex_responses.py")
storage = load(ROOT / "scripts/nvim-ai-codex-store.py")
runtime = load(ROOT / "scripts/nvim-ai-codex-runtime.py")


class AuthorityTest(unittest.TestCase):
    def test_rotating_authority_rejects_a_reused_refresh_token(self):
        with fixture.Authority() as authority:
            def refresh(generation):
                body = {"grant_type": "refresh_token", "client_id": "synthetic-client",
                        "refresh_token": fixture.bundle(generation)["tokens"]["refresh_token"]}
                return urlopen(Request(authority.url + "/oauth/token", json.dumps(body).encode(),
                    {"Content-Type": "application/json"}), timeout=3)
            with refresh(0) as reply:
                self.assertTrue(json.load(reply)["refresh_token"] == fixture.bundle(1)["tokens"]["refresh_token"],
                                "Authority did not rotate")
            with self.assertRaises(HTTPError) as refused:
                refresh(0)
            self.assertEqual(refused.exception.code, 401)
            refused.exception.close()
            with refresh(1) as reply:
                self.assertEqual(reply.status, 200)
            self.assertEqual(authority.accepted_generations, [0, 1])
            self.assertEqual(authority.rejected_count, 1)
            self.assertFalse(authority.errors)


@unittest.skipUnless(os.environ.get("NVIM_AI_REAL_CODEX"), "pass --codex for pinned refresh acceptance")
class InstalledTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="draft-real-owned-auth-", dir="/tmp")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        version_home = self.root / "version-home"
        version_home.mkdir(mode=0o700)
        self.binary = Path(os.environ["NVIM_AI_REAL_CODEX"]).resolve(strict=True)
        version = subprocess.run([str(self.binary), "--version"], capture_output=True, timeout=10,
            env={"PATH": os.defpath, "HOME": str(version_home), "CODEX_HOME": str(version_home)})
        self.assertEqual((version.returncode, version.stdout.strip()), (0, b"codex-cli 0.163.0"))
        self.bwrap = os.path.realpath(shutil.which("bwrap"))
        runtime.require_owned_auth(self.bwrap)
        self.directory = self.root / "dedicated-login"
        self.directory.mkdir(mode=0o700)
        self.auth = self.directory / "auth.json"
        self.initial = fixture.bundle()
        self.auth.write_text(json.dumps(self.initial))
        self.auth.chmod(0o600)
        self.source = self.root / "real-project.txt"
        self.source.write_bytes(b"real project unchanged\n")
        self.authority = self.enterContext(fixture.Authority())
        self.store, self.peer = None, None
        self.serial = 0
        self.addCleanup(self.cleanup)
        self.new_store()
        self.launch()

    def new_store(self):
        self.store = storage.Store(self.root)
        self.store.initialize(auth_store=str(self.directory))

    def launch(self):
        self.store.acquire_auth()
        self.serial += 1
        task = self.root / f"turn-{self.serial}"
        self.project = task / "staging"
        self.project.mkdir(mode=0o700, parents=True)
        (self.project / "example.txt").write_bytes(self.source.read_bytes())
        argv, env = runtime.sandbox({"bwrap": self.bwrap, "codex": str(self.binary),
                                    "model": "openai/gpt-6.1-sol"}, task, self.store)
        self.assertNotIn(str(self.directory), argv)
        # Only this synthetic audit overrides endpoints. Production gains no routing option.
        profile = task / "agent/codex.toml"
        profile.write_text("chatgpt_base_url = " + json.dumps(self.authority.url)
            + "\nopenai_base_url = " + json.dumps(self.authority.url + "/v1") + "\n" + profile.read_text())
        env["CODEX_REFRESH_TOKEN_URL_OVERRIDE"] = self.authority.url + "/oauth/token"
        self.notifications = []
        self.session = None
        self.peer = self.store.start(argv, env=env, on_notification=self.notifications.append, stop_timeout=10)
        result = self.rpc("initialize", {"clientInfo": {"name": "draft_owned_auth_probe", "version": "0.1"}})
        self.assertIn("0.163.0", result["userAgent"])
        self.peer.notify("initialized", {})
        probe = self.rpc("command/exec", {"command": ["/usr/bin/true"], "cwd": "/tmp/project", "timeoutMs": 5000})
        self.assertEqual(probe["exitCode"], 0, "Nested sandbox is unavailable")

    def rpc(self, method, params):
        return self.peer.request(method, params)

    def refresh(self):
        result = self.rpc("getAuthStatus", {"includeToken": False, "refreshToken": True})
        self.assertIsNone(result.get("authToken"), "Refresh RPC exposed a token")

    def thread(self, previous=None):
        params = {"cwd": "/tmp/project", "model": "gpt-6.1-sol", "modelProvider": "openai",
                  "approvalPolicy": "never", "approvalsReviewer": "user"}
        if previous is not None:
            params.update(threadId=previous, excludeTurns=True)
        result = self.rpc("thread/resume" if previous else "thread/start", params)
        return result["thread"]["id"]

    def turn(self, thread):
        result = self.rpc("turn/start", {"threadId": thread,
            "input": [{"type": "text", "text": "Run the synthetic acceptance check.", "text_elements": []}],
            "approvalPolicy": "never", "approvalsReviewer": "user"})
        turn = result["turn"]["id"]
        deadline = time.monotonic() + 25
        while True:
            for message in self.notifications:
                params = message.get("params", {})
                if (message["method"] == "turn/completed" and params.get("threadId") == thread
                        and params.get("turn", {}).get("id") == turn):
                    self.assertEqual(params["turn"]["status"], "completed", "Synthetic turn failed")
                    self.session = thread
                    return
            self.peer.poll_events(deadline=deadline)

    def answer(self, thread):
        self.authority.enqueue(responses.answer("Synthetic answer."))
        self.turn(thread)

    def stop(self):
        result = self.store.stop(outcome="completed", session=self.session)
        self.peer = None
        self.assertTrue(result.settled)
        self.assertEqual(self.store.auth_fds, ())
        self.assertEqual((self.store.path / "auth.json").read_bytes(), b"")
        self.assertEqual(self.source.read_bytes(), b"real project unchanged\n")
        self.assertFalse(self.authority.errors, "Unexpected loopback request")
        self.assertEqual(self.authority.rejected_count, 0)

    def persisted(self, generation):
        self.assertIsNone(self.peer, "Inspect credentials only after proven writer exit")
        current = json.loads(self.auth.read_bytes())
        self.assertTrue(current["tokens"] == fixture.bundle(generation)["tokens"], "Replacement tokens mismatch")
        self.assertGreater(datetime.fromisoformat(current["last_refresh"]),
                           datetime.fromisoformat(self.initial["last_refresh"]))
        self.assertEqual(storage.auth.chatgpt_owner(current), ("fixture-user", "fixture-workspace"))

    def cleanup(self):
        if self.store is not None:
            if self.peer is not None:
                try:
                    self.store.stop(outcome="failed")
                except storage.Refused:
                    result = self.peer.close()
                    self.assertTrue(result.reaped and result.output_closed)
            self.store.close()

    def test_refreshed_login_survives_close_and_new_conversation(self):
        self.refresh()
        first_thread = self.thread()
        self.answer(first_thread)
        self.stop()
        self.persisted(1)
        old_root = self.store.root
        lock_inode = (self.directory / ".draft.lock").stat().st_ino
        self.store.close()
        self.assertFalse(old_root.exists())
        self.assertTrue(self.auth.exists())
        self.new_store()
        self.launch()
        second_thread = self.thread()
        self.assertNotEqual(second_thread, first_thread)
        self.answer(second_thread)
        self.assertEqual(self.authority.authorized_generations, [1, 1])
        self.refresh()
        self.stop()
        self.persisted(2)
        self.assertEqual(self.authority.accepted_generations, [0, 1])
        self.assertEqual((self.directory / ".draft.lock").stat().st_ino, lock_inode)

    def test_refreshed_login_survives_stopped_worker_and_same_thread_resume(self):
        self.refresh()
        thread = self.thread()
        self.answer(thread)
        self.stop()
        self.persisted(1)
        self.launch()
        self.assertEqual(self.thread(thread), thread)
        self.answer(thread)
        self.assertEqual(self.authority.authorized_generations, [1, 1])
        self.refresh()
        self.answer(thread)
        self.stop()
        self.persisted(2)
        self.assertEqual(self.authority.accepted_generations, [0, 1])
        self.assertEqual(self.authority.authorized_generations, [1, 1, 2])

    def outer_boundary(self):
        def descendants(pid):
            result = []
            for child in Path(f"/proc/{pid}/task/{pid}/children").read_text().split():
                result.append(int(child))
                result.extend(descendants(int(child)))
            return result
        binary = self.binary.stat()
        engines = []
        for pid in descendants(self.peer.child.pid):
            try:
                node = Path(f"/proc/{pid}/exe").stat()
                if (node.st_dev, node.st_ino) == (binary.st_dev, binary.st_ino):
                    engines.append(pid)
            except FileNotFoundError:
                pass
        self.assertEqual(len(engines), 1, "Cannot identify the confined engine")
        proc = Path(f"/proc/{engines[0]}")
        root = proc / "root"
        for path in (root / str(self.directory).lstrip("/"), root / "home/agent/.codex/.draft.lock"):
            with self.assertRaises(FileNotFoundError):
                path.stat()
        original = self.auth.stat()
        bound = (root / "home/agent/.codex/auth.json").stat()
        self.assertEqual((bound.st_dev, bound.st_ino), (original.st_dev, original.st_ino))
        protected = [(os.fstat(fd).st_dev, os.fstat(fd).st_ino) for fd in self.store.auth_fds]
        for descriptor in (proc / "fd").iterdir():
            try:
                node = descriptor.stat()
                self.assertNotIn((node.st_dev, node.st_ino), protected, "Credential descriptor reached the engine")
            except FileNotFoundError:
                pass

    def denial_script(self):
        protected = [(os.fstat(fd).st_dev, os.fstat(fd).st_ino) for fd in self.store.auth_fds]
        return f'''import errno, os, pathlib
protected = {protected!r}
def denied(path, absent=False):
    for mode in (os.O_RDONLY, os.O_WRONLY):
        try:
            fd = os.open(path, mode | os.O_NONBLOCK)
        except OSError as error:
            assert error.errno in (errno.EACCES, errno.EPERM, errno.EROFS) or (absent and error.errno == errno.ENOENT), "Unexpected denial"
        else:
            os.close(fd)
            raise AssertionError("Credential alias allowed an open")
direct = pathlib.Path('/home/agent/.codex/auth.json')
alias = pathlib.Path('/tmp/project/credential-alias')
alias.symlink_to(direct)
try:
    denied(direct)
    denied(alias)
    denied('/proc/self/root/home/agent/.codex/auth.json')
    processes = [path for path in pathlib.Path('/proc').iterdir() if path.name.isdigit()]
    assert len(processes) <= 128, "Unexpected process visibility"
    for proc in processes:
        denied(proc / 'root/home/agent/.codex/auth.json', absent=True)
        try:
            descriptors = list((proc / 'fd').iterdir())
        except (PermissionError, FileNotFoundError):
            continue
        for descriptor in descriptors:
            try:
                node = descriptor.stat()
            except (PermissionError, FileNotFoundError):
                continue
            if (node.st_dev, node.st_ino) in protected:
                denied(descriptor, absent=True)
    for path in ({str(self.directory)!r}, '/home/agent/.codex/.draft.lock'):
        try:
            os.stat(path)
        except (PermissionError, FileNotFoundError):
            pass
        else:
            raise AssertionError("Outer credential directory or lease is exposed")
finally:
    alias.unlink()
print('credential access denied')
'''

    def test_commands_cannot_read_or_write_credentials_before_or_after_refresh(self):
        thread = self.thread()
        for phase in ("before", "after"):
            if phase == "after":
                self.refresh()
            self.outer_boundary()
            script = self.denial_script()
            result = self.rpc("command/exec", {"command": ["/usr/bin/python3", "-I", "-B", "-c", script],
                "cwd": "/tmp/project", "timeoutMs": 5000})
            self.assertEqual(result["exitCode"], 0, "Nested read/write denial probe failed: " + phase)
            self.assertEqual(result["stdout"], "credential access denied\n")
            self.authority.enqueue(responses.command("/usr/bin/python3 -I -B -c " + shlex.quote(script)))
            self.authority.enqueue(responses.answer("Credential isolation checked."))
            self.turn(thread)
            outputs = [item for item in self.authority.requests[-1]["input"]
                       if item.get("type") == "custom_tool_call_output"]
            self.assertTrue(outputs, "Model command did not execute through code mode")
            content = outputs[-1]["output"]
            self.assertIsInstance(content, list, "Unexpected code-mode response")
            self.assertTrue(content[0]["text"].startswith("Script completed\n"), "Code-mode host failed")
            command = json.loads(content[-1]["text"])
            self.assertEqual(command["exit_code"], 0, "Model-issued denial probe failed")
            self.assertTrue(command["output"] == "credential access denied\n", "Unexpected model command output")
            history = json.dumps(self.authority.requests)
            for generation in range(self.authority.generation + 1):
                for key in ("id_token", "access_token", "refresh_token"):
                    self.assertTrue(fixture.bundle(generation)["tokens"][key] not in history,
                                    "Synthetic token reached provider history")
        self.stop()
        self.persisted(1)
        self.assertEqual(self.authority.accepted_generations, [0])
        self.assertEqual(self.authority.authorized_generations, [0, 0, 1, 1])


if __name__ == "__main__":
    unittest.main()
