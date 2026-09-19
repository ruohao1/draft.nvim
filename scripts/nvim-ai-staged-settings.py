#!/usr/bin/env python3
"""Private staging preferences only: never read credentials or invoke a provider."""
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import sys

spec = importlib.util.spec_from_file_location("review", Path(__file__).with_name("nvim-ai-review.py"))
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)
NAME = b"settings.json"
MAX_BYTES = 16384
DISABLED = {"schema": 1, "enabled": False}


def decode(raw):
    return json.loads(raw, object_pairs_hook=review._unique_object,
                      parse_constant=review._invalid_constant)


def preferences(value, check_auth=False):
    if (not isinstance(value, dict) or type(value.get("schema")) is not int
            or value["schema"] != 1 or type(value.get("enabled")) is not bool):
        raise ValueError("invalid preferences")
    optional_mode = {"review_mode"} if "review_mode" in value else set()
    if optional_mode and value["review_mode"] not in ("native", "pre_write"):
        raise ValueError("invalid review mode")
    if not value["enabled"]:
        if set(value) != {"schema", "enabled"} | optional_mode:
            raise ValueError("invalid disabled preferences")
        return value
    fields = {"schema", "enabled", "model"} | optional_mode
    if set(value) not in (fields, fields | {"auth_file"}):
        raise ValueError("unexpected preference fields")
    model = value["model"]
    if (not isinstance(model, str) or len(model.encode()) > 512
            or not re.fullmatch(r"[a-zA-Z0-9_.-]+/[^\s\x00-\x1f\x7f]+", model)):
        raise ValueError("invalid model")
    if "auth_file" in value:
        path = value["auth_file"]
        raw = review._absolute(path)
        review._relative(raw[1:])
        if any(ord(c) < 32 or ord(c) == 127 for c in path):
            raise ValueError("invalid authentication path")
        if check_auth:
            # Metadata only. Credential validation/copying belongs to the turn.
            with review.open_parent(b"/", raw[1:]) as parent:
                private_file(os.stat(parent.name, dir_fd=parent.fd, follow_symlinks=False))
                parent.verify()
    return value


def private_file(node):
    if (not stat.S_ISREG(node.st_mode) or node.st_uid != os.getuid()
            or stat.S_IMODE(node.st_mode) != 0o600 or node.st_nlink != 1):
        raise ValueError("unsafe private file")


def directory_node(node, leaf=False):
    mode = stat.S_IMODE(node.st_mode)
    safe = (node.st_uid == os.getuid() and mode == 0o700) if leaf else (
        not mode & 0o022 or (node.st_uid == 0 and mode & stat.S_ISVTX))
    if not stat.S_ISDIR(node.st_mode) or not safe:
        raise ValueError("unsafe preferences directory")


def open_directory(directory, create=False):
    raw = review._absolute(directory)
    parts = review._relative(raw[1:])
    if create:
        fd = os.open(b"/", review.DIRECTORY_FLAGS)
        try:
            directory_node(os.fstat(fd))
            for index, part in enumerate(parts):
                try:
                    os.mkdir(part, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
                child = os.open(part, review.DIRECTORY_FLAGS, dir_fd=fd)
                os.close(fd)
                fd = child
                directory_node(os.fstat(fd), leaf=index == len(parts) - 1)
        finally:
            os.close(fd)
    parent = review.open_parent(b"/", raw[1:] + b"/" + NAME)
    try:
        for index, fd in enumerate(parent.fds):
            directory_node(os.fstat(fd), leaf=index == len(parent.fds) - 1)
        parent.verify()
        return parent
    except BaseException:
        parent.close()
        raise


def load(directory):
    try:
        with open_directory(directory) as parent:
            before = os.stat(NAME, dir_fd=parent.fd, follow_symlinks=False)
            private_file(before)
            fd = os.open(NAME, review.READ_FLAGS, dir_fd=parent.fd)
            try:
                if review._snapshot(before) != review._snapshot(os.fstat(fd)):
                    raise ValueError("preferences changed before read")
                raw = review._read_fd(fd, before, MAX_BYTES)
            finally:
                os.close(fd)
            parent.verify()
            if review._snapshot(before) != review._snapshot(os.stat(NAME, dir_fd=parent.fd, follow_symlinks=False)):
                raise ValueError("preferences changed during read")
            return preferences(decode(raw))
    except FileNotFoundError:
        return DISABLED


def save(directory, value):
    raw = json.dumps(preferences(value, check_auth=True), ensure_ascii=True).encode()
    if len(raw) > MAX_BYTES:
        raise ValueError("oversize preferences")
    with open_directory(directory, create=True) as parent:
        temporary = (".settings-" + os.urandom(16).hex()).encode()
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
                private_file(os.stat(NAME, dir_fd=parent.fd, follow_symlinks=False))
            except FileNotFoundError:
                pass
            os.replace(temporary, NAME, src_dir_fd=parent.fd, dst_dir_fd=parent.fd)
            owned = False
            os.fsync(parent.fd)
            parent.verify()
            private_file(os.stat(NAME, dir_fd=parent.fd, follow_symlinks=False))
        finally:
            if owned:
                os.unlink(temporary, dir_fd=parent.fd)


def main():
    answer = {"ok": False}
    try:
        operation = sys.argv[1] if len(sys.argv) == 2 else ""
        raw = sys.stdin.buffer.read(MAX_BYTES + 1)
        if len(raw) > MAX_BYTES or operation not in ("load", "save"):
            raise ValueError("invalid operation")
        request = decode(raw)
        if not review._keys(request, {"directory"} | ({"settings"} if operation == "save" else set())):
            raise ValueError("invalid request")
        if operation == "save":
            save(request["directory"], request["settings"])
            value = request["settings"]
        else:
            value = load(request["directory"])
        answer = {"ok": True, "settings": value}
    except (OSError, ValueError, TypeError, UnicodeError, RecursionError):
        pass  # Never echo paths, file contents, or values from malformed settings.
    print(json.dumps(answer, ensure_ascii=True))


if __name__ == "__main__":
    os.environ.clear()
    main()
