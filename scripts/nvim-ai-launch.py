#!/usr/bin/env python3
"""Validate and launch native AI CLIs through a strict Bubblewrap boundary."""

import argparse
import base64
import fcntl
import hashlib
import hmac
import http.client
import io
import json
import os
import pathlib
import re
import select
import signal
import socket
import stat
import subprocess
import sys
import termios
import time


MAX_MANIFEST_BYTES = 1024 * 1024
MAX_PROFILE_BYTES = 1024 * 1024
MAX_CODEX_CONFIG_BYTES = 1024 * 1024
MAX_TEXT_BYTES = 8192
MAX_ARGUMENTS = 256
MAX_COLLECTION_ENTRIES = 128
MAX_EVENT_BYTES = 1024 * 1024
AUDITED_VERSION = "1.18.30"
# Workaround for the audited OpenTUI renderer crashing at narrow widths. This
# is a relay diagnostic, not evidence that the upstream renderer is repaired.
OPENCODE_MIN_COLUMNS = 40
OPENCODE_SIZE_EXIT = 78
AUDITED_POLICY_JSON = (
    '{"bash":"ask","doom_loop":"ask","external_directory":"ask",'
    '"skill":"deny","task":"deny","webfetch":"ask","websearch":"ask"}'
)
AUDITED_CONFIG_JSON = (
    '{"$schema":"https://opencode.ai/config.json","autoupdate":false,'
    '"permission":{"bash":"ask","doom_loop":"ask",'
    '"external_directory":"ask","skill":"deny","task":"deny",'
    '"webfetch":"ask","websearch":"ask"},"agent":{'
    '"general":{"disable":true},"explore":{"disable":true},'
    '"compaction":{"permission":{"*":"deny"}},'
    '"summary":{"permission":{"*":"deny"}},'
    '"title":{"permission":{"*":"deny"}}}}'
)
AUDITED_BOOTSTRAP_GITIGNORE = (
    b"node_modules\npackage.json\npackage-lock.json\nbun.lock\n.gitignore"
)
AUDITED_BOOTSTRAP_GITIGNORE_SHA256 = (
    "663a068e76d264d0bc6740f5450b6c4193c7b41ecf5e0dc222485b8a17404d95"
)
MOUNT_DESTINATION_CLEANUP_ERROR = "mount destination cleanup failed"
CHILD_CLEANUP_ERROR = "managed child cleanup failed"

TOP_LEVEL_KEYS = frozenset(
    (
        "schema",
        "token",
        "identity_key",
        "root",
        "git_dir",
        "git_common_dir",
        "git_entry",
        "writable",
        "grants",
        "review_id",
        "runtime_root",
        "state_root",
        "context_dir",
        "backend_state_dir",
        "control_socket",
        "control_token",
        "control_helper",
        "event_helper",
        "profile_helper",
        "launcher",
        "review_helper",
        "event_file",
        "tmux_socket",
        "python",
        "bwrap",
        "host_tools",
        "shell",
        "launch",
    )
)
LAUNCH_KEYS = frozenset(
    (
        "kind",
        "backend",
        "argv",
        "server_argv",
        "attach_argv",
        "env",
        "session",
        "capabilities",
        "read_only_inputs",
        "protected_paths",
        "event_url",
        "event_file",
        "managed_profile",
    )
)
PROFILE_KEYS = frozenset(
    (
        "schema",
        "version",
        "profile_root",
        "fingerprint",
        "config_source",
        "auth_source",
        "home_mask_source",
    )
)
CAPABILITY_KEYS = frozenset(("approval", "busy", "completion", "exact_session"))
INPUT_KEYS = frozenset(("source", "destination", "kind"))
PROFILE_MANIFEST_KEYS = (
    "schema",
    "version",
    "identity_key",
    "root",
    "fingerprint",
    "config_sha256",
    "instructions_sha256",
)
OPENCODE_KEYS = frozenset(
    (
        "OPENCODE_DISABLE_AUTOUPDATE",
        "OPENCODE_DISABLE_CLAUDE_CODE",
        "OPENCODE_DISABLE_EXTERNAL_SKILLS",
        "OPENCODE_DISABLE_LSP_DOWNLOAD",
        "OPENCODE_DISABLE_PROJECT_CONFIG",
        "OPENCODE_PERMISSION",
        "OPENCODE_PURE",
        "OPENCODE_SERVER_PASSWORD",
        "OPENCODE_SERVER_USERNAME",
        "XDG_CACHE_HOME",
        "XDG_CONFIG_HOME",
        "XDG_DATA_HOME",
        "XDG_STATE_HOME",
    )
)
PARENT_KEYS = frozenset(
    (
        "PATH",
        "HOME",
        "USER",
        "LOGNAME",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "TERM",
        "COLORTERM",
        "NO_COLOR",
        "SSL_CERT_FILE",
        "SSL_CERT_DIR",
        "REQUESTS_CA_BUNDLE",
        "CURL_CA_BUNDLE",
        "NODE_EXTRA_CA_CERTS",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "NO_PROXY",
        "FTP_PROXY",
        "http_proxy",
        "https_proxy",
        "all_proxy",
        "no_proxy",
        "ftp_proxy",
    )
)

_ACTIVE_CHILDREN = []
_RESIZE_WRITERS = {}


def _current_uid():
    return os.getuid()


def _has_control(value):
    return any(ord(character) <= 31 or 127 <= ord(character) <= 159 for character in value)


def _safe_text(value, label, *, allow_empty=False):
    if not isinstance(value, str):
        raise ValueError(label + " must be text")
    try:
        encoded = value.encode("utf-8")
    except UnicodeError:
        raise ValueError(label + " is not valid UTF-8") from None
    if (not allow_empty and not value) or len(encoded) > MAX_TEXT_BYTES or _has_control(value):
        raise ValueError(label + " contains an unsafe value")
    return value


def _valid_hex(value, length):
    return (
        isinstance(value, str)
        and len(value) == length
        and all(character in "0123456789abcdef" for character in value)
    )


def _canonical_path(value, label, *, allow_root=False):
    _safe_text(value, label)
    if not os.path.isabs(value) or os.path.normpath(value) != value:
        raise ValueError(label + " must be a canonical absolute path")
    if not allow_root and value == "/":
        raise ValueError(label + " must not be the filesystem root")
    return value


def _path_within(base, path):
    return path == base or path.startswith(base + os.sep)


def _exact_object(value, keys, label):
    if not isinstance(value, dict) or set(value) != set(keys):
        raise ValueError(label + " keys are invalid")
    return value


def _duplicate_rejecting_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON key")
        value[key] = item
    return value


def _reject_constant(_value):
    raise ValueError("invalid JSON constant")


def _decode_json_bytes(payload, label):
    if not isinstance(payload, bytes):
        raise ValueError(label + " is invalid")
    try:
        document = payload.decode("utf-8")
        return json.loads(
            document,
            object_pairs_hook=_duplicate_rejecting_object,
            parse_constant=_reject_constant,
        )
    except (UnicodeError, TypeError, RecursionError):
        raise ValueError(label + " is not valid JSON") from None
    except ValueError as error:
        if "duplicate JSON key" in str(error):
            raise ValueError(label + " contains a duplicate JSON key") from None
        raise ValueError(label + " is not valid JSON") from None


def _compact_json(value):
    try:
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    except (TypeError, ValueError, UnicodeError, RecursionError):
        raise ValueError("value is not valid JSON") from None


def _metadata_identity(value):
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_uid,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def _safe_nonuser_path(path):
    return not os.access(path, os.W_OK)


def _validate_owned_node(path, label, expected_kind, *, exact_mode=None, executable=False):
    _canonical_path(path, label)
    try:
        before = os.lstat(path)
        physical = os.path.realpath(path)
    except OSError:
        raise ValueError(label + " is unavailable") from None
    if physical != path or stat.S_ISLNK(before.st_mode):
        raise ValueError(label + " is a symlink or has a symlinked component")
    kind_ok = {
        "file": stat.S_ISREG,
        "directory": stat.S_ISDIR,
        "socket": stat.S_ISSOCK,
    }[expected_kind](before.st_mode)
    if not kind_ok:
        raise ValueError(label + " has the wrong kind")
    mode = stat.S_IMODE(before.st_mode)
    if exact_mode is not None and mode != exact_mode:
        raise ValueError(label + " has an unsafe mode")
    if exact_mode is None and mode & 0o022:
        raise ValueError(label + " is group- or world-writable")
    if before.st_uid != _current_uid() and not _safe_nonuser_path(path):
        raise ValueError(label + " has an unsafe owner")
    if executable and mode & 0o111 == 0:
        raise ValueError(label + " is not executable")
    try:
        after = os.lstat(path)
    except OSError:
        raise ValueError(label + " changed during validation") from None
    if _metadata_identity(before) != _metadata_identity(after):
        raise ValueError(label + " changed during validation")
    return before


def _validate_private_directory(path, label):
    value = _validate_owned_node(path, label, "directory", exact_mode=0o700)
    if value.st_uid != _current_uid():
        raise ValueError(label + " has the wrong owner")
    return value


def _validate_private_file(path, label):
    value = _validate_owned_node(path, label, "file", exact_mode=0o600)
    if value.st_uid != _current_uid():
        raise ValueError(label + " has the wrong owner")
    return value


def _validate_trusted_node(path, label, expected_kind, *, executable=False):
    value = _validate_owned_node(
        path, label, expected_kind, executable=executable
    )
    if value.st_uid not in (0, _current_uid()):
        raise ValueError(label + " has an unsafe owner")
    return value


def _validate_executable(path, label):
    return _validate_trusted_node(path, label, "file", executable=True)


def _validate_trusted_file(path, label):
    return _validate_trusted_node(path, label, "file")


def _validate_current_user_socket(path, label):
    _canonical_path(path, label)
    try:
        before = os.lstat(path)
        physical = os.path.realpath(path)
    except OSError:
        raise ValueError(label + " is unavailable") from None
    if (
        physical != path
        or stat.S_ISLNK(before.st_mode)
        or not stat.S_ISSOCK(before.st_mode)
        or before.st_uid != _current_uid()
    ):
        raise ValueError(label + " has unsafe ownership or kind")
    try:
        after = os.lstat(path)
    except OSError:
        raise ValueError(label + " changed during validation") from None
    if _metadata_identity(before) != _metadata_identity(after):
        raise ValueError(label + " changed during validation")
    return before


def _validate_string_array(value, label, *, paths=False, nonempty=True):
    if not isinstance(value, list) or len(value) > MAX_ARGUMENTS:
        raise ValueError(label + " must be a bounded array")
    if nonempty and not value:
        raise ValueError(label + " must not be empty")
    result = []
    for item in value:
        if paths:
            result.append(_canonical_path(item, label + " path"))
        else:
            result.append(_safe_text(item, label + " value"))
    return result


def _validate_optional_path(value, label):
    if value is None:
        return None
    return _canonical_path(value, label)


def _validate_optional_text(value, label):
    if value is None:
        return None
    return _safe_text(value, label)


def _validate_manifest_metadata(metadata):
    if not isinstance(metadata, dict):
        raise ValueError("manifest metadata is invalid")
    if metadata.get("is_symlink"):
        raise ValueError("manifest is a symlink")
    if not metadata.get("is_regular"):
        raise ValueError("manifest is not a regular file")
    if metadata.get("mode") != 0o600:
        raise ValueError("manifest must have mode 0600")
    if metadata.get("uid") != _current_uid():
        raise ValueError("manifest has the wrong owner")
    size = metadata.get("size")
    if isinstance(size, bool) or not isinstance(size, int) or size > MAX_MANIFEST_BYTES:
        raise ValueError("manifest is too large")


def _validate_grants(manifest):
    grants = manifest["grants"]
    if not isinstance(grants, list) or len(grants) > MAX_COLLECTION_ENTRIES:
        raise ValueError("grant list is invalid")
    if any(not isinstance(grant, str) for grant in grants):
        raise ValueError("grant list contains a non-path value")
    if grants != sorted(set(grants)):
        raise ValueError("grant list must be sorted and unique")
    for grant in grants:
        _canonical_path(grant, "grant")
        if grant == manifest["root"]:
            raise ValueError("grant duplicates the project root")
        try:
            kind = "file" if stat.S_ISREG(os.lstat(grant).st_mode) else "directory"
        except OSError:
            raise ValueError("grant is unavailable") from None
        _validate_owned_node(grant, "grant", kind)
    if manifest["writable"]:
        review = manifest["review_id"]
        if (
            not isinstance(review, str)
            or not review.startswith("review_")
            or not review[7:]
            or not _valid_hex(review[7:], len(review) - 7)
            or len(review) > 128
        ):
            raise ValueError("writable launch requires a valid review ID")
    elif manifest["review_id"] is not None:
        raise ValueError("read-only launch must not contain a review ID")


def _read_git_entry_target(path):
    descriptor = None
    try:
        before = os.lstat(path)
        mode = stat.S_IMODE(before.st_mode)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_size > 4096
            or mode & 0o022
            or (before.st_uid != _current_uid() and not _safe_nonuser_path(path))
        ):
            raise ValueError("Git entry is invalid")
        flags = os.O_RDONLY | os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags)
        opened = os.fstat(descriptor)
        if _metadata_identity(before) != _metadata_identity(opened):
            raise ValueError("Git entry changed during validation")
        chunks = []
        remaining = 4097
        while remaining:
            chunk = os.read(descriptor, min(4096, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        payload = b"".join(chunks)
        after_open = os.fstat(descriptor)
        after_path = os.lstat(path)
        if (
            len(payload) > 4096
            or len(payload) != opened.st_size
            or _metadata_identity(opened) != _metadata_identity(after_open)
            or _metadata_identity(opened) != _metadata_identity(after_path)
        ):
            raise ValueError("Git entry changed while reading")
        try:
            document = payload.decode("utf-8")
        except UnicodeError:
            raise ValueError("Git entry is invalid") from None
        if document.endswith("\n"):
            document = document[:-1]
        if "\r" in document or "\n" in document or not document.startswith("gitdir: "):
            raise ValueError("Git entry is invalid")
        target = document[len("gitdir: ") :]
        if not target or "\x00" in target or _has_control(target):
            raise ValueError("Git entry is invalid")
        if not os.path.isabs(target):
            target = os.path.normpath(os.path.join(os.path.dirname(path), target))
        return os.path.realpath(target)
    except ValueError:
        raise
    except OSError:
        raise ValueError("Git entry cannot be read safely") from None
    finally:
        if descriptor is not None:
            active_error = sys.exc_info()[0] is not None
            try:
                os.close(descriptor)
            except OSError:
                if not active_error:
                    raise ValueError("Git entry cannot be closed safely") from None


def _validate_git_and_roots(manifest):
    root = _canonical_path(manifest["root"], "project root")
    _validate_owned_node(root, "project root", "directory")
    runtime = _canonical_path(manifest["runtime_root"], "runtime root")
    state_root = _canonical_path(manifest["state_root"], "state root")
    context = _canonical_path(manifest["context_dir"], "context directory")
    backend = _canonical_path(manifest["backend_state_dir"], "backend state directory")
    control = _canonical_path(manifest["control_socket"], "control socket")
    event_file = _canonical_path(manifest["event_file"], "event file")
    _validate_private_directory(runtime, "runtime root")
    _validate_private_directory(state_root, "state root")
    _validate_private_directory(context, "context directory")
    _validate_private_directory(backend, "backend state directory")
    _validate_private_file(event_file, "event file")
    if not _path_within(runtime, context) or not _path_within(runtime, control):
        raise ValueError("runtime path is outside the runtime root")
    if not _path_within(state_root, backend) or not _path_within(backend, event_file):
        raise ValueError("backend path is outside the state root")
    _validate_owned_node(control, "control socket", "socket")

    git_values = (manifest["git_dir"], manifest["git_common_dir"], manifest["git_entry"])
    if any(value is None for value in git_values):
        if any(value is not None for value in git_values):
            raise ValueError("Git paths must be present together")
    else:
        _validate_owned_node(manifest["git_dir"], "Git directory", "directory")
        _validate_owned_node(
            manifest["git_common_dir"], "Git common directory", "directory"
        )
        if manifest["git_entry"] != os.path.join(root, ".git"):
            raise ValueError("Git entry is not the exact project entry")
        try:
            git_entry_metadata = os.lstat(manifest["git_entry"])
        except OSError:
            raise ValueError("Git entry is unavailable") from None
        if stat.S_ISREG(git_entry_metadata.st_mode):
            git_entry_kind = "file"
        elif stat.S_ISDIR(git_entry_metadata.st_mode):
            git_entry_kind = "directory"
        else:
            raise ValueError("Git entry has the wrong kind")
        _validate_owned_node(manifest["git_entry"], "Git entry", git_entry_kind)
        if git_entry_kind == "directory":
            if os.path.realpath(manifest["git_entry"]) != manifest["git_dir"]:
                raise ValueError("Git entry does not match the Git directory")
        elif _read_git_entry_target(manifest["git_entry"]) != manifest["git_dir"]:
            raise ValueError("Git entry does not target the Git directory")

    tmux_socket = manifest["tmux_socket"]
    if tmux_socket is not None:
        _validate_current_user_socket(tmux_socket, "tmux socket")


def _validate_trusted_paths(manifest):
    for field, label in (
        ("python", "Python executable"),
        ("bwrap", "Bubblewrap executable"),
        ("shell", "login shell"),
    ):
        _validate_executable(manifest[field], label)
    if os.path.realpath(sys.executable) != manifest["python"]:
        raise ValueError("Python executable does not match the running launcher")
    expected_launcher = str(pathlib.Path(__file__).resolve())
    if manifest["launcher"] != expected_launcher:
        raise ValueError("launcher path does not match the running launcher")
    for field, label in (
        ("launcher", "launcher"),
        ("review_helper", "review helper"),
        ("control_helper", "control helper"),
        ("event_helper", "event helper"),
        ("profile_helper", "profile helper"),
    ):
        _validate_trusted_file(manifest[field], label)

    tools = _validate_string_array(manifest["host_tools"], "host tools", paths=True)
    if tools != sorted(set(tools)):
        raise ValueError("host tools must be sorted and unique")
    names = []
    for tool in tools:
        _validate_executable(tool, "host tool")
        names.append(os.path.basename(tool))
    expected_names = ["git"] + (["tmux"] if manifest["tmux_socket"] else [])
    if sorted(names) != sorted(expected_names):
        raise ValueError("host tools do not contain the exact Git and tmux tools")


def _validate_profile_public(profile, backend):
    _exact_object(profile, PROFILE_KEYS, "managed profile")
    if (
        type(profile["schema"]) is not int
        or profile["schema"] != 1
        or profile["version"] != AUDITED_VERSION
    ):
        raise ValueError("managed profile schema or version is unsupported")
    if not _valid_hex(profile["fingerprint"], 64):
        raise ValueError("managed profile fingerprint is invalid")
    root = _canonical_path(profile["profile_root"], "managed profile root")
    prefix = os.path.join(backend, "profiles") + os.sep
    if not root.startswith(prefix):
        raise ValueError("managed profile root is outside backend state")
    token = root[len(prefix) :]
    if os.sep in token or not _valid_hex(token, 32):
        raise ValueError("managed profile generation is invalid")
    expected = {
        "config_source": os.path.join(root, "xdg-config"),
        "auth_source": os.path.join(root, "credentials", "auth.json"),
        "home_mask_source": os.path.join(root, "empty-home-opencode"),
    }
    for field, path in expected.items():
        if _canonical_path(profile[field], "managed profile " + field) != path:
            raise ValueError("managed profile contains an unexpected source path")
    return profile


def _validate_destination_chain(backend, destination, expected_kind):
    relative = os.path.relpath(destination, backend)
    components = relative.split(os.sep)
    parent_components = components[:-1]
    backend_descriptor = current_descriptor = None
    try:
        backend_descriptor = _open_private_directory_path(
            backend, "read-only input destination root"
        )
        current_descriptor = backend_descriptor
        for component in parent_components:
            try:
                os.stat(component, dir_fd=current_descriptor, follow_symlinks=False)
            except FileNotFoundError:
                return
            except OSError:
                raise ValueError("read-only input destination parent is unsafe") from None
            child = _open_private_child(
                current_descriptor, component, "read-only input destination parent"
            )
            if current_descriptor != backend_descriptor:
                os.close(current_descriptor)
            current_descriptor = child
        try:
            metadata = os.stat(
                components[-1], dir_fd=current_descriptor, follow_symlinks=False
            )
        except FileNotFoundError:
            return
        except OSError:
            raise ValueError("read-only input destination is unsafe") from None
        kind_ok = stat.S_ISREG(metadata.st_mode) if expected_kind == "file" else stat.S_ISDIR(metadata.st_mode)
        expected_mode = 0o600 if expected_kind == "file" else 0o700
        if (
            not kind_ok
            or metadata.st_uid != _current_uid()
            or stat.S_IMODE(metadata.st_mode) != expected_mode
        ):
            raise ValueError("read-only input destination has the wrong kind, owner, or mode")
    finally:
        if current_descriptor is not None and current_descriptor != backend_descriptor:
            try:
                os.close(current_descriptor)
            except OSError:
                pass
        if backend_descriptor is not None:
            try:
                os.close(backend_descriptor)
            except OSError:
                pass


def _validate_read_only_inputs(launch, backend):
    values = launch["read_only_inputs"]
    if not isinstance(values, list) or len(values) > MAX_COLLECTION_ENTRIES:
        raise ValueError("read-only inputs are invalid")
    protected = launch["protected_paths"]
    for item in values:
        _exact_object(item, INPUT_KEYS, "read-only input")
        source = _canonical_path(item["source"], "read-only input source")
        destination = _canonical_path(
            item["destination"], "read-only input destination"
        )
        if item["kind"] not in ("file", "directory"):
            raise ValueError("read-only input kind is invalid")
        if not _path_within(backend, destination) or destination == backend:
            raise ValueError("read-only input destination is outside backend state")
        if not any(_path_within(provider, source) for provider in protected):
            raise ValueError("read-only input source is outside its provider root")
        _validate_owned_node(source, "read-only input source", item["kind"])
        _validate_destination_chain(backend, destination, item["kind"])


def _validate_protected_paths(launch):
    paths = _validate_string_array(
        launch["protected_paths"], "protected paths", paths=True, nonempty=True
    )
    if paths != sorted(set(paths)):
        raise ValueError("protected paths must be sorted and unique")
    executable_paths = set()
    for field in ("argv", "server_argv", "attach_argv"):
        arguments = launch.get(field)
        if isinstance(arguments, list) and arguments:
            executable_paths.add(arguments[0])
    for path in paths:
        if path in executable_paths:
            _validate_executable(path, "protected executable")
            continue
        try:
            metadata = os.lstat(path)
        except OSError:
            raise ValueError("protected path is unavailable") from None
        if stat.S_ISDIR(metadata.st_mode):
            validated = _validate_owned_node(path, "protected path", "directory")
        elif stat.S_ISREG(metadata.st_mode):
            validated = _validate_owned_node(path, "protected path", "file")
        else:
            raise ValueError("protected path has the wrong kind")
        if validated.st_uid != _current_uid():
            raise ValueError("protected path has the wrong owner")
    return paths


def _validate_claude_settings(manifest, argv):
    launch = manifest["launch"]
    session = launch["session"]
    if (re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", session) is None
            or len(argv) < 7 or argv[1] not in ("--session-id", "--resume")
            or argv[2:6] != [session, "--permission-mode", "acceptEdits", "--settings"]
            or launch["event_url"] is not None or launch["event_file"] != manifest["event_file"]):
        raise ValueError("Claude session or event command changed")
    expected_grants = []
    seen = set()
    for grant in manifest["grants"]:
        directory = os.path.dirname(grant) if stat.S_ISREG(os.lstat(grant).st_mode) else grant
        if directory not in seen:
            expected_grants.extend(["--add-dir", directory])
            seen.add(directory)
    if argv[7:] != expected_grants:
        raise ValueError("Claude scope arguments changed")
    def quote(value):
        return "'" + value.replace("'", "'\\''") + "'"
    command = (quote(manifest["python"]) + " -I -B " + quote(manifest["event_helper"])
               + " claude-hook --event-file " + quote(manifest["event_file"]))
    expected = {"hooks": {
        name: [{"hooks": [{"type": "command", "command": command, "timeout": 5}]}]
        for name in ("SessionStart", "PostToolUse", "UserPromptSubmit", "PreToolUse",
                     "PermissionRequest", "Stop", "SessionEnd")
    }}
    settings = _decode_json_bytes(argv[6].encode("utf-8"), "Claude hook settings")
    if settings != expected:
        raise ValueError("Claude hook settings changed")


def _validate_launch(manifest):
    value = manifest["launch"]
    keys = LAUNCH_KEYS | ({"config_seed"} if isinstance(value, dict) and "config_seed" in value else set())
    launch = _exact_object(value, keys, "launch")
    if launch["backend"] not in ("codex", "claude", "opencode"):
        raise ValueError("launch backend is unsupported")
    if not isinstance(launch["session"], str) or len(launch["session"]) > 512:
        raise ValueError("launch session is invalid")
    _safe_text(launch["session"], "launch session", allow_empty=True)
    _exact_object(launch["capabilities"], CAPABILITY_KEYS, "capabilities")
    if not all(isinstance(value, bool) for value in launch["capabilities"].values()):
        raise ValueError("capabilities must be boolean")
    if not isinstance(launch["env"], dict) or len(launch["env"]) > MAX_COLLECTION_ENTRIES:
        raise ValueError("adapter environment is invalid")
    for key, value in launch["env"].items():
        _safe_text(key, "adapter environment name")
        _safe_text(value, "adapter environment value", allow_empty=True)
    protected = _validate_protected_paths(launch)
    _validate_read_only_inputs(launch, manifest["backend_state_dir"])
    seed = launch.get("config_seed")
    if seed is not None:
        if launch["backend"] != "codex" or launch["kind"] != "direct":
            raise ValueError("configuration seed is only supported for Codex")
        _canonical_path(seed, "Codex configuration seed")
        if os.path.basename(seed) != "config.toml" or not any(
            provider != seed and _path_within(provider, seed) for provider in protected
        ):
            raise ValueError("Codex configuration seed is outside its provider root")
        source = _validate_owned_node(seed, "Codex configuration seed", "file")
        if source.st_nlink != 1 or source.st_size > MAX_CODEX_CONFIG_BYTES:
            raise ValueError("Codex configuration seed has unsafe size or links")
        destination = os.path.join(manifest["backend_state_dir"], "config.toml")
        if any(
            _path_within(item["destination"], destination)
            or _path_within(destination, item["destination"])
            for item in launch["read_only_inputs"]
        ):
            raise ValueError("Codex configuration seed overlaps a read-only input")
    _validate_optional_text(launch["event_url"], "event URL")
    event_file = _validate_optional_path(launch["event_file"], "launch event file")
    if event_file is not None and event_file != manifest["event_file"]:
        raise ValueError("launch event file changed")

    if launch["kind"] == "direct" and launch["backend"] in ("codex", "claude"):
        if launch["managed_profile"] is not None:
            raise ValueError("direct backend must not contain a managed profile")
        if launch["server_argv"] is not None or launch["attach_argv"] is not None:
            raise ValueError("direct backend contains server or attach argv")
        argv = _validate_string_array(launch["argv"], "backend argv")
        _validate_executable(argv[0], "backend executable")
        if argv[0] not in protected:
            raise ValueError("backend executable is not protected")
        if launch["backend"] == "claude":
            _validate_claude_settings(manifest, argv)
    elif launch["kind"] == "server_attach" and launch["backend"] == "opencode":
        if launch["argv"] is not None:
            raise ValueError("OpenCode launch contains a direct argv")
        server = _validate_string_array(launch["server_argv"], "OpenCode server argv")
        attach = _validate_string_array(launch["attach_argv"], "OpenCode attach argv")
        if (
            len(server) != 7
            or server[1:6] != ["--pure", "serve", "--hostname", "127.0.0.1", "--port"]
        ):
            raise ValueError("OpenCode server or attach command form changed")
        port = server[6]
        if (
            not port.isascii()
            or not port.isdigit()
            or len(port) > 5
            or int(port) < 1
            or int(port) > 65535
            or str(int(port)) != port
        ):
            raise ValueError("OpenCode server port is invalid")
        expected_attach = [
            server[0],
            "--pure",
            "attach",
            "http://127.0.0.1:" + port,
            "--dir",
            manifest["root"],
        ]
        if launch["session"]:
            expected_attach.extend(["--session", launch["session"]])
        if attach != expected_attach:
            raise ValueError("OpenCode server or attach command form changed")
        if launch["event_url"] != "http://127.0.0.1:" + port + "/event" or event_file != manifest["event_file"]:
            raise ValueError("OpenCode event endpoint or file changed")
        _validate_executable(server[0], "OpenCode executable")
        if server[0] not in protected:
            raise ValueError("OpenCode executable is not protected")
        profile = _validate_profile_public(
            launch["managed_profile"], manifest["backend_state_dir"]
        )
        if profile["profile_root"] not in protected:
            raise ValueError("managed profile root is not protected")
        if launch["read_only_inputs"]:
            raise ValueError("managed OpenCode must not contain ordinary inputs")
    else:
        raise ValueError("launch kind does not match backend")


def validate_manifest(data, metadata):
    _validate_manifest_metadata(metadata)
    manifest = _exact_object(data, TOP_LEVEL_KEYS, "manifest")
    if type(manifest["schema"]) is not int or manifest["schema"] != 1:
        raise ValueError("manifest schema is unsupported")
    if not _valid_hex(manifest["token"], 32):
        raise ValueError("manifest token is invalid")
    if not _valid_hex(manifest["identity_key"], 32):
        raise ValueError("manifest identity is invalid")
    if not _valid_hex(manifest["control_token"], 32):
        raise ValueError("control token is invalid")
    if not isinstance(manifest["writable"], bool):
        raise ValueError("manifest writable flag is invalid")
    _validate_git_and_roots(manifest)
    _validate_grants(manifest)
    _validate_trusted_paths(manifest)
    _validate_launch(manifest)
    return manifest


def _directory_flags():
    flags = os.O_RDONLY | os.O_CLOEXEC
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    return flags


def _open_private_directory_path(path, label, return_identity=False):
    _validate_private_directory(path, label)
    descriptor = None
    try:
        before = os.lstat(path)
        descriptor = os.open(path, _directory_flags())
        opened = os.fstat(descriptor)
        if _metadata_identity(before) != _metadata_identity(opened):
            raise ValueError(label + " changed during validation")
        identity = _metadata_identity(opened)
        if return_identity:
            return descriptor, identity
        return descriptor
    except Exception:
        if descriptor is not None:
            os.close(descriptor)
        raise


def _open_private_child(
    parent_descriptor, name, label, return_identity=False
):
    descriptor = None
    try:
        before = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        if (
            not stat.S_ISDIR(before.st_mode)
            or before.st_uid != _current_uid()
            or stat.S_IMODE(before.st_mode) != 0o700
        ):
            raise ValueError(label + " has unsafe ownership, mode, or kind")
        descriptor = os.open(name, _directory_flags(), dir_fd=parent_descriptor)
        opened = os.fstat(descriptor)
        if _metadata_identity(before) != _metadata_identity(opened):
            raise ValueError(label + " changed during validation")
        identity = _metadata_identity(opened)
        if return_identity:
            return descriptor, identity
        return descriptor
    except (OSError, ValueError):
        if descriptor is not None:
            os.close(descriptor)
        raise ValueError(label + " is not a safe private directory") from None


def _list_entries(descriptor, label):
    try:
        return sorted(os.listdir(descriptor))
    except OSError:
        raise ValueError(label + " cannot be inspected") from None


def _verify_private_directory_path(path, descriptor, identity, label):
    try:
        current = os.lstat(path)
        opened = os.fstat(descriptor)
        physical = os.path.realpath(path)
    except (OSError, ValueError):
        raise ValueError(label + " changed during validation") from None
    for metadata in (current, opened):
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or metadata.st_uid != _current_uid()
            or stat.S_IMODE(metadata.st_mode) != 0o700
        ):
            raise ValueError(label + " changed during validation")
    if (
        physical != path
        or stat.S_ISLNK(current.st_mode)
        or _metadata_identity(current) != identity
        or _metadata_identity(opened) != identity
    ):
        raise ValueError(label + " changed during validation")


def _verify_private_directory_child(
    parent_descriptor,
    name,
    descriptor,
    identity,
    label,
):
    try:
        current = os.stat(
            name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        opened = os.fstat(descriptor)
    except OSError:
        raise ValueError(label + " changed during validation") from None
    for metadata in (current, opened):
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or metadata.st_uid != _current_uid()
            or stat.S_IMODE(metadata.st_mode) != 0o700
        ):
            raise ValueError(label + " changed during validation")
    if (
        _metadata_identity(current) != identity
        or _metadata_identity(opened) != identity
    ):
        raise ValueError(label + " changed during validation")


def _read_regular_at(parent_descriptor, name, maximum, label="profile file"):
    descriptor = None
    try:
        before = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != _current_uid()
            or stat.S_IMODE(before.st_mode) != 0o600
        ):
            raise ValueError(label + " has unsafe ownership, mode, or kind")
        if before.st_size > maximum:
            raise ValueError(label + " is too large")
        flags = os.O_RDONLY | os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(name, flags, dir_fd=parent_descriptor)
        opened = os.fstat(descriptor)
        if _metadata_identity(before) != _metadata_identity(opened):
            raise ValueError(label + " changed during validation")
        chunks = []
        remaining = maximum + 1
        while remaining:
            chunk = os.read(descriptor, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        payload = b"".join(chunks)
        after_open = os.fstat(descriptor)
        after_path = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        if (
            len(payload) > maximum
            or len(payload) != opened.st_size
            or _metadata_identity(opened) != _metadata_identity(after_open)
            or _metadata_identity(opened) != _metadata_identity(after_path)
        ):
            raise ValueError(label + " changed while reading")
        return payload
    except ValueError:
        raise
    except OSError:
        raise ValueError(label + " cannot be read safely") from None
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass


def _read_managed_home_bootstrap(descriptor):
    if _list_entries(descriptor, "managed home mask") != [".gitignore"]:
        raise ValueError("managed home mask bootstrap tree is not canonical")
    try:
        before = os.stat(
            ".gitignore",
            dir_fd=descriptor,
            follow_symlinks=False,
        )
    except OSError:
        raise ValueError("managed home bootstrap cannot be inspected") from None
    payload = _read_regular_at(
        descriptor,
        ".gitignore",
        len(AUDITED_BOOTSTRAP_GITIGNORE),
        "managed home bootstrap",
    )
    try:
        after = os.stat(
            ".gitignore",
            dir_fd=descriptor,
            follow_symlinks=False,
        )
    except OSError:
        raise ValueError("managed home bootstrap changed during validation") from None
    identity = _metadata_identity(after)
    if _metadata_identity(before) != identity:
        raise ValueError("managed home bootstrap changed during validation")
    if (
        payload != AUDITED_BOOTSTRAP_GITIGNORE
        or hashlib.sha256(payload).hexdigest()
        != AUDITED_BOOTSTRAP_GITIGNORE_SHA256
    ):
        raise ValueError("managed home bootstrap changed")
    return payload, identity


def _validate_credential_string(value, label, maximum):
    if not isinstance(value, str):
        raise ValueError(label + " has an invalid credential field")
    try:
        encoded = value.encode("utf-8")
    except UnicodeError:
        raise ValueError(label + " has an invalid credential field") from None
    if len(encoded) > maximum or "\x00" in value:
        raise ValueError(label + " has an invalid credential field")


def _sorted_utf8(values):
    return sorted(values, key=lambda value: value.encode("utf-8"))


def _validate_authentication(payload):
    auth = _decode_json_bytes(payload, "managed authentication")
    if not isinstance(auth, dict) or not auth or len(auth) > MAX_COLLECTION_ENTRIES:
        raise ValueError("managed authentication has no accepted credentials")
    normalized = set()
    normalized_records = {}
    for provider, record in auth.items():
        _validate_credential_string(provider, "managed authentication", 256)
        if _has_control(provider):
            raise ValueError("managed authentication provider is invalid")
        identity = provider.rstrip("/")
        if not identity or identity != provider or identity in normalized:
            raise ValueError("managed authentication provider is invalid")
        normalized.add(identity)
        if not isinstance(record, dict):
            raise ValueError("managed authentication record is invalid")
        credential_type = record.get("type")
        if credential_type == "api":
            if set(record) not in ({"type", "key"}, {"type", "key", "metadata"}):
                raise ValueError("managed authentication API record is invalid")
            _validate_credential_string(record["key"], "managed authentication", 256 * 1024)
            normalized_record = {"type": "api", "key": record["key"]}
            metadata = record.get("metadata", {})
            if not isinstance(metadata, dict) or len(metadata) > MAX_COLLECTION_ENTRIES:
                raise ValueError("managed authentication metadata is invalid")
            for key, value in metadata.items():
                _validate_credential_string(key, "managed authentication", MAX_TEXT_BYTES)
                _validate_credential_string(value, "managed authentication", MAX_TEXT_BYTES)
            if "metadata" in record:
                normalized_record["metadata"] = {
                    key: metadata[key] for key in _sorted_utf8(metadata)
                }
        elif credential_type == "oauth":
            required = {"type", "refresh", "access", "expires"}
            allowed = required | {"accountId", "enterpriseUrl"}
            if not required.issubset(record) or not set(record).issubset(allowed):
                raise ValueError("managed authentication OAuth record is invalid")
            _validate_credential_string(
                record["refresh"], "managed authentication", 256 * 1024
            )
            _validate_credential_string(
                record["access"], "managed authentication", 256 * 1024
            )
            expires = record["expires"]
            if isinstance(expires, bool) or not isinstance(expires, int) or expires < 0:
                raise ValueError("managed authentication OAuth record is invalid")
            normalized_record = {
                "type": "oauth",
                "refresh": record["refresh"],
                "access": record["access"],
                "expires": expires,
            }
            for field in ("accountId", "enterpriseUrl"):
                if field in record:
                    _validate_credential_string(
                        record[field], "managed authentication", 256 * 1024
                    )
                    normalized_record[field] = record[field]
        else:
            raise ValueError("managed authentication record type is invalid")
        normalized_records[identity] = normalized_record
    normalized_auth = {
        provider: normalized_records[provider]
        for provider in _sorted_utf8(normalized_records)
    }
    if payload != (_compact_json(normalized_auth) + "\n").encode("utf-8"):
        raise ValueError("managed authentication is not canonical JSON")
    return len(normalized_auth)


def _profile_fingerprint(identity_key, root, config, instructions):
    digest = hashlib.sha256()
    for component in (
        b"1",
        AUDITED_VERSION.encode("utf-8"),
        identity_key.encode("ascii"),
        root.encode("utf-8"),
        config,
        instructions,
    ):
        digest.update(len(component).to_bytes(8, "big"))
        digest.update(component)
    return digest.hexdigest()


def _validate_stable_user_directory(path, label):
    try:
        before = os.lstat(path)
        physical = os.path.realpath(path)
    except OSError:
        raise ValueError(label + " is unavailable") from None
    if (
        stat.S_ISLNK(before.st_mode)
        or not stat.S_ISDIR(before.st_mode)
        or before.st_uid != _current_uid()
        or physical != path
        or stat.S_IMODE(before.st_mode) & 0o022
    ):
        raise ValueError(label + " has unsafe ownership, mode, or kind")
    try:
        after = os.lstat(path)
    except OSError:
        raise ValueError(label + " changed during validation") from None
    if _metadata_identity(before) != _metadata_identity(after):
        raise ValueError(label + " changed during validation")
    return before


def _validate_home(parent_env):
    if not isinstance(parent_env, dict) or "HOME" not in parent_env:
        raise ValueError("inherited HOME is missing")
    home = _canonical_path(parent_env["HOME"], "inherited HOME")
    _validate_stable_user_directory(home, "inherited HOME")
    destination = os.path.join(home, ".opencode")
    _validate_stable_user_directory(destination, "home OpenCode destination")
    return home


def _validate_isolated_destinations(manifest):
    environment = manifest["launch"]["env"]
    backend = manifest["backend_state_dir"]
    backend_descriptor = None
    opened = []
    try:
        backend_descriptor = _open_private_directory_path(
            backend, "isolated OpenCode state root"
        )
        descriptors = {}
        for field, leaf, required in (
            ("XDG_CACHE_HOME", "xdg-cache", True),
            ("XDG_CONFIG_HOME", "xdg-config", False),
            ("XDG_DATA_HOME", "xdg-data", True),
            ("XDG_STATE_HOME", "xdg-state", True),
        ):
            if environment[field] != os.path.join(backend, leaf):
                raise ValueError("isolated XDG destination changed")
            try:
                os.stat(leaf, dir_fd=backend_descriptor, follow_symlinks=False)
            except FileNotFoundError:
                if required:
                    raise ValueError("isolated XDG destination is missing") from None
                continue
            except OSError:
                raise ValueError("isolated XDG destination cannot be inspected") from None
            descriptor = _open_private_child(
                backend_descriptor, leaf, "isolated XDG destination"
            )
            descriptors[leaf] = descriptor
            opened.append(descriptor)
        data_descriptor = descriptors["xdg-data"]
        try:
            os.stat("opencode", dir_fd=data_descriptor, follow_symlinks=False)
        except FileNotFoundError:
            return
        except OSError:
            raise ValueError("isolated OpenCode state cannot be inspected") from None
        opencode_descriptor = _open_private_child(
            data_descriptor, "opencode", "isolated OpenCode state"
        )
        opened.append(opencode_descriptor)
        entries = _list_entries(opencode_descriptor, "isolated OpenCode state")
        for name in ("account.json", "mcp-auth.json"):
            if name in entries:
                raise ValueError("isolated OpenCode state contains forbidden account data")
        if "auth.json" in entries:
            metadata = os.stat(
                "auth.json", dir_fd=opencode_descriptor, follow_symlinks=False
            )
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != _current_uid()
                or stat.S_IMODE(metadata.st_mode) != 0o600
            ):
                raise ValueError("isolated OpenCode authentication destination is unsafe")
    finally:
        for descriptor in reversed(opened):
            try:
                os.close(descriptor)
            except OSError:
                pass
        if backend_descriptor is not None:
            try:
                os.close(backend_descriptor)
            except OSError:
                pass


def validate_managed_profile(manifest, parent_env):
    launch = manifest["launch"]
    if launch["backend"] != "opencode":
        return None
    profile = _validate_profile_public(
        launch["managed_profile"], manifest["backend_state_dir"]
    )
    _validate_home(parent_env)
    _validate_isolated_destinations(manifest)

    backend_descriptor = profiles_descriptor = profile_descriptor = None
    credentials_descriptor = mask_descriptor = xdg_descriptor = opencode_descriptor = None
    try:
        backend_descriptor, backend_identity = _open_private_directory_path(
            manifest["backend_state_dir"],
            "backend state directory",
            return_identity=True,
        )
        profiles_descriptor, profiles_identity = _open_private_child(
            backend_descriptor,
            "profiles",
            "managed profiles directory",
            return_identity=True,
        )
        token = os.path.basename(profile["profile_root"])
        profile_descriptor, profile_identity = _open_private_child(
            profiles_descriptor,
            token,
            "managed profile",
            return_identity=True,
        )
        if _list_entries(profile_descriptor, "managed profile") != [
            "credentials",
            "empty-home-opencode",
            "manifest.json",
            "xdg-config",
        ]:
            raise ValueError("managed profile has an unexpected tree")
        credentials_descriptor, credentials_identity = _open_private_child(
            profile_descriptor,
            "credentials",
            "managed credentials directory",
            return_identity=True,
        )
        if _list_entries(credentials_descriptor, "managed credentials") != ["auth.json"]:
            raise ValueError("managed profile has unexpected credential entries")
        auth = _read_regular_at(
            credentials_descriptor, "auth.json", MAX_PROFILE_BYTES, "managed authentication"
        )
        _validate_authentication(auth)

        mask_descriptor, mask_identity = _open_private_child(
            profile_descriptor,
            "empty-home-opencode",
            "managed home mask",
            return_identity=True,
        )
        home_bootstrap, home_bootstrap_identity = (
            _read_managed_home_bootstrap(mask_descriptor)
        )

        xdg_descriptor, xdg_identity = _open_private_child(
            profile_descriptor,
            "xdg-config",
            "managed XDG configuration",
            return_identity=True,
        )
        if _list_entries(xdg_descriptor, "managed XDG configuration") != ["opencode"]:
            raise ValueError("managed profile has an unexpected XDG tree")
        opencode_descriptor, opencode_identity = _open_private_child(
            xdg_descriptor,
            "opencode",
            "managed OpenCode configuration",
            return_identity=True,
        )
        if _list_entries(opencode_descriptor, "managed OpenCode configuration") != [
            ".gitignore",
            "AGENTS.md",
            "opencode.json",
        ]:
            raise ValueError("managed profile has unexpected configuration entries")
        bootstrap = _read_regular_at(
            opencode_descriptor, ".gitignore", MAX_PROFILE_BYTES, "configuration bootstrap"
        )
        if (
            bootstrap != AUDITED_BOOTSTRAP_GITIGNORE
            or hashlib.sha256(bootstrap).hexdigest() != AUDITED_BOOTSTRAP_GITIGNORE_SHA256
        ):
            raise ValueError("configuration bootstrap changed")
        instructions = _read_regular_at(
            opencode_descriptor, "AGENTS.md", MAX_PROFILE_BYTES, "instruction snapshot"
        )
        try:
            instructions.decode("utf-8")
        except UnicodeError:
            raise ValueError("instruction snapshot is not valid UTF-8") from None
        if b"\x00" in instructions:
            raise ValueError("instruction snapshot contains a NUL byte")
        config = _read_regular_at(
            opencode_descriptor, "opencode.json", MAX_PROFILE_BYTES, "managed configuration"
        )
        if config != AUDITED_CONFIG_JSON.encode("utf-8"):
            raise ValueError("managed configuration is not the audited canonical JSON")
        decoded_config = _decode_json_bytes(config, "managed configuration")
        if _compact_json(decoded_config) != AUDITED_CONFIG_JSON:
            raise ValueError("managed configuration semantics changed")

        profile_manifest_bytes = _read_regular_at(
            profile_descriptor, "manifest.json", MAX_PROFILE_BYTES, "profile manifest"
        )
        profile_manifest = _decode_json_bytes(profile_manifest_bytes, "profile manifest")
        _exact_object(profile_manifest, PROFILE_MANIFEST_KEYS, "profile manifest")
        fingerprint = _profile_fingerprint(
            manifest["identity_key"], manifest["root"], config, instructions
        )
        expected_manifest = {
            "schema": 1,
            "version": AUDITED_VERSION,
            "identity_key": manifest["identity_key"],
            "root": manifest["root"],
            "fingerprint": fingerprint,
            "config_sha256": hashlib.sha256(config).hexdigest(),
            "instructions_sha256": hashlib.sha256(instructions).hexdigest(),
        }
        if (
            type(profile_manifest.get("schema")) is not int
            or profile_manifest != expected_manifest
        ):
            raise ValueError("profile manifest hashes or identity changed")
        if profile_manifest_bytes != (_compact_json(expected_manifest) + "\n").encode("utf-8"):
            raise ValueError("profile manifest is not canonical JSON")
        if profile["fingerprint"] != fingerprint:
            raise ValueError("managed profile fingerprint changed")
        _verify_private_directory_child(
            profile_descriptor,
            "credentials",
            credentials_descriptor,
            credentials_identity,
            "managed credentials directory",
        )
        _verify_private_directory_child(
            profile_descriptor,
            "empty-home-opencode",
            mask_descriptor,
            mask_identity,
            "managed home mask",
        )
        _verify_private_directory_child(
            xdg_descriptor,
            "opencode",
            opencode_descriptor,
            opencode_identity,
            "managed OpenCode configuration",
        )
        _verify_private_directory_child(
            profile_descriptor,
            "xdg-config",
            xdg_descriptor,
            xdg_identity,
            "managed XDG configuration",
        )
        _verify_private_directory_child(
            profiles_descriptor,
            token,
            profile_descriptor,
            profile_identity,
            "managed profile",
        )
        _verify_private_directory_child(
            backend_descriptor,
            "profiles",
            profiles_descriptor,
            profiles_identity,
            "managed profiles directory",
        )
        _verify_private_directory_path(
            manifest["backend_state_dir"],
            backend_descriptor,
            backend_identity,
            "backend state directory",
        )
        final_home_bootstrap, final_home_bootstrap_identity = (
            _read_managed_home_bootstrap(mask_descriptor)
        )
        if (
            final_home_bootstrap != home_bootstrap
            or final_home_bootstrap_identity != home_bootstrap_identity
        ):
            raise ValueError("managed home bootstrap changed during validation")
        _verify_private_directory_child(
            profile_descriptor,
            "empty-home-opencode",
            mask_descriptor,
            mask_identity,
            "managed home mask",
        )
        return {
            "schema": 1,
            "version": AUDITED_VERSION,
            "profile_root": profile["profile_root"],
            "fingerprint": fingerprint,
            "config_source": profile["config_source"],
            "auth_source": profile["auth_source"],
            "home_mask_source": profile["home_mask_source"],
        }
    finally:
        for descriptor in (
            opencode_descriptor,
            xdg_descriptor,
            mask_descriptor,
            credentials_descriptor,
            profile_descriptor,
            profiles_descriptor,
            backend_descriptor,
        ):
            if descriptor is not None:
                try:
                    os.close(descriptor)
                except OSError:
                    pass


def _validate_environment_item(name, value):
    _safe_text(name, "environment name")
    _safe_text(value, "environment value", allow_empty=True)


def build_environment(manifest, parent_env):
    if not isinstance(parent_env, dict):
        raise ValueError("parent environment is invalid")
    for name, value in parent_env.items():
        _validate_environment_item(name, value)
    launch = manifest["launch"]
    adapter = launch["env"]
    for name, value in adapter.items():
        _validate_environment_item(name, value)
    backend = launch["backend"]
    if backend == "opencode":
        for name in parent_env:
            if name.startswith("OPENCODE_"):
                raise ValueError("inherited OpenCode environment is forbidden")
        if set(adapter) != OPENCODE_KEYS:
            raise ValueError("adapter environment contains an unexpected OpenCode key")
        for field in (
            "OPENCODE_DISABLE_AUTOUPDATE",
            "OPENCODE_DISABLE_CLAUDE_CODE",
            "OPENCODE_DISABLE_EXTERNAL_SKILLS",
            "OPENCODE_DISABLE_LSP_DOWNLOAD",
            "OPENCODE_DISABLE_PROJECT_CONFIG",
            "OPENCODE_PURE",
        ):
            if adapter[field] != "true":
                raise ValueError("OpenCode environment boolean control changed")
        if adapter["OPENCODE_PERMISSION"] != AUDITED_POLICY_JSON:
            raise ValueError("OpenCode environment permission policy changed")
        if adapter["OPENCODE_SERVER_USERNAME"] != "opencode":
            raise ValueError("OpenCode environment username changed")
        if not _valid_hex(adapter["OPENCODE_SERVER_PASSWORD"], 32):
            raise ValueError("OpenCode environment password is invalid")
        backend_state = manifest["backend_state_dir"]
        expected_paths = {
            "XDG_CACHE_HOME": os.path.join(backend_state, "xdg-cache"),
            "XDG_CONFIG_HOME": os.path.join(backend_state, "xdg-config"),
            "XDG_DATA_HOME": os.path.join(backend_state, "xdg-data"),
            "XDG_STATE_HOME": os.path.join(backend_state, "xdg-state"),
        }
        for field, expected in expected_paths.items():
            if adapter[field] != expected or not _path_within(backend_state, adapter[field]):
                raise ValueError("OpenCode environment XDG path changed")
        _validate_home(parent_env)
    elif backend == "codex":
        if set(adapter) != {"CODEX_HOME"}:
            raise ValueError("adapter environment contains an unexpected key")
        if adapter["CODEX_HOME"] != manifest["backend_state_dir"]:
            raise ValueError("Codex state path changed")
    elif backend == "claude":
        if set(adapter) != {"CLAUDE_CONFIG_DIR"}:
            raise ValueError("adapter environment contains an unexpected key")
        if adapter["CLAUDE_CONFIG_DIR"] != manifest["backend_state_dir"]:
            raise ValueError("Claude state path changed")
    else:
        raise ValueError("adapter environment backend is unsupported")
    result = {name: value for name, value in parent_env.items() if name in PARENT_KEYS}
    result.update(adapter)
    if backend == "opencode":
        # A delayed Kitty graphics reply can reach the still-focused editor
        # through tmux passthrough. Managed OpenCode does not need this probe.
        result["OPENTUI_GRAPHICS"] = "0"
    result.pop("TMUX", None)
    result.pop("TMUX_PANE", None)
    if os.path.realpath(sys.executable) != manifest["python"]:
        raise ValueError("Python executable does not match the running launcher")
    result.update({
        "NVIM_AI_CONTROL_SOCKET": manifest["control_socket"],
        "NVIM_AI_CONTROL_TOKEN": manifest["control_token"],
        "NVIM_AI_CONTROL_HELPER": manifest["control_helper"],
        "NVIM_AI_CONTROL_PYTHON": manifest["python"],
    })
    return result


def _unique_paths(*paths):
    result = []
    seen = set()
    for path in paths:
        if path is not None and path not in seen:
            seen.add(path)
            result.append(path)
    return result


def _git_masks(manifest):
    paths = _unique_paths(
        manifest.get("git_entry"), manifest.get("git_dir"), manifest.get("git_common_dir")
    )
    return sorted(paths, key=lambda value: (-value.count(os.sep), value))


def _mount_destination_record(path, metadata, kind):
    return {
        "path": path,
        "dev": metadata.st_dev,
        "ino": metadata.st_ino,
        "kind": kind,
    }


def _validate_mount_directory_metadata(metadata, label):
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != _current_uid()
        or stat.S_IMODE(metadata.st_mode) != 0o700
    ):
        raise ValueError(label + " has unsafe ownership, mode, or kind")


def _validate_mount_file_metadata(metadata, label):
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != _current_uid()
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or metadata.st_size != 0
    ):
        raise ValueError(label + " has unsafe ownership, mode, kind, or contents")


def _remove_unpublished_mount_node(
    parent_descriptor, name, metadata, kind, label
):
    try:
        current = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        if (
            current.st_dev != metadata.st_dev
            or current.st_ino != metadata.st_ino
            or current.st_uid != _current_uid()
        ):
            raise ValueError(MOUNT_DESTINATION_CLEANUP_ERROR)
        if kind == "file":
            if not stat.S_ISREG(current.st_mode) or current.st_size != 0:
                raise ValueError(MOUNT_DESTINATION_CLEANUP_ERROR)
            os.unlink(name, dir_fd=parent_descriptor)
        else:
            if not stat.S_ISDIR(current.st_mode):
                raise ValueError(MOUNT_DESTINATION_CLEANUP_ERROR)
            os.rmdir(name, dir_fd=parent_descriptor)
    except ValueError:
        raise
    except OSError:
        raise ValueError(MOUNT_DESTINATION_CLEANUP_ERROR) from None


def _open_created_private_directory(parent_descriptor, name, label):
    descriptor = None
    created_metadata = None
    created = False
    try:
        os.mkdir(name, 0o700, dir_fd=parent_descriptor)
        created = True
        descriptor = os.open(name, _directory_flags(), dir_fd=parent_descriptor)
        created_metadata = os.fstat(descriptor)
        os.fchmod(descriptor, 0o700)
        opened = os.fstat(descriptor)
        current = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        _validate_mount_directory_metadata(opened, label)
        if _metadata_identity(opened) != _metadata_identity(current):
            raise ValueError(label + " changed during creation")
        return descriptor, opened
    except FileExistsError:
        raise ValueError(label + " appeared during creation") from None
    except (OSError, ValueError):
        close_failed = False
        if created and created_metadata is None and descriptor is not None:
            try:
                created_metadata = os.fstat(descriptor)
            except OSError:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
                raise ValueError(MOUNT_DESTINATION_CLEANUP_ERROR) from None
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                close_failed = True
        if created_metadata is not None:
            _remove_unpublished_mount_node(
                parent_descriptor,
                name,
                created_metadata,
                "directory",
                label,
            )
        elif created:
            raise ValueError(MOUNT_DESTINATION_CLEANUP_ERROR) from None
        if close_failed:
            raise ValueError("mount destination descriptor close failed") from None
        raise ValueError(label + " could not be created safely") from None


def _validate_existing_mount_file(parent_descriptor, name, label):
    descriptor = None
    try:
        before = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        _validate_mount_file_metadata(before, label)
        flags = os.O_RDONLY | os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(name, flags, dir_fd=parent_descriptor)
        opened = os.fstat(descriptor)
        after = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        _validate_mount_file_metadata(opened, label)
        if (
            _metadata_identity(before) != _metadata_identity(opened)
            or _metadata_identity(opened) != _metadata_identity(after)
        ):
            raise ValueError(label + " changed during validation")
    except ValueError:
        raise
    except OSError:
        raise ValueError(label + " is not a safe private file") from None
    finally:
        if descriptor is not None:
            active_error = sys.exc_info()[0] is not None
            try:
                os.close(descriptor)
            except OSError:
                if not active_error:
                    raise ValueError(
                        "mount destination descriptor close failed"
                    ) from None


def _create_private_mount_file(parent_descriptor, name, path, label, created):
    descriptor = None
    created_metadata = None
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(name, flags, 0o600, dir_fd=parent_descriptor)
        created_metadata = os.fstat(descriptor)
        os.fchmod(descriptor, 0o600)
        opened = os.fstat(descriptor)
        current = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        _validate_mount_file_metadata(opened, label)
        if _metadata_identity(opened) != _metadata_identity(current):
            raise ValueError(label + " changed during creation")
        created.append(_mount_destination_record(path, opened, "file"))
    except FileExistsError:
        raise ValueError(label + " appeared during creation") from None
    except (OSError, ValueError):
        if created_metadata is None and descriptor is not None:
            try:
                created_metadata = os.fstat(descriptor)
            except OSError:
                raise ValueError(MOUNT_DESTINATION_CLEANUP_ERROR) from None
        if created_metadata is not None:
            _remove_unpublished_mount_node(
                parent_descriptor, name, created_metadata, "file", label
            )
        raise ValueError(label + " could not be created safely") from None
    finally:
        if descriptor is not None:
            active_error = sys.exc_info()[0] is not None
            try:
                os.close(descriptor)
            except OSError:
                if not active_error:
                    raise ValueError(
                        "mount destination descriptor close failed"
                    ) from None


def _ensure_private_mount_destination(backend, destination, kind, created):
    destination = _canonical_path(destination, "mount destination")
    if destination == backend or not _path_within(backend, destination):
        raise ValueError("mount destination is outside backend state")
    components = os.path.relpath(destination, backend).split(os.sep)
    current_descriptor = _open_private_directory_path(
        backend, "mount destination root"
    )
    current_path = backend
    try:
        for index, component in enumerate(components):
            leaf = index == len(components) - 1
            path = os.path.join(current_path, component)
            if leaf and kind == "file":
                try:
                    os.stat(
                        component,
                        dir_fd=current_descriptor,
                        follow_symlinks=False,
                    )
                except FileNotFoundError:
                    _create_private_mount_file(
                        current_descriptor,
                        component,
                        path,
                        "mount destination file",
                        created,
                    )
                except OSError:
                    raise ValueError("mount destination file is unsafe") from None
                else:
                    _validate_existing_mount_file(
                        current_descriptor, component, "mount destination file"
                    )
                return

            created_here = False
            try:
                os.stat(
                    component,
                    dir_fd=current_descriptor,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                child_descriptor, metadata = _open_created_private_directory(
                    current_descriptor, component, "mount destination directory"
                )
                created_here = True
            except OSError:
                raise ValueError("mount destination directory is unsafe") from None
            else:
                child_descriptor = _open_private_child(
                    current_descriptor,
                    component,
                    "mount destination directory",
                )
                metadata = os.fstat(child_descriptor)
            if created_here:
                created.append(
                    _mount_destination_record(path, metadata, "directory")
                )
            previous_descriptor = current_descriptor
            current_descriptor = child_descriptor
            current_path = path
            try:
                os.close(previous_descriptor)
            except OSError:
                try:
                    os.close(previous_descriptor)
                except OSError:
                    pass
                raise
    finally:
        active_error = sys.exc_info()[0] is not None
        try:
            os.close(current_descriptor)
        except OSError:
            if not active_error:
                raise ValueError(
                    "mount destination descriptor close failed"
                ) from None


def _rollback_mount_destination(record):
    if (
        not isinstance(record, dict)
        or set(record) != {"path", "dev", "ino", "kind"}
        or record.get("kind") not in ("file", "directory")
        or type(record.get("dev")) is not int
        or type(record.get("ino")) is not int
    ):
        raise ValueError("mount destination cleanup record is invalid")
    try:
        path = _canonical_path(record["path"], "rollback mount destination")
        parent = os.path.dirname(path)
        name = os.path.basename(path)
        parent_descriptor = _open_private_directory_path(
            parent, "rollback mount destination parent"
        )
    except (TypeError, ValueError):
        raise ValueError("mount destination cleanup path is invalid") from None
    try:
        try:
            metadata = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        except FileNotFoundError:
            return
        if metadata.st_dev != record["dev"] or metadata.st_ino != record["ino"]:
            raise ValueError("mount destination cleanup identity changed")
        if record["kind"] == "file":
            _validate_mount_file_metadata(metadata, "rollback mount destination")
            os.unlink(name, dir_fd=parent_descriptor)
        else:
            _validate_mount_directory_metadata(
                metadata, "rollback mount destination"
            )
            os.rmdir(name, dir_fd=parent_descriptor)
    except ValueError:
        raise
    except OSError:
        raise ValueError("mount destination cleanup failed") from None
    finally:
        try:
            os.close(parent_descriptor)
        except OSError:
            pass


def rollback_mount_destinations(created):
    if not isinstance(created, list):
        raise ValueError("mount destination cleanup list is invalid")
    failed = False
    for record in reversed(created):
        try:
            _rollback_mount_destination(record)
        except ValueError:
            failed = True
    if failed:
        raise ValueError(MOUNT_DESTINATION_CLEANUP_ERROR)


def _validate_codex_config(metadata):
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != _current_uid()
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or metadata.st_nlink != 1
        or metadata.st_size > MAX_CODEX_CONFIG_BYTES
    ):
        raise ValueError("Codex private configuration has unsafe metadata")


def _read_codex_config_seed(source):
    before = _validate_owned_node(source, "Codex configuration seed", "file")
    if before.st_nlink != 1 or before.st_size > MAX_CODEX_CONFIG_BYTES:
        raise ValueError("Codex configuration seed has unsafe size or links")
    descriptor = os.open(source, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        if _metadata_identity(before) != _metadata_identity(os.fstat(descriptor)):
            raise ValueError("Codex configuration seed changed")
        chunks, remaining = [], MAX_CODEX_CONFIG_BYTES + 1
        while remaining:
            chunk = os.read(descriptor, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        payload = b"".join(chunks)
        if (
            len(payload) != before.st_size
            or len(payload) > MAX_CODEX_CONFIG_BYTES
            or _metadata_identity(before) != _metadata_identity(os.fstat(descriptor))
            or _metadata_identity(before) != _metadata_identity(os.lstat(source))
        ):
            raise ValueError("Codex configuration seed changed")
        return payload
    finally:
        os.close(descriptor)


def _prepare_codex_config(manifest):
    """Seed once, retaining native trust edits and never writing the global source.

    A zero-byte file from the old read-only mount is an uninitialized seed.
    Publication is atomic; initialized configuration survives later launch failure.
    """
    launch = manifest["launch"]
    if launch["backend"] != "codex":
        return
    backend = manifest["backend_state_dir"]
    descriptor = _open_private_directory_path(backend, "Codex configuration directory")
    temporary = temporary_metadata = output = None
    try:
        anchor = os.fstat(descriptor)
        try:
            existing = os.stat("config.toml", dir_fd=descriptor, follow_symlinks=False)
        except FileNotFoundError:
            existing = None
        if existing is not None:
            _validate_codex_config(existing)
        source = launch.get("config_seed")
        if source is None or (existing is not None and existing.st_size != 0):
            return
        payload = _read_codex_config_seed(source)
        temporary = ".config-seed-" + os.urandom(16).hex()
        output = os.open(
            temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o600, dir_fd=descriptor,
        )
        temporary_metadata = os.fstat(output)
        os.fchmod(output, 0o600)
        remaining = memoryview(payload)
        while remaining:
            written = os.write(output, remaining)
            if written <= 0:
                raise ValueError("Codex configuration seed write failed")
            remaining = remaining[written:]
        os.fsync(output)
        written_metadata = os.fstat(output)
        _validate_codex_config(written_metadata)
        if _metadata_identity(written_metadata) != _metadata_identity(
            os.stat(temporary, dir_fd=descriptor, follow_symlinks=False)
        ):
            raise ValueError("Codex temporary configuration changed before publication")
        os.close(output)
        output = None
        current_anchor = _validate_private_directory(backend, "Codex configuration directory")
        if (anchor.st_dev, anchor.st_ino) != (current_anchor.st_dev, current_anchor.st_ino):
            raise ValueError("Codex configuration directory changed")
        try:
            current = os.stat("config.toml", dir_fd=descriptor, follow_symlinks=False)
        except FileNotFoundError:
            current = None
        if existing is None:
            # No overwrite if a competing initializer published a configuration.
            if current is not None:
                raise ValueError("Codex private configuration appeared during seeding")
            os.link(temporary, "config.toml", src_dir_fd=descriptor, dst_dir_fd=descriptor, follow_symlinks=False)
            os.unlink(temporary, dir_fd=descriptor)
        else:
            if current is None or _metadata_identity(current) != _metadata_identity(existing):
                raise ValueError("Codex private configuration changed during seeding")
            os.replace(temporary, "config.toml", src_dir_fd=descriptor, dst_dir_fd=descriptor)
        temporary = None
        published = os.stat("config.toml", dir_fd=descriptor, follow_symlinks=False)
        _validate_codex_config(published)
        if (published.st_dev, published.st_ino) != (written_metadata.st_dev, written_metadata.st_ino):
            raise ValueError("Codex private configuration changed during publication")
        os.fsync(descriptor)
    except OSError:
        raise ValueError("Codex private configuration could not be seeded safely") from None
    finally:
        try:
            if output is not None:
                os.close(output)
            if temporary is not None and temporary_metadata is not None:
                current = os.stat(temporary, dir_fd=descriptor, follow_symlinks=False)
                if (current.st_dev, current.st_ino) != (temporary_metadata.st_dev, temporary_metadata.st_ino):
                    raise ValueError("Codex temporary configuration changed during cleanup")
                os.unlink(temporary, dir_fd=descriptor)
        finally:
            os.close(descriptor)


def prepare_mount_destinations(manifest, parent_env):
    created = []
    try:
        backend = _canonical_path(
            manifest["backend_state_dir"], "backend state directory"
        )
        _validate_private_directory(backend, "backend state directory")
        launch = manifest["launch"]
        _prepare_codex_config(manifest)
        for item in launch["read_only_inputs"]:
            _ensure_private_mount_destination(
                backend, item["destination"], item["kind"], created
            )
        if launch["backend"] == "opencode":
            build_environment(manifest, parent_env)
            environment = launch["env"]
            for field in (
                "XDG_CACHE_HOME",
                "XDG_CONFIG_HOME",
                "XDG_DATA_HOME",
                "XDG_STATE_HOME",
            ):
                _ensure_private_mount_destination(
                    backend, environment[field], "directory", created
                )
            opencode = os.path.join(environment["XDG_DATA_HOME"], "opencode")
            _ensure_private_mount_destination(
                backend, opencode, "directory", created
            )
            opencode_descriptor = _open_private_directory_path(
                opencode, "isolated OpenCode state"
            )
            try:
                entries = _list_entries(
                    opencode_descriptor, "isolated OpenCode state"
                )
                if "account.json" in entries or "mcp-auth.json" in entries:
                    raise ValueError(
                        "isolated OpenCode state contains forbidden account data"
                    )
            finally:
                os.close(opencode_descriptor)
            _ensure_private_mount_destination(
                backend,
                os.path.join(opencode, "auth.json"),
                "file",
                created,
            )
        return created
    except ValueError:
        try:
            rollback_mount_destinations(created)
        except ValueError:
            raise ValueError(MOUNT_DESTINATION_CLEANUP_ERROR) from None
        raise
    except (KeyError, TypeError, OSError):
        try:
            rollback_mount_destinations(created)
        except ValueError:
            raise ValueError(MOUNT_DESTINATION_CLEANUP_ERROR) from None
        raise ValueError("mount destinations are invalid") from None


def build_bwrap_argv(manifest, launch_argv=None, *, resize_fd=None):
    if launch_argv is None:
        launch_argv = manifest["launch"]["argv"]
    if not launch_argv:
        raise ValueError("a concrete backend argv is required")
    _validate_string_array(launch_argv, "backend argv")
    command = list(launch_argv)
    root = manifest["root"]
    argv = [
        manifest["bwrap"],
        "--new-session",
        "--unshare-pid",
        "--unshare-ipc",
        "--unshare-uts",
        "--die-with-parent",
        "--ro-bind",
        "/",
        "/",
        "--dev",
        "/dev",
        "--proc",
        "/proc",
        "--tmpfs",
        "/tmp",
    ]
    for path in _unique_paths(root, manifest["runtime_root"], manifest["state_root"]):
        if _path_within("/tmp", path):
            argv += ["--dir", path]
    argv += ["--bind" if manifest["writable"] else "--ro-bind", root, root]
    for grant in manifest["grants"]:
        argv += ["--bind" if manifest["writable"] else "--ro-bind", grant, grant]
    trusted = [
        manifest["python"],
        manifest["bwrap"],
        manifest["launcher"],
        manifest["review_helper"],
        manifest["control_helper"],
        manifest["event_helper"],
        manifest["profile_helper"],
        manifest["shell"],
        *manifest["host_tools"],
    ]
    launch_protected = list(manifest["launch"]["protected_paths"])
    if manifest["launch"]["backend"] == "opencode":
        managed_root = manifest["launch"]["managed_profile"]["profile_root"]
        launch_protected = [path for path in launch_protected if path != managed_root]
    protected = _unique_paths(
        manifest["runtime_root"],
        manifest["state_root"],
        *trusted,
        *launch_protected,
    )
    for path in protected:
        argv += ["--ro-bind", path, path]
    argv += ["--bind", manifest["backend_state_dir"], manifest["backend_state_dir"]]
    for item in manifest["launch"]["read_only_inputs"]:
        argv += ["--ro-bind", item["source"], item["destination"]]

    if manifest["launch"]["backend"] == "opencode":
        environment = manifest["launch"]["env"]
        profile = manifest["launch"]["managed_profile"]
        profiles_root = os.path.dirname(profile["profile_root"])
        auth_destination = os.path.join(
            environment["XDG_DATA_HOME"], "opencode", "auth.json"
        )
        home = _validate_home(dict(os.environ))
        argv += ["--ro-bind", profiles_root, profiles_root]
        argv += ["--ro-bind", profile["profile_root"], profile["profile_root"]]
        argv += ["--ro-bind", profile["config_source"], environment["XDG_CONFIG_HOME"]]
        argv += ["--ro-bind", profile["auth_source"], auth_destination]
        argv += [
            "--ro-bind",
            profile["home_mask_source"],
            os.path.join(home, ".opencode"),
        ]
        executable = manifest["launch"]["server_argv"][0]
        if _path_within(os.path.join(home, ".opencode"), executable):
            # Keep the complete home mask. Relocate only the validated file
            # into this launch's private tmpfs; never expose its installation
            # directory or introduce a writable host-side executable copy.
            _validate_executable(executable, "OpenCode executable")
            executable_directory = "/tmp/nvim-ai-exec-" + manifest["token"]
            _canonical_path(executable_directory, "OpenCode execution directory")
            for path in _unique_paths(root, *manifest["grants"], *protected, home):
                if _path_within(path, executable_directory) or _path_within(executable_directory, path):
                    raise ValueError("OpenCode execution directory overlaps a protected path")
            destination = executable_directory + "/opencode"
            argv += ["--dir", executable_directory, "--ro-bind", executable, destination]
            if command[0] == executable:
                command[0] = destination

    for git_path in _git_masks(manifest):
        argv += ["--ro-bind", git_path, git_path]
    argv += ["--ro-bind", manifest["context_dir"], manifest["context_dir"]]
    control_parent = os.path.dirname(manifest["control_socket"])
    argv += ["--ro-bind", control_parent, control_parent]
    if manifest.get("tmux_socket"):
        argv += ["--ro-bind", "/dev/null", manifest["tmux_socket"]]
    argv += ["--chdir", root, "--unsetenv", "TMUX", "--unsetenv", "TMUX_PANE", "--"]
    if resize_fd is not None:
        # Wrap after executable relocation, so a masked OpenCode installation
        # still uses its validated read-only executable in the private tmpfs.
        guard = ["--opencode-size-guard"] if manifest["launch"]["backend"] == "opencode" else []
        command = [
            manifest["python"], "-I", "-B", manifest["launcher"],
            "--resize-fd", str(resize_fd), *guard, "--", *command,
        ]
    argv += command
    return argv


def _manifest_file_metadata(value):
    return {
        "is_symlink": stat.S_ISLNK(value.st_mode),
        "is_regular": stat.S_ISREG(value.st_mode),
        "mode": stat.S_IMODE(value.st_mode),
        "uid": value.st_uid,
        "size": value.st_size,
    }


def consume_manifest(path, *, include_preparation=False):
    path = _canonical_path(path, "manifest path")
    descriptor = None
    created = []
    consumed = False
    try:
        before = os.lstat(path)
        metadata = _manifest_file_metadata(before)
        _validate_manifest_metadata(metadata)
        flags = os.O_RDONLY | os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags)
        opened = os.fstat(descriptor)
        if _metadata_identity(before) != _metadata_identity(opened):
            raise ValueError("manifest changed during validation")
        chunks = []
        remaining = MAX_MANIFEST_BYTES + 1
        while remaining:
            chunk = os.read(descriptor, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        payload = b"".join(chunks)
        final_open = os.fstat(descriptor)
        final_path = os.lstat(path)
        if (
            len(payload) > MAX_MANIFEST_BYTES
            or len(payload) != opened.st_size
            or _metadata_identity(opened) != _metadata_identity(final_open)
            or _metadata_identity(opened) != _metadata_identity(final_path)
        ):
            raise ValueError("manifest changed while reading")
        data = _decode_json_bytes(payload, "manifest")
        validate_manifest(data, metadata)
        build_environment(data, dict(os.environ))
        created = prepare_mount_destinations(data, dict(os.environ))
        validate_managed_profile(data, dict(os.environ))
        current = os.lstat(path)
        if _metadata_identity(opened) != _metadata_identity(current):
            raise ValueError("manifest changed before consumption")
        os.unlink(path)
        consumed = True
        if include_preparation:
            return data, created
        return data
    except ValueError:
        raise
    except (TypeError, KeyError, AttributeError, IndexError):
        raise ValueError("manifest validation failed") from None
    except OSError:
        raise ValueError("manifest could not be consumed safely") from None
    finally:
        cleanup_failed = False
        if not consumed:
            try:
                rollback_mount_destinations(created)
            except ValueError:
                cleanup_failed = True
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
        if cleanup_failed:
            raise ValueError(MOUNT_DESTINATION_CLEANUP_ERROR) from None


def _opencode_event_session(manifest, descriptor):
    # Display only: use the coordinator's binding after rollover, otherwise the
    # first normalized session from this fresh activation's authenticated feed.
    parent = None
    try:
        parent = _open_private_directory_path(
            os.path.join(manifest["state_root"], manifest["identity_key"]), "session directory"
        )
        record = _decode_json_bytes(_read_regular_at(parent, "record.json", MAX_EVENT_BYTES), "session record")
        if (isinstance(record, dict) and record.get("schema") == 1
                and record.get("active_backend") == "opencode"
                and isinstance(record.get("identity"), dict)
                and record["identity"].get("key") == manifest["identity_key"]
                and record["identity"].get("root") == manifest["root"]
                and isinstance(record.get("sessions"), dict)):
            reference = record["sessions"].get("opencode")
            if isinstance(reference, str) and re.fullmatch(r"ses_[A-Za-z0-9_-]{1,124}", reference):
                return reference
    except (OSError, ValueError):
        pass
    finally:
        if parent is not None:
            os.close(parent)
    if os.fstat(descriptor).st_size > MAX_EVENT_BYTES:
        return ""
    for line in os.pread(descriptor, MAX_EVENT_BYTES, 0).split(b"\n")[:-1]:
        if len(line) > 4096:
            continue
        try:
            event = _decode_json_bytes(line, "event")
            if (isinstance(event, dict) and set(event) == {"schema", "backend", "session", "state", "time"}
                    and type(event["schema"]) is int and event["schema"] == 1
                    and event["backend"] == "opencode" and isinstance(event["session"], str)
                    and re.fullmatch(r"ses_[A-Za-z0-9_-]{1,124}", event["session"])
                    and event["state"] in ("idle", "busy", "approval", "completed", "failed")
                    and type(event["time"]) in (int, float) and 0 <= event["time"] <= 9007199254740991):
                return event["session"]
        except ValueError:
            pass
    return ""


def append_event(manifest, state_name):
    if state_name not in ("open", "failed"):
        raise ValueError("event state is invalid")
    launch = manifest["launch"]
    record = {
        "schema": 1,
        "backend": launch["backend"],
        "session": launch["session"],
        "state": state_name,
        "time": int(time.time()),
    }
    _update_event_file(manifest, record)


def _update_event_file(manifest, record):
    path = manifest["event_file"]
    before = _validate_private_file(path, "event file")
    descriptor = None
    try:
        flags = os.O_RDWR | os.O_APPEND | os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        metadata = os.fstat(descriptor)
        if (not stat.S_ISREG(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o600
                or metadata.st_uid != _current_uid() or metadata.st_nlink != 1
                or metadata.st_ino != before.st_ino or metadata.st_dev != before.st_dev):
            raise ValueError("event file changed or is unsafe")
        if record is None:
            os.ftruncate(descriptor, 0)
            os.fsync(descriptor)
            return
        if record["backend"] == "opencode" and record["session"] == "" and record["state"] == "failed":
            record["session"] = _opencode_event_session(manifest, descriptor)
        payload = (_compact_json(record) + "\n").encode("utf-8")
        if len(payload) > 1024:
            raise ValueError("event record is too large")
        if metadata.st_size + len(payload) > MAX_EVENT_BYTES:
            os.ftruncate(descriptor, 0)
        if os.write(descriptor, payload) != len(payload):
            raise ValueError("event record could not be appended")
        os.fsync(descriptor)
    except ValueError:
        raise
    except OSError:
        raise ValueError("event record could not be appended") from None
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass


def _open_server_output(path):
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags, 0o600)
        os.fchmod(descriptor, 0o600)
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != _current_uid()
            or stat.S_IMODE(metadata.st_mode) != 0o600
        ):
            raise ValueError("server output file is unsafe")
        return descriptor
    except ValueError:
        if "descriptor" in locals():
            os.close(descriptor)
        raise
    except OSError:
        raise ValueError("server output file cannot be opened") from None


def _forward_signal(number, _frame):
    if number == signal.SIGWINCH:
        # Only readiness bytes cross this private pipe: no terminal input,
        # dimensions, process IDs, or authority to signal a host process.
        for descriptor in list(_RESIZE_WRITERS.values()):
            _notify_resize(descriptor)
        return
    for child in list(_ACTIVE_CHILDREN):
        try:
            if child.poll() is None:
                child.send_signal(number)
        except OSError:
            pass


def _install_signal_handlers():
    for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGWINCH):
        signal.signal(number, _forward_signal)


def _notify_resize(descriptor):
    try:
        os.write(descriptor, b"\0")
    except OSError:
        # A full pipe already has a pending redraw; a closed reader belongs to
        # an exiting launch. Never block the terminal's signal handler.
        pass


def _start_terminal_child(manifest, command, environment):
    reader, writer = os.pipe2(os.O_CLOEXEC | os.O_NONBLOCK)
    try:
        argv = build_bwrap_argv(manifest, command, resize_fd=reader)
        # Bubblewrap passes explicitly inherited extra descriptors to COMMAND,
        # while closing them in its monitor/reaper. The native CLI never gets it.
        child = _start_child(argv, environment, pass_fds=(reader,))
        _RESIZE_WRITERS[child] = writer
        writer = None
        _notify_resize(_RESIZE_WRITERS[child])
        return child
    finally:
        os.close(reader)
        if writer is not None:
            os.close(writer)


def _opencode_pane_safe():
    try:
        size = os.get_terminal_size(1)
    except OSError:
        return False
    return size.columns >= OPENCODE_MIN_COLUMNS and size.lines > 0


def _run_terminal_relay(descriptor, command, *, opencode=False):
    """Forward resize notices only to our unreaped child inside the sandbox."""
    child = None
    try:
        if (
            descriptor < 3
            or not stat.S_ISFIFO(os.fstat(descriptor).st_mode)
            or fcntl.fcntl(descriptor, fcntl.F_GETFL) & os.O_ACCMODE != os.O_RDONLY
            or os.getppid() != 1
            or os.getsid(0) != 1
            or os.getpgid(0) != 1
            or not command
            or not os.path.isabs(command[0])
        ):
            raise ValueError("terminal resize relay boundary is invalid")
        if opencode and not _opencode_pane_safe():
            return OPENCODE_SIZE_EXIT
        # A separate owned group lets renderer subprocesses receive SIGWINCH
        # too. There is still no controlling host terminal (TIOCSTI isolation).
        child = _start_child(command, dict(os.environ), start_new_session=True)
        while child.poll() is None:
            readable, _, _ = select.select([descriptor], [], [], 0.1)
            if not readable:
                continue
            if not os.read(descriptor, 4096):
                break
            if child.poll() is None:
                if opencode and not _opencode_pane_safe():
                    # Stop our owned child without forwarding the unsafe
                    # dimensions. The outer launcher retains review/session
                    # state and presents a passive diagnostic after cleanup.
                    return OPENCODE_SIZE_EXIT
                # This direct child cannot have its PID reused until *we* reap
                # it. No wait/poll or SIGCHLD handler runs between here and killpg.
                try:
                    os.killpg(child.pid, signal.SIGWINCH)
                except ProcessLookupError:
                    pass
        code = child.returncode
        return (128 - code if code < 0 else code) if code is not None else 1
    finally:
        os.close(descriptor)
        _terminate_children(child)


def _start_child(argv, environment, **options):
    child = subprocess.Popen(
        argv,
        env=environment,
        close_fds=True,
        **options,
    )
    _ACTIVE_CHILDREN.append(child)
    return child


def _forget_child(child):
    # Remove before closing: a reentrant SIGWINCH must never write through a
    # descriptor number that could already have been reused for another file.
    descriptor = _RESIZE_WRITERS.pop(child, None)
    if descriptor is not None:
        os.close(descriptor)
    try:
        _ACTIVE_CHILDREN.remove(child)
    except ValueError:
        pass


def _wait_for_server(server, port):
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        if server.poll() is not None:
            raise ValueError("managed server exited before attachment")
        try:
            connection = socket.create_connection(("127.0.0.1", port), timeout=0.1)
            connection.close()
            return
        except OSError:
            time.sleep(0.05)
    raise ValueError("managed server did not become ready")


def _terminate_child(child):
    if child is None:
        return
    cleanup_failed = False
    confirmed = False
    try:
        confirmed = child.poll() is not None
    except OSError:
        cleanup_failed = True
    if not confirmed:
        try:
            child.terminate()
        except OSError:
            cleanup_failed = True
        try:
            child.wait(timeout=2.0)
            confirmed = True
        except subprocess.TimeoutExpired:
            pass
        except OSError:
            cleanup_failed = True
    if not confirmed:
        try:
            child.kill()
        except OSError:
            cleanup_failed = True
        try:
            child.wait(timeout=2.0)
            confirmed = True
        except (OSError, subprocess.TimeoutExpired):
            cleanup_failed = True
    if confirmed:
        _forget_child(child)
    if cleanup_failed or not confirmed:
        raise ValueError(CHILD_CLEANUP_ERROR)


def _terminate_children(*children):
    cleanup_failed = False
    for child in children:
        try:
            _terminate_child(child)
        except ValueError:
            cleanup_failed = True
    if cleanup_failed:
        raise ValueError(CHILD_CLEANUP_ERROR)


def _append_failed_event(manifest):
    try:
        append_event(manifest, "failed")
    except (OSError, ValueError):
        pass


class _PromptBroker:
    """One live activation's private append-only channel; never a prompt queue."""

    def __init__(self, manifest, server, attach):
        self.manifest, self.server, self.attach = manifest, server, attach
        self.parent = self.listener = self.identity = None
        self.path = os.path.join(os.path.dirname(manifest["control_socket"]), "prompt.sock")
        if len(os.fsencode(self.path)) > 107:
            raise ValueError("prompt socket path is too long")
        try:
            self.parent = _open_private_directory_path(os.path.dirname(self.path), "prompt directory")
            try:
                old = os.stat("prompt.sock", dir_fd=self.parent, follow_symlinks=False)
            except FileNotFoundError:
                old = None
            if old is not None:
                if not self._private_socket(old):
                    raise ValueError("prompt socket is unsafe")
                with socket.socket(socket.AF_UNIX) as probe:
                    probe.settimeout(.1)
                    try:
                        probe.connect(self.path)
                    except ConnectionRefusedError:
                        if self._same(old):
                            os.unlink("prompt.sock", dir_fd=self.parent)
                        else:
                            raise ValueError("prompt socket changed") from None
                    else:
                        raise ValueError("prompt socket is already live")
            self.listener = socket.socket(socket.AF_UNIX)
            # Bind through the already validated directory descriptor. Renaming
            # an ancestor cannot redirect creation into a different directory.
            self.listener.bind("/proc/self/fd/" + str(self.parent) + "/prompt.sock")
            self.identity = os.stat("prompt.sock", dir_fd=self.parent, follow_symlinks=False)
            os.chmod("prompt.sock", 0o600, dir_fd=self.parent, follow_symlinks=False)
            self.listener.listen(1)
            self.listener.settimeout(.05)
        except Exception:
            self.close()
            raise

    @staticmethod
    def _private_socket(value):
        return (stat.S_ISSOCK(value.st_mode) and value.st_uid == os.getuid()
                and stat.S_IMODE(value.st_mode) == 0o600)

    def _same(self, expected):
        try:
            actual = os.stat("prompt.sock", dir_fd=self.parent, follow_symlinks=False)
            return (stat.S_ISSOCK(actual.st_mode) and actual.st_uid == os.getuid()
                    and (actual.st_dev, actual.st_ino) == (expected.st_dev, expected.st_ino))
        except OSError:
            return False

    def close(self):
        if self.listener is not None:
            self.listener.close()
            self.listener = None
        if self.parent is not None:
            try:
                if self.identity is not None and self._same(self.identity):
                    os.unlink("prompt.sock", dir_fd=self.parent)
            finally:
                os.close(self.parent)
                self.parent = None

    def alive(self):
        return self.server.poll() is None and self.attach is not None and self.attach.poll() is None

    def poll(self):
        try:
            client, _ = self.listener.accept()
        except TimeoutError:
            return
        with client:
            try:
                client.settimeout(.5)
                # The challenge binds the single connection to this activation.
                # No HTTP password, context, or durable credentials are published.
                challenge = ":".join((self.manifest["token"], self.manifest["identity_key"],
                                      self.manifest["review_id"])) + "\n"
                client.sendall(challenge.encode("ascii"))
                deadline, data = time.monotonic() + .5, b""
                while b"\n" not in data and len(data) <= 8192:
                    client.settimeout(max(.001, deadline - time.monotonic()))
                    block = client.recv(min(2048, 8193 - len(data)))
                    if not block or time.monotonic() >= deadline:
                        return
                    data += block
                result = "refused"
                if len(data) <= 8192 and data.endswith(b"\n") and data.count(b"\n") == 1:
                    request = _decode_json_bytes(data, "prompt request")
                    if self._valid(request) and self.alive():
                        result = self._append(request["text"])
                client.sendall((result + "\n").encode("ascii"))
            except (OSError, ValueError, UnicodeError):
                # Malformed/local-disconnected clients get no retry or HTTP fallback.
                return

    def _valid(self, request):
        if (not isinstance(request, dict)
                or set(request) != {"schema", "token", "launch", "review_id", "text"}
                or type(request["schema"]) is not int or request["schema"] != 1
                or not _valid_hex(request["token"], 32)
                or not hmac.compare_digest(request["token"], self.manifest["control_token"])
                or request["launch"] != self.manifest["token"]
                or request["review_id"] != self.manifest["review_id"]):
            return False
        text = request["text"]
        return (isinstance(text, str) and 0 < len(text.encode("utf-8")) <= 2048
                and not any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in text))

    def _append(self, text):
        port = int(self.manifest["launch"]["server_argv"][6])
        password = self.manifest["launch"]["env"]["OPENCODE_SERVER_PASSWORD"]
        authorization = base64.b64encode(("opencode:" + password).encode("ascii"))
        body = _compact_json({"text": text}).encode("utf-8")
        request = (b"POST /tui/append-prompt HTTP/1.1\r\nHost: 127.0.0.1:" + str(port).encode()
                   + b"\r\nAuthorization: Basic " + authorization
                   + b"\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: "
                   + str(len(body)).encode() + b"\r\n\r\n" + body)
        sent, deadline = False, time.monotonic() + 1
        try:
            # Literal loopback only: no DNS, proxy settings, redirects, or retries.
            with socket.create_connection(("127.0.0.1", port), timeout=.2) as connection:
                if not self.alive():
                    return "refused"
                connection.settimeout(max(.001, deadline - time.monotonic()))
                sent = True  # A write failure can still mean partial/publication delivery.
                connection.sendall(request)
                data = b""
                while len(data) <= 8192 and time.monotonic() < deadline:
                    connection.settimeout(max(.001, deadline - time.monotonic()))
                    block = connection.recv(min(2048, 8193 - len(data)))
                    if not block:
                        break
                    data += block
                    if b"\r\n\r\n" in data:
                        result = self._response(data)
                        if result:
                            return result
        except OSError:
            pass
        return "uncertain" if sent else "refused"

    @staticmethod
    def _response(data):
        class BufferedSocket:
            def makefile(self, *_):
                return io.BytesIO(data)

        try:
            with http.client.HTTPResponse(BufferedSocket()) as response:
                response.begin()
                if response.status != 200:
                    return "uncertain"
                if not response.chunked:
                    if response.length is None:
                        return None
                    if response.length > 32:
                        return "uncertain"
                    if len(data.split(b"\r\n\r\n", 1)[1]) < response.length:
                        return None
                body = response.read(33)
                if len(body) > 32:
                    return "uncertain"
                if response.isclosed():
                    return "published" if body.strip() == b"true" else "uncertain"
        except (http.client.HTTPException, ValueError):
            pass
        return None


def run_backend(manifest, environment, on_start=None):
    if on_start is None:
        on_start = lambda: None
    if not callable(on_start):
        raise ValueError("backend start callback is invalid")
    launch = manifest["launch"]
    if launch["kind"] == "direct":
        child = None
        try:
            child = _start_terminal_child(manifest, launch["argv"], environment)
            on_start()
            append_event(manifest, "open")
            code = child.wait()
            _forget_child(child)
            if code != 0:
                append_event(manifest, "failed")
            return code
        except (OSError, ValueError):
            cleanup_failed = False
            if child is not None and child in _ACTIVE_CHILDREN:
                try:
                    _terminate_children(child)
                except ValueError:
                    cleanup_failed = True
            _append_failed_event(manifest)
            if cleanup_failed:
                raise ValueError(CHILD_CLEANUP_ERROR) from None
            raise ValueError("managed backend could not run") from None

    server = attach = event_reader = prompt = None
    stdout_descriptor = stderr_descriptor = None
    failed_event_attempted = False
    try:
        if launch["session"] == "":
            # Reset only for a new session, before this activation has writers.
            _update_event_file(manifest, None)
        server_argv = build_bwrap_argv(manifest, launch["server_argv"])
        stdout_path = os.path.join(
            manifest["backend_state_dir"], "server-" + manifest["token"] + ".stdout"
        )
        stderr_path = os.path.join(
            manifest["backend_state_dir"], "server-" + manifest["token"] + ".stderr"
        )
        stdout_descriptor = _open_server_output(stdout_path)
        stderr_descriptor = _open_server_output(stderr_path)
        server = _start_child(
            server_argv,
            environment,
            stdin=subprocess.DEVNULL,
            stdout=stdout_descriptor,
            stderr=stderr_descriptor,
        )
        on_start()
        os.close(stdout_descriptor)
        stdout_descriptor = None
        os.close(stderr_descriptor)
        stderr_descriptor = None
        port = int(launch["server_argv"][6])
        _wait_for_server(server, port)
        event_reader = _start_child(
            [manifest["python"], "-I", "-B", manifest["event_helper"], "opencode-stream",
             "--event-url", launch["event_url"], "--event-file", manifest["event_file"],
             "--parent-pid", str(os.getpid())],
            environment, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if manifest["writable"]:
            prompt = _PromptBroker(manifest, server, None)
        attach = _start_terminal_child(manifest, launch["attach_argv"], environment)
        append_event(manifest, "open")
        if prompt is not None:
            prompt.attach = attach
            while attach.poll() is None:
                if server.poll() is not None:
                    raise ValueError("managed prompt server exited")
                prompt.poll()
            code = attach.returncode
        else:
            code = attach.wait()
        _forget_child(attach)
        attach = None
        if code != 0:
            append_event(manifest, "failed")
        return code
    except (OSError, ValueError):
        _append_failed_event(manifest)
        failed_event_attempted = True
        raise ValueError("managed server or attach client could not run") from None
    finally:
        cleanup_failed = False
        if prompt is not None:
            try:
                prompt.close()
            except OSError:
                cleanup_failed = True
        for descriptor in (stdout_descriptor, stderr_descriptor):
            if descriptor is not None:
                try:
                    os.close(descriptor)
                except OSError:
                    cleanup_failed = True
        try:
            _terminate_children(attach, event_reader, server)
        except ValueError:
            cleanup_failed = True
        if cleanup_failed:
            if not failed_event_attempted:
                _append_failed_event(manifest)
            raise ValueError(CHILD_CLEANUP_ERROR) from None


def _bounded_diagnostic(message):
    cleaned = "".join(
        " " if ord(character) <= 31 or 127 <= ord(character) <= 159 else character
        for character in message
    )
    encoded = " ".join(cleaned.split()).encode("utf-8")[:256]
    while encoded:
        try:
            return encoded.decode("utf-8")
        except UnicodeError:
            encoded = encoded[:-1]
    return "launch failed"


def _restore_signal_handlers():
    for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGWINCH):
        signal.signal(number, signal.SIG_DFL)


def _fixed_wait():
    _restore_signal_handlers()
    while True:
        signal.pause()


def _capture_terminal():
    try:
        if not os.isatty(0) or not os.isatty(1):
            return None
        source, output = os.fstat(0), os.fstat(1)
        identity = (source.st_dev, source.st_ino, source.st_rdev)
        if identity != (output.st_dev, output.st_ino, output.st_rdev):
            return None
        return identity, termios.tcgetattr(0)
    except (OSError, termios.error):
        return None


def _restore_terminal(terminal):
    if terminal is None:
        return True
    try:
        identity, attributes = terminal
        for descriptor in (0, 1):
            current = os.fstat(descriptor)
            if (current.st_dev, current.st_ino, current.st_rdev) != identity:
                return False
        termios.tcsetattr(0, termios.TCSANOW, attributes)
        termios.tcflush(0, termios.TCIFLUSH)
        # Reset only this inherited PTY, never /dev/tty or the owning editor.
        # End synchronized output/alternate screen, then VT full reset clears
        # mouse, focus, paste and extended-key modes left by a crashed renderer.
        reset = b"\x1b[?2026l\x1b[?1049l\x1bc"
        while reset:
            written = os.write(1, reset)
            if written <= 0:
                return False
            reset = reset[written:]
        return True
    except (OSError, termios.error):
        return False


def diagnostic_fallback(manifest, environment, diagnostic, *, terminal=None):
    _restore_signal_handlers()
    if not _restore_terminal(terminal):
        print("nvim-ai-launch: terminal cleanup unavailable", file=sys.stderr, flush=True)
    print(_bounded_diagnostic(diagnostic), file=sys.stderr, flush=True)
    print("No shell is running. Reopen or close the companion from Neovim.",
          file=sys.stderr, flush=True)
    # A failed pane is a diagnostic, not a command interpreter. In particular,
    # late terminal replies cannot execute shell syntax or load login hooks.
    _fixed_wait()


def main(argv=None):
    parser = argparse.ArgumentParser(prog="nvim-ai-launch.py")
    parser.add_argument("--manifest", required=True)
    arguments = parser.parse_args(argv)
    _install_signal_handlers()
    terminal = _capture_terminal()
    manifest = None
    environment = None
    created = []
    started = False

    def mark_started():
        nonlocal started
        started = True

    try:
        try:
            manifest, created = consume_manifest(
                arguments.manifest, include_preparation=True
            )
            environment = build_environment(manifest, dict(os.environ))
        except (TypeError, KeyError, AttributeError, IndexError):
            raise ValueError("launch validation failed") from None
        code = run_backend(manifest, environment, on_start=mark_started)
        diagnostic = "nvim-ai-launch: managed backend exited with code " + str(code)
        if manifest["launch"]["backend"] == "opencode" and code == OPENCODE_SIZE_EXIT:
            diagnostic = (
                "nvim-ai-launch: OpenCode needs at least " + str(OPENCODE_MIN_COLUMNS)
                + " columns. Widen the pane, then reopen from Neovim."
            )
        diagnostic_fallback(
            manifest,
            environment,
            diagnostic,
            terminal=terminal,
        )
    except ValueError as error:
        if _ACTIVE_CHILDREN:
            print(
                _bounded_diagnostic(
                    "nvim-ai-launch: managed child cleanup failed"
                ),
                file=sys.stderr,
                flush=True,
            )
            return 1
        if started and manifest is not None and environment is not None:
            diagnostic_fallback(
                manifest,
                environment,
                "nvim-ai-launch: managed backend failed",
                terminal=terminal,
            )
        cleanup_failed = str(error) == MOUNT_DESTINATION_CLEANUP_ERROR
        try:
            rollback_mount_destinations(created)
        except ValueError:
            cleanup_failed = True
        diagnostic = (
            "nvim-ai-launch: destination cleanup failed"
            if cleanup_failed
            else "nvim-ai-launch: launch refused"
        )
        # Publishing the refusal is the observer's shutdown-ready boundary.
        # Restore defaults first so an immediate signal cannot be swallowed by
        # the now-childless forwarding handler before entering the fixed wait.
        _restore_signal_handlers()
        print(_bounded_diagnostic(diagnostic), file=sys.stderr, flush=True)
        _fixed_wait()
    return 1


if __name__ == "__main__":
    if len(sys.argv) >= 5 and sys.argv[1] == "--resize-fd":
        try:
            guarded = sys.argv[3] == "--opencode-size-guard"
            separator = 4 if guarded else 3
            if len(sys.argv) <= separator + 1 or sys.argv[separator] != "--":
                raise ValueError("terminal resize relay arguments are invalid")
            raise SystemExit(_run_terminal_relay(
                int(sys.argv[2]), sys.argv[separator + 1:], opencode=guarded
            ))
        except (OSError, ValueError):
            print("nvim-ai-launch: terminal resize relay failed", file=sys.stderr, flush=True)
            raise SystemExit(1)
    raise SystemExit(main())
