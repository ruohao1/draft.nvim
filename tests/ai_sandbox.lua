local function eq(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    string.format("%s\nexpected: %s\nactual: %s", label, vim.inspect(expected), vim.inspect(actual))
  )
end

local function rejected(call, label, fragment)
  local ok, value, err = pcall(call)
  assert(ok, label .. " raised: " .. tostring(value))
  eq(value, nil, label .. " result")
  assert(type(err) == "string" and err ~= "", label .. " diagnostic")
  if fragment then
    assert(err:find(fragment, 1, true), label .. " diagnostic: " .. err)
  end
end

local sandbox = require("ai.sandbox")

local identity = {
  key = string.rep("a", 32),
  root = "/work/repo",
  inside_git = true,
  git_dir = "/git/worktrees/repo",
  git_common_dir = "/git",
  git_entry = "/work/repo/.git",
  owner_pane = "%12",
  tmux_socket = "/tmp/tmux-1000/default",
  namespace = "tmux:/tmp/tmux-1000/default:41:9001",
}

local capabilities = {
  approval = false,
  busy = false,
  completion = false,
  exact_session = false,
}

local direct_launch = {
  kind = "direct",
  backend = "claude",
  argv = { "/usr/bin/claude", "--session-id", "id" },
  env = {
    CLAUDE_CODE_ADDITIONAL_SETTINGS = "/state/ai/backend/additional-settings.json",
    CLAUDE_CONFIG_DIR = "/state/ai/backend",
  },
  session = "id",
  capabilities = capabilities,
  read_only_inputs = {},
  protected_paths = { "/usr/bin/claude" },
}

local managed_profile = {
  schema = 1,
  version = "1.18.30",
  profile_root = "/state/ai/backend/profiles/" .. string.rep("b", 32),
  fingerprint = string.rep("c", 64),
  config_source = "/state/ai/backend/profiles/" .. string.rep("b", 32) .. "/xdg-config",
  auth_source = "/state/ai/backend/profiles/" .. string.rep("b", 32) .. "/credentials/auth.json",
  home_mask_source = "/state/ai/backend/profiles/" .. string.rep("b", 32) .. "/empty-home-opencode",
}

local managed_environment = {
  OPENCODE_DISABLE_AUTOUPDATE = "true",
  OPENCODE_DISABLE_CLAUDE_CODE = "true",
  OPENCODE_DISABLE_EXTERNAL_SKILLS = "true",
  OPENCODE_DISABLE_LSP_DOWNLOAD = "true",
  OPENCODE_DISABLE_PROJECT_CONFIG = "true",
  OPENCODE_PERMISSION = '{"bash":"ask","doom_loop":"ask","external_directory":"ask","skill":"deny","task":"deny","webfetch":"ask","websearch":"ask"}',
  OPENCODE_PURE = "true",
  OPENCODE_SERVER_PASSWORD = string.rep("d", 32),
  OPENCODE_SERVER_USERNAME = "opencode",
  XDG_CACHE_HOME = "/state/ai/backend/xdg-cache",
  XDG_CONFIG_HOME = "/state/ai/backend/xdg-config",
  XDG_DATA_HOME = "/state/ai/backend/xdg-data",
  XDG_STATE_HOME = "/state/ai/backend/xdg-state",
}

local server_launch = {
  kind = "server_attach",
  backend = "opencode",
  server_argv = {
    "/usr/bin/opencode",
    "--pure",
    "serve",
    "--hostname",
    "127.0.0.1",
    "--port",
    "4096",
  },
  attach_argv = {
    "/usr/bin/opencode",
    "--pure",
    "attach",
    "http://127.0.0.1:4096",
    "--dir",
    "/work/repo",
    "--session",
    "ses_test",
  },
  env = managed_environment,
  session = "ses_test",
  capabilities = {
    approval = true,
    busy = true,
    completion = true,
    exact_session = true,
  },
  read_only_inputs = {},
  protected_paths = { "/state/ai/backend/profiles/" .. string.rep("b", 32), "/usr/bin/opencode" },
  managed_profile = managed_profile,
}

local function base_options(launch)
  return {
    identity = vim.deepcopy(identity),
    launch = vim.deepcopy(launch or direct_launch),
    writable = false,
    grants = {},
    token = string.rep("e", 32),
    runtime_root = "/run/ai",
    state_root = "/state/ai",
    context_dir = "/run/ai/context",
    backend_state_dir = "/state/ai/backend",
    control_socket = "/run/ai/control.sock",
    control_token = string.rep("f", 32),
    control_helper = "/config/nvim/scripts/nvim-ai-control.py",
    event_helper = "/config/nvim/scripts/nvim-ai-event.py",
    review_helper = "/config/nvim/scripts/nvim-ai-review.py",
    profile_helper = "/config/nvim/scripts/nvim-ai-opencode-profile.py",
    event_file = "/state/ai/backend/events.ndjson",
    launcher = "/config/nvim/scripts/nvim-ai-launch.py",
    python = "/usr/bin/python3",
    bwrap = "/usr/bin/bwrap",
    host_tools = { "/usr/bin/git", "/usr/bin/tmux" },
    shell = "/bin/zsh",
    resolve_trusted = function(path)
      return path
    end,
    grant_deps = {
      realpath = function(path)
        return path
      end,
      stat = function()
        return { type = "directory" }
      end,
    },
    write_manifest = function(manifest)
      return "/run/ai/launch/" .. manifest.token .. ".json"
    end,
  }
end

local prepared = assert(sandbox._test.prepare(base_options()))
eq(prepared.path, "/run/ai/launch/" .. string.rep("e", 32) .. ".json", "manifest path")
eq(prepared.argv, {
  "/usr/bin/python3",
  "-I",
  "-B",
  "/config/nvim/scripts/nvim-ai-launch.py",
  "--manifest",
  prepared.path,
}, "launcher argv")
eq(prepared.manifest.writable, false, "read-only launch")
eq(prepared.manifest.git_dir, "/git/worktrees/repo", "Git mask")
eq(prepared.manifest.tmux_socket, "/tmp/tmux-1000/default", "tmux mask")
eq(prepared.manifest.bwrap, "/usr/bin/bwrap", "canonical Bubblewrap")
eq(prepared.manifest.python, "/usr/bin/python3", "canonical Python")
eq(prepared.manifest.host_tools, { "/usr/bin/git", "/usr/bin/tmux" }, "protected host tools")
eq(
  prepared.manifest.profile_helper,
  "/config/nvim/scripts/nvim-ai-opencode-profile.py",
  "profile helper protection"
)
eq(prepared.manifest.launch.managed_profile, vim.NIL, "direct launch has no managed profile")
assert(
  prepared.command:match("^exec '[^']+' %-I %-B '[^']+' %-%-manifest '[^']+'$"),
  "fixed tmux command shape"
)

local expected_manifest_keys = {
  "backend_state_dir",
  "bwrap",
  "context_dir",
  "control_helper",
  "control_socket",
  "control_token",
  "event_file",
  "event_helper",
  "git_common_dir",
  "git_dir",
  "git_entry",
  "grants",
  "host_tools",
  "identity_key",
  "launch",
  "launcher",
  "profile_helper",
  "python",
  "review_helper",
  "review_id",
  "root",
  "runtime_root",
  "schema",
  "shell",
  "state_root",
  "tmux_socket",
  "token",
  "writable",
}
local manifest_keys = vim.tbl_keys(prepared.manifest)
table.sort(manifest_keys)
eq(manifest_keys, expected_manifest_keys, "exact manifest fields")

local expected_launch_keys = {
  "argv",
  "attach_argv",
  "backend",
  "capabilities",
  "env",
  "event_file",
  "event_url",
  "kind",
  "managed_profile",
  "protected_paths",
  "read_only_inputs",
  "server_argv",
  "session",
}
local launch_keys = vim.tbl_keys(prepared.manifest.launch)
table.sort(launch_keys)
eq(launch_keys, expected_launch_keys, "exact nested launch fields")

local seeded_codex = vim.deepcopy(direct_launch)
seeded_codex.backend = "codex"
seeded_codex.argv = { "/usr/bin/codex", "-C", identity.root }
seeded_codex.env = { CODEX_HOME = "/state/ai/backend" }
seeded_codex.session = "last"
seeded_codex.protected_paths = { "/home/user/.codex", "/usr/bin/codex" }
seeded_codex.config_seed = "/home/user/.codex/config.toml"
local seeded = assert(sandbox._test.prepare(base_options(seeded_codex)))
eq(seeded.manifest.launch.config_seed, seeded_codex.config_seed, "Codex seed source is explicit")
for _, backend in ipairs({ "claude", "opencode" }) do
  local invalid = vim.deepcopy(backend == "opencode" and server_launch or direct_launch)
  invalid.config_seed = seeded_codex.config_seed
  rejected(function()
    return sandbox._test.prepare(base_options(invalid))
  end, backend .. " refuses Codex seed", "only supported for Codex")
end
for _, path in ipairs({ "relative.toml", "/config/../config.toml", "/config/bad\n.toml" }) do
  local invalid = vim.deepcopy(seeded_codex)
  invalid.config_seed = path
  rejected(function()
    return sandbox._test.prepare(base_options(invalid))
  end, "unsafe Codex seed source", "configuration seed")
end

local writable_options = base_options()
writable_options.writable = true
writable_options.review_id = "review_0123456789abcdef"
writable_options.grants = { "/outside/two", "/outside/one" }
local writable = assert(sandbox._test.prepare(writable_options))
eq(writable.manifest.grants, { "/outside/one", "/outside/two" }, "sorted grants")
eq(writable.manifest.review_id, "review_0123456789abcdef", "writable review identity")

local managed = assert(sandbox._test.prepare(base_options(server_launch)))
eq(managed.manifest.launch.managed_profile, managed_profile, "exact public managed profile")
eq(managed.manifest.launch.argv, vim.NIL, "managed launch has no direct argv")
eq(managed.manifest.launch.server_argv, server_launch.server_argv, "server argv preserved")
eq(managed.manifest.launch.attach_argv, server_launch.attach_argv, "attach argv preserved")
eq(managed.manifest.launch.env, managed_environment, "managed environment preserved")

local empty_session_launch = vim.deepcopy(server_launch)
empty_session_launch.session = ""
empty_session_launch.attach_argv = {
  "/usr/bin/opencode",
  "--pure",
  "attach",
  "http://127.0.0.1:4096",
  "--dir",
  "/work/repo",
}
local empty_session = assert(sandbox._test.prepare(base_options(empty_session_launch)))
eq(empty_session.manifest.launch.attach_argv, empty_session_launch.attach_argv, "new-session argv")

local argv_mutations = {
  {
    label = "server trailing argument",
    mutate = function(launch)
      table.insert(launch.server_argv, "--fixture")
    end,
  },
  {
    label = "server duplicate hostname",
    mutate = function(launch)
      vim.list_extend(launch.server_argv, { "--hostname", "0.0.0.0" })
    end,
  },
  {
    label = "attach trailing argument",
    mutate = function(launch)
      table.insert(launch.attach_argv, "--help")
    end,
  },
  {
    label = "attach duplicate session",
    mutate = function(launch)
      vim.list_extend(launch.attach_argv, { "--session", launch.session })
    end,
  },
  {
    label = "attach duplicate directory",
    mutate = function(launch)
      vim.list_extend(launch.attach_argv, { "--dir", identity.root })
    end,
  },
  {
    label = "empty session with session pair",
    mutate = function(launch)
      launch.session = ""
    end,
  },
  {
    label = "missing hostname control",
    mutate = function(launch)
      launch.server_argv[4] = "hostname"
    end,
  },
  {
    label = "misordered server controls",
    mutate = function(launch)
      launch.server_argv[4], launch.server_argv[6] = launch.server_argv[6], launch.server_argv[4]
    end,
  },
  {
    label = "changed server address",
    mutate = function(launch)
      launch.server_argv[5] = "0.0.0.0"
    end,
  },
  {
    label = "missing directory control",
    mutate = function(launch)
      launch.attach_argv[5] = "dir"
    end,
  },
  {
    label = "misordered attach controls",
    mutate = function(launch)
      launch.attach_argv[5], launch.attach_argv[7] = launch.attach_argv[7], launch.attach_argv[5]
    end,
  },
  {
    label = "missing session pair",
    mutate = function(launch)
      table.remove(launch.attach_argv)
      table.remove(launch.attach_argv)
    end,
  },
  {
    label = "misordered session pair",
    mutate = function(launch)
      launch.attach_argv[7], launch.attach_argv[8] = launch.attach_argv[8], launch.attach_argv[7]
    end,
  },
  {
    label = "mismatched root",
    mutate = function(launch)
      launch.attach_argv[6] = "/work/other"
    end,
  },
  {
    label = "mismatched session",
    mutate = function(launch)
      launch.attach_argv[8] = "ses_other"
    end,
  },
  {
    label = "mismatched server port",
    mutate = function(launch)
      launch.server_argv[7] = "4097"
    end,
  },
  {
    label = "mismatched attach port",
    mutate = function(launch)
      launch.attach_argv[4] = "http://127.0.0.1:4097"
    end,
  },
}
for _, mutation in ipairs(argv_mutations) do
  local changed = vim.deepcopy(server_launch)
  mutation.mutate(changed)
  rejected(function()
    return sandbox._test.prepare(base_options(changed))
  end, mutation.label, "OpenCode")
end

for _, port_case in ipairs({
  { server = "0", attach = "0" },
  { server = "65536", attach = "65536" },
  { server = "04096", attach = "4096" },
  { server = "+4096", attach = "4096" },
  { server = " 4096", attach = "4096" },
  { server = "4096 ", attach = "4096" },
  { server = "٤٠٩٦", attach = "4096" },
}) do
  local changed = vim.deepcopy(server_launch)
  changed.server_argv[7] = port_case.server
  changed.attach_argv[4] = "http://127.0.0.1:" .. port_case.attach
  rejected(function()
    return sandbox._test.prepare(base_options(changed))
  end, "noncanonical port " .. vim.inspect(port_case.server), "OpenCode")
end

local private_profile = vim.deepcopy(server_launch)
private_profile.managed_profile.auth = "authenticated"
rejected(function()
  return sandbox._test.prepare(base_options(private_profile))
end, "helper-private profile field", "managed profile")

for _, backend in ipairs({ "codex", "claude" }) do
  local changed = vim.deepcopy(direct_launch)
  changed.backend = backend
  changed.managed_profile = vim.deepcopy(managed_profile)
  rejected(function()
    return sandbox._test.prepare(base_options(changed))
  end, backend .. " managed profile", "managed profile")
end

local missing_profile = vim.deepcopy(server_launch)
missing_profile.managed_profile = nil
rejected(function()
  return sandbox._test.prepare(base_options(missing_profile))
end, "OpenCode missing profile", "managed profile")

local profile_mutations = {
  ["older version"] = function(profile)
    profile.version = "1.18.18"
  end,
  ["previous audited version"] = function(profile)
    profile.version = "1.18.28"
  end,
  ["unaudited intervening version"] = function(profile)
    profile.version = "1.18.29"
  end,
  ["future version"] = function(profile)
    profile.version = "1.18.31"
  end,
  ["changed version"] = function(profile)
    profile.version = "1.18.19"
  end,
  ["wrong profile generation"] = function(profile)
    profile.profile_root = "/state/ai/backend/profiles/" .. string.rep("B", 32)
  end,
  ["profile outside backend state"] = function(profile)
    profile.profile_root = "/outside/profiles/" .. string.rep("b", 32)
  end,
  ["config outside profile"] = function(profile)
    profile.config_source = "/state/ai/backend/xdg-config"
  end,
  ["authentication outside profile"] = function(profile)
    profile.auth_source = "/state/ai/backend/credentials/auth.json"
  end,
  ["home mask outside profile"] = function(profile)
    profile.home_mask_source = "/state/ai/backend/empty-home-opencode"
  end,
  ["changed fingerprint"] = function(profile)
    profile.fingerprint = string.rep("C", 64)
  end,
}
for label, mutate in pairs(profile_mutations) do
  local changed = vim.deepcopy(server_launch)
  mutate(changed.managed_profile)
  rejected(function()
    return sandbox._test.prepare(base_options(changed))
  end, label, "managed profile")
end

for _, invalid in ipairs({ "", "/", "relative", "/path/../escape" }) do
  local value, err = sandbox._test.validate_grants(identity, { invalid }, {
    realpath = function(path)
      return path
    end,
    stat = function()
      return { type = "directory" }
    end,
  })
  eq(value, nil, "invalid grant " .. vim.inspect(invalid))
  assert(type(err) == "string" and err ~= "", "invalid grant detail")
end

local grants = assert(sandbox._test.validate_grants(identity, { "/z", "/a" }, {
  realpath = function(path)
    return path
  end,
  stat = function()
    return { type = "directory" }
  end,
}))
eq(grants, { "/a", "/z" }, "grant validation sorts canonically")

rejected(function()
  return sandbox._test.validate_grants(identity, { "/a", "/a" }, {
    realpath = function(path)
      return path
    end,
    stat = function()
      return { type = "directory" }
    end,
  })
end, "duplicate grant", "duplicate")

local unresolved = base_options()
unresolved.resolve_trusted = function(path)
  if path == unresolved.profile_helper then
    return nil, "changed"
  end
  return path
end
rejected(function()
  return sandbox._test.prepare(unresolved)
end, "profile helper resolution", "profile helper")

local publication = base_options()
publication.write_manifest = function()
  return nil, "state publication refused"
end
rejected(function()
  return sandbox._test.prepare(publication)
end, "manifest publication", "state publication refused")

local unsafe_command = base_options()
unsafe_command.launcher = "/config/nvim/scripts/bad\nlauncher.py"
rejected(function()
  return sandbox._test.prepare(unsafe_command)
end, "command control", "control")

print("AI sandbox manifest assertions: ok")
