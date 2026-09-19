-- Local names/metadata only. Selection never loads buffers or starts an agent.
-- The staging controller remains authoritative for contents and write safety.
local M = {}
local max_bytes, max_files, max_candidates = 1024 * 1024, 16, 5000

local function notify(message)
  vim.notify("AI staged: " .. message, vim.log.levels.WARN)
end

local function supported_path(name)
  if name == "" or #name > 4096 or name:find("[%c]") or name:sub(1, 1) == "/" then
    return false
  end
  local parts = vim.split(name:lower(), "/", { plain = true })
  if #parts > 64 then
    return false
  end
  for _, part in ipairs(parts) do
    if
      part == ""
      or part == "."
      or part == ".."
      or part == ".git"
      or part == ".ssh"
      or part == ".gnupg"
      or part == "auth.json"
      or part:match("^%.env")
      or part:match("%.pem$")
      or part:match("%.key$")
    then
      return false
    end
  end
  return true
end

local function metadata(file)
  local stat = vim.uv.fs_lstat(file)
  if
    not stat
    or stat.type ~= "file"
    or stat.uid ~= vim.uv.getuid()
    or stat.nlink ~= 1
    or (stat.mode % 4096 ~= 420 and stat.mode % 4096 ~= 493)
    or stat.size > max_bytes
    or vim.uv.fs_realpath(file) ~= file
  then
    return nil
  end
  return {
    dev = stat.dev,
    ino = stat.ino,
    mode = stat.mode,
    size = stat.size,
    mtime = stat.mtime,
    ctime = stat.ctime,
  }
end

-- Returns an idempotent cancellation function. callback receives canonical
-- absolute filenames only after the separate summary confirmation, or nil.
function M.open(root, callback)
  local node = type(root) == "string" and vim.uv.fs_stat(root) or nil
  if
    type(root) ~= "string"
    or root == "/"
    or root:find("[%c]")
    or vim.uv.fs_realpath(root) ~= root
    or not node
    or node.type ~= "directory"
  then
    notify("Choose a canonical project directory for file selection")
    callback(nil)
    return function() end
  end
  local tools = require("ai.tools")
  local rg, why = tools.resolve("rg")
  local valid
  if rg then
    valid, why = tools.revalidate(rg)
  end
  if not valid then
    notify(tostring(why) .. "; use :NvimAIStageFiles with explicit paths")
    callback(nil)
    return function() end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "nvim-ai-staged-picker"
  vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "wipe", false
  local win, group, job, closed
  local entries, selected, rows, summary, loaded = {}, {}, {}, false, false
  local function close(value)
    if closed then
      return
    end
    closed = true
    if group then
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end
    if job then
      pcall(job.kill, job, 15)
    end
    if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) and not vim.bo[buf].modified then
      pcall(vim.api.nvim_buf_delete, buf, {})
    end
    callback(value)
  end
  local function dimensions()
    local width, height = math.min(96, vim.o.columns - 4), math.min(22, vim.o.lines - 6)
    if width < 48 or height < 3 then
      return nil
    end
    return {
      relative = "editor",
      width = width,
      height = height,
      row = math.floor((vim.o.lines - height - 2) / 2),
      col = math.floor((vim.o.columns - width) / 2),
      style = "minimal",
      border = "rounded",
    }
  end
  local config = dimensions()
  if not config then
    notify("Enlarge Neovim to select files, or use :NvimAIStageFiles with explicit paths")
    close()
    return close
  end
  win = vim.api.nvim_open_win(buf, true, config)
  vim.wo[win].wrap, vim.wo[win].cursorline = false, true
  vim.wo[win].foldenable, vim.wo[win].spell = false, false
  local function render()
    if closed then
      return
    end
    local count, total, text = 0, 0, {}
    rows = {}
    for _, item in ipairs(entries) do
      local chosen = selected[item.path]
      if chosen then
        count, total = count + 1, total + chosen.size
      end
      if not summary or chosen then
        rows[#rows + 1] = item
        text[#text + 1] = (chosen and "[x] " or "[ ] ")
          .. item.path
          .. "  ("
          .. item.meta.size
          .. " B)"
      end
    end
    if not loaded then
      text = { "Scanning files..." }
    elseif #text == 0 then
      text = { "No eligible files found. q to cancel; explicit paths remain available." }
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
    vim.bo[buf].modifiable, vim.bo[buf].modified = false, false
    vim.api.nvim_win_set_config(win, {
      title = (summary and " Confirm files: " or " Select files: ")
        .. count
        .. "/16 · "
        .. total
        .. " B / 1 MiB ",
      footer = summary and " Enter: instruction · Backspace: back · q: cancel "
        or " /: search · Tab/Space: toggle · Enter: summary · q: cancel ",
    })
  end
  local function toggle()
    if closed or not loaded or summary then
      return
    end
    local item = rows[vim.api.nvim_win_get_cursor(win)[1]]
    if not item then
      return
    end
    if selected[item.path] then
      selected[item.path] = nil
    else
      local meta, count, total = metadata(item.file), 0, 0
      if not meta or not vim.deep_equal(meta, item.meta) then
        return notify("File changed or is no longer eligible; reopen the file picker")
      end
      for _, choice in pairs(selected) do
        count, total = count + 1, total + choice.size
      end
      if count == max_files or total + meta.size > max_bytes then
        return notify("Select at most 16 files and 1 MiB combined")
      end
      selected[item.path] = meta
    end
    render()
  end
  local function confirm()
    if closed or not loaded then
      return
    end
    local paths = {}
    for _, item in ipairs(entries) do
      if selected[item.path] then
        if not vim.deep_equal(metadata(item.file), selected[item.path]) then
          return notify("A selected file changed; cancel and reopen the file picker")
        end
        paths[#paths + 1] = item.file
      end
    end
    if #paths == 0 then
      return notify("Select at least one file with Tab or Space")
    end
    if summary then
      return close(paths)
    end
    summary = true
    render()
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
  end
  for _, key in ipairs({ "<Tab>", "<Space>" }) do
    vim.keymap.set("n", key, toggle, { buffer = buf, nowait = true, desc = "Toggle staged file" })
  end
  vim.keymap.set("n", "<CR>", confirm, { buffer = buf, desc = "Confirm staged selection" })
  vim.keymap.set("n", "<BS>", function()
    if not closed then
      summary = false
      render()
    end
  end, { buffer = buf, desc = "Back to staged file selection" })
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      close()
    end, { buffer = buf, nowait = true, desc = "Cancel staged selection" })
  end
  group = vim.api.nvim_create_augroup("NvimAIStagedPicker" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "WinLeave", "BufWipeout" }, {
    group = group,
    buffer = buf,
    callback = function()
      close()
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    callback = function()
      close()
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      local next_config = dimensions()
      if not next_config then
        return close()
      end
      vim.api.nvim_win_set_config(win, next_config)
      render()
    end,
  })
  render()

  -- Bound both process time and output. Never parse a truncated listing as a
  -- complete candidate set. rg obeys ignore files and does not follow symlinks.
  local chunks, bytes, failure = {}, 0
  local function fail(reason)
    notify(reason .. "; use :NvimAIStageFiles with explicit paths")
    close()
  end
  local ran, process = pcall(vim.system, {
    rg,
    "--files",
    "--hidden",
    "--null",
    "--no-config",
    "--glob=!.git",
    "--",
    ".",
  }, {
    cwd = root,
    text = false,
    timeout = 3000,
    stdout = function(err, data)
      if err then
        failure = "File discovery failed"
      end
      if closed or failure or not data then
        return
      end
      bytes = bytes + #data
      if bytes > 2 * max_bytes then
        failure = "File listing exceeds the 2 MiB discovery limit"
        if job then
          pcall(job.kill, job, 15)
        end
      else
        chunks[#chunks + 1] = data
      end
    end,
    stderr = false,
  }, function(result)
    vim.schedule(function()
      job = nil
      if closed then
        return
      end
      if failure or (result.code ~= 0 and result.code ~= 1) then
        return fail(failure or "File discovery failed or timed out")
      end
      local output = table.concat(chunks)
      chunks = nil
      if output ~= "" and output:sub(-1) ~= "\0" then
        return fail("Incomplete file listing")
      end
      local names = vim.split(output, "\0", { plain = true, trimempty = true })
      if #names > max_candidates then
        return fail("More than 5000 candidate files")
      end
      local index, seen = 1, {}
      local function batch()
        if closed then
          return
        end
        for _ = 1, 100 do
          local name = names[index]
          if not name then
            table.sort(entries, function(a, b)
              return a.path < b.path
            end)
            loaded = true
            render()
            return
          end
          index = index + 1
          name = name:gsub("^%./", "")
          if supported_path(name) and not seen[name] then
            local file = root .. "/" .. name
            local meta = metadata(file)
            if meta then
              seen[name] = true
              entries[#entries + 1] = { file = file, path = name, meta = meta }
            end
          end
        end
        vim.schedule(batch)
      end
      batch()
    end)
  end)
  if not ran then
    fail("Could not start local file discovery")
  elseif closed then
    pcall(process.kill, process, 15)
  else
    job = process
  end
  return function()
    close()
  end
end

return M
