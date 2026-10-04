# Linux beta publication — 2026-10-04

[v0.1.0-beta.1](https://github.com/ruohao1/draft.nvim/releases/tag/v0.1.0-beta.1)
was published at 14:00:04 UTC from
`c3c5d5168eae3f4b48faff0831d564afa652b47d`, following explicit approval of the
exact tag, commit, release notes and two source assets. It is a public prerelease
and is not marked Latest. The published tag remains fixed at this tested commit.

This record completes the gates left pending in the historical
[local release preparation](2026-10-04-linux-beta-release.md) and
[beta acceptance](2026-10-04-linux-beta.md) records.

## Acceptance evidence

| Check | Result and scope |
| --- | --- |
| Default suite | 63/63 suites passed locally at the preparation checkpoint; the later candidate commits changed only documentation. |
| Hosted CI | [Run 37188134760](https://github.com/ruohao1/draft.nvim/actions/runs/37188134760) passed 63/63 suites on the exact released commit. The tmux 3.7c build and Bubblewrap namespace checks also passed. |
| Installation and version changes | Fresh relocated installation, core chat without tmux, passive lazy.nvim alpha/candidate/alpha transitions and the native upgrade fixture passed, as detailed in the local preparation record. |
| Current-version live provider | Four explicit turns passed with OpenCode 1.18.34 / ACP 1 and OpenAI OAuth / `openai/gpt-6-astra`, using three disposable text files in an isolated editor. |
| User-operated UI | After the prepared five-step offline exercise with a scripted provider, the user reported "done it works". This is a user-reported pass, separate from agent-operated checks. |
| Release archive | All 208 tracked files matched their committed Git blobs and safe file modes. The existing installation suite passed all three tests from the extracted archive. |

The live check covered discussion without writes, automatic frozen review of a
three-file proposal, partial approval/rejection, revision of the remaining
pending file, approval, context recall and confirmed Close. Seven exact-byte
checkpoints passed. The original credential file remained unchanged, and the
disposable editor's controller exited. Exactly four Sends were used; this was
not a measurement of HTTP requests, token billing or a monetary cap.

The user-operated exercise covered automatic review after leaving insert mode,
accept/reject navigation, returning to chat and Close. Its result does not prove
acceptance in the user's normal editor configuration or extended daily use.
The live check does not establish other providers, models, live model switching
or native after-write acceptance.

## Published assets

The release contains these two uploaded assets:

- `draft.nvim-v0.1.0-beta.1.tar.gz`
- `SHA256SUMS`

The source archive SHA-256 is:

```text
d0df98c2acc2c49c0898e95bccbe435a4f62f1c9071a50755248da0f9db2177d
```

The archive was generated from the exact released commit with Git's
`tar.umask=0022`, then gzip-compressed with a zero timestamp. It contains source
only, with the plugin's Lua and Python helpers together. Downloaded copies of
both assets matched the approved hashes. The downloaded archive's embedded
commit, tracked-file contents and file modes were checked again.

The public release body matched the approved notes exactly. The remote tag and
the fetched local tag both resolved to the tested commit. Publication sent no
additional provider requests.

## Evidence locations

The public release and hosted CI links above provide the published result.
Local evidence is retained under `.test-results/` and is not included in the
source archive:

- `linux-beta-release-2026-10-04/`: local preparation, installation and review.
- `linux-beta-hosted-ci-2026-10-04/`: hosted job metadata and all 63 suite logs.
- `linux-beta-live-2026-10-04/`: the authorized live check, synthetic terminal
  captures, exact-byte validation and prepared offline user exercise.
- `beta-publication-2026-10-04/`: user report, installation log, authorization,
  prepared/downloaded assets and publication verification.

Each completed evidence archive has a checksum manifest. Credential contents
are not stored in these records. The later documentation follow-up on `main`
updates installation guidance without changing the published beta tag.
