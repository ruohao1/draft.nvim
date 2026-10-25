-- Public context actions with the real composer/owner and deterministic replies.
vim.o.columns, vim.o.lines = 140, 42
local root = assert(vim.uv.fs_mkdtemp("/tmp/draft-selection-test-XXXXXX"))
local path = root .. "/parser.lua"
local original = { "local café = 1", "local second = 2", "return café + second" }
vim.fn.writefile(original, path)
assert(vim.uv.fs_chmod(path, 420))
vim.env.DRAFT_CHAT_UI_ROOT = root
dofile(assert(vim.api.nvim_get_runtime_file("tests/fixtures/ai/chat_ui.lua", false)[1]))
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
local function hide(buf)
  vim.cmd("NvimAIChatHide")
  vim.api.nvim_set_current_buf(buf or source)
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
local function passage(body, attribution, fence_size)
  local text, fence = draft(), string.rep(string.char(96), fence_size or 3)
  assert(
    text:find('Read-only context snapshot from "parser.lua" (' .. attribution .. "):", 1, true),
    text
  )
  assert(text:find("Captured: %d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ; modified:"))
  assert(text:sub(-#(fence .. "\n" .. body .. fence)) == fence .. "\n" .. body .. fence, text)
end
local ok, reason = xpcall(function()
  assert(vim.fn.exists(":NvimAIChatAttach") == 2)
  local selection = vim.deepcopy(runtime:conversation_status().selection)
  compose("Explain this function.")
  hide()
  vim.cmd("1,2NvimAIChatAttach")
  passage("local café = 1\nlocal second = 2\n", "lines 1-2; line")
  assert(vim.startswith(draft(), "Explain this function.\n\nRead-only"))
  local expected = draft()
  assert(vim.bo.filetype == "draft-chat-input")
  unchanged(expected)
  assert(vim.deep_equal(vim.fn.readfile(path), original))
  hide()
  vim.cmd("NvimAIChat")
  assert(draft() == expected, "Hidden context must survive reopening")
  compose("")
  hide()
  vim.api.nvim_win_set_cursor(0, { 1, 6 })
  vim.cmd("normal! ve")
  local attach = vim.fn.maparg("<leader>at", "x", false, true).callback
  assert(type(attach) == "function")
  attach()
  passage("café\n", "lines 1-1; character")
  assert(vim.api.nvim_get_mode().mode == "n")
  compose("")
  hide()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("normal! \22j4l")
  attach()
  passage("local\nlocal\n", "lines 1-2; block")
  compose("")
  hide()
  vim.o.selection = "exclusive"
  vim.api.nvim_win_set_cursor(0, { 1, 6 })
  vim.cmd("normal! v4l")
  attach()
  passage("café\n", "lines 1-1; character")
  vim.o.selection = "inclusive"
  compose("")
  hide()
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { string.rep(string.char(96), 100) })
  vim.cmd("1NvimAIChatAttach")
  passage(string.rep(string.char(96), 100) .. "\n", "lines 1-1; line", 101)
  hide()
  restore()
  print("ok - line, character and block context preserve exact text without submission")

  compose("Keep this draft")
  assert(runtime:chat_attach(), "No range captures the whole current buffer")
  passage(table.concat(original, "\n") .. "\n", "lines 1-3; buffer")
  assert(draft():find("Final newline: yes", 1, true))
  local first_snapshot = draft()
  hide()
  assert(runtime:chat_attach({ line1 = 1, line2 = 1 }))
  assert(draft():sub(1, #first_snapshot + 2) == first_snapshot .. "\n\n")

  hide()
  local unselected = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(unselected, root .. "/new/context-only.txt")
  vim.api.nvim_set_current_buf(unselected)
  vim.api.nvim_buf_set_lines(unselected, 0, -1, false, { "unsaved context" })
  assert(runtime:chat_attach())
  assert(draft():find('"new/context-only.txt"', 1, true))
  assert(draft():find("modified: yes", 1, true))
  assert(vim.bo[unselected].modified)
  assert(vim.api.nvim_buf_get_lines(unselected, 0, -1, false)[1] == "unsaved context")
  assert(vim.uv.fs_stat(root .. "/new") == nil)
  assert(vim.deep_equal(runtime:conversation_status().selection, selection))
  local captured = draft()
  vim.api.nvim_buf_set_lines(unselected, 0, -1, false, { "later edit" })
  assert(draft() == captured, "Snapshots do not refresh after source changes")
  hide()
  vim.api.nvim_buf_set_lines(source, 0, 1, false, { "unsaved selected text" })
  assert(runtime:chat_attach({ line1 = 1, line2 = 1 }))
  assert(vim.bo[source].modified and draft():find("unsaved selected text", 1, true))
  hide()
  restore()
  vim.fn.writefile({ "changed on disk" }, path)
  assert(runtime:chat_attach({ line1 = 1, line2 = 1 }), "Capture uses editor text")
  assert(draft():find(original[1], 1, true))
  assert(vim.fn.readfile(path)[1] == "changed on disk")
  hide()
  restore()
  print(
    "ok - whole, unselected, unsaved and disk-stale snapshots leave sources and scope unchanged"
  )

  compose("Keep this draft")
  local before = draft()
  assert(not runtime:chat_attach({ line1 = 0, line2 = 1 }))
  assert(not runtime:chat_attach({ line1 = 1, line2 = 4 }))
  unchanged(before)
  local outside = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(outside, root .. "-outside.txt")
  vim.api.nvim_set_current_buf(outside)
  assert(not runtime:chat_attach())
  unchanged(before)
  hide()
  for _, change in ipairs({
    function()
      vim.api.nvim_buf_set_lines(source, 0, 1, false, { "changed during focus" })
    end,
    function()
      vim.bo[source].fileformat = "dos"
    end,
    function()
      vim.api.nvim_buf_set_name(source, root .. "/renamed.lua")
    end,
    function()
      compose("newer composer text")
    end,
  }) do
    local fired = false
    vim.api.nvim_create_autocmd("BufEnter", {
      callback = function(event)
        if not fired and vim.bo[event.buf].filetype == "draft-chat-input" then
          fired = true
          change()
          return true
        end
      end,
    })
    assert(not runtime:chat_attach({ line1 = 1, line2 = 1 }))
    assert(fired and vim.g.chat_fixture_prompts == 0)
    assert(draft() == before or draft() == "newer composer text")
    hide()
    vim.api.nvim_buf_set_name(source, path)
    restore()
  end
  compose(string.rep("é", 16300))
  before = draft()
  assert(not runtime:chat_attach())
  unchanged(before)
  print("ok - invalid sources, focus races and complete-message overflow preserve the draft")

  compose("Explain this function.")
  hide()
  vim.cmd("1,2NvimAIChatAttach")
  expected = draft()
  vim.cmd("NvimAIChatSend")
  assert(vim.g.chat_fixture_prompts == 1)
  assert(vim.g.chat_fixture_message == expected)
  assert(vim.g.chat_fixture_commands[1].message == expected)
  assert(draft() == "")
  assert(vim.deep_equal(vim.fn.readfile(path), original))
  hide()
  vim.api.nvim_create_autocmd("BufEnter", {
    callback = function(event)
      if vim.bo[event.buf].filetype == "draft-chat-input" then
        runtime:chat_close()
        return true
      end
    end,
  })
  assert(not runtime:chat_attach(), "Closing while focusing must invalidate attachment")
  assert(runtime:conversation_status() == nil)
  assert(draft() == "")
  hide()
  assert(not runtime:chat_attach())
  assert(vim.g.chat_fixture_prompts == 1 and draft() == "")
  assert(runtime:chat_new({ path }))
  hide()
  local replaced = false
  vim.api.nvim_create_autocmd("BufEnter", {
    callback = function(event)
      if not replaced and vim.bo[event.buf].filetype == "draft-chat-input" then
        replaced = true
        runtime:chat_close()
        assert(runtime:chat_new({ path }))
        compose("new owner's draft")
        return true
      end
    end,
  })
  assert(not runtime:chat_attach(), "A replacement owner must invalidate attachment")
  assert(replaced and draft() == "new owner's draft")
  assert(vim.g.chat_fixture_prompts == 1)
  print("ok - explicit Send alone submits context; closing invalidates captures")
end, debug.traceback)
pcall(runtime.chat_close, runtime)
pcall(runtime.shutdown, runtime)
vim.fn.delete(root, "rf")
assert(ok, reason)
