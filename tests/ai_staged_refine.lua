-- Public staged commands and real Bubblewrap/ACP fixture; no live provider.
local staged = require("ai.staged")
local base = assert(vim.uv.fs_mkdtemp("/tmp/nvim-ai-followup-ui-XXXXXX"))
local root, peer = base .. "/project", base .. "/opencode"
vim.fn.mkdir(root, "p", "0700")
local fixture = assert(vim.api.nvim_get_runtime_file("tests/fixtures/ai/staged_acp.py", false)[1])
vim.fn.writefile(vim.fn.readfile(fixture, "b"), peer, "b")
assert(vim.uv.fs_chmod(peer, 448))
local paths = { "first.txt", "second.txt" }
local source, proposals, count = {}, {}, 0
local input, system, select = vim.ui.input, vim.system, vim.ui.select
vim.o.swapfile, vim.o.undofile, vim.o.modeline, vim.o.autoread = false, false, false, true

local function eq(a, b, label)
  assert(
    vim.deep_equal(a, b),
    (label or "mismatch") .. ": " .. vim.inspect(a) .. " ~= " .. vim.inspect(b)
  )
end

local function disk(index)
  return table.concat(vim.fn.readfile(root .. "/" .. paths[index]), "\n") .. "\n"
end

local function key(lhs)
  local mapping = vim.fn.maparg(lhs, "n", false, true)
  assert(type(mapping.callback) == "function", "missing review key " .. lhs)
  mapping.callback()
end

local function done()
  assert(
    vim.wait(12000, function()
      local phase = staged.status().phase
      return phase ~= "preparing" and phase ~= "refining"
    end, 10),
    "follow-up timed out"
  )
  local state = staged.status()
  if state.proposal then
    proposals[vim.fs.dirname(state.proposal)] = true
  end
  return state
end

local function start(multi)
  if multi then
    vim.ui.input = function(_, callback)
      callback("TEST:multi")
    end
    vim.cmd("NvimAIStageFiles first.txt second.txt")
    vim.ui.input = input
  else
    vim.cmd("NvimAIStage TEST:approve")
  end
  local state = done()
  eq(state.phase, "review_ready", vim.inspect(state))
  return state
end

local function followup(case)
  vim.cmd("NvimAIStageFollowup TEST:" .. (case or "refine"))
  eq(staged.status().phase, "refining")
  local state = done()
  eq(state.phase, "review_ready", vim.inspect(state))
  return state
end

local function seed()
  staged.cancel()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf):sub(1, #base) == base then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  for index, path in ipairs(paths) do
    vim.fn.writefile({ index == 1 and "first original" or "second original" }, root .. "/" .. path)
    assert(vim.uv.fs_chmod(root .. "/" .. path, 420))
    source[index] = vim.fn.bufadd(root .. "/" .. path)
    vim.fn.bufload(source[index])
  end
  vim.api.nvim_set_current_buf(source[1])
  vim.cmd.cd(vim.fn.fnameescape(root))
  staged.setup({
    enabled = true,
    model = "fixture/model",
    opencode = peer,
    root = root,
    review_mode = "pre_write",
  })
end

local function scenario(name, run)
  seed()
  run()
  staged.cancel()
  done()
  vim.ui.input, vim.system, vim.ui.select = input, system, select
  count = count + 1
  print("ok - " .. name)
end

local ok, err = xpcall(function()
  scenario("f prompts then revises the frozen single-file proposal without publishing", function()
    local old = start()
    local answer
    vim.ui.input = function(opts, callback)
      assert(opts.prompt:find("1 pending", 1, true), opts.prompt)
      answer = callback
    end
    vim.api.nvim_feedkeys("f", "xt", false)
    eq(staged.status().phase, "review_ready")
    answer("TEST:refine-one")
    eq(staged.status().phase, "refining")
    key("a")
    eq(disk(1), "first original\n")
    local state = done()
    eq(state.phase, "review_ready", vim.inspect(state))
    assert(state.proposal ~= old.proposal)
    eq(state.previous_proposals, { old.proposal })
    local wins = vim.api.nvim_tabpage_list_wins(state.review_tab)
    eq(
      vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(wins[1]), 0, -1, false),
      { "first original" }
    )
    eq(
      vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(wins[2]), 0, -1, false),
      { "approved edit", "refined" }
    )
    key("a")
    eq(staged.status().phase, "applied")
    eq(disk(1), "approved edit\nrefined\n")
    eq(disk(2), "second original\n")
  end)

  scenario(
    "repeated follow-ups retain accepted files without resending or rewriting them",
    function()
      start(true)
      key("a")
      for _ = 1, 2 do
        local state = followup("refine-one")
        eq(state.files[1].state, "accepted")
        eq(state.files[2].state, "pending")
        eq(state.current_file, 2, "open the first pending diff, not retained context")
        eq(disk(1), "approved edit\n")
        eq(disk(2), "second original\n")
      end
      key("a")
      eq(staged.status().phase, "applied")
      eq(staged.status().results.applied, paths)
      eq(disk(1), "approved edit\n")
      eq(disk(2), "approved edit\nrefined\nrefined\n")
    end
  )

  scenario("rejected files stay rejected through follow-up and later rejection", function()
    start(true)
    key("r")
    key("]f")
    local state = followup("refine-one")
    eq(state.files[1].state, "rejected")
    key("r")
    eq(staged.status().phase, "rejected")
    eq(staged.status().results.rejected, paths)
    eq(disk(1), "first original\n")
    eq(disk(2), "second original\n")
  end)

  scenario("failed generation restores the previous review with no automatic retry", function()
    local old = start()
    vim.cmd("NvimAIStageFollowup TEST:bad-json")
    local state = done()
    eq(state.phase, "review_ready", vim.inspect(state))
    eq(state.proposal, old.proposal)
    eq(state.review_tab, old.review_tab)
    key("a")
    eq(disk(1), "approved edit\n")
  end)

  scenario("q during follow-up cancels pending work and preserves accepted writes", function()
    start(true)
    key("a")
    vim.cmd("NvimAIStageFollowup TEST:stall")
    key("q")
    eq(done().phase, "cancelled")
    eq(disk(1), "approved edit\n")
    eq(disk(2), "second original\n")
  end)

  scenario("closing the diff during follow-up cancels without reopening it", function()
    local old = start()
    vim.cmd("NvimAIStageFollowup TEST:stall")
    vim.cmd("tabclose")
    eq(done().phase, "cancelled")
    eq(vim.api.nvim_tabpage_is_valid(old.review_tab), false)
    eq(disk(1), "first original\n")
  end)

  scenario("source edits during generation cannot be overwritten by the new revision", function()
    start(true)
    vim.cmd("NvimAIStageFollowup TEST:refine")
    vim.api.nvim_buf_set_lines(source[2], 0, -1, false, { "unsaved second" })
    eq(done().phase, "conflicted")
    vim.cmd("NvimAIStageApprove")
    eq(vim.bo[source[2]].modified, true)
    eq(disk(1), "first original\n")
    eq(disk(2), "second original\n")
  end)

  scenario("cancelled, stale and overlong follow-up input never starts an agent", function()
    start(true)
    local answer, calls = nil, 0
    vim.ui.input = function(_, callback)
      answer = callback
    end
    vim.system = function(command, ...)
      if command[5] == "refine" then
        calls = calls + 1
      end
      return system(command, ...)
    end
    key("f")
    answer(nil)
    key("f")
    answer("   ")
    key("f")
    key("]f")
    answer("TEST:refine")
    key("f")
    answer(string.rep("x", 32769))
    key("f")
    key("r")
    answer("TEST:refine")
    eq(calls, 0)
    eq(disk(1), "first original\n")
    eq(disk(2), "second original\n")
  end)

  scenario("new revisions must be reviewed again before accepting remaining files", function()
    start(true)
    key("]f")
    local state = followup()
    eq(state.files[2].reviewed, false)
    vim.ui.select = function()
      error("unreviewed revision reached all-file confirmation")
    end
    key("A")
    eq(disk(1), "first original\n")
    eq(disk(2), "second original\n")
  end)

  scenario("missing handoff result never restores approval or retries automatically", function()
    start()
    vim.system = function(command, opts, callback)
      if command[5] == "refine" then
        vim.schedule(function()
          callback({ code = 1, stdout = "" })
        end)
        return { write = function() end }
      end
      return system(command, opts, callback)
    end
    vim.cmd("NvimAIStageFollowup TEST:refine")
    eq(done().phase, "blocked")
    vim.cmd("NvimAIStageApprove")
    eq(disk(1), "first original\n")
  end)

  scenario("a follow-up can remove all pending changes without writing the project", function()
    start(true)
    key("a")
    vim.cmd("NvimAIStageFollowup TEST:refine-revert")
    local state = done()
    eq(state.phase, "unchanged", vim.inspect(state))
    eq(state.files[1].state, "accepted")
    eq(state.files[2].state, "unchanged")
    eq(state.results.applied, { paths[1] })
    eq(disk(1), "approved edit\n")
    eq(disk(2), "second original\n")
  end)

  scenario("tampered hidden frozen panels block follow-up before agent launch", function()
    start(true)
    local buf = vim.api.nvim_get_current_buf()
    key("]f")
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "tampered proposal" })
    local calls = 0
    vim.system = function(command, ...)
      if command[5] == "refine" then
        calls = calls + 1
      end
      return system(command, ...)
    end
    vim.cmd("NvimAIStageFollowup TEST:refine")
    eq(calls, 0)
    eq(staged.status().phase, "conflicted")
    eq(disk(1), "first original\n")
    eq(disk(2), "second original\n")
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modified = false
      vim.api.nvim_buf_delete(buf, {})
    end
  end)

  scenario("rejecting a revised pending file preserves the earlier cumulative approval", function()
    start(true)
    key("a")
    followup("refine-one")
    key("r")
    local state = staged.status()
    eq(state.phase, "applied")
    eq(state.results.applied, { paths[1] })
    eq(state.results.rejected, { paths[2] })
    eq(disk(1), "approved edit\n")
    eq(disk(2), "second original\n")
  end)
end, debug.traceback)

vim.ui.input, vim.system, vim.ui.select = input, system, select
staged.cancel()
done()
for directory in pairs(proposals) do
  vim.fn.delete(directory, "rf")
end
vim.cmd.cd("/tmp")
vim.fn.delete(base, "rf")
if not ok then
  error(err)
end
print("ai_staged_refine: " .. count .. " scenarios passed")
