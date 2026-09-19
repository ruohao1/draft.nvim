local bit = require("bit")

local M = {}

local DIRECTORY_MODE = 448
local PERMISSION_BITS = 511
local LOCK_NAME = ".baseline-serialization"
local MALFORMED_STATE_ROOT = "baseline serialization unavailable: malformed state root"
local MALFORMED_LOCK = "baseline serialization unavailable: malformed lock"
local EXISTING_LOCK = "baseline serialization unavailable: lock exists (active or stale)"

local default_dependencies = {
  lstat = vim.uv.fs_lstat,
  realpath = vim.uv.fs_realpath,
  open = vim.uv.fs_open,
  fstat = vim.uv.fs_fstat,
  mkdir = vim.uv.fs_mkdir,
  scandir = vim.uv.fs_scandir,
  scandir_next = vim.uv.fs_scandir_next,
  fsync = vim.uv.fs_fsync,
  close = vim.uv.fs_close,
  rmdir = vim.uv.fs_rmdir,
  uid = vim.uv.getuid,
}

local function dependencies(overrides)
  overrides = overrides or {}
  return {
    lstat = overrides.lstat or default_dependencies.lstat,
    realpath = overrides.realpath or default_dependencies.realpath,
    open = overrides.open or default_dependencies.open,
    fstat = overrides.fstat or default_dependencies.fstat,
    mkdir = overrides.mkdir or default_dependencies.mkdir,
    scandir = overrides.scandir or default_dependencies.scandir,
    scandir_next = overrides.scandir_next or default_dependencies.scandir_next,
    fsync = overrides.fsync or default_dependencies.fsync,
    close = overrides.close or default_dependencies.close,
    rmdir = overrides.rmdir or default_dependencies.rmdir,
    uid = overrides.uid or default_dependencies.uid,
  }
end

local function error_code(err, code)
  local candidate = code
  if type(candidate) ~= "string" then
    candidate = type(err) == "string" and err:match("%f[%w](E[A-Z0-9_]+)%f[%W]") or nil
  end
  if type(candidate) ~= "string" or #candidate > 24 or not candidate:match("^E[A-Z0-9_]+$") then
    return "UNKNOWN"
  end
  return candidate
end

local function operation_error(phase, operation, err, code)
  return string.format(
    "baseline serialization %s failed: %s (%s)",
    phase,
    operation,
    error_code(err, code)
  )
end

local function semantic_error(phase, operation)
  return operation_error(phase, operation, nil, "UNKNOWN")
end

local function append_error(errors, err)
  if err then
    table.insert(errors, err)
  end
end

local function combined_error(primary, cleanup_errors)
  local errors = { primary }
  vim.list_extend(errors, cleanup_errors)
  return table.concat(errors, "; ")
end

local function private_directory(stat, uid)
  return stat
    and stat.type == "directory"
    and type(stat.dev) == "number"
    and type(stat.ino) == "number"
    and stat.uid == uid
    and type(stat.mode) == "number"
    and bit.band(stat.mode, PERMISSION_BITS) == DIRECTORY_MODE
end

local function same_directory(left, right)
  return left
    and right
    and left.dev == right.dev
    and left.ino == right.ino
    and left.type == right.type
    and left.uid == right.uid
    and left.mode == right.mode
end

local function absolute_normalized(path)
  return type(path) == "string"
    and #path > 0
    and path:sub(1, 1) == "/"
    and path:find("[%z\1-\31\127]") == nil
    and vim.fs.normalize(path) == path
end

local function close_for_cleanup(fd, deps, operation)
  local closed, close_error, close_code = deps.close(fd)
  if not closed then
    return operation_error("cleanup", operation, close_error, close_code)
  end
end

local function fail_with_state_fd(primary, state_fd, deps)
  local cleanup_errors = {}
  append_error(cleanup_errors, close_for_cleanup(state_fd, deps, "close-state-root"))
  return nil, combined_error(primary, cleanup_errors)
end

local function fail_with_lock_fd(primary, lock_fd, state_fd, deps)
  local cleanup_errors = {}
  append_error(cleanup_errors, close_for_cleanup(lock_fd, deps, "close-lock"))
  append_error(cleanup_errors, close_for_cleanup(state_fd, deps, "close-state-root"))
  return nil, combined_error(primary, cleanup_errors)
end

local function fail_open_state_root(primary, state_fd, deps)
  local _, failure = fail_with_state_fd(primary, state_fd, deps)
  return nil, nil, nil, failure
end

local function fail_open_lock(primary, lock_fd, state_fd, deps)
  local _, failure
  if lock_fd then
    _, failure = fail_with_lock_fd(primary, lock_fd, state_fd, deps)
  else
    _, failure = fail_with_state_fd(primary, state_fd, deps)
  end
  return nil, nil, failure
end

local function open_state_root(state_root, deps)
  if not absolute_normalized(state_root) then
    return nil, nil, nil, MALFORMED_STATE_ROOT
  end

  local uid = deps.uid()
  if type(uid) ~= "number" then
    return nil, nil, nil, MALFORMED_STATE_ROOT
  end

  local before, before_error, before_code = deps.lstat(state_root)
  if not before then
    return nil,
      nil,
      nil,
      operation_error("acquisition", "lstat-state-root", before_error, before_code)
  end
  if not private_directory(before, uid) then
    return nil, nil, nil, MALFORMED_STATE_ROOT
  end

  local physical, physical_error, physical_code = deps.realpath(state_root)
  if not physical then
    return nil,
      nil,
      nil,
      operation_error("acquisition", "validate-state-root", physical_error, physical_code)
  end
  if physical ~= state_root then
    return nil, nil, nil, MALFORMED_STATE_ROOT
  end

  local state_fd, open_error, open_code = deps.open(state_root, "r", 0)
  if not state_fd then
    return nil, nil, nil, operation_error("acquisition", "open-state-root", open_error, open_code)
  end

  local opened, opened_error, opened_code = deps.fstat(state_fd)
  if not opened then
    return fail_open_state_root(
      operation_error("acquisition", "validate-state-root", opened_error, opened_code),
      state_fd,
      deps
    )
  end

  local after, after_error, after_code = deps.lstat(state_root)
  if not after then
    return fail_open_state_root(
      operation_error("acquisition", "lstat-state-root", after_error, after_code),
      state_fd,
      deps
    )
  end

  if
    not private_directory(opened, uid)
    or not private_directory(after, uid)
    or not same_directory(before, opened)
    or not same_directory(opened, after)
  then
    return fail_open_state_root(MALFORMED_STATE_ROOT, state_fd, deps)
  end

  return state_fd, opened, uid
end

local function open_lock(lock_path, state_identity, uid, state_fd, deps)
  local before, before_error, before_code = deps.lstat(lock_path)
  if not before then
    return fail_open_lock(
      operation_error("acquisition", "lstat-lock", before_error, before_code),
      nil,
      state_fd,
      deps
    )
  end
  if not private_directory(before, uid) or before.dev ~= state_identity.dev then
    return fail_open_lock(MALFORMED_LOCK, nil, state_fd, deps)
  end

  local physical, physical_error, physical_code = deps.realpath(lock_path)
  if not physical then
    return fail_open_lock(
      operation_error("acquisition", "validate-lock", physical_error, physical_code),
      nil,
      state_fd,
      deps
    )
  end
  if physical ~= lock_path then
    return fail_open_lock(MALFORMED_LOCK, nil, state_fd, deps)
  end

  local lock_fd, open_error, open_code = deps.open(lock_path, "r", 0)
  if not lock_fd then
    return fail_open_lock(
      operation_error("acquisition", "open-lock", open_error, open_code),
      nil,
      state_fd,
      deps
    )
  end

  local opened, opened_error, opened_code = deps.fstat(lock_fd)
  if not opened then
    return fail_open_lock(
      operation_error("acquisition", "validate-lock", opened_error, opened_code),
      lock_fd,
      state_fd,
      deps
    )
  end

  local scanner, scan_error, scan_code = deps.scandir(lock_path)
  if not scanner then
    return fail_open_lock(
      operation_error("acquisition", "scan-lock", scan_error, scan_code),
      lock_fd,
      state_fd,
      deps
    )
  end
  local name, scan_error, scan_code = deps.scandir_next(scanner)
  if not name and (scan_error ~= nil or scan_code ~= nil) then
    return fail_open_lock(
      operation_error("acquisition", "scan-lock", nil, scan_code),
      lock_fd,
      state_fd,
      deps
    )
  end
  if name ~= nil then
    return fail_open_lock(MALFORMED_LOCK, lock_fd, state_fd, deps)
  end

  local after, after_error, after_code = deps.lstat(lock_path)
  if not after then
    return fail_open_lock(
      operation_error("acquisition", "lstat-lock", after_error, after_code),
      lock_fd,
      state_fd,
      deps
    )
  end

  if
    not private_directory(opened, uid)
    or not private_directory(after, uid)
    or opened.dev ~= state_identity.dev
    or after.dev ~= state_identity.dev
    or not same_directory(before, opened)
    or not same_directory(opened, after)
  then
    return fail_open_lock(MALFORMED_LOCK, lock_fd, state_fd, deps)
  end

  return lock_fd, opened
end

local function inspect_created_lock(context, deps)
  local before, before_error, before_code = deps.lstat(context.lock_path)
  if not before then
    return nil, nil, operation_error("acquisition", "lstat-lock", before_error, before_code)
  end
  if not private_directory(before, context.uid) or before.dev ~= context.state_identity.dev then
    return nil, nil, MALFORMED_LOCK
  end
  context.created_identity = before

  local physical, physical_error, physical_code = deps.realpath(context.lock_path)
  if not physical then
    return nil, nil, operation_error("acquisition", "validate-lock", physical_error, physical_code)
  end
  if physical ~= context.lock_path then
    return nil, nil, MALFORMED_LOCK
  end

  local lock_fd, open_error, open_code = deps.open(context.lock_path, "r", 0)
  if not lock_fd then
    return nil, nil, operation_error("acquisition", "open-lock", open_error, open_code)
  end
  context.lock_fd = lock_fd

  local opened, opened_error, opened_code = deps.fstat(lock_fd)
  if not opened then
    return nil, nil, operation_error("acquisition", "validate-lock", opened_error, opened_code)
  end

  local scanner, scan_error, scan_code = deps.scandir(context.lock_path)
  if not scanner then
    return nil, nil, operation_error("acquisition", "scan-lock", scan_error, scan_code)
  end
  local name, scan_error, scan_code = deps.scandir_next(scanner)
  if not name and (scan_error ~= nil or scan_code ~= nil) then
    return nil, nil, operation_error("acquisition", "scan-lock", nil, scan_code)
  end
  if name ~= nil then
    return nil, nil, MALFORMED_LOCK
  end

  local after, after_error, after_code = deps.lstat(context.lock_path)
  if not after then
    return nil, nil, operation_error("acquisition", "lstat-lock", after_error, after_code)
  end

  if
    not private_directory(opened, context.uid)
    or not private_directory(after, context.uid)
    or opened.dev ~= context.state_identity.dev
    or after.dev ~= context.state_identity.dev
    or not same_directory(before, opened)
    or not same_directory(opened, after)
  then
    return nil, nil, MALFORMED_LOCK
  end

  return lock_fd, opened
end

local function absent(path, deps)
  local stat, stat_error, stat_code = deps.lstat(path)
  if stat then
    return nil, semantic_error("release", "verify-lock-absent")
  end
  if error_code(stat_error, stat_code) ~= "ENOENT" then
    return nil, operation_error("release", "verify-lock-absent", stat_error, stat_code)
  end
  return true
end

local function cleanup_absent(path, deps)
  local stat, stat_error, stat_code = deps.lstat(path)
  if stat then
    return nil, semantic_error("cleanup", "verify-lock-absent")
  end
  if error_code(stat_error, stat_code) ~= "ENOENT" then
    return nil, operation_error("cleanup", "verify-lock-absent", stat_error, stat_code)
  end
  return true
end

local function cleanup_created_lock(primary, context, deps)
  local cleanup_errors = {}

  if context.lock_fd then
    local lock_fd = context.lock_fd
    context.lock_fd = nil
    append_error(cleanup_errors, close_for_cleanup(lock_fd, deps, "close-lock"))
  end

  if context.created_identity then
    local path_identity, path_error, path_code = deps.lstat(context.lock_path)
    local removable = true

    if not path_identity then
      append_error(cleanup_errors, operation_error("cleanup", "lstat-lock", path_error, path_code))
      removable = false
    elseif
      not private_directory(path_identity, context.uid)
      or path_identity.dev ~= context.state_identity.dev
      or not same_directory(path_identity, context.created_identity)
    then
      append_error(cleanup_errors, semantic_error("cleanup", "validate-lock"))
      removable = false
    end

    if removable then
      local removed, remove_error, remove_code = deps.rmdir(context.lock_path)
      if not removed then
        append_error(
          cleanup_errors,
          operation_error("cleanup", "rmdir-lock", remove_error, remove_code)
        )
      else
        local _, missing_error = cleanup_absent(context.lock_path, deps)
        append_error(cleanup_errors, missing_error)

        local synced, sync_error, sync_code = deps.fsync(context.state_fd)
        if not synced then
          append_error(
            cleanup_errors,
            operation_error("cleanup", "fsync-state-root", sync_error, sync_code)
          )
        end
      end
    end
  end

  local state_fd = context.state_fd
  context.state_fd = nil
  append_error(cleanup_errors, close_for_cleanup(state_fd, deps, "close-state-root"))
  return nil, combined_error(primary, cleanup_errors)
end

local function revalidate_state_root(context, deps)
  local current, current_error, current_code = deps.lstat(context.state_root)
  if not current then
    return nil, operation_error("acquisition", "lstat-state-root", current_error, current_code)
  end
  if
    not private_directory(current, context.uid)
    or not same_directory(current, context.state_identity)
  then
    return nil, semantic_error("acquisition", "validate-state-root")
  end
  return true
end

local function new_lease(lock_path, lock_identity, lock_fd, state_fd, state_identity, uid, deps)
  local lease = {}
  local consumed = false
  local cached_value
  local cached_error

  function lease:release()
    if consumed then
      return cached_value, cached_error
    end
    consumed = true

    local errors = {}
    local opened_state, opened_state_error, opened_state_code = deps.fstat(state_fd)
    local path_identity, path_error, path_code = deps.lstat(lock_path)
    local opened_identity, opened_error, opened_code = deps.fstat(lock_fd)
    local physical, physical_error, physical_code = deps.realpath(lock_path)
    local final_identity, final_error, final_code = deps.lstat(lock_path)
    local removable = true

    if not opened_state then
      append_error(
        errors,
        operation_error("release", "validate-state-root", opened_state_error, opened_state_code)
      )
      removable = false
    elseif
      not private_directory(opened_state, uid)
      or not same_directory(opened_state, state_identity)
    then
      append_error(errors, semantic_error("release", "validate-state-root"))
      removable = false
    end

    if not path_identity then
      append_error(errors, operation_error("release", "lstat-lock", path_error, path_code))
      removable = false
    end
    if not opened_identity then
      append_error(errors, operation_error("release", "validate-lock", opened_error, opened_code))
      removable = false
    end
    if not physical then
      append_error(
        errors,
        operation_error("release", "validate-lock", physical_error, physical_code)
      )
      removable = false
    end
    if not final_identity then
      append_error(errors, operation_error("release", "lstat-lock", final_error, final_code))
      removable = false
    end
    if
      (path_identity and not private_directory(path_identity, uid))
      or (opened_identity and not private_directory(opened_identity, uid))
      or (final_identity and not private_directory(final_identity, uid))
      or (path_identity and not same_directory(path_identity, lock_identity))
      or (opened_identity and not same_directory(opened_identity, lock_identity))
      or (final_identity and not same_directory(final_identity, lock_identity))
      or (physical and physical ~= lock_path)
    then
      append_error(errors, semantic_error("release", "validate-lock"))
      removable = false
    end

    local lock_closed, lock_close_error, lock_close_code = deps.close(lock_fd)
    if not lock_closed then
      append_error(
        errors,
        operation_error("release", "close-lock", lock_close_error, lock_close_code)
      )
    end

    local removed = false
    if removable then
      local remove_error
      local remove_code
      removed, remove_error, remove_code = deps.rmdir(lock_path)
      if not removed then
        append_error(errors, operation_error("release", "rmdir-lock", remove_error, remove_code))
      end
    end

    if removed then
      local missing, missing_error = absent(lock_path, deps)
      append_error(errors, missing_error)
    end

    local synced, sync_error, sync_code = deps.fsync(state_fd)
    if not synced then
      append_error(errors, operation_error("release", "fsync-state-root", sync_error, sync_code))
    end

    local state_closed, state_close_error, state_close_code = deps.close(state_fd)
    if not state_closed then
      append_error(
        errors,
        operation_error("release", "close-state-root", state_close_error, state_close_code)
      )
    end

    if #errors > 0 then
      cached_value = nil
      cached_error = table.concat(errors, "; ")
    else
      cached_value = true
      cached_error = nil
    end
    return cached_value, cached_error
  end

  return lease
end

local function acquire(state_root, deps)
  local state_fd, state_identity, uid, state_error = open_state_root(state_root, deps)
  if not state_fd then
    return nil, state_error
  end

  local lock_path = vim.fs.joinpath(state_root, LOCK_NAME)
  local created, create_error, create_code = deps.mkdir(lock_path, DIRECTORY_MODE)
  if not created then
    if error_code(create_error, create_code) == "EEXIST" then
      local lock_fd, _, lock_error = open_lock(lock_path, state_identity, uid, state_fd, deps)
      if not lock_fd then
        return nil, lock_error
      end
      return fail_with_lock_fd(EXISTING_LOCK, lock_fd, state_fd, deps)
    end
    return fail_with_state_fd(
      operation_error("acquisition", "mkdir-lock", create_error, create_code),
      state_fd,
      deps
    )
  end

  local context = {
    state_root = state_root,
    state_fd = state_fd,
    state_identity = state_identity,
    uid = uid,
    lock_path = lock_path,
    created_identity = nil,
    lock_fd = nil,
  }

  local lock_fd, lock_identity, lock_error = inspect_created_lock(context, deps)
  if not lock_fd then
    return cleanup_created_lock(lock_error, context, deps)
  end

  local state_valid, state_validation_error = revalidate_state_root(context, deps)
  if not state_valid then
    return cleanup_created_lock(state_validation_error, context, deps)
  end

  local synced, sync_error, sync_code = deps.fsync(state_fd)
  if not synced then
    return cleanup_created_lock(
      operation_error("acquisition", "fsync-state-root", sync_error, sync_code),
      context,
      deps
    )
  end

  return new_lease(lock_path, lock_identity, lock_fd, state_fd, state_identity, uid, deps)
end

local runtime_dependencies = dependencies()

function M.acquire(state_root, dependency_overrides)
  local deps = dependency_overrides and dependencies(dependency_overrides) or runtime_dependencies
  return acquire(state_root, deps)
end

return M
