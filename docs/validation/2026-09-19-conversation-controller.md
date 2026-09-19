# Production conversation controller validation

## Baseline — 2026-09-19

Baseline commit: `c6d4d198fe019c9372ab0a2bae24dc3afca462c1`.
The approved controller plan starts from the completed standalone extraction and
Linux CI. Tests ran from a new isolated worktree before implementation changes.

- `python3 -I -B tests/run.py`: **46/46 suites passed**, zero failures; installed-agent opt-in skips were expected.
- `tests/nvim_ai_acp_resume.py -v`, with its explicit pinned-runtime opt-in: **4/4 passed** in 14.097 seconds.
- `tests/nvim_ai_conversation_lifetime.py -v`, with the same opt-in: **5/5 passed** in 2.273 seconds, including the real runtime owner-death case.

The opt-in runs used an allowlisted environment, disposable HOME/XDG directories,
synthetic credentials and a loopback scripted provider. They reused the existing
OpenCode executable without installation or upgrade. No live account, editor,
tmux session or configuration was changed.

Tested versions: Neovim 0.12.4, Python 3.14.4, Bubblewrap 0.11.1, Git 2.53.0,
tmux 3.6 and OpenCode 1.18.30 / ACP 1. The OpenCode executable SHA-256 was
`87bd160e053af86b5b409daabf71f8dc05bbc3a2a3a5f563f36011cdf706a999`.

These results establish the component baseline, including retained history
across worker restart and owner-death supervision.

## Production controller — 2026-09-20

The production Python controller and trusted Neovim adapter now connect the
semantic owner, bounded editor pipe, ACP worker, metadata-only store and guarded
review publisher. This delivers the internal engine for
[ISQ-233](https://linear.app/isqrd/issue/ISQ-233); the chat composer, navigation,
model picker and hands-on acceptance remain sibling issues.

Complete provider-free regression run: **52/52 suites passed**, zero failures,
with installed-runtime probes explicitly skipped. Touched Lua files passed
`stylua --check`; `git diff --check` passed.

Focused implementation evidence:

- Protocol/registry/controller/publication/refinement run: **8/8 suites passed**.
  The controller's 26 process tests included blocked input/output, cancellation
  after freezing, source/store drift, EOF and detached descendants.
- Neovim integration run: **11/11 suites passed**, including shared staged
  guards, runtime exclusion and relocation into a path containing spaces.
- Real Neovim exit: **1/1 additional process test passed**. Exact controller and
  worker PID descriptors confirmed exit; task, retained store and launch config
  were removed. This case also runs in the default controller suite.
- Guarded publication used the existing writer and actual journal receipts.
  Hidden dirty aliases, changed frozen panels and unvisited files were refused.
  Accepted-source refresh failure preserved the confirmed accepted file while
  fencing remaining decisions. Stale native pickers could not launch after a
  conversation acquired and released the runtime lease.

Pinned production-controller interoperability: **4/4 cases passed** using
`tests/nvim_ai_conversation_interop.py` and the exact isolated invocation in
[tests/README.md](../../tests/README.md). Three cases passed in the initial run;
the continuity case passed after correcting its test's initial review identity.
The runtime was unchanged OpenCode **1.18.30 / ACP 1**, with the SHA-256 recorded
above. No paid credentials, installations or user configuration changes occurred.

- A real native edit tool result and distinctive assistant reply survived into
  a fresh worker's provider request. Neither was replayed in its new submitted
  prompt. One `session/new` and one `session/resume` used the same session ID;
  observed worker PIDs were `713290` and `713876`.
- The first proposal was rejected through the real decision helper. Project
  bytes remained original. A subsequent question-only turn produced no proposal.
- Rotating synthetic profile credentials and choosing the second advertised
  model affected only the next explicit turn. Both workers reapplied model/build
  configuration with compaction and pruning disabled.
- Cooperative cancellation preserved eligible context for a fresh worker. A real
  missing-session response and an HTTP context-overflow response failed without
  a new session, implicit compaction or a repeated provider request. Only the
  missing-session test substitutes an invalid identifier in its test observer.
- Every listener stopped. Retained files were private regular single-link DB,
  WAL and SHM artifacts, inspected only through metadata. The continuity case
  recorded sizes **266,240 / 819,912 / 32,768 bytes**, below the 64 MiB cap.
  Confirmed close removed retained backend state.

Consumed frozen journals retain publication evidence under the existing staged
policy; close retires their approval authority. There is no cross-editor store
adoption, automatic recovery, new public chat command or live-account acceptance
claim. Final review, PR and post-merge CI evidence are tracked on
[ISQ-233](https://linear.app/isqrd/issue/ISQ-233).
