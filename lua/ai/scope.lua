-- Temporary writable paths are approved here, but published only by the session.
local M = {}
local display_names = { claude = "Claude", codex = "Codex", opencode = "OpenCode" }

local function response(ok, code, message)
  return { schema = 1, ok = ok, code = code, message = message }
end

local function text(value, limit)
  return type(value) == "string"
    and #value > 0
    and #value <= limit
    and not value:find("[%z\1-\31\127]")
    and not value:find("\194[\128-\159]")
    and require("ai.review.reducer").is_text(value)
end

local function within(base, path)
  return path == base or path:sub(1, #base + 1) == base .. "/"
end

local function timer(milliseconds, callback)
  local handle = assert(vim.uv.new_timer())
  handle:start(milliseconds, 0, vim.schedule_wrap(callback))
  return function()
    if not handle:is_closing() then
      handle:stop()
      handle:close()
    end
  end
end

-- Preserve missing provider leaves while resolving their existing ancestors.
local function physical(path)
  if not text(path, 4096) or path:sub(1, 1) ~= "/" then
    return nil
  end
  local resolved = vim.uv.fs_realpath(path)
  if resolved then
    return resolved
  end
  local stat, _, code = vim.uv.fs_lstat(path)
  if stat or code ~= "ENOENT" then
    return nil
  end
  local parent = vim.fs.dirname(path)
  if parent == path then
    return nil
  end
  parent = physical(parent)
  return parent and vim.fs.joinpath(parent, vim.fs.basename(path)) or nil
end

local function same_socket(path, expected)
  local stat = vim.uv.fs_lstat(path)
  return stat
    and stat.type == "socket"
    and stat.uid == vim.uv.getuid()
    and stat.ino == expected.ino
    and stat.dev == expected.dev
end

local function socket_probe(path)
  local probe = assert(vim.uv.new_pipe(false))
  local completed, failure = false, nil
  probe:connect(path, function(err)
    completed, failure = true, err
  end)
  local waited = vim.wait(100, function()
    return completed
  end, 5)
  probe:close()
  return waited and failure and failure:find("ECONNREFUSED", 1, true) ~= nil
end

local function bind_socket(path, ffi)
  if #path > 107 then
    return nil
  end
  local address = ffi.new("nvim_ai_scope_sockaddr")
  address.family = 1 -- AF_UNIX on the supported Linux runtime.
  ffi.copy(address.path, path)
  local descriptor = ffi.C.socket(1, 1 + 524288 + 2048, 0) -- STREAM | CLOEXEC | NONBLOCK
  if descriptor < 0 then
    return nil
  end
  if ffi.C.bind(descriptor, address, ffi.sizeof(address)) ~= 0 then
    ffi.C.close(descriptor)
    return nil
  end
  local stat = vim.uv.fs_lstat(path)
  local handle = assert(vim.uv.new_pipe(false))
  -- Adopt a bound descriptor: uv_pipe_bind's implicit unlink-on-close cannot
  -- preserve a path which another process replaced. We unlink only our inode.
  if not handle:open(descriptor) then
    ffi.C.close(descriptor)
    handle:close()
    if stat and same_socket(path, stat) then
      vim.uv.fs_unlink(path)
    end
    return nil
  end
  return handle, stat
end

local function decode_request(bytes)
  if bytes:sub(-1) ~= "\n" or select(2, bytes:gsub("\n", "")) ~= 1 then
    return nil
  end
  -- The protocol is a flat five-key object. Counting colons outside strings
  -- also rejects duplicate JSON keys, which the JSON decoder otherwise merges.
  local quoted, escaped, colons = false, false, 0
  for index = 1, #bytes do
    local byte = bytes:sub(index, index)
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
  local ok, payload = pcall(vim.json.decode, bytes)
  return ok and payload or nil
end

function M.new(options)
  if
    type(options) ~= "table"
    or not options.identity
    or not options.store
    or not options.session
  then
    return nil, "AI scope dependencies are unavailable"
  end
  local store, session = options.store, options.session
  local identity = vim.deepcopy(options.identity)
  local broker = {}
  local running, token, pending, unsubscribe = false, nil, nil, nil
  local server, socket_path, socket_stat, ffi
  local clients = {}
  local start_timer = options.timer or timer
  local confirm = options.confirm
    or function(message, callback)
      vim.ui.select({ "Cancel", "Approve" }, { prompt = message }, function(choice)
        callback(choice == "Approve")
      end)
    end

  local function finish(transaction, result)
    if pending ~= transaction then
      return
    end
    pending = nil
    if transaction.cancel_timer then
      transaction.cancel_timer()
    end
    if options.on_result then
      pcall(options.on_result, vim.deepcopy(result))
    end
    pcall(transaction.callback, result)
  end

  local function refuse(callback, code, message)
    local result = response(false, code, message)
    if options.on_result then
      pcall(options.on_result, vim.deepcopy(result))
    end
    pcall(callback, result)
  end

  local function check_path(path, grants)
    if not text(path, 4096) or path:sub(1, 1) ~= "/" then
      return nil, "invalid_path"
    end
    local canonical = vim.uv.fs_realpath(path)
    local stat = canonical and vim.uv.fs_lstat(canonical)
    if
      not canonical
      or canonical == "/"
      or not text(canonical, 4096)
      or not stat
      or (stat.type ~= "file" and stat.type ~= "directory")
    then
      return nil, "invalid_path"
    end
    if canonical == identity.root then
      return nil, "already_writable"
    end
    local protected = { store:runtime_root(), store:state_root() }
    for _, value in pairs({
      identity.git_dir,
      identity.git_common_dir,
      identity.git_entry,
      identity.tmux_socket,
    }) do
      protected[#protected + 1] = value
    end
    local home = options.home or vim.env.HOME
    if home then
      local data_home = options.data_home or vim.env.XDG_DATA_HOME
      if not data_home or data_home == "" then
        data_home = home .. "/.local/share"
      end
      local config_home = options.config_home or vim.env.XDG_CONFIG_HOME
      if not config_home or config_home == "" then
        config_home = home .. "/.config"
      end
      vim.list_extend(protected, {
        home .. "/.codex",
        home .. "/.claude",
        home .. "/.claude.json",
        home .. "/.opencode",
        home .. "/.config/opencode",
        data_home .. "/opencode",
        config_home .. "/opencode",
      })
    end
    vim.list_extend(protected, options.protected_paths or {})
    for _, protected_path in pairs(protected) do
      local protected_physical = physical(protected_path)
      if not protected_physical then
        return nil, "protected_path"
      end
      if within(protected_physical, canonical) or within(canonical, protected_physical) then
        return nil, "protected_path"
      end
    end
    if within(identity.root, canonical) then
      return nil, "already_writable"
    end
    for _, grant in ipairs(grants) do
      if canonical == grant then
        return nil, "duplicate"
      end
      if within(grant, canonical) then
        return nil, "already_writable"
      end
    end
    return canonical, nil, stat
  end

  local function connected(client)
    if not client then
      return true
    end
    if client.closed or client.pipe:is_closing() then
      return false
    end
    client.pollfd[0].revents = 0
    -- Linux POLLHUP/POLLERR/POLLNVAL only: unlike UV_DISCONNECT/POLLRDHUP,
    -- events=0 does not mistake the client's required SHUT_WR for full close.
    return ffi.C.poll(client.pollfd, 1, 0) == 0
  end

  local function close_client(client)
    if client.closed then
      return
    end
    client.closed = true
    clients[client] = nil
    if client.cancel_idle then
      client.cancel_idle()
    end
    if client.watch then
      client.watch:stop()
      client.watch:close()
    end
    if pending and pending.client == client and not pending.applying then
      finish(pending, response(false, "disconnected", "Scope client disconnected."))
    end
    if not client.pipe:is_closing() then
      client.pipe:read_stop()
      client.pipe:close()
    end
  end

  local function reply(client, value)
    if client.closed then
      return
    end
    if client.watch then
      client.watch:stop()
      client.watch:close()
      client.watch = nil
    end
    local ok, written = pcall(
      client.pipe.write,
      client.pipe,
      vim.json.encode(value) .. "\n",
      function()
        close_client(client)
      end
    )
    if not ok or not written then
      close_client(client)
    end
  end

  local request
  local function accept_client(err)
    if err or not running then
      return
    end
    local pipe = assert(vim.uv.new_pipe(false))
    if not server:accept(pipe) then
      pipe:close()
      return
    end
    local client = { pipe = pipe, bytes = "" }
    clients[client] = true
    if vim.tbl_count(clients) > 16 then
      close_client(client)
      return
    end
    client.pollfd = ffi.new("nvim_ai_scope_pollfd[1]")
    client.pollfd[0].fd = assert(pipe:fileno())
    client.cancel_idle = start_timer(5000, function()
      reply(client, response(false, "timeout", "Scope request input timed out."))
    end)
    pipe:read_start(function(read_error, bytes)
      if client.closed then
        return
      end
      if read_error then
        close_client(client)
        return
      end
      if bytes then
        if #client.bytes + #bytes > 8192 then
          pipe:read_stop()
          vim.schedule(function()
            reply(client, response(false, "request_too_large", "Scope request limit exceeded."))
          end)
          return
        end
        client.bytes = client.bytes .. bytes
        return
      end
      pipe:read_stop()
      client.cancel_idle()
      client.cancel_idle = nil
      vim.schedule(function()
        if client.closed or not connected(client) then
          close_client(client)
          return
        end
        local payload = decode_request(client.bytes)
        client.bytes = nil
        if not payload then
          reply(client, response(false, "invalid_request", "Invalid scope request."))
          return
        end
        client.watch = assert(vim.uv.new_timer())
        client.watch:start(
          50,
          50,
          vim.schedule_wrap(function()
            if not connected(client) then
              close_client(client)
            end
          end)
        )
        request(payload, function(value)
          reply(client, value)
        end, client)
      end)
    end)
  end

  function broker:start()
    if running then
      return true
    end
    if vim.uv.os_uname().sysname ~= "Linux" then
      return nil, "AI scope execution requires Linux"
    end
    local ok
    ok, ffi = pcall(require, "ffi")
    if not ok then
      return nil, "AI scope disconnect monitoring is unavailable"
    end
    if not pcall(ffi.typeof, "nvim_ai_scope_pollfd") then
      ffi.cdef([[
        typedef struct { int fd; short events; short revents; } nvim_ai_scope_pollfd;
        int poll(nvim_ai_scope_pollfd *fds, unsigned long nfds, int timeout);
        typedef struct { unsigned short family; char path[108]; } nvim_ai_scope_sockaddr;
        int socket(int domain, int type, int protocol);
        int bind(int fd, const void *address, unsigned int length);
        int close(int fd);
      ]])
    end
    local runtime = store:runtime_dir()
    local stat = vim.uv.fs_lstat(runtime)
    if
      not stat
      or stat.type ~= "directory"
      or stat.uid ~= vim.uv.getuid()
      or stat.mode % 512 ~= 448
      or vim.uv.fs_realpath(runtime) ~= runtime
    then
      return nil, "AI scope runtime directory is unsafe"
    end
    socket_path = runtime .. "/control.sock"
    local existing = vim.uv.fs_lstat(socket_path)
    if existing then
      if
        existing.type ~= "socket"
        or existing.uid ~= vim.uv.getuid()
        or not socket_probe(socket_path)
        or not same_socket(socket_path, existing)
        or not vim.uv.fs_unlink(socket_path)
      then
        return nil, "AI scope socket is live or unsafe"
      end
    end
    local token_error
    token, token_error = store:read_control_token()
    if token_error or (not token and session:snapshot().pane) then
      return nil, "AI surviving control token is unavailable; reconcile the companion first"
    end
    if not token then
      token = store:ensure_control_token(function()
        return vim.uv.random(16):gsub(".", function(byte)
          return string.format("%02x", byte:byte())
        end)
      end)
    end
    if not token then
      return nil, "AI control token is unavailable"
    end
    server, socket_stat = bind_socket(socket_path, ffi)
    if not server then
      return nil, "AI scope socket bind failed"
    end
    if not socket_stat or not vim.uv.fs_chmod(socket_path, 384) then
      self:stop()
      return nil, "AI scope socket is unsafe"
    end
    running = true
    if not server:listen(16, accept_client) then
      self:stop()
      return nil, "AI scope socket listen failed"
    end
    unsubscribe = session:subscribe(function(snapshot)
      if
        pending
        and not pending.applying
        and (
          snapshot.pane ~= pending.snapshot.pane
          or snapshot.review_id ~= pending.snapshot.review_id
          or snapshot.backend ~= pending.snapshot.backend
          or snapshot.state == "closed"
        )
      then
        finish(pending, response(false, "closed", "The owning companion changed or closed."))
      end
    end)
    return true
  end

  function broker:list()
    return vim.deepcopy(session:snapshot().grants)
  end

  request = function(payload, callback, client)
    if type(callback) ~= "function" then
      return nil, "AI scope callback is required"
    end
    if not running then
      return refuse(callback, "not_running", "The scope broker is not running.")
    end
    if pending then
      return refuse(callback, "busy", "A scope transaction is already pending.")
    end
    local keys = { schema = true, operation = true, token = true, path = true, reason = true }
    local count = 0
    if type(payload) ~= "table" then
      return refuse(callback, "invalid_request", "Invalid scope request.")
    end
    for key in pairs(payload) do
      if not keys[key] then
        return refuse(callback, "invalid_request", "Invalid scope request.")
      end
      count = count + 1
    end
    if count ~= 5 or payload.schema ~= 1 or payload.operation ~= "request_scope" then
      return refuse(callback, "invalid_request", "Invalid scope request.")
    end
    token = store:read_control_token()
    if not token or payload.token ~= token then
      return refuse(callback, "unauthorized", "Invalid control token.")
    end
    if not text(payload.reason, 512) or not payload.reason:find("%S") then
      return refuse(callback, "invalid_reason", "A bounded, printable reason is required.")
    end
    local snapshot = session:snapshot()
    if not snapshot.review_id then
      return refuse(callback, "no_review", "An active review batch is required.")
    end
    if not snapshot.pane or not display_names[snapshot.backend] or not snapshot.transfer_ready then
      return refuse(callback, "closed", "The owning companion is not ready.")
    end
    local path, code, stat = check_path(payload.path, snapshot.grants)
    if not path then
      return refuse(callback, code, "The requested path cannot be granted.")
    end
    local transaction = { callback = callback, snapshot = snapshot, client = client }
    pending = transaction
    transaction.cancel_timer = start_timer(30000, function()
      if not transaction.applying then
        finish(
          transaction,
          response(false, "timeout", "Scope confirmation expired; nothing was granted.")
        )
      end
    end)
    local message = table.concat({
      "Backend: " .. display_names[snapshot.backend],
      "Owner pane: " .. (identity.owner_pane or "standalone Neovim terminal"),
      "Physical root: " .. identity.root,
      "Requested path: " .. path,
      "Reason: " .. payload.reason,
      "Approval restarts the TUI with this path writable and does not continue the pending turn.",
    }, "\n")
    local called = pcall(confirm, message, function(approved)
      if pending ~= transaction or transaction.applying then
        return
      end
      if approved ~= true then
        return finish(transaction, response(false, "denied", "Scope request cancelled."))
      end
      local current = session:snapshot()
      local checked, _, checked_stat = check_path(payload.path, current.grants)
      if
        not running
        or not connected(client)
        or store:read_control_token() ~= payload.token
        or not current.transfer_ready
        or current.pane ~= snapshot.pane
        or current.review_id ~= snapshot.review_id
        or current.backend ~= snapshot.backend
        or not vim.deep_equal(current.grants, snapshot.grants)
        or not vim.deep_equal(current.sessions, snapshot.sessions)
        or checked ~= path
        or not checked_stat
        or checked_stat.dev ~= stat.dev
        or checked_stat.ino ~= stat.ino
        or checked_stat.type ~= stat.type
      then
        return finish(
          transaction,
          response(false, "state_changed", "Scope state changed; request again.")
        )
      end
      transaction.applying = true
      local grants = broker:list()
      grants[#grants + 1] = path
      table.sort(grants)
      local ok, granted = pcall(session.set_grants, session, grants)
      if ok and granted then
        finish(transaction, response(true, "granted", "Scope approved; the TUI was restarted."))
      else
        finish(
          transaction,
          response(false, "relaunch_failed", "Scope change failed; no grant was confirmed.")
        )
      end
    end)
    if not called then
      finish(transaction, response(false, "denied", "Scope confirmation failed."))
    end
  end

  function broker:request(payload, callback)
    return request(payload, callback)
  end

  function broker:revoke(path, callback)
    if type(callback) ~= "function" then
      return nil, "AI scope callback is required"
    end
    if not running then
      return refuse(callback, "not_running", "The scope broker is not running.")
    end
    if pending then
      return refuse(callback, "busy", "A scope transaction is already pending.")
    end
    local grants = {}
    local found = false
    for _, grant in ipairs(self:list()) do
      if grant ~= path then
        grants[#grants + 1] = grant
      else
        found = true
      end
    end
    if not found then
      return refuse(callback, "invalid_path", "The path is not an active grant.")
    end
    local transaction = { callback = callback, applying = true }
    pending = transaction
    local ok, revoked = pcall(session.set_grants, session, grants)
    if ok and revoked then
      finish(transaction, response(true, "revoked", "Scope revoked; the TUI was restarted."))
    else
      finish(transaction, response(false, "relaunch_failed", "Scope revocation failed."))
    end
  end

  function broker:stop()
    running = false
    if pending and not pending.applying then
      finish(pending, response(false, "not_running", "The scope broker stopped."))
    end
    if unsubscribe then
      unsubscribe()
      unsubscribe = nil
    end
    for client in pairs(clients) do
      close_client(client)
    end
    local cleaned = true
    if socket_stat and vim.uv.fs_lstat(socket_path) then
      cleaned = same_socket(socket_path, socket_stat) and vim.uv.fs_unlink(socket_path) ~= nil
    end
    if server then
      server:close()
      server = nil
    end
    if not cleaned then
      return nil, "AI scope socket changed or cleanup failed"
    end
    socket_stat = nil
    return true
  end

  function broker:clear_for_close(callback)
    if type(callback) ~= "function" then
      return nil, "AI scope callback is required"
    end
    local snapshot = session:snapshot()
    if
      snapshot.pane
      or snapshot.state ~= "closed"
      or not session:attach()
      or session:snapshot().pane
    then
      return refuse(
        callback,
        "pane_alive",
        "Close the managed pane before clearing its scope broker."
      )
    end
    if not self:stop() or not store:remove_control_token() then
      return refuse(callback, "cleanup_failed", "The closed companion requires private cleanup.")
    end
    token = nil
    pcall(callback, response(true, "cleared", "Closed companion scope was cleared."))
  end

  return broker
end

return M
