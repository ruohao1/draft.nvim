#!/usr/bin/env python3
"""Discard provider content and publish only bounded structured lifecycle states."""

import argparse
import base64
import fcntl
import http.client
import json
import math
import os
import re
import stat
import sys
import time
import urllib.error
import urllib.request

MAX_INPUT = 65536
MAX_FILE = 1024 * 1024
CLAUDE_STATES = {
    "SessionStart": "idle", "PostToolUse": "idle",
    "UserPromptSubmit": "busy", "PreToolUse": "busy",
    "PermissionRequest": "approval", "Stop": "completed", "SessionEnd": "completed",
}
OPENCODE_STATES = {
    "permission.asked": "approval", "session.idle": "completed", "session.error": "failed",
}


def _session(backend, value, state):
    if not isinstance(value, str):
        return False
    if backend == "claude":
        return re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", value) is not None
    if backend == "opencode":
        return (value == "" and state in ("open", "failed")) or re.fullmatch(r"ses_[A-Za-z0-9_-]{1,124}", value) is not None
    return backend == "codex" and value == "last" and state in ("open", "failed")


def _record(backend, session, state, now):
    if not state or not _session(backend, session, state):
        return None
    now = int(time.time()) if now is None else now
    if type(now) not in (int, float) or not math.isfinite(now) or not 0 <= now <= 9007199254740991:
        return None
    return {"schema": 1, "backend": backend, "session": session, "state": state, "time": now}


def normalize_claude(payload, now=None):
    if not isinstance(payload, dict) or not isinstance(payload.get("hook_event_name"), str):
        return None
    return _record("claude", payload.get("session_id"), CLAUDE_STATES.get(payload["hook_event_name"]), now)


def normalize_opencode(payload, now=None):
    if not isinstance(payload, dict) or not isinstance(payload.get("type"), str):
        return None
    properties = payload.get("properties")
    if not isinstance(properties, dict):
        return None
    state = OPENCODE_STATES.get(payload["type"])
    if payload["type"] == "session.status":
        status = properties.get("status")
        if isinstance(status, dict) and isinstance(status.get("type"), str):
            state = {"idle": "idle", "busy": "busy", "retry": "busy"}.get(status["type"])
    return _record("opencode", properties.get("sessionID"), state, now)


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate event key")
        result[key] = value
    return result


def _decode(payload):
    if len(payload) > MAX_INPUT:
        raise ValueError("event input limit exceeded")
    try:
        return json.loads(payload.decode("utf-8"), object_pairs_hook=_unique_object)
    except (UnicodeError, ValueError, RecursionError):
        raise ValueError("invalid event input") from None


def append_event(path, event):
    if (not isinstance(event, dict) or set(event) != {"schema", "backend", "session", "state", "time"}
            or type(event["schema"]) is not int or event["schema"] != 1
            or event["state"] not in ("open", "failed", "idle", "busy", "approval", "completed")
            or _record(event["backend"], event["session"], event["state"], event["time"]) != event):
        raise ValueError("invalid normalized event")
    if (not isinstance(path, str) or not path.startswith("/") or os.path.normpath(path) != path
            or len(path.encode("utf-8")) > 4096
            or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in path)):
        raise ValueError("invalid event path")
    parent, name = os.path.split(path)
    if os.path.realpath(parent) != parent:
        raise ValueError("event parent is a symlink")
    parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        metadata = os.fstat(parent_fd)
        if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
            raise ValueError("event parent is unsafe")
        descriptor = os.open(name, os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC,
                             0o600, dir_fd=parent_fd)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            metadata = os.fstat(descriptor)
            if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid()
                    or stat.S_IMODE(metadata.st_mode) != 0o600 or metadata.st_nlink != 1):
                raise ValueError("event file is unsafe")
            payload = (json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n").encode()
            if metadata.st_size + len(payload) > MAX_FILE:
                os.ftruncate(descriptor, 0)
            if os.write(descriptor, payload) != len(payload):
                raise ValueError("event append was incomplete")
            os.fsync(descriptor)
        finally:
            os.close(descriptor)  # Also releases the append lock.
    finally:
        os.close(parent_fd)
    return True


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        return None


def stream_opencode(event_url, event_file, password, parent_pid=None, *,
                    opener=None, alive=None, sleep=time.sleep, now=time.time):
    match = re.fullmatch(r"http://127\.0\.0\.1:([1-9][0-9]{0,4})/event", event_url or "")
    if not match or int(match.group(1)) > 65535:
        raise ValueError("invalid loopback event URL")
    if not isinstance(password, str) or re.fullmatch("[0-9a-f]{32}", password) is None:
        raise ValueError("invalid event stream password")
    parent_pid = os.getppid() if parent_pid is None else parent_pid
    if alive is None and (type(parent_pid) is not int or parent_pid <= 1):
        raise ValueError("invalid event stream parent")
    alive = alive or (lambda: os.getppid() == parent_pid)
    # Ignore proxy configuration and refuse redirects; credentials stay on this
    # one authenticated loopback endpoint, even if a server sends a redirect.
    opener = opener or urllib.request.build_opener(
        urllib.request.ProxyHandler({}), _NoRedirect()
    ).open
    authorization = "Basic " + base64.b64encode(("opencode:" + password).encode()).decode("ascii")
    request = urllib.request.Request(event_url, headers={
        "Authorization": authorization, "Accept": "text/event-stream",
    })
    delays = (.1, .25, .5, 1, 2)
    retry = 0
    while alive():
        try:
            with opener(request, timeout=1.0) as feed:
                data, size, discarded = [], 0, False
                while alive():
                    line = feed.readline(MAX_INPUT + 1)
                    if not line:
                        break
                    size += len(line)
                    if size > MAX_INPUT:
                        discarded = True
                        data = []
                    stripped = line.rstrip(b"\r\n")
                    if not stripped:
                        if data and not discarded:
                            try:
                                event = normalize_opencode(_decode(b"\n".join(data)), now=now())
                            except ValueError:
                                event = None
                            if event is not None:
                                try:
                                    append_event(event_file, event)
                                except OSError:
                                    raise ValueError("event file append failed") from None
                                retry = 0
                        data, size, discarded = [], 0, False
                    elif not discarded and line.startswith(b"data:"):
                        value = stripped[5:]
                        data.append(value[1:] if value.startswith(b" ") else value)
        except (OSError, urllib.error.URLError, http.client.HTTPException):
            pass
        if alive():
            sleep(delays[min(retry, len(delays) - 1)])
            retry += 1
    return True


def main(argv=None):
    parser = argparse.ArgumentParser(prog="nvim-ai-event.py")
    modes = parser.add_subparsers(dest="mode", required=True)
    hook = modes.add_parser("claude-hook")
    hook.add_argument("--event-file", required=True)
    stream = modes.add_parser("opencode-stream")
    stream.add_argument("--event-file", required=True)
    stream.add_argument("--event-url", required=True)
    stream.add_argument("--parent-pid", required=True, type=int)
    arguments = parser.parse_args(argv)
    try:
        if arguments.mode == "opencode-stream":
            stream_opencode(arguments.event_url, arguments.event_file,
                            os.environ.get("OPENCODE_SERVER_PASSWORD"), arguments.parent_pid)
        else:
            event = normalize_claude(_decode(sys.stdin.buffer.read(MAX_INPUT + 1)))
            if event is not None:
                append_event(arguments.event_file, event)
        return 0
    except (OSError, ValueError, TypeError):
        print("nvim-ai-event: event rejected", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
