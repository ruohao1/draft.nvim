-- Read-only structured display state. Events never authorize a project mutation.
local M = {}
local uv = vim.uv
local states =
  { open = true, failed = true, idle = true, busy = true, approval = true, completed = true }
local fields = { schema = true, backend = true, session = true, state = true, time = true }

local function valid_session(event)
  if type(event.session) ~= "string" or #event.session > 128 then
    return false
  end
  if event.backend == "opencode" then
    return event.session:match("^ses_[A-Za-z0-9_-]+$") ~= nil
      or (event.session == "" and (event.state == "open" or event.state == "failed"))
  end
  if event.backend == "codex" then
    return event.session == "last" and (event.state == "open" or event.state == "failed")
  end
  return event.backend == "claude"
    and #event.session == 36
    and event.session:match("^[0-9a-f]+%-[0-9a-f]+%-4[0-9a-f]+%-[89ab][0-9a-f]+%-[0-9a-f]+$") ~= nil
    and event.session:sub(9, 9) == "-"
    and event.session:sub(14, 14) == "-"
    and event.session:sub(19, 19) == "-"
    and event.session:sub(24, 24) == "-"
end

local function valid(event)
  if type(event) ~= "table" then
    return false
  end
  local count = 0
  for key in pairs(event) do
    if not fields[key] then
      return false
    end
    count = count + 1
  end
  return count == 5
    and event.schema == 1
    and states[event.state] == true
    and valid_session(event)
    and type(event.time) == "number"
    and event.time >= 0
    and event.time <= 9007199254740991
end

local function decode(line)
  local quoted, escaped, colons = false, false, 0
  for index = 1, #line do
    local byte = line:sub(index, index)
    if escaped then
      escaped = false
    elseif quoted and byte == "\\" then
      escaped = true
    elseif byte == '"' then
      quoted = not quoted
    elseif not quoted and byte == ":" then
      colons = colons + 1
    end
  end
  if colons ~= 5 then
    return nil
  end
  local ok, event = pcall(vim.json.decode, line)
  return ok and event or nil
end

local function safe_file(stat)
  return stat
    and stat.type == "file"
    and stat.uid == uv.getuid()
    and stat.mode % 512 == 384
    and stat.nlink == 1
    and stat.size <= 1024 * 1024
end

local function read_file(path, offset, previous, anchor)
  local before = uv.fs_lstat(path)
  if not safe_file(before) or uv.fs_realpath(path) ~= path then
    return nil
  end
  local nofollow = uv.constants.O_NOFOLLOW or (uv.os_uname().sysname == "Linux" and 131072)
  if not nofollow then
    return nil
  end
  local fd = uv.fs_open(path, bit.bor(uv.constants.O_RDONLY, nofollow, uv.constants.O_NONBLOCK), 0)
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  local bytes, latest_anchor, reset
  if safe_file(stat) and stat.ino == before.ino and stat.dev == before.dev then
    reset = not previous
      or previous.ino ~= stat.ino
      or previous.dev ~= stat.dev
      or stat.size < offset
    if not reset and offset > 0 then
      local length = math.min(64, offset)
      reset = uv.fs_read(fd, length, offset - length) ~= anchor
    end
    local start = reset and 0 or offset
    bytes = stat.size == start and "" or uv.fs_read(fd, stat.size - start, start)
    if bytes and #bytes ~= stat.size - start then
      bytes = nil
    end
    local length = math.min(64, stat.size)
    latest_anchor = length == 0 and "" or uv.fs_read(fd, length, stat.size - length)
  end
  local after = uv.fs_fstat(fd)
  local named = uv.fs_lstat(path)
  uv.fs_close(fd)
  if
    not bytes
    or not latest_anchor
    or not safe_file(after)
    or after.size < stat.size
    or after.ino ~= stat.ino
    or after.dev ~= stat.dev
    or not safe_file(named)
    or named.ino ~= stat.ino
    or named.dev ~= stat.dev
  then
    return nil
  end
  return bytes, stat, reset, latest_anchor
end

local function watch(path, callback)
  local timer = assert(uv.new_timer())
  timer:start(250, 250, vim.schedule_wrap(callback))
  return function()
    timer:stop()
    timer:close()
  end
end

function M.new(options)
  if
    type(options) ~= "table"
    or type(options.path) ~= "string"
    or options.path:sub(1, 1) ~= "/"
    or not ({ claude = true, codex = true, opencode = true })[options.backend]
    or (type(options.session) ~= "string" and type(options.session) ~= "function")
  then
    return nil, "AI event reader options are invalid"
  end
  local reader, subscribers = {}, {}
  local running, cancel, offset, identity, anchor = false, nil, 0, nil, ""
  local carry, discarded, polling = "", false, false
  local function current_session()
    return type(options.session) == "function" and options.session() or options.session
  end
  local function matches(event, session)
    return valid(event)
      and event.backend == options.backend
      and (
        event.session == session
        or (options.backend == "opencode" and session == "" and event.session ~= "")
      )
  end
  local function consume(bytes, emit)
    bytes = carry .. bytes
    local cursor, last = 1, nil
    local seed_session = not emit and current_session() or nil
    while true do
      local newline = bytes:find("\n", cursor, true)
      if not newline then
        break
      end
      if not discarded and newline - cursor <= 4096 then
        local event = decode(bytes:sub(cursor, newline - 1))
        if matches(event, emit and current_session() or seed_session) then
          last = event
          if not emit then
            seed_session = event.session
          end
          if emit and running then
            for _, callback in ipairs(vim.deepcopy(subscribers)) do
              pcall(callback, vim.deepcopy(event))
            end
          end
        end
      end
      discarded = false
      cursor = newline + 1
    end
    carry = bytes:sub(cursor)
    if #carry > 4096 then
      carry, discarded = "", true
    end
    return last
  end

  function reader:subscribe(callback)
    if type(callback) ~= "function" then
      return nil, "AI event observer is invalid"
    end
    subscribers[#subscribers + 1] = callback
    return function()
      for index, candidate in ipairs(subscribers) do
        if candidate == callback then
          table.remove(subscribers, index)
          break
        end
      end
    end
  end

  function reader:start()
    if running then
      return true
    end
    local bytes, stat, _, latest_anchor = read_file(options.path, 0)
    if not bytes then
      return nil, "AI event file is unavailable or unsafe"
    end
    carry, discarded = "", false
    local seed = consume(bytes, false)
    carry, discarded = "", bytes ~= "" and bytes:sub(-1) ~= "\n"
    offset, identity, anchor, running = stat.size, stat, latest_anchor, true
    cancel = (options.watch or watch)(options.path, function()
      if running then
        reader:poll()
      end
    end)
    return true, seed
  end

  function reader:poll()
    if not running then
      return nil, "AI event reader is stopped"
    end
    if polling then
      return nil, "AI event reader is busy"
    end
    local bytes, stat, reset, latest_anchor = read_file(options.path, offset, identity, anchor)
    if not bytes then
      return nil, "AI event file is unavailable or unsafe"
    end
    if reset then
      carry, discarded = "", false
    end
    offset, identity, anchor = stat.size, stat, latest_anchor
    polling = true
    local ok = pcall(consume, bytes, true)
    polling = false
    if not ok then
      return nil, "AI event observer failed"
    end
    return true
  end

  function reader:stop()
    running = false
    if cancel then
      cancel()
      cancel = nil
    end
    return true
  end
  return reader
end

return M
