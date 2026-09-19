local function eq(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    string.format("%s\nexpected: %s\nactual: %s", label, vim.inspect(expected), vim.inspect(actual))
  )
end

local function rejected(call, label)
  local value, err = call()
  assert(value == nil, label .. " was accepted")
  assert(type(err) == "string" and err ~= "", label .. " returned no diagnostic")
  assert(#err <= 256, label .. " returned an unbounded diagnostic")
end

local managed = require("ai.backends.opencode_managed")
local registry_module = require("ai.backends")

local expected_policy = {
  bash = "ask",
  doom_loop = "ask",
  external_directory = "ask",
  skill = "deny",
  task = "deny",
  webfetch = "ask",
  websearch = "ask",
}
local expected_config_json =
  '{"$schema":"https://opencode.ai/config.json","autoupdate":false,"permission":{"bash":"ask","doom_loop":"ask","external_directory":"ask","skill":"deny","task":"deny","webfetch":"ask","websearch":"ask"},"agent":{"general":{"disable":true},"explore":{"disable":true},"compaction":{"permission":{"*":"deny"}},"summary":{"permission":{"*":"deny"}},"title":{"permission":{"*":"deny"}}}}'

eq(managed.version(), "1.18.30", "audited OpenCode version")
eq(managed.policy(), expected_policy, "managed permission policy")
assert(managed.policy()["*"] == nil, "no wildcard permission")
assert(managed.policy().read == nil, "native read permission preserved")
assert(managed.policy().edit == nil, "native edit permission preserved")
eq(
  managed.policy_json(),
  '{"bash":"ask","doom_loop":"ask","external_directory":"ask","skill":"deny","task":"deny","webfetch":"ask","websearch":"ask"}',
  "canonical managed permission policy"
)

local config = managed.config()
eq(config.autoupdate, false, "configuration also disables updates")
eq(config.permission, managed.policy(), "file and environment policies agree")
eq(managed.config_json(), expected_config_json, "canonical managed configuration")
eq(vim.json.decode(managed.config_json()), config, "table and JSON configurations agree")
eq(
  managed.bootstrap_gitignore(),
  "node_modules\npackage.json\npackage-lock.json\nbun.lock\n.gitignore",
  "canonical OpenCode configuration bootstrap"
)
eq(
  managed.bootstrap_gitignore_sha256(),
  "663a068e76d264d0bc6740f5450b6c4193c7b41ecf5e0dc222485b8a17404d95",
  "canonical OpenCode configuration bootstrap digest"
)
eq(config.agent.general, { disable = true }, "general subagent disabled")
eq(config.agent.explore, { disable = true }, "explore subagent disabled")
for _, name in ipairs({ "compaction", "summary", "title" }) do
  eq(config.agent[name], { permission = { ["*"] = "deny" } }, name .. " remains tool-denied")
end
assert(
  config.agent.build == nil and config.agent.plan == nil,
  "native Build and Plan are not replaced"
)

local immutable_cases = {
  {
    label = "changed policy key",
    mutate = function()
      local value = managed.policy()
      value.bash = "allow"
      value.provider = "allow"
    end,
    fresh = managed.policy,
    expected = expected_policy,
  },
  {
    label = "changed configuration key",
    mutate = function()
      local value = managed.config()
      value.autoupdate = true
      value.agent.build = { disable = true }
    end,
    fresh = managed.config,
    expected = config,
  },
}
for _, case in ipairs(immutable_cases) do
  case.mutate()
  eq(case.fresh(), case.expected, case.label .. " did not alter the managed contract")
end

local identity = {
  key = string.rep("a", 32),
  root = "/work/repo",
}
local paths = {
  backend_state = "/state/identity/backends/opencode",
  global_opencode_data = "/home/user/.local/share/opencode",
  home_agents = "/home/user/AGENTS.md",
  profile_helper = "/config/nvim/scripts/nvim-ai-opencode-profile.py",
  python = "/usr/bin/python3",
}
local token = string.rep("b", 32)
local request = assert(managed.profile_request(identity, paths, token))
eq(request, {
  schema = 1,
  token = token,
  identity_key = identity.key,
  root = identity.root,
  backend_state = paths.backend_state,
  global_auth = "/home/user/.local/share/opencode/auth.json",
  user_agents = paths.home_agents,
  repo_agents = "/work/repo/AGENTS.md",
  version = "1.18.30",
  config_json = expected_config_json,
  policy_json = managed.policy_json(),
}, "exact managed profile request")
eq(request.global_auth, "/home/user/.local/share/opencode/auth.json", "auth-only source")
eq(request.user_agents, "/home/user/AGENTS.md", "global instruction source")
eq(request.repo_agents, "/work/repo/AGENTS.md", "repository instruction source")
assert(vim.inspect(request):find("account.json", 1, true) == nil, "account data excluded")
assert(vim.inspect(request):find("mcp-auth.json", 1, true) == nil, "MCP auth excluded")

local invalid_request_cases = {
  {
    label = "wrong identity key",
    change = function(changed_identity)
      changed_identity.key = string.rep("A", 32)
    end,
  },
  {
    label = "noncanonical root",
    change = function(changed_identity)
      changed_identity.root = "/work/../work/repo"
    end,
  },
  {
    label = "control-bearing root",
    change = function(changed_identity)
      changed_identity.root = "/work/repo\nchanged"
    end,
  },
}
for _, case in ipairs(invalid_request_cases) do
  local changed_identity = vim.deepcopy(identity)
  case.change(changed_identity)
  rejected(function()
    return managed.profile_request(changed_identity, paths, token)
  end, case.label)
end

for _, field in ipairs({
  "backend_state",
  "global_opencode_data",
  "home_agents",
  "profile_helper",
  "python",
}) do
  local changed_paths = vim.deepcopy(paths)
  changed_paths[field] = changed_paths[field] .. "/../escape"
  rejected(function()
    return managed.profile_request(identity, changed_paths, token)
  end, "noncanonical " .. field)
end
rejected(function()
  return managed.profile_request(identity, paths, string.rep("B", 32))
end, "changed token")

local managed_profile = {
  schema = 1,
  version = "1.18.30",
  profile_root = "/state/identity/backends/opencode/profiles/" .. token,
  fingerprint = string.rep("c", 64),
}
eq(assert(managed.profile_reference(managed_profile)), {
  token = token,
  fingerprint = string.rep("c", 64),
  version = "1.18.30",
}, "bounded durable profile reference")

for _, version in ipairs({ "1.18.28", "1.18.31" }) do
  local reference = assert(managed.profile_reference(managed_profile))
  reference.version = version
  local request, err = managed.inspection_request(reference, identity, paths)
  eq(request, nil, "noncurrent reference cannot authorize inspection")
  assert(err:find("version", 1, true), "noncurrent reference is refused at the version boundary")
end

local password = "0123456789abcdef0123456789abcdef"
eq(assert(managed.environment(managed_profile, password)), {
  OPENCODE_DISABLE_AUTOUPDATE = "true",
  OPENCODE_DISABLE_CLAUDE_CODE = "true",
  OPENCODE_DISABLE_EXTERNAL_SKILLS = "true",
  OPENCODE_DISABLE_LSP_DOWNLOAD = "true",
  OPENCODE_DISABLE_PROJECT_CONFIG = "true",
  OPENCODE_PERMISSION = managed.policy_json(),
  OPENCODE_PURE = "true",
  OPENCODE_SERVER_PASSWORD = password,
  OPENCODE_SERVER_USERNAME = "opencode",
  XDG_CACHE_HOME = "/state/identity/backends/opencode/xdg-cache",
  XDG_CONFIG_HOME = "/state/identity/backends/opencode/xdg-config",
  XDG_DATA_HOME = "/state/identity/backends/opencode/xdg-data",
  XDG_STATE_HOME = "/state/identity/backends/opencode/xdg-state",
}, "exact managed launch environment")

local invalid_profile_cases = {
  {
    label = "changed schema",
    change = function(profile)
      profile.schema = 2
    end,
  },
  {
    label = "changed version",
    change = function(profile)
      profile.version = "1.18.19"
    end,
  },
  {
    label = "previous audited version",
    change = function(profile)
      profile.version = "1.18.28"
    end,
  },
  {
    label = "future version",
    change = function(profile)
      profile.version = "1.18.31"
    end,
  },
  {
    label = "changed profile-root component",
    change = function(profile)
      profile.profile_root = "/state/identity/backends/opencode/profile/" .. token
    end,
  },
  {
    label = "changed profile-root token",
    change = function(profile)
      profile.profile_root = "/state/identity/backends/opencode/profiles/" .. string.rep("B", 32)
    end,
  },
  {
    label = "changed fingerprint",
    change = function(profile)
      profile.fingerprint = string.rep("C", 64)
    end,
  },
}
for _, case in ipairs(invalid_profile_cases) do
  local profile = vim.deepcopy(managed_profile)
  case.change(profile)
  rejected(function()
    return managed.profile_reference(profile)
  end, case.label)
end
rejected(function()
  return managed.environment(managed_profile, string.rep("A", 32))
end, "changed password")

local audited_risk_permissions = {
  "bash",
  "webfetch",
  "websearch",
  "external_directory",
  "doom_loop",
}
local audited_denied_permissions = { "task", "skill" }
local audited_hidden_tool_map = {
  invalid = false,
  question = false,
  bash = false,
  read = false,
  glob = false,
  grep = false,
  edit = false,
  write = false,
  task = false,
  webfetch = false,
  todowrite = false,
  websearch = false,
  skill = false,
}
local audited_primary_tool_map = {
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

local function audited_primary_permissions(edit_action)
  local rules = {
    {
      permission = "edit",
      pattern = "*",
      action = edit_action == "allow" and "deny" or "allow",
    },
    { permission = "edit", pattern = "src/nvim_ai_probe.lua", action = edit_action },
  }
  for _, permission in ipairs(audited_risk_permissions) do
    rules[#rules + 1] = { permission = permission, pattern = "*", action = "allow" }
    rules[#rules + 1] = {
      permission = permission,
      pattern = "src/nvim_ai_probe.lua",
      action = "ask",
    }
  end
  for _, permission in ipairs(audited_denied_permissions) do
    rules[#rules + 1] = { permission = permission, pattern = "*", action = "ask" }
    rules[#rules + 1] = {
      permission = permission,
      pattern = "src/nvim_ai_probe.lua",
      action = "deny",
    }
  end
  return rules
end

local function audited_hidden_agent()
  return {
    native = true,
    hidden = true,
    tools = vim.deepcopy(audited_hidden_tool_map),
    permission = { { permission = "*", pattern = "*", action = "deny" } },
  }
end

local function audited_compatibility_report()
  return {
    version = "1.18.30",
    help = {
      root = { "--pure", "serve", "attach" },
      serve = { "--hostname", "--port" },
      attach = { "--dir", "--session", "OPENCODE_SERVER_PASSWORD" },
    },
    names = { "build", "compaction", "plan", "summary", "title" },
    agents = {
      build = {
        native = true,
        mode = "primary",
        tools = {},
        permission = audited_primary_permissions("allow"),
      },
      plan = {
        native = true,
        mode = "primary",
        tools = {},
        permission = audited_primary_permissions("deny"),
      },
      compaction = audited_hidden_agent(),
      summary = audited_hidden_agent(),
      title = audited_hidden_agent(),
    },
  }
end

local good = audited_compatibility_report()
eq(good.names, { "build", "compaction", "plan", "summary", "title" }, "audited agent names")
assert(managed.validate_compatibility(good))
eq(
  managed._test.compatibility_fixture(),
  good,
  "production compatibility helper matches the independent audit"
)

local hidden_precedence = vim.deepcopy(good)
table.insert(hidden_precedence.agents.compaction.permission, 1, {
  permission = "bash",
  pattern = "*",
  action = "allow",
})
assert(managed.validate_compatibility(hidden_precedence), "final hidden denial wins precedence")

local nonmatching_wildcard_controls = {
  {
    label = "Lua character class is literal",
    agent = "plan",
    rule = { permission = "edit", pattern = "src/nvim_ai_probe[.]lua", action = "allow" },
  },
  {
    label = "Lua end anchor is literal",
    agent = "plan",
    rule = { permission = "edit", pattern = "src/nvim_ai_probe.lua$", action = "allow" },
  },
  {
    label = "resource matching is fully anchored",
    agent = "plan",
    rule = { permission = "edit", pattern = "nvim_ai_probe.lua", action = "allow" },
  },
  {
    label = "permission matching is fully anchored",
    agent = "build",
    rule = { permission = "ash", pattern = "*", action = "allow" },
  },
  {
    label = "permission brackets are literal",
    agent = "build",
    rule = { permission = "b[as]h", pattern = "*", action = "allow" },
  },
  {
    label = "question wildcard matches exactly one character",
    agent = "build",
    rule = { permission = "b??sh", pattern = "*", action = "allow" },
  },
}
for _, case in ipairs(nonmatching_wildcard_controls) do
  local report = vim.deepcopy(good)
  table.insert(report.agents[case.agent].permission, case.rule)
  assert(managed.validate_compatibility(report), case.label)
end

local wildcard_precedence = vim.deepcopy(good)
table.insert(wildcard_precedence.agents.plan.permission, {
  permission = "edit",
  pattern = "src/*.lua",
  action = "allow",
})
table.insert(wildcard_precedence.agents.plan.permission, {
  permission = "edit",
  pattern = "src/nvim_ai_*.lua",
  action = "deny",
})
assert(managed.validate_compatibility(wildcard_precedence), "last wildcard match wins precedence")

local false_accept_cases = {
  {
    label = "nonempty Build tool map",
    change = function(report)
      report.agents.build.tools.edit = false
    end,
  },
  {
    label = "unknown actionable Plan tool",
    change = function(report)
      report.agents.plan.tools.shell = true
    end,
  },
  {
    label = "hidden final wildcard allow",
    change = function(report)
      report.agents.compaction.permission[1].action = "allow"
    end,
  },
  {
    label = "hidden later permission allow",
    change = function(report)
      table.insert(report.agents.summary.permission, {
        permission = "bash",
        pattern = "src/nvim_ai_probe.lua",
        action = "allow",
      })
    end,
  },
  {
    label = "Plan wildcard edit allow",
    change = function(report)
      table.insert(report.agents.plan.permission, {
        permission = "edit",
        pattern = "src/*.lua",
        action = "allow",
      })
    end,
  },
  {
    label = "Plan optional trailing wildcard allow",
    change = function(report)
      table.insert(report.agents.plan.permission, {
        permission = "edit *",
        pattern = "src/nvim_ai_probe.lua",
        action = "allow",
      })
    end,
  },
  {
    label = "Build web-star risk allow",
    change = function(report)
      table.insert(report.agents.build.permission, {
        permission = "web*",
        pattern = "*",
        action = "allow",
      })
    end,
  },
  {
    label = "Plan bash-question risk allow",
    change = function(report)
      table.insert(report.agents.plan.permission, {
        permission = "b?sh",
        pattern = "*",
        action = "allow",
      })
    end,
  },
  {
    label = "hidden permission wildcard allow",
    change = function(report)
      table.insert(report.agents.compaction.permission, {
        permission = "b?sh",
        pattern = "*",
        action = "allow",
      })
    end,
  },
  {
    label = "hidden resource wildcard allow",
    change = function(report)
      table.insert(report.agents.summary.permission, {
        permission = "*",
        pattern = "src/*.lua",
        action = "allow",
      })
    end,
  },
  {
    label = "hidden normalized-backslash wildcard allow",
    change = function(report)
      table.insert(report.agents.title.permission, {
        permission = "*",
        pattern = "src\\*.lua",
        action = "allow",
      })
    end,
  },
}
local false_accepts = {}
for _, case in ipairs(false_accept_cases) do
  local report = vim.deepcopy(good)
  case.change(report)
  local ok, err = managed.validate_compatibility(report)
  if ok then
    false_accepts[#false_accepts + 1] = case.label
  else
    assert(type(err) == "string" and err ~= "", case.label .. " returned no diagnostic")
    assert(#err <= 256, case.label .. " returned an unbounded diagnostic")
  end
end
assert(#false_accepts == 0, "compatibility false accepts: " .. table.concat(false_accepts, ", "))

local function change_last_matching_action(report, agent_name, permission, action)
  local rules = report.agents[agent_name].permission
  for index = #rules, 1, -1 do
    local rule = rules[index]
    if
      (rule.permission == permission or rule.permission == "*")
      and (rule.pattern == "*" or rule.pattern == "src/nvim_ai_probe.lua")
    then
      rule.action = action
      return
    end
  end
  error("independent compatibility rule is missing")
end

local compatibility_mutations = {
  {
    label = "version",
    change = function(report)
      report.version = "1.18.19"
    end,
  },
  {
    label = "agents",
    change = function(report)
      report.agents.title = nil
    end,
  },
  {
    label = "build_edit",
    change = function(report)
      change_last_matching_action(report, "build", "edit", "deny")
    end,
  },
  {
    label = "plan_edit",
    change = function(report)
      change_last_matching_action(report, "plan", "edit", "allow")
    end,
  },
  {
    label = "risk",
    change = function(report)
      change_last_matching_action(report, "build", "websearch", "allow")
    end,
  },
  {
    label = "hidden_tools",
    change = function(report)
      report.agents.title.tools.websearch = true
    end,
  },
}
for _, mutation in ipairs(compatibility_mutations) do
  local changed = vim.deepcopy(good)
  mutation.change(changed)
  rejected(function()
    return managed.validate_compatibility(changed)
  end, "compatibility mutation: " .. mutation.label)
end

local invalid_compatibility_cases = {
  {
    label = "duplicate compatibility name",
    change = function(report)
      report.names[5] = "summary"
    end,
  },
  {
    label = "control-bearing compatibility name",
    change = function(report)
      report.names[1] = "build\nchanged"
    end,
  },
  {
    label = "missing compatibility field",
    change = function(report)
      report.help.attach = nil
    end,
  },
  {
    label = "changed configuration key",
    change = function(report)
      report.agents.build.configuration = {}
    end,
  },
  {
    label = "changed policy key",
    change = function(report)
      report.agents.build.permission[1].unexpected = true
    end,
  },
  {
    label = "unknown compatibility field",
    change = function(report)
      report.unexpected = true
    end,
  },
  {
    label = "missing pure-mode help",
    change = function(report)
      report.help.root[1] = "--unsafe"
    end,
  },
}
for _, case in ipairs(invalid_compatibility_cases) do
  local report = vim.deepcopy(good)
  case.change(report)
  rejected(function()
    return managed.validate_compatibility(report)
  end, case.label)
end

local oversized = vim.deepcopy(good)
oversized.unexpected = string.rep("x", 1024 * 1024)
rejected(function()
  return managed.validate_compatibility(oversized)
end, "oversized report")

local profile_token = string.rep("b", 32)
local profile_fingerprint = string.rep("c", 64)
local helper_profile = {
  schema = 1,
  version = "1.18.30",
  profile_root = "/state/identity/backends/opencode/profiles/" .. profile_token,
  fingerprint = profile_fingerprint,
  config_source = "/state/identity/backends/opencode/profiles/" .. profile_token .. "/xdg-config",
  auth_source = "/state/identity/backends/opencode/profiles/"
    .. profile_token
    .. "/credentials/auth.json",
  home_mask_source = "/state/identity/backends/opencode/profiles/"
    .. profile_token
    .. "/empty-home-opencode",
  auth = "authenticated",
  credential_count = 2,
}
local public_profile = {
  schema = 1,
  version = "1.18.30",
  profile_root = helper_profile.profile_root,
  fingerprint = helper_profile.fingerprint,
  config_source = helper_profile.config_source,
  auth_source = helper_profile.auth_source,
  home_mask_source = helper_profile.home_mask_source,
}
local launch_identity = { key = string.rep("a", 32), root = "/work/repo" }
local launch_paths = {
  backend_state = "/state/identity/backends/opencode",
  global_opencode_data = "/home/user/.local/share/opencode",
  home_agents = "/home/user/AGENTS.md",
  profile_helper = "/config/nvim/scripts/nvim-ai-opencode-profile.py",
  python = "/usr/bin/python3",
  grants = {},
}

local provider_start_canaries = {
  controller_starts = 0,
  process_starts = 0,
}
local validation_module = require("ai.backends.opencode_validation")
local original_validation_new = validation_module.new
local original_vim_system = vim.system
local CONTROLLER_START_CANARY = "provider-free controller construction canary"
local PROCESS_START_CANARY = "provider-free process spawn canary"

local function trip_provider_start_canary(field, diagnostic)
  local count = provider_start_canaries[field]
  assert(type(count) == "number" and count >= 0 and count < 4)
  provider_start_canaries[field] = count + 1
  error(diagnostic, 0)
end

local function provider_free_adapter_assertions()
  local controller_ok, controller_error = pcall(registry_module._test.new_opencode_validation, {})
  eq(controller_ok, false, "controller construction canary is armed")
  eq(controller_error, CONTROLLER_START_CANARY, "controller construction canary diagnostic")

  local process_completion_count = 0
  local process_completion
  local process_category
  local process_handle = registry_module._test.bounded_system_async(
    { "/provider-free/process-canary" },
    { text = true },
    { stdout = 0, stderr = 0 },
    function(result, category)
      process_completion_count = process_completion_count + 1
      process_completion = vim.deepcopy(result)
      process_category = category
    end,
    {
      schedule = function(callback)
        callback()
      end,
    }
  )
  assert(type(process_handle) == "table", "process start canary returned no runner handle")
  eq(process_completion_count, 1, "process start canary completes exactly once")
  eq(process_category, "probe-failure", "process start canary category")
  eq(process_completion, {
    code = 126,
    signal = 0,
    stdout = "",
    stderr = "",
    stdout_overflow = false,
    stderr_overflow = false,
    system_error = true,
    process_started = false,
    process_exited = false,
  }, "process start canary result")
  eq(provider_start_canaries, {
    controller_starts = 1,
    process_starts = 1,
  }, "provider-free start canaries are reachable")
  provider_start_canaries.controller_starts = 0
  provider_start_canaries.process_starts = 0
  eq(provider_start_canaries, {
    controller_starts = 0,
    process_starts = 0,
  }, "provider-free start canaries are reset before adapter assertions")

  local function adapter_fixture(options)
    local settings = options or {}
    local calls = {
      prepare = {},
      inspect = {},
      compatibility = {
        snapshots = 0,
        reports = 0,
      },
    }
    local compatibility_snapshot = {
      state = "ready",
      installed = true,
      executable = "/usr/bin/opencode",
      version = "1.18.30",
      category = "",
      queued = false,
    }
    local compatibility_report = vim.deepcopy(good)
    assert(managed.validate_compatibility(compatibility_report))
    local function count_compatibility_call(field)
      local count = calls.compatibility[field]
      assert(type(count) == "number" and count >= 0 and count < 8)
      calls.compatibility[field] = count + 1
    end
    local validation = {
      snapshot = function()
        count_compatibility_call("snapshots")
        return vim.deepcopy(compatibility_snapshot)
      end,
      report = function()
        count_compatibility_call("reports")
        return vim.deepcopy(compatibility_report)
      end,
    }
    local adapter = require("ai.backends.opencode").new({
      validate_launch = function(candidate_identity, candidate_paths)
        eq(candidate_identity, launch_identity, "managed adapter launch identity")
        eq(candidate_paths.backend_state, launch_paths.backend_state, "managed adapter state")
        return {
          root = candidate_identity.root,
          backend_state = candidate_paths.backend_state,
          grants = vim.deepcopy(candidate_paths.grants),
        }
      end,
      resolve_executable = function(name)
        eq(name, "opencode", "managed adapter executable")
        return "/usr/bin/opencode"
      end,
      opencode_compatibility_snapshot = function()
        return validation.snapshot()
      end,
      opencode_compatibility_report = function()
        return validation.report()
      end,
      profile_token = function()
        return profile_token
      end,
      prepare_opencode_profile = function(request)
        calls.prepare[#calls.prepare + 1] = vim.deepcopy(request)
        if settings.prepare_exception then
          error(settings.prepare_exception)
        end
        if settings.prepare_error then
          return nil, settings.prepare_error
        end
        return vim.deepcopy(settings.prepare_profile or helper_profile)
      end,
      inspect_opencode_profile = function(request)
        calls.inspect[#calls.inspect + 1] = vim.deepcopy(request)
        if settings.inspect_exception then
          error(settings.inspect_exception)
        end
        if settings.inspect_error then
          return nil, settings.inspect_error
        end
        return vim.deepcopy(settings.inspect_profile or helper_profile)
      end,
      port = function()
        return 43123
      end,
      password = function()
        return "0123456789abcdef0123456789abcdef"
      end,
      format_context = function()
        return ""
      end,
    })
    return adapter, calls
  end

  local function assert_compatibility_reads(calls, snapshots, reports, label)
    eq(calls.compatibility, {
      snapshots = snapshots,
      reports = reports,
    }, label)
    eq(provider_start_canaries, {
      controller_starts = 0,
      process_starts = 0,
    }, label .. " starts no controller or process")
  end

  local managed_adapter, managed_calls = adapter_fixture()
  local managed_launch = assert(managed_adapter:new_session(launch_identity, launch_paths))
  assert_compatibility_reads(managed_calls, 1, 1, "new launch reads passive compatibility")
  eq(managed_launch.managed_profile, public_profile, "helper-private profile fields are stripped")
  eq(assert(managed_adapter:profile_reference(managed_launch)), {
    token = profile_token,
    fingerprint = profile_fingerprint,
    version = "1.18.30",
  }, "adapter profile reference is bounded and secret-free")
  eq(#managed_calls.prepare, 1, "first activation prepares one fresh profile")
  eq(managed_calls.prepare[1], request, "adapter sends the exact managed request to prepare")

  local reference_paths = vim.deepcopy(launch_paths)
  reference_paths.opencode_profile = {
    token = profile_token,
    fingerprint = profile_fingerprint,
    version = "1.18.30",
  }
  local reused =
    assert(managed_adapter:resume_session(launch_identity, reference_paths, "ses_test123"))
  assert_compatibility_reads(managed_calls, 2, 2, "resume launch reads passive compatibility")
  eq(reused.managed_profile, public_profile, "active relaunch reuses the inspected profile")
  eq(#managed_calls.prepare, 1, "profile reuse does not resnapshot credentials or instructions")
  eq(managed_calls.inspect, {
    {
      schema = 1,
      backend_state = launch_paths.backend_state,
      token = profile_token,
      identity_key = launch_identity.key,
      root = launch_identity.root,
      version = "1.18.30",
      fingerprint = profile_fingerprint,
    },
  }, "profile inspection receives only the nonsecret identity-bound reference")
  eq(
    assert(
      managed_adapter:validate_profile(
        reference_paths.opencode_profile,
        launch_identity,
        launch_paths
      )
    ),
    public_profile,
    "explicit profile validation returns the stripped public profile"
  )
  assert_compatibility_reads(
    managed_calls,
    2,
    2,
    "explicit profile validation starts no compatibility work"
  )
  eq(#managed_calls.prepare, 1, "explicit validation never prepares a profile")

  local invalid_reference_adapter, invalid_reference_calls = adapter_fixture({
    inspect_error = "profile-secret-canary",
  })
  local invalid_reference, invalid_reference_error =
    invalid_reference_adapter:resume_session(launch_identity, reference_paths, "ses_test123")
  eq(invalid_reference, nil, "invalid supplied reference fails closed")
  assert(type(invalid_reference_error) == "string" and invalid_reference_error ~= "")
  assert(#invalid_reference_error <= 256, "invalid reference diagnostic is unbounded")
  assert(
    not invalid_reference_error:find("profile-secret-canary", 1, true),
    "invalid reference diagnostic leaks helper output"
  )
  assert_compatibility_reads(
    invalid_reference_calls,
    1,
    1,
    "invalid resume reads passive compatibility once"
  )
  eq(#invalid_reference_calls.prepare, 0, "invalid supplied reference has no prepare fallback")

  for _, field in ipairs({
    "schema",
    "version",
    "profile_root",
    "fingerprint",
    "config_source",
    "auth_source",
    "home_mask_source",
    "auth",
    "credential_count",
  }) do
    local changed = vim.deepcopy(helper_profile)
    if field == "schema" then
      changed[field] = 2
    elseif field == "version" then
      changed[field] = "1.18.19"
    elseif field == "auth" then
      changed[field] = "unauthenticated"
    elseif field == "credential_count" then
      changed[field] = 0
    else
      changed[field] = tostring(changed[field]) .. "-changed"
    end
    local mismatch_adapter, mismatch_calls = adapter_fixture({ inspect_profile = changed })
    rejected(function()
      return mismatch_adapter:validate_profile(
        reference_paths.opencode_profile,
        launch_identity,
        launch_paths
      )
    end, "profile inspection mismatch: " .. field)
    assert_compatibility_reads(
      mismatch_calls,
      0,
      0,
      "profile mismatch validation starts no compatibility work: " .. field
    )
  end

  eq(provider_start_canaries, {
    controller_starts = 0,
    process_starts = 0,
  }, "provider-free adapter prefix starts no controller or process")
end

local adapter_prefix_ok, adapter_prefix_error = pcall(function()
  validation_module.new = function()
    trip_provider_start_canary("controller_starts", CONTROLLER_START_CANARY)
  end
  vim.system = function()
    trip_provider_start_canary("process_starts", PROCESS_START_CANARY)
  end
  provider_free_adapter_assertions()
end)
local restore_validation_ok = pcall(function()
  validation_module.new = original_validation_new
end)
local restore_system_ok = pcall(function()
  vim.system = original_vim_system
end)
assert(restore_validation_ok, "controller constructor restoration failed")
assert(restore_system_ok, "process entry-point restoration failed")
assert(validation_module.new == original_validation_new, "controller constructor was not restored")
assert(vim.system == original_vim_system, "process entry point was not restored")
assert(adapter_prefix_ok, adapter_prefix_error)

local helper_argv
local helper_options
local helper_revalidations = {}
local helper_result =
  assert(registry_module._test.invoke_profile_helper(launch_paths, "prepare", request, {
    revalidate = function(path)
      helper_revalidations[#helper_revalidations + 1] = path
      return true
    end,
    run = function(argv, options)
      helper_argv = vim.deepcopy(argv)
      helper_options = vim.deepcopy(options)
      return {
        code = 0,
        signal = 0,
        stdout = vim.json.encode(helper_profile) .. "\n",
        stderr = "",
      }
    end,
  }))
eq(helper_result, helper_profile, "prepare helper report")
eq(helper_argv, {
  "/usr/bin/python3",
  "-I",
  "-B",
  "/config/nvim/scripts/nvim-ai-opencode-profile.py",
  "--operation",
  "prepare",
}, "exact isolated profile-helper argv")
eq(helper_options.clear_env, true, "profile helper clears inherited environment")
eq(helper_options.env, { LANG = "C.UTF-8" }, "profile helper receives only the locale")
eq(helper_options.text, true, "profile helper uses text pipes")
eq(helper_options.timeout, 5000, "profile helper timeout")
eq(vim.json.decode(helper_options.stdin), request, "profile helper receives canonical request JSON")
eq(
  helper_revalidations,
  { "/usr/bin/python3", "/config/nvim/scripts/nvim-ai-opencode-profile.py" },
  "profile helper revalidates canonical Python and helper paths"
)

local subprocess_boundary_failures = {}
local killed_helper_root = vim.fn.tempname()
assert(vim.fn.mkdir(killed_helper_root, "p", 448) == 1)
local killed_helper = killed_helper_root .. "/profile-helper"
vim.fn.writefile({
  "#!/bin/sh",
  "printf '%s\\n' " .. vim.fn.shellescape(vim.json.encode(helper_profile)),
  "kill -KILL $$",
}, killed_helper)
assert(vim.uv.fs_chmod(killed_helper, 448))
local killed_helper_stat = assert(vim.uv.fs_lstat(killed_helper))
eq(require("bit").band(killed_helper_stat.mode, 511), 448, "self-signaling helper fixture mode")
local killed_helper_report, killed_helper_error = registry_module._test.invoke_profile_helper(
  { python = killed_helper, profile_helper = killed_helper },
  "prepare",
  request,
  {
    revalidate = function()
      return true
    end,
  }
)
if killed_helper_report ~= nil then
  subprocess_boundary_failures[#subprocess_boundary_failures + 1] =
    "real self-SIGKILL helper returned a profile report"
end
if
  type(killed_helper_error) ~= "string"
  or killed_helper_error == ""
  or killed_helper_error:find(profile_token, 1, true)
then
  subprocess_boundary_failures[#subprocess_boundary_failures + 1] =
    "real self-SIGKILL helper returned a non-generic diagnostic"
end
assert(vim.fn.delete(killed_helper_root, "rf") == 0)

for _, case in ipairs({
  { label = "signaled injected helper", signal = 9 },
  { label = "missing-signal injected helper", omit_signal = true },
}) do
  local report, helper_error =
    registry_module._test.invoke_profile_helper(launch_paths, "prepare", request, {
      revalidate = function()
        return true
      end,
      run = function()
        local result = {
          code = 0,
          stdout = vim.json.encode(helper_profile) .. "\n",
          stderr = "",
        }
        if not case.omit_signal then
          result.signal = case.signal
        end
        return result
      end,
    })
  if report ~= nil then
    subprocess_boundary_failures[#subprocess_boundary_failures + 1] = case.label
      .. " returned a profile report"
  end
  if type(helper_error) ~= "string" or helper_error == "" then
    subprocess_boundary_failures[#subprocess_boundary_failures + 1] = case.label
      .. " returned no generic diagnostic"
  end
end

for _, failure in ipairs({
  { stdout = "", stderr = "credential-secret-canary", code = 2 },
  { stdout = "{malformed credential-secret-canary", stderr = "", code = 0 },
  { stdout = string.rep("x", 65537), stderr = "", code = 0 },
  { stdout = "", stderr = string.rep("x", 65537), code = 0 },
  {
    stdout = vim.json.encode(helper_profile) .. "\n",
    stderr = "",
    code = 0,
    stdout_overflow = true,
  },
  {
    stdout = vim.json.encode(helper_profile) .. "\n",
    stderr = "",
    code = 0,
    stderr_overflow = true,
  },
  {
    stdout = vim.json.encode(helper_profile) .. "\n",
    stderr = "",
    code = 0,
    system_error = true,
  },
}) do
  local report, err =
    registry_module._test.invoke_profile_helper(launch_paths, "prepare", request, {
      revalidate = function()
        return true
      end,
      run = function()
        return {
          code = failure.code,
          signal = 0,
          stdout = failure.stdout,
          stderr = failure.stderr,
          stdout_overflow = failure.stdout_overflow,
          stderr_overflow = failure.stderr_overflow,
          system_error = failure.system_error,
        }
      end,
    })
  eq(report, nil, "unsafe helper result is rejected")
  assert(type(err) == "string" and err ~= "" and #err <= 256, "helper error is not bounded")
  assert(not err:find("credential-secret-canary", 1, true), "helper error leaks secret output")
end

local semantic_probe_argv
local semantic_probe_options
local semantic_probe = registry_module._test.read_only_probe("/usr/bin/opencode", { "--version" }, {
  resolve = function(name)
    assert(name == "bwrap" or name == "python3", "unexpected semantic probe tool")
    return "/usr/bin/" .. name
  end,
  revalidate = function(path)
    assert(path == "/usr/bin/opencode" or path == "/usr/bin/bwrap" or path == "/usr/bin/python3")
    return true
  end,
  lstat = function()
    return { type = "directory", uid = 1000, mode = 448 }
  end,
  getuid = function()
    return 1000
  end,
  environment = { HOME = "/tmp/nvim-ai-probe/home", OPENCODE_PURE = "true" },
  working_directory = "/tmp/nvim-ai-probe",
  read_only_mounts = {
    { source = "/tmp/probe-home", destination = "/tmp/nvim-ai-probe/home" },
    { source = "/tmp/probe-config", destination = "/tmp/nvim-ai-probe/xdg-config" },
  },
  writable_mounts = {
    { source = "/tmp/probe-data", destination = "/tmp/nvim-ai-probe/xdg-data" },
    { source = "/tmp/probe-cache", destination = "/tmp/nvim-ai-probe/xdg-cache" },
    { source = "/tmp/probe-state", destination = "/tmp/nvim-ai-probe/xdg-state" },
  },
  inspect_artifacts = function()
    return true
  end,
  run = function(argv, options)
    semantic_probe_argv = vim.deepcopy(argv)
    semantic_probe_options = vim.deepcopy(options)
    return { code = 0, signal = 0, stdout = "1.18.30\n", stderr = "" }
  end,
})
eq(semantic_probe.code, 0, "semantic Bubblewrap probe result")
eq(semantic_probe_argv, {
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
  "/tmp/probe-home",
  "/tmp/nvim-ai-probe/home",
  "--ro-bind",
  "/tmp/probe-config",
  "/tmp/nvim-ai-probe/xdg-config",
  "--bind",
  "/tmp/probe-data",
  "/tmp/nvim-ai-probe/xdg-data",
  "--bind",
  "/tmp/probe-cache",
  "/tmp/nvim-ai-probe/xdg-cache",
  "--bind",
  "/tmp/probe-state",
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
}, "exact semantic Bubblewrap probe argv")
eq(semantic_probe_options.clear_env, true, "semantic probe clears the environment")
eq(semantic_probe_options.env, {
  HOME = "/tmp/nvim-ai-probe/home",
  OPENCODE_PURE = "true",
}, "semantic probe admits only the exact environment")
eq(semantic_probe_options.timeout, 2000, "semantic probe command timeout")

local raised_probe_inspected = false
local raised_probe = registry_module._test.read_only_probe("/usr/bin/opencode", {}, {
  resolve = function()
    return "/usr/bin/bwrap"
  end,
  revalidate = function()
    return true
  end,
  run = function()
    error("probe-artifact-secret-canary")
  end,
  inspect_artifacts = function(result)
    raised_probe_inspected = type(result) == "string"
    return true
  end,
})
assert(raised_probe_inspected, "probe artifacts were not inspected after runner exception")
eq(raised_probe.code, 126, "runner exception fails the probe boundary")
assert(
  not raised_probe.stderr:find("probe-artifact-secret-canary", 1, true),
  "runner exception leaked through the probe boundary"
)

for _, case in ipairs({
  { label = "signaled read-only probe", signal = 9 },
  { label = "missing-signal read-only probe", omit_signal = true },
}) do
  local inspected = false
  local result = registry_module._test.read_only_probe("/usr/bin/opencode", {}, {
    resolve = function()
      return "/usr/bin/bwrap"
    end,
    revalidate = function()
      return true
    end,
    run = function()
      local completed = {
        code = 0,
        stdout = "read-only-signal-secret-canary",
        stderr = "",
      }
      if not case.omit_signal then
        completed.signal = case.signal
      end
      return completed
    end,
    inspect_artifacts = function(completed)
      inspected = type(completed) == "table"
        and completed.stdout == "read-only-signal-secret-canary"
      return true
    end,
  })
  if not inspected then
    subprocess_boundary_failures[#subprocess_boundary_failures + 1] = case.label
      .. " skipped artifact inspection"
  end
  if
    result.code ~= 126
    or result.signal ~= 0
    or result.stdout ~= ""
    or type(result.stderr) ~= "string"
    or result.stderr == ""
    or result.stderr:find("read-only-signal-secret-canary", 1, true)
  then
    subprocess_boundary_failures[#subprocess_boundary_failures + 1] = case.label
      .. " crossed the subprocess boundary"
  end
end

local bounded_system = registry_module._test.bounded_system
assert(type(bounded_system) == "function", "bounded production runner is not exposed for testing")

local early_overflow_kills = 0
local early_overflow_signal
local early_overflow = bounded_system(
  { "/fake/early-overflow" },
  { text = true, timeout = 10 },
  { stdout = 8, stderr = 8 },
  function(_, options)
    options.stdout(nil, "12345678stdout-secret-canary")
    return {
      kill = function(_, signal)
        early_overflow_kills = early_overflow_kills + 1
        early_overflow_signal = signal
        error("kill-secret-canary")
      end,
      wait = function()
        return { code = 0, signal = 0 }
      end,
    }
  end
)
eq(early_overflow.code, 126, "overflow before process assignment fails closed")
eq(early_overflow.stdout, "", "early overflow discards retained stdout")
eq(early_overflow.stderr, "", "early overflow has generic stderr")
eq(early_overflow.stdout_overflow, true, "early stdout overflow is marked")
eq(early_overflow_kills, 1, "pending overflow kills after process assignment")
eq(early_overflow_signal, "sigkill", "early overflow uses the hard kill boundary")

local late_overflow_kills = 0
local late_overflow_signal
local late_overflow = bounded_system(
  { "/fake/late-overflow" },
  { text = true, timeout = 10 },
  { stdout = 8, stderr = 8 },
  function(_, options)
    return {
      kill = function(_, signal)
        late_overflow_kills = late_overflow_kills + 1
        late_overflow_signal = signal
      end,
      wait = function()
        options.stderr(nil, "12345678stderr-secret-canary")
        return { code = 0, signal = 0 }
      end,
    }
  end
)
eq(late_overflow.code, 126, "stderr overflow fails closed")
eq(late_overflow.stdout, "", "stderr overflow discards stdout")
eq(late_overflow.stderr, "", "stderr overflow discards retained stderr")
eq(late_overflow.stderr_overflow, true, "stderr overflow is marked")
eq(late_overflow_kills, 1, "stderr overflow kills an assigned process")
eq(late_overflow_signal, "sigkill", "stderr overflow uses the hard kill boundary")

for _, case in ipairs({
  {
    label = "stream callback error",
    system = function(_, options)
      options.stdout("callback-secret-canary", nil)
      return {
        kill = function() end,
        wait = function()
          return { code = 0, signal = 0 }
        end,
      }
    end,
  },
  {
    label = "invalid callback data",
    system = function(_, options)
      options.stderr(nil, { "callback-secret-canary" })
      return {
        kill = function() end,
        wait = function()
          return { code = 0, signal = 0 }
        end,
      }
    end,
  },
  {
    label = "spawn error",
    system = function()
      error("spawn-secret-canary")
    end,
  },
  {
    label = "wait error",
    system = function(_, options)
      return {
        kill = function() end,
        wait = function()
          options.stdout(nil, "bounded")
          error("wait-secret-canary")
        end,
      }
    end,
  },
}) do
  local failed = bounded_system(
    { "/fake/" .. case.label },
    { text = true, timeout = 10 },
    { stdout = 8, stderr = 8 },
    case.system
  )
  eq(failed.code, 126, case.label .. " fails closed")
  eq(failed.stdout, "", case.label .. " returns no captured stdout")
  eq(failed.stderr, "", case.label .. " returns no captured stderr")
  eq(failed.system_error, true, case.label .. " is marked as a runner error")
end

local exact_bounded = bounded_system(
  { "/fake/exact-output" },
  { text = true, timeout = 10 },
  { stdout = 16, stderr = 16 },
  function(_, options)
    return {
      kill = function()
        error("successful bounded process was killed")
      end,
      wait = function()
        options.stdout(nil, "byte-")
        options.stdout(nil, "exact\n")
        options.stderr(nil, "warning\n")
        options.stdout(nil, nil)
        options.stderr(nil, nil)
        return { code = 0, signal = 0 }
      end,
    }
  end
)
eq(exact_bounded.code, 0, "bounded runner preserves successful code")
eq(exact_bounded.signal, 0, "bounded runner preserves successful signal")
eq(exact_bounded.stdout, "byte-exact\n", "bounded runner preserves stdout bytes")
eq(exact_bounded.stderr, "warning\n", "bounded runner preserves stderr bytes")
eq(exact_bounded.stdout_overflow, false, "bounded stdout is not marked overflow")
eq(exact_bounded.stderr_overflow, false, "bounded stderr is not marked overflow")
eq(exact_bounded.system_error, false, "bounded success is not marked as a runner error")

local real_probe_root = vim.fn.tempname()
assert(vim.fn.mkdir(real_probe_root, "p", 448) == 1, "create real probe fixture root")
local real_probe_home = real_probe_root .. "/home"
local real_probe_config = real_probe_root .. "/xdg-config"
assert(vim.fn.mkdir(real_probe_home, "", 448) == 1, "create real probe home")
assert(vim.fn.mkdir(real_probe_config, "", 448) == 1, "create real probe config")
local true_executable = assert(require("ai.tools").resolve("true"))
local real_probe = registry_module._test.read_only_probe(true_executable, {}, {
  environment = { HOME = "/tmp/nvim-ai-probe/home" },
  working_directory = "/tmp/nvim-ai-probe",
  read_only_mounts = {
    { source = real_probe_home, destination = "/tmp/nvim-ai-probe/home" },
    { source = real_probe_config, destination = "/tmp/nvim-ai-probe/xdg-config" },
  },
})
vim.fn.delete(real_probe_root, "rf")
assert(real_probe.code == 0, "provider-free real Bubblewrap probe failed: " .. real_probe.stderr)

local output_boundary_root = vim.fs.joinpath(
  assert(vim.env.HOME),
  ".config",
  ".nvim-ai-output-boundary-" .. vim.fn.sha256(vim.fn.tempname()):sub(1, 16)
)
assert(vim.fn.mkdir(output_boundary_root, "p", 448) == 1, "create output-boundary root")
local output_boundary_paths = {
  home = output_boundary_root .. "/home",
  config = output_boundary_root .. "/xdg-config",
  data = output_boundary_root .. "/xdg-data",
  cache = output_boundary_root .. "/xdg-cache",
  state = output_boundary_root .. "/xdg-state",
}
for _, path in pairs(output_boundary_paths) do
  assert(vim.fn.mkdir(path, "", 448) == 1, "create output-boundary directory")
end

local bounded_executable = output_boundary_root .. "/bounded-output"
vim.fn.writefile({
  "#!/bin/sh",
  "printf 'bounded-stdout\\n'",
  "printf 'bounded-stderr\\n' >&2",
}, bounded_executable)
assert(vim.uv.fs_chmod(bounded_executable, 448))

local probe_flood_executable = output_boundary_root .. "/probe-stdout-flood"
vim.fn.writefile({
  "#!/bin/sh",
  "trap '' TERM",
  "printf 'probe-output-secret-canary'",
  "head -c 1114112 /dev/zero | tr '\\000' x",
  "sleep 1",
  'printf reached > "$XDG_CACHE_HOME/post-overflow"',
}, probe_flood_executable)
assert(vim.uv.fs_chmod(probe_flood_executable, 448))

local helper_stdout_sentinel = output_boundary_root .. "/helper-stdout-completed"
local helper_stdout_executable = output_boundary_root .. "/helper-stdout-flood"
vim.fn.writefile({
  "#!/bin/sh",
  "trap '' TERM",
  "printf 'helper-stdout-secret-canary'",
  "head -c 70000 /dev/zero | tr '\\000' x",
  "sleep 1",
  "printf reached > " .. vim.fn.shellescape(helper_stdout_sentinel),
}, helper_stdout_executable)
assert(vim.uv.fs_chmod(helper_stdout_executable, 448))

local helper_stderr_sentinel = output_boundary_root .. "/helper-stderr-completed"
local helper_stderr_executable = output_boundary_root .. "/helper-stderr-flood"
vim.fn.writefile({
  "#!/bin/sh",
  "trap '' TERM",
  "printf 'helper-stderr-secret-canary' >&2",
  "head -c 70000 /dev/zero | tr '\\000' x >&2",
  "sleep 1",
  "printf reached > " .. vim.fn.shellescape(helper_stderr_sentinel),
}, helper_stderr_executable)
assert(vim.uv.fs_chmod(helper_stderr_executable, 448))

local common_output_probe_options = {
  environment = { HOME = "/tmp/nvim-ai-probe/home" },
  working_directory = "/tmp/nvim-ai-probe",
  read_only_mounts = {
    { source = output_boundary_paths.home, destination = "/tmp/nvim-ai-probe/home" },
    { source = output_boundary_paths.config, destination = "/tmp/nvim-ai-probe/xdg-config" },
  },
}
local bounded_probe = registry_module._test.read_only_probe(
  assert(require("ai.tools").resolve(bounded_executable)),
  {},
  common_output_probe_options
)
eq(bounded_probe.code, 0, "bounded default probe succeeds")
eq(bounded_probe.stdout, "bounded-stdout\n", "bounded default probe stdout remains byte-exact")
eq(bounded_probe.stderr, "bounded-stderr\n", "bounded default probe stderr remains byte-exact")

local flood_inspected = false
local flood_created_sentinel = false
local flood_inspection_result
local flood_probe_options = vim.deepcopy(common_output_probe_options)
flood_probe_options.environment = {
  HOME = "/tmp/nvim-ai-probe/home",
  XDG_CACHE_HOME = "/tmp/nvim-ai-probe/xdg-cache",
}
flood_probe_options.writable_mounts = {
  { source = output_boundary_paths.data, destination = "/tmp/nvim-ai-probe/xdg-data" },
  { source = output_boundary_paths.cache, destination = "/tmp/nvim-ai-probe/xdg-cache" },
  { source = output_boundary_paths.state, destination = "/tmp/nvim-ai-probe/xdg-state" },
}
flood_probe_options.inspect_artifacts = function(result)
  flood_inspected = true
  flood_inspection_result = vim.deepcopy(result)
  flood_created_sentinel = vim.uv.fs_lstat(output_boundary_paths.cache .. "/post-overflow") ~= nil
  return true
end
local flood_probe = registry_module._test.read_only_probe(
  assert(require("ai.tools").resolve(probe_flood_executable)),
  {},
  flood_probe_options
)

local helper_boundary_failures = {}
for _, case in ipairs({
  {
    label = "stdout",
    executable = helper_stdout_executable,
    sentinel = helper_stdout_sentinel,
    canary = "helper-stdout-secret-canary",
  },
  {
    label = "stderr",
    executable = helper_stderr_executable,
    sentinel = helper_stderr_sentinel,
    canary = "helper-stderr-secret-canary",
  },
}) do
  local report, helper_error = registry_module._test.invoke_profile_helper(
    { python = case.executable, profile_helper = case.executable },
    "prepare",
    request,
    {
      revalidate = function()
        return true
      end,
    }
  )
  if report ~= nil then
    helper_boundary_failures[#helper_boundary_failures + 1] = case.label
      .. " flood returned a helper report"
  end
  if
    type(helper_error) ~= "string"
    or helper_error == ""
    or helper_error:find(case.canary, 1, true)
  then
    helper_boundary_failures[#helper_boundary_failures + 1] = case.label
      .. " flood returned a non-generic helper diagnostic"
  end
  if vim.uv.fs_lstat(case.sentinel) then
    helper_boundary_failures[#helper_boundary_failures + 1] = case.label
      .. " flood process was not killed at the stream limit"
  end
end

vim.fn.delete(output_boundary_root, "rf")
local output_boundary_failures = {}
if not flood_inspected then
  output_boundary_failures[#output_boundary_failures + 1] =
    "probe artifacts were not inspected after output overflow"
end
if flood_created_sentinel then
  output_boundary_failures[#output_boundary_failures + 1] =
    "probe stdout flood was not killed at the stream limit"
end
if flood_probe.code ~= 126 or flood_probe.stderr ~= "probe output exceeded configured limit" then
  output_boundary_failures[#output_boundary_failures + 1] =
    "probe stdout flood returned a non-generic diagnostic"
end
if
  type(flood_inspection_result) ~= "table"
  or flood_inspection_result.stdout_overflow ~= true
  or flood_inspection_result.stderr_overflow ~= false
then
  output_boundary_failures[#output_boundary_failures + 1] =
    "artifact inspection did not receive the marked stdout overflow"
end
if
  flood_probe.stdout ~= ""
  or flood_probe.stderr:find("probe-output-secret-canary", 1, true)
  or flood_probe.stdout:find("probe-output-secret-canary", 1, true)
then
  output_boundary_failures[#output_boundary_failures + 1] =
    "probe stdout flood returned captured output"
end
vim.list_extend(output_boundary_failures, helper_boundary_failures)
assert(#output_boundary_failures == 0, table.concat(output_boundary_failures, "; "))

local artifact_failures = {}
local sentinel_root = vim.fs.joinpath(
  assert(vim.env.HOME),
  ".config",
  ".nvim-ai-opencode-probe-" .. vim.fn.sha256(vim.fn.tempname()):sub(1, 16)
)
assert(vim.fn.mkdir(sentinel_root, "p", 448) == 1, "create sentinel probe root")
local sentinel_paths = {
  home = sentinel_root .. "/home",
  config = sentinel_root .. "/xdg-config",
  data = sentinel_root .. "/xdg-data",
  cache = sentinel_root .. "/xdg-cache",
  state = sentinel_root .. "/xdg-state",
}
for _, path in pairs(sentinel_paths) do
  assert(vim.fn.mkdir(path, "", 448) == 1, "create sentinel probe directory")
end
local sentinel_executable = sentinel_root .. "/write-xdg-sentinel"
vim.fn.writefile({
  "#!/bin/sh",
  'mkdir -p "$XDG_CACHE_HOME"',
  'printf forbidden > "$XDG_CACHE_HOME/forbidden-sentinel"',
  "exit 0",
}, sentinel_executable)
assert(vim.uv.fs_chmod(sentinel_executable, 448))
local resolved_sentinel = assert(require("ai.tools").resolve(sentinel_executable))
local sentinel_probe = registry_module._test.read_only_probe(resolved_sentinel, {}, {
  environment = {
    HOME = "/tmp/nvim-ai-probe/home",
    XDG_CACHE_HOME = "/tmp/nvim-ai-probe/xdg-cache",
    XDG_CONFIG_HOME = "/tmp/nvim-ai-probe/xdg-config",
    XDG_DATA_HOME = "/tmp/nvim-ai-probe/xdg-data",
    XDG_STATE_HOME = "/tmp/nvim-ai-probe/xdg-state",
  },
  working_directory = "/tmp/nvim-ai-probe",
  read_only_mounts = {
    { source = sentinel_paths.home, destination = "/tmp/nvim-ai-probe/home" },
    { source = sentinel_paths.config, destination = "/tmp/nvim-ai-probe/xdg-config" },
  },
  writable_mounts = {
    { source = sentinel_paths.data, destination = "/tmp/nvim-ai-probe/xdg-data" },
    { source = sentinel_paths.cache, destination = "/tmp/nvim-ai-probe/xdg-cache" },
    { source = sentinel_paths.state, destination = "/tmp/nvim-ai-probe/xdg-state" },
  },
  inspect_artifacts = function()
    if vim.uv.fs_lstat(sentinel_paths.cache .. "/forbidden-sentinel") then
      return nil, "probe-artifact-secret-canary"
    end
    return true
  end,
})
vim.fn.delete(sentinel_root, "rf")
if sentinel_probe.code ~= 125 then
  artifact_failures[#artifact_failures + 1] = string.format(
    "real Bubblewrap XDG sentinel was not detected (code=%s, stderr=%s)",
    tostring(sentinel_probe.code),
    sentinel_probe.stderr
  )
else
  assert(
    not sentinel_probe.stderr:find("probe-artifact-secret-canary", 1, true),
    "real artifact diagnostic leaks raw evidence"
  )
end

assert(#artifact_failures == 0, table.concat(artifact_failures, "; "))

local cleanup_owned_probe_tree = registry_module._test.cleanup_owned_probe_tree
assert(type(cleanup_owned_probe_tree) == "function", "owned-tree cleanup validator is unavailable")
assert(#subprocess_boundary_failures == 0, table.concat(subprocess_boundary_failures, "; "))

local fixed_lock = "0a009c556ac8352fed53ef8323a3a97270935d30.lock"

local function valid_lock_metadata()
  return table.concat({
    "{",
    '  "token": "00112233-4455-4677-8899-aabbccddeeff",',
    '  "pid": 2,',
    string.format('  "hostname": %s,', vim.json.encode(assert(vim.uv.os_gethostname()))),
    '  "createdAt": "2026-08-27T12:00:00.000Z"',
    "}",
  }, "\n")
end

local lock_fixture = (function()
  local methods = {}

  local function contains(fixture, path)
    local root = vim.fs.normalize(fixture.root)
    local normalized = vim.fs.normalize(path)
    return normalized == root or normalized:sub(1, #root + 1) == root .. "/"
  end

  local function assert_node(fixture, path, node_type, mode)
    assert(contains(fixture, path), "lock fixture path escaped its private root")
    local stat = assert(vim.uv.fs_lstat(path), "lock fixture node is absent")
    assert(stat.type == node_type, "lock fixture node has the wrong type")
    assert(stat.uid == vim.uv.getuid(), "lock fixture node has the wrong owner")
    eq(require("bit").band(stat.mode, 511), mode, "lock fixture node mode")
    return stat
  end

  local function create_directory(fixture, path)
    assert(contains(fixture, path), "lock fixture directory escaped its private root")
    assert(vim.fn.mkdir(path, "", 448) == 1, "create exclusive lock fixture directory")
    assert_node(fixture, path, "directory", 448)
  end

  local function create_file(fixture, path, bytes)
    assert(contains(fixture, path), "lock fixture file escaped its private root")
    local descriptor = assert(vim.uv.fs_open(path, "wx", 384), "create exclusive lock fixture file")
    local offset = 0
    while offset < #bytes do
      local written = assert(vim.uv.fs_write(descriptor, bytes:sub(offset + 1), offset))
      assert(written > 0 and written <= #bytes - offset, "complete lock fixture file write")
      offset = offset + written
    end
    assert(vim.uv.fs_fsync(descriptor), "fsync lock fixture file")
    local opened = assert(vim.uv.fs_fstat(descriptor), "stat open lock fixture file")
    assert(opened.type == "file", "open lock fixture node has the wrong type")
    assert(opened.uid == vim.uv.getuid(), "open lock fixture file has the wrong owner")
    eq(require("bit").band(opened.mode, 511), 384, "open lock fixture file mode")
    eq(opened.size, #bytes, "open lock fixture file size")
    assert(vim.uv.fs_close(descriptor), "close lock fixture file")
    local final = assert_node(fixture, path, "file", 384)
    eq(final.dev, opened.dev, "lock fixture file device identity")
    eq(final.ino, opened.ino, "lock fixture file inode identity")
    eq(final.size, opened.size, "lock fixture file stable size")
  end

  local function remove_path(fixture, path)
    assert(fixture.owned_process == nil, "lock fixture mutation requires confirmed process exit")
    assert(contains(fixture, path), "lock fixture cleanup escaped its private root")
    assert(vim.fs.normalize(path) ~= vim.fs.normalize(fixture.root), "refuse nested root cleanup")
    assert_node(fixture, fixture.root, "directory", 448)
    local stat, _, code = vim.uv.fs_lstat(path)
    if not stat then
      assert(code == "ENOENT", "lock fixture cleanup could not inspect its target")
      return
    end
    local flags = stat.type == "directory" and "rf" or ""
    assert(vim.fn.delete(path, flags) == 0, "remove exact contained lock fixture path")
    local remaining, _, remaining_code = vim.uv.fs_lstat(path)
    assert(remaining == nil and remaining_code == "ENOENT", "lock fixture path remains")
  end

  function methods.new()
    local root = vim.fn.tempname()
    local fixture = {
      root = root,
      state = root .. "/xdg-state",
      owned_process = nil,
    }
    assert(vim.fn.mkdir(root, "", 448) == 1, "create guarded lock fixture root")
    assert_node(fixture, root, "directory", 448)
    create_directory(fixture, fixture.state)
    create_directory(fixture, fixture.state .. "/opencode")
    return fixture
  end

  function methods.create_form(fixture, form)
    assert(fixture.owned_process == nil, "lock fixture still owns a process")
    assert(
      vim.tbl_contains({
        "absent",
        "empty-root",
        "empty-directory",
        "heartbeat",
        "metadata",
        "full",
      }, form),
      "unknown lock fixture form"
    )
    local state = fixture.state .. "/opencode"
    local lock_root = state .. "/locks"
    local lock = lock_root .. "/" .. fixed_lock
    assert_node(fixture, state, "directory", 448)
    remove_path(fixture, lock_root)
    if form == "absent" then
      return
    end
    create_directory(fixture, lock_root)
    if form == "empty-root" then
      return
    end
    create_directory(fixture, lock)
    if form == "empty-directory" then
      return
    end
    if form == "heartbeat" or form == "full" then
      create_file(fixture, lock .. "/heartbeat", "")
    end
    if form == "metadata" or form == "full" then
      create_file(fixture, lock .. "/meta.json", valid_lock_metadata())
    end
  end

  function methods.cleanup(fixture)
    assert(fixture.owned_process == nil, "lock fixture cleanup requires confirmed process exit")
    assert_node(fixture, fixture.root, "directory", 448)
    assert(vim.fn.delete(fixture.root, "rf") == 0, "remove exact guarded lock fixture root")
    local stat, _, code = vim.uv.fs_lstat(fixture.root)
    assert(stat == nil and code == "ENOENT", "guarded lock fixture root remains")
  end

  return methods
end)()

local MAX_MANAGED_FIXTURE_BYTES = 1024 * 1024

local function stable_timestamp(value)
  return type(value) == "table" and type(value.sec) == "number" and type(value.nsec) == "number"
end

local function same_stable_stat(left, right)
  return type(left) == "table"
    and type(right) == "table"
    and left.type == right.type
    and left.dev == right.dev
    and left.ino == right.ino
    and left.uid == right.uid
    and left.gid == right.gid
    and left.mode == right.mode
    and left.size == right.size
    and stable_timestamp(left.mtime)
    and stable_timestamp(right.mtime)
    and left.mtime.sec == right.mtime.sec
    and left.mtime.nsec == right.mtime.nsec
    and stable_timestamp(left.ctime)
    and stable_timestamp(right.ctime)
    and left.ctime.sec == right.ctime.sec
    and left.ctime.nsec == right.ctime.nsec
end

local function valid_fixture_file(stat, allow_repair_mode)
  local permissions = type(stat) == "table"
      and type(stat.mode) == "number"
      and require("bit").band(stat.mode, 511)
    or nil
  return type(stat) == "table"
    and stat.type == "file"
    and stat.uid == vim.uv.getuid()
    and type(stat.gid) == "number"
    and (permissions == 384 or (allow_repair_mode and permissions == 420))
    and type(stat.dev) == "number"
    and type(stat.ino) == "number"
    and type(stat.size) == "number"
    and stat.size >= 0
    and stat.size <= MAX_MANAGED_FIXTURE_BYTES
    and stable_timestamp(stat.mtime)
    and stable_timestamp(stat.ctime)
end

local function close_fixture_descriptor(descriptor)
  for _ = 1, 2 do
    local close_ok, closed = pcall(vim.uv.fs_close, descriptor)
    if close_ok and closed then
      return true
    end
  end
  return false
end

local function read_fixture_descriptor(descriptor, size)
  assert(type(size) == "number" and size >= 0 and size <= MAX_MANAGED_FIXTURE_BYTES)
  local chunks = {}
  local offset = 0
  while offset < size do
    local requested = math.min(65536, size - offset)
    local bytes = assert(vim.uv.fs_read(descriptor, requested, offset))
    assert(type(bytes) == "string" and #bytes > 0 and #bytes <= requested)
    chunks[#chunks + 1] = bytes
    offset = offset + #bytes
  end
  local bytes = table.concat(chunks)
  eq(#bytes, size, "complete bounded artifact-fixture read")
  return bytes
end

local function fixture_read(path)
  local before = assert(vim.uv.fs_lstat(path))
  assert(valid_fixture_file(before), "artifact-fixture source is not a bounded private file")
  local descriptor = assert(vim.uv.fs_open(path, "r", 0))
  local read_ok, bytes, opened = pcall(function()
    local current = assert(vim.uv.fs_fstat(descriptor))
    assert(valid_fixture_file(current) and same_stable_stat(before, current))
    local content = read_fixture_descriptor(descriptor, current.size)
    local after_descriptor = assert(vim.uv.fs_fstat(descriptor))
    local after_path = assert(vim.uv.fs_lstat(path))
    assert(
      valid_fixture_file(after_descriptor)
        and same_stable_stat(current, after_descriptor)
        and same_stable_stat(after_descriptor, after_path),
      "artifact-fixture source changed during bounded read"
    )
    return content, after_descriptor
  end)
  local closed = close_fixture_descriptor(descriptor)
  assert(closed, "artifact-fixture read descriptor close is unproven")
  assert(read_ok, "bounded artifact-fixture read failed")
  local after_close = assert(vim.uv.fs_lstat(path))
  assert(valid_fixture_file(after_close) and same_stable_stat(opened, after_close))
  return bytes
end

local function fixture_write(path, bytes)
  assert(type(bytes) == "string" and #bytes <= MAX_MANAGED_FIXTURE_BYTES)
  local before = assert(vim.uv.fs_lstat(path))
  assert(
    valid_fixture_file(before, true),
    "artifact-fixture target is not a bounded current-user file"
  )
  local descriptor = assert(vim.uv.fs_open(path, "r+", 384))
  local write_ok, final_stat = pcall(function()
    local opened = assert(vim.uv.fs_fstat(descriptor))
    assert(valid_fixture_file(opened, true) and same_stable_stat(before, opened))
    assert(vim.uv.fs_fchmod(descriptor, 384))
    assert(vim.uv.fs_ftruncate(descriptor, 0))
    local offset = 0
    while offset < #bytes do
      local chunk = bytes:sub(offset + 1, math.min(offset + 65536, #bytes))
      local written = assert(vim.uv.fs_write(descriptor, chunk, offset))
      assert(type(written) == "number" and written > 0 and written <= #chunk)
      offset = offset + written
    end
    eq(offset, #bytes, "complete bounded artifact-fixture write")
    assert(vim.uv.fs_ftruncate(descriptor, #bytes))
    assert(vim.uv.fs_fsync(descriptor))
    local current = assert(vim.uv.fs_fstat(descriptor))
    assert(valid_fixture_file(current) and current.size == #bytes)
    assert(
      read_fixture_descriptor(descriptor, current.size) == bytes,
      "artifact-fixture write readback differs"
    )
    local after_readback = assert(vim.uv.fs_fstat(descriptor))
    local after_path = assert(vim.uv.fs_lstat(path))
    assert(
      valid_fixture_file(after_readback)
        and same_stable_stat(current, after_readback)
        and same_stable_stat(after_readback, after_path),
      "artifact-fixture target changed after bounded write"
    )
    return after_readback
  end)
  local closed = close_fixture_descriptor(descriptor)
  assert(closed, "artifact-fixture write descriptor close is unproven")
  assert(write_ok, "bounded artifact-fixture write failed")
  local after_close = assert(vim.uv.fs_lstat(path))
  assert(valid_fixture_file(after_close) and same_stable_stat(final_stat, after_close))
end

local function fixture_create(path, bytes)
  assert(type(bytes) == "string" and #bytes <= MAX_MANAGED_FIXTURE_BYTES)
  local absent, _, absent_code = vim.uv.fs_lstat(path)
  assert(absent == nil and absent_code == "ENOENT", "artifact-fixture creation target exists")
  local descriptor = assert(vim.uv.fs_open(path, "wx", 384))
  local create_ok, final_stat = pcall(function()
    assert(vim.uv.fs_fchmod(descriptor, 384))
    local offset = 0
    while offset < #bytes do
      local chunk = bytes:sub(offset + 1, math.min(offset + 65536, #bytes))
      local written = assert(vim.uv.fs_write(descriptor, chunk, offset))
      assert(type(written) == "number" and written > 0 and written <= #chunk)
      offset = offset + written
    end
    eq(offset, #bytes, "complete bounded artifact-fixture creation")
    assert(vim.uv.fs_ftruncate(descriptor, #bytes))
    assert(vim.uv.fs_fsync(descriptor))
    local current = assert(vim.uv.fs_fstat(descriptor))
    local current_path = assert(vim.uv.fs_lstat(path))
    assert(
      valid_fixture_file(current)
        and current.size == #bytes
        and same_stable_stat(current, current_path),
      "artifact-fixture creation changed identity"
    )
    return current
  end)
  local closed = close_fixture_descriptor(descriptor)
  assert(closed, "artifact-fixture creation descriptor close is unproven")
  assert(create_ok, "bounded artifact-fixture creation failed")
  local after_close = assert(vim.uv.fs_lstat(path))
  assert(valid_fixture_file(after_close) and same_stable_stat(final_stat, after_close))
  assert(fixture_read(path) == bytes, "artifact-fixture creation readback differs")
end

if not vim.env.NVIM_AI_MANAGED_REAL_OPENCODE then
  print("AI managed OpenCode deterministic assertions: ok")
  print("SKIP installed OpenCode artifact audit (pass --opencode to tests/run.py)")
  return
end
(function()
  local installed_opencode =
    assert(require("ai.tools").resolve(vim.env.NVIM_AI_MANAGED_REAL_OPENCODE))
  local MAX_RETAINED_ENTRIES = 128
  local MAX_RETAINED_BYTES = 1024 * 1024

  local function guarded_copy_probe_tree(tree, target_root, destination_name, logical_destination)
    local uv = vim.uv
    local bit = require("bit")
    local uid = uv.getuid()
    local open_files = {}
    local open_directories = {}
    local entry_count = 0
    local byte_count = 0

    local function close_file(descriptor)
      if not open_files[descriptor] then
        return true
      end
      local close_ok, closed = pcall(uv.fs_close, descriptor)
      if close_ok and closed then
        open_files[descriptor] = nil
        return true
      end
      return false
    end

    local function close_directory(directory)
      if not open_directories[directory] then
        return true
      end
      local close_ok, closed = pcall(uv.fs_closedir, directory)
      if close_ok and closed then
        open_directories[directory] = nil
        return true
      end
      return false
    end

    local function close_all_tracked()
      for _ = 1, 2 do
        for directory in pairs(open_directories) do
          close_directory(directory)
        end
        for descriptor in pairs(open_files) do
          close_file(descriptor)
        end
        if next(open_directories) == nil and next(open_files) == nil then
          return true
        end
      end
      return false
    end

    local function valid_name(name)
      return type(name) == "string"
        and name ~= ""
        and name ~= "."
        and name ~= ".."
        and #name <= 255
        and not name:find("/", 1, true)
        and not name:find("[%z\1-\31\127]")
    end

    local function valid_node(stat, node_type, mode)
      return type(stat) == "table"
        and stat.type == node_type
        and stat.uid == uid
        and type(stat.mode) == "number"
        and bit.band(stat.mode, 511) == mode
        and type(stat.dev) == "number"
        and type(stat.ino) == "number"
        and type(stat.gid) == "number"
        and type(stat.size) == "number"
        and stat.size >= 0
        and stable_timestamp(stat.mtime)
        and stable_timestamp(stat.ctime)
    end

    local function same_node(left, right)
      return same_stable_stat(left, right)
    end

    local function same_identity(left, right, node_type, mode)
      return valid_node(left, node_type, mode)
        and valid_node(right, node_type, mode)
        and left.type == right.type
        and left.dev == right.dev
        and left.ino == right.ino
        and left.uid == right.uid
        and left.gid == right.gid
        and left.mode == right.mode
    end

    local function descriptor_anchor(descriptor, node_type, mode)
      assert(
        type(descriptor) == "number" and descriptor >= 0 and descriptor == math.floor(descriptor)
      )
      local anchor = "/proc/self/fd/" .. descriptor
      local opened = assert(uv.fs_fstat(descriptor))
      local anchored = assert(uv.fs_stat(anchor))
      assert(
        valid_node(opened, node_type, mode)
          and valid_node(anchored, node_type, mode)
          and same_node(opened, anchored)
      )
      return anchor
    end

    local function verify_target_directory(target)
      assert(type(target) == "table")
      local held = assert(uv.fs_fstat(target.descriptor))
      local anchored = assert(uv.fs_stat(target.anchor))
      local logical = assert(uv.fs_lstat(target.logical_path))
      assert(
        same_identity(target.identity, held, "directory", 448)
          and same_identity(held, anchored, "directory", 448)
          and same_identity(anchored, logical, "directory", 448),
        "retained target directory identity changed"
      )
      return held
    end

    local function target_child_anchor(parent, name, logical_child)
      assert(valid_name(name))
      assert(logical_child == parent.logical_path .. "/" .. name)
      verify_target_directory(parent)
      return parent.anchor .. "/" .. name
    end

    local function assert_target_absent(path)
      local stat, _, code = uv.fs_lstat(path)
      assert(stat == nil and code == "ENOENT", "retained target child already exists")
    end

    local function create_target_directory(parent, name, logical_path)
      local anchored_path = target_child_anchor(parent, name, logical_path)
      assert_target_absent(anchored_path)
      assert_target_absent(logical_path)
      assert(uv.fs_mkdir(anchored_path, 448))
      local descriptor = assert(uv.fs_open(anchored_path, "r", 0))
      open_files[descriptor] = true
      local opened = assert(uv.fs_fstat(descriptor))
      local anchored = assert(uv.fs_lstat(anchored_path))
      local logical = assert(uv.fs_lstat(logical_path))
      assert(
        same_identity(opened, anchored, "directory", 448)
          and same_identity(anchored, logical, "directory", 448),
        "retained target directory creation changed identity"
      )
      local target = {
        anchor = descriptor_anchor(descriptor, "directory", 448),
        anchored_path = anchored_path,
        descriptor = descriptor,
        identity = opened,
        logical_path = logical_path,
      }
      verify_target_directory(target)
      verify_target_directory(parent)
      return target
    end

    local function open_target_file(parent, name, logical_path)
      local anchored_path = target_child_anchor(parent, name, logical_path)
      assert_target_absent(anchored_path)
      assert_target_absent(logical_path)
      local descriptor = assert(uv.fs_open(anchored_path, "wx", 384))
      open_files[descriptor] = true
      assert(uv.fs_fchmod(descriptor, 384))
      local opened = assert(uv.fs_fstat(descriptor))
      local anchored = assert(uv.fs_lstat(anchored_path))
      local logical = assert(uv.fs_lstat(logical_path))
      assert(
        same_identity(opened, anchored, "file", 384)
          and same_identity(anchored, logical, "file", 384),
        "retained target file creation changed identity"
      )
      verify_target_directory(parent)
      return descriptor, anchored_path
    end

    local function open_checked_source(logical_path, anchored_path, node_type, mode)
      local logical_before = assert(uv.fs_lstat(logical_path))
      local anchored_before = assert(uv.fs_lstat(anchored_path))
      assert(
        valid_node(logical_before, node_type, mode)
          and valid_node(anchored_before, node_type, mode)
          and same_node(logical_before, anchored_before)
      )
      local descriptor = assert(uv.fs_open(anchored_path, "r", 0))
      open_files[descriptor] = true
      local opened = assert(uv.fs_fstat(descriptor))
      assert(valid_node(opened, node_type, mode) and same_node(logical_before, opened))
      local anchor = descriptor_anchor(descriptor, node_type, mode)
      return {
        anchor = anchor,
        descriptor = descriptor,
        logical_path = logical_path,
        opened = opened,
        node_type = node_type,
        mode = mode,
      }
    end

    local function verify_checked_source(source)
      local held = assert(uv.fs_fstat(source.descriptor))
      local anchored = assert(uv.fs_stat(source.anchor))
      local logical = assert(uv.fs_lstat(source.logical_path))
      assert(
        valid_node(held, source.node_type, source.mode)
          and valid_node(anchored, source.node_type, source.mode)
          and valid_node(logical, source.node_type, source.mode)
          and same_node(source.opened, held)
          and same_node(held, anchored)
          and same_node(anchored, logical),
        "retained source identity or timestamps changed"
      )
      return held
    end

    local function directory_entries(anchor, reserve_entries, expected_count)
      local directory = assert(uv.fs_opendir(anchor, nil, 32))
      open_directories[directory] = true
      local entries = {}
      local seen = {}
      while true do
        local batch, read_error = uv.fs_readdir(directory)
        assert(read_error == nil)
        if batch == nil or #batch == 0 then
          break
        end
        assert(type(batch) == "table")
        for _, entry in ipairs(batch) do
          assert(valid_name(entry.name) and not seen[entry.name])
          assert(#entries < MAX_RETAINED_ENTRIES)
          if expected_count ~= nil then
            assert(#entries < expected_count)
          end
          if reserve_entries then
            assert(entry_count < MAX_RETAINED_ENTRIES)
            entry_count = entry_count + 1
          end
          seen[entry.name] = true
          entries[#entries + 1] = { name = entry.name, type = entry.type }
        end
      end
      assert(close_directory(directory), "retained directory stream close is unproven")
      table.sort(entries, function(left, right)
        return left.name < right.name
      end)
      return entries
    end

    local copy_directory

    local function copy_file(logical_source, anchored_source, target_parent, name, logical_target)
      local source = open_checked_source(logical_source, anchored_source, "file", 384)
      byte_count = byte_count + source.opened.size
      assert(byte_count <= MAX_RETAINED_BYTES)

      local target_descriptor, anchored_target =
        open_target_file(target_parent, name, logical_target)
      local offset = 0
      while offset < source.opened.size do
        local length = math.min(65536, source.opened.size - offset)
        local bytes = assert(uv.fs_read(source.descriptor, length, offset))
        assert(#bytes > 0 and #bytes <= length)
        local written = 0
        while written < #bytes do
          local count =
            assert(uv.fs_write(target_descriptor, bytes:sub(written + 1), offset + written))
          assert(count > 0 and count <= #bytes - written)
          written = written + count
        end
        offset = offset + #bytes
      end
      eq(offset, source.opened.size, "complete retained source copy")
      assert(uv.fs_ftruncate(target_descriptor, source.opened.size))
      assert(uv.fs_fsync(target_descriptor))
      local copied = assert(uv.fs_fstat(target_descriptor))
      local anchored_stat = assert(uv.fs_lstat(anchored_target))
      local logical_stat = assert(uv.fs_lstat(logical_target))
      assert(
        valid_node(copied, "file", 384)
          and copied.size == source.opened.size
          and same_node(copied, anchored_stat)
          and same_node(anchored_stat, logical_stat)
      )
      verify_target_directory(target_parent)
      verify_checked_source(source)
      assert(close_file(target_descriptor), "retained target descriptor close is unproven")
      local anchored_after_close = assert(uv.fs_lstat(anchored_target))
      local logical_after_close = assert(uv.fs_lstat(logical_target))
      assert(
        same_node(copied, anchored_after_close)
          and same_node(anchored_after_close, logical_after_close),
        "retained target file changed after close"
      )
      verify_target_directory(target_parent)
      assert(close_file(source.descriptor), "retained source descriptor close is unproven")
      local source_after_close = assert(uv.fs_lstat(logical_source))
      assert(
        valid_node(source_after_close, "file", 384) and same_node(source.opened, source_after_close)
      )
      return { name = name, type = "file", mode = 384, size = source.opened.size }
    end

    copy_directory = function(
      logical_source,
      anchored_source,
      target_parent,
      target_name,
      logical_target,
      depth
    )
      assert(depth <= 16)
      local source = open_checked_source(logical_source, anchored_source, "directory", 448)
      local target = create_target_directory(target_parent, target_name, logical_target)
      local manifest = {
        name = target_name,
        type = "directory",
        mode = 448,
        children = {},
      }
      local entries = directory_entries(source.anchor, true)
      for _, entry in ipairs(entries) do
        local logical_child = logical_source .. "/" .. entry.name
        local anchored_child = source.anchor .. "/" .. entry.name
        local logical_target_child = logical_target .. "/" .. entry.name
        local logical_stat = assert(uv.fs_lstat(logical_child))
        local anchored_stat = assert(uv.fs_lstat(anchored_child))
        assert(same_node(logical_stat, anchored_stat))
        assert(entry.type == nil or entry.type == "unknown" or entry.type == anchored_stat.type)
        if anchored_stat.type == "directory" then
          assert(valid_node(anchored_stat, "directory", 448))
          manifest.children[#manifest.children + 1] = copy_directory(
            logical_child,
            anchored_child,
            target,
            entry.name,
            logical_target_child,
            depth + 1
          )
        else
          assert(valid_node(anchored_stat, "file", 384))
          manifest.children[#manifest.children + 1] =
            copy_file(logical_child, anchored_child, target, entry.name, logical_target_child)
        end
        verify_target_directory(target)
      end
      assert(
        vim.deep_equal(directory_entries(source.anchor, false, #entries), entries),
        "retained source directory entries changed"
      )
      verify_checked_source(source)
      verify_target_directory(target)
      assert(
        close_file(source.descriptor),
        "retained source directory descriptor close is unproven"
      )
      local source_after_close = assert(uv.fs_lstat(logical_source))
      assert(
        valid_node(source_after_close, "directory", 448)
          and same_node(source.opened, source_after_close)
      )
      assert(close_file(target.descriptor), "retained target directory close is unproven")
      local anchored_target_after_close = assert(uv.fs_lstat(target.anchored_path))
      local logical_target_after_close = assert(uv.fs_lstat(target.logical_path))
      assert(
        same_identity(target.identity, anchored_target_after_close, "directory", 448)
          and same_identity(
            anchored_target_after_close,
            logical_target_after_close,
            "directory",
            448
          ),
        "retained target directory changed after close"
      )
      verify_target_directory(target_parent)
      return manifest
    end

    local ok, manifest = pcall(function()
      assert(type(uid) == "number")
      local expected_children = {
        home = "/home",
        config = "/xdg-config",
        config_opencode = "/xdg-config/opencode",
        bootstrap = "/xdg-config/opencode/.gitignore",
        data = "/xdg-data",
        cache = "/xdg-cache",
        state = "/xdg-state",
      }
      assert(type(tree) == "table" and type(tree.root) == "string")
      assert(tree.root:sub(1, 1) == "/" and vim.fs.normalize(tree.root) == tree.root)
      for field, suffix in pairs(expected_children) do
        assert(tree[field] == tree.root .. suffix)
      end
      assert(type(target_root) == "table")
      assert(type(target_root.descriptor) == "number")
      assert(type(target_root.anchor) == "string")
      assert(type(target_root.logical_path) == "string")
      assert(type(target_root.identity) == "table")
      assert(target_root.anchor == descriptor_anchor(target_root.descriptor, "directory", 448))
      verify_target_directory(target_root)
      assert(valid_name(destination_name))
      assert(type(logical_destination) == "string" and logical_destination:sub(1, 1) == "/")
      assert(vim.fs.normalize(logical_destination) == logical_destination)
      assert(logical_destination == target_root.logical_path .. "/" .. destination_name)
      local anchored_destination = target_root.anchor .. "/" .. destination_name
      assert_target_absent(anchored_destination)
      assert_target_absent(logical_destination)
      entry_count = 1
      assert(entry_count <= MAX_RETAINED_ENTRIES)
      local manifest =
        copy_directory(tree.root, tree.root, target_root, destination_name, logical_destination, 0)
      verify_target_directory(target_root)
      return manifest
    end)
    local handles_closed = close_all_tracked()
    if ok and handles_closed then
      return true, manifest
    end
    return false, nil
  end

  local retention_root = "/tmp/nvim-ai-opencode-retention-"
    .. vim.fn.sha256(vim.fn.tempname()):sub(1, 16)
  local retention_created = vim.uv.fs_mkdir(retention_root, 448)
  local retention_live = retention_created == true
  local preserve_retention = true
  local retention_root_descriptor
  local retention_root_anchor
  local retention_root_identity
  local retention_root_identity_ready = false

  local function valid_retention_root_stat(stat)
    return type(stat) == "table"
      and stat.type == "directory"
      and stat.uid == vim.uv.getuid()
      and type(stat.gid) == "number"
      and type(stat.mode) == "number"
      and require("bit").band(stat.mode, 511) == 448
      and type(stat.dev) == "number"
      and type(stat.ino) == "number"
  end

  local function same_retention_root_identity(left, right)
    return valid_retention_root_stat(left)
      and valid_retention_root_stat(right)
      and left.type == right.type
      and left.dev == right.dev
      and left.ino == right.ino
      and left.uid == right.uid
      and left.gid == right.gid
      and left.mode == right.mode
  end

  if retention_live then
    local open_ok, descriptor = pcall(vim.uv.fs_open, retention_root, "r", 0)
    if open_ok and type(descriptor) == "number" then
      retention_root_descriptor = descriptor
      retention_root_anchor = "/proc/self/fd/" .. descriptor
      local stat_ok, held, anchored, logical = pcall(function()
        return vim.uv.fs_fstat(descriptor),
          vim.uv.fs_stat(retention_root_anchor),
          vim.uv.fs_lstat(retention_root)
      end)
      if
        stat_ok
        and same_retention_root_identity(held, anchored)
        and same_retention_root_identity(anchored, logical)
      then
        retention_root_identity = held
        retention_root_identity_ready = true
      end
    end
  end

  local function retention_root_state(allow_absent)
    if
      not retention_root_identity_ready
      or type(retention_root_descriptor) ~= "number"
      or type(retention_root_anchor) ~= "string"
    then
      return nil
    end
    local state_ok, state = pcall(function()
      local logical, logical_error, logical_code = vim.uv.fs_lstat(retention_root)
      return {
        held = vim.uv.fs_fstat(retention_root_descriptor),
        anchored = vim.uv.fs_stat(retention_root_anchor),
        logical = logical,
        logical_error = logical_error,
        logical_code = logical_code,
      }
    end)
    if
      not state_ok
      or type(state) ~= "table"
      or not same_retention_root_identity(retention_root_identity, state.held)
      or not same_retention_root_identity(state.held, state.anchored)
    then
      return nil
    end
    if state.logical == nil then
      if allow_absent and state.logical_code == "ENOENT" then
        return state
      end
      return nil
    end
    if not same_retention_root_identity(state.anchored, state.logical) then
      return nil
    end
    return state
  end

  local compatibility_controller
  local controller_may_own_process = false
  local shutdown_attempted = false
  local shutdown_proven = false
  local function shutdown_for_exit()
    if shutdown_attempted then
      return shutdown_proven
    end
    shutdown_attempted = true
    if not controller_may_own_process then
      shutdown_proven = true
      return true
    end
    if type(compatibility_controller) ~= "table" then
      return false
    end
    local shutdown_ok, drained = pcall(function()
      return compatibility_controller:shutdown(true)
    end)
    shutdown_proven = shutdown_ok and drained == true
    return shutdown_proven
  end
  local function shutdown_category()
    return shutdown_proven and "proved" or "unproven"
  end

  local function cleanup_manifest_valid(manifest)
    local entry_count = 0
    local byte_count = 0
    local function visit(node, depth)
      if depth > 16 or type(node) ~= "table" then
        return false
      end
      if
        type(node.name) ~= "string"
        or node.name == ""
        or node.name == "."
        or node.name == ".."
        or #node.name > 255
        or node.name:find("/", 1, true)
        or node.name:find("[%z\1-\31\127]")
      then
        return false
      end
      if entry_count >= MAX_RETAINED_ENTRIES then
        return false
      end
      entry_count = entry_count + 1
      if node.type == "file" then
        for key in pairs(node) do
          if key ~= "name" and key ~= "type" and key ~= "mode" and key ~= "size" then
            return false
          end
        end
        if
          node.mode ~= 384
          or type(node.size) ~= "number"
          or node.size < 0
          or node.size ~= math.floor(node.size)
          or byte_count > MAX_RETAINED_BYTES - node.size
        then
          return false
        end
        byte_count = byte_count + node.size
        return true
      end
      if node.type ~= "directory" or node.mode ~= 448 or type(node.children) ~= "table" then
        return false
      end
      for key in pairs(node) do
        if key ~= "name" and key ~= "type" and key ~= "mode" and key ~= "children" then
          return false
        end
      end
      local previous_name
      for index, child in ipairs(node.children) do
        if
          index > MAX_RETAINED_ENTRIES
          or type(child) ~= "table"
          or type(child.name) ~= "string"
          or (previous_name ~= nil and child.name <= previous_name)
          or not visit(child, depth + 1)
        then
          return false
        end
        previous_name = child.name
      end
      for key in pairs(node.children) do
        if type(key) ~= "number" or key < 1 or key > #node.children or key ~= math.floor(key) then
          return false
        end
      end
      return true
    end
    if not visit(manifest, 0) or manifest.name ~= "names" or manifest.type ~= "directory" then
      return nil
    end
    return { entries = entry_count, bytes = byte_count }
  end

  local function cleanup_expected_retained_contents(manifest)
    local uv = vim.uv
    local bit = require("bit")
    local limits = cleanup_manifest_valid(manifest)
    if limits == nil then
      return false
    end
    local open_descriptors = {}
    local open_directories = {}

    local function close_descriptor(descriptor)
      if not open_descriptors[descriptor] then
        return true
      end
      if close_fixture_descriptor(descriptor) then
        open_descriptors[descriptor] = nil
        return true
      end
      return false
    end

    local function close_directory(directory)
      if not open_directories[directory] then
        return true
      end
      for _ = 1, 2 do
        local close_ok, closed = pcall(uv.fs_closedir, directory)
        if close_ok and closed then
          open_directories[directory] = nil
          return true
        end
      end
      return false
    end

    local function close_all_tracked()
      for _ = 1, 2 do
        for directory in pairs(open_directories) do
          close_directory(directory)
        end
        for descriptor in pairs(open_descriptors) do
          close_descriptor(descriptor)
        end
        if next(open_directories) == nil and next(open_descriptors) == nil then
          return true
        end
      end
      return false
    end

    local function valid_node(stat, node_type, mode)
      return type(stat) == "table"
        and stat.type == node_type
        and stat.uid == uv.getuid()
        and type(stat.gid) == "number"
        and type(stat.mode) == "number"
        and bit.band(stat.mode, 511) == mode
        and type(stat.dev) == "number"
        and type(stat.ino) == "number"
        and type(stat.size) == "number"
        and stat.size >= 0
        and type(stat.nlink) == "number"
        and stat.nlink >= 0
        and stable_timestamp(stat.mtime)
        and stable_timestamp(stat.ctime)
    end

    local function same_identity(left, right, node_type, mode)
      return valid_node(left, node_type, mode)
        and valid_node(right, node_type, mode)
        and left.type == right.type
        and left.dev == right.dev
        and left.ino == right.ino
        and left.uid == right.uid
        and left.gid == right.gid
        and left.mode == right.mode
    end

    local function same_live_identity(left, right, node_type, mode)
      return same_identity(left, right, node_type, mode)
        and (node_type ~= "file" or (left.nlink == 1 and right.nlink == 1))
    end

    local function open_node(parent_anchor, expected)
      local path = parent_anchor .. "/" .. expected.name
      local before = assert(uv.fs_lstat(path))
      assert(
        valid_node(before, expected.type, expected.mode)
          and (expected.type ~= "file" or before.nlink == 1)
      )
      if expected.type == "file" then
        assert(before.size == expected.size)
      end
      local descriptor = assert(uv.fs_open(path, "r", 0))
      open_descriptors[descriptor] = true
      local anchor = "/proc/self/fd/" .. descriptor
      local held = assert(uv.fs_fstat(descriptor))
      local anchored = assert(uv.fs_stat(anchor))
      assert(
        same_stable_stat(before, held)
          and same_stable_stat(held, anchored)
          and same_live_identity(before, held, expected.type, expected.mode)
          and same_live_identity(held, anchored, expected.type, expected.mode)
      )
      return {
        anchor = anchor,
        descriptor = descriptor,
        identity = held,
        path = path,
      }
    end

    local function directory_entries(anchor, counter)
      local directory = assert(uv.fs_opendir(anchor, nil, 32))
      open_directories[directory] = true
      local entries = {}
      local seen = {}
      while true do
        local batch, read_error = uv.fs_readdir(directory)
        assert(read_error == nil)
        if batch == nil or #batch == 0 then
          break
        end
        assert(type(batch) == "table")
        for _, entry in ipairs(batch) do
          assert(
            type(entry.name) == "string"
              and entry.name ~= ""
              and entry.name ~= "."
              and entry.name ~= ".."
              and #entry.name <= 255
              and not entry.name:find("/", 1, true)
              and not entry.name:find("[%z\1-\31\127]")
              and not seen[entry.name]
          )
          assert(#entries < MAX_RETAINED_ENTRIES)
          if counter ~= nil then
            assert(counter.entries < MAX_RETAINED_ENTRIES)
            counter.entries = counter.entries + 1
          end
          seen[entry.name] = true
          entries[#entries + 1] = { name = entry.name, type = entry.type }
        end
      end
      assert(close_directory(directory), "retained cleanup directory close is unproven")
      table.sort(entries, function(left, right)
        return left.name < right.name
      end)
      return entries
    end

    local function entries_match(entries, children)
      if #entries ~= #children then
        return false
      end
      for index, entry in ipairs(entries) do
        local expected = children[index]
        if
          entry.name ~= expected.name
          or (entry.type ~= nil and entry.type ~= "unknown" and entry.type ~= expected.type)
        then
          return false
        end
      end
      return true
    end

    local function verify_held(node, expected)
      local held = assert(uv.fs_fstat(node.descriptor))
      local anchored = assert(uv.fs_stat(node.anchor))
      local path_stat = assert(uv.fs_lstat(node.path))
      assert(
        same_live_identity(node.identity, held, expected.type, expected.mode)
          and same_live_identity(held, anchored, expected.type, expected.mode)
          and same_live_identity(anchored, path_stat, expected.type, expected.mode)
      )
      if expected.type == "file" then
        assert(held.size == expected.size and path_stat.size == expected.size)
      end
      return held
    end

    local function validate_node(parent_anchor, expected, depth, counter)
      assert(depth <= 16)
      local node = open_node(parent_anchor, expected)
      if expected.type == "directory" then
        local entries = directory_entries(node.anchor, counter)
        assert(entries_match(entries, expected.children))
        for _, child in ipairs(expected.children) do
          validate_node(node.anchor, child, depth + 1, counter)
        end
      end
      verify_held(node, expected)
      assert(close_descriptor(node.descriptor), "retained cleanup descriptor close is unproven")
      local after_close = assert(uv.fs_lstat(node.path))
      assert(same_live_identity(node.identity, after_close, expected.type, expected.mode))
    end

    local delete_node
    delete_node = function(parent_anchor, expected, depth, counter)
      assert(depth <= 16)
      local node = open_node(parent_anchor, expected)
      if expected.type == "file" then
        local immediately_before_unlink = verify_held(node, expected)
        assert(immediately_before_unlink.nlink == 1)
        assert(uv.fs_unlink(node.path))
      else
        local entries = directory_entries(node.anchor, counter)
        assert(entries_match(entries, expected.children))
        for _, child in ipairs(expected.children) do
          delete_node(node.anchor, child, depth + 1, counter)
        end
        assert(#directory_entries(node.anchor, nil) == 0)
        verify_held(node, expected)
        assert(uv.fs_rmdir(node.path))
      end
      local held_after = assert(uv.fs_fstat(node.descriptor))
      local anchored_after = assert(uv.fs_stat(node.anchor))
      assert(
        same_identity(node.identity, held_after, expected.type, expected.mode)
          and same_identity(held_after, anchored_after, expected.type, expected.mode)
          and held_after.nlink == 0
          and anchored_after.nlink == 0,
        "retained cleanup did not unlink the held node"
      )
      local absent, _, absent_code = uv.fs_lstat(node.path)
      assert(absent == nil and absent_code == "ENOENT")
      assert(close_descriptor(node.descriptor), "retained cleanup descriptor close is unproven")
    end

    local cleanup_ok = pcall(function()
      local validation_counter = { entries = 0 }
      local root_entries = directory_entries(retention_root_anchor, validation_counter)
      assert(entries_match(root_entries, { manifest }))
      validate_node(retention_root_anchor, manifest, 0, validation_counter)
      assert(validation_counter.entries == limits.entries)
      assert(retention_root_state(false) ~= nil)

      local deletion_counter = { entries = 0 }
      local deletion_entries = directory_entries(retention_root_anchor, deletion_counter)
      assert(entries_match(deletion_entries, { manifest }))
      delete_node(retention_root_anchor, manifest, 0, deletion_counter)
      assert(deletion_counter.entries == limits.entries)
      assert(#directory_entries(retention_root_anchor, nil) == 0)
    end)
    local handles_closed = close_all_tracked()
    return cleanup_ok and handles_closed
  end

  local retained_cleanup_manifest
  local function cleanup_retention_root()
    if not retention_live or preserve_retention then
      return not retention_live
    end
    if retention_root_state(false) == nil then
      return false
    end
    if not cleanup_expected_retained_contents(retained_cleanup_manifest) then
      return false
    end
    local before_remove = retention_root_state(false)
    if
      before_remove == nil
      or type(before_remove.held.nlink) ~= "number"
      or type(before_remove.anchored.nlink) ~= "number"
      or before_remove.held.nlink <= 0
      or before_remove.anchored.nlink <= 0
    then
      return false
    end
    local remove_ok, removed = pcall(vim.uv.fs_rmdir, retention_root)
    if not remove_ok or not removed then
      return false
    end
    local after_remove = retention_root_state(true)
    if
      after_remove == nil
      or after_remove.logical ~= nil
      or after_remove.logical_code ~= "ENOENT"
      or after_remove.held.nlink ~= 0
      or after_remove.anchored.nlink ~= 0
    then
      return false
    end
    retention_live = false
    return true
  end
  local function retained_cleanup_manifest_upvalue(closure)
    local captured_id
    local capture_count = 0
    for index = 1, 16 do
      local name = debug.getupvalue(closure, index)
      if name == nil then
        break
      end
      if name == "retained_cleanup_manifest" then
        capture_count = capture_count + 1
        captured_id = debug.upvalueid(closure, index)
      end
    end
    return capture_count, captured_id
  end
  local function assert_retained_cleanup_manifest_scope(observer)
    local cleanup_count, cleanup_id = retained_cleanup_manifest_upvalue(cleanup_retention_root)
    local observer_count, observer_id = retained_cleanup_manifest_upvalue(observer)
    assert(
      cleanup_count == 1 and observer_count == 1 and cleanup_id == observer_id,
      "cleanup and observer retained manifest scope is invalid"
    )
  end
  local function report_retained_failure()
    if not retention_live then
      return
    end
    local drained = shutdown_for_exit()
    pcall(
      vim.api.nvim_err_writeln,
      "managed OpenCode audit retained="
        .. retention_root
        .. " shutdown="
        .. (drained and "proved" or "unproven")
    )
  end
  local cleanup_registration_ok = pcall(vim.api.nvim_create_autocmd, "VimLeavePre", {
    once = true,
    callback = report_retained_failure,
  })
  if not cleanup_registration_ok then
    report_retained_failure()
  end
  assert(cleanup_registration_ok, "register guarded compatibility retention cleanup")
  assert(retention_created == true, "create guarded compatibility retention root")
  assert(retention_root_identity_ready, "open guarded compatibility retention root")
  local retention_state =
    assert(retention_root_state(false), "validate guarded compatibility retention root")
  local retention_stat = retention_state.logical
  assert(retention_stat.type == "directory", "compatibility retention root type")
  eq(retention_stat.uid, vim.uv.getuid(), "compatibility retention root owner")
  eq(require("bit").band(retention_stat.mode, 511), 448, "compatibility retention root mode")

  local retained_names_root = retention_root .. "/names"
  local retained_names_anchor = retention_root_anchor .. "/names"
  local retention_target_root = {
    anchor = retention_root_anchor,
    descriptor = retention_root_descriptor,
    identity = retention_root_identity,
    logical_path = retention_root,
  }
  local compatibility_observations = {}
  local compatibility_notifications = {}
  local retention_copy_attempts = 0
  local retention_copy_succeeded = false
  local controller_creations = 0
  local expected_observation_fields = {
    artifact_accepted = true,
    artifact_category = true,
    code = true,
    signal = true,
    stdout_bytes = true,
    stderr_bytes = true,
    stdout_overflow = true,
    stderr_overflow = true,
    system_error = true,
    duration_ms = true,
  }
  local function observe_compatibility_probe(name, tree, observation)
    local retained_path
    if name == "names" and observation.artifact_accepted == true and observation.code == 0 then
      retention_copy_attempts = retention_copy_attempts + 1
      retained_path = retained_names_root
      retention_copy_succeeded, retained_cleanup_manifest =
        guarded_copy_probe_tree(tree, retention_target_root, "names", retained_names_root)
    end
    assert(type(observation) == "table", "real observer received an invalid observation")
    for field in pairs(observation) do
      assert(expected_observation_fields[field], "real observer exposed an unexpected field")
    end
    compatibility_observations[#compatibility_observations + 1] = {
      name = name,
      observation = {
        artifact_accepted = observation.artifact_accepted,
        artifact_category = observation.artifact_category,
        code = observation.code,
        signal = observation.signal,
        stdout_bytes = observation.stdout_bytes,
        stderr_bytes = observation.stderr_bytes,
        stdout_overflow = observation.stdout_overflow,
        stderr_overflow = observation.stderr_overflow,
        system_error = observation.system_error,
        duration_ms = observation.duration_ms,
      },
      retained_path = retained_path,
    }
  end
  assert_retained_cleanup_manifest_scope(observe_compatibility_probe)
  controller_creations = controller_creations + 1
  compatibility_controller = registry_module._test.new_opencode_validation({
    executable = installed_opencode,
    notify = function(message, level)
      compatibility_notifications[#compatibility_notifications + 1] = {
        message = message,
        level = level,
      }
    end,
    observe_probe = observe_compatibility_probe,
  })
  local identity_key = string.rep("a", 32)
  controller_may_own_process = true
  local started, start_error = compatibility_controller:ensure({
    reason = "open",
    identity_key = identity_key,
  })
  assert(started, start_error)
  eq(started.state, "checking", "real compatibility starts one checking sequence")
  local compatibility_completed = vim.wait(70000, function()
    local state = compatibility_controller:snapshot().state
    return state == "ready" or state == "failed"
  end, 10)
  if not compatibility_completed then
    local drained = shutdown_for_exit()
    assert(
      drained,
      "real managed OpenCode validation timed out; retained="
        .. retention_root
        .. " shutdown="
        .. shutdown_category()
    )
  end
  assert(
    compatibility_completed,
    "real managed OpenCode validation exceeded its outer test deadline; preserved="
      .. retention_root
  )
  local compatibility_snapshot = compatibility_controller:snapshot()
  if compatibility_snapshot.state ~= "ready" or not retention_copy_succeeded then
    local drained = shutdown_for_exit()
    local categories = {}
    for _, observed in ipairs(compatibility_observations) do
      local observation = observed.observation
      categories[#categories + 1] = table.concat({
        observed.name,
        tostring(observation.code),
        tostring(observation.artifact_category),
        tostring(observation.stdout_bytes),
        tostring(observation.stderr_bytes),
      }, ":")
    end
    error(
      "real pinned OpenCode compatibility boundary failed: "
        .. tostring(compatibility_snapshot.category)
        .. "; structural observations="
        .. table.concat(categories, ",")
        .. "; preserved="
        .. retention_root
        .. "; shutdown="
        .. (drained and "proved" or "unproven")
    )
  end
  eq(compatibility_snapshot, {
    state = "ready",
    installed = true,
    executable = installed_opencode,
    version = "1.18.30",
    category = "",
    queued = true,
  }, "real compatibility ready snapshot")
  local installed_compatibility = assert(compatibility_controller:report())
  assert(managed.validate_compatibility(installed_compatibility))
  eq(
    installed_compatibility.names,
    { "build", "compaction", "plan", "summary", "title" },
    "real exact five-agent enumeration"
  )
  for _, name in ipairs({ "build", "plan" }) do
    local agent = installed_compatibility.agents[name]
    assert(agent.native == true, "real " .. name .. " remains native")
    eq(agent.mode, "primary", "real " .. name .. " remains primary")
  end
  for _, name in ipairs({ "compaction", "summary", "title" }) do
    local agent = installed_compatibility.agents[name]
    assert(
      agent.native == true and agent.hidden == true,
      "real " .. name .. " remains native and hidden"
    )
    eq(agent.tools, audited_hidden_tool_map, "real " .. name .. " actionable tools remain disabled")
  end
  eq(#compatibility_observations, 12, "real exact compatibility command count")
  for index, command in ipairs(require("ai.backends.opencode_validation").commands()) do
    local observed = compatibility_observations[index]
    eq(observed.name, command.name, "real compatibility observation order " .. index)
    for field in pairs(observed.observation) do
      assert(expected_observation_fields[field], "real observer exposed an unexpected field")
    end
    local observation = observed.observation
    assert(
      observation.artifact_accepted == true,
      "real probe artifacts accepted: " .. observed.name
    )
    eq(observation.artifact_category, "accepted", observed.name .. " artifact category")
    local expected_code = (command.name == "general" or command.name == "explore") and 1 or 0
    eq(observation.code, expected_code, observed.name .. " exit code")
    eq(observation.signal, 0, observed.name .. " signal")
    assert(
      type(observation.stdout_bytes) == "number"
        and observation.stdout_bytes >= 0
        and observation.stdout_bytes <= 1024 * 1024,
      observed.name .. " bounded stdout count"
    )
    assert(
      type(observation.stderr_bytes) == "number"
        and observation.stderr_bytes >= 0
        and observation.stderr_bytes <= 65536,
      observed.name .. " bounded stderr count"
    )
    eq(observation.stdout_overflow, false, observed.name .. " stdout boundary")
    eq(observation.stderr_overflow, false, observed.name .. " stderr boundary")
    eq(observation.system_error, false, observed.name .. " system boundary")
    assert(
      type(observation.duration_ms) == "number"
        and observation.duration_ms >= 0
        and observation.duration_ms <= 10000,
      observed.name .. " bounded duration"
    )
    eq(
      observed.retained_path,
      command.name == "names" and retained_names_root or nil,
      observed.name .. " retained path"
    )
  end
  eq(retention_copy_attempts, 1, "one semantic artifact tree is retained")
  eq(compatibility_notifications, {}, "successful real validation emits no notification")
  eq(controller_creations, 1, "one real compatibility controller is constructed")
  eq(compatibility_controller:take_open(identity_key), true, "queued real opening is consumed once")
  eq(compatibility_controller:take_open(identity_key), false, "queued real opening cannot replay")
  eq(#compatibility_observations, 12, "passive ready reads and queue consumption do not retry")

  local normalized_retention = vim.fs.normalize(retention_root)
  local normalized_names = vim.fs.normalize(retained_names_root)
  assert(
    normalized_names:sub(1, #normalized_retention + 1) == normalized_retention .. "/",
    "retained names tree escaped its guarded root"
  )
  local retained_names_stat = assert(vim.uv.fs_lstat(retained_names_root))
  local retained_names_anchor_stat = assert(vim.uv.fs_lstat(retained_names_anchor))
  assert(retained_names_stat.type == "directory", "retained names tree type")
  assert(
    same_retention_root_identity(retained_names_stat, retained_names_anchor_stat),
    "retained names tree identity differs from its root descriptor anchor"
  )
  assert(
    retention_root_state(false) ~= nil,
    "guarded compatibility retention root changed before artifact mutation"
  )
  eq(retained_names_stat.uid, vim.uv.getuid(), "retained names tree owner")
  eq(require("bit").band(retained_names_stat.mode, 511), 448, "retained names tree mode")

  local mutation_tree = {
    root = retained_names_root,
    home = retained_names_root .. "/home",
    config = retained_names_root .. "/xdg-config",
    config_opencode = retained_names_root .. "/xdg-config/opencode",
    bootstrap = retained_names_root .. "/xdg-config/opencode/.gitignore",
    data = retained_names_root .. "/xdg-data",
    cache = retained_names_root .. "/xdg-cache",
    state = retained_names_root .. "/xdg-state",
  }
  local artifact_paths = {
    bootstrap = mutation_tree.bootstrap,
    database = mutation_tree.data .. "/opencode/opencode.db",
    log = mutation_tree.data .. "/opencode/log/opencode.log",
    metadata = mutation_tree.state
      .. "/opencode/locks/0a009c556ac8352fed53ef8323a3a97270935d30.lock/meta.json",
    heartbeat = mutation_tree.state
      .. "/opencode/locks/0a009c556ac8352fed53ef8323a3a97270935d30.lock/heartbeat",
    shared_memory = mutation_tree.data .. "/opencode/opencode.db-shm",
    unknown = mutation_tree.cache .. "/opencode/unknown-artifact",
    write_ahead_log = mutation_tree.data .. "/opencode/opencode.db-wal",
  }
  local function artifacts_rejected(label, overrides, expected_category)
    local accepted, category =
      registry_module._test.inspect_opencode_probe_artifacts(mutation_tree, true, overrides)
    assert(not accepted, label .. " was accepted by the production artifact inspector")
    if expected_category then
      eq(category, expected_category, label .. " structural failure category")
    end
  end

  local mutation_lock_fixture = {
    root = mutation_tree.root,
    state = mutation_tree.state,
    owned_process = nil,
  }
  local function assert_full_lock_restored(label)
    local lock_root = mutation_tree.state .. "/opencode/locks"
    local lock = lock_root .. "/" .. fixed_lock
    for path, node_type in pairs({
      [lock_root] = "directory",
      [lock] = "directory",
      [artifact_paths.heartbeat] = "file",
      [artifact_paths.metadata] = "file",
    }) do
      local stat = assert(vim.uv.fs_lstat(path), label .. " restored node is absent")
      eq(stat.type, node_type, label .. " restored node type")
      eq(stat.uid, vim.uv.getuid(), label .. " restored node owner")
      eq(
        require("bit").band(stat.mode, 511),
        node_type == "directory" and 448 or 384,
        label .. " restored node mode"
      )
    end
    assert(fixture_read(artifact_paths.heartbeat) == "", "restored heartbeat bytes differ")
    assert(
      fixture_read(artifact_paths.metadata) == valid_lock_metadata(),
      "restored metadata bytes differ"
    )
  end
  for _, case in ipairs({
    { form = "absent", disposition = "quiescent", fingerprint = "absent" },
    { form = "empty-root", disposition = "quiescent", fingerprint = "empty" },
    { form = "empty-directory", disposition = "transient" },
    { form = "heartbeat", disposition = "transient" },
    { form = "metadata", disposition = "transient" },
    { form = "full", disposition = "quiescent" },
  }) do
    lock_fixture.create_form(mutation_lock_fixture, case.form)
    local snapshot, category =
      registry_module._test.inspect_opencode_probe_artifacts(mutation_tree, true)
    assert(snapshot, case.form .. " retained lock form failed: " .. tostring(category))
    eq(snapshot.disposition, case.disposition, case.form .. " retained lock disposition")
    if case.fingerprint then
      eq(snapshot.fingerprint, case.fingerprint, case.form .. " retained lock fingerprint")
    elseif case.form == "full" then
      assert(
        type(snapshot.fingerprint) == "string"
          and snapshot.fingerprint:match("^full:[0-9a-f]+$")
          and #snapshot.fingerprint == 69,
        "full retained lock fingerprint"
      )
    end
    lock_fixture.create_form(mutation_lock_fixture, "full")
    assert_full_lock_restored(case.form .. " lock form")
  end

  local unknown_lock_entry = mutation_tree.state .. "/opencode/unknown-lock-entry"
  fixture_create(unknown_lock_entry, "unknown")
  artifacts_rejected("unknown lock-root entry", nil, "probe-lock-tree")
  assert(vim.uv.fs_unlink(unknown_lock_entry))
  local unknown_lock_stat, _, unknown_lock_code = vim.uv.fs_lstat(unknown_lock_entry)
  assert(
    unknown_lock_stat == nil and unknown_lock_code == "ENOENT",
    "unknown lock-root entry was not removed"
  )
  lock_fixture.create_form(mutation_lock_fixture, "full")
  assert_full_lock_restored("unknown lock-root entry")

  local metadata_bytes = fixture_read(artifact_paths.metadata)
  local altered_metadata, replacements = metadata_bytes:gsub('"pid": 2', '"pid": 3', 1)
  eq(replacements, 1, "lock metadata fixture mutation")
  fixture_write(artifact_paths.metadata, altered_metadata)
  artifacts_rejected("altered probe lock metadata")
  lock_fixture.create_form(mutation_lock_fixture, "full")
  assert_full_lock_restored("altered probe lock metadata")

  assert(vim.uv.fs_unlink(artifact_paths.heartbeat))
  assert(vim.uv.fs_symlink(artifact_paths.log, artifact_paths.heartbeat))
  artifacts_rejected("artifact symlink")
  lock_fixture.create_form(mutation_lock_fixture, "full")
  assert_full_lock_restored("artifact symlink")

  local exact_artifact_summary = {
    lock = "directory",
    database_sha256 = "40cf07c52bfaa52b334ef341456f970787f6dc701ffe18ad3c572cb5056dbd70",
    database_size = 4096,
    shared_memory_size = 32768,
    write_ahead_log_size = 259592,
  }
  eq({
    lock = assert(vim.uv.fs_lstat(mutation_tree.state .. "/opencode/locks/" .. fixed_lock)).type,
    database_sha256 = vim.fn.sha256(fixture_read(artifact_paths.database)),
    database_size = assert(vim.uv.fs_lstat(artifact_paths.database)).size,
    shared_memory_size = assert(vim.uv.fs_lstat(artifact_paths.shared_memory)).size,
    write_ahead_log_size = assert(vim.uv.fs_lstat(artifact_paths.write_ahead_log)).size,
  }, exact_artifact_summary, "retained clean real artifact shape")

  local function restore_artifact(path, bytes, label)
    fixture_write(path, bytes)
    assert(fixture_read(path) == bytes, "restored artifact bytes differ")
    eq(require("bit").band(assert(vim.uv.fs_lstat(path)).mode, 511), 384, label .. " mode restored")
  end

  fixture_create(artifact_paths.unknown, "unknown")
  artifacts_rejected("unknown artifact")
  assert(vim.uv.fs_unlink(artifact_paths.unknown))
  local unknown_stat, _, unknown_code = vim.uv.fs_lstat(artifact_paths.unknown)
  assert(unknown_stat == nil and unknown_code == "ENOENT", "unknown artifact was not removed")

  local retained_log_bytes = fixture_read(artifact_paths.log)
  fixture_write(artifact_paths.log, "forbidden log")
  artifacts_rejected("nonempty probe log")
  restore_artifact(artifact_paths.log, retained_log_bytes, "nonempty probe log")

  local startup_log_suffixes = {
    'message="creating instance" directory=/tmp/nvim-ai-probe',
    "message=fromDirectory directory=/tmp/nvim-ai-probe",
    "message=bootstrapping directory=/tmp/nvim-ai-probe",
    "message=loading path=/tmp/nvim-ai-probe/xdg-config/opencode/config.json",
    "message=loading path=/tmp/nvim-ai-probe/xdg-config/opencode/opencode.json",
    "message=loading path=/tmp/nvim-ai-probe/xdg-config/opencode/opencode.jsonc",
    'message="all LSPs are disabled"',
    'message="all formatters are disabled"',
    "message=init",
  }
  local function startup_log_fixture(timestamps, run_identifiers, suffixes)
    local lines = {}
    suffixes = suffixes or startup_log_suffixes
    for index, suffix in ipairs(suffixes) do
      local timestamp = type(timestamps) == "table" and timestamps[index] or timestamps
      local run_identifier = type(run_identifiers) == "table" and run_identifiers[index]
        or run_identifiers
      lines[index] =
        string.format("timestamp=%s level=INFO run=%s %s", timestamp, run_identifier, suffix)
    end
    return table.concat(lines, "\n") .. "\n"
  end

  local startup_time = os.time()
  local startup_timestamp = os.date("!%Y-%m-%dT%H:%M:%S.000Z", startup_time)
  local exact_startup_log = startup_log_fixture(startup_timestamp, "deadbeef")
  eq(#exact_startup_log, 994, "exact audited startup-log size")
  fixture_write(artifact_paths.log, exact_startup_log)
  assert(
    registry_module._test.inspect_opencode_probe_artifacts(mutation_tree, true),
    "exact audited startup log was rejected"
  )
  restore_artifact(artifact_paths.log, retained_log_bytes, "exact audited startup log")

  local changed_runs = vim.tbl_map(function()
    return "deadbeef"
  end, startup_log_suffixes)
  changed_runs[#changed_runs] = "feedface"
  fixture_write(artifact_paths.log, startup_log_fixture(startup_timestamp, changed_runs))
  artifacts_rejected("inconsistent startup-log run identifier", nil, "probe-log-run-identifier")
  restore_artifact(
    artifact_paths.log,
    retained_log_bytes,
    "inconsistent startup-log run identifier"
  )

  fixture_write(artifact_paths.log, startup_log_fixture(startup_timestamp, "DEADBEEF"))
  artifacts_rejected("invalid startup-log run identifier", nil, "probe-log-run-identifier")
  restore_artifact(artifact_paths.log, retained_log_bytes, "invalid startup-log run identifier")

  local invalid_timestamp = startup_timestamp:sub(1, 5) .. "13" .. startup_timestamp:sub(8)
  fixture_write(artifact_paths.log, startup_log_fixture(invalid_timestamp, "deadbeef"))
  artifacts_rejected("invalid startup-log timestamp", nil, "probe-log-timestamp-shape")
  restore_artifact(artifact_paths.log, retained_log_bytes, "invalid startup-log timestamp")

  local reversed_timestamps = vim.tbl_map(function()
    return startup_timestamp
  end, startup_log_suffixes)
  reversed_timestamps[2] = os.date("!%Y-%m-%dT%H:%M:%S.000Z", startup_time - 1)
  fixture_write(artifact_paths.log, startup_log_fixture(reversed_timestamps, "deadbeef"))
  artifacts_rejected("reversed startup-log timestamp", nil, "probe-log-timestamp-order")
  restore_artifact(artifact_paths.log, retained_log_bytes, "reversed startup-log timestamp")

  local changed_suffixes = vim.deepcopy(startup_log_suffixes)
  changed_suffixes[#changed_suffixes] = "message=unit"
  fixture_write(
    artifact_paths.log,
    startup_log_fixture(startup_timestamp, "deadbeef", changed_suffixes)
  )
  local changed_log_accepted, changed_log_category =
    registry_module._test.inspect_opencode_probe_artifacts(mutation_tree, true)
  assert(not changed_log_accepted, "changed fixed startup-log message was accepted")
  assert(
    type(changed_log_category) == "string"
      and changed_log_category:match("^probe%-log%-normalized%-digest:[0-9a-f]+$")
      and #changed_log_category == #"probe-log-normalized-digest:" + 64,
    "changed startup-log message returned an unsafe structural digest"
  )
  restore_artifact(artifact_paths.log, retained_log_bytes, "changed startup-log message")

  local reordered_suffixes = vim.deepcopy(startup_log_suffixes)
  reordered_suffixes[1], reordered_suffixes[2] = reordered_suffixes[2], reordered_suffixes[1]
  fixture_write(
    artifact_paths.log,
    startup_log_fixture(startup_timestamp, "deadbeef", reordered_suffixes)
  )
  artifacts_rejected("reordered startup-log messages")
  restore_artifact(artifact_paths.log, retained_log_bytes, "reordered startup-log messages")

  local changed_path_suffixes = vim.deepcopy(startup_log_suffixes)
  changed_path_suffixes[4] = changed_path_suffixes[4]:gsub("config.json", "confjg.json")
  fixture_write(
    artifact_paths.log,
    startup_log_fixture(startup_timestamp, "deadbeef", changed_path_suffixes)
  )
  artifacts_rejected("changed startup-log path")
  restore_artifact(artifact_paths.log, retained_log_bytes, "changed startup-log path")

  local changed_level_log = exact_startup_log:gsub("level=INFO", "level=WARN", 1)
  eq(#changed_level_log, 994, "changed startup-log level preserves audited size")
  fixture_write(artifact_paths.log, changed_level_log)
  artifacts_rejected("changed startup-log level", nil, "probe-log-line-shape")
  restore_artifact(artifact_paths.log, retained_log_bytes, "changed startup-log level")

  local forbidden_startup_suffixes = vim.deepcopy(startup_log_suffixes)
  forbidden_startup_suffixes[#forbidden_startup_suffixes] = "http://evilx"
  fixture_write(
    artifact_paths.log,
    startup_log_fixture(startup_timestamp, "deadbeef", forbidden_startup_suffixes)
  )
  artifacts_rejected("forbidden startup-log evidence", nil, "probe-log-forbidden-evidence")
  restore_artifact(artifact_paths.log, retained_log_bytes, "forbidden startup-log evidence")

  local missing_line_break_log = exact_startup_log:gsub("\n", " ", 1)
  eq(#missing_line_break_log, 994, "changed startup-log line count preserves audited size")
  fixture_write(artifact_paths.log, missing_line_break_log)
  artifacts_rejected("changed startup-log line count", nil, "probe-log-line-count")
  restore_artifact(artifact_paths.log, retained_log_bytes, "changed startup-log line count")

  fixture_write(artifact_paths.log, exact_startup_log .. "unknown\n")
  artifacts_rejected("extra startup-log line", nil, "probe-log-size")
  restore_artifact(artifact_paths.log, retained_log_bytes, "extra startup-log line")

  local database_bytes = fixture_read(artifact_paths.database)
  fixture_write(artifact_paths.database, "X" .. database_bytes:sub(2))
  artifacts_rejected("altered probe database")
  restore_artifact(artifact_paths.database, database_bytes, "altered probe database")

  local write_ahead_log_bytes = fixture_read(artifact_paths.write_ahead_log)
  fixture_write(artifact_paths.write_ahead_log, write_ahead_log_bytes:sub(1, -2))
  artifacts_rejected("altered probe write-ahead log")
  restore_artifact(
    artifact_paths.write_ahead_log,
    write_ahead_log_bytes,
    "altered probe write-ahead log"
  )

  local function flip_artifact_byte(bytes, offset)
    return bytes:sub(1, offset - 1)
      .. string.char(require("bit").bxor(bytes:byte(offset), 1))
      .. bytes:sub(offset + 1)
  end

  local SQLITE_U32_MODULO = 4294967296

  local function artifact_u32(bytes, offset, little_endian)
    local first, second, third, fourth = bytes:byte(offset, offset + 3)
    assert(fourth, "complete artifact u32")
    if little_endian then
      return first + second * 256 + third * 65536 + fourth * 16777216
    end
    return first * 16777216 + second * 65536 + third * 256 + fourth
  end

  local function artifact_pack_u32(value, little_endian)
    value = value % SQLITE_U32_MODULO
    local first = math.floor(value / 16777216) % 256
    local second = math.floor(value / 65536) % 256
    local third = math.floor(value / 256) % 256
    local fourth = value % 256
    if little_endian then
      return string.char(fourth, third, second, first)
    end
    return string.char(first, second, third, fourth)
  end

  local function artifact_replace(bytes, offset, replacement)
    return bytes:sub(1, offset - 1) .. replacement .. bytes:sub(offset + #replacement)
  end

  local function artifact_sqlite_checksum(bytes, offset, length, checksum0, checksum1)
    for index = offset, offset + length - 1, 8 do
      local word0 = artifact_u32(bytes, index, true)
      local word1 = artifact_u32(bytes, index + 4, true)
      checksum0 = (checksum0 + word0 + checksum1) % SQLITE_U32_MODULO
      checksum1 = (checksum1 + word1 + checksum0) % SQLITE_U32_MODULO
    end
    return checksum0, checksum1
  end

  local function rechecksum_artifact_wal(bytes)
    local checksum0, checksum1 = artifact_sqlite_checksum(bytes, 1, 24, 0, 0)
    bytes = artifact_replace(
      bytes,
      25,
      artifact_pack_u32(checksum0, false) .. artifact_pack_u32(checksum1, false)
    )
    for frame = 0, 62 do
      local base = 33 + frame * 4120
      checksum0, checksum1 = artifact_sqlite_checksum(bytes, base, 8, checksum0, checksum1)
      checksum0, checksum1 = artifact_sqlite_checksum(bytes, base + 24, 4096, checksum0, checksum1)
      bytes = artifact_replace(
        bytes,
        base + 16,
        artifact_pack_u32(checksum0, false) .. artifact_pack_u32(checksum1, false)
      )
    end
    return bytes
  end

  local function link_artifact_shm_to_wal(shared_memory, write_ahead_log)
    local final_frame = 33 + 62 * 4120
    local checksum0 = artifact_u32(write_ahead_log, final_frame + 16, false)
    local checksum1 = artifact_u32(write_ahead_log, final_frame + 20, false)
    local header = artifact_replace(
      shared_memory,
      25,
      artifact_pack_u32(checksum0, true) .. artifact_pack_u32(checksum1, true)
    )
    header = artifact_replace(header, 33, write_ahead_log:sub(17, 24))
    checksum0, checksum1 = artifact_sqlite_checksum(header, 1, 40, 0, 0)
    header = artifact_replace(
      header,
      41,
      artifact_pack_u32(checksum0, true) .. artifact_pack_u32(checksum1, true)
    )
    return artifact_replace(header, 49, header:sub(1, 48))
  end

  local function artifact_u48_be(bytes, offset)
    local value = 0
    for index = offset, offset + 5 do
      value = value * 256 + bytes:byte(index)
    end
    return value
  end

  local function artifact_pack_u48_be(value)
    local bytes = {}
    for index = 6, 1, -1 do
      bytes[index] = string.char(value % 256)
      value = math.floor(value / 256)
    end
    return table.concat(bytes)
  end

  local unchecked_same_size_mutations = {}
  local function require_same_size_mutation_rejection(label, expected_category)
    local accepted, category =
      registry_module._test.inspect_opencode_probe_artifacts(mutation_tree, true)
    if accepted then
      unchecked_same_size_mutations[#unchecked_same_size_mutations + 1] = label
    elseif expected_category then
      eq(category, expected_category, label .. " structural failure category")
    end
  end

  fixture_write(
    artifact_paths.write_ahead_log,
    flip_artifact_byte(write_ahead_log_bytes, #write_ahead_log_bytes)
  )
  require_same_size_mutation_rejection("same-size WAL final-byte flip", "sqlite-wal-frame-checksum")
  restore_artifact(artifact_paths.write_ahead_log, write_ahead_log_bytes, "WAL final-byte flip")

  fixture_write(artifact_paths.write_ahead_log, flip_artifact_byte(write_ahead_log_bytes, 1000))
  require_same_size_mutation_rejection("same-size WAL interior-byte flip")
  restore_artifact(artifact_paths.write_ahead_log, write_ahead_log_bytes, "WAL interior-byte flip")

  fixture_write(artifact_paths.write_ahead_log, flip_artifact_byte(write_ahead_log_bytes, 25))
  require_same_size_mutation_rejection("corrupt WAL header checksum")
  restore_artifact(artifact_paths.write_ahead_log, write_ahead_log_bytes, "WAL header checksum")

  fixture_write(artifact_paths.write_ahead_log, flip_artifact_byte(write_ahead_log_bytes, 49))
  require_same_size_mutation_rejection("corrupt WAL frame checksum")
  restore_artifact(artifact_paths.write_ahead_log, write_ahead_log_bytes, "WAL frame checksum")

  local shared_memory_bytes = fixture_read(artifact_paths.shared_memory)
  fixture_write(
    artifact_paths.shared_memory,
    flip_artifact_byte(shared_memory_bytes, #shared_memory_bytes)
  )
  require_same_size_mutation_rejection("same-size SHM final-byte flip")
  restore_artifact(artifact_paths.shared_memory, shared_memory_bytes, "SHM final-byte flip")

  local corrupt_shm_header_checksum = flip_artifact_byte(shared_memory_bytes, 41)
  corrupt_shm_header_checksum = flip_artifact_byte(corrupt_shm_header_checksum, 89)
  fixture_write(artifact_paths.shared_memory, corrupt_shm_header_checksum)
  require_same_size_mutation_rejection("corrupt duplicated SHM header checksum")
  restore_artifact(artifact_paths.shared_memory, shared_memory_bytes, "SHM header checksum")

  local corrupt_shm_frame_checksum = flip_artifact_byte(shared_memory_bytes, 25)
  corrupt_shm_frame_checksum = flip_artifact_byte(corrupt_shm_frame_checksum, 73)
  fixture_write(artifact_paths.shared_memory, corrupt_shm_frame_checksum)
  require_same_size_mutation_rejection("corrupt duplicated SHM WAL-checksum linkage")
  restore_artifact(artifact_paths.shared_memory, shared_memory_bytes, "SHM WAL-checksum linkage")

  local rechecksummed_interior_wal =
    rechecksum_artifact_wal(flip_artifact_byte(write_ahead_log_bytes, 1000))
  local relinked_interior_shm =
    link_artifact_shm_to_wal(shared_memory_bytes, rechecksummed_interior_wal)
  fixture_write(artifact_paths.write_ahead_log, rechecksummed_interior_wal)
  fixture_write(artifact_paths.shared_memory, relinked_interior_shm)
  require_same_size_mutation_rejection("rechecksummed WAL non-dynamic-byte flip")
  restore_artifact(
    artifact_paths.write_ahead_log,
    write_ahead_log_bytes,
    "rechecksummed WAL non-dynamic-byte flip"
  )
  restore_artifact(
    artifact_paths.shared_memory,
    shared_memory_bytes,
    "relinked SHM non-dynamic-byte flip"
  )

  local migration_timestamp_offset = 245568
  local migration_timestamp = artifact_u48_be(write_ahead_log_bytes, migration_timestamp_offset)
  local corrupt_timestamp_wal = artifact_replace(
    write_ahead_log_bytes,
    migration_timestamp_offset,
    artifact_pack_u48_be(migration_timestamp + 5000)
  )
  corrupt_timestamp_wal = rechecksum_artifact_wal(corrupt_timestamp_wal)
  local corrupt_timestamp_shm = link_artifact_shm_to_wal(shared_memory_bytes, corrupt_timestamp_wal)
  fixture_write(artifact_paths.write_ahead_log, corrupt_timestamp_wal)
  fixture_write(artifact_paths.shared_memory, corrupt_timestamp_shm)
  require_same_size_mutation_rejection("rechecksummed inconsistent migration timestamp")
  restore_artifact(
    artifact_paths.write_ahead_log,
    write_ahead_log_bytes,
    "rechecksummed migration timestamp"
  )
  restore_artifact(artifact_paths.shared_memory, shared_memory_bytes, "migration timestamp SHM")

  local project_created_offset = 255459
  local project_updated_offset = 255465
  local project_created = artifact_u48_be(write_ahead_log_bytes, project_created_offset)
  local function write_project_timestamps(created, updated)
    local wal =
      artifact_replace(write_ahead_log_bytes, project_created_offset, artifact_pack_u48_be(created))
    wal = artifact_replace(wal, project_updated_offset, artifact_pack_u48_be(updated))
    wal = rechecksum_artifact_wal(wal)
    fixture_write(artifact_paths.write_ahead_log, wal)
    fixture_write(artifact_paths.shared_memory, link_artifact_shm_to_wal(shared_memory_bytes, wal))
  end

  write_project_timestamps(project_created, project_created + 1)
  assert(
    registry_module._test.inspect_opencode_probe_artifacts(mutation_tree, true),
    "one-millisecond project timestamp progression was rejected"
  )
  restore_artifact(artifact_paths.write_ahead_log, write_ahead_log_bytes, "valid project timestamp")
  restore_artifact(artifact_paths.shared_memory, shared_memory_bytes, "valid project timestamp SHM")

  write_project_timestamps(project_created, project_created - 1)
  artifacts_rejected(
    "reversed project timestamp progression",
    nil,
    "sqlite-wal-project-timestamp-order"
  )
  restore_artifact(
    artifact_paths.write_ahead_log,
    write_ahead_log_bytes,
    "reversed project timestamp"
  )
  restore_artifact(
    artifact_paths.shared_memory,
    shared_memory_bytes,
    "reversed project timestamp SHM"
  )

  write_project_timestamps(project_created, project_created + 5001)
  artifacts_rejected(
    "over-window project timestamp progression",
    nil,
    "sqlite-wal-project-timestamp-span"
  )
  restore_artifact(
    artifact_paths.write_ahead_log,
    write_ahead_log_bytes,
    "over-window project timestamp"
  )
  restore_artifact(
    artifact_paths.shared_memory,
    shared_memory_bytes,
    "over-window project timestamp SHM"
  )

  assert(
    #unchecked_same_size_mutations == 0,
    "production artifact inspector accepted: " .. table.concat(unchecked_same_size_mutations, "; ")
  )

  local corrupt_wal_salt = flip_artifact_byte(write_ahead_log_bytes, 41)
  fixture_write(artifact_paths.write_ahead_log, corrupt_wal_salt)
  artifacts_rejected("corrupt WAL frame salt")
  restore_artifact(artifact_paths.write_ahead_log, write_ahead_log_bytes, "WAL frame salt")

  local corrupt_shm_salt = flip_artifact_byte(shared_memory_bytes, 33)
  corrupt_shm_salt = flip_artifact_byte(corrupt_shm_salt, 81)
  fixture_write(artifact_paths.shared_memory, corrupt_shm_salt)
  artifacts_rejected("corrupt duplicated SHM salt linkage")
  restore_artifact(artifact_paths.shared_memory, shared_memory_bytes, "SHM salt linkage")

  assert(vim.uv.fs_chmod(artifact_paths.log, 420))
  artifacts_rejected("wrong artifact mode")
  restore_artifact(artifact_paths.log, retained_log_bytes, "wrong artifact mode")

  artifacts_rejected("wrong artifact owner", {
    lstat = function(path)
      local stat = vim.uv.fs_lstat(path)
      if path == artifact_paths.log and stat then
        stat = vim.deepcopy(stat)
        stat.uid = stat.uid + 1
      end
      return stat
    end,
  })

  local replacement_lstat_calls = 0
  artifacts_rejected("artifact replacement", {
    lstat = function(path)
      local stat = vim.uv.fs_lstat(path)
      if path == artifact_paths.database and stat then
        replacement_lstat_calls = replacement_lstat_calls + 1
        if replacement_lstat_calls > 1 then
          stat = vim.deepcopy(stat)
          stat.ino = stat.ino + 1
        end
      end
      return stat
    end,
  })
  assert(replacement_lstat_calls > 1, "artifact replacement check did not revalidate identity")

  local directory_path = mutation_tree.cache .. "/opencode"
  local directory_lstat_calls = 0
  artifacts_rejected("artifact directory replacement", {
    lstat = function(path)
      local stat = vim.uv.fs_lstat(path)
      if path == directory_path and stat then
        directory_lstat_calls = directory_lstat_calls + 1
        if directory_lstat_calls > 1 then
          stat = vim.deepcopy(stat)
          stat.ino = stat.ino + 1
        end
      end
      return stat
    end,
  })
  assert(directory_lstat_calls > 1, "artifact directory replacement was not revalidated")

  fixture_create(artifact_paths.unknown, "unknown")
  local parked_directory = mutation_tree.cache .. "/opencode-parked"
  local descriptor_swap_exercised = false
  artifacts_rejected("descriptor-bound directory swap", {
    scandir = function(path)
      local target = vim.uv.fs_readlink(path)
      if not descriptor_swap_exercised and target == directory_path then
        assert(vim.uv.fs_rename(directory_path, parked_directory))
        assert(vim.fn.mkdir(directory_path, "", 448) == 1)
        local request = assert(vim.uv.fs_scandir(path))
        assert(vim.uv.fs_rmdir(directory_path))
        assert(vim.uv.fs_rename(parked_directory, directory_path))
        descriptor_swap_exercised = true
        return request
      end
      return vim.uv.fs_scandir(path)
    end,
  })
  assert(descriptor_swap_exercised, "artifact enumeration did not use its directory descriptor")
  assert(vim.uv.fs_unlink(artifact_paths.unknown))
  local swapped_unknown, _, swapped_unknown_code = vim.uv.fs_lstat(artifact_paths.unknown)
  assert(
    swapped_unknown == nil and swapped_unknown_code == "ENOENT",
    "descriptor-bound swap left its unknown artifact"
  )

  local bootstrap_bytes = fixture_read(artifact_paths.bootstrap)
  fixture_write(artifact_paths.bootstrap, bootstrap_bytes .. "\n")
  artifacts_rejected("altered configuration bootstrap")
  restore_artifact(artifact_paths.bootstrap, bootstrap_bytes, "altered configuration bootstrap")
  assert(vim.uv.fs_chmod(artifact_paths.bootstrap, 420))
  artifacts_rejected("wrong configuration bootstrap mode")
  restore_artifact(artifact_paths.bootstrap, bootstrap_bytes, "wrong configuration bootstrap mode")

  lock_fixture.create_form(mutation_lock_fixture, "full")
  assert_full_lock_restored("final retained lock form")
  assert(
    registry_module._test.inspect_opencode_probe_artifacts(mutation_tree, true),
    "restored retained artifact tree was rejected"
  )
  assert(
    shutdown_for_exit(),
    "real compatibility shutdown is unproven; retained="
      .. retention_root
      .. " shutdown="
      .. shutdown_category()
  )
  assert(
    retention_root_state(false) ~= nil,
    "guarded compatibility retention root changed before cleanup"
  )
  preserve_retention = false
  local cleanup_ok, cleaned = pcall(cleanup_retention_root)
  local retention_cleaned = cleanup_ok and cleaned == true
  if not retention_cleaned then
    preserve_retention = true
  end
  assert(
    retention_cleaned,
    "guarded compatibility retention cleanup failed; retained="
      .. retention_root
      .. " shutdown="
      .. shutdown_category()
  )
  local retention_descriptor_closed = close_fixture_descriptor(retention_root_descriptor)
  if not retention_descriptor_closed then
    preserve_retention = true
  end
  assert(
    retention_descriptor_closed,
    "guarded compatibility retention root descriptor close is unproven"
  )
  retention_root_descriptor = nil
  retention_root_identity_ready = false
  local retained, _, retained_code = vim.uv.fs_lstat(retention_root)
  local retention_absent = retained == nil and retained_code == "ENOENT"
  if not retention_absent then
    retention_live = true
    preserve_retention = true
  end
  assert(retention_absent, "compatibility retention root remains")
end)()

print("AI managed OpenCode assertions: ok")
