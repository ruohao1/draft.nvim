# Linux beta release preparation — 2026-10-04

Scope: [ISQ-353](https://linear.app/isqrd/issue/ISQ-353/prepare-the-linux-beta-candidate-and-release-handoff).
Proposed version: `v0.1.0-beta.1`. This is a local preparation record, not a
published release or a hosted-CI pass.

The release changes CI's tmux pin to 3.7c and adds version-selection, installation,
upgrade, rollback and release notes. Production code, fixtures and approval
guards are unchanged from the [QA checkpoint](2026-10-04-linux-beta.md).

## Candidate identity and environment

Tested checkpoint: `449dd77a3ee3ac93359c0ae7aac6cc28f1b4e3ee`, branch
`release/linux-beta-candidate`. The tree was clean at the start of the full suite.
The final evidence record and a help-text line wrap follow that checkpoint;
neither changes runtime, fixtures or the CI job. The proposed version remains
`v0.1.0-beta.1` until a separate tag/publication decision.

Linux `7.0.0-34-generic` x86_64, Neovim `0.12.4`, LuaJIT `2.1.1774638290`, Python
`3.14.4`, Bubblewrap `0.11.1`, Git `2.53.0`, ripgrep `15.2.0` and tmux `3.7c`.
The passively resolved OpenCode executable is
`/home/ubuntu/.opencode/bin/opencode`, version `1.18.34`, SHA-256
`9ca0b9953d49997601655e54f846a3efa464f237e47c6f1b04716d0f2e64c4c2`.

## Results

| Check | Result |
| --- | --- |
| Baseline setup/installation | `draft_setup` and `nvim_ai_install` passed, including all 3 relocated installation cases. |
| Candidate default suite | **63/63 suites passed, 0 failures**, including 3 installation, 9 TUI and 35 controller cases. Expected opt-in provider skips remain separate. |
| Version-pinned lazy.nvim install, upgrade and rollback | Passed through 6 fresh editor processes, with exact checkout and lockfile commits. |
| Optional native upgrade fixture | `sh tests/nvim-ai-native.sh version-upgrade-opencode` passed. |
| Static checks | Lua formatting passed; all 6 embedded CI shell steps parsed; workflow triggers and verified archive digest matched; local documentation links resolved. |
| Installed OpenCode artifact/interop evidence | Carried forward from QA, as detailed below; not rerun in this package. |
| Hosted candidate CI, user acceptance, live-account prompts | Not performed. These remain release gates. |

## Installation, upgrade and rollback evidence

The maintained installation suite copies the candidate into a path with spaces
and runs from an unrelated working directory. It validates production setup,
commands and help tags, plus guarded chat approval/recovery with no tmux on PATH.

A separate one-off driver uses lazy.nvim commit
`85c7ff3711b730b4030d03144f6db6375044ae82`, archived from the installed checkout
into disposable storage. The personal plugin-manager checkout and user config
remain untouched. Its local-file Git remote points to the candidate checkout;
only the file protocol is allowed, with no GitHub fetch or live credentials.

The sequence installs alpha.1, upgrades to the exact candidate, and rolls back
to alpha.1. Each change uses a maintenance editor followed by a fresh smoke
editor. The driver checks both Git HEAD and `lazy-lock.json` at each revision.
Alpha's public `:NvimAIStageSetup` saves `fixture/model`; an explicit
`:NvimAIReviewMode pre_write` sets the routing preference. All later editors load
the same bytes without resaving them.

Each smoke editor resolves help from the selected checkout, opens the saved
source file, opens idle chat at turn 0, and waits for confirmed Close. Source
bytes, inode, permissions and mtime remain unchanged, as do preference bytes.
No provider data directory is created. Launch traces show only the local
settings helper and, on Close, the local Python conversation controller that
acknowledges cleanup. OpenCode is resolved but never launched; no Send occurs.

The driver needed ordinary harness corrections before passing: a disposable
lazy copy for generated help tags, safe `/tmp` HOME/XDG ancestors, explicit
alpha routing, the required CLI on PATH, and waiting for asynchronous Close.
The ownership guards were not weakened. These corrections did not change the
plugin or establish product regressions.

This proves plugin code/preference transitions with private state, not personal
configuration compatibility or OpenCode database downgrade safety. Alpha's
required OpenCode 1.18.30 was not launched; 1.18.34 was only resolved during the
passive checks. The separate native upgrade case uses a synthetic CLI and
validates recovery from old native version references. It is not a live downgrade.

## Carried-forward provider evidence

The [QA record](2026-10-04-linux-beta.md) at
`3f2d67a16782e2423eaadb359d987dfbaca5a473` includes the installed 1.18.34 artifact
audit, four scripted-provider interop cases and one owner-death case. Comparing
that commit with the candidate finds no changes in `lua/`, `scripts/`, test code
or fixtures; only `tests/README.md` differs under `tests/`. The installed binary
identity and local tmux version are unchanged.

Those exact results remain evidence for the same runtime. They are not new runs
and do not substitute for candidate hosted CI or current-version live-account
acceptance. Their logs remain in `.test-results/linux-beta-2026-10-04/`.

## Reproduction and evidence

Run `python3 -I -B tests/run.py`, `stylua --check lua tests` and `git diff --check`
from the candidate checkout. The native version case is the separate command
shown above. All maintained tests use private state and synthetic providers.

Local release evidence is retained in `.test-results/linux-beta-release-2026-10-04/`:
the default-suite logs, version-switch driver and reports, six editor logs,
native upgrade log, official archive proof and static checks. Replay notes name
the lazy.nvim and OpenCode paths and explain the local-file remote. Evidence
scripts and logs are local artifacts, not a new supported test runner.

The complete candidate run is `run-l2go7lw1` (see the archived runner transcript
for the recorded path). The baseline run is `run-v6osrvz5`. Formatting,
`git diff --check`, workflow/shell parsing and all 42 current local documentation
links passed. Help tags resolved from the selected checkout in all three
cross-version smoke editors.

## CI artifact and remaining gates

The official [tmux 3.7c archive](https://github.com/tmux/tmux/releases/tag/3.7c)
was downloaded and verified against SHA-256
`7c60cae9a0e25288e2e24750aafc9e8800fc7fd4555e447e1b29ee4201cfb3bf`.
It contains `configure` and `Makefile.in`. The existing Ubuntu job installs its
build dependencies and retains the executable-specific Bubblewrap AppArmor
profile, global namespace restriction, pinned Neovim archive and action SHAs.

Local tmux is 3.7c. The local environment lacks bison and pkg-config, so this
record does not claim a fresh source build of that archive. Hosted Ubuntu CI
must still validate the candidate job.

As checked on 2026-10-04, GitHub's published baseline and remote main remain
`514d9460cf09e970ba325c29fd7aadc5e2e15ba3`. Its
[successful alpha CI run](https://github.com/ruohao1/draft.nvim/actions/runs/36307687622)
is historical evidence, not candidate validation. A candidate branch push and
new hosted-CI result remain outstanding. No tag, release or Linear update was
created during this preparation.

User-operated acceptance and the separately authorized current-version provider
run from the [beta checklist](linux-beta-checklist.md) remain release gates.
No live-account requests are part of this package.
