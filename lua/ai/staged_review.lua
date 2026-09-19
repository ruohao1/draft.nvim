-- Shared frozen-review guards and the existing synchronous local publisher.
local M = {}
local sources = require("ai.staged_sources")
local lines, source_unchanged = sources.lines, sources.source_unchanged
local sources_unchanged, refresh_accepted = sources.unchanged, sources.refresh_accepted
local show_file
local module_root = debug.getinfo(1, "S").source:sub(2):match("^(.*)/lua/ai/staged_review.lua$")
local script = module_root and vim.uv.fs_realpath(module_root .. "/scripts/nvim-ai-staged.py")
local function notify(message, level)
  vim.notify("AI staged: " .. message, level or vim.log.levels.INFO)
end

local function close_review(state)
  local tab = state.tab
  if not tab then
    return
  end
  local panels = state.panels or {}
  if vim.api.nvim_tabpage_is_valid(tab) then
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if not panels[buf] then
        return
      end
    end
    -- Never force-close a tab that the user has repurposed.
    pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(tab))
  end
  if not vim.api.nvim_tabpage_is_valid(tab) then
    for buf in pairs(panels) do
      if
        vim.api.nvim_buf_is_valid(buf)
        and not vim.bo[buf].modified
        and #vim.fn.win_findbuf(buf) == 0
      then
        pcall(vim.api.nvim_buf_delete, buf, {})
      end
    end
  end
end

local function writer(state, choice, remaining)
  state.attempted = {}
  if choice == "approve" then
    for index, item in ipairs(state.files) do
      if item.decision == "pending" and (remaining or index == state.index) then
        state.attempted[item.path] = true
      end
    end
  end
  local valid, why = require("ai.tools").revalidate(state.python)
  if not valid then
    return { phase = "blocked", reason = why }
  end
  local command =
    { state.python, "-I", "-B", script, choice, "--proposal", state.proposal, "--id", state.id }
  if state.multi and choice ~= "cancel" then
    vim.list_extend(
      command,
      remaining and { "--remaining" } or { "--path", state.files[state.index].path }
    )
  end
  local ran, result = pcall(function()
    return vim
      .system(command, {
        text = true,
        clear_env = true,
        env = { PATH = "/usr/bin:/bin", LANG = "C.UTF-8" },
      })
      :wait(5000)
  end)
  if not ran or type(result) ~= "table" then
    return {
      phase = "uncertain",
      reason = "Writer stopped without a decision; inspect disk before retrying",
    }
  end
  local ok, verdict = pcall(vim.json.decode, result.stdout or "")
  local phases = {
    review_ready = true,
    applied = true,
    rejected = true,
    cancelled = true,
    blocked = true,
    conflicted = true,
    partial = true,
    uncertain = true,
    already_decided = true,
  }
  if result.code ~= 0 or not ok or type(verdict) ~= "table" or not phases[verdict.phase] then
    return {
      phase = "uncertain",
      reason = "Writer did not return a decision; inspect disk before retrying",
    }
  end
  return verdict
end

local function finish(state, verdict)
  state.confirmation = nil
  state.phase, state.reason = verdict.phase, verdict.reason
  local decisions = vim.deepcopy(verdict.decisions)
  local valid = type(decisions) == "table" and vim.islist(decisions) and #decisions == #state.files
  local allowed = {
    pending = true,
    accepted = true,
    rejected = true,
    unchanged = true,
    cancelled = true,
    blocked = true,
    uncertain = true,
  }
  local pending, already_decided = 0, false
  for index, item in ipairs(state.files) do
    if item.decision == "accepted" or item.decision == "rejected" then
      already_decided = true
    end
    local decision = valid and decisions[index] or nil
    if item.retained_decision and type(decision) == "table" then
      -- A decided file is immutable context in the new manifest. Its wire
      -- outcome must remain unchanged; retain its earlier UI decision/history.
      if decision.state == "unchanged" then
        decision.state = item.retained_decision
      else
        valid = false
      end
    end
    if
      type(decision) ~= "table"
      or decision.path ~= item.path
      or not allowed[decision.state]
      or (item.decision and item.decision ~= "pending" and decision.state ~= item.decision)
    then
      valid = false
    elseif decision.state == "pending" then
      pending = pending + 1
    end
  end
  if
    (verdict.phase == "review_ready" and pending == 0)
    or (verdict.phase ~= "review_ready" and pending > 0)
  then
    valid = false
  end
  if
    not valid
    and (
      verdict.phase == "review_ready"
      or (
        state.multi
        and state.tab
        and (
          verdict.phase == "applied"
          or verdict.phase == "rejected"
          or (verdict.phase == "cancelled" and already_decided)
        )
      )
    )
  then
    state.phase, state.reason =
      "uncertain", "Writer returned invalid file decisions; inspect disk before further staging"
  end
  if valid then
    for index, item in ipairs(state.files) do
      item.decision = decisions[index].state
    end
    if state.phase == "rejected" then
      for _, item in ipairs(state.files) do
        if item.decision == "accepted" then
          state.phase = "applied" -- Cumulative outcome includes earlier revisions.
          break
        end
      end
    end
  else
    for _, item in ipairs(state.files) do
      if item.decision == "pending" then
        if not state.multi and verdict.phase == "applied" then
          item.decision = "accepted"
        elseif not state.multi and verdict.phase == "rejected" then
          item.decision = "rejected"
        else
          item.decision = state.phase == "cancelled" and "cancelled"
            or (
              (state.phase == "uncertain" or state.phase == "partial")
                and state.attempted
                and state.attempted[item.path]
                and "uncertain"
              or "blocked"
            )
        end
      end
    end
  end
  -- A missing/malformed subsequent reply cannot erase already-confirmed writes.
  -- Derive cumulative outcomes from the monotonic per-file decision record.
  local prior = state.results or {}
  local cleanup = {}
  for _, list in ipairs({ prior.cleanup_pending or {}, verdict.cleanup_pending or {} }) do
    if type(list) == "table" and vim.islist(list) then
      for _, path in ipairs(list) do
        if type(path) == "string" then
          cleanup[path] = true
        end
      end
    end
  end
  state.results = {
    applied = {},
    rejected = {},
    pending = {},
    uncertain = {},
    not_attempted = {},
    unchanged = {},
    cleanup_pending = {},
  }
  local result_names = {
    accepted = "applied",
    rejected = "rejected",
    pending = "pending",
    uncertain = "uncertain",
    unchanged = "unchanged",
  }
  for _, item in ipairs(state.files) do
    local key = result_names[item.decision]
    if key then
      table.insert(state.results[key], item.path)
    end
    if item.decision == "pending" or item.decision == "blocked" then
      table.insert(state.results.not_attempted, item.path)
    end
    if cleanup[item.path] then
      table.insert(state.results.cleanup_pending, item.path)
    end
  end
  if state.phase ~= "review_ready" then
    close_review(state)
  end
  if state.phase == "partial" or state.phase == "uncertain" then
    state.reason = (state.reason or state.phase)
      .. "; inspect the selected files on disk before any further staging. No automatic retry or rollback. Retained proposal: "
      .. (state.proposal or "unavailable")
  end
  if next(state.results.cleanup_pending) ~= nil then
    state.reason = (state.reason or verdict.phase)
      .. "; prepared temporary files may remain. Inspect retained cleanup evidence beside: "
      .. (state.proposal or "unavailable")
  end
  notify(
    state.reason or state.phase,
    (state.phase == "applied" or state.phase == "review_ready") and vim.log.levels.INFO
      or vim.log.levels.WARN
  )
end

local function visible_review(state)
  if
    not state.tab
    or not vim.api.nvim_tabpage_is_valid(state.tab)
    or vim.api.nvim_get_current_tabpage() ~= state.tab
  then
    notify("Open the staged diff tab before deciding", vim.log.levels.WARN)
    return false
  end
  local visible = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(state.tab)) do
    if vim.wo[win].diff then
      visible[vim.api.nvim_win_get_buf(win)] = true
    end
  end
  if not visible[state.left] or not visible[state.right] then
    notify("Both frozen diff panels must be visible before deciding", vim.log.levels.WARN)
    return false
  end
  return true
end

local function frozen_unchanged(state)
  if state.deferred and not state.panels then
    return true -- Material was validated, but no editor panels have existed yet.
  end
  -- Even hidden and already-decided panels remain the immutable review record.
  for _, item in ipairs(state.files) do
    for _, panel in ipairs({ { item.left, item.oldText }, { item.right, item.newText } }) do
      if
        not panel[1]
        or not vim.api.nvim_buf_is_valid(panel[1])
        or vim.bo[panel[1]].modified
        or not vim.deep_equal(vim.api.nvim_buf_get_lines(panel[1], 0, -1, false), lines(panel[2]))
      then
        return false
      end
    end
  end
  return true
end

show_file = function(state, index)
  if not state.tab or not vim.api.nvim_tabpage_is_valid(state.tab) then
    return false
  end
  local item = state.files[index]
  for _, win in ipairs(state.windows) do
    if not vim.api.nvim_win_is_valid(win) then
      return false
    end
    if not state.panels[vim.api.nvim_win_get_buf(win)] then
      return false -- The user repurposed a review window; never replace it.
    end
  end
  local counts = { pending = 0, accepted = 0, rejected = 0 }
  for _, file in ipairs(state.files) do
    if counts[file.decision] then
      counts[file.decision] = counts[file.decision] + 1
    end
  end
  local summary = state.controls
    or string.format(
      " a accept + next | r reject file | f revise pending | A/R remaining | ]f/[f files | q cancel pending | %d pending · %d accepted · %d rejected",
      counts.pending,
      counts.accepted,
      counts.rejected
    )
  for position, buf in ipairs({ item.left, item.right }) do
    if not vim.api.nvim_buf_is_valid(buf) then
      return false
    end
    local win = state.windows[position]
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_call(win, function()
      local title = string.format(
        "[%d/%d] [%s] %s · %s",
        index,
        #state.files,
        item.decision,
        item.path,
        item.retained_decision and "RETAINED DECISION · current saved context"
          or (position == 1 and "SAVED SNAPSHOT" or "FROZEN STAGED PROPOSAL")
      )
      vim.wo.winbar = title:gsub("%%", "%%%%")
      vim.wo.statusline = summary
      vim.wo.number, vim.wo.wrap = true, false
      vim.cmd("diffthis")
      vim.wo.foldenable = false
    end)
  end
  vim.api.nvim_set_current_tabpage(state.tab)
  for position, buf in ipairs({ item.left, item.right }) do
    local win = state.windows[position]
    if
      not vim.api.nvim_win_is_valid(win)
      or vim.api.nvim_win_get_tabpage(win) ~= state.tab
      or vim.api.nvim_win_get_buf(win) ~= buf
      or not vim.wo[win].diff
    then
      return false
    end
  end
  state.index, state.left, state.right = index, item.left, item.right
  state.revision = (state.revision or 0) + 1
  item.visited = true
  return true
end

local function create_panels(state)
  state.panels = {}
  local function panel(text)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden, vim.bo[buf].swapfile, vim.bo[buf].undofile = "hide", false, false
    vim.bo[buf].modeline = false
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines(text))
    vim.bo[buf].modified, vim.bo[buf].modifiable, vim.bo[buf].readonly = false, false, true
    if state.actions then
      local actions = state.actions
      vim.keymap.set("n", "a", actions.approve, { buffer = buf, silent = true })
      vim.keymap.set("n", "r", actions.reject, { buffer = buf, silent = true })
      vim.keymap.set("n", "A", actions.approve_all, { buffer = buf, silent = true })
      vim.keymap.set("n", "R", actions.reject_all, { buffer = buf, silent = true })
      vim.keymap.set("n", "q", actions.cancel, { buffer = buf, silent = true })
      vim.keymap.set(
        "n",
        "f",
        actions.followup,
        { buffer = buf, silent = true, desc = "Revise pending staged proposals" }
      )
      vim.keymap.set("n", "]f", function()
        actions.review(1)
      end, { buffer = buf, silent = true, desc = "Next staged file" })
      vim.keymap.set("n", "[f", function()
        actions.review(-1)
      end, { buffer = buf, silent = true, desc = "Previous staged file" })
    end
    state.panels[buf] = true
    return buf
  end
  for _, item in ipairs(state.files) do
    item.left, item.right = panel(item.oldText), panel(item.newText)
  end
end

local function present(state, first)
  if state.tab and vim.api.nvim_tabpage_is_valid(state.tab) then
    local wins = vim.api.nvim_tabpage_list_wins(state.tab)
    for _, win in ipairs(wins) do
      if not state.panels[vim.api.nvim_win_get_buf(win)] then
        return nil, "The review tab was repurposed; its windows are preserved"
      end
    end
    vim.api.nvim_set_current_tabpage(state.tab)
    state.windows = { wins[1], wins[2] }
  else
    vim.cmd("tabnew")
    state.tab = vim.api.nvim_get_current_tabpage()
    local empty = vim.api.nvim_get_current_buf()
    state.windows = { vim.api.nvim_get_current_win() }
    vim.api.nvim_win_set_buf(state.windows[1], state.files[first].left)
    if vim.api.nvim_buf_get_name(empty) == "" and not vim.bo[empty].modified then
      vim.api.nvim_buf_delete(empty, {})
    end
  end
  if not state.windows[2] then
    state.windows[2] = vim.api.nvim_open_win(state.files[first].right, true, {
      split = "right",
      win = state.windows[1],
    })
  end
  if not show_file(state, first) then
    return nil, "Review windows disappeared"
  end
  vim.cmd("wincmd =")
  return true
end

local function preview(state, first)
  create_panels(state)
  assert(present(state, first or 1))
  state.phase = "review_ready"
end

M.close, M.writer, M.finish = close_review, writer, finish
M.visible, M.frozen_unchanged = visible_review, frozen_unchanged
M.show_file, M.preview = show_file, preview

function M.can_decide(state, choice, remaining)
  if not visible_review(state) then
    return nil
  end
  local item = state.files[state.index]
  if not remaining and item.decision ~= "pending" then
    return nil, item.path .. " is already " .. item.decision .. "; other files remain pending"
  end
  if choice == "approve" then
    for _, file in ipairs(state.files) do
      if (remaining or file == item) and file.decision == "pending" and not file.visited then
        return nil, "Review every pending changed file with ]f / [f before accepting all"
      end
    end
    if not sources_unchanged(state) then
      return nil,
        "Source buffer changed; save and start a fresh turn. Previously accepted files remain published",
        true
    end
    if not frozen_unchanged(state) then
      return nil,
        "Review buffers changed; start a fresh turn. Previously accepted files remain published",
        true
    end
  end
  return true
end

function M.open(frozen, captured, options)
  options = options or {}
  if
    type(frozen) ~= "table"
    or frozen.root ~= captured.root
    or type(frozen.files) ~= "table"
    or not vim.islist(frozen.files)
    or #frozen.files ~= #captured.files
  then
    return nil, "Frozen review does not match the captured selection"
  end
  local state = vim.deepcopy(captured)
  state.proposal, state.id, state.python, state.multi =
    frozen.proposal, frozen.id, options.python, true
  state.actions, state.controls =
    options.actions, options.controls or "Frozen proposal — review before deciding"
  state.deferred = options.defer == true
  local first, total = nil, 0
  for index, item in ipairs(state.files) do
    local value = frozen.files[index]
    if
      type(value) ~= "table"
      or value.path ~= item.path
      or value.oldText ~= item.oldText
      or type(value.newText) ~= "string"
    then
      return nil, "Frozen review does not match its saved sources"
    end
    total = total + #value.newText
    if total > 1024 * 1024 then
      return nil, "Frozen review exceeds the selection budget"
    end
    item.newText = value.newText
    item.decision = item.oldText == item.newText and "unchanged" or "pending"
    local prior = options.decisions and options.decisions[index]
    if prior and prior.state ~= "pending" then
      if prior.path ~= item.path or item.decision ~= "unchanged" then
        return nil, "Replacement changed decided context"
      end
      item.decision, item.retained_decision = prior.state, prior.state
    end
    if item.decision == "pending" and not first then
      first = index
    end
  end
  local handle = {}
  function handle:show(path)
    if state.phase ~= "review_ready" then
      return nil, "This review handle is retired"
    end
    if not self:intact() then
      return nil, "Captured sources or frozen panels changed; cancel or close this review"
    end
    for index, item in ipairs(state.files) do
      if item.path == path then
        if not state.panels then
          create_panels(state)
        end
        if show_file(state, index) then
          return true
        end
        return present(state, index)
      end
    end
    return nil, "File is outside this frozen review"
  end
  function handle:intact()
    return state.phase == "review_ready" and sources_unchanged(state) and frozen_unchanged(state)
  end
  function handle:decide(choice, path)
    if
      state.phase ~= "review_ready"
      or (choice ~= "approve" and choice ~= "reject")
      or not state.index
      or state.files[state.index].path ~= path
    then
      return nil, "Open this pending file in its frozen review before deciding"
    end
    local allowed, reason = M.can_decide(state, choice, false)
    if not allowed then
      return nil, reason or "The frozen review is not visible"
    end
    local prior = {}
    for _, item in ipairs(state.files) do
      prior[item.path] = item.decision
    end
    state.phase = "applying"
    -- Preserve the existing synchronous guard-to-publication boundary.
    local verdict = writer(state, choice, false)
    finish(state, verdict)
    local refreshed = choice ~= "approve" or refresh_accepted(state, prior)
    local reason
    if
      not refreshed
      or (state.phase ~= "applied" and state.phase ~= "review_ready" and state.phase ~= "rejected")
    then
      reason = "Accepted source buffers or writer evidence require recovery"
    end
    return verdict, reason
  end
  function handle:retire()
    -- This handle owns only editor eligibility; Python retires writer authority.
    state.phase = "retired"
    close_review(state)
  end
  handle.close = handle.retire
  if first then
    if state.deferred then
      state.phase = "review_ready"
    else
      preview(state, first)
    end
  else
    state.phase = "settled"
  end
  return handle
end

return M
