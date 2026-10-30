# Durable Codex credential validation

Date: 2026-10-29. Reviewed and tested implementation:
`cf97994f8feb1eace17f043f7af6442bf343b80e`, based on `e7131e4`.
The final documentation commit does not change runtime or test code.

Managed Codex now uses `chat.auth_store` for a fresh dedicated ChatGPT login.
It binds the verified auth file into each temporary conversation home and holds
an exclusive lease until the sandbox writer exits. Close retains that login.
`chat.auth_file` accepts copied API-key input only; saved ChatGPT input receives
migration guidance before worker launch. Setup is in the [usage guide](../usage.md#codex).

The provider-free command `python3 -I -B tests/run.py` passed **78/78 suites**
with zero failures (`run-zkwqgnol`). It retained 23 optional installed-provider
unittest skips and one optional installed-OpenCode artifact skip.
`stylua --check lua tests` and `git diff --check` passed.

The focused regressions first failed for missing ownership, configuration and
diagnostic behavior. Their completed runs cover these contracts:

- Private path, owner, mode, link, file-size and JSON bounds; stable settlement
  and both user/workspace identities. Refresh retains identity; switching either
  identity refuses before thread resume or prompt submission.
- Separate-process contention before credential reads. Bubblewrap retains the
  shared lock after local descriptor closure. Normal exit, TERM, KILL and
  controller death during startup and a held operation release it only after
  the detached writer's pidfd confirms death. The engine inherits neither descriptor.
- Busy first turns, continuation and review revision preserve the appropriate
  draft, thread and prior review. Retry is explicit. Changed retained state,
  forced exit and failed credential synchronization cannot authorize review.
- Passive UI/health, backend isolation, API-key source preservation, OpenCode
  compatibility, fixed diagnostics, migration refusal and complete conversation cleanup.

The explicit runtime command ran on a supported Ubuntu 26.04 VM:

```sh
python3 -I -B tests/run.py --codex /absolute/path/to/codex \
  nvim_ai_codex_runtime nvim_ai_codex_auth_runtime
```

Both suites passed: **8 existing tests and 4 credential tests, zero skips**
(`run-mihxvp4b`). The native CLI and companion came from the checksum-verified
Codex 0.163.0 package. The host used Bubblewrap 0.11.1, Python 3.14.4 and
Neovim 0.12.4. Hashes of 182 runtime, test and CI files matched the reviewed commit.

The loopback authority accepts only the current synthetic refresh token.
Close/new conversation and stopped-worker/same-thread resume each consumed
generations `[0, 1]`, with no stale-token rejection. Tests inspected replacement
tokens and timestamps only after writer exit. The temporary auth placeholder
remained empty, and Close removed the old conversation tree while retaining auth.

Real direct RPC and model-issued code-mode commands denied both read and
non-destructive write-open attempts through direct, symlink, proc-root and
available descriptor aliases, before and after refresh. An empty successful read
cannot pass. Commands returned the exact denial sentinel; provider history
contained no synthetic token. The engine had no credential-directory or lock
mount and no inherited credential descriptor. Real project bytes stayed unchanged.

The initial VM run identified one missing fixture route. The fixture now returns
404 only for the observed auxiliary settings request, as documented by the
[pinned backend client](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/backend-client/src/client.rs#L547).
Unexpected requests still fail. All endpoint overrides remain test-only.

The development host refused Codex's nested namespace before prompt submission.
The VM used a temporary named AppArmor profile for the test process tree, as in
prior runtime audits. The profile was removed after each run; the stock profile
checksum and both global namespace restrictions stayed unchanged. Both Draft
sandbox layers remained active throughout acceptance.
Final cleanup found no remaining test process or open handle and removed the
disposable checkout, binaries and synthetic state. Logs and policy receipts
were preserved outside the VM.

One independent whole-branch review checked `e7131e4..cf97994` and the connected
controller, review registry, worker and Lua callers. It found no Critical,
Important or Minor issues. It inspected the recorded evidence without rerunning
the suites. No implementation finding was deferred.

The checks above used synthetic credentials and providers. A dedicated login is required;
locking coordinates cooperating local Draft processes, not another CLI, IDE or
machine. Codex's upstream truncate/write refresh is not crash-atomic. Interrupted
refresh can require a fresh login; Draft preserves the latest file and never
restores an obsolete token seed.

## Live acceptance — 2026-10-29

A separately authorized trial passed on candidate
`df978e022d7e6dbcc52122b455b474e5bf10d402`, with the same pinned CLI, companion,
editor and Bubblewrap versions. The user completed a fresh device login on the
test VM. Existing CLI/IDE credentials were not imported. The operator was the
Codex agent, using a disposable project and `openai/gpt-6.1-sol`.

One explicit `getAuthStatus` request used `includeToken=false` and
`refreshToken=true` through the production Store, worker and sandbox.
After the writer exited, the trusted observer confirmed replacement access and
refresh tokens, a newer `last_refresh`, unchanged user/workspace identity and
stable auth/lock inodes. It recorded booleans only. The temporary auth placeholder
stayed empty. Closing that Store removed conversation state and retained the login.

The first editor Send requested one exact change to a disposable Lua file.
The frozen proposal was read-only and matched the requested bytes. Saved files
stayed unchanged until the actual `a` key approved it. Only the selected file
changed, and the accepted receipt sequence was 1.

Public Close followed by `:NvimAIChatNew` created a new conversation and thread.
A second minimal Send returned the requested reply using the retained login.
It changed no files. Both editor workers settled normally; the old conversation
store disappeared, and final Close retained a valid login. Exactly two Sends
and one explicit refresh occurred. The agent made no prompt retry.

Before live submission, the synthetic observer and passive editor preflight
passed. Two harness assumptions were corrected: New requires `NvimAIChatNew`,
and Close may start the cleanup controller without starting a provider worker.
Product code was unchanged. The first unauthenticated device-login process timed
out; the replacement login succeeded before the live trial.

The live wrapper exited 0 and removed its temporary AppArmor profile. A root
observer found no test process, open handle or inspection error. Both Codex
conversation stores were absent, and stock/global security policy was unchanged.
After the user approved cleanup on 2026-10-30, the dedicated login was logged
out under its exclusive lease. The auth file, retained review directory,
disposable project, test checkout and tools were removed. A final root observer
confirmed no matching process, open handle or inspection error and unchanged
host policy. The operator preserved 24 allowlisted evidence files locally,
including exact proposal/published bytes and three terminal captures. The
archive checksum and all live-result assertions passed. No credentials or
private conversation stores were exported. Cleanup made no additional model
request. No release or merge was performed.

This proves one fresh-login, refresh, review and Close/New path on the recorded
host. It does not establish other accounts or workspaces, cross-client locking,
crash-atomic refresh, internal HTTP request counts, billing or long-term use.
