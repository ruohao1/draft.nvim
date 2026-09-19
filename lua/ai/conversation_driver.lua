-- Trusted editor/controller pipe, NOT raw ACP. No provider or writer operations.
-- new is passive. One driver owns one process and one conversation for life.
-- argv is trusted configuration, never a user action or agent-supplied command.
-- Events assert controller-validated evidence; process exit does not create it.
local M = {}
local uv = vim.uv
local MAX_FRAME, MAX_BYTES, MAX_EVENTS = 8 * 1024 * 1024, 32 * 1024 * 1024, 20000

local function close(handle)
  if handle and not handle:is_closing() then
    handle:close()
  end
end

local function integer(value, minimum, maximum)
  return type(value) == "number" and value % 1 == 0 and value >= minimum and value <= maximum
end

local function object(value, allowed)
  if type(value) ~= "table" or getmetatable(value) ~= nil then
    return false
  end
  for key in pairs(value) do
    if not allowed[key] then
      return false
    end
  end
  return true
end

local function decode(raw)
  local scan = 1
  while true do
    local at = raw:find("[\128-\255]", scan)
    if not at then
      break
    end
    local byte = raw:byte(at)
    local size = byte >= 194 and byte <= 223 and 2
      or byte >= 224 and byte <= 239 and 3
      or byte >= 240 and byte <= 244 and 4
    if not size or at + size - 1 > #raw then
      return nil
    end
    for index = 1, size - 1 do
      local next_byte = raw:byte(at + index)
      if next_byte < 128 or next_byte > 191 then
        return nil
      end
    end
    local second = raw:byte(at + 1)
    if
      (byte == 224 and second < 160)
      or (byte == 237 and second >= 160)
      or (byte == 240 and second < 144)
      or (byte == 244 and second >= 144)
    then
      return nil
    end
    scan = at + size
  end
  -- vim.json.decode does not reject duplicate object keys. Scan string/structure
  -- tokens first, bounding depth and checking decoded keys (including escapes).
  -- The native decoder remains responsible for the full JSON grammar.
  local stack, pos, tokens = {}, 1, 0
  while pos <= #raw do
    local at = raw:find("%S", pos)
    if not at then
      break
    end
    tokens = tokens + 1
    if tokens > 8192 then
      return nil
    end
    local char = raw:sub(at, at)
    if char == '"' then
      local ending = at + 1
      while true do
        ending = raw:find('["\\]', ending)
        if not ending then
          return nil
        end
        if raw:sub(ending, ending) == '"' then
          break
        end
        ending = ending + 2
      end
      local after = raw:find("%S", ending + 1)
      if after and raw:sub(after, after) == ":" then
        local keys = stack[#stack]
        local ok, key = pcall(vim.json.decode, raw:sub(at, ending))
        if not ok or type(keys) ~= "table" or keys[key] then
          return nil
        end
        keys[key] = true
      end
      pos = ending + 1
    elseif char:match("[{}%[%],:]") then
      if char == "{" or char == "[" then
        if #stack >= 32 then
          return nil
        end
        stack[#stack + 1] = char == "{" and {} or false
      elseif char == "}" or char == "]" then
        if #stack == 0 then
          return nil
        end
        stack[#stack] = nil
      end
      pos = at + 1
    else
      local ending = raw:find('[%s{}%[%],:"]', at) or (#raw + 1)
      local token = raw:sub(at, ending - 1)
      if token ~= "true" and token ~= "false" and token ~= "null" then
        local number = tonumber(token)
        local unsigned = token:gsub("^-", "")
        local whole = unsigned:match("^0") or unsigned:match("^[1-9]%d*")
        if not whole or not number or number ~= number or math.abs(number) == math.huge then
          return nil
        end
        local rest = unsigned:sub(#whole + 1)
        if rest:sub(1, 1) == "." then
          local fraction = rest:match("^%.%d+")
          if not fraction then
            return nil
          end
          rest = rest:sub(#fraction + 1)
        end
        if rest ~= "" and not rest:match("^[eE][+-]?%d+$") then
          return nil
        end
      end
      pos = ending
    end
  end
  local ok, value = pcall(vim.json.decode, raw)
  if ok and #stack == 0 then
    return value
  end
end

function M.new(options)
  if
    not object(options, { command = true, timeout_ms = true, stop_timeout_ms = true })
    or type(options.command) ~= "table"
    or not vim.islist(options.command)
    or #options.command < 1
    or #options.command > 32
  then
    return nil, "Invalid trusted controller configuration"
  end
  for _, arg in ipairs(options.command) do
    if type(arg) ~= "string" or #arg == 0 or #arg > 4096 or arg:find("%z") then
      return nil, "Invalid trusted controller argv"
    end
  end
  if options.command[1]:sub(1, 1) ~= "/" then
    return nil, "Controller executable must be an absolute trusted path"
  end
  local timeout, stop_timeout = options.timeout_ms or 120000, options.stop_timeout_ms or 3000
  if not integer(timeout, 20, 600000) or not integer(stop_timeout, 20, 10000) then
    return nil, "Invalid controller deadlines"
  end
  local argv = vim.deepcopy(options.command)
  local driver, serial, current, binding = {}, 0, nil, nil
  local process, input, output, exit_result, eof, held_close, dead, disconnected
  local timer, stop_timer, boundary_timer, leave, forced, input_closed
  local buffer, chunks, wire_bytes, frames, pending_bytes, queued_bytes = "", {}, 0, 0, 0, 0
  local scheduled, fault, pump, schedule, pumping

  local function clear_timer()
    close(timer)
    timer = nil
  end

  local function retire_handles()
    clear_timer()
    close(stop_timer)
    close(boundary_timer)
    stop_timer = nil
    boundary_timer = nil
    if leave then
      local id = leave
      leave = nil
      vim.schedule(function()
        pcall(vim.api.nvim_del_autocmd, id)
      end)
    end
  end

  local function input_eof()
    if input and not input:is_closing() and not input_closed then
      input_closed = true
      local ok, request = pcall(input.shutdown, input, function()
        close(input)
      end)
      if not ok or not request then
        close(input)
      end
    end
  end

  local function stop()
    input_eof()
    if stop_timer or not process then
      return
    end
    -- Exact spawned process only. The real controller must independently own
    -- worker EOF/death supervision; closing this pipe proves no worker cleanup.
    local step = 0
    stop_timer = assert(uv.new_timer())
    stop_timer:start(stop_timeout, stop_timeout, function()
      step = step + 1
      if exit_result and eof then
        retire_handles()
        return
      end
      forced = true
      close(input)
      if not exit_result then
        pcall(process.kill, process, step == 1 and "sigterm" or "sigkill")
      end
      if step >= 3 then
        -- A pipe held by an unknown descendant is not proof of shutdown. Stop
        -- retaining its output/handles, keep the owner failed, never claim close.
        close(output)
        retire_handles()
      end
    end)
  end

  fault = function()
    if dead then
      return
    end
    dead, held_close, buffer, chunks = true, nil, "", {}
    queued_bytes = 0
    clear_timer()
    if disconnected then
      disconnected()
    end
    stop()
  end

  local function boundary_deadline()
    if not boundary_timer and not dead then
      boundary_timer = assert(uv.new_timer())
      boundary_timer:start(stop_timeout, 0, fault)
    end
  end

  local function finish()
    if not exit_result or not eof or #chunks > 0 then
      return
    end
    if dead then
      retire_handles()
      return
    end
    if
      not held_close
      or buffer ~= ""
      or forced
      or exit_result.code ~= 0
      or exit_result.signal ~= 0
    then
      fault()
      retire_handles()
      return
    end
    local event = held_close
    held_close = nil
    local ok, accepted = pcall(current.receive, event)
    if not ok or accepted ~= true then
      fault()
    else
      dead = true
    end
    retire_handles()
  end

  local function frame(raw)
    frames = frames + 1
    if #raw > MAX_FRAME or frames > MAX_EVENTS or held_close then
      return fault()
    end
    local value = decode(raw)
    if
      not object(value, { version = true, serial = true, event = true })
      or value.version ~= 1
      or not integer(value.serial, 1, serial)
      or type(value.event) ~= "table"
    then
      return fault()
    end
    if value.serial ~= serial then
      return -- Old command, still charged against the wire budget.
    end
    local event, command = value.event, current.command
    for _, key in ipairs({ "conversation_id", "owner_generation", "turn_id", "worker_generation" }) do
      if event[key] ~= command[key] then
        return -- Wrong semantic identity cannot advance the current high-water mark.
      end
    end
    if not integer(event.sequence, 1, 9007199254740991) or event.sequence <= current.sequence then
      return
    end
    current.sequence = event.sequence
    if event.kind == "closed" and command.kind == "close" then
      held_close = event
      input_eof()
      return
    end
    local ok, accepted = pcall(current.receive, event)
    if not ok or accepted ~= true then
      return fault()
    end
    if event.kind == "settled" or event.kind == "cancelled" or event.kind == "decided" then
      clear_timer()
    end
  end

  pump = function()
    scheduled = false
    if dead then
      chunks, buffer = {}, ""
      finish()
      return
    end
    buffer = buffer .. table.concat(chunks)
    chunks = {}
    for _ = 1, 64 do
      local at = buffer:find("\n", 1, true)
      if not at then
        break
      end
      local raw = buffer:sub(1, at - 1)
      buffer = buffer:sub(at + 1)
      queued_bytes = queued_bytes - at
      frame(raw)
      if dead then
        return
      end
    end
    if #buffer > MAX_FRAME and not buffer:find("\n", 1, true) then
      return fault()
    end
    if buffer:find("\n", 1, true) then
      schedule()
      return -- Exit/EOF cannot overtake the remaining complete framed events.
    elseif eof and (buffer ~= "" or not held_close) then
      fault()
    elseif exit_result and (exit_result.code ~= 0 or exit_result.signal ~= 0) then
      fault()
    end
    finish()
  end

  local pump_batch = pump
  pump = function()
    scheduled = false
    if pumping then
      return -- A subscriber may run a nested event loop; never drain recursively.
    end
    pumping = true
    local ok = pcall(pump_batch)
    pumping = false
    if not ok then
      fault()
    end
    if not dead and (#chunks > 0 or buffer:find("\n", 1, true)) then
      schedule()
    end
  end

  schedule = function()
    if not scheduled then
      scheduled = true
      vim.schedule(pump)
    end
  end

  local function start()
    input, output = assert(uv.new_pipe(false)), assert(uv.new_pipe(false))
    process = uv.spawn(argv[1], {
      args = vim.list_slice(argv, 2),
      env = { "PATH=/usr/bin:/bin", "LANG=C.UTF-8" },
      stdio = { input, output, nil },
    }, function(code, signal)
      -- Capture status before scheduling: EOF must never race a bad exit into
      -- publishing a held closed receipt.
      exit_result = { code = code, signal = signal }
      boundary_deadline()
      close(process)
      close(input)
      schedule()
    end)
    if not process then
      close(input)
      close(output)
      dead = true
      return false
    end
    leave = vim.api.nvim_create_autocmd("VimLeavePre", { once = true, callback = input_eof })
    output:read_start(function(err, data)
      if not data then
        eof = true
        boundary_deadline()
        close(output)
      elseif not dead then
        -- Charge before scheduling so the fast-callback queue is bounded too.
        wire_bytes = wire_bytes + #data
        queued_bytes = queued_bytes + #data
        if wire_bytes > MAX_BYTES or queued_bytes > MAX_BYTES or #chunks >= MAX_EVENTS then
          fault()
        else
          chunks[#chunks + 1] = data
        end
      end
      if err then
        fault()
      end
      schedule()
    end)
    return true
  end

  function driver:send(command, receive, on_disconnect)
    if dead or input_closed or type(receive) ~= "function" or type(on_disconnect) ~= "function" then
      return false
    end
    if
      binding
      and (binding.id ~= command.conversation_id or binding.generation ~= command.owner_generation)
    then
      return false -- A process can never be rebound to a different editor owner.
    end
    binding = binding or { id = command.conversation_id, generation = command.owner_generation }
    disconnected = on_disconnect
    if not process and not start() then
      return false
    end
    serial = serial + 1
    local ok, payload = pcall(vim.json.encode, { version = 1, serial = serial, command = command })
    if not ok or #payload > 1024 * 1024 or pending_bytes + #payload + 1 > 2 * 1024 * 1024 then
      fault()
      return false
    end
    payload = payload .. "\n"
    current = { receive = receive, command = vim.deepcopy(command), sequence = 0 }
    wire_bytes, frames = 0, 0
    clear_timer()
    timer = assert(uv.new_timer())
    timer:start(timeout, 0, fault)
    pending_bytes = pending_bytes + #payload
    local sent, request = pcall(input.write, input, payload, function(err)
      pending_bytes = pending_bytes - #payload
      if err then
        fault()
      end
    end)
    if not sent or not request then
      fault()
      return false
    end
    return true -- Admission to bounded async I/O, not provider submission evidence.
  end
  return driver
end

return M
