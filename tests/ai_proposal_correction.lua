-- Editable drafts preserve supported bytes without owning project publication.
local loaded, correction = pcall(require, "ai.proposal_correction")
assert(loaded, "The separate proposal correction buffer is not implemented")
local function eq(actual, expected)
  assert(vim.deep_equal(actual, expected), vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
end
for _, bytes in ipairs({ "", "\n", "\n\n", "text\n", "text\n\n\n", "é 日本語\n" }) do
  local draft = assert(correction.open("example.txt", bytes))
  local buf = vim.api.nvim_get_current_buf()
  local text, stamp = draft:snapshot()
  eq(text, bytes)
  assert(draft:unchanged(stamp) and not draft:modified())
  assert(vim.wo.winbar:find("Editable correction", 1, true))
  if bytes == "" then
    assert(vim.wo.winbar:find("0 bytes", 1, true))
  end
  if bytes == "\n" then
    assert(vim.wo.winbar:find("final newline", 1, true))
  end
  for _, key in ipairs({ "a", "r", "A", "R", "q" }) do
    assert(vim.fn.maparg(key, "n") == "", "review mappings leaked into editable text")
  end
  assert(draft:hide())
  assert(vim.api.nvim_buf_is_loaded(buf))
  assert(draft:show())
  eq(vim.api.nvim_get_current_buf(), buf)
  eq(draft:snapshot(), bytes)
  assert(draft:lock(stamp))
  assert(not vim.bo[buf].modifiable)
  assert(draft:unchanged(stamp))
  draft:release()
  assert(vim.bo[buf].modifiable)
  draft:discard()
  assert(not vim.api.nvim_buf_is_valid(buf))
end
local draft = assert(correction.open("example.txt", "seed\n"))
vim.cmd("normal! A!")
eq(draft:snapshot(), "seed!\n")
vim.cmd("undo")
eq(draft:snapshot(), "seed\n")
vim.cmd("redo")
eq(draft:snapshot(), "seed!\n")
local buf = vim.api.nvim_get_current_buf()
for _, option in ipairs({ "bomb", "binary", "modeline", "swapfile", "undofile", "fixendofline" }) do
  vim.bo[buf][option] = true
  assert(not draft:snapshot(), "unsafe draft metadata was accepted: " .. option)
  vim.bo[buf][option] = false
end
vim.bo[buf].fileformat = "dos"
assert(not draft:snapshot())
vim.bo[buf].fileformat = "unix"
for _, line in ipairs({
  "bad\0byte",
  "bad\rbyte",
  "\239\187\191BOM",
  "\255",
  string.rep("x", 1024 * 1024),
}) do
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  assert(not draft:snapshot(), "unsupported text was normalized instead of refused")
end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
vim.bo[buf].endofline = false
eq(draft:snapshot(), "")
vim.bo[buf].endofline = true
eq(draft:snapshot(), "\n")
local _, stamp = draft:snapshot()
assert(draft:lock(stamp))
vim.bo[buf].modifiable = true
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "newer edits" })
assert(not draft:unchanged(stamp))
draft:detach()
assert(vim.bo[buf].modifiable and vim.bo[buf].modified)
eq(draft:snapshot(), "newer edits\n")
assert(vim.wo.winbar:find("Detached correction", 1, true))
draft:discard()
print("ai_proposal_correction: exact bytes, undo, metadata, bounds and detached edits passed")
