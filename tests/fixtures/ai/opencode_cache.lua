-- A fresh editor per invocation; only compatibility command results are faked.
local validation = require("ai.backends.opencode_validation")
local managed = require("ai.backends.opencode_managed")
local available, cache_module = pcall(require, "ai.backends.opencode_cache")
local cache = available and cache_module.new({ directory = vim.env.CACHE_TEST_DIRECTORY }) or nil
local started = 0
local begin = vim.uv.hrtime()
local controller
if vim.env.CACHE_TEST_PLATFORM_CHANGE == "1" then
  local uname = vim.uv.os_uname
  vim.uv.os_uname = function()
    local value = uname()
    value.release = value.release .. "-cache-fixture"
    return value
  end
end
local function change_loaded_policy()
  local path = vim.api.nvim_get_runtime_file("lua/ai/backends/opencode_managed.lua", false)[1]
  assert(path:match("^/tmp/nvim%-ai%-cache%-test%-"), "source drift fixture must stay private")
  vim.fn.writefile({ "-- source drift regression" }, path, "a")
end
if vim.env.CACHE_TEST_RUNTIME == "1" then
  local backend = require("ai.backends")
  local executable = assert(require("ai.tools").resolve("opencode"))
  local system = vim.system
  vim.system = function(argv, ...)
    if vim.tbl_contains(argv, executable) then
      started = started + 1
    end
    return system(argv, ...)
  end
  controller = {
    snapshot = function()
      return backend.opencode_compatibility()
    end,
    ensure = function(_, request)
      return backend.ensure_opencode_compatibility(request)
    end,
    shutdown = function(_, committed)
      return backend.shutdown(committed)
    end,
  }
elseif vim.env.CACHE_TEST_REAL == "1" then
  controller = require("ai.backends")._test.new_opencode_validation({
    cache = cache,
    observe_probe = function()
      started = started + 1
    end,
    notify = function() end,
  })
else
  local report = managed._test.compatibility_fixture()
  local function result(command)
    local name = command.name
    local value = { code = 0, signal = 0, stdout = "", stderr = "" }
    if name == "version" then
      value.stdout = managed.version() .. "\n"
    elseif name == "root_help" then
      value.stderr = "--pure serve attach"
    elseif name == "serve_help" then
      value.stderr = "--hostname --port"
    elseif name == "attach_help" then
      value.stderr = "--dir --session OPENCODE_SERVER_PASSWORD"
    elseif name == "names" then
      for _, agent in ipairs(report.names) do
        local mode = (agent == "build" or agent == "plan") and "primary" or "subagent"
        value.stdout = value.stdout .. agent .. " (" .. mode .. ")\n[]\n"
      end
    elseif name == "general" or name == "explore" then
      value.code = 1
      value.stderr = "Agent "
        .. name
        .. " not found, run 'opencode agent list' to get an agent list\n"
    else
      local agent = vim.deepcopy(report.agents[name])
      if name == "build" or name == "plan" then
        agent.tools = {
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
      end
      value.stdout = vim.json.encode(agent)
    end
    if vim.env.CACHE_TEST_FAIL == "1" then
      value.code = 126
    end
    return value
  end
  controller = validation.new({
    cache = cache,
    identify = function()
      local s = assert(vim.uv.fs_lstat(vim.env.CACHE_TEST_EXECUTABLE))
      return {
        installed = true,
        executable = vim.env.CACHE_TEST_EXECUTABLE,
        metadata = vim.json.encode({
          s.dev,
          s.ino,
          s.mode,
          s.uid,
          s.size,
          s.mtime.sec,
          s.mtime.nsec,
          s.ctime.sec,
          s.ctime.nsec,
        }),
      }
    end,
    start_probe = function(_, command, complete)
      started = started + 1
      if started == 1 and vim.env.CACHE_TEST_DRIFT == "audit" then
        change_loaded_policy()
      end
      vim.schedule(function()
        complete(result(command), "")
      end)
      return {
        cancel = function() end,
        shutdown_drain = function()
          return true
        end,
      }
    end,
    now = vim.uv.now,
    defer = vim.defer_fn,
    schedule = vim.schedule,
    notify = function() end,
  })
end
if vim.env.CACHE_TEST_DRIFT == "lookup" then
  change_loaded_policy()
end
assert(
  controller:snapshot().state == "not_checked",
  "passive snapshot must not load/create a cache"
)
if controller.report then
  assert(controller:report() == nil, "passive report must not load a cache")
end
if vim.env.CACHE_TEST_PASSIVE == "1" then
  assert(controller:shutdown(true))
  io.stdout:write(vim.json.encode({ phase = "not_checked", starts = started }) .. "\n")
  return
end
assert(controller:ensure({ reason = "open", identity_key = string.rep("a", 32) }))
assert(
  vim.wait(20000, function()
    local phase = controller:snapshot().state
    return phase == "ready" or phase == "failed"
  end, 5),
  "validation timed out"
)
local phase = controller:snapshot().state
local elapsed = (vim.uv.hrtime() - begin) / 1e6
assert(controller:shutdown(true), "cleanup must be proved")
io.stdout:write(vim.json.encode({ phase = phase, starts = started, duration_ms = elapsed }) .. "\n")
