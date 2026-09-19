-- Public Neovim commands + actual Python controller, Bubblewrap and ACP fixture.
local staged = require("ai.staged")
local root = assert(vim.uv.fs_mkdtemp("/tmp/nvim-ai-staged-ui-XXXXXX"))
local repo = assert(vim.api.nvim_get_runtime_file("tests/fixtures/ai/staged_acp.py", false)[1])
local peer, file = root .. "/opencode", root .. "/project/src/example.txt"
vim.fn.mkdir(root .. "/project/src", "p", "0700")
vim.fn.writefile(vim.fn.readfile(repo, "b"), peer, "b")
assert(vim.uv.fs_chmod(peer, 448))
vim.o.swapfile, vim.o.undofile, vim.o.modeline = false, false, false
vim.o.autoread = true
local source, proposals, count = nil, {}, 0

local function eq(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    (label or "mismatch") .. ": " .. vim.inspect(actual) .. " ~= " .. vim.inspect(expected)
  )
end

local function disk()
  return table.concat(vim.fn.readfile(file), "\n") .. "\n"
end

local function wait_done()
  assert(
    vim.wait(12000, function()
      return staged.status().phase ~= "preparing"
    end, 10),
    "staging timed out"
  )
  local status = staged.status()
  if status.proposal then
    proposals[vim.fs.dirname(status.proposal)] = true
  end
  return status
end

local function seed()
  if source and vim.api.nvim_buf_is_valid(source) then
    vim.api.nvim_buf_delete(source, { force = true })
  end
  vim.fn.writefile({ "original text" }, file)
  assert(vim.uv.fs_chmod(file, 420))
  vim.cmd.edit(vim.fn.fnameescape(file))
  source = vim.api.nvim_get_current_buf()
end

local function start(case)
  vim.cmd("NvimAIStage TEST:" .. (case or "approve"))
  local status = wait_done()
  eq(status.phase, "review_ready", "review must be shown")
  eq(disk(), "original text\n", "disk remains unchanged before approval")
  local wins = vim.api.nvim_tabpage_list_wins(status.review_tab)
  eq(#wins, 2)
  for _, win in ipairs(wins) do
    eq(vim.wo[win].diff, true)
    local buf = vim.api.nvim_win_get_buf(win)
    eq(vim.bo[buf].modifiable, false)
    eq(vim.bo[buf].buftype, "nofile")
  end
  eq(
    vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(wins[1]), 0, -1, false),
    { "original text" }
  )
  eq(
    vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(wins[2]), 0, -1, false),
    { "approved edit" }
  )
end

local function scenario(name, run)
  seed()
  run()
  count = count + 1
  print("ok - " .. name)
end

local ok, err = xpcall(function()
  eq(vim.fn.exists(":NvimAIStage"), 0, "require must remain passive")
  staged.setup({ enabled = false })
  eq(vim.fn.exists(":NvimAIStage"), 2, "disabled staging remains discoverable")
  vim.cmd("NvimAIStage TEST:approve")
  eq(staged.status().phase, "idle", "discoverability does not enable staging")
  staged.setup({
    enabled = true,
    model = "fixture/model",
    opencode = peer,
    root = root .. "/project",
  })

  scenario("approve publishes only after a visible native diff", function()
    start()
    vim.cmd("NvimAIStageApprove")
    eq(staged.status().phase, "applied")
    eq(disk(), "approved edit\n")
    eq(vim.bo[source].modified, false)
    vim.fn.writefile({ "later user edit" }, file)
    vim.cmd("NvimAIStageApprove")
    eq(disk(), "later user edit\n", "replayed approval cannot overwrite")
  end)

  scenario("reject discards frozen proposal", function()
    start()
    vim.cmd("NvimAIStageReject")
    eq(staged.status().phase, "rejected")
    eq(disk(), "original text\n")
  end)

  scenario("normal setup and interactive prompt use the same pre-write review", function()
    require("ai").setup()
    local input, select = vim.ui.input, vim.ui.select
    local config = {
      settings_directory = root .. "/settings",
      opencode = peer,
      root = root .. "/project",
    }
    staged.setup(config)
    local answers = { "fixture/model", "" }
    vim.ui.input = function(_, callback)
      callback(table.remove(answers, 1))
    end
    vim.ui.select = function(_, _, callback)
      callback("Save and enable")
    end
    vim.cmd("NvimAIStageSetup")
    eq(staged.status().settings.model, "fixture/model")
    staged.setup(config) -- Drop in-memory choices; the prompt must load the saved record.
    vim.ui.input = function(_, callback)
      callback("TEST:approve")
    end
    vim.ui.select = function()
      error("configuration must be blocked while a turn is live")
    end
    vim.cmd("NvimAIStage")
    eq(wait_done().phase, "review_ready")
    eq(disk(), "original text\n")
    vim.cmd("NvimAIStageSetup")
    vim.cmd("NvimAIStageReset")
    eq(staged.status().phase, "review_ready")
    vim.cmd("NvimAIStageReject")
    eq(disk(), "original text\n")
    vim.ui.input, vim.ui.select = input, select
  end)

  scenario(
    "normal prompt and shortcut use persisted pre-write routing without a native companion",
    function()
      local runtime = require("ai").setup()
      local input, select, native = vim.ui.input, vim.ui.select, runtime.native_prompt
      local native_calls = 0
      runtime.native_prompt = function()
        native_calls = native_calls + 1
        return nil, "unexpected native fallback"
      end
      local config = {
        enabled = true,
        model = "fixture/model",
        settings_directory = root .. "/routing-settings",
        opencode = peer,
        root = root .. "/project",
      }
      staged.setup(config)
      vim.ui.select = function(items, _, callback)
        eq(items[1], "Cancel")
        callback(items[2])
      end
      vim.cmd("NvimAIReviewMode pre_write")
      staged.setup(config) -- Explicit model/enabled options must not hide the saved mode.
      eq(staged.review_mode(), "pre_write")
      vim.ui.input = function(_, callback)
        callback("TEST:approve")
      end
      for turn = 1, 2 do
        if turn == 1 then
          vim.cmd("NvimAIPrompt")
        else
          seed()
          vim.api.nvim_feedkeys("\\ap", "xt", false)
        end
        eq(wait_done().phase, "review_ready")
        eq(disk(), "original text\n", "normal prompt cannot publish before approval")
        eq(runtime:show_status().settings.review_mode, "pre_write")
        vim.cmd("NvimAIReviewMode native")
        eq(staged.review_mode(), "pre_write", "pending proposals prevent changing mode")
        vim.cmd("NvimAIStageApprove")
        eq(staged.status().phase, "applied")
        eq(disk(), "approved edit\n")
      end
      eq(native_calls, 0, "neither entry point may fall back to native")
      vim.ui.input, vim.ui.select, runtime.native_prompt = input, select, native
    end
  )

  scenario(
    "pre-write ranges visual mappings and disabled staging never invoke native prompting",
    function()
      local runtime = require("ai").setup()
      local input, native = vim.ui.input, runtime.native_prompt
      local inputs, native_calls = 0, 0
      vim.ui.input = function()
        inputs = inputs + 1
      end
      runtime.native_prompt = function()
        native_calls = native_calls + 1
        return true
      end
      staged.setup({ enabled = true, model = "fixture/model", review_mode = "pre_write" })
      vim.cmd("1,1NvimAIPrompt")
      vim.fn.maparg("\\ap", "x", false, true).callback()
      staged.setup({ enabled = false, review_mode = "pre_write" })
      vim.cmd("NvimAIPrompt")
      eq(inputs, 0, "no selection is expanded into a file prompt")
      eq(native_calls, 0, "disabled staging is not a native fallback")
      eq(staged.busy(), false)
      eq(disk(), "original text\n")
      vim.ui.input, runtime.native_prompt = input, native
      staged.setup({
        enabled = true,
        model = "fixture/model",
        review_mode = "pre_write",
        opencode = peer,
        root = root .. "/project",
      })
    end
  )

  scenario("hidden dirty source blocks approval", function()
    start()
    vim.api.nvim_buf_set_lines(source, 0, -1, false, { "unsaved user edit" })
    vim.cmd("NvimAIStageApprove")
    eq(staged.status().phase, "conflicted")
    eq(vim.api.nvim_buf_get_lines(source, 0, -1, false), { "unsaved user edit" })
    eq(vim.bo[source].modified, true)
    eq(disk(), "original text\n")
  end)

  scenario("disk edit while diff is open blocks approval", function()
    start()
    vim.fn.writefile({ "external user edit" }, file)
    vim.cmd("NvimAIStageApprove")
    eq(staged.status().phase, "conflicted")
    eq(disk(), "external user edit\n")
  end)

  scenario("closing review tab cancels without writing", function()
    start()
    vim.cmd("tabclose")
    assert(vim.wait(2000, function()
      return staged.status().phase == "cancelled"
    end, 10))
    eq(disk(), "original text\n")
  end)

  scenario("cancelling a running agent returns without publishing", function()
    vim.cmd("NvimAIStage TEST:stall")
    eq(staged.status().phase, "preparing")
    vim.cmd("NvimAIStageCancel")
    eq(wait_done().phase, "blocked")
    eq(disk(), "original text\n")
  end)

  scenario("changing a diff scratch buffer invalidates approval", function()
    start()
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "not the reviewed proposal" })
    vim.cmd("NvimAIStageApprove")
    eq(staged.status().phase, "conflicted")
    eq(disk(), "original text\n")
    -- This modified nofile buffer is owned by the test; do not leave it behind.
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modified = false
    end
    if vim.api.nvim_get_current_tabpage() == staged.status().review_tab then
      vim.cmd("tabclose")
    end
  end)

  scenario("unchanged turn opens no diff", function()
    local tabs = #vim.api.nvim_list_tabpages()
    vim.cmd("NvimAIStage TEST:unchanged")
    eq(wait_done().phase, "unchanged")
    eq(#vim.api.nvim_list_tabpages(), tabs)
    eq(disk(), "original text\n")
  end)

  staged.setup({ enabled = false })
  eq(vim.fn.exists(":NvimAIStage"), 2)
end, debug.traceback)

staged.cancel()
for directory in pairs(proposals) do
  vim.fn.delete(directory, "rf")
end
vim.fn.delete(root, "rf")
if not ok then
  error(err)
end
print("ai_staged: " .. count .. " scenarios passed")
