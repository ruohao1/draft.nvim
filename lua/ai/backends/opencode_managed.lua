local M = {}

local VERSION = "1.18.30"
local POLICY = {
  bash = "ask",
  doom_loop = "ask",
  external_directory = "ask",
  skill = "deny",
  task = "deny",
  webfetch = "ask",
  websearch = "ask",
}

local CONFIG = {
  ["$schema"] = "https://opencode.ai/config.json",
  autoupdate = false,
  permission = POLICY,
  agent = {
    general = { disable = true },
    explore = { disable = true },
    compaction = { permission = { ["*"] = "deny" } },
    summary = { permission = { ["*"] = "deny" } },
    title = { permission = { ["*"] = "deny" } },
  },
}

local POLICY_JSON =
  '{"bash":"ask","doom_loop":"ask","external_directory":"ask","skill":"deny","task":"deny","webfetch":"ask","websearch":"ask"}'
local CONFIG_JSON =
  '{"$schema":"https://opencode.ai/config.json","autoupdate":false,"permission":{"bash":"ask","doom_loop":"ask","external_directory":"ask","skill":"deny","task":"deny","webfetch":"ask","websearch":"ask"},"agent":{"general":{"disable":true},"explore":{"disable":true},"compaction":{"permission":{"*":"deny"}},"summary":{"permission":{"*":"deny"}},"title":{"permission":{"*":"deny"}}}}'
local BOOTSTRAP_GITIGNORE = "node_modules\npackage.json\npackage-lock.json\nbun.lock\n.gitignore"
local BOOTSTRAP_GITIGNORE_SHA256 =
  "663a068e76d264d0bc6740f5450b6c4193c7b41ecf5e0dc222485b8a17404d95"

local C0_PATTERN = "[%z\1-\31\127]"
local C1_PATTERN = "\194[\128-\159]"
local MAX_REPORT_BYTES = 1024 * 1024
local PROBE_PATH = "src/nvim_ai_probe.lua"
local EXPECTED_NAMES = { "build", "compaction", "plan", "summary", "title" }
local EXPECTED_HELP = {
  root = { "--pure", "serve", "attach" },
  serve = { "--hostname", "--port" },
  attach = { "--dir", "--session", "OPENCODE_SERVER_PASSWORD" },
}
local RISK_PERMISSIONS = { "bash", "webfetch", "websearch", "external_directory", "doom_loop" }
local DENIED_PERMISSIONS = { "task", "skill" }
local HIDDEN_TOOLS = {
  "invalid",
  "question",
  "bash",
  "read",
  "glob",
  "grep",
  "edit",
  "write",
  "task",
  "webfetch",
  "todowrite",
  "websearch",
  "skill",
}
local HELPER_PROFILE_KEYS = {
  "schema",
  "version",
  "profile_root",
  "fingerprint",
  "config_source",
  "auth_source",
  "home_mask_source",
  "auth",
  "credential_count",
}

local function has_control(value)
  return type(value) ~= "string" or value:find(C0_PATTERN) ~= nil or value:find(C1_PATTERN) ~= nil
end

local function valid_hex(value, length)
  return type(value) == "string" and #value == length and value:match("^[0-9a-f]+$") ~= nil
end

local function canonical_path(value, label)
  if type(value) ~= "string" or value == "" or value:sub(1, 1) ~= "/" then
    return nil, label .. " must be an absolute path"
  end
  if has_control(value) then
    return nil, label .. " contains a control character"
  end
  local ok, normalized = pcall(vim.fs.normalize, value)
  if not ok or normalized ~= value or value == "/" then
    return nil, label .. " must be canonical"
  end
  return value
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

local function array_length(value, label)
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

local function profile_components(profile)
  if type(profile) ~= "table" then
    return nil, "managed profile must be an object"
  end
  if profile.schema ~= 1 then
    return nil, "managed profile schema is unsupported"
  end
  if profile.version ~= VERSION then
    return nil, "managed profile version is unsupported"
  end
  local profile_root, root_error = canonical_path(profile.profile_root, "managed profile root")
  if not profile_root then
    return nil, root_error
  end
  if not valid_hex(profile.fingerprint, 64) then
    return nil, "managed profile fingerprint is invalid"
  end
  local backend_state, token = profile_root:match("^(.*)/profiles/([^/]+)$")
  if not backend_state or not valid_hex(token, 32) then
    return nil, "managed profile root has an invalid generation"
  end
  local canonical_backend, backend_error = canonical_path(backend_state, "managed backend state")
  if not canonical_backend then
    return nil, backend_error
  end
  return {
    backend_state = canonical_backend,
    token = token,
    fingerprint = profile.fingerprint,
  }
end

local function validate_rules(value, label)
  local length, length_error = array_length(value, label)
  if not length then
    return nil, length_error
  end
  for index = 1, length do
    local rule = value[index]
    local exact, exact_error =
      exact_keys(rule, { "permission", "pattern", "action" }, label .. " rule")
    if not exact then
      return nil, exact_error
    end
    if
      type(rule.permission) ~= "string"
      or rule.permission == ""
      or #rule.permission > 128
      or has_control(rule.permission)
    then
      return nil, label .. " contains an invalid permission"
    end
    if
      type(rule.pattern) ~= "string"
      or rule.pattern == ""
      or #rule.pattern > 4096
      or has_control(rule.pattern)
    then
      return nil, label .. " contains an invalid pattern"
    end
    if rule.action ~= "allow" and rule.action ~= "ask" and rule.action ~= "deny" then
      return nil, label .. " contains an invalid action"
    end
  end
  return true
end

local CASE_INSENSITIVE_WILDCARDS = package.config:sub(1, 1) == "\\"

local function wildcard_match(input, pattern)
  input = input:gsub("\\", "/")
  pattern = pattern:gsub("\\", "/")
  if CASE_INSENSITIVE_WILDCARDS then
    input = input:lower()
    pattern = pattern:lower()
  end
  local function matches(candidate)
    local input_index = 1
    local pattern_index = 1
    local star_index
    local retry_index
    while input_index <= #input do
      local wildcard = candidate:sub(pattern_index, pattern_index)
      if
        pattern_index <= #candidate
        and (wildcard == "?" or wildcard == input:sub(input_index, input_index))
      then
        input_index = input_index + 1
        pattern_index = pattern_index + 1
      elseif wildcard == "*" then
        star_index = pattern_index
        retry_index = input_index
        pattern_index = pattern_index + 1
      elseif star_index then
        retry_index = retry_index + 1
        input_index = retry_index
        pattern_index = star_index + 1
      else
        return false
      end
    end
    while candidate:sub(pattern_index, pattern_index) == "*" do
      pattern_index = pattern_index + 1
    end
    return pattern_index > #candidate
  end
  if pattern:sub(-2) == " *" and matches(pattern:sub(1, -3)) then
    return true
  end
  return matches(pattern)
end

local function resolve_permission(rules, permission)
  local action
  for _, rule in ipairs(rules) do
    if wildcard_match(permission, rule.permission) and wildcard_match(PROBE_PATH, rule.pattern) then
      action = rule.action
    end
  end
  return action
end

local function validate_empty_tool_map(value, label)
  if type(value) ~= "table" then
    return nil, label .. " tools must be an object"
  end
  if next(value) ~= nil then
    return nil, label .. " tools changed"
  end
  return true
end

local function validate_primary_agent(agent, label)
  local exact, exact_error = exact_keys(agent, { "native", "mode", "tools", "permission" }, label)
  if not exact then
    return nil, exact_error
  end
  if agent.native ~= true or agent.mode ~= "primary" then
    return nil, label .. " native definition changed"
  end
  local tools_ok, tools_error = validate_empty_tool_map(agent.tools, label)
  if not tools_ok then
    return nil, tools_error
  end
  return validate_rules(agent.permission, label .. " permissions")
end

local function validate_hidden_agent(agent, label)
  local exact, exact_error = exact_keys(agent, { "native", "hidden", "tools", "permission" }, label)
  if not exact then
    return nil, exact_error
  end
  if agent.native ~= true or agent.hidden ~= true then
    return nil, label .. " native definition changed"
  end
  if type(agent.tools) ~= "table" then
    return nil, label .. " tools must be an object"
  end
  local expected = {}
  for _, name in ipairs(HIDDEN_TOOLS) do
    expected[name] = true
    if agent.tools[name] ~= false then
      return nil, label .. " exposes an actionable tool"
    end
  end
  for name in pairs(agent.tools) do
    if type(name) ~= "string" or not expected[name] then
      return nil, label .. " tools changed"
    end
  end
  local rules_ok, rules_error = validate_rules(agent.permission, label .. " permissions")
  if not rules_ok then
    return nil, rules_error
  end
  local final_wildcard_action
  for _, rule in ipairs(agent.permission) do
    if rule.permission == "*" and rule.pattern == "*" then
      final_wildcard_action = rule.action
    end
  end
  if final_wildcard_action ~= "deny" or resolve_permission(agent.permission, "*") ~= "deny" then
    return nil, label .. " final wildcard denial changed"
  end
  for _, permission in ipairs(HIDDEN_TOOLS) do
    if resolve_permission(agent.permission, permission) ~= "deny" then
      return nil, label .. " permission denial changed"
    end
  end
  for _, permission in ipairs(RISK_PERMISSIONS) do
    if resolve_permission(agent.permission, permission) ~= "deny" then
      return nil, label .. " permission denial changed"
    end
  end
  return true
end

local function primary_rules(edit_action)
  local rules = {
    {
      permission = "edit",
      pattern = "*",
      action = edit_action == "allow" and "deny" or "allow",
    },
    { permission = "edit", pattern = PROBE_PATH, action = edit_action },
  }
  for _, permission in ipairs(RISK_PERMISSIONS) do
    rules[#rules + 1] = { permission = permission, pattern = "*", action = "allow" }
    rules[#rules + 1] = { permission = permission, pattern = PROBE_PATH, action = "ask" }
  end
  for _, permission in ipairs(DENIED_PERMISSIONS) do
    rules[#rules + 1] = { permission = permission, pattern = "*", action = "ask" }
    rules[#rules + 1] = { permission = permission, pattern = PROBE_PATH, action = "deny" }
  end
  return rules
end

local function hidden_tools()
  local tools = {}
  for _, name in ipairs(HIDDEN_TOOLS) do
    tools[name] = false
  end
  return tools
end

local function compatibility_fixture()
  return {
    version = VERSION,
    help = vim.deepcopy(EXPECTED_HELP),
    names = vim.deepcopy(EXPECTED_NAMES),
    agents = {
      build = {
        native = true,
        mode = "primary",
        tools = {},
        permission = primary_rules("allow"),
      },
      plan = {
        native = true,
        mode = "primary",
        tools = {},
        permission = primary_rules("deny"),
      },
      compaction = {
        native = true,
        hidden = true,
        tools = hidden_tools(),
        permission = { { permission = "*", pattern = "*", action = "deny" } },
      },
      summary = {
        native = true,
        hidden = true,
        tools = hidden_tools(),
        permission = { { permission = "*", pattern = "*", action = "deny" } },
      },
      title = {
        native = true,
        hidden = true,
        tools = hidden_tools(),
        permission = { { permission = "*", pattern = "*", action = "deny" } },
      },
    },
  }
end

local function replace_last_action(report, agent_name, permission, action)
  local rules = report.agents[agent_name].permission
  for index = #rules, 1, -1 do
    local rule = rules[index]
    if
      (rule.permission == permission or rule.permission == "*")
      and (rule.pattern == "*" or rule.pattern == PROBE_PATH)
    then
      rule.action = action
      return
    end
  end
  error("fixture permission is missing")
end

local function mutate_compatibility(report, mutation)
  local mutations = {
    version = function()
      report.version = "1.18.19"
    end,
    agents = function()
      report.agents.title = nil
    end,
    build_edit = function()
      replace_last_action(report, "build", "edit", "deny")
    end,
    plan_edit = function()
      replace_last_action(report, "plan", "edit", "allow")
    end,
    risk = function()
      replace_last_action(report, "build", "bash", "allow")
    end,
    hidden_tools = function()
      report.agents.compaction.tools.bash = true
    end,
  }
  assert(mutations[mutation], "unknown compatibility fixture mutation")()
end

function M.version()
  return VERSION
end

-- Only canonical release numbers may cross the probe-to-diagnostic boundary.
-- This is syntax validation, not authorization to launch an unaudited release.
function M.valid_version(value)
  if type(value) ~= "string" or #value > 32 then
    return false
  end
  local major, minor, patch = value:match("^(%d+)%.(%d+)%.(%d+)$")
  if not major then
    return false
  end
  for _, part in ipairs({ major, minor, patch }) do
    if #part > 1 and part:sub(1, 1) == "0" then
      return false
    end
  end
  return true
end

function M.version_mismatch(value)
  if not M.valid_version(value) or value == VERSION then
    return nil
  end
  return "managed OpenCode version mismatch: installed " .. value .. "; requires " .. VERSION
end

function M.policy()
  return vim.deepcopy(POLICY)
end

function M.policy_json()
  return POLICY_JSON
end

function M.config()
  return vim.deepcopy(CONFIG)
end

function M.config_json()
  return CONFIG_JSON
end

function M.bootstrap_gitignore()
  return BOOTSTRAP_GITIGNORE
end

function M.bootstrap_gitignore_sha256()
  return BOOTSTRAP_GITIGNORE_SHA256
end

function M.profile_request(identity, paths, token)
  if type(identity) ~= "table" or not valid_hex(identity.key, 32) then
    return nil, "AI identity key is invalid"
  end
  local root, root_error = canonical_path(identity.root, "AI root")
  if not root then
    return nil, root_error
  end
  if type(paths) ~= "table" then
    return nil, "AI paths must be an object"
  end
  local validated = {}
  for _, field in ipairs({
    "backend_state",
    "global_opencode_data",
    "home_agents",
    "profile_helper",
    "python",
  }) do
    local path, path_error = canonical_path(paths[field], "OpenCode " .. field)
    if not path then
      return nil, path_error
    end
    validated[field] = path
  end
  if not valid_hex(token, 32) then
    return nil, "OpenCode profile token is invalid"
  end
  return {
    schema = 1,
    token = token,
    identity_key = identity.key,
    root = root,
    backend_state = validated.backend_state,
    global_auth = validated.global_opencode_data .. "/auth.json",
    user_agents = validated.home_agents,
    repo_agents = root .. "/AGENTS.md",
    version = VERSION,
    config_json = CONFIG_JSON,
    policy_json = POLICY_JSON,
  }
end

function M.profile_reference(profile)
  local components, components_error = profile_components(profile)
  if not components then
    return nil, components_error
  end
  return {
    token = components.token,
    fingerprint = components.fingerprint,
    version = VERSION,
  }
end

function M.inspection_request(reference, identity, paths)
  if type(reference) ~= "table" then
    return nil, "OpenCode profile reference must be an object"
  end
  local exact, exact_error =
    exact_keys(reference, { "token", "fingerprint", "version" }, "OpenCode profile reference")
  if not exact then
    return nil, exact_error
  end
  if not valid_hex(reference.token, 32) then
    return nil, "OpenCode profile reference token is invalid"
  end
  if not valid_hex(reference.fingerprint, 64) then
    return nil, "OpenCode profile reference fingerprint is invalid"
  end
  if reference.version ~= VERSION then
    return nil, "OpenCode profile reference version is unsupported"
  end
  if type(identity) ~= "table" or not valid_hex(identity.key, 32) then
    return nil, "AI identity key is invalid"
  end
  local root, root_error = canonical_path(identity.root, "AI root")
  if not root then
    return nil, root_error
  end
  if type(paths) ~= "table" then
    return nil, "AI paths must be an object"
  end
  local backend_state, state_error = canonical_path(paths.backend_state, "OpenCode backend state")
  if not backend_state then
    return nil, state_error
  end
  return {
    schema = 1,
    backend_state = backend_state,
    token = reference.token,
    identity_key = identity.key,
    root = root,
    version = VERSION,
    fingerprint = reference.fingerprint,
  }
end

function M.validate_profile_report(report, expected)
  local exact, exact_error = exact_keys(report, HELPER_PROFILE_KEYS, "OpenCode profile report")
  if not exact then
    return nil, exact_error
  end
  if type(expected) ~= "table" then
    return nil, "OpenCode profile expectation must be an object"
  end
  local backend_state, state_error =
    canonical_path(expected.backend_state, "OpenCode backend state")
  if not backend_state then
    return nil, state_error
  end
  if not valid_hex(expected.token, 32) then
    return nil, "OpenCode expected profile token is invalid"
  end
  if expected.fingerprint ~= nil and not valid_hex(expected.fingerprint, 64) then
    return nil, "OpenCode expected profile fingerprint is invalid"
  end
  local components, components_error = profile_components(report)
  if not components then
    return nil, components_error
  end
  if components.backend_state ~= backend_state or components.token ~= expected.token then
    return nil, "OpenCode profile report does not match the requested generation"
  end
  if expected.fingerprint and components.fingerprint ~= expected.fingerprint then
    return nil, "OpenCode profile report fingerprint changed"
  end
  if report.auth ~= "authenticated" then
    return nil, "OpenCode profile has no compatible credentials"
  end
  if
    type(report.credential_count) ~= "number"
    or report.credential_count % 1 ~= 0
    or report.credential_count < 1
    or report.credential_count > 128
  then
    return nil, "OpenCode profile credential count is invalid"
  end
  local expected_sources = {
    config_source = report.profile_root .. "/xdg-config",
    auth_source = report.profile_root .. "/credentials/auth.json",
    home_mask_source = report.profile_root .. "/empty-home-opencode",
  }
  for field, expected_path in pairs(expected_sources) do
    local source, source_error = canonical_path(report[field], "OpenCode " .. field)
    if not source then
      return nil, source_error
    end
    if source ~= expected_path then
      return nil, "OpenCode profile report contains an unexpected source path"
    end
  end
  return {
    schema = 1,
    version = VERSION,
    profile_root = report.profile_root,
    fingerprint = report.fingerprint,
    config_source = report.config_source,
    auth_source = report.auth_source,
    home_mask_source = report.home_mask_source,
  }
end

function M.environment(profile, password)
  local components, components_error = profile_components(profile)
  if not components then
    return nil, components_error
  end
  if not valid_hex(password, 32) then
    return nil, "OpenCode server password is invalid"
  end
  local backend_state = components.backend_state
  return {
    OPENCODE_DISABLE_AUTOUPDATE = "true",
    OPENCODE_DISABLE_CLAUDE_CODE = "true",
    OPENCODE_DISABLE_EXTERNAL_SKILLS = "true",
    OPENCODE_DISABLE_LSP_DOWNLOAD = "true",
    OPENCODE_DISABLE_PROJECT_CONFIG = "true",
    OPENCODE_PERMISSION = POLICY_JSON,
    OPENCODE_PURE = "true",
    OPENCODE_SERVER_PASSWORD = password,
    OPENCODE_SERVER_USERNAME = "opencode",
    XDG_CACHE_HOME = backend_state .. "/xdg-cache",
    XDG_CONFIG_HOME = backend_state .. "/xdg-config",
    XDG_DATA_HOME = backend_state .. "/xdg-data",
    XDG_STATE_HOME = backend_state .. "/xdg-state",
  }
end

function M.validate_compatibility(report)
  if type(report) ~= "table" then
    return nil, "OpenCode compatibility report must be an object"
  end
  local encoded_ok, encoded = pcall(vim.json.encode, report)
  if not encoded_ok or type(encoded) ~= "string" then
    return nil, "OpenCode compatibility report is not JSON-compatible"
  end
  if #encoded > MAX_REPORT_BYTES then
    return nil, "OpenCode compatibility report exceeds the size limit"
  end

  local exact, exact_error =
    exact_keys(report, { "version", "help", "names", "agents" }, "OpenCode report")
  if not exact then
    return nil, exact_error
  end
  if report.version ~= VERSION then
    return nil, "OpenCode compatibility version is unsupported"
  end

  local help_ok, help_error =
    exact_keys(report.help, { "root", "serve", "attach" }, "OpenCode help")
  if not help_ok then
    return nil, help_error
  end
  for _, name in ipairs({ "root", "serve", "attach" }) do
    local length, length_error = array_length(report.help[name], "OpenCode " .. name .. " help")
    if not length then
      return nil, length_error
    end
    if
      length ~= #EXPECTED_HELP[name] or not vim.deep_equal(report.help[name], EXPECTED_HELP[name])
    then
      return nil, "OpenCode command form changed"
    end
  end

  local name_count, names_error = array_length(report.names, "OpenCode agent names")
  if not name_count then
    return nil, names_error
  end
  local seen = {}
  for index = 1, name_count do
    local name = report.names[index]
    if type(name) ~= "string" or name == "" or #name > 128 or has_control(name) then
      return nil, "OpenCode agent name is invalid"
    end
    if seen[name] then
      return nil, "OpenCode agent names contain a duplicate"
    end
    seen[name] = true
  end
  if name_count ~= #EXPECTED_NAMES or not vim.deep_equal(report.names, EXPECTED_NAMES) then
    return nil, "OpenCode agent set changed"
  end

  local agents_ok, agents_error = exact_keys(report.agents, EXPECTED_NAMES, "OpenCode agents")
  if not agents_ok then
    return nil, agents_error
  end
  for _, name in ipairs({ "build", "plan" }) do
    local agent_ok, agent_error = validate_primary_agent(report.agents[name], "OpenCode " .. name)
    if not agent_ok then
      return nil, agent_error
    end
  end
  for _, name in ipairs({ "compaction", "summary", "title" }) do
    local agent_ok, agent_error = validate_hidden_agent(report.agents[name], "OpenCode " .. name)
    if not agent_ok then
      return nil, agent_error
    end
  end

  if resolve_permission(report.agents.build.permission, "edit") ~= "allow" then
    return nil, "OpenCode Build edit behavior changed"
  end
  if resolve_permission(report.agents.plan.permission, "edit") ~= "deny" then
    return nil, "OpenCode Plan edit behavior changed"
  end
  for _, name in ipairs({ "build", "plan" }) do
    local rules = report.agents[name].permission
    for _, permission in ipairs(RISK_PERMISSIONS) do
      if resolve_permission(rules, permission) ~= "ask" then
        return nil, "OpenCode approval behavior changed"
      end
    end
    for _, permission in ipairs(DENIED_PERMISSIONS) do
      if resolve_permission(rules, permission) ~= "deny" then
        return nil, "OpenCode delegation behavior changed"
      end
    end
  end
  return true
end

M._test = {
  compatibility_fixture = compatibility_fixture,
  mutate_compatibility = mutate_compatibility,
}

return M
