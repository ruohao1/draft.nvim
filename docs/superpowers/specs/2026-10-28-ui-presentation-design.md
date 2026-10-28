# Chat, review and README presentation

## Direction

Polish the existing native Neovim splits. Give messages and proposed code more
space, shorten repeated labels, and make the README a useful first visit.
The user requested a plan after this approach was recommended. The layout and
copy below are planning decisions, ready for implementation review.

At baseline `f35a0c3`, the README has 600 lines and about 4,647 words. Chat repeats
its model, phase and controls across three surfaces. Its first README screenshot
shows an empty conversation. Existing navigation and publication guards already
provide the required behavior.

## Approaches

- **Native polish, selected for this plan:** reuse the transcript, composer,
  diff windows and action menu. Standard highlights follow the user's theme.
  The change stays small and keeps familiar keyboard behavior.
- **Borders and additional panels:** stronger framing, but less room for code
  and more layout work. This is outside the selected scope.
- **Documentation only:** improves onboarding but leaves the reported UI problem.

## Chat

Keep the current right split at 100 or more columns and bottom layout below it.
Keep the default 48-column chat width, 3–6-row composer and passive hide below
40 columns or 12 rows. Do not change global editor options.

Use one compact winbar for Draft, phase and next-turn model. Retain the explicit
`next:` label: changing it must not relabel earlier replies. Show editable paths
once in the transcript, with the existing bounded metadata treatment. Place
`g? actions` and `q hide` in the transcript footer. Put send/newline hints by the
composer. Remove the duplicate buffer heading and empty status labels.

Give generated role labels, tool summaries, review results and notices distinct
standard Neovim highlights. Separate turns with one blank line. Preserve message
text literally; use semantic row metadata, not patterns that might style provider
text as trusted status. Do not add Markdown rendering, concealment, fonts or a UI
dependency. Keep the existing 2 MiB / 20,000-line transcript and 32 KiB draft limits.

| State | Visible information and available action |
| --- | --- |
| Empty/idle | Editable paths, a short first-message hint and composer. Opening remains passive. |
| Starting/generating | Current startup/progress text and `gc cancel`. Keep the unsent draft intact. |
| Stopping/cancelling/closing | Explicit phase. Do not imply completion or offer a new submission. |
| Review pending | Pending outcome and `gd review`. Sending is a follow-up, not approval. |
| Editing/freezing | Correction state and the existing Freeze/Discard guidance. Freezing does not publish. |
| Publishing | Publication in progress; do not imply success before a receipt. |
| Failed/recovery required | Failure reason and allowed recovery. Advertise `gr retry` only when `retry_safe` is true and recovery is not required. Preserve uncertain outcomes and close guidance. |
| Closed | Retained history and the existing New action. Composer stays read-only. |

Hints follow the existing coordinator's action eligibility. They do not add actions
or weaken its checks. Put the current action/recovery note after the latest turn
so tail-following readers see it above the composer. Keep phase in the winbar
while preserving the viewport of someone reading older messages.
Full paths, long reasons and model names remain available
through the transcript or existing status/action surfaces if a winbar truncates.

## Frozen review

Use short `Saved` and `Proposed` panel labels, file position and an explicit
decision label. Keep retained decisions marked as retained context, rather than
presenting accepted content as a new proposal. Keep native diff colors and all
snapshot buffers read-only.

The managed review footer prioritizes `a accept`, `r reject`, `f chat` and
`g? actions`. Keep this compact hint in both focusable panes so it also works with
Neovim's global statusline. Other keys remain in the existing action menu/help.
Standalone staging retains its different `f` meaning and available controls.
Do not promise a control when that caller supplies no action callback.

On terminal resize, rebalance a managed review only when its active tab still
contains exactly its two frozen diff panes. Preserve background and repurposed tabs.

Preserve automatic review timing, Escape deferral, return-to-chat behavior,
per-file/batch decisions and all source checks. Shared title changes also cover
standalone staging; native after-write review is outside this redesign.

## README and documentation

Target 120–160 lines: purpose, a populated real TUI screenshot, requirements and
installation, a short first-edit walkthrough, essential keys, then further help.
Label development screenshots and synthetic provider data accurately.

Keep Linux, Neovim 0.12+, required tools, exact backend pins, the beta/development
distinction and approval-before-write semantics easy to find. Put Codex setup,
advanced workflows and recovery guidance in one focused `docs/usage.md` guide.
Keep `doc/draft.txt` as the complete command/option reference. Link existing
release and test guides instead of copying their histories. Preserve material
limits: native after-write behavior, sensitive retained artifacts, incomplete
recovery and non-atomic multi-file publication.

## Acceptance and delivery

Capture empty chat, a populated conversation, pending review and failure/recovery
at 140×42 and 70×28. Inspect populated chat and review in a light theme as well
as the dark capture theme. Verify global statusline behavior, literal `%`/Unicode
paths, long models, repeated updates and hidden/background views.

Use the existing isolated TUI fixtures. Real credentials, paid requests and a VM
are unnecessary for this presentation change. Keep the design, plan, screenshots
and validation with the implementation branch and PR. No production changes are
part of this planning deliverable.
