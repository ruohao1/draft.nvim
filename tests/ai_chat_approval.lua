-- Public commands, real frozen buffers, authoritative writer journals and confined ACP workers.
vim.o.columns, vim.o.lines = 140, 42
local root = assert(vim.uv.fs_mkdtemp("/tmp/draft-chat-approval-XXXXXX"))
local make =
  dofile(assert(vim.api.nvim_get_runtime_file("tests/fixtures/ai/chat_approval.lua", false)[1]))
local f = make(root)
local select, dialogs = vim.ui.select, {}
vim.ui.select = function(items, options, callback)
  dialogs[#dialogs + 1] = { items = items, prompt = options.prompt, callback = callback }
end
local function choose(index, choice)
  local dialog = dialogs[index or #dialogs]
  dialog.callback(dialog.items[choice or 2])
end
local function review(index)
  vim.cmd("NvimAIChatReview")
  choose(nil, index or 1)
end
local function request(text)
  f.compose(text or "Propose edits to all selected files.")
  vim.cmd("NvimAIChatSend")
  f.phase("review")
end
local function close()
  if f.snapshot().phase == "closed" then
    return
  end
  local pending = f.snapshot().review
  vim.cmd("NvimAIChatClose")
  if pending and (pending.status == "pending" or pending.status == "revising") then
    choose()
  end
  f.phase("closed")
end
local function fresh()
  close()
  for _, file in ipairs(f.files) do
    vim.fn.writefile({ "original text" }, file)
    local buf = vim.fn.bufadd(file)
    vim.fn.bufload(buf)
    vim.bo[buf].readonly = false
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("edit!")
    end)
  end
  local previous = f.owner()
  vim.cmd("NvimAIChatNew")
  if f.owner() == previous then
    choose()
  end
  request()
end
local function context()
  for index = #f.audit, 1, -1 do
    if f.audit[index].method == "session/prompt" then
      for _, block in ipairs(f.audit[index].params.prompt) do
        if block.text and block.text:find("Editor-confirmed file decisions", 1, true) then
          return vim.json.decode(block.text:match("\n(.*)"))
        end
      end
      error("No confirmed decision context")
    end
  end
end
local function states(expected)
  for index, value in ipairs(expected) do
    assert(f.snapshot().rounds[#f.snapshot().rounds].files[index].state == value)
  end
end
local ok, reason = xpcall(function()
  assert(#f.audit == 0)
  request()
  local original = f.snapshot().review
  for index = 1, 3 do
    assert(f.disk(index) == "original text")
  end
  assert(not f.runtime:chat_approve(), "approval from chat cannot open and accept a diff")
  review()
  local old_approve = f.key("a")
  local origin = vim.api.nvim_get_current_tabpage()
  local before = #dialogs
  vim.cmd("NvimAIChatApproveAll")
  assert(#dialogs == before, "unvisited batch approval must not reach confirmation")
  vim.cmd("NvimAIChatApprove")
  f.phase("review")
  assert(f.disk(1) == "proposed edit" and f.disk(2) == "original text")
  assert(vim.wo.winbar:find("second.txt", 1, true), "approval advances")
  vim.cmd("NvimAIChatReject")
  f.phase("review")
  assert(vim.wo.winbar:find("second.txt", 1, true), "rejection stays visible")
  states({ "accepted", "rejected", "pending" })
  f.key("]f")()
  assert(vim.wo.winbar:find("third.txt", 1, true))
  f.key("f")()
  assert(vim.bo.filetype == "draft-chat-input")
  assert(vim.api.nvim_get_current_tabpage() ~= origin)
  f.rendered("first.txt · accepted")
  f.rendered("second.txt · rejected")
  request("Revise the pending edit.")
  local revised = f.snapshot().review
  assert(revised.token ~= original.token and revised.revision == 2)
  assert(context()[1].state == "accepted" and context()[2].state == "rejected")
  assert(context()[3].state == "pending")
  states({ "accepted", "rejected", "pending" })
  local revision = f.snapshot().view_revision
  old_approve()
  assert(f.snapshot().view_revision == revision, "superseded keys must be inert")
  assert(not f.runtime:chat_approve_all(), "replacement cannot inherit old visits")
  request("Discuss why the pending edit is useful.")
  assert(f.snapshot().review.token == revised.token, "discussion preserves validated proposal")
  review(3)
  assert(vim.api.nvim_get_current_line() == "revised edit")
  vim.cmd("NvimAIChatApprove")
  f.phase("idle")
  states({ "accepted", "rejected", "accepted" })
  assert(
    f.disk(1) == "proposed edit" and f.disk(2) == "original text" and f.disk(3) == "revised edit"
  )
  vim.cmd("NvimAIChat")
  f.compose("Discuss the saved results.")
  vim.cmd("NvimAIChatSend")
  f.phase("idle")
  assert(
    context()[1].state == "accepted"
      and context()[2].state == "rejected"
      and context()[3].state == "accepted"
  )
  f.rendered("third.txt · accepted")
  print(
    "ok - public partial approval, rejection, revision and discussion retain exact decision context"
  )

  fresh()
  review()
  f.key("]f")()
  f.key("]f")()
  vim.cmd("NvimAIChatApproveAll")
  local stale = #dialogs
  f.key("[f")()
  f.key("]f")()
  choose(stale)
  assert(f.snapshot().review.receipt_sequence == 0)
  vim.cmd("NvimAIChatApproveAll")
  stale = #dialogs
  local panel = vim.api.nvim_get_current_buf()
  vim.bo[panel].readonly = false
  choose(stale)
  vim.bo[panel].readonly = true
  assert(f.snapshot().review.receipt_sequence == 0)
  vim.cmd("NvimAIChatApproveAll")
  assert(f.snapshot().phase == "review" and f.disk(1) == "original text")
  choose()
  f.phase("idle")
  states({ "accepted", "accepted", "accepted" })
  assert(f.snapshot().rounds[1].receipt_sequence == 1)
  for index = 1, 3 do
    assert(f.disk(index) == "proposed edit")
  end
  print("ok - confirmed batch approval requires real visits and current navigation/panel evidence")

  fresh()
  review()
  vim.cmd("NvimAIChatRejectAll")
  local stale_reject = #dialogs
  vim.cmd("NvimAIChatApproveAll") -- Refused; an unopened dialog cannot supersede a real one.
  assert(#dialogs == stale_reject)
  choose(stale_reject)
  f.phase("idle")
  states({ "rejected", "rejected", "rejected" })
  assert(f.disk(1) == "original text")

  for _, operation in ipairs({ "Cancel", "Close" }) do
    fresh()
    review()
    vim.cmd("NvimAIChatApprove")
    f.phase("review")
    vim.cmd("NvimAIChatHide")
    f.compose("Keep the next draft")
    f.key("f")()
    assert(
      vim.bo.filetype == "draft-chat-input" and f.text("draft-chat-input") == "Keep the next draft"
    )
    vim.cmd("NvimAIChatHide")
    assert(not f.runtime:open(), "hidden review still excludes native work")
    vim.cmd("NvimAIStage TEST:approve")
    assert(not require("ai.staged").busy())
    vim.cmd("NvimAIChat" .. operation)
    choose()
    f.phase(operation == "Close" and "closed" or "idle")
    assert(f.disk(1) == "proposed edit" and f.disk(2) == "original text")
    states({ "accepted", "cancelled", "cancelled" })
    vim.cmd("NvimAIChat")
    assert(f.text("draft-chat-input") == "Keep the next draft")
  end
  print("ok - hidden cancel and close preserve accepted files, drafts and runtime exclusion")

  for _, damage in ipairs({ "source", "alias", "panel" }) do
    fresh()
    review()
    f.key("]f")()
    f.key("]f")()
    vim.cmd("NvimAIChatApproveAll")
    local stale_dialog = #dialogs
    local target, alias_path
    if damage == "panel" then
      target = vim.api.nvim_get_current_buf()
      vim.bo[target].modifiable = true
    elseif damage == "alias" then
      alias_path = root .. "/source-alias.txt"
      assert(vim.uv.fs_symlink(f.files[1], alias_path))
      target = vim.fn.bufadd(alias_path)
      vim.fn.bufload(target)
    else
      target = vim.fn.bufadd(f.files[1])
    end
    vim.api.nvim_buf_set_lines(target, 0, -1, false, { "user edit during dialog" })
    choose(stale_dialog)
    assert(f.snapshot().phase == "review" and f.snapshot().review.receipt_sequence == 0)
    assert(not f.runtime:chat_approve_all())
    for index = 1, 3 do
      assert(f.disk(index) == "original text")
    end
    vim.cmd("NvimAIChatClose")
    choose()
    f.phase("closed")
    if vim.api.nvim_buf_is_valid(target) then
      assert(vim.api.nvim_buf_get_lines(target, 0, -1, false)[1] == "user edit during dialog")
      if damage ~= "source" then
        vim.api.nvim_buf_delete(target, { force = true })
      end
    end
    if alias_path then
      vim.uv.fs_unlink(alias_path)
    end
  end
  print(
    "ok - public source, hidden alias and frozen-panel drift refuse publication and preserve edits"
  )

  fresh()
  local chat_tab = vim.api.nvim_get_current_tabpage()
  review()
  local review_tab, left = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_buf()
  f.compose("Return after my original tab was closed")
  vim.cmd("NvimAIChatHide")
  vim.api.nvim_set_current_tabpage(chat_tab)
  vim.cmd("tabclose")
  vim.api.nvim_set_current_tabpage(review_tab)
  f.key("f")()
  assert(vim.api.nvim_get_current_tabpage() ~= review_tab)
  assert(vim.bo.filetype == "draft-chat-input")
  assert(f.text("draft-chat-input") == "Return after my original tab was closed")
  assert(vim.api.nvim_tabpage_is_valid(review_tab) and vim.api.nvim_buf_is_valid(left))
  close()
  assert(f.runtime:shutdown())
  print(
    "ok - returning to hidden chat never repurposes frozen windows after the original tab closes"
  )
end, debug.traceback)
f.cleanup()
vim.ui.select = select
vim.fn.delete(root, "rf")
assert(ok, reason)
