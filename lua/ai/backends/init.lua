local bit = require("bit")
local opencode_cache = require("ai.backends.opencode_cache")

local M = {}

-- Pin bundled helpers to this loaded module, not an unrelated installed config
-- or a later runtimepath entry. Capture the absolute root before cwd changes.
local module_file = debug.getinfo(1, "S").source:match("^@(.+)$")
local runtime_root = module_file and vim.fn.fnamemodify(module_file, ":p:h:h:h:h")

-- One eligibility policy for both picker presentation and native launches.
function M.is_available(health)
  return type(health) == "table"
    and health.installed == true
    and type(health.version) == "string"
    and health.version ~= ""
    and #health.version <= 128
    and vim.fn.strtrans(health.version) == health.version
    and health.error == ""
    and ({ authenticated = true, unknown = true, unsupported = true })[health.auth] == true
end

local BACKEND_NAMES = { "codex", "claude", "opencode" }
local C0_PATTERN = "[%z\1-\31\127]"
local C1_PATTERN = "\194[\128-\159]"
local GROUP_OR_OTHER_WRITE_BITS = 18
local MAX_DIAGNOSTIC_BYTES = 256
local MAX_HELP_BYTES = 65536
local MAX_AUTH_BYTES = 65536
local MAX_PROFILE_REPORT_BYTES = 65536
local MAX_COMPATIBILITY_REPORT_BYTES = 1024 * 1024
local OPENCODE_PROBE_LOCK = "0a009c556ac8352fed53ef8323a3a97270935d30.lock"
local OPENCODE_PROBE_DB_SHA256 = "40cf07c52bfaa52b334ef341456f970787f6dc701ffe18ad3c572cb5056dbd70"
local OPENCODE_PROBE_LOG_SHA256 = "5f83512e2594b9182bbf4b33632ca0b711b22b1555919e93127d28746ec2412f"
local OPENCODE_PROBE_SHM_SHA256 = "a2410912adcf2ec5a17f767f110bf3ae6539c697a0a45453c7bb6f832d0245d4"
local OPENCODE_PROBE_WAL_SHA256 = "acbe27717b5ac59975ae57011fefbcdcd0042f80286466cf318e405c9f5e7005"
local OPENCODE_PROBE_MIGRATION_TIMESTAMPS = {
  245568,
  245616,
  245672,
  245718,
  245756,
  245792,
  245841,
  245895,
  245948,
  245995,
  246040,
  246098,
  246158,
  246207,
  246249,
  246290,
  246339,
  246381,
  246427,
  246466,
  246510,
  246550,
  246586,
  246628,
  246668,
  246715,
  246756,
  246796,
  246828,
  246876,
  246919,
  246965,
  247003,
  247053,
  247088,
  247135,
  247181,
  247227,
}
local OPENCODE_PROBE_PROJECT_TIMESTAMPS = { 255459, 255465 }
local OPENCODE_PROBE_FORBIDDEN_ARTIFACTS = {
  "node_modules",
  "package.json",
  "package-lock.json",
  "bun.lock",
  "installing configuration dependenc",
  "downloading plugin",
  "loading plugin",
  "/plugins/",
  "checking for update",
  "downloading lsp",
  "lsp-download",
  "/lsp/",
  "network request",
  "network setup",
  "http://",
  "https://",
  ".opencode",
  "/tmp/opencode/",
}
local AUTH_ARGUMENTS = {
  codex = { "login", "status" },
  claude = { "auth", "status", "--json" },
}

local function has_control(value)
  return type(value) ~= "string" or value:find(C0_PATTERN) ~= nil or value:find(C1_PATTERN) ~= nil
end

local function bound_utf8(value, limit)
  if #value <= limit then
    return value
  end
  local bounded = value:sub(1, limit)
  while #bounded > 0 and not pcall(vim.str_utfindex, bounded) do
    bounded = bounded:sub(1, -2)
  end
  return bounded
end

local function clean_text(value, limit)
  local text = type(value) == "string" and value or ""
  text = text:gsub(C1_PATTERN, " "):gsub(C0_PATTERN, " ")
  text = text:gsub("%s+", " "):match("^%s*(.-)%s*$")
  return bound_utf8(text, limit)
end

local function diagnostic(result)
  if type(result) ~= "table" then
    return "probe returned an invalid result"
  end
  local detail = clean_text(result.stderr, MAX_DIAGNOSTIC_BYTES)
  if detail == "" then
    detail = clean_text(result.stdout, MAX_DIAGNOSTIC_BYTES)
  end
  if detail == "" then
    detail = string.format("probe exited with code %s", tostring(result.code))
  end
  return detail
end

local function auth_arguments(name)
  local arguments = AUTH_ARGUMENTS[name]
  return arguments and vim.deepcopy(arguments) or nil
end

local function auth_output(value)
  local text = type(value) == "string" and value:sub(1, MAX_AUTH_BYTES) or ""
  text = text:gsub("\27%[[0-?]*[ -/]*[@-~]", "")
  text = text:gsub(C1_PATTERN, " ")
  text = text:gsub("[%z\1-\9\11\12\14-\31\127]", " ")
  return text
end

local function auth_lines(value)
  local lines = {}
  for line in (auth_output(value):gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line:match("^%s*(.-)%s*$")
  end
  return lines
end

local function parse_codex_auth(result)
  local positive_lines = {
    ["logged in using chatgpt"] = true,
    ["logged in using an api key"] = true,
    ["logged in using workload identity"] = true,
    ["logged in using access token"] = true,
    ["logged in using personal access token"] = true,
    ["logged in using amazon bedrock api key"] = true,
    ["logged in using agent identity"] = true,
  }
  -- Codex reports successful login on stderr. Inspect complete known status
  -- lines from either stream, with explicit logout taking precedence.
  local lines = vim.list_extend(auth_lines(result.stdout), auth_lines(result.stderr))
  for _, line in ipairs(lines) do
    local lower = line:lower()
    if lower:find("not logged in", 1, true) == 1 then
      return "unauthenticated"
    end
  end
  for _, line in ipairs(lines) do
    local lower = line:lower()
    if positive_lines[lower] or lower:match("^logged in using an api key %- .+$") then
      return "authenticated"
    end
  end
  return "unknown"
end

local function parse_claude_auth(result)
  local ok, decoded = pcall(vim.json.decode, auth_output(result.stdout))
  if not ok or type(decoded) ~= "table" or type(decoded.loggedIn) ~= "boolean" then
    return "unknown"
  end
  return decoded.loggedIn and "authenticated" or "unauthenticated"
end

local AUTH_PARSERS = {
  codex = parse_codex_auth,
  claude = parse_claude_auth,
}

local function parse_auth(name, result)
  local parser = AUTH_PARSERS[name]
  return parser and parser(result) or "unknown"
end

local function auth_diagnostic(name, result)
  if type(result) ~= "table" then
    return clean_text(
      string.format("authentication status unavailable: %s probe could not run", name),
      MAX_DIAGNOSTIC_BYTES
    )
  end
  if result.code ~= 0 then
    return clean_text(
      string.format(
        "authentication status unavailable: %s probe exited with code %s",
        name,
        tostring(result.code)
      ),
      MAX_DIAGNOSTIC_BYTES
    )
  end
  return clean_text(
    string.format("authentication status unavailable: unrecognized %s status", name),
    MAX_DIAGNOSTIC_BYTES
  )
end

local function canonical_path(value, label, allow_root)
  if type(value) ~= "string" or value == "" or value:sub(1, 1) ~= "/" then
    return nil, label .. " must be an absolute path"
  end
  if has_control(value) then
    return nil, label .. " contains a control character"
  end
  if vim.fs.normalize(value) ~= value or (not allow_root and value == "/") then
    return nil, label .. " must be canonical"
  end
  return value
end

local function uuid_v4(random)
  local bytes = assert(random(16))
  assert(type(bytes) == "string" and #bytes == 16, "UUID provider must return 16 bytes")
  local values = { bytes:byte(1, 16) }
  values[7] = bit.bor(bit.band(values[7], 15), 64)
  values[9] = bit.bor(bit.band(values[9], 63), 128)
  local function hex(first, last)
    local output = {}
    for index = first, last do
      output[#output + 1] = string.format("%02x", values[index])
    end
    return table.concat(output)
  end
  return table.concat({
    hex(1, 4),
    hex(5, 6),
    hex(7, 8),
    hex(9, 10),
    hex(11, 16),
  }, "-")
end

local function private_directory(path, lstat, getuid)
  local ok, stat = pcall(lstat, path)
  return ok
    and type(stat) == "table"
    and stat.type == "directory"
    and stat.uid == getuid()
    and type(stat.mode) == "number"
    and bit.band(stat.mode, 511) == 448
end

local function bounded_system(argv, options, limits, system)
  local function failed(stdout_overflow, stderr_overflow, system_error)
    return {
      code = 126,
      signal = 0,
      stdout = "",
      stderr = "",
      stdout_overflow = stdout_overflow == true,
      stderr_overflow = stderr_overflow == true,
      system_error = system_error == true,
    }
  end

  if
    type(argv) ~= "table"
    or not vim.islist(argv)
    or type(options) ~= "table"
    or type(limits) ~= "table"
    or type(limits.stdout) ~= "number"
    or limits.stdout < 0
    or limits.stdout ~= math.floor(limits.stdout)
    or type(limits.stderr) ~= "number"
    or limits.stderr < 0
    or limits.stderr ~= math.floor(limits.stderr)
    or (system ~= nil and type(system) ~= "function")
  then
    return failed(false, false, true)
  end

  local stdout_chunks = {}
  local stderr_chunks = {}
  local stdout_length = 0
  local stderr_length = 0
  local stdout_overflow = false
  local stderr_overflow = false
  local system_error = false
  local process
  local stop_requested = false
  local kill_attempted = false

  local function kill_process()
    if kill_attempted or not process then
      return
    end
    kill_attempted = true
    local kill_ok = pcall(process.kill, process, "sigkill")
    if not kill_ok then
      system_error = true
    end
  end

  local function stop_process()
    stop_requested = true
    kill_process()
  end

  local function capture(stream)
    local chunks = stream == "stdout" and stdout_chunks or stderr_chunks
    local limit = limits[stream]
    return function(err, data)
      local callback_ok = pcall(function()
        if err ~= nil or (data ~= nil and type(data) ~= "string") then
          system_error = true
          stop_process()
          return
        end
        if data == nil or stdout_overflow or stderr_overflow or system_error or #data == 0 then
          return
        end
        local length = stream == "stdout" and stdout_length or stderr_length
        local remaining = limit - length
        if #data > remaining then
          if remaining > 0 then
            chunks[#chunks + 1] = data:sub(1, remaining)
          end
          if stream == "stdout" then
            stdout_length = limit
            stdout_overflow = true
          else
            stderr_length = limit
            stderr_overflow = true
          end
          stop_process()
          return
        end
        chunks[#chunks + 1] = data
        if stream == "stdout" then
          stdout_length = stdout_length + #data
        else
          stderr_length = stderr_length + #data
        end
      end)
      if not callback_ok then
        system_error = true
        stop_process()
      end
    end
  end

  local options_ok, system_options = pcall(vim.deepcopy, options)
  if not options_ok or type(system_options) ~= "table" then
    return failed(false, false, true)
  end
  system_options.stdout = capture("stdout")
  system_options.stderr = capture("stderr")
  local spawn_ok, spawned = pcall(system or vim.system, argv, system_options)
  if not spawn_ok or type(spawned) ~= "table" then
    return failed(stdout_overflow, stderr_overflow, true)
  end
  process = spawned
  if type(process.kill) ~= "function" or type(process.wait) ~= "function" then
    return failed(stdout_overflow, stderr_overflow, true)
  end
  if stop_requested then
    kill_process()
  end
  local wait_ok, completed = pcall(process.wait, process)
  if
    not wait_ok
    or type(completed) ~= "table"
    or type(completed.code) ~= "number"
    or type(completed.signal) ~= "number"
  then
    system_error = true
    stop_process()
  end
  if stdout_overflow or stderr_overflow or system_error then
    return failed(stdout_overflow, stderr_overflow, system_error)
  end
  return {
    code = completed.code,
    signal = completed.signal,
    stdout = table.concat(stdout_chunks),
    stderr = table.concat(stderr_chunks),
    stdout_overflow = false,
    stderr_overflow = false,
    system_error = false,
  }
end

local function bounded_system_async(argv, options, limits, on_complete, overrides)
  local async = type(overrides) == "table" and overrides or {}
  local valid_cancel = {
    close = true,
    ["backend-switch"] = true,
    shutdown = true,
    ["executable-drift"] = true,
    timeout = true,
    cancellation = true,
  }
  local system = async.system or vim.system
  local schedule = async.schedule or vim.schedule
  local schedule_valid = type(schedule) == "function"
  if not schedule_valid then
    schedule = vim.schedule
  end
  local stdout_chunks = {}
  local stderr_chunks = {}
  local lengths = { stdout = 0, stderr = 0 }
  local overflow = { stdout = false, stderr = false }
  local process
  local process_started = false
  local process_exited = false
  local delivered = false
  local final_result
  local stop_requested = false
  local kill_attempted = false
  local system_error = type(overrides) ~= "nil" and type(overrides) ~= "table"
  local cancellation
  local boundary_cause
  local completion_claimed = false
  local scheduling = false
  local reentrant_completion = false
  local handle = {}

  local function record_boundary(category)
    if boundary_cause == nil then
      boundary_cause = category
    end
  end

  local function failed_result()
    return {
      code = 126,
      signal = 0,
      stdout = "",
      stderr = "",
      stdout_overflow = overflow.stdout,
      stderr_overflow = overflow.stderr,
      system_error = system_error,
      cancellation = cancellation,
      process_started = process_started,
      process_exited = process_exited,
    }
  end

  local function kill_once()
    stop_requested = true
    if kill_attempted or process_exited or not process then
      return
    end
    kill_attempted = true
    local ok = pcall(process.kill, process, "sigkill")
    if not ok then
      system_error = true
      record_boundary("probe-failure")
    end
  end

  local function capture(stream)
    local chunks = stream == "stdout" and stdout_chunks or stderr_chunks
    return function(err, data)
      local ok = pcall(function()
        if err ~= nil or (data ~= nil and type(data) ~= "string") then
          system_error = true
          record_boundary("probe-failure")
          kill_once()
          return
        end
        if data == nil or data == "" or delivered or overflow.stdout or overflow.stderr then
          return
        end
        local remaining = limits[stream] - lengths[stream]
        if #data > remaining then
          if remaining > 0 then
            chunks[#chunks + 1] = data:sub(1, remaining)
          end
          lengths[stream] = limits[stream]
          overflow[stream] = true
          record_boundary("output-overflow")
          kill_once()
          return
        end
        chunks[#chunks + 1] = data
        lengths[stream] = lengths[stream] + #data
      end)
      if not ok then
        system_error = true
        record_boundary("probe-failure")
        kill_once()
      end
    end
  end

  local function complete_once()
    if completion_claimed then
      return
    end
    if scheduling then
      reentrant_completion = true
      return
    end
    completion_claimed = true
    pcall(on_complete, final_result, boundary_cause)
  end

  local function deliver(completed)
    if delivered then
      return final_result
    end
    delivered = true
    local result
    if
      system_error
      or overflow.stdout
      or overflow.stderr
      or type(completed) ~= "table"
      or type(completed.code) ~= "number"
      or type(completed.signal) ~= "number"
    then
      result = failed_result()
    else
      result = {
        code = completed.code,
        signal = completed.signal,
        stdout = table.concat(stdout_chunks),
        stderr = table.concat(stderr_chunks),
        stdout_overflow = false,
        stderr_overflow = false,
        system_error = false,
        cancellation = cancellation,
        process_started = process_started,
        process_exited = process_exited,
      }
    end
    stdout_chunks = {}
    stderr_chunks = {}
    final_result = result
    scheduling = true
    local schedule_ok = pcall(schedule, complete_once)
    scheduling = false
    if not schedule_ok then
      system_error = true
      record_boundary("probe-failure")
      final_result = failed_result()
      complete_once()
    elseif reentrant_completion then
      complete_once()
    end
    return final_result
  end

  local function exited(completed)
    if delivered then
      return
    end
    process_exited = type(completed) == "table"
      and type(completed.code) == "number"
      and type(completed.signal) == "number"
    if not process_exited then
      record_boundary("probe-failure")
    elseif completed.code == 124 then
      record_boundary("timeout")
    elseif completed.signal ~= 0 then
      record_boundary("probe-failure")
    end
    deliver(completed)
  end

  function handle:cancel(reason)
    cancellation = valid_cancel[reason] and reason or "cancellation"
    record_boundary(cancellation == "timeout" and "timeout" or "cancellation")
    kill_once()
  end

  function handle:shutdown_drain(timeout_ms)
    assert(timeout_ms == 2000, "OpenCode shutdown drain must be exactly 2000 ms")
    if process_exited then
      return true, final_result
    end
    if not process or type(process.wait) ~= "function" then
      return false
    end
    kill_once()
    local ok, completed = pcall(process.wait, process, timeout_ms)
    if
      not ok
      or type(completed) ~= "table"
      or type(completed.code) ~= "number"
      or type(completed.signal) ~= "number"
    then
      return false
    end
    process_exited = true
    local result = deliver(completed)
    return true, result
  end

  local options_ok, system_options = pcall(vim.deepcopy, options)
  if
    type(argv) ~= "table"
    or not vim.islist(argv)
    or not options_ok
    or type(system_options) ~= "table"
    or type(limits) ~= "table"
    or type(limits.stdout) ~= "number"
    or limits.stdout < 0
    or limits.stdout ~= math.floor(limits.stdout)
    or type(limits.stderr) ~= "number"
    or limits.stderr < 0
    or limits.stderr ~= math.floor(limits.stderr)
    or type(on_complete) ~= "function"
    or type(system) ~= "function"
    or not schedule_valid
  then
    system_error = true
    record_boundary("probe-failure")
    deliver(nil)
    return handle
  end

  system_options.stdout = capture("stdout")
  system_options.stderr = capture("stderr")
  local spawn_ok, spawned = pcall(system, argv, system_options, exited)
  if spawn_ok and type(spawned) == "table" then
    process = spawned
    process_started = true
  end
  if not spawn_ok or type(spawned) ~= "table" or type(spawned.kill) ~= "function" then
    system_error = true
    record_boundary("probe-failure")
    deliver(nil)
    return handle
  end
  if stop_requested then
    kill_once()
  end
  return handle
end

local function valid_probe_result(result)
  return type(result) == "table"
    and type(result.code) == "number"
    and type(result.signal) == "number"
    and result.signal == 0
    and type(result.stdout) == "string"
    and type(result.stderr) == "string"
end

local function prepare_read_only_probe(executable, arguments, probe, timeout_ms)
  local tools = require("ai.tools")
  probe = probe or {}
  local resolve = probe.resolve or tools.resolve
  local revalidate = probe.revalidate or tools.revalidate
  local environ = probe.environ or vim.fn.environ
  local lstat = probe.lstat or vim.uv.fs_lstat
  local getuid = probe.getuid or vim.uv.getuid

  local function failed(code, message)
    return nil,
      {
        code = code,
        signal = 0,
        stdout = "",
        stderr = message,
      }
  end

  if
    type(probe) ~= "table"
    or type(arguments) ~= "table"
    or not vim.islist(arguments)
    or (timeout_ms ~= 2000 and timeout_ms ~= 5000)
  then
    return failed(126, "probe invocation is invalid")
  end
  for _, argument in ipairs(arguments) do
    if type(argument) ~= "string" or has_control(argument) then
      return failed(126, "probe argument is invalid")
    end
  end

  local executable_check_ok, executable_ok, executable_error = pcall(revalidate, executable)
  if not executable_check_ok or not executable_ok then
    return failed(126, executable_check_ok and executable_error or executable_ok)
  end

  local bwrap, resolve_error = resolve("bwrap")
  if not bwrap then
    return failed(127, resolve_error)
  end
  local bwrap_check_ok, bwrap_ok, bwrap_error = pcall(revalidate, bwrap)
  if not bwrap_check_ok or not bwrap_ok then
    return failed(126, bwrap_check_ok and bwrap_error or bwrap_ok)
  end

  local argv = {
    bwrap,
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
  }
  if probe.working_directory ~= nil then
    local working_directory, directory_error =
      canonical_path(probe.working_directory, "probe working directory", false)
    if not working_directory then
      return failed(126, directory_error)
    end
    argv[#argv + 1] = "--dir"
    argv[#argv + 1] = working_directory
  end
  local read_only_mounts = {}
  if probe.read_only_mounts ~= nil then
    if type(probe.read_only_mounts) ~= "table" or not vim.islist(probe.read_only_mounts) then
      return failed(126, "probe mounts are invalid")
    end
    for _, mount in ipairs(probe.read_only_mounts) do
      if type(mount) ~= "table" then
        return failed(126, "probe mount is invalid")
      end
      local source, source_error = canonical_path(mount.source, "probe mount source", false)
      local destination, destination_error =
        canonical_path(mount.destination, "probe mount destination", false)
      if not source or not destination then
        return failed(126, source_error or destination_error)
      end
      read_only_mounts[#read_only_mounts + 1] = { source = source, destination = destination }
    end
  end
  local writable_mounts = {}
  if probe.writable_mounts ~= nil then
    if
      type(probe.writable_mounts) ~= "table"
      or not vim.islist(probe.writable_mounts)
      or #probe.writable_mounts ~= 3
    then
      return failed(126, "probe writable mounts are invalid")
    end
    local allowed_destinations = {
      ["/tmp/nvim-ai-probe/xdg-data"] = true,
      ["/tmp/nvim-ai-probe/xdg-cache"] = true,
      ["/tmp/nvim-ai-probe/xdg-state"] = true,
    }
    local seen_sources = {}
    local seen_destinations = {}
    for _, mount in ipairs(probe.writable_mounts) do
      if type(mount) ~= "table" then
        return failed(126, "probe writable mount is invalid")
      end
      local source, source_error = canonical_path(mount.source, "probe writable source", false)
      local destination, destination_error =
        canonical_path(mount.destination, "probe writable destination", false)
      if
        not source
        or not destination
        or not allowed_destinations[destination]
        or seen_sources[source]
        or seen_destinations[destination]
        or not private_directory(source, lstat, getuid)
        or not private_directory(vim.fs.dirname(source), lstat, getuid)
      then
        return failed(126, source_error or destination_error or "probe writable mount is invalid")
      end
      seen_sources[source] = true
      seen_destinations[destination] = true
      writable_mounts[#writable_mounts + 1] = { source = source, destination = destination }
    end
  end
  local seen_destinations = {}
  for _, mounts in ipairs({ read_only_mounts, writable_mounts }) do
    for _, mount in ipairs(mounts) do
      if seen_destinations[mount.destination] then
        return failed(126, "probe mount is duplicated")
      end
      seen_destinations[mount.destination] = true
      vim.list_extend(argv, { "--dir", mount.destination })
    end
  end
  for _, mount in ipairs(read_only_mounts) do
    vim.list_extend(argv, { "--ro-bind", mount.source, mount.destination })
  end
  for _, mount in ipairs(writable_mounts) do
    vim.list_extend(argv, { "--bind", mount.source, mount.destination })
  end
  -- The private /tmp mask must not hide a validated executable installed there
  -- (including the provider-free lifecycle fixture). Restore only that file.
  if executable:sub(1, 5) == "/tmp/" then
    vim.list_extend(argv, { "--ro-bind", executable, executable })
  end
  if probe.working_directory ~= nil then
    vim.list_extend(argv, { "--chdir", probe.working_directory })
  end
  argv[#argv + 1] = "--"
  if #writable_mounts > 0 then
    -- Set the mask in the sandbox child, never in the shared Neovim process.
    -- Isolated Python avoids shell evaluation and inherited Python startup code;
    -- the executable and its arguments remain separate, literal argv entries.
    local python, python_error = resolve("python3")
    if not python then
      return failed(127, python_error)
    end
    local check_ok, python_ok, check_error = pcall(revalidate, python)
    if not check_ok or not python_ok then
      return failed(126, check_ok and check_error or python_ok)
    end
    vim.list_extend(argv, {
      python,
      "-I",
      "-S",
      "-B",
      "-c",
      "import os,sys; os.umask(0o077); os.execv(sys.argv[1], sys.argv[1:])",
    })
  end
  argv[#argv + 1] = executable
  vim.list_extend(argv, arguments)
  local environment
  if probe.environment ~= nil then
    if type(probe.environment) ~= "table" then
      return failed(126, "probe environment is invalid")
    end
    local environment_ok
    environment_ok, environment = pcall(vim.deepcopy, probe.environment)
    if not environment_ok or type(environment) ~= "table" then
      return failed(126, "probe environment is invalid")
    end
  else
    local environment_ok
    environment_ok, environment = pcall(environ)
    if not environment_ok or type(environment) ~= "table" then
      return failed(126, "probe environment is invalid")
    end
    environment.TMUX = nil
    environment.TMUX_PANE = nil
    environment.NVIM = nil
    environment.NVIM_LISTEN_ADDRESS = nil
  end

  return {
    argv = argv,
    options = {
      text = true,
      timeout = timeout_ms,
      clear_env = true,
      env = environment,
    },
  }
end

local function read_only_probe(executable, arguments, overrides)
  local probe = overrides or {}
  local run = probe.run
    or function(argv, options)
      return bounded_system(argv, options, {
        stdout = MAX_COMPATIBILITY_REPORT_BYTES,
        stderr = MAX_HELP_BYTES,
      })
    end
  local invocation, invocation_error = prepare_read_only_probe(executable, arguments, probe, 2000)
  if not invocation then
    return invocation_error
  end

  local ok, result = pcall(function()
    return run(invocation.argv, invocation.options)
  end)
  if probe.inspect_artifacts ~= nil then
    if type(probe.inspect_artifacts) ~= "function" then
      return { code = 126, signal = 0, stdout = "", stderr = "probe artifact inspector is invalid" }
    end
    local inspection_ok, accepted = pcall(probe.inspect_artifacts, result)
    if not inspection_ok or accepted ~= true then
      return {
        code = 125,
        signal = 0,
        stdout = "",
        stderr = "managed probe artifact validation failed",
      }
    end
  end
  if not ok or not valid_probe_result(result) then
    return { code = 126, signal = 0, stdout = "", stderr = "probe execution failed" }
  end
  if result.stdout_overflow or result.stderr_overflow then
    return {
      code = 126,
      signal = 0,
      stdout = "",
      stderr = "probe output exceeded configured limit",
    }
  end
  if result.system_error then
    return { code = 126, signal = 0, stdout = "", stderr = "probe execution failed" }
  end
  return result
end

local function executable_metadata(stat)
  if
    type(stat) ~= "table"
    or stat.type ~= "file"
    or type(stat.dev) ~= "number"
    or type(stat.ino) ~= "number"
    or type(stat.mode) ~= "number"
    or type(stat.uid) ~= "number"
    or type(stat.size) ~= "number"
    or type(stat.mtime) ~= "table"
    or type(stat.mtime.sec) ~= "number"
    or type(stat.mtime.nsec) ~= "number"
    or type(stat.ctime) ~= "table"
    or type(stat.ctime.sec) ~= "number"
    or type(stat.ctime.nsec) ~= "number"
  then
    return nil
  end
  return table.concat({
    tostring(stat.dev),
    tostring(stat.ino),
    tostring(stat.mode),
    tostring(stat.uid),
    tostring(stat.size),
    string.format("%d:%d", stat.mtime.sec, stat.mtime.nsec),
    string.format("%d:%d", stat.ctime.sec, stat.ctime.nsec),
  }, ":")
end

local function same_probe_file(left, right)
  return type(left) == "table"
    and type(right) == "table"
    and left.type == right.type
    and left.dev == right.dev
    and left.ino == right.ino
    and left.mode == right.mode
    and left.uid == right.uid
    and left.size == right.size
    and type(left.mtime) == "table"
    and type(right.mtime) == "table"
    and left.mtime.sec == right.mtime.sec
    and left.mtime.nsec == right.mtime.nsec
    and type(left.ctime) == "table"
    and type(right.ctime) == "table"
    and left.ctime.sec == right.ctime.sec
    and left.ctime.nsec == right.ctime.nsec
end

local function probe_artifact_filesystem(overrides)
  local filesystem = overrides or {}
  return {
    close = filesystem.close or vim.uv.fs_close,
    fstat = filesystem.fstat or vim.uv.fs_fstat,
    getuid = filesystem.getuid or vim.uv.getuid,
    hostname = filesystem.hostname or vim.uv.os_gethostname,
    lstat = filesystem.lstat or vim.uv.fs_lstat,
    open = filesystem.open or vim.uv.fs_open,
    read = filesystem.read or vim.uv.fs_read,
    scandir = filesystem.scandir or vim.uv.fs_scandir,
    scandir_next = filesystem.scandir_next or vim.uv.fs_scandir_next,
    sha256 = filesystem.sha256 or vim.fn.sha256,
    time = filesystem.time or os.time,
  }
end

local function read_probe_file(path, maximum, filesystem)
  local before = filesystem.lstat(path)
  if
    type(before) ~= "table"
    or before.type ~= "file"
    or before.uid ~= filesystem.getuid()
    or bit.band(before.mode, 511) ~= 384
    or type(before.size) ~= "number"
    or before.size < 0
    or before.size > maximum
  then
    return nil
  end
  local descriptor = filesystem.open(path, "r", 0)
  if not descriptor then
    return nil
  end
  local opened = filesystem.fstat(descriptor)
  local bytes = before.size == 0 and "" or filesystem.read(descriptor, before.size, 0)
  local extra = filesystem.read(descriptor, 1, before.size)
  local after = filesystem.fstat(descriptor)
  local close_ok, closed = pcall(filesystem.close, descriptor)
  local final = filesystem.lstat(path)
  if
    not same_probe_file(before, opened)
    or type(bytes) ~= "string"
    or #bytes ~= before.size
    or (extra ~= nil and extra ~= "")
    or not same_probe_file(opened, after)
    or not close_ok
    or closed == nil
    or not same_probe_file(after, final)
  then
    return nil
  end
  return bytes
end

local function write_probe_file(path, bytes)
  local descriptor = vim.uv.fs_open(path, "wx", 384)
  if not descriptor then
    return nil
  end
  local offset = 0
  while offset < #bytes do
    local written = vim.uv.fs_write(descriptor, bytes:sub(offset + 1), offset)
    if type(written) ~= "number" or written <= 0 or written > #bytes - offset then
      break
    end
    offset = offset + written
  end
  local synced = offset == #bytes and vim.uv.fs_fsync(descriptor)
  local stat = vim.uv.fs_fstat(descriptor)
  local close_ok, closed = pcall(vim.uv.fs_close, descriptor)
  return offset == #bytes
    and synced ~= nil
    and type(stat) == "table"
    and stat.type == "file"
    and stat.uid == vim.uv.getuid()
    and bit.band(stat.mode, 511) == 384
    and stat.size == #bytes
    and close_ok
    and closed ~= nil
end

local function directory_entries(path, filesystem)
  local before = filesystem.lstat(path)
  if
    type(before) ~= "table"
    or before.type ~= "directory"
    or before.uid ~= filesystem.getuid()
    or type(before.mode) ~= "number"
    or bit.band(before.mode, 511) ~= 448
  then
    return nil
  end
  local descriptor = filesystem.open(path, "r", 0)
  if not descriptor then
    return nil
  end
  local opened = filesystem.fstat(descriptor)
  local descriptor_path = "/proc/self/fd/" .. tostring(descriptor)
  local request = filesystem.scandir(descriptor_path)
  if not request then
    pcall(filesystem.close, descriptor)
    return nil
  end
  local entries = {}
  local invalid = false
  while true do
    local name = filesystem.scandir_next(request)
    if name == nil then
      break
    end
    if
      name == ""
      or name == "."
      or name == ".."
      or name:find("/", 1, true)
      or has_control(name)
    then
      invalid = true
      break
    end
    entries[#entries + 1] = name
    if #entries > 32 then
      invalid = true
      break
    end
  end
  local after = filesystem.fstat(descriptor)
  local close_ok, closed = pcall(filesystem.close, descriptor)
  local final = filesystem.lstat(path)
  if
    invalid
    or not same_probe_file(before, opened)
    or not same_probe_file(opened, after)
    or not close_ok
    or closed == nil
    or not same_probe_file(after, final)
  then
    return nil
  end
  table.sort(entries)
  return entries
end

local function exact_probe_directory(path, expected, filesystem)
  local entries = directory_entries(path, filesystem)
  return entries ~= nil and vim.deep_equal(entries, expected)
end

local function validate_probe_inputs(tree, filesystem)
  filesystem = filesystem or probe_artifact_filesystem()
  local managed = require("ai.backends.opencode_managed")
  if
    not exact_probe_directory(tree.home, {}, filesystem)
    or not exact_probe_directory(tree.config, { "opencode" }, filesystem)
    or not exact_probe_directory(tree.config_opencode, { ".gitignore" }, filesystem)
  then
    return nil
  end
  local bootstrap = read_probe_file(tree.bootstrap, 64, filesystem)
  return bootstrap == managed.bootstrap_gitignore()
    and filesystem.sha256(bootstrap) == managed.bootstrap_gitignore_sha256()
end

local function cleanup_owned_probe_tree(root, remove, lstat, getuid)
  local normalize_ok, normalized = false, nil
  if type(root) == "string" then
    normalize_ok, normalized = pcall(vim.fs.normalize, root)
  end
  if
    type(root) ~= "string"
    or root == ""
    or root:sub(1, 1) ~= "/"
    or root == "/"
    or has_control(root)
    or not normalize_ok
    or normalized ~= root
    or type(remove) ~= "function"
    or type(lstat) ~= "function"
    or type(getuid) ~= "function"
  then
    return false
  end
  local before_ok, before = pcall(lstat, root)
  local uid_ok, uid = pcall(getuid)
  if
    not before_ok
    or not uid_ok
    or type(uid) ~= "number"
    or type(before) ~= "table"
    or before.type ~= "directory"
    or type(before.uid) ~= "number"
    or before.uid ~= uid
    or type(before.mode) ~= "number"
    or bit.band(before.mode, 511) ~= 448
  then
    return false
  end
  local remove_ok, status = pcall(remove, root, "rf")
  if not remove_ok or status ~= 0 then
    return false
  end
  local lstat_ok, stat, _, code = pcall(lstat, root)
  return lstat_ok and stat == nil and code == "ENOENT"
end

local function create_opencode_probe_tree()
  local root = vim.fn.tempname()
  local tree = {
    root = root,
    home = root .. "/home",
    config = root .. "/xdg-config",
    config_opencode = root .. "/xdg-config/opencode",
    bootstrap = root .. "/xdg-config/opencode/.gitignore",
    data = root .. "/xdg-data",
    cache = root .. "/xdg-cache",
    state = root .. "/xdg-state",
  }
  local created = false
  local ok = pcall(function()
    assert(vim.fn.mkdir(root, "p", 448) == 1)
    created = true
    for _, path in ipairs({
      tree.home,
      tree.config,
      tree.config_opencode,
      tree.data,
      tree.cache,
      tree.state,
    }) do
      assert(vim.fn.mkdir(path, "", 448) == 1)
    end
    for _, path in ipairs({
      tree.root,
      tree.home,
      tree.config,
      tree.config_opencode,
      tree.data,
      tree.cache,
      tree.state,
    }) do
      assert(vim.uv.fs_chmod(path, 448))
      assert(private_directory(path, vim.uv.fs_lstat, vim.uv.getuid))
    end
    local managed = require("ai.backends.opencode_managed")
    assert(write_probe_file(tree.bootstrap, managed.bootstrap_gitignore()))
    assert(validate_probe_inputs(tree))
  end)
  if not ok then
    if
      created
      and not cleanup_owned_probe_tree(root, vim.fn.delete, vim.uv.fs_lstat, vim.uv.getuid)
    then
      return nil, "cleanup-failure"
    end
    return nil, "probe-failure"
  end
  return tree
end

local function forbidden_probe_artifact(bytes)
  for printable in bytes:gmatch("[ -~]+") do
    if #printable >= 8 then
      local lower = printable:lower()
      for _, evidence in ipairs(OPENCODE_PROBE_FORBIDDEN_ARTIFACTS) do
        if lower:find(evidence, 1, true) then
          return true
        end
      end
    end
  end
  return false
end

local function valid_probe_uuid(value)
  if type(value) ~= "string" or value:find("[^0-9a-f-]") then
    return false
  end
  local first, second, third, fourth, fifth =
    value:match("^([0-9a-f]+)%-([0-9a-f]+)%-([0-9a-f]+)%-([0-9a-f]+)%-([0-9a-f]+)$")
  return first ~= nil
    and #first == 8
    and #second == 4
    and #third == 4
    and third:sub(1, 1) == "4"
    and #fourth == 4
    and fourth:sub(1, 1):match("[89ab]") ~= nil
    and #fifth == 12
end

local function valid_probe_lock_metadata(bytes, filesystem)
  local token, pid, hostname, created_at = bytes:match(
    '^%{\n  "token": "([^"]+)",\n  "pid": ([0-9]+),\n  "hostname": "([^"]+)",\n  "createdAt": "([^"]+)"\n%}$'
  )
  local current_hostname = filesystem.hostname()
  return valid_probe_uuid(token)
    and pid == "2"
    and type(current_hostname) == "string"
    and hostname == current_hostname
    and #hostname <= 253
    and hostname:match("^[%w][%w.-]*$") ~= nil
    and #created_at == 24
    and created_at:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d%d%dZ$") ~= nil
end

local function inspect_opencode_probe_lock(tree, overrides)
  local filesystem = probe_artifact_filesystem(overrides)
  local state = tree.state .. "/opencode"
  local state_entries = directory_entries(state, filesystem)
  if not state_entries then
    return nil, "probe-lock-tree"
  end
  if #state_entries == 0 then
    return { disposition = "quiescent", fingerprint = "absent" }
  end
  if not vim.deep_equal(state_entries, { "locks" }) then
    return nil, "probe-lock-tree"
  end

  local lock_root = state .. "/locks"
  local root_entries = directory_entries(lock_root, filesystem)
  if not root_entries then
    return nil, "probe-lock-tree"
  end
  if #root_entries == 0 then
    return { disposition = "quiescent", fingerprint = "empty" }
  end
  if not vim.deep_equal(root_entries, { OPENCODE_PROBE_LOCK }) then
    return nil, "probe-lock-tree"
  end

  local lock = lock_root .. "/" .. OPENCODE_PROBE_LOCK
  local lock_entries = directory_entries(lock, filesystem)
  if not lock_entries then
    return nil, "probe-lock-tree"
  end
  local allowed = {
    heartbeat = true,
    ["meta.json"] = true,
  }
  for _, name in ipairs(lock_entries) do
    if not allowed[name] then
      return nil, "probe-lock-tree"
    end
  end

  local has_heartbeat = vim.tbl_contains(lock_entries, "heartbeat")
  local has_metadata = vim.tbl_contains(lock_entries, "meta.json")
  if has_heartbeat then
    local heartbeat = read_probe_file(lock .. "/heartbeat", 0, filesystem)
    if heartbeat ~= "" then
      return nil, "probe-heartbeat"
    end
  end
  local metadata
  if has_metadata then
    metadata = read_probe_file(lock .. "/meta.json", 512, filesystem)
    if not metadata or not valid_probe_lock_metadata(metadata, filesystem) then
      return nil, "probe-lock-metadata"
    end
  end

  if has_heartbeat and has_metadata and #lock_entries == 2 then
    local digest = filesystem.sha256(metadata)
    if type(digest) ~= "string" or #digest ~= 64 or digest:find("[^0-9a-f]") then
      return nil, "probe-lock-metadata"
    end
    return { disposition = "quiescent", fingerprint = "full:" .. digest }
  end

  local partial = #lock_entries == 0 and "empty-directory"
    or (has_heartbeat and "heartbeat" or "metadata")
  return { disposition = "transient", fingerprint = "partial:" .. partial }
end

local SQLITE_U32_MODULO = 4294967296

local function probe_u32(bytes, offset, little_endian)
  local first, second, third, fourth = bytes:byte(offset, offset + 3)
  if not fourth then
    return nil
  end
  if little_endian then
    return first + second * 256 + third * 65536 + fourth * 16777216
  end
  return first * 16777216 + second * 65536 + third * 256 + fourth
end

local function probe_u16_little_endian(bytes, offset)
  local first, second = bytes:byte(offset, offset + 1)
  return second and first + second * 256 or nil
end

local function probe_u48_big_endian(bytes, offset)
  local value = 0
  for index = offset, offset + 5 do
    local byte = bytes:byte(index)
    if not byte then
      return nil
    end
    value = value * 256 + byte
  end
  return value
end

local function probe_sqlite_checksum(bytes, offset, length, checksum0, checksum1)
  if length % 8 ~= 0 or offset < 1 or offset + length - 1 > #bytes then
    return nil
  end
  for index = offset, offset + length - 1, 8 do
    local word0 = probe_u32(bytes, index, true)
    local word1 = probe_u32(bytes, index + 4, true)
    if not word0 or not word1 then
      return nil
    end
    checksum0 = (checksum0 + word0 + checksum1) % SQLITE_U32_MODULO
    checksum1 = (checksum1 + word1 + checksum0) % SQLITE_U32_MODULO
  end
  return checksum0, checksum1
end

local function normalize_probe_bytes(bytes, ranges)
  table.sort(ranges, function(left, right)
    return left.offset < right.offset
  end)
  local chunks = {}
  local cursor = 1
  for _, range in ipairs(ranges) do
    if
      type(range.offset) ~= "number"
      or type(range.length) ~= "number"
      or range.offset < cursor
      or range.length < 1
      or range.offset + range.length - 1 > #bytes
    then
      return nil
    end
    chunks[#chunks + 1] = bytes:sub(cursor, range.offset - 1)
    chunks[#chunks + 1] = string.rep("\0", range.length)
    cursor = range.offset + range.length
  end
  chunks[#chunks + 1] = bytes:sub(cursor)
  return table.concat(chunks)
end

local function probe_digest_failure(category, digest)
  if type(digest) == "string" and #digest == 64 and not digest:find("[^0-9a-f]") then
    return category .. ":" .. digest
  end
  return category .. ":invalid"
end

local function valid_probe_utc_timestamp(value)
  if type(value) ~= "string" then
    return false
  end
  local year, month, day, hour, minute, second, millisecond =
    value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)%.(%d%d%d)Z$")
  year = tonumber(year)
  month = tonumber(month)
  day = tonumber(day)
  hour = tonumber(hour)
  minute = tonumber(minute)
  second = tonumber(second)
  millisecond = tonumber(millisecond)
  if
    not year
    or year < 1970
    or not month
    or month < 1
    or month > 12
    or not day
    or not hour
    or hour > 23
    or not minute
    or minute > 59
    or not second
    or second > 59
    or not millisecond
    or millisecond > 999
  then
    return false
  end
  local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0) then
    days[2] = 29
  end
  return day >= 1 and day <= days[month]
end

local function valid_probe_log(bytes, filesystem)
  if bytes == "" then
    return true
  end
  if type(bytes) ~= "string" or #bytes ~= 994 then
    return false, "probe-log-size"
  end
  if forbidden_probe_artifact(bytes) then
    return false, "probe-log-forbidden-evidence"
  end

  local lines = {}
  local cursor = 1
  while cursor <= #bytes do
    local newline = bytes:find("\n", cursor, true)
    if not newline then
      return false, "probe-log-line-count"
    end
    lines[#lines + 1] = bytes:sub(cursor, newline - 1)
    cursor = newline + 1
  end
  if #lines ~= 9 then
    return false, "probe-log-line-count"
  end

  local run_identifier
  local previous_timestamp
  local normalized = {}
  for _, line in ipairs(lines) do
    local timestamp, run, suffix = line:match("^timestamp=(%S+) level=INFO run=(%S+) (.+)$")
    if not timestamp or not run or not suffix then
      return false, "probe-log-line-shape"
    end
    if not valid_probe_utc_timestamp(timestamp) then
      return false, "probe-log-timestamp-shape"
    end
    if previous_timestamp and timestamp < previous_timestamp then
      return false, "probe-log-timestamp-order"
    end
    previous_timestamp = timestamp
    if #run ~= 8 or run:find("[^0-9a-f]") then
      return false, "probe-log-run-identifier"
    end
    if run_identifier and run ~= run_identifier then
      return false, "probe-log-run-identifier"
    end
    run_identifier = run
    normalized[#normalized + 1] = "timestamp=<time> level=INFO run=<duration> " .. suffix .. "\n"
  end
  local normalized_sha256 = filesystem.sha256(table.concat(normalized))
  if normalized_sha256 ~= OPENCODE_PROBE_LOG_SHA256 then
    return false, probe_digest_failure("probe-log-normalized-digest", normalized_sha256)
  end
  return true
end

local function safe_probe_artifact_category(value)
  if type(value) == "string" and #value > 0 and #value <= 128 and not value:find("[^a-z0-9:-]") then
    return value
  end
  return "unavailable"
end

local function valid_probe_wal_timestamps(write_ahead_log, filesystem)
  local now = filesystem.time()
  if type(now) ~= "number" or now <= 0 then
    return false, "sqlite-wal-clock"
  end
  local now_milliseconds = math.floor(now * 1000)
  local lower_bound = now_milliseconds - 60000
  local upper_bound = now_milliseconds + 5000
  local previous
  local minimum
  local maximum
  for _, offset in ipairs(OPENCODE_PROBE_MIGRATION_TIMESTAMPS) do
    local value = probe_u48_big_endian(write_ahead_log, offset)
    if not value then
      return false, "sqlite-wal-migration-timestamp-structure"
    end
    if value < lower_bound or value > upper_bound then
      return false, "sqlite-wal-migration-timestamp-range"
    end
    if previous and value > previous then
      return false, "sqlite-wal-migration-timestamp-order"
    end
    previous = value
    minimum = minimum and math.min(minimum, value) or value
    maximum = maximum and math.max(maximum, value) or value
  end
  if not minimum or maximum - minimum > 1000 then
    return false, "sqlite-wal-migration-timestamp-span"
  end
  local created = probe_u48_big_endian(write_ahead_log, OPENCODE_PROBE_PROJECT_TIMESTAMPS[1])
  local updated = probe_u48_big_endian(write_ahead_log, OPENCODE_PROBE_PROJECT_TIMESTAMPS[2])
  if not created or not updated then
    return false, "sqlite-wal-project-timestamp-structure"
  end
  if updated < created then
    return false, "sqlite-wal-project-timestamp-order"
  end
  if updated - created > 5000 or created < maximum or created - maximum > 5000 then
    return false, "sqlite-wal-project-timestamp-span"
  end
  if
    created < lower_bound
    or created > upper_bound
    or updated < lower_bound
    or updated > upper_bound
  then
    return false, "sqlite-wal-project-timestamp-range"
  end
  return true
end

local function valid_probe_wal(write_ahead_log, filesystem)
  local wal_header = string.char(
    0x37,
    0x7f,
    0x06,
    0x82,
    0x00,
    0x2d,
    0xe2,
    0x18,
    0x00,
    0x00,
    0x10,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00
  )
  if #write_ahead_log ~= 259592 or write_ahead_log:sub(1, 16) ~= wal_header then
    return nil, "sqlite-wal-header"
  end
  local checksum0, checksum1 = probe_sqlite_checksum(write_ahead_log, 1, 24, 0, 0)
  if
    not checksum0
    or checksum0 ~= probe_u32(write_ahead_log, 25, false)
    or checksum1 ~= probe_u32(write_ahead_log, 29, false)
  then
    return nil, "sqlite-wal-header-checksum"
  end
  local salt = write_ahead_log:sub(17, 24)
  if salt == string.rep("\0", 8) then
    return nil, "sqlite-wal-salt"
  end
  local page_numbers = {}
  local normalized_ranges = { { offset = 17, length = 16 } }
  for frame = 0, 62 do
    local base = 33 + frame * 4120
    if write_ahead_log:sub(base + 8, base + 15) ~= salt then
      return nil, "sqlite-wal-frame-salt"
    end
    checksum0, checksum1 = probe_sqlite_checksum(write_ahead_log, base, 8, checksum0, checksum1)
    if not checksum0 then
      return nil, "sqlite-wal-frame-structure"
    end
    checksum0, checksum1 =
      probe_sqlite_checksum(write_ahead_log, base + 24, 4096, checksum0, checksum1)
    if
      not checksum0
      or checksum0 ~= probe_u32(write_ahead_log, base + 16, false)
      or checksum1 ~= probe_u32(write_ahead_log, base + 20, false)
    then
      return nil, "sqlite-wal-frame-checksum"
    end
    local page_number = probe_u32(write_ahead_log, base, false)
    if not page_number or page_number == 0 then
      return nil, "sqlite-wal-frame-page"
    end
    page_numbers[#page_numbers + 1] = page_number
    normalized_ranges[#normalized_ranges + 1] = { offset = base + 8, length = 16 }
  end
  local timestamps_ok, timestamp_error = valid_probe_wal_timestamps(write_ahead_log, filesystem)
  if not timestamps_ok then
    return nil, timestamp_error
  end
  for _, offset in ipairs(OPENCODE_PROBE_MIGRATION_TIMESTAMPS) do
    normalized_ranges[#normalized_ranges + 1] = { offset = offset, length = 6 }
  end
  for _, offset in ipairs(OPENCODE_PROBE_PROJECT_TIMESTAMPS) do
    normalized_ranges[#normalized_ranges + 1] = { offset = offset, length = 6 }
  end
  local normalized = normalize_probe_bytes(write_ahead_log, normalized_ranges)
  if not normalized then
    return nil, "sqlite-wal-normalization"
  end
  local normalized_sha256 = filesystem.sha256(normalized)
  if normalized_sha256 ~= OPENCODE_PROBE_WAL_SHA256 then
    return nil, probe_digest_failure("sqlite-wal-normalized-digest", normalized_sha256)
  end
  return {
    checksum0 = checksum0,
    checksum1 = checksum1,
    page_numbers = page_numbers,
    salt = salt,
  }
end

local function valid_probe_shm(shared_memory, wal, filesystem)
  if
    #shared_memory ~= 32768
    or shared_memory:sub(1, 48) ~= shared_memory:sub(49, 96)
    or probe_u32(shared_memory, 1, true) ~= 3007000
    or probe_u32(shared_memory, 5, true) ~= 0
    or probe_u32(shared_memory, 9, true) ~= 2
    or shared_memory:byte(13) ~= 1
    or shared_memory:byte(14) ~= 0
    or probe_u16_little_endian(shared_memory, 15) ~= 4096
    or probe_u32(shared_memory, 17, true) ~= 63
    or probe_u32(shared_memory, 21, true) ~= 61
    or probe_u32(shared_memory, 25, true) ~= wal.checksum0
    or probe_u32(shared_memory, 29, true) ~= wal.checksum1
    or shared_memory:sub(33, 40) ~= wal.salt
  then
    return false, "sqlite-shm-header"
  end
  local checksum0, checksum1 = probe_sqlite_checksum(shared_memory, 1, 40, 0, 0)
  if
    not checksum0
    or checksum0 ~= probe_u32(shared_memory, 41, true)
    or checksum1 ~= probe_u32(shared_memory, 45, true)
    or probe_u32(shared_memory, 97, true) ~= 0
    or probe_u32(shared_memory, 101, true) ~= 0
    or probe_u32(shared_memory, 105, true) ~= 63
    or probe_u32(shared_memory, 109, true) ~= 0xffffffff
    or probe_u32(shared_memory, 113, true) ~= 0xffffffff
    or probe_u32(shared_memory, 117, true) ~= 0xffffffff
    or shared_memory:sub(121, 128) ~= string.rep("\0", 8)
    or probe_u32(shared_memory, 129, true) ~= 0
    or probe_u32(shared_memory, 133, true) ~= 0
  then
    return false, "sqlite-shm-header-checksum-or-state"
  end
  for index = 1, 4062 do
    local page_number = probe_u32(shared_memory, 137 + (index - 1) * 4, true)
    local expected = index <= 63 and wal.page_numbers[index] or 0
    if page_number ~= expected then
      return false, "sqlite-shm-page-map"
    end
  end
  local normalized = normalize_probe_bytes(shared_memory, {
    { offset = 25, length = 24 },
    { offset = 73, length = 24 },
  })
  if not normalized then
    return false, "sqlite-shm-normalization"
  end
  local normalized_sha256 = filesystem.sha256(normalized)
  if normalized_sha256 ~= OPENCODE_PROBE_SHM_SHA256 then
    return false, probe_digest_failure("sqlite-shm-normalized-digest", normalized_sha256)
  end
  return true
end

local function valid_probe_sqlite_files(database, shared_memory, write_ahead_log, filesystem)
  if #database ~= 4096 then
    return false, "sqlite-database-size"
  end
  local database_sha256 = filesystem.sha256(database)
  if database_sha256 ~= OPENCODE_PROBE_DB_SHA256 then
    return false, probe_digest_failure("sqlite-database-digest", database_sha256)
  end
  if
    forbidden_probe_artifact(database)
    or forbidden_probe_artifact(shared_memory)
    or forbidden_probe_artifact(write_ahead_log)
  then
    return false, "sqlite-forbidden-evidence"
  end
  for _, marker in ipairs({
    "SQLite format 3\0",
    "20260127222353_familiar_lady_ursula",
    "20260622202450_simplify_session_input",
    "CREATE TABLE `credential`",
  }) do
    if not write_ahead_log:find(marker, 1, true) then
      return false, "sqlite-audited-marker"
    end
  end
  local wal, wal_error = valid_probe_wal(write_ahead_log, filesystem)
  if not wal then
    return false, wal_error
  end
  return valid_probe_shm(shared_memory, wal, filesystem)
end

local function inspect_opencode_probe_artifacts(tree, semantic, overrides)
  local filesystem = probe_artifact_filesystem(overrides)
  if not validate_probe_inputs(tree, filesystem) then
    return nil, "probe-input-tree"
  end
  if
    not exact_probe_directory(tree.data, { "opencode" }, filesystem)
    or not exact_probe_directory(tree.cache, { "opencode" }, filesystem)
    or not exact_probe_directory(tree.state, { "opencode" }, filesystem)
  then
    return nil, "probe-xdg-root-tree"
  end
  local data = tree.data .. "/opencode"
  local cache = tree.cache .. "/opencode"
  local state = tree.state .. "/opencode"
  local data_entries = semantic
      and { "log", "opencode.db", "opencode.db-shm", "opencode.db-wal", "repos" }
    or { "log", "repos" }
  if
    not exact_probe_directory(data, data_entries, filesystem)
    or not exact_probe_directory(data .. "/log", semantic and { "opencode.log" } or {}, filesystem)
    or not exact_probe_directory(data .. "/repos", {}, filesystem)
    or not exact_probe_directory(cache, { "bin" }, filesystem)
    or not exact_probe_directory(cache .. "/bin", {}, filesystem)
  then
    return nil, "probe-artifact-tree"
  end
  if not semantic then
    if not exact_probe_directory(state, {}, filesystem) then
      return nil, "probe-artifact-tree"
    end
    return { disposition = "quiescent", fingerprint = "nonsemantic" }
  end

  local lock_snapshot, lock_error = inspect_opencode_probe_lock(tree, overrides)
  if not lock_snapshot then
    return nil, lock_error
  end

  local log = read_probe_file(data .. "/log/opencode.log", 994, filesystem)
  local database = read_probe_file(data .. "/opencode.db", 4096, filesystem)
  local shared_memory = read_probe_file(data .. "/opencode.db-shm", 32768, filesystem)
  local write_ahead_log = read_probe_file(data .. "/opencode.db-wal", 259592, filesystem)
  local log_ok, log_error = valid_probe_log(log, filesystem)
  if not log_ok then
    return nil, log_error
  end
  if not database or not shared_memory or not write_ahead_log then
    return nil, "probe-sqlite-file-boundary"
  end
  local sqlite_ok, sqlite_error =
    valid_probe_sqlite_files(database, shared_memory, write_ahead_log, filesystem)
  if not sqlite_ok then
    return nil, sqlite_error
  end
  return lock_snapshot
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

local function settle_opencode_probe_lock(tree, initial, overrides, callback)
  local options = overrides or {}
  local now = options.now or vim.uv.now
  local defer = options.defer or vim.defer_fn
  local inspect = options.inspect_lock or inspect_opencode_probe_lock
  local started_at = now()
  local candidate = initial.disposition == "quiescent" and initial.fingerprint or nil
  local active = true
  local timer

  local function finish(accepted, category, snapshot)
    if not active then
      return
    end
    active = false
    stop_timer(timer)
    timer = nil
    callback(accepted, category, snapshot)
  end

  local function step()
    if not active then
      return
    end
    local now_ok, current = pcall(now)
    if not now_ok or type(current) ~= "number" or type(started_at) ~= "number" then
      now_ok = nil
      current = nil
      finish(nil, "probe-lock-tree")
      return
    end
    local elapsed = current - started_at
    now_ok = nil
    current = nil
    if elapsed > 1000 then
      finish(nil, "probe-lock-tree")
      return
    end
    local inspect_ok, snapshot, category = pcall(inspect, tree, options.filesystem)
    if not inspect_ok then
      inspect_ok = nil
      snapshot = nil
      category = nil
      finish(nil, "probe-lock-tree")
      return
    end
    inspect_ok = nil
    if not snapshot then
      finish(nil, category or "probe-lock-tree")
      return
    end
    if snapshot.disposition == "quiescent" then
      if candidate == snapshot.fingerprint then
        finish(true, nil, snapshot)
        return
      end
      candidate = snapshot.fingerprint
    else
      candidate = nil
    end
    if elapsed >= 1000 then
      finish(nil, "probe-lock-tree")
      return
    end
    local defer_ok, next_timer = pcall(defer, step, 50)
    if not defer_ok then
      defer_ok = nil
      next_timer = nil
      finish(nil, "probe-lock-tree")
      return
    end
    timer = next_timer
    defer_ok = nil
    next_timer = nil
  end

  timer = defer(step, 50)
  return function()
    finish(nil, "cancellation")
  end
end

local function opencode_probe_environment()
  local managed = require("ai.backends.opencode_managed")
  return {
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
  }
end

local function start_opencode_probe(identity, command, on_complete, overrides)
  local options = type(overrides) == "table" and overrides or {}
  local revalidate = options.revalidate or require("ai.tools").revalidate
  local stat = options.stat or vim.uv.fs_lstat
  local create_tree = options.create_tree or create_opencode_probe_tree
  local cleanup_tree = options.cleanup_tree or cleanup_owned_probe_tree
  local inspect_artifacts = options.inspect_artifacts or inspect_opencode_probe_artifacts
  local settle_lock = options.settle_lock or settle_opencode_probe_lock
  local schedule = options.schedule or vim.schedule
  local observe = options.observe_probe
  local delete = options.delete or vim.fn.delete
  local lstat = options.lstat or vim.uv.fs_lstat
  local getuid = options.getuid or vim.uv.getuid
  local now = options.now or vim.uv.now
  local finished = false
  local cancellation_requested = false
  local cancel_settle
  local runner
  local tree
  local owned_root
  local public = {}

  if
    type(overrides) ~= "nil" and type(overrides) ~= "table"
    or type(identity) ~= "table"
    or identity.installed ~= true
    or type(identity.executable) ~= "string"
    or canonical_path(identity.executable, "OpenCode executable", false) ~= identity.executable
    or type(identity.metadata) ~= "string"
    or identity.metadata == ""
    or has_control(identity.metadata)
    or type(command) ~= "table"
    or type(command.name) ~= "string"
    or type(command.arguments) ~= "table"
    or type(command.semantic) ~= "boolean"
    or type(on_complete) ~= "function"
    or (observe ~= nil and type(observe) ~= "function")
  then
    return nil, "probe-failure"
  end
  local expected_command
  for _, expected in ipairs(require("ai.backends.opencode_validation").commands()) do
    if expected.name == command.name then
      expected_command = expected
      break
    end
  end
  if not expected_command or not vim.deep_equal(command, expected_command) then
    return nil, "probe-failure"
  end
  local clock_ok, started_at = pcall(now)
  if not clock_ok or type(started_at) ~= "number" then
    return nil, "probe-failure"
  end

  local valid_ok, valid = pcall(revalidate, identity.executable)
  local stat_ok, current_stat = pcall(stat, identity.executable)
  local current_metadata = stat_ok and executable_metadata(current_stat) or nil
  current_stat = nil
  valid = valid == true
  if not valid_ok or not valid or not stat_ok or current_metadata ~= identity.metadata then
    return nil, "executable-drift"
  end
  local tree_ok, created_tree, create_error = pcall(create_tree)
  tree = tree_ok and created_tree or nil
  created_tree = nil
  if not tree then
    return nil,
      tree_ok and create_error == "cleanup-failure" and "cleanup-failure" or "probe-failure"
  end
  create_error = nil
  if type(tree) ~= "table" then
    return nil, "cleanup-failure"
  end
  local exact_children = {
    home = "/home",
    config = "/xdg-config",
    config_opencode = "/xdg-config/opencode",
    bootstrap = "/xdg-config/opencode/.gitignore",
    data = "/xdg-data",
    cache = "/xdg-cache",
    state = "/xdg-state",
  }
  local tree_keys = vim.tbl_keys(tree)
  table.sort(tree_keys)
  local normalize_ok, normalized_root = false, nil
  if type(tree.root) == "string" then
    normalize_ok, normalized_root = pcall(vim.fs.normalize, tree.root)
  end
  if
    not vim.deep_equal(tree_keys, {
      "bootstrap",
      "cache",
      "config",
      "config_opencode",
      "data",
      "home",
      "root",
      "state",
    })
    or type(tree.root) ~= "string"
    or tree.root:sub(1, 1) ~= "/"
    or tree.root == "/"
    or has_control(tree.root)
    or not normalize_ok
    or normalized_root ~= tree.root
  then
    return nil, "cleanup-failure"
  end
  local root_private_ok, root_private = pcall(private_directory, tree.root, lstat, getuid)
  if not root_private_ok or root_private ~= true then
    return nil, "cleanup-failure"
  end
  owned_root = tree.root
  for field, suffix in pairs(exact_children) do
    if tree[field] ~= owned_root .. suffix then
      return nil, "cleanup-failure"
    end
  end

  local function clean_tree()
    if tree.root ~= owned_root then
      return false
    end
    local ok, cleaned = pcall(cleanup_tree, owned_root, delete, lstat, getuid)
    return ok and cleaned == true
  end

  local probe_options = {
    resolve = options.resolve or require("ai.tools").resolve,
    revalidate = revalidate,
    lstat = lstat,
    getuid = getuid,
    environment = opencode_probe_environment(),
    working_directory = "/tmp/nvim-ai-probe",
    read_only_mounts = {
      { source = tree.home, destination = "/tmp/nvim-ai-probe/home" },
      { source = tree.config, destination = "/tmp/nvim-ai-probe/xdg-config" },
    },
    writable_mounts = {
      { source = tree.data, destination = "/tmp/nvim-ai-probe/xdg-data" },
      { source = tree.cache, destination = "/tmp/nvim-ai-probe/xdg-cache" },
      { source = tree.state, destination = "/tmp/nvim-ai-probe/xdg-state" },
    },
  }

  local invocation_ok, invocation =
    pcall(prepare_read_only_probe, identity.executable, command.arguments, probe_options, 5000)
  if not invocation_ok or type(invocation) ~= "table" then
    invocation = nil
    local cleaned = clean_tree()
    return nil, cleaned and "probe-failure" or "cleanup-failure"
  end

  local function exit_proven(result)
    return type(result) == "table"
      and (result.process_started ~= true or result.process_exited == true)
  end

  local function safe_observe(result, accepted, category)
    if type(observe) ~= "function" or not exit_proven(result) then
      return
    end
    local tree_copy = {
      root = owned_root,
      home = owned_root .. "/home",
      config = owned_root .. "/xdg-config",
      config_opencode = owned_root .. "/xdg-config/opencode",
      bootstrap = owned_root .. "/xdg-config/opencode/.gitignore",
      data = owned_root .. "/xdg-data",
      cache = owned_root .. "/xdg-cache",
      state = owned_root .. "/xdg-state",
    }
    local category_ok, safe_category = pcall(safe_probe_artifact_category, category)
    if not category_ok then
      return
    end
    local finished_ok, finished_at = pcall(now)
    local duration = finished_ok
        and type(finished_at) == "number"
        and math.max(0, math.min(10000, finished_at - started_at))
      or nil
    pcall(observe, command.name, tree_copy, {
      artifact_accepted = accepted == true,
      artifact_category = safe_category,
      code = type(result.code) == "number" and result.code or nil,
      signal = type(result.signal) == "number" and result.signal or nil,
      stdout_bytes = type(result.stdout) == "string" and #result.stdout or nil,
      stderr_bytes = type(result.stderr) == "string" and #result.stderr or nil,
      stdout_overflow = result.stdout_overflow == true,
      stderr_overflow = result.stderr_overflow == true,
      system_error = result.system_error == true,
      duration_ms = duration,
    })
  end

  local function result_category(
    result,
    artifacts_accepted,
    artifact_category,
    cleaned,
    runner_cause
  )
    if not exit_proven(result) then
      return "cleanup-failure"
    end
    if not cleaned then
      return "cleanup-failure"
    end
    local cause = ({
      ["probe-failure"] = true,
      timeout = true,
      ["output-overflow"] = true,
      cancellation = true,
    })[runner_cause] and runner_cause or nil
    if not cause then
      if cancellation_requested or artifact_category == "cancellation" then
        cause = "cancellation"
      elseif result.code == 124 then
        cause = "timeout"
      elseif result.stdout_overflow or result.stderr_overflow then
        cause = "output-overflow"
      elseif result.system_error or not valid_probe_result(result) then
        cause = "probe-failure"
      end
    end
    if cause then
      return cause
    end
    if not artifacts_accepted then
      return "artifact-rejection"
    end
    return ""
  end

  local function finalize(result, artifacts_accepted, artifact_category, runner_cause)
    if finished then
      return
    end
    finished = true
    local proven = exit_proven(result)
    if proven then
      safe_observe(result, artifacts_accepted, artifact_category)
    end
    local cleaned = proven and clean_tree() or false
    local category =
      result_category(result, artifacts_accepted, artifact_category, cleaned, runner_cause)
    pcall(on_complete, category == "" and result or nil, category)
  end

  local function after_process(result, runner_cause)
    if finished then
      return
    end
    if not exit_proven(result) then
      finalize(result, false, "process-exit-unproven", runner_cause)
      return
    end
    local inspect_ok, initial, artifact_category = pcall(inspect_artifacts, tree, command.semantic)
    if not inspect_ok or not initial then
      initial = nil
      finalize(result, false, artifact_category or "probe-artifact-tree", runner_cause)
      return
    end
    if not command.semantic then
      initial = nil
      finalize(result, true, "accepted", runner_cause)
      return
    end
    local settle_ok, settle_cancel = pcall(settle_lock, tree, initial, {
      now = now,
      defer = options.defer or vim.defer_fn,
      filesystem = options.filesystem,
      inspect_lock = options.inspect_lock,
    }, function(accepted, category)
      cancel_settle = nil
      finalize(result, accepted == true, category or "accepted", runner_cause)
    end)
    initial = nil
    if finished then
      return
    end
    if not settle_ok or type(settle_cancel) ~= "function" then
      settle_cancel = nil
      finalize(result, false, "probe-lock-tree", runner_cause)
      return
    end
    cancel_settle = settle_cancel
  end

  runner = bounded_system_async(
    invocation.argv,
    invocation.options,
    { stdout = MAX_COMPATIBILITY_REPORT_BYTES, stderr = MAX_HELP_BYTES },
    after_process,
    { system = options.system, schedule = schedule }
  )
  invocation = nil

  function public:cancel(reason)
    cancellation_requested = true
    if cancel_settle then
      local cancel = cancel_settle
      cancel_settle = nil
      pcall(cancel)
    end
    if runner then
      pcall(runner.cancel, runner, reason)
    end
  end

  function public:shutdown_drain(timeout_ms)
    cancellation_requested = true
    if runner then
      pcall(runner.cancel, runner, "shutdown")
    end
    local ok, exited, result = pcall(runner.shutdown_drain, runner, timeout_ms)
    if not ok or exited ~= true then
      result = nil
      return false
    end
    if cancel_settle then
      local cancel = cancel_settle
      cancel_settle = nil
      pcall(cancel)
    end
    if not finished then
      local inspect_ok, inspected = pcall(inspect_artifacts, tree, command.semantic)
      local accepted = inspect_ok and inspected ~= nil
      safe_observe(result, accepted, accepted and "shutdown" or "artifact-rejection")
      local cleaned = clean_tree()
      finished = true
      return cleaned == true
    end
    return true
  end

  return public
end

local function new_opencode_validation(overrides)
  local options = type(overrides) == "table" and overrides or {}
  local tools = require("ai.tools")
  local function identify()
    local executable = options.executable or tools.resolve("opencode")
    if not executable then
      return { installed = false, executable = "", metadata = "" }
    end
    local canonical = canonical_path(executable, "OpenCode executable", false)
    local valid_ok, valid = false, nil
    local stat_ok, current_stat = false, nil
    if canonical then
      valid_ok, valid = pcall(options.revalidate or tools.revalidate, canonical)
      stat_ok, current_stat = pcall(options.stat or vim.uv.fs_lstat, canonical)
    end
    local metadata = stat_ok and executable_metadata(current_stat) or nil
    current_stat = nil
    if not canonical or not valid_ok or valid ~= true or not metadata then
      return { installed = false, executable = "", metadata = "" }
    end
    return { installed = true, executable = canonical, metadata = metadata }
  end

  return require("ai.backends.opencode_validation").new({
    cache = options.cache,
    identify = identify,
    start_probe = function(identity, command, complete)
      return start_opencode_probe(identity, command, complete, options)
    end,
    now = options.now or vim.uv.now,
    defer = options.defer or vim.defer_fn,
    schedule = options.schedule or vim.schedule,
    notify = options.notify or vim.notify,
    warn_level = options.warn_level or vim.log.levels.WARN,
  })
end

local PROFILE_HELPER_REQUEST_KEYS = {
  prepare = {
    "schema",
    "token",
    "identity_key",
    "root",
    "backend_state",
    "global_auth",
    "user_agents",
    "repo_agents",
    "version",
    "config_json",
    "policy_json",
  },
  ["inspect-auth"] = { "global_auth" },
  ["inspect-profile"] = {
    "schema",
    "backend_state",
    "token",
    "identity_key",
    "root",
    "version",
    "fingerprint",
  },
}

local PROFILE_HELPER_REPORT_KEYS = {
  prepare = {
    "schema",
    "version",
    "profile_root",
    "fingerprint",
    "config_source",
    "auth_source",
    "home_mask_source",
    "auth",
    "credential_count",
  },
  ["inspect-auth"] = { "auth", "count" },
  ["inspect-profile"] = {
    "schema",
    "version",
    "profile_root",
    "fingerprint",
    "config_source",
    "auth_source",
    "home_mask_source",
    "auth",
    "credential_count",
  },
}

local function exact_object(value, keys)
  if type(value) ~= "table" or vim.islist(value) then
    return false
  end
  local expected = {}
  for _, key in ipairs(keys) do
    expected[key] = true
    if value[key] == nil then
      return false
    end
  end
  for key in pairs(value) do
    if type(key) ~= "string" or not expected[key] then
      return false
    end
  end
  return true
end

local function canonical_request_json(operation, request)
  local keys = PROFILE_HELPER_REQUEST_KEYS[operation]
  if not keys or not exact_object(request, keys) then
    return nil
  end
  local fields = {}
  for _, key in ipairs(keys) do
    local encoded_ok, encoded = pcall(vim.json.encode, request[key])
    if not encoded_ok or type(encoded) ~= "string" then
      return nil
    end
    fields[#fields + 1] = vim.json.encode(key) .. ":" .. encoded
  end
  return "{" .. table.concat(fields, ",") .. "}\n"
end

local function invoke_profile_helper(paths, operation, request, overrides)
  if type(paths) ~= "table" then
    return nil, "managed OpenCode profile helper paths are invalid"
  end
  local python = canonical_path(paths.python, "OpenCode Python", false)
  local helper = canonical_path(paths.profile_helper, "OpenCode profile helper", false)
  if not python or not helper then
    return nil, "managed OpenCode profile helper paths are invalid"
  end
  local stdin = canonical_request_json(operation, request)
  if not stdin then
    return nil, "managed OpenCode profile helper request is invalid"
  end
  local options = overrides or {}
  local revalidate = options.revalidate or require("ai.tools").revalidate
  for _, path in ipairs({ python, helper }) do
    local check_ok, valid = pcall(revalidate, path)
    if not check_ok or not valid then
      return nil, "managed OpenCode profile helper validation failed"
    end
  end
  local run = options.run
    or function(argv, system_options)
      return bounded_system(argv, system_options, {
        stdout = MAX_PROFILE_REPORT_BYTES,
        stderr = MAX_PROFILE_REPORT_BYTES,
      })
    end
  local argv = { python, "-I", "-B", helper, "--operation", operation }
  local run_ok, result = pcall(run, argv, {
    clear_env = true,
    env = { LANG = "C.UTF-8" },
    text = true,
    timeout = 5000,
    stdin = stdin,
  })
  if
    not run_ok
    or not valid_probe_result(result)
    or result.code ~= 0
    or result.stdout_overflow
    or result.stderr_overflow
    or result.system_error
    or result.stderr ~= ""
    or #result.stdout > MAX_PROFILE_REPORT_BYTES
    or #result.stderr > MAX_PROFILE_REPORT_BYTES
  then
    return nil, "managed OpenCode profile helper failed"
  end
  local decoded_ok, decoded = pcall(vim.json.decode, result.stdout)
  if not decoded_ok or not exact_object(decoded, assert(PROFILE_HELPER_REPORT_KEYS[operation])) then
    return nil, "managed OpenCode profile helper returned an invalid report"
  end
  return decoded
end

local function runtime_opencode_paths()
  local tools = require("ai.tools")
  local python, python_error = tools.resolve("python3")
  if not python then
    return nil, python_error
  end
  local helper_candidate = runtime_root and runtime_root .. "/scripts/nvim-ai-opencode-profile.py"
  local helper = helper_candidate and vim.uv.fs_realpath(helper_candidate)
  if type(helper) ~= "string" or helper == "" or vim.fs.normalize(helper) ~= helper then
    return nil, "managed OpenCode profile helper is unavailable"
  end
  local helper_stat = vim.uv.fs_lstat(helper)
  if
    not helper_stat
    or helper_stat.type ~= "file"
    or helper_stat.uid ~= vim.uv.getuid()
    or bit.band(helper_stat.mode, GROUP_OR_OTHER_WRITE_BITS) ~= 0
  then
    return nil, "managed OpenCode profile helper is unsafe"
  end

  local inherited_home = vim.env.HOME
  local home = type(inherited_home) == "string" and vim.uv.fs_realpath(inherited_home) or nil
  if type(home) ~= "string" or home == "" or vim.fs.normalize(home) ~= home then
    return nil, "managed OpenCode inherited home is invalid"
  end
  local home_stat = vim.uv.fs_lstat(home)
  if
    not home_stat
    or home_stat.type ~= "directory"
    or home_stat.uid ~= vim.uv.getuid()
    or bit.band(home_stat.mode, GROUP_OR_OTHER_WRITE_BITS) ~= 0
  then
    return nil, "managed OpenCode inherited home is unsafe"
  end
  local data_candidate = vim.env.XDG_DATA_HOME
  if type(data_candidate) ~= "string" or data_candidate == "" then
    data_candidate = home .. "/.local/share"
  end
  local data_root = vim.uv.fs_realpath(data_candidate)
  if type(data_root) ~= "string" or data_root == "" or vim.fs.normalize(data_root) ~= data_root then
    return nil, "managed OpenCode data root is invalid"
  end
  local data_stat = vim.uv.fs_lstat(data_root)
  if
    not data_stat
    or data_stat.type ~= "directory"
    or data_stat.uid ~= vim.uv.getuid()
    or bit.band(data_stat.mode, GROUP_OR_OTHER_WRITE_BITS) ~= 0
  then
    return nil, "managed OpenCode data root is unsafe"
  end
  return {
    python = python,
    profile_helper = helper,
    home_agents = home .. "/AGENTS.md",
    global_opencode_data = data_root .. "/opencode",
  }
end

local function runtime_helper_revalidate(path, expected)
  if path == expected.python then
    return require("ai.tools").revalidate(path)
  end
  if path ~= expected.profile_helper or vim.uv.fs_realpath(path) ~= path then
    return nil, "managed OpenCode profile helper changed"
  end
  local stat = vim.uv.fs_lstat(path)
  if
    not stat
    or stat.type ~= "file"
    or stat.uid ~= vim.uv.getuid()
    or bit.band(stat.mode, GROUP_OR_OTHER_WRITE_BITS) ~= 0
  then
    return nil, "managed OpenCode profile helper changed"
  end
  return true
end

local function runtime_dependencies()
  return {
    opencode_cache = opencode_cache.new(),
    executable = function(name)
      return require("ai.tools").resolve(name)
    end,
    revalidate = function(executable)
      return require("ai.tools").revalidate(executable)
    end,
    version = function(_, executable)
      return read_only_probe(executable, { "--version" })
    end,
    auth = function(name, executable)
      return read_only_probe(executable, assert(auth_arguments(name)))
    end,
    help = function(_, executable, arguments)
      return read_only_probe(executable, arguments)
    end,
    opencode_paths = runtime_opencode_paths,
    opencode_auth_path = function()
      local paths, paths_error = runtime_opencode_paths()
      if not paths then
        error(paths_error)
      end
      return paths.global_opencode_data .. "/auth.json"
    end,
    prepare_opencode_profile = function(request, supplied_paths)
      local expected, paths_error = runtime_opencode_paths()
      if not expected then
        return nil, paths_error
      end
      if
        type(supplied_paths) ~= "table"
        or supplied_paths.python ~= expected.python
        or supplied_paths.profile_helper ~= expected.profile_helper
      then
        return nil, "managed OpenCode profile helper paths changed"
      end
      return invoke_profile_helper(expected, "prepare", request, {
        revalidate = function(path)
          return runtime_helper_revalidate(path, expected)
        end,
      })
    end,
    inspect_opencode_profile = function(request, supplied_paths)
      local expected, paths_error = runtime_opencode_paths()
      if not expected then
        return nil, paths_error
      end
      if
        type(supplied_paths) ~= "table"
        or supplied_paths.python ~= expected.python
        or supplied_paths.profile_helper ~= expected.profile_helper
      then
        return nil, "managed OpenCode profile helper paths changed"
      end
      return invoke_profile_helper(expected, "inspect-profile", request, {
        revalidate = function(path)
          return runtime_helper_revalidate(path, expected)
        end,
      })
    end,
    inspect_opencode_auth = function(path)
      local expected, paths_error = runtime_opencode_paths()
      if not expected then
        return nil, paths_error
      end
      local report, report_error = invoke_profile_helper(
        expected,
        "inspect-auth",
        { global_auth = path },
        {
          revalidate = function(candidate)
            return runtime_helper_revalidate(candidate, expected)
          end,
        }
      )
      if not report then
        return nil, report_error
      end
      if
        (report.auth ~= "authenticated" and report.auth ~= "unauthenticated")
        or type(report.count) ~= "number"
        or report.count % 1 ~= 0
        or report.count < 0
        or report.count > 128
        or (report.auth == "authenticated" and report.count < 1)
        or (report.auth == "unauthenticated" and report.count ~= 0)
      then
        return nil, "managed OpenCode authentication report is invalid"
      end
      return report.auth
    end,
    uuid = function()
      return uuid_v4(vim.uv.random)
    end,
    port = function()
      local socket = assert(vim.uv.new_tcp())
      assert(socket:bind("127.0.0.1", 0))
      local name = assert(socket:getsockname())
      socket:close()
      return assert(name.port)
    end,
    password = function()
      return vim.fn.sha256(assert(vim.uv.random(32))):sub(1, 32)
    end,
    profile_token = function()
      return vim.fn.sha256(assert(vim.uv.random(32))):sub(1, 32)
    end,
    stat = vim.uv.fs_lstat,
    uid = vim.uv.getuid,
  }
end

local function opencode_identity(services, deps)
  local executable = services.resolve_executable("opencode")
  if not executable then
    return { installed = false, executable = "", metadata = "" }
  end
  local stat_ok, current_stat = pcall(deps.stat, executable)
  local metadata = stat_ok and executable_metadata(current_stat) or nil
  current_stat = nil
  if not metadata then
    return { installed = false, executable = "", metadata = "" }
  end
  return { installed = true, executable = executable, metadata = metadata }
end

local function new(deps)
  assert(type(deps) == "table", "backend dependencies are required")
  local services = {}
  for key, value in pairs(deps) do
    services[key] = value
  end

  function services.resolve_executable(name)
    local ok, executable, resolve_error = pcall(deps.executable, name)
    if not ok then
      return nil,
        "executable resolution failed: " .. clean_text(executable, MAX_DIAGNOSTIC_BYTES),
        false
    end
    if not executable then
      return nil, clean_text(resolve_error, MAX_DIAGNOSTIC_BYTES), false
    end
    local canonical, canonical_error = canonical_path(executable, name .. " executable", false)
    if not canonical then
      return nil, canonical_error, true
    end
    local stat = deps.stat(canonical)
    if not stat or stat.type ~= "file" then
      return nil, name .. " executable is not a nonsymlink regular file", true
    end
    if type(deps.revalidate) ~= "function" then
      return nil, name .. " executable cannot be revalidated", true
    end
    local check_ok, valid, validation_error = pcall(deps.revalidate, canonical)
    if not check_ok or not valid then
      return nil, clean_text(check_ok and validation_error or valid, MAX_DIAGNOSTIC_BYTES), true
    end
    return canonical, nil, true
  end

  function services.append_grants(argv, grants)
    local seen = {}
    for _, grant in ipairs(grants) do
      local metadata = deps.stat(grant)
      local directory = metadata and metadata.type == "file" and vim.fs.dirname(grant) or grant
      if not seen[directory] then
        argv[#argv + 1] = "--add-dir"
        argv[#argv + 1] = directory
        seen[directory] = true
      end
    end
  end

  function services.validate_launch(identity, paths)
    if type(identity) ~= "table" then
      return nil, "AI identity is required"
    end
    local root, root_error = canonical_path(identity.root, "AI root", false)
    if not root then
      return nil, root_error
    end
    if type(paths) ~= "table" then
      return nil, "backend paths are required"
    end
    if paths.opencode_profile ~= nil then
      return nil, "OpenCode profile references are not valid for this backend"
    end
    local backend_state, state_error =
      canonical_path(paths.backend_state, "backend state path", false)
    if not backend_state then
      return nil, state_error
    end
    if type(paths.grants) ~= "table" or not vim.islist(paths.grants) then
      return nil, "scope grants must be a sorted list"
    end
    local grants = {}
    local previous
    for _, grant in ipairs(paths.grants) do
      local canonical, grant_error = canonical_path(grant, "scope grant", false)
      if not canonical then
        return nil, grant_error
      end
      if previous and canonical <= previous then
        return nil, "scope grants must be sorted and unique"
      end
      grants[#grants + 1] = canonical
      previous = canonical
    end
    return { root = root, backend_state = backend_state, grants = grants }
  end

  function services.validate_opencode_paths(paths)
    if type(deps.opencode_paths) ~= "function" then
      return true
    end
    local ok, expected = pcall(deps.opencode_paths)
    if not ok or not expected then
      return nil, "managed OpenCode source path validation failed"
    end
    for _, field in ipairs({
      "python",
      "profile_helper",
      "home_agents",
      "global_opencode_data",
    }) do
      local actual, actual_error = canonical_path(paths[field], "OpenCode " .. field, false)
      if not actual or actual ~= expected[field] then
        return nil, actual_error or "managed OpenCode source path changed"
      end
    end
    return true
  end

  function services.destination(backend_state, relative)
    if type(relative) ~= "string" or relative == "" or relative:sub(1, 1) == "/" then
      return nil, "read-only input destination is invalid"
    end
    local destination = vim.fs.normalize(backend_state .. "/" .. relative)
    if destination:sub(1, #backend_state + 1) ~= backend_state .. "/" then
      return nil, "read-only input destination escapes backend state"
    end
    return destination
  end

  function services.provider_path(path, kind, label)
    local canonical, canonical_error = canonical_path(path, label, false)
    if not canonical then
      return nil, canonical_error
    end
    local stat = deps.stat(canonical)
    if not stat then
      return nil
    end
    if stat.type ~= kind then
      return nil, label .. " has the wrong type"
    end
    if type(stat.mode) ~= "number" or bit.band(stat.mode, GROUP_OR_OTHER_WRITE_BITS) ~= 0 then
      return nil, label .. " has an unsafe mode"
    end
    if type(stat.uid) ~= "number" or stat.uid ~= deps.uid() then
      return nil, label .. " has an unsafe owner"
    end
    return canonical
  end

  function services.read_only_input(source, destination, kind, backend_state, label)
    local canonical_source, source_error = services.provider_path(source, kind, label)
    if source_error then
      return nil, source_error
    end
    if not canonical_source then
      return nil
    end
    local canonical_destination, destination_error =
      services.destination(backend_state, destination)
    if not canonical_destination then
      return nil, destination_error
    end
    return {
      source = canonical_source,
      destination = canonical_destination,
      kind = kind,
    }
  end

  local function probe(executable, callback, ...)
    local check_ok, valid, validation_error = pcall(deps.revalidate, executable)
    if not check_ok or not valid then
      return nil, clean_text(check_ok and validation_error or valid, MAX_DIAGNOSTIC_BYTES)
    end
    local ok, result = pcall(callback, ...)
    if not ok then
      return nil, clean_text(result, MAX_DIAGNOSTIC_BYTES)
    end
    if not valid_probe_result(result) then
      return nil, "probe returned an invalid result"
    end
    return result
  end

  function services.health_backend(name, capabilities, help_requirements)
    local executable, executable_error, installed = services.resolve_executable(name)
    if not executable then
      return {
        installed = installed,
        executable = "",
        version = "",
        auth = "unknown",
        capabilities = {},
        error = clean_text(executable_error, MAX_DIAGNOSTIC_BYTES),
      }
    end

    local version_result, version_error = probe(executable, deps.version, name, executable)
    if not version_result or version_result.code ~= 0 then
      return {
        installed = true,
        executable = executable,
        version = "",
        auth = "unknown",
        capabilities = {},
        error = clean_text(
          "version probe failed: " .. (version_error or diagnostic(version_result)),
          MAX_DIAGNOSTIC_BYTES
        ),
      }
    end
    local version = clean_text(version_result.stdout, MAX_DIAGNOSTIC_BYTES)
    if version == "" then
      return {
        installed = true,
        executable = executable,
        version = "",
        auth = "unknown",
        capabilities = {},
        error = "version probe returned no version",
      }
    end

    for _, requirement in ipairs(help_requirements) do
      local help_result, help_error =
        probe(executable, deps.help, name, executable, vim.deepcopy(requirement.arguments))
      if not help_result or help_result.code ~= 0 then
        return {
          installed = true,
          executable = executable,
          version = version,
          auth = "unknown",
          capabilities = {},
          error = clean_text(
            "compatibility probe failed: " .. (help_error or diagnostic(help_result)),
            MAX_DIAGNOSTIC_BYTES
          ),
        }
      end
      local output = (help_result.stdout .. "\n" .. help_result.stderr):sub(1, MAX_HELP_BYTES)
      for _, flag in ipairs(requirement.flags) do
        if not output:find(flag, 1, true) then
          return {
            installed = true,
            executable = executable,
            version = version,
            auth = "unknown",
            capabilities = {},
            error = clean_text(
              string.format("incompatible %s CLI: missing %s", name, flag),
              MAX_DIAGNOSTIC_BYTES
            ),
          }
        end
      end
    end

    local auth_result = probe(executable, deps.auth, name, executable)
    local auth = "unknown"
    local health_error = ""
    local parsed_auth = auth_result and parse_auth(name, auth_result) or "unknown"
    if parsed_auth == "unauthenticated" then
      auth = "unauthenticated"
    elseif auth_result and auth_result.code == 0 and parsed_auth == "authenticated" then
      auth = "authenticated"
    else
      health_error = auth_diagnostic(name, auth_result)
    end

    return {
      installed = true,
      executable = executable,
      version = version,
      auth = auth,
      capabilities = vim.deepcopy(capabilities),
      error = health_error,
    }
  end

  function services.format_context(context)
    if type(context) ~= "table" or type(context.path) ~= "string" or context.path == "" then
      return ""
    end
    if has_control(context.path) then
      return ""
    end
    if
      context.kind == "location"
      and type(context.line) == "number"
      and context.line >= 1
      and context.line % 1 == 0
      and type(context.column) == "number"
      and context.column >= 1
      and context.column % 1 == 0
    then
      return string.format("Regarding %s:%d:%d: ", context.path, context.line, context.column)
    end
    if
      context.kind == "selection"
      and type(context.first) == "number"
      and context.first >= 1
      and context.first % 1 == 0
      and type(context.last) == "number"
      and context.last >= context.first
      and context.last % 1 == 0
      and type(context.context_file) == "string"
      and context.context_file:sub(1, 1) == "/"
      and not has_control(context.context_file)
    then
      return string.format(
        "Use the exact selection from %s:%d-%d stored at %s: ",
        context.path,
        context.first,
        context.last,
        context.context_file
      )
    end
    return ""
  end

  local opencode_controller
  local shutdown_called = false
  local shutdown_result = true

  local function idle_opencode_compatibility()
    return {
      state = "not_checked",
      installed = false,
      executable = "",
      version = "",
      category = "",
      queued = false,
    }
  end

  local function opencode_validation_controller()
    if opencode_controller then
      return opencode_controller
    end
    if deps.opencode_validation ~= nil then
      opencode_controller = deps.opencode_validation
      return opencode_controller
    end
    opencode_controller = require("ai.backends.opencode_validation").new({
      cache = deps.opencode_cache,
      identify = function()
        return opencode_identity(services, deps)
      end,
      start_probe = function(identity, command, complete)
        local starter = type(deps.start_opencode_probe) == "function" and deps.start_opencode_probe
          or start_opencode_probe
        return starter(identity, command, complete)
      end,
      now = deps.now or vim.uv.now,
      defer = deps.defer or vim.defer_fn,
      schedule = deps.schedule or vim.schedule,
      notify = deps.notify or vim.notify,
      warn_level = deps.warn_level or vim.log.levels.WARN,
    })
    return opencode_controller
  end

  services.opencode_compatibility_snapshot = function()
    if shutdown_called then
      return idle_opencode_compatibility()
    end
    return opencode_validation_controller():snapshot()
  end
  services.opencode_compatibility_report = function()
    if shutdown_called then
      return nil
    end
    return opencode_validation_controller():report()
  end

  local adapters = {
    codex = require("ai.backends.codex").new(services),
    claude = require("ai.backends.claude").new(services),
    opencode = require("ai.backends.opencode").new(services),
  }
  local registry = {
    names = function()
      return vim.deepcopy(BACKEND_NAMES)
    end,
    get = function(_, name)
      return adapters[name]
    end,
    health = function(_, name)
      local adapter = adapters[name]
      if not adapter then
        return {
          installed = false,
          executable = "",
          version = "",
          auth = "unknown",
          capabilities = {},
          error = "unknown backend",
        }
      end
      return adapter:health()
    end,
  }

  function registry:opencode_compatibility()
    if shutdown_called then
      return idle_opencode_compatibility()
    end
    return opencode_validation_controller():snapshot()
  end

  function registry:ensure_opencode_compatibility(request)
    if shutdown_called then
      return nil, "managed OpenCode compatibility request is invalid"
    end
    return opencode_validation_controller():ensure(request)
  end

  function registry:take_opencode_open(identity_key)
    if shutdown_called then
      return false
    end
    return opencode_validation_controller():take_open(identity_key)
  end

  function registry:cancel_opencode_compatibility(reason)
    if shutdown_called then
      return nil
    end
    return opencode_validation_controller():cancel(reason)
  end

  function registry:subscribe_opencode_compatibility(callback)
    if shutdown_called then
      return nil, "managed OpenCode compatibility observer is unavailable"
    end
    return opencode_validation_controller():subscribe(callback)
  end

  function registry:shutdown(exit_committed)
    assert(type(exit_committed) == "boolean", "shutdown phase must be explicit")
    if shutdown_called then
      return shutdown_result
    end
    shutdown_called = true
    if not opencode_controller then
      return true
    end
    local ok, result = pcall(opencode_controller.shutdown, opencode_controller, exit_committed)
    shutdown_result = ok and result == true
    return shutdown_result
  end

  return registry
end

local runtime

local function runtime_registry()
  if not runtime then
    runtime = new(runtime_dependencies())
  end
  return runtime
end

function M.names()
  return vim.deepcopy(BACKEND_NAMES)
end

function M.get(name)
  return runtime_registry():get(name)
end

function M.health(name)
  return runtime_registry():health(name)
end

function M.opencode_compatibility()
  return runtime_registry():opencode_compatibility()
end

function M.ensure_opencode_compatibility(request)
  return runtime_registry():ensure_opencode_compatibility(request)
end

function M.take_opencode_open(identity_key)
  return runtime_registry():take_opencode_open(identity_key)
end

function M.cancel_opencode_compatibility(reason)
  return runtime_registry():cancel_opencode_compatibility(reason)
end

function M.subscribe_opencode_compatibility(callback)
  return runtime_registry():subscribe_opencode_compatibility(callback)
end

function M.shutdown(exit_committed)
  assert(type(exit_committed) == "boolean", "shutdown phase must be explicit")
  if not runtime then
    return true
  end
  local current = runtime
  runtime = nil
  return current:shutdown(exit_committed)
end

M._test = {
  auth_arguments = auth_arguments,
  bounded_system = bounded_system,
  bounded_system_async = bounded_system_async,
  cleanup_owned_probe_tree = cleanup_owned_probe_tree,
  create_opencode_probe_tree = create_opencode_probe_tree,
  inspect_opencode_probe_lock = inspect_opencode_probe_lock,
  inspect_opencode_probe_artifacts = inspect_opencode_probe_artifacts,
  invoke_profile_helper = invoke_profile_helper,
  new = new,
  new_opencode_validation = new_opencode_validation,
  read_only_probe = read_only_probe,
  settle_opencode_probe_lock = settle_opencode_probe_lock,
  start_opencode_probe = start_opencode_probe,
  uuid = uuid_v4,
}

return M
