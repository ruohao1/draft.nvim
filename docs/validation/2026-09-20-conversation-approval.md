# Conversational approval validation — 2026-09-20

Scope: [ISQ-235](https://linear.app/isqrd/issue/ISQ-235), within **Usable
conversational editing**. Chat now connects to the existing frozen review and
guarded publisher for explicit per-file decisions, confirmed batches and pending
proposal follow-ups. Model selection (ISQ-236) and broader/live-account acceptance
(ISQ-237) remain separate.

## Observed boundaries

| Boundary | Evidence |
| --- | --- |
| Explicit publication | `ai_chat_approval`: unchanged disk after generation; approval from chat refuses; actual visible-file approval writes only that file and advances after its receipt; rejection stays on the displayed file |
| Batch authority | `ai_conversation_review`, `nvim_ai_conversation_protocol`, `nvim_ai_conversation_review`: literal `remaining=true` is exclusive with `path`; targets derive from pending files; real journal matching, prior decisions, partial/lost receipts and uncertain writes are verified |
| Confirmation and navigation | `ai_staged_shared`, `ai_chat`, `ai_chat_approval`: actual visits, draft changes, newer dialogs, source/alias/panel metadata, file navigation, leaving/returning to tabs and repurposing/restoring windows invalidate old confirmations |
| Follow-up and context | `ai_chat_approval`: accept first/reject second/revise third; fresh token and visits; old mapping inert; discussion retains validated proposal; revision and subsequent independent turn receive exact confirmed decisions |
| Focus and ownership | `ai_conversation_controller`, `ai_chat_approval`: a background receipt does not pull focus; a repurposed old tab survives replacement; hidden chat and a closed original tab retain the draft without taking over frozen windows |
| Cleanup and failure | Public cancel/close preserve accepted bytes, discard pending authority and retain unsent drafts; native/standalone staging remain excluded while hidden; source, hidden alias and frozen-panel drift refuse publication and preserve user edits |
| Rendering and installation | `ai_chat_view`: receipt-derived states render once at the corresponding proposal turn, independently of assistant text, retaining display and undo bounds; `nvim_ai_install` repeats production approval from a plugin path with spaces and unrelated cwd |

The existing controller suites continue to cover interrupted replacement handoffs,
uncertain stop/cleanup, source refresh failure and transport loss. No new writer,
native-write fallback, provider request or runtime dependency was added.

## Real keyboard and visual evidence

`nvim_ai_chat_ui` exercises actual `a/r/A/R/f/q`, `]f/[f`, Ctrl-S and dialog keys
in a private tmux server and Neovim TUI. The approval case uses the production
controller, a confined scripted ACP peer and the real guarded publisher. It also
acknowledges Neovim's ordinary hit-enter prompt after synchronous batch output.

Both captures below are actual 140×42 terminal grids, converted to PNG with the
optional renderer and visually inspected. Review help uses compact labels so
accept/reject remain visible in each split; a real-screen regression checks this.

![Frozen proposal and review controls](../images/conversation-review.png)

![Receipt-derived partial outcomes](../images/conversation-decisions.png)

Reproduction commands are in [tests/README.md](../../tests/README.md).

## Verification boundaries

The final complete default run passed **57/57** suites, including all **29**
controller tests, with the expected installed-provider opt-in skips.
`stylua --check lua tests` and `git diff --check` passed.

The focused final integration gate passed **5/5** suites, including the two real
keyboard/layout tests. A separate relocated-install run passed its two tests,
including the complete public approval flow. Formatting and whitespace checks
passed. Navigation-history and clipped-help regressions were observed failing
before their fixes and passing afterward.

All fixtures use disposable files, private HOME/XDG directories, loopback audit
endpoints and isolated editors. No paid request, real credentials, live editor,
user tmux server or personal configuration was used. Earlier pinned OpenCode
evidence remains in the [controller record](2026-09-19-conversation-controller.md).
Independent review, exact-head CI and post-merge CI are delivery gates recorded
in the issue and its linked pull request.
