-- Public multi-file commands + real isolated controller/ACP fixture; no provider.
local staged = require("ai.staged")
local root = assert(vim.uv.fs_mkdtemp("/tmp/nvim-ai-staged-multi-ui-XXXXXX"))
local project = root .. "/project"
local relative = { "src/first.txt", "src/second file.txt" }
local files = vim.tbl_map(function(path)
  return project .. "/" .. path
end, relative)
local fixture = assert(vim.api.nvim_get_runtime_file("tests/fixtures/ai/staged_acp.py", false)[1])
local peer = root .. "/opencode"
vim.fn.mkdir(project .. "/src", "p", "0700")
vim.fn.writefile(vim.fn.readfile(fixture, "b"), peer, "b")
assert(vim.uv.fs_chmod(peer, 448))
vim.o.swapfile, vim.o.undofile, vim.o.modeline, vim.o.autoread = false, false, false, true
local input, select, system = vim.ui.input, vim.ui.select, vim.system
local proposals, sources, count = {}, {}, 0

local function eq(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    (label or "mismatch") .. ": " .. vim.inspect(actual) .. " ~= " .. vim.inspect(expected)
  )
end

local function disk(index)
  return table.concat(vim.fn.readfile(files[index]), "\n") .. "\n"
end

local function unchanged()
  eq(disk(1), "first original\n", "first real file")
  eq(disk(2), "second original\n", "second real file")
end

local function wait_done()
  assert(
    vim.wait(12000, function()
      return staged.status().phase ~= "preparing"
    end, 10),
    "multi-file staging timed out"
  )
  local status = staged.status()
  if status.proposal then
    proposals[vim.fs.dirname(status.proposal)] = true
  end
  return status
end

local function seed()
  staged.cancel()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):sub(1, #root) == root then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  for index, file in ipairs(files) do
    vim.fn.writefile({ index == 1 and "first original" or "second original" }, file)
    assert(vim.uv.fs_chmod(file, 420))
  end
  vim.cmd.edit(vim.fn.fnameescape(files[1]))
  sources = { vim.api.nvim_get_current_buf(), vim.fn.bufadd(files[2]) }
  vim.fn.bufload(sources[2])
  staged.setup({ enabled = true, model = "fixture/model", opencode = peer, root = project })
  vim.cmd.cd(vim.fn.fnameescape(project))
end

local function start(case, selected)
  vim.ui.input = function(_, callback)
    callback("TEST:" .. (case or "multi"))
  end
  -- Exercise user-command argument parsing, including escaped spaces.
  vim.cmd(
    "NvimAIStageFiles " .. table.concat(vim.tbl_map(vim.fn.fnameescape, selected or relative), " ")
  )
  vim.ui.input = input
  local status = wait_done()
  eq(status.phase, "review_ready", vim.inspect(status))
  unchanged()
  local wins = vim.api.nvim_tabpage_list_wins(status.review_tab)
  eq(#wins, 2, "one combined two-panel review tab")
  for _, win in ipairs(wins) do
    eq(vim.wo[win].diff, true)
    eq(vim.bo[vim.api.nvim_win_get_buf(win)].modifiable, false)
  end
  eq(status.files[1].path, relative[1])
  eq(status.files[2].path, relative[2])
  eq(status.files[1].reviewed, true)
  eq(status.files[2].reviewed, false)
  return wins
end

local function next_file()
  local mapping = vim.fn.maparg("]f", "n", false, true)
  assert(type(mapping.callback) == "function", "review navigation is buffer-local")
  mapping.callback()
  eq(staged.status().files[2].reviewed, true)
end

local function key(name)
  local mapping = vim.fn.maparg(name, "n", false, true)
  assert(type(mapping.callback) == "function", "review key is buffer-local: " .. name)
  mapping.callback()
end

local function decisions(first, second)
  local status = staged.status()
  eq({ status.files[1].state, status.files[2].state }, { first, second }, "per-file decisions")
end

local function shown(path, decision)
  local wins = vim.api.nvim_tabpage_list_wins(staged.status().review_tab)
  eq(#wins, 2, "both diff panels remain open")
  for _, win in ipairs(wins) do
    assert(
      vim.wo[win].winbar:find("[" .. (decision or "pending") .. "] " .. path .. " ·", 1, true),
      "both panels must show " .. path .. ": " .. vim.wo[win].winbar
    )
  end
end

local function extra_file(path, text)
  vim.fn.writefile({ text or "extra original" }, project .. "/" .. path)
  assert(vim.uv.fs_chmod(project .. "/" .. path, 420))
  return path
end

local function confirmation(action, answer)
  local called = false
  vim.ui.select = function(items, _, callback)
    called = true
    eq(items[1], "Cancel", "all-file actions default to cancellation")
    callback(answer == true and items[2] or answer)
  end
  action()
  assert(called, "remaining-file action must ask for explicit confirmation")
  vim.ui.select = select
end

local function scenario(name, run)
  seed()
  run()
  staged.cancel()
  vim.ui.input, vim.ui.select, vim.system = input, select, system
  count = count + 1
  print("ok - " .. name)
end

local function pick_files(selected)
  vim.cmd("NvimAIStageFiles")
  assert(
    vim.wait(5000, function()
      return vim.bo.filetype == "nvim-ai-staged-picker"
        and vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] ~= "Scanning files..."
    end, 10),
    "picker discovery timed out"
  )
  for _, path in ipairs(selected or relative) do
    local found = false
    for line, text in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if text:find(" " .. path .. "  (", 1, true) then
        vim.api.nvim_win_set_cursor(0, { line, 0 })
        key("<Tab>")
        found = true
        break
      end
    end
    assert(found, "missing selectable path: " .. path)
  end
  key("<CR>") -- Explicit selected-file summary, not an instruction yet.
  eq(vim.bo.filetype, "nvim-ai-staged-picker")
end

local ok, err = xpcall(function()
  scenario(
    "file picker reaches real staged review with exact paths and per-file approval",
    function()
      local instruction, requested, prepares = nil, nil, 0
      vim.ui.input = function(opts, callback)
        requested, instruction = opts, callback
      end
      vim.system = function(command, ...)
        if command[5] == "prepare" then
          prepares = prepares + 1
        end
        return system(command, ...)
      end
      pick_files()
      eq(prepares, 0, "selection and summary do not start the agent")
      eq(instruction, nil)
      eq(staged.busy(), true)
      eq(#vim.api.nvim_buf_get_lines(0, 0, -1, false), 2)
      key("<CR>")
      assert(requested.prompt:find("2 file(s), 31 B", 1, true), requested.prompt)
      eq(prepares, 0, "opening the instruction dialog is not submission")
      instruction("TEST:multi")
      local status = wait_done()
      eq(status.phase, "review_ready", vim.inspect(status))
      eq(prepares, 1)
      eq({ status.files[1].path, status.files[2].path }, relative)
      unchanged()
      key("a")
      eq(disk(1), "approved edit\n")
      eq(disk(2), "second original\n")
      shown(relative[2])
      key("r")
      decisions("accepted", "rejected")
    end
  )

  scenario("cancellation fences discovery and the later instruction callback", function()
    local instruction, prepares = nil, 0
    vim.ui.input = function(_, callback)
      instruction = callback
    end
    vim.system = function(command, ...)
      if command[5] == "prepare" then
        prepares = prepares + 1
      end
      return system(command, ...)
    end
    vim.cmd("NvimAIStageFiles")
    vim.cmd("NvimAIStageCancel")
    eq(staged.busy(), false)
    vim.wait(100, function()
      return false
    end, 10)
    eq(instruction, nil)
    eq(vim.bo.filetype == "nvim-ai-staged-picker", false)
    pick_files()
    key("<CR>")
    assert(instruction)
    vim.cmd("NvimAIStageCancel")
    instruction("TEST:multi")
    eq(prepares, 0)
    eq(staged.busy(), false)
    unchanged()
  end)

  scenario("dirty selected buffer is refused before requesting an instruction", function()
    vim.ui.input = function()
      error("dirty source reached instruction dialog")
    end
    pick_files()
    vim.api.nvim_buf_set_lines(sources[2], 0, -1, false, { "unsaved while selecting" })
    key("<CR>")
    eq(staged.busy(), false)
    eq(vim.bo.filetype == "nvim-ai-staged-picker", false)
    unchanged()
  end)

  scenario("picker root and filenames survive a cwd change outside a Git repository", function()
    vim.fn.mkdir(project .. "/zzz", "p")
    local extra = extra_file("zzz/context.txt")
    staged.setup({
      enabled = true,
      model = "fixture/model",
      opencode = peer,
      review_mode = "pre_write",
    })
    local instruction
    vim.ui.input = function(_, callback)
      instruction = callback
    end
    pick_files({ relative[1], extra })
    key("<CR>")
    vim.cmd.cd(vim.fn.fnameescape(root))
    instruction("TEST:multi")
    local status = wait_done()
    eq(status.phase, "review_ready", vim.inspect(status))
    eq({ status.files[1].path, status.files[2].path }, { relative[1], extra })
    unchanged()
    key("r")
    next_file()
    key("r")
  end)

  scenario("Space-leader picker mapping and setup invalidation work without plugins", function()
    local leader = vim.g.mapleader
    vim.g.mapleader = " "
    staged.setup({
      enabled = true,
      model = "fixture/model",
      opencode = peer,
      root = project,
      review_mode = "pre_write",
    })
    local mapping = vim.fn.maparg(" af", "n", false, true)
    assert(type(mapping.callback) == "function")
    vim.api.nvim_feedkeys(" af", "xt", false)
    eq(vim.bo.filetype, "nvim-ai-staged-picker")
    staged.setup({ enabled = false, review_mode = "pre_write" })
    eq(staged.busy(), false)
    eq(vim.bo.filetype == "nvim-ai-staged-picker", false)
    vim.cmd("NvimAIStageFiles")
    eq(staged.busy(), false)
    eq(vim.bo.filetype == "nvim-ai-staged-picker", false)
    vim.g.mapleader = leader
  end)

  scenario("accept current publishes only its file and opens the next pending diff", function()
    local wins = start()
    key("a")
    eq(staged.status().phase, "review_ready")
    decisions("accepted", "pending")
    eq(staged.status().files[2].reviewed, true)
    eq(disk(1), "approved edit\n")
    eq(disk(2), "second original\n")
    shown(relative[2])
    assert(vim.wo[wins[1]].statusline:find("1 pending", 1, true), "pending count is visible")
    key("[f")
    shown(relative[1], "accepted")
    local calls = 0
    vim.system = function(...)
      calls = calls + 1
      return system(...)
    end
    key("a")
    key("r")
    eq(calls, 0, "already-decided file never calls the writer again")
    vim.system = system
    next_file()
    vim.cmd("NvimAIStageApprove")
    eq(staged.status().phase, "applied")
    decisions("accepted", "accepted")
    eq(disk(1), "approved edit\n")
    eq(disk(2), "approved edit\n")
    for _, source in ipairs(sources) do
      eq(vim.bo[source].modified, false)
      eq(vim.api.nvim_buf_get_lines(source, 0, -1, false), { "approved edit" })
    end
  end)

  scenario("successive accept keystrokes advance and close the last pending diff", function()
    local wins = start()
    local review = staged.status().review_tab
    vim.api.nvim_set_current_win(wins[1])
    vim.api.nvim_feedkeys("a", "xt", false)
    decisions("accepted", "pending")
    shown(relative[2])
    eq(
      vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(wins[1]), 0, -1, false),
      { "second original" }
    )
    eq(
      vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(wins[2]), 0, -1, false),
      { "approved edit" }
    )
    eq(disk(2), "second original\n", "advancing is not approval")
    vim.api.nvim_set_current_win(wins[2])
    vim.api.nvim_feedkeys("a", "xt", false)
    eq(staged.status().phase, "applied")
    decisions("accepted", "accepted")
    eq(disk(1), "approved edit\n")
    eq(disk(2), "approved edit\n")
    eq(vim.api.nvim_tabpage_is_valid(review), false, "last acceptance closes review")
  end)

  scenario("accept advances past rejected unchanged and accepted files", function()
    local context = extra_file("src/context.txt", "approved edit")
    local fourth = extra_file("src/fourth.txt")
    local fifth = extra_file("src/fifth.txt")
    start(nil, { relative[1], relative[2], context, fourth, fifth })
    next_file()
    key("r")
    shown(relative[2], "rejected")
    staged.review(2)
    shown(fourth)
    key("a")
    shown(fifth)
    staged.review(1)
    shown(relative[1])
    key("a")
    shown(fifth)
    eq(
      vim.tbl_map(function(item)
        return item.state
      end, staged.status().files),
      { "accepted", "rejected", "unchanged", "accepted", "pending" }
    )
    eq(staged.status().files[3].reviewed, false, "skipped context is not marked as opened")
    eq(disk(2), "second original\n")
    eq(vim.fn.readfile(project .. "/" .. fifth), { "extra original" })
    key("a")
    eq(staged.status().phase, "applied")
    eq(vim.fn.readfile(project .. "/" .. fifth), { "approved edit" })
  end)

  scenario("accepting the last listed file wraps to an earlier pending diff", function()
    local third = extra_file("src/third.txt")
    start(nil, { relative[1], relative[2], third })
    next_file()
    vim.cmd("NvimAIStageApprove")
    shown(third)
    vim.cmd("NvimAIStageApprove")
    shown(relative[1])
    decisions("pending", "accepted")
    eq(disk(1), "first original\n")
    vim.cmd("NvimAIStageApprove")
    eq(staged.status().phase, "applied")
    eq(disk(1), "approved edit\n")
  end)

  scenario("accept then reject leaves the accepted edit and rejects only current", function()
    start()
    key("a")
    key("r")
    eq(staged.status().phase, "applied")
    decisions("accepted", "rejected")
    eq(staged.status().results.applied, { relative[1] })
    eq(staged.status().results.rejected, { relative[2] })
    eq(disk(1), "approved edit\n")
    eq(disk(2), "second original\n")
  end)

  scenario("reject then accept keeps the rejected file unchanged", function()
    start()
    vim.cmd("NvimAIStageReject")
    eq(staged.status().phase, "review_ready")
    decisions("rejected", "pending")
    unchanged()
    next_file()
    vim.cmd("NvimAIStageApprove")
    eq(staged.status().phase, "applied")
    decisions("rejected", "accepted")
    eq(disk(1), "first original\n")
    eq(disk(2), "approved edit\n")
  end)

  scenario("rejecting both current files preserves every real file", function()
    start()
    staged.cancel("reject") -- Legacy call now also means the current file only.
    eq(staged.status().phase, "review_ready")
    decisions("rejected", "pending")
    next_file()
    vim.cmd("NvimAIStageReject")
    eq(staged.status().phase, "rejected")
    decisions("rejected", "rejected")
    unchanged()
  end)

  scenario("accept remaining requires every pending diff plus explicit confirmation", function()
    start()
    vim.ui.select = function()
      error("unreviewed remaining file must block before confirmation")
    end
    vim.cmd("NvimAIStageApproveAll")
    eq(staged.status().phase, "review_ready")
    unchanged()
    next_file()
    confirmation(function()
      key("A")
    end, nil)
    eq(staged.status().phase, "review_ready")
    unchanged()
    confirmation(function()
      vim.cmd("NvimAIStageApproveAll")
    end, true)
    eq(staged.status().phase, "applied")
    decisions("accepted", "accepted")
    eq(disk(1), "approved edit\n")
    eq(disk(2), "approved edit\n")
  end)

  scenario("reject remaining confirms and does not undo accepted files", function()
    start()
    key("a")
    confirmation(function()
      key("R")
    end, "Cancel")
    decisions("accepted", "pending")
    confirmation(function()
      vim.cmd("NvimAIStageRejectAll")
    end, true)
    eq(staged.status().phase, "applied")
    decisions("accepted", "rejected")
    eq(disk(1), "approved edit\n")
    eq(disk(2), "second original\n")
  end)

  scenario("reject remaining can reject unvisited files but still needs confirmation", function()
    start()
    confirmation(function()
      vim.cmd("NvimAIStageRejectAll")
    end, true)
    eq(staged.status().phase, "rejected")
    decisions("rejected", "rejected")
    unchanged()
  end)

  scenario("reject remaining preserves source edits already present before confirmation", function()
    start()
    vim.api.nvim_buf_set_lines(sources[2], 0, -1, false, { "dirty before rejection" })
    confirmation(function()
      vim.cmd("NvimAIStageRejectAll")
    end, true)
    eq(staged.status().phase, "rejected")
    decisions("rejected", "rejected")
    eq(vim.bo[sources[2]].modified, true)
    eq(vim.api.nvim_buf_get_lines(sources[2], 0, -1, false), { "dirty before rejection" })
    unchanged()
  end)

  scenario("navigation away and back invalidates an outstanding all-file confirmation", function()
    start()
    next_file()
    local callback, answer
    vim.ui.select = function(items, _, done)
      callback, answer = done, items[2]
    end
    vim.cmd("NvimAIStageApproveAll")
    key("[f")
    key("]f")
    callback(answer)
    eq(staged.status().phase, "review_ready")
    decisions("pending", "pending")
    unchanged()
  end)

  scenario("source changes invalidate an outstanding confirmation without publishing", function()
    start()
    next_file()
    local callback, answer
    vim.ui.select = function(items, _, done)
      callback, answer = done, items[2]
    end
    vim.cmd("NvimAIStageApproveAll")
    vim.api.nvim_buf_set_lines(sources[1], 0, -1, false, { "changed during confirmation" })
    callback(answer)
    eq(staged.status().phase, "review_ready")
    decisions("pending", "pending")
    unchanged()
  end)

  scenario("a later decision invalidates an outstanding all-file confirmation", function()
    start()
    next_file()
    local callback, answer
    vim.ui.select = function(items, _, done)
      callback, answer = done, items[2]
    end
    vim.cmd("NvimAIStageApproveAll")
    key("r")
    callback(answer)
    eq(staged.status().phase, "review_ready")
    decisions("pending", "rejected")
    unchanged()
  end)

  scenario("a second confirmation replaces the first token", function()
    start()
    next_file()
    local callbacks, answers = {}, {}
    vim.ui.select = function(items, _, done)
      callbacks[#callbacks + 1], answers[#answers + 1] = done, items[2]
    end
    vim.cmd("NvimAIStageApproveAll")
    vim.cmd("NvimAIStageRejectAll")
    callbacks[1](answers[1])
    decisions("pending", "pending")
    unchanged()
    callbacks[2]("Cancel")
  end)

  scenario("cancel pending after accepting one file never rolls it back", function()
    start()
    key("a")
    key("q")
    eq(staged.status().phase, "cancelled")
    decisions("accepted", "cancelled")
    eq(staged.status().results.applied, { relative[1] })
    eq(disk(1), "approved edit\n")
    eq(disk(2), "second original\n")
  end)

  scenario("closing review after acceptance cancels only pending files", function()
    start()
    key("a")
    vim.cmd("tabclose")
    assert(vim.wait(2000, function()
      return staged.status().phase == "cancelled"
    end, 10))
    decisions("accepted", "cancelled")
    eq(disk(1), "approved edit\n")
    eq(disk(2), "second original\n")
  end)

  scenario("accepted source edits are not silently blessed for the next approval", function()
    start()
    key("a")
    vim.api.nvim_buf_set_lines(sources[1], 0, -1, false, { "unsaved accepted source" })
    key("a")
    eq(staged.status().phase, "conflicted")
    decisions("accepted", "cancelled")
    eq(vim.bo[sources[1]].modified, true)
    eq(disk(1), "approved edit\n")
    eq(disk(2), "second original\n")
  end)

  scenario("checktime autocommand edits are preserved and retire pending approvals", function()
    start()
    local called = false
    local event = vim.api.nvim_create_autocmd("FileChangedShellPost", {
      pattern = files[1],
      once = true,
      callback = function()
        called = true
        vim.api.nvim_buf_set_lines(sources[2], 0, -1, false, { "autocommand user edit" })
      end,
    })
    key("a")
    pcall(vim.api.nvim_del_autocmd, event)
    assert(called, "normal checktime must invoke external-change handling")
    eq(staged.status().phase, "conflicted")
    decisions("accepted", "cancelled")
    eq(staged.status().files[2].reviewed, false, "unsafe refresh must not advance the review")
    eq(vim.bo[sources[2]].modified, true)
    eq(vim.api.nvim_buf_get_lines(sources[2], 0, -1, false), { "autocommand user edit" })
    eq(disk(1), "approved edit\n")
    eq(disk(2), "second original\n")
  end)

  for _, reply in ipairs({
    "missing",
    "malformed continuation",
    "malformed terminal",
    "unknown phase",
    "throwing helper",
  }) do
    scenario(
      reply .. " after acceptance preserves confirmed writes and marks the next target uncertain",
      function()
        start()
        key("a")
        local calls = 0
        vim.system = function(command, ...)
          if command[5] ~= "approve" then
            return system(command, ...)
          end
          calls = calls + 1
          if reply == "throwing helper" then
            error("injected process-launch/wait failure")
          end
          return {
            wait = function()
              return {
                code = 0,
                stdout = reply == "missing" and ""
                  or vim.json.encode({
                    phase = reply == "unknown phase" and "unexpected"
                      or (reply == "malformed continuation" and "review_ready" or "applied"),
                    decisions = {},
                  }),
              }
            end,
          }
        end
        key("a")
        local status = staged.status()
        eq(status.phase, "uncertain")
        decisions("accepted", "uncertain")
        eq(status.results.applied, { relative[1] })
        eq(status.results.uncertain, { relative[2] })
        eq(status.results.pending, {})
        assert(
          status.reason:find(status.proposal, 1, true),
          "unknown outcomes retain an inspection path"
        )
        staged.approve()
        eq(calls, 1, "unknown outcome cannot be retried")
        vim.system = system
        eq(disk(1), "approved edit\n")
        eq(disk(2), "second original\n") -- The injected missing reply cannot prove this to the UI.
      end
    )
  end

  scenario("second-file disk conflict publishes neither file", function()
    start()
    next_file()
    vim.fn.writefile({ "external second" }, files[2])
    vim.cmd("NvimAIStageApprove")
    eq(staged.status().phase, "conflicted")
    eq(disk(1), "first original\n")
    eq(disk(2), "external second\n")
  end)

  scenario("unchanged selected context is still checked on disk", function()
    start("multi-one")
    eq(staged.status().files[2].changed, false)
    vim.fn.writefile({ "external unchanged context" }, files[2])
    vim.cmd("NvimAIStageApprove")
    eq(staged.status().phase, "conflicted")
    eq(disk(1), "first original\n")
    eq(disk(2), "external unchanged context\n")
  end)

  scenario("unchanged context needs no visit but remains selected", function()
    start("multi-one")
    vim.cmd("NvimAIStageApprove")
    eq(staged.status().phase, "applied")
    eq(disk(1), "approved edit\n")
    eq(disk(2), "second original\n")
  end)

  scenario("hidden dirty selected source blocks the whole batch", function()
    start()
    next_file()
    vim.api.nvim_buf_set_lines(sources[2], 0, -1, false, { "unsaved second" })
    vim.cmd("NvimAIStageApprove")
    eq(staged.status().phase, "conflicted")
    eq(vim.bo[sources[2]].modified, true)
    unchanged()
  end)

  scenario("tampered hidden diff panels invalidate current-file approval", function()
    local wins = start()
    local panel = vim.api.nvim_win_get_buf(wins[1])
    next_file()
    vim.bo[panel].modifiable = true
    vim.api.nvim_buf_set_lines(panel, 0, -1, false, { "tampered hidden snapshot" })
    vim.cmd("NvimAIStageApprove")
    eq(staged.status().phase, "conflicted")
    unchanged()
    if vim.api.nvim_buf_is_valid(panel) then
      vim.bo[panel].modified = false
      vim.api.nvim_buf_delete(panel, {})
    end
  end)

  scenario("selection is frozen before the asynchronous prompt", function()
    local callback
    vim.ui.input = function(_, answer)
      callback = answer
    end
    vim.cmd(
      "NvimAIStageFiles "
        .. vim.fn.fnameescape(relative[1])
        .. " "
        .. vim.fn.fnameescape(relative[2])
    )
    local before = staged.status().phase
    vim.api.nvim_buf_set_lines(sources[2], 0, -1, false, { "prompt-time change" })
    callback("TEST:multi")
    eq(staged.status().phase, before, "no agent started after source changed")
    unchanged()
  end)

  scenario("changing cwd during prompt does not change the selected paths", function()
    local callback
    vim.ui.input = function(_, answer)
      callback = answer
    end
    vim.cmd(
      "NvimAIStageFiles "
        .. vim.fn.fnameescape(relative[1])
        .. " "
        .. vim.fn.fnameescape(relative[2])
    )
    vim.cmd.cd(vim.fn.fnameescape(root))
    callback("TEST:multi")
    eq(wait_done().phase, "review_ready")
    next_file()
    vim.cmd("NvimAIStageReject")
    unchanged()
  end)

  scenario("invalid explicit selections never reach the instruction dialog", function()
    vim.ui.input = function()
      error("invalid selection reached instruction dialog")
    end
    local prior = staged.status().phase
    staged.prompt({ files[1], files[1] })
    staged.prompt({ files[1], project .. "/missing.txt" })
    local outside = root .. "/outside.txt"
    vim.fn.writefile({ "outside" }, outside)
    staged.prompt({ files[1], outside })
    local too_many = {}
    for _ = 1, 17 do
      too_many[#too_many + 1] = files[1]
    end
    staged.prompt(too_many)
    vim.api.nvim_buf_set_lines(sources[2], 0, -1, false, { "dirty selection" })
    staged.prompt(files)
    eq(staged.status().phase, prior)
    unchanged()
  end)

  scenario("review picker can return to the combined review tab", function()
    start()
    local review = staged.status().review_tab
    vim.cmd("tabprevious")
    vim.ui.select = function(items, _, callback)
      callback(items[2], 2)
    end
    vim.cmd("NvimAIStageReview")
    eq(vim.api.nvim_get_current_tabpage(), review)
    eq(staged.status().files[2].reviewed, true)
    vim.cmd("NvimAIStageReject")
    unchanged()
  end)

  scenario("deleting a hidden frozen panel cancels the whole review", function()
    local wins = start()
    local panel = vim.api.nvim_win_get_buf(wins[1])
    next_file()
    vim.api.nvim_buf_delete(panel, {})
    assert(vim.wait(2000, function()
      return staged.status().phase == "cancelled"
    end, 10))
    unchanged()
  end)

  scenario("single explicit file uses the multi-file command safely", function()
    vim.ui.input = function(_, callback)
      callback("TEST:multi")
    end
    vim.cmd("NvimAIStageFiles " .. vim.fn.fnameescape(relative[1]))
    eq(wait_done().phase, "review_ready")
    eq(#staged.status().files, 1)
    vim.cmd("NvimAIStageApprove")
    eq(staged.status().phase, "applied")
    eq(disk(1), "approved edit\n")
    eq(disk(2), "second original\n", "unselected file is not published")
  end)

  scenario("partial writer outcome retains per-path evidence without retry", function()
    start()
    next_file()
    local calls = 0
    vim.system = function(command, ...)
      if command[5] ~= "approve" then
        return system(command, ...)
      end
      calls = calls + 1
      return {
        wait = function()
          return {
            code = 0,
            stdout = vim.json.encode({
              phase = "partial",
              reason = "injected writer interruption",
              applied = { relative[1] },
              uncertain = { relative[2] },
              not_attempted = {},
              unchanged = {},
              cleanup_pending = { relative[2] },
              decisions = {
                { path = relative[1], state = "accepted" },
                { path = relative[2], state = "uncertain" },
              },
            }),
          }
        end,
      }
    end
    confirmation(function()
      vim.cmd("NvimAIStageApproveAll")
    end, true)
    vim.system = system
    local status = staged.status()
    eq(status.phase, "partial")
    eq(status.results.applied, { relative[1] })
    eq(status.results.uncertain, { relative[2] })
    eq(status.results.unchanged, {})
    eq(status.results.cleanup_pending, { relative[2] })
    assert(status.reason:find("inspect", 1, true))
    assert(status.reason:find(status.proposal, 1, true))
    assert(status.reason:find("temporary files may remain", 1, true))
    vim.cmd("NvimAIStageApprove")
    eq(calls, 1, "no automatic or replayed retry")
    unchanged() -- This case injects the local writer response, not publication.
  end)
end, debug.traceback)

vim.ui.input, vim.ui.select, vim.system = input, select, system
staged.cancel()
for directory in pairs(proposals) do
  vim.fn.delete(directory, "rf")
end
vim.cmd.cd("/tmp")
vim.fn.delete(root, "rf")
if not ok then
  error(err)
end
print("ai_staged_multi: " .. count .. " scenarios passed")
