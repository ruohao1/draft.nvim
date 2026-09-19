local function eq(actual, expected, label)
  assert(vim.deep_equal(actual, expected), label .. "\n" .. vim.inspect(actual))
end

local identity = {
  key = string.rep("a", 32),
  root = "/work/repo",
  namespace = "tmux:/private/ai.sock:41:9001",
  owner_pane = "%12",
  tmux_socket = "/private/ai.sock",
}
local metadata = {
  key = identity.key,
  owner = identity.owner_pane,
  root = identity.root,
  backend = "claude",
  state = "open",
  grants = "0",
  session = "11111111-1111-4111-8111-111111111111",
  opencode_token = "",
  opencode_fingerprint = "",
  opencode_version = "",
}

local function row(pane, data)
  data = data or metadata
  return table.concat({
    pane,
    "1",
    data.key,
    data.owner,
    data.root,
    data.backend,
    data.state,
    data.grants,
    data.session,
    data.opencode_token,
    data.opencode_fingerprint,
    data.opencode_version,
  }, "\t") .. "\n"
end

local function fixture(output, overrides)
  local calls = {}
  local transport = require("ai.transports.tmux")._test.new(vim.tbl_extend("force", {
    tmux = "/usr/bin/tmux",
    revalidate = function()
      return true
    end,
    socket_valid = function()
      return true
    end,
    hold_command = "exec '/usr/bin/sleep' '2147483647'",
    width = 40,
    nonce = function()
      return "77_99"
    end,
    run = function(argv, options)
      eq(
        { argv[1], argv[2], argv[3], argv[4] },
        { "/usr/bin/tmux", "-S", identity.tmux_socket, "-u" },
        "private server only"
      )
      calls[#calls + 1] = { argv = vim.deepcopy(argv), options = vim.deepcopy(options) }
      if type(output) == "function" then
        return output(argv, options)
      end
      return { code = 0, signal = 0, stdout = output, stderr = "" }
    end,
  }, overrides or {}))
  return transport, calls
end

-- Discovery must preserve ambiguous ownership instead of picking a pane.
local transport = fixture(row("%30") .. row("%31"))
local panes = assert(transport:discover(identity))
eq(
  vim.tbl_map(function(item)
    return item.pane
  end, panes),
  { "%30", "%31" },
  "duplicates remain visible"
)
eq(panes[1].session, metadata.session, "session survives discovery")
eq(panes[1].grants, "0", "grant hash survives discovery")

do
  local stale = fixture("%40\t1\t" .. identity.key .. "\t%12\t/work/repo\n")
  eq(assert(stale:owned_panes(identity)), {
    { pane = "%40", key = identity.key, owner = "%12", root = "/work/repo" },
  }, "ownership-only inspection does not need backend metadata")
  local foreign = fixture("%40\t1\t" .. identity.key .. "\t%13\t/work/repo\n")
  assert(not foreign:owned_panes(identity), "ownership-only inspection refuses foreign owner")
end

local invocation = {
  command = "exec '/usr/bin/python3' -I -B '/config/nvim/scripts/nvim-ai-launch.py' --manifest '/run/launch.json'",
  argv = {
    "/usr/bin/python3",
    "-I",
    "-B",
    "/config/nvim/scripts/nvim-ai-launch.py",
    "--manifest",
    "/run/launch.json",
  },
}
local function success(stdout)
  return { code = 0, signal = 0, stdout = stdout or "", stderr = "" }
end
local function owned()
  return "%40\t1\t" .. identity.key .. "\t%12\t/work/repo\t900\t0\n"
end
local creator, calls = fixture(function(argv)
  if argv[5] == "split-window" then
    return success("%40\n")
  end
  if argv[5] == "display-message" then
    return success(owned())
  end
  return success()
end)
eq(assert(creator:create(identity, invocation)), "%40", "created pane")
eq(calls[1].argv, {
  "/usr/bin/tmux",
  "-S",
  identity.tmux_socket,
  "-u",
  "split-window",
  "-h",
  "-p",
  "40",
  "-d",
  "-P",
  "-F",
  "#{pane_id}",
  "-t",
  "%12",
  "-c",
  identity.root,
  "exec '/usr/bin/sleep' '2147483647'",
}, "passive right-hand holder")
eq(calls[2].argv[5], "set-option", "ownership is recorded before launcher starts")
assert(
  table.concat(calls[2].argv, " "):find("set-option -pt %40 allow-passthrough off", 1, true),
  "new companion blocks terminal passthrough before any backend starts"
)
eq(calls[#calls].argv, {
  "/usr/bin/tmux",
  "-S",
  identity.tmux_socket,
  "-u",
  "respawn-pane",
  "-k",
  "-t",
  "%40",
  invocation.command,
}, "launcher starts in tagged pane")
assert(creator:tag("%40", metadata))

local encoded = vim.deepcopy(metadata)
encoded.root = "/work/a%20b%25"
local spaced_identity = vim.deepcopy(identity)
spaced_identity.root = "/work/a b%"
local spaced = fixture(row("%40", encoded))
eq(
  assert(spaced:discover(spaced_identity))[1].root,
  spaced_identity.root,
  "root encoding round trip"
)
local opencode = vim.deepcopy(metadata)
opencode.backend = "opencode"
opencode.opencode_token = string.rep("b", 32)
opencode.opencode_fingerprint = string.rep("c", 64)
opencode.opencode_version = "1.18.30"
local profiled = fixture(row("%40", opencode))
eq(
  assert(profiled:discover(identity))[1].opencode_fingerprint,
  opencode.opencode_fingerprint,
  "profile round trip"
)

local function rejected(fn, label)
  local ok, value, err = pcall(fn)
  assert(ok, label .. " raised: " .. tostring(value))
  assert(not value and type(err) == "string" and err ~= "", label .. " must report failure")
end
for _, change in ipairs({
  { opencode_version = "" },
  { opencode_version = "1.18.18" },
  { opencode_version = "1.18.29" },
  { opencode_version = "1.18.28" },
  { opencode_version = "1.18.31" },
  { opencode_token = "bad" },
  { backend = "codex" },
  { owner = "%99" },
  { root = "/work/%00" },
  { state = "invented" },
  { grants = "../unsafe" },
  { session = "bad\r" },
}) do
  local bad = fixture(row("%40", vim.tbl_extend("force", opencode, change)))
  rejected(function()
    return bad:discover(identity)
  end, "malformed matching pane")
end

-- Context is data, never a shell command or an implicit submit key.
local pasted = "Regarding file 'quoted'; $(touch should-not-run):7:3: "
assert(creator:paste("%40", pasted))
local buffer_name = "draft.nvim-" .. identity.key .. "-77_99"
eq(
  calls[#calls - 2].argv,
  { "/usr/bin/tmux", "-S", identity.tmux_socket, "-u", "load-buffer", "-b", buffer_name, "-" },
  "context uses a named buffer"
)
eq(calls[#calls - 2].options.stdin, pasted, "exact context bytes are sent on stdin")
eq(calls[#calls - 1].argv, {
  "/usr/bin/tmux",
  "-S",
  identity.tmux_socket,
  "-u",
  "paste-buffer",
  "-b",
  buffer_name,
  "-t",
  "%40",
}, "paste does not submit")
eq(calls[#calls].argv[5], "delete-buffer", "private buffer deleted after paste")
for _, bytes in ipairs({ "", "line\n", "enter\r", "escape\27", "\194\155", string.rep("x", 2049) }) do
  local before = #calls
  rejected(function()
    return creator:paste("%40", bytes)
  end, "unsafe paste")
  eq(#calls, before, "unsafe paste does not reach tmux")
end

for _, failure in ipairs({ "load-buffer", "paste-buffer", "delete-buffer" }) do
  local deletes = 0
  local broken, observed = fixture(function(argv)
    if argv[5] == "display-message" then
      return success(owned())
    end
    if argv[5] == "delete-buffer" then
      deletes = deletes + 1
    end
    if argv[5] == failure then
      return { code = 1, signal = 0, stdout = "" }
    end
    return success()
  end)
  assert(broken:discover(identity))
  rejected(function()
    return broken:paste("%40", "context")
  end, failure .. " failure")
  eq(deletes, failure == "delete-buffer" and 2 or 1, "bounded exact-buffer cleanup")
  eq(
    observed[#observed].argv,
    { "/usr/bin/tmux", "-S", identity.tmux_socket, "-u", "delete-buffer", "-b", buffer_name },
    "cleanup never targets another buffer"
  )
end

for _, failure in ipairs({ "set-option", "respawn-pane" }) do
  local broken, observed = fixture(function(argv)
    if argv[5] == "split-window" then
      return success("%40\n")
    end
    if argv[5] == "display-message" then
      return success(owned())
    end
    if argv[5] == failure then
      return { code = 1, signal = 0, stdout = "" }
    end
    return success()
  end)
  rejected(function()
    return broken:create(identity, invocation)
  end, failure .. " creation failure")
  eq(
    observed[#observed].argv,
    { "/usr/bin/tmux", "-S", identity.tmux_socket, "-u", "kill-pane", "-t", "%40" },
    "only the new pane is cleaned up"
  )
end

local dead = false
local signaled = {}
local lifecycle, lifecycle_calls = fixture(function(argv)
  if argv[5] == "display-message" then
    return success(dead and owned():gsub("0\n$", "1\n") or owned())
  end
  return success()
end, {
  kill = function(pid, signal)
    signaled[#signaled + 1] = { pid, signal }
    dead = true
    return 0
  end,
  wait = function(timeout, check)
    eq(timeout, 2000, "graceful stop is bounded")
    return check()
  end,
})
assert(lifecycle:discover(identity))
assert(lifecycle:focus("%40"))
eq(lifecycle_calls[#lifecycle_calls].argv[5], "select-pane", "focus selects owned pane")
assert(lifecycle:respawn("%40", invocation, { signal = 1, timeout = 2000 }))
eq(signaled[1], { 900, 1 }, "switch suspends the owned process")
eq(lifecycle_calls[#lifecycle_calls].argv[5], "respawn-pane", "switch reuses pane")
eq(lifecycle_calls[#lifecycle_calls - 1].argv, {
  "/usr/bin/tmux",
  "-S",
  identity.tmux_socket,
  "-u",
  "set-option",
  "-pt",
  "%40",
  "allow-passthrough",
  "off",
}, "replacement reasserts the pane-local passthrough boundary before launch")
dead = false
assert(lifecycle:close("%40", { signal = 15, timeout = 2000 }))
eq(signaled[2], { 900, 15 }, "close gracefully stops the owned process")
eq(
  lifecycle_calls[#lifecycle_calls].argv,
  { "/usr/bin/tmux", "-S", identity.tmux_socket, "-u", "kill-pane", "-t", "%40" },
  "close removes the owned pane"
)
local before_shutdown = #lifecycle_calls
lifecycle:shutdown()
eq(#lifecycle_calls, before_shutdown, "Neovim exit leaves tmux companion alive")

do
  local blocked, observed = fixture(function(argv)
    if argv[5] == "display-message" then
      return success(owned():gsub("0\n$", "1\n"))
    end
    if argv[5] == "set-option" then
      return { code = 1, signal = 0, stdout = "" }
    end
    return success()
  end)
  assert(blocked:discover(identity))
  local started, err, phase = blocked:respawn("%40", invocation)
  assert(not started and err, "failure to establish the pane boundary refuses replacement")
  eq(phase, "not_started", "boundary failure precedes native launch")
  for _, call in ipairs(observed) do
    assert(call.argv[5] ~= "respawn-pane", "failed boundary must never launch a CLI")
  end
end

local stolen, stolen_calls = fixture(function(argv)
  if argv[5] == "display-message" then
    return success(owned():gsub(identity.key, string.rep("b", 32)))
  end
  return success()
end)
assert(stolen:discover(identity))
for _, action in ipairs({
  function()
    return stolen:focus("%40")
  end,
  function()
    return stolen:paste("%40", "context")
  end,
  function()
    return stolen:tag("%40", metadata)
  end,
  function()
    return stolen:close("%40")
  end,
  function()
    return stolen:respawn("%40", invocation)
  end,
  function()
    return stolen:focus("%40; kill-server")
  end,
}) do
  rejected(action, "refuse foreign or invalid pane")
end
for _, call in ipairs(stolen_calls) do
  assert(
    call.argv[5] == "list-panes" or call.argv[5] == "display-message",
    "foreign panes are never mutated"
  )
end

local terminal_calls = {}
local live = true
local terminal = require("ai.transports.terminal")._test.new({
  create = function(root, argv)
    terminal_calls[#terminal_calls + 1] = { "create", root, vim.deepcopy(argv) }
    live = true
    return 8, 91
  end,
  valid = function(buffer, job)
    return buffer == 8 and (job == 91 or job == 92)
  end,
  restart = function(buffer, root, argv)
    terminal_calls[#terminal_calls + 1] = { "restart", buffer, root, vim.deepcopy(argv) }
    live = true
    return 8, 92
  end,
  running = function()
    return live
  end,
  pid = function()
    return 901
  end,
  kill = function(pid, signal)
    terminal_calls[#terminal_calls + 1] = { "signal", pid, signal }
    live = false
    return 0
  end,
  wait = function(_, check)
    return check()
  end,
  focus = function(buffer)
    terminal_calls[#terminal_calls + 1] = { "focus", buffer }
    return true
  end,
  send = function(job, bytes)
    terminal_calls[#terminal_calls + 1] = { "send", job, bytes }
    return true
  end,
  stop = function(job)
    terminal_calls[#terminal_calls + 1] = { "stop", job }
    live = false
    return true
  end,
  wipe = function(buffer)
    terminal_calls[#terminal_calls + 1] = { "wipe", buffer }
    return true
  end,
})
local standalone_identity = vim.deepcopy(identity)
standalone_identity.namespace = "nvim:fixture"
standalone_identity.owner_pane, standalone_identity.tmux_socket = nil, nil
local handle = assert(terminal:create(standalone_identity, invocation))
eq(handle, "term:8:91", "standalone handle")
eq(
  terminal_calls[1],
  { "create", identity.root, invocation.argv },
  "terminal receives argv, not shell text"
)
eq(assert(terminal:discover(standalone_identity))[1].pane, handle, "terminal is rediscovered")
assert(terminal:paste(handle, "selection reference"))
eq(
  terminal_calls[#terminal_calls],
  { "send", 91, "selection reference" },
  "terminal does not append Enter"
)
rejected(function()
  return terminal:paste("term:8:92", "context")
end, "stale terminal handle")
rejected(function()
  return terminal:paste(handle, "context\r")
end, "terminal refuses submit bytes")
assert(terminal:focus(handle))
local standalone_metadata = vim.deepcopy(metadata)
standalone_metadata.owner = nil
assert(terminal:tag(handle, standalone_metadata))
assert(terminal:respawn(handle, invocation, { signal = 1, timeout = 2000 }))
eq(
  assert(terminal:discover(standalone_identity))[1].pane,
  handle,
  "logical terminal handle survives replacement"
)
assert(terminal:paste(handle, "replacement context"))
eq(
  terminal_calls[#terminal_calls],
  { "send", 92, "replacement context" },
  "replacement receives context"
)
terminal:shutdown()
eq(
  terminal_calls[#terminal_calls - 1],
  { "signal", 901, 15 },
  "standalone shutdown stops its process"
)
eq(terminal_calls[#terminal_calls], { "wipe", 8 }, "standalone shutdown wipes only its buffer")
eq(assert(terminal:discover(standalone_identity)), {}, "closed terminal is no longer discoverable")

for _, changed in ipairs({
  {
    revalidate = function()
      return nil, "executable changed"
    end,
  },
  {
    socket_valid = function()
      return false
    end,
  },
}) do
  local unsafe, observed = fixture("", changed)
  rejected(function()
    return unsafe:create(identity, invocation)
  end, "changed executable/socket")
  eq(observed, {}, "changed trust inputs prevent all tmux commands")
end
local missing_socket = vim.deepcopy(identity)
missing_socket.tmux_socket = nil
local no_socket, no_socket_calls = fixture("")
rejected(function()
  return no_socket:discover(missing_socket)
end, "missing socket")
eq(no_socket_calls, {}, "missing socket never falls back to default server")
local malformed = fixture("%40\t1\t" .. identity.key .. "\t%12\n")
rejected(function()
  return malformed:discover(identity)
end, "incomplete discovery record")

local fallback_signals = {}
local fallback, fallback_calls = fixture(function(argv)
  return success(argv[5] == "display-message" and owned() or "")
end, {
  kill = function(pid, signal)
    fallback_signals[#fallback_signals + 1] = { pid, signal }
    return 0
  end,
  wait = function(timeout, check)
    eq(timeout, 2000, "unresponsive process wait is bounded")
    eq(check(), false, "fixture process ignores graceful signal")
    return false
  end,
})
assert(fallback:discover(identity))
assert(fallback:respawn("%40", invocation, { signal = 1, timeout = 2000 }))
eq(fallback_signals, { { 900, 1 } }, "graceful signal precedes forced fallback")
eq(
  fallback_calls[#fallback_calls].argv[5],
  "respawn-pane",
  "unresponsive owned process can be replaced"
)

dofile(vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "ai_session.lua"))
print("AI transport assertions: ok")

do
  local marker = "1"
  local interrupted = fixture(function(argv)
    if argv[5] == "list-panes" then
      return success(row("%40"))
    end
    if argv[5] == "display-message" then
      return success("%40\t" .. marker .. "\t" .. identity.key .. "\t%12\t/work/repo\t900\t1\n")
    end
    if argv[5] == "set-option" then
      -- tmux accepted the first command then lost the connection.
      if argv[8] == "@draft_nvim" then
        marker = argv[9]
      end
      return { code = 1, signal = 0, stdout = "", stderr = "interrupted tag" }
    end
    return success("")
  end)
  assert(interrupted:discover(identity))
  assert(not interrupted:tag("%40", metadata))
  assert(
    interrupted:close("%40", { signal = 15, timeout = 2000 }),
    "tag interruption must not disable exact owned-process cleanup"
  )
end
