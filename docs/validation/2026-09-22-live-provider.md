# Linux live-provider validation — 2026-09-22

A bounded, agent-operated pilot completed four conversational turns through the
production Draft controller, confined OpenCode workers, frozen review and guarded
writer. It used three synthetic files in a disposable Neovim/tmux environment.
This is live-provider evidence, separate from the earlier
[provider-free Linux acceptance](2026-09-20-conversation-linux.md).

## Tested scope

| Component | Tested value |
| --- | --- |
| Draft commit | `7bfc7483612fc9b4654e67c7148c93a4b4412a13` |
| Platform | Linux |
| Neovim | `0.12.4` |
| Python | `3.14.4` |
| Bubblewrap | `0.11.1` |
| tmux | `3.6` |
| OpenCode | `1.18.30`, ACP 1 |
| Provider and model | OpenAI OAuth, `openai/gpt-6-astra` |

Four explicit Sends produced four completed backend turns. All completed turns
reported the selected model, and no retry or fallback was used during this run.
The selected saved files had mode `0644`, and source validation passed before
the first Send. Provider authentication and model availability were demonstrated
by actual replies and proposals for this account and run; token refresh was not
independently instrumented.

## Results

| Step | Observed result |
| --- | --- |
| Discuss the selected files | A reply described all three files; saved contents stayed unchanged. |
| Propose three replacements | All three exact frozen replacements were inspected. Saved contents stayed unchanged until approval. |
| Make partial decisions | The first file was accepted, the second rejected and the third left pending. Only the accepted first-file bytes reached disk. |
| Revise the pending file | The replacement preserved the earlier acceptance and rejection. The revised third file reached disk only after its new frozen proposal was inspected and accepted. |
| Recall earlier context | The final turn recalled a marker supplied only in the first prompt and correctly summarized the file decisions. |
| Close | Public Close completed within the operator's 20-second bound; the disposable editor directory was removed and original credential bytes were unchanged. |

Final saved contents, each ending with a newline:

| File | Decision | Contents |
| --- | --- | --- |
| `first.txt` | Accepted | `accepted first` |
| `second.txt` | Rejected | `original text` |
| `third.txt` | Accepted after revision | `revised third` |

All four snapshots retained one editor conversation identity. The successful
marker recall supplies an additional check of conversational continuity; raw
provider database contents were not inspected.

## Evidence and limits

Turn snapshots, terminal captures, disk checks and an independent post-Close
process inventory were retained locally. This public record omits raw transcripts,
credential paths, account identifiers and host-specific evidence locations.

The production driver exposes `closed` only after clean controller exit and
output EOF, and controller cleanup requires stopped workers and store cleanup.
The subsequent process inventory found no matching remaining controller,
confined OpenCode worker or pilot editor/tmux process. A separate launch observer
hooked `vim.system`, but the controller uses `vim.uv.spawn`; that observer's zero
count is not launch or exit evidence. No independent controller pidfds were
captured. The cleanup result relies on the production exit/EOF-gated state and
the post-Close process inventory.

This pilot supports the tested Linux/OpenAI OAuth/GPT-6 Astra workflow. It does
not establish compatibility with other accounts, models, platforms or native
Codex/Claude companions. It was agent-operated in a disposable editor, not
user-performed acceptance in an everyday Neovim configuration. Internal HTTP
request count, monetary spend and credential-refresh events were not measured;
the turn limit was not a monetary cap.

Automatic crash recovery, transcript restoration, orphan retention management
and atomic multi-file publication remain outside this validation. No personal
installation, package change or release was performed by the pilot. The next
acceptance step is installation in the user's normal Neovim setup and a small
real-project workflow before a Linux prerelease decision.
