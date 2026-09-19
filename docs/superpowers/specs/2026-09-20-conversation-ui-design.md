# Neovim conversation UI

Date: 2026-09-20. Implementation brief for [ISQ-234](https://linear.app/isqrd/issue/ISQ-234), following the user's instruction to continue with the next deliverable. The optional placement preference was offered; the working default is a right-hand split. This document records decisions, not a claim of completed implementation or a separate written-artifact approval.

## Intent and scope

Make the production conversation engine usable for explicit multi-turn questions inside Neovim. A user opens chat beside saved selected files, composes a message, deliberately submits it, reads streamed replies, and can hide/reopen the view without starting another turn. Model, selected files, lifecycle state and pending review remain visible. Opening a frozen diff is explicit.

ISQ-234 owns presentation, commands, safe window/buffer lifetime, review navigation and a keyboard walkthrough. ISQ-235 owns user-facing approval, batch decisions and conversational revision controls. ISQ-236 owns the model picker. ISQ-237 owns integrated acceptance, including separately authorized real-account requests. This increment exposes frozen proposals as previews, with return-to-chat and explicit cancel/close; it does not claim a complete editing UX.

Use the existing semantic owner, production factory, runtime lease and guarded review implementation. Do not add another lifecycle state machine, project writer, credential store, terminal scraper or provider transport. There is one current or retained closed chat per runtime.

## Placement

| Choice | Benefit | Cost |
| --- | --- | --- |
| Right-hand split (chosen) | Code and conversation remain visible together; ordinary Neovim navigation | Needs a narrow-editor fallback |
| Dedicated tab | Predictable space for transcript/composer | Code and chat are separated |
| Floating window | Compact overlay | Obscures source and complicates focus/resize behavior |

Use two owned scratch windows: transcript above a small editable composer. At 100 columns or wider, open a right-hand column, default width 48, constrained to preserve at least 40 source columns. Below that width, use a bottom area with transcript above composer. Require at least 40 columns and 12 editor rows; smaller dimensions hide the view while retaining the owner and draft and offer reopening after enlargement. Resize changes only owned windows. Never replace a window the user has repurposed with another buffer. Explicit reopen may rebuild missing owned windows.

Opening focuses the composer. Streaming and lifecycle events never switch windows/tabs, move the source cursor or enter insert mode. Auto-scroll only if the transcript was already following its tail; users reading older messages retain their cursor/viewport. An explicit compose action focuses the draft. Hide closes only owned windows, leaves buffers/owner intact and returns to the original source window when it still exists. Ordinary window closure has the same passive semantics.

## Public commands and controls

- `:NvimAIChat [files...]`: first open selects the saved current file when no paths are supplied; explicit arguments select 1–16 files through existing capture checks. Subsequent no-argument calls reopen the same conversation. Arguments cannot silently change an existing conversation's scope.
- `:NvimAIChatNew [files...]`: start a fresh passive owner only after the previous owner is confirmed closed. With no arguments after close, reuse its fixed selected paths. Replace the retained transcript only after new construction succeeds; confirm before clearing a nonempty unsent draft.
- `:NvimAIChatSend`: submit the composer only when the semantic owner permits it. Return/newline alone never submits. Clear the composer only after dispatch admits the action; preflight refusal preserves it.
- `:NvimAIChatHide`: hide the view; no cancel, close, submission or review decision.
- `:NvimAIChatCancel`: explicit cooperative cancellation, or retirement of pending proposals. Confirm when pending review is being discarded. Keep earlier accepted outcomes intact.
- `:NvimAIChatRetry`: explicit retry only when the owner reports `retry_safe`; use the composer if nonempty, otherwise the failed turn's original prompt. Never queue or replay automatically.
- `:NvimAIChatClose`: explicit owner close. Confirm when discarding pending review. The UI stays until the closed event, showing failure/recovery if cleanup is unproven. Window closure never invokes this command.
- `:NvimAIChatReview`: choose a file from the current frozen proposal and show its existing diff surface. Opening/revisiting is read-only. Return with `:NvimAIChat`.

Buffer-local controls are always available in owned chat buffers: Ctrl-S sends (normal/insert), `q` hides (normal), `gi` composes, `gd` opens review, `gc` cancels, `gr` retries, `gx` closes, and `g?` opens a state-aware action menu. Enter remains a newline in the composer. Help is displayed in the view. Existing global mappings are unchanged; optional `keymaps=true` adds `<leader>at` for chat.

All delayed menus/confirmations capture owner identity, view revision and draft changedtick where relevant. Revalidate before acting. Late callbacks after new/close/hide cannot submit, close a replacement, change selection or visit a stale proposal. Refusals appear once in the chat status area; streamed content never uses notifications or command-line output.

## Configuration and opening

Reuse the effective explicitly enabled staged model/auth/provider/executable settings. Add a narrow `staged.conversation_options()` reader that returns a defensive copy of only root, model, auth_file, provider, python, opencode and bwrap, or a setup reason. Loading local preferences is allowed on an explicit command; setup/require remain passive. No login, model discovery, credentials read or ACP worker is triggered by chat opening. Existing `:NvimAIStageSetup` remains the opt-in configuration entry point.

Opening captures the saved scope before constructing the owner, using `staged_sources.capture`. Source capture may load explicitly selected buffers but never saves them. Submit still recaptures through the trusted factory. Dirty/aliased, missing, unsupported or oversized selections fail without losing the draft or creating a worker. Root and selection remain fixed for the owner's lifetime.

The runtime retains its existing conversation lease. Native/staged activity, pending dialogs, native review and a second owner remain excluded while an idle or hidden conversation exists. A retained closed transcript has no execution lease. New owner creation rechecks runtime exclusion.

## Components and interfaces

- `lua/ai/chat_view.lua`: owns transcript/composer buffers, window placement, display projection, render coalescing and local mappings. `new({on_action,on_hide,width?}) -> view`; methods `show(snapshot)`, `update(snapshot)`, `hide()`, `dispose()`, `draft() -> text|nil,reason,stamp`, `set_draft(text)`, `notice(reason)`. It never calls the engine or writer.
- `lua/ai/chat.lua`: owns the one owner/view pairing and subscription, resolves scope/configuration, maps UI actions to owner dispatch and fences delayed UI callbacks. `new({create,configuration,width?,notify?}) -> chat`; methods `open(files?,fresh?)`, `send()`, `hide()`, `cancel()`, `retry()`, `close()`, `review()`. `create(config)` is the runtime's production `conversation` method; test fixtures substitute only provider transport/configuration below that boundary when possible.
- `lua/ai/init.lua`: lazily creates the chat coordinator, supplies runtime creation and effective preferences, registers commands and optional mapping, and disposes closed UI state during successful runtime shutdown. Existing native command meanings are preserved.
- `lua/ai/conversation_controller.lua` and `staged_review.lua`: add trusted `defer_review=true` for the chat factory. Validate material/captures and bind the owner event before exposing a read-only handle, but create/focus diff windows only on explicit `show(path)`. Default existing factory/staged behavior remains eager. Never expose writer authority to the renderer.

Lazy review handles hold immutable material and capture evidence. Before first display, source drift invalidates the handle. Once buffers exist, `intact()` validates them even when hidden. A missing/changed previously created panel is never recreated as if it were untouched. Revisiting valid panels can recreate only owned windows/tab, preserving visits and immutable buffer checks. Cancel/close retires both unopened and shown handles. No implicit diff visit or focus change occurs when a proposal arrives.

## Rendering and budgets

Use literal buffer text and fixed highlight groups, not executable Markdown, terminal escape interpretation or model-authored statusline expressions. Escape `%` in any dynamic window option. Show user/assistant turn headings, original model labels, current model, scope summary, phase, bounded progress and concise recovery reason. Earlier turn labels never change when desired model changes.

Retain at most one semantic owner, including its closed transcript, and one reusable transcript/composer pair. New replaces closed state rather than accumulating archives. The engine's 64-turn/32 MiB limit remains authoritative. Project only the most recent 2 MiB / 20,000 display lines into the transcript, with a visible older-content omission marker. Projection cannot cut a UTF-8 codepoint. This cap does not silently shorten a submitted prompt or backend context.

Coalesce rendering to at most one pending 30 ms timer and one latest snapshot; no timer queue per token. Hidden views unsubscribe, stop rendering and release queued snapshots. Reopen takes a fresh owner snapshot. Closed views need no live subscription. Dispose clears the timer, autocommands and owned buffers without touching repurposed windows or source buffers.

The composer has the engine's 32 KiB submission limit; oversize input is refused intact. User-entered buffer text is not copied into an additional hidden archive. No chat history is written to disk, health output, ordinary CI diagnostics or Linear. Test transcripts are synthetic. Swap/undo files and modelines are disabled for owned buffers.

## Failure and lifecycle behavior

The owner remains authoritative for admissible actions, current generation and recovery. The UI never converts a display error into a success/cleanup claim. A rendering exception hides or reports a view failure while the controller remains supervised; the explicit close path remains reachable through commands. Pending confirmation callbacks cannot outlive their identities.

Fresh opening or resizing failures clean up only newly created owned windows and preserve the draft and source layout. User-created duplicate views of an owned buffer share its bytes, rather than creating new transcript archives. Wiping an owned buffer invalidates that view; next explicit open recreates a transcript from owner state, and never silently substitutes source buffers. Normal hide/reopen preserves the composer; forced buffer deletion follows Neovim's explicit discard semantics.

On editor exit the existing controller pipe supervision remains authoritative. UI shutdown does not claim cleanup or forcibly discard an unclosed owner. Confirmed close releases execution exclusion; retained historical display is read-only until explicit New.

## Verification and completion

Use headless Neovim against real buffers/windows plus production semantic owners and real controller/fake ACP processes. Cover passive setup/opening, two submissions, no focus theft, draft/cursor preservation, hidden streaming/reopen, cancellation, safe/unsafe retry, close confirmation fencing, scope/settings refusal, narrow/resize and repurposed windows, display budgets, lazy frozen review, dirty hidden aliases, runtime exclusion and relocation.

Capture the actual Neovim TUI at wide and narrow sizes for the PR. Run focused suites while developing, then the complete default runner, Lua formatting and diff checks. Preserve synthetic-provider versus live-account evidence distinctions. Independent whole-branch review, exact-head CI and post-merge CI precede ISQ-234 completion. The milestone remains open for ISQ-235/236/237.
