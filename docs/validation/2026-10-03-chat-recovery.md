# OpenCode cancellation and recovery — 2026-10-03

Scope: ISQ-351, the Linux/OpenCode lifecycle work following startup diagnostics
at `251eef6`. Automatic crash recovery, transcript restoration, retention-policy
redesign and publication changes remain outside this package.

## Safe Retry defect

The semantic owner correctly marked an initial missing-credentials failure safe
to retry after proving no prompt submission, worker shutdown, valid retained
storage and token retirement. The production Lua controller then fenced every
failed owner. Public Retry returned `Conversation guards failed; close before
further work`, contradicting the displayed recovery state.

`ai_chat_recovery` reproduced that exact refusal through the real runtime,
controller and confined fake ACP peer. The controller now leaves positively
proven safe failures eligible for explicit Retry. Existing guard failures remain
fenced; no existing fence is cleared, no failed publication is retried, and all
source, identity, action-revision and lifecycle checks remain authoritative.

Retry retains its existing input contract: a nonempty composer supplies the new
instruction; an empty composer uses the failed prompt. It creates one explicit
turn and never runs automatically. A refused action preserves the draft. Text
typed after a successful Retry remains the next draft.

## Lifecycle evidence

| Scenario | Evidence and result |
| --- | --- |
| Initial and later missing credentials | Public Retry after restoring the synthetic file submits once; a later retry resumes the existing session without creating a replacement. |
| Stale actions, dirty selected buffers and overlapping retries | Refused before another turn or worker; dirty source and composer contents remain intact. |
| Unsafe failure | Wrong-version startup stays recovery-required and refuses Retry. Close followed by New has no old turn, review or automatic submission. |
| Startup and blocked-input cancellation | Existing controller cases require recovery rather than inventing cancellation confirmation; observed within the existing 4.2-second test bound. |
| Normal and flooded generation cancellation | Matching confirmation, stopped worker, valid store and retired authority are required; existing tests enforce a two-second bound. |
| Partial approval followed by Cancel/Close | Accepted disk contents, later unsaved source edits and composer text survive; remaining proposals are retired. |
| Guard, blocked-writer or uncertain publication failure | Existing public/controller tests retain accepted/blocked/uncertain outcomes and recovery evidence through Close. |
| Normal editor exit | Production controller EOF supervision stops workers and removes owned store and launch configuration. |
| Editor SIGKILL and restart | Process handles prove the controller and worker stop. A fresh Neovim using the same isolated configuration has no old transcript, approval authority, child process or replayed prompt. The old private launch artifact remains unchanged. |
| Controller death | Existing process-lifetime tests prove worker/listener shutdown and prevent a new owner from adopting interrupted storage. |

The driver also tests silent controllers, broken pipes, forced exits and missing
cleanup evidence. A timeout or killed process alone never becomes proof of safe
Retry or confirmed Close. Production limits remain unchanged: startup RPCs have
a 15-second limit within a 60-second startup budget; prompt cancellation has a
five-second response deadline, followed by worker EOF/TERM/KILL stages bounded
at three seconds each. These are protocol/shutdown bounds, not guaranteed UI
latencies under every operating-system failure.

The disconnect audit found a misleading recovery action: the message requested
Close, although the dead driver cannot confirm Close. A failing process-death
regression now requires restart guidance both immediately and after a refused
Close. The shared message directs users to preserve unsaved source edits and the
composer draft, inspect uncertain writes and restart Neovim. No lost owner is
silently reopened, and cleanup is still reported as unconfirmed.

The real-key TUI case restores synthetic credentials, presses `gr`, observes one
new startup attempt, cancels with `gc`, and explicitly closes. Tests operate only
on disposable projects and test-owned processes.

## Installed OpenCode 1.18.34

All four existing production-controller interoperability cases passed with the
installed binary and a loopback scripted provider: context without replay,
cooperative cancellation followed by explicit resume, failed restoration without
a replacement session, and context overflow without compaction/replay. The
installed owner-death case also passed: worker/listeners stop, source stays
unchanged and a fresh owner does not adopt retained storage.

These five cases used synthetic credentials and private HOME/XDG directories.
No real account, paid prompt or user's editor was involved. The production
Bubblewrap boundary remained enabled. Environment: Linux x86_64, Neovim 0.12.4,
Python 3.14.4, Bubblewrap 0.11.1 and OpenCode 1.18.34 at
`/home/ubuntu/.opencode/bin/opencode`.

The allowlisted-environment invocation in `tests/README.md` was used for
`tests/nvim_ai_conversation_interop.py -v` and for
`tests/nvim_ai_conversation_lifetime.py
LifetimeTest.test_real_opencode_owner_death_stops_active_listener_without_resuming -v`.
Both used `NVIM_AI_ACP_REAL_OPENCODE` pointing to the canonical installed binary.

## Recovery and retained artifacts

- Cancel/Close do not undo accepted writes or discard unsaved source buffers.
  A pending review requires confirmation before retirement.
- Startup cancellation can require Close even when no prompt was submitted;
  pre-submission status alone does not establish a reusable session.
- If safe Retry is offered, restore credentials at the same configured path,
  resolve dirty selected buffers, then explicitly retry. Configuration/model
  changes require Close and setup for a new conversation.
- After an uncertain publication, inspect actual files and receipt evidence.
  Close releases the backend after proof; it does not clear uncertainty, roll
  back changes or retry approval tokens.
- When the controller disconnects, Close cannot prove cleanup. Preserve unsaved
  source edits and the composer draft, inspect uncertain writes, then restart
  Neovim. Same-editor New cannot replace that permanently lost owner.
- A new editor or explicit New has fresh conversation context. Neither restores
  a transcript, replays a prompt, adopts an old store or revives approval authority.
- Abrupt editor death can leave `/tmp/draft-conversation-config-*`: a private
  `0700` directory with `0600` `launch.json`, containing provider configuration and
  an auth-file path. Controller death can also leave private backend/proposal
  evidence. Identify an exact artifact and establish that its owned processes
  have stopped before inspecting or removing it. Never sweep directory families.
- Aggregate orphan retention and automatic recovery remain unimplemented.
  Unsaved editor memory cannot be promised to survive SIGKILL.

## Verification

```sh
python3 -I -B tests/run.py ai_chat_recovery ai_chat_approval
python3 -I -B tests/run.py nvim_ai_chat_ui nvim_ai_conversation_controller
python3 -I -B tests/run.py
stylua --check lua tests
git diff --check
```

Final verification completed on 2026-10-04 (Europe/Paris):

- The unchanged-checkout default run passed **63/63 suites**, including all nine
  TUI cases, all 35 controller cases and both relocated-install cases.
- The separate installed-OpenCode runs passed **5/5 cases**. These opt-in cases
  remain skipped by the default runner; their result is not inferred from it.
- `stylua --check lua tests` and `git diff --check` passed.
- Independent review found no correctness or safety issues. It checked the
  sticky fences, positive Retry proofs, preserved buffers, restart boundaries,
  disconnect guidance and installed-runtime evidence.

Evidence is retained locally under `.test-results/chat-recovery-2026-10-03/`:
`runs/run-b4v73dn3/` contains the final full run, `recovery-installed/` contains
the two installed-runtime logs, and the other `runs/` directories preserve the
focused checks and red regressions. An earlier full run (`run-kxvisfsg`) passed
62/63 suites: its relocated copy hit the new disconnect-message regression while
the test and production fix were being edited. The final run used unchanged
source files and passed that same relocated-install check.
