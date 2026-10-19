# Claude CLI validation prerequisites

Checked 2026-10-18 for ISQ-463. This is a planning memo, not a completed runtime trial.

## Establish a reproducible runtime

Record the exact CLI version with `claude --version`, alongside the plugin commit, Neovim version, operating system, and selected model. Anthropic documents installation of an explicit release through `claude install <version>`; replace the placeholder with the chosen release. A channel such as `stable` is not an exact pin, and `minimumVersion` is only a floor. For native installations, disable background updates for the trial with `DISABLE_AUTOUPDATER=1`; verify the effective state through `claude doctor` and record the version again afterwards. This variable does not prohibit manual updates. Installation and configuration changes belong to execution, not this planning task. [Advanced setup](https://code.claude.com/docs/en/setup#install-a-specific-version), [update controls](https://code.claude.com/docs/en/setup#disable-auto-updates).

## Verify readiness without publishing credentials

The documented preflight commands are:

```sh
claude --version
claude doctor
claude auth status >/dev/null 2>&1
```

The last command reports authentication readiness through its exit status: 0 authenticated, 1 unauthenticated. Keep it separate from commands that would overwrite that status. `doctor` provides read-only installation/settings diagnostics. The unsuppressed authentication command returns JSON including the auth method and, on supported versions, configuration directory; the trial only needs readiness and a sanitized method label. [CLI reference](https://code.claude.com/docs/en/cli-reference).

Inside a later interactive trial, inspect `/status` for version, model, connectivity, and effective account selection; inspect `/permissions` for rules by scope and `/ide` for the connection. Record selected fields, not screenshots containing account identifiers. These commands are documented inspection surfaces, not proof that a provider request will succeed. [Commands](https://code.claude.com/docs/en/commands).

Do not copy credential files into evidence. Linux stores Claude credentials in `.credentials.json`; `CLAUDE_CONFIG_DIR` changes their location. A new configuration directory can therefore require a separate login, and some Console sign-ins remain outside it. Environment credentials can also change which account/provider wins. Record the chosen authentication route without its values. [Authentication](https://code.claude.com/docs/en/authentication).

## Make approval and IDE routing explicit

Start the trial with `claude --permission-mode default` and verify Manual mode in the status bar. Current documentation says recent interactive versions can start in auto mode. Existing permission rules still matter. `acceptEdits` permits file edits without prompting and therefore cannot serve as the primary approval-before-write trial; `plan` does not exercise normal edit publication. [Permission modes](https://code.claude.com/docs/en/permission-modes).

Anthropic documents `/ide` connection and `/config` → Diff tool → `auto` for its JetBrains integration. That menu entry appears only after connection; `terminal` selects terminal rendering. These are official IDE behaviors. They do not establish compatibility with Neovim: claudecode.nvim describes its implementation as reverse-engineered. Require a successful real CLI → Neovim diff round trip before running the case matrix. [JetBrains guide](https://code.claude.com/docs/en/jetbrains#claude-code-settings), [plugin README](https://github.com/coder/claudecode.nvim#what-makes-this-special).

Use a disposable independent fixture repository. A git worktree alone is insufficient settings isolation: current CLI versions can use the main checkout's local settings file. `/config` saves changes, and `/status` names loaded settings sources; managed settings can override local choices. Record relevant effective settings, including permissions and diff routing, without dumping whole files. [Settings scope](https://code.claude.com/docs/en/settings#where-claude-code-keeps-the-local-file-in-a-git-repository).

## What still requires observation

None of these pages establishes a Neovim protocol stability contract, conflict-safe publication, or durable write ordering after an IDE acceptance response. Treat those as research questions. Capture separately: proposal bytes, editor response, disk bytes before/after acceptance, intervening external edits, client result, and cleanup after rejection/disconnection. A missing diff is a failed baseline, not evidence that acceptance or conflict handling passed. No Claude installation, account operation, provider request, or production-code change was performed for this memo.

## Execution follow-up — 2026-10-19

Claude Code 2.1.303 is now pinned in an isolated temporary npm installation.
The [validation record](../validation/claude-cli-review.md#pinned-cli-preflight--2026-10-19)
records the binary hash and local results. `--version`, `--help`, `auth login --help`
and `doctor` completed with networking disabled; `auth status` returned exit 1
and `authMethod: none`. `doctor` confirmed updates disabled and no local
installation issues. Remote settings, policy and provider connectivity were not
validated. No login flow or provider prompt was started.

The installed help confirms `claude auth login --claudeai` selects a Claude
subscription and `claude auth login --console` selects Console API billing.
Choose the account route before invoking either command; never put a credential
in the report. The isolated configuration has its own authentication state.
Installation is now available for this runtime; account/model selection and the
real IDE baseline remain prerequisites. This does not complete live acceptance.
