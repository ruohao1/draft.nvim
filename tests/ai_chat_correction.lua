-- Public manual corrections over the real owner, controller and guarded publisher.
vim.o.columns, vim.o.lines = 140, 42
local root = assert(vim.uv.fs_mkdtemp("/tmp/draft-chat-correction-XXXXXX"))
local make =
  dofile(assert(vim.api.nvim_get_runtime_file("tests/fixtures/ai/chat_approval.lua", false)[1]))
local controller =
  assert(vim.api.nvim_get_runtime_file("scripts/nvim-ai-conversation.py", false)[1])
local spawn, pid = vim.uv.spawn, nil
vim.uv.spawn = function(path, options, callback)
  local handle, child = spawn(path, options, callback)
  if vim.list_contains(options.args or {}, controller) then
    pid = child
  end
  return handle, child
end
local f = make(root)
local select, dialogs = vim.ui.select, {}
vim.ui.select = function(items, options, callback)
  dialogs[#dialogs + 1] = { items = items, callback = callback, prompt = options.prompt }
end
local function choose(index, item)
  local dialog = dialogs[index or #dialogs]
  dialog.callback(dialog.items[item or 2])
end
local function close()
  if f.snapshot().phase == "closed" then
    return
  end
  local before = #dialogs
  vim.cmd("NvimAIChatClose")
  if #dialogs > before then
    choose()
  end
  f.phase("closed")
end
local function review(index)
  vim.cmd("NvimAIChatReview")
  choose(nil, index or 1)
end
local function fresh()
  if f.owner() then
    close()
    for _, file in ipairs(f.files) do
      vim.fn.writefile({ "original text" }, file)
      local buf = vim.fn.bufadd(file)
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("edit!")
      end)
    end
    vim.cmd("NvimAIChatNew")
  end
  f.compose("Propose edits to all selected files.")
  vim.cmd("NvimAIChatSend")
  f.phase("review")
  review()
end
local function edit(lines)
  vim.cmd("NvimAIChatEditProposal")
  f.phase("editing")
  local buf = vim.api.nvim_get_current_buf()
  assert(vim.bo[buf].filetype == "draft-proposal-correction")
  if lines then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
  return buf
end
local function bytes(index)
  return table.concat(vim.fn.readfile(f.files[index], "b"), "\n")
end
local function prompts()
  local n = 0
  for _, item in ipairs(f.audit) do
    if item.method == "session/prompt" then
      n = n + 1
    end
  end
  return n
end
local ok, reason = xpcall(function()
  assert(vim.fn.exists(":NvimAIChatEditProposal") == 2, "manual correction commands are missing")
  fresh()
  vim.cmd("NvimAIChatApprove")
  f.phase("review")
  review(2)
  local original, sent, panel = f.snapshot().review, prompts(), vim.api.nvim_get_current_buf()
  vim.cmd("NvimAIChatRejectAll")
  local stale = #dialogs
  local draft = edit({ "manual correction", "" })
  choose(stale)
  assert(f.snapshot().phase == "editing")
  assert(not vim.bo[panel].modifiable and vim.api.nvim_get_current_buf() == draft)
  assert(not f.runtime:chat_approve() and not f.runtime:chat_approve_all())
  f.compose("Keep this unsent question")
  assert(not f.runtime:chat_send())
  assert(f.text("draft-chat-input") == "Keep this unsent question")
  f.compose("")
  vim.cmd("NvimAIChatHide")
  assert(vim.api.nvim_buf_is_loaded(draft) and not f.runtime:chat_approve())
  vim.cmd("NvimAIChatEditProposal")
  assert(vim.api.nvim_get_current_buf() == draft)
  vim.cmd("NvimAIChatFreezeProposal")
  f.phase("review")
  assert(f.snapshot().review.token ~= original.token and f.snapshot().review.revision == 2)
  assert(f.snapshot().review.files[1].state == "accepted")
  assert(prompts() == sent and #f.snapshot().turns == 1)
  assert(bytes(1) == "proposed edit\n" and bytes(2) == "original text\n")
  assert(not f.runtime:chat_approve_all(), "replacement requires fresh visits")
  review(2)
  vim.cmd("NvimAIChatApprove")
  f.phase("review")
  assert(bytes(2) == "manual correction\n\n" and bytes(3) == "original text\n")
  vim.cmd("NvimAIChat")
  f.rendered("manual correction")
  print("ok - public correction freezes exact bytes without model turn or publication")

  fresh()
  original = f.snapshot().review
  draft = edit()
  vim.cmd("NvimAIChatFreezeProposal")
  f.phase("review")
  assert(f.snapshot().review.token == original.token and not vim.api.nvim_buf_is_valid(draft))
  review()
  draft = edit({ "discard me" })
  vim.cmd("NvimAIChatDiscardCorrection")
  stale = #dialogs
  vim.api.nvim_buf_set_lines(draft, 0, -1, false, { "newer draft" })
  choose(stale)
  assert(f.snapshot().phase == "editing" and vim.api.nvim_buf_is_valid(draft))
  vim.cmd("NvimAIChatDiscardCorrection")
  choose()
  f.phase("review")
  assert(not vim.api.nvim_buf_is_valid(draft) and f.snapshot().review.token == original.token)

  for _, case in ipairs({
    { lines = { "" }, eol = false, bytes = "" },
    { lines = { "" }, eol = true, bytes = "\n" },
    { lines = { "", "" }, eol = true, bytes = "\n\n" },
  }) do
    fresh()
    draft = edit(case.lines)
    vim.bo[draft].endofline = case.eol
    vim.cmd("NvimAIChatFreezeProposal")
    f.phase("review")
    review()
    vim.cmd("NvimAIChatApprove")
    f.phase("review")
    assert(bytes(1) == case.bytes)
  end
  print("ok - no-op identity, stale discard dialogs, empty files and newlines stay exact")

  for _, operation in ipairs({ "Cancel", "Close" }) do
    fresh()
    draft = edit({ "keep these edits" })
    vim.api.nvim_buf_set_lines(draft, 0, -1, false, { string.rep('"', 600000) })
    assert(not f.runtime:chat_freeze_proposal())
    assert(f.snapshot().phase == "editing" and vim.bo[draft].modifiable)
    vim.api.nvim_buf_set_lines(draft, 0, -1, false, { "keep these edits" })
    vim.cmd("NvimAIChatHide")
    vim.cmd("NvimAIChat" .. operation)
    choose()
    f.phase(operation == "Close" and "closed" or "idle")
    assert(
      vim.api.nvim_buf_is_loaded(draft) and vim.bo[draft].modified and vim.bo[draft].modifiable
    )
    assert(vim.api.nvim_buf_get_lines(draft, 0, -1, false)[1] == "keep these edits")
    assert(not f.runtime:chat_freeze_proposal())
    assert(bytes(1) == "original text\n")
    vim.api.nvim_buf_delete(draft, { force = true })
  end
  fresh()
  draft = edit({ "correction interrupted by cancel" })
  vim.cmd("NvimAIChatFreezeProposal")
  assert(f.snapshot().phase == "freezing")
  vim.cmd("NvimAIChatHide")
  vim.cmd("NvimAIChatCancel")
  choose()
  f.phase("idle")
  assert(vim.api.nvim_buf_is_loaded(draft) and vim.bo[draft].modifiable)
  assert(vim.api.nvim_buf_get_lines(draft, 0, -1, false)[1] == "correction interrupted by cancel")
  assert(bytes(1) == "original text\n")
  vim.api.nvim_buf_delete(draft, { force = true })
  fresh()
  vim.cmd("NvimAIChatReject")
  f.phase("review")
  review(2)
  vim.cmd("NvimAIChatReject")
  f.phase("review")
  review(3)
  draft = edit({ "original text" })
  vim.cmd("NvimAIChatFreezeProposal")
  f.phase("idle")
  assert(not vim.api.nvim_buf_is_valid(draft), "baseline reversion must consume the frozen draft")
  assert(f.snapshot().rounds[1].files[3].state == "unchanged")
  assert(bytes(3) == "original text\n")

  fresh()
  draft = edit({ "submitted correction" })
  vim.cmd("NvimAIChatFreezeProposal")
  vim.bo[draft].modifiable = true
  vim.api.nvim_buf_set_lines(draft, 0, -1, false, { "newer unsent edits" })
  f.phase("review")
  assert(vim.api.nvim_buf_is_loaded(draft) and vim.bo[draft].modifiable)
  assert(vim.api.nvim_buf_get_lines(draft, 0, -1, false)[1] == "newer unsent edits")
  review()
  vim.cmd("NvimAIChatApprove")
  f.phase("review")
  assert(bytes(1) == "submitted correction\n")
  vim.api.nvim_buf_delete(draft, { force = true })
  print("ok - refusal, hidden cancel/close and late edits preserve draft text")

  fresh()
  draft = edit({ "survive controller loss" })
  assert(pid and vim.uv.kill(pid, 9))
  f.phase("failed")
  assert(f.snapshot().recovery_required and not f.runtime:chat_freeze_proposal())
  assert(vim.api.nvim_buf_is_loaded(draft) and vim.bo[draft].modifiable)
  assert(vim.api.nvim_buf_get_lines(draft, 0, -1, false)[1] == "survive controller loss")
  assert(bytes(1) == "original text\n")
  print("ok - controller loss keeps editable text without replaying freeze")
end, debug.traceback)
f.cleanup()
vim.uv.spawn, vim.ui.select = spawn, select
vim.fn.delete(root, "rf")
assert(ok, reason)
