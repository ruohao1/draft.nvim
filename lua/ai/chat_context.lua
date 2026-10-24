-- Ephemeral editor snapshots; only the returned block enters a conversation.
local M = {}
local context = require("ai.context")
local MAX_MESSAGE, MAX_SOURCE = 32768, 1024 * 1024
local buffer_options = {
  "buftype",
  "binary",
  "fileencoding",
  "fileformat",
  "endofline",
  "bomb",
  "modified",
  "tabstop",
  "vartabstop",
}
local window_options = { "virtualedit", "list", "listchars" }
local global_options = { "selection", "ambiwidth", "display" }

local function integer(value, minimum)
  return type(value) == "number" and value >= minimum and value <= 2147483647 and value % 1 == 0
end

local function valid_text(bytes)
  return #bytes <= MAX_MESSAGE
    and not bytes:find("[%z\1-\8\11-\31\127]")
    and not bytes:find("\194[\128-\159]")
    and require("ai.review.reducer").is_text(bytes)
end

local function source_guard(root, buf, win)
  if
    not integer(buf, 1)
    or not vim.api.nvim_buf_is_loaded(buf)
    or not vim.api.nvim_win_is_valid(win)
    or vim.api.nvim_win_get_buf(win) ~= buf
  then
    return nil, "Capture requires the current loaded file buffer"
  end
  local name, bo = vim.api.nvim_buf_get_name(buf), vim.bo[buf]
  if
    name == ""
    or not require("ai.review.reducer").is_text(name)
    or bo.buftype ~= ""
    or bo.binary
    or (bo.fileencoding ~= "" and bo.fileencoding ~= "utf-8")
  then
    return nil, "Capture requires a named, normal UTF-8 buffer"
  end
  -- The API name resolves symlinks; bufname retains the user's alias spelling.
  local spelling = vim.fs.normalize(vim.fs.abspath(vim.fn.bufname(buf)), { expand_env = false })
  if
    type(root) ~= "string"
    or root:sub(1, 1) ~= "/"
    or root == "/"
    or root:find("%z")
    or vim.uv.fs_realpath(root) ~= root
    or name:sub(1, #root + 1) ~= root .. "/"
    or spelling ~= name
    or context.physical_source(name) ~= name
  then
    return nil, "Context must use a canonical path inside the conversation root"
  end
  local options = {}
  for _, option in ipairs(buffer_options) do
    options[option] = bo[option]
  end
  for _, option in ipairs(window_options) do
    options[option] = vim.wo[win][option]
  end
  for _, option in ipairs(global_options) do
    options[option] = vim.o[option]
  end
  return {
    root = root,
    buf = buf,
    win = win,
    name = name,
    tick = vim.api.nvim_buf_get_changedtick(buf),
    options = options,
  }
end

function M.unchanged(guard)
  local ok, current = pcall(source_guard, guard.root, guard.buf, guard.win)
  return ok and current ~= nil and vim.deep_equal(guard, current)
end

local function glyph_end(line, column)
  if column <= 0 or column > #line then
    return #line
  end
  local finish = vim.fn.byteidx(line, vim.fn.charidx(line, column - 1) + 1)
  return finish < 0 and #line or finish
end

local function visual_preflight(guard, marks)
  if
    type(marks) ~= "table"
    or not ({ v = true, V = true, ["\22"] = true })[marks.mode]
    or (marks.inclusive ~= nil and type(marks.inclusive) ~= "boolean")
  then
    return nil, "Invalid visual selection"
  end
  local buf, count = guard.buf, vim.api.nvim_buf_line_count(guard.buf)
  for _, key in ipairs({ "first", "last" }) do
    local mark = marks[key]
    if
      type(mark) ~= "table"
      or not vim.islist(mark)
      or #mark ~= 4
      or (mark[1] ~= 0 and mark[1] ~= buf)
      or not integer(mark[2], 1)
      or mark[2] > count
      or not integer(mark[3], 1)
      or not integer(mark[4], 0)
      or mark[4] > 4 * MAX_SOURCE
    then
      return nil, "Invalid visual marks"
    end
  end
  local first, last =
    math.min(marks.first[2], marks.last[2]), math.max(marks.first[2], marks.last[2])
  if last - first > MAX_MESSAGE then
    return nil, "Selection has too many lines for the 32 KiB message limit"
  end
  if
    vim.api.nvim_buf_get_offset(buf, last) - vim.api.nvim_buf_get_offset(buf, first - 1)
    > MAX_SOURCE
  then
    return nil, "Context source span exceeds 1 MiB; select fewer lines"
  end
  local lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
  for _, mark in ipairs({ marks.first, marks.last }) do
    if
      mark[3] > #lines[mark[2] - first + 1] + 1
      and not (marks.mode == "V" and mark[3] == 2147483647)
    then
      return nil, "Visual mark is beyond its source line"
    end
  end
  local ok, segments = pcall(vim.fn.getregionpos, marks.first, marks.last, {
    type = marks.mode,
    exclusive = marks.inclusive == false,
    eol = true,
  })
  if
    not ok
    or type(segments) ~= "table"
    or not vim.islist(segments)
    or #segments == 0
    or #segments > last - first + 1
  then
    return nil, "Visual selection positions are unavailable"
  end
  local budget = #segments - 1 + (marks.mode == "V" and 1 or 0)
  for _, segment in ipairs(segments) do
    if type(segment) ~= "table" or #segment ~= 2 then
      return nil, "Invalid visual selection positions"
    end
    for _, pos in ipairs(segment) do
      if
        type(pos) ~= "table"
        or #pos ~= 4
        or pos[1] ~= buf
        or not integer(pos[2], first)
        or pos[2] > last
        or not integer(pos[3], 0)
        or not integer(pos[4], 0)
      then
        return nil, "Invalid visual selection position"
      end
    end
    local a, b = segment[1], segment[2]
    local line = lines[a[2] - first + 1]
    if a[2] ~= b[2] or a[3] > #line + 1 or b[3] > #line + 1 or a[3] > b[3] then
      return nil, "Visual selection size cannot be established safely"
    end
    local finish = glyph_end(line, b[3])
    local bytes = a[3] > 0 and math.max(0, finish - a[3] + 1) or 0
    if a[3] == b[3] and b[4] > 0 then
      bytes = math.max(0, b[4] - a[4])
    else
      -- Partial boundary glyphs become spaces, not their original UTF-8 bytes.
      if a[4] > 0 and a[3] <= #line then
        local cells = vim.fn.virtcol({ a[2], a[3] }, true, guard.win)
        bytes = bytes
          - (glyph_end(line, a[3]) - a[3] + 1)
          + math.max(0, cells[2] - cells[1] + 1 - a[4])
      end
      if b[4] > 0 then
        bytes = bytes - math.max(0, finish - b[3] + 1) + b[4]
      end
    end
    budget = budget + bytes
    if budget > MAX_MESSAGE then
      return nil, "Expanded selection exceeds 32 KiB; select less text"
    end
  end
  return true
end

local function render(guard, bytes, kind, first, last, whole)
  if not valid_text(bytes) then
    return nil, "Context must be valid UTF-8 text within 32 KiB, without control characters"
  end
  local size = 3
  for run in bytes:gmatch(string.char(96) .. "+") do
    size = math.max(size, #run + 1)
  end
  if #bytes + 2 * size > MAX_MESSAGE then
    return nil, "Context and its fences exceed the 32 KiB message limit"
  end
  local fence = string.rep(string.char(96), size)
  local location = first and string.format("lines %d-%d", first, last) or "all lines"
  local label = kind == "diagnostics" and "Cached diagnostics; freshness unverified"
    or "buffer text (LF)"
  local header = string.format(
    "Read-only context snapshot from %s (%s; %s):\nCaptured: %s; modified: %s; %s\n",
    vim.json.encode(guard.name:sub(#guard.root + 2)),
    location,
    kind,
    os.date("!%Y-%m-%dT%H:%M:%SZ"),
    guard.options.modified and "yes" or "no",
    label
  )
  if whole then
    header = header .. "Final newline: " .. (guard.options.endofline and "yes" or "no") .. "\n"
  end
  local block = header .. fence .. "\n" .. bytes .. (bytes:sub(-1) == "\n" and "" or "\n") .. fence
  if #block > MAX_MESSAGE then
    return nil, "Context metadata and text exceed the 32 KiB message limit"
  end
  return { block = block, guard = guard }
end

function M.capture_text(root, buf, marks)
  if buf ~= vim.api.nvim_get_current_buf() then
    return nil, "Capture requires the current file buffer"
  end
  local guard, reason = source_guard(root, buf, vim.api.nvim_get_current_win())
  if not guard then
    return nil, reason
  end
  local bytes, first, last, kind
  if marks == nil then
    first, last, kind = 1, vim.api.nvim_buf_line_count(buf), "buffer"
    if vim.api.nvim_buf_get_offset(buf, last) > MAX_SOURCE then
      return nil, "Context source span exceeds 1 MiB; select fewer lines"
    end
    bytes = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    if bytes ~= "" and guard.options.endofline then
      bytes = bytes .. "\n"
    end
  else
    local fits, why = visual_preflight(guard, marks)
    if not fits then
      return nil, why
    end
    if not M.unchanged(guard) then
      return nil, "Source changed during selection preflight"
    end
    local region, why = context.selection(buf, marks)
    if not region then
      return nil, why
    end
    bytes, first, last = region.bytes, region.first, region.last
    kind = ({ v = "character", V = "line", ["\22"] = "block" })[marks.mode]
  end
  if not M.unchanged(guard) then
    return nil, "Source changed during context capture"
  end
  return render(guard, bytes, kind, first, last, marks == nil)
end

function M.capture_diagnostics(root, buf, range)
  if buf ~= vim.api.nvim_get_current_buf() then
    return nil, "Capture requires the current file buffer"
  end
  local guard, reason = source_guard(root, buf, vim.api.nvim_get_current_win())
  if not guard then
    return nil, reason
  end
  if
    range ~= nil
    and (
      type(range) ~= "table"
      or not integer(range.line1, 1)
      or not integer(range.line2, 1)
      or range.line1 > range.line2
      or range.line2 > vim.api.nvim_buf_line_count(buf)
    )
  then
    return nil, "Invalid diagnostic line range"
  end
  -- shortcut: diagnostic count scans the cache and get copies nested data;
  -- replace acquisition if a hard memory/latency bound is required.
  local ok, counts = pcall(vim.diagnostic.count, buf)
  if not ok or type(counts) ~= "table" then
    return nil, "Cannot count cached diagnostics"
  end
  local total = 0
  for severity, count in pairs(counts) do
    if not integer(severity, 1) or severity > 4 or not integer(count, 0) then
      return nil, "Invalid cached diagnostic counts"
    end
    total = total + count
  end
  if total > 1000 then
    return nil, "More than 1,000 cached diagnostics; reduce the cache or attach text instead"
  end
  if total == 0 then
    return nil, "No cached diagnostics for this buffer"
  end
  local got, records = pcall(vim.diagnostic.get, buf)
  if not got or type(records) ~= "table" or not vim.islist(records) or #records ~= total then
    return nil, "Cached diagnostic retrieval failed or changed since count"
  end
  local selected, bytes = {}, 0
  for _, record in ipairs(records) do
    if
      type(record) ~= "table"
      or not integer(record.lnum, 0)
      or not integer(record.col, 0)
      or not integer(record.severity, 1)
      or record.severity > 4
    then
      return nil, "Invalid cached diagnostic position or severity"
    end
    if not range or (record.lnum + 1 >= range.line1 and record.lnum + 1 <= range.line2) then
      if #selected == 100 then
        return nil, "More than 100 matching diagnostics; select fewer lines"
      end
      if
        type(record.message) ~= "string"
        or (record.source ~= nil and type(record.source) ~= "string")
        or (record.code ~= nil and type(record.code) ~= "number" and type(record.code) ~= "string")
        or (
          type(record.code) == "number"
          and (record.code ~= record.code or math.abs(record.code) == math.huge)
        )
      then
        return nil, "Invalid cached diagnostic fields"
      end
      for _, field in ipairs({ "source", "code", "message" }) do
        local value = record[field]
        if type(value) == "string" then
          if not valid_text(value) then
            return nil,
              "Diagnostic fields must be valid UTF-8 text within 32 KiB, without control characters"
          end
          bytes = bytes + #value
        end
      end
      if bytes > MAX_MESSAGE then
        return nil, "Diagnostic text exceeds the 32 KiB message limit"
      end
      selected[#selected + 1] = record
    end
  end
  if #selected == 0 then
    return nil, "No cached diagnostics start in this line range"
  end
  local order = { ["nil"] = 1, number = 2, string = 3 }
  table.sort(selected, function(a, b)
    for _, key in ipairs({ "lnum", "col", "severity", "source", "code", "message" }) do
      if type(a[key]) ~= type(b[key]) then
        return order[type(a[key])] < order[type(b[key])]
      end
      if a[key] ~= b[key] then
        return a[key] < b[key]
      end
    end
    return false
  end)
  local lines, rendered_bytes = {}, 0
  local severity = { "ERROR", "WARN", "INFO", "HINT" }
  for _, record in ipairs(selected) do
    local line =
      string.format("%d:%d %s", record.lnum + 1, record.col + 1, severity[record.severity])
    for _, key in ipairs({ "source", "code", "message" }) do
      if record[key] ~= nil then
        line = line .. " " .. key .. "=" .. vim.json.encode(record[key])
      end
    end
    rendered_bytes = rendered_bytes + #line + 1
    if rendered_bytes > MAX_MESSAGE then
      return nil, "Rendered diagnostics exceed the 32 KiB message limit"
    end
    lines[#lines + 1] = line
  end
  if not M.unchanged(guard) then
    return nil, "Source changed during diagnostic capture"
  end
  return render(
    guard,
    table.concat(lines, "\n"),
    "diagnostics",
    range and range.line1,
    range and range.line2
  )
end

return M
