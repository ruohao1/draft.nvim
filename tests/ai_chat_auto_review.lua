-- Automatic presentation uses the real controller and guarded frozen review.
vim.o.columns, vim.o.lines = 140, 42
local root = assert(vim.uv.fs_mkdtemp("/tmp/draft-chat-auto-review-XXXXXX"))
local make =
  dofile(assert(vim.api.nvim_get_runtime_file("tests/fixtures/ai/chat_approval.lua", false)[1]))
local f = make(root)
local select, dialogs = vim.ui.select, {}
vim.ui.select = function(items, options, callback)
  dialogs[#dialogs + 1] = { items = items, prompt = options.prompt, callback = callback }
end
local function choose()
  local dialog = dialogs[#dialogs]
  dialog.callback(dialog.items[2])
end
local function close()
  if f.snapshot().phase == "closed" then
    return
  end
  local pending = f.snapshot().review
  vim.cmd("NvimAIChatClose")
  if pending and pending.status == "pending" then
    choose()
  end
  f.phase("closed")
end
local function fresh()
  close()
  local previous = f.owner()
  vim.cmd("NvimAIChatNew")
  if f.owner() == previous then
    choose()
  end
  return vim.api.nvim_get_current_tabpage()
end
local function send(message)
  f.compose(message or "Propose edits to all selected files.")
  vim.cmd("NvimAIChatSend")
end
local function shown(path)
  assert(vim.wo.diff and vim.wo.winbar:find("FROZEN STAGED PROPOSAL", 1, true))
  assert(vim.wo.winbar:find(path, 1, true))
end
local ok, reason = xpcall(function()
  local chat_tab, tabs = vim.api.nvim_get_current_tabpage(), #vim.api.nvim_list_tabpages()
  send()
  f.compose("Keep my next question")
  f.phase("review")
  shown("first.txt")
  assert(#vim.api.nvim_list_tabpages() == tabs + 1 and #dialogs == 0)
  assert(f.snapshot().review.receipt_sequence == 0)
  for index = 1, 3 do
    assert(f.disk(index) == "original text", "automatic presentation must not publish")
  end
  f.key("f")()
  assert(vim.api.nvim_get_current_tabpage() == chat_tab)
  assert(vim.bo.filetype == "draft-chat-input")
  assert(f.text("draft-chat-input") == "Keep my next question")
  vim.cmd("NvimAIChat")
  assert(vim.api.nvim_get_current_tabpage() == chat_tab, "returning must not bounce back to review")
  assert(not f.runtime:chat_approve(), "returning to chat must not approve the shown proposal")
  print("ok - ready proposal opens without a picker or publication and returns to the composer")

  for _, departure in ipairs({ "hide", "other_tab", "repurpose", "rename" }) do
    local origin = fresh()
    send()
    f.compose("Preserve draft across " .. departure)
    local notes
    if departure == "hide" then
      vim.cmd("NvimAIChatHide")
    elseif departure == "other_tab" then
      vim.cmd("tabnew")
    elseif departure == "rename" then
      notes = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_name(notes, "user-owned-composer")
    else
      notes = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), notes)
    end
    notes = notes or vim.api.nvim_get_current_buf()
    local tab, win, count =
      vim.api.nvim_get_current_tabpage(),
      vim.api.nvim_get_current_win(),
      #vim.api.nvim_list_tabpages()
    f.phase("review")
    assert(vim.api.nvim_get_current_tabpage() == tab and vim.api.nvim_get_current_win() == win)
    assert(vim.api.nvim_get_current_buf() == notes and #vim.api.nvim_list_tabpages() == count)
    assert(f.snapshot().review.receipt_sequence == 0)
    if departure == "other_tab" then
      vim.api.nvim_set_current_tabpage(origin)
      vim.api.nvim_exec_autocmds("ModeChanged", { pattern = "i:n" })
      vim.wait(60, function()
        return false
      end, 10)
      assert(
        vim.api.nvim_get_current_tabpage() == origin and #vim.api.nvim_list_tabpages() == count
      )
      assert(not vim.wo.diff, "ordinary tab return must not arm a background proposal")
    elseif departure == "rename" then
      assert(vim.api.nvim_buf_get_lines(notes, 0, -1, false)[1] == "Preserve draft across rename")
      vim.bo[notes].filetype = "text"
    end
    vim.cmd("NvimAIChat")
    shown("first.txt")
    f.key("f")()
    assert(vim.bo.filetype == "draft-chat-input")
    if departure ~= "rename" then
      assert(f.text("draft-chat-input") == "Preserve draft across " .. departure)
    end
    assert(vim.api.nvim_buf_is_valid(notes))
    print("ok - " .. departure .. " defers automatic review until explicit chat reopening")
  end

  fresh()
  send()
  f.phase("review")
  shown("first.txt")
  local original = f.snapshot().review.token
  f.key("a")()
  f.phase("review")
  assert(f.disk(1) == "proposed edit")
  f.key("f")()
  send("Revise the pending edit.")
  f.phase("review")
  shown("second.txt")
  assert(f.snapshot().review.token ~= original and f.snapshot().review.revision == 2)
  local before = #dialogs
  assert(not f.runtime:chat_approve_all(), "automatic display cannot visit other pending files")
  assert(#dialogs == before and f.disk(2) == "original text" and f.disk(3) == "original text")
  local token = f.snapshot().review.token
  f.key("f")()
  send("Discuss why the pending edit is useful.")
  f.phase("review")
  assert(f.snapshot().review.token == token and vim.bo.filetype == "draft-chat-input")
  print("ok - revisions open the first pending file; discussion keeps the composer")
  close()
end, debug.traceback)
f.cleanup()
vim.ui.select = select
vim.fn.delete(root, "rf")
assert(ok, reason)
