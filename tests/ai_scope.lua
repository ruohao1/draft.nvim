-- Public scope/session contracts with private state and simulated CLI processes.
local function eq(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    label .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual)
  )
end

local scope = require("ai.scope")
local uv = vim.uv
local base = assert(uv.fs_mkdtemp("/tmp/ai-scope-XXXXXX"))
assert(uv.fs_chmod(base, 448))
local cleanups = {}
local sequence = 0
local function directory(path)
  vim.fn.mkdir(path, "p", 448)
  assert(uv.fs_chmod(path, 448))
  return path
end

local function fixture(standalone)
  sequence = sequence + 1
  local f = { base = directory(base .. "/" .. sequence), prompts = {}, timers = {} }
  f.home = directory(f.base .. "/home")
  f.outside = directory(f.base .. "/outside")
  f.identity = {
    key = string.rep("a", 32),
    root = directory(f.base .. "/repo"),
    inside_git = true,
    git_dir = directory(f.base .. "/git/worktrees/repo"),
    git_common_dir = f.base .. "/git",
    git_entry = f.base .. "/repo/.git",
    owner_pane = "%12",
    tmux_socket = f.base .. "/tmux.sock",
    namespace = "tmux:fixture",
  }
  if standalone then
    f.identity.owner_pane, f.identity.tmux_socket = nil, nil
    f.identity.namespace = "nvim:fixture"
  end
  local old_runtime, old_state = vim.env.XDG_RUNTIME_DIR, vim.env.XDG_STATE_HOME
  vim.env.XDG_RUNTIME_DIR = directory(f.base .. "/run")
  vim.env.XDG_STATE_HOME = directory(f.base .. "/state")
  f.store = assert(require("ai.state").open(f.identity))
  vim.env.XDG_RUNTIME_DIR, vim.env.XDG_STATE_HOME = old_runtime, old_state
  local uuid = "11111111-1111-4111-8111-111111111111"
  -- Simulated provider/process adapters avoid invoking an installed CLI.
  local backend = {
    new_session = function()
      return { backend = "claude", session = uuid }
    end,
    resume_session = function()
      return { backend = "claude", session = uuid }
    end,
    session_reference = function(_, launch)
      return launch.session
    end,
    capabilities = function()
      return { busy = true, approval = true, completion = true }
    end,
    suspend = function()
      return { signal = 1, timeout = 2000 }
    end,
    stop = function()
      return { signal = 15, timeout = 2000 }
    end,
  }
  local transport = {
    discover = function()
      return f.panes or {}
    end,
    create = function()
      f.alive = true
      return "%40"
    end,
    respawn = function()
      if f.fail_relaunch then
        f.fail_relaunch = false
        return nil, "failed", "not_started"
      end
      f.alive = true
      return true
    end,
    tag = function(_, pane, metadata)
      f.panes = { vim.tbl_extend("force", { pane = pane }, metadata) }
      return true
    end,
    close = function()
      f.alive = false
      f.panes = {}
      return true
    end,
  }
  f.session = assert(require("ai.session").new({
    identity = f.identity,
    store = f.store,
    transport = transport,
    registry = {
      get = function()
        return backend
      end,
      health = function()
        return { installed = true, version = "1.0.0", auth = "authenticated", error = "" }
      end,
    },
    sandbox = {
      prepare = function(options)
        local path = assert(options.write_manifest({ token = options.token }))
        return { token = options.token, path = path, argv = { "simulated-provider" } }
      end,
    },
    home = f.home,
    data_home = directory(f.home .. "/data"),
    tools = { git = "/usr/bin/git", tmux = "/usr/bin/tmux" },
    token = function()
      return f.next_token or string.rep("b", 32)
    end,
  }))
  assert(f.session:prepare_review("review_0123456789abcdef"))
  assert(f.session:open("claude"))
  f.options = {
    identity = f.identity,
    store = f.store,
    session = f.session,
    home = f.home,
    protected_paths = { f.home .. "/provider" },
    timer = function(milliseconds, callback)
      local timer = { milliseconds = milliseconds, callback = callback, active = true }
      f.timers[#f.timers + 1] = timer
      return function()
        timer.active = false
      end
    end,
    confirm = function(message, callback)
      f.prompts[#f.prompts + 1] = message
      if f.defer then
        f.answer = callback
      else
        callback(f.approved ~= false)
      end
    end,
  }
  f.broker = assert(scope.new(f.options))
  cleanups[#cleanups + 1] = function()
    f.broker:stop()
    f.session:close()
  end
  assert(f.broker:start())
  function f:request(path, changes)
    local response
    self.broker:request(
      vim.tbl_extend("force", {
        schema = 1,
        operation = "request_scope",
        token = string.rep("b", 32),
        path = path or self.outside,
        reason = "generate a fixture",
      }, changes or {}),
      function(value)
        response = value
      end
    )
    return response
  end
  return f
end

local ok, err = xpcall(function()
  local standalone = fixture(true)
  eq(standalone:request().code, "granted", "standalone terminal can request scope")
  assert(
    standalone.prompts[1]:find("standalone Neovim terminal", 1, true),
    "fallback owner is explicit"
  )
  local f = fixture()
  assert(uv.fs_symlink(f.outside, f.base .. "/link"))
  eq(f:request(f.base .. "/link").code, "granted", "canonical scope approved")
  eq(f.broker:list(), { f.outside }, "approved canonical grant")
  eq(f.session:snapshot().grants, { f.outside }, "session owns approved grants")
  for _, text in ipairs({
    "Claude",
    "%12",
    f.identity.root,
    f.outside,
    "generate a fixture",
    "Approval restarts the TUI with this path writable and does not continue the pending turn.",
  }) do
    assert(f.prompts[1]:find(text, 1, true), "approval omitted " .. text)
  end
  local revoked
  f.broker:revoke(f.outside, function(value)
    revoked = value
  end)
  eq(revoked.code, "revoked", "revocation succeeds")
  eq(f.broker:list(), {}, "revocation removes scope")

  -- Exact refusal classes all leave the public grant list unchanged.
  local refusals = {
    { { schema = 2 }, "invalid_request" },
    { { schema = true }, "invalid_request" },
    { { operation = "execute" }, "invalid_request" },
    { { extra = "ignored?" }, "invalid_request" },
    { { token = string.rep("c", 32) }, "unauthorized" },
    { { path = vim.NIL }, "invalid_path" },
    { { path = "relative" }, "invalid_path" },
    { { path = f.base .. "/missing" }, "invalid_path" },
    { { path = "/" }, "invalid_path" },
    { { path = f.outside .. "\n" }, "invalid_path" },
    { { path = "/" .. string.rep("x", 4096) }, "invalid_path" },
    { { reason = "" }, "invalid_reason" },
    { { reason = " " }, "invalid_reason" },
    { { reason = string.rep("x", 513) }, "invalid_reason" },
    { { reason = "escape\27" }, "invalid_reason" },
    { { reason = string.char(255) }, "invalid_reason" },
    { { path = f.identity.root }, "already_writable" },
    { { path = directory(f.identity.root .. "/nested") }, "already_writable" },
    { { path = f.identity.git_dir }, "protected_path" },
    { { path = f.identity.git_common_dir }, "protected_path" },
    { { path = f.store:runtime_root() }, "protected_path" },
    { { path = f.store:state_root() }, "protected_path" },
    { { path = f.home }, "protected_path" },
    { { path = directory(f.home .. "/provider") }, "protected_path" },
    { { path = f.base }, "protected_path" },
  }
  local prompt_count = #f.prompts
  for _, refusal in ipairs(refusals) do
    eq(f:request(nil, refusal[1]).code, refusal[2], "refused unsafe scope")
    eq(f.broker:list(), {}, "refusal grants nothing")
  end
  eq(#f.prompts, prompt_count, "invalid requests never open a prompt")
  f.approved = false
  eq(f:request().code, "denied", "confirmation refusal")
  f.approved = true
  eq(f:request().code, "granted", "approve after refused requests")
  eq(f:request().code, "duplicate", "duplicate scope does not relaunch")
  f.broker:revoke(f.outside, function(value)
    eq(value.code, "revoked", "remove fixture grant")
  end)
  f.fail_relaunch = true
  eq(f:request().code, "relaunch_failed", "failed relaunch reports refusal")
  eq(f.broker:list(), {}, "failed relaunch restores old grants")

  local pending = fixture()
  pending.defer = true
  eq(pending:request(), nil, "confirmation is asynchronous")
  local late_answer = pending.answer
  eq(pending:request().code, "busy", "one pending transaction per pane")
  eq(#pending.prompts, 1, "busy request never opens another prompt")
  local transaction_timer = pending.timers[#pending.timers]
  eq(transaction_timer.milliseconds, 30000, "confirmation deadline")
  transaction_timer.callback()
  late_answer(true)
  eq(pending.broker:list(), {}, "expired approval grants nothing")
  pending:request()
  late_answer = pending.answer
  assert(pending.session:close())
  late_answer(true)
  eq(pending.broker:list(), {}, "closed-pane approval grants nothing")
  pending.broker:stop()
  eq(pending:request().code, "not_running", "stopped broker refuses")

  local no_review = fixture()
  assert(no_review.session:finish_review("review_0123456789abcdef"))
  eq(no_review:request().code, "no_review", "scope requires active review batch")
  eq(no_review.broker:list(), {}, "missing batch grants nothing")

  -- The shipped Python client half-closes its request and keeps reading.
  local socket_fixture = fixture()
  local socket_path = socket_fixture.store:runtime_dir() .. "/control.sock"
  local helper = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
    .. "/../scripts/nvim-ai-control.py"
  local function client(f)
    local result
    local process = vim.system({
      "/usr/bin/python3",
      "-I",
      "-B",
      helper,
      "request-scope",
      "--path",
      f.outside,
      "--reason",
      "native socket fixture",
    }, {
      env = {
        NVIM_AI_CONTROL_SOCKET = f.store:runtime_dir() .. "/control.sock",
        NVIM_AI_CONTROL_TOKEN = string.rep("b", 32),
      },
    }, function(value)
      result = value
    end)
    return process, function()
      return result
    end
  end
  local process, result = client(socket_fixture)
  assert(vim.wait(2000, function()
    return result() ~= nil
  end))
  eq(result().code, 0, "native Python client receives approval")
  eq(socket_fixture.broker:list(), { socket_fixture.outside }, "wire request owns one grant")
  local saved_token = assert(socket_fixture.store:read_control_token())
  local competing = assert(scope.new(socket_fixture.options))
  assert(not competing:start(), "a live broker socket cannot be replaced")
  assert(socket_fixture.broker:stop())
  eq(socket_fixture.store:read_control_token(), saved_token, "ordinary stop retains pane token")
  eq(socket_fixture.broker:list(), { socket_fixture.outside }, "ordinary stop retains grants")
  assert(not uv.fs_lstat(socket_path), "stop removes owned socket")
  assert(socket_fixture.broker:start())
  local cleared
  socket_fixture.broker:clear_for_close(function(value)
    cleared = value
  end)
  eq(cleared.code, "pane_alive", "clear refuses a surviving pane")
  assert(socket_fixture.session:close())
  socket_fixture.broker:clear_for_close(function(value)
    cleared = value
  end)
  eq(cleared.code, "cleared", "explicit pane close clears broker")
  eq(socket_fixture.store:read_control_token(), nil, "closed companion loses control token")
  assert(not uv.fs_lstat(socket_path), "closed companion loses socket")

  local disconnected = fixture()
  disconnected.defer = true
  process, result = client(disconnected)
  assert(
    vim.wait(2000, function()
      return disconnected.answer ~= nil
    end),
    "wire confirmation opened"
  )
  process:kill(15)
  assert(
    vim.wait(2000, function()
      return result() ~= nil
    end),
    "client terminated"
  )
  disconnected.answer(true)
  eq(disconnected.broker:list(), {}, "fully disconnected client cannot approve late")

  local bounded = fixture()
  local function raw_request(bytes)
    local pipe = assert(uv.new_pipe(false))
    local result = ""
    local complete = false
    assert(pipe:connect(bounded.store:runtime_dir() .. "/control.sock", function(error)
      assert(not error, error)
      assert(pipe:read_start(function(read_error, chunk)
        assert(not read_error, read_error)
        if chunk then
          result = result .. chunk
        else
          complete = true
          pipe:close()
        end
      end))
      assert(pipe:write(bytes))
      pipe:shutdown()
    end))
    assert(
      vim.wait(2000, function()
        return complete
      end),
      "bounded request completed"
    )
    return vim.json.decode(result)
  end
  eq(raw_request(string.rep("x", 8193)).code, "request_too_large", "request byte limit")
  eq(
    raw_request(
      '{"schema":1,"schema":1,"operation":"request_scope","token":"'
        .. string.rep("b", 32)
        .. '","path":"/outside","reason":"reason"}\n'
    ).code,
    "invalid_request",
    "duplicate wire keys"
  )
  eq(raw_request("{}\n{}\n").code, "invalid_request", "only one request line")

  local replaced = fixture()
  local replaced_path = replaced.store:runtime_dir() .. "/control.sock"
  assert(uv.fs_unlink(replaced_path))
  local descriptor = assert(uv.fs_open(replaced_path, "wx", 384))
  assert(uv.fs_write(descriptor, "replacement must survive", 0))
  assert(uv.fs_close(descriptor))
  assert(not replaced.broker:stop(), "socket replacement is reported")
  eq(
    vim.fn.readfile(replaced_path),
    { "replacement must survive" },
    "stop preserves unrelated replacement"
  )

  local files = fixture()
  local file = files.outside .. "/fixture.txt"
  descriptor = assert(uv.fs_open(file, "wx", 384))
  assert(uv.fs_write(descriptor, "one file only", 0))
  assert(uv.fs_close(descriptor))
  eq(files:request(file).code, "granted", "individual regular file can be granted")
  eq(files.broker:list(), { file }, "file grant never expands to its parent")

  local lost_token = fixture()
  assert(lost_token.broker:stop())
  assert(lost_token.store:remove_control_token())
  assert(not lost_token.broker:start(), "surviving pane cannot silently acquire a new token")
  eq(lost_token.store:read_control_token(), nil, "missing surviving token remains absent")

  local new_pane = fixture()
  assert(new_pane.session:close())
  new_pane.next_token = string.rep("c", 32)
  assert(new_pane.session:open("claude"))
  eq(new_pane:request().code, "unauthorized", "old pane token cannot approve scope")
  eq(
    new_pane:request(nil, { token = new_pane.next_token }).code,
    "granted",
    "running broker follows coordinator-created token for a new pane"
  )

  local explicit = fixture()
  explicit.defer = true
  local explicit_result = explicit:request()
  eq(explicit_result, nil, "scope waits for a UI answer")
  explicit.answer("truthy is not approval")
  eq(explicit.broker:list(), {}, "only boolean true can approve scope")
  local unresolved = fixture()
  assert(uv.fs_symlink(unresolved.base .. "/missing-provider", unresolved.home .. "/provider"))
  eq(unresolved:request().code, "protected_path", "unresolvable protected symlink fails closed")
  local xdg = fixture()
  xdg.options.config_home = directory(xdg.base .. "/custom-config")
  local config = directory(xdg.options.config_home .. "/opencode")
  eq(xdg:request(config).code, "protected_path", "alternate global OpenCode config is protected")
  xdg.options.data_home = ""
  local default_data = directory(xdg.home .. "/.local/share/opencode")
  eq(
    xdg:request(default_data).code,
    "protected_path",
    "empty XDG data setting uses the home default"
  )

  local changed = fixture()
  changed.defer = true
  local link = changed.base .. "/requested-link"
  assert(uv.fs_symlink(changed.outside, link))
  changed:request(link)
  assert(uv.fs_unlink(link))
  assert(uv.fs_symlink(directory(changed.base .. "/different"), link))
  changed.answer(true)
  eq(changed.broker:list(), {}, "a path retargeted during confirmation grants nothing")
  local unsaved = fixture()
  assert(uv.fs_chmod(unsaved.store:record_path(), 256))
  eq(unsaved:request().code, "relaunch_failed", "unsafe durable publication refuses scope")
  eq(unsaved.broker:list(), {}, "failed durable publication leaves old grants")
  assert(uv.fs_chmod(unsaved.store:record_path(), 384))
  eq(assert(unsaved.store:read_record()).grants, {}, "durable grants remain unchanged")

  local idle = fixture()
  local idle_pipe = assert(uv.new_pipe(false))
  local idle_response, idle_closed = "", false
  idle_pipe:connect(idle.store:runtime_dir() .. "/control.sock", function(error)
    assert(not error, error)
    idle_pipe:read_start(function(read_error, bytes)
      assert(not read_error, read_error)
      if bytes then
        idle_response = idle_response .. bytes
      else
        idle_closed = true
        idle_pipe:close()
      end
    end)
  end)
  assert(
    vim.wait(2000, function()
      return #idle.timers > 0
    end),
    "idle client is accepted"
  )
  eq(idle.timers[1].milliseconds, 5000, "idle socket has a five-second input deadline")
  idle.timers[1].callback()
  assert(
    vim.wait(2000, function()
      return idle_closed
    end),
    "idle socket is closed"
  )
  eq(vim.json.decode(idle_response).code, "timeout", "idle request is refused")

  local stale = fixture()
  assert(stale.broker:stop())
  local stale_path = stale.store:runtime_dir() .. "/control.sock"
  local stale_result = vim
    .system({
      "/usr/bin/python3",
      "-I",
      "-B",
      "-c",
      "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()",
      stale_path,
    })
    :wait()
  eq(stale_result.code, 0, "stale owned socket fixture")
  assert(stale.broker:start(), "stale owned nonsymlink socket can be replaced")

  local event_path = files.store:launch_paths("claude").event_file
  local uuid = files.session:snapshot().sessions.claude
  local function write_events(bytes, append)
    local fd = assert(uv.fs_open(event_path, append and "a" or "w", 384))
    assert(uv.fs_write(fd, bytes, append and -1 or 0))
    assert(uv.fs_close(fd))
  end
  local function event_line(state, session, time)
    return vim.json.encode({
      schema = 1,
      backend = "claude",
      session = session or uuid,
      state = state,
      time = time or 123,
    }) .. "\n"
  end
  write_events(event_line("busy") .. event_line("completed"))
  local emitted = {}
  local reader = assert(require("ai.events").new({
    backend = "claude",
    session = uuid,
    path = event_path,
    watch = function()
      return function() end
    end,
  }))
  cleanups[#cleanups + 1] = function()
    reader:stop()
  end
  reader:subscribe(function(event)
    emitted[#emitted + 1] = event.state
  end)
  local started, seed = reader:start()
  assert(started)
  eq(seed.state, "completed", "reconnect seeds only last matching status")
  eq(emitted, {}, "history does not emit transition notifications")
  write_events(
    event_line("busy")
      .. event_line("completed", "22222222-2222-4222-8222-222222222222")
      .. event_line("completed", nil, 100),
    true
  )
  assert(reader:poll())
  eq(emitted, { "busy", "completed" }, "live append order wins over wall-clock ordering")
  assert(reader:poll())
  eq(emitted, { "busy", "completed" }, "poll never replays consumed bytes")
  write_events(event_line("approval"))
  assert(reader:poll())
  eq(emitted, { "busy", "completed", "approval" }, "rollover resumes at byte zero")
  local partial = event_line("idle")
  write_events(partial:sub(1, 50), true)
  assert(reader:poll())
  eq(#emitted, 3, "partial line waits for completion")
  write_events(partial:sub(51), true)
  assert(reader:poll())
  eq(emitted[4], "idle", "completed partial line emits once")
  write_events(
    '{"schema":1,"schema":1,"backend":"claude","session":"'
      .. uuid
      .. '","state":"busy","time":123}\n'
      .. event_line("busy"):gsub('"time":123', '"extra":true,"time":123')
      .. string.rep(" ", 4097)
      .. event_line("busy"),
    true
  )
  assert(reader:poll())
  eq(#emitted, 4, "duplicate, unknown, and oversized lines are ignored")
  assert(uv.fs_chmod(event_path, 420))
  assert(not reader:poll(), "nonprivate event file refused")
  eq(#emitted, 4, "unsafe file emits nothing")
  assert(uv.fs_chmod(event_path, 384))
  write_events(string.rep("x", 1024 * 1024 + 1))
  assert(not reader:poll(), "oversized event file refused")
  write_events(event_line("completed"))
  assert(reader:poll())
  eq(emitted[5], "completed", "reader recovers after valid rollover")
  assert(uv.fs_rename(event_path, event_path .. ".original"))
  assert(uv.fs_symlink(event_path .. ".original", event_path))
  assert(not reader:poll(), "symlink event file refused")
  assert(uv.fs_unlink(event_path))
  assert(uv.fs_rename(event_path .. ".original", event_path))
  assert(reader:stop())

  local opencode_session = ""
  local open_events = {}
  local function open_line(session, state)
    return vim.json.encode({
      schema = 1,
      backend = "opencode",
      session = session,
      state = state,
      time = 123,
    }) .. "\n"
  end
  write_events(open_line("", "open"))
  local open_reader = assert(require("ai.events").new({
    backend = "opencode",
    path = event_path,
    session = function()
      return opencode_session
    end,
    watch = function()
      return function() end
    end,
  }))
  cleanups[#cleanups + 1] = function()
    open_reader:stop()
  end
  open_reader:subscribe(function(event)
    opencode_session = event.session
    open_events[#open_events + 1] = event.state
  end)
  assert(open_reader:start())
  write_events(
    open_line("invalid", "busy")
      .. open_line("ses_first", "busy")
      .. open_line("ses_foreign", "completed")
      .. open_line("ses_first", "approval"),
    true
  )
  assert(open_reader:poll())
  eq(opencode_session, "ses_first", "reader allows first valid OpenCode session to be pinned")
  eq(open_events, { "busy", "approval" }, "reader requires exact match after first session")
  assert(open_reader:stop())
  opencode_session = ""
  write_events(
    open_line("", "open")
      .. open_line("ses_first", "busy")
      .. open_line("ses_foreign", "completed")
      .. open_line("ses_first", "approval")
  )
  local reconnected, open_seed = open_reader:start()
  assert(reconnected)
  eq(open_seed.session, "ses_first", "reconnect keeps the first valid unpinned session")
  eq(open_seed.state, "approval", "reconnect seeds last status for that exact session")
  eq(#open_events, 2, "OpenCode reconnect emits no historical transitions")
  assert(open_reader:stop())

  local hooks = fixture()
  local hook_path = hooks.store:launch_paths("claude").event_file
  local hook_session = hooks.session:snapshot().sessions.claude
  local hook_reader = assert(require("ai.events").new({
    path = hook_path,
    backend = "claude",
    session = hook_session,
    watch = function()
      return function() end
    end,
  }))
  cleanups[#cleanups + 1] = function()
    hook_reader:stop()
  end
  hook_reader:subscribe(function(event)
    hooks.session:handle_event(event)
  end)
  assert(hook_reader:start())
  local helper = vim.fs.dirname(
    vim.fs.dirname(vim.uv.fs_realpath(debug.getinfo(1, "S").source:sub(2)))
  ) .. "/scripts/nvim-ai-event.py"
  for _, name in ipairs({ "PreToolUse", "PostToolUse", "Stop" }) do
    local result = vim
      .system(
        { "/usr/bin/python3", "-I", "-B", helper, "claude-hook", "--event-file", hook_path },
        { stdin = vim.json.encode({ hook_event_name = name, session_id = hook_session }) }
      )
      :wait(2000)
    eq(result.code, 0, "normal Claude hook is normalized")
    assert(hook_reader:poll())
  end
  eq(
    hooks.session:snapshot().state,
    "completed",
    "Claude completion after post-tool idle is published"
  )
  assert(hook_reader:stop())

  local rich = fixture()
  local rich_session = rich.session:snapshot().sessions.claude
  for index, state in ipairs({ "idle", "busy", "approval", "busy", "completed" }) do
    assert(rich.session:handle_event({
      schema = 1,
      backend = "claude",
      session = rich_session,
      state = state,
      time = 100 - index,
    }))
    eq(rich.session:snapshot().state, state, "rich event follows state machine")
  end
  local observed = 0
  rich.session:subscribe(function()
    observed = observed + 1
  end)
  for _, event in ipairs({
    { schema = 1, backend = "claude", session = rich_session, state = "completed", time = 200 },
    { schema = 1, backend = "claude", session = "foreign", state = "busy", time = 200 },
    { schema = 1, backend = "codex", session = rich_session, state = "busy", time = 200 },
    { schema = 2, backend = "claude", session = rich_session, state = "busy", time = 200 },
    {
      schema = 1,
      backend = "claude",
      session = rich_session,
      state = "busy",
      time = 200,
      extra = true,
    },
  }) do
    assert(not rich.session:handle_event(event), "unsupported or duplicate event ignored")
  end
  eq(observed, 0, "ignored events publish no snapshots")
  eq(rich.session:snapshot().grants, {}, "events cannot grant scope")
  eq(rich.session:snapshot().review_id, "review_0123456789abcdef", "events cannot resolve a review")
  assert(not reader:poll(), "stopped reader does not read")
  write_events(string.rep(event_line("idle"), 1000))
  assert(reader:start())
  write_events(event_line("busy"), true)
  local real_read, read_bytes = uv.fs_read, 0
  uv.fs_read = function(fd, length, ...)
    read_bytes = read_bytes + length
    return real_read(fd, length, ...)
  end
  local polled, poll_error = pcall(reader.poll, reader)
  uv.fs_read = real_read
  assert(polled, poll_error)
  assert(read_bytes <= 512, "incremental poll must not reread consumed event history")
  assert(reader:stop())
end, debug.traceback)
for _, cleanup in ipairs(cleanups) do
  pcall(cleanup)
end
vim.fn.delete(base, "rf")
assert(not uv.fs_lstat(base), "scope fixture cleanup")
assert(ok, err)
print("AI scope assertions: ok")
