-- Editor-owned conversation state. No agent, filesystem, writer or UI operations.
-- The injected trusted driver owns effects; construction/observation are passive.
-- The chat coordinator observes this owner; the production adapter owns effects.
-- send(command, receive, disconnected) returns promptly, except the trusted
-- production adapter's existing guarded local publisher may wait up to 5 s.
-- The optional
-- third callback reports permanent controller loss even between completed turns;
-- it never proves worker shutdown or cleanup. Synchronous events are held
-- until that acceptance; a failed send never proves that no effect occurred.
-- Each command gets a fresh callback lease and positive exact-integer sequence
-- space. A receive result only acknowledges ingestion, not worker termination.
-- The adapter must enforce actual deadlines/shutdown and treat callback refusal
-- as a reason to stop safely. Never pass raw ACP bodies or agent-supplied proof.
-- decide is one explicit file/remaining-files intent, not a write receipt. The adapter
-- must validate visible frozen review, buffers/sources and existing writer gates.
-- Receipt data is normalized trusted evidence, never an agent notification.
-- Follow-up restoration needs active predecessor AND unused-candidate retirement
-- evidence. Replacement needs the opposite: retired predecessor, fresh candidate.
local M = {}
local MAX_BYTES, MAX_EVENTS = 32 * 1024 * 1024, 20000
local function plain(value)
  return type(value) == "table" and getmetatable(value) == nil
end
local function keys(value, allowed)
  if not plain(value) then
    return false
  end
  for key in pairs(value) do
    if not allowed[key] then
      return false
    end
  end
  return true
end
local function path(value, absolute)
  if
    type(value) ~= "string"
    or #value == 0
    or #value > 4096
    or value:find("[%z\1-\31\127]")
    or (value:sub(1, 1) == "/") ~= absolute
  then
    return false
  end
  local relative = absolute and value:sub(2) or value
  local depth = 0
  for part in (relative .. "/"):gmatch("(.-)/") do
    depth = depth + 1
    if part == "" or part == "." or part == ".." or depth > 64 then
      return false
    end
  end
  return true
end
local function model(value)
  return type(value) == "string"
    and #value <= 256
    and value:match("^([%w_.-]+)/[^%s%z\1-\31\127]+$")
end
local function selection(value)
  if not plain(value) or not vim.islist(value) or #value < 1 or #value > 16 then
    return false
  end
  local seen = {}
  for _, name in ipairs(value) do
    if not path(name, false) or seen[name] then
      return false
    end
    seen[name] = true
  end
  return true
end
local ACTIONS = {
  submit = { kind = true, text = true },
  retry = { kind = true, text = true },
  revise = {
    kind = true,
    text = true,
    round_id = true,
    proposal_revision = true,
    proposal_token = true,
  },
  ["edit-proposal"] = {
    kind = true,
    path = true,
    seed_sha256 = true,
    round_id = true,
    proposal_revision = true,
    proposal_token = true,
  },
  ["discard-correction"] = { kind = true },
  correct = {
    kind = true,
    path = true,
    replacement = true,
    round_id = true,
    proposal_revision = true,
    proposal_token = true,
  },
  cancel = { kind = true },
  close = { kind = true },
  ["choose-model"] = { kind = true, model = true },
  decide = {
    kind = true,
    choice = true,
    path = true,
    remaining = true,
    round_id = true,
    proposal_revision = true,
    proposal_token = true,
  },
}
local EVENTS = {
  startup = { stage = true },
  submitted = { model = true, models = true },
  text = { text = true },
  progress = { tool_id = true, title = true, status = true },
  stopping = {},
  settled = {
    diagnostic = true,
    outcome = true,
    stopped = true,
    graceful = true,
    store_valid = true,
    tokens_retired = true,
    submission = true,
    proposal = true,
    prior_review = true,
    candidates_retired = true,
  },
  cancelled = {
    stopped = true,
    graceful = true,
    store_valid = true,
    tokens_retired = true,
    cancel_confirmed = true,
    candidates_retired = true,
    receipt = true,
  },
  closed = {
    stopped = true,
    writer_stopped = true,
    candidates_retired = true,
    cleaned = true,
    tokens_retired = true,
    receipt = true,
  },
  decided = { receipt = true, sources_valid = true },
  corrected = { outcome = true, proposal = true, prior_review = true, candidates_retired = true },
}
local STARTUP = {
  sources = "Preparing saved file copies",
  credentials = "Checking configured credentials",
  launch = "Starting OpenCode in its sandbox",
  initialize = "Checking OpenCode compatibility (up to 15 seconds)",
  session = "Opening an OpenCode session (up to 15 seconds)",
  resume = "Resuming the conversation (up to 15 seconds)",
  model = "Confirming the selected model (up to 15 seconds)",
  mode = "Confirming edit mode (up to 15 seconds)",
  compatibility = "Checking command sandbox support (up to 15 seconds)",
}
local DIAGNOSTICS = {
  sources = "Saved file validation failed. Save and check the selected files and their permissions.",
  credentials = "OpenCode credentials could not be loaded. Close chat, then check the auth file and provider with :NvimAIStageSetup.",
  launch = "OpenCode could not start in its sandbox. Run :checkhealth draft and check the configured executables.",
  initialize = "OpenCode startup handshake failed. Run :checkhealth draft and verify OpenCode 1.18.34.",
  compatibility = "OpenCode compatibility check failed. Use OpenCode 1.18.34 and run :checkhealth draft.",
  session = "OpenCode could not create a session. Check account access and model settings, then close chat.",
  resume = "OpenCode could not resume this conversation. Close it and use :NvimAIChatNew.",
  model = "OpenCode did not advertise or confirm the selected model. Close chat and choose a model with :NvimAIStageSetup.",
  mode = "OpenCode did not confirm edit mode. Verify OpenCode 1.18.34 with :checkhealth draft.",
  timeout = "OpenCode stopped responding before its deadline. Check connectivity and :checkhealth draft.",
  generation = "OpenCode request failed. Check account access, model settings and connectivity.",
  cleanup = "OpenCode shutdown did not confirm a safe result. Close chat and inspect :checkhealth draft.",
  review = "The generated proposal could not be validated. Inspect the selected files before starting a new conversation.",
}
local DISCONNECTED_REASON =
  "Conversation controller disconnected; cleanup is unconfirmed. Preserve unsaved source edits and your draft, inspect any uncertain writes, then restart Neovim."
for _, fields in pairs(EVENTS) do
  for _, key in ipairs({
    "kind",
    "conversation_id",
    "owner_generation",
    "turn_id",
    "worker_generation",
    "sequence",
  }) do
    fields[key] = true
  end
end
local function message(value)
  return type(value) == "string"
    and #value <= 32768
    and value:find("%S")
    and not value:find("[%z\1-\8\11-\31\127]")
end
local function models(value, provider, chosen)
  if not plain(value) or not vim.islist(value) or #value < 1 or #value > 128 then
    return false
  end
  local seen = {}
  for _, name in ipairs(value) do
    if model(name) ~= provider or seen[name] then
      return false
    end
    seen[name] = true
  end
  return seen[chosen] == true
end
local function fresh_sequence(value, previous)
  return type(value) == "number"
    and value % 1 == 0
    and value > previous
    and value <= 9007199254740991
end
local function opaque(value)
  return type(value) == "string" and #value > 0 and #value <= 128 and value:match("^[%w_-]+$")
end
local function file_states(value, scope, allowed)
  if not plain(value) or not vim.islist(value) or #value ~= #scope then
    return nil
  end
  local bytes = 0
  for index, file in ipairs(value) do
    if
      not keys(file, { path = true, state = true })
      or file.path ~= scope[index]
      or not allowed[file.state]
    then
      return nil
    end
    bytes = bytes + #file.path + #file.state
  end
  return bytes
end
local function proposal_bytes(value, scope)
  if
    not keys(value, { token = true, source_generation = true, files = true })
    or not opaque(value.token)
    or not fresh_sequence(value.source_generation, 0)
  then
    return nil
  end
  local bytes = file_states(value.files, scope, { pending = true, unchanged = true })
  if bytes then
    return bytes + #value.token
  end
end
local function receipt_bytes(value, scope)
  if
    not keys(value, {
      round_id = true,
      proposal_revision = true,
      proposal_token = true,
      sequence = true,
      phase = true,
      decisions = true,
      cleanup_pending = true,
    })
    or not fresh_sequence(value.round_id, 0)
    or not fresh_sequence(value.proposal_revision, 0)
    or not fresh_sequence(value.sequence, 0)
    or not opaque(value.proposal_token)
    or not ({
      review_ready = true,
      applied = true,
      rejected = true,
      cancelled = true,
      partial = true,
      uncertain = true,
      blocked = true,
      conflicted = true,
      already_decided = true,
    })[value.phase]
  then
    return nil
  end
  local bytes = file_states(value.decisions, scope, {
    pending = true,
    accepted = true,
    rejected = true,
    unchanged = true,
    blocked = true,
    uncertain = true,
    cancelled = true,
  })
  if
    not bytes
    or not plain(value.cleanup_pending)
    or not vim.islist(value.cleanup_pending)
    or #value.cleanup_pending > #scope
  then
    return nil
  end
  local seen = {}
  for _, name in ipairs(value.cleanup_pending) do
    if not vim.list_contains(scope, name) or seen[name] then
      return nil
    end
    seen[name], bytes = true, bytes + #name
  end
  return bytes + #value.proposal_token + #value.phase
end
local function review_context(round)
  return {
    round_id = round.id,
    proposal_revision = round.revision,
    proposal_token = round.token,
    receipt_sequence = round.receipt_sequence,
    files = vim.deepcopy(round.files),
  }
end
local function active_review(round)
  return round
    and (
      round.status == "pending"
      or round.status == "revising"
      or round.status == "editing"
      or round.status == "freezing"
    )
end
local function prior_review_bytes(value, scope)
  if
    not keys(value, {
      round_id = true,
      proposal_revision = true,
      proposal_token = true,
      receipt_sequence = true,
      files = true,
      status = true,
      context_valid = true,
    })
    or not fresh_sequence(value.round_id, 0)
    or not fresh_sequence(value.proposal_revision, 0)
    or not fresh_sequence(value.receipt_sequence, -1)
    or not opaque(value.proposal_token)
    or (value.status ~= "active" and value.status ~= "retired")
    or value.context_valid ~= true
  then
    return nil
  end
  local bytes = file_states(
    value.files,
    scope,
    { pending = true, accepted = true, rejected = true, unchanged = true, cancelled = true }
  )
  if bytes then
    return bytes + #value.proposal_token + #value.status
  end
end

function M.new(options)
  if
    not plain(options)
    or (options.backend ~= nil and not ({ codex = true, opencode = true })[options.backend])
    or not path(options.root, true)
    or not selection(options.selection)
    or not model(options.model)
    or type(options.driver) ~= "table"
    or type(options.driver.send) ~= "function"
  then
    return nil, "Invalid conversation scope, model or driver"
  end
  local owner, listeners = {}, {}
  local backend = options.backend or "opencode"
  local startup, diagnostics = vim.deepcopy(STARTUP), vim.deepcopy(DIAGNOSTICS)
  if backend == "codex" then
    for key, value in pairs(startup) do
      startup[key] = value:gsub("OpenCode", "Codex")
    end
    startup.session = "Opening a Codex thread (up to 15 seconds)"
    for key, value in pairs(diagnostics) do
      diagnostics[key] = value:gsub("OpenCode", "Codex"):gsub("1%.18%.34", "0.163.0")
    end
    diagnostics.launch =
      "Codex could not start in its sandbox. Install Codex 0.163.0 with its matching codex-code-mode-host beside the native executable; run :checkhealth draft."
    diagnostics.credentials =
      "Codex credentials could not be loaded. Check chat.auth_file for an API key, or chat.auth_store for a private dedicated login; auth.json must be owned mode 0600."
    diagnostics.auth_support =
      "Dedicated Codex login needs Bubblewrap with --bind-fd and --sync-fd support. Install Bubblewrap 0.11.1, then Retry."
    diagnostics.auth_busy =
      "The dedicated Codex login is already in use. Wait for the other Draft worker to stop, then explicitly Retry or Revise."
    diagnostics.auth_identity =
      "The dedicated Codex login has a missing or different user or workspace identity. Close chat, check the dedicated login, then start a New conversation."
    diagnostics.auth_persistence =
      "Codex credentials could not be validated or saved after shutdown. Close chat and check the dedicated login; a fresh login may be required."
    diagnostics.auth_migrate =
      "Saved ChatGPT tokens can no longer use chat.auth_file. Create a fresh dedicated Codex login and configure chat.auth_store; see :help draft-chat-codex."
    diagnostics.model =
      "Codex did not advertise or confirm the selected model. Check chat.model, then close chat."
    diagnostics.compatibility =
      "Codex compatibility check failed. Use Codex 0.163.0 on a Linux host supporting its nested sandbox; run :checkhealth draft."
  end
  local driver = options.driver
  local lease, sequence, notifying, dispatching = 0, 0, false, false
  local sending, draining, queue, queue_bytes = false, false, {}, 0
  local drain, text_pending
  local transcript_bytes, text_chunks = 0, {}
  local event_count, event_bytes = 0, 0
  local seen_tokens = {}
  local disconnected, disconnect_reported = false, false
  local state = {
    conversation_id = vim.uv.random(16):gsub(".", function(byte)
      return ("%02x"):format(byte:byte())
    end),
    owner_generation = 1,
    turn_id = 0,
    worker_generation = 0,
    view_revision = 1,
    phase = "idle",
    root = options.root,
    backend = backend,
    selection = vim.deepcopy(options.selection),
    desired_model = options.model,
    provider = model(options.model),
    available_models = { options.model },
    turns = {},
    rounds = {},
    manual_revisions = 0,
    retry_safe = false,
    recovery_required = false,
  }

  local function flush_text()
    if #text_chunks > 0 then
      local turn = state.turns[#state.turns]
      turn.text = turn.text .. table.concat(text_chunks)
      text_chunks = {}
    end
  end

  function owner:snapshot()
    flush_text()
    return vim.deepcopy(state)
  end

  local function notify()
    local pending = vim.list_extend({}, listeners)
    notifying = true
    for _, registration in ipairs(pending) do
      if registration.callback then
        pcall(registration.callback, owner:snapshot())
      end
    end
    notifying = false
    drain()
  end

  local function changed(authority)
    if authority == false then
      -- Display-only traffic cannot invalidate a Cancel/Close view revision.
      if not text_pending then
        text_pending = true
        vim.schedule(function()
          if text_pending then
            text_pending = false
            notify()
          end
        end)
      end
      return
    end
    text_pending = false
    state.view_revision = state.view_revision + 1
    notify()
  end

  local function fail(reason)
    lease = lease + 1
    if state.review then
      local intent = state.pending_decision
      state.review.status = "recovery_required"
      for _, file in ipairs(state.review.files) do
        if file.state == "pending" then
          file.state = intent
              and intent.choice == "approve"
              and (intent.remaining or file.path == intent.path)
              and "uncertain"
            or "blocked"
        end
      end
      state.publication_recovery, state.pending_decision = true, nil
    end
    state.phase, state.retry_safe, state.recovery_required = "failed", false, true
    state.startup = nil
    state.correction = nil
    state.reason = reason
    local turn = state.turns[#state.turns]
    if turn and turn.status == "running" then
      turn.status = "failed"
    end
    changed()
    return nil, reason
  end

  local function report_disconnect()
    if disconnect_reported or state.phase == "closed" then
      return
    end
    disconnect_reported = true
    fail(DISCONNECTED_REASON)
  end

  local function on_disconnect()
    if disconnected or state.phase == "closed" then
      return
    end
    disconnected = true
    if sending or notifying or draining or dispatching or vim.in_fast_event() then
      vim.schedule(report_disconnect)
    else
      report_disconnect()
    end
  end

  local function decision_result(receipt)
    -- Validate the entire receipt before mutating any confirmed file outcome.
    local round, intent = state.review, state.pending_decision
    if
      not receipt_bytes(receipt, state.selection)
      or receipt.round_id ~= round.id
      or receipt.proposal_revision ~= round.revision
      or receipt.proposal_token ~= round.token
      or receipt.sequence ~= round.receipt_sequence + 1
    then
      return nil
    end
    local failed = receipt.phase ~= "review_ready"
      and receipt.phase ~= "applied"
      and receipt.phase ~= "rejected"
      and receipt.phase ~= "cancelled"
    local pending, accepted = false, false
    for index, prior in ipairs(round.files) do
      local expected = prior.state
      local selected = intent.choice == "cancel" or intent.remaining or prior.path == intent.path
      if prior.state == "pending" and selected then
        expected = intent.choice == "approve" and "accepted"
          or intent.choice == "cancel" and "cancelled"
          or "rejected"
      end
      local actual = receipt.decisions[index].state
      if failed and prior.state == "pending" then
        if
          actual ~= "blocked"
          and actual ~= "uncertain"
          and not (selected and actual == expected)
        then
          return nil
        end
      elseif actual ~= expected then
        return nil
      end
      pending, accepted = pending or actual == "pending", accepted or actual == "accepted"
    end
    local phase = intent.choice == "cancel" and "cancelled"
      or pending and "review_ready"
      or accepted and "applied"
      or "rejected"
    if not failed and receipt.phase ~= phase then
      return nil
    end
    round.files, round.receipt_sequence = vim.deepcopy(receipt.decisions), receipt.sequence
    round.cleanup_pending = round.cleanup_pending or {}
    for _, name in ipairs(receipt.cleanup_pending) do
      if not vim.list_contains(round.cleanup_pending, name) then
        table.insert(round.cleanup_pending, name)
      end
    end
    round.status, state.phase = pending and "pending" or "settled", pending and "review" or "idle"
    if intent.choice == "cancel" and not failed then
      round.status = "cancelled"
    end
    if intent.choice == "approve" and pending then
      for step = 1, #round.files - 1 do
        local index = (round.current_index - 1 + step) % #round.files + 1
        if round.files[index].state == "pending" then
          round.current_index = index
          break
        end
      end
    end
    if not pending and not failed then
      state.review = nil
    end
    state.pending_decision = nil
    return true, failed
  end

  local function prior_matches(evidence, status)
    -- context_valid is the trusted adapter's post-worker source/buffer/frozen
    -- revalidation result. It is never accepted from ACP or inferred from text.
    local round, turn = state.review, state.turns[#state.turns]
    local correction = state.correction
    if
      not round
      or not (correction and round.status == "freezing" or turn.followup and round.status == "revising")
      or not prior_review_bytes(evidence, state.selection)
      or evidence.status ~= status
    then
      return false
    end
    local context = review_context(round)
    return vim.deep_equal(correction and correction.context or turn.context, context)
      and evidence.round_id == context.round_id
      and evidence.proposal_revision == context.proposal_revision
      and evidence.proposal_token == context.proposal_token
      and evidence.receipt_sequence == context.receipt_sequence
      and vim.deep_equal(evidence.files, context.files)
  end

  local function replace_review(event, manual)
    if not prior_matches(event.prior_review, "retired") or seen_tokens[event.proposal.token] then
      return nil
    end
    local round, turn = state.review, state.turns[#state.turns]
    local candidate, first = vim.deepcopy(event.proposal.files), nil
    for index, old in ipairs(round.files) do
      if old.state ~= "pending" then
        if candidate[index].state ~= "unchanged" then
          return nil
        end
        candidate[index].state = old.state
      elseif candidate[index].state == "pending" and not first then
        first = index
      end
    end
    -- Never copy the history into itself: one bounded record per replacement.
    round.history = round.history or {}
    round.history[#round.history + 1] = {
      token = round.token,
      revision = round.revision,
      source_generation = round.source_generation,
      turn_id = round.turn_id,
      model = round.model,
      origin = round.origin,
      receipt_sequence = round.receipt_sequence,
      files = vim.deepcopy(round.files),
      status = "superseded",
    }
    seen_tokens[event.proposal.token] = true
    -- The replacement has a fresh writer journal; the token/revision fences old receipts.
    round.token, round.revision, round.receipt_sequence =
      event.proposal.token, round.revision + 1, 0
    round.source_generation = event.proposal.source_generation
    round.turn_id = manual and round.turn_id or turn.id
    round.origin = manual and "manual" or nil
    if manual then
      round.model = nil
    else
      round.model = turn.model
      turn.proposal_revision = round.revision
    end
    round.files, round.current_index, round.status =
      candidate, first, first and "pending" or "settled"
    state.phase = first and "review" or "idle"
    if not first then
      state.review = nil
    end
    return true
  end

  local function receive(current, event)
    if
      current ~= lease
      or not plain(event)
      or event.conversation_id ~= state.conversation_id
      or event.owner_generation ~= state.owner_generation
      or event.turn_id ~= state.turn_id
      or event.worker_generation ~= state.worker_generation
      or not fresh_sequence(event.sequence, sequence)
    then
      return nil, "Stale conversation event"
    end
    if not EVENTS[event.kind] or not keys(event, EVENTS[event.kind]) then
      return fail("Invalid conversation event; explicit recovery required")
    end
    if
      event.diagnostic ~= nil
      and (
        event.outcome ~= "failed"
        or type(event.diagnostic) ~= "string"
        or not diagnostics[event.diagnostic]
      )
    then
      return fail("Invalid conversation diagnostic; explicit recovery required")
    end
    local turn = state.turns[#state.turns]
    if
      event.kind == "settled"
      and event.candidates_retired ~= nil
      and (event.candidates_retired ~= true or event.outcome == "review")
    then
      return fail("Contradictory candidate retirement evidence")
    end
    if
      event.prior_review ~= nil
      and not (state.review and (state.correction or turn and turn.followup))
    then
      return fail("Unexpected predecessor review evidence")
    end
    if event.kind == "corrected" and state.phase == "freezing" and state.correction then
      if event.outcome == "review" then
        if
          not proposal_bytes(event.proposal, state.selection)
          or event.proposal.source_generation ~= state.review.source_generation
          or event.candidates_retired ~= nil
          or state.manual_revisions >= 64
          or not replace_review(event, true)
        then
          return fail("Manual replacement handoff is unproven; explicit recovery required")
        end
        state.manual_revisions = state.manual_revisions + 1
        state.correction, state.reason = nil, nil
      elseif
        (event.outcome == "unchanged" or event.outcome == "refused")
        and event.proposal == nil
        and event.candidates_retired == true
        and prior_matches(event.prior_review, "active")
      then
        if event.outcome == "unchanged" then
          state.phase, state.review.status, state.correction = "review", "pending", nil
          state.reason = "Correction is unchanged; the original frozen review remains available"
        else
          state.phase, state.review.status = "editing", "editing"
          state.reason =
            "Correction could not be frozen; draft retained. Check text and proposal limits."
        end
      else
        return fail("Correction eligibility or cleanup is unproven; explicit recovery required")
      end
      lease = lease + 1
    elseif event.kind == "decided" and state.phase == "publishing" then
      if event.sources_valid ~= nil and type(event.sources_valid) ~= "boolean" then
        return fail("Invalid editor source validation")
      end
      local valid, failed = decision_result(event.receipt)
      if not valid then
        return fail("Invalid decision receipt; explicit recovery required")
      end
      if failed then
        return fail("Writer outcome requires recovery; confirmed file decisions are retained")
      end
      if event.sources_valid == false then
        state.publication_recovery = true
        return fail(
          "Accepted source buffers require recovery; confirmed file decisions are retained"
        )
      end
      lease = lease + 1
    elseif event.kind == "startup" and state.phase == "starting" then
      if type(event.stage) ~= "string" or not startup[event.stage] then
        return fail("Invalid startup progress; explicit recovery required")
      end
      state.startup = startup[event.stage]
    elseif
      event.kind == "submitted"
      and state.phase == "starting"
      and event.model == state.desired_model
    then
      local advertised = event.models or { event.model }
      if not models(advertised, state.provider, event.model) then
        return fail("Invalid confirmed model options")
      end
      state.available_models = vim.deepcopy(advertised)
      state.phase, state.confirmed_model = "generating", event.model
      state.startup = nil
      turn.model, turn.submission = event.model, "submitted"
    elseif
      event.kind == "text"
      and state.phase == "generating"
      and type(event.text) == "string"
    then
      local text = event.text:gsub("[%z\1-\8\11-\31\127]", "")
      if transcript_bytes + #text > MAX_BYTES then
        return fail("Conversation display limit reached; explicit recovery required")
      end
      transcript_bytes = transcript_bytes + #text
      text_chunks[#text_chunks + 1] = text
    elseif event.kind == "progress" and state.phase == "generating" then
      if
        type(event.tool_id) ~= "string"
        or #event.tool_id == 0
        or #event.tool_id > 256
        or type(event.title) ~= "string"
        or #event.title == 0
        or #event.title > 256
        or not ({
          pending = true,
          in_progress = true,
          completed = true,
          failed = true,
          cancelled = true,
        })[event.status]
      then
        return fail("Invalid tool progress; explicit recovery required")
      end
      turn.progress = {
        tool_id = event.tool_id,
        title = event.title:gsub("[%z\1-\31\127]", ""),
        status = event.status,
      }
    elseif
      event.kind == "stopping" and (state.phase == "generating" or state.phase == "starting")
    then
      state.phase = "stopping"
      state.startup = nil
    elseif event.kind == "settled" and state.phase == "stopping" and event.outcome == "failed" then
      if event.proposal ~= nil then
        return fail("Failed turn cannot carry a frozen proposal")
      end
      if turn.followup then
        local submission = turn.submission == "submitted" and "submitted" or "not_submitted"
        if
          event.stopped ~= true
          or event.graceful ~= true
          or event.store_valid ~= true
          or event.tokens_retired ~= nil
          or event.submission ~= submission
          or event.candidates_retired ~= true
          or not prior_matches(event.prior_review, "active")
        then
          return fail("Follow-up recovery has not been proved")
        end
        state.review.status, state.phase = "pending", "review"
        state.retry_safe, state.recovery_required = false, false
        state.reason =
          "Follow-up failed; the previous review was positively revalidated. No automatic retry."
        turn.submission = submission
      else
        local safe = event.stopped == true
          and event.graceful == true
          and event.store_valid == true
          and event.tokens_retired == true
          and event.submission == "not_submitted"
          and turn.submission ~= "submitted"
        state.phase, state.retry_safe, state.recovery_required = "failed", safe, not safe
        state.reason = safe and "Request not submitted; an explicit new retry is allowed"
          or "Failed turn requires explicit recovery"
        if safe then
          turn.submission = "not_submitted"
        end
      end
      turn.status = "failed"
      if event.diagnostic then
        state.reason = diagnostics[event.diagnostic] .. " " .. state.reason
      end
      lease = lease + 1
    elseif
      event.kind == "settled"
      and state.phase == "stopping"
      and (event.outcome == "answer" or event.outcome == "review")
      and event.stopped == true
      and event.graceful == true
      and event.store_valid == true
      and (event.tokens_retired == nil or event.tokens_retired == true)
      and (event.submission == nil or event.submission == "submitted")
      and turn.submission == "submitted"
      and turn.model == turn.requested_model
    then
      if event.outcome == "review" then
        if
          not proposal_bytes(event.proposal, state.selection)
          or event.proposal.source_generation ~= turn.id
          or event.tokens_retired ~= nil
        then
          return fail("Invalid frozen proposal evidence")
        end
        local first
        for index, file in ipairs(event.proposal.files) do
          if file.state == "pending" and not first then
            first = index
          end
        end
        if seen_tokens[event.proposal.token] then
          return fail("Proposal token was already used")
        end
        if turn.followup then
          if not replace_review(event) then
            return fail("Replacement handoff is unproven; explicit recovery required")
          end
        else
          if not first then
            return fail("Review requires a pending frozen change")
          end
          local round = vim.deepcopy(event.proposal)
          round.id, round.revision, round.receipt_sequence = #state.rounds + 1, 1, 0
          round.status, round.current_index, round.model, round.turn_id =
            "pending", first, turn.model, turn.id
          state.rounds[#state.rounds + 1], state.review, state.phase = round, round, "review"
          turn.round_id = round.id
          seen_tokens[round.token] = true
        end
      else
        if event.proposal ~= nil then
          return fail("Answer cannot carry an unreviewed proposal")
        end
        if turn.followup then
          if
            event.tokens_retired ~= nil
            or event.candidates_retired ~= true
            or not prior_matches(event.prior_review, "active")
          then
            return fail("Follow-up review eligibility has not been proved")
          end
          state.review.status, state.phase = "pending", "review"
        else
          state.phase = "idle"
        end
      end
      turn.status = "completed"
      lease = lease + 1
    elseif
      event.kind == "cancelled"
      and state.phase == "cancelling"
      and event.stopped == true
      and event.graceful == true
      and event.store_valid == true
      and event.tokens_retired == true
      and (not turn or turn.status ~= "running" or event.cancel_confirmed == true)
      and (event.cancel_confirmed == nil or event.cancel_confirmed == true)
      and (event.candidates_retired == nil or event.candidates_retired == true)
      and (not (turn and turn.followup) or event.candidates_retired == true)
      and (not state.correction or event.candidates_retired == true)
    then
      if state.review then
        local valid, failed = decision_result(event.receipt)
        if not valid or failed then
          return fail("Pending review retirement is unproven")
        end
      elseif event.receipt ~= nil then
        return fail("Unexpected review retirement receipt")
      end
      state.phase = "idle"
      state.correction = nil
      if turn and turn.status == "running" then
        turn.status = "cancelled"
      end
      lease = lease + 1
    elseif
      event.kind == "closed"
      and state.phase == "closing"
      and event.stopped == true
      and event.cleaned == true
      and event.tokens_retired == true
      and (event.writer_stopped == nil or event.writer_stopped == true)
      and (not (state.review or state.publication_recovery) or event.writer_stopped == true)
      and (event.candidates_retired == nil or event.candidates_retired == true)
      and (not (turn and turn.followup) or event.candidates_retired == true)
      and (not state.correction or event.candidates_retired == true)
    then
      if active_review(state.review) then
        local valid, failed = decision_result(event.receipt)
        if not valid or failed then
          return fail("Close did not prove pending review retirement")
        end
      elseif event.receipt ~= nil then
        return fail("Unexpected close decision receipt")
      end
      state.phase = "closed"
      state.correction = nil
      state.retry_safe, state.recovery_required = false, state.publication_recovery == true
      state.reason = state.publication_recovery
          and "Backend closed; publication evidence still requires recovery"
        or nil
      if turn and turn.status == "running" then
        turn.status = "cancelled"
      end
      lease = lease + 1
    else
      return fail("Conversation outcome is unproven; explicit recovery required")
    end
    sequence = event.sequence
    changed(event.kind ~= "text" and event.kind ~= "startup")
    return true
  end

  drain = function()
    if sending or notifying or draining then
      return
    end
    draining = true
    local index = 1
    while index <= #queue do
      local item = queue[index]
      if disconnected or item.lease ~= lease then
        item.ok, item.reason = nil, "Stale conversation event"
      elseif item.invalid then
        item.ok, item.reason = fail("Invalid or excessive conversation event")
      else
        item.ok, item.reason = receive(item.lease, item.event)
      end
      index = index + 1
    end
    queue, queue_bytes, draining = {}, 0, false
  end

  local function offer(current, event)
    if
      disconnected
      or current ~= lease
      or not plain(event)
      or event.conversation_id ~= state.conversation_id
      or event.owner_generation ~= state.owner_generation
      or event.turn_id ~= state.turn_id
      or event.worker_generation ~= state.worker_generation
      or not fresh_sequence(event.sequence, sequence)
    then
      return nil, "Stale conversation event"
    end
    local valid = EVENTS[event.kind] and keys(event, EVENTS[event.kind])
    local bytes = 0
    if valid then
      for key, value in pairs(event) do
        if key == "prior_review" then
          local size = prior_review_bytes(value, state.selection)
          valid = size ~= nil
          bytes = bytes + (size or 0)
        elseif key == "proposal" then
          local size = proposal_bytes(value, state.selection)
          valid = size ~= nil
          bytes = bytes + (size or 0)
        elseif key == "receipt" then
          local size = receipt_bytes(value, state.selection)
          valid = size ~= nil
          bytes = bytes + (size or 0)
        elseif key == "models" then
          valid = models(value, state.provider, event.model)
          if valid then
            for _, name in ipairs(value) do
              bytes = bytes + #name
            end
          end
        elseif type(value) == "string" then
          bytes = bytes + #value
          valid = #value <= (key == "text" and 1024 * 1024 or 4096)
        else
          valid = type(value) == "boolean" or type(value) == "number"
        end
        if not valid then
          break
        end
      end
    end
    event_count, event_bytes = event_count + 1, event_bytes + bytes
    local item = {
      lease = current,
      invalid = not valid
        or #queue >= MAX_EVENTS
        or queue_bytes + bytes > MAX_BYTES
        or event_count > MAX_EVENTS
        or event_bytes > MAX_BYTES,
    }
    if not item.invalid then
      item.event, queue_bytes = vim.deepcopy(event), queue_bytes + bytes
    end
    -- Keep at most one overflow marker; never copy unbounded rejected bodies.
    if #queue > MAX_EVENTS then
      return nil, "Conversation event queue exceeded"
    end
    queue[#queue + 1] = item
    local buffered = sending or notifying or draining
    drain()
    if buffered then
      return true
    end
    return item.ok, item.reason
  end

  function owner:subscribe(listener)
    if type(listener) ~= "function" then
      return nil, "Invalid conversation listener"
    end
    local registration = { callback = listener }
    listeners[#listeners + 1] = registration
    return function()
      if not registration.callback then
        return
      end
      registration.callback = nil
      for index, active in ipairs(listeners) do
        if active == registration then
          table.remove(listeners, index)
          break
        end
      end
    end
  end

  local function review_matches(action)
    return state.review
      and action.round_id == state.review.id
      and action.proposal_revision == state.review.revision
      and action.proposal_token == state.review.token
  end

  local function command_binding(kind)
    return {
      kind = kind,
      conversation_id = state.conversation_id,
      owner_generation = state.owner_generation,
      turn_id = state.turn_id,
      worker_generation = state.worker_generation,
      root = state.root,
      selection = vim.deepcopy(state.selection),
      model = state.desired_model,
    }
  end

  function owner:dispatch(action, revision)
    if notifying or dispatching then
      return nil, "Conversation is handling a callback"
    end
    if revision ~= state.view_revision then
      return nil, "Stale conversation view"
    end
    if not plain(action) or not ACTIONS[action.kind] or not keys(action, ACTIONS[action.kind]) then
      return nil, "Invalid conversation action"
    end
    if action.kind == "choose-model" then
      if state.phase ~= "idle" or not vim.list_contains(state.available_models, action.model) then
        return nil, "Model choice requires an advertised model and an idle conversation"
      end
      state.desired_model = action.model
      changed()
      return true
    end
    if action.kind == "edit-proposal" then
      local pending = false
      if
        state.phase == "review"
        and review_matches(action)
        and state.review.status == "pending"
        and #(state.review.cleanup_pending or {}) == 0
        and type(action.seed_sha256) == "string"
        and #action.seed_sha256 == 64
        and action.seed_sha256:match("^[a-f0-9]+$")
      then
        for _, file in ipairs(state.review.files) do
          pending = pending or file.path == action.path and file.state == "pending"
        end
      end
      if not pending then
        return nil, "Only a current pending proposal can be edited"
      end
      state.correction = {
        path = action.path,
        seed_sha256 = action.seed_sha256,
        context = review_context(state.review),
      }
      state.phase, state.review.status, state.reason = "editing", "editing", nil
      changed()
      return true
    elseif action.kind == "discard-correction" then
      if state.phase ~= "editing" or not state.correction then
        return nil, "No editable correction can be discarded"
      end
      state.phase, state.review.status, state.correction, state.reason =
        "review", "pending", nil, nil
      changed()
      return true
    end
    local correction = action.kind == "correct"
      and state.phase == "editing"
      and state.correction
      and review_matches(action)
      and action.path == state.correction.path
      and require("ai.staged_sources").valid_text(action.replacement)
    local correction_command
    if correction then
      if
        state.manual_revisions >= 64
        and vim.fn.sha256(action.replacement) ~= state.correction.seed_sha256
      then
        return nil, "Manual revision limit reached; discard or freeze an unchanged draft"
      end
      correction_command = command_binding("correct")
      for key, value in pairs(state.correction.context) do
        if key ~= "files" then
          correction_command[key] = value
        end
      end
      correction_command.context = vim.deepcopy(state.correction.context)
      correction_command.path, correction_command.replacement = action.path, action.replacement
      if type(driver.preflight) ~= "function" then
        return nil, "Correction preflight is unavailable"
      end
      local ready, reason = driver:preflight(correction_command)
      if not ready then
        return nil, reason
      end
    end
    local followup = action.kind == "revise"
      and state.phase == "review"
      and action.round_id == state.review.id
      and action.proposal_revision == state.review.revision
      and action.proposal_token == state.review.token
      and state.review.status == "pending"
      and #(state.review.cleanup_pending or {}) == 0
    local submit = (
      (action.kind == "submit" and state.phase == "idle")
      or (action.kind == "retry" and state.phase == "failed" and state.retry_safe)
      or followup
    ) and message(action.text)
    local cancel = action.kind == "cancel"
      and (
        state.phase == "starting"
        or state.phase == "generating"
        or state.phase == "review"
        or state.phase == "editing"
        or state.phase == "freezing"
      )
    local close = action.kind == "close"
      and state.phase ~= "closed"
      and state.phase ~= "closing"
      and state.phase ~= "publishing"
    local target
    if
      action.kind == "decide"
      and state.phase == "review"
      and state.review.status == "pending"
      and action.round_id == state.review.id
      and action.proposal_revision == state.review.revision
      and action.proposal_token == state.review.token
      and (action.choice == "approve" or action.choice == "reject")
      and (
        (action.remaining == true and action.path == nil)
        or (action.remaining == nil and action.path ~= nil)
      )
    then
      for index, file in ipairs(state.review.files) do
        if
          not target
          and file.state == "pending"
          and (action.remaining or file.path == action.path)
        then
          target = index
        end
      end
    end
    if not submit and not cancel and not close and not target and not correction then
      return nil, "Unsupported conversation action"
    end
    if submit and #state.turns >= 64 then
      return nil, "Conversation turn limit reached; close or explicitly start a new conversation"
    end
    if submit and transcript_bytes + #action.text > MAX_BYTES then
      return nil, "Conversation display limit reached; close or explicitly start a new conversation"
    end
    dispatching = true
    if submit then
      flush_text()
      transcript_bytes = transcript_bytes + #action.text
      state.turn_id, state.worker_generation = state.turn_id + 1, state.worker_generation + 1
      state.phase = "starting"
      state.startup = "Starting the conversation controller"
      state.retry_safe, state.recovery_required, state.reason = false, false, nil
      state.turns[#state.turns + 1] = {
        id = state.turn_id,
        prompt = action.text,
        text = "",
        status = "running",
        submission = "possibly_submitted",
        requested_model = state.desired_model,
      }
      if followup then
        local turn = state.turns[#state.turns]
        turn.followup, turn.round_id, turn.context =
          true, state.review.id, review_context(state.review)
        state.review.status = "revising"
      end
    elseif correction then
      state.phase, state.review.status, state.reason = "freezing", "freezing", nil
    elseif target then
      state.phase, state.review.current_index = "publishing", target
      state.pending_decision =
        { choice = action.choice, path = action.path, remaining = action.remaining }
    else
      state.phase = close and "closing" or "cancelling"
      state.startup = nil
      if active_review(state.review) then
        state.pending_decision = { choice = "cancel" }
      end
    end
    lease = lease + 1
    -- A high-water mark or exhausted turn budget must not block cleanup proof.
    sequence, event_count, event_bytes = 0, 0, 0
    local current = lease
    local command = correction_command
      or command_binding(
        followup and "revise"
          or submit and "start"
          or target and "decide"
          or close and "close"
          or "cancel"
      )
    command.message = action.text
    if followup then
      command.context = vim.deepcopy(state.turns[#state.turns].context)
    end
    if state.review then
      if target then
        command.choice, command.path = action.choice, action.path
        command.remaining = action.remaining
      end
      command.round_id, command.proposal_revision, command.proposal_token =
        state.review.id, state.review.revision, state.review.token
      command.receipt_sequence = state.review.receipt_sequence
    end
    changed()
    sending = true
    local ok, accepted = pcall(driver.send, driver, command, function(event)
      return offer(current, event)
    end, on_disconnect)
    sending = false
    if disconnected then
      queue, queue_bytes = {}, 0
      report_disconnect()
      -- A later explicit close cannot silently reopen a permanently lost owner.
      if state.phase ~= "failed" then
        fail(DISCONNECTED_REASON)
      end
    elseif not ok or accepted ~= true then
      queue, queue_bytes = {}, 0
      fail("Conversation driver failed; submission or cleanup may have occurred")
    else
      drain()
    end
    dispatching = false
    return true
  end

  return owner
end

return M
