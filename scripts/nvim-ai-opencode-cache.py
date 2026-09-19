#!/usr/bin/env python3
"""Bounded, private compatibility receipts. No OpenCode, login, or network calls."""
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import time


spec = importlib.util.spec_from_file_location("review", Path(__file__).with_name("nvim-ai-review.py"))
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)

MAX_BYTES = 65536
TTL = 24 * 60 * 60
NAME = b"compatibility.json"


def decode(raw):
    return json.loads(raw, object_pairs_hook=review._unique_object,
                      parse_constant=review._invalid_constant)


def directory_node(node, private=False):
    mode = stat.S_IMODE(node.st_mode)
    if private:
        safe = node.st_uid == os.getuid() and mode == 0o700
    else:
        # A root-owned sticky /tmp is safe as an ancestor, never as the cache.
        # Ancestors can belong to a mapped filesystem owner (e.g. /home).
        # The receipt and leaf must still be private and owned by this UID.
        safe = not mode & 0o022 or (node.st_uid == 0 and mode & stat.S_ISVTX)
    if not stat.S_ISDIR(node.st_mode) or not safe:
        raise ValueError("unsafe cache directory")


def private_node(node):
    if (not stat.S_ISREG(node.st_mode) or node.st_uid != os.getuid()
            or stat.S_IMODE(node.st_mode) != 0o600 or node.st_nlink != 1):
        raise ValueError("unsafe cache file")


def open_cache(directory, create=False):
    raw = review._absolute(directory)
    if raw == b"/" or len(raw) > 4096:
        raise ValueError("invalid cache directory")
    if create:
        # Create each missing component relative to a checked, held descriptor.
        fd = os.open(b"/", review.DIRECTORY_FLAGS)
        try:
            parts = review._relative(raw[1:])
            directory_node(os.fstat(fd))
            for index, part in enumerate(parts):
                try:
                    os.mkdir(part, mode=0o700, dir_fd=fd)
                except FileExistsError:
                    pass
                child = os.open(part, review.DIRECTORY_FLAGS, dir_fd=fd)
                os.close(fd)
                fd = child
                directory_node(os.fstat(fd), private=index == len(parts) - 1)
        finally:
            os.close(fd)
    parent = review.open_parent(b"/", raw[1:] + b"/" + NAME)
    try:
        for index, fd in enumerate(parent.fds):
            directory_node(os.fstat(fd), private=index == len(parent.fds) - 1)
        parent.verify()
        return parent
    except BaseException:
        parent.close()
        raise


def read_record(parent):
    before = os.stat(NAME, dir_fd=parent.fd, follow_symlinks=False)
    private_node(before)
    fd = os.open(NAME, review.READ_FLAGS, dir_fd=parent.fd)
    try:
        if review._snapshot(before) != review._snapshot(os.fstat(fd)):
            raise ValueError("cache changed before read")
        raw = review._read_fd(fd, before, MAX_BYTES)
    finally:
        os.close(fd)
    parent.verify()
    if review._snapshot(before) != review._snapshot(os.stat(NAME, dir_fd=parent.fd, follow_symlinks=False)):
        raise ValueError("cache changed during read")
    return decode(raw)


def lookup(directory, key):
    with open_cache(directory) as parent:
        record = read_record(parent)
    now = int(time.time())
    if (not review._keys(record, {"schema", "key", "created_at", "expires_at", "report"})
            or type(record["schema"]) is not int or record["schema"] != 1
            or record["key"] != key or type(record["created_at"]) is not int
            or type(record["expires_at"]) is not int
            or not 0 < record["created_at"] <= now < record["expires_at"]
            or record["expires_at"] != record["created_at"] + TTL
            or not isinstance(record["report"], dict)):
        return {"hit": False}
    return {"hit": True, "report": record["report"]}


def store(directory, key, report):
    if not isinstance(report, dict):
        raise ValueError("invalid compatibility report")
    now = int(time.time())
    raw = json.dumps({"schema": 1, "key": key, "created_at": now,
                      "expires_at": now + TTL, "report": report},
                     allow_nan=False, separators=(",", ":")).encode("utf-8")
    if len(raw) > MAX_BYTES:
        raise ValueError("oversize compatibility report")
    with open_cache(directory, create=True) as parent:
        temporary = (".receipt-" + os.urandom(16).hex()).encode("ascii")
        owned = False
        try:
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                         0o600, dir_fd=parent.fd)
            owned = True
            try:
                os.fchmod(fd, 0o600)
                with os.fdopen(fd, "wb", closefd=False) as stream:
                    stream.write(raw)
                    stream.flush()
                os.fsync(fd)
            finally:
                os.close(fd)
            parent.verify()
            try:
                private_node(os.stat(NAME, dir_fd=parent.fd, follow_symlinks=False))
            except FileNotFoundError:
                pass
            os.replace(temporary, NAME, src_dir_fd=parent.fd, dst_dir_fd=parent.fd)
            owned = False
            os.fsync(parent.fd)
            parent.verify()
            private_node(os.stat(NAME, dir_fd=parent.fd, follow_symlinks=False))
        finally:
            if owned:
                os.unlink(temporary, dir_fd=parent.fd)
    return {"stored": True}


def main():
    operation = sys.argv[1] if len(sys.argv) == 2 else ""
    answer = {"hit": False} if operation == "lookup" else {"stored": False}
    try:
        raw = sys.stdin.buffer.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES or operation not in ("lookup", "store"):
            raise ValueError("invalid cache request")
        request = decode(raw)
        keys = {"directory", "key"} | ({"report"} if operation == "store" else set())
        if not review._keys(request, keys) or not review._hex(request["key"], 64):
            raise ValueError("invalid cache request")
        if operation == "lookup":
            answer = lookup(request["directory"], request["key"])
        else:
            answer = store(request["directory"], request["key"], request["report"])
    except (OSError, ValueError, TypeError, UnicodeError, RecursionError):
        pass  # The caller always treats an unusable receipt as a cache miss.
    sys.stdout.write(json.dumps(answer, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    os.environ.clear()
    main()
