local bit = require("bit")

local M = {}

local C0_PATTERN = "[%z\1-\31\127]"
local C1_PATTERN = "\194[\128-\159]"
local EXECUTE_BITS = 73
local GROUP_OR_OTHER_WRITE_BITS = 18
local MAX_ARGUMENTS = 256
local MAX_TEXT_BYTES = 8192
local POLICY_JSON =
  '{"bash":"ask","doom_loop":"ask","external_directory":"ask","skill":"deny","task":"deny","webfetch":"ask","websearch":"ask"}'

local MANAGED_ENVIRONMENT_KEYS = {
  "OPENCODE_DISABLE_AUTOUPDATE",
  "OPENCODE_DISABLE_CLAUDE_CODE",
  "OPENCODE_DISABLE_EXTERNAL_SKILLS",
  "OPENCODE_DISABLE_LSP_DOWNLOAD",
  "OPENCODE_DISABLE_PROJECT_CONFIG",
  "OPENCODE_PERMISSION",
  "OPENCODE_PURE",
  "OPENCODE_SERVER_PASSWORD",
  "OPENCODE_SERVER_USERNAME",
  "XDG_CACHE_HOME",
  "XDG_CONFIG_HOME",
  "XDG_DATA_HOME",
  "XDG_STATE_HOME",
}

local function has_control(value)
  return type(value) ~= "string" or value:find(C0_PATTERN) ~= nil or value:find(C1_PATTERN) ~= nil
end

local function valid_hex(value, length)
  return type(value) == "string" and #value == length and value:match("^[0-9a-f]+$") ~= nil
end

local function canonical_path(value, label, allow_root)
  if type(value) ~= "string" or value == "" or value:sub(1, 1) ~= "/" then
    return nil, label .. " must be an absolute path"
  end
  if #value > MAX_TEXT_BYTES or has_control(value) then
    return nil, label .. " contains a control character or is too large"
  end
  local ok, normalized = pcall(vim.fs.normalize, value)
  if not ok or normalized ~= value or (not allow_root and value == "/") then
    return nil, label .. " must be canonical"
  end
  return value
end

local function path_within(base, path)
  return path == base or path:sub(1, #base + 1) == base .. "/"
end

local function exact_keys(value, keys, label)
  if type(value) ~= "table" then
    return nil, label .. " must be an object"
  end
  local allowed = {}
  for _, key in ipairs(keys) do
    allowed[key] = true
    if value[key] == nil then
      return nil, label .. " is missing a field"
    end
  end
  for key in pairs(value) do
    if type(key) ~= "string" or not allowed[key] then
      return nil, label .. " contains an unknown field"
    end
  end
  return true
end

local function dense_length(value, label)
  if type(value) ~= "table" then
    return nil, label .. " must be an array"
  end
  local count = 0
  local maximum = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
      return nil, label .. " must be a dense array"
    end
    count = count + 1
    maximum = math.max(maximum, key)
  end
  if count ~= maximum then
    return nil, label .. " must be a dense array"
  end
  return count
end

local function copy_string_array(value, label, paths)
  local length, length_error = dense_length(value, label)
  if not length then
    return nil, length_error
  end
  if length > MAX_ARGUMENTS then
    return nil, label .. " contains too many entries"
  end
  local copied = {}
  for index = 1, length do
    local item = value[index]
    if type(item) ~= "string" or item == "" or #item > MAX_TEXT_BYTES or has_control(item) then
      return nil, label .. " contains an unsafe value"
    end
    if paths then
      local path, path_error = canonical_path(item, label .. " path")
      if not path then
        return nil, path_error
      end
    end
    copied[index] = item
  end
  return copied
end

local function sorted_unique_paths(value, label)
  local copied, copy_error = copy_string_array(value, label, true)
  if not copied then
    return nil, copy_error
  end
  local previous
  for _, path in ipairs(copied) do
    if previous and path <= previous then
      return nil, label .. " must be sorted and unique"
    end
    previous = path
  end
  return copied
end

local function validate_capabilities(value)
  local fields = { "approval", "busy", "completion", "exact_session" }
  local exact, exact_error = exact_keys(value, fields, "backend capabilities")
  if not exact then
    return nil, exact_error
  end
  local copied = {}
  for _, field in ipairs(fields) do
    if type(value[field]) ~= "boolean" then
      return nil, "backend capability must be boolean"
    end
    copied[field] = value[field]
  end
  return copied
end

local function validate_environment(value)
  if type(value) ~= "table" then
    return nil, "backend environment must be an object"
  end
  local copied = {}
  local count = 0
  for key, item in pairs(value) do
    count = count + 1
    if
      type(key) ~= "string"
      or key == ""
      or #key > MAX_TEXT_BYTES
      or has_control(key)
      or type(item) ~= "string"
      or #item > MAX_TEXT_BYTES
      or has_control(item)
    then
      return nil, "backend environment contains an unsafe value"
    end
    copied[key] = item
  end
  if count > 128 then
    return nil, "backend environment contains too many entries"
  end
  return copied
end

local function validate_inputs(value)
  local length, length_error = dense_length(value, "read-only inputs")
  if not length then
    return nil, length_error
  end
  if length > 128 then
    return nil, "read-only inputs contain too many entries"
  end
  local copied = {}
  for index = 1, length do
    local item = value[index]
    local exact, exact_error =
      exact_keys(item, { "source", "destination", "kind" }, "read-only input")
    if not exact then
      return nil, exact_error
    end
    local source, source_error = canonical_path(item.source, "read-only input source")
    if not source then
      return nil, source_error
    end
    local destination, destination_error =
      canonical_path(item.destination, "read-only input destination")
    if not destination then
      return nil, destination_error
    end
    if item.kind ~= "file" and item.kind ~= "directory" then
      return nil, "read-only input has an invalid kind"
    end
    copied[index] = { source = source, destination = destination, kind = item.kind }
  end
  return copied
end

local function validate_managed_profile(value, backend_state)
  local exact, exact_error = exact_keys(value, {
    "schema",
    "version",
    "profile_root",
    "fingerprint",
    "config_source",
    "auth_source",
    "home_mask_source",
  }, "managed profile")
  if not exact then
    return nil, exact_error
  end
  if value.schema ~= 1 or value.version ~= "1.18.30" then
    return nil, "managed profile schema or version is unsupported"
  end
  if not valid_hex(value.fingerprint, 64) then
    return nil, "managed profile fingerprint is invalid"
  end
  local root, root_error = canonical_path(value.profile_root, "managed profile root")
  if not root then
    return nil, root_error
  end
  local token = root:match("^" .. vim.pesc(backend_state .. "/profiles/") .. "([0-9a-f]+)$")
  if not valid_hex(token, 32) then
    return nil, "managed profile root is outside the backend state or has an invalid generation"
  end
  local expected = {
    config_source = root .. "/xdg-config",
    auth_source = root .. "/credentials/auth.json",
    home_mask_source = root .. "/empty-home-opencode",
  }
  for field, path in pairs(expected) do
    local candidate, candidate_error = canonical_path(value[field], "managed profile " .. field)
    if not candidate then
      return nil, candidate_error
    end
    if candidate ~= path then
      return nil, "managed profile contains an unexpected source path"
    end
  end
  return {
    schema = 1,
    version = "1.18.30",
    profile_root = root,
    fingerprint = value.fingerprint,
    config_source = expected.config_source,
    auth_source = expected.auth_source,
    home_mask_source = expected.home_mask_source,
  }
end

local function validate_managed_environment(environment, backend_state)
  local exact, exact_error =
    exact_keys(environment, MANAGED_ENVIRONMENT_KEYS, "managed environment")
  if not exact then
    return nil, exact_error
  end
  for _, field in ipairs({
    "OPENCODE_DISABLE_AUTOUPDATE",
    "OPENCODE_DISABLE_CLAUDE_CODE",
    "OPENCODE_DISABLE_EXTERNAL_SKILLS",
    "OPENCODE_DISABLE_LSP_DOWNLOAD",
    "OPENCODE_DISABLE_PROJECT_CONFIG",
    "OPENCODE_PURE",
  }) do
    if environment[field] ~= "true" then
      return nil, "managed environment contains a changed boolean control"
    end
  end
  if environment.OPENCODE_PERMISSION ~= POLICY_JSON then
    return nil, "managed environment permission policy changed"
  end
  if environment.OPENCODE_SERVER_USERNAME ~= "opencode" then
    return nil, "managed environment username changed"
  end
  if not valid_hex(environment.OPENCODE_SERVER_PASSWORD, 32) then
    return nil, "managed environment password is invalid"
  end
  local paths = {
    XDG_CACHE_HOME = backend_state .. "/xdg-cache",
    XDG_CONFIG_HOME = backend_state .. "/xdg-config",
    XDG_DATA_HOME = backend_state .. "/xdg-data",
    XDG_STATE_HOME = backend_state .. "/xdg-state",
  }
  for field, expected in pairs(paths) do
    if environment[field] ~= expected then
      return nil, "managed environment contains an unexpected XDG path"
    end
  end
  return true
end

local function optional_text(value, label)
  if value == nil or value == vim.NIL then
    return vim.NIL
  end
  if type(value) ~= "string" or value == "" or #value > MAX_TEXT_BYTES or has_control(value) then
    return nil, label .. " is invalid"
  end
  return value
end

local function canonical_port(value)
  if type(value) ~= "string" or value == "" or #value > 5 or value:match("^[0-9]+$") == nil then
    return nil
  end
  local number = tonumber(value)
  if number == nil or number < 1 or number > 65535 or tostring(number) ~= value then
    return nil
  end
  return value
end

local function validate_launch(launch, backend_state, root)
  if type(launch) ~= "table" then
    return nil, "backend launch must be an object"
  end
  local allowed = {
    kind = true,
    backend = true,
    argv = true,
    server_argv = true,
    attach_argv = true,
    env = true,
    session = true,
    capabilities = true,
    read_only_inputs = true,
    config_seed = true,
    protected_paths = true,
    event_url = true,
    event_file = true,
    managed_profile = true,
  }
  for key in pairs(launch) do
    if type(key) ~= "string" or not allowed[key] then
      return nil, "backend launch contains an unknown field"
    end
  end
  for _, field in ipairs({
    "kind",
    "backend",
    "env",
    "session",
    "capabilities",
    "read_only_inputs",
    "protected_paths",
  }) do
    if launch[field] == nil then
      return nil, "backend launch is missing a field"
    end
  end
  if launch.backend ~= "codex" and launch.backend ~= "claude" and launch.backend ~= "opencode" then
    return nil, "backend launch names an unsupported backend"
  end
  local environment, environment_error = validate_environment(launch.env)
  if not environment then
    return nil, environment_error
  end
  local capabilities, capabilities_error = validate_capabilities(launch.capabilities)
  if not capabilities then
    return nil, capabilities_error
  end
  local inputs, inputs_error = validate_inputs(launch.read_only_inputs)
  if not inputs then
    return nil, inputs_error
  end
  local protected, protected_error = sorted_unique_paths(launch.protected_paths, "protected paths")
  if not protected then
    return nil, protected_error
  end
  if type(launch.session) ~= "string" or #launch.session > 512 or has_control(launch.session) then
    return nil, "backend session is invalid"
  end
  local event_url, event_url_error = optional_text(launch.event_url, "backend event URL")
  if event_url == nil then
    return nil, event_url_error
  end
  local event_file, event_file_error = optional_text(launch.event_file, "backend event file")
  if event_file == nil then
    return nil, event_file_error
  end

  local copied = {
    kind = launch.kind,
    backend = launch.backend,
    env = environment,
    session = launch.session,
    capabilities = capabilities,
    read_only_inputs = inputs,
    protected_paths = protected,
    event_url = event_url,
    event_file = event_file,
  }
  if launch.config_seed ~= nil and launch.config_seed ~= vim.NIL then
    if launch.backend ~= "codex" or launch.kind ~= "direct" then
      return nil, "configuration seed is only supported for Codex"
    end
    local seed, seed_error = canonical_path(launch.config_seed, "Codex configuration seed")
    if not seed then
      return nil, seed_error
    end
    copied.config_seed = seed
  end
  if launch.kind == "direct" and (launch.backend == "codex" or launch.backend == "claude") then
    if launch.managed_profile ~= nil and launch.managed_profile ~= vim.NIL then
      return nil, "direct backend must not contain a managed profile"
    end
    local argv, argv_error = copy_string_array(launch.argv, "backend argv")
    if not argv or #argv == 0 then
      return nil, argv_error or "backend argv is empty"
    end
    if launch.server_argv ~= nil or launch.attach_argv ~= nil then
      return nil, "direct backend contains server or attach argv"
    end
    copied.argv = argv
    copied.server_argv = vim.NIL
    copied.attach_argv = vim.NIL
    copied.managed_profile = vim.NIL
  elseif launch.kind == "server_attach" and launch.backend == "opencode" then
    if launch.argv ~= nil then
      return nil, "OpenCode launch contains a direct argv"
    end
    local server, server_error = copy_string_array(launch.server_argv, "OpenCode server argv")
    if not server or #server == 0 then
      return nil, server_error or "OpenCode server argv is empty"
    end
    local attach, attach_error = copy_string_array(launch.attach_argv, "OpenCode attach argv")
    if not attach or #attach == 0 then
      return nil, attach_error or "OpenCode attach argv is empty"
    end
    local port = canonical_port(server[7])
    if
      #server ~= 7
      or server[2] ~= "--pure"
      or server[3] ~= "serve"
      or server[4] ~= "--hostname"
      or server[5] ~= "127.0.0.1"
      or server[6] ~= "--port"
      or port == nil
    then
      return nil, "OpenCode server and attach command forms changed"
    end
    local expected_attach_length = launch.session == "" and 6 or 8
    if
      #attach ~= expected_attach_length
      or attach[1] ~= server[1]
      or attach[2] ~= "--pure"
      or attach[3] ~= "attach"
      or attach[4] ~= "http://127.0.0.1:" .. port
      or attach[5] ~= "--dir"
      or attach[6] ~= root
      or (launch.session ~= "" and (attach[7] ~= "--session" or attach[8] ~= launch.session))
    then
      return nil, "OpenCode server and attach command forms changed"
    end
    local profile, profile_error = validate_managed_profile(launch.managed_profile, backend_state)
    if not profile then
      return nil, profile_error
    end
    local environment_ok, managed_environment_error =
      validate_managed_environment(environment, backend_state)
    if not environment_ok then
      return nil, managed_environment_error
    end
    if not vim.tbl_contains(protected, profile.profile_root) then
      return nil, "managed profile root is not protected"
    end
    copied.argv = vim.NIL
    copied.server_argv = server
    copied.attach_argv = attach
    copied.managed_profile = profile
  else
    return nil, "backend kind does not match the backend"
  end
  return copied
end

local function default_grant_dependencies()
  return {
    realpath = vim.uv.fs_realpath,
    stat = vim.uv.fs_stat,
  }
end

local function validate_grants(identity, grants, deps)
  if type(identity) ~= "table" then
    return nil, "AI identity is required"
  end
  local root, root_error = canonical_path(identity.root, "AI root")
  if not root then
    return nil, root_error
  end
  local length, length_error = dense_length(grants, "scope grants")
  if not length then
    return nil, length_error
  end
  if length > 128 then
    return nil, "scope grants contain too many entries"
  end
  deps = deps or default_grant_dependencies()
  local result = {}
  local seen = {}
  for index = 1, length do
    local raw, raw_error = canonical_path(grants[index], "scope grant")
    if not raw then
      return nil, raw_error
    end
    local ok_realpath, physical = pcall(deps.realpath, raw)
    if
      not ok_realpath
      or type(physical) ~= "string"
      or physical == ""
      or physical:sub(1, 1) ~= "/"
      or has_control(physical)
    then
      return nil, "scope grant is not physical"
    end
    physical = vim.fs.normalize(physical)
    local canonical, canonical_error = canonical_path(physical, "scope grant")
    if not canonical then
      return nil, canonical_error
    end
    local ok_stat, metadata = pcall(deps.stat, canonical)
    if
      not ok_stat
      or not metadata
      or (metadata.type ~= "directory" and metadata.type ~= "file")
    then
      return nil, "scope grant is not an existing file or directory"
    end
    if canonical == root or seen[canonical] then
      return nil,
        seen[canonical] and "scope grant is duplicate" or "scope grant duplicates the root"
    end
    seen[canonical] = true
    result[#result + 1] = canonical
  end
  table.sort(result)
  return result
end

local function shell_quote(value)
  if type(value) ~= "string" or value == "" or has_control(value) then
    return nil, "launcher command contains a control character"
  end
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function launcher_command(python, launcher, manifest)
  local quoted_python, python_error = shell_quote(python)
  if not quoted_python then
    return nil, python_error
  end
  local quoted_launcher, launcher_error = shell_quote(launcher)
  if not quoted_launcher then
    return nil, launcher_error
  end
  local quoted_manifest, manifest_error = shell_quote(manifest)
  if not quoted_manifest then
    return nil, manifest_error
  end
  return table.concat({
    "exec",
    quoted_python,
    "-I",
    "-B",
    quoted_launcher,
    "--manifest",
    quoted_manifest,
  }, " ")
end

local function default_resolve_trusted(path, label, executable)
  local candidate, candidate_error = canonical_path(path, label)
  if not candidate then
    return nil, candidate_error
  end
  local physical = vim.uv.fs_realpath(candidate)
  if type(physical) ~= "string" or vim.fs.normalize(physical) ~= physical then
    return nil, label .. " is not physical"
  end
  local metadata = vim.uv.fs_lstat(physical)
  if
    not metadata
    or metadata.type ~= "file"
    or type(metadata.mode) ~= "number"
    or type(metadata.uid) ~= "number"
    or bit.band(metadata.mode, GROUP_OR_OTHER_WRITE_BITS) ~= 0
    or (metadata.uid ~= 0 and metadata.uid ~= vim.uv.getuid())
  then
    return nil, label .. " is not a safely owned regular file"
  end
  if executable and bit.band(metadata.mode, EXECUTE_BITS) == 0 then
    return nil, label .. " is not executable"
  end
  return physical
end

local function prepare(options)
  if type(options) ~= "table" then
    return nil, "sandbox options must be an object"
  end
  if type(options.identity) ~= "table" or not valid_hex(options.identity.key, 32) then
    return nil, "AI identity key is invalid"
  end
  local root, root_error = canonical_path(options.identity.root, "AI root")
  if not root then
    return nil, root_error
  end
  if not valid_hex(options.token, 32) then
    return nil, "launch token is invalid"
  end
  if not valid_hex(options.control_token, 32) then
    return nil, "control token is invalid"
  end
  if type(options.writable) ~= "boolean" then
    return nil, "sandbox writable flag must be boolean"
  end
  local review_id = options.review_id
  if options.writable then
    if
      type(review_id) ~= "string"
      or #review_id > 128
      or review_id:match("^review_[0-9a-f]+$") == nil
    then
      return nil, "writable sandbox requires a valid review ID"
    end
  elseif review_id ~= nil then
    return nil, "read-only sandbox must not contain a review ID"
  end

  local paths = {}
  for _, item in ipairs({
    { field = "runtime_root", label = "runtime root" },
    { field = "state_root", label = "state root" },
    { field = "context_dir", label = "context directory" },
    { field = "backend_state_dir", label = "backend state directory" },
    { field = "control_socket", label = "control socket" },
    { field = "event_file", label = "event file" },
  }) do
    local path, path_error = canonical_path(options[item.field], item.label)
    if not path then
      return nil, path_error
    end
    paths[item.field] = path
  end
  if
    not path_within(paths.runtime_root, paths.context_dir)
    or not path_within(paths.runtime_root, paths.control_socket)
  then
    return nil, "runtime paths are outside the runtime root"
  end
  if
    not path_within(paths.state_root, paths.backend_state_dir)
    or not path_within(paths.backend_state_dir, paths.event_file)
  then
    return nil, "backend paths are outside the state root"
  end

  local grants, grants_error = validate_grants(options.identity, options.grants, options.grant_deps)
  if not grants then
    return nil, grants_error
  end
  local launch, launch_error = validate_launch(options.launch, paths.backend_state_dir, root)
  if not launch then
    return nil, launch_error
  end

  local resolve = options.resolve_trusted or default_resolve_trusted
  local trusted = {}
  for _, item in ipairs({
    { field = "python", label = "Python", executable = true },
    { field = "bwrap", label = "Bubblewrap", executable = true },
    { field = "shell", label = "login shell", executable = true },
    { field = "launcher", label = "launcher", executable = true },
    { field = "review_helper", label = "review helper", executable = false },
    { field = "control_helper", label = "control helper", executable = false },
    { field = "event_helper", label = "event helper", executable = false },
    { field = "profile_helper", label = "profile helper", executable = false },
  }) do
    local ok, resolved, resolution_error =
      pcall(resolve, options[item.field], item.label, item.executable)
    if not ok then
      return nil, item.label .. " resolution failed"
    end
    if not resolved then
      return nil, item.label .. " resolution failed: " .. tostring(resolution_error)
    end
    local canonical, canonical_error = canonical_path(resolved, item.label)
    if not canonical then
      return nil, canonical_error
    end
    trusted[item.field] = canonical
  end
  local host_tools, host_tools_error = sorted_unique_paths(options.host_tools, "host tools")
  if not host_tools then
    return nil, host_tools_error
  end
  for index, tool in ipairs(host_tools) do
    local ok, resolved, resolution_error = pcall(resolve, tool, "host tool", true)
    if not ok or not resolved then
      return nil, "host tool resolution failed: " .. tostring(resolution_error or resolved)
    end
    host_tools[index] = resolved
  end
  table.sort(host_tools)
  for index = 2, #host_tools do
    if host_tools[index] == host_tools[index - 1] then
      return nil, "host tools must be unique"
    end
  end

  local git_dir = vim.NIL
  local git_common_dir = vim.NIL
  local git_entry = vim.NIL
  if options.identity.inside_git then
    for field, label in pairs({
      git_dir = "Git directory",
      git_common_dir = "Git common directory",
      git_entry = "Git entry",
    }) do
      local path, path_error = canonical_path(options.identity[field], label)
      if not path then
        return nil, path_error
      end
      if field == "git_dir" then
        git_dir = path
      elseif field == "git_common_dir" then
        git_common_dir = path
      else
        git_entry = path
      end
    end
  end
  local tmux_socket = vim.NIL
  if options.identity.tmux_socket ~= nil then
    local socket, socket_error = canonical_path(options.identity.tmux_socket, "tmux socket")
    if not socket then
      return nil, socket_error
    end
    tmux_socket = socket
  end

  local manifest = {
    schema = 1,
    token = options.token,
    identity_key = options.identity.key,
    root = root,
    git_dir = git_dir,
    git_common_dir = git_common_dir,
    git_entry = git_entry,
    writable = options.writable,
    grants = grants,
    review_id = review_id or vim.NIL,
    runtime_root = paths.runtime_root,
    state_root = paths.state_root,
    context_dir = paths.context_dir,
    backend_state_dir = paths.backend_state_dir,
    control_socket = paths.control_socket,
    control_token = options.control_token,
    control_helper = trusted.control_helper,
    event_helper = trusted.event_helper,
    profile_helper = trusted.profile_helper,
    launcher = trusted.launcher,
    review_helper = trusted.review_helper,
    event_file = paths.event_file,
    tmux_socket = tmux_socket,
    python = trusted.python,
    bwrap = trusted.bwrap,
    host_tools = host_tools,
    shell = trusted.shell,
    launch = launch,
  }
  if type(options.write_manifest) ~= "function" then
    return nil, "manifest publication is unavailable"
  end
  local published, manifest_path, publication_error = pcall(options.write_manifest, manifest)
  if not published then
    return nil, "manifest publication failed"
  end
  if not manifest_path then
    return nil, tostring(publication_error or "manifest publication failed")
  end
  local canonical_manifest, manifest_error = canonical_path(manifest_path, "launch manifest")
  if not canonical_manifest then
    return nil, manifest_error
  end
  if not path_within(paths.runtime_root, canonical_manifest) then
    return nil, "launch manifest is outside the runtime root"
  end
  local command, command_error =
    launcher_command(trusted.python, trusted.launcher, canonical_manifest)
  if not command then
    return nil, command_error
  end
  return {
    token = options.token,
    path = canonical_manifest,
    argv = {
      trusted.python,
      "-I",
      "-B",
      trusted.launcher,
      "--manifest",
      canonical_manifest,
    },
    command = command,
    manifest = manifest,
  }
end

function M.prepare(options)
  return prepare(options)
end

function M.validate_grants(identity, grants)
  return validate_grants(identity, grants)
end

M._test = {
  prepare = prepare,
  validate_grants = validate_grants,
  validate_launch = validate_launch,
}

return M
