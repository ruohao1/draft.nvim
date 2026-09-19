local M = {}
local backend_metadata = require("ai.transports.metadata")

local fields = {
  "key",
  "owner",
  "root",
  "backend",
  "state",
  "grants",
  "session",
  "opencode_token",
  "opencode_fingerprint",
  "opencode_version",
}
local prefix = "@draft_nvim"
local format = "#{pane_id}\t#{" .. prefix .. "}"
for _, field in ipairs(fields) do
  format = format .. "\t#{" .. prefix .. "_" .. field .. "}"
end

local function pane_valid(value)
  return type(value) == "string" and #value <= 16 and value:match("^%%%d+$") ~= nil
end

local function safe(value, limit)
  return type(value) == "string"
    and #value <= limit
    and not value:find("[%z\1-\31\127]")
    and not value:find("\194[\128-\159]")
end

local function hex(value, length)
  return safe(value, length) and #value == length and value:match("^[0-9a-f]+$") ~= nil
end

local function path_valid(value)
  return safe(value, 1024)
    and value:sub(1, 1) == "/"
    and value ~= "/"
    and vim.fs.normalize(value) == value
end

local function encode_root(value)
  return (
    value:gsub("([^A-Za-z0-9._/-])", function(byte)
      return string.format("%%%02X", string.byte(byte))
    end)
  )
end

local function decode_root(value)
  if not safe(value, 1024) then
    return nil
  end
  local decoded = value:gsub("%%(%x%x)", function(pair)
    return string.char(tonumber(pair, 16))
  end)
  if not path_valid(decoded) or encode_root(decoded) ~= value then
    return nil
  end
  return decoded
end

local function valid_metadata(data)
  if
    not hex(data.key, 32)
    or not pane_valid(data.owner)
    or not path_valid(data.root)
    or #encode_root(data.root) > 1024
  then
    return nil, "invalid pane ownership metadata"
  end
  return backend_metadata.validate(data)
end

local function invocation_valid(invocation)
  if
    type(invocation) ~= "table"
    or not safe(invocation.command, 16384)
    or invocation.command:sub(1, 5) ~= "exec "
    or type(invocation.argv) ~= "table"
    or not vim.islist(invocation.argv)
    or #invocation.argv == 0
    or #invocation.argv > 256
  then
    return false
  end
  for _, argument in ipairs(invocation.argv) do
    if not safe(argument, 8192) or argument == "" then
      return false
    end
  end
  return invocation.argv[1]:sub(1, 1) == "/"
end

local function argument(value)
  return value:sub(-1) == ";" and (value:sub(1, -2) .. "\\;") or value
end

local function new(deps)
  local identity
  local transport = {}

  local function bind(value)
    if
      type(value) ~= "table"
      or not hex(value.key, 32)
      or not path_valid(value.root)
      or not pane_valid(value.owner_pane)
      or not path_valid(value.tmux_socket)
      or not safe(value.namespace, 1200)
    then
      return nil, "invalid tmux identity or missing socket"
    end
    if
      identity
      and (
        identity.key ~= value.key
        or identity.root ~= value.root
        or identity.owner_pane ~= value.owner_pane
        or identity.namespace ~= value.namespace
        or identity.tmux_socket ~= value.tmux_socket
      )
    then
      return nil, "transport identity changed"
    end
    identity = vim.deepcopy(value)
    return true
  end

  local function run(args, options)
    if not identity then
      return nil, "transport has no identity"
    end
    local ok, err = deps.revalidate(deps.tmux)
    if not ok then
      return nil, err or "tmux executable changed"
    end
    if not deps.socket_valid(identity) then
      return nil, "tmux socket identity changed"
    end
    -- Preserve literal metadata separators even when the host locale is C.
    local argv = { deps.tmux, "-S", identity.tmux_socket, "-u" }
    vim.list_extend(argv, args)
    options = vim.tbl_extend("force", { text = true, timeout = 2000 }, options or {})
    local called, result = pcall(deps.run, argv, options)
    if
      not called
      or type(result) ~= "table"
      or result.code ~= 0
      or result.signal ~= 0
      or type(result.stdout) ~= "string"
    then
      return nil, "tmux " .. args[1] .. " failed"
    end
    return result.stdout
  end

  local function owned(pane, timeout)
    if not pane_valid(pane) then
      return nil, "invalid managed pane"
    end
    local output, err = run({
      "display-message",
      "-p",
      "-t",
      pane,
      "#{pane_id}\t#{"
        .. prefix
        .. "}\t#{"
        .. prefix
        .. "_key}\t#{"
        .. prefix
        .. "_owner}\t#{"
        .. prefix
        .. "_root}\t#{pane_pid}\t#{pane_dead}",
    }, { timeout = timeout or 2000 })
    if not output then
      return nil, err
    end
    local parts = vim.split(output:gsub("\n$", ""), "\t", { plain = true })
    if
      #parts ~= 7
      or parts[1] ~= pane
      or parts[2] ~= "1"
      or parts[3] ~= identity.key
      or parts[4] ~= identity.owner_pane
      or decode_root(parts[5]) ~= identity.root
      or not parts[6]:match("^%d+$")
      or #parts[6] > 10
      or tonumber(parts[6]) < 2
      or (parts[7] ~= "0" and parts[7] ~= "1")
    then
      return nil, "pane no longer belongs to this companion"
    end
    return { pid = tonumber(parts[6]), dead = parts[7] == "1" }
  end

  local function write_tags(pane, data, initial)
    local args = {}
    local function set(name, value)
      if #args > 0 then
        args[#args + 1] = ";"
      end
      vim.list_extend(args, { "set-option", "-pt", pane, name, argument(value) })
    end
    if initial then
      set(prefix, "0")
      set("remain-on-exit", "on")
      -- Bypassed terminal queries lose their pane routing on the reply path.
      -- Fence only this owned AI pane, before its native CLI can emit anything.
      set("allow-passthrough", "off")
    end
    -- Retagging never withdraws established ownership: a partial backend tuple
    -- fails discovery, but exact ownership must remain available for cleanup.
    for _, field in ipairs(fields) do
      if data[field] ~= nil then
        set(prefix .. "_" .. field, field == "root" and encode_root(data.root) or data[field])
      end
    end
    set(prefix, "1")
    local output, err = run(args)
    return output ~= nil or nil, err
  end

  function transport:discover(value)
    local ok, err = bind(value)
    if not ok then
      return nil, err
    end
    local output
    output, err = run({ "list-panes", "-a", "-F", format })
    if not output then
      return nil, err
    end
    if #output > 1024 * 1024 then
      return nil, "tmux discovery output is too large"
    end
    local panes = {}
    for line in output:gmatch("[^\n]+") do
      local parts = vim.split(line, "\t", { plain = true })
      if parts[2] == "1" and parts[3] == identity.key then
        if #parts ~= 12 or not pane_valid(parts[1]) then
          return nil, "malformed managed pane"
        end
        local data = { pane = parts[1] }
        for index, field in ipairs(fields) do
          data[field] = parts[index + 2]
        end
        data.root = decode_root(data.root)
        ok, err = valid_metadata(data)
        if not ok then
          return nil, err
        end
        if data.owner ~= identity.owner_pane or data.root ~= identity.root then
          return nil, "managed pane identity does not match its key"
        end
        panes[#panes + 1] = data
      end
    end
    return panes
  end

  -- Explicit cleanup can inspect ownership even when backend metadata is stale.
  -- This is not an adoption path: close() still rechecks the exact pane and PID.
  function transport:owned_panes(value)
    local bound, err = bind(value)
    if not bound then
      return nil, err
    end
    local ownership_format = "#{pane_id}\t#{"
      .. prefix
      .. "}\t#{"
      .. prefix
      .. "_key}\t#{"
      .. prefix
      .. "_owner}\t#{"
      .. prefix
      .. "_root}"
    local output = run({ "list-panes", "-a", "-F", ownership_format })
    if not output or #output > 1024 * 1024 then
      return nil, "managed ownership inspection failed"
    end
    local panes = {}
    for line in output:gmatch("[^\n]+") do
      local parts = vim.split(line, "\t", { plain = true })
      if parts[2] == "1" and parts[3] == identity.key then
        if
          #parts ~= 5
          or not pane_valid(parts[1])
          or parts[4] ~= identity.owner_pane
          or decode_root(parts[5]) ~= identity.root
        then
          return nil, "managed pane ownership does not match its key"
        end
        panes[#panes + 1] =
          { pane = parts[1], key = identity.key, owner = identity.owner_pane, root = identity.root }
      end
    end
    return panes
  end

  local function project_shell()
    if not deps.project_pairs then
      return false
    end
    local owner, err = run({
      "display-message",
      "-p",
      "-t",
      identity.owner_pane,
      "#{@dotfiles_project_shell}\t#{session_id}",
    })
    if not owner then
      return nil, err
    end
    local shell, editor = owner:match("^(.-)\t(%$%d+)\n$")
    if shell == "" then
      return false
    end
    if not shell or not shell:match("^%$%d+$") or shell == editor then
      return nil, "invalid project shell session"
    end
    local target
    target, err = run({
      "display-message",
      "-p",
      "-t",
      shell .. ":",
      "#{session_id}\t#{session_path}\t#{@dotfiles_project_role}\t#{@dotfiles_project_editor}",
    })
    if not target then
      return nil, err
    end
    if target ~= table.concat({ shell, identity.root, "shell", editor }, "\t") .. "\n" then
      return nil, "project shell session no longer matches this editor and worktree; run t again"
    end
    return shell
  end

  function transport:create(value, invocation)
    local ok, err = bind(value)
    if not ok then
      return nil, err
    end
    if not invocation_valid(invocation) then
      return nil, "invalid launcher invocation"
    end
    if deps.holder_valid and not deps.holder_valid() then
      return nil, "passive holder executable changed"
    end
    local width = deps.width or 40
    if
      type(width) ~= "number"
      or width % 1 ~= 0
      or width < 10
      or width > 80
      or not safe(deps.hold_command, 1024)
    then
      return nil, "invalid passive pane configuration"
    end
    local shell
    shell, err = project_shell()
    if shell == nil then
      return nil, err
    end
    local args = shell
        and {
          "new-window",
          "-d",
          "-P",
          "-F",
          "#{pane_id}",
          "-t",
          shell .. ":",
          "-n",
          "ai",
          "-c",
          identity.root,
          deps.hold_command,
        }
      or {
        "split-window",
        "-h",
        "-p",
        tostring(width),
        "-d",
        "-P",
        "-F",
        "#{pane_id}",
        "-t",
        identity.owner_pane,
        "-c",
        identity.root,
        deps.hold_command,
      }
    local output
    output, err = run(args)
    if not output then
      return nil, err
    end
    local pane = output:gsub("\n$", "")
    if not pane_valid(pane) or pane == identity.owner_pane then
      return nil, "invalid created pane handle"
    end
    local launch_attempted = false
    ok, err = write_tags(pane, {
      key = identity.key,
      owner = identity.owner_pane,
      root = identity.root,
      state = "starting",
    }, true)
    if ok then
      ok, err = owned(pane)
      if ok then
        launch_attempted = true
        output, err = run({ "respawn-pane", "-k", "-t", pane, invocation.command })
        ok = output ~= nil
      end
    end
    if not ok then
      local cleaned, cleanup_error = run({ "kill-pane", "-t", pane })
      if not cleaned then
        err = tostring(err) .. "; cleanup failed: " .. tostring(cleanup_error)
      end
      return nil, err, launch_attempted and "unknown" or "not_started"
    end
    return pane
  end

  function transport:tag(pane, data)
    if type(data) ~= "table" then
      return nil, "missing pane metadata"
    end
    local ok, err = valid_metadata(data)
    if not ok then
      return nil, err
    end
    if
      not identity
      or data.key ~= identity.key
      or data.owner ~= identity.owner_pane
      or data.root ~= identity.root
    then
      return nil, "tag would change pane ownership"
    end
    ok, err = owned(pane)
    if not ok then
      return nil, err
    end
    return write_tags(pane, data)
  end

  function transport:paste(pane, text)
    if not safe(text, 2048) or text == "" then
      return nil, "unsafe or empty context reference"
    end
    local current, err = owned(pane)
    if not current then
      return nil, err
    end
    if current.dead then
      return nil, "managed pane process has exited"
    end
    local nonce = deps.nonce()
    if not safe(nonce, 64) or not nonce:match("^[A-Za-z0-9_-]+$") then
      return nil, "invalid paste nonce"
    end
    local name = "draft.nvim-" .. identity.key .. "-" .. nonce
    local output
    output, err = run({ "load-buffer", "-b", name, "-" }, { stdin = text })
    if output then
      output, err = run({ "paste-buffer", "-b", name, "-t", pane })
    end
    local cleaned, cleanup_error = run({ "delete-buffer", "-b", name }, { timeout = 500 })
    if not cleaned then
      run({ "delete-buffer", "-b", name }, { timeout = 500 })
      return nil, tostring(err or "context pasted") .. "; " .. tostring(cleanup_error)
    end
    return output ~= nil or nil, err
  end

  function transport:focus(pane)
    local current, err = owned(pane)
    if not current then
      return nil, err
    end
    local output
    output, err = run({ "select-window", "-t", pane })
    if not output then
      return nil, err
    end
    output, err = run({ "select-pane", "-t", pane })
    return output ~= nil or nil, err
  end

  local function stop(pane, policy)
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
    local current, err = owned(pane)
    if not current then
      return nil, err
    end
    if not current.dead then
      local called, result = pcall(deps.kill, current.pid, policy.signal)
      if not called or result ~= 0 then
        return nil, "could not signal managed process"
      end
      local changed
      deps.wait(policy.timeout, function()
        local latest, query_error = owned(pane, math.max(1, math.min(100, policy.timeout)))
        if not latest or latest.pid ~= current.pid then
          changed = query_error or "managed process changed while stopping"
          return true
        end
        return latest.dead
      end)
      if changed then
        return nil, changed
      end
    end
    -- Recheck ownership after waiting, including when a process ignores the signal.
    local latest
    latest, err = owned(pane)
    if not latest or latest.pid ~= current.pid then
      return nil, err or "managed process changed"
    end
    return true
  end

  function transport:respawn(pane, invocation, policy)
    if not invocation_valid(invocation) then
      return nil, "invalid launcher invocation", "not_started"
    end
    local ok, err = stop(pane, policy)
    if not ok then
      return nil, err, "not_started"
    end
    local output
    output, err = run({ "set-option", "-pt", pane, "allow-passthrough", "off" })
    if not output then
      return nil, err, "not_started"
    end
    output, err = run({ "respawn-pane", "-k", "-t", pane, invocation.command })
    return output ~= nil or nil, err
  end

  function transport:close(pane, policy)
    local ok, err = stop(pane, policy)
    if not ok then
      return nil, err
    end
    local output
    output, err = run({ "kill-pane", "-t", pane })
    return output ~= nil or nil, err
  end

  function transport:shutdown()
    -- A tmux companion belongs to the owning pane, not this Neovim process.
  end

  return transport
end

function M.new(options)
  options = options or {}
  if not path_valid(options.tmux) then
    return nil, "canonical tmux executable is required"
  end
  local tools = require("ai.tools")
  local executable, err = tools.resolve(options.tmux)
  if not executable or executable ~= options.tmux then
    return nil, err or "tmux path is not canonical"
  end
  local sleep
  sleep, err = tools.resolve("sleep")
  if not sleep then
    return nil, err
  end
  local counter = 0
  return new({
    tmux = executable,
    project_pairs = options.project_pairs == true,
    width = options.width or 40,
    hold_command = "exec '" .. sleep:gsub("'", "'\\''") .. "' '2147483647'",
    holder_valid = function()
      return tools.revalidate(sleep)
    end,
    revalidate = tools.revalidate,
    socket_valid = function(identity)
      local stat = vim.uv.fs_lstat(identity.tmux_socket)
      return stat
        and stat.type == "socket"
        and stat.uid == vim.uv.getuid()
        and vim.uv.fs_realpath(identity.tmux_socket) == identity.tmux_socket
        and identity.namespace
          == string.format("tmux:%s:%s:%s", identity.tmux_socket, stat.dev, stat.ino)
    end,
    run = function(argv, run_options)
      return vim
        .system(argv, {
          text = true,
          stdin = run_options.stdin,
          clear_env = true,
          env = { LC_ALL = "C" },
        })
        :wait(run_options.timeout)
    end,
    kill = vim.uv.kill,
    wait = function(timeout, check)
      return vim.wait(timeout, check, 25)
    end,
    nonce = function()
      counter = counter + 1
      return string.format(
        "%d_%s_%d",
        vim.fn.getpid(),
        tostring(vim.uv.hrtime()):gsub("[^%w]", ""),
        counter
      )
    end,
  })
end

M._test = { new = new }
return M
