-- Real owners and buffers; only the external controller and interactive choice are synthetic.
local root = assert(vim.uv.fs_mkdtemp("/tmp/draft-chat-model-XXXXXX"))
local path = root .. "/example.txt"
vim.fn.writefile({ "original source" }, path)
vim.o.columns, vim.o.lines, vim.o.swapfile = 140, 42, false
vim.cmd.edit(vim.fn.fnameescape(path))
local saved = { root = root, model = "fixture/model" }
local instances, pending, notices = {}, {}, {}
local select = vim.ui.select
vim.ui.select = function(items, options, callback)
  pending[#pending + 1] = { items = items, options = options, callback = callback }
end
local chat = require("ai.chat").new({
  configuration = function()
    return saved
  end,
  notify = function(message)
    notices[#notices + 1] = message
  end,
  create = function(config)
    local driver = { requests = {}, sequence = 0 }
    function driver:send(command, receive)
      self.requests[#self.requests + 1] = { command = command, receive = receive }
      return true
    end
    function driver:emit(event)
      self.sequence = self.sequence + 1
      local request = self.requests[#self.requests]
      return request.receive(vim.tbl_extend("force", event, {
        conversation_id = request.command.conversation_id,
        owner_generation = request.command.owner_generation,
        turn_id = request.command.turn_id,
        worker_generation = request.command.worker_generation,
        sequence = self.sequence,
      }))
    end
    local owner = assert(require("ai.conversation").new({
      root = config.root,
      selection = config.selection,
      model = config.model,
      driver = driver,
    }))
    instances[#instances + 1] = { owner = owner, driver = driver }
    return owner
  end,
})
local function current()
  return instances[#instances]
end
local function state()
  return current().owner:snapshot()
end
local function buffer(kind)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == kind then
      return buf
    end
  end
end
local function compose(text)
  vim.api.nvim_buf_set_lines(assert(buffer("draft-chat-input")), 0, -1, false, { text })
end
local function draft()
  return table.concat(vim.api.nvim_buf_get_lines(buffer("draft-chat-input"), 0, -1, false), "\n")
end
local function visible(text)
  assert(
    vim.wait(1000, function()
      local lines = vim.api.nvim_buf_get_lines(buffer("draft-chat"), 0, -1, false)
      return table.concat(lines, "\n"):find(text, 1, true) ~= nil
    end, 10),
    "Missing visible model information: " .. text
  )
end
local function choice(value)
  pending[#pending].callback(value)
end
local function submitted(models)
  local driver = current().driver
  local request = driver.requests[#driver.requests].command
  assert(driver:emit({ kind = "submitted", model = request.model, models = models }))
end
local function settled(proposal)
  local driver = current().driver
  assert(driver:emit({ kind = "stopping" }))
  assert(driver:emit({
    kind = "settled",
    outcome = proposal and "review" or "answer",
    stopped = true,
    graceful = true,
    store_valid = true,
    proposal = proposal,
  }))
end
local function close()
  assert(chat:close())
  assert(current().driver:emit({
    kind = "closed",
    stopped = true,
    cleaned = true,
    tokens_retired = true,
  }))
end
local ok, reason = xpcall(function()
  assert(type(chat.model) == "function", "chat exposes model selection")
  assert(not chat:model(), "no owner cannot offer a model")
  assert(chat:open({ path }))
  assert(not chat:model(), "initial configured model is not an advertised catalog")
  assert(#pending == 0 and #current().driver.requests == 0)
  visible("after")
  assert(chat:hide())
  local notifications = #notices
  assert(not chat:model())
  assert(
    #notices == notifications + 1 and notices[#notices]:find("after", 1, true),
    "hidden model refusal must visibly explain negotiation eligibility"
  )
  assert(#vim.api.nvim_list_wins() == 1 and #current().driver.requests == 0)
  assert(chat:open())
  compose("first explicit question")
  assert(chat:send())
  assert(not chat:model(), "starting is ineligible")
  vim.cmd("tabnew")
  local other_tab = vim.api.nvim_get_current_tabpage()
  notifications = #notices
  assert(not chat:model())
  assert(#notices == notifications + 1 and notices[#notices]:find("idle", 1, true))
  assert(vim.api.nvim_get_current_tabpage() == other_tab, "off-tab refusal cannot take focus")
  vim.cmd("tabclose")
  submitted({ "fixture/model", "fixture/second-model" })
  assert(not chat:model(), "generating is ineligible")
  settled()
  compose("keep this draft")
  assert(chat:model())
  assert(vim.deep_equal(pending[#pending].items, { "fixture/model", "fixture/second-model" }))
  assert(pending[#pending].options.format_item("fixture/model"):find("selected", 1, true))
  choice(nil)
  assert(state().desired_model == "fixture/model" and draft() == "keep this draft")
  assert(chat:model())
  choice("foreign/model")
  assert(state().desired_model == "fixture/model" and #current().driver.requests == 1)
  assert(chat:model())
  choice("fixture/second-model")
  assert(state().desired_model == "fixture/second-model" and draft() == "keep this draft")
  assert(state().turns[1].model == "fixture/model" and #current().driver.requests == 1)
  visible("next: fixture/second-model")
  visible("Assistant · fixture/model")
  assert(chat:hide() and chat:open())
  assert(state().desired_model == "fixture/second-model" and draft() == "keep this draft")
  assert(saved.model == "fixture/model", "local selection must leave the saved default intact")
  print("ok - advertised selection is passive and preserves draft, history and saved default")

  assert(chat:model())
  local hidden_choice = pending[#pending].callback
  assert(chat:hide())
  notifications = #notices
  hidden_choice("fixture/model")
  assert(
    #notices == notifications + 1 and notices[#notices]:find("expired", 1, true),
    "an expired choice after hiding must notify without reopening"
  )
  assert(#vim.api.nvim_list_wins() == 1 and state().desired_model == "fixture/second-model")
  assert(#current().driver.requests == 1 and draft() == "keep this draft")
  assert(chat:open())

  for _, invalidate in ipairs({
    function()
      compose("a changed draft")
    end,
    function()
      assert(chat:hide() and chat:open())
    end,
    function()
      vim.cmd("tabnew")
      vim.cmd("tabclose")
    end,
    function()
      assert(chat:actions())
    end,
  }) do
    assert(chat:model())
    local stale = pending[#pending].callback
    invalidate()
    stale("fixture/model")
    assert(state().desired_model == "fixture/second-model" and #current().driver.requests == 1)
  end
  assert(chat:actions())
  assert(vim.list_contains(pending[#pending].items, "Choose next-turn model"))
  choice("Choose next-turn model")
  assert(pending[#pending].options.prompt:find("conversation only", 1, true))
  choice(nil)
  print("ok - edited, hidden, departed and superseded dialogs cannot change the model")

  assert(chat:model())
  local stale_turn = pending[#pending].callback
  assert(chat:send())
  assert(current().driver.requests[2].command.model == "fixture/second-model")
  submitted({ "fixture/second-model" })
  settled()
  stale_turn("fixture/model")
  assert(state().desired_model == "fixture/second-model")
  assert(state().turns[1].model == "fixture/model")
  assert(state().turns[2].model == "fixture/second-model")
  assert(chat:model())
  assert(vim.deep_equal(pending[#pending].items, { "fixture/second-model" }))
  choice("fixture/model")
  assert(state().desired_model == "fixture/second-model" and #current().driver.requests == 2)
  print("ok - catalog replacement removes old choices and preserves each turn's model")

  assert(chat:model())
  local old_owner = pending[#pending].callback
  close()
  assert(not chat:model(), "closed history cannot change its model")
  assert(chat:open(nil, true))
  assert(#instances == 2 and state().desired_model == "fixture/model")
  old_owner("fixture/second-model")
  assert(state().desired_model == "fixture/model" and #current().driver.requests == 0)
  compose("a refused turn")
  assert(chat:send())
  assert(current().driver:emit({ kind = "stopping" }))
  assert(not chat:model(), "stopping is ineligible")
  assert(current().driver:emit({
    kind = "settled",
    outcome = "failed",
    stopped = true,
    graceful = false,
    store_valid = false,
    tokens_retired = true,
    submission = "not_submitted",
  }))
  assert(not chat:model(), "failed session requires explicit recovery")
  assert(state().recovery_required and #current().driver.requests == 1)
  close()
  assert(chat:open(nil, true))
  compose("make a proposal")
  assert(chat:send())
  submitted({ "fixture/model", "fixture/second-model" })
  settled({
    token = "fixed-proposal",
    source_generation = 1,
    files = { { path = "example.txt", state = "pending" } },
  })
  local review = state().review
  assert(not chat:model(), "pending approval cannot change its generation model")
  assert(vim.deep_equal(state().review, review))
  assert(state().desired_model == "fixture/model" and #current().driver.requests == 1)
  assert(chat:actions())
  assert(not vim.list_contains(pending[#pending].items, "Choose next-turn model"))
  local decision = {
    kind = "decide",
    choice = "reject",
    path = "example.txt",
    round_id = review.id,
    proposal_revision = review.revision,
    proposal_token = review.token,
  }
  assert(current().owner:dispatch(decision, state().view_revision))
  assert(not chat:model(), "publishing is ineligible")
  assert(current().driver:emit({
    kind = "decided",
    receipt = {
      round_id = review.id,
      proposal_revision = review.revision,
      proposal_token = review.token,
      sequence = 1,
      phase = "rejected",
      decisions = { { path = "example.txt", state = "rejected" } },
      cleanup_pending = {},
    },
  }))
  local retired = state().rounds[1]
  assert(state().phase == "idle" and retired.model == "fixture/model")
  assert(chat:model())
  choice("fixture/second-model")
  assert(state().desired_model == "fixture/second-model")
  assert(vim.deep_equal(state().rounds[1], retired), "selection cannot relabel a retired proposal")
  assert(not current().owner:dispatch(decision, state().view_revision))
  assert(#current().driver.requests == 2, "selection cannot revive retired approval")
  close()
  print(
    "ok - New restores the default; failed/review states refuse and retired proposals stay fixed"
  )
end, debug.traceback)
chat:hide()
vim.ui.select = select
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(reason .. "\n")
  vim.cmd("cquit 1")
end
vim.cmd("qa!")
