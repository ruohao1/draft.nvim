# Using Draft

Start with the [README walkthrough](../README.md#start-with-opencode-chat).
Use `:help draft` for the full command and option reference. This guide covers
configuration choices, advanced tasks and recovery.

## Codex

Managed Codex requires a development checkout. The published `v0.1.0-beta.1`
provides OpenCode chat. Follow the
[development installation instructions](releases/install-upgrade-rollback.md#choose-an-available-version),
then configure Codex on the first setup call:

```lua
require("draft").setup({
  chat = {
    backend = "codex",
    model = "openai/<advertised-codex-model>",
    auth_store = "/absolute/private/path/to/draft-codex",
    -- codex = "/absolute/path/to/codex",
  },
})
```

Install the native **Codex 0.163.0** CLI and matching `codex-code-mode-host` in
the same directory. The complete `codex-package` release archive includes both
under `bin/`; point `chat.codex` at `bin/codex`. The single-CLI archive is
insufficient. The companion must be a regular executable, owned by you or root,
with no symlink or group/world write access. Draft validates both files and
mounts them read-only. A missing or unsafe companion refuses Send and keeps the draft.

Choose an explicit `openai/model` from the advertised catalog. On Send, Draft
checks the CLI version, model and nested sandbox, including whether commands
can read private credentials. Unsupported hosts refuse before submission, with
no unconfined or native fallback. Setup, opening chat, status and health do not
import credentials or launch app-server.

Use the same `:NvimAIChat`, Send and frozen-review workflow as OpenCode. A `chat`
table is a complete configuration; it does not inherit staged credentials,
provider options or saved preferences. Omit it to use the saved OpenCode setup,
or choose `backend = "opencode"` with explicit model/auth/provider options.
Both forms accept `root`, `python` and `bwrap`. Only the selected CLI is required.
The backend stays fixed until the conversation closes.

For a saved ChatGPT login, use `chat.auth_store`. Create a fresh login in a
dedicated directory. Do not copy the CLI or IDE's tokens: a copy still shares
their refresh-token family. Do not run another Codex client against this directory.
Before login or logout, stop all Draft Codex workers.

```sh
umask 077
draft_codex_home="$HOME/.local/state/draft-codex"
mkdir -p "$HOME/.local/state"
mkdir -m 700 "$draft_codex_home" # Choose a new directory if this already exists.
CODEX_HOME="$draft_codex_home" codex -c 'cli_auth_credentials_store="file"' login
chmod 600 "$draft_codex_home/auth.json"
```

Set `chat.auth_store` to that directory's absolute, canonical path. Draft requires
an owned **0700** directory and an owned, single-link regular **0600** `auth.json`,
at most **1 MiB**. Symlinks are refused. Bubblewrap must support `--bind-fd` and
`--sync-fd`; **0.11.1** is tested. Unsupported hosts refuse before reading credentials.

On each Send, Draft takes an exclusive local lease. Codex writes refreshed tokens
directly to the dedicated file. Other Draft conversations can use the same login
after the worker stops. A busy login preserves the draft and thread; wait for the
other worker, then explicitly Retry or Revise. Idle chat and frozen review hold
no lease. A different ChatGPT user or workspace requires a new conversation.

Close removes conversation data and retains this login. To sign out after all
workers stop, run `CODEX_HOME="$draft_codex_home" codex -c 'cli_auth_credentials_store="file"' logout`.
If a refresh is interrupted, the upstream file writer can leave incomplete or
unusable credentials. Draft preserves that file and never restores an older
token seed. Close the affected conversation and perform a fresh dedicated login.

For API keys, set `chat.auth_file` to an owned, single-link **0600** credential
file instead. Draft copies it and leaves the source unchanged. Set exactly one
of `auth_file` and `auth_store`. **Migration:** saved ChatGPT tokens configured
through `auth_file` are now refused before worker launch; create the separate
login above and change the option to `auth_store`.

Commands can read system tools and selected copies; credentials and conversation
state remain outside their readable filesystem. Draft does not import global or
project configuration, export credentials, or start login. The lease coordinates
cooperating local Draft processes; it does not coordinate another CLI or IDE.
Unsafe conversation cleanup still requires recovery. Real-service login and
refresh remain a separate opt-in acceptance check.

A start acknowledgement is not a finished edit. Frozen review waits for matching
terminal completion, process exit and source/state validation. Cancel needs a
matching interrupted event before continuation is eligible. Failed resume does
not start a replacement thread or replay the request. See `:help draft-chat-codex`
and the [runtime](validation/2026-10-20-managed-codex-runtime.md) and
[code-mode host](validation/2026-10-27-codex-companion.md) validation records for
their specific evidence and limits.

## Models and conversation state

After the first explicit Send negotiates model choices, press `gm` while idle
or run `:NvimAIChatModel`. Selecting a model sends nothing and does not change
saved defaults. The header's `next:` label applies to the next turn; earlier
replies retain their own model labels. Finish or discard pending review before
switching. A new conversation uses the configured default again.

Opening, hiding and reopening chat are passive. A Send transmits your instruction
and selected contents to the configured provider. The editable selection contains
1–16 saved existing files, at most 1 MiB combined. It stays fixed for the conversation.
Unsupported permissions or changed sources refuse submission and preserve the draft.

The transcript uses the current theme. It has distinct role and review labels;
provider text remains literal. Current guidance follows the latest reply. Chat
uses a right split at 100 or more columns and a bottom split in narrower editors.
Below 40 columns or 12 rows, it hides while retaining the draft. Resize, then
run `:NvimAIChat` to reopen it.

The visible transcript keeps the newest 2 MiB / 20,000 lines and marks omitted
history. The owner retains at most 64 turns and 32 MiB; the composer limit is
32 KiB. See `:help draft-chat` for the complete limits and lifetime rules.

## Context and corrections

These features require development code beyond the published beta.

To attach read-only context, open another text buffer and run
`:[range]NvimAIChatAttach`. With `keymaps = true`, Visual-mode `<leader>at`
attaches the selection to an existing chat. Attaching uses current buffer bytes,
including unsaved text, and appends them to the composer without sending or saving.
It does not add editing authority. Verify the appended context before Send.

`:NvimAIChatDiagnostics` appends cached diagnostics for the current buffer;
`:12,20NvimAIChatDiagnostics` limits the range. The text records capture time,
modified state and unverified freshness. It does not request fresh LSP diagnostics.
Snapshots, diagnostic counts and appended text are bounded; refusals preserve the draft.
See `:help draft-chat` for path/scope restrictions and exact limits.

To adjust a pending proposal yourself:

1. Open its diff and run `:NvimAIChatEditProposal`.
2. Edit the separate scratch buffer. The saved and proposed review panes stay read-only.
3. Run `:NvimAIChatFreezeProposal` to create a new review revision.
4. Inspect the replacement diff, then explicitly accept or reject it.

`:NvimAIChatDiscardCorrection` discards the correction, with confirmation when
edited. One correction can be active. Send and approval wait until it is frozen
or discarded; freezing never publishes. Exact UTF-8, newline, size and revision
rules are in `:help draft-chat-corrections`.

## Other workflows

### Standalone staged edits

Run `:NvimAIStageSetup` and save an explicit OpenCode model and optional auth path.
Then use `:NvimAIStage` for the current saved file or `:NvimAIStageFiles` to select
several files. Review and accept/reject the frozen proposal before project writes.
In this workflow, `f` revises pending proposals; in managed chat, it returns to chat.

Use `:NvimAIStageStatus` for phase and artifact paths, `:NvimAIStageReview` to
reopen review, and `:NvimAIStageCancel` to cancel. `:NvimAIStageReset` confirms
forgetting preferences and disabling staging. It does not change the saved
prompt review mode.

`:NvimAIReviewMode pre_write` explicitly routes `:NvimAIPrompt` through staging.
This is separate from chat, which always reviews before write. See
`:help draft-staged-review` for Lua configuration and all staged commands.

### Native CLI companions

Native companions use **after-write review**: the CLI can write within its
authorized scope before you inspect the changes. Acceptance acknowledges those
changes; rejection uses the saved baseline and source checks.

Choose `:NvimAIBackend [codex|claude|opencode]`, then run `:NvimAIOpen`.
`:NvimAINativePrompt` prepares context and a review baseline, transfers the prompt,
and focuses the CLI without submitting. Inspect it, then submit in the CLI.
`:NvimAIReview` opens detected changes in a searchable picker. Escape closes the
picker without a decision. `:NvimAIClose` closes the companion.

Close the companion and resolve or explicitly abandon native review before
staging or managed chat. One native runtime pins one physical project/worktree;
use separate Neovim instances for different roots. Native prompting is the
initial `:NvimAIPrompt` mode. See `:help draft-native-review`.

## Safety and recovery

### A turn fails or stalls

Use `:NvimAIStatus` or `:checkhealth draft` for the current phase, startup step
and recovery reason. These diagnostics exclude credentials and conversation text.
Health defers native account probes while managed chat is configured or open.

Use `gc` or `:NvimAIChatCancel` to stop waiting. Cancellation waits for worker
cleanup; a window closing is not proof that a worker stopped. Retry is offered
only when the controller proves it safe. Fix missing credentials at the configured
path before retrying. A new path or model requires Close and setup for a new chat.

`gr` / `:NvimAIChatRetry` sends the current nonempty draft, or otherwise retries
the failed prompt. It checks the selected sources again and never submits
automatically. A refused retry preserves the draft. When retry is unavailable,
follow the displayed close/recovery guidance. `:NvimAIChatNew` starts fresh context
after confirmed close; it does not resume a previous editor process.

### Approval and retained data

Publication across several files is **not atomic**. An external writer can race a
final rename. After a partial or uncertain outcome, inspect the files and receipts.
Do not reuse approval tokens, assume rollback, or treat Close as clearing uncertainty.
Earlier accepted files remain saved when later proposals are rejected or cancelled.

Bubblewrap provides filesystem isolation; it is not a network firewall or protection
against unrelated programs running as your user. Selected credentials are copied
into private provider state; project configuration and unrelated buffers are not
implicitly imported. Keep retained artifacts private because they can contain code
and session data.

| Data | Location |
| --- | --- |
| Native runtime | `$XDG_RUNTIME_DIR/draft.nvim/`, or `/tmp/draft.nvim-<uid>/` |
| Native durable records | `$XDG_STATE_HOME/draft.nvim/`, or `~/.local/state/draft.nvim/` |
| Staged preferences | `stdpath("state")/draft.nvim/staged/settings.json` |
| OpenCode compatibility cache | `stdpath("cache")/draft.nvim/opencode-compat/` |

Preferences store an auth-file path, not credentials. Proposal snapshots and
receipts can retain contents in private `/tmp/nvim-ai-staged-*` directories. The
legacy prefix is intentional; these directories are not reusable conversations.
Draft does not adopt previous companion state automatically.

Crash recovery and retention management are incomplete. SIGKILL can leave private
`/tmp/draft-conversation-config-*` launch files; interrupted cache writes can leave
untrusted `.receipt-*` files. No automatic aggregate retention limit is provided.
Inspect only the exact artifact path reported by status, and confirm its users
have stopped before cleanup. Do not delete whole temporary-directory families.

See `:help draft-state`, the [recovery record](validation/2026-10-03-chat-recovery.md),
and [testing and validation](../tests/README.md) for checks and limits. Local
fixtures, installed-runtime audits and live-account acceptance are separate evidence.
