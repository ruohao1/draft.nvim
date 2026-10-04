# Linux beta release preparation — 2026-10-04

Scope: [ISQ-353](https://linear.app/isqrd/issue/ISQ-353/prepare-the-linux-beta-candidate-and-release-handoff).
Proposed version: `v0.1.0-beta.1`. This is a local preparation record, not a
published release or a hosted-CI pass.

The release changes CI's tmux pin to 3.7c and adds version-selection, installation,
upgrade, rollback and release notes. Production code, fixtures and approval
guards are unchanged from the [QA checkpoint](2026-10-04-linux-beta.md).

## Candidate checks

The exact tested checkpoint and final results will be recorded after validation.
The baseline `draft_setup` and `nvim_ai_install` suites passed, including all
three relocated installation cases. Full candidate checks are pending.

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
