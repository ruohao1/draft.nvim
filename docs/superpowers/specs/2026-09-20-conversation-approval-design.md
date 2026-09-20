# Conversational approval and revision

Date: 2026-09-20. Implements [ISQ-235](https://linear.app/isqrd/issue/ISQ-235)
within **Usable conversational editing**. The user instructed continuation after
this issue was identified as the next deliverable. This document records the
working design; it is not a claim of separate written-artifact approval.

## Outcome

Connect the existing chat surface to frozen per-file review and the trusted
publisher. A user can inspect a proposal, accept the visible file and advance,
reject that file, explicitly confirm a batch, or send a follow-up about the
pending proposal. Confirmed decisions appear in chat and reach subsequent model
context. Nothing writes the project until an explicit approval passes the
existing editor, source, proposal and journal checks.

Model selection remains ISQ-236 and broader live-account acceptance ISQ-237.
This change uses synthetic providers and disposable editors. It does not modify
the user's live editor, tmux, credentials or configuration.

## Approach

| Approach | Consequence |
| --- | --- |
| Carry a bounded batch intent through the existing owner and publisher | One user decision, one synchronous guarded publisher operation, one authoritative journal receipt; chosen |
| Sequence individual approvals from the chat UI | Requires a second asynchronous transaction/lifecycle mechanism across receipts and user navigation |
| Dispatch standalone staged commands from chat | Their independent ownership cannot represent the conversation's review identities and outcomes |

The existing publisher already implements `--remaining`. Extend the conversation
intent and receipt boundary to describe that operation; do not add another writer
or reinterpret provider text as authorization. Keep UI eligibility and navigation
inside the shared frozen-review handle, and conversation identity/state inside
the semantic owner and trusted adapter.

## User interaction

- Continue to open diffs explicitly with `:NvimAIChatReview` or `gd`. Generation
  never creates a review tab or steals focus.
- In a conversation diff, `a` accepts only the displayed pending file and advances
  to the next pending file after its receipt. `r` rejects the displayed file and
  stays on it while other files remain pending. `]f` and `[f` navigate files.
- `A` / `R` confirm accepting/rejecting all remaining pending files. Approval
  requires a genuine visit to every pending diff in this proposal revision.
  Neither opening the dialog nor confirming it creates synthetic visits.
- Add `NvimAIChatApprove`, `NvimAIChatReject`, `NvimAIChatApproveAll` and
  `NvimAIChatRejectAll`, bringing the chat command count to twelve. Commands
  require the actual frozen review to be visible; invoking one from chat does
  not open a diff and approve it in one step.
- `f` returns to the composer for a follow-up; `q` uses the existing confirmed
  cancel/discard flow. Return to chat preserves the draft and review tab even
  when chat was hidden. A closed original tab cannot cause chat to take over
  frozen diff windows.
- Explicit Send while a review is pending dispatches `revise` bound to its round,
  revision and token. It can discuss or request changes; it never approves. Enter
  still inserts a newline. Drafts clear only after admitted submission.
- A discussion-only answer can preserve the validated proposal. A replacement
  retires prior writer authority, has a new token, and starts with unvisited
  diffs. Previous accepted/rejected files remain immutable context.
- Chat displays receipt-derived file states and review status, including
  accepted, rejected, pending, cancelled, blocked and uncertain. Agent text is
  not treated as a publication report. Revision history is not copied into itself.

## Interfaces and authority

`decide` accepts exactly one target form: `path = selected_path` or
`remaining = true`, alongside existing choice and review identities. A path plus
remaining, false/nonboolean remaining, missing target, extra fields, stale
identity or empty pending set refuses. Batch targets are the ordered pending
files of the bound review, never arbitrary caller-supplied paths.

The Lua owner records the complete batch intent before publication. Receipt
validation requires the exact selected outcomes and preserves prior confirmed
files. A lost receipt after batch approval marks every targeted pending file
uncertain; it cannot claim that unobserved writes did not occur. Partial writer
results retain confirmed successes and fence further publication.

Python protocol validation mirrors the exclusive target forms. ReviewRegistry
derives the expected batch paths from its current entry and compares them with
the actual writer journal. Revisions and later independent messages reuse the
existing confirmed-decision context; no fabricated receipt enters that path.

The shared frozen handle provides `current()`, `move(delta)`, and
`prepare(choice, remaining) -> intent|nil, reason`. An intent contains its
path/remaining target, pending count and `valid()` callback. Validity covers the
same handle, phase, navigation revision, current tab/windows, source/alias buffer
metadata and frozen-panel metadata. The legacy staged confirmation snapshot is
shared rather than copied. Approval still rechecks source and frozen bytes
immediately before the synchronous writer. Rejection preserves the existing
ability to discard an unusable proposal without publishing it.

`handle:decide(choice, path, remaining)` retains the publisher and normal source
refresh, returning the verdict, recovery reason and a presentation guard. The
adapter advances only after an authoritative receipt and while that guard proves
the user has not left or navigated the review. A background receipt updates
outcomes without pulling focus back.

The trusted factory adds optional `on_review_action(name, argument)`. Per-handle
key callbacks are fenced to that handle and proposal identity. The `on_review`
facade exposes presentation/eligibility methods only; it does not expose the
publisher. Chat obtains an intent, confirms batches with its owner/view/draft
fence plus the handle guard, and dispatches through `owner:dispatch`.
Opening a newer dialog invalidates older pending dialog callbacks.

## Constraints and failure behavior

- Linux, Neovim 0.12+ / LuaJIT, Python standard library, existing Bubblewrap and
  pinned ACP/controller behavior. No new runtime dependency or provider request.
- One conversation/runtime lease; 1–16 saved selected files, 1 MiB aggregate
  selected/proposed bytes; scope stays fixed. Native and standalone staged writes
  remain excluded even when chat is hidden or reviewing.
- Preserve the five-second synchronous publisher bound. Keep current process,
  store, identity, link/mode/ACL, immutable-panel and source-alias checks.
- Keep 64 turns / 32 MiB owner history, 2 MiB / 20,000 rendered lines and 32 KiB
  composer limit. No transcript undo history; normal composer undo remains.
- A stale menu, confirmation, old diff mapping or replaced proposal performs no
  action. Source drift or uncertain publication never grants a fresh approval.
- Cancel/close discard pending authority only and preserve accepted project
  bytes. Dirty or repurposed user buffers/windows are never overwritten to
  recover the review. Report actionable close/restart guidance after guard failure.
- Preserve root untracked AGENTS.md and unrelated worktrees.

## Acceptance evidence

Use real owner transitions for valid/invalid batch intents and partial/lost
receipts; real writer journals for registry matching; real Neovim panels and
sources for eligibility, visits, confirmations and callback fences; public
commands through the production controller and confined fake ACP worker for
partial acceptance, revision, discussion, context and close/cancel preservation.
Add actual keyboard coverage and captures for the changed review UI. Run all
default suites, one fresh whole-branch review, exact-head CI and post-merge main
CI before completing delivery and updating Linear.
