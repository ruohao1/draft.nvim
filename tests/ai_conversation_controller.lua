-- Actual Neovim owner/adapter/controller/ACP processes; a scripted local peer.
local factory = require("ai.conversation_controller")
local driver = require("ai.conversation_driver")
local original_driver, driver_options = driver.new, {}
driver.new = function(config)
  driver_options[#driver_options + 1] = vim.deepcopy(config)
  return original_driver(config)
end
local root = assert(vim.uv.fs_mkdtemp("/tmp/draft-conversation-ui-XXXXXX"))
local project, peer = root .. "/project", root .. "/opencode"
vim.fn.mkdir(project, "p", "0700")
local fixture =
  assert(vim.api.nvim_get_runtime_file("tests/fixtures/ai/conversation_acp.py", false)[1])
vim.fn.writefile(vim.fn.readfile(fixture, "b"), peer, "b")
assert(vim.uv.fs_chmod(peer, 448))
vim.fn.writefile({ "original text" }, project .. "/example.txt")
assert(vim.uv.fs_chmod(project .. "/example.txt", 420))
vim.o.swapfile, vim.o.undofile, vim.o.modeline, vim.o.autoread = false, false, false, true
vim.cmd.edit(vim.fn.fnameescape(project .. "/example.txt"))
local audit, clients, waiters, proposals = {}, {}, {}, {}
local original_system = vim.system
vim.system = function(command, ...)
  for index, item in ipairs(command) do
    if
      item == "--proposal"
      and command[index + 1]:match("^/tmp/nvim%-ai%-staged%-[^/]+/proposal%.json$")
    then
      proposals[vim.fs.dirname(command[index + 1])] = true
    end
  end
  return original_system(command, ...)
end
local server = assert(vim.uv.new_tcp())
assert(server:bind("127.0.0.1", 0))
assert(server:listen(64, function(error)
  assert(not error)
  local client, buffer = assert(vim.uv.new_tcp()), ""
  clients[#clients + 1] = client
  assert(server:accept(client))
  client:read_start(function(failed, data)
    assert(not failed)
    if data then
      buffer = buffer .. data
      if buffer:find("\n", 1, true) then
        local event = vim.json.decode(buffer)
        audit[#audit + 1] = event
        client:read_stop()
        if event.ready == "held-answer" or event.ready == "held-edit" then
          waiters[#waiters + 1] = client
        elseif not client:is_closing() then
          client:close()
        end
      end
    elseif not client:is_closing() then
      client:close()
    end
  end)
end))
local options = {
  root = project,
  selection = { "example.txt" },
  model = "fixture/model",
  opencode = peer,
  provider = {
    fixture = { options = { testCase = "answer", auditPort = server:getsockname().port } },
  },
}
local owners = {}
local function make(config)
  local owner = assert(factory.new(vim.tbl_extend("force", vim.deepcopy(options), config or {})))
  owners[#owners + 1] = owner
  return owner
end
local function act(owner, action)
  return owner:dispatch(action, owner:snapshot().view_revision)
end
local function wait_phase(owner, phase)
  assert(
    vim.wait(12000, function()
      return owner:snapshot().phase == phase
    end, 10),
    vim.inspect(owner:snapshot())
  )
end
local function release()
  for _, client in ipairs(waiters) do
    if not client:is_closing() then
      client:write("continue\n", function()
        if not client:is_closing() then
          client:close()
        end
      end)
    end
  end
  waiters = {}
end
local function held()
  assert(
    vim.wait(5000, function()
      return #waiters > 0
    end, 10),
    "Peer did not reach its readiness marker"
  )
end
local function reset()
  vim.fn.writefile({ "original text" }, project .. "/example.txt")
  local source = vim.fn.bufadd(project .. "/example.txt")
  vim.fn.bufload(source)
  vim.api.nvim_buf_call(source, function()
    vim.cmd("edit!")
  end)
  return source
end
local function editing(case, extra)
  return make(vim.tbl_extend("force", {
    provider = {
      fixture = {
        options = {
          testCase = case or "edit",
          auditPort = server:getsockname().port,
        },
      },
    },
  }, extra or {}))
end
local function decide(owner, path)
  local round = owner:snapshot().review
  return act(owner, {
    kind = "decide",
    choice = "approve",
    path = path or "example.txt",
    round_id = round.id,
    proposal_revision = round.revision,
    proposal_token = round.token,
  })
end
local function finish(owner)
  assert(act(owner, { kind = "close" }))
  wait_phase(owner, "closed")
end
local ok, reason = xpcall(function()
  local owner = make()
  assert(driver_options[1].timeout_ms == 270000 and driver_options[1].stop_timeout_ms == 10000)
  assert(owner:snapshot().phase == "idle")
  assert(#audit == 0, "Factory construction launched an ACP worker")
  assert(not act(owner, { kind = "revise", text = "No review exists." }))
  assert(act(owner, { kind = "submit", text = "First explicit question." }))
  wait_phase(owner, "idle")
  assert(act(owner, { kind = "submit", text = "Use the earlier context." }))
  wait_phase(owner, "idle")
  assert(#owner:snapshot().turns == 2)
  assert(owner:snapshot().turns[1].text == "A bounded answer.")
  local fresh, resumed = 0, 0
  for _, event in ipairs(audit) do
    fresh = fresh + (event.method == "session/new" and 1 or 0)
    resumed = resumed + (event.method == "session/resume" and 1 or 0)
  end
  assert(fresh == 1 and resumed == 1)
  assert(act(owner, { kind = "close" }))
  wait_phase(owner, "closed")
  print("ok - production owner submits, resumes and closes")

  local delayed = editing("held-answer", { timeout_ms = 2700, stop_timeout_ms = 1000 })
  assert(act(delayed, { kind = "submit", text = "Take an allowed long turn." }))
  held()
  -- Scale the production 270/120-second ordering: release after the former
  -- driver's 1200 ms budget, but before the factory's 2700 ms budget.
  local since = vim.uv.hrtime()
  vim.defer_fn(release, 1500)
  wait_phase(delayed, "idle")
  assert((vim.uv.hrtime() - since) / 1e6 >= 1500)
  finish(delayed)
  print("ok - factory deadlines allow a turn beyond the former driver budget")

  local shown
  local editing_owner = make({
    provider = {
      fixture = {
        options = {
          testCase = "edit",
          auditPort = server:getsockname().port,
        },
      },
    },
    on_review = function(view)
      shown = view
    end,
  })
  assert(act(editing_owner, { kind = "submit", text = "Propose an edit." }))
  wait_phase(editing_owner, "review")
  assert(shown and type(shown.show) == "function")
  assert(table.concat(vim.fn.readfile(project .. "/example.txt"), "\n") == "original text")
  local round = editing_owner:snapshot().review
  assert(act(editing_owner, {
    kind = "decide",
    choice = "approve",
    path = "example.txt",
    round_id = round.id,
    proposal_revision = round.revision,
    proposal_token = round.token,
  }))
  wait_phase(editing_owner, "idle")
  assert(table.concat(vim.fn.readfile(project .. "/example.txt"), "\n") == "proposed edit")
  assert(editing_owner:snapshot().rounds[1].files[1].state == "accepted")
  assert(act(editing_owner, { kind = "close" }))
  wait_phase(editing_owner, "closed")
  print("ok - production review uses guarded writer and authoritative receipt")

  reset()
  local revising = editing()
  assert(act(revising, { kind = "submit", text = "Propose an edit." }))
  wait_phase(revising, "review")
  local before = revising:snapshot().review
  assert(act(revising, {
    kind = "revise",
    text = "Revise the pending proposal.",
    round_id = before.id,
    proposal_revision = before.revision,
    proposal_token = before.token,
  }))
  wait_phase(revising, "review")
  local after = revising:snapshot().review
  assert(after.revision == 2 and after.token ~= before.token)
  assert(decide(revising))
  wait_phase(revising, "idle")
  assert(table.concat(vim.fn.readfile(project .. "/example.txt"), "\n") == "revised edit")
  finish(revising)
  print("ok - replacement review gets a fresh guarded handle")

  reset()
  local cancelled_view
  local cancelling = editing(nil, {
    on_review = function(view)
      cancelled_view = view
    end,
  })
  assert(act(cancelling, { kind = "submit", text = "Propose an edit." }))
  wait_phase(cancelling, "review")
  assert(act(cancelling, { kind = "cancel" }))
  wait_phase(cancelling, "idle")
  assert(not cancelled_view:show("example.txt"), "Confirmed cancel must retire the editor handle")
  finish(cancelling)
  print("ok - confirmed cancellation retires editor review eligibility")

  reset()
  local dirty = editing("held-edit")
  assert(act(dirty, { kind = "submit", text = "Propose an edit." }))
  held()
  local alias_path = root .. "/alias.txt"
  assert(vim.uv.fs_symlink(project .. "/example.txt", alias_path))
  local alias = vim.fn.bufadd(alias_path)
  vim.fn.bufload(alias)
  vim.api.nvim_buf_set_lines(alias, 0, -1, false, { "unsaved alias edit" })
  release()
  wait_phase(dirty, "failed")
  assert(table.concat(vim.fn.readfile(project .. "/example.txt"), "\n") == "original text")
  finish(dirty)
  assert(vim.api.nvim_buf_get_lines(alias, 0, -1, false)[1] == "unsaved alias edit")
  vim.api.nvim_buf_delete(alias, { force = true })
  vim.uv.fs_unlink(alias_path)
  print("ok - hidden alias drift fences frozen review and still permits proven close")

  reset()
  local changed_review = editing()
  assert(act(changed_review, { kind = "submit", text = "Propose an edit." }))
  wait_phase(changed_review, "review")
  assert(vim.uv.fs_symlink(project .. "/example.txt", alias_path))
  alias = vim.fn.bufadd(alias_path)
  vim.fn.bufload(alias)
  vim.api.nvim_buf_set_lines(alias, 0, -1, false, { "unsaved while reviewing" })
  assert(decide(changed_review))
  wait_phase(changed_review, "failed")
  assert(table.concat(vim.fn.readfile(project .. "/example.txt"), "\n") == "original text")
  finish(changed_review)
  assert(vim.api.nvim_buf_get_lines(alias, 0, -1, false)[1] == "unsaved while reviewing")
  vim.api.nvim_buf_delete(alias, { force = true })
  vim.uv.fs_unlink(alias_path)
  print("ok - hidden alias drift during review never reaches the writer")

  reset()
  local tampered = editing()
  assert(act(tampered, { kind = "submit", text = "Propose an edit." }))
  wait_phase(tampered, "review")
  local panel = vim.api.nvim_get_current_buf()
  vim.bo[panel].modifiable = true
  vim.api.nvim_buf_set_lines(panel, 0, -1, false, { "changed frozen panel" })
  vim.bo[panel].modified = false
  assert(decide(tampered))
  wait_phase(tampered, "failed")
  assert(table.concat(vim.fn.readfile(project .. "/example.txt"), "\n") == "original text")
  finish(tampered)
  print("ok - changed frozen panels never reach the writer")

  reset()
  vim.fn.writefile({ "original text" }, project .. "/second.txt")
  assert(vim.uv.fs_chmod(project .. "/second.txt", 420))
  local unvisited = editing(nil, { selection = { "example.txt", "second.txt" } })
  assert(act(unvisited, { kind = "submit", text = "Propose edits." }))
  wait_phase(unvisited, "review")
  assert(decide(unvisited, "second.txt"))
  wait_phase(unvisited, "failed")
  assert(table.concat(vim.fn.readfile(project .. "/second.txt"), "\n") == "original text")
  finish(unvisited)
  print("ok - unvisited approval is refused")

  local source = reset()
  local refreshing = editing(nil, { selection = { "example.txt", "second.txt" } })
  assert(act(refreshing, { kind = "submit", text = "Propose edits." }))
  wait_phase(refreshing, "review")
  local changed = vim.api.nvim_create_autocmd("FileChangedShellPost", {
    buffer = source,
    once = true,
    callback = function()
      vim.api.nvim_buf_set_lines(source, 0, -1, false, { "unsaved refresh edit" })
    end,
  })
  assert(decide(refreshing))
  wait_phase(refreshing, "failed")
  assert(refreshing:snapshot().rounds[1].files[1].state == "accepted")
  assert(table.concat(vim.fn.readfile(project .. "/example.txt"), "\n") == "proposed edit")
  assert(table.concat(vim.fn.readfile(project .. "/second.txt"), "\n") == "original text")
  finish(refreshing)
  assert(refreshing:snapshot().recovery_required)
  assert(vim.api.nvim_buf_get_lines(source, 0, -1, false)[1] == "unsaved refresh edit")
  pcall(vim.api.nvim_del_autocmd, changed)
  reset()
  print("ok - source refresh failure preserves real acceptance and blocks remaining writes")
end, debug.traceback)
release()
for _, owner in ipairs(owners) do
  if owner:snapshot().phase ~= "closed" then
    act(owner, { kind = "close" })
    vim.wait(12000, function()
      return owner:snapshot().phase == "closed"
    end, 10)
  end
end
for _, client in ipairs(clients) do
  if not client:is_closing() then
    client:close()
  end
end
server:close()
vim.system = original_system
driver.new = original_driver
if ok then
  for directory in pairs(proposals) do
    vim.fn.delete(directory, "rf")
  end
end
vim.fn.delete(root, "rf")
assert(ok, reason)
