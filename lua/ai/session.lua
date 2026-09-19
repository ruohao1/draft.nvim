-- One identity, one managed pane, and a remembered session for each backend.
-- Dependencies are supplied by command wiring; construction never starts a CLI.
local M = {}
local copy = vim.deepcopy
local backend_available = require("ai.backends").is_available
local transitions = {
  closed = { starting = true, paused = true },
  starting = { open = true, failed = true, closed = true },
  open = {
    idle = true,
    busy = true,
    approval = true,
    completed = true,
    starting = true,
    attention = true,
    changes = true,
    conflicted = true,
    failed = true,
    closed = true,
  },
  idle = {
    starting = true,
    busy = true,
    completed = true,
    attention = true,
    changes = true,
    conflicted = true,
    failed = true,
    closed = true,
  },
  busy = {
    starting = true,
    idle = true,
    approval = true,
    completed = true,
    changes = true,
    conflicted = true,
    failed = true,
    closed = true,
  },
  approval = { busy = true, idle = true, completed = true, failed = true, closed = true },
  completed = {
    idle = true,
    busy = true,
    changes = true,
    conflicted = true,
    failed = true,
    closed = true,
  },
  attention = {
    open = true,
    starting = true,
    changes = true,
    conflicted = true,
    failed = true,
    closed = true,
  },
  changes = { open = true, starting = true, conflicted = true, closed = true },
  conflicted = { starting = true, conflicted = true, closed = true },
  failed = { starting = true, closed = true },
  paused = { starting = true, closed = true },
}

local function present(value)
  return value ~= nil and value ~= vim.NIL
end

-- Never forward helper stderr, paths, credentials, or malformed metadata to UI.
local function call(object, method, ...)
  if type(object) ~= "table" or type(object[method]) ~= "function" then
    return nil, "AI dependency operation is unavailable"
  end
  local ok, result, err, published = pcall(object[method], object, ...)
  if ok then
    return result, err, published
  end
  return nil, "AI dependency operation failed"
end

local function owned_directory(path)
  if
    type(path) ~= "string"
    or path:sub(1, 1) ~= "/"
    or path:find("[%z\1-\31\127]")
    or path:find("\194[\128-\159]")
  then
    return nil
  end
  local physical = vim.uv.fs_realpath(path)
  local stat = physical and vim.uv.fs_lstat(physical)
  if
    not stat
    or stat.type ~= "directory"
    or stat.uid ~= vim.uv.getuid()
    or bit.band(stat.mode, 18) ~= 0
  then
    return nil
  end
  return physical
end

local function grant_hash(grants)
  return #grants == 0 and "0" or vim.fn.sha256(table.concat(grants, "\0")):sub(1, 16)
end

function M.new(options)
  options = options or {}
  if type(options.identity) ~= "table" or not options.transport or not options.store then
    return nil, "AI session dependencies are unavailable"
  end
  local identity = copy(options.identity)
  local store, transport, registry = options.store, options.transport, options.registry
  local runtime_registry = require("ai.backends")
  if not registry or registry == runtime_registry then
    registry = {}
    for _, method in ipairs({
      "get",
      "health",
      "ensure_opencode_compatibility",
      "take_opencode_open",
      "cancel_opencode_compatibility",
      "subscribe_opencode_compatibility",
    }) do
      registry[method] = function(_, ...)
        return runtime_registry[method](...)
      end
    end
  end
  local sandbox = options.sandbox or require("ai.sandbox")
  local subscribers, coordinator = {}, {}
  local pane, record, state, diagnostic
  local attached, refused, reconcile = false, false, false
  local conflicts, unresolved = 0, 0
  local unsubscribe_tracker
  local closed_review_cleanup
  local stopped = false
  local launching, transferring = false, false
  local prompt_launch
  local activation = 0
  local pending_open, queue_generation, validation = false, 0, nil
  local unsubscribe_validation
  state = "closed"
  local token = options.token
    or function()
      return vim.uv.random(16):gsub(".", function(byte)
        return string.format("%02x", byte:byte())
      end)
    end
  local environment

  function coordinator:snapshot()
    return {
      state = (state == "closed" or state == "paused") and state
        or conflicts > 0 and "conflicted"
        or state,
      pane = pane,
      backend = record and present(record.active_backend) and record.active_backend or nil,
      conflicts = conflicts,
      unresolved = unresolved,
      validation = validation,
      queued = pending_open,
      activation = activation,
      sessions = record and copy(record.sessions) or { codex = "", claude = "", opencode = "" },
      grants = record and copy(record.grants) or {},
      review_id = record and present(record.review_id) and record.review_id or nil,
      opencode_profile = record and present(record.opencode_profile) and copy(
        record.opencode_profile
      ) or nil,
      error = diagnostic,
      transfer_ready = pane ~= nil
        and not stopped
        and not launching
        and not transferring
        and not refused
        and not reconcile
        and state ~= "failed"
        and state ~= "paused"
        and state ~= "starting",
    }
  end

  local function emit(next_state)
    if next_state and next_state ~= state then
      if not transitions[state][next_state] then
        return nil
      end
      state = next_state
    end
    for _, callback in ipairs(copy(subscribers)) do
      pcall(callback, coordinator:snapshot())
    end
    return true
  end

  local function fail(message)
    diagnostic = message
    if options.notify then
      pcall(options.notify, message)
    end
    return nil, message
  end

  local function block(message)
    state, refused = "failed", true
    fail(message)
    emit()
    return nil, message
  end

  local function publish_record(proposed, previous)
    local written, _, published = call(store, "write_record", proposed)
    if written then
      return true
    end
    if published ~= false and not call(store, "write_record", previous) then
      return block("AI durable publication failed and rollback could not be verified")
    end
    return fail("AI durable state publication failed")
  end

  local function cancel_open(reason)
    queue_generation = queue_generation + 1
    if pending_open then
      call(registry, "cancel_opencode_compatibility", reason)
    end
    pending_open = false
  end

  local function ensure_opencode()
    if type(registry.ensure_opencode_compatibility) ~= "function" then
      return true
    end
    pending_open, queue_generation = true, queue_generation + 1
    local report = call(
      registry,
      "ensure_opencode_compatibility",
      { reason = "open", identity_key = identity.key }
    )
    if not report then
      pending_open = false
      return fail("AI OpenCode validation could not be requested")
    end
    validation = report.state
    if report.state == "ready" and call(registry, "take_opencode_open", identity.key) then
      pending_open = false
      return true
    end
    if report.state ~= "checking" then
      pending_open = false
    end
    emit()
    return nil,
      pending_open and "AI OpenCode validation is in progress; opening queued without prompt text"
        or "AI OpenCode validation is unavailable; explicit retry is required"
  end

  function coordinator:subscribe(callback)
    if type(callback) ~= "function" then
      return nil, "AI session observer is invalid"
    end
    subscribers[#subscribers + 1] = callback
    return function()
      for index, candidate in ipairs(subscribers) do
        if candidate == callback then
          table.remove(subscribers, index)
          break
        end
      end
    end
  end

  local function paths_for(backend, next_record, create)
    if not environment then
      local home = owned_directory(options.home or vim.env.HOME)
      if not home then
        return nil
      end
      local data_home = owned_directory(
        options.data_home
          or (vim.env.XDG_DATA_HOME ~= "" and vim.env.XDG_DATA_HOME)
          or home .. "/.local/share"
      )
      if not data_home then
        return nil
      end
      environment = {
        global_codex_home = home .. "/.codex",
        global_claude_config = home .. "/.claude",
        global_claude_home_file = home .. "/.claude.json",
        home_agents = home .. "/AGENTS.md",
        global_opencode_data = data_home .. "/opencode",
      }
    end
    local paths = call(store, "launch_paths", backend, create)
    if not paths then
      return nil
    end
    paths = vim.tbl_extend("force", paths, copy(environment))
    paths.grants = copy(next_record.grants)
    paths.python = options.tools and options.tools.python
    paths.event_helper = options.helpers and options.helpers.event_helper
    paths.profile_helper = options.helpers and options.helpers.profile_helper
    return paths
  end

  local function initial_record()
    return {
      schema = 1,
      identity = {
        key = identity.key,
        root = identity.root,
        namespace = identity.namespace,
        owner_pane = identity.owner_pane or vim.NIL,
      },
      active_backend = vim.NIL,
      sessions = { codex = "", claude = "", opencode = "" },
      grants = {},
      review_id = vim.NIL,
      opencode_profile = vim.NIL,
    }
  end

  local function metadata(next_record, next_state)
    local profile = present(next_record.opencode_profile) and next_record.opencode_profile or {}
    return {
      key = identity.key,
      owner = identity.owner_pane,
      root = identity.root,
      backend = next_record.active_backend,
      state = next_state,
      grants = grant_hash(next_record.grants),
      session = next_record.sessions[next_record.active_backend],
      opencode_token = profile.token or "",
      opencode_fingerprint = profile.fingerprint or "",
      opencode_version = profile.version or "",
    }
  end

  local function prepare_launch(backend, proposed, profile)
    local adapter = call(registry, "get", backend)
    local health = adapter and call(registry, "health", backend)
    if not backend_available(health) then
      return fail("AI backend is unavailable; check AI health")
    end
    local next_record = copy(proposed)
    local grants = require("ai.sandbox").validate_grants(identity, next_record.grants)
    if not grants then
      return fail("AI scope grants are invalid or unavailable")
    end
    next_record.grants = grants
    local paths = paths_for(backend, next_record)
    if not paths then
      return fail("AI launch paths are unavailable or unsafe")
    end
    if profile then
      paths.opencode_profile = copy(profile)
    end
    local reference =
      call(adapter, "session_reference", { session = next_record.sessions[backend] })
    local prepared = call(
      adapter,
      reference and reference ~= "" and "resume_session" or "new_session",
      identity,
      paths,
      reference
    )
    if not prepared then
      return fail("AI backend launch preparation failed")
    end
    next_record.active_backend = backend
    next_record.sessions[backend] = call(adapter, "session_reference", prepared)
    next_record.opencode_profile = vim.NIL
    if backend == "opencode" then
      next_record.opencode_profile = call(adapter, "profile_reference", prepared)
    end
    if not next_record.sessions[backend] or not next_record.opencode_profile then
      return fail("AI backend launch reference is invalid")
    end
    if not require("ai.transports.metadata").validate(metadata(next_record, "open")) then
      return fail("AI backend launch metadata is invalid")
    end
    local control_token = call(store, "ensure_control_token", token)
    if not control_token then
      return fail("AI control token is unavailable")
    end
    local host_tools = { options.tools and options.tools.git }
    if identity.tmux_socket then
      host_tools[#host_tools + 1] = options.tools and options.tools.tmux
    end
    table.sort(host_tools)
    local generated, launch_token = pcall(token)
    if not generated then
      return fail("AI launch token generation failed")
    end
    local publication_attempted = false
    local ok, invocation = pcall(
      sandbox.prepare,
      vim.tbl_extend("force", copy(options.tools or {}), copy(options.helpers or {}), {
        identity = copy(identity),
        launch = prepared,
        token = launch_token,
        control_token = control_token,
        writable = present(next_record.review_id),
        review_id = present(next_record.review_id) and next_record.review_id or nil,
        grants = copy(next_record.grants),
        runtime_root = store:runtime_root(),
        state_root = store:state_root(),
        context_dir = paths.context_dir,
        backend_state_dir = paths.backend_state,
        control_socket = paths.control_socket,
        event_file = paths.event_file,
        host_tools = host_tools,
        write_manifest = function(manifest)
          publication_attempted = true
          return store:write_launch(manifest)
        end,
      })
    )
    if not ok or not invocation then
      if publication_attempted and not call(store, "remove_launch", launch_token) then
        return fail("AI sandbox preparation and manifest cleanup failed")
      end
      return fail("AI sandbox preparation failed")
    end
    return { record = next_record, invocation = invocation, adapter = adapter }
  end

  local function launch_transaction(backend, proposed, reuse_profile)
    local previous, previous_pane = copy(record), pane
    local profile = reuse_profile
        and pane
        and backend == "opencode"
        and record.active_backend == "opencode"
        and present(record.opencode_profile)
        and record.opencode_profile
      or nil
    local prepared, prepare_error = prepare_launch(backend, proposed or record, profile)
    if not prepared then
      return nil, prepare_error
    end
    local next_record, invocation, adapter = prepared.record, prepared.invocation, prepared.adapter
    local previous_state = state
    if
      previous_pane and not call(transport, "tag", previous_pane, metadata(previous, "starting"))
    then
      call(store, "remove_launch", invocation.token)
      return block("AI pane transition could not be staged; explicit reconciliation is required")
    end
    -- Session/profile references must precede creation, but a review binding
    -- must not disappear while the prior writable process can still be alive.
    local launching_record = copy(next_record)
    launching_record.review_id = previous.review_id
    launching_record.completed_review_id = previous.completed_review_id
    local written, write_error = publish_record(launching_record, previous)
    if not written then
      if not call(store, "remove_launch", invocation.token) then
        return block("AI durable publication failed and unused launch cleanup failed")
      end
      if
        previous_pane
        and (
          refused or not call(transport, "tag", previous_pane, metadata(previous, previous_state))
        )
      then
        return block("AI durable publication failed and prior pane state could not be restored")
      end
      return nil, write_error
    end
    diagnostic = nil
    if state == "approval" then
      emit("busy")
    elseif state == "completed" then
      emit("idle")
    end
    emit("starting")
    local created, phase
    if pane then
      local previous_adapter = call(registry, "get", previous.active_backend)
      local respawned, _, attempt_phase =
        call(transport, "respawn", pane, invocation, call(previous_adapter, "suspend"))
      phase = attempt_phase
      if respawned then
        created = pane
      end
    else
      local create_error
      created, create_error, phase = call(transport, "create", identity, invocation)
    end
    local tagged = created and call(transport, "tag", created, metadata(next_record, "starting"))
    if tagged and not vim.deep_equal(launching_record, next_record) then
      tagged = call(store, "write_record", next_record)
    end
    if tagged then
      tagged = call(transport, "tag", created, metadata(next_record, "open"))
    end
    if not tagged then
      -- A timeout is not proof that a launcher never ran. Leave that manifest to
      -- the launcher or explicit close; only a proven pre-start failure removes it.
      if not created and phase == "not_started" then
        call(store, "remove_launch", invocation.token)
      end
      if previous_pane then
        local prior_profile = previous.active_backend == "opencode"
            and present(previous.opencode_profile)
            and previous.opencode_profile
          or nil
        local recovery = prepare_launch(previous.active_backend, previous, prior_profile)
        if
          recovery
          and vim.deep_equal(recovery.record, previous)
          and call(transport, "tag", previous_pane, metadata(next_record, "starting"))
        then
          -- Stops any just-started process before retagging or durable rollback.
          local recovered, _, recovery_phase =
            call(transport, "respawn", previous_pane, recovery.invocation, call(adapter, "stop"))
          if not recovered and recovery_phase == "not_started" then
            call(store, "remove_launch", recovery.invocation.token)
          end
          if
            recovered
            and call(transport, "tag", previous_pane, metadata(previous, "starting"))
            and call(store, "write_record", previous)
            and call(transport, "tag", previous_pane, metadata(previous, "open"))
          then
            pane, record, refused, reconcile = previous_pane, previous, false, false
            prompt_launch = recovery.invocation.token
            emit("open")
            return fail("AI relaunch failed; the previous managed process was recovered")
          end
        elseif recovery then
          call(store, "remove_launch", recovery.invocation.token)
        end
        local stopped = call(transport, "close", previous_pane, call(adapter, "stop"))
        record, refused, pane = call(store, "read_record"), true, previous_pane
        if stopped then
          pane = nil
        end
        emit("failed")
        return fail("AI relaunch and process recovery failed; explicit close is required")
      end
      local cleaned = (not created and phase == "not_started")
        or (created and call(transport, "close", created, call(adapter, "stop")))
      if not cleaned or not call(store, "write_record", previous) then
        record, pane, refused = call(store, "read_record"), nil, true
        emit("failed")
        return fail(
          "AI startup failed and cleanup could not be verified; explicit close is required"
        )
      end
      record, pane = previous, nil
      emit("failed")
      return fail("AI managed process could not be started or tagged")
    end
    pane, record = created, next_record
    prompt_launch = invocation.token
    activation = activation + 1
    attached, refused, reconcile = true, false, false
    emit("open")
    return true
  end

  local function launch(backend, proposed, reuse_profile)
    if launching or transferring then
      return nil, "AI lifecycle operation is already in progress"
    end
    launching = true
    local ok, result, err = pcall(launch_transaction, backend, proposed, reuse_profile)
    launching = false
    if not ok then
      state, refused = "failed", true
      fail("AI lifecycle operation failed; explicit close is required")
      emit()
      return nil, diagnostic
    end
    return result, err
  end

  function coordinator:attach()
    if launching or transferring or stopped then
      return nil, "AI session is busy or shut down"
    end
    local function reject(message)
      refused, attached, pane, state = true, true, nil, "failed"
      fail(message)
      emit()
      return nil, message
    end
    local panes = call(transport, "discover", identity)
    if not panes or not vim.islist(panes) then
      return reject("AI pane discovery failed; explicit close or restart is required")
    end
    if #panes > 1 then
      local ids = {}
      for _, item in ipairs(panes) do
        if type(item.pane) ~= "string" or #item.pane > 64 or not item.pane:match("^[%%:%w]+$") then
          return reject("AI pane discovery returned invalid ownership")
        end
        ids[#ids + 1] = item.pane
      end
      table.sort(ids)
      return reject("Multiple AI panes match this identity: " .. table.concat(ids, ", "))
    end
    local read, err = call(store, "read_record")
    if err then
      return reject("AI durable record could not be read; explicit repair is required")
    end
    local durable = read or initial_record()
    if #panes == 0 then
      local cleared = copy(durable)
      cleared.grants, cleared.opencode_profile = {}, vim.NIL
      if not call(store, "remove_control_token") then
        return reject("AI stale control token could not be cleared")
      end
      if not vim.deep_equal(cleared, durable) and not call(store, "write_record", cleared) then
        return reject("AI stale durable state could not be cleared")
      end
      record, pane, state, attached, refused, reconcile, diagnostic =
        cleared, nil, "closed", true, false, false, nil
      prompt_launch = nil
      return true
    end
    local candidate = panes[1]
    local backend = durable.active_backend
    local adapter = present(backend) and call(registry, "get", backend)
    if
      not read
      or not adapter
      or type(durable.sessions) ~= "table"
      or type(durable.identity) ~= "table"
      or durable.identity.key ~= identity.key
      or durable.identity.root ~= identity.root
      or durable.identity.namespace ~= identity.namespace
      or (present(durable.identity.owner_pane) and durable.identity.owner_pane or nil) ~= identity.owner_pane
      or candidate.key ~= identity.key
      or candidate.owner ~= identity.owner_pane
      or candidate.root ~= identity.root
      or candidate.backend ~= backend
      or not require("ai.transports.metadata").validate(candidate)
    then
      return reject("AI surviving pane metadata is stale; explicit close or restart is required")
    end
    local reference = call(adapter, "session_reference", { session = durable.sessions[backend] })
    if
      reference == nil
      or reference ~= durable.sessions[backend]
      or candidate.session ~= reference
      or (backend ~= "opencode" and reference == "")
    then
      return reject(
        "AI surviving session does not match durable state; explicit close or restart is required"
      )
    end
    if backend == "opencode" then
      local profile = durable.opencode_profile
      if
        type(profile) ~= "table"
        or candidate.opencode_token ~= profile.token
        or candidate.opencode_fingerprint ~= profile.fingerprint
        or candidate.opencode_version ~= profile.version
      then
        return reject(
          "AI surviving OpenCode profile does not match; explicit close or restart is required"
        )
      end
      local paths = paths_for(backend, durable, false)
      if
        not paths or not call(adapter, "validate_profile", copy(profile), copy(identity), paths)
      then
        return reject(
          "AI surviving OpenCode profile could not be verified; explicit close or restart is required"
        )
      end
    elseif durable.opencode_profile ~= vim.NIL then
      return reject(
        "AI surviving pane has stale OpenCode profile state; explicit close or restart is required"
      )
    end
    local control_token, control_error = call(store, "read_control_token")
    local physical_grants = require("ai.sandbox").validate_grants(identity, durable.grants)
    reconcile = not control_token
      or control_error ~= nil
      or candidate.grants ~= grant_hash(durable.grants)
      or candidate.state == "starting"
      or not vim.deep_equal(physical_grants, durable.grants)
    if pane ~= candidate.pane or not record or record.active_backend ~= backend then
      prompt_launch = nil
    end
    record, pane, state, attached, refused = durable, candidate.pane, candidate.state, true, false
    diagnostic = reconcile
        and "AI surviving pane requires a confirmed sandbox relaunch before text transfer"
      or nil
    emit()
    return true
  end

  function coordinator:open(backend)
    if launching or transferring or stopped then
      return nil, "AI session is busy or shut down"
    end
    if not ({ codex = true, claude = true, opencode = true })[backend] then
      return fail("AI backend name is invalid")
    end
    if backend ~= "opencode" then
      cancel_open("backend-switch")
    end
    if refused then
      return fail("AI surviving pane requires explicit close or restart")
    end
    -- A fresh creation always rediscovers ownership, including retries and
    -- delayed validation completion. A prior empty scan is not a lifetime lease.
    if (not attached or not pane) and not self:attach() then
      return nil, diagnostic
    end
    if pane then
      if reconcile then
        if
          not options.confirm
          or options.confirm(
              "Relaunch the AI sandbox in the same pane to reconcile grants and control ownership?"
            )
            ~= true
        then
          return nil, "AI sandbox relaunch cancelled"
        end
        if record.active_backend == "opencode" then
          local ok, err = ensure_opencode()
          if not ok then
            return nil, err
          end
        end
        return launch(record.active_backend, nil, true)
      end
      if state == "paused" or state == "failed" then
        if record.active_backend == "opencode" then
          local ok, err = ensure_opencode()
          if not ok then
            return nil, err
          end
        end
        return launch(record.active_backend, nil, true)
      end
      if record.active_backend == "opencode" then
        local ok, err = ensure_opencode()
        if not ok then
          return nil, err
        end
      end
      return call(transport, "focus", pane)
    end
    if backend == "opencode" then
      local ok, err = ensure_opencode()
      if not ok then
        return nil, err
      end
    end
    return launch(backend)
  end

  function coordinator:paste(text)
    if launching or transferring or stopped then
      return nil, "AI session is busy or shut down"
    end
    if
      type(text) ~= "string"
      or text == ""
      or #text > 2048
      or text:find("[%z\1-\31\127]")
      or text:find("\194[\128-\159]")
    then
      return fail("AI context reference is empty or unsafe")
    end
    if not self:snapshot().transfer_ready then
      return fail("AI pane is not verified for text transfer")
    end
    if record.active_backend == "opencode" then
      local expected_pane, expected_activation, review = pane, activation, record.review_id
      transferring = true
      local ok, result = pcall(require("ai.prompt").append, {
        store = store,
        identity = identity,
        review_id = review,
        launch = prompt_launch,
        text = text,
        current = function()
          return not stopped
            and not refused
            and not reconcile
            and state ~= "failed"
            and pane == expected_pane
            and activation == expected_activation
            and record.review_id == review
        end,
      })
      transferring = false
      if ok and result == "published" then
        return true
      end
      if not ok or result == "uncertain" then
        return nil,
          "OpenCode context delivery is unconfirmed; private context and review were retained. Check its prompt before preparing again; nothing was submitted or retried.",
          true
      end
      return nil,
        "OpenCode context channel is unavailable or stale; close and reopen the companion. Nothing was sent."
    end
    if not call(transport, "paste", pane, text) then
      diagnostic = "AI text transfer failed; the managed process may have exited"
      emit("failed")
      return fail(diagnostic)
    end
    return true
  end

  function coordinator:switch(backend)
    if launching or transferring or stopped then
      return nil, "AI session is busy or shut down"
    end
    if not ({ codex = true, claude = true, opencode = true })[backend] then
      return fail("AI backend name is invalid")
    end
    if backend ~= "opencode" then
      cancel_open("backend-switch")
    end
    if not pane then
      return self:open(backend)
    end
    if refused or reconcile then
      return fail("AI pane requires explicit sandbox reconciliation before switching")
    end
    if record.active_backend == backend then
      return call(transport, "focus", pane)
    end
    local capabilities = call(call(registry, "get", record.active_backend), "capabilities") or {}
    if capabilities.busy and (state == "busy" or state == "approval") then
      local message = "Switch from "
        .. record.active_backend
        .. " to "
        .. backend
        .. "? The same pane will resume a different session."
      if not options.confirm or options.confirm(message) ~= true then
        return nil, "AI backend switch cancelled"
      end
    end
    if backend == "opencode" then
      local ok, err = ensure_opencode()
      if not ok then
        return nil, err
      end
    end
    return launch(backend)
  end

  local function load_record()
    if record then
      return true
    end
    local read, err = call(store, "read_record")
    if err then
      return fail("AI durable record could not be read")
    end
    record = read or initial_record()
    return true
  end

  local function save_or_relaunch(proposed)
    if refused or reconcile then
      return fail("AI pane requires explicit sandbox reconciliation before changing scope")
    end
    if pane then
      if record.active_backend == "opencode" then
        local ok, err = ensure_opencode()
        if not ok then
          return nil, err
        end
      end
      return launch(record.active_backend, proposed, true)
    end
    local written, err = publish_record(proposed, record)
    if not written then
      return nil, err
    end
    record = proposed
    emit()
    return true
  end

  function coordinator:prepare_review(review_id)
    if launching or transferring or stopped then
      return nil, "AI session is busy or shut down"
    end
    if
      type(review_id) ~= "string"
      or #review_id > 128
      or not review_id:match("^review_[0-9a-f]+$")
    then
      return fail("AI review ID is invalid")
    end
    if not attached and not self:attach() then
      return nil, diagnostic
    end
    if not load_record() then
      return nil, diagnostic
    end
    if present(record.review_id) then
      if record.review_id == review_id then
        return true
      end
      return fail("AI review batch is already active")
    end
    local proposed = copy(record)
    proposed.review_id = review_id
    proposed.completed_review_id = nil
    return save_or_relaunch(proposed)
  end

  function coordinator:finish_review(review_id)
    if launching or transferring or stopped then
      return nil, "AI session is busy or shut down"
    end
    if
      type(review_id) ~= "string"
      or #review_id > 128
      or not review_id:match("^review_[0-9a-f]+$")
    then
      return fail("AI review ID is invalid")
    end
    if not attached and not self:attach() then
      return nil, diagnostic
    end
    if not load_record() then
      return nil, diagnostic
    end
    if not present(record.review_id) and record.completed_review_id == review_id then
      -- A failed tracker acknowledgement must not repeat the completed transition.
      -- Re-read durable state and rediscover the pane: this coordinator may be stale.
      if
        not self:attach()
        or refused
        or reconcile
        or present(record.review_id)
        or record.completed_review_id ~= review_id
        or unresolved > 0
      then
        return fail("AI completed review acknowledgement requires verified read-only state")
      end
      return true
    end
    if not present(record.review_id) or record.review_id ~= review_id then
      return fail("AI review ID does not match the active batch")
    end
    if unresolved > 0 then
      return fail("AI review still contains unresolved or conflicted paths")
    end
    local proposed = copy(record)
    proposed.review_id = vim.NIL
    proposed.completed_review_id = review_id
    if not pane and options.tracker then
      if refused and closed_review_cleanup ~= review_id then
        return fail("AI pane requires explicit reconciliation before review resolution")
      end
      local previous = copy(record)
      local written, err = publish_record(proposed, previous)
      if not written then
        return nil, err
      end
      record = proposed
      -- The review UI owns baseline cleanup after a live read-only relaunch.
      -- With no process, this method is the complete closed-batch resolution.
      if not call(options.tracker, "abandon") then
        if publish_record(previous, proposed) then
          record, closed_review_cleanup = previous, review_id
        end
        return block("AI closed review baseline cleanup failed; retry review resolution explicitly")
      end
      closed_review_cleanup, refused, diagnostic = nil, false, nil
      emit("closed")
      return true
    end
    return save_or_relaunch(proposed)
  end

  -- Only the confirmed command transaction may discard attribution to an old
  -- review. Unlike finish_review, this never creates a cleanup receipt.
  function coordinator:abandon_review(review_id)
    if launching or transferring or stopped then
      return nil, "AI session is busy or shut down"
    end
    if not self:attach() or pane or refused or reconcile then
      return nil, "AI review abandonment requires verified closed execution"
    end
    if not load_record() then
      return nil, diagnostic
    end
    local bound = present(record.review_id) and record.review_id or record.completed_review_id
    if type(review_id) ~= "string" or bound ~= review_id then
      return nil, "AI review ID does not match the abandoned batch"
    end
    local proposed = copy(record)
    proposed.review_id, proposed.completed_review_id = vim.NIL, vim.NIL
    if not publish_record(proposed, record) then
      return nil, diagnostic
    end
    record = proposed
    emit()
    return true
  end

  function coordinator:set_grants(grants)
    if launching or transferring or stopped then
      return nil, "AI session is busy or shut down"
    end
    if not attached and not self:attach() then
      return nil, diagnostic
    end
    if not load_record() then
      return nil, diagnostic
    end
    local validated = require("ai.sandbox").validate_grants(identity, grants)
    if not validated then
      return fail("AI scope grants are invalid or unavailable")
    end
    local proposed = copy(record)
    proposed.grants = validated
    return save_or_relaunch(proposed)
  end

  function coordinator:handle_event(event)
    if
      launching
      or stopped
      or refused
      or reconcile
      or not pane
      or not record
      or type(event) ~= "table"
    then
      return nil
    end
    local fields = { schema = true, backend = true, session = true, state = true, time = true }
    local count = 0
    for key in pairs(event) do
      if not fields[key] then
        return nil
      end
      count = count + 1
    end
    if
      count ~= 5
      or event.schema ~= 1
      or event.backend ~= record.active_backend
      or type(event.session) ~= "string"
      or #event.session > 128
      or type(event.time) ~= "number"
      or not (event.time >= 0 and event.time <= 9007199254740991)
    then
      return nil
    end
    local common = event.state == "open" or event.state == "failed"
    local capability = ({
      idle = "busy",
      busy = "busy",
      approval = "approval",
      completed = "completion",
    })[event.state]
    local adapter = call(registry, "get", record.active_backend)
    local capabilities = call(adapter, "capabilities") or {}
    if not common and (not capability or capabilities[capability] ~= true) then
      return nil
    end
    if event.state == state or not transitions[state][event.state] then
      return nil
    end
    local reference = record.sessions[event.backend]
    if
      event.backend == "opencode"
      and reference == ""
      and #event.session >= 5
      and event.session:match("^ses_[A-Za-z0-9_-]+$")
    then
      local proposed = copy(record)
      proposed.sessions.opencode = event.session
      if not publish_record(proposed, record) then
        return nil
      end
      if not call(transport, "tag", pane, metadata(proposed, state)) then
        if
          not publish_record(record, proposed)
          or not call(transport, "tag", pane, metadata(record, state))
        then
          return block("AI event session publication requires explicit reconciliation")
        end
        return fail("AI event session metadata could not be published")
      end
      record, reference = proposed, event.session
    end
    if event.session ~= reference then
      return nil
    end
    return emit(event.state)
  end

  local function close_transaction()
    if refused then
      local candidates = call(transport, "owned_panes", identity)
      if
        not candidates
        or #candidates > 1
        or (
          #candidates == 1
          and (
            candidates[1].key ~= identity.key
            or candidates[1].owner ~= identity.owner_pane
            or candidates[1].root ~= identity.root
          )
        )
      then
        return fail("AI stale pane ownership is ambiguous; close refused")
      end
      if
        #candidates == 1
        and (
          not options.confirm
          or options.confirm(
              "Close the one verified identity-matching AI pane? Its unverified session will be stopped; the next open creates a fresh managed activation."
            )
            ~= true
        )
      then
        return nil, "AI stale pane close cancelled"
      end
      -- Confirmations may yield: recheck both uniqueness and identity afterwards.
      local checked = call(transport, "owned_panes", identity)
      if not vim.deep_equal(candidates, checked) then
        return fail("AI stale pane ownership changed; close refused")
      end
      pane = candidates[1] and candidates[1].pane or nil
    end
    if not load_record() then
      return nil, diagnostic
    end
    if pane then
      local adapter = call(registry, "get", record.active_backend)
      if not call(transport, "close", pane, call(adapter, "stop")) then
        return block("AI owned pane could not be closed")
      end
      pane = nil
    end
    local proposed = copy(record)
    proposed.grants, proposed.opencode_profile = {}, vim.NIL
    for _, method in ipairs({ "cleanup_contexts", "remove_control_token", "cleanup_launches" }) do
      if not call(store, method) then
        return block("AI pane is closed but private cleanup failed")
      end
    end
    if not publish_record(proposed, record) then
      return block("AI pane is closed but durable cleanup failed")
    end
    record, diagnostic, refused, reconcile = proposed, nil, false, false
    emit("closed")
    return true
  end

  function coordinator:close()
    if launching or transferring then
      return nil, "AI lifecycle operation is already in progress"
    end
    cancel_open("close")
    if not attached then
      self:attach()
    end
    -- Stopping yields to native exit events. Fence them, and concurrent commands,
    -- until the verified stop and durable cleanup have completed or failed.
    launching = true
    local ok, result, err = pcall(close_transaction)
    launching = false
    if not ok then
      return block("AI close operation failed; explicit close is required")
    end
    return result, err
  end

  function coordinator:shutdown()
    if launching or transferring then
      return nil, "AI lifecycle operation is already in progress"
    end
    stopped = true
    -- Registry lifetime belongs to command wiring, not one identity coordinator.
    cancel_open("close")
    if unsubscribe_validation then
      pcall(unsubscribe_validation)
      unsubscribe_validation = nil
    end
    if unsubscribe_tracker then
      pcall(unsubscribe_tracker)
      unsubscribe_tracker = nil
    end
    subscribers = {}
    if not identity.tmux_socket then
      return self:close()
    end
    return true
  end

  if type(registry.subscribe_opencode_compatibility) == "function" then
    unsubscribe_validation = call(registry, "subscribe_opencode_compatibility", function(report)
      if stopped or type(report) ~= "table" then
        return
      end
      validation = report.state
      if pending_open and report.state == "ready" then
        local generation = queue_generation
        local schedule = options.schedule or vim.schedule
        schedule(function()
          if stopped or not pending_open or generation ~= queue_generation then
            return
          end
          if not call(registry, "take_opencode_open", identity.key) then
            return
          end
          pending_open = false
          local resolver = options.current_identity
            or function()
              return require("ai.identity").resolve()
            end
          local ok, current = pcall(resolver)
          if
            not ok
            or type(current) ~= "table"
            or current.key ~= identity.key
            or current.root ~= identity.root
            or current.namespace ~= identity.namespace
            or current.owner_pane ~= identity.owner_pane
            or current.tmux_socket ~= identity.tmux_socket
          then
            fail("AI queued opening cancelled because the current identity changed")
            return
          end
          if pane and record.active_backend ~= "opencode" then
            coordinator:switch("opencode")
          else
            coordinator:open("opencode")
          end
        end)
      elseif report.state == "failed" or report.state == "not_checked" then
        pending_open, queue_generation = false, queue_generation + 1
      end
      emit()
    end)
    if type(unsubscribe_validation) ~= "function" then
      return nil, "AI validation subscription is unavailable"
    end
  end

  if options.tracker then
    local function update_review(paths)
      if stopped or type(paths) ~= "table" or not vim.islist(paths) then
        return
      end
      local next_conflicts, next_unresolved = 0, 0
      for _, item in ipairs(paths) do
        if type(item) ~= "table" then
          return
        end
        if item.state == "conflicted" then
          next_conflicts = next_conflicts + 1
        end
        if item.state == "conflicted" or item.state == "unresolved" then
          next_unresolved = next_unresolved + 1
        end
      end
      conflicts, unresolved = next_conflicts, next_unresolved
      emit()
    end
    update_review(call(options.tracker, "paths"))
    unsubscribe_tracker = call(options.tracker, "subscribe", update_review)
    if type(unsubscribe_tracker) ~= "function" then
      return nil, "AI review subscription is unavailable"
    end
  end

  return coordinator
end

return M
