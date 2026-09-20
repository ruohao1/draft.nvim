-- Explicitly opt-in. Independent of the native (after-write review) companion.
local M = {}
local options, current, dialog
local before_start
local show_file, start
local registered = false
local global_keymaps = true
local policy_revision = 0
local preferences_loaded = false
local module_root = debug.getinfo(1, "S").source:sub(2):match("^(.*)/lua/ai/staged.lua$")
local script = module_root and vim.uv.fs_realpath(module_root .. "/scripts/nvim-ai-staged.py")
local live = { preparing = true, refining = true, review_ready = true, applying = true }

local sources = require("ai.staged_sources")
local shared_review = require("ai.staged_review")
local lines, buffer_text, text_buffer = sources.lines, sources.buffer_text, sources.text_buffer
local source_unchanged, sources_unchanged = sources.source_unchanged, sources.unchanged
local refresh_accepted = sources.refresh_accepted
local close_review, writer, finish = shared_review.close, shared_review.writer, shared_review.finish
local visible_review, frozen_unchanged = shared_review.visible, shared_review.frozen_unchanged
show_file = shared_review.show_file
local function capture(files, root)
  return sources.capture(files, root or (options and options.root))
end
local function preview(state, first)
  state.actions = M
  return shared_review.preview(state, first)
end

local function clear_dialog()
  local previous = dialog
  dialog = nil
  if previous and previous.cancel then
    previous.cancel()
  end
end

local function notify(message, level)
  vim.notify("AI staged: " .. message, level or vim.log.levels.INFO)
end

local function retire(state, reason)
  local verdict = writer(state, "cancel")
  if verdict.phase == "cancelled" then
    verdict.phase, verdict.reason = "conflicted", reason
  end
  finish(state, verdict)
end

local function decide(choice, remaining)
  local state = current
  if not state or state.phase ~= "review_ready" then
    return notify("No pending staged diff to decide")
  end
  local allowed, reason, retire_required = shared_review.can_decide(state, choice, remaining)
  if not allowed then
    if retire_required then
      return retire(state, reason)
    end
    return reason and notify(reason, vim.log.levels.WARN) or nil
  end
  local decided_index = state.index
  local item = state.files[decided_index]
  local prior = {}
  for _, file in ipairs(state.files) do
    prior[file.path] = file.decision
  end
  state.confirmation, state.revision = nil, (state.revision or 0) + 1
  state.phase = "applying"
  -- Only this small local write is synchronous, so editor keystrokes cannot
  -- race the dirty-buffer check. Model execution is always asynchronous.
  local verdict = writer(state, choice, remaining)
  finish(state, verdict)
  if choice == "approve" and (state.phase == "applied" or state.phase == "review_ready") then
    local refreshed = refresh_accepted(state, prior)
    if not refreshed and state.phase == "review_ready" then
      return retire(
        state,
        "Accepted file is published, but a source buffer could not be safely refreshed; reload/save and start a fresh turn"
      )
    elseif not refreshed then
      notify(
        "Accepted files are published; reload their source buffers before editing further",
        vim.log.levels.WARN
      )
    end
  end
  if state.phase == "review_ready" then
    local index = state.index
    if choice == "approve" and not remaining and item.decision == "accepted" then
      for step = 1, #state.files - 1 do
        local candidate = ((decided_index - 1 + step) % #state.files) + 1
        if state.files[candidate].decision == "pending" then
          index = candidate
          break
        end
      end
    end
    if not show_file(state, index) then
      return retire(
        state,
        "Review windows changed; pending files cancelled. Previously accepted files remain published"
      )
    end
  end
end

function M.approve()
  decide("approve", false)
end

function M.reject()
  decide("reject", false)
end

local confirmation_snapshot = shared_review.confirmation_snapshot

local function confirm_remaining(choice)
  local state = current
  if not state or state.phase ~= "review_ready" then
    return notify("No pending staged diff to decide")
  end
  if not visible_review(state) then
    return
  end
  local count = 0
  for _, item in ipairs(state.files) do
    if item.decision == "pending" then
      count = count + 1
      if choice == "approve" and not item.visited then
        return notify(
          "Review every pending changed file with ]f / [f before accepting all",
          vim.log.levels.WARN
        )
      end
    end
  end
  local token, index, revision, tab =
    {}, state.index, state.revision, vim.api.nvim_get_current_tabpage()
  -- Rejecting cannot publish anything, including when a source was already
  -- dirty at dialog open. Guard changes during this dialog, not its old proposal
  -- baseline; accepting additionally revalidates every baseline in decide().
  local snapshot = confirmation_snapshot(state)
  state.confirmation = token
  local label = choice == "approve" and "Accept remaining files" or "Reject remaining files"
  vim.ui.select({ "Cancel", label }, {
    prompt = label .. " (" .. count .. ")? Previously accepted files are not undone.",
  }, function(answer)
    if current ~= state or state.phase ~= "review_ready" or state.confirmation ~= token then
      return
    end
    state.confirmation = nil
    if answer ~= label then
      return
    end
    if
      state.index ~= index
      or state.revision ~= revision
      or vim.api.nvim_get_current_tabpage() ~= tab
      or not vim.deep_equal(confirmation_snapshot(state), snapshot)
    then
      return notify(
        "Confirmation cancelled because the review or source buffers changed",
        vim.log.levels.WARN
      )
    end
    decide(choice, true)
  end)
end

function M.approve_all()
  confirm_remaining("approve")
end

function M.reject_all()
  confirm_remaining("reject")
end

function M.cancel(choice)
  if choice == "reject" then
    return M.reject() -- Legacy callers now reject only the currently reviewed file.
  end
  clear_dialog()
  local state = current
  if not state or not live[state.phase] then
    return
  end
  state.confirmation = nil
  if state.phase == "preparing" or state.phase == "refining" then
    state.cancelled = true
    pcall(function()
      state.job:write(nil)
    end)
    state.reason = "Cancelling; waiting for the isolated agent to stop"
  elseif state.phase == "review_ready" then
    finish(state, writer(state, "cancel"))
  end
end

local function configured()
  options = options or {}
  if not preferences_loaded and (options.enabled == nil or options.review_mode == nil) then
    local saved, why = require("ai.staged_settings").load(options)
    if not saved then
      notify(why .. "; use :NvimAIStageSetup to reconfigure", vim.log.levels.WARN)
      return nil, why
    end
    if options.enabled == nil then
      options = vim.tbl_extend("force", saved, options)
    elseif options.review_mode == nil then
      -- Explicit staging configuration remains session-only: only inherit the
      -- routing preference, never a different model or authentication path.
      options.review_mode = saved.review_mode
    end
    preferences_loaded = true
  end
  if
    options.review_mode ~= nil
    and options.review_mode ~= "native"
    and options.review_mode ~= "pre_write"
  then
    return nil, "Invalid review mode; use :NvimAIReviewMode to choose explicitly"
  end
  return options
end

function M.review_mode()
  local config, why = configured()
  if not config then
    return nil, why or "Review-mode preferences could not be loaded; no prompt sent"
  end
  -- Old records retain their existing native behavior until an explicit choice.
  local mode = config.review_mode == nil and "native" or config.review_mode
  return mode, nil, policy_revision
end

-- Explicit chat opening reuses opt-in preferences without starting a staged turn.
function M.conversation_options()
  local config, why = configured()
  if not config then
    return nil, why
  end
  if config.enabled ~= true or type(config.model) ~= "string" or config.model == "" then
    return nil, "Run :NvimAIStageSetup to enable OpenCode and choose a provider/model first"
  end
  local result = {}
  for _, key in ipairs({ "root", "model", "auth_file", "provider", "python", "opencode", "bwrap" }) do
    result[key] = vim.deepcopy(config[key])
  end
  return result
end

function M.busy()
  return dialog ~= nil or (current ~= nil and live[current.phase] == true)
end

local function ready()
  local config = configured()
  if not config then
    return false
  end
  if config.enabled ~= true or type(config.model) ~= "string" or config.model == "" then
    notify("Run :NvimAIStageSetup to opt in and choose a provider/model first")
    return false
  end
  if before_start then
    local ok, allowed, why = pcall(before_start)
    if not ok or allowed ~= true then
      notify(
        ok and (why or "Native activity prevents staging") or "Native activity could not be checked"
      )
      return false
    end
  end
  return true
end

local function begin_dialog()
  if current and live[current.phase] then
    notify("Finish or cancel the current staged turn first")
    return nil
  end
  clear_dialog()
  local token = {}
  dialog = token
  return function()
    return dialog == token and not (current and live[current.phase])
  end
end

function M.configure_review_mode(requested, context_valid)
  if requested ~= nil and requested ~= "native" and requested ~= "pre_write" then
    return notify("Review mode must be pre_write or native", vim.log.levels.WARN)
  end
  local valid = begin_dialog()
  if not valid then
    return
  end
  local config = configured() or options
  local choices = requested and { "Cancel", requested } or { "Cancel", "pre_write", "native" }
  vim.ui.select(choices, {
    prompt = "NvimAIPrompt mode (native permits writes before review):",
    format_item = function(mode)
      return ({
        pre_write = "Pre-write review (OpenCode staging)",
        native = "Native prompt (after-write review)",
      })[mode] or mode
    end,
  }, function(choice)
    if not valid() then
      return
    end
    dialog = nil
    if context_valid and not context_valid() then
      return notify(
        "Review mode choice cancelled because native activity changed; choose again",
        vim.log.levels.WARN
      )
    end
    if (choice ~= "native" and choice ~= "pre_write") or not vim.tbl_contains(choices, choice) then
      return
    end
    local saved, why = require("ai.staged_settings").save(options, {
      enabled = config.enabled == true,
      model = config.model,
      auth_file = config.auth_file,
      review_mode = choice,
    })
    if not saved then
      return notify(why, vim.log.levels.WARN)
    end
    options.enabled, options.model, options.auth_file, options.review_mode =
      saved.enabled, saved.model, saved.auth_file, saved.review_mode
    policy_revision = policy_revision + 1
    notify(
      choice == "pre_write"
          and "Pre-write mode saved: :NvimAIPrompt uses OpenCode staging; no prompt sent."
        or "Native mode saved: :NvimAIPrompt uses after-write review; no prompt sent."
    )
  end)
end

function M.configure()
  local valid = begin_dialog()
  if not valid then
    return
  end
  local loaded = configured()
  local config = loaded or options
  vim.ui.input(
    { prompt = "Staged OpenCode model (provider/model): ", default = config.model or "" },
    function(model)
      if not valid() then
        return
      end
      if model == nil then
        dialog = nil
        return
      end
      model = vim.trim(model)
      if not model:match("^[%w_.%-]+/[^%s%c]+$") or #model > 512 then
        dialog = nil
        return notify("Use an explicit provider/model, e.g. openai/your-model", vim.log.levels.WARN)
      end
      local auth = config.auth_file
      if not auth then
        local data = vim.env.XDG_DATA_HOME or (vim.env.HOME and vim.env.HOME .. "/.local/share")
        local candidate = data and (data .. "/opencode/auth.json")
        if candidate and vim.uv.fs_lstat(candidate) then
          auth = candidate -- Suggest a path only; never open credentials here.
        end
      end
      vim.ui.input({
        prompt = "OpenCode auth-file path (blank = none): ",
        default = auth or "",
        completion = "file",
      }, function(path)
        if not valid() then
          return
        end
        if path == nil then
          dialog = nil
          return
        end
        if path:sub(1, 2) == "~/" and vim.env.HOME then
          path = vim.env.HOME .. path:sub(2)
        end
        local next_config = {
          enabled = true,
          model = model,
          auth_file = path ~= "" and path or nil,
          review_mode = config.review_mode or (not loaded and "pre_write" or nil),
        }
        vim.ui.select({ "Cancel", "Save and enable" }, {
          prompt = "Save model/auth path only? Each staged prompt sends only explicitly selected saved files to "
            .. model
            .. ".",
        }, function(choice)
          if not valid() then
            return
          end
          dialog = nil
          if choice ~= "Save and enable" then
            return
          end
          local saved, why = require("ai.staged_settings").save(options, next_config)
          if not saved then
            return notify(why, vim.log.levels.WARN)
          end
          options.enabled, options.model, options.auth_file, options.review_mode =
            saved.enabled, saved.model, saved.auth_file, saved.review_mode
          policy_revision = policy_revision + 1
          notify("Settings saved; no prompt sent. Use :NvimAIStage for pre-write review.")
        end)
      end)
    end
  )
end

function M.reset()
  local valid = begin_dialog()
  if not valid then
    return
  end
  local config = configured()
  vim.ui.select({ "Cancel", "Forget and disable" }, {
    prompt = "Forget saved staging preferences? Your OpenCode auth file will not be changed.",
  }, function(choice)
    if not valid() then
      return
    end
    dialog = nil
    if choice ~= "Forget and disable" then
      return
    end
    local saved, why = require("ai.staged_settings").save(options or {}, {
      enabled = false,
      -- Disabling staging must never implicitly re-enable native writes.
      review_mode = config and config.review_mode or (not config and "pre_write" or nil),
    })
    if not saved then
      return notify(why, vim.log.levels.WARN)
    end
    options = options or {}
    options.enabled, options.model, options.auth_file, options.review_mode =
      false, nil, nil, saved.review_mode
    policy_revision = policy_revision + 1
    notify(
      "Staging disabled; model/auth path forgotten. Prompt routing is not switched to native; auth file unchanged."
    )
  end)
end

local function prompt_files(files, root)
  local valid = begin_dialog()
  if not valid then
    return
  end
  if not ready() then
    dialog = nil
    return
  end
  local state, why = capture(files, root)
  if not state then
    dialog = nil
    return notify(why, vim.log.levels.WARN)
  end
  local buf = vim.api.nvim_get_current_buf()
  local total = 0
  for _, item in ipairs(state.files) do
    total = total + #item.oldText
  end
  vim.ui.input({
    prompt = "Stage edit ("
      .. #state.files
      .. " file(s), "
      .. total
      .. " B, review before write): ",
  }, function(prompt)
    if not valid() then
      return
    end
    dialog = nil
    if prompt == nil or prompt:match("^%s*$") then
      return
    end
    if (not files and vim.api.nvim_get_current_buf() ~= buf) or not sources_unchanged(state) then
      return notify(
        "Source buffer changed while entering the prompt; try again",
        vim.log.levels.WARN
      )
    end
    -- Keep the exact selection captured before the asynchronous input dialog.
    -- start() recaptures only after every prior source snapshot was checked.
    start(prompt, files and vim.tbl_map(function(item)
      return item.file
    end, state.files) or nil, state.root)
  end)
end

function M.prompt(files)
  prompt_files(files)
end

function M.pick_files()
  local valid = begin_dialog()
  if not valid then
    return
  end
  if not ready() then
    dialog = nil
    return
  end
  -- Discovery stays inside the chosen directory; do not widen a listing to an
  -- ancestor merely because it contains a .git marker.
  local root = options.root or vim.fn.getcwd()
  root = vim.uv.fs_realpath(root)
  local token = dialog
  local cancel_picker = require("ai.staged_picker").open(root, function(files)
    if not valid() then
      return
    end
    dialog = nil
    if files then
      prompt_files(files, root)
    end
  end)
  if valid() then
    token.cancel = cancel_picker
  else
    cancel_picker()
  end
end

function M.status()
  local config, why = configured()
  config = config or {}
  local settings = {
    enabled = config.enabled == true,
    model = config.model,
    auth_file = config.auth_file,
    review_mode = why and "unavailable"
      or (config.review_mode == nil and "native" or config.review_mode),
    error = why,
  }
  if not current then
    return { phase = "idle", settings = settings }
  end
  return {
    phase = current.phase,
    reason = current.reason,
    file = current.file,
    proposal = current.proposal,
    review_tab = current.tab,
    previous_proposals = vim.deepcopy(current.previous_proposals or {}),
    replacement_proposal = current.replacement_proposal,
    current_file = current.index,
    files = vim.tbl_map(function(item)
      return {
        path = item.path,
        changed = item.changed,
        reviewed = item.visited == true,
        state = item.decision,
        retained_decision = item.retained_decision,
      }
    end, current.files),
    results = current.results and vim.deepcopy(current.results),
    settings = settings,
  }
end

function M.review(step)
  local state = current
  if not state or state.phase ~= "review_ready" then
    return notify("No pending staged diff to review")
  end
  local function jump(index)
    if current ~= state or state.phase ~= "review_ready" then
      return
    end
    if not show_file(state, index) then
      notify("Both original review windows must remain available", vim.log.levels.WARN)
    end
  end
  if type(step) == "number" then
    return jump(((state.index - 1 + step) % #state.files) + 1)
  end
  vim.ui.select(state.files, {
    prompt = "Staged files — a/r current file; A/R remaining files:",
    format_item = function(item)
      return string.format(
        "[%s] %s",
        item.decision .. (item.decision == "pending" and not item.visited and ", UNREVIEWED" or ""),
        item.path
      )
    end,
  }, function(_, index)
    if index then
      jump(index)
    end
  end)
end

local function review_intact(state)
  if not vim.api.nvim_tabpage_is_valid(state.tab) then
    return false
  end
  for _, win in ipairs(state.windows) do
    if not vim.api.nvim_win_is_valid(win) or not state.panels[vim.api.nvim_win_get_buf(win)] then
      return false
    end
  end
  return true
end

function M.followup(instruction)
  local state = current
  if not state or state.phase ~= "review_ready" then
    return notify("Open a pending staged review before requesting a follow-up")
  end
  if not ready() then
    return
  end
  if not visible_review(state) then
    return
  end
  local pending, wire = 0, {}
  for _, item in ipairs(state.files) do
    wire[#wire + 1] = item.retained_decision and "unchanged" or item.decision
    if item.decision == "pending" then
      pending = pending + 1
    end
  end
  if pending == 0 then
    return notify("No pending files to revise")
  end
  local token, index, revision, snapshot =
    {}, state.index, state.revision, confirmation_snapshot(state)
  state.confirmation = token
  local function submit(answer)
    if current ~= state or state.phase ~= "review_ready" or state.confirmation ~= token then
      return
    end
    state.confirmation = nil
    if answer == nil or answer:match("^%s*$") then
      return
    end
    if not ready() then
      return
    end
    if
      state.index ~= index
      or state.revision ~= revision
      or not visible_review(state)
      or not vim.deep_equal(confirmation_snapshot(state), snapshot)
    then
      return notify(
        "Follow-up cancelled because the review or source buffers changed",
        vim.log.levels.WARN
      )
    end
    if not sources_unchanged(state) or not frozen_unchanged(state) then
      return retire(state, "Source or frozen review changed; start a fresh turn")
    end
    local instructions = vim.deepcopy(state.instructions)
    if not instructions or not state.launch then
      return notify("Start a fresh staged turn before using follow-ups")
    end
    instructions[#instructions + 1] = answer
    local text = "Revise the frozen, unapproved proposal in these isolated files. The editor will review the result against the saved project originals.\n\nOriginal instruction:\n"
      .. instructions[1]
    for number = 2, #instructions do
      text = text .. "\n\nFollow-up " .. (number - 1) .. ":\n" .. instructions[number]
    end
    if #text > 32768 then
      return notify(
        "Follow-up instruction history exceeds 32 KiB; shorten it or start a fresh turn",
        vim.log.levels.WARN
      )
    end
    for _, tool in ipairs({ state.python, state.launch.bwrap, state.launch.opencode }) do
      local valid, why = require("ai.tools").revalidate(tool)
      if not valid then
        return notify(why, vim.log.levels.WARN)
      end
    end
    local request = vim.deepcopy(state.launch)
    request.prompt, request.decisions = text, wire
    state.phase, state.revision = "refining", state.revision + 1
    state.reason = "Revising "
      .. pending
      .. " pending proposal(s); a/r disabled until frozen. q cancels pending work."
    for _, win in ipairs(state.windows) do
      vim.wo[win].statusline = state.reason
    end
    notify(state.reason)

    local function completed(result)
      vim.schedule(function()
        local decoded, value = pcall(vim.json.decode, result.stdout or "")
        if result.code ~= 0 or not decoded or type(value) ~= "table" then
          return finish(state, {
            phase = "blocked",
            reason = "Follow-up outcome unknown; inspect retained proposal receipts. No automatic retry.",
          })
        end
        local intact = sources_unchanged(state) and frozen_unchanged(state) and review_intact(state)
        if value.phase ~= "review_ready" then
          if value.parent_active == true then
            if state.cancelled then
              return finish(state, writer(state, "cancel"))
            end
            if not intact then
              return retire(
                state,
                "Source or review changed during follow-up; pending work cancelled"
              )
            end
            state.phase, state.reason =
              "review_ready",
              "Follow-up failed: "
                .. (value.reason or "no revised proposal")
                .. ". Previous proposal remains pending."
            show_file(state, state.index)
            return notify(state.reason, vim.log.levels.WARN)
          end
          return finish(state, {
            phase = "blocked",
            reason = value.reason
              or "Follow-up handoff could not be confirmed; inspect retained receipts",
          })
        end
        local candidate_identity = type(value.proposal) == "string"
          and value.proposal:match("^/tmp/nvim%-ai%-staged%-[^/]+/proposal%.json$")
          and value.proposal ~= state.proposal
          and type(value.id) == "string"
          and #value.id == 32
          and value.id:match("^[a-f0-9]+$")
          and value.id ~= state.id
        local matching = candidate_identity
          and value.parent_active == false
          and value.previous_proposal == state.proposal
          and vim.deep_equal(value.prior_decisions, wire)
          and type(value.proposal) == "string"
          and value.proposal ~= state.proposal
          and type(value.id) == "string"
          and value.id ~= state.id
          and type(value.files) == "table"
          and vim.islist(value.files)
          and #value.files == #state.files
        local next_state = {
          files = {},
          multi = true,
          root = state.root,
          python = state.python,
          proposal = value.proposal,
          id = value.id,
          file = state.file,
          launch = state.launch,
          instructions = instructions,
          previous_proposals = vim.deepcopy(state.previous_proposals or {}),
        }
        local first, next_pending
        next_pending = 0
        for position, item in ipairs(state.files) do
          local proposed = matching and value.files[position] or nil
          local before = item.sourceText or item.oldText
          if
            type(proposed) ~= "table"
            or proposed.path ~= item.path
            or proposed.oldText ~= before
            or type(proposed.newText) ~= "string"
            or (item.decision ~= "pending" and proposed.newText ~= before)
          then
            matching = false
          else
            local decision = item.decision ~= "pending" and item.decision
              or (proposed.newText ~= before and "pending" or "unchanged")
            next_state.files[#next_state.files + 1] = {
              source = item.source,
              file = item.file,
              path = item.path,
              tick = item.tick,
              oldText = before,
              newText = proposed.newText,
              changed = proposed.newText ~= before,
              decision = decision,
              retained_decision = item.decision ~= "pending" and item.decision or nil,
            }
            if decision == "pending" then
              first, next_pending = first or position, next_pending + 1
            end
          end
        end
        if not matching then
          -- A malformed success is not permission to revive the retired token.
          state.replacement_proposal = candidate_identity and value.proposal or nil
          return finish(state, {
            phase = "blocked",
            reason = "Follow-up returned an invalid replacement; inspect retained proposal receipts",
          })
        end
        if state.cancelled or not intact then
          writer(next_state, "cancel")
          local cancelled = state.cancelled == true
          local decisions = {}
          for position, item in ipairs(state.files) do
            decisions[position] = {
              path = item.path,
              state = item.retained_decision and "unchanged"
                or (
                  item.decision == "pending" and (cancelled and "cancelled" or "blocked")
                  or item.decision
                ),
            }
          end
          return finish(state, {
            phase = cancelled and "cancelled" or "conflicted",
            decisions = decisions,
            reason = "Follow-up discarded because it was cancelled or the source/review changed; earlier accepted writes are retained",
          })
        end
        next_state.previous_proposals[#next_state.previous_proposals + 1] = state.proposal
        state.phase = "superseded"
        close_review(state)
        current = next_state
        if next_pending == 0 then
          local decisions = vim.tbl_map(function(item)
            return { path = item.path, state = "unchanged" }
          end, next_state.files)
          return finish(next_state, {
            phase = "unchanged",
            decisions = decisions,
            reason = "Follow-up removed all pending changes; earlier accepted writes remain published",
          })
        end
        local shown, why = pcall(preview, next_state, first)
        if not shown then
          writer(next_state, "cancel")
          return finish(next_state, {
            phase = "blocked",
            reason = "Could not show revised diff; proposal discarded: " .. tostring(why),
          })
        end
        next_state.reason = value.reason
        notify(value.reason)
      end)
    end
    local ran, job = pcall(
      vim.system,
      { state.python, "-I", "-B", script, "refine", "--proposal", state.proposal, "--id", state.id },
      {
        stdin = true,
        text = true,
        clear_env = true,
        env = { PATH = "/usr/bin:/bin", LANG = "C.UTF-8" },
      },
      completed
    )
    if not ran then
      return completed({
        code = 0,
        stdout = vim.json.encode({
          phase = "blocked",
          parent_active = true,
          reason = "Could not start follow-up controller",
        }),
      })
    end
    state.job = job
    local wrote = pcall(job.write, job, vim.json.encode(request) .. "\n")
    if not wrote then
      pcall(job.write, job, nil)
    end
  end
  if instruction ~= nil then
    submit(instruction)
  else
    vim.ui.input(
      { prompt = "Follow-up (" .. pending .. " pending files; decided files excluded): " },
      submit
    )
  end
end

start = function(prompt, files, root)
  if not ready() then
    return
  end
  if current and live[current.phase] then
    return notify("Finish or cancel the current staged turn first")
  end
  if vim.uv.os_uname().sysname ~= "Linux" then
    return notify("This opt-in path currently supports Linux only")
  end
  if type(prompt) ~= "string" or prompt:match("^%s*$") then
    return notify("Use :NvimAIStage <instruction>")
  end
  local valid = begin_dialog()
  if not valid then
    return
  end
  local state, why = capture(files, root)
  if not valid() then
    return -- A read hook cancelled or replaced this exact staged request.
  end
  local function refuse(message, level)
    clear_dialog()
    return notify(message, level)
  end
  if not state then
    return refuse(why, vim.log.levels.WARN)
  end
  if not ready() then
    clear_dialog()
    return
  end
  local tools, resolved = require("ai.tools"), {}
  for _, name in ipairs({ "python", "bwrap", "opencode" }) do
    local path, err = tools.resolve(options[name] or (name == "python" and "python3" or name))
    if not path then
      return refuse(err, vim.log.levels.ERROR)
    end
    local valid, why = tools.revalidate(path)
    if not valid then
      return refuse(why, vim.log.levels.ERROR)
    end
    resolved[name] = path
  end
  if not script or not vim.uv.fs_stat(script) then
    return refuse("Staged controller is missing from this runtime")
  end
  if not sources_unchanged(state) then
    return refuse("A selected buffer changed before staging could start", vim.log.levels.WARN)
  end
  state.phase, state.python = "preparing", resolved.python
  state.reason = "Agent editing isolated copies of "
    .. #state.files
    .. " selected file(s); project unchanged"
  local request = {
    root = state.root,
    prompt = prompt,
    model = options.model,
    provider = options.provider,
    auth_file = options.auth_file,
    bwrap = resolved.bwrap,
    opencode = resolved.opencode,
  }
  state.launch, state.instructions = vim.deepcopy(request), { prompt }
  if state.multi then
    request.files = vim.tbl_map(function(item)
      return { path = item.path, snapshot_sha256 = vim.fn.sha256(item.oldText) }
    end, state.files)
  else
    request.path, request.snapshot_sha256 =
      state.files[1].path, vim.fn.sha256(state.files[1].oldText)
  end
  current = state
  clear_dialog()
  state.job = vim.system({ state.python, "-I", "-B", script, "prepare" }, {
    stdin = true,
    text = true,
    clear_env = true,
    env = { PATH = "/usr/bin:/bin", LANG = "C.UTF-8" },
  }, function(result)
    vim.schedule(function()
      local ok, value = pcall(vim.json.decode, result.stdout or "")
      if result.code ~= 0 or not ok or type(value) ~= "table" or type(value.phase) ~= "string" then
        return finish(state, {
          phase = "blocked",
          reason = "Staging stopped without a proposal; project not published",
        })
      end
      if value.phase ~= "review_ready" then
        return finish(state, value)
      end
      if type(value.proposal) ~= "string" or type(value.id) ~= "string" then
        return finish(state, {
          phase = "blocked",
          reason = "Staging returned no valid proposal identity; project not published",
        })
      end
      state.proposal, state.id = value.proposal, value.id
      local proposed = value.files or { value }
      local matching = type(proposed) == "table"
        and vim.islist(proposed)
        and #proposed == #state.files
      for index, item in ipairs(state.files) do
        local candidate = matching and proposed[index] or nil
        if
          type(candidate) ~= "table"
          or candidate.path ~= item.path
          or candidate.oldText ~= item.oldText
          or type(candidate.newText) ~= "string"
        then
          matching = false
        else
          item.newText, item.changed = candidate.newText, candidate.newText ~= item.oldText
          item.decision = item.changed and "pending" or "unchanged"
        end
      end
      if state.cancelled or not sources_unchanged(state) or not matching then
        writer(state, "cancel")
        return finish(
          state,
          { phase = "cancelled", reason = "Turn cancelled or source changed; proposal discarded" }
        )
      end
      state.reason = value.reason
      local shown, err = pcall(preview, state)
      if not shown then
        writer(state, "cancel")
        finish(state, {
          phase = "blocked",
          reason = "Could not show diff; proposal discarded: " .. tostring(err),
        })
      end
    end)
  end)
  state.job:write(vim.json.encode(request) .. "\n")
  notify(state.reason)
end

function M.start(prompt, files)
  start(prompt, files)
end

local function setup_keymaps()
  if not global_keymaps then
    return
  end
  vim.keymap.set(
    "n",
    "<leader>ae",
    M.prompt,
    { silent = true, desc = "AI: staged edit (review before write)" }
  )
  vim.keymap.set(
    "n",
    "<leader>ac",
    M.configure,
    { silent = true, desc = "AI: configure staged edits" }
  )
  vim.keymap.set(
    "n",
    "<leader>af",
    M.pick_files,
    { silent = true, desc = "AI: pick files for staged review" }
  )
end

function M.setup(config, guard, keymaps)
  if keymaps ~= nil then
    global_keymaps = keymaps
  end
  if guard ~= nil then
    assert(type(guard) == "function", "Staging lifecycle guard must be a function")
    before_start = guard
  end
  -- The native runtime owns this guard independently of user preferences;
  -- advanced/session-only setup must not disconnect it.
  if config == nil and registered then
    setup_keymaps()
    return M
  end
  if current and live[current.phase] then
    error("Cancel the staged turn before reconfiguring")
  end
  options = vim.deepcopy(config or {})
  preferences_loaded = false
  policy_revision = policy_revision + 1
  clear_dialog()
  registered = true
  for _, name in ipairs({
    "NvimAIStage",
    "NvimAIStageFiles",
    "NvimAIStageFollowup",
    "NvimAIStageReview",
    "NvimAIStageApprove",
    "NvimAIStageReject",
    "NvimAIStageApproveAll",
    "NvimAIStageRejectAll",
    "NvimAIStageCancel",
    "NvimAIStageStatus",
    "NvimAIStageSetup",
    "NvimAIStageReset",
  }) do
    pcall(vim.api.nvim_del_user_command, name)
  end
  local group = vim.api.nvim_create_augroup("NvimAIStaged", { clear = true })
  vim.api.nvim_create_user_command("NvimAIStage", function(args)
    if args.args == "" then
      M.prompt()
    else
      M.start(args.args)
    end
  end, { nargs = "*", desc = "AI: staged edit (review before write)" })
  vim.api.nvim_create_user_command("NvimAIStageFiles", function(args)
    if #args.fargs == 0 then
      M.pick_files()
    else
      M.prompt(args.fargs)
    end
  end, {
    nargs = "*",
    complete = "file",
    desc = "AI: pick or name files for staged review",
  })
  vim.api.nvim_create_user_command("NvimAIStageReview", function()
    M.review()
  end, { desc = "AI: select a file in the staged review" })
  vim.api.nvim_create_user_command("NvimAIStageFollowup", function(args)
    M.followup(args.args ~= "" and args.args or nil)
  end, { nargs = "*", desc = "AI: revise pending staged proposals before approval" })
  vim.api.nvim_create_user_command(
    "NvimAIStageSetup",
    M.configure,
    { desc = "AI: configure staged edits" }
  )
  vim.api.nvim_create_user_command(
    "NvimAIStageReset",
    M.reset,
    { desc = "AI: forget staging preferences and disable" }
  )
  vim.api.nvim_create_user_command("NvimAIStageApprove", M.approve, {})
  vim.api.nvim_create_user_command("NvimAIStageReject", M.reject, {})
  vim.api.nvim_create_user_command("NvimAIStageApproveAll", M.approve_all, {})
  vim.api.nvim_create_user_command("NvimAIStageRejectAll", M.reject_all, {})
  vim.api.nvim_create_user_command("NvimAIStageCancel", M.cancel, {})
  vim.api.nvim_create_user_command("NvimAIStageStatus", function()
    vim.print(M.status())
  end, {})
  setup_keymaps()
  vim.api.nvim_create_autocmd({ "TabClosed", "BufWipeout" }, {
    group = group,
    callback = function()
      vim.schedule(function()
        if
          current
          and (current.phase == "review_ready" or current.phase == "refining")
          and (
            not vim.api.nvim_tabpage_is_valid(current.tab)
            or vim.iter(vim.tbl_keys(current.panels)):any(function(buf)
              return not vim.api.nvim_buf_is_valid(buf)
            end)
          )
        then
          M.cancel()
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      M.cancel()
      if current and (current.phase == "preparing" or current.phase == "refining") then
        current.job:wait(4000)
      end
    end,
  })
  return M
end

return M
