"""Own a dedicated saved ChatGPT login without copying or restoring its tokens."""
import base64
import binascii
from contextlib import ExitStack
from datetime import datetime
import fcntl
import importlib.util
import os
from pathlib import Path
import re
import stat


def helper(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


review = helper("nvim-ai-review")
protocol = helper("nvim-ai-conversation-protocol")
MAX_BYTES = 1024 * 1024


class Refused(RuntimeError):
    """Only fixed reason codes cross the credential boundary."""


def _validate(raw):
    value = protocol.decode_json(raw)
    if not isinstance(value, dict) or value.keys() - {
            "auth_mode", "OPENAI_API_KEY", "tokens", "last_refresh"}:
        raise ValueError()
    mode, key, tokens = value.get("auth_mode"), value.get("OPENAI_API_KEY"), value.get("tokens")
    if mode not in (None, "apikey", "chatgpt"):
        raise ValueError()
    if key is not None:
        if not isinstance(key, str) or not key.strip() or tokens is not None or mode == "chatgpt":
            raise ValueError()
    else:
        if (mode == "apikey" or not isinstance(tokens, dict)
                or tokens.keys() - {"id_token", "access_token", "refresh_token", "account_id"}
                or any(not isinstance(tokens.get(k), str) or not tokens[k].strip()
                       for k in ("id_token", "access_token", "refresh_token"))
                or (tokens.get("account_id") is not None
                    and (not isinstance(tokens["account_id"], str) or not tokens["account_id"]))):
            raise ValueError()
        if re.fullmatch(r"[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+", tokens["id_token"]) is None:
            raise ValueError()
    if value.get("last_refresh") is not None:
        stamp = value["last_refresh"]
        if (not isinstance(stamp, str) or not stamp.endswith("Z")
                or datetime.fromisoformat(stamp).tzinfo is None):
            raise ValueError()

    return value


def validate(raw: bytes) -> dict:
    try:
        return _validate(raw)
    except (ValueError, TypeError, protocol.Refused):
        raise Refused("credentials") from None


def _identifier(value):
    if (not isinstance(value, str) or not value.strip()
            or len(value.encode("utf-8")) > 1024
            or any(ord(char) < 32 or 127 <= ord(char) <= 159 for char in value)):
        raise ValueError()
    return value


def chatgpt_owner(value: dict) -> tuple[str, str]:
    try:
        tokens = value["tokens"]
        parts = tokens["id_token"].split(".")
        if len(parts) != 3 or any(re.fullmatch(r"[A-Za-z0-9_-]+", part) is None for part in parts):
            raise ValueError()
        payload = parts[1]
        if len(payload) > MAX_BYTES:
            raise ValueError()
        claims = protocol.decode_json(base64.b64decode(
            payload + "=" * (-len(payload) % 4), altchars=b"-_", validate=True))
        claim = claims["https://api.openai.com/auth"]
        user = claim.get("chatgpt_user_id")
        if user is None:
            user = claim.get("user_id")
        # This is local identity continuity, not signature verification.
        return _identifier(user), _identifier(tokens["account_id"])
    except (KeyError, AttributeError, TypeError, ValueError, binascii.Error, protocol.Refused):
        raise Refused("auth_identity") from None


def _identity(node):
    return node.st_dev, node.st_ino, node.st_mode, node.st_uid, node.st_gid


def _private(node, *, directory=False):
    if (node.st_uid != os.getuid()
            or stat.S_IMODE(node.st_mode) != (0o700 if directory else 0o600)
            or (directory and not stat.S_ISDIR(node.st_mode))
            or (not directory and (not stat.S_ISREG(node.st_mode) or node.st_nlink != 1
                                   or node.st_size > MAX_BYTES))):
        raise ValueError()


class Lease:
    """The lock descriptor may be borrowed by Bubblewrap's PID 1 supervisor."""

    def __init__(self, directory: str, expected_owner: tuple[str, str] | None = None):
        self._fds = ExitStack()
        self.auth_fd = self.lock_fd = None
        self._closed = False
        try:
            if not protocol.path(directory, absolute=True):
                raise ValueError()
            self._parent = self._fds.enter_context(review.open_parent(
                "/", os.fsencode(directory[1:] + "/auth.json")))
            self._directory = _identity(os.fstat(self._parent.fd))
            _private(os.fstat(self._parent.fd), directory=True)
            self.lock_fd = os.open(".draft.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW
                                   | os.O_CLOEXEC | os.O_NONBLOCK, 0o600, dir_fd=self._parent.fd)
            self._fds.callback(os.close, self.lock_fd)
            _private(os.fstat(self.lock_fd))
            self._lock = _identity(os.fstat(self.lock_fd))
            self._verify()
            try:
                fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise Refused("auth_busy") from None
            self._verify()
            self.auth_fd = os.open("auth.json", review.READ_FLAGS, dir_fd=self._parent.fd)
            self._fds.callback(os.close, self.auth_fd)
            self._auth = _identity(os.fstat(self.auth_fd))
            self.check()
            self.owner = self._owner()
            if expected_owner is not None and self.owner != expected_owner:
                raise Refused("auth_identity")
        except BaseException as error:
            self.close()
            if isinstance(error, Refused):
                raise
            if isinstance(error, (OSError, ValueError, TypeError, protocol.Refused)):
                raise Refused("credentials") from None
            raise

    def _verify(self):
        if self._closed:
            raise ValueError()
        self._parent.verify()
        node = os.fstat(self._parent.fd)
        _private(node, directory=True)
        if _identity(node) != self._directory:
            raise ValueError()
        for name, fd, expected in ((".draft.lock", self.lock_fd, self._lock),
                                  ("auth.json", self.auth_fd, getattr(self, "_auth", None))):
            if fd is None:
                continue
            node = os.fstat(fd)
            _private(node)
            if (_identity(node) != expected or _identity(os.stat(
                    name, dir_fd=self._parent.fd, follow_symlinks=False)) != expected):
                raise ValueError()

    def check(self) -> None:
        try:
            self._verify()
        except (OSError, ValueError):
            raise Refused("credentials") from None

    def _owner(self):
        self.check()
        before = os.fstat(self.auth_fd)
        os.lseek(self.auth_fd, 0, os.SEEK_SET)
        raw = review._read_fd(self.auth_fd, before, MAX_BYTES)
        self.check()
        if review._snapshot(os.fstat(self.auth_fd)) != review._snapshot(before):
            raise ValueError()
        return chatgpt_owner(validate(raw))

    def settle(self) -> None:
        try:
            if self._owner() != self.owner:
                raise Refused("auth_identity")
            os.fsync(self.auth_fd)
            self.check()
        except (OSError, ValueError, Refused) as error:
            reason = "auth_identity" if isinstance(error, Refused) and str(error) == "auth_identity" else "auth_persistence"
            raise Refused(reason) from None

    def close(self) -> None:
        if not self._closed:
            self._closed = True
            # LOCK_UN would release the supervisor's shared open-file-description lock.
            self._fds.close()
            self.auth_fd = self.lock_fd = None
