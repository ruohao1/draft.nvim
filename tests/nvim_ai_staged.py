"""Public controller tests: actual files, ACP subprocesses, and Bubblewrap."""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import selectors
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
CONTROLLER = HERE.parent / "scripts/nvim-ai-staged.py"
BEFORE = b"original text\n"
AFTER = b"approved edit\n"


class StagedTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="nvim-ai-staged-test-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "project"
        (self.root / "src").mkdir(parents=True)
        self.file = self.root / "src/example.txt"
        self.file.write_bytes(BEFORE)
        self.file.chmod(0o644)
        self.peer = Path(self.temp.name) / "opencode"
        shutil.copyfile(HERE / "fixtures/ai/staged_acp.py", self.peer)
        self.peer.chmod(0o700)

    def request(self, case="approve", **overrides):
        return dict({"root": str(self.root), "path": "src/example.txt",
                     "snapshot_sha256": hashlib.sha256(BEFORE).hexdigest(),
                     "model": "fixture/model", "opencode": str(self.peer),
                     "bwrap": os.path.realpath(shutil.which("bwrap")),
                     "prompt": "TEST:" + case}, **overrides)

    def spawn(self, request):
        child = subprocess.Popen([sys.executable, "-I", "-B", str(CONTROLLER), "prepare"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=dict(os.environ, NVIM_STAGED_SENTINEL="must-not-reach-agent"))
        def stop():
            if child.poll() is None:
                child.stdin.close()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)
            for stream in (child.stdin, child.stdout, child.stderr):
                stream.close()
        self.addCleanup(stop)
        child.stdin.write(json.dumps(request).encode() + b"\n")
        child.stdin.flush()
        return child

    def receive(self, child, seconds=15):
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            self.assertTrue(selector.select(seconds), "controller timed out")
        result = json.loads(child.stdout.readline())
        child.wait(timeout=5)
        self.assertEqual(child.returncode, 0, child.stderr.read().decode())
        if result.get("proposal"):
            directory = Path(result["proposal"]).parent
            self.addCleanup(lambda: shutil.rmtree(directory) if directory.exists() else None)
        return result

    def prepare(self, case="approve", **overrides):
        result = self.receive(self.spawn(self.request(case, **overrides)))
        self.assertEqual(self.file.read_bytes(), BEFORE)
        return result

    def ready(self, case="approve", **overrides):
        result = self.prepare(case, **overrides)
        self.assertEqual(result["phase"], "review_ready", result)
        self.assertEqual(result["oldText"].encode(), BEFORE)
        self.assertEqual(result["newText"].encode(), AFTER)
        directory = Path(result["proposal"]).parent
        self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        self.assertFalse((directory / "agent").exists())
        self.assertFalse((directory / "staging").exists())
        return result

    def decide(self, proposal, choice="approve", token=None):
        result = subprocess.run([sys.executable, "-I", "-B", str(CONTROLLER), choice,
            "--proposal", proposal["proposal"], "--id", token or proposal["id"]],
            capture_output=True, timeout=6, check=True)
        return json.loads(result.stdout)

    def test_approval_is_the_only_publication_and_cannot_replay(self):
        proposal = self.ready()
        self.assertEqual(self.decide(proposal)["phase"], "applied")
        self.assertEqual(self.file.read_bytes(), AFTER)
        self.file.write_bytes(b"later user edit\n")
        self.assertEqual(self.decide(proposal)["phase"], "already_decided")
        self.assertEqual(self.file.read_bytes(), b"later user edit\n")

    def test_workspace_freezing_is_independent_of_agent_execution(self):
        spec = importlib.util.spec_from_file_location("staged_workspace", CONTROLLER)
        staging = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(staging)
        request = self.request(opencode="/missing/agent")
        selected, multi = staging.selected_files(request)
        task = staging.prepare_workspace(request, selected)
        self.addCleanup(lambda: staging.discard_workspace(task) if task.exists() else None)
        (task / "staging/src/example.txt").write_bytes(AFTER)
        frozen = staging.freeze_workspace(task, str(self.root), selected, multi=multi)
        self.assertEqual(frozen["phase"], "review_ready")
        self.assertEqual(frozen["newText"].encode(), AFTER)
        self.assertEqual(self.file.read_bytes(), BEFORE)
        self.assertFalse((task / "staging").exists())

    def test_reject_and_cancel_leave_original(self):
        for choice, phase in (("reject", "rejected"), ("cancel", "cancelled")):
            with self.subTest(choice=choice):
                proposal = self.ready()
                self.assertEqual(self.decide(proposal, choice)["phase"], phase)
                self.assertEqual(self.file.read_bytes(), BEFORE)
                self.assertFalse(Path(proposal["proposal"]).exists())

    def test_root_lock_close_error_preserves_confirmed_publication(self):
        proposal = self.ready()
        spec = importlib.util.spec_from_file_location("staged_close_test", CONTROLLER)
        controller = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(controller)
        locked, faults = [], []
        real_flock, real_close = controller.fcntl.flock, controller.os.close

        def flock(fd, operation):
            real_flock(fd, operation)
            locked.append(fd)

        def close(fd):
            real_close(fd)
            if locked and fd == locked[0]:
                faults.append(fd)
                raise OSError("injected root lock close failure")

        with mock.patch.object(controller.fcntl, "flock", side_effect=flock), \
                mock.patch.object(controller.os, "close", side_effect=close):
            result = controller.decide(proposal["proposal"], proposal["id"], "approve")
        self.assertEqual(len(faults), 1)
        self.assertEqual(result["phase"], "applied", result)
        self.assertEqual(self.file.read_bytes(), AFTER)

    def test_stale_disk_blocks_publication(self):
        proposal = self.ready()
        self.file.write_bytes(b"user edit\n")
        self.assertEqual(self.decide(proposal)["phase"], "conflicted")
        self.assertEqual(self.file.read_bytes(), b"user edit\n")

    def test_same_bytes_replacement_is_still_a_conflict(self):
        proposal = self.ready()
        self.file.unlink()
        self.file.write_bytes(BEFORE)
        self.file.chmod(0o644)
        self.assertEqual(self.decide(proposal)["phase"], "conflicted")
        self.assertEqual(self.file.read_bytes(), BEFORE)

    def test_parent_replacement_and_symlink_fail_closed(self):
        proposal = self.ready()
        parent = self.file.parent
        parent.rename(self.root / "saved-src")
        parent.symlink_to(self.root / "saved-src", target_is_directory=True)
        self.assertEqual(self.decide(proposal)["phase"], "blocked")
        self.assertEqual(self.file.read_bytes(), BEFORE)

    def test_frozen_source_tampering_cannot_publish(self):
        proposal = self.ready()
        (Path(proposal["proposal"]).parent / "after").write_bytes(b"unreviewed\n")
        self.assertEqual(self.decide(proposal)["phase"], "uncertain")
        self.assertEqual(self.file.read_bytes(), BEFORE)

    def test_wrong_proposal_identity_is_rejected(self):
        proposal = self.ready()
        self.assertEqual(self.decide(proposal, token="0" * 32)["phase"], "blocked")
        self.assertEqual(self.file.read_bytes(), BEFORE)
        self.assertEqual(self.decide(proposal, "reject")["phase"], "rejected")

    def test_unsupported_staging_refuses_the_entire_turn(self):
        for case in ("extra", "symlink", "delete", "mode", "binary", "bad-json"):
            with self.subTest(case=case):
                self.assertEqual(self.prepare(case)["phase"], "blocked")

    def test_agent_cannot_reach_real_file_or_client_writer(self):
        proposal = self.ready("direct", prompt="TEST:direct OUTSIDE:" + str(self.file))
        self.assertEqual(self.decide(proposal)["phase"], "applied")
        self.assertEqual(self.file.read_bytes(), AFTER)

    def test_non_edit_permissions_are_cancelled(self):
        self.ready("permission")

    def test_no_change_needs_no_review(self):
        self.assertEqual(self.prepare("unchanged")["phase"], "unchanged")

    def test_editor_disconnect_cancels_a_running_turn(self):
        child = self.spawn(self.request("stall"))
        time.sleep(.2)
        child.stdin.close()
        self.assertEqual(self.receive(child)["phase"], "blocked")
        self.assertEqual(self.file.read_bytes(), BEFORE)

    def test_background_child_is_stopped_before_freezing(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            port = listener.getsockname()[1]
            proposal = self.ready("background", prompt=f"TEST:background BACKGROUND_PORT:{port}")
            with selectors.DefaultSelector() as selector:
                selector.register(listener, selectors.EVENT_READ)
                self.assertFalse(selector.select(2.5), "Background child survived its owned namespace")
            self.assertEqual(self.decide(proposal)["phase"], "applied")
            self.assertEqual(self.file.read_bytes(), AFTER)

    def test_explicit_auth_copy_contains_only_selected_provider(self):
        auth = Path(self.temp.name) / "auth.json"
        auth.write_text(json.dumps({"fixture": {"type": "api", "key": "fixture-secret"},
                                   "unrelated": {"type": "api", "key": "must-not-be-copied"}}))
        auth.chmod(0o600)
        self.ready("auth", auth_file=str(auth))
        auth.chmod(0o644)
        self.assertEqual(self.prepare("auth", auth_file=str(auth))["phase"], "blocked")

    def test_nonstandard_source_metadata_and_hardlinks_are_refused(self):
        link = self.root / "second-link"
        os.link(self.file, link)
        self.assertEqual(self.prepare()["phase"], "blocked")
        link.unlink()
        os.setxattr(self.file, "user.staged-fixture", b"unsupported metadata")
        self.assertEqual(self.prepare()["phase"], "blocked")
        os.removexattr(self.file, "user.staged-fixture")

    def test_a_second_proposal_cannot_overwrite_a_first_approval(self):
        first, second = self.ready(), self.ready()
        self.assertEqual(self.decide(first)["phase"], "applied")
        self.assertEqual(self.decide(second)["phase"], "conflicted")
        self.assertEqual(self.file.read_bytes(), AFTER)

    def test_preflight_rejects_dirty_snapshot_and_unsafe_paths(self):
        for overrides in ({"snapshot_sha256": "0" * 64}, {"path": "../outside"},
                          {"path": "src/.env"}, {"root": "/"}, {"model": ""}):
            with self.subTest(overrides=overrides):
                self.assertEqual(self.prepare(**overrides)["phase"], "blocked")
        self.file.chmod(0o664)
        self.assertEqual(self.prepare()["phase"], "blocked")

    @unittest.skipUnless(os.environ.get("NVIM_AI_STAGED_REAL_OPENCODE"), "opt-in installed OpenCode test")
    def test_installed_opencode_with_local_scripted_model(self):
        requests = []

        class Model(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                if self.path != "/v1/chat/completions" or not 0 < length <= 2 * 1024 * 1024:
                    self.send_error(400)
                    return
                body = json.loads(self.rfile.read(length))
                requests.append(body)
                messages = body.get("messages", [])
                tools = [t["function"]["name"] for t in body.get("tools", [])]
                active = any("TEST:approve" in str(m.get("content")) for m in messages)
                finished = any(m.get("role") == "tool" for m in messages)
                call = active and not finished and "edit" in tools
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()

                def chunk(delta, finish=None):
                    value = {"id": "staged-local", "object": "chat.completion.chunk", "created": 1,
                             "model": "model", "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
                    self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode())

                chunk({"role": "assistant"})
                if call:
                    chunk({"tool_calls": [{"index": 0, "id": "staged_edit", "type": "function", "function": {
                        "name": "edit", "arguments": json.dumps({"filePath": "/tmp/project/src/example.txt",
                            "oldString": BEFORE.decode().strip(), "newString": AFTER.decode().strip()})}}]})
                    chunk({}, "tool_calls")
                else:
                    chunk({"content": "Staged edit complete; awaiting editor review."})
                    chunk({}, "stop")
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()

        server = ThreadingHTTPServer(("127.0.0.1", 0), Model)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        provider = {"fixture": {"npm": "@ai-sdk/openai-compatible", "name": "Local scripted fixture",
            "options": {"baseURL": f"http://127.0.0.1:{server.server_port}/v1", "apiKey": "not-a-secret"},
            "models": {"model": {"name": "Fixture model", "tool_call": True,
                                  "limit": {"context": 32768, "output": 2048}}}}}
        request = self.request(opencode=os.path.realpath(os.environ["NVIM_AI_STAGED_REAL_OPENCODE"]), provider=provider)
        proposal = self.receive(self.spawn(request), seconds=60)
        self.assertEqual(proposal["phase"], "review_ready", proposal)
        self.assertEqual(self.file.read_bytes(), BEFORE)
        self.assertEqual(proposal["newText"].encode(), AFTER)
        self.assertTrue(any(m.get("role") == "tool" for r in requests for m in r.get("messages", [])),
                        "Real OpenCode must execute its native edit tool")
        self.assertEqual(self.decide(proposal)["phase"], "applied")
        self.assertEqual(self.file.read_bytes(), AFTER)


if __name__ == "__main__":
    unittest.main()
