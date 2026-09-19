local function eq(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    string.format("%s\nexpected: %s\nactual: %s", label, vim.inspect(expected), vim.inspect(actual))
  )
end

local function contains(value, needle, label)
  assert(
    tostring(value):find(needle, 1, true),
    string.format("%s\nexpected text containing: %s\nactual: %s", label, needle, tostring(value))
  )
end

local registry_module = require("ai.backends")
local managed = require("ai.backends.opencode_managed")

eq(registry_module.names(), { "codex", "claude", "opencode" }, "backend order")

local identity = {
  key = string.rep("a", 32),
  root = "/work/repo",
  inside_git = true,
  git_dir = "/git/worktrees/repo",
  git_common_dir = "/git",
  git_entry = "/work/repo/.git",
  owner_pane = "%12",
  tmux_socket = "/tmp/tmux/default",
  namespace = "tmux:/tmp/tmux/default:41:9001",
}
local paths = {
  state = "/state/identity",
  backend_state = "/state/identity/backends/codex",
  event_file = "/run/identity/events.ndjson",
  event_helper = "/config/nvim/scripts/nvim-ai-event.py",
  python = "/usr/bin/python3",
  global_codex_home = "/home/user/.codex",
  global_claude_config = "/home/user/.claude",
  global_claude_home_file = "/home/user/.claude.json",
  global_opencode_data = "/home/user/.local/share/opencode",
  home_agents = "/home/user/AGENTS.md",
  profile_helper = "/config/nvim/scripts/nvim-ai-opencode-profile.py",
  grants = {},
}

local directories = {
  ["/home/user/.codex"] = true,
  ["/home/user/.claude"] = true,
  ["/home/user"] = true,
  ["/home/user/.local/share/opencode"] = true,
}
local files = {
  ["/usr/bin/codex"] = true,
  ["/usr/bin/claude"] = true,
  ["/usr/bin/opencode"] = true,
  ["/home/user/.codex/auth.json"] = true,
  ["/home/user/.codex/config.toml"] = true,
  ["/home/user/.claude/settings.json"] = true,
  ["/home/user/.claude.json"] = true,
  ["/home/user/.local/share/opencode/auth.json"] = true,
  ["/config/nvim/scripts/nvim-ai-opencode-profile.py"] = true,
  ["/usr/bin/python3"] = true,
}
local help_text = {
  codex = {
    ["--help"] = "-C --sandbox --ask-for-approval --add-dir",
    ["resume\0--help"] = "--last -C --sandbox --ask-for-approval --add-dir",
  },
  claude = {
    ["--help"] = "--session-id --resume --permission-mode --add-dir --settings",
  },
  opencode = {
    ["--help"] = "serve attach",
    ["serve\0--help"] = "--hostname --port OPENCODE_SERVER_PASSWORD",
    ["attach\0--help"] = "--dir --session",
  },
}
local profile_token = string.rep("b", 32)
local profile_fingerprint = string.rep("c", 64)
local prepared_profile = {
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
  credential_count = 1,
}
local compatibility_report = managed._test.compatibility_fixture()
local compatibility_state = {
  snapshot = {
    state = "ready",
    installed = true,
    executable = "/usr/bin/opencode",
    version = "1.18.30",
    category = "",
    queued = false,
  },
  report = vim.deepcopy(compatibility_report),
  ensures = {},
  cancels = {},
  subscriptions = {},
  shutdowns = {},
  snapshot_calls = 0,
  report_calls = 0,
}
local fake_validation = {
  snapshot = function()
    compatibility_state.snapshot_calls = compatibility_state.snapshot_calls + 1
    return vim.deepcopy(compatibility_state.snapshot)
  end,
  report = function()
    compatibility_state.report_calls = compatibility_state.report_calls + 1
    return vim.deepcopy(compatibility_state.report)
  end,
  ensure = function(_, request)
    compatibility_state.ensures[#compatibility_state.ensures + 1] = vim.deepcopy(request)
    return vim.deepcopy(compatibility_state.snapshot)
  end,
  take_open = function(_, identity_key)
    compatibility_state.take_open = identity_key
    return false
  end,
  cancel = function(_, reason)
    compatibility_state.cancels[#compatibility_state.cancels + 1] = reason
  end,
  subscribe = function(_, callback)
    compatibility_state.subscriptions[#compatibility_state.subscriptions + 1] = callback
    return function() end
  end,
  shutdown = function(_, exit_committed)
    assert(type(exit_committed) == "boolean", "fake shutdown phase")
    compatibility_state.shutdowns[#compatibility_state.shutdowns + 1] = exit_committed
    return true
  end,
}
local calls = {
  executable = {},
  revalidate = {},
  version = {},
  auth = {},
  help = {},
  inspect_auth = {},
  prepare = {},
  inspect_profile = {},
  port = 0,
  password = 0,
  profile_token = 0,
}
local registry = registry_module._test.new({
  executable = function(name)
    table.insert(calls.executable, name)
    return "/usr/bin/" .. name
  end,
  revalidate = function(executable)
    table.insert(calls.revalidate, executable)
    return true
  end,
  version = function(name, executable)
    table.insert(calls.version, { name, executable })
    local output = name == "opencode" and "1.18.30\n" or name .. " 1.0\n"
    return { code = 0, signal = 0, stdout = output, stderr = "" }
  end,
  auth = function(name, executable)
    table.insert(calls.auth, { name, executable })
    assert(name ~= "opencode", "OpenCode must never invoke auth list")
    local output = {
      codex = "Logged in using ChatGPT\n",
      claude = '{"loggedIn":true}\n',
    }
    return { code = 0, signal = 0, stdout = assert(output[name]), stderr = "" }
  end,
  help = function(name, executable, arguments)
    table.insert(calls.help, { name, executable, vim.deepcopy(arguments) })
    return {
      code = 0,
      signal = 0,
      stdout = assert(help_text[name][table.concat(arguments, "\0")]),
      stderr = "",
    }
  end,
  uuid = function()
    return "11111111-1111-4111-8111-111111111111"
  end,
  port = function()
    calls.port = calls.port + 1
    return 43123
  end,
  password = function()
    calls.password = calls.password + 1
    return "0123456789abcdef0123456789abcdef"
  end,
  profile_token = function()
    calls.profile_token = calls.profile_token + 1
    return profile_token
  end,
  prepare_opencode_profile = function(request)
    calls.prepare[#calls.prepare + 1] = vim.deepcopy(request)
    return vim.deepcopy(prepared_profile)
  end,
  inspect_opencode_profile = function(request)
    calls.inspect_profile[#calls.inspect_profile + 1] = vim.deepcopy(request)
    return vim.deepcopy(prepared_profile)
  end,
  inspect_opencode_auth = function(path)
    calls.inspect_auth[#calls.inspect_auth + 1] = path
    return "authenticated"
  end,
  opencode_auth_path = function()
    return "/home/user/.local/share/opencode/auth.json"
  end,
  opencode_validation = fake_validation,
  stat = function(path)
    if directories[path] then
      return { type = "directory", mode = 448, uid = 1000 }
    end
    if files[path] then
      return {
        type = "file",
        mode = path:match("^/usr/bin/") and 493 or 384,
        uid = path:match("^/usr/bin/") and 0 or 1000,
      }
    end
    return nil
  end,
  uid = function()
    return 1000
  end,
})

eq(calls.executable, {}, "registry construction is lazy")
eq(registry:names(), { "codex", "claude", "opencode" }, "injected backend order")
eq(registry:get("missing"), nil, "unknown backend lookup")

local codex = assert(registry:get("codex"))
eq(codex:new_session(identity, paths), {
  kind = "direct",
  backend = "codex",
  argv = {
    "/usr/bin/codex",
    "-C",
    "/work/repo",
    "--sandbox",
    "workspace-write",
    "--ask-for-approval",
    "on-request",
  },
  env = { CODEX_HOME = "/state/identity/backends/codex" },
  session = "last",
  capabilities = { approval = false, busy = false, completion = false, exact_session = false },
  read_only_inputs = {
    {
      source = "/home/user/.codex/auth.json",
      destination = "/state/identity/backends/codex/auth.json",
      kind = "file",
    },
  },
  config_seed = "/home/user/.codex/config.toml",
  protected_paths = { "/home/user/.codex", "/usr/bin/codex" },
}, "Codex new session")

eq(codex:resume_session(identity, paths, "last").argv, {
  "/usr/bin/codex",
  "resume",
  "--last",
  "-C",
  "/work/repo",
  "--sandbox",
  "workspace-write",
  "--ask-for-approval",
  "on-request",
}, "Codex isolated resume")
local invalid_codex, invalid_codex_error = codex:resume_session(identity, paths, "other")
eq(invalid_codex, nil, "Codex rejects an ambiguous session")
contains(invalid_codex_error, "session", "Codex session error")

paths.backend_state = "/state/identity/backends/claude"
local claude = assert(registry:get("claude"))
local claude_launch = assert(claude:new_session(identity, paths))
local settings_index
for index, argument in ipairs(claude_launch.argv) do
  if argument == "--settings" then
    settings_index = index
  end
end
assert(settings_index, "Claude explicitly loads ephemeral hook settings")
local settings = vim.json.decode(claude_launch.argv[settings_index + 1])
eq(vim.tbl_keys(settings), { "hooks" }, "ephemeral settings contain only lifecycle hooks")
local hook_names = vim.tbl_keys(settings.hooks)
table.sort(hook_names)
eq(hook_names, {
  "PermissionRequest",
  "PostToolUse",
  "PreToolUse",
  "SessionEnd",
  "SessionStart",
  "Stop",
  "UserPromptSubmit",
}, "only approved Claude hooks are installed")
local hook_command =
  "'/usr/bin/python3' -I -B '/config/nvim/scripts/nvim-ai-event.py' claude-hook --event-file '/run/identity/events.ndjson'"
for _, hooks in pairs(settings.hooks) do
  eq(
    hooks,
    { { hooks = { { type = "command", command = hook_command, timeout = 5 } } } },
    "hook argv is fixed and contains no event payload"
  )
end
eq(claude_launch.session, "11111111-1111-4111-8111-111111111111", "Claude UUID")
eq(claude_launch.argv, {
  "/usr/bin/claude",
  "--session-id",
  "11111111-1111-4111-8111-111111111111",
  "--permission-mode",
  "acceptEdits",
  "--settings",
  claude_launch.argv[settings_index + 1],
}, "Claude new session")
eq(claude_launch.env, {
  CLAUDE_CONFIG_DIR = "/state/identity/backends/claude",
}, "Claude isolated config")
eq(claude_launch.capabilities, {
  approval = true,
  busy = true,
  completion = true,
  exact_session = true,
}, "Claude capabilities")
eq(claude_launch.read_only_inputs, {
  {
    source = "/home/user/.claude/settings.json",
    destination = "/state/identity/backends/claude/settings.json",
    kind = "file",
  },
}, "Claude read-only settings")
eq(claude_launch.protected_paths, {
  "/home/user/.claude",
  "/home/user/.claude.json",
  "/usr/bin/claude",
}, "Claude protected paths")
eq(claude:resume_session(identity, paths, claude_launch.session).argv, {
  "/usr/bin/claude",
  "--resume",
  "11111111-1111-4111-8111-111111111111",
  "--permission-mode",
  "acceptEdits",
  "--settings",
  claude_launch.argv[settings_index + 1],
}, "Claude resume")
local invalid_claude, invalid_claude_error = claude:resume_session(identity, paths, "not-a-uuid")
eq(invalid_claude, nil, "Claude rejects invalid UUID")
contains(invalid_claude_error, "session", "Claude session error")

paths.backend_state = "/state/identity/backends/opencode"
local opencode = assert(registry:get("opencode"))
local ready_compatibility_snapshot = vim.deepcopy(compatibility_state.snapshot)
local function launch_side_effect_counts()
  return {
    prepare = #calls.prepare,
    inspect_profile = #calls.inspect_profile,
    port = calls.port,
    password = calls.password,
    profile_token = calls.profile_token,
  }
end

for _, case in ipairs({
  {
    label = "not checked",
    snapshot = {
      state = "not_checked",
      installed = true,
      executable = "/usr/bin/opencode",
      version = "",
      category = "",
      queued = false,
    },
    report = compatibility_report,
  },
  {
    label = "checking",
    snapshot = {
      state = "checking",
      installed = true,
      executable = "/usr/bin/opencode",
      version = "",
      category = "",
      queued = true,
    },
    report = compatibility_report,
  },
  {
    label = "failed",
    snapshot = {
      state = "failed",
      installed = true,
      executable = "/usr/bin/opencode",
      version = "",
      category = "timeout",
      queued = false,
    },
    report = compatibility_report,
  },
  {
    label = "malformed snapshot",
    snapshot = { state = "ready", private = "snapshot-secret-canary" },
    report = compatibility_report,
  },
  {
    label = "stale executable",
    snapshot = {
      state = "ready",
      installed = true,
      executable = "/usr/bin/stale-opencode",
      version = "1.18.30",
      category = "",
      queued = false,
    },
    report = compatibility_report,
  },
  {
    label = "missing report",
    snapshot = ready_compatibility_snapshot,
    report = false,
  },
  {
    label = "invalid report",
    snapshot = ready_compatibility_snapshot,
    report = vim.tbl_extend("force", vim.deepcopy(compatibility_report), { version = "1.18.19" }),
  },
}) do
  compatibility_state.snapshot = vim.deepcopy(case.snapshot)
  compatibility_state.report = case.report == false and nil or vim.deepcopy(case.report)
  local before = launch_side_effect_counts()
  local launch, launch_error = opencode:new_session(identity, paths)
  eq(launch, nil, case.label .. " launch is refused")
  eq(
    launch_error,
    "managed OpenCode compatibility is not ready",
    case.label .. " launch diagnostic"
  )
  eq(launch_side_effect_counts(), before, case.label .. " starts no launch preparation")
end

compatibility_state.snapshot = {
  state = "checking",
  installed = true,
  executable = "/usr/bin/opencode",
  version = "",
  category = "",
  queued = true,
}
compatibility_state.report = vim.deepcopy(compatibility_report)
local blocked_resume_paths = vim.deepcopy(paths)
blocked_resume_paths.opencode_profile = {
  token = profile_token,
  fingerprint = profile_fingerprint,
  version = "1.18.30",
}
local blocked_resume_before = launch_side_effect_counts()
local blocked_resume, blocked_resume_error =
  opencode:resume_session(identity, blocked_resume_paths, "ses_test123")
eq(blocked_resume, nil, "checking resume is refused")
eq(
  blocked_resume_error,
  "managed OpenCode compatibility is not ready",
  "checking resume diagnostic"
)
eq(launch_side_effect_counts(), blocked_resume_before, "checking resume inspects no profile")

compatibility_state.snapshot = vim.deepcopy(ready_compatibility_snapshot)
compatibility_state.report = vim.deepcopy(compatibility_report)
local opencode_launch = assert(opencode:new_session(identity, paths))
eq(opencode_launch.event_url, "http://127.0.0.1:43123/event", "OpenCode launcher-private event URL")
eq(opencode_launch.event_file, paths.event_file, "OpenCode launcher-private event file")
eq(opencode_launch.kind, "server_attach", "OpenCode launch kind")
eq(opencode_launch.server_argv, {
  "/usr/bin/opencode",
  "--pure",
  "serve",
  "--hostname",
  "127.0.0.1",
  "--port",
  "43123",
}, "OpenCode server")
eq(opencode_launch.attach_argv, {
  "/usr/bin/opencode",
  "--pure",
  "attach",
  "http://127.0.0.1:43123",
  "--dir",
  "/work/repo",
}, "OpenCode attach")
eq(opencode_launch.env, {
  OPENCODE_DISABLE_AUTOUPDATE = "true",
  OPENCODE_DISABLE_CLAUDE_CODE = "true",
  OPENCODE_DISABLE_EXTERNAL_SKILLS = "true",
  OPENCODE_DISABLE_LSP_DOWNLOAD = "true",
  OPENCODE_DISABLE_PROJECT_CONFIG = "true",
  OPENCODE_PERMISSION = managed.policy_json(),
  OPENCODE_PURE = "true",
  OPENCODE_SERVER_PASSWORD = "0123456789abcdef0123456789abcdef",
  OPENCODE_SERVER_USERNAME = "opencode",
  XDG_CACHE_HOME = "/state/identity/backends/opencode/xdg-cache",
  XDG_CONFIG_HOME = "/state/identity/backends/opencode/xdg-config",
  XDG_DATA_HOME = "/state/identity/backends/opencode/xdg-data",
  XDG_STATE_HOME = "/state/identity/backends/opencode/xdg-state",
}, "OpenCode isolated environment")
eq(opencode_launch.session, "", "OpenCode starts without a guessed session")
eq(opencode_launch.capabilities, {
  approval = true,
  busy = true,
  completion = true,
  exact_session = true,
}, "OpenCode capabilities")
eq(opencode_launch.read_only_inputs, {}, "raw global OpenCode inputs excluded")
eq(opencode_launch.protected_paths, {
  prepared_profile.profile_root,
  "/usr/bin/opencode",
}, "OpenCode protected paths")
eq(opencode_launch.managed_profile, {
  schema = 1,
  version = "1.18.30",
  profile_root = prepared_profile.profile_root,
  fingerprint = profile_fingerprint,
  config_source = prepared_profile.config_source,
  auth_source = prepared_profile.auth_source,
  home_mask_source = prepared_profile.home_mask_source,
}, "OpenCode launch strips helper-private profile fields")
eq(calls.prepare, {
  {
    schema = 1,
    token = profile_token,
    identity_key = identity.key,
    root = identity.root,
    backend_state = paths.backend_state,
    global_auth = paths.global_opencode_data .. "/auth.json",
    user_agents = paths.home_agents,
    repo_agents = identity.root .. "/AGENTS.md",
    version = "1.18.30",
    config_json = managed.config_json(),
    policy_json = managed.policy_json(),
  },
}, "OpenCode helper receives the exact approved prepare request")

local resume_paths = vim.deepcopy(paths)
resume_paths.opencode_profile = {
  token = profile_token,
  fingerprint = profile_fingerprint,
  version = "1.18.30",
}
local opencode_resume = assert(opencode:resume_session(identity, resume_paths, "ses_test123"))
eq(opencode_resume.attach_argv, {
  "/usr/bin/opencode",
  "--pure",
  "attach",
  "http://127.0.0.1:43123",
  "--dir",
  "/work/repo",
  "--session",
  "ses_test123",
}, "OpenCode exact resume")
eq(
  opencode_resume.managed_profile.profile_root,
  opencode_launch.managed_profile.profile_root,
  "OpenCode resume reuses profile"
)
eq(#calls.prepare, 1, "OpenCode reuse does not prepare a replacement profile")
eq(calls.inspect_profile, {
  {
    schema = 1,
    backend_state = paths.backend_state,
    token = profile_token,
    identity_key = identity.key,
    root = identity.root,
    version = "1.18.30",
    fingerprint = profile_fingerprint,
  },
}, "OpenCode reuse inspects only the exact nonsecret reference")
eq(opencode_resume.env.OPENCODE_PERMISSION, managed.policy_json(), "OpenCode resume permission")
eq(opencode_resume.env.OPENCODE_DISABLE_AUTOUPDATE, "true", "OpenCode resume update policy")
eq(opencode_resume.env.OPENCODE_DISABLE_LSP_DOWNLOAD, "true", "OpenCode resume LSP download policy")
eq(
  assert(opencode:profile_reference(opencode_launch)),
  resume_paths.opencode_profile,
  "OpenCode profile reference"
)
eq(
  assert(opencode:validate_profile(resume_paths.opencode_profile, identity, paths)),
  opencode_launch.managed_profile,
  "OpenCode profile reference validation"
)
eq(#calls.prepare, 1, "profile validation never prepares a replacement")
local invalid_opencode, invalid_opencode_error =
  opencode:resume_session(identity, paths, "../foreign")
eq(invalid_opencode, nil, "OpenCode rejects invalid session")
contains(invalid_opencode_error, "session", "OpenCode session error")

local bad_reference_paths = vim.deepcopy(resume_paths)
bad_reference_paths.opencode_profile.fingerprint = string.rep("d", 64)
local prepare_before_bad_reference = #calls.prepare
local invalid_reference, invalid_reference_error =
  opencode:resume_session(identity, bad_reference_paths, "ses_test123")
eq(invalid_reference, nil, "invalid managed profile reference fails closed")
contains(invalid_reference_error, "profile", "invalid profile reference diagnostic")
eq(#calls.prepare, prepare_before_bad_reference, "invalid reference has no fresh-profile fallback")

local foreign_profile_paths = vim.deepcopy(paths)
foreign_profile_paths.opencode_profile = resume_paths.opencode_profile
local foreign_codex = codex:new_session(identity, foreign_profile_paths)
eq(foreign_codex, nil, "Codex rejects an OpenCode profile reference")
local foreign_claude = claude:new_session(identity, foreign_profile_paths)
eq(foreign_claude, nil, "Claude rejects an OpenCode profile reference")

eq(
  codex:format_context({ kind = "location", path = "lua/main.lua", line = 7, column = 3 }),
  "Regarding lua/main.lua:7:3: ",
  "Codex location context"
)
eq(
  claude:format_context({
    kind = "selection",
    path = "lua/main.lua",
    first = 7,
    last = 9,
    context_file = "/run/context/abc.txt",
  }),
  "Use the exact selection from lua/main.lua:7-9 stored at /run/context/abc.txt: ",
  "Claude selection context"
)

eq(codex:suspend(), { signal = 1, timeout = 2000 }, "suspend policy")
eq(codex:stop(), { signal = 15, timeout = 2000 }, "stop policy")
eq(claude:session_reference(claude_launch), claude_launch.session, "Claude session reference")
eq(opencode:session_reference(opencode_launch), "", "OpenCode empty session reference")

paths.backend_state = "/state/identity/backends/codex"
paths.grants = { "/extra/a", "/extra/b" }
local granted = assert(codex:new_session(identity, paths))
eq(vim.list_slice(granted.argv, #granted.argv - 3), {
  "--add-dir",
  "/extra/a",
  "--add-dir",
  "/extra/b",
}, "sorted Codex grants")
paths.grants = { "/extra/b", "/extra/a" }
local unsorted, unsorted_error = codex:new_session(identity, paths)
eq(unsorted, nil, "unsorted grants refused")
contains(unsorted_error, "sorted", "unsorted grant error")
paths.grants = {}

-- CLI directory hints may be wider than an exact file bind; the manifest's
-- grant remains that file, so the outer sandbox cannot write any sibling.
files["/extra/only.txt"] = true
local file_grant_paths = vim.deepcopy(paths)
file_grant_paths.grants = { "/extra/only.txt" }
local file_grant_launch = assert(codex:new_session(identity, file_grant_paths))
eq(
  vim.list_slice(file_grant_launch.argv, #file_grant_launch.argv - 1),
  { "--add-dir", "/extra" },
  "Codex receives a valid directory hint for one file"
)
file_grant_paths.backend_state = "/state/identity/backends/claude"
file_grant_launch = assert(claude:new_session(identity, file_grant_paths))
eq(
  vim.list_slice(file_grant_launch.argv, #file_grant_launch.argv - 1),
  { "--add-dir", "/extra" },
  "Claude receives a valid directory hint for one file"
)
eq(file_grant_paths.grants, { "/extra/only.txt" }, "adapter never widens manifest file grant")

local first_capabilities = codex:capabilities()
first_capabilities.approval = true
eq(codex:capabilities().approval, false, "capabilities are fresh")
local first_launch = assert(codex:new_session(identity, paths))
first_launch.argv[1] = "/changed"
eq(assert(codex:new_session(identity, paths)).argv[1], "/usr/bin/codex", "launch tables are fresh")
local opencode_paths = vim.deepcopy(paths)
opencode_paths.backend_state = "/state/identity/backends/opencode"
local first_opencode_launch = assert(opencode:new_session(identity, opencode_paths))
first_opencode_launch.env.OPENCODE_PERMISSION = "changed"
local fresh_opencode_launch = assert(opencode:new_session(identity, opencode_paths))
eq(
  fresh_opencode_launch.env.OPENCODE_PERMISSION,
  managed.policy_json(),
  "OpenCode permission tables are fresh"
)

local before_health_revalidations = #calls.revalidate
for _, name in ipairs(registry_module.names()) do
  local health = registry:health(name)
  eq(health.installed, true, name .. " installed")
  eq(health.executable, "/usr/bin/" .. name, name .. " executable")
  assert(type(health.version) == "string" and health.version ~= "", name .. " version")
  eq(health.auth, "authenticated", name .. " authentication")
  assert(type(health.capabilities) == "table", name .. " capabilities")
  eq(health.error, "", name .. " health error")
  if name == "opencode" then
    eq(health.compatibility, "ready", "OpenCode ready compatibility state")
  end
end
assert(#calls.revalidate > before_health_revalidations, "health revalidates executables")
eq(calls.help, {
  { "codex", "/usr/bin/codex", { "--help" } },
  { "codex", "/usr/bin/codex", { "resume", "--help" } },
  { "claude", "/usr/bin/claude", { "--help" } },
}, "exact compatibility help probes")
eq(
  calls.inspect_auth,
  { "/home/user/.local/share/opencode/auth.json" },
  "OpenCode health inspects only the approved global auth file"
)
eq(compatibility_state.ensures, {}, "health never starts validation")

local auth_reads_before_passive_health = #calls.inspect_auth
do
  compatibility_state.snapshot = {
    state = "failed",
    installed = true,
    executable = "/usr/bin/opencode",
    version = "1.18.31",
    category = "version-mismatch",
    queued = false,
  }
  local report_calls = compatibility_state.report_calls
  local health = registry:health("opencode")
  eq(health.version, "1.18.31", "mismatch health shows the detected release")
  eq(
    health.error,
    "managed OpenCode version mismatch: installed 1.18.31; requires 1.18.30",
    "mismatch health explains the exact audited release"
  )
  eq(health.auth, "unknown", "mismatch skips authentication")
  eq(health.capabilities, {}, "mismatch grants no capabilities")
  eq(compatibility_state.report_calls, report_calls, "mismatch reads no report")
  for _, version in ipairs({ "", "1.18.30", "1.18.31 private-canary", "1.18.31\n", "01.18.31" }) do
    compatibility_state.snapshot.version = version
    health = registry:health("opencode")
    eq(health.version, "", "malformed mismatch retains no version")
    eq(
      health.error,
      "managed OpenCode compatibility failed: probe-failure",
      "malformed mismatch snapshot fails closed without leaking bytes"
    )
  end
end
for _, case in ipairs({
  {
    state = "not_checked",
    category = "",
    queued = false,
    error = "managed OpenCode compatibility not checked",
  },
  {
    state = "checking",
    category = "",
    queued = true,
    error = "managed OpenCode compatibility checking",
  },
  {
    state = "failed",
    category = "timeout",
    queued = false,
    error = "managed OpenCode compatibility failed: timeout",
  },
}) do
  compatibility_state.snapshot = {
    state = case.state,
    installed = true,
    executable = "/usr/bin/opencode",
    version = "",
    category = case.category,
    queued = case.queued,
  }
  local report_calls = compatibility_state.report_calls
  local health = registry:health("opencode")
  eq(health.compatibility, case.state, case.state .. " health state")
  eq(health.version, "", case.state .. " health has no version")
  eq(health.auth, "unknown", case.state .. " health skips authentication")
  eq(health.capabilities, {}, case.state .. " health has no capabilities")
  eq(health.error, case.error, case.state .. " bounded health diagnostic")
  eq(compatibility_state.report_calls, report_calls, case.state .. " health reads no report")
end

for _, case in ipairs({
  {
    label = "missing snapshot",
    snapshot = false,
    category = "probe-failure",
  },
  {
    label = "extra snapshot field",
    snapshot = vim.tbl_extend("force", vim.deepcopy(ready_compatibility_snapshot), {
      private = "snapshot-secret-canary",
    }),
    category = "probe-failure",
  },
  {
    label = "unknown snapshot state",
    snapshot = vim.tbl_extend("force", vim.deepcopy(ready_compatibility_snapshot), {
      state = "private-state-canary",
    }),
    category = "probe-failure",
  },
  {
    label = "invalid failure category",
    snapshot = {
      state = "failed",
      installed = true,
      executable = "/usr/bin/opencode",
      version = "",
      category = "private-category-canary",
      queued = false,
    },
    category = "probe-failure",
  },
  {
    label = "ready executable drift",
    snapshot = vim.tbl_extend("force", vim.deepcopy(ready_compatibility_snapshot), {
      executable = "/usr/bin/stale-opencode",
    }),
    category = "executable-drift",
  },
}) do
  compatibility_state.snapshot = case.snapshot == false and nil or vim.deepcopy(case.snapshot)
  local report_calls = compatibility_state.report_calls
  local health = registry:health("opencode")
  eq(health.compatibility, "failed", case.label .. " maps to failed")
  eq(health.capabilities, {}, case.label .. " has no capabilities")
  eq(
    health.error,
    "managed OpenCode compatibility failed: " .. case.category,
    case.label .. " bounded diagnostic"
  )
  eq(compatibility_state.report_calls, report_calls, case.label .. " reads no report")
  assert(
    not vim.inspect(health):find("private", 1, true),
    case.label .. " leaked malformed snapshot data"
  )
end
eq(
  #calls.inspect_auth,
  auth_reads_before_passive_health,
  "non-ready health reads no authentication"
)
eq(compatibility_state.ensures, {}, "passive health never ensures compatibility")

compatibility_state.snapshot = {
  state = "checking",
  installed = true,
  executable = "/usr/bin/opencode",
  version = "",
  category = "",
  queued = true,
}
local direct_snapshot = registry:opencode_compatibility()
direct_snapshot.state = "failed"
direct_snapshot.executable = "private-snapshot-mutation"
eq(registry:opencode_compatibility(), {
  state = "checking",
  installed = true,
  executable = "/usr/bin/opencode",
  version = "",
  category = "",
  queued = true,
}, "direct compatibility snapshots are fresh and passive")
eq(compatibility_state.ensures, {}, "direct snapshot never ensures compatibility")
compatibility_state.snapshot = vim.deepcopy(ready_compatibility_snapshot)
compatibility_state.report = vim.deepcopy(compatibility_report)
eq(registry_module._test.auth_arguments("codex"), { "login", "status" }, "Codex auth argv")
eq(
  registry_module._test.auth_arguments("claude"),
  { "auth", "status", "--json" },
  "Claude auth argv"
)
eq(registry_module._test.auth_arguments("opencode"), nil, "OpenCode has no auth-list argv")
for _, call in ipairs(calls.auth) do
  assert(call[1] ~= "opencode", "OpenCode invoked auth list")
end

local function health_with_auth(name, result)
  local fixture = registry_module._test.new({
    executable = function(requested)
      return "/usr/bin/" .. requested
    end,
    revalidate = function()
      return true
    end,
    version = function(requested)
      return { code = 0, signal = 0, stdout = requested .. " 1.0\n", stderr = "" }
    end,
    auth = function(requested)
      eq(requested, name, "authentication parser backend")
      return vim.deepcopy(result)
    end,
    help = function(requested, _, arguments)
      return {
        code = 0,
        signal = 0,
        stdout = assert(help_text[requested][table.concat(arguments, "\0")]),
        stderr = "",
      }
    end,
    stat = function(path)
      return files[path] and { type = "file", mode = 493, uid = 0 } or nil
    end,
    uid = function()
      return 1000
    end,
  })
  return fixture:health(name)
end

local auth_cases = {
  {
    "codex",
    { code = 0, signal = 0, stdout = "Logged in using ChatGPT\n", stderr = "" },
    "authenticated",
    "Codex explicit login",
  },
  {
    "codex",
    { code = 0, signal = 0, stdout = "", stderr = "Logged in using ChatGPT\n" },
    "authenticated",
    "Codex explicit login on stderr",
  },
  {
    "codex",
    {
      code = 0,
      signal = 0,
      stdout = "",
      stderr = "WARNING: Read-only file system\n\27[32mLogged in using ChatGPT\27[0m\r\n",
    },
    "authenticated",
    "Codex stderr login survives a sandbox startup warning",
  },
  {
    "codex",
    {
      code = 0,
      signal = 0,
      stdout = "",
      stderr = "Logged in using an API key - redacted-key-sentinel\n",
    },
    "authenticated",
    "Codex stderr API key login stays private",
  },
  {
    "codex",
    { code = 1, signal = 0, stdout = "", stderr = "Logged in using ChatGPT\n" },
    "unknown",
    "Codex positive stderr cannot override a failed probe",
  },
  {
    "codex",
    {
      code = 0,
      signal = 0,
      stdout = "Not logged in\n",
      stderr = "Logged in using ChatGPT\n",
    },
    "unauthenticated",
    "Codex stdout logout overrides stderr login",
  },
  {
    "codex",
    {
      code = 0,
      signal = 0,
      stdout = "Logged in using ChatGPT\n",
      stderr = "Not logged in\n",
    },
    "unauthenticated",
    "Codex stderr logout overrides stdout login",
  },
  {
    "codex",
    { code = 0, signal = 0, stdout = "", stderr = "Logged in using ChatGPT extra\n" },
    "unknown",
    "Codex stderr login still requires a complete recognized line",
  },
  {
    "codex",
    {
      code = 0,
      signal = 0,
      stdout = "Logged in using an API key - redacted-key-sentinel\n",
      stderr = "",
    },
    "authenticated",
    "Codex API key login",
  },
  {
    "codex",
    { code = 0, signal = 0, stdout = "Logged in using workload identity\n", stderr = "" },
    "authenticated",
    "Codex workload identity login",
  },
  {
    "codex",
    { code = 0, signal = 0, stdout = "Logged in using access token\n", stderr = "" },
    "authenticated",
    "Codex access token login",
  },
  {
    "codex",
    { code = 0, signal = 0, stdout = "Logged in using personal access token\n", stderr = "" },
    "authenticated",
    "Codex personal access token login",
  },
  {
    "codex",
    { code = 0, signal = 0, stdout = "Logged in using Amazon Bedrock API key\n", stderr = "" },
    "authenticated",
    "Codex Bedrock login",
  },
  {
    "codex",
    { code = 0, signal = 0, stdout = "Logged in using Agent Identity\n", stderr = "" },
    "authenticated",
    "Codex legacy agent identity login",
  },
  {
    "codex",
    { code = 1, signal = 0, stdout = "Not logged in\n", stderr = "" },
    "unauthenticated",
    "Codex explicit logout on failure",
  },
  {
    "codex",
    { code = 1, signal = 0, stdout = "", stderr = "Not logged in\n" },
    "unauthenticated",
    "Codex explicit logout on stderr",
  },
  {
    "codex",
    { code = 0, signal = 0, stdout = "Codex is ready\n", stderr = "" },
    "unknown",
    "Codex ambiguous success",
  },
  {
    "codex",
    { code = 0, signal = 0, stdout = "Logged in using surprise provider\n", stderr = "" },
    "unknown",
    "Codex arbitrary login suffix",
  },
  {
    "codex",
    { code = 0, signal = 0, stdout = "Logged in using ChatGPT extra\n", stderr = "" },
    "unknown",
    "Codex known login with extra suffix",
  },
  {
    "claude",
    { code = 0, signal = 0, stdout = '{"loggedIn":true}\n', stderr = "" },
    "authenticated",
    "Claude JSON login",
  },
  {
    "claude",
    { code = 1, signal = 0, stdout = '{"loggedIn":false}\n', stderr = "" },
    "unauthenticated",
    "Claude JSON logout on failure",
  },
  {
    "claude",
    { code = 1, signal = 0, stdout = "", stderr = '{"loggedIn":false}\n' },
    "unknown",
    "Claude ignores JSON-shaped stderr",
  },
  {
    "claude",
    { code = 0, signal = 0, stdout = '{"loggedIn":"yes"}\n', stderr = "" },
    "unknown",
    "Claude ambiguous JSON",
  },
  {
    "claude",
    { code = 0, signal = 0, stdout = "not json\n", stderr = "" },
    "unknown",
    "Claude malformed JSON",
  },
}
for _, case in ipairs(auth_cases) do
  local health = health_with_auth(case[1], case[2])
  eq(health.auth, case[3], case[4])
  assert(#health.error <= 256, case[4] .. " diagnostic exceeds byte cap")
  local serialized_health = vim.inspect(health)
  for _, private_text in ipairs({ "private-provider-name", "redacted-key-sentinel" }) do
    assert(
      not serialized_health:find(private_text, 1, true),
      case[4] .. " leaks authentication detail"
    )
  end
end

local function managed_health(overrides)
  local options = overrides or {}
  local order = {}
  local controller = {
    snapshot = function()
      order[#order + 1] = "snapshot"
      if options.snapshot_exception then
        error(options.snapshot_exception)
      end
      return vim.deepcopy(options.snapshot or ready_compatibility_snapshot)
    end,
    report = function()
      order[#order + 1] = "report"
      if options.compatibility_error then
        error(options.compatibility_error)
      end
      return vim.deepcopy(options.compatibility or compatibility_report)
    end,
    ensure = function()
      error("health must not ensure compatibility")
    end,
    take_open = function()
      return false
    end,
    cancel = function() end,
    subscribe = function()
      return function() end
    end,
    shutdown = function()
      return true
    end,
  }
  local fixture = registry_module._test.new({
    executable = function(name)
      order[#order + 1] = "executable"
      return "/usr/bin/" .. name
    end,
    revalidate = function()
      order[#order + 1] = "revalidate"
      return true
    end,
    opencode_validation = controller,
    opencode_auth_path = function()
      order[#order + 1] = "auth_path"
      return "/home/user/.local/share/opencode/auth.json"
    end,
    inspect_opencode_auth = function(path)
      order[#order + 1] = "inspect_auth"
      eq(path, "/home/user/.local/share/opencode/auth.json", "managed auth inspection path")
      if options.auth_exception then
        error(options.auth_exception)
      end
      return options.auth or "authenticated", options.auth_error
    end,
    stat = function(path)
      return path == "/usr/bin/opencode" and { type = "file", mode = 493, uid = 0 } or nil
    end,
    uid = function()
      return 1000
    end,
  })
  return fixture:health("opencode"), order
end

local healthy_opencode, healthy_order = managed_health()
eq(healthy_opencode.installed, true, "managed OpenCode is installed")
eq(healthy_opencode.version, "1.18.30", "managed OpenCode exact health version")
eq(healthy_opencode.auth, "authenticated", "managed OpenCode filtered authentication")
eq(healthy_opencode.capabilities, opencode:capabilities(), "managed OpenCode health capabilities")
eq(healthy_opencode.error, "", "managed OpenCode health succeeds")
eq(
  healthy_order,
  { "executable", "revalidate", "snapshot", "report", "auth_path", "inspect_auth" },
  "managed OpenCode health ordering"
)

local health_failures = {
  {
    label = "unknown exact version",
    compatibility_state = "failed",
    mutate = function(options)
      options.compatibility = vim.deepcopy(compatibility_report)
      options.compatibility.version = "1.18.19"
    end,
  },
  {
    label = "missing pure mode",
    compatibility_state = "failed",
    mutate = function(options)
      options.compatibility = vim.deepcopy(compatibility_report)
      options.compatibility.help.root[1] = "--unsafe"
    end,
  },
  {
    label = "malformed agent report",
    compatibility_state = "failed",
    mutate = function(options)
      options.compatibility = vim.deepcopy(compatibility_report)
      options.compatibility.agents.build = "malformed-agent-canary"
    end,
  },
  {
    label = "semantic helper failure",
    compatibility_state = "failed",
    mutate = function(options)
      options.compatibility_error = "compatibility-secret-canary"
    end,
  },
  {
    label = "unauthenticated filtered credentials",
    compatibility_state = "ready",
    mutate = function(options)
      options.auth = "unauthenticated"
    end,
  },
  {
    label = "authentication helper exception",
    compatibility_state = "ready",
    mutate = function(options)
      options.auth_exception = "credential-secret-canary"
    end,
  },
  {
    label = "unknown authentication",
    compatibility_state = "ready",
    mutate = function(options)
      options.auth = "unknown"
      options.auth_error = "credential-helper-private-canary"
    end,
  },
}
for _, case in ipairs(health_failures) do
  local options = {}
  case.mutate(options)
  local health = managed_health(options)
  eq(health.installed, true, case.label .. " remains detected")
  eq(health.compatibility, case.compatibility_state, case.label .. " compatibility state")
  eq(health.capabilities, {}, case.label .. " disables capabilities")
  assert(type(health.error) == "string" and health.error ~= "", case.label .. " has no error")
  assert(#health.error <= 256, case.label .. " error is unbounded")
  local serialized = vim.inspect(health)
  for _, canary in ipairs({
    "malformed-agent-canary",
    "compatibility-secret-canary",
    "credential-secret-canary",
    "credential-helper-private-canary",
  }) do
    assert(not serialized:find(canary, 1, true), case.label .. " leaked private output")
  end
end

local absent_calls = 0
local absent = registry_module._test.new({
  executable = function()
    return nil, "not found"
  end,
  revalidate = function()
    absent_calls = absent_calls + 1
    return true
  end,
  version = function()
    absent_calls = absent_calls + 1
  end,
  auth = function()
    absent_calls = absent_calls + 1
  end,
  help = function()
    absent_calls = absent_calls + 1
  end,
  stat = function()
    return nil
  end,
  uid = function()
    return 1000
  end,
})
local absent_health = absent:health("codex")
eq(absent_health.installed, false, "absent executable")
eq(absent_calls, 0, "absent backend runs no probes")

local function absent_opencode_health(options)
  local calls = {
    order = {},
    ensure = 0,
    report = 0,
    auth_path = 0,
    inspect_auth = 0,
    revalidate = 0,
    stat = 0,
  }
  local controller = {
    snapshot = function()
      calls.order[#calls.order + 1] = "snapshot"
      if options.snapshot_exception then
        error({ private = "snapshot-secret-canary" })
      end
      return vim.deepcopy(options.snapshot)
    end,
    report = function()
      calls.report = calls.report + 1
      error("absent health read a compatibility report")
    end,
    ensure = function()
      calls.ensure = calls.ensure + 1
      error("absent health ensured compatibility")
    end,
  }
  local fixture = registry_module._test.new({
    executable = function(name)
      eq(name, "opencode", options.label .. " resolver backend")
      calls.order[#calls.order + 1] = "resolve"
      return nil, "resolver-secret-canary", false
    end,
    revalidate = function()
      calls.revalidate = calls.revalidate + 1
      error("absent health revalidated an executable")
    end,
    opencode_validation = controller,
    opencode_auth_path = function()
      calls.auth_path = calls.auth_path + 1
      error("absent health resolved authentication")
    end,
    inspect_opencode_auth = function()
      calls.inspect_auth = calls.inspect_auth + 1
      error("absent health inspected authentication")
    end,
    stat = function()
      calls.stat = calls.stat + 1
      error("absent health inspected the filesystem")
    end,
    uid = function()
      return 1000
    end,
  })
  return fixture:health("opencode"), calls
end

for _, case in ipairs({
  {
    label = "absent not checked",
    snapshot = {
      state = "not_checked",
      installed = false,
      executable = "",
      version = "",
      category = "",
      queued = false,
    },
    compatibility = "not_checked",
    error = "managed OpenCode compatibility not checked",
  },
  {
    label = "absent unavailable",
    snapshot = {
      state = "failed",
      installed = false,
      executable = "",
      version = "",
      category = "unavailable",
      queued = false,
    },
    compatibility = "failed",
    error = "managed OpenCode compatibility failed: unavailable",
  },
  {
    label = "absent malformed snapshot",
    snapshot = { state = "private-state-canary" },
    compatibility = "failed",
    error = "managed OpenCode compatibility failed: probe-failure",
  },
  {
    label = "absent throwing snapshot",
    snapshot_exception = true,
    compatibility = "failed",
    error = "managed OpenCode compatibility failed: probe-failure",
  },
}) do
  local health, absent_opencode_calls = absent_opencode_health(case)
  eq(health, {
    installed = false,
    executable = "",
    version = "",
    auth = "unknown",
    capabilities = {},
    compatibility = case.compatibility,
    error = case.error,
  }, case.label .. " health")
  eq(absent_opencode_calls.order, { "resolve", "snapshot" }, case.label .. " ordering")
  eq(absent_opencode_calls.ensure, 0, case.label .. " does not ensure")
  eq(absent_opencode_calls.report, 0, case.label .. " reads no report")
  eq(absent_opencode_calls.auth_path, 0, case.label .. " resolves no authentication path")
  eq(absent_opencode_calls.inspect_auth, 0, case.label .. " inspects no authentication")
  eq(absent_opencode_calls.revalidate, 0, case.label .. " revalidates no executable")
  eq(absent_opencode_calls.stat, 0, case.label .. " inspects no filesystem")
  assert(
    not vim.inspect(health):find("secret-canary", 1, true),
    case.label .. " leaked a dependency diagnostic"
  )
end

eq(registry:health("missing"), {
  installed = false,
  executable = "",
  version = "",
  auth = "unknown",
  capabilities = {},
  error = "unknown backend",
}, "unknown backend health is unchanged")

local facade_calls = {}
local facade_snapshot = {
  state = "checking",
  installed = true,
  executable = "/usr/bin/opencode",
  version = "",
  category = "",
  queued = true,
}
local facade_controller = {
  snapshot = function()
    facade_calls[#facade_calls + 1] = { "snapshot" }
    return vim.deepcopy(facade_snapshot)
  end,
  report = function()
    facade_calls[#facade_calls + 1] = { "report" }
    return vim.deepcopy(compatibility_report)
  end,
  ensure = function(_, request)
    facade_calls[#facade_calls + 1] = { "ensure", vim.deepcopy(request) }
    return vim.deepcopy(facade_snapshot)
  end,
  take_open = function(_, identity_key)
    facade_calls[#facade_calls + 1] = { "take_open", identity_key }
    return true
  end,
  cancel = function(_, reason)
    facade_calls[#facade_calls + 1] = { "cancel", reason }
  end,
  subscribe = function(_, callback)
    facade_calls[#facade_calls + 1] = { "subscribe", callback }
    return function()
      facade_calls[#facade_calls + 1] = { "unsubscribe" }
    end
  end,
  shutdown = function(_, exit_committed)
    facade_calls[#facade_calls + 1] = { "shutdown", exit_committed }
    return true
  end,
}
local facade = registry_module._test.new({
  executable = function()
    error("facade-executable-secret-canary")
  end,
  revalidate = function()
    error("facade-revalidate-secret-canary")
  end,
  stat = function()
    error("facade-stat-secret-canary")
  end,
  uid = function()
    return 1000
  end,
  opencode_validation = facade_controller,
})
eq(facade_calls, {}, "facade registry construction is passive")
eq(facade:names(), { "codex", "claude", "opencode" }, "facade names remain passive")
assert(type(facade:get("opencode")) == "table", "facade get returns OpenCode adapter")
eq(facade_calls, {}, "facade names and get do not touch the controller")
eq(facade:opencode_compatibility(), facade_snapshot, "facade forwards snapshot")
local facade_request = { reason = "open", identity_key = identity.key }
eq(facade:ensure_opencode_compatibility(facade_request), facade_snapshot, "facade forwards ensure")
eq(facade:take_opencode_open(identity.key), true, "facade forwards queued opening")
facade:cancel_opencode_compatibility("backend-switch")
local facade_observer = function() end
local unsubscribe = assert(facade:subscribe_opencode_compatibility(facade_observer))
unsubscribe()
local invalid_shutdown_ok = pcall(facade.shutdown, facade, "false")
eq(invalid_shutdown_ok, false, "registry shutdown requires an explicit boolean")
eq(facade:shutdown(true), true, "registry forwards committed shutdown")
local terminal_snapshot = facade:opencode_compatibility()
eq(terminal_snapshot, {
  state = "not_checked",
  installed = false,
  executable = "",
  version = "",
  category = "",
  queued = false,
}, "shutdown registry returns an idle compatibility snapshot")
terminal_snapshot.state = "failed"
eq(facade:opencode_compatibility(), {
  state = "not_checked",
  installed = false,
  executable = "",
  version = "",
  category = "",
  queued = false,
}, "shutdown registry returns fresh compatibility snapshots")
local terminal_ensure, terminal_ensure_error =
  facade:ensure_opencode_compatibility({ reason = "open", identity_key = identity.key })
eq(terminal_ensure, nil, "shutdown registry refuses compatibility ensure")
eq(
  terminal_ensure_error,
  "managed OpenCode compatibility request is invalid",
  "shutdown registry ensure diagnostic"
)
eq(facade:take_opencode_open(identity.key), false, "shutdown registry has no queued opening")
eq(
  facade:cancel_opencode_compatibility("backend-switch"),
  nil,
  "shutdown registry cancellation is inert"
)
local terminal_unsubscribe, terminal_subscribe_error = facade:subscribe_opencode_compatibility(
  function() end
)
eq(terminal_unsubscribe, nil, "shutdown registry refuses observers")
eq(
  terminal_subscribe_error,
  "managed OpenCode compatibility observer is unavailable",
  "shutdown registry observer diagnostic"
)
eq(facade:shutdown(false), true, "registry shutdown is idempotent")
eq(facade_calls, {
  { "snapshot" },
  { "ensure", facade_request },
  { "take_open", identity.key },
  { "cancel", "backend-switch" },
  { "subscribe", facade_observer },
  { "unsubscribe" },
  { "shutdown", true },
}, "all facades use one injected controller exactly once")

local unused_shutdowns = 0
local unused_starts = 0
local unused_controller_touches = 0
local unused_facade = registry_module._test.new({
  executable = function()
    error("unused facade resolved an executable")
  end,
  revalidate = function()
    error("unused facade revalidated an executable")
  end,
  stat = function()
    error("unused facade inspected the filesystem")
  end,
  uid = function()
    return 1000
  end,
  start_opencode_probe = function()
    unused_starts = unused_starts + 1
    error("unused facade started a probe")
  end,
  opencode_validation = setmetatable({}, {
    __index = function(_, method)
      unused_controller_touches = unused_controller_touches + 1
      if method == "shutdown" then
        return function()
          unused_shutdowns = unused_shutdowns + 1
          return true
        end
      end
      error("unused facade touched its controller")
    end,
  }),
})
eq(unused_facade:shutdown(false), true, "unused registry shutdown succeeds passively")
eq(unused_facade:opencode_compatibility(), {
  state = "not_checked",
  installed = false,
  executable = "",
  version = "",
  category = "",
  queued = false,
}, "unused shutdown registry remains terminal")
eq(unused_facade:shutdown(true), true, "unused registry shutdown remains idempotent")
eq(unused_shutdowns, 0, "unused registry shutdown does not touch an injected controller")
eq(unused_controller_touches, 0, "terminal facades never construct an injected controller")
eq(unused_starts, 0, "terminal facades never start a compatibility probe")

local terminal_ready_snapshot = {
  state = "ready",
  installed = true,
  executable = "/usr/bin/opencode",
  version = "1.18.30",
  category = "",
  queued = false,
}

local function new_terminal_registry(label, executable_present)
  local controller_calls = {
    snapshot = 0,
    report = 0,
    ensure = 0,
    shutdown = 0,
    start = 0,
  }
  local effects = {
    auth_path = 0,
    inspect_auth = 0,
    prepare = 0,
    inspect_profile = 0,
    port = 0,
    password = 0,
    profile_token = 0,
  }
  local controller = {
    snapshot = function()
      controller_calls.snapshot = controller_calls.snapshot + 1
      return vim.deepcopy(terminal_ready_snapshot)
    end,
    report = function()
      controller_calls.report = controller_calls.report + 1
      return vim.deepcopy(compatibility_report)
    end,
    ensure = function()
      controller_calls.ensure = controller_calls.ensure + 1
      return vim.deepcopy(terminal_ready_snapshot)
    end,
    shutdown = function(_, exit_committed)
      assert(type(exit_committed) == "boolean", label .. " shutdown phase")
      controller_calls.shutdown = controller_calls.shutdown + 1
      return true
    end,
  }
  local registry = registry_module._test.new({
    executable = function(name)
      eq(name, "opencode", label .. " executable backend")
      if executable_present then
        return "/usr/bin/opencode"
      end
      return nil, "terminal-resolver-secret-canary", false
    end,
    revalidate = function(executable)
      eq(executable, "/usr/bin/opencode", label .. " executable revalidation")
      return true
    end,
    opencode_validation = controller,
    start_opencode_probe = function()
      controller_calls.start = controller_calls.start + 1
      error("terminal registry started a probe")
    end,
    opencode_auth_path = function()
      effects.auth_path = effects.auth_path + 1
      return "/home/user/.local/share/opencode/auth.json"
    end,
    inspect_opencode_auth = function()
      effects.inspect_auth = effects.inspect_auth + 1
      return "authenticated"
    end,
    prepare_opencode_profile = function()
      effects.prepare = effects.prepare + 1
      return vim.deepcopy(prepared_profile)
    end,
    inspect_opencode_profile = function()
      effects.inspect_profile = effects.inspect_profile + 1
      return vim.deepcopy(prepared_profile)
    end,
    port = function()
      effects.port = effects.port + 1
      return 43123
    end,
    password = function()
      effects.password = effects.password + 1
      return "0123456789abcdef0123456789abcdef"
    end,
    profile_token = function()
      effects.profile_token = effects.profile_token + 1
      return profile_token
    end,
    stat = function(path)
      if path == "/usr/bin/opencode" and executable_present then
        return { type = "file", mode = 493, uid = 0 }
      end
      return nil
    end,
    uid = function()
      return 1000
    end,
  })
  local terminal_paths = vim.deepcopy(paths)
  terminal_paths.backend_state = "/state/identity/backends/opencode"
  terminal_paths.grants = {}
  terminal_paths.opencode_profile = nil
  local resume_paths = vim.deepcopy(terminal_paths)
  resume_paths.opencode_profile = {
    token = profile_token,
    fingerprint = profile_fingerprint,
    version = "1.18.30",
  }
  return {
    registry = registry,
    adapter = assert(registry:get("opencode")),
    controller_calls = controller_calls,
    effects = effects,
    paths = terminal_paths,
    resume_paths = resume_paths,
  }
end

local function terminal_health(executable_present)
  return {
    installed = executable_present,
    executable = executable_present and "/usr/bin/opencode" or "",
    version = "",
    auth = "unknown",
    capabilities = {},
    compatibility = "not_checked",
    error = "managed OpenCode compatibility not checked",
  }
end

local function assert_terminal_effects(fixture, label)
  eq(fixture.effects, {
    auth_path = 0,
    inspect_auth = 0,
    prepare = 0,
    inspect_profile = 0,
    port = 0,
    password = 0,
    profile_token = 0,
  }, label .. " has no authentication or launch effects")
end

for _, active in ipairs({ false, true }) do
  for _, executable_present in ipairs({ false, true }) do
    local label = string.format(
      "%s %s terminal registry",
      active and "active" or "unused",
      executable_present and "present" or "absent"
    )
    local fixture = new_terminal_registry(label, executable_present)
    if active then
      eq(
        fixture.registry:opencode_compatibility(),
        terminal_ready_snapshot,
        label .. " activates one controller"
      )
    end
    eq(fixture.registry:shutdown(false), true, label .. " first shutdown")
    eq(
      fixture.registry:health("opencode"),
      terminal_health(executable_present),
      label .. " registry health"
    )
    eq(
      fixture.adapter:health(),
      terminal_health(executable_present),
      label .. " retained adapter health"
    )
    local new_launch, new_error = fixture.adapter:new_session(identity, fixture.paths)
    eq(new_launch, nil, label .. " retained new session is refused")
    eq(
      new_error,
      "managed OpenCode compatibility is not ready",
      label .. " retained new-session diagnostic"
    )
    local resume_launch, resume_error =
      fixture.adapter:resume_session(identity, fixture.resume_paths, "ses_terminal123")
    eq(resume_launch, nil, label .. " retained resume is refused")
    eq(
      resume_error,
      "managed OpenCode compatibility is not ready",
      label .. " retained resume diagnostic"
    )
    eq(fixture.registry:shutdown(true), true, label .. " repeated shutdown is cached")
    eq(fixture.controller_calls, {
      snapshot = active and 1 or 0,
      report = 0,
      ensure = 0,
      shutdown = active and 1 or 0,
      start = 0,
    }, label .. " has exact controller access")
    assert_terminal_effects(fixture, label)
  end
end

for _, case in ipairs({
  {
    label = "signaled generic version probe",
    result = {
      code = 0,
      signal = 9,
      stdout = "codex 9.9 generic-signal-secret-canary\n",
      stderr = "",
    },
  },
  {
    label = "missing-signal generic version probe",
    result = {
      code = 0,
      stdout = "codex 9.9 generic-signal-secret-canary\n",
      stderr = "",
    },
  },
}) do
  local later_probe_calls = 0
  local signaled = registry_module._test.new({
    executable = function(name)
      return "/usr/bin/" .. name
    end,
    revalidate = function()
      return true
    end,
    version = function()
      return vim.deepcopy(case.result)
    end,
    auth = function()
      later_probe_calls = later_probe_calls + 1
      return { code = 0, signal = 0, stdout = "Logged in using ChatGPT\n", stderr = "" }
    end,
    help = function()
      later_probe_calls = later_probe_calls + 1
      return { code = 0, signal = 0, stdout = "", stderr = "" }
    end,
    stat = function(path)
      return files[path] and { type = "file", mode = 493, uid = 0 } or nil
    end,
    uid = function()
      return 1000
    end,
  })
  local health = signaled:health("codex")
  eq(health.version, "", case.label .. " is rejected")
  eq(health.auth, "unknown", case.label .. " skips authentication")
  eq(health.capabilities, {}, case.label .. " disables capabilities")
  eq(later_probe_calls, 0, case.label .. " skips later probes")
  assert(type(health.error) == "string" and health.error ~= "", case.label .. " is generic")
  assert(
    not vim.inspect(health):find("generic-signal-secret-canary", 1, true),
    case.label .. " leaked subprocess output"
  )
end

local incompatible = registry_module._test.new({
  executable = function(name)
    return "/usr/bin/" .. name
  end,
  revalidate = function()
    return true
  end,
  version = function()
    return { code = 0, signal = 0, stdout = "codex 1.0\n", stderr = "" }
  end,
  auth = function()
    error("authentication must not run for an incompatible CLI")
  end,
  help = function()
    return { code = 0, signal = 0, stdout = "--sandbox only", stderr = "" }
  end,
  stat = function(path)
    return files[path] and { type = "file", mode = 384, uid = 0 } or nil
  end,
  uid = function()
    return 1000
  end,
})
local incompatible_health = incompatible:health("codex")
eq(incompatible_health.installed, true, "incompatible CLI remains detected")
eq(incompatible_health.capabilities, {}, "incompatible CLI is disabled")
contains(incompatible_health.error, "incompatible", "incompatible health diagnostic")

local unsafe_paths = vim.deepcopy(paths)
unsafe_paths.global_codex_home = "/home/user/.unsafe-codex"
directories[unsafe_paths.global_codex_home] = true
files[unsafe_paths.global_codex_home .. "/auth.json"] = true
local original_stat = registry_module._test.new({
  executable = function(name)
    return "/usr/bin/" .. name
  end,
  revalidate = function()
    return true
  end,
  version = function()
    return { code = 0, signal = 0, stdout = "1", stderr = "" }
  end,
  auth = function()
    return { code = 0, signal = 0, stdout = "authenticated", stderr = "" }
  end,
  help = function()
    return { code = 0, signal = 0, stdout = "", stderr = "" }
  end,
  stat = function(path)
    if path == unsafe_paths.global_codex_home then
      return { type = "directory", mode = 511, uid = 1000 }
    end
    if files[path] then
      return { type = "file", mode = 384, uid = 1000 }
    end
    return nil
  end,
  uid = function()
    return 1000
  end,
})
local unsafe_launch, unsafe_error =
  assert(original_stat:get("codex")):new_session(identity, unsafe_paths)
eq(unsafe_launch, nil, "unsafe provider directory refused")
contains(unsafe_error, "unsafe mode", "unsafe provider directory diagnostic")

local uuid = registry_module._test.uuid(function(length)
  eq(length, 16, "UUID byte count")
  return string.char(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)
end)
eq(uuid, "00010203-0405-4607-8809-0a0b0c0d0e0f", "deterministic RFC-4122 UUID")
assert(
  uuid:match(
    "^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-4[0-9a-f][0-9a-f][0-9a-f]%-[89ab][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f]+$"
  ),
  "generated UUID is lowercase RFC-4122 version 4: " .. uuid
)

local probe_argv
local probe_options
local probe_revalidations = {}
local probe_result = registry_module._test.read_only_probe(
  "/usr/bin/codex",
  { "resume", "--help" },
  {
    resolve = function(name)
      eq(name, "bwrap", "probe resolves Bubblewrap")
      return "/usr/bin/bwrap"
    end,
    revalidate = function(path)
      assert(path == "/usr/bin/codex" or path == "/usr/bin/bwrap", "unexpected probe tool")
      probe_revalidations[#probe_revalidations + 1] = path
      return true
    end,
    environ = function()
      return {
        HOME = "/home/user",
        NVIM = "/run/nvim/socket",
        NVIM_LISTEN_ADDRESS = "/run/nvim/legacy",
        TMUX = "/tmp/tmux/default,1,2",
        TMUX_PANE = "%12",
      }
    end,
    run = function(argv, options)
      probe_argv = vim.deepcopy(argv)
      probe_options = vim.deepcopy(options)
      return { code = 0, signal = 0, stdout = "help", stderr = "" }
    end,
  }
)
eq(probe_result.code, 0, "read-only probe result")
eq(probe_argv, {
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
  "--",
  "/usr/bin/codex",
  "resume",
  "--help",
}, "read-only network-isolated probe argv")
eq(probe_options.clear_env, true, "probe clears inherited environment")
eq(probe_options.timeout, 2000, "probe timeout")
eq(probe_options.env, { HOME = "/home/user" }, "probe hides editor and tmux sockets")
eq(probe_revalidations, { "/usr/bin/codex", "/usr/bin/bwrap" }, "probe revalidates exact programs")

local unconfined_run = false
local missing_bwrap = registry_module._test.read_only_probe("/usr/bin/codex", { "--version" }, {
  resolve = function()
    return nil, "Bubblewrap missing"
  end,
  revalidate = function()
    return true
  end,
  environ = function()
    return {}
  end,
  run = function()
    unconfined_run = true
  end,
})
eq(missing_bwrap.code, 127, "missing Bubblewrap fails health probe")
eq(unconfined_run, false, "missing Bubblewrap never retries unconfined")

for _, method in ipairs({
  "opencode_compatibility",
  "ensure_opencode_compatibility",
  "take_opencode_open",
  "cancel_opencode_compatibility",
  "subscribe_opencode_compatibility",
  "shutdown",
}) do
  assert(type(registry_module[method]) == "function", "module facade is missing: " .. method)
end
local invalid_module_shutdown_ok = pcall(registry_module.shutdown, "false")
eq(invalid_module_shutdown_ok, false, "module shutdown requires an explicit boolean")
eq(registry_module.shutdown(false), true, "unused module shutdown is passive")

local runtime_upvalue
local original_runtime
for index = 1, 32 do
  local name, value = debug.getupvalue(registry_module.shutdown, index)
  if name == nil then
    break
  end
  if name == "runtime" then
    runtime_upvalue = index
    original_runtime = value
    break
  end
end
assert(runtime_upvalue, "module runtime upvalue is unavailable")
eq(original_runtime, nil, "module runtime starts empty")

local old_runtime = new_terminal_registry("old module runtime", true)
eq(
  old_runtime.registry:opencode_compatibility(),
  terminal_ready_snapshot,
  "old module runtime activates its controller"
)
debug.setupvalue(registry_module.shutdown, runtime_upvalue, old_runtime.registry)
local retained_runtime_adapter = registry_module.get("opencode")
eq(retained_runtime_adapter, old_runtime.adapter, "module returns the old runtime adapter")
eq(registry_module.shutdown(true), true, "module shutdown clears and stops the old singleton")

local fresh_runtime = new_terminal_registry("fresh module runtime", true)
debug.setupvalue(registry_module.shutdown, runtime_upvalue, fresh_runtime.registry)
local fresh_runtime_adapter = registry_module.get("opencode")
assert(
  retained_runtime_adapter ~= fresh_runtime_adapter,
  "module singleton replacement reused the old adapter"
)
eq(
  retained_runtime_adapter:health(),
  terminal_health(true),
  "old retained adapter remains terminal after singleton replacement"
)
local old_launch, old_launch_error =
  retained_runtime_adapter:new_session(identity, old_runtime.paths)
eq(old_launch, nil, "old retained adapter refuses launch after singleton replacement")
eq(
  old_launch_error,
  "managed OpenCode compatibility is not ready",
  "old retained adapter launch diagnostic after singleton replacement"
)
local old_resume, old_resume_error =
  retained_runtime_adapter:resume_session(identity, old_runtime.resume_paths, "ses_terminal123")
eq(old_resume, nil, "old retained adapter refuses resume after singleton replacement")
eq(
  old_resume_error,
  "managed OpenCode compatibility is not ready",
  "old retained adapter resume diagnostic after singleton replacement"
)
eq(old_runtime.registry:shutdown(false), true, "old registry shutdown result remains cached")
eq(old_runtime.controller_calls, {
  snapshot = 1,
  report = 0,
  ensure = 0,
  shutdown = 1,
  start = 0,
}, "old retained adapter never re-enters either controller generation")
eq(fresh_runtime.controller_calls, {
  snapshot = 0,
  report = 0,
  ensure = 0,
  shutdown = 0,
  start = 0,
}, "old retained adapter never touches the fresh controller")
assert_terminal_effects(old_runtime, "old retained adapter")
assert_terminal_effects(fresh_runtime, "fresh replacement runtime")
eq(registry_module.shutdown(false), true, "replacement singleton shuts down independently")
debug.setupvalue(registry_module.shutdown, runtime_upvalue, original_runtime)

print("AI backend adapter assertions: ok")
