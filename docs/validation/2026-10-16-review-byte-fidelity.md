# Managed review byte fidelity — 2026-10-16

[ISQ-460](https://linear.app/isqrd/issue/ISQ-460) compares Draft's existing
contracts with the three newline/empty-file differences observed in the
[claudecode.nvim study](https://linear.app/isqrd/document/claudecodenvim-study-architecture-diff-review-and-lessons-for-draft-7658617adef7).
No corresponding Draft production defect was found. This branch adds only
regression coverage and this record; it does not change the publisher or UI.

Tested production revision: `5b447c0aa553e86e103492ecea899d494e407cae`, with the
tests on `test/isq-460-review-byte-fidelity`. This audit is independent of the
selection-context feature branch.

## Existing coverage checked first

| Boundary | Existing evidence |
| --- | --- |
| Proposed workspace → frozen material | [`nvim_ai_staged.py`](../../tests/nvim_ai_staged.py) checks freezing separately from agent execution, unchanged project bytes before approval, exact before/after text, and unsupported changes. |
| Frozen material → displayed review | [`ai_staged_shared.lua`](../../tests/ai_staged_shared.lua) checks frozen panel tampering/deletion, saved/alias guards and deferred reopen; [`ai_staged.lua`](../../tests/ai_staged.lua) checks the public two-panel review and refusal after scratch-buffer edits. |
| Approval → actual publication | [`nvim_ai_staged_publish.py`](../../tests/nvim_ai_staged_publish.py) checks exact prepared bytes/modes, frozen tampering, consumed authority, unchanged context, source identity/drift and preparation failures. |
| Publication → receipt | The same publisher suite injects failures at the attempt receipt, rename, parent fsync, applied receipt and final receipt. Earlier confirmed writes remain accepted; possible unconfirmed writes become uncertain. |
| Receipt → editor outcome | [`ai_conversation_review.lua`](../../tests/ai_conversation_review.lua) keeps files pending during publication, requires matching complete evidence, and rejects stale/contradictory replies. [`ai_staged_multi.lua`](../../tests/ai_staged_multi.lua) checks missing/malformed/throwing writer replies after a confirmed acceptance. |
| Close/reopen and interruption | Shared review tests invalidate old confirmations after navigation or retirement. The [approval record](2026-09-20-conversation-approval.md) and [ISQ-351 recovery record](2026-10-03-chat-recovery.md) cover accepted files, dirty buffers, stale actions, cancellation, owner death and fresh-editor authority. |

The missing explicit coverage was the exact empty/newline/trailing-blank byte
matrix across display and publication. Existing broad source-drift, late-callback
and interruption tests were reused rather than duplicated.

## Cases and observed behavior

Managed staging and conversation review share the native side-by-side frozen
panels in [`staged_review.lua`](../../lua/ai/staged_review.lua). There is no managed
unified-view option. Native after-write review has a separate contract and is
not evidence for managed proposal acceptance.

| Original bytes | Proposed bytes | Displayed proposal lines | Result |
| --- | --- | --- | --- |
| `original text\n` | empty, zero bytes | one empty editor line | Published zero bytes. |
| empty, zero bytes | `\n`, one byte | one empty editor line | Published exactly one newline. |
| `original text\n\n` | `approved edit\n\n\n` | text plus two empty lines | All trailing blank lines survived. |
| nonempty without final newline | — | no managed review | Source capture/controller refused; original bytes unchanged. |
| valid saved source | nonempty without final newline | no managed review | Staging refused the proposal; project bytes unchanged. |

Empty content and a single newline both occupy one empty Neovim line. The display
is a projection, not the publication payload: frozen byte files and fingerprints
retain that distinction. The supported text contract explicitly requires a final
newline for nonempty text. This audit does not add missing-final-newline support.

The added public-command cases run the real Python controller, Bubblewrap, fake
ACP peer, frozen review and single-file publisher. They compare frozen before/
after files and final disk bytes exactly; resizing, diff refresh and wrapping do
not change them. The shared deferred-review cases close and reopen the same
panels, preserve byte projections, invalidate the old confirmation and require a
fresh one. The multi-file publisher case publishes all three forms and compares
the durable receipt, including proposal ID, with the returned outcome.

## Approval, publication and outcomes

No uncovered interval was found among the tested failure boundaries. Before
rename, refusal is blocked/conflicted without an accepted write. After a possible
rename but before durable confirmation, the result is uncertain. A missing or
malformed reply cannot become acceptance. Confirmed earlier files remain accepted
when a later write fails or the remaining proposal is rejected/cancelled.

`accepted` requires publisher evidence; clicking approve only starts publication.
`rejected` records discarding a proposal and does not mean the source was written.
A hidden/reopened panel permits fresh review but cannot revive an old confirmation.
Retired handles and consumed proposal identities remain unusable. Batch publication
is per-file and is not a multi-file atomic transaction.

## Validation

```sh
python3 -I -B tests/run.py ai_staged ai_staged_shared ai_staged_multi ai_conversation_review nvim_ai_staged nvim_ai_staged_publish nvim_ai_staged_decisions
python3 -I -B tests/run.py
stylua --check lua tests
git diff --check
```

The seven targeted suites passed (`.test-results/run-eciih5rh`), including
21 controller cases (one optional skip), 28 publisher tests and 37 decision tests. Independent
review found no issues in the test/fixture changes. Formatting and whitespace
checks passed. The final default run passed **63/63 suites**, including the
existing cancellation/recovery and relocated-install cases
(`.test-results/run-coybd6y6`). Environment: Linux, Neovim 0.12.4, Python 3.14.4.
The first focused run caught an audit-test expectation: durable `result.json`
includes the proposal ID in addition to the return payload. The assertion now
checks both rather than dropping identity.

Limits: fake ACP traffic, temporary projects and injected filesystem faults; no
live provider, real power-loss experiment or new recovery mechanism. Existing
retained-artifact and unsaved-memory limits in ISQ-351 still apply.
