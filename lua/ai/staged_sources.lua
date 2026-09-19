-- Shared saved-source and alias guards; capturing never publishes or saves.
local M = {}
local function lines(text)
  local result = vim.split(text, "\n", { plain = true })
  if result[#result] == "" then
    table.remove(result)
  end
  return #result == 0 and { "" } or result
end

local function buffer_text(buf, empty)
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  if empty and text == "" then
    return ""
  end
  return text .. (vim.bo[buf].endofline and "\n" or "")
end

local function text_buffer(buf)
  local bo = vim.bo[buf]
  return bo.buftype == ""
    and not bo.modified
    and not bo.binary
    and not bo.bomb
    and bo.fileformat == "unix"
    and (bo.fileencoding == "" or bo.fileencoding == "utf-8")
end

local function source_unchanged(state)
  local buf = state.source
  local expected = state.sourceText or state.oldText
  if
    not vim.api.nvim_buf_is_loaded(buf)
    or vim.api.nvim_buf_get_name(buf) ~= state.file
    or vim.api.nvim_buf_get_changedtick(buf) ~= state.tick
    or not text_buffer(buf)
    or buffer_text(buf, expected == "") ~= expected
  then
    return false
  end
  -- Hidden buffers and symlink aliases must not lose unsaved edits either.
  for _, alias in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_loaded(alias)
      and vim.uv.fs_realpath(vim.api.nvim_buf_get_name(alias)) == state.file
    then
      if not text_buffer(alias) or buffer_text(alias, expected == "") ~= expected then
        return false
      end
    end
  end
  return true
end

local function sources_unchanged(state)
  for _, item in ipairs(state.files) do
    if not source_unchanged(item) then
      return false
    end
  end
  return true
end

-- Capture only explicitly selected files. Loading a named buffer does not save
-- it, and all loaded aliases remain part of the approval guard.
local function capture(files, root)
  local selected = files or { vim.api.nvim_buf_get_name(0) }
  if type(selected) ~= "table" or not vim.islist(selected) or #selected == 0 or #selected > 16 then
    return nil, "Select between 1 and 16 existing files"
  end
  local items, seen, total = {}, {}, 0
  for _, name in ipairs(selected) do
    if type(name) ~= "string" or name == "" then
      return nil, "Select a saved, unmodified UTF-8 file (Unix line endings)"
    end
    local file = vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
    local node = vim.uv.fs_lstat(file)
    if not node or node.type ~= "file" or node.size > 1024 * 1024 then
      return nil, "Select regular files of at most 1 MiB combined"
    end
    if vim.uv.fs_realpath(file) ~= file then
      return nil, "Select canonical files without symbolic-link paths"
    end
    if seen[file] then
      return nil, "Each selected file must be unique"
    end
    seen[file], total = true, total + node.size
    if total > 1024 * 1024 then
      return nil, "Selected files exceed the 1 MiB combined limit"
    end
    root = root or vim.fs.root(file, ".git") or vim.fs.dirname(file)
    if file:sub(1, #root + 1) ~= root .. "/" then
      return nil, "Every selected file must be inside the first file's project root"
    end
    local buf = files and vim.fn.bufadd(file) or vim.api.nvim_get_current_buf()
    local loaded = pcall(vim.fn.bufload, buf)
    if not loaded or not vim.api.nvim_buf_is_loaded(buf) or not text_buffer(buf) then
      return nil, "Every selected buffer must be saved, unmodified UTF-8 (Unix line endings)"
    end
    if node.size > 0 and not vim.bo[buf].endofline then
      return nil, "Save every selected file with a final newline before staging"
    end
    local item = {
      source = buf,
      file = file,
      path = file:sub(#root + 2),
      tick = vim.api.nvim_buf_get_changedtick(buf),
      oldText = buffer_text(buf, node.size == 0),
    }
    if not source_unchanged(item) then
      return nil, "A selected file or alias buffer has unsaved or divergent contents"
    end
    items[#items + 1] = item
  end
  local state = { files = items, root = root, multi = files ~= nil, file = items[1].file }
  if not sources_unchanged(state) then
    return nil, "A selected buffer changed while loading the other selected files"
  end
  return state
end

local function refresh_accepted(state, prior)
  for _, item in ipairs(state.files) do
    if item.decision == "accepted" and prior[item.path] ~= "accepted" then
      if not source_unchanged(item) then
        return false
      end
      -- Normal external-change handling only. Never overwrite dirty buffers or
      -- bless arbitrary edits triggered by a checktime autocommand.
      local aliases = {}
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if
          vim.api.nvim_buf_is_loaded(buf)
          and vim.uv.fs_realpath(vim.api.nvim_buf_get_name(buf)) == item.file
        then
          aliases[#aliases + 1] = buf
        end
      end
      for _, buf in ipairs(aliases) do
        if not text_buffer(buf) then
          return false
        end
        local ok = pcall(vim.api.nvim_buf_call, buf, function()
          vim.cmd("checktime")
        end)
        if
          not ok
          or not vim.api.nvim_buf_is_loaded(buf)
          or not text_buffer(buf)
          or buffer_text(buf, item.newText == "") ~= item.newText
        then
          return false
        end
      end
      if
        not vim.api.nvim_buf_is_loaded(item.source)
        or vim.api.nvim_buf_get_name(item.source) ~= item.file
      then
        return false
      end
      item.sourceText, item.tick = item.newText, vim.api.nvim_buf_get_changedtick(item.source)
    end
  end
  return sources_unchanged(state)
end

M.lines, M.buffer_text, M.text_buffer = lines, buffer_text, text_buffer
M.source_unchanged, M.unchanged, M.capture = source_unchanged, sources_unchanged, capture
M.refresh_accepted = refresh_accepted
return M
