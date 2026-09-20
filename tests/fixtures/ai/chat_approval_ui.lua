vim.o.termguicolors, vim.o.number, vim.o.showmode = true, true, true
vim.cmd("colorscheme habamax")
local make =
  dofile(assert(vim.api.nvim_get_runtime_file("tests/fixtures/ai/chat_approval.lua", false)[1]))
_G.chat_approval_fixture = make(vim.env.DRAFT_CHAT_UI_ROOT)
vim.g.chat_fixture_ready = true
