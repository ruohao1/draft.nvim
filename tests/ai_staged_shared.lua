-- Shared captured sources and frozen review guards, with real Neovim buffers.
local sources = require("ai.staged_sources")
local review = require("ai.staged_review")
local root = assert(vim.uv.fs_mkdtemp("/tmp/draft-shared-review-XXXXXX"))
local files = { root .. "/first.txt", root .. "/second.txt" }
vim.o.swapfile, vim.o.undofile, vim.o.modeline = false, false, false
for _, path in ipairs(files) do
  vim.fn.writefile({ "original text" }, path)
  assert(vim.uv.fs_chmod(path, 420))
end
local handle
local ok, reason = xpcall(function()
  local staged = require("ai.staged")
  staged.setup({
    enabled = true,
    review_mode = "pre_write",
    model = "fixture/model",
    opencode = "/usr/bin/true",
    root = root,
    provider = { fixture = {} },
  })
  local config = assert(staged.conversation_options())
  config.provider.fixture.changed = true
  assert(not staged.conversation_options().provider.fixture.changed)
  config = assert(staged.conversation_options())
  config.selection = { "first.txt" }
  local owner = assert(require("ai.conversation_controller").new(config))
  assert(owner:snapshot().phase == "idle")
  assert(owner:dispatch({ kind = "close" }, owner:snapshot().view_revision))
  assert(vim.wait(3000, function()
    return owner:snapshot().phase == "closed"
  end, 10))
  staged.setup({ enabled = false, review_mode = "native" })
  assert(not staged.conversation_options())

  local captured = assert(sources.capture(files, root))
  assert(sources.unchanged(captured))
  local frozen = {
    root = root,
    id = string.rep("a", 32),
    proposal = root .. "/proposal.json",
    files = {
      { path = "first.txt", oldText = "original text\n", newText = "proposed edit\n" },
      { path = "second.txt", oldText = "original text\n", newText = "proposed edit\n" },
    },
  }
  local focus, tabs, buffers =
    vim.api.nvim_get_current_win(), #vim.api.nvim_list_tabpages(), #vim.api.nvim_list_bufs()
  handle = assert(review.open(frozen, captured, { defer = true }))
  assert(#vim.api.nvim_list_tabpages() == tabs and vim.api.nvim_get_current_win() == focus)
  assert(
    #vim.api.nvim_list_bufs() == buffers,
    "deferred review must not create panels or synthetic visits"
  )
  assert(handle:intact())
  assert(not handle:decide("approve", "first.txt"))
  handle:retire()
  assert(not handle:show("first.txt"))

  handle = assert(review.open(frozen, captured, { defer = true }))
  local alias_path = root .. "/alias.txt"
  assert(vim.uv.fs_symlink(files[1], alias_path))
  local alias = vim.fn.bufadd(alias_path)
  vim.fn.bufload(alias)
  vim.api.nvim_buf_set_lines(alias, 0, -1, false, { "unsaved hidden alias" })
  assert(not handle:intact() and not handle:show("first.txt"))
  assert(#vim.api.nvim_list_tabpages() == tabs)
  handle:retire()
  vim.api.nvim_buf_delete(alias, { force = true })
  vim.uv.fs_unlink(alias_path)
  -- Neovim may coalesce an alias into the original buffer. A new review must
  -- capture fresh evidence after that dirty-buffer fixture has been discarded.
  captured = assert(sources.capture(files, root))

  for _, damage in ipairs({ "changed", "missing" }) do
    handle = assert(review.open(frozen, captured, { defer = true }))
    assert(handle:show("second.txt"))
    local panel = vim.api.nvim_get_current_buf()
    assert(vim.api.nvim_buf_get_lines(panel, 0, -1, false)[1] == "proposed edit")
    vim.cmd("tabclose")
    assert(handle:show("first.txt"), "intact hidden panels must reopen without recreation")
    assert(handle:intact())
    vim.cmd("tabclose")
    if damage == "changed" then
      vim.bo[panel].modifiable = true
      vim.api.nvim_buf_set_lines(panel, 0, -1, false, { "changed frozen bytes" })
      vim.bo[panel].modified = false
    else
      vim.api.nvim_buf_delete(panel, { force = true })
    end
    assert(not handle:intact() and not handle:show("first.txt"))
    assert(#vim.api.nvim_list_tabpages() == tabs, "damaged panels must not be recreated")
    handle:retire()
  end
  print("ok - deferred frozen reviews preserve guards before first display and across reopening")

  handle = assert(review.open(frozen, captured, { defer = true }))
  assert(handle:current() == nil)
  assert(not handle:prepare("approve", false), "unopened diffs cannot authorize a decision")
  assert(handle:show("first.txt"))
  assert(handle:current() == "first.txt")
  local single = assert(handle:prepare("approve", false))
  assert(single.path == "first.txt" and single.remaining == nil and single.count == 1)
  assert(single.valid())
  assert(not handle:prepare("approve", true), "all pending diffs must be visited before a batch")
  assert(handle:move(1))
  assert(handle:current() == "second.txt")
  local batch = assert(handle:prepare("approve", true))
  assert(batch.remaining and batch.path == nil and batch.count == 2 and batch.valid())
  assert(handle:move(-1) and handle:move(1))
  assert(not batch.valid(), "navigation away and back cannot revive an old confirmation")
  batch = assert(handle:prepare("approve", true))
  local review_tab = vim.api.nvim_get_current_tabpage()
  vim.cmd("tabnew")
  assert(not batch.valid() and handle:current() == nil)
  vim.cmd("tabclose")
  assert(vim.api.nvim_get_current_tabpage() == review_tab)
  batch = assert(handle:prepare("approve", true))
  local frozen_panel = vim.api.nvim_get_current_buf()
  -- An actual text edit, restored to the same bytes, still changes its tick.
  vim.bo[frozen_panel].modifiable = true
  vim.api.nvim_buf_set_lines(frozen_panel, 0, -1, false, { "temporary edit" })
  vim.api.nvim_buf_set_lines(frozen_panel, 0, -1, false, { "proposed edit" })
  vim.bo[frozen_panel].modified, vim.bo[frozen_panel].modifiable = false, false
  assert(not batch.valid(), "restored frozen bytes do not revive a pending confirmation")
  batch = assert(handle:prepare("approve", true))
  vim.bo[frozen_panel].readonly = false
  assert(not batch.valid(), "frozen panel option changes invalidate a confirmation")
  vim.bo[frozen_panel].readonly = true
  assert(vim.uv.fs_symlink(files[1], alias_path))
  alias = vim.fn.bufadd(alias_path)
  vim.fn.bufload(alias)
  batch = assert(handle:prepare("approve", true))
  local alias_readonly = vim.bo[alias].readonly
  vim.bo[alias].readonly = not alias_readonly
  assert(not batch.valid(), "hidden source alias metadata invalidates a confirmation")
  vim.bo[alias].readonly = alias_readonly
  if alias ~= captured.files[1].source then
    vim.api.nvim_buf_delete(alias, { force = true })
  end
  vim.uv.fs_unlink(alias_path)
  batch = assert(handle:prepare("approve", true))
  local guarded_source = captured.files[1].source
  vim.api.nvim_buf_set_lines(guarded_source, 0, -1, false, { "unsaved during confirmation" })
  assert(not batch.valid())
  assert(not handle:prepare("approve", true))
  local reject = assert(handle:prepare("reject", true))
  assert(reject.valid(), "discarding an already dirty proposal must remain possible")
  vim.api.nvim_buf_set_lines(guarded_source, 0, -1, false, { "newer unsaved edit" })
  assert(not reject.valid(), "new source changes still invalidate a rejection confirmation")
  reject = assert(handle:prepare("reject", true))
  handle:retire()
  assert(not reject.valid() and not handle:prepare("reject", true))
  vim.api.nvim_buf_set_lines(guarded_source, 0, -1, false, { "original text" })
  vim.bo[guarded_source].modified = false
  captured = assert(sources.capture(files, root))
  assert(vim.fn.readfile(files[1])[1] == "original text", "eligibility never publishes")
  print("ok - review preparation binds real visits, navigation and buffer confirmation state")

  handle = assert(
    review.open(frozen, captured, { python = assert(require("ai.tools").resolve("python3")) })
  )
  assert(
    not handle:decide("approve", "second.txt"),
    "An unvisited file must never reach the writer"
  )
  assert(handle:show("second.txt"))
  local win = vim.api.nvim_get_current_win()
  local panel = vim.api.nvim_win_get_buf(win)
  vim.bo[panel].modifiable = true
  vim.api.nvim_buf_set_lines(panel, 0, -1, false, { "changed frozen material" })
  vim.bo[panel].modified = false
  assert(
    not handle:decide("approve", "second.txt"),
    "Changed frozen panels must never reach the writer"
  )
  local source = captured.files[1].source
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "unsaved source" })
  assert(not sources.unchanged(captured), "Hidden dirty sources invalidate captured authority")
end, debug.traceback)
if handle then
  handle:close()
end
vim.fn.delete(root, "rf")
assert(ok, reason)
print("ok - shared staged source and review guards")
