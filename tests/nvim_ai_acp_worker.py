"""ACP/process seam tests: real pipes and Bubblewrap, no provider or database."""
import importlib.util
import os
from pathlib import Path
import shutil
import socket
import tempfile
import time
import unittest


HERE = Path(__file__).resolve().parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE.parent / "scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


staging = load("nvim-ai-staged")
acp = load("nvim-ai-acp-worker")


class WorkerTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="nvim-ai-acp-fault-", dir="/tmp"))
        self.worker = None
        self.addCleanup(self.cleanup)
        self.source = self.root / "real-source.txt"
        self.source.write_bytes(b"original text\n")
        for name in ("home", "config", "data", "cache", "state"):
            (self.root / "agent" / name).mkdir(mode=0o700, parents=True)
        (self.root / "staging").mkdir(mode=0o700)
        self.selected = self.root / "staging/example.txt"
        self.selected.write_bytes(b"original text\n")
        peer = self.root / "peer"
        shutil.copyfile(HERE / "fixtures/ai/acp_fault_peer.py", peer)
        peer.chmod(0o700)
        request = {"bwrap": os.path.realpath(shutil.which("bwrap")), "opencode": str(peer)}
        self.command, self.env = staging.sandbox(request, self.root, {})
        self.worker = self.spawn()

    def spawn(self, **options):
        return acp.Worker(self.command, env=self.env, rpc_timeout=1, stop_timeout=.2, **options)

    def listening(self, port):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=.2):
                return True
        except OSError:
            return False

    def cleanup(self):
        if self.worker is not None:
            result = self.worker.close()
            if not result.reaped or not result.output_closed:
                raise AssertionError("Worker exit unproven; retaining exact scratch evidence: " + str(self.root))
        shutil.rmtree(self.root)

    def test_malformed_reply_cannot_become_a_reusable_completion(self):
        with self.assertRaisesRegex(acp.ProtocolError, "Malformed ACP") as error:
            self.worker.request("fixture/malformed", {})
        self.assertNotIn("fixture-secret", str(error.exception))
        result = self.worker.close()
        self.assertTrue(result.reaped and result.output_closed)
        self.assertFalse(result.settled)
        self.assertEqual(self.source.read_bytes(), b"original text\n")
        with self.assertRaises(acp.ProtocolError):
            self.worker.request("session/prompt", {})

    def test_poll_yields_to_explicit_cancel_without_expiring_the_pending_request(self):
        pending = self.worker.begin("fixture/await-cancel", {})
        for _ in range(3):
            self.assertEqual(self.worker.poll(pending, timeout=.02), (False, None))
        self.worker.notify("session/cancel", {"sessionId": "fixture-session"})
        self.assertEqual(self.worker.receive(pending), {"stopReason": "cancelled"})
        self.assertTrue(self.worker.close().settled)
        self.assertEqual(self.source.read_bytes(), b"original text\n")

    def test_receiving_before_begin_refuses_without_reading_an_unset_deadline(self):
        for method in ("receive", "poll"):
            for identifier in ("missing", None):
                with self.subTest(method=method, identifier=identifier):
                    self.worker.close()
                    self.worker = self.spawn()
                    with self.assertRaisesRegex(acp.ProtocolError, "Unexpected ACP request identity"):
                        getattr(self.worker, method)(identifier)
                    result = self.worker.close()
                    self.assertTrue(result.reaped and result.output_closed)
                    self.assertFalse(result.settled)

    def test_closed_worker_refuses_receive_and_poll_before_first_begin(self):
        self.assertTrue(self.worker.close().settled)
        for method in ("receive", "poll"):
            with self.subTest(method=method):
                with self.assertRaisesRegex(acp.ProtocolError, "closing or closed"):
                    getattr(self.worker, method)("missing")

    def test_wrong_protocol_version_is_not_a_successful_reply(self):
        with self.assertRaisesRegex(acp.ProtocolError, "Malformed ACP"):
            self.worker.request("fixture/wrong-version", {})
        self.assertFalse(self.worker.close().settled)

    def test_ambiguous_or_invalid_envelopes_are_refused_without_peer_diagnostics(self):
        for case in ("duplicate-key", "nan", "overflow", "both", "result-array", "error-string",
                     "error-bool-code", "method-array", "params-array", "mixed"):
            with self.subTest(case=case):
                self.worker.close()
                self.worker = self.spawn()
                with self.assertRaisesRegex(acp.ProtocolError, "Malformed ACP") as error:
                    self.worker.request("fixture/envelope", {"case": case})
                self.assertNotIn("fixture-secret", str(error.exception))
                self.assertFalse(self.worker.close().settled)

    def test_ignored_cancel_times_out_and_cannot_authorize_reuse(self):
        ports = []

        def ready(message):
            ports.append(message["params"]["port"])
            self.assertTrue(self.listening(ports[-1]))
            self.worker.notify("session/cancel", {"sessionId": "fixture"})

        self.worker.close()
        self.worker = self.spawn(on_notification=ready)
        started = time.monotonic()
        with self.assertRaisesRegex(acp.ProtocolError, "deadline"):
            self.worker.request("fixture/stall", {}, timeout=.3)
        result = self.worker.close()
        self.assertTrue(result.reaped and result.output_closed and result.forced)
        self.assertFalse(result.settled)
        self.assertEqual(len(ports), 1)
        self.assertFalse(self.listening(ports[0]))
        self.assertLess(time.monotonic() - started, 2)
        self.assertEqual(self.source.read_bytes(), b"original text\n")
        with self.assertRaises(acp.ProtocolError):
            self.worker.request("session/prompt", {})

    def test_close_acknowledgement_is_not_graceful_worker_exit(self):
        ports = []
        self.worker.close()
        self.worker = self.spawn(on_notification=lambda message: ports.append(message["params"]["port"]))
        self.assertEqual(self.worker.request("session/close", {"sessionId": "fixture"}), {})
        self.assertTrue(self.listening(ports[0]))
        result = self.worker.close()
        self.assertTrue(result.reaped and result.output_closed and result.forced)
        self.assertFalse(result.graceful or result.settled)
        self.assertFalse(self.listening(ports[0]))
        self.assertEqual(self.source.read_bytes(), b"original text\n")
        self.assertEqual(self.worker.close(), result, "Shutdown evidence changed on a repeated close")

    def test_pid_namespace_reaps_detached_descendant_holding_output_pipe(self):
        result = self.worker.request("fixture/descendant", {})
        self.assertTrue(self.listening(result["port"]))
        exit_result = self.worker.close()
        self.assertTrue(exit_result.settled)
        self.assertFalse(self.listening(result["port"]))
        self.assertEqual(self.source.read_bytes(), b"original text\n")

    def test_duplicate_completion_during_shutdown_taints_the_transport(self):
        self.assertEqual(self.worker.request("fixture/duplicate", {})["stopReason"], "end_turn")
        result = self.worker.close()
        self.assertTrue(result.reaped and result.output_closed)
        self.assertFalse(result.settled)

    def test_reply_after_input_eof_cannot_revive_completion(self):
        self.worker.request("fixture/late", {})
        self.assertFalse(self.worker.close().settled)

    def test_repeated_client_request_identity_is_not_executed_again(self):
        with self.assertRaisesRegex(acp.ProtocolError, "Duplicate ACP request"):
            self.worker.request("fixture/duplicate-request", {})
        self.assertFalse(self.worker.close().settled)

    def test_another_worker_response_is_not_completion(self):
        with self.assertRaisesRegex(acp.ProtocolError, "response identity"):
            self.worker.request("fixture/wrong-id", {})
        self.assertFalse(self.worker.close().settled)

    def test_abrupt_exit_without_reply_is_not_completion(self):
        with self.assertRaisesRegex(acp.ProtocolError, "output closed"):
            self.worker.request("fixture/exit", {})
        result = self.worker.close()
        self.assertFalse(result.settled)
        self.assertEqual(result.returncode, 23)

    def test_output_budgets_bound_large_or_flooded_peer_messages(self):
        for case in ("frame", "messages", "bytes"):
            with self.subTest(case=case):
                self.worker.close()
                self.worker = self.spawn()
                with self.assertRaisesRegex(acp.ProtocolError, "budget exceeded"):
                    self.worker.request("fixture/budget", {"case": case}, timeout=5)
                self.assertFalse(self.worker.close().settled)

    def test_peer_that_stops_reading_cannot_block_input_forever(self):
        self.worker.request("fixture/blocked-input", {})
        started = time.monotonic()
        with self.assertRaisesRegex(acp.ProtocolError, "input deadline"):
            self.worker.request("session/prompt", {"text": "x" * (1024 * 1024)}, timeout=.2)
        self.assertFalse(self.worker.close().settled)
        self.assertLess(time.monotonic() - started, 2)

    def test_client_file_and_terminal_operations_are_denied(self):
        self.assertEqual(self.worker.request("fixture/client-operations", {"outside": str(self.source)}),
                         {"denied": 2})
        self.assertTrue(self.worker.close().settled)
        self.assertEqual(self.source.read_bytes(), b"original text\n")


if __name__ == "__main__":
    unittest.main()
