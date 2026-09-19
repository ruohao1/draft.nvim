local baseline_module = require("ai.review.baseline")
local reducer = require("ai.review.reducer")
local review_task = require("ai.review.task")

local M = {}

local function clone(value)
  return vim.deepcopy(value)
end

local function classify_writer(input)
  if input.current_hash == input.baseline_hash then
    return { writer = input.nvim_seen and "nvim" or "none", state = "unchanged" }
  end
  if input.external_seen and input.nvim_seen then
    return { writer = "mixed", state = "conflicted" }
  end
  if
    input.last_nvim_hash
    and input.current_hash == input.last_nvim_hash
    and not input.external_seen
  then
    return { writer = "nvim", state = "unchanged" }
  end
  if input.nvim_seen then
    return { writer = "mixed", state = "conflicted" }
  end
  return { writer = "external", state = "unresolved" }
end

local function strip_storage(object)
  return {
    kind = object.kind,
    mode = object.mode,
    size = object.size,
    sha256 = object.sha256,
    storage = nil,
    tree_oid = nil,
  }
end

local function absent_object()
  return {
    kind = "absent",
    mode = nil,
    size = 0,
    sha256 = nil,
    storage = nil,
    tree_oid = nil,
  }
end

local function unsupported_object()
  return {
    kind = "unsupported",
    mode = nil,
    size = 0,
    sha256 = nil,
    storage = nil,
    tree_oid = nil,
  }
end

local function valid_relative(path)
  if type(path) ~= "string" or path == "" or path:sub(1, 1) == "/" or path:find("\0", 1, true) then
    return false
  end
  if path:find("//", 1, true) or path:sub(-1) == "/" then
    return false
  end
  for component in path:gmatch("[^/]+") do
    if component == "." or component == ".." then
      return false
    end
  end
  return true
end

local function default_buffer_state(path, identity)
  local full = identity.root .. "/" .. path
  local target = vim.uv.fs_stat(full)
  local result = { loaded = false, modified = false, bufnrs = {} }
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      local stat = name ~= "" and vim.uv.fs_stat(name) or nil
      if
        vim.fs.normalize(name, { expand_env = false }) == full
        or (target and stat and target.dev == stat.dev and target.ino == stat.ino)
      then
        result.loaded = true
        result.bufnr = result.bufnr or bufnr
        result.bufnrs[#result.bufnrs + 1] = bufnr
        result.modified = result.modified
          or vim.api.nvim_get_option_value("modified", { buf = bufnr })
      end
    end
  end
  return result
end

local function default_reload(bufnr, _, object)
  -- Like native autoread, retain the last buffer text when the file disappears.
  -- A changed symlink is metadata-only: do not follow a new target in the editor.
  if object.kind == "absent" then
    return true
  end
  if object.kind ~= "regular" then
    return nil, "changed non-regular buffer requires manual reload"
  end
  local ok, reloaded = pcall(vim.api.nvim_buf_call, bufnr, function()
    if vim.bo[bufnr].modified then
      return false
    end
    local view = vim.fn.winsaveview()
    local edited = false
    local guard = vim.api.nvim_create_autocmd("BufReadPost", {
      buffer = bufnr,
      callback = function()
        edited = vim.bo[bufnr].modified
      end,
    })
    -- checktime can defer work and opens W16's modal dialog for a formerly
    -- absent file. Reload this exact unmodified buffer synchronously, without
    -- bang, so the tracker never holds its scan lease across that dialog.
    local read = pcall(vim.api.nvim_cmd, {
      cmd = "edit",
      mods = { keepalt = true, keepjumps = true },
    }, {})
    pcall(vim.api.nvim_del_autocmd, guard)
    if edited and vim.api.nvim_buf_is_valid(bufnr) then
      -- :edit clears 'modified' after BufReadPost, even if a user hook edited
      -- the loaded text. Preserve that edit and make the review manual-only.
      vim.bo[bufnr].modified = true
    end
    if not read or edited then
      return false
    end
    vim.fn.winrestview(view)
    return true
  end)
  if not ok or not reloaded then
    return nil, "buffer reload failed; resolve the file manually"
  end
  return true
end

local function default_path_for_buffer(bufnr, identity)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "buffer is invalid"
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if type(name) ~= "string" or name == "" then
    return nil, "buffer has no file path"
  end
  local normalized = vim.fs.normalize(name, { expand_env = false })
  if normalized:sub(1, #identity.root + 1) ~= identity.root .. "/" then
    return nil, "buffer is outside the AI root"
  end
  local path = normalized:sub(#identity.root + 2)
  if not valid_relative(path) then
    return nil, "buffer path is invalid"
  end
  return path
end

local function default_loaded_paths(identity)
  local result = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local path = default_path_for_buffer(bufnr, identity)
      if path then
        result[path] = true
      end
    end
  end
  return vim.tbl_keys(result)
end

local function safe_close(handle)
  if not handle then
    return true
  end
  local ok = true
  if handle.stop then
    local stopped = pcall(handle.stop, handle)
    ok = stopped and ok
  end
  local closing = false
  if handle.is_closing then
    local checked, result = pcall(handle.is_closing, handle)
    if not checked then
      ok = false
    else
      closing = result == true
    end
  end
  if handle.close and not closing then
    local closed = pcall(handle.close, handle)
    ok = closed and ok
  end
  return ok
end

local default_dependencies = {
  baseline_module = baseline_module,
  scanner = function(identity, requested_paths)
    return baseline_module._internal.scan_current(identity, requested_paths)
  end,
  fingerprint_hash = baseline_module._internal.fingerprint_hash,
  read_current = baseline_module._internal.read_current,
  buffer_state = default_buffer_state,
  reload = default_reload,
  path_for_buffer = default_path_for_buffer,
  loaded_paths = default_loaded_paths,
  new_fs_event = vim.uv.new_fs_event,
  new_timer = vim.uv.new_timer,
  schedule = vim.schedule,
  revalidate_baseline = function(identity, store, review_id)
    return baseline_module.open(identity, store, review_id)
  end,
  create_augroup = vim.api.nvim_create_augroup,
  create_autocmd = vim.api.nvim_create_autocmd,
  del_augroup = vim.api.nvim_del_augroup_by_id,
}

local function new(options)
  options = options or {}
  local deps = vim.tbl_extend("force", {}, default_dependencies)
  for key in pairs(default_dependencies) do
    if options[key] ~= nil then
      deps[key] = options[key]
    end
  end

  local identity = options.identity
  local store = options.store
  local mutation = require("ai.review.mutation").new(options)
  local supplied_baseline = options.baseline
  local start_watchers = options.start_watchers ~= false
  local tracker = {}
  local active
  local manifest
  local records = {}
  local metadata = {}
  local subscribers = {}
  local signaled = {}
  local watcher
  local debounce
  local periodic
  local augroup
  local shutdown_result
  local stopped = false
  local batch_conflict_reason
  local scan_running = false
  local rescan_requested = false
  local decision_running = false
  local view_running = false
  local journal_verified = false
  local manual_action = false
  local write_epoch, action_epoch = 0, 0
  local resolution_running = false
  local resolution_error
  local decision_payload
  local resolution_phase
  local relaunch_complete = false
  local baseline_removed = false
  local background_scan
  local signal_epoch = 0

  local function cancel_background_scan()
    if background_scan and not background_scan:current() then
      background_scan:cancel()
      background_scan = nil
      scan_running, rescan_requested = false, false
    end
  end

  local function read_resolution_phase()
    if type(store.read_review_phase) ~= "function" then
      return true
    end
    local ok, record, err = pcall(store.read_review_phase, store, active:id())
    if not ok or err or (record and record.baseline_hash ~= manifest.baseline_hash) then
      return nil, "private review resolution phase is unavailable"
    end
    if record then
      resolution_phase, relaunch_complete = record.phase, true
    end
    return true
  end

  local function close_runtime_sources()
    local watcher_closed = safe_close(watcher)
    local debounce_closed = safe_close(debounce)
    local periodic_closed = safe_close(periodic)
    local augroup_closed = true
    if augroup then
      augroup_closed = pcall(deps.del_augroup, augroup)
    end
    watcher = nil
    debounce = nil
    periodic = nil
    augroup = nil
    return watcher_closed and debounce_closed and periodic_closed and augroup_closed
  end

  local function hash_object(object)
    return deps.fingerprint_hash(strip_storage(object))
  end

  local function valid_scan_object(object)
    if type(object) ~= "table" then
      return false
    end
    for key in pairs(object) do
      if
        key ~= "kind"
        and key ~= "mode"
        and key ~= "size"
        and key ~= "sha256"
        and key ~= "storage"
        and key ~= "tree_oid"
      then
        return false
      end
    end
    if object.storage ~= nil or object.tree_oid ~= nil then
      return false
    end
    if object.kind == "absent" or object.kind == "unsupported" then
      return object.mode == nil and object.size == 0 and object.sha256 == nil
    end
    if object.kind ~= "regular" and object.kind ~= "symlink" then
      return false
    end
    local valid_mode = object.kind == "regular"
        and (object.mode == "100644" or object.mode == "100755")
      or object.kind == "symlink" and object.mode == "120000"
    return valid_mode
      and type(object.size) == "number"
      and object.size >= 0
      and object.size % 1 == 0
      and type(object.sha256) == "string"
      and #object.sha256 == 64
      and object.sha256:match("^[0-9a-f]+$") ~= nil
  end

  local function validate_scan_entry(path, entry)
    if not valid_relative(path) then
      return nil, "authoritative scanner returned an invalid path"
    end
    if
      type(entry) ~= "table"
      or type(entry.hash) ~= "string"
      or #entry.hash ~= 64
      or entry.hash:match("^[0-9a-f]+$") == nil
      or type(entry.binary) ~= "boolean"
      or (entry.reason ~= nil and type(entry.reason) ~= "string")
      or not valid_scan_object(entry.object)
    then
      return nil, "authoritative scanner returned an invalid entry"
    end
    for key in pairs(entry) do
      if key ~= "object" and key ~= "hash" and key ~= "binary" and key ~= "reason" then
        return nil, "authoritative scanner returned an invalid entry"
      end
    end
    local hashed, expected = pcall(hash_object, entry.object)
    if not hashed or expected ~= entry.hash then
      return nil, "authoritative scanner returned an inconsistent fingerprint"
    end
    return true
  end

  local function public_record(
    path,
    baseline,
    current,
    current_hash,
    writer,
    state,
    action,
    reason,
    decision
  )
    return {
      path = path,
      baseline = clone(baseline),
      decision_base = decision and clone(decision) or nil,
      current = clone(current),
      current_hash = current_hash,
      writer = writer,
      state = state,
      action = action,
      reason = reason,
    }
  end

  local function notify(reason)
    if #subscribers == 0 then
      return
    end
    local snapshot = tracker:paths()
    for _, callback in ipairs(clone(subscribers)) do
      pcall(callback, clone(snapshot), reason)
    end
  end

  local function ensure_record(path, baseline, ignored_at_baseline, visible_at_baseline)
    if records[path] then
      return metadata[path]
    end
    baseline = baseline or absent_object()
    local current = strip_storage(baseline)
    local baseline_hash = hash_object(baseline)
    local state = batch_conflict_reason and "conflicted"
      or baseline.kind == "unsupported" and "unsupported"
      or ignored_at_baseline and "ignored"
      or "unchanged"
    local action = "none"
    local meta = {
      baseline = clone(baseline),
      baseline_hash = baseline_hash,
      current_hash = baseline_hash,
      last_hash = baseline_hash,
      last_nvim_hash = nil,
      nvim_seen = false,
      external_seen = false,
      ignored_at_baseline = ignored_at_baseline == true,
      visible_at_baseline = visible_at_baseline == true,
      ignored_now = ignored_at_baseline == true,
      binary = false,
      baseline_binary = false,
      latched_conflict = batch_conflict_reason ~= nil,
      decision_hash = nil,
      decision_base = nil,
    }
    metadata[path] = meta
    records[path] = public_record(
      path,
      baseline,
      current,
      baseline_hash,
      "none",
      state,
      action,
      batch_conflict_reason or state == "unsupported" and "unsupported baseline object" or nil
    )
    return meta
  end

  local function decode_manifest()
    local seen = {}
    for _, item in ipairs(manifest.paths or {}) do
      local path = deps.baseline_module._internal
          and deps.baseline_module._internal.decode_hex(item.path_hex)
        or baseline_module._internal.decode_hex(item.path_hex)
      if not path or not valid_relative(path) or seen[path] then
        return nil, "baseline manifest path is invalid"
      end
      seen[path] = true
      local meta = ensure_record(path, assert(active:read(path)), false, true)
      local bytes = active:bytes(path)
      meta.baseline_binary = type(bytes) == "string" and not reducer.is_text(bytes)
    end
    for _, item in ipairs(manifest.ignored or {}) do
      local path = deps.baseline_module._internal
          and deps.baseline_module._internal.decode_hex(item.path_hex)
        or baseline_module._internal.decode_hex(item.path_hex)
      if not path or not valid_relative(path) or seen[path] then
        return nil, "baseline ignored path is invalid"
      end
      seen[path] = true
      ensure_record(path, assert(active:ignored_fingerprint(path)), true, false)
    end
    return true
  end

  local function action_for(meta, current, binary)
    if current.kind == "unsupported" or meta.baseline.kind == "unsupported" then
      return "none"
    end
    if current.kind ~= meta.baseline.kind or current.mode ~= meta.baseline.mode then
      return "whole"
    end
    if current.kind ~= "regular" or binary or meta.baseline_binary then
      return "whole"
    end
    return "hunks"
  end

  local function persist_observation(path, current, current_hash)
    -- Task 7's scanner-only test seam has no durable store or action capability.
    if type(store.write_review_decision) ~= "function" then
      return true
    end
    local lease
    if not decision_running and not view_running then
      local acquired, value = pcall(function()
        return require("ai.review.serialization").acquire(store:state_dir())
      end)
      if not acquired or not value then
        return nil, "writer observation serialization failed"
      end
      lease = value
    end
    local invoked, saved = pcall(function()
      local latest, err = store:read_review_decision(active:id(), path)
      if err or not vim.deep_equal(latest, metadata[path].saved_decision) then
        return nil
      end
      local payload = decision_payload(
        path,
        { object = current, hash = current_hash },
        absent_object(),
        records[path].state,
        0
      )
      payload.decision_base, payload.observation = nil, true
      if not store:write_review_decision(active:id(), payload, nil) then
        return nil
      end
      metadata[path].saved_decision = clone(payload)
      return true
    end)
    local released = true
    if lease then
      local ok, result = pcall(lease.release, lease)
      released = ok and result == true
    end
    if not invoked or not saved or not released then
      return nil, "durable writer observation failed"
    end
    return true
  end

  local function apply_state(path, current, current_hash, binary, ignored_now, reason, nvim_write)
    local meta = metadata[path]
    local old = records[path]
    local changed_since_observation = current_hash ~= meta.last_hash
    if
      changed_since_observation and not (meta.nvim_seen and current_hash == meta.last_nvim_hash)
    then
      meta.external_seen = true
    end
    local invalidated = meta.decision_hash and (current_hash ~= meta.decision_hash or nvim_write)
    if invalidated then
      meta.decision_hash = nil
      meta.decision_base = nil
      meta.decision_bytes = nil
      meta.manual = nil
    end
    meta.current_hash = current_hash
    meta.binary = binary == true
    meta.ignored_now = ignored_now == true
    if batch_conflict_reason then
      meta.latched_conflict = true
    end

    local writer = "none"
    local state = "unchanged"
    local action = "none"
    local state_reason = reason
    if manifest.conflict_only then
      if current_hash ~= meta.baseline_hash or meta.external_seen or meta.nvim_seen then
        writer = meta.nvim_seen and "mixed" or "external"
        state = "conflicted"
        state_reason = state_reason or "non-Git review batch is conflict-only"
        meta.latched_conflict = true
      end
    elseif meta.ignored_at_baseline and not ignored_now and current.kind ~= "absent" then
      writer = "external"
      state = "conflicted"
      state_reason = "ignored baseline path became Git-visible"
      meta.latched_conflict = true
    elseif meta.visible_at_baseline and ignored_now then
      writer = "external"
      state = "conflicted"
      state_reason = "Git-visible baseline path became ignored"
      meta.latched_conflict = true
    elseif ignored_now or (meta.ignored_at_baseline and current.kind == "absent") then
      writer = "none"
      state = "ignored"
      state_reason = "ignored path fingerprint only"
    elseif current.kind == "unsupported" or meta.baseline.kind == "unsupported" then
      writer = current_hash == meta.baseline_hash and "none" or "external"
      state = current_hash == meta.baseline_hash and "unsupported" or "conflicted"
      state_reason = state_reason or "unsupported path type"
      if state == "conflicted" then
        meta.latched_conflict = true
      end
    else
      local classified = classify_writer({
        baseline_hash = meta.baseline_hash,
        current_hash = current_hash,
        last_nvim_hash = meta.last_nvim_hash,
        external_seen = meta.external_seen,
        nvim_seen = meta.nvim_seen,
      })
      writer = classified.writer
      state = classified.state
      if state == "conflicted" then
        meta.latched_conflict = true
      end
      if meta.latched_conflict then
        writer = meta.nvim_seen and "mixed" or writer
        state = "conflicted"
      elseif meta.decision_hash == current_hash then
        state = old.state
      end
      if state == "unresolved" then
        action = action_for(meta, current, binary)
        state_reason = state_reason or "Git-visible external change"
      elseif state == "conflicted" then
        state_reason = state_reason or "multiple or unsafe writers"
      end
    end
    if
      not batch_conflict_reason
      and meta.decision_hash == current_hash
      and old.state == "accepted"
      and (meta.manual or not meta.latched_conflict)
    then
      meta.latched_conflict = false
      state = "accepted"
      action = "none"
      state_reason = nil
      if meta.manual then
        writer, state_reason = old.writer, "manually resolved"
      end
    elseif meta.latched_conflict then
      writer = meta.nvim_seen and "mixed" or writer
      state = "conflicted"
      action = "none"
      state_reason = batch_conflict_reason or state_reason or "conflict is latched"
    end

    records[path] = public_record(
      path,
      meta.baseline,
      current,
      current_hash,
      writer,
      state,
      action,
      state_reason,
      meta.decision_base
    )
    records[path].unresolved_hunks = meta.decision_hash == current_hash and old.unresolved_hunks
      or nil
    if invalidated or nvim_write then
      local saved, err = persist_observation(path, current, current_hash)
      if not saved then
        meta.latched_conflict = true
        records[path].state, records[path].action, records[path].reason = "conflicted", "none", err
      end
    end
    return changed_since_observation
  end

  local function scanner_requested_paths()
    local requested = {}
    for path in pairs(records) do
      requested[path] = true
    end
    for path in pairs(signaled) do
      if valid_relative(path) then
        requested[path] = true
      end
    end
    local ok, loaded = pcall(deps.loaded_paths, identity)
    if not ok or type(loaded) ~= "table" then
      return nil, "loaded-buffer enumeration failed"
    end
    for _, path in ipairs(loaded) do
      if not valid_relative(path) then
        return nil, "loaded-buffer enumeration returned an invalid path"
      end
      requested[path] = true
    end
    local paths = vim.tbl_keys(requested)
    table.sort(paths)
    return paths
  end

  local function fingerprint_single(path)
    if options.fingerprint_path then
      local ok, result, err = pcall(options.fingerprint_path, path, identity)
      if not ok then
        return nil, "path fingerprint failed"
      end
      if result then
        local checked = clone(result)
        checked.ignored = nil
        local valid, validation_error = validate_scan_entry(path, checked)
        if not valid then
          return nil, validation_error
        end
      end
      return result, err
    end
    local invoked, scanned, scan_error = pcall(deps.scanner, identity, { path })
    if not invoked then
      return nil, "path scanner raised an exception"
    end
    if not scanned then
      return nil, scan_error
    end
    if type(scanned.paths) ~= "table" or type(scanned.ignored) ~= "table" then
      return nil, "path scanner returned an invalid result"
    end
    if scanned.paths[path] and scanned.ignored[path] then
      return nil, "path scanner returned an ambiguous path"
    end
    if scanned.paths[path] then
      local valid, validation_error = validate_scan_entry(path, scanned.paths[path])
      if not valid then
        return nil, validation_error
      end
      return scanned.paths[path]
    end
    if scanned.ignored[path] then
      local valid, validation_error = validate_scan_entry(path, scanned.ignored[path])
      if not valid then
        return nil, validation_error
      end
      local ignored = clone(scanned.ignored[path])
      ignored.ignored = true
      return ignored
    end
    return {
      object = absent_object(),
      hash = hash_object(absent_object()),
      binary = false,
    }
  end

  local function buffer_sync(path, expected_hash)
    local ok, state = pcall(deps.buffer_state, path, identity)
    if not ok or type(state) ~= "table" then
      return nil, "buffer state is unavailable"
    end
    if not state.loaded then
      return true
    end
    if state.modified then
      return nil, "modified buffer was changed externally"
    end
    if type(state.bufnr) ~= "number" then
      return nil, "loaded buffer number is unavailable"
    end
    local before, before_error = fingerprint_single(path)
    if not before or before.hash ~= expected_hash then
      return nil, before_error or "disk changed before buffer reload"
    end
    local checked, latest = pcall(deps.buffer_state, path, identity)
    if not checked or type(latest) ~= "table" then
      return nil, "buffer state changed before reload"
    end
    if not latest.loaded then
      return true
    end
    if latest.modified then
      return nil, "modified buffer was changed externally"
    end
    if type(latest.bufnr) ~= "number" or latest.bufnr ~= state.bufnr then
      return nil, "loaded buffer changed before reload"
    end
    local buffers = latest.bufnrs or { latest.bufnr }
    if not vim.islist(buffers) or #buffers == 0 then
      return nil, "loaded buffer list is unavailable"
    end
    for _, bufnr in ipairs(buffers) do
      local buffer_ok, current_buffers = pcall(deps.buffer_state, path, identity)
      if
        not buffer_ok
        or type(current_buffers) ~= "table"
        or current_buffers.modified
        or not current_buffers.loaded
        or not vim.deep_equal(current_buffers.bufnrs or { current_buffers.bufnr }, buffers)
        or type(bufnr) ~= "number"
      then
        return nil, "loaded buffers changed before reload"
      end
      local before_reload = fingerprint_single(path)
      if not before_reload or before_reload.hash ~= expected_hash then
        return nil, "disk changed before buffer reload"
      end
      -- Fingerprinting can yield to editor events; recheck immediately before reload.
      local still_ok, still = pcall(deps.buffer_state, path, identity)
      if not still_ok or not vim.deep_equal(still, current_buffers) or still.modified then
        return nil, "loaded buffers changed before reload"
      end
      local reloaded, reload_error = deps.reload(bufnr, expected_hash, before_reload.object)
      if not reloaded then
        return nil, reload_error or "buffer reload failed"
      end
      local after, after_error = fingerprint_single(path)
      if not after or after.hash ~= expected_hash then
        return nil, after_error or "disk changed during buffer reload"
      end
      local after_ok, after_buffers = pcall(deps.buffer_state, path, identity)
      if not after_ok or type(after_buffers) ~= "table" or after_buffers.modified then
        return nil, "loaded buffers changed during reload"
      end
    end
    return true
  end

  local function latch_scan_failure(err)
    batch_conflict_reason = "authoritative scan failed: " .. tostring(err)
    for path, meta in pairs(metadata) do
      meta.latched_conflict = true
      local current = records[path].current
      records[path] = public_record(
        path,
        meta.baseline,
        current,
        records[path].current_hash,
        meta.nvim_seen and "mixed" or records[path].writer,
        "conflicted",
        "none",
        batch_conflict_reason,
        meta.decision_base
      )
    end
  end

  local function scheduled_scan(reason)
    local scheduled = pcall(deps.schedule, function()
      if not stopped and active then
        tracker:request_scan(reason)
      end
    end)
    if not scheduled then
      latch_scan_failure("could not schedule " .. tostring(reason) .. " scan")
      notify("scan-schedule-failure")
      return nil, "review tracker could not schedule a scan"
    end
    return true
  end

  local function restart_debounce()
    local closing = false
    if debounce and debounce.is_closing then
      local checked, result = pcall(debounce.is_closing, debounce)
      if not checked then
        closing = true
      else
        closing = result == true
      end
    end
    if not debounce or closing then
      latch_scan_failure("filesystem debounce timer is unavailable")
      notify("debounce-failure")
      return nil, "review tracker debounce timer is unavailable"
    end
    local stopped_ok = pcall(debounce.stop, debounce)
    local started_ok, started, start_error = pcall(debounce.start, debounce, 120, 0, function()
      scheduled_scan("filesystem")
    end)
    if not stopped_ok or not started_ok or started == nil or started == false then
      latch_scan_failure("filesystem debounce timer failed")
      notify("debounce-failure")
      return nil,
        "review tracker debounce timer failed: " .. tostring(
          start_error or not stopped_ok and "stop failed" or "start failed"
        )
    end
    return true
  end

  local function start_runtime_watchers()
    if not start_watchers then
      return true
    end
    local watcher_ok
    local debounce_ok
    local periodic_ok
    watcher_ok, watcher = pcall(deps.new_fs_event)
    debounce_ok, debounce = pcall(deps.new_timer)
    periodic_ok, periodic = pcall(deps.new_timer)
    if
      not watcher_ok
      or not debounce_ok
      or not periodic_ok
      or not watcher
      or not debounce
      or not periodic
    then
      close_runtime_sources()
      return nil, "review tracker watcher allocation failed"
    end
    local started_ok, started, start_error = pcall(
      watcher.start,
      watcher,
      identity.root,
      {},
      function(err, filename)
        if stopped then
          return
        end
        if err then
          local scheduled = pcall(deps.schedule, function()
            if active and not stopped then
              latch_scan_failure("filesystem watcher failed")
              notify("watcher-failure")
            end
          end)
          if not scheduled then
            latch_scan_failure("filesystem watcher failure could not be scheduled")
            notify("watcher-failure")
          end
          return
        end
        if type(filename) == "string" and valid_relative(filename) then
          signaled[filename] = true
        end
        signal_epoch = signal_epoch + 1
        restart_debounce()
      end
    )
    if not started_ok or started == nil or started == false then
      close_runtime_sources()
      return nil, "review tracker watcher start failed: " .. tostring(start_error)
    end
    local periodic_started_ok, periodic_started, periodic_error = pcall(
      periodic.start,
      periodic,
      2000,
      2000,
      function()
        scheduled_scan("periodic")
      end
    )
    if not periodic_started_ok or periodic_started == nil or periodic_started == false then
      close_runtime_sources()
      return nil, "review tracker periodic timer start failed: " .. tostring(periodic_error)
    end

    local id_ok, active_id = pcall(active.id, active)
    if not id_ok or type(active_id) ~= "string" then
      close_runtime_sources()
      return nil, "review tracker baseline id is unavailable"
    end
    local group_ok
    group_ok, augroup = pcall(deps.create_augroup, "NvimAIReview_" .. active_id, { clear = true })
    if not group_ok or type(augroup) ~= "number" then
      close_runtime_sources()
      return nil, "review tracker autocmd group creation failed"
    end
    local scans_ok, scans_id = pcall(deps.create_autocmd, { "FocusGained", "BufEnter" }, {
      group = augroup,
      callback = function(args)
        if not stopped and active then
          local reason = args and args.event == "FocusGained" and "focus" or "buffer-enter"
          local invoked = pcall(tracker.request_scan, tracker, reason)
          if not invoked then
            latch_scan_failure("event scan raised an exception")
            notify("event-scan-failure")
          end
        end
      end,
    })
    local writes_ok, writes_id = pcall(deps.create_autocmd, "BufWritePost", {
      group = augroup,
      callback = function(args)
        if stopped or not active or type(args) ~= "table" or type(args.buf) ~= "number" then
          return
        end
        local resolved, path = pcall(deps.path_for_buffer, args.buf, identity)
        if not resolved or not path then
          return
        end
        local invoked, recorded, record_error = pcall(tracker.record_nvim_write, tracker, args.buf)
        if not invoked or not recorded then
          latch_scan_failure(record_error or "BufWritePost tracking raised an exception")
          notify("nvim-write-failure")
        end
      end,
    })
    if
      not scans_ok
      or scans_id == nil
      or scans_id == false
      or not writes_ok
      or writes_id == nil
      or writes_id == false
    then
      close_runtime_sources()
      return nil, "review tracker autocmd creation failed"
    end

    for _, handle in ipairs({ watcher, debounce, periodic }) do
      if handle.unref and not pcall(handle.unref, handle) then
        close_runtime_sources()
        return nil, "review tracker handle unref failed"
      end
    end
    return true
  end

  function tracker:ensure_batch()
    if stopped then
      return nil, "review tracker is shut down"
    end
    if active then
      return active
    end
    resolution_phase, resolution_error = nil, nil
    relaunch_complete, baseline_removed = false, false
    local created
    local create_error
    local created_here = supplied_baseline == nil
    if supplied_baseline then
      created = supplied_baseline
    else
      local invoked
      invoked, created, create_error = pcall(deps.baseline_module.create, identity, store)
      if not invoked then
        created = nil
        create_error = "baseline creation raised an exception"
      end
    end
    if not created then
      return nil, create_error
    end

    local function initialization_failure(message)
      close_runtime_sources()
      local cleanup_error
      if created_here then
        local invoked, removed, remove_error = pcall(created.remove, created)
        if not invoked or not removed then
          cleanup_error = remove_error or "baseline cleanup raised an exception"
        end
      end
      active = nil
      manifest = nil
      records = {}
      metadata = {}
      signaled = {}
      if cleanup_error then
        return nil, message .. "; new baseline cleanup failed: " .. tostring(cleanup_error)
      end
      return nil, message
    end

    active = created
    local manifest_ok
    manifest_ok, manifest = pcall(active.manifest, active)
    if not manifest_ok or type(manifest) ~= "table" then
      return initialization_failure("review baseline manifest is unavailable")
    end
    local decode_ok, initialized, initialize_error = pcall(decode_manifest)
    if not decode_ok or not initialized then
      return initialization_failure(
        initialize_error or "review baseline manifest initialization raised an exception"
      )
    end
    local phase_ok, phase_error = read_resolution_phase()
    if not phase_ok then
      return initialization_failure(phase_error)
    end
    if resolution_phase == "cleanup" then
      supplied_baseline = nil
      return active
    end
    if type(store.read_review_decisions) == "function" then
      local read_ok, decisions = pcall(store.read_review_decisions, store, active:id())
      if not read_ok or type(decisions) ~= "table" then
        return initialization_failure("private review decisions are unavailable")
      end
      local seen = {}
      for _, decision in ipairs(decisions) do
        local path = type(decision) == "table"
            and baseline_module._internal.decode_hex(decision.path_hex)
          or nil
        if
          not path
          or not valid_relative(path)
          or seen[path]
          or decision.schema ~= 1
          or decision.baseline_hash ~= manifest.baseline_hash
          or not valid_scan_object(decision.current)
          or ((decision.manual or decision.observation) and decision.decision_base ~= nil)
          or (not decision.manual and not decision.observation and not valid_scan_object(
            decision.decision_base
          ))
          or (decision.manual ~= nil and decision.manual ~= true)
          or (decision.observation ~= nil and decision.observation ~= true)
          or (decision.manual and decision.observation)
          or type(decision.external_seen) ~= "boolean"
          or type(decision.nvim_seen) ~= "boolean"
          or (decision.last_nvim_hash ~= nil and (type(decision.last_nvim_hash) ~= "string" or #decision.last_nvim_hash ~= 64 or not decision.last_nvim_hash:match(
            "^[0-9a-f]+$"
          )))
          or not ({ none = true, nvim = true, external = true, mixed = true })[decision.writer]
          or hash_object(decision.current) ~= decision.current_hash
          or not ({
            unresolved = true,
            accepted = true,
            rejected = true,
            conflicted = true,
            unchanged = decision.observation,
            ignored = decision.observation,
            unsupported = decision.observation,
          })[decision.state]
          or type(decision.unresolved_hunks) ~= "number"
          or decision.unresolved_hunks < 0
          or decision.unresolved_hunks % 1 ~= 0
        then
          return initialization_failure("private review decision is invalid")
        end
        for key in pairs(decision) do
          if
            not ({
              schema = true,
              path_hex = true,
              baseline_hash = true,
              current_hash = true,
              current = true,
              decision_base = true,
              state = true,
              unresolved_hunks = true,
              manual = true,
              writer = true,
              observation = true,
              external_seen = true,
              nvim_seen = true,
              last_nvim_hash = true,
            })[key]
          then
            return initialization_failure("private review decision contains an unknown field")
          end
        end
        seen[path] = true
        local meta = metadata[path] or ensure_record(path, absent_object(), false, false)
        local bytes
        if
          decision.decision_base
          and (decision.decision_base.kind == "regular" or decision.decision_base.kind == "symlink")
        then
          local loaded, value =
            pcall(store.read_review_object, store, active:id(), decision.decision_base.sha256)
          if
            not loaded
            or type(value) ~= "string"
            or #value ~= decision.decision_base.size
            or vim.fn.sha256(value) ~= decision.decision_base.sha256
          then
            return initialization_failure("private decision object is unavailable")
          end
          bytes = value
        end
        meta.decision_base, meta.decision_bytes = clone(decision.decision_base), bytes
        meta.decision_hash, meta.last_hash, meta.current_hash =
          decision.current_hash, decision.current_hash, decision.current_hash
        if decision.observation then
          meta.decision_hash = nil
        end
        if
          (
            decision.state == "unresolved"
            and not decision.observation
            and (
              decision.manual
              or decision.unresolved_hunks < 1
              or decision.current.kind ~= "regular"
              or decision.decision_base.kind ~= "regular"
              or decision.current.mode ~= decision.decision_base.mode
              or not reducer.is_text(bytes)
            )
          )
          or (decision.state ~= "unresolved" and decision.unresolved_hunks ~= 0)
          or (decision.observation and (decision.unresolved_hunks ~= 0 or decision.state == "accepted" or decision.state == "rejected"))
          or (decision.manual and decision.state ~= "accepted" and decision.state ~= "conflicted")
          or (decision.state == "rejected" and decision.current_hash ~= meta.baseline_hash)
        then
          return initialization_failure("private review decision state is inconsistent")
        end
        meta.external_seen = decision.external_seen
        meta.nvim_seen, meta.last_nvim_hash = decision.nvim_seen, decision.last_nvim_hash
        meta.manual = decision.manual
        meta.latched_conflict = decision.state == "conflicted"
        meta.saved_decision = clone(decision)
        records[path] = public_record(
          path,
          meta.baseline,
          decision.current,
          decision.current_hash,
          decision.writer,
          decision.state,
          decision.state == "unresolved" and not decision.observation and "hunks" or "none",
          decision.manual and "manually resolved" or nil,
          decision.decision_base
        )
        records[path].unresolved_hunks = decision.unresolved_hunks
      end
    end
    local watching, watcher_error = start_runtime_watchers()
    if not watching then
      return initialization_failure(watcher_error)
    end
    supplied_baseline = nil
    return active
  end

  local function scan_once(reason)
    local started_write_epoch, started_signal_epoch = write_epoch, signal_epoch
    local function retry_stale_snapshot()
      if
        review_task.current()
        and (write_epoch ~= started_write_epoch or signal_epoch ~= started_signal_epoch)
      then
        -- Editor events may arrive during either collection or loaded-buffer
        -- fingerprinting. Keep their signals and never publish older metadata.
        rescan_requested = true
        return true
      end
      return false
    end
    if stopped then
      return nil, "review tracker is shut down"
    end
    if not active then
      return nil, "review batch is not open"
    end

    local function fail_scan(message)
      latch_scan_failure(message)
      notify("scan-failure")
      return nil, message
    end

    local id_ok, review_id = pcall(active.id, active)
    if not id_ok or type(review_id) ~= "string" then
      return fail_scan("durable baseline identity is unavailable")
    end
    local reopened_ok, reopened, reopen_error =
      pcall(deps.revalidate_baseline, identity, store, review_id)
    if not reopened_ok or not reopened then
      return fail_scan(reopen_error or "durable baseline revalidation failed")
    end
    local manifest_ok, reopened_manifest = pcall(reopened.manifest, reopened)
    if
      not manifest_ok
      or type(reopened_manifest) ~= "table"
      or not vim.deep_equal(reopened_manifest, manifest)
    then
      return fail_scan("durable baseline changed during review")
    end
    active = reopened

    local requested, request_error = scanner_requested_paths()
    if not requested then
      return fail_scan(request_error)
    end
    local ok, scanned, scan_error = pcall(deps.scanner, identity, requested, reason)
    if retry_stale_snapshot() then
      return true
    end
    if not ok then
      scan_error = "authoritative scanner raised an exception"
      scanned = nil
    end
    if not scanned or type(scanned.paths) ~= "table" or type(scanned.ignored) ~= "table" then
      scan_error = scan_error or "authoritative scanner returned an invalid result"
      return fail_scan(scan_error)
    end
    for path, entry in pairs(scanned.paths) do
      local valid, validation_error = validate_scan_entry(path, entry)
      if not valid then
        return fail_scan(validation_error)
      end
      if scanned.ignored[path] ~= nil then
        return fail_scan("authoritative scanner returned an ambiguous path")
      end
    end
    for path, entry in pairs(scanned.ignored) do
      local valid, validation_error = validate_scan_entry(path, entry)
      if not valid then
        return fail_scan(validation_error)
      end
    end

    local names = {}
    for path in pairs(records) do
      names[path] = true
    end
    for path in pairs(scanned.paths) do
      names[path] = true
    end
    for path in pairs(scanned.ignored) do
      names[path] = true
    end
    for path in pairs(signaled) do
      if valid_relative(path) then
        names[path] = true
      end
    end
    local ordered = vim.tbl_keys(names)
    table.sort(ordered)

    for _, path in ipairs(ordered) do
      if retry_stale_snapshot() then
        return true
      end
      if not valid_relative(path) then
        return fail_scan("authoritative scanner returned an invalid path")
      end
      local visible = scanned.paths[path]
      local ignored = scanned.ignored[path]
      if visible and ignored then
        return fail_scan("authoritative scanner returned an ambiguous path")
      end
      local meta = metadata[path]
      if not meta then
        meta = ensure_record(path, absent_object(), false, false)
      end
      local current_entry = visible or ignored
      if not current_entry then
        local absent = absent_object()
        current_entry = { object = absent, hash = hash_object(absent), binary = false }
      end
      local fingerprint_ok, computed_hash = pcall(hash_object, current_entry.object)
      if
        type(current_entry.object) ~= "table"
        or type(current_entry.hash) ~= "string"
        or #current_entry.hash ~= 64
        or not fingerprint_ok
        or computed_hash ~= current_entry.hash
      then
        meta.latched_conflict = true
        apply_state(
          path,
          unsupported_object(),
          hash_object(unsupported_object()),
          false,
          false,
          "invalid scan record"
        )
      else
        local previous_hash = meta.last_hash
        local changed = apply_state(
          path,
          strip_storage(current_entry.object),
          current_entry.hash,
          current_entry.binary,
          ignored ~= nil,
          current_entry.reason
        )
        if
          changed
          and ignored == nil
          and meta.external_seen
          and not (
            meta.nvim_seen
            and current_entry.hash == meta.last_nvim_hash
            and not meta.external_seen
          )
        then
          local synced, sync_error = buffer_sync(path, current_entry.hash)
          if retry_stale_snapshot() then
            return true
          end
          if not synced then
            meta.latched_conflict = true
            records[path].state = "conflicted"
            records[path].writer = meta.nvim_seen and "mixed" or "external"
            records[path].action = "none"
            records[path].reason = sync_error
          end
        end
        meta.last_hash = current_entry.hash
        if previous_hash == nil then
          meta.last_hash = current_entry.hash
        end
      end
    end
    signaled = {}
    notify(reason or "scan")
    return true
  end

  function tracker:scan(reason)
    cancel_background_scan()
    if resolution_phase == "cleanup" then
      return true
    end
    if scan_running or decision_running or view_running then
      rescan_requested = true
      return true
    end
    scan_running = true
    local invoked, result, scan_error = pcall(scan_once, reason)
    scan_running = false
    if not invoked then
      if active and not stopped then
        latch_scan_failure("authoritative scan raised an exception")
        notify("scan-failure")
      end
      rescan_requested = false
      return nil, "authoritative scan raised an exception"
    end
    if rescan_requested then
      rescan_requested = false
      if active and not stopped then
        scheduled_scan("coalesced")
      end
    end
    return result, scan_error
  end

  function tracker:request_scan(reason)
    if stopped or not active or resolution_phase == "cleanup" then
      return true
    end
    if
      background_scan
      or scan_running
      or decision_running
      or view_running
      or resolution_running
    then
      rescan_requested = true
      return true
    end
    local finished = false
    local task = review_task.run(function()
      return self:scan(reason)
    end, function(ok, err)
      finished = true
      background_scan = nil
      if not ok and not stopped and active then
        scan_running = false
        latch_scan_failure(err or "background scan raised an exception")
        notify("scan-failure")
      end
    end)
    if not finished then
      background_scan = task
    end
    return true
  end

  function tracker:record_nvim_write(bufnr)
    if resolution_phase == "cleanup" then
      return nil, "review cleanup is pending"
    end
    if stopped then
      return nil, "review tracker is shut down"
    end
    if not active then
      return nil, "review batch is not open"
    end
    local path, path_error = deps.path_for_buffer(bufnr, identity)
    if not path or not valid_relative(path) then
      return nil, path_error or "buffer path is invalid"
    end
    local current, fingerprint_error = fingerprint_single(path)
    if not current or type(current.object) ~= "table" or type(current.hash) ~= "string" then
      return nil, fingerprint_error or "post-write fingerprint is unavailable"
    end
    local fingerprint_ok, expected_hash = pcall(hash_object, current.object)
    if not fingerprint_ok or expected_hash ~= current.hash then
      return nil, "post-write fingerprint is inconsistent"
    end
    local meta = metadata[path] or ensure_record(path, absent_object(), false, false)
    write_epoch = write_epoch + 1
    meta.nvim_seen = true
    meta.last_nvim_hash = current.hash
    meta.last_hash = current.hash
    apply_state(
      path,
      strip_storage(current.object),
      current.hash,
      current.binary,
      current.ignored == true,
      nil,
      true
    )
    if meta.external_seen then
      meta.latched_conflict = true
      records[path].writer = "mixed"
      records[path].state = "conflicted"
      records[path].action = "none"
      records[path].reason = "Neovim and an external writer both changed the path"
    end
    notify("nvim-write")
    return true
  end

  function tracker:signal(path)
    signal_epoch = signal_epoch + 1
    if stopped then
      return nil, "review tracker is shut down"
    end
    if path ~= nil then
      if not valid_relative(path) then
        return nil, "filesystem signal path is invalid"
      end
      signaled[path] = true
    end
    if debounce then
      return restart_debounce()
    end
    return true
  end

  function tracker:paths()
    local paths = vim.tbl_keys(records)
    table.sort(paths)
    local result = {}
    for _, path in ipairs(paths) do
      table.insert(result, clone(records[path]))
    end
    return result
  end

  function tracker:get(path)
    local value = records[path]
    return value and clone(value) or nil
  end

  decision_payload = function(path, current, decision, state, unresolved_hunks, manual)
    return {
      schema = 1,
      path_hex = baseline_module._internal.encode_hex(path),
      baseline_hash = manifest.baseline_hash,
      current_hash = current.hash,
      current = strip_storage(current.object),
      decision_base = not manual and strip_storage(decision) or nil,
      state = state,
      unresolved_hunks = unresolved_hunks,
      manual = manual and true or nil,
      writer = records[path].writer,
      external_seen = metadata[path].external_seen,
      nvim_seen = metadata[path].nvim_seen,
      last_nvim_hash = metadata[path].last_nvim_hash,
    }
  end

  local function action_conflict(path, message, persist)
    local record, meta = records[path], metadata[path]
    if record and meta then
      meta.latched_conflict = true
      record.state, record.action, record.reason = "conflicted", "none", message
      if decision_running and journal_verified and persist ~= false then
        local decision = meta.decision_base or strip_storage(meta.baseline)
        local bytes = meta.decision_bytes
        if bytes == nil then
          local ok, value = pcall(active.bytes, active, path)
          if ok then
            bytes = value
          end
        end
        local is_manual = manual_action or meta.manual
        if is_manual then
          bytes = nil
        end
        local payload = decision_payload(
          path,
          { object = record.current, hash = record.current_hash },
          decision,
          "conflicted",
          0,
          is_manual
        )
        local ok, saved = pcall(store.write_review_decision, store, active:id(), payload, bytes)
        if ok and saved then
          meta.saved_decision = clone(payload)
        else
          batch_conflict_reason = "private conflict persistence failed"
        end
      end
      notify("action-conflict")
    end
    return nil, message
  end

  local function verify_current(path, expected_hash, allow_conflict)
    if
      batch_conflict_reason
      or (decision_running and write_epoch ~= action_epoch)
      or (metadata[path].latched_conflict and not allow_conflict)
    then
      return action_conflict(path, "review writer state changed")
    end
    local checked, buffers = pcall(deps.buffer_state, path, identity)
    if not checked or type(buffers) ~= "table" or buffers.modified then
      return action_conflict(path, "review action refused a modified or unavailable buffer")
    end
    local ok, current = pcall(deps.read_current, identity, path)
    if
      not ok
      or type(current) ~= "table"
      or not valid_scan_object(current.object)
      or current.hash ~= expected_hash
      or hash_object(current.object) ~= expected_hash
    then
      return action_conflict(path, "reviewed disk hash changed")
    end
    if current.object.kind == "regular" or current.object.kind == "symlink" then
      if
        type(current.bytes) ~= "string"
        or #current.bytes ~= current.object.size
        or vim.fn.sha256(current.bytes) ~= current.object.sha256
      then
        return action_conflict(path, "reviewed object bytes do not match their hash")
      end
    end
    local visible = fingerprint_single(path)
    if not visible or visible.hash ~= expected_hash or (not allow_conflict and visible.ignored) then
      return action_conflict(path, "reviewed hash or Git visibility changed")
    end
    local final_ok, final_buffers = pcall(deps.buffer_state, path, identity)
    if
      not final_ok
      or type(final_buffers) ~= "table"
      or final_buffers.modified
      or (decision_running and write_epoch ~= action_epoch)
    then
      return action_conflict(path, "review buffers or writer changed during verification")
    end
    return current
  end

  local function verify_review(path)
    if not read_resolution_phase() or resolution_phase == "cleanup" then
      return action_conflict(path, "review resolution changed", false)
    end
    local reopened_ok, reopened = pcall(deps.revalidate_baseline, identity, store, active:id())
    if not reopened_ok or not reopened then
      return action_conflict(path, "durable baseline is unavailable")
    end
    local manifest_ok, latest = pcall(reopened.manifest, reopened)
    if not manifest_ok or not vim.deep_equal(latest, manifest) then
      return action_conflict(path, "durable baseline changed during review")
    end
    local read_ok, decisions = pcall(store.read_review_decisions, store, active:id())
    if not read_ok or type(decisions) ~= "table" then
      return action_conflict(path, "private review decisions are unavailable", false)
    end
    local found
    for _, decision in ipairs(decisions) do
      if decision.path_hex == baseline_module._internal.encode_hex(path) then
        if found then
          return action_conflict(path, "duplicate private review decision", false)
        end
        found = decision
      end
    end
    if not vim.deep_equal(found, metadata[path].saved_decision) then
      return action_conflict(path, "review decision changed in another editor", false)
    end
    active = reopened
    journal_verified = true
    return true
  end

  local function reviewed_current(path, expected_hash, hunk)
    local record = records[path]
    if stopped or not active or not record then
      return nil, "review path is unavailable"
    end
    if
      record.state ~= "unresolved"
      or record.action == "none"
      or (hunk and record.action ~= "hunks")
    then
      return nil, "review action is not advertised for this path"
    end
    if type(expected_hash) ~= "string" or expected_hash ~= record.current_hash then
      return action_conflict(path, "reviewed hash changed")
    end
    local trusted, trust_error = mutation:check()
    if not trusted then
      return action_conflict(path, trust_error)
    end
    return verify_current(path, expected_hash)
  end

  -- A read-only rendering seam: private objects and journal validation stay here.
  function tracker:view(path)
    cancel_background_scan()
    if stopped or not active or not records[path] then
      return nil, "review path is unavailable"
    end
    if
      decision_running
      or scan_running
      or view_running
      or resolution_running
      or resolution_phase == "cleanup"
    then
      return nil, "review tracker is busy"
    end
    local acquired, lease = pcall(function()
      return require("ai.review.serialization").acquire(store:state_dir())
    end)
    if not acquired or not lease then
      return nil, "review view serialization is unavailable"
    end
    view_running = true
    local epoch = write_epoch
    local invoked, result, err = pcall(function()
      if not verify_review(path) then
        return nil, records[path].reason
      end
      local record = clone(records[path])
      local current = deps.read_current(identity, path)
      if
        type(current) ~= "table"
        or not valid_scan_object(current.object)
        or current.hash ~= record.current_hash
        or hash_object(current.object) ~= record.current_hash
      then
        return nil, "reviewed disk hash changed; refresh the view"
      end
      if current.object.kind == "regular" or current.object.kind == "symlink" then
        if
          type(current.bytes) ~= "string"
          or #current.bytes ~= current.object.size
          or vim.fn.sha256(current.bytes) ~= current.object.sha256
        then
          return nil, "reviewed object bytes are unavailable"
        end
      end
      local meta = metadata[path]
      local base = meta.decision_base or meta.baseline
      local bytes = meta.decision_bytes or active:bytes(path)
      if base.kind == "absent" then
        bytes = ""
      end
      if
        bytes ~= nil
        and base.kind ~= "absent"
        and (#bytes ~= base.size or vim.fn.sha256(bytes) ~= base.sha256)
      then
        return nil, "review comparison bytes are unavailable"
      end
      if current.object.kind == "absent" then
        current.bytes = ""
      end
      local hunks = {}
      if record.state == "unresolved" and record.action == "hunks" then
        hunks = reducer.hunks(bytes, current.bytes)
        if not hunks then
          return nil, "review hunk comparison is unavailable"
        end
      end
      if stopped or write_epoch ~= epoch or not vim.deep_equal(records[path], record) then
        return nil, "review writer changed during display"
      end
      record.review_id, record.root = "review_" .. active:id(), identity.root
      record.baseline_bytes, record.current_bytes, record.hunks = bytes, current.bytes, hunks
      return record
    end)
    local released, release_result = pcall(lease.release, lease)
    view_running, journal_verified = false, false
    if rescan_requested then
      rescan_requested = false
      scheduled_scan("view-completion")
    end
    if not invoked or not released or not release_result then
      return nil, "review view verification failed"
    end
    return result, err
  end

  local function persist_decision(path, current, decision, bytes, state, unresolved_hunks, manual)
    local meta = metadata[path]
    local payload = decision_payload(path, current, decision, state, unresolved_hunks, manual)
    local ok, saved = pcall(store.write_review_decision, store, active:id(), payload, bytes)
    if not ok or not saved then
      return action_conflict(path, "private review decision publication failed")
    end
    local fresh = verify_current(path, current.hash, manual)
    if not fresh then
      return nil, records[path].reason
    end
    meta.saved_decision = clone(payload)
    meta.decision_hash, meta.decision_base, meta.decision_bytes =
      current.hash, clone(decision), bytes
    meta.current_hash, meta.last_hash = current.hash, current.hash
    meta.manual, meta.latched_conflict = manual, false
    records[path] = public_record(
      path,
      meta.baseline,
      current.object,
      current.hash,
      payload.writer,
      state,
      state == "unresolved" and "hunks" or "none",
      manual and "manually resolved" or nil,
      decision
    )
    records[path].unresolved_hunks = unresolved_hunks
    notify("decision")
    return {
      path = path,
      state = state,
      current_hash = current.hash,
      unresolved_hunks = unresolved_hunks,
    }
  end

  local function with_action(path, operation, manual)
    cancel_background_scan()
    if stopped or not active or not records[path] then
      return nil, "review path is unavailable"
    end
    if
      decision_running
      or scan_running
      or view_running
      or resolution_running
      or resolution_phase == "cleanup"
    then
      return nil, "review tracker is busy"
    end
    local acquired, lease = pcall(function()
      return require("ai.review.serialization").acquire(store:state_dir())
    end)
    if not acquired or not lease then
      return action_conflict(path, "review decision serialization is unavailable", false)
    end
    decision_running = true
    journal_verified = false
    action_epoch, manual_action = write_epoch, manual == true
    local invoked, result, err = pcall(function()
      if not verify_review(path) then
        return nil, records[path].reason
      end
      return operation()
    end)
    if not invoked then
      result, err = action_conflict(path, "review action raised an exception")
    end
    local released, release_result = pcall(lease.release, lease)
    if not released or not release_result then
      result, err = action_conflict(path, "review decision serialization release failed", false)
    end
    decision_running = false
    journal_verified = false
    manual_action = false
    if rescan_requested then
      rescan_requested = false
      scheduled_scan("decision-completion")
    end
    if result and options.finish_review and tracker:batch_status().state == "resolved" then
      tracker:finish_review()
    end
    return result, err
  end

  function tracker:accept_hunk(path, index, expected_hash)
    local current, err = reviewed_current(path, expected_hash, true)
    if not current then
      return nil, err
    end
    local meta = metadata[path]
    local base = meta.decision_bytes or active:bytes(path)
    local bytes, reduce_error = reducer.accept_hunk(base, current.bytes, index)
    if not bytes then
      return action_conflict(path, reduce_error)
    end
    local decision =
      { kind = "regular", mode = current.object.mode, size = #bytes, sha256 = vim.fn.sha256(bytes) }
    local remaining = #assert(reducer.hunks(bytes, current.bytes))
    local state = remaining > 0 and "unresolved"
      or current.hash == meta.baseline_hash and "rejected"
      or "accepted"
    return persist_decision(path, current, decision, bytes, state, remaining)
  end

  local function apply_rejection(path, current, desired, bytes)
    local mutated, mutation_error =
      mutation:apply(active:id(), path, current.object, desired, bytes)
    if not mutated then
      return action_conflict(path, mutation_error)
    end
    local changed, changed_error = verify_current(path, hash_object(mutated))
    if not changed then
      return nil, changed_error
    end
    local synced, sync_error = buffer_sync(path, changed.hash)
    if not synced then
      return action_conflict(path, sync_error)
    end
    return changed
  end

  function tracker:reject_hunk(path, index, expected_hash)
    local current, err = reviewed_current(path, expected_hash, true)
    if not current then
      return nil, err
    end
    local meta = metadata[path]
    local base = meta.decision_bytes or active:bytes(path)
    local bytes, reduce_error = reducer.reject_hunk(base, current.bytes, index)
    if not bytes then
      return action_conflict(path, reduce_error)
    end
    local desired =
      { kind = "regular", mode = current.object.mode, size = #bytes, sha256 = vim.fn.sha256(bytes) }
    local changed, changed_error = apply_rejection(path, current, desired, bytes)
    if not changed then
      return nil, changed_error
    end
    local remaining = #assert(reducer.hunks(base, changed.bytes))
    local state = remaining > 0 and "unresolved"
      or changed.hash == meta.baseline_hash and "rejected"
      or "accepted"
    local decision = meta.decision_base or strip_storage(meta.baseline)
    return persist_decision(path, changed, decision, base, state, remaining)
  end

  function tracker:accept_file(path, expected_hash)
    local current, err = reviewed_current(path, expected_hash, false)
    if not current then
      return nil, err
    end
    local state = current.hash == metadata[path].baseline_hash and "rejected" or "accepted"
    return persist_decision(path, current, strip_storage(current.object), current.bytes, state, 0)
  end

  function tracker:reject_file(path, expected_hash)
    local current, err = reviewed_current(path, expected_hash, false)
    if not current then
      return nil, err
    end
    local desired = strip_storage(metadata[path].baseline)
    local bytes, read_error = active:bytes(path)
    if desired.kind ~= "absent" and type(bytes) ~= "string" then
      return action_conflict(path, read_error or "baseline bytes are unavailable")
    end
    local changed, changed_error = apply_rejection(path, current, desired, bytes)
    if not changed then
      return nil, changed_error
    end
    return persist_decision(path, changed, desired, bytes, "rejected", 0)
  end

  for _, name in ipairs({ "accept_hunk", "reject_hunk", "accept_file", "reject_file" }) do
    local operation = tracker[name]
    tracker[name] = function(self, path, ...)
      local args = { n = select("#", ...), ... }
      return with_action(path, function()
        return operation(self, path, unpack(args, 1, args.n))
      end)
    end
  end

  function tracker:resolve(path, resolution, expected_hash)
    if stopped then
      return nil, "review tracker is shut down"
    end
    local record = records[path]
    local meta = metadata[path]
    if not record or not meta then
      return nil, "review path is unavailable"
    end
    if batch_conflict_reason then
      return nil, "review batch is latched conflicted"
    end
    if resolution ~= "manual" or type(expected_hash) ~= "string" then
      return nil, "review path is not safely resolvable without an exact-hash manual resolution"
    end
    return with_action(path, function()
      if record.current_hash ~= expected_hash then
        return action_conflict(path, "reviewed hash changed")
      end
      local current, err = verify_current(path, expected_hash, true)
      if not current then
        return nil, err
      end
      return persist_decision(path, current, nil, nil, "accepted", 0, true)
    end, true)
  end

  function tracker:batch_status()
    if active and resolution_phase == "cleanup" then
      return {
        review_id = "review_" .. active:id(),
        state = "resolved",
        observed_delta = true,
        cleanup_pending = true,
        reason = resolution_error,
      }
    end
    local observed, unresolved = false, batch_conflict_reason ~= nil
    for path, meta in pairs(metadata) do
      local state = records[path].state
      observed = observed or meta.external_seen
      unresolved = unresolved
        or state == "conflicted"
        or state == "unresolved"
        or (meta.external_seen and state ~= "accepted" and state ~= "rejected")
    end
    return {
      review_id = active and "review_" .. active:id() or nil,
      state = not active and "closed" or observed and not unresolved and "resolved" or "open",
      observed_delta = observed,
      reason = resolution_error or batch_conflict_reason,
    }
  end

  local function serialized_resolution(operation)
    local ok, lease = pcall(function()
      return require("ai.review.serialization").acquire(store:state_dir())
    end)
    if not ok or not lease then
      return nil, "review resolution serialization is unavailable"
    end
    local called, saved, err = pcall(operation)
    local released, result = pcall(lease.release, lease)
    if not called or not saved or not released or not result then
      return nil, called and err or "private review resolution operation failed"
    end
    return true
  end

  local function publish_resolution_phase(phase)
    local saved, err = serialized_resolution(function()
      return store:write_review_phase(active:id(), manifest.baseline_hash, phase)
    end)
    if not saved then
      return nil, err or "private review resolution phase publication failed"
    end
    resolution_phase = phase
    return true
  end

  function tracker:finish_review(review_id)
    cancel_background_scan()
    if stopped or decision_running or scan_running or view_running or resolution_running then
      return nil, "review tracker is busy or shut down"
    end
    if not active and review_id == nil then
      return nil, "review batch is not open"
    end
    if
      review_id ~= nil
      and (
        type(review_id) ~= "string"
        or #review_id ~= 32
        or not review_id:match("^[0-9a-f]+$")
        or (active and review_id ~= active:id())
      )
    then
      return nil, "review cleanup identity is invalid"
    end
    resolution_running = true
    local invoked, finished, finish_error = pcall(function()
      if not active then
        return serialized_resolution(function()
          return store:cleanup_removed_review(review_id)
        end)
      end
      if not read_resolution_phase() then
        return nil, "private review resolution phase is unavailable"
      end
      if resolution_phase == "cleanup" then
        return self:abandon()
      end
      if not self:scan("resolution-check") or self:batch_status().state ~= "resolved" then
        return nil, "review batch still requires explicit decisions"
      end
      if not relaunch_complete then
        if type(options.finish_review) ~= "function" then
          return nil, "read-only review coordinator is unavailable"
        end
        local called, result = pcall(options.finish_review, active:id())
        if not called or not result then
          return nil, "read-only relaunch failed; retry review resolution explicitly"
        end
        if not active then
          return true
        end -- The coordinator can finish an already-closed batch itself.
        relaunch_complete = true
      end
      if resolution_phase ~= "read-only" then
        local saved, err = publish_resolution_phase("read-only")
        if not saved then
          return nil, err
        end
      end
      if not self:scan("post-relaunch") or self:batch_status().state ~= "resolved" then
        return nil, "review changed during read-only relaunch; baseline retained"
      end
      local saved, err = publish_resolution_phase("cleanup")
      if not saved then
        return nil, err
      end
      return self:abandon()
    end)
    resolution_running = false
    if not invoked or not finished then
      resolution_error = invoked and finish_error or "review resolution raised an exception"
      notify("resolution-pending")
      return nil, resolution_error
    end
    resolution_error = nil
    return true
  end

  -- Confirmed abandonment can forget an unverifiable batch without deleting its
  -- unknown private remnants. The command owner must stop writable execution first.
  function tracker:abandon(abandon_options)
    cancel_background_scan()
    if stopped then
      return nil, "review tracker is shut down"
    end
    if not active then
      supplied_baseline = nil
      return true
    end
    if decision_running or scan_running or view_running then
      return nil, "review tracker is busy"
    end
    local preserve_storage = type(abandon_options) == "table"
      and abandon_options.preserve_storage == true
    if not preserve_storage and type(store.cleanup_review_decisions) == "function" then
      local cleaned, cleanup_error =
        store:cleanup_review_decisions(active:id(), resolution_phase == "cleanup")
      if not cleaned then
        return nil, cleanup_error
      end
    end
    if not preserve_storage and not baseline_removed then
      local removed, remove_error = active:remove()
      if not removed then
        return nil, remove_error
      end
      baseline_removed = true
    end
    if not preserve_storage and resolution_phase == "cleanup" then
      local cleaned, err = store:cleanup_review_decisions(active:id())
      if not cleaned then
        return nil, err
      end
    end
    active, supplied_baseline = nil, nil
    manifest = nil
    records = {}
    metadata = {}
    signaled = {}
    batch_conflict_reason = nil
    resolution_phase, resolution_error = nil, nil
    relaunch_complete, baseline_removed = false, false
    local closed = close_runtime_sources()
    notify("abandon")
    if not closed then
      return nil, "review tracker resources could not all be closed"
    end
    return true
  end

  function tracker:subscribe(callback)
    if stopped then
      return nil, "review tracker is shut down"
    end
    if type(callback) ~= "function" then
      return nil, "review tracker subscriber is invalid"
    end
    table.insert(subscribers, callback)
    local subscribed = true
    return function()
      if not subscribed then
        return true
      end
      subscribed = false
      for index, candidate in ipairs(subscribers) do
        if candidate == callback then
          table.remove(subscribers, index)
          break
        end
      end
      return true
    end
  end

  function tracker:shutdown()
    cancel_background_scan()
    if shutdown_result ~= nil then
      return shutdown_result
    end
    stopped = true
    local ok = close_runtime_sources()
    subscribers = {}
    shutdown_result = ok
    return shutdown_result
  end

  return tracker
end

function M.new(options)
  return new(options)
end

M._test = {
  new = new,
  classify_writer = classify_writer,
}

return M
