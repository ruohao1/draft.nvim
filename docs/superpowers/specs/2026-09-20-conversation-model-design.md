# Conversational model selection

ISQ-236 adds the public picker for the existing conversation owner's passive
`choose-model` action. The intent is to change the next eligible turn's model
without restarting Neovim, losing history, or changing provider accounts.
This working design implements the authorized issue; it is not a claim of
separate user approval of this newly written document.

## Contract

- `:NvimAIChatModel`, normal-mode `gm` in either chat buffer, and the idle action
  menu open the same picker. A choice applies to this conversation until changed.
- Only idle conversations with a previously confirmed model expose the latest
  advertised same-provider model IDs. Before initial negotiation, explain that
  the user must explicitly send with the configured model first. Opening chat or
  a picker must not start the controller, discover models, authenticate, or send.
- Generation, stopping, publishing, pending review, failed and closed states
  refuse model selection with a visible reason. Completing or explicitly
  discarding review returns to the existing permitted lifecycle points.
- Selecting an item confirms a local next-turn preference. Cancelling does
  nothing. Revalidate the advertised item and the existing dialog fence (owner,
  revision, draft, navigation and visibility) when the callback runs. Stale
  callbacks cannot mutate even if the user returns to the old tab or view.
- The transcript and winbar label the selection as `next:`. Earlier turn model
  labels and proposal identities remain fixed. The picker marks the current
  item and explains that the preference is conversation-only.
- Selection preserves the composer, scope, turns and provider store. Hide/reopen
  retains it. Close retains readable history; an explicit New reads the saved
  default again. No model selection writes settings or account files.
- A later explicit Send resumes the same session in a fresh confined worker.
  It rechecks available model options and confirmation before `session/prompt`.
  Removed models, missing auth, failed confirmation or failed resume produce
  the existing explicit failure/recovery outcome. They never choose a fallback,
  create a replacement session, automatically replay, or relabel earlier turns.
  Recovery requiring Close/New is explained; no hidden reconstruction is added.

## Approach and alternatives

Reuse `ai.chat`'s dialog fence, `ai.conversation`'s model admission and the current
ACP negotiation. A free-text picker would accept unadvertised models; live
discovery on opening would violate passivity. A saved-default toggle would mix
runtime selection with settings, whose existing explicit setup flow is adequate.
No new protocol operation or session migration is needed.

## Boundaries and validation

Linux; Neovim 0.12+ and LuaJIT; Python standard library; pinned OpenCode 1.18.30.
Keep two-space Lua indentation, double quotes and 100-column formatting.
No real provider request, user credential, live editor, personal config or user
tmux server is used. Run confined fixtures outside the tool sandbox; do not
weaken Bubblewrap, helper trust checks or cleanup proof.

Use real semantic owners for picker lifecycle, stale choices, cancellation,
catalog replacement and persistence checks; the transport alone is synthetic.
Use the production controller with scripted ACP to prove resume and model
confirmation order, missing auth, capability loss and failed switching. Exercise
real terminal keys and capture the visible selection. Run the full provider-free
suite and one fresh whole-branch review before publishing.
