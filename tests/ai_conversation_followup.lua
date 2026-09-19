-- Public conversation follow-ups; deterministic trusted driver, no project I/O.
local conversation = require("ai.conversation")
local count = 0
local paths = { "accepted.txt", "rejected.txt", "unchanged.txt", "pending.txt" }
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
local function files(states)
  local result = {}
  for index, path in ipairs(paths) do
    result[index] = { path = path, state = states[index] }
  end
  return result
end
local function proposal(token, generation, states)
  return { token = token, source_generation = generation, files = files(states) }
end
local function bound(view)
  return {
    round_id = view.review.id,
    proposal_revision = view.review.revision,
    proposal_token = view.review.token,
    receipt_sequence = view.review.receipt_sequence,
    files = vim.deepcopy(view.review.files),
  }
end
local function prior(view, status)
  return vim.tbl_extend("force", bound(view), { status = status, context_valid = true })
end
local function retirement(view)
  return {
    round_id = view.review.id,
    proposal_revision = view.review.revision,
    proposal_token = view.review.token,
    sequence = view.review.receipt_sequence + 1,
    phase = "cancelled",
    cleanup_pending = {},
    decisions = files({ "accepted", "rejected", "unchanged", "cancelled" }),
  }
end
local function revise(owner, text)
  local view = owner:snapshot()
  return owner:dispatch({
    kind = "revise",
    text = text or "please refine the pending change",
    round_id = view.review.id,
    proposal_revision = view.review.revision,
    proposal_token = view.review.token,
  }, view.view_revision)
end
local function fixture(cleanup)
  local driver = { commands = {}, callbacks = {}, sequence = 0 }
  function driver:send(command, receive)
    self.commands[#self.commands + 1], self.callbacks[#self.callbacks + 1] =
      vim.deepcopy(command), receive
    return true
  end
  function driver:emit(event, index)
    index = index or #self.commands
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
  function driver:finish(outcome, fields)
    return self:emit(
      vim.tbl_extend(
        "force",
        { kind = "settled", outcome = outcome, stopped = true, graceful = true, store_valid = true },
        fields or {}
      )
    )
  end
  function driver:progress()
    assert(self:emit({ kind = "submitted", model = "fixture/model" }))
    assert(self:emit({ kind = "stopping" }))
  end
  local owner = assert(conversation.new({
    root = "/tmp/conversation-followup-fixture",
    selection = paths,
    model = "fixture/model",
    driver = driver,
  }))
  assert(act(owner, { kind = "submit", text = "initial request" }))
  driver:progress()
  assert(
    driver:finish(
      "review",
      { proposal = proposal("proposal-1", 1, { "pending", "pending", "unchanged", "pending" }) }
    )
  )
  for index, choice in ipairs({ "approve", "reject" }) do
    local view = owner:snapshot()
    assert(owner:dispatch({
      kind = "decide",
      choice = choice,
      path = paths[index],
      round_id = 1,
      proposal_revision = 1,
      proposal_token = "proposal-1",
    }, view.view_revision))
    assert(driver:emit({
      kind = "decided",
      receipt = {
        round_id = 1,
        proposal_revision = 1,
        proposal_token = "proposal-1",
        sequence = index,
        phase = "review_ready",
        cleanup_pending = cleanup and { "pending.txt" } or {},
        decisions = files({
          "accepted",
          index == 1 and "pending" or "rejected",
          "unchanged",
          "pending",
        }),
      },
    }))
  end
  return owner, driver
end

scenario(
  "an explicit bound follow-up captures decided context and prevents overlapping decisions",
  function()
    local owner, driver = fixture()
    local before = owner:snapshot()
    assert(revise(owner))
    local view, command = owner:snapshot(), driver.commands[4]
    eq(view.phase, "starting")
    eq(view.review.status, "revising")
    eq(view.review.files, before.review.files)
    eq(view.turn_id, 2)
    eq(view.worker_generation, 2)
    eq(view.turns[2].followup, true)
    eq(view.turns[2].context, bound(before))
    eq(command.kind, "revise")
    eq(command.context, bound(before))
    command.context.files[1].state = "pending"
    eq(owner:snapshot().turns[2].context.files[1].state, "accepted")
    assert(not revise(owner, "overlap"))
    assert(not act(owner, { kind = "choose-model", model = "fixture/model" }))
    assert(not act(owner, {
      kind = "decide",
      choice = "approve",
      path = "pending.txt",
      round_id = 1,
      proposal_revision = 1,
      proposal_token = "proposal-1",
    }))
    eq(#driver.commands, 4)
  end
)

scenario(
  "replacement retires the predecessor and preserves decided context in the same round",
  function()
    for _, pending in ipairs({ true, false }) do
      local owner, driver = fixture()
      local before = owner:snapshot()
      assert(revise(owner))
      driver:progress()
      assert(driver:finish("review", {
        prior_review = prior(before, "retired"),
        proposal = proposal(
          "proposal-2",
          2,
          { "unchanged", "unchanged", "unchanged", pending and "pending" or "unchanged" }
        ),
      }))
      local view, round = owner:snapshot(), owner:snapshot().rounds[1]
      eq(view.phase, pending and "review" or "idle")
      eq(#view.rounds, 1)
      eq(round.id, 1)
      eq(round.revision, 2)
      eq(round.token, "proposal-2")
      eq(round.receipt_sequence, 0)
      eq(
        round.files,
        files({ "accepted", "rejected", "unchanged", pending and "pending" or "unchanged" })
      )
      eq(round.history[1].token, "proposal-1")
      eq(round.history[1].files, before.review.files)
      eq(round.history[1].status, "superseded")
      eq(view.turns[2].status, "completed")
      assert(not driver:finish("review", {
        prior_review = prior(before, "retired"),
        proposal = proposal("late", 2, { "pending", "pending", "unchanged", "pending" }),
      }))
      if pending then
        eq(round.current_index, 4)
        assert(not act(owner, {
          kind = "decide",
          choice = "approve",
          path = "pending.txt",
          round_id = 1,
          proposal_revision = 1,
          proposal_token = "proposal-1",
        }))
        assert(act(owner, {
          kind = "decide",
          choice = "approve",
          path = "pending.txt",
          round_id = 1,
          proposal_revision = 2,
          proposal_token = "proposal-2",
        }))
        assert(driver:emit({
          kind = "decided",
          receipt = {
            round_id = 1,
            proposal_revision = 2,
            proposal_token = "proposal-2",
            sequence = 1,
            phase = "applied",
            cleanup_pending = {},
            decisions = files({ "accepted", "rejected", "unchanged", "accepted" }),
          },
        }))
        eq(owner:snapshot().phase, "idle")
      else
        eq(view.review, nil)
      end
    end
  end
)

scenario("a discussion-only answer returns to the same positively revalidated review", function()
  local owner, driver = fixture()
  local before = owner:snapshot()
  assert(revise(owner, "explain the pending proposal"))
  driver:progress()
  assert(
    driver:finish("answer", { prior_review = prior(before, "active"), candidates_retired = true })
  )
  local view = owner:snapshot()
  eq(view.phase, "review")
  eq(view.review, before.review)
  eq(#view.rounds, 1)
  eq(view.turns[2].status, "completed")
  eq(view.turns[2].context, bound(before))
  eq(#driver.commands, 4)
  assert(revise(owner, "another explicit question"))
  eq(owner:snapshot().turn_id, 3)
end)

scenario("a failed follow-up restores review only with safe active-token evidence", function()
  for _, submitted in ipairs({ false, true }) do
    local owner, driver = fixture()
    local before = owner:snapshot()
    assert(revise(owner))
    if submitted then
      assert(driver:emit({ kind = "submitted", model = "fixture/model" }))
    end
    assert(driver:emit({ kind = "stopping" }))
    assert(driver:finish("failed", {
      prior_review = prior(before, "active"),
      candidates_retired = true,
      submission = submitted and "submitted" or "not_submitted",
    }))
    local view = owner:snapshot()
    eq(view.phase, "review")
    eq(view.review, before.review)
    eq(view.turns[2].status, "failed")
    eq(view.turns[2].submission, submitted and "submitted" or "not_submitted")
    eq(view.retry_safe, false)
    eq(view.recovery_required, false)
    eq(#driver.commands, 4)
    assert(not act(owner, { kind = "retry", text = "do not silently replay" }))
    assert(revise(owner, "a new explicit attempt"))
    eq(#driver.commands, 5)
  end
end)

scenario("follow-up cancel and close prove both worker and all-candidate retirement", function()
  for _, case in ipairs({
    { "starting", "cancel" },
    { "generating", "cancel" },
    { "starting", "close" },
    { "generating", "close" },
    { "stopping", "close" },
    { "generating", "cancel-close" },
  }) do
    local owner, driver = fixture()
    local before = owner:snapshot()
    assert(revise(owner))
    if case[1] ~= "starting" then
      assert(driver:emit({ kind = "submitted", model = "fixture/model" }))
    end
    if case[1] == "stopping" then
      assert(driver:emit({ kind = "stopping" }))
    end
    assert(act(owner, { kind = case[2] == "close" and "close" or "cancel" }))
    if case[2] == "cancel-close" then
      assert(act(owner, { kind = "close" }))
    end
    assert(not driver:emit({
      kind = "settled",
      outcome = "review",
      stopped = true,
      graceful = true,
      store_valid = true,
      prior_review = prior(before, "retired"),
      proposal = proposal(
        "late-candidate",
        2,
        { "unchanged", "unchanged", "unchanged", "pending" }
      ),
    }, 4))
    local event = {
      kind = case[2] == "cancel" and "cancelled" or "closed",
      stopped = true,
      tokens_retired = true,
      candidates_retired = true,
      receipt = retirement(before),
    }
    if case[2] == "cancel" then
      event.graceful, event.store_valid, event.cancel_confirmed = true, true, true
    else
      event.writer_stopped, event.cleaned = true, true
    end
    assert(driver:emit(event))
    local view = owner:snapshot()
    eq(view.phase, case[2] == "cancel" and "idle" or "closed")
    eq(view.review, nil)
    eq(view.rounds[1].files, files({ "accepted", "rejected", "unchanged", "cancelled" }))
    eq(view.turns[2].status, "cancelled")
    eq(view.recovery_required, false)
    assert(not driver:emit({
      kind = "settled",
      outcome = "answer",
      stopped = true,
      graceful = true,
      store_valid = true,
      prior_review = prior(before, "active"),
    }, 4))
  end
end)

scenario(
  "invalid replacements never change the proposal identity or reopen decided files",
  function()
    for _, corrupt in ipairs({
      function(e)
        e.prior_review = nil
      end,
      function(e)
        e.prior_review.status = "active"
      end,
      function(e)
        e.prior_review.context_valid = false
      end,
      function(e)
        e.prior_review.round_id = 2
      end,
      function(e)
        e.prior_review.proposal_revision = 2
      end,
      function(e)
        e.prior_review.proposal_token = "wrong"
      end,
      function(e)
        e.prior_review.receipt_sequence = 1
      end,
      function(e)
        e.prior_review.files[1].state = "pending"
      end,
      function(e)
        e.prior_review.raw = "private"
      end,
      function(e)
        e.proposal.token = "proposal-1"
      end,
      function(e)
        e.proposal.source_generation = 1
      end,
      function(e)
        e.proposal.files[1].state = "pending"
      end,
      function(e)
        e.proposal.files[2].state = "pending"
      end,
      function(e)
        e.proposal.files[3].state = "pending"
      end,
      function(e)
        e.proposal.files[4].path = "outside.txt"
      end,
      function(e)
        e.tokens_retired = true
      end,
      function(e)
        e.stopped = false
      end,
    }) do
      local owner, driver = fixture()
      local before = owner:snapshot()
      assert(revise(owner))
      driver:progress()
      local event = {
        kind = "settled",
        outcome = "review",
        stopped = true,
        graceful = true,
        store_valid = true,
        prior_review = prior(before, "retired"),
        proposal = proposal("proposal-2", 2, { "unchanged", "unchanged", "unchanged", "pending" }),
      }
      corrupt(event)
      assert(not driver:emit(event))
      local view = owner:snapshot()
      eq(view.phase, "failed")
      eq(view.review.token, "proposal-1")
      eq(view.review.revision, 1)
      eq(view.review.history, nil)
      eq(view.review.files, files({ "accepted", "rejected", "unchanged", "blocked" }))
      eq(view.retry_safe, false)
      eq(view.recovery_required, true)
    end
  end
)

scenario(
  "answers and failures never infer predecessor eligibility from missing or contradictory proof",
  function()
    for _, outcome in ipairs({ "answer", "failed" }) do
      for _, corrupt in ipairs({
        function(e)
          e.prior_review = nil
        end,
        function(e)
          e.prior_review.status = "retired"
        end,
        function(e)
          e.prior_review.context_valid = false
        end,
        function(e)
          e.prior_review.files[2].state = "accepted"
        end,
        function(e)
          e.graceful = false
        end,
        function(e)
          e.store_valid = false
        end,
        function(e)
          e.tokens_retired = true
        end,
        function(e)
          e.submission = "not_submitted"
        end,
      }) do
        local owner, driver = fixture()
        local before = owner:snapshot()
        assert(revise(owner))
        driver:progress()
        local event = {
          kind = "settled",
          outcome = outcome,
          stopped = true,
          graceful = true,
          store_valid = true,
          submission = "submitted",
          prior_review = prior(before, "active"),
          candidates_retired = true,
        }
        corrupt(event)
        assert(not driver:emit(event))
        eq(owner:snapshot().phase, "failed")
        eq(owner:snapshot().retry_safe, false)
        eq(owner:snapshot().review.files[1].state, "accepted")
        assert(not revise(owner))
      end
    end
    local owner, driver = fixture()
    assert(revise(owner))
    assert(driver:emit({ kind = "stopping" }))
    assert(not driver:finish("failed", { submission = "not_submitted", tokens_retired = true }))
    eq(owner:snapshot().retry_safe, false)
    assert(not act(owner, { kind = "retry", text = "not an independent startup retry" }))
  end
)

scenario("predecessor retirement alone cannot complete follow-up cancellation", function()
  for _, field in ipairs({ "candidates_retired", "cancel_confirmed", "receipt", "graceful" }) do
    local owner, driver = fixture()
    local before = owner:snapshot()
    assert(revise(owner))
    assert(act(owner, { kind = "cancel" }))
    local event = {
      kind = "cancelled",
      stopped = true,
      graceful = true,
      store_valid = true,
      tokens_retired = true,
      candidates_retired = true,
      cancel_confirmed = true,
      receipt = retirement(before),
    }
    event[field] = nil
    assert(not driver:emit(event))
    eq(owner:snapshot().phase, "failed")
    eq(owner:snapshot().review.files[1].state, "accepted")
    eq(owner:snapshot().review.files[4].state, "blocked")
  end
end)

scenario("repeated revisions retain immutable history and never reuse superseded tokens", function()
  for _, reused in ipairs({ "proposal-1", "proposal-2" }) do
    local owner, driver = fixture()
    for generation = 2, 3 do
      local before = owner:snapshot()
      assert(revise(owner))
      driver:progress()
      assert(driver:finish("review", {
        prior_review = prior(before, "retired"),
        proposal = proposal(
          "proposal-" .. generation,
          generation,
          { "unchanged", "unchanged", "unchanged", "pending" }
        ),
      }))
    end
    local before = owner:snapshot()
    eq(before.review.revision, 3)
    eq(#before.review.history, 2)
    eq(before.review.history[1].token, "proposal-1")
    eq(before.review.history[1].receipt_sequence, 2)
    eq(before.review.history[2].token, "proposal-2")
    eq(before.review.history[2].receipt_sequence, 0)
    before.review.history[1].files[1].state = "pending"
    eq(owner:snapshot().review.history[1].files[1].state, "accepted")
    assert(revise(owner))
    driver:progress()
    assert(not driver:finish("review", {
      prior_review = prior(owner:snapshot(), "retired"),
      proposal = proposal(reused, 4, { "unchanged", "unchanged", "unchanged", "pending" }),
    }))
    eq(owner:snapshot().review.token, "proposal-3")
    eq(#owner:snapshot().review.history, 2)
    eq(owner:snapshot().recovery_required, true)
  end
end)

scenario("an active predecessor alone does not prove unused candidate retirement", function()
  for _, outcome in ipairs({ "answer", "failed" }) do
    local owner, driver = fixture()
    local before = owner:snapshot()
    assert(revise(owner))
    driver:progress()
    assert(
      not driver:finish(
        outcome,
        { prior_review = prior(before, "active"), submission = "submitted" }
      )
    )
    eq(owner:snapshot().phase, "failed")
    eq(owner:snapshot().review.status, "recovery_required")
    eq(owner:snapshot().review.files[1].state, "accepted")
  end
end)

scenario(
  "a driver failure after synchronous replacement evidence exposes no transient revision",
  function()
    for _, mode in ipairs({ "success", "throw", "false" }) do
      local owner, driver = fixture()
      local before, send = owner:snapshot(), driver.send
      local observed = false
      owner:subscribe(function(view)
        if view.review.token == "proposal-2" then
          observed = true
        end
        assert(not revise(owner, "reentrant follow-up"))
      end)
      function driver:send(command, receive)
        send(self, command, receive)
        self:progress()
        self:finish("review", {
          prior_review = prior(before, "retired"),
          proposal = proposal(
            "proposal-2",
            2,
            { "unchanged", "unchanged", "unchanged", "pending" }
          ),
        })
        if mode == "throw" then
          error("private controller error")
        end
        return mode == "success"
      end
      assert(revise(owner))
      local view = owner:snapshot()
      eq(observed, mode == "success")
      eq(view.review.token, mode == "success" and "proposal-2" or "proposal-1")
      eq(view.phase, mode == "success" and "review" or "failed")
      eq(view.review.files[1].state, "accepted")
      eq(#driver.commands, 4)
      assert(not vim.inspect(view):find("private controller error", 1, true))
    end
  end
)

scenario(
  "follow-up admission rejects stale identities, unsafe inputs, cleanup and exhausted turns",
  function()
    local owner, driver = fixture()
    local view = owner:snapshot()
    local action = {
      kind = "revise",
      text = "refine",
      round_id = 1,
      proposal_revision = 1,
      proposal_token = "proposal-1",
    }
    for _, override in ipairs({
      { round_id = 2 },
      { proposal_revision = 2 },
      { proposal_token = "old" },
      { text = "" },
      { text = "bad\0text" },
      { text = ("x"):rep(32769) },
      { context = { files = {} } },
      { model = "fixture/other" },
      { selection = { "outside.txt" } },
    }) do
      assert(not owner:dispatch(vim.tbl_extend("force", action, override), view.view_revision))
      eq(owner:snapshot(), view)
    end
    assert(not owner:dispatch(action, view.view_revision - 1))
    eq(#driver.commands, 3)
    local dirty, dirty_driver = fixture(true)
    assert(not revise(dirty))
    eq(#dirty_driver.commands, 3)
    for _ = 2, 64 do
      local before = owner:snapshot()
      assert(revise(owner, "explain"))
      driver:progress()
      assert(
        driver:finish(
          "answer",
          { prior_review = prior(before, "active"), candidates_retired = true }
        )
      )
    end
    eq(#owner:snapshot().turns, 64)
    local commands = #driver.commands
    assert(not revise(owner))
    eq(#driver.commands, commands)
    eq(owner:snapshot().phase, "review")
  end
)

scenario(
  "close after an ambiguous handoff requires candidate retirement and retains recovery",
  function()
    local owner, driver = fixture()
    assert(revise(owner))
    driver:progress()
    assert(not driver:finish("answer"))
    assert(act(owner, { kind = "close" }))
    assert(not driver:emit({
      kind = "closed",
      stopped = true,
      writer_stopped = true,
      cleaned = true,
      tokens_retired = true,
    }))
    eq(owner:snapshot().phase, "failed")
    assert(act(owner, { kind = "close" }))
    assert(driver:emit({
      kind = "closed",
      stopped = true,
      writer_stopped = true,
      cleaned = true,
      tokens_retired = true,
      candidates_retired = true,
    }))
    local view = owner:snapshot()
    eq(view.phase, "closed")
    eq(view.recovery_required, true)
    eq(view.rounds[1].files, files({ "accepted", "rejected", "unchanged", "blocked" }))
    eq(view.turns[2].status, "failed")
  end
)

print("ai_conversation_followup: " .. count .. " scenarios passed")
