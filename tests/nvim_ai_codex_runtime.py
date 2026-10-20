"""Offline runner checks and explicit pinned Codex sandbox acceptance."""
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import shutil
import select
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
POLICY = {"type": "workspaceWrite", "writableRoots": ["/tmp/project"],
          "networkAccess": False, "excludeTmpdirEnvVar": True, "excludeSlashTmp": True}


def provider_fixture():
    spec = importlib.util.spec_from_file_location(
        "codex_responses", ROOT / "tests/fixtures/ai/codex_responses.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def helper(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


storage = helper("nvim-ai-codex-store")
runtime = helper("nvim-ai-codex-runtime")


@unittest.skipUnless(os.environ.get("NVIM_AI_REAL_CODEX"), "pass --codex for pinned runtime acceptance")
class InstalledTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="draft-real-codex-", dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / "version-home"
        self.home.mkdir(mode=0o700)
        self.store = storage.Store(self.root)
        self.codex_home = self.store.path
        self.addCleanup(self.store.close)
        self.source = self.root / "example.txt"
        self.source.write_bytes(b"original text\n")
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
        self.auth = self.root / "auth.json"
        self.auth.write_text('{"OPENAI_API_KEY":"synthetic-codex-key"}')
        self.auth.chmod(0o600)
        self.store.initialize(str(self.auth))
        self.launch()
        result = self.rpc("command/exec", {"command": ["/usr/bin/true"],
            "cwd": "/tmp/project", "sandboxPolicy": POLICY, "timeoutMs": 5000})
        self.assertEqual(result["exitCode"], 0, "Nested sandbox unavailable: " + str(result))

    def launch(self, hostile=False):
        self.serial += 1
        task = self.root / f"turn-{self.serial}"
        self.project = task / "staging"
        self.project.mkdir(mode=0o700, parents=True)
        (self.project / "example.txt").write_bytes(self.source.read_bytes())
        if hostile:
            (self.project / ".codex").mkdir(mode=0o700)
            (self.project / ".codex/config.toml").write_text(
                '[mcp_servers.evil]\ncommand = "/usr/bin/python3"\nargs = '
                + json.dumps(["-c", "from pathlib import Path; Path('/tmp/project/mcp-started').touch()"])
                + '\n[features]\nplugins = true\n')
        argv, env = runtime.sandbox({"bwrap": os.path.realpath(shutil.which("bwrap")),
            "codex": str(self.binary), "model": "openai/gpt-5.4"}, task, self.store)
        # Only this explicit test redirects the provider; production has no override option.
        profile = task / "agent/codex.toml"
        profile.write_text("openai_base_url = " + json.dumps(self.provider.url) + "\n" + profile.read_text())
        self.notifications = []
        self.terminal_session = self.terminal_status = None
        self.peer = self.store.start(argv, env=env, on_notification=self.notifications.append, stop_timeout=10)
        initialized = self.rpc("initialize", {"clientInfo": {"name": "draft_probe", "version": "0.1"}})
        self.assertIn("0.163.0", initialized["userAgent"])
        self.peer.notify("initialized", {})

    def rpc(self, method, params):
        return self.peer.request(method, params)

    def terminal(self, thread, turn):
        deadline = time.monotonic() + 25
        while True:
            for message in self.notifications:
                params = message.get("params", {})
                if (message["method"] == "turn/completed" and params.get("threadId") == thread
                        and params.get("turn", {}).get("id") == turn):
                    self.terminal_session, self.terminal_status = thread, params["turn"]["status"]
                    return params["turn"]
            self.peer.poll_events(deadline=deadline)

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
            try:
                self.store.stop(outcome="failed")
            except storage.Refused:
                result = self.peer.close()
                self.assertTrue(result.reaped and result.output_closed)
            self.peer = None

    def stop(self, label):
        outcome = "cancelled" if self.terminal_status == "interrupted" else "completed"
        result = self.store.stop(outcome=outcome, session=self.terminal_session)
        self.assertTrue(result.settled, result)
        self.peer = None
        print("\nCodex production inventory " + label + ": " + json.dumps(self.store.check()), flush=True)
        self.assertEqual(self.source.read_bytes(), b"original text\n")
        self.assertEqual(self.auth.read_text(), '{"OPENAI_API_KEY":"synthetic-codex-key"}')
        self.assertFalse(self.provider.errors, self.provider.errors)

    def test_generated_profile_ignores_external_config(self):
        self.stop("before-hostile-config")
        with mock.patch.dict(os.environ, {"CODEX_HOME": "/external/codex", "OPENAI_API_KEY": "ambient-secret",
                                          "CODEX_CONFIG_FILE": "/external/config.toml"}):
            self.launch(hostile=True)
        self.provider.enqueue(self.fixture.answer("Only the configured provider."))
        thread = self.thread()
        turn = self.turn(thread, "Answer without editing.")
        self.assertEqual(self.terminal(thread, turn)["status"], "completed")
        self.assertFalse((self.project / "mcp-started").exists())
        self.assertFalse(any("evil" in json.dumps(n) for n in self.notifications))
        self.assertEqual(len(self.provider.requests), 1)
        self.stop("hostile-config-ignored")

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
        self.assertEqual(self.terminal(thread, turn)["status"], "completed")
        self.assertEqual(len(self.provider.requests), 1)
        self.stop("confined-completed")

    def test_empty_thread_resume_fails(self):
        thread = self.thread()
        self.stop("empty")
        self.launch()
        with self.assertRaisesRegex(storage.ProtocolError, "-32600"):
            self.peer.request("thread/resume", {"threadId": thread})
        self.assertEqual(len(self.provider.requests), 0)
        self.stop("empty-resume-refused")

    def start_controller(self):
        self.stop("before-managed-controller")
        config = self.root / "controller.json"
        config.write_text(json.dumps({"backend": "codex", "codex": str(self.binary),
            "bwrap": os.path.realpath(shutil.which("bwrap")), "model": "openai/gpt-5.4",
            "auth_file": str(self.auth)}))
        config.chmod(0o600)
        self.audit_file = self.root / "controller-audit.jsonl"
        self.controller = subprocess.Popen([sys.executable, "-I", "-B",
            str(ROOT / "tests/fixtures/ai/codex_runtime_controller.py"), "--config", str(config)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env={"PATH": os.defpath, "LANG": "C.UTF-8", "DRAFT_CODEX_PROVIDER": self.provider.url,
                 "DRAFT_CODEX_AUDIT": str(self.audit_file)}, umask=0o077)
        self.addCleanup(self.stop_controller)
        self.editor_serial = self.editor_turn = 0
        self.editor_buffer, self.editor_events = bytearray(), []
        self.proposals = set()

    def stop_controller(self):
        self.provider.release()
        if self.controller.poll() is None:
            self.controller.stdin.close()
            try:
                self.controller.wait(timeout=12)
            except subprocess.TimeoutExpired:
                self.controller.kill()
                self.controller.wait(timeout=3)
        for stream in (self.controller.stdin, self.controller.stdout, self.controller.stderr):
            stream.close()
        for path in self.proposals:
            if path.exists():
                shutil.rmtree(path)

    def editor_send(self, kind, **extra):
        self.editor_serial += 1
        if kind in ("start", "revise"):
            self.editor_turn += 1
            extra.setdefault("message", "Answer without editing.")
            extra["sources"] = [{"path": self.source.name,
                "snapshot_sha256": hashlib.sha256(self.source.read_bytes()).hexdigest()}]
        command = dict(kind=kind, conversation_id="a" * 32, owner_generation=1,
            turn_id=self.editor_turn, worker_generation=self.editor_turn,
            root=str(self.root), selection=[self.source.name], model="openai/gpt-5.4", **extra)
        self.controller.stdin.write(json.dumps(
            {"version": 1, "serial": self.editor_serial, "command": command}).encode() + b"\n")
        self.controller.stdin.flush()

    def editor_receive(self, kind):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            while b"\n" in self.editor_buffer:
                raw, _, rest = self.editor_buffer.partition(b"\n")
                self.editor_buffer = bytearray(rest)
                event = json.loads(raw)["event"]
                self.editor_events.append(event)
                if "review_ref" in event:
                    self.proposals.add(Path(event["review_ref"]["manifest"]).parent)
                if event["kind"] == kind:
                    return event
            if select.select([self.controller.stdout], [], [], .1)[0]:
                data = os.read(self.controller.stdout.fileno(), 65536)
                if not data:
                    self.fail("Controller closed: " + repr(self.editor_events)
                              + self.controller.stderr.read().decode())
                self.editor_buffer.extend(data)
        self.fail("Controller timed out before " + kind + ": " + repr(self.editor_events))

    def controller_settled(self, outcome):
        event = self.editor_receive("settled")
        self.assertEqual(event["outcome"], outcome, self.editor_events)
        self.assertTrue(event["stopped"] and event["graceful"] and event["store_valid"])
        self.assertEqual(Path(f"/proc/{self.controller.pid}/task/{self.controller.pid}/children")
                         .read_text().strip(), "", "No worker may remain before review or resume")
        self.assertEqual(self.source.read_bytes(), b"original text\n")
        return event

    def controller_audit(self):
        return [json.loads(line) for line in self.audit_file.read_text().splitlines()]

    def close_controller(self):
        self.editor_send("close")
        self.assertTrue(self.editor_receive("closed")["cleaned"])
        self.assertEqual(self.controller.wait(timeout=3), 0)
        self.assertEqual(self.auth.read_text(), '{"OPENAI_API_KEY":"synthetic-codex-key"}')
        self.assertFalse(self.provider.errors, self.provider.errors)

    def test_completed_thread_resumes_after_exit(self):
        self.start_controller()
        self.provider.enqueue(self.fixture.command("printf 'proposed text\\n' > /tmp/project/example.txt"))
        self.provider.enqueue(self.fixture.answer("copper-orbit-731"))
        self.editor_send("start", message="Edit the selected copy.")
        first = self.controller_settled("review")
        manifest = Path(first["review_ref"]["manifest"])
        proposal = json.loads(manifest.read_bytes())
        self.assertEqual(first["proposal"]["files"][0]["state"], "pending")
        self.assertEqual(proposal["id"], first["review_ref"]["token"])
        self.assertEqual((manifest.parent / "after-0").read_bytes(), b"proposed text\n")
        identity = dict(round_id=1, proposal_revision=1, proposal_token=first["review_ref"]["token"],
                        receipt_sequence=0)
        self.provider.enqueue(self.fixture.answer("Resumed."))
        self.editor_send("revise", message="Continue without editing.",
                        context=dict(identity, files=first["proposal"]["files"]), **identity)
        self.controller_settled("answer")
        audit = self.controller_audit()
        starts = [entry for entry in audit if entry.get("method") == "turn/start"]
        resumes = [entry for entry in audit if entry.get("method") == "thread/resume"]
        terminals = [entry for entry in audit if "terminal" in entry]
        self.assertEqual(len(starts), 2)
        self.assertEqual(len(resumes), 1)
        self.assertEqual([entry["threadId"] for entry in starts], [resumes[0]["threadId"]] * 2)
        self.assertEqual([entry["terminal"] for entry in terminals], ["completed", "completed"])
        self.assertEqual([entry["threadId"] for entry in terminals], [resumes[0]["threadId"]] * 2)
        self.assertEqual(len(self.provider.requests), 3)
        self.assertIn("copper-orbit-731", json.dumps(self.provider.requests[-1]["input"]))
        self.close_controller()
        print("\nProduction controller: real edit → frozen pending review → stopped exact-thread resume", flush=True)

    def test_interrupt_requires_terminal(self):
        self.start_controller()
        self.provider.hold()
        self.provider.enqueue(self.fixture.answer("Partial answer."))
        self.editor_send("start", message="cancelled-user-marker")
        self.editor_receive("submitted")
        self.assertTrue(self.provider.streaming.wait(timeout=8))
        self.editor_send("cancel")
        cancelled = self.editor_receive("cancelled")
        self.assertTrue(cancelled["cancel_confirmed"] and cancelled["stopped"]
                        and cancelled["graceful"] and cancelled["store_valid"])
        self.assertFalse(any("review_ref" in event for event in self.editor_events))
        self.provider.release()
        self.provider.enqueue(self.fixture.answer("New explicit turn."))
        self.editor_send("start", message="Continue explicitly.")
        self.controller_settled("answer")
        audit = self.controller_audit()
        terminals = [entry for entry in audit if "terminal" in entry]
        self.assertEqual([entry["terminal"] for entry in terminals], ["interrupted", "completed"])
        resumed = next(entry for entry in audit if entry.get("method") == "thread/resume")
        interrupted = next(entry for entry in audit if entry.get("method") == "turn/interrupt")
        self.assertEqual(resumed["threadId"], terminals[0]["threadId"])
        self.assertEqual((interrupted["threadId"], interrupted["turnId"]),
                         (terminals[0]["threadId"], terminals[0]["turnId"]))
        self.assertIn("cancelled-user-marker", json.dumps(self.provider.requests[-1]["input"]))
        self.close_controller()
        print("\nProduction controller: matching interrupt terminal → stopped exact-thread resume", flush=True)



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
