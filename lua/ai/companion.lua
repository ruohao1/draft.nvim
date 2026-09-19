-- Assemble one pinned identity from the existing safety modules. No prompt bytes live here.
local M = {}
local bit = require("bit")
local retained
local module_names = {
  "ai.tools",
  "ai.identity",
  "ai.state",
  "ai.backends",
  "ai.backends.codex",
  "ai.backends.claude",
  "ai.backends.opencode",
  "ai.backends.opencode_managed",
  "ai.backends.opencode_validation",
  "ai.sandbox",
  "ai.transports.tmux",
  "ai.transports.terminal",
  "ai.transports.metadata",
  "ai.session",
  "ai.context",
  "ai.prompt",
  "ai.review.baseline",
  "ai.review.task",
  "ai.review.tracker",
  "ai.review.reducer",
  "ai.review.serialization",
  "ai.review.mutation",
  "ai.review.ui",
  "ai.scope",
  "ai.events",
}

local function helper_metadata(path, executable)
  local stat = vim.uv.fs_lstat(path)
  if
    vim.uv.fs_realpath(path) ~= path
    or not stat
    or stat.type ~= "file"
    or (stat.uid ~= 0 and stat.uid ~= vim.uv.getuid())
    or bit.band(stat.mode, 18) ~= 0
    or (executable and bit.band(stat.mode, 73) == 0)
  then
    return nil
  end
  return {
    dev = stat.dev,
    ino = stat.ino,
    uid = stat.uid,
    mode = stat.mode,
    type = stat.type,
    size = stat.size,
    mtime = stat.mtime,
    ctime = stat.ctime,
  }
end

function M.new(options)
  if not retained then
    local loaded = {}
    for _, name in ipairs(module_names) do
      loaded[name] = require(name)
    end
    retained = loaded
  end
  local modules, identity = retained, options.identity
  local tools, tool_error = modules["ai.tools"].resolve_host({ identity = identity })
  if not tools then
    return nil, tool_error
  end
  local source = debug.getinfo(1, "S").source:sub(2)
  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
  local helpers, helper_stats = {}, {}
  for field, filename in pairs({
    launcher = "nvim-ai-launch.py",
    control_helper = "nvim-ai-control.py",
    event_helper = "nvim-ai-event.py",
    profile_helper = "nvim-ai-opencode-profile.py",
    review_helper = "nvim-ai-review.py",
  }) do
    local path = vim.uv.fs_realpath(root .. "/scripts/" .. filename)
    local stat = path and helper_metadata(path, field == "launcher")
    if not stat then
      return nil, "AI trusted helper is unavailable or unsafe"
    end
    helpers[field] = path
    helper_stats[field] = stat
  end
  local store, err = modules["ai.state"].open(identity)
  if not store then
    return nil, err
  end
  local registry = options.registry
  if not registry then
    registry = {}
    for _, method in ipairs({
      "names",
      "get",
      "health",
      "ensure_opencode_compatibility",
      "take_opencode_open",
      "cancel_opencode_compatibility",
      "subscribe_opencode_compatibility",
      "shutdown",
    }) do
      registry[method] = function(_, ...)
        return modules["ai.backends"][method](...)
      end
    end
  end
  local transport = options.transport
  if not transport then
    local name = identity.owner_pane and identity.tmux_socket and "ai.transports.tmux"
      or "ai.transports.terminal"
    transport, err = modules[name].new({
      tmux = tools.tmux,
      width = options.width,
      project_pairs = options.tmux_project_pairs == true,
    })
    if not transport then
      return nil, err
    end
  end
  local companion = {
    identity = identity,
    store = store,
    registry = registry,
    transport = transport,
    tools = tools,
    helpers = helpers,
    modules = modules,
  }
  local record, record_error = store:read_record()
  if record_error then
    return nil, "AI durable record could not be read"
  end
  local function absent(path)
    local stat, _, code = vim.uv.fs_lstat(path)
    return not stat and code == "ENOENT"
  end
  local function receipt_pending(id)
    return not absent(store:state_dir() .. "/reviews/" .. id:sub(8))
      or not absent(store:state_dir() .. "/decisions/" .. id:sub(8))
  end
  local function recorded_review(saved)
    if saved and type(saved.review_id) == "string" then
      return saved.review_id, false
    end
    local completed = saved and saved.completed_review_id
    if type(completed) == "string" and receipt_pending(completed) then
      return completed, true
    end
  end
  local restored, restored_id, acknowledged = nil, recorded_review(record)
  if restored_id then
    restored = modules["ai.review.baseline"].open(identity, store, restored_id:sub(8))
    if not restored then
      local phase, phase_error = store:read_review_phase(restored_id:sub(8))
      if
        not acknowledged
        or not absent(store:state_dir() .. "/reviews/" .. restored_id:sub(8))
        or phase_error
        or (phase and phase.phase ~= "cleanup")
      then
        companion.missing_review = restored_id
      end
    end
  end
  local session
  local tracker = modules["ai.review.tracker"].new({
    identity = identity,
    store = store,
    tools = tools,
    helpers = helpers,
    baseline = restored,
    finish_review = function(id)
      return session:finish_review("review_" .. id)
    end,
  })
  companion.tracker = tracker
  session, err = modules["ai.session"].new({
    identity = identity,
    store = store,
    transport = transport,
    registry = registry,
    sandbox = {
      prepare = function(launch)
        local valid, validation_error = companion:revalidate()
        if not valid then
          return nil, validation_error
        end
        if launch.writable then
          local ready, review_error = companion:review_ready(launch.review_id)
          if not ready then
            return nil, review_error
          end
        end
        return (options.sandbox or modules["ai.sandbox"]).prepare(launch)
      end,
    },
    tracker = tracker,
    tools = tools,
    helpers = helpers,
    home = options.home,
    data_home = options.data_home,
    current_identity = modules["ai.identity"].resolve,
    schedule = options.schedule_native,
    confirm = function(message)
      if options.confirm then
        return options.confirm(message)
      end
      return vim.fn.confirm(message, "&Continue\n&Cancel", 2) == 1
    end,
    notify = options.notify,
  })
  if not session then
    tracker:shutdown()
    return nil, err
  end
  companion.session = session
  if restored and not tracker:ensure_batch() then
    companion.missing_review = restored_id
  end
  companion.context = modules["ai.context"].new({ store = store })
  local protected_paths = vim.deepcopy(options.protected_paths or {})
  protected_paths[#protected_paths + 1] = (options.home or vim.env.HOME) .. "/AGENTS.md"
  for _, paths in ipairs({ tools, helpers }) do
    for _, path in pairs(paths) do
      protected_paths[#protected_paths + 1] = path
    end
  end
  companion.scope = assert(modules["ai.scope"].new({
    identity = identity,
    store = store,
    session = session,
    home = options.home,
    data_home = options.data_home,
    config_home = options.config_home,
    protected_paths = protected_paths,
    on_result = function(result)
      companion:refresh(
        nil,
        result.ok and (result.code == "revoked" and "scope_revoked" or "scope_granted")
          or "scope_refused"
      )
    end,
  }))
  local reader, reader_key, latest_event, seeding, reader_activation
  local function synchronize_events(snapshot, restore_event)
    local new_activation = snapshot.activation > 0 and snapshot.activation ~= reader_activation
    reader_activation = snapshot.activation
    local key = snapshot.pane and snapshot.backend and snapshot.backend .. ":" .. snapshot.pane
      or nil
    if key ~= reader_key then
      if reader then
        reader:stop()
      end
      reader, reader_key, latest_event = nil, key, nil
      if key then
        local paths = store:launch_paths(snapshot.backend, false)
        if paths then
          reader = modules["ai.events"].new({
            path = paths.event_file,
            backend = snapshot.backend,
            session = function()
              return session:snapshot().sessions[snapshot.backend]
            end,
          })
          reader:subscribe(function(event)
            local accepted = session:handle_event(event)
            -- Expected stop events ignored by the lifecycle guard must not be
            -- cached and replayed after that guard releases the replacement.
            if accepted or event.state ~= "failed" then
              latest_event = event
            end
          end)
          local started, seed = reader:start()
          if started then
            latest_event = seed
          else
            reader:stop()
            reader = nil
          end
          restore_event = true
        end
      end
    end
    if new_activation then
      -- The previous process has stopped. Drain its unread tail while the
      -- launch transaction still guards events, before accepting fresh events.
      if reader then
        reader:poll()
      end
      if latest_event and latest_event.state == "failed" then
        latest_event = nil
      end
    end
    if restore_event and latest_event and snapshot.state ~= "paused" then
      seeding = true
      session:handle_event(latest_event)
      seeding = false
      return true
    end
  end
  function companion:refresh(snapshot, category, restore_event)
    snapshot = snapshot or session:snapshot()
    local affected_path = snapshot.affected_path
    local replayed = synchronize_events(snapshot, restore_event)
    snapshot = session:snapshot()
    snapshot.affected_path = affected_path
    if options.publish then
      local adapter = snapshot.backend and registry:get(snapshot.backend)
      snapshot.capabilities = adapter and adapter:capabilities() or {}
      snapshot.root, snapshot.identity_key, snapshot.owner_pane =
        identity.root, identity.key, identity.owner_pane
      if companion.missing_review then
        snapshot.state, snapshot.conflicts = "conflicted", math.max(1, snapshot.conflicts or 0)
        snapshot.unresolved = math.max(1, snapshot.unresolved or 0)
      end
      category = category
        or ({
          approval = "approval",
          completed = "completed",
          failed = "failed",
          conflicted = "conflict",
          paused = "paused",
        })[snapshot.state]
      options.publish(snapshot, not seeding and not replayed and category or nil)
    end
  end
  local unsubscribe = session:subscribe(function(snapshot)
    companion:refresh(snapshot)
  end)
  local observed_paths = {}
  for _, item in ipairs(tracker:paths()) do
    observed_paths[item.path] = item
  end
  local unsubscribe_changes = tracker:subscribe(function(paths)
    local previous = observed_paths
    observed_paths = {}
    for _, item in ipairs(paths) do
      observed_paths[item.path] = item
      if
        (item.state == "unresolved" or item.state == "conflicted")
        and not vim.deep_equal(previous[item.path], item)
      then
        local snapshot = session:snapshot()
        snapshot.affected_path = item.path
        companion:refresh(snapshot, item.state == "conflicted" and "conflict" or "changes")
      end
    end
  end)
  function companion:review_id()
    local saved, read_error = store:read_record()
    if read_error then
      return nil, nil, "AI durable record could not be read"
    end
    local id, completed = recorded_review(saved)
    return id or tracker:batch_status().review_id, completed
  end
  function companion:review_ready(expected_id, resolving)
    local id, completed, read_error = self:review_id()
    if read_error then
      return nil, read_error
    end
    if expected_id and expected_id ~= id then
      self.missing_review = expected_id
    end
    if id and not self.missing_review then
      local phase, phase_error = store:read_review_phase(id:sub(8))
      if phase_error or (phase and not completed) then
        self.missing_review = id
      elseif completed and not resolving then
        return nil,
          "AI saved read-only review needs explicit resolution or cleanup with :NvimAIReview before another writable launch"
      elseif tracker:batch_status().review_id ~= id then
        if not completed or not absent(store:state_dir() .. "/reviews/" .. id:sub(8)) then
          self.missing_review = id
        end
      elseif not (completed and phase and phase.phase == "cleanup") then
        if not tracker:scan(resolving and "before_review" or "before_writable") then
          self.missing_review = id
        elseif tracker:batch_status().reason and not resolving then
          return nil,
            "AI review needs explicit resolution or cleanup with :NvimAIReview before another writable launch"
        end
      end
    end
    if self.missing_review then
      self:refresh()
      return nil,
        "AI saved baseline is missing or invalid; automatic rejection is disabled. Resolve manually or explicitly abandon with :NvimAIReview!"
    end
    return true
  end
  function companion:revalidate()
    for _, path in pairs(tools) do
      if not modules["ai.tools"].revalidate(path) then
        return nil, "AI trusted host tool changed"
      end
    end
    for name, path in pairs(helpers) do
      if not vim.deep_equal(helper_stats[name], helper_metadata(path, name == "launcher")) then
        return nil, "AI trusted helper changed"
      end
    end
    return true
  end
  function companion:shutdown()
    if unsubscribe then
      unsubscribe()
      unsubscribe = nil
    end
    if unsubscribe_changes then
      unsubscribe_changes()
      unsubscribe_changes = nil
    end
    if reader then
      reader:stop()
      reader = nil
    end
    local closed = session:shutdown()
    local scope_closed = self.scope:stop()
    local tracker_closed = tracker:shutdown()
    local review_closed = not self.review or self.review:close()
    local registry_closed = true
    if registry.shutdown then
      registry_closed = registry:shutdown(true)
    end
    return closed and scope_closed and tracker_closed and registry_closed and review_closed
  end
  return companion
end

return M
