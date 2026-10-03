# Linux/OpenCode beta acceptance checklist

Use this checklist for a named candidate. Keep the results in a separate dated
record, including the full commit ID, dirty-tree status, runtime versions,
commands, failures and evidence paths. A passing fixture run is not a release,
hosted CI result, live-account test or user-operated acceptance.

The target is core pre-write chat on Linux with Neovim 0.12+ / LuaJIT and exactly
OpenCode 1.18.34 / ACP 1. See [requirements and installation](../../README.md#requirements)
and the [test environment](../../tests/README.md). Tmux is optional for core chat;
the terminal test harness uses a private tmux server to send real keys.

## Candidate gates

Run from the candidate checkout. Record the output of `git rev-parse HEAD`,
`git status --short`, `uname -srmo`, `nvim --version`, `python3 --version`,
`bwrap --version`, `git --version`, `rg --version` and `tmux -V` when available.
Record the installed OpenCode version and executable checksum from the isolated
installed-binary check, not from a live account session.

```sh
python3 -I -B tests/run.py
stylua --check lua tests
git diff --check
```

Use the runner's printed log directory as evidence. A skipped installed-provider
case is not a provider pass. For focused reproduction, the existing suites map
to the following gates; the complete run also retains shared/native regressions.

| Gate | Existing acceptance boundary |
| --- | --- |
| Fresh installation | `nvim_ai_install`: copied plugin path with spaces, unrelated cwd, isolated HOME/XDG, public commands, helper resolution and help tags. |
| Core chat without tmux | `nvim_ai_install.test_relocated_core_chat_without_tmux`: Neovim must report no tmux executable or tmux environment; the real approval and recovery journeys still complete. |
| Discussion through continuation | `ai_chat_approval`: five explicit turns, model selection, proposals, partial accept/reject, pending discussion, revision, receipt context and exact disk bytes through the production controller and writer. |
| Actual keys and focus | `nvim_ai_chat_ui`, `ai_chat_auto_review`: Enter versus Ctrl-S, passive model choice/hide/reopen, automatic diff, typing deferral, file navigation and decisions at 140 and 70 columns. |
| Unsaved buffers and conflicts | `ai_chat_approval`, `ai_conversation_review`: source, alias and frozen-buffer changes refuse approval; prior accepted files and unsaved edits survive Cancel/Close. |
| Startup and Retry | `ai_chat_startup`, `ai_chat_recovery`, `nvim_ai_chat_ui`: actionable failures, consistent status/health, explicit proven-safe Retry, preserved drafts and unsafe Retry refusal. |
| Cancel and Close | `ai_chat_controller`, `ai_chat_approval`, `nvim_ai_conversation_controller`: bounded cancellation, confirmed cleanup, pending-review confirmation and retained uncertain outcomes. |
| Editor exit and restart | `nvim_ai_conversation_controller`, `nvim_ai_conversation_lifetime`, `ai_conversation_driver`: EOF, SIGKILL, owner death, no replay/adoption/revived authority and explicit disconnected-controller guidance. |

The installation gate is a clean runtime-path installation. A plugin-manager or
personal-config check must be recorded separately; it is not implied by copying
the checkout into the fixture. Core functionality must not depend on the optional
native companion being usable.

## Repeatable terminal journey

This launcher uses the same production-controller fixture as the maintained
tests. It selects a scripted ACP peer and three disposable files. It does not
load personal configuration, authenticate an account or need an outer tmux
session. Run it directly in a terminal, initially at least 140 columns × 42 rows.

```sh
DRAFT_BETA_PLUGIN="$(pwd -P)"
DRAFT_BETA_NVIM="$(command -v nvim)"
DRAFT_BETA_ROOT="$(mktemp -d /tmp/draft-beta-check.XXXXXX)"
chmod 700 "$DRAFT_BETA_ROOT"
for part in home config data state cache run; do
  mkdir -m 700 "$DRAFT_BETA_ROOT/$part"
done
printf 'Candidate: %s\nFixture: %s\n' "$DRAFT_BETA_PLUGIN" "$DRAFT_BETA_ROOT"
env -i \
  PATH="$(dirname "$DRAFT_BETA_NVIM"):/usr/bin:/bin" \
  LANG=C.UTF-8 TERM=xterm-256color NVIM_LOG_FILE=/dev/null \
  HOME="$DRAFT_BETA_ROOT/home" XDG_CONFIG_HOME="$DRAFT_BETA_ROOT/config" \
  XDG_DATA_HOME="$DRAFT_BETA_ROOT/data" XDG_STATE_HOME="$DRAFT_BETA_ROOT/state" \
  XDG_CACHE_HOME="$DRAFT_BETA_ROOT/cache" XDG_RUNTIME_DIR="$DRAFT_BETA_ROOT/run" \
  DRAFT_TEST_ROOT="$DRAFT_BETA_PLUGIN" DRAFT_CHAT_UI_ROOT="$DRAFT_BETA_ROOT" \
  DRAFT_CHAT_UI_SCRIPT="$DRAFT_BETA_PLUGIN/tests/fixtures/ai/chat_approval_ui.lua" \
  "$DRAFT_BETA_NVIM" --clean -u NONE -i NONE \
  --cmd 'lua vim.opt.rtp:prepend(vim.env.DRAFT_TEST_ROOT)' \
  -c 'lua dofile(vim.env.DRAFT_CHAT_UI_SCRIPT)'
```

Confirm the loaded checkout with
`:lua print(vim.api.nvim_get_runtime_file("lua/draft/init.lua", false)[1])`.
The selected files are `first.txt`, `second.txt` and `third.txt` in the printed
fixture's `project with spaces` directory. `Discuss` is a case-sensitive fixture
control word; use the prompts literally. All disk values below end in a newline.

Press `i` to type, Ctrl-S to send, and Escape for normal mode. Enter inserts a
newline. Wait for the expected state and rendered transcript after each turn.
If terminal flow control consumes Ctrl-S, use Ctrl-Q, Escape and
`:NvimAIChatSend` as described in the quickstart.

| Check | Action and expected result | Disk: first / second / third |
| --- | --- | --- |
| ☐ | Opening stays idle and sends nothing. | original text / original text / original text |
| ☐ | Send `Discuss the selected files without editing.`; wait for idle. | original text / original text / original text |
| ☐ | Type `Propose edits to all selected files.`, Escape, `gm`, choose `fixture/second-model`. The draft remains and no turn starts. | original text / original text / original text |
| ☐ | `q` hides; `:NvimAIChat` restores the draft. Press `i`, then Ctrl-S. Stay in insert mode until review is ready; the composer keeps focus. Escape presents the first pending frozen diff automatically. | original text / original text / original text |
| ☐ | Inspect SAVED SNAPSHOT / FROZEN STAGED PROPOSAL. `a` accepts first and advances; `r` rejects second and stays there. | proposed edit / original text / original text |
| ☐ | `f` returns to chat. Send `Discuss the pending proposal without editing.`. The third file stays pending; earlier decisions remain. | proposed edit / original text / original text |
| ☐ | Send `Revise the pending edit.`. Escape opens the third file's new frozen diff with `revised edit`; revision is 2. | proposed edit / original text / original text |
| ☐ | `]f` and `[f` navigate files. Return to third and press `a`; wait for idle. | proposed edit / original text / revised edit |
| ☐ | `:NvimAIChat`, `gm`, select `fixture/model`. Send `Discuss the saved results.`. Both historical model labels and accepted/rejected/accepted receipts remain. | proposed edit / original text / revised edit |
| ☐ | `:NvimAIChatClose`, wait for closed, then `:NvimAIChatNew`. New context has empty history and sends nothing automatically. | proposed edit / original text / revised edit |

The five completed turns should yield one `session/new`, four `session/resume`
and five `session/prompt` events in `chat_approval_fixture.audit`. No proposal
may change project bytes before approval. Compare disk bytes with
`:lua print(vim.inspect(vim.tbl_map(vim.fn.readfile, chat_approval_fixture.files)))`.

On a fresh run, shrink to 70 columns × 28 rows and repeat a proposal. Type an
unsent draft while waiting: it must not approve a file or lose focus. After
Escape, accept first, reject second, use `]f` to reach third and reject it.
Return with `:NvimAIChat`; the unsent draft must remain. The maintained TUI case
also checks the receipt messages and return from the narrow layout.

On separate fresh runs:

- **Full rejection:** propose edits, press `R`, confirm rejecting all three.
  Every file remains original. `A`/`R` batch actions require confirmation.
- **Unsaved conflict:** after a proposal opens, run
  `:lua local b = vim.fn.bufadd(chat_approval_fixture.files[1]); vim.fn.bufload(b); vim.api.nvim_buf_set_lines(b, 0, -1, false, {"unsaved change"})`.
  `:NvimAIChatApprove` must refuse, keep all disk files original, and retain the
  modified buffer and `unsaved change`. Close confirms retirement of the pending
  review and preserves that unsaved edit.
- **Startup failure and cancellation:** replace `chat_approval_ui.lua` in the
  launcher with `chat_startup_ui.lua`. Send a question. Missing synthetic
  credentials must show an actionable failure and preserve a later draft.
  The maintained `gr`/`gc` TUI cases restore the synthetic file, observe one
  explicit retry and cancel stalled startup. Run them through
  `python3 -I -B tests/run.py ai_chat_startup ai_chat_recovery nvim_ai_chat_ui`.
- **Exit and restart:** run
  `python3 -I -B tests/run.py nvim_ai_conversation_controller nvim_ai_conversation_lifetime ai_conversation_driver`.
  These tests stop only owned disposable processes, prove shutdown and launch a
  fresh editor against the same configuration. Re-running the launcher creates
  a different project and is not a substitute for the interruption test.

Finish with `:NvimAIChatClose`, confirm pending-review retirement if asked, wait
for closed, then
`:lua assert(chat_approval_fixture.snapshot().phase == "closed"); chat_approval_fixture.cleanup()`
and `:qa!`. Preserve results and exact artifact paths before removing that run's
directory. Failed cleanup remains a failure; see [recovery limits](2026-10-03-chat-recovery.md).

## Installed and live-provider scope

For this acceptance package, run the installed **1.18.34** artifact audit and
the following five local-provider cases. Use the allowlisted HOME/XDG invocation
in [installed audit instructions](../../tests/README.md#installed-opencode-audit-optional).
Never pass real credentials to these checks.

```sh
python3 -I -B tests/run.py --opencode /absolute/path/to/opencode ai_opencode_managed
```

Inside the documented private environment with `NVIM_AI_ACP_REAL_OPENCODE`:

- `tests/nvim_ai_conversation_interop.py -v`: four cases for retained context,
  explicit resume after cancellation, failed restoration and context overflow.
- `tests/nvim_ai_conversation_lifetime.py LifetimeTest.test_real_opencode_owner_death_stops_active_listener_without_resuming -v`:
  worker/listener shutdown and no interrupted-store adoption.

These exercise the installed binary with a scripted loopback provider. They do
not establish real provider authentication, model quality or daily usability.
Optional native resize/transport acceptance remains in the
[native record](2026-10-01-native-resize.md); it is separate from core chat.

Before a release-time live-provider run, record and approve the exact candidate,
OpenCode version, provider/model, auth-file path, disposable three-file project,
request/cost limit and operator. Proposed scope is at most four explicit prompts:
discuss the three files; request one-line changes; after accepting first and
rejecting second, revise only pending third; after approving third, discuss the
saved result. Inspect exact bytes before and after each approval, automatic
review, preserved decisions and confirmed Close. An eligible model change is
passive and must preserve historical labels. Stop on failure; do not silently
retry or widen the scope. This document does not authorize that live run.

## Result and release handoff

Record each gate as passed, failed, skipped or not run. Classify who operated it
and whether the provider was scripted or live. A failure report needs the exact
command, candidate, expected/actual behavior, source bytes and bounded diagnostics.
Route focus/navigation problems to UX 2 (ISQ-349), startup problems to Runtime 1
(ISQ-350), cleanup/recovery problems to Runtime 2 (ISQ-351), and installation/CI
problems to Release 1 (ISQ-353). Recheck affected gates on the repaired candidate.

Release 1 owns hosted CI on the final candidate, supported-version notes,
installation/upgrade/rollback notes, scoped live-provider/user acceptance and
the publication decision. Earlier live-provider evidence on 1.18.30 is historical;
it is not current-version validation. Record blockers explicitly, even when all
local fixtures pass.
