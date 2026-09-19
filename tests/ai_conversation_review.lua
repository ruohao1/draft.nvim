-- Public conversation review interface; deterministic trusted driver, no writes.
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
local function act(owner, action)
  return owner:dispatch(action, owner:snapshot().view_revision)
end
local function fixture()
  local driver = { commands = {}, callbacks = {}, sequence = 0 }
  function driver:send(command, receive)
    self.commands[#self.commands + 1], self.callbacks[#self.callbacks + 1] =
      vim.deepcopy(command), receive
    return true
  end
  function driver:emit(index, event)
    self.sequence = self.sequence + 1
    local command = self.commands[index]
    return self.callbacks[index](vim.tbl_extend("force", vim.deepcopy(event), {
      conversation_id = command.conversation_id,
      owner_generation = command.owner_generation,
      turn_id = command.turn_id,
      worker_generation = command.worker_generation,
      sequence = self.sequence,
    }))
  end
  local owner = assert(conversation.new({
    root = "/tmp/conversation-review-fixture",
    selection = { "first.txt", "second.txt" },
    model = "fixture/model",
    driver = driver,
  }))
  return owner, driver
end
local function proposal(token)
  return {
    token = token or "proposal-1",
    source_generation = 1,
    files = {
      { path = "first.txt", state = "pending" },
      { path = "second.txt", state = "pending" },
    },
  }
end
local function complete(owner, driver, proposed)
  assert(act(owner, { kind = "submit", text = "edit the selected files" }))
  local index = #driver.commands
  assert(driver:emit(index, { kind = "submitted", model = "fixture/model" }))
  assert(driver:emit(index, { kind = "stopping" }))
  return driver:emit(index, {
    kind = "settled",
    outcome = "review",
    stopped = true,
    graceful = true,
    store_valid = true,
    proposal = proposed or proposal(),
  })
end
local function decide(owner, choice, path)
  local view = owner:snapshot()
  return owner:dispatch({
    kind = "decide",
    choice = choice,
    path = path,
    round_id = view.review.id,
    proposal_revision = view.review.revision,
    proposal_token = view.review.token,
  }, view.view_revision)
end
local function receipt(sequence, phase, first, second)
  return {
    round_id = 1,
    proposal_revision = 1,
    proposal_token = "proposal-1",
    sequence = sequence,
    phase = phase,
    decisions = { { path = "first.txt", state = first }, { path = "second.txt", state = second } },
    cleanup_pending = {},
  }
end

scenario("a proven frozen proposal opens a detached review without publishing", function()
  local owner, driver = fixture()
  local proposed = proposal()
  assert(complete(owner, driver, proposed))
  local view = owner:snapshot()
  eq(view.phase, "review")
  eq(view.review.id, 1)
  eq(view.review.revision, 1)
  eq(view.review.token, "proposal-1")
  eq(view.review.receipt_sequence, 0)
  eq(view.review.files, proposed.files)
  eq(view.review.current_index, 1)
  eq(view.turns[1].status, "completed")
  eq(view.turns[1].round_id, 1)
  proposed.files[1].state = "accepted"
  view.review.files[1].state = "accepted"
  eq(owner:snapshot().review.files[1].state, "pending")
  eq(#driver.commands, 1)
  assert(not act(owner, { kind = "choose-model", model = "fixture/model" }))
  assert(not act(owner, { kind = "submit", text = "independent work" }))
  assert(not driver:emit(1, { kind = "text", text = "late completion" }))
end)

scenario("per-file approval waits for its receipt and never accepts the other file", function()
  local owner, driver = fixture()
  assert(complete(owner, driver))
  assert(decide(owner, "approve", "first.txt"))
  eq(owner:snapshot().phase, "publishing")
  eq(owner:snapshot().review.files[1].state, "pending")
  eq(driver.commands[2].kind, "decide")
  eq(driver.commands[2].path, "first.txt")
  eq(driver.commands[2].proposal_token, "proposal-1")
  for _, action in ipairs({
    { kind = "close" },
    { kind = "cancel" },
    { kind = "submit", text = "overlap" },
    { kind = "choose-model", model = "fixture/model" },
  }) do
    assert(not act(owner, action))
  end
  assert(not decide(owner, "reject", "second.txt"))
  assert(
    driver:emit(
      2,
      { kind = "decided", receipt = receipt(1, "review_ready", "accepted", "pending") }
    )
  )
  eq(owner:snapshot().phase, "review")
  eq(owner:snapshot().review.current_index, 2)
  eq(owner:snapshot().review.files[1].state, "accepted")
  eq(owner:snapshot().review.files[2].state, "pending")
  assert(not decide(owner, "approve", "first.txt"))
  assert(decide(owner, "reject", "second.txt"))
  -- Applied is cumulative: the final rejected file is not an accepted write.
  assert(
    driver:emit(3, { kind = "decided", receipt = receipt(2, "applied", "accepted", "rejected") })
  )
  eq(owner:snapshot().phase, "idle")
  eq(owner:snapshot().review, nil)
  eq(owner:snapshot().rounds[1].files, {
    { path = "first.txt", state = "accepted" },
    { path = "second.txt", state = "rejected" },
  })
  eq(owner:snapshot().rounds[1].receipt_sequence, 2)
  eq(#driver.commands, 3)
end)

scenario(
  "a malformed or missing writer result preserves accepted files and reports uncertainty",
  function()
    for _, broken in ipairs({ "receipt", "throw", "false" }) do
      local owner, driver = fixture()
      assert(complete(owner, driver))
      assert(decide(owner, "approve", "first.txt"))
      assert(
        driver:emit(
          2,
          { kind = "decided", receipt = receipt(1, "review_ready", "accepted", "pending") }
        )
      )
      if broken ~= "receipt" then
        function driver:send()
          if broken == "throw" then
            error("private writer failure")
          end
          return false
        end
      end
      assert(decide(owner, "approve", "second.txt"))
      if broken == "receipt" then
        -- A contradictory result must never roll back the earlier acceptance.
        assert(
          not driver:emit(
            3,
            { kind = "decided", receipt = receipt(2, "applied", "rejected", "accepted") }
          )
        )
      end
      local view = owner:snapshot()
      eq(view.phase, "failed")
      eq(view.recovery_required, true)
      eq(view.retry_safe, false)
      eq(view.review.files[1].state, "accepted")
      eq(view.review.files[2].state, "uncertain")
      eq(view.review.status, "recovery_required")
      assert(not act(owner, { kind = "retry", text = "unsafe retry" }))
      assert(not decide(owner, "approve", "second.txt"))
      assert(not vim.inspect(view):find("private writer failure", 1, true))
    end
  end
)

scenario("failure receipts and cleanup evidence survive backend close", function()
  for _, outcome in ipairs({ { "partial", "blocked" }, { "uncertain", "uncertain" } }) do
    local owner, driver = fixture()
    assert(complete(owner, driver))
    assert(decide(owner, "approve", "first.txt"))
    assert(
      driver:emit(
        2,
        { kind = "decided", receipt = receipt(1, "review_ready", "accepted", "pending") }
      )
    )
    assert(decide(owner, "approve", "second.txt"))
    local result = receipt(2, outcome[1], "accepted", outcome[2])
    result.cleanup_pending = { "second.txt" }
    assert(not driver:emit(3, { kind = "decided", receipt = result }))
    eq(owner:snapshot().review.receipt_sequence, 2)
    eq(owner:snapshot().review.files[2].state, outcome[2])
    eq(owner:snapshot().review.cleanup_pending, { "second.txt" })
    assert(act(owner, { kind = "close" }))
    assert(driver:emit(4, {
      kind = "closed",
      stopped = true,
      writer_stopped = true,
      cleaned = true,
      tokens_retired = true,
    }))
    local view = owner:snapshot()
    eq(view.phase, "closed")
    eq(view.recovery_required, true)
    eq(view.rounds[1].files[1].state, "accepted")
    eq(view.rounds[1].files[2].state, outcome[2])
    eq(view.rounds[1].cleanup_pending, { "second.txt" })
  end
end)

scenario("review cancel and close retire only pending files with a matching receipt", function()
  for _, action in ipairs({ "cancel", "close", "cancel-then-close" }) do
    local owner, driver = fixture()
    assert(complete(owner, driver))
    assert(decide(owner, "approve", "first.txt"))
    assert(
      driver:emit(
        2,
        { kind = "decided", receipt = receipt(1, "review_ready", "accepted", "pending") }
      )
    )
    assert(act(owner, { kind = action == "close" and "close" or "cancel" }))
    if action == "cancel-then-close" then
      assert(act(owner, { kind = "close" }))
      assert(not driver:emit(3, {
        kind = "cancelled",
        stopped = true,
        graceful = true,
        store_valid = true,
        tokens_retired = true,
        receipt = receipt(2, "cancelled", "accepted", "cancelled"),
      }))
    end
    local index = #driver.commands
    eq(driver.commands[index].proposal_token, "proposal-1")
    eq(owner:snapshot().review.files[2].state, "pending")
    local event = {
      kind = action == "cancel" and "cancelled" or "closed",
      stopped = true,
      tokens_retired = true,
      receipt = receipt(2, "cancelled", "accepted", "cancelled"),
    }
    if action == "cancel" then
      event.graceful, event.store_valid = true, true
    else
      event.cleaned, event.writer_stopped = true, true
    end
    assert(driver:emit(index, event))
    local view = owner:snapshot()
    eq(view.phase, action == "cancel" and "idle" or "closed")
    eq(view.review, nil)
    eq(view.rounds[1].files[1].state, "accepted")
    eq(view.rounds[1].files[2].state, "cancelled")
    eq(view.rounds[1].status, "cancelled")
    eq(view.turns[1].status, "completed")
    eq(view.recovery_required, false)
  end
end)

scenario("a claimed unsubmitted failure cannot carry a frozen proposal and enable retry", function()
  local owner, driver = fixture()
  assert(act(owner, { kind = "submit", text = "q" }))
  assert(driver:emit(1, { kind = "stopping" }))
  assert(not driver:emit(1, {
    kind = "settled",
    outcome = "failed",
    stopped = true,
    graceful = true,
    store_valid = true,
    tokens_retired = true,
    submission = "not_submitted",
    proposal = proposal(),
  }))
  eq(owner:snapshot().phase, "failed")
  eq(owner:snapshot().retry_safe, false)
  eq(owner:snapshot().review, nil)
end)

scenario("stale or expanded approval actions have no effect", function()
  local owner, driver = fixture()
  assert(complete(owner, driver))
  local view = owner:snapshot()
  local action = {
    kind = "decide",
    choice = "approve",
    path = "first.txt",
    round_id = 1,
    proposal_revision = 1,
    proposal_token = "proposal-1",
  }
  for _, override in ipairs({
    { round_id = 2 },
    { proposal_revision = 2 },
    { proposal_token = "old" },
    { path = "../outside" },
    { choice = "approve-all" },
    { remaining = true },
    { reviewed = true },
    { path = "second.txt", manifest = "/tmp/injected" },
  }) do
    assert(not owner:dispatch(vim.tbl_extend("force", action, override), view.view_revision))
    eq(owner:snapshot(), view)
  end
  assert(not owner:dispatch(action, view.view_revision - 1))
  eq(#driver.commands, 1)
  assert(decide(owner, "reject", "first.txt"))
  assert(
    driver:emit(
      2,
      { kind = "decided", receipt = receipt(1, "review_ready", "rejected", "pending") }
    )
  )
  eq(owner:snapshot().review.current_index, 1)
  assert(not owner:dispatch(action, view.view_revision))
  assert(not decide(owner, "approve", "first.txt"))
  assert(decide(owner, "approve", "second.txt"))
  assert(
    driver:emit(3, { kind = "decided", receipt = receipt(2, "applied", "rejected", "accepted") })
  )
end)

scenario("malformed or widened receipts cannot publish an unapproved file", function()
  for _, change in ipairs({
    function(r)
      r.round_id = 2
    end,
    function(r)
      r.proposal_revision = 2
    end,
    function(r)
      r.proposal_token = "old"
    end,
    function(r)
      r.sequence = 2
    end,
    function(r)
      r.decisions[1].path = "second.txt"
    end,
    function(r)
      r.decisions[2].state = "accepted"
      r.phase = "applied"
    end,
    function(r)
      r.decisions[1].state = "rejected"
    end,
    function(r)
      r.decisions[2] = nil
    end,
    function(r)
      r.decisions[1].raw = "private"
    end,
    function(r)
      r.phase = "applied"
    end,
    function(r)
      r.cleanup_pending = { "outside.txt" }
    end,
    function(r)
      r.cleanup_pending = { "first.txt", "first.txt" }
    end,
    function(r)
      r.decisions = setmetatable(r.decisions, {})
    end,
  }) do
    local owner, driver = fixture()
    assert(complete(owner, driver))
    assert(decide(owner, "approve", "first.txt"))
    local result = receipt(1, "review_ready", "accepted", "pending")
    change(result)
    assert(not driver:emit(2, { kind = "decided", receipt = result }))
    local view = owner:snapshot()
    eq(view.phase, "failed")
    eq(view.review.files[1].state, "uncertain")
    eq(view.review.files[2].state, "blocked")
    eq(view.review.receipt_sequence, 0)
    eq(view.recovery_required, true)
  end
end)

scenario("invalid initial proposals and unproven retirement cannot open usable review", function()
  for _, change in ipairs({
    function(p)
      p.token = "../foreign"
    end,
    function(p)
      p.source_generation = 2
    end,
    function(p)
      p.files[1].state = "accepted"
    end,
    function(p)
      p.files[1].state = "unchanged"
      p.files[2].state = "unchanged"
    end,
    function(p)
      p.files[2].path = "first.txt"
    end,
    function(p)
      p.files[3] = { path = "extra", state = "pending" }
    end,
  }) do
    local owner, driver = fixture()
    local proposed = proposal()
    change(proposed)
    assert(not complete(owner, driver, proposed))
    eq(owner:snapshot().phase, "failed")
    eq(owner:snapshot().review, nil)
  end
  for _, action in ipairs({ "cancel", "close" }) do
    local owner, driver = fixture()
    assert(complete(owner, driver))
    assert(act(owner, { kind = action }))
    local event = action == "cancel"
        and {
          kind = "cancelled",
          stopped = true,
          graceful = true,
          store_valid = true,
          tokens_retired = true,
          cancel_confirmed = true,
        }
      or {
        kind = "closed",
        stopped = true,
        writer_stopped = true,
        cleaned = true,
        tokens_retired = true,
      }
    assert(not driver:emit(2, event))
    eq(owner:snapshot().phase, "failed")
    eq(owner:snapshot().review.files[1].state, "blocked")
  end
end)

scenario("new rounds retain old decisions and cannot reuse an old proposal token", function()
  for _, token in ipairs({ "proposal-2", "proposal-1" }) do
    local owner, driver = fixture()
    assert(complete(owner, driver))
    assert(decide(owner, "approve", "first.txt"))
    assert(
      driver:emit(
        2,
        { kind = "decided", receipt = receipt(1, "review_ready", "accepted", "pending") }
      )
    )
    assert(decide(owner, "reject", "second.txt"))
    assert(
      driver:emit(3, { kind = "decided", receipt = receipt(2, "applied", "accepted", "rejected") })
    )
    local proposed = proposal(token)
    proposed.source_generation, proposed.files[1].state = 2, "unchanged"
    local opened = complete(owner, driver, proposed)
    if token == "proposal-1" then
      assert(not opened)
      eq(owner:snapshot().phase, "failed")
    else
      assert(opened)
      eq(owner:snapshot().review.id, 2)
      eq(owner:snapshot().review.current_index, 2)
      assert(not act(owner, {
        kind = "decide",
        choice = "approve",
        path = "second.txt",
        round_id = 1,
        proposal_revision = 1,
        proposal_token = "proposal-1",
      }))
      assert(
        not driver:emit(
          3,
          { kind = "decided", receipt = receipt(3, "applied", "accepted", "accepted") }
        )
      )
      assert(decide(owner, "approve", "second.txt"))
      local result = receipt(1, "applied", "unchanged", "accepted")
      result.round_id, result.proposal_token = 2, "proposal-2"
      assert(driver:emit(5, { kind = "decided", receipt = result }))
      eq(owner:snapshot().phase, "idle")
    end
    eq(owner:snapshot().rounds[1].files[1].state, "accepted")
    eq(owner:snapshot().rounds[1].files[2].state, "rejected")
  end
end)

scenario(
  "a synchronous writer callback followed by failure exposes no transient acceptance",
  function()
    for _, mode in ipairs({ "success", "throw", "false" }) do
      local owner, driver = fixture()
      assert(complete(owner, driver))
      local send, observed_acceptance = driver.send, false
      function driver:send(command, receive)
        send(self, command, receive)
        self:emit(
          2,
          { kind = "decided", receipt = receipt(1, "review_ready", "accepted", "pending") }
        )
        if mode == "throw" then
          error("private writer error")
        end
        return mode == "success"
      end
      owner:subscribe(function(view)
        if view.review.files[1].state == "accepted" then
          observed_acceptance = true
        end
        assert(not decide(owner, "approve", "second.txt"))
        view.review.files[2].state = "accepted"
      end)
      assert(decide(owner, "approve", "first.txt"))
      eq(observed_acceptance, mode == "success")
      eq(owner:snapshot().review.files[1].state, mode == "success" and "accepted" or "uncertain")
      eq(owner:snapshot().review.files[2].state, mode == "success" and "pending" or "blocked")
      eq(#driver.commands, 2)
    end
  end
)

scenario("accepting the last displayed file wraps to the next pending file", function()
  local owner, driver = fixture()
  assert(complete(owner, driver))
  assert(decide(owner, "approve", "second.txt"))
  assert(
    driver:emit(
      2,
      { kind = "decided", receipt = receipt(1, "review_ready", "pending", "accepted") }
    )
  )
  eq(owner:snapshot().review.current_index, 1)
  local view = owner:snapshot()
  view.review.files[1].state = "accepted"
  eq(owner:snapshot().review.files[1].state, "pending")
  assert(
    not driver:emit(
      2,
      { kind = "decided", receipt = receipt(2, "applied", "accepted", "accepted") }
    )
  )
  eq(owner:snapshot().review.files[1].state, "pending")
end)

scenario("contradictory optional shutdown evidence cannot claim successful cleanup", function()
  local owner, driver = fixture()
  assert(act(owner, { kind = "close" }))
  assert(not driver:emit(1, {
    kind = "closed",
    stopped = true,
    cleaned = true,
    tokens_retired = true,
    writer_stopped = false,
  }))
  eq(owner:snapshot().phase, "failed")

  owner, driver = fixture()
  assert(complete(owner, driver))
  assert(act(owner, { kind = "cancel" }))
  assert(not driver:emit(2, {
    kind = "cancelled",
    stopped = true,
    graceful = true,
    store_valid = true,
    tokens_retired = true,
    cancel_confirmed = false,
    receipt = receipt(1, "cancelled", "cancelled", "cancelled"),
  }))
  eq(owner:snapshot().phase, "failed")
end)

print("ai_conversation_review: " .. count .. " scenarios passed")
