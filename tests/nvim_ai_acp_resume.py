"""Opt-in pinned-binary interoperability proof; no production conversation API yet."""
import importlib.util
import os
from pathlib import Path
import stat
import threading
import unittest


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("acp_session_probe", HERE / "fixtures/ai/acp_session_probe.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


@unittest.skipUnless(os.environ.get("NVIM_AI_ACP_REAL_OPENCODE"), "opt-in pinned OpenCode/local-provider proof")
class ResumeTest(unittest.TestCase):
    def setUp(self):
        self.fixture = probe.Fixture(os.path.realpath(os.environ["NVIM_AI_ACP_REAL_OPENCODE"]))
        self.addCleanup(self.fixture.close)

    def test_assistant_and_native_tool_context_survive_fresh_worker(self):
        self.fixture.provider.replies.extend([
            {"edit": True}, {"text": "First-turn assistant marker: copper-orbit-731."},
            {"text": "Second turn received."},
        ])
        with self.fixture.worker() as first:
            session = first.start()
            self.assertEqual(first.prompt("Edit the selected copy from original text to proposed text.")["stopReason"],
                             "end_turn")
            self.assertEqual(first.selected.read_bytes(), b"proposed text\n")
            self.assertEqual(self.fixture.source.read_bytes(), b"original text\n")
        self.assertTrue(first.graceful, "Review requires graceful, fully reaped worker exit")
        self.assertFalse(first.task.exists(), "Worker HOME/XDG/workspace must not survive restart")
        self.assertFalse(first.listening(), "The ACP HTTP listener survived its worker")

        with self.fixture.worker() as second:
            second.start(session)
            self.assertEqual(second.prompt("Continue the conversation without editing.")["stopReason"], "end_turn")
            messages = self.fixture.provider.requests[-1]["body"]["messages"]
            self.assertTrue(any(m.get("role") == "assistant" and
                                "copper-orbit-731" in str(m.get("content")) for m in messages),
                            "The fresh worker lost prior assistant history")
            self.assertTrue(any(m.get("role") == "tool" and m.get("tool_call_id") == "first_native_edit"
                                for m in messages), "The fresh worker lost actual native-tool history")
            self.assertEqual(second.selected.read_bytes(), b"original text\n",
                             "Rejected/unpublished prior edits must not silently become saved files")
            self.assertEqual(self.fixture.source.read_bytes(), b"original text\n")
        self.assertTrue(second.graceful)
        self.assertFalse(second.listening())
        self.assertEqual([r["authorization"] for r in self.fixture.provider.requests],
                         ["Bearer fixture-profile-1", "Bearer fixture-profile-1", "Bearer fixture-profile-2"])
        self.assertIn("fs/write_text_file", first.denied)
        self.assertEqual(len(self.fixture.provider.requests), 3, "Unexpected extra provider request")
        artifacts = {}
        for entry in self.fixture.store.iterdir():
            metadata = entry.lstat()
            self.assertTrue(stat.S_ISREG(metadata.st_mode))
            self.assertEqual((stat.S_IMODE(metadata.st_mode), metadata.st_nlink, metadata.st_uid),
                             (0o600, 1, os.getuid()))
            artifacts[entry.name] = metadata.st_size
        self.assertIn("opencode.db", artifacts)
        self.assertLessEqual(set(artifacts), {"opencode.db", "opencode.db-wal", "opencode.db-shm"})
        self.assertLess(sum(artifacts.values()), 64 * 1024 * 1024)
        print(f"\nACP startup: first={first.startup:.3f}s resumed={second.startup:.3f}s", flush=True)
        print(f"Retained artifacts (bytes): {artifacts}", flush=True)

    def test_model_choice_is_reapplied_after_restart_without_implicit_prompt(self):
        self.fixture.provider.replies.extend([{"text": "Original model turn."}, {"text": "Changed model turn."}])
        with self.fixture.worker() as first:
            session = first.start()
            first.prompt("Answer briefly using the configured model.")
            first.choose("model", "fixture/second-model")
            self.assertEqual(len(self.fixture.provider.requests), 1, "A settings change sent a model request")
        with self.fixture.worker() as second:
            second.start(session, model="fixture/second-model")
            restored_model = next(option["currentValue"] for option in second.session_response["configOptions"]
                                  if option["id"] == "model")
            self.assertEqual(restored_model, "fixture/model",
                             "Recheck the pinned restoration contract: an unsubmitted setting is memory-only")
            self.assertEqual(len(self.fixture.provider.requests), 1, "Resume/settings automatically submitted a prompt")
            second.prompt("Answer this new explicit message.")
            self.assertEqual([r["body"]["model"] for r in self.fixture.provider.requests], ["model", "second-model"])
            with self.assertRaises(probe.ProtocolError):
                second.choose("model", "fixture/unavailable-model")
            self.assertEqual(len(self.fixture.provider.requests), 2, "Invalid model caused a fallback request")
        self.assertTrue(first.graceful and second.graceful)

    def test_replaced_retained_store_refuses_launch_without_replaying_prompt(self):
        self.fixture.provider.replies.append({"text": "This conversation requires its retained store."})
        with self.fixture.worker() as first:
            session = first.start()
            first.prompt("Remember this first explicit message.")
        # Replace the closed store directory, without reading/modifying DB bytes.
        # The production owner must reject it before any second worker launches.
        # No database bytes or rows are read, modified, copied or reconstructed.
        self.fixture.store.rename(self.fixture.root / "retired-backend-store")
        self.fixture.store.mkdir(mode=0o700)
        try:
            with self.assertRaises(probe.storage.Refused):
                with self.fixture.worker() as second:
                    second.start(session)
            self.assertEqual(len(self.fixture.provider.requests), 1, "Missing state caused an automatic prompt replay")
            self.assertEqual(self.fixture.source.read_bytes(), b"original text\n")
            self.assertEqual(len(self.fixture.workers), 1, "A worker launched against a substituted store")
        finally:
            self.fixture.store.rmdir()
            (self.fixture.root / "retired-backend-store").rename(self.fixture.store)
        self.assertTrue(first.graceful)

    def test_cooperatively_cancelled_turn_can_resume_in_a_fresh_worker(self):
        release = threading.Event()
        self.addCleanup(release.set)
        self.fixture.provider.replies.extend([
            {"text": "Partial interrupted answer.", "hold": release}, {"text": "New explicit turn after cancel."},
        ])
        with self.fixture.worker() as first:
            session = first.start()
            identifier = first.begin("session/prompt", {"sessionId": session, "prompt": [
                {"type": "text", "text": "cancelled-user-turn: answer without editing"}]})
            self.assertTrue(self.fixture.provider.streaming.wait(timeout=5), "Provider never began its held stream")
            first.send({"method": "session/cancel", "params": {"sessionId": session}})
            self.assertEqual(first.receive(identifier, timeout=5)["stopReason"], "cancelled")
            release.set()
        self.assertTrue(first.graceful, "Cooperative cancellation needed forced shutdown")
        self.assertFalse(first.listening())
        with self.fixture.worker() as second:
            second.start(session)
            self.assertEqual(len(self.fixture.provider.requests), 1, "Resume replayed the cancelled request")
            self.assertEqual(second.prompt("This is a new explicit user turn.")["stopReason"], "end_turn")
            messages = self.fixture.provider.requests[-1]["body"]["messages"]
            self.assertTrue(any(m.get("role") == "user" and "cancelled-user-turn" in str(m.get("content"))
                                for m in messages), "Cancellation lost the session's prior user context")
            self.assertEqual(self.fixture.source.read_bytes(), b"original text\n")
        self.assertTrue(second.graceful)
        self.assertEqual(len(self.fixture.provider.requests), 2)


if __name__ == "__main__":
    unittest.main()
