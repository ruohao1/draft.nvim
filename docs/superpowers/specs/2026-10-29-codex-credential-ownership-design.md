# Durable Codex credential ownership

Status: approved and implemented on the feature branch on 2026-10-29.
See the [implementation validation](../../validation/2026-10-29-codex-credential-ownership.md).
Base: Draft `e7131e4c5084392238a986a54570133e7a161428`; Codex `0.163.0`.

## Decision

Give managed Codex chat a dedicated, persistent credential directory. The user
signs in once through Codex with a separate `CODEX_HOME`. They can use the same
ChatGPT account. Copying the CLI or IDE's existing tokens does not create a
separate login session.

Each Draft worker writes to the same credential file while it holds an exclusive
lease. Conversation databases, transcripts and staged files keep their current
temporary owners. Close removes conversation data and retains the login.

This replaces the saved-ChatGPT-token import contract in the
[managed Codex design](2026-10-19-managed-codex-design.md). Implementation,
migration documentation and synthetic acceptance are complete. Live login
acceptance remains a separate opt-in task.

## Evidence and approaches

At the baseline revision, `Store.initialize()` copies `chat.auth_file`.
Codex can update the copy across turns. `Store.close()` deletes it.
A new conversation imports the old
source again. The recorded synthetic refresh probe used the real pinned Codex
runtime and a loopback rotating-token authority. It verified replacement-token
reuse in one store and rejection of a stale import in another. This is evidence
of the client behavior under that fixture, not the live service's token policy.

The pinned [file backend][storage] truncates and rewrites `auth.json` in place.
It flushes the write, but does not use atomic replacement or `fsync`. The
[authentication manager][manager] serializes refreshes within one manager and
reloads changed credentials before refreshing. This is not a shared process
lock. Official [persistence guidance][persistence] also calls for retaining the
updated credentials and serializing their use.

| Approach | Consequence | Decision |
| --- | --- | --- |
| Dedicated Draft login and writable file | Codex keeps its refresh implementation. Draft owns persistence and serializes its workers. Requires a separate login and stronger Bubblewrap support. | Selected. |
| Shared CLI/IDE credentials or copy-back | Independent clients can refresh concurrently. Copy-back can overwrite newer tokens. Draft-only locking cannot coordinate those clients. | Do not offer without a verified shared coordination contract. |
| Host-owned authentication broker | Workers receive external access tokens. A new owner handles refresh requests, durable storage and account recovery. | Defer. Draft does not already own that lifecycle. |

The [external-token app-server mode][external] exists in the
[pinned handler][external-pinned] and current documentation, but it moves refresh
responsibility to the host. It is an alternative architecture, not a persistence
setting.

## Configuration and migration

Add one Codex-only option:

```lua
chat = {
  backend = "codex",
  model = "openai/<model>",
  auth_store = "/absolute/path/to/draft-codex",
}
```

`auth_store` accepts saved ChatGPT credentials only. It names an owned mode-0700
directory containing an owned, single-link, mode-0600 `auth.json`. Draft uses
only that file and its private lease file. It does not import configuration or
adopt other files from the directory. Reject symlinks, unsafe ancestry,
unsupported credentials and oversized input using the existing bounded validation
rules.

Exactly one of `chat.auth_file` and `chat.auth_store` is permitted. Keep
`auth_file` as the unchanged, copied API-key path. On explicit Send, refuse
saved ChatGPT tokens through `auth_file` with migration instructions before
starting a worker. Do not silently enable write-back or copy an existing login
into `auth_store`. This is an intentional compatibility change.

The setup instructions require a fresh Codex login with the dedicated directory
as `CODEX_HOME` and file credential storage. Other clients must not use that
directory or a copy of its token set. Draft cannot prove token-family exclusivity
from file contents. The requirement must be explicit in setup and recovery docs.

Setup, chat opening, status and health remain free of credential reads, provider
requests and login flows. Configuration checks can validate the option shape.
The first Send performs credential validation. API-key behavior, OpenCode and
the legacy terminal Codex adapter remain outside this change.

## Ownership and runtime contract

The trusted Python controller owns the credential lease. Use a persistent
private lock file in `auth_store`, shared by all Draft editor processes on the
same host. Acquire a nonblocking exclusive `flock` before reading credentials
or starting any Codex worker. Refuse contention with a retryable message and
preserve the prompt. Do not queue or automatically resubmit it.
Never unlink or replace the lease file during normal operation or cleanup.

After acquiring the lease, read the current credential file again through
verified descriptors. Bind the conversation to both the ChatGPT user ID and
workspace ID, following the pinned [ownership comparison][owner]. Use
`tokens.account_id` for the workspace and the ID token's
`https://api.openai.com/auth` claim for the user: `chatgpt_user_id`, with `user_id`
as the [pinned parser's fallback][token-data]. Require both values to be nonempty
bounded strings.
Refuse missing identity, a different user in the same workspace, or a workspace
change before resume. Bounded local claim decoding establishes continuity, not
cryptographic token validity. The service remains the authentication authority.
Do not retain token bytes in Lua, diagnostic events or saved preferences.

Mount the verified credential file over a nonsecret placeholder at
`/home/agent/.codex/auth.json`. The rest of `CODEX_HOME` remains the current
per-conversation store. Use a descriptor-backed writable bind, so a pathname
replacement cannot redirect the mount. This relies on the pinned Codex file
backend's in-place writes. A future backend that renames its auth file requires
a new compatibility decision. While a worker runs, guard the pinned file's
identity, ownership, mode, link count and size limit. Do not parse or require
stable token bytes while Codex can be rewriting them.

Keep the existing nested command deny rule for `auth.json`. Mount no credential
parent directory, lease file or general user home. Pass only the descriptors
needed for sandbox setup. The credential descriptor must close before Codex
executes; the lease descriptor must not reach Codex or model commands.

Retain the lease for the entire worker lifetime, including startup, background
refresh and shutdown. The proposed mechanism passes a separate lease descriptor
to Bubblewrap's [`--sync-fd` supervisor][bwrap-supervisor]. Keep the default PID-1
supervisor and `--die-with-parent`. Parent process death must not release
ownership while a credential writer survives. This lifetime guarantee needs a
runtime regression test before implementation can be accepted.
On uncertain exit, close only the controller's descriptor; do not explicitly
unlock the shared open-file description while the supervisor can still hold it.

After proven worker exit, validate the current credentials and account binding,
then `fsync` the file before releasing the controller's lease. A validation or
sync failure is a visible failure; preserve the file and do not restore an old
seed. Resume reads the latest credentials under a new lease. Idle conversations
and frozen reviews hold no lease and retain no private token copy.

The current temporary-store seals and cleanup checks continue to cover only
conversation state and the nonsecret mount placeholder. They must not adopt,
seal or delete the persistent credential owner.

## Close, interruption and recovery

| Event | Required outcome |
| --- | --- |
| Completed turn or acknowledged Cancel | Prove worker exit, validate credentials, synchronize the file and release the lease. Preserve the existing continuation rules. |
| Close or early-startup cleanup | Remove only owned conversation state after exit. Keep credentials. Close does not sign out or revoke a token. |
| Another editor sends while busy | Refuse before provider startup. Preserve its prompt. A later explicit Send reads the latest file. |
| Crash or forced shutdown | Preserve the credential file and existing conversation taint rules. Hold the lease until the sandbox writer has exited. Never restore the original tokens. |
| Corrupt or missing credentials | Refuse before starting a worker. Require a fresh dedicated login; do not repair from a cached copy. |
| Rejected refresh or changed account | Report recovery without token values. Do not automatically resubmit a model turn or loop through login attempts. |

A valid JSON file does not prove that a refresh token is still accepted. A crash
between server rotation and local persistence can lose the replacement token.
An interrupted in-place write can also corrupt the file. This proposal preserves
completed refresh writes across normal Close and restart; it does not promise
crash-atomic OAuth refresh. The user may need to sign in again.

Recovery and sign-out remain explicit Codex operations outside Draft. The user
first stops all Draft workers for this directory, then runs login or logout with
that dedicated `CODEX_HOME`. Do not run those operations concurrently with Draft.
No new login dialog, sign-out command, background refresh daemon or backup token
store is required. The lease coordinates cooperating local Draft processes; it
does not coordinate another machine, a manual CLI invocation or an unrelated
program running as the same user.

## Compatibility and implementation scope

Owned credentials require descriptor-backed binding and supervisor lifetime
support. Local Bubblewrap 0.11.1 advertises `--bind-fd` and `--sync-fd`.
[Bubblewrap 0.9.0][bwrap-old] has `--sync-fd` but lacks `--bind-fd`; its normal
bind path resolves symlinks, so `/proc/self/fd/N` is not an equivalent fallback.
Refuse unsupported hosts before reading or mounting credentials. Do not weaken
the binding contract. The implementation must provide a verified Bubblewrap
version for the owned-credential CI audit and document this extra requirement.

The implementation reaches the Lua conversation configuration and diagnostics,
the Python conversation configuration, Codex store/runtime/turn lifecycle, and
the shared worker's tightly scoped descriptor handoff. Reuse the existing secure
path and credential validators. Add one bounded credential owner; do not build
a general account manager. Keep shared-worker defaults unchanged for OpenCode.

Update `README.md`, `docs/usage.md`, `doc/draft.txt`, the affected managed-Codex
design paragraphs and the changelog together. Keep this proposal and the later
implementation plan on the feature branch with the implementation PR.

## Acceptance evidence required

1. A synthetic rotating authority observes refresh, normal Close, a new
   conversation, and reuse of the replacement. The obsolete seed is never read.
2. Two separate controller processes cannot start credential writers together.
   Cover aliases, lock replacement, startup failures, controller death and
   forced termination. Verify lease lifetime and descriptor closure.
3. The real pinned runtime cannot read or write credentials from a model command
   through the direct path, symlinks, inherited descriptors or proc-root aliases.
   Recheck that no secret reaches provider history or diagnostics.
4. Cover partial auth writes, missing files, unsafe metadata, account switching,
   sync failures and shutdown without proven exit. Account tests include two
   users in one workspace and one user switching workspaces. No case authorizes
   deletion of persistent credentials or restoration of stale tokens.
5. Close removes temporary databases and transcripts. API-key source preservation,
   OpenCode behavior, frozen review and prompt preservation remain unchanged.
6. After synthetic acceptance, a separate opt-in test with a fresh dedicated
   login verifies actual refresh and subsequent access. Source inspection and
   successful auth-status RPC completion alone are insufficient evidence.

## Validation of this proposal

This task inspected the current callers, the pinned Codex source, official
authentication guidance and Bubblewrap source. It did not run the proposed
mount, lease or recovery behavior, read real credentials, or make live provider
requests. Product tests were not rerun for a documentation-only proposal.

A fresh independent builder review identified the missing definition of account
ownership. The proposal now specifies both user and workspace identity. The
follow-up review reported no remaining consequential planning questions. This
review did not validate the proposed runtime behavior.

The historical synthetic receipt assertions still pass up to the verifier's
final source-policy check. That old check expects SQLite journals to be refused
and now fails because PR #20 fixed that behavior. The historical artifacts were
left unchanged. They are not a passing audit of the proposed design.

[storage]: https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/login/src/auth/storage.rs#L214
[manager]: https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/login/src/auth/manager.rs#L2841
[persistence]: https://learn.chatgpt.com/docs/auth/ci-cd-auth
[external]: https://learn.chatgpt.com/docs/app-server#authentication-modes
[external-pinned]: https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/app-server/src/request_processors/account_processor.rs#L856
[owner]: https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/login/src/auth/change_state.rs#L14
[token-data]: https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/login/src/token_data.rs#L174
[bwrap-supervisor]: https://github.com/containers/bubblewrap/blob/v0.11.1/bubblewrap.c#L3551
[bwrap-old]: https://github.com/containers/bubblewrap/blob/v0.9.0/bubblewrap.c#L1528
