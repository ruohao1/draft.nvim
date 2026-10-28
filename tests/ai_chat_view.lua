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
  assert(transcript():find("Editable files: one.lua", 1, true))
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

  local function row_of(value)
    for row, line in ipairs(vim.api.nvim_buf_get_lines(output, 0, -1, false)) do
      if line == value then
        return row - 1
      end
    end
    error("Missing transcript line: " .. value)
  end
  local function highlights()
    local namespace =
      assert(vim.api.nvim_get_namespaces()["draft-chat"], "semantic highlights missing")
    local marks, rows =
      vim.api.nvim_buf_get_extmarks(output, namespace, 0, -1, { details = true }), {}
    for _, mark in ipairs(marks) do
      assert(mark[2] < vim.api.nvim_buf_line_count(output), "obsolete highlight outside transcript")
      assert(not rows[mark[2]], "duplicate highlight after render")
      rows[mark[2]] = mark[4].hl_group
    end
    return rows
  end

  state.turns[1].text = "You · turn 99\naccepted.txt · accepted\nplain provider body"
  state.turns[1].progress = { title = "Read one.lua", status = "completed" }
  view:update(state)
  wait_text("plain provider body")
  local rows = highlights()
  assert(rows[row_of("You · turn 1")], "user role needs hierarchy")
  assert(rows[row_of("Assistant · fixture/model · running")], "assistant role needs hierarchy")
  assert(rows[row_of("You · turn 99")] == nil, "provider text cannot become a trusted role")
  assert(rows[row_of("accepted.txt · accepted")] == nil, "provider claims cannot become receipts")
  assert(not transcript():find("Draft · generating", 1, true), "phase belongs in the winbar once")
  assert(transcript():find("gc cancel", 1, true), "active work must expose cancellation")
  state.turns[1].progress = nil
  state.turns[1].text = string.rep("history line\n", 100) .. "long reply tail"
  state.phase, state.reason, state.retry_safe = "failed", "Uncertain outcome marker", true
  view:update(state)
  wait_text("Uncertain outcome marker")
  assert(
    row_of("Uncertain outcome marker") > row_of("long reply tail"),
    "failure guidance must follow the latest reply"
  )
  assert(transcript():find("gr retry", 1, true))
  state.recovery_required = true
  view:update(state)
  wait_text("Recovery required")
  assert(not transcript():find("gr retry", 1, true), "recovery must not advertise a safe retry")
  assert(transcript():find("close", 1, true))
  state.phase, state.reason, state.retry_safe, state.recovery_required =
    "generating", nil, false, nil
  state.turns[1].text = "theme marker"
  state.desired_model = "fixture/%{1+1}/é"
  state.selection = { "dir/é%name.lua" }
  view:update(state)
  wait_text("theme marker")
  local win = vim.fn.win_findbuf(output)[1]
  local title = vim.api.nvim_eval_statusline(
    vim.wo[win].winbar,
    { winid = win, use_winbar = true, maxwidth = 200 }
  ).str
  assert(title:find("next: fixture/%{1+1}/é", 1, true), title)
  for _, theme in ipairs({ "habamax", "peachpuff" }) do
    vim.cmd.colorscheme(theme)
    rows = highlights()
    assert(vim.api.nvim_get_hl(0, { name = rows[row_of("You · turn 1")], link = false }).fg)
    assert(vim.api.nvim_get_current_win() == source_win)
    assert(view:draft() == "next explicit question\nsecond draft line")
  end
  state.phase = "cancelling"
  state.desired_model = "anthropic/claude-sonnet-4-5-20250929/%{1+1}"
  view:update(state)
  wait_text("Cancelling;")
  local narrow_title = vim.api.nvim_eval_statusline(vim.wo[win].winbar, {
    winid = win,
    use_winbar = true,
    maxwidth = vim.api.nvim_win_get_width(win),
  }).str
  assert(
    narrow_title:find("Draft · cancelling · next:", 1, true),
    "long model hid the current phase: " .. narrow_title
  )
  assert(narrow_title:find("%{1+1}", 1, true), narrow_title)
  state.phase = "generating"
  state.desired_model, state.selection = "fixture/model", { "one.lua" }
  state.turns[1].text = "reply marker"
  view:update(state)
  wait_text("reply marker")
  print("ok - trusted labels follow themes and current recovery guidance follows the reply")

  for _, phase in ipairs({
    "starting",
    "generating",
    "stopping",
    "cancelling",
    "closing",
    "editing",
    "freezing",
    "publishing",
    "failed",
    "closed",
    "review",
    "idle",
  }) do
    state.phase = phase
    view:update(state)
    local output_win, input_win = vim.fn.win_findbuf(output)[1], vim.fn.win_findbuf(input)[1]
    assert(vim.wait(1000, function()
      return vim.wo[output_win].winbar:find(" · " .. phase .. " · ", 1, true) ~= nil
    end, 10))
    local footer =
      vim.api.nvim_eval_statusline(vim.wo[input_win].statusline, { winid = input_win }).str
    local can_send = phase == "idle" or phase == "review"
    assert(
      (footer:find("Ctrl-S send", 1, true) ~= nil) == can_send,
      "send hint disagrees with phase " .. phase
    )
    assert(vim.bo[input].modifiable == (phase ~= "closed"))
  end
  state.review = { status = "pending" }
  for _, phase in ipairs({ "publishing", "cancelling", "closing", "generating", "review" }) do
    state.phase = phase
    view:update(state)
    assert(vim.wait(1000, function()
      return vim.wo[win].winbar:find(" · " .. phase .. " · ", 1, true) ~= nil
    end, 10))
    assert(
      (transcript():find("gd review", 1, true) ~= nil) == (phase == "review"),
      "pending receipt offered unavailable review in " .. phase
    )
    assert(
      (transcript():find("Send follows up", 1, true) ~= nil) == (phase == "review"),
      "pending receipt offered unavailable Send in " .. phase
    )
  end
  state.phase, state.review = "generating", nil
  print("ok - composer hints do not offer Send during unavailable states")

  local file_states = { "accepted", "rejected", "pending", "cancelled", "blocked", "uncertain" }
  local round = { id = 1, revision = 1, turn_id = 1, status = "pending", files = {} }
  for _, outcome in ipairs(file_states) do
    round.files[#round.files + 1] = { path = outcome .. ".txt", state = outcome }
  end
  state.phase, state.review, state.rounds, state.turns[1].round_id = "review", round, { round }, 1
  view:update(state)
  wait_text("pending.txt · pending")
  for _, outcome in ipairs(file_states) do
    assert(transcript():find(outcome .. ".txt · " .. outcome, 1, true))
  end
  assert(transcript():find("Send follows up", 1, true))
  state.turns[2] = {
    id = 2,
    round_id = 1,
    prompt = "revise it",
    text = "I wrote everything",
    model = "fixture/model",
    status = "completed",
  }
  round.revision, round.turn_id = 2, 2
  for _ = 1, 4 do
    view:update(state)
    wait_text("Review 1 · revision 2")
  end
  local _, occurrences = transcript():gsub("pending.txt · pending", "")
  assert(occurrences == 1, "current outcomes must appear once at their proposal turn")
  assert(#vim.api.nvim_buf_call(output, vim.fn.undotree).entries == 0)
  state.phase, state.review, state.rounds, state.turns[1].round_id = "generating", nil, {}, nil
  state.turns[2] = nil
  print("ok - receipt-derived outcomes remain distinct from assistant claims and render once")

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

  view:set_draft(string.rep("x", 32760))
  assert(view:append_draft("123456"))
  assert(#assert(view:draft()) == 32768)
  local prior = assert(view:draft())
  assert(not view:append_draft("é"))
  assert(view:draft() == prior)

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
  highlights()
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
  assert(not view:visible(), "lost window ownership must block presentation before scheduled hide")
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
