-- Real semantic owners and editor buffers; only controller transport is synthetic.
local chat_module = require("ai.chat")
local conversation = require("ai.conversation")
local sources = require("ai.staged_sources")
vim.o.columns, vim.o.lines, vim.o.swapfile = 140, 42, false
local root = assert(vim.uv.fs_mkdtemp("/tmp/draft-chat-test-XXXXXX"))
local path = root .. "/example.txt"
vim.fn.writefile({ "original source" }, path)
vim.cmd.edit(vim.fn.fnameescape(path))
local source = vim.api.nvim_get_current_buf()
local instances, fail_create, pending = {}, false, {}
local select = vim.ui.select
vim.ui.select = function(items, _, callback)
  pending[#pending + 1] = { items = items, callback = callback }
end
local function last()
  return instances[#instances]
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
local function output()
  return table.concat(vim.api.nvim_buf_get_lines(buffer("draft-chat"), 0, -1, false), "\n")
end
local function choose(index, item)
  local choice = pending[index or #pending]
  choice.callback(choice.items[item or 2])
end
local chat = chat_module.new({
  configuration = function()
    return { root = root, model = "fixture/model" }
  end,
  create = function(config)
    if fail_create then
      return nil, "fixture construction refused"
    end
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
    local owner = assert(conversation.new({
      root = config.root,
      selection = config.selection,
      model = config.model,
      driver = driver,
    }))
    local dispatch = owner.dispatch
    function owner:dispatch(action, revision)
      if action.kind == "submit" or action.kind == "retry" then
        local captured, reason = sources.capture({ path }, root)
        if not captured then
          return nil, reason
        end
      end
      return dispatch(self, action, revision)
    end
    instances[#instances + 1] = { owner = owner, driver = driver, config = config }
    return owner
  end,
})
local function answer(text, proposal)
  local driver = last().driver
  assert(driver:emit({ kind = "submitted", model = "fixture/model" }))
  assert(driver:emit({ kind = "text", text = text }))
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
local function closed()
  assert(
    last().driver:emit({ kind = "closed", stopped = true, cleaned = true, tokens_retired = true })
  )
end
local ok, reason = xpcall(function()
  assert(chat:open({ path }))
  assert(#instances == 1 and #last().driver.requests == 0)
  assert(vim.deep_equal(last().config.selection, { "example.txt" }))
  compose("first question")
  assert(chat:send())
  assert(draft() == "")
  compose("second draft")
  assert(not chat:send())
  assert(draft() == "second draft" and #last().driver.requests == 1)
  assert(chat:hide())
  answer("first reply")
  assert(chat:open())
  assert(#last().driver.requests == 1 and draft() == "second draft")
  assert(output():find("first reply", 1, true))
  assert(not chat:open({ path }), "explicit paths cannot silently rebind an existing owner")
  assert(not chat:open(nil, true), "New requires confirmed close")
  assert(not chat:retry(), "Retry is never an ordinary second send")
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "dirty source" })
  assert(not chat:send())
  assert(draft() == "second draft" and #last().driver.requests == 1)
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "original source" })
  vim.bo[source].modified = false
  assert(chat:send())
  answer("second reply")
  assert(#last().driver.requests == 2)
  assert(last().owner:snapshot().turn_id == 2)
  print("ok - two explicit turns, hidden output and refused preflight preserve scope and draft")

  compose("keep this unsent text")
  assert(chat:close())
  assert(last().owner:snapshot().phase == "closing")
  assert(not chat:open(nil, true))
  closed()
  assert(chat:open())
  assert(output():find("second reply", 1, true) and output():find("closed", 1, true))
  assert(not vim.bo[buffer("draft-chat-input")].modifiable, "closed history must be read-only")
  assert(chat:open(nil, true))
  local stale_new = #pending
  chat:hide()
  chat:open()
  choose(stale_new)
  assert(#instances == 1, "hidden/reopened callbacks must be fenced")
  fail_create = true
  assert(chat:open(nil, true))
  choose()
  assert(#instances == 1 and draft() == "keep this unsent text")
  assert(output():find("second reply", 1, true))
  fail_create = false
  assert(chat:open(nil, true))
  choose()
  assert(#instances == 2 and draft() == "" and #last().driver.requests == 0)
  assert(vim.deep_equal(last().config.selection, { "example.txt" }))
  print(
    "ok - confirmed close retains history and New replaces it only after successful construction"
  )

  compose("edit it")
  assert(chat:send())
  answer("proposed edit", {
    token = "proposal-1",
    source_generation = 1,
    files = { { path = "example.txt", state = "pending" } },
  })
  assert(chat:close())
  local stale_close = #pending
  compose("edited while confirmation open")
  choose(stale_close)
  assert(last().owner:snapshot().phase == "review")
  assert(chat:cancel())
  local stale_cancel = #pending
  chat:hide()
  chat:open()
  choose(stale_cancel)
  assert(last().owner:snapshot().phase == "review")
  assert(chat:cancel())
  choose()
  assert(last().owner:snapshot().phase == "cancelling")
  assert(last().driver:emit({
    kind = "cancelled",
    stopped = true,
    graceful = true,
    store_valid = true,
    tokens_retired = true,
    cancel_confirmed = true,
    receipt = {
      round_id = 1,
      proposal_revision = 1,
      proposal_token = "proposal-1",
      sequence = 1,
      phase = "cancelled",
      cleanup_pending = {},
      decisions = { { path = "example.txt", state = "cancelled" } },
    },
  }))
  assert(last().owner:snapshot().phase == "idle")
  assert(draft() == "edited while confirmation open")
  print("ok - late review confirmations cannot discard after draft edits or hide/reopen")

  compose("try safely")
  assert(chat:send())
  assert(last().driver:emit({ kind = "stopping" }))
  assert(last().driver:emit({
    kind = "settled",
    outcome = "failed",
    submission = "not_submitted",
    stopped = true,
    graceful = true,
    store_valid = true,
    tokens_retired = true,
  }))
  assert(last().owner:snapshot().retry_safe)
  assert(chat:retry())
  assert(last().driver.requests[#last().driver.requests].command.message == "try safely")
  assert(chat:cancel())
  assert(last().driver:emit({
    kind = "cancelled",
    stopped = true,
    graceful = true,
    store_valid = true,
    tokens_retired = true,
    cancel_confirmed = true,
  }))
  local menu = vim.fn.maparg("g?", "n", false, true).callback
  assert(type(menu) == "function")
  menu()
  local stale_menu = #pending
  compose("do not send via stale menu")
  choose(stale_menu, 1)
  assert(last().owner:snapshot().phase == "idle" and draft() == "do not send via stale menu")
  menu()
  local disposed_menu = #pending
  assert(chat:close())
  closed()
  assert(chat:dispose())
  choose(disposed_menu, 1)
  assert(buffer("draft-chat") == nil and buffer("draft-chat-input") == nil)
  print("ok - safe Retry is explicit and stale menus preserve edited input")
end, debug.traceback)
vim.ui.select = select
chat:hide()
vim.fn.delete(root, "rf")
assert(ok, reason)
