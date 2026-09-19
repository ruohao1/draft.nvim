-- Real local PTYs and a private tmux server; no backend or provider is invoked.
assert(vim.uv.os_uname().sysname == "Linux", "this integration check currently targets Linux")
local tools = require("ai.tools")
local tmux = assert(tools.resolve("tmux"))
local python = assert(tools.resolve("python3"))
local sleep = assert(tools.resolve("sleep"))
local script = assert(vim.api.nvim_get_runtime_file("tests/fixtures/ai/fake_cli.py", false)[1])
local root = assert(vim.uv.fs_mkdtemp("/tmp/nvim-ai-transport.XXXXXX"))
assert(vim.uv.fs_chmod(root, 448))
local socket = root .. "/tmux.sock"
local terminal

local function command(argv)
  local quoted = vim.tbl_map(function(item)
    return "'" .. item:gsub("'", "'\\''") .. "'"
  end, argv)
  return "exec " .. table.concat(quoted, " ")
end

local function run(args)
  local argv = { tmux, "-S", socket }
  vim.list_extend(argv, args)
  return vim
    .system(argv, { text = true, clear_env = true, env = { LC_ALL = "C", TERM = "xterm-256color" } })
    :wait(3000)
end

local function events(name)
  local result = {}
  local file = io.open(root .. "/" .. name, "r")
  if not file then
    return result
  end
  for line in file:lines() do
    result[#result + 1] = vim.json.decode(line)
  end
  file:close()
  return result
end

local function await_event(name, kind, count)
  assert(
    vim.wait(3000, function()
      local found = 0
      for _, event in ipairs(events(name)) do
        if event.event == kind then
          found = found + 1
        end
      end
      return found >= (count or 1)
    end, 10),
    "missing fixture event: " .. name .. ":" .. kind
  )
end

local function invocation(name)
  local argv = { python, "-I", "-B", script, root .. "/" .. name }
  return { argv = argv, command = command(argv) }
end

local ok, err = xpcall(function()
  local started = run({
    "-f",
    "/dev/null",
    "new-session",
    "-d",
    "-s",
    "ai-test",
    "-x",
    "160",
    "-y",
    "48",
    "-P",
    "-F",
    "#{pane_id}",
    "-c",
    root,
    command({ sleep, "2147483647" }),
  })
  assert(started.code == 0, started.stderr)
  local owner = started.stdout:gsub("\n$", "")
  local stat = assert(vim.uv.fs_lstat(socket))
  local identity = {
    key = string.rep("a", 32),
    root = root,
    inside_git = false,
    owner_pane = owner,
    tmux_socket = socket,
    namespace = string.format("tmux:%s:%s:%s", socket, stat.dev, stat.ino),
  }
  local transport = assert(require("ai.transports.tmux").new({ tmux = tmux }))
  assert(#assert(transport:discover(identity)) == 0)
  local pane = assert(transport:create(identity, invocation("tmux-events")))
  local metadata = {
    key = identity.key,
    owner = owner,
    root = root,
    backend = "codex",
    state = "open",
    grants = "0",
    session = "last",
    opencode_token = "",
    opencode_fingerprint = "",
    opencode_version = "",
  }
  assert(transport:tag(pane, metadata))
  await_event("tmux-events", "ready")
  assert(
    run({ "show-options", "-pv", "-t", pane, "allow-passthrough" }).stdout == "off\n",
    "native creation must fence passthrough only on the companion pane"
  )
  assert(assert(transport:discover(identity))[1].pane == pane)
  local profile = vim.tbl_extend("force", metadata, {
    backend = "opencode",
    session = "ses_fixture;",
    opencode_token = string.rep("b", 32),
    opencode_fingerprint = string.rep("c", 64),
    opencode_version = "1.18.30",
  })
  assert(transport:tag(pane, profile))
  local observed = assert(transport:discover(identity))[1]
  assert(observed.session == "ses_fixture;", "tmux interpreted metadata's trailing semicolon")
  assert(
    observed.opencode_token == profile.opencode_token
      and observed.opencode_fingerprint == profile.opencode_fingerprint
      and observed.opencode_version == "1.18.30",
    "OpenCode tag/discovery did not round trip"
  )
  assert(transport:tag(pane, metadata))
  assert(transport:focus(pane))
  local text = "Regarding demo.lua:7:3: 'quoted'; $(literal) "
  assert(transport:paste(pane, text))
  await_event("tmux-events", "input")
  local received = ""
  for _, event in ipairs(events("tmux-events")) do
    if event.event == "input" then
      received = received .. event.hex
    end
  end
  assert(received == (text:gsub(".", function(byte)
    return string.format("%02x", byte:byte())
  end)), "tmux changed/submitted input")
  local buffers = run({ "list-buffers", "-F", "#{buffer_name}" })
  assert(buffers.code == 0 and buffers.stdout == "", "tmux paste buffer leaked")
  assert(run({ "set-option", "-pt", pane, "allow-passthrough", "on" }).code == 0)
  assert(transport:respawn(pane, invocation("tmux-events"), { signal = 1, timeout = 2000 }))
  assert(
    run({ "show-options", "-pv", "-t", pane, "allow-passthrough" }).stdout == "off\n",
    "native replacement must reassert passthrough boundary"
  )
  await_event("tmux-events", "ready", 2)
  await_event("tmux-events", "signal")
  transport:shutdown()
  local reconnected = assert(require("ai.transports.tmux").new({ tmux = tmux }))
  assert(
    assert(reconnected:discover(identity))[1].pane == pane,
    "tmux did not survive coordinator shutdown"
  )
  assert(reconnected:close(pane))
  await_event("tmux-events", "signal", 2)
  local survivors = run({ "list-panes", "-a", "-F", "#{pane_id}" })
  assert(survivors.stdout == owner .. "\n", "closing companion changed owner pane")

  -- Real coordinator, durable store, adapters, and native transport. CLI health
  -- responses and the sandbox process boundary are provider-free fixtures.
  do
    local fixture_home = root .. "/coordinator-home"
    assert(vim.uv.fs_mkdir(fixture_home, 448))
    local registry = require("ai.backends")._test.new({
      executable = function()
        return python
      end,
      revalidate = tools.revalidate,
      stat = vim.uv.fs_lstat,
      uid = vim.uv.getuid,
      uuid = function()
        return "11111111-1111-4111-8111-111111111111"
      end,
      version = function()
        return { code = 0, signal = 0, stdout = "1.0", stderr = "" }
      end,
      auth = function(backend)
        return {
          code = 0,
          signal = 0,
          stdout = backend == "claude" and '{"loggedIn":true}' or "Logged in using ChatGPT",
          stderr = "",
        }
      end,
      help = function()
        return {
          code = 0,
          signal = 0,
          stdout = "--session-id --resume --permission-mode --add-dir --settings --last -C --sandbox --ask-for-approval",
          stderr = "",
        }
      end,
      opencode_validation = {
        subscribe = function()
          return function() end
        end,
      },
    })
    local store = assert(require("ai.state")._test.open({
      identity = identity,
      runtime_base = root .. "/coordinator-run",
      state_base = root .. "/coordinator-state",
      uid = vim.uv.getuid(),
    }))
    local launches = {}
    local options = {
      identity = identity,
      store = store,
      registry = registry,
      transport = assert(require("ai.transports.tmux").new({ tmux = tmux })),
      tools = { git = assert(tools.resolve("git")), tmux = tmux, python = python },
      helpers = {
        event_helper = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
          .. "/scripts/nvim-ai-event.py",
      },
      home = fixture_home,
      data_home = fixture_home,
      sandbox = {
        prepare = function(request)
          launches[#launches + 1] = request
          local manifest = {
            token = request.token,
            writable = request.writable,
            review_id = request.review_id or vim.NIL,
          }
          local path = assert(request.write_manifest(manifest))
          local result = invocation("coordinator-events")
          result.token, result.path = request.token, path
          return result
        end,
      },
      confirm = function()
        return true
      end,
    }
    local coordinator = assert(require("ai.session").new(options))
    assert(coordinator:open("claude"))
    await_event("coordinator-events", "ready")
    local original = coordinator:snapshot().pane
    assert(launches[1].writable == false, "native first launch was not read-only")
    assert(coordinator:prepare_review("review_abcdef"))
    await_event("coordinator-events", "ready", 2)
    assert(launches[2].writable and launches[2].review_id == "review_abcdef")
    assert(coordinator:switch("codex"))
    await_event("coordinator-events", "ready", 3)
    assert(coordinator:snapshot().pane == original, "coordinator changed native pane")
    assert(coordinator:finish_review("review_abcdef"))
    await_event("coordinator-events", "ready", 4)
    assert(not launches[4].writable, "resolved native review remains writable")
    assert(coordinator:shutdown())
    options.transport = assert(require("ai.transports.tmux").new({ tmux = tmux }))
    local reopened = assert(require("ai.session").new(options))
    assert(reopened:attach())
    assert(
      reopened:snapshot().pane == original and #launches == 4,
      "native reconnect restarted the backend"
    )
    assert(reopened:paste(text))
    await_event("coordinator-events", "input")
    assert(reopened:close())
    assert(store:read_control_token() == nil, "native close left control ownership")
    local durable = assert(store:read_record())
    assert(
      durable.sessions.codex == "last"
        and durable.sessions.claude == "11111111-1111-4111-8111-111111111111",
      "native close lost remembered sessions"
    )
    assert(durable.opencode_profile == vim.NIL and #durable.grants == 0)
    assert(
      run({ "list-panes", "-a", "-F", "#{pane_id}" }).stdout == owner .. "\n",
      "native coordinator closed unrelated pane"
    )
    assert(reopened:shutdown())
  end

  identity.owner_pane, identity.tmux_socket = nil, nil
  identity.namespace = "nvim:transport-integration"
  terminal = assert(require("ai.transports.terminal").new())
  local handle = assert(terminal:create(identity, invocation("terminal-events")))
  await_event("terminal-events", "ready")
  assert(terminal:paste(handle, text))
  await_event("terminal-events", "input")
  assert(terminal:focus(handle))
  metadata.owner = nil
  assert(terminal:tag(handle, metadata))
  assert(terminal:respawn(handle, invocation("terminal-events"), { signal = 1, timeout = 2000 }))
  await_event("terminal-events", "ready", 2)
  await_event("terminal-events", "signal")
  assert(assert(terminal:discover(identity))[1].pane == handle)
  assert(terminal:paste(handle, text))
  await_event("terminal-events", "input", 2)
  assert(terminal:shutdown())
  await_event("terminal-events", "signal", 2)
  assert(#assert(terminal:discover(identity)) == 0)

  -- The manual smoke entry point is itself exercised through visible commands.
  local manual_script =
    assert(vim.api.nvim_get_runtime_file("tests/ai_transport_manual.lua", false)[1])
  local existing_calls = 0
  vim.api.nvim_create_user_command("AITransportRestart", function()
    existing_calls = existing_calls + 1
  end, { desc = "Existing user command" })
  local collision_ok = pcall(dofile, manual_script)
  assert(not collision_ok, "manual demo replaced an existing command")
  vim.cmd.AITransportRestart()
  assert(existing_calls == 1, "existing command no longer works")
  vim.api.nvim_del_user_command("AITransportRestart")
  local demo =
    dofile(assert(vim.api.nvim_get_runtime_file("tests/ai_transport_manual.lua", false)[1]))
  assert(vim.fn.exists(":AITransportPaste") == 2)
  local function visible_text()
    local lines = {}
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buffer].buftype == "terminal" then
        vim.list_extend(lines, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
      end
    end
    return table.concat(lines, "\n")
  end
  assert(vim.wait(3000, function()
    return visible_text():find("FAKE CLI READY", 1, true)
  end, 10))
  vim.cmd.AITransportPaste()
  assert(vim.wait(3000, function()
    return visible_text():find("INPUT: Regarding demo.lua:7:3:", 1, true)
  end, 10))
  vim.cmd.AITransportRestart()
  assert(vim.wait(3000, function()
    return visible_text():find("FAKE CLI READY", 1, true)
  end, 10))
  vim.cmd.AITransportClose()
  assert(not vim.uv.fs_lstat(demo.root), "manual demo left private state behind")
end, debug.traceback)

if terminal then
  terminal:shutdown()
end
local stopped = run({ "kill-server" })
assert(stopped.code == 0 or stopped.code == 1, "private tmux cleanup failed")
-- This test owns every object below its fresh, private fixture directory.
assert(vim.fn.delete(root, "rf") == 0, "private fixture cleanup failed")
assert(not vim.uv.fs_lstat(root), "fixture residue remains")
assert(ok, err)
print("AI transport native Linux assertions: ok")
