# Native resize and feedback validation — 2026-10-01

Scope: [ISQ-213](https://linear.app/isqrd/issue/ISQ-213), against the Linux alpha
commit `514d9460cf09e970ba325c29fd7aadc5e2e15ba3`, with the fixture repair and
OpenCode 1.18.34 compatibility update below.
The private resize relay, backend-readiness labels and mixed-writer guidance
were already present in the standalone extraction. This follow-up checks those
behaviors, repairs a timing-dependent acceptance-test failure, and validates
the installed OpenCode release.

## Environment and results

Linux 7.0.0-34-generic, Neovim 0.12.4, Python 3.14.4, Bubblewrap 0.11.1,
Git 2.53.0 and tmux 3.7c. The initial checks in this section used fixture provider
processes. The installed-binary checks below used synthetic credentials; no
live-account prompts were submitted.

| Check | Result |
| --- | --- |
| `tests/run.py nvim_ai_launch ai_runtime ai_session ai_review nvim-ai-native` | 5/5 suites passed, including 116 launcher tests. |
| `resize-codex`, `resize-opencode` | Zoom, unzoom, repeated resizing, visible redraw, no submitted input and clean Close passed. |
| `prompt-review-opencode` | Real-key startup retry, context handoff, nonblocking feedback, explicit fake-agent edit and native review/rejection passed. |
| `review-conflict` | Mixed-writer guidance, unchanged disk contents, preserved unsaved buffer and disabled automatic rejection passed. |
| `notice-layouts` | Nonblocking notices across 113×40, 40×10, 20×6 and 12×4 terminals, with `cmdheight` 0 and 1, passed. |
| `size-guard-opencode` | The repaired real-key recovery case passed six consecutive runs. |

After the fixture repair, `python3 -I -B tests/run.py` passed **58/58 suites,
0 failures**. Installed-OpenCode opt-in cases remained skipped. Python syntax,
`stylua --check lua tests`, local documentation links and `git diff --check`
passed. An independent review found no actionable issues in the fixture change
or acceptance documentation.

Run the named TUI cases with `sh tests/nvim-ai-native.sh CASE`; they supplement
the default native lifecycle suite. Reproduction commands are in the
[testing guide](../../tests/README.md#native-resize-and-feedback).

The initial restricted-sandbox attempt could not create Unix sockets and masked
host executable ownership. Checkout helpers were also group-writable. Helper
permissions were corrected using the testing guide's `chmod go-w` command, and
the passing checks ran in the approved environment with working sockets and
namespaces. Production permission and confinement checks were preserved.

## Acceptance-test repair

The original size-guard case failed in three of six diagnostic runs at the
second `NvimAIOpen`, with `AI companion failed; inspect with :NvimAIStatus`.
At every captured failure, the companion had already reopened in the same
40-column pane, status was `open`, and the fake CLI had recorded the expected
third launch. The RPC `execute()` call received the scheduled error notice from
the earlier shrink; its error result did not describe the reopen outcome.

The fixture now enters `:NvimAIOpen` through real editor keys and checks the
exact launch count and live pane. It also verifies the saved session, grants,
review identity and unsaved source buffer after recovery. Existing checks still
require stopping below 40 columns, refusing unsafe initial startup, preserving
source state, avoiding prompt replay and cleaning up on Close.

## OpenCode 1.18.34 compatibility

OpenCode was initially missed because its installation directory was outside
the agent's PATH. A subsequent search found `~/.opencode/bin/opencode`; an
isolated `--version` check reported **1.18.34**. Its SHA-256 was
`9ca0b9953d49997601655e54f846a3efa464f237e47c6f1b04716d0f2e64c4c2`.

Before the compatibility update, the separate installed-binary audit ran with
`tests/run.py --opencode /absolute/path/to/opencode ai_opencode_managed`.
It failed with **`version-mismatch`**, because Draft's audited version was
1.18.30. The audit reported proved shutdown and sent no model request. This
was the expected rejection before updating the pin.

All active version gates now require exactly **1.18.34 / ACP 1**: compatibility
probes, managed profiles, launcher manifests, transport metadata, staging, and
conversation workers. The existing configuration, agent/tool policy, artifact
rules, confinement checks, and cleanup requirements are unchanged. Durable
1.18.30 and 1.18.28 profile references remain readable only for explicit
close/reopen recovery. They cannot authorize launch or adoption. Recovery
preserves saved session and review references and prepares a new profile.

The five targeted suites first failed against the old implementation, then
passed after the update, including the installed-binary artifact audit.
The following additional checks passed with the installed 1.18.34 executable:

| Check | Result |
| --- | --- |
| `ai_opencode_managed` with `tests/run.py --opencode` | Installed artifact/CLI audit passed; targeted session, identity, transport and sandbox suites also passed (5/5). |
| `nvim_ai_acp_resume.py` | 4 tests passed, including native-tool history, fresh-worker resume, model choice and cancellation. |
| `nvim_ai_conversation_interop.py` | 4 production-controller tests passed, including restoration failure and provider context overflow. |
| `nvim_ai_conversation_lifetime.py` | 5 tests passed, including real OpenCode owner-death/listener cleanup. |
| `nvim_ai_staged.py`, `nvim_ai_staged_multi.py` | 20 and 10 tests passed, including real native edits through a loopback scripted provider. |
| `nvim_ai_opencode_cache.py` | 20 tests passed. Installed cold validation used 12 probes; a fresh editor reused the receipt with 0 probes (about 11 s versus 41 ms). Normal-runtime caching passed too. |
| `nvim-ai-opencode-compat.sh`, `nvim-ai-opencode-probe.sh` | Strict installed-binary confinement/compatibility and permissive-caller-umask checks passed. |
| Native `version-upgrade-opencode`, `resize-opencode`, `size-guard-opencode`, `prompt-review-opencode` | All 4 fixture cases passed with the new pin. Upgrade recovery starts from a 1.18.30 reference. |

All Python opt-ins ran in fresh HOME/XDG directories with an allowlisted
environment. Conversation and staged edits used only local scripted providers.
The optional commands and flags are documented in the
[testing guide](../../tests/README.md#installed-opencode-audit-optional).

After the compatibility update, the full `python3 -I -B tests/run.py` run passed
**58/58 suites, 0 failures**. The default suite still skips installed-binary
opt-ins; those were enabled separately above. `stylua --check lua tests` and
`git diff --check` passed. Independent code review found no actionable issues.

Local evidence is under `.test-results/run-cjluhfy5` (targeted red),
`run-8m7r22ax` (targeted green and installed audit),
`opencode-1.18.34-10dv20bi` (12 additional checks), and `run-5mehozxe` (full suite).
Logs are local artifacts, not tracked release evidence.

## Real OpenCode terminal smoke

An agent-operated smoke check loaded the candidate checkout in fresh Neovim
instances, replaced the native fixture's OpenCode executable with the installed
1.18.34 binary, and retained its disposable project and synthetic credentials.
It submitted no prompt. Actual terminal captures showed OpenCode's prompt and
an explicitly typed, unsent text sentinel throughout resizing.

- The tmux companion passed zoom/unzoom and repeated redraw at 200×60, 80×60,
  52×43, 44×20 and 80×60. Its launcher PID and unsent prompt remained unchanged.
- A fresh editor with `TMUX` and `TMUX_PANE` unset exercised Draft's Neovim
  terminal transport. It passed redraw with outer terminals of 160×45, 128×30
  and 200×60; its companion window was kept at 64–70 columns. The same terminal
  job and unsent prompt survived each resize.
- Both transports stopped below 40 columns, displayed the width diagnostic,
  reopened on explicit `:NvimAIOpen`, left the fresh-state session/review/grant
  fields unchanged, preserved unsaved source buffers, and passed `:NvimAIClose`.
  Reopening did not replay the unsent terminal text. Close removed the owned
  companion. Preservation of populated session and review references is covered
  by the upgrade and size-guard fixtures, not this fresh-state smoke check.

The successful captures are in `.test-results/real-opencode-tui-i3a6t2xv`.
This was an ad hoc installed-binary smoke check, separate from the maintained
provider-free fixture suites. Its initial harness needed wrapped-line matching,
a shorter temporary path for Linux's Unix-socket limit, and waits for stopped
state and replacement terminal buffers. Those harness corrections required no
additional production changes. The final complete smoke run passed.

## Remaining manual acceptance

Cross-version migration of OpenCode's own database and user-performed everyday
acceptance are not established by these checks. Actual Codex rendering and
live-account native context handoff remain outside this OpenCode follow-up.

Use a disposable project and a fresh editor loading the candidate plugin, with
the supported OpenCode 1.18.34 / ACP 1 installation and tmux 3.7+:

- [x] Record plugin baseline, candidate changes, Neovim, tmux and OpenCode versions.
- [ ] Open the backend picker and verify checking, ready and failure feedback
  agrees with `:NvimAIStatus` and `:checkhealth draft` in that same editor.
- [x] Open OpenCode, zoom/unzoom and repeatedly resize its unsent prompt without
  restarting; repeat in a fresh Neovim terminal split outside tmux.
- [ ] Repeat actual-CLI resizing for Codex and inspect existing reply output.
- [x] For OpenCode, shrink below 40 columns, check the width diagnostic, widen
  to at least 40 and explicitly reopen. Verify the fresh-state fields and
  unsaved source contents remain intact; no prompt is automatically submitted.
- [ ] Prepare context with `:NvimAIPrompt` and verify its handoff/retry guidance.
  Inspect an existing mixed-writer review; check the file and manual-resolution
  explanation while preserving unsaved buffers and disabled automatic rejection.
- [x] Close each tested OpenCode companion and record cleanup.
