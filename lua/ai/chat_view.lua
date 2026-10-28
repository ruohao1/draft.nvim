-- Presentation owns scratch buffers and windows, never conversation effects.
local M = {}
local MAX_BYTES, MAX_LINES, MAX_DRAFT = 2 * 1024 * 1024, 20000, 32768
local serial = 0
local namespace = vim.api.nvim_create_namespace("draft-chat")

local function prefix(value, limit)
  local last = math.min(#value, limit)
  if last < #value then
    while last > 0 and value:byte(last + 1) >= 128 and value:byte(last + 1) < 192 do
      last = last - 1
    end
  end
  return value:sub(1, last)
end

local function projection(snapshot, notice)
  local chunks, bytes, lines, omitted = {}, MAX_BYTES - 4096, MAX_LINES - 32, false
  local function prepend(value, group)
    value = tostring(value or "")
    local start = math.max(1, #value - bytes + 1)
    for i = #value, start, -1 do
      if value:byte(i) == 10 then
        if lines <= 1 then
          start = i + 1
          break
        end
        lines = lines - 1
      end
    end
    while start <= #value and value:byte(start) >= 128 and value:byte(start) < 192 do
      start = start + 1
    end
    omitted = omitted or start > 1
    local tail = value:sub(start)
    if bytes > 0 and lines > 0 and (#tail > 0 or value == "") then
      table.insert(chunks, 1, { text = tail, group = start == 1 and group or nil })
      bytes, lines = math.max(0, bytes - #tail - 1), lines - 1
    elseif #value > 0 then
      omitted = true
    end
  end
  for i = #(snapshot.turns or {}), 1, -1 do
    local turn = snapshot.turns[i]
    local round = (snapshot.rounds or {})[turn.round_id]
    if round and round.turn_id == turn.id then
      for index = #round.files, 1, -1 do
        local file = round.files[index]
        prepend(file.path .. " · " .. file.state, "DiagnosticInfo")
      end
      prepend(
        "Review "
          .. round.id
          .. " · revision "
          .. round.revision
          .. " · "
          .. round.status
          .. (round.origin == "manual" and " · manual correction" or ""),
        "Title"
      )
      prepend("")
    end
    if turn.progress then
      prepend("Tool: " .. turn.progress.title .. " [" .. turn.progress.status .. "]", "Comment")
    end
    prepend(turn.text)
    prepend(
      "Assistant · " .. (turn.model or turn.requested_model or "") .. " · " .. turn.status,
      "Title"
    )
    prepend("")
    prepend(turn.prompt)
    prepend("You · turn " .. turn.id, "Identifier")
    prepend("")
  end

  local text, highlights = {}, {}
  local function append(value, group, max_lines)
    for index, line in ipairs(vim.split(value, "\n", { plain = true })) do
      if max_lines and index > max_lines then
        break
      end
      if group and line ~= "" then
        highlights[#highlights + 1] = { line = #text, group = group }
      end
      text[#text + 1] = line
    end
  end
  append(
    (snapshot.backend == "codex" and "Codex" or "OpenCode") .. " · review before write",
    "Comment"
  )
  append(
    prefix("Editable files: " .. table.concat(snapshot.selection or {}, ", "), 1024),
    "Comment",
    6
  )
  if omitted then
    append("[Earlier transcript omitted from this view]", "Comment")
  end
  for _, chunk in ipairs(chunks) do
    append(chunk.text, chunk.group)
  end

  local notes, phase = {}, snapshot.phase or "idle"
  if phase == "idle" and #(snapshot.turns or {}) == 0 then
    notes[#notes + 1] = "Ask about the selected files, or request an edit."
  elseif phase == "starting" then
    notes[#notes + 1] = (snapshot.startup or "Starting") .. " · gc cancel"
  elseif phase == "generating" then
    notes[#notes + 1] = "gc cancel"
  elseif phase == "stopping" then
    notes[#notes + 1] = "Finishing this turn."
  elseif phase == "cancelling" then
    notes[#notes + 1] = "Cancelling; waiting for the worker to stop."
  elseif phase == "closing" then
    notes[#notes + 1] = "Closing; waiting for cleanup."
  elseif phase == "editing" then
    notes[#notes + 1] =
      "Correction open. :NvimAIChatFreezeProposal creates a fresh review; it does not publish."
  elseif phase == "freezing" then
    notes[#notes + 1] = "Freezing correction. Review the replacement before accepting."
  elseif phase == "publishing" then
    notes[#notes + 1] = "Publishing; waiting for the file outcomes."
  elseif phase == "closed" then
    notes[#notes + 1] = "Conversation closed. g? actions to start a new one."
  end
  if snapshot.review and snapshot.review.status == "pending" then
    notes[#notes + 1] = "gd review · Proposal pending"
    notes[#notes + 1] = "Send follows up; only acceptance writes files."
  end
  if snapshot.recovery_required then
    notes[#notes + 1] = "Recovery required; close this conversation before starting another."
  elseif phase == "failed" and snapshot.retry_safe then
    notes[#notes + 1] = "gr retry · gx close"
  end
  if snapshot.reason then
    notes[#notes + 1] = prefix(tostring(snapshot.reason), 2000)
  end
  if notice then
    notes[#notes + 1] = notice
  end
  if #notes > 0 then
    append("")
    -- Keep current guidance at the tail; provider text never supplies styling.
    local group = "Comment"
    if snapshot.recovery_required or phase == "failed" then
      group = "DiagnosticError"
    elseif snapshot.review and snapshot.review.status == "pending" then
      group = "DiagnosticWarn"
    end
    append(prefix(table.concat(notes, "\n"), 2900), group, 23)
  end
  return text, highlights
end

function M.new(options)
  options = options or {}
  serial = serial + 1
  local id, view = serial, {}
  local buffers, windows, names = {}, {}, {}
  local visible, disposed, closing = false, false, false
  local source_win, tab, layout, group, timer, latest, message
  local generation = 0

  local function owned(kind)
    local buf = buffers[kind]
    return buf
      and vim.api.nvim_buf_is_valid(buf)
      and vim.bo[buf].buftype == "nofile"
      and vim.api.nvim_buf_get_name(buf) == names[kind]
  end

  local function window(kind)
    local win = windows[kind]
    return owned(kind)
      and win
      and vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_win_get_buf(win) == buffers[kind]
      and win
  end

  local function cancel_timer()
    generation = generation + 1
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
  end

  local function close_windows()
    closing = true
    for _, kind in ipairs({ "input", "output" }) do
      local win = window(kind)
      if win then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    windows = {}
    closing = false
  end

  local function render()
    if not visible or not latest or not owned("output") then
      return
    end
    local buf, win = buffers.output, window("output")
    local count = vim.api.nvim_buf_line_count(buf)
    local saved = win and vim.api.nvim_win_call(win, vim.fn.winsaveview)
    local follow = not saved or saved.lnum >= count
    local text, highlights = projection(latest, message)
    if owned("input") then
      vim.bo[buffers.input].modifiable = latest.phase ~= "closed"
      local input = window("input")
      if input then
        local can_send = (latest.phase == "idle" or latest.phase == "review")
          and not latest.recovery_required
        vim.wo[input].statusline = latest.phase == "closed" and " Read-only history"
          or can_send and " Ctrl-S send · Enter newline"
          or " Draft kept · Enter newline"
      end
    end
    vim.bo[buf].modifiable = true
    local ok, reason = pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, text)
    vim.bo[buf].modifiable = false
    if not ok then
      error(reason)
    end
    vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    for _, mark in ipairs(highlights) do
      vim.api.nvim_buf_set_extmark(buf, namespace, mark.line, 0, {
        end_row = mark.line + 1,
        hl_group = mark.group,
      })
    end
    if win then
      if follow then
        vim.api.nvim_win_set_cursor(win, { #text, 0 })
        vim.api.nvim_win_call(win, function()
          vim.cmd("normal! zb")
        end)
      else
        vim.api.nvim_win_call(win, function()
          vim.fn.winrestview(saved)
        end)
      end
      vim.wo[win].winbar = (
        " Draft · "
        .. (latest.phase or "idle")
        .. " · next: "
        .. (latest.desired_model or "")
      ):gsub("%%", "%%%%")
    end
  end

  local function schedule()
    if timer or not visible or disposed then
      return
    end
    local token = generation
    timer = vim.uv.new_timer()
    timer:start(
      30,
      0,
      vim.schedule_wrap(function()
        if token ~= generation or disposed or not visible then
          return
        end
        cancel_timer()
        local ok, reason = pcall(render)
        if not ok then
          message = "Display failed: " .. tostring(reason):sub(1, 500)
        end
      end)
    )
  end

  local function action(name)
    if name == "hide" then
      view:hide()
    elseif name == "compose" then
      local win = window("input")
      if win then
        vim.api.nvim_set_current_win(win)
      end
    elseif options.on_action then
      options.on_action(name)
    end
  end

  local function make_buffer(kind)
    if owned(kind) then
      return buffers[kind]
    end
    local buf = vim.api.nvim_create_buf(false, true)
    if kind == "output" then
      -- Render projections are disposable; undo would retain every old copy.
      vim.bo[buf].undolevels = -1
    end
    buffers[kind] = buf
    names[kind] = "draft://chat/" .. id .. "/" .. kind .. "/" .. buf
    vim.api.nvim_buf_set_name(buf, names[kind])
    for key, value in pairs({
      buftype = "nofile",
      bufhidden = "hide",
      swapfile = false,
      undofile = false,
      modeline = false,
      filetype = kind == "input" and "draft-chat-input" or "draft-chat",
      modifiable = kind == "input",
    }) do
      vim.bo[buf][key] = value
    end
    for key, name in pairs({
      ["<C-s>"] = "send",
      q = "hide",
      gi = "compose",
      gd = "review",
      gm = "model",
      gc = "cancel",
      gr = "retry",
      gx = "close",
      ["g?"] = "actions",
    }) do
      vim.keymap.set("n", key, function()
        action(name)
      end, { buffer = buf, silent = true, desc = "Draft: " .. name })
    end
    if kind == "input" then
      vim.keymap.set("i", "<C-s>", function()
        action("send")
      end, { buffer = buf, silent = true, desc = "Draft: send" })
    end
    return buf
  end

  local function dimensions()
    if vim.o.columns < 40 or vim.o.lines < 12 then
      return nil
    end
    return vim.o.columns >= 100 and "right" or "below"
  end

  local function open_windows()
    layout = dimensions()
    if not layout then
      return nil, "Editor is too small for chat; resize and run :NvimAIChat again"
    end
    local config = { split = layout, win = -1, style = "minimal" }
    if layout == "right" then
      config.width = math.min(options.width or 48, vim.o.columns - 41)
    else
      config.height = math.max(6, math.floor(vim.o.lines / 2))
    end
    windows.output = vim.api.nvim_open_win(make_buffer("output"), false, config)
    windows.input = vim.api.nvim_open_win(make_buffer("input"), false, {
      split = "below",
      win = windows.output,
      height = math.min(6, math.max(3, math.floor(vim.o.lines / 5))),
      style = "minimal",
    })
    for kind, win in pairs(windows) do
      vim.wo[win].wrap = true
      vim.wo[win].signcolumn = "no"
      vim.wo[win].foldenable = false
      vim.wo[win].statusline = kind == "input" and " Ctrl-S send · Enter newline"
        or " g? actions · q hide"
      vim.wo[win].winbar = kind == "input" and " Message" or " Draft"
    end
    tab, visible = vim.api.nvim_get_current_tabpage(), true
    return true
  end

  local function watch()
    if group then
      return
    end
    group = vim.api.nvim_create_augroup("draft_chat_" .. id, { clear = true })
    vim.api.nvim_create_autocmd({ "WinClosed", "BufWinLeave" }, {
      group = group,
      callback = function(event)
        if closing or not visible then
          return
        end
        local win = tonumber(event.match)
        if
          win == windows.input
          or win == windows.output
          or event.buf == buffers.input
          or event.buf == buffers.output
        then
          local input, output = windows.input, windows.output
          vim.schedule(function()
            if
              visible
              and windows.input == input
              and windows.output == output
              and (not window("input") or not window("output"))
            then
              view:hide()
            end
          end)
        end
      end,
    })
    vim.api.nvim_create_autocmd("VimResized", {
      group = group,
      callback = function()
        if not visible then
          return
        end
        -- Never switch tabs to repair a background layout.
        if
          tab ~= vim.api.nvim_get_current_tabpage()
          or not window("input")
          or not window("output")
        then
          view:hide()
          return
        end
        local next_layout = dimensions()
        if not next_layout then
          view:hide()
        elseif next_layout ~= layout then
          local focus, kind = vim.api.nvim_get_current_win()
          if focus == windows.input then
            kind = "input"
          elseif focus == windows.output then
            kind = "output"
          end
          close_windows()
          local ok = pcall(open_windows)
          if not ok then
            view:hide()
          elseif kind then
            vim.api.nvim_set_current_win(windows[kind])
          elseif vim.api.nvim_win_is_valid(focus) then
            vim.api.nvim_set_current_win(focus)
          end
          schedule()
        end
      end,
    })
  end

  function view:show(snapshot)
    if disposed then
      return nil, "Conversation view was disposed"
    end
    cancel_timer()
    if not visible or not window("input") or not window("output") then
      close_windows()
      source_win = vim.api.nvim_get_current_win()
      local ok, result, why = pcall(open_windows)
      if not ok or not result then
        self:hide()
        return nil, why or tostring(result)
      end
      watch()
    end
    latest = snapshot
    local ok, reason = pcall(render)
    if not ok then
      return nil, "Cannot render chat: " .. tostring(reason)
    end
    vim.api.nvim_set_current_win(windows.input)
    return true
  end

  function view:update(snapshot)
    if visible and not disposed then
      latest = snapshot
      schedule()
    end
  end

  function view:visible()
    return visible
      and not disposed
      and window("input")
      and window("output")
      and tab == vim.api.nvim_get_current_tabpage()
  end

  function view:hide()
    local was_visible = visible
    local focus = vim.api.nvim_get_current_win()
    local focused = focus == window("input") or focus == window("output")
    visible, latest = false, nil
    cancel_timer()
    close_windows()
    if focused and source_win and vim.api.nvim_win_is_valid(source_win) then
      vim.api.nvim_set_current_win(source_win)
    end
    if was_visible and options.on_hide then
      options.on_hide()
    end
    return true
  end

  function view:draft()
    if not owned("input") then
      return "", nil, "absent"
    end
    local buf = buffers.input
    local stamp = buf .. ":" .. vim.api.nvim_buf_get_changedtick(buf)
    if vim.api.nvim_buf_get_offset(buf, vim.api.nvim_buf_line_count(buf)) - 1 > MAX_DRAFT then
      return nil, "Draft exceeds 32 KiB; shorten it before sending", stamp
    end
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), nil, stamp
  end

  function view:set_draft(value)
    local buf = make_buffer("input")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(value, "\n", { plain = true }))
  end

  function view:append_draft(value)
    local text, reason = self:draft()
    if not text then
      return nil, reason
    end
    local combined = text == "" and value or text .. "\n\n" .. value
    if #combined > MAX_DRAFT then
      return nil,
        "Context would exceed the 32 KiB draft limit; select less text or shorten the draft"
    end
    self:set_draft(combined)
    return true
  end

  function view:notice(reason)
    message = reason and prefix(tostring(reason), 1000) or nil
    schedule()
    return visible and window("output") ~= nil and tab == vim.api.nvim_get_current_tabpage()
  end

  function view:dispose()
    self:hide()
    disposed = true
    if group then
      vim.api.nvim_del_augroup_by_id(group)
      group = nil
    end
    for _, kind in ipairs({ "input", "output" }) do
      if owned(kind) then
        pcall(vim.api.nvim_buf_delete, buffers[kind], { force = true })
      end
    end
  end

  return view
end

return M
