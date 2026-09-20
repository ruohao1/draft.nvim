# Conversational model selection validation — 2026-09-20

Scope: [ISQ-236](https://linear.app/isqrd/issue/ISQ-236), within **Usable
conversational editing**. `:NvimAIChatModel`, `gm` and the idle action menu select
an advertised model for the next eligible turn. Broader/live-account acceptance
remains ISQ-237.

## Observed boundaries

| Boundary | Evidence |
| --- | --- |
| Passive choices | `ai_chat_model` and `ai_chat_controller`: no worker before negotiation; selection/cancellation preserve composer and history without a controller command; only an explicit later Send starts the next turn |
| Lifecycle and stale dialogs | Real owners refuse before discovery, starting, generation, stopping, review, publication, failure and close; changed drafts, newer dialogs, hide/reopen, tab departure/return, later turns and replacement owners invalidate old choices |
| Visible refusals | Hidden or off-tab chat reports refusal through a notification without reopening, taking focus or submitting; stale callbacks after hiding also report their expiry |
| Catalog and labels | A newly negotiated catalog replaces prior options; forged/removed models refuse; earlier turn labels stay fixed and the next turn requests the selected model |
| Preference boundaries | Hide/reopen retains the local selection; New reads the original unchanged default; no settings/account mutation or provider discovery occurs in the picker |
| Same-session switch | Public commands and the production controller confirm `fixture/model` then `fixture/second-model`, with one `session/new`, one `session/resume`, two explicit prompts and fresh confined workers |
| Failed switch | Resumed options removing the selected model and incorrect model confirmation both settle failed/not-submitted, with no second prompt, fallback choice or replacement session |
| Missing auth | Removing a synthetic auth file after a completed turn refuses the next selected model before launching another worker; source bytes remain unchanged |
| Proposal identity | Pending/publishing review refuses selection; choosing after rejection preserves the original round/model and cannot revive its retired decision authority |

The Lua owner, controller protocol, saved-settings implementation, publisher and
confinement did not need production changes. Existing review and follow-up
suites continue to enforce generation identity and stop/cleanup proof.

## Real keyboard and visual evidence

The disposable tmux/Neovim test uses real `gm`, cancellation, choice, `q`,
reopen and Ctrl-S. It proves that selecting a model leaves the next question
unsent and that replies retain distinct model labels after the second Send.
The captured 140×42 terminal grid was rendered and visually inspected, as was
the picker with its selected-item marker. The short help line keeps `gm` visible.

![Selected next model, earlier reply and unsent draft](../images/conversation-model.png)

Reproduction instructions are in [tests/README.md](../../tests/README.md).

## Verification boundaries

The focused integration run passed **8/8** suites, including all **31** production
controller tests. The two input/model terminal cases passed. The new public
interface tests were observed failing for the missing method/command before
implementation, then passing. Controller switch-failure cases characterize the
existing guarded negotiation; no protocol fix was needed.

The complete default run passed **58/58** suites, including all three terminal
UI cases and the relocated-install flow, with expected installed-provider opt-in
skips. `stylua --check lua tests` and `git diff --check` passed.

Independent review found one visibility gap: a refusal routed only to a hidden
transcript. A failing headless regression reproduced it; current-tab notice
availability now controls notification fallback. Hidden/off-tab refusal and a
stale callback after hiding are covered without changing model or worker state.

A post-fix full run exposed an existing intermittent assertion in
`test_multi_unchanged_context_is_not_written_but_is_revalidated`: complete stat
equality treated a revalidation read's access-time update as a write. Delaying
the real decision across a second boundary reproduced the same failure, with
only `st_atime_ns` changing. The corrected test retains content, identity,
permissions, ownership, size and nanosecond modification/change checks. The
delayed reproduction and all ten multi-file cases passed; publisher code is
unchanged.

The final complete run after both corrections passed **58/58**, including the
formerly intermittent staging assertion. Formatting and whitespace remained clean.

Initial PR CI then exposed two timing assumptions (push CI passed on that same
commit). The relocated chat test could accept the previous turn's idle frame;
an 800 ms render delay in a disposable copy reproduced the failure. It now waits
for the second turn to render as generating before releasing the provider gate.
The cache concurrency test now exercises four completed atomic helper writes
directly, then verifies a fresh editor reuses the receipt. Individual editor
integration and the bounded-cache-timeout test remain in place.

Known follow-up: a cache helper hard-killed during a write can retain a private
`.receipt-*` temporary file. A delayed write reproduced this. Readers only
consider the complete `compatibility.json` receipt, so the residue grants no
compatibility or writer authority; interrupted-cache cleanup remains to address
in broader acceptance. This model-selection change does not alter cache code.

All fixtures use synthetic credentials, disposable HOME/XDG directories,
loopback audit endpoints and isolated editors. No paid provider request, real
credentials, live editor, user tmux server or personal configuration was used.
Pinned real-OpenCode evidence remains separately documented in the earlier
[controller record](2026-09-19-conversation-controller.md). Fresh review,
exact-head CI and post-merge CI are recorded in the issue and linked pull request.
