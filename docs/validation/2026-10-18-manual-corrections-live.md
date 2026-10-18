# Manual correction live acceptance — 2026-10-18

A bounded, agent-operated trial exercised Edit → Freeze → review → approval
through the production runtime at `8c1117b73e8deabb9dca65b79c4c1dbe4e39e36b`.
It sent one prompt for one synthetic Lua file in a disposable project, using a
private Neovim/tmux instance. No personal project, installation or configuration
was changed by the trial.

## Environment and scope

Linux; Neovim 0.12.4; Python 3.14.4; Bubblewrap 0.11.1; tmux 3.7c;
OpenCode 1.18.34 / ACP 1; configured OpenAI OAuth with `openai/gpt-6-astra`.
The actual completed turn confirmed that model. Only the selected synthetic
file and request were submitted. There was no retry or second provider prompt.

The file began as:

```lua
return function(name)
  return "Hello, " .. name
end
```

The provider was asked to add `.. "!"` to the return statement. Its exact frozen
proposal matched that request. Ordinary editor keys then changed `Hello` to `Hi`
in the separate editable correction. All versions ended with a newline.

## Observed results

| Step | Result |
| --- | --- |
| Provider proposal | Exact requested proposal; saved project file still matched the baseline. |
| Edit | A separate editable scratch contained `return "Hi, " .. name .. "!"`; the project remained unchanged. |
| Freeze | Revision advanced from 1 to 2 with a fresh token and manual provenance. The replacement was read-only; the project still matched the baseline. |
| Approve | The ordinary `a` review action wrote exactly the corrected bytes. The settled round recorded one accepted file and receipt sequence 1. |
| Model work | Snapshots before and after correction, approval and Close all retained one model turn and worker generation 1. The local correction needed no further model turn. |
| Close | Public Close reached `closed`; a pidfd observed the controller exit. The disposable editor/project was removed and original credential bytes were unchanged. |

## Observer correction and evidence

The one-off runner reached approval and passed its exact saved-byte assertion,
then exited with a bookkeeping error: it read `approved["review"]` after the
last file had settled. The owner intentionally clears the active review and
retains the receipt-confirmed result in `approved["rounds"][-1]`.

The original runner and failure report were preserved. The saved live snapshot
reproduced the mistaken lookup; the corrected completed-round assertion passed
offline. An evidence check also verified revision/token replacement, accepted
receipt, single-turn/source-generation continuity, public Close, controller exit,
and fixture removal. No additional provider request was made to repair the
observer. This is a verified live workflow with a corrected evidence check,
not a claim that the original runner exited successfully.

Local evidence includes phase snapshots, terminal captures, the original runner,
its failure report and the subsequent verification result. Public documentation
omits account identifiers, credential paths and private evidence locations.

## Pre-merge verification

The full default suite passed **67/67 suites**, including all 11 terminal UI
cases, on the tested runtime (`.test-results/run-5s1ezgun`).
`stylua --check lua tests` and `git diff --check` also passed. Only validation
documentation was added after that run; no runtime or test code changed.

## Limits

This demonstrates a concrete correction without another model turn. It does not
measure everyday user benefit or compare interaction time with asking the model
again. It was agent-operated in a disposable editor, not user-performed acceptance
in a normal configuration. HTTP request count, spend and credential-refresh
internals were not measured. Other models/accounts and the separate installed
OpenCode audit remain outside this trial. Drafts remain memory-only.
