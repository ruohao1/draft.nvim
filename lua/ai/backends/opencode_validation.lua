local M = {}

local managed = require("ai.backends.opencode_managed")

local MAX_HELP_BYTES = 65536
local MAX_REPORT_BYTES = 1024 * 1024
local FORBIDDEN_EVIDENCE = {
  "installing configuration dependenc",
  "downloading plugin",
  "loading plugin",
  "checking for update",
  "downloading lsp",
  "network request",
}
local HELP_REQUIREMENTS = {
  root_help = { "--pure", "serve", "attach" },
  serve_help = { "--hostname", "--port" },
  attach_help = { "--dir", "--session", "OPENCODE_SERVER_PASSWORD" },
}
local AGENT_COMMANDS = {
  build = true,
  plan = true,
  compaction = true,
  summary = true,
  title = true,
}
local AGENT_LIST_MODES = {
  all = true,
  primary = true,
  subagent = true,
}
local OPENCODE_PRIMARY_TOOLS = {
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
local COMMANDS = {
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

local function valid_result(result)
  return type(result) == "table"
    and type(result.code) == "number"
    and type(result.signal) == "number"
    and result.signal == 0
    and type(result.stdout) == "string"
    and type(result.stderr) == "string"
    and result.stdout_overflow ~= true
    and result.stderr_overflow ~= true
    and result.system_error ~= true
    and #result.stdout <= MAX_REPORT_BYTES
    and #result.stderr <= MAX_HELP_BYTES
end

local function has_forbidden_evidence(result)
  local output = (result.stdout .. "\n" .. result.stderr):lower()
  for _, evidence in ipairs(FORBIDDEN_EVIDENCE) do
    if output:find(evidence, 1, true) then
      return true
    end
  end
  return false
end

local function valid_permission_json(lines)
  if type(lines) ~= "table" or #lines == 0 then
    return false
  end
  local encoded = table.concat(lines, "\n")
  local decoded_ok, decoded = pcall(vim.json.decode, encoded)
  encoded = nil
  if not decoded_ok or type(decoded) ~= "table" or not vim.islist(decoded) then
    return false
  end
  decoded = nil
  return true
end

local function parse_names(result)
  if result.code ~= 0 or result.stderr ~= "" or #result.stdout > MAX_HELP_BYTES then
    return nil
  end

  local output = result.stdout:gsub("\r\n", "\n")
  if output == "" or output:find("\r", 1, true) then
    return nil
  end
  if output:sub(-1) ~= "\n" then
    output = output .. "\n"
  end

  local names = {}
  local seen = {}
  local permission_lines
  local function finish_entry()
    if not valid_permission_json(permission_lines) then
      return false
    end
    permission_lines = nil
    return true
  end

  for line in output:gmatch("(.-)\n") do
    local name, mode = line:match("^([%w_-]+) %(([%w_-]+)%)$")
    if name then
      if not AGENT_LIST_MODES[mode] or seen[name] then
        return nil
      end
      if permission_lines and not finish_entry() then
        return nil
      end
      seen[name] = true
      names[#names + 1] = name
      permission_lines = {}
    else
      if not permission_lines then
        return nil
      end
      permission_lines[#permission_lines + 1] = line
    end
  end

  if not finish_entry() then
    return nil
  end
  output = nil
  table.sort(names)
  return names
end

local function parse_agent(name, result)
  if result.code ~= 0 or result.stderr ~= "" then
    return nil
  end
  local decoded_ok, decoded = pcall(vim.json.decode, result.stdout)
  if not decoded_ok or type(decoded) ~= "table" then
    return nil
  end
  local agent
  if name == "build" or name == "plan" then
    if not vim.deep_equal(decoded.tools, OPENCODE_PRIMARY_TOOLS) then
      return nil
    end
    agent = {
      native = decoded.native,
      mode = decoded.mode,
      tools = {},
      permission = decoded.permission,
    }
  else
    agent = {
      native = decoded.native,
      hidden = decoded.hidden,
      tools = decoded.tools,
      permission = decoded.permission,
    }
  end
  local encoded_ok, encoded = pcall(vim.json.encode, agent)
  if not encoded_ok or type(encoded) ~= "string" or #encoded > MAX_REPORT_BYTES then
    return nil
  end
  return agent
end

local function valid_disabled(name, result)
  local expected = "Agent " .. name .. " not found, run 'opencode agent list' to get an agent list"
  local output = result.stderr ~= "" and result.stderr or result.stdout
  return result.code ~= 0
    and not (result.stderr ~= "" and result.stdout ~= "")
    and (output == expected or output == expected .. "\n")
end

local function new_parser()
  local state = {
    index = 0,
    version = false,
    names = nil,
    agents = {},
    finished = false,
  }
  local parser = {}

  function parser:accept(command, result)
    local expected = COMMANDS[state.index + 1]
    if
      state.finished
      or not expected
      or not vim.deep_equal(command, expected)
      or not valid_result(result)
      or has_forbidden_evidence(result)
    then
      return nil, "parse-failure"
    end

    local name = expected.name
    if name == "version" then
      local version = result.stdout:gsub("\n$", "")
      if result.code ~= 0 or result.stderr ~= "" or not managed.valid_version(version) then
        return nil, "parse-failure"
      end
      if version ~= managed.version() then
        return nil, "version-mismatch", version
      end
      state.version = true
    elseif HELP_REQUIREMENTS[name] then
      if result.code ~= 0 or result.stdout ~= "" or result.stderr == "" then
        return nil, "parse-failure"
      end
      for _, requirement in ipairs(HELP_REQUIREMENTS[name]) do
        if not result.stderr:find(requirement, 1, true) then
          return nil, "parse-failure"
        end
      end
    elseif name == "names" then
      state.names = parse_names(result)
      if not state.names then
        return nil, "parse-failure"
      end
    elseif AGENT_COMMANDS[name] then
      state.agents[name] = parse_agent(name, result)
      if not state.agents[name] then
        return nil, "parse-failure"
      end
    elseif not valid_disabled(name, result) then
      return nil, "parse-failure"
    end
    state.index = state.index + 1
    return true
  end

  function parser:finish()
    if state.finished or state.index ~= #COMMANDS or state.version ~= true then
      return nil, "parse-failure"
    end
    local report = {
      version = managed.version(),
      help = {
        root = { "--pure", "serve", "attach" },
        serve = { "--hostname", "--port" },
        attach = { "--dir", "--session", "OPENCODE_SERVER_PASSWORD" },
      },
      names = vim.deepcopy(state.names),
      agents = vim.deepcopy(state.agents),
    }
    local compatible_ok, compatible = pcall(managed.validate_compatibility, report)
    if not compatible_ok or not compatible then
      return nil, "parse-failure"
    end
    state.finished = true
    state.names = nil
    state.agents = {}
    return vim.deepcopy(report)
  end

  function parser:debug_state()
    return {
      index = state.index,
      version = state.version,
      name_count = type(state.names) == "table" and #state.names or 0,
      agent_count = vim.tbl_count(state.agents),
      finished = state.finished,
    }
  end

  return parser
end

local function parse_results(results)
  if type(results) ~= "table" then
    return nil, "parse-failure"
  end
  local parser = new_parser()
  for _, command in ipairs(COMMANDS) do
    local accepted, category, version = parser:accept(command, results[command.name])
    if not accepted then
      return nil, category, version
    end
  end
  return parser:finish()
end

local MAX_OBSERVERS = 32
local SEQUENCE_TIMEOUT_MS = 60000
local VALID_IDENTITY_KEY = "^[0-9a-f]+$"
local VALID_CANCEL_REASON = {
  close = true,
  ["backend-switch"] = true,
  shutdown = true,
  ["executable-drift"] = true,
}
local VALID_FAILURE = {
  unavailable = true,
  timeout = true,
  ["output-overflow"] = true,
  ["executable-drift"] = true,
  ["probe-failure"] = true,
  ["artifact-rejection"] = true,
  ["parse-failure"] = true,
  ["version-mismatch"] = true,
  cancellation = true,
  ["cleanup-failure"] = true,
}

local function idle_snapshot()
  return {
    state = "not_checked",
    installed = false,
    executable = "",
    version = "",
    category = "",
    queued = false,
  }
end

local function valid_identity(identity)
  return type(identity) == "table"
    and type(identity.installed) == "boolean"
    and type(identity.executable) == "string"
    and type(identity.metadata) == "string"
    and (
      (not identity.installed and identity.executable == "" and identity.metadata == "")
      or (identity.installed and identity.executable:sub(1, 1) == "/" and identity.metadata ~= "")
    )
end

local function same_identity(left, right)
  return valid_identity(left)
    and valid_identity(right)
    and left.installed == right.installed
    and left.executable == right.executable
    and left.metadata == right.metadata
end

local function stop_timer(timer)
  if not timer then
    return
  end
  if type(timer.stop) == "function" then
    pcall(timer.stop, timer)
  end
  local closing = false
  if type(timer.is_closing) == "function" then
    local ok, value = pcall(timer.is_closing, timer)
    closing = ok and value == true
  end
  if not closing and type(timer.close) == "function" then
    pcall(timer.close, timer)
  end
end

local function new(deps)
  assert(type(deps) == "table", "OpenCode validation dependencies are required")
  for _, name in ipairs({ "identify", "start_probe", "now", "defer", "schedule", "notify" }) do
    assert(type(deps[name]) == "function", "OpenCode validation dependency is invalid: " .. name)
  end

  local state = {
    phase = "unknown",
    identity = nil,
    parser = nil,
    report = nil,
    cache_ticket = nil,
    category = "",
    observed_version = "",
    generation = 0,
    active = nil,
    sequence_timer = nil,
    queued_identity = nil,
    observers = {},
    observer_count = 0,
    next_observer = 0,
    stopped = false,
    shutdown_result = true,
    cancelling = nil,
    command_index = 0,
    sequence_started_at = 0,
  }
  local controller = {}
  local start_next

  local function current_identity()
    local ok, identity = pcall(deps.identify)
    if not ok or not valid_identity(identity) then
      return { installed = false, executable = "", metadata = "" }
    end
    return vim.deepcopy(identity)
  end

  local function raw_snapshot()
    local identity = state.identity or { installed = false, executable = "", metadata = "" }
    return {
      state = state.phase == "unknown" and "not_checked" or state.phase,
      installed = identity.installed,
      executable = identity.executable,
      version = state.phase == "ready" and managed.version() or state.observed_version,
      category = state.phase == "failed" and state.category or "",
      queued = state.queued_identity ~= nil,
    }
  end

  local function publish(notify_failure)
    local published = raw_snapshot()
    local generation = state.generation
    for key, callback in pairs(state.observers) do
      local copy = vim.deepcopy(published)
      deps.schedule(function()
        if
          not state.stopped
          and generation == state.generation
          and state.observers[key] == callback
        then
          pcall(callback, copy)
        end
      end)
    end
    if notify_failure and published.state == "failed" then
      local category = VALID_FAILURE[published.category] and published.category or "probe-failure"
      local message = category == "version-mismatch" and managed.version_mismatch(published.version)
        or ("managed OpenCode validation failed: " .. category)
      deps.schedule(function()
        if not state.stopped and generation == state.generation then
          pcall(deps.notify, message, deps.warn_level)
        end
      end)
    end
  end

  local function clear_sequence_timer()
    stop_timer(state.sequence_timer)
    state.sequence_timer = nil
  end

  local function reset(identity)
    clear_sequence_timer()
    state.generation = state.generation + 1
    state.phase = "unknown"
    state.identity = vim.deepcopy(identity)
    state.parser = nil
    state.report = nil
    state.cache_ticket = nil
    state.category = ""
    state.observed_version = ""
    state.active = nil
    state.cancelling = nil
    state.command_index = 0
    state.sequence_started_at = 0
    state.queued_identity = nil
  end

  local function fail(category, version)
    clear_sequence_timer()
    state.phase = "failed"
    state.parser = nil
    state.report = nil
    state.cache_ticket = nil
    state.category = VALID_FAILURE[category] and category or "probe-failure"
    state.observed_version = ""
    if state.category == "version-mismatch" then
      if managed.version_mismatch(version) then
        state.observed_version = version
      else
        state.category = "parse-failure"
      end
    end
    state.active = nil
    state.cancelling = nil
    state.command_index = 0
    state.sequence_started_at = 0
    state.queued_identity = nil
    publish(true)
  end

  local function cancel_active(outcome, category, identity)
    clear_sequence_timer()
    state.queued_identity = nil
    state.cancelling = {
      outcome = outcome,
      category = category,
      identity = vim.deepcopy(identity or state.identity),
    }
    publish(false)
    local slot = state.active
    if slot then
      slot.cancel_reason = category
      if slot.handle and type(slot.handle.cancel) == "function" then
        pcall(slot.handle.cancel, slot.handle, category)
      end
      return
    end
    if outcome == "failed" then
      fail(category)
    else
      reset(identity or current_identity())
      publish(false)
    end
  end

  local function reconcile_identity()
    local identity = current_identity()
    if not state.identity then
      state.identity = vim.deepcopy(identity)
      return identity
    end
    if same_identity(identity, state.identity) then
      return identity
    end
    if state.phase == "checking" then
      if not state.cancelling then
        cancel_active("unknown", "executable-drift", identity)
      end
      return identity
    end
    reset(identity)
    publish(false)
    return identity
  end

  local function complete_probe(slot, completion)
    if state.stopped or state.generation ~= slot.generation or state.active ~= slot then
      completion.result = nil
      completion.category = nil
      return
    end

    local result = completion.result
    local category = completion.category
    completion.result = nil
    completion.category = nil
    state.active = nil

    if state.cancelling then
      result = nil
      local cancellation = state.cancelling
      if category == "cleanup-failure" or category == "artifact-rejection" then
        fail(category)
      elseif cancellation.outcome == "failed" then
        fail(cancellation.category)
      else
        reset(cancellation.identity)
        publish(false)
      end
      return
    end

    if category ~= nil and category ~= "" then
      result = nil
      fail(category)
      return
    end
    if type(result) ~= "table" then
      result = nil
      fail("probe-failure")
      return
    end
    local parser = state.parser
    if type(parser) ~= "table" or type(parser.accept) ~= "function" then
      result = nil
      fail("parse-failure")
      return
    end
    local accept_ok, accepted, parse_category, version =
      pcall(parser.accept, parser, slot.command, result)
    result = nil
    if not accept_ok or not accepted then
      if accept_ok and parse_category == "version-mismatch" then
        fail(parse_category, version)
      else
        fail("parse-failure")
      end
      return
    end
    state.command_index = state.command_index + 1
    start_next()
  end

  local function finish_success()
    local parser = state.parser
    if type(parser) ~= "table" or type(parser.finish) ~= "function" then
      fail("parse-failure")
      return
    end
    local parse_ok, report = pcall(parser.finish, parser)
    if not parse_ok or not report then
      fail("parse-failure")
      return
    end
    local identity = current_identity()
    if not same_identity(identity, state.identity) then
      cancel_active("unknown", "executable-drift", identity)
      return
    end
    clear_sequence_timer()
    if deps.cache and state.cache_ticket then
      -- Publication is best effort and only follows all probes and cleanup.
      pcall(deps.cache.publish, deps.cache, state.cache_ticket, identity, vim.deepcopy(report))
    end
    state.cache_ticket = nil
    identity = current_identity()
    if not same_identity(identity, state.identity) then
      cancel_active("unknown", "executable-drift", identity)
      return
    end
    state.phase = "ready"
    state.parser = nil
    state.report = vim.deepcopy(report)
    state.category = ""
    state.observed_version = ""
    state.active = nil
    state.cancelling = nil
    state.command_index = 0
    state.sequence_started_at = 0
    publish(false)
  end

  start_next = function()
    if state.stopped or state.phase ~= "checking" or state.cancelling then
      return
    end
    if deps.now() - state.sequence_started_at >= SEQUENCE_TIMEOUT_MS then
      cancel_active("failed", "timeout", state.identity)
      return
    end
    local identity = current_identity()
    if not same_identity(identity, state.identity) then
      cancel_active("unknown", "executable-drift", identity)
      return
    end
    local command = COMMANDS[state.command_index + 1]
    if not command then
      finish_success()
      return
    end

    local slot = {
      generation = state.generation,
      command = vim.deepcopy(command),
      handle = nil,
      cancel_reason = nil,
    }
    state.active = slot
    local ok, handle, start_error = pcall(
      deps.start_probe,
      vim.deepcopy(state.identity),
      vim.deepcopy(command),
      function(result, category)
        local completion = { result = result, category = category }
        result = nil
        category = nil
        deps.schedule(function()
          complete_probe(slot, completion)
        end)
      end
    )
    if
      ok
      and type(handle) == "table"
      and type(handle.cancel) == "function"
      and type(handle.shutdown_drain) == "function"
    then
      if state.active == slot then
        slot.handle = handle
        if slot.cancel_reason then
          pcall(handle.cancel, handle, slot.cancel_reason)
        end
      end
      return
    end
    local failure = ok and start_error or handle
    local completion = {
      result = nil,
      category = type(failure) == "string" and VALID_FAILURE[failure] and failure
        or "probe-failure",
    }
    failure = nil
    handle = nil
    start_error = nil
    deps.schedule(function()
      complete_probe(slot, completion)
    end)
  end

  local function start_sequence(identity, ticket)
    state.generation = state.generation + 1
    state.phase = "checking"
    state.identity = vim.deepcopy(identity)
    state.parser = new_parser()
    state.report = nil
    state.cache_ticket = ticket
    state.category = ""
    state.observed_version = ""
    state.active = nil
    state.cancelling = nil
    state.command_index = 0
    state.sequence_started_at = deps.now()
    local generation = state.generation
    state.sequence_timer = deps.defer(function()
      deps.schedule(function()
        if
          not state.stopped
          and state.phase == "checking"
          and state.generation == generation
          and not state.cancelling
        then
          cancel_active("failed", "timeout", state.identity)
        end
      end)
    end, SEQUENCE_TIMEOUT_MS)
    publish(false)
    start_next()
  end

  function controller:snapshot()
    if state.stopped then
      return idle_snapshot()
    end
    reconcile_identity()
    return vim.deepcopy(raw_snapshot())
  end

  function controller:report()
    if state.stopped then
      return nil
    end
    reconcile_identity()
    return state.phase == "ready" and vim.deepcopy(state.report) or nil
  end

  function controller:ensure(request)
    if
      state.stopped
      or type(request) ~= "table"
      or (request.reason ~= "picker" and request.reason ~= "open")
      or (request.reason == "picker" and (request.identity_key ~= nil or vim.tbl_count(request) ~= 1))
      or (
        request.reason == "open"
        and (
          vim.tbl_count(request) ~= 2
          or type(request.identity_key) ~= "string"
          or #request.identity_key ~= 32
          or request.identity_key:match(VALID_IDENTITY_KEY) == nil
        )
      )
    then
      return nil, "managed OpenCode compatibility request is invalid"
    end

    local identity = reconcile_identity()
    if state.cancelling then
      return vim.deepcopy(raw_snapshot())
    end
    if not identity.installed then
      if
        request.reason == "picker"
        and state.phase == "failed"
        and state.category == "unavailable"
      then
        return vim.deepcopy(raw_snapshot())
      end
      fail("unavailable")
      return self:snapshot()
    end
    if request.reason == "open" then
      if state.queued_identity and state.queued_identity ~= request.identity_key then
        return nil, "managed OpenCode opening identity changed"
      end
      state.queued_identity = request.identity_key
    end

    if state.phase == "unknown" then
      local report, ticket
      if deps.cache then
        local ok, cached, receipt = pcall(deps.cache.lookup, deps.cache, vim.deepcopy(identity))
        if ok then
          report, ticket = cached, receipt
        end
      end
      local current = current_identity()
      if not same_identity(identity, current) then
        reset(current)
        publish(false)
        return vim.deepcopy(raw_snapshot())
      end
      local valid, compatible = pcall(managed.validate_compatibility, report)
      if valid and compatible then
        state.generation = state.generation + 1
        state.phase = "ready"
        state.report = vim.deepcopy(report)
        publish(false)
      else
        start_sequence(identity, ticket)
      end
    elseif state.phase == "failed" and request.reason == "open" then
      -- Explicit retry of a failed audit must not consume an older receipt.
      start_sequence(identity)
    elseif state.phase == "ready" and request.reason == "open" then
      publish(false)
    end
    return vim.deepcopy(raw_snapshot())
  end

  function controller:take_open(identity_key)
    if
      state.stopped
      or state.phase ~= "ready"
      or type(identity_key) ~= "string"
      or #identity_key ~= 32
      or identity_key:match(VALID_IDENTITY_KEY) == nil
      or state.queued_identity ~= identity_key
    then
      return false
    end
    reconcile_identity()
    if state.phase ~= "ready" or state.queued_identity ~= identity_key then
      return false
    end
    state.queued_identity = nil
    publish(false)
    return true
  end

  function controller:cancel(reason)
    if state.stopped or not VALID_CANCEL_REASON[reason] then
      return
    end
    if reason == "shutdown" then
      self:shutdown(false)
      return
    end
    if state.phase == "ready" and (reason == "close" or reason == "backend-switch") then
      local generation = state.generation
      reconcile_identity()
      if state.generation ~= generation then
        return
      end
    end
    state.queued_identity = nil
    if state.phase == "checking" then
      if not state.cancelling then
        local identity = reason == "executable-drift" and current_identity() or state.identity
        cancel_active("unknown", reason, identity)
      end
      return
    end
    if reason == "executable-drift" then
      reset(current_identity())
    end
    publish(false)
  end

  function controller:subscribe(callback)
    if state.stopped or type(callback) ~= "function" or state.observer_count >= MAX_OBSERVERS then
      return nil, "managed OpenCode compatibility observer is unavailable"
    end
    state.next_observer = state.next_observer + 1
    local key = state.next_observer
    state.observers[key] = callback
    state.observer_count = state.observer_count + 1
    local subscribed = true
    return function()
      if subscribed and state.observers[key] then
        subscribed = false
        state.observers[key] = nil
        state.observer_count = state.observer_count - 1
      end
    end
  end

  function controller:shutdown(exit_committed)
    assert(type(exit_committed) == "boolean", "shutdown phase must be explicit")
    if state.stopped then
      return state.shutdown_result
    end
    state.stopped = true
    state.cache_ticket = nil
    state.queued_identity = nil
    state.observed_version = ""
    clear_sequence_timer()
    state.observers = {}
    state.observer_count = 0
    state.generation = state.generation + 1
    local slot = state.active
    state.active = nil
    if not slot or not slot.handle then
      return true
    end
    pcall(slot.handle.cancel, slot.handle, "shutdown")
    if not exit_committed then
      return true
    end
    local ok, drained = pcall(slot.handle.shutdown_drain, slot.handle, 2000)
    state.shutdown_result = ok and drained == true
    return state.shutdown_result
  end

  function controller:debug_state()
    return {
      phase = state.phase,
      generation = state.generation,
      command_index = state.command_index,
      sequence_started_at = state.sequence_started_at,
      has_identity = state.identity ~= nil,
      has_report = state.report ~= nil,
      has_parser = state.parser ~= nil,
      has_active = state.active ~= nil,
      has_timer = state.sequence_timer ~= nil,
      observer_count = state.observer_count,
      queued = state.queued_identity ~= nil,
      stopped = state.stopped,
      cancelling = state.cancelling ~= nil,
    }
  end

  return controller
end

function M.commands()
  return vim.deepcopy(COMMANDS)
end

M.new = new
M._test = {
  new = new,
  new_idle_snapshot = idle_snapshot,
  new_parser = new_parser,
  parse_results = parse_results,
}

return M
