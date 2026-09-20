# Conversational Model Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose passive, conversation-local model selection for the next eligible turn.

**Architecture:** The chat controller presents negotiated choices and dispatches
the existing `choose-model` action through its dialog fence. The semantic owner
and confined ACP controller retain their existing lifecycle and resume contract.

**Tech Stack:** Neovim Lua, Python standard library, scripted ACP and disposable tmux.

**Spec:** `docs/superpowers/specs/2026-09-20-conversation-model-design.md`

## Global Constraints

- Linux; Neovim 0.12+ and LuaJIT; Python standard library; pinned OpenCode 1.18.30.
- Keep two-space Lua indentation, double quotes and 100-column formatting.
- No real provider request, user credential, live editor, personal config or user tmux server is used.
- Run confined fixtures outside the tool sandbox; do not weaken Bubblewrap, helper trust checks or cleanup proof.

## Review Focus

- A dialog outliving a draft edit, turn, hide/reopen, tab departure or owner replacement cannot select a model; cover in the headless chat test.
- A capability catalog losing a formerly advertised model cannot retain it as an eligible choice or submit with fallback; cover owner and ACP fixtures.
- A changed preference cannot rewrite old model labels or pending/retired proposal authority; cover history and refused pending-review selection.
- Choosing, cancelling or reopening a picker cannot start a worker, send a draft or change saved defaults; cover real runtime and New/reset tests.
- Missing authentication and failed model confirmation on resumed sessions cannot submit or silently replace the session; cover production controller fixtures.

---

### Task 1: Expose and verify next-turn model selection

**Files:**
- Modify: `lua/ai/chat.lua`, `lua/ai/chat_view.lua`, `lua/ai/init.lua`
- Create: `tests/ai_chat_model.lua`
- Modify: `tests/ai_chat_controller.lua`, `tests/nvim_ai_conversation_controller.py`, `tests/fixtures/ai/conversation_acp.py`
- Modify: `tests/nvim_ai_chat_ui.py`, `tests/fixtures/ai/chat_ui.lua`
- Modify: `README.md`, `doc/draft.txt`, `tests/README.md`
- Create: `docs/validation/2026-09-20-conversation-model.md`, `docs/images/conversation-model.png`

**Interfaces:**
- Consumes: owner `snapshot()` (`phase`, `confirmed_model`, `desired_model`, `available_models`, `view_revision`) and `dispatch({kind="choose-model", model=id}, revision)`; chat's existing dialog fence; ACP `configOptions` and `session/set_config_option`.
- Produces: `chat:model()` / runtime `chat_model()` / `:NvimAIChatModel`, normal-mode `gm`, and idle action-menu choice. Returns success for an opened picker or nil/reason for a refusal; no transport effect from choosing.

- [x] **Step 1: Write the failing public behavior tests.** In a new headless suite, use a real owner with a recording transport and real chat buffers. Assert a missing model method is a named assertion failure. Advertise `fixture/model` and `fixture/second-model` on the first submitted event, settle, then choose the second model:

  ```lua
  assert(type(chat.model) == "function", "chat exposes model selection")
  assert(chat:model())
  pending[#pending].callback("fixture/second-model")
  assert(owner:snapshot().desired_model == "fixture/second-model")
  assert(#driver.requests == 1 and draft() == "keep this draft")
  assert(owner:snapshot().turns[1].model == "fixture/model")
  ```

  Cover refusal before negotiation and while starting/generating/review/failed/closed; cancelled and forged choices; changed draft, superseding dialog, hide/reopen, tab departure/return, stale turn and owner callbacks. On a later submitted catalog containing only the second model, refuse the removed first model. Assert New returns to the unchanged configured default. Add real-command coverage to `ai_chat_controller.lua` proving passive selection between two sends, original labels, confirmed option values and one resumed session.

- [x] **Step 2: Observe RED.** Run `python3 -I -B tests/run.py ai_chat_model ai_chat_controller` outside the sandbox. Expected: new named assertion and absent public command fail; retain logs. Existing controller fixtures are not changed to create a failure.

- [x] **Step 3: Implement the smallest public interface.** Add `chat:model()` with idle and confirmed-catalog admission. Copy available IDs, create a fence, then invoke `vim.ui.select` with current-item formatting and a conversation-only prompt. On a non-nil selection, reject stale fences or unknown IDs before dispatch:

  ```lua
  if not valid() then
    return refusal("Model choice expired; reopen the picker")
  end
  if not vim.list_contains(choices, chosen) then
    return refusal("Choose an advertised model")
  end
  return dispatch({ kind = "choose-model", model = chosen })
  ```

  Wire the command and runtime method in `ai.init`; add `gm` and `next:` labels in the view; add the idle action entry. Keep history and settings untouched.

- [x] **Step 4: Verify GREEN and the existing protocol contract.** Extend the Python fixture with resumed-catalog removal and model-confirmation refusal cases. Parameterize the test send helper's model and assert an explicit second turn confirms `fixture/second-model` in the same session. For capability loss, wrong confirmation and missing copied auth, assert one initial prompt, no second prompt, no replacement `session/new`, failed outcome and unchanged source. These are regression tests for existing behavior and may pass on first run; change production protocol only if evidence requires it.

  ```python
  self.send("start", model="fixture/second-model")
  self.assertEqual(self.receive("settled")["outcome"], "failed")
  methods = [item.get("method") for item in self.audit]
  self.assertEqual(methods.count("session/prompt"), 1)
  self.assertEqual(methods.count("session/new"), 1)
  ```

  Run `python3 -I -B tests/run.py ai_chat_model ai_chat_controller nvim_ai_conversation_controller ai_chat ai_chat_view ai_conversation ai_conversation_review ai_conversation_followup`. Expected: all eight suites pass.

- [x] **Step 5: Exercise real keys and document the contract.** In the existing disposable TUI harness, advertise two models, press `gm`, cancel once, choose the second item, retain unsent text, hide/reopen, then explicitly send and verify two distinct turn labels. Capture the picker and selected state; render with the existing capture script and visually inspect. Update README/help with eligibility, initial discovery, same-session revalidation, recovery behavior, `gm`, saved-default boundaries and fixture-only evidence.

- [x] **Step 6: Verify and commit.** Run `stylua --check lua tests`, `git diff --check`, and `python3 -I -B tests/run.py` outside the sandbox via `task-done`. Expected: formatting clean and all provider-free suites pass. Commit `feat: select the next conversational model` and update the ledger commit range without repeating unchanged tests.

Delivery after Task 1: request one fresh whole-branch review. Publish the reviewed branch, require exact-head CI, merge, verify main CI and update ISQ-236/milestone. Record these gates in the issue, PR and execution ledger.
