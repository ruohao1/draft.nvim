#!/usr/bin/env python3
"""One-operation client for the owning Neovim's private scope broker."""

import argparse
import errno
import json
import math
import os
import socket
import sys
import time


def _text(value, limit, absolute=False):
    if not isinstance(value, str) or not value.strip():
        raise RuntimeError("invalid scope request or response text")
    try:
        encoded = value.encode("utf-8")
    except UnicodeError:
        raise RuntimeError("invalid scope request or response text") from None
    if (len(encoded) > limit or any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in value)
            or (absolute and not value.startswith("/"))):
        raise RuntimeError("invalid scope request or response text")
    return value


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result


def request_scope(socket_path, token, path, reason, timeout=30.0):
    _text(socket_path, 4096, absolute=True)
    _text(path, 4096, absolute=True)
    _text(reason, 512)
    if not isinstance(token, str) or len(token) != 32 or any(c not in "0123456789abcdef" for c in token):
        raise RuntimeError("invalid scope control token")
    if type(timeout) not in (int, float) or not math.isfinite(timeout) or not 0 < timeout <= 30:
        raise RuntimeError("invalid scope timeout")
    request = {
        "schema": 1, "operation": "request_scope", "token": token,
        "path": path, "reason": reason,
    }
    payload = (json.dumps(request, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()
    if len(payload) > 8192:
        raise RuntimeError("invalid scope request: request limit exceeded")
    deadline = time.monotonic() + timeout
    data = b""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(timeout)
            connection.connect(socket_path)
            connection.sendall(payload)
            connection.shutdown(socket.SHUT_WR)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError()
                connection.settimeout(remaining)
                chunk = connection.recv(4097 - len(data))
                if not chunk:
                    break
                data += chunk
                if len(data) > 4096:
                    raise RuntimeError("scope response limit exceeded")
    except TimeoutError:
        raise RuntimeError("scope request timed out; no approval was confirmed") from None
    except OSError as error:
        if error.errno in (errno.ENOENT, errno.ECONNREFUSED):
            raise RuntimeError(
                "reopen the owning Neovim instance and retry the scope request"
            ) from None
        raise RuntimeError("scope connection failed; no approval was confirmed") from None
    try:
        if not data.endswith(b"\n") or data.count(b"\n") != 1:
            raise ValueError()
        response = json.loads(data.decode("utf-8"), object_pairs_hook=_unique_object)
        if (not isinstance(response, dict) or set(response) != {"schema", "ok", "code", "message"}
                or type(response["schema"]) is not int or response["schema"] != 1
                or type(response["ok"]) is not bool):
            raise ValueError()
        code = _text(response["code"], 64)
        if any(c not in "abcdefghijklmnopqrstuvwxyz_" for c in code):
            raise ValueError()
        _text(response["message"], 512)
    except (ValueError, UnicodeError, RuntimeError):
        raise RuntimeError("invalid scope response") from None
    return response


def main(argv=None):
    parser = argparse.ArgumentParser(prog="nvim-ai-control.py")
    subcommands = parser.add_subparsers(dest="operation", required=True)
    request = subcommands.add_parser("request-scope")
    request.add_argument("--path", required=True)
    request.add_argument("--reason", required=True)
    arguments = parser.parse_args(argv)
    try:
        response = request_scope(
            os.environ.get("NVIM_AI_CONTROL_SOCKET"),
            os.environ.get("NVIM_AI_CONTROL_TOKEN"),
            arguments.path, arguments.reason,
        )
    except RuntimeError as error:
        print(str(error), file=sys.stderr)
        return 1
    print(response["message"])
    return 0 if response["ok"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
