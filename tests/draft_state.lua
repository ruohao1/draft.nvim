-- Old state may exist, but must not grant Draft a session or preferences.
local uv = vim.uv
local function directory(path)
  vim.fn.mkdir(path, "p", 448)
  assert(uv.fs_chmod(path, 448))
  return path
end
local key = string.rep("a", 32)
local legacy = directory(vim.env.XDG_STATE_HOME .. "/dotfiles/nvim-ai/" .. key)
vim.fn.writefile({ "legacy record must remain untouched" }, legacy .. "/record.json")
local store = assert(require("ai.state").open({
  key = key,
  root = vim.env.HOME,
  namespace = "standalone:draft-test",
}))
assert(store:state_dir() == vim.env.XDG_STATE_HOME .. "/draft.nvim/" .. key)
assert(store:runtime_dir() == vim.env.XDG_RUNTIME_DIR .. "/draft.nvim/" .. key)
assert(store:read_record() == nil, "legacy session must not be adopted")
assert(vim.fn.readfile(legacy .. "/record.json")[1] == "legacy record must remain untouched")
assert(uv.fs_stat(store:state_dir()).mode % 512 == 448, "state must remain private")
assert(uv.fs_stat(store:runtime_dir()).mode % 512 == 448, "runtime must remain private")

local settings = require("ai.staged_settings")
local old_settings = { settings_directory = vim.fn.stdpath("state") .. "/nvim-ai/staged" }
assert(settings.save(old_settings, { enabled = true, model = "fixture/model" }))
assert(assert(settings.load()).enabled == false, "legacy opt-in must not enable Draft")
assert(settings.save({}, { enabled = false }))
assert(vim.fn.filereadable(vim.fn.stdpath("state") .. "/draft.nvim/staged/settings.json") == 1)
assert(assert(settings.load(old_settings)).enabled == true, "legacy preferences must be untouched")

local cache_module = require("ai.backends.opencode_cache")
local report = require("ai.backends.opencode_managed")._test.compatibility_fixture()
local identity =
  { installed = true, executable = uv.fs_realpath("/usr/bin/true"), metadata = "fixture" }
local old_cache =
  cache_module.new({ directory = vim.fn.stdpath("cache") .. "/nvim-ai/opencode-compat" })
local _, old_ticket = old_cache:lookup(identity)
assert(old_cache:publish(old_ticket, identity, report))
local cache = cache_module.new()
local hit, ticket = cache:lookup(identity)
assert(hit == nil and ticket, "legacy compatibility receipt must not be adopted")
assert(cache:publish(ticket, identity, report))
assert(cache:lookup(identity), "Draft must reuse its own private receipt")
assert(
  #vim.fn.glob(vim.fn.stdpath("cache") .. "/draft.nvim/opencode-compat/*.json", false, true) == 1
)
print("Draft state: private native state, preferences and cache are isolated")
