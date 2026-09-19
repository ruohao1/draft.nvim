#!/usr/bin/env python3
"""Hash-checked, descriptor-relative review mutations. Never invokes Git."""
import argparse
import hashlib
import json
import os
import stat
import sys


MAX_OBJECT_BYTES = 64 * 1024 * 1024
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK


def _hex(value, length=None):
    return isinstance(value, str) and bool(value) and len(value) % 2 == 0 and all(byte in "0123456789abcdef" for byte in value) and (length is None or len(value) == length)


def _keys(value, expected):
    return isinstance(value, dict) and set(value) == set(expected)


def _relative(path):
    if not isinstance(path, bytes) or not path or len(path) > 4096 or b"\0" in path or any(part in (b"", b".", b"..") for part in path.split(b"/")):
        raise ValueError("invalid relative review path")
    return path.split(b"/")


def _absolute(path):
    if not isinstance(path, str) or not path.startswith("/") or "\0" in path or os.path.normpath(path) != path:
        raise ValueError("invalid absolute review path")
    return os.fsencode(path)


def _object(value, desired=False):
    if not _keys(value, {"kind", "mode", "size", "sha256"} | ({"source"} if desired else set())):
        raise ValueError("invalid review object keys")
    if value["kind"] not in ("regular", "symlink", "absent") or type(value["size"]) is not int or not 0 <= value["size"] <= MAX_OBJECT_BYTES:
        raise ValueError("invalid review object")
    if value["kind"] == "absent":
        if value["mode"] is not None or value["size"] != 0 or value["sha256"] is not None or (desired and value["source"] is not None):
            raise ValueError("invalid absent review object")
    else:
        modes = ("100644", "100755") if value["kind"] == "regular" else ("120000",)
        if value["mode"] not in modes or not _hex(value["sha256"], 64):
            raise ValueError("invalid review fingerprint")
        if desired:
            _absolute(value["source"])


def validate_action(action):
    if not _keys(action, {"schema", "root", "path_hex", "expected", "desired"}) or type(action["schema"]) is not int or action["schema"] != 1:
        raise ValueError("invalid review action keys or schema")
    root = _absolute(action["root"])
    if root == b"/" or os.path.realpath(root) != root:
        raise ValueError("review root must be canonical and bounded")
    if not _hex(action["path_hex"]):
        raise ValueError("invalid review path hex")
    _relative(bytes.fromhex(action["path_hex"]))
    _object(action["expected"])
    _object(action["desired"], desired=True)
    return action


def _identity(node):
    return node.st_dev, node.st_ino, node.st_mode, node.st_uid


def _snapshot(node):
    return _identity(node), node.st_size, node.st_mtime_ns, node.st_ctime_ns, node.st_nlink


def _same_inode(left, right):
    return (left.st_dev, left.st_ino, stat.S_IFMT(left.st_mode)) == (right.st_dev, right.st_ino, stat.S_IFMT(right.st_mode))


class _Parent:
    def __init__(self, root, path):
        self.root = root
        self.parts = _relative(path)
        self.name = self.parts[-1]
        self.fds = []
        try:
            self.fds.append(os.open(root, DIRECTORY_FLAGS))
            for part in self.parts[:-1]:
                node = os.stat(part, dir_fd=self.fds[-1], follow_symlinks=False)
                if stat.S_ISLNK(node.st_mode):
                    raise ValueError("review parent is a symlink")
                self.fds.append(os.open(part, DIRECTORY_FLAGS, dir_fd=self.fds[-1]))
            self.identities = [_identity(os.fstat(fd)) for fd in self.fds]
            self.fd = self.fds[-1]
            self.verify()
        except BaseException:
            self.close()
            raise

    def verify(self):
        try:
            if os.path.realpath(self.root) != self.root or _identity(os.stat(self.root, follow_symlinks=False)) != self.identities[0]:
                raise ValueError("review root changed during action")
            for index, fd in enumerate(self.fds):
                if _identity(os.fstat(fd)) != self.identities[index]:
                    raise ValueError("review parent descriptor changed")
                if index and _identity(os.stat(self.parts[index - 1], dir_fd=self.fds[index - 1], follow_symlinks=False)) != self.identities[index]:
                    raise ValueError("review parent changed during action")
        except OSError as exc:
            raise ValueError("review parent changed during action") from exc

    def close(self):
        failure = None
        while self.fds:
            try:
                os.close(self.fds.pop())
            except OSError as exc:
                failure = failure or exc
        if failure:
            raise failure

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def open_parent(root, path):
    return _Parent(os.fsencode(root), path)


def _read_fd(fd, before, maximum):
    if not stat.S_ISREG(before.st_mode) or before.st_size > maximum:
        raise ValueError("review source is not a bounded regular file")
    chunks, remaining = [], before.st_size
    while remaining:
        chunk = os.read(fd, min(1024 * 1024, remaining))
        if not chunk:
            raise ValueError("review source changed while reading")
        chunks.append(chunk)
        remaining -= len(chunk)
    if os.read(fd, 1) or _snapshot(before) != _snapshot(os.fstat(fd)):
        raise ValueError("review source changed while reading")
    return b"".join(chunks)


def fingerprint_at(parent_fd, name):
    try:
        before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return {"kind": "absent", "mode": None, "size": 0, "sha256": None}
    if stat.S_ISREG(before.st_mode):
        fd = os.open(name, READ_FLAGS, dir_fd=parent_fd)
        try:
            if _snapshot(before) != _snapshot(os.fstat(fd)):
                raise ValueError("review destination changed before reading")
            value = _read_fd(fd, before, MAX_OBJECT_BYTES)
        finally:
            os.close(fd)
        kind, mode = "regular", "100755" if before.st_mode & 0o111 else "100644"
    elif stat.S_ISLNK(before.st_mode):
        value = os.fsencode(os.readlink(name, dir_fd=parent_fd))
        kind, mode = "symlink", "120000"
    else:
        raise ValueError("unsupported review destination kind")
    if _snapshot(before) != _snapshot(os.stat(name, dir_fd=parent_fd, follow_symlinks=False)):
        raise ValueError("review destination changed while reading")
    return {"kind": kind, "mode": mode, "size": len(value), "sha256": hashlib.sha256(value).hexdigest()}


def _private_bytes(path, maximum):
    raw = _absolute(path)
    with open_parent(b"/", raw[1:]) as parent:
        before = os.stat(parent.name, dir_fd=parent.fd, follow_symlinks=False)
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or stat.S_IMODE(before.st_mode) != 0o600 or before.st_nlink != 1:
            raise ValueError("private review source has unsafe ownership, mode, or kind")
        fd = os.open(parent.name, READ_FLAGS, dir_fd=parent.fd)
        try:
            if _snapshot(before) != _snapshot(os.fstat(fd)):
                raise ValueError("private review source changed")
            value = _read_fd(fd, before, maximum)
        finally:
            os.close(fd)
        parent.verify()
        if _snapshot(before) != _snapshot(os.stat(parent.name, dir_fd=parent.fd, follow_symlinks=False)):
            raise ValueError("private review source changed")
        return value


def apply_action(action):
    validate_action(action)
    expected, desired = action["expected"], action["desired"]
    with open_parent(action["root"], bytes.fromhex(action["path_hex"])) as parent:
        if fingerprint_at(parent.fd, parent.name) != expected:
            raise ValueError("expected fingerprint mismatch")
        if desired["kind"] == "absent":
            parent.verify()
            if fingerprint_at(parent.fd, parent.name) != expected:
                raise ValueError("expected fingerprint changed before unlink")
            parent.verify()
            if expected["kind"] != "absent":
                os.unlink(parent.name, dir_fd=parent.fd)
            os.fsync(parent.fd)
            parent.verify()
            result = fingerprint_at(parent.fd, parent.name)
            if result["kind"] != "absent":
                raise ValueError("review post-write fingerprint mismatch")
            return result
        value = _private_bytes(desired["source"], MAX_OBJECT_BYTES)
        if len(value) != desired["size"] or hashlib.sha256(value).hexdigest() != desired["sha256"]:
            raise ValueError("desired source fingerprint mismatch")
        if desired["kind"] == "symlink" and b"\0" in value:
            raise ValueError("desired symlink target contains NUL")
        temporary = os.urandom(16).hex().encode("ascii")
        owned = False
        owned_node = None
        try:
            if desired["kind"] == "symlink":
                os.symlink(value, temporary, dir_fd=parent.fd)
                owned = True
                owned_node = os.stat(temporary, dir_fd=parent.fd, follow_symlinks=False)
            else:
                fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=parent.fd)
                owned = True
                try:
                    owned_node = os.fstat(fd)
                    cursor = 0
                    while cursor < len(value):
                        wrote = os.write(fd, value[cursor:])
                        if type(wrote) is not int or not 0 < wrote <= len(value) - cursor:
                            raise OSError("review temporary write failed")
                        cursor += wrote
                    os.fchmod(fd, 0o755 if desired["mode"] == "100755" else 0o644)
                    os.fsync(fd)
                finally:
                    os.close(fd)
            parent.verify()
            desired_fingerprint = {key: desired[key] for key in ("kind", "mode", "size", "sha256")}
            if not _same_inode(owned_node, os.stat(temporary, dir_fd=parent.fd, follow_symlinks=False)) or fingerprint_at(parent.fd, temporary) != desired_fingerprint:
                raise ValueError("review temporary changed before publication")
            if fingerprint_at(parent.fd, parent.name) != expected:
                raise ValueError("expected fingerprint changed before publication")
            parent.verify()
            os.rename(temporary, parent.name, src_dir_fd=parent.fd, dst_dir_fd=parent.fd)
            owned = False
            os.fsync(parent.fd)
            parent.verify()
            result = fingerprint_at(parent.fd, parent.name)
            if result != desired_fingerprint:
                raise ValueError("review post-write fingerprint mismatch")
            return result
        finally:
            if owned:
                try:
                    current_temporary = os.stat(temporary, dir_fd=parent.fd, follow_symlinks=False)
                except FileNotFoundError:
                    current_temporary = None
                if owned_node is not None and current_temporary is not None and _same_inode(owned_node, current_temporary):
                    os.unlink(temporary, dir_fd=parent.fd)


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate review manifest key")
        result[key] = value
    return result


def _invalid_constant(_):
    raise ValueError("invalid review manifest number")


def read_manifest(path):
    value = _private_bytes(path, 1024 * 1024)
    action = json.loads(value.decode("utf-8"), object_pairs_hook=_unique_object, parse_constant=_invalid_constant)
    return validate_action(action)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Apply one confined exact-hash review decision")
    parser.add_argument("--manifest", required=True)
    args = parser.parse_args(argv)
    try:
        result = apply_action(read_manifest(args.manifest))
    except (OSError, ValueError, UnicodeError):
        # Never echo source bytes, path bytes, or a decoded manifest to diagnostics.
        sys.stderr.write("review mutation failed\n")
        return 1
    sys.stdout.write(json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    # In addition to the runner's closed-fd spawn, retain only the JSON protocol.
    os.closerange(3, max(3, os.sysconf("SC_OPEN_MAX")))
    os.environ.clear()
    sys.exit(main())
