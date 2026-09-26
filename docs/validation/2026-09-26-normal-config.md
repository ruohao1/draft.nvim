# Linux normal-configuration acceptance — 2026-09-26

Draft was installed into the user's existing lazy.nvim configuration, pinned to
`7bfc7483612fc9b4654e67c7148c93a4b4412a13`. An agent-operated check then completed
one README edit through the installed plugin, frozen review and guarded writer.
This follows the [four-turn disposable pilot](2026-09-22-live-provider.md).

## Installation and environment

The run used Linux, Neovim 0.12.4, Python 3.14.4, Bubblewrap 0.11.1, tmux 3.6,
and OpenCode 1.18.30 / ACP 1 with OpenAI OAuth and `openai/gpt-6-astra`.

The previous embedded `lua/ai` files were moved to a backup before loading Draft.
All 13 backed-up files retained their original bytes. Observed `draft`, `ai`,
`ai.state` and `ai.tools` modules resolved to the pinned plugin checkout.
The existing init and plugin lock files stayed unchanged. Normal startup
reported no error; `:checkhealth draft` reported zero errors and five warnings:
tmux below the recommended 3.7, missing Claude with unknown authentication, and
unchecked native OpenCode authentication and managed compatibility.

A fresh editor loaded that normal configuration inside a private tmux server.
The one-off operator disabled swap, persistent undo, ShaDa and modelines for the
check. A local diagnostic wrapper loaded the installed production controller,
drained worker stderr and retained only recognized error categories. Temporary
editor hooks observed controller launches and proposal-directory identities.
No installed runtime code or existing configuration was changed by the check.

## Successful acceptance request

| Check | Observed result |
| --- | --- |
| Open | The composer opened with only the saved `README.md` selected, before any provider launch. |
| Send | One explicit Send produced one completed backend turn, confirming `openai/gpt-6-astra`. |
| Inspect | The saved README stayed unchanged while the read-only frozen proposal was opened. Its complete bytes matched the requested migration paragraph edit. |
| Approve | Accepting the visible proposal wrote exactly those bytes; the writer receipt marked the file accepted and the conversation returned to idle. |
| Close | Public Close reached `closed`; an independent pidfd wait verified exit of the one observed controller. |
| Cleanup | The private editor fixture and observed proposal directory were removed; original credential bytes were unchanged by this request. |

The accepted edit adds the installation guidance to move an embedded `lua/ai`
copy out of the Neovim configuration before loading Draft. The help document
was subsequently updated with the same guidance as a normal documentation edit.

## Earlier attempts and limits

Five backend prompts ran across the personal-installation validation. The first
three failed before a reply; improved diagnostics on the third identified an
OAuth token-refresh rejection for an expired access token. The user signed in
again. The fourth produced the exact proposal, but the one-off operator timed
out before approval because `cmdheight=0` hid a native-picker heading it expected.
Its public Close check also failed, and teardown cancelled and retired that
proposal without changing README. These failures are not counted as acceptance.

The operator was corrected to recognize the visible numbered choice. Before
the fifth, successful request, four local UI scenarios verified approval and
Close from an open picker at `cmdheight=0` and `cmdheight=1`, through the real
controller and guarded writer with a confined fake provider. Passive startup
and offline observer checks also passed without provider requests. Each live
attempt had explicit authorization; the successful request used no retry or
fallback. Earlier setup refusals sent no backend prompt.

Snapshots, terminal captures, exact before/expected/after bytes, controller-exit
checks and credential-integrity results were retained locally. This public
record omits raw transcripts, account identifiers and private evidence paths.

This completes the scoped installation and normal-configuration acceptance for
the pinned runtime. It was agent-operated in a fresh editor, not user-performed
manual QA or extended everyday use. Other accounts, models, platforms and native
companions remain outside this live evidence. HTTP request counts, billing and
token-refresh internals were not measured. Automatic crash recovery, transcript
restoration, orphan retention management and atomic multi-file publication
remain outside the validation. No release was tagged or published.
