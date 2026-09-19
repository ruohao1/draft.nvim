-- Shared backend metadata schema. Pane/buffer ownership stays in each transport.
local M = {}

local states = {
  closed = true,
  starting = true,
  open = true,
  attention = true,
  changes = true,
  conflicted = true,
  failed = true,
  paused = true,
  idle = true,
  busy = true,
  approval = true,
  completed = true,
}

local function safe(value, limit)
  return type(value) == "string"
    and #value <= limit
    and not value:find("[%z\1-\31\127]")
    and not value:find("\194[\128-\159]")
end

local function hex(value, length)
  return safe(value, length) and #value == length and value:match("^[0-9a-f]+$") ~= nil
end

function M.validate(data)
  if
    type(data) ~= "table"
    or not ({ codex = true, claude = true, opencode = true })[data.backend]
    or not states[data.state]
    or not safe(data.session, 128)
    or (data.grants ~= "0" and not hex(data.grants, 16))
  then
    return nil, "invalid backend pane metadata"
  end
  if data.backend == "opencode" then
    if
      not hex(data.opencode_token, 32)
      or not hex(data.opencode_fingerprint, 64)
      or data.opencode_version ~= "1.18.30"
    then
      return nil, "invalid OpenCode profile metadata"
    end
  elseif
    data.opencode_token ~= ""
    or data.opencode_fingerprint ~= ""
    or data.opencode_version ~= ""
  then
    return nil, "unexpected OpenCode profile metadata"
  end
  return true
end

return M
