# UI and documentation presentation validation

Date: 2026-10-28. Baseline: `f35a0c3`. UI implementation and review fixes:
`e3ba0a97d0c8646d34850c5648609dee925af7e0`.

## Result

Chat has one phase/model header, theme-aware role labels and current guidance
after the latest reply. Provider text remains literal. The composer advertises
Send only in eligible states. Frozen-review titles prioritize panel role and
decision; managed review keeps its two owned panes balanced on terminal resize.

The README is 124 lines / 768 words, down from 600 lines / 4,647 words. Detailed
configuration and recovery guidance is in [the usage guide](../usage.md) and
the existing help reference. The README distinguishes the published OpenCode
beta from development-only Codex and UI changes.

## Checks

- `python3 -I -B tests/run.py`: **75/76 suites passed** in
  `.test-results/run-n_1crx_r`. The remaining sandbox case refused its
  group-writable fake executable. After restoring that fixture to `0755`,
  `python3 -I -B tests/run.py nvim-ai-sandbox` passed **1/1** in
  `.test-results/run-snaraetr`. All 76 suites have passing results; this was a
  full run plus a targeted environment-corrected rerun.
- The real-key TUI suite passed **14/14 cases**. It uses a private tmux server,
  clean Neovim state and deterministic providers. Opening, model selection,
  hide/reopen, resizing and theme changes do not submit or publish.
- Headless checks cover literal provider text resembling role/receipt labels,
  UTF-8 retention bounds, stale highlight removal, historical model labels,
  long model names at the actual 48-column width, and pending-review transitions.
- Shared review tests cover literal `%`/Unicode paths, retained accepted/rejected
  decisions, read-only buffers, background tabs and repurposed review tabs.
- Lua formatting and whitespace checks passed. Local documentation links and
  help tags resolve. The README was rendered with CommonMark tables in an
  isolated headless browser and inspected visually.

The initial local run exposed an old integration assertion reading phase from
the transcript. It now inspects the evaluated winbar. The new worktree also had
group-writable checkout files, including trusted helpers and a fake executable
used by the sandbox suite. Their normal Git executable/non-executable modes
(`0755` / `0644`) were restored. No sandbox or ownership checks were weakened.

## Terminal captures

These are actual terminal-cell captures, rendered with the existing
`tests/fixtures/ai/render_chat_capture.py`. They contain synthetic messages and
proposals. Older screenshots remain unchanged for historical records.

| State | Wide | Narrow | Light theme |
| --- | --- | --- | --- |
| Empty chat | [140×42](../images/presentation-idle-wide.png) | [70×28](../images/presentation-idle-narrow.png) | — |
| Conversation | [140×42](../images/presentation-chat-wide.png) | [70×28](../images/presentation-chat-narrow.png) | [140×42](../images/presentation-chat-light.png) |
| Pending review | [140×42](../images/presentation-review-wide.png) | [70×28, global statusline](../images/presentation-review-narrow.png) | [140×42](../images/presentation-review-light.png) |
| Failed startup | [140×42](../images/presentation-failure-wide.png) | [70×28](../images/presentation-failure-narrow.png) | — |

The README uses the [first-reply capture at 140×30](../images/presentation-chat-intro.png).
Dark captures use bundled `habamax`; light captures use bundled `peachpuff`.
Capture waits require the final phase/model header after layout changes, and
failure captures also wait for the state-appropriate composer hint.

Reproduce the raw grids with:

```sh
DRAFT_CHAT_CAPTURE_DIR=/tmp/draft-presentation-captures \
  python3 -I -B tests/nvim_ai_chat_ui.py -q
```

See [capture rendering instructions](../../tests/README.md#conversation-ui-evidence).
For the README image, render `conversation-intro.ansi` at 140 columns. The other
names follow the capture calls in `tests/nvim_ai_chat_ui.py`.

## Independent review and limits

One independent reviewer checked the whole change, documentation and all eleven
screenshots. The review found a long-model truncation issue and pending-review
action hints during unavailable phases. Both were reproduced with failing
regressions and fixed. The reviewer also caught two screenshots taken before a
scheduled resize render; those waits and images were corrected. The reviewer
confirmed the fixes and reported no remaining material findings.

These checks exercise editor presentation and existing fixture workflows. They
do not establish live-provider acceptance, actual token refresh or release
availability. No real credentials, paid requests or user editor configuration
were used. The published beta keeps its earlier UI until a new release is made.
