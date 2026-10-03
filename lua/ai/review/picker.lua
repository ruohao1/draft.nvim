-- A local selector only: opening a diff or deciding a review belongs to ui.lua.
local M = {}
local search_namespace = vim.api.nvim_create_namespace("nvim-ai-review-search")

local function display(text)
  return (
    tostring(text):gsub("[%z\1-\31\127]", function(byte)
      return string.format("%%%02X", string.byte(byte))
    end)
  )
end

-- vim.ui.select-compatible arguments; returns an idempotent cancellation function.
function M.select(items, options, callback)
  local owner = vim.api.nvim_get_current_win()
  local token = tostring({})
  local buffers, windows, entries = {}, {}, {}
  local closed, group, last_query = false, nil, nil
  local rows = {}
  for index, item in ipairs(items) do
    local text = display(options.format_item and options.format_item(item) or item)
    entries[index] = {
      item = item,
      index = index,
      text = text,
      search = type(item) == "table" and type(item.path) == "string" and display(item.path) or text,
    }
  end

  local function owns_window(win, buf)
    return win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf
  end

  local function inside()
    local current = vim.api.nvim_get_current_win()
    return (current == windows.input and owns_window(current, buffers.input))
      or (current == windows.list and owns_window(current, buffers.list))
  end

  local function close(entry)
    if closed then
      return
    end
    closed = true
    local restore = inside()
    if restore then
      vim.cmd.stopinsert()
    end
    if group then
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end
    for _, name in ipairs({ "list", "input" }) do
      local win, buf = windows[name], buffers[name]
      if owns_window(win, buf) then
        pcall(vim.api.nvim_win_close, win, true)
      end
      if
        buf
        and vim.api.nvim_buf_is_valid(buf)
        and vim.b[buf].nvim_ai_picker_owner == token
        and vim.bo[buf].buftype == "nofile"
        and #vim.fn.win_findbuf(buf) == 0
      then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    if restore and vim.api.nvim_win_is_valid(owner) then
      vim.api.nvim_set_current_win(owner)
    end
    -- Leave insert mode and retire the floats before opening a diff/confirmation.
    vim.schedule(function()
      callback(entry and entry.item or nil, entry and entry.index or nil)
    end)
  end
  local function cancel()
    close()
  end

  local function dimensions()
    local width = math.min(100, vim.o.columns - 4)
    local height = math.min(14, math.max(3, #entries), vim.o.lines - vim.o.cmdheight - 7)
    if width < 26 or height < 3 then
      return nil
    end
    local row = math.max(0, math.floor((vim.o.lines - vim.o.cmdheight - height - 5) / 2))
    local col = math.floor((vim.o.columns - width - 2) / 2)
    local common =
      { relative = "editor", width = width, col = col, style = "minimal", border = "rounded" }
    return {
      input = vim.tbl_extend(
        "force",
        common,
        { row = row, height = 1, title = " Review changes ", title_pos = "center" }
      ),
      list = vim.tbl_extend("force", common, {
        row = row + 3,
        height = height,
        footer = width >= 64 and " Enter: diff  ↑↓/Ctrl-n/p: move  Esc: close "
          or " Enter: diff  Esc: close ",
        footer_pos = "center",
      }),
    }
  end

  local function render(reset)
    if closed then
      return
    end
    local text = {}
    for _, entry in ipairs(rows) do
      text[#text + 1] = entry.text
    end
    if #text == 0 then
      text[1] = #entries == 0 and "No pending changes" or "No matching changes"
    end
    local selected = reset and 1 or vim.api.nvim_win_get_cursor(windows.list)[1]
    vim.bo[buffers.list].modifiable = true
    vim.api.nvim_buf_set_lines(buffers.list, 0, -1, false, text)
    vim.bo[buffers.list].modifiable, vim.bo[buffers.list].modified = false, false
    vim.api.nvim_win_set_cursor(windows.list, { math.min(selected, #text), 0 })
    vim.api.nvim_win_set_config(windows.list, {
      title = string.format(" %d/%d matches ", #rows, #entries),
      title_pos = "left",
    })
  end

  local function filter()
    if closed then
      return
    end
    local query = table.concat(vim.api.nvim_buf_get_lines(buffers.input, 0, -1, false), " ")
    if query == last_query then
      return
    end
    last_query = query
    vim.api.nvim_buf_clear_namespace(buffers.input, search_namespace, 0, -1)
    if query == "" then
      vim.api.nvim_buf_set_extmark(buffers.input, search_namespace, 0, 0, {
        virt_text = { { "Type to search files...", "Comment" } },
        virt_text_pos = "overlay",
      })
    end
    rows = query == "" and entries or vim.fn.matchfuzzy(entries, query, { key = "search" })
    render(true)
  end

  local function move(delta)
    filter()
    if not closed and #rows > 0 then
      local line = vim.api.nvim_win_get_cursor(windows.list)[1]
      vim.api.nvim_win_set_cursor(windows.list, { (line - 1 + delta) % #rows + 1, 0 })
    end
  end

  local function choose()
    if closed then
      return
    end
    -- TextChangedI may wait until typeahead is drained, after Enter/Ctrl-n.
    filter()
    local entry = rows[vim.api.nvim_win_get_cursor(windows.list)[1]]
    if entry then
      close(entry)
    end
  end

  local geometry = dimensions()
  if not geometry then
    vim.notify("Enlarge Neovim to open the review picker", vim.log.levels.WARN)
    cancel()
    return cancel
  end
  local ok, err = pcall(function()
    for _, name in ipairs({ "list", "input" }) do
      local buf = vim.api.nvim_create_buf(false, true)
      buffers[name] = buf
      vim.b[buf].nvim_ai_picker_owner = token
      vim.bo[buf].bufhidden, vim.bo[buf].swapfile, vim.bo[buf].undofile = "wipe", false, false
      vim.bo[buf].modeline, vim.bo[buf].undolevels = false, -1
      vim.bo[buf].filetype = name == "input" and "nvim-ai-review-search" or "nvim-ai-review-picker"
      local win = vim.api.nvim_open_win(buf, name == "input", geometry[name])
      windows[name] = win
      vim.wo[win].wrap, vim.wo[win].spell, vim.wo[win].foldenable = false, false, false
      vim.wo[win].cursorline = name == "list"
      vim.wo[win].cursorlineopt = "line"
      vim.wo[win].scrolloff = 2
      vim.wo[win].winhighlight = "Normal:NormalFloat,CursorLine:PmenuSel"
      local function map(modes, key, action, description)
        vim.keymap.set(modes, key, action, {
          buffer = buf,
          nowait = true,
          silent = true,
          desc = description,
        })
      end
      for _, key in ipairs({ "<Down>", "<C-n>", "<C-j>", "<Tab>" }) do
        map({ "n", "i" }, key, function()
          move(1)
        end, "Next review file")
      end
      for _, key in ipairs({ "<Up>", "<C-p>", "<C-k>", "<S-Tab>" }) do
        map({ "n", "i" }, key, function()
          move(-1)
        end, "Previous review file")
      end
      map("n", "j", function()
        move(1)
      end, "Next review file")
      map("n", "k", function()
        move(-1)
      end, "Previous review file")
      map({ "n", "i" }, "<CR>", choose, "Open selected review")
      map({ "n", "i" }, "<Esc>", cancel, "Close review picker")
      map({ "n", "i" }, "<C-c>", cancel, "Close review picker")
      map("n", "q", cancel, "Close review picker")
      map("n", "/", function()
        vim.api.nvim_set_current_win(windows.input)
        vim.cmd.startinsert()
      end, "Search review files")
    end
    group = vim.api.nvim_create_augroup("NvimAIReviewPicker" .. buffers.input, { clear = true })
    vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
      group = group,
      buffer = buffers.input,
      callback = filter,
    })
    vim.api.nvim_create_autocmd("WinLeave", {
      group = group,
      callback = function()
        -- Exit the picker-owned Insert mode before focus reaches a source buffer.
        if inside() then
          vim.cmd.stopinsert()
        end
        vim.schedule(function()
          if not closed and not inside() then
            cancel()
          end
        end)
      end,
    })
    local function retire()
      if inside() then
        vim.cmd.stopinsert()
      end
      vim.schedule(cancel)
    end
    for _, name in ipairs({ "list", "input" }) do
      vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        pattern = tostring(windows[name]),
        callback = retire,
      })
      vim.api.nvim_create_autocmd({ "BufWinLeave", "BufWipeout" }, {
        group = group,
        buffer = buffers[name],
        callback = retire,
      })
    end
    vim.api.nvim_create_autocmd("VimResized", {
      group = group,
      callback = function()
        if
          not owns_window(windows.input, buffers.input)
          or not owns_window(windows.list, buffers.list)
        then
          return cancel()
        end
        local next_geometry = dimensions()
        if not next_geometry then
          return cancel()
        end
        for _, name in ipairs({ "list", "input" }) do
          vim.api.nvim_win_set_config(windows[name], next_geometry[name])
        end
        render(false)
      end,
    })
    filter()
    vim.cmd.startinsert()
  end)
  if not ok then
    cancel()
    vim.notify("Review picker could not open: " .. tostring(err), vim.log.levels.WARN)
  end
  return cancel
end

return M
