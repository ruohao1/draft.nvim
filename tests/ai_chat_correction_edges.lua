-- Review regressions over the real controller, buffers and publisher.
vim.o.columns, vim.o.lines = 140, 42
local root = assert(vim.uv.fs_mkdtemp("/tmp/draft-correction-edges-XXXXXX"))
local make =
  dofile(assert(vim.api.nvim_get_runtime_file("tests/fixtures/ai/chat_approval.lua", false)[1]))
local f = make(root)
local select, dialogs, failures = vim.ui.select, {}, {}
vim.ui.select = function(items, _, callback)
  dialogs[#dialogs + 1] = { items = items, callback = callback }
end
local function choose(label)
  local dialog = dialogs[#dialogs]
  assert(dialog, "expected an action or confirmation picker")
  local index = label and vim.fn.index(dialog.items, label) + 1 or 2
  assert(index > 0, "action is unavailable: " .. tostring(label))
  dialog.callback(dialog.items[index])
end
local function fresh()
  if f.snapshot().phase ~= "closed" then
    assert(f.owner():dispatch({ kind = "close" }, f.snapshot().view_revision))
    f.phase("closed")
  end
  for _, file in ipairs(f.files) do
    vim.fn.writefile({ "original text" }, file)
    vim.api.nvim_buf_call(vim.fn.bufadd(file), function()
      vim.cmd("edit!")
    end)
  end
  vim.cmd("NvimAIChatNew")
  f.compose("Propose edits to all selected files.")
  vim.cmd("NvimAIChatSend")
  f.phase("review")
end
local function edit()
  assert(f.runtime:chat_edit_proposal())
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "submitted correction" })
  return buf
end
local function scenario(name, run)
  local ok, reason = xpcall(function()
    fresh()
    run()
  end, debug.traceback)
  if ok then
    print("ok - " .. name)
  else
    failures[#failures + 1] = name .. ": " .. reason
  end
end
local ok, reason = xpcall(function()
  for _, operation in ipairs({ "FreezeProposal", "DiscardCorrection" }) do
    scenario("window-leave edits survive " .. operation, function()
      local draft, changed = edit(), false
      vim.api.nvim_create_autocmd("BufWinLeave", {
        buffer = draft,
        once = true,
        callback = function()
          changed = true
          vim.bo[draft].modifiable = true
          vim.api.nvim_buf_set_lines(draft, 0, -1, false, { "newer callback edits" })
        end,
      })
      vim.cmd("NvimAIChat" .. operation)
      if operation == "DiscardCorrection" then
        choose()
      end
      f.phase("review")
      assert(changed and vim.api.nvim_buf_is_loaded(draft), "newer callback edits were deleted")
      assert(vim.api.nvim_buf_get_lines(draft, 0, -1, false)[1] == "newer callback edits")
      assert(vim.bo[draft].modifiable and not f.runtime:chat_freeze_proposal())
      assert(vim.api.nvim_buf_call(draft, function()
        return vim.fn.maparg("g?", "n")
      end) == "", "detached text must regain its ordinary mapping")
      assert(f.disk(1) == "original text")
      vim.cmd("NvimAIChatReview")
      dialogs[#dialogs].callback(dialogs[#dialogs].items[1])
      vim.cmd("NvimAIChatApprove")
      f.phase("review")
      assert(
        f.disk(1) == (operation == "FreezeProposal" and "submitted correction" or "proposed edit")
      )
      vim.api.nvim_buf_delete(draft, { force = true })
    end)
  end
  for _, operation in ipairs({ "FreezeProposal", "DiscardCorrection" }) do
    for _, event in ipairs({ "BufWinLeave", "BufUnload", "BufDelete", "BufWipeout" }) do
      scenario(event .. " cannot lose text during final " .. operation, function()
        local draft, changed = edit(), false
        if event == "BufWinLeave" then
          vim.cmd("vsplit")
        end
        vim.api.nvim_create_autocmd(event, {
          buffer = draft,
          once = true,
          callback = function()
            vim.bo[draft].modifiable = true
            vim.api.nvim_buf_set_lines(draft, 0, -1, false, { "newer teardown edits" })
            changed = true
          end,
        })
        local ignored = vim.o.eventignore
        vim.cmd("NvimAIChat" .. operation)
        if operation == "DiscardCorrection" then
          choose()
        end
        f.phase("review")
        assert(vim.o.eventignore == ignored, "cleanup left editor events disabled")
        if changed then
          assert(vim.api.nvim_buf_is_loaded(draft), "newer teardown edits were deleted")
          assert(vim.api.nvim_buf_get_lines(draft, 0, -1, false)[1] == "newer teardown edits")
          assert(vim.bo[draft].modifiable and not f.runtime:chat_freeze_proposal())
        else
          assert(not vim.api.nvim_buf_is_valid(draft), "consumed draft was not cleaned up")
          assert(vim.fn.exists("#draft_correction_" .. draft) == 0, "draft event handlers leaked")
        end
        assert(f.disk(1) == "original text")
        vim.cmd("NvimAIChatReview")
        dialogs[#dialogs].callback(dialogs[#dialogs].items[1])
        vim.cmd("NvimAIChatApprove")
        f.phase("review")
        assert(
          f.disk(1) == (operation == "FreezeProposal" and "submitted correction" or "proposed edit")
        )
        if vim.api.nvim_buf_is_valid(draft) then
          vim.api.nvim_buf_delete(draft, { force = true })
        end
      end)
    end
  end
  for _, operation in ipairs({ "Cancel", "Close" }) do
    scenario("fresh cleanup after deleted draft: " .. operation, function()
      local draft = edit()
      vim.cmd("NvimAIChat" .. operation)
      vim.api.nvim_buf_delete(draft, { force = true })
      choose()
      assert(f.snapshot().phase == "editing", "deletion must invalidate the older confirmation")
      vim.cmd("NvimAIChat" .. operation)
      choose()
      assert(f.snapshot().phase ~= "editing", "a fresh confirmation must allow cleanup")
      f.phase(operation == "Close" and "closed" or "idle")
      assert(f.disk(1) == "original text")
    end)
  end
  scenario("actions menu reaches Edit and Freeze", function()
    assert(
      type(vim.fn.maparg("g?", "n", false, true).callback) == "function",
      "frozen actions menu is inaccessible"
    )
    f.key("g?")()
    choose("Edit proposal")
    f.phase("editing")
    local draft = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(draft, 0, -1, false, { "menu correction" })
    for _, key in ipairs({ "a", "r", "A", "R", "q" }) do
      assert(vim.fn.maparg(key, "n") == "", "editable text gained a review decision mapping")
    end
    assert(
      type(vim.fn.maparg("g?", "n", false, true).callback) == "function",
      "correction actions menu is inaccessible"
    )
    f.key("g?")()
    choose("Freeze proposal")
    f.phase("review")
    assert(f.snapshot().review.revision == 2 and f.disk(1) == "original text")
  end)
  for _, message in ipairs({ "Discuss the current proposal.", "Try an extra-file." }) do
    scenario("manual source generation after " .. message, function()
      f.compose(message)
      vim.cmd("NvimAIChatSend")
      f.phase("review")
      assert(f.snapshot().turn_id == 2 and f.snapshot().review.source_generation == 1)
      local draft = edit()
      vim.cmd("NvimAIChatFreezeProposal")
      f.phase("review")
      local view = f.snapshot()
      assert(
        view.review.source_generation == 1 and view.review.turn_id == 1,
        "discussion was falsely made the proposal's model source"
      )
      assert(view.turn_id == 2 and view.worker_generation == 2 and #view.turns == 2)
      assert(view.review.origin == "manual" and not vim.api.nvim_buf_is_valid(draft))
      assert(f.disk(1) == "original text")
    end)
  end
end, debug.traceback)
f.cleanup()
vim.ui.select = select
vim.fn.delete(root, "rf")
assert(ok, reason)
assert(#failures == 0, table.concat(failures, "\n\n"))
