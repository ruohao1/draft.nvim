-- Real runtime dependencies and Python profile helper, without a provider.
-- Only the already-validated CLI report is simulated. HOME/config/data and all
-- credentials are disposable; no installed config or real auth file is read.
local uv = vim.uv
local original_runtime = vim.o.runtimepath
local original_cwd = vim.fn.getcwd()
local environment = { "HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "PATH" }
local original_environment = {}
for _, key in ipairs(environment) do
  original_environment[key] = vim.env[key]
end
local base = assert(uv.fs_mkdtemp("/tmp/ai-opencode-runtime-XXXXXX"))
local function directory(path)
  vim.fn.mkdir(path, "p", 448)
  assert(uv.fs_chmod(path, 448))
  return path
end
local function write(path, lines, mode)
  vim.fn.writefile(lines, path)
  assert(uv.fs_chmod(path, mode or 384))
end
local function copy(source, destination)
  assert(uv.fs_copyfile(source, destination))
  assert(uv.fs_chmod(destination, 420))
end
local source = assert(vim.api.nvim_get_runtime_file("lua/ai/backends/init.lua", false)[1])
local helper =
  assert(vim.api.nvim_get_runtime_file("scripts/nvim-ai-opencode-profile.py", false)[1])
local managed = require("ai.backends.opencode_managed")
local validation = require("ai.backends.opencode_validation")
local original_validation_new = validation.new
local registries = {}

local ok, err = xpcall(function()
  vim.env.HOME = directory(base .. "/home")
  vim.env.XDG_CONFIG_HOME = directory(base .. "/config")
  vim.env.XDG_DATA_HOME = directory(base .. "/data")
  vim.env.XDG_STATE_HOME = directory(base .. "/state")
  local bin = directory(base .. "/bin")
  local opencode = bin .. "/opencode"
  write(opencode, { "#!/bin/sh", "exit 97" }, 448)
  vim.env.PATH = bin .. ":/usr/bin:/bin"
  directory(vim.env.XDG_DATA_HOME .. "/opencode")
  local credential = vim.env.XDG_DATA_HOME .. "/opencode/auth.json"
  write(credential, { '{"openai":{"type":"api","key":"DUMMY_RUNTIME_PATH_TEST"}}' })

  validation.new = function()
    return {
      snapshot = function()
        return {
          state = "ready",
          installed = true,
          executable = opencode,
          version = managed.version(),
          category = "",
          queued = false,
        }
      end,
      report = function()
        return managed._test.compatibility_fixture()
      end,
      shutdown = function()
        return true
      end,
    }
  end
  local function registry(module)
    registries[#registries + 1] = module
    return module
  end
  local function available(module, label)
    local health = module.health("opencode")
    assert(module.is_available(health), label .. ": " .. vim.inspect(health))
  end
  local native = registry(require("ai.backends"))
  local installed_helper = vim.fn.stdpath("config") .. "/scripts/nvim-ai-opencode-profile.py"
  assert(not uv.fs_stat(installed_helper), "the installed config has no profile helper")
  available(native, "worktree health must use the helper beside its loaded module")

  -- A different installed config and a later runtimepath entry must not redirect
  -- an already-loaded module to an unrelated helper, even one with safe modes.
  directory(vim.fs.dirname(installed_helper))
  write(installed_helper, { 'raise SystemExit("wrong installed helper")' }, 420)
  local decoy = directory(base .. "/decoy-runtime")
  directory(decoy .. "/scripts")
  write(
    decoy .. "/scripts/nvim-ai-opencode-profile.py",
    { 'raise SystemExit("wrong runtime helper")' },
    420
  )
  vim.opt.runtimepath:prepend(decoy)
  available(native, "loaded worktree wins over installed config and runtimepath decoys")

  local identity = { key = string.rep("a", 32), root = directory(base .. "/project") }
  local paths = {
    backend_state = directory(base .. "/backend"),
    python = assert(require("ai.tools").resolve("python3")),
    profile_helper = assert(uv.fs_realpath(helper)),
    home_agents = vim.env.HOME .. "/AGENTS.md",
    global_opencode_data = vim.env.XDG_DATA_HOME .. "/opencode",
    grants = {},
  }
  local adapter = native.get("opencode")
  local launch, launch_error = adapter:new_session(identity, paths)
  assert(
    launch,
    "native profile creation must use the same worktree helper: " .. tostring(launch_error)
  )
  assert(launch.backend == "opencode" and launch.kind == "server_attach")
  local reference = assert(adapter:profile_reference(launch))
  assert(
    adapter:validate_profile(reference, identity, paths),
    "profile inspection uses the same helper"
  )
  assert(
    launch.server_argv[1] == opencode,
    "only the non-provider fixture executable can be selected"
  )
  assert(
    vim.fn.readfile(credential)[1]:find("DUMMY_RUNTIME_PATH_TEST", 1, true),
    "source auth remains unchanged"
  )

  -- Mutate only a disposable copy, never the actual worktree helper.
  local relocated = directory(base .. "/relocated")
  directory(relocated .. "/lua/ai/backends")
  directory(relocated .. "/scripts")
  local relocated_source = relocated .. "/lua/ai/backends/init.lua"
  local relocated_helper = relocated .. "/scripts/nvim-ai-opencode-profile.py"
  copy(source, relocated_source)
  copy(helper, relocated_helper)
  vim.api.nvim_set_current_dir(base)
  local moved = registry(assert(loadfile("relocated/lua/ai/backends/init.lua"))())
  vim.api.nvim_set_current_dir(original_cwd)
  available(moved, "a relatively loaded module keeps its sibling helper after cwd changes")
  -- Both alternatives are now valid, so a refusal proves we did not fall back.
  copy(helper, installed_helper)
  copy(helper, decoy .. "/scripts/nvim-ai-opencode-profile.py")
  assert(not adapter:new_session(
    identity,
    vim.tbl_extend("force", paths, {
      profile_helper = installed_helper,
    })
  ), "a caller cannot substitute a different config's helper")
  assert(uv.fs_chmod(relocated_helper, 436)) -- 0664: group-writable.
  assert(not moved.is_available(moved.health("opencode")), "unsafe helper remains refused")
  assert(uv.fs_chmod(relocated_helper, 420))
  available(moved, "restoring safe helper metadata restores eligibility")
  assert(uv.fs_unlink(relocated_helper))
  assert(
    not moved.is_available(moved.health("opencode")),
    "missing sibling never falls back to another config"
  )
end, debug.traceback)

for _, module in ipairs(registries) do
  module.shutdown(true)
end
validation.new = original_validation_new
vim.o.runtimepath = original_runtime
vim.api.nvim_set_current_dir(original_cwd)
for _, key in ipairs(environment) do
  vim.env[key] = original_environment[key]
end
vim.fn.delete(base, "rf")
assert(ok, err)
print("AI OpenCode worktree helper assertions: ok")
