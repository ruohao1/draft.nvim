# Codex cancellation event validation

## Problem and change

A streaming Codex turn could confirm its interrupt and stop normally while the
editor still entered recovery-required state. The adapter emitted `stopping`
before `cancelled`, but the owner had already entered `cancelling` and rejected
that event. The adapter now emits `stopping` only for normal completion.

The matching terminal, worker exit, retained-store validation, and workspace
retirement checks remain required before confirmed cancellation. A new Send is
still explicit. Startup cancellation and completion-winning races retain their
existing fail-closed behavior.

## Regression

The existing `ai_chat_codex` suite now uses the production chat UI, owner, driver,
controller, adapter, sandbox and store with the scripted Codex peer. It waits for
rendered streamed text before invoking the actual `gc` mapping callback. It then
requires idle/cancelled state without recovery, unchanged source bytes and no
review proposal. A second explicit Send must complete on the same thread with
a new worker generation and the same controller. Close must succeed.

The scripted peer emits partial text for the existing cancellation cases. After
the first worker stops, the test changes only that peer's response scenario to
answer the next request. It does not replace production events or the editor owner.

## Checks

- Clean baseline: `ai_chat_codex` and `nvim_ai_codex_turn` passed (2/2 suites).
- Before the fix, the new editor regression failed with
  `Conversation outcome is unproven; explicit recovery required` after partial
  text and Cancel. Evidence: `run-yfreyteu/ai_chat_codex.log`.
- After the fix, `ai_chat_codex`, `nvim_ai_codex_turn`, `ai_conversation` and
  `ai_conversation_driver` passed (4/4 suites, including all 16 adapter tests).
  Evidence: `run-0wwnmnio`.
- `stylua --check lua tests` and `git diff --check` passed.
- Independent read-only review found no issues. It inspected the connected UI,
  owner, driver, controller, adapter, store and worker paths. It checked the saved
  failing/passing test evidence and independently passed `git diff --check`.

- Full default command: `python3 -I -B tests/run.py` passed **76/76 suites**,
  zero failures. Evidence: `run-do7uajtn`. The configured optional checks retained
  20 unittest skips and one installed-OpenCode Lua audit skip.

All named logs are under the feature worktree's `.test-results/` directory.

## Limits

This fix uses synthetic credentials and peers. The earlier live failure supplied
the symptom; no live account, credential transfer or paid prompt was used for
this implementation. A fresh bounded live Cancel → resume trial remains after
review and integration. Actual token refresh remains unverified.
