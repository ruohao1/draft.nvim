-- Public picker + actual scratch windows, keypresses and local file discovery.
-- No provider, credentials, project writes, or optional UI plugin.
local picker = require("ai.staged_picker")
local base = assert(vim.uv.fs_mkdtemp("/tmp/nvim-ai-file-picker-XXXXXX"))
local root = base .. "/project"
vim.fn.mkdir(root .. "/src", "p", "0700")
vim.o.swapfile, vim.o.undofile, vim.o.modeline = false, false, false
local notices, count, cancel = {}, 0
local notify, system = vim.notify, vim.system
vim.notify = function(message)
  notices[#notices + 1] = message
end

local function eq(actual, expected, label)
  assert(vim.deep_equal(actual, expected), (label or "mismatch") .. ": " .. vim.inspect(actual))
end

local function file(name, text, mode)
  local target = root .. "/" .. name
  vim.fn.writefile({ text or "hello" }, target)
  assert(vim.uv.fs_chmod(target, mode or 420))
  return target
end

local first = file("src/first.txt")
local second = file("src/second file.txt", "world")
file(".hidden.txt")
file(".ignore", "ignored.txt")
file("ignored.txt")
file("unsafe.txt", "hello", 438)
file(".env.local")
file("auth.json")
file("private.pem")
file("src/control\nname.txt")
file("huge.txt", string.rep("x", 1024 * 1024))
assert(vim.uv.fs_symlink(first, root .. "/link.txt"))
assert(vim.uv.fs_symlink(root .. "/src", root .. "/alias"))
file("linked.txt")
assert(vim.uv.fs_link(root .. "/linked.txt", root .. "/hardlink.txt"))
vim.fn.mkdir(root .. "/.git", "p")
file(".git/metadata")

local function open()
  local result, calls = nil, 0
  local owner = vim.api.nvim_get_current_win()
  cancel = picker.open(root, function(selected)
    calls, result = calls + 1, selected
  end)
  assert(type(cancel) == "function")
  assert(
    vim.wait(5000, function()
      return vim.bo.filetype == "nvim-ai-staged-picker"
        and vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] ~= "Scanning files..."
    end, 10),
    "file discovery timed out"
  )
  return vim.api.nvim_get_current_win(), function()
    return result, calls
  end, owner
end

local function key(lhs)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, false, true), "xt", false)
end

local function choose(name)
  local found = false
  for line, text in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if text:find(" " .. name .. "  (", 1, true) then
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      found = true
      break
    end
  end
  assert(found, "missing picker candidate: " .. name)
  key("<Tab>")
end

local function scenario(name, run)
  notices = {}
  run()
  if cancel then
    cancel()
  end
  count = count + 1
  print("ok - " .. name)
end

local ok, err = xpcall(function()
  scenario(
    "search, toggle, summary and exact multi-selection without opening source buffers",
    function()
      local win, result, owner = open()
      local listing = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      assert(listing:find(".hidden.txt", 1, true), "hidden dotfiles remain discoverable")
      for _, excluded in ipairs({
        "ignored.txt",
        "unsafe.txt",
        "huge.txt",
        "link.txt",
        "alias/",
        "linked.txt",
        "hardlink.txt",
        "metadata",
        "control",
        ".env.local",
        "auth.json",
        "private.pem",
      }) do
        assert(not listing:find(excluded, 1, true), "unsafe or ignored candidate: " .. excluded)
      end
      eq(vim.fn.bufnr(first), -1, "discovery does not load source contents")
      key("/second<CR>")
      assert(vim.api.nvim_get_current_line():find("src/second file.txt", 1, true))
      key("<Space>")
      choose("src/first.txt")
      key("<CR>")
      eq(select(2, result()), 0, "summary is not submission")
      eq(#vim.api.nvim_buf_get_lines(0, 0, -1, false), 2, "summary shows only selected files")
      local title = vim.inspect(vim.api.nvim_win_get_config(win).title)
      assert(title:find("2/16", 1, true) and title:find("12 B", 1, true), title)
      key("<CR>")
      local selected, calls = result()
      eq(selected, { first, second }, "canonical selection preserves paths with spaces")
      eq(calls, 1)
      eq(vim.api.nvim_get_current_win(), owner)
      eq(vim.api.nvim_win_is_valid(win), false)
      eq(vim.fn.bufnr(first), -1)
    end
  )

  scenario("summary can return to selection and deselect a file", function()
    local _, result = open()
    choose("src/first.txt")
    choose("src/second file.txt")
    key("<CR>")
    key("<BS>")
    choose("src/first.txt")
    key("<CR>")
    key("<CR>")
    eq(result(), { second })
  end)

  scenario("empty Enter and cancellation never implicitly pick the highlighted file", function()
    local _, result = open()
    key("<CR>")
    eq(select(2, result()), 0)
    assert(table.concat(notices):find("Select", 1, true))
    key("q")
    local selected, calls = result()
    eq(selected, nil)
    eq(calls, 1)
    cancel()
    eq(select(2, result()), 1, "cancellation is idempotent")
  end)

  scenario("file replacement during the summary cannot confirm a stale selection", function()
    local _, result = open()
    choose("src/first.txt")
    key("<CR>")
    file("src/first.txt", "changed size")
    key("<CR>")
    eq(select(2, result()), 0)
    assert(table.concat(notices):find("changed", 1, true))
    file("src/first.txt")
  end)

  scenario("combined byte and file-count limits apply when toggling", function()
    file("big-a.txt", string.rep("x", 600000))
    file("big-b.txt", string.rep("x", 600000))
    for i = 1, 17 do
      file("item-" .. i .. ".txt")
    end
    local _, result = open()
    choose("big-a.txt")
    choose("big-b.txt")
    key("<CR>")
    eq(#vim.api.nvim_buf_get_lines(0, 0, -1, false), 1)
    key("<BS>")
    choose("big-a.txt")
    for i = 1, 17 do
      choose("item-" .. i .. ".txt")
    end
    key("<CR>")
    eq(#vim.api.nvim_buf_get_lines(0, 0, -1, false), 16)
    key("<CR>")
    eq(#result(), 16)
  end)

  scenario("leaving or externally closing the picker cancels it", function()
    local win, result, owner = open()
    vim.api.nvim_set_current_win(owner)
    eq(select(2, result()), 1)
    eq(result(), nil)
    eq(vim.api.nvim_win_is_valid(win), false)
    win, result = open()
    vim.api.nvim_win_close(win, true)
    eq(select(2, result()), 1)
  end)

  scenario("cancelling asynchronous discovery does not reopen the window", function()
    local calls = 0
    local stop = picker.open(root, function(selected)
      eq(selected, nil)
      calls = calls + 1
    end)
    stop()
    vim.wait(100, function()
      return false
    end, 10)
    eq(calls, 1)
    eq(vim.bo.filetype == "nvim-ai-staged-picker", false)
  end)

  scenario("failed, truncated, timed-out or oversized discovery fails closed", function()
    for _, case in ipairs({
      { code = 2, data = "./src/first.txt\0" },
      { code = 124, data = "./src/first.txt\0" },
      { code = 0, data = "./src/first.txt" },
      { code = 0, data = string.rep("x", 2 * 1024 * 1024 + 1) },
      { code = 0, data = string.rep("./src/first.txt\0", 5001) },
    }) do
      vim.system = function(command, opts, callback)
        eq(vim.fs.basename(command[1]), "rg", "only local discovery may run")
        eq(opts.timeout, 3000, "discovery has a short deadline")
        opts.stdout(nil, case.data)
        callback({ code = case.code })
        return { kill = function() end }
      end
      local calls = 0
      cancel = picker.open(root, function(selected)
        eq(selected, nil, "never confirm a partial file list")
        calls = calls + 1
      end)
      assert(vim.wait(1000, function()
        return calls == 1
      end, 10))
      eq(vim.bo.filetype == "nvim-ai-staged-picker", false)
      cancel()
      eq(calls, 1)
    end
    vim.system = system
  end)

  scenario("resizing preserves selection and an unusably small window cancels", function()
    local win, result = open()
    choose("src/first.txt")
    local columns = vim.o.columns
    vim.o.columns = 70
    vim.api.nvim_exec_autocmds("VimResized", {})
    eq(vim.api.nvim_win_get_config(win).width, 66)
    key("<CR>")
    eq(#vim.api.nvim_buf_get_lines(0, 0, -1, false), 1)
    vim.o.columns = 40
    vim.api.nvim_exec_autocmds("VimResized", {})
    eq(result(), nil)
    eq(select(2, result()), 1)
    vim.o.columns = columns
  end)
end, debug.traceback)

if cancel then
  cancel()
end
vim.notify, vim.system = notify, system
vim.fn.delete(base, "rf")
if not ok then
  error(err)
end
print("ai_staged_picker: " .. count .. " scenarios passed")
