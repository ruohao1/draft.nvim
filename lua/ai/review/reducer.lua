-- Pure byte reduction. Acceptance changes the decision base, never disk.
local M = {}

-- str_utfindex counts malformed bytes as codepoints; it is not a validator.
function M.is_text(bytes)
  if type(bytes) ~= "string" or bytes:find("\0", 1, true) then
    return false
  end
  local cursor = 1
  while cursor <= #bytes do
    local lead = bytes:byte(cursor)
    local width = lead < 128 and 1
      or lead >= 194 and lead <= 223 and 2
      or lead >= 224 and lead <= 239 and 3
      or lead >= 240 and lead <= 244 and 4
      or nil
    if not width or cursor + width - 1 > #bytes then
      return false
    end
    for offset = 1, width - 1 do
      local byte = bytes:byte(cursor + offset)
      if byte < 128 or byte > 191 then
        return false
      end
      if
        offset == 1
        and (
          (lead == 224 and byte < 160)
          or (lead == 237 and byte >= 160)
          or (lead == 240 and byte < 144)
          or (lead == 244 and byte >= 144)
        )
      then
        return false
      end
    end
    cursor = cursor + width
  end
  return true
end

function M.hunks(base, current)
  if not M.is_text(base) or not M.is_text(current) then
    return nil, "binary review objects require whole-file decisions"
  end
  local ok, raw = pcall(vim.diff, base, current, {
    result_type = "indices",
    algorithm = "histogram",
    ctxlen = 0,
    interhunkctxlen = 0,
  })
  if not ok then
    return nil, "review hunk comparison failed"
  end
  local result = {}
  for _, hunk in ipairs(raw) do
    result[#result + 1] = {
      base_start = hunk[1],
      base_count = hunk[2],
      current_start = hunk[3],
      current_count = hunk[4],
    }
  end
  return result
end

local function span(bytes, start, count)
  local starts, cursor = {}, 1
  while cursor <= #bytes do
    starts[#starts + 1] = cursor
    local newline = bytes:find("\n", cursor, true)
    cursor = newline and newline + 1 or #bytes + 1
  end
  if count == 0 then
    local offset = starts[start + 1] or #bytes + 1
    return offset, offset
  end
  return starts[start], starts[start + count] or #bytes + 1
end

local function reduce(base, current, index, reject)
  local hunks, err = M.hunks(base, current)
  if not hunks then
    return nil, err
  end
  if type(index) ~= "number" or index % 1 ~= 0 or not hunks[index] then
    return nil, "review hunk index is invalid"
  end
  local hunk = hunks[index]
  local base_start, base_end = span(base, hunk.base_start, hunk.base_count)
  local current_start, current_end = span(current, hunk.current_start, hunk.current_count)
  if reject then
    return current:sub(1, current_start - 1)
      .. base:sub(base_start, base_end - 1)
      .. current:sub(current_end)
  end
  return base:sub(1, base_start - 1)
    .. current:sub(current_start, current_end - 1)
    .. base:sub(base_end)
end

function M.accept_hunk(base, current, index)
  return reduce(base, current, index, false)
end
function M.reject_hunk(base, current, index)
  return reduce(base, current, index, true)
end

return M
