-- Real floating windows, fuzzy filtering, key mappings and cancellation.
local picker = require("ai.review.picker")
vim.o.columns, vim.o.lines = 110, 36
vim.o.cursorlineopt = "number"
local source, owner = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_lines(source, 0, -1, false, { "unsaved source stays intact" })
local tick = vim.api.nvim_buf_get_changedtick(source)
local items = {
  { label = "[unresolved] z-latest.lua", path = "z-latest.lua" },
  { label = "[conflicted] src/older.lua", path = "src/older.lua" },
  { label = "[unresolved] src/other.lua", path = "src/other.lua" },
  { label = "[batch] Abandon review batch", abandon = true },
}
local function eq(actual, expected, message)
  assert(vim.deep_equal(actual, expected), message .. ": " .. vim.inspect(actual))
end
local function keys(input)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(input, true, false, true), "xt", false)
end
local function find(kind)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == kind then
      return win, buf
    end
  end
end
local function open(choices)
  local result, calls = nil, 0
  local cancel = picker.select(choices or items, {
    prompt = "AI review batch private-id",
    format_item = function(item)
      return item.label
    end,
  }, function(item, index)
    calls = calls + 1
    result = { item = item, index = index }
  end)
  vim.cmd.stopinsert()
  local input_win, input = find("nvim-ai-review-search")
  local list_win, list = find("nvim-ai-review-picker")
  return {
    input_win = input_win,
    input = input,
    list_win = list_win,
    list = list,
    cancel = cancel,
    result = function()
      return result, calls
    end,
  }
end
local function lines(t)
  return vim.api.nvim_buf_get_lines(t.list, 0, -1, false)
end
local function query(t, text)
  vim.api.nvim_buf_set_lines(t.input, 0, -1, false, { text })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = t.input })
end
local function finished(t)
  assert(
    vim.wait(1000, function()
      return select(2, t.result()) == 1
    end),
    "picker callback completes exactly once"
  )
  eq(vim.api.nvim_win_is_valid(t.input_win), false, "search window closes")
  eq(vim.api.nvim_win_is_valid(t.list_win), false, "result window closes")
  eq(vim.api.nvim_buf_is_valid(t.input), false, "search scratch is removed")
  eq(vim.api.nvim_buf_is_valid(t.list), false, "result scratch is removed")
end

local t = open()
assert(vim.api.nvim_win_get_config(t.input_win).relative == "editor", "search floats")
assert(vim.api.nvim_win_get_config(t.list_win).relative == "editor", "results float")
eq(
  vim.wo[t.list_win].cursorlineopt,
  "line",
  "selected row stays visible with number-only source highlighting"
)
eq(vim.api.nvim_get_current_win(), t.input_win, "search receives focus")
eq(
  lines(t),
  vim.tbl_map(function(item)
    return item.label
  end, items),
  "unfiltered rows preserve newest-first ordering and final batch action"
)
for _, buf in ipairs({ t.input, t.list }) do
  assert(not vim.bo[buf].swapfile and not vim.bo[buf].undofile and not vim.bo[buf].modeline)
end
eq(select(2, t.result()), 0, "opening does not select or abandon anything")
keys("<Down><CR>")
finished(t)
eq(t.result().item, items[2], "arrow navigation selects the highlighted original item")
eq(t.result().index, 2, "callback receives the original item index")
eq(vim.api.nvim_get_current_win(), owner, "selection restores source focus before callback")
t.cancel()
eq(select(2, t.result()), 1, "cancellation remains idempotent after selection")

t = open()
query(t, "old")
eq(lines(t), { items[2].label }, "status labels do not produce unrelated fuzzy matches")
query(t, "srold")
eq(lines(t), { items[2].label }, "noncontiguous fuzzy search finds the path")
keys("<CR>")
finished(t)
eq(t.result().item.path, "src/older.lua", "filtered Enter keeps the literal path")
eq(t.result().index, 2, "filtering does not change the callback index")

t = open()
keys("iolder<CR>")
finished(t)
eq(t.result().item, items[2], "typing and Enter in one input batch uses the latest query")

t = open()
query(t, "no-such-file")
eq(lines(t), { "No matching changes" }, "empty search results are explicit")
keys("<CR>")
eq(select(2, t.result()), 0, "empty Enter cannot abandon the review batch")
query(t, "")
keys("<C-n><C-n><C-p><CR>")
finished(t)
eq(t.result().item, items[2], "Ctrl-n and Ctrl-p move without changing the query")

t = open()
keys("j<CR>")
finished(t)
eq(t.result().item, items[2], "normal-mode j navigates the list")

t = open()
keys("iolder<Esc>")
finished(t)
eq(t.result().item, nil, "Escape during search cancels without choosing")
eq(vim.api.nvim_get_current_win(), owner, "Escape returns to the source window")

t = open({ { label = "literal\nname\t.lua", path = "literal\nname\t.lua" } })
eq(lines(t), { "literal%0Aname%09.lua" }, "control bytes cannot inject result rows")
keys("<CR>")
finished(t)
eq(t.result().item.path, "literal\nname\t.lua", "display escaping preserves exact selection")

t = open()
keys("<Down>")
vim.o.columns, vim.o.lines = 54, 18
vim.api.nvim_exec_autocmds("VimResized", {})
eq(vim.api.nvim_win_get_cursor(t.list_win)[1], 2, "resizing preserves selection")
local size = vim.api.nvim_win_get_config(t.list_win)
assert(size.width <= 50 and size.height <= 10, "picker fits a smaller editor")
keys("<CR>")
finished(t)
eq(t.result().item, items[2], "resized selection still opens the intended file")

t = open()
vim.o.columns, vim.o.lines = 20, 6
vim.api.nvim_exec_autocmds("VimResized", {})
finished(t)
eq(t.result().item, nil, "unusable terminal size cancels safely")
vim.o.columns, vim.o.lines = 110, 36

t = open()
vim.api.nvim_set_current_win(owner)
finished(t)
eq(t.result().item, nil, "leaving the picker cancels without stealing focus")
eq(vim.api.nvim_get_current_win(), owner, "focus stays on the destination window")

t = open()
vim.api.nvim_win_close(t.list_win, true)
finished(t)
eq(t.result().item, nil, "external window closure retires the entire picker")

t = open()
local replacement = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(replacement, 0, -1, false, { "unrelated unsaved buffer" })
vim.api.nvim_win_set_buf(t.input_win, replacement)
assert(
  vim.wait(1000, function()
    return select(2, t.result()) == 1
  end),
  "repurposed picker cancels"
)
eq(t.result().item, nil, "window repurposing makes no selection")
eq(vim.api.nvim_win_get_buf(t.input_win), replacement, "cleanup preserves the repurposed window")
eq(
  vim.api.nvim_get_current_win(),
  t.input_win,
  "cleanup does not take focus from unrelated content"
)
eq(vim.api.nvim_win_is_valid(t.list_win), false, "cleanup removes remaining owned windows")
eq(
  vim.api.nvim_buf_get_lines(replacement, 0, -1, false),
  { "unrelated unsaved buffer" },
  "unrelated text survives"
)
vim.api.nvim_win_close(t.input_win, true)
vim.api.nvim_buf_delete(replacement, { force = true })

eq(vim.api.nvim_buf_get_changedtick(source), tick, "picker never changes unsaved source text")
assert(vim.bo[source].modified, "unsaved source remains unsaved")
eq(#vim.api.nvim_list_wins(), 1, "no picker windows leak")
print("ok - floating review picker search, navigation, selection and lifecycle")
