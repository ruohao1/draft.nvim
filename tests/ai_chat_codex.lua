-- Public managed-Codex configuration and passive UI, with production controllers.
vim.o.columns, vim.o.lines = 140, 42
local root = assert(vim.uv.fs_mkdtemp("/tmp/draft-chat-codex-XXXXXX"))
local make =
  dofile(assert(vim.api.nvim_get_runtime_file("tests/fixtures/ai/chat_approval.lua", false)[1]))
local f
local tools = require("ai.tools")
local resolve, spawn, fs_open, readfile =
  tools.resolve, vim.uv.spawn, vim.uv.fs_open, vim.fn.readfile
local launches, auth_reads, forbidden = 0, 0, "opencode"
tools.resolve = function(name)
  if name == forbidden then
    return nil, "Other backend is deliberately unavailable"
  end
  return resolve(name)
end
vim.uv.spawn = function(path, options, callback)
  for _, arg in ipairs(options.args or {}) do
    if arg:match("/nvim%-ai%-conversation%.py$") then
      launches = launches + 1
    end
  end
  return spawn(path, options, callback)
end
vim.uv.fs_open = function(path, ...)
  if tostring(path):find("synthetic auth", 1, true) then
    auth_reads = auth_reads + 1
  end
  return fs_open(path, ...)
end
vim.fn.readfile = function(path, ...)
  if tostring(path):find("synthetic auth", 1, true) then
    auth_reads = auth_reads + 1
  end
  return readfile(path, ...)
end
local function directory(name)
  local path = root .. "/" .. name
  assert(vim.uv.fs_mkdir(path, 448))
  return path
end
local backends = require("ai.backends")
local native_health, native_probes = backends.health, 0
backends.health = function()
  native_probes = native_probes + 1
  return { installed = false, auth = "unknown", version = "", executable = "", error = "" }
end
local function health()
  local messages, report = {}, {}
  for _, level in ipairs({ "start", "info", "ok", "warn", "error" }) do
    report[level] = function(message)
      messages[#messages + 1] = message
    end
  end
  assert(require("draft.health").check({
    report = report,
    system = function()
      return { code = 0, signal = 0, stdout = "tmux 3.7" }
    end,
  }))
  return table.concat(messages, "\n")
end
local function requests(method)
  local count = 0
  for _, event in ipairs(f.audit) do
    if event.method == method then
      count = count + 1
    end
  end
  return count
end
local ok, reason = xpcall(function()
  f = make(directory("passive"), {}, "codex", "answer")
  assert(f.owner(), "The configured Codex backend must open without OpenCode")
  assert(f.configuration.backend == "codex" and f.configuration.model == "openai/gpt-5.4")
  assert(f.configuration.provider == nil and f.configuration.opencode == nil)
  assert(
    f.configuration.auth_file == f.auth_file,
    "Explicit chat must not inherit staged credentials"
  )
  assert(f.snapshot().backend == "codex")
  local copy = f.snapshot()
  copy.backend = "opencode"
  assert(f.snapshot().backend == "codex", "Backend identity belongs to the owner")
  for _, change in ipairs({
    { backend = "other" },
    { model = "other/model" },
    { provider = { openai = {} } },
    { opencode = f.peer },
    { auth_file = "relative/auth.json" },
  }) do
    local invalid = vim.tbl_extend("force", vim.deepcopy(f.configuration), change)
    assert(
      not require("ai.conversation_controller").new(invalid),
      "Cross-backend or incomplete options must be refused"
    )
  end
  f.rendered("Codex · review before write")
  vim.cmd("NvimAIChatHide")
  vim.cmd("NvimAIChat")
  assert(f.runtime:conversation_status().backend == "codex")
  assert(require("draft").compact() == "AI:C idle")
  assert(health():find("Codex chat (review before write): idle", 1, true))
  assert(native_probes == 0, "Managed health must not invoke native credential-reading probes")
  assert(
    launches == 0 and auth_reads == 0 and #f.audit == 0,
    "Passive UI must not read credentials or launch managed workers"
  )
  assert(not f.runtime:open(), "A managed Codex owner must retain the existing runtime lease")
  f.compose("Answer explicitly")
  vim.cmd("NvimAIChatSend")
  f.phase("idle")
  f.rendered("Bounded answer.")
  assert(requests("turn/start") == 1 and requests("session/prompt") == 0)
  assert(f.snapshot().backend == "codex")
  for index = 1, 3 do
    assert(f.disk(index) == "original text")
  end
  local old_owner, old_view = f.owner(), f.snapshot().view_revision
  local select, pending = vim.ui.select
  vim.ui.select = function(items, _, callback)
    pending = function()
      callback(items[1])
    end
  end
  vim.cmd("NvimAIChatModel")
  assert(pending)
  f.cleanup()
  f = nil
  forbidden = "codex"
  f =
    make(directory("opencode"), { provider = { fixture = { options = { testCase = "answer" } } } })
  pending()
  vim.ui.select = select
  assert(f.snapshot().backend == "opencode", "A stale model picker cannot change the new backend")
  assert(not old_owner:dispatch({ kind = "choose-model", model = "openai/gpt-5.4" }, old_view))
  f.compose("OpenCode remains independent")
  vim.cmd("NvimAIChatSend")
  f.phase("idle")
  assert(requests("session/prompt") == 1 and requests("turn/start") == 0)
  f.cleanup()
  f = nil
  forbidden = "opencode"
  print("ok - explicit backend, passive status, runtime lease and stale owner fences")

  for _, case in ipairs({
    {
      name = "credentials",
      options = { auth_file = root .. "/PRIVATE_AUTH.json" },
      hint = "chat.auth_file",
    },
    { name = "wrong-version", hint = "Codex 0.163.0" },
    { name = "missing-model", hint = "Codex" },
    { name = "unsupported", hint = "sandbox" },
  }) do
    f = make(directory(case.name), case.options or {}, "codex", case.name)
    f.compose("PRIVATE_REQUEST")
    vim.cmd("NvimAIChatSend")
    f.compose("PRIVATE_UNSENT")
    vim.cmd("NvimAIChatHide")
    f.phase("failed")
    vim.cmd("NvimAIChat")
    f.rendered(case.hint)
    assert(require("draft").compact() == "AI:C failed")
    assert(f.runtime:conversation_status().backend == "codex")
    local report = health()
    assert(report:find(case.hint, 1, true) and not report:find("PRIVATE_", 1, true))
    assert(f.text("draft-chat-input") == "PRIVATE_UNSENT")
    assert(requests("turn/start") == 0)
    f.cleanup()
    f = nil
  end
  print("ok - Codex startup refusals agree across chat, status and health")
end, debug.traceback)
if f then
  f.cleanup()
end
tools.resolve, vim.uv.spawn, vim.uv.fs_open, vim.fn.readfile = resolve, spawn, fs_open, readfile
backends.health = native_health
vim.fn.delete(root, "rf")
assert(ok, reason)
