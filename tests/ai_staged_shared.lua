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
