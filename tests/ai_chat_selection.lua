-- Public selection actions with the real composer/owner and deterministic replies.
vim.o.columns, vim.o.lines = 140, 42
local root = assert(vim.uv.fs_mkdtemp("/tmp/draft-selection-test-XXXXXX"))
local path = root .. "/parser.lua"
local original = { "local café = 1", "local second = 2", "return café + second" }
vim.fn.writefile(original, path)
assert(vim.uv.fs_chmod(path, 420))
vim.env.DRAFT_CHAT_UI_ROOT = root
local fixture = assert(vim.api.nvim_get_runtime_file("tests/fixtures/ai/chat_ui.lua", false)[1])
dofile(fixture)
local runtime = require("draft").setup()
local source = vim.fn.bufnr(path)
local function input()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "draft-chat-input" then
      return buf
    end
  end
  error("Composer missing")
end
local function draft()
  return table.concat(vim.api.nvim_buf_get_lines(input(), 0, -1, false), "\n")
end
local function compose(text)
  vim.api.nvim_buf_set_lines(input(), 0, -1, false, vim.split(text, "\n", { plain = true }))
end
local function hide()
  vim.cmd("NvimAIChatHide")
  vim.api.nvim_set_current_buf(source)
end
local function restore()
  vim.fn.writefile(original, path)
  vim.api.nvim_set_current_buf(source)
  vim.cmd("edit!")
end
local function unchanged(before)
  assert(draft() == before, "Refusal must retain the composer")
  assert(vim.g.chat_fixture_prompts == 0, "Context actions must not submit")
end
local ok, reason = xpcall(function()
  assert(vim.fn.exists(":NvimAIChatAttach") == 2, "Missing public context attachment command")
  compose("Explain this function.")
  hide()
  vim.cmd("1,2NvimAIChatAttach")
  local expected =
    'Explain this function.\n\nSelection from "parser.lua" (lines 1-2):\n```\nlocal café = 1\nlocal second = 2\n```'
  assert(draft() == expected, "Line attachment must preserve text, path and range")
  assert(vim.bo.filetype == "draft-chat-input", "Attachment must focus the composer")
  assert(vim.g.chat_fixture_prompts == 0)
  assert(vim.deep_equal(vim.fn.readfile(path), original))
  hide()
  vim.cmd("NvimAIChat")
  assert(draft() == expected, "Hidden context must survive reopening")
  compose("")
  hide()
  vim.api.nvim_win_set_cursor(0, { 1, 6 })
  vim.cmd("normal! ve")
  local attach = vim.fn.maparg("<leader>at", "x", false, true).callback
  assert(type(attach) == "function", "Visual chat mapping must attach context")
  attach()
  assert(draft() == 'Selection from "parser.lua" (lines 1-1):\n```\ncafé\n```')
  assert(vim.api.nvim_get_mode().mode == "n", "Visual mode must end before composer focus")
  compose("")
  hide()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("normal! \22j4l")
  attach()
  assert(draft() == 'Selection from "parser.lua" (lines 1-2):\n```\nlocal\nlocal\n```')
  compose("")
  hide()
  vim.o.selection = "exclusive"
  vim.api.nvim_win_set_cursor(0, { 1, 6 })
  vim.cmd("normal! v4l")
  attach()
  assert(draft() == 'Selection from "parser.lua" (lines 1-1):\n```\ncafé\n```')
  vim.o.selection = "inclusive"
  compose("")
  hide()
  vim.fn.writefile({ "```" }, path)
  vim.cmd("edit!")
  vim.cmd("1NvimAIChatAttach")
  assert(draft() == 'Selection from "parser.lua" (lines 1-1):\n````\n```\n````')
  hide()
  restore()
  print("ok - line, character and block context preserve exact selected text without submission")

  compose("Keep this draft")
  hide()
  local before = draft()
  assert(not runtime:chat_attach(), "A missing selection/range must be refused")
  unchanged(before)
  local outside = root .. "/other.lua"
  vim.fn.writefile({ "outside selected scope" }, outside)
  assert(vim.uv.fs_chmod(outside, 420))
  vim.cmd.edit(vim.fn.fnameescape(outside))
  assert(not runtime:chat_attach({ line1 = 1, line2 = 1 }))
  unchanged(before)
  vim.api.nvim_set_current_buf(source)
  vim.api.nvim_buf_set_lines(source, 0, 1, false, { "unsaved secret" })
  assert(not runtime:chat_attach({ line1 = 1, line2 = 1 }))
  assert(vim.bo[source].modified)
  unchanged(before)
  restore()
  vim.fn.writefile({ "changed on disk" }, path)
  assert(not runtime:chat_attach({ line1 = 1, line2 = 1 }), "Stale buffer must be refused")
  assert(vim.api.nvim_buf_get_lines(source, 0, 1, false)[1] == original[1])
  assert(vim.fn.readfile(path)[1] == "changed on disk")
  unchanged(before)
  restore()
  assert(not runtime:chat_attach({ line1 = 0, line2 = 1 }))
  assert(not runtime:chat_attach({ line1 = 1, line2 = 4 }))
  unchanged(before)
  vim.api.nvim_create_autocmd("BufEnter", {
    callback = function(event)
      if vim.bo[event.buf].filetype == "draft-chat-input" then
        vim.api.nvim_buf_set_lines(source, 0, 1, false, { "changed during focus" })
        return true
      end
    end,
  })
  assert(not runtime:chat_attach({ line1 = 1, line2 = 1 }), "Focus-time edits must be refused")
  unchanged(before)
  hide()
  restore()
  compose(string.rep("x", 32760))
  before = draft()
  assert(not runtime:chat_attach({ line1 = 1, line2 = 1 }))
  unchanged(before)
  print("ok - missing/out-of-scope, dirty, stale, invalid and oversized context retain the draft")

  compose("Explain this function.")
  hide()
  vim.cmd("1,2NvimAIChatAttach")
  assert(draft() == expected)
  vim.cmd("NvimAIChatSend")
  assert(vim.g.chat_fixture_prompts == 1)
  assert(vim.g.chat_fixture_message == expected, "Only explicit Send submits the captured text")
  assert(draft() == "")
  assert(vim.deep_equal(vim.fn.readfile(path), original))
  vim.cmd("NvimAIChatClose")
  hide()
  assert(not runtime:chat_attach({ line1 = 1, line2 = 1 }), "Closed history cannot accept context")
  assert(vim.g.chat_fixture_prompts == 1 and draft() == "")
  print("ok - explicit Send alone submits context; closed conversation remains read-only")
end, debug.traceback)
pcall(runtime.chat_close, runtime)
pcall(runtime.shutdown, runtime)
vim.fn.delete(root, "rf")
assert(ok, reason)
