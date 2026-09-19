local M = {}
local valid_metadata = require("ai.transports.metadata").validate

local function safe(value, limit)
  return type(value) == "string"
    and #value <= limit
    and not value:find("[%z\1-\31\127]")
    and not value:find("\194[\128-\159]")
end

local function valid_identity(value)
  return type(value) == "table"
    and safe(value.key, 32)
    and #value.key == 32
    and value.key:match("^[0-9a-f]+$")
    and safe(value.root, 1024)
    and value.root:sub(1, 1) == "/"
    and value.root ~= "/"
    and vim.fs.normalize(value.root) == value.root
    and safe(value.namespace, 1200)
    and value.namespace:match("^nvim:.+")
    and not value.owner_pane
    and not value.tmux_socket
end

local function valid_invocation(value)
  if
    type(value) ~= "table"
    or type(value.argv) ~= "table"
    or not vim.islist(value.argv)
    or #value.argv < 1
    or #value.argv > 256
  then
    return false
  end
  for _, item in ipairs(value.argv) do
    if not safe(item, 8192) or item == "" then
      return false
    end
  end
  return value.argv[1]:sub(1, 1) == "/"
end

local function new(deps)
  local transport = {}
  local identity, active

  local function bind(value)
    if not valid_identity(value) then
      return nil, "invalid standalone identity"
    end
    if
      identity
      and (
        identity.key ~= value.key
        or identity.root ~= value.root
        or identity.namespace ~= value.namespace
      )
    then
      return nil, "transport identity changed"
    end
    identity = vim.deepcopy(value)
    return true
  end

  local function owned(handle)
    if not active or handle ~= active.pane or not deps.valid(active.buffer, active.job) then
      return nil, "stale or foreign terminal handle"
    end
    return active
  end

  local function stop(item, policy)
    policy = policy or { signal = 15, timeout = 2000 }
    if
      type(policy) ~= "table"
      or (policy.signal ~= 1 and policy.signal ~= 15)
      or type(policy.timeout) ~= "number"
      or policy.timeout % 1 ~= 0
      or policy.timeout < 0
      or policy.timeout > 2000
      or policy.force
    then
      return nil, "invalid backend stop policy"
    end
    if deps.running(item.job) then
      local pid = deps.pid(item.job)
      if type(pid) ~= "number" or pid < 2 then
        return nil, "terminal process identity unavailable"
      end
      local called, result = pcall(deps.kill, pid, policy.signal)
      if not called or result ~= 0 then
        return nil, "could not signal terminal process"
      end
      local stopped = deps.wait(policy.timeout, function()
        return not deps.running(item.job)
      end)
      if not stopped then
        if not deps.valid(item.buffer, item.job) then
          return nil, "terminal ownership changed"
        end
        if
          not deps.stop(item.job)
          or not deps.wait(1000, function()
            return not deps.running(item.job)
          end)
        then
          return nil, "terminal process did not stop"
        end
      end
    end
    return true
  end

  function transport:discover(value)
    local ok, err = bind(value)
    if not ok then
      return nil, err
    end
    if active and deps.valid(active.buffer, active.job) and deps.running(active.job) then
      local data = vim.deepcopy(active.metadata or {})
      data.pane = active.pane
      return { data }
    end
    return {}
  end

  function transport:owned_panes(value)
    local ok, err = bind(value)
    if not ok then
      return nil, err
    end
    if active and deps.valid(active.buffer, active.job) then
      return { { pane = active.pane, key = identity.key, root = identity.root } }
    end
    return {}
  end

  function transport:create(value, invocation)
    local ok, err = bind(value)
    if not ok then
      return nil, err
    end
    if not valid_invocation(invocation) then
      return nil, "invalid terminal launcher argv"
    end
    if active then
      if deps.valid(active.buffer, active.job) then
        if deps.running(active.job) then
          return nil, "terminal companion already exists"
        end
        if not deps.wipe(active.buffer) then
          return nil, "could not clean up exited terminal"
        end
      end
      active = nil
    end
    local called, buffer, job = pcall(deps.create, identity.root, vim.deepcopy(invocation.argv))
    if not called or type(buffer) ~= "number" or buffer < 1 or type(job) ~= "number" or job < 1 then
      return nil, "terminal creation failed"
    end
    local pane = string.format("term:%d:%d", buffer, job)
    active = { pane = pane, buffer = buffer, job = job }
    return pane
  end

  function transport:focus(handle)
    local item, err = owned(handle)
    if not item then
      return nil, err
    end
    if not deps.focus(item.buffer) then
      return nil, "could not focus terminal"
    end
    return true
  end

  function transport:paste(handle, text)
    if not safe(text, 2048) or text == "" then
      return nil, "unsafe or empty context reference"
    end
    local item, err = owned(handle)
    if not item then
      return nil, err
    end
    if not deps.running(item.job) then
      return nil, "terminal process has exited"
    end
    if not deps.send(item.job, text) then
      return nil, "terminal paste failed"
    end
    return true
  end

  function transport:tag(handle, data)
    if
      not valid_metadata(data)
      or not identity
      or data.key ~= identity.key
      or data.root ~= identity.root
      or data.owner ~= nil
    then
      return nil, "invalid terminal metadata"
    end
    local item, err = owned(handle)
    if not item then
      return nil, err
    end
    item.metadata = vim.deepcopy(data)
    return true
  end

  function transport:respawn(handle, invocation, policy)
    if not valid_invocation(invocation) then
      return nil, "invalid terminal launcher argv", "not_started"
    end
    local item, err = owned(handle)
    if not item then
      return nil, err, "not_started"
    end
    local ok
    ok, err = stop(item, policy)
    if not ok then
      return nil, err, "not_started"
    end
    local called, buffer, job =
      pcall(deps.restart, item.buffer, identity.root, vim.deepcopy(invocation.argv))
    if not called or type(buffer) ~= "number" or buffer < 1 or type(job) ~= "number" or job < 1 then
      return nil, "terminal replacement failed"
    end
    -- The handle is an opaque generation token, not a buffer/channel lookup.
    -- Replacement keeps the window and token, but Neovim needs a fresh terminal buffer.
    item.buffer, item.job = buffer, job
    return true
  end

  function transport:close(handle, policy)
    local item, err = owned(handle)
    if not item then
      return nil, err
    end
    local ok
    ok, err = stop(item, policy)
    if not ok then
      return nil, err
    end
    if not deps.wipe(item.buffer) then
      return nil, "could not wipe owned terminal buffer"
    end
    active = nil
    return true
  end

  function transport:shutdown()
    if active then
      return self:close(active.pane)
    end
    return true
  end

  return transport
end

function M.new(options)
  options = options or {}
  local width = options.width or 40
  if type(width) ~= "number" or width % 1 ~= 0 or width < 10 or width > 80 then
    return nil, "invalid terminal width"
  end
  local function split(buffer)
    vim.cmd("botright vsplit")
    vim.api.nvim_win_set_buf(0, buffer)
    vim.api.nvim_win_set_width(0, math.max(1, math.floor(vim.o.columns * width / 100)))
  end
  return new({
    create = function(root, argv)
      local buffer = vim.api.nvim_create_buf(false, true)
      local ok, job = pcall(function()
        split(buffer)
        vim.bo[buffer].bufhidden = "hide"
        return vim.fn.termopen(argv, { cwd = root })
      end)
      if not ok or job < 1 then
        pcall(vim.api.nvim_buf_delete, buffer, { force = true })
        return nil
      end
      return buffer, job
    end,
    restart = function(buffer, root, argv)
      local replacement = vim.api.nvim_create_buf(false, true)
      local job
      local ok = pcall(function()
        vim.bo[replacement].bufhidden = "hide"
        job = vim.api.nvim_buf_call(replacement, function()
          return vim.fn.termopen(argv, { cwd = root })
        end)
        assert(job > 0)
        for _, window in ipairs(vim.fn.win_findbuf(buffer)) do
          vim.api.nvim_win_set_buf(window, replacement)
        end
        vim.api.nvim_buf_delete(buffer, { force = true })
      end)
      if not ok then
        if job and job > 0 then
          vim.fn.jobstop(job)
          vim.fn.jobwait({ job }, 1000)
        end
        pcall(vim.api.nvim_buf_delete, replacement, { force = true })
        return nil
      end
      return replacement, job
    end,
    valid = function(buffer, job)
      return vim.api.nvim_buf_is_valid(buffer)
        and vim.bo[buffer].buftype == "terminal"
        and vim.b[buffer].terminal_job_id == job
    end,
    running = function(job)
      return vim.fn.jobwait({ job }, 0)[1] == -1
    end,
    pid = vim.fn.jobpid,
    kill = vim.uv.kill,
    wait = function(timeout, check)
      return vim.wait(timeout, check, 25)
    end,
    focus = function(buffer)
      local windows = vim.fn.win_findbuf(buffer)
      if #windows == 0 then
        split(buffer)
      else
        vim.api.nvim_set_current_win(windows[1])
      end
      return true
    end,
    send = function(job, bytes)
      local ok, count = pcall(vim.fn.chansend, job, bytes)
      return ok and count == #bytes
    end,
    stop = function(job)
      return vim.fn.jobstop(job) == 1
    end,
    wipe = function(buffer)
      return pcall(vim.api.nvim_buf_delete, buffer, { force = true })
    end,
  })
end

M._test = { new = new }
return M
