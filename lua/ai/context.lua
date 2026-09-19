-- Explicit editor context only. Selected bytes never become a terminal paste.
local M = {}
local MAX_CONTEXT_BYTES = 4 * 1024 * 1024

local function integer(value, minimum)
  return type(value) == "number" and value >= minimum and value <= 2147483647 and value % 1 == 0
end

local function valid_identity(identity)
  return type(identity) == "table"
    and type(identity.key) == "string"
    and #identity.key == 32
    and identity.key:match("^[0-9a-f]+$")
    and type(identity.root) == "string"
    and identity.root:sub(1, 1) == "/"
    and identity.root ~= "/"
    and vim.fs.normalize(identity.root, { expand_env = false }) == identity.root
    and not identity.root:find("[%z\1-\31\127]")
    and not identity.root:find("\194[\128-\159]")
end

local function valid_buffer(bufnr)
  return integer(bufnr, 1)
    and vim.api.nvim_buf_is_valid(bufnr)
    and vim.api.nvim_buf_is_loaded(bufnr)
end

local function encode_source(value)
  return (
    value:gsub("([^A-Za-z0-9._/-])", function(byte)
      return string.format("%%%02X", byte:byte())
    end)
  )
end

local function physical_source(name)
  local candidate, missing = vim.fs.normalize(vim.fs.abspath(name), { expand_env = false }), {}
  while true do
    local physical = vim.uv.fs_realpath(candidate)
    if physical then
      return vim.fs.joinpath(physical, unpack(missing))
    end
    local stat, _, code = vim.uv.fs_lstat(candidate)
    if stat or code ~= "ENOENT" or candidate == "/" then
      return nil
    end
    table.insert(missing, 1, vim.fs.basename(candidate))
    candidate = vim.fs.dirname(candidate)
  end
end

local function source_path(identity, bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return "[No Name]"
  end
  if vim.bo[bufnr].buftype ~= "" then
    return encode_source(vim.fs.basename(name))
  end
  -- Resolve the nearest existing ancestor of an unsaved file, too. Lexical
  -- fallback alone would admit root/link/new-file when link points outside.
  local physical = physical_source(name)
  if not physical then
    return nil, "AI context source cannot be resolved safely"
  end
  -- Both paths are already absolute and physical. vim.fs.relpath would expand
  -- environment variables inside literal filenames before checking containment.
  local prefix = identity.root .. "/"
  if physical:sub(1, #prefix) ~= prefix then
    return nil, "buffer is outside the pinned companion root"
  end
  return encode_source(physical:sub(#prefix + 1))
end

function M.location(identity, bufnr, cursor)
  if not valid_identity(identity) or not valid_buffer(bufnr) then
    return nil, "AI context identity or buffer is invalid"
  end
  if vim.api.nvim_buf_get_name(bufnr) == "" or vim.bo[bufnr].buftype ~= "" then
    return nil, "normal AI context requires a named file buffer"
  end
  if
    type(cursor) ~= "table"
    or not integer(cursor[1], 1)
    or cursor[1] > vim.api.nvim_buf_line_count(bufnr)
    or not integer(cursor[2], 0)
  then
    return nil, "AI context cursor is invalid"
  end
  local path, err = source_path(identity, bufnr)
  if not path then
    return nil, err
  end
  return { kind = "location", path = path, line = cursor[1], column = cursor[2] + 1 }
end

local function selected_region(deps, bufnr, marks)
  if
    type(marks) ~= "table"
    or not ({ v = true, V = true, ["\22"] = true })[marks.mode]
    or (marks.inclusive ~= nil and type(marks.inclusive) ~= "boolean")
  then
    return nil, "AI visual selection is invalid"
  end
  local positions = {}
  for index, mark in ipairs({ marks.first, marks.last }) do
    if
      type(mark) ~= "table"
      or not vim.islist(mark)
      or #mark ~= 4
      or (mark[1] ~= 0 and mark[1] ~= bufnr)
      or not integer(mark[2], 1)
      or mark[2] > vim.api.nvim_buf_line_count(bufnr)
      or not integer(mark[3], 1)
      or not integer(mark[4], 0)
      or mark[4] > MAX_CONTEXT_BYTES
    then
      return nil, "AI visual marks are invalid or belong to another buffer"
    end
    local line = vim.api.nvim_buf_get_lines(bufnr, mark[2] - 1, mark[2], false)[1]
    if mark[3] > #line + 1 and not (marks.mode == "V" and mark[3] == 2147483647) then
      return nil, "AI visual mark is beyond its buffer line"
    end
    positions[index] = { bufnr, mark[2], mark[3], mark[4] }
  end
  if #positions ~= 2 then
    return nil, "AI visual marks are missing"
  end
  local selection_options = { type = marks.mode, exclusive = marks.inclusive == false }
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local ok, region = pcall(vim.api.nvim_buf_call, bufnr, function()
    return {
      lines = deps.getregion(positions[1], positions[2], selection_options),
      segments = deps.getregionpos(positions[1], positions[2], selection_options),
    }
  end)
  if not ok or type(region) ~= "table" then
    return nil, "AI visual selection is unavailable"
  end
  local lines, segments = region.lines, region.segments
  if
    not valid_buffer(bufnr)
    or vim.api.nvim_buf_get_changedtick(bufnr) ~= tick
    or type(lines) ~= "table"
    or not vim.islist(lines)
    or #lines == 0
    or type(segments) ~= "table"
    or not vim.islist(segments)
    or #segments ~= #lines
  then
    return nil, "AI visual selection is unavailable or changed"
  end
  for _, segment in ipairs(segments) do
    if type(segment) ~= "table" or not vim.islist(segment) or #segment ~= 2 then
      return nil, "AI visual selection positions are invalid"
    end
    for _, position in ipairs(segment) do
      if
        type(position) ~= "table"
        or not vim.islist(position)
        or #position ~= 4
        or position[1] ~= bufnr
        or not integer(position[2], 1)
        or position[2] > vim.api.nvim_buf_line_count(bufnr)
        or not integer(position[3], 0)
        or not integer(position[4], 0)
      then
        return nil, "AI visual selection positions are invalid"
      end
    end
  end
  for index, line in ipairs(lines) do
    if type(line) ~= "string" then
      return nil, "AI visual selection is invalid"
    end
    -- Vimscript strings represent an in-buffer NUL as NL. Line boundaries are
    -- already separate list entries, so restore NUL before joining those entries.
    lines[index] = line:gsub("\n", "\0")
  end
  local bytes = table.concat(lines, "\n") .. (marks.mode == "V" and "\n" or "")
  if bytes == "" then
    return nil, "AI visual selection is empty"
  end
  if #bytes > MAX_CONTEXT_BYTES then
    return nil, "AI visual selection exceeds the 4 MiB context limit"
  end
  local first, last = segments[1][1][2], segments[#segments][2][2]
  if not integer(first, 1) or not integer(last, first) then
    return nil, "AI visual selection positions are invalid"
  end
  return { bytes = bytes, first = first, last = last }
end

local function new(deps)
  local context = {}
  local current, pending, uncertain, transaction
  local function remove(path)
    if not path then
      return true
    end
    local ok, removed = pcall(deps.unlink, path)
    return ok and removed == true
  end
  local function discard()
    if not remove(pending) then
      return nil, "AI context rollback cleanup failed; retry cleanup"
    end
    pending = nil
    return true
  end
  local function accept(metadata, retain_pending)
    local next_file = metadata.context_file
    local ok, removed
    if deps.cleanup_all then
      ok, removed = pcall(deps.cleanup_all, next_file)
    else
      ok, removed = true, remove(current)
    end
    if not ok or removed ~= true then
      if retain_pending then
        return nil, "AI delivered context was retained; previous context cleanup needs retry"
      end
      local cleaned = discard()
      return nil,
        cleaned and "AI previous context cleanup failed"
          or "AI context rollback cleanup failed; retry cleanup"
    end
    current, pending = next_file, nil
    return metadata
  end
  function context:location(identity, bufnr, cursor)
    return M.location(identity, bufnr, cursor)
  end

  local function stage(identity, bufnr, marks)
    if pending or uncertain or transaction then
      return nil, "AI context cleanup is pending; retry cleanup"
    end
    if not valid_identity(identity) or not valid_buffer(bufnr) then
      return nil, "AI context identity or buffer is invalid"
    end
    local path, path_error = source_path(identity, bufnr)
    if not path then
      return nil, path_error
    end
    local region, region_error = selected_region(deps, bufnr, marks)
    if not region then
      return nil, region_error
    end
    if source_path(identity, bufnr) ~= path then
      return nil, "AI context source changed during selection"
    end
    local generated, nonce = pcall(deps.nonce)
    if
      not generated
      or type(nonce) ~= "string"
      or #nonce == 0
      or #nonce > 64
      or not nonce:match("^[A-Za-z0-9_-]+$")
    then
      return nil, "AI context nonce is unavailable or invalid"
    end
    local name = identity.key .. "-" .. nonce .. ".txt"
    local written, file, _, cleanup_required = pcall(deps.write_private, name, region.bytes)
    if not written or cleanup_required == true then
      uncertain = true
      return nil, "AI private context publication failed; retry cleanup"
    end
    if
      type(file) ~= "string"
      or file:sub(1, 1) ~= "/"
      or vim.fs.normalize(file, { expand_env = false }) ~= file
      or vim.fs.basename(file) ~= name
      or file:find("[%z\1-\31\127]")
      or file:find("\194[\128-\159]")
    then
      return nil, "AI private context publication failed"
    end
    if file == current then
      return nil, "AI private context writer reused the active file"
    end
    pending = file
    return {
      kind = "selection",
      path = path,
      first = region.first,
      last = region.last,
      context_file = file,
    }
  end

  function context:selection(identity, bufnr, marks)
    local metadata, err = stage(identity, bufnr, marks)
    if not metadata then
      return nil, err
    end
    return accept(metadata)
  end

  -- Stage before launch, format after launch, and commit only after delivery.
  -- Cancellation removes only this preparation; failed commit retains delivered bytes.
  function context:stage(options)
    if type(options) ~= "table" or (options.marks ~= nil and options.cursor ~= nil) then
      return nil, "AI context preparation options are invalid"
    end
    if pending or uncertain or transaction then
      return nil, "AI context cleanup is pending; retry cleanup"
    end
    local metadata, err
    if options.marks ~= nil then
      metadata, err = stage(options.identity, options.bufnr, options.marks)
    else
      metadata, err = M.location(options.identity, options.bufnr, options.cursor)
    end
    if not metadata then
      return nil, err
    end
    local staged, formatted =
      { file = metadata.context_file, metadata = vim.deepcopy(metadata) }, false
    transaction = staged
    function staged:cancel()
      if transaction ~= self then
        return true
      end
      local cleaned = discard()
      if cleaned then
        transaction = nil
        return true
      end
      return nil, "AI context rollback cleanup failed; retry cleanup"
    end
    function staged:format(adapter)
      if
        transaction ~= self
        or type(adapter) ~= "table"
        or type(adapter.format_context) ~= "function"
      then
        return nil, "AI context preparation is unavailable"
      end
      local ok, text = pcall(adapter.format_context, adapter, vim.deepcopy(metadata))
      if
        not ok
        or type(text) ~= "string"
        or #text == 0
        or #text > 2048
        or text:find("[%z\1-\31\127]")
        or text:find("\194[\128-\159]")
        or text:find("\226\128[\168\169]")
        or vim.fn.strtrans(text) ~= text
      then
        local cleaned = self:cancel()
        return nil,
          cleaned and "AI formatted context is not a short printable reference"
            or "AI context rollback cleanup failed; retry cleanup"
      end
      formatted = true
      return text
    end
    function staged:commit()
      if transaction ~= self or not formatted then
        return nil, "AI context preparation is unavailable or unformatted"
      end
      local accepted, accept_error = accept(metadata, true)
      if accepted then
        transaction = nil
        return true
      end
      return nil, accept_error
    end
    return staged
  end

  -- Preparing context has no authority to create a review, open a CLI, or paste.
  function context:prepare(options)
    if
      type(options) ~= "table"
      or type(options.adapter) ~= "table"
      or type(options.adapter.format_context) ~= "function"
    then
      return nil, "AI context preparation options are invalid"
    end
    local staged, err = self:stage(options)
    if not staged then
      return nil, err
    end
    local text, format_error = staged:format(options.adapter)
    if not text then
      return nil, format_error
    end
    local committed, commit_error = staged:commit()
    if not committed then
      local cleaned, cleanup_error = staged:cancel()
      return nil, cleaned and commit_error or cleanup_error
    end
    return { text = text, file = staged.file, metadata = staged.metadata }
  end

  function context:cleanup()
    if deps.cleanup_all then
      local ok, removed = pcall(deps.cleanup_all)
      if not ok or removed ~= true then
        return nil, "AI context cleanup failed; retry cleanup"
      end
      current, pending, uncertain, transaction = nil, nil, nil, nil
      return true
    end
    if uncertain then
      return nil, "AI private context store cleanup is required"
    end
    local cleaned, err = discard()
    if not cleaned then
      return nil, err
    end
    if not remove(current) then
      return nil, "AI context cleanup failed; retry cleanup"
    end
    current, transaction = nil, nil
    return true
  end

  function context:supersede()
    return self:cleanup()
  end

  -- Call only for a structured backend event proving this exact context was consumed.
  -- Terminal output, focus changes, and timeouts are not consumption evidence.
  function context:consumed(path)
    if path ~= current or current == nil then
      return true
    end
    if not remove(current) then
      return nil, "AI consumed context cleanup failed; retry cleanup"
    end
    current = nil
    return true
  end
  return context
end

function M.new(options)
  options = options or {}
  return new({
    nonce = function()
      return (
        vim.uv.random(16):gsub(".", function(byte)
          return string.format("%02x", byte:byte())
        end)
      )
    end,
    getregion = vim.fn.getregion,
    getregionpos = vim.fn.getregionpos,
    write_private = function(name, bytes)
      if not options.store then
        return nil
      end
      return options.store:write_context(name, bytes)
    end,
    unlink = function(path)
      if not options.store then
        return nil
      end
      return options.store:remove_context(path)
    end,
    cleanup_all = options.store and function(keep)
      return options.store:prune_contexts(keep)
    end or nil,
  })
end

M._test = {
  new = function(options)
    return new(
      vim.tbl_extend(
        "force",
        { getregion = vim.fn.getregion, getregionpos = vim.fn.getregionpos },
        options
      )
    )
  end,
}

return M
