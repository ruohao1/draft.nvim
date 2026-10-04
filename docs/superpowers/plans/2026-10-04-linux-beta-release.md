# Linux Beta Release Preparation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan inline, with one final independent review.

**Goal:** Prepare an exact Linux/OpenCode candidate and proposed `v0.1.0-beta.1` release handoff, including CI alignment and installation/upgrade/rollback evidence.

**Architecture:** Keep runtime and guarded publication unchanged. Update the existing CI dependency pin, document reproducible version selection and release limits, and reuse the existing acceptance fixtures plus disposable cross-version editor checks. Candidate publication and hosted-CI state must be reported separately from local preparation.

**Tech Stack:** Linux, Neovim 0.12.4 / LuaJIT, standard-library Python 3, Bubblewrap, Git, optional tmux 3.7c and OpenCode 1.18.34 / ACP 1.

**Spec:** [ISQ-353](https://linear.app/isqrd/issue/ISQ-353/prepare-the-linux-beta-candidate-and-release-handoff), retrieved 2026-10-04: integrate M1/M2 and QA; align CI and pass it on the candidate; validate fresh installation, upgrade and rollback; complete release notes/support limits; identify exact candidate/version; preserve pre-write chat versus native after-write review. Packaging preparation does not authorize tagging, publishing or provider requests.

## Global Constraints

- Base: `e62427f`; preserve root untracked files and unrelated worktrees.
- Proposed version only: `v0.1.0-beta.1`. The published baseline is `v0.1.0-alpha.1` at `514d9460cf09e970ba325c29fd7aadc5e2e15ba3`.
- Pin tmux 3.7c to official source archive SHA-256 `7c60cae9a0e25288e2e24750aafc9e8800fc7fd4555e447e1b29ee4201cfb3bf`. Preserve other CI pins, ownership checks and namespaces.
- Core chat does not require tmux. CI uses it for isolated terminal/native fixtures.
- No live-account prompts, tags, release publication, or Linear writes. Finish concrete local work before any external publication decision.
- Never hot-swap loaded plugin code, restore old approval authority, or imply OpenCode database downgrade compatibility.
- Use private HOME/XDG state and disposable editors. Do not install missing build packages into the user's system.

## Review Focus

1. CI must use the documented supported tmux version with the verified official archive digest; do not relax confinement to obtain a pass.
2. Installation instructions must not tell users to fetch an unpublished tag or local-only commit without saying it is unavailable remotely.
3. Upgrade/rollback must preserve saved source and preferences while starting fresh editors; restarting does not restore chats or approval tokens.
4. Alpha rollback needs its matching OpenCode 1.18.30 pin; no live-account or database downgrade proof may be inferred from passive editor checks.
5. Candidate identity, local tests and hosted CI must stay distinct. Missing remote CI is a remaining release gate, not a green result.

## Task 1: Prepare and verify the release handoff

**Files:**
- Modify: `.github/workflows/linux-tests.yml`, `README.md`, `doc/draft.txt`, `tests/README.md`.
- Create: `docs/releases/v0.1.0-beta.1.md`, `docs/releases/install-upgrade-rollback.md`, `docs/validation/2026-10-04-linux-beta-release.md`.
- Reuse: `tests/run.py`, `tests/nvim_ai_install.py`, `tests/draft_setup.lua`, existing native version-upgrade fixture and the QA checklist.

**Interfaces:** Existing setup, StageSetup, Chat, Close, status and settings interfaces only. No production API or new runner. Disposable archived alpha/candidate checkouts and fresh Neovim processes establish the documented installation boundaries.

- [x] Verify the official tmux asset bytes/digest and update the existing CI version pin. Check YAML structure and embedded shell syntax.
- [x] Write the release notes and installation/upgrade/rollback guide. Link both usage documents and align current testing-stack text while preserving dated historical evidence.
- [x] Exercise fresh installation and passive alpha → candidate → alpha preference/source preservation with fresh editors. Run the existing optional native version-upgrade fixture separately. Record exact scope and limits.
- [x] Commit a checkpoint and run the complete default suite, formatting and local link/help checks. Reuse explicitly identified installed-provider evidence only after proving runtime/test sources are unchanged from its validated checkpoint.
- [x] Obtain one independent review and resolve material findings. Record the exact local candidate and remaining hosted-CI/publication gates; archive evidence and integrate locally under the established authorization.

## Initial evidence and constraints

GitHub reports only `v0.1.0-alpha.1` published; its most recent hosted CI is green
at `514d9460cf09e970ba325c29fd7aadc5e2e15ba3`, not the local beta candidate.
The local machine has tmux 3.7c but lacks `pkg-config` and `bison`; CI already
installs those build dependencies. Local validation will not claim to have
reproduced the hosted source build. No system package changes are needed.
