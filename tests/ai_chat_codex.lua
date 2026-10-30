-- Public managed-Codex configuration and passive UI, with production controllers.
vim.o.columns, vim.o.lines = 140, 42
local root = assert(vim.uv.fs_mkdtemp("/tmp/draft-chat-codex-XXXXXX"))
local make =
  dofile(assert(vim.api.nvim_get_runtime_file("tests/fixtures/ai/chat_approval.lua", false)[1]))
local f
local original_select = vim.ui.select
local tools = require("ai.tools")
local resolve, spawn, fs_open, readfile =
  tools.resolve, vim.uv.spawn, vim.uv.fs_open, vim.fn.readfile
local launches, auth_reads, forbidden = 0, 0, "opencode"
local locks = {}
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
local function owned_directory(name)
  local path = directory(name)
  local fixture = assert(vim.api.nvim_get_runtime_file("tests/fixtures/ai/codex_auth.py", false)[1])
  local result = vim.system({ "/usr/bin/python3", "-I", "-B", fixture, path }):wait()
  assert(result.code == 0, result.stderr)
  return path
end
local function take_lock(path)
  local ready = false
  local fd = assert(vim.uv.fs_open(path .. "/.draft.lock", "a", 384))
  vim.uv.fs_close(fd)
  local process = vim.system({
    "flock",
    "-n",
    path .. "/.draft.lock",
    "/usr/bin/python3",
    "-c",
    "print('ready', flush=True); input()",
  }, {
    stdin = true,
    stdout = function(_, data)
      ready = ready or (data ~= nil and data:find("ready", 1, true) ~= nil)
    end,
  })
  locks[#locks + 1] = process
  assert(
    vim.wait(3000, function()
      return ready
    end, 10),
    "Contender did not acquire the lease"
  )
  return function()
    process:write("release\n")
    assert(process:wait(3000).code == 0)
  end
end
local ok, reason = xpcall(function()
  local passive_store = root .. "/PRIVATE_MISSING_STORE"
  f = make(directory("owned-passive"), { auth_store = passive_store }, "codex", "answer")
  assert(f.owner(), "Dedicated credentials must be accepted without reading them")
  assert(f.configuration.auth_file == nil and f.configuration.auth_store == passive_store)
  for _, change in ipairs({
    { auth_file = "/unused" },
    { auth_store = "relative" },
    { auth_store = "/tmp/../private" },
    { auth_store = "/tmp/" },
    { auth_store = "/" },
    { auth_store = false },
  }) do
    assert(
      not require("ai.conversation_controller").new(
        vim.tbl_extend("force", f.configuration, change)
      )
    )
  end
  vim.cmd("NvimAIChatHide")
  vim.cmd("NvimAIChat")
  health()
  assert(launches == 0 and auth_reads == 0 and #f.audit == 0)
  f.cleanup()
  f = nil
  assert(not vim.uv.fs_stat(passive_store), "Passive Close created credential state")
  launches, auth_reads = 0, 0

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
  assert(not require("ai.conversation_controller").new(vim.tbl_extend("force", f.configuration, {
    auth_store = root .. "/private-codex-only",
  })))
  assert(not old_owner:dispatch({ kind = "choose-model", model = "openai/gpt-5.4" }, old_view))
  f.compose("OpenCode remains independent")
  vim.cmd("NvimAIChatSend")
  f.phase("idle")
  assert(requests("session/prompt") == 1 and requests("turn/start") == 0)
  f.cleanup()
  f = nil
  forbidden = "opencode"
  print("ok - explicit backend, passive status, runtime lease and stale owner fences")

  local owned = owned_directory("dedicated-login")
  local release = take_lock(owned)
  f = make(directory("owned-busy"), { auth_store = owned }, "codex", "answer")
  f.compose("First explicit request")
  vim.cmd("NvimAIChatSend")
  f.phase("failed")
  f.rendered("already in use")
  assert(f.snapshot().retry_safe and not f.snapshot().recovery_required)
  assert(requests("turn/start") == 0)
  release()
  vim.cmd("NvimAIChatRetry")
  f.phase("idle")
  assert(requests("turn/start") == 1 and requests("thread/start") == 1)
  release = take_lock(owned)
  f.compose("Blocked continuation")
  vim.cmd("NvimAIChatSend")
  f.compose("PRIVATE_UNSENT")
  vim.cmd("NvimAIChatHide")
  f.phase("failed")
  vim.cmd("NvimAIChat")
  assert(f.snapshot().retry_safe and not f.snapshot().recovery_required)
  assert(f.text("draft-chat-input") == "PRIVATE_UNSENT")
  assert(requests("turn/start") == 1 and requests("thread/resume") == 0)
  assert(not health():find("PRIVATE_", 1, true))
  release()
  vim.cmd("NvimAIChatRetry")
  f.phase("idle")
  assert(requests("turn/start") == 2 and requests("thread/resume") == 1)
  f.cleanup()
  f = nil
  assert(vim.uv.fs_stat(owned .. "/auth.json"))

  f = make(directory("owned-busy-review"), { auth_store = owned }, "codex", "edit")
  f.compose("Create a proposal")
  vim.cmd("NvimAIChatSend")
  f.phase("review")
  local prior = vim.deepcopy(f.snapshot().review)
  release = take_lock(owned)
  f.compose("Blocked revision")
  vim.cmd("NvimAIChatSend")
  f.compose("PRIVATE_REVIEW_DRAFT")
  assert(
    vim.wait(12000, function()
      local state = f.snapshot()
      return state.phase == "review"
        and state.reason
        and state.reason:find("already in use", 1, true)
    end, 10),
    vim.inspect(f.snapshot())
  )
  assert(f.snapshot().review.token == prior.token and not f.snapshot().recovery_required)
  assert(f.text("draft-chat-input") == "PRIVATE_REVIEW_DRAFT")
  assert(requests("turn/start") == 1 and requests("thread/resume") == 0)
  release()
  vim.cmd("NvimAIChatSend")
  assert(
    vim.wait(12000, function()
      return f.snapshot().phase == "review" and f.snapshot().review.token ~= prior.token
    end, 10),
    vim.inspect(f.snapshot())
  )
  assert(requests("turn/start") == 2 and requests("thread/resume") == 1)
  f.cleanup()
  f = nil
  print("ok - owned login contention preserves draft, thread and prior review")

  local old_bwrap = root .. "/old-bwrap"
  vim.fn.writefile({ "#!/bin/sh", "printf '%s\\n' '--sync-fd FD'" }, old_bwrap)
  assert(vim.uv.fs_chmod(old_bwrap, 448))
  for _, case in ipairs({
    {
      name = "auth-support",
      options = { auth_store = root .. "/PRIVATE_UNREAD_STORE", bwrap = old_bwrap },
      hint = "Bubblewrap",
    },
    {
      name = "auth-migrate",
      options = { auth_file = owned .. "/auth.json" },
      hint = "chat.auth_store",
    },
    {
      name = "credentials",
      options = { auth_file = root .. "/PRIVATE_AUTH.json" },
      hint = "chat.auth_file",
    },
    { name = "wrong-version", hint = "Codex 0.163.0" },
    { name = "missing-host", hint = "codex-code-mode-host" },
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
  local dialogs = {}
  vim.ui.select = function(items, _, callback)
    dialogs[#dialogs + 1] = { items = items, callback = callback }
  end
  local function review(index)
    vim.cmd("NvimAIChatReview")
    local dialog = dialogs[#dialogs]
    dialog.callback(dialog.items[index or 1])
  end
  local function bytes(index)
    return table.concat(vim.fn.readfile(f.files[index], "b"), "\n")
  end
  local function held()
    assert(vim.wait(12000, function()
      return #f.waiters > 0 or f.snapshot().phase == "failed"
    end, 10))
    assert(#f.waiters > 0, vim.inspect(f.snapshot()))
  end
  f = make(directory("review"), {}, "codex", "edit-held")
  f.compose("Propose edits to all selected files.")
  vim.cmd("NvimAIChatSend")
  held()
  f.phase("generating")
  assert(f.snapshot().review == nil)
  assert(not f.runtime:chat_approve(), "Acknowledgement cannot authorize review")
  for index = 1, 3 do
    assert(bytes(index) == "original text\n")
  end
  f.release()
  f.phase("review")
  for index = 1, 3 do
    assert(bytes(index) == "original text\n", "A frozen proposal is not publication")
  end
  review()
  vim.cmd("NvimAIChatApprove")
  f.phase("review")
  assert(bytes(1) == "proposed text\n" and bytes(2) == "original text\n")
  review(2)
  vim.cmd("NvimAIChatReject")
  f.phase("review")
  assert(bytes(2) == "original text\n")
  review(3)
  local original, old_approve = f.snapshot().review, f.key("a")
  assert(original.files[1].state == "accepted" and original.files[2].state == "rejected")
  assert(original.receipt_sequence == 2)
  vim.cmd("NvimAIChatRejectAll")
  local stale_dialog = dialogs[#dialogs]
  local sent = requests("turn/start")
  vim.cmd("NvimAIChatEditProposal")
  f.phase("editing")
  local draft = vim.api.nvim_get_current_buf()
  local lines = { "manual correction 二", "second line", "" }
  local corrected_bytes = table.concat(lines, "\n") .. "\n"
  vim.api.nvim_buf_set_lines(draft, 0, -1, false, lines)
  for _, format in ipairs({ "crlf", "no-final-newline" }) do
    local proposed = format == "crlf" and lines or { "manual correction 二", "second line" }
    vim.api.nvim_buf_set_lines(draft, 0, -1, false, proposed)
    vim.bo[draft].fileformat = format == "crlf" and "dos" or "unix"
    vim.bo[draft].endofline = format ~= "no-final-newline"
    assert(not f.runtime:chat_freeze_proposal(), "Unsupported byte formats must be refused")
    assert(f.snapshot().phase == "editing" and f.snapshot().review.token == original.token)
    assert(vim.deep_equal(vim.api.nvim_buf_get_lines(draft, 0, -1, false), proposed))
    assert(vim.bo[draft].fileformat == (format == "crlf" and "dos" or "unix"))
    assert(vim.bo[draft].endofline == (format ~= "no-final-newline"))
    assert(bytes(3) == "original text\n" and requests("turn/start") == sent)
  end
  vim.api.nvim_buf_set_lines(draft, 0, -1, false, lines)
  vim.bo[draft].fileformat, vim.bo[draft].endofline = "unix", true
  vim.cmd("NvimAIChatHide")
  vim.cmd("NvimAIChatEditProposal")
  assert(vim.api.nvim_get_current_buf() == draft)
  vim.cmd("NvimAIChatFreezeProposal")
  f.phase("review")
  local corrected = f.snapshot().review
  assert(corrected.token ~= original.token and corrected.revision == 2)
  assert(corrected.receipt_sequence == 0, "A replacement has a fresh writer journal")
  assert(corrected.history[1].receipt_sequence == original.receipt_sequence)
  assert(
    vim.deep_equal(corrected.history[1].files, original.files),
    "Prior receipts must remain exact"
  )
  assert(corrected.files[1].state == "accepted" and corrected.files[2].state == "rejected")
  old_approve()
  stale_dialog.callback(stale_dialog.items[2])
  assert(f.snapshot().review.receipt_sequence == corrected.receipt_sequence)
  assert(not f.runtime:chat_approve_all(), "The corrected revision needs fresh visits")
  assert(requests("turn/start") == sent and #f.snapshot().turns == 1)
  assert(bytes(3) == "original text\n", "Edit and Freeze cannot publish")
  vim.cmd("NvimAIChat")
  f.compose("Preserve manual correction.")
  vim.cmd("NvimAIChatSend")
  held()
  f.release()
  f.phase("review")
  assert(requests("turn/start") == sent + 1 and requests("thread/resume") == 1)
  assert(requests("thread/start") == 1)
  local request, workspace, thread
  for _, event in ipairs(f.audit) do
    if event.method == "turn/start" then
      if thread then
        assert(event.params.threadId == thread, "The exact stopped thread must resume")
      end
      thread, request = event.params.threadId, event.params.input[1].text
    elseif event.workspace then
      workspace = event.workspace
    end
  end
  assert(request:find("editor-made corrections", 1, true))
  local decisions =
    vim.json.decode(request:match("Editor%-confirmed file decisions[^\n]*\n([^\n]+)"))
  assert(decisions[1].state == "accepted" and decisions[2].state == "rejected")
  assert(decisions[3].state == "pending")
  assert(
    vim.deep_equal(workspace, { ["third.txt"] = corrected_bytes }),
    "Decided files must not regain edit authority"
  )
  assert(f.snapshot().review.receipt_sequence == corrected.receipt_sequence)
  review(3)
  vim.cmd("NvimAIChatApprove")
  f.phase("idle")
  assert(bytes(1) == "proposed text\n" and bytes(2) == "original text\n")
  assert(bytes(3) == corrected_bytes, "Approval must preserve the frozen correction bytes")
  f.cleanup()
  f = nil
  print("ok - Codex terminal, partial decisions, local correction and exact-thread resume")

  f = make(directory("cancel-resume"), {}, "codex", "cancel")
  local controllers = launches
  f.compose("Stream an answer until I cancel.")
  vim.cmd("NvimAIChatSend")
  f.phase("generating")
  f.rendered("Partial answer before cancellation.")
  f.key("gc")()
  f.phase("idle")
  assert(f.snapshot().turns[1].status == "cancelled")
  assert(not f.snapshot().recovery_required and f.snapshot().review == nil)
  assert(#f.snapshot().rounds == 0 and requests("turn/interrupt") == 1)
  for index = 1, 3 do
    assert(bytes(index) == "original text\n", "Cancellation cannot publish source changes")
  end
  local peer = table.concat(vim.fn.readfile(f.peer, "b"), "\n")
  local resumed, replacements = peer:gsub('CASE = "cancel"', 'CASE = "answer"')
  assert(replacements == 1)
  vim.fn.writefile(vim.split(resumed, "\n", { plain = true }), f.peer, "b")
  f.compose("Continue with a new explicit request.")
  vim.cmd("NvimAIChatSend")
  f.phase("idle")
  assert(f.snapshot().turn_id == 2 and f.snapshot().worker_generation == 2)
  assert(f.snapshot().turns[1].status == "cancelled")
  assert(f.snapshot().turns[2].status == "completed")
  assert(f.snapshot().turns[2].text == "Bounded answer.")
  assert(not f.snapshot().recovery_required and #f.snapshot().rounds == 0)
  assert(launches == controllers + 1 and requests("turn/start") == 2)
  assert(requests("thread/start") == 1 and requests("thread/resume") == 1)
  local cancelled_thread
  for _, event in ipairs(f.audit) do
    if event.method == "turn/interrupt" then
      cancelled_thread = event.params.threadId
    elseif event.method == "thread/resume" then
      assert(cancelled_thread and event.params.threadId == cancelled_thread)
    end
  end
  for index = 1, 3 do
    assert(bytes(index) == "original text\n")
  end
  f.cleanup()
  assert(f.snapshot().phase == "closed")
  f = nil
  print("ok - Codex cancellation reaches the editor and resumes the same thread")

  f = make(directory("source-drift"), {}, "codex", "edit")
  f.compose("Propose edits.")
  vim.cmd("NvimAIChatSend")
  f.phase("review")
  review()
  vim.fn.writefile({ "external change" }, f.files[1])
  vim.cmd("NvimAIChatApprove")
  f.phase("failed")
  assert(bytes(1) == "external change\n")
  assert(bytes(2) == "original text\n" and bytes(3) == "original text\n")
  assert(f.snapshot().recovery_required and not f.snapshot().retry_safe)
  for _, file in ipairs(f.snapshot().rounds[1].files) do
    assert(file.state == "blocked", "Source drift cannot produce acceptance")
  end
  f.cleanup()
  f = nil
  vim.ui.select = original_select
  print("ok - Codex review refuses source drift without publication")
end, debug.traceback)
if f then
  f.cleanup()
end
for _, process in ipairs(locks) do
  process:kill(9)
  process:wait(3000)
end
tools.resolve, vim.uv.spawn, vim.uv.fs_open, vim.fn.readfile = resolve, spawn, fs_open, readfile
backends.health, vim.ui.select = native_health, original_select
vim.fn.delete(root, "rf")
assert(ok, reason)
