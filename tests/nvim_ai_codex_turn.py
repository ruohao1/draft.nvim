"""Codex semantics with real supervised pipes and selected-file workspaces."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socketserver
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]


def helper(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


turns = helper("nvim-ai-codex-turn")
storage = helper("nvim-ai-codex-store")


class TurnTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="draft-codex-turn-", dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.project = self.root / "project"
        self.project.mkdir(mode=0o700)
        self.source = self.project / "example.txt"
        self.source.write_bytes(b"original text\n")
        self.source.chmod(0o644)
        self.auth = self.root / "auth.json"
        self.auth.write_text('{"OPENAI_API_KEY":"synthetic-key"}')
        self.auth.chmod(0o600)
        self.peer = self.root / "codex"
        self.audit, self.events = [], []
        self.gate = threading.Event()
        audit, gate = self.audit, self.gate

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                message = json.loads(self.rfile.readline())
                audit.append(message)
                if message.get("waiting"):
                    gate.wait(timeout=5)
                self.wfile.write(b"continue\n")

        self.server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.server_thread.start()
        self.store = storage.Store(self.root)
        self.turn = None
        self.addCleanup(self.cleanup)

    def cleanup(self):
        self.gate.set()
        if self.turn:
            self.turn.fail()
        self.store.close()
        self.server.shutdown()
        self.server.server_close()
        self.server_thread.join(timeout=3)

    def start(self, case="answer", session=None, model="openai/gpt-5.4"):
        fixture = (ROOT / "tests/fixtures/ai/conversation_codex.py").read_text()
        self.peer.write_text(fixture.replace('CASE = "answer"', "CASE = " + repr(case))
                            .replace("AUDIT_PORT = 0", "AUDIT_PORT = " + str(self.server.server_address[1])))
        self.peer.chmod(0o700)
        host = self.peer.with_name("codex-code-mode-host")
        if case == "missing-host":
            host.unlink(missing_ok=True)
        else:
            host.write_text("#!/bin/sh\nexit 0\n")
            host.chmod(0o700)
        config = {"backend": "codex", "codex": str(self.peer), "auth_file": str(self.auth),
                  "bwrap": os.path.realpath(shutil.which("bwrap")), "model": model}
        self.turn = turns.Turn(config, self.store, None, session=session)
        self.command = {"kind": "start", "root": str(self.project), "model": model,
                        "message": "Explicit request", "sources": [{"path": "example.txt",
                        "snapshot_sha256": hashlib.sha256(self.source.read_bytes()).hexdigest()}]}
        try:
            self.turn.start(self.command)
        except Exception:
            self.events.extend(self.turn.fail())
        return self.turn

    def until(self, predicate, seconds=5):
        end = time.monotonic() + seconds
        while not predicate():
            if time.monotonic() >= end:
                self.fail("Codex adapter did not reach the expected state")
            try:
                self.events.extend(self.turn.advance())
            except Exception:
                self.events.extend(self.turn.fail())
            if self.turn.done and not predicate():
                self.fail("Codex adapter stopped early: " + repr(self.events))

    def finish(self):
        self.until(lambda: self.turn.done)
        return self.events[-1]

    def methods(self):
        return [entry["method"] for entry in self.audit if "method" in entry]

    def test_private_cache_and_journal_survive_start_resume_and_close(self):
        self.start()
        self.assertEqual(self.finish()["outcome"], "answer")
        self.assertIn("models_cache.json", self.store.check())
        self.assertIn("memories_1.sqlite-journal", self.store.check())
        self.start(session=self.turn.session)
        self.assertEqual(self.finish()["outcome"], "answer")
        self.assertIn("models_cache.json", self.store.check())
        self.assertIn("memories_1.sqlite-journal", self.store.check())
        self.store.close()
        self.assertFalse(self.store.root.exists())
        self.assertEqual(self.source.read_bytes(), b"original text\n")
        for entry in self.audit:
            if entry.get("method") in ("command/exec", "thread/start", "thread/resume", "turn/start"):
                self.assertNotIn("sandbox", entry["params"])
                self.assertNotIn("sandboxPolicy", entry["params"])
            if entry.get("method") == "command/exec":
                self.assertEqual(entry["params"]["command"],
                                 ["/usr/bin/test", "!", "-r", "/home/agent/.codex/auth.json"])

    def test_missing_companion_never_starts_a_worker_or_submits(self):
        self.start("missing-host")
        event = self.finish()
        self.assertEqual(event["outcome"], "failed")
        self.assertIsNone(self.turn.worker)
        self.assertEqual(self.methods(), [])
        self.assertFalse(self.turn.submitted)
        self.assertEqual(self.source.read_bytes(), b"original text\n")
        self.store.close()
        self.assertFalse(self.store.root.exists())

    def test_completion_is_not_start_ack(self):
        self.start("edit-held")
        self.until(lambda: self.turn.stage == "running")
        self.assertFalse(self.turn.done)
        self.assertIsNone(self.turn.frozen)
        self.assertEqual(self.source.read_bytes(), b"original text\n")
        self.assertEqual((self.turn.task / "staging/example.txt").read_bytes(), b"proposed text\n")
        self.gate.set()
        event = self.finish()
        self.assertEqual(event["outcome"], "review")
        self.assertTrue(event["stopped"] and event["graceful"] and event["store_valid"])
        self.assertTrue(self.turn.worker.close().settled)
        self.assertEqual(self.source.read_bytes(), b"original text\n")

    def test_early_events_are_bound_before_display_and_answer_can_resume(self):
        self.start("early")
        self.assertEqual(self.finish()["outcome"], "answer")
        self.assertEqual([e["text"] for e in self.events if e["kind"] == "text"], ["Bounded answer."])
        session = self.turn.session
        self.start(session=session)
        self.assertEqual(self.finish()["outcome"], "answer")
        self.assertEqual(self.turn.session, session)
        self.assertEqual(self.methods().count("thread/start"), 1)
        self.assertEqual(self.methods().count("thread/resume"), 1)
        self.assertEqual(self.methods().count("turn/start"), 2)

    def test_early_and_shutdown_terminal_identity(self):
        for case in ("early-wrong", "wrong-thread", "wrong-turn", "foreign-item",
                     "duplicate-terminal", "late-terminal", "failed-terminal"):
            with self.subTest(case=case):
                self.start(case)
                event = self.finish()
                self.assertEqual(event["outcome"], "failed")
                self.assertIsNone(self.turn.frozen)
                self.assertFalse(event["store_valid"])
                self.assertEqual(self.source.read_bytes(), b"original text\n")
                if case == "early-wrong":
                    self.assertFalse(any(e["kind"] == "text" for e in self.events))
                self.store.close()
                self.store = storage.Store(self.root)
                self.events.clear()

    def test_cancel_ack_is_not_terminal(self):
        self.start("cancel-ack")
        self.until(lambda: self.turn.stage == "running")
        self.events.extend(self.turn.cancel())
        self.until(lambda: self.turn.stage == "interrupting")
        self.assertFalse(self.turn.done)
        self.assertIsNone(self.turn.frozen)
        self.turn.deadline = time.monotonic() - 1
        event = self.finish()
        self.assertEqual(event["kind"], "cancelled")
        self.assertFalse(event["cancel_confirmed"])
        self.assertFalse(event["store_valid"])

    def test_interrupted_terminal_preserves_thread_and_discards_workspace(self):
        self.start("cancel")
        self.until(lambda: self.turn.stage == "running")
        task = self.turn.task
        self.events.extend(self.turn.cancel())
        event = self.finish()
        self.assertTrue(event["cancel_confirmed"] and event["store_valid"])
        self.assertFalse(task.exists())
        self.assertEqual(self.source.read_bytes(), b"original text\n")
        session = self.turn.session
        self.start(session=session)
        self.assertEqual(self.finish()["outcome"], "answer")
        self.assertEqual(self.turn.session, session)

    def test_unsupported_host_and_model_failures_never_submit(self):
        for case in ("wrong-version", "missing-model", "model-loop", "unsupported", "wrong-model", "wrong-policy"):
            with self.subTest(case=case):
                self.start(case)
                event = self.finish()
                self.assertEqual(event["outcome"], "failed")
                self.assertEqual(event["submission"], "not_submitted")
                self.assertNotIn("turn/start", self.methods())
                self.assertIsNone(self.turn.frozen)
                self.store.close()
                self.store = storage.Store(self.root)
                self.events.clear()
                self.audit.clear()

    def test_empty_thread_failure_allows_only_explicit_safe_retry(self):
        self.start("wrong-policy")
        event = self.finish()
        self.assertEqual(event["submission"], "not_submitted")
        self.assertTrue(event["stopped"] and event["graceful"] and event["store_valid"])
        self.assertTrue(event["tokens_retired"])
        self.assertIsNone(self.turn.session)
        self.assertFalse(self.store.root.exists())
        self.assertNotIn("turn/start", self.methods())
        self.assertEqual(self.methods().count("thread/start"), 1)

    def test_resume_failure_never_replays(self):
        self.start()
        self.assertEqual(self.finish()["outcome"], "answer")
        session = self.turn.session
        self.start("resume-refused", session=session)
        event = self.finish()
        self.assertEqual(event["outcome"], "failed")
        self.assertFalse(event["store_valid"])
        self.assertEqual(self.methods().count("thread/start"), 1)
        self.assertEqual(self.methods().count("turn/start"), 1)

    def test_lost_start_response_and_deadline_prohibit_replay(self):
        self.start("lost-start")
        self.until(lambda: self.turn.stage == "turn/start")
        self.assertTrue(self.turn.submitted)
        self.turn.worker.deadline = time.monotonic() - 1
        event = self.finish()
        self.assertEqual(event["submission"], "submitted")
        self.assertFalse(event["store_valid"])
        self.assertIsNone(self.turn.frozen)

    def test_source_drift_after_terminal_cannot_expose_review(self):
        self.start("edit-held")
        self.until(lambda: self.turn.stage == "running")
        self.source.write_bytes(b"user changed this\n")
        self.gate.set()
        event = self.finish()
        self.assertEqual(event["outcome"], "failed")
        self.assertIsNone(self.turn.frozen)
        self.assertEqual(self.source.read_bytes(), b"user changed this\n")

    def test_idle_generation_deadline_cannot_be_renewed(self):
        self.start("cancel")
        self.until(lambda: self.turn.stage == "running")
        self.turn.deadline = time.monotonic() - 1
        event = self.finish()
        self.assertEqual(event["outcome"], "failed")
        self.assertEqual(event["diagnostic"], "timeout")
        self.assertFalse(event["store_valid"])
        self.assertIsNone(self.turn.frozen)

    def test_live_store_tampering_refuses_review_and_continuation(self):
        self.start("edit-held")
        self.until(lambda: self.turn.stage == "running")
        auth = self.store.path / "auth.json"
        auth.chmod(0o644)
        try:
            self.turn.worker.guard_due = 0
            event = self.finish()
            self.assertEqual(event["outcome"], "failed")
            self.assertFalse(event["store_valid"])
            self.assertIsNone(self.turn.frozen)
            self.assertEqual(self.source.read_bytes(), b"original text\n")
        finally:
            auth.chmod(0o600)

    def test_forced_exit_cannot_expose_review(self):
        self.start("forced-exit")
        self.turn.worker.stop_timeout = .1
        event = self.finish()
        self.assertEqual(event["outcome"], "failed")
        self.assertFalse(event["store_valid"])
        self.assertIsNone(self.turn.frozen)
        self.assertTrue(self.turn.worker.close().forced)

    def test_item_callbacks_are_denied_and_model_catalog_is_paginated(self):
        self.start("callbacks")
        self.assertEqual(self.finish()["outcome"], "answer")
        self.assertIn({"client_denied": True}, self.audit)
        self.store.close()
        self.store = storage.Store(self.root)
        self.start("model-pages", model="openai/gpt-second")
        self.assertEqual(self.finish()["outcome"], "answer")
        self.assertEqual(self.turn.models, ["openai/gpt-5.4", "openai/gpt-second"])


if __name__ == "__main__":
    unittest.main()
