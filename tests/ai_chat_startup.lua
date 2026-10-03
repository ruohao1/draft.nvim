-- Public startup, status and health use the production controller and fake ACP.
vim.o.columns, vim.o.lines = 140, 42
local root = assert(vim.uv.fs_mkdtemp("/tmp/draft-chat-startup-XXXXXX"))
local make =
  dofile(assert(vim.api.nvim_get_runtime_file("tests/fixtures/ai/chat_approval.lua", false)[1]))
local f
local function health_text()
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
    backend_health = function()
      return { installed = true, auth = "unknown", version = "", executable = "", error = "" }
    end,
  }))
  return table.concat(messages, "\n")
end
local ok, reason = xpcall(function()
  for _, case in ipairs({
    {
      name = "credentials",
      options = { auth_file = root .. "/PRIVATE_AUTH_PATH.json" },
      hint = "NvimAIStageSetup",
    },
    { name = "wrong-version", hint = "OpenCode 1.18.34" },
    { name = "missing-model", hint = "NvimAIStageSetup" },
    { name = "launch", hint = "checkhealth draft" },
    { name = "startup-cancel", hint = "Checking OpenCode compatibility" },
  }) do
    local directory = root .. "/" .. case.name
    assert(vim.uv.fs_mkdir(directory, 448))
    f = make(
      directory,
      case.options or { provider = { fixture = { options = { testCase = case.name } } } }
    )
    if case.name == "launch" then
      assert(vim.uv.fs_unlink(f.peer))
    end
    local source, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    f.compose("PRIVATE_USER_PROMPT")
    vim.cmd("NvimAIChatSend")
    f.compose("PRIVATE_UNSENT_DRAFT")
    if case.name == "startup-cancel" then
      f.rendered(case.hint)
      assert(f.snapshot().phase == "starting")
    else
      -- Delayed failures must still be available after reopening a hidden chat.
      vim.cmd("NvimAIChatHide")
      f.phase("failed")
      vim.cmd("NvimAIChat")
      f.rendered(case.hint)
    end
    local status = assert(f.runtime:conversation_status())
    assert(status.state == f.snapshot().phase and status.mode == "pre_write")
    assert(require("draft").compact() == "AI:O " .. status.state)
    assert((status.startup or status.reason):find(case.hint, 1, true))
    local before = #f.snapshot().turns
    local report = health_text()
    assert(report:find("OpenCode chat (review before write): " .. status.state, 1, true))
    assert(report:find(case.hint, 1, true))
    assert(
      not report:find("PRIVATE_", 1, true) and not vim.inspect(status):find("PRIVATE_", 1, true)
    )
    assert(#f.snapshot().turns == before, "reading status and health cannot start a turn")
    assert(f.text("draft-chat-input") == "PRIVATE_UNSENT_DRAFT")
    for _, event in ipairs(f.audit) do
      assert(
        event.method ~= "session/prompt",
        "startup refusal or cancellation cannot send a prompt"
      )
    end
    for index = 1, 3 do
      assert(f.disk(index) == "original text")
    end
    if case.name == "startup-cancel" then
      assert(vim.api.nvim_get_current_buf() == source and vim.api.nvim_get_current_win() == win)
      vim.cmd("NvimAIChatCancel")
      f.phase("failed")
      assert(f.snapshot().recovery_required and not f.snapshot().retry_safe)
    end
    vim.cmd("NvimAIChatClose")
    f.phase("closed")
    f.cleanup()
    f = nil
    print("ok - " .. case.name .. " agrees across chat, status and health without leaking content")
  end
end, debug.traceback)
if f then
  f.cleanup()
end
vim.fn.delete(root, "rf")
assert(ok, reason)
