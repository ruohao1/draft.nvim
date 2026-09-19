"""Private, editor-lifetime OpenCode store ownership; never read database bytes.

Only this instance's freshly created root can be owned. There is no adoption,
SQL, checkpointing, repair, approval or automatic recovery interface.
"""
from contextlib import ExitStack
import importlib.util
import os
from pathlib import Path
import secrets
import stat


HERE = Path(__file__).resolve().parent


def _helper(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


review = _helper("nvim-ai-review")
acp = _helper("nvim-ai-acp-worker")
ProtocolError = acp.ProtocolError
ARTIFACTS = frozenset({"opencode.db", "opencode.db-wal", "opencode.db-shm"})
MAX_BYTES = 64 * 1024 * 1024


class Refused(RuntimeError):
    """Trusted diagnostic; no backend filenames, data or underlying OS errors."""


def _identity(node):
    return node.st_dev, node.st_ino, node.st_mode, node.st_uid, node.st_gid


def _snapshot(node):
    return _identity(node), node.st_size, node.st_mtime_ns, node.st_ctime_ns, node.st_nlink


def _names(fd, allowed):
    names = set()
    with os.scandir(fd) as entries:
        for entry in entries:
            if entry.name not in allowed or entry.name in names:
                raise Refused("Unexpected retained-store entry")
            names.add(entry.name)
    return names


class Store:
    def __init__(self, parent="/tmp"):
        if not hasattr(os, "O_PATH"):
            raise Refused("Retained store requires Linux metadata descriptors")
        parent = os.fspath(parent)
        if (not isinstance(parent, str) or not parent.startswith("/") or parent == "/"
                or os.path.normpath(parent) != parent or os.path.realpath(parent) != parent
                or len(os.fsencode(parent)) > 4000 or any(ord(char) < 32 for char in parent)):
            raise Refused("Store parent must be a canonical bounded directory")
        self._root_path = Path(parent) / ("nvim-ai-conversation-" + secrets.token_hex(16))
        self._closed, self._failed = False, None
        self._worker, self._sealed = None, {}
        self._fds = ExitStack()
        try:
            self._parent = self._fds.enter_context(review.open_parent("/", os.fsencode(str(self.root)[1:])))
            self._parent.verify()
            os.mkdir(self._parent.name, 0o700, dir_fd=self._parent.fd)
            self._root = os.open(self._parent.name, review.DIRECTORY_FLAGS, dir_fd=self._parent.fd)
            self._fds.callback(os.close, self._root)
            os.mkdir("backend-store", 0o700, dir_fd=self._root)
            self._backend = os.open("backend-store", review.DIRECTORY_FLAGS, dir_fd=self._root)
            self._fds.callback(os.close, self._backend)
            self._root_identity = _identity(os.fstat(self._root))
            self._backend_identity = _identity(os.fstat(self._backend))
            self.check()
        except BaseException:
            self._fds.close()
            raise

    @property
    def root(self):
        return self._root_path

    @property
    def path(self):
        return self._root_path / "backend-store"

    def _verify(self):
        self._parent.verify()
        for fd, name, parent, expected in (
                (self._root, self._parent.name, self._parent.fd, self._root_identity),
                (self._backend, "backend-store", self._root, self._backend_identity)):
            node = os.fstat(fd)
            if (not stat.S_ISDIR(node.st_mode) or node.st_uid != os.getuid()
                    or stat.S_IMODE(node.st_mode) != 0o700 or _identity(node) != expected
                    or _identity(os.stat(name, dir_fd=parent, follow_symlinks=False)) != expected):
                raise Refused("Retained-store directory identity or permissions changed")
        if _names(self._root, {"backend-store"}) != {"backend-store"}:
            raise Refused("Retained-store directory missing")

    def _inventory(self, *, stable=True, budget=True):
        self._verify()
        names = _names(self._backend, ARTIFACTS)
        values, total = {}, 0
        with ExitStack() as opened:
            for name in names:
                try:
                    before = os.stat(name, dir_fd=self._backend, follow_symlinks=False)
                    # Linux O_PATH obtains metadata only: no database bytes,
                    # FIFO reads, SQLite locks, checkpoints or SQL on the host.
                    fd = os.open(name, os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=self._backend)
                except FileNotFoundError:
                    if not stable:  # A live SQLite worker may retire a sidecar.
                        continue
                    raise
                opened.callback(os.close, fd)
                node = os.fstat(fd)
                if (not stat.S_ISREG(node.st_mode) or node.st_uid != os.getuid()
                        or stat.S_IMODE(node.st_mode) != 0o600 or node.st_nlink != 1
                        or _identity(node) != _identity(before)
                        or (stable and _snapshot(node) != _snapshot(before))):
                    raise Refused("Unsafe retained-store artifact metadata")
                values[name] = (_snapshot(node), fd)
                total += node.st_size
            if budget and total > MAX_BYTES:
                raise Refused("Retained-store size budget exceeded")
            if stable:
                if _names(self._backend, ARTIFACTS) != names:
                    raise Refused("Retained-store entries changed during validation")
                for name, (expected, fd) in values.items():
                    if (expected != _snapshot(os.fstat(fd)) or expected != _snapshot(
                            os.stat(name, dir_fd=self._backend, follow_symlinks=False))):
                        raise Refused("Retained-store artifact changed during validation")
            self._verify()
            return {name: expected for name, (expected, _) in values.items()}

    def check(self):
        """Validate metadata, plus the stopped-state seal when no worker is live."""
        if self._closed:
            raise Refused("Retained store is closed")
        if self._failed:
            raise Refused(self._failed)
        try:
            values = self._inventory(stable=self._worker is None)
            if self._worker is None and values != self._sealed:
                raise Refused("Retained store changed while no worker was active")
            return {name: metadata[1] for name, metadata in values.items()}
        except (OSError, ValueError, Refused) as error:
            self._failed = self._failed or (str(error) if isinstance(error, Refused)
                                           else "Retained-store validation failed")
            raise Refused(self._failed) from None

    def start(self, command, *, env, **worker_options):
        """Launch one trusted staging.sandbox command with the dedicated store.

        No shell or untrusted argv is accepted by the future controller. The
        returned ACP worker is owned here until stop() validates its exit.
        """
        if self._closed or self._failed or self._worker is not None:
            raise Refused(self._failed or "Retained store is closed or already in use")
        if "guard" in worker_options:
            raise Refused("Retained store owns the worker state guard")
        self.check()
        command = list(command)
        separator = command.index("--")
        command[separator:separator] = ["--bind", str(self.path), "/tmp/backend-state"]
        env = dict(env, OPENCODE_DB="/tmp/backend-state/opencode.db")
        self._worker = acp.Worker(command, env=env, guard=self.check, **worker_options)
        return self._worker

    def stop(self, *, outcome):
        """Reap before sealing. Outcome is trusted controller policy, not ACP text.

        completed/cancelled require a separately validated semantic outcome.
        Failed/forced/unknown results taint continuation. This never freezes or
        approves changes; clean cancellation still discards mutable proposals.
        """
        if self._worker is None:
            raise Refused("No retained-store worker is active")
        result = self._worker.close()
        if not result.reaped or not result.output_closed:
            self._failed = "Worker exit unproven; retain mounted state for explicit recovery"
            raise Refused(self._failed)
        self._worker = None
        try:
            if self._failed or not result.settled or outcome not in ("completed", "cancelled"):
                raise Refused(self._failed or "Worker outcome cannot authorize retained-state reuse")
            values = self._inventory()
            if "opencode.db" not in values or values["opencode.db"][1] == 0:
                raise Refused("Retained database artifact missing or empty")
            self._sealed = values
            return result
        except (OSError, ValueError, Refused) as error:
            self._failed = str(error) if isinstance(error, Refused) else "Retained-store validation failed"
            raise Refused(self._failed) from None

    def close(self):
        """Explicitly discard proven-owned artifacts after exit; never recurse.

        A tainted but stopped store can be discarded if structural checks pass.
        Unsafe entries or cleanup errors remain visible for explicit recovery.
        """
        if self._closed:
            return
        if self._worker is not None:
            raise Refused("Cannot remove retained state before worker exit is proven")
        try:
            values = self._inventory(budget=False)
            for name, expected in values.items():
                self._verify()
                if _snapshot(os.stat(name, dir_fd=self._backend, follow_symlinks=False)) != expected:
                    raise Refused("Retained-store artifact changed during cleanup")
                os.unlink(name, dir_fd=self._backend)
            os.fsync(self._backend)
            self._verify()
            os.rmdir("backend-store", dir_fd=self._root)
            self._parent.verify()
            if _identity(os.stat(self._parent.name, dir_fd=self._parent.fd,
                                 follow_symlinks=False)) != self._root_identity:
                raise Refused("Retained-store root changed during cleanup")
            os.rmdir(self._parent.name, dir_fd=self._parent.fd)
            os.fsync(self._parent.fd)
            self._fds.close()
            self._closed = True
        except (OSError, ValueError, Refused):
            self._failed = "Retained-store cleanup incomplete; explicit recovery required"
            raise Refused(self._failed) from None
