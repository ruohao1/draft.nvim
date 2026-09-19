-- Real Neovim windows, scratch buffers, input mappings and viewport behavior.
local ui = require("ai.chat_view")
vim.o.columns, vim.o.lines, vim.o.swapfile = 140, 42, false
vim.cmd("only")
local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_lines(source, 0, -1, false, { "untouched source" })
local source_tick = vim.api.nvim_buf_get_changedtick(source)
local actions, hidden = {}, 0
local view = ui.new({
  on_action = function(name)
    actions[#actions + 1] = name
  end,
  on_hide = function()
    hidden = hidden + 1
  end,
})
local state = {
  conversation_id = string.rep("a", 32),
  owner_generation = 1,
  view_revision = 1,
  phase = "idle",
  root = "/tmp/example",
  selection = { "one.lua" },
  desired_model = "fixture/model",
  turns = {},
  rounds = {},
  retry_safe = false,
}
local function buffer(kind)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == kind then
      return buf
    end
  end
end
local function transcript()
  return table.concat(vim.api.nvim_buf_get_lines(assert(buffer("draft-chat")), 0, -1, false), "\n")
end
local function wait_text(text)
  assert(
    vim.wait(1000, function()
      return transcript():find(text, 1, true) ~= nil
    end, 10),
    transcript()
  )
end
local ok, reason = xpcall(function()
  assert(#vim.api.nvim_list_wins() == 1, "view construction must be passive")
  assert(view:show(state))
  local output, input = assert(buffer("draft-chat")), assert(buffer("draft-chat-input"))
  assert(output ~= input and vim.api.nvim_get_current_buf() == input)
  assert(not vim.bo[output].modifiable and vim.bo[input].modifiable)
  assert(not vim.bo[input].swapfile and not vim.bo[input].undofile and not vim.bo[input].modeline)
  assert(vim.fn.maparg("<C-s>", "i", false, true).buffer == 1)
  assert(vim.fn.maparg("<CR>", "i") == "", "newlines must never submit")
  view:set_draft("next explicit question\nsecond draft line")
  vim.api.nvim_set_current_win(source_win)
  state.phase, state.view_revision = "generating", 2
  state.turns = {
    {
      id = 1,
      prompt = "first question",
      text = "reply marker",
      model = "fixture/model",
      status = "running",
    },
  }
  view:update(state)
  wait_text("reply marker")
  assert(vim.api.nvim_get_current_win() == source_win)
  assert(vim.api.nvim_get_current_buf() == source)
  assert(view:draft() == "next explicit question\nsecond draft line")
  assert(vim.api.nvim_buf_get_changedtick(source) == source_tick)
  assert(#actions == 0, "display operations must never dispatch")
  print("ok - passive view streams without taking focus or changing drafts")

  state.turns[1].text = table.concat(vim.fn["repeat"]({ "history line" }, 100), "\n")
  view:update(state)
  wait_text("history line")
  local transcript_win = vim.fn.win_findbuf(output)[1]
  vim.api.nvim_win_set_cursor(transcript_win, { 3, 0 })
  vim.api.nvim_win_call(transcript_win, function()
    vim.cmd("normal! zt")
  end)
  local before = vim.api.nvim_win_call(transcript_win, vim.fn.winsaveview)
  state.turns[1].text = state.turns[1].text .. "\nnew tail marker"
  view:update(state)
  wait_text("new tail marker")
  local after = vim.api.nvim_win_call(transcript_win, vim.fn.winsaveview)
  assert(before.lnum == after.lnum and before.topline == after.topline)
  assert(vim.api.nvim_get_current_win() == source_win)
  print("ok - reading older transcript text preserves its viewport")

  vim.api.nvim_win_set_cursor(transcript_win, { vim.api.nvim_buf_line_count(output), 0 })
  state.turns[1].text = state.turns[1].text .. "\nfollowed tail"
  view:update(state)
  wait_text("followed tail")
  assert(vim.api.nvim_win_get_cursor(transcript_win)[1] == vim.api.nvim_buf_line_count(output))
  local original_tab = vim.api.nvim_get_current_tabpage()
  vim.cmd("tabnew")
  local background_tab, background_win =
    vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
  state.turns[1].text = "background reply"
  view:update(state)
  wait_text("background reply")
  assert(vim.api.nvim_get_current_tabpage() == background_tab)
  assert(vim.api.nvim_get_current_win() == background_win)
  vim.cmd("tabclose")
  assert(vim.api.nvim_get_current_tabpage() == original_tab)
  print("ok - tail followers advance and background tabs retain focus")

  for index = 1, 6 do
    state.turns[1].text = string.rep("rendered text ", 4096) .. "render number " .. index
    view:update(state)
    wait_text("render number " .. index)
  end
  local history = vim.api.nvim_buf_call(output, vim.fn.undotree)
  assert(#history.entries == 0, "transcript undo retained previous render projections")
  assert(
    #vim.api.nvim_buf_call(input, vim.fn.undotree).entries > 0,
    "composer must retain normal undo"
  )
  print("ok - scheduled transcript renders retain no hidden undo history; composer undo survives")

  state.turns[1].text = "discarded render"
  view:update(state)
  assert(view:hide())
  assert(#vim.api.nvim_list_wins() == 1 and hidden == 1)
  assert(vim.wait(60, function()
    return false
  end, 10) == false)
  assert(not transcript():find("discarded render", 1, true), "hidden view rendered pending work")
  assert(view:show(state))
  assert(buffer("draft-chat") == output and buffer("draft-chat-input") == input)
  assert(view:draft() == "next explicit question\nsecond draft line")
  for _ = 1, 4 do
    assert(view:hide())
    assert(view:show(state))
  end
  assert(buffer("draft-chat") == output and buffer("draft-chat-input") == input)
  print("ok - hide and reopen retain one draft and transcript without submitting")

  view:set_draft(string.rep("x", 32769))
  local draft, why = view:draft()
  assert(draft == nil and type(why) == "string")
  assert(#vim.api.nvim_buf_get_lines(input, 0, -1, false)[1] == 32769)
  view:set_draft("draft retained")
  state.turns[1].text = "old marker\n" .. string.rep("€", 800000) .. "\nlatest marker"
  view:update(state)
  wait_text("latest marker")
  local text = transcript()
  assert(#text < 2 * 1024 * 1024 + 2048 and not text:find("old marker", 1, true))
  assert(text:find("omitted", 1, true))
  for _, line in ipairs(vim.api.nvim_buf_get_lines(output, 0, -1, false)) do
    local first = line:byte(1)
    assert(not first or first < 128 or first >= 192, "display truncation split UTF-8")
  end
  print("ok - transcript retention is bounded and oversize drafts are refused intact")

  state.turns[1].text = "short reply"
  view:update(state)
  wait_text("short reply")
  vim.api.nvim_set_current_win(source_win)
  vim.o.columns, vim.o.lines = 70, 28
  vim.api.nvim_exec_autocmds("VimResized", {})
  assert(vim.wait(500, function()
    local wins = vim.fn.win_findbuf(output)
    return #wins > 0 and vim.api.nvim_win_get_width(wins[1]) > 50
  end, 10))
  assert(vim.api.nvim_get_current_win() == source_win)
  assert(view:draft() == "draft retained")
  vim.o.columns, vim.o.lines = 30, 9
  vim.api.nvim_exec_autocmds("VimResized", {})
  assert(vim.wait(500, function()
    return #vim.fn.win_findbuf(output) == 0
  end, 10))
  assert(view:draft() == "draft retained")
  vim.o.columns, vim.o.lines = 140, 42
  assert(view:show(state))
  print("ok - narrow resize is passive and tiny editors retain hidden draft state")

  state.turns[1].text = string.rep("line\n", 30000) .. "line limit tail"
  view:update(state)
  wait_text("line limit tail")
  assert(vim.api.nvim_buf_line_count(output) <= 20000)
  assert(transcript():find("omitted", 1, true))
  vim.api.nvim_win_close(vim.fn.win_findbuf(input)[1], true)
  assert(vim.wait(500, function()
    return #vim.fn.win_findbuf(output) == 0
  end, 10))
  assert(view:draft() == "draft retained")
  assert(view:show(state))
  vim.api.nvim_buf_delete(input, { force = true })
  assert(
    vim.wait(500, function()
      return #vim.fn.win_findbuf(output) == 0
    end, 10),
    "wiping a chat buffer must passively hide the remaining pane"
  )
  assert(view:show(state))
  input = assert(buffer("draft-chat-input"))
  print("ok - line retention is bounded and manually closed or wiped panes stay closed")

  transcript_win = vim.fn.win_findbuf(output)[1]
  local repurposed = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(repurposed, 0, -1, false, { "user-owned replacement" })
  vim.api.nvim_win_set_buf(transcript_win, repurposed)
  state.turns[1].text = "late reply after repurposing"
  view:update(state)
  assert(
    vim.wait(500, function()
      return #vim.fn.win_findbuf(input) == 0
    end, 10),
    "repurposing a pane must stop the remaining view"
  )
  view:hide()
  assert(vim.api.nvim_win_is_valid(transcript_win))
  assert(vim.api.nvim_win_get_buf(transcript_win) == repurposed)
  view:dispose()
  assert(not vim.api.nvim_buf_is_valid(output) and not vim.api.nvim_buf_is_valid(input))
  assert(vim.api.nvim_buf_get_lines(repurposed, 0, -1, false)[1] == "user-owned replacement")
  assert(vim.api.nvim_buf_get_changedtick(source) == source_tick)
  print("ok - repurposed windows and source buffers survive cleanup")
end, debug.traceback)
view:dispose()
assert(ok, reason)
