-- The parent observes the real controller/worker before allowing editor EOF.
local config = vim.json.decode(table.concat(vim.fn.readfile(vim.env.DRAFT_EDITOR_CONFIG), "\n"))
vim.o.swapfile, vim.o.undofile, vim.o.modeline = false, false, false
vim.cmd.edit(vim.fn.fnameescape(config.root .. "/example.txt"))
local owner = assert(require("ai.conversation_controller").new(config))
assert(
  owner:dispatch(
    { kind = "submit", text = "Wait for editor shutdown." },
    owner:snapshot().view_revision
  )
)
assert(vim.wait(15000, function()
  return vim.uv.fs_stat(vim.env.DRAFT_EDITOR_GATE) ~= nil
end, 10))
vim.cmd("qa!")
