-- Native review controls. Only the tracker may decide or mutate reviewed files.
local M = {}
local reducer = require("ai.review.reducer")

local function display_path(path)
  return (
    path:gsub("([^A-Za-z0-9._/-])", function(byte)
      return string.format("%%%02X", string.byte(byte))
    end)
  )
end

local function label(item)
  local state = item.state
  local suffix = item.reason and item.reason ~= "" and (" - " .. item.reason) or ""
  return string.format("[%s] %s%s", state, display_path(item.path), suffix)
end

local function owned_buffer(handle, buf)
  return buf and vim.api.nvim_buf_is_valid(buf) and vim.b[buf].nvim_ai_review_owner == handle.owner
end

local function close_diff(handle)
  if not handle then
    return true
  end
  if handle.tab and vim.api.nvim_tabpage_is_valid(handle.tab) then
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(handle.tab)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if (buf ~= handle.baseline and buf ~= handle.current) or not owned_buffer(handle, buf) then
        return nil, "review tab contains an unrelated window; close it explicitly"
      end
    end
    local ok = pcall(vim.api.nvim_cmd, {
      cmd = "tabclose",
      args = { tostring(vim.api.nvim_tabpage_get_number(handle.tab)) },
      mods = { noautocmd = true },
    }, {})
    if not ok then
      return nil, "review tab could not be closed safely"
    end
  end
  if handle.cursor_autocmd then
    pcall(vim.api.nvim_del_autocmd, handle.cursor_autocmd)
  end
  for _, buf in ipairs({ handle.baseline, handle.current }) do
    if owned_buffer(handle, buf) and #vim.fn.win_findbuf(buf) == 0 then
      if not pcall(vim.api.nvim_buf_delete, buf, { force = false }) then
        return nil, "review scratch could not be closed safely"
      end
    end
  end
  return true
end

local function scratch(view, side, bytes, owner)
  local name = "nvim-ai-" .. side .. "://" .. view.review_id .. "/" .. display_path(view.path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == name then
      error("review buffer name is already owned")
    end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  local ok, err = pcall(function()
    vim.b[buf].nvim_ai_review_owner = owner
    vim.api.nvim_buf_set_name(buf, name)
    vim.bo[buf].bufhidden, vim.bo[buf].swapfile, vim.bo[buf].modeline = "wipe", false, false
    local text = reducer.is_text(bytes)
    local lines = text and vim.split(bytes, "\n", { plain = true }) or {}
    if text and bytes:sub(-1) == "\n" then
      table.remove(lines)
    end
    local object = side == "baseline" and (view.decision_base or view.baseline) or view.current
    if view.action ~= "hunks" then
      local details = {
        "Path: " .. display_path(view.path),
        "State: " .. view.state,
        "Kind: " .. object.kind,
        "Mode: " .. (object.mode or "-"),
        "Size: " .. tostring(object.size),
        "SHA-256: " .. (object.sha256 or "-"),
      }
      if view.reason then
        details[#details + 1] = "Reason: " .. view.reason
      end
      if view.action == "none" and view.state == "conflicted" then
        if view.writer == "mixed" then
          details[#details + 1] =
            "Writer: mixed (Neovim edits and external changes cannot be separated safely)"
        end
      end
      if
        view.action == "none"
        and ({ conflicted = true, ignored = true, unsupported = true })[view.state]
      then
        details[#details + 1] =
          "Automatic accept/reject is disabled; unsaved buffers are preserved."
        details[#details + 1] =
          "Press o to inspect the real file and resolve manually; save any intended edits."
        details[#details + 1] =
          "Then reopen :NvimAIReview and press m to confirm the displayed exact version."
      end
      if object.kind == "symlink" and type(bytes) == "string" then
        details[#details + 1] = "Target: " .. display_path(bytes)
      elseif object.kind == "regular" and text then
        details[#details + 1] = ""
        vim.list_extend(details, lines)
      elseif object.kind == "regular" and bytes ~= nil then
        details[#details + 1] = "Content: binary (whole-file decisions only)"
      elseif bytes == nil then
        details[#details + 1] = "Content: unavailable (metadata only)"
      end
      lines = details
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].endofline = type(bytes) == "string" and bytes:sub(-1) == "\n"
    vim.bo[buf].fixendofline = false
    vim.bo[buf].filetype = vim.filetype.match({ filename = view.root .. "/" .. view.path }) or ""
    vim.b[buf].nvim_ai_review_path = view.path
    vim.b[buf].nvim_ai_review_hash = view.current_hash
    vim.b[buf].nvim_ai_review_hunk = #view.hunks > 0 and 1 or 0
    vim.bo[buf].modified, vim.bo[buf].modifiable, vim.bo[buf].readonly = false, false, true
  end)
  if not ok then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    error(err)
  end
  return buf
end

local function open_diff(view)
  local handle = { owner = tostring({}) }
  local ok = pcall(function()
    handle.baseline = scratch(view, "baseline", view.baseline_bytes, handle.owner)
    handle.current = scratch(view, "current", view.current_bytes, handle.owner)
    vim.api.nvim_cmd({
      cmd = "sbuffer",
      args = { tostring(handle.baseline) },
      mods = { tab = vim.api.nvim_tabpage_get_number(0), noautocmd = true },
    }, {})
    handle.tab, handle.baseline_win =
      vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
    vim.api.nvim_cmd({
      cmd = "sbuffer",
      args = { tostring(handle.current) },
      mods = { vertical = true, split = "botright", noautocmd = true },
    }, {})
    handle.current_win = vim.api.nvim_get_current_win()
    for _, win in ipairs({ handle.baseline_win, handle.current_win }) do
      vim.api.nvim_win_call(win, function()
        vim.cmd("diffthis")
      end)
    end
    if view.hunks[1] then
      vim.api.nvim_win_set_cursor(
        handle.current_win,
        { math.max(1, view.hunks[1].current_start), 0 }
      )
    end
  end)
  if not ok then
    close_diff(handle)
    return nil, "native review display could not be opened"
  end
  return handle
end

local function live_diff(handle)
  return handle
    and handle.tab
    and vim.api.nvim_tabpage_is_valid(handle.tab)
    and owned_buffer(handle, handle.baseline)
    and owned_buffer(handle, handle.current)
    and vim.api.nvim_win_is_valid(handle.baseline_win)
    and vim.api.nvim_win_is_valid(handle.current_win)
    and vim.api.nvim_win_get_buf(handle.baseline_win) == handle.baseline
    and vim.api.nvim_win_get_buf(handle.current_win) == handle.current
end

local function cursor_hunk(hunks, line)
  for index, hunk in ipairs(hunks) do
    if
      (hunk.current_count == 0 and line == math.max(1, hunk.current_start))
      or (line >= hunk.current_start and line < hunk.current_start + hunk.current_count)
    then
      return index
    end
  end
end

function M.new(options)
  local tracker = assert(options.tracker, "review tracker is required")
  local select = options.select or vim.ui.select
  local ui, generation = {}, 0
  local handle, shown, unsubscribe
  local schedule = options.schedule or vim.schedule
  local render, dispose = options.open_diff or open_diff, options.close_diff or close_diff
  local is_open = options.is_open or live_diff
  local cursor = options.cursor
    or function(view)
      return vim.api.nvim_win_get_cursor(view.current_win)[1]
    end
  local notify = options.notify
    or function(message)
      vim.notify(message, vim.log.levels.WARN)
    end
  local confirm = options.confirm
    or function(message)
      return vim.fn.confirm(message, "&Resolve\n&Cancel", 2) == 1
    end
  local map = options.map
    or function(buf, mode, lhs, callback, description)
      vim.keymap.set(mode, lhs, callback, { buffer = buf, silent = true, desc = description })
    end
  local open_file = options.open_file
    or function(view, rendered)
      vim.api.nvim_cmd({
        cmd = "tabedit",
        args = { view.root .. "/" .. view.path },
        magic = { file = false, bar = false },
        mods = { tab = vim.api.nvim_tabpage_get_number(rendered.tab) },
      }, {})
      return true
    end

  local function fresh_view(displayed, rendered)
    if shown ~= displayed or handle ~= rendered or not is_open(rendered) then
      return nil, "review view is closed or changed"
    end
    local latest, err = tracker:view(displayed.path)
    if not latest then
      return nil, err
    end
    if
      latest.review_id ~= displayed.review_id
      or latest.current_hash ~= displayed.current_hash
      or latest.baseline_bytes ~= displayed.baseline_bytes
      or latest.state ~= displayed.state
      or latest.action ~= displayed.action
    then
      return nil, "review view is stale; refresh before deciding"
    end
    return latest
  end

  local function bind_actions(displayed, rendered)
    local function control(lhs, description, operation, closing)
      for _, buf in ipairs({ rendered.baseline, rendered.current }) do
        map(buf, "n", lhs, function()
          if
            shown ~= displayed
            or handle ~= rendered
            or (not closing and not is_open(rendered))
          then
            return nil, "review view is closed or changed"
          end
          local called, result, err = pcall(operation)
          if not called then
            result, err = nil, "review control failed"
          end
          if not result then
            notify(err)
          end
          return result, err
        end, description)
      end
    end
    control("]r", "Next unresolved AI file", function()
      return ui:next(1)
    end)
    control("[r", "Previous unresolved AI file", function()
      return ui:next(-1)
    end)
    control("o", "Open real file for manual editing", function()
      return open_file(displayed, rendered)
    end)
    control("q", "Close owned AI review tab", function()
      return ui:close()
    end, true)
    local function bind(lhs, operation, description, whole)
      for _, buf in ipairs({ rendered.baseline, rendered.current }) do
        map(buf, "n", lhs, function()
          local invoked, result, err = pcall(function()
            local latest, view_error = fresh_view(displayed, rendered)
            if not latest then
              return nil, view_error
            end
            local decided, decision_error
            if operation == "resolve" then
              if
                latest.action ~= "none"
                or not ({ conflicted = true, ignored = true, unsupported = true })[latest.state]
              then
                return nil, "manual resolution is only available for manual-only paths"
              end
              if
                not confirm(
                  "Mark the displayed exact version of "
                    .. display_path(displayed.path)
                    .. " manually resolved? No automatic rejection will be performed."
                )
              then
                return nil, "manual resolution cancelled"
              end
              local verified, verification_error = fresh_view(displayed, rendered)
              if not verified then
                return nil, verification_error
              end
              decided, decision_error =
                tracker:resolve(displayed.path, "manual", displayed.current_hash)
            elseif whole then
              decided, decision_error =
                tracker[operation](tracker, displayed.path, displayed.current_hash)
            else
              local index = cursor_hunk(latest.hunks, cursor(rendered))
              if not index then
                return nil, "cursor is not on an unresolved hunk"
              end
              for _, owned in ipairs({ rendered.baseline, rendered.current }) do
                vim.b[owned].nvim_ai_review_hunk = index
              end
              decided, decision_error =
                tracker[operation](tracker, displayed.path, index, displayed.current_hash)
            end
            if not decided then
              return nil, decision_error
            end
            local refreshed, refresh_error = ui:refresh()
            if not refreshed then
              notify(refresh_error)
            end
            return decided
          end)
          if not invoked then
            result, err = nil, "review action failed"
          end
          if not result then
            notify(err)
          end
          return result, err
        end, description)
      end
    end
    bind("m", "resolve", "Manually resolve exact AI file")
    if displayed.state == "unresolved" and displayed.action == "hunks" then
      bind("a", "accept_hunk", "Accept current AI hunk")
      bind("r", "reject_hunk", "Reject current AI hunk")
    end
    if
      displayed.state == "unresolved"
      and (displayed.action == "hunks" or displayed.action == "whole")
    then
      bind("A", "accept_file", "Accept entire AI file", true)
      bind("R", "reject_file", "Reject entire AI file", true)
    end
  end

  function ui:open_path(path)
    local view, err = tracker:view(path)
    if not view then
      return nil, err
    end
    if options.review_id and options.review_id ~= view.review_id then
      return nil, "review batch changed"
    end
    local closed, close_error = self:close()
    if not closed then
      return nil, close_error
    end
    local opened, open_error = render(view)
    if not opened then
      return nil, open_error
    end
    handle, shown = opened, view
    bind_actions(view, opened)
    if opened.owner and #view.hunks > 0 then
      opened.cursor_autocmd = vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = opened.current,
        callback = function()
          if handle ~= opened or not is_open(opened) then
            return
          end
          local index = cursor_hunk(view.hunks, cursor(opened)) or 0
          for _, buf in ipairs({ opened.baseline, opened.current }) do
            vim.b[buf].nvim_ai_review_hunk = index
          end
        end,
      })
    end
    unsubscribe = tracker:subscribe(function()
      schedule(function()
        if handle ~= opened then
          return
        end
        local batch = tracker:batch_status()
        if
          batch.state == "closed"
          or batch.review_id ~= view.review_id
          or batch.cleanup_pending
        then
          local closed, close_error = self:close()
          if not closed then
            notify(close_error)
          end
        end
      end)
    end)
    return true
  end

  function ui:refresh()
    if not shown or not is_open(handle) then
      return nil, "review view is closed"
    end
    if tracker:batch_status().state == "closed" then
      return self:close()
    end
    local scanned, err = tracker:scan("review-refresh")
    if not scanned then
      return nil, err
    end
    return self:open_path(shown.path)
  end

  function ui:next(direction)
    if not shown or not is_open(handle) then
      return nil, "review view is closed"
    end
    if direction ~= 1 and direction ~= -1 then
      return nil, "review direction must be 1 or -1"
    end
    local scanned, err = tracker:scan("review-navigation")
    if not scanned then
      return nil, err
    end
    local paths = {}
    for _, item in ipairs(tracker:paths()) do
      if item.state == "unresolved" or item.state == "conflicted" then
        paths[#paths + 1] = item.path
      end
    end
    table.sort(paths)
    if #paths == 0 then
      return nil, "no unresolved review paths remain"
    end
    if direction == 1 then
      for _, path in ipairs(paths) do
        if path > shown.path then
          return self:open_path(path)
        end
      end
      return self:open_path(paths[1])
    end
    for index = #paths, 1, -1 do
      if paths[index] < shown.path then
        return self:open_path(paths[index])
      end
    end
    return self:open_path(paths[#paths])
  end

  function ui:open()
    local batch = tracker:batch_status()
    local review_id = options.review_id or batch.review_id
    if batch.state == "closed" or not review_id then
      return nil, "review batch is not open"
    end
    if review_id ~= batch.review_id then
      return nil, "review batch changed"
    end
    if batch.cleanup_pending then
      return nil, "review cleanup is pending"
    end
    generation = generation + 1
    local request = generation
    local items = tracker:paths()
    table.sort(items, function(left, right)
      return left.path < right.path
    end)
    for _, item in ipairs(items) do
      item.label = label(item)
    end
    items[#items + 1] = { label = "[batch] Abandon review batch", abandon = true }
    select(items, {
      prompt = "AI review batch " .. review_id,
      format_item = function(item)
        return item.label
      end,
    }, function(item)
      if not item or generation ~= request then
        return
      end
      generation = generation + 1
      local current = tracker:batch_status()
      if current.review_id ~= review_id or current.state == "closed" or current.cleanup_pending then
        notify("review batch changed while the picker was open")
        return
      end
      local called, result, err = pcall(function()
        if item.abandon then
          -- Command wiring supplies the same exact-ID, confirmed transaction
          -- as :NvimAIReview!. The UI never drops recovery storage itself.
          if type(options.abandon) ~= "function" then
            return nil, "confirmed review abandonment is unavailable"
          end
          local abandoned, abandon_error = options.abandon(review_id)
          if not abandoned then
            return nil, abandon_error
          end
          return self:close()
        end
        return self:open_path(item.path)
      end)
      if not called then
        result, err = nil, "review picker action failed"
      end
      if not result then
        notify(err)
      end
    end)
    return true
  end

  function ui:close()
    generation = generation + 1
    local closed, err = dispose(handle)
    if not closed then
      return nil, err
    end
    handle, shown = nil, nil
    if unsubscribe then
      local remove = unsubscribe
      unsubscribe = nil
      if not pcall(remove) then
        return nil, "review observer could not be detached"
      end
    end
    return true
  end

  return ui
end

return M
