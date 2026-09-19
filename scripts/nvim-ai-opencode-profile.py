"""Build and inspect private credentials-only OpenCode profiles."""

import argparse
import ctypes
import hashlib
import json
import os
import pathlib
import stat
import sys

AUDITED_VERSION = "1.18.30"
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

MAX_PROVIDERS = 128
MAX_PROVIDER_BYTES = 256
MAX_CREDENTIAL_BYTES = 256 * 1024
MAX_METADATA_ENTRIES = 128
MAX_METADATA_BYTES = 8 * 1024
MAX_SOURCE_BYTES = 256 * 1024
MAX_SNAPSHOT_BYTES = 512 * 1024
MAX_JSON_BYTES = 1024 * 1024
MAX_CLI_REPORT_BYTES = 64 * 1024
MAX_DIAGNOSTIC_BYTES = 256

_RENAME_NOREPLACE = 1

_HEX = frozenset("0123456789abcdef")
_PREPARE_KEYS = frozenset(
    (
        "schema",
        "token",
        "identity_key",
        "root",
        "backend_state",
        "global_auth",
        "user_agents",
        "repo_agents",
        "version",
        "config_json",
        "policy_json",
    )
)
_INSPECT_PROFILE_KEYS = frozenset(
    (
        "schema",
        "backend_state",
        "token",
        "identity_key",
        "root",
        "version",
        "fingerprint",
    )
)


def _duplicate_rejecting_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON key")
        value[key] = item
    return value


def _reject_constant(_value):
    raise ValueError("invalid JSON value")


def _decode_json(document):
    if not isinstance(document, str):
        raise ValueError("JSON input must be text")
    try:
        return json.loads(
            document,
            object_pairs_hook=_duplicate_rejecting_object,
            parse_constant=_reject_constant,
        )
    except ValueError as error:
        if "duplicate" in str(error):
            raise ValueError("duplicate JSON key") from None
        raise ValueError("invalid JSON document") from None
    except (TypeError, UnicodeError, RecursionError):
        raise ValueError("invalid JSON document") from None


def _encode_compact(value):
    try:
        return json.dumps(
            value,
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
    except (TypeError, ValueError, UnicodeError, RecursionError):
        raise ValueError("value is not valid JSON") from None


def _exact_object(value, required, optional=(), label="object"):
    if not isinstance(value, dict):
        raise ValueError(label + " must be an object")
    keys = set(value)
    allowed = set(required) | set(optional)
    if not set(required).issubset(keys):
        raise ValueError(label + " is missing a field")
    if not keys.issubset(allowed):
        raise ValueError(label + " contains an unknown field")
    return value


def _utf8_bytes(value, label):
    if not isinstance(value, str):
        raise ValueError(label + " must be text")
    try:
        return value.encode("utf-8")
    except UnicodeError:
        raise ValueError(label + " is not valid UTF-8") from None


def _has_control(value):
    return any(
        ord(character) <= 31 or 127 <= ord(character) <= 159 for character in value
    )


def _bounded_secret(value, maximum, label):
    encoded = _utf8_bytes(value, label)
    if len(encoded) > maximum or "\x00" in value:
        raise ValueError(label + " is invalid")
    return value


def _normalized_provider(value):
    encoded = _utf8_bytes(value, "provider identifier")
    if not encoded or len(encoded) > MAX_PROVIDER_BYTES or _has_control(value):
        raise ValueError("provider identifier is invalid")
    normalized = value.rstrip("/")
    normalized_bytes = _utf8_bytes(normalized, "provider identifier")
    if not normalized_bytes or len(normalized_bytes) > MAX_PROVIDER_BYTES:
        raise ValueError("provider identifier is invalid")
    return normalized


def _sorted_utf8(values):
    return sorted(values, key=lambda value: value.encode("utf-8"))


def _metadata(value):
    if not isinstance(value, dict) or len(value) > MAX_METADATA_ENTRIES:
        raise ValueError("credential metadata is invalid")
    result = {}
    for key in _sorted_utf8(value):
        _bounded_secret(key, MAX_METADATA_BYTES, "credential metadata key")
        result[key] = _bounded_secret(
            value[key], MAX_METADATA_BYTES, "credential metadata value"
        )
    return result


def _api_record(value):
    _exact_object(value, ("type", "key"), ("metadata",), "API credential")
    if value["type"] != "api":
        raise ValueError("API credential type is invalid")
    result = {
        "type": "api",
        "key": _bounded_secret(value["key"], MAX_CREDENTIAL_BYTES, "API credential"),
    }
    if "metadata" in value:
        result["metadata"] = _metadata(value["metadata"])
    return result


def _oauth_record(value):
    _exact_object(
        value,
        ("type", "refresh", "access", "expires"),
        ("accountId", "enterpriseUrl"),
        "OAuth credential",
    )
    if value["type"] != "oauth":
        raise ValueError("OAuth credential type is invalid")
    expires = value["expires"]
    if isinstance(expires, bool) or not isinstance(expires, int) or expires < 0:
        raise ValueError("OAuth credential expiry is invalid")
    result = {
        "type": "oauth",
        "refresh": _bounded_secret(
            value["refresh"], MAX_CREDENTIAL_BYTES, "OAuth refresh credential"
        ),
        "access": _bounded_secret(
            value["access"], MAX_CREDENTIAL_BYTES, "OAuth access credential"
        ),
        "expires": expires,
    }
    if "accountId" in value:
        result["accountId"] = _bounded_secret(
            value["accountId"], MAX_CREDENTIAL_BYTES, "OAuth account identifier"
        )
    if "enterpriseUrl" in value:
        result["enterpriseUrl"] = _bounded_secret(
            value["enterpriseUrl"], MAX_CREDENTIAL_BYTES, "OAuth enterprise URL"
        )
    return result


def _filter_auth_value(source):
    if not isinstance(source, dict):
        raise ValueError("authentication root must be an object")
    if len(source) > MAX_PROVIDERS:
        raise ValueError("authentication has too many providers")
    normalized = {}
    for identifier, record in source.items():
        provider = _normalized_provider(identifier)
        if provider in normalized:
            raise ValueError("provider identifiers collide after normalization")
        if not isinstance(record, dict):
            raise ValueError("credential record must be an object")
        record_type = record.get("type")
        if record_type == "wellknown":
            normalized[provider] = None
        elif record_type == "api":
            normalized[provider] = _api_record(record)
        elif record_type == "oauth":
            normalized[provider] = _oauth_record(record)
        else:
            raise ValueError("credential record type is unsupported")
    result = {}
    for provider in _sorted_utf8(normalized):
        if normalized[provider] is not None:
            result[provider] = normalized[provider]
    encoded = _encode_compact(result) + b"\n"
    if len(encoded) > MAX_JSON_BYTES:
        raise ValueError("filtered authentication is too large")
    return result, encoded


def filter_auth(document):
    result, _encoded = _filter_auth_value(_decode_json(document))
    return result


def _canonical_path(value, label, allow_root=False):
    encoded = _utf8_bytes(value, label)
    path_value = pathlib.Path(value) if isinstance(value, str) else None
    if (
        not encoded
        or len(encoded) > 4096
        or "\x00" in value
        or _has_control(value)
        or path_value is None
        or not path_value.is_absolute()
        or os.path.normpath(value) != value
        or (value == "/" and not allow_root)
    ):
        raise ValueError(label + " must be an absolute canonical path")
    try:
        resolved = os.path.realpath(value)
    except (OSError, ValueError):
        raise ValueError(label + " cannot be resolved") from None
    if resolved != value:
        raise ValueError(label + " must not contain a symlink")
    return value


def _file_metadata(value):
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_uid,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def _validate_file_metadata(value, maximum, policy):
    if not stat.S_ISREG(value.st_mode) or value.st_uid != os.getuid():
        raise ValueError("source file is unsafe")
    mode = stat.S_IMODE(value.st_mode)
    if policy == "credential":
        if mode != 0o600:
            raise ValueError("credential file is unsafe")
    elif mode & 0o022:
        raise ValueError("instruction file is unsafe")
    if value.st_size < 0 or value.st_size > maximum:
        raise ValueError("source file is too large")


def _secure_read_path(path, maximum, policy, missing_ok):
    _canonical_path(path, "source path")
    try:
        before = os.lstat(path)
    except FileNotFoundError:
        if missing_ok:
            return None, None
        raise ValueError("source file is missing") from None
    except OSError:
        raise ValueError("source file cannot be inspected") from None
    _validate_file_metadata(before, maximum, policy)

    flags = os.O_RDONLY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError:
        raise ValueError("source file cannot be opened") from None
    try:
        opened = os.fstat(descriptor)
        _validate_file_metadata(opened, maximum, policy)
        if _file_metadata(before) != _file_metadata(opened):
            raise ValueError("source file changed during validation")
        chunks = []
        length = 0
        while length <= maximum:
            chunk = os.read(descriptor, min(65536, maximum + 1 - length))
            if not chunk:
                break
            chunks.append(chunk)
            length += len(chunk)
        if length > maximum:
            raise ValueError("source file is too large")
        after_read = os.fstat(descriptor)
        _validate_file_metadata(after_read, maximum, policy)
        if _file_metadata(opened) != _file_metadata(after_read):
            raise ValueError("source file changed during read")
    except OSError:
        raise ValueError("source file cannot be read") from None
    finally:
        try:
            os.close(descriptor)
        except OSError:
            pass
    try:
        after_close = os.lstat(path)
    except OSError:
        raise ValueError("source file changed during read") from None
    _validate_file_metadata(after_close, maximum, policy)
    if _file_metadata(after_read) != _file_metadata(after_close):
        raise ValueError("source file changed during read")
    return b"".join(chunks), (after_read.st_dev, after_read.st_ino)


def _decode_auth_bytes(payload):
    try:
        document = payload.decode("utf-8")
    except UnicodeError:
        raise ValueError("authentication is not valid UTF-8") from None
    return _filter_auth_value(_decode_json(document))


def inspect_auth(path):
    payload, _identity = _secure_read_path(
        path, MAX_JSON_BYTES, "credential", missing_ok=True
    )
    if payload is None:
        return {"auth": "unauthenticated", "count": 0}
    filtered, _encoded = _decode_auth_bytes(payload)
    return {
        "auth": "authenticated" if filtered else "unauthenticated",
        "count": len(filtered),
    }


def _valid_hex(value, length):
    return (
        isinstance(value, str)
        and len(value) == length
        and all(character in _HEX for character in value)
    )


def _validate_prepare_request(request):
    _exact_object(request, _PREPARE_KEYS, label="prepare request")
    if isinstance(request["schema"], bool) or request["schema"] != 1:
        raise ValueError("prepare schema is unsupported")
    if not _valid_hex(request["token"], 32):
        raise ValueError("profile token is invalid")
    if not _valid_hex(request["identity_key"], 32):
        raise ValueError("identity key is invalid")
    if request["version"] != AUDITED_VERSION:
        raise ValueError("OpenCode version is unsupported")
    if request["config_json"] != AUDITED_CONFIG_JSON:
        raise ValueError("managed configuration is not canonical")
    if request["policy_json"] != AUDITED_POLICY_JSON:
        raise ValueError("managed policy is not canonical")

    policy = _decode_json(request["policy_json"])
    configuration = _decode_json(request["config_json"])
    if not isinstance(configuration, dict) or configuration.get("permission") != policy:
        raise ValueError("managed policy does not match configuration")

    validated = dict(request)
    validated["root"] = _canonical_path(request["root"], "physical root")
    validated["backend_state"] = _canonical_path(
        request["backend_state"], "backend state"
    )
    validated["global_auth"] = _canonical_path(
        request["global_auth"], "global authentication"
    )
    validated["user_agents"] = _canonical_path(
        request["user_agents"], "user instructions"
    )
    validated["repo_agents"] = _canonical_path(
        request["repo_agents"], "repository instructions"
    )
    if request["repo_agents"] != os.path.join(request["root"], "AGENTS.md"):
        raise ValueError("repository instructions path is invalid")
    return validated


def _instruction_bytes(payload, label):
    if payload is None:
        return None
    if b"\x00" in payload:
        raise ValueError(label + " contain a NUL byte")
    try:
        payload.decode("utf-8")
    except UnicodeError:
        raise ValueError(label + " are not valid UTF-8") from None
    return payload


def _build_instruction_snapshot(user_path, repository_path):
    user_bytes, user_identity = _secure_read_path(
        user_path, MAX_SOURCE_BYTES, "instruction", missing_ok=True
    )
    repository_bytes, repository_identity = _secure_read_path(
        repository_path, MAX_SOURCE_BYTES, "instruction", missing_ok=True
    )
    user_bytes = _instruction_bytes(user_bytes, "user instructions")
    repository_bytes = _instruction_bytes(repository_bytes, "repository instructions")

    sources = []
    if user_bytes is not None:
        sources.append((b"# User instructions\n\n", user_bytes))
    if repository_bytes is not None and repository_identity != user_identity:
        sources.append((b"# Repository instructions\n\n", repository_bytes))

    chunks = []
    length = 0
    for heading, payload in sources:
        contribution = heading + payload
        if not payload.endswith(b"\n"):
            contribution += b"\n"
        contribution += b"\n"
        length += len(contribution)
        if length > MAX_SNAPSHOT_BYTES:
            raise ValueError("instruction snapshot is too large")
        chunks.append(contribution)
    return b"".join(chunks)


def _fingerprint(identity_key, root, config_bytes, instruction_bytes):
    components = (
        b"1",
        AUDITED_VERSION.encode("utf-8"),
        identity_key.encode("ascii"),
        root.encode("utf-8"),
        config_bytes,
        instruction_bytes,
    )
    digest = hashlib.sha256()
    for component in components:
        digest.update(len(component).to_bytes(8, "big"))
        digest.update(component)
    return digest.hexdigest()


def _directory_metadata(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_uid)


def _validate_private_directory_metadata(value):
    if (
        not stat.S_ISDIR(value.st_mode)
        or value.st_uid != os.getuid()
        or stat.S_IMODE(value.st_mode) != 0o700
    ):
        raise ValueError("private directory is unsafe")


def _directory_flags():
    flags = os.O_RDONLY | os.O_CLOEXEC
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    return flags


def _open_private_directory_path(path):
    _canonical_path(path, "private directory")
    try:
        before = os.lstat(path)
        _validate_private_directory_metadata(before)
        descriptor = os.open(path, _directory_flags())
    except (OSError, ValueError):
        raise ValueError("private directory is unsafe") from None
    try:
        opened = os.fstat(descriptor)
        _validate_private_directory_metadata(opened)
        if _directory_metadata(before) != _directory_metadata(opened):
            raise ValueError("private directory changed during validation")
    except Exception:
        os.close(descriptor)
        raise
    return descriptor, _directory_metadata(opened)


def _entry_lstat(parent_descriptor, name):
    return os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)


def _entry_exists(parent_descriptor, name):
    try:
        _entry_lstat(parent_descriptor, name)
        return True
    except FileNotFoundError:
        return False
    except OSError:
        raise ValueError("private entry cannot be inspected") from None


def _open_private_child(parent_descriptor, name):
    try:
        before = _entry_lstat(parent_descriptor, name)
        _validate_private_directory_metadata(before)
        descriptor = os.open(name, _directory_flags(), dir_fd=parent_descriptor)
        opened = os.fstat(descriptor)
        _validate_private_directory_metadata(opened)
        if _directory_metadata(before) != _directory_metadata(opened):
            raise ValueError("private directory changed during validation")
    except Exception as error:
        if "descriptor" in locals():
            os.close(descriptor)
        if isinstance(error, ValueError):
            raise
        raise ValueError("private directory is unsafe") from None
    return descriptor, _directory_metadata(opened)


def _verify_private_child(parent_descriptor, name, identity):
    try:
        current = _entry_lstat(parent_descriptor, name)
        _validate_private_directory_metadata(current)
    except (OSError, ValueError):
        raise ValueError("private directory changed") from None
    if _directory_metadata(current) != identity:
        raise ValueError("private directory changed")


def _create_private_child(parent_descriptor, name):
    descriptor = None
    created_identity = None
    mkdir_succeeded = False
    try:
        os.mkdir(name, 0o700, dir_fd=parent_descriptor)
        mkdir_succeeded = True
        created = _entry_lstat(parent_descriptor, name)
        created_identity = _directory_metadata(created)
        _validate_private_directory_metadata(created)
        descriptor = os.open(name, _directory_flags(), dir_fd=parent_descriptor)
        opened = os.fstat(descriptor)
        _validate_private_directory_metadata(opened)
        if _directory_metadata(created) != _directory_metadata(opened):
            raise ValueError("private directory changed during creation")
        os.fchmod(descriptor, 0o700)
        opened = os.fstat(descriptor)
        _validate_private_directory_metadata(opened)
        final = _entry_lstat(parent_descriptor, name)
        _validate_private_directory_metadata(final)
        if _directory_metadata(opened) != _directory_metadata(final):
            raise ValueError("private directory changed during creation")
    except Exception as error:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
        if mkdir_succeeded:
            _recover_created_child(parent_descriptor, name, created_identity)
        if isinstance(error, ValueError):
            raise
        raise ValueError("private directory cannot be created") from None
    return descriptor, _directory_metadata(opened)


def _open_or_create_profiles(backend_descriptor):
    if not _entry_exists(backend_descriptor, "profiles"):
        return _create_private_child(backend_descriptor, "profiles")
    return _open_private_child(backend_descriptor, "profiles")


def _write_private_file(parent_descriptor, name, payload):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(name, flags, 0o600, dir_fd=parent_descriptor)
        os.fchmod(descriptor, 0o600)
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise OSError("short write")
            offset += written
        os.fsync(descriptor)
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) != 0o600
            or metadata.st_size != len(payload)
        ):
            raise ValueError("private file is unsafe")
    except Exception as error:
        if "descriptor" in locals():
            try:
                os.close(descriptor)
            except OSError:
                pass
        if isinstance(error, ValueError):
            raise
        raise ValueError("private file cannot be written") from None
    try:
        os.close(descriptor)
    except OSError:
        raise ValueError("private file cannot be closed") from None


def _remove_tree_contents(descriptor):
    try:
        entries = list(os.scandir(descriptor))
    except OSError:
        return False
    for entry in entries:
        try:
            metadata = entry.stat(follow_symlinks=False)
            if stat.S_ISDIR(metadata.st_mode):
                child = os.open(entry.name, _directory_flags(), dir_fd=descriptor)
                opened = os.fstat(child)
                if _directory_metadata(metadata) != _directory_metadata(opened):
                    os.close(child)
                    return False
                clean = _remove_tree_contents(child)
                os.close(child)
                if not clean:
                    return False
                os.rmdir(entry.name, dir_fd=descriptor)
            else:
                os.unlink(entry.name, dir_fd=descriptor)
        except OSError:
            return False
    try:
        os.fsync(descriptor)
    except OSError:
        return False
    return True


def _recover_created_child(parent_descriptor, name, created_identity):
    if created_identity is None:
        return
    descriptor = None
    try:
        before = _entry_lstat(parent_descriptor, name)
        _validate_private_directory_metadata(before)
        before_identity = _directory_metadata(before)
        if before_identity != created_identity:
            return
        descriptor = os.open(name, _directory_flags(), dir_fd=parent_descriptor)
        opened = os.fstat(descriptor)
        _validate_private_directory_metadata(opened)
        opened_identity = _directory_metadata(opened)
        if before_identity != opened_identity:
            return
        current = _entry_lstat(parent_descriptor, name)
        _validate_private_directory_metadata(current)
        if _directory_metadata(current) != opened_identity:
            return
        if not _remove_tree_contents(descriptor):
            return
        current = _entry_lstat(parent_descriptor, name)
        _validate_private_directory_metadata(current)
        if _directory_metadata(current) != opened_identity:
            return
        os.rmdir(name, dir_fd=parent_descriptor)
        os.fsync(parent_descriptor)
    except (OSError, ValueError):
        pass
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass


def _cleanup_staging(parent_descriptor, name, descriptor, identity):
    if not _remove_tree_contents(descriptor):
        return
    try:
        current = _entry_lstat(parent_descriptor, name)
    except OSError:
        current = None
    try:
        if current is not None and _directory_metadata(current) == identity:
            os.rmdir(name, dir_fd=parent_descriptor)
        os.fsync(parent_descriptor)
    except OSError:
        pass


def _cleanup_published_generation(
    source_parent_descriptor,
    destination_parent_descriptor,
    name,
    descriptor,
    identity,
):
    if not _remove_tree_contents(descriptor):
        return
    try:
        current = _entry_lstat(destination_parent_descriptor, name)
    except OSError:
        current = None
    try:
        if current is not None and _directory_metadata(current) == identity:
            os.rmdir(name, dir_fd=destination_parent_descriptor)
        os.fsync(destination_parent_descriptor)
        os.fsync(source_parent_descriptor)
    except OSError:
        pass


def _rename_noreplace(
    source_descriptor,
    source_name,
    destination_descriptor,
    destination_name,
):
    if sys.platform != "linux":
        raise ValueError("atomic profile publication is unavailable")
    if (
        isinstance(source_descriptor, bool)
        or not isinstance(source_descriptor, int)
        or source_descriptor < 0
        or isinstance(destination_descriptor, bool)
        or not isinstance(destination_descriptor, int)
        or destination_descriptor < 0
    ):
        raise ValueError("atomic profile publication is unavailable")
    source_bytes = _utf8_bytes(source_name, "publication source")
    destination_bytes = _utf8_bytes(destination_name, "publication destination")
    if (
        not source_bytes
        or len(source_bytes) > 255
        or b"/" in source_bytes
        or b"\x00" in source_bytes
        or not destination_bytes
        or len(destination_bytes) > 255
        or b"/" in destination_bytes
        or b"\x00" in destination_bytes
    ):
        raise ValueError("atomic profile publication is unavailable")
    try:
        library = ctypes.CDLL(None, use_errno=True)
        renameat2 = library.renameat2
        renameat2.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        ]
        renameat2.restype = ctypes.c_int
        ctypes.set_errno(0)
        result = renameat2(
            source_descriptor,
            source_bytes,
            destination_descriptor,
            destination_bytes,
            _RENAME_NOREPLACE,
        )
    except (AttributeError, OSError, TypeError, ValueError):
        raise ValueError("atomic profile publication is unavailable") from None
    if result != 0:
        raise ValueError("atomic profile publication failed")


def _public_report(request, fingerprint, count):
    profile_root = os.path.join(request["backend_state"], "profiles", request["token"])
    return {
        "schema": 1,
        "version": AUDITED_VERSION,
        "profile_root": profile_root,
        "fingerprint": fingerprint,
        "config_source": os.path.join(profile_root, "xdg-config"),
        "auth_source": os.path.join(profile_root, "credentials", "auth.json"),
        "home_mask_source": os.path.join(profile_root, "empty-home-opencode"),
        "auth": "authenticated",
        "credential_count": count,
    }


def _publish_profile(request, auth_bytes, count, instruction_bytes):
    config_bytes = AUDITED_CONFIG_JSON.encode("utf-8")
    fingerprint = _fingerprint(
        request["identity_key"],
        request["root"],
        config_bytes,
        instruction_bytes,
    )
    manifest = {
        "schema": 1,
        "version": AUDITED_VERSION,
        "identity_key": request["identity_key"],
        "root": request["root"],
        "fingerprint": fingerprint,
        "config_sha256": hashlib.sha256(config_bytes).hexdigest(),
        "instructions_sha256": hashlib.sha256(instruction_bytes).hexdigest(),
    }
    manifest_bytes = _encode_compact(manifest) + b"\n"
    staging_name = ".opencode-profile-" + request["token"] + ".tmp"
    destination_name = request["token"]

    parent_descriptor = None
    backend_descriptor = None
    profiles_descriptor = None
    staging_descriptor = None
    staging_identity = None
    renamed = False
    publication_complete = False
    try:
        backend_parent = os.path.dirname(request["backend_state"])
        backend_name = os.path.basename(request["backend_state"])
        parent_descriptor, parent_identity = _open_private_directory_path(
            backend_parent
        )
        backend_descriptor, backend_identity = _open_private_child(
            parent_descriptor, backend_name
        )
        profiles_descriptor, profiles_identity = _open_or_create_profiles(
            backend_descriptor
        )
        if parent_identity[0] != profiles_identity[0]:
            raise ValueError("profile staging and destination filesystems differ")
        if _entry_exists(parent_descriptor, staging_name):
            raise ValueError("profile staging path already exists")
        if _entry_exists(profiles_descriptor, destination_name):
            raise ValueError("profile destination already exists")
        staging_descriptor, staging_identity = _create_private_child(
            parent_descriptor, staging_name
        )

        credentials_descriptor, _credentials_identity = _create_private_child(
            staging_descriptor, "credentials"
        )
        try:
            _write_private_file(credentials_descriptor, "auth.json", auth_bytes)
            os.fsync(credentials_descriptor)
        finally:
            os.close(credentials_descriptor)

        empty_descriptor, _empty_identity = _create_private_child(
            staging_descriptor, "empty-home-opencode"
        )
        try:
            _write_private_file(
                empty_descriptor,
                ".gitignore",
                AUDITED_BOOTSTRAP_GITIGNORE,
            )
            os.fsync(empty_descriptor)
        finally:
            os.close(empty_descriptor)

        xdg_descriptor, _xdg_identity = _create_private_child(
            staging_descriptor, "xdg-config"
        )
        try:
            opencode_descriptor, _opencode_identity = _create_private_child(
                xdg_descriptor, "opencode"
            )
            try:
                _write_private_file(
                    opencode_descriptor,
                    ".gitignore",
                    AUDITED_BOOTSTRAP_GITIGNORE,
                )
                _write_private_file(opencode_descriptor, "AGENTS.md", instruction_bytes)
                _write_private_file(opencode_descriptor, "opencode.json", config_bytes)
                os.fsync(opencode_descriptor)
            finally:
                os.close(opencode_descriptor)
            os.fsync(xdg_descriptor)
        finally:
            os.close(xdg_descriptor)

        _write_private_file(staging_descriptor, "manifest.json", manifest_bytes)
        os.fsync(staging_descriptor)
        os.fsync(profiles_descriptor)
        os.fsync(backend_descriptor)
        os.fsync(parent_descriptor)

        _verify_private_child(parent_descriptor, staging_name, staging_identity)
        if _entry_exists(profiles_descriptor, destination_name):
            raise ValueError("profile destination already exists")
        _verify_private_child(backend_descriptor, "profiles", profiles_identity)
        _verify_private_child(parent_descriptor, backend_name, backend_identity)
        _rename_noreplace(
            parent_descriptor,
            staging_name,
            profiles_descriptor,
            destination_name,
        )
        renamed = True
        os.fsync(profiles_descriptor)
        os.fsync(parent_descriptor)
        if _entry_exists(parent_descriptor, staging_name):
            raise ValueError("profile staging path remains after publication")
        _verify_private_child(profiles_descriptor, destination_name, staging_identity)
        _verify_private_child(backend_descriptor, "profiles", profiles_identity)
        _verify_private_child(parent_descriptor, backend_name, backend_identity)
        try:
            final_parent = os.lstat(backend_parent)
            final_backend = os.lstat(request["backend_state"])
        except OSError:
            raise ValueError("backend state changed during publication") from None
        if _directory_metadata(final_parent) != parent_identity:
            raise ValueError("backend state parent changed during publication")
        if _directory_metadata(final_backend) != backend_identity:
            raise ValueError("backend state changed during publication")
        publication_complete = True
    except ValueError:
        raise
    except OSError:
        raise ValueError("profile publication failed") from None
    finally:
        if (
            not publication_complete
            and parent_descriptor is not None
            and staging_descriptor is not None
            and staging_identity is not None
        ):
            if renamed and profiles_descriptor is not None:
                _cleanup_published_generation(
                    parent_descriptor,
                    profiles_descriptor,
                    destination_name,
                    staging_descriptor,
                    staging_identity,
                )
            else:
                _cleanup_staging(
                    parent_descriptor,
                    staging_name,
                    staging_descriptor,
                    staging_identity,
                )
        for descriptor in (
            staging_descriptor,
            profiles_descriptor,
            backend_descriptor,
            parent_descriptor,
        ):
            if descriptor is not None:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
    return _public_report(request, fingerprint, count)


def prepare_profile(request):
    validated = _validate_prepare_request(request)
    auth_payload, _auth_identity = _secure_read_path(
        validated["global_auth"], MAX_JSON_BYTES, "credential", missing_ok=True
    )
    if auth_payload is None:
        return {"auth": "unauthenticated", "credential_count": 0}
    filtered, auth_bytes = _decode_auth_bytes(auth_payload)
    if not filtered:
        return {"auth": "unauthenticated", "credential_count": 0}
    instruction_bytes = _build_instruction_snapshot(
        validated["user_agents"], validated["repo_agents"]
    )
    return _publish_profile(validated, auth_bytes, len(filtered), instruction_bytes)


def _validate_inspect_profile_request(request):
    _exact_object(request, _INSPECT_PROFILE_KEYS, label="inspect-profile request")
    if isinstance(request["schema"], bool) or request["schema"] != 1:
        raise ValueError("profile schema is unsupported")
    if not _valid_hex(request["token"], 32):
        raise ValueError("profile token is invalid")
    if not _valid_hex(request["identity_key"], 32):
        raise ValueError("identity key is invalid")
    if not _valid_hex(request["fingerprint"], 64):
        raise ValueError("profile fingerprint is invalid")
    if request["version"] != AUDITED_VERSION:
        raise ValueError("OpenCode version is unsupported")
    validated = dict(request)
    validated["root"] = _canonical_path(request["root"], "physical root")
    validated["backend_state"] = _canonical_path(
        request["backend_state"], "backend state"
    )
    return validated


def _secure_read_entry(parent_descriptor, name, maximum):
    try:
        before = _entry_lstat(parent_descriptor, name)
        _validate_file_metadata(before, maximum, "credential")
        flags = os.O_RDONLY | os.O_CLOEXEC
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(name, flags, dir_fd=parent_descriptor)
        opened = os.fstat(descriptor)
        _validate_file_metadata(opened, maximum, "credential")
        if _file_metadata(before) != _file_metadata(opened):
            raise ValueError("profile file changed during validation")
        chunks = []
        length = 0
        while length <= maximum:
            chunk = os.read(descriptor, min(65536, maximum + 1 - length))
            if not chunk:
                break
            chunks.append(chunk)
            length += len(chunk)
        if length > maximum:
            raise ValueError("profile file is too large")
        after_read = os.fstat(descriptor)
        _validate_file_metadata(after_read, maximum, "credential")
        if _file_metadata(opened) != _file_metadata(after_read):
            raise ValueError("profile file changed during read")
    except Exception as error:
        if "descriptor" in locals():
            try:
                os.close(descriptor)
            except OSError:
                pass
        if isinstance(error, ValueError):
            raise
        raise ValueError("profile file is unsafe") from None
    try:
        os.close(descriptor)
        after_close = _entry_lstat(parent_descriptor, name)
        _validate_file_metadata(after_close, maximum, "credential")
    except (OSError, ValueError):
        raise ValueError("profile file changed during read") from None
    if _file_metadata(after_read) != _file_metadata(after_close):
        raise ValueError("profile file changed during read")
    return b"".join(chunks)


def _require_entries(descriptor, expected):
    try:
        actual = set(os.listdir(descriptor))
    except OSError:
        raise ValueError("profile directory cannot be listed") from None
    if actual != set(expected):
        raise ValueError("profile tree contains unexpected entries")


def _read_home_mask_bootstrap(descriptor):
    try:
        _require_entries(descriptor, (".gitignore",))
        before = _entry_lstat(descriptor, ".gitignore")
        _validate_file_metadata(
            before,
            len(AUDITED_BOOTSTRAP_GITIGNORE),
            "credential",
        )
        payload = _secure_read_entry(
            descriptor,
            ".gitignore",
            len(AUDITED_BOOTSTRAP_GITIGNORE),
        )
        after = _entry_lstat(descriptor, ".gitignore")
        _validate_file_metadata(
            after,
            len(AUDITED_BOOTSTRAP_GITIGNORE),
            "credential",
        )
    except (OSError, ValueError):
        raise ValueError("home mask bootstrap is unsafe") from None
    identity = _file_metadata(after)
    if _file_metadata(before) != identity:
        raise ValueError("home mask bootstrap changed during inspection")
    if (
        payload != AUDITED_BOOTSTRAP_GITIGNORE
        or hashlib.sha256(payload).hexdigest()
        != AUDITED_BOOTSTRAP_GITIGNORE_SHA256
    ):
        raise ValueError("home mask bootstrap is not canonical")
    return payload, identity


def _canonical_json_file(payload, label):
    if not payload.endswith(b"\n") or payload.endswith(b"\n\n"):
        raise ValueError(label + " is not canonical JSON")
    body = payload[:-1]
    try:
        text = body.decode("utf-8")
    except UnicodeError:
        raise ValueError(label + " is not valid UTF-8") from None
    value = _decode_json(text)
    if _encode_compact(value) != body:
        raise ValueError(label + " is not canonical JSON")
    return value


def _validate_manifest(manifest, request, config_bytes, instruction_bytes):
    keys = (
        "schema",
        "version",
        "identity_key",
        "root",
        "fingerprint",
        "config_sha256",
        "instructions_sha256",
    )
    _exact_object(manifest, keys, label="profile manifest")
    if list(manifest) != list(keys):
        raise ValueError("profile manifest key order is invalid")
    if isinstance(manifest["schema"], bool) or manifest["schema"] != 1:
        raise ValueError("profile manifest schema is unsupported")
    if manifest["version"] != request["version"]:
        raise ValueError("profile manifest version changed")
    if manifest["identity_key"] != request["identity_key"]:
        raise ValueError("profile manifest identity changed")
    if manifest["root"] != request["root"]:
        raise ValueError("profile manifest root changed")
    if manifest["fingerprint"] != request["fingerprint"]:
        raise ValueError("profile manifest fingerprint changed")
    expected_config_hash = hashlib.sha256(config_bytes).hexdigest()
    expected_instruction_hash = hashlib.sha256(instruction_bytes).hexdigest()
    if manifest["config_sha256"] != expected_config_hash:
        raise ValueError("profile configuration hash changed")
    if manifest["instructions_sha256"] != expected_instruction_hash:
        raise ValueError("profile instruction hash changed")
    expected_fingerprint = _fingerprint(
        manifest["identity_key"],
        manifest["root"],
        config_bytes,
        instruction_bytes,
    )
    if manifest["fingerprint"] != expected_fingerprint:
        raise ValueError("profile fingerprint is invalid")
    return expected_fingerprint


def inspect_profile(request):
    validated = _validate_inspect_profile_request(request)
    descriptors = []
    try:
        backend_descriptor, backend_identity = _open_private_directory_path(
            validated["backend_state"]
        )
        descriptors.append(backend_descriptor)
        profiles_descriptor, profiles_identity = _open_private_child(
            backend_descriptor, "profiles"
        )
        descriptors.append(profiles_descriptor)
        profile_descriptor, profile_identity = _open_private_child(
            profiles_descriptor, validated["token"]
        )
        descriptors.append(profile_descriptor)
        _require_entries(
            profile_descriptor,
            ("credentials", "empty-home-opencode", "manifest.json", "xdg-config"),
        )

        credentials_descriptor, credentials_identity = _open_private_child(
            profile_descriptor, "credentials"
        )
        descriptors.append(credentials_descriptor)
        _require_entries(credentials_descriptor, ("auth.json",))
        auth_bytes = _secure_read_entry(
            credentials_descriptor, "auth.json", MAX_JSON_BYTES
        )
        filtered, canonical_auth = _decode_auth_bytes(auth_bytes)
        if not filtered or canonical_auth != auth_bytes:
            raise ValueError("profile authentication is invalid")

        empty_descriptor, empty_identity = _open_private_child(
            profile_descriptor, "empty-home-opencode"
        )
        descriptors.append(empty_descriptor)
        home_bootstrap_bytes, home_bootstrap_identity = _read_home_mask_bootstrap(
            empty_descriptor
        )

        xdg_descriptor, xdg_identity = _open_private_child(
            profile_descriptor, "xdg-config"
        )
        descriptors.append(xdg_descriptor)
        _require_entries(xdg_descriptor, ("opencode",))
        opencode_descriptor, opencode_identity = _open_private_child(
            xdg_descriptor, "opencode"
        )
        descriptors.append(opencode_descriptor)
        _require_entries(
            opencode_descriptor,
            (".gitignore", "AGENTS.md", "opencode.json"),
        )
        bootstrap_bytes = _secure_read_entry(
            opencode_descriptor,
            ".gitignore",
            len(AUDITED_BOOTSTRAP_GITIGNORE),
        )
        if (
            bootstrap_bytes != AUDITED_BOOTSTRAP_GITIGNORE
            or hashlib.sha256(bootstrap_bytes).hexdigest()
            != AUDITED_BOOTSTRAP_GITIGNORE_SHA256
        ):
            raise ValueError("profile bootstrap is not canonical")
        config_bytes = _secure_read_entry(
            opencode_descriptor, "opencode.json", MAX_JSON_BYTES
        )
        if config_bytes != AUDITED_CONFIG_JSON.encode("utf-8"):
            raise ValueError("profile configuration is not canonical")
        decoded_config = _decode_json(config_bytes.decode("utf-8"))
        if _encode_compact(decoded_config) != config_bytes:
            raise ValueError("profile configuration is not canonical")
        if decoded_config.get("permission") != _decode_json(AUDITED_POLICY_JSON):
            raise ValueError("profile policy is not canonical")

        instruction_bytes = _secure_read_entry(
            opencode_descriptor, "AGENTS.md", MAX_SNAPSHOT_BYTES
        )
        _instruction_bytes(instruction_bytes, "profile instructions")
        manifest_bytes = _secure_read_entry(
            profile_descriptor, "manifest.json", MAX_JSON_BYTES
        )
        manifest = _canonical_json_file(manifest_bytes, "profile manifest")
        fingerprint = _validate_manifest(
            manifest, validated, config_bytes, instruction_bytes
        )

        _require_entries(
            profile_descriptor,
            ("credentials", "empty-home-opencode", "manifest.json", "xdg-config"),
        )
        _require_entries(credentials_descriptor, ("auth.json",))
        _require_entries(xdg_descriptor, ("opencode",))
        _require_entries(
            opencode_descriptor,
            (".gitignore", "AGENTS.md", "opencode.json"),
        )
        if (
            _secure_read_entry(credentials_descriptor, "auth.json", MAX_JSON_BYTES)
            != auth_bytes
        ):
            raise ValueError("profile authentication changed during inspection")
        if (
            _secure_read_entry(opencode_descriptor, "opencode.json", MAX_JSON_BYTES)
            != config_bytes
        ):
            raise ValueError("profile configuration changed during inspection")
        if (
            _secure_read_entry(
                opencode_descriptor,
                ".gitignore",
                len(AUDITED_BOOTSTRAP_GITIGNORE),
            )
            != bootstrap_bytes
        ):
            raise ValueError("profile bootstrap changed during inspection")
        final_home_bootstrap, final_home_bootstrap_identity = (
            _read_home_mask_bootstrap(empty_descriptor)
        )
        if (
            final_home_bootstrap != home_bootstrap_bytes
            or final_home_bootstrap_identity != home_bootstrap_identity
        ):
            raise ValueError("home mask bootstrap changed during inspection")
        if (
            _secure_read_entry(opencode_descriptor, "AGENTS.md", MAX_SNAPSHOT_BYTES)
            != instruction_bytes
        ):
            raise ValueError("profile instructions changed during inspection")
        if (
            _secure_read_entry(profile_descriptor, "manifest.json", MAX_JSON_BYTES)
            != manifest_bytes
        ):
            raise ValueError("profile manifest changed during inspection")

        _verify_private_child(xdg_descriptor, "opencode", opencode_identity)
        _verify_private_child(profile_descriptor, "xdg-config", xdg_identity)
        _verify_private_child(profile_descriptor, "empty-home-opencode", empty_identity)
        _verify_private_child(profile_descriptor, "credentials", credentials_identity)
        _verify_private_child(profiles_descriptor, validated["token"], profile_identity)
        _verify_private_child(backend_descriptor, "profiles", profiles_identity)
        try:
            final_backend = os.lstat(validated["backend_state"])
        except OSError:
            raise ValueError("backend state changed during inspection") from None
        if _directory_metadata(final_backend) != backend_identity:
            raise ValueError("backend state changed during inspection")
    finally:
        for descriptor in reversed(descriptors):
            try:
                os.close(descriptor)
            except OSError:
                pass
    return _public_report(validated, fingerprint, len(filtered))


class _ArgumentParser(argparse.ArgumentParser):
    def error(self, _message):
        raise ValueError("invalid command line")


def _read_cli_request(stream):
    try:
        payload = stream.read(MAX_JSON_BYTES + 1)
    except (OSError, ValueError, TypeError, UnicodeError):
        raise ValueError("request cannot be read") from None
    if isinstance(payload, str):
        try:
            payload = payload.encode("utf-8")
        except UnicodeError:
            raise ValueError("request is not valid UTF-8") from None
    if not isinstance(payload, bytes) or len(payload) > MAX_JSON_BYTES:
        raise ValueError("request is too large")
    try:
        document = payload.decode("utf-8")
    except UnicodeError:
        raise ValueError("request is not valid UTF-8") from None
    return _decode_json(document)


def _dispatch(operation, request):
    if operation == "prepare":
        return prepare_profile(request)
    if operation == "inspect-auth":
        _exact_object(request, ("global_auth",), label="inspect-auth request")
        return inspect_auth(request["global_auth"])
    if operation == "inspect-profile":
        return inspect_profile(request)
    raise ValueError("operation is unsupported")


def main(argv=None, stdin=None, stdout=None, stderr=None):
    arguments = sys.argv[1:] if argv is None else argv
    input_stream = sys.stdin.buffer if stdin is None else stdin
    output_stream = sys.stdout if stdout is None else stdout
    error_stream = sys.stderr if stderr is None else stderr
    parser = _ArgumentParser(add_help=False)
    parser.add_argument(
        "--operation",
        required=True,
        choices=("prepare", "inspect-auth", "inspect-profile"),
    )
    try:
        options = parser.parse_args(arguments)
        request = _read_cli_request(input_stream)
        report = _dispatch(options.operation, request)
        encoded = _encode_compact(report) + b"\n"
        if len(encoded) > MAX_CLI_REPORT_BYTES:
            raise ValueError("report is too large")
        output_stream.write(encoded.decode("utf-8"))
        output_stream.flush()
        return 0
    except (ValueError, OSError, TypeError, UnicodeError, RecursionError):
        diagnostic = "error: validation failed\n"
        if len(diagnostic.encode("utf-8")) > MAX_DIAGNOSTIC_BYTES:
            diagnostic = "error\n"
        try:
            error_stream.write(diagnostic)
            error_stream.flush()
        except (OSError, ValueError, TypeError, UnicodeError):
            pass
        return 2


if __name__ == "__main__":
    sys.exit(main())
