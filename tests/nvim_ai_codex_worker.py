"""Codex envelopes and asynchronous pipe lifecycle; no provider/account."""
import importlib.util
import os
from pathlib import Path
import shutil
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]


def helper(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


acp = helper("nvim-ai-acp-worker")
staging = helper("nvim-ai-staged")


class CodexWorkerTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="draft-codex-wire-", dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        for name in ("home", "config", "data", "cache", "state"):
            (root / "agent" / name).mkdir(mode=0o700, parents=True)
        (root / "staging").mkdir(mode=0o700)
        peer = root / "peer"
        shutil.copyfile(ROOT / "tests/fixtures/ai/conversation_codex.py", peer)
        peer.chmod(0o700)
        self.command, self.env = staging.sandbox(
            {"bwrap": os.path.realpath(shutil.which("bwrap")), "opencode": str(peer)}, root, {})
        self.command[self.command.index("--") + 1:] = ["/opt/opencode", "app-server"]
        self.worker = None
        self.addCleanup(self.cleanup_worker)

    def spawn(self, **options):
        self.cleanup_worker()
        self.worker = acp.Worker(self.command, env=self.env, rpc_timeout=1,
                                 stop_timeout=.2, **options)
        return self.worker

    def cleanup_worker(self):
        if self.worker is not None:
            result = self.worker.close()
            self.assertTrue(result.reaped and result.output_closed)
            self.worker = None

    def test_codex_envelopes_and_idle_pump(self):
        notifications = []
        worker = self.spawn(wire="codex", on_notification=notifications.append)
        result = worker.request("fixture/stream", {})
        self.assertEqual(result, {"saw_jsonrpc": False, "denied": True, "additive": {"future": True}})
        deadline = time.monotonic() + 1
        count = 0
        while not any(n["method"] == "turn/completed" for n in notifications):
            count += worker.poll_events(deadline=deadline)
        self.assertGreater(count, 0)
        self.assertEqual(notifications[0]["params"]["delta"], "Early text")
        self.assertEqual(notifications[-1]["method"], "turn/completed")
        self.assertTrue(worker.close().settled)

    def test_acp_stays_strict(self):
        worker = self.spawn()
        with self.assertRaisesRegex(acp.ProtocolError, "Malformed ACP"):
            worker.request("fixture/stream", {})
        self.assertFalse(worker.close().settled)

    def test_terminal_validation_during_close(self):
        terminals = []
        def validate(message):
            if message["method"] == "turn/completed":
                terminals.append(message)
                if len(terminals) > 1:
                    raise ValueError("fixture-secret-duplicate")
        worker = self.spawn(wire="codex", on_notification=validate)
        worker.request("fixture/late-terminal", {})
        while not terminals:
            worker.poll_events(deadline=time.monotonic() + 1)
        result = worker.close()
        self.assertTrue(result.reaped and result.output_closed and result.graceful)
        self.assertFalse(result.settled)
        self.assertNotIn("fixture-secret", result.fault)
        self.assertEqual(len(terminals), 2)

    def test_shutdown_never_executes_a_client_request(self):
        operations = []
        worker = self.spawn(wire="codex", on_request=operations.append)
        worker.request("fixture/shutdown-request", {})
        self.assertFalse(worker.close().settled)
        self.assertEqual(operations, [])

    def test_terminal_before_eof_is_delivered_before_exit_validation(self):
        messages = []
        worker = self.spawn(wire="codex", on_notification=messages.append)
        worker.request("fixture/terminal-exit", {})
        deadline = time.monotonic() + 1
        while not messages:
            worker.poll_events(deadline=deadline)
        self.assertEqual(messages[-1]["method"], "turn/completed")
        self.assertTrue(worker.close().settled)

    def test_idle_guard_failure_still_reaps_the_worker(self):
        marker = Path(self.temporary.name) / "tainted"
        def guard():
            if marker.exists():
                raise ValueError("fixture-secret-state")
        worker = self.spawn(wire="codex", guard=guard)
        worker.request("fixture/echo", {})
        marker.touch()
        deadline = time.monotonic() + 1
        with self.assertRaisesRegex(acp.ProtocolError, "state check"):
            while True:
                worker.poll_events(deadline=deadline)
        result = worker.close()
        self.assertTrue(result.reaped and result.output_closed)
        self.assertFalse(result.settled)
        self.assertNotIn("fixture-secret", result.fault)

    def test_malformed_codex_frames_taint_exit(self):
        for case in ("timestamp-bool", "timestamp-float", "timestamp-overflow",
                     "request-timestamp", "jsonrpc", "duplicate-key", "unknown-envelope",
                     "mixed", "depth", "nan"):
            with self.subTest(case=case):
                worker = self.spawn(wire="codex")
                with self.assertRaisesRegex(acp.ProtocolError, "Malformed"):
                    worker.request("fixture/envelope", {"case": case})
                self.assertFalse(worker.close().settled)
        worker = self.spawn(wire="codex")
        with self.assertRaisesRegex(acp.ProtocolError, "Malformed"):
            worker.request("fixture/bad-utf8", {})
        self.assertFalse(worker.close().settled)

    def test_idle_pump_rejects_unsolicited_responses_and_duplicate_requests(self):
        for method in ("fixture/unsolicited", "fixture/duplicate-request", "fixture/exit"):
            with self.subTest(method=method):
                worker = self.spawn(wire="codex")
                worker.request(method, {})
                with self.assertRaises(acp.ProtocolError):
                    deadline = time.monotonic() + 1
                    while True:
                        worker.poll_events(deadline=deadline)
                self.assertFalse(worker.close().settled)

    def test_idle_pump_keeps_budgets_and_yields_to_cancel(self):
        for method, params in (("fixture/oversized", {}),
                               ("fixture/flood", {"count": 20001}),
                               ("fixture/flood", {"count": 5, "size": 8 * 1024 * 1024})):
            with self.subTest(method=method, params=params):
                worker = self.spawn(wire="codex")
                worker.request(method, params)
                with self.assertRaisesRegex(acp.ProtocolError, "budget"):
                    deadline = time.monotonic() + 5
                    while True:
                        count = worker.poll_events(deadline=deadline)
                        self.assertLessEqual(count, 64)
                self.assertFalse(worker.close().settled)

    def test_output_does_not_renew_absolute_deadline(self):
        worker = self.spawn(wire="codex")
        worker.request("fixture/ticker", {})
        deadline = time.monotonic() + .05
        with self.assertRaisesRegex(acp.ProtocolError, "deadline"):
            while True:
                worker.poll_events(deadline=deadline, timeout=.01)
        self.assertLess(time.monotonic() - deadline, .2)
        self.assertFalse(worker.close().settled)

    def test_codex_depth_bound_ignores_braces_in_strings(self):
        worker = self.spawn(wire="codex")
        value = worker.request("fixture/nesting", {"depth": 30})["value"]
        for _ in range(30):
            value = value[0]
        self.assertEqual(value, '{} " []')
        worker = self.spawn(wire="codex")
        with self.assertRaisesRegex(acp.ProtocolError, "depth budget"):
            worker.request("fixture/nesting", {"depth": 31})
        self.assertFalse(worker.close().settled)

    def test_blocked_codex_write_can_be_interrupted_without_splicing_cancel(self):
        attempts = []
        blocked = False
        def interrupt():
            if blocked:
                attempts.append(True)
            return len(attempts) >= 2
        worker = self.spawn(wire="codex", on_write_wait=interrupt)
        worker.request("fixture/blocked", {})
        blocked = True
        with self.assertRaisesRegex(acp.ProtocolError, "interrupted"):
            worker.begin("turn/start", {"text": "x" * (1024 * 1024)}, timeout=10)
        with self.assertRaises(acp.ProtocolError):
            worker.notify("turn/interrupt", {})
        self.assertFalse(worker.close().settled)

    def test_idle_pump_refuses_pending_rpc_and_invalid_timeouts(self):
        worker = self.spawn(wire="codex")
        for value in (0, -1, True, float("nan"), float("inf")):
            with self.subTest(timeout=value), self.assertRaises(ValueError):
                worker.poll_events(deadline=time.monotonic() + 1, timeout=value)
        for value in (True, float("nan"), float("inf")):
            with self.subTest(deadline=value), self.assertRaises(ValueError):
                worker.poll_events(deadline=value)
        worker.begin("fixture/echo", {})
        with self.assertRaises(acp.ProtocolError):
            worker.poll_events(deadline=time.monotonic() + 1)
        self.assertFalse(worker.close().settled)

    def test_unknown_wire_never_starts_a_child(self):
        with self.assertRaises(ValueError):
            acp.Worker(["/no/such/executable"], env={}, wire="other")


if __name__ == "__main__":
    unittest.main()
