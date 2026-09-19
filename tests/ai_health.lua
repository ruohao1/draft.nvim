-- Health is a read-only reporting interface, including unsupported hosts.
local reports = {}
local report = {}
for _, level in ipairs({ "start", "ok", "info", "warn", "error" }) do
  report[level] = function(message)
    reports[#reports + 1] = { level = level, message = message }
  end
end
local health = require("draft.health")
assert(health.check({
  platform = function()
    return "Darwin"
  end,
  report = report,
  system = function()
    error("unsupported platform must not execute a child")
  end,
}))
assert(
  vim.inspect(reports):find("launch disabled", 1, true),
  "macOS clearly reports launch disabled"
)
assert(package.loaded["ai.session"] == nil, "health never constructs a session")

local uv = vim.uv
local base = assert(uv.fs_mkdtemp("/tmp/ai-health-XXXXXX"))
local old_cwd, old_run, old_state = vim.fn.getcwd(), vim.env.XDG_RUNTIME_DIR, vim.env.XDG_STATE_HOME
vim.fn.mkdir(base .. "/run", "p", 448)
vim.fn.mkdir(base .. "/state", "p", 448)
vim.api.nvim_set_current_dir(base)
vim.env.XDG_RUNTIME_DIR, vim.env.XDG_STATE_HOME = base .. "/run", base .. "/state"
local calls = {}
local ok, failure = xpcall(function()
  assert(health.check({
    report = report,
    backend_health = function(name)
      return {
        installed = true,
        executable = "/usr/bin/" .. name,
        version = "1.0\n\27" .. string.rep("界", 900),
        auth = "unknown",
        capabilities = { busy = true, exact_session = false },
        error = "",
        token = "PRIVATE_TOKEN",
        password = "PRIVATE_PASSWORD",
      }
    end,
    system = function(argv, milliseconds)
      calls[#calls + 1] = argv
      assert(milliseconds <= 2000, "health child is bounded")
      return { code = 0, signal = 0, stdout = "tmux 3.7\n", stderr = "" }
    end,
  }))
  local self_check
  for _, argv in ipairs(calls) do
    if argv[2] == "--new-session" then
      self_check = argv
    end
  end
  assert(self_check, "health performs the read-only Bubblewrap self-check")
  assert(
    vim.deep_equal(self_check, {
      "/usr/bin/bwrap",
      "--new-session",
      "--unshare-pid",
      "--unshare-ipc",
      "--unshare-uts",
      "--die-with-parent",
      "--ro-bind",
      "/",
      "/",
      "--dev",
      "/dev",
      "--proc",
      "/proc",
      "--",
      "/bin/true",
    }),
    "self-check cannot request writable binds"
  )
  assert(not uv.fs_lstat(base .. "/run/draft.nvim"), "health does not create runtime state")
  assert(not uv.fs_lstat(base .. "/state/draft.nvim"), "health does not create durable state")
  for _, item in ipairs(reports) do
    assert(
      #item.message <= 1024 and not item.message:find("[%z\1-\31\127]"),
      "health output is bounded and control-free"
    )
    assert(not item.message:find("\194[\128-\159]"), "health output strips C1 controls")
  end
  assert(
    not vim.inspect(reports):find("PRIVATE_", 1, true),
    "health reports no arbitrary authentication fields"
  )
  assert(package.loaded["ai.session"] == nil, "Linux health never constructs a session")
end, debug.traceback)
vim.api.nvim_set_current_dir(old_cwd)
vim.env.XDG_RUNTIME_DIR, vim.env.XDG_STATE_HOME = old_run, old_state
vim.fn.delete(base, "rf")
assert(ok, failure)
print("AI health assertions: ok")
