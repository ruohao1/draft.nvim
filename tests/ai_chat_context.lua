-- Read-only snapshots use editor bytes without acquiring editable-file authority.
local loaded, context = pcall(require, "ai.chat_context")
assert(loaded, "Read-only context capture is missing")
local root = assert(vim.uv.fs_mkdtemp("/tmp/draft-chat-context-XXXXXX"))
local buffers = {}
local function buffer(name, lines)
  local buf = vim.api.nvim_create_buf(true, false)
  buffers[#buffers + 1] = buf
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, root .. "/" .. name)
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or { "" })
  return buf
end
local function has(text, value)
  assert(text:find(value, 1, true), vim.inspect(value) .. " missing from " .. text)
end
local function marks(buf, mode, first, last, inclusive)
  return {
    mode = mode,
    first = { buf, first[1], first[2], first[3] or 0 },
    last = { buf, last[1], last[2], last[3] or 0 },
    inclusive = inclusive ~= false,
  }
end
local ticks = string.rep(string.char(96), 3)
local getregion, getregionpos, get_lines =
  vim.fn.getregion, vim.fn.getregionpos, vim.api.nvim_buf_get_lines
local ok, reason = xpcall(function()
  for _, eol in ipairs({ true, false }) do
    local buf = buffer(eol and "with-eol.lua" or "without-eol.lua", { "café" })
    vim.bo[buf].endofline = eol
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local captured = assert(context.capture_text(root, buf))
    has(captured.block, "Read-only context snapshot")
    has(captured.block, "buffer")
    has(captured.block, "modified: yes")
    has(captured.block, "Final newline: " .. (eol and "yes" or "no"))
    has(captured.block, ticks .. "\ncafé\n" .. ticks)
    assert(captured.block:match("%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ"))
    assert(context.unchanged(captured.guard))
    assert(vim.api.nvim_buf_get_changedtick(buf) == tick and vim.bo[buf].modified)
    vim.bo[buf].fileformat = "dos"
    local crlf = assert(context.capture_text(root, buf))
    assert(not crlf.block:find("\r", 1, true))
  end
  local empty = buffer("empty", { "" })
  assert(context.capture_text(root, empty), "An empty whole buffer is valid context")
  assert(not context.capture_text(root, empty, marks(empty, "v", { 1, 1 }, { 1, 1 })))

  local buf = buffer("passage.lua", { "local café = 1", "local second = 2" })
  for _, case in ipairs({
    { "v", { 1, 7 }, { 1, 10 }, true, "café" },
    { "v", { 1, 7 }, { 1, 12 }, false, "café" },
    { "V", { 1, 1 }, { 2, 1 }, true, "local café = 1\nlocal second = 2" },
    { "\22", { 1, 1 }, { 2, 5 }, true, "local\nlocal" },
  }) do
    local captured = assert(context.capture_text(root, buf, marks(buf, unpack(case, 1, 4))))
    has(captured.block, ticks .. "\n" .. case[5] .. "\n" .. ticks)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { ticks })
  local captured = assert(context.capture_text(root, buf))
  has(captured.block, ticks .. string.char(96) .. "\n" .. ticks .. "\n" .. ticks .. string.char(96))
  print("ok - buffer, visual and newline snapshots preserve text without saving")

  local calls, positions, reads = 0, 0, 0
  vim.fn.getregion = function(...)
    calls = calls + 1
    return getregion(...)
  end
  vim.fn.getregionpos = function(...)
    positions = positions + 1
    return getregionpos(...)
  end
  vim.api.nvim_buf_get_lines = function(...)
    reads = reads + 1
    return get_lines(...)
  end
  local function reset_counts()
    calls, positions, reads = 0, 0, 0
  end
  local padded = buffer("padded", vim.fn["repeat"]({ "x" }, 100))
  vim.wo.virtualedit = "all"
  assert(not context.capture_text(root, padded, marks(padded, "\22", { 1, 1 }, { 100, 2, 999 })))
  assert(calls == 0, "Oversized virtual padding must refuse before getregion")
  local rows = buffer("many-rows", vim.fn["repeat"]({ "" }, 32770))
  reset_counts()
  assert(not context.capture_text(root, rows, marks(rows, "\22", { 1, 1 }, { 32770, 1 })))
  assert(calls == 0 and positions == 0, "Row count must bound position enumeration")
  local large = buffer("long-line", { string.rep("x", 1024 * 1024 - 1) })
  reset_counts()
  assert(context.capture_text(root, large, marks(large, "v", { 1, 1 }, { 1, 1 })))
  assert(calls == 1, "A 1 MiB source span can supply a small selection")
  vim.api.nvim_buf_set_lines(large, 0, -1, false, { string.rep("x", 1024 * 1024) })
  reset_counts()
  assert(not context.capture_text(root, large, marks(large, "v", { 1, 1 }, { 1, 1 })))
  assert(
    calls == 0 and positions == 0 and reads == 0,
    "Source span must be checked before reading lines"
  )
  vim.api.nvim_buf_set_lines(large, 0, -1, false, { "ok", string.rep("x", 1024 * 1024) })
  assert(context.capture_text(root, large, marks(large, "V", { 1, 1 }, { 1, 1 })))
  reset_counts()
  assert(not context.capture_text(root, large, marks(large, "\22", { 1, 1 }, { 2, 1 })))
  assert(calls == 0 and positions == 0)
  for _, length in ipairs({ 32768, 32769 }) do
    vim.api.nvim_buf_set_lines(large, 0, -1, false, { string.rep("x", length) })
    reset_counts()
    assert(not context.capture_text(root, large, marks(large, "v", { 1, 1 }, { 1, length })))
    assert(
      calls == (length == 32768 and 1 or 0),
      "Expanded bytes and metadata have separate budgets"
    )
  end
  local shapes = buffer("shapes", { "\t你éx", "\t你éy" })
  vim.bo[shapes].tabstop = 8
  vim.wo.virtualedit = "all"
  for _, case in ipairs({
    { "\22", { 1, 1, 2 }, { 2, 1, 4 }, true, "   \n   " },
    { "\22", { 1, 2 }, { 2, 2 }, true, "你\n你" },
    { "v", { 1, 5 }, { 1, 5 }, true, "é" },
  }) do
    local result = assert(context.capture_text(root, shapes, marks(shapes, unpack(case, 1, 4))))
    has(result.block, ticks .. "\n" .. case[5] .. "\n" .. ticks)
  end
  vim.api.nvim_buf_set_lines(shapes, 0, -1, false, { "a", "你", "b" })
  local partial =
    assert(context.capture_text(root, shapes, marks(shapes, "\22", { 1, 1 }, { 3, 1 })))
  has(partial.block, ticks .. "\na\n \nb\n" .. ticks)
  local thin = vim.fn["repeat"]({ "你" }, 10000)
  table.insert(thin, 1, "a")
  thin[#thin + 1] = "b"
  vim.api.nvim_buf_set_lines(shapes, 0, -1, false, thin)
  local narrow =
    assert(context.capture_text(root, shapes, marks(shapes, "\22", { 1, 1 }, { 10002, 1 })))
  has(narrow.block, "a\n" .. string.rep(" \n", 10000) .. "b")
  vim.fn.getregion, vim.fn.getregionpos, vim.api.nvim_buf_get_lines =
    getregion, getregionpos, get_lines
  print("ok - source and expanded-region budgets refuse before allocation")

  local literal = buffer("$DRAFT_CONTEXT_LITERAL % 二.lua", { "literal" })
  has(assert(context.capture_text(root, literal)).block, '"$DRAFT_CONTEXT_LITERAL % 二.lua"')
  local new = buffer("new/ancestor/file.lua", { "unsaved" })
  assert(context.capture_text(root, new))
  assert(not vim.uv.fs_stat(root .. "/new"), "Capture must not create directories")
  assert(vim.uv.fs_symlink(root, root .. "/inside-link"))
  assert(vim.uv.fs_symlink("/tmp", root .. "/outside-link"))
  for _, path in ipairs({ "inside-link/new.lua", "outside-link/new.lua", "../outside-context.lua" }) do
    local alias = buffer(path, { "refuse" })
    assert(not context.capture_text(root, alias), "Refuse path " .. path)
  end
  local guarded = buffer("guarded", { "before" })
  for _, option in ipairs({ "endofline", "modified", "binary" }) do
    local prior = vim.bo[guarded][option]
    local capture = assert(context.capture_text(root, guarded))
    vim.bo[guarded][option] = not prior
    assert(not context.unchanged(capture.guard), option .. " changes invalidate capture")
    vim.bo[guarded][option] = prior
  end
  local capture = assert(context.capture_text(root, guarded))
  vim.wo.list = not vim.wo.list
  assert(not context.unchanged(capture.guard))
  vim.wo.list = not vim.wo.list
  capture = assert(context.capture_text(root, guarded))
  vim.api.nvim_buf_set_lines(guarded, 0, -1, false, { "after" })
  assert(not context.unchanged(capture.guard))
  has(capture.block, "before")
  capture = assert(context.capture_text(root, guarded))
  vim.api.nvim_buf_set_name(guarded, root .. "/renamed")
  assert(not context.unchanged(capture.guard))
  for _, invalid in ipairs({ "\0", "\r", "\1", "\127", "\255", "\192\128", "\194\133" }) do
    vim.api.nvim_buf_set_lines(guarded, 0, -1, false, { invalid })
    assert(not context.capture_text(root, guarded), "Refuse invalid text " .. vim.inspect(invalid))
  end
  vim.api.nvim_buf_set_lines(guarded, 0, -1, false, { "text" })
  for _, option in ipairs({
    { "buftype", "nofile" },
    { "binary", true },
    { "fileencoding", "latin1" },
  }) do
    local prior = vim.bo[guarded][option[1]]
    vim.bo[guarded][option[1]] = option[2]
    assert(not context.capture_text(root, guarded))
    vim.bo[guarded][option[1]] = prior
  end
  vim.api.nvim_buf_set_name(guarded, "")
  assert(not context.capture_text(root, guarded))
  vim.api.nvim_buf_delete(guarded, { force = true })
  assert(not context.capture_text(root, guarded))
  local invalid_name = buffer("invalid-\255", { "text" })
  local ran, result = pcall(context.capture_text, root, invalid_name)
  assert(ran and result == nil, "Invalid UTF-8 attribution must refuse without throwing")
  print("ok - paths, source guards and text types preserve source identity")
end, debug.traceback)
vim.fn.getregion, vim.fn.getregionpos, vim.api.nvim_buf_get_lines =
  getregion, getregionpos, get_lines
for _, buf in ipairs(buffers) do
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end
vim.fn.delete(root, "rf")
assert(ok, reason)
