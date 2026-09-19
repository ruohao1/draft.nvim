local bit = require("bit")

local M = {}

local CONTROL_PATTERN = "[%z\1-\31\127]"
local MAX_JSON_BYTES = 1024 * 1024
local MAX_CONTEXT_BYTES = 4 * 1024 * 1024
local PRIVATE_DIRECTORY_MODE = 448
local PRIVATE_FILE_MODE = 384
local GROUP_OR_OTHER_WRITE_BITS = 18

local function has_control(value)
  return type(value) ~= "string" or value:find(CONTROL_PATTERN) ~= nil
end

local function path_within(base, path)
  return path == base or path:sub(1, #base + 1) == base .. "/"
end

local function valid_leaf(value)
  return type(value) == "string"
    and #value > 0
    and #value <= 128
    and value ~= "."
    and value ~= ".."
    and value:match("^[%w_.-]+$") ~= nil
end

local function same_file(left, right)
  if not left or not right then
    return false
  end
  if left.dev ~= nil and right.dev ~= nil and left.dev ~= right.dev then
    return false
  end
  if left.ino ~= nil and right.ino ~= nil and left.ino ~= right.ino then
    return false
  end
  return left.type == right.type
end

local function private_directory_metadata_safe(stat, uid)
  return stat
    and stat.type == "directory"
    and type(stat.mode) == "number"
    and stat.uid == uid
    and stat.mode % 512 == PRIVATE_DIRECTORY_MODE
end

local function validate_absolute(path)
  if type(path) ~= "string" or path == "" or path:sub(1, 1) ~= "/" then
    return nil, "private state path must be absolute"
  end
  if has_control(path) then
    return nil, "private state path contains a control character"
  end
  local normalized = vim.fs.normalize(path)
  if normalized ~= path then
    return nil, "private state path must be normalized: " .. path
  end
  return normalized
end

local function validate_directory(path, uid, create, deps)
  local normalized, path_error = validate_absolute(path)
  if not normalized then
    return nil, path_error
  end
  local before = deps.fs_lstat(path)
  if before and before.type == "link" then
    return nil, "private state path is a symlink: " .. path
  end
  if before and before.type ~= "directory" then
    return nil, "private state path is not a directory: " .. path
  end
  if not before and create then
    local ok, err = deps.fs_mkdir(path, PRIVATE_DIRECTORY_MODE)
    if not ok and not tostring(err):find("EEXIST", 1, true) then
      return nil, "could not create private state path: " .. tostring(err)
    end
  elseif not before then
    return nil, "private state path does not exist: " .. path
  end
  local after = deps.fs_lstat(path)
  if after and after.type == "link" then
    return nil, "private state path became a symlink: " .. path
  end
  local stat = deps.fs_stat(path)
  if
    not after
    or after.type ~= "directory"
    or not stat
    or stat.type ~= "directory"
    or not same_file(after, stat)
    or not private_directory_metadata_safe(stat, uid)
  then
    return nil, "private state path has unsafe ownership or mode: " .. path
  end
  if before and not same_file(before, after) then
    return nil, "private state path changed during validation: " .. path
  end
  local physical = deps.fs_realpath(path)
  if physical ~= normalized then
    return nil, "private state path has a symlinked ancestor: " .. path
  end
  local final = deps.fs_lstat(path)
  if not final or final.type == "link" or not same_file(after, final) then
    return nil, "private state path changed during validation: " .. path
  end
  return path
end

local function ensure_private_chain(anchor, components, uid, deps)
  local current = anchor
  for _, component in ipairs(components) do
    current = vim.fs.joinpath(current, component)
    local ok, err = validate_directory(current, uid, true, deps)
    if not ok then
      return nil, err
    end
  end
  return current
end

local function validate_user_ancestor(path, uid, exact_mode, deps)
  local normalized, path_error = validate_absolute(path)
  if not normalized then
    return nil, path_error
  end
  local lstat = deps.fs_lstat(path)
  local stat = deps.fs_stat(path)
  if
    not lstat
    or lstat.type == "link"
    or lstat.type ~= "directory"
    or not stat
    or stat.type ~= "directory"
    or not same_file(lstat, stat)
  then
    return nil, "state ancestor is not a nonsymlink directory: " .. path
  end
  if stat.uid ~= uid then
    return nil, "state ancestor has the wrong owner: " .. path
  end
  if exact_mode and stat.mode % 512 ~= exact_mode then
    return nil, "state ancestor has an unsafe mode: " .. path
  end
  if not exact_mode and bit.band(stat.mode, GROUP_OR_OTHER_WRITE_BITS) ~= 0 then
    return nil, "state ancestor is group- or world-writable: " .. path
  end
  local physical = deps.fs_realpath(path)
  if type(physical) ~= "string" or physical == "" or has_control(physical) then
    return nil, "state ancestor is not physical: " .. path
  end
  local final = deps.fs_lstat(path)
  if not final or final.type == "link" or not same_file(lstat, final) then
    return nil, "state ancestor changed during validation: " .. path
  end
  return vim.fs.normalize(physical)
end

local function ensure_user_path(anchor, components, uid, deps)
  local current = anchor
  for _, component in ipairs(components) do
    current = vim.fs.joinpath(current, component)
    local before = deps.fs_lstat(current)
    if before and before.type == "link" then
      return nil, "state ancestor is a symlink: " .. current
    end
    if not before then
      local made, make_error = deps.fs_mkdir(current, PRIVATE_DIRECTORY_MODE)
      if not made and not tostring(make_error):find("EEXIST", 1, true) then
        return nil, "could not create state ancestor: " .. tostring(make_error)
      end
    end
    local validated, validation_error = validate_user_ancestor(current, uid, nil, deps)
    if not validated then
      return nil, validation_error
    end
    current = validated
  end
  return current
end

local function file_metadata_safe(stat, uid)
  return stat and stat.type == "file" and stat.uid == uid and stat.mode % 512 == PRIVATE_FILE_MODE
end

local function read_private_file(path, uid, maximum, deps)
  local parent, parent_error = validate_directory(vim.fs.dirname(path), uid, false, deps)
  if not parent then
    return nil, parent_error
  end
  local before = deps.fs_lstat(path)
  if not before then
    return nil
  end
  if before.type == "link" then
    return nil, "private state file is a symlink: " .. path
  end
  if not file_metadata_safe(before, uid) then
    return nil, "private state file has unsafe ownership or mode: " .. path
  end
  if type(before.size) ~= "number" or before.size > maximum then
    return nil, "private state file is too large: " .. path
  end
  local fd, open_error = deps.fs_open(path, "r", 0)
  if not fd then
    return nil, "could not open private state file: " .. tostring(open_error)
  end
  local opened = deps.fs_fstat(fd)
  if
    not file_metadata_safe(opened, uid)
    or not same_file(before, opened)
    or opened.size > maximum
  then
    deps.fs_close(fd)
    return nil, "private state file changed during validation: " .. path
  end
  local bytes, read_error = deps.fs_read(fd, opened.size + 1, 0)
  local closed, close_error = deps.fs_close(fd)
  if bytes == nil then
    return nil, "could not read private state file: " .. tostring(read_error)
  end
  if closed == nil or closed == false then
    return nil, "could not close private state file: " .. tostring(close_error)
  end
  if #bytes ~= opened.size then
    return nil, "private state file changed while reading: " .. path
  end
  local after = deps.fs_lstat(path)
  if not file_metadata_safe(after, uid) or not same_file(opened, after) then
    return nil, "private state file changed while reading: " .. path
  end
  return bytes
end

local function read_json(path, uid, deps)
  local bytes, read_error = read_private_file(path, uid, MAX_JSON_BYTES, deps)
  if bytes == nil then
    return nil, read_error
  end
  local ok, value = pcall(vim.json.decode, bytes)
  if not ok or type(value) ~= "table" then
    return nil, "private state file contains invalid JSON: " .. path
  end
  return value
end

local function write_atomic(path, bytes, uid, deps)
  if type(bytes) ~= "string" or #bytes > MAX_JSON_BYTES then
    return nil, "private state payload is invalid or too large", false
  end
  local parent = vim.fs.dirname(path)
  local parent_path, parent_error = validate_directory(parent, uid, false, deps)
  if not parent_path then
    return nil, parent_error, false
  end
  local destination = deps.fs_lstat(path)
  if destination and destination.type == "link" then
    return nil, "refusing to replace a symlink: " .. path, false
  end
  if destination and not file_metadata_safe(destination, uid) then
    return nil, "refusing to replace an unsafe state file: " .. path, false
  end

  local temporary = vim.fs.joinpath(
    parent,
    string.format(".%s.%d.%d", vim.fs.basename(path), deps.pid(), deps.hrtime())
  )
  local fd, open_error = deps.fs_open(temporary, "wx", PRIVATE_FILE_MODE)
  if not fd then
    return nil, tostring(open_error), false
  end
  local offset = 0
  local write_error
  while offset < #bytes do
    local wrote
    wrote, write_error = deps.fs_write(fd, bytes:sub(offset + 1), offset)
    if type(wrote) ~= "number" or wrote <= 0 or wrote > #bytes - offset then
      break
    end
    offset = offset + wrote
  end
  local synced, sync_error
  if offset == #bytes then
    synced, sync_error = deps.fs_fsync(fd)
  end
  local temporary_stat = deps.fs_fstat(fd)
  local closed, close_error = deps.fs_close(fd)
  if
    offset ~= #bytes
    or not synced
    or not file_metadata_safe(temporary_stat, uid)
    or temporary_stat.size ~= #bytes
    or closed == nil
    or closed == false
  then
    deps.fs_unlink(temporary)
    return nil,
      tostring(
        write_error or sync_error or close_error or "temporary state file has unsafe metadata"
      ),
      false
  end

  local parent_before = deps.fs_lstat(parent)
  local parent_fd, parent_open_error = deps.fs_open(parent, "r", 0)
  if not parent_fd then
    deps.fs_unlink(temporary)
    return nil, "could not open state directory for fsync: " .. tostring(parent_open_error), false
  end
  local parent_opened = deps.fs_fstat(parent_fd)
  local parent_before_rename = deps.fs_lstat(parent)
  if
    not private_directory_metadata_safe(parent_before, uid)
    or not private_directory_metadata_safe(parent_opened, uid)
    or not private_directory_metadata_safe(parent_before_rename, uid)
    or not same_file(parent_before, parent_opened)
    or not same_file(parent_opened, parent_before_rename)
  then
    local _, parent_close_error = deps.fs_close(parent_fd)
    deps.fs_unlink(temporary)
    return nil,
      "state directory changed before publication: " .. tostring(parent_close_error or "unsafe"),
      false
  end

  local renamed, rename_error = deps.fs_rename(temporary, path)
  if not renamed then
    local _, parent_close_error = deps.fs_close(parent_fd)
    deps.fs_unlink(temporary)
    return nil, tostring(rename_error or parent_close_error), false
  end
  local parent_synced, parent_sync_error = deps.fs_fsync(parent_fd)
  local parent_closed, parent_close_error = deps.fs_close(parent_fd)
  local parent_after = deps.fs_lstat(parent)
  if
    not parent_synced
    or parent_closed == nil
    or parent_closed == false
    or not private_directory_metadata_safe(parent_after, uid)
    or not same_file(parent_before, parent_opened)
    or not same_file(parent_opened, parent_after)
  then
    return nil,
      "state directory fsync failed: " .. tostring(
        parent_sync_error or parent_close_error or "directory changed"
      ),
      true
  end
  return true
end

local function error_text(...)
  local errors = {}
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if value ~= nil and value ~= false then
      table.insert(errors, tostring(value))
    end
  end
  if #errors == 0 then
    return "unknown error"
  end
  return table.concat(errors, "; ")
end

local function create_once(path, bytes, uid, deps, maximum)
  if type(bytes) ~= "string" or #bytes > (maximum or MAX_JSON_BYTES) then
    return nil, "private state payload is invalid or too large", false
  end
  local parent = vim.fs.dirname(path)
  local parent_path, parent_error = validate_directory(parent, uid, false, deps)
  if not parent_path then
    return nil, parent_error, false
  end

  local temporary = vim.fs.joinpath(
    parent,
    string.format(".%s.once.%d.%d", vim.fs.basename(path), deps.pid(), deps.hrtime())
  )
  local fd, open_error = deps.fs_open(temporary, "wx", PRIVATE_FILE_MODE)
  if not fd then
    return nil, tostring(open_error), false
  end
  local offset = 0
  local write_error
  while offset < #bytes do
    local wrote
    wrote, write_error = deps.fs_write(fd, bytes:sub(offset + 1), offset)
    if type(wrote) ~= "number" or wrote <= 0 or wrote > #bytes - offset then
      break
    end
    offset = offset + wrote
  end
  local synced, sync_error
  if offset == #bytes then
    synced, sync_error = deps.fs_fsync(fd)
  end
  local temporary_stat = deps.fs_fstat(fd)
  local closed, close_error = deps.fs_close(fd)
  if
    offset ~= #bytes
    or not synced
    or not file_metadata_safe(temporary_stat, uid)
    or temporary_stat.size ~= #bytes
    or closed == nil
    or closed == false
  then
    local removed, remove_error = deps.fs_unlink(temporary)
    return nil,
      error_text(
        write_error or sync_error or close_error or "temporary state file has unsafe metadata",
        not removed and remove_error or nil
      ),
      false
  end
  local temporary_path_stat = deps.fs_lstat(temporary)
  if
    not file_metadata_safe(temporary_path_stat, uid)
    or not same_file(temporary_stat, temporary_path_stat)
    or temporary_path_stat.size ~= #bytes
  then
    local removed, remove_error = deps.fs_unlink(temporary)
    return nil,
      error_text(
        "temporary state file changed before publication",
        not removed and remove_error or nil
      ),
      false
  end

  local parent_before = deps.fs_lstat(parent)
  local parent_fd, parent_open_error = deps.fs_open(parent, "r", 0)
  if not parent_fd then
    local removed, remove_error = deps.fs_unlink(temporary)
    return nil,
      error_text(
        "could not open state directory for fsync: " .. tostring(parent_open_error),
        not removed and remove_error or nil
      ),
      false
  end
  local parent_opened = deps.fs_fstat(parent_fd)
  local parent_before_link = deps.fs_lstat(parent)
  if
    not private_directory_metadata_safe(parent_before, uid)
    or not private_directory_metadata_safe(parent_opened, uid)
    or not private_directory_metadata_safe(parent_before_link, uid)
    or not same_file(parent_before, parent_opened)
    or not same_file(parent_opened, parent_before_link)
  then
    local parent_closed, parent_close_error = deps.fs_close(parent_fd)
    local removed, remove_error = deps.fs_unlink(temporary)
    return nil,
      error_text(
        "state directory changed before create-once publication",
        (parent_closed == nil or parent_closed == false) and parent_close_error or nil,
        not removed and remove_error or nil
      ),
      false
  end

  local linked, link_error, link_code = deps.fs_link(temporary, path)
  local link_exists = not linked
    and (
      tostring(link_error):find("EEXIST", 1, true) ~= nil
      or tostring(link_code):find("EEXIST", 1, true) ~= nil
    )
  local removed, remove_error = deps.fs_unlink(temporary)
  local parent_synced, parent_sync_error = deps.fs_fsync(parent_fd)
  local parent_closed, parent_close_error = deps.fs_close(parent_fd)
  local parent_after = deps.fs_lstat(parent)
  local published = linked and true or link_exists

  if not linked and not link_exists then
    return nil,
      error_text(
        link_error or link_code or "could not publish private state file",
        not removed and remove_error or nil,
        not parent_synced and parent_sync_error or nil,
        (parent_closed == nil or parent_closed == false) and parent_close_error or nil
      ),
      false
  end
  if
    not removed
    or not parent_synced
    or parent_closed == nil
    or parent_closed == false
    or not private_directory_metadata_safe(parent_after, uid)
    or not same_file(parent_before, parent_opened)
    or not same_file(parent_opened, parent_after)
  then
    return nil,
      error_text(
        not removed and remove_error or nil,
        not parent_synced and parent_sync_error or nil,
        (parent_closed == nil or parent_closed == false) and parent_close_error or nil,
        not private_directory_metadata_safe(parent_after, uid) and "state directory became unsafe"
          or nil,
        not same_file(parent_opened, parent_after) and "state directory changed" or nil
      ),
      published,
      linked and temporary_stat or nil
  end

  if linked then
    local destination = deps.fs_lstat(path)
    if
      not file_metadata_safe(destination, uid)
      or not same_file(temporary_stat, destination)
      or destination.size ~= #bytes
    then
      return nil, "created state file changed during publication: " .. path, true, temporary_stat
    end
    return "created"
  end
  return "exists"
end

local function nullish(value)
  return value == nil or value == vim.NIL
end

local function validate_record(record, identity)
  if type(record) ~= "table" or record.schema ~= 1 then
    return nil, "durable record schema is invalid"
  end
  local allowed = {
    schema = true,
    identity = true,
    active_backend = true,
    sessions = true,
    grants = true,
    review_id = true,
    completed_review_id = true,
    opencode_profile = true,
  }
  for key in pairs(record) do
    if not allowed[key] then
      return nil, "durable record has an unknown field: " .. tostring(key)
    end
  end
  if record.active_backend == nil or record.review_id == nil or record.opencode_profile == nil then
    return nil, "durable record is missing a required field"
  end
  local item = record.identity
  local identity_fields = { key = true, root = true, namespace = true, owner_pane = true }
  if type(item) == "table" then
    for key in pairs(item) do
      if not identity_fields[key] then
        return nil, "durable record identity has an unknown field: " .. tostring(key)
      end
    end
  end
  if
    type(item) ~= "table"
    or item.owner_pane == nil
    or item.key ~= identity.key
    or item.root ~= identity.root
    or item.namespace ~= identity.namespace
    or (not nullish(item.owner_pane) and item.owner_pane ~= identity.owner_pane)
    or (nullish(item.owner_pane) and identity.owner_pane ~= nil)
  then
    return nil, "durable record identity does not match"
  end
  if
    not nullish(record.active_backend)
    and record.active_backend ~= "codex"
    and record.active_backend ~= "claude"
    and record.active_backend ~= "opencode"
  then
    return nil, "durable record backend is invalid"
  end
  if type(record.sessions) ~= "table" then
    return nil, "durable record sessions are invalid"
  end
  local session_fields = { codex = true, claude = true, opencode = true }
  for key in pairs(record.sessions) do
    if not session_fields[key] then
      return nil, "durable record sessions have an unknown field: " .. tostring(key)
    end
  end
  for _, backend in ipairs({ "codex", "claude", "opencode" }) do
    if type(record.sessions[backend]) ~= "string" then
      return nil, "durable record session is invalid: " .. backend
    end
  end
  if type(record.grants) ~= "table" or not vim.islist(record.grants) then
    return nil, "durable record grants are invalid"
  end
  for index, grant in ipairs(record.grants) do
    if index < 1 or type(grant) ~= "string" or grant:sub(1, 1) ~= "/" or has_control(grant) then
      return nil, "durable record grant is invalid"
    end
  end
  if not nullish(record.review_id) and not valid_leaf(record.review_id) then
    return nil, "durable record review id is invalid"
  end
  if
    not nullish(record.completed_review_id)
    and (
      type(record.completed_review_id) ~= "string"
      or #record.completed_review_id > 128
      or not record.completed_review_id:match("^review_[0-9a-f]+$")
    )
  then
    return nil, "durable completed review id is invalid"
  end
  local profile = record.opencode_profile
  if profile ~= vim.NIL then
    if type(profile) ~= "table" or record.active_backend ~= "opencode" then
      return nil, "durable OpenCode profile is invalid"
    end
    for key in pairs(profile) do
      if key ~= "token" and key ~= "fingerprint" and key ~= "version" then
        return nil, "durable OpenCode profile has an unknown field"
      end
    end
    if
      type(profile.token) ~= "string"
      or #profile.token ~= 32
      or not profile.token:match("^[0-9a-f]+$")
      or type(profile.fingerprint) ~= "string"
      or #profile.fingerprint ~= 64
      or not profile.fingerprint:match("^[0-9a-f]+$")
      -- Read the previous audited reference for explicit close/reopen recovery.
      -- Transport adoption, profile inspection and launch remain current-only.
      or (profile.version ~= "1.18.30" and profile.version ~= "1.18.28")
    then
      return nil, "durable OpenCode profile is invalid"
    end
  end
  return true
end

local function remove_private_file(path, uid, deps)
  local parent, parent_error = validate_directory(vim.fs.dirname(path), uid, false, deps)
  if not parent then
    return nil, parent_error
  end
  local stat = deps.fs_lstat(path)
  if not stat then
    return true
  end
  if not file_metadata_safe(stat, uid) then
    return nil, "refusing to remove an unsafe private file: " .. path
  end
  local removed, remove_error = deps.fs_unlink(path)
  if not removed then
    return nil, tostring(remove_error)
  end
  local parent_fd, open_error = deps.fs_open(parent, "r", 0)
  if not parent_fd then
    return nil, "could not open private directory for fsync: " .. tostring(open_error)
  end
  local synced, sync_error = deps.fs_fsync(parent_fd)
  deps.fs_close(parent_fd)
  if not synced then
    return nil, "private directory fsync failed: " .. tostring(sync_error)
  end
  return true
end

local function new_store(options, deps)
  local identity = options.identity
  if
    type(identity) ~= "table"
    or type(identity.key) ~= "string"
    or not identity.key:match("^[0-9a-f]+$")
    or #identity.key ~= 32
    or type(identity.root) ~= "string"
    or identity.root:sub(1, 1) ~= "/"
    or has_control(identity.root)
    or type(identity.namespace) ~= "string"
    or identity.namespace == ""
    or has_control(identity.namespace)
  then
    return nil, "AI identity is invalid for private state"
  end

  local runtime_root, runtime_error =
    validate_directory(options.runtime_base, options.uid, true, deps)
  if not runtime_root then
    return nil, runtime_error
  end
  local state_root, state_error = validate_directory(options.state_base, options.uid, true, deps)
  if not state_root then
    return nil, state_error
  end
  local runtime_dir, runtime_dir_error =
    ensure_private_chain(runtime_root, { identity.key }, options.uid, deps)
  if not runtime_dir then
    return nil, runtime_dir_error
  end
  local state_dir, state_dir_error =
    ensure_private_chain(state_root, { identity.key }, options.uid, deps)
  if not state_dir then
    return nil, state_dir_error
  end

  local record_path = vim.fs.joinpath(state_dir, "record.json")
  local control_token_path = vim.fs.joinpath(runtime_dir, "control-token")
  local store = {}

  function store:runtime_root()
    return runtime_root
  end

  function store:state_root()
    return state_root
  end

  function store:runtime_dir()
    return runtime_dir
  end

  function store:state_dir()
    return state_dir
  end

  function store:record_path()
    return record_path
  end

  function store:read_record()
    local record, read_error = read_json(record_path, options.uid, deps)
    if record == nil then
      return nil, read_error
    end
    local valid, validation_error = validate_record(record, identity)
    if not valid then
      return nil, validation_error
    end
    return record
  end

  function store:write_record(record)
    local valid, validation_error = validate_record(record, identity)
    if not valid then
      return nil, validation_error
    end
    local ok, encoded = pcall(vim.json.encode, record)
    if not ok then
      return nil, "could not encode durable record: " .. tostring(encoded)
    end
    return write_atomic(record_path, encoded, options.uid, deps)
  end

  function store:write_launch(manifest)
    if
      type(manifest) ~= "table"
      or type(manifest.token) ~= "string"
      or #manifest.token < 32
      or #manifest.token > 128
      or not manifest.token:match("^[0-9a-f]+$")
    then
      return nil, "launch manifest token is invalid"
    end
    local launches, launches_error =
      ensure_private_chain(runtime_dir, { "launches" }, options.uid, deps)
    if not launches then
      return nil, launches_error
    end
    local path = vim.fs.joinpath(launches, manifest.token .. ".json")
    local ok, encoded = pcall(vim.json.encode, manifest)
    if not ok then
      return nil, "could not encode launch manifest: " .. tostring(encoded)
    end
    local written, write_error, published = write_atomic(path, encoded, options.uid, deps)
    if not written then
      return nil, write_error, published
    end
    return path
  end

  function store:remove_launch(token)
    if type(token) ~= "string" or #token < 32 or #token > 128 or not token:match("^[0-9a-f]+$") then
      return nil, "launch manifest token is invalid"
    end
    local launches = vim.fs.joinpath(runtime_dir, "launches")
    if not deps.fs_lstat(launches) then
      return true
    end
    local path = vim.fs.joinpath(launches, token .. ".json")
    if not path_within(runtime_dir, path) then
      return nil, "launch manifest path escaped private state"
    end
    return remove_private_file(path, options.uid, deps)
  end

  function store:review_dir(review_id)
    if not valid_leaf(review_id) then
      return nil, "review id is invalid"
    end
    return ensure_private_chain(state_dir, { "reviews", review_id }, options.uid, deps)
  end

  local function decision_directory(review_id, create)
    if type(review_id) ~= "string" or #review_id ~= 32 or not review_id:match("^[0-9a-f]+$") then
      return nil, "review decision identity is invalid"
    end
    local path = vim.fs.joinpath(state_dir, "decisions", review_id)
    if create then
      return ensure_private_chain(state_dir, { "decisions", review_id }, options.uid, deps)
    end
    local stat, err, code = deps.fs_lstat(path)
    if not stat then
      return nil, code ~= "ENOENT" and (err or "private review directory is unavailable") or nil
    end
    return validate_directory(path, options.uid, false, deps)
  end

  -- Mutable decisions are separate from the immutable baseline's manifest and objects.
  function store:write_review_decision(review_id, record, bytes)
    if
      type(record) ~= "table"
      or type(record.path_hex) ~= "string"
      or #record.path_hex == 0
      or #record.path_hex > 8192
      or #record.path_hex % 2 ~= 0
      or record.path_hex:find("[^0-9a-f]")
    then
      return nil, "review decision record is invalid"
    end
    local directory, err = decision_directory(review_id, true)
    if not directory then
      return nil, err
    end
    if bytes ~= nil then
      if type(bytes) ~= "string" or #bytes > 64 * 1024 * 1024 then
        return nil, "review decision object exceeds its bound"
      end
      local hash = vim.fn.sha256(bytes)
      local path = vim.fs.joinpath(directory, hash .. ".object")
      local created, create_error = create_once(path, bytes, options.uid, deps, 64 * 1024 * 1024)
      if not created then
        return nil, create_error
      end
      local stored, read_error = read_private_file(path, options.uid, 64 * 1024 * 1024, deps)
      if stored ~= bytes then
        return nil, read_error or "review decision object changed"
      end
    end
    local encoded, payload = pcall(vim.json.encode, record)
    if not encoded then
      return nil, "review decision encoding failed"
    end
    return write_atomic(
      vim.fs.joinpath(directory, vim.fn.sha256(record.path_hex) .. ".json"),
      payload,
      options.uid,
      deps
    )
  end

  function store:read_review_decision(review_id, path)
    local directory, err = decision_directory(review_id, false)
    if not directory then
      return nil, err
    end
    local path_hex = (
      path:gsub(".", function(byte)
        return string.format("%02x", byte:byte())
      end)
    )
    return read_json(
      vim.fs.joinpath(directory, vim.fn.sha256(path_hex) .. ".json"),
      options.uid,
      deps
    )
  end

  function store:read_review_decisions(review_id)
    local directory, err = decision_directory(review_id, false)
    if not directory then
      return err == nil and {} or nil, err
    end
    local scanner, scan_error = deps.fs_scandir(directory)
    if not scanner then
      return nil, scan_error
    end
    local records = {}
    while true do
      local name, kind = deps.fs_scandir_next(scanner)
      if not name then
        break
      end
      local path = vim.fs.joinpath(directory, name)
      if kind ~= "file" or not file_metadata_safe(deps.fs_lstat(path), options.uid) then
        return nil, "unsafe review decision entry"
      end
      local hash, extension = name:match("^([0-9a-f]+)%.([a-z]+)$")
      if
        name ~= "phase.json"
        and (not hash or #hash ~= 64 or (extension ~= "json" and extension ~= "object"))
      then
        return nil, "unfinished review decision publication"
      end
      if name ~= "phase.json" and extension == "json" then
        local record, read_error = read_json(path, options.uid, deps)
        if
          not record
          or type(record.path_hex) ~= "string"
          or vim.fn.sha256(record.path_hex) ~= hash
        then
          return nil, read_error or "review decision name mismatch"
        end
        records[#records + 1] = record
      end
    end
    return records
  end

  function store:read_review_object(review_id, hash)
    if type(hash) ~= "string" or #hash ~= 64 or not hash:match("^[0-9a-f]+$") then
      return nil, "review object hash is invalid"
    end
    local directory, err = decision_directory(review_id, false)
    if not directory then
      return nil, err
    end
    local bytes, read_error = read_private_file(
      vim.fs.joinpath(directory, hash .. ".object"),
      options.uid,
      64 * 1024 * 1024,
      deps
    )
    if not bytes or vim.fn.sha256(bytes) ~= hash then
      return nil, read_error or "review decision object hash mismatch"
    end
    return bytes
  end

  local function valid_review_phase(record)
    if
      type(record) ~= "table"
      or record.schema ~= 1
      or type(record.baseline_hash) ~= "string"
      or #record.baseline_hash ~= 64
      or not record.baseline_hash:match("^[0-9a-f]+$")
      or (record.phase ~= "read-only" and record.phase ~= "cleanup")
    then
      return false
    end
    for key in pairs(record) do
      if key ~= "schema" and key ~= "baseline_hash" and key ~= "phase" then
        return false
      end
    end
    return true
  end

  function store:read_review_phase(review_id)
    local directory, err = decision_directory(review_id, false)
    if not directory then
      return nil, err
    end
    local record, read_error =
      read_json(vim.fs.joinpath(directory, "phase.json"), options.uid, deps)
    if record == nil then
      return nil, read_error
    end
    if not valid_review_phase(record) then
      return nil, "private review resolution phase is invalid"
    end
    return record
  end

  function store:write_review_phase(review_id, baseline_hash, phase)
    local record = { schema = 1, baseline_hash = baseline_hash, phase = phase }
    if not valid_review_phase(record) then
      return nil, "private review resolution phase is invalid"
    end
    local directory, err = decision_directory(review_id, true)
    if not directory then
      return nil, err
    end
    return write_atomic(
      vim.fs.joinpath(directory, "phase.json"),
      vim.json.encode(record),
      options.uid,
      deps
    )
  end

  function store:cleanup_review_decisions(review_id, keep_phase)
    local directory, err = decision_directory(review_id, false)
    if not directory then
      return err == nil and true or nil, err
    end
    local scanner, scan_error = deps.fs_scandir(directory)
    if not scanner then
      return nil, scan_error
    end
    local paths, phase_path = {}, nil
    while true do
      local name, kind = deps.fs_scandir_next(scanner)
      if not name then
        break
      end
      local path = vim.fs.joinpath(directory, name)
      if
        not valid_leaf(name)
        or kind ~= "file"
        or not file_metadata_safe(deps.fs_lstat(path), options.uid)
      then
        return nil, "unsafe private review decision entry"
      end
      if name == "phase.json" then
        phase_path = path
      else
        paths[#paths + 1] = path
      end
    end
    for _, path in ipairs(paths) do
      local removed, remove_error = remove_private_file(path, options.uid, deps)
      if not removed then
        return nil, remove_error
      end
    end
    if keep_phase then
      return true
    end
    -- Retain the acknowledgement until all recoverable decision bytes are gone.
    if phase_path then
      local removed, remove_error = remove_private_file(phase_path, options.uid, deps)
      if not removed then
        return nil, remove_error
      end
    end
    local removed, remove_error = deps.fs_rmdir(directory)
    if not removed then
      return nil, remove_error
    end
    local fd = deps.fs_open(vim.fs.dirname(directory), "r", 0)
    if not fd then
      return nil, "review decision directory sync unavailable"
    end
    local synced = deps.fs_fsync(fd)
    local closed = deps.fs_close(fd)
    return synced and closed and true or nil,
      not (synced and closed) and "review decision directory sync failed" or nil
  end

  -- Called under review serialization; never creates or removes a baseline.
  function store:cleanup_removed_review(review_id)
    local directory, err = decision_directory(review_id, false)
    if err then
      return nil, err
    end
    local reviews = vim.fs.joinpath(state_dir, "reviews")
    if
      not validate_directory(state_dir, options.uid, false, deps)
      or not validate_directory(reviews, options.uid, false, deps)
    then
      return nil, "private baseline parent is unavailable"
    end
    local entry, _, code = deps.fs_lstat(vim.fs.joinpath(reviews, review_id))
    if entry or code ~= "ENOENT" then
      return nil, "baseline removal has not been verified"
    end
    if not directory then
      return true
    end
    local phase, phase_error = self:read_review_phase(review_id)
    if phase_error or (phase and phase.phase ~= "cleanup") then
      return nil, "review cleanup has not been acknowledged"
    end
    if not phase then
      -- A final rmdir failure can leave an empty directory after phase removal.
      -- Without an acknowledgement no recovery bytes may be discarded.
      local scanner = deps.fs_scandir(directory)
      if not scanner or deps.fs_scandir_next(scanner) ~= nil then
        return nil, "unacknowledged review residue is not empty"
      end
    end
    return self:cleanup_review_decisions(review_id)
  end

  local review_actions = {}
  function store:write_review_action(review_id, action, bytes)
    if
      type(action) ~= "table"
      or action.root ~= identity.root
      or type(action.desired) ~= "table"
    then
      return nil, "review action is invalid"
    end
    local directory, directory_error = decision_directory(review_id, true)
    if not directory then
      return nil, directory_error
    end
    local nonce = (
      vim.uv.random(16):gsub(".", function(byte)
        return string.format("%02x", byte:byte())
      end)
    )
    local reference = { manifest = vim.fs.joinpath(directory, "action-" .. nonce .. ".json") }
    local owned = {}
    review_actions[reference] = owned
    local function publish(path, payload, limit)
      local created, err, _, stat = create_once(path, payload, options.uid, deps, limit)
      if created == "created" then
        stat = deps.fs_lstat(path)
      end
      if stat then
        owned[#owned + 1] = { path = path, stat = stat }
      end
      return created == "created" and true or nil, err or "review action publication collided"
    end
    local manifest = vim.deepcopy(action)
    if bytes ~= nil then
      if
        type(bytes) ~= "string"
        or #bytes > 64 * 1024 * 1024
        or #bytes ~= action.desired.size
        or vim.fn.sha256(bytes) ~= action.desired.sha256
      then
        return nil, "desired review action bytes are invalid", reference
      end
      reference.source = vim.fs.joinpath(directory, "action-" .. nonce .. ".object")
      local created, err = publish(reference.source, bytes, 64 * 1024 * 1024)
      if not created then
        return nil, err, reference
      end
      manifest.desired.source = reference.source
    else
      manifest.desired.source = vim.NIL
    end
    local encoded, payload = pcall(vim.json.encode, manifest)
    if not encoded then
      return nil, "review action encoding failed", reference
    end
    local created, err = publish(reference.manifest, payload, MAX_JSON_BYTES)
    if not created then
      return nil, err, reference
    end
    return reference
  end

  function store:remove_review_action(reference)
    local owned = review_actions[reference]
    if not owned then
      return nil, "unknown private review action"
    end
    local remaining = {}
    for _, item in ipairs(owned) do
      local current, _, code = deps.fs_lstat(item.path)
      if current then
        if
          not same_file(item.stat, current)
          or not file_metadata_safe(current, options.uid)
          or not remove_private_file(item.path, options.uid, deps)
        then
          remaining[#remaining + 1] = item
        end
      elseif code ~= "ENOENT" then
        remaining[#remaining + 1] = item
      end
    end
    if #remaining > 0 then
      review_actions[reference] = remaining
      return nil, "private review action cleanup failed"
    end
    review_actions[reference] = nil
    return true
  end

  -- Passive reconnect must not manufacture missing backend state or event files.
  function store:launch_paths(backend, create)
    if backend ~= "codex" and backend ~= "claude" and backend ~= "opencode" then
      return nil, "launch backend is invalid"
    end
    local function directory(base, parts)
      if create ~= false then
        return ensure_private_chain(base, parts, options.uid, deps)
      end
      local path, err = validate_directory(base, options.uid, false, deps)
      if not path then
        return nil, err
      end
      for _, part in ipairs(parts) do
        path, err = validate_directory(vim.fs.joinpath(path, part), options.uid, false, deps)
        if not path then
          return nil, err
        end
      end
      return path
    end
    local backend_state, backend_error = directory(state_dir, { "backends", backend })
    if not backend_state then
      return nil, backend_error
    end
    local contexts, context_error = directory(runtime_dir, { "contexts" })
    if not contexts then
      return nil, context_error
    end
    local events = vim.fs.joinpath(backend_state, "events.jsonl")
    if create ~= false and not deps.fs_lstat(events) then
      local created, err = create_once(events, "", options.uid, deps)
      if not created then
        return nil, err
      end
    end
    if not file_metadata_safe(deps.fs_lstat(events), options.uid) then
      return nil, "private event file is unavailable or unsafe"
    end
    return {
      backend_state = backend_state,
      context_dir = contexts,
      event_file = events,
      control_socket = vim.fs.joinpath(runtime_dir, "control.sock"),
    }
  end

  function store:cleanup_launches()
    local path = vim.fs.joinpath(runtime_dir, "launches")
    if not deps.fs_lstat(path) then
      return true
    end
    local valid, validation_error = validate_directory(path, options.uid, false, deps)
    if not valid then
      return nil, validation_error
    end
    local scanner = deps.fs_scandir(path)
    if not scanner then
      return nil, "could not scan private launch manifests"
    end
    local tokens = {}
    while true do
      local name, kind = deps.fs_scandir_next(scanner)
      if not name then
        break
      end
      local launch_token = name:match("^([0-9a-f]+)%.json$")
      if
        kind ~= "file"
        or not launch_token
        or #launch_token < 32
        or #launch_token > 128
        or not file_metadata_safe(deps.fs_lstat(vim.fs.joinpath(path, name)), options.uid)
      then
        return nil, "refusing to remove an unsafe launch manifest entry"
      end
      tokens[#tokens + 1] = launch_token
    end
    for _, launch_token in ipairs(tokens) do
      local removed, err = self:remove_launch(launch_token)
      if not removed then
        return nil, err
      end
    end
    return true
  end

  function store:read_control_token()
    local token, read_error = read_private_file(control_token_path, options.uid, 256, deps)
    if token == nil then
      return nil, read_error
    end
    if #token < 32 or #token > 128 or not token:match("^[0-9a-f]+$") then
      return nil, "control token is invalid"
    end
    return token
  end

  function store:ensure_control_token(factory)
    local existing, read_error = self:read_control_token()
    if existing then
      return existing
    end
    if read_error then
      return nil, read_error
    end
    if type(factory) ~= "function" then
      return nil, "control token factory is unavailable"
    end
    local token = factory()
    if type(token) ~= "string" or #token < 32 or #token > 128 or not token:match("^[0-9a-f]+$") then
      return nil, "control token factory returned an invalid token"
    end
    local outcome, write_error, published =
      create_once(control_token_path, token, options.uid, deps)
    if not outcome then
      return nil, write_error, published
    end
    if outcome == "created" then
      return token
    end
    local winner, winner_error = self:read_control_token()
    if winner == nil then
      return nil, winner_error or "control token winner is unavailable", true
    end
    return winner
  end

  function store:remove_control_token()
    return remove_private_file(control_token_path, options.uid, deps)
  end

  local function context_name(name)
    if type(name) ~= "string" then
      return false
    end
    local nonce = name:match("^" .. identity.key .. "%-([A-Za-z0-9_-]+)%.txt$")
    return nonce ~= nil and #nonce <= 64
  end

  local context_dir = vim.fs.joinpath(runtime_dir, "contexts")
  local function context_path(path)
    return type(path) == "string"
      and vim.fs.dirname(path) == context_dir
      and path == vim.fs.joinpath(context_dir, vim.fs.basename(path))
      and context_name(vim.fs.basename(path))
  end

  -- Context payloads are never JSON, launch manifests, or durable records.
  function store:write_context(name, bytes)
    if
      not context_name(name)
      or type(bytes) ~= "string"
      or #bytes == 0
      or #bytes > MAX_CONTEXT_BYTES
      or vim.fn.strtrans(context_dir) ~= context_dir
      or context_dir:find("\226\128[\168\169]")
    then
      return nil, "private context name or payload is invalid"
    end
    local root = validate_directory(runtime_dir, options.uid, false, deps)
    if not root then
      return nil, "private context runtime is unsafe"
    end
    local directory = ensure_private_chain(runtime_dir, { "contexts" }, options.uid, deps)
    if not directory then
      return nil, "private context directory is unsafe"
    end
    local path = vim.fs.joinpath(directory, name)
    local created, _, _, owned = create_once(path, bytes, options.uid, deps, MAX_CONTEXT_BYTES)
    if created ~= "created" then
      -- A create-once collision is not ours to remove, even if fsync also failed.
      if owned and same_file(owned, deps.fs_lstat(path)) then
        remove_private_file(path, options.uid, deps)
      end
      -- A failed create may also leave an owned temporary file. The context
      -- owner must explicitly clean this directory before publishing again.
      return nil, "private context publication failed", created == nil
    end
    return path
  end

  function store:remove_context(path)
    if not context_path(path) then
      return nil, "private context path is invalid"
    end
    if not deps.fs_lstat(context_dir) then
      return true
    end
    return remove_private_file(path, options.uid, deps)
  end

  local function clean_contexts(keep, remove_directory)
    if keep ~= nil and not context_path(keep) then
      return nil, "retained context path is invalid"
    end
    local path = vim.fs.joinpath(runtime_dir, "contexts")
    local stat = deps.fs_lstat(path)
    if not stat then
      if keep then
        return nil, "retained context is unavailable or unsafe"
      end
      return true
    end
    local valid, validation_error = validate_directory(path, options.uid, false, deps)
    if not valid then
      return nil, validation_error
    end
    if keep and not file_metadata_safe(deps.fs_lstat(keep), options.uid) then
      return nil, "retained context is unavailable or unsafe"
    end
    local scanner, scan_error = deps.fs_scandir(path)
    if not scanner then
      return nil, "could not scan private contexts: " .. tostring(scan_error)
    end
    local entries = {}
    while true do
      local name, kind = deps.fs_scandir_next(scanner)
      if not name then
        break
      end
      local child = vim.fs.joinpath(path, name)
      local child_stat = deps.fs_lstat(child)
      if kind ~= "file" or not file_metadata_safe(child_stat, options.uid) then
        return nil, "refusing to remove an unsafe context entry: " .. child
      end
      if child ~= keep then
        entries[#entries + 1] = { path = child, stat = child_stat }
      end
    end
    for _, entry in ipairs(entries) do
      local current = deps.fs_lstat(entry.path)
      if not file_metadata_safe(current, options.uid) or not same_file(entry.stat, current) then
        return nil, "private context changed before cleanup"
      end
      local removed, remove_error = deps.fs_unlink(entry.path)
      if not removed then
        return nil, "could not remove private context: " .. tostring(remove_error)
      end
    end
    if remove_directory then
      local removed, remove_error = deps.fs_rmdir(path)
      if not removed then
        return nil, "could not remove private context directory: " .. tostring(remove_error)
      end
    end
    local parent_fd, open_error = deps.fs_open(remove_directory and runtime_dir or path, "r", 0)
    if not parent_fd then
      return nil, "could not open runtime directory for fsync: " .. tostring(open_error)
    end
    local synced, sync_error = deps.fs_fsync(parent_fd)
    deps.fs_close(parent_fd)
    if not synced then
      return nil, "runtime directory fsync failed: " .. tostring(sync_error)
    end
    return true
  end

  -- A running sandbox bind-mounts this directory inode. Remove files, not the
  -- mount source, when preparing, superseding, or rolling back live context.
  function store:prune_contexts(keep)
    return clean_contexts(keep, false)
  end

  -- The session coordinator calls this only after the owned pane is closed.
  function store:cleanup_contexts()
    return clean_contexts(nil, true)
  end

  return store
end

local default_dependencies = {
  fs_lstat = vim.uv.fs_lstat,
  fs_stat = vim.uv.fs_stat,
  fs_realpath = vim.uv.fs_realpath,
  fs_mkdir = vim.uv.fs_mkdir,
  fs_open = vim.uv.fs_open,
  fs_fstat = vim.uv.fs_fstat,
  fs_read = vim.uv.fs_read,
  fs_write = vim.uv.fs_write,
  fs_fsync = vim.uv.fs_fsync,
  fs_close = vim.uv.fs_close,
  fs_link = vim.uv.fs_link,
  fs_rename = vim.uv.fs_rename,
  fs_unlink = vim.uv.fs_unlink,
  fs_scandir = vim.uv.fs_scandir,
  fs_scandir_next = vim.uv.fs_scandir_next,
  fs_rmdir = vim.uv.fs_rmdir,
  pid = vim.fn.getpid,
  hrtime = vim.uv.hrtime,
}

local function dependencies(options)
  local result = vim.tbl_extend("force", {}, default_dependencies)
  for name in pairs(default_dependencies) do
    if options[name] then
      result[name] = options[name]
    end
  end
  return result
end

local function open_for_test(options)
  options = options or {}
  if type(options.uid) ~= "number" then
    return nil, "current UID is unavailable"
  end
  return new_store(options, dependencies(options))
end

local function production_bases(uid, deps)
  local runtime_base
  if type(vim.env.XDG_RUNTIME_DIR) == "string" and vim.env.XDG_RUNTIME_DIR ~= "" then
    local runtime_ancestor, runtime_error = validate_user_ancestor(
      vim.fs.normalize(vim.env.XDG_RUNTIME_DIR),
      uid,
      PRIVATE_DIRECTORY_MODE,
      deps
    )
    if not runtime_ancestor then
      return nil, nil, runtime_error
    end
    runtime_base, runtime_error =
      ensure_private_chain(runtime_ancestor, { "draft.nvim" }, uid, deps)
    if not runtime_base then
      return nil, nil, runtime_error
    end
  else
    local tmp = deps.fs_realpath("/tmp")
    if tmp ~= "/tmp" then
      return nil, nil, "temporary runtime ancestor is not physical"
    end
    runtime_base = vim.fs.joinpath(tmp, "draft.nvim-" .. uid)
    local runtime_error
    runtime_base, runtime_error = validate_directory(runtime_base, uid, true, deps)
    if not runtime_base then
      return nil, nil, runtime_error
    end
  end

  local state_ancestor
  if type(vim.env.XDG_STATE_HOME) == "string" and vim.env.XDG_STATE_HOME ~= "" then
    state_ancestor =
      validate_user_ancestor(vim.fs.normalize(vim.env.XDG_STATE_HOME), uid, nil, deps)
    if not state_ancestor then
      return nil, nil, "XDG state ancestor is unsafe"
    end
  else
    if type(vim.env.HOME) ~= "string" or vim.env.HOME == "" then
      return nil, nil, "HOME is unavailable"
    end
    local home, home_error = validate_user_ancestor(vim.fs.normalize(vim.env.HOME), uid, nil, deps)
    if not home then
      return nil, nil, home_error
    end
    local ancestor_error
    state_ancestor, ancestor_error = ensure_user_path(home, { ".local", "state" }, uid, deps)
    if not state_ancestor then
      return nil, nil, ancestor_error
    end
  end
  local state_base, state_error = ensure_private_chain(state_ancestor, { "draft.nvim" }, uid, deps)
  if not state_base then
    return nil, nil, state_error
  end
  return runtime_base, state_base
end

function M.open(identity)
  local uid = vim.uv.getuid()
  if type(uid) ~= "number" then
    return nil, "current UID is unavailable"
  end
  local deps = dependencies({})
  local runtime_base, state_base, base_error = production_bases(uid, deps)
  if not runtime_base then
    return nil, base_error
  end
  return new_store({
    identity = identity,
    runtime_base = runtime_base,
    state_base = state_base,
    uid = uid,
  }, deps)
end

M._test = { open = open_for_test }

return M
