-- The Python parent proves process/store cleanup after a public chat editor exits.
local config = vim.json.decode(table.concat(vim.fn.readfile(vim.env.DRAFT_EDITOR_CONFIG), "\n"))
config.selection, config.enabled = nil, true
vim.o.swapfile, vim.o.undofile, vim.o.modeline = false, false, false
vim.o.columns, vim.o.lines = 140, 42
vim.cmd.edit(vim.fn.fnameescape(config.root .. "/example.txt"))
require("draft").setup({ staged = config })
vim.cmd("NvimAIChat")
assert(vim.bo.filetype == "draft-chat-input")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Wait for editor shutdown." })
vim.cmd("NvimAIChatSend")
vim.cmd("NvimAIChatHide")
assert(vim.wait(15000, function()
  return vim.uv.fs_stat(vim.env.DRAFT_EDITOR_GATE) ~= nil
end, 10))
vim.cmd("qa!")
