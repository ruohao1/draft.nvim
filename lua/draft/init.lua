-- Public facade; internal ai modules and NvimAI commands retain their names.
local M = {}

function M.setup(options)
  if vim.fn.has("nvim-0.12") == 0 then
    error("Draft requires Neovim 0.12 or newer (tested with 0.12.4)", 2)
  end
  options = vim.tbl_extend("keep", options or {}, { keymaps = false })
  return require("ai").setup(options)
end

function M.compact()
  local ai = package.loaded["ai"]
  return ai and ai.compact() or ""
end

return M
