-- Public conversation interface with a deterministic trusted-driver fixture.
-- No process, credentials, project writes, native session or installed config.
local conversation = require("ai.conversation")
local count = 0
local function eq(actual, expected)
  if not vim.deep_equal(actual, expected) then
    error(vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
  end
end
local function scenario(name, run)
  run()
  count = count + 1
  print("ok - " .. name)
end
local function fixture()
  local driver = { requests = {}, sequence = 0 }
  function driver:send(command, receive)
    self.requests[#self.requests + 1] = { command = vim.deepcopy(command), receive = receive }
    return true
  end
  function driver:emit(index, event, overrides)
    local request = assert(self.requests[index])
    self.sequence = self.sequence + 1
    local envelope = vim.tbl_extend("force", vim.deepcopy(event), {
      conversation_id = request.command.conversation_id,
      owner_generation = request.command.owner_generation,
      turn_id = request.command.turn_id,
      worker_generation = request.command.worker_generation,
      sequence = self.sequence,
    }, overrides or {})
    return request.receive(envelope)
  end
  local options = {
    root = "/tmp/conversation-fixture",
    selection = { "first.txt", "second.txt" },
    model = "fixture/model",
    driver = driver,
  }
  return assert(conversation.new(options)), driver, options
end
local function act(owner, action)
  return owner:dispatch(action, owner:snapshot().view_revision)
end

scenario("bounded progress is display-only and unknown fields fail closed", function()
  local owner, driver = fixture()
  assert(act(owner, { kind = "submit", text = "read the selected file" }))
  assert(driver:emit(1, { kind = "submitted", model = "fixture/model" }))
  assert(
    driver:emit(
      1,
      { kind = "progress", tool_id = "read-1", title = "Read file", status = "completed" }
    )
  )
  eq(owner:snapshot().phase, "generating")
  eq(
    owner:snapshot().turns[1].progress,
    { tool_id = "read-1", title = "Read file", status = "completed" }
  )
  driver:emit(1, {
    kind = "progress",
    tool_id = "read-1",
    title = "Read file",
    status = "completed",
    path = "secret",
  })
  eq(owner:snapshot().recovery_required, true)
end)

scenario("progress fields have closed byte and status bounds", function()
  for _, change in ipairs({
    { title = string.rep("x", 257) },
    { tool_id = "" },
    { status = "approved" },
  }) do
    local owner, driver = fixture()
    assert(act(owner, { kind = "submit", text = "read" }))
    assert(driver:emit(1, { kind = "submitted", model = "fixture/model" }))
    driver:emit(
      1,
      vim.tbl_extend(
        "force",
        { kind = "progress", tool_id = "id", title = "Read", status = "pending" },
        change
      )
    )
    eq(owner:snapshot().recovery_required, true)
  end
end)

scenario("construction and observation are passive and detached", function()
  local owner, driver, options = fixture()
  local view = owner:snapshot()
  eq(view.phase, "idle")
  eq(view.turn_id, 0)
  eq(view.desired_model, "fixture/model")
  eq(view.confirmed_model, nil)
  eq(view.turns, {})
  local observed = 0
  local unsubscribe = assert(owner:subscribe(function()
    observed = observed + 1
  end))
  options.selection[1] = "changed.txt"
  view.selection[2] = "changed.txt"
  view.turns[1] = { prompt = "not a submission" }
  eq(owner:snapshot().selection, { "first.txt", "second.txt" })
  eq(owner:snapshot().turns, {})
  eq(observed, 0)
  unsubscribe()
  unsubscribe()
  eq(#driver.requests, 0)
end)

scenario("only explicit submissions start sequential turns and retain answers", function()
  local owner, driver = fixture()
  local original = owner:snapshot()
  assert(act(owner, { kind = "submit", text = "first question" }))
  eq(owner:snapshot().phase, "starting")
  eq(owner:snapshot().turns[1].submission, "possibly_submitted")
  eq(#driver.requests, 1)
  local command = driver.requests[1].command
  eq(command.kind, "start")
  eq(command.message, "first question")
  eq(command.model, "fixture/model")
  eq(command.selection, { "first.txt", "second.txt" })
  assert(not owner:dispatch({ kind = "submit", text = "stale" }, original.view_revision))
  assert(not act(owner, { kind = "submit", text = "overlap" }))
  assert(driver:emit(1, { kind = "submitted", model = "fixture/model" }))
  eq(owner:snapshot().phase, "generating")
  assert(driver:emit(1, { kind = "text", text = "first answer" }))
  assert(driver:emit(1, { kind = "stopping" }))
  eq(owner:snapshot().phase, "stopping")
  assert(not act(owner, { kind = "submit", text = "too soon" }))
  assert(
    driver:emit(
      1,
      { kind = "settled", outcome = "answer", stopped = true, graceful = true, store_valid = true }
    )
  )
  eq(owner:snapshot().phase, "idle")
  eq(owner:snapshot().turns[1].text, "first answer")
  eq(owner:snapshot().turns[1].status, "completed")
  eq(owner:snapshot().turns[1].model, "fixture/model")
  assert(act(owner, { kind = "submit", text = "second question" }))
  eq(#driver.requests, 2)
  eq(driver.requests[2].command.conversation_id, command.conversation_id)
  eq(driver.requests[2].command.turn_id, 2)
  eq(driver.requests[2].command.worker_generation, 2)
  eq(owner:snapshot().turns[1].text, "first answer")
end)

scenario(
  "cancel fences late completion and only proven cancellation permits another turn",
  function()
    for _, submitted in ipairs({ false, true }) do
      local owner, driver = fixture()
      assert(act(owner, { kind = "submit", text = "cancel this" }))
      if submitted then
        assert(driver:emit(1, { kind = "submitted", model = "fixture/model" }))
      end
      assert(act(owner, { kind = "cancel" }))
      eq(owner:snapshot().phase, "cancelling")
      eq(driver.requests[2].command.kind, "cancel")
      assert(not act(owner, { kind = "cancel" }))
      assert(not driver:emit(1, {
        kind = "settled",
        outcome = "answer",
        stopped = true,
        graceful = true,
        store_valid = true,
      }, { sequence = 10000 }))
      eq(owner:snapshot().phase, "cancelling")
      assert(driver:emit(2, {
        kind = "cancelled",
        stopped = true,
        graceful = true,
        store_valid = true,
        tokens_retired = true,
        cancel_confirmed = true,
      }))
      eq(owner:snapshot().phase, "idle")
      eq(owner:snapshot().turns[1].status, "cancelled")
      assert(act(owner, { kind = "submit", text = "new explicit question" }))
      eq(owner:snapshot().turn_id, 2)
      eq(#driver.requests, 3)
    end
  end
)

scenario("close remains pending until cleanup is proved and never reopens", function()
  for _, phase in ipairs({ "idle", "starting", "generating", "stopping", "cancelling" }) do
    local owner, driver = fixture()
    if phase ~= "idle" then
      assert(act(owner, { kind = "submit", text = "work" }))
    end
    if phase == "generating" or phase == "stopping" then
      assert(driver:emit(1, { kind = "submitted", model = "fixture/model" }))
    end
    if phase == "stopping" then
      assert(driver:emit(1, { kind = "stopping" }))
    end
    if phase == "cancelling" then
      assert(act(owner, { kind = "cancel" }))
    end
    eq(owner:snapshot().phase, phase)
    assert(act(owner, { kind = "close" }))
    eq(owner:snapshot().phase, "closing")
    local closing = #driver.requests
    eq(driver.requests[closing].command.kind, "close")
    assert(not act(owner, { kind = "close" }))
    for index = 1, closing - 1 do
      assert(not driver:emit(index, {
        kind = "settled",
        outcome = "answer",
        stopped = true,
        graceful = true,
        store_valid = true,
      }))
    end
    eq(owner:snapshot().phase, "closing")
    assert(
      driver:emit(
        closing,
        { kind = "closed", stopped = true, cleaned = true, tokens_retired = true }
      )
    )
    eq(owner:snapshot().phase, "closed")
    assert(not act(owner, { kind = "submit", text = "resurrect" }))
    assert(not act(owner, { kind = "retry", text = "resurrect" }))
    assert(
      not driver:emit(
        closing,
        { kind = "closed", stopped = true, cleaned = true, tokens_retired = true }
      )
    )
    eq(owner:snapshot().phase, "closed")
    eq(#driver.requests, closing)
  end
end)

scenario(
  "missing or contradictory lifecycle proof requires recovery, never approval or retry",
  function()
    for _, case in ipairs({
      "not-submitted",
      "not-stopping",
      "no-exit",
      "forced",
      "store",
      "cancel-confirmation",
      "retirement",
      "cleanup",
      "unexpected-review",
      "answer-retirement",
      "answer-submission",
    }) do
      local owner, driver = fixture()
      assert(act(owner, { kind = "submit", text = "work" }))
      if case ~= "not-submitted" then
        assert(driver:emit(1, { kind = "submitted", model = "fixture/model" }))
      end
      local index, event =
        1, {
          kind = "settled",
          outcome = "answer",
          stopped = true,
          graceful = true,
          store_valid = true,
        }
      if case == "cancel-confirmation" or case == "retirement" then
        assert(act(owner, { kind = "cancel" }))
        index, event =
          2, {
            kind = "cancelled",
            stopped = true,
            graceful = true,
            store_valid = true,
            tokens_retired = case ~= "retirement",
            cancel_confirmed = case ~= "cancel-confirmation",
          }
      elseif case == "cleanup" then
        assert(act(owner, { kind = "close" }))
        index, event =
          2, { kind = "closed", stopped = true, cleaned = false, tokens_retired = true }
      else
        if case ~= "not-stopping" then
          assert(driver:emit(1, { kind = "stopping" }))
        end
        if case == "no-exit" then
          event.stopped = false
        end
        if case == "forced" then
          event.graceful = false
        end
        if case == "store" then
          event.store_valid = false
        end
        if case == "unexpected-review" then
          event.outcome = "review"
        end
        if case == "answer-retirement" then
          event.tokens_retired = false
        end
        if case == "answer-submission" then
          event.submission = "not_submitted"
        end
      end
      assert(not driver:emit(index, event))
      eq(owner:snapshot().phase, "failed")
      eq(owner:snapshot().recovery_required, true)
      eq(owner:snapshot().retry_safe, false)
      eq(owner:snapshot().review, nil)
      assert(not act(owner, { kind = "submit", text = "unsafe" }))
      assert(not act(owner, { kind = "retry", text = "unsafe" }))
      eq(#driver.requests, index)
    end
  end
)

scenario("only proven unsubmitted failure allows an explicit new retry turn", function()
  for _, submitted in ipairs({ false, true }) do
    local owner, driver = fixture()
    assert(act(owner, { kind = "submit", text = "first request" }))
    if submitted then
      assert(driver:emit(1, { kind = "submitted", model = "fixture/model" }))
    end
    assert(driver:emit(1, { kind = "stopping" }))
    assert(driver:emit(1, {
      kind = "settled",
      outcome = "failed",
      stopped = true,
      graceful = true,
      store_valid = true,
      tokens_retired = true,
      submission = "not_submitted",
    }))
    eq(owner:snapshot().phase, "failed")
    eq(owner:snapshot().retry_safe, not submitted)
    eq(owner:snapshot().recovery_required, submitted)
    eq(owner:snapshot().turns[1].submission, submitted and "submitted" or "not_submitted")
    eq(#driver.requests, 1)
    if submitted then
      assert(not act(owner, { kind = "retry", text = "unsafe retry" }))
    else
      assert(not act(owner, { kind = "retry" }))
      assert(act(owner, { kind = "retry", text = "explicit replacement request" }))
      eq(owner:snapshot().turn_id, 2)
      eq(owner:snapshot().retry_safe, false)
      eq(driver.requests[2].command.message, "explicit replacement request")
      eq(owner:snapshot().turns[1].status, "failed")
    end
  end
end)

scenario("malformed construction and action payloads are refused without effects", function()
  local owner, driver, defaults = fixture()
  for _, mutation in ipairs({
    function(o)
      o.root = {}
    end,
    function(o)
      o.root = "/tmp/../project"
    end,
    function(o)
      o.selection = { "../escape" }
    end,
    function(o)
      o.selection = { "x", "x" }
    end,
    function(o)
      o.selection = {}
    end,
    function(o)
      o.model = {}
    end,
    function(o)
      o.model = "provider/model\ncommand"
    end,
    function(o)
      o.driver = {}
    end,
  }) do
    local options = vim.deepcopy(defaults)
    mutation(options)
    local result, reason = conversation.new(options)
    assert(not result and type(reason) == "string")
  end
  local view = owner:snapshot()
  for _, action in ipairs({
    { kind = "shell", text = "anything" },
    { kind = "submit", text = "" },
    { kind = "submit", text = "   " },
    { kind = "submit", text = "unsafe\0" },
    { kind = "submit", text = string.rep("x", 32769) },
    { kind = "submit", text = "valid", root = "/tmp/other" },
    { kind = "close", command = "sh" },
  }) do
    assert(not owner:dispatch(action, view.view_revision))
    eq(owner:snapshot(), view)
  end
  eq(#driver.requests, 0)
end)

scenario("model choice is passive, idle-only and never rewrites an earlier turn", function()
  local owner, driver = fixture()
  assert(not act(owner, { kind = "choose-model", model = "fixture/other" }))
  assert(act(owner, { kind = "choose-model", model = "fixture/model" }))
  eq(#driver.requests, 0)
  assert(act(owner, { kind = "submit", text = "first" }))
  assert(
    driver:emit(
      1,
      { kind = "submitted", model = "fixture/model", models = { "fixture/model", "fixture/other" } }
    )
  )
  assert(not act(owner, { kind = "choose-model", model = "fixture/other" }))
  assert(driver:emit(1, { kind = "stopping" }))
  assert(
    driver:emit(
      1,
      { kind = "settled", outcome = "answer", stopped = true, graceful = true, store_valid = true }
    )
  )
  assert(not act(owner, { kind = "choose-model", model = "another/provider" }))
  assert(act(owner, { kind = "choose-model", model = "fixture/other" }))
  eq(#driver.requests, 1)
  eq(owner:snapshot().desired_model, "fixture/other")
  eq(owner:snapshot().turns[1].model, "fixture/model")
  assert(act(owner, { kind = "submit", text = "second" }))
  eq(driver.requests[2].command.model, "fixture/other")
  assert(not driver:emit(2, { kind = "submitted", model = "fixture/model" }))
  eq(owner:snapshot().phase, "failed")
  eq(owner:snapshot().turns[1].model, "fixture/model")
  eq(owner:snapshot().turns[2].model, nil)
end)

scenario("stale identities and sequences cannot change state or poison later events", function()
  local owner, driver = fixture()
  assert(act(owner, { kind = "submit", text = "first" }))
  local before = owner:snapshot()
  for _, field in ipairs({ "conversation_id", "owner_generation", "turn_id", "worker_generation" }) do
    assert(
      not driver:emit(
        1,
        { kind = "submitted", model = "fixture/model" },
        { [field] = "wrong", sequence = 99999 }
      )
    )
    eq(owner:snapshot(), before)
  end
  assert(driver:emit(1, { kind = "submitted", model = "fixture/model" }))
  before = owner:snapshot()
  for _, sequence in ipairs({ 0, driver.sequence, -1, 1.5, math.huge }) do
    assert(not driver:emit(1, { kind = "text", text = "duplicate" }, { sequence = sequence }))
    eq(owner:snapshot(), before)
  end
  assert(driver:emit(1, { kind = "text", text = "only once" }))
  eq(owner:snapshot().turns[1].text, "only once")
end)

scenario("unknown current-event fields fail closed without exposing raw driver data", function()
  local owner, driver = fixture()
  assert(act(owner, { kind = "submit", text = "request" }))
  assert(
    not driver:emit(
      1,
      { kind = "submitted", model = "fixture/model", raw_stderr = "sensitive raw data" }
    )
  )
  eq(owner:snapshot().phase, "failed")
  assert(not vim.inspect(owner:snapshot()):find("sensitive raw data", 1, true))
end)

scenario(
  "synchronous callbacks are serialized and a failed send exposes no false completion",
  function()
    for _, broken in ipairs({ false, true }) do
      local owner, driver = fixture()
      local send = driver.send
      function driver:send(command, receive)
        send(self, command, receive)
        self:emit(1, { kind = "submitted", model = "fixture/model" })
        self:emit(1, { kind = "text", text = "synchronous answer" })
        self:emit(1, { kind = "stopping" })
        self:emit(1, {
          kind = "settled",
          outcome = "answer",
          stopped = true,
          graceful = true,
          store_valid = true,
        })
        if broken then
          error("sensitive driver failure")
        end
        return true
      end
      local completed = false
      owner:subscribe(function(view)
        if view.phase == "idle" then
          completed = true
        end
        assert(not act(owner, { kind = "close" }), "reentrant actions must be refused")
        view.selection[1] = "listener mutation"
        error("listener failure must be isolated")
      end)
      assert(act(owner, { kind = "submit", text = "request" }))
      eq(completed, not broken)
      eq(owner:snapshot().phase, broken and "failed" or "idle")
      eq(owner:snapshot().selection[1], "first.txt")
      eq(owner:snapshot().retry_safe, false)
      eq(#driver.requests, 1)
      assert(not vim.inspect(owner:snapshot()):find("sensitive driver failure", 1, true))
    end
  end
)

scenario("listener-triggered events are not lost and subscriptions stay detached", function()
  local owner, driver = fixture()
  local emitted, removed_calls, added_calls = false, 0, 0
  local remove
  owner:subscribe(function(view)
    if view.phase == "generating" and not emitted then
      emitted = true
      remove()
      owner:subscribe(function(copy)
        added_calls = added_calls + 1
        copy.turns = {}
      end)
      assert(driver:emit(1, { kind = "text", text = "nested answer" }))
      assert(driver:emit(1, { kind = "stopping" }))
      assert(driver:emit(1, {
        kind = "settled",
        outcome = "answer",
        stopped = true,
        graceful = true,
        store_valid = true,
      }))
    end
  end)
  remove = owner:subscribe(function()
    removed_calls = removed_calls + 1
  end)
  assert(act(owner, { kind = "submit", text = "work" }))
  eq(removed_calls, 1)
  assert(driver:emit(1, { kind = "submitted", model = "fixture/model" }))
  eq(owner:snapshot().phase, "idle")
  eq(owner:snapshot().turns[1].text, "nested answer")
  eq(removed_calls, 1)
  assert(added_calls > 0)
end)

scenario("stream updates are sanitized and coalesced without invalidating cancel", function()
  local owner, driver = fixture()
  local updates = 0
  owner:subscribe(function(view)
    if view.phase == "generating" and view.turns[1].text ~= "" then
      updates = updates + 1
    end
  end)
  assert(act(owner, { kind = "submit", text = "request" }))
  assert(driver:emit(1, { kind = "submitted", model = "fixture/model" }))
  local revision = owner:snapshot().view_revision
  assert(driver:emit(1, { kind = "text", text = "safe\0\27\r\127" }))
  assert(driver:emit(1, { kind = "text", text = "\ntext" }))
  assert(driver:emit(1, { kind = "text", text = "\t" }))
  eq(owner:snapshot().turns[1].text, "safe\ntext\t")
  eq(owner:snapshot().view_revision, revision)
  eq(updates, 0)
  assert(vim.wait(1000, function()
    return updates == 1
  end, 1))
  assert(owner:dispatch({ kind = "cancel" }, revision))
end)

scenario("the turn limit refuses more work without discarding history or blocking close", function()
  local owner, driver = fixture()
  for index = 1, 64 do
    assert(act(owner, { kind = "submit", text = "question " .. index }))
    assert(driver:emit(index, { kind = "submitted", model = "fixture/model" }))
    assert(driver:emit(index, { kind = "stopping" }))
    assert(driver:emit(index, {
      kind = "settled",
      outcome = "answer",
      stopped = true,
      graceful = true,
      store_valid = true,
    }))
  end
  local before = owner:snapshot()
  assert(not act(owner, { kind = "submit", text = "one too many" }))
  eq(owner:snapshot(), before)
  eq(#driver.requests, 64)
  eq(#before.turns, 64)
  eq(before.turns[1].prompt, "question 1")
  assert(act(owner, { kind = "close" }))
  assert(
    driver:emit(65, { kind = "closed", stopped = true, cleaned = true, tokens_retired = true })
  )
  eq(owner:snapshot().phase, "closed")
end)

scenario("the display budget spans turns and refuses overflow without truncation", function()
  for _, overflow in ipairs({ false, true }) do
    local owner, driver = fixture()
    local chunk = ("x"):rep(1024 * 1024)
    for index = 1, 2 do
      assert(act(owner, { kind = "submit", text = "q" }))
      assert(driver:emit(index, { kind = "submitted", model = "fixture/model" }))
      for _ = 1, 15 do
        assert(driver:emit(index, { kind = "text", text = chunk }))
      end
      assert(driver:emit(index, { kind = "text", text = index == 1 and chunk or chunk:sub(3) }))
      if overflow and index == 2 then
        assert(not driver:emit(index, { kind = "text", text = "!" }))
        eq(owner:snapshot().phase, "failed")
        eq(owner:snapshot().recovery_required, true)
      else
        assert(driver:emit(index, { kind = "stopping" }))
        assert(driver:emit(index, {
          kind = "settled",
          outcome = "answer",
          stopped = true,
          graceful = true,
          store_valid = true,
        }))
      end
    end
    local before = owner:snapshot()
    eq(#before.turns[1].text + #before.turns[2].text + 2, 32 * 1024 * 1024)
    assert(not act(owner, { kind = "submit", text = "over budget" }))
    eq(owner:snapshot(), before)
    eq(#driver.requests, 2)
    assert(act(owner, { kind = "close" }))
    assert(
      driver:emit(3, { kind = "closed", stopped = true, cleaned = true, tokens_retired = true })
    )
  end
end)

scenario("event limits count drained traffic and still permit explicit cleanup", function()
  for _, limit in ipairs({ "count", "bytes", "fragment" }) do
    local owner, driver = fixture()
    assert(act(owner, { kind = "submit", text = "q" }))
    assert(driver:emit(1, { kind = "submitted", model = "fixture/model" }))
    if limit == "count" then
      for _ = 1, 19999 do
        assert(driver:emit(1, { kind = "text", text = "" }))
      end
      assert(not driver:emit(1, { kind = "text", text = "" }))
    elseif limit == "bytes" then
      -- Stripped controls still count as input; a small display is not a bypass.
      local chunk = ("\27"):rep(1024 * 1024)
      for _ = 1, 31 do
        assert(driver:emit(1, { kind = "text", text = chunk }))
      end
      assert(not driver:emit(1, { kind = "text", text = chunk }))
    else
      assert(not driver:emit(1, { kind = "text", text = ("x"):rep(1024 * 1024 + 1) }))
    end
    eq(owner:snapshot().phase, "failed")
    eq(owner:snapshot().turns[1].text, "")
    eq(owner:snapshot().retry_safe, false)
    eq(#driver.requests, 1)
    assert(act(owner, { kind = "close" }))
    assert(
      driver:emit(2, { kind = "closed", stopped = true, cleaned = true, tokens_retired = true })
    )
    eq(owner:snapshot().phase, "closed")
  end
end)

scenario("sequence bounds and old high-water marks cannot poison later commands", function()
  for _, next_action in ipairs({ "submit", "cancel", "close" }) do
    local owner, driver = fixture()
    assert(act(owner, { kind = "submit", text = "q" }))
    assert(
      not driver:emit(
        1,
        { kind = "submitted", model = "fixture/model" },
        { sequence = 1.7976931348623157e308 }
      )
    )
    eq(owner:snapshot().phase, "starting")
    local ceiling = 9007199254740991
    assert(
      driver:emit(1, { kind = "submitted", model = "fixture/model" }, { sequence = ceiling - 2 })
    )
    if next_action == "submit" then
      assert(driver:emit(1, { kind = "stopping" }, { sequence = ceiling - 1 }))
      assert(driver:emit(1, {
        kind = "settled",
        outcome = "answer",
        stopped = true,
        graceful = true,
        store_valid = true,
      }, { sequence = ceiling }))
      assert(act(owner, { kind = "submit", text = "next" }))
      assert(driver:emit(2, { kind = "submitted", model = "fixture/model" }, { sequence = 1 }))
      eq(owner:snapshot().phase, "generating")
    elseif next_action == "cancel" then
      assert(act(owner, { kind = "cancel" }))
      assert(driver:emit(2, {
        kind = "cancelled",
        stopped = true,
        graceful = true,
        store_valid = true,
        tokens_retired = true,
        cancel_confirmed = true,
      }, { sequence = 1 }))
      eq(owner:snapshot().phase, "idle")
    else
      assert(act(owner, { kind = "close" }))
      assert(
        driver:emit(
          2,
          { kind = "closed", stopped = true, cleaned = true, tokens_retired = true },
          { sequence = 1 }
        )
      )
      eq(owner:snapshot().phase, "closed")
    end
    assert(not driver:emit(1, { kind = "text", text = "late" }, { sequence = ceiling }))
  end
end)

scenario("deferred stream listeners can queue completion without reentrant actions", function()
  local owner, driver = fixture()
  owner:subscribe(function(view)
    if view.phase == "generating" and view.turns[1].text ~= "" then
      assert(not act(owner, { kind = "cancel" }))
      assert(driver:emit(1, { kind = "stopping" }))
      assert(driver:emit(1, {
        kind = "settled",
        outcome = "answer",
        stopped = true,
        graceful = true,
        store_valid = true,
      }))
    end
  end)
  assert(act(owner, { kind = "submit", text = "q" }))
  assert(driver:emit(1, { kind = "submitted", model = "fixture/model" }))
  assert(driver:emit(1, { kind = "text", text = "answer" }))
  assert(vim.wait(1000, function()
    return owner:snapshot().phase == "idle"
  end, 1))
  eq(owner:snapshot().turns[1].text, "answer")
  eq(#driver.requests, 1)
end)

scenario("an excessive synchronous callback burst cannot expose completion", function()
  local owner, driver = fixture()
  local send, completed = driver.send, false
  function driver:send(command, receive)
    send(self, command, receive)
    self:emit(1, { kind = "submitted", model = "fixture/model" })
    for _ = 1, 20001 do
      self:emit(1, { kind = "text", text = "" })
    end
    self:emit(1, { kind = "stopping" })
    self:emit(
      1,
      { kind = "settled", outcome = "answer", stopped = true, graceful = true, store_valid = true }
    )
    return true
  end
  owner:subscribe(function(view)
    if view.phase == "idle" then
      completed = true
    end
  end)
  assert(act(owner, { kind = "submit", text = "q" }))
  eq(owner:snapshot().phase, "failed")
  eq(owner:snapshot().recovery_required, true)
  eq(completed, false)
  eq(#driver.requests, 1)
end)

scenario("disconnect during notification fences already queued completion", function()
  local owner, driver = fixture()
  local disconnect, completed
  local send = driver.send
  function driver:send(command, receive, failed)
    disconnect = failed
    send(self, command, receive)
    self:emit(1, { kind = "submitted", model = "fixture/model" })
    self:emit(1, { kind = "stopping" })
    self:emit(1, {
      kind = "settled",
      outcome = "answer",
      stopped = true,
      graceful = true,
      store_valid = true,
    })
    return true
  end
  owner:subscribe(function(view)
    if view.phase == "generating" then
      disconnect()
    elseif view.phase == "idle" then
      completed = true
    end
  end)
  assert(act(owner, { kind = "submit", text = "must not complete" }))
  assert(not completed)
  assert(vim.wait(500, function()
    return owner:snapshot().phase == "failed"
  end, 5))
  eq(owner:snapshot().recovery_required, true)
end)

print("ai_conversation: " .. count .. " scenarios passed")
