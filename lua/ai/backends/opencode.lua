local M = {}

local managed = require("ai.backends.opencode_managed")

local CAPABILITIES = {
  approval = true,
  busy = true,
  completion = true,
  exact_session = true,
}

local MAX_DIAGNOSTIC_BYTES = 256

local VALID_COMPATIBILITY_STATE = {
  not_checked = true,
  checking = true,
  ready = true,
  failed = true,
}

local VALID_COMPATIBILITY_FAILURE = {
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

local COMPATIBILITY_SNAPSHOT_FIELDS = {
  state = true,
  installed = true,
  executable = true,
  version = true,
  category = true,
  queued = true,
}

local compatibility_errors = {
  not_checked = "managed OpenCode compatibility not checked",
  checking = "managed OpenCode compatibility checking",
}

local function valid_session(value, allow_empty)
  if allow_empty and value == "" then
    return true
  end
  return type(value) == "string"
    and #value >= 5
    and #value <= 128
    and value:match("^ses_[0-9A-Za-z_-]+$") ~= nil
end

local function generic_error(category)
  return ("managed OpenCode " .. category .. " failed"):sub(1, MAX_DIAGNOSTIC_BYTES)
end

local function valid_compatibility_snapshot(snapshot)
  if type(snapshot) ~= "table" then
    return false
  end
  local field_count = 0
  for field in pairs(snapshot) do
    if not COMPATIBILITY_SNAPSHOT_FIELDS[field] then
      return false
    end
    field_count = field_count + 1
  end
  if
    field_count ~= 6
    or not VALID_COMPATIBILITY_STATE[snapshot.state]
    or type(snapshot.installed) ~= "boolean"
    or type(snapshot.executable) ~= "string"
    or type(snapshot.version) ~= "string"
    or type(snapshot.category) ~= "string"
    or type(snapshot.queued) ~= "boolean"
    or (snapshot.installed and snapshot.executable:sub(1, 1) ~= "/")
    or (not snapshot.installed and snapshot.executable ~= "")
  then
    return false
  end
  if snapshot.state == "ready" then
    return snapshot.installed and snapshot.version == managed.version() and snapshot.category == ""
  end
  if snapshot.state == "failed" and snapshot.category == "version-mismatch" then
    return snapshot.installed
      and not snapshot.queued
      and managed.version_mismatch(snapshot.version) ~= nil
  end
  if snapshot.version ~= "" then
    return false
  end
  if snapshot.state == "failed" then
    return VALID_COMPATIBILITY_FAILURE[snapshot.category] == true
  end
  return snapshot.category == ""
end

local function compatibility_health(executable, snapshot, installed)
  local state = type(snapshot) == "table" and snapshot.state or "failed"
  local category = type(snapshot) == "table" and snapshot.category or "probe-failure"
  local mismatch = state == "failed" and category == "version-mismatch"
  local detail = mismatch and managed.version_mismatch(snapshot.version)
    or compatibility_errors[state]
    or ("managed OpenCode compatibility failed: " .. tostring(category)):sub(
      1,
      MAX_DIAGNOSTIC_BYTES
    )
  return {
    installed = installed ~= false,
    executable = executable,
    version = mismatch and snapshot.version or "",
    auth = "unknown",
    capabilities = {},
    compatibility = state,
    error = detail,
  }
end

local function without_profile_reference(paths)
  local sanitized = vim.deepcopy(paths)
  sanitized.opencode_profile = nil
  return sanitized
end

function M.new(deps)
  local adapter = {}

  local function validate_common(identity, paths)
    if type(paths) ~= "table" then
      return nil, "backend paths are required"
    end
    if type(deps.validate_opencode_paths) == "function" then
      local valid_paths, paths_error = deps.validate_opencode_paths(paths)
      if not valid_paths then
        return nil, paths_error
      end
    end
    return deps.validate_launch(identity, without_profile_reference(paths))
  end

  local function inspect_profile(reference, identity, paths)
    local validated, validation_error = validate_common(identity, paths)
    if not validated then
      return nil, validation_error
    end
    local request, request_error = managed.inspection_request(reference, identity, paths)
    if not request then
      return nil, request_error
    end
    local ok, report = pcall(deps.inspect_opencode_profile, request, paths)
    if not ok or not report then
      return nil, generic_error("profile inspection")
    end
    local profile = managed.validate_profile_report(report, {
      backend_state = validated.backend_state,
      token = reference.token,
      fingerprint = reference.fingerprint,
    })
    if not profile then
      return nil, generic_error("profile validation")
    end
    return profile
  end

  local function prepare_profile(identity, paths, validated)
    local token_ok, token = pcall(deps.profile_token)
    if
      not token_ok
      or type(token) ~= "string"
      or #token ~= 32
      or token:match("^[0-9a-f]+$") == nil
    then
      return nil, generic_error("profile token generation")
    end
    local request, request_error = managed.profile_request(identity, paths, token)
    if not request then
      return nil, request_error
    end
    local ok, report = pcall(deps.prepare_opencode_profile, request, paths)
    if not ok or not report then
      return nil, generic_error("profile preparation")
    end
    local profile = managed.validate_profile_report(report, {
      backend_state = validated.backend_state,
      token = token,
    })
    if not profile then
      return nil, generic_error("profile validation")
    end
    return profile
  end

  local function build(identity, paths, session)
    if not valid_session(session, true) then
      return nil, "OpenCode session must be empty or a bounded ses_ identifier"
    end
    local validated, validation_error = validate_common(identity, paths)
    if not validated then
      return nil, validation_error
    end
    local executable, executable_error = deps.resolve_executable("opencode")
    local snapshot_ok, snapshot = pcall(deps.opencode_compatibility_snapshot)
    local valid_snapshot_ok, valid_snapshot = pcall(valid_compatibility_snapshot, snapshot)
    if
      not snapshot_ok
      or not valid_snapshot_ok
      or not valid_snapshot
      or snapshot.state ~= "ready"
      or snapshot.installed ~= true
      or snapshot.version ~= managed.version()
      or snapshot.category ~= ""
    then
      return nil, "managed OpenCode compatibility is not ready"
    end
    if not executable then
      return nil, executable_error
    end
    if snapshot.executable ~= executable then
      return nil, "managed OpenCode compatibility is not ready"
    end
    local report_ok, report = pcall(deps.opencode_compatibility_report)
    local validation_ok, compatible = pcall(managed.validate_compatibility, report)
    if not report_ok or type(report) ~= "table" or not validation_ok or not compatible then
      return nil, "managed OpenCode compatibility is not ready"
    end

    local profile, profile_error
    if paths.opencode_profile ~= nil then
      profile, profile_error = inspect_profile(paths.opencode_profile, identity, paths)
    else
      profile, profile_error = prepare_profile(identity, paths, validated)
    end
    if not profile then
      return nil, profile_error
    end

    local ok_port, port = pcall(deps.port)
    if not ok_port or type(port) ~= "number" or port % 1 ~= 0 or port < 1 or port > 65535 then
      return nil, "OpenCode port provider returned an invalid port"
    end
    local ok_password, password = pcall(deps.password)
    if
      not ok_password
      or type(password) ~= "string"
      or password:match("^[0-9a-f]+$") == nil
      or #password ~= 32
    then
      return nil, "OpenCode password provider returned an invalid secret"
    end
    local environment, environment_error = managed.environment(profile, password)
    if not environment then
      return nil, environment_error
    end

    local attach_argv = {
      executable,
      "--pure",
      "attach",
      string.format("http://127.0.0.1:%d", port),
      "--dir",
      validated.root,
    }
    if session ~= "" then
      vim.list_extend(attach_argv, { "--session", session })
    end

    local protected_paths = { executable, profile.profile_root }
    table.sort(protected_paths)
    return {
      kind = "server_attach",
      backend = "opencode",
      server_argv = {
        executable,
        "--pure",
        "serve",
        "--hostname",
        "127.0.0.1",
        "--port",
        tostring(port),
      },
      attach_argv = attach_argv,
      env = environment,
      session = session,
      capabilities = vim.deepcopy(CAPABILITIES),
      read_only_inputs = {},
      protected_paths = protected_paths,
      managed_profile = profile,
      event_url = string.format("http://127.0.0.1:%d/event", port),
      event_file = paths.event_file,
    }
  end

  function adapter:new_session(identity, paths)
    return build(identity, paths, "")
  end

  function adapter:resume_session(identity, paths, session)
    if not valid_session(session, false) then
      return nil, "OpenCode resume session must be a bounded ses_ identifier"
    end
    return build(identity, paths, session)
  end

  function adapter:format_context(context)
    return deps.format_context(context)
  end

  function adapter:capabilities()
    return vim.deepcopy(CAPABILITIES)
  end

  function adapter:session_reference(launch)
    return type(launch) == "table" and valid_session(launch.session, true) and launch.session or ""
  end

  function adapter:profile_reference(launch)
    if type(launch) ~= "table" then
      return nil, "OpenCode launch is required"
    end
    return managed.profile_reference(launch.managed_profile)
  end

  function adapter:validate_profile(reference, identity, paths)
    return inspect_profile(reference, identity, paths)
  end

  function adapter:suspend()
    return { signal = 1, timeout = 2000 }
  end

  function adapter:stop()
    return { signal = 15, timeout = 2000 }
  end

  function adapter:health()
    local executable = deps.resolve_executable("opencode")
    local snapshot_ok, snapshot = pcall(deps.opencode_compatibility_snapshot)
    local valid_snapshot_ok, valid_snapshot = pcall(valid_compatibility_snapshot, snapshot)
    if not snapshot_ok or not valid_snapshot_ok or not valid_snapshot then
      snapshot = {
        state = "failed",
        category = "probe-failure",
      }
    end
    if snapshot.state == "ready" and (not executable or snapshot.executable ~= executable) then
      snapshot = {
        state = "failed",
        category = "executable-drift",
      }
    end
    if not executable then
      return compatibility_health("", snapshot, false)
    end
    if snapshot.state ~= "ready" then
      return compatibility_health(executable, snapshot)
    end

    local report_ok, report = pcall(deps.opencode_compatibility_report)
    local validation_ok, compatible = pcall(managed.validate_compatibility, report)
    if not report_ok or type(report) ~= "table" or not validation_ok or not compatible then
      return compatibility_health(executable, {
        state = "failed",
        category = "probe-failure",
      })
    end

    local path_ok, auth_path = pcall(deps.opencode_auth_path)
    if not path_ok or type(auth_path) ~= "string" then
      return {
        installed = true,
        executable = executable,
        version = managed.version(),
        auth = "unknown",
        capabilities = {},
        compatibility = "ready",
        error = generic_error("authentication path validation"),
      }
    end
    local auth_ok, auth = pcall(deps.inspect_opencode_auth, auth_path)
    if not auth_ok or auth ~= "authenticated" then
      return {
        installed = true,
        executable = executable,
        version = managed.version(),
        auth = auth_ok and auth == "unauthenticated" and "unauthenticated" or "unknown",
        capabilities = {},
        compatibility = "ready",
        error = generic_error("authentication inspection"),
      }
    end
    return {
      installed = true,
      executable = executable,
      version = managed.version(),
      auth = "authenticated",
      capabilities = vim.deepcopy(CAPABILITIES),
      compatibility = "ready",
      error = "",
    }
  end

  return adapter
end

return M
