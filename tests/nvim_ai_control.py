"""Scope client and bounded backend event protocol tests; no providers."""

import importlib.util
import base64
import io
import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest import mock
import urllib.error

ROOT = pathlib.Path(__file__).resolve().parents[1]


def load_helper(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


control = load_helper("nvim-ai-control")
event_helper = load_helper("nvim-ai-event")


class FakeUnixServer:
    def __init__(self, response=None, raw_response=None, delay=0):
        self.response = response
        self.raw_response = raw_response
        self.delay = delay
        self.request = None
        self.error = None

    def __enter__(self):
        self.directory = tempfile.TemporaryDirectory(prefix="ai-control-")
        os.chmod(self.directory.name, 0o700)
        self.path = self.directory.name + "/control.sock"
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.settimeout(2)
        self.listener.bind(self.path)
        self.listener.listen(1)

        def serve():
            try:
                connection, _ = self.listener.accept()
                with connection:
                    connection.settimeout(2)
                    data = b""
                    while True:
                        chunk = connection.recv(8193)
                        if not chunk:
                            break
                        data += chunk
                        if len(data) > 8192:
                            raise AssertionError("request exceeded limit")
                    self.request = json.loads(data)
                    threading.Event().wait(self.delay)
                    payload = self.raw_response
                    if payload is None:
                        payload = (json.dumps(self.response) + "\n").encode()
                    try:
                        connection.sendall(payload)
                    except BrokenPipeError:
                        pass
            except Exception as error:
                self.error = error

        self.thread = threading.Thread(target=serve, daemon=True)
        self.thread.start()
        return self

    def __exit__(self, *args):
        self.thread.join(3)
        self.listener.close()
        self.directory.cleanup()
        if self.thread.is_alive():
            raise AssertionError("fake socket server did not finish")
        if self.error and args[0] is None:
            raise self.error


class ControlClientTests(unittest.TestCase):
    def test_exact_request_and_response(self):
        response = {"schema": 1, "ok": True, "code": "granted", "message": "approved"}
        with FakeUnixServer(response) as server:
            result = control.request_scope(
                server.path, "b" * 32, "/outside/physical", "generate a fixture", 1.0
            )
        self.assertEqual(result, response)
        self.assertEqual(server.request, {
            "schema": 1, "operation": "request_scope", "token": "b" * 32,
            "path": "/outside/physical", "reason": "generate a fixture",
        })

    def test_missing_neovim_socket_is_actionable(self):
        with self.assertRaisesRegex(RuntimeError, "reopen the owning Neovim instance"):
            control.request_scope("/missing/control.sock", "b" * 32, "/outside", "reason", .1)

    def test_unsafe_request_is_refused_before_connection(self):
        valid = ["/missing/control.sock", "b" * 32, "/outside", "reason", .1]
        cases = [
            (0, "relative"), (0, "/socket\n"), (1, "B" * 32), (1, "b" * 31),
            (2, ""), (2, "relative"), (2, "/a\n"), (2, "/a\x85"),
            (2, "/" + "é" * 2048), (2, "/\ud800"),
            (3, ""), (3, "  "), (3, "x" * 513), (3, "a\t"), (3, "a\x7f"),
            (4, 0), (4, float("inf")), (4, True),
        ]
        for index, value in cases:
            with self.subTest(index=index, value=repr(value)):
                arguments = valid.copy()
                arguments[index] = value
                with self.assertRaisesRegex(RuntimeError, "invalid"):
                    control.request_scope(*arguments)

    def test_response_protocol_is_strict_and_bounded(self):
        valid = {"schema": 1, "ok": True, "code": "granted", "message": "approved"}
        responses = [
            b"x" * 4097, b"{", b"[]\n", b"null\n", b"\xff\n",
            json.dumps(valid).encode(), (json.dumps(valid) + "\n{}\n").encode(),
            b'{"schema":1,"schema":1,"ok":true,"code":"granted","message":"ok"}\n',
        ]
        for field, value in [
            ("schema", True), ("schema", 2), ("ok", 1), ("extra", ""),
            ("code", "x" * 65), ("code", "injected\n"), ("message", "x" * 513),
            ("message", "escape\x1b"), ("message", "\ud800"),
        ]:
            responses.append((json.dumps(dict(valid, **{field: value})) + "\n").encode())
        for raw in responses:
            with self.subTest(response=repr(raw[:70])):
                with FakeUnixServer(raw_response=raw) as server:
                    with self.assertRaises(RuntimeError):
                        control.request_scope(server.path, "b" * 32, "/outside", "reason", 1)

    def test_partial_response_timeout_is_bounded(self):
        with FakeUnixServer(raw_response=b"{", delay=.1) as server:
            with self.assertRaisesRegex(RuntimeError, "timed out"):
                control.request_scope(server.path, "b" * 32, "/outside", "reason", .02)

    def test_cli_reports_only_bounded_message_and_refusal_status(self):
        for approved, expected in [(True, 0), (False, 2)]:
            reply = {"schema": 1, "ok": approved, "code": "granted" if approved else "denied",
                     "message": "scope decision"}
            with FakeUnixServer(reply) as server:
                result = subprocess.run(
                    [sys.executable, "-I", "-B", str(ROOT / "scripts/nvim-ai-control.py"),
                     "request-scope", "--path", "/outside", "--reason", "reason"],
                    env={"NVIM_AI_CONTROL_SOCKET": server.path, "NVIM_AI_CONTROL_TOKEN": "b" * 32},
                    capture_output=True, timeout=3,
                )
            self.assertEqual((result.returncode, result.stdout, result.stderr),
                             (expected, b"scope decision\n", b""))

    def test_cli_missing_environment_fails_without_secret_output(self):
        result = subprocess.run(
            [sys.executable, "-I", "-B", str(ROOT / "scripts/nvim-ai-control.py"),
             "request-scope", "--path", "/outside", "--reason", "secret-reason"],
            env={}, capture_output=True, timeout=3,
        )
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(b"secret-reason", result.stdout + result.stderr)


class EventTests(unittest.TestCase):
    def test_claude_hook_discards_prompt_content(self):
        payload = {
            "hook_event_name": "PreToolUse",
            "session_id": "11111111-1111-4111-8111-111111111111",
            "prompt": "must not persist",
        }
        event = event_helper.normalize_claude(payload, now=123)
        self.assertEqual(event, {
            "schema": 1, "backend": "claude", "session": payload["session_id"],
            "state": "busy", "time": 123,
        })
        self.assertNotIn("prompt", json.dumps(event))

    def test_opencode_event_maps_only_supported_state(self):
        payload = {"type": "permission.asked", "properties": {"sessionID": "ses_123", "content": "discard"}}
        event = event_helper.normalize_opencode(payload, now=124)
        self.assertEqual(event, {
            "schema": 1, "backend": "opencode", "session": "ses_123",
            "state": "approval", "time": 124,
        })
        self.assertNotIn("content", json.dumps(event))

    def test_only_valid_supported_states_and_sessions_are_normalized(self):
        uuid = "11111111-1111-4111-8111-111111111111"
        for name, state in {
            "SessionStart": "idle", "PostToolUse": "idle", "PreToolUse": "busy",
            "UserPromptSubmit": "busy", "PermissionRequest": "approval",
            "Stop": "completed", "SessionEnd": "completed",
        }.items():
            with self.subTest(hook=name):
                event = event_helper.normalize_claude({"hook_event_name": name, "session_id": uuid}, now=123)
                self.assertEqual(event["state"], state)
        for payload in [
            None, [], {}, {"hook_event_name": "unknown", "session_id": uuid},
            {"hook_event_name": "PreToolUse", "session_id": "not-uuid"},
            {"hook_event_name": "PreToolUse", "session_id": uuid.replace("4111", "1111")},
            {"hook_event_name": "PreToolUse", "session_id": uuid + "\n"},
        ]:
            self.assertIsNone(event_helper.normalize_claude(payload, now=123))
        for name, status, state in [
            ("session.status", "idle", "idle"), ("session.status", "busy", "busy"),
            ("session.status", "retry", "busy"), ("permission.asked", None, "approval"),
            ("session.idle", None, "completed"), ("session.error", None, "failed"),
        ]:
            payload = {"type": name, "properties": {"sessionID": "ses_123", "status": {"type": status}}}
            self.assertEqual(event_helper.normalize_opencode(payload, now=124)["state"], state)
        for payload in [
            None, [], {}, {"type": "message.updated", "properties": {"sessionID": "ses_123"}},
            {"type": "session.status", "properties": {"sessionID": "ses_123", "status": {"type": "unknown"}}},
            {"type": "session.idle", "properties": {"sessionID": "ses_"}},
            {"type": "session.idle", "properties": {"sessionID": "ses_abc\n"}},
            {"type": "session.idle", "properties": {"sessionID": "ses_" + "x" * 125}},
        ]:
            self.assertIsNone(event_helper.normalize_opencode(payload, now=124))

    def test_claude_cli_appends_only_normalized_record_to_private_file(self):
        with tempfile.TemporaryDirectory(prefix="ai-events-") as directory:
            path = pathlib.Path(directory) / "events.ndjson"
            payload = {
                "hook_event_name": "PreToolUse", "session_id": "11111111-1111-4111-8111-111111111111",
                "prompt": "private prompt", "tool_input": {"command": "secret command"},
            }
            result = subprocess.run(
                [sys.executable, "-I", "-B", str(ROOT / "scripts/nvim-ai-event.py"),
                 "claude-hook", "--event-file", str(path)],
                input=json.dumps(payload).encode(), capture_output=True, timeout=3,
            )
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))
            record = json.loads(path.read_bytes())
            self.assertEqual(set(record), {"schema", "backend", "session", "state", "time"})
            self.assertEqual(record["state"], "busy")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertNotIn(b"secret", path.read_bytes())

    def test_event_file_rejects_links_modes_and_non_regular_objects(self):
        event = event_helper.normalize_opencode({"type": "session.idle", "properties": {"sessionID": "ses_123"}}, now=1)
        with tempfile.TemporaryDirectory(prefix="ai-events-") as directory:
            base = pathlib.Path(directory)
            target = base / "target"
            target.write_bytes(b"unchanged")
            target.chmod(0o600)
            path = base / "events"
            path.symlink_to(target)
            with self.assertRaises((OSError, ValueError)):
                event_helper.append_event(str(path), event)
            self.assertEqual(target.read_bytes(), b"unchanged")
            path.unlink()
            os.link(target, path)
            with self.assertRaisesRegex(ValueError, "unsafe"):
                event_helper.append_event(str(path), event)
            path.unlink()
            for mode in (0o644, 0o666, 0o400):
                target.chmod(mode)
                with self.assertRaises((OSError, ValueError)):
                    event_helper.append_event(str(target), event)
            target.chmod(0o600)
            with mock.patch.object(event_helper.os, "getuid", return_value=os.getuid() + 1):
                with self.assertRaisesRegex(ValueError, "unsafe"):
                    event_helper.append_event(str(target), event)
            os.mkfifo(path, 0o600)
            with self.assertRaisesRegex(ValueError, "unsafe"):
                event_helper.append_event(str(path), event)
            path.unlink()
            alias = base / "alias"
            alias.symlink_to(base, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "symlink"):
                event_helper.append_event(str(alias / "target"), event)
            self.assertEqual(target.read_bytes(), b"unchanged")

    def test_concurrent_appends_are_complete_and_rollover_keeps_latest_record(self):
        with tempfile.TemporaryDirectory(prefix="ai-events-") as directory:
            path = pathlib.Path(directory) / "events"
            events = [event_helper.normalize_opencode({
                "type": "session.idle", "properties": {"sessionID": "ses_" + str(index)}
            }, now=index) for index in range(80)]
            with ThreadPoolExecutor(max_workers=8) as pool:
                list(pool.map(lambda event: event_helper.append_event(str(path), event), events))
            actual = [json.loads(line) for line in path.read_bytes().splitlines()]
            self.assertCountEqual(actual, events)
            path.write_bytes(b"x" * (1024 * 1024))
            event_helper.append_event(str(path), events[-1])
            self.assertEqual(json.loads(path.read_bytes()), events[-1])
            with mock.patch.object(event_helper.os, "write", return_value=0):
                with self.assertRaisesRegex(ValueError, "incomplete"):
                    event_helper.append_event(str(path), events[-1])

    def test_hook_input_is_bounded_and_failure_does_not_fabricate_an_event(self):
        with tempfile.TemporaryDirectory(prefix="ai-events-") as directory:
            path = pathlib.Path(directory) / "events"
            for payload in (b"x" * 65537, b"{", b"\xff", b'{"hook_event_name":"Stop","hook_event_name":"Stop"}'):
                result = subprocess.run(
                    [sys.executable, "-I", "-B", str(ROOT / "scripts/nvim-ai-event.py"),
                     "claude-hook", "--event-file", str(path)],
                    input=payload, capture_output=True, timeout=3,
                )
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, b"")
                self.assertFalse(path.exists())

    def test_opencode_stream_uses_auth_and_discards_unsupported_or_oversized_events(self):
        with tempfile.TemporaryDirectory(prefix="ai-events-") as directory:
            path = pathlib.Path(directory) / "events"
            running = [True]
            payload = b"".join([
                b": heartbeat\n\n",
                b'data: {"type":"permission.asked",\n',
                b'data: "properties":{"sessionID":"ses_123","content":"private"}}\n\n',
                b"data: " + b"x" * 65537 + b"\n\n",
                b'data: {"type":"unknown","properties":{"sessionID":"ses_123"}}\n\n',
                b'data: {"type":"session.idle","properties":{"sessionID":"ses_123"}}\n\n',
            ])
            class Feed(io.BytesIO):
                def readline(self, limit):
                    result = super().readline(limit)
                    if not result:
                        running[0] = False
                    return result
            def open_feed(request, timeout):
                self.assertEqual(request.full_url, "http://127.0.0.1:1234/event")
                expected = "Basic " + base64.b64encode(("opencode:" + "e" * 32).encode()).decode()
                self.assertEqual(request.get_header("Authorization"), expected)
                self.assertLessEqual(timeout, 2)
                return Feed(payload)
            event_helper.stream_opencode(
                "http://127.0.0.1:1234/event", str(path), "e" * 32,
                opener=open_feed, alive=lambda: running[0], now=lambda: 124,
            )
            events = [json.loads(line) for line in path.read_bytes().splitlines()]
            self.assertEqual([event["state"] for event in events], ["approval", "completed"])
            self.assertNotIn(b"private", path.read_bytes())

    def test_opencode_reconnect_backoff_stops_when_parent_exits(self):
        attempts = []
        delays = []
        def unavailable(request, timeout):
            attempts.append(request.full_url)
            raise urllib.error.URLError("unavailable")
        event_helper.stream_opencode(
            "http://127.0.0.1:1234/event", "/unused/events", "e" * 32,
            opener=unavailable, alive=lambda: len(attempts) < 6, sleep=delays.append,
        )
        self.assertEqual(delays, [.1, .25, .5, 1, 2])
        self.assertEqual(len(attempts), 6)

    def test_opencode_stream_refuses_non_loopback_or_ambiguous_urls_and_invalid_password(self):
        for url in [
            "https://127.0.0.1:1234/event", "http://localhost:1234/event",
            "http://127.0.0.2:1234/event", "http://127.0.0.1:0/event",
            "http://127.0.0.1:65536/event", "http://127.0.0.1:01234/event",
            "http://127.0.0.1:1234/event?secret=x", "http://user@127.0.0.1:1234/event",
            "http://127.0.0.1:1234/event#x", "http://127.0.0.1:1234/event\n",
        ]:
            with self.subTest(url=url):
                with self.assertRaises(ValueError):
                    event_helper.stream_opencode(url, "/unused", "e" * 32, alive=lambda: False)
        for password in (None, "", "E" * 32, "e" * 33, "secret\n"):
            with self.assertRaises(ValueError):
                event_helper.stream_opencode("http://127.0.0.1:1234/event", "/unused", password, alive=lambda: False)


if __name__ == "__main__":
    unittest.main()
