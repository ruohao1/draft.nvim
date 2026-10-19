# Codex app-server design preflight

Date: 2026-10-19. Tracks [ISQ-491](https://linear.app/isqrd/issue/ISQ-491).
Design: [managed Codex conversation and review](../superpowers/specs/2026-10-19-managed-codex-design.md).

## Result

The installed CLI supplies a usable app-server protocol surface for the proposed
adapter. Local initialization, thread creation and graceful EOF shutdown worked
without credentials or model requests. Empty-thread resume was correctly
refused. Command confinement inside Draft's outer sandbox is **not yet proven**:
the default nested sandbox failed at namespace creation, and the legacy Landlock
option refused the required policy. No integration success is claimed.

## Inputs and provenance

| Input | Value |
| --- | --- |
| Draft base | `bba5c4bfda8f1f779348bd5b776235924a07c90d` |
| CLI | `codex-cli 0.163.0`, existing standalone Linux musl installation |
| Binary bytes | 296865480 |
| Binary SHA-256 | `399ff69c431c066e40de318fba45c2b07f45a76b19939d247ee4828fc70c4215` |
| CLI schema generation | `codex app-server generate-json-schema --out <private-temp>/schema`, without `--experimental` |
| Generated JSON schemas | 318 |
| Temporary research root | `/tmp/draft-codex-schema-hvx1hjl7` |

Schema generation used an empty temporary HOME/CODEX_HOME. The CLI warned that
it would not create helper aliases under `/tmp`; schema generation exited 0.
The server probes instead used a private home mounted at `/home/agent` inside
the sandbox. No installed binary or global configuration was changed.

Selected schema hashes:

| File | SHA-256 |
| --- | --- |
| `v2/ThreadStartParams.json` | `e9c6d3cc18d049bfbc0249add3808fb8e5a27e1a0b5a423767aafbc3859a9428` |
| `v2/TurnStartParams.json` | `835e0d4ca1a0ddc4fb6db1e2b3249dd67f07c50ac2506092ba81543efc92829b` |
| `v2/TurnCompletedNotification.json` | `69413578ec3ecd02691424bdeb9d640c7244b4ca4c5c3ef26f69a2efe7c37db8` |

## What was exercised

All app-server probes ran inside a disposable Bubblewrap filesystem with a
clean environment, no host home/project mount, no authentication file, no editor
socket, and `--unshare-net`. Only system runtime files, the Codex binary, a new
private state directory and an empty disposable project were available.

The protocol script sent `initialize`, `initialized`, `thread/start`, closed
stdin and waited for exit. A fresh process tried `thread/resume` with the same
private state and returned thread ID. It never sent `turn/start`.

The refined profile disabled bundled skills and set workspace-write temporary
directory exclusions. The command probe additionally called `command/exec`
with a local Python assertion script and this sandbox policy:

```json
{
  "type": "workspaceWrite",
  "writableRoots": ["/tmp/project"],
  "networkAccess": false,
  "excludeTmpdirEnvVar": true,
  "excludeSlashTmp": true
}
```

The assertions would write only a new disposable `/tmp/project/probe.txt`,
require denial of writes to private Codex state and another `/tmp` path, require
denial of a network socket, and check that the host project was absent. Both
sandbox variants failed before this assertion script executed. These are
**unrun confinement assertions**, not passing checks.

| Observation | Evidence and interpretation |
| --- | --- |
| Initialization | Response identifies 0.163.0, Linux/unix and the isolated Codex home. Frames have `id`/`result`, without `jsonrpc`. |
| Thread creation | Returns the selected model, `openai`, `/tmp/project`, `never`, reviewer `user`, and a `workspaceWrite` sandbox. This does not establish model availability or account access. |
| Notifications | `configWarning` and `remoteControl/status/changed` include top-level `emittedAtMs`; response data includes additive fields beyond the stable schema projection. |
| Empty-thread resume | Error -32600: no rollout found for the thread ID. No user message had materialized it. This is an expected negative control, not a resume implementation failure. |
| Shutdown | Both start and resume probe processes exit 0 after stdin EOF. No running worker is retained. |
| Default command sandbox | `command/exec` returns exit 1: nested Bubblewrap cannot create a namespace. The assertion script does not run. |
| Explicit legacy Landlock | `command/exec` returns exit 101: the runtime requires Bubblewrap to isolate app-server sockets for filesystem-restricted execution. No safe fallback established. |
| Independent reproduction | An installed `/usr/bin/bwrap` inside another installed Bubblewrap, with only system mounts and `true`, fails with the same namespace-creation error. Failure is not dependent on a model, credential, or Draft turn adapter. |

The host permits the outer Bubblewrap but refuses the tested nested namespace.
Read-only diagnostics showed unprivileged user namespaces enabled and AppArmor's
unprivileged-user-namespace restriction enabled. The precise kernel/profile
denial was not established from an audit log. No security setting was changed.

Temporary evidence files include `probe-protocol.json`,
`probe-confined-protocol.json`, `probe-landlock-protocol.json`, the generated
schemas and the two probe scripts. These files are local research evidence, not
runtime dependencies or a substitute for checked-in acceptance tests.

## State observations

Even without a model turn, the refined profile creates `state_5.sqlite`,
`goals_1.sqlite`, `logs_2.sqlite`, `memories_1.sqlite` and `queue_1.sqlite`, with
some SQLite sidecars. It also creates `thread-writer-locks`, helper scratch
directories and migration/installation markers. A disabled memory feature does
not mean its database is absent.

Retained directories were mode 0700 and the observed payload/lock files mode
0600. `installation_id` was mode 0644 behind the private directory. The initial
profile also installed bundled system skills; `skills.bundled.enabled = false`
removed that behavior in a fresh home. No rollout existed because no turn was
submitted. These observations are an initial inventory, not a complete allowed
state list for completed/resumed/authenticated turns.

## Source checks

- [Official app-server documentation](https://learn.chatgpt.com/docs/app-server)
  describes custom clients, thread/turn events and interruption. The installed
  schema remains the implementation baseline where examples differ.
- [Pinned configuration schema](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/core/config.schema.json)
  contains the relevant isolation/profile settings. Its downloaded SHA-256 is
  `e9dd16b9d1710e57b020e42da4af6d6606e8f44cb028a2e94196dee3890d9170`.
- [Pinned rollout recorder](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/rollout/src/recorder.rs#L882)
  defers new rollout creation until persistence.
  [The upstream negative test](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/app-server/tests/suite/v2/thread_resume.rs#L450)
  explicitly refuses resume before the first user message materializes storage.
- [Pinned authentication storage](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/login/src/auth/storage.rs#L47)
  defines file-based API-key/ChatGPT-token data; its file writer uses mode 0600.
  This is source evidence, not a successful authentication or refresh test.
- [Pinned Linux sandbox policy check](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/linux-sandbox/src/linux_run_main.rs#L411)
  explains why legacy Landlock cannot satisfy this filesystem-restricted path.

## Remaining evidence

First obtain a positive command-confinement result with the supported default
sandbox on a suitable launcher/host, keeping the same assertions. Then use a
synthetic local provider to validate actual turn completion, cancellation,
persisted-thread resume and state inventory with the pinned CLI. Build the
adapter against those facts and drive the existing real Neovim review/publisher
path. Real-account Codex acceptance remains a separate explicit opt-in.

No paid provider request, real credential read, login, installation, global
configuration change, product code change or full repository test run occurred
in this investigation. The two documents are the only intended branch changes.
