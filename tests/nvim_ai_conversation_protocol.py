"""Closed editor commands and bounded real-pipe framing, independent of ACP."""
import copy
import errno
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/nvim-ai-conversation-protocol.py"


def close_descriptor(fd):
    try:
        os.close(fd)
    except OSError as error:
        if error.errno != errno.EBADF:
            raise


def frame(kind="close", serial=1):
    command = {"kind": kind, "conversation_id": "a" * 32, "owner_generation": 1,
               "turn_id": 0, "worker_generation": 0, "root": "/tmp/project",
               "selection": ["example.txt"], "model": "fixture/model"}
    if kind == "start":
        command.update(turn_id=1, worker_generation=1, message="A real question",
                       sources=[{"path": "example.txt", "snapshot_sha256": "b" * 64}])
    return {"version": 1, "serial": serial, "command": command}


class ProtocolTest(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.is_file(), "The bounded editor protocol is not implemented")
        spec = importlib.util.spec_from_file_location("conversation_protocol", SCRIPT)
        self.protocol = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.protocol)

    def decode(self, value):
        return self.protocol.decode_command(json.dumps(value).encode())

    def pipe(self):
        read, write = os.pipe()
        output, result = os.pipe()
        for fd in (read, write, output, result):
            self.addCleanup(close_descriptor, fd)
        return self.protocol.EditorPipe(read, result), write, output

    def test_valid_close_and_start_round_trip_without_coercion(self):
        for kind in ("close", "start"):
            value = frame(kind)
            self.assertEqual(self.decode(value), value)

    def test_duplicate_decoded_keys_and_nonfinite_values_are_refused(self):
        raw = json.dumps(frame()).encode()
        self.assertEqual(self.protocol.decode_command(raw), frame())
        variants = [raw.replace(b'"version": 1', b'"version": 1, "versi\\u006fn": 2')]
        variants += [raw.replace(b'"serial": 1', b'"serial": ' + number)
                     for number in (b'NaN', b'Infinity', b'-Infinity', b'1e9999', b'true', b'1.0')]
        variants += [raw.replace(b'fixture/model', b'fixture/\xff'),
                     raw.replace(b'fixture/model', b'fixture/\\ud800')]
        for value in variants:
            with self.subTest(value=value[:50]), self.assertRaises(self.protocol.Refused):
                self.protocol.decode_command(value)

    def test_unknown_fields_or_unsafe_scope_cannot_enter_the_protocol(self):
        for field, value in [("root", "/tmp/../project"), ("root", "/"),
                             ("selection", ["../secret"]), ("selection", ["a", "a"]),
                             ("selection", []), ("model", "provider/model\n"),
                             ("owner_generation", 0), ("conversation_id", "unknown"),
                             ("turn_id", 2 ** 53), ("worker_generation", True),
                             ("argv", ["/usr/bin/sh"]), ("review_ref", {"manifest": "/tmp/x"})]:
            value_frame = frame()
            value_frame["command"][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(self.protocol.Refused):
                self.decode(value_frame)
        extra = frame()
        extra["extra"] = True
        with self.assertRaises(self.protocol.Refused):
            self.decode(extra)

    def test_sources_and_message_must_match_the_explicit_selection(self):
        for field, value in [("message", " "), ("message", "bad\x1btext"),
                             ("message", "x" * 32769), ("sources", []),
                             ("sources", [{"path": "other.txt", "snapshot_sha256": "b" * 64}]),
                             ("sources", [{"path": "example.txt", "snapshot_sha256": "bad"}])]:
            value_frame = frame("start")
            value_frame["command"][field] = value
            with self.subTest(field=field), self.assertRaises(self.protocol.Refused):
                self.decode(value_frame)

    def test_review_identity_and_context_are_closed_and_complete(self):
        value = frame("start")
        command = value["command"]
        command.update(kind="revise", round_id=1, proposal_revision=1,
                       proposal_token="token_1", receipt_sequence=0)
        command["context"] = {key: command[key] for key in
                              ("round_id", "proposal_revision", "proposal_token", "receipt_sequence")}
        command["context"]["files"] = [{"path": "example.txt", "state": "pending"}]
        self.assertEqual(self.decode(value), value)
        for change in ("identity", "proof", "path", "state"):
            invalid = copy.deepcopy(value)
            context = invalid["command"]["context"]
            if change == "identity":
                context["proposal_token"] = "other_token"
            elif change == "proof":
                context["context_valid"] = True
            elif change == "path":
                context["files"][0]["path"] = "extra.txt"
            else:
                context["files"][0]["state"] = "made_up"
            with self.subTest(change=change), self.assertRaises(self.protocol.Refused):
                self.decode(invalid)

    def test_depth_token_and_frame_limits_are_enforced_before_json_expansion(self):
        for raw in (b'[' * 33 + b'0' + b']' * 33,
                    b'[' + b'0,' * 8192 + b'0]', b'"' + b'x' * (1024 * 1024)):
            with self.assertRaisesRegex(self.protocol.Refused, "budget"):
                self.protocol.decode_command(raw)

    def test_fragmented_unicode_and_eof_have_real_pipe_semantics(self):
        pipe, writer, _ = self.pipe()
        value = frame("start")
        value["command"]["message"] = "réviser 日本語"
        raw = json.dumps(value, ensure_ascii=False).encode() + b'\n'
        result = []
        for byte in raw:
            os.write(writer, bytes([byte]))
            result += pipe.read_ready()
        self.assertEqual(result, [value])
        self.assertFalse(pipe.eof)

    def test_partial_frame_at_eof_is_not_a_command(self):
        pipe, writer, _ = self.pipe()
        os.write(writer, b'{"version":1')
        self.assertEqual(pipe.read_ready(), [])
        os.close(writer)
        with self.assertRaises(self.protocol.Refused):
            pipe.read_ready()

    def test_binding_fences_duplicate_serials_and_wrong_owner_or_turn(self):
        binding = self.protocol.Binding()
        start = frame("start")
        self.assertTrue(binding.accept(start))
        self.assertFalse(binding.accept(start))
        for change in ("serial", "owner", "turn", "scope"):
            invalid = frame("close", 2)
            invalid["command"].update(turn_id=1, worker_generation=1)
            if change == "serial":
                invalid["serial"] = 3
            elif change == "owner":
                invalid["command"]["conversation_id"] = "c" * 32
            elif change == "turn":
                invalid["command"]["turn_id"] = 2
            else:
                invalid["command"]["selection"] = ["other.txt"]
            with self.subTest(change=change), self.assertRaises(self.protocol.Refused):
                binding.accept(invalid)

    def test_pipe_emits_only_complete_correlated_frames(self):
        pipe, _, reader = self.pipe()
        event = {"kind": "closed", "sequence": 1}
        pipe.enqueue(1, event)
        pipe.flush_ready()
        self.assertEqual(json.loads(os.read(reader, 1024)), {"version": 1, "serial": 1, "event": event})
        self.assertFalse(pipe.writing)

    def test_more_than_64_pending_commands_are_refused(self):
        pipe, _, _ = self.pipe()
        with tempfile.TemporaryFile() as stream:
            stream.write((json.dumps(frame()).encode() + b'\n') * 65)
            stream.seek(0)
            pipe.input = stream.fileno()
            with self.assertRaisesRegex(self.protocol.Refused, "queue budget"):
                pipe.read_ready()

    def test_output_limits_apply_to_frames_events_and_undelivered_bytes(self):
        pipe, _, _ = self.pipe()
        with self.assertRaisesRegex(self.protocol.Refused, "output budget"):
            pipe.enqueue(1, {"text": "x" * (8 * 1024 * 1024)})
        pipe, _, _ = self.pipe()
        for _ in range(20000):
            pipe.enqueue(1, {"kind": "text"})
        with self.assertRaisesRegex(self.protocol.Refused, "output budget"):
            pipe.enqueue(1, {"kind": "text"})
        pipe, _, _ = self.pipe()
        for serial in range(1, 5):
            pipe.enqueue(serial, {"text": "x" * (8 * 1024 * 1024 - 128)})
        with self.assertRaisesRegex(self.protocol.Refused, "output budget"):
            pipe.enqueue(5, {"text": "x" * 1024})

    def test_pending_input_bytes_are_bounded_even_with_valid_frames(self):
        pipe, _, _ = self.pipe()
        with tempfile.TemporaryFile() as stream:
            stream.write((json.dumps(frame()).encode() + b' ' * 900000 + b'\n') * 3)
            stream.seek(0)
            pipe.input = stream.fileno()
            with self.assertRaisesRegex(self.protocol.Refused, "pending input budget"):
                pipe.read_ready()

    def test_partial_writes_do_not_renew_the_delivery_deadline(self):
        pipe, _, reader = self.pipe()
        with patch.object(self.protocol.time, "monotonic", return_value=100):
            pipe.enqueue(1, {"text": "x" * (1024 * 1024)})
            pipe.flush_ready()
        self.assertTrue(pipe.writing)
        os.read(reader, 4096)
        with patch.object(self.protocol.time, "monotonic", return_value=104):
            pipe.flush_ready()
        with patch.object(self.protocol.time, "monotonic", return_value=105):
            with self.assertRaisesRegex(self.protocol.Refused, "delivery deadline"):
                pipe.flush_ready()


if __name__ == "__main__":
    unittest.main()
