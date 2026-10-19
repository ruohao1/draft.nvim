# Claude CLI review validation

Recorded 2026-10-19 for [ISQ-463](https://linear.app/isqrd/issue/ISQ-463).
The offline observer controls pass. **No real Claude CLI trial has run.**
Explicit provider prompts: **0 of the authorized maximum 10**.

## Environment and provenance

| Component | Observed value |
| --- | --- |
| Draft base | `bba5c4bfda8f1f779348bd5b776235924a07c90d` |
| claudecode.nvim | Clean checkout, `2390c6e45c4789072c293ac69de051d169668b29` |
| Neovim | 0.12.4 |
| Python | 3.14.4 |
| strace | 6.19 |
| tmux | 3.7c available; these headless controls do not use it |
| Editor configuration | Vertical split, selection tracking and automatic startup off, no terminal provider |
| Claude CLI, model, permissions, IDE Diff tool | Not established; no installed CLI or authentication found during preflight |

Every control is synthetic. The editor controls use the pinned RPC dispatcher,
coroutine tool handler, deferred response sender, WebSocket encoder, diff buffers
and `close_tab` handler. Only the client transport handle is synthetic: it captures
and decodes the emitted WebSocket frame. This proves local handler behavior,
not a socket handshake, delivery to Claude, CLI tool routing or a provider turn.
The two writer controls use a separate Python child, never a substitute Claude.

The [primary-source memo](../research/2026-10-18-claude-cli-validation-prerequisites.md)
records documented installation, authentication, permissions and IDE setup.
Those documents do not establish this reverse-engineered Neovim protocol's
compatibility with an untested CLI release.

## Checked controls

Run from the research checkout:

```sh
python3 -I -B tests/manual/claude_ide_review.py \
  --self-test --plugin /tmp/draft-isq463-claudecode
stylua --check tests/manual/claude_ide_observer.lua
git diff --check
```

| Control | Observed result |
| --- | --- |
| Accept | One correlated `openDiff` response, `FILE_SAVED`, exact 25-byte proposal returned; source bytes and inode unchanged at every checkpoint. |
| Reject | One correlated `DIFF_REJECTED` response; source bytes and inode unchanged at every checkpoint. |
| Edit proposal | Human revision plus a trailing blank line returned exactly, 26 bytes; source unchanged at the response boundary. |
| In-place writer | Child trace includes target open/truncate and undecoded write; target identity preserved. |
| Rename writer | Child trace includes temporary-file write and successful rename onto target; target identity changed. |

In each editor control the event sequence is:

`openDiff request → pending → decision → response attempt → response return → close_tab request → response attempt → response return → finalization → teardown`.

Request and response records match by client and request ID. Each Neovim event
contains an origin, sequence number, monotonic timestamp, source existence,
relative path, device/inode, byte count, SHA-256 and private byte snapshot.
Proposal and accepted payload snapshots are separate. A `response_return` with
`delegated_return=true` records the upstream sender's return value; it is not a
client receipt or filesystem acknowledgement.

The finalizer is invoked as an actual `tools/call` with the synthetic title
`✻ [Claude Code] sample.lua (synthetic) ⧉`. All three controls receive `TAB_CLOSED`
and lose their active diff state, while source bytes remain unchanged. This
establishes the pinned title-dispatch convention and demonstrates that finalizing
an accepted diff does not verify publication. **It does not establish the title
or ordering a real Claude CLI uses.** The test deliberately supplies no writer
between acceptance and finalization.

The relevant source boundaries are the pinned
[deferred response sender](https://github.com/coder/claudecode.nvim/blob/2390c6e45c4789072c293ac69de051d169668b29/lua/claudecode/server/init.lua#L228-L260),
[transport delegation](https://github.com/coder/claudecode.nvim/blob/2390c6e45c4789072c293ac69de051d169668b29/lua/claudecode/server/init.lua#L372-L396),
[title dispatch](https://github.com/coder/claudecode.nvim/blob/2390c6e45c4789072c293ac69de051d169668b29/lua/claudecode/tools/close_tab.lua)
and [saved-diff cleanup](https://github.com/coder/claudecode.nvim/blob/2390c6e45c4789072c293ac69de051d169668b29/lua/claudecode/diff.lua#L1685-L1719).

## Evidence and limits

Private runs are under `.test-results/claude-cli-review/` in the research checkout:

- `20261019T195529-j6kn4i36`: initial control setup failure, retained. The fixture
  initialized `claudecode.tools` while the server loads `claudecode.tools.init`;
  these are distinct Lua module-cache entries. Corrected to the server's module.
- `20261019T195544-z1qk9vv9`: all three observer assertions fail with the no-op
  observer, after real handler behavior succeeds.
- `20261019T195621-yemuibfa`: all three observer controls pass.
- `20261019T195713-tr67pqnr`: both trace assertions fail before tracing exists.
- `20261019T195728-27e36m4j`: all five controls pass; temporary fixtures removed.

The wrapper delegates ordinary requests/responses unchanged and records observer
I/O errors without suppressing the original RPC. Controls fail if such errors
are reported. Evidence directories use private permissions and child environments
contain only allowlisted variables and disposable HOME/XDG/Claude directories.

Snapshots establish values at sampled boundaries. They are not atomic snapshots
of a concurrent writer and cannot exclude intervening writes. The syscall
controls trace only their own child and two known synthetic paths, exclude write
payload decoding and retain PID-specific Unix-timestamped traces. Cross-clock
ordering against Neovim's monotonic events, arbitrary CLI temporary filenames,
CLI process-tree cleanup and live lockfile cleanup remain unvalidated. No
combined event order or live writer attribution is claimed.

The default Draft suite was not rerun: runtime modules, shared fixtures and
default test discovery are unchanged. The new opt-in utility has its own five
controls. Formatting and whitespace checks accompany the recorded self-test.

## Live matrix and recommendation

| Planned live case | Status |
| --- | --- |
| 1. Baseline IDE edit | Not run: CLI/account/model prerequisite unavailable |
| 2. Reject | Not run: requires baseline |
| 3. Edited split proposal | Not run: requires baseline; synthetic result above is separate |
| 4. Source content conflict | Not run: requires baseline |
| 5. Source identity conflict | Not run: requires baseline |
| 6. New file | Not run: requires baseline |
| 7. Pending disconnect | Not run: requires baseline |
| 8. Disconnect after local response attempt | Not run: requires baseline |
| 9. Write failure | Not run: requires baseline |
| 10. Terminal diff control | Not run: requires baseline |

**Defer Claude protocol integration.** The evidence supports separating proposal
editing, user decision, client transmission, project publication and cleanup.
Draft should retain its existing publication checks and recovery receipts; neither
`FILE_SAVED` nor `TAB_CLOSED` can replace them. Editable review remains a useful
interaction lesson, already addressed separately by Draft's manual-correction
work. No new adapter or roadmap change follows from these controls.

Resume after the account route is established: install and pin a CLI release,
verify authentication without recording account details, complete the isolated
live runner/trace correlation, then establish one real IDE baseline under explicit
`--permission-mode default` and Diff tool `auto`. Stop if routing or observations
are unusable. The remaining matrix keeps the [approved plan's](../superpowers/plans/2026-10-18-claude-cli-review-validation.md)
one-prompt-per-case budget, deadlines and no-retry rule. ISQ-463's live acceptance
items remain open; ISQ-461's everyday-use feedback item is unaffected.
