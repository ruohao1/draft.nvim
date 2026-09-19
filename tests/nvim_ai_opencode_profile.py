"""Security and behavior tests for the managed OpenCode profile helper."""

from __future__ import annotations

import ast
import hashlib
import importlib.util
import io
import json
import os
import pathlib
import stat
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
HELPER_PATH = ROOT / "scripts" / "nvim-ai-opencode-profile.py"
SPEC = importlib.util.spec_from_file_location("nvim_ai_opencode_profile", HELPER_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"could not load helper from {HELPER_PATH}")
helper = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = helper
SPEC.loader.exec_module(helper)


POLICY_JSON = (
    '{"bash":"ask","doom_loop":"ask","external_directory":"ask",'
    '"skill":"deny","task":"deny","webfetch":"ask","websearch":"ask"}'
)
CONFIG_JSON = (
    '{"$schema":"https://opencode.ai/config.json","autoupdate":false,'
    '"permission":{"bash":"ask","doom_loop":"ask",'
    '"external_directory":"ask","skill":"deny","task":"deny",'
    '"webfetch":"ask","websearch":"ask"},"agent":{'
    '"general":{"disable":true},"explore":{"disable":true},'
    '"compaction":{"permission":{"*":"deny"}},'
    '"summary":{"permission":{"*":"deny"}},'
    '"title":{"permission":{"*":"deny"}}}}'
)
BOOTSTRAP_GITIGNORE = (
    b"node_modules\npackage.json\npackage-lock.json\nbun.lock\n.gitignore"
)
BOOTSTRAP_GITIGNORE_SHA256 = (
    "663a068e76d264d0bc6740f5450b6c4193c7b41ecf5e0dc222485b8a17404d95"
)
IDENTITY_KEY = "a" * 32
TOKEN = "b" * 32
SECOND_TOKEN = "c" * 32
VERSION = "1.18.30"
MAX_SOURCE_BYTES = 256 * 1024
MAX_SNAPSHOT_BYTES = 512 * 1024
MAX_JSON_BYTES = 1024 * 1024


def compact_json(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def fingerprint_for(
    *, identity_key: str, root: str, config: bytes, instructions: bytes
) -> str:
    components = (
        b"1",
        VERSION.encode("utf-8"),
        identity_key.encode("ascii"),
        root.encode("utf-8"),
        config,
        instructions,
    )
    digest = hashlib.sha256()
    for component in components:
        digest.update(len(component).to_bytes(8, "big"))
        digest.update(component)
    return digest.hexdigest()


class StatProxy:
    def __init__(self, source: os.stat_result, **changes: int) -> None:
        self._source = source
        self._changes = changes

    def __getattr__(self, name: str) -> object:
        if name in self._changes:
            return self._changes[name]
        return getattr(self._source, name)


class Fixture:
    def __init__(self, case: unittest.TestCase) -> None:
        self._temporary = tempfile.TemporaryDirectory(prefix="nvim-ai-opencode-")
        case.addCleanup(self._temporary.cleanup)
        self.base = pathlib.Path(self._temporary.name).resolve()
        os.chmod(self.base, 0o700)

        self.backend_state = self.base / "state"
        self.backend_state.mkdir(mode=0o700)
        self.physical_root = self.base / "project"
        self.physical_root.mkdir(mode=0o700)
        self.global_data = self.base / "global-data"
        self.global_data.mkdir(mode=0o700)
        self.home = self.base / "home"
        self.home.mkdir(mode=0o700)

        self.global_auth = self.global_data / "auth.json"
        self.user_agents = self.home / "AGENTS.md"
        self.repo_agents = self.physical_root / "AGENTS.md"
        self.write_auth(
            {
                "anthropic": {"type": "api", "key": "api-canary"},
                "openai": {
                    "type": "oauth",
                    "refresh": "refresh-canary",
                    "access": "access-canary",
                    "expires": 4102444800000,
                    "accountId": "acct-test",
                },
                "https://managed.invalid": {
                    "type": "wellknown",
                    "key": "TOKEN",
                    "token": "remote-config-canary",
                },
            }
        )
        self.write_instruction(self.user_agents, b"user line")
        self.write_instruction(self.repo_agents, b"repo line\n")

    def write_auth(self, value: object | str | bytes) -> None:
        if isinstance(value, bytes):
            payload = value
        elif isinstance(value, str):
            payload = value.encode("utf-8")
        else:
            payload = compact_json(value).encode("utf-8")
        self.global_auth.write_bytes(payload)
        os.chmod(self.global_auth, 0o600)

    @staticmethod
    def write_instruction(path: pathlib.Path, payload: bytes) -> None:
        path.write_bytes(payload)
        os.chmod(path, 0o644)

    def request(self, token: str = TOKEN) -> dict[str, object]:
        return {
            "schema": 1,
            "token": token,
            "identity_key": IDENTITY_KEY,
            "root": str(self.physical_root),
            "backend_state": str(self.backend_state),
            "global_auth": str(self.global_auth),
            "user_agents": str(self.user_agents),
            "repo_agents": str(self.repo_agents),
            "version": VERSION,
            "config_json": CONFIG_JSON,
            "policy_json": POLICY_JSON,
        }

    def profile_request(
        self, report: dict[str, object], token: str = TOKEN
    ) -> dict[str, object]:
        return {
            "schema": 1,
            "backend_state": str(self.backend_state),
            "token": token,
            "identity_key": IDENTITY_KEY,
            "root": str(self.physical_root),
            "version": VERSION,
            "fingerprint": report["fingerprint"],
        }

    def profile_root(self, token: str = TOKEN) -> pathlib.Path:
        return self.backend_state / "profiles" / token

    def prepare(self, token: str = TOKEN) -> dict[str, object]:
        return helper.prepare_profile(self.request(token))


class StaticContractTests(unittest.TestCase):
    def test_helper_uses_only_the_eight_permitted_imports_and_no_os_rename(
        self,
    ) -> None:
        tree = ast.parse(HELPER_PATH.read_text(encoding="utf-8"))
        imports: set[str] = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imports.update(alias.name for alias in node.names)
            elif isinstance(node, ast.ImportFrom):
                self.fail(f"from-import is not permitted: {ast.dump(node)}")
        self.assertEqual(
            imports,
            {
                "argparse",
                "ctypes",
                "hashlib",
                "json",
                "os",
                "pathlib",
                "stat",
                "sys",
            },
        )
        ordinary_renames = [
            node
            for node in ast.walk(tree)
            if isinstance(node, ast.Attribute)
            and isinstance(node.value, ast.Name)
            and node.value.id == "os"
            and node.attr == "rename"
        ]
        self.assertEqual(ordinary_renames, [])

    def test_audited_constants_and_limits_are_exact(self) -> None:
        self.assertEqual(helper.AUDITED_VERSION, VERSION)
        self.assertEqual(helper.AUDITED_POLICY_JSON, POLICY_JSON)
        self.assertEqual(helper.AUDITED_CONFIG_JSON, CONFIG_JSON)
        self.assertEqual(helper.AUDITED_BOOTSTRAP_GITIGNORE, BOOTSTRAP_GITIGNORE)
        self.assertEqual(
            helper.AUDITED_BOOTSTRAP_GITIGNORE_SHA256,
            BOOTSTRAP_GITIGNORE_SHA256,
        )
        self.assertEqual(helper.MAX_SOURCE_BYTES, MAX_SOURCE_BYTES)
        self.assertEqual(helper.MAX_SNAPSHOT_BYTES, MAX_SNAPSHOT_BYTES)
        self.assertEqual(helper.MAX_JSON_BYTES, MAX_JSON_BYTES)


class CredentialTests(unittest.TestCase):
    def test_filters_to_exact_api_and_oauth_schemas(self) -> None:
        source = {
            "anthropic": {"type": "api", "key": "api-canary"},
            "openai": {
                "type": "oauth",
                "refresh": "refresh-canary",
                "access": "access-canary",
                "expires": 4102444800000,
                "accountId": "acct-test",
            },
            "https://managed.invalid": {
                "type": "wellknown",
                "key": "TOKEN",
                "token": "remote-config-canary",
            },
        }
        result = helper.filter_auth(json.dumps(source))
        self.assertEqual(sorted(result), ["anthropic", "openai"])
        self.assertNotIn("remote-config-canary", json.dumps(result))

    def test_rejects_duplicate_keys_before_decoding(self) -> None:
        duplicate_documents = (
            '{"openai":{"type":"api","key":"one"},"openai":{"type":"api","key":"two"}}',
            '{"openai":{"type":"api","key":"one","key":"two"}}',
            (
                '{"openai":{"type":"api","key":"one",'
                '"metadata":{"region":"one","region":"two"}}}'
            ),
        )
        for document in duplicate_documents:
            with (
                self.subTest(document=document),
                self.assertRaisesRegex(ValueError, "duplicate"),
            ):
                helper.filter_auth(document)

    def test_diagnostics_never_echo_secrets(self) -> None:
        canary = "credential-must-never-escape"
        with self.assertRaises(ValueError) as caught:
            helper.filter_auth(
                json.dumps({"openai": {"type": "api", "key": canary, "extra": canary}})
            )
        self.assertNotIn(canary, str(caught.exception))
        self.assertLessEqual(len(str(caught.exception).encode("utf-8")), 256)

    def test_normalizes_and_utf8_sorts_provider_and_metadata_keys(self) -> None:
        source = {
            "z-provider///": {
                "metadata": {"z": "last", "é": "unicode", "a": "first"},
                "key": "z-key",
                "type": "api",
            },
            "é-provider/": {"type": "api", "key": "unicode-key"},
            "a-provider": {
                "enterpriseUrl": "https://enterprise.invalid",
                "expires": 1,
                "access": "access",
                "accountId": "account",
                "refresh": "refresh",
                "type": "oauth",
            },
        }
        result = helper.filter_auth(compact_json(source))
        self.assertEqual(list(result), ["a-provider", "z-provider", "é-provider"])
        self.assertEqual(list(result["z-provider"]["metadata"]), ["a", "z", "é"])
        self.assertEqual(
            list(result["a-provider"]),
            [
                "type",
                "refresh",
                "access",
                "expires",
                "accountId",
                "enterpriseUrl",
            ],
        )

    def test_rejects_nonobjects_unknown_types_fields_and_invalid_expires(self) -> None:
        invalid_records = (
            [],
            {"provider": "not-an-object"},
            {"provider": {"type": "unknown", "key": "secret"}},
            {"provider": {"type": "api"}},
            {"provider": {"type": "api", "key": 3}},
            {"provider": {"type": "api", "key": "secret", "extra": "x"}},
            {
                "provider": {
                    "type": "oauth",
                    "refresh": "r",
                    "access": "a",
                    "expires": -1,
                }
            },
            {
                "provider": {
                    "type": "oauth",
                    "refresh": "r",
                    "access": "a",
                    "expires": True,
                }
            },
            {
                "provider": {
                    "type": "oauth",
                    "refresh": "r",
                    "access": "a",
                    "expires": 1.5,
                }
            },
            {
                "provider": {
                    "type": "oauth",
                    "refresh": "r",
                    "access": "a",
                    "expires": 1,
                    "unknown": "secret",
                }
            },
        )
        for source in invalid_records:
            with self.subTest(source=source), self.assertRaises(ValueError):
                helper.filter_auth(compact_json(source))

    def test_wellknown_is_excluded_without_consuming_remote_fields(self) -> None:
        source = {
            "remote": {
                "type": "wellknown",
                "token": "remote-secret",
                "config": {"permission": {"*": "allow"}},
            }
        }
        self.assertEqual(helper.filter_auth(compact_json(source)), {})

    def test_rejects_provider_identifier_bounds_controls_and_collisions(self) -> None:
        invalid = (
            {"": {"type": "api", "key": "x"}},
            {"///": {"type": "api", "key": "x"}},
            {"bad\nprovider": {"type": "api", "key": "x"}},
            {"bad\x80provider": {"type": "api", "key": "x"}},
            {"é" * 129: {"type": "api", "key": "x"}},
            {
                "provider": {"type": "api", "key": "one"},
                "provider/": {"type": "api", "key": "two"},
            },
        )
        for source in invalid:
            with self.subTest(source=list(source)), self.assertRaises(ValueError):
                helper.filter_auth(compact_json(source))

        accepted = {"é" * 128: {"type": "api", "key": "x"}}
        self.assertEqual(
            len(next(iter(helper.filter_auth(compact_json(accepted))))), 128
        )

    def test_rejects_provider_metadata_and_output_bounds(self) -> None:
        cases = (
            {f"provider-{index}": {"type": "api", "key": "x"} for index in range(129)},
            {"provider": {"type": "api", "key": "x" * (MAX_SOURCE_BYTES + 1)}},
            {"provider": {"type": "api", "key": "nul\x00secret"}},
            {
                "provider": {
                    "type": "api",
                    "key": "x",
                    "metadata": {str(index): "x" for index in range(129)},
                }
            },
            {
                "provider": {
                    "type": "api",
                    "key": "x",
                    "metadata": {"k" * 8193: "v"},
                }
            },
            {
                "provider": {
                    "type": "api",
                    "key": "x",
                    "metadata": {"key": "v" * 8193},
                }
            },
            {
                "provider": {
                    "type": "api",
                    "key": "x",
                    "metadata": {"key": 3},
                }
            },
            {
                f"provider-{index}": {
                    "type": "api",
                    "key": "x" * MAX_SOURCE_BYTES,
                }
                for index in range(5)
            },
        )
        for source in cases:
            with self.subTest(providers=len(source)), self.assertRaises(ValueError):
                helper.filter_auth(compact_json(source))

    def test_strict_json_rejects_nonfinite_values_and_trailing_content(self) -> None:
        documents = (
            '{"provider":{"type":"oauth","refresh":"r","access":"a","expires":NaN}}',
            '{"provider":{"type":"api","key":"x"}} trailing',
        )
        for document in documents:
            with self.subTest(document=document), self.assertRaises(ValueError):
                helper.filter_auth(document)


class AuthenticationInspectionTests(unittest.TestCase):
    def test_inspect_auth_reports_only_status_and_accepted_count(self) -> None:
        fixture = Fixture(self)
        self.assertEqual(
            helper.inspect_auth(str(fixture.global_auth)),
            {"auth": "authenticated", "count": 2},
        )

        fixture.global_auth.unlink()
        self.assertEqual(
            helper.inspect_auth(str(fixture.global_auth)),
            {"auth": "unauthenticated", "count": 0},
        )

    def test_inspect_auth_rejects_unsafe_or_oversized_files(self) -> None:
        mutations = ("mode", "owner", "symlink", "directory", "oversize")
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                fixture = Fixture(self)
                patcher = None
                if mutation == "mode":
                    os.chmod(fixture.global_auth, 0o644)
                elif mutation == "owner":
                    original_lstat = os.lstat

                    def wrong_owner(path: object, *args: object, **kwargs: object):
                        result = original_lstat(path, *args, **kwargs)
                        if os.fspath(path) == str(fixture.global_auth):
                            return StatProxy(result, st_uid=os.getuid() + 1)
                        return result

                    patcher = mock.patch.object(
                        helper.os, "lstat", side_effect=wrong_owner
                    )
                elif mutation == "symlink":
                    target = fixture.global_auth.with_name("auth-target.json")
                    fixture.global_auth.rename(target)
                    fixture.global_auth.symlink_to(target)
                elif mutation == "directory":
                    fixture.global_auth.unlink()
                    fixture.global_auth.mkdir(mode=0o700)
                else:
                    fixture.write_auth(b"{" + b"x" * MAX_JSON_BYTES + b"}")
                if patcher is None:
                    with self.assertRaises(ValueError):
                        helper.inspect_auth(str(fixture.global_auth))
                else:
                    with patcher, self.assertRaises(ValueError):
                        helper.inspect_auth(str(fixture.global_auth))


class ProfileConstructionTests(unittest.TestCase):
    def assert_exact_tree(self, fixture: Fixture, token: str = TOKEN) -> None:
        profile = fixture.profile_root(token)
        relative = sorted(str(path.relative_to(profile)) for path in profile.rglob("*"))
        self.assertEqual(
            relative,
            [
                "credentials",
                "credentials/auth.json",
                "empty-home-opencode",
                "empty-home-opencode/.gitignore",
                "manifest.json",
                "xdg-config",
                "xdg-config/opencode",
                "xdg-config/opencode/.gitignore",
                "xdg-config/opencode/AGENTS.md",
                "xdg-config/opencode/opencode.json",
            ],
        )

    def assert_private_modes(self, fixture: Fixture, token: str = TOKEN) -> None:
        profile = fixture.profile_root(token)
        self.assertEqual(stat.S_IMODE(profile.stat().st_mode), 0o700)
        for path in profile.rglob("*"):
            expected = 0o700 if path.is_dir() else 0o600
            self.assertEqual(stat.S_IMODE(path.lstat().st_mode), expected, str(path))

    def test_builds_exact_private_tree_snapshot_manifest_and_report(self) -> None:
        fixture = Fixture(self)
        report = fixture.prepare()
        self.assert_exact_tree(fixture)
        self.assert_private_modes(fixture)

        expected_instructions = (
            b"# User instructions\n\nuser line\n\n"
            b"# Repository instructions\n\nrepo line\n\n"
        )
        profile = fixture.profile_root()
        self.assertEqual(
            (profile / "xdg-config/opencode/AGENTS.md").read_bytes(),
            expected_instructions,
        )
        self.assertEqual(
            (profile / "xdg-config/opencode/opencode.json").read_bytes(),
            CONFIG_JSON.encode("utf-8"),
        )
        bootstrap = profile / "xdg-config/opencode/.gitignore"
        bootstrap_bytes = bootstrap.read_bytes()
        self.assertEqual(len(bootstrap_bytes), 63)
        self.assertEqual(bootstrap_bytes, BOOTSTRAP_GITIGNORE)
        self.assertFalse(bootstrap_bytes.endswith(b"\n"))
        self.assertEqual(
            hashlib.sha256(bootstrap_bytes).hexdigest(),
            BOOTSTRAP_GITIGNORE_SHA256,
        )
        self.assertEqual(stat.S_IMODE(bootstrap.lstat().st_mode), 0o600)

        home_bootstrap = profile / "empty-home-opencode/.gitignore"
        home_bootstrap_bytes = home_bootstrap.read_bytes()
        self.assertEqual(home_bootstrap_bytes, BOOTSTRAP_GITIGNORE)
        self.assertEqual(
            hashlib.sha256(home_bootstrap_bytes).hexdigest(),
            BOOTSTRAP_GITIGNORE_SHA256,
        )
        home_bootstrap_metadata = home_bootstrap.lstat()
        self.assertEqual(stat.S_IMODE(home_bootstrap_metadata.st_mode), 0o600)
        self.assertEqual(home_bootstrap_metadata.st_uid, os.getuid())

        auth_bytes = (profile / "credentials/auth.json").read_bytes()
        self.assertTrue(auth_bytes.endswith(b"\n"))
        auth = json.loads(auth_bytes)
        self.assertEqual(list(auth), ["anthropic", "openai"])
        self.assertNotIn(b"remote-config-canary", auth_bytes)

        expected_fingerprint = fingerprint_for(
            identity_key=IDENTITY_KEY,
            root=str(fixture.physical_root),
            config=CONFIG_JSON.encode("utf-8"),
            instructions=expected_instructions,
        )
        self.assertEqual(
            report,
            {
                "schema": 1,
                "version": VERSION,
                "profile_root": str(profile),
                "fingerprint": expected_fingerprint,
                "config_source": str(profile / "xdg-config"),
                "auth_source": str(profile / "credentials/auth.json"),
                "home_mask_source": str(profile / "empty-home-opencode"),
                "auth": "authenticated",
                "credential_count": 2,
            },
        )
        self.assertNotIn("canary", compact_json(report))

        manifest_bytes = (profile / "manifest.json").read_bytes()
        self.assertTrue(manifest_bytes.endswith(b"\n"))
        manifest = json.loads(manifest_bytes)
        self.assertEqual(
            list(manifest),
            [
                "schema",
                "version",
                "identity_key",
                "root",
                "fingerprint",
                "config_sha256",
                "instructions_sha256",
            ],
        )
        self.assertEqual(manifest["fingerprint"], expected_fingerprint)
        self.assertEqual(
            manifest["config_sha256"],
            hashlib.sha256(CONFIG_JSON.encode("utf-8")).hexdigest(),
        )
        self.assertEqual(
            manifest["instructions_sha256"],
            hashlib.sha256(expected_instructions).hexdigest(),
        )
        self.assertEqual(manifest_bytes, (compact_json(manifest) + "\n").encode())

    def test_hostile_sibling_configuration_and_account_inputs_are_excluded(
        self,
    ) -> None:
        fixture = Fixture(self)
        hostile_sources = {
            fixture.global_data / "account.json": b"account-sibling-canary",
            fixture.global_data / "mcp-auth.json": b"mcp-auth-sibling-canary",
            fixture.home / ".config/opencode/opencode.json": b"global-config-canary",
            fixture.home / ".config/opencode/AGENTS.md": b"global-agents-canary",
            fixture.physical_root / "opencode.json": b"project-config-canary",
            fixture.physical_root / "nested/AGENTS.md": b"nested-agents-canary",
        }
        for path, payload in hostile_sources.items():
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            os.chmod(path.parent, 0o700)
            path.write_bytes(payload)
            os.chmod(path, 0o600)

        fixture.prepare()
        profile = fixture.profile_root()
        profile_bytes = b"\n".join(
            path.read_bytes() for path in profile.rglob("*") if path.is_file()
        )
        for payload in hostile_sources.values():
            self.assertNotIn(payload, profile_bytes)
        self.assertEqual(
            sorted(path.name for path in (profile / "credentials").iterdir()),
            ["auth.json"],
        )
        self.assertEqual(
            (profile / "xdg-config/opencode/AGENTS.md").read_bytes(),
            b"# User instructions\n\nuser line\n\n"
            b"# Repository instructions\n\nrepo line\n\n",
        )

    def test_instruction_order_separator_and_inode_dedup_are_exact(self) -> None:
        fixture = Fixture(self)
        fixture.write_instruction(fixture.user_agents, b"user\n\n")
        fixture.write_instruction(fixture.repo_agents, b"repo")
        fixture.prepare()
        snapshot = (
            fixture.profile_root() / "xdg-config/opencode/AGENTS.md"
        ).read_bytes()
        self.assertEqual(
            snapshot,
            b"# User instructions\n\nuser\n\n\n# Repository instructions\n\nrepo\n\n",
        )

        dedup = Fixture(self)
        dedup.repo_agents.unlink()
        os.link(dedup.user_agents, dedup.repo_agents)
        dedup.prepare()
        dedup_snapshot = (
            dedup.profile_root() / "xdg-config/opencode/AGENTS.md"
        ).read_bytes()
        self.assertEqual(dedup_snapshot, b"# User instructions\n\nuser line\n\n")

    def test_absent_optional_instructions_produce_an_empty_snapshot(self) -> None:
        fixture = Fixture(self)
        fixture.user_agents.unlink()
        fixture.repo_agents.unlink()
        fixture.prepare()
        self.assertEqual(
            (fixture.profile_root() / "xdg-config/opencode/AGENTS.md").read_bytes(),
            b"",
        )

    def test_instruction_utf8_nul_mode_kind_and_size_fail_closed(self) -> None:
        mutations = ("utf8", "nul", "mode", "symlink", "directory", "oversize")
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                fixture = Fixture(self)
                if mutation == "utf8":
                    fixture.write_instruction(fixture.repo_agents, b"bad\xff")
                elif mutation == "nul":
                    fixture.write_instruction(fixture.repo_agents, b"bad\x00text")
                elif mutation == "mode":
                    os.chmod(fixture.repo_agents, 0o664)
                elif mutation == "symlink":
                    target = fixture.repo_agents.with_name("instructions-target")
                    fixture.repo_agents.rename(target)
                    fixture.repo_agents.symlink_to(target)
                elif mutation == "directory":
                    fixture.repo_agents.unlink()
                    fixture.repo_agents.mkdir(mode=0o700)
                else:
                    fixture.write_instruction(
                        fixture.repo_agents, b"x" * (MAX_SOURCE_BYTES + 1)
                    )
                with self.assertRaises(ValueError):
                    fixture.prepare()
                self.assertFalse(fixture.profile_root().exists())

    def test_instruction_per_source_and_combined_limits_are_enforced(self) -> None:
        accepted = Fixture(self)
        accepted.user_agents.unlink()
        accepted.write_instruction(accepted.repo_agents, b"x" * MAX_SOURCE_BYTES)
        accepted.prepare()
        self.assertLessEqual(
            len(
                (accepted.profile_root() / "xdg-config/opencode/AGENTS.md").read_bytes()
            ),
            MAX_SNAPSHOT_BYTES,
        )

        combined = Fixture(self)
        combined.write_instruction(combined.user_agents, b"u" * MAX_SOURCE_BYTES)
        combined.write_instruction(combined.repo_agents, b"r" * MAX_SOURCE_BYTES)
        with self.assertRaises(ValueError):
            combined.prepare()
        self.assertFalse(combined.profile_root().exists())

    def test_empty_filtered_auth_returns_unauthenticated_without_publication(
        self,
    ) -> None:
        fixture = Fixture(self)
        fixture.write_auth({"remote": {"type": "wellknown", "token": "remote-secret"}})
        self.assertEqual(
            fixture.prepare(),
            {"auth": "unauthenticated", "credential_count": 0},
        )
        self.assertFalse((fixture.backend_state / "profiles").exists())

    def test_exact_prepare_request_and_audited_json_are_required(self) -> None:
        fixture = Fixture(self)
        base = fixture.request()
        invalid: list[dict[str, object]] = []
        for key in base:
            candidate = dict(base)
            del candidate[key]
            invalid.append(candidate)
        extra = dict(base)
        extra["extra"] = "forbidden"
        invalid.append(extra)
        for key, value in (
            ("schema", 2),
            ("token", "B" * 32),
            ("identity_key", "a" * 31),
            ("root", str(fixture.physical_root) + "/.."),
            ("version", "1.18.19"),
            ("version", "1.18.18"),
            ("version", "1.18.28"),
            ("version", "1.18.29"),
            ("version", "1.18.31"),
            ("config_json", CONFIG_JSON + " "),
            ("policy_json", '{"bash":"allow"}'),
        ):
            candidate = dict(base)
            candidate[key] = value
            invalid.append(candidate)

        for candidate in invalid:
            with self.subTest(keys=sorted(candidate)), self.assertRaises(ValueError):
                helper.prepare_profile(candidate)
        self.assertFalse(fixture.profile_root().exists())

    def test_credentials_change_generation_but_not_fingerprint(self) -> None:
        fixture = Fixture(self)
        first = fixture.prepare(TOKEN)
        first_auth = (
            fixture.profile_root(TOKEN) / "credentials/auth.json"
        ).read_bytes()
        fixture.write_auth(
            {
                "anthropic": {"type": "api", "key": "changed-api-canary"},
                "openai": {
                    "type": "oauth",
                    "refresh": "changed-refresh-canary",
                    "access": "changed-access-canary",
                    "expires": 4102444800001,
                },
            }
        )
        second = fixture.prepare(SECOND_TOKEN)
        second_auth = (
            fixture.profile_root(SECOND_TOKEN) / "credentials/auth.json"
        ).read_bytes()
        self.assertNotEqual(first["profile_root"], second["profile_root"])
        self.assertNotEqual(first_auth, second_auth)
        self.assertEqual(first["fingerprint"], second["fingerprint"])
        reports = compact_json([first, second])
        for canary in (
            "api-canary",
            "refresh-canary",
            "access-canary",
            "changed-api-canary",
            "changed-refresh-canary",
            "changed-access-canary",
        ):
            self.assertNotIn(canary, reports)


class SourceRaceTests(unittest.TestCase):
    def _swap_to_symlink(self, source: pathlib.Path) -> pathlib.Path:
        stable = source.with_name(source.name + ".stable")
        source.rename(stable)
        source.symlink_to(stable)
        return stable

    def test_refuses_symlink_replacement_between_lstat_and_open(self) -> None:
        fixture = Fixture(self)
        source = fixture.repo_agents
        original_open = os.open
        swapped = False

        def racing_open(path: object, flags: int, mode: int = 0o777, *, dir_fd=None):
            nonlocal swapped
            if dir_fd is None and os.fspath(path) == str(source) and not swapped:
                swapped = True
                self._swap_to_symlink(source)
            return original_open(path, flags, mode, dir_fd=dir_fd)

        with mock.patch.object(helper.os, "open", side_effect=racing_open):
            with self.assertRaises(ValueError):
                fixture.prepare()
        self.assertTrue(swapped)
        self.assertFalse(fixture.profile_root().exists())

    def test_refuses_symlink_replacement_between_open_and_fstat(self) -> None:
        fixture = Fixture(self)
        source = fixture.repo_agents
        identity = source.stat()
        original_fstat = os.fstat
        swapped = False

        def racing_fstat(fd: int):
            nonlocal swapped
            result = original_fstat(fd)
            if (
                not swapped
                and result.st_dev == identity.st_dev
                and result.st_ino == identity.st_ino
            ):
                swapped = True
                self._swap_to_symlink(source)
            return result

        with mock.patch.object(helper.os, "fstat", side_effect=racing_fstat):
            with self.assertRaises(ValueError):
                fixture.prepare()
        self.assertTrue(swapped)
        self.assertFalse(fixture.profile_root().exists())

    def test_refuses_symlink_replacement_between_fstat_and_read(self) -> None:
        fixture = Fixture(self)
        source = fixture.repo_agents
        identity = source.stat()
        original_read = os.read
        original_fstat = os.fstat
        swapped = False

        def racing_read(fd: int, size: int):
            nonlocal swapped
            descriptor = original_fstat(fd)
            if (
                not swapped
                and descriptor.st_dev == identity.st_dev
                and descriptor.st_ino == identity.st_ino
            ):
                swapped = True
                self._swap_to_symlink(source)
            return original_read(fd, size)

        with mock.patch.object(helper.os, "read", side_effect=racing_read):
            with self.assertRaises(ValueError):
                fixture.prepare()
        self.assertTrue(swapped)
        self.assertFalse(fixture.profile_root().exists())

    def test_refuses_symlink_replacement_between_read_and_final_lstat(self) -> None:
        fixture = Fixture(self)
        source = fixture.repo_agents
        original_lstat = os.lstat
        calls = 0

        def racing_lstat(path: object, *args: object, **kwargs: object):
            nonlocal calls
            if os.fspath(path) == str(source):
                calls += 1
                if calls == 2:
                    self._swap_to_symlink(source)
            return original_lstat(path, *args, **kwargs)

        with mock.patch.object(helper.os, "lstat", side_effect=racing_lstat):
            with self.assertRaises(ValueError):
                fixture.prepare()
        self.assertGreaterEqual(calls, 2)
        self.assertFalse(fixture.profile_root().exists())

    def test_refuses_same_inode_mutation_during_bounded_read(self) -> None:
        fixture = Fixture(self)
        source = fixture.repo_agents
        identity = source.stat()
        original_read = os.read
        original_fstat = os.fstat
        changed = False

        def racing_read(fd: int, size: int):
            nonlocal changed
            descriptor = original_fstat(fd)
            if (
                not changed
                and descriptor.st_dev == identity.st_dev
                and descriptor.st_ino == identity.st_ino
            ):
                changed = True
                source.write_bytes(b"replacement bytes with changed size")
                os.chmod(source, 0o644)
            return original_read(fd, size)

        with mock.patch.object(helper.os, "read", side_effect=racing_read):
            with self.assertRaises(ValueError):
                fixture.prepare()
        self.assertTrue(changed)
        self.assertFalse(fixture.profile_root().exists())


class PublicationBoundaryTests(unittest.TestCase):
    def test_backend_state_and_profiles_reject_symlink_mode_owner_and_kind(
        self,
    ) -> None:
        for boundary in ("backend_state", "profiles"):
            for mutation in ("symlink", "mode", "owner", "kind"):
                with self.subTest(boundary=boundary, mutation=mutation):
                    fixture = Fixture(self)
                    target = fixture.backend_state
                    if boundary == "profiles":
                        target = fixture.backend_state / "profiles"
                        target.mkdir(mode=0o700)

                    patcher = None
                    if mutation == "symlink":
                        real = target.with_name(target.name + "-real")
                        target.rename(real)
                        target.symlink_to(real, target_is_directory=True)
                    elif mutation == "mode":
                        os.chmod(target, 0o755)
                    elif mutation == "kind":
                        target.rmdir()
                        target.write_text("not a directory", encoding="utf-8")
                        os.chmod(target, 0o600)
                    else:
                        patcher = mock.patch.object(
                            helper.os, "getuid", return_value=os.getuid() + 1
                        )

                    context = (
                        patcher
                        if patcher is not None
                        else mock.patch.object(helper, "AUDITED_VERSION", VERSION)
                    )
                    with context, self.assertRaises(ValueError):
                        fixture.prepare()
                    self.assertFalse(fixture.profile_root().exists())

    def test_preexisting_staging_or_destination_is_refused_and_untouched(self) -> None:
        for boundary, name in (
            ("staging", f".opencode-profile-{TOKEN}.tmp"),
            ("destination", TOKEN),
        ):
            with self.subTest(boundary=boundary, name=name):
                fixture = Fixture(self)
                profiles = fixture.backend_state / "profiles"
                profiles.mkdir(mode=0o700)
                parent = (
                    fixture.backend_state.parent if boundary == "staging" else profiles
                )
                existing = parent / name
                existing.mkdir(mode=0o700)
                sentinel = existing / "keep"
                sentinel.write_text("preexisting", encoding="utf-8")
                os.chmod(sentinel, 0o600)
                with self.assertRaises(ValueError):
                    fixture.prepare()
                self.assertEqual(sentinel.read_text(encoding="utf-8"), "preexisting")

    def test_unpublished_generation_is_created_as_trusted_backend_state_sibling(
        self,
    ) -> None:
        fixture = Fixture(self)
        original_create = helper._create_private_child
        creations: list[tuple[pathlib.Path, str]] = []

        def observe_create(parent_descriptor: int, name: str):
            if TOKEN in name:
                parent = pathlib.Path(
                    os.readlink(f"/proc/self/fd/{parent_descriptor}")
                ).resolve()
                creations.append((parent, name))
            return original_create(parent_descriptor, name)

        with mock.patch.object(
            helper, "_create_private_child", side_effect=observe_create
        ):
            fixture.prepare()
        self.assertEqual(
            creations,
            [
                (
                    fixture.backend_state.parent,
                    f".opencode-profile-{TOKEN}.tmp",
                )
            ],
        )

    def test_publish_moves_from_trusted_parent_into_profiles_with_distinct_dirfds(
        self,
    ) -> None:
        fixture = Fixture(self)
        original_rename = helper._rename_noreplace
        calls: list[tuple[pathlib.Path, str, pathlib.Path, str]] = []

        def observe_rename(
            source_descriptor: int,
            source_name: str,
            destination_descriptor: int,
            destination_name: str,
        ) -> None:
            calls.append(
                (
                    pathlib.Path(
                        os.readlink(f"/proc/self/fd/{source_descriptor}")
                    ).resolve(),
                    source_name,
                    pathlib.Path(
                        os.readlink(f"/proc/self/fd/{destination_descriptor}")
                    ).resolve(),
                    destination_name,
                )
            )
            original_rename(
                source_descriptor,
                source_name,
                destination_descriptor,
                destination_name,
            )

        with mock.patch.object(helper, "_rename_noreplace", side_effect=observe_rename):
            fixture.prepare()
        self.assertEqual(
            calls,
            [
                (
                    fixture.backend_state.parent,
                    f".opencode-profile-{TOKEN}.tmp",
                    fixture.backend_state / "profiles",
                    TOKEN,
                )
            ],
        )

    def test_trusted_backend_state_parent_mode_is_validated(self) -> None:
        fixture = Fixture(self)
        os.chmod(fixture.backend_state.parent, 0o755)
        with self.assertRaises(ValueError):
            fixture.prepare()
        self.assertFalse(fixture.profile_root().exists())

    def test_trusted_parent_rejects_symlink_wrong_owner_and_wrong_kind(self) -> None:
        for mutation in ("symlink", "owner", "kind"):
            with self.subTest(mutation=mutation):
                fixture = Fixture(self)
                patcher = None
                if mutation == "symlink":
                    actual_parent = fixture.base / "actual-backends"
                    actual_parent.mkdir(mode=0o700)
                    moved_state = actual_parent / "state"
                    fixture.backend_state.rename(moved_state)
                    linked_parent = fixture.base / "linked-backends"
                    linked_parent.symlink_to(actual_parent, target_is_directory=True)
                    fixture.backend_state = linked_parent / "state"
                else:
                    parent = fixture.backend_state.parent
                    original_lstat = os.lstat

                    def altered_parent(
                        path: object,
                        *args: object,
                        _mutation: str = mutation,
                        _parent: pathlib.Path = parent,
                        _lstat=original_lstat,
                        **kwargs: object,
                    ):
                        result = _lstat(path, *args, **kwargs)
                        if os.fspath(path) == str(_parent):
                            if _mutation == "owner":
                                return StatProxy(result, st_uid=os.getuid() + 1)
                            return StatProxy(
                                result,
                                st_mode=stat.S_IFREG | 0o700,
                            )
                        return result

                    patcher = mock.patch.object(
                        helper.os, "lstat", side_effect=altered_parent
                    )

                if patcher is None:
                    with self.assertRaises(ValueError):
                        fixture.prepare()
                else:
                    with patcher, self.assertRaises(ValueError):
                        fixture.prepare()
                self.assertFalse(fixture.profile_root().exists())

    def test_parent_and_profiles_must_share_one_filesystem(self) -> None:
        fixture = Fixture(self)
        original_open_profiles = helper._open_or_create_profiles

        def report_other_filesystem(backend_descriptor: int):
            descriptor, identity = original_open_profiles(backend_descriptor)
            return descriptor, (identity[0] + 1, *identity[1:])

        with mock.patch.object(
            helper,
            "_open_or_create_profiles",
            side_effect=report_other_filesystem,
        ):
            with self.assertRaises(ValueError):
                fixture.prepare()
        self.assertFalse(fixture.profile_root().exists())

    def test_failed_build_cleans_only_sibling_staging_without_leakage(self) -> None:
        fixture = Fixture(self)
        staging = fixture.backend_state.parent / f".opencode-profile-{TOKEN}.tmp"
        with mock.patch.object(
            helper, "_write_private_file", side_effect=ValueError("injected")
        ):
            with self.assertRaises(ValueError):
                fixture.prepare()
        self.assertFalse(staging.exists())
        profiles = fixture.backend_state / "profiles"
        self.assertTrue(profiles.is_dir())
        self.assertEqual(list(profiles.iterdir()), [])

    def test_success_leaves_no_sibling_or_profiles_staging_entry(self) -> None:
        fixture = Fixture(self)
        fixture.prepare()
        self.assertFalse(
            (fixture.backend_state.parent / f".opencode-profile-{TOKEN}.tmp").exists()
        )
        self.assertFalse(
            (fixture.backend_state / "profiles" / f".{TOKEN}.tmp").exists()
        )

    def test_staging_swap_at_open_boundary_is_refused_without_publish(self) -> None:
        fixture = Fixture(self)
        original_open = os.open
        original_rename = os.rename
        replacement: pathlib.Path | None = None
        stolen: pathlib.Path | None = None

        def replace_before_open(
            path: object,
            flags: int,
            mode: int = 0o777,
            *,
            dir_fd: int | None = None,
        ):
            nonlocal replacement, stolen
            if (
                path == f".opencode-profile-{TOKEN}.tmp"
                and dir_fd is not None
                and replacement is None
            ):
                parent = fixture.backend_state.parent
                staging = parent / os.fspath(path)
                stolen = parent / ".staging-created-by-helper"
                original_rename(staging, stolen)
                staging.mkdir(mode=0o700)
                replacement = staging / "attacker-sentinel"
                replacement.write_text("foreign", encoding="utf-8")
                os.chmod(replacement, 0o600)
            return original_open(path, flags, mode, dir_fd=dir_fd)

        with mock.patch.object(helper.os, "open", side_effect=replace_before_open):
            with self.assertRaises(ValueError):
                fixture.prepare()
        self.assertIsNotNone(replacement)
        self.assertEqual(replacement.read_text(encoding="utf-8"), "foreign")
        self.assertIsNotNone(stolen)
        self.assertTrue(stolen.is_dir())
        self.assertFalse(fixture.profile_root().exists())

    def test_staging_open_failure_removes_the_proven_empty_created_entry(self) -> None:
        fixture = Fixture(self)
        original_open = os.open
        staging_name = f".opencode-profile-{TOKEN}.tmp"
        staging = fixture.backend_state.parent / staging_name
        injected = False

        def fail_staging_open(
            path: object,
            flags: int,
            mode: int = 0o777,
            *,
            dir_fd: int | None = None,
        ):
            nonlocal injected
            if path == staging_name and dir_fd is not None and not injected:
                injected = True
                raise OSError("injected staging open failure")
            return original_open(path, flags, mode, dir_fd=dir_fd)

        with mock.patch.object(helper.os, "open", side_effect=fail_staging_open):
            with self.assertRaises(ValueError):
                fixture.prepare()
        failed_create_staging_exists = staging.exists()
        self.assertFalse(failed_create_staging_exists)

    def test_staging_first_lstat_failure_preserves_unresolved_empty_basename(
        self,
    ) -> None:
        fixture = Fixture(self)
        original_entry_lstat = helper._entry_lstat
        staging_name = f".opencode-profile-{TOKEN}.tmp"
        staging = fixture.backend_state.parent / staging_name
        injected = False

        def fail_first_post_mkdir_lstat(parent_descriptor: int, name: str):
            nonlocal injected
            if name == staging_name and staging.exists() and not injected:
                injected = True
                raise OSError("injected first post-mkdir lstat failure")
            return original_entry_lstat(parent_descriptor, name)

        caught = False
        with mock.patch.object(
            helper,
            "_entry_lstat",
            side_effect=fail_first_post_mkdir_lstat,
        ):
            try:
                fixture.prepare()
            except ValueError:
                caught = True
        staging_exists = staging.exists()
        self.assertTrue(caught)
        self.assertTrue(staging_exists)
        self.assertEqual(list(staging.iterdir()), [])

    def test_first_lstat_failure_preserves_an_empty_foreign_replacement(
        self,
    ) -> None:
        fixture = Fixture(self)
        original_entry_lstat = helper._entry_lstat
        original_rename = os.rename
        staging_name = f".opencode-profile-{TOKEN}.tmp"
        staging = fixture.backend_state.parent / staging_name
        stolen = fixture.backend_state.parent / ".staging-created-by-helper"
        injected = False

        def replace_then_fail_first_lstat(parent_descriptor: int, name: str):
            nonlocal injected
            if name == staging_name and staging.exists() and not injected:
                injected = True
                original_rename(staging, stolen)
                staging.mkdir(mode=0o700)
                raise OSError("injected first post-mkdir lstat failure")
            return original_entry_lstat(parent_descriptor, name)

        caught = False
        with mock.patch.object(
            helper,
            "_entry_lstat",
            side_effect=replace_then_fail_first_lstat,
        ):
            try:
                fixture.prepare()
            except ValueError:
                caught = True
        self.assertTrue(caught)
        self.assertTrue(staging.is_dir())
        self.assertEqual(list(staging.iterdir()), [])
        self.assertTrue(stolen.is_dir())
        self.assertFalse(fixture.profile_root().exists())

    def test_first_lstat_failure_never_adopts_a_foreign_staging_replacement(
        self,
    ) -> None:
        fixture = Fixture(self)
        original_entry_lstat = helper._entry_lstat
        original_rename = os.rename
        staging_name = f".opencode-profile-{TOKEN}.tmp"
        staging = fixture.backend_state.parent / staging_name
        stolen = fixture.backend_state.parent / ".staging-created-by-helper"
        sentinel = staging / "attacker-sentinel"
        injected = False

        def replace_then_fail_first_lstat(parent_descriptor: int, name: str):
            nonlocal injected
            if name == staging_name and staging.exists() and not injected:
                injected = True
                original_rename(staging, stolen)
                staging.mkdir(mode=0o700)
                sentinel.write_text("foreign", encoding="utf-8")
                os.chmod(sentinel, 0o600)
                raise OSError("injected first post-mkdir lstat failure")
            return original_entry_lstat(parent_descriptor, name)

        caught = False
        with mock.patch.object(
            helper,
            "_entry_lstat",
            side_effect=replace_then_fail_first_lstat,
        ):
            try:
                fixture.prepare()
            except ValueError:
                caught = True
        self.assertTrue(caught)
        self.assertTrue(staging.is_dir())
        self.assertTrue(sentinel.is_file())
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "foreign")
        self.assertTrue(stolen.is_dir())
        self.assertFalse(fixture.profile_root().exists())

    def test_empty_destination_injected_after_final_precheck_is_not_replaced(
        self,
    ) -> None:
        fixture = Fixture(self)
        original_entry_exists = helper._entry_exists
        destination_checks = 0

        def inject_empty_destination(parent_descriptor: int, name: str) -> bool:
            nonlocal destination_checks
            exists = original_entry_exists(parent_descriptor, name)
            if name == TOKEN:
                destination_checks += 1
                if destination_checks == 2 and not exists:
                    fixture.profile_root().mkdir(mode=0o700)
            return exists

        with mock.patch.object(
            helper, "_entry_exists", side_effect=inject_empty_destination
        ):
            with self.assertRaises(ValueError):
                fixture.prepare()
        self.assertEqual(destination_checks, 2)
        self.assertTrue(fixture.profile_root().is_dir())
        self.assertEqual(list(fixture.profile_root().iterdir()), [])

    def test_renameat2_wrapper_uses_dirfds_names_and_noreplace(self) -> None:
        renameat2 = mock.Mock(return_value=0)
        library = mock.Mock()
        library.renameat2 = renameat2
        with mock.patch.object(helper.ctypes, "CDLL", return_value=library) as loader:
            helper._rename_noreplace(11, ".source", 12, "destination")
        loader.assert_called_once_with(None, use_errno=True)
        renameat2.assert_called_once_with(11, b".source", 12, b"destination", 1)
        self.assertEqual(renameat2.restype, helper.ctypes.c_int)
        self.assertEqual(
            renameat2.argtypes,
            [
                helper.ctypes.c_int,
                helper.ctypes.c_char_p,
                helper.ctypes.c_int,
                helper.ctypes.c_char_p,
                helper.ctypes.c_uint,
            ],
        )

    def test_renameat2_unavailable_never_falls_back_to_ordinary_rename(self) -> None:
        unavailable_cases = (
            mock.patch.object(helper.ctypes, "CDLL", side_effect=OSError("missing")),
            mock.patch.object(helper.ctypes, "CDLL", return_value=object()),
        )
        for unavailable in unavailable_cases:
            with self.subTest(unavailable=unavailable):
                with unavailable, mock.patch.object(helper.os, "rename") as fallback:
                    with self.assertRaises(ValueError) as caught:
                        helper._rename_noreplace(11, ".source", 11, "destination")
                fallback.assert_not_called()
                self.assertLessEqual(len(str(caught.exception).encode("utf-8")), 256)

    def test_tree_is_complete_and_private_at_the_single_atomic_rename(self) -> None:
        fixture = Fixture(self)
        original_rename = helper._rename_noreplace
        observations: list[tuple[int, str, int, str]] = []

        def observing_rename(
            source_descriptor: int,
            src: str,
            destination_descriptor: int,
            dst: str,
        ) -> None:
            src_path = fixture.backend_state.parent / os.fspath(src)
            dst_path = fixture.backend_state / "profiles" / os.fspath(dst)
            self.assertEqual(src_path.name, f".opencode-profile-{TOKEN}.tmp")
            self.assertEqual(dst_path.name, TOKEN)
            self.assertTrue((src_path / "manifest.json").is_file())
            self.assertTrue((src_path / "credentials/auth.json").is_file())
            self.assertFalse(dst_path.exists())
            for path in [src_path, *src_path.rglob("*")]:
                expected = 0o700 if path.is_dir() else 0o600
                self.assertEqual(stat.S_IMODE(path.lstat().st_mode), expected)
            self.assertNotEqual(source_descriptor, destination_descriptor)
            observations.append((source_descriptor, src, destination_descriptor, dst))
            original_rename(
                source_descriptor,
                src,
                destination_descriptor,
                dst,
            )

        with mock.patch.object(
            helper, "_rename_noreplace", side_effect=observing_rename
        ):
            fixture.prepare()
        self.assertEqual(len(observations), 1)
        source_descriptor, source, destination_descriptor, destination = observations[0]
        self.assertNotEqual(source_descriptor, destination_descriptor)
        self.assertEqual(
            (source, destination),
            (f".opencode-profile-{TOKEN}.tmp", TOKEN),
        )
        self.assertTrue(fixture.profile_root().is_dir())

    def test_every_file_and_directory_is_fsynced_before_or_with_publication(
        self,
    ) -> None:
        fixture = Fixture(self)
        original_fsync = os.fsync
        original_fstat = os.fstat
        synced = {"file": 0, "directory": 0}
        synced_directories: set[pathlib.Path] = set()

        def observing_fsync(descriptor: int):
            metadata = original_fstat(descriptor)
            if stat.S_ISREG(metadata.st_mode):
                synced["file"] += 1
            elif stat.S_ISDIR(metadata.st_mode):
                synced["directory"] += 1
                synced_directories.add(
                    pathlib.Path(os.readlink(f"/proc/self/fd/{descriptor}")).resolve()
                )
            return original_fsync(descriptor)

        with mock.patch.object(helper.os, "fsync", side_effect=observing_fsync):
            fixture.prepare()
        self.assertEqual(synced["file"], 6)
        self.assertGreaterEqual(synced["directory"], 7)
        self.assertTrue(
            {
                fixture.backend_state.parent,
                fixture.backend_state,
                fixture.backend_state / "profiles",
            }.issubset(synced_directories)
        )

    def test_post_rename_profiles_fsync_failure_removes_the_generation(self) -> None:
        fixture = Fixture(self)
        original_fsync = os.fsync
        profiles = (fixture.backend_state / "profiles").resolve()
        profiles_syncs = 0
        injected = False

        def fail_second_profiles_fsync(descriptor: int):
            nonlocal profiles_syncs, injected
            opened_path = pathlib.Path(
                os.readlink(f"/proc/self/fd/{descriptor}")
            ).resolve()
            if opened_path == profiles:
                profiles_syncs += 1
                if profiles_syncs == 2:
                    injected = True
                    raise OSError("injected post-rename profiles fsync failure")
            return original_fsync(descriptor)

        with mock.patch.object(
            helper.os,
            "fsync",
            side_effect=fail_second_profiles_fsync,
        ):
            with self.assertRaises(ValueError):
                fixture.prepare()
        profile = fixture.profile_root()
        self.assertTrue(injected)
        self.assertFalse(profile.exists())
        self.assertFalse((profile / "credentials/auth.json").exists())
        self.assertFalse(
            (fixture.backend_state.parent / f".opencode-profile-{TOKEN}.tmp").exists()
        )

    def test_final_verification_failure_removes_the_generation(self) -> None:
        fixture = Fixture(self)
        original_verify = helper._verify_private_child
        injected = False

        def fail_destination_verification(
            parent_descriptor: int,
            name: str,
            identity: tuple[int, int, int, int],
        ) -> None:
            nonlocal injected
            if name == TOKEN and not injected:
                injected = True
                raise ValueError("injected final destination verification failure")
            original_verify(parent_descriptor, name, identity)

        with mock.patch.object(
            helper,
            "_verify_private_child",
            side_effect=fail_destination_verification,
        ):
            with self.assertRaises(ValueError):
                fixture.prepare()
        profile = fixture.profile_root()
        self.assertTrue(injected)
        self.assertFalse(profile.exists())
        self.assertFalse((profile / "credentials/auth.json").exists())

    def test_replaced_destination_survives_incomplete_publication_cleanup(
        self,
    ) -> None:
        fixture = Fixture(self)
        original_verify = helper._verify_private_child
        original_rename = os.rename
        profile = fixture.profile_root()
        stolen = profile.parent / ".stolen-published-generation"
        sentinel = profile / "attacker-sentinel"
        injected = False

        def replace_destination_before_final_verification(
            parent_descriptor: int,
            name: str,
            identity: tuple[int, int, int, int],
        ) -> None:
            nonlocal injected
            if name == TOKEN and not injected:
                injected = True
                original_rename(profile, stolen)
                profile.mkdir(mode=0o700)
                sentinel.write_text("foreign", encoding="utf-8")
                os.chmod(sentinel, 0o600)
                raise ValueError("injected final destination replacement")
            original_verify(parent_descriptor, name, identity)

        with mock.patch.object(
            helper,
            "_verify_private_child",
            side_effect=replace_destination_before_final_verification,
        ):
            with self.assertRaises(ValueError):
                fixture.prepare()
        self.assertTrue(injected)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "foreign")
        self.assertTrue(stolen.is_dir())
        stolen_auth = stolen / "credentials/auth.json"
        self.assertFalse(stolen_auth.exists())
        self.assertEqual(list(stolen.iterdir()), [])

    def test_staging_replacement_on_publication_is_not_deleted_or_published(
        self,
    ) -> None:
        fixture = Fixture(self)
        original_rename = os.rename
        replacement: pathlib.Path | None = None
        stolen = fixture.backend_state.parent / ".stolen"

        def replace_staging(
            _source_descriptor: int,
            src: str,
            _destination_descriptor: int,
            _dst: str,
        ) -> None:
            nonlocal replacement
            parent = fixture.backend_state.parent
            staging = parent / os.fspath(src)
            original_rename(staging, stolen)
            staging.mkdir(mode=0o700)
            replacement = staging / "attacker-sentinel"
            replacement.write_text("foreign", encoding="utf-8")
            os.chmod(replacement, 0o600)
            raise OSError("simulated publication race")

        with mock.patch.object(
            helper, "_rename_noreplace", side_effect=replace_staging
        ):
            with self.assertRaises(ValueError):
                fixture.prepare()
        self.assertIsNotNone(replacement)
        self.assertEqual(replacement.read_text(encoding="utf-8"), "foreign")
        stolen_auth = stolen / "credentials/auth.json"
        stolen_contains_api_canary = (
            stolen_auth.is_file() and b"api-canary" in stolen_auth.read_bytes()
        )
        self.assertFalse(stolen_contains_api_canary)
        self.assertFalse(fixture.profile_root().exists())

    def test_destination_replacement_before_rename_is_never_overwritten(self) -> None:
        fixture = Fixture(self)
        original_rename = helper._rename_noreplace
        sentinel: pathlib.Path | None = None

        def replace_destination(
            source_descriptor: int,
            src: str,
            destination_descriptor: int,
            dst: str,
        ) -> None:
            nonlocal sentinel
            profiles = fixture.backend_state / "profiles"
            destination = profiles / os.fspath(dst)
            destination.mkdir(mode=0o700)
            sentinel = destination / "attacker-sentinel"
            sentinel.write_text("foreign", encoding="utf-8")
            os.chmod(sentinel, 0o600)
            original_rename(
                source_descriptor,
                src,
                destination_descriptor,
                dst,
            )

        with mock.patch.object(
            helper, "_rename_noreplace", side_effect=replace_destination
        ):
            with self.assertRaises(ValueError):
                fixture.prepare()
        self.assertIsNotNone(sentinel)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "foreign")


class InspectProfileTests(unittest.TestCase):
    def test_securely_reopens_generation_and_returns_the_same_public_report(
        self,
    ) -> None:
        fixture = Fixture(self)
        prepared = fixture.prepare()
        inspected = helper.inspect_profile(fixture.profile_request(prepared))
        self.assertEqual(inspected, prepared)
        self.assertNotIn("canary", compact_json(inspected))

    def test_rejects_unsafe_or_changed_bootstrap_gitignore(self) -> None:
        mutations = (
            "missing",
            "changed-bytes",
            "appended-lf",
            "mode",
            "owner",
            "symlink",
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                fixture = Fixture(self)
                prepared = fixture.prepare()
                path = fixture.profile_root() / "xdg-config/opencode/.gitignore"
                patcher = None
                if mutation == "missing":
                    path.unlink()
                elif mutation == "changed-bytes":
                    path.write_bytes(b"x" + BOOTSTRAP_GITIGNORE[1:])
                elif mutation == "appended-lf":
                    path.write_bytes(BOOTSTRAP_GITIGNORE + b"\n")
                elif mutation == "mode":
                    os.chmod(path, 0o644)
                elif mutation == "owner":
                    original_entry_lstat = helper._entry_lstat

                    def wrong_bootstrap_owner(
                        parent_descriptor: int,
                        name: str,
                    ):
                        result = original_entry_lstat(parent_descriptor, name)
                        if name == ".gitignore":
                            return StatProxy(result, st_uid=os.getuid() + 1)
                        return result

                    patcher = mock.patch.object(
                        helper,
                        "_entry_lstat",
                        side_effect=wrong_bootstrap_owner,
                    )
                else:
                    target = fixture.base / "bootstrap-target"
                    target.write_bytes(path.read_bytes())
                    os.chmod(target, 0o600)
                    path.unlink()
                    path.symlink_to(target)

                context = (
                    patcher
                    if patcher is not None
                    else mock.patch.object(helper, "AUDITED_VERSION", VERSION)
                )
                with context, self.assertRaises(ValueError) as caught:
                    helper.inspect_profile(fixture.profile_request(prepared))
                self.assertNotIn("canary", str(caught.exception))

    def test_rejects_late_bootstrap_gitignore_replacement(self) -> None:
        fixture = Fixture(self)
        prepared = fixture.prepare()
        path = fixture.profile_root() / "xdg-config/opencode/.gitignore"
        original_validate = helper._validate_manifest
        replaced = False

        def replace_after_manifest_validation(*args: object, **kwargs: object):
            nonlocal replaced
            result = original_validate(*args, **kwargs)
            replacement = path.with_name("bootstrap-replacement")
            replacement.write_bytes(b"x" + BOOTSTRAP_GITIGNORE[1:])
            os.chmod(replacement, 0o600)
            os.replace(replacement, path)
            replaced = True
            return result

        with (
            mock.patch.object(
                helper,
                "_validate_manifest",
                side_effect=replace_after_manifest_validation,
            ),
            self.assertRaises(ValueError) as caught,
        ):
            helper.inspect_profile(fixture.profile_request(prepared))
        self.assertTrue(replaced)
        self.assertNotIn("canary", str(caught.exception))

    def test_rejects_unsafe_or_changed_home_mask_bootstrap(self) -> None:
        mutations = (
            "missing",
            "changed-bytes",
            "wrong-kind",
            "mode",
            "owner",
            "symlink",
            "extra",
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                fixture = Fixture(self)
                prepared = fixture.prepare()
                mask = fixture.profile_root() / "empty-home-opencode"
                path = mask / ".gitignore"
                patcher = None
                if mutation == "missing":
                    path.unlink()
                elif mutation == "changed-bytes":
                    path.write_bytes(b"x" + BOOTSTRAP_GITIGNORE[1:])
                elif mutation == "wrong-kind":
                    path.unlink()
                    path.mkdir(mode=0o700)
                elif mutation == "mode":
                    os.chmod(path, 0o644)
                elif mutation == "owner":
                    mask_metadata = mask.stat()
                    original_entry_lstat = helper._entry_lstat

                    def wrong_home_bootstrap_owner(
                        parent_descriptor: int,
                        name: str,
                    ):
                        result = original_entry_lstat(parent_descriptor, name)
                        parent_metadata = os.fstat(parent_descriptor)
                        if (
                            name == ".gitignore"
                            and parent_metadata.st_dev == mask_metadata.st_dev
                            and parent_metadata.st_ino == mask_metadata.st_ino
                        ):
                            return StatProxy(result, st_uid=os.getuid() + 1)
                        return result

                    patcher = mock.patch.object(
                        helper,
                        "_entry_lstat",
                        side_effect=wrong_home_bootstrap_owner,
                    )
                elif mutation == "symlink":
                    target = fixture.base / "home-bootstrap-target"
                    target.write_bytes(path.read_bytes())
                    os.chmod(target, 0o600)
                    path.unlink()
                    path.symlink_to(target)
                else:
                    extra = mask / "unexpected"
                    extra.write_bytes(b"unexpected")
                    os.chmod(extra, 0o600)

                context = (
                    patcher
                    if patcher is not None
                    else mock.patch.object(helper, "AUDITED_VERSION", VERSION)
                )
                with context, self.assertRaisesRegex(
                    ValueError, "home mask bootstrap"
                ) as caught:
                    helper.inspect_profile(fixture.profile_request(prepared))
                self.assertNotIn("canary", str(caught.exception))

    def test_rejects_late_home_mask_bootstrap_replacement(self) -> None:
        fixture = Fixture(self)
        prepared = fixture.prepare()
        path = fixture.profile_root() / "empty-home-opencode/.gitignore"
        original_validate = helper._validate_manifest
        replaced = False

        def replace_after_manifest_validation(*args: object, **kwargs: object):
            nonlocal replaced
            result = original_validate(*args, **kwargs)
            replacement = path.with_name("home-bootstrap-replacement")
            replacement.write_bytes(b"x" + BOOTSTRAP_GITIGNORE[1:])
            os.chmod(replacement, 0o600)
            os.replace(replacement, path)
            replaced = True
            return result

        with (
            mock.patch.object(
                helper,
                "_validate_manifest",
                side_effect=replace_after_manifest_validation,
            ),
            self.assertRaises(ValueError) as caught,
        ):
            helper.inspect_profile(fixture.profile_request(prepared))
        self.assertTrue(replaced)
        self.assertNotIn("canary", str(caught.exception))

    def test_rejects_same_byte_home_mask_bootstrap_replacement(self) -> None:
        fixture = Fixture(self)
        prepared = fixture.prepare()
        path = fixture.profile_root() / "empty-home-opencode/.gitignore"
        original_inode = path.lstat().st_ino
        original_validate = helper._validate_manifest
        replacement_inode = None

        def replace_after_manifest_validation(*args: object, **kwargs: object):
            nonlocal replacement_inode
            result = original_validate(*args, **kwargs)
            replacement = path.with_name("home-bootstrap-replacement")
            replacement.write_bytes(BOOTSTRAP_GITIGNORE)
            os.chmod(replacement, 0o600)
            os.replace(replacement, path)
            replacement_inode = path.lstat().st_ino
            return result

        with (
            mock.patch.object(
                helper,
                "_validate_manifest",
                side_effect=replace_after_manifest_validation,
            ),
            self.assertRaisesRegex(ValueError, "home mask bootstrap.*changed"),
        ):
            helper.inspect_profile(fixture.profile_request(prepared))
        self.assertIsNotNone(replacement_inode)
        self.assertNotEqual(replacement_inode, original_inode)

    def test_rejects_changed_reference_and_manifest_identity_fields(self) -> None:
        request_mutations = {
            "schema": 2,
            "token": "d" * 32,
            "identity_key": "e" * 32,
            "root": None,
            "version": "1.18.19",
            "fingerprint": "f" * 64,
        }
        for field, value in request_mutations.items():
            with self.subTest(location="request", field=field):
                fixture = Fixture(self)
                prepared = fixture.prepare()
                request = fixture.profile_request(prepared)
                if field == "root":
                    other = fixture.base / "other-root"
                    other.mkdir(mode=0o700)
                    request[field] = str(other)
                else:
                    request[field] = value
                with self.assertRaises(ValueError) as caught:
                    helper.inspect_profile(request)
                self.assertNotIn("canary", str(caught.exception))

        manifest_mutations = {
            "schema": 2,
            "version": "1.18.19",
            "identity_key": "e" * 32,
            "root": "/wrong/root",
            "fingerprint": "f" * 64,
        }
        for field, value in manifest_mutations.items():
            with self.subTest(location="manifest", field=field):
                fixture = Fixture(self)
                prepared = fixture.prepare()
                manifest_path = fixture.profile_root() / "manifest.json"
                manifest = json.loads(manifest_path.read_bytes())
                manifest[field] = value
                manifest_path.write_bytes((compact_json(manifest) + "\n").encode())
                os.chmod(manifest_path, 0o600)
                with self.assertRaises(ValueError) as caught:
                    helper.inspect_profile(fixture.profile_request(prepared))
                self.assertNotIn("canary", str(caught.exception))

    def test_rejects_changed_configuration_instruction_and_manifest_hashes(
        self,
    ) -> None:
        mutations = (
            "config-file",
            "instructions-file",
            "config-hash",
            "instructions-hash",
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                fixture = Fixture(self)
                prepared = fixture.prepare()
                profile = fixture.profile_root()
                if mutation == "config-file":
                    path = profile / "xdg-config/opencode/opencode.json"
                    path.write_bytes(CONFIG_JSON.encode() + b" ")
                    os.chmod(path, 0o600)
                elif mutation == "instructions-file":
                    path = profile / "xdg-config/opencode/AGENTS.md"
                    path.write_bytes(path.read_bytes() + b"credential-canary")
                    os.chmod(path, 0o600)
                else:
                    path = profile / "manifest.json"
                    manifest = json.loads(path.read_bytes())
                    manifest[
                        "config_sha256"
                        if mutation == "config-hash"
                        else "instructions_sha256"
                    ] = "0" * 64
                    path.write_bytes((compact_json(manifest) + "\n").encode())
                    os.chmod(path, 0o600)
                with self.assertRaises(ValueError) as caught:
                    helper.inspect_profile(fixture.profile_request(prepared))
                self.assertNotIn("credential-canary", str(caught.exception))

    def test_rejects_changed_owner_mode_kind_symlink_and_unexpected_entries(
        self,
    ) -> None:
        mutations = ("owner", "mode", "kind", "symlink", "extra")
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                fixture = Fixture(self)
                prepared = fixture.prepare()
                profile = fixture.profile_root()
                patcher = None
                if mutation == "owner":
                    patcher = mock.patch.object(
                        helper.os, "getuid", return_value=os.getuid() + 1
                    )
                elif mutation == "mode":
                    os.chmod(profile / "manifest.json", 0o644)
                elif mutation == "kind":
                    target = profile / "empty-home-opencode"
                    (target / ".gitignore").unlink()
                    target.rmdir()
                    target.write_text("wrong kind", encoding="utf-8")
                    os.chmod(target, 0o600)
                elif mutation == "symlink":
                    target = profile / "credentials"
                    real = profile / "credentials-real"
                    target.rename(real)
                    target.symlink_to(real, target_is_directory=True)
                elif mutation == "extra":
                    extra = profile / "unexpected"
                    extra.write_text("unexpected", encoding="utf-8")
                    os.chmod(extra, 0o600)
                context = (
                    patcher
                    if patcher is not None
                    else mock.patch.object(helper, "AUDITED_VERSION", VERSION)
                )
                with context, self.assertRaises(ValueError) as caught:
                    helper.inspect_profile(fixture.profile_request(prepared))
                self.assertNotIn("canary", str(caught.exception))

    def test_rejects_authentication_tampering_without_returning_contents(self) -> None:
        mutations = (
            b'{"provider":{"type":"api","key":"credential-canary","extra":"x"}}\n',
            b'{"provider":{"type":"wellknown","token":"credential-canary"}}\n',
            (
                b'{"provider":{"type":"api","key":"credential-canary"},'
                b'"provider":{"type":"api","key":"other"}}\n'
            ),
        )
        for payload in mutations:
            with self.subTest(payload=payload[:20]):
                fixture = Fixture(self)
                prepared = fixture.prepare()
                path = fixture.profile_root() / "credentials/auth.json"
                path.write_bytes(payload)
                os.chmod(path, 0o600)
                with self.assertRaises(ValueError) as caught:
                    helper.inspect_profile(fixture.profile_request(prepared))
                self.assertNotIn("credential-canary", str(caught.exception))

    def test_rechecks_tree_and_file_bytes_after_manifest_validation(self) -> None:
        for mutation in ("extra-entry", "credential-replacement"):
            with self.subTest(mutation=mutation):
                fixture = Fixture(self)
                prepared = fixture.prepare()
                profile = fixture.profile_root()
                original_validate = helper._validate_manifest

                def mutate_after_validation(*args: object, **kwargs: object):
                    result = original_validate(*args, **kwargs)
                    if mutation == "extra-entry":
                        target = profile / "late-entry"
                        target.write_text("late", encoding="utf-8")
                    else:
                        target = profile / "credentials/auth.json"
                        target.write_text(
                            '{"provider":{"type":"api",'
                            '"key":"late-credential-canary"}}\n',
                            encoding="utf-8",
                        )
                    os.chmod(target, 0o600)
                    return result

                with (
                    mock.patch.object(
                        helper,
                        "_validate_manifest",
                        side_effect=mutate_after_validation,
                    ),
                    self.assertRaises(ValueError) as caught,
                ):
                    helper.inspect_profile(fixture.profile_request(prepared))
                self.assertNotIn("late-credential-canary", str(caught.exception))

    def test_inspect_request_rejects_missing_unknown_and_malformed_fields(self) -> None:
        fixture = Fixture(self)
        prepared = fixture.prepare()
        base = fixture.profile_request(prepared)
        candidates: list[dict[str, object]] = []
        for key in base:
            candidate = dict(base)
            del candidate[key]
            candidates.append(candidate)
        extra = dict(base)
        extra["extra"] = "forbidden"
        candidates.append(extra)
        for candidate in candidates:
            with self.subTest(keys=sorted(candidate)), self.assertRaises(ValueError):
                helper.inspect_profile(candidate)


class CliTests(unittest.TestCase):
    def run_cli(
        self, operation: str, payload: bytes, argv: list[str] | None = None
    ) -> tuple[int, str, str]:
        output = io.StringIO()
        errors = io.StringIO()
        code = helper.main(
            argv or ["--operation", operation],
            io.BytesIO(payload),
            output,
            errors,
        )
        return code, output.getvalue(), errors.getvalue()

    def test_prepare_cli_emits_one_compact_secret_free_json_line(self) -> None:
        fixture = Fixture(self)
        code, output, errors = self.run_cli(
            "prepare", compact_json(fixture.request()).encode("utf-8")
        )
        self.assertEqual(code, 0)
        self.assertEqual(errors, "")
        self.assertEqual(output.count("\n"), 1)
        self.assertTrue(output.endswith("\n"))
        report = json.loads(output)
        self.assertEqual(output, compact_json(report) + "\n")
        self.assertEqual(report["auth"], "authenticated")
        for canary in (
            "api-canary",
            "refresh-canary",
            "access-canary",
            "remote-config-canary",
        ):
            self.assertNotIn(canary, output)

    def test_inspect_auth_and_profile_cli_schemas_are_bounded(self) -> None:
        fixture = Fixture(self)
        prepared = fixture.prepare()
        cases = (
            (
                "inspect-auth",
                {"global_auth": str(fixture.global_auth)},
                {"auth": "authenticated", "count": 2},
            ),
            (
                "inspect-profile",
                fixture.profile_request(prepared),
                prepared,
            ),
        )
        for operation, request, expected in cases:
            with self.subTest(operation=operation):
                code, output, errors = self.run_cli(
                    operation, compact_json(request).encode("utf-8")
                )
                self.assertEqual(code, 0)
                self.assertEqual(errors, "")
                self.assertEqual(json.loads(output), expected)
                self.assertLessEqual(len(output.encode("utf-8")), 64 * 1024)

    def test_cli_rejects_duplicate_oversized_invalid_utf8_and_bad_argv_generically(
        self,
    ) -> None:
        canary = "credential-must-never-escape"
        payloads = (
            (
                "prepare",
                ('{"schema":1,"schema":1,"secret":"' + canary + '"}').encode(),
                None,
            ),
            ("prepare", b"x" * (MAX_JSON_BYTES + 1), None),
            ("prepare", b'{"secret":"\xff' + canary.encode() + b'"}', None),
            ("prepare", b"{}", ["--operation", "unknown"]),
        )
        for operation, payload, argv in payloads:
            with self.subTest(size=len(payload), argv=argv):
                code, output, errors = self.run_cli(operation, payload, argv)
                self.assertEqual(code, 2)
                self.assertEqual(output, "")
                self.assertNotEqual(errors, "")
                self.assertLessEqual(len(errors.encode("utf-8")), 256)
                self.assertNotIn(canary, errors)


if __name__ == "__main__":
    unittest.main()
