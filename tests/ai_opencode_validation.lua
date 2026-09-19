local function eq(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    string.format("%s\nexpected: %s\nactual: %s", label, vim.inspect(expected), vim.inspect(actual))
  )
end

local managed = require("ai.backends.opencode_managed")
local validation = require("ai.backends.opencode_validation")
local registry = require("ai.backends")

local expected_commands = {
  { name = "version", arguments = { "--version" }, semantic = false },
  { name = "root_help", arguments = { "--help" }, semantic = false },
  { name = "serve_help", arguments = { "serve", "--help" }, semantic = false },
  { name = "attach_help", arguments = { "attach", "--help" }, semantic = false },
  { name = "names", arguments = { "--pure", "agent", "list" }, semantic = true },
  { name = "build", arguments = { "--pure", "debug", "agent", "build" }, semantic = true },
  { name = "plan", arguments = { "--pure", "debug", "agent", "plan" }, semantic = true },
  {
    name = "compaction",
    arguments = { "--pure", "debug", "agent", "compaction" },
    semantic = true,
  },
  { name = "summary", arguments = { "--pure", "debug", "agent", "summary" }, semantic = true },
  { name = "title", arguments = { "--pure", "debug", "agent", "title" }, semantic = true },
  { name = "general", arguments = { "--pure", "debug", "agent", "general" }, semantic = true },
  { name = "explore", arguments = { "--pure", "debug", "agent", "explore" }, semantic = true },
}

eq(validation.commands(), expected_commands, "fixed OpenCode validation order")
local changed_commands = validation.commands()
changed_commands[1].arguments[1] = "changed-secret-canary"
eq(validation.commands(), expected_commands, "command callers cannot mutate the fixed contract")

local primary_tools = {
  invalid = true,
  question = true,
  bash = true,
  read = true,
  glob = true,
  grep = true,
  edit = true,
  write = true,
  task = false,
  webfetch = true,
  todowrite = true,
  websearch = true,
  skill = false,
}

local list_fixture_wildcard = "**/{src,test}/**"
local list_fixture_header = "plan (primary)"
local list_fixture_braces = "{literal-json-braces}"

local function pretty_permission_json(rules)
  assert(type(rules) == "table" and vim.islist(rules), "permission fixture must be a list")
  if #rules == 0 then
    return "[]"
  end

  local lines = { "[" }
  for index, rule in ipairs(rules) do
    assert(type(rule) == "table", "permission fixture rule must be a table")
    assert(type(rule.permission) == "string", "permission fixture permission")
    assert(type(rule.pattern) == "string", "permission fixture pattern")
    assert(type(rule.action) == "string", "permission fixture action")
    lines[#lines + 1] = "  {"
    lines[#lines + 1] = string.format('    "permission": %s,', vim.json.encode(rule.permission))
    lines[#lines + 1] = string.format('    "pattern": %s,', vim.json.encode(rule.pattern))
    if index == 1 then
      lines[#lines + 1] = string.format('    "action": %s,', vim.json.encode(rule.action))
      lines[#lines + 1] = '    "enabled": true,'
      lines[#lines + 1] = '    "disabled": false,'
      lines[#lines + 1] = '    "metadata": {'
      lines[#lines + 1] = '      "patterns": ['
      lines[#lines + 1] = string.format("        %s,", vim.json.encode(list_fixture_wildcard))
      lines[#lines + 1] = string.format("        %s", vim.json.encode(list_fixture_header))
      lines[#lines + 1] = "      ],"
      lines[#lines + 1] = string.format('      "braces": %s', vim.json.encode(list_fixture_braces))
      lines[#lines + 1] = "    }"
    else
      lines[#lines + 1] = string.format('    "action": %s', vim.json.encode(rule.action))
    end
    lines[#lines + 1] = "  }" .. (index < #rules and "," or "")
  end
  lines[#lines + 1] = "]"
  return table.concat(lines, "\n")
end

local function agent_list_stdout(report)
  local entries = {
    { name = "title", mode = "subagent" },
    { name = "build", mode = "primary" },
    { name = "summary", mode = "subagent" },
    { name = "plan", mode = "primary" },
    { name = "compaction", mode = "subagent" },
  }
  local lines = {}
  for _, entry in ipairs(entries) do
    lines[#lines + 1] = string.format("%s (%s)", entry.name, entry.mode)
    lines[#lines + 1] = pretty_permission_json(report.agents[entry.name].permission)
  end
  return table.concat(lines, "\n") .. "\n"
end

local function fixture_results()
  local report = managed._test.compatibility_fixture()
  local results = {
    version = { code = 0, signal = 0, stdout = "1.18.30\n", stderr = "" },
    root_help = { code = 0, signal = 0, stdout = "", stderr = "--pure serve attach" },
    serve_help = { code = 0, signal = 0, stdout = "", stderr = "--hostname --port" },
    attach_help = {
      code = 0,
      signal = 0,
      stdout = "",
      stderr = "--dir --session OPENCODE_SERVER_PASSWORD",
    },
    names = {
      code = 0,
      signal = 0,
      stdout = agent_list_stdout(report),
      stderr = "",
    },
  }
  for _, name in ipairs({ "build", "plan", "compaction", "summary", "title" }) do
    local agent = vim.deepcopy(report.agents[name])
    if name == "build" or name == "plan" then
      agent.tools = vim.deepcopy(primary_tools)
    end
    results[name] = {
      code = 0,
      signal = 0,
      stdout = vim.json.encode(agent) .. "\n",
      stderr = "",
    }
  end
  for _, name in ipairs({ "general", "explore" }) do
    results[name] = {
      code = 1,
      signal = 0,
      stdout = "",
      stderr = "Agent " .. name .. " not found, run 'opencode agent list' to get an agent list\n",
    }
  end
  return results, report
end

local valid_results, expected_report = fixture_results()
eq({
  explicit_boolean = valid_results.names.stdout:find('"enabled": true', 1, true) ~= nil,
  explicit_false = valid_results.names.stdout:find('"disabled": false', 1, true) ~= nil,
  nested_multiline = valid_results.names.stdout:find('"metadata": {\n      "patterns": [', 1, true)
    ~= nil,
  quoted_wildcard = valid_results.names.stdout:find(
    vim.json.encode(list_fixture_wildcard),
    1,
    true
  ) ~= nil,
  quoted_braces = valid_results.names.stdout:find(vim.json.encode(list_fixture_braces), 1, true)
    ~= nil,
  quoted_header = valid_results.names.stdout:find(vim.json.encode(list_fixture_header), 1, true)
    ~= nil,
}, {
  explicit_boolean = true,
  explicit_false = true,
  nested_multiline = true,
  quoted_wildcard = true,
  quoted_braces = true,
  quoted_header = true,
}, "successful realistic names fixture covers boolean and nested multiline JSON")
local fixture_header_order = {}
for line in valid_results.names.stdout:gmatch("[^\n]+") do
  local name = line:match("^([%w_-]+) %([%w_-]+%)$")
  if name then
    fixture_header_order[#fixture_header_order + 1] = name
  end
end
eq(
  fixture_header_order,
  { "title", "build", "summary", "plan", "compaction" },
  "successful names fixture keeps a deliberately unsorted header order"
)
eq(
  expected_report.names,
  { "build", "compaction", "plan", "summary", "title" },
  "successful names fixture keeps the expected sanitized sorted report"
)
local parsed, parse_error = validation._test.parse_results(valid_results)
assert(parsed, parse_error)
eq(parsed, expected_report, "bounded results produce the audited sanitized report")
local test_parsed, test_parse_error = validation._test.parse_results(valid_results)
assert(test_parsed, test_parse_error)
eq(test_parsed, expected_report, "test parser export uses the module-local parser")

local crlf_results, crlf_report = fixture_results()
crlf_results.names.stdout = crlf_results.names.stdout:gsub("\n", "\r\n")
local crlf_parsed, crlf_error = validation._test.parse_results(crlf_results)
assert(crlf_parsed, crlf_error)
eq(crlf_parsed, crlf_report, "CRLF agent list parses through the pinned grammar")

local ignored_list_permissions, ignored_list_report = fixture_results()
local replacement_count
ignored_list_permissions.names.stdout, replacement_count =
  ignored_list_permissions.names.stdout:gsub('"action": "allow"', '"action": "deny"', 1)
eq(replacement_count, 1, "agent-list permission fixture changed exactly once")
local ignored_list_parsed, ignored_list_error =
  validation._test.parse_results(ignored_list_permissions)
assert(ignored_list_parsed, ignored_list_error)
eq(
  ignored_list_parsed,
  ignored_list_report,
  "agent-list permissions are structural while debug-agent permissions remain semantic"
)

local function expect_names_parse_failure(label, stdout)
  local results = fixture_results()
  results.names.stdout = stdout
  local parser = validation._test.new_parser()
  for index = 1, 4 do
    local command = expected_commands[index]
    local accepted, category = parser:accept(command, results[command.name])
    assert(accepted, category)
  end

  local accepted, category = parser:accept(expected_commands[5], results.names)
  assert(accepted == nil, label .. " was accepted")
  eq(category, "parse-failure", label .. " category")
  assert(not category:find("secret-canary", 1, true), label .. " leaked canary bytes")
  eq(parser:debug_state(), {
    index = 4,
    version = true,
    name_count = 0,
    agent_count = 0,
    finished = false,
  }, label .. " retains no names or raw result")
end

expect_names_parse_failure("empty list", "")
expect_names_parse_failure("leading text", "secret-canary\nbuild (primary)\n[]\n")
expect_names_parse_failure("missing permission block", "build (primary)\nplan (primary)\n[]\n")
expect_names_parse_failure("malformed permission JSON", "build (primary)\n{secret-canary}\n")
expect_names_parse_failure("non-list permission JSON", "build (primary)\n{}\n")
expect_names_parse_failure("multiple permission values", "build (primary)\n[]\n[]\n")
expect_names_parse_failure("duplicate agent header", "build (primary)\n[]\nbuild (primary)\n[]\n")
expect_names_parse_failure("unsupported agent mode", "build (future)\n[]\n")
expect_names_parse_failure("trailing text", "build (primary)\n[]\nsecret-canary\n")
expect_names_parse_failure(
  "raw header inside unfinished JSON",
  "build (primary)\n[\nplan (primary)\n[]\n"
)
expect_names_parse_failure("bare carriage return", "build (primary)\n[]\r")
expect_names_parse_failure("truncated final JSON", "build (primary)\n[\n{}\n")

local oversized_names_header = "build (primary)\n"
local oversized_names_stdout = oversized_names_header
  .. table.concat({
    "[",
    "  {",
    '    "permission": "read",',
    '    "pattern": "' .. string.rep("*", 65536) .. '",',
    '    "action": "allow"',
    "  }",
    "]",
  }, "\n")
  .. "\n"
local oversized_names_json = oversized_names_stdout:sub(#oversized_names_header + 1, -2)
local oversized_names_ok, oversized_names_decoded = pcall(vim.json.decode, oversized_names_json)
assert(
  oversized_names_ok and vim.islist(oversized_names_decoded) and #oversized_names_decoded == 1,
  "oversized names fixture must otherwise be one structurally valid permission array"
)
assert(#oversized_names_stdout > 65536, "oversized names fixture must exceed 64 KiB")
assert(
  #oversized_names_stdout <= 1024 * 1024,
  "oversized names fixture must remain within the general result bound"
)
expect_names_parse_failure("oversized names stdout", oversized_names_stdout)

local function expect_parse_failure(label, mutate)
  local results = fixture_results()
  mutate(results)
  local report, category = validation._test.parse_results(results)
  assert(report == nil, label .. " was accepted")
  eq(category, "parse-failure", label .. " category")
  assert(not category:find("secret-canary", 1, true), label .. " leaked canary bytes")
end

expect_parse_failure("prefixed version", function(results)
  results.version.stdout = "opencode 1.18.30 secret-canary\n"
end)
for _, version in ipairs({ "1.18.18", "1.18.28", "1.18.29", "1.18.31", "1.19.0" }) do
  for _, suffix in ipairs({ "", "\n" }) do
    local results = fixture_results()
    results.version.stdout = version .. suffix
    local report, category, detected = validation._test.parse_results(results)
    eq(report, nil, "unaudited release is refused")
    eq(category, "version-mismatch", "clean release differs from malformed output")
    eq(detected, version, "only the bounded release number survives parsing")
  end
end
for _, output in ipairs({
  "1.18.31\n\n",
  "1.18.31\r\n",
  "01.18.31",
  "1.018.31",
  "1.18.031",
  "1.18.31-beta",
  "1.18.31 secret-canary",
  "\27[31m1.18.31",
  "1.18.31\0",
  string.rep("1", 33) .. ".18.31",
}) do
  expect_parse_failure("malformed version", function(results)
    results.version.stdout = output
  end)
end
expect_parse_failure("missing help flag", function(results)
  results.root_help.stderr = "serve attach secret-canary"
end)
expect_parse_failure("duplicate agent name", function(results)
  results.names.stdout = results.names.stdout .. "build (primary)\nsecret-canary"
end)
expect_parse_failure("malformed agent JSON", function(results)
  results.compaction.stdout = "{secret-canary"
end)
expect_parse_failure("changed primary tools", function(results)
  local build = vim.json.decode(results.build.stdout)
  build.tools.edit = false
  build["secret-canary"] = true
  results.build.stdout = vim.json.encode(build)
end)
expect_parse_failure("unexpected disabled agent", function(results)
  results.general.code = 0
  results.general.stdout = "secret-canary"
  results.general.stderr = ""
end)
expect_parse_failure("forbidden side-effect text", function(results)
  results.serve_help.stderr = results.serve_help.stderr .. " network request secret-canary"
end)
expect_parse_failure("overflow marker", function(results)
  results.plan.stdout_overflow = true
  results.plan.stderr = "secret-canary"
end)
expect_parse_failure("nonzero signal", function(results)
  results.title.signal = 9
  results.title.stderr = "secret-canary"
end)
expect_parse_failure("oversized stdout", function(results)
  results.version.stdout = string.rep("x", 1024 * 1024 + 1) .. "secret-canary"
end)
expect_parse_failure("oversized stderr", function(results)
  results.root_help.stderr = string.rep("x", 65537) .. "secret-canary"
end)

local incremental_results, incremental_report = fixture_results()
local parser = validation._test.new_parser()
local expected_name_count = 0
local expected_agent_count = 0
for index, command in ipairs(validation.commands()) do
  local result = incremental_results[command.name]
  local accepted, category = parser:accept(command, result)
  assert(accepted, category)
  if command.name == "names" then
    expected_name_count = 5
  elseif vim.tbl_contains({ "build", "plan", "compaction", "summary", "title" }, command.name) then
    expected_agent_count = expected_agent_count + 1
  end

  result.stdout = "retained-stdout-secret-canary"
  result.stderr = "retained-stderr-secret-canary"
  result.private = { raw = "retained-result-secret-canary" }
  incremental_results[command.name] = nil

  local debug = parser:debug_state()
  eq(debug, {
    index = index,
    version = index >= 1,
    name_count = expected_name_count,
    agent_count = expected_agent_count,
    finished = false,
  }, command.name .. " retains only sanitized parser counters")
  local inspected = vim.inspect(debug)
  assert(not inspected:find("stdout", 1, true), command.name .. " retained stdout")
  assert(not inspected:find("stderr", 1, true), command.name .. " retained stderr")
  assert(not inspected:find("secret-canary", 1, true), command.name .. " retained raw result data")
end

local incremental_parsed, incremental_error = parser:finish()
assert(incremental_parsed, incremental_error)
eq(incremental_parsed, incremental_report, "incremental parser produces the audited report")
eq(parser:debug_state(), {
  index = #expected_commands,
  version = true,
  name_count = 0,
  agent_count = 0,
  finished = true,
}, "finished parser drops sanitized working data")
local replay, replay_error = parser:finish()
assert(replay == nil, "finished parser accepted a second finish")
eq(replay_error, "parse-failure", "second finish category")

local inspect_lock = registry._test.inspect_opencode_probe_lock
assert(type(inspect_lock) == "function", "Task 3 OpenCode lock classifier export is missing")

local fixed_lock = "0a009c556ac8352fed53ef8323a3a97270935d30.lock"
local fixture_hostname = "fixture-host"
local fixture_metadata = table.concat({
  "{",
  '  "token": "00112233-4455-4677-8899-aabbccddeeff",',
  '  "pid": 2,',
  '  "hostname": "' .. fixture_hostname .. '",',
  '  "createdAt": "2026-08-27T12:00:00.000Z"',
  "}",
}, "\n")

local function new_lock_filesystem(form, configure)
  local tree = { state = "/fixture/xdg-state" }
  local state = tree.state .. "/opencode"
  local lock_root = state .. "/locks"
  local lock = lock_root .. "/" .. fixed_lock
  local paths = {
    state = state,
    lock_root = lock_root,
    lock = lock,
    heartbeat = lock .. "/heartbeat",
    metadata = lock .. "/meta.json",
  }
  local nodes = {}
  local next_inode = 100

  local function stat(node_type, mode, size)
    next_inode = next_inode + 1
    return {
      type = node_type,
      dev = 1,
      ino = next_inode,
      mode = mode,
      uid = 1000,
      size = size or 0,
      mtime = { sec = 1, nsec = next_inode },
      ctime = { sec = 1, nsec = next_inode },
    }
  end

  local function directory(path, entries)
    nodes[path] = {
      stat = stat("directory", 448),
      entries = vim.deepcopy(entries or {}),
    }
  end

  local function file(path, bytes)
    nodes[path] = {
      stat = stat("file", 384, #bytes),
      bytes = bytes,
    }
  end

  directory(state)
  if form ~= "absent" then
    nodes[state].entries = { "locks" }
    directory(lock_root)
  end
  if not vim.tbl_contains({ "absent", "empty-root" }, form) then
    nodes[lock_root].entries = { fixed_lock }
    directory(lock)
  end
  if form == "heartbeat" or form == "full" then
    nodes[lock].entries[#nodes[lock].entries + 1] = "heartbeat"
    file(paths.heartbeat, "")
  end
  if form == "metadata" or form == "full" then
    nodes[lock].entries[#nodes[lock].entries + 1] = "meta.json"
    file(paths.metadata, fixture_metadata)
  end

  table.sort(nodes[state].entries)
  if nodes[lock_root] then
    table.sort(nodes[lock_root].entries)
  end
  if nodes[lock] then
    table.sort(nodes[lock].entries)
  end

  local fixture = {
    nodes = nodes,
    paths = paths,
    replace_path = nil,
    sha256 = nil,
    traversal_failure = nil,
  }
  if configure then
    configure(fixture, directory, file)
  end

  local descriptors = {}
  local lstat_calls = {}
  local next_descriptor = 10
  local filesystem = {
    getuid = function()
      return 1000
    end,
    hostname = function()
      return fixture_hostname
    end,
    sha256 = fixture.sha256 or vim.fn.sha256,
    time = os.time,
  }

  function filesystem.lstat(path)
    local node = nodes[path]
    if not node then
      return nil, "no such file or directory", "ENOENT"
    end
    lstat_calls[path] = (lstat_calls[path] or 0) + 1
    local result = vim.deepcopy(node.stat)
    if fixture.replace_path == path and lstat_calls[path] > 1 then
      result.ino = result.ino + 1000
    end
    return result
  end

  function filesystem.open(path)
    local node = nodes[path]
    if not node then
      return nil
    end
    next_descriptor = next_descriptor + 1
    descriptors[next_descriptor] = {
      path = path,
      node = node,
      stat = vim.deepcopy(node.stat),
    }
    return next_descriptor
  end

  function filesystem.fstat(descriptor)
    local opened = descriptors[descriptor]
    return opened and vim.deepcopy(opened.stat) or nil
  end

  function filesystem.read(descriptor, length, offset)
    local opened = descriptors[descriptor]
    if not opened or type(opened.node.bytes) ~= "string" then
      return nil
    end
    return opened.node.bytes:sub(offset + 1, offset + length)
  end

  function filesystem.close(descriptor)
    if not descriptors[descriptor] then
      return nil
    end
    descriptors[descriptor] = nil
    return true
  end

  function filesystem.scandir(descriptor_path)
    local descriptor = tonumber(descriptor_path:match("/proc/self/fd/(%d+)$"))
    local opened = descriptor and descriptors[descriptor] or nil
    if not opened or opened.path == fixture.traversal_failure then
      return nil
    end
    return {
      entries = vim.deepcopy(opened.node.entries),
      index = 0,
    }
  end

  function filesystem.scandir_next(request)
    request.index = request.index + 1
    return request.entries[request.index]
  end

  return tree, filesystem, fixture
end

local function inspect_lock_form(form, configure)
  local tree, filesystem, fixture = new_lock_filesystem(form, configure)
  local snapshot, category = inspect_lock(tree, filesystem)
  return snapshot, category, fixture
end

local absent = assert(inspect_lock_form("absent"))
eq(absent, {
  disposition = "quiescent",
  fingerprint = "absent",
}, "absent lock form")

local empty_root = assert(inspect_lock_form("empty-root"))
eq(empty_root, {
  disposition = "quiescent",
  fingerprint = "empty",
}, "empty lock-root form")

local full = assert(inspect_lock_form("full"))
eq(full.disposition, "quiescent", "full lock form")
assert(
  full.fingerprint:match("^full:[0-9a-f]+$") and #full.fingerprint == 69,
  "full lock fingerprint is not a bounded SHA-256"
)
eq(
  full.fingerprint,
  "full:" .. vim.fn.sha256(fixture_metadata),
  "full lock fingerprint hashes the exact validated metadata bytes"
)
assert(not full.fingerprint:find(fixture_hostname, 1, true), "full fingerprint leaked hostname")
assert(not full.fingerprint:find("00112233", 1, true), "full fingerprint leaked UUID bytes")

for _, form in ipairs({ "empty-directory", "heartbeat", "metadata" }) do
  local partial = assert(inspect_lock_form(form))
  eq(partial.disposition, "transient", form .. " lock form")
  assert(
    partial.fingerprint:match("^partial:[a-z-]+$") ~= nil,
    form .. " partial fingerprint is unbounded"
  )
end

local unsafe_lock_forms = {
  {
    label = "unknown root entry",
    form = "absent",
    category = "probe-lock-tree",
    configure = function(fixture)
      fixture.nodes[fixture.paths.state].entries = { "unknown-secret-canary" }
    end,
  },
  {
    label = "unknown fixed-directory entry",
    form = "full",
    category = "probe-lock-tree",
    configure = function(fixture)
      fixture.nodes[fixture.paths.lock].entries[#fixture.nodes[fixture.paths.lock].entries + 1] =
        "unknown-secret-canary"
    end,
  },
  {
    label = "lock symlink",
    form = "empty-root",
    category = "probe-lock-tree",
    configure = function(fixture)
      fixture.nodes[fixture.paths.lock_root].stat.type = "link"
    end,
  },
  {
    label = "lock FIFO",
    form = "empty-directory",
    category = "probe-lock-tree",
    configure = function(fixture)
      fixture.nodes[fixture.paths.lock].stat.type = "fifo"
    end,
  },
  {
    label = "wrong directory owner",
    form = "empty-directory",
    category = "probe-lock-tree",
    configure = function(fixture)
      fixture.nodes[fixture.paths.lock].stat.uid = 1001
    end,
  },
  {
    label = "wrong directory mode",
    form = "empty-root",
    category = "probe-lock-tree",
    configure = function(fixture)
      fixture.nodes[fixture.paths.lock_root].stat.mode = 493
    end,
  },
  {
    label = "wrong file owner",
    form = "full",
    category = "probe-heartbeat",
    configure = function(fixture)
      fixture.nodes[fixture.paths.heartbeat].stat.uid = 1001
    end,
  },
  {
    label = "wrong file mode",
    form = "full",
    category = "probe-heartbeat",
    configure = function(fixture)
      fixture.nodes[fixture.paths.heartbeat].stat.mode = 420
    end,
  },
  {
    label = "nonempty heartbeat",
    form = "full",
    category = "probe-heartbeat",
    configure = function(fixture)
      fixture.nodes[fixture.paths.heartbeat].bytes = "secret-canary"
      fixture.nodes[fixture.paths.heartbeat].stat.size = #"secret-canary"
    end,
  },
  {
    label = "malformed metadata",
    form = "full",
    category = "probe-lock-metadata",
    configure = function(fixture)
      fixture.nodes[fixture.paths.metadata].bytes = "secret-canary"
      fixture.nodes[fixture.paths.metadata].stat.size = #"secret-canary"
    end,
  },
  {
    label = "oversized metadata",
    form = "full",
    category = "probe-lock-metadata",
    configure = function(fixture)
      fixture.nodes[fixture.paths.metadata].bytes = string.rep("x", 513)
      fixture.nodes[fixture.paths.metadata].stat.size = 513
    end,
  },
  {
    label = "metadata replacement race",
    form = "full",
    category = "probe-lock-metadata",
    configure = function(fixture)
      fixture.replace_path = fixture.paths.metadata
    end,
  },
  {
    label = "lock-directory replacement race",
    form = "full",
    category = "probe-lock-tree",
    configure = function(fixture)
      fixture.replace_path = fixture.paths.lock
    end,
  },
  {
    label = "invalid metadata digest",
    form = "full",
    category = "probe-lock-metadata",
    configure = function(fixture)
      fixture.sha256 = function()
        return string.rep("A", 64)
      end
    end,
  },
  {
    label = "descriptor traversal failure",
    form = "full",
    category = "probe-lock-tree",
    configure = function(fixture)
      fixture.traversal_failure = fixture.paths.lock
    end,
  },
  {
    label = "lock entry cap",
    form = "absent",
    category = "probe-lock-tree",
    configure = function(fixture)
      local entries = {}
      for index = 1, 33 do
        entries[index] = string.format("entry-%02d", index)
      end
      fixture.nodes[fixture.paths.state].entries = entries
    end,
  },
}

for _, case in ipairs(unsafe_lock_forms) do
  local snapshot, category = inspect_lock_form(case.form, case.configure)
  assert(snapshot == nil, case.label .. " was accepted")
  eq(category, case.category, case.label .. " category")
  assert(not category:find("secret-canary", 1, true), case.label .. " leaked artifact bytes")
  assert(#category <= 64, case.label .. " returned an unbounded category")
end

local settle_lock = registry._test.settle_opencode_probe_lock
assert(type(settle_lock) == "function", "Task 3 OpenCode lock settler export is missing")

local ABSENT_LOCK = { disposition = "quiescent", fingerprint = "absent" }
local EMPTY_LOCK = { disposition = "quiescent", fingerprint = "empty" }
local FULL_LOCK_A = { disposition = "quiescent", fingerprint = "full:" .. string.rep("a", 64) }
local FULL_LOCK_B = { disposition = "quiescent", fingerprint = "full:" .. string.rep("b", 64) }
local PARTIAL_HEARTBEAT = {
  disposition = "transient",
  fingerprint = "partial:heartbeat",
}
local PARTIAL_METADATA = { disposition = "transient", fingerprint = "partial:metadata" }

local function new_settle_fixture(initial, snapshots)
  local fixture = {
    now_ms = 0,
    snapshots = vim.deepcopy(snapshots),
    inspect_calls = 0,
    timers = {},
    callbacks = {},
  }

  local function inspect()
    fixture.inspect_calls = fixture.inspect_calls + 1
    local next_snapshot = table.remove(fixture.snapshots, 1)
    assert(next_snapshot, "settling fixture has no classifier snapshot")
    if next_snapshot.category then
      return nil, next_snapshot.category
    end
    return vim.deepcopy(next_snapshot)
  end

  fixture.cancel = settle_lock({}, vim.deepcopy(initial), {
    now = function()
      return fixture.now_ms
    end,
    defer = function(callback, delay_ms)
      local timer = {
        callback = callback,
        delay_ms = delay_ms,
        stopped = false,
        closed = false,
        fired = false,
      }
      function timer:stop()
        self.stopped = true
      end
      function timer:is_closing()
        return self.closed
      end
      function timer:close()
        self.closed = true
      end
      fixture.timers[#fixture.timers + 1] = timer
      return timer
    end,
    inspect_lock = inspect,
  }, function(accepted, category, snapshot)
    fixture.callbacks[#fixture.callbacks + 1] = {
      accepted = accepted == true,
      category = category or "",
      snapshot = snapshot and vim.deepcopy(snapshot) or false,
    }
  end)

  function fixture:fire(elapsed)
    self.now_ms = elapsed
    for _, timer in ipairs(self.timers) do
      if not timer.fired then
        timer.fired = true
        timer.callback()
        return timer
      end
    end
    error("settling fixture has no pending timer")
  end

  return fixture
end

local function expect_settle_acceptance(label, initial, snapshots, times, expected)
  local fixture = new_settle_fixture(initial, snapshots)
  for _, elapsed in ipairs(times) do
    local timer = fixture:fire(elapsed)
    eq(timer.delay_ms, 50, label .. " timer interval")
  end
  eq(#fixture.callbacks, 1, label .. " callback count")
  eq(fixture.callbacks[1], {
    accepted = true,
    category = "",
    snapshot = expected,
  }, label .. " accepted snapshot")
  local final_timer = fixture.timers[#fixture.timers]
  assert(final_timer.stopped, label .. " final timer was not stopped")
  assert(final_timer.closed, label .. " final timer was not closed")
end

expect_settle_acceptance("absent stable trace", ABSENT_LOCK, { ABSENT_LOCK }, { 50 }, ABSENT_LOCK)
expect_settle_acceptance(
  "empty to full trace",
  EMPTY_LOCK,
  { FULL_LOCK_A, FULL_LOCK_A },
  { 50, 100 },
  FULL_LOCK_A
)
expect_settle_acceptance(
  "partial heartbeat to full trace",
  PARTIAL_HEARTBEAT,
  { FULL_LOCK_A, FULL_LOCK_A },
  { 50, 100 },
  FULL_LOCK_A
)

do
  local snapshots = {}
  local times = {}
  for index = 1, 20 do
    snapshots[index] = PARTIAL_METADATA
    times[index] = index * 50
  end
  local fixture = new_settle_fixture(PARTIAL_METADATA, snapshots)
  for _, elapsed in ipairs(times) do
    fixture:fire(elapsed)
  end
  eq(#fixture.callbacks, 1, "persistent partial metadata callback count")
  eq(fixture.callbacks[1], {
    accepted = false,
    category = "probe-lock-tree",
    snapshot = false,
  }, "persistent partial metadata deadline")
  eq(fixture.inspect_calls, 20, "persistent partial metadata exact snapshot count")
  assert(fixture.timers[#fixture.timers].stopped, "partial deadline timer was not stopped")
  assert(fixture.timers[#fixture.timers].closed, "partial deadline timer was not closed")
end

do
  local fixture = new_settle_fixture(ABSENT_LOCK, { { category = "probe-lock-tree" } })
  fixture:fire(50)
  eq(fixture.callbacks[1], {
    accepted = false,
    category = "probe-lock-tree",
    snapshot = false,
  }, "unsafe entry fails settling immediately")
  eq(fixture.inspect_calls, 1, "unsafe entry stops after one snapshot")
  eq(#fixture.timers, 1, "unsafe entry schedules no successor timer")
end

expect_settle_acceptance(
  "changed full fingerprint trace",
  FULL_LOCK_A,
  { FULL_LOCK_B, FULL_LOCK_B },
  { 50, 100 },
  FULL_LOCK_B
)

do
  local fixture = new_settle_fixture(FULL_LOCK_A, {})
  fixture:fire(1001)
  eq(fixture.callbacks[1], {
    accepted = false,
    category = "probe-lock-tree",
    snapshot = false,
  }, "late first timer misses the strict settling ceiling")
  eq(fixture.inspect_calls, 0, "late first timer cannot inspect or accept")
end

do
  local fixture = new_settle_fixture(ABSENT_LOCK, { ABSENT_LOCK })
  local pending = fixture.timers[1]
  fixture.cancel()
  eq(#fixture.callbacks, 1, "settling cancellation callback count")
  eq(fixture.callbacks[1], {
    accepted = false,
    category = "cancellation",
    snapshot = false,
  }, "settling cancellation category")
  assert(pending.stopped, "settling cancellation did not stop its timer")
  assert(pending.closed, "settling cancellation did not close its timer")
  fixture.cancel()
  pending.callback()
  eq(#fixture.callbacks, 1, "settling cancellation callback is at most once")
  eq(fixture.inspect_calls, 0, "late cancelled timer cannot inspect or accept")
end

local function deferred_exception(canary)
  local value = setmetatable({ private = canary }, {
    __tostring = function()
      return canary
    end,
  })
  local weak = setmetatable({ value }, { __mode = "v" })
  return weak, function()
    local current = value
    value = nil
    error(current, 0)
  end
end

local function deferred_failure_fixture(kind)
  local canary = "settler-" .. kind .. "-exception-secret-canary"
  local weak, throw_exception = deferred_exception(canary)
  local fixture = {
    callbacks = {},
    defer_calls = 0,
    inspect_calls = 0,
    now_calls = 0,
    now_ms = 0,
    timers = {},
  }

  local function now()
    fixture.now_calls = fixture.now_calls + 1
    if kind == "now" and fixture.now_calls > 1 then
      throw_exception()
    end
    return fixture.now_ms
  end

  local function inspect()
    fixture.inspect_calls = fixture.inspect_calls + 1
    if kind == "inspect" then
      throw_exception()
    end
    return vim.deepcopy(FULL_LOCK_A)
  end

  local function defer(callback, delay_ms)
    fixture.defer_calls = fixture.defer_calls + 1
    if kind == "successor-defer" and fixture.defer_calls > 1 then
      throw_exception()
    end
    local timer = {
      callback = callback,
      delay_ms = delay_ms,
      stopped = false,
      closed = false,
    }
    function timer:stop()
      self.stopped = true
    end
    function timer:is_closing()
      return self.closed
    end
    function timer:close()
      self.closed = true
    end
    fixture.timers[#fixture.timers + 1] = timer
    return timer
  end

  fixture.cancel = settle_lock({}, vim.deepcopy(ABSENT_LOCK), {
    now = now,
    inspect_lock = inspect,
    defer = defer,
  }, function(accepted, category, snapshot)
    fixture.callbacks[#fixture.callbacks + 1] = {
      arity = select("#", accepted, category, snapshot),
      accepted = accepted,
      category = category,
      snapshot = snapshot,
    }
  end)
  fixture.canary = canary
  fixture.weak = weak
  return fixture
end

for _, kind in ipairs({ "now", "inspect", "successor-defer" }) do
  local fixture = deferred_failure_fixture(kind)
  eq(#fixture.timers, 1, kind .. " failure starts with one pending timer")
  local pending = fixture.timers[1]
  eq(pending.delay_ms, 50, kind .. " failure timer interval")
  fixture.now_ms = 50
  local fire_ok = pcall(pending.callback)
  assert(fire_ok, kind .. " deferred dependency exception escaped its timer callback")
  eq(#fixture.callbacks, 1, kind .. " failure callback count")
  eq(fixture.callbacks[1].arity, 3, kind .. " failure callback arity")
  eq(fixture.callbacks[1].accepted, nil, kind .. " failure acceptance")
  eq(fixture.callbacks[1].category, "probe-lock-tree", kind .. " bounded category")
  eq(fixture.callbacks[1].snapshot, nil, kind .. " failure snapshot")
  assert(pending.stopped, kind .. " failure did not stop its current timer")
  assert(pending.closed, kind .. " failure did not close its current timer")
  eq(#fixture.timers, 1, kind .. " failure retained a successor timer")
  assert(
    not vim.inspect(fixture.callbacks):find(fixture.canary, 1, true),
    kind .. " failure exposed its exception canary"
  )
  fixture.cancel()
  pending.callback()
  eq(#fixture.callbacks, 1, kind .. " failure delivered a duplicate or late acceptance")
  collectgarbage("collect")
  collectgarbage("collect")
  assert(fixture.weak[1] == nil, kind .. " failure retained its arbitrary exception object")
end

local IDENTITY_KEY = string.rep("a", 32)
local OTHER_IDENTITY_KEY = string.rep("b", 32)
local DEFAULT_METADATA = "1:2:493:0:3:4:5:6:7"

eq(validation._test.new_idle_snapshot(), {
  state = "not_checked",
  installed = false,
  executable = "",
  version = "",
  category = "",
  queued = false,
}, "passive initial snapshot")

local function new_controller_fixture(options)
  options = options or {}
  local fixture = {
    identity = {
      installed = true,
      executable = "/usr/bin/opencode",
      metadata = DEFAULT_METADATA,
    },
    starts = {},
    pending = {},
    cancel_reasons = {},
    drain_calls = {},
    drain_result = options.drain_result ~= false,
    notifications = {},
    timers = {},
    scheduled = {},
    now_ms = options.now_ms or 1000,
  }

  local function schedule(callback)
    if options.queued_schedule then
      fixture.scheduled[#fixture.scheduled + 1] = callback
    else
      callback()
    end
  end

  fixture.controller = validation._test.new({
    cache = options.cache,
    identify = function()
      return vim.deepcopy(fixture.identity)
    end,
    start_probe = function(identity, command, complete)
      if options.start_probe then
        return options.start_probe(identity, command, complete)
      end
      local handle = {}
      local start = {
        identity = vim.deepcopy(identity),
        command = vim.deepcopy(command),
        complete = complete,
        handle = handle,
      }
      fixture.starts[#fixture.starts + 1] = start
      fixture.pending[#fixture.pending + 1] = start
      function handle:cancel(reason)
        fixture.cancel_reasons[#fixture.cancel_reasons + 1] = reason
      end
      function handle:shutdown_drain(timeout_ms)
        fixture.drain_calls[#fixture.drain_calls + 1] = timeout_ms
        return fixture.drain_result
      end
      return handle
    end,
    now = function()
      return fixture.now_ms
    end,
    defer = function(callback, delay_ms)
      local timer = {
        callback = callback,
        delay_ms = delay_ms,
        stopped = false,
        closed = false,
      }
      function timer:stop()
        self.stopped = true
      end
      function timer:is_closing()
        return self.closed
      end
      function timer:close()
        self.closed = true
      end
      fixture.timers[#fixture.timers + 1] = timer
      return timer
    end,
    schedule = schedule,
    notify = function(message, level)
      fixture.notifications[#fixture.notifications + 1] = {
        message = message,
        level = level,
      }
    end,
    warn_level = vim.log.levels.WARN,
  })

  function fixture:complete_next(result, category)
    local current = table.remove(self.pending, 1)
    assert(current and type(current.complete) == "function", "fixture has no pending probe")
    current.complete(result, category)
    return current.complete
  end

  function fixture:flush_scheduled()
    while #self.scheduled > 0 do
      local callback = table.remove(self.scheduled, 1)
      callback()
    end
  end

  return fixture
end

local function run_to_ready(fixture)
  local results, report = fixture_results()
  local last_callback
  local start_offset = #fixture.starts - 1
  for index, command in ipairs(expected_commands) do
    eq(#fixture.pending, 1, command.name .. " is the sole pending command")
    local start = fixture.starts[start_offset + index]
    eq(start.command, command, command.name .. " starts in fixed order")
    eq(start.identity, fixture.identity, command.name .. " uses the stable identity")
    local result = vim.deepcopy(results[command.name])
    result.private = "completed-result-secret-canary"
    last_callback = fixture:complete_next(result, "")
    local inspected = vim.inspect(fixture.controller:debug_state())
    assert(not inspected:find("secret-canary", 1, true), command.name .. " retained result content")
    assert(not inspected:find("stdout", 1, true), command.name .. " retained stdout")
    assert(not inspected:find("stderr", 1, true), command.name .. " retained stderr")
    if index < #expected_commands then
      eq(
        #fixture.starts,
        start_offset + index + 1,
        command.name .. " completion starts exactly one successor"
      )
    end
  end
  eq(
    #fixture.starts,
    start_offset + #expected_commands,
    "sequence stops before a thirteenth command"
  )
  eq(#fixture.pending, 0, "ready sequence has no pending command")
  eq(fixture.controller:snapshot().state, "ready", "complete sequence reaches ready")
  return report, last_callback
end

do
  local _, report = fixture_results()
  local lookups, publications = 0, 0
  local fixture = new_controller_fixture({
    cache = {
      lookup = function()
        lookups = lookups + 1
        return report
      end,
      publish = function()
        publications = publications + 1
      end,
    },
  })
  eq(fixture.controller:snapshot().state, "not_checked", "snapshot never reads persistent cache")
  eq(fixture.controller:report(), nil, "report never reads persistent cache")
  eq(lookups, 0, "passive reads are cache-free")
  fixture.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  eq(fixture.controller:snapshot().state, "ready", "valid receipt reaches ready")
  eq(#fixture.starts, 0, "valid receipt skips all probes")
  eq(publications, 0, "cache hits do not extend receipt expiry")
  report.version = "1.18.31"
  eq(fixture.controller:report().version, "1.18.30", "cached reports are copied")
  eq(fixture.controller:take_open(IDENTITY_KEY), true, "cache hit preserves exact queued opening")
  fixture.controller:ensure({ reason = "picker" })
  eq(lookups, 1, "ready controller keeps its in-memory result")
end

do
  for _, broken in ipairs({ false, true }) do
    local publications = 0
    local fixture = new_controller_fixture({
      cache = {
        lookup = function()
          if broken then
            error("fixture cache read failure")
          end
          return { version = "1.18.30" }, { key = "fixture" }
        end,
        publish = function()
          publications = publications + 1
          error("fixture cache write failure")
        end,
      },
    })
    fixture.controller:ensure({ reason = "picker" })
    eq(fixture.controller:snapshot().state, "checking", "bad cache requires full audit")
    run_to_ready(fixture)
    eq(publications, broken and 0 or 1, "only successful ticketed audits attempt publication")
  end
end

do
  local publications, lookups = 0, 0
  local fixture = new_controller_fixture({
    cache = {
      lookup = function()
        lookups = lookups + 1
        return nil, { key = "fixture" }
      end,
      publish = function()
        publications = publications + 1
      end,
    },
  })
  fixture.controller:ensure({ reason = "picker" })
  eq(publications, 0, "an incomplete audit cannot persist a receipt")
  local result = fixture_results().version
  result.code = 126
  fixture:complete_next(result, "")
  eq(publications, 0, "failed audits are not persisted")
  fixture.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  eq(lookups, 1, "explicit failed-audit retry bypasses old cache")
  run_to_ready(fixture)
end

do
  local _, report = fixture_results()
  local fixture
  fixture = new_controller_fixture({
    cache = {
      lookup = function()
        fixture.identity.metadata = "replacement-during-cache-read"
        return report
      end,
    },
  })
  fixture.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  eq(fixture.controller:snapshot().state, "not_checked", "identity drift discards cached evidence")
  eq(fixture.controller:take_open(IDENTITY_KEY), false, "drift cannot open a queued companion")
  eq(#fixture.starts, 0, "drift awaits a new explicit request")
end

do
  local fixture = new_controller_fixture()
  fixture.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  local result = fixture_results().version
  result.stdout = "1.18.31\n"
  fixture:complete_next(result, "")
  eq(fixture.controller:snapshot(), {
    state = "failed",
    installed = true,
    executable = "/usr/bin/opencode",
    version = "1.18.31",
    category = "version-mismatch",
    queued = false,
  }, "version rejection retains only a safe diagnostic")
  eq(fixture.controller:report(), nil, "mismatch has no compatibility evidence")
  eq(fixture.controller:take_open(IDENTITY_KEY), false, "mismatch cancels queued open")
  eq(#fixture.starts, 1, "mismatch stops before help or semantic probes")
  eq(
    fixture.notifications[1].message,
    "managed OpenCode version mismatch: installed 1.18.31; requires 1.18.30",
    "notification identifies detected and audited releases"
  )
  fixture.controller:ensure({ reason = "picker" })
  eq(#fixture.starts, 1, "passive picker does not retry failed validation")
  fixture.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  eq(fixture.controller:snapshot().version, "", "explicit retry clears stale version")
  local malformed = fixture_results().version
  malformed.stdout = "1.18.31 secret-canary\n"
  fixture:complete_next(malformed, "")
  eq(fixture.controller:snapshot().category, "parse-failure", "malformed retry stays generic")
  eq(fixture.controller:snapshot().version, "", "malformed retry retains no output")
  assert(not vim.inspect(fixture.notifications):find("secret-canary", 1, true))
  fixture.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  fixture:complete_next(result, "")
  eq(fixture.controller:snapshot().version, "1.18.31", "valid mismatch is captured on retry")
  fixture.identity.metadata = DEFAULT_METADATA .. "-changed"
  eq(fixture.controller:snapshot().version, "", "executable drift clears failed evidence")
  fixture.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  fixture:complete_next(result, "")
  eq(fixture.controller:snapshot().version, "1.18.31", "new identity captures its own version")
  fixture.controller:shutdown(false)
  eq(fixture.controller:snapshot().version, "", "shutdown clears observed version")
end

do
  local pending = {}
  local starts = {}
  local cancel_reasons = {}
  local wait_calls = 0
  local controller = validation._test.new({
    identify = function()
      return {
        installed = true,
        executable = "/usr/bin/opencode",
        metadata = DEFAULT_METADATA,
      }
    end,
    start_probe = function(identity, command, complete)
      starts[#starts + 1] = {
        identity = vim.deepcopy(identity),
        command = vim.deepcopy(command),
      }
      pending[#pending + 1] = complete
      return {
        cancel = function(_, reason)
          cancel_reasons[#cancel_reasons + 1] = reason
        end,
        shutdown_drain = function()
          wait_calls = wait_calls + 1
          return true
        end,
      }
    end,
    now = vim.uv.now,
    defer = vim.defer_fn,
    schedule = vim.schedule,
    notify = function() end,
    warn_level = vim.log.levels.WARN,
  })

  local timer_progressed = false
  vim.defer_fn(function()
    timer_progressed = true
  end, 10)

  eq(
    controller:ensure({ reason = "open", identity_key = IDENTITY_KEY }).state,
    "checking",
    "explicit request starts checking"
  )
  assert(
    vim.wait(250, function()
      return timer_progressed
    end, 5),
    "Neovim timer did not progress while validation remained pending"
  )
  eq(controller:snapshot().state, "checking", "delayed probe remains pending")
  eq(#starts, 1, "only the first delayed probe starts")
  eq(wait_calls, 0, "ordinary validation never enters the exit-only drain")
  eq(controller:shutdown(false), true, "ordinary responsiveness fixture shuts down")
  eq(cancel_reasons, { "shutdown" }, "ordinary shutdown cancels the delayed probe")
  eq(wait_calls, 0, "ordinary shutdown does not wait")
end

do
  local fixture = new_controller_fixture()
  for _, method in ipairs({
    "snapshot",
    "report",
    "ensure",
    "take_open",
    "cancel",
    "subscribe",
    "shutdown",
    "debug_state",
  }) do
    eq(type(fixture.controller[method]), "function", method .. " controller method exists")
  end
  eq(fixture.controller:snapshot(), {
    state = "not_checked",
    installed = true,
    executable = "/usr/bin/opencode",
    version = "",
    category = "",
    queued = false,
  }, "snapshot is passive and identifies without probing")
  assert(fixture.controller:report() == nil, "passive report returned a compatibility cache")
  eq(#fixture.starts, 0, "passive snapshot starts no probe")
  eq(#fixture.timers, 0, "passive snapshot starts no timer")
  eq(fixture.controller:debug_state().phase, "unknown", "passive internal phase is unknown")

  local first = fixture.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  eq(first.state, "checking", "open request enters checking")
  eq(first.queued, true, "open request stores one identity token")
  fixture.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  fixture.controller:ensure({ reason = "picker" })
  eq(#fixture.starts, 1, "repeated requests share one sequence")
  eq(#fixture.pending, 1, "repeated requests keep one pending command")
  eq(#fixture.timers, 1, "one sequence creates one controller timer")
  eq(fixture.timers[1].delay_ms, 60000, "sequence timer uses the total ceiling")
  local changed_key, changed_key_error = fixture.controller:ensure({
    reason = "open",
    identity_key = OTHER_IDENTITY_KEY,
  })
  assert(changed_key == nil, "checking accepted a replacement opening identity")
  eq(changed_key_error, "managed OpenCode opening identity changed", "replacement identity error")

  local report, last_callback = run_to_ready(fixture)
  eq(fixture.controller:debug_state().phase, "ready", "successful internal phase is ready")
  eq(fixture.controller:report(), report, "ready report is sanitized")
  local changed_report = fixture.controller:report()
  changed_report.version = "changed"
  changed_report.agents.build.permission = "changed"
  eq(fixture.controller:report(), report, "report callers cannot mutate the cache")
  local changed_snapshot = fixture.controller:snapshot()
  changed_snapshot.state = "failed"
  changed_snapshot.executable = "secret-canary"
  eq(fixture.controller:snapshot().state, "ready", "snapshot callers cannot mutate state")
  eq(#fixture.timers, 1, "commands create no per-command controller timers")
  assert(fixture.timers[1].stopped, "successful sequence did not stop its total timer")

  local starts_before_cache = #fixture.starts
  eq(fixture.controller:ensure({ reason = "picker" }).state, "ready", "picker reuses ready cache")
  eq(#fixture.starts, starts_before_cache, "ready cache starts no new sequence")
  eq(fixture.controller:take_open(IDENTITY_KEY), true, "queued opening is consumed once")
  eq(fixture.controller:take_open(IDENTITY_KEY), false, "queued opening cannot be replayed")
  eq(
    fixture.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY }).state,
    "ready",
    "ready cache accepts a fresh opening intent"
  )
  eq(#fixture.starts, starts_before_cache, "ready opening starts no new sequence")
  eq(fixture.controller:take_open(IDENTITY_KEY), true, "fresh ready opening is consumed")
  last_callback(vim.deepcopy(fixture_results().explore), "")
  eq(#fixture.starts, #expected_commands, "late final callback cannot start a thirteenth command")
  eq(fixture.controller:snapshot().state, "ready", "late final callback cannot replace ready")

  fixture.identity.metadata = "1:2:493:0:3:4:5:6:8"
  eq(fixture.controller:snapshot(), {
    state = "not_checked",
    installed = true,
    executable = "/usr/bin/opencode",
    version = "",
    category = "",
    queued = false,
  }, "metadata drift invalidates the ready cache")
  assert(fixture.controller:report() == nil, "metadata drift retained a ready report")
  fixture.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  eq(#fixture.starts, #expected_commands + 1, "explicit request starts after metadata drift")
  local second_report = run_to_ready(fixture)
  eq(fixture.controller:report(), second_report, "metadata drift permits a fresh full sequence")
  eq(#fixture.starts, #expected_commands * 2, "metadata retry executes exactly twelve commands")
  eq(#fixture.timers, 2, "each explicit sequence owns one total timer")
  fixture.controller:shutdown(false)
  eq(#fixture.drain_calls, 0, "ready shutdown does not wait")
end

do
  local function collect_twice()
    collectgarbage("collect")
    collectgarbage("collect")
  end

  local returned_handle = { private = "returned-handle-secret-canary" }
  local returned_error = { private = "returned-error-secret-canary" }
  local returned_weak = setmetatable({ returned_handle, returned_error }, { __mode = "v" })
  local returned = new_controller_fixture({
    queued_schedule = true,
    start_probe = function()
      local handle = returned_handle
      local start_error = returned_error
      returned_handle = nil
      returned_error = nil
      return handle, start_error
    end,
  })
  returned.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  eq(#returned.scheduled, 1, "returned start failure schedules one bounded completion")
  collect_twice()
  assert(returned_weak[1] == nil, "invalid returned handle remained retained")
  assert(returned_weak[2] == nil, "arbitrary returned start error remained retained")
  returned:flush_scheduled()
  eq(returned.controller:snapshot().state, "failed", "returned start error fails validation")
  eq(returned.controller:snapshot().category, "probe-failure", "returned error is normalized")
  returned.controller:shutdown(false)

  local thrown_error = { private = "thrown-error-secret-canary" }
  local thrown_weak = setmetatable({ thrown_error }, { __mode = "v" })
  local thrown = new_controller_fixture({
    queued_schedule = true,
    start_probe = function()
      local start_error = thrown_error
      thrown_error = nil
      error(start_error, 0)
    end,
  })
  thrown.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  eq(#thrown.scheduled, 1, "thrown start failure schedules one bounded completion")
  collect_twice()
  assert(thrown_weak[1] == nil, "arbitrary thrown start error remained retained")
  thrown:flush_scheduled()
  eq(thrown.controller:snapshot().state, "failed", "thrown start error fails validation")
  eq(thrown.controller:snapshot().category, "probe-failure", "thrown error is normalized")
  thrown.controller:shutdown(false)
end

do
  for _, reason in ipairs({ "close", "backend-switch" }) do
    local fixture = new_controller_fixture()
    fixture.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
    run_to_ready(fixture)
    eq(fixture.controller:snapshot().queued, true, reason .. " ready fixture retains its opening")
    local observed = {}
    assert(fixture.controller:subscribe(function(snapshot)
      observed[#observed + 1] = snapshot
    end))
    fixture.identity.metadata = "1:2:493:0:3:4:5:6:8"
    fixture.controller:cancel(reason)
    eq(
      fixture.controller:snapshot().state,
      "not_checked",
      reason .. " reconciles ready metadata before publishing"
    )
    assert(fixture.controller:report() == nil, reason .. " retained a stale ready report")
    eq(fixture.controller:snapshot().queued, false, reason .. " retained a stale opening")
    eq(#observed, 1, reason .. " publishes exactly one reconciled snapshot")
    eq(observed[1].state, "not_checked", reason .. " observer saw stale ready")
    eq(observed[1].queued, false, reason .. " observer saw a stale opening")
    fixture.controller:shutdown(false)
  end
end

do
  local fixture = new_controller_fixture()
  fixture.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  fixture:complete_next(nil, "probe-failure")
  eq(fixture.controller:snapshot().state, "failed", "probe failure becomes visible")
  eq(fixture.controller:debug_state().phase, "failed", "failed internal phase is retained")
  eq(fixture.controller:snapshot().category, "probe-failure", "probe failure is generic")
  eq(fixture.controller:snapshot().queued, false, "probe failure clears the opening")
  assert(fixture.controller:report() == nil, "probe failure created a report")
  eq(#fixture.starts, 1, "failure does not retry automatically")
  eq(#fixture.notifications, 1, "one failed attempt emits one notification")
  eq(
    fixture.notifications[1].message,
    "managed OpenCode validation failed: probe-failure",
    "failure notification is bounded"
  )
  eq(fixture.notifications[1].level, vim.log.levels.WARN, "failure notification level")
  fixture.controller:snapshot()
  fixture.controller:ensure({ reason = "picker" })
  eq(#fixture.starts, 1, "passive reads do not retry a failure")
  eq(#fixture.notifications, 1, "passive reads do not repeat a notification")

  fixture.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  eq(#fixture.starts, 2, "explicit open retries a failed attempt")
  fixture:complete_next(nil, "probe-failure")
  eq(#fixture.starts, 2, "second failure also has no automatic retry")
  eq(#fixture.notifications, 2, "two explicit failures emit two notifications")
  assert(fixture.controller:report() == nil, "repeated failure created a report")
  fixture.controller:shutdown(false)
end

do
  local fixture = new_controller_fixture()
  fixture.identity = { installed = false, executable = "", metadata = "" }
  eq(fixture.controller:snapshot().state, "not_checked", "unavailable snapshot stays passive")
  eq(#fixture.starts, 0, "unavailable snapshot starts no probe")
  eq(fixture.controller:ensure({ reason = "picker" }).state, "failed", "unavailable ensure fails")
  eq(fixture.controller:snapshot().category, "unavailable", "unavailable category is bounded")
  eq(#fixture.starts, 0, "unavailable ensure starts no probe")
  eq(#fixture.notifications, 1, "unavailable attempt notifies once")
  fixture.controller:ensure({ reason = "picker" })
  eq(#fixture.notifications, 1, "repeated unavailable picker request does not notify again")
  fixture.controller:shutdown(false)
end

do
  for _, key in ipairs({
    "prompt",
    "selection",
    "line",
    "column",
    "context_file",
    "credentials",
  }) do
    local fixture = new_controller_fixture()
    local request = {
      reason = "open",
      identity_key = IDENTITY_KEY,
      [key] = "request-secret-canary",
    }
    local snapshot, request_error = fixture.controller:ensure(request)
    assert(snapshot == nil, key .. " request content was accepted")
    eq(
      request_error,
      "managed OpenCode compatibility request is invalid",
      key .. " request error is bounded"
    )
    eq(#fixture.starts, 0, key .. " request started validation")
    local inspected = vim.inspect(fixture.controller:debug_state())
    assert(not inspected:find("secret-canary", 1, true), key .. " request content was retained")
    fixture.controller:shutdown(false)
  end

  local invalid_requests = {
    {},
    { reason = "picker", identity_key = IDENTITY_KEY },
    { reason = "open" },
    { reason = "open", identity_key = string.rep("a", 31) },
    { reason = "open", identity_key = string.rep("A", 32) },
    { reason = "unknown" },
  }
  for index, request in ipairs(invalid_requests) do
    local fixture = new_controller_fixture()
    local snapshot, request_error = fixture.controller:ensure(request)
    assert(snapshot == nil, "invalid request " .. index .. " was accepted")
    eq(
      request_error,
      "managed OpenCode compatibility request is invalid",
      "invalid request " .. index .. " error"
    )
    eq(#fixture.starts, 0, "invalid request " .. index .. " started a probe")
    fixture.controller:shutdown(false)
  end
end

do
  local fixture = new_controller_fixture()
  fixture.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  fixture.identity = { installed = false, executable = "", metadata = "" }
  eq(fixture.controller:snapshot().state, "checking", "drift waits for cleanup confirmation")
  eq(fixture.cancel_reasons, { "executable-drift" }, "drift cancels the active handle once")
  assert(fixture.timers[1].stopped, "drift cancellation left the sequence timer running")
  assert(fixture.timers[1].closed, "drift cancellation left the sequence timer open")
  eq(fixture.controller:debug_state().has_timer, false, "drift cancellation releases its timer")
  eq(fixture.controller:snapshot().state, "checking", "second snapshot preserves cancellation")
  eq(fixture.cancel_reasons, { "executable-drift" }, "second snapshot does not cancel twice")
  local cancelling = fixture.controller:ensure({
    reason = "open",
    identity_key = OTHER_IDENTITY_KEY,
  })
  eq(cancelling.state, "checking", "request during drift waits for cleanup")
  eq(cancelling.queued, false, "request during drift cannot replace the cleared queue")
  eq(fixture.controller:debug_state().cancelling, true, "drift remains internally cancelling")
  eq(#fixture.notifications, 0, "drift does not publish unavailable before cleanup")
  fixture:complete_next(nil, "executable-drift")
  eq(fixture.controller:snapshot(), {
    state = "not_checked",
    installed = false,
    executable = "",
    version = "",
    category = "",
    queued = false,
  }, "confirmed drift returns to unknown for the new identity")
  eq(#fixture.notifications, 0, "confirmed drift is cancellation, not a failed attempt")
  fixture.controller:shutdown(false)
end

do
  for _, reason in ipairs({ "close", "backend-switch", "executable-drift" }) do
    local fixture = new_controller_fixture()
    fixture.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
    fixture.controller:cancel(reason)
    eq(fixture.cancel_reasons, { reason }, reason .. " cancels one active probe")
    assert(fixture.timers[1].stopped, reason .. " left the sequence timer running")
    assert(fixture.timers[1].closed, reason .. " left the sequence timer open")
    eq(fixture.controller:debug_state().has_timer, false, reason .. " releases its timer")
    eq(fixture.controller:snapshot().queued, false, reason .. " clears the queued opening")
    fixture:complete_next(
      nil,
      reason == "executable-drift" and "executable-drift" or "cancellation"
    )
    eq(fixture.controller:snapshot().state, "not_checked", reason .. " returns to not_checked")
    eq(#fixture.notifications, 0, reason .. " cancellation does not notify")
    fixture.controller:shutdown(false)
  end

  local cleanup = new_controller_fixture()
  cleanup.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  cleanup.controller:cancel("close")
  cleanup:complete_next(nil, "cleanup-failure")
  eq(cleanup.controller:snapshot().state, "failed", "cleanup uncertainty is a hard failure")
  eq(cleanup.controller:snapshot().category, "cleanup-failure", "cleanup failure category")
  eq(#cleanup.notifications, 1, "cleanup failure notifies once")
  cleanup.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  eq(#cleanup.starts, 2, "cleanup failure is not cached across an explicit retry")
  cleanup:complete_next(nil, "cleanup-failure")
  eq(#cleanup.starts, 2, "cleanup retry does not replay automatically")
  eq(#cleanup.notifications, 2, "each explicit cleanup failure notifies once")
  cleanup.controller:shutdown(false)
end

do
  local fixture = new_controller_fixture()
  fixture.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  local old = table.remove(fixture.pending, 1)
  fixture.controller:cancel("close")
  old.complete(nil, "cancellation")
  fixture.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  eq(#fixture.starts, 2, "new generation starts after confirmed cancellation")
  old.complete(vim.deepcopy(fixture_results().version), "")
  eq(#fixture.starts, 2, "stale callback cannot advance the new generation")
  eq(fixture.controller:snapshot().state, "checking", "stale callback cannot publish state")
  eq(fixture.controller:snapshot().queued, true, "stale callback cannot clear a new queue")
  fixture.controller:cancel("close")
  fixture:complete_next(nil, "cancellation")
  fixture.controller:shutdown(false)
end

do
  local fixture = new_controller_fixture({ queued_schedule = true })
  local live_snapshots = {}
  local removed_snapshots = {}
  local unsubscribe_live = assert(fixture.controller:subscribe(function(snapshot)
    live_snapshots[#live_snapshots + 1] = vim.deepcopy(snapshot)
    snapshot.executable = "observer-secret-canary"
  end))
  local unsubscribe_removed = assert(fixture.controller:subscribe(function(snapshot)
    removed_snapshots[#removed_snapshots + 1] = snapshot
  end))
  fixture.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  unsubscribe_removed()
  fixture:flush_scheduled()
  eq(#live_snapshots, 1, "live observer receives a scheduled snapshot")
  eq(#removed_snapshots, 0, "unsubscribed observer receives no queued snapshot")
  eq(live_snapshots[1].state, "checking", "observer sees checking")
  eq(fixture.controller:snapshot().executable, "/usr/bin/opencode", "observer receives a copy")
  unsubscribe_live()
  fixture.controller:shutdown(false)

  local stale = new_controller_fixture({ queued_schedule = true })
  local stale_calls = 0
  assert(stale.controller:subscribe(function()
    stale_calls = stale_calls + 1
  end))
  stale.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  stale.controller:shutdown(false)
  stale:flush_scheduled()
  eq(stale_calls, 0, "shutdown suppresses stale scheduled observers")

  local bounded = new_controller_fixture()
  local unsubscribe = {}
  for index = 1, 32 do
    unsubscribe[index] = assert(bounded.controller:subscribe(function() end))
  end
  eq(bounded.controller:debug_state().observer_count, 32, "observer retention is bounded at 32")
  local thirty_third, observer_error = bounded.controller:subscribe(function() end)
  assert(thirty_third == nil, "thirty-third observer was retained")
  eq(
    observer_error,
    "managed OpenCode compatibility observer is unavailable",
    "observer bound error is generic"
  )
  unsubscribe[1]()
  assert(bounded.controller:subscribe(function() end), "released observer slot was not reusable")
  bounded.controller:shutdown(false)
end

do
  local fixture = new_controller_fixture()
  fixture.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  eq(#fixture.timers, 1, "deadline fixture owns exactly one timer")
  fixture.timers[1].callback()
  eq(fixture.cancel_reasons, { "timeout" }, "total deadline cancels the active handle")
  assert(fixture.timers[1].stopped, "total timeout left the sequence timer running")
  assert(fixture.timers[1].closed, "total timeout left the sequence timer open")
  eq(fixture.controller:debug_state().has_timer, false, "total timeout releases its timer")
  eq(fixture.controller:snapshot().state, "checking", "timeout waits for callback cleanup")
  eq(fixture.controller:snapshot().category, "", "timeout is not published before cleanup")
  eq(fixture.controller:snapshot().queued, false, "timeout clears the queued opening immediately")
  eq(#fixture.notifications, 0, "timeout does not notify before cleanup")
  local retry_while_cancelling = fixture.controller:ensure({
    reason = "open",
    identity_key = OTHER_IDENTITY_KEY,
  })
  eq(retry_while_cancelling.state, "checking", "timeout cancellation cannot be replaced")
  eq(retry_while_cancelling.queued, false, "timeout cancellation keeps the queue clear")
  eq(#fixture.starts, 1, "timeout does not start a replacement probe")
  local results = fixture_results()
  fixture:complete_next(vim.deepcopy(results.version), "")
  eq(fixture.controller:snapshot().state, "failed", "timeout publishes only after cleanup")
  eq(fixture.controller:snapshot().category, "timeout", "total timeout category")
  eq(#fixture.notifications, 1, "total timeout notifies once")
  eq(#fixture.starts, 1, "total timeout never retries")
  fixture.controller:shutdown(false)
end

do
  local ordinary = new_controller_fixture()
  ordinary.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  eq(ordinary.controller:shutdown(false), true, "ordinary shutdown succeeds without waiting")
  eq(ordinary.cancel_reasons, { "shutdown" }, "ordinary shutdown cancels")
  assert(ordinary.timers[1].stopped, "ordinary shutdown left the sequence timer running")
  assert(ordinary.timers[1].closed, "ordinary shutdown left the sequence timer open")
  eq(#ordinary.drain_calls, 0, "ordinary shutdown never drains")

  local exiting = new_controller_fixture()
  exiting.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  eq(exiting.controller:shutdown(true), true, "exit-only shutdown returns successful drain")
  eq(exiting.cancel_reasons, { "shutdown" }, "exit-only shutdown cancels first")
  eq(exiting.drain_calls, { 2000 }, "exit-only shutdown uses one bounded drain")
  eq(exiting.controller:shutdown(true), true, "repeated shutdown is idempotent")
  eq(exiting.drain_calls, { 2000 }, "repeated shutdown does not drain twice")

  local undrained = new_controller_fixture({ drain_result = false })
  undrained.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  eq(undrained.controller:shutdown(true), false, "failed exit-only drain is reported")
  eq(undrained.drain_calls, { 2000 }, "failed drain remains bounded")
  eq(undrained.controller:shutdown(true), false, "failed exit-only drain result is replayed")
  eq(undrained.drain_calls, { 2000 }, "failed drain is not attempted twice")

  local cancellation = new_controller_fixture()
  cancellation.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  cancellation.controller:cancel("shutdown")
  eq(cancellation.cancel_reasons, { "shutdown" }, "shutdown cancellation cancels the handle")
  assert(cancellation.timers[1].stopped, "shutdown cancellation left the timer running")
  assert(cancellation.timers[1].closed, "shutdown cancellation left the timer open")
  eq(#cancellation.drain_calls, 0, "shutdown cancellation uses the ordinary no-wait path")
  eq(
    cancellation.controller:snapshot(),
    validation._test.new_idle_snapshot(),
    "shutdown stops state"
  )
end

do
  local fixture = new_controller_fixture()
  fixture.controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  run_to_ready(fixture)
  assert(fixture.controller:report(), "ready drift fixture has no report")
  fixture.controller:cancel("executable-drift")
  eq(fixture.controller:snapshot().state, "not_checked", "explicit ready drift invalidates state")
  assert(fixture.controller:report() == nil, "explicit ready drift retained a report")
  eq(fixture.controller:snapshot().queued, false, "explicit ready drift clears the queue")
  fixture.controller:shutdown(false)
end

do
  local bounded_system_async = registry._test.bounded_system_async
  assert(
    type(bounded_system_async) == "function",
    "Task 4 asynchronous process boundary export is missing"
  )

  local function new_async_fixture(options)
    options = options or {}
    local fixture = {
      callbacks = {},
      completions = {},
      kills = {},
      scheduled = {},
      wait_calls = 0,
    }
    local process = {}

    function process:kill(signal)
      fixture.kills[#fixture.kills + 1] = signal
      if options.kill_error then
        error({ private = "kill-secret-canary" })
      end
      return true
    end

    function process:wait()
      fixture.wait_calls = fixture.wait_calls + 1
      error("wait-secret-canary")
    end

    local system = function(_, system_options, callback)
      fixture.stdout = system_options.stdout
      fixture.stderr = system_options.stderr
      fixture.exit = callback
      if options.before_return then
        options.before_return(fixture)
      end
      if options.spawn_error then
        error({ private = "spawn-secret-canary" })
      end
      if options.invalid_process then
        return {}
      end
      return process
    end

    fixture.handle = bounded_system_async(
      { "/usr/bin/fake" },
      { text = true, timeout = 5000 },
      options.limits or { stdout = 4, stderr = 4 },
      options.on_complete
        or function(result)
          fixture.completions[#fixture.completions + 1] = result
        end,
      {
        system = system,
        schedule = options.schedule or function(callback)
          fixture.scheduled[#fixture.scheduled + 1] = callback
        end,
      }
    )

    function fixture:flush()
      while #self.scheduled > 0 do
        local callback = table.remove(self.scheduled, 1)
        callback()
      end
    end

    return fixture
  end

  local delayed = new_async_fixture()
  eq(#delayed.completions, 0, "async starter returns before completion")
  eq(#delayed.scheduled, 0, "async starter does not invent completion")
  eq(delayed.wait_calls, 0, "ordinary async start never waits")
  local progressed = false
  vim.defer_fn(function()
    progressed = true
  end, 10)
  assert(
    vim.wait(250, function()
      return progressed
    end, 5),
    "event loop did not progress while the fake process was pending"
  )
  eq(delayed.wait_calls, 0, "event-loop progress never enters process wait")
  delayed.stdout(nil, "ab")
  delayed.stderr(nil, "cd")
  delayed.exit({ code = 0, signal = 0 })
  eq(#delayed.scheduled, 1, "process exit schedules exactly one completion")
  eq(#delayed.completions, 0, "completion is not delivered inline")
  delayed:flush()
  eq(#delayed.completions, 1, "scheduled process completion is delivered once")
  eq(delayed.completions[1], {
    code = 0,
    signal = 0,
    stdout = "ab",
    stderr = "cd",
    stdout_overflow = false,
    stderr_overflow = false,
    system_error = false,
    process_started = true,
    process_exited = true,
  }, "successful async result is bounded")

  local early = new_async_fixture({
    before_return = function(fixture)
      fixture.stdout(nil, "abcde")
    end,
  })
  eq(early.kills, { "sigkill" }, "early overflow kills after handle assignment exactly once")
  early.stderr(nil, "ignored-secret-canary")
  early.exit({ code = 137, signal = 9 })
  early.exit({ code = 0, signal = 0 })
  eq(#early.scheduled, 1, "duplicate exit cannot duplicate an early-overflow completion")
  early:flush()
  eq(#early.completions, 1, "early overflow completes once")
  eq(early.completions[1].stdout, "", "early overflow returns no retained stdout")
  eq(early.completions[1].stderr, "", "early overflow returns no retained stderr")
  eq(early.completions[1].stdout_overflow, true, "early stdout overflow is bounded")
  assert(
    not vim.inspect(early.completions[1]):find("secret-canary", 1, true),
    "early overflow leaked ignored stream bytes"
  )

  local late = new_async_fixture()
  late.stdout(nil, "abcde")
  late.stdout(nil, "late-secret-canary")
  eq(late.kills, { "sigkill" }, "late stdout overflow kills exactly once")
  late.exit({ code = 137, signal = 9 })
  late:flush()
  eq(late.completions[1].stdout, "", "late overflow returns empty stdout")
  eq(late.completions[1].stderr, "", "late overflow returns empty stderr")
  eq(late.completions[1].stdout_overflow, true, "late stdout overflow is reported")

  local stderr_overflow = new_async_fixture()
  stderr_overflow.stderr(nil, "abcde")
  eq(stderr_overflow.kills, { "sigkill" }, "stderr overflow kills exactly once")
  stderr_overflow.exit({ code = 137, signal = 9 })
  stderr_overflow:flush()
  eq(stderr_overflow.completions[1].stdout, "", "stderr overflow returns empty stdout")
  eq(stderr_overflow.completions[1].stderr, "", "stderr overflow returns empty stderr")
  eq(stderr_overflow.completions[1].stderr_overflow, true, "stderr overflow is reported")

  for _, case in ipairs({
    {
      label = "stream callback error",
      invoke = function(fixture)
        fixture.stdout({ private = "stream-error-secret-canary" }, nil)
      end,
    },
    {
      label = "invalid stream callback data",
      invoke = function(fixture)
        fixture.stdout(nil, { private = "stream-data-secret-canary" })
      end,
    },
  }) do
    local fixture = new_async_fixture()
    case.invoke(fixture)
    eq(fixture.kills, { "sigkill" }, case.label .. " kills exactly once")
    fixture.exit({ code = 137, signal = 9 })
    fixture:flush()
    eq(#fixture.completions, 1, case.label .. " completes once")
    eq(fixture.completions[1].stdout, "", case.label .. " returns empty stdout")
    eq(fixture.completions[1].stderr, "", case.label .. " returns empty stderr")
    eq(fixture.completions[1].system_error, true, case.label .. " is a system failure")
    assert(
      not vim.inspect(fixture.completions[1]):find("secret-canary", 1, true),
      case.label .. " retained raw callback data"
    )
  end

  local throwing_limits = setmetatable({ stdout = 4, stderr = 4 }, {
    __index = function()
      error({ private = "stream-exception-secret-canary" })
    end,
  })
  local stream_exception = new_async_fixture({ limits = throwing_limits })
  throwing_limits.stdout = nil
  stream_exception.stdout(nil, "a")
  eq(stream_exception.kills, { "sigkill" }, "stream callback exception kills exactly once")
  stream_exception.exit({ code = 137, signal = 9 })
  stream_exception:flush()
  eq(stream_exception.completions[1].stdout, "", "stream exception returns empty stdout")
  eq(stream_exception.completions[1].stderr, "", "stream exception returns empty stderr")
  eq(stream_exception.completions[1].system_error, true, "stream exception is contained")
  assert(
    not vim.inspect(stream_exception.completions[1]):find("secret-canary", 1, true),
    "stream callback exception was retained"
  )

  for _, case in ipairs({
    { label = "spawn exception", options = { spawn_error = true } },
    { label = "invalid spawned handle", options = { invalid_process = true } },
  }) do
    local fixture = new_async_fixture(case.options)
    eq(#fixture.scheduled, 1, case.label .. " schedules one completion")
    fixture:flush()
    eq(#fixture.completions, 1, case.label .. " completes once")
    eq(fixture.completions[1].stdout, "", case.label .. " returns empty stdout")
    eq(fixture.completions[1].stderr, "", case.label .. " returns empty stderr")
    eq(fixture.completions[1].system_error, true, case.label .. " is bounded")
    assert(
      not vim.inspect(fixture.completions[1]):find("secret-canary", 1, true),
      case.label .. " leaked raw failure data"
    )
  end

  local timeout = new_async_fixture()
  timeout.exit({ code = 124, signal = 15 })
  timeout:flush()
  eq(timeout.completions[1].code, 124, "timeout exit code is preserved")
  eq(timeout.completions[1].signal, 15, "timeout signal is preserved")
  eq(timeout.kills, {}, "completed timeout result is not killed again")

  local signaled = new_async_fixture()
  signaled.stdout(nil, "ok")
  signaled.exit({ code = 0, signal = 9 })
  signaled:flush()
  eq(signaled.completions[1].code, 0, "signaled exit code is preserved")
  eq(signaled.completions[1].signal, 9, "signaled exit signal is preserved")
  eq(signaled.completions[1].stdout, "ok", "signaled exit keeps bounded stdout")

  local cancelled = new_async_fixture()
  cancelled.handle:cancel("close")
  cancelled.handle:cancel("backend-switch")
  eq(cancelled.kills, { "sigkill" }, "repeated cancellation makes one hard-kill request")
  eq(#cancelled.scheduled, 0, "cancellation waits for proven process exit")
  cancelled.exit({ code = 137, signal = 9 })
  cancelled:flush()
  eq(cancelled.completions[1].cancellation, "backend-switch", "latest bounded reason is retained")
  eq(cancelled.wait_calls, 0, "ordinary cancellation never waits")

  local callback_fixture
  callback_fixture = new_async_fixture({
    on_complete = function()
      callback_fixture.callbacks[#callback_fixture.callbacks + 1] = true
      error({ private = "completion-secret-canary" })
    end,
  })
  callback_fixture.exit({ code = 0, signal = 0 })
  local callback_ok, callback_error = pcall(callback_fixture.flush, callback_fixture)
  assert(callback_ok, "completion callback exception escaped: " .. vim.inspect(callback_error))
  eq(#callback_fixture.callbacks, 1, "throwing completion callback runs once")
  eq(#callback_fixture.scheduled, 0, "throwing completion callback is not rescheduled")

  local delayed_scheduler = new_async_fixture({
    schedule = function()
      error({ private = "delayed-scheduler-secret-canary" })
    end,
  })
  local delayed_schedule_ok, delayed_schedule_error = pcall(function()
    delayed_scheduler.exit({ code = 0, signal = 0 })
  end)
  assert(
    delayed_schedule_ok,
    "delayed scheduler exception escaped: " .. vim.inspect(delayed_schedule_error)
  )
  eq(#delayed_scheduler.completions, 1, "delayed scheduler failure completes once")
  eq(delayed_scheduler.completions[1].system_error, true, "delayed scheduler failure is bounded")
  assert(
    not vim.inspect(delayed_scheduler.completions):find("secret-canary", 1, true),
    "delayed scheduler failure retained its arbitrary error"
  )

  local queued_scheduler
  queued_scheduler = new_async_fixture({
    schedule = function(callback)
      queued_scheduler.scheduled[#queued_scheduler.scheduled + 1] = callback
      error({ private = "queued-scheduler-secret-canary" })
    end,
  })
  local queued_schedule_ok, queued_schedule_error = pcall(function()
    queued_scheduler.exit({ code = 0, signal = 0 })
  end)
  assert(
    queued_schedule_ok,
    "queue-then-throw scheduler exception escaped: " .. vim.inspect(queued_schedule_error)
  )
  eq(#queued_scheduler.completions, 1, "queue-then-throw fallback completes once")
  queued_scheduler:flush()
  eq(#queued_scheduler.completions, 1, "late queued callback cannot complete twice")

  local reentrant_scheduler = new_async_fixture({
    schedule = function(callback)
      callback()
      error({ private = "reentrant-scheduler-secret-canary" })
    end,
  })
  local reentrant_ok, reentrant_error = pcall(function()
    reentrant_scheduler.exit({ code = 0, signal = 0 })
  end)
  assert(reentrant_ok, "reentrant scheduler exception escaped: " .. vim.inspect(reentrant_error))
  eq(#reentrant_scheduler.completions, 1, "reentrant scheduler completes once")

  local immediate_completions = {}
  local immediate_ok, immediate_handle = pcall(
    bounded_system_async,
    { "/usr/bin/fake" },
    {},
    { stdout = -1, stderr = 1 },
    function(result)
      immediate_completions[#immediate_completions + 1] = result
    end,
    {
      system = function()
        error("invalid limits started a process")
      end,
      schedule = function()
        error({ private = "immediate-scheduler-secret-canary" })
      end,
    }
  )
  assert(immediate_ok, "immediate validation scheduler exception escaped")
  assert(type(immediate_handle) == "table", "immediate scheduler failure returned no handle")
  eq(#immediate_completions, 1, "immediate scheduler failure completes once")
  eq(immediate_completions[1].system_error, true, "immediate scheduler failure is bounded")

  for _, limits in ipairs({
    { stdout = -1, stderr = 1 },
    { stdout = 1, stderr = -1 },
    { stdout = 1.5, stderr = 1 },
    { stdout = 1, stderr = 1.5 },
  }) do
    local completions = {}
    local scheduled = {}
    local handle = bounded_system_async({ "/usr/bin/fake" }, {}, limits, function(result)
      completions[#completions + 1] = result
    end, {
      system = function()
        error("invalid limits started a process")
      end,
      schedule = function(callback)
        scheduled[#scheduled + 1] = callback
      end,
    })
    assert(type(handle) == "table", "invalid integer limit returned no cancellation handle")
    eq(#scheduled, 1, "invalid integer limit schedules one bounded failure")
    scheduled[1]()
    eq(#completions, 1, "invalid integer limit completes once")
    eq(completions[1].stdout, "", "invalid integer limit returns empty stdout")
    eq(completions[1].stderr, "", "invalid integer limit returns empty stderr")
    eq(completions[1].system_error, true, "invalid integer limit is a system failure")
  end
end

do
  local start_opencode_probe = registry._test.start_opencode_probe
  local new_opencode_validation = registry._test.new_opencode_validation
  assert(type(start_opencode_probe) == "function", "Task 4 owned probe starter export is missing")
  assert(
    type(new_opencode_validation) == "function",
    "Task 4 production controller factory export is missing"
  )

  local cleanup_owned_probe_tree = registry._test.cleanup_owned_probe_tree
  assert(type(cleanup_owned_probe_tree) == "function", "owned-tree cleanup export is missing")

  local owned_root = "/tmp/task4-owned-probe"
  local directory_stat = { type = "directory", uid = 1000, mode = 448 }
  local cleanup_lstat_calls = 0
  local cleanup_remove_calls = 0
  assert(
    cleanup_owned_probe_tree(owned_root, function(path, mode)
      cleanup_remove_calls = cleanup_remove_calls + 1
      eq(path, owned_root, "cleanup deletes only the owned root")
      eq(mode, "rf", "cleanup uses the guarded recursive mode")
      return 0
    end, function(path)
      eq(path, owned_root, "cleanup revalidates only the owned root")
      cleanup_lstat_calls = cleanup_lstat_calls + 1
      if cleanup_lstat_calls == 1 then
        return vim.deepcopy(directory_stat)
      end
      return nil, "missing", "ENOENT"
    end, function()
      return 1000
    end),
    "exact private root was not cleaned"
  )
  eq(cleanup_remove_calls, 1, "exact private root is deleted once")
  eq(cleanup_lstat_calls, 2, "cleanup checks before and after deletion")

  local unsafe_cleanup_cases = {
    {
      label = "relative root",
      root = "tmp/task4-owned-probe",
    },
    {
      label = "filesystem root",
      root = "/",
    },
    {
      label = "normalization escape",
      root = "/tmp/task4-owned-probe/../escape",
    },
    {
      label = "control-bearing root",
      root = "/tmp/task4-owned-probe\nsecret-canary",
    },
    {
      label = "symlink root",
      stat = { type = "link", uid = 1000, mode = 448 },
    },
    {
      label = "regular-file root",
      stat = { type = "file", uid = 1000, mode = 448 },
    },
    {
      label = "wrong-owner root",
      stat = { type = "directory", uid = 1001, mode = 448 },
    },
    {
      label = "wrong-mode root",
      stat = { type = "directory", uid = 1000, mode = 493 },
    },
    {
      label = "current uid drift",
      getuid = function()
        return 1001
      end,
    },
    {
      label = "invalid current uid",
      getuid = function()
        return "1000"
      end,
    },
    {
      label = "pre-delete lstat exception",
      lstat = function()
        error({ private = "lstat-secret-canary" })
      end,
    },
  }
  for _, case in ipairs(unsafe_cleanup_cases) do
    local delete_calls = 0
    local accepted = cleanup_owned_probe_tree(case.root or owned_root, function()
      delete_calls = delete_calls + 1
      return 0
    end, case.lstat or function()
      return vim.deepcopy(case.stat or directory_stat)
    end, case.getuid or function()
      return 1000
    end)
    eq(accepted, false, case.label .. " is refused")
    eq(delete_calls, 0, case.label .. " reaches no recursive deletion")
  end

  for _, case in ipairs({
    {
      label = "delete exception",
      remove = function()
        error({ private = "delete-secret-canary" })
      end,
    },
    {
      label = "delete failure status",
      remove = function()
        return 1
      end,
    },
  }) do
    local delete_calls = 0
    local accepted = cleanup_owned_probe_tree(owned_root, function(...)
      delete_calls = delete_calls + 1
      return case.remove(...)
    end, function()
      return vim.deepcopy(directory_stat)
    end, function()
      return 1000
    end)
    eq(accepted, false, case.label .. " is a hard cleanup failure")
    eq(delete_calls, 1, case.label .. " invokes deletion once")
  end

  local post_delete_cases = {
    {
      label = "post-delete root remains",
      after = function()
        return vim.deepcopy(directory_stat)
      end,
    },
    {
      label = "post-delete wrong error",
      after = function()
        return nil, "permission denied", "EACCES"
      end,
    },
    {
      label = "post-delete lstat exception",
      after = function()
        error({ private = "post-delete-secret-canary" })
      end,
    },
  }
  for _, case in ipairs(post_delete_cases) do
    local lstat_calls = 0
    local delete_calls = 0
    local accepted = cleanup_owned_probe_tree(owned_root, function()
      delete_calls = delete_calls + 1
      return 0
    end, function()
      lstat_calls = lstat_calls + 1
      if lstat_calls == 1 then
        return vim.deepcopy(directory_stat)
      end
      return case.after()
    end, function()
      return 1000
    end)
    eq(accepted, false, case.label .. " is a hard cleanup failure")
    eq(delete_calls, 1, case.label .. " follows one guarded deletion")
  end

  local executable_stat = {
    type = "file",
    dev = 1,
    ino = 2,
    mode = 493,
    uid = 1000,
    size = 123,
    mtime = { sec = 3, nsec = 4 },
    ctime = { sec = 5, nsec = 6 },
  }
  local executable_metadata = "1:2:493:1000:123:3:4:5:6"
  local identity = {
    installed = true,
    executable = "/usr/bin/opencode",
    metadata = executable_metadata,
  }
  local exact_tree = {
    root = owned_root,
    home = owned_root .. "/home",
    config = owned_root .. "/xdg-config",
    config_opencode = owned_root .. "/xdg-config/opencode",
    bootstrap = owned_root .. "/xdg-config/opencode/.gitignore",
    data = owned_root .. "/xdg-data",
    cache = owned_root .. "/xdg-cache",
    state = owned_root .. "/xdg-state",
  }

  local function new_owned_probe(options)
    options = options or {}
    local fixture = {
      cleanups = {},
      completions = {},
      kills = {},
      observations = {},
      revalidations = {},
      scheduled = {},
      trace = {},
      waits = {},
      tree = vim.deepcopy(options.tree or exact_tree),
    }
    local now_index = 0
    local process = {}

    function process:kill(signal)
      fixture.trace[#fixture.trace + 1] = "kill"
      fixture.kills[#fixture.kills + 1] = signal
      if options.kill_error then
        error({ private = "kill-secret-canary" })
      end
      return true
    end

    function process:wait(timeout_ms)
      fixture.trace[#fixture.trace + 1] = "wait"
      fixture.waits[#fixture.waits + 1] = timeout_ms
      if options.wait_error then
        error({ private = "wait-secret-canary" })
      end
      return options.wait_result or { code = 137, signal = 9 }
    end

    local command = vim.deepcopy(options.command or expected_commands[1])
    local handle, category = start_opencode_probe(
      vim.deepcopy(options.identity or identity),
      command,
      options.on_complete
        or function(result, result_category)
          fixture.trace[#fixture.trace + 1] = "complete"
          fixture.completions[#fixture.completions + 1] = {
            result = result,
            category = result_category,
          }
        end,
      {
        revalidate = function(path)
          fixture.revalidations[#fixture.revalidations + 1] = path
          if options.revalidate_error then
            error({ private = "revalidate-secret-canary" })
          end
          if path == "/usr/bin/python3" and options.unsafe_python then
            return false, "unsafe helper"
          end
          return options.revalidate_result ~= false
        end,
        stat = function(path)
          eq(path, identity.executable, "owned probe stats only the executable")
          return vim.deepcopy(options.executable_stat or executable_stat)
        end,
        create_tree = function()
          fixture.trace[#fixture.trace + 1] = "create"
          if options.create_error then
            error({ private = "create-secret-canary" })
          end
          if options.create_result ~= nil or options.create_category ~= nil then
            return options.create_result, options.create_category
          end
          return fixture.tree
        end,
        cleanup_tree = function(root, delete, lstat, getuid)
          fixture.trace[#fixture.trace + 1] = "cleanup"
          fixture.cleanups[#fixture.cleanups + 1] = root
          eq(type(delete), "function", "owned cleanup receives the delete dependency")
          eq(type(lstat), "function", "owned cleanup receives the lstat dependency")
          eq(type(getuid), "function", "owned cleanup receives the uid dependency")
          if options.cleanup_error then
            error({ private = "cleanup-secret-canary" })
          end
          return options.cleanup_result ~= false
        end,
        inspect_artifacts = function(tree, semantic)
          fixture.trace[#fixture.trace + 1] = "inspect"
          eq(semantic, command.semantic, "artifact inspection uses command semantics")
          if options.mutate_root_during_inspection then
            tree.root = "/tmp/changed-owned-probe"
          end
          if options.inspect_error then
            error({ private = "inspect-secret-canary" })
          end
          if options.inspect_result == false then
            return nil, options.inspect_category or "probe-artifact-tree"
          end
          return vim.deepcopy(
            options.snapshot or { disposition = "quiescent", fingerprint = "absent" }
          )
        end,
        settle_lock = function(tree, initial, _, callback)
          fixture.trace[#fixture.trace + 1] = "settle"
          fixture.settle_tree = tree
          fixture.settle_initial = initial
          if options.settle_error then
            error({ private = "settle-secret-canary" })
          end
          if options.settle_pending then
            fixture.settle_callback = callback
            return function()
              fixture.trace[#fixture.trace + 1] = "settle-cancel"
              callback(nil, "cancellation")
            end
          end
          callback(options.settle_result ~= false, options.settle_category)
          return function() end
        end,
        schedule = options.schedule or function(callback)
          fixture.scheduled[#fixture.scheduled + 1] = callback
        end,
        observe_probe = options.observe and function(name, tree, observation)
          fixture.trace[#fixture.trace + 1] = "observe"
          fixture.observations[#fixture.observations + 1] = {
            name = name,
            tree = tree,
            observation = observation,
          }
        end or nil,
        delete = function()
          error("injected cleanup_tree must own deletion")
        end,
        lstat = function()
          return vim.deepcopy(options.root_stat or directory_stat)
        end,
        getuid = function()
          return options.current_uid or 1000
        end,
        now = function()
          now_index = now_index + 1
          return options.now_values and options.now_values[now_index] or 100
        end,
        defer = function()
          error("injected settler must own deferral")
        end,
        resolve = function(name)
          assert(name == "bwrap" or name == "python3", "unexpected owned probe tool")
          if name == "python3" and options.missing_python then
            return nil, "helper unavailable"
          end
          return "/usr/bin/" .. name
        end,
        system = function(argv, system_options, exit_callback)
          fixture.trace[#fixture.trace + 1] = "spawn"
          fixture.argv = vim.deepcopy(argv)
          fixture.system_options = system_options
          fixture.stdout = system_options.stdout
          fixture.stderr = system_options.stderr
          fixture.exit_callback = exit_callback
          if options.spawn_error then
            error({ private = "spawn-secret-canary" })
          end
          return process
        end,
      }
    )
    fixture.handle = handle
    fixture.start_category = category

    function fixture:exit(result)
      self.trace[#self.trace + 1] = "exit"
      self.exit_callback(result or { code = 0, signal = 0 })
    end

    function fixture:flush()
      while #self.scheduled > 0 do
        local callback = table.remove(self.scheduled, 1)
        callback()
      end
    end

    return fixture
  end

  for _, case in ipairs({
    {
      label = "unknown command",
      command = { name = "unknown", arguments = {}, semantic = false },
      category = "probe-failure",
    },
    {
      label = "changed command arguments",
      command = { name = "version", arguments = { "secret-canary" }, semantic = false },
      category = "probe-failure",
    },
    {
      label = "changed command semantics",
      command = { name = "version", arguments = { "--version" }, semantic = true },
      category = "probe-failure",
    },
    {
      label = "changed executable metadata",
      identity = {
        installed = true,
        executable = identity.executable,
        metadata = executable_metadata .. ":changed",
      },
      category = "executable-drift",
    },
  }) do
    local fixture = new_owned_probe({ command = case.command, identity = case.identity })
    assert(fixture.handle == nil, case.label .. " returned a probe handle")
    eq(fixture.start_category, case.category, case.label .. " category")
    eq(fixture.trace, {}, case.label .. " created no private tree or process")
  end

  for _, case in ipairs({
    { label = "tree creation exception", create_error = true, category = "probe-failure" },
    {
      label = "tree creation failure",
      create_result = false,
      create_category = "probe-failure",
      category = "probe-failure",
    },
    {
      label = "partial-tree cleanup failure",
      create_result = false,
      create_category = "cleanup-failure",
      category = "cleanup-failure",
    },
  }) do
    local fixture = new_owned_probe(case)
    assert(fixture.handle == nil, case.label .. " returned a probe handle")
    eq(fixture.start_category, case.category, case.label .. " category")
    eq(fixture.trace, { "create" }, case.label .. " starts no process")
    assert(
      not vim.inspect(fixture.start_category):find("secret-canary", 1, true),
      case.label .. " leaked a raw error"
    )
  end

  for _, case in ipairs({
    {
      label = "wrong tree child",
      tree = vim.tbl_extend("force", vim.deepcopy(exact_tree), { data = owned_root .. "/changed" }),
    },
    {
      label = "nonnormalized tree root",
      tree = vim.tbl_extend("force", vim.deepcopy(exact_tree), {
        root = owned_root .. "/../escape",
      }),
    },
    {
      label = "symlink tree root",
      root_stat = { type = "link", uid = 1000, mode = 448 },
    },
    {
      label = "regular-file tree root",
      root_stat = { type = "file", uid = 1000, mode = 448 },
    },
    {
      label = "wrong-owner tree root",
      root_stat = { type = "directory", uid = 1001, mode = 448 },
    },
    {
      label = "wrong-mode tree root",
      root_stat = { type = "directory", uid = 1000, mode = 493 },
    },
  }) do
    local fixture = new_owned_probe(case)
    assert(fixture.handle == nil, case.label .. " returned a probe handle")
    eq(fixture.start_category, "cleanup-failure", case.label .. " category")
    eq(fixture.trace, { "create" }, case.label .. " starts no process or unsafe cleanup")
  end

  for _, case in ipairs({ { missing_python = true }, { unsafe_python = true } }) do
    local fixture = new_owned_probe(case)
    eq(fixture.handle, nil, "unavailable private-mask helper refuses the probe")
    eq(fixture.start_category, "probe-failure", "private-mask helper failure category")
    eq(fixture.trace, { "create", "cleanup" }, "helper failure cleans without spawning")
  end

  local invocation = new_owned_probe()
  assert(type(invocation.handle) == "table", invocation.start_category)
  eq(invocation.trace, { "create", "spawn" }, "owned probe returns before process completion")
  eq(invocation.system_options.timeout, 5000, "OpenCode uses the five-second command timeout")
  eq(invocation.system_options.text, true, "OpenCode requests text streaming")
  eq(invocation.system_options.clear_env, true, "OpenCode clears the inherited environment")
  eq(invocation.system_options.env, {
    HOME = "/tmp/nvim-ai-probe/home",
    OPENCODE_CONFIG_CONTENT = managed.config_json(),
    OPENCODE_DISABLE_AUTOUPDATE = "true",
    OPENCODE_DISABLE_CLAUDE_CODE = "true",
    OPENCODE_DISABLE_EXTERNAL_SKILLS = "true",
    OPENCODE_DISABLE_LSP_DOWNLOAD = "true",
    OPENCODE_DISABLE_PROJECT_CONFIG = "true",
    OPENCODE_PERMISSION = managed.policy_json(),
    OPENCODE_PURE = "true",
    XDG_CACHE_HOME = "/tmp/nvim-ai-probe/xdg-cache",
    XDG_CONFIG_HOME = "/tmp/nvim-ai-probe/xdg-config",
    XDG_DATA_HOME = "/tmp/nvim-ai-probe/xdg-data",
    XDG_STATE_HOME = "/tmp/nvim-ai-probe/xdg-state",
  }, "OpenCode uses the exact cleared probe environment")
  eq(invocation.argv, {
    "/usr/bin/bwrap",
    "--new-session",
    "--unshare-pid",
    "--unshare-ipc",
    "--unshare-uts",
    "--unshare-net",
    "--die-with-parent",
    "--ro-bind",
    "/",
    "/",
    "--dev",
    "/dev",
    "--proc",
    "/proc",
    "--tmpfs",
    "/tmp",
    "--dir",
    "/tmp/nvim-ai-probe",
    "--dir",
    "/tmp/nvim-ai-probe/home",
    "--dir",
    "/tmp/nvim-ai-probe/xdg-config",
    "--dir",
    "/tmp/nvim-ai-probe/xdg-data",
    "--dir",
    "/tmp/nvim-ai-probe/xdg-cache",
    "--dir",
    "/tmp/nvim-ai-probe/xdg-state",
    "--ro-bind",
    owned_root .. "/home",
    "/tmp/nvim-ai-probe/home",
    "--ro-bind",
    owned_root .. "/xdg-config",
    "/tmp/nvim-ai-probe/xdg-config",
    "--bind",
    owned_root .. "/xdg-data",
    "/tmp/nvim-ai-probe/xdg-data",
    "--bind",
    owned_root .. "/xdg-cache",
    "/tmp/nvim-ai-probe/xdg-cache",
    "--bind",
    owned_root .. "/xdg-state",
    "/tmp/nvim-ai-probe/xdg-state",
    "--chdir",
    "/tmp/nvim-ai-probe",
    "--",
    "/usr/bin/python3",
    "-I",
    "-S",
    "-B",
    "-c",
    "import os,sys; os.umask(0o077); os.execv(sys.argv[1], sys.argv[1:])",
    "/usr/bin/opencode",
    "--version",
  }, "OpenCode owns the exact Bubblewrap command")
  eq(invocation.revalidations, {
    "/usr/bin/opencode",
    "/usr/bin/opencode",
    "/usr/bin/bwrap",
    "/usr/bin/python3",
  }, "OpenCode revalidates the executable, Bubblewrap, and private-mask helper")

  invocation.stdout(nil, "ok")
  invocation:exit({ code = 0, signal = 0 })
  eq(#invocation.cleanups, 0, "private root is not deleted before scheduled exit handling")
  invocation:flush()
  eq(invocation.trace, {
    "create",
    "spawn",
    "exit",
    "inspect",
    "cleanup",
    "complete",
  }, "nonsemantic success lifecycle")
  eq(#invocation.cleanups, 1, "nonsemantic success cleans once")
  eq(#invocation.completions, 1, "nonsemantic success completes once")
  eq(invocation.completions[1].category, "", "nonsemantic success category")
  eq(invocation.completions[1].result.stdout, "ok", "nonsemantic success keeps bounded output")

  local semantic_snapshot = { disposition = "quiescent", fingerprint = "full:fixture" }
  local semantic = new_owned_probe({
    command = expected_commands[5],
    snapshot = semantic_snapshot,
  })
  semantic:exit({ code = 0, signal = 0 })
  semantic:flush()
  eq(semantic.trace, {
    "create",
    "spawn",
    "exit",
    "inspect",
    "settle",
    "cleanup",
    "complete",
  }, "semantic success settles before cleanup")
  eq(semantic.settle_initial, semantic_snapshot, "Task 3 snapshot seam reaches the settler")
  eq(#semantic.cleanups, 1, "semantic success cleans once")

  local spawn_failure = new_owned_probe({ spawn_error = true })
  eq(spawn_failure.trace, { "create", "spawn" }, "spawn failure returns without inline cleanup")
  spawn_failure:flush()
  eq(spawn_failure.trace, {
    "create",
    "spawn",
    "inspect",
    "cleanup",
    "complete",
  }, "spawn failure inspects and cleans a safe unstarted tree")
  eq(spawn_failure.completions[1].category, "probe-failure", "spawn failure category")
  assert(spawn_failure.completions[1].result == nil, "spawn failure exposed a result")
  assert(
    not vim.inspect(spawn_failure.completions):find("secret-canary", 1, true),
    "spawn failure retained a raw exception"
  )

  local overflow = new_owned_probe()
  overflow.stdout(nil, string.rep("x", 1024 * 1024 + 1))
  eq(overflow.kills, { "sigkill" }, "overflow requests one hard kill")
  eq(#overflow.cleanups, 0, "overflow never cleans before exit")
  overflow.handle:cancel("close")
  eq(overflow.kills, { "sigkill" }, "overflow plus cancellation still kills once")
  overflow:exit({ code = 137, signal = 9 })
  overflow.exit_callback({ code = 0, signal = 0 })
  overflow.stderr(nil, "late-secret-canary")
  overflow:flush()
  eq(#overflow.cleanups, 1, "overflow and duplicate exit clean once")
  eq(#overflow.completions, 1, "overflow and duplicate exit complete once")
  eq(overflow.completions[1].category, "output-overflow", "overflow category")
  assert(overflow.completions[1].result == nil, "overflow exposed bounded stream data")

  local timeout = new_owned_probe()
  timeout:exit({ code = 124, signal = 15 })
  timeout:flush()
  eq(timeout.trace, {
    "create",
    "spawn",
    "exit",
    "inspect",
    "cleanup",
    "complete",
  }, "command timeout lifecycle")
  eq(timeout.completions[1].category, "timeout", "command timeout category")

  local cancelled = new_owned_probe()
  cancelled.handle:cancel("backend-switch")
  eq(cancelled.trace, { "create", "spawn", "kill" }, "cancellation kills before exit")
  eq(#cancelled.cleanups, 0, "cancellation never deletes a live tree")
  cancelled:exit({ code = 137, signal = 9 })
  cancelled:flush()
  eq(cancelled.trace, {
    "create",
    "spawn",
    "kill",
    "exit",
    "inspect",
    "cleanup",
    "complete",
  }, "active cancellation lifecycle")
  eq(cancelled.completions[1].category, "cancellation", "active cancellation category")
  eq(cancelled.kills, { "sigkill" }, "active cancellation kills once")

  local artifact_rejection = new_owned_probe({
    inspect_result = false,
    inspect_category = "probe-artifact-tree",
  })
  artifact_rejection:exit({ code = 0, signal = 0 })
  artifact_rejection:flush()
  eq(artifact_rejection.trace, {
    "create",
    "spawn",
    "exit",
    "inspect",
    "cleanup",
    "complete",
  }, "artifact rejection lifecycle")
  eq(
    artifact_rejection.completions[1].category,
    "artifact-rejection",
    "artifact rejection category"
  )

  local cleanup_failure = new_owned_probe({ cleanup_result = false })
  cleanup_failure:exit({ code = 0, signal = 0 })
  cleanup_failure:flush()
  eq(cleanup_failure.completions[1].category, "cleanup-failure", "cleanup failure category")
  eq(#cleanup_failure.cleanups, 1, "cleanup failure is not retried")

  local rejected_cleanup_failure = new_owned_probe({
    inspect_result = false,
    cleanup_result = false,
  })
  rejected_cleanup_failure:exit({ code = 0, signal = 0 })
  rejected_cleanup_failure:flush()
  eq(
    rejected_cleanup_failure.completions[1].category,
    "cleanup-failure",
    "guarded cleanup failure dominates artifact rejection"
  )

  local function rejected_boundary(options, activate, expected, label)
    options.inspect_result = false
    local fixture = new_owned_probe(options)
    activate(fixture)
    fixture:flush()
    eq(fixture.completions[1].category, expected, label .. " survives artifact rejection")
    eq(#fixture.cleanups, 1, label .. " cleans exactly once")
  end

  rejected_boundary({ spawn_error = true }, function() end, "probe-failure", "spawn failure")
  rejected_boundary({}, function(fixture)
    fixture:exit({ code = 124, signal = 15 })
  end, "timeout", "timeout")
  rejected_boundary({}, function(fixture)
    fixture.stdout(nil, string.rep("x", 1024 * 1024 + 1))
    fixture:exit({ code = 137, signal = 9 })
  end, "output-overflow", "overflow")
  rejected_boundary({}, function(fixture)
    fixture.handle:cancel("backend-switch")
    fixture:exit({ code = 137, signal = 9 })
  end, "cancellation", "cancellation")

  local cancellation_first = new_owned_probe()
  cancellation_first.handle:cancel("close")
  cancellation_first.stdout(nil, string.rep("x", 1024 * 1024 + 1))
  cancellation_first:exit({ code = 137, signal = 9 })
  cancellation_first:flush()
  eq(
    cancellation_first.completions[1].category,
    "cancellation",
    "first cancellation cause survives later overflow"
  )

  local stream_failure_first = new_owned_probe()
  stream_failure_first.stdout({ private = "stream-first-secret-canary" }, nil)
  stream_failure_first.stdout(nil, string.rep("x", 1024 * 1024 + 1))
  stream_failure_first:exit({ code = 137, signal = 9 })
  stream_failure_first:flush()
  eq(
    stream_failure_first.completions[1].category,
    "probe-failure",
    "first stream-system cause survives later overflow"
  )

  local uncertain_exit = new_owned_probe()
  uncertain_exit:exit({ code = "invalid", signal = 0 })
  uncertain_exit:flush()
  eq(uncertain_exit.completions[1].category, "cleanup-failure", "unproven exit category")
  eq(#uncertain_exit.cleanups, 0, "unproven exit retains the owned root")

  local immediate_schedule_ok, immediate_schedule_fixture = pcall(new_owned_probe, {
    spawn_error = true,
    schedule = function()
      error({ private = "owned-immediate-scheduler-secret-canary" })
    end,
  })
  assert(immediate_schedule_ok, "owned immediate scheduler exception escaped")
  eq(#immediate_schedule_fixture.cleanups, 1, "owned immediate scheduler failure cleans once")
  eq(#immediate_schedule_fixture.completions, 1, "owned immediate scheduler failure completes once")
  eq(
    immediate_schedule_fixture.completions[1].category,
    "probe-failure",
    "owned immediate scheduler category"
  )

  local delayed_owned_scheduler = new_owned_probe({
    schedule = function()
      error({ private = "owned-delayed-scheduler-secret-canary" })
    end,
  })
  local delayed_owned_ok, delayed_owned_error = pcall(function()
    delayed_owned_scheduler:exit({ code = 0, signal = 0 })
  end)
  assert(
    delayed_owned_ok,
    "owned delayed scheduler exception escaped: " .. vim.inspect(delayed_owned_error)
  )
  eq(#delayed_owned_scheduler.cleanups, 1, "owned delayed scheduler failure cleans once")
  eq(#delayed_owned_scheduler.completions, 1, "owned delayed scheduler failure completes once")
  eq(
    delayed_owned_scheduler.completions[1].category,
    "probe-failure",
    "owned delayed scheduler category"
  )

  local queue_then_throw
  queue_then_throw = new_owned_probe({
    schedule = function(callback)
      queue_then_throw.scheduled[#queue_then_throw.scheduled + 1] = callback
      error({ private = "owned-queued-scheduler-secret-canary" })
    end,
  })
  local queue_then_throw_ok, queue_then_throw_error = pcall(function()
    queue_then_throw:exit({ code = 0, signal = 0 })
  end)
  assert(
    queue_then_throw_ok,
    "owned queue-then-throw scheduler escaped: " .. vim.inspect(queue_then_throw_error)
  )
  eq(#queue_then_throw.cleanups, 1, "owned queue-then-throw cleanup runs once")
  eq(#queue_then_throw.completions, 1, "owned queue-then-throw completion runs once")
  queue_then_throw:flush()
  eq(#queue_then_throw.cleanups, 1, "late queued callback cannot repeat cleanup")
  eq(#queue_then_throw.completions, 1, "late queued callback cannot repeat completion")

  local reentrant_owned = new_owned_probe({
    schedule = function(callback)
      callback()
      error({ private = "owned-reentrant-scheduler-secret-canary" })
    end,
  })
  local reentrant_owned_ok, reentrant_owned_error = pcall(function()
    reentrant_owned:exit({ code = 0, signal = 0 })
  end)
  assert(
    reentrant_owned_ok,
    "owned reentrant scheduler escaped: " .. vim.inspect(reentrant_owned_error)
  )
  eq(#reentrant_owned.cleanups, 1, "owned reentrant scheduler cleans once")
  eq(#reentrant_owned.completions, 1, "owned reentrant scheduler completes once")
  eq(reentrant_owned.completions[1].category, "probe-failure", "owned reentrant category")
  assert(
    not vim.inspect(reentrant_owned.completions):find("secret-canary", 1, true),
    "owned reentrant scheduler retained its arbitrary error"
  )

  local inspect_exception = new_owned_probe({ inspect_error = true })
  inspect_exception:exit({ code = 0, signal = 0 })
  inspect_exception:flush()
  eq(
    inspect_exception.completions[1].category,
    "artifact-rejection",
    "artifact callback exception category"
  )
  assert(
    not vim.inspect(inspect_exception.completions):find("secret-canary", 1, true),
    "artifact callback exception leaked"
  )

  local settle_exception = new_owned_probe({
    command = expected_commands[5],
    settle_error = true,
  })
  settle_exception:exit({ code = 0, signal = 0 })
  settle_exception:flush()
  eq(
    settle_exception.completions[1].category,
    "artifact-rejection",
    "settler callback exception category"
  )
  assert(
    not vim.inspect(settle_exception.completions):find("secret-canary", 1, true),
    "settler callback exception leaked"
  )

  local settling = new_owned_probe({
    command = expected_commands[5],
    settle_pending = true,
  })
  settling:exit({ code = 0, signal = 0 })
  settling:flush()
  eq(settling.trace, { "create", "spawn", "exit", "inspect", "settle" }, "settling waits")
  eq(#settling.cleanups, 0, "settling keeps the exited tree for inspection")
  settling.handle:cancel("close")
  eq(settling.trace, {
    "create",
    "spawn",
    "exit",
    "inspect",
    "settle",
    "settle-cancel",
    "cleanup",
    "complete",
  }, "settler cancellation lifecycle")
  eq(settling.completions[1].category, "cancellation", "settler cancellation category")
  eq(settling.kills, {}, "settler cancellation does not kill an exited process")

  local changed_root = new_owned_probe({ mutate_root_during_inspection = true })
  changed_root:exit({ code = 0, signal = 0 })
  changed_root:flush()
  eq(changed_root.completions[1].category, "cleanup-failure", "changed root fails cleanup")
  eq(#changed_root.cleanups, 0, "changed root reaches no cleanup function")

  local callback_fixture
  callback_fixture = new_owned_probe({
    on_complete = function()
      callback_fixture.trace[#callback_fixture.trace + 1] = "throwing-complete"
      error({ private = "owned-completion-secret-canary" })
    end,
  })
  callback_fixture:exit({ code = 0, signal = 0 })
  local callback_ok, callback_error = pcall(callback_fixture.flush, callback_fixture)
  assert(
    callback_ok,
    "owned completion callback exception escaped: " .. vim.inspect(callback_error)
  )
  eq(callback_fixture.trace, {
    "create",
    "spawn",
    "exit",
    "inspect",
    "cleanup",
    "throwing-complete",
  }, "owned completion callback is contained after cleanup")
  eq(#callback_fixture.cleanups, 1, "throwing completion cleans exactly once")

  local observed = new_owned_probe({
    observe = true,
    now_values = { 100, 20100 },
  })
  observed.stdout(nil, "ok")
  observed.stderr(nil, "warn")
  observed:exit({ code = 0, signal = 0 })
  observed:flush()
  eq(observed.trace, {
    "create",
    "spawn",
    "exit",
    "inspect",
    "observe",
    "cleanup",
    "complete",
  }, "test observer runs only after exit and inspection")
  eq(#observed.observations, 1, "test observer is bounded to one ownership callback")
  eq(observed.observations[1].name, "version", "observer command name")
  eq(observed.observations[1].tree, exact_tree, "observer receives the exact exited tree copy")
  eq(observed.observations[1].observation, {
    artifact_accepted = true,
    artifact_category = "accepted",
    code = 0,
    signal = 0,
    stdout_bytes = 2,
    stderr_bytes = 4,
    stdout_overflow = false,
    stderr_overflow = false,
    system_error = false,
    duration_ms = 10000,
  }, "observer receives only bounded numeric and boolean metadata")
  assert(
    not vim.inspect(observed.observations[1].observation):find("ok", 1, true),
    "observer retained raw streams"
  )

  for _, command_index in ipairs({ 11, 12 }) do
    local command = expected_commands[command_index]
    local not_found = "Agent "
      .. command.name
      .. " not found, run 'opencode agent list' to get an agent list\n"
    local disabled = new_owned_probe({
      command = command,
      observe = true,
    })
    disabled.stderr(nil, not_found)
    disabled:exit({ code = 1, signal = 0 })
    disabled:flush()
    eq(disabled.trace, {
      "create",
      "spawn",
      "exit",
      "inspect",
      "settle",
      "observe",
      "cleanup",
      "complete",
    }, command.name .. " disabled observer lifecycle")
    eq(#disabled.observations, 1, command.name .. " disabled observer count")
    local disabled_observation = disabled.observations[1]
    eq(disabled_observation.name, command.name, command.name .. " disabled observer name")
    eq(disabled_observation.observation, {
      artifact_accepted = true,
      artifact_category = "accepted",
      code = 1,
      signal = 0,
      stdout_bytes = 0,
      stderr_bytes = #not_found,
      stdout_overflow = false,
      stderr_overflow = false,
      system_error = false,
      duration_ms = 0,
    }, command.name .. " disabled observer bounded metadata")
    assert(
      disabled_observation.observation.stdout == nil,
      command.name .. " disabled observer retained raw stdout"
    )
    assert(
      disabled_observation.observation.stderr == nil,
      command.name .. " disabled observer retained raw stderr"
    )
    eq(
      disabled_observation.observation.artifact_accepted,
      true,
      command.name .. " disabled artifact acceptance"
    )
    eq(
      disabled_observation.observation.artifact_category,
      "accepted",
      command.name .. " disabled artifact category"
    )
    eq(disabled_observation.observation.code, 1, command.name .. " disabled observed code")
    eq(disabled_observation.observation.signal, 0, command.name .. " disabled observed signal")
    eq(
      disabled_observation.observation.stderr_bytes,
      #not_found,
      command.name .. " disabled observed stderr bytes"
    )
    eq(#disabled.completions, 1, command.name .. " disabled completion count")
    local completion = disabled.completions[1]
    eq(completion.category, "", command.name .. " disabled completion category")
    assert(completion.result, command.name .. " disabled result was discarded")
    eq(completion.result.code, 1, command.name .. " disabled result code")
    eq(completion.result.signal, 0, command.name .. " disabled result signal")
    eq(completion.result.stdout, "", command.name .. " disabled result stdout")
    eq(completion.result.stderr, not_found, command.name .. " disabled result stderr")

    local parser_results, parser_report = fixture_results()
    local parser = validation._test.new_parser()
    for prefix_index = 1, command_index - 1 do
      local prefix_command = expected_commands[prefix_index]
      local accepted, category = parser:accept(prefix_command, parser_results[prefix_command.name])
      assert(accepted, category)
    end
    local accepted, category = parser:accept(command, completion.result)
    assert(accepted, category)
    for suffix_index = command_index + 1, #expected_commands do
      local suffix_command = expected_commands[suffix_index]
      accepted, category = parser:accept(suffix_command, parser_results[suffix_command.name])
      assert(accepted, category)
    end
    local parsed_report, finish_category = parser:finish()
    assert(parsed_report, finish_category)
    eq(
      parsed_report,
      parser_report,
      command.name .. " disabled result reaches command-specific semantic parsing"
    )
  end

  local drained = new_owned_probe({ wait_result = { code = 137, signal = 9 } })
  eq(drained.handle:shutdown_drain(2000), true, "exit-only drain proves exit and cleanup")
  eq(drained.trace, { "create", "spawn", "kill", "wait", "inspect", "cleanup" }, "drain lifecycle")
  eq(drained.waits, { 2000 }, "shutdown uses the sole exact drain timeout")
  eq(drained.kills, { "sigkill" }, "shutdown drain kills once")
  eq(#drained.cleanups, 1, "shutdown drain cleans once after wait")
  drained:flush()
  eq(#drained.cleanups, 1, "scheduled exit callback cannot repeat drained cleanup")
  eq(drained.handle:shutdown_drain(2000), true, "repeated drained shutdown is idempotent")
  eq(drained.waits, { 2000 }, "repeated drained shutdown never waits twice")

  for _, case in ipairs({
    { label = "wait exception", wait_error = true },
    { label = "invalid wait result", wait_result = { code = "bad", signal = 0 } },
  }) do
    local fixture = new_owned_probe(case)
    eq(fixture.handle:shutdown_drain(2000), false, case.label .. " cannot prove exit")
    eq(fixture.waits, { 2000 }, case.label .. " remains bounded")
    eq(#fixture.cleanups, 0, case.label .. " retains the private root")
    eq(#fixture.completions, 0, case.label .. " publishes no completion")
    assert(
      not vim.inspect(fixture):find("wait-secret-canary", 1, true),
      case.label .. " retained a raw wait error"
    )
  end

  local wrong_drain = new_owned_probe()
  eq(wrong_drain.handle:shutdown_drain(1999), false, "nonexact drain timeout is refused")
  eq(wrong_drain.waits, {}, "nonexact drain timeout never waits")
  eq(#wrong_drain.cleanups, 0, "nonexact drain timeout retains the root")

  local factory_creates = 0
  local factory_cleanups = 0
  local factory_kills = 0
  local factory_scheduled = {}
  local factory_exit
  local factory_timer
  local factory_controller = new_opencode_validation({
    executable = identity.executable,
    revalidate = function()
      return true
    end,
    stat = function()
      return vim.deepcopy(executable_stat)
    end,
    create_tree = function()
      factory_creates = factory_creates + 1
      return vim.deepcopy(exact_tree)
    end,
    cleanup_tree = function(root)
      eq(root, owned_root, "factory cleans the exact owned root")
      factory_cleanups = factory_cleanups + 1
      return true
    end,
    inspect_artifacts = function()
      return { disposition = "quiescent", fingerprint = "absent" }
    end,
    settle_lock = function(_, _, _, callback)
      callback(true)
      return function() end
    end,
    resolve = function()
      return "/usr/bin/bwrap"
    end,
    lstat = function()
      return vim.deepcopy(directory_stat)
    end,
    getuid = function()
      return 1000
    end,
    system = function(_, _, callback)
      factory_exit = callback
      return {
        kill = function()
          factory_kills = factory_kills + 1
        end,
        wait = function()
          error("factory-wait-secret-canary")
        end,
      }
    end,
    now = function()
      return 100
    end,
    defer = function(callback, delay_ms)
      factory_timer = {
        callback = callback,
        delay_ms = delay_ms,
        stopped = false,
        closed = false,
      }
      function factory_timer:stop()
        self.stopped = true
      end
      function factory_timer:is_closing()
        return self.closed
      end
      function factory_timer:close()
        self.closed = true
      end
      return factory_timer
    end,
    schedule = function(callback)
      factory_scheduled[#factory_scheduled + 1] = callback
    end,
    notify = function() end,
    warn_level = vim.log.levels.WARN,
  })
  eq(factory_creates, 0, "controller factory is lazy")
  eq(factory_controller:snapshot().state, "not_checked", "factory snapshot is passive")
  eq(factory_creates, 0, "passive factory snapshot creates no private tree")
  factory_controller:ensure({ reason = "open", identity_key = IDENTITY_KEY })
  eq(factory_creates, 1, "explicit ensure creates one command-owned tree")
  eq(factory_timer.delay_ms, 60000, "factory preserves the controller sequence ceiling")
  factory_controller:cancel("close")
  eq(factory_kills, 1, "factory cancellation kills one active process")
  eq(factory_cleanups, 0, "factory cancellation waits for process exit")
  factory_exit({ code = 137, signal = 9 })
  while #factory_scheduled > 0 do
    table.remove(factory_scheduled, 1)()
  end
  eq(factory_cleanups, 1, "factory cleanup follows proven exit")
  eq(factory_controller:snapshot().state, "not_checked", "factory cancellation returns idle")
  factory_controller:shutdown(false)

  local passive_dependency_calls = 0
  local passive = registry._test.new({
    executable = function()
      passive_dependency_calls = passive_dependency_calls + 1
      error("passive-executable-secret-canary")
    end,
    stat = function()
      passive_dependency_calls = passive_dependency_calls + 1
      error("passive-stat-secret-canary")
    end,
    revalidate = function()
      passive_dependency_calls = passive_dependency_calls + 1
      error("passive-revalidate-secret-canary")
    end,
    opencode_validation = setmetatable({}, {
      __index = function()
        passive_dependency_calls = passive_dependency_calls + 1
        error("passive-controller-secret-canary")
      end,
    }),
  })
  eq(passive_dependency_calls, 0, "registry construction is passive")
  eq(passive:names(), { "codex", "claude", "opencode" }, "passive registry names")
  assert(type(passive:get("opencode")) == "table", "passive registry returns the adapter")
  for _, method in ipairs({
    "opencode_compatibility",
    "ensure_opencode_compatibility",
    "take_opencode_open",
    "cancel_opencode_compatibility",
    "subscribe_opencode_compatibility",
    "shutdown",
  }) do
    assert(type(passive[method]) == "function", "Task 5 registry facade is missing: " .. method)
  end
  eq(passive_dependency_calls, 0, "registry names and get start no validation or private tree")
  eq(passive:shutdown(false), true, "unused passive registry shutdown succeeds")
  local passive_terminal_snapshot = passive:opencode_compatibility()
  eq(passive_terminal_snapshot, {
    state = "not_checked",
    installed = false,
    executable = "",
    version = "",
    category = "",
    queued = false,
  }, "passive shutdown returns an idle compatibility snapshot")
  passive_terminal_snapshot.state = "failed"
  eq(passive:opencode_compatibility(), {
    state = "not_checked",
    installed = false,
    executable = "",
    version = "",
    category = "",
    queued = false,
  }, "passive shutdown compatibility snapshots are fresh")
  local passive_ensure, passive_ensure_error =
    passive:ensure_opencode_compatibility({ reason = "picker" })
  eq(passive_ensure, nil, "passive shutdown refuses compatibility ensure")
  eq(
    passive_ensure_error,
    "managed OpenCode compatibility request is invalid",
    "passive shutdown ensure diagnostic"
  )
  eq(passive:take_opencode_open(IDENTITY_KEY), false, "passive shutdown has no queued open")
  eq(passive:cancel_opencode_compatibility("close"), nil, "passive shutdown cancellation is inert")
  local passive_unsubscribe, passive_subscribe_error = passive:subscribe_opencode_compatibility(
    function() end
  )
  eq(passive_unsubscribe, nil, "passive shutdown refuses observers")
  eq(
    passive_subscribe_error,
    "managed OpenCode compatibility observer is unavailable",
    "passive shutdown observer diagnostic"
  )
  eq(passive:shutdown(true), true, "passive registry shutdown is idempotent")
  eq(passive_dependency_calls, 0, "unused shutdown does not construct the controller")
end

for _, active in ipairs({ true, false }) do
  local label = active and "active adapter services" or "unused adapter services"
  local calls = {
    snapshot = 0,
    report = 0,
    shutdown = 0,
    touches = 0,
    starts = 0,
  }
  local ready_snapshot = {
    state = "ready",
    installed = true,
    executable = "/usr/bin/opencode",
    version = "1.18.30",
    category = "",
    queued = false,
  }
  local controller
  if active then
    controller = {
      snapshot = function()
        calls.snapshot = calls.snapshot + 1
        return vim.deepcopy(ready_snapshot)
      end,
      report = function()
        calls.report = calls.report + 1
        return managed._test.compatibility_fixture()
      end,
      shutdown = function(_, exit_committed)
        assert(type(exit_committed) == "boolean", label .. " shutdown phase")
        calls.shutdown = calls.shutdown + 1
        return true
      end,
    }
  else
    controller = setmetatable({}, {
      __index = function()
        calls.touches = calls.touches + 1
        error("unused-adapter-service-secret-canary")
      end,
    })
  end

  local captured_services
  local original_opencode = package.loaded["ai.backends.opencode"]
  package.loaded["ai.backends.opencode"] = {
    new = function(services)
      captured_services = services
      return {}
    end,
  }
  local construction_ok, service_registry = pcall(registry._test.new, {
    opencode_validation = controller,
    start_opencode_probe = function()
      calls.starts = calls.starts + 1
      error("adapter services started a probe")
    end,
  })
  package.loaded["ai.backends.opencode"] = original_opencode
  assert(
    construction_ok,
    label .. " registry construction failed: " .. vim.inspect(service_registry)
  )
  assert(type(captured_services) == "table", label .. " did not capture adapter services")

  if active then
    eq(
      captured_services.opencode_compatibility_snapshot(),
      ready_snapshot,
      label .. " activates one controller"
    )
  end
  eq(service_registry:shutdown(false), true, label .. " first shutdown")
  local idle_snapshot = captured_services.opencode_compatibility_snapshot()
  eq(idle_snapshot, {
    state = "not_checked",
    installed = false,
    executable = "",
    version = "",
    category = "",
    queued = false,
  }, label .. " terminal snapshot")
  idle_snapshot.state = "failed"
  eq(captured_services.opencode_compatibility_snapshot(), {
    state = "not_checked",
    installed = false,
    executable = "",
    version = "",
    category = "",
    queued = false,
  }, label .. " fresh terminal snapshot")
  eq(captured_services.opencode_compatibility_report(), nil, label .. " terminal report")
  eq(service_registry:shutdown(true), true, label .. " repeated shutdown")
  eq(calls, {
    snapshot = active and 1 or 0,
    report = 0,
    shutdown = active and 1 or 0,
    touches = 0,
    starts = 0,
  }, label .. " exact terminal access")
end

do
  local create_opencode_probe_tree = registry._test.create_opencode_probe_tree
  assert(
    type(create_opencode_probe_tree) == "function",
    "private-tree creation export is unavailable"
  )
  local original_mkdir = vim.fn.mkdir
  local original_delete = vim.fn.delete
  local original_lstat = vim.uv.fs_lstat
  for _, case in ipairs({
    {
      label = "partial-create delete exception",
      remove = function()
        error("partial-create-secret-canary")
      end,
      lstat = original_lstat,
      expected_error = "cleanup-failure",
    },
    {
      label = "partial-create delete failure status",
      remove = function()
        return -1
      end,
      lstat = original_lstat,
      expected_error = "cleanup-failure",
    },
    {
      label = "partial-create root remains",
      remove = function()
        return 0
      end,
      lstat = original_lstat,
      expected_error = "cleanup-failure",
    },
    {
      label = "partial-create ambiguous root lookup",
      remove = function()
        return 0
      end,
      lstat = function()
        return nil
      end,
      expected_error = "cleanup-failure",
    },
    {
      label = "partial-create verified root absence",
      remove = function(path, flags)
        return original_delete(path, flags)
      end,
      lstat = original_lstat,
      expected_error = "probe-failure",
    },
  }) do
    local partial_root
    local mkdir_calls = 0
    vim.fn.mkdir = function(path, flags, mode)
      mkdir_calls = mkdir_calls + 1
      if mkdir_calls == 1 then
        partial_root = path
        local status = original_mkdir(path, flags, mode)
        local stat = assert(original_lstat(path))
        assert(status == 1, case.label .. " did not create its fixture root")
        eq(stat.uid, vim.uv.getuid(), case.label .. " root owner")
        eq(require("bit").band(stat.mode, 511), 448, case.label .. " root mode")
        return status
      end
      return 0
    end
    vim.fn.delete = case.remove
    vim.uv.fs_lstat = case.lstat
    local call_ok, tree, create_error = pcall(create_opencode_probe_tree)
    vim.fn.mkdir = original_mkdir
    vim.fn.delete = original_delete
    vim.uv.fs_lstat = original_lstat

    assert(call_ok, case.label .. " raised through the creation boundary")
    eq(tree, nil, case.label .. " returned a partial tree")
    eq(create_error, case.expected_error, case.label .. " bounded category")
    assert(type(create_error) == "string" and #create_error <= 256, case.label .. " category")
    assert(
      not create_error:find("partial-create-secret-canary", 1, true),
      case.label .. " leaked its injected error"
    )
    if partial_root and original_lstat(partial_root) then
      assert(original_delete(partial_root, "rf") == 0, case.label .. " fixture cleanup")
      assert(original_lstat(partial_root) == nil, case.label .. " left fixture residue")
    end
  end
  eq(vim.fn.mkdir, original_mkdir, "partial-create fixture restores vim.fn.mkdir")
  eq(vim.fn.delete, original_delete, "partial-create fixture restores vim.fn.delete")
  eq(vim.uv.fs_lstat, original_lstat, "partial-create fixture restores vim.uv.fs_lstat")
end

assert(validation.parse_results == nil, "production parser export must be absent")
assert(
  type(validation._test.parse_results) == "function",
  "test parser export must remain available"
)

print("AI OpenCode background validation assertions: ok")
