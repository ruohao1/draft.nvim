-- Fresh editor after interruption: opening cannot restore context, authority or work.
local config = vim.json.decode(table.concat(vim.fn.readfile(vim.env.DRAFT_EDITOR_CONFIG), "\n"))
config.selection, config.enabled = nil, true
vim.o.swapfile, vim.o.undofile, vim.o.modeline = false, false, false
vim.cmd.edit(vim.fn.fnameescape(config.root .. "/example.txt"))
local runtime = require("draft").setup({ staged = config })
vim.cmd("NvimAIChat")
local status = assert(runtime:conversation_status())
assert(status.state == "idle" and status.turn == 0)
assert(not status.retry_safe and not status.recovery_required)
assert(vim.bo.filetype == "draft-chat-input")
assert(vim.api.nvim_get_current_line() == "")
assert(not runtime:chat_review(), "A fresh editor must not revive approval authority")
local pid = vim.uv.os_getpid()
local children = table.concat(vim.fn.readfile("/proc/" .. pid .. "/task/" .. pid .. "/children"))
assert(children:match("^%s*$"), "Opening a fresh chat must not launch a controller or worker")
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "draft-chat" then
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert(not text:find("Wait for editor shutdown.", 1, true), "Old transcript must not reappear")
  end
end
vim.cmd("NvimAIChatClose")
assert(
  vim.wait(10000, function()
    return runtime:conversation_status() == nil
  end, 10),
  "Fresh owner must confirm Close"
)
assert(runtime:shutdown())
print("ok - restarted editor has no old context, approval authority or implicit request")
vim.cmd("qa!")
