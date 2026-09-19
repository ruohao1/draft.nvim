local bit = require("bit")
local trusted_tools = require("ai.tools")
local serialization_module = require("ai.review.serialization")
local reducer = require("ai.review.reducer")
local review_task = require("ai.review.task")

local M = {}

local DIRECTORY_MODE = 448
local FILE_MODE = 384
local PERMISSION_BITS = 511
local EXECUTE_BITS = 73
local MAX_MANIFEST_BYTES = 8 * 1024 * 1024
local MAX_FILE_BYTES = 64 * 1024 * 1024
local SCHEMA = 1

local function clone(value)
  return vim.deepcopy(value)
end

local function path_within(root, path)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function same_stat(left, right)
  if not left or not right then
    return false
  end
  for _, field in ipairs({
    "dev",
    "ino",
    "mode",
    "nlink",
    "size",
    "type",
    "uid",
    "gid",
    "mtime",
    "ctime",
  }) do
    if not vim.deep_equal(left[field], right[field]) then
      return false
    end
  end
  return true
end

local function same_identity(left, right)
  if not left or not right then
    return false
  end
  for _, field in ipairs({ "dev", "ino", "type", "uid", "gid", "mode" }) do
    if not vim.deep_equal(left[field], right[field]) then
      return false
    end
  end
  return true
end

local function same_leaf_identity(left, right)
  if not left or not right then
    return false
  end
  for _, field in ipairs({ "dev", "ino", "type", "uid", "gid", "mode", "nlink", "size", "mtime" }) do
    if not vim.deep_equal(left[field], right[field]) then
      return false
    end
  end
  return true
end

local function valid_oid(value)
  return type(value) == "string"
    and (value:match("^[0-9a-f]+$") ~= nil)
    and (#value == 40 or #value == 64)
end

local function encode_hex(value)
  return (value:gsub(".", function(byte)
    return string.format("%02x", string.byte(byte))
  end))
end

local function decode_hex(value)
  if type(value) ~= "string" or #value % 2 ~= 0 or value:find("[^0-9a-f]") then
    return nil
  end
  return (value:gsub("..", function(pair)
    return string.char(tonumber(pair, 16))
  end))
end

local function json_string(value)
  local result = { '"' }
  for index = 1, #value do
    local byte = value:byte(index)
    if byte == 34 then
      table.insert(result, '\\"')
    elseif byte == 92 then
      table.insert(result, "\\\\")
    elseif byte == 8 then
      table.insert(result, "\\b")
    elseif byte == 9 then
      table.insert(result, "\\t")
    elseif byte == 10 then
      table.insert(result, "\\n")
    elseif byte == 12 then
      table.insert(result, "\\f")
    elseif byte == 13 then
      table.insert(result, "\\r")
    elseif byte >= 32 and byte <= 126 then
      table.insert(result, string.char(byte))
    else
      table.insert(result, string.format("\\u%04x", byte))
    end
  end
  table.insert(result, '"')
  return table.concat(result)
end

local function is_array(value)
  local maximum = 0
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false
    end
    maximum = math.max(maximum, key)
    count = count + 1
  end
  return maximum == count
end

local function exact_keys(value, allowed, required)
  if type(value) ~= "table" then
    return false
  end
  for key in pairs(value) do
    if not allowed[key] then
      return false
    end
  end
  for key in pairs(required or allowed) do
    if value[key] == nil then
      return false
    end
  end
  return true
end

local function canonical_json(value)
  local kind = type(value)
  if kind == "string" then
    return json_string(value)
  end
  if kind == "number" then
    assert(value == value and value ~= math.huge and value ~= -math.huge, "nonfinite JSON number")
    return tostring(value)
  end
  if kind == "boolean" then
    return value and "true" or "false"
  end
  if kind ~= "table" then
    error("unsupported canonical JSON value")
  end
  if is_array(value) then
    local items = {}
    for index = 1, #value do
      items[index] = canonical_json(value[index])
    end
    return "[" .. table.concat(items, ",") .. "]"
  end
  local keys = {}
  for key in pairs(value) do
    assert(type(key) == "string", "canonical JSON object key is not a string")
    table.insert(keys, key)
  end
  table.sort(keys)
  local items = {}
  for _, key in ipairs(keys) do
    table.insert(items, json_string(key) .. ":" .. canonical_json(value[key]))
  end
  return "{" .. table.concat(items, ",") .. "}"
end

local function exact_object(kind, mode, size, sha256, storage, tree_oid)
  return {
    kind = kind,
    mode = mode,
    size = size,
    sha256 = sha256,
    storage = storage,
    tree_oid = tree_oid,
  }
end

local function absent_object()
  return exact_object("absent", nil, 0, nil, nil, nil)
end

local function unsupported_object()
  return exact_object("unsupported", nil, 0, nil, nil, nil)
end

local function fingerprint_hash(object, hash)
  return hash(table.concat({
    object.kind,
    object.mode or "",
    tostring(object.size),
    object.sha256 or "",
  }, "\0"))
end

local function fingerprint_object(object)
  return exact_object(object.kind, object.mode, object.size, object.sha256, nil, nil)
end

local function validate_identity(identity, deps)
  if
    type(identity) ~= "table"
    or type(identity.key) ~= "string"
    or #identity.key ~= 32
    or not identity.key:match("^[0-9a-f]+$")
    or type(identity.root) ~= "string"
    or identity.root:sub(1, 1) ~= "/"
    or type(identity.inside_git) ~= "boolean"
  then
    return nil, "AI identity is invalid for baseline capture"
  end
  local root = deps.realpath(identity.root)
  local stat = deps.lstat(identity.root)
  if root ~= identity.root or not stat or stat.type ~= "directory" then
    return nil, "AI identity root is not a physical directory"
  end
  if identity.inside_git then
    if
      type(identity.git_dir) ~= "string"
      or identity.git_dir:sub(1, 1) ~= "/"
      or type(identity.git_common_dir) ~= "string"
      or identity.git_common_dir:sub(1, 1) ~= "/"
    then
      return nil, "Git identity metadata is incomplete"
    end
  end
  return true
end

local function validate_relative(path)
  if type(path) ~= "string" or path == "" or path:find("\0", 1, true) or path:sub(1, 1) == "/" then
    return nil, "Git path is invalid"
  end
  for component in path:gmatch("[^/]+") do
    if component == "." or component == ".." then
      return nil, "Git path escaped the physical root"
    end
  end
  if path:find("//", 1, true) or path:sub(-1) == "/" then
    return nil, "Git path is invalid"
  end
  return true
end

local function validate_parent(root, path, deps)
  local valid, err = validate_relative(path)
  if not valid then
    return nil, err
  end
  local full = root .. "/" .. path
  local current = vim.fs.dirname(full)
  local physical
  while current and path_within(root, current) do
    physical = deps.realpath(current)
    if physical then
      break
    end
    if current == root then
      break
    end
    current = vim.fs.dirname(current)
  end
  if not physical or not path_within(root, physical) then
    return nil, "Git path escaped the physical root"
  end
  return full
end

local function split_nul(bytes, label)
  if bytes == "" then
    return {}
  end
  if bytes:sub(-1) ~= "\0" then
    return nil, label .. " returned an unterminated record"
  end
  local result = {}
  local start = 1
  while start <= #bytes do
    local finish = bytes:find("\0", start, true)
    if not finish then
      return nil, label .. " returned an unterminated record"
    end
    local value = bytes:sub(start, finish - 1)
    if value == "" then
      return nil, label .. " returned an empty record"
    end
    table.insert(result, value)
    start = finish + 1
  end
  return result
end

local function parse_tree(bytes)
  local records, err = split_nul(bytes, "Git tree enumeration")
  if not records then
    return nil, err
  end
  local result = {}
  for _, record in ipairs(records) do
    local header, path = record:match("^([^\t]+)\t(.*)$")
    local mode, kind, oid
    if header then
      mode, kind, oid = header:match("^(%d+) ([^ ]+) ([0-9a-f]+)$")
    end
    if not mode or not path or path == "" or not valid_oid(oid) or result[path] then
      return nil, "Git tree enumeration returned an invalid record"
    end
    result[path] = { mode = mode, kind = kind, oid = oid }
  end
  return result
end

local function parse_index(bytes)
  local records, err = split_nul(bytes, "Git index enumeration")
  if not records then
    return nil, err
  end
  local result = {}
  for _, record in ipairs(records) do
    local header, path = record:match("^([^\t]+)\t(.*)$")
    local mode, oid, stage
    if header then
      mode, oid, stage = header:match("^(%d+) ([0-9a-f]+) (%d+)$")
    end
    stage = tonumber(stage)
    if not mode or not path or path == "" or not valid_oid(oid) or stage == nil then
      return nil, "Git index enumeration returned an invalid record"
    end
    local existing = result[path]
    if existing and (existing.stage == 0 or stage == 0 or existing.stage == stage) then
      return nil, "Git index enumeration returned a duplicate stage"
    end
    if existing then
      existing.stage = -1
    else
      result[path] = { mode = mode, oid = oid, stage = stage }
    end
  end
  return result
end

local function parse_names(bytes, label)
  local records, err = split_nul(bytes, label)
  if not records then
    return nil, err
  end
  local result = {}
  for _, path in ipairs(records) do
    if result[path] then
      return nil, label .. " returned a duplicate path"
    end
    result[path] = true
  end
  return result
end

local function regular_mode(stat)
  return bit.band(stat.mode, EXECUTE_BITS) ~= 0 and "100755" or "100644"
end

local function valid_git_mode(mode)
  return mode == "100644" or mode == "100755" or mode == "120000"
end

local FAILURE_PHASE_ORDER = {
  "primary",
  "cleanup",
  "synchronization",
  "release",
  "close",
}
local FAILURE_OPERATION_ORDER = {
  primary = {},
  cleanup = {
    "restore-publication-review",
    "validate-cleanup-context",
    "validate-cleanup-reviews",
    "open-cleanup-reviews",
    "validate-cleanup-review",
    "claim-cleanup-review",
    "open-cleanup-review",
    "scan-cleanup-review",
    "validate-cleanup-objects",
    "open-cleanup-objects",
    "scan-cleanup-objects",
    "validate-cleanup-object",
    "validate-cleanup-manifest",
    "claim-cleanup-object",
    "claim-cleanup-manifest",
    "unlink-cleanup-object",
    "verify-cleanup-object-absent",
    "claim-cleanup-objects",
    "rmdir-cleanup-objects",
    "verify-cleanup-objects-absent",
    "unlink-cleanup-manifest",
    "verify-cleanup-manifest-absent",
    "claim-owned-cleanup-review",
    "rmdir-cleanup-review",
    "verify-cleanup-review-absent",
    "restore-cleanup-manifest",
    "restore-cleanup-object",
    "restore-cleanup-review",
    "restore-removal-manifest",
    "restore-removal-object",
    "restore-removal-review",
  },
  synchronization = {
    "fsync-private-baseline-file",
    "fsync-publication-objects",
    "fsync-publication-review",
    "fsync-publication-reviews",
    "fsync-cleanup-objects",
    "fsync-cleanup-review",
    "fsync-cleanup-reviews",
    "fsync-removal-objects",
    "fsync-removal-review",
    "fsync-removal-reviews",
  },
  release = {},
  close = {
    "close-baseline-source",
    "close-private-baseline-file",
    "close-directory-anchor",
    "close-publication-objects",
    "close-publication-review",
    "close-publication-reviews",
    "close-cleanup-objects",
    "close-cleanup-review",
    "close-cleanup-reviews",
    "close-removal-objects",
    "close-removal-review",
    "close-removal-reviews",
  },
}
local MAX_FAILURES_PER_PHASE = 8
local MAX_FAILURE_CODE_BYTES = 24
local FAILURE_CODE_WINDOW_BYTES = MAX_FAILURE_CODE_BYTES + 1
local MAX_COMPATIBILITY_DETAIL_BYTES = 128
local ADDITIONAL_FAILURE_COMPONENT = "additional-failures (UNKNOWN)"
local COMPATIBILITY_KINDS = {
  transaction_load_scan = true,
  cleanup_review_rmdir = true,
  removal_review_rmdir = true,
}

local function valid_failure_code(value)
  return type(value) == "string"
    and #value <= MAX_FAILURE_CODE_BYTES
    and value:match("^E[A-Z0-9_]+$") ~= nil
end

local function normalize_failure_code(err, code)
  if valid_failure_code(code) then
    return code
  end
  if type(err) == "string" then
    local window = err:sub(1, FAILURE_CODE_WINDOW_BYTES)
    local candidate = window:match("^(E[A-Z0-9_]+)")
    if valid_failure_code(candidate) then
      local boundary = window:sub(#candidate + 1, #candidate + 1)
      if boundary == "" or boundary:match("[^A-Za-z0-9_]") then
        return candidate
      end
    end
  end
  return "UNKNOWN"
end

local function require_absent(path, deps_for_check, label)
  local stat, stat_error, stat_code = deps_for_check.lstat(path)
  if stat then
    return nil, label .. " still exists"
  end
  local code = normalize_failure_code(stat_error, stat_code)
  if code ~= "ENOENT" then
    return nil, label .. " absence could not be verified (" .. code .. ")"
  end
  return true
end

local function bounded_compatibility_detail(value)
  if
    type(value) == "string"
    and value ~= ""
    and #value <= MAX_COMPATIBILITY_DETAIL_BYTES
    and not value:find("\0", 1, true)
    and not value:find("\r", 1, true)
    and not value:find("\n", 1, true)
  then
    return value
  end
  return nil
end

local function dependency_primary(prefix, err, code, compatibility_kind)
  local detail = compatibility_kind and bounded_compatibility_detail(err) or nil
  return prefix .. (detail or normalize_failure_code(err, code)), detail
end

local function new_failure_collector(primary)
  assert(
    primary == nil or (type(primary) == "string" and primary ~= ""),
    "baseline primary failure is invalid"
  )
  return {
    primary = primary,
    phases = {},
    compatibility = {},
  }
end

local function adopt_failure_collector(failures)
  if failures ~= nil then
    assert(
      type(failures) == "table"
        and type(rawget(failures, "phases")) == "table"
        and type(rawget(failures, "compatibility")) == "table",
      "baseline failure collector is invalid"
    )
    return failures, false
  end
  return new_failure_collector(nil), true
end

local function set_primary_failure(failures, primary)
  if primary == nil then
    return
  end
  assert(type(primary) == "string" and primary ~= "", "baseline primary failure is invalid")
  if failures.primary == nil then
    failures.primary = primary
  end
end

local function set_compatibility_detail(failures, kind, value)
  assert(COMPATIBILITY_KINDS[kind], "baseline compatibility kind is invalid")
  local detail = bounded_compatibility_detail(value)
  if detail and failures.compatibility[kind] == nil then
    failures.compatibility[kind] = detail
  end
  return detail
end

local function append_failure(failures, phase, operation, err, code)
  local operation_order = FAILURE_OPERATION_ORDER[phase]
  assert(operation_order, "baseline failure phase is invalid")

  local allowed = false
  for _, candidate in ipairs(operation_order) do
    if candidate == operation then
      allowed = true
      break
    end
  end
  assert(allowed, "baseline failure operation is invalid")

  local bucket = failures.phases[phase]
  if not bucket then
    bucket = {
      entries = {},
      seen = {},
      count = 0,
      additional = false,
    }
    failures.phases[phase] = bucket
  end

  local normalized = normalize_failure_code(err, code)
  local key = operation .. "\0" .. normalized
  if bucket.seen[key] then
    bucket.additional = true
    return
  end
  if bucket.count >= MAX_FAILURES_PER_PHASE then
    bucket.additional = true
    return
  end

  bucket.seen[key] = true
  bucket.count = bucket.count + 1
  bucket.entries[operation] = bucket.entries[operation] or {}
  table.insert(bucket.entries[operation], normalized)
end

local function phase_has_failures(failures, phase)
  local bucket = failures.phases[phase]
  return bucket ~= nil and (bucket.count > 0 or bucket.additional)
end

local function exact_phase_operation(failures, phase, operation)
  local bucket = failures.phases[phase]
  if not bucket or bucket.additional or bucket.count ~= 1 then
    return false
  end
  local codes = bucket.entries[operation]
  if type(codes) ~= "table" or #codes ~= 1 then
    return false
  end
  for candidate in pairs(bucket.entries) do
    if candidate ~= operation then
      return false
    end
  end
  return true
end

local function render_compatible_cleanup(failures)
  if failures.release_batch ~= nil then
    return nil
  end
  for phase in pairs(failures.phases) do
    if phase ~= "cleanup" then
      return nil
    end
  end

  local primary_detail = failures.compatibility.transaction_load_scan
  local cleanup_detail = failures.compatibility.cleanup_review_rmdir
  if
    not primary_detail
    or not cleanup_detail
    or failures.primary ~= "could not scan baseline storage: " .. primary_detail
    or not exact_phase_operation(failures, "cleanup", "rmdir-cleanup-review")
  then
    return nil
  end

  return failures.primary
    .. "; publication cleanup failed: could not clean failed review publication: "
    .. cleanup_detail
end

local function render_failures(failures, primary_marker)
  local rendered = {}
  for _, phase in ipairs(FAILURE_PHASE_ORDER) do
    if phase == "primary" then
      if failures.primary then
        table.insert(rendered, failures.primary)
        if primary_marker then
          table.insert(rendered, primary_marker)
        end
      end
    elseif phase == "release" then
      if failures.release_batch then
        table.insert(rendered, failures.release_batch)
      end
    else
      local bucket = failures.phases[phase]
      if bucket then
        for _, operation in ipairs(FAILURE_OPERATION_ORDER[phase]) do
          local codes = bucket.entries[operation]
          if codes then
            table.sort(codes)
            for _, code in ipairs(codes) do
              table.insert(rendered, operation .. " (" .. code .. ")")
            end
          end
        end
        if bucket.additional then
          table.insert(rendered, ADDITIONAL_FAILURE_COMPONENT)
        end
      end
    end
  end
  return table.concat(rendered, "; ")
end

local function render_public_failures(failures)
  local compatible = render_compatible_cleanup(failures)
  if compatible then
    return compatible
  end

  local primary_detail = failures.compatibility.transaction_load_scan
  if
    primary_detail
    and failures.primary == "could not scan baseline storage: " .. primary_detail
    and phase_has_failures(failures, "cleanup")
  then
    return render_failures(failures, "publication cleanup failed")
  end
  return render_failures(failures)
end

local function with_result_count(...)
  return select("#", ...), ...
end

local function close_owned(owner, key, deps_for_close, failures, operation)
  local owned = owner[key]
  owner[key] = nil
  if not owned then
    return true
  end

  local result_count, invoked, closed, close_error, close_code =
    with_result_count(pcall(deps_for_close.close, owned.fd))
  if
    result_count <= 4
    and invoked
    and closed == true
    and close_error == nil
    and close_code == nil
  then
    return true
  end

  local error_value
  local error_code
  if invoked then
    error_value = close_error
    error_code = close_code
    if error_value == nil and closed ~= true then
      error_value = closed
    end
  else
    error_value = closed
  end
  append_failure(failures, "close", operation, error_value, error_code)
  return false
end

local function read_regular(path, before, deps, supplied_failures)
  if before.size > MAX_FILE_BYTES then
    local primary = "file exceeds baseline capture bound"
    if supplied_failures then
      set_primary_failure(supplied_failures, primary)
    end
    return nil, primary
  end

  local fd, open_error, open_code = deps.open(path, "r", 0)
  if not fd then
    local primary =
      dependency_primary("could not open file for baseline capture: ", open_error, open_code)
    if supplied_failures then
      set_primary_failure(supplied_failures, primary)
    end
    return nil, primary
  end

  local failures, private = adopt_failure_collector(supplied_failures)
  local function finish_capture(primary)
    set_primary_failure(failures, primary)
    local owner = {
      source = { fd = fd },
    }
    fd = nil
    local closed = close_owned(owner, "source", deps, failures, "close-baseline-source")
    if primary ~= nil or not closed then
      return nil, private and render_failures(failures) or primary
    end
    return true
  end

  local opened = deps.fstat(fd)
  if not opened or not same_stat(before, opened) then
    return finish_capture("file changed during capture: metadata")
  end

  local chunks = {}
  local offset = 0
  while offset < before.size do
    local length = math.min(1024 * 1024, before.size - offset)
    local bytes = deps.read(fd, length, offset)
    if type(bytes) ~= "string" or #bytes == 0 then
      return finish_capture("file changed during capture: short read")
    end
    table.insert(chunks, bytes)
    offset = offset + #bytes
  end

  local extra = deps.read(fd, 1, before.size)
  local finished = deps.fstat(fd)
  local primary
  if extra ~= nil and extra ~= "" then
    primary = "file changed during capture: grew while reading"
  elseif not same_stat(before, finished) then
    primary = "file changed during capture"
  end
  local closed, capture_error = finish_capture(primary)
  if not closed then
    return nil, capture_error
  end

  local bytes = table.concat(chunks)
  if #bytes ~= before.size then
    primary = "file changed during capture: size mismatch"
    set_primary_failure(failures, primary)
    return nil, private and render_failures(failures) or primary
  end
  if deps.after_read then
    deps.after_read(path, bytes)
  end
  local after = deps.lstat(path)
  if not same_stat(before, after) then
    primary = "file changed during capture"
    set_primary_failure(failures, primary)
    return nil, private and render_failures(failures) or primary
  end
  return bytes
end

local function fingerprint_path(root, path, deps, failures)
  local full, parent_error = validate_parent(root, path, deps)
  if not full then
    if failures then
      set_primary_failure(failures, parent_error)
    end
    return nil, nil, parent_error
  end
  local before = deps.lstat(full)
  if not before then
    return absent_object(), nil
  end
  if before.type == "file" then
    if type(before.mode) ~= "number" or type(before.size) ~= "number" or before.size < 0 then
      local primary = "regular file metadata is incomplete"
      if failures then
        set_primary_failure(failures, primary)
      end
      return nil, nil, primary
    end
    local bytes, read_error = read_regular(full, before, deps, failures)
    if not bytes then
      return nil, nil, read_error
    end
    local checked, checked_error = validate_parent(root, path, deps)
    if not checked or checked ~= full then
      local primary = checked_error or "Git path escaped during capture"
      if failures then
        set_primary_failure(failures, primary)
      end
      return nil, nil, primary
    end
    return exact_object("regular", regular_mode(before), #bytes, deps.hash(bytes), nil, nil), bytes
  end
  if before.type == "link" then
    local target, read_error, read_code = deps.readlink(full)
    if type(target) ~= "string" then
      local primary =
        dependency_primary("could not read symlink during capture: ", read_error, read_code)
      if failures then
        set_primary_failure(failures, primary)
      end
      return nil, nil, primary
    end
    if deps.after_read then
      deps.after_read(full, target)
    end
    local after = deps.lstat(full)
    if not same_stat(before, after) then
      local primary = "symlink changed during capture"
      if failures then
        set_primary_failure(failures, primary)
      end
      return nil, nil, primary
    end
    local checked, checked_error = validate_parent(root, path, deps)
    if not checked or checked ~= full then
      local primary = checked_error or "Git path escaped during capture"
      if failures then
        set_primary_failure(failures, primary)
      end
      return nil, nil, primary
    end
    return exact_object("symlink", "120000", #target, deps.hash(target), nil, nil), target
  end
  return unsupported_object(), nil
end

local function validate_private_directory(path, uid, deps, label)
  local stat = deps.lstat(path)
  local physical = deps.realpath(path)
  if
    not stat
    or stat.type ~= "directory"
    or stat.uid ~= uid
    or type(stat.mode) ~= "number"
    or bit.band(stat.mode, PERMISSION_BITS) ~= DIRECTORY_MODE
    or physical ~= path
  then
    return nil, label .. " is not a current-user mode 0700 nonsymlink directory"
  end
  return stat
end

local function validate_private_file(path, uid, deps, label)
  local stat = deps.lstat(path)
  if
    not stat
    or stat.type ~= "file"
    or stat.uid ~= uid
    or stat.nlink ~= 1
    or type(stat.mode) ~= "number"
    or bit.band(stat.mode, PERMISSION_BITS) ~= FILE_MODE
  then
    return nil, label .. " is not a current-user mode 0600 nonsymlink file"
  end
  return stat
end

local function read_bounded_file(path, stat, maximum, deps, label, failures)
  if type(stat.size) ~= "number" or stat.size < 0 or stat.size > maximum then
    local primary = label .. " exceeds its size bound"
    if failures then
      set_primary_failure(failures, primary)
    end
    return nil, primary
  end
  return read_regular(path, stat, deps, failures)
end

local function write_new_file(path, bytes, deps, supplied_failures, open_failure_prefix)
  local fd, open_error, open_code = deps.open(path, "wx", FILE_MODE)
  if not fd then
    local primary = dependency_primary(
      open_failure_prefix or "could not create private baseline file: ",
      open_error,
      open_code
    )
    if supplied_failures then
      set_primary_failure(supplied_failures, primary)
    end
    return nil, primary
  end

  local failures, private = adopt_failure_collector(supplied_failures)
  local owner = {
    file = { fd = fd },
  }
  fd = nil

  local function finish_file(primary)
    set_primary_failure(failures, primary)
    local closed = close_owned(owner, "file", deps, failures, "close-private-baseline-file")
    if primary ~= nil or not closed then
      return nil, private and render_failures(failures) or primary
    end
    return true
  end

  local offset = 0
  while offset < #bytes do
    local written, write_error, write_code =
      deps.write(owner.file.fd, bytes:sub(offset + 1), offset)
    if type(written) ~= "number" or written < 1 or write_error ~= nil or write_code ~= nil then
      local stat = deps.fstat(owner.file.fd)
      local _, write_error = finish_file("could not write private baseline file")
      return nil, write_error, stat
    end
    offset = offset + written
  end

  local synced, sync_error, sync_code = deps.fsync(owner.file.fd)
  local stat = deps.fstat(owner.file.fd)
  local primary
  if synced ~= true or sync_error ~= nil or sync_code ~= nil then
    if private then
      primary = dependency_primary(
        "could not fsync private baseline file: ",
        sync_error or synced,
        sync_code
      )
    else
      primary = "could not fsync private baseline file"
      append_failure(
        failures,
        "synchronization",
        "fsync-private-baseline-file",
        sync_error or synced,
        sync_code
      )
    end
  elseif not stat then
    primary = "could not stat private baseline file after writing"
  end

  local closed, close_error = finish_file(primary)
  if not closed then
    return nil, close_error, stat
  end
  return true, nil, stat
end

local function open_anchored_directory(
  path,
  expected,
  deps,
  label,
  supplied_failures,
  close_operation,
  failure_phase,
  failure_operation
)
  local fd, open_error, open_code = deps.open(path, "r", 0)
  if not fd then
    local primary = dependency_primary(label .. " could not be opened: ", open_error, open_code)
    if supplied_failures then
      if failure_phase and failure_operation then
        append_failure(supplied_failures, failure_phase, failure_operation, open_error, open_code)
      else
        set_primary_failure(supplied_failures, primary)
      end
    end
    return nil, primary
  end

  local failures, private = adopt_failure_collector(supplied_failures)
  local owner = {
    directory_anchor = { fd = fd },
  }
  fd = nil
  close_operation = close_operation or "close-directory-anchor"

  local function fail(primary, err, code)
    if supplied_failures and failure_phase and failure_operation then
      append_failure(failures, failure_phase, failure_operation, err, code)
    else
      set_primary_failure(failures, primary)
    end
    close_owned(owner, "directory_anchor", deps, failures, close_operation)
    return nil, private and render_failures(failures) or primary
  end

  local opened = deps.fstat(owner.directory_anchor.fd)
  if not same_stat(expected, opened) then
    return fail(label .. " changed before it could be anchored: metadata")
  end
  local resolved, anchor_path = pcall(deps.fd_path, owner.directory_anchor.fd)
  if not resolved or type(anchor_path) ~= "string" or anchor_path:sub(1, 1) ~= "/" then
    return fail(label .. " has no stable descriptor anchor")
  end
  local anchored = deps.fstat(owner.directory_anchor.fd)
  local anchored_path = deps.lstat(anchor_path .. "/.")
  if not same_stat(expected, anchored) or not same_identity(expected, anchored_path) then
    return fail(label .. " changed while it was anchored")
  end

  local anchor = owner.directory_anchor
  owner.directory_anchor = nil
  anchor.path = anchor_path
  return anchor
end

local function scan_directory(path, deps)
  local scanner, scan_error, scan_code = deps.scandir(path)
  if not scanner then
    return nil, scan_error, scan_code
  end
  local result = {}
  while true do
    local name, kind_or_error, next_code = deps.scandir_next(scanner)
    if not name then
      if kind_or_error ~= nil or next_code ~= nil then
        return nil, kind_or_error, next_code
      end
      break
    end
    result[name] = kind_or_error
  end
  return result
end

local function default_system(argv, options)
  return review_task.system(argv, options)
end

local function default_fd_path(fd)
  for _, prefix in ipairs({ "/proc/self/fd/", "/dev/fd/" }) do
    local path = prefix .. tostring(fd)
    if vim.uv.fs_lstat(path) then
      return path
    end
  end
  return nil, "stable directory descriptor path is unavailable"
end

local default_dependencies = {
  lstat = vim.uv.fs_lstat,
  realpath = vim.uv.fs_realpath,
  readlink = vim.uv.fs_readlink,
  open = vim.uv.fs_open,
  fstat = vim.uv.fs_fstat,
  read = vim.uv.fs_read,
  write = vim.uv.fs_write,
  fsync = vim.uv.fs_fsync,
  close = vim.uv.fs_close,
  mkdir = vim.uv.fs_mkdir,
  unlink = vim.uv.fs_unlink,
  rmdir = vim.uv.fs_rmdir,
  rename = vim.uv.fs_rename,
  scandir = vim.uv.fs_scandir,
  scandir_next = vim.uv.fs_scandir_next,
  hash = vim.fn.sha256,
  uid = vim.uv.getuid,
  pid = vim.fn.getpid,
  hrtime = vim.uv.hrtime,
  resolve_git = function()
    return trusted_tools.resolve("git")
  end,
  revalidate_git = trusted_tools.revalidate,
  system = default_system,
  fd_path = default_fd_path,
  serialization = serialization_module,
}

local function dependencies(overrides)
  return vim.tbl_extend("force", {}, default_dependencies, overrides or {})
end

local function new(overrides)
  local deps = dependencies(overrides)
  local api = {}

  local function run_git(identity, family, tail, stdin)
    if deps.run_git then
      return deps.run_git(identity, family, tail, stdin)
    end
    local git, resolve_error, resolve_code = deps.resolve_git()
    if not git then
      local primary =
        dependency_primary("trusted Git executable is unavailable: ", resolve_error, resolve_code)
      return nil, primary
    end
    local valid, validation_error, validation_code = deps.revalidate_git(git)
    if not valid then
      local primary =
        dependency_primary("trusted Git executable changed: ", validation_error, validation_code)
      return nil, primary
    end
    local argv = { git, "-C", identity.root, "-c", "core.fsmonitor=false" }
    vim.list_extend(argv, tail)
    local invoked, result = pcall(deps.system, argv, {
      clear_env = true,
      env = {
        LC_ALL = "C",
        LANG = "C",
        GIT_OPTIONAL_LOCKS = "0",
        GIT_CONFIG_NOSYSTEM = "1",
        GIT_CONFIG_GLOBAL = "/dev/null",
        GIT_CONFIG_COUNT = "0",
      },
      stdin = stdin,
      text = false,
    })
    if
      not invoked
      or type(result) ~= "table"
      or type(result.code) ~= "number"
      or type(result.signal) ~= "number"
      or type(result.stdout) ~= "string"
      or type(result.stderr) ~= "string"
      or result.signal ~= 0
      or result.code == 124
    then
      return nil, "Git " .. family .. " did not complete safely"
    end
    return result
  end

  local function object_id(identity, bytes)
    local result, err =
      run_git(identity, "object hashing", { "hash-object", "--no-filters", "--stdin" }, bytes)
    if not result then
      return nil, err
    end
    if result.code ~= 0 then
      return nil, "Git object hashing failed"
    end
    local oid = result.stdout:match("^([0-9a-f]+)\n?$")
    if not valid_oid(oid) then
      return nil, "Git object hashing returned an invalid object id"
    end
    return oid
  end

  local function read_tree_object(identity, oid)
    if not valid_oid(oid) then
      return nil, "tree object id is invalid"
    end
    local result, err = run_git(identity, "object read", { "cat-file", "blob", oid })
    if not result then
      return nil, err
    end
    if result.code ~= 0 then
      return nil, "Git tree object is unavailable"
    end
    return result.stdout
  end

  -- Read immutable baseline blobs through one Git process. Object ids, framing,
  -- types and byte lengths are checked; callers still verify every fingerprint.
  local function read_tree_objects(identity, requested)
    local oids = vim.tbl_keys(requested)
    table.sort(oids)
    if #oids == 0 then
      return {}
    end
    if #oids == 1 then
      local bytes, err = read_tree_object(identity, oids[1])
      return bytes and { [oids[1]] = bytes } or nil, err
    end
    local result, err = run_git(
      identity,
      "batch object read",
      { "cat-file", "--batch" },
      table.concat(oids, "\n") .. "\n"
    )
    if not result then
      return nil, err
    end
    if result.code ~= 0 then
      return nil, "Git tree object batch is unavailable"
    end
    local objects, offset = {}, 1
    for _, expected in ipairs(oids) do
      local ending = result.stdout:find("\n", offset, true)
      if not ending or ending - offset > 128 then
        return nil, "Git tree object batch header is invalid"
      end
      local oid, size_text = result.stdout:sub(offset, ending - 1):match("^([0-9a-f]+) blob (%d+)$")
      local size = size_text and tonumber(size_text)
      if oid ~= expected or not size or size > MAX_FILE_BYTES or tostring(size) ~= size_text then
        return nil, "Git tree object batch identity or size is invalid"
      end
      local finish = ending + size
      if result.stdout:sub(finish + 1, finish + 1) ~= "\n" then
        return nil, "Git tree object batch payload is truncated"
      end
      objects[oid] = result.stdout:sub(ending + 1, finish)
      offset = finish + 2
    end
    if offset ~= #result.stdout + 1 then
      return nil, "Git tree object batch has trailing bytes"
    end
    return objects
  end

  local function enumerate(identity)
    local head, head_error =
      run_git(identity, "HEAD tree query", { "rev-parse", "--verify", "HEAD^{tree}" })
    if not head then
      return nil, head_error
    end
    local tree_oid
    if head.code == 0 then
      tree_oid = head.stdout:match("^([0-9a-f]+)\n?$")
      if not valid_oid(tree_oid) then
        return nil, "Git HEAD tree query returned an invalid object id"
      end
    elseif head.code ~= 128 then
      return nil, "Git HEAD tree query failed"
    end

    local tree = {}
    if tree_oid then
      local result, err =
        run_git(identity, "tree enumeration", { "ls-tree", "-rz", "--full-tree", "HEAD" })
      if not result then
        return nil, err
      end
      if result.code ~= 0 then
        return nil, "Git tree enumeration failed"
      end
      tree, err = parse_tree(result.stdout)
      if not tree then
        return nil, err
      end
    end

    local index_result, index_error =
      run_git(identity, "index enumeration", { "ls-files", "-z", "--stage" })
    if not index_result then
      return nil, index_error
    end
    if index_result.code ~= 0 then
      return nil, "Git index enumeration failed"
    end
    local index, parse_error = parse_index(index_result.stdout)
    if not index then
      return nil, parse_error
    end

    local staged_result, staged_error = run_git(identity, "staged path enumeration", {
      "diff",
      "--cached",
      "--no-ext-diff",
      "--no-textconv",
      "--name-only",
      "-z",
      "--diff-filter=ACDMRTUXB",
    })
    if not staged_result then
      return nil, staged_error
    end
    if staged_result.code ~= 0 then
      return nil, "Git staged path enumeration failed"
    end
    local staged
    staged, parse_error = parse_names(staged_result.stdout, "Git staged path enumeration")
    if not staged then
      return nil, parse_error
    end

    local untracked_result, untracked_error = run_git(
      identity,
      "untracked path enumeration",
      { "ls-files", "-z", "--others", "--exclude-standard" }
    )
    if not untracked_result then
      return nil, untracked_error
    end
    if untracked_result.code ~= 0 then
      return nil, "Git untracked path enumeration failed"
    end
    local untracked
    untracked, parse_error = parse_names(untracked_result.stdout, "Git untracked path enumeration")
    if not untracked then
      return nil, parse_error
    end

    local ignored_result, ignored_error = run_git(
      identity,
      "ignored path enumeration",
      { "ls-files", "-z", "--others", "--ignored", "--exclude-standard" }
    )
    if not ignored_result then
      return nil, ignored_error
    end
    if ignored_result.code ~= 0 then
      return nil, "Git ignored path enumeration failed"
    end
    local ignored
    ignored, parse_error = parse_names(ignored_result.stdout, "Git ignored path enumeration")
    if not ignored then
      return nil, parse_error
    end

    return {
      tree_oid = tree_oid,
      tree = tree,
      index = index,
      staged = staged,
      untracked = untracked,
      ignored = ignored,
    }
  end

  local function verify_git_capture(identity, captured, failures)
    local paths = vim.tbl_keys(captured.observed)
    table.sort(paths)
    for _, path in ipairs(paths) do
      local current, bytes, path_error = fingerprint_path(identity.root, path, deps, failures)
      if not current then
        return nil, path_error
      end
      local expected = captured.observed[path]
      if
        not expected
        or not vim.deep_equal(fingerprint_object(current), expected.object)
        or bytes ~= expected.bytes
      then
        return nil, "path changed before baseline capture completed"
      end
      review_task.checkpoint()
    end
    local ignored_paths = vim.tbl_keys(captured.ignored_observed)
    table.sort(ignored_paths)
    for _, path in ipairs(ignored_paths) do
      local current, bytes, path_error = fingerprint_path(identity.root, path, deps, failures)
      if not current then
        return nil, path_error
      end
      local expected = captured.ignored_observed[path]
      if
        not expected
        or not vim.deep_equal(fingerprint_object(current), expected.object)
        or bytes ~= expected.bytes
      then
        return nil, "ignored path changed before baseline capture completed"
      end
      review_task.checkpoint()
    end
    local final_inventory, final_inventory_error = enumerate(identity)
    if not final_inventory then
      return nil, final_inventory_error
    end
    if not vim.deep_equal(captured.inventory, final_inventory) then
      return nil, "Git-visible paths changed before baseline capture completed"
    end
    return true
  end

  local function capture_git(identity, fingerprint_only)
    local inventory, inventory_error = enumerate(identity)
    if not inventory then
      return nil, inventory_error
    end
    local visible = {}
    for path in pairs(inventory.tree) do
      visible[path] = true
    end
    for path in pairs(inventory.index) do
      visible[path] = true
    end
    for path in pairs(inventory.untracked) do
      visible[path] = true
    end
    local paths = vim.tbl_keys(visible)
    table.sort(paths)

    local captured = {
      tree_oid = inventory.tree_oid,
      paths = {},
      ignored = {},
      bytes = {},
      binary = {},
      observed = {},
      ignored_observed = {},
      inventory = inventory,
    }
    for _, path in ipairs(paths) do
      local valid, path_error = validate_relative(path)
      if not valid then
        return nil, path_error
      end
      local tree = inventory.tree[path]
      local index = inventory.index[path]
      local object
      local bytes
      local reason
      if
        (tree and (tree.kind ~= "blob" or not valid_git_mode(tree.mode)))
        or (index and (index.stage ~= 0 or not valid_git_mode(index.mode)))
      then
        local observed, observed_bytes, parent_error = fingerprint_path(identity.root, path, deps)
        if parent_error then
          return nil, parent_error
        end
        captured.observed[path] = {
          object = fingerprint_object(observed),
          bytes = observed_bytes,
        }
        object = unsupported_object()
        reason = tree
            and (tree.kind ~= "blob" or not valid_git_mode(tree.mode))
            and "unsupported Git tree entry"
          or index and index.stage ~= 0 and "unmerged Git index entry"
          or "unsupported Git index mode"
      else
        object, bytes, path_error = fingerprint_path(identity.root, path, deps)
        if not object then
          return nil, path_error
        end
        captured.observed[path] = {
          object = fingerprint_object(object),
          bytes = bytes,
        }
        if inventory.untracked[path] and object.kind == "absent" then
          return nil, "untracked path changed during capture"
        end
        if not fingerprint_only and (object.kind == "regular" or object.kind == "symlink") then
          local tracked = tree ~= nil or index ~= nil
          if tracked then
            local oid, oid_error = object_id(identity, bytes)
            if not oid then
              return nil, oid_error
            end
            if
              tree
              and not inventory.staged[path]
              and tree.kind == "blob"
              and tree.mode == object.mode
              and tree.oid == oid
              and (
                not index
                or (index.stage == 0 and index.mode == tree.mode and index.oid == tree.oid)
              )
            then
              object.storage = "tree:" .. tree.oid
              object.tree_oid = tree.oid
            else
              object.storage = "copy:" .. object.sha256
            end
          else
            object.storage = "copy:" .. object.sha256
          end
        end
      end
      captured.paths[path] = { object = object, reason = reason }
      captured.bytes[path] = bytes
      captured.binary[path] = type(bytes) == "string" and not reducer.is_text(bytes) or false
      review_task.checkpoint()
    end

    local ignored_paths = vim.tbl_keys(inventory.ignored)
    table.sort(ignored_paths)
    for _, path in ipairs(ignored_paths) do
      local object, bytes, path_error = fingerprint_path(identity.root, path, deps)
      if not object then
        return nil, path_error
      end
      if object.kind == "absent" then
        return nil, "ignored path changed during capture"
      end
      object.storage = nil
      object.tree_oid = nil
      captured.ignored[path] = { object = object }
      captured.ignored_observed[path] = {
        object = fingerprint_object(object),
        bytes = bytes,
      }
      captured.binary[path] = type(bytes) == "string" and not reducer.is_text(bytes) or false
      review_task.checkpoint()
    end

    local verified, verification_error = verify_git_capture(identity, captured)
    if not verified then
      return nil, verification_error
    end
    return captured
  end

  local function capture(identity, requested_paths, fingerprint_only)
    if identity.inside_git then
      return capture_git(identity, fingerprint_only)
    end
    local captured = { tree_oid = nil, paths = {}, ignored = {}, bytes = {}, binary = {} }
    for _, path in ipairs(requested_paths or {}) do
      local object, bytes, err = fingerprint_path(identity.root, path, deps)
      if not object then
        return nil, err
      end
      captured.paths[path] = { object = object }
      captured.bytes[path] = bytes
      captured.binary[path] = type(bytes) == "string" and not reducer.is_text(bytes) or false
    end
    return captured
  end

  local function manifest_from_capture(identity, review_id, captured)
    local paths = {}
    local ignored = {}
    local names = vim.tbl_keys(captured.paths)
    table.sort(names)
    for _, path in ipairs(names) do
      table.insert(paths, {
        path_hex = encode_hex(path),
        object = clone(captured.paths[path].object),
      })
    end
    names = vim.tbl_keys(captured.ignored)
    table.sort(names)
    for _, path in ipairs(names) do
      table.insert(ignored, {
        path_hex = encode_hex(path),
        fingerprint = clone(captured.ignored[path].object),
      })
    end
    local manifest = {
      schema = SCHEMA,
      review_id = review_id,
      identity_key = identity.key,
      root_hex = encode_hex(identity.root),
      inside_git = identity.inside_git,
      conflict_only = not identity.inside_git,
      tree_oid = captured.tree_oid,
      paths = paths,
      ignored = ignored,
    }
    manifest.baseline_hash = deps.hash(canonical_json(manifest))
    return manifest
  end

  local function state_root_location(store)
    if type(store) ~= "table" or type(store.state_dir) ~= "function" then
      return nil, "baseline store is invalid"
    end

    local uid = deps.uid()
    if type(uid) ~= "number" then
      return nil, "current UID is unavailable"
    end

    local path = store:state_dir()
    local stat, state_error = validate_private_directory(path, uid, deps, "state directory")
    if not stat then
      return nil, state_error
    end

    return {
      uid = uid,
      path = path,
      stat = stat,
    }
  end

  local function same_state_root(expected, current)
    if
      type(expected) ~= "table"
      or type(current) ~= "table"
      or type(expected.path) ~= "string"
      or type(current.path) ~= "string"
      or type(expected.stat) ~= "table"
      or type(current.stat) ~= "table"
      or type(expected.stat.dev) ~= "number"
      or type(current.stat.dev) ~= "number"
      or type(expected.stat.ino) ~= "number"
      or type(current.stat.ino) ~= "number"
      or type(expected.stat.uid) ~= "number"
      or type(current.stat.uid) ~= "number"
      or type(expected.stat.type) ~= "string"
      or type(current.stat.type) ~= "string"
      or type(expected.stat.mode) ~= "number"
      or type(current.stat.mode) ~= "number"
    then
      return false
    end
    return expected.path == current.path
      and expected.stat.dev == current.stat.dev
      and expected.stat.ino == current.stat.ino
      and expected.stat.uid == current.stat.uid
      and expected.stat.type == current.stat.type
      and expected.stat.mode == current.stat.mode
  end

  local function state_location(store, review_id, create, expected_state)
    if
      type(store) ~= "table"
      or type(store.state_dir) ~= "function"
      or type(store.review_dir) ~= "function"
    then
      return nil, "baseline store is invalid"
    end
    local state, state_error = state_root_location(store)
    if not state then
      return nil, state_error
    end
    if expected_state and not same_state_root(expected_state, state) then
      return nil, "state directory changed before baseline publication"
    end
    local uid = state.uid
    local state_dir = state.path
    local reviews = vim.fs.joinpath(state_dir, "reviews")
    local expected = vim.fs.joinpath(reviews, review_id)
    if create then
      if deps.lstat(expected) then
        return nil, "generated review id collided with existing state"
      end
      local path, create_error = store:review_dir(review_id)
      if not path then
        return nil, create_error
      end
      if path ~= expected then
        return nil, "review directory escaped private state"
      end
    end
    local reviews_stat, reviews_error =
      validate_private_directory(reviews, uid, deps, "reviews directory")
    if not reviews_stat then
      return nil, reviews_error
    end
    local review_stat, review_error =
      validate_private_directory(expected, uid, deps, "review directory")
    if not review_stat then
      return nil, review_error
    end
    return {
      uid = uid,
      state_dir = state_dir,
      reviews = reviews,
      reviews_stat = reviews_stat,
      review_dir = expected,
      review_stat = review_stat,
    }
  end

  local function claim_named_entry(
    parent_anchor,
    name,
    expected,
    claimed_name,
    kind,
    label,
    failures,
    restore_operation,
    identity_failure
  )
    local source = vim.fs.joinpath(parent_anchor.path, name)
    local claimed = vim.fs.joinpath(parent_anchor.path, claimed_name)
    if deps.lstat(claimed) then
      return nil, label .. " claim already exists"
    end

    local renamed, rename_error, rename_code = deps.rename(source, claimed)
    if renamed ~= true or rename_error ~= nil or rename_code ~= nil then
      local primary = dependency_primary(
        "could not claim " .. label .. ": ",
        rename_error or renamed,
        rename_code
      )
      return nil, primary, rename_error or renamed, rename_code
    end

    local claimed_stat = deps.lstat(claimed)
    local matches = kind == "directory" and same_identity(expected, claimed_stat)
      or kind == "file" and same_leaf_identity(expected, claimed_stat)
    if not matches then
      if not deps.lstat(source) and deps.lstat(claimed) then
        local restored, restore_error, restore_code = deps.rename(claimed, source)
        if restored ~= true or restore_error ~= nil or restore_code ~= nil then
          if failures and restore_operation then
            append_failure(
              failures,
              "cleanup",
              restore_operation,
              restore_error or restored,
              restore_code
            )
          end
        end
      elseif failures and restore_operation then
        append_failure(failures, "cleanup", restore_operation, nil, nil)
      end
      return nil, identity_failure or label .. " changed while it was claimed"
    end

    return {
      name = name,
      claimed_name = claimed_name,
      path = claimed,
      stat = claimed_stat,
      kind = kind,
      label = label,
    }
  end

  local function restore_named_claim(parent_anchor, claim, failures, operation)
    if not claim then
      return true
    end
    local source = vim.fs.joinpath(parent_anchor.path, claim.name)
    if deps.lstat(source) or not deps.lstat(claim.path) then
      if failures and operation then
        append_failure(failures, "cleanup", operation, nil, nil)
      end
      return nil, claim.label .. " claim could not be restored"
    end

    local current = deps.lstat(claim.path)
    local matches = claim.kind == "directory" and same_identity(claim.stat, current)
      or claim.kind == "file" and same_leaf_identity(claim.stat, current)
    if not matches then
      if failures and operation then
        append_failure(failures, "cleanup", operation, nil, nil)
      end
      return nil, claim.label .. " claim changed before rollback"
    end

    local restored, restore_error, restore_code = deps.rename(claim.path, source)
    if restored ~= true or restore_error ~= nil or restore_code ~= nil then
      if failures and operation then
        append_failure(failures, "cleanup", operation, restore_error or restored, restore_code)
      end
      local primary = dependency_primary(
        "could not restore " .. claim.label .. ": ",
        restore_error or restored,
        restore_code
      )
      return nil, primary
    end
    return true
  end

  local function validate_named_claim(claim)
    local current = claim and deps.lstat(claim.path)
    if claim and claim.kind == "directory" then
      return same_identity(claim.stat, current)
    end
    return claim and same_leaf_identity(claim.stat, current) or false
  end

  local function cleanup_publication(location, created, lease, deps_for_cleanup, supplied_failures)
    assert(type(lease) == "table", "baseline cleanup lease is unavailable")
    local failures, private = adopt_failure_collector(supplied_failures)
    local cleanup_ok = true

    local function finish_cleanup(message)
      if cleanup_ok then
        return true
      end
      if private then
        local rendered = render_failures(failures)
        return nil, rendered ~= "" and rendered or message
      end
      return nil, message
    end

    local function mark_cleanup_failure(operation, err, code)
      cleanup_ok = false
      append_failure(failures, "cleanup", operation, err, code)
    end

    local function record_cleanup_absence(path, label, operation)
      local absent, absence_error = require_absent(path, deps_for_cleanup, label)
      if not absent then
        mark_cleanup_failure(operation, absence_error)
      end
    end

    local function record_cleanup_claim_absence(parent, claim, label, operation)
      record_cleanup_absence(vim.fs.joinpath(parent, claim.name), label, operation)
      record_cleanup_absence(claim.path, label, operation)
    end

    local function mark_sync_failure(operation, err, code)
      cleanup_ok = false
      append_failure(failures, "synchronization", operation, err, code)
    end

    if not location or type(created) ~= "table" then
      mark_cleanup_failure("validate-cleanup-context")
      return finish_cleanup("baseline cleanup context is unavailable")
    end

    local current_reviews = deps_for_cleanup.lstat(location.reviews)
    if not same_identity(location.reviews_stat, current_reviews) then
      mark_cleanup_failure("validate-cleanup-reviews")
      return finish_cleanup("reviews directory changed before baseline cleanup")
    end

    local owner = {}
    local anchor_error
    owner.reviews, anchor_error = open_anchored_directory(
      location.reviews,
      current_reviews,
      deps_for_cleanup,
      "reviews directory",
      failures,
      "close-cleanup-reviews",
      "cleanup",
      "open-cleanup-reviews"
    )
    if not owner.reviews then
      cleanup_ok = false
      return finish_cleanup(anchor_error)
    end

    local function finalize_cleanup()
      local objects_closed =
        close_owned(owner, "objects", deps_for_cleanup, failures, "close-cleanup-objects")
      local review_closed =
        close_owned(owner, "review", deps_for_cleanup, failures, "close-cleanup-review")
      local reviews_closed =
        close_owned(owner, "reviews", deps_for_cleanup, failures, "close-cleanup-reviews")
      if not objects_closed or not review_closed or not reviews_closed then
        cleanup_ok = false
      end
      return objects_closed and review_closed and reviews_closed
    end

    local review_name = location.review_dir:match("([^/]+)$")
    if not review_name or not review_name:match("^[0-9a-f]+$") then
      mark_cleanup_failure("validate-cleanup-review")
      finalize_cleanup()
      return finish_cleanup("baseline cleanup review id is invalid")
    end

    local review_path = vim.fs.joinpath(owner.reviews.path, review_name)
    local current_review = deps_for_cleanup.lstat(review_path)
    if not same_identity(location.review_stat, current_review) then
      mark_cleanup_failure("validate-cleanup-review")
      finalize_cleanup()
      return finish_cleanup("review directory changed before baseline cleanup")
    end

    local tombstone_path = vim.fs.joinpath(owner.reviews.path, ".cleanup-" .. review_name)
    if deps_for_cleanup.lstat(tombstone_path) then
      mark_cleanup_failure("validate-cleanup-review")
      finalize_cleanup()
      return finish_cleanup("baseline cleanup tombstone already exists")
    end

    local renamed, rename_error, rename_code = deps_for_cleanup.rename(review_path, tombstone_path)
    if renamed ~= true or rename_error ~= nil or rename_code ~= nil then
      mark_cleanup_failure("claim-cleanup-review", rename_error or renamed, rename_code)
      finalize_cleanup()
      local primary = dependency_primary(
        "could not claim failed baseline publication: ",
        rename_error or renamed,
        rename_code
      )
      return finish_cleanup(primary)
    end

    local object_claims = {}
    local manifest_claim
    local function rollback(message)
      cleanup_ok = false
      if manifest_claim and owner.review then
        restore_named_claim(owner.review, manifest_claim, failures, "restore-cleanup-manifest")
      end
      if owner.objects then
        for index = #object_claims, 1, -1 do
          restore_named_claim(
            owner.objects,
            object_claims[index],
            failures,
            "restore-cleanup-object"
          )
        end
      end

      close_owned(owner, "objects", deps_for_cleanup, failures, "close-cleanup-objects")
      close_owned(owner, "review", deps_for_cleanup, failures, "close-cleanup-review")

      if not deps_for_cleanup.lstat(review_path) and deps_for_cleanup.lstat(tombstone_path) then
        local restored, restore_error, restore_code =
          deps_for_cleanup.rename(tombstone_path, review_path)
        if restored ~= true or restore_error ~= nil or restore_code ~= nil then
          append_failure(
            failures,
            "cleanup",
            "restore-cleanup-review",
            restore_error or restored,
            restore_code
          )
        end
      else
        append_failure(failures, "cleanup", "restore-cleanup-review", nil, nil)
      end
      finalize_cleanup()
      return finish_cleanup(message)
    end

    local function rollback_failure(operation, message, err, code)
      mark_cleanup_failure(operation, err, code)
      return rollback(message)
    end

    local claimed_review = deps_for_cleanup.lstat(tombstone_path)
    if
      not same_identity(current_review, claimed_review)
      or not same_identity(location.reviews_stat, deps_for_cleanup.lstat(location.reviews))
    then
      return rollback_failure(
        "validate-cleanup-review",
        "baseline publication changed during cleanup"
      )
    end

    owner.review, anchor_error = open_anchored_directory(
      tombstone_path,
      claimed_review,
      deps_for_cleanup,
      "failed review publication",
      failures,
      "close-cleanup-review",
      "cleanup",
      "open-cleanup-review"
    )
    if not owner.review then
      cleanup_ok = false
      return rollback(anchor_error)
    end

    local review_item
    local objects_item
    local manifest_item
    local object_items = {}
    for _, item in ipairs(created) do
      if item.path == location.review_dir and item.kind == "directory" then
        review_item = item
      elseif
        item.path == vim.fs.joinpath(location.review_dir, "objects")
        and item.kind == "directory"
      then
        objects_item = item
      elseif
        item.path == vim.fs.joinpath(location.review_dir, "manifest.json")
        and item.kind == "file"
      then
        manifest_item = item
      else
        local prefix = vim.fs.joinpath(location.review_dir, "objects") .. "/"
        local name = item.path:sub(1, #prefix) == prefix and item.path:sub(#prefix + 1) or nil
        if
          item.kind ~= "file"
          or not name
          or not name:match("^[0-9a-f]+$")
          or object_items[name]
        then
          return rollback_failure(
            "validate-cleanup-context",
            "baseline publication cleanup list is invalid"
          )
        end
        object_items[name] = item
      end
    end

    if not review_item or not same_identity(review_item.stat, claimed_review) then
      return rollback_failure(
        "validate-cleanup-review",
        "failed review publication changed before cleanup"
      )
    end

    local review_entries
    local scan_error
    local scan_code
    review_entries, scan_error, scan_code = scan_directory(owner.review.path, deps_for_cleanup)
    if not review_entries then
      local primary = dependency_primary("could not scan baseline storage: ", scan_error, scan_code)
      return rollback_failure("scan-cleanup-review", primary, scan_error, scan_code)
    end

    for name, kind in pairs(review_entries) do
      if
        not (
          name == "objects" and objects_item and kind == "directory"
          or name == "manifest.json" and manifest_item and kind == "file"
        )
      then
        return rollback_failure(
          "validate-cleanup-review",
          "failed review publication contains an unexpected entry"
        )
      end
    end
    if objects_item and review_entries.objects ~= "directory" then
      return rollback_failure(
        "validate-cleanup-objects",
        "failed review publication lost its objects directory"
      )
    end
    if manifest_item and review_entries["manifest.json"] ~= "file" then
      return rollback_failure(
        "validate-cleanup-manifest",
        "failed review publication lost its manifest"
      )
    end

    local objects_path = vim.fs.joinpath(owner.review.path, "objects")
    if objects_item then
      local current_objects = deps_for_cleanup.lstat(objects_path)
      if not same_identity(objects_item.stat, current_objects) then
        return rollback_failure(
          "validate-cleanup-objects",
          "failed baseline objects directory changed before cleanup"
        )
      end
      owner.objects, anchor_error = open_anchored_directory(
        objects_path,
        current_objects,
        deps_for_cleanup,
        "failed baseline objects directory",
        failures,
        "close-cleanup-objects",
        "cleanup",
        "open-cleanup-objects"
      )
      if not owner.objects then
        cleanup_ok = false
        return rollback(anchor_error)
      end

      local object_entries
      object_entries, scan_error, scan_code = scan_directory(owner.objects.path, deps_for_cleanup)
      if not object_entries then
        local primary =
          dependency_primary("could not scan baseline storage: ", scan_error, scan_code)
        return rollback_failure("scan-cleanup-objects", primary, scan_error, scan_code)
      end

      for name, kind in pairs(object_entries) do
        local item = object_items[name]
        if
          not item
          or kind ~= "file"
          or not same_stat(
            item.stat,
            deps_for_cleanup.lstat(vim.fs.joinpath(owner.objects.path, name))
          )
        then
          return rollback_failure(
            "validate-cleanup-object",
            "failed baseline object changed before cleanup"
          )
        end
      end
      for name in pairs(object_items) do
        if object_entries[name] ~= "file" then
          return rollback_failure(
            "validate-cleanup-object",
            "failed baseline object is missing before cleanup"
          )
        end
      end
    elseif next(object_items) ~= nil then
      return rollback_failure(
        "validate-cleanup-objects",
        "failed baseline objects have no owned directory"
      )
    end

    if
      manifest_item
      and not same_stat(
        manifest_item.stat,
        deps_for_cleanup.lstat(vim.fs.joinpath(owner.review.path, "manifest.json"))
      )
    then
      return rollback_failure(
        "validate-cleanup-manifest",
        "failed baseline manifest changed before cleanup"
      )
    end

    local object_names = vim.tbl_keys(object_items)
    table.sort(object_names)
    for _, name in ipairs(object_names) do
      local claim
      local claim_error
      local claim_value
      local claim_code
      claim, claim_error, claim_value, claim_code = claim_named_entry(
        owner.objects,
        name,
        object_items[name].stat,
        ".owned-cleanup-" .. review_name .. "-" .. name,
        "file",
        "failed baseline object",
        failures,
        "restore-cleanup-object"
      )
      if not claim then
        return rollback_failure("claim-cleanup-object", claim_error, claim_value, claim_code)
      end
      table.insert(object_claims, claim)
    end

    if manifest_item then
      local claim_error
      local claim_value
      local claim_code
      manifest_claim, claim_error, claim_value, claim_code = claim_named_entry(
        owner.review,
        "manifest.json",
        manifest_item.stat,
        ".owned-cleanup-manifest-" .. review_name,
        "file",
        "failed baseline manifest",
        failures,
        "restore-cleanup-manifest"
      )
      if not manifest_claim then
        return rollback_failure("claim-cleanup-manifest", claim_error, claim_value, claim_code)
      end
    end

    for _, claim in ipairs(object_claims) do
      if not validate_named_claim(claim) then
        return rollback_failure(
          "validate-cleanup-object",
          "failed baseline object changed after it was claimed"
        )
      end
    end
    if manifest_claim and not validate_named_claim(manifest_claim) then
      return rollback_failure(
        "validate-cleanup-manifest",
        "failed baseline manifest changed after it was claimed"
      )
    end
    if
      not same_identity(location.reviews_stat, deps_for_cleanup.lstat(location.reviews))
      or not same_identity(claimed_review, deps_for_cleanup.lstat(tombstone_path))
    then
      return rollback_failure(
        "validate-cleanup-review",
        "baseline publication changed during cleanup"
      )
    end

    local function fail_after_delete(operation, message, err, code)
      mark_cleanup_failure(operation, err, code)
      finalize_cleanup()
      return finish_cleanup(message)
    end

    if owner.objects then
      for _, claim in ipairs(object_claims) do
        local removed, remove_error, remove_code = deps_for_cleanup.unlink(claim.path)
        if removed ~= true or remove_error ~= nil or remove_code ~= nil then
          local primary = dependency_primary(
            "could not clean failed baseline object: ",
            remove_error or removed,
            remove_code
          )
          return fail_after_delete(
            "unlink-cleanup-object",
            primary,
            remove_error or removed,
            remove_code
          )
        end
        record_cleanup_claim_absence(
          owner.objects.path,
          claim,
          "failed baseline object",
          "verify-cleanup-object-absent"
        )
      end

      local synced, sync_error, sync_code = deps_for_cleanup.fsync(owner.objects.fd)
      if synced ~= true or sync_error ~= nil or sync_code ~= nil then
        mark_sync_failure("fsync-cleanup-objects", sync_error or synced, sync_code)
      end

      local object_dir_claim
      local directory_claim_error
      local claim_value
      local claim_code
      object_dir_claim, directory_claim_error, claim_value, claim_code = claim_named_entry(
        owner.review,
        "objects",
        objects_item.stat,
        ".owned-cleanup-objects-" .. review_name,
        "directory",
        "failed baseline objects directory",
        failures,
        "restore-cleanup-object"
      )
      if not object_dir_claim then
        return fail_after_delete(
          "claim-cleanup-objects",
          directory_claim_error,
          claim_value,
          claim_code
        )
      end
      if not validate_named_claim(object_dir_claim) then
        return fail_after_delete(
          "validate-cleanup-objects",
          "failed baseline objects directory changed after it was claimed"
        )
      end

      local removed, remove_error, remove_code = deps_for_cleanup.rmdir(object_dir_claim.path)
      if removed ~= true or remove_error ~= nil or remove_code ~= nil then
        local primary = dependency_primary(
          "could not clean failed baseline objects directory: ",
          remove_error or removed,
          remove_code
        )
        return fail_after_delete(
          "rmdir-cleanup-objects",
          primary,
          remove_error or removed,
          remove_code
        )
      end
      record_cleanup_claim_absence(
        owner.review.path,
        object_dir_claim,
        "failed baseline objects directory",
        "verify-cleanup-objects-absent"
      )
      if not close_owned(owner, "objects", deps_for_cleanup, failures, "close-cleanup-objects") then
        cleanup_ok = false
      end
    end

    if manifest_claim then
      local removed, remove_error, remove_code = deps_for_cleanup.unlink(manifest_claim.path)
      if removed ~= true or remove_error ~= nil or remove_code ~= nil then
        local primary = dependency_primary(
          "could not clean failed baseline manifest: ",
          remove_error or removed,
          remove_code
        )
        return fail_after_delete(
          "unlink-cleanup-manifest",
          primary,
          remove_error or removed,
          remove_code
        )
      end
      record_cleanup_claim_absence(
        owner.review.path,
        manifest_claim,
        "failed baseline manifest",
        "verify-cleanup-manifest-absent"
      )
    end

    local synced, sync_error, sync_code = deps_for_cleanup.fsync(owner.review.fd)
    if synced ~= true or sync_error ~= nil or sync_code ~= nil then
      mark_sync_failure("fsync-cleanup-review", sync_error or synced, sync_code)
    end

    local review_dir_claim
    local directory_claim_error
    local claim_value
    local claim_code
    review_dir_claim, directory_claim_error, claim_value, claim_code = claim_named_entry(
      owner.reviews,
      ".cleanup-" .. review_name,
      claimed_review,
      ".owned-cleanup-review-" .. review_name,
      "directory",
      "failed review publication",
      failures,
      "restore-cleanup-review"
    )
    if not review_dir_claim then
      return fail_after_delete(
        "claim-owned-cleanup-review",
        directory_claim_error,
        claim_value,
        claim_code
      )
    end
    if not validate_named_claim(review_dir_claim) then
      return fail_after_delete(
        "validate-cleanup-review",
        "failed review publication changed after it was claimed"
      )
    end

    local removed, remove_error, remove_code = deps_for_cleanup.rmdir(review_dir_claim.path)
    if removed ~= true or remove_error ~= nil or remove_code ~= nil then
      local primary, detail = dependency_primary(
        "could not clean failed review publication: ",
        remove_error or removed,
        remove_code,
        "cleanup_review_rmdir"
      )
      if detail then
        set_compatibility_detail(failures, "cleanup_review_rmdir", detail)
      end
      return fail_after_delete(
        "rmdir-cleanup-review",
        primary,
        remove_error or removed,
        remove_code
      )
    end
    record_cleanup_absence(review_path, "failed review publication", "verify-cleanup-review-absent")
    record_cleanup_absence(
      vim.fs.joinpath(owner.reviews.path, ".publishing-" .. review_name),
      "failed review publication",
      "verify-cleanup-review-absent"
    )
    record_cleanup_claim_absence(
      owner.reviews.path,
      review_dir_claim,
      "failed review publication",
      "verify-cleanup-review-absent"
    )

    if not close_owned(owner, "review", deps_for_cleanup, failures, "close-cleanup-review") then
      cleanup_ok = false
    end

    synced, sync_error, sync_code = deps_for_cleanup.fsync(owner.reviews.fd)
    if synced ~= true or sync_error ~= nil or sync_code ~= nil then
      mark_sync_failure("fsync-cleanup-reviews", sync_error or synced, sync_code)
    end

    if not close_owned(owner, "reviews", deps_for_cleanup, failures, "close-cleanup-reviews") then
      cleanup_ok = false
    end
    return finish_cleanup()
  end

  local function publish(
    identity,
    store,
    review_id,
    captured,
    lease,
    expected_state,
    supplied_failures
  )
    local failures, private = adopt_failure_collector(supplied_failures)

    local function failed(primary)
      set_primary_failure(failures, primary)
      if private then
        return nil, render_failures(failures)
      end
      return nil, primary
    end

    local location, location_error = state_location(store, review_id, true, expected_state)
    if not location then
      return failed(location_error)
    end

    local current_reviews = deps.lstat(location.reviews)
    if not same_identity(location.reviews_stat, current_reviews) then
      return failed("reviews directory changed before baseline publication")
    end

    local owner = {}
    local anchor_error
    owner.reviews, anchor_error = open_anchored_directory(
      location.reviews,
      current_reviews,
      deps,
      "reviews directory",
      failures,
      "close-publication-reviews"
    )
    if not owner.reviews then
      return failed(anchor_error)
    end

    local function close_publication_anchors()
      local objects_closed =
        close_owned(owner, "objects", deps, failures, "close-publication-objects")
      local review_closed = close_owned(owner, "review", deps, failures, "close-publication-review")
      return objects_closed and review_closed
    end

    local function close_publication_reviews()
      return close_owned(owner, "reviews", deps, failures, "close-publication-reviews")
    end

    local review_name = review_id
    local staging_name = ".publishing-" .. review_id
    local review_claim
    local claim_error
    review_claim, claim_error = claim_named_entry(
      owner.reviews,
      review_name,
      location.review_stat,
      staging_name,
      "directory",
      "review directory",
      failures,
      "restore-publication-review"
    )
    if not review_claim then
      set_primary_failure(failures, claim_error)
      close_publication_reviews()
      return failed(claim_error)
    end

    owner.review, anchor_error = open_anchored_directory(
      review_claim.path,
      review_claim.stat,
      deps,
      "publication directory",
      failures,
      "close-publication-review"
    )
    if not owner.review then
      restore_named_claim(owner.reviews, review_claim, failures, "restore-publication-review")
      close_publication_reviews()
      return failed(anchor_error)
    end

    local created = {
      {
        kind = "directory",
        path = location.review_dir,
        stat = review_claim.stat,
      },
    }
    local published_final = false

    local function fail_publication(primary)
      set_primary_failure(failures, primary)
      close_publication_anchors()

      local restoration_ok = true
      local final_parent = owner.reviews and owner.reviews.path or location.reviews
      local final_path = vim.fs.joinpath(final_parent, review_name)
      if published_final then
        location.review_stat = deps.lstat(final_path)
        created[1].stat = location.review_stat
      elseif deps.lstat(final_path) or not validate_named_claim(review_claim) then
        restoration_ok = false
        append_failure(failures, "cleanup", "restore-publication-review", nil, nil)
      else
        local restored, restore_error, restore_code = deps.rename(review_claim.path, final_path)
        if restored ~= true or restore_error ~= nil or restore_code ~= nil then
          restoration_ok = false
          append_failure(
            failures,
            "cleanup",
            "restore-publication-review",
            restore_error or restored,
            restore_code
          )
        else
          location.review_stat = deps.lstat(final_path)
          created[1].stat = location.review_stat
        end
      end

      close_publication_reviews()
      if restoration_ok then
        cleanup_publication(location, created, lease, deps, failures)
      end

      if private then
        return nil, render_failures(failures)
      end
      return nil, primary
    end

    local objects_dir = vim.fs.joinpath(owner.review.path, "objects")
    local logical_objects_dir = vim.fs.joinpath(location.review_dir, "objects")
    local made, mkdir_error, mkdir_code = deps.mkdir(objects_dir, DIRECTORY_MODE)
    if made ~= true or mkdir_error ~= nil or mkdir_code ~= nil then
      local primary = dependency_primary(
        "could not create baseline objects directory: ",
        mkdir_error or made,
        mkdir_code
      )
      return fail_publication(primary)
    end

    local objects_stat = deps.lstat(objects_dir)
    table.insert(created, {
      kind = "directory",
      path = logical_objects_dir,
      stat = objects_stat,
    })
    owner.objects, anchor_error = open_anchored_directory(
      objects_dir,
      objects_stat,
      deps,
      "baseline objects directory",
      failures,
      "close-publication-objects"
    )
    if not owner.objects then
      return fail_publication(anchor_error)
    end

    local object_bytes = {}
    for path, item in pairs(captured.paths) do
      local name = item.object.storage and item.object.storage:match("^copy:([0-9a-f]+)$")
      if name then
        local bytes = captured.bytes[path]
        if type(bytes) ~= "string" or deps.hash(bytes) ~= name then
          return fail_publication("copied baseline object is inconsistent")
        end
        if object_bytes[name] and object_bytes[name] ~= bytes then
          return fail_publication("copied baseline object hash collided")
        end
        object_bytes[name] = bytes
      end
    end

    local names = vim.tbl_keys(object_bytes)
    table.sort(names)
    for _, name in ipairs(names) do
      local path = vim.fs.joinpath(owner.objects.path, name)
      local logical_path = vim.fs.joinpath(logical_objects_dir, name)
      local written
      local write_error
      local written_stat
      written, write_error, written_stat = write_new_file(path, object_bytes[name], deps, failures)
      if written_stat then
        table.insert(created, {
          kind = "file",
          path = logical_path,
          stat = written_stat,
        })
      end
      if not written then
        return fail_publication(write_error)
      end
    end

    local synced, sync_error, sync_code = deps.fsync(owner.objects.fd)
    if synced ~= true or sync_error ~= nil or sync_code ~= nil then
      local primary = "could not fsync private baseline directory"
      set_primary_failure(failures, primary)
      append_failure(
        failures,
        "synchronization",
        "fsync-publication-objects",
        sync_error or synced,
        sync_code
      )
      return fail_publication(primary)
    end

    local manifest = manifest_from_capture(identity, review_id, captured)
    local manifest_bytes = canonical_json(manifest)
    local manifest_path = vim.fs.joinpath(owner.review.path, "manifest.json")
    local logical_manifest_path = vim.fs.joinpath(location.review_dir, "manifest.json")
    local written
    local write_error
    local manifest_stat
    written, write_error, manifest_stat = write_new_file(
      manifest_path,
      manifest_bytes,
      deps,
      failures,
      "could not create private baseline file: manifest open failure: "
    )
    if manifest_stat then
      table.insert(created, {
        kind = "file",
        path = logical_manifest_path,
        stat = manifest_stat,
      })
    end
    if not written then
      return fail_publication(write_error)
    end

    synced, sync_error, sync_code = deps.fsync(owner.review.fd)
    if synced ~= true or sync_error ~= nil or sync_code ~= nil then
      local primary = "could not fsync private baseline directory"
      set_primary_failure(failures, primary)
      append_failure(
        failures,
        "synchronization",
        "fsync-publication-review",
        sync_error or synced,
        sync_code
      )
      return fail_publication(primary)
    end

    if not close_publication_anchors() then
      return fail_publication("could not close baseline publication directories")
    end

    local final_path = vim.fs.joinpath(owner.reviews.path, review_name)
    if deps.lstat(final_path) or not validate_named_claim(review_claim) then
      return fail_publication("review directory changed before baseline publication completed")
    end

    local finalized, finalize_error, finalize_code = deps.rename(review_claim.path, final_path)
    if finalized ~= true or finalize_error ~= nil or finalize_code ~= nil then
      local primary = dependency_primary(
        "could not publish baseline review directory: ",
        finalize_error or finalized,
        finalize_code
      )
      return fail_publication(primary)
    end

    local final_stat = deps.lstat(final_path)
    if not same_identity(review_claim.stat, final_stat) then
      published_final = true
      review_claim.path = final_path
      return fail_publication("review directory changed while baseline publication completed")
    end
    published_final = true
    review_claim.path = final_path

    synced, sync_error, sync_code = deps.fsync(owner.reviews.fd)
    if synced ~= true or sync_error ~= nil or sync_code ~= nil then
      local primary = "could not fsync reviews directory"
      set_primary_failure(failures, primary)
      append_failure(
        failures,
        "synchronization",
        "fsync-publication-reviews",
        sync_error or synced,
        sync_code
      )
      return fail_publication(primary)
    end

    local current_logical_reviews = deps.lstat(location.reviews)
    if not same_identity(location.reviews_stat, current_logical_reviews) then
      return fail_publication("reviews directory changed while baseline publication completed")
    end
    location.reviews_stat = current_logical_reviews
    location.review_stat = final_stat
    created[1].stat = final_stat

    if not close_publication_reviews() then
      local primary = "could not close reviews directory after baseline publication"
      set_primary_failure(failures, primary)
      cleanup_publication(location, created, lease, deps, failures)
      if private then
        return nil, render_failures(failures)
      end
      return nil, primary
    end

    return {
      manifest = manifest,
      location = location,
      created = created,
    }
  end

  local function validate_object(value, allow_storage)
    if type(value) ~= "table" then
      return nil, "baseline object is invalid"
    end
    for key in pairs(value) do
      if
        key ~= "kind"
        and key ~= "mode"
        and key ~= "size"
        and key ~= "sha256"
        and key ~= "storage"
        and key ~= "tree_oid"
      then
        return nil, "baseline object has an unknown field"
      end
    end
    if value.kind == "absent" or value.kind == "unsupported" then
      if
        value.mode ~= nil
        or value.size ~= 0
        or value.sha256 ~= nil
        or value.storage ~= nil
        or value.tree_oid ~= nil
      then
        return nil, "baseline absent or unsupported object is invalid"
      end
      return exact_object(value.kind, nil, 0, nil, nil, nil)
    end
    if value.kind ~= "regular" and value.kind ~= "symlink" then
      return nil, "baseline object kind is invalid"
    end
    local valid_mode = value.kind == "regular"
        and (value.mode == "100644" or value.mode == "100755")
      or value.kind == "symlink" and value.mode == "120000"
    if
      not valid_mode
      or type(value.size) ~= "number"
      or value.size < 0
      or value.size % 1 ~= 0
      or type(value.sha256) ~= "string"
      or #value.sha256 ~= 64
      or not value.sha256:match("^[0-9a-f]+$")
    then
      return nil, "baseline object fingerprint is invalid"
    end
    if not allow_storage then
      if value.storage ~= nil or value.tree_oid ~= nil then
        return nil, "ignored fingerprint retains object storage"
      end
      return exact_object(value.kind, value.mode, value.size, value.sha256, nil, nil)
    end
    if type(value.storage) ~= "string" then
      return nil, "baseline object storage is invalid"
    end
    local copy_name = value.storage:match("^copy:([0-9a-f]+)$")
    local tree_oid = value.storage:match("^tree:([0-9a-f]+)$")
    if copy_name then
      if copy_name ~= value.sha256 or value.tree_oid ~= nil then
        return nil, "copied baseline object storage is invalid"
      end
    elseif tree_oid then
      if not valid_oid(tree_oid) or value.tree_oid ~= tree_oid then
        return nil, "tree baseline object storage is invalid"
      end
    else
      return nil, "baseline object storage is invalid"
    end
    return exact_object(
      value.kind,
      value.mode,
      value.size,
      value.sha256,
      value.storage,
      value.tree_oid
    )
  end

  local function load(identity, store, review_id, failures)
    local function scan(path)
      local entries, scan_error, scan_code = scan_directory(path, deps)
      if entries then
        return entries
      end

      local primary, detail = dependency_primary(
        "could not scan baseline storage: ",
        scan_error,
        scan_code,
        "transaction_load_scan"
      )
      if failures then
        set_primary_failure(failures, primary)
        if detail then
          set_compatibility_detail(failures, "transaction_load_scan", detail)
        end
      end
      return nil, primary
    end

    local function perform_load()
      if type(review_id) ~= "string" or #review_id ~= 32 or not review_id:match("^[0-9a-f]+$") then
        return nil, "review id is invalid"
      end
      local location, location_error = state_location(store, review_id, false)
      if not location then
        return nil, location_error
      end
      local entries, scan_error = scan(location.review_dir)
      if not entries then
        return nil, scan_error
      end
      if entries["manifest.json"] ~= "file" or entries.objects ~= "directory" then
        return nil, "baseline storage is incomplete"
      end
      for name in pairs(entries) do
        if name ~= "manifest.json" and name ~= "objects" then
          return nil, "baseline storage contains an unexpected entry"
        end
      end

      local manifest_path = vim.fs.joinpath(location.review_dir, "manifest.json")
      local manifest_stat, manifest_stat_error =
        validate_private_file(manifest_path, location.uid, deps, "baseline manifest")
      if not manifest_stat then
        return nil, manifest_stat_error
      end
      local manifest_bytes, manifest_read_error = read_bounded_file(
        manifest_path,
        manifest_stat,
        MAX_MANIFEST_BYTES,
        deps,
        "baseline manifest",
        failures
      )
      if not manifest_bytes then
        return nil, manifest_read_error
      end
      local decoded, manifest =
        pcall(vim.json.decode, manifest_bytes, { luanil = { object = true, array = true } })
      if not decoded or type(manifest) ~= "table" then
        return nil, "baseline manifest is not valid JSON"
      end
      local manifest_keys = {
        schema = true,
        review_id = true,
        identity_key = true,
        root_hex = true,
        inside_git = true,
        conflict_only = true,
        tree_oid = true,
        paths = true,
        ignored = true,
        baseline_hash = true,
      }
      local required_manifest_keys = clone(manifest_keys)
      required_manifest_keys.tree_oid = nil
      if
        not exact_keys(manifest, manifest_keys, required_manifest_keys)
        or manifest.schema ~= SCHEMA
        or manifest.review_id ~= review_id
        or manifest.identity_key ~= identity.key
        or decode_hex(manifest.root_hex) ~= identity.root
        or manifest.inside_git ~= identity.inside_git
        or manifest.conflict_only ~= not identity.inside_git
        or not is_array(manifest.paths)
        or not is_array(manifest.ignored)
        or type(manifest.baseline_hash) ~= "string"
        or #manifest.baseline_hash ~= 64
        or not manifest.baseline_hash:match("^[0-9a-f]+$")
        or (manifest.tree_oid ~= nil and not valid_oid(manifest.tree_oid))
        or (not identity.inside_git and manifest.tree_oid ~= nil)
      then
        return nil, "baseline manifest schema or identity is invalid"
      end
      local hash_input = clone(manifest)
      hash_input.baseline_hash = nil
      local encoded_ok, expected_hash = pcall(function()
        return deps.hash(canonical_json(hash_input))
      end)
      if not encoded_ok or expected_hash ~= manifest.baseline_hash then
        return nil, "baseline manifest hash is invalid"
      end
      local canonical_ok, canonical_bytes = pcall(canonical_json, manifest)
      if not canonical_ok or canonical_bytes ~= manifest_bytes then
        return nil, "baseline manifest is not canonically encoded"
      end

      local paths = {}
      local ignored = {}
      local copied = {}
      local tree_bytes = {}
      local tree_objects = {}
      local seen_paths = {}
      local previous
      for _, item in ipairs(manifest.paths) do
        if
          not exact_keys(item, { path_hex = true, object = true })
          or type(item.path_hex) ~= "string"
        then
          return nil, "baseline manifest path record is invalid"
        end
        local path = decode_hex(item.path_hex)
        local valid, path_error = validate_relative(path)
        if not valid then
          return nil, path_error
        end
        if previous and not (previous < path) then
          return nil, "baseline manifest paths are not uniquely sorted"
        end
        previous = path
        seen_paths[path] = true
        local object, object_error = validate_object(item.object, true)
        if not object then
          return nil, object_error
        end
        paths[path] = object
        local copy_name = object.storage and object.storage:match("^copy:([0-9a-f]+)$")
        if copy_name then
          copied[copy_name] = object
        elseif object.tree_oid then
          if not manifest.tree_oid then
            return nil, "tree baseline object has no captured tree"
          end
          tree_objects[object.tree_oid] = true
        end
        review_task.checkpoint()
      end
      local blobs, tree_error = read_tree_objects(identity, tree_objects)
      if not blobs then
        return nil, tree_error
      end
      for path, object in pairs(paths) do
        if object.tree_oid then
          local bytes = blobs[object.tree_oid]
          if
            type(bytes) ~= "string"
            or #bytes ~= object.size
            or deps.hash(bytes) ~= object.sha256
          then
            return nil, "tree baseline object fingerprint is invalid"
          end
          tree_bytes[path] = bytes
        end
        review_task.checkpoint()
      end
      previous = nil
      for _, item in ipairs(manifest.ignored) do
        if
          not exact_keys(item, { path_hex = true, fingerprint = true })
          or type(item.path_hex) ~= "string"
        then
          return nil, "baseline ignored record is invalid"
        end
        local path = decode_hex(item.path_hex)
        local valid, path_error = validate_relative(path)
        if not valid then
          return nil, path_error
        end
        if previous and not (previous < path) then
          return nil, "baseline ignored paths are not uniquely sorted"
        end
        if seen_paths[path] then
          return nil, "baseline path is both visible and ignored"
        end
        previous = path
        local object, object_error = validate_object(item.fingerprint, false)
        if not object then
          return nil, object_error
        end
        ignored[path] = object
      end

      local objects_dir = vim.fs.joinpath(location.review_dir, "objects")
      local objects_stat, objects_error =
        validate_private_directory(objects_dir, location.uid, deps, "baseline objects directory")
      if not objects_stat then
        return nil, objects_error
      end
      local object_entries
      object_entries, scan_error = scan(objects_dir)
      if not object_entries then
        return nil, scan_error
      end
      for name, kind in pairs(object_entries) do
        if copied[name] and kind ~= "file" then
          return nil, "copied object is not a mode 0600 nonsymlink file"
        end
        if not copied[name] then
          return nil, "baseline objects directory contains an unexpected entry"
        end
      end
      local copied_bytes = {}
      local copied_stats = {}
      for name, expected in pairs(copied) do
        local path = vim.fs.joinpath(objects_dir, name)
        local stat, stat_error = validate_private_file(path, location.uid, deps, "copied object")
        if not stat then
          return nil, stat_error
        end
        local bytes, read_error =
          read_bounded_file(path, stat, MAX_FILE_BYTES, deps, "copied object", failures)
        if not bytes then
          return nil, read_error
        end
        if #bytes ~= expected.size or deps.hash(bytes) ~= expected.sha256 then
          return nil, "copied object fingerprint is invalid"
        end
        copied_bytes[name] = bytes
        copied_stats[name] = stat
        review_task.checkpoint()
      end

      local opened = {
        location = location,
        manifest = manifest,
        manifest_stat = manifest_stat,
        objects_stat = objects_stat,
        paths = paths,
        ignored = ignored,
        copied_bytes = copied_bytes,
        copied_stats = copied_stats,
        tree_bytes = tree_bytes,
      }
      return opened
    end

    local opened, load_error = perform_load()
    if not opened and failures then
      set_primary_failure(failures, load_error)
    end
    return opened, load_error
  end

  local finish_remove

  local function baseline_object(identity, store, opened)
    local baseline = {}

    function baseline:id()
      return opened.manifest.review_id
    end

    function baseline:manifest()
      return clone(opened.manifest)
    end

    function baseline:read(path)
      local value = opened.paths[path]
      return value and clone(value) or nil
    end

    function baseline:fingerprint(path)
      return self:read(path)
    end

    function baseline:ignored_fingerprint(path)
      local value = opened.ignored[path]
      return value and clone(value) or nil
    end

    function baseline:bytes(path)
      local object = opened.paths[path]
      if not object or object.kind == "absent" or object.kind == "unsupported" then
        return nil
      end
      local copy_name = object.storage and object.storage:match("^copy:([0-9a-f]+)$")
      if copy_name then
        return opened.copied_bytes[copy_name]
      end
      return opened.tree_bytes[path]
    end

    local function remove_under_lease(lease, expected_state, failures)
      local function fail(primary, compatibility_kind, compatibility_detail)
        set_primary_failure(failures, primary)
        if compatibility_kind and compatibility_detail then
          set_compatibility_detail(failures, compatibility_kind, compatibility_detail)
        end
        return nil, primary
      end

      local absence_primary

      local function record_removal_absence(path, label)
        local absent, absence_error = require_absent(path, deps, label)
        if not absent and absence_primary == nil then
          absence_primary = absence_error
          set_primary_failure(failures, absence_error)
        end
      end

      local function record_removal_claim_absence(parent, claim, label)
        record_removal_absence(vim.fs.joinpath(parent, claim.name), label)
        record_removal_absence(claim.path, label)
      end

      local review_name = opened.manifest.review_id
      local location = state_location(store, review_name, false, expected_state)
      if not location then
        return fail("baseline storage changed before removal")
      end

      local current_manifest = deps.lstat(vim.fs.joinpath(location.review_dir, "manifest.json"))
      local current_objects = deps.lstat(vim.fs.joinpath(location.review_dir, "objects"))
      if
        not same_identity(opened.location.reviews_stat, location.reviews_stat)
        or not same_identity(opened.location.review_stat, location.review_stat)
        or not same_leaf_identity(opened.manifest_stat, current_manifest)
        or not same_identity(opened.objects_stat, current_objects)
        or not same_stat(location.reviews_stat, deps.lstat(location.reviews))
      then
        return fail("baseline storage changed before removal")
      end

      local owner = {}

      local function close_removal(key, operation)
        return close_owned(owner, key, deps, failures, operation)
      end

      local function finalize_removal()
        local objects_closed = close_removal("objects", "close-removal-objects")
        local review_closed = close_removal("review", "close-removal-review")
        local reviews_closed = close_removal("reviews", "close-removal-reviews")
        return objects_closed and review_closed and reviews_closed
      end

      local function fail_and_finalize(primary)
        fail(primary)
        finalize_removal()
        return nil, primary
      end

      local function synchronize(key, operation)
        local anchor = owner[key]
        if not anchor then
          return true
        end
        local synced, sync_error, sync_code = deps.fsync(anchor.fd)
        if synced ~= true or sync_error ~= nil or sync_code ~= nil then
          append_failure(failures, "synchronization", operation, sync_error or synced, sync_code)
          return false
        end
        return true
      end

      local anchor_error
      owner.reviews, anchor_error = open_anchored_directory(
        location.reviews,
        location.reviews_stat,
        deps,
        "reviews directory",
        failures,
        "close-removal-reviews"
      )
      if not owner.reviews then
        return fail(anchor_error)
      end

      local review_path = vim.fs.joinpath(owner.reviews.path, review_name)
      local current_review = deps.lstat(review_path)
      if not same_stat(location.review_stat, current_review) then
        return fail_and_finalize(
          "baseline storage changed before removal (anchored review mismatch)"
        )
      end

      local tombstone_name = ".removing-" .. review_name
      local tombstone_path = vim.fs.joinpath(owner.reviews.path, tombstone_name)
      if deps.lstat(tombstone_path) then
        return fail_and_finalize("baseline removal tombstone already exists")
      end

      local review_claim
      local claim_error
      review_claim, claim_error = claim_named_entry(
        owner.reviews,
        review_name,
        current_review,
        tombstone_name,
        "directory",
        "baseline review directory",
        failures,
        "restore-removal-review",
        "baseline storage changed during removal"
      )
      if not review_claim then
        if not same_identity(location.reviews_stat, deps.lstat(location.reviews)) then
          claim_error = "baseline storage changed during removal"
        end
        return fail_and_finalize(claim_error)
      end
      local claimed_review = review_claim.stat

      local function rollback(primary)
        fail(primary)
        close_removal("objects", "close-removal-objects")
        close_removal("review", "close-removal-review")
        restore_named_claim(owner.reviews, review_claim, failures, "restore-removal-review")
        close_removal("reviews", "close-removal-reviews")
        return nil, primary
      end

      if not same_identity(location.reviews_stat, deps.lstat(location.reviews)) then
        return rollback("baseline storage changed during removal")
      end

      owner.review, anchor_error = open_anchored_directory(
        review_claim.path,
        claimed_review,
        deps,
        "claimed review directory",
        failures,
        "close-removal-review"
      )
      if not owner.review then
        return rollback(anchor_error)
      end

      local objects_path = vim.fs.joinpath(owner.review.path, "objects")
      owner.objects, anchor_error = open_anchored_directory(
        objects_path,
        current_objects,
        deps,
        "baseline objects directory",
        failures,
        "close-removal-objects"
      )
      if not owner.objects then
        return rollback(anchor_error)
      end

      local entries
      local scan_error
      local scan_code
      entries, scan_error, scan_code = scan_directory(owner.review.path, deps)
      if not entries then
        local primary =
          dependency_primary("could not scan baseline storage: ", scan_error, scan_code)
        return rollback(primary)
      end
      if entries["manifest.json"] ~= "file" or entries.objects ~= "directory" then
        return rollback("baseline storage changed during removal")
      end
      for name in pairs(entries) do
        if name ~= "manifest.json" and name ~= "objects" then
          return rollback("baseline storage changed during removal")
        end
      end

      local object_entries
      object_entries, scan_error, scan_code = scan_directory(owner.objects.path, deps)
      if not object_entries then
        local primary =
          dependency_primary("could not scan baseline storage: ", scan_error, scan_code)
        return rollback(primary)
      end
      for name, stat in pairs(opened.copied_stats) do
        local anchored_object = vim.fs.joinpath(owner.objects.path, name)
        if object_entries[name] ~= "file" or not same_stat(stat, deps.lstat(anchored_object)) then
          return rollback("baseline copied object changed during removal")
        end
      end
      for name in pairs(object_entries) do
        if not opened.copied_stats[name] then
          return rollback("baseline storage changed during removal")
        end
      end

      if
        not same_stat(
          current_manifest,
          deps.lstat(vim.fs.joinpath(owner.review.path, "manifest.json"))
        )
        or not same_identity(location.reviews_stat, deps.lstat(location.reviews))
        or not same_stat(claimed_review, deps.lstat(review_claim.path))
      then
        return rollback("baseline storage changed during removal")
      end

      local object_claims = {}
      local manifest_claim

      local function rollback_leaf_claims(primary)
        fail(primary)
        if manifest_claim then
          restore_named_claim(owner.review, manifest_claim, failures, "restore-removal-manifest")
        end
        for index = #object_claims, 1, -1 do
          restore_named_claim(
            owner.objects,
            object_claims[index],
            failures,
            "restore-removal-object"
          )
        end
        return rollback(primary)
      end

      local object_names = vim.tbl_keys(opened.copied_stats)
      table.sort(object_names)
      for _, name in ipairs(object_names) do
        local claim
        claim, claim_error = claim_named_entry(
          owner.objects,
          name,
          opened.copied_stats[name],
          ".owned-" .. review_name .. "-" .. name,
          "file",
          "baseline copied object",
          failures,
          "restore-removal-object"
        )
        if not claim then
          return rollback_leaf_claims(claim_error)
        end
        table.insert(object_claims, claim)
      end

      manifest_claim, anchor_error = claim_named_entry(
        owner.review,
        "manifest.json",
        current_manifest,
        ".owned-manifest-" .. review_name,
        "file",
        "baseline manifest",
        failures,
        "restore-removal-manifest"
      )
      if not manifest_claim then
        return rollback_leaf_claims(anchor_error)
      end

      for _, claim in ipairs(object_claims) do
        if not validate_named_claim(claim) then
          return rollback_leaf_claims("baseline copied object changed after it was claimed")
        end
      end
      if
        not validate_named_claim(manifest_claim)
        or not same_identity(location.reviews_stat, deps.lstat(location.reviews))
        or not same_identity(claimed_review, deps.lstat(review_claim.path))
      then
        return rollback_leaf_claims("baseline storage changed after its leaves were claimed")
      end

      local function irreversible_failure(primary, compatibility_kind, compatibility_detail)
        fail(primary, compatibility_kind, compatibility_detail)
        finalize_removal()
        return nil, primary
      end

      for _, claim in ipairs(object_claims) do
        local removed, remove_error, remove_code = deps.unlink(claim.path)
        if removed ~= true or remove_error ~= nil or remove_code ~= nil then
          local primary = dependency_primary(
            "could not remove copied baseline object: ",
            remove_error or removed,
            remove_code
          )
          return irreversible_failure(primary)
        end
        record_removal_claim_absence(owner.objects.path, claim, "copied baseline object")
      end

      local removed, remove_error, remove_code = deps.unlink(manifest_claim.path)
      if removed ~= true or remove_error ~= nil or remove_code ~= nil then
        local primary = dependency_primary(
          "could not remove baseline manifest: ",
          remove_error or removed,
          remove_code
        )
        return irreversible_failure(primary)
      end
      record_removal_claim_absence(owner.review.path, manifest_claim, "baseline manifest")

      synchronize("objects", "fsync-removal-objects")

      local object_dir_claim
      object_dir_claim, claim_error = claim_named_entry(
        owner.review,
        "objects",
        current_objects,
        ".owned-removing-objects-" .. review_name,
        "directory",
        "baseline objects directory",
        failures,
        "restore-removal-object"
      )
      if not object_dir_claim then
        return irreversible_failure(claim_error)
      end
      if not validate_named_claim(object_dir_claim) then
        return irreversible_failure("baseline objects directory changed after it was claimed")
      end

      removed, remove_error, remove_code = deps.rmdir(object_dir_claim.path)
      if removed ~= true or remove_error ~= nil or remove_code ~= nil then
        local primary = dependency_primary(
          "could not remove baseline objects directory: ",
          remove_error or removed,
          remove_code
        )
        return irreversible_failure(primary)
      end
      record_removal_claim_absence(
        owner.review.path,
        object_dir_claim,
        "baseline objects directory"
      )
      close_removal("objects", "close-removal-objects")

      synchronize("review", "fsync-removal-review")

      local review_dir_claim
      review_dir_claim, claim_error = claim_named_entry(
        owner.reviews,
        tombstone_name,
        claimed_review,
        ".owned-removing-review-" .. review_name,
        "directory",
        "baseline review directory",
        failures,
        "restore-removal-review"
      )
      if not review_dir_claim then
        return irreversible_failure(claim_error)
      end
      if not validate_named_claim(review_dir_claim) then
        return irreversible_failure("baseline review directory changed after it was claimed")
      end

      removed, remove_error, remove_code = deps.rmdir(review_dir_claim.path)
      if removed ~= true or remove_error ~= nil or remove_code ~= nil then
        local primary, detail = dependency_primary(
          "could not remove baseline review directory: ",
          remove_error or removed,
          remove_code,
          "removal_review_rmdir"
        )
        return irreversible_failure(primary, detail and "removal_review_rmdir" or nil, detail)
      end
      record_removal_absence(review_path, "baseline review directory")
      record_removal_absence(
        vim.fs.joinpath(owner.reviews.path, ".publishing-" .. review_name),
        "baseline review directory"
      )
      record_removal_claim_absence(
        owner.reviews.path,
        review_dir_claim,
        "baseline review directory"
      )
      close_removal("review", "close-removal-review")

      synchronize("reviews", "fsync-removal-reviews")
      finalize_removal()
      if absence_primary then
        return nil, absence_primary
      end
      return true
    end

    function baseline:remove()
      local expected_state, state_error = state_root_location(store)
      if not expected_state then
        return nil, state_error
      end
      local lease, serialization_error = deps.serialization.acquire(expected_state.path, deps)
      if not lease then
        return nil, serialization_error
      end

      local failures = new_failure_collector(nil)
      local removed, remove_error = remove_under_lease(lease, expected_state, failures)
      return finish_remove(lease, removed, remove_error, failures)
    end

    return baseline
  end

  local function create_under_lease(
    identity,
    store,
    review_id,
    captured,
    lease,
    expected_state,
    failures
  )
    local published, publication_error =
      publish(identity, store, review_id, captured, lease, expected_state, failures)
    if not published then
      set_primary_failure(failures, publication_error)
      return nil, publication_error
    end

    if identity.inside_git then
      local stable, stability_error = verify_git_capture(identity, captured, failures)
      if not stable then
        set_primary_failure(failures, stability_error)
        cleanup_publication(published.location, published.created, lease, deps, failures)
        return nil, stability_error
      end
    end

    local opened, open_error = load(identity, store, review_id, failures)
    if not opened then
      set_primary_failure(failures, open_error)
      cleanup_publication(published.location, published.created, lease, deps, failures)
      return nil, open_error
    end
    return baseline_object(identity, store, opened)
  end

  local invalid_release_error = "baseline serialization release failed: validate-lock (UNKNOWN)"
  local release_error_order = {
    "validate-state-root",
    "lstat-lock",
    "validate-lock",
    "validate-lock",
    "lstat-lock",
    "validate-lock",
    "close-lock",
    "rmdir-lock",
    "verify-lock-absent",
    "fsync-state-root",
    "close-state-root",
  }
  local release_validation_order = {
    "lstat-lock",
    "validate-lock",
    "validate-lock",
    "lstat-lock",
  }

  local function canonical_release_validation(operations)
    local offset = operations[1] == "validate-state-root" and 1 or 0
    local function match(slot, index, semantic)
      if slot > #release_validation_order then
        if semantic then
          return index == #operations and operations[index] == "validate-lock"
        end
        return index > #operations
      end
      if match(slot + 1, index, semantic) or match(slot + 1, index, true) then
        return true
      end
      return operations[index] == release_validation_order[slot]
        and match(slot + 1, index + 1, semantic)
    end
    return match(1, offset + 1, false)
  end

  local function canonical_release_error(value)
    if type(value) ~= "string" or #value == 0 or #value > 1024 then
      return nil
    end
    local components = vim.split(value, "; ", { plain = true })
    if #components > 8 or table.concat(components, "; ") ~= value then
      return nil
    end

    local position = 1
    local validation_operations = {}
    local removal_failed = false
    for _, component in ipairs(components) do
      local operation, code = component:match(
        "^baseline serialization release failed: ([a-z][a-z0-9%-]*) %(([A-Z0-9_]+)%)$"
      )
      local valid_code = code == "UNKNOWN"
        or type(code) == "string" and #code <= 24 and code:match("^E[A-Z0-9_]+$") ~= nil
      if not operation or not valid_code then
        return nil
      end

      local next_position
      for index = position, #release_error_order do
        if release_error_order[index] == operation then
          next_position = index + 1
          break
        end
      end
      if not next_position then
        return nil
      end
      position = next_position

      if
        operation == "validate-state-root"
        or operation == "lstat-lock"
        or operation == "validate-lock"
      then
        table.insert(validation_operations, operation)
      elseif operation == "rmdir-lock" or operation == "verify-lock-absent" then
        if #validation_operations > 0 or removal_failed then
          return nil
        end
        removal_failed = true
      end
    end
    if not canonical_release_validation(validation_operations) then
      return nil
    end
    return value
  end

  local function finish_create(lease, value, primary_error, supplied_failures)
    local failures = supplied_failures or new_failure_collector(nil)
    if primary_error ~= nil then
      if type(primary_error) == "string" and primary_error ~= "" then
        set_primary_failure(failures, primary_error)
      else
        set_primary_failure(failures, "baseline operation failed")
      end
    end

    local invoked, released, release_error = pcall(function()
      return lease:release()
    end)
    if not invoked or released ~= true or release_error ~= nil then
      local bounded_release_error = invoked and canonical_release_error(release_error) or nil
      failures.release_batch = bounded_release_error or invalid_release_error
    end

    local rendered = render_public_failures(failures)
    if rendered ~= "" then
      return nil, rendered
    end
    return value, nil
  end

  finish_remove = finish_create

  function api.create(identity, store)
    local valid, identity_error = validate_identity(identity, deps)
    if not valid then
      return nil, identity_error
    end

    local captured, capture_error = capture(identity)
    if not captured then
      return nil, capture_error
    end

    local review_id = deps
      .hash(table.concat({
        identity.key,
        tostring(deps.pid()),
        tostring(deps.hrtime()),
        captured.tree_oid or "unborn",
      }, "\0"))
      :sub(1, 32)
    if #review_id ~= 32 or not review_id:match("^[0-9a-f]+$") then
      return nil, "generated review id is invalid"
    end

    local expected_state, state_error = state_root_location(store)
    if not expected_state then
      return nil, state_error
    end
    local lease, serialization_error = deps.serialization.acquire(expected_state.path, deps)
    if not lease then
      return nil, serialization_error
    end

    local failures = new_failure_collector(nil)
    local created, create_error =
      create_under_lease(identity, store, review_id, captured, lease, expected_state, failures)
    return finish_create(lease, created, create_error, failures)
  end

  function api.open(identity, store, review_id)
    local valid, identity_error = validate_identity(identity, deps)
    if not valid then
      return nil, identity_error
    end
    local opened, open_error = load(identity, store, review_id)
    if not opened then
      return nil, open_error
    end
    return baseline_object(identity, store, opened)
  end

  function api.scan_current(identity, requested_paths)
    local valid, identity_error = validate_identity(identity, deps)
    if not valid then
      return nil, identity_error
    end
    local captured, capture_error = capture(identity, requested_paths, true)
    if not captured then
      return nil, capture_error
    end
    local result = { paths = {}, ignored = {} }
    for path, item in pairs(captured.paths) do
      local object = clone(item.object)
      object.storage = nil
      object.tree_oid = nil
      result.paths[path] = {
        object = object,
        hash = fingerprint_hash(object, deps.hash),
        binary = captured.binary[path] == true,
        reason = item.reason,
      }
    end
    for path, item in pairs(captured.ignored) do
      local object = clone(item.object)
      result.ignored[path] = {
        object = object,
        hash = fingerprint_hash(object, deps.hash),
        binary = captured.binary[path] == true,
      }
    end
    if identity.inside_git then
      -- Git omits directories/FIFOs replacing known untracked files. They are
      -- unsupported current objects, not deletions eligible for restoration.
      for _, path in ipairs(requested_paths or {}) do
        if not result.paths[path] and not result.ignored[path] then
          local object, _, err = fingerprint_path(identity.root, path, deps)
          if not object then
            return nil, err
          end
          if object.kind == "unsupported" then
            result.paths[path] =
              { object = object, hash = fingerprint_hash(object, deps.hash), binary = false }
          end
        end
      end
    end
    return result
  end

  api._fingerprint_hash = function(object)
    return fingerprint_hash(object, deps.hash)
  end

  api.read_current = function(identity, path)
    local valid, err = validate_identity(identity, deps)
    if not valid then
      return nil, err
    end
    local object, bytes, read_error = fingerprint_path(identity.root, path, deps)
    if not object then
      return nil, read_error
    end
    return { object = object, bytes = bytes, hash = fingerprint_hash(object, deps.hash) }
  end

  return api
end

local runtime = new()

function M.create(identity, store)
  return runtime.create(identity, store)
end

function M.open(identity, store, review_id)
  return runtime.open(identity, store, review_id)
end

M._internal = {
  read_current = function(identity, path)
    return runtime.read_current(identity, path)
  end,
  scan_current = function(identity, requested_paths)
    return runtime.scan_current(identity, requested_paths)
  end,
  fingerprint_hash = runtime._fingerprint_hash,
  encode_hex = encode_hex,
  decode_hex = decode_hex,
}

M._test = {
  new = new,
  canonical_json = canonical_json,
  encode_hex = encode_hex,
  decode_hex = decode_hex,
  fingerprint_hash = runtime._fingerprint_hash,
}

return M
