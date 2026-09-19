"""Explicit multi-file controller requests with a real isolated ACP fixture."""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import shutil
import threading
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("single_staged_tests", HERE / "nvim_ai_staged.py")
single = importlib.util.module_from_spec(spec)
spec.loader.exec_module(single)


class MultiFileTest(single.StagedTest):
    # Reuse fixture methods without inheriting the single-file test methods.
    def request(self, case="multi", **overrides):
        request = super().request(case)
        request.pop("path")
        request.pop("snapshot_sha256")
        request["files"] = [{"path": str(path.relative_to(self.root)),
            "snapshot_sha256": hashlib.sha256(path.read_bytes()).hexdigest()} for path in self.selected]
        request.update(overrides)
        return request

    def setUp(self):
        super().setUp()
        self.second = self.root / 'src/other space "quoted".txt'
        self.second.write_bytes(b"second original\n")
        self.second.chmod(0o644)
        self.selected = [self.file, self.second]
        self.original = [path.read_bytes() for path in self.selected]

    def ready_multi(self, case="multi", **overrides):
        result = self.receive(self.spawn(self.request(case, **overrides)))
        self.assertEqual(result["phase"], "review_ready", result)
        self.assertEqual([path.read_bytes() for path in self.selected], self.original)
        self.assertEqual([item["path"] for item in result["files"]],
                         [str(path.relative_to(self.root)) for path in self.selected])
        self.assertEqual([item["oldText"].encode() for item in result["files"]], self.original)
        task = Path(result["proposal"]).parent
        self.assertFalse((task / "agent").exists())
        self.assertFalse((task / "staging").exists())
        self.assertEqual(json.loads((task / "proposal.json").read_bytes())["schema"], 2)
        return result

    def test_multi_approval_is_explicit_and_consumed_once(self):
        proposal = self.ready_multi("multi-permission")
        result = self.decide(proposal)
        self.assertEqual(result["phase"], "applied", result)
        self.assertEqual([path.read_bytes() for path in self.selected], [single.AFTER] * 2)
        self.second.write_bytes(b"later user edit\n")
        self.assertEqual(self.decide(proposal)["phase"], "already_decided")
        self.assertEqual(self.second.read_bytes(), b"later user edit\n")

    def test_multi_reject_and_cancel_publish_nothing(self):
        for choice in ("reject", "cancel"):
            proposal = self.ready_multi()
            self.assertEqual(self.decide(proposal, choice)["phase"],
                             "rejected" if choice == "reject" else "cancelled")
            self.assertEqual([path.read_bytes() for path in self.selected], self.original)

    def test_multi_stale_second_file_blocks_all_publication(self):
        proposal = self.ready_multi()
        self.second.write_bytes(b"external user edit\n")
        result = self.decide(proposal)
        self.assertIn(result["phase"], ("blocked", "conflicted"), result)
        self.assertEqual(self.file.read_bytes(), self.original[0])
        self.assertEqual(self.second.read_bytes(), b"external user edit\n")
        self.assertEqual(self.decide(proposal)["phase"], "already_decided")

    def test_multi_unchanged_context_is_not_written_but_is_revalidated(self):
        proposal = self.ready_multi("multi-one")
        original_stat = self.second.stat()
        self.assertEqual(proposal["files"][1]["oldText"], proposal["files"][1]["newText"])
        self.assertEqual(self.decide(proposal)["phase"], "applied")
        self.assertEqual(self.second.stat(), original_stat)
        self.file.write_bytes(self.original[0])
        proposal = self.ready_multi("multi-one")
        self.second.write_bytes(b"context changed\n")
        self.assertIn(self.decide(proposal)["phase"], ("blocked", "conflicted"))
        self.assertEqual(self.file.read_bytes(), self.original[0])

    def test_multi_tampered_second_frozen_file_is_caught_before_first_write(self):
        proposal = self.ready_multi()
        (Path(proposal["proposal"]).parent / "after-1").write_bytes(b"unreviewed\n")
        result = self.decide(proposal)
        self.assertIn(result["phase"], ("blocked", "conflicted"), result)
        self.assertEqual([path.read_bytes() for path in self.selected], self.original)

    def test_multi_unsupported_staged_changes_reject_entire_proposal(self):
        for case in ("multi-extra", "multi-delete", "multi-mode"):
            with self.subTest(case=case):
                result = self.receive(self.spawn(self.request(case)))
                self.assertEqual(result["phase"], "blocked", result)
                self.assertNotIn("proposal", result)
                self.assertEqual([path.read_bytes() for path in self.selected], self.original)

    def test_multi_empty_duplicate_oversize_and_ambiguous_requests_are_refused(self):
        files = self.request()["files"]
        for overrides in ({"files": []}, {"files": files * 9}, {"files": [files[0], files[0]]},
                          {"files": [dict(files[0], extra=True)]}, {"path": "src/example.txt"},
                          {"files": [dict(files[0], snapshot_sha256="0" * 64)]},
                          {"files": [dict(files[0], path="../escape")]},
                          {"files": [dict(files[0], path="src/auth.json")]}):
            with self.subTest(overrides=overrides):
                result = self.receive(self.spawn(self.request(**overrides)))
                self.assertEqual(result["phase"], "blocked", result)
        for path in self.selected:
            path.write_bytes((b"x" * 100 + b"\n") * 6000)
        result = self.receive(self.spawn(self.request()))
        self.assertEqual(result["phase"], "blocked", result)
        self.assertIn("1 MiB in total", result["reason"])

    def test_multi_second_parent_replacement_publishes_neither_file(self):
        nested = self.root / "nested"
        nested.mkdir()
        moved = nested / "second.txt"
        self.second.rename(moved)
        self.second, self.selected[1] = moved, moved
        proposal = self.ready_multi()
        old = self.root / "old-nested"
        nested.rename(old)
        nested.mkdir()
        shutil.copyfile(old / "second.txt", moved)
        moved.chmod(0o644)
        self.assertIn(self.decide(proposal)["phase"], ("blocked", "conflicted"))
        self.assertEqual(self.file.read_bytes(), self.original[0])
        self.assertEqual(moved.read_bytes(), self.original[1])

    def test_multi_system_runtime_overlap_is_refused_before_launch(self):
        for root in ("/usr", "/usr/share", "/etc", os.path.realpath("/etc/ssl")):
            with self.subTest(root=root):
                result = self.receive(self.spawn(self.request(root=root)))
                self.assertEqual(result["phase"], "blocked", result)
                self.assertIn("overlaps a system runtime mount", result["reason"])
                self.assertNotIn("proposal", result)
                self.assertEqual([path.read_bytes() for path in self.selected], self.original)

    @unittest.skipUnless(os.environ.get("NVIM_AI_STAGED_REAL_OPENCODE"), "opt-in installed OpenCode test")
    def test_multi_installed_opencode_native_edits_with_local_model(self):
        requests = []
        edits = [{"filePath": "/tmp/project/" + str(path.relative_to(self.root)),
                  "oldString": data.decode().strip(), "newString": single.AFTER.decode().strip()}
                 for path, data in zip(self.selected, self.original)]

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
                tools = [item["function"]["name"] for item in body.get("tools", [])]
                active = any("TEST:multi" in str(message.get("content")) for message in messages)
                finished = any(message.get("role") == "tool" for message in messages)
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()

                def chunk(delta, finish=None):
                    value = {"id": "staged-multi-local", "object": "chat.completion.chunk", "created": 1,
                             "model": "model", "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
                    self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode())

                chunk({"role": "assistant"})
                if active and not finished and "edit" in tools:
                    chunk({"tool_calls": [{"index": index, "id": "edit-" + str(index), "type": "function",
                           "function": {"name": "edit", "arguments": json.dumps(edit)}}
                           for index, edit in enumerate(edits)]})
                    chunk({}, "tool_calls")
                else:
                    chunk({"content": "Selected files staged; awaiting Neovim review."})
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
        self.assertEqual([path.read_bytes() for path in self.selected], self.original)
        self.assertEqual([item["newText"].encode() for item in proposal["files"]], [single.AFTER] * 2)
        self.assertTrue(any(sum(message.get("role") == "tool" for message in req.get("messages", [])) >= 2
                            for req in requests), "Real OpenCode must execute both native edit tools")
        self.assertEqual(self.decide(proposal)["phase"], "applied")
        self.assertEqual([path.read_bytes() for path in self.selected], [single.AFTER] * 2)


def load_tests(loader, tests, pattern):
    return unittest.TestSuite(MultiFileTest(name) for name in dir(MultiFileTest)
                              if name.startswith("test_multi_"))


if __name__ == "__main__":
    unittest.main()
