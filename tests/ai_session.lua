-- Coordinator tests use the transport/store/backend/sandbox seams specified by Task 5.
local function eq(actual, expected, label)
  assert(vim.deep_equal(actual, expected), label .. "\n" .. vim.inspect(actual))
end

local identity = {
  key = string.rep("a", 32),
  root = "/work/repo",
  namespace = "tmux:/private/ai.sock:41:9001",
  owner_pane = "%12",
  tmux_socket = "/private/ai.sock",
}
local uuid = "11111111-1111-4111-8111-111111111111"
local function fixture()
  local f = {
    launches = {},
    processes = {},
    tags = {},
    confirmations = {},
    notifications = {},
    failures = {},
  }
  local function failing(operation)
    local count = f.failures[operation] or 0
    if count == 0 then
      return false
    end
    f.failures[operation] = count - 1
    return true
  end
  f.record = {
    schema = 1,
    identity = {
      key = identity.key,
      root = identity.root,
      namespace = identity.namespace,
      owner_pane = identity.owner_pane,
    },
    active_backend = "claude",
    sessions = { codex = "last", claude = uuid, opencode = "" },
    grants = {},
    review_id = vim.NIL,
    opencode_profile = vim.NIL,
  }
  f.store = {
    read_record = function()
      if f.read_error then
        return nil, f.read_error
      end
      return vim.deepcopy(f.record)
    end,
    write_record = function(_, record)
      if failing("write") then
        return nil, "secret write failure", false
      end
      f.record = vim.deepcopy(record)
      return true
    end,
    runtime_root = function()
      return "/private/run"
    end,
    runtime_dir = function()
      return "/private/run/" .. identity.key
    end,
    state_root = function()
      return "/private/state"
    end,
    launch_paths = function(_, backend)
      return {
        context_dir = "/private/run/contexts",
        backend_state = "/private/state/" .. backend,
        control_socket = "/private/run/control.sock",
        event_file = "/private/state/" .. backend .. "/events.jsonl",
      }
    end,
    read_control_token = function()
      return f.control_token
    end,
    ensure_control_token = function(_, factory)
      f.control_token = f.control_token or factory()
      return f.control_token
    end,
    write_launch = function(_, manifest)
      return "/private/run/launches/" .. manifest.token .. ".json"
    end,
    remove_launch = function()
      f.removed_launches = (f.removed_launches or 0) + 1
      return true
    end,
    remove_control_token = function()
      f.control_token = nil
      return true
    end,
    cleanup_contexts = function()
      return true
    end,
    cleanup_launches = function()
      return true
    end,
  }
  f.transport = {
    discover = function()
      return vim.deepcopy(f.panes or {})
    end,
    owned_panes = function()
      local result = {}
      for _, candidate in ipairs(f.panes or {}) do
        if
          candidate.key ~= identity.key
          or candidate.owner ~= identity.owner_pane
          or candidate.root ~= identity.root
        then
          return nil
        end
        result[#result + 1] = {
          pane = candidate.pane,
          key = candidate.key,
          owner = candidate.owner,
          root = candidate.root,
        }
      end
      return result
    end,
    create = function(_, _, invocation)
      if failing("create") then
        return nil, "secret create failure", "not_started"
      end
      f.processes[#f.processes + 1] = invocation
      f.pane = "%40"
      return f.pane
    end,
    tag = function(_, pane, data)
      if failing(data.state == "starting" and "stage_tag" or "tag") then
        return nil, "secret tag failure"
      end
      eq(pane, f.pane, "only owned pane is tagged")
      f.tags[#f.tags + 1] = vim.deepcopy(data)
      f.panes = { vim.tbl_extend("force", { pane = pane }, data) }
      return true
    end,
    focus = function(_, pane)
      f.focused = pane
      return true
    end,
    respawn = function(_, pane, invocation, policy)
      eq(pane, f.pane, "relaunch reuses the exact owned pane")
      assert(
        policy.timeout == 2000 and (policy.signal == 1 or policy.signal == 15),
        "relaunch uses bounded lifecycle policy"
      )
      f.respawns = (f.respawns or 0) + 1
      if failing("respawn") then
        return nil, "secret respawn failure", "not_started"
      end
      f.processes[#f.processes + 1] = invocation
      return true
    end,
    close = function(_, pane, policy)
      if failing("close") then
        return nil, "secret close failure"
      end
      eq(pane, f.pane, "close removes only owned pane")
      eq(policy, { signal = 15, timeout = 2000 }, "explicit close uses stop policy")
      f.closed = (f.closed or 0) + 1
      f.panes = {}
      return true
    end,
    shutdown = function()
      return true
    end,
    paste = function(_, _, text)
      f.pasted = text
      return true
    end,
  }
  f.adapters = {}
  for _, backend in ipairs({ "codex", "claude", "opencode" }) do
    local function build(_, _, paths, session)
      f.backend_paths = vim.deepcopy(paths)
      return {
        backend = backend,
        session = session or (backend == "claude" and uuid or backend == "codex" and "last" or ""),
      }
    end
    f.adapters[backend] = {
      new_session = build,
      resume_session = build,
      session_reference = function(_, launch)
        local ref = launch.session
        return (
          backend == "claude" and ref == uuid
          or backend == "codex" and ref == "last"
          or backend == "opencode" and (ref == "" or ref:match("^ses_[A-Za-z0-9_-]+$"))
        )
            and ref
          or ""
      end,
      capabilities = function()
        return { busy = backend ~= "codex" }
      end,
      suspend = function()
        return { signal = 1, timeout = 2000 }
      end,
      stop = function()
        return { signal = 15, timeout = 2000 }
      end,
    }
  end
  f.adapters.opencode.profile_reference = function()
    return f.backend_paths.opencode_profile
      or { token = string.rep("b", 32), fingerprint = string.rep("c", 64), version = "1.18.30" }
  end
  f.adapters.opencode.validate_profile = function(_, reference, actual_identity, paths)
    eq(actual_identity.root, identity.root, "reconnect inspects exact physical root")
    eq(reference, f.record.opencode_profile, "reconnect inspects durable generation")
    if f.profile_error then
      return nil, f.profile_error
    end
    return true
  end
  f.registry = {
    get = function(_, name)
      return f.adapters[name]
    end,
    health = function()
      return {
        installed = not failing("health"),
        version = "1.0.0",
        auth = "authenticated",
        error = "",
      }
    end,
  }
  f.sandbox = {
    prepare = function(options)
      if failing("sandbox") then
        return nil, "secret sandbox failure"
      end
      f.launches[#f.launches + 1] = vim.deepcopy(options)
      local path = assert(options.write_manifest({ token = options.token }))
      return { token = options.token, path = path, command = "managed", argv = { "managed" } }
    end,
  }
  f.options = {
    identity = identity,
    transport = f.transport,
    registry = f.registry,
    store = f.store,
    sandbox = f.sandbox,
    home = vim.env.HOME,
    tools = {
      python = "/usr/bin/python3",
      bwrap = "/usr/bin/bwrap",
      shell = "/usr/bin/bash",
      git = "/usr/bin/git",
      tmux = "/usr/bin/tmux",
    },
    helpers = {
      launcher = "/config/launch.py",
      review_helper = "/config/review.py",
      control_helper = "/config/control.py",
      event_helper = "/config/event.py",
      profile_helper = "/config/profile.py",
    },
    token = function()
      return string.rep("d", 32)
    end,
    confirm = function(message)
      f.confirmations[#f.confirmations + 1] = message
      return f.confirmed ~= false
    end,
    notify = function(message)
      f.notifications[#f.notifications + 1] = message
    end,
  }
  f.coordinator = assert(require("ai.session").new(f.options))
  return f
end

do
  for _, state in ipairs({
    "open",
    "idle",
    "busy",
    "approval",
    "completed",
    "attention",
    "changes",
    "conflicted",
    "paused",
    "starting",
  }) do
    local f = fixture()
    f.adapters.claude.capabilities = function()
      return { busy = true, approval = true, completion = true }
    end
    assert(f.coordinator:open("claude"))
    local function event(value)
      return { schema = 1, backend = "claude", session = uuid, state = value, time = 1 }
    end
    if state == "approval" then
      assert(f.coordinator:handle_event(event("busy")))
    end
    if
      ({ attention = true, changes = true, conflicted = true, paused = true, starting = true })[state]
    then
      f.panes[1].state = state
      assert(f.coordinator:attach(), "adopt a verified pane with saved display state")
    elseif state ~= "open" then
      assert(f.coordinator:handle_event(event(state)))
    end
    local observed = {}
    f.coordinator:subscribe(function(snapshot)
      observed[#observed + 1] = snapshot.state
    end)
    local close = f.transport.close
    f.transport.close = function(...)
      eq(f.coordinator:handle_event(event("failed")), nil, "expected stop event is ignored")
      eq(f.coordinator:paste("no replay"), nil, "closing rejects concurrent input")
      eq(f.coordinator:close(), nil, "closing rejects reentrant close")
      return close(...)
    end
    assert(f.coordinator:close())
    eq(f.coordinator:snapshot().state, "closed", "intentional close completes from " .. state)
    eq(observed, { "closed" }, "intentional close does not pass through failure from " .. state)
    eq(f.closed, 1, "close stops only the expected owned process")
  end
end

do
  local f = fixture()
  assert(f.coordinator:open("opencode"))
  f.panes[1].opencode_version = "1.18.18"
  local reopened = assert(require("ai.session").new(f.options))
  assert(not reopened:attach())
  f.confirmed = false
  assert(not reopened:close(), "refused attach requires explicit confirmation to close")
  eq(f.closed, nil, "declined restart leaves process alone")
  f.confirmed = true
  assert(reopened:close())
  eq(f.closed, 1, "confirmed stale-profile close stops exactly one pane")
  assert(reopened:open("opencode"))
  eq(f.backend_paths.opencode_profile, nil, "explicit reopen builds a fresh generation")
  eq(f.record.opencode_profile.version, "1.18.30", "fresh profile replaces stale reference")
end

do
  local f = fixture()
  assert(f.coordinator:open("opencode"))
  f.panes[1].opencode_version = "1.18.28"
  f.record.opencode_profile.version = "1.18.28"
  f.record.sessions.opencode = "ses_before_upgrade"
  f.record.review_id = "review_abc123"
  f.record.completed_review_id = "review_def456"
  local saved_sessions = vim.deepcopy(f.record.sessions)
  local reopened = assert(require("ai.session").new(f.options))
  assert(not reopened:attach(), "old audited pane is not silently adopted")
  f.confirmed = false
  assert(not reopened:close(), "upgrade recovery needs explicit close confirmation")
  eq(f.closed, nil, "declining recovery leaves the pane running")
  eq(f.record.opencode_profile.version, "1.18.28", "declining preserves the old reference")
  f.confirmed = true
  assert(reopened:close())
  eq(f.record.opencode_profile, vim.NIL, "close clears the old generation reference")
  eq(f.record.sessions, saved_sessions, "upgrade recovery preserves saved sessions")
  eq(f.record.review_id, "review_abc123", "upgrade recovery preserves the active review")
  eq(f.record.completed_review_id, "review_def456", "upgrade recovery preserves the review receipt")
  assert(reopened:open("opencode"))
  eq(f.backend_paths.opencode_profile, nil, "upgrade reopen prepares a fresh generation")
  eq(f.record.opencode_profile.version, "1.18.30", "reopen uses only the new audited release")
end

do
  for _, backend in ipairs({ "claude", "opencode" }) do
    local f = fixture()
    assert(f.coordinator:open(backend))
    local reopened = assert(require("ai.session").new(f.options))
    assert(reopened:attach())
    eq(reopened:snapshot().pane, "%40", "unique surviving pane reattaches")
    eq(#f.processes, 1, "attach never launches or resumes")
    eq(f.focused, nil, "attach never steals focus")
    if backend == "opencode" then
      assert(not reopened:paste("literal prompt"), "OpenCode requires its private append channel")
      eq(f.pasted, nil, "OpenCode reconnect never falls back to terminal paste")
    else
      assert(reopened:paste("literal prompt"))
      eq(f.pasted, "literal prompt", "validated reconnect permits transfer")
    end
  end
end

do
  local cases = {
    token = function(f)
      f.panes[1].opencode_token = string.rep("e", 32)
    end,
    fingerprint = function(f)
      f.panes[1].opencode_fingerprint = string.rep("e", 64)
    end,
    version = function(f)
      f.panes[1].opencode_version = "1.18.18"
    end,
    durable = function(f)
      f.record.opencode_profile.token = string.rep("e", 32)
    end,
    missing_generation = function(f)
      f.profile_error = "/secret/auth.json missing"
    end,
    changed_manifest = function(f)
      f.profile_error = "secret credential changed"
    end,
    wrong_root = function(f)
      f.panes[1].root = "/secret/other"
    end,
    inspect_failure = function(f)
      f.profile_error = "secret helper stderr"
    end,
    missing_backend = function(f)
      f.record.active_backend = vim.NIL
    end,
    decode_failure = function(f)
      f.read_error = "secret file contents"
    end,
    stale_session = function(f)
      f.panes[1].session = "ses_other"
    end,
  }
  for label, mutate in pairs(cases) do
    local f = fixture()
    assert(f.coordinator:open("opencode"))
    mutate(f)
    local before = vim.deepcopy(f.panes)
    local reopened = assert(require("ai.session").new(f.options))
    local attached, err = reopened:attach()
    assert(
      not attached and type(err) == "string" and not err:find("secret", 1, true),
      label .. " refuses safely"
    )
    assert(not reopened:paste("never transfer"), label .. " blocks paste")
    eq(f.pasted, nil, label .. " transfers no bytes")
    eq(f.panes, before, label .. " leaves surviving pane untouched")
    eq(#f.processes, 1, label .. " never rebuilds a profile or process")
  end
  local f = fixture()
  assert(f.coordinator:open("claude"))
  f.panes[2] = vim.tbl_extend("force", f.panes[1], { pane = "%41" })
  local reopened = assert(require("ai.session").new(f.options))
  local attached, err = reopened:attach()
  assert(
    not attached and err:find("%40", 1, true) and err:find("%41", 1, true),
    "duplicate refusal names every pane"
  )
end

do
  local f = fixture()
  assert(f.coordinator:open("claude"))
  local control_token = f.control_token
  assert(f.coordinator:prepare_review("review_0123456789abcdef"))
  eq(f.launches[2].writable, true, "review opens write access")
  eq(f.launches[2].review_id, "review_0123456789abcdef", "launch binds exact review")
  assert(not f.coordinator:prepare_review("review_other"), "second review is refused")
  assert(f.coordinator:switch("opencode"))
  eq(f.coordinator:snapshot().pane, "%40", "backend switch reuses pane")
  eq(f.coordinator:snapshot().backend, "opencode", "active backend changes")
  eq(f.record.sessions.claude, uuid, "switch remembers inactive session")
  eq(f.coordinator:snapshot().opencode_profile, {
    token = string.rep("b", 32),
    fingerprint = string.rep("c", 64),
    version = "1.18.30",
  }, "managed profile persists with session")
  assert(f.coordinator:finish_review("review_0123456789abcdef"))
  eq(f.launches[4].writable, false, "finishing review restores read-only root")
  eq(f.coordinator:snapshot().review_id, nil, "resolved review cleared")
  eq(
    f.backend_paths.opencode_profile.token,
    string.rep("b", 32),
    "same OpenCode activation keeps profile generation"
  )
  eq(f.control_token, control_token, "control token survives backend and review changes")
  eq(f.pasted, nil, "lifecycle actions never transfer text")
  assert(f.coordinator:shutdown())
  eq(f.closed, nil, "tmux backend survives Neovim shutdown")
  assert(f.coordinator:close())
  eq(f.closed, 1, "explicit close stops pane once")
  eq(f.record.opencode_profile, vim.NIL, "close clears active profile")
  eq(f.control_token, nil, "close revokes control token")
end

do
  local f = fixture()
  local states = {}
  f.coordinator:subscribe(function(snapshot)
    states[#states + 1] = snapshot.state
  end)
  assert(f.coordinator:open("claude"))
  eq(f.coordinator:snapshot().state, "open", "first launch opens one pane")
  eq(#f.processes, 1, "one process created")
  eq(f.launches[1].writable, false, "ordinary first open is read-only")
  eq(f.launches[1].launch.session, uuid, "remembered session resumes")
  eq(f.record.sessions.claude, uuid, "session survives durable publication")
  eq(f.tags[1].session, uuid, "pane and durable session agree")
  eq(states, { "starting", "open" }, "observers see bounded lifecycle states")
end

do
  local grant = assert(vim.uv.fs_mkdtemp("/tmp/nvim-ai-session-grant.XXXXXX"))
  local ok, err = xpcall(function()
    local f = fixture()
    assert(f.coordinator:prepare_review("review_abcd"))
    eq(#f.processes, 0, "preparing review before open does not launch a process")
    assert(f.coordinator:open("claude"))
    eq(f.launches[1].writable, true, "pending review makes first launch writable")
    assert(f.coordinator:set_grants({ grant }))
    eq(f.launches[2].grants, { grant }, "grant relaunch carries canonical directory")
    assert(f.coordinator:switch("codex"))
    eq(f.launches[3].grants, { grant }, "approved grants survive backend switch")
    eq(#f.confirmations, 0, "common open state does not ask busy confirmation")
    assert(f.coordinator:close())
    eq(f.record.grants, {}, "explicit close revokes all grants")
    eq(f.record.review_id, "review_abcd", "close retains unresolved review")
    assert(f.coordinator:finish_review("review_abcd"))
    eq(#f.processes, 3, "closed review resolution does not restart a CLI")
    eq(f.record.review_id, vim.NIL, "closed review can finish")

    for _, change in ipairs({
      function(value)
        value.control_token = nil
      end,
      function(value)
        value.panes[1].grants = string.rep("f", 16)
      end,
    }) do
      f = fixture()
      assert(f.coordinator:open("claude"))
      change(f)
      local reopened = assert(require("ai.session").new(f.options))
      assert(reopened:attach())
      assert(not reopened:paste("blocked"), "unreconciled sandbox blocks transfer")
      eq(#f.processes, 1, "reconnect does not silently fix sandbox")
      f.confirmed = false
      assert(not reopened:open("claude"), "reconciliation requires confirmation")
      f.confirmed = true
      assert(reopened:open("claude"))
      assert(reopened:paste("explicit"))
      eq(#f.processes, 2, "confirmed reconciliation relaunches once")
    end
    f = fixture()
    assert(f.coordinator:open("claude"))
    f.panes[1].state = "busy"
    local reopened = assert(require("ai.session").new(f.options))
    assert(reopened:attach())
    f.confirmed = false
    assert(not reopened:switch("opencode"), "busy rich backend requires confirmation")
    local prompt = f.confirmations[1]
    assert(
      prompt:find("claude", 1, true)
        and prompt:find("opencode", 1, true)
        and prompt:find("same pane", 1, true)
        and prompt:find("different session", 1, true)
    )
    f.confirmed = true
    assert(reopened:switch("opencode"))
  end, debug.traceback)
  assert(vim.uv.fs_rmdir(grant))
  assert(ok, err)
end

do
  for _, operation in ipairs({ "respawn", "tag" }) do
    local f = fixture()
    assert(f.coordinator:open("claude"))
    local before = vim.deepcopy(f.record)
    f.failures[operation] = 1
    local changed, err = f.coordinator:prepare_review("review_abcd")
    assert(not changed and not err:find("secret", 1, true), "failed writable relaunch is bounded")
    eq(f.record, before, "successful process recovery restores durable state")
    eq(f.coordinator:snapshot().state, "open", "recovered process is open")
    eq(f.launches[#f.launches].writable, false, "recovery actually rebuilds read-only launch")
    eq(f.respawns, 2, "failed relaunch is followed by same-pane recovery")
    assert(f.coordinator:paste("after recovery"))
  end
  local f = fixture()
  assert(f.coordinator:open("claude"))
  f.failures.respawn = 2
  assert(not f.coordinator:prepare_review("review_abcd"))
  eq(
    f.coordinator:snapshot().state,
    "failed",
    "failed recovery does not pretend to restore a process"
  )
  eq(f.coordinator:snapshot().pane, nil, "failed recovery closes unverified process")
  assert(not f.coordinator:paste("blocked"), "failed recovery blocks transfer")

  f = fixture()
  f.failures.create = 1
  assert(not f.coordinator:open("claude"))
  eq(f.coordinator:snapshot().state, "failed", "startup failure is observable")
  eq(f.removed_launches, 1, "manifest is removed when process provably never started")
  f = fixture()
  f.failures.health = 1
  assert(not f.coordinator:open("claude"))
  eq(#f.processes, 0, "unavailable backend never creates process")
  f = fixture()
  f.failures.tag = 1
  f.failures.close = 1
  assert(not f.coordinator:open("claude"))
  eq(f.coordinator:snapshot().pane, nil, "failed tag cleanup never adopts process")
  eq(f.coordinator:snapshot().state, "failed", "failed cleanup is reported truthfully")
end

do
  local f = fixture()
  local callback, unsubscribed
  f.options.tracker = {
    paths = function()
      return {}
    end,
    subscribe = function(_, subscriber)
      callback = subscriber
      return function()
        unsubscribed = true
      end
    end,
  }
  local coordinator = assert(require("ai.session").new(f.options))
  assert(coordinator:open("claude"))
  callback({ { state = "conflicted" } }, "conflict")
  eq(coordinator:snapshot().state, "conflicted", "tracker conflict latches display state")
  assert(coordinator:prepare_review("review_abcd"))
  eq(coordinator:snapshot().state, "conflicted", "process restart cannot erase conflict latch")
  callback({}, "abandon")
  eq(coordinator:snapshot().state, "open", "only tracker resolution clears conflict latch")
  assert(coordinator:shutdown())
  eq(unsubscribed, true, "shutdown releases tracker subscription")

  f = fixture()
  assert(f.coordinator:open("claude"))
  f.transport.paste = function()
    return nil, "secret process exit detail"
  end
  assert(not f.coordinator:paste("literal"))
  eq(f.coordinator:snapshot().state, "failed", "unexpected process exit becomes failed state")
  eq(#f.processes, 1, "process exit never auto-restarts backend")

  f = fixture()
  local standalone = vim.deepcopy(identity)
  standalone.tmux_socket, standalone.owner_pane, standalone.namespace = nil, nil, "nvim:test"
  f.options.identity = standalone
  f.record.identity.owner_pane, f.record.identity.namespace = vim.NIL, "nvim:test"
  coordinator = assert(require("ai.session").new(f.options))
  assert(coordinator:open("claude"))
  assert(coordinator:shutdown())
  eq(f.closed, 1, "standalone shutdown closes its owned terminal")
end

do
  local function queued_fixture()
    local f = fixture()
    f.validation = "checking"
    f.registry.ensure_opencode_compatibility = function(_, request)
      eq(
        request,
        { reason = "open", identity_key = identity.key },
        "queued opening contains identity only"
      )
      f.queued = true
      return { state = f.validation }
    end
    f.registry.take_opencode_open = function()
      if f.validation ~= "ready" or not f.queued then
        return false
      end
      f.queued = false
      return true
    end
    f.registry.subscribe_opencode_compatibility = function(_, callback)
      f.validation_callback = callback
      return function()
        f.unsubscribed_validation = true
      end
    end
    f.registry.cancel_opencode_compatibility = function()
      f.queued = false
      f.cancelled = true
    end
    f.options.current_identity = function()
      return f.current_identity or identity
    end
    f.options.schedule = function(callback)
      f.scheduled = callback
    end
    f.coordinator = assert(require("ai.session").new(f.options))
    return f
  end
  local f = queued_fixture()
  assert(not f.coordinator:open("opencode"), "pending validation does not launch synchronously")
  assert(not f.coordinator:paste("must not be retained"))
  eq(#f.processes, 0, "pending validation creates no backend process")
  f.validation = "ready"
  f.validation_callback({ state = "ready" })
  assert(f.scheduled, "ready notification schedules the opening")
  f.scheduled()
  eq(#f.processes, 1, "validated queued open launches exactly once")
  eq(f.pasted, nil, "queued open retains no prompt bytes")
  f.scheduled()
  eq(#f.processes, 1, "late duplicate callback cannot relaunch")

  -- Reopened Neovim has no compatibility cache, even though its pane survived.
  f.validation = "checking"
  f.coordinator = assert(require("ai.session").new(f.options))
  assert(f.coordinator:attach())
  assert(not f.coordinator:prepare_review("review_abcd"))
  eq(f.queued, true, "explicit OpenCode scope change starts missing validation")
  eq(f.record.review_id, vim.NIL, "pending validation does not publish a review action")
  f.validation = "ready"
  f.validation_callback({ state = "ready" })
  f.scheduled()
  eq(#f.processes, 1, "validation completion does not replay queued write access")
  assert(f.coordinator:prepare_review("review_abcd"))
  eq(#f.processes, 2, "explicit review retry relaunches after validation")

  for _, action in ipairs({ "close", "shutdown", "switch" }) do
    f = queued_fixture()
    assert(not f.coordinator:open("opencode"))
    f.validation = "ready"
    f.validation_callback({ state = "ready" })
    if action == "switch" then
      assert(f.coordinator:switch("claude"))
    else
      assert(f.coordinator[action](f.coordinator))
    end
    assert(f.cancelled, "explicit lifecycle cancellation clears queued opening")
    f.scheduled()
    eq(
      #f.processes,
      action == "switch" and 1 or 0,
      "late callback cannot revive cancelled OpenCode"
    )
  end
  f = queued_fixture()
  assert(not f.coordinator:open("opencode"))
  f.current_identity = vim.tbl_extend("force", identity, { key = string.rep("f", 32) })
  f.validation = "ready"
  f.validation_callback({ state = "ready" })
  f.scheduled()
  eq(#f.processes, 0, "queued opening rechecks current identity")

  f = queued_fixture()
  assert(not f.coordinator:open("opencode"))
  f.queued = false
  f.validation_callback({ state = "not_checked", queued = false })
  eq(f.coordinator:snapshot().queued, false, "executable drift clears coordinator opening intent")
  f.validation_callback({ state = "ready", queued = false })
  eq(f.scheduled, nil, "late readiness cannot revive drift-cancelled opening")
end

do
  local f = fixture()
  f.store.read_record = function()
    error("secret decode exception")
  end
  assert(
    not f.coordinator:open("claude"),
    "read exception must not be treated as absent durable state"
  )
  eq(#f.processes, 0, "read exception starts nothing")
  f = fixture()
  local reentrant
  f.coordinator:subscribe(function(snapshot)
    if snapshot.state == "starting" then
      reentrant = f.coordinator:close()
    end
  end)
  assert(f.coordinator:open("claude"))
  eq(reentrant, nil, "observer cannot interleave close with launch publication")
  assert(f.control_token, "in-flight launch retains its control ownership")
end

do
  local f = fixture()
  local attempts = 0
  f.transport.create = function()
    attempts = attempts + 1
    return nil, "unknown launcher acknowledgement and cleanup", "unknown"
  end
  assert(not f.coordinator:open("claude"))
  assert(
    not f.coordinator:open("claude"),
    "uncertain creation requires explicit ownership reconciliation"
  )
  eq(attempts, 1, "uncertain creation cannot duplicate a surviving pane")
  assert(f.coordinator:close(), "no surviving owned pane allows explicit cleanup")

  f = fixture()
  assert(f.coordinator:attach())
  local before = vim.deepcopy(f.record)
  local write = f.store.write_record
  local failed = false
  f.store.write_record = function(self, value)
    assert(write(self, value))
    if not failed then
      failed = true
      return nil, "directory fsync failed", true
    end
    return true
  end
  assert(not f.coordinator:prepare_review("review_abcd"))
  eq(f.record, before, "non-launch post-rename failure restores durable record")
  eq(f.coordinator:snapshot().review_id, nil, "non-launch rollback preserves review snapshot")

  f = fixture()
  assert(f.coordinator:open("claude"))
  f.store.cleanup_contexts = function()
    return nil, "private cleanup failed"
  end
  assert(not f.coordinator:close())
  eq(
    f.coordinator:snapshot().state,
    "failed",
    "cleanup failure cannot leave an open snapshot after pane closes"
  )
  assert(not f.coordinator:open("claude"), "unverified cleanup requires explicit retry")
end

do
  local f = fixture()
  local removals = 0
  f.options.tracker = {
    paths = function()
      return {}
    end,
    subscribe = function()
      return function() end
    end,
    abandon = function()
      removals = removals + 1
      return true
    end,
  }
  local coordinator = assert(require("ai.session").new(f.options))
  assert(coordinator:prepare_review("review_abcd"))
  assert(coordinator:finish_review("review_abcd"))
  eq(removals, 1, "finishing a closed resolved review removes its baseline")
  eq(#f.processes, 0, "closed baseline resolution launches nothing")
  assert(coordinator:prepare_review("review_bcde"))
  f.options.tracker.abandon = function()
    return nil, "baseline cleanup failure"
  end
  assert(not coordinator:finish_review("review_bcde"))
  eq(f.record.review_id, "review_bcde", "failed closed baseline cleanup retains review identity")
  eq(coordinator:snapshot().state, "failed", "incomplete baseline cleanup is visible")
  f.options.tracker.abandon = function()
    return true
  end
  assert(
    coordinator:finish_review("review_bcde"),
    "closed baseline cleanup can be retried explicitly"
  )
  eq(f.record.review_id, vim.NIL, "successful retry clears resolved identity")
end

do
  local f = fixture()
  assert(f.coordinator:open("claude"))
  assert(f.coordinator:prepare_review("review_abcd"))
  local respawn = f.transport.respawn
  local interrupted
  f.transport.respawn = function(self, ...)
    local reopened = assert(require("ai.session").new(f.options))
    local adopted = reopened:attach()
    interrupted =
      { adopted = adopted, snapshot = reopened:snapshot(), review_id = f.record.review_id }
    return respawn(self, ...)
  end
  assert(f.coordinator:finish_review("review_abcd"))
  eq(
    interrupted.review_id,
    "review_abcd",
    "finish retains durable review binding while old writable process exists"
  )
  assert(
    not interrupted.snapshot.transfer_ready,
    "interrupted replacement cannot reconnect with text transfer enabled"
  )
  eq(f.record.review_id, vim.NIL, "review binding clears only after read-only replacement")

  f = fixture()
  assert(f.coordinator:open("claude"))
  assert(f.coordinator:prepare_review("review_abcd"))
  local write = f.store.write_record
  local failed = false
  f.store.write_record = function(self, value)
    if not failed and value.review_id == vim.NIL then
      failed = true
      return nil, "final binding publication failed", false
    end
    return write(self, value)
  end
  assert(not f.coordinator:finish_review("review_abcd"))
  eq(f.record.review_id, "review_abcd", "failed final binding publication restores prior review")
  eq(
    f.coordinator:snapshot().state,
    "open",
    "prior bound process is recovered after final publication failure"
  )
  eq(
    f.launches[#f.launches].review_id,
    "review_abcd",
    "recovery rebuilds prior exact review binding"
  )
end

do
  local root = assert(vim.uv.fs_mkdtemp("/tmp/nvim-ai-session-grant-drift.XXXXXX"))
  local allowed, moved, other = root .. "/allowed", root .. "/moved", root .. "/other"
  assert(vim.uv.fs_mkdir(allowed, 448))
  assert(vim.uv.fs_mkdir(other, 448))
  local ok, err = xpcall(function()
    local f = fixture()
    assert(f.coordinator:open("claude"))
    assert(f.coordinator:set_grants({ allowed }))
    assert(vim.uv.fs_rename(allowed, moved))
    assert(vim.uv.fs_symlink(other, allowed))
    local reopened = assert(require("ai.session").new(f.options))
    assert(reopened:attach())
    assert(
      not reopened:paste("blocked"),
      "changed physical grant requires confirmed reconciliation"
    )
  end, debug.traceback)
  assert(vim.uv.fs_unlink(allowed))
  assert(vim.uv.fs_rmdir(moved))
  assert(vim.uv.fs_rmdir(other))
  assert(vim.uv.fs_rmdir(root))
  assert(ok, err)
end

do
  local f = fixture()
  assert(f.coordinator:open("claude"))
  assert(f.coordinator:prepare_review("review_abcd"))
  assert(f.coordinator:finish_review("review_abcd"))
  eq(
    f.record.completed_review_id,
    "review_abcd",
    "read-only transition durably acknowledges the exact completed review"
  )
  local launches = #f.processes
  assert(
    f.coordinator:finish_review("review_abcd"),
    "same-instance exact acknowledgement is idempotent"
  )
  local reopened = assert(require("ai.session").new(f.options))
  assert(
    reopened:finish_review("review_abcd"),
    "completed review acknowledgement survives coordinator reopen"
  )
  eq(#f.processes, launches, "acknowledgement retries never relaunch or paste")
  assert(not reopened:finish_review("review_dead"), "different review ID is not acknowledged")
  assert(not reopened:finish_review(nil), "missing review ID is not acknowledged")
  f.panes[1].state = "starting"
  assert(
    not f.coordinator:finish_review("review_abcd"),
    "receipt cannot bypass current pane reconciliation"
  )
  f.panes[1].state = "open"
  assert(reopened:attach())
  assert(reopened:prepare_review("review_bcde"))
  eq(f.record.completed_review_id, nil, "a new writable review invalidates the previous receipt")
  assert(
    not f.coordinator:finish_review("review_abcd"),
    "an older coordinator cannot acknowledge a newly writable session"
  )
end

do
  local f = fixture()
  assert(f.coordinator:open("opencode"))
  assert(f.coordinator:handle_event({
    schema = 1,
    backend = "opencode",
    session = "ses_first",
    state = "busy",
    time = 123,
  }))
  eq(f.coordinator:snapshot().sessions.opencode, "ses_first", "first rich feed pins exact session")
  assert(not f.coordinator:handle_event({
    schema = 1,
    backend = "opencode",
    session = "ses_foreign",
    state = "idle",
    time = 124,
  }), "later foreign sessions are ignored")
  local reopened = assert(require("ai.session").new(f.options))
  assert(reopened:attach(), "captured session agrees with durable and pane metadata")
  eq(reopened:snapshot().sessions.opencode, "ses_first", "captured session survives reopen")
  assert(
    reopened:handle_event({
      schema = 1,
      backend = "opencode",
      session = "ses_first",
      state = "failed",
      time = 122,
    }),
    "common failure needs no rich capability"
  )
end

do
  local f = fixture()
  assert(f.coordinator:open("opencode"))
  f.failures.write = 1
  assert(not f.coordinator:handle_event({
    schema = 1,
    backend = "opencode",
    session = "ses_first",
    state = "busy",
    time = 123,
  }))
  eq(f.coordinator:snapshot().sessions.opencode, "", "failed publication cannot pin a session")
  eq(f.coordinator:snapshot().state, "open", "failed publication cannot publish rich state")
end

do
  local f = fixture()
  assert(f.coordinator:open("opencode"))
  assert(
    f.coordinator:handle_event({
      schema = 1,
      backend = "opencode",
      session = "ses_first",
      state = "failed",
      time = 123,
    }),
    "first feed record may be a session failure"
  )
  eq(
    f.coordinator:snapshot().sessions.opencode,
    "ses_first",
    "initial failure still pins exact session"
  )
  eq(f.coordinator:snapshot().state, "failed", "initial failure is visible")
end

do
  local f = fixture()
  assert(f.coordinator:open("codex"))
  assert(not f.coordinator:handle_event({
    schema = 1,
    backend = "codex",
    session = "last",
    state = "busy",
    time = 123,
  }), "Codex does not invent unsupported rich capabilities")
  eq(f.coordinator:snapshot().state, "open", "Codex remains healthy on common state")
  assert(
    f.coordinator:handle_event({
      schema = 1,
      backend = "codex",
      session = "last",
      state = "failed",
      time = 123,
    }),
    "Codex accepts matching common failure"
  )
  assert(f.coordinator:close())
end

print("AI session assertions: ok")
