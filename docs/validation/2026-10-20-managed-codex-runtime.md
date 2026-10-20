# Managed Codex runtime validation

Date: 2026-10-20. [ISQ-491](https://linear.app/isqrd/issue/ISQ-491).
This is an implementation-stage record; managed Codex is not yet exposed.

## Baseline and explicit opt-in

The provider-free baseline at `0fafc251e86a20fe8de3fbb9dce0fda6b22e7f1f`
passed all 67 suites (`.test-results/run-ngzsfu5x`). Optional installed-provider
cases remained skipped. The new runner regression failed for the missing
`--codex` option, then passed after adding the explicit option. It verifies that
ambient Codex opt-in and OpenAI credentials are not inherited, including a
configured executable path containing spaces and non-ASCII characters.

## Installed CLI on the development host

Command:

```sh
python3 -I -B tests/run.py --codex /home/ubuntu/.codex/packages/standalone/releases/0.163.0-x86_64-unknown-linux-musl/bin/codex nvim_ai_codex_runtime
```

Result: the runner regression passed; four installed-runtime cases failed during
setup before any prompt. Each successfully initialized app-server, then
`command/exec` of `/usr/bin/true` returned exit 1 because nested Bubblewrap could
not create a namespace. Log: `.test-results/run-y6vgzvya`.
No command confinement assertion, model edit, cancellation or resume passed on
this host. The failure matches the [earlier preflight](2026-10-19-codex-app-server-preflight.md).
Both sandbox layers and host policy remain intact.

## Disposable Linux CI gate

The existing workflow now accepts an explicit `codex_runtime` boolean input.
Its default remains false. The optional job steps reuse the existing narrow
Bubblewrap AppArmor profile and the same audit; positive results are pending.
No closed state-artifact policy can be admitted until a completed real-runtime
turn and stopped-worker resume produce their metadata inventory.

The [official 0.163.0 release](https://github.com/openai/codex/releases/tag/rust-v0.163.0)
archive was downloaded to temporary storage and verified against published
SHA-256 `beb339e8ecd9ba057a6bb2dc81ad8ca474812edfbf0fc5056ca818797648dde4`.
Inspection found one regular executable, `codex-x86_64-unknown-linux-musl`,
296865480 bytes. No global installation or configuration was changed.

The local fixture follows the pinned upstream
[Responses events](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/core/tests/common/responses.rs)
and [command event fixture](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/app-server/tests/common/responses.rs).
The isolated profile directs the built-in OpenAI provider to loopback using
`openai_base_url`; only synthetic credentials enter the probes. The outer
network remains available so a passed command denial cannot be explained by
outer network isolation. Actual-account access and refresh are untested.
