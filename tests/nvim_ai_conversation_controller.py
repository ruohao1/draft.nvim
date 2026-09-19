"""Production controller exercised through separate processes and private pipes."""
import json
import hashlib
import importlib.util
import os
from pathlib import Path
import select
import shutil
import socketserver
import subprocess
import sys
import tempfile
import time
import threading
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/nvim-ai-conversation.py"


class ControllerTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="draft-controller-test-", dir="/tmp")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.config = self.root / "config.json"
        self.config.write_text(json.dumps({"opencode": "/missing/unused-agent", "bwrap": "/usr/bin/bwrap",
                                           "model": "fixture/model"}))
        self.config.chmod(0o600)

    def close_frame(self):
        return {"version": 1, "serial": 1, "command": {
            "kind": "close", "conversation_id": "a" * 32, "owner_generation": 1,
            "turn_id": 0, "worker_generation": 0, "root": str(self.root),
            "selection": ["example.txt"], "model": "fixture/model"}}

    def invoke(self, raw):
        return subprocess.run([sys.executable, "-I", "-B", str(SCRIPT), "--config", str(self.config)],
                              input=raw, capture_output=True, timeout=3,
                              env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"}, umask=0o077)

    def test_close_before_a_turn_needs_no_agent_or_store(self):
        result = self.invoke(json.dumps(self.close_frame()).encode() + b'\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual((value["version"], value["serial"]), (1, 1))
        self.assertEqual(value["event"], {"kind": "closed", "conversation_id": "a" * 32,
            "owner_generation": 1, "turn_id": 0, "worker_generation": 0, "sequence": 1,
            "stopped": True, "cleaned": True, "tokens_retired": True})
        self.assertEqual(list(self.root.iterdir()), [self.config])
        self.assertEqual(result.stderr, b'')

    def test_malformed_or_partial_editor_input_never_asserts_cleanup(self):
        for raw in (b'{bad}\n', b'{"version":1', b'[]\n'):
            with self.subTest(raw=raw):
                result = self.invoke(raw)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b'')
                self.assertNotIn(b'{bad}', result.stderr)

    def test_untrusted_launch_file_is_refused_even_for_passive_close(self):
        self.config.chmod(0o644)
        result = self.invoke(json.dumps(self.close_frame()).encode() + b'\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b'')

    def test_blocked_editor_output_exits_within_its_absolute_deadline(self):
        reader, writer = os.pipe()
        try:
            os.set_blocking(writer, False)
            try:
                while True:
                    os.write(writer, b'x' * 4096)
            except BlockingIOError:
                pass
            started = time.monotonic()
            process = subprocess.Popen(
                [sys.executable, "-I", "-B", str(SCRIPT), "--config", str(self.config)],
                stdin=subprocess.PIPE, stdout=writer, stderr=subprocess.PIPE,
                env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"}, umask=0o077)
            try:
                _, error = process.communicate(json.dumps(self.close_frame()).encode() + b'\n', timeout=7)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
            self.assertNotEqual(process.returncode, 0)
            self.assertGreaterEqual(time.monotonic() - started, 5)
            self.assertLess(time.monotonic() - started, 7)
            self.assertIn(b'explicit recovery required', error)
        finally:
            os.close(reader)
            os.close(writer)


class EngineTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="draft-engine-test-", dir="/tmp")
        self.addCleanup(self.directory.cleanup)
        self.scratch = Path(self.directory.name)
        self.root = self.scratch / "project"
        self.root.mkdir(mode=0o700)
        self.source = self.root / "example.txt"
        self.source.write_bytes(b"original text\n")
        self.source.chmod(0o644)
        self.peer = self.scratch / "opencode"
        shutil.copyfile(ROOT / "tests/fixtures/ai/conversation_acp.py", self.peer)
        self.peer.chmod(0o700)
        self.audit, self.events, self.buffer = [], [], bytearray()
        audit = self.audit

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                audit.append(json.loads(self.rfile.readline()))

        self.server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.config = self.scratch / "config.json"
        self.serial = 0
        self.turn = 0

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)

    def spawn(self, case="answer"):
        self.config.write_text(json.dumps({"opencode": str(self.peer),
            "bwrap": os.path.realpath(shutil.which("bwrap")), "model": "fixture/model",
            "provider": {"fixture": {"options": {"testCase": case, "auditPort": self.server.server_address[1]}}}}))
        self.config.chmod(0o600)
        self.child = subprocess.Popen([sys.executable, "-I", "-B", str(SCRIPT), "--config", str(self.config)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "NVIM_STAGED_SENTINEL": "private"}, umask=0o077)
        self.addCleanup(self.stop)

    def stop(self):
        if self.child.poll() is None:
            self.child.stdin.close()
            try:
                self.child.wait(timeout=12)
            except subprocess.TimeoutExpired:
                self.child.kill()
                self.child.wait(timeout=3)
        for stream in (self.child.stdin, self.child.stdout, self.child.stderr):
            stream.close()

    def send(self, kind, **extra):
        self.serial += 1
        if kind in ("start", "revise"):
            self.turn += 1
            extra = dict(message="Answer without editing.", sources=[{"path": "example.txt",
                "snapshot_sha256": hashlib.sha256(self.source.read_bytes()).hexdigest()}], **extra)
        command = dict(kind=kind, conversation_id="a" * 32, owner_generation=1,
            turn_id=self.turn, worker_generation=self.turn, root=str(self.root),
            selection=["example.txt"], model="fixture/model", **extra)
        self.child.stdin.write(json.dumps({"version": 1, "serial": self.serial, "command": command}).encode() + b'\n')
        self.child.stdin.flush()

    def receive(self, kind, seconds=12):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            while b'\n' in self.buffer:
                raw, _, remaining = self.buffer.partition(b'\n')
                self.buffer = bytearray(remaining)
                event = json.loads(raw)["event"]
                self.events.append(event)
                if event["kind"] == kind:
                    return event
            if select.select([self.child.stdout], [], [], min(.1, max(0, deadline - time.monotonic())))[0]:
                data = os.read(self.child.stdout.fileno(), 65536)
                if not data:
                    self.child.wait(timeout=3)
                    self.fail("Controller closed before " + kind + ": " + self.child.stderr.read().decode())
                self.buffer.extend(data)
        self.fail("Controller timed out before " + kind)

    def test_answer_finishes_without_proposal(self):
        self.spawn()
        self.send("start")
        settled = self.receive("settled")
        self.assertEqual(settled["outcome"], "answer")
        self.assertTrue(settled["stopped"] and settled["graceful"] and settled["store_valid"])
        self.assertNotIn("proposal", settled)
        self.assertNotIn("review_ref", settled)
        self.assertEqual([event["text"] for event in self.events if event["kind"] == "text"], ["A bounded answer."])
        self.assertEqual([event["status"] for event in self.events if event["kind"] == "progress"], ["completed"])
        self.assertEqual([item["method"] for item in self.audit if "method" in item], ["initialize", "session/new",
            "session/set_config_option", "session/set_config_option", "session/prompt"])
        self.assertIn({"exiting": True}, self.audit)
        self.assertEqual(Path(f"/proc/{self.child.pid}/task/{self.child.pid}/children").read_text().strip(), "")
        self.assertEqual(self.source.read_bytes(), b"original text\n")
        self.send("close")
        self.assertTrue(self.receive("closed")["cleaned"])
        self.child.wait(timeout=3)
        self.assertEqual(self.child.returncode, 0)

    def test_handshake_and_option_refusals_never_submit_a_prompt(self):
        for case in ("wrong-version", "missing-resume", "missing-model", "missing-mode", "wrong-confirmation"):
            with self.subTest(case=case):
                self.serial = self.turn = 0
                self.audit.clear()
                self.spawn(case)
                self.send("start")
                event = self.receive("settled")
                self.assertEqual(event["outcome"], "failed")
                self.assertFalse(any(item.get("method") == "session/prompt" for item in self.audit))
                self.stop()

    def test_foreign_session_updates_and_unsuccessful_stop_never_freeze(self):
        for case in ("wrong-session", "bad-stop"):
            with self.subTest(case=case):
                self.serial = self.turn = 0
                self.audit.clear()
                self.spawn(case)
                self.send("start")
                event = self.receive("settled")
                self.assertEqual(event["outcome"], "failed")
                self.assertNotIn("proposal", event)
                self.stop()


if __name__ == "__main__":
    unittest.main()
