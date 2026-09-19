local function eq(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    string.format("%s\nexpected: %s\nactual: %s", label, vim.inspect(expected), vim.inspect(actual))
  )
end

local function rejected(value, err, needle, label)
  eq(value, nil, label)
  assert(
    tostring(err):find(needle, 1, true),
    string.format("%s\nexpected error containing: %s\nactual: %s", label, needle, tostring(err))
  )
end

local function hex(value)
  return (value:gsub(".", function(byte)
    return string.format("%02x", string.byte(byte))
  end))
end

local function copy(value)
  return vim.deepcopy(value)
end

local roots = {}
local children = {}
local parent_descriptors = {}
local parent_descriptor_active = {}
local parent_descriptor_generations = {}
local parent_descriptor_live_reuse = 0
local suite_root
local suite_device
local suite_uid
local worktree
local root_sequence = 0

local function task7_exact_enoent(path)
  local stat, _, code = vim.uv.fs_lstat(path)
  return stat == nil and code == "ENOENT"
end

local function task7_directory_identity(path)
  local stat = vim.uv.fs_lstat(path)
  local physical = vim.uv.fs_realpath(path)
  if
    type(path) ~= "string"
    or type(physical) ~= "string"
    or type(stat) ~= "table"
    or stat.type ~= "directory"
  then
    return nil
  end
  return {
    path = path,
    physical = physical,
    dev = stat.dev,
    ino = stat.ino,
    uid = stat.uid,
    type = stat.type,
    mode = bit.band(stat.mode, 511),
  }
end

local function task7_same_directory_identity(expected, current, require_mode)
  return type(expected) == "table"
    and type(current) == "table"
    and expected.path == current.path
    and expected.physical == current.physical
    and expected.dev == current.dev
    and expected.ino == current.ino
    and expected.uid == current.uid
    and expected.type == current.type
    and (not require_mode or expected.mode == current.mode)
end

local function make_root(label)
  assert(type(suite_root) == "string", "suite root is unavailable")
  assert(type(label) == "string" and label:match("^[A-Za-z0-9%-]+$"), "test root label is invalid")
  root_sequence = root_sequence + 1
  local root = vim.fs.joinpath(suite_root, string.format("root-%04d-%s", root_sequence, label))
  assert(vim.fs.dirname(root) == suite_root, "test root escaped suite root")
  assert(task7_exact_enoent(root), "test root was not initially absent")
  local record = { path = root, pending = true }
  table.insert(roots, record)
  assert(vim.uv.fs_mkdir(root, 448) == true, "could not create test root")
  assert(vim.uv.fs_chmod(root, 448), "could not chmod test root")
  local identity = task7_directory_identity(root)
  assert(
    identity
      and identity.path == root
      and identity.physical == root
      and identity.dev == suite_device
      and identity.uid == suite_uid
      and identity.mode == 448,
    "test root identity is invalid"
  )
  for name, value in pairs(identity) do
    record[name] = value
  end
  record.pending = false
  return root
end

local function write_file(path, bytes, mode)
  assert(vim.fn.mkdir(vim.fs.dirname(path), "p", 448) >= 0, "could not create file parent")
  local fd = assert(vim.uv.fs_open(path, "w", mode or 384))
  local offset = 0
  while offset < #bytes do
    local written = assert(vim.uv.fs_write(fd, bytes:sub(offset + 1), offset))
    assert(written > 0, "short test write")
    offset = offset + written
  end
  assert(vim.uv.fs_close(fd))
  assert(vim.uv.fs_chmod(path, mode or 384))
end

local function run_serialization_child()
  if vim.env.AI_REVIEW_CHILD_MODE ~= "hold-serialization" then
    return false
  end

  local state_root = vim.env.AI_REVIEW_CHILD_STATE_ROOT
  local ready_path = vim.env.AI_REVIEW_CHILD_READY_PATH
  local release_path = vim.env.AI_REVIEW_CHILD_RELEASE_PATH
  assert(type(state_root) == "string" and state_root ~= "", "serialization child state missing")
  assert(type(ready_path) == "string" and ready_path ~= "", "serialization child ready missing")
  assert(
    type(release_path) == "string" and release_path ~= "",
    "serialization child release missing"
  )

  local acquire_ok, lease = pcall(function()
    return require("ai.review.serialization").acquire(state_root)
  end)
  assert(acquire_ok and lease ~= nil, "serialization child acquisition failed")

  local ready_ok = pcall(write_file, ready_path, "ready\n", 384)
  assert(ready_ok, "serialization child ready publication failed")

  local wait_ok, release_exists = pcall(function()
    return vim.wait(30000, function()
      return vim.uv.fs_lstat(release_path) ~= nil
    end, 10)
  end)
  assert(wait_ok and release_exists == true, "serialization child timed out")

  local release_ok, released, release_error = pcall(function()
    return lease:release()
  end)
  assert(
    release_ok and released == true and release_error == nil,
    "serialization child release failed"
  )
  return true
end

if run_serialization_child() then
  return
end

local function read_file(path)
  local stat = assert(vim.uv.fs_lstat(path))
  local fd = assert(vim.uv.fs_open(path, "r", 0))
  local bytes = assert(vim.uv.fs_read(fd, stat.size, 0))
  assert(vim.uv.fs_close(fd))
  return bytes
end

local function mode_bits(stat)
  return bit.band(stat.mode, 511)
end

local function assert_error_order(err, needles, label)
  local text = tostring(err)
  local offset = 1
  for _, needle in ipairs(needles) do
    local index = text:find(needle, offset, true)
    assert(index, string.format("%s: missing %s in %s", label, needle, text))
    offset = index + #needle
  end
end

local function assert_absent(path, label)
  local stat, stat_error, stat_code = vim.uv.fs_lstat(path)
  assert(
    not stat
      and (
        stat_code == "ENOENT"
        or tostring(stat_error):find("ENOENT", 1, true)
        or tostring(stat_error):find("no such file", 1, true)
      ),
    string.format("%s: absence was not proven: %s", label, tostring(stat_error))
  )
end

local function snapshot_tree(path)
  local root_stat = vim.uv.fs_lstat(path)
  if not root_stat then
    assert_absent(path, "snapshot root")
    return { { path = ".", type = "absent" } }
  end

  local snapshot = {}
  local function visit(entry_path, relative_path, stat)
    local item = {
      path = relative_path,
      type = stat.type,
      mode = mode_bits(stat),
      dev = stat.dev,
      ino = stat.ino,
      uid = stat.uid,
      size = stat.size,
      nlink = stat.nlink,
      mtime_sec = stat.mtime.sec,
      mtime_nsec = stat.mtime.nsec,
    }
    if stat.type == "file" then
      item.sha256 = vim.fn.sha256(read_file(entry_path))
    elseif stat.type == "link" then
      item.target = assert(vim.uv.fs_readlink(entry_path))
    end
    table.insert(snapshot, item)

    if stat.type ~= "directory" then
      return
    end

    local scanner = assert(vim.uv.fs_scandir(entry_path))
    local names = {}
    while true do
      local name, scan_error, scan_code = vim.uv.fs_scandir_next(scanner)
      if not name then
        if scan_error ~= nil or scan_code ~= nil then
          local bounded_code = scan_code
          if
            type(bounded_code) ~= "string"
            or #bounded_code > 24
            or not bounded_code:match("^E[A-Z0-9_]+$")
          then
            bounded_code = "UNKNOWN"
          end
          error("snapshot scan failed: " .. bounded_code, 0)
        end
        break
      end
      table.insert(names, name)
    end
    table.sort(names)
    for _, name in ipairs(names) do
      local child_path = vim.fs.joinpath(entry_path, name)
      local child_relative = relative_path == "." and name or relative_path .. "/" .. name
      visit(child_path, child_relative, assert(vim.uv.fs_lstat(child_path)))
    end
  end

  visit(path, ".", root_stat)
  table.sort(snapshot, function(left, right)
    return left.path < right.path
  end)
  return snapshot
end

local function tracked_open_close_dependencies(options)
  options = options or {}
  local descriptors = {}
  local lifetimes = {}
  local generations = {}
  local dependencies = {}

  dependencies.open = function(path, flags, mode)
    local fd, open_error, open_code = vim.uv.fs_open(path, flags, mode)
    if fd ~= nil then
      generations[fd] = (generations[fd] or 0) + 1
      local descriptor = {
        fd = fd,
        generation = generations[fd],
        path = path,
        open_succeeded = true,
        close_attempts = 0,
        active = true,
      }
      descriptors[fd] = descriptor
      table.insert(lifetimes, descriptor)
    end
    return fd, open_error, open_code
  end

  dependencies.close = function(fd)
    local descriptor = assert(descriptors[fd], "close attempted for an untracked descriptor")
    descriptor.close_attempts = descriptor.close_attempts + 1
    local closed, close_error, close_code = vim.uv.fs_close(fd)
    descriptor.physical_close = closed
    descriptor.physical_close_error = close_error
    descriptor.physical_close_code = close_code
    if closed == true then
      descriptor.active = false
    end
    if not closed then
      return closed, close_error, close_code
    end

    local injected_error
    local injected_code
    if type(options.close_error) == "function" then
      injected_error, injected_code = options.close_error(fd, descriptor)
    elseif options.close_error ~= nil then
      injected_error = options.close_error
      injected_code = options.close_code
    end
    if injected_error ~= nil then
      return nil, injected_error, injected_code or "EIO"
    end
    return closed
  end

  return dependencies, descriptors, lifetimes
end

local TASK7_MARKER = "AI review assertions: ok"
local TASK7_STREAM_LIMIT = 4096

local function task7_validate_private_directory(path, expected_device)
  local identity = task7_directory_identity(path)
  if
    not identity
    or identity.path ~= path
    or identity.physical ~= path
    or identity.uid ~= suite_uid
    or identity.mode ~= 448
    or (expected_device ~= nil and identity.dev ~= expected_device)
  then
    return nil
  end
  return identity
end

local function task7_initialize_main_environment()
  local supplied_root = vim.env.AI_REVIEW_TEST_ROOT
  local supplied_worktree =
    vim.fs.dirname(vim.fs.dirname(vim.uv.fs_realpath(debug.getinfo(1, "S").source:sub(2))))
  local supplied_platform = vim.env.AI_REVIEW_NATIVE_PLATFORM
  assert(type(supplied_root) == "string" and supplied_root ~= "", "suite root is missing")
  assert(type(supplied_worktree) == "string" and supplied_worktree ~= "", "worktree is missing")
  assert(
    type(supplied_platform) == "string" and supplied_platform ~= "",
    "native platform is missing"
  )
  assert(supplied_root:sub(1, 1) == "/", "suite root is not absolute")
  assert(supplied_worktree:sub(1, 1) == "/", "worktree is not absolute")
  assert(vim.fs.normalize(supplied_root) == supplied_root, "suite root is not normalized")
  assert(vim.fs.normalize(supplied_worktree) == supplied_worktree, "worktree is not normalized")
  assert(#roots == 0, "suite root was not registered first")

  local uid = vim.uv.getuid()
  assert(type(uid) == "number", "current uid is unavailable")
  local root_identity = task7_directory_identity(supplied_root)
  assert(
    root_identity
      and root_identity.physical == supplied_root
      and root_identity.uid == uid
      and root_identity.mode == 448,
    "suite root identity is invalid"
  )

  local scanner = assert(vim.uv.fs_scandir(supplied_root), "suite root scan failed")
  local first_name, scan_error, scan_code = vim.uv.fs_scandir_next(scanner)
  assert(
    first_name == nil and scan_error == nil and scan_code == nil,
    "suite root was not initially empty"
  )

  local worktree_identity = task7_directory_identity(supplied_worktree)
  assert(
    worktree_identity
      and worktree_identity.physical == supplied_worktree
      and supplied_worktree ~= supplied_root
      and supplied_worktree:sub(1, #supplied_root + 1) ~= supplied_root .. "/"
      and supplied_root:sub(1, #supplied_worktree + 1) ~= supplied_worktree .. "/"
      and (worktree_identity.dev ~= root_identity.dev or worktree_identity.ino ~= root_identity.ino),
    "worktree identity is invalid"
  )
  assert(
    type(vim.v.progpath) == "string" and vim.v.progpath:sub(1, 1) == "/",
    "Neovim executable is not absolute"
  )

  suite_root = supplied_root
  suite_device = root_identity.dev
  suite_uid = uid
  worktree = supplied_worktree
  table.insert(roots, root_identity)
end

local function task7_make_private_directory(path)
  assert(path:sub(1, #suite_root + 1) == suite_root .. "/", "private directory escaped suite root")
  assert(task7_exact_enoent(path), "private directory was not initially absent")
  assert(vim.fn.mkdir(path, "p", 448) == 1, "private directory creation failed")
  assert(vim.uv.fs_chmod(path, 448) == true, "private directory mode failed")
  assert(
    task7_validate_private_directory(path, suite_device),
    "private directory identity is invalid"
  )
end

local function task7_new_stream()
  return {
    total = 0,
    retained = "",
    tail = "",
    marker = false,
    callback_error = false,
    eof = false,
  }
end

local function task7_stream_callback(stream)
  return function(err, data)
    local ok = pcall(function()
      if err ~= nil then
        stream.callback_error = true
      end
      if data == nil then
        stream.eof = true
        return
      end
      if type(data) ~= "string" then
        stream.callback_error = true
        return
      end
      stream.total = math.min(TASK7_STREAM_LIMIT + 1, stream.total + #data)
      local remaining = TASK7_STREAM_LIMIT - #stream.retained
      if remaining > 0 then
        stream.retained = stream.retained .. data:sub(1, remaining)
      end
      local joined = stream.tail .. data
      if joined:find(TASK7_MARKER, 1, true) then
        stream.marker = true
      end
      local keep = math.max(#TASK7_MARKER - 1, 0)
      stream.tail = keep == 0 and "" or joined:sub(-keep)
    end)
    if not ok then
      stream.callback_error = true
    end
  end
end

local function task7_register_parent_descriptor(fd, kind)
  if parent_descriptor_active[fd] ~= nil then
    parent_descriptor_live_reuse = parent_descriptor_live_reuse + 1
  end
  local generation = (parent_descriptor_generations[fd] or 0) + 1
  parent_descriptor_generations[fd] = generation
  local record = {
    fd = fd,
    kind = kind,
    generation = generation,
    active = true,
    close_attempts = 0,
    physical_closes = 0,
    final_fstat_exact = false,
  }
  parent_descriptor_active[fd] = record
  table.insert(parent_descriptors, record)
  return record
end

local function task7_close_parent_descriptor(record)
  if record.active ~= true or record.close_attempts ~= 0 then
    return false
  end
  record.close_attempts = 1
  local close_ok, closed = pcall(vim.uv.fs_close, record.fd)
  if not close_ok or closed ~= true then
    return false
  end
  record.physical_closes = 1
  record.active = false
  if parent_descriptor_active[record.fd] == record then
    parent_descriptor_active[record.fd] = nil
  end
  local fstat_ok, final_stat, _, final_code = pcall(vim.uv.fs_fstat, record.fd)
  record.final_fstat_exact = fstat_ok and final_stat == nil and final_code == "EBADF"
  return record.final_fstat_exact
end

local function task7_ready_exact(path)
  local before = vim.uv.fs_lstat(path)
  if
    type(before) ~= "table"
    or before.type ~= "file"
    or before.uid ~= suite_uid
    or before.dev ~= suite_device
    or bit.band(before.mode, 511) ~= 384
    or before.size ~= 6
  then
    return false
  end
  local fd = vim.uv.fs_open(path, "r", 0)
  if fd == nil then
    return false
  end
  local descriptor = task7_register_parent_descriptor(fd, "ready")
  local current = vim.uv.fs_fstat(fd)
  local bytes = current and vim.uv.fs_read(fd, 6, 0) or nil
  local after = vim.uv.fs_lstat(path)
  local physical = vim.uv.fs_realpath(path)
  local closed = task7_close_parent_descriptor(descriptor)
  return closed
    and type(current) == "table"
    and type(after) == "table"
    and current.type == "file"
    and after.type == "file"
    and current.dev == before.dev
    and after.dev == before.dev
    and current.ino == before.ino
    and after.ino == before.ino
    and current.uid == before.uid
    and after.uid == before.uid
    and bit.band(current.mode, 511) == 384
    and bit.band(after.mode, 511) == 384
    and current.size == 6
    and after.size == 6
    and physical == path
    and bytes == "ready\n"
end

local function task7_spawn_holder(state_root, control_root, label)
  assert(task7_validate_private_directory(state_root, suite_device), "holder state root is invalid")
  assert(task7_validate_private_directory(control_root, suite_device), "control root is invalid")
  local child_home = make_root(label .. "-home")
  local xdg_config = vim.fs.joinpath(child_home, ".config")
  local xdg_local = vim.fs.joinpath(child_home, ".local")
  local xdg_data = vim.fs.joinpath(xdg_local, "share")
  local xdg_state = vim.fs.joinpath(xdg_local, "state")
  local xdg_cache = vim.fs.joinpath(child_home, ".cache")
  for _, path in ipairs({ xdg_config, xdg_local, xdg_data, xdg_state, xdg_cache }) do
    task7_make_private_directory(path)
  end

  local ready_path = vim.fs.joinpath(control_root, "ready")
  local release_path = vim.fs.joinpath(control_root, "release")
  assert(vim.fs.dirname(ready_path) == control_root, "ready marker escaped control root")
  assert(vim.fs.dirname(release_path) == control_root, "release marker escaped control root")
  assert(task7_exact_enoent(ready_path), "ready marker was not initially absent")
  assert(task7_exact_enoent(release_path), "release marker was not initially absent")

  local entry = {
    stdout = task7_new_stream(),
    stderr = task7_new_stream(),
    ready_path = ready_path,
    release_path = release_path,
    scenario_wait_attempted = false,
    finalizer_wait_attempted = false,
    kill_attempted = false,
    finalizer_kill_attempted = false,
  }
  local child = vim.system({
    vim.v.progpath,
    "--clean",
    "--headless",
    "-u",
    "NONE",
    "-i",
    "NONE",
    "--cmd",
    "lua vim.opt.rtp:prepend(" .. string.format("%q", worktree) .. ")",
    "-l",
    vim.fs.joinpath(worktree, "tests/ai_review.lua"),
  }, {
    clear_env = true,
    env = {
      HOME = child_home,
      XDG_CONFIG_HOME = xdg_config,
      XDG_DATA_HOME = xdg_data,
      XDG_STATE_HOME = xdg_state,
      XDG_CACHE_HOME = xdg_cache,
      NVIM_LOG_FILE = "/dev/null",
      AI_REVIEW_CHILD_MODE = "hold-serialization",
      AI_REVIEW_CHILD_STATE_ROOT = state_root,
      AI_REVIEW_CHILD_READY_PATH = ready_path,
      AI_REVIEW_CHILD_RELEASE_PATH = release_path,
      AI_REVIEW_TEST_ROOT = suite_root,
      AI_REVIEW_WORKTREE = worktree,
    },
    stdout = task7_stream_callback(entry.stdout),
    stderr = task7_stream_callback(entry.stderr),
    text = false,
  })
  entry.handle = child
  table.insert(children, entry)
  return entry
end

local function task7_wait_ready(entry)
  return vim.wait(30000, function()
    return task7_ready_exact(entry.ready_path)
  end, 10) == true
end

local function task7_process_closed(entry)
  local ok, closing = pcall(entry.handle.is_closing, entry.handle)
  return ok and closing == true
end

local function task7_complete_result(entry)
  local result = entry.result
  return type(result) == "table"
    and type(result.code) == "number"
    and result.code % 1 == 0
    and type(result.signal) == "number"
    and result.signal % 1 == 0
    and result.code ~= 124
    and entry.stdout.callback_error == false
    and entry.stderr.callback_error == false
    and entry.stdout.eof == true
    and entry.stderr.eof == true
    and task7_process_closed(entry)
end

local function task7_save_child_result(entry, result)
  entry.last_result = result
  if
    type(result) ~= "table"
    or type(result.code) ~= "number"
    or result.code % 1 ~= 0
    or type(result.signal) ~= "number"
    or result.signal % 1 ~= 0
    or result.code == 124
  then
    return false
  end
  entry.result = result
  if task7_complete_result(entry) then
    return true
  end
  entry.result = nil
  return false
end

local function task7_wait_child(entry, finalizer)
  if finalizer then
    if entry.finalizer_wait_attempted then
      return false
    end
    entry.finalizer_wait_attempted = true
  else
    if entry.scenario_wait_attempted then
      return false
    end
    entry.scenario_wait_attempted = true
  end
  local wait_ok, result = pcall(entry.handle.wait, entry.handle, 5000)
  return wait_ok and task7_save_child_result(entry, result)
end

local function task7_zero_output(entry)
  return entry.stdout.total == 0
    and entry.stderr.total == 0
    and entry.stdout.retained == ""
    and entry.stderr.retained == ""
    and entry.stdout.marker == false
    and entry.stderr.marker == false
end

local function task7_release_holder(entry)
  if entry.release_written or entry.scenario_wait_attempted then
    return false
  end
  write_file(entry.release_path, "release\n", 384)
  entry.release_written = true
  return task7_wait_child(entry, false)
end

local function task7_kill_holder(entry)
  if entry.kill_attempted or entry.scenario_wait_attempted then
    return false
  end
  entry.kill_attempted = true
  local killed = pcall(entry.handle.kill, entry.handle, 9)
  return killed and task7_wait_child(entry, false)
end

local function task7_open_parent_descriptor(path)
  local path_identity = task7_directory_identity(path)
  if not path_identity then
    return nil
  end
  local fd = vim.uv.fs_open(path, "r", 0)
  if fd == nil then
    return nil
  end
  local record = task7_register_parent_descriptor(fd, "lock")
  record.path_identity = path_identity
  local stat = vim.uv.fs_fstat(fd)
  record.identity = stat
      and {
        dev = stat.dev,
        ino = stat.ino,
        uid = stat.uid,
        type = stat.type,
        mode = bit.band(stat.mode, 511),
      }
    or nil
  record.identity_exact = record.identity
    and record.identity.dev == path_identity.dev
    and record.identity.ino == path_identity.ino
    and record.identity.uid == path_identity.uid
    and record.identity.type == "directory"
    and record.identity.mode == 448
  return record
end

local function task7_parent_descriptor_matches(record)
  local stat = vim.uv.fs_fstat(record.fd)
  return type(stat) == "table"
    and type(record.identity) == "table"
    and stat.dev == record.identity.dev
    and stat.ino == record.identity.ino
    and stat.uid == record.identity.uid
    and stat.type == record.identity.type
    and bit.band(stat.mode, 511) == record.identity.mode
end

local function task7_parent_path_matches(record)
  return task7_same_directory_identity(
    record.path_identity,
    task7_directory_identity(record.path_identity.path),
    true
  )
end

local function task7_finalize_children(failures)
  local exact = true
  for _, entry in ipairs(children) do
    if not task7_complete_result(entry) then
      if not entry.finalizer_kill_attempted then
        entry.finalizer_kill_attempted = true
        pcall(entry.handle.kill, entry.handle, 9)
      end
      if not entry.finalizer_wait_attempted then
        task7_wait_child(entry, true)
      end
    end
    if not task7_complete_result(entry) then
      exact = false
      table.insert(failures, "child process was not conclusively reaped")
    end
  end
  return exact
end

local function task7_finalize_descriptors(failures)
  local exact = parent_descriptor_live_reuse == 0
  if not exact then
    table.insert(failures, "parent descriptor generation was reused while active")
  end
  for _, record in ipairs(parent_descriptors) do
    if record.active and record.close_attempts == 0 then
      task7_close_parent_descriptor(record)
    end
    if
      record.active
      or record.close_attempts ~= 1
      or record.physical_closes ~= 1
      or record.final_fstat_exact ~= true
    then
      exact = false
      table.insert(failures, "parent descriptor closure was not exact")
    end
  end
  return exact
end

local function task7_scan_empty(path)
  local scanner = vim.uv.fs_scandir(path)
  if scanner == nil then
    return false
  end
  local name, scan_error, scan_code = vim.uv.fs_scandir_next(scanner)
  return name == nil and scan_error == nil and scan_code == nil
end

local function task7_finalize_roots(failures)
  if type(roots[1]) ~= "table" or roots[1].path ~= suite_root or roots[1].pending then
    table.insert(failures, "suite root was not registered first")
    return false
  end

  local states = {}
  for index = #roots, 1, -1 do
    local record = roots[index]
    if record.pending then
      table.insert(failures, "registered root identity is incomplete")
      return false
    end
    local current = task7_directory_identity(record.path)
    if current then
      local require_mode = index == 1
      if not task7_same_directory_identity(record, current, require_mode) then
        table.insert(failures, "registered root identity changed")
        return false
      end
      states[index] = "present"
    elseif index == 1 or not task7_exact_enoent(record.path) then
      table.insert(failures, "registered root state is invalid")
      return false
    else
      states[index] = "absent"
    end
  end

  for index = #roots, 2, -1 do
    local record = roots[index]
    if states[index] == "present" then
      local invoked, result = pcall(vim.fn.delete, record.path, "rf")
      if not invoked or result ~= 0 or not task7_exact_enoent(record.path) then
        table.insert(failures, "registered descendant cleanup failed")
        return false
      end
    end
  end

  if
    not task7_same_directory_identity(roots[1], task7_directory_identity(suite_root), true)
    or not task7_scan_empty(suite_root)
  then
    table.insert(failures, "suite root was not empty after descendant cleanup")
    return false
  end
  if vim.uv.fs_rmdir(suite_root) ~= true or not task7_exact_enoent(suite_root) then
    table.insert(failures, "suite root cleanup failed")
    return false
  end
  return true
end

local git_executable = assert(require("ai.tools").resolve("git"))

local function command(argv, options)
  options = options or {}
  local result = vim
    .system(argv, {
      clear_env = true,
      env = options.env,
      stdin = options.stdin,
      text = false,
    })
    :wait(30000)
  assert(result.code ~= 124, "test command timed out")
  return result
end

local Fixture = {}
Fixture.__index = Fixture

function Fixture.new(label, initialize)
  local base = make_root(label)
  local root = vim.fs.joinpath(base, "repo")
  local state = vim.fs.joinpath(base, "state")
  assert(vim.fn.mkdir(root, "p", 448) == 1)
  assert(vim.fn.mkdir(state, "p", 448) == 1)
  assert(vim.uv.fs_chmod(root, 448))
  assert(vim.uv.fs_chmod(state, 448))
  assert(
    task7_validate_private_directory(root, suite_device),
    "fixture repository identity is invalid"
  )
  assert(task7_validate_private_directory(state, suite_device), "fixture state identity is invalid")
  local self = setmetatable({ base = base, root = root, state = state }, Fixture)
  if initialize ~= false then
    self:git({ "init", "--quiet" })
    self:git({ "config", "user.name", "AI Review Test" })
    self:git({ "config", "user.email", "ai-review@example.invalid" })
    self:git({ "config", "commit.gpgsign", "false" })
    self:git({ "config", "core.autocrlf", "false" })
  end
  return self
end

function Fixture:environment()
  return {
    HOME = self.base,
    LC_ALL = "C",
    LANG = "C",
    GIT_CONFIG_NOSYSTEM = "1",
    GIT_CONFIG_GLOBAL = "/dev/null",
    GIT_CONFIG_COUNT = "0",
  }
end

function Fixture:git(args, stdin, allow_failure)
  local argv = { git_executable, "-C", self.root }
  vim.list_extend(argv, args)
  local result = command(argv, { env = self:environment(), stdin = stdin })
  if not allow_failure then
    assert(
      result.code == 0 and result.signal == 0,
      string.format(
        "fixture Git failed: %s\nstdout: %s\nstderr: %s",
        vim.inspect(args),
        tostring(result.stdout),
        tostring(result.stderr)
      )
    )
  end
  return result
end

function Fixture:path(path)
  return vim.fs.joinpath(self.root, path)
end

function Fixture:write(path, bytes, mode)
  write_file(self:path(path), bytes, mode)
end

function Fixture:unlink(path)
  local ok, err = vim.uv.fs_unlink(self:path(path))
  assert(ok, tostring(err))
end

function Fixture:symlink(path, target)
  assert(vim.fn.mkdir(vim.fs.dirname(self:path(path)), "p", 448) >= 0)
  assert(vim.uv.fs_symlink(target, self:path(path)))
end

function Fixture:commit(message)
  self:git({ "add", "--all" })
  self:git({ "commit", "--quiet", "-m", message })
end

function Fixture:status_bytes()
  return self:git({ "status", "--porcelain=v1", "-z", "--untracked-files=all" }).stdout
end

function Fixture:object_count()
  return self:git({ "count-objects", "-v" }).stdout
end

function Fixture:identity(inside_git)
  if inside_git == false then
    return {
      key = string.rep("e", 32),
      root = self.root,
      inside_git = false,
      namespace = "nvim:test-plain",
    }
  end
  local git_dir = self:git({ "rev-parse", "--absolute-git-dir" }).stdout:gsub("\n$", "")
  local git_common_dir =
    self:git({ "rev-parse", "--path-format=absolute", "--git-common-dir" }).stdout:gsub("\n$", "")
  return {
    key = string.rep("d", 32),
    root = self.root,
    inside_git = true,
    git_dir = git_dir,
    git_common_dir = git_common_dir,
    git_entry = vim.fs.joinpath(self.root, ".git"),
    namespace = "nvim:test-git",
  }
end

function Fixture:store()
  local state = self.state
  return {
    state_dir = function()
      return state
    end,
    review_dir = function(_, review_id)
      assert(review_id:match("^[0-9a-f]+$"), "invalid test review id")
      local reviews = vim.fs.joinpath(state, "reviews")
      local path = vim.fs.joinpath(reviews, review_id)
      assert(vim.fn.mkdir(path, "p", 448) >= 0)
      assert(vim.uv.fs_chmod(reviews, 448))
      assert(vim.uv.fs_chmod(path, 448))
      return path
    end,
  }
end

local function copied_object_path(fixture, baseline, path)
  local storage = assert(baseline:read(path).storage)
  local name = assert(storage:match("^copy:([0-9a-f]+)$"))
  return vim.fs.joinpath(fixture.state, "reviews", baseline:id(), "objects", name)
end

local function manifest_path(fixture, baseline)
  return vim.fs.joinpath(fixture.state, "reviews", baseline:id(), "manifest.json")
end

local function review_entries(fixture)
  local reviews = vim.fs.joinpath(fixture.state, "reviews")
  if not vim.uv.fs_lstat(reviews) then
    return {}
  end
  local entries = vim.fn.readdir(reviews)
  table.sort(entries)
  return entries
end

local function object(value, options)
  options = options or {}
  if options.kind == "absent" or options.kind == "unsupported" then
    return {
      kind = options.kind,
      mode = nil,
      size = 0,
      sha256 = nil,
      storage = nil,
      tree_oid = nil,
    }
  end
  local kind = options.kind or "regular"
  local bytes = value or ""
  return {
    kind = kind,
    mode = options.mode or (kind == "symlink" and "120000" or "100644"),
    size = #bytes,
    sha256 = vim.fn.sha256(bytes),
    storage = options.storage,
    tree_oid = options.tree_oid,
  }
end

local function entry(value, options)
  options = options or {}
  local item = object(value, options)
  return {
    object = item,
    hash = vim.fn.sha256(table.concat({
      item.kind,
      item.mode or "",
      tostring(item.size),
      item.sha256 or "",
    }, "\0")),
    binary = type(value) == "string" and value:find("\0", 1, true) ~= nil or false,
  }
end

local function fake_baseline(paths, ignored, conflict_only)
  paths = paths or {}
  ignored = ignored or {}
  local manifest_paths = {}
  local manifest_ignored = {}
  for path, item in pairs(paths) do
    table.insert(manifest_paths, { path_hex = hex(path), object = copy(item.object or item) })
  end
  for path, item in pairs(ignored) do
    table.insert(
      manifest_ignored,
      { path_hex = hex(path), fingerprint = copy(item.object or item) }
    )
  end
  table.sort(manifest_paths, function(left, right)
    return left.path_hex < right.path_hex
  end)
  table.sort(manifest_ignored, function(left, right)
    return left.path_hex < right.path_hex
  end)
  local removed = 0
  return {
    id = function()
      return string.rep("f", 32)
    end,
    manifest = function()
      return {
        schema = 1,
        conflict_only = conflict_only == true,
        paths = copy(manifest_paths),
        ignored = copy(manifest_ignored),
      }
    end,
    read = function(_, path)
      local item = paths[path]
      return item and copy(item.object or item) or nil
    end,
    fingerprint = function(_, path)
      local item = paths[path]
      return item and copy(item.object or item) or nil
    end,
    ignored_fingerprint = function(_, path)
      local item = ignored[path]
      return item and copy(item.object or item) or nil
    end,
    bytes = function(_, path)
      local item = paths[path]
      return item and item.bytes or nil
    end,
    remove = function()
      removed = removed + 1
      return true
    end,
    remove_count = function()
      return removed
    end,
  }
end

local function created_baseline_module(active_baseline, decode_hex)
  return {
    create = function()
      return active_baseline
    end,
    _internal = {
      decode_hex = decode_hex,
    },
  }
end

local function inert_handle(start_result, stop_error)
  local handle = { closing = false }
  function handle:start(_, _, callback)
    self.callback = callback
    return start_result
  end
  function handle:stop()
    self.stop_attempted = true
    if stop_error then
      error(stop_error)
    end
    return true
  end
  function handle:close()
    self.close_attempted = true
    self.closing = true
    return true
  end
  function handle:is_closing()
    return self.closing
  end
  function handle:unref()
    return true
  end
  return handle
end

local function run()
  local serialization = require("ai.review.serialization")
  local baseline_module = require("ai.review.baseline")
  local tracker_module = require("ai.review.tracker")
  eq(
    vim.uv.os_uname().sysname,
    assert(vim.env.AI_REVIEW_NATIVE_PLATFORM),
    "native platform evidence"
  )
  task7_initialize_main_environment()

  do
    local reducer = require("ai.review.reducer")
    local base = "one\ntwo\nthree\nfour\n"
    local current = "one\nTWO\nthree\nFOUR\n"
    local hunks = assert(reducer.hunks(base, current))
    eq(hunks, {
      { base_start = 2, base_count = 1, current_start = 2, current_count = 1 },
      { base_start = 4, base_count = 1, current_start = 4, current_count = 1 },
    }, "two independent zero-context hunks")
    local accepted_base = assert(reducer.accept_hunk(base, current, 1))
    eq(accepted_base, "one\nTWO\nthree\nfour\n", "accept records bytes without changing current")
    eq(#reducer.hunks(accepted_base, current), 1, "accepted hunk leaves one unresolved")
    local rejected_current = assert(reducer.reject_hunk(accepted_base, current, 1))
    eq(rejected_current, accepted_base, "reject remaining hunk restores decision base")
    eq(#reducer.hunks(accepted_base, rejected_current), 0, "all hunks resolved")
    eq(reducer.reject_hunk(base, current, 99), nil, "invalid hunk refused")
    for _, pair in ipairs({
      { "", "created without newline" },
      { "deleted without newline", "" },
      { "a\nb\n", "a\ninserted\nb\n" },
      { "a\ndeleted\nb\n", "a\nb\n" },
      { "café\n", "CAFE\n" },
      { "a\nb\n", "A\nB\n" },
      { "tail\n", "first\ntail\n" },
      { "a\nlast", "a\n" },
      { "first\r\nlast\r\n", "FIRST\r\nlast\r\n" },
      { "last", "last\n" },
      { "last\n", "last" },
    }) do
      eq(#assert(reducer.hunks(pair[1], pair[2])), 1, "fixture has one exact hunk")
      eq(assert(reducer.reject_hunk(pair[1], pair[2], 1)), pair[1], "byte-exact inverse")
      eq(assert(reducer.accept_hunk(pair[1], pair[2], 1)), pair[2], "byte-exact acceptance")
    end
    for _, binary in ipairs({
      "a\0b",
      "\255",
      "\192\128",
      "\237\160\128",
      "\244\144\128\128",
      "\226\130",
    }) do
      assert(
        not reducer.is_text(binary),
        "binary or malformed UTF-8 is routed to whole-file review"
      )
      assert(not reducer.hunks("text", binary), "binary current is refused by the reducer")
      assert(not reducer.hunks(binary, "text"), "binary baseline is refused by the reducer")
    end
    assert(
      reducer.is_text("café e\204\129 🙂\r\n"),
      "valid multibyte text is accepted without normalization"
    )
  end

  do
    local state_root = make_root("serialization-scan-failure")
    local injected_scan_failure = function()
      return nil, "injected scan failure", "EIO"
    end
    local accepted_failures = {}

    local dependencies = tracked_open_close_dependencies()
    dependencies.scandir_next = injected_scan_failure
    local lease, acquire_error = serialization.acquire(state_root, dependencies)
    if lease then
      local released, release_error = lease:release()
      assert(released, tostring(release_error))
      assert_absent(
        vim.fs.joinpath(state_root, ".baseline-serialization"),
        "serialization scan failure lock release"
      )
      table.insert(accepted_failures, "serialization.acquire accepted injected scan failure")
    elseif acquire_error ~= "baseline serialization acquisition failed: scan-lock (EIO)" then
      table.insert(
        accepted_failures,
        "serialization.acquire returned the wrong injected scan failure error"
      )
    end

    write_file(vim.fs.joinpath(state_root, "snapshot-child"), "snapshot\n")
    local original_scandir_next = vim.uv.fs_scandir_next
    local snapshot_scan_calls = 0
    local snapshot_scan_failure = function()
      snapshot_scan_calls = snapshot_scan_calls + 1
      return nil, "injected scan failure", "EIO"
    end
    local snapshot_ok
    local snapshot_error
    local guarded_ok, guarded_error = xpcall(function()
      vim.uv.fs_scandir_next = snapshot_scan_failure
      snapshot_ok, snapshot_error = xpcall(function()
        return snapshot_tree(state_root)
      end, debug.traceback)
    end, debug.traceback)
    vim.uv.fs_scandir_next = original_scandir_next
    assert(
      vim.uv.fs_scandir_next == original_scandir_next,
      "snapshot scan failure did not restore fs_scandir_next"
    )
    if not guarded_ok then
      table.insert(
        accepted_failures,
        "snapshot_tree scan guard raised an unrelated error: " .. tostring(guarded_error)
      )
    end
    if snapshot_scan_calls == 0 then
      table.insert(accepted_failures, "snapshot_tree did not call the injected scan failure")
    elseif snapshot_scan_calls > 1 then
      table.insert(
        accepted_failures,
        "snapshot_tree called the injected scan failure more than once"
      )
    end
    if snapshot_ok then
      table.insert(accepted_failures, "snapshot_tree accepted injected scan failure")
    elseif not tostring(snapshot_error):find("snapshot scan failed: EIO", 1, true) then
      table.insert(accepted_failures, "snapshot_tree returned an unrelated scan failure error")
    end

    assert(
      #accepted_failures == 0,
      "scan failure rejection: " .. table.concat(accepted_failures, "; ")
    )
  end

  do
    local state_root = make_root("serialization-state-identity-drift")
    local lock_path = vim.fs.joinpath(state_root, ".baseline-serialization")
    local dependencies, descriptors = tracked_open_close_dependencies()
    local state_fstat_calls = 0

    dependencies.fstat = function(fd)
      local descriptor = assert(descriptors[fd], "fstat attempted for an untracked descriptor")
      if descriptor.path == state_root then
        state_fstat_calls = state_fstat_calls + 1
      end
      local stat, stat_error, stat_code = vim.uv.fs_fstat(fd)
      if stat and descriptor.path == state_root and state_fstat_calls == 2 then
        local drifted = copy(stat)
        drifted.ino = drifted.ino + 1
        return drifted
      end
      return stat, stat_error, stat_code
    end

    local lease, acquire_error = serialization.acquire(state_root, dependencies)
    assert(lease, tostring(acquire_error))
    local lock_before = snapshot_tree(lock_path)

    local release_value, release_error = lease:release()
    local lock_after = snapshot_tree(lock_path)
    local accepted_failures = {}

    if release_value ~= nil then
      table.insert(accepted_failures, "release succeeded")
    elseif
      release_error ~= "baseline serialization release failed: validate-state-root (UNKNOWN)"
    then
      table.insert(accepted_failures, "release returned the wrong state-root validation error")
    end

    if state_fstat_calls ~= 2 then
      table.insert(
        accepted_failures,
        string.format("state-root fstat calls expected 2 actual %d", state_fstat_calls)
      )
    end

    if #lock_after == 1 and lock_after[1].path == "." and lock_after[1].type == "absent" then
      table.insert(accepted_failures, "acquired lock absent after release identity failure")
    elseif not vim.deep_equal(lock_after, lock_before) then
      table.insert(accepted_failures, "acquired lock changed after release identity failure")
    end

    local descriptor_counts = {
      [state_root] = 0,
      [lock_path] = 0,
    }
    local descriptor_labels = {
      [state_root] = "state-root",
      [lock_path] = "lock",
    }
    for _, descriptor in pairs(descriptors) do
      local label = descriptor_labels[descriptor.path]
      if not label then
        table.insert(accepted_failures, "unexpected tracked descriptor path")
      else
        descriptor_counts[descriptor.path] = descriptor_counts[descriptor.path] + 1
        if descriptor.close_attempts ~= 1 then
          table.insert(
            accepted_failures,
            string.format(
              "%s physical close attempts expected 1 actual %d",
              label,
              descriptor.close_attempts
            )
          )
        end
        if descriptor.physical_close ~= true then
          table.insert(accepted_failures, label .. " descriptor was not physically closed")
        end
      end
    end
    for path, count in pairs(descriptor_counts) do
      if count ~= 1 then
        table.insert(
          accepted_failures,
          string.format("%s descriptor count expected 1 actual %d", descriptor_labels[path], count)
        )
      end
    end

    assert(
      #accepted_failures == 0,
      "state-root identity release validation: " .. table.concat(accepted_failures, "; ")
    )
  end

  do
    local state_root = make_root("serialization-smoke")
    local dependencies, descriptors = tracked_open_close_dependencies()
    local lease, acquire_error = serialization.acquire(state_root, dependencies)
    assert(lease, tostring(acquire_error))

    local lock_path = vim.fs.joinpath(state_root, ".baseline-serialization")
    local lock_stat = assert(vim.uv.fs_lstat(lock_path))
    eq(lock_stat.type, "directory", "serialization smoke lock type")
    eq(mode_bits(lock_stat), 448, "serialization smoke lock mode")

    local released, release_error = lease:release()
    assert(released, tostring(release_error))
    assert_absent(lock_path, "serialization smoke lock release")

    local descriptor_count = 0
    for fd, descriptor in pairs(descriptors) do
      descriptor_count = descriptor_count + 1
      eq(descriptor.open_succeeded, true, "serialization descriptor open " .. tostring(fd))
      eq(descriptor.close_attempts, 1, "serialization descriptor close " .. tostring(fd))
      eq(
        descriptor.physical_close,
        true,
        "serialization descriptor physical close " .. tostring(fd)
      )
    end
    eq(descriptor_count, 2, "serialization smoke descriptor count")
  end

  do
    local fixed_error = "baseline serialization unavailable: lock exists (active or stale)"
    local current_error = "baseline serialization acquisition failed: mkdir-lock (EEXIST)"
    local injected_payload = "EEXIST: file already exists: /fixed/isq84/.baseline-serialization"
    local real_mkdir = vim.uv.fs_mkdir
    local cases = {
      { label = "native", kind = "native" },
      { label = "error-field-only", kind = "error-field-only" },
      { label = "code-field-only", kind = "code-field-only" },
    }
    local accepted_failures = {}
    local observations = {}

    for _, test_case in ipairs(cases) do
      local state_root = make_root("serialization-existing-lock-" .. test_case.label)
      local lock_path = vim.fs.joinpath(state_root, ".baseline-serialization")
      assert(vim.fn.mkdir(lock_path, "p", 448) == 1, "could not create existing lock")
      assert(vim.uv.fs_chmod(lock_path, 448), "could not chmod existing lock")
      local before = snapshot_tree(state_root)

      local dependencies, descriptors = tracked_open_close_dependencies()
      local tracked_open = dependencies.open
      local open_invocations = {
        [state_root] = 0,
        [lock_path] = 0,
      }
      local unexpected_open_paths = {}
      dependencies.open = function(path, flags, mode)
        if open_invocations[path] == nil then
          table.insert(unexpected_open_paths, path)
        else
          open_invocations[path] = open_invocations[path] + 1
        end
        return tracked_open(path, flags, mode)
      end
      local mkdir_calls = {}
      local native_delegates = 0
      local native_tuple
      dependencies.mkdir = function(path, mode)
        table.insert(mkdir_calls, { path = path, mode = mode })
        if test_case.kind == "native" then
          native_delegates = native_delegates + 1
          local created, create_error, create_code = real_mkdir(path, mode)
          native_tuple = {
            created = created,
            error = create_error,
            code = create_code,
          }
          return created, create_error, create_code
        elseif test_case.kind == "error-field-only" then
          return nil, injected_payload, nil
        end
        return nil, nil, "EEXIST"
      end

      local lease, acquire_error = serialization.acquire(state_root, dependencies)
      local returned_lease = lease ~= nil
      local release_observation = "none"
      if lease then
        local release_ok, release_value, release_error = pcall(lease.release, lease)
        if not release_ok then
          release_observation = "raised"
          table.insert(
            accepted_failures,
            test_case.label .. " defective lease release raised an error"
          )
        elseif release_value ~= true then
          release_observation = "failed"
          table.insert(
            accepted_failures,
            test_case.label .. " defective lease release failed: " .. tostring(release_error)
          )
        else
          release_observation = "released"
        end
      end
      if returned_lease then
        table.insert(accepted_failures, test_case.label .. " acquisition returned a lease")
      end

      for _, expected_open in ipairs({
        { path = state_root, label = "state-root" },
        { path = lock_path, label = "lock" },
      }) do
        if open_invocations[expected_open.path] ~= 1 then
          table.insert(
            accepted_failures,
            string.format(
              "%s %s open invocations expected 1 actual %d",
              test_case.label,
              expected_open.label,
              open_invocations[expected_open.path]
            )
          )
        end
      end
      if #unexpected_open_paths ~= 0 then
        table.insert(
          accepted_failures,
          string.format(
            "%s unexpected open invocations expected 0 actual %d",
            test_case.label,
            #unexpected_open_paths
          )
        )
      end

      local public_error = tostring(acquire_error)
      local error_observation = "other"
      if acquire_error == fixed_error then
        error_observation = "fixed-existing-lock"
      elseif acquire_error == current_error then
        error_observation = "mkdir-lock-EEXIST"
      end
      if acquire_error ~= fixed_error then
        table.insert(
          accepted_failures,
          test_case.label .. " fixed existing-lock classification missing: " .. error_observation
        )
      end

      local payload_absent = not public_error:find(injected_payload, 1, true)
      if not payload_absent then
        table.insert(
          accepted_failures,
          test_case.label .. " injected payload reached public result"
        )
      end

      if #mkdir_calls ~= 1 then
        table.insert(
          accepted_failures,
          string.format("%s mkdir calls expected 1 actual %d", test_case.label, #mkdir_calls)
        )
      end
      for _, mkdir_call in ipairs(mkdir_calls) do
        if mkdir_call.path ~= lock_path then
          table.insert(accepted_failures, test_case.label .. " mkdir used the wrong lock path")
        end
        if mkdir_call.mode ~= 448 then
          table.insert(accepted_failures, test_case.label .. " mkdir used the wrong mode")
        end
      end

      local native_eexist = native_tuple
        and native_tuple.created == nil
        and (
          native_tuple.code == "EEXIST"
          or tostring(native_tuple.error):find("EEXIST", 1, true) ~= nil
        )
      if test_case.kind == "native" then
        if native_delegates ~= 1 then
          table.insert(
            accepted_failures,
            string.format("native mkdir delegates expected 1 actual %d", native_delegates)
          )
        end
        if not native_eexist then
          table.insert(accepted_failures, "native mkdir did not return EEXIST")
        end
      end

      local descriptor_facts = {
        [state_root] = { label = "state-root", count = 0, attempts = 0, closed = true },
        [lock_path] = { label = "lock", count = 0, attempts = 0, closed = true },
      }
      for _, descriptor in pairs(descriptors) do
        local fact = descriptor_facts[descriptor.path]
        if not fact then
          table.insert(accepted_failures, test_case.label .. " tracked an unexpected descriptor")
        else
          fact.count = fact.count + 1
          fact.attempts = fact.attempts + descriptor.close_attempts
          fact.closed = fact.closed and descriptor.physical_close == true
          if descriptor.close_attempts ~= 1 then
            table.insert(
              accepted_failures,
              string.format(
                "%s %s close attempts expected 1 actual %d",
                test_case.label,
                fact.label,
                descriptor.close_attempts
              )
            )
          end
          if descriptor.physical_close ~= true then
            table.insert(
              accepted_failures,
              test_case.label .. " " .. fact.label .. " descriptor was not physically closed"
            )
          end
        end
      end
      for _, path in ipairs({ state_root, lock_path }) do
        local fact = descriptor_facts[path]
        if fact.count ~= 1 then
          table.insert(
            accepted_failures,
            string.format(
              "%s %s descriptor count expected 1 actual %d",
              test_case.label,
              fact.label,
              fact.count
            )
          )
        end
      end

      local after = snapshot_tree(state_root)
      local snapshot_unchanged = vim.deep_equal(after, before)
      if not snapshot_unchanged then
        table.insert(accepted_failures, test_case.label .. " state-root snapshot changed")
      end

      local state_fact = descriptor_facts[state_root]
      local lock_fact = descriptor_facts[lock_path]
      table.insert(
        observations,
        string.format(
          "%s error=%s mkdir=%d mode=%s native-delegates=%d opens=%d/%d/%d state=%d/%d/%s lock=%d/%d/%s snapshot=%s payload-absent=%s release=%s",
          test_case.label,
          error_observation,
          #mkdir_calls,
          tostring(mkdir_calls[1] and mkdir_calls[1].mode),
          native_delegates,
          open_invocations[state_root],
          open_invocations[lock_path],
          #unexpected_open_paths,
          state_fact.count,
          state_fact.attempts,
          tostring(state_fact.count > 0 and state_fact.closed),
          lock_fact.count,
          lock_fact.attempts,
          tostring(lock_fact.count > 0 and lock_fact.closed),
          tostring(snapshot_unchanged),
          tostring(payload_absent),
          release_observation
        )
      )
    end

    assert(
      #accepted_failures == 0,
      "existing lock classification: "
        .. table.concat(accepted_failures, "; ")
        .. " | observations: "
        .. table.concat(observations, "; ")
    )
  end

  do
    local malformed_state_root = "baseline serialization unavailable: malformed state root"
    local malformed_lock = "baseline serialization unavailable: malformed lock"
    local lstat_eio = "baseline serialization acquisition failed: lstat-lock (EIO)"
    local injected_payload = "injected EIO at /fixed/isq84/semantic/.baseline-serialization"
    local lock_name = ".baseline-serialization"
    local failures = {}
    local observations = {}
    local executed_cases = 0
    local native_lstat = vim.uv.fs_lstat
    local native_mkdir = vim.uv.fs_mkdir
    local native_fsync = vim.uv.fs_fsync
    local native_rmdir = vim.uv.fs_rmdir

    local function add_failure(label, detail)
      table.insert(failures, label .. " " .. detail)
    end

    local function expect_count(label, detail, actual, expected)
      if actual ~= expected then
        add_failure(label, string.format("%s expected %d actual %d", detail, expected, actual))
      end
    end

    local function make_directory(path, mode)
      assert(vim.fn.mkdir(path, "p", mode or 448) == 1, "could not create semantic directory")
      assert(vim.uv.fs_chmod(path, mode or 448), "could not chmod semantic directory")
    end

    local function make_symlink(target, path)
      assert(vim.uv.fs_symlink(target, path), "could not create semantic symlink")
    end

    local function relative_path(from, to)
      local from_parts = vim.split(vim.fs.normalize(from), "/", { plain = true, trimempty = true })
      local to_parts = vim.split(vim.fs.normalize(to), "/", { plain = true, trimempty = true })
      local common = 0
      while
        common < #from_parts
        and common < #to_parts
        and from_parts[common + 1] == to_parts[common + 1]
      do
        common = common + 1
      end

      local parts = {}
      for _ = common + 1, #from_parts do
        table.insert(parts, "..")
      end
      for index = common + 1, #to_parts do
        table.insert(parts, to_parts[index])
      end
      assert(#parts > 0, "relative semantic path was empty")
      return table.concat(parts, "/")
    end

    local function instrumented_dependencies(state_root, lock_path, lstat_injection)
      local dependencies, descriptors = tracked_open_close_dependencies()
      local tracked_open = dependencies.open
      local telemetry = {
        descriptors = descriptors,
        lifetimes = {},
        open_invocations = {
          state = 0,
          lock = 0,
          unexpected = {},
        },
        open_delegates = 0,
        lstat_invocations = {
          state = 0,
          lock = 0,
          unexpected = {},
        },
        lstat_delegates = 0,
        injected_lstats = 0,
        mkdir_calls = {},
        mkdir_results = {},
        mkdir_delegates = 0,
        fsync_calls = 0,
        rmdir_calls = 0,
      }

      dependencies.open = function(path, flags, mode)
        if path == state_root then
          telemetry.open_invocations.state = telemetry.open_invocations.state + 1
        elseif path == lock_path then
          telemetry.open_invocations.lock = telemetry.open_invocations.lock + 1
        else
          table.insert(telemetry.open_invocations.unexpected, path)
        end

        telemetry.open_delegates = telemetry.open_delegates + 1
        local fd, open_error, open_code = tracked_open(path, flags, mode)
        if fd ~= nil then
          table.insert(telemetry.lifetimes, {
            fd = fd,
            path = path,
            descriptor = assert(descriptors[fd], "successful open lacked a descriptor record"),
          })
        end
        return fd, open_error, open_code
      end

      dependencies.lstat = function(path)
        local ordinal
        if path == state_root then
          telemetry.lstat_invocations.state = telemetry.lstat_invocations.state + 1
          ordinal = telemetry.lstat_invocations.state
        elseif path == lock_path then
          telemetry.lstat_invocations.lock = telemetry.lstat_invocations.lock + 1
          ordinal = telemetry.lstat_invocations.lock
        else
          table.insert(telemetry.lstat_invocations.unexpected, path)
          ordinal = #telemetry.lstat_invocations.unexpected
        end

        local inject = lstat_injection
          and path == lstat_injection.path
          and ordinal == lstat_injection.ordinal
        if inject then
          telemetry.injected_lstats = telemetry.injected_lstats + 1
        end

        telemetry.lstat_delegates = telemetry.lstat_delegates + 1
        local stat, stat_error, stat_code = native_lstat(path)
        if inject then
          return lstat_injection.result(stat, stat_error, stat_code)
        end
        return stat, stat_error, stat_code
      end

      dependencies.mkdir = function(path, mode)
        table.insert(telemetry.mkdir_calls, { path = path, mode = mode })
        telemetry.mkdir_delegates = telemetry.mkdir_delegates + 1
        local created, create_error, create_code = native_mkdir(path, mode)
        table.insert(telemetry.mkdir_results, {
          created = created,
          error = create_error,
          code = create_code,
        })
        return created, create_error, create_code
      end

      dependencies.fsync = function(fd)
        telemetry.fsync_calls = telemetry.fsync_calls + 1
        return native_fsync(fd)
      end

      dependencies.rmdir = function(path)
        telemetry.rmdir_calls = telemetry.rmdir_calls + 1
        return native_rmdir(path)
      end

      return dependencies, telemetry
    end

    local function run_case(spec, case_fixture)
      executed_cases = executed_cases + 1
      local label = spec.label
      local state_root = case_fixture.state_root
      local lock_path = case_fixture.lock_path
      local before = snapshot_tree(case_fixture.snapshot_root)
      local dependencies, telemetry =
        instrumented_dependencies(state_root, lock_path, case_fixture.lstat_injection)

      local lease, acquire_error = serialization.acquire(state_root, dependencies)
      local returned_lease = lease ~= nil
      local release_calls = 0
      local release_observation = "none"
      if lease then
        release_calls = release_calls + 1
        local release_ok, release_value, release_error = pcall(lease.release, lease)
        if not release_ok then
          release_observation = "raised"
          add_failure(label, "defective lease fallback release raised")
        elseif release_value ~= true then
          release_observation = "failed"
          add_failure(label, "defective lease fallback release failed: " .. tostring(release_error))
        else
          release_observation = "released"
        end
      end

      if returned_lease then
        add_failure(label, "acquisition returned a lease")
      end

      local rescue_count = 0
      for _, lifetime in ipairs(telemetry.lifetimes) do
        if lifetime.descriptor.physical_close ~= true then
          rescue_count = rescue_count + 1
          add_failure(label, "descriptor lifetime required rescue close")
          local rescued, rescue_error = vim.uv.fs_close(lifetime.fd)
          assert(
            rescued,
            string.format("%s rescue close failed: %s", label, tostring(rescue_error))
          )
        end
      end

      local after = snapshot_tree(case_fixture.snapshot_root)
      local snapshot_unchanged = vim.deep_equal(after, before)
      if not snapshot_unchanged then
        add_failure(label, "complete snapshot changed")
      end

      if acquire_error ~= spec.expected_error then
        add_failure(
          label,
          "public error differed from exact expected class: " .. tostring(acquire_error)
        )
      end
      if tostring(acquire_error):find(injected_payload, 1, true) then
        add_failure(label, "fixed injected payload reached the public error")
      end

      expect_count(
        label,
        "state-root open invocations",
        telemetry.open_invocations.state,
        spec.state_opens
      )
      expect_count(label, "lock open invocations", telemetry.open_invocations.lock, spec.lock_opens)
      expect_count(label, "unexpected open invocations", #telemetry.open_invocations.unexpected, 0)
      expect_count(
        label,
        "tracked open delegations",
        telemetry.open_delegates,
        spec.state_opens + spec.lock_opens
      )

      expect_count(
        label,
        "state-root lstat invocations",
        telemetry.lstat_invocations.state,
        spec.state_lstats
      )
      expect_count(
        label,
        "lock lstat invocations",
        telemetry.lstat_invocations.lock,
        spec.lock_lstats
      )
      expect_count(
        label,
        "unexpected lstat invocations",
        #telemetry.lstat_invocations.unexpected,
        0
      )
      expect_count(
        label,
        "lstat delegations",
        telemetry.lstat_delegates,
        spec.state_lstats + spec.lock_lstats
      )
      expect_count(label, "injected lstat results", telemetry.injected_lstats, spec.injected_lstats)

      expect_count(label, "mkdir calls", #telemetry.mkdir_calls, spec.mkdir_calls)
      expect_count(label, "native mkdir delegations", telemetry.mkdir_delegates, spec.mkdir_calls)
      for _, mkdir_call in ipairs(telemetry.mkdir_calls) do
        if mkdir_call.path ~= lock_path then
          add_failure(label, "mkdir used a non-lock path")
        end
        if mkdir_call.mode ~= 448 then
          add_failure(label, "mkdir used a mode other than 448")
        end
      end
      for _, mkdir_result in ipairs(telemetry.mkdir_results) do
        local native_eexist = mkdir_result.created == nil
          and (
            mkdir_result.code == "EEXIST"
            or tostring(mkdir_result.error):find("EEXIST", 1, true) ~= nil
          )
        if not native_eexist then
          add_failure(label, "native existing-lock mkdir did not return EEXIST")
        end
      end

      expect_count(label, "fsync calls", telemetry.fsync_calls, 0)
      expect_count(label, "rmdir calls", telemetry.rmdir_calls, 0)
      expect_count(label, "release calls", release_calls, 0)

      local lifetime_counts = {
        state = 0,
        lock = 0,
        unexpected = 0,
      }
      for _, lifetime in ipairs(telemetry.lifetimes) do
        local lifetime_label
        if lifetime.path == state_root then
          lifetime_counts.state = lifetime_counts.state + 1
          lifetime_label = "state-root"
        elseif lifetime.path == lock_path then
          lifetime_counts.lock = lifetime_counts.lock + 1
          lifetime_label = "lock"
        else
          lifetime_counts.unexpected = lifetime_counts.unexpected + 1
          lifetime_label = "unexpected"
        end

        if lifetime.descriptor.close_attempts ~= 1 then
          add_failure(
            label,
            string.format(
              "%s lifetime close attempts expected 1 actual %d",
              lifetime_label,
              lifetime.descriptor.close_attempts
            )
          )
        end
        if lifetime.descriptor.physical_close ~= true then
          add_failure(label, lifetime_label .. " lifetime was not physically closed")
        end
      end
      expect_count(
        label,
        "state-root descriptor lifetimes",
        lifetime_counts.state,
        spec.state_opens
      )
      expect_count(label, "lock descriptor lifetimes", lifetime_counts.lock, spec.lock_opens)
      expect_count(label, "unexpected descriptor lifetimes", lifetime_counts.unexpected, 0)

      table.insert(
        observations,
        string.format(
          "%s error=%s opens=%d/%d lifetimes=%d/%d lstats=%d/%d injected=%d mkdir=%d fsync=%d rmdir=%d release=%d rescue=%d snapshot=%s fallback=%s",
          label,
          tostring(acquire_error == spec.expected_error),
          telemetry.open_invocations.state,
          telemetry.open_invocations.lock,
          lifetime_counts.state,
          lifetime_counts.lock,
          telemetry.lstat_invocations.state,
          telemetry.lstat_invocations.lock,
          telemetry.injected_lstats,
          #telemetry.mkdir_calls,
          telemetry.fsync_calls,
          telemetry.rmdir_calls,
          release_calls,
          rescue_count,
          tostring(snapshot_unchanged),
          release_observation
        )
      )
    end

    local state_cases = {
      {
        label = "state-non-string",
        state_opens = 0,
        lock_opens = 0,
        state_lstats = 0,
        lock_lstats = 0,
        injected_lstats = 0,
        mkdir_calls = 0,
        setup = function()
          local guard_root = make_root("serialization-malformed-state-non-string")
          write_file(vim.fs.joinpath(guard_root, "guard"), "guard\n")
          return {
            state_root = false,
            lock_path = vim.fs.joinpath(guard_root, lock_name),
            snapshot_root = guard_root,
          }
        end,
      },
      {
        label = "state-relative",
        state_opens = 0,
        lock_opens = 0,
        state_lstats = 0,
        lock_lstats = 0,
        injected_lstats = 0,
        mkdir_calls = 0,
        setup = function()
          local guard_root = make_root("serialization-malformed-state-relative")
          local relative_root = relative_path(assert(vim.uv.cwd()), guard_root)
          assert(relative_root:sub(1, 1) ~= "/", "relative state-root fixture is absolute")
          eq(
            vim.uv.fs_realpath(relative_root),
            guard_root,
            "relative state-root fixture resolves only to its registered root"
          )
          return {
            state_root = relative_root,
            lock_path = vim.fs.joinpath(relative_root, lock_name),
            snapshot_root = guard_root,
          }
        end,
      },
      {
        label = "state-non-normalized",
        state_opens = 0,
        lock_opens = 0,
        state_lstats = 0,
        lock_lstats = 0,
        injected_lstats = 0,
        mkdir_calls = 0,
        setup = function()
          local guard_root = make_root("serialization-malformed-state-non-normalized")
          local state_root = guard_root .. "/."
          return {
            state_root = state_root,
            lock_path = vim.fs.joinpath(state_root, lock_name),
            snapshot_root = guard_root,
          }
        end,
      },
      {
        label = "state-symlinked-ancestor",
        state_opens = 0,
        lock_opens = 0,
        state_lstats = 1,
        lock_lstats = 0,
        injected_lstats = 0,
        mkdir_calls = 0,
        setup = function()
          local guard_root = make_root("serialization-malformed-state-symlinked-ancestor")
          local physical_parent = vim.fs.joinpath(guard_root, "physical")
          local physical_state = vim.fs.joinpath(physical_parent, "state")
          local alias = vim.fs.joinpath(guard_root, "alias")
          make_directory(physical_parent)
          make_directory(physical_state)
          make_symlink(physical_parent, alias)
          local state_root = vim.fs.joinpath(alias, "state")
          return {
            state_root = state_root,
            lock_path = vim.fs.joinpath(state_root, lock_name),
            snapshot_root = guard_root,
          }
        end,
      },
      {
        label = "state-symlink-root",
        state_opens = 0,
        lock_opens = 0,
        state_lstats = 1,
        lock_lstats = 0,
        injected_lstats = 0,
        mkdir_calls = 0,
        setup = function()
          local guard_root = make_root("serialization-malformed-state-symlink-root")
          local physical_state = vim.fs.joinpath(guard_root, "physical-state")
          local state_root = vim.fs.joinpath(guard_root, "state")
          make_directory(physical_state)
          make_symlink(physical_state, state_root)
          return {
            state_root = state_root,
            lock_path = vim.fs.joinpath(state_root, lock_name),
            snapshot_root = guard_root,
          }
        end,
      },
      {
        label = "state-regular-file",
        state_opens = 0,
        lock_opens = 0,
        state_lstats = 1,
        lock_lstats = 0,
        injected_lstats = 0,
        mkdir_calls = 0,
        setup = function()
          local guard_root = make_root("serialization-malformed-state-file")
          local state_root = vim.fs.joinpath(guard_root, "state")
          write_file(state_root, "not a directory\n")
          return {
            state_root = state_root,
            lock_path = vim.fs.joinpath(state_root, lock_name),
            snapshot_root = guard_root,
          }
        end,
      },
      {
        label = "state-wrong-owner",
        state_opens = 0,
        lock_opens = 0,
        state_lstats = 1,
        lock_lstats = 0,
        injected_lstats = 1,
        mkdir_calls = 0,
        setup = function()
          local state_root = make_root("serialization-malformed-state-owner")
          return {
            state_root = state_root,
            lock_path = vim.fs.joinpath(state_root, lock_name),
            snapshot_root = state_root,
            lstat_injection = {
              path = state_root,
              ordinal = 1,
              result = function(stat)
                local changed = copy(stat)
                changed.uid = changed.uid + 1
                return changed
              end,
            },
          }
        end,
      },
      {
        label = "state-wrong-mode",
        state_opens = 0,
        lock_opens = 0,
        state_lstats = 1,
        lock_lstats = 0,
        injected_lstats = 0,
        mkdir_calls = 0,
        setup = function()
          local state_root = make_root("serialization-malformed-state-mode")
          assert(vim.uv.fs_chmod(state_root, 493), "could not set malformed state mode")
          return {
            state_root = state_root,
            lock_path = vim.fs.joinpath(state_root, lock_name),
            snapshot_root = state_root,
          }
        end,
      },
      {
        label = "state-unstable-inode",
        state_opens = 1,
        lock_opens = 0,
        state_lstats = 2,
        lock_lstats = 0,
        injected_lstats = 1,
        mkdir_calls = 0,
        setup = function()
          local state_root = make_root("serialization-malformed-state-unstable")
          return {
            state_root = state_root,
            lock_path = vim.fs.joinpath(state_root, lock_name),
            snapshot_root = state_root,
            lstat_injection = {
              path = state_root,
              ordinal = 2,
              result = function(stat)
                local changed = copy(stat)
                changed.ino = changed.ino + 1
                return changed
              end,
            },
          }
        end,
      },
    }

    for _, test_case in ipairs(state_cases) do
      test_case.expected_error = malformed_state_root
      run_case(test_case, test_case.setup())
    end

    local lock_cases = {
      {
        label = "lock-regular-file",
        state_opens = 1,
        lock_opens = 0,
        state_lstats = 2,
        lock_lstats = 1,
        injected_lstats = 0,
        mkdir_calls = 1,
        setup = function()
          local state_root = make_root("serialization-malformed-lock-file")
          local lock_path = vim.fs.joinpath(state_root, lock_name)
          write_file(lock_path, "not a directory\n")
          return {
            state_root = state_root,
            lock_path = lock_path,
            snapshot_root = state_root,
          }
        end,
      },
      {
        label = "lock-symlink",
        state_opens = 1,
        lock_opens = 0,
        state_lstats = 2,
        lock_lstats = 1,
        injected_lstats = 0,
        mkdir_calls = 1,
        setup = function()
          local state_root = make_root("serialization-malformed-lock-symlink")
          local lock_path = vim.fs.joinpath(state_root, lock_name)
          local target = vim.fs.joinpath(state_root, "lock-target")
          make_directory(target)
          make_symlink(target, lock_path)
          return {
            state_root = state_root,
            lock_path = lock_path,
            snapshot_root = state_root,
          }
        end,
      },
      {
        label = "lock-wrong-mode",
        state_opens = 1,
        lock_opens = 0,
        state_lstats = 2,
        lock_lstats = 1,
        injected_lstats = 0,
        mkdir_calls = 1,
        setup = function()
          local state_root = make_root("serialization-malformed-lock-mode")
          local lock_path = vim.fs.joinpath(state_root, lock_name)
          make_directory(lock_path, 493)
          return {
            state_root = state_root,
            lock_path = lock_path,
            snapshot_root = state_root,
          }
        end,
      },
      {
        label = "lock-wrong-owner",
        state_opens = 1,
        lock_opens = 0,
        state_lstats = 2,
        lock_lstats = 1,
        injected_lstats = 1,
        mkdir_calls = 1,
        setup = function()
          local state_root = make_root("serialization-malformed-lock-owner")
          local lock_path = vim.fs.joinpath(state_root, lock_name)
          make_directory(lock_path)
          return {
            state_root = state_root,
            lock_path = lock_path,
            snapshot_root = state_root,
            lstat_injection = {
              path = lock_path,
              ordinal = 1,
              result = function(stat)
                local changed = copy(stat)
                changed.uid = changed.uid + 1
                return changed
              end,
            },
          }
        end,
      },
      {
        label = "lock-cross-device",
        state_opens = 1,
        lock_opens = 0,
        state_lstats = 2,
        lock_lstats = 1,
        injected_lstats = 1,
        mkdir_calls = 1,
        setup = function()
          local state_root = make_root("serialization-malformed-lock-device")
          local lock_path = vim.fs.joinpath(state_root, lock_name)
          make_directory(lock_path)
          return {
            state_root = state_root,
            lock_path = lock_path,
            snapshot_root = state_root,
            lstat_injection = {
              path = lock_path,
              ordinal = 1,
              result = function(stat)
                local changed = copy(stat)
                changed.dev = changed.dev + 1
                return changed
              end,
            },
          }
        end,
      },
      {
        label = "lock-nonempty",
        state_opens = 1,
        lock_opens = 1,
        state_lstats = 2,
        lock_lstats = 1,
        injected_lstats = 0,
        mkdir_calls = 1,
        setup = function()
          local state_root = make_root("serialization-malformed-lock-nonempty")
          local lock_path = vim.fs.joinpath(state_root, lock_name)
          make_directory(lock_path)
          write_file(vim.fs.joinpath(lock_path, "child"), "digested child\n")
          return {
            state_root = state_root,
            lock_path = lock_path,
            snapshot_root = state_root,
          }
        end,
      },
      {
        label = "lock-unstable-inode",
        state_opens = 1,
        lock_opens = 1,
        state_lstats = 2,
        lock_lstats = 2,
        injected_lstats = 1,
        mkdir_calls = 1,
        setup = function()
          local state_root = make_root("serialization-malformed-lock-unstable")
          local lock_path = vim.fs.joinpath(state_root, lock_name)
          make_directory(lock_path)
          return {
            state_root = state_root,
            lock_path = lock_path,
            snapshot_root = state_root,
            lstat_injection = {
              path = lock_path,
              ordinal = 2,
              result = function(stat)
                local changed = copy(stat)
                changed.ino = changed.ino + 1
                return changed
              end,
            },
          }
        end,
      },
      {
        label = "lock-incomplete-stable-inspection",
        state_opens = 1,
        lock_opens = 1,
        state_lstats = 2,
        lock_lstats = 2,
        injected_lstats = 1,
        mkdir_calls = 1,
        setup = function()
          local state_root = make_root("serialization-malformed-lock-incomplete")
          local lock_path = vim.fs.joinpath(state_root, lock_name)
          make_directory(lock_path)
          return {
            state_root = state_root,
            lock_path = lock_path,
            snapshot_root = state_root,
            lstat_injection = {
              path = lock_path,
              ordinal = 2,
              result = function(stat)
                local changed = copy(stat)
                changed.ino = nil
                return changed
              end,
            },
          }
        end,
      },
    }

    for _, test_case in ipairs(lock_cases) do
      test_case.expected_error = malformed_lock
      run_case(test_case, test_case.setup())
    end

    local eio_case = {
      label = "lock-second-lstat-real-eio",
      expected_error = lstat_eio,
      state_opens = 1,
      lock_opens = 1,
      state_lstats = 2,
      lock_lstats = 2,
      injected_lstats = 1,
      mkdir_calls = 1,
    }
    local eio_state_root = make_root("serialization-lock-real-eio")
    local eio_lock_path = vim.fs.joinpath(eio_state_root, lock_name)
    make_directory(eio_lock_path)
    run_case(eio_case, {
      state_root = eio_state_root,
      lock_path = eio_lock_path,
      snapshot_root = eio_state_root,
      lstat_injection = {
        path = eio_lock_path,
        ordinal = 2,
        result = function()
          return nil, injected_payload, "EIO"
        end,
      },
    })

    expect_count("cycle-2c", "executed rows", executed_cases, 18)
    expect_count("cycle-2c", "observation rows", #observations, 18)
    assert(
      #failures == 0,
      "serialization semantic matrix: "
        .. table.concat(failures, "; ")
        .. " | observations: "
        .. table.concat(observations, "; ")
    )
  end

  do
    local AL = "baseline serialization acquisition failed: lstat-lock (EIO)"
    local AVL = "baseline serialization acquisition failed: validate-lock (EIO)"
    local AO = "baseline serialization acquisition failed: open-lock (EIO)"
    local AS = "baseline serialization acquisition failed: scan-lock (EIO)"
    local AVS = "baseline serialization acquisition failed: validate-state-root (UNKNOWN)"
    local AF = "baseline serialization acquisition failed: fsync-state-root (EIO)"
    local CCL = "baseline serialization cleanup failed: close-lock (EIO)"
    local CLL = "baseline serialization cleanup failed: lstat-lock (EIO)"
    local CVL = "baseline serialization cleanup failed: validate-lock (UNKNOWN)"
    local CR = "baseline serialization cleanup failed: rmdir-lock (EIO)"
    local CVA = "baseline serialization cleanup failed: verify-lock-absent (EIO)"
    local CF = "baseline serialization cleanup failed: fsync-state-root (EIO)"
    local CCS = "baseline serialization cleanup failed: close-state-root (EIO)"
    local error_names = {
      [AL] = "AL",
      [AVL] = "AVL",
      [AO] = "AO",
      [AS] = "AS",
      [AVS] = "AVS",
      [AF] = "AF",
      [AS .. "; " .. CCL] = "AS;CCL",
      [AS .. "; " .. CLL] = "AS;CLL",
      [AS .. "; " .. CR] = "AS;CR",
      [AS .. "; " .. CVA] = "AS;CVA",
      [AS .. "; " .. CF] = "AS;CF",
      [AS .. "; " .. CCS] = "AS;CCS",
      [AS .. "; " .. CCL .. "; " .. CVA .. "; " .. CF .. "; " .. CCS] = "AS;CCL;CVA;CF;CCS",
      [AS .. "; " .. CVL] = "AS;CVL",
    }
    local ABS = { { path = ".", type = "absent" } }
    local KEEP = "KEEP"
    local SWAP = "SWAP"
    local injected_payload = "injected cycle 2D payload at /fixed/isq84/.baseline-serialization"
    local lock_name = ".baseline-serialization"
    local failures = {}
    local observations = {}
    local executed_rows = 0
    local native = {
      lstat = vim.uv.fs_lstat,
      realpath = vim.uv.fs_realpath,
      fstat = vim.uv.fs_fstat,
      mkdir = vim.uv.fs_mkdir,
      scandir = vim.uv.fs_scandir,
      scandir_next = vim.uv.fs_scandir_next,
      fsync = vim.uv.fs_fsync,
      rmdir = vim.uv.fs_rmdir,
      rename = vim.uv.fs_rename,
      symlink = vim.uv.fs_symlink,
      uid = vim.uv.getuid,
    }
    local operation_names = {
      "lstat",
      "realpath",
      "open",
      "fstat",
      "mkdir",
      "scandir",
      "scandir_next",
      "fsync",
      "close",
      "rmdir",
    }

    local function add_failure(label, detail)
      table.insert(failures, label .. " " .. detail)
    end

    local function expect_count(label, detail, actual, expected)
      if actual ~= expected then
        add_failure(label, string.format("%s expected %d actual %d", detail, expected, actual))
      end
    end

    local function new_path_counter()
      return {
        state = 0,
        lock = 0,
        unexpected = 0,
      }
    end

    local function new_operation_counters()
      local counters = {}
      for _, operation in ipairs(operation_names) do
        counters[operation] = new_path_counter()
      end
      return counters
    end

    local function record(counter, category)
      counter[category] = counter[category] + 1
      return counter[category]
    end

    local function path_category(path, state_root, lock_path)
      if path == state_root then
        return "state"
      end
      if path == lock_path then
        return "lock"
      end
      return "unexpected"
    end

    local function identity(stat)
      if type(stat) ~= "table" then
        return nil
      end
      return {
        dev = stat.dev,
        ino = stat.ino,
        uid = stat.uid,
        type = stat.type,
        mode = type(stat.mode) == "number" and mode_bits(stat) or nil,
      }
    end

    local function same_identity(left, right)
      return left
        and right
        and left.dev == right.dev
        and left.ino == right.ino
        and left.uid == right.uid
        and left.type == right.type
        and left.mode == right.mode
    end

    local function is_native_enoent(result)
      return result
        and result.exists == false
        and (
          result.code == "ENOENT"
          or tostring(result.error):find("ENOENT", 1, true)
          or tostring(result.error):find("no such file", 1, true)
        )
    end

    local function protected_snapshot(path)
      return xpcall(function()
        return snapshot_tree(path)
      end, debug.traceback)
    end

    local function contained_path(state_root, path)
      return type(path) == "string"
        and vim.fs.normalize(path) == path
        and path:sub(1, #state_root + 1) == state_root .. "/"
    end

    local function capture_setup(path)
      local stat, stat_error = native.lstat(path)
      assert(stat, tostring(stat_error))
      return {
        identity = identity(stat),
        snapshot = snapshot_tree(path),
      }
    end

    local function prepare_swap_setup(state_root, spec)
      if not spec.swap_kind then
        return nil
      end

      local setup = {
        kind = spec.swap_kind,
        retired_path = vim.fs.joinpath(state_root, ".cycle-2d-retired-" .. spec.key),
        replacement_path = vim.fs.joinpath(state_root, ".cycle-2d-replacement-" .. spec.key),
        symlink_calls = 0,
        symlink_successes = 0,
        setup_native_ok = true,
      }
      assert(contained_path(state_root, setup.retired_path), "Cycle 2D retired path escaped")
      assert(
        contained_path(state_root, setup.replacement_path),
        "Cycle 2D replacement path escaped"
      )
      eq(snapshot_tree(setup.retired_path), ABS, "Cycle 2D retired setup absence")

      if setup.kind == "directory" then
        local created, create_error = native.mkdir(setup.replacement_path, 448)
        assert(created, tostring(create_error))
        assert(vim.uv.fs_chmod(setup.replacement_path, 448))
      elseif setup.kind == "symlink" then
        setup.target_path = vim.fs.joinpath(state_root, ".cycle-2d-target-" .. spec.key)
        assert(contained_path(state_root, setup.target_path), "Cycle 2D target path escaped")
        local target_created, target_error = native.mkdir(setup.target_path, 448)
        assert(target_created, tostring(target_error))
        assert(vim.uv.fs_chmod(setup.target_path, 448))
        setup.target = capture_setup(setup.target_path)
        setup.symlink_calls = setup.symlink_calls + 1
        local linked, link_error = native.symlink(setup.target_path, setup.replacement_path)
        if linked then
          setup.symlink_successes = setup.symlink_successes + 1
        else
          setup.setup_native_ok = false
        end
        assert(linked, tostring(link_error))
      else
        error("unknown Cycle 2D swap kind", 0)
      end

      setup.replacement = capture_setup(setup.replacement_path)
      setup.paths_contained = contained_path(state_root, setup.retired_path)
        and contained_path(state_root, setup.replacement_path)
        and (not setup.target_path or contained_path(state_root, setup.target_path))
      return setup
    end

    local function instrumented_dependencies(state_root, lock_path, spec, swap_setup)
      local dependencies, descriptors = tracked_open_close_dependencies()
      local tracked_open = dependencies.open
      local tracked_close = dependencies.close
      local function injection_enabled(name)
        return spec.injection == name
          or (type(spec.injections) == "table" and spec.injections[name] == true)
      end
      local telemetry = {
        calls = new_operation_counters(),
        delegates = new_operation_counters(),
        descriptors = descriptors,
        lifetimes = {},
        active_by_fd = {},
        events = {},
        scanner_category = {},
        lstat_results = {
          state = {},
          lock = {},
          unexpected = {},
        },
        fsync_results = {
          state = {},
          lock = {},
          unexpected = {},
        },
        rmdir_results = {
          state = {},
          lock = {},
          unexpected = {},
        },
        mkdir_results = {},
        uid_calls = 0,
        uid_delegates = 0,
        uid_unexpected_arguments = 0,
        injection_calls = 0,
        injection_delegates = 0,
        injection_native_ok = true,
        created_lock_capture_ok = false,
        created_lock = nil,
        reused_live_descriptors = 0,
        swap = {
          calls = 0,
          rename_calls = 0,
          rename_successes = 0,
          native_ok = true,
          completed = false,
          state_snapshot_ok = false,
          state_snapshot = nil,
        },
      }

      local function note_injection(delegated, native_ok)
        telemetry.injection_calls = telemetry.injection_calls + 1
        if delegated then
          telemetry.injection_delegates = telemetry.injection_delegates + 1
        end
        telemetry.injection_native_ok = telemetry.injection_native_ok and native_ok
      end

      local function note_event(operation, category, ordinal)
        table.insert(telemetry.events, string.format("%s:%s:%d", operation, category, ordinal))
      end

      local function descriptor_category(fd)
        local lifetime = telemetry.active_by_fd[fd]
        return lifetime and lifetime.category or "unexpected", lifetime
      end

      local function perform_swap()
        telemetry.swap.calls = telemetry.swap.calls + 1
        if not swap_setup then
          telemetry.swap.native_ok = false
          return
        end

        telemetry.swap.rename_calls = telemetry.swap.rename_calls + 1
        local retired = native.rename(lock_path, swap_setup.retired_path)
        if retired then
          telemetry.swap.rename_successes = telemetry.swap.rename_successes + 1
        else
          telemetry.swap.native_ok = false
          return
        end

        telemetry.swap.rename_calls = telemetry.swap.rename_calls + 1
        local installed = native.rename(swap_setup.replacement_path, lock_path)
        if installed then
          telemetry.swap.rename_successes = telemetry.swap.rename_successes + 1
          telemetry.swap.completed = true
        else
          telemetry.swap.native_ok = false
          return
        end

        local snapshot_ok, state_snapshot = protected_snapshot(state_root)
        telemetry.swap.state_snapshot_ok = snapshot_ok
        telemetry.swap.state_snapshot = snapshot_ok and state_snapshot or nil
        telemetry.swap.native_ok = telemetry.swap.native_ok and snapshot_ok
      end

      dependencies.uid = function(...)
        telemetry.uid_calls = telemetry.uid_calls + 1
        if select("#", ...) ~= 0 then
          telemetry.uid_unexpected_arguments = telemetry.uid_unexpected_arguments + 1
        end
        telemetry.uid_delegates = telemetry.uid_delegates + 1
        return native.uid(...)
      end

      dependencies.lstat = function(path)
        local category = path_category(path, state_root, lock_path)
        local ordinal = record(telemetry.calls.lstat, category)
        note_event("lstat", category, ordinal)
        record(telemetry.delegates.lstat, category)
        local stat, stat_error, stat_code = native.lstat(path)
        table.insert(telemetry.lstat_results[category], {
          exists = stat ~= nil,
          identity = identity(stat),
          error = stat_error,
          code = stat_code,
        })

        if injection_enabled("lock-lstat-1") and category == "lock" and ordinal == 1 then
          note_injection(true, stat ~= nil)
          return nil, injected_payload, "EIO"
        end
        if injection_enabled("lock-lstat-2-error") and category == "lock" and ordinal == 2 then
          note_injection(true, stat ~= nil)
          return nil, injected_payload, "EIO"
        end
        if injection_enabled("state-lstat-3") and category == "state" and ordinal == 3 then
          local native_ok = stat ~= nil and type(stat.ino) == "number"
          note_injection(true, native_ok)
          if native_ok then
            local changed = copy(stat)
            changed.ino = changed.ino + 1
            return changed
          end
          return stat, stat_error, stat_code
        end
        if
          injection_enabled("lock-lstat-3-absence-error")
          and category == "lock"
          and ordinal == 3
        then
          note_injection(
            true,
            is_native_enoent({
              exists = stat ~= nil,
              error = stat_error,
              code = stat_code,
            })
          )
          return nil, injected_payload, "EIO"
        end
        return stat, stat_error, stat_code
      end

      dependencies.realpath = function(path)
        local category = path_category(path, state_root, lock_path)
        record(telemetry.calls.realpath, category)
        record(telemetry.delegates.realpath, category)
        return native.realpath(path)
      end

      dependencies.open = function(path, flags, mode)
        local category = path_category(path, state_root, lock_path)
        local ordinal = record(telemetry.calls.open, category)
        if injection_enabled("lock-open-1") and category == "lock" and ordinal == 1 then
          note_injection(false, true)
          return nil, injected_payload, "EIO"
        end

        record(telemetry.delegates.open, category)
        local fd, open_error, open_code = tracked_open(path, flags, mode)
        if fd ~= nil then
          local prior = telemetry.active_by_fd[fd]
          if prior and not prior.ever_physically_closed then
            telemetry.reused_live_descriptors = telemetry.reused_live_descriptors + 1
          end
          local lifetime = {
            fd = fd,
            path = path,
            category = category,
            descriptor = assert(
              descriptors[fd],
              "successful Cycle 2D open lacked a descriptor record"
            ),
            close_invocations = 0,
            ever_physically_closed = false,
          }
          table.insert(telemetry.lifetimes, lifetime)
          telemetry.active_by_fd[fd] = lifetime
        end
        return fd, open_error, open_code
      end

      dependencies.fstat = function(fd)
        local category = descriptor_category(fd)
        local ordinal = record(telemetry.calls.fstat, category)
        record(telemetry.delegates.fstat, category)
        local stat, stat_error, stat_code = native.fstat(fd)
        if injection_enabled("lock-fstat-1") and category == "lock" and ordinal == 1 then
          note_injection(true, stat ~= nil)
          return nil, injected_payload, "EIO"
        end
        return stat, stat_error, stat_code
      end

      dependencies.mkdir = function(path, mode)
        local category = path_category(path, state_root, lock_path)
        record(telemetry.calls.mkdir, category)
        record(telemetry.delegates.mkdir, category)
        local created, create_error, create_code = native.mkdir(path, mode)
        table.insert(telemetry.mkdir_results, {
          category = category,
          path_matches = path == lock_path,
          mode = mode,
          created = created,
          error = create_error,
          code = create_code,
        })

        if created then
          local capture_ok, capture = xpcall(function()
            local created_stat, created_error = native.lstat(lock_path)
            assert(created_stat, tostring(created_error))
            return {
              identity = identity(created_stat),
              snapshot = snapshot_tree(lock_path),
            }
          end, debug.traceback)
          telemetry.created_lock_capture_ok = capture_ok
          if capture_ok then
            telemetry.created_lock = capture
          end
        end
        return created, create_error, create_code
      end

      dependencies.scandir = function(path)
        local category = path_category(path, state_root, lock_path)
        record(telemetry.calls.scandir, category)
        record(telemetry.delegates.scandir, category)
        local scanner, scan_error, scan_code = native.scandir(path)
        if scanner ~= nil then
          telemetry.scanner_category[scanner] = category
        end
        return scanner, scan_error, scan_code
      end

      dependencies.scandir_next = function(scanner)
        local category = telemetry.scanner_category[scanner] or "unexpected"
        local ordinal = record(telemetry.calls.scandir_next, category)
        record(telemetry.delegates.scandir_next, category)
        local name, scan_error, scan_code = native.scandir_next(scanner)
        if injection_enabled("lock-scan-next-1") and category == "lock" and ordinal == 1 then
          note_injection(true, name == nil and scan_error == nil and scan_code == nil)
          return nil, injected_payload, "EIO"
        end
        return name, scan_error, scan_code
      end

      dependencies.fsync = function(fd)
        local category = descriptor_category(fd)
        local ordinal = record(telemetry.calls.fsync, category)
        note_event("fsync", category, ordinal)
        record(telemetry.delegates.fsync, category)
        local synced, sync_error, sync_code = native.fsync(fd)
        table.insert(telemetry.fsync_results[category], {
          synced = synced,
          error = sync_error,
          code = sync_code,
        })
        if injection_enabled("state-fsync-1") and category == "state" and ordinal == 1 then
          note_injection(true, synced == true)
          return nil, injected_payload, "EIO"
        end
        return synced, sync_error, sync_code
      end

      dependencies.close = function(fd)
        local category, lifetime = descriptor_category(fd)
        local ordinal = record(telemetry.calls.close, category)
        note_event("close", category, ordinal)
        if lifetime then
          lifetime.close_invocations = lifetime.close_invocations + 1
          lifetime.ever_physically_closed = lifetime.ever_physically_closed
            or lifetime.descriptor.physical_close == true
        end
        record(telemetry.delegates.close, category)

        local close_ok, closed, close_error, close_code = pcall(tracked_close, fd)
        if lifetime then
          lifetime.ever_physically_closed = lifetime.ever_physically_closed
            or lifetime.descriptor.physical_close == true
          if lifetime.ever_physically_closed then
            telemetry.active_by_fd[fd] = nil
          end
        end
        if
          injection_enabled("swap-after-lock-close")
          and category == "lock"
          and ordinal == 1
          and close_ok
          and closed == true
          and lifetime
          and lifetime.ever_physically_closed
        then
          perform_swap()
        end
        if injection_enabled("lock-close-1-error") and category == "lock" and ordinal == 1 then
          note_injection(
            true,
            close_ok and closed == true and lifetime ~= nil and lifetime.ever_physically_closed
          )
          return nil, injected_payload, "EIO"
        end
        if injection_enabled("state-close-1-error") and category == "state" and ordinal == 1 then
          note_injection(
            true,
            close_ok and closed == true and lifetime ~= nil and lifetime.ever_physically_closed
          )
          return nil, injected_payload, "EIO"
        end
        if not close_ok then
          error(closed, 0)
        end
        return closed, close_error, close_code
      end

      dependencies.rmdir = function(path)
        local category = path_category(path, state_root, lock_path)
        local ordinal = record(telemetry.calls.rmdir, category)
        note_event("rmdir", category, ordinal)
        if injection_enabled("lock-rmdir-1-error") and category == "lock" and ordinal == 1 then
          note_injection(false, true)
          table.insert(telemetry.rmdir_results[category], {
            removed = nil,
            error = injected_payload,
            code = "EIO",
          })
          return nil, injected_payload, "EIO"
        end
        record(telemetry.delegates.rmdir, category)
        local removed, remove_error, remove_code = native.rmdir(path)
        table.insert(telemetry.rmdir_results[category], {
          removed = removed,
          error = remove_error,
          code = remove_code,
        })
        return removed, remove_error, remove_code
      end

      return dependencies, telemetry
    end

    local function expect_path_counter(label, detail, counter, state_expected, lock_expected)
      expect_count(label, detail .. " state", counter.state, state_expected)
      expect_count(label, detail .. " lock", counter.lock, lock_expected)
      expect_count(label, detail .. " unexpected", counter.unexpected, 0)
    end

    local function run_case(spec)
      executed_rows = executed_rows + 1
      local label = spec.key .. " " .. spec.label
      local state_root = make_root("serialization-durable-primary-" .. spec.key)
      local lock_path = vim.fs.joinpath(state_root, lock_name)
      local reviews_path = vim.fs.joinpath(state_root, "reviews")
      assert(vim.fn.mkdir(reviews_path, "p", 448) == 1, "could not create Cycle 2D reviews")
      assert(vim.uv.fs_chmod(reviews_path, 448), "could not chmod Cycle 2D reviews")
      write_file(vim.fs.joinpath(reviews_path, "control.bin"), "cycle-2d-control\n", 384)
      assert(
        vim.uv.fs_symlink("control.bin", vim.fs.joinpath(reviews_path, "control-link")),
        "could not create Cycle 2D control symlink"
      )
      local swap_setup = prepare_swap_setup(state_root, spec)
      local reviews_before = snapshot_tree(reviews_path)
      local state_identity = identity(assert(native.lstat(state_root)))
      local dependencies, telemetry =
        instrumented_dependencies(state_root, lock_path, spec, swap_setup)
      local visible_results = {}

      local acquire_ok, lease, acquire_error = xpcall(function()
        return serialization.acquire(state_root, dependencies)
      end, debug.traceback)
      if not acquire_ok then
        table.insert(visible_results, tostring(lease))
        lease = nil
        acquire_error = nil
        add_failure(label, "acquisition raised instead of returning a bounded result")
      else
        table.insert(visible_results, tostring(acquire_error))
      end

      local returned_lease = lease ~= nil
      local release_calls = 0
      local release_observation = "none"
      if lease then
        add_failure(label, "acquisition returned a defective lease")
        release_calls = release_calls + 1
        local release_ok, release_value, release_error = xpcall(function()
          return lease:release()
        end, debug.traceback)
        if not release_ok then
          release_observation = "raised"
          table.insert(visible_results, tostring(release_value))
          add_failure(label, "defective lease fallback release raised")
        else
          table.insert(visible_results, tostring(release_error))
          if release_value == true then
            release_observation = "released"
          else
            release_observation = "failed"
            add_failure(label, "defective lease fallback release failed")
          end
        end
      end

      local rescue_count = 0
      local rescue_successes = 0
      for _, lifetime in ipairs(telemetry.lifetimes) do
        lifetime.ever_physically_closed = lifetime.ever_physically_closed
          or lifetime.descriptor.physical_close == true
        if not lifetime.ever_physically_closed then
          rescue_count = rescue_count + 1
          add_failure(label, "a live descriptor lifetime required rescue")
          local rescue_ok, rescued = pcall(vim.uv.fs_close, lifetime.fd)
          if rescue_ok and rescued == true then
            rescue_successes = rescue_successes + 1
            lifetime.ever_physically_closed = true
          else
            add_failure(label, "a descriptor rescue did not physically close")
          end
        end
      end
      if rescue_successes ~= rescue_count then
        add_failure(label, "not every attempted rescue succeeded")
      end

      local reviews_ok, reviews_after = protected_snapshot(reviews_path)
      local reviews_unchanged = reviews_ok and vim.deep_equal(reviews_after, reviews_before)
      if not reviews_ok then
        add_failure(label, "reviews control snapshot raised")
      elseif not reviews_unchanged then
        add_failure(label, "reviews control snapshot changed")
      end

      local lock_snapshot_ok, final_lock_snapshot = protected_snapshot(lock_path)
      if not lock_snapshot_ok then
        add_failure(label, "final lock snapshot raised")
      end

      if not acquire_ok or returned_lease or acquire_error ~= spec.expected_error then
        add_failure(label, "public acquisition result differed from the exact expected error")
      end
      local error_observation = returned_lease and "lease"
        or error_names[acquire_error]
        or (acquire_ok and "other" or "raised")
      local payload_absent = true
      for _, result in ipairs(visible_results) do
        if result:find(injected_payload, 1, true) then
          payload_absent = false
        end
      end
      if not payload_absent then
        add_failure(label, "fixed injected payload reached a public result")
      end

      expect_count(label, "UID calls", telemetry.uid_calls, 1)
      expect_count(label, "UID native delegations", telemetry.uid_delegates, 1)
      expect_count(label, "UID unexpected arguments", telemetry.uid_unexpected_arguments, 0)
      expect_count(label, "injection calls", telemetry.injection_calls, spec.injection_calls or 1)
      expect_count(
        label,
        "injection native delegations",
        telemetry.injection_delegates,
        spec.injection_delegates
      )
      if not telemetry.injection_native_ok then
        add_failure(label, "injected dependency did not first observe its native control result")
      end
      local expected_swap_calls = spec.swap_kind and 1 or 0
      expect_count(label, "swap injections", telemetry.swap.calls, expected_swap_calls)
      expect_count(
        label,
        "swap rename calls",
        telemetry.swap.rename_calls,
        spec.swap_kind and 2 or 0
      )
      expect_count(
        label,
        "swap rename successes",
        telemetry.swap.rename_successes,
        spec.swap_kind and 2 or 0
      )
      if spec.swap_kind then
        if
          not swap_setup
          or not swap_setup.paths_contained
          or not swap_setup.setup_native_ok
          or not telemetry.swap.native_ok
          or not telemetry.swap.completed
          or not telemetry.swap.state_snapshot_ok
        then
          add_failure(label, "swap setup, confinement, native operations, or capture failed")
        end
        expect_count(
          label,
          "swap symlink calls",
          swap_setup and swap_setup.symlink_calls or 0,
          spec.swap_kind == "symlink" and 1 or 0
        )
        expect_count(
          label,
          "swap symlink successes",
          swap_setup and swap_setup.symlink_successes or 0,
          spec.swap_kind == "symlink" and 1 or 0
        )
        local replacement_root = swap_setup
          and swap_setup.replacement
          and swap_setup.replacement.snapshot[1]
        if spec.swap_kind == "directory" then
          if
            not replacement_root
            or #swap_setup.replacement.snapshot ~= 1
            or replacement_root.type ~= "directory"
            or replacement_root.mode ~= 448
            or replacement_root.uid ~= native.uid()
            or not same_identity(swap_setup.replacement.identity, replacement_root)
          then
            add_failure(label, "directory replacement setup was not exact, private, and empty")
          end
        elseif spec.swap_kind == "symlink" then
          local target_root = swap_setup.target and swap_setup.target.snapshot[1]
          if
            not replacement_root
            or #swap_setup.replacement.snapshot ~= 1
            or replacement_root.type ~= "link"
            or replacement_root.target ~= swap_setup.target_path
            or not contained_path(state_root, replacement_root.target)
            or not target_root
            or #swap_setup.target.snapshot ~= 1
            or target_root.type ~= "directory"
            or target_root.mode ~= 448
            or target_root.uid ~= native.uid()
            or not same_identity(swap_setup.replacement.identity, replacement_root)
            or not same_identity(swap_setup.target.identity, target_root)
          then
            add_failure(label, "symlink replacement setup or contained target was not exact")
          end
        end
      end

      expect_path_counter(
        label,
        "lstat calls",
        telemetry.calls.lstat,
        spec.state_lstats,
        spec.lock_lstats
      )
      expect_path_counter(
        label,
        "lstat native delegations",
        telemetry.delegates.lstat,
        spec.state_lstats,
        spec.lock_lstats
      )
      expect_path_counter(label, "realpath calls", telemetry.calls.realpath, 1, spec.lock_realpaths)
      expect_path_counter(
        label,
        "realpath native delegations",
        telemetry.delegates.realpath,
        1,
        spec.lock_realpaths
      )
      expect_path_counter(label, "open calls", telemetry.calls.open, 1, spec.lock_open_calls)
      expect_path_counter(
        label,
        "open native delegations",
        telemetry.delegates.open,
        1,
        spec.lock_open_delegates
      )
      expect_path_counter(label, "fstat calls", telemetry.calls.fstat, 1, spec.lock_fstats)
      expect_path_counter(
        label,
        "fstat native delegations",
        telemetry.delegates.fstat,
        1,
        spec.lock_fstats
      )
      expect_path_counter(label, "mkdir calls", telemetry.calls.mkdir, 0, 1)
      expect_path_counter(label, "mkdir native delegations", telemetry.delegates.mkdir, 0, 1)
      expect_path_counter(label, "scandir calls", telemetry.calls.scandir, 0, spec.scan_calls)
      expect_path_counter(
        label,
        "scandir native delegations",
        telemetry.delegates.scandir,
        0,
        spec.scan_calls
      )
      expect_path_counter(
        label,
        "scandir-next calls",
        telemetry.calls.scandir_next,
        0,
        spec.scan_calls
      )
      expect_path_counter(
        label,
        "scandir-next native delegations",
        telemetry.delegates.scandir_next,
        0,
        spec.scan_calls
      )
      expect_path_counter(label, "fsync calls", telemetry.calls.fsync, spec.fsync_calls, 0)
      expect_path_counter(
        label,
        "fsync native delegations",
        telemetry.delegates.fsync,
        spec.fsync_calls,
        0
      )
      expect_path_counter(label, "close calls", telemetry.calls.close, 1, spec.lock_lifetimes)
      expect_path_counter(
        label,
        "close native delegations",
        telemetry.delegates.close,
        1,
        spec.lock_lifetimes
      )
      expect_path_counter(label, "rmdir calls", telemetry.calls.rmdir, 0, spec.rmdir_calls)
      expect_path_counter(
        label,
        "rmdir native delegations",
        telemetry.delegates.rmdir,
        0,
        spec.rmdir_delegates or spec.rmdir_calls
      )

      expect_count(label, "mkdir result rows", #telemetry.mkdir_results, 1)
      local mkdir_result = telemetry.mkdir_results[1]
      if
        not mkdir_result
        or mkdir_result.category ~= "lock"
        or not mkdir_result.path_matches
        or mkdir_result.mode ~= 448
        or mkdir_result.created ~= true
      then
        add_failure(label, "native mkdir did not create the exact mode-448 lock")
      end

      local captured = telemetry.created_lock
      local capture_exact = telemetry.created_lock_capture_ok and captured ~= nil
      if not capture_exact then
        add_failure(label, "post-mkdir lock identity or snapshot was not captured")
      else
        local captured_identity = captured.identity
        local captured_root = captured.snapshot[1]
        if
          #captured.snapshot ~= 1
          or not captured_identity
          or type(captured_identity.dev) ~= "number"
          or type(captured_identity.ino) ~= "number"
          or captured_identity.uid ~= native.uid()
          or captured_identity.type ~= "directory"
          or captured_identity.mode ~= 448
          or captured_identity.dev ~= state_identity.dev
          or not captured_root
          or captured_root.path ~= "."
          or captured_root.type ~= captured_identity.type
          or captured_root.mode ~= captured_identity.mode
          or captured_root.dev ~= captured_identity.dev
          or captured_root.ino ~= captured_identity.ino
          or captured_root.uid ~= captured_identity.uid
        then
          capture_exact = false
          add_failure(label, "post-mkdir lock capture was not exact and private")
        end
      end

      local lifetime_counts = {
        state = 0,
        lock = 0,
        unexpected = 0,
      }
      for _, lifetime in ipairs(telemetry.lifetimes) do
        lifetime_counts[lifetime.category] = lifetime_counts[lifetime.category] + 1
        if lifetime.close_invocations ~= 1 then
          add_failure(
            label,
            string.format(
              "%s lifetime close invocations expected 1 actual %d",
              lifetime.category,
              lifetime.close_invocations
            )
          )
        end
        if lifetime.descriptor.close_attempts ~= 1 then
          add_failure(
            label,
            string.format(
              "%s lifetime tracked close attempts expected 1 actual %d",
              lifetime.category,
              lifetime.descriptor.close_attempts
            )
          )
        end
        if not lifetime.ever_physically_closed then
          add_failure(label, lifetime.category .. " lifetime was not physically closed")
        end
      end
      expect_count(label, "state descriptor lifetimes", lifetime_counts.state, 1)
      expect_count(label, "lock descriptor lifetimes", lifetime_counts.lock, spec.lock_lifetimes)
      expect_count(label, "unexpected descriptor lifetimes", lifetime_counts.unexpected, 0)
      expect_count(label, "live descriptor reuse", telemetry.reused_live_descriptors, 0)
      expect_count(label, "fallback release calls", release_calls, 0)
      expect_count(label, "descriptor rescue calls", rescue_count, 0)

      local events_exact = vim.deep_equal(telemetry.events, spec.expected_events)
      if not events_exact then
        add_failure(
          label,
          string.format(
            "event order expected [%s] actual [%s]",
            table.concat(spec.expected_events, ","),
            table.concat(telemetry.events, ",")
          )
        )
      end

      local outcome_observation = "OTHER"
      if lock_snapshot_ok and captured then
        if spec.outcome == KEEP then
          local final_stat = native.lstat(lock_path)
          local identity_unchanged = same_identity(identity(final_stat), captured.identity)
          local snapshot_unchanged = vim.deep_equal(final_lock_snapshot, captured.snapshot)
          if identity_unchanged and snapshot_unchanged then
            outcome_observation = KEEP
          else
            add_failure(label, "KEEP lock identity or complete snapshot changed")
          end
        elseif spec.outcome == SWAP then
          local retired_ok, retired_snapshot =
            protected_snapshot(swap_setup and swap_setup.retired_path or "")
          local retired_stat = swap_setup and native.lstat(swap_setup.retired_path) or nil
          local replacement_stat = native.lstat(lock_path)
          local state_after_ok, state_after = protected_snapshot(state_root)
          local target_exact = true
          if swap_setup and swap_setup.target_path then
            local target_stat = native.lstat(swap_setup.target_path)
            local target_ok, target_snapshot = protected_snapshot(swap_setup.target_path)
            target_exact = target_ok
              and same_identity(identity(target_stat), swap_setup.target.identity)
              and vim.deep_equal(target_snapshot, swap_setup.target.snapshot)
          end
          if
            retired_ok
            and swap_setup
            and same_identity(identity(retired_stat), captured.identity)
            and vim.deep_equal(retired_snapshot, captured.snapshot)
            and same_identity(identity(replacement_stat), swap_setup.replacement.identity)
            and vim.deep_equal(final_lock_snapshot, swap_setup.replacement.snapshot)
            and state_after_ok
            and telemetry.swap.state_snapshot_ok
            and vim.deep_equal(state_after, telemetry.swap.state_snapshot)
            and target_exact
          then
            outcome_observation = SWAP
          else
            add_failure(
              label,
              "SWAP retired identity, replacement identity, or complete snapshot changed"
            )
          end
        elseif spec.outcome == ABS then
          if vim.deep_equal(final_lock_snapshot, ABS) then
            outcome_observation = "ABS"
          else
            add_failure(label, "ABS lock sentinel was not exact")
          end
        else
          add_failure(label, "unknown Cycle 2D outcome oracle")
        end
      end

      if spec.outcome == ABS and captured then
        local lock_results = telemetry.lstat_results.lock
        local cleanup_identity = lock_results[spec.pre_cleanup_lock_lstats + 1]
        local absence_proof = lock_results[spec.pre_cleanup_lock_lstats + 2]
        if
          not cleanup_identity
          or not same_identity(cleanup_identity.identity, captured.identity)
        then
          add_failure(label, "cleanup lock-identity lstat did not match the created lock")
        end
        if not is_native_enoent(absence_proof) then
          add_failure(label, "delegated absence-proof lstat was not native ENOENT")
        end

        local final_rmdir = telemetry.rmdir_results.lock[#telemetry.rmdir_results.lock]
        if not final_rmdir or final_rmdir.removed ~= true then
          add_failure(label, "exact native lock rmdir did not succeed")
        end
        local final_fsync = telemetry.fsync_results.state[#telemetry.fsync_results.state]
        if not final_fsync or final_fsync.synced ~= true then
          add_failure(label, "cleanup parent fsync did not natively succeed")
        end
      end

      table.insert(
        observations,
        string.format(
          "%s error=%s opens=%d/%d/%d/%d lifetimes=%d/%d lstats=%d/%d fstats=%d/%d scans=%d/%d fsync=%d/%d rmdir=%d/%d release=%d rescue=%d reviews=%s capture=%s payload-absent=%s outcome=%s fallback=%s order=%s swap=%d/%d/%d/%s/%s symlink=%d/%d events=%s",
          label,
          error_observation,
          telemetry.calls.open.state,
          telemetry.calls.open.lock,
          telemetry.delegates.open.state,
          telemetry.delegates.open.lock,
          lifetime_counts.state,
          lifetime_counts.lock,
          telemetry.calls.lstat.state,
          telemetry.calls.lstat.lock,
          telemetry.calls.fstat.state,
          telemetry.calls.fstat.lock,
          telemetry.calls.scandir_next.lock,
          telemetry.delegates.scandir_next.lock,
          telemetry.calls.fsync.state,
          telemetry.delegates.fsync.state,
          telemetry.calls.rmdir.lock,
          telemetry.delegates.rmdir.lock,
          release_calls,
          rescue_count,
          tostring(reviews_unchanged),
          tostring(capture_exact),
          tostring(payload_absent),
          outcome_observation,
          release_observation,
          tostring(events_exact),
          telemetry.swap.calls,
          telemetry.swap.rename_calls,
          telemetry.swap.rename_successes,
          tostring(telemetry.swap.completed),
          tostring(telemetry.swap.state_snapshot_ok),
          swap_setup and swap_setup.symlink_calls or 0,
          swap_setup and swap_setup.symlink_successes or 0,
          table.concat(telemetry.events, ",")
        )
      )
    end

    local cleanup_full_events = {
      "lstat:state:1",
      "lstat:state:2",
      "lstat:lock:1",
      "close:lock:1",
      "lstat:lock:2",
      "rmdir:lock:1",
      "lstat:lock:3",
      "fsync:state:1",
      "close:state:1",
    }
    local cleanup_validation_stop_events = {
      "lstat:state:1",
      "lstat:state:2",
      "lstat:lock:1",
      "close:lock:1",
      "lstat:lock:2",
      "close:state:1",
    }
    local cleanup_rmdir_stop_events = {
      "lstat:state:1",
      "lstat:state:2",
      "lstat:lock:1",
      "close:lock:1",
      "lstat:lock:2",
      "rmdir:lock:1",
      "close:state:1",
    }

    local cases = {
      {
        key = "A0",
        label = "no identity claim",
        injection = "lock-lstat-1",
        injection_delegates = 1,
        expected_error = AL,
        state_lstats = 2,
        lock_lstats = 1,
        lock_realpaths = 0,
        lock_open_calls = 0,
        lock_open_delegates = 0,
        lock_lifetimes = 0,
        lock_fstats = 0,
        scan_calls = 0,
        fsync_calls = 0,
        rmdir_calls = 0,
        outcome = KEEP,
        expected_events = {
          "lstat:state:1",
          "lstat:state:2",
          "lstat:lock:1",
          "close:state:1",
        },
      },
      {
        key = "A1",
        label = "lock validation",
        injection = "lock-fstat-1",
        injection_delegates = 1,
        expected_error = AVL,
        state_lstats = 2,
        lock_lstats = 3,
        lock_realpaths = 1,
        lock_open_calls = 1,
        lock_open_delegates = 1,
        lock_lifetimes = 1,
        lock_fstats = 1,
        scan_calls = 0,
        fsync_calls = 1,
        rmdir_calls = 1,
        pre_cleanup_lock_lstats = 1,
        outcome = ABS,
        expected_events = {
          "lstat:state:1",
          "lstat:state:2",
          "lstat:lock:1",
          "close:lock:1",
          "lstat:lock:2",
          "rmdir:lock:1",
          "lstat:lock:3",
          "fsync:state:1",
          "close:state:1",
        },
      },
      {
        key = "A2",
        label = "lock open",
        injection = "lock-open-1",
        injection_delegates = 0,
        expected_error = AO,
        state_lstats = 2,
        lock_lstats = 3,
        lock_realpaths = 1,
        lock_open_calls = 1,
        lock_open_delegates = 0,
        lock_lifetimes = 0,
        lock_fstats = 0,
        scan_calls = 0,
        fsync_calls = 1,
        rmdir_calls = 1,
        pre_cleanup_lock_lstats = 1,
        outcome = ABS,
        expected_events = {
          "lstat:state:1",
          "lstat:state:2",
          "lstat:lock:1",
          "lstat:lock:2",
          "rmdir:lock:1",
          "lstat:lock:3",
          "fsync:state:1",
          "close:state:1",
        },
      },
      {
        key = "A3",
        label = "lock scan",
        injection = "lock-scan-next-1",
        injection_delegates = 1,
        expected_error = AS,
        state_lstats = 2,
        lock_lstats = 3,
        lock_realpaths = 1,
        lock_open_calls = 1,
        lock_open_delegates = 1,
        lock_lifetimes = 1,
        lock_fstats = 1,
        scan_calls = 1,
        fsync_calls = 1,
        rmdir_calls = 1,
        pre_cleanup_lock_lstats = 1,
        outcome = ABS,
        expected_events = {
          "lstat:state:1",
          "lstat:state:2",
          "lstat:lock:1",
          "close:lock:1",
          "lstat:lock:2",
          "rmdir:lock:1",
          "lstat:lock:3",
          "fsync:state:1",
          "close:state:1",
        },
      },
      {
        key = "A4",
        label = "root revalidation",
        injection = "state-lstat-3",
        injection_delegates = 1,
        expected_error = AVS,
        state_lstats = 3,
        lock_lstats = 4,
        lock_realpaths = 1,
        lock_open_calls = 1,
        lock_open_delegates = 1,
        lock_lifetimes = 1,
        lock_fstats = 1,
        scan_calls = 1,
        fsync_calls = 1,
        rmdir_calls = 1,
        pre_cleanup_lock_lstats = 2,
        outcome = ABS,
        expected_events = {
          "lstat:state:1",
          "lstat:state:2",
          "lstat:lock:1",
          "lstat:lock:2",
          "lstat:state:3",
          "close:lock:1",
          "lstat:lock:3",
          "rmdir:lock:1",
          "lstat:lock:4",
          "fsync:state:1",
          "close:state:1",
        },
      },
      {
        key = "A5",
        label = "acquisition parent fsync",
        injection = "state-fsync-1",
        injection_delegates = 1,
        expected_error = AF,
        state_lstats = 3,
        lock_lstats = 4,
        lock_realpaths = 1,
        lock_open_calls = 1,
        lock_open_delegates = 1,
        lock_lifetimes = 1,
        lock_fstats = 1,
        scan_calls = 1,
        fsync_calls = 2,
        rmdir_calls = 1,
        pre_cleanup_lock_lstats = 2,
        outcome = ABS,
        expected_events = {
          "lstat:state:1",
          "lstat:state:2",
          "lstat:lock:1",
          "lstat:lock:2",
          "lstat:state:3",
          "fsync:state:1",
          "close:lock:1",
          "lstat:lock:3",
          "rmdir:lock:1",
          "lstat:lock:4",
          "fsync:state:2",
          "close:state:1",
        },
      },
      {
        key = "C1",
        label = "cleanup lock close",
        injections = {
          ["lock-scan-next-1"] = true,
          ["lock-close-1-error"] = true,
        },
        injection_calls = 2,
        injection_delegates = 2,
        expected_error = AS .. "; " .. CCL,
        state_lstats = 2,
        lock_lstats = 3,
        lock_realpaths = 1,
        lock_open_calls = 1,
        lock_open_delegates = 1,
        lock_lifetimes = 1,
        lock_fstats = 1,
        scan_calls = 1,
        fsync_calls = 1,
        rmdir_calls = 1,
        pre_cleanup_lock_lstats = 1,
        outcome = ABS,
        expected_events = cleanup_full_events,
      },
      {
        key = "C2",
        label = "cleanup identity read",
        injections = {
          ["lock-scan-next-1"] = true,
          ["lock-lstat-2-error"] = true,
        },
        injection_calls = 2,
        injection_delegates = 2,
        expected_error = AS .. "; " .. CLL,
        state_lstats = 2,
        lock_lstats = 2,
        lock_realpaths = 1,
        lock_open_calls = 1,
        lock_open_delegates = 1,
        lock_lifetimes = 1,
        lock_fstats = 1,
        scan_calls = 1,
        fsync_calls = 0,
        rmdir_calls = 0,
        outcome = KEEP,
        expected_events = cleanup_validation_stop_events,
      },
      {
        key = "C3",
        label = "exact rmdir",
        injections = {
          ["lock-scan-next-1"] = true,
          ["lock-rmdir-1-error"] = true,
        },
        injection_calls = 2,
        injection_delegates = 1,
        expected_error = AS .. "; " .. CR,
        state_lstats = 2,
        lock_lstats = 2,
        lock_realpaths = 1,
        lock_open_calls = 1,
        lock_open_delegates = 1,
        lock_lifetimes = 1,
        lock_fstats = 1,
        scan_calls = 1,
        fsync_calls = 0,
        rmdir_calls = 1,
        rmdir_delegates = 0,
        outcome = KEEP,
        expected_events = cleanup_rmdir_stop_events,
      },
      {
        key = "C4",
        label = "absence proof",
        injections = {
          ["lock-scan-next-1"] = true,
          ["lock-lstat-3-absence-error"] = true,
        },
        injection_calls = 2,
        injection_delegates = 2,
        expected_error = AS .. "; " .. CVA,
        state_lstats = 2,
        lock_lstats = 3,
        lock_realpaths = 1,
        lock_open_calls = 1,
        lock_open_delegates = 1,
        lock_lifetimes = 1,
        lock_fstats = 1,
        scan_calls = 1,
        fsync_calls = 1,
        rmdir_calls = 1,
        pre_cleanup_lock_lstats = 1,
        outcome = ABS,
        expected_events = cleanup_full_events,
      },
      {
        key = "C5",
        label = "cleanup parent fsync",
        injections = {
          ["lock-scan-next-1"] = true,
          ["state-fsync-1"] = true,
        },
        injection_calls = 2,
        injection_delegates = 2,
        expected_error = AS .. "; " .. CF,
        state_lstats = 2,
        lock_lstats = 3,
        lock_realpaths = 1,
        lock_open_calls = 1,
        lock_open_delegates = 1,
        lock_lifetimes = 1,
        lock_fstats = 1,
        scan_calls = 1,
        fsync_calls = 1,
        rmdir_calls = 1,
        pre_cleanup_lock_lstats = 1,
        outcome = ABS,
        expected_events = cleanup_full_events,
      },
      {
        key = "C6",
        label = "parent close",
        injections = {
          ["lock-scan-next-1"] = true,
          ["state-close-1-error"] = true,
        },
        injection_calls = 2,
        injection_delegates = 2,
        expected_error = AS .. "; " .. CCS,
        state_lstats = 2,
        lock_lstats = 3,
        lock_realpaths = 1,
        lock_open_calls = 1,
        lock_open_delegates = 1,
        lock_lifetimes = 1,
        lock_fstats = 1,
        scan_calls = 1,
        fsync_calls = 1,
        rmdir_calls = 1,
        pre_cleanup_lock_lstats = 1,
        outcome = ABS,
        expected_events = cleanup_full_events,
      },
      {
        key = "C7",
        label = "ordering canary",
        injections = {
          ["lock-scan-next-1"] = true,
          ["lock-close-1-error"] = true,
          ["lock-lstat-3-absence-error"] = true,
          ["state-fsync-1"] = true,
          ["state-close-1-error"] = true,
        },
        injection_calls = 5,
        injection_delegates = 5,
        expected_error = AS .. "; " .. CCL .. "; " .. CVA .. "; " .. CF .. "; " .. CCS,
        state_lstats = 2,
        lock_lstats = 3,
        lock_realpaths = 1,
        lock_open_calls = 1,
        lock_open_delegates = 1,
        lock_lifetimes = 1,
        lock_fstats = 1,
        scan_calls = 1,
        fsync_calls = 1,
        rmdir_calls = 1,
        pre_cleanup_lock_lstats = 1,
        outcome = ABS,
        expected_events = cleanup_full_events,
      },
      {
        key = "D1",
        label = "directory replacement",
        injections = {
          ["lock-scan-next-1"] = true,
          ["swap-after-lock-close"] = true,
        },
        injection_calls = 1,
        injection_delegates = 1,
        expected_error = AS .. "; " .. CVL,
        state_lstats = 2,
        lock_lstats = 2,
        lock_realpaths = 1,
        lock_open_calls = 1,
        lock_open_delegates = 1,
        lock_lifetimes = 1,
        lock_fstats = 1,
        scan_calls = 1,
        fsync_calls = 0,
        rmdir_calls = 0,
        swap_kind = "directory",
        outcome = SWAP,
        expected_events = cleanup_validation_stop_events,
      },
      {
        key = "D2",
        label = "symlink replacement",
        injections = {
          ["lock-scan-next-1"] = true,
          ["swap-after-lock-close"] = true,
        },
        injection_calls = 1,
        injection_delegates = 1,
        expected_error = AS .. "; " .. CVL,
        state_lstats = 2,
        lock_lstats = 2,
        lock_realpaths = 1,
        lock_open_calls = 1,
        lock_open_delegates = 1,
        lock_lifetimes = 1,
        lock_fstats = 1,
        scan_calls = 1,
        fsync_calls = 0,
        rmdir_calls = 0,
        swap_kind = "symlink",
        outcome = SWAP,
        expected_events = cleanup_validation_stop_events,
      },
    }

    for _, test_case in ipairs(cases) do
      run_case(test_case)
    end

    expect_count("cycle-2d", "executed rows", executed_rows, 15)
    expect_count("cycle-2d", "observation rows", #observations, 15)
    assert(
      #failures == 0,
      "serialization durable acquisition primary failures: "
        .. table.concat(failures, "; ")
        .. " | observations: "
        .. table.concat(observations, "; ")
    )
  end

  do
    local ABS = { { path = ".", type = "absent" } }
    local lock_name = ".baseline-serialization"
    local complete_failure = table.concat({
      "baseline serialization release failed: close-lock (EIO)",
      "baseline serialization release failed: verify-lock-absent (EIO)",
      "baseline serialization release failed: fsync-state-root (EIO)",
      "baseline serialization release failed: close-state-root (EIO)",
    }, "; ")
    local operation_names = {
      "lstat",
      "realpath",
      "open",
      "fstat",
      "mkdir",
      "scandir",
      "scandir_next",
      "fsync",
      "close",
      "rmdir",
    }
    local native = {
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
    local failures = {}
    local observations = {}
    local executed_rows = 0

    local function add_failure(row, detail)
      table.insert(row.failures, detail)
    end

    local function identity(stat)
      if type(stat) ~= "table" then
        return nil
      end
      return {
        dev = stat.dev,
        ino = stat.ino,
        uid = stat.uid,
        type = stat.type,
        mode = type(stat.mode) == "number" and mode_bits(stat) or nil,
      }
    end

    local function same_identity(left, right)
      return left
        and right
        and left.dev == right.dev
        and left.ino == right.ino
        and left.uid == right.uid
        and left.type == right.type
        and left.mode == right.mode
    end

    local function is_enoent(stat, stat_error, stat_code)
      return stat == nil
        and (
          stat_code == "ENOENT"
          or tostring(stat_error):find("ENOENT", 1, true) ~= nil
          or tostring(stat_error):find("no such file", 1, true) ~= nil
        )
    end

    local function protected_snapshot(path)
      return xpcall(function()
        return snapshot_tree(path)
      end, function()
        return "snapshot failed"
      end)
    end

    local function capture_release(lease)
      local capture = {
        ok = false,
        tuple = { n = 2 },
      }
      local ok, thrown = xpcall(function()
        capture.tuple[1], capture.tuple[2] = lease:release()
      end, function(err)
        return tostring(err)
      end)
      capture.ok = ok
      if not ok then
        capture.thrown = thrown
      end
      return capture
    end

    local function add_visible_capture(row, capture)
      table.insert(row.captures, capture)
      for index = 1, capture.tuple.n do
        if capture.tuple[index] ~= nil then
          table.insert(row.visible_results, tostring(capture.tuple[index]))
        end
      end
      if capture.thrown ~= nil then
        table.insert(row.visible_results, tostring(capture.thrown))
      end
    end

    local function new_path_counter()
      return {
        state = 0,
        lock = 0,
        unexpected = 0,
      }
    end

    local function new_operation_counters()
      local counters = {}
      for _, operation in ipairs(operation_names) do
        counters[operation] = new_path_counter()
      end
      return counters
    end

    local function path_category(path, state_root, lock_path)
      if path == state_root then
        return "state"
      end
      if path == lock_path then
        return "lock"
      end
      return "unexpected"
    end

    local function lifetime_snapshot(telemetry)
      local result = {}
      for _, lifetime in ipairs(telemetry.lifetimes) do
        table.insert(result, {
          fd = lifetime.fd,
          generation = lifetime.generation,
          path = lifetime.path,
          category = lifetime.category,
          active = lifetime.active,
          release_close_attempts = lifetime.release_close_attempts,
          release_physical_closes = lifetime.release_physical_closes,
        })
      end
      return result
    end

    local function telemetry_snapshot(telemetry)
      return {
        calls = copy(telemetry.calls),
        delegates = copy(telemetry.delegates),
        events = copy(telemetry.events),
        native_results = copy(telemetry.native_results),
        post_delegation = copy(telemetry.post_delegation),
        injection_count = telemetry.injection_count,
        injection_payloads = copy(telemetry.injection_payloads),
        injection_native_ok = telemetry.injection_native_ok,
        lifetimes = lifetime_snapshot(telemetry),
        live_generation_reuse = telemetry.live_generation_reuse,
        unowned_close_attempts = telemetry.unowned_close_attempts,
        extra_physical_closes = telemetry.extra_physical_closes,
        physical_closes = telemetry.physical_closes,
        uid_calls = telemetry.uid_calls,
        uid_delegates = telemetry.uid_delegates,
        uid_unexpected_arguments = telemetry.uid_unexpected_arguments,
        nested_calls = telemetry.nested_calls,
        nested_guard_hits = telemetry.nested_guard_hits,
        nested_activity_unchanged = telemetry.nested_activity_unchanged,
        rescue_count = telemetry.rescue_count,
        fallback_calls = telemetry.fallback_calls,
      }
    end

    local function instrumented_dependencies(row, spec)
      local telemetry = {
        phase = "acquisition",
        calls = new_operation_counters(),
        delegates = new_operation_counters(),
        events = {},
        native_results = {},
        post_delegation = {},
        injection_count = 0,
        injection_payloads = {},
        injection_native_ok = true,
        lifetimes = {},
        generations = {},
        active_by_fd = {},
        latest_by_fd = {},
        scanner_categories = {},
        live_generation_reuse = 0,
        unowned_close_attempts = 0,
        extra_physical_closes = 0,
        physical_closes = 0,
        uid_calls = 0,
        uid_delegates = 0,
        uid_unexpected_arguments = 0,
        nested_calls = 0,
        nested_guard = false,
        nested_guard_hits = 0,
        nested_activity_unchanged = nil,
        nested_capture = nil,
        rescue_count = 0,
        fallback_calls = 0,
      }
      local dependencies = {}

      local function descriptor(fd)
        local lifetime = telemetry.active_by_fd[fd] or telemetry.latest_by_fd[fd]
        if lifetime then
          return lifetime.category, lifetime.generation, lifetime
        end
        return "unexpected", 0, nil
      end

      local function call(operation, category, generation)
        if telemetry.phase ~= "release" then
          return 0
        end
        local counter = telemetry.calls[operation]
        counter[category] = counter[category] + 1
        local ordinal = counter[category]
        table.insert(
          telemetry.events,
          string.format("%s:%s:g%d:%d", operation, category, generation or 0, ordinal)
        )
        return ordinal
      end

      local function delegate(operation, category)
        if telemetry.phase == "release" then
          telemetry.delegates[operation][category] = telemetry.delegates[operation][category] + 1
        end
      end

      local function result(operation, category, value)
        if telemetry.phase ~= "release" then
          return
        end
        telemetry.native_results[operation] = telemetry.native_results[operation] or {}
        telemetry.native_results[operation][category] = telemetry.native_results[operation][category]
          or {}
        table.insert(telemetry.native_results[operation][category], value)
      end

      local function inject(operation, category, generation, ordinal, native_ok)
        telemetry.injection_count = telemetry.injection_count + 1
        table.insert(telemetry.injection_payloads, row.injected_payload)
        telemetry.injection_native_ok = telemetry.injection_native_ok and native_ok
        table.insert(
          telemetry.post_delegation,
          string.format(
            "native:%s:%s:g%d:%d:%s",
            operation,
            category,
            generation,
            ordinal,
            tostring(native_ok)
          )
        )
        table.insert(
          telemetry.post_delegation,
          string.format("inject:%s:%s:g%d:%d", operation, category, generation, ordinal)
        )
      end

      dependencies.uid = function(...)
        if telemetry.phase == "release" then
          telemetry.uid_calls = telemetry.uid_calls + 1
          if select("#", ...) ~= 0 then
            telemetry.uid_unexpected_arguments = telemetry.uid_unexpected_arguments + 1
          end
          telemetry.uid_delegates = telemetry.uid_delegates + 1
        end
        return native.uid(...)
      end

      dependencies.lstat = function(path)
        local category = path_category(path, row.state_root, row.lock_path)
        local ordinal = call("lstat", category, 0)
        delegate("lstat", category)
        local stat, stat_error, stat_code = native.lstat(path)
        result("lstat", category, {
          exists = stat ~= nil,
          identity = identity(stat),
          enoent = is_enoent(stat, stat_error, stat_code),
          code = stat_code,
        })
        if spec.key == "S1" and category == "lock" and ordinal == 3 then
          local native_ok = is_enoent(stat, stat_error, stat_code)
          inject("lstat", category, 0, ordinal, native_ok)
          return nil, row.injected_payload, "EIO"
        end
        return stat, stat_error, stat_code
      end

      dependencies.realpath = function(path)
        local category = path_category(path, row.state_root, row.lock_path)
        local ordinal = call("realpath", category, 0)
        delegate("realpath", category)
        local physical, realpath_error, realpath_code = native.realpath(path)
        result("realpath", category, {
          path = physical,
          ordinal = ordinal,
          code = realpath_code,
        })
        return physical, realpath_error, realpath_code
      end

      dependencies.open = function(path, flags, mode)
        local category = path_category(path, row.state_root, row.lock_path)
        call("open", category, 0)
        delegate("open", category)
        local fd, open_error, open_code = native.open(path, flags, mode)
        if fd ~= nil then
          local prior = telemetry.active_by_fd[fd]
          if prior and prior.active then
            telemetry.live_generation_reuse = telemetry.live_generation_reuse + 1
          end
          local generation = (telemetry.generations[fd] or 0) + 1
          telemetry.generations[fd] = generation
          local lifetime = {
            fd = fd,
            generation = generation,
            path = path,
            category = category,
            active = true,
            release_close_attempts = 0,
            release_physical_closes = 0,
          }
          table.insert(telemetry.lifetimes, lifetime)
          telemetry.active_by_fd[fd] = lifetime
          telemetry.latest_by_fd[fd] = lifetime
        end
        return fd, open_error, open_code
      end

      dependencies.fstat = function(fd)
        local category, generation = descriptor(fd)
        local ordinal = call("fstat", category, generation)
        if telemetry.phase == "release" and spec.key == "S2" and category == "state" then
          if telemetry.nested_guard then
            telemetry.nested_guard_hits = telemetry.nested_guard_hits + 1
          elseif telemetry.nested_calls == 0 and ordinal == 1 then
            telemetry.nested_calls = telemetry.nested_calls + 1
            telemetry.nested_guard = true
            local before = telemetry_snapshot(telemetry)
            telemetry.nested_capture = capture_release(telemetry.lease)
            local after = telemetry_snapshot(telemetry)
            telemetry.nested_activity_unchanged = vim.deep_equal(after, before)
            telemetry.nested_guard = false
          end
        end
        delegate("fstat", category)
        local stat, stat_error, stat_code = native.fstat(fd)
        result("fstat", category, {
          exists = stat ~= nil,
          identity = identity(stat),
          code = stat_code,
        })
        return stat, stat_error, stat_code
      end

      dependencies.mkdir = function(path, mode)
        local category = path_category(path, row.state_root, row.lock_path)
        call("mkdir", category, 0)
        delegate("mkdir", category)
        return native.mkdir(path, mode)
      end

      dependencies.scandir = function(path)
        local category = path_category(path, row.state_root, row.lock_path)
        call("scandir", category, 0)
        delegate("scandir", category)
        local scanner, scan_error, scan_code = native.scandir(path)
        if scanner ~= nil then
          telemetry.scanner_categories[scanner] = category
        end
        return scanner, scan_error, scan_code
      end

      dependencies.scandir_next = function(scanner)
        local category = telemetry.scanner_categories[scanner] or "unexpected"
        call("scandir_next", category, 0)
        delegate("scandir_next", category)
        return native.scandir_next(scanner)
      end

      dependencies.fsync = function(fd)
        local category, generation = descriptor(fd)
        local ordinal = call("fsync", category, generation)
        delegate("fsync", category)
        local synced, sync_error, sync_code = native.fsync(fd)
        result("fsync", category, {
          synced = synced,
          code = sync_code,
        })
        if spec.key == "S1" and category == "state" and ordinal == 1 then
          inject("fsync", category, generation, ordinal, synced == true)
          return nil, row.injected_payload, "EIO"
        end
        return synced, sync_error, sync_code
      end

      dependencies.close = function(fd)
        local category, generation, lifetime = descriptor(fd)
        local ordinal = call("close", category, generation)
        if telemetry.phase == "release" then
          if lifetime then
            lifetime.release_close_attempts = lifetime.release_close_attempts + 1
          else
            telemetry.unowned_close_attempts = telemetry.unowned_close_attempts + 1
          end
        end
        delegate("close", category)
        local close_ok, closed, close_error, close_code = pcall(native.close, fd)
        if not close_ok then
          close_code = "UNKNOWN"
          close_error = "native close raised"
          closed = nil
        end
        if closed == true then
          if lifetime and lifetime.active and telemetry.active_by_fd[fd] == lifetime then
            lifetime.active = false
            telemetry.active_by_fd[fd] = nil
            if telemetry.phase == "release" then
              lifetime.release_physical_closes = lifetime.release_physical_closes + 1
              telemetry.physical_closes = telemetry.physical_closes + 1
            end
          elseif telemetry.phase == "release" then
            telemetry.extra_physical_closes = telemetry.extra_physical_closes + 1
          end
        end
        result("close", category, {
          closed = closed,
          code = close_code,
        })
        if spec.key == "S1" and ordinal == 1 and (category == "lock" or category == "state") then
          inject("close", category, generation, ordinal, close_ok and closed == true)
          return nil, row.injected_payload, "EIO"
        end
        return closed, close_error, close_code
      end

      dependencies.rmdir = function(path)
        local category = path_category(path, row.state_root, row.lock_path)
        local ordinal = call("rmdir", category, 0)
        delegate("rmdir", category)
        local removed, remove_error, remove_code = native.rmdir(path)
        result("rmdir", category, {
          removed = removed,
          ordinal = ordinal,
          code = remove_code,
        })
        return removed, remove_error, remove_code
      end

      return dependencies, telemetry
    end

    local function begin_release(telemetry)
      telemetry.calls = new_operation_counters()
      telemetry.delegates = new_operation_counters()
      telemetry.events = {}
      telemetry.native_results = {}
      telemetry.post_delegation = {}
      telemetry.injection_count = 0
      telemetry.injection_payloads = {}
      telemetry.injection_native_ok = true
      telemetry.live_generation_reuse = 0
      telemetry.unowned_close_attempts = 0
      telemetry.extra_physical_closes = 0
      telemetry.physical_closes = 0
      telemetry.uid_calls = 0
      telemetry.uid_delegates = 0
      telemetry.uid_unexpected_arguments = 0
      telemetry.nested_calls = 0
      telemetry.nested_guard = false
      telemetry.nested_guard_hits = 0
      telemetry.nested_activity_unchanged = nil
      telemetry.nested_capture = nil
      telemetry.rescue_count = 0
      telemetry.fallback_calls = 0
      for _, lifetime in ipairs(telemetry.lifetimes) do
        lifetime.release_close_attempts = 0
        lifetime.release_physical_closes = 0
      end
      telemetry.phase = "release"
    end

    local function complete_snapshot(row)
      local snapshot = telemetry_snapshot(row.telemetry)
      snapshot.filesystem = {
        state = snapshot_tree(row.state_root),
        lock = snapshot_tree(row.lock_path),
        reviews = snapshot_tree(row.reviews_path),
      }
      return snapshot
    end

    local function expect_count(row, detail, actual, expected)
      if actual ~= expected then
        add_failure(row, string.format("%s expected %d actual %d", detail, expected, actual))
      end
    end

    local function expect_path_counter(row, detail, counter, state_expected, lock_expected)
      expect_count(row, detail .. " state", counter.state, state_expected)
      expect_count(row, detail .. " lock", counter.lock, lock_expected)
      expect_count(row, detail .. " unexpected", counter.unexpected, 0)
    end

    local function validate_first(row, spec)
      local expected_tuple = spec.key == "S1" and { n = 2, [2] = complete_failure }
        or { n = 2, [1] = true }
      if not row.first_capture.ok then
        add_failure(row, "first release raised")
      elseif not vim.deep_equal(row.first_capture.tuple, expected_tuple) then
        add_failure(row, "first release tuple was not exact")
      end

      local expected_counts = {
        lstat = { 0, 3 },
        realpath = { 0, 1 },
        open = { 0, 0 },
        fstat = { 1, 1 },
        mkdir = { 0, 0 },
        scandir = { 0, 0 },
        scandir_next = { 0, 0 },
        fsync = { 1, 0 },
        close = { 1, 1 },
        rmdir = { 0, 1 },
      }
      for _, operation in ipairs(operation_names) do
        local expected = expected_counts[operation]
        expect_path_counter(
          row,
          operation .. " calls",
          row.first_activity.calls[operation],
          expected[1],
          expected[2]
        )
        expect_path_counter(
          row,
          operation .. " native delegations",
          row.first_activity.delegates[operation],
          expected[1],
          expected[2]
        )
      end
      expect_count(row, "UID calls", row.first_activity.uid_calls, 0)
      expect_count(row, "UID native delegations", row.first_activity.uid_delegates, 0)
      expect_count(row, "UID unexpected arguments", row.first_activity.uid_unexpected_arguments, 0)

      local expected_events = {
        "fstat:state:g1:1",
        "lstat:lock:g0:1",
        "fstat:lock:g1:1",
        "realpath:lock:g0:1",
        "lstat:lock:g0:2",
        "close:lock:g1:1",
        "rmdir:lock:g0:1",
        "lstat:lock:g0:3",
        "fsync:state:g1:1",
        "close:state:g1:1",
      }
      if not vim.deep_equal(row.first_activity.events, expected_events) then
        add_failure(row, "first release event order was not exact")
      end

      local results = row.first_activity.native_results
      local state_fstat = results.fstat and results.fstat.state and results.fstat.state[1]
      local lock_fstat = results.fstat and results.fstat.lock and results.fstat.lock[1]
      local first_lstat = results.lstat and results.lstat.lock and results.lstat.lock[1]
      local final_lstat = results.lstat and results.lstat.lock and results.lstat.lock[2]
      local absence_lstat = results.lstat and results.lstat.lock and results.lstat.lock[3]
      local realpath = results.realpath and results.realpath.lock and results.realpath.lock[1]
      local lock_close = results.close and results.close.lock and results.close.lock[1]
      local state_close = results.close and results.close.state and results.close.state[1]
      local rmdir = results.rmdir and results.rmdir.lock and results.rmdir.lock[1]
      local fsync = results.fsync and results.fsync.state and results.fsync.state[1]
      if
        not state_fstat
        or not state_fstat.exists
        or not same_identity(state_fstat.identity, row.state_identity)
      then
        add_failure(row, "state validation did not return the acquired identity")
      end
      if
        not first_lstat
        or not first_lstat.exists
        or not same_identity(first_lstat.identity, row.lock_identity)
      then
        add_failure(row, "lock-path validation did not return the acquired identity")
      end
      if
        not lock_fstat
        or not lock_fstat.exists
        or not same_identity(lock_fstat.identity, row.lock_identity)
      then
        add_failure(row, "lock-descriptor validation did not return the acquired identity")
      end
      if not realpath or realpath.path ~= row.lock_path then
        add_failure(row, "lock physical-path validation was not exact")
      end
      if
        not final_lstat
        or not final_lstat.exists
        or not same_identity(final_lstat.identity, row.lock_identity)
      then
        add_failure(row, "final lock-path validation did not return the acquired identity")
      end
      if not lock_close or lock_close.closed ~= true then
        add_failure(row, "lock native close did not succeed")
      end
      if not rmdir or rmdir.removed ~= true then
        add_failure(row, "exact lock native rmdir did not succeed")
      end
      if not absence_lstat or not absence_lstat.enoent then
        add_failure(row, "native lock absence proof was not ENOENT")
      end
      if not fsync or fsync.synced ~= true then
        add_failure(row, "state-root native fsync did not succeed")
      end
      if not state_close or state_close.closed ~= true then
        add_failure(row, "state-root native close did not succeed")
      end

      if not vim.deep_equal(row.first_activity.filesystem.reviews, row.reviews_before) then
        add_failure(row, "content-aware reviews snapshot changed")
      end
      if not vim.deep_equal(row.first_activity.filesystem.lock, ABS) then
        add_failure(row, "first release lock outcome was not exact ABS")
      end

      local lifetime_counts = { state = 0, lock = 0, unexpected = 0 }
      for _, lifetime in ipairs(row.first_activity.lifetimes) do
        lifetime_counts[lifetime.category] = lifetime_counts[lifetime.category] + 1
        if lifetime.generation ~= 1 then
          add_failure(row, "owned descriptor generation was not one")
        end
        if lifetime.release_close_attempts ~= 1 then
          add_failure(row, "owned lifetime did not receive exactly one release close attempt")
        end
        if lifetime.release_physical_closes ~= 1 or lifetime.active then
          add_failure(row, "owned lifetime was not physically closed exactly once")
        end
      end
      expect_count(row, "state descriptor lifetimes", lifetime_counts.state, 1)
      expect_count(row, "lock descriptor lifetimes", lifetime_counts.lock, 1)
      expect_count(row, "unexpected descriptor lifetimes", lifetime_counts.unexpected, 0)
      expect_count(row, "live generation reuse", row.first_activity.live_generation_reuse, 0)
      expect_count(row, "unowned close attempts", row.first_activity.unowned_close_attempts, 0)
      expect_count(row, "extra physical closes", row.first_activity.extra_physical_closes, 0)
      expect_count(row, "physical closes", row.first_activity.physical_closes, 2)
      expect_count(row, "rescue calls", row.first_activity.rescue_count, 0)
      expect_count(row, "fallback release calls", row.first_activity.fallback_calls, 0)

      if spec.key == "S1" then
        local expected_post_delegation = {
          "native:close:lock:g1:1:true",
          "inject:close:lock:g1:1",
          "native:lstat:lock:g0:3:true",
          "inject:lstat:lock:g0:3",
          "native:fsync:state:g1:1:true",
          "inject:fsync:state:g1:1",
          "native:close:state:g1:1:true",
          "inject:close:state:g1:1",
        }
        expect_count(row, "post-delegation injections", row.first_activity.injection_count, 4)
        if not row.first_activity.injection_native_ok then
          add_failure(row, "an injected release failure lacked its native result")
        end
        if not vim.deep_equal(row.first_activity.post_delegation, expected_post_delegation) then
          add_failure(row, "post-delegation injection order was not exact")
        end
        for _, payload in ipairs(row.first_activity.injection_payloads) do
          if payload ~= row.injected_payload then
            add_failure(row, "an injected error field did not use the shared oversized payload")
          end
        end
      else
        expect_count(row, "post-delegation injections", row.first_activity.injection_count, 0)
      end

      if spec.key == "S2" then
        expect_count(row, "nested release calls", row.first_activity.nested_calls, 1)
        expect_count(row, "nested recursion-guard hits", row.first_activity.nested_guard_hits, 0)
        if not row.telemetry.nested_capture or not row.telemetry.nested_capture.ok then
          add_failure(row, "nested release raised or was not observed")
        end
        if row.first_activity.nested_activity_unchanged ~= true then
          add_failure(row, "nested release added dependency or lifetime activity")
        end
      else
        expect_count(row, "nested release calls", row.first_activity.nested_calls, 0)
      end
    end

    local function exercise_row(row, spec)
      row.state_root = make_root("serialization-release-e1-" .. spec.key)
      row.lock_path = vim.fs.joinpath(row.state_root, lock_name)
      row.reviews_path = vim.fs.joinpath(row.state_root, "reviews")
      row.control_path = vim.fs.joinpath(row.reviews_path, "control.bin")
      row.link_path = vim.fs.joinpath(row.reviews_path, "control-link")
      row.private_paths = {
        row.state_root,
        row.lock_path,
        row.reviews_path,
        row.control_path,
        row.link_path,
      }
      assert(vim.fn.mkdir(row.reviews_path, "p", 448) == 1, "could not create E1 reviews")
      assert(vim.uv.fs_chmod(row.reviews_path, 448), "could not chmod E1 reviews")
      write_file(row.control_path, "cycle-2e-release-control\n", 384)
      assert(vim.uv.fs_symlink("control.bin", row.link_path), "could not create E1 control symlink")
      row.reviews_before = snapshot_tree(row.reviews_path)
      local control_exact = false
      local link_exact = false
      for _, entry in ipairs(row.reviews_before) do
        if
          entry.path == "control.bin"
          and entry.sha256 == vim.fn.sha256("cycle-2e-release-control\n")
        then
          control_exact = true
        elseif entry.path == "control-link" and entry.target == "control.bin" then
          link_exact = true
        end
      end
      if not control_exact or not link_exact then
        add_failure(row, "reviews control digest or symlink target was not exact")
      end

      row.injected_payload = (
        "injected Cycle 2E release payload state="
        .. row.state_root
        .. " lock="
        .. row.lock_path
        .. " reviews="
        .. row.reviews_path
        .. " private=/fixed/private/fixture "
      ):rep(96)
      if #row.injected_payload <= 8192 then
        add_failure(row, "injected path-bearing payload was not longer than 8 KiB")
      end

      local dependencies, telemetry = instrumented_dependencies(row, spec)
      row.telemetry = telemetry
      local lease, acquire_error = serialization.acquire(row.state_root, dependencies)
      if not lease then
        if acquire_error ~= nil then
          table.insert(row.visible_results, tostring(acquire_error))
        end
        add_failure(row, "successful acquisition setup failed")
        return
      end
      if acquire_error ~= nil then
        table.insert(row.visible_results, tostring(acquire_error))
        add_failure(row, "successful acquisition returned an error")
      end
      row.lease = lease
      telemetry.lease = lease
      row.acquired_lifetimes = lifetime_snapshot(telemetry)
      begin_release(telemetry)

      row.state_identity = identity(assert(native.lstat(row.state_root)))
      local lock_stat = assert(native.lstat(row.lock_path))
      row.lock_identity = identity(lock_stat)
      row.lock_before = snapshot_tree(row.lock_path)
      if
        #row.lock_before ~= 1
        or row.lock_before[1].type ~= "directory"
        or row.lock_before[1].mode ~= 448
        or row.lock_before[1].uid ~= native.uid()
      then
        add_failure(row, "acquired lock was not an exact private empty directory")
      end
      if #row.acquired_lifetimes ~= 2 then
        add_failure(row, "acquisition did not retain exactly two descriptor lifetimes")
      end

      row.external_release_calls = row.external_release_calls + 1
      row.first_capture = capture_release(lease)
      add_visible_capture(row, row.first_capture)
      if telemetry.nested_capture then
        add_visible_capture(row, telemetry.nested_capture)
      end
      row.first_activity = complete_snapshot(row)
      validate_first(row, spec)

      row.repeat_tuples_equal = true
      row.repeat_activity_stable = true
      for _ = 1, 2 do
        row.external_release_calls = row.external_release_calls + 1
        local repeated = capture_release(lease)
        add_visible_capture(row, repeated)
        if not repeated.ok or not vim.deep_equal(repeated.tuple, row.first_capture.tuple) then
          row.repeat_tuples_equal = false
        end
        local repeated_activity = complete_snapshot(row)
        if not vim.deep_equal(repeated_activity, row.first_activity) then
          row.repeat_activity_stable = false
        end
      end
      if not row.repeat_tuples_equal then
        add_failure(row, "repeated releases did not return the complete cached first tuple")
      end
      if not row.repeat_activity_stable then
        add_failure(row, "repeated releases changed telemetry, lifetimes, or filesystem snapshots")
      end
    end

    local function finish_row(row, spec, protected_ok, protected_error)
      if not protected_ok then
        table.insert(row.visible_results, tostring(protected_error))
        add_failure(row, "protected row capture raised")
      end

      local all_closed = true
      if row.telemetry then
        for _, lifetime in ipairs(row.telemetry.lifetimes) do
          if lifetime.active then
            row.telemetry.rescue_count = row.telemetry.rescue_count + 1
            add_failure(row, "an exact live owned generation required rescue")
            local current = row.telemetry.active_by_fd[lifetime.fd]
            if current == lifetime and current.generation == lifetime.generation then
              local rescue_ok, rescued = pcall(native.close, lifetime.fd)
              if rescue_ok and rescued == true then
                lifetime.active = false
                row.telemetry.active_by_fd[lifetime.fd] = nil
              end
            end
          end
          if lifetime.active then
            all_closed = false
          end
        end
        if row.telemetry.rescue_count ~= 0 then
          add_failure(row, "descriptor rescue count was not zero")
        end
        if row.telemetry.fallback_calls ~= 0 then
          add_failure(row, "release was retried as teardown")
        end
        if row.telemetry.extra_physical_closes ~= 0 then
          add_failure(row, "an extra descriptor was physically closed")
        end
        for _, lifetime in ipairs(row.telemetry.lifetimes) do
          if lifetime.release_close_attempts ~= 1 then
            add_failure(row, "final owned lifetime close-attempt count was not one")
          end
          if lifetime.release_physical_closes ~= 1 then
            add_failure(row, "final owned lifetime physical-close count was not one")
          end
        end
      end

      if row.external_release_calls ~= 3 then
        add_failure(row, "external release-call count was not three")
      end

      local first_kind = "missing"
      if row.first_capture then
        if
          row.first_capture.ok
          and row.first_capture.tuple[1] == true
          and row.first_capture.tuple[2] == nil
        then
          first_kind = "success"
        elseif
          row.first_capture.ok
          and row.first_capture.tuple[1] == nil
          and row.first_capture.tuple[2] == complete_failure
        then
          first_kind = "complete-failure"
        elseif row.first_capture.ok then
          first_kind = "other"
        else
          first_kind = "raised"
        end
      end
      local events = row.first_activity and table.concat(row.first_activity.events, ",") or "none"
      local lock_absent = row.first_activity
        and vim.deep_equal(row.first_activity.filesystem.lock, ABS)
      local reviews_exact = row.first_activity
        and vim.deep_equal(row.first_activity.filesystem.reviews, row.reviews_before)
      row.observation = string.format(
        "%s first=%s repeat-tuple=%s repeat-activity=%s nested=%d/%s abs=%s reviews=%s rescue=%d events=%s",
        spec.key,
        first_kind,
        tostring(row.repeat_tuples_equal),
        tostring(row.repeat_activity_stable),
        row.telemetry and row.telemetry.nested_calls or 0,
        tostring(row.telemetry and row.telemetry.nested_activity_unchanged),
        tostring(lock_absent),
        tostring(reviews_exact),
        row.telemetry and row.telemetry.rescue_count or 0,
        events
      )
      table.insert(observations, row.observation)

      if row.state_root and all_closed then
        local removed = vim.fn.delete(row.state_root, "rf")
        if removed ~= 0 then
          add_failure(row, "exact private row-root teardown failed")
        end
        local stat, stat_error, stat_code = native.lstat(row.state_root)
        if not is_enoent(stat, stat_error, stat_code) then
          add_failure(row, "exact private row-root absence was not proven")
        end
      elseif row.state_root then
        add_failure(row, "private row root retained because an owned descriptor remained live")
      end

      for _, result_text in ipairs(row.visible_results) do
        if #result_text > 1024 then
          add_failure(row, "a public or observed release string was not bounded")
        end
      end
      local visible = copy(row.visible_results)
      vim.list_extend(visible, row.failures)
      table.insert(visible, row.observation)
      local forbidden = { row.injected_payload }
      vim.list_extend(forbidden, row.private_paths or {})
      local leak_found = false
      for _, text in ipairs(visible) do
        for _, needle in ipairs(forbidden) do
          if type(needle) == "string" and #needle > 0 and text:find(needle, 1, true) then
            leak_found = true
          end
        end
      end
      if leak_found then
        add_failure(row, "a payload or private fixture path reached a visible result")
      end

      for _, detail in ipairs(row.failures) do
        table.insert(failures, row.label .. " " .. detail)
      end
    end

    local cases = {
      { key = "S0", label = "cached success" },
      { key = "S1", label = "cached complete failure" },
      { key = "S2", label = "consumed before first dependency" },
    }
    for _, spec in ipairs(cases) do
      executed_rows = executed_rows + 1
      local row = {
        label = spec.key .. " " .. spec.label,
        failures = {},
        captures = {},
        visible_results = {},
        private_paths = {},
        external_release_calls = 0,
        repeat_tuples_equal = false,
        repeat_activity_stable = false,
      }
      local protected_ok, protected_error = xpcall(function()
        exercise_row(row, spec)
      end, function(err)
        return tostring(err)
      end)
      finish_row(row, spec, protected_ok, protected_error)
    end

    if executed_rows ~= 3 then
      table.insert(failures, "Cycle 2E E1 did not execute exactly three rows")
    end
    if #observations ~= 3 then
      table.insert(failures, "Cycle 2E E1 did not record exactly three observations")
    end
    assert(
      #failures == 0,
      "serialization Cycle 2E E1 release failures: "
        .. table.concat(failures, "; ")
        .. " | observations: "
        .. table.concat(observations, "; ")
    )
  end

  do
    local ABS = { { path = ".", type = "absent" } }
    local RVL = "baseline serialization release failed: validate-lock (UNKNOWN)"
    local lock_name = ".baseline-serialization"
    local fixed_private_path = "/fixed/private/cycle-2e-e2-v3"
    local shared_payload = (
      "injected Cycle 2E E2 diagnostic payload private="
      .. fixed_private_path
      .. " lock=/fixed/private/cycle-2e-e2-v3/.baseline-serialization "
    ):rep(128)
    local operation_names = {
      "lstat",
      "realpath",
      "open",
      "fstat",
      "mkdir",
      "scandir",
      "scandir_next",
      "fsync",
      "close",
      "rmdir",
    }
    local native = {
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
      rename = vim.uv.fs_rename,
      symlink = vim.uv.fs_symlink,
      uid = vim.uv.getuid,
    }
    local failures = {}
    local observations = {}
    local executed_rows = 0

    local function add_failure(row, detail)
      table.insert(row.failures, detail)
    end

    local function identity(stat)
      if type(stat) ~= "table" then
        return nil
      end
      return {
        dev = stat.dev,
        ino = stat.ino,
        uid = stat.uid,
        type = stat.type,
        mode = type(stat.mode) == "number" and mode_bits(stat) or nil,
      }
    end

    local function same_identity(left, right)
      return left
        and right
        and left.dev == right.dev
        and left.ino == right.ino
        and left.uid == right.uid
        and left.type == right.type
        and left.mode == right.mode
    end

    local function is_enoent(stat, stat_error, stat_code)
      return stat == nil
        and (
          stat_code == "ENOENT"
          or tostring(stat_error):find("ENOENT", 1, true) ~= nil
          or tostring(stat_error):find("no such file", 1, true) ~= nil
        )
    end

    local function contained_path(root, path)
      return type(path) == "string"
        and vim.fs.normalize(path) == path
        and path:sub(1, #root + 1) == root .. "/"
    end

    local function protected_snapshot(path)
      local ok, value = xpcall(function()
        return snapshot_tree(path)
      end, function()
        return "snapshot failed"
      end)
      return {
        ok = ok,
        value = ok and value or nil,
      }
    end

    local function capture_release(lease)
      local capture = {
        ok = false,
        tuple = { n = 2 },
      }
      local ok = xpcall(function()
        capture.tuple[1], capture.tuple[2] = lease:release()
      end, function()
        return "release capture failed"
      end)
      capture.ok = ok
      if not ok then
        capture.failure = "release capture failed"
      end
      return capture
    end

    local function add_visible_capture(row, capture)
      table.insert(row.captures, capture)
      for index = 1, capture.tuple.n do
        if capture.tuple[index] ~= nil then
          table.insert(row.visible_results, tostring(capture.tuple[index]))
        end
      end
      if capture.failure then
        table.insert(row.visible_results, capture.failure)
      end
    end

    local function new_path_counter()
      return {
        state = 0,
        lock = 0,
        unexpected = 0,
      }
    end

    local function new_operation_counters()
      local counters = {}
      for _, operation in ipairs(operation_names) do
        counters[operation] = new_path_counter()
      end
      return counters
    end

    local function path_category(path, row)
      if path == row.state_root then
        return "state"
      end
      if path == row.lock_path then
        return "lock"
      end
      return "unexpected"
    end

    local function lifetime_snapshot(telemetry)
      local result = {}
      for _, lifetime in ipairs(telemetry.lifetimes) do
        table.insert(result, {
          fd = lifetime.fd,
          generation = lifetime.generation,
          category = lifetime.category,
          active = lifetime.active,
          release_close_attempts = lifetime.release_close_attempts,
          release_physical_closes = lifetime.release_physical_closes,
        })
      end
      return result
    end

    local function telemetry_snapshot(telemetry)
      return {
        calls = copy(telemetry.calls),
        delegates = copy(telemetry.delegates),
        events = copy(telemetry.events),
        native_results = copy(telemetry.native_results),
        lifetimes = lifetime_snapshot(telemetry),
        generations = copy(telemetry.generations),
        live_generation_reuse = telemetry.live_generation_reuse,
        integer_fd_aliases = telemetry.integer_fd_aliases,
        unowned_close_attempts = telemetry.unowned_close_attempts,
        extra_physical_closes = telemetry.extra_physical_closes,
        physical_closes = telemetry.physical_closes,
        uid_calls = telemetry.uid_calls,
        uid_delegates = telemetry.uid_delegates,
        uid_unexpected_arguments = telemetry.uid_unexpected_arguments,
        swap = copy(telemetry.swap),
        rescue_count = telemetry.rescue_count,
        fallback_calls = telemetry.fallback_calls,
      }
    end

    local function filesystem_snapshot(row)
      return {
        state = protected_snapshot(row.state_root),
        lock = protected_snapshot(row.lock_path),
        reviews = protected_snapshot(row.reviews_path),
        retired = protected_snapshot(row.retired_path),
        staging = protected_snapshot(row.staging_path),
      }
    end

    local function snapshots_ok(filesystem)
      return filesystem.state.ok
        and filesystem.lock.ok
        and filesystem.reviews.ok
        and filesystem.retired.ok
        and filesystem.staging.ok
    end

    local function exact_v3_state_projection(snapshot)
      local expected = {
        ["."] = true,
        [lock_name] = true,
        [".cycle-2e-e2-v3-retired"] = true,
        reviews = true,
        ["reviews/control.bin"] = true,
        ["reviews/control-link"] = true,
      }
      local observed = {}
      for _, entry in ipairs(snapshot) do
        if not expected[entry.path] or observed[entry.path] then
          return false
        end
        observed[entry.path] = true
      end
      for path in pairs(expected) do
        if not observed[path] then
          return false
        end
      end
      return true
    end

    local function perform_v3_swap(row, telemetry)
      telemetry.swap.calls = telemetry.swap.calls + 1
      telemetry.swap.before_final_lstat = telemetry.calls.lstat.lock == 1
      telemetry.swap.paths_contained = contained_path(row.state_root, row.retired_path)
        and contained_path(row.state_root, row.staging_path)
        and contained_path(row.state_root, row.lock_path)

      telemetry.swap.rename_calls = telemetry.swap.rename_calls + 1
      local retired, retire_error, retire_code = native.rename(row.lock_path, row.retired_path)
      telemetry.swap.retire_error = retire_error and "present" or nil
      telemetry.swap.retire_code = retire_code
      if retired == true then
        telemetry.swap.rename_successes = telemetry.swap.rename_successes + 1
      else
        return
      end

      telemetry.swap.rename_calls = telemetry.swap.rename_calls + 1
      local installed, install_error, install_code = native.rename(row.staging_path, row.lock_path)
      telemetry.swap.install_error = install_error and "present" or nil
      telemetry.swap.install_code = install_code
      if installed == true then
        telemetry.swap.rename_successes = telemetry.swap.rename_successes + 1
        telemetry.swap.completed = true
      else
        return
      end

      telemetry.swap.post_swap = filesystem_snapshot(row)
      telemetry.swap.capture_ok = snapshots_ok(telemetry.swap.post_swap)
    end

    local function instrumented_dependencies(row)
      local telemetry = {
        phase = "acquisition",
        calls = new_operation_counters(),
        delegates = new_operation_counters(),
        events = {},
        native_results = {},
        lifetimes = {},
        generations = {},
        active_by_fd = {},
        latest_by_fd = {},
        scanner_categories = {},
        live_generation_reuse = 0,
        integer_fd_aliases = 0,
        unowned_close_attempts = 0,
        extra_physical_closes = 0,
        physical_closes = 0,
        uid_calls = 0,
        uid_delegates = 0,
        uid_unexpected_arguments = 0,
        swap = {
          calls = 0,
          rename_calls = 0,
          rename_successes = 0,
          completed = false,
          capture_ok = false,
          before_final_lstat = false,
          paths_contained = false,
          realpath_exact = false,
        },
        rescue_count = 0,
        fallback_calls = 0,
      }
      local dependencies = {}

      local function descriptor(fd)
        local lifetime = telemetry.active_by_fd[fd] or telemetry.latest_by_fd[fd]
        if lifetime then
          return lifetime.category, lifetime.generation, lifetime
        end
        return "unexpected", 0, nil
      end

      local function call(operation, category, generation)
        if telemetry.phase ~= "release" then
          return 0
        end
        local counter = telemetry.calls[operation]
        counter[category] = counter[category] + 1
        local ordinal = counter[category]
        table.insert(
          telemetry.events,
          string.format("%s:%s:g%d:%d", operation, category, generation or 0, ordinal)
        )
        return ordinal
      end

      local function delegate(operation, category)
        if telemetry.phase == "release" then
          telemetry.delegates[operation][category] = telemetry.delegates[operation][category] + 1
        end
      end

      local function result(operation, category, value)
        if telemetry.phase ~= "release" then
          return
        end
        telemetry.native_results[operation] = telemetry.native_results[operation] or {}
        telemetry.native_results[operation][category] = telemetry.native_results[operation][category]
          or {}
        table.insert(telemetry.native_results[operation][category], value)
      end

      dependencies.uid = function(...)
        if telemetry.phase == "release" then
          telemetry.uid_calls = telemetry.uid_calls + 1
          if select("#", ...) ~= 0 then
            telemetry.uid_unexpected_arguments = telemetry.uid_unexpected_arguments + 1
          end
          telemetry.uid_delegates = telemetry.uid_delegates + 1
        end
        return native.uid(...)
      end

      dependencies.lstat = function(path)
        local category = path_category(path, row)
        call("lstat", category, 0)
        delegate("lstat", category)
        local stat, stat_error, stat_code = native.lstat(path)
        result("lstat", category, {
          exists = stat ~= nil,
          identity = identity(stat),
          enoent = is_enoent(stat, stat_error, stat_code),
          code = stat_code,
        })
        return stat, stat_error, stat_code
      end

      dependencies.realpath = function(path)
        local category = path_category(path, row)
        local ordinal = call("realpath", category, 0)
        delegate("realpath", category)
        local physical, realpath_error, realpath_code = native.realpath(path)
        result("realpath", category, {
          path = physical,
          code = realpath_code,
        })
        if telemetry.phase == "release" and category == "lock" and ordinal == 1 then
          telemetry.swap.realpath_exact = physical == row.lock_path
          if telemetry.swap.realpath_exact then
            perform_v3_swap(row, telemetry)
          end
        end
        return physical, realpath_error, realpath_code
      end

      dependencies.open = function(path, flags, mode)
        local category = path_category(path, row)
        call("open", category, 0)
        delegate("open", category)
        local fd, open_error, open_code = native.open(path, flags, mode)
        if fd ~= nil then
          local prior = telemetry.active_by_fd[fd]
          if prior and prior.active then
            telemetry.live_generation_reuse = telemetry.live_generation_reuse + 1
            telemetry.integer_fd_aliases = telemetry.integer_fd_aliases + 1
          end
          local generation = (telemetry.generations[fd] or 0) + 1
          telemetry.generations[fd] = generation
          local lifetime = {
            fd = fd,
            generation = generation,
            category = category,
            active = true,
            release_close_attempts = 0,
            release_physical_closes = 0,
          }
          table.insert(telemetry.lifetimes, lifetime)
          telemetry.active_by_fd[fd] = lifetime
          telemetry.latest_by_fd[fd] = lifetime
        end
        return fd, open_error, open_code
      end

      dependencies.fstat = function(fd)
        local category, generation = descriptor(fd)
        call("fstat", category, generation)
        delegate("fstat", category)
        local stat, stat_error, stat_code = native.fstat(fd)
        result("fstat", category, {
          exists = stat ~= nil,
          identity = identity(stat),
          code = stat_code,
        })
        return stat, stat_error, stat_code
      end

      dependencies.mkdir = function(path, mode)
        local category = path_category(path, row)
        call("mkdir", category, 0)
        delegate("mkdir", category)
        return native.mkdir(path, mode)
      end

      dependencies.scandir = function(path)
        local category = path_category(path, row)
        call("scandir", category, 0)
        delegate("scandir", category)
        local scanner, scan_error, scan_code = native.scandir(path)
        if scanner ~= nil then
          telemetry.scanner_categories[scanner] = category
        end
        return scanner, scan_error, scan_code
      end

      dependencies.scandir_next = function(scanner)
        local category = telemetry.scanner_categories[scanner] or "unexpected"
        call("scandir_next", category, 0)
        delegate("scandir_next", category)
        return native.scandir_next(scanner)
      end

      dependencies.fsync = function(fd)
        local category, generation = descriptor(fd)
        call("fsync", category, generation)
        delegate("fsync", category)
        local synced, sync_error, sync_code = native.fsync(fd)
        result("fsync", category, {
          synced = synced,
          code = sync_code,
        })
        return synced, sync_error, sync_code
      end

      dependencies.close = function(fd)
        local category, generation, lifetime = descriptor(fd)
        call("close", category, generation)
        if telemetry.phase == "release" then
          if lifetime then
            lifetime.release_close_attempts = lifetime.release_close_attempts + 1
          else
            telemetry.unowned_close_attempts = telemetry.unowned_close_attempts + 1
          end
        end
        delegate("close", category)
        local close_ok, closed, close_error, close_code = pcall(native.close, fd)
        if not close_ok then
          closed = nil
          close_error = "native close failed"
          close_code = "UNKNOWN"
        end
        if closed == true then
          if lifetime and lifetime.active and telemetry.active_by_fd[fd] == lifetime then
            lifetime.active = false
            telemetry.active_by_fd[fd] = nil
            if telemetry.phase == "release" then
              lifetime.release_physical_closes = lifetime.release_physical_closes + 1
              telemetry.physical_closes = telemetry.physical_closes + 1
            end
          elseif telemetry.phase == "release" then
            telemetry.extra_physical_closes = telemetry.extra_physical_closes + 1
          end
        end
        result("close", category, {
          closed = closed,
          code = close_code,
        })
        return closed, close_error, close_code
      end

      dependencies.rmdir = function(path)
        local category = path_category(path, row)
        call("rmdir", category, 0)
        delegate("rmdir", category)
        local removed, remove_error, remove_code = native.rmdir(path)
        result("rmdir", category, {
          removed = removed,
          code = remove_code,
        })
        return removed, remove_error, remove_code
      end

      return dependencies, telemetry
    end

    local function begin_release(telemetry)
      telemetry.calls = new_operation_counters()
      telemetry.delegates = new_operation_counters()
      telemetry.events = {}
      telemetry.native_results = {}
      telemetry.live_generation_reuse = 0
      telemetry.integer_fd_aliases = 0
      telemetry.unowned_close_attempts = 0
      telemetry.extra_physical_closes = 0
      telemetry.physical_closes = 0
      telemetry.uid_calls = 0
      telemetry.uid_delegates = 0
      telemetry.uid_unexpected_arguments = 0
      telemetry.swap = {
        calls = 0,
        rename_calls = 0,
        rename_successes = 0,
        completed = false,
        capture_ok = false,
        before_final_lstat = false,
        paths_contained = false,
        realpath_exact = false,
      }
      telemetry.rescue_count = 0
      telemetry.fallback_calls = 0
      for _, lifetime in ipairs(telemetry.lifetimes) do
        lifetime.release_close_attempts = 0
        lifetime.release_physical_closes = 0
      end
      telemetry.phase = "release"
    end

    local function complete_snapshot(row)
      local result = telemetry_snapshot(row.telemetry)
      result.filesystem = filesystem_snapshot(row)
      return result
    end

    local function exact_capture(path)
      local stat, stat_error = native.lstat(path)
      assert(stat, tostring(stat_error))
      return {
        identity = identity(stat),
        snapshot = snapshot_tree(path),
      }
    end

    local function prepare_v3_row(row)
      row.state_root = make_root("serialization-release-e2-v3")
      row.lock_path = vim.fs.joinpath(row.state_root, lock_name)
      row.reviews_path = vim.fs.joinpath(row.state_root, "reviews")
      row.control_path = vim.fs.joinpath(row.reviews_path, "control.bin")
      row.link_path = vim.fs.joinpath(row.reviews_path, "control-link")
      row.retired_path = vim.fs.joinpath(row.state_root, ".cycle-2e-e2-v3-retired")
      row.staging_path = vim.fs.joinpath(row.state_root, ".cycle-2e-e2-v3-staging")
      row.private_paths = {
        row.state_root,
        row.lock_path,
        row.reviews_path,
        row.control_path,
        row.link_path,
        row.retired_path,
        row.staging_path,
      }

      if #shared_payload <= 8192 then
        add_failure(row, "shared path-bearing diagnostic payload was not longer than 8 KiB")
      end
      if
        not contained_path(row.state_root, row.lock_path)
        or not contained_path(row.state_root, row.reviews_path)
        or not contained_path(row.state_root, row.retired_path)
        or not contained_path(row.state_root, row.staging_path)
      then
        add_failure(row, "a V3 setup path escaped the exact private row root")
      end

      assert(vim.fn.mkdir(row.reviews_path, "p", 448) == 1, "V3 reviews setup failed")
      assert(vim.uv.fs_chmod(row.reviews_path, 448), "V3 reviews chmod failed")
      write_file(row.control_path, "cycle-2e-e2-v3-control\n", 384)
      assert(native.symlink("control.bin", row.link_path), "V3 reviews symlink setup failed")
      row.reviews_before = snapshot_tree(row.reviews_path)

      local reviews_root_exact = false
      local control_exact = false
      local link_exact = false
      for _, entry in ipairs(row.reviews_before) do
        if
          entry.path == "."
          and entry.type == "directory"
          and entry.mode == 448
          and entry.uid == native.uid()
        then
          reviews_root_exact = true
        elseif
          entry.path == "control.bin"
          and entry.type == "file"
          and entry.mode == 384
          and entry.uid == native.uid()
          and entry.sha256 == vim.fn.sha256("cycle-2e-e2-v3-control\n")
        then
          control_exact = true
        elseif
          entry.path == "control-link"
          and entry.type == "link"
          and entry.target == "control.bin"
        then
          link_exact = true
        end
      end
      if not reviews_root_exact or not control_exact or not link_exact then
        add_failure(row, "reviews metadata, regular-file digest, or symlink target was not exact")
      end

      local state_stat, state_error = native.lstat(row.state_root)
      assert(state_stat, tostring(state_error))
      row.state_identity = identity(state_stat)
      if
        row.state_identity.type ~= "directory"
        or row.state_identity.mode ~= 448
        or row.state_identity.uid ~= native.uid()
      then
        add_failure(row, "state root was not an exact current-user mode-0700 directory")
      end

      local retired_before = snapshot_tree(row.retired_path)
      if not vim.deep_equal(retired_before, ABS) then
        add_failure(row, "retired path was not absent before acquisition")
      end
      local staged, stage_error = native.mkdir(row.staging_path, 448)
      assert(staged, tostring(stage_error))
      assert(vim.uv.fs_chmod(row.staging_path, 448), "V3 staging chmod failed")
      row.replacement_before = exact_capture(row.staging_path)
      local replacement_root = row.replacement_before.snapshot[1]
      if
        #row.replacement_before.snapshot ~= 1
        or not replacement_root
        or replacement_root.path ~= "."
        or replacement_root.type ~= "directory"
        or replacement_root.mode ~= 448
        or replacement_root.uid ~= native.uid()
        or replacement_root.dev ~= row.state_identity.dev
        or not same_identity(row.replacement_before.identity, replacement_root)
      then
        add_failure(row, "prebuilt replacement was not exact, private, empty, and same-device")
      end

      local dependencies, telemetry = instrumented_dependencies(row)
      row.telemetry = telemetry
      local lease, acquire_error = serialization.acquire(row.state_root, dependencies)
      if not lease then
        if acquire_error ~= nil then
          table.insert(row.visible_results, tostring(acquire_error))
        end
        add_failure(row, "normal V3 acquisition failed")
        return
      end
      if acquire_error ~= nil then
        table.insert(row.visible_results, tostring(acquire_error))
        add_failure(row, "normal V3 acquisition returned an error")
      end
      row.lease = lease
      row.acquired_lifetimes = lifetime_snapshot(telemetry)

      local lock_stat, lock_error = native.lstat(row.lock_path)
      assert(lock_stat, tostring(lock_error))
      row.lock_identity = identity(lock_stat)
      row.lock_before = snapshot_tree(row.lock_path)
      local lock_root = row.lock_before[1]
      if
        #row.lock_before ~= 1
        or not lock_root
        or lock_root.path ~= "."
        or lock_root.type ~= "directory"
        or lock_root.mode ~= 448
        or lock_root.uid ~= native.uid()
        or lock_root.dev ~= row.state_identity.dev
        or not same_identity(row.lock_identity, lock_root)
      then
        add_failure(row, "acquired lock was not an exact private empty directory")
      end
      if #row.acquired_lifetimes ~= 2 then
        add_failure(row, "acquisition did not retain exactly two descriptor generations")
      end
      if
        row.acquired_lifetimes[1]
        and row.acquired_lifetimes[2]
        and row.acquired_lifetimes[1].fd == row.acquired_lifetimes[2].fd
      then
        add_failure(row, "acquired state and lock lifetimes aliased one integer fd")
      end

      begin_release(telemetry)
    end

    local function exercise_v3(row)
      prepare_v3_row(row)
      if not row.lease then
        return
      end

      row.external_release_calls = row.external_release_calls + 1
      row.first_capture = capture_release(row.lease)
      add_visible_capture(row, row.first_capture)
      row.first_activity = complete_snapshot(row)

      row.repeat_tuples_equal = true
      row.repeat_activity_stable = true
      for _ = 1, 2 do
        row.external_release_calls = row.external_release_calls + 1
        local repeated = capture_release(row.lease)
        add_visible_capture(row, repeated)
        if not repeated.ok or not vim.deep_equal(repeated.tuple, row.first_capture.tuple) then
          row.repeat_tuples_equal = false
        end
        local repeated_activity = complete_snapshot(row)
        if not vim.deep_equal(repeated_activity, row.first_activity) then
          row.repeat_activity_stable = false
        end
      end

      if not row.repeat_tuples_equal then
        add_failure(row, "cached releases did not repeat the complete nil-sensitive pair")
      end
      if not row.repeat_activity_stable then
        add_failure(row, "cached releases changed dependency, descriptor, or filesystem activity")
      end
    end

    local function expect_count(row, detail, actual, expected)
      if actual ~= expected then
        add_failure(row, string.format("%s expected %d actual %d", detail, expected, actual))
      end
    end

    local function expect_path_counter(row, detail, counter, state_expected, lock_expected)
      expect_count(row, detail .. " state", counter.state, state_expected)
      expect_count(row, detail .. " lock", counter.lock, lock_expected)
      expect_count(row, detail .. " unexpected", counter.unexpected, 0)
    end

    local function first_result(activity, operation, category, ordinal)
      local operation_results = activity.native_results[operation]
      local category_results = operation_results and operation_results[category]
      return category_results and category_results[ordinal]
    end

    local function validate_v3(row)
      if not row.first_capture then
        add_failure(row, "first release result was not captured")
        return
      end
      local expected_tuple = { n = 2, [2] = RVL }
      if not row.first_capture.ok then
        add_failure(row, "first release raised")
      elseif not vim.deep_equal(row.first_capture.tuple, expected_tuple) then
        add_failure(row, "first release did not return the exact bounded RVL pair")
      end
      if not row.first_activity then
        add_failure(row, "first release activity was not captured")
        return
      end

      local expected_events = {
        "fstat:state:g1:1",
        "lstat:lock:g0:1",
        "fstat:lock:g1:1",
        "realpath:lock:g0:1",
        "lstat:lock:g0:2",
        "close:lock:g1:1",
        "fsync:state:g1:1",
        "close:state:g1:1",
      }
      if not vim.deep_equal(row.first_activity.events, expected_events) then
        add_failure(row, "release event vector was not exact FS,L1,FL,RP,L2,CL,SY,CS")
      end

      local expected_counts = {
        lstat = { 0, 2 },
        realpath = { 0, 1 },
        open = { 0, 0 },
        fstat = { 1, 1 },
        mkdir = { 0, 0 },
        scandir = { 0, 0 },
        scandir_next = { 0, 0 },
        fsync = { 1, 0 },
        close = { 1, 1 },
        rmdir = { 0, 0 },
      }
      for _, operation in ipairs(operation_names) do
        local expected = expected_counts[operation]
        expect_path_counter(
          row,
          operation .. " calls",
          row.first_activity.calls[operation],
          expected[1],
          expected[2]
        )
        expect_path_counter(
          row,
          operation .. " native delegations",
          row.first_activity.delegates[operation],
          expected[1],
          expected[2]
        )
      end
      expect_count(row, "UID calls", row.first_activity.uid_calls, 0)
      expect_count(row, "UID native delegations", row.first_activity.uid_delegates, 0)
      expect_count(row, "UID unexpected arguments", row.first_activity.uid_unexpected_arguments, 0)

      local state_fstat = first_result(row.first_activity, "fstat", "state", 1)
      local lock_fstat = first_result(row.first_activity, "fstat", "lock", 1)
      local initial_lstat = first_result(row.first_activity, "lstat", "lock", 1)
      local final_lstat = first_result(row.first_activity, "lstat", "lock", 2)
      local realpath = first_result(row.first_activity, "realpath", "lock", 1)
      local lock_close = first_result(row.first_activity, "close", "lock", 1)
      local state_fsync = first_result(row.first_activity, "fsync", "state", 1)
      local state_close = first_result(row.first_activity, "close", "state", 1)
      if
        not state_fstat
        or not state_fstat.exists
        or not same_identity(state_fstat.identity, row.state_identity)
      then
        add_failure(row, "retained state fd did not observe the acquired state identity")
      end
      if
        not initial_lstat
        or not initial_lstat.exists
        or not same_identity(initial_lstat.identity, row.lock_identity)
      then
        add_failure(row, "initial fixed-path lstat did not observe the acquired lock identity")
      end
      if
        not lock_fstat
        or not lock_fstat.exists
        or not same_identity(lock_fstat.identity, row.lock_identity)
      then
        add_failure(row, "retained lock fd did not observe the acquired lock identity")
      end
      if not realpath or realpath.path ~= row.lock_path then
        add_failure(row, "delegated realpath did not prove the exact fixed lock path")
      end
      if
        not final_lstat
        or not final_lstat.exists
        or not same_identity(final_lstat.identity, row.replacement_before.identity)
      then
        add_failure(row, "final fixed-path lstat did not observe the installed replacement")
      end
      if final_lstat and final_lstat.enoent then
        add_failure(row, "an absence proof occurred instead of final lock revalidation")
      end
      if not lock_close or lock_close.closed ~= true then
        add_failure(row, "retained lock fd was not physically closed")
      end
      if not state_fsync or state_fsync.synced ~= true then
        add_failure(row, "state root did not receive one successful synchronization attempt")
      end
      if not state_close or state_close.closed ~= true then
        add_failure(row, "retained state fd was not physically closed last")
      end
      if row.first_activity.native_results.rmdir ~= nil then
        add_failure(row, "replacement removal occurred after validation should have stopped")
      end

      local swap = row.first_activity.swap
      if
        swap.calls ~= 1
        or swap.rename_calls ~= 2
        or swap.rename_successes ~= 2
        or swap.completed ~= true
        or swap.capture_ok ~= true
        or swap.before_final_lstat ~= true
        or swap.paths_contained ~= true
        or swap.realpath_exact ~= true
      then
        add_failure(row, "contained mid-realpath swap did not complete and capture exactly")
      end

      local post_swap = swap.post_swap
      local filesystem = row.first_activity.filesystem
      if not post_swap or not snapshots_ok(post_swap) then
        add_failure(row, "complete post-swap snapshot was unavailable")
      end
      if not snapshots_ok(filesystem) then
        add_failure(row, "complete first-release filesystem snapshot was unavailable")
      end

      if post_swap and snapshots_ok(post_swap) then
        local retired_root = post_swap.retired.value[1]
        local replacement_root = post_swap.lock.value[1]
        if not exact_v3_state_projection(post_swap.state.value) then
          add_failure(row, "post-swap state-root projection had a missing or extra sibling")
        end
        if
          not retired_root
          or not same_identity(identity(retired_root), row.lock_identity)
          or not vim.deep_equal(post_swap.retired.value, row.lock_before)
        then
          add_failure(row, "post-swap retired path did not retain the exact acquired lock")
        end
        if
          not replacement_root
          or not same_identity(identity(replacement_root), row.replacement_before.identity)
          or not vim.deep_equal(post_swap.lock.value, row.replacement_before.snapshot)
        then
          add_failure(row, "post-swap fixed path did not retain the exact replacement")
        end
        if not vim.deep_equal(post_swap.staging.value, ABS) then
          add_failure(row, "post-swap staging path was not absent")
        end
        if not vim.deep_equal(post_swap.reviews.value, row.reviews_before) then
          add_failure(row, "post-swap reviews snapshot changed")
        end
      end

      if snapshots_ok(filesystem) then
        local final_state_root = filesystem.state.value[1]
        local final_retired_root = filesystem.retired.value[1]
        local final_replacement_root = filesystem.lock.value[1]
        if
          not final_state_root
          or not same_identity(identity(final_state_root), row.state_identity)
        then
          add_failure(row, "state-root identity or private metadata changed")
        end
        if
          not final_retired_root
          or not same_identity(identity(final_retired_root), row.lock_identity)
          or not vim.deep_equal(filesystem.retired.value, row.lock_before)
        then
          add_failure(row, "SWAP retired outcome did not preserve the acquired lock")
        end
        if
          not final_replacement_root
          or not same_identity(identity(final_replacement_root), row.replacement_before.identity)
          or not vim.deep_equal(filesystem.lock.value, row.replacement_before.snapshot)
        then
          add_failure(row, "SWAP fixed-path outcome did not preserve the replacement")
        end
        if not vim.deep_equal(filesystem.staging.value, ABS) then
          add_failure(row, "SWAP staging outcome was not absent")
        end
        if not vim.deep_equal(filesystem.reviews.value, row.reviews_before) then
          add_failure(row, "content-aware reviews snapshot changed during release")
        end
        if
          post_swap
          and snapshots_ok(post_swap)
          and not vim.deep_equal(filesystem.state.value, post_swap.state.value)
        then
          add_failure(row, "complete state-root projection changed after the captured swap")
        end
      end

      local lifetime_counts = { state = 0, lock = 0, unexpected = 0 }
      local acquired_counts = { state = 0, lock = 0, unexpected = 0 }
      for _, lifetime in ipairs(row.acquired_lifetimes or {}) do
        acquired_counts[lifetime.category] = acquired_counts[lifetime.category] + 1
        if
          lifetime.generation ~= 1
          or lifetime.active ~= true
          or lifetime.release_close_attempts ~= 0
          or lifetime.release_physical_closes ~= 0
        then
          add_failure(row, "pre-release acquired generation state was not exact")
        end
      end
      expect_count(row, "acquired state generations", acquired_counts.state, 1)
      expect_count(row, "acquired lock generations", acquired_counts.lock, 1)
      expect_count(row, "acquired unexpected generations", acquired_counts.unexpected, 0)
      for _, lifetime in ipairs(row.first_activity.lifetimes) do
        lifetime_counts[lifetime.category] = lifetime_counts[lifetime.category] + 1
        if lifetime.generation ~= 1 then
          add_failure(row, "owned descriptor generation was not one")
        end
        if lifetime.release_close_attempts ~= 1 then
          add_failure(row, "owned generation did not receive exactly one release close")
        end
        if lifetime.release_physical_closes ~= 1 or lifetime.active then
          add_failure(row, "owned generation was not physically closed exactly once")
        end
      end
      expect_count(row, "state descriptor generations", lifetime_counts.state, 1)
      expect_count(row, "lock descriptor generations", lifetime_counts.lock, 1)
      expect_count(row, "unexpected descriptor generations", lifetime_counts.unexpected, 0)
      expect_count(row, "live generation reuse", row.first_activity.live_generation_reuse, 0)
      expect_count(row, "integer-fd aliases", row.first_activity.integer_fd_aliases, 0)
      expect_count(row, "unowned close attempts", row.first_activity.unowned_close_attempts, 0)
      expect_count(row, "extra physical closes", row.first_activity.extra_physical_closes, 0)
      expect_count(row, "physical closes", row.first_activity.physical_closes, 2)
      expect_count(row, "rescue calls", row.first_activity.rescue_count, 0)
      expect_count(row, "fallback release calls", row.first_activity.fallback_calls, 0)
    end

    local function finish_v3(row, protected_ok, protected_error)
      if not protected_ok then
        table.insert(row.visible_results, protected_error)
        add_failure(row, "protected V3 exercise did not complete")
      end

      local all_closed = true
      if row.telemetry then
        row.telemetry.phase = "teardown"
        for _, lifetime in ipairs(row.telemetry.lifetimes) do
          if lifetime.active then
            row.telemetry.rescue_count = row.telemetry.rescue_count + 1
            add_failure(row, "an exact live owned generation required rescue")
            local current = row.telemetry.active_by_fd[lifetime.fd]
            if current == lifetime and current.generation == lifetime.generation then
              local rescue_ok, rescued = pcall(native.close, lifetime.fd)
              if rescue_ok and rescued == true then
                lifetime.active = false
                row.telemetry.active_by_fd[lifetime.fd] = nil
              end
            end
          end
          if lifetime.active then
            all_closed = false
          end
        end
        if row.telemetry.rescue_count ~= 0 then
          add_failure(row, "descriptor rescue count was not zero")
        end
        if row.telemetry.fallback_calls ~= 0 then
          add_failure(row, "release was retried during fallback or teardown")
        end
        if row.telemetry.extra_physical_closes ~= 0 then
          add_failure(row, "an extra descriptor was physically closed")
        end
      end

      if row.external_release_calls ~= 3 then
        add_failure(row, "external release-call count was not three")
      end
      if #row.captures ~= row.external_release_calls then
        add_failure(row, "release capture count did not match external release calls")
      end

      if row.state_root and all_closed then
        local removed = vim.fn.delete(row.state_root, "rf")
        if removed ~= 0 then
          add_failure(row, "exact private row-root teardown failed")
        end
        local stat, stat_error, stat_code = native.lstat(row.state_root)
        if not is_enoent(stat, stat_error, stat_code) then
          add_failure(row, "exact private row-root absence was not proven")
        end
      elseif row.state_root then
        add_failure(row, "private row root was retained because a descriptor remained live")
      end

      local first_kind = "missing"
      if row.first_capture then
        if
          row.first_capture.ok
          and row.first_capture.tuple[1] == nil
          and row.first_capture.tuple[2] == RVL
        then
          first_kind = "RVL"
        elseif
          row.first_capture.ok
          and row.first_capture.tuple[1] == true
          and row.first_capture.tuple[2] == nil
        then
          first_kind = "success"
        elseif row.first_capture.ok then
          first_kind = "other"
        else
          first_kind = "raised"
        end
      end
      local outcome = "missing"
      if
        row.first_activity
        and row.first_activity.filesystem
        and row.first_activity.filesystem.lock.ok
      then
        local lock_snapshot = row.first_activity.filesystem.lock.value
        if vim.deep_equal(lock_snapshot, ABS) then
          outcome = "ABS"
        elseif
          row.replacement_before
          and lock_snapshot[1]
          and same_identity(identity(lock_snapshot[1]), row.replacement_before.identity)
        then
          outcome = "SWAP"
        else
          outcome = "OTHER"
        end
      end
      local events = row.first_activity and table.concat(row.first_activity.events, ",") or "none"
      row.observation = string.format(
        "V3 first=%s repeat-tuple=%s repeat-activity=%s swap=%d/%d/%d outcome=%s rescue=%d events=%s",
        first_kind,
        tostring(row.repeat_tuples_equal),
        tostring(row.repeat_activity_stable),
        row.first_activity and row.first_activity.swap.calls or 0,
        row.first_activity and row.first_activity.swap.rename_calls or 0,
        row.first_activity and row.first_activity.swap.rename_successes or 0,
        outcome,
        row.telemetry and row.telemetry.rescue_count or 0,
        events
      )
      if #row.observation > 1024 then
        add_failure(row, "V3 observation was not bounded")
      end
      table.insert(observations, row.observation)

      for _, result_text in ipairs(row.visible_results) do
        if #result_text > 1024 then
          add_failure(row, "a public or protected result was not bounded")
        end
      end
      local diagnostic_visible = copy(row.visible_results)
      vim.list_extend(diagnostic_visible, row.failures)
      table.insert(diagnostic_visible, row.observation)
      local forbidden = { shared_payload, fixed_private_path }
      vim.list_extend(forbidden, row.private_paths or {})
      local leak_found = false
      for _, visible in ipairs(diagnostic_visible) do
        for _, needle in ipairs(forbidden) do
          if type(needle) == "string" and #needle > 0 and visible:find(needle, 1, true) then
            leak_found = true
          end
        end
      end
      if leak_found then
        add_failure(row, "a shared payload or private fixture path reached diagnostics")
      end

      for _, detail in ipairs(row.failures) do
        table.insert(failures, row.label .. " " .. detail)
      end
    end

    executed_rows = executed_rows + 1
    local row = {
      label = "V3 mid-validation contained directory replacement",
      failures = {},
      captures = {},
      visible_results = {},
      private_paths = {},
      external_release_calls = 0,
      repeat_tuples_equal = false,
      repeat_activity_stable = false,
    }
    local protected_ok, protected_error = xpcall(function()
      exercise_v3(row)
      validate_v3(row)
    end, function()
      return "protected V3 exercise failed"
    end)
    finish_v3(row, protected_ok, protected_error)

    local RLL = "baseline serialization release failed: lstat-lock (EIO)"
    local v4_fixed_private_path = "/fixed/private/cycle-2e-e2-v4"
    local v4_executed_rows = 0

    local function v4_filesystem_snapshot(v4_row)
      return {
        state = protected_snapshot(v4_row.state_root),
        lock = protected_snapshot(v4_row.lock_path),
        reviews = protected_snapshot(v4_row.reviews_path),
      }
    end

    local function v4_snapshots_ok(filesystem)
      return filesystem.state.ok and filesystem.lock.ok and filesystem.reviews.ok
    end

    local function v4_telemetry_snapshot(telemetry)
      return {
        calls = copy(telemetry.calls),
        delegates = copy(telemetry.delegates),
        events = copy(telemetry.events),
        native_results = copy(telemetry.native_results),
        post_delegation = copy(telemetry.post_delegation),
        injection_count = telemetry.injection_count,
        injection_native_ok = telemetry.injection_native_ok,
        injection_armed = telemetry.injection_armed,
        injection_arm_count = telemetry.injection_arm_count,
        injection_nontrigger_count = telemetry.injection_nontrigger_count,
        injection_nontrigger_enoent = telemetry.injection_nontrigger_enoent,
        injection_payloads = copy(telemetry.injection_payloads),
        lifetimes = lifetime_snapshot(telemetry),
        generations = copy(telemetry.generations),
        live_generation_reuse = telemetry.live_generation_reuse,
        integer_fd_aliases = telemetry.integer_fd_aliases,
        unowned_close_attempts = telemetry.unowned_close_attempts,
        extra_physical_closes = telemetry.extra_physical_closes,
        physical_closes = telemetry.physical_closes,
        uid_calls = telemetry.uid_calls,
        uid_delegates = telemetry.uid_delegates,
        uid_unexpected_arguments = telemetry.uid_unexpected_arguments,
        rescue_count = telemetry.rescue_count,
        fallback_calls = telemetry.fallback_calls,
      }
    end

    local function v4_instrumented_dependencies(v4_row)
      local telemetry = {
        phase = "acquisition",
        calls = new_operation_counters(),
        delegates = new_operation_counters(),
        events = {},
        native_results = {},
        post_delegation = {},
        injection_count = 0,
        injection_native_ok = true,
        injection_armed = false,
        injection_arm_count = 0,
        injection_nontrigger_count = 0,
        injection_nontrigger_enoent = false,
        injection_payloads = {},
        lifetimes = {},
        generations = {},
        active_by_fd = {},
        latest_by_fd = {},
        scanner_categories = {},
        live_generation_reuse = 0,
        integer_fd_aliases = 0,
        unowned_close_attempts = 0,
        extra_physical_closes = 0,
        physical_closes = 0,
        uid_calls = 0,
        uid_delegates = 0,
        uid_unexpected_arguments = 0,
        rescue_count = 0,
        fallback_calls = 0,
      }
      local dependencies = {}

      local function descriptor(fd)
        local lifetime = telemetry.active_by_fd[fd] or telemetry.latest_by_fd[fd]
        if lifetime then
          return lifetime.category, lifetime.generation, lifetime
        end
        return "unexpected", 0, nil
      end

      local function call(operation, category, generation)
        if telemetry.phase ~= "release" then
          return 0
        end
        local counter = telemetry.calls[operation]
        counter[category] = counter[category] + 1
        local ordinal = counter[category]
        table.insert(
          telemetry.events,
          string.format("%s:%s:g%d:%d", operation, category, generation or 0, ordinal)
        )
        return ordinal
      end

      local function delegate(operation, category)
        if telemetry.phase == "release" then
          telemetry.delegates[operation][category] = telemetry.delegates[operation][category] + 1
        end
      end

      local function result(operation, category, value)
        if telemetry.phase ~= "release" then
          return
        end
        telemetry.native_results[operation] = telemetry.native_results[operation] or {}
        telemetry.native_results[operation][category] = telemetry.native_results[operation][category]
          or {}
        table.insert(telemetry.native_results[operation][category], value)
      end

      local function inject(operation, category, generation, ordinal, native_ok)
        telemetry.injection_count = telemetry.injection_count + 1
        telemetry.injection_native_ok = telemetry.injection_native_ok and native_ok
        table.insert(telemetry.injection_payloads, shared_payload)
        table.insert(
          telemetry.post_delegation,
          string.format(
            "native:%s:%s:g%d:%d:%s",
            operation,
            category,
            generation,
            ordinal,
            tostring(native_ok)
          )
        )
        table.insert(
          telemetry.post_delegation,
          string.format("inject:%s:%s:g%d:%d", operation, category, generation, ordinal)
        )
      end

      dependencies.uid = function(...)
        if telemetry.phase == "release" then
          telemetry.uid_calls = telemetry.uid_calls + 1
          if select("#", ...) ~= 0 then
            telemetry.uid_unexpected_arguments = telemetry.uid_unexpected_arguments + 1
          end
          telemetry.uid_delegates = telemetry.uid_delegates + 1
        end
        return native.uid(...)
      end

      dependencies.lstat = function(path)
        local category = path_category(path, v4_row)
        local ordinal = call("lstat", category, 0)
        delegate("lstat", category)
        local stat, stat_error, stat_code = native.lstat(path)
        local native_result = {
          exists = stat ~= nil,
          identity = identity(stat),
          enoent = is_enoent(stat, stat_error, stat_code),
          code = stat_code,
        }
        result("lstat", category, native_result)
        if
          telemetry.phase == "release"
          and category == "lock"
          and ordinal == 2
          and telemetry.injection_armed
        then
          local native_ok = stat ~= nil
            and stat.type == "directory"
            and same_identity(identity(stat), v4_row.lock_identity)
          if native_ok then
            inject("lstat", category, 0, ordinal, true)
            return nil, shared_payload, "EIO"
          end
          telemetry.injection_nontrigger_count = telemetry.injection_nontrigger_count + 1
          telemetry.injection_nontrigger_enoent = native_result.enoent
        end
        return stat, stat_error, stat_code
      end

      dependencies.realpath = function(path)
        local category = path_category(path, v4_row)
        local ordinal = call("realpath", category, 0)
        delegate("realpath", category)
        local physical, realpath_error, realpath_code = native.realpath(path)
        result("realpath", category, {
          path = physical,
          code = realpath_code,
        })
        if
          telemetry.phase == "release"
          and category == "lock"
          and ordinal == 1
          and physical == v4_row.lock_path
        then
          telemetry.injection_armed = true
          telemetry.injection_arm_count = telemetry.injection_arm_count + 1
        end
        return physical, realpath_error, realpath_code
      end

      dependencies.open = function(path, flags, mode)
        local category = path_category(path, v4_row)
        call("open", category, 0)
        delegate("open", category)
        local fd, open_error, open_code = native.open(path, flags, mode)
        if fd ~= nil then
          local prior = telemetry.active_by_fd[fd]
          if prior and prior.active then
            telemetry.live_generation_reuse = telemetry.live_generation_reuse + 1
            telemetry.integer_fd_aliases = telemetry.integer_fd_aliases + 1
          end
          local generation = (telemetry.generations[fd] or 0) + 1
          telemetry.generations[fd] = generation
          local lifetime = {
            fd = fd,
            generation = generation,
            category = category,
            active = true,
            release_close_attempts = 0,
            release_physical_closes = 0,
          }
          table.insert(telemetry.lifetimes, lifetime)
          telemetry.active_by_fd[fd] = lifetime
          telemetry.latest_by_fd[fd] = lifetime
        end
        return fd, open_error, open_code
      end

      dependencies.fstat = function(fd)
        local category, generation = descriptor(fd)
        call("fstat", category, generation)
        delegate("fstat", category)
        local stat, stat_error, stat_code = native.fstat(fd)
        result("fstat", category, {
          exists = stat ~= nil,
          identity = identity(stat),
          code = stat_code,
        })
        return stat, stat_error, stat_code
      end

      dependencies.mkdir = function(path, mode)
        local category = path_category(path, v4_row)
        call("mkdir", category, 0)
        delegate("mkdir", category)
        return native.mkdir(path, mode)
      end

      dependencies.scandir = function(path)
        local category = path_category(path, v4_row)
        call("scandir", category, 0)
        delegate("scandir", category)
        local scanner, scan_error, scan_code = native.scandir(path)
        if scanner ~= nil then
          telemetry.scanner_categories[scanner] = category
        end
        return scanner, scan_error, scan_code
      end

      dependencies.scandir_next = function(scanner)
        local category = telemetry.scanner_categories[scanner] or "unexpected"
        call("scandir_next", category, 0)
        delegate("scandir_next", category)
        return native.scandir_next(scanner)
      end

      dependencies.fsync = function(fd)
        local category, generation = descriptor(fd)
        call("fsync", category, generation)
        delegate("fsync", category)
        local synced, sync_error, sync_code = native.fsync(fd)
        result("fsync", category, {
          synced = synced,
          code = sync_code,
        })
        return synced, sync_error, sync_code
      end

      dependencies.close = function(fd)
        local category, generation, lifetime = descriptor(fd)
        call("close", category, generation)
        if telemetry.phase == "release" then
          if lifetime then
            lifetime.release_close_attempts = lifetime.release_close_attempts + 1
          else
            telemetry.unowned_close_attempts = telemetry.unowned_close_attempts + 1
          end
        end
        delegate("close", category)
        local close_ok, closed, close_error, close_code = pcall(native.close, fd)
        if not close_ok then
          closed = nil
          close_error = "native close failed"
          close_code = "UNKNOWN"
        end
        if closed == true then
          if lifetime and lifetime.active and telemetry.active_by_fd[fd] == lifetime then
            lifetime.active = false
            telemetry.active_by_fd[fd] = nil
            if telemetry.phase == "release" then
              lifetime.release_physical_closes = lifetime.release_physical_closes + 1
              telemetry.physical_closes = telemetry.physical_closes + 1
            end
          elseif telemetry.phase == "release" then
            telemetry.extra_physical_closes = telemetry.extra_physical_closes + 1
          end
        end
        result("close", category, {
          closed = closed,
          code = close_code,
        })
        return closed, close_error, close_code
      end

      dependencies.rmdir = function(path)
        local category = path_category(path, v4_row)
        call("rmdir", category, 0)
        delegate("rmdir", category)
        local removed, remove_error, remove_code = native.rmdir(path)
        result("rmdir", category, {
          removed = removed,
          code = remove_code,
        })
        return removed, remove_error, remove_code
      end

      return dependencies, telemetry
    end

    local function v4_begin_release(telemetry)
      telemetry.calls = new_operation_counters()
      telemetry.delegates = new_operation_counters()
      telemetry.events = {}
      telemetry.native_results = {}
      telemetry.post_delegation = {}
      telemetry.injection_count = 0
      telemetry.injection_native_ok = true
      telemetry.injection_armed = false
      telemetry.injection_arm_count = 0
      telemetry.injection_nontrigger_count = 0
      telemetry.injection_nontrigger_enoent = false
      telemetry.injection_payloads = {}
      telemetry.live_generation_reuse = 0
      telemetry.integer_fd_aliases = 0
      telemetry.unowned_close_attempts = 0
      telemetry.extra_physical_closes = 0
      telemetry.physical_closes = 0
      telemetry.uid_calls = 0
      telemetry.uid_delegates = 0
      telemetry.uid_unexpected_arguments = 0
      telemetry.rescue_count = 0
      telemetry.fallback_calls = 0
      for _, lifetime in ipairs(telemetry.lifetimes) do
        lifetime.release_close_attempts = 0
        lifetime.release_physical_closes = 0
      end
      telemetry.phase = "release"
    end

    local function v4_complete_snapshot(v4_row)
      local result = v4_telemetry_snapshot(v4_row.telemetry)
      result.filesystem = v4_filesystem_snapshot(v4_row)
      return result
    end

    local function exact_v4_state_projection(snapshot)
      local expected = {
        ["."] = true,
        [lock_name] = true,
        reviews = true,
        ["reviews/control.bin"] = true,
        ["reviews/control-link"] = true,
      }
      local observed = {}
      for _, entry in ipairs(snapshot) do
        if not expected[entry.path] or observed[entry.path] then
          return false
        end
        observed[entry.path] = true
      end
      for path in pairs(expected) do
        if not observed[path] then
          return false
        end
      end
      return true
    end

    local function prepare_v4_row(v4_row)
      v4_row.state_root = make_root("serialization-release-e2-v4")
      v4_row.lock_path = vim.fs.joinpath(v4_row.state_root, lock_name)
      v4_row.reviews_path = vim.fs.joinpath(v4_row.state_root, "reviews")
      v4_row.control_path = vim.fs.joinpath(v4_row.reviews_path, "control.bin")
      v4_row.link_path = vim.fs.joinpath(v4_row.reviews_path, "control-link")
      v4_row.private_paths = {
        v4_row.state_root,
        v4_row.lock_path,
        v4_row.reviews_path,
        v4_row.control_path,
        v4_row.link_path,
      }

      if #shared_payload <= 8192 then
        add_failure(v4_row, "shared path-bearing diagnostic payload was not longer than 8 KiB")
      end
      if
        not contained_path(v4_row.state_root, v4_row.lock_path)
        or not contained_path(v4_row.state_root, v4_row.reviews_path)
      then
        add_failure(v4_row, "a V4 setup path escaped the exact private row root")
      end

      assert(vim.fn.mkdir(v4_row.reviews_path, "p", 448) == 1, "V4 reviews setup failed")
      assert(vim.uv.fs_chmod(v4_row.reviews_path, 448), "V4 reviews chmod failed")
      write_file(v4_row.control_path, "cycle-2e-e2-v4-control\n", 384)
      assert(native.symlink("control.bin", v4_row.link_path), "V4 reviews symlink setup failed")
      v4_row.reviews_before = snapshot_tree(v4_row.reviews_path)

      local reviews_root_exact = false
      local control_exact = false
      local link_exact = false
      for _, entry in ipairs(v4_row.reviews_before) do
        if
          entry.path == "."
          and entry.type == "directory"
          and entry.mode == 448
          and entry.uid == native.uid()
        then
          reviews_root_exact = true
        elseif
          entry.path == "control.bin"
          and entry.type == "file"
          and entry.mode == 384
          and entry.uid == native.uid()
          and entry.sha256 == vim.fn.sha256("cycle-2e-e2-v4-control\n")
        then
          control_exact = true
        elseif
          entry.path == "control-link"
          and entry.type == "link"
          and entry.target == "control.bin"
        then
          link_exact = true
        end
      end
      if not reviews_root_exact or not control_exact or not link_exact then
        add_failure(
          v4_row,
          "reviews metadata, regular-file digest, or symlink target was not exact"
        )
      end

      local state_stat, state_error = native.lstat(v4_row.state_root)
      assert(state_stat, tostring(state_error))
      v4_row.state_identity = identity(state_stat)
      if
        v4_row.state_identity.type ~= "directory"
        or v4_row.state_identity.mode ~= 448
        or v4_row.state_identity.uid ~= native.uid()
      then
        add_failure(v4_row, "state root was not an exact current-user mode-0700 directory")
      end

      local dependencies, telemetry = v4_instrumented_dependencies(v4_row)
      v4_row.telemetry = telemetry
      local lease, acquire_error = serialization.acquire(v4_row.state_root, dependencies)
      if not lease then
        if acquire_error ~= nil then
          table.insert(v4_row.visible_results, tostring(acquire_error))
        end
        add_failure(v4_row, "normal V4 acquisition failed")
        return
      end
      if acquire_error ~= nil then
        table.insert(v4_row.visible_results, tostring(acquire_error))
        add_failure(v4_row, "normal V4 acquisition returned an error")
      end
      v4_row.lease = lease
      v4_row.acquired_lifetimes = lifetime_snapshot(telemetry)

      local lock_stat, lock_error = native.lstat(v4_row.lock_path)
      assert(lock_stat, tostring(lock_error))
      v4_row.lock_identity = identity(lock_stat)
      v4_row.lock_before = snapshot_tree(v4_row.lock_path)
      local lock_root = v4_row.lock_before[1]
      if
        #v4_row.lock_before ~= 1
        or not lock_root
        or lock_root.path ~= "."
        or lock_root.type ~= "directory"
        or lock_root.mode ~= 448
        or lock_root.uid ~= native.uid()
        or lock_root.dev ~= v4_row.state_identity.dev
        or not same_identity(v4_row.lock_identity, lock_root)
      then
        add_failure(v4_row, "acquired lock was not an exact private empty directory")
      end
      if #v4_row.acquired_lifetimes ~= 2 then
        add_failure(v4_row, "acquisition did not retain exactly two descriptor generations")
      end
      if
        v4_row.acquired_lifetimes[1]
        and v4_row.acquired_lifetimes[2]
        and v4_row.acquired_lifetimes[1].fd == v4_row.acquired_lifetimes[2].fd
      then
        add_failure(v4_row, "acquired state and lock lifetimes aliased one integer fd")
      end
      v4_row.state_before = snapshot_tree(v4_row.state_root)
      if not exact_v4_state_projection(v4_row.state_before) then
        add_failure(v4_row, "pre-release state-root projection was not exact")
      end

      v4_begin_release(telemetry)
    end

    local function exercise_v4(v4_row)
      prepare_v4_row(v4_row)
      if not v4_row.lease then
        return
      end

      v4_row.external_release_calls = v4_row.external_release_calls + 1
      v4_row.first_capture = capture_release(v4_row.lease)
      add_visible_capture(v4_row, v4_row.first_capture)
      v4_row.first_activity = v4_complete_snapshot(v4_row)

      v4_row.repeat_tuples_equal = true
      v4_row.repeat_activity_stable = true
      for _ = 1, 2 do
        v4_row.external_release_calls = v4_row.external_release_calls + 1
        local repeated = capture_release(v4_row.lease)
        add_visible_capture(v4_row, repeated)
        if not repeated.ok or not vim.deep_equal(repeated.tuple, v4_row.first_capture.tuple) then
          v4_row.repeat_tuples_equal = false
        end
        local repeated_activity = v4_complete_snapshot(v4_row)
        if not vim.deep_equal(repeated_activity, v4_row.first_activity) then
          v4_row.repeat_activity_stable = false
        end
      end

      if not v4_row.repeat_tuples_equal then
        add_failure(v4_row, "cached releases did not repeat the complete nil-sensitive pair")
      end
      if not v4_row.repeat_activity_stable then
        add_failure(
          v4_row,
          "cached releases changed dependency, descriptor, or filesystem activity"
        )
      end
    end

    local function validate_v4(v4_row)
      if not v4_row.first_capture then
        add_failure(v4_row, "first release result was not captured")
        return
      end
      local expected_tuple = { n = 2, [2] = RLL }
      if not v4_row.first_capture.ok then
        add_failure(v4_row, "first release raised")
      elseif not vim.deep_equal(v4_row.first_capture.tuple, expected_tuple) then
        add_failure(v4_row, "first release did not return the exact bounded RLL pair")
      end
      if not v4_row.first_activity then
        add_failure(v4_row, "first release activity was not captured")
        return
      end

      local expected_events = {
        "fstat:state:g1:1",
        "lstat:lock:g0:1",
        "fstat:lock:g1:1",
        "realpath:lock:g0:1",
        "lstat:lock:g0:2",
        "close:lock:g1:1",
        "fsync:state:g1:1",
        "close:state:g1:1",
      }
      if not vim.deep_equal(v4_row.first_activity.events, expected_events) then
        add_failure(v4_row, "release event vector was not exact FS,L1,FL,RP,L2,CL,SY,CS")
      end

      local expected_counts = {
        lstat = { 0, 2 },
        realpath = { 0, 1 },
        open = { 0, 0 },
        fstat = { 1, 1 },
        mkdir = { 0, 0 },
        scandir = { 0, 0 },
        scandir_next = { 0, 0 },
        fsync = { 1, 0 },
        close = { 1, 1 },
        rmdir = { 0, 0 },
      }
      for _, operation in ipairs(operation_names) do
        local expected = expected_counts[operation]
        expect_path_counter(
          v4_row,
          operation .. " calls",
          v4_row.first_activity.calls[operation],
          expected[1],
          expected[2]
        )
        expect_path_counter(
          v4_row,
          operation .. " native delegations",
          v4_row.first_activity.delegates[operation],
          expected[1],
          expected[2]
        )
      end
      expect_count(v4_row, "UID calls", v4_row.first_activity.uid_calls, 0)
      expect_count(v4_row, "UID native delegations", v4_row.first_activity.uid_delegates, 0)
      expect_count(
        v4_row,
        "UID unexpected arguments",
        v4_row.first_activity.uid_unexpected_arguments,
        0
      )

      local state_fstat = first_result(v4_row.first_activity, "fstat", "state", 1)
      local lock_fstat = first_result(v4_row.first_activity, "fstat", "lock", 1)
      local initial_lstat = first_result(v4_row.first_activity, "lstat", "lock", 1)
      local final_lstat = first_result(v4_row.first_activity, "lstat", "lock", 2)
      local realpath = first_result(v4_row.first_activity, "realpath", "lock", 1)
      local lock_close = first_result(v4_row.first_activity, "close", "lock", 1)
      local state_fsync = first_result(v4_row.first_activity, "fsync", "state", 1)
      local state_close = first_result(v4_row.first_activity, "close", "state", 1)
      if
        not state_fstat
        or not state_fstat.exists
        or not same_identity(state_fstat.identity, v4_row.state_identity)
      then
        add_failure(v4_row, "retained state fd did not observe the acquired state identity")
      end
      if
        not initial_lstat
        or not initial_lstat.exists
        or not same_identity(initial_lstat.identity, v4_row.lock_identity)
      then
        add_failure(v4_row, "initial fixed-path lstat did not observe the acquired lock identity")
      end
      if
        not lock_fstat
        or not lock_fstat.exists
        or not same_identity(lock_fstat.identity, v4_row.lock_identity)
      then
        add_failure(v4_row, "retained lock fd did not observe the acquired lock identity")
      end
      if not realpath or realpath.path ~= v4_row.lock_path then
        add_failure(v4_row, "delegated realpath did not prove the exact fixed lock path")
      end
      if
        not final_lstat
        or not final_lstat.exists
        or not same_identity(final_lstat.identity, v4_row.lock_identity)
      then
        add_failure(v4_row, "armed final lstat did not natively prove the acquired lock")
      end
      if final_lstat and final_lstat.enoent then
        add_failure(v4_row, "native ENOENT reached ordinal 2 instead of final revalidation")
      end
      if not lock_close or lock_close.closed ~= true then
        add_failure(v4_row, "retained lock fd was not physically closed")
      end
      if not state_fsync or state_fsync.synced ~= true then
        add_failure(v4_row, "state root did not receive one successful synchronization attempt")
      end
      if not state_close or state_close.closed ~= true then
        add_failure(v4_row, "retained state fd was not physically closed last")
      end
      if v4_row.first_activity.native_results.rmdir ~= nil then
        add_failure(v4_row, "lock removal occurred after final-lstat failure")
      end

      expect_count(v4_row, "realpath arming count", v4_row.first_activity.injection_arm_count, 1)
      expect_count(v4_row, "post-native injections", v4_row.first_activity.injection_count, 1)
      expect_count(v4_row, "armed nontriggers", v4_row.first_activity.injection_nontrigger_count, 0)
      if v4_row.first_activity.injection_armed ~= true then
        add_failure(v4_row, "V4 injection was not armed after exact native realpath")
      end
      if v4_row.first_activity.injection_native_ok ~= true then
        add_failure(v4_row, "V4 injection lacked its successful native directory result")
      end
      if v4_row.first_activity.injection_nontrigger_enoent ~= false then
        add_failure(v4_row, "native ENOENT incorrectly qualified for V4 injection")
      end
      local expected_post_delegation = {
        "native:lstat:lock:g0:2:true",
        "inject:lstat:lock:g0:2",
      }
      if not vim.deep_equal(v4_row.first_activity.post_delegation, expected_post_delegation) then
        add_failure(v4_row, "native-result-before-injection proof was not exact")
      end
      if
        #v4_row.first_activity.injection_payloads ~= 1
        or v4_row.first_activity.injection_payloads[1] ~= shared_payload
      then
        add_failure(v4_row, "V4 injection did not use the shared oversized payload")
      end

      local filesystem = v4_row.first_activity.filesystem
      if not v4_snapshots_ok(filesystem) then
        add_failure(v4_row, "complete first-release filesystem snapshot was unavailable")
      else
        local final_state_root = filesystem.state.value[1]
        local final_lock_root = filesystem.lock.value[1]
        if
          not final_state_root
          or not same_identity(identity(final_state_root), v4_row.state_identity)
        then
          add_failure(v4_row, "state-root identity or private metadata changed")
        end
        if
          not final_lock_root
          or not same_identity(identity(final_lock_root), v4_row.lock_identity)
          or not vim.deep_equal(filesystem.lock.value, v4_row.lock_before)
        then
          add_failure(v4_row, "KEEP lock identity or complete snapshot changed")
        end
        if not vim.deep_equal(filesystem.state.value, v4_row.state_before) then
          add_failure(v4_row, "complete KEEP state-root projection changed")
        end
        if not exact_v4_state_projection(filesystem.state.value) then
          add_failure(v4_row, "KEEP state-root projection had a missing or extra sibling")
        end
        if not vim.deep_equal(filesystem.reviews.value, v4_row.reviews_before) then
          add_failure(v4_row, "content-aware reviews snapshot changed during release")
        end
      end

      local acquired_counts = { state = 0, lock = 0, unexpected = 0 }
      for _, lifetime in ipairs(v4_row.acquired_lifetimes or {}) do
        acquired_counts[lifetime.category] = acquired_counts[lifetime.category] + 1
        if
          lifetime.generation ~= 1
          or lifetime.active ~= true
          or lifetime.release_close_attempts ~= 0
          or lifetime.release_physical_closes ~= 0
        then
          add_failure(v4_row, "pre-release acquired generation state was not exact")
        end
      end
      expect_count(v4_row, "acquired state generations", acquired_counts.state, 1)
      expect_count(v4_row, "acquired lock generations", acquired_counts.lock, 1)
      expect_count(v4_row, "acquired unexpected generations", acquired_counts.unexpected, 0)

      local lifetime_counts = { state = 0, lock = 0, unexpected = 0 }
      for _, lifetime in ipairs(v4_row.first_activity.lifetimes) do
        lifetime_counts[lifetime.category] = lifetime_counts[lifetime.category] + 1
        if lifetime.generation ~= 1 then
          add_failure(v4_row, "owned descriptor generation was not one")
        end
        if lifetime.release_close_attempts ~= 1 then
          add_failure(v4_row, "owned generation did not receive exactly one release close")
        end
        if lifetime.release_physical_closes ~= 1 or lifetime.active then
          add_failure(v4_row, "owned generation was not physically closed exactly once")
        end
      end
      expect_count(v4_row, "state descriptor generations", lifetime_counts.state, 1)
      expect_count(v4_row, "lock descriptor generations", lifetime_counts.lock, 1)
      expect_count(v4_row, "unexpected descriptor generations", lifetime_counts.unexpected, 0)
      expect_count(v4_row, "live generation reuse", v4_row.first_activity.live_generation_reuse, 0)
      expect_count(v4_row, "integer-fd aliases", v4_row.first_activity.integer_fd_aliases, 0)
      expect_count(
        v4_row,
        "unowned close attempts",
        v4_row.first_activity.unowned_close_attempts,
        0
      )
      expect_count(v4_row, "extra physical closes", v4_row.first_activity.extra_physical_closes, 0)
      expect_count(v4_row, "physical closes", v4_row.first_activity.physical_closes, 2)
      expect_count(v4_row, "rescue calls", v4_row.first_activity.rescue_count, 0)
      expect_count(v4_row, "fallback release calls", v4_row.first_activity.fallback_calls, 0)
    end

    local function finish_v4(v4_row, v4_protected_ok, v4_protected_error)
      if not v4_protected_ok then
        table.insert(v4_row.visible_results, v4_protected_error)
        add_failure(v4_row, "protected V4 exercise did not complete")
      end

      local all_closed = true
      if v4_row.telemetry then
        v4_row.telemetry.phase = "teardown"
        for _, lifetime in ipairs(v4_row.telemetry.lifetimes) do
          if lifetime.active then
            v4_row.telemetry.rescue_count = v4_row.telemetry.rescue_count + 1
            add_failure(v4_row, "an exact live owned generation required rescue")
            local current = v4_row.telemetry.active_by_fd[lifetime.fd]
            if current == lifetime and current.generation == lifetime.generation then
              local rescue_ok, rescued = pcall(native.close, lifetime.fd)
              if rescue_ok and rescued == true then
                lifetime.active = false
                v4_row.telemetry.active_by_fd[lifetime.fd] = nil
              end
            end
          end
          if lifetime.active then
            all_closed = false
          end
        end
        if v4_row.telemetry.rescue_count ~= 0 then
          add_failure(v4_row, "descriptor rescue count was not zero")
        end
        if v4_row.telemetry.fallback_calls ~= 0 then
          add_failure(v4_row, "release was retried during fallback or teardown")
        end
        if v4_row.telemetry.extra_physical_closes ~= 0 then
          add_failure(v4_row, "an extra descriptor was physically closed")
        end
      end

      if v4_row.external_release_calls ~= 3 then
        add_failure(v4_row, "external release-call count was not three")
      end
      if #v4_row.captures ~= v4_row.external_release_calls then
        add_failure(v4_row, "release capture count did not match external release calls")
      end

      if v4_row.state_root and all_closed then
        local removed = vim.fn.delete(v4_row.state_root, "rf")
        if removed ~= 0 then
          add_failure(v4_row, "exact private row-root teardown failed")
        end
        local stat, stat_error, stat_code = native.lstat(v4_row.state_root)
        if not is_enoent(stat, stat_error, stat_code) then
          add_failure(v4_row, "exact private row-root absence was not proven")
        end
      elseif v4_row.state_root then
        add_failure(v4_row, "private row root was retained because a descriptor remained live")
      end

      local first_kind = "missing"
      if v4_row.first_capture then
        if
          v4_row.first_capture.ok
          and v4_row.first_capture.tuple[1] == nil
          and v4_row.first_capture.tuple[2] == RLL
        then
          first_kind = "RLL"
        elseif
          v4_row.first_capture.ok
          and v4_row.first_capture.tuple[1] == true
          and v4_row.first_capture.tuple[2] == nil
        then
          first_kind = "success"
        elseif v4_row.first_capture.ok then
          first_kind = "other"
        else
          first_kind = "raised"
        end
      end
      local outcome = "missing"
      if
        v4_row.first_activity
        and v4_row.first_activity.filesystem
        and v4_row.first_activity.filesystem.lock.ok
      then
        local lock_snapshot = v4_row.first_activity.filesystem.lock.value
        if vim.deep_equal(lock_snapshot, ABS) then
          outcome = "ABS"
        elseif
          v4_row.lock_identity
          and lock_snapshot[1]
          and same_identity(identity(lock_snapshot[1]), v4_row.lock_identity)
          and vim.deep_equal(lock_snapshot, v4_row.lock_before)
        then
          outcome = "KEEP"
        else
          outcome = "OTHER"
        end
      end
      local events = v4_row.first_activity and table.concat(v4_row.first_activity.events, ",")
        or "none"
      v4_row.observation = string.format(
        "V4 first=%s repeat-tuple=%s repeat-activity=%s injection=%d/%d/%d/%s outcome=%s rescue=%d events=%s",
        first_kind,
        tostring(v4_row.repeat_tuples_equal),
        tostring(v4_row.repeat_activity_stable),
        v4_row.first_activity and v4_row.first_activity.injection_count or 0,
        v4_row.first_activity and v4_row.first_activity.injection_arm_count or 0,
        v4_row.first_activity and v4_row.first_activity.injection_nontrigger_count or 0,
        tostring(v4_row.first_activity and v4_row.first_activity.injection_nontrigger_enoent),
        outcome,
        v4_row.telemetry and v4_row.telemetry.rescue_count or 0,
        events
      )
      if #v4_row.observation > 1024 then
        add_failure(v4_row, "V4 observation was not bounded")
      end
      table.insert(observations, v4_row.observation)

      for _, result_text in ipairs(v4_row.visible_results) do
        if #result_text > 1024 then
          add_failure(v4_row, "a public or protected result was not bounded")
        end
      end
      local diagnostic_visible = copy(v4_row.visible_results)
      vim.list_extend(diagnostic_visible, v4_row.failures)
      table.insert(diagnostic_visible, v4_row.observation)
      local forbidden = {
        shared_payload,
        fixed_private_path,
        v4_fixed_private_path,
      }
      vim.list_extend(forbidden, v4_row.private_paths or {})
      local leak_found = false
      for _, visible in ipairs(diagnostic_visible) do
        for _, needle in ipairs(forbidden) do
          if type(needle) == "string" and #needle > 0 and visible:find(needle, 1, true) then
            leak_found = true
          end
        end
      end
      if leak_found then
        add_failure(v4_row, "a shared payload or private fixture path reached diagnostics")
      end

      for _, detail in ipairs(v4_row.failures) do
        table.insert(failures, v4_row.label .. " " .. detail)
      end
    end

    v4_executed_rows = v4_executed_rows + 1
    local v4_row = {
      label = "V4 final-revalidation syscall failure",
      failures = {},
      captures = {},
      visible_results = {},
      private_paths = {},
      external_release_calls = 0,
      repeat_tuples_equal = false,
      repeat_activity_stable = false,
    }
    local v4_protected_ok, v4_protected_error = xpcall(function()
      exercise_v4(v4_row)
      validate_v4(v4_row)
    end, function()
      return "protected V4 exercise failed"
    end)
    finish_v4(v4_row, v4_protected_ok, v4_protected_error)

    if v4_executed_rows ~= 1 then
      table.insert(failures, "Cycle 2E E2 V4 did not execute exactly once")
    end
    if not v4_row.observation or observations[2] ~= v4_row.observation then
      table.insert(failures, "Cycle 2E E2 V4 did not append one bounded observation")
    end

    local RVS = "baseline serialization release failed: validate-state-root (UNKNOWN)"
    local RR = "baseline serialization release failed: rmdir-lock (EIO)"
    local RCL = "baseline serialization release failed: close-lock (EIO)"
    local RF = "baseline serialization release failed: fsync-state-root (EIO)"
    local RCS = "baseline serialization release failed: close-state-root (EIO)"
    local O2_ERROR = table.concat({ RCL, RR, RF, RCS }, "; ")
    local v0_fixed_private_path = "/fixed/private/cycle-2e-e2-v0"
    local c1_fixed_private_path = "/fixed/private/cycle-2e-e2-c1"
    local o2_fixed_private_path = "/fixed/private/cycle-2e-e2-o2"
    local v0_executed_rows = 0
    local c1_executed_rows = 0
    local o2_executed_rows = 0

    local function v69_filesystem_snapshot(v69_row)
      return {
        state = protected_snapshot(v69_row.state_root),
        lock = protected_snapshot(v69_row.lock_path),
        reviews = protected_snapshot(v69_row.reviews_path),
      }
    end

    local function v69_snapshots_ok(filesystem)
      return filesystem.state.ok and filesystem.lock.ok and filesystem.reviews.ok
    end

    local function v69_telemetry_snapshot(telemetry)
      return {
        calls = copy(telemetry.calls),
        delegates = copy(telemetry.delegates),
        events = copy(telemetry.events),
        native_results = copy(telemetry.native_results),
        post_delegation = copy(telemetry.post_delegation),
        failure_injection_count = telemetry.failure_injection_count,
        failure_injection_native_ok = telemetry.failure_injection_native_ok,
        failure_payloads = copy(telemetry.failure_payloads),
        drift_count = telemetry.drift_count,
        drift_native_ok = telemetry.drift_native_ok,
        nondelegating_rmdir_count = telemetry.nondelegating_rmdir_count,
        lifetimes = lifetime_snapshot(telemetry),
        generations = copy(telemetry.generations),
        live_generation_reuse = telemetry.live_generation_reuse,
        integer_fd_aliases = telemetry.integer_fd_aliases,
        unowned_close_attempts = telemetry.unowned_close_attempts,
        extra_physical_closes = telemetry.extra_physical_closes,
        physical_closes = telemetry.physical_closes,
        uid_calls = telemetry.uid_calls,
        uid_delegates = telemetry.uid_delegates,
        uid_unexpected_arguments = telemetry.uid_unexpected_arguments,
        rescue_count = telemetry.rescue_count,
        fallback_calls = telemetry.fallback_calls,
      }
    end

    local function v69_instrumented_dependencies(v69_row, spec)
      local telemetry = {
        phase = "acquisition",
        calls = new_operation_counters(),
        delegates = new_operation_counters(),
        events = {},
        native_results = {},
        post_delegation = {},
        failure_injection_count = 0,
        failure_injection_native_ok = true,
        failure_payloads = {},
        drift_count = 0,
        drift_native_ok = true,
        nondelegating_rmdir_count = 0,
        lifetimes = {},
        generations = {},
        active_by_fd = {},
        latest_by_fd = {},
        scanner_categories = {},
        live_generation_reuse = 0,
        integer_fd_aliases = 0,
        unowned_close_attempts = 0,
        extra_physical_closes = 0,
        physical_closes = 0,
        uid_calls = 0,
        uid_delegates = 0,
        uid_unexpected_arguments = 0,
        rescue_count = 0,
        fallback_calls = 0,
      }
      local dependencies = {}

      local function descriptor(fd)
        local lifetime = telemetry.active_by_fd[fd] or telemetry.latest_by_fd[fd]
        if lifetime then
          return lifetime.category, lifetime.generation, lifetime
        end
        return "unexpected", 0, nil
      end

      local function call(operation, category, generation)
        if telemetry.phase ~= "release" then
          return 0
        end
        local counter = telemetry.calls[operation]
        counter[category] = counter[category] + 1
        local ordinal = counter[category]
        table.insert(
          telemetry.events,
          string.format("%s:%s:g%d:%d", operation, category, generation or 0, ordinal)
        )
        return ordinal
      end

      local function delegate(operation, category)
        if telemetry.phase == "release" then
          telemetry.delegates[operation][category] = telemetry.delegates[operation][category] + 1
        end
      end

      local function result(operation, category, value)
        if telemetry.phase ~= "release" then
          return
        end
        telemetry.native_results[operation] = telemetry.native_results[operation] or {}
        telemetry.native_results[operation][category] = telemetry.native_results[operation][category]
          or {}
        table.insert(telemetry.native_results[operation][category], value)
      end

      local function note_failure(operation, category, generation, ordinal, delegated, native_ok)
        telemetry.failure_injection_count = telemetry.failure_injection_count + 1
        telemetry.failure_injection_native_ok = telemetry.failure_injection_native_ok
          and (not delegated or native_ok)
        table.insert(telemetry.failure_payloads, shared_payload)
        if delegated then
          table.insert(
            telemetry.post_delegation,
            string.format(
              "native:%s:%s:g%d:%d:%s",
              operation,
              category,
              generation,
              ordinal,
              tostring(native_ok)
            )
          )
        end
        table.insert(
          telemetry.post_delegation,
          string.format("inject:%s:%s:g%d:%d", operation, category, generation, ordinal)
        )
      end

      dependencies.uid = function(...)
        if telemetry.phase == "release" then
          telemetry.uid_calls = telemetry.uid_calls + 1
          if select("#", ...) ~= 0 then
            telemetry.uid_unexpected_arguments = telemetry.uid_unexpected_arguments + 1
          end
          telemetry.uid_delegates = telemetry.uid_delegates + 1
        end
        return native.uid(...)
      end

      dependencies.lstat = function(path)
        local category = path_category(path, v69_row)
        call("lstat", category, 0)
        delegate("lstat", category)
        local stat, stat_error, stat_code = native.lstat(path)
        result("lstat", category, {
          exists = stat ~= nil,
          identity = identity(stat),
          enoent = is_enoent(stat, stat_error, stat_code),
          code = stat_code,
        })
        return stat, stat_error, stat_code
      end

      dependencies.realpath = function(path)
        local category = path_category(path, v69_row)
        call("realpath", category, 0)
        delegate("realpath", category)
        local physical, realpath_error, realpath_code = native.realpath(path)
        result("realpath", category, {
          path = physical,
          code = realpath_code,
        })
        return physical, realpath_error, realpath_code
      end

      dependencies.open = function(path, flags, mode)
        local category = path_category(path, v69_row)
        call("open", category, 0)
        delegate("open", category)
        local fd, open_error, open_code = native.open(path, flags, mode)
        if fd ~= nil then
          local prior = telemetry.active_by_fd[fd]
          if prior and prior.active then
            telemetry.live_generation_reuse = telemetry.live_generation_reuse + 1
            telemetry.integer_fd_aliases = telemetry.integer_fd_aliases + 1
          end
          local generation = (telemetry.generations[fd] or 0) + 1
          telemetry.generations[fd] = generation
          local lifetime = {
            fd = fd,
            generation = generation,
            category = category,
            active = true,
            release_close_attempts = 0,
            release_physical_closes = 0,
          }
          table.insert(telemetry.lifetimes, lifetime)
          telemetry.active_by_fd[fd] = lifetime
          telemetry.latest_by_fd[fd] = lifetime
        end
        return fd, open_error, open_code
      end

      dependencies.fstat = function(fd)
        local category, generation = descriptor(fd)
        local ordinal = call("fstat", category, generation)
        delegate("fstat", category)
        local stat, stat_error, stat_code = native.fstat(fd)
        result("fstat", category, {
          exists = stat ~= nil,
          identity = identity(stat),
          code = stat_code,
        })
        if
          telemetry.phase == "release"
          and spec.key == "V0"
          and category == "state"
          and ordinal == 1
        then
          local native_ok = stat ~= nil
            and type(stat.ino) == "number"
            and same_identity(identity(stat), v69_row.state_identity)
          telemetry.drift_count = telemetry.drift_count + 1
          telemetry.drift_native_ok = telemetry.drift_native_ok and native_ok
          table.insert(
            telemetry.post_delegation,
            string.format("native:fstat:state:g%d:%d:%s", generation, ordinal, tostring(native_ok))
          )
          table.insert(
            telemetry.post_delegation,
            string.format("drift:fstat:state:g%d:%d", generation, ordinal)
          )
          if native_ok then
            local changed = copy(stat)
            changed.ino = changed.ino + 1
            return changed
          end
        end
        return stat, stat_error, stat_code
      end

      dependencies.mkdir = function(path, mode)
        local category = path_category(path, v69_row)
        call("mkdir", category, 0)
        delegate("mkdir", category)
        return native.mkdir(path, mode)
      end

      dependencies.scandir = function(path)
        local category = path_category(path, v69_row)
        call("scandir", category, 0)
        delegate("scandir", category)
        local scanner, scan_error, scan_code = native.scandir(path)
        if scanner ~= nil then
          telemetry.scanner_categories[scanner] = category
        end
        return scanner, scan_error, scan_code
      end

      dependencies.scandir_next = function(scanner)
        local category = telemetry.scanner_categories[scanner] or "unexpected"
        call("scandir_next", category, 0)
        delegate("scandir_next", category)
        return native.scandir_next(scanner)
      end

      dependencies.fsync = function(fd)
        local category, generation = descriptor(fd)
        local ordinal = call("fsync", category, generation)
        delegate("fsync", category)
        local synced, sync_error, sync_code = native.fsync(fd)
        result("fsync", category, {
          synced = synced,
          code = sync_code,
        })
        if
          telemetry.phase == "release"
          and spec.key == "O2"
          and category == "state"
          and ordinal == 1
        then
          note_failure("fsync", category, generation, ordinal, true, synced == true)
          return nil, shared_payload, "EIO"
        end
        return synced, sync_error, sync_code
      end

      dependencies.close = function(fd)
        local category, generation, lifetime = descriptor(fd)
        local ordinal = call("close", category, generation)
        if telemetry.phase == "release" then
          if lifetime then
            lifetime.release_close_attempts = lifetime.release_close_attempts + 1
          else
            telemetry.unowned_close_attempts = telemetry.unowned_close_attempts + 1
          end
        end
        delegate("close", category)
        local close_ok, closed, close_error, close_code = pcall(native.close, fd)
        if not close_ok then
          closed = nil
          close_error = "native close failed"
          close_code = "UNKNOWN"
        end
        if closed == true then
          if lifetime and lifetime.active and telemetry.active_by_fd[fd] == lifetime then
            lifetime.active = false
            telemetry.active_by_fd[fd] = nil
            if telemetry.phase == "release" then
              lifetime.release_physical_closes = lifetime.release_physical_closes + 1
              telemetry.physical_closes = telemetry.physical_closes + 1
            end
          elseif telemetry.phase == "release" then
            telemetry.extra_physical_closes = telemetry.extra_physical_closes + 1
          end
        end
        result("close", category, {
          closed = closed,
          code = close_code,
        })
        if
          telemetry.phase == "release"
          and spec.key == "O2"
          and ordinal == 1
          and (category == "lock" or category == "state")
        then
          note_failure("close", category, generation, ordinal, true, close_ok and closed == true)
          return nil, shared_payload, "EIO"
        end
        return closed, close_error, close_code
      end

      dependencies.rmdir = function(path)
        local category = path_category(path, v69_row)
        local ordinal = call("rmdir", category, 0)
        if
          telemetry.phase == "release"
          and (spec.key == "C1" or spec.key == "O2")
          and category == "lock"
          and ordinal == 1
        then
          telemetry.nondelegating_rmdir_count = telemetry.nondelegating_rmdir_count + 1
          note_failure("rmdir", category, 0, ordinal, false, true)
          return nil, shared_payload, "EIO"
        end
        delegate("rmdir", category)
        local removed, remove_error, remove_code = native.rmdir(path)
        result("rmdir", category, {
          removed = removed,
          code = remove_code,
        })
        return removed, remove_error, remove_code
      end

      return dependencies, telemetry
    end

    local function v69_begin_release(telemetry)
      telemetry.calls = new_operation_counters()
      telemetry.delegates = new_operation_counters()
      telemetry.events = {}
      telemetry.native_results = {}
      telemetry.post_delegation = {}
      telemetry.failure_injection_count = 0
      telemetry.failure_injection_native_ok = true
      telemetry.failure_payloads = {}
      telemetry.drift_count = 0
      telemetry.drift_native_ok = true
      telemetry.nondelegating_rmdir_count = 0
      telemetry.live_generation_reuse = 0
      telemetry.integer_fd_aliases = 0
      telemetry.unowned_close_attempts = 0
      telemetry.extra_physical_closes = 0
      telemetry.physical_closes = 0
      telemetry.uid_calls = 0
      telemetry.uid_delegates = 0
      telemetry.uid_unexpected_arguments = 0
      telemetry.rescue_count = 0
      telemetry.fallback_calls = 0
      for _, lifetime in ipairs(telemetry.lifetimes) do
        lifetime.release_close_attempts = 0
        lifetime.release_physical_closes = 0
      end
      telemetry.phase = "release"
    end

    local function v69_complete_snapshot(v69_row)
      local snapshot = v69_telemetry_snapshot(v69_row.telemetry)
      snapshot.filesystem = v69_filesystem_snapshot(v69_row)
      return snapshot
    end

    local function exact_v69_state_projection(snapshot)
      local expected = {
        ["."] = true,
        [lock_name] = true,
        reviews = true,
        ["reviews/control.bin"] = true,
        ["reviews/control-link"] = true,
      }
      local observed = {}
      for _, entry in ipairs(snapshot) do
        if not expected[entry.path] or observed[entry.path] then
          return false
        end
        observed[entry.path] = true
      end
      for path in pairs(expected) do
        if not observed[path] then
          return false
        end
      end
      return true
    end

    local function prepare_v69_row(v69_row, spec)
      local suffix = spec.key:lower()
      local control_bytes = "cycle-2e-e2-" .. suffix .. "-control\n"
      v69_row.state_root = make_root("serialization-release-e2-" .. suffix)
      v69_row.lock_path = vim.fs.joinpath(v69_row.state_root, lock_name)
      v69_row.reviews_path = vim.fs.joinpath(v69_row.state_root, "reviews")
      v69_row.control_path = vim.fs.joinpath(v69_row.reviews_path, "control.bin")
      v69_row.link_path = vim.fs.joinpath(v69_row.reviews_path, "control-link")
      v69_row.private_paths = {
        v69_row.state_root,
        v69_row.lock_path,
        v69_row.reviews_path,
        v69_row.control_path,
        v69_row.link_path,
      }

      if #shared_payload <= 8192 then
        add_failure(v69_row, "shared path-bearing diagnostic payload was not longer than 8 KiB")
      end
      if
        not contained_path(v69_row.state_root, v69_row.lock_path)
        or not contained_path(v69_row.state_root, v69_row.reviews_path)
      then
        add_failure(v69_row, "a " .. spec.key .. " setup path escaped the exact private row root")
      end

      assert(vim.fn.mkdir(v69_row.reviews_path, "p", 448) == 1, spec.key .. " reviews setup failed")
      assert(vim.uv.fs_chmod(v69_row.reviews_path, 448), spec.key .. " reviews chmod failed")
      write_file(v69_row.control_path, control_bytes, 384)
      assert(
        native.symlink("control.bin", v69_row.link_path),
        spec.key .. " reviews symlink setup failed"
      )
      v69_row.reviews_before = snapshot_tree(v69_row.reviews_path)

      local reviews_root_exact = false
      local control_exact = false
      local link_exact = false
      for _, entry in ipairs(v69_row.reviews_before) do
        if
          entry.path == "."
          and entry.type == "directory"
          and entry.mode == 448
          and entry.uid == native.uid()
        then
          reviews_root_exact = true
        elseif
          entry.path == "control.bin"
          and entry.type == "file"
          and entry.mode == 384
          and entry.uid == native.uid()
          and entry.sha256 == vim.fn.sha256(control_bytes)
        then
          control_exact = true
        elseif
          entry.path == "control-link"
          and entry.type == "link"
          and entry.target == "control.bin"
        then
          link_exact = true
        end
      end
      if not reviews_root_exact or not control_exact or not link_exact then
        add_failure(
          v69_row,
          "reviews metadata, regular-file digest, or symlink target was not exact"
        )
      end

      local state_stat, state_error = native.lstat(v69_row.state_root)
      assert(state_stat, tostring(state_error))
      v69_row.state_identity = identity(state_stat)
      if
        v69_row.state_identity.type ~= "directory"
        or v69_row.state_identity.mode ~= 448
        or v69_row.state_identity.uid ~= native.uid()
      then
        add_failure(v69_row, "state root was not an exact current-user mode-0700 directory")
      end

      local dependencies, telemetry = v69_instrumented_dependencies(v69_row, spec)
      v69_row.telemetry = telemetry
      local lease, acquire_error = serialization.acquire(v69_row.state_root, dependencies)
      if not lease then
        if acquire_error ~= nil then
          table.insert(v69_row.visible_results, tostring(acquire_error))
        end
        add_failure(v69_row, "normal " .. spec.key .. " acquisition failed")
        return
      end
      if acquire_error ~= nil then
        table.insert(v69_row.visible_results, tostring(acquire_error))
        add_failure(v69_row, "normal " .. spec.key .. " acquisition returned an error")
      end
      v69_row.lease = lease
      v69_row.acquired_lifetimes = lifetime_snapshot(telemetry)

      local lock_stat, lock_error = native.lstat(v69_row.lock_path)
      assert(lock_stat, tostring(lock_error))
      v69_row.lock_identity = identity(lock_stat)
      v69_row.lock_before = snapshot_tree(v69_row.lock_path)
      local lock_root = v69_row.lock_before[1]
      if
        #v69_row.lock_before ~= 1
        or not lock_root
        or lock_root.path ~= "."
        or lock_root.type ~= "directory"
        or lock_root.mode ~= 448
        or lock_root.uid ~= native.uid()
        or lock_root.dev ~= v69_row.state_identity.dev
        or not same_identity(v69_row.lock_identity, lock_root)
      then
        add_failure(v69_row, "acquired lock was not an exact private empty directory")
      end
      if #v69_row.acquired_lifetimes ~= 2 then
        add_failure(v69_row, "acquisition did not retain exactly two descriptor generations")
      end
      if
        v69_row.acquired_lifetimes[1]
        and v69_row.acquired_lifetimes[2]
        and v69_row.acquired_lifetimes[1].fd == v69_row.acquired_lifetimes[2].fd
      then
        add_failure(v69_row, "acquired state and lock lifetimes aliased one integer fd")
      end
      v69_row.state_before = snapshot_tree(v69_row.state_root)
      if not exact_v69_state_projection(v69_row.state_before) then
        add_failure(v69_row, "pre-release state-root projection was not exact")
      end

      v69_begin_release(telemetry)
    end

    local function exercise_v69(v69_row, spec)
      prepare_v69_row(v69_row, spec)
      if not v69_row.lease then
        return
      end

      v69_row.external_release_calls = v69_row.external_release_calls + 1
      v69_row.first_capture = capture_release(v69_row.lease)
      add_visible_capture(v69_row, v69_row.first_capture)
      v69_row.first_activity = v69_complete_snapshot(v69_row)

      v69_row.repeat_tuples_equal = true
      v69_row.repeat_activity_stable = true
      for _ = 1, 2 do
        v69_row.external_release_calls = v69_row.external_release_calls + 1
        local repeated = capture_release(v69_row.lease)
        add_visible_capture(v69_row, repeated)
        if not repeated.ok or not vim.deep_equal(repeated.tuple, v69_row.first_capture.tuple) then
          v69_row.repeat_tuples_equal = false
        end
        local repeated_activity = v69_complete_snapshot(v69_row)
        if not vim.deep_equal(repeated_activity, v69_row.first_activity) then
          v69_row.repeat_activity_stable = false
        end
      end

      if not v69_row.repeat_tuples_equal then
        add_failure(v69_row, "cached releases did not repeat the complete nil-sensitive pair")
      end
      if not v69_row.repeat_activity_stable then
        add_failure(
          v69_row,
          "cached releases changed dependency, descriptor, or filesystem activity"
        )
      end
    end

    local function validate_v69(v69_row, spec)
      if not v69_row.first_capture then
        add_failure(v69_row, "first release result was not captured")
        return
      end
      local expected_tuple = { n = 2, [2] = spec.expected_error }
      if not v69_row.first_capture.ok then
        add_failure(v69_row, "first release raised")
      elseif not vim.deep_equal(v69_row.first_capture.tuple, expected_tuple) then
        add_failure(
          v69_row,
          "first release did not return the exact bounded " .. spec.key .. " pair"
        )
      end
      if not v69_row.first_activity then
        add_failure(v69_row, "first release activity was not captured")
        return
      end

      if not vim.deep_equal(v69_row.first_activity.events, spec.expected_events) then
        add_failure(v69_row, "release event vector was not exact " .. spec.vector)
      end

      local expected_calls = {
        lstat = { 0, 2 },
        realpath = { 0, 1 },
        open = { 0, 0 },
        fstat = { 1, 1 },
        mkdir = { 0, 0 },
        scandir = { 0, 0 },
        scandir_next = { 0, 0 },
        fsync = { 1, 0 },
        close = { 1, 1 },
        rmdir = { 0, spec.rmdir_calls },
      }
      local expected_delegates = copy(expected_calls)
      expected_delegates.rmdir = { 0, 0 }
      for _, operation in ipairs(operation_names) do
        local calls = expected_calls[operation]
        local delegates = expected_delegates[operation]
        expect_path_counter(
          v69_row,
          operation .. " calls",
          v69_row.first_activity.calls[operation],
          calls[1],
          calls[2]
        )
        expect_path_counter(
          v69_row,
          operation .. " native delegations",
          v69_row.first_activity.delegates[operation],
          delegates[1],
          delegates[2]
        )
      end
      expect_count(v69_row, "UID calls", v69_row.first_activity.uid_calls, 0)
      expect_count(v69_row, "UID native delegations", v69_row.first_activity.uid_delegates, 0)
      expect_count(
        v69_row,
        "UID unexpected arguments",
        v69_row.first_activity.uid_unexpected_arguments,
        0
      )

      local state_fstat = first_result(v69_row.first_activity, "fstat", "state", 1)
      local initial_lstat = first_result(v69_row.first_activity, "lstat", "lock", 1)
      local lock_fstat = first_result(v69_row.first_activity, "fstat", "lock", 1)
      local realpath = first_result(v69_row.first_activity, "realpath", "lock", 1)
      local final_lstat = first_result(v69_row.first_activity, "lstat", "lock", 2)
      local lock_close = first_result(v69_row.first_activity, "close", "lock", 1)
      local state_fsync = first_result(v69_row.first_activity, "fsync", "state", 1)
      local state_close = first_result(v69_row.first_activity, "close", "state", 1)
      if
        not state_fstat
        or not state_fstat.exists
        or not same_identity(state_fstat.identity, v69_row.state_identity)
      then
        add_failure(
          v69_row,
          "native retained-state validation did not observe the acquired identity"
        )
      end
      if
        not initial_lstat
        or not initial_lstat.exists
        or not same_identity(initial_lstat.identity, v69_row.lock_identity)
      then
        add_failure(v69_row, "initial fixed-path lstat did not observe the acquired lock")
      end
      if
        not lock_fstat
        or not lock_fstat.exists
        or not same_identity(lock_fstat.identity, v69_row.lock_identity)
      then
        add_failure(v69_row, "retained lock fd did not observe the acquired lock")
      end
      if not realpath or realpath.path ~= v69_row.lock_path then
        add_failure(v69_row, "delegated realpath did not prove the exact fixed lock path")
      end
      if
        not final_lstat
        or not final_lstat.exists
        or not same_identity(final_lstat.identity, v69_row.lock_identity)
      then
        add_failure(v69_row, "mandatory final lstat did not observe the acquired lock")
      end
      if final_lstat and final_lstat.enoent then
        add_failure(v69_row, "final revalidation incorrectly observed lock absence")
      end
      if not lock_close or lock_close.closed ~= true then
        add_failure(v69_row, "retained lock fd was not physically closed")
      end
      if not state_fsync or state_fsync.synced ~= true then
        add_failure(v69_row, "state root did not receive one native synchronization attempt")
      end
      if not state_close or state_close.closed ~= true then
        add_failure(v69_row, "retained state fd was not physically closed last")
      end
      if v69_row.first_activity.native_results.rmdir ~= nil then
        add_failure(v69_row, "a nondelegating or gated rmdir unexpectedly reached native code")
      end

      expect_count(
        v69_row,
        "state-identity drift injections",
        v69_row.first_activity.drift_count,
        spec.drift_count
      )
      if v69_row.first_activity.drift_native_ok ~= true then
        add_failure(v69_row, "state-identity drift lacked its successful native proof")
      end
      expect_count(
        v69_row,
        "release failure injections",
        v69_row.first_activity.failure_injection_count,
        spec.failure_injection_count
      )
      if v69_row.first_activity.failure_injection_native_ok ~= true then
        add_failure(v69_row, "a delegated release injection lacked native success")
      end
      expect_count(
        v69_row,
        "nondelegating rmdir injections",
        v69_row.first_activity.nondelegating_rmdir_count,
        spec.nondelegating_rmdir_count
      )
      if not vim.deep_equal(v69_row.first_activity.post_delegation, spec.post_delegation) then
        add_failure(v69_row, "native-result and injection trace was not exact")
      end
      if #v69_row.first_activity.failure_payloads ~= spec.failure_injection_count then
        add_failure(v69_row, "failure payload count was not exact")
      else
        for _, payload in ipairs(v69_row.first_activity.failure_payloads) do
          if payload ~= shared_payload then
            add_failure(v69_row, "a release injection did not use the shared payload")
          end
        end
      end

      local filesystem = v69_row.first_activity.filesystem
      if not v69_snapshots_ok(filesystem) then
        add_failure(v69_row, "complete first-release filesystem snapshot was unavailable")
      else
        local final_state_root = filesystem.state.value[1]
        local final_lock_root = filesystem.lock.value[1]
        if
          not final_state_root
          or not same_identity(identity(final_state_root), v69_row.state_identity)
        then
          add_failure(v69_row, "state-root identity or private metadata changed")
        end
        if
          not final_lock_root
          or not same_identity(identity(final_lock_root), v69_row.lock_identity)
          or not vim.deep_equal(filesystem.lock.value, v69_row.lock_before)
        then
          add_failure(v69_row, "KEEP lock identity or complete snapshot changed")
        end
        if not vim.deep_equal(filesystem.state.value, v69_row.state_before) then
          add_failure(v69_row, "complete KEEP state-root projection changed")
        end
        if not exact_v69_state_projection(filesystem.state.value) then
          add_failure(v69_row, "KEEP state-root projection had a missing or extra sibling")
        end
        if not vim.deep_equal(filesystem.reviews.value, v69_row.reviews_before) then
          add_failure(v69_row, "content-aware reviews snapshot changed during release")
        end
      end

      local acquired_counts = { state = 0, lock = 0, unexpected = 0 }
      for _, lifetime in ipairs(v69_row.acquired_lifetimes or {}) do
        acquired_counts[lifetime.category] = acquired_counts[lifetime.category] + 1
        if
          lifetime.generation ~= 1
          or lifetime.active ~= true
          or lifetime.release_close_attempts ~= 0
          or lifetime.release_physical_closes ~= 0
        then
          add_failure(v69_row, "pre-release acquired generation state was not exact")
        end
      end
      expect_count(v69_row, "acquired state generations", acquired_counts.state, 1)
      expect_count(v69_row, "acquired lock generations", acquired_counts.lock, 1)
      expect_count(v69_row, "acquired unexpected generations", acquired_counts.unexpected, 0)

      local lifetime_counts = { state = 0, lock = 0, unexpected = 0 }
      for _, lifetime in ipairs(v69_row.first_activity.lifetimes) do
        lifetime_counts[lifetime.category] = lifetime_counts[lifetime.category] + 1
        if lifetime.generation ~= 1 then
          add_failure(v69_row, "owned descriptor generation was not one")
        end
        if lifetime.release_close_attempts ~= 1 then
          add_failure(v69_row, "owned generation did not receive exactly one release close")
        end
        if lifetime.release_physical_closes ~= 1 or lifetime.active then
          add_failure(v69_row, "owned generation was not physically closed exactly once")
        end
      end
      expect_count(v69_row, "state descriptor generations", lifetime_counts.state, 1)
      expect_count(v69_row, "lock descriptor generations", lifetime_counts.lock, 1)
      expect_count(v69_row, "unexpected descriptor generations", lifetime_counts.unexpected, 0)
      expect_count(
        v69_row,
        "live generation reuse",
        v69_row.first_activity.live_generation_reuse,
        0
      )
      expect_count(v69_row, "integer-fd aliases", v69_row.first_activity.integer_fd_aliases, 0)
      expect_count(
        v69_row,
        "unowned close attempts",
        v69_row.first_activity.unowned_close_attempts,
        0
      )
      expect_count(
        v69_row,
        "extra physical closes",
        v69_row.first_activity.extra_physical_closes,
        0
      )
      expect_count(v69_row, "physical closes", v69_row.first_activity.physical_closes, 2)
      expect_count(v69_row, "rescue calls", v69_row.first_activity.rescue_count, 0)
      expect_count(v69_row, "fallback release calls", v69_row.first_activity.fallback_calls, 0)
    end

    local function finish_v69(v69_row, spec, protected_ok, protected_error)
      if not protected_ok then
        table.insert(v69_row.visible_results, protected_error)
        add_failure(v69_row, "protected " .. spec.key .. " exercise did not complete")
      end

      local all_closed = true
      if v69_row.telemetry then
        v69_row.telemetry.phase = "teardown"
        for _, lifetime in ipairs(v69_row.telemetry.lifetimes) do
          if lifetime.active then
            v69_row.telemetry.rescue_count = v69_row.telemetry.rescue_count + 1
            add_failure(v69_row, "an exact live owned generation required rescue")
            local current = v69_row.telemetry.active_by_fd[lifetime.fd]
            if current == lifetime and current.generation == lifetime.generation then
              local rescue_ok, rescued = pcall(native.close, lifetime.fd)
              if rescue_ok and rescued == true then
                lifetime.active = false
                v69_row.telemetry.active_by_fd[lifetime.fd] = nil
              end
            end
          end
          if lifetime.active then
            all_closed = false
          end
        end
        if v69_row.telemetry.rescue_count ~= 0 then
          add_failure(v69_row, "descriptor rescue count was not zero")
        end
        if v69_row.telemetry.fallback_calls ~= 0 then
          add_failure(v69_row, "release was retried during fallback or teardown")
        end
        if v69_row.telemetry.extra_physical_closes ~= 0 then
          add_failure(v69_row, "an extra descriptor was physically closed")
        end
      end

      if v69_row.external_release_calls ~= 3 then
        add_failure(v69_row, "external release-call count was not three")
      end
      if #v69_row.captures ~= v69_row.external_release_calls then
        add_failure(v69_row, "release capture count did not match external release calls")
      end

      if v69_row.state_root and all_closed then
        local removed = vim.fn.delete(v69_row.state_root, "rf")
        if removed ~= 0 then
          add_failure(v69_row, "exact private row-root teardown failed")
        end
        local stat, stat_error, stat_code = native.lstat(v69_row.state_root)
        if not is_enoent(stat, stat_error, stat_code) then
          add_failure(v69_row, "exact private row-root absence was not proven")
        end
      elseif v69_row.state_root then
        add_failure(v69_row, "private row root was retained because a descriptor remained live")
      end

      local first_kind = "missing"
      if v69_row.first_capture then
        if
          v69_row.first_capture.ok
          and v69_row.first_capture.tuple[1] == nil
          and v69_row.first_capture.tuple[2] == spec.expected_error
        then
          first_kind = spec.first_kind
        elseif
          v69_row.first_capture.ok
          and v69_row.first_capture.tuple[1] == true
          and v69_row.first_capture.tuple[2] == nil
        then
          first_kind = "success"
        elseif v69_row.first_capture.ok then
          first_kind = "other"
        else
          first_kind = "raised"
        end
      end
      local outcome = "missing"
      if
        v69_row.first_activity
        and v69_row.first_activity.filesystem
        and v69_row.first_activity.filesystem.lock.ok
      then
        local lock_snapshot = v69_row.first_activity.filesystem.lock.value
        if vim.deep_equal(lock_snapshot, ABS) then
          outcome = "ABS"
        elseif
          v69_row.lock_identity
          and lock_snapshot[1]
          and same_identity(identity(lock_snapshot[1]), v69_row.lock_identity)
          and vim.deep_equal(lock_snapshot, v69_row.lock_before)
        then
          outcome = "KEEP"
        else
          outcome = "OTHER"
        end
      end
      local events = v69_row.first_activity and table.concat(v69_row.first_activity.events, ",")
        or "none"
      v69_row.observation = string.format(
        "%s first=%s repeat-tuple=%s repeat-activity=%s drift=%d injection=%d nondelegating=%d outcome=%s rescue=%d events=%s",
        spec.key,
        first_kind,
        tostring(v69_row.repeat_tuples_equal),
        tostring(v69_row.repeat_activity_stable),
        v69_row.first_activity and v69_row.first_activity.drift_count or 0,
        v69_row.first_activity and v69_row.first_activity.failure_injection_count or 0,
        v69_row.first_activity and v69_row.first_activity.nondelegating_rmdir_count or 0,
        outcome,
        v69_row.telemetry and v69_row.telemetry.rescue_count or 0,
        events
      )
      if #v69_row.observation > 1024 then
        add_failure(v69_row, spec.key .. " observation was not bounded")
      end
      table.insert(observations, v69_row.observation)

      for _, result_text in ipairs(v69_row.visible_results) do
        if #result_text > 1024 then
          add_failure(v69_row, "a public or protected result was not bounded")
        end
      end
      local diagnostic_visible = copy(v69_row.visible_results)
      vim.list_extend(diagnostic_visible, v69_row.failures)
      table.insert(diagnostic_visible, v69_row.observation)
      local forbidden = {
        shared_payload,
        fixed_private_path,
        v4_fixed_private_path,
        v0_fixed_private_path,
        c1_fixed_private_path,
        o2_fixed_private_path,
      }
      vim.list_extend(forbidden, v69_row.private_paths or {})
      local leak_found = false
      for _, visible in ipairs(diagnostic_visible) do
        for _, needle in ipairs(forbidden) do
          if type(needle) == "string" and #needle > 0 and visible:find(needle, 1, true) then
            leak_found = true
          end
        end
      end
      if leak_found then
        add_failure(v69_row, "a shared payload or private fixture path reached diagnostics")
      end

      for _, detail in ipairs(v69_row.failures) do
        table.insert(failures, v69_row.label .. " " .. detail)
      end
    end

    local v0_spec = {
      key = "V0",
      label = "V0 retained state inode drift",
      expected_error = RVS,
      first_kind = "RVS",
      vector = "FS,L1,FL,RP,L2,CL,SY,CS",
      rmdir_calls = 0,
      drift_count = 1,
      failure_injection_count = 0,
      nondelegating_rmdir_count = 0,
      expected_events = {
        "fstat:state:g1:1",
        "lstat:lock:g0:1",
        "fstat:lock:g1:1",
        "realpath:lock:g0:1",
        "lstat:lock:g0:2",
        "close:lock:g1:1",
        "fsync:state:g1:1",
        "close:state:g1:1",
      },
      post_delegation = {
        "native:fstat:state:g1:1:true",
        "drift:fstat:state:g1:1",
      },
    }
    local c1_spec = {
      key = "C1",
      label = "C1 nondelegating rmdir failure",
      expected_error = RR,
      first_kind = "RR",
      vector = "FS,L1,FL,RP,L2,CL,RM,SY,CS",
      rmdir_calls = 1,
      drift_count = 0,
      failure_injection_count = 1,
      nondelegating_rmdir_count = 1,
      expected_events = {
        "fstat:state:g1:1",
        "lstat:lock:g0:1",
        "fstat:lock:g1:1",
        "realpath:lock:g0:1",
        "lstat:lock:g0:2",
        "close:lock:g1:1",
        "rmdir:lock:g0:1",
        "fsync:state:g1:1",
        "close:state:g1:1",
      },
      post_delegation = {
        "inject:rmdir:lock:g0:1",
      },
    }
    local o2_spec = {
      key = "O2",
      label = "O2 close rmdir fsync close aggregate",
      expected_error = O2_ERROR,
      first_kind = "O2",
      vector = "FS,L1,FL,RP,L2,CL,RM,SY,CS",
      rmdir_calls = 1,
      drift_count = 0,
      failure_injection_count = 4,
      nondelegating_rmdir_count = 1,
      expected_events = {
        "fstat:state:g1:1",
        "lstat:lock:g0:1",
        "fstat:lock:g1:1",
        "realpath:lock:g0:1",
        "lstat:lock:g0:2",
        "close:lock:g1:1",
        "rmdir:lock:g0:1",
        "fsync:state:g1:1",
        "close:state:g1:1",
      },
      post_delegation = {
        "native:close:lock:g1:1:true",
        "inject:close:lock:g1:1",
        "inject:rmdir:lock:g0:1",
        "native:fsync:state:g1:1:true",
        "inject:fsync:state:g1:1",
        "native:close:state:g1:1:true",
        "inject:close:state:g1:1",
      },
    }

    v0_executed_rows = v0_executed_rows + 1
    local v0_row = {
      label = v0_spec.label,
      failures = {},
      captures = {},
      visible_results = {},
      private_paths = {},
      external_release_calls = 0,
      repeat_tuples_equal = false,
      repeat_activity_stable = false,
    }
    local v0_protected_ok, v0_protected_error = xpcall(function()
      exercise_v69(v0_row, v0_spec)
      validate_v69(v0_row, v0_spec)
    end, function()
      return "protected V0 exercise failed"
    end)
    finish_v69(v0_row, v0_spec, v0_protected_ok, v0_protected_error)

    c1_executed_rows = c1_executed_rows + 1
    local c1_row = {
      label = c1_spec.label,
      failures = {},
      captures = {},
      visible_results = {},
      private_paths = {},
      external_release_calls = 0,
      repeat_tuples_equal = false,
      repeat_activity_stable = false,
    }
    local c1_protected_ok, c1_protected_error = xpcall(function()
      exercise_v69(c1_row, c1_spec)
      validate_v69(c1_row, c1_spec)
    end, function()
      return "protected C1 exercise failed"
    end)
    finish_v69(c1_row, c1_spec, c1_protected_ok, c1_protected_error)

    o2_executed_rows = o2_executed_rows + 1
    local o2_row = {
      label = o2_spec.label,
      failures = {},
      captures = {},
      visible_results = {},
      private_paths = {},
      external_release_calls = 0,
      repeat_tuples_equal = false,
      repeat_activity_stable = false,
    }
    local o2_protected_ok, o2_protected_error = xpcall(function()
      exercise_v69(o2_row, o2_spec)
      validate_v69(o2_row, o2_spec)
    end, function()
      return "protected O2 exercise failed"
    end)
    finish_v69(o2_row, o2_spec, o2_protected_ok, o2_protected_error)

    if v0_executed_rows ~= 1 then
      table.insert(failures, "Cycle 2E E2 V0 did not execute exactly once")
    end
    if c1_executed_rows ~= 1 then
      table.insert(failures, "Cycle 2E E2 C1 did not execute exactly once")
    end
    if o2_executed_rows ~= 1 then
      table.insert(failures, "Cycle 2E E2 O2 did not execute exactly once")
    end
    if not v0_row.observation or observations[3] ~= v0_row.observation then
      table.insert(failures, "Cycle 2E E2 V0 did not append one bounded observation")
    end
    if not c1_row.observation or observations[4] ~= c1_row.observation then
      table.insert(failures, "Cycle 2E E2 C1 did not append one bounded observation")
    end
    if not o2_row.observation or observations[5] ~= o2_row.observation then
      table.insert(failures, "Cycle 2E E2 O2 did not append one bounded observation")
    end

    local v1_fixed_private_path = "/fixed/private/cycle-2e-e2-v1"
    local v2_fixed_private_path = "/fixed/private/cycle-2e-e2-v2"
    local v1_executed_rows = 0
    local v2_executed_rows = 0

    local function v71_filesystem_snapshot(v71_row)
      local snapshot = {
        state = protected_snapshot(v71_row.state_root),
        lock = protected_snapshot(v71_row.lock_path),
        reviews = protected_snapshot(v71_row.reviews_path),
        retired = protected_snapshot(v71_row.retired_path),
        staging = protected_snapshot(v71_row.staging_path),
      }
      if v71_row.target_path then
        snapshot.target = protected_snapshot(v71_row.target_path)
      end
      return snapshot
    end

    local function v71_snapshots_ok(filesystem)
      return filesystem.state.ok
        and filesystem.lock.ok
        and filesystem.reviews.ok
        and filesystem.retired.ok
        and filesystem.staging.ok
        and (filesystem.target == nil or filesystem.target.ok)
    end

    local function exact_v71_state_projection(snapshot, spec)
      local expected = {
        ["."] = true,
        [lock_name] = true,
        [spec.retired_name] = true,
        reviews = true,
        ["reviews/control.bin"] = true,
        ["reviews/control-link"] = true,
      }
      if spec.target_name then
        expected[spec.target_name] = true
      end
      local observed = {}
      for _, entry in ipairs(snapshot) do
        if not expected[entry.path] or observed[entry.path] then
          return false
        end
        observed[entry.path] = true
      end
      for path in pairs(expected) do
        if not observed[path] then
          return false
        end
      end
      return true
    end

    local function v71_complete_snapshot(v71_row)
      local snapshot = v69_telemetry_snapshot(v71_row.telemetry)
      snapshot.filesystem = v71_filesystem_snapshot(v71_row)
      return snapshot
    end

    local function prepare_v71_foundation(v71_row, spec)
      local suffix = spec.key:lower()
      local control_bytes = "cycle-2e-e2-" .. suffix .. "-control\n"
      v71_row.state_root = make_root("serialization-release-e2-" .. suffix)
      v71_row.lock_path = vim.fs.joinpath(v71_row.state_root, lock_name)
      v71_row.reviews_path = vim.fs.joinpath(v71_row.state_root, "reviews")
      v71_row.control_path = vim.fs.joinpath(v71_row.reviews_path, "control.bin")
      v71_row.link_path = vim.fs.joinpath(v71_row.reviews_path, "control-link")
      v71_row.retired_path = vim.fs.joinpath(v71_row.state_root, spec.retired_name)
      v71_row.staging_path = vim.fs.joinpath(v71_row.state_root, spec.staging_name)
      if spec.target_name then
        v71_row.target_path = vim.fs.joinpath(v71_row.state_root, spec.target_name)
      end
      v71_row.private_paths = {
        v71_row.state_root,
        v71_row.lock_path,
        v71_row.reviews_path,
        v71_row.control_path,
        v71_row.link_path,
        v71_row.retired_path,
        v71_row.staging_path,
      }
      if v71_row.target_path then
        table.insert(v71_row.private_paths, v71_row.target_path)
      end
      v71_row.swap = {
        rename_calls = 0,
        rename_successes = 0,
        completed = false,
      }

      if #shared_payload <= 8192 then
        add_failure(v71_row, "shared path-bearing diagnostic payload was not longer than 8 KiB")
      end
      for _, path in ipairs(v71_row.private_paths) do
        if path ~= v71_row.state_root and not contained_path(v71_row.state_root, path) then
          add_failure(v71_row, "a " .. spec.key .. " setup path escaped the exact private row root")
        end
      end

      assert(vim.fn.mkdir(v71_row.reviews_path, "p", 448) == 1, spec.key .. " reviews setup failed")
      assert(vim.uv.fs_chmod(v71_row.reviews_path, 448), spec.key .. " reviews chmod failed")
      write_file(v71_row.control_path, control_bytes, 384)
      assert(
        native.symlink("control.bin", v71_row.link_path),
        spec.key .. " reviews symlink setup failed"
      )
      v71_row.reviews_before = snapshot_tree(v71_row.reviews_path)

      local reviews_root_exact = false
      local control_exact = false
      local link_exact = false
      for _, entry in ipairs(v71_row.reviews_before) do
        if
          entry.path == "."
          and entry.type == "directory"
          and entry.mode == 448
          and entry.uid == native.uid()
        then
          reviews_root_exact = true
        elseif
          entry.path == "control.bin"
          and entry.type == "file"
          and entry.mode == 384
          and entry.uid == native.uid()
          and entry.sha256 == vim.fn.sha256(control_bytes)
        then
          control_exact = true
        elseif
          entry.path == "control-link"
          and entry.type == "link"
          and entry.target == "control.bin"
        then
          link_exact = true
        end
      end
      if
        #v71_row.reviews_before ~= 3
        or not reviews_root_exact
        or not control_exact
        or not link_exact
      then
        add_failure(
          v71_row,
          "reviews metadata, regular-file digest, symlink target, or cardinality was not exact"
        )
      end

      local state_stat, state_error = native.lstat(v71_row.state_root)
      assert(state_stat, tostring(state_error))
      v71_row.state_identity = identity(state_stat)
      if
        v71_row.state_identity.type ~= "directory"
        or v71_row.state_identity.mode ~= 448
        or v71_row.state_identity.uid ~= native.uid()
      then
        add_failure(v71_row, "state root was not an exact current-user mode-0700 directory")
      end
      if not vim.deep_equal(snapshot_tree(v71_row.retired_path), ABS) then
        add_failure(v71_row, "retired path was not absent before acquisition")
      end
      if not vim.deep_equal(snapshot_tree(v71_row.staging_path), ABS) then
        add_failure(v71_row, "staging path was not absent before acquisition")
      end
      if v71_row.target_path and not vim.deep_equal(snapshot_tree(v71_row.target_path), ABS) then
        add_failure(v71_row, "target path was not absent before acquisition")
      end

      local dependencies, telemetry = v69_instrumented_dependencies(v71_row, spec)
      v71_row.telemetry = telemetry
      local lease, acquire_error = serialization.acquire(v71_row.state_root, dependencies)
      if not lease then
        if acquire_error ~= nil then
          table.insert(v71_row.visible_results, tostring(acquire_error))
        end
        add_failure(v71_row, "normal " .. spec.key .. " acquisition failed")
        return
      end
      if acquire_error ~= nil then
        table.insert(v71_row.visible_results, tostring(acquire_error))
        add_failure(v71_row, "normal " .. spec.key .. " acquisition returned an error")
      end
      v71_row.lease = lease
      v71_row.acquired_lifetimes = lifetime_snapshot(telemetry)

      v71_row.acquired_lock = exact_capture(v71_row.lock_path)
      v71_row.lock_identity = v71_row.acquired_lock.identity
      v71_row.lock_before = v71_row.acquired_lock.snapshot
      local lock_root = v71_row.lock_before[1]
      if
        #v71_row.lock_before ~= 1
        or not lock_root
        or lock_root.path ~= "."
        or lock_root.type ~= "directory"
        or lock_root.mode ~= 448
        or lock_root.uid ~= native.uid()
        or lock_root.dev ~= v71_row.state_identity.dev
        or not same_identity(v71_row.lock_identity, lock_root)
      then
        add_failure(v71_row, "acquired lock was not an exact private empty directory")
      end
      if #v71_row.acquired_lifetimes ~= 2 then
        add_failure(v71_row, "acquisition did not retain exactly two descriptor generations")
      end
      if
        v71_row.acquired_lifetimes[1]
        and v71_row.acquired_lifetimes[2]
        and v71_row.acquired_lifetimes[1].fd == v71_row.acquired_lifetimes[2].fd
      then
        add_failure(v71_row, "acquired state and lock lifetimes aliased one integer fd")
      end
    end

    local function perform_v71_replacement(v71_row, spec)
      if spec.kind == "directory" then
        local created, create_error = native.mkdir(v71_row.staging_path, 448)
        assert(created, tostring(create_error))
        assert(vim.uv.fs_chmod(v71_row.staging_path, 448), spec.key .. " replacement chmod failed")
        v71_row.staged_replacement = exact_capture(v71_row.staging_path)
        local replacement_root = v71_row.staged_replacement.snapshot[1]
        if
          #v71_row.staged_replacement.snapshot ~= 1
          or not replacement_root
          or replacement_root.path ~= "."
          or replacement_root.type ~= "directory"
          or replacement_root.mode ~= 448
          or replacement_root.uid ~= native.uid()
          or replacement_root.dev ~= v71_row.state_identity.dev
          or not same_identity(v71_row.staged_replacement.identity, replacement_root)
          or same_identity(v71_row.staged_replacement.identity, v71_row.lock_identity)
        then
          add_failure(
            v71_row,
            "staged replacement was not exact, distinct, private, empty, and same-device"
          )
        end
      else
        local target_created, target_error = native.mkdir(v71_row.target_path, 448)
        assert(target_created, tostring(target_error))
        assert(vim.uv.fs_chmod(v71_row.target_path, 448), spec.key .. " target chmod failed")
        v71_row.target_before = exact_capture(v71_row.target_path)
        local target_root = v71_row.target_before.snapshot[1]
        if
          #v71_row.target_before.snapshot ~= 1
          or not target_root
          or target_root.path ~= "."
          or target_root.type ~= "directory"
          or target_root.mode ~= 448
          or target_root.uid ~= native.uid()
          or target_root.dev ~= v71_row.state_identity.dev
          or not same_identity(v71_row.target_before.identity, target_root)
          or same_identity(v71_row.target_before.identity, v71_row.lock_identity)
        then
          add_failure(
            v71_row,
            "symlink target was not exact, distinct, private, empty, and same-device"
          )
        end

        local linked, link_error = native.symlink(v71_row.target_path, v71_row.staging_path)
        assert(linked, tostring(link_error))
        v71_row.staged_replacement = exact_capture(v71_row.staging_path)
        local staged_link = v71_row.staged_replacement.snapshot[1]
        if
          #v71_row.staged_replacement.snapshot ~= 1
          or not staged_link
          or staged_link.path ~= "."
          or staged_link.type ~= "link"
          or staged_link.uid ~= native.uid()
          or staged_link.dev ~= v71_row.state_identity.dev
          or staged_link.target ~= v71_row.target_path
          or not same_identity(v71_row.staged_replacement.identity, staged_link)
          or same_identity(v71_row.staged_replacement.identity, v71_row.lock_identity)
        then
          add_failure(
            v71_row,
            "staged symlink replacement or its exact contained target was not exact"
          )
        end
      end

      v71_row.swap.rename_calls = v71_row.swap.rename_calls + 1
      local retired, retire_error = native.rename(v71_row.lock_path, v71_row.retired_path)
      assert(retired, tostring(retire_error))
      v71_row.swap.rename_successes = v71_row.swap.rename_successes + 1

      v71_row.swap.rename_calls = v71_row.swap.rename_calls + 1
      local installed, install_error = native.rename(v71_row.staging_path, v71_row.lock_path)
      assert(installed, tostring(install_error))
      v71_row.swap.rename_successes = v71_row.swap.rename_successes + 1
      v71_row.swap.completed = true

      v71_row.retired_before = exact_capture(v71_row.retired_path)
      v71_row.fixed_before = exact_capture(v71_row.lock_path)
      if
        not same_identity(v71_row.retired_before.identity, v71_row.lock_identity)
        or not vim.deep_equal(v71_row.retired_before.snapshot, v71_row.lock_before)
      then
        add_failure(v71_row, "retired path did not preserve the exact acquired lock")
      end
      if
        not same_identity(v71_row.fixed_before.identity, v71_row.staged_replacement.identity)
        or not vim.deep_equal(v71_row.fixed_before.snapshot, v71_row.staged_replacement.snapshot)
        or same_identity(v71_row.fixed_before.identity, v71_row.lock_identity)
      then
        add_failure(v71_row, "fixed path did not preserve the exact distinct replacement")
      end
      if not vim.deep_equal(snapshot_tree(v71_row.staging_path), ABS) then
        add_failure(v71_row, "staging path was not absent after atomic installation")
      end
      if spec.kind == "symlink" then
        local target_after = exact_capture(v71_row.target_path)
        local installed_link = v71_row.fixed_before.snapshot[1]
        if
          not vim.deep_equal(target_after, v71_row.target_before)
          or not installed_link
          or installed_link.type ~= "link"
          or installed_link.target ~= v71_row.target_path
        then
          add_failure(v71_row, "installed link or its exact private target changed")
        end
      end

      v71_row.pre_release_filesystem = v71_filesystem_snapshot(v71_row)
      if not v71_snapshots_ok(v71_row.pre_release_filesystem) then
        add_failure(v71_row, "complete pre-release SWAP snapshot was unavailable")
      else
        v71_row.state_before = v71_row.pre_release_filesystem.state.value
        if not exact_v71_state_projection(v71_row.state_before, spec) then
          add_failure(v71_row, "pre-release SWAP state projection was not exact")
        end
        if
          not vim.deep_equal(v71_row.pre_release_filesystem.reviews.value, v71_row.reviews_before)
        then
          add_failure(v71_row, "reviews snapshot changed during replacement setup")
        end
        if not vim.deep_equal(v71_row.pre_release_filesystem.staging.value, ABS) then
          add_failure(v71_row, "pre-release staging path was not absent")
        end
      end

      v69_begin_release(v71_row.telemetry)
    end

    local function exercise_v71(v71_row, spec)
      prepare_v71_foundation(v71_row, spec)
      if not v71_row.lease then
        return
      end
      perform_v71_replacement(v71_row, spec)
      v71_row.release_start = v69_telemetry_snapshot(v71_row.telemetry)

      v71_row.external_release_calls = v71_row.external_release_calls + 1
      v71_row.first_capture = capture_release(v71_row.lease)
      add_visible_capture(v71_row, v71_row.first_capture)
      v71_row.first_activity = v71_complete_snapshot(v71_row)

      v71_row.repeat_tuples_equal = true
      v71_row.repeat_activity_stable = true
      for _ = 1, 2 do
        v71_row.external_release_calls = v71_row.external_release_calls + 1
        local repeated = capture_release(v71_row.lease)
        add_visible_capture(v71_row, repeated)
        if not repeated.ok or not vim.deep_equal(repeated.tuple, v71_row.first_capture.tuple) then
          v71_row.repeat_tuples_equal = false
        end
        local repeated_activity = v71_complete_snapshot(v71_row)
        if not vim.deep_equal(repeated_activity, v71_row.first_activity) then
          v71_row.repeat_activity_stable = false
        end
      end

      if not v71_row.repeat_tuples_equal then
        add_failure(v71_row, "cached releases did not repeat the complete nil-sensitive pair")
      end
      if not v71_row.repeat_activity_stable then
        add_failure(
          v71_row,
          "cached releases changed dependency, descriptor, native-result, or SWAP activity"
        )
      end
    end

    local function validate_v71_release(v71_row, spec)
      if not v71_row.first_capture then
        add_failure(v71_row, "first release result was not captured")
        return
      end
      local expected_tuple = { n = 2, [2] = RVL }
      if not v71_row.first_capture.ok then
        add_failure(v71_row, "first release raised")
      elseif not vim.deep_equal(v71_row.first_capture.tuple, expected_tuple) then
        add_failure(v71_row, "first release did not return the exact bounded RVL pair")
      end
      if not v71_row.first_activity then
        add_failure(v71_row, "first release activity was not captured")
        return
      end

      local expected_events = {
        "fstat:state:g1:1",
        "lstat:lock:g0:1",
        "fstat:lock:g1:1",
        "realpath:lock:g0:1",
        "lstat:lock:g0:2",
        "close:lock:g1:1",
        "fsync:state:g1:1",
        "close:state:g1:1",
      }
      if not vim.deep_equal(v71_row.first_activity.events, expected_events) then
        add_failure(v71_row, "release event vector was not exact FS,L1,FL,RP,L2,CL,SY,CS")
      end

      local expected_counts = {
        lstat = { 0, 2 },
        realpath = { 0, 1 },
        open = { 0, 0 },
        fstat = { 1, 1 },
        mkdir = { 0, 0 },
        scandir = { 0, 0 },
        scandir_next = { 0, 0 },
        fsync = { 1, 0 },
        close = { 1, 1 },
        rmdir = { 0, 0 },
      }
      for _, operation in ipairs(operation_names) do
        local expected = expected_counts[operation]
        expect_path_counter(
          v71_row,
          operation .. " calls",
          v71_row.first_activity.calls[operation],
          expected[1],
          expected[2]
        )
        expect_path_counter(
          v71_row,
          operation .. " native delegations",
          v71_row.first_activity.delegates[operation],
          expected[1],
          expected[2]
        )
        if v71_row.release_start then
          expect_path_counter(
            v71_row,
            operation .. " setup-reset calls",
            v71_row.release_start.calls[operation],
            0,
            0
          )
          expect_path_counter(
            v71_row,
            operation .. " setup-reset delegations",
            v71_row.release_start.delegates[operation],
            0,
            0
          )
        end
      end
      expect_count(v71_row, "UID calls", v71_row.first_activity.uid_calls, 0)
      expect_count(v71_row, "UID native delegations", v71_row.first_activity.uid_delegates, 0)
      expect_count(
        v71_row,
        "UID unexpected arguments",
        v71_row.first_activity.uid_unexpected_arguments,
        0
      )
      if not v71_row.release_start then
        add_failure(v71_row, "release-start telemetry was not captured")
      elseif
        #v71_row.release_start.events ~= 0
        or next(v71_row.release_start.native_results) ~= nil
        or #v71_row.release_start.post_delegation ~= 0
        or v71_row.release_start.failure_injection_count ~= 0
        or #v71_row.release_start.failure_payloads ~= 0
        or v71_row.release_start.drift_count ~= 0
        or v71_row.release_start.nondelegating_rmdir_count ~= 0
        or v71_row.release_start.physical_closes ~= 0
        or v71_row.release_start.uid_calls ~= 0
      then
        add_failure(v71_row, "replacement setup contaminated release telemetry")
      end

      local state_fstat = first_result(v71_row.first_activity, "fstat", "state", 1)
      local initial_lstat = first_result(v71_row.first_activity, "lstat", "lock", 1)
      local lock_fstat = first_result(v71_row.first_activity, "fstat", "lock", 1)
      local realpath = first_result(v71_row.first_activity, "realpath", "lock", 1)
      local final_lstat = first_result(v71_row.first_activity, "lstat", "lock", 2)
      local lock_close = first_result(v71_row.first_activity, "close", "lock", 1)
      local state_fsync = first_result(v71_row.first_activity, "fsync", "state", 1)
      local state_close = first_result(v71_row.first_activity, "close", "state", 1)
      if
        not state_fstat
        or not state_fstat.exists
        or not same_identity(state_fstat.identity, v71_row.state_identity)
      then
        add_failure(v71_row, "retained state fd did not observe the acquired state identity")
      end
      if
        not initial_lstat
        or not initial_lstat.exists
        or initial_lstat.enoent
        or not same_identity(initial_lstat.identity, v71_row.fixed_before.identity)
      then
        add_failure(v71_row, "L1 did not natively observe the installed replacement")
      end
      if
        not lock_fstat
        or not lock_fstat.exists
        or not same_identity(lock_fstat.identity, v71_row.lock_identity)
      then
        add_failure(v71_row, "retained lock fd did not observe the retired acquired lock")
      end
      local expected_realpath = spec.kind == "directory" and v71_row.lock_path
        or v71_row.target_path
      if not realpath or realpath.path ~= expected_realpath then
        add_failure(v71_row, "delegated realpath did not prove the exact replacement target")
      end
      if
        not final_lstat
        or not final_lstat.exists
        or final_lstat.enoent
        or not same_identity(final_lstat.identity, v71_row.fixed_before.identity)
      then
        add_failure(v71_row, "L2 did not natively observe the installed replacement")
      end
      if not lock_close or lock_close.closed ~= true then
        add_failure(v71_row, "retained lock fd was not physically closed")
      end
      if not state_fsync or state_fsync.synced ~= true then
        add_failure(v71_row, "state root did not receive one native synchronization attempt")
      end
      if not state_close or state_close.closed ~= true then
        add_failure(v71_row, "retained state fd was not physically closed last")
      end
      if v71_row.first_activity.native_results.rmdir ~= nil then
        add_failure(v71_row, "replacement removal or absence proof unexpectedly occurred")
      end
      if
        v71_row.first_activity.failure_injection_count ~= 0
        or #v71_row.first_activity.failure_payloads ~= 0
        or v71_row.first_activity.drift_count ~= 0
        or v71_row.first_activity.nondelegating_rmdir_count ~= 0
        or #v71_row.first_activity.post_delegation ~= 0
      then
        add_failure(v71_row, "an unrelated release injection or drift occurred")
      end
      if
        v71_row.swap.rename_calls ~= 2
        or v71_row.swap.rename_successes ~= 2
        or v71_row.swap.completed ~= true
      then
        add_failure(v71_row, "pre-release replacement did not complete two exact renames")
      end
    end

    local function validate_v71_state(v71_row, spec)
      if not v71_row.first_activity or not v71_row.pre_release_filesystem then
        add_failure(v71_row, "SWAP state evidence was not captured")
        return
      end
      local filesystem = v71_row.first_activity.filesystem
      if
        not v71_snapshots_ok(filesystem)
        or not v71_snapshots_ok(v71_row.pre_release_filesystem)
      then
        add_failure(v71_row, "complete first-result or pre-release SWAP snapshot was unavailable")
      else
        local final_state_root = filesystem.state.value[1]
        local final_retired_root = filesystem.retired.value[1]
        local final_fixed_root = filesystem.lock.value[1]
        if
          not vim.deep_equal(filesystem, v71_row.pre_release_filesystem)
          or not vim.deep_equal(filesystem.state.value, v71_row.state_before)
        then
          add_failure(v71_row, "complete SWAP filesystem changed during first release")
        end
        if
          not final_state_root
          or not same_identity(identity(final_state_root), v71_row.state_identity)
          or final_state_root.mode ~= 448
          or final_state_root.uid ~= native.uid()
        then
          add_failure(v71_row, "state-root identity or private metadata changed")
        end
        if not exact_v71_state_projection(filesystem.state.value, spec) then
          add_failure(v71_row, "SWAP state-root projection had a missing or extra sibling")
        end
        if
          not final_retired_root
          or not same_identity(identity(final_retired_root), v71_row.lock_identity)
          or not vim.deep_equal(filesystem.retired.value, v71_row.lock_before)
        then
          add_failure(v71_row, "SWAP retired path did not preserve the acquired lock")
        end
        if
          not final_fixed_root
          or not same_identity(identity(final_fixed_root), v71_row.staged_replacement.identity)
          or not vim.deep_equal(filesystem.lock.value, v71_row.staged_replacement.snapshot)
          or same_identity(identity(final_fixed_root), v71_row.lock_identity)
        then
          add_failure(v71_row, "SWAP fixed path did not preserve the distinct replacement")
        end
        if not vim.deep_equal(filesystem.staging.value, ABS) then
          add_failure(v71_row, "SWAP staging path was not absent")
        end
        if not vim.deep_equal(filesystem.reviews.value, v71_row.reviews_before) then
          add_failure(v71_row, "content-aware reviews snapshot changed during release")
        end
        if spec.kind == "directory" then
          if
            final_fixed_root.type ~= "directory"
            or final_fixed_root.mode ~= 448
            or final_fixed_root.uid ~= native.uid()
            or final_fixed_root.dev ~= v71_row.state_identity.dev
          then
            add_failure(v71_row, "installed directory replacement lost private metadata")
          end
        else
          local final_target_root = filesystem.target and filesystem.target.value[1]
          if
            final_fixed_root.type ~= "link"
            or final_fixed_root.target ~= v71_row.target_path
            or final_fixed_root.dev ~= v71_row.state_identity.dev
            or not final_target_root
            or not same_identity(identity(final_target_root), v71_row.target_before.identity)
            or not vim.deep_equal(filesystem.target.value, v71_row.target_before.snapshot)
            or final_target_root.type ~= "directory"
            or final_target_root.mode ~= 448
            or final_target_root.uid ~= native.uid()
          then
            add_failure(v71_row, "installed symlink or exact private target changed")
          end
        end
      end

      local acquired_counts = { state = 0, lock = 0, unexpected = 0 }
      for _, lifetime in ipairs(v71_row.acquired_lifetimes or {}) do
        acquired_counts[lifetime.category] = acquired_counts[lifetime.category] + 1
        if
          lifetime.generation ~= 1
          or lifetime.active ~= true
          or lifetime.release_close_attempts ~= 0
          or lifetime.release_physical_closes ~= 0
        then
          add_failure(v71_row, "pre-release acquired generation state was not exact")
        end
      end
      expect_count(v71_row, "acquired state generations", acquired_counts.state, 1)
      expect_count(v71_row, "acquired lock generations", acquired_counts.lock, 1)
      expect_count(v71_row, "acquired unexpected generations", acquired_counts.unexpected, 0)

      local lifetime_counts = { state = 0, lock = 0, unexpected = 0 }
      for _, lifetime in ipairs(v71_row.first_activity.lifetimes) do
        lifetime_counts[lifetime.category] = lifetime_counts[lifetime.category] + 1
        if lifetime.generation ~= 1 then
          add_failure(v71_row, "owned descriptor generation was not one")
        end
        if lifetime.release_close_attempts ~= 1 then
          add_failure(v71_row, "owned generation did not receive exactly one release close")
        end
        if lifetime.release_physical_closes ~= 1 or lifetime.active then
          add_failure(v71_row, "owned generation was not physically closed exactly once")
        end
      end
      expect_count(v71_row, "state descriptor generations", lifetime_counts.state, 1)
      expect_count(v71_row, "lock descriptor generations", lifetime_counts.lock, 1)
      expect_count(v71_row, "unexpected descriptor generations", lifetime_counts.unexpected, 0)
      expect_count(
        v71_row,
        "live generation reuse",
        v71_row.first_activity.live_generation_reuse,
        0
      )
      expect_count(v71_row, "integer-fd aliases", v71_row.first_activity.integer_fd_aliases, 0)
      expect_count(
        v71_row,
        "unowned close attempts",
        v71_row.first_activity.unowned_close_attempts,
        0
      )
      expect_count(
        v71_row,
        "extra physical closes",
        v71_row.first_activity.extra_physical_closes,
        0
      )
      expect_count(v71_row, "physical closes", v71_row.first_activity.physical_closes, 2)
      expect_count(v71_row, "rescue calls", v71_row.first_activity.rescue_count, 0)
      expect_count(v71_row, "fallback release calls", v71_row.first_activity.fallback_calls, 0)
      if
        v71_row.first_activity.failure_injection_native_ok ~= true
        or v71_row.first_activity.drift_native_ok ~= true
      then
        add_failure(v71_row, "zero-injection native proof state was not exact")
      end
    end

    local function finish_v71(v71_row, spec, protected_ok, protected_error)
      if not protected_ok then
        table.insert(v71_row.visible_results, protected_error)
        add_failure(v71_row, "protected " .. spec.key .. " exercise did not complete")
      end

      local all_closed = true
      if v71_row.telemetry then
        v71_row.telemetry.phase = "teardown"
        for _, lifetime in ipairs(v71_row.telemetry.lifetimes) do
          if lifetime.active then
            v71_row.telemetry.rescue_count = v71_row.telemetry.rescue_count + 1
            add_failure(v71_row, "an exact live owned generation required rescue")
            local current = v71_row.telemetry.active_by_fd[lifetime.fd]
            if current == lifetime and current.generation == lifetime.generation then
              local rescue_ok, rescued = pcall(native.close, lifetime.fd)
              if rescue_ok and rescued == true then
                lifetime.active = false
                v71_row.telemetry.active_by_fd[lifetime.fd] = nil
              end
            end
          end
          if lifetime.active then
            all_closed = false
          end
        end
        if v71_row.telemetry.rescue_count ~= 0 then
          add_failure(v71_row, "descriptor rescue count was not zero")
        end
        if v71_row.telemetry.fallback_calls ~= 0 then
          add_failure(v71_row, "release was retried during fallback or teardown")
        end
        if v71_row.telemetry.extra_physical_closes ~= 0 then
          add_failure(v71_row, "an extra descriptor was physically closed")
        end
      end

      if v71_row.external_release_calls ~= 3 then
        add_failure(v71_row, "external release-call count was not three")
      end
      if #v71_row.captures ~= v71_row.external_release_calls then
        add_failure(v71_row, "release capture count did not match external release calls")
      end

      if v71_row.state_root and all_closed then
        local removed = vim.fn.delete(v71_row.state_root, "rf")
        if removed ~= 0 then
          add_failure(v71_row, "exact private row-root teardown failed")
        end
        local stat, stat_error, stat_code = native.lstat(v71_row.state_root)
        if not is_enoent(stat, stat_error, stat_code) then
          add_failure(v71_row, "exact private row-root absence was not proven")
        end
      elseif v71_row.state_root then
        add_failure(v71_row, "private row root was retained because a descriptor remained live")
      end

      local first_kind = "missing"
      if v71_row.first_capture then
        if
          v71_row.first_capture.ok
          and v71_row.first_capture.tuple[1] == nil
          and v71_row.first_capture.tuple[2] == RVL
        then
          first_kind = "RVL"
        elseif
          v71_row.first_capture.ok
          and v71_row.first_capture.tuple[1] == true
          and v71_row.first_capture.tuple[2] == nil
        then
          first_kind = "success"
        elseif v71_row.first_capture.ok then
          first_kind = "other"
        else
          first_kind = "raised"
        end
      end
      local outcome = "missing"
      if
        v71_row.first_activity
        and v71_row.first_activity.filesystem
        and v71_snapshots_ok(v71_row.first_activity.filesystem)
      then
        local filesystem = v71_row.first_activity.filesystem
        if
          vim.deep_equal(filesystem.retired.value, v71_row.lock_before)
          and vim.deep_equal(filesystem.lock.value, v71_row.staged_replacement.snapshot)
          and vim.deep_equal(filesystem.staging.value, ABS)
          and (
            spec.kind == "directory"
            or vim.deep_equal(filesystem.target.value, v71_row.target_before.snapshot)
          )
        then
          outcome = "SWAP"
        else
          outcome = "OTHER"
        end
      end
      local events = v71_row.first_activity and table.concat(v71_row.first_activity.events, ",")
        or "none"
      v71_row.observation = string.format(
        "%s first=%s repeat-tuple=%s repeat-activity=%s swap=%d/%d outcome=%s rescue=%d events=%s",
        spec.key,
        first_kind,
        tostring(v71_row.repeat_tuples_equal),
        tostring(v71_row.repeat_activity_stable),
        v71_row.swap and v71_row.swap.rename_calls or 0,
        v71_row.swap and v71_row.swap.rename_successes or 0,
        outcome,
        v71_row.telemetry and v71_row.telemetry.rescue_count or 0,
        events
      )
      if #v71_row.observation > 1024 then
        add_failure(v71_row, spec.key .. " observation was not bounded")
      end
      table.insert(observations, v71_row.observation)

      for _, result_text in ipairs(v71_row.visible_results) do
        if #result_text > 1024 then
          add_failure(v71_row, "a public or protected result was not bounded")
        end
      end
      local diagnostic_visible = copy(v71_row.visible_results)
      vim.list_extend(diagnostic_visible, v71_row.failures)
      table.insert(diagnostic_visible, v71_row.observation)
      local forbidden = {
        shared_payload,
        fixed_private_path,
        v4_fixed_private_path,
        v0_fixed_private_path,
        c1_fixed_private_path,
        o2_fixed_private_path,
        v1_fixed_private_path,
        v2_fixed_private_path,
      }
      vim.list_extend(forbidden, v71_row.private_paths or {})
      local leak_found = false
      for _, visible in ipairs(diagnostic_visible) do
        for _, needle in ipairs(forbidden) do
          if type(needle) == "string" and #needle > 0 and visible:find(needle, 1, true) then
            leak_found = true
          end
        end
      end
      if leak_found then
        add_failure(v71_row, "a shared payload or private fixture path reached diagnostics")
      end

      for _, detail in ipairs(v71_row.failures) do
        table.insert(failures, v71_row.label .. " " .. detail)
      end
    end

    local v1_spec = {
      key = "V1",
      label = "V1 pre-release private-directory replacement",
      kind = "directory",
      retired_name = ".cycle-2e-e2-v1-retired",
      staging_name = ".cycle-2e-e2-v1-staging",
    }
    local v2_spec = {
      key = "V2",
      label = "V2 pre-release symlink replacement",
      kind = "symlink",
      retired_name = ".cycle-2e-e2-v2-retired",
      staging_name = ".cycle-2e-e2-v2-staging",
      target_name = ".cycle-2e-e2-v2-target",
    }

    v1_executed_rows = v1_executed_rows + 1
    local v1_row = {
      label = v1_spec.label,
      failures = {},
      captures = {},
      visible_results = {},
      private_paths = {},
      external_release_calls = 0,
      repeat_tuples_equal = false,
      repeat_activity_stable = false,
    }
    local v1_protected_ok, v1_protected_error = xpcall(function()
      exercise_v71(v1_row, v1_spec)
      validate_v71_release(v1_row, v1_spec)
      validate_v71_state(v1_row, v1_spec)
    end, function()
      return "protected V1 exercise failed"
    end)
    finish_v71(v1_row, v1_spec, v1_protected_ok, v1_protected_error)

    v2_executed_rows = v2_executed_rows + 1
    local v2_row = {
      label = v2_spec.label,
      failures = {},
      captures = {},
      visible_results = {},
      private_paths = {},
      external_release_calls = 0,
      repeat_tuples_equal = false,
      repeat_activity_stable = false,
    }
    local v2_protected_ok, v2_protected_error = xpcall(function()
      exercise_v71(v2_row, v2_spec)
      validate_v71_release(v2_row, v2_spec)
      validate_v71_state(v2_row, v2_spec)
    end, function()
      return "protected V2 exercise failed"
    end)
    finish_v71(v2_row, v2_spec, v2_protected_ok, v2_protected_error)

    if v1_executed_rows ~= 1 then
      table.insert(failures, "Cycle 2E E2 V1 did not execute exactly once")
    end
    if v2_executed_rows ~= 1 then
      table.insert(failures, "Cycle 2E E2 V2 did not execute exactly once")
    end
    if not v1_row.observation or observations[6] ~= v1_row.observation then
      table.insert(failures, "Cycle 2E E2 V1 did not append one bounded observation")
    end
    if not v2_row.observation or observations[7] ~= v2_row.observation then
      table.insert(failures, "Cycle 2E E2 V2 did not append one bounded observation")
    end

    local RVA = "baseline serialization release failed: verify-lock-absent (EIO)"
    local O0_ERROR = table.concat({ RCL, RVA, RF, RCS }, "; ")
    local O1_ERROR = table.concat({ RLL, RCL, RF, RCS }, "; ")
    local c0_fixed_private_path = "/fixed/private/cycle-2e-e2-c0"
    local c2_fixed_private_path = "/fixed/private/cycle-2e-e2-c2"
    local c3_fixed_private_path = "/fixed/private/cycle-2e-e2-c3"
    local c4_fixed_private_path = "/fixed/private/cycle-2e-e2-c4"
    local o0_fixed_private_path = "/fixed/private/cycle-2e-e2-o0"
    local o1_fixed_private_path = "/fixed/private/cycle-2e-e2-o1"
    local c0_executed_rows = 0
    local c2_executed_rows = 0
    local c3_executed_rows = 0
    local c4_executed_rows = 0
    local o0_executed_rows = 0
    local o1_executed_rows = 0

    local function v73_filesystem_snapshot(v73_row)
      return {
        state = protected_snapshot(v73_row.state_root),
        lock = protected_snapshot(v73_row.lock_path),
        reviews = protected_snapshot(v73_row.reviews_path),
      }
    end

    local function v73_snapshots_ok(filesystem)
      return filesystem.state.ok and filesystem.lock.ok and filesystem.reviews.ok
    end

    local function exact_v73_state_projection(snapshot, lock_present)
      local expected = {
        ["."] = true,
        reviews = true,
        ["reviews/control.bin"] = true,
        ["reviews/control-link"] = true,
      }
      if lock_present then
        expected[lock_name] = true
      end
      local observed = {}
      for _, entry in ipairs(snapshot) do
        if not expected[entry.path] or observed[entry.path] then
          return false
        end
        observed[entry.path] = true
      end
      for path in pairs(expected) do
        if not observed[path] then
          return false
        end
      end
      return true
    end

    local function v73_telemetry_snapshot(telemetry)
      return {
        calls = copy(telemetry.calls),
        delegates = copy(telemetry.delegates),
        events = copy(telemetry.events),
        native_results = copy(telemetry.native_results),
        post_delegation = copy(telemetry.post_delegation),
        injection_count = telemetry.injection_count,
        injection_native_ok = telemetry.injection_native_ok,
        injection_payloads = copy(telemetry.injection_payloads),
        l2_armed = telemetry.l2_armed,
        realpath_arm_count = telemetry.realpath_arm_count,
        lstat_nontrigger_count = telemetry.lstat_nontrigger_count,
        lstat_nontrigger_enoent = telemetry.lstat_nontrigger_enoent,
        lifetimes = lifetime_snapshot(telemetry),
        generations = copy(telemetry.generations),
        live_generation_reuse = telemetry.live_generation_reuse,
        integer_fd_aliases = telemetry.integer_fd_aliases,
        unowned_close_attempts = telemetry.unowned_close_attempts,
        extra_physical_closes = telemetry.extra_physical_closes,
        physical_closes = telemetry.physical_closes,
        uid_calls = telemetry.uid_calls,
        uid_delegates = telemetry.uid_delegates,
        uid_unexpected_arguments = telemetry.uid_unexpected_arguments,
        rescue_count = telemetry.rescue_count,
        fallback_calls = telemetry.fallback_calls,
      }
    end

    local function v73_instrumented_dependencies(v73_row, spec)
      local telemetry = {
        phase = "acquisition",
        calls = new_operation_counters(),
        delegates = new_operation_counters(),
        events = {},
        native_results = {},
        post_delegation = {},
        injection_count = 0,
        injection_native_ok = true,
        injection_payloads = {},
        l2_armed = false,
        realpath_arm_count = 0,
        lstat_nontrigger_count = 0,
        lstat_nontrigger_enoent = false,
        lifetimes = {},
        generations = {},
        active_by_fd = {},
        latest_by_fd = {},
        scanner_categories = {},
        live_generation_reuse = 0,
        integer_fd_aliases = 0,
        unowned_close_attempts = 0,
        extra_physical_closes = 0,
        physical_closes = 0,
        uid_calls = 0,
        uid_delegates = 0,
        uid_unexpected_arguments = 0,
        rescue_count = 0,
        fallback_calls = 0,
      }
      local dependencies = {}

      local function descriptor(fd)
        local lifetime = telemetry.active_by_fd[fd] or telemetry.latest_by_fd[fd]
        if lifetime then
          return lifetime.category, lifetime.generation, lifetime
        end
        return "unexpected", 0, nil
      end

      local function call(operation, category, generation)
        if telemetry.phase ~= "release" then
          return 0
        end
        local counter = telemetry.calls[operation]
        counter[category] = counter[category] + 1
        local ordinal = counter[category]
        table.insert(
          telemetry.events,
          string.format("%s:%s:g%d:%d", operation, category, generation or 0, ordinal)
        )
        return ordinal
      end

      local function delegate(operation, category)
        if telemetry.phase == "release" then
          telemetry.delegates[operation][category] = telemetry.delegates[operation][category] + 1
        end
      end

      local function result(operation, category, value)
        if telemetry.phase ~= "release" then
          return
        end
        telemetry.native_results[operation] = telemetry.native_results[operation] or {}
        telemetry.native_results[operation][category] = telemetry.native_results[operation][category]
          or {}
        table.insert(telemetry.native_results[operation][category], value)
      end

      local function inject(operation, category, generation, ordinal, native_ok)
        telemetry.injection_count = telemetry.injection_count + 1
        telemetry.injection_native_ok = telemetry.injection_native_ok and native_ok
        table.insert(telemetry.injection_payloads, shared_payload)
        table.insert(
          telemetry.post_delegation,
          string.format(
            "native:%s:%s:g%d:%d:%s",
            operation,
            category,
            generation,
            ordinal,
            tostring(native_ok)
          )
        )
        table.insert(
          telemetry.post_delegation,
          string.format("inject:%s:%s:g%d:%d", operation, category, generation, ordinal)
        )
      end

      dependencies.uid = function(...)
        if telemetry.phase == "release" then
          telemetry.uid_calls = telemetry.uid_calls + 1
          if select("#", ...) ~= 0 then
            telemetry.uid_unexpected_arguments = telemetry.uid_unexpected_arguments + 1
          end
          telemetry.uid_delegates = telemetry.uid_delegates + 1
        end
        return native.uid(...)
      end

      dependencies.lstat = function(path)
        local category = path_category(path, v73_row)
        local ordinal = call("lstat", category, 0)
        delegate("lstat", category)
        local stat, stat_error, stat_code = native.lstat(path)
        local native_result = {
          exists = stat ~= nil,
          identity = identity(stat),
          enoent = is_enoent(stat, stat_error, stat_code),
          code = stat_code,
        }
        result("lstat", category, native_result)
        if telemetry.phase == "release" and category == "lock" then
          if spec.inject_l2 and ordinal == 2 and telemetry.l2_armed then
            local native_ok = stat ~= nil
              and stat.type == "directory"
              and same_identity(identity(stat), v73_row.lock_identity)
            if native_ok then
              inject("lstat", category, 0, ordinal, true)
              return nil, shared_payload, "EIO"
            end
            telemetry.lstat_nontrigger_count = telemetry.lstat_nontrigger_count + 1
            telemetry.lstat_nontrigger_enoent = native_result.enoent
          elseif spec.inject_absence and ordinal == 3 then
            if native_result.enoent then
              inject("lstat", category, 0, ordinal, true)
              return nil, shared_payload, "EIO"
            end
            telemetry.lstat_nontrigger_count = telemetry.lstat_nontrigger_count + 1
            telemetry.lstat_nontrigger_enoent = native_result.enoent
          elseif spec.inject_absence and ordinal == 2 and native_result.enoent then
            telemetry.lstat_nontrigger_count = telemetry.lstat_nontrigger_count + 1
            telemetry.lstat_nontrigger_enoent = true
          end
        end
        return stat, stat_error, stat_code
      end

      dependencies.realpath = function(path)
        local category = path_category(path, v73_row)
        local ordinal = call("realpath", category, 0)
        delegate("realpath", category)
        local physical, realpath_error, realpath_code = native.realpath(path)
        result("realpath", category, {
          path = physical,
          code = realpath_code,
        })
        if
          telemetry.phase == "release"
          and spec.inject_l2
          and category == "lock"
          and ordinal == 1
          and physical == v73_row.lock_path
        then
          telemetry.l2_armed = true
          telemetry.realpath_arm_count = telemetry.realpath_arm_count + 1
        end
        return physical, realpath_error, realpath_code
      end

      dependencies.open = function(path, flags, mode)
        local category = path_category(path, v73_row)
        call("open", category, 0)
        delegate("open", category)
        local fd, open_error, open_code = native.open(path, flags, mode)
        if fd ~= nil then
          local prior = telemetry.active_by_fd[fd]
          if prior and prior.active then
            telemetry.live_generation_reuse = telemetry.live_generation_reuse + 1
            telemetry.integer_fd_aliases = telemetry.integer_fd_aliases + 1
          end
          local generation = (telemetry.generations[fd] or 0) + 1
          telemetry.generations[fd] = generation
          local lifetime = {
            fd = fd,
            generation = generation,
            category = category,
            active = true,
            release_close_attempts = 0,
            release_physical_closes = 0,
          }
          table.insert(telemetry.lifetimes, lifetime)
          telemetry.active_by_fd[fd] = lifetime
          telemetry.latest_by_fd[fd] = lifetime
        end
        return fd, open_error, open_code
      end

      dependencies.fstat = function(fd)
        local category, generation = descriptor(fd)
        call("fstat", category, generation)
        delegate("fstat", category)
        local stat, stat_error, stat_code = native.fstat(fd)
        result("fstat", category, {
          exists = stat ~= nil,
          identity = identity(stat),
          code = stat_code,
        })
        return stat, stat_error, stat_code
      end

      dependencies.mkdir = function(path, mode)
        local category = path_category(path, v73_row)
        call("mkdir", category, 0)
        delegate("mkdir", category)
        return native.mkdir(path, mode)
      end

      dependencies.scandir = function(path)
        local category = path_category(path, v73_row)
        call("scandir", category, 0)
        delegate("scandir", category)
        local scanner, scan_error, scan_code = native.scandir(path)
        if scanner ~= nil then
          telemetry.scanner_categories[scanner] = category
        end
        return scanner, scan_error, scan_code
      end

      dependencies.scandir_next = function(scanner)
        local category = telemetry.scanner_categories[scanner] or "unexpected"
        call("scandir_next", category, 0)
        delegate("scandir_next", category)
        return native.scandir_next(scanner)
      end

      dependencies.fsync = function(fd)
        local category, generation = descriptor(fd)
        local ordinal = call("fsync", category, generation)
        delegate("fsync", category)
        local synced, sync_error, sync_code = native.fsync(fd)
        result("fsync", category, {
          synced = synced,
          code = sync_code,
        })
        if
          telemetry.phase == "release"
          and spec.inject_fsync
          and category == "state"
          and ordinal == 1
        then
          inject("fsync", category, generation, ordinal, synced == true)
          return nil, shared_payload, "EIO"
        end
        return synced, sync_error, sync_code
      end

      dependencies.close = function(fd)
        local category, generation, lifetime = descriptor(fd)
        local ordinal = call("close", category, generation)
        if telemetry.phase == "release" then
          if lifetime then
            lifetime.release_close_attempts = lifetime.release_close_attempts + 1
          else
            telemetry.unowned_close_attempts = telemetry.unowned_close_attempts + 1
          end
        end
        delegate("close", category)
        local close_ok, closed, close_error, close_code = pcall(native.close, fd)
        if not close_ok then
          closed = nil
          close_error = "native close failed"
          close_code = "UNKNOWN"
        end
        if closed == true then
          if lifetime and lifetime.active and telemetry.active_by_fd[fd] == lifetime then
            lifetime.active = false
            telemetry.active_by_fd[fd] = nil
            if telemetry.phase == "release" then
              lifetime.release_physical_closes = lifetime.release_physical_closes + 1
              telemetry.physical_closes = telemetry.physical_closes + 1
            end
          elseif telemetry.phase == "release" then
            telemetry.extra_physical_closes = telemetry.extra_physical_closes + 1
          end
        end
        result("close", category, {
          closed = closed,
          code = close_code,
        })
        local selected = ordinal == 1
          and (
            (category == "lock" and spec.inject_close_lock)
            or (category == "state" and spec.inject_close_state)
          )
        if telemetry.phase == "release" and selected then
          inject("close", category, generation, ordinal, close_ok and closed == true)
          return nil, shared_payload, "EIO"
        end
        return closed, close_error, close_code
      end

      dependencies.rmdir = function(path)
        local category = path_category(path, v73_row)
        call("rmdir", category, 0)
        delegate("rmdir", category)
        local removed, remove_error, remove_code = native.rmdir(path)
        result("rmdir", category, {
          removed = removed,
          code = remove_code,
        })
        return removed, remove_error, remove_code
      end

      return dependencies, telemetry
    end

    local function v73_begin_release(telemetry)
      telemetry.calls = new_operation_counters()
      telemetry.delegates = new_operation_counters()
      telemetry.events = {}
      telemetry.native_results = {}
      telemetry.post_delegation = {}
      telemetry.injection_count = 0
      telemetry.injection_native_ok = true
      telemetry.injection_payloads = {}
      telemetry.l2_armed = false
      telemetry.realpath_arm_count = 0
      telemetry.lstat_nontrigger_count = 0
      telemetry.lstat_nontrigger_enoent = false
      telemetry.live_generation_reuse = 0
      telemetry.integer_fd_aliases = 0
      telemetry.unowned_close_attempts = 0
      telemetry.extra_physical_closes = 0
      telemetry.physical_closes = 0
      telemetry.uid_calls = 0
      telemetry.uid_delegates = 0
      telemetry.uid_unexpected_arguments = 0
      telemetry.rescue_count = 0
      telemetry.fallback_calls = 0
      for _, lifetime in ipairs(telemetry.lifetimes) do
        lifetime.release_close_attempts = 0
        lifetime.release_physical_closes = 0
      end
      telemetry.phase = "release"
    end

    local function v73_complete_snapshot(v73_row)
      local snapshot = v73_telemetry_snapshot(v73_row.telemetry)
      snapshot.filesystem = v73_filesystem_snapshot(v73_row)
      return snapshot
    end

    local function prepare_v73_row(v73_row, spec)
      local suffix = spec.key:lower()
      local control_bytes = "cycle-2e-e2-" .. suffix .. "-control\n"
      v73_row.state_root = make_root("serialization-release-e2-" .. suffix)
      v73_row.lock_path = vim.fs.joinpath(v73_row.state_root, lock_name)
      v73_row.reviews_path = vim.fs.joinpath(v73_row.state_root, "reviews")
      v73_row.control_path = vim.fs.joinpath(v73_row.reviews_path, "control.bin")
      v73_row.link_path = vim.fs.joinpath(v73_row.reviews_path, "control-link")
      v73_row.private_paths = {
        v73_row.state_root,
        v73_row.lock_path,
        v73_row.reviews_path,
        v73_row.control_path,
        v73_row.link_path,
      }

      if #shared_payload <= 8192 then
        add_failure(v73_row, "shared path-bearing diagnostic payload was not longer than 8 KiB")
      end
      if
        not contained_path(v73_row.state_root, v73_row.lock_path)
        or not contained_path(v73_row.state_root, v73_row.reviews_path)
      then
        add_failure(v73_row, "a " .. spec.key .. " setup path escaped the exact private row root")
      end

      assert(vim.fn.mkdir(v73_row.reviews_path, "p", 448) == 1, spec.key .. " reviews setup failed")
      assert(vim.uv.fs_chmod(v73_row.reviews_path, 448), spec.key .. " reviews chmod failed")
      write_file(v73_row.control_path, control_bytes, 384)
      assert(
        native.symlink("control.bin", v73_row.link_path),
        spec.key .. " reviews symlink setup failed"
      )
      v73_row.reviews_before = snapshot_tree(v73_row.reviews_path)

      local reviews_root_exact = false
      local control_exact = false
      local link_exact = false
      for _, entry in ipairs(v73_row.reviews_before) do
        if
          entry.path == "."
          and entry.type == "directory"
          and entry.mode == 448
          and entry.uid == native.uid()
        then
          reviews_root_exact = true
        elseif
          entry.path == "control.bin"
          and entry.type == "file"
          and entry.mode == 384
          and entry.uid == native.uid()
          and entry.sha256 == vim.fn.sha256(control_bytes)
        then
          control_exact = true
        elseif
          entry.path == "control-link"
          and entry.type == "link"
          and entry.target == "control.bin"
        then
          link_exact = true
        end
      end
      if not reviews_root_exact or not control_exact or not link_exact then
        add_failure(
          v73_row,
          "reviews metadata, regular-file digest, or symlink target was not exact"
        )
      end

      local state_stat, state_error = native.lstat(v73_row.state_root)
      assert(state_stat, tostring(state_error))
      v73_row.state_identity = identity(state_stat)
      if
        v73_row.state_identity.type ~= "directory"
        or v73_row.state_identity.mode ~= 448
        or v73_row.state_identity.uid ~= native.uid()
      then
        add_failure(v73_row, "state root was not an exact current-user mode-0700 directory")
      end

      local dependencies, telemetry = v73_instrumented_dependencies(v73_row, spec)
      v73_row.telemetry = telemetry
      local lease, acquire_error = serialization.acquire(v73_row.state_root, dependencies)
      if not lease then
        if acquire_error ~= nil then
          table.insert(v73_row.visible_results, tostring(acquire_error))
        end
        add_failure(v73_row, "normal " .. spec.key .. " acquisition failed")
        return
      end
      if acquire_error ~= nil then
        table.insert(v73_row.visible_results, tostring(acquire_error))
        add_failure(v73_row, "normal " .. spec.key .. " acquisition returned an error")
      end
      v73_row.lease = lease
      v73_row.acquired_lifetimes = lifetime_snapshot(telemetry)

      local lock_stat, lock_error = native.lstat(v73_row.lock_path)
      assert(lock_stat, tostring(lock_error))
      v73_row.lock_identity = identity(lock_stat)
      v73_row.lock_before = snapshot_tree(v73_row.lock_path)
      local lock_root = v73_row.lock_before[1]
      if
        #v73_row.lock_before ~= 1
        or not lock_root
        or lock_root.path ~= "."
        or lock_root.type ~= "directory"
        or lock_root.mode ~= 448
        or lock_root.uid ~= native.uid()
        or lock_root.dev ~= v73_row.state_identity.dev
        or not same_identity(v73_row.lock_identity, lock_root)
      then
        add_failure(v73_row, "acquired lock was not an exact private empty directory")
      end
      if #v73_row.acquired_lifetimes ~= 2 then
        add_failure(v73_row, "acquisition did not retain exactly two descriptor generations")
      end
      if
        v73_row.acquired_lifetimes[1]
        and v73_row.acquired_lifetimes[2]
        and v73_row.acquired_lifetimes[1].fd == v73_row.acquired_lifetimes[2].fd
      then
        add_failure(v73_row, "acquired state and lock lifetimes aliased one integer fd")
      end
      v73_row.state_before = snapshot_tree(v73_row.state_root)
      if not exact_v73_state_projection(v73_row.state_before, true) then
        add_failure(v73_row, "pre-release state-root projection was not exact")
      end

      v73_begin_release(telemetry)
      v73_row.release_start = v73_telemetry_snapshot(telemetry)
    end

    local function exercise_v73(v73_row, spec)
      prepare_v73_row(v73_row, spec)
      if not v73_row.lease then
        return
      end

      v73_row.external_release_calls = v73_row.external_release_calls + 1
      v73_row.first_capture = capture_release(v73_row.lease)
      add_visible_capture(v73_row, v73_row.first_capture)
      v73_row.first_activity = v73_complete_snapshot(v73_row)

      v73_row.repeat_tuples_equal = true
      v73_row.repeat_activity_stable = true
      for _ = 1, 2 do
        v73_row.external_release_calls = v73_row.external_release_calls + 1
        local repeated = capture_release(v73_row.lease)
        add_visible_capture(v73_row, repeated)
        if not repeated.ok or not vim.deep_equal(repeated.tuple, v73_row.first_capture.tuple) then
          v73_row.repeat_tuples_equal = false
        end
        local repeated_activity = v73_complete_snapshot(v73_row)
        if not vim.deep_equal(repeated_activity, v73_row.first_activity) then
          v73_row.repeat_activity_stable = false
        end
      end

      if not v73_row.repeat_tuples_equal then
        add_failure(v73_row, "cached releases did not repeat the complete nil-sensitive pair")
      end
      if not v73_row.repeat_activity_stable then
        add_failure(
          v73_row,
          "cached releases changed dependency, descriptor, or filesystem activity"
        )
      end
    end

    local function validate_v73_release(v73_row, spec)
      if not v73_row.first_capture then
        add_failure(v73_row, "first release result was not captured")
        return
      end
      local expected_tuple = { n = 2, [2] = spec.expected_error }
      if not v73_row.first_capture.ok then
        add_failure(v73_row, "first release raised")
      elseif not vim.deep_equal(v73_row.first_capture.tuple, expected_tuple) then
        add_failure(
          v73_row,
          "first release did not return the exact bounded " .. spec.key .. " pair"
        )
      end
      if not v73_row.first_activity then
        add_failure(v73_row, "first release activity was not captured")
        return
      end

      if not vim.deep_equal(v73_row.first_activity.events, spec.expected_events) then
        add_failure(v73_row, "release event vector was not exact " .. spec.vector)
      end

      local expected_calls = {
        lstat = { 0, spec.validation_stop and 2 or 3 },
        realpath = { 0, 1 },
        open = { 0, 0 },
        fstat = { 1, 1 },
        mkdir = { 0, 0 },
        scandir = { 0, 0 },
        scandir_next = { 0, 0 },
        fsync = { 1, 0 },
        close = { 1, 1 },
        rmdir = { 0, spec.validation_stop and 0 or 1 },
      }
      for _, operation in ipairs(operation_names) do
        local expected = expected_calls[operation]
        expect_path_counter(
          v73_row,
          operation .. " calls",
          v73_row.first_activity.calls[operation],
          expected[1],
          expected[2]
        )
        expect_path_counter(
          v73_row,
          operation .. " native delegations",
          v73_row.first_activity.delegates[operation],
          expected[1],
          expected[2]
        )
      end
      expect_count(v73_row, "UID calls", v73_row.first_activity.uid_calls, 0)
      expect_count(v73_row, "UID native delegations", v73_row.first_activity.uid_delegates, 0)
      expect_count(
        v73_row,
        "UID unexpected arguments",
        v73_row.first_activity.uid_unexpected_arguments,
        0
      )

      if not v73_row.release_start then
        add_failure(v73_row, "release-start telemetry was not captured")
      else
        for _, operation in ipairs(operation_names) do
          expect_path_counter(
            v73_row,
            "release-start " .. operation .. " calls",
            v73_row.release_start.calls[operation],
            0,
            0
          )
          expect_path_counter(
            v73_row,
            "release-start " .. operation .. " native delegations",
            v73_row.release_start.delegates[operation],
            0,
            0
          )
        end
        if
          #v73_row.release_start.events ~= 0
          or next(v73_row.release_start.native_results) ~= nil
          or #v73_row.release_start.post_delegation ~= 0
          or v73_row.release_start.injection_count ~= 0
          or #v73_row.release_start.injection_payloads ~= 0
          or v73_row.release_start.l2_armed ~= false
          or v73_row.release_start.realpath_arm_count ~= 0
          or v73_row.release_start.lstat_nontrigger_count ~= 0
          or v73_row.release_start.lstat_nontrigger_enoent ~= false
          or v73_row.release_start.physical_closes ~= 0
          or v73_row.release_start.uid_calls ~= 0
          or v73_row.release_start.rescue_count ~= 0
          or v73_row.release_start.fallback_calls ~= 0
        then
          add_failure(v73_row, "fixture setup contaminated release telemetry")
        end
      end

      local state_fstat = first_result(v73_row.first_activity, "fstat", "state", 1)
      local initial_lstat = first_result(v73_row.first_activity, "lstat", "lock", 1)
      local lock_fstat = first_result(v73_row.first_activity, "fstat", "lock", 1)
      local realpath = first_result(v73_row.first_activity, "realpath", "lock", 1)
      local final_lstat = first_result(v73_row.first_activity, "lstat", "lock", 2)
      local lock_close = first_result(v73_row.first_activity, "close", "lock", 1)
      local rmdir = first_result(v73_row.first_activity, "rmdir", "lock", 1)
      local absence = first_result(v73_row.first_activity, "lstat", "lock", 3)
      local state_fsync = first_result(v73_row.first_activity, "fsync", "state", 1)
      local state_close = first_result(v73_row.first_activity, "close", "state", 1)
      if
        not state_fstat
        or not state_fstat.exists
        or not same_identity(state_fstat.identity, v73_row.state_identity)
      then
        add_failure(v73_row, "retained state fd did not observe the acquired identity")
      end
      if
        not initial_lstat
        or not initial_lstat.exists
        or initial_lstat.enoent
        or not same_identity(initial_lstat.identity, v73_row.lock_identity)
      then
        add_failure(v73_row, "L1 did not natively observe the acquired lock")
      end
      if
        not lock_fstat
        or not lock_fstat.exists
        or not same_identity(lock_fstat.identity, v73_row.lock_identity)
      then
        add_failure(v73_row, "retained lock fd did not observe the acquired lock")
      end
      if not realpath or realpath.path ~= v73_row.lock_path then
        add_failure(v73_row, "delegated realpath did not prove the exact fixed lock path")
      end
      if
        not final_lstat
        or not final_lstat.exists
        or final_lstat.enoent
        or not same_identity(final_lstat.identity, v73_row.lock_identity)
      then
        add_failure(v73_row, "L2 did not natively observe the acquired lock")
      end
      if not lock_close or lock_close.closed ~= true then
        add_failure(v73_row, "retained lock fd was not physically closed")
      end
      if spec.validation_stop then
        if rmdir or absence then
          add_failure(v73_row, "validation-stop row reached removal or absence proof")
        end
      else
        if not rmdir or rmdir.removed ~= true then
          add_failure(v73_row, "lock directory was not natively removed")
        end
        if not absence or absence.exists or not absence.enoent then
          add_failure(v73_row, "L3 did not natively prove lock absence")
        end
      end
      if not state_fsync or state_fsync.synced ~= true then
        add_failure(v73_row, "state root did not receive one native synchronization attempt")
      end
      if not state_close or state_close.closed ~= true then
        add_failure(v73_row, "retained state fd was not physically closed last")
      end

      expect_count(
        v73_row,
        "post-native injections",
        v73_row.first_activity.injection_count,
        spec.injection_count
      )
      if v73_row.first_activity.injection_native_ok ~= true then
        add_failure(v73_row, "a release injection lacked its successful native result")
      end
      if not vim.deep_equal(v73_row.first_activity.post_delegation, spec.post_delegation) then
        add_failure(v73_row, "native-result-before-injection trace was not exact")
      end
      if #v73_row.first_activity.injection_payloads ~= spec.injection_count then
        add_failure(v73_row, "release injection payload count was not exact")
      else
        for _, payload in ipairs(v73_row.first_activity.injection_payloads) do
          if payload ~= shared_payload then
            add_failure(v73_row, "a release injection did not use the shared payload")
          end
        end
      end
      expect_count(
        v73_row,
        "exact-realpath arming count",
        v73_row.first_activity.realpath_arm_count,
        spec.arm_count
      )
      if v73_row.first_activity.l2_armed ~= (spec.arm_count == 1) then
        add_failure(v73_row, "post-realpath L2 arming state was not exact")
      end
      expect_count(
        v73_row,
        "ordinal-sensitive lstat nontriggers",
        v73_row.first_activity.lstat_nontrigger_count,
        0
      )
      if v73_row.first_activity.lstat_nontrigger_enoent ~= false then
        add_failure(v73_row, "native ENOENT incorrectly qualified at the wrong ordinal")
      end
    end

    local function validate_v73_state(v73_row, spec)
      if not v73_row.first_activity then
        add_failure(v73_row, "first release activity was unavailable for state checks")
        return
      end
      local filesystem = v73_row.first_activity.filesystem
      if not v73_snapshots_ok(filesystem) then
        add_failure(v73_row, "complete first-release filesystem snapshot was unavailable")
      else
        local final_state_root = filesystem.state.value[1]
        if
          not final_state_root
          or not same_identity(identity(final_state_root), v73_row.state_identity)
          or final_state_root.type ~= "directory"
          or final_state_root.mode ~= 448
          or final_state_root.uid ~= native.uid()
        then
          add_failure(v73_row, "state-root identity or private metadata changed")
        end
        if not vim.deep_equal(filesystem.reviews.value, v73_row.reviews_before) then
          add_failure(v73_row, "content-aware reviews snapshot changed during release")
        end
        if spec.validation_stop then
          local final_lock_root = filesystem.lock.value[1]
          if
            not final_lock_root
            or not same_identity(identity(final_lock_root), v73_row.lock_identity)
            or not vim.deep_equal(filesystem.lock.value, v73_row.lock_before)
          then
            add_failure(v73_row, "KEEP lock identity or complete snapshot changed")
          end
          if not vim.deep_equal(filesystem.state.value, v73_row.state_before) then
            add_failure(v73_row, "complete KEEP state-root projection changed")
          end
          if not exact_v73_state_projection(filesystem.state.value, true) then
            add_failure(v73_row, "KEEP projection had a missing or extra sibling")
          end
        else
          if not vim.deep_equal(filesystem.lock.value, ABS) then
            add_failure(v73_row, "ABS lock snapshot was not exact")
          end
          if not exact_v73_state_projection(filesystem.state.value, false) then
            add_failure(v73_row, "ABS projection had a missing or extra sibling")
          end
        end
      end

      local acquired_counts = { state = 0, lock = 0, unexpected = 0 }
      for _, lifetime in ipairs(v73_row.acquired_lifetimes or {}) do
        acquired_counts[lifetime.category] = acquired_counts[lifetime.category] + 1
        if
          lifetime.generation ~= 1
          or lifetime.active ~= true
          or lifetime.release_close_attempts ~= 0
          or lifetime.release_physical_closes ~= 0
        then
          add_failure(v73_row, "pre-release acquired generation state was not exact")
        end
      end
      expect_count(v73_row, "acquired state generations", acquired_counts.state, 1)
      expect_count(v73_row, "acquired lock generations", acquired_counts.lock, 1)
      expect_count(v73_row, "acquired unexpected generations", acquired_counts.unexpected, 0)

      local lifetime_counts = { state = 0, lock = 0, unexpected = 0 }
      for _, lifetime in ipairs(v73_row.first_activity.lifetimes) do
        lifetime_counts[lifetime.category] = lifetime_counts[lifetime.category] + 1
        if lifetime.generation ~= 1 then
          add_failure(v73_row, "owned descriptor generation was not one")
        end
        if lifetime.release_close_attempts ~= 1 then
          add_failure(v73_row, "owned generation did not receive exactly one release close")
        end
        if lifetime.release_physical_closes ~= 1 or lifetime.active then
          add_failure(v73_row, "owned generation was not physically closed exactly once")
        end
      end
      expect_count(v73_row, "state descriptor generations", lifetime_counts.state, 1)
      expect_count(v73_row, "lock descriptor generations", lifetime_counts.lock, 1)
      expect_count(v73_row, "unexpected descriptor generations", lifetime_counts.unexpected, 0)
      expect_count(
        v73_row,
        "live generation reuse",
        v73_row.first_activity.live_generation_reuse,
        0
      )
      expect_count(v73_row, "integer-fd aliases", v73_row.first_activity.integer_fd_aliases, 0)
      expect_count(
        v73_row,
        "unowned close attempts",
        v73_row.first_activity.unowned_close_attempts,
        0
      )
      expect_count(
        v73_row,
        "extra physical closes",
        v73_row.first_activity.extra_physical_closes,
        0
      )
      expect_count(v73_row, "physical closes", v73_row.first_activity.physical_closes, 2)
      expect_count(v73_row, "rescue calls", v73_row.first_activity.rescue_count, 0)
      expect_count(v73_row, "fallback release calls", v73_row.first_activity.fallback_calls, 0)
    end

    local function finish_v73(v73_row, spec, protected_ok, protected_error)
      if not protected_ok then
        table.insert(v73_row.visible_results, protected_error)
        add_failure(v73_row, "protected " .. spec.key .. " exercise did not complete")
      end

      local all_closed = true
      if v73_row.telemetry then
        v73_row.telemetry.phase = "teardown"
        for _, lifetime in ipairs(v73_row.telemetry.lifetimes) do
          if lifetime.active then
            v73_row.telemetry.rescue_count = v73_row.telemetry.rescue_count + 1
            add_failure(v73_row, "an exact live owned generation required rescue")
            local current = v73_row.telemetry.active_by_fd[lifetime.fd]
            if current == lifetime and current.generation == lifetime.generation then
              local rescue_ok, rescued = pcall(native.close, lifetime.fd)
              if rescue_ok and rescued == true then
                lifetime.active = false
                v73_row.telemetry.active_by_fd[lifetime.fd] = nil
              end
            end
          end
          if lifetime.active then
            all_closed = false
          end
        end
        if v73_row.telemetry.rescue_count ~= 0 then
          add_failure(v73_row, "descriptor rescue count was not zero")
        end
        if v73_row.telemetry.fallback_calls ~= 0 then
          add_failure(v73_row, "release was retried during fallback or teardown")
        end
        if v73_row.telemetry.extra_physical_closes ~= 0 then
          add_failure(v73_row, "an extra descriptor was physically closed")
        end
      end

      if v73_row.external_release_calls ~= 3 then
        add_failure(v73_row, "external release-call count was not three")
      end
      if #v73_row.captures ~= v73_row.external_release_calls then
        add_failure(v73_row, "release capture count did not match external release calls")
      end

      if v73_row.state_root and all_closed then
        local removed = vim.fn.delete(v73_row.state_root, "rf")
        if removed ~= 0 then
          add_failure(v73_row, "exact private row-root teardown failed")
        end
        local stat, stat_error, stat_code = native.lstat(v73_row.state_root)
        if not is_enoent(stat, stat_error, stat_code) then
          add_failure(v73_row, "exact private row-root absence was not proven")
        end
      elseif v73_row.state_root then
        add_failure(v73_row, "private row root was retained because a descriptor remained live")
      end

      local first_kind = "missing"
      if v73_row.first_capture then
        if
          v73_row.first_capture.ok
          and v73_row.first_capture.tuple[1] == nil
          and v73_row.first_capture.tuple[2] == spec.expected_error
        then
          first_kind = spec.first_kind
        elseif
          v73_row.first_capture.ok
          and v73_row.first_capture.tuple[1] == true
          and v73_row.first_capture.tuple[2] == nil
        then
          first_kind = "success"
        elseif v73_row.first_capture.ok then
          first_kind = "other"
        else
          first_kind = "raised"
        end
      end
      local outcome = "missing"
      if
        v73_row.first_activity
        and v73_row.first_activity.filesystem
        and v73_row.first_activity.filesystem.lock.ok
      then
        local lock_snapshot = v73_row.first_activity.filesystem.lock.value
        if vim.deep_equal(lock_snapshot, ABS) then
          outcome = "ABS"
        elseif
          v73_row.lock_identity
          and lock_snapshot[1]
          and same_identity(identity(lock_snapshot[1]), v73_row.lock_identity)
          and vim.deep_equal(lock_snapshot, v73_row.lock_before)
        then
          outcome = "KEEP"
        else
          outcome = "OTHER"
        end
      end
      local events = v73_row.first_activity and table.concat(v73_row.first_activity.events, ",")
        or "none"
      v73_row.observation = string.format(
        "%s first=%s repeat-tuple=%s repeat-activity=%s injection=%d arm=%d nontrigger=%d/%s outcome=%s rescue=%d events=%s",
        spec.key,
        first_kind,
        tostring(v73_row.repeat_tuples_equal),
        tostring(v73_row.repeat_activity_stable),
        v73_row.first_activity and v73_row.first_activity.injection_count or 0,
        v73_row.first_activity and v73_row.first_activity.realpath_arm_count or 0,
        v73_row.first_activity and v73_row.first_activity.lstat_nontrigger_count or 0,
        tostring(v73_row.first_activity and v73_row.first_activity.lstat_nontrigger_enoent),
        outcome,
        v73_row.telemetry and v73_row.telemetry.rescue_count or 0,
        events
      )
      if #v73_row.observation > 1024 then
        add_failure(v73_row, spec.key .. " observation was not bounded")
      end
      table.insert(observations, v73_row.observation)

      for _, result_text in ipairs(v73_row.visible_results) do
        if #result_text > 1024 then
          add_failure(v73_row, "a public or protected result was not bounded")
        end
      end
      local diagnostic_visible = copy(v73_row.visible_results)
      vim.list_extend(diagnostic_visible, v73_row.failures)
      table.insert(diagnostic_visible, v73_row.observation)
      local forbidden = {
        shared_payload,
        fixed_private_path,
        v4_fixed_private_path,
        v0_fixed_private_path,
        c1_fixed_private_path,
        o2_fixed_private_path,
        v1_fixed_private_path,
        v2_fixed_private_path,
        c0_fixed_private_path,
        c2_fixed_private_path,
        c3_fixed_private_path,
        c4_fixed_private_path,
        o0_fixed_private_path,
        o1_fixed_private_path,
      }
      vim.list_extend(forbidden, v73_row.private_paths or {})
      local leak_found = false
      for _, visible in ipairs(diagnostic_visible) do
        for _, needle in ipairs(forbidden) do
          if type(needle) == "string" and #needle > 0 and visible:find(needle, 1, true) then
            leak_found = true
          end
        end
      end
      if leak_found then
        add_failure(v73_row, "a shared payload or private fixture path reached diagnostics")
      end

      for _, detail in ipairs(v73_row.failures) do
        table.insert(failures, v73_row.label .. " " .. detail)
      end
    end

    local normal_events = {
      "fstat:state:g1:1",
      "lstat:lock:g0:1",
      "fstat:lock:g1:1",
      "realpath:lock:g0:1",
      "lstat:lock:g0:2",
      "close:lock:g1:1",
      "rmdir:lock:g0:1",
      "lstat:lock:g0:3",
      "fsync:state:g1:1",
      "close:state:g1:1",
    }
    local validation_stop_events = {
      "fstat:state:g1:1",
      "lstat:lock:g0:1",
      "fstat:lock:g1:1",
      "realpath:lock:g0:1",
      "lstat:lock:g0:2",
      "close:lock:g1:1",
      "fsync:state:g1:1",
      "close:state:g1:1",
    }
    local c0_spec = {
      key = "C0",
      label = "C0 lock-close failure after physical close",
      expected_error = RCL,
      first_kind = "RCL",
      vector = "FS,L1,FL,RP,L2,CL,RM,L3,SY,CS",
      expected_events = normal_events,
      inject_close_lock = true,
      injection_count = 1,
      arm_count = 0,
      post_delegation = {
        "native:close:lock:g1:1:true",
        "inject:close:lock:g1:1",
      },
    }
    local c2_spec = {
      key = "C2",
      label = "C2 absence-proof failure",
      expected_error = RVA,
      first_kind = "RVA",
      vector = "FS,L1,FL,RP,L2,CL,RM,L3,SY,CS",
      expected_events = normal_events,
      inject_absence = true,
      injection_count = 1,
      arm_count = 0,
      post_delegation = {
        "native:lstat:lock:g0:3:true",
        "inject:lstat:lock:g0:3",
      },
    }
    local c3_spec = {
      key = "C3",
      label = "C3 parent-fsync failure",
      expected_error = RF,
      first_kind = "RF",
      vector = "FS,L1,FL,RP,L2,CL,RM,L3,SY,CS",
      expected_events = normal_events,
      inject_fsync = true,
      injection_count = 1,
      arm_count = 0,
      post_delegation = {
        "native:fsync:state:g1:1:true",
        "inject:fsync:state:g1:1",
      },
    }
    local c4_spec = {
      key = "C4",
      label = "C4 parent-close failure after physical close",
      expected_error = RCS,
      first_kind = "RCS",
      vector = "FS,L1,FL,RP,L2,CL,RM,L3,SY,CS",
      expected_events = normal_events,
      inject_close_state = true,
      injection_count = 1,
      arm_count = 0,
      post_delegation = {
        "native:close:state:g1:1:true",
        "inject:close:state:g1:1",
      },
    }
    local o0_spec = {
      key = "O0",
      label = "O0 ABS ordering canary",
      expected_error = O0_ERROR,
      first_kind = "O0",
      vector = "FS,L1,FL,RP,L2,CL,RM,L3,SY,CS",
      expected_events = normal_events,
      inject_close_lock = true,
      inject_absence = true,
      inject_fsync = true,
      inject_close_state = true,
      injection_count = 4,
      arm_count = 0,
      post_delegation = {
        "native:close:lock:g1:1:true",
        "inject:close:lock:g1:1",
        "native:lstat:lock:g0:3:true",
        "inject:lstat:lock:g0:3",
        "native:fsync:state:g1:1:true",
        "inject:fsync:state:g1:1",
        "native:close:state:g1:1:true",
        "inject:close:state:g1:1",
      },
    }
    local o1_spec = {
      key = "O1",
      label = "O1 validation-stop ordering canary",
      expected_error = O1_ERROR,
      first_kind = "O1",
      vector = "FS,L1,FL,RP,L2,CL,SY,CS",
      expected_events = validation_stop_events,
      validation_stop = true,
      inject_l2 = true,
      inject_close_lock = true,
      inject_fsync = true,
      inject_close_state = true,
      injection_count = 4,
      arm_count = 1,
      post_delegation = {
        "native:lstat:lock:g0:2:true",
        "inject:lstat:lock:g0:2",
        "native:close:lock:g1:1:true",
        "inject:close:lock:g1:1",
        "native:fsync:state:g1:1:true",
        "inject:fsync:state:g1:1",
        "native:close:state:g1:1:true",
        "inject:close:state:g1:1",
      },
    }

    c0_executed_rows = c0_executed_rows + 1
    local c0_row = {
      label = c0_spec.label,
      failures = {},
      captures = {},
      visible_results = {},
      private_paths = {},
      external_release_calls = 0,
      repeat_tuples_equal = false,
      repeat_activity_stable = false,
    }
    local c0_protected_ok, c0_protected_error = xpcall(function()
      exercise_v73(c0_row, c0_spec)
      validate_v73_release(c0_row, c0_spec)
      validate_v73_state(c0_row, c0_spec)
    end, function()
      return "protected C0 exercise failed"
    end)
    finish_v73(c0_row, c0_spec, c0_protected_ok, c0_protected_error)

    c2_executed_rows = c2_executed_rows + 1
    local c2_row = {
      label = c2_spec.label,
      failures = {},
      captures = {},
      visible_results = {},
      private_paths = {},
      external_release_calls = 0,
      repeat_tuples_equal = false,
      repeat_activity_stable = false,
    }
    local c2_protected_ok, c2_protected_error = xpcall(function()
      exercise_v73(c2_row, c2_spec)
      validate_v73_release(c2_row, c2_spec)
      validate_v73_state(c2_row, c2_spec)
    end, function()
      return "protected C2 exercise failed"
    end)
    finish_v73(c2_row, c2_spec, c2_protected_ok, c2_protected_error)

    c3_executed_rows = c3_executed_rows + 1
    local c3_row = {
      label = c3_spec.label,
      failures = {},
      captures = {},
      visible_results = {},
      private_paths = {},
      external_release_calls = 0,
      repeat_tuples_equal = false,
      repeat_activity_stable = false,
    }
    local c3_protected_ok, c3_protected_error = xpcall(function()
      exercise_v73(c3_row, c3_spec)
      validate_v73_release(c3_row, c3_spec)
      validate_v73_state(c3_row, c3_spec)
    end, function()
      return "protected C3 exercise failed"
    end)
    finish_v73(c3_row, c3_spec, c3_protected_ok, c3_protected_error)

    c4_executed_rows = c4_executed_rows + 1
    local c4_row = {
      label = c4_spec.label,
      failures = {},
      captures = {},
      visible_results = {},
      private_paths = {},
      external_release_calls = 0,
      repeat_tuples_equal = false,
      repeat_activity_stable = false,
    }
    local c4_protected_ok, c4_protected_error = xpcall(function()
      exercise_v73(c4_row, c4_spec)
      validate_v73_release(c4_row, c4_spec)
      validate_v73_state(c4_row, c4_spec)
    end, function()
      return "protected C4 exercise failed"
    end)
    finish_v73(c4_row, c4_spec, c4_protected_ok, c4_protected_error)

    o0_executed_rows = o0_executed_rows + 1
    local o0_row = {
      label = o0_spec.label,
      failures = {},
      captures = {},
      visible_results = {},
      private_paths = {},
      external_release_calls = 0,
      repeat_tuples_equal = false,
      repeat_activity_stable = false,
    }
    local o0_protected_ok, o0_protected_error = xpcall(function()
      exercise_v73(o0_row, o0_spec)
      validate_v73_release(o0_row, o0_spec)
      validate_v73_state(o0_row, o0_spec)
    end, function()
      return "protected O0 exercise failed"
    end)
    finish_v73(o0_row, o0_spec, o0_protected_ok, o0_protected_error)

    o1_executed_rows = o1_executed_rows + 1
    local o1_row = {
      label = o1_spec.label,
      failures = {},
      captures = {},
      visible_results = {},
      private_paths = {},
      external_release_calls = 0,
      repeat_tuples_equal = false,
      repeat_activity_stable = false,
    }
    local o1_protected_ok, o1_protected_error = xpcall(function()
      exercise_v73(o1_row, o1_spec)
      validate_v73_release(o1_row, o1_spec)
      validate_v73_state(o1_row, o1_spec)
    end, function()
      return "protected O1 exercise failed"
    end)
    finish_v73(o1_row, o1_spec, o1_protected_ok, o1_protected_error)

    if c0_executed_rows ~= 1 then
      table.insert(failures, "Cycle 2E E2 C0 did not execute exactly once")
    end
    if c2_executed_rows ~= 1 then
      table.insert(failures, "Cycle 2E E2 C2 did not execute exactly once")
    end
    if c3_executed_rows ~= 1 then
      table.insert(failures, "Cycle 2E E2 C3 did not execute exactly once")
    end
    if c4_executed_rows ~= 1 then
      table.insert(failures, "Cycle 2E E2 C4 did not execute exactly once")
    end
    if o0_executed_rows ~= 1 then
      table.insert(failures, "Cycle 2E E2 O0 did not execute exactly once")
    end
    if o1_executed_rows ~= 1 then
      table.insert(failures, "Cycle 2E E2 O1 did not execute exactly once")
    end
    if not c0_row.observation or observations[8] ~= c0_row.observation then
      table.insert(failures, "Cycle 2E E2 C0 did not append one bounded observation")
    end
    if not c2_row.observation or observations[9] ~= c2_row.observation then
      table.insert(failures, "Cycle 2E E2 C2 did not append one bounded observation")
    end
    if not c3_row.observation or observations[10] ~= c3_row.observation then
      table.insert(failures, "Cycle 2E E2 C3 did not append one bounded observation")
    end
    if not c4_row.observation or observations[11] ~= c4_row.observation then
      table.insert(failures, "Cycle 2E E2 C4 did not append one bounded observation")
    end
    if not o0_row.observation or observations[12] ~= o0_row.observation then
      table.insert(failures, "Cycle 2E E2 O0 did not append one bounded observation")
    end
    if not o1_row.observation or observations[13] ~= o1_row.observation then
      table.insert(failures, "Cycle 2E E2 O1 did not append one bounded observation")
    end

    local R0_CANARY_OPEN_BOUND = 256
    local r0_executed_rows = 0

    local function exact_r0_state_projection(snapshot, lock_present)
      local expected = {
        ["."] = true,
        canaries = true,
        reviews = true,
        ["reviews/control.bin"] = true,
        ["reviews/control-link"] = true,
      }
      if lock_present then
        expected[lock_name] = true
      end
      for index = 1, R0_CANARY_OPEN_BOUND do
        expected[string.format("canaries/canary-%03d", index)] = true
      end

      local observed = {}
      for _, entry in ipairs(snapshot) do
        if not expected[entry.path] or observed[entry.path] then
          return false
        end
        observed[entry.path] = true
      end
      for path in pairs(expected) do
        if not observed[path] then
          return false
        end
      end
      return true
    end

    local function prepare_r0_row(r0_row)
      local control_bytes = "cycle-2e-e2-r0-control\n"
      r0_row.state_root = make_root("serialization-release-e2-r0")
      r0_row.canaries_path = vim.fs.joinpath(r0_row.state_root, "canaries")
      r0_row.lock_path = vim.fs.joinpath(r0_row.state_root, lock_name)
      r0_row.reviews_path = vim.fs.joinpath(r0_row.state_root, "reviews")
      r0_row.control_path = vim.fs.joinpath(r0_row.reviews_path, "control.bin")
      r0_row.link_path = vim.fs.joinpath(r0_row.reviews_path, "control-link")
      r0_row.private_paths = {
        r0_row.state_root,
        r0_row.canaries_path,
        r0_row.lock_path,
        r0_row.reviews_path,
        r0_row.control_path,
        r0_row.link_path,
      }
      r0_row.canary_specs = {}

      if
        not contained_path(r0_row.state_root, r0_row.canaries_path)
        or not contained_path(r0_row.state_root, r0_row.lock_path)
        or not contained_path(r0_row.state_root, r0_row.reviews_path)
      then
        add_failure(r0_row, "an R0 setup path escaped the exact private row root")
        return
      end

      local canaries_created = native.mkdir(r0_row.canaries_path, 448)
      if canaries_created ~= true or vim.uv.fs_chmod(r0_row.canaries_path, 448) ~= true then
        add_failure(r0_row, "R0 canary root setup failed")
        return
      end
      local canary_root_stat = native.lstat(r0_row.canaries_path)
      local current_uid = native.uid()
      if
        not canary_root_stat
        or canary_root_stat.type ~= "directory"
        or mode_bits(canary_root_stat) ~= 448
        or canary_root_stat.uid ~= current_uid
      then
        add_failure(r0_row, "R0 canary root was not an exact private directory")
        return
      end

      local seen_canary_identities = {}
      for index = 1, R0_CANARY_OPEN_BOUND do
        local canary_path =
          vim.fs.joinpath(r0_row.canaries_path, string.format("canary-%03d", index))
        table.insert(r0_row.private_paths, canary_path)
        if not contained_path(r0_row.state_root, canary_path) then
          add_failure(r0_row, "an R0 canary path escaped the exact private row root")
          return
        end
        local created = native.mkdir(canary_path, 448)
        if created ~= true or vim.uv.fs_chmod(canary_path, 448) ~= true then
          add_failure(r0_row, "an R0 canary directory could not be precreated")
          return
        end
        local canary_stat = native.lstat(canary_path)
        local canary_identity = identity(canary_stat)
        if
          not canary_identity
          or canary_identity.type ~= "directory"
          or canary_identity.mode ~= 448
          or canary_identity.uid ~= current_uid
        then
          add_failure(r0_row, "a precreated R0 canary identity was not exact")
          return
        end
        local identity_key =
          string.format("%s:%s", tostring(canary_identity.dev), tostring(canary_identity.ino))
        if seen_canary_identities[identity_key] then
          add_failure(r0_row, "precreated R0 canary identities were not distinct")
          return
        end
        seen_canary_identities[identity_key] = true
        table.insert(r0_row.canary_specs, {
          path = canary_path,
          identity = canary_identity,
        })
      end
      if #r0_row.canary_specs ~= R0_CANARY_OPEN_BOUND then
        add_failure(r0_row, "R0 did not precreate exactly 256 canary directories")
        return
      end

      if vim.fn.mkdir(r0_row.reviews_path, "p", 448) ~= 1 then
        add_failure(r0_row, "R0 reviews setup failed")
        return
      end
      if vim.uv.fs_chmod(r0_row.reviews_path, 448) ~= true then
        add_failure(r0_row, "R0 reviews chmod failed")
        return
      end
      write_file(r0_row.control_path, control_bytes, 384)
      if native.symlink("control.bin", r0_row.link_path) ~= true then
        add_failure(r0_row, "R0 reviews symlink setup failed")
        return
      end
      r0_row.reviews_before = snapshot_tree(r0_row.reviews_path)

      local reviews_root_exact = false
      local control_exact = false
      local link_exact = false
      for _, entry in ipairs(r0_row.reviews_before) do
        if
          entry.path == "."
          and entry.type == "directory"
          and entry.mode == 448
          and entry.uid == current_uid
        then
          reviews_root_exact = true
        elseif
          entry.path == "control.bin"
          and entry.type == "file"
          and entry.mode == 384
          and entry.uid == current_uid
          and entry.sha256 == vim.fn.sha256(control_bytes)
        then
          control_exact = true
        elseif
          entry.path == "control-link"
          and entry.type == "link"
          and entry.target == "control.bin"
        then
          link_exact = true
        end
      end
      if not reviews_root_exact or not control_exact or not link_exact then
        add_failure(
          r0_row,
          "reviews metadata, regular-file digest, or symlink target was not exact"
        )
      end

      local state_stat = native.lstat(r0_row.state_root)
      r0_row.state_identity = identity(state_stat)
      if
        not r0_row.state_identity
        or r0_row.state_identity.type ~= "directory"
        or r0_row.state_identity.mode ~= 448
        or r0_row.state_identity.uid ~= current_uid
      then
        add_failure(r0_row, "state root was not an exact current-user mode-0700 directory")
        return
      end

      local dependencies, telemetry = v73_instrumented_dependencies(r0_row, {
        key = "R0",
      })
      r0_row.telemetry = telemetry
      local lease, acquire_error = serialization.acquire(r0_row.state_root, dependencies)
      if not lease then
        if acquire_error ~= nil then
          table.insert(r0_row.visible_results, tostring(acquire_error))
        end
        add_failure(r0_row, "normal R0 acquisition failed")
        return
      end
      if acquire_error ~= nil then
        table.insert(r0_row.visible_results, tostring(acquire_error))
        add_failure(r0_row, "normal R0 acquisition returned an error")
      end
      r0_row.lease = lease
      r0_row.acquired_lifetimes = lifetime_snapshot(telemetry)

      local lock_stat = native.lstat(r0_row.lock_path)
      r0_row.lock_identity = identity(lock_stat)
      r0_row.lock_before = snapshot_tree(r0_row.lock_path)
      local lock_root = r0_row.lock_before[1]
      if
        #r0_row.lock_before ~= 1
        or not lock_root
        or lock_root.path ~= "."
        or lock_root.type ~= "directory"
        or lock_root.mode ~= 448
        or lock_root.uid ~= current_uid
        or lock_root.dev ~= r0_row.state_identity.dev
        or not same_identity(r0_row.lock_identity, lock_root)
      then
        add_failure(r0_row, "acquired lock was not an exact private empty directory")
      end

      r0_row.acquired_targets = {}
      for _, lifetime in ipairs(telemetry.lifetimes) do
        if lifetime.category == "state" or lifetime.category == "lock" then
          if r0_row.acquired_targets[lifetime.category] then
            add_failure(r0_row, "acquisition retained a duplicate descriptor category")
          else
            local descriptor_stat = native.fstat(lifetime.fd)
            local descriptor_identity = identity(descriptor_stat)
            r0_row.acquired_targets[lifetime.category] = {
              fd = lifetime.fd,
              generation = lifetime.generation,
              identity = descriptor_identity,
            }
            local expected_identity = lifetime.category == "state" and r0_row.state_identity
              or r0_row.lock_identity
            if
              lifetime.generation ~= 1
              or lifetime.active ~= true
              or not same_identity(descriptor_identity, expected_identity)
            then
              add_failure(r0_row, "an acquired R0 target generation or identity was not exact")
            end
          end
        else
          add_failure(r0_row, "acquisition retained an unexpected descriptor category")
        end
      end
      local state_target = r0_row.acquired_targets.state
      local lock_target = r0_row.acquired_targets.lock
      if not state_target or not lock_target then
        add_failure(r0_row, "acquisition did not retain both exact R0 descriptor targets")
      elseif state_target.fd == lock_target.fd then
        add_failure(r0_row, "acquired state and lock lifetimes aliased one integer fd")
      end

      r0_row.state_before = snapshot_tree(r0_row.state_root)
      r0_row.canaries_before = snapshot_tree(r0_row.canaries_path)
      if not exact_r0_state_projection(r0_row.state_before, true) then
        add_failure(r0_row, "pre-release R0 state-root projection was not exact")
      end
      if #r0_row.canaries_before ~= R0_CANARY_OPEN_BOUND + 1 then
        add_failure(r0_row, "pre-release R0 canary snapshot was not exact")
      end

      v73_begin_release(telemetry)
      r0_row.release_start = v73_telemetry_snapshot(telemetry)
    end

    local function allocate_r0_canaries(r0_row)
      r0_row.canary_records = {}
      r0_row.canary_active_by_fd = {}
      r0_row.canary_generations = copy(r0_row.telemetry.generations)
      r0_row.canary_targets = {}
      r0_row.canary_open_attempts = 0
      r0_row.canary_open_failures = 0
      r0_row.canary_live_generation_reuse = 0
      r0_row.fd_reuse_count = 0

      for _, canary in ipairs(r0_row.canary_specs) do
        if r0_row.canary_targets.state and r0_row.canary_targets.lock then
          break
        end
        r0_row.canary_open_attempts = r0_row.canary_open_attempts + 1
        local fd = native.open(canary.path, "r", 0)
        if fd == nil then
          r0_row.canary_open_failures = r0_row.canary_open_failures + 1
        else
          local prior = r0_row.canary_active_by_fd[fd]
          if prior and prior.active then
            r0_row.canary_live_generation_reuse = r0_row.canary_live_generation_reuse + 1
          end
          local generation = (r0_row.canary_generations[fd] or 0) + 1
          r0_row.canary_generations[fd] = generation
          local descriptor_stat = native.fstat(fd)
          local descriptor_identity = identity(descriptor_stat)
          local record = {
            fd = fd,
            generation = generation,
            identity = descriptor_identity,
            expected_identity = canary.identity,
            active = true,
            close_attempts = 0,
            physical_closes = 0,
          }
          table.insert(r0_row.canary_records, record)
          r0_row.canary_active_by_fd[fd] = record
          if not same_identity(descriptor_identity, canary.identity) then
            add_failure(r0_row, "a native-opened R0 canary identity was not exact")
          end

          for _, category in ipairs({ "state", "lock" }) do
            local target = r0_row.acquired_targets[category]
            if target and fd == target.fd then
              if r0_row.canary_targets[category] then
                add_failure(r0_row, "an R0 target integer was rebound while already active")
              else
                record.target_category = category
                r0_row.canary_targets[category] = record
              end
            end
          end
        end
      end

      if r0_row.canary_open_attempts > R0_CANARY_OPEN_BOUND then
        add_failure(r0_row, "R0 exceeded the 256-open canary bound")
      end
      if r0_row.canary_open_failures ~= 0 then
        add_failure(r0_row, "one or more bounded native R0 canary opens failed")
      end
      if not r0_row.canary_targets.state or not r0_row.canary_targets.lock then
        add_failure(r0_row, "both old descriptor integers were not reacquired within 256 opens")
      end

      for _, category in ipairs({ "state", "lock" }) do
        local target = r0_row.acquired_targets[category]
        local record = r0_row.canary_targets[category]
        if
          target
          and record
          and record.fd == target.fd
          and record.generation == target.generation + 1
          and record.active == true
          and r0_row.canary_active_by_fd[record.fd] == record
          and same_identity(record.identity, record.expected_identity)
          and not same_identity(record.identity, target.identity)
        then
          r0_row.fd_reuse_count = r0_row.fd_reuse_count + 1
        else
          add_failure(r0_row, "an R0 target reuse lacked exact generation-2 identity proof")
        end
      end
      if
        r0_row.canary_targets.state
        and r0_row.canary_targets.lock
        and (
          r0_row.canary_targets.state == r0_row.canary_targets.lock
          or r0_row.canary_targets.state.fd == r0_row.canary_targets.lock.fd
          or same_identity(
            r0_row.canary_targets.state.identity,
            r0_row.canary_targets.lock.identity
          )
        )
      then
        add_failure(r0_row, "R0 state and lock canary targets were not distinct")
      end
      if r0_row.canary_live_generation_reuse ~= 0 then
        add_failure(r0_row, "R0 observed live-generation reuse during canary allocation")
      end
      for _, record in ipairs(r0_row.canary_records) do
        if r0_row.canary_active_by_fd[record.fd] ~= record then
          add_failure(r0_row, "an R0 canary record was not owned by its exact active integer")
        end
      end
    end

    local function probe_r0_target(r0_row, category, repeat_index)
      local target = r0_row.acquired_targets[category]
      local record = r0_row.canary_targets[category]
      local probe = {
        category = category,
        repeat_index = repeat_index,
        ok = false,
      }
      table.insert(r0_row.target_probes, probe)
      if not target or not record then
        add_failure(r0_row, "an immediate cached-release R0 target probe was unavailable")
        return
      end

      local descriptor_stat = native.fstat(record.fd)
      local descriptor_identity = identity(descriptor_stat)
      probe.fd = record.fd
      probe.generation = record.generation
      probe.identity = descriptor_identity
      if
        record.fd == target.fd
        and record.generation == target.generation + 1
        and record.active == true
        and r0_row.canary_active_by_fd[record.fd] == record
        and same_identity(descriptor_identity, record.expected_identity)
        and same_identity(descriptor_identity, record.identity)
      then
        probe.ok = true
        r0_row.immediate_fstat_count = r0_row.immediate_fstat_count + 1
      else
        add_failure(r0_row, "an immediate cached-release R0 target fstat was not exact")
      end
    end

    local function exercise_r0(r0_row)
      prepare_r0_row(r0_row)
      if not r0_row.lease then
        return
      end

      r0_row.external_release_calls = r0_row.external_release_calls + 1
      r0_row.first_capture = capture_release(r0_row.lease)
      add_visible_capture(r0_row, r0_row.first_capture)
      r0_row.first_activity = v73_complete_snapshot(r0_row)

      allocate_r0_canaries(r0_row)
      r0_row.target_probes = {}
      r0_row.immediate_fstat_count = 0
      r0_row.repeat_tuples_equal = true
      r0_row.repeat_activity_stable = true
      for repeat_index = 1, 2 do
        r0_row.external_release_calls = r0_row.external_release_calls + 1
        local repeated = capture_release(r0_row.lease)
        add_visible_capture(r0_row, repeated)
        if not repeated.ok or not vim.deep_equal(repeated.tuple, r0_row.first_capture.tuple) then
          r0_row.repeat_tuples_equal = false
        end

        probe_r0_target(r0_row, "state", repeat_index)
        probe_r0_target(r0_row, "lock", repeat_index)

        local repeated_activity = v73_complete_snapshot(r0_row)
        if not vim.deep_equal(repeated_activity, r0_row.first_activity) then
          r0_row.repeat_activity_stable = false
        end
      end

      if not r0_row.repeat_tuples_equal then
        add_failure(r0_row, "cached releases did not repeat the complete nil-sensitive pair")
      end
      if not r0_row.repeat_activity_stable then
        add_failure(
          r0_row,
          "cached releases changed dependency, descriptor, or filesystem activity"
        )
      end
    end

    local function validate_r0_release(r0_row)
      if not r0_row.first_capture then
        add_failure(r0_row, "first release result was not captured")
        return
      end
      local expected_tuple = { n = 2, [1] = true }
      if not r0_row.first_capture.ok then
        add_failure(r0_row, "first release raised")
      elseif not vim.deep_equal(r0_row.first_capture.tuple, expected_tuple) then
        add_failure(r0_row, "first release did not return the exact success pair")
      end
      if not r0_row.first_activity then
        add_failure(r0_row, "first release activity was not captured")
        return
      end

      local expected_events = {
        "fstat:state:g1:1",
        "lstat:lock:g0:1",
        "fstat:lock:g1:1",
        "realpath:lock:g0:1",
        "lstat:lock:g0:2",
        "close:lock:g1:1",
        "rmdir:lock:g0:1",
        "lstat:lock:g0:3",
        "fsync:state:g1:1",
        "close:state:g1:1",
      }
      if not vim.deep_equal(r0_row.first_activity.events, expected_events) then
        add_failure(r0_row, "release event vector was not exact FS,L1,FL,RP,L2,CL,RM,L3,SY,CS")
      end

      local expected_calls = {
        lstat = { 0, 3 },
        realpath = { 0, 1 },
        open = { 0, 0 },
        fstat = { 1, 1 },
        mkdir = { 0, 0 },
        scandir = { 0, 0 },
        scandir_next = { 0, 0 },
        fsync = { 1, 0 },
        close = { 1, 1 },
        rmdir = { 0, 1 },
      }
      for _, operation in ipairs(operation_names) do
        local expected = expected_calls[operation]
        expect_path_counter(
          r0_row,
          operation .. " calls",
          r0_row.first_activity.calls[operation],
          expected[1],
          expected[2]
        )
        expect_path_counter(
          r0_row,
          operation .. " native delegations",
          r0_row.first_activity.delegates[operation],
          expected[1],
          expected[2]
        )
      end
      expect_count(r0_row, "UID calls", r0_row.first_activity.uid_calls, 0)
      expect_count(r0_row, "UID native delegations", r0_row.first_activity.uid_delegates, 0)
      expect_count(
        r0_row,
        "UID unexpected arguments",
        r0_row.first_activity.uid_unexpected_arguments,
        0
      )

      if not r0_row.release_start then
        add_failure(r0_row, "release-start telemetry was not captured")
      else
        for _, operation in ipairs(operation_names) do
          expect_path_counter(
            r0_row,
            "release-start " .. operation .. " calls",
            r0_row.release_start.calls[operation],
            0,
            0
          )
          expect_path_counter(
            r0_row,
            "release-start " .. operation .. " native delegations",
            r0_row.release_start.delegates[operation],
            0,
            0
          )
        end
        if
          #r0_row.release_start.events ~= 0
          or next(r0_row.release_start.native_results) ~= nil
          or #r0_row.release_start.post_delegation ~= 0
          or r0_row.release_start.injection_count ~= 0
          or #r0_row.release_start.injection_payloads ~= 0
          or r0_row.release_start.l2_armed ~= false
          or r0_row.release_start.realpath_arm_count ~= 0
          or r0_row.release_start.lstat_nontrigger_count ~= 0
          or r0_row.release_start.lstat_nontrigger_enoent ~= false
          or r0_row.release_start.physical_closes ~= 0
          or r0_row.release_start.uid_calls ~= 0
          or r0_row.release_start.rescue_count ~= 0
          or r0_row.release_start.fallback_calls ~= 0
        then
          add_failure(r0_row, "fixture setup contaminated release telemetry")
        end
      end

      local state_fstat = first_result(r0_row.first_activity, "fstat", "state", 1)
      local initial_lstat = first_result(r0_row.first_activity, "lstat", "lock", 1)
      local lock_fstat = first_result(r0_row.first_activity, "fstat", "lock", 1)
      local realpath = first_result(r0_row.first_activity, "realpath", "lock", 1)
      local final_lstat = first_result(r0_row.first_activity, "lstat", "lock", 2)
      local lock_close = first_result(r0_row.first_activity, "close", "lock", 1)
      local rmdir = first_result(r0_row.first_activity, "rmdir", "lock", 1)
      local absence = first_result(r0_row.first_activity, "lstat", "lock", 3)
      local state_fsync = first_result(r0_row.first_activity, "fsync", "state", 1)
      local state_close = first_result(r0_row.first_activity, "close", "state", 1)
      if
        not state_fstat
        or not state_fstat.exists
        or not same_identity(state_fstat.identity, r0_row.state_identity)
      then
        add_failure(r0_row, "retained state fd did not observe the acquired identity")
      end
      if
        not initial_lstat
        or not initial_lstat.exists
        or initial_lstat.enoent
        or not same_identity(initial_lstat.identity, r0_row.lock_identity)
      then
        add_failure(r0_row, "L1 did not natively observe the acquired lock")
      end
      if
        not lock_fstat
        or not lock_fstat.exists
        or not same_identity(lock_fstat.identity, r0_row.lock_identity)
      then
        add_failure(r0_row, "retained lock fd did not observe the acquired lock")
      end
      if not realpath or realpath.path ~= r0_row.lock_path then
        add_failure(r0_row, "delegated realpath did not prove the exact fixed lock path")
      end
      if
        not final_lstat
        or not final_lstat.exists
        or final_lstat.enoent
        or not same_identity(final_lstat.identity, r0_row.lock_identity)
      then
        add_failure(r0_row, "L2 did not natively observe the acquired lock")
      end
      if not lock_close or lock_close.closed ~= true then
        add_failure(r0_row, "retained lock fd was not physically closed")
      end
      if not rmdir or rmdir.removed ~= true then
        add_failure(r0_row, "lock directory was not natively removed")
      end
      if not absence or absence.exists or not absence.enoent then
        add_failure(r0_row, "L3 did not natively prove lock absence")
      end
      if not state_fsync or state_fsync.synced ~= true then
        add_failure(r0_row, "state root did not receive one native synchronization attempt")
      end
      if not state_close or state_close.closed ~= true then
        add_failure(r0_row, "retained state fd was not physically closed last")
      end

      if
        r0_row.first_activity.injection_count ~= 0
        or r0_row.first_activity.injection_native_ok ~= true
        or #r0_row.first_activity.injection_payloads ~= 0
        or #r0_row.first_activity.post_delegation ~= 0
        or r0_row.first_activity.l2_armed ~= false
        or r0_row.first_activity.realpath_arm_count ~= 0
        or r0_row.first_activity.lstat_nontrigger_count ~= 0
        or r0_row.first_activity.lstat_nontrigger_enoent ~= false
      then
        add_failure(r0_row, "injection-free R0 release telemetry was not exact")
      end
    end

    local function validate_r0_state(r0_row)
      if not r0_row.first_activity then
        add_failure(r0_row, "first release activity was unavailable for state checks")
        return
      end
      local filesystem = r0_row.first_activity.filesystem
      if not v73_snapshots_ok(filesystem) then
        add_failure(r0_row, "complete first-release filesystem snapshot was unavailable")
      else
        local final_state_root = filesystem.state.value[1]
        if
          not final_state_root
          or not same_identity(identity(final_state_root), r0_row.state_identity)
          or final_state_root.type ~= "directory"
          or final_state_root.mode ~= 448
          or final_state_root.uid ~= native.uid()
        then
          add_failure(r0_row, "state-root identity or private metadata changed")
        end
        if not vim.deep_equal(filesystem.reviews.value, r0_row.reviews_before) then
          add_failure(r0_row, "content-aware reviews snapshot changed during release")
        end
        if not vim.deep_equal(filesystem.lock.value, ABS) then
          add_failure(r0_row, "ABS lock snapshot was not exact")
        end
        if not exact_r0_state_projection(filesystem.state.value, false) then
          add_failure(r0_row, "R0 ABS projection had a missing or extra sibling")
        end
      end

      local canaries_after = protected_snapshot(r0_row.canaries_path)
      if
        not canaries_after.ok
        or not vim.deep_equal(canaries_after.value, r0_row.canaries_before)
      then
        add_failure(r0_row, "complete R0 canary snapshot changed during release")
      end

      local acquired_counts = { state = 0, lock = 0, unexpected = 0 }
      for _, lifetime in ipairs(r0_row.acquired_lifetimes or {}) do
        acquired_counts[lifetime.category] = acquired_counts[lifetime.category] + 1
        if
          lifetime.generation ~= 1
          or lifetime.active ~= true
          or lifetime.release_close_attempts ~= 0
          or lifetime.release_physical_closes ~= 0
        then
          add_failure(r0_row, "pre-release acquired generation state was not exact")
        end
      end
      expect_count(r0_row, "acquired state generations", acquired_counts.state, 1)
      expect_count(r0_row, "acquired lock generations", acquired_counts.lock, 1)
      expect_count(r0_row, "acquired unexpected generations", acquired_counts.unexpected, 0)

      local lifetime_counts = { state = 0, lock = 0, unexpected = 0 }
      for _, lifetime in ipairs(r0_row.first_activity.lifetimes) do
        lifetime_counts[lifetime.category] = lifetime_counts[lifetime.category] + 1
        if lifetime.generation ~= 1 then
          add_failure(r0_row, "owned descriptor generation was not one")
        end
        if lifetime.release_close_attempts ~= 1 then
          add_failure(r0_row, "owned generation did not receive exactly one release close")
        end
        if lifetime.release_physical_closes ~= 1 or lifetime.active then
          add_failure(r0_row, "owned generation was not physically closed exactly once")
        end
      end
      expect_count(r0_row, "state descriptor generations", lifetime_counts.state, 1)
      expect_count(r0_row, "lock descriptor generations", lifetime_counts.lock, 1)
      expect_count(r0_row, "unexpected descriptor generations", lifetime_counts.unexpected, 0)
      expect_count(r0_row, "live generation reuse", r0_row.first_activity.live_generation_reuse, 0)
      expect_count(r0_row, "integer-fd aliases", r0_row.first_activity.integer_fd_aliases, 0)
      expect_count(
        r0_row,
        "unowned close attempts",
        r0_row.first_activity.unowned_close_attempts,
        0
      )
      expect_count(r0_row, "extra physical closes", r0_row.first_activity.extra_physical_closes, 0)
      expect_count(r0_row, "physical closes", r0_row.first_activity.physical_closes, 2)
      expect_count(r0_row, "rescue calls", r0_row.first_activity.rescue_count, 0)
      expect_count(r0_row, "fallback release calls", r0_row.first_activity.fallback_calls, 0)

      expect_count(r0_row, "exact reused target descriptors", r0_row.fd_reuse_count, 2)
      expect_count(r0_row, "immediate target fstat successes", r0_row.immediate_fstat_count, 4)
      if #r0_row.target_probes ~= 4 then
        add_failure(r0_row, "R0 did not record exactly four immediate target probes")
      else
        local expected_probe_order = {
          { "state", 1 },
          { "lock", 1 },
          { "state", 2 },
          { "lock", 2 },
        }
        for index, expected in ipairs(expected_probe_order) do
          local probe = r0_row.target_probes[index]
          if
            probe.category ~= expected[1]
            or probe.repeat_index ~= expected[2]
            or probe.ok ~= true
          then
            add_failure(r0_row, "R0 immediate target probe order or result was not exact")
          end
        end
      end
      if
        #r0_row.canary_records == 0
        or #r0_row.canary_records > R0_CANARY_OPEN_BOUND
        or r0_row.canary_open_attempts ~= #r0_row.canary_records
      then
        add_failure(r0_row, "R0 retained canary descriptor count was not exact")
      end
      for _, record in ipairs(r0_row.canary_records) do
        if
          record.active ~= true
          or record.close_attempts ~= 0
          or record.physical_closes ~= 0
          or r0_row.canary_active_by_fd[record.fd] ~= record
          or r0_row.canary_generations[record.fd] ~= record.generation
          or not same_identity(record.identity, record.expected_identity)
        then
          add_failure(r0_row, "a retained R0 canary generation was not exact before close")
        end
      end
    end

    local function finish_r0(r0_row, protected_ok, protected_error)
      if not protected_ok then
        table.insert(r0_row.visible_results, protected_error)
        add_failure(r0_row, "protected R0 exercise did not complete")
      end

      local all_closed = true
      r0_row.target_close_count = 0
      for _, record in ipairs(r0_row.canary_records or {}) do
        if not record.active then
          add_failure(r0_row, "an R0 canary descriptor was not live until test-side close")
        else
          record.close_attempts = record.close_attempts + 1
          local close_ok, closed = pcall(native.close, record.fd)
          if close_ok and closed == true and r0_row.canary_active_by_fd[record.fd] == record then
            record.active = false
            record.physical_closes = record.physical_closes + 1
            r0_row.canary_active_by_fd[record.fd] = nil
            if record.target_category then
              r0_row.target_close_count = r0_row.target_close_count + 1
            end
          else
            add_failure(r0_row, "an R0 canary descriptor was not natively closed")
          end
        end
        if record.active or record.close_attempts ~= 1 or record.physical_closes ~= 1 then
          all_closed = false
          add_failure(r0_row, "an R0 canary generation was not closed exactly once")
        end
      end
      if next(r0_row.canary_active_by_fd or {}) ~= nil then
        all_closed = false
        add_failure(r0_row, "the R0 canary active-generation map was not empty")
      end
      expect_count(r0_row, "exact reused target descriptors", r0_row.fd_reuse_count or 0, 2)
      expect_count(r0_row, "immediate target fstat successes", r0_row.immediate_fstat_count or 0, 4)
      expect_count(r0_row, "test-side target closes", r0_row.target_close_count, 2)

      if r0_row.telemetry then
        r0_row.telemetry.phase = "teardown"
        for _, lifetime in ipairs(r0_row.telemetry.lifetimes) do
          if lifetime.active then
            r0_row.telemetry.rescue_count = r0_row.telemetry.rescue_count + 1
            add_failure(r0_row, "an exact live owned generation required rescue")
            local current = r0_row.telemetry.active_by_fd[lifetime.fd]
            if current == lifetime and current.generation == lifetime.generation then
              local rescue_ok, rescued = pcall(native.close, lifetime.fd)
              if rescue_ok and rescued == true then
                lifetime.active = false
                r0_row.telemetry.active_by_fd[lifetime.fd] = nil
              end
            end
          end
          if lifetime.active then
            all_closed = false
          end
        end
        if r0_row.telemetry.rescue_count ~= 0 then
          add_failure(r0_row, "descriptor rescue count was not zero")
        end
        if r0_row.telemetry.fallback_calls ~= 0 then
          add_failure(r0_row, "release was retried during fallback or teardown")
        end
        if r0_row.telemetry.live_generation_reuse ~= 0 then
          add_failure(r0_row, "release observed live-generation reuse")
        end
        if r0_row.telemetry.integer_fd_aliases ~= 0 then
          add_failure(r0_row, "release observed an integer-fd alias")
        end
        if r0_row.telemetry.unowned_close_attempts ~= 0 then
          add_failure(r0_row, "release attempted to close an unowned descriptor")
        end
        if r0_row.telemetry.extra_physical_closes ~= 0 then
          add_failure(r0_row, "an extra descriptor was physically closed")
        end
      end

      if r0_row.external_release_calls ~= 3 then
        add_failure(r0_row, "external release-call count was not three")
      end
      if #r0_row.captures ~= r0_row.external_release_calls then
        add_failure(r0_row, "release capture count did not match external release calls")
      end

      if r0_row.state_root and all_closed then
        local removed = vim.fn.delete(r0_row.state_root, "rf")
        if removed ~= 0 then
          add_failure(r0_row, "exact private row-root teardown failed")
        end
        local stat, stat_error, stat_code = native.lstat(r0_row.state_root)
        if not is_enoent(stat, stat_error, stat_code) then
          add_failure(r0_row, "exact private row-root absence was not proven")
        end
      elseif r0_row.state_root then
        add_failure(r0_row, "private row root was retained because a descriptor remained live")
      end

      local first_kind = "missing"
      if r0_row.first_capture then
        if
          r0_row.first_capture.ok
          and r0_row.first_capture.tuple[1] == true
          and r0_row.first_capture.tuple[2] == nil
        then
          first_kind = "success"
        elseif r0_row.first_capture.ok then
          first_kind = "other"
        else
          first_kind = "raised"
        end
      end
      local outcome = "missing"
      if
        r0_row.first_activity
        and r0_row.first_activity.filesystem
        and r0_row.first_activity.filesystem.lock.ok
      then
        if vim.deep_equal(r0_row.first_activity.filesystem.lock.value, ABS) then
          outcome = "ABS"
        else
          outcome = "OTHER"
        end
      end
      local events = r0_row.first_activity and table.concat(r0_row.first_activity.events, ",")
        or "none"
      r0_row.observation = string.format(
        "R0 first=%s repeat-tuple=%s repeat-activity=%s fd-reuse=%d/2 bound=%d immediate-fstat=%d/4 target-close=%d/2 outcome=%s rescue=%d events=%s",
        first_kind,
        tostring(r0_row.repeat_tuples_equal),
        tostring(r0_row.repeat_activity_stable),
        r0_row.fd_reuse_count or 0,
        R0_CANARY_OPEN_BOUND,
        r0_row.immediate_fstat_count or 0,
        r0_row.target_close_count,
        outcome,
        r0_row.telemetry and r0_row.telemetry.rescue_count or 0,
        events
      )
      if #r0_row.observation > 1024 then
        add_failure(r0_row, "R0 observation was not bounded")
      end
      table.insert(observations, r0_row.observation)

      for _, result_text in ipairs(r0_row.visible_results) do
        if #result_text > 1024 then
          add_failure(r0_row, "a public or protected result was not bounded")
        end
      end
      local diagnostic_visible = copy(r0_row.visible_results)
      vim.list_extend(diagnostic_visible, r0_row.failures)
      table.insert(diagnostic_visible, r0_row.observation)
      local forbidden = {
        shared_payload,
        fixed_private_path,
        v4_fixed_private_path,
        v0_fixed_private_path,
        c1_fixed_private_path,
        o2_fixed_private_path,
        v1_fixed_private_path,
        v2_fixed_private_path,
        c0_fixed_private_path,
        c2_fixed_private_path,
        c3_fixed_private_path,
        c4_fixed_private_path,
        o0_fixed_private_path,
        o1_fixed_private_path,
      }
      vim.list_extend(forbidden, r0_row.private_paths or {})
      local leak_found = false
      for _, visible in ipairs(diagnostic_visible) do
        for _, needle in ipairs(forbidden) do
          if type(needle) == "string" and #needle > 0 and visible:find(needle, 1, true) then
            leak_found = true
          end
        end
      end
      if leak_found then
        add_failure(r0_row, "a shared payload or private fixture path reached diagnostics")
      end

      for _, detail in ipairs(r0_row.failures) do
        table.insert(failures, r0_row.label .. " " .. detail)
      end
    end

    r0_executed_rows = r0_executed_rows + 1
    local r0_row = {
      label = "R0 final-revalidation and fd-reuse control",
      failures = {},
      captures = {},
      visible_results = {},
      private_paths = {},
      external_release_calls = 0,
      repeat_tuples_equal = false,
      repeat_activity_stable = false,
    }
    local r0_protected_ok, r0_protected_error = xpcall(function()
      exercise_r0(r0_row)
      validate_r0_release(r0_row)
      validate_r0_state(r0_row)
    end, function()
      return "protected R0 exercise failed"
    end)
    finish_r0(r0_row, r0_protected_ok, r0_protected_error)

    if r0_executed_rows ~= 1 then
      table.insert(failures, "Cycle 2E E2 R0 did not execute exactly once")
    end
    if not r0_row.observation or observations[14] ~= r0_row.observation then
      table.insert(failures, "Cycle 2E E2 R0 did not append one bounded observation")
    end

    if executed_rows ~= 1 then
      table.insert(failures, "Cycle 2E E2 V3 did not execute exactly once")
    end
    if not row.observation or observations[1] ~= row.observation then
      table.insert(failures, "Cycle 2E E2 V3 did not record one bounded observation")
    end
    local runtime_proof = table.concat({
      string.format(
        "V3=%d/%s/%s/%d/%s",
        executed_rows,
        tostring(protected_ok),
        tostring(row.observation ~= nil and observations[1] == row.observation),
        #row.failures,
        vim.fn.sha256(table.concat(row.failures, "\n"))
      ),
      string.format(
        "V4=%d/%s/%s/%d/%s",
        v4_executed_rows,
        tostring(v4_protected_ok),
        tostring(v4_row.observation ~= nil and observations[2] == v4_row.observation),
        #v4_row.failures,
        vim.fn.sha256(table.concat(v4_row.failures, "\n"))
      ),
      string.format(
        "V0=%d/%s/%s/%d/%s",
        v0_executed_rows,
        tostring(v0_protected_ok),
        tostring(v0_row.observation ~= nil and observations[3] == v0_row.observation),
        #v0_row.failures,
        vim.fn.sha256(table.concat(v0_row.failures, "\n"))
      ),
      string.format(
        "C1=%d/%s/%s/%d/%s",
        c1_executed_rows,
        tostring(c1_protected_ok),
        tostring(c1_row.observation ~= nil and observations[4] == c1_row.observation),
        #c1_row.failures,
        vim.fn.sha256(table.concat(c1_row.failures, "\n"))
      ),
      string.format(
        "O2=%d/%s/%s/%d/%s",
        o2_executed_rows,
        tostring(o2_protected_ok),
        tostring(o2_row.observation ~= nil and observations[5] == o2_row.observation),
        #o2_row.failures,
        vim.fn.sha256(table.concat(o2_row.failures, "\n"))
      ),
      string.format(
        "V1=%d/%s/%s/%d/%s",
        v1_executed_rows,
        tostring(v1_protected_ok),
        tostring(v1_row.observation ~= nil and observations[6] == v1_row.observation),
        #v1_row.failures,
        vim.fn.sha256(table.concat(v1_row.failures, "\n"))
      ),
      string.format(
        "V2=%d/%s/%s/%d/%s",
        v2_executed_rows,
        tostring(v2_protected_ok),
        tostring(v2_row.observation ~= nil and observations[7] == v2_row.observation),
        #v2_row.failures,
        vim.fn.sha256(table.concat(v2_row.failures, "\n"))
      ),
      string.format(
        "C0=%d/%s/%s/%d/%s",
        c0_executed_rows,
        tostring(c0_protected_ok),
        tostring(c0_row.observation ~= nil and observations[8] == c0_row.observation),
        #c0_row.failures,
        vim.fn.sha256(table.concat(c0_row.failures, "\n"))
      ),
      string.format(
        "C2=%d/%s/%s/%d/%s",
        c2_executed_rows,
        tostring(c2_protected_ok),
        tostring(c2_row.observation ~= nil and observations[9] == c2_row.observation),
        #c2_row.failures,
        vim.fn.sha256(table.concat(c2_row.failures, "\n"))
      ),
      string.format(
        "C3=%d/%s/%s/%d/%s",
        c3_executed_rows,
        tostring(c3_protected_ok),
        tostring(c3_row.observation ~= nil and observations[10] == c3_row.observation),
        #c3_row.failures,
        vim.fn.sha256(table.concat(c3_row.failures, "\n"))
      ),
      string.format(
        "C4=%d/%s/%s/%d/%s",
        c4_executed_rows,
        tostring(c4_protected_ok),
        tostring(c4_row.observation ~= nil and observations[11] == c4_row.observation),
        #c4_row.failures,
        vim.fn.sha256(table.concat(c4_row.failures, "\n"))
      ),
      string.format(
        "O0=%d/%s/%s/%d/%s",
        o0_executed_rows,
        tostring(o0_protected_ok),
        tostring(o0_row.observation ~= nil and observations[12] == o0_row.observation),
        #o0_row.failures,
        vim.fn.sha256(table.concat(o0_row.failures, "\n"))
      ),
      string.format(
        "O1=%d/%s/%s/%d/%s",
        o1_executed_rows,
        tostring(o1_protected_ok),
        tostring(o1_row.observation ~= nil and observations[13] == o1_row.observation),
        #o1_row.failures,
        vim.fn.sha256(table.concat(o1_row.failures, "\n"))
      ),
      string.format(
        "R0=%d/%s/%s/%d/%s",
        r0_executed_rows,
        tostring(r0_protected_ok),
        tostring(r0_row.observation ~= nil and observations[14] == r0_row.observation),
        #r0_row.failures,
        vim.fn.sha256(table.concat(r0_row.failures, "\n"))
      ),
      string.format("GLOBAL=%d/%s", #failures, vim.fn.sha256(table.concat(failures, "\n"))),
    }, ",")
    assert(
      #failures == 0,
      runtime_proof
        .. " | observations: "
        .. table.concat(observations, "; ")
        .. " | failures: "
        .. table.concat(failures, "; ")
    )
  end

  do
    local fixture = Fixture.new("publication-contention")
    fixture:write("tracked.txt", "committed\n")
    fixture:commit("publication contention")
    fixture:write("tracked.txt", "dirty\n")

    local reviews_path = vim.fs.joinpath(fixture.state, "reviews")
    assert(vim.fn.mkdir(reviews_path, "p", 448) == 1)
    assert(vim.uv.fs_chmod(reviews_path, 448))
    write_file(vim.fs.joinpath(reviews_path, "control.bin"), "contention control\n")
    assert(vim.uv.fs_symlink("control.bin", vim.fs.joinpath(reviews_path, "control-link")))

    local EVENT_SUMMARY_LIMIT = 8
    local FALLBACK_TEXT_SUMMARY =
      "len=14 sha256=2cb71b01eefae66a47de8117e23ce0926722323b7868a217ed28f927e1df85ec"
    local EVENT_ALLOWLIST = {
      acquire = true,
      release = true,
      ["holder-acquired"] = true,
      ["exercise-start"] = true,
      ["exercise-finish"] = true,
      ["holder-release"] = true,
      ["review-dir"] = true,
      mkdir = true,
      rename = true,
      write = true,
      unlink = true,
      rmdir = true,
    }
    local function protected_text(value)
      local ok, text = pcall(tostring, value)
      if ok and type(text) == "string" then
        return text
      end
      return "<unrenderable>"
    end
    local function summarize_text(value)
      local text = protected_text(value)
      local hash_ok, digest = pcall(function()
        return vim.fn.sha256(text)
      end)
      if
        not hash_ok
        or type(digest) ~= "string"
        or #digest ~= 64
        or not digest:match("^[0-9a-f]+$")
      then
        return FALLBACK_TEXT_SUMMARY
      end
      return string.format("len=%d sha256=%s", #text, digest)
    end
    local function summarize_events(events)
      local retained = {}
      local retained_count = math.min(#events, EVENT_SUMMARY_LIMIT)
      for index = 1, retained_count do
        local token = events[index]
        if type(token) ~= "string" or EVENT_ALLOWLIST[token] ~= true then
          token = "invalid"
        end
        table.insert(retained, token)
      end
      return string.format(
        "%s remaining=%d",
        retained_count == 0 and "none" or table.concat(retained, ","),
        #events - retained_count
      )
    end
    local function exact_events(actual, expected)
      if #actual ~= #expected then
        return false
      end
      for index, token in ipairs(expected) do
        if actual[index] ~= token then
          return false
        end
      end
      return true
    end

    local store = fixture:store()
    local review_dir_calls = 0
    local publication_events = {}
    local original_review_dir = store.review_dir
    store.review_dir = function(self, review_id)
      review_dir_calls = review_dir_calls + 1
      table.insert(publication_events, "review-dir")
      return original_review_dir(self, review_id)
    end

    local lifecycle = {}
    local holder_dependencies, holder_descriptors = tracked_open_close_dependencies()
    local contender_dependencies, contender_descriptors = tracked_open_close_dependencies()

    local operation_lifetimes = {}
    local operation_active = {}
    local operation_generations = {}
    local operation_unowned_closes = 0
    local operation_live_generation_reuse = 0
    local native_open = vim.uv.fs_open
    local native_close = vim.uv.fs_close
    local function operation_open(path, flags, mode)
      local fd, open_error, open_code = native_open(path, flags, mode)
      if fd ~= nil then
        if operation_active[fd] ~= nil then
          operation_live_generation_reuse = operation_live_generation_reuse + 1
        end
        local generation = (operation_generations[fd] or 0) + 1
        operation_generations[fd] = generation
        local lifetime = {
          fd = fd,
          generation = generation,
          close_attempts = 0,
          physical_closes = 0,
          active = true,
        }
        table.insert(operation_lifetimes, lifetime)
        operation_active[fd] = lifetime
      end
      return fd, open_error, open_code
    end
    local function operation_close(fd)
      local lifetime = operation_active[fd]
      if lifetime then
        lifetime.close_attempts = lifetime.close_attempts + 1
      else
        operation_unowned_closes = operation_unowned_closes + 1
      end
      local closed, close_error, close_code = native_close(fd)
      if lifetime and closed == true then
        lifetime.physical_closes = lifetime.physical_closes + 1
        lifetime.active = false
        if operation_active[fd] == lifetime then
          operation_active[fd] = nil
        end
      end
      return closed, close_error, close_code
    end

    local mutation_operations = { "mkdir", "rename", "write", "unlink", "rmdir" }
    local operation_functions = {
      open = operation_open,
      close = operation_close,
    }
    local serializer_events = {}
    local serializer_canary = {
      acquire_count = 0,
      release_count = 0,
      inner_release_count = 0,
      held = false,
      lease_count = 0,
      state_roots = {},
      dependency_argument_count = 0,
      dependency_argument_exact = nil,
    }
    serializer_canary.acquire = function(state_root, operation_dependencies)
      serializer_canary.acquire_count = serializer_canary.acquire_count + 1
      serializer_canary.dependency_argument_count = serializer_canary.dependency_argument_count + 1
      local dependency_argument_exact = type(operation_dependencies) == "table"
        and operation_dependencies.serialization == serializer_canary
        and operation_dependencies.open == operation_functions.open
        and operation_dependencies.close == operation_functions.close
      for _, operation in ipairs(mutation_operations) do
        dependency_argument_exact = dependency_argument_exact
          and operation_dependencies[operation] == operation_functions[operation]
      end
      if serializer_canary.dependency_argument_exact == nil then
        serializer_canary.dependency_argument_exact = dependency_argument_exact
      else
        serializer_canary.dependency_argument_exact = serializer_canary.dependency_argument_exact
          and dependency_argument_exact
      end

      table.insert(serializer_canary.state_roots, state_root)
      table.insert(serializer_events, "acquire")
      table.insert(lifecycle, "acquire")
      local lease, acquire_error = serialization.acquire(state_root, contender_dependencies)
      if not lease then
        return nil, acquire_error
      end

      serializer_canary.held = true
      serializer_canary.lease_count = serializer_canary.lease_count + 1
      local consumed = false
      local cached_value
      local cached_error
      local wrapped = {}
      function wrapped:release()
        serializer_canary.release_count = serializer_canary.release_count + 1
        table.insert(serializer_events, "release")
        if consumed then
          return cached_value, cached_error
        end
        consumed = true
        serializer_canary.inner_release_count = serializer_canary.inner_release_count + 1
        cached_value, cached_error = lease:release()
        serializer_canary.held = false
        return cached_value, cached_error
      end
      return wrapped
    end

    local mutation_counts = { mkdir = 0, rename = 0, write = 0, unlink = 0, rmdir = 0 }
    local overrides = {
      serialization = serializer_canary,
      open = operation_functions.open,
      close = operation_functions.close,
    }
    local function mutation_wrapper(operation, native)
      return function(...)
        mutation_counts[operation] = mutation_counts[operation] + 1
        table.insert(publication_events, operation)
        return native(...)
      end
    end
    for _, operation in ipairs(mutation_operations) do
      local wrapped = mutation_wrapper(operation, assert(vim.uv["fs_" .. operation]))
      operation_functions[operation] = wrapped
      overrides[operation] = wrapped
    end
    local publication = baseline_module._test.new(overrides)
    local identity = fixture:identity()

    local holder, holder_error = serialization.acquire(fixture.state, holder_dependencies)
    assert(holder, tostring(holder_error))
    table.insert(lifecycle, "holder-acquired")

    local captured = {}
    local protected_ok, protected_error = xpcall(function()
      table.insert(lifecycle, "exercise-start")
      captured.reviews_before = snapshot_tree(reviews_path)
      captured.lock_before =
        snapshot_tree(vim.fs.joinpath(fixture.state, ".baseline-serialization"))
      captured.result = { n = 2 }
      captured.result[1], captured.result[2] = publication.create(identity, store)
      captured.reviews_after = snapshot_tree(reviews_path)
      captured.lock_after = snapshot_tree(vim.fs.joinpath(fixture.state, ".baseline-serialization"))
      table.insert(lifecycle, "exercise-finish")
    end, debug.traceback)

    table.insert(lifecycle, "holder-release")
    local holder_release_ok, holder_release_value, holder_release_error = xpcall(function()
      return holder:release()
    end, debug.traceback)

    local harness_failures = {}
    local behavior_failures = {}
    local diagnostics = {}
    local function add_harness_failure(message)
      table.insert(harness_failures, message)
    end
    local function add_behavior_failure(message)
      table.insert(behavior_failures, message)
    end
    local function add_diagnostic(label, value)
      table.insert(diagnostics, label .. " " .. summarize_text(value))
    end
    if not holder_release_ok then
      captured.holder_release_traceback = holder_release_value
      add_harness_failure("holder release raised")
      add_diagnostic("holder-release-traceback", holder_release_value)
    elseif holder_release_value ~= true or holder_release_error ~= nil then
      captured.holder_release_result = {
        n = 2,
        [1] = holder_release_value,
        [2] = holder_release_error,
      }
      add_harness_failure("holder release returned a failure")
      add_diagnostic("holder-release-value", holder_release_value)
      add_diagnostic("holder-release-error", holder_release_error)
    end
    if not protected_ok then
      captured.protected_traceback = protected_error
      add_harness_failure("protected publication-contention exercise raised")
      add_diagnostic("protected-traceback", protected_error)
    end

    local lock_path = vim.fs.joinpath(fixture.state, ".baseline-serialization")
    local released_lock, released_error, released_code = vim.uv.fs_lstat(lock_path)
    local released_error_text = protected_text(released_error)
    if
      released_lock
      or (
        released_code ~= "ENOENT"
        and not released_error_text:find("ENOENT", 1, true)
        and not released_error_text:find("no such file", 1, true)
      )
    then
      add_harness_failure("holder lock absence was not proven after finalization")
    end

    local function validate_descriptors(label, tracked, record_failure)
      local count = 0
      local invalid = 0
      for _, descriptor in pairs(tracked) do
        count = count + 1
        if
          descriptor.open_succeeded ~= true
          or descriptor.close_attempts ~= 1
          or descriptor.physical_close ~= true
        then
          invalid = invalid + 1
        end
      end
      if invalid ~= 0 then
        record_failure(
          string.format("%s descriptor lifetimes invalid %d/%d", label, invalid, count)
        )
      end
      if count ~= 2 then
        record_failure(string.format("%s descriptor count expected 2 actual %d", label, count))
      end
      return count
    end
    local holder_descriptor_count =
      validate_descriptors("holder", holder_descriptors, add_harness_failure)
    local contender_descriptor_count =
      validate_descriptors("contender", contender_descriptors, add_behavior_failure)

    local operation_invalid_lifetimes = 0
    for _, lifetime in ipairs(operation_lifetimes) do
      if
        lifetime.close_attempts ~= 1
        or lifetime.physical_closes ~= 1
        or lifetime.active ~= false
      then
        operation_invalid_lifetimes = operation_invalid_lifetimes + 1
      end
    end
    if operation_invalid_lifetimes ~= 0 then
      add_harness_failure(
        string.format(
          "baseline-operation descriptor lifetimes invalid %d/%d",
          operation_invalid_lifetimes,
          #operation_lifetimes
        )
      )
    end
    if operation_unowned_closes ~= 0 then
      add_harness_failure(
        string.format(
          "baseline-operation unowned closes expected 0 actual %d",
          operation_unowned_closes
        )
      )
    end
    if operation_live_generation_reuse ~= 0 then
      add_harness_failure(
        string.format(
          "baseline-operation live generation reuse expected 0 actual %d",
          operation_live_generation_reuse
        )
      )
    end

    local expected_error = "baseline serialization unavailable: lock exists (active or stale)"
    if protected_ok then
      if captured.result[1] ~= nil then
        add_behavior_failure("publication succeeded while holder was active")
      end
      if captured.result[2] ~= expected_error then
        add_behavior_failure("publication did not return the exact active-or-stale error")
      end
      if not vim.deep_equal(captured.lock_before, captured.lock_after) then
        add_behavior_failure("holder lock changed during publication contention")
      end
      if not vim.deep_equal(captured.reviews_before, captured.reviews_after) then
        add_behavior_failure("reviews snapshot changed while holder was active")
      end
    end

    if serializer_canary.acquire_count ~= 1 then
      add_behavior_failure(
        string.format(
          "serializer acquire count expected 1 actual %d",
          serializer_canary.acquire_count
        )
      )
    elseif not vim.deep_equal(serializer_canary.state_roots, { fixture.state }) then
      add_behavior_failure("serializer did not receive the exact state root")
    end
    if
      serializer_canary.dependency_argument_count ~= 1
      or serializer_canary.dependency_argument_exact ~= true
    then
      add_behavior_failure("serializer dependency argument was not exact")
    end
    if
      serializer_canary.release_count ~= 0
      or serializer_canary.inner_release_count ~= 0
      or serializer_canary.held ~= false
      or serializer_canary.lease_count ~= 0
    then
      add_behavior_failure("serializer contention lifecycle was not exact")
    end
    if not exact_events(serializer_events, { "acquire" }) then
      add_behavior_failure("serializer event order was not exact")
    end
    local expected_lifecycle = {
      "holder-acquired",
      "exercise-start",
      "acquire",
      "exercise-finish",
      "holder-release",
    }
    if not exact_events(lifecycle, expected_lifecycle) then
      add_behavior_failure("publication contention lifecycle order was not exact")
    end
    if review_dir_calls ~= 0 then
      add_behavior_failure(string.format("review_dir calls expected 0 actual %d", review_dir_calls))
    end
    local expected_mutations = { mkdir = 0, rename = 0, write = 0, unlink = 0, rmdir = 0 }
    if not vim.deep_equal(mutation_counts, expected_mutations) then
      add_behavior_failure(
        string.format(
          "publication mutations expected 0/0/0/0/0 actual %d/%d/%d/%d/%d",
          mutation_counts.mkdir,
          mutation_counts.rename,
          mutation_counts.write,
          mutation_counts.unlink,
          mutation_counts.rmdir
        )
      )
    end
    if not exact_events(publication_events, {}) then
      add_behavior_failure("publication event order was not exact")
    end

    local cleanup_call_ok, cleanup_result = pcall(vim.fn.delete, fixture.base, "rf")
    if not cleanup_call_ok then
      captured.cleanup_traceback = cleanup_result
      add_harness_failure("fixture cleanup raised")
      add_diagnostic("fixture-cleanup-traceback", cleanup_result)
    elseif cleanup_result ~= 0 then
      add_harness_failure("fixture cleanup returned a failure")
    end
    local cleanup_stat, cleanup_error, cleanup_code = vim.uv.fs_lstat(fixture.base)
    captured.cleanup_lstat_error = cleanup_error
    local cleanup_error_text = protected_text(cleanup_error)
    local cleanup_absent = not cleanup_stat
      and (
        cleanup_code == "ENOENT"
        or cleanup_error_text:find("ENOENT", 1, true)
        or cleanup_error_text:find("no such file", 1, true)
      )
    if not cleanup_absent then
      add_harness_failure("fixture absence was not proven after cleanup")
    end
    local cleanup_exact = cleanup_call_ok and cleanup_result == 0 and cleanup_absent

    local result_error_summary = "unavailable"
    if captured.result then
      if captured.result[2] == nil then
        result_error_summary = "nil"
      elseif captured.result[2] == expected_error then
        result_error_summary = "active-or-stale"
      else
        result_error_summary = "unexpected(" .. summarize_text(captured.result[2]) .. ")"
      end
    end

    local observation = string.format(
      "result=%s error=%s acquire=%d deps=%d/%s release=%d held=%s leases=%d descriptors=%d/%d/%d review-dir=%d mutations=%d/%d/%d/%d/%d serializer-events=%s publication-events=%s snapshot=%s holder-lock=%s lifecycle=%s cleanup=%s",
      captured.result and captured.result[1] ~= nil and "success" or "nil",
      result_error_summary,
      serializer_canary.acquire_count,
      serializer_canary.dependency_argument_count,
      tostring(serializer_canary.dependency_argument_exact),
      serializer_canary.release_count,
      tostring(serializer_canary.held),
      serializer_canary.lease_count,
      holder_descriptor_count,
      contender_descriptor_count,
      #operation_lifetimes,
      review_dir_calls,
      mutation_counts.mkdir,
      mutation_counts.rename,
      mutation_counts.write,
      mutation_counts.unlink,
      mutation_counts.rmdir,
      summarize_events(serializer_events),
      summarize_events(publication_events),
      tostring(protected_ok and vim.deep_equal(captured.reviews_before, captured.reviews_after)),
      tostring(protected_ok and vim.deep_equal(captured.lock_before, captured.lock_after)),
      summarize_events(lifecycle),
      tostring(cleanup_exact)
    )
    local harness_summary = #harness_failures == 0 and "none"
      or table.concat(harness_failures, "; ")
    local behavior_summary = #behavior_failures == 0 and "none"
      or table.concat(behavior_failures, "; ")
    local diagnostic_suffix = #diagnostics == 0 and ""
      or " | diagnostics: " .. table.concat(diagnostics, "; ")
    assert(
      #harness_failures == 0 and #behavior_failures == 0,
      "baseline publication contention: harness="
        .. harness_summary
        .. string.format(" harness-count=%d", #harness_failures)
        .. " | behavior="
        .. behavior_summary
        .. string.format(" behavior-count=%d", #behavior_failures)
        .. " | observation: "
        .. observation
        .. diagnostic_suffix
    )
  end

  do
    local fixture = Fixture.new("process-publication-contention")
    fixture:write("tracked.txt", "committed\n")
    fixture:commit("process publication contention")
    fixture:write("tracked.txt", "dirty\n")

    local reviews_path = vim.fs.joinpath(fixture.state, "reviews")
    assert(vim.fn.mkdir(reviews_path, "p", 448) == 1, "contention reviews creation failed")
    assert(vim.uv.fs_chmod(reviews_path, 448) == true, "contention reviews mode failed")
    local control_file = vim.fs.joinpath(reviews_path, "control.bin")
    local control_link = vim.fs.joinpath(reviews_path, "control-link")
    write_file(control_file, "contention control\n")
    assert(
      vim.uv.fs_symlink("control.bin", control_link) == true,
      "contention control symlink failed"
    )

    local state_dir_calls = 0
    local review_dir_calls = 0
    local store = fixture:store()
    local original_state_dir = store.state_dir
    local original_review_dir = store.review_dir
    store.state_dir = function(self)
      state_dir_calls = state_dir_calls + 1
      return original_state_dir(self)
    end
    store.review_dir = function(self, review_id)
      review_dir_calls = review_dir_calls + 1
      return original_review_dir(self, review_id)
    end

    local control_root = make_root("process-publication-control")
    local child = task7_spawn_holder(fixture.state, control_root, "process-publication-child")
    assert(task7_wait_ready(child), "publication holder readiness failed")

    local captured = {}
    local exercise_ok = xpcall(function()
      captured.before = snapshot_tree(reviews_path)
      captured.nonvacuous = #captured.before >= 3
      captured.value, captured.error = baseline_module.create(fixture:identity(), store)
      captured.blocked_state_dir = state_dir_calls
      captured.blocked_review_dir = review_dir_calls
      captured.after = snapshot_tree(reviews_path)
    end, function()
      return "publication contention exercise failed"
    end)

    local released = task7_release_holder(child)
    local lock_path = vim.fs.joinpath(fixture.state, ".baseline-serialization")
    local lock_absent = task7_exact_enoent(lock_path)

    assert(exercise_ok, "publication contention exercise failed")
    assert(released, "publication holder wait failed")
    assert(task7_complete_result(child), "publication holder result was incomplete")
    assert(
      child.result.code == 0 and child.result.signal == 0,
      "publication holder exit was invalid"
    )
    assert(task7_zero_output(child), "publication holder emitted output")
    assert(captured.nonvacuous, "publication contention snapshot was vacuous")
    assert(captured.value == nil, "publication succeeded while process holder was active")
    assert(
      captured.error == "baseline serialization unavailable: lock exists (active or stale)",
      "publication contention error was not exact"
    )
    assert(captured.blocked_state_dir == 1, "blocked publication state_dir count was not exact")
    assert(captured.blocked_review_dir == 0, "blocked publication review_dir count was not exact")
    assert(
      vim.deep_equal(captured.before, captured.after),
      "publication contention changed reviews"
    )
    assert(lock_absent, "publication holder lock remained after clean exit")

    local before_retry_state_dir = state_dir_calls
    local before_retry_review_dir = review_dir_calls
    local retry, retry_error = baseline_module.create(fixture:identity(), store)
    assert(retry ~= nil and retry_error == nil, "publication retry failed")
    -- State is validated before acquisition, during publication, and during the final load.
    assert(
      state_dir_calls - before_retry_state_dir == 3,
      "publication retry state_dir delta was not exact"
    )
    assert(
      review_dir_calls - before_retry_review_dir == 1,
      "publication retry review_dir delta was not exact"
    )
    assert(state_dir_calls == 4, "cumulative publication state_dir count was not exact")
    assert(review_dir_calls == 1, "cumulative publication review_dir count was not exact")
    local removed, remove_error = retry:remove()
    assert(removed == true and remove_error == nil, "publication retry cleanup failed")
    assert(
      vim.deep_equal(review_entries(fixture), { "control-link", "control.bin" }),
      "publication retry changed control entries"
    )
    assert(read_file(control_file) == "contention control\n", "publication control changed")
    assert(vim.uv.fs_readlink(control_link) == "control.bin", "publication control link changed")
  end

  do
    local fixture = Fixture.new("process-killed-holder")
    fixture:write("tracked.txt", "committed\n")
    fixture:commit("process killed holder")
    fixture:write("tracked.txt", "dirty\n")

    local lock_path = vim.fs.joinpath(fixture.state, ".baseline-serialization")
    local attempts = { mkdir = 0, rename = 0, unlink = 0, rmdir = 0 }
    local successes = { mkdir = 0, rename = 0, unlink = 0, rmdir = 0 }
    local lock_mkdir_attempts = 0
    local overrides = {}
    local function instrument(operation)
      local native = assert(vim.uv["fs_" .. operation])
      return function(...)
        local arguments = { ... }
        attempts[operation] = attempts[operation] + 1
        if operation == "mkdir" and arguments[1] == lock_path then
          lock_mkdir_attempts = lock_mkdir_attempts + 1
        end
        local value, native_error, native_code = native(...)
        if value == true then
          successes[operation] = successes[operation] + 1
        end
        return value, native_error, native_code
      end
    end
    for _, operation in ipairs({ "mkdir", "rename", "unlink", "rmdir" }) do
      overrides[operation] = instrument(operation)
    end

    local publication = baseline_module._test.new(overrides)
    local identity = fixture:identity()
    local store = fixture:store()
    local created, create_error = publication.create(identity, store)
    assert(created ~= nil and create_error == nil, "killed-holder setup publication failed")
    local opened, open_error = publication.open(identity, store, created:id())
    assert(opened ~= nil and open_error == nil, "killed-holder setup open failed")

    for name in pairs(successes) do
      attempts[name] = 0
      successes[name] = 0
    end
    lock_mkdir_attempts = 0

    local reviews_path = vim.fs.joinpath(fixture.state, "reviews")
    local before = snapshot_tree(reviews_path)
    local control_root = make_root("process-killed-control")
    local child = task7_spawn_holder(fixture.state, control_root, "process-killed-child")
    assert(task7_wait_ready(child), "killed holder readiness failed")

    local anchor = task7_open_parent_descriptor(lock_path)
    assert(anchor and anchor.identity_exact == true, "killed holder lock anchor failed")

    local captured = {}
    local exercise_ok = xpcall(function()
      captured.release_absent_before_kill = task7_exact_enoent(child.release_path)
      captured.killed = task7_kill_holder(child)
      captured.release_absent_after_kill = task7_exact_enoent(child.release_path)
      captured.path_after_kill = task7_parent_path_matches(anchor)
      captured.fd_after_kill = task7_parent_descriptor_matches(anchor)
      captured.create_value, captured.create_error = publication.create(identity, store)
      captured.path_after_create = task7_parent_path_matches(anchor)
      captured.fd_after_create = task7_parent_descriptor_matches(anchor)
      captured.remove_value, captured.remove_error = opened:remove()
      captured.path_after_remove = task7_parent_path_matches(anchor)
      captured.fd_after_remove = task7_parent_descriptor_matches(anchor)
      captured.after = snapshot_tree(reviews_path)
      captured.path_after_snapshot = task7_parent_path_matches(anchor)
      captured.release_absent_after_operations = task7_exact_enoent(child.release_path)
    end, function()
      return "killed holder exercise failed"
    end)

    local anchor_closed = task7_complete_result(child) and task7_close_parent_descriptor(anchor)
    local expected_error = "baseline serialization unavailable: lock exists (active or stale)"

    assert(exercise_ok, "killed holder exercise failed")
    assert(captured.killed, "killed holder wait failed")
    assert(task7_complete_result(child), "killed holder result was incomplete")
    assert(child.result.signal == 9, "killed holder signal was not exact")
    assert(task7_zero_output(child), "killed holder emitted output")
    assert(
      captured.release_absent_before_kill
        and captured.release_absent_after_kill
        and captured.release_absent_after_operations,
      "killed holder release marker was not absent"
    )
    assert(captured.path_after_kill and captured.fd_after_kill, "lock identity changed after kill")
    assert(
      captured.path_after_create and captured.fd_after_create,
      "lock identity changed after blocked creation"
    )
    assert(
      captured.path_after_remove and captured.fd_after_remove,
      "lock identity changed after blocked removal"
    )
    assert(captured.path_after_snapshot, "lock identity changed after review snapshot")
    assert(
      captured.create_value == nil and captured.create_error == expected_error,
      "blocked creation was not exact"
    )
    assert(
      captured.remove_value == nil and captured.remove_error == expected_error,
      "blocked removal was not exact"
    )
    assert(vim.deep_equal(before, captured.after), "killed holder changed reviews")
    assert(lock_mkdir_attempts == 2, "killed holder lock mkdir attempts were not exact")
    assert(attempts.mkdir == 2, "killed holder mkdir attempts were not exact")
    assert(attempts.rename == 0, "killed holder rename was called")
    assert(attempts.unlink == 0, "killed holder unlink was called")
    assert(attempts.rmdir == 0, "killed holder rmdir was called")
    assert(successes.mkdir == 0, "killed holder mkdir unexpectedly succeeded")
    assert(successes.rename == 0, "killed holder rename unexpectedly succeeded")
    assert(successes.unlink == 0, "killed holder unlink unexpectedly succeeded")
    assert(successes.rmdir == 0, "killed holder rmdir unexpectedly succeeded")
    assert(anchor.close_attempts == 1, "lock anchor close count was not exact")
    assert(anchor.physical_closes == 1, "lock anchor physical close was not exact")
    assert(anchor_closed and anchor.final_fstat_exact, "lock anchor EBADF proof failed")
    assert(parent_descriptor_live_reuse == 0, "parent descriptor generation was reused")
  end

  do
    local expected_error = "state directory changed before baseline publication"
    local required_post_acquire = {
      "uid",
      "lstat",
      "realpath",
      "readlink",
      "open",
      "fstat",
      "read",
      "write",
      "fsync",
      "close",
      "mkdir",
      "rename",
      "scandir",
      "scandir_next",
      "hash",
      "resolve_git",
      "revalidate_git",
      "system",
      "fd_path",
      "after_read",
    }
    local dependency_names = {
      "lstat",
      "realpath",
      "readlink",
      "open",
      "fstat",
      "read",
      "write",
      "fsync",
      "close",
      "mkdir",
      "unlink",
      "rmdir",
      "rename",
      "scandir",
      "scandir_next",
      "hash",
      "uid",
      "pid",
      "hrtime",
      "resolve_git",
      "revalidate_git",
      "system",
      "fd_path",
      "after_read",
    }
    local success_events = {
      "capture",
      "review-id",
      "acquire",
      "state-refresh",
      "review-dir",
      "mutation",
      "sync",
      "publish",
      "verify",
      "load",
      "close",
      "release",
    }
    local drift_events = {
      "capture",
      "review-id",
      "acquire",
      "state-refresh",
      "release",
    }
    local failures = {}
    local observations = {}

    local function exact_tokens(actual, expected)
      if #actual ~= #expected then
        return false
      end
      for index, token in ipairs(expected) do
        if actual[index] ~= token then
          return false
        end
      end
      return true
    end

    local function exact_counts(actual, expected)
      for name, count in pairs(expected) do
        if actual[name] ~= count then
          return false
        end
      end
      return true
    end

    local function named_upvalue(fn, target)
      if type(fn) ~= "function" then
        return nil
      end
      for index = 1, 64 do
        local ok, name, value = pcall(debug.getupvalue, fn, index)
        if not ok or name == nil then
          break
        end
        if name == target then
          return value
        end
      end
      return nil
    end

    local function execute_row(label, inject_inode_drift)
      local fixture = Fixture.new("publication-lease-" .. label)
      fixture:write("clean.txt", "clean\n")
      fixture:write("dirty.txt", "committed\n")
      fixture:symlink("linked", "clean.txt")
      fixture:commit("publication lease")
      fixture:write("dirty.txt", "dirty\n")

      local identity = fixture:identity()
      local reviews_path = vim.fs.joinpath(fixture.state, "reviews")
      local row = {
        events = {},
        dependencies = {},
        mutation_counts = { mkdir = 0, rename = 0, write = 0, unlink = 0, rmdir = 0 },
        fsync_roles = {},
        git_counts = {
          verify_rev_parse = 0,
          verify_ls_tree = 0,
          verify_ls_files = 0,
          verify_diff = 0,
          load_cat_file = 0,
        },
        open_flags = { r = 0, wx = 0 },
        descriptors = {},
        active = {},
        generations = {},
        held_violations = 0,
        after_release_calls = 0,
        live_generation_reuse = 0,
        unowned_closes = 0,
        pre_acquire_state_samples = 0,
        expected_state_named_locals = 0,
        expected_state_exact_locals = 0,
        state_dir_calls = 0,
        review_dir_calls = 0,
        lease_named_locals = 0,
        lease_exact_locals = 0,
        drift_injections = 0,
        rescue_count = 0,
      }
      local canary_lease = {}
      local serializer_canary = {
        acquire_count = 0,
        release_count = 0,
        physical_release_count = 0,
        held = false,
        active = nil,
        dependency_argument_exact = false,
        acquisition_order_exact = false,
        root_exact = false,
      }
      local expected_dependencies = {}
      local consumed = false
      local cached_value
      local cached_error
      local capture_path_seen = false
      local capture_complete = false
      local review_id_generated = false
      local publication_complete = false
      local verification_complete = false
      local load_started = false
      local close_after_load = false
      local sync_started = false
      local mutation_started = false
      local state_refresh_started = false
      local head_tree
      local review_id
      local expected_clean_storage
      local expected_dirty_storage
      local expected_link_storage
      local pre_acquire_state_stat
      local fixed_pid = 4104
      local fixed_hrtime = 4204

      local function note_dependency(name)
        if serializer_canary.acquire_count == 0 then
          return
        end
        if serializer_canary.release_count > 0 then
          row.after_release_calls = row.after_release_calls + 1
          return
        end
        row.dependencies[name] = (row.dependencies[name] or 0) + 1
        if
          serializer_canary.held ~= true
          or not rawequal(serializer_canary.active, canary_lease)
        then
          row.held_violations = row.held_violations + 1
        end
      end

      local function append_event(token)
        table.insert(row.events, token)
      end

      local store = {}
      function store:state_dir()
        row.state_dir_calls = row.state_dir_calls + 1
        if serializer_canary.acquire_count > 0 then
          note_dependency("state_dir")
          if not state_refresh_started then
            state_refresh_started = true
            append_event("state-refresh")
          end
        end
        return fixture.state
      end
      function store:review_dir(candidate_review_id)
        row.review_dir_calls = row.review_dir_calls + 1
        note_dependency("review_dir")
        append_event("review-dir")
        for level = 2, 8 do
          for index = 1, 64 do
            local ok, name, value = pcall(debug.getlocal, level, index)
            if not ok or name == nil then
              break
            end
            if name == "lease" then
              row.lease_named_locals = row.lease_named_locals + 1
              if rawequal(value, canary_lease) then
                row.lease_exact_locals = row.lease_exact_locals + 1
              end
            end
          end
        end
        assert(candidate_review_id:match("^[0-9a-f]+$"), "invalid test review id")
        local path = vim.fs.joinpath(reviews_path, candidate_review_id)
        assert(vim.fn.mkdir(path, "p", 448) >= 0, "review directory creation failed")
        assert(vim.uv.fs_chmod(reviews_path, 448), "reviews chmod failed")
        assert(vim.uv.fs_chmod(path, 448), "review chmod failed")
        return path
      end

      function serializer_canary.acquire(state_root, operation_dependencies)
        serializer_canary.acquire_count = serializer_canary.acquire_count + 1
        serializer_canary.root_exact = state_root == fixture.state
        serializer_canary.acquisition_order_exact = capture_complete
          and review_id_generated
          and row.review_dir_calls == 0
        local exact = type(operation_dependencies) == "table"
          and operation_dependencies.serialization == serializer_canary
        for name, fn in pairs(expected_dependencies) do
          exact = exact and operation_dependencies[name] == fn
        end
        for _, name in ipairs(dependency_names) do
          exact = exact and type(operation_dependencies[name]) == "function"
        end
        serializer_canary.dependency_argument_exact = exact
        append_event("acquire")
        serializer_canary.held = true
        serializer_canary.active = canary_lease
        return canary_lease
      end

      function canary_lease:release()
        serializer_canary.release_count = serializer_canary.release_count + 1
        if consumed then
          return cached_value, cached_error
        end
        consumed = true
        serializer_canary.physical_release_count = serializer_canary.physical_release_count + 1
        if
          self ~= canary_lease
          or serializer_canary.held ~= true
          or not rawequal(serializer_canary.active, canary_lease)
        then
          row.held_violations = row.held_violations + 1
        end
        serializer_canary.held = false
        serializer_canary.active = nil
        append_event("release")
        cached_value = true
        cached_error = nil
        return cached_value, cached_error
      end

      local native_lstat = vim.uv.fs_lstat
      local native_open = vim.uv.fs_open
      local native_close = vim.uv.fs_close
      local native_fstat = vim.uv.fs_fstat
      local native_fsync = vim.uv.fs_fsync
      local native_rename = vim.uv.fs_rename
      local native_scandir = vim.uv.fs_scandir
      local native_hash = vim.fn.sha256
      expected_dirty_storage = "copy:" .. native_hash("dirty\n")

      local function lstat(path)
        note_dependency("lstat")
        local stat, stat_error, stat_code = native_lstat(path)
        if path == fixture.state and serializer_canary.acquire_count == 0 and stat then
          row.pre_acquire_state_samples = row.pre_acquire_state_samples + 1
          if not pre_acquire_state_stat then
            pre_acquire_state_stat = stat
          end
        end
        if
          inject_inode_drift
          and path == fixture.state
          and serializer_canary.held
          and row.drift_injections == 0
          and pre_acquire_state_stat
          and stat
        then
          local expected_state_identity
          for level = 2, 8 do
            for index = 1, 64 do
              local ok, name, value = pcall(debug.getlocal, level, index)
              if not ok or name == nil then
                break
              end
              if name == "expected_state" then
                row.expected_state_named_locals = row.expected_state_named_locals + 1
                if
                  type(value) == "table"
                  and value.path == fixture.state
                  and rawequal(value.stat, pre_acquire_state_stat)
                then
                  if not expected_state_identity then
                    expected_state_identity = value
                  end
                  if rawequal(value, expected_state_identity) then
                    row.expected_state_exact_locals = row.expected_state_exact_locals + 1
                  end
                end
              end
            end
          end
          stat = vim.deepcopy(stat)
          stat.ino = stat.ino == 0 and 1 or 0
          row.drift_injections = row.drift_injections + 1
        end
        return stat, stat_error, stat_code
      end

      local function descriptor_role(path, flags)
        if flags == "wx" then
          return path:sub(-#"/manifest.json") == "/manifest.json" and "manifest-file"
            or "copied-file"
        end
        if path == reviews_path then
          return "reviews-dir"
        end
        if path:sub(-#"/objects") == "/objects" then
          return "objects-dir"
        end
        if path:find("/.publishing-", 1, true) then
          return "publication-dir"
        end
        return "read-file"
      end

      local function open(path, flags, mode)
        note_dependency("open")
        local fd, open_error, open_code = native_open(path, flags, mode)
        if fd ~= nil then
          if row.active[fd] ~= nil then
            row.live_generation_reuse = row.live_generation_reuse + 1
          end
          local generation = (row.generations[fd] or 0) + 1
          row.generations[fd] = generation
          local lifetime = {
            generation = generation,
            role = descriptor_role(path, flags),
            close_attempts = 0,
            physical_closes = 0,
            active = true,
          }
          table.insert(row.descriptors, lifetime)
          row.active[fd] = lifetime
          if serializer_canary.acquire_count > 0 then
            row.open_flags[flags] = (row.open_flags[flags] or 0) + 1
          end
        end
        return fd, open_error, open_code
      end

      local function close(fd)
        note_dependency("close")
        local lifetime = row.active[fd]
        if lifetime then
          lifetime.close_attempts = lifetime.close_attempts + 1
        else
          row.unowned_closes = row.unowned_closes + 1
        end
        local closed, close_error, close_code = native_close(fd)
        if lifetime and closed == true then
          lifetime.physical_closes = lifetime.physical_closes + 1
          lifetime.active = false
          if row.active[fd] == lifetime then
            row.active[fd] = nil
          end
          if load_started and not close_after_load then
            close_after_load = true
            append_event("close")
          end
        end
        return closed, close_error, close_code
      end

      local function fsync(fd)
        note_dependency("fsync")
        local synced, sync_error, sync_code = native_fsync(fd)
        if synced == true then
          local lifetime = row.active[fd]
          local role = lifetime and lifetime.role or "invalid"
          row.fsync_roles[role] = (row.fsync_roles[role] or 0) + 1
          if not sync_started then
            sync_started = true
            append_event("sync")
          end
        end
        return synced, sync_error, sync_code
      end

      local mutation_native = {
        mkdir = vim.uv.fs_mkdir,
        write = vim.uv.fs_write,
        unlink = vim.uv.fs_unlink,
        rmdir = vim.uv.fs_rmdir,
      }
      local function mutation(name)
        return function(...)
          note_dependency(name)
          row.mutation_counts[name] = row.mutation_counts[name] + 1
          if not mutation_started then
            mutation_started = true
            append_event("mutation")
          end
          return mutation_native[name](...)
        end
      end

      local function rename(source, target)
        note_dependency("rename")
        row.mutation_counts.rename = row.mutation_counts.rename + 1
        if not mutation_started then
          mutation_started = true
          append_event("mutation")
        end
        local renamed, rename_error, rename_code = native_rename(source, target)
        if
          renamed == true
          and source:find("/.publishing-", 1, true)
          and not publication_complete
        then
          publication_complete = true
          append_event("publish")
        end
        return renamed, rename_error, rename_code
      end

      local function tail_is(argv, expected)
        if #argv < #expected then
          return false
        end
        local offset = #argv - #expected
        for index, value in ipairs(expected) do
          if argv[offset + index] ~= value then
            return false
          end
        end
        return true
      end

      local function system(argv, options)
        note_dependency("system")
        local result = vim.system(argv, options):wait(30000)
        if
          result.code == 0
          and type(result.stdout) == "string"
          and serializer_canary.acquire_count == 0
          and tail_is(argv, { "ls-tree", "-rz", "--full-tree", "HEAD" })
        then
          for record in result.stdout:gmatch("([^%z]+)%z") do
            local object_id, path = record:match("^%d+ %S+ ([0-9a-f]+)\t(.+)$")
            if path == "clean.txt" then
              expected_clean_storage = "tree:" .. object_id
            elseif path == "linked" then
              expected_link_storage = "tree:" .. object_id
            end
          end
        end
        if tail_is(argv, { "rev-parse", "--verify", "HEAD^{tree}" }) and result.code == 0 then
          head_tree = result.stdout:match("^([0-9a-f]+)\n?$")
        end
        if serializer_canary.held and publication_complete then
          if not verification_complete then
            if tail_is(argv, { "rev-parse", "--verify", "HEAD^{tree}" }) then
              row.git_counts.verify_rev_parse = row.git_counts.verify_rev_parse + 1
            elseif tail_is(argv, { "ls-tree", "-rz", "--full-tree", "HEAD" }) then
              row.git_counts.verify_ls_tree = row.git_counts.verify_ls_tree + 1
            elseif
              tail_is(argv, { "ls-files", "-z", "--stage" })
              or tail_is(argv, { "ls-files", "-z", "--others", "--exclude-standard" })
              or tail_is(argv, { "ls-files", "-z", "--others", "--ignored", "--exclude-standard" })
            then
              row.git_counts.verify_ls_files = row.git_counts.verify_ls_files + 1
            elseif
              tail_is(argv, {
                "diff",
                "--cached",
                "--no-ext-diff",
                "--no-textconv",
                "--name-only",
                "-z",
                "--diff-filter=ACDMRTUXB",
              })
            then
              row.git_counts.verify_diff = row.git_counts.verify_diff + 1
            end
          elseif
            tail_is(argv, { "cat-file", "blob", argv[#argv] })
            or tail_is(argv, { "cat-file", "--batch" })
          then
            row.git_counts.load_cat_file = row.git_counts.load_cat_file + 1
          end
        end
        local ignored_tail = {
          "ls-files",
          "-z",
          "--others",
          "--ignored",
          "--exclude-standard",
        }
        if
          result.code == 0
          and tail_is(argv, ignored_tail)
          and capture_path_seen
          and serializer_canary.acquire_count == 0
          and not capture_complete
        then
          capture_complete = true
          append_event("capture")
        elseif
          result.code == 0
          and tail_is(argv, ignored_tail)
          and publication_complete
          and serializer_canary.held
          and not verification_complete
        then
          verification_complete = true
          append_event("verify")
        end
        return result
      end

      local function hash(bytes)
        note_dependency("hash")
        local digest = native_hash(bytes)
        local expected_input = head_tree
          and table.concat({
            identity.key,
            tostring(fixed_pid),
            tostring(fixed_hrtime),
            head_tree,
          }, "\0")
        if
          capture_complete
          and not review_id_generated
          and serializer_canary.acquire_count == 0
          and bytes == expected_input
        then
          review_id_generated = true
          review_id = digest:sub(1, 32)
          append_event("review-id")
        end
        return digest
      end

      local function scandir(path)
        note_dependency("scandir")
        local scanner, scan_error, scan_code = native_scandir(path)
        if
          scanner
          and review_id
          and path == vim.fs.joinpath(reviews_path, review_id)
          and verification_complete
          and not load_started
        then
          load_started = true
          append_event("load")
        end
        return scanner, scan_error, scan_code
      end

      local function fd_path(fd)
        note_dependency("fd_path")
        for _, prefix in ipairs({ "/proc/self/fd/", "/dev/fd/" }) do
          local path = prefix .. tostring(fd)
          if native_lstat(path) then
            return path
          end
        end
        return nil, "stable directory descriptor path is unavailable"
      end

      local overrides = {
        serialization = serializer_canary,
        lstat = lstat,
        open = open,
        close = close,
        fsync = fsync,
        rename = rename,
        scandir = scandir,
        hash = hash,
        system = system,
        fd_path = fd_path,
        mkdir = mutation("mkdir"),
        write = mutation("write"),
        unlink = mutation("unlink"),
        rmdir = mutation("rmdir"),
        realpath = function(...)
          note_dependency("realpath")
          return vim.uv.fs_realpath(...)
        end,
        readlink = function(...)
          note_dependency("readlink")
          return vim.uv.fs_readlink(...)
        end,
        fstat = function(...)
          note_dependency("fstat")
          return vim.uv.fs_fstat(...)
        end,
        read = function(...)
          note_dependency("read")
          return vim.uv.fs_read(...)
        end,
        scandir_next = function(...)
          note_dependency("scandir_next")
          return vim.uv.fs_scandir_next(...)
        end,
        uid = function()
          note_dependency("uid")
          return vim.uv.getuid()
        end,
        pid = function()
          note_dependency("pid")
          return fixed_pid
        end,
        hrtime = function()
          note_dependency("hrtime")
          return fixed_hrtime
        end,
        resolve_git = function()
          note_dependency("resolve_git")
          return git_executable
        end,
        revalidate_git = function(path)
          note_dependency("revalidate_git")
          return path == git_executable
        end,
        after_read = function(path, bytes)
          note_dependency("after_read")
          if
            serializer_canary.acquire_count == 0
            and path == fixture:path("dirty.txt")
            and bytes == "dirty\n"
          then
            capture_path_seen = true
          end
        end,
      }
      for name, fn in pairs(overrides) do
        expected_dependencies[name] = fn
      end

      local publication = baseline_module._test.new(overrides)
      local final_fstat_exact
      local protected_ok = xpcall(function()
        row.reviews_before = snapshot_tree(reviews_path)
        row.value, row.error = publication.create(identity, store)
        final_fstat_exact = true
        for fd in pairs(row.generations) do
          local final_stat, _, final_code = native_fstat(fd)
          final_fstat_exact = final_fstat_exact and final_stat == nil and final_code == "EBADF"
        end
        row.reviews_after = snapshot_tree(reviews_path)
      end, function()
        return "protected exercise raised"
      end)
      if serializer_canary.held then
        row.rescue_count = row.rescue_count + 1
        local rescued = pcall(function()
          return canary_lease:release()
        end)
        if not rescued then
          table.insert(failures, label .. " rescue release failed")
        end
      end

      local invalid_lifetimes = 0
      for _, lifetime in ipairs(row.descriptors) do
        if
          lifetime.close_attempts ~= 1
          or lifetime.physical_closes ~= 1
          or lifetime.active ~= false
        then
          invalid_lifetimes = invalid_lifetimes + 1
        end
      end
      local descriptor_harness_exact = invalid_lifetimes == 0
        and final_fstat_exact
        and row.live_generation_reuse == 0
        and row.unowned_closes == 0
        and next(row.active) == nil
      if not protected_ok then
        table.insert(failures, label .. " protected exercise raised")
      end
      if not descriptor_harness_exact then
        table.insert(failures, label .. " descriptor harness mismatch")
      end

      local required_dependencies_exact = true
      if not inject_inode_drift then
        for _, name in ipairs(required_post_acquire) do
          required_dependencies_exact = required_dependencies_exact
            and (row.dependencies[name] or 0) > 0
        end
      end
      local result_kind = row.value ~= nil and "success" or "nil"
      local error_kind = row.error == nil and "nil"
        or row.error == expected_error and "expected"
        or "unexpected"
      local baseline_ok, baseline_exact = pcall(function()
        if inject_inode_drift then
          return row.value == nil
        end
        if type(row.value) ~= "table" then
          return false
        end
        local clean = row.value:read("clean.txt")
        local dirty = row.value:read("dirty.txt")
        local linked = row.value:read("linked")
        return row.value:id() == review_id
          and type(clean) == "table"
          and type(expected_clean_storage) == "string"
          and clean.storage == expected_clean_storage
          and row.value:bytes("clean.txt") == "clean\n"
          and type(dirty) == "table"
          and dirty.storage == expected_dirty_storage
          and row.value:bytes("dirty.txt") == "dirty\n"
          and type(linked) == "table"
          and linked.kind == "symlink"
          and type(expected_link_storage) == "string"
          and linked.storage == expected_link_storage
          and row.value:bytes("linked") == "clean.txt"
      end)
      baseline_exact = baseline_ok and baseline_exact == true
      local reviews_same = protected_ok and vim.deep_equal(row.reviews_before, row.reviews_after)
      local expected_mutations = inject_inode_drift
          and { mkdir = 0, rename = 0, write = 0, unlink = 0, rmdir = 0 }
        or { mkdir = 1, rename = 2, write = 2, unlink = 0, rmdir = 0 }
      local expected_fsync = inject_inode_drift and {}
        or {
          ["copied-file"] = 1,
          ["manifest-file"] = 1,
          ["objects-dir"] = 1,
          ["publication-dir"] = 1,
          ["reviews-dir"] = 1,
        }
      local fsync_exact = exact_counts(row.fsync_roles, expected_fsync)
      if inject_inode_drift then
        fsync_exact = fsync_exact and next(row.fsync_roles) == nil
      else
        fsync_exact = fsync_exact
          and row.fsync_roles.invalid == nil
          and #vim.tbl_keys(row.fsync_roles) == 5
      end
      local expected_git = inject_inode_drift
          and {
            verify_rev_parse = 0,
            verify_ls_tree = 0,
            verify_ls_files = 0,
            verify_diff = 0,
            load_cat_file = 0,
          }
        or {
          verify_rev_parse = 1,
          verify_ls_tree = 1,
          verify_ls_files = 3,
          verify_diff = 1,
          load_cat_file = 1,
        }
      local contract_exact = protected_ok
        and descriptor_harness_exact
        and serializer_canary.acquire_count == 1
        and serializer_canary.release_count == 1
        and serializer_canary.physical_release_count == 1
        and serializer_canary.held == false
        and serializer_canary.active == nil
        and serializer_canary.root_exact
        and serializer_canary.dependency_argument_exact
        and serializer_canary.acquisition_order_exact
        and row.rescue_count == 0
        and row.pre_acquire_state_samples == 1
        and row.expected_state_named_locals == (inject_inode_drift and 4 or 0)
        and row.expected_state_exact_locals == (inject_inode_drift and 4 or 0)
        and row.held_violations == 0
        and row.after_release_calls == 0
        and row.state_dir_calls == (inject_inode_drift and 2 or 3)
        and row.review_dir_calls == (inject_inode_drift and 0 or 1)
        and row.lease_named_locals == (inject_inode_drift and 0 or 3)
        and row.lease_exact_locals == (inject_inode_drift and 0 or 3)
        and row.drift_injections == (inject_inode_drift and 1 or 0)
        and result_kind == (inject_inode_drift and "nil" or "success")
        and error_kind == (inject_inode_drift and "expected" or "nil")
        and baseline_exact
        and exact_counts(row.mutation_counts, expected_mutations)
        and row.open_flags.wx == (inject_inode_drift and 0 or 2)
        and row.open_flags.r == (inject_inode_drift and 0 or 7)
        and fsync_exact
        and exact_counts(row.git_counts, expected_git)
        and #row.descriptors == (inject_inode_drift and 4 or 13)
        and (row.dependencies.close or 0) == (inject_inode_drift and 0 or 9)
        and required_dependencies_exact
        and (not inject_inode_drift or reviews_same)
        and exact_tokens(row.events, inject_inode_drift and drift_events or success_events)
      if not contract_exact then
        table.insert(failures, label .. " contract mismatch")
      end

      local event_summary = #row.events == 0 and "none" or table.concat(row.events, ",")
      table.insert(
        observations,
        string.format(
          "%s=%s/%s acquire=%d deps=%s release=%d/%d rescue=%d held=%s pre=%d expected=%d/%d state=%d review=%d lease=%d/%d drift=%d mutations=%d/%d/%d/%d/%d opens=%d/%d fsync=%d git=%d/%d/%d/%d/%d descriptors=%d/%d fstat=%s baseline=%s violations=%d/%d snapshot=%s events=%s",
          label,
          result_kind,
          error_kind,
          serializer_canary.acquire_count,
          tostring(serializer_canary.dependency_argument_exact),
          serializer_canary.release_count,
          serializer_canary.physical_release_count,
          row.rescue_count,
          tostring(serializer_canary.held),
          row.pre_acquire_state_samples,
          row.expected_state_named_locals,
          row.expected_state_exact_locals,
          row.state_dir_calls,
          row.review_dir_calls,
          row.lease_named_locals,
          row.lease_exact_locals,
          row.drift_injections,
          row.mutation_counts.mkdir,
          row.mutation_counts.rename,
          row.mutation_counts.write,
          row.mutation_counts.unlink,
          row.mutation_counts.rmdir,
          row.open_flags.wx,
          row.open_flags.r,
          vim.tbl_count(row.fsync_roles),
          row.git_counts.verify_rev_parse,
          row.git_counts.verify_ls_tree,
          row.git_counts.verify_ls_files,
          row.git_counts.verify_diff,
          row.git_counts.load_cat_file,
          #row.descriptors,
          row.dependencies.close or 0,
          tostring(final_fstat_exact),
          tostring(baseline_exact),
          row.held_violations,
          row.after_release_calls,
          tostring(reviews_same),
          event_summary
        )
      )
      return {
        publication = publication,
      }
    end

    local success = execute_row("success", false)
    execute_row("inode", true)

    local create_under_lease = named_upvalue(success.publication.create, "create_under_lease")
    local publish = named_upvalue(create_under_lease, "publish")
    local state_location = named_upvalue(publish, "state_location")
    local same_state_root = named_upvalue(state_location, "same_state_root")
    local edge_count = 0
    for _, value in ipairs({ create_under_lease, publish, state_location, same_state_root }) do
      if type(value) == "function" then
        edge_count = edge_count + 1
      end
    end
    local equal_exact = false
    local drift_exact = 0
    local missing_field_exact = 0
    local typed_field_exact = 0
    local malformed_exact = false
    local unrelated_exact = false
    if type(same_state_root) == "function" then
      local expected = {
        path = "/cycle4b-state",
        stat = {
          dev = 11,
          ino = 12,
          uid = 13,
          type = "directory",
          mode = 16832,
          gid = 14,
          nlink = 2,
          size = 64,
          mtime = { sec = 15, nsec = 16 },
          ctime = { sec = 17, nsec = 18 },
        },
      }
      equal_exact = same_state_root(copy(expected), copy(expected)) == true
      local drifts = {
        { scope = "root", field = "path", value = "/cycle4b-other", invalid = 17 },
        { scope = "stat", field = "dev", value = 21, invalid = "11" },
        { scope = "stat", field = "ino", value = 22, invalid = "12" },
        { scope = "stat", field = "uid", value = 23, invalid = "13" },
        { scope = "stat", field = "type", value = "file", invalid = 14 },
        { scope = "stat", field = "mode", value = 16896, invalid = "16832" },
      }
      for _, drift in ipairs(drifts) do
        local fresh = copy(expected)
        if drift.scope == "root" then
          fresh[drift.field] = drift.value
        else
          fresh.stat[drift.field] = drift.value
        end
        if
          same_state_root(expected, fresh) == false
          and same_state_root(fresh, expected) == false
        then
          drift_exact = drift_exact + 1
        end

        local missing = copy(expected)
        if drift.scope == "root" then
          missing[drift.field] = nil
        else
          missing.stat[drift.field] = nil
        end
        if
          same_state_root(expected, missing) == false
          and same_state_root(missing, expected) == false
          and same_state_root(missing, copy(missing)) == false
        then
          missing_field_exact = missing_field_exact + 1
        end

        local invalid = copy(expected)
        if drift.scope == "root" then
          invalid[drift.field] = drift.invalid
        else
          invalid.stat[drift.field] = drift.invalid
        end
        if
          same_state_root(expected, invalid) == false
          and same_state_root(invalid, expected) == false
          and same_state_root(invalid, copy(invalid)) == false
        then
          typed_field_exact = typed_field_exact + 1
        end
      end
      local missing_stat = { path = expected.path }
      local empty_stat = { path = expected.path, stat = {} }
      malformed_exact = same_state_root(nil, nil) == false
        and same_state_root(expected, nil) == false
        and same_state_root(nil, expected) == false
        and same_state_root({}, {}) == false
        and same_state_root(expected, {}) == false
        and same_state_root({}, expected) == false
        and same_state_root(expected, missing_stat) == false
        and same_state_root(missing_stat, expected) == false
        and same_state_root(missing_stat, copy(missing_stat)) == false
        and same_state_root(expected, empty_stat) == false
        and same_state_root(empty_stat, expected) == false
        and same_state_root(empty_stat, copy(empty_stat)) == false
      local unrelated = copy(expected)
      unrelated.stat.gid = 24
      unrelated.stat.nlink = 3
      unrelated.stat.size = 65
      unrelated.stat.mtime = { sec = 25, nsec = 26 }
      unrelated.stat.ctime = { sec = 27, nsec = 28 }
      unrelated_exact = same_state_root(expected, unrelated) == true
        and same_state_root(unrelated, expected) == true
    end
    local predicate_exact = edge_count == 4
      and equal_exact
      and drift_exact == 6
      and missing_field_exact == 6
      and typed_field_exact == 6
      and malformed_exact
      and unrelated_exact
    if not predicate_exact then
      table.insert(failures, "state-root predicate contract mismatch")
    end
    table.insert(
      observations,
      string.format(
        "predicate=edges:%d/4 equal:%s drifts:%d/6 missing=%d/6 typed=%d/6 malformed:%s unrelated:%s",
        edge_count,
        tostring(equal_exact),
        drift_exact,
        missing_field_exact,
        typed_field_exact,
        tostring(malformed_exact),
        tostring(unrelated_exact)
      )
    )

    assert(
      #failures == 0,
      "Cycle 4B publication lease failures: "
        .. table.concat(failures, "; ")
        .. " | observations: "
        .. table.concat(observations, "; ")
    )
  end

  do
    local expected_errors = {
      ["git-stability"] = "Git-visible paths changed before baseline capture completed",
      ["load-failure"] = "could not scan baseline storage: injected Cycle 4C load failure",
    }
    local prefixes = {
      ["git-stability"] = {
        "capture",
        "review-id",
        "acquire",
        "state-refresh",
        "review-dir",
        "publish",
        "git-fault",
        "verify-enumerated",
      },
      ["load-failure"] = {
        "capture",
        "review-id",
        "acquire",
        "state-refresh",
        "review-dir",
        "publish",
        "verify",
        "load-fault",
      },
    }
    local cleanup_suffix = {
      "cleanup",
      "open-reviews",
      "claim-review",
      "open-review",
      "open-objects",
      "claim-object",
      "claim-manifest",
      "unlink-object",
      "fsync-objects",
      "claim-objects-dir",
      "rmdir-objects",
      "close-objects",
      "unlink-manifest",
      "fsync-review",
      "claim-review-dir",
      "rmdir-review",
      "close-review",
      "fsync-reviews",
      "close-reviews",
      "release",
    }
    local dependency_names = {
      "lstat",
      "realpath",
      "readlink",
      "open",
      "fstat",
      "read",
      "write",
      "fsync",
      "close",
      "mkdir",
      "unlink",
      "rmdir",
      "rename",
      "scandir",
      "scandir_next",
      "hash",
      "uid",
      "pid",
      "hrtime",
      "resolve_git",
      "revalidate_git",
      "system",
      "fd_path",
      "after_read",
    }
    local findings = {}
    local observations = {}

    local function exact(actual, expected)
      if #actual ~= #expected then
        return false
      end
      for index, value in ipairs(expected) do
        if actual[index] ~= value then
          return false
        end
      end
      return true
    end
    local function named_upvalue(fn, target)
      if type(fn) ~= "function" then
        return nil
      end
      for index = 1, 64 do
        local ok, name, value = pcall(debug.getupvalue, fn, index)
        if not ok or name == nil then
          break
        end
        if name == target then
          return value
        end
      end
      return nil
    end
    local function run_row(label)
      local fixture = Fixture.new("cleanup-lease-" .. label)
      fixture:write("dirty.txt", "committed\n")
      fixture:commit("cleanup lease")
      fixture:write("dirty.txt", "dirty\n")
      local identity = fixture:identity()
      local reviews_path = vim.fs.joinpath(fixture.state, "reviews")
      local native = {
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
        resolve_git = function()
          return git_executable
        end,
        revalidate_git = require("ai.tools").revalidate,
      }
      local row = {
        events = {},
        calls = {},
        mutations = { mkdir = 0, rename = 0, write = 0, unlink = 0, rmdir = 0 },
        cleanup = { open = 0, rename = 0, unlink = 0, rmdir = 0, fsync = 0, close = 0 },
        cleanup_fsync = {},
        git = { rev_parse = 0, ls_tree = 0, ls_files = 0, diff = 0, cat_file = 0 },
        flags = { r = 0, wx = 0 },
        post_flags = { r = 0, wx = 0 },
        descriptors = {},
        active = {},
        generations = {},
        state_calls = 0,
        review_calls = 0,
        held_violations = 0,
        after_release_calls = 0,
        live_reuse = 0,
        unowned_closes = 0,
        frame_count = 0,
        slot3_exact = false,
        slot4_exact = false,
        rescue = 0,
      }
      local canary_lease = {}
      local serializer = {
        acquire_count = 0,
        release_count = 0,
        physical_release_count = 0,
        held = false,
        dependency_exact = false,
        root_exact = false,
        recursive = false,
      }
      local acquired_dependencies
      local expected_dependencies
      local release_consumed = false
      local release_value, release_error
      local capture_ignored = 0
      local captured = false
      local review_id
      local published = false
      local verified = false
      local failed = false
      local cleanup_seen = false
      local cleanup_function
      local overall_fsync = 0
      local pre_descriptors = 0
      local post_descriptors = 0
      local final_fstat_exact = false
      local function event(value)
        table.insert(row.events, value)
      end
      local function note(name)
        row.calls[name] = (row.calls[name] or 0) + 1
        if serializer.acquire_count == 0 then
          return
        end
        if serializer.release_count > 0 then
          row.after_release_calls = row.after_release_calls + 1
        elseif serializer.held ~= true or not rawequal(serializer.active, canary_lease) then
          row.held_violations = row.held_violations + 1
        end
      end

      local function probe_cleanup_frame()
        if cleanup_seen then
          return
        end
        cleanup_seen = true
        event("cleanup")
        for level = 2, 8 do
          local info_ok, info = pcall(debug.getinfo, level, "f")
          if info_ok and info and rawequal(info.func, cleanup_function) then
            row.frame_count = row.frame_count + 1
            local slot3_ok, slot3_name, slot3 = pcall(debug.getlocal, level, 3)
            local slot4_ok, slot4_name, slot4 = pcall(debug.getlocal, level, 4)
            row.slot3_exact = slot3_ok and slot3_name == "lease" and rawequal(slot3, canary_lease)
            row.slot4_exact = slot4_ok
              and slot4_name == "deps_for_cleanup"
              and rawequal(slot4, acquired_dependencies)
          end
        end
      end

      local real_store = fixture:store()
      local store = {}
      function store:state_dir()
        row.state_calls = row.state_calls + 1
        if serializer.held and row.state_calls == 2 then
          event("state-refresh")
        end
        return real_store:state_dir()
      end
      function store:review_dir(candidate)
        row.review_calls = row.review_calls + 1
        event("review-dir")
        row.review_id = candidate
        row.review_path = vim.fs.joinpath(reviews_path, candidate)
        return real_store:review_dir(candidate)
      end

      function serializer.acquire(root, dependencies)
        serializer.acquire_count = serializer.acquire_count + 1
        if serializer.acquire_count ~= 1 or serializer.held then
          serializer.recursive = true
          return nil, "recursive test acquisition"
        end
        serializer.root_exact = root == fixture.state
        acquired_dependencies = dependencies
        local matches = type(dependencies) == "table"
          and dependencies.serialization == serializer
          and vim.tbl_count(dependencies) == #dependency_names + 1
        for _, name in ipairs(dependency_names) do
          matches = matches and dependencies[name] == expected_dependencies[name]
        end
        serializer.dependency_exact = matches
        serializer.held = true
        serializer.active = canary_lease
        event("acquire")
        return canary_lease
      end

      function canary_lease:release()
        serializer.release_count = serializer.release_count + 1
        if release_consumed then
          return release_value, release_error
        end
        release_consumed = true
        serializer.physical_release_count = serializer.physical_release_count + 1
        row.release_cleanup_exact = row.cleanup.open == 3
          and row.cleanup.rename == 5
          and row.cleanup.unlink == 2
          and row.cleanup.rmdir == 2
          and row.cleanup.fsync == 3
          and row.cleanup.close == 3
          and next(row.active) == nil
        if
          self ~= canary_lease
          or serializer.held ~= true
          or not rawequal(serializer.active, canary_lease)
        then
          row.held_violations = row.held_violations + 1
        end
        serializer.held = false
        serializer.active = nil
        event("release")
        release_value = true
        return release_value, release_error
      end

      local function role(path, flags)
        if flags == "wx" then
          return path:sub(-#"/manifest.json") == "/manifest.json" and "manifest" or "object"
        end
        if path == reviews_path then
          return "reviews"
        end
        if path:sub(-#"/objects") == "/objects" then
          return "objects"
        end
        if path:find("/.cleanup-", 1, true) then
          return "review"
        end
        if path:find("/.publishing-", 1, true) then
          return "publication"
        end
        return "file"
      end

      local function open(path, flags, mode)
        note("open")
        local fd, err, code = native.open(path, flags, mode)
        if fd ~= nil then
          if row.active[fd] then
            row.live_reuse = row.live_reuse + 1
          end
          local generation = (row.generations[fd] or 0) + 1
          row.generations[fd] = generation
          local lifetime = {
            role = role(path, flags),
            generation = generation,
            attempts = 0,
            closes = 0,
            active = true,
          }
          table.insert(row.descriptors, lifetime)
          row.active[fd] = lifetime
          row.flags[flags] = (row.flags[flags] or 0) + 1
          if serializer.acquire_count == 0 then
            pre_descriptors = pre_descriptors + 1
          else
            post_descriptors = post_descriptors + 1
            row.post_flags[flags] = (row.post_flags[flags] or 0) + 1
          end
          if failed then
            row.cleanup.open = row.cleanup.open + 1
            event("open-" .. lifetime.role)
          end
        end
        return fd, err, code
      end

      local function close(fd)
        note("close")
        local lifetime = row.active[fd]
        if lifetime then
          lifetime.attempts = lifetime.attempts + 1
        else
          row.unowned_closes = row.unowned_closes + 1
        end
        local closed, err, code = native.close(fd)
        if lifetime and closed == true then
          lifetime.closes = lifetime.closes + 1
          lifetime.active = false
          if row.active[fd] == lifetime then
            row.active[fd] = nil
          end
          if failed then
            row.cleanup.close = row.cleanup.close + 1
            event("close-" .. lifetime.role)
          end
        end
        return closed, err, code
      end

      local function fsync(fd)
        note("fsync")
        local synced, err, code = native.fsync(fd)
        if synced == true then
          overall_fsync = overall_fsync + 1
          if failed then
            row.cleanup.fsync = row.cleanup.fsync + 1
            local lifetime = row.active[fd]
            local sync_role = lifetime and lifetime.role or "invalid"
            row.cleanup_fsync[sync_role] = (row.cleanup_fsync[sync_role] or 0) + 1
            event("fsync-" .. sync_role)
          end
        end
        return synced, err, code
      end

      local function mutation(name)
        return function(...)
          note(name)
          local value, err, code = native[name](...)
          local succeeded = name == "write" and type(value) == "number" and value > 0
            or name ~= "write" and value == true
          if succeeded then
            row.mutations[name] = row.mutations[name] + 1
            if failed and (name == "unlink" or name == "rmdir") then
              row.cleanup[name] = row.cleanup[name] + 1
              local path = select(1, ...)
              local suffix
              if name == "unlink" then
                suffix = path:find("manifest", 1, true) and "manifest" or "object"
              else
                suffix = path:find("objects", 1, true) and "objects" or "review"
              end
              event(name .. "-" .. suffix)
            end
          end
          return value, err, code
        end
      end

      local function rename(source, target)
        note("rename")
        local renamed, err, code = native.rename(source, target)
        if renamed == true then
          row.mutations.rename = row.mutations.rename + 1
          if failed then
            row.cleanup.rename = row.cleanup.rename + 1
            local token = target:find(".owned-cleanup-manifest-", 1, true) and "claim-manifest"
              or target:find(".owned-cleanup-objects-", 1, true) and "claim-objects-dir"
              or target:find(".owned-cleanup-review-", 1, true) and "claim-review-dir"
              or target:find(".owned-cleanup-", 1, true) and "claim-object"
              or "claim-review"
            event(token)
          elseif source:find("/.publishing-", 1, true) then
            published = true
            event("publish")
          end
        end
        return renamed, err, code
      end

      local function tail(argv, expected)
        if #argv < #expected then
          return false
        end
        local offset = #argv - #expected
        for index, value in ipairs(expected) do
          if argv[offset + index] ~= value then
            return false
          end
        end
        return true
      end

      local ignored_tail = { "ls-files", "-z", "--others", "--ignored", "--exclude-standard" }
      local function system(argv, options)
        note("system")
        local result = vim.system(argv, options):wait(30000)
        if serializer.acquire_count == 0 and result.code == 0 and tail(argv, ignored_tail) then
          capture_ignored = capture_ignored + 1
          if capture_ignored == 2 then
            captured = true
            event("capture")
          end
        elseif serializer.held and published then
          if tail(argv, { "rev-parse", "--verify", "HEAD^{tree}" }) then
            row.git.rev_parse = row.git.rev_parse + 1
            if label == "git-stability" and not failed and result.code == 0 then
              local oid = result.stdout:match("^([0-9a-f]+)\n?$")
              if oid then
                local replacement = (oid:sub(1, 1) == "0" and "1" or "0") .. oid:sub(2)
                result = vim.tbl_extend("force", {}, result, { stdout = replacement .. "\n" })
                failed = true
                event("git-fault")
              end
            end
          elseif tail(argv, { "ls-tree", "-rz", "--full-tree", "HEAD" }) then
            row.git.ls_tree = row.git.ls_tree + 1
          elseif
            tail(argv, { "ls-files", "-z", "--stage" })
            or tail(argv, { "ls-files", "-z", "--others", "--exclude-standard" })
            or tail(argv, ignored_tail)
          then
            row.git.ls_files = row.git.ls_files + 1
          elseif
            tail(argv, {
              "diff",
              "--cached",
              "--no-ext-diff",
              "--no-textconv",
              "--name-only",
              "-z",
              "--diff-filter=ACDMRTUXB",
            })
          then
            row.git.diff = row.git.diff + 1
          elseif
            tail(argv, { "cat-file", "blob", argv[#argv] }) or tail(argv, { "cat-file", "--batch" })
          then
            row.git.cat_file = row.git.cat_file + 1
          end
          if tail(argv, ignored_tail) then
            verified = true
            event(label == "git-stability" and "verify-enumerated" or "verify")
          end
        end
        return result
      end

      local function lstat(path)
        note("lstat")
        if failed then
          probe_cleanup_frame()
        end
        return native.lstat(path)
      end

      local function scandir(path)
        note("scandir")
        if
          label == "load-failure"
          and serializer.held
          and verified
          and not failed
          and path == row.review_path
        then
          failed = true
          event("load-fault")
          return nil, "injected Cycle 4C load failure", "EIO"
        end
        return native.scandir(path)
      end

      local function hash(bytes)
        note("hash")
        local digest = native.hash(bytes)
        if captured and serializer.acquire_count == 0 and not review_id then
          review_id = digest:sub(1, 32)
          event("review-id")
        end
        return digest
      end

      local function fd_path(fd)
        note("fd_path")
        for _, prefix in ipairs({ "/proc/self/fd/", "/dev/fd/" }) do
          local path = prefix .. tostring(fd)
          if native.lstat(path) then
            return path
          end
        end
        return nil, "stable directory descriptor path is unavailable"
      end

      local overrides = {
        serialization = serializer,
        lstat = lstat,
        open = open,
        close = close,
        fsync = fsync,
        rename = rename,
        scandir = scandir,
        system = system,
        hash = hash,
        fd_path = fd_path,
        mkdir = mutation("mkdir"),
        write = mutation("write"),
        unlink = mutation("unlink"),
        rmdir = mutation("rmdir"),
      }
      for _, name in ipairs({
        "realpath",
        "readlink",
        "fstat",
        "read",
        "scandir_next",
        "uid",
        "resolve_git",
        "revalidate_git",
      }) do
        local dependency_name = name
        overrides[dependency_name] = function(...)
          note(dependency_name)
          return native[dependency_name](...)
        end
      end
      overrides.pid = function()
        note("pid")
        return 4304
      end
      overrides.hrtime = function()
        note("hrtime")
        return 4404
      end
      overrides.after_read = function()
        note("after_read")
      end
      expected_dependencies = overrides

      local publication = baseline_module._test.new(overrides)
      local create_under_lease = named_upvalue(publication.create, "create_under_lease")
      cleanup_function = named_upvalue(create_under_lease, "cleanup_publication")
      local status_before = fixture:status_bytes()
      local objects_before = fixture:object_count()
      local protected_ok = xpcall(function()
        local invoked, value, err = pcall(publication.create, identity, store)
        row.invoked = invoked
        if invoked then
          row.value = value
          row.error = err
        end
        final_fstat_exact = true
        for fd in pairs(row.generations) do
          local stat, _, code = native.fstat(fd)
          final_fstat_exact = final_fstat_exact and stat == nil and code == "EBADF"
        end
        local scanner = native.scandir(reviews_path)
        row.entries_empty = scanner ~= nil
        if scanner then
          local name, scan_error, scan_code = native.scandir_next(scanner)
          row.entries_empty = name == nil and scan_error == nil and scan_code == nil
        end
        local function absent(path)
          local stat, err, code = native.lstat(path)
          return stat == nil
            and (
              code == "ENOENT"
              or type(err) == "string"
                and (err:find("ENOENT", 1, true) or err:find("no such file", 1, true))
            )
        end
        row.residue_exact = row.review_id ~= nil
          and absent(row.review_path)
          and absent(vim.fs.joinpath(reviews_path, ".cleanup-" .. row.review_id))
          and absent(vim.fs.joinpath(reviews_path, ".owned-cleanup-review-" .. row.review_id))
        row.git_state_exact = fixture:status_bytes() == status_before
          and fixture:object_count() == objects_before
      end, function()
        return "protected exercise raised"
      end)

      if serializer.held then
        row.rescue = row.rescue + 1
        pcall(function()
          return canary_lease:release()
        end)
      end

      local invalid = 0
      for _, lifetime in ipairs(row.descriptors) do
        if lifetime.attempts ~= 1 or lifetime.closes ~= 1 or lifetime.active ~= false then
          invalid = invalid + 1
        end
      end
      local descriptor_exact = invalid == 0
        and #row.descriptors == 11
        and pre_descriptors == 2
        and post_descriptors == 9
        and row.flags.r == 9
        and row.flags.wx == 2
        and row.post_flags.r == 7
        and row.post_flags.wx == 2
        and row.live_reuse == 0
        and row.unowned_closes == 0
        and next(row.active) == nil
        and final_fstat_exact
      local cleanup_exact = row.cleanup.open == 3
        and row.cleanup.rename == 5
        and row.cleanup.unlink == 2
        and row.cleanup.rmdir == 2
        and row.cleanup.fsync == 3
        and row.cleanup.close == 3
        and row.cleanup_fsync.objects == 1
        and row.cleanup_fsync.review == 1
        and row.cleanup_fsync.reviews == 1
        and vim.tbl_count(row.cleanup_fsync) == 3
      local git_exact = row.git.rev_parse == 1
        and row.git.ls_tree == 1
        and row.git.ls_files == 3
        and row.git.diff == 1
        and row.git.cat_file == 0
      local frame_exact = row.frame_count == 1 and row.slot3_exact and row.slot4_exact
      if not frame_exact then
        table.insert(findings, label .. " cleanup lease identity mismatch")
      end
      local expected_events = vim.list_extend(vim.deepcopy(prefixes[label]), cleanup_suffix)
      local behavior_exact = protected_ok
        and row.invoked
        and row.value == nil
        and row.error == expected_errors[label]
        and type(cleanup_function) == "function"
        and serializer.acquire_count == 1
        and serializer.release_count == 1
        and serializer.physical_release_count == 1
        and serializer.root_exact
        and serializer.dependency_exact
        and not serializer.recursive
        and serializer.held == false
        and serializer.active == nil
        and row.rescue == 0
        and row.state_calls == (label == "git-stability" and 2 or 3)
        and row.review_calls == 1
        and row.held_violations == 0
        and row.after_release_calls == 0
        and descriptor_exact
        and row.mutations.mkdir == 1
        and row.mutations.rename == 7
        and row.mutations.write == 2
        and row.mutations.unlink == 2
        and row.mutations.rmdir == 2
        and overall_fsync == 8
        and cleanup_exact
        and git_exact
        and row.release_cleanup_exact
        and row.entries_empty
        and row.residue_exact
        and row.git_state_exact
        and exact(row.events, expected_events)
      if not behavior_exact then
        table.insert(findings, label .. " cleanup behavior mismatch")
      end

      table.insert(
        observations,
        string.format(
          "%s=nil/%s acquire=%d deps=%s release=%d/%d rescue=%d held=%s frame=%d/%s/%s state=%d review=%d descriptors=%d/%d/%d opens=%d/%d/%d/%d cleanup=%d/%d/%d/%d/%d/%d mutations=%d/%d/%d/%d/%d fsync=%d roles=%s git=%d/%d/%d/%d/%d fstat=%s release-order=%s residue=%s git-state=%s violations=%d/%d/%d/%d events=%s",
          label,
          row.error == expected_errors[label] and "expected" or "unexpected",
          serializer.acquire_count,
          tostring(serializer.dependency_exact),
          serializer.release_count,
          serializer.physical_release_count,
          row.rescue,
          tostring(serializer.held),
          row.frame_count,
          tostring(row.slot3_exact),
          tostring(row.slot4_exact),
          row.state_calls,
          row.review_calls,
          #row.descriptors,
          pre_descriptors,
          post_descriptors,
          row.flags.r,
          row.flags.wx,
          row.post_flags.r,
          row.post_flags.wx,
          row.cleanup.open,
          row.cleanup.rename,
          row.cleanup.unlink,
          row.cleanup.rmdir,
          row.cleanup.fsync,
          row.cleanup.close,
          row.mutations.mkdir,
          row.mutations.rename,
          row.mutations.write,
          row.mutations.unlink,
          row.mutations.rmdir,
          overall_fsync,
          tostring(cleanup_exact),
          row.git.rev_parse,
          row.git.ls_tree,
          row.git.ls_files,
          row.git.diff,
          row.git.cat_file,
          tostring(final_fstat_exact),
          tostring(row.release_cleanup_exact),
          tostring(row.residue_exact and row.entries_empty),
          tostring(row.git_state_exact),
          row.held_violations,
          row.after_release_calls,
          row.live_reuse,
          row.unowned_closes,
          table.concat(row.events, ",")
        )
      )
    end

    run_row("git-stability")
    run_row("load-failure")
    local diagnostic = "Cycle 4C cleanup lease failures: "
      .. table.concat(findings, "; ")
      .. " | observations: "
      .. table.concat(observations, "; ")
    assert(#diagnostic <= 1536, "Cycle 4C cleanup lease diagnostic overflow")
    assert(#findings == 0, diagnostic)
  end

  do
    local P = "could not scan baseline storage: injected Cycle 4D load failure"
    local R = "baseline serialization release failed: fsync-state-root (EIO)"
    local F = "baseline serialization release failed: validate-lock (UNKNOWN)"
    local PR = P .. "; " .. R
    local PF = P .. "; " .. F
    local VSR = "baseline serialization release failed: validate-state-root (UNKNOWN)"
    local LL = "baseline serialization release failed: lstat-lock (EIO)"
    local VL = "baseline serialization release failed: validate-lock (UNKNOWN)"
    local CL = "baseline serialization release failed: close-lock (EIO)"
    local RR = "baseline serialization release failed: rmdir-lock (EIO)"
    local VA = "baseline serialization release failed: verify-lock-absent (EIO)"
    local CS = "baseline serialization release failed: close-state-root (EIO)"
    local valid_max = table.concat({ VSR, LL, VL, LL, VL, CL, R, CS }, "; ")
    local valid_lstats = table.concat({ LL, LL }, "; ")
    local valid_validates = table.concat({ VL, VL, VL }, "; ")
    local valid_rmdir = table.concat({ CL, RR, R, CS }, "; ")
    local valid_absence = table.concat({ CL, VA, R, CS }, "; ")
    local invalid_nine = valid_max .. "; " .. CS
    local invalid_identity = table.concat({ LL, VL, VL, LL, VL }, "; ")
    local invalid_identity_order = table.concat({ LL, LL, VL, VL }, "; ")
    local invalid_order = R .. "; " .. CL
    local invalid_removals = RR .. "; " .. VA
    local invalid_validation_rmdir = LL .. "; " .. RR
    local invalid_validation_absence = VL .. "; " .. VA
    local invalid_state_rmdir = VSR .. "; " .. RR
    local invalid_state_absence = VSR .. "; " .. VA
    local invalid_duplicate_close = CL .. "; " .. CL
    local invalid_duplicate_state = VSR .. "; " .. VSR
    local invalid_duplicate_rmdir = RR .. "; " .. RR
    local invalid_duplicate_absence = VA .. "; " .. VA
    local invalid_duplicate_sync = R .. "; " .. R
    local invalid_duplicate_state_close = CS .. "; " .. CS
    local invalid_operation = "baseline serialization release failed: open-lock (EIO)"
    local valid_code = "baseline serialization release failed: close-lock (E"
      .. string.rep("A", 23)
      .. ")"
    local invalid_code = "baseline serialization release failed: close-lock (E"
      .. string.rep("A", 24)
      .. ")"
    local hostile_path = "/private/cycle4d/" .. string.rep("secret", 256)
    local dependency_names = {
      "lstat",
      "realpath",
      "readlink",
      "open",
      "fstat",
      "read",
      "write",
      "fsync",
      "close",
      "mkdir",
      "unlink",
      "rmdir",
      "rename",
      "scandir",
      "scandir_next",
      "hash",
      "uid",
      "pid",
      "hrtime",
      "resolve_git",
      "revalidate_git",
      "system",
      "fd_path",
      "after_read",
    }
    local expected_events = {
      ["primary-release"] = {
        "acquire",
        "review-dir",
        "publish",
        "load-fault",
        "cleanup",
        "release",
      },
      ["success-release"] = {
        "acquire",
        "review-dir",
        "publish",
        "load",
        "release",
      },
    }
    local findings = {}
    local harness_failures = {}
    local observations = {}

    local function exact(actual, expected)
      if #actual ~= #expected then
        return false
      end
      for index, value in ipairs(expected) do
        if actual[index] ~= value then
          return false
        end
      end
      return true
    end

    local function named_upvalue(fn, target)
      if type(fn) ~= "function" then
        return nil
      end
      for index = 1, 64 do
        local ok, name, value = pcall(debug.getupvalue, fn, index)
        if not ok or name == nil then
          break
        end
        if name == target then
          return value
        end
      end
      return nil
    end

    local native = {
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
      revalidate_git = require("ai.tools").revalidate,
    }

    local function execute_row(label)
      local inject_load = label == "primary-release"
      local fixture = Fixture.new("outer-result-" .. label)
      fixture:write("dirty.txt", "committed\n")
      fixture:commit("outer result")
      fixture:write("dirty.txt", "dirty\n")
      local identity = fixture:identity()
      local real_store = fixture:store()
      local reviews_path = vim.fs.joinpath(fixture.state, "reviews")
      local row = {
        events = {},
        descriptors = {},
        active = {},
        generations = {},
        acquire_count = 0,
        release_count = 0,
        physical_release_count = 0,
        review_calls = 0,
        fault_count = 0,
        held_violations = 0,
        after_release_calls = 0,
        live_reuse = 0,
        unowned_closes = 0,
        rescue = 0,
        open_acquires = 0,
      }
      local serializer = {}
      local canary_lease = {}
      local expected_dependencies
      local release_consumed = false
      local release_value
      local release_error
      local published = false
      local cleanup_seen = false

      local function event(token)
        table.insert(row.events, token)
      end

      local function note()
        if row.acquire_count == 0 then
          return
        end
        if row.release_count > 0 then
          row.after_release_calls = row.after_release_calls + 1
        elseif serializer.held ~= true or not rawequal(serializer.active, canary_lease) then
          row.held_violations = row.held_violations + 1
        end
      end

      local store = {}
      function store:state_dir()
        return real_store:state_dir()
      end
      function store:review_dir(review_id)
        row.review_calls = row.review_calls + 1
        row.review_id = review_id
        row.review_path = vim.fs.joinpath(reviews_path, review_id)
        event("review-dir")
        return real_store:review_dir(review_id)
      end

      function serializer.acquire(root, dependencies)
        row.acquire_count = row.acquire_count + 1
        serializer.root_exact = root == fixture.state
        local matches = type(dependencies) == "table" and dependencies.serialization == serializer
        for _, name in ipairs(dependency_names) do
          matches = matches and dependencies[name] == expected_dependencies[name]
        end
        serializer.dependency_exact = matches
        serializer.held = true
        serializer.active = canary_lease
        event("acquire")
        return canary_lease
      end

      function canary_lease:release()
        row.release_count = row.release_count + 1
        if release_consumed then
          return release_value, release_error
        end
        release_consumed = true
        row.physical_release_count = row.physical_release_count + 1
        row.release_after_close = next(row.active) == nil
        row.release_fstat_exact = true
        for fd in pairs(row.generations) do
          local stat, _, code = native.fstat(fd)
          row.release_fstat_exact = row.release_fstat_exact and stat == nil and code == "EBADF"
        end
        local entries = review_entries(fixture)
        row.release_state_exact = inject_load and #entries == 0
          or not inject_load and #entries == 1 and entries[1] == row.review_id
        if
          self ~= canary_lease
          or serializer.held ~= true
          or not rawequal(serializer.active, canary_lease)
        then
          row.held_violations = row.held_violations + 1
        end
        serializer.held = false
        serializer.active = nil
        event("release")
        release_value = nil
        release_error = R
        return release_value, release_error
      end

      local function open(pathname, flags, mode)
        note()
        local fd, err, code = native.open(pathname, flags, mode)
        if fd ~= nil then
          if row.active[fd] ~= nil then
            row.live_reuse = row.live_reuse + 1
          end
          local generation = (row.generations[fd] or 0) + 1
          row.generations[fd] = generation
          local lifetime = {
            generation = generation,
            close_attempts = 0,
            physical_closes = 0,
            active = true,
          }
          table.insert(row.descriptors, lifetime)
          row.active[fd] = lifetime
        end
        return fd, err, code
      end

      local function close(fd)
        note()
        local lifetime = row.active[fd]
        if lifetime then
          lifetime.close_attempts = lifetime.close_attempts + 1
        else
          row.unowned_closes = row.unowned_closes + 1
        end
        local closed, err, code = native.close(fd)
        if lifetime and closed == true then
          lifetime.physical_closes = lifetime.physical_closes + 1
          lifetime.active = false
          if row.active[fd] == lifetime then
            row.active[fd] = nil
          end
        end
        return closed, err, code
      end

      local function lstat(pathname)
        note()
        if row.fault_count > 0 and not cleanup_seen then
          cleanup_seen = true
          event("cleanup")
        end
        return native.lstat(pathname)
      end

      local function rename(source, target)
        note()
        local renamed, err, code = native.rename(source, target)
        if renamed == true and source:find("/.publishing-", 1, true) then
          published = true
          event("publish")
        end
        return renamed, err, code
      end

      local function scandir(pathname)
        note()
        if pathname == row.review_path and published then
          if inject_load and row.fault_count == 0 then
            row.fault_count = row.fault_count + 1
            event("load-fault")
            return nil, "injected Cycle 4D load failure", "EIO"
          end
          if not inject_load and not row.load_seen then
            row.load_seen = true
            event("load")
          end
        end
        return native.scandir(pathname)
      end

      local function fd_path(fd)
        note()
        for _, prefix in ipairs({ "/proc/self/fd/", "/dev/fd/" }) do
          local pathname = prefix .. tostring(fd)
          if native.lstat(pathname) then
            return pathname
          end
        end
        return nil, "stable directory descriptor path is unavailable"
      end

      local overrides = {
        serialization = serializer,
        lstat = lstat,
        open = open,
        close = close,
        rename = rename,
        scandir = scandir,
        fd_path = fd_path,
        realpath = function(...)
          note()
          return native.realpath(...)
        end,
        readlink = function(...)
          note()
          return native.readlink(...)
        end,
        fstat = function(...)
          note()
          return native.fstat(...)
        end,
        read = function(...)
          note()
          return native.read(...)
        end,
        write = function(...)
          note()
          return native.write(...)
        end,
        fsync = function(...)
          note()
          return native.fsync(...)
        end,
        mkdir = function(...)
          note()
          return native.mkdir(...)
        end,
        unlink = function(...)
          note()
          return native.unlink(...)
        end,
        rmdir = function(...)
          note()
          return native.rmdir(...)
        end,
        scandir_next = function(...)
          note()
          return native.scandir_next(...)
        end,
        hash = function(...)
          note()
          return native.hash(...)
        end,
        uid = function()
          note()
          return native.uid()
        end,
        pid = function()
          note()
          return label == "primary-release" and 4504 or 4505
        end,
        hrtime = function()
          note()
          return label == "primary-release" and 4604 or 4605
        end,
        resolve_git = function()
          note()
          return git_executable
        end,
        revalidate_git = function(...)
          note()
          return native.revalidate_git(...)
        end,
        system = function(argv, options)
          note()
          return vim.system(argv, options):wait(30000)
        end,
        after_read = function()
          note()
        end,
      }
      expected_dependencies = overrides

      local publication = baseline_module._test.new(overrides)
      local status_before = fixture:status_bytes()
      local objects_before = fixture:object_count()
      local invoked, value, err = pcall(publication.create, identity, store)
      row.invoked = invoked
      if invoked then
        row.value = value
        row.error = err
      end
      if serializer.held then
        row.rescue = row.rescue + 1
        pcall(function()
          return canary_lease:release()
        end)
      end

      local invalid_lifetimes = 0
      for _, lifetime in ipairs(row.descriptors) do
        if
          lifetime.close_attempts ~= 1
          or lifetime.physical_closes ~= 1
          or lifetime.active ~= false
        then
          invalid_lifetimes = invalid_lifetimes + 1
        end
      end
      row.descriptor_exact = #row.descriptors == (inject_load and 11 or 10)
        and invalid_lifetimes == 0
        and next(row.active) == nil
        and row.live_reuse == 0
        and row.unowned_closes == 0
        and row.release_after_close == true
        and row.release_fstat_exact == true
      local entries = review_entries(fixture)
      row.residue_exact = inject_load and #entries == 0
        or not inject_load and #entries == 1 and entries[1] == row.review_id
      row.git_exact = fixture:status_bytes() == status_before
        and fixture:object_count() == objects_before
      row.lifecycle_exact = row.acquire_count == 1
        and row.release_count == 1
        and row.physical_release_count == 1
        and serializer.root_exact
        and serializer.dependency_exact
        and serializer.held == false
        and serializer.active == nil
        and row.review_calls == 1
        and row.fault_count == (inject_load and 1 or 0)
        and row.rescue == 0
        and row.held_violations == 0
        and row.after_release_calls == 0
        and row.release_state_exact == true
        and exact(row.events, expected_events[label])

      if
        not (row.descriptor_exact and row.lifecycle_exact and row.residue_exact and row.git_exact)
      then
        table.insert(harness_failures, label .. " integration harness mismatch")
      end

      row.result_exact = row.invoked and row.value == nil and row.error == (inject_load and PR or R)

      if label == "success-release" then
        local bomb = {}
        function bomb.acquire()
          row.open_acquires = row.open_acquires + 1
          error("api.open attempted serialization acquisition", 0)
        end
        local reader = baseline_module._test.new({ serialization = bomb })
        local open_ok, opened, open_error = pcall(reader.open, identity, real_store, row.review_id)
        row.open_exact = open_ok
          and open_error == nil
          and type(opened) == "table"
          and opened:id() == row.review_id
          and opened:bytes("dirty.txt") == "dirty\n"
          and row.open_acquires == 0
      end

      table.insert(
        observations,
        string.format(
          "%s=%s/%s acquire=%d release=%d/%d descriptors=%d closed=%s order=%s residue=%s git=%s open=%s/%d events=%s",
          label,
          row.value == nil and "nil" or "value",
          row.error == (inject_load and PR or R) and "expected" or "unexpected",
          row.acquire_count,
          row.release_count,
          row.physical_release_count,
          #row.descriptors,
          tostring(row.descriptor_exact),
          tostring(row.lifecycle_exact),
          tostring(row.residue_exact),
          tostring(row.git_exact),
          tostring(label ~= "success-release" or row.open_exact == true),
          row.open_acquires,
          table.concat(row.events, ",")
        )
      )
      return row
    end

    local primary = execute_row("primary-release")
    local success = execute_row("success-release")
    if not primary.result_exact then
      table.insert(findings, "primary-release result mismatch")
    end
    if not success.result_exact or success.open_exact ~= true then
      table.insert(findings, "success-release or open contract mismatch")
    end

    local probe = baseline_module._test.new()
    local finish_create = named_upvalue(probe.create, "finish_create")
    if type(finish_create) ~= "function" then
      table.insert(findings, "outer finalizer contract unavailable")
      table.insert(observations, "finalizer=missing")
    else
      local canary = {}
      local hostile_tostring_calls = 0
      local hostile_object = setmetatable({}, {
        __tostring = function()
          hostile_tostring_calls = hostile_tostring_calls + 1
          error("hostile release object rendered", 0)
        end,
      })
      local valid_multiple = valid_lstats .. "; " .. R .. "; " .. CS
      local cases = {
        { label = "success", value = canary, released = true, expected_value = canary },
        { label = "primary", value = canary, primary = P, released = true, expected_error = P },
        {
          label = "release",
          value = canary,
          released = nil,
          release_error = R,
          expected_error = R,
        },
        {
          label = "nil-release",
          primary = P,
          released = nil,
          release_error = R,
          expected_error = PR,
        },
        {
          label = "false-release",
          primary = P,
          released = false,
          release_error = R,
          expected_error = PR,
        },
        {
          label = "true-error",
          primary = P,
          released = true,
          release_error = R,
          expected_error = PR,
        },
        {
          label = "status-object-empty",
          primary = P,
          released = hostile_object,
          expected_error = PF,
        },
        {
          label = "status-object-release",
          primary = P,
          released = hostile_object,
          release_error = R,
          expected_error = PR,
        },
        {
          label = "true-false-error",
          primary = P,
          released = true,
          release_error = false,
          expected_error = PF,
        },
        {
          label = "true-empty-error",
          primary = P,
          released = true,
          release_error = "",
          expected_error = PF,
        },
        {
          label = "true-object-error",
          primary = P,
          released = true,
          release_error = hostile_object,
          expected_error = PF,
        },
        { label = "nil-empty", primary = P, released = nil, expected_error = PF },
        { label = "false-empty", primary = P, released = false, expected_error = PF },
        { label = "throw-path", primary = P, throws = hostile_path, expected_error = PF },
        { label = "throw-canonical", primary = P, throws = R, expected_error = PF },
        { label = "throw-object", primary = P, throws = hostile_object, expected_error = PF },
        {
          label = "short-path",
          primary = P,
          release_error = "/private/release",
          expected_error = PF,
        },
        { label = "object", primary = P, release_error = hostile_object, expected_error = PF },
        { label = "oversized", primary = P, release_error = hostile_path, expected_error = PF },
        {
          label = "valid-max",
          primary = P,
          release_error = valid_max,
          expected_error = P .. "; " .. valid_max,
        },
        {
          label = "valid-lstats",
          primary = P,
          release_error = valid_lstats,
          expected_error = P .. "; " .. valid_lstats,
        },
        {
          label = "valid-validates",
          primary = P,
          release_error = valid_validates,
          expected_error = P .. "; " .. valid_validates,
        },
        {
          label = "valid-rmdir",
          primary = P,
          release_error = valid_rmdir,
          expected_error = P .. "; " .. valid_rmdir,
        },
        {
          label = "valid-absence",
          primary = P,
          release_error = valid_absence,
          expected_error = P .. "; " .. valid_absence,
        },
        {
          label = "valid-multiple",
          primary = P,
          release_error = valid_multiple,
          expected_error = P .. "; " .. valid_multiple,
        },
        {
          label = "valid-code",
          primary = P,
          release_error = valid_code,
          expected_error = P .. "; " .. valid_code,
        },
        { label = "nine", primary = P, release_error = invalid_nine, expected_error = PF },
        {
          label = "identity-five",
          primary = P,
          release_error = invalid_identity,
          expected_error = PF,
        },
        {
          label = "identity-order",
          primary = P,
          release_error = invalid_identity_order,
          expected_error = PF,
        },
        { label = "order", primary = P, release_error = invalid_order, expected_error = PF },
        { label = "removals", primary = P, release_error = invalid_removals, expected_error = PF },
        {
          label = "validation-rmdir",
          primary = P,
          release_error = invalid_validation_rmdir,
          expected_error = PF,
        },
        {
          label = "validation-absence",
          primary = P,
          release_error = invalid_validation_absence,
          expected_error = PF,
        },
        {
          label = "state-rmdir",
          primary = P,
          release_error = invalid_state_rmdir,
          expected_error = PF,
        },
        {
          label = "state-absence",
          primary = P,
          release_error = invalid_state_absence,
          expected_error = PF,
        },
        {
          label = "duplicate-close",
          primary = P,
          release_error = invalid_duplicate_close,
          expected_error = PF,
        },
        {
          label = "duplicate-state",
          primary = P,
          release_error = invalid_duplicate_state,
          expected_error = PF,
        },
        {
          label = "duplicate-rmdir",
          primary = P,
          release_error = invalid_duplicate_rmdir,
          expected_error = PF,
        },
        {
          label = "duplicate-absence",
          primary = P,
          release_error = invalid_duplicate_absence,
          expected_error = PF,
        },
        {
          label = "duplicate-sync",
          primary = P,
          release_error = invalid_duplicate_sync,
          expected_error = PF,
        },
        {
          label = "duplicate-state-close",
          primary = P,
          release_error = invalid_duplicate_state_close,
          expected_error = PF,
        },
        {
          label = "operation",
          primary = P,
          release_error = invalid_operation,
          expected_error = PF,
        },
        { label = "code", primary = P, release_error = invalid_code, expected_error = PF },
      }
      local function exercise(case, primary_error, expected_value, expected_error)
        local lease = { calls = 0 }
        function lease:release()
          self.calls = self.calls + 1
          if case.throws then
            error(case.throws, 0)
          end
          return case.released, case.release_error
        end
        local invoked, value, err = pcall(finish_create, lease, canary, primary_error)
        local value_exact = expected_value ~= nil and rawequal(value, expected_value)
          or expected_value == nil and value == nil
        local secret_absent = type(err) ~= "string"
          or not err:find("/private/", 1, true)
            and not err:find("secret", 1, true)
            and not err:find("hostile release object rendered", 1, true)
        return invoked
          and value_exact
          and err == expected_error
          and lease.calls == 1
          and hostile_tostring_calls == 0
          and secret_absent
      end

      local passed = 0
      local expected_passes = 0
      local primary_prefix = P .. "; "
      for _, case in ipairs(cases) do
        if case.label == "success" or case.label == "primary" then
          expected_passes = expected_passes + 1
          if exercise(case, case.primary, case.expected_value, case.expected_error) then
            passed = passed + 1
          end
        else
          local release_only_error = case.expected_error
          if case.primary ~= nil then
            release_only_error = release_only_error:sub(#primary_prefix + 1)
          end
          expected_passes = expected_passes + 2
          if exercise(case, nil, nil, release_only_error) then
            passed = passed + 1
          end
          if exercise(case, P, nil, primary_prefix .. release_only_error) then
            passed = passed + 1
          end
        end
      end
      if passed ~= expected_passes then
        table.insert(findings, "outer finalizer contract mismatch")
      end
      table.insert(observations, string.format("finalizer=%d/%d", passed, expected_passes))
    end

    local diagnostic = "Cycle 4D outer result failures: harness="
      .. (#harness_failures == 0 and "none" or table.concat(harness_failures, "; "))
      .. " behavior="
      .. (#findings == 0 and "none" or table.concat(findings, "; "))
      .. " | observations: "
      .. table.concat(observations, "; ")
    assert(#diagnostic <= 1536, "Cycle 4D outer result diagnostic overflow")
    assert(#harness_failures == 0 and #findings == 0, diagnostic)
  end

  local fixture = Fixture.new("baseline")
  fixture:write("clean.txt", "clean\n")
  fixture:write("dirty.txt", "committed\n")
  fixture:write("staged.txt", "committed staged\n")
  fixture:write("script.sh", "#!/bin/sh\nexit 0\n", 493)
  fixture:write("mode-change.sh", "#!/bin/sh\nexit 0\n", 420)
  fixture:write("missing.txt", "present in committed tree\n")
  fixture:write("missing-unstaged.txt", "also present in committed tree\n")
  fixture:symlink("linked", "clean.txt")
  local tabbed = "tab\tname.txt"
  local newline = "line\nname.txt"
  local non_utf8 = "raw-\255.txt"
  fixture:write(tabbed, "tabbed\n")
  fixture:write(newline, "newline\n")
  fixture:write(non_utf8, "raw\n")
  fixture:commit("baseline")
  assert(vim.uv.fs_chmod(fixture:path("mode-change.sh"), 493))

  local head = fixture:git({ "rev-parse", "HEAD" }).stdout:gsub("\n$", "")
  fixture:git({ "update-index", "--add", "--cacheinfo", "160000," .. head .. ",vendor/sub" })
  fixture:git({ "commit", "--quiet", "-m", "gitlink" })
  fixture:unlink("missing.txt")
  fixture:git({ "add", "--", "missing.txt" })
  fixture:unlink("missing-unstaged.txt")
  fixture:write("dirty.txt", "pre-request dirty\n")
  fixture:write("staged.txt", "staged bytes\n")
  fixture:git({ "add", "--", "staged.txt" })
  fixture:write("untracked.txt", "pre-request untracked\n")
  fixture:write("ignored.log", "ignored before\n")
  fixture:write(".gitignore", "*.log\n")

  local status_before = fixture:status_bytes()
  local objects_before = fixture:object_count()
  local baseline = assert(baseline_module.create(fixture:identity(), fixture:store()))
  eq(fixture:status_bytes(), status_before, "baseline does not alter Git status")
  eq(fixture:object_count(), objects_before, "baseline writes no Git object")
  eq(baseline:read("clean.txt").storage:sub(1, 5), "tree:", "clean tracked tree reference")
  eq(baseline:read("clean.txt").mode, "100644", "clean tracked mode")
  eq(baseline:read("script.sh").mode, "100755", "executable tracked mode")
  eq(baseline:read("mode-change.sh").mode, "100755", "executable-bit change mode")
  eq(baseline:read("mode-change.sh").storage:sub(1, 5), "copy:", "executable-bit change is copied")
  eq(baseline:read("linked").kind, "symlink", "symlink kind")
  eq(baseline:bytes("linked"), "clean.txt", "symlink target bytes")
  eq(baseline:read("dirty.txt").storage:sub(1, 5), "copy:", "dirty tracked copy")
  eq(baseline:bytes("dirty.txt"), "pre-request dirty\n", "dirty bytes retained exactly")
  eq(baseline:read("staged.txt").storage:sub(1, 5), "copy:", "staged path copied")
  eq(baseline:bytes("untracked.txt"), "pre-request untracked\n", "untracked bytes retained exactly")
  eq(baseline:read("missing.txt").kind, "absent", "absent path")
  eq(baseline:read("missing-unstaged.txt").kind, "absent", "unstaged missing path")
  eq(baseline:read("vendor/sub").kind, "unsupported", "gitlink is unsupported")
  assert(baseline:ignored_fingerprint("ignored.log").sha256, "ignored path fingerprint missing")
  eq(baseline:read("ignored.log"), nil, "ignored bytes are not retained")
  eq(baseline:bytes(tabbed), "tabbed\n", "tabbed path bytes")
  eq(baseline:bytes(newline), "newline\n", "newline path bytes")
  eq(baseline:bytes(non_utf8), "raw\n", "non-UTF-8 path bytes")

  local reopened = assert(baseline_module.open(fixture:identity(), fixture:store(), baseline:id()))
  eq(reopened:bytes("dirty.txt"), "pre-request dirty\n", "durable baseline reopen")
  eq(reopened:manifest().baseline_hash, baseline:manifest().baseline_hash, "manifest hash")
  eq(reopened:manifest().paths, baseline:manifest().paths, "durable path manifest")

  local unborn = Fixture.new("unborn")
  unborn:write(".gitignore", "*.cache\n")
  unborn:write("staged.txt", "staged unborn\n")
  unborn:git({ "add", "--", "staged.txt" })
  unborn:write("untracked.txt", "untracked unborn\n")
  unborn:write("ignored.cache", "ignored unborn\n")
  local unborn_before = unborn:object_count()
  local unborn_baseline = assert(baseline_module.create(unborn:identity(), unborn:store()))
  eq(unborn_baseline:manifest().tree_oid, nil, "unborn repository has no tree")
  eq(unborn_baseline:bytes("staged.txt"), "staged unborn\n", "unborn staged copy")
  eq(unborn_baseline:bytes("untracked.txt"), "untracked unborn\n", "unborn untracked copy")
  assert(unborn_baseline:ignored_fingerprint("ignored.cache"), "unborn ignored fingerprint")
  eq(unborn:object_count(), unborn_before, "unborn capture writes no Git object")

  local plain = Fixture.new("plain", false)
  plain:write("visible.txt", "plain\n")
  local git_calls = 0
  local plain_module = baseline_module._test.new({
    run_git = function()
      git_calls = git_calls + 1
      error("Git must not run for non-Git baseline")
    end,
  })
  local plain_baseline = assert(plain_module.create(plain:identity(false), plain:store()))
  eq(plain_baseline:manifest().conflict_only, true, "non-Git conflict-only baseline")
  eq(plain_baseline:manifest().paths, {}, "non-Git stores no automatic objects")
  eq(git_calls, 0, "non-Git invokes no Git command")

  local race = Fixture.new("race")
  race:write("race.txt", "before\n")
  race:commit("race")
  race:write("race.txt", "capture one\n")
  local raced = false
  local race_module = baseline_module._test.new({
    after_read = function(path)
      if path == race:path("race.txt") and not raced then
        raced = true
        race:write("race.txt", "capture two\n")
      end
    end,
  })
  local race_baseline, race_error = race_module.create(race:identity(), race:store())
  rejected(race_baseline, race_error, "changed during capture", "capture race rejected")

  do
    local hostile_path = "/private/cycle6c/" .. string.rep("secret", 256)
    local cases = {
      {
        label = "fstat-mismatch",
        injection = "fstat",
        expected_fstat_calls = 1,
        expected_read_calls = 0,
        expected_error = "file changed during capture: metadata; close-baseline-source (EIO)",
      },
      {
        label = "read-failure",
        injection = "read",
        expected_fstat_calls = 1,
        expected_read_calls = 1,
        expected_error = "file changed during capture: short read; close-baseline-source (EIO)",
      },
    }
    local harness_findings = {}
    local behavior_findings = {}
    local observations = {}

    for _, case in ipairs(cases) do
      local fixture = Fixture.new("cycle-6c-1-" .. case.label, false)
      fixture:write("source.txt", "source\n")
      local source_path = fixture:path("source.txt")
      local events = {}
      local dependencies
      local descriptors
      local lifetimes
      dependencies, descriptors, lifetimes = tracked_open_close_dependencies({
        close_error = function(_, lifetime)
          if lifetime.path == source_path then
            table.insert(events, "close")
            return hostile_path, "EIO"
          end
        end,
      })

      local injection_count = 0
      local target_fstat_calls = 0
      local target_read_calls = 0
      dependencies.fstat = function(fd)
        local lifetime = descriptors[fd]
        if lifetime and lifetime.path == source_path then
          target_fstat_calls = target_fstat_calls + 1
        end
        local stat, stat_error, stat_code = vim.uv.fs_fstat(fd)
        if
          case.injection == "fstat"
          and injection_count == 0
          and lifetime
          and lifetime.path == source_path
          and stat
        then
          injection_count = injection_count + 1
          table.insert(events, "primary")
          stat = copy(stat)
          stat.ino = stat.ino == 0 and 1 or 0
        end
        return stat, stat_error, stat_code
      end
      dependencies.read = function(fd, length, offset)
        local lifetime = descriptors[fd]
        if lifetime and lifetime.path == source_path then
          target_read_calls = target_read_calls + 1
        end
        if
          case.injection == "read"
          and injection_count == 0
          and lifetime
          and lifetime.path == source_path
        then
          injection_count = injection_count + 1
          table.insert(events, "primary")
          return ""
        end
        return vim.uv.fs_read(fd, length, offset)
      end

      local cycle6c_module = baseline_module._test.new(dependencies)
      local call_ok
      local value
      local capture_error
      call_ok, value, capture_error = xpcall(function()
        return cycle6c_module.scan_current(fixture:identity(false), { "source.txt" })
      end, debug.traceback)
      table.insert(events, "return")

      if not call_ok then
        table.insert(behavior_findings, case.label .. " production call raised")
      else
        if value ~= nil then
          table.insert(behavior_findings, case.label .. " returned a value")
        end
        if capture_error ~= case.expected_error then
          table.insert(behavior_findings, case.label .. " result mismatch")
        end
      end

      local hostile_visible = type(capture_error) == "string"
        and capture_error:find(hostile_path, 1, true) ~= nil
      if hostile_visible then
        table.insert(behavior_findings, case.label .. " rendered hostile payload")
      end
      if injection_count ~= 1 then
        table.insert(harness_findings, case.label .. " injection count mismatch")
      end
      if
        target_fstat_calls ~= case.expected_fstat_calls
        or target_read_calls ~= case.expected_read_calls
      then
        table.insert(behavior_findings, case.label .. " dependency call count mismatch")
      end
      if not vim.deep_equal(events, { "primary", "close", "return" }) then
        table.insert(behavior_findings, case.label .. " event order mismatch")
      end

      local lifetime = #lifetimes == 1 and lifetimes[1] or nil
      if #lifetimes ~= 1 then
        table.insert(behavior_findings, case.label .. " descriptor count mismatch")
      end
      local close_exact = lifetime
        and lifetime.close_attempts == 1
        and lifetime.physical_close == true
        and lifetime.active == false
      if not close_exact then
        table.insert(behavior_findings, case.label .. " close contract mismatch")
      end

      local immediate_closed = false
      if lifetime then
        local stat, _, stat_code = vim.uv.fs_fstat(lifetime.fd)
        immediate_closed = stat == nil and stat_code == "EBADF"
      end
      if not immediate_closed then
        table.insert(behavior_findings, case.label .. " immediate EBADF mismatch")
      end

      local rescue_count = 0
      local rescued_fds = {}
      for _, candidate in ipairs(lifetimes) do
        if candidate.active then
          rescue_count = rescue_count + 1
          if rescued_fds[candidate.fd] then
            table.insert(harness_findings, case.label .. " duplicate active generation")
          else
            rescued_fds[candidate.fd] = true
            local rescue_ok, rescued = pcall(vim.uv.fs_close, candidate.fd)
            if not rescue_ok or rescued ~= true then
              table.insert(harness_findings, case.label .. " descriptor rescue failed")
            end
          end
        end
      end
      if rescue_count ~= 0 then
        table.insert(behavior_findings, case.label .. " production close was rescued")
      end
      for fd in pairs(descriptors) do
        local stat, _, stat_code = vim.uv.fs_fstat(fd)
        if stat or stat_code ~= "EBADF" then
          table.insert(harness_findings, case.label .. " descriptor remained live")
        end
      end

      table.insert(
        observations,
        string.format(
          "%s injection=%d calls=%d/%d lifetimes=%d close=%s physical=%s active=%s ebadf=%s rescue=%d events=%s hostile=%s",
          case.label,
          injection_count,
          target_fstat_calls,
          target_read_calls,
          #lifetimes,
          lifetime and tostring(lifetime.close_attempts) or "missing",
          lifetime and tostring(lifetime.physical_close) or "missing",
          lifetime and tostring(lifetime.active) or "missing",
          tostring(immediate_closed),
          rescue_count,
          table.concat(events, ","),
          tostring(hostile_visible)
        )
      )
    end

    local diagnostic = "Cycle 6C-1 capture closure failures: harness="
      .. (#harness_findings == 0 and "none" or table.concat(harness_findings, ", "))
      .. " behavior="
      .. (#behavior_findings == 0 and "none" or table.concat(behavior_findings, ", "))
      .. " | observations: "
      .. table.concat(observations, "; ")
    assert(#diagnostic <= 512, "Cycle 6C-1 capture closure diagnostic overflow")
    if #harness_findings > 0 or #behavior_findings > 0 then
      error(diagnostic, 0)
    end
  end

  do
    local hostile_path = "/private/cycle6c2/" .. string.rep("secret", 256)
    local harness_findings = {}
    local behavior_findings = {}
    local observations = {}

    local function hostile_error(counter)
      return setmetatable({}, {
        __tostring = function()
          counter.renderings = counter.renderings + 1
          return hostile_path
        end,
      })
    end

    local function same_written_stat(left, right)
      if type(left) ~= "table" or type(right) ~= "table" then
        return false
      end
      for _, field in ipairs({
        "dev",
        "ino",
        "type",
        "uid",
        "gid",
        "mode",
        "nlink",
        "size",
        "mtime",
      }) do
        if not vim.deep_equal(left[field], right[field]) then
          return false
        end
      end
      return true
    end

    local function add_finding(findings, label)
      for _, existing in ipairs(findings) do
        if existing == label then
          return
        end
      end
      table.insert(findings, label)
    end

    local function named_upvalue(fn, target)
      if type(fn) ~= "function" then
        return nil
      end
      for index = 1, 64 do
        local ok, name, value = pcall(debug.getupvalue, fn, index)
        if not ok or name == nil then
          break
        end
        if name == target then
          return value
        end
      end
      return nil
    end

    local function observe_lifetime(
      label,
      target_path,
      descriptors,
      lifetimes,
      events,
      expected_events,
      immediate_closed,
      counts,
      hostile_renderings,
      hostile_visible
    )
      if not vim.deep_equal(events, expected_events) then
        add_finding(behavior_findings, label .. " event order mismatch")
      end

      local lifetime = #lifetimes == 1 and lifetimes[1] or nil
      if #lifetimes ~= 1 then
        add_finding(behavior_findings, label .. " descriptor count mismatch")
      end
      if lifetime and (lifetime.generation ~= 1 or lifetime.path ~= target_path) then
        add_finding(behavior_findings, label .. " descriptor identity mismatch")
      end
      if
        not lifetime
        or lifetime.close_attempts ~= 1
        or lifetime.physical_close ~= true
        or lifetime.active ~= false
      then
        add_finding(behavior_findings, label .. " close contract mismatch")
      end
      if not immediate_closed then
        add_finding(behavior_findings, label .. " immediate EBADF mismatch")
      end

      local rescue_count = 0
      local rescued_fds = {}
      for _, candidate in ipairs(lifetimes) do
        if candidate.active then
          rescue_count = rescue_count + 1
          if rescued_fds[candidate.fd] then
            add_finding(harness_findings, label .. " duplicate active generation")
          else
            rescued_fds[candidate.fd] = true
            local rescue_ok, rescued = pcall(vim.uv.fs_close, candidate.fd)
            if not rescue_ok or rescued ~= true then
              add_finding(harness_findings, label .. " descriptor rescue failed")
            end
          end
        end
      end
      if rescue_count ~= 0 then
        add_finding(behavior_findings, label .. " production close was rescued")
      end
      for fd in pairs(descriptors) do
        local stat, _, stat_code = vim.uv.fs_fstat(fd)
        if stat or stat_code ~= "EBADF" then
          add_finding(harness_findings, label .. " descriptor remained live")
        end
      end

      table.insert(
        observations,
        string.format(
          "%s calls=%s life=%d close=%s/%s/%s ebadf=%s rescue=%d events=%s hostile=%d/%s",
          label,
          counts,
          #lifetimes,
          lifetime and tostring(lifetime.close_attempts) or "missing",
          lifetime and tostring(lifetime.physical_close) or "missing",
          lifetime and tostring(lifetime.active) or "missing",
          tostring(immediate_closed),
          rescue_count,
          table.concat(events, ","),
          hostile_renderings,
          tostring(hostile_visible)
        )
      )
    end

    local probe = baseline_module._test.new({})
    local capture = named_upvalue(probe.scan_current, "capture")
    local fingerprint_path = named_upvalue(capture, "fingerprint_path")
    local read_regular = named_upvalue(fingerprint_path, "read_regular")
    local create_under_lease = named_upvalue(probe.create, "create_under_lease")
    local publish = named_upvalue(create_under_lease, "publish")
    local write_new_file = named_upvalue(publish, "write_new_file")
    local open_anchored_directory = named_upvalue(publish, "open_anchored_directory")
    local primitives = {
      { "read_regular", read_regular },
      { "write_new_file", write_new_file },
      { "open_anchored_directory", open_anchored_directory },
    }
    for _, primitive in ipairs(primitives) do
      if type(primitive[2]) ~= "function" then
        add_finding(harness_findings, primitive[1] .. " production graph mismatch")
      end
    end

    if #harness_findings == 0 then
      local read_cases = {
        {
          label = "terminal-read",
          injection = "terminal-read",
          expected_primary_injections = 1,
          expected_events = { "terminal-read", "close", "return" },
          expected_error = "file changed during capture: grew while reading; close-baseline-source (EIO)",
        },
        {
          label = "final-fstat",
          injection = "final-fstat",
          expected_primary_injections = 1,
          expected_events = { "final-fstat", "close", "return" },
          expected_error = "file changed during capture; close-baseline-source (EIO)",
        },
        {
          label = "read-close-only",
          injection = "close-only",
          expected_primary_injections = 0,
          expected_events = { "close", "return" },
          expected_error = "close-baseline-source (EIO)",
        },
      }

      for _, case in ipairs(read_cases) do
        local fixture = Fixture.new("cycle-6c-2-" .. case.label, false)
        fixture:write("source.txt", "source\n")
        local source_path = fixture:path("source.txt")
        local before = assert(vim.uv.fs_lstat(source_path))
        local events = {}
        local hostile = { renderings = 0 }
        local dependencies
        local descriptors
        local lifetimes
        local immediate_closed = false
        local close_injections = 0
        dependencies, descriptors, lifetimes = tracked_open_close_dependencies({
          close_error = function(fd, lifetime)
            if lifetime.path == source_path then
              close_injections = close_injections + 1
              table.insert(events, "close")
              local closed_stat, _, closed_code = vim.uv.fs_fstat(fd)
              immediate_closed = closed_stat == nil and closed_code == "EBADF"
              return hostile_error(hostile), "EIO"
            end
          end,
        })

        local primary_injections = 0
        local target_fstat_calls = 0
        local target_read_calls = 0
        dependencies.fstat = function(fd)
          local lifetime = descriptors[fd]
          local stat, stat_error, stat_code = vim.uv.fs_fstat(fd)
          if lifetime and lifetime.path == source_path then
            target_fstat_calls = target_fstat_calls + 1
            if case.injection == "final-fstat" and target_fstat_calls == 2 and stat then
              primary_injections = primary_injections + 1
              table.insert(events, "final-fstat")
              stat = copy(stat)
              stat.ino = stat.ino == 0 and 1 or 0
            end
          end
          return stat, stat_error, stat_code
        end
        dependencies.read = function(fd, length, offset)
          local lifetime = descriptors[fd]
          if lifetime and lifetime.path == source_path then
            target_read_calls = target_read_calls + 1
            if case.injection == "terminal-read" and target_read_calls == 2 then
              primary_injections = primary_injections + 1
              table.insert(events, "terminal-read")
              return "x"
            end
          end
          return vim.uv.fs_read(fd, length, offset)
        end
        dependencies.lstat = vim.uv.fs_lstat

        local call_ok
        local value
        local row_error
        call_ok, value, row_error = pcall(read_regular, source_path, before, dependencies)
        table.insert(events, "return")

        local hostile_visible = call_ok
          and type(row_error) == "string"
          and row_error:find(hostile_path, 1, true) ~= nil
        if not call_ok then
          add_finding(behavior_findings, case.label .. " production call raised")
        elseif
          value ~= nil
          or row_error ~= case.expected_error
          or hostile.renderings ~= 0
          or hostile_visible
        then
          add_finding(behavior_findings, case.label .. " result mismatch")
        end
        if primary_injections ~= case.expected_primary_injections then
          add_finding(harness_findings, case.label .. " primary injection mismatch")
        end
        if close_injections ~= 1 then
          add_finding(harness_findings, case.label .. " close injection mismatch")
        end
        if target_fstat_calls ~= 2 or target_read_calls ~= 2 then
          add_finding(behavior_findings, case.label .. " dependency call count mismatch")
        end

        observe_lifetime(
          case.label,
          source_path,
          descriptors,
          lifetimes,
          events,
          case.expected_events,
          immediate_closed,
          string.format("%d/%d", target_fstat_calls, target_read_calls),
          hostile.renderings,
          hostile_visible
        )
      end

      local write_cases = {
        {
          label = "write-failure",
          injection = "write",
          expected_write_injections = 1,
          expected_fsync_calls = 0,
          expected_events = { "write", "close", "return" },
          expected_error = "could not write private baseline file; close-private-baseline-file (EIO)",
        },
        {
          label = "final-write-close",
          injection = "close-only",
          expected_write_injections = 0,
          expected_fsync_calls = 1,
          expected_events = { "close", "return" },
          expected_error = "close-private-baseline-file (EIO)",
        },
      }

      for _, case in ipairs(write_cases) do
        local fixture = Fixture.new("cycle-6c-2-" .. case.label, false)
        local target_path = fixture:path("private")
        local events = {}
        local hostile = { renderings = 0 }
        local dependencies
        local descriptors
        local lifetimes
        local immediate_closed = false
        local close_injections = 0
        dependencies, descriptors, lifetimes = tracked_open_close_dependencies({
          close_error = function(fd, lifetime)
            if lifetime.path == target_path then
              close_injections = close_injections + 1
              table.insert(events, "close")
              local closed_stat, _, closed_code = vim.uv.fs_fstat(fd)
              immediate_closed = closed_stat == nil and closed_code == "EBADF"
              return hostile_error(hostile), "EIO"
            end
          end,
        })

        local write_injections = 0
        local target_write_calls = 0
        local target_fsync_calls = 0
        local target_fstat_calls = 0
        dependencies.write = function(fd, bytes, offset)
          local lifetime = descriptors[fd]
          if lifetime and lifetime.path == target_path then
            target_write_calls = target_write_calls + 1
            if case.injection == "write" and write_injections == 0 then
              write_injections = write_injections + 1
              table.insert(events, "write")
              return nil, hostile_error(hostile), "ENOSPC"
            end
          end
          return vim.uv.fs_write(fd, bytes, offset)
        end
        dependencies.fsync = function(fd)
          local lifetime = descriptors[fd]
          if lifetime and lifetime.path == target_path then
            target_fsync_calls = target_fsync_calls + 1
          end
          return vim.uv.fs_fsync(fd)
        end
        dependencies.fstat = function(fd)
          local lifetime = descriptors[fd]
          if lifetime and lifetime.path == target_path then
            target_fstat_calls = target_fstat_calls + 1
          end
          return vim.uv.fs_fstat(fd)
        end

        local call_ok
        local value
        local row_error
        local written_stat
        call_ok, value, row_error, written_stat =
          pcall(write_new_file, target_path, "private\n", dependencies)
        table.insert(events, "return")
        local current_stat = vim.uv.fs_lstat(target_path)

        local hostile_visible = call_ok
          and type(row_error) == "string"
          and row_error:find(hostile_path, 1, true) ~= nil
        if not call_ok then
          add_finding(behavior_findings, case.label .. " production call raised")
        elseif
          value ~= nil
          or row_error ~= case.expected_error
          or not same_written_stat(written_stat, current_stat)
          or hostile.renderings ~= 0
          or hostile_visible
        then
          add_finding(behavior_findings, case.label .. " result mismatch")
        end
        if write_injections ~= case.expected_write_injections then
          add_finding(harness_findings, case.label .. " write injection mismatch")
        end
        if close_injections ~= 1 then
          add_finding(harness_findings, case.label .. " close injection mismatch")
        end
        if
          target_write_calls ~= 1
          or target_fsync_calls ~= case.expected_fsync_calls
          or target_fstat_calls ~= 1
        then
          add_finding(behavior_findings, case.label .. " dependency call count mismatch")
        end

        observe_lifetime(
          case.label,
          target_path,
          descriptors,
          lifetimes,
          events,
          case.expected_events,
          immediate_closed,
          string.format("%d/%d/%d", target_write_calls, target_fsync_calls, target_fstat_calls),
          hostile.renderings,
          hostile_visible
        )
      end

      do
        local label = "anchor-failure"
        local fixture = Fixture.new("cycle-6c-2-" .. label, false)
        local anchor_path = fixture:path("anchor")
        assert(vim.fn.mkdir(anchor_path, "p", 448) == 1)
        assert(vim.uv.fs_chmod(anchor_path, 448))
        local expected = assert(vim.uv.fs_lstat(anchor_path))
        local events = {}
        local hostile = { renderings = 0 }
        local dependencies
        local descriptors
        local lifetimes
        local immediate_closed = false
        local close_injections = 0
        dependencies, descriptors, lifetimes = tracked_open_close_dependencies({
          close_error = function(fd, lifetime)
            if lifetime.path == anchor_path then
              close_injections = close_injections + 1
              table.insert(events, "close")
              local closed_stat, _, closed_code = vim.uv.fs_fstat(fd)
              immediate_closed = closed_stat == nil and closed_code == "EBADF"
              return hostile_error(hostile), "EIO"
            end
          end,
        })

        local fstat_injections = 0
        local target_fstat_calls = 0
        local target_fd_path_calls = 0
        local target_lstat_calls = 0
        dependencies.fstat = function(fd)
          local lifetime = descriptors[fd]
          local stat, stat_error, stat_code = vim.uv.fs_fstat(fd)
          if lifetime and lifetime.path == anchor_path then
            target_fstat_calls = target_fstat_calls + 1
            if fstat_injections == 0 and stat then
              fstat_injections = fstat_injections + 1
              table.insert(events, "anchor-fstat")
              stat = copy(stat)
              stat.ino = stat.ino == 0 and 1 or 0
            end
          end
          return stat, stat_error, stat_code
        end
        dependencies.fd_path = function(fd)
          local lifetime = descriptors[fd]
          if lifetime and lifetime.path == anchor_path then
            target_fd_path_calls = target_fd_path_calls + 1
          end
          return nil, "unexpected descriptor path request"
        end
        dependencies.lstat = function(path)
          target_lstat_calls = target_lstat_calls + 1
          return vim.uv.fs_lstat(path)
        end

        local call_ok
        local value
        local row_error
        call_ok, value, row_error =
          pcall(open_anchored_directory, anchor_path, expected, dependencies, "reviews directory")
        table.insert(events, "return")

        local hostile_visible = call_ok
          and type(row_error) == "string"
          and row_error:find(hostile_path, 1, true) ~= nil
        local expected_error = "reviews directory changed before it could be anchored: metadata; "
          .. "close-directory-anchor (EIO)"
        if not call_ok then
          add_finding(behavior_findings, label .. " production call raised")
        elseif
          value ~= nil
          or row_error ~= expected_error
          or hostile.renderings ~= 0
          or hostile_visible
        then
          add_finding(behavior_findings, label .. " result mismatch")
        end
        if fstat_injections ~= 1 then
          add_finding(harness_findings, label .. " fstat injection mismatch")
        end
        if close_injections ~= 1 then
          add_finding(harness_findings, label .. " close injection mismatch")
        end
        if target_fstat_calls ~= 1 or target_fd_path_calls ~= 0 or target_lstat_calls ~= 0 then
          add_finding(behavior_findings, label .. " dependency call count mismatch")
        end

        observe_lifetime(
          label,
          anchor_path,
          descriptors,
          lifetimes,
          events,
          { "anchor-fstat", "close", "return" },
          immediate_closed,
          string.format("%d/%d/%d", target_fstat_calls, target_fd_path_calls, target_lstat_calls),
          hostile.renderings,
          hostile_visible
        )
      end
    end

    local diagnostic = "Cycle 6C-2 primitive failures: harness="
      .. (#harness_findings == 0 and "none" or table.concat(harness_findings, ", "))
      .. " behavior="
      .. (#behavior_findings == 0 and "none" or table.concat(behavior_findings, ", "))
      .. " | observations: "
      .. table.concat(observations, "; ")
    assert(#diagnostic <= 1024, "Cycle 6C-2 primitive diagnostic overflow")
    if #harness_findings > 0 or #behavior_findings > 0 then
      error(diagnostic, 0)
    end
  end

  do
    local harness_findings = {}
    local behavior_findings = {}
    local observations = {}
    local publication_primary = "could not write private baseline file"
    local removal_primary = "could not remove baseline review directory: EACCES"
    local release_single = "baseline serialization release failed: fsync-state-root (EIO)"
    local release_valid_max = "baseline serialization release failed: validate-state-root (UNKNOWN)"
      .. "; baseline serialization release failed: lstat-lock (EIO)"
      .. "; baseline serialization release failed: validate-lock (UNKNOWN)"
      .. "; baseline serialization release failed: lstat-lock (EIO)"
      .. "; baseline serialization release failed: validate-lock (UNKNOWN)"
      .. "; baseline serialization release failed: close-lock (EIO)"
      .. "; baseline serialization release failed: fsync-state-root (EIO)"
      .. "; baseline serialization release failed: close-state-root (EIO)"
    local publication_error = publication_primary
      .. "; rmdir-cleanup-review (EACCES)"
      .. "; fsync-cleanup-objects (ENOSPC)"
      .. "; fsync-cleanup-review (EIO)"
      .. "; "
      .. release_valid_max
      .. "; close-private-baseline-file (EIO)"
      .. "; close-cleanup-review (EBADF)"
      .. "; close-cleanup-reviews (EMFILE)"
    local removal_error = removal_primary
      .. "; "
      .. release_single
      .. "; close-removal-review (EBADF)"
      .. "; close-removal-reviews (EMFILE)"
    local close_private = { "close", "close-private-baseline-file", "EIO" }
    local sync_cleanup_objects = { "synchronization", "fsync-cleanup-objects", "ENOSPC" }
    local sync_cleanup_review = { "synchronization", "fsync-cleanup-review", "EIO" }
    local remove_cleanup_review = { "cleanup", "rmdir-cleanup-review", "EACCES" }
    local close_cleanup_review = { "close", "close-cleanup-review", "EBADF" }
    local close_cleanup_reviews = { "close", "close-cleanup-reviews", "EMFILE" }
    local close_removal_review = { "close", "close-removal-review", "EBADF" }
    local close_removal_reviews = { "close", "close-removal-reviews", "EMFILE" }
    local dependency_names = {
      "lstat",
      "realpath",
      "readlink",
      "open",
      "fstat",
      "read",
      "write",
      "fsync",
      "close",
      "mkdir",
      "unlink",
      "rmdir",
      "rename",
      "scandir",
      "scandir_next",
      "hash",
      "uid",
      "pid",
      "hrtime",
      "resolve_git",
      "revalidate_git",
      "system",
      "fd_path",
      "after_read",
    }

    local function expected_state(primary, entries)
      return {
        primary_is_nil = primary == nil,
        primary = primary,
        entries = entries,
      }
    end

    local specs = {
      {
        label = "publication-cleanup",
        expected_error = publication_error,
        release_error = release_valid_max,
        expected_roles = {
          "publication-reviews",
          "publication-review",
          "publication-objects",
          "manifest-writer",
          "cleanup-reviews",
          "cleanup-review",
          "cleanup-objects",
        },
        expected_probes = {
          "manifest-write",
          "close-private-baseline-file",
          "close-publication-objects",
          "close-publication-review",
          "close-publication-reviews",
          "fsync-cleanup-objects",
          "close-cleanup-objects",
          "fsync-cleanup-review",
          "rmdir-cleanup-review",
          "close-cleanup-review",
          "close-cleanup-reviews",
          "release",
        },
        expected_events = {
          "acquire",
          "manifest-write",
          "close-private-baseline-file",
          "close-publication-objects",
          "close-publication-review",
          "close-publication-reviews",
          "fsync-cleanup-objects",
          "close-cleanup-objects",
          "fsync-cleanup-review",
          "rmdir-cleanup-review",
          "close-cleanup-review",
          "close-cleanup-reviews",
          "release",
          "return",
        },
        states = {
          ["manifest-write"] = expected_state(nil, {}),
          ["close-private-baseline-file"] = expected_state(publication_primary, {}),
          ["close-publication-objects"] = expected_state(publication_primary, { close_private }),
          ["close-publication-review"] = expected_state(publication_primary, { close_private }),
          ["close-publication-reviews"] = expected_state(publication_primary, { close_private }),
          ["fsync-cleanup-objects"] = expected_state(publication_primary, { close_private }),
          ["close-cleanup-objects"] = expected_state(
            publication_primary,
            { close_private, sync_cleanup_objects }
          ),
          ["fsync-cleanup-review"] = expected_state(
            publication_primary,
            { close_private, sync_cleanup_objects }
          ),
          ["rmdir-cleanup-review"] = expected_state(
            publication_primary,
            { close_private, sync_cleanup_objects, sync_cleanup_review }
          ),
          ["close-cleanup-review"] = expected_state(publication_primary, {
            close_private,
            sync_cleanup_objects,
            sync_cleanup_review,
            remove_cleanup_review,
          }),
          ["close-cleanup-reviews"] = expected_state(publication_primary, {
            close_private,
            sync_cleanup_objects,
            sync_cleanup_review,
            remove_cleanup_review,
            close_cleanup_review,
          }),
          release = expected_state(publication_primary, {
            close_private,
            sync_cleanup_objects,
            sync_cleanup_review,
            remove_cleanup_review,
            close_cleanup_review,
            close_cleanup_reviews,
          }),
        },
      },
      {
        label = "removal",
        expected_error = removal_error,
        release_error = release_single,
        expected_roles = {
          "removal-reviews",
          "removal-review",
          "removal-objects",
        },
        expected_probes = {
          "rmdir-removal-review",
          "close-removal-review",
          "close-removal-reviews",
          "release",
        },
        expected_events = {
          "acquire",
          "close-removal-objects",
          "rmdir-removal-review",
          "close-removal-review",
          "close-removal-reviews",
          "release",
          "return",
        },
        states = {
          ["rmdir-removal-review"] = expected_state(nil, {}),
          ["close-removal-review"] = expected_state(removal_primary, {}),
          ["close-removal-reviews"] = expected_state(removal_primary, { close_removal_review }),
          release = expected_state(
            removal_primary,
            { close_removal_review, close_removal_reviews }
          ),
        },
      },
    }

    local function add_finding(findings, label)
      for _, existing in ipairs(findings) do
        if existing == label then
          return
        end
      end
      if #findings < 8 then
        table.insert(findings, label)
      elseif findings[#findings] ~= "additional" then
        table.insert(findings, "additional")
      end
    end

    local baseline_probe = baseline_module._test.new({})
    local baseline_info = assert(debug.getinfo(baseline_probe.create, "S"))
    local baseline_source = baseline_info.source
    local known_phases = {
      cleanup = true,
      synchronization = true,
      release = true,
      close = true,
    }

    local function collector_shape(value)
      if type(value) ~= "table" then
        return false
      end
      local primary = rawget(value, "primary")
      local phases = rawget(value, "phases")
      if
        type(phases) ~= "table"
        or not (primary == nil or type(primary) == "string" and primary ~= "")
      then
        return false
      end
      for phase, bucket in next, phases do
        if
          not known_phases[phase]
          or type(bucket) ~= "table"
          or type(rawget(bucket, "entries")) ~= "table"
          or type(rawget(bucket, "seen")) ~= "table"
          or type(rawget(bucket, "count")) ~= "number"
          or type(rawget(bucket, "additional")) ~= "boolean"
        then
          return false
        end
      end
      return true
    end

    local function unique_production_collector()
      local found = {}
      local seen = {}
      local function consider(value)
        if collector_shape(value) and not seen[value] then
          seen[value] = true
          table.insert(found, value)
        end
      end

      for level = 3, 48 do
        local info_ok, info = pcall(debug.getinfo, level, "fS")
        if info_ok and info and info.source == baseline_source then
          for index = 1, 64 do
            local ok, name, value = pcall(debug.getlocal, level, index)
            if not ok or name == nil then
              break
            end
            consider(value)
          end
          for index = 1, 64 do
            local ok, name, value = pcall(debug.getupvalue, info.func, index)
            if not ok or name == nil then
              break
            end
            consider(value)
          end
        end
      end
      return #found == 1 and found[1] or nil, #found
    end

    local function exact_entries(collector, expected)
      local wanted = {}
      for _, item in ipairs(expected) do
        local key = item[1] .. "\0" .. item[2] .. "\0" .. item[3]
        if wanted[key] then
          return false
        end
        wanted[key] = true
      end

      local actual = {}
      local actual_count = 0
      for phase, bucket in next, rawget(collector, "phases") do
        if rawget(bucket, "additional") ~= false then
          return false
        end
        local bucket_count = 0
        for operation, codes in next, rawget(bucket, "entries") do
          if type(operation) ~= "string" or type(codes) ~= "table" then
            return false
          end
          for index, code in next, codes do
            if type(index) ~= "number" or index < 1 or index % 1 ~= 0 or type(code) ~= "string" then
              return false
            end
            local key = phase .. "\0" .. operation .. "\0" .. code
            if actual[key] or not wanted[key] then
              return false
            end
            actual[key] = true
            bucket_count = bucket_count + 1
            actual_count = actual_count + 1
          end
        end
        if bucket_count == 0 or rawget(bucket, "count") ~= bucket_count then
          return false
        end
      end
      return actual_count == #expected
    end

    local function run_row(spec)
      local publication = spec.label == "publication-cleanup"
      local fixture = Fixture.new("cycle-6c-3-" .. spec.label, not publication)
      if not publication then
        fixture:write("dirty.txt", "one\n")
        fixture:commit("cycle 6c-3")
        fixture:write("dirty.txt", "two\n")
      end
      local identity = publication and fixture:identity(false) or fixture:identity()
      local real_store = fixture:store()
      local store = {}
      local review_id
      function store:state_dir(...)
        return real_store.state_dir(real_store, ...)
      end
      function store:review_dir(candidate, ...)
        review_id = candidate
        return real_store.review_dir(real_store, candidate, ...)
      end

      local row = {
        events = {},
        probes = {},
        renderings = 0,
        acquire_count = 0,
        release_count = 0,
        physical_release_count = 0,
        recursive = 0,
        held_violations = 0,
        after_release = 0,
        receiver_exact = true,
        dependency_exact = true,
        root_exact = true,
        collector_missing = 0,
        collector_mismatch = 0,
        collector_state_mismatch = 0,
        live_reuse = 0,
        rescue = 0,
        manifest_stat_exact = not publication,
        injection = {
          write = 0,
          fsync = 0,
          rmdir = 0,
          close = 0,
        },
      }
      local hostile = setmetatable({}, {
        __tostring = function()
          row.renderings = row.renderings + 1
          return "/private/cycle6c3/" .. string.rep("secret", 256)
        end,
      })
      local dependencies
      local descriptors
      local lifetimes
      dependencies, descriptors, lifetimes = tracked_open_close_dependencies()
      local tracked_open = dependencies.open
      local tracked_close = dependencies.close
      local held = false
      local released = false
      local active_lease
      local scope_start = 0
      local failure_started = false
      local collector_identity
      local collector_phases

      local function probe_collector(token)
        table.insert(row.probes, token)
        local expected = assert(spec.states[token])
        local collector, count = unique_production_collector()
        if not collector or count ~= 1 then
          row.collector_missing = row.collector_missing + 1
          return
        end
        local phases = rawget(collector, "phases")
        if collector_identity == nil then
          collector_identity = collector
          collector_phases = phases
        elseif
          not rawequal(collector_identity, collector)
          or not rawequal(collector_phases, phases)
        then
          row.collector_mismatch = row.collector_mismatch + 1
        end
        local expected_primary = expected.primary_is_nil and nil or expected.primary
        if
          rawget(collector, "primary") ~= expected_primary
          or not exact_entries(collector, expected.entries)
        then
          row.collector_state_mismatch = row.collector_state_mismatch + 1
        end
      end

      local function note()
        if released then
          row.after_release = row.after_release + 1
        elseif row.acquire_count > 0 and (not held or not rawequal(active_lease, row.lease)) then
          row.held_violations = row.held_violations + 1
        end
      end

      local native = {
        lstat = vim.uv.fs_lstat,
        realpath = vim.uv.fs_realpath,
        readlink = vim.uv.fs_readlink,
        fstat = vim.uv.fs_fstat,
        read = vim.uv.fs_read,
        mkdir = vim.uv.fs_mkdir,
        unlink = vim.uv.fs_unlink,
        rename = vim.uv.fs_rename,
        scandir = vim.uv.fs_scandir,
        scandir_next = vim.uv.fs_scandir_next,
        hash = vim.fn.sha256,
        uid = vim.uv.getuid,
        pid = vim.fn.getpid,
        hrtime = vim.uv.hrtime,
        resolve_git = function()
          return require("ai.tools").resolve("git")
        end,
        revalidate_git = require("ai.tools").revalidate,
        system = function(argv, options)
          return vim.system(argv, options):wait(30000)
        end,
        fd_path = function(fd)
          for _, prefix in ipairs({ "/proc/self/fd/", "/dev/fd/" }) do
            local path = prefix .. tostring(fd)
            if vim.uv.fs_lstat(path) then
              return path
            end
          end
          return nil, "stable directory descriptor path is unavailable"
        end,
      }
      for operation, target in pairs(native) do
        local name = operation
        local callback = target
        dependencies[name] = function(...)
          note()
          return callback(...)
        end
      end
      dependencies.after_read = function()
        note()
      end

      local function basename(path)
        return type(path) == "string" and path:match("([^/]+)$") or nil
      end

      local function role(path, flags)
        local name = basename(path)
        if publication then
          if name == "manifest.json" and flags == "wx" then
            return "manifest-writer"
          end
          if name == "objects" then
            return failure_started and "cleanup-objects" or "publication-objects"
          end
          if name and name:match("^%.publishing%-") then
            return "publication-review"
          end
          if name and name:match("^%.cleanup%-") then
            return "cleanup-review"
          end
          if path == vim.fs.joinpath(fixture.state, "reviews") then
            return failure_started and "cleanup-reviews" or "publication-reviews"
          end
        elseif held then
          if name == "objects" then
            return "removal-objects"
          end
          if name and name:match("^%.removing%-") then
            return "removal-review"
          end
          if path == vim.fs.joinpath(fixture.state, "reviews") then
            return "removal-reviews"
          end
        end
        return nil
      end

      dependencies.open = function(path, flags, mode)
        note()
        local fd, open_error, open_code = tracked_open(path, flags, mode)
        if fd ~= nil then
          local lifetime = descriptors[fd]
          lifetime.role = role(path, flags)
          for index = 1, #lifetimes - 1 do
            if lifetimes[index].fd == fd and lifetimes[index].active then
              row.live_reuse = row.live_reuse + 1
            end
          end
        end
        return fd, open_error, open_code
      end

      local close_token = {
        ["manifest-writer"] = "close-private-baseline-file",
        ["publication-objects"] = "close-publication-objects",
        ["publication-review"] = "close-publication-review",
        ["publication-reviews"] = "close-publication-reviews",
        ["cleanup-objects"] = "close-cleanup-objects",
        ["cleanup-review"] = "close-cleanup-review",
        ["cleanup-reviews"] = "close-cleanup-reviews",
        ["removal-objects"] = "close-removal-objects",
        ["removal-review"] = "close-removal-review",
        ["removal-reviews"] = "close-removal-reviews",
      }
      dependencies.close = function(fd)
        note()
        local lifetime = descriptors[fd]
        local closed, close_error, close_code = tracked_close(fd)
        if lifetime and lifetime.active == false then
          local stat, _, code = vim.uv.fs_fstat(fd)
          lifetime.immediate_ebadf = stat == nil and code == "EBADF"
          local token = lifetime.role and close_token[lifetime.role] or nil
          if token then
            table.insert(row.events, token)
            if failure_started then
              probe_collector(token)
            end
          end
          if lifetime.role == "manifest-writer" then
            row.injection.close = row.injection.close + 1
            return nil, hostile, "EIO"
          elseif lifetime.role == "cleanup-review" then
            row.injection.close = row.injection.close + 1
            return true, hostile, "EBADF"
          elseif lifetime.role == "cleanup-reviews" then
            row.injection.close = row.injection.close + 1
            return nil, hostile, "EMFILE"
          elseif lifetime.role == "removal-review" then
            row.injection.close = row.injection.close + 1
            return nil, hostile, "EBADF"
          elseif lifetime.role == "removal-reviews" then
            row.injection.close = row.injection.close + 1
            return nil, hostile, "EMFILE"
          end
        end
        return closed, close_error, close_code
      end

      dependencies.write = function(fd, bytes, offset)
        note()
        local lifetime = descriptors[fd]
        if lifetime and lifetime.role == "manifest-writer" and row.injection.write == 0 then
          local stat = vim.uv.fs_fstat(fd)
          row.manifest_stat_exact = type(stat) == "table" and stat.type == "file"
          row.injection.write = 1
          failure_started = true
          table.insert(row.events, "manifest-write")
          probe_collector("manifest-write")
          return nil, hostile, "ENOSPC"
        end
        return vim.uv.fs_write(fd, bytes, offset)
      end

      dependencies.fsync = function(fd)
        note()
        local lifetime = descriptors[fd]
        local synced, sync_error, sync_code = vim.uv.fs_fsync(fd)
        if synced and lifetime and lifetime.role == "cleanup-objects" then
          row.injection.fsync = row.injection.fsync + 1
          table.insert(row.events, "fsync-cleanup-objects")
          probe_collector("fsync-cleanup-objects")
          return nil, hostile, "ENOSPC"
        elseif synced and lifetime and lifetime.role == "cleanup-review" then
          row.injection.fsync = row.injection.fsync + 1
          table.insert(row.events, "fsync-cleanup-review")
          probe_collector("fsync-cleanup-review")
          return nil, hostile, "EIO"
        end
        return synced, sync_error, sync_code
      end

      dependencies.rmdir = function(path)
        note()
        local name = basename(path)
        local token
        if review_id and name == ".owned-cleanup-review-" .. review_id then
          token = "rmdir-cleanup-review"
        elseif review_id and name == ".owned-removing-review-" .. review_id then
          token = "rmdir-removal-review"
          failure_started = true
        end
        if token then
          row.injection.rmdir = row.injection.rmdir + 1
          table.insert(row.events, token)
          probe_collector(token)
          return nil, hostile, "EACCES"
        end
        return vim.uv.fs_rmdir(path)
      end

      local lease = {}
      row.lease = lease
      function lease:release()
        row.release_count = row.release_count + 1
        if not rawequal(self, lease) then
          row.receiver_exact = false
        end
        if released then
          return nil, spec.release_error
        end
        row.physical_release_count = row.physical_release_count + 1
        if not held or not rawequal(active_lease, lease) then
          row.held_violations = row.held_violations + 1
        end
        probe_collector("release")
        row.release_after_close = true
        row.release_ebadf = true
        for index = scope_start + 1, #lifetimes do
          local lifetime = lifetimes[index]
          if lifetime.active or lifetime.close_attempts ~= 1 or lifetime.physical_close ~= true then
            row.release_after_close = false
          end
          local stat, _, code = vim.uv.fs_fstat(lifetime.fd)
          if stat ~= nil or code ~= "EBADF" then
            row.release_ebadf = false
          end
        end
        table.insert(row.events, "release")
        held = false
        released = true
        active_lease = nil
        return nil, spec.release_error
      end

      local serializer = {}
      function serializer.acquire(root, passed)
        row.acquire_count = row.acquire_count + 1
        if row.acquire_count ~= 1 or held then
          row.recursive = row.recursive + 1
        end
        if released then
          row.after_release = row.after_release + 1
        end
        if root ~= fixture.state then
          row.root_exact = false
        end
        local matches = type(passed) == "table" and passed.serialization == serializer
        for _, name in ipairs(dependency_names) do
          matches = matches and passed[name] == dependencies[name]
        end
        row.dependency_exact = row.dependency_exact and matches
        held = true
        active_lease = lease
        table.insert(row.events, "acquire")
        return lease
      end
      dependencies.serialization = serializer

      local module = baseline_module._test.new(dependencies)
      local value
      local row_error
      local call_ok = false
      local status_before
      local objects_before
      if not publication then
        status_before = fixture:status_bytes()
        objects_before = fixture:object_count()
      end
      if publication then
        call_ok, value, row_error = pcall(module.create, identity, store)
      else
        local setup_ok
        local opened
        setup_ok, opened = pcall(function()
          local created, create_error = baseline_module.create(identity, store)
          assert(created, create_error)
          review_id = created:id()
          local loaded, open_error = module.open(identity, store, review_id)
          assert(loaded, open_error)
          return loaded
        end)
        if not setup_ok then
          add_finding(harness_findings, "removal setup mismatch")
        elseif row.acquire_count ~= 0 then
          add_finding(harness_findings, "removal open acquired lease")
        else
          scope_start = #lifetimes
          call_ok, value, row_error = pcall(function()
            return opened:remove()
          end)
        end
      end
      table.insert(row.events, "return")

      local roles = {}
      for index = scope_start + 1, #lifetimes do
        table.insert(roles, lifetimes[index].role or "unknown")
      end
      local close_exact = true
      local final_ebadf = true
      for _, lifetime in ipairs(lifetimes) do
        if
          lifetime.close_attempts ~= 1
          or lifetime.physical_close ~= true
          or lifetime.active ~= false
          or lifetime.immediate_ebadf ~= true
        then
          close_exact = false
        end
        local stat, _, code = vim.uv.fs_fstat(lifetime.fd)
        if stat ~= nil or code ~= "EBADF" then
          final_ebadf = false
        end
      end

      local rescued = {}
      for _, lifetime in ipairs(lifetimes) do
        if lifetime.active then
          row.rescue = row.rescue + 1
          if rescued[lifetime.fd] then
            add_finding(harness_findings, spec.label .. " duplicate active generation")
          else
            rescued[lifetime.fd] = true
            local rescue_ok, rescued_close = pcall(vim.uv.fs_close, lifetime.fd)
            if not rescue_ok or rescued_close ~= true then
              add_finding(harness_findings, spec.label .. " descriptor rescue failed")
            end
          end
        end
      end

      local expected_write = publication and 1 or 0
      local expected_fsync = publication and 2 or 0
      local expected_close = publication and 3 or 2
      if
        row.injection.write ~= expected_write
        or row.injection.fsync ~= expected_fsync
        or row.injection.rmdir ~= 1
        or row.injection.close ~= expected_close
        or not row.manifest_stat_exact
      then
        add_finding(harness_findings, spec.label .. " injection mismatch")
      end
      if not call_ok then
        add_finding(harness_findings, spec.label .. " production call raised")
      end
      if not vim.deep_equal(roles, spec.expected_roles) then
        add_finding(harness_findings, spec.label .. " descriptor role mismatch")
      end
      if not close_exact or not final_ebadf or row.rescue ~= 0 or row.live_reuse ~= 0 then
        add_finding(harness_findings, spec.label .. " descriptor lifecycle mismatch")
      end
      if
        row.acquire_count ~= 1
        or row.release_count ~= 1
        or row.physical_release_count ~= 1
        or held
        or row.recursive ~= 0
        or row.held_violations ~= 0
        or row.after_release ~= 0
        or not row.root_exact
        or not row.dependency_exact
        or not row.receiver_exact
        or not row.release_after_close
        or not row.release_ebadf
      then
        add_finding(harness_findings, spec.label .. " lease/order mismatch")
      end
      if not vim.deep_equal(row.events, spec.expected_events) then
        add_finding(harness_findings, spec.label .. " event order mismatch")
      end
      if not vim.deep_equal(row.probes, spec.expected_probes) then
        add_finding(harness_findings, spec.label .. " collector probe mismatch")
      end

      local residue = (publication and ".owned-cleanup-review-" or ".owned-removing-review-")
        .. tostring(review_id)
      local residue_path = vim.fs.joinpath(fixture.state, "reviews", residue)
      local entries_ok, entries = pcall(review_entries, fixture)
      local residue_stat = vim.uv.fs_lstat(residue_path)
      local leaf_ok, leaf_entries = pcall(vim.fn.readdir, residue_path)
      local residue_exact = entries_ok
        and vim.deep_equal(entries, { residue })
        and type(residue_stat) == "table"
        and residue_stat.type == "directory"
        and leaf_ok
        and vim.deep_equal(leaf_entries, {})
      if not residue_exact then
        add_finding(harness_findings, spec.label .. " residue mismatch")
      end

      local git_exact = true
      if not publication then
        local git_ok, current_status, current_objects = pcall(function()
          return fixture:status_bytes(), fixture:object_count()
        end)
        git_exact = git_ok and current_status == status_before and current_objects == objects_before
      end
      if not git_exact then
        add_finding(harness_findings, spec.label .. " Git mutation mismatch")
      end

      local collector_exact = collector_identity ~= nil
        and row.collector_missing == 0
        and row.collector_mismatch == 0
        and row.collector_state_mismatch == 0
      local result_exact = call_ok
        and value == nil
        and row_error == spec.expected_error
        and row.renderings == 0
        and collector_exact
      if not result_exact then
        add_finding(behavior_findings, spec.label .. " collector/result mismatch")
      end
      table.insert(
        observations,
        string.format(
          "%s result=%s life=%d close=%s/%s lease=%d/%d/%d collector=%s/%d/%d/%d residue=%s git=%s hostile=%d events=%s",
          spec.label,
          tostring(result_exact),
          #roles,
          tostring(close_exact),
          tostring(final_ebadf),
          row.acquire_count,
          row.release_count,
          row.physical_release_count,
          tostring(collector_identity ~= nil),
          row.collector_missing,
          row.collector_mismatch,
          row.collector_state_mismatch,
          tostring(residue_exact),
          tostring(git_exact),
          row.renderings,
          table.concat(row.events, ",")
        )
      )
    end

    for _, spec in ipairs(specs) do
      run_row(spec)
    end
    local diagnostic = "Cycle 6C-3 transaction failures: harness="
      .. (#harness_findings == 0 and "none" or table.concat(harness_findings, ", "))
      .. " behavior="
      .. (#behavior_findings == 0 and "none" or table.concat(behavior_findings, ", "))
      .. " | observations: "
      .. table.concat(observations, "; ")
    assert(#diagnostic <= 1536, "Cycle 6C-3 transaction diagnostic overflow")
    if #harness_findings > 0 or #behavior_findings > 0 then
      error(diagnostic, 0)
    end
  end

  do
    local harness_findings = {}
    local behavior_findings = {}
    local observations = {}

    local function add_finding(findings, label)
      for _, existing in ipairs(findings) do
        if existing == label then
          return
        end
      end
      if #findings < 8 then
        table.insert(findings, label)
      elseif findings[#findings] ~= "additional" then
        table.insert(findings, "additional")
      end
    end

    local function same_directory_identity(left, right)
      if type(left) ~= "table" or type(right) ~= "table" then
        return false
      end
      for _, field in ipairs({ "dev", "ino", "type", "uid", "gid", "mode" }) do
        if
          left[field] == nil
          or right[field] == nil
          or not vim.deep_equal(left[field], right[field])
        then
          return false
        end
      end
      return left.type == "directory"
    end

    local function named_upvalue(fn, target)
      if type(fn) ~= "function" then
        return nil
      end
      for index = 1, 64 do
        local ok, name, value = pcall(debug.getupvalue, fn, index)
        if not ok or name == nil then
          break
        end
        if name == target then
          return value
        end
      end
      return nil
    end

    local specs = {
      {
        label = "publication",
        publication = true,
        prefix = "cleanup",
        phase_name = ".cleanup-",
        owned_object_prefix = ".owned-cleanup-",
        owned_manifest_prefix = ".owned-cleanup-manifest-",
        owned_objects_prefix = ".owned-cleanup-objects-",
        owned_review_prefix = ".owned-cleanup-review-",
        selected_kind = "visible",
        expected_error = "could not scan baseline storage: injected Cycle 6D load failure"
          .. "; publication cleanup failed"
          .. "; verify-cleanup-review-absent (UNKNOWN)",
        finding = "publication absence rejection missing",
      },
      {
        label = "removal",
        publication = false,
        prefix = "removal",
        phase_name = ".removing-",
        owned_object_prefix = ".owned-",
        owned_manifest_prefix = ".owned-manifest-",
        owned_objects_prefix = ".owned-removing-objects-",
        owned_review_prefix = ".owned-removing-review-",
        selected_kind = "error",
        expected_error = "baseline review directory absence could not be verified (EIO)",
        finding = "removal absence rejection missing",
      },
    }

    local function run_row(spec)
      local fixture = Fixture.new("cycle-6d-" .. spec.label)
      fixture:write("a.txt", "committed-a\n")
      fixture:write("z.txt", "committed-z\n")
      fixture:commit("cycle 6d")
      fixture:write("a.txt", "dirty-a\n")
      fixture:write("z.txt", "dirty-z\n")

      local identity = fixture:identity()
      local real_store = fixture:store()
      local store = real_store
      local reviews_path = vim.fs.joinpath(fixture.state, "reviews")
      local review_id
      local review_path
      local object_names = {
        vim.fn.sha256("dirty-a\n"),
        vim.fn.sha256("dirty-z\n"),
      }
      table.sort(object_names)
      local object_index = {}
      for index, name in ipairs(object_names) do
        object_index[name] = index
      end

      local row = {
        exercise = false,
        cleanup_started = false,
        held = false,
        released = false,
        acquire_count = 0,
        release_count = 0,
        physical_release_count = 0,
        held_violations = 0,
        after_release = 0,
        dependency_exact = true,
        receiver_exact = true,
        root_exact = true,
        recursive = 0,
        live_reuse = 0,
        unowned_closes = 0,
        immediate_ebadf = true,
        final_ebadf = true,
        close_exact = true,
        arm_exact = true,
        anchor_exact = true,
        native_absent = true,
        order_exact = true,
        release_proof_exact = false,
        release_closed_exact = false,
        injection_count = 0,
        hostile_renderings = 0,
        proofs = {},
        expected = {
          "absent-object-1",
          "absent-owned-object-1",
          "absent-object-2",
          "absent-owned-object-2",
          spec.publication and "absent-objects" or "absent-manifest",
          spec.publication and "absent-owned-objects" or "absent-owned-manifest",
          spec.publication and "absent-manifest" or "absent-objects",
          spec.publication and "absent-owned-manifest" or "absent-owned-objects",
          "absent-review",
          "absent-publishing",
          spec.publication and "absent-cleanup" or "absent-removing",
          "absent-owned-review",
        },
        proof_counts = {},
        armed = {},
        arm_order = {},
        anchors = {},
        claim_sources = {},
        operation_lifetimes = {},
        load_faults = 0,
        published = false,
        rescue = 0,
      }

      if spec.publication then
        store = {}
        function store:state_dir(...)
          return real_store.state_dir(real_store, ...)
        end
        function store:review_dir(candidate, ...)
          if review_id ~= nil and review_id ~= candidate then
            row.arm_exact = false
          end
          review_id = candidate
          review_path = vim.fs.joinpath(reviews_path, candidate)
          return real_store.review_dir(real_store, candidate, ...)
        end
      else
        local created = assert(baseline_module.create(identity, real_store))
        review_id = created:id()
        review_path = vim.fs.joinpath(reviews_path, review_id)
      end

      local native = {
        lstat = vim.uv.fs_lstat,
        realpath = vim.uv.fs_realpath,
        readlink = vim.uv.fs_readlink,
        fstat = vim.uv.fs_fstat,
        read = vim.uv.fs_read,
        write = vim.uv.fs_write,
        fsync = vim.uv.fs_fsync,
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
          return git_executable
        end,
        revalidate_git = require("ai.tools").revalidate,
        system = function(argv, options)
          return vim.system(argv, options):wait(30000)
        end,
      }
      local dependencies
      local descriptors
      local lifetimes
      dependencies, descriptors, lifetimes = tracked_open_close_dependencies()
      local tracked_open = dependencies.open
      local tracked_close = dependencies.close
      local lease = {}
      local serializer = {}
      local hostile = setmetatable({}, {
        __tostring = function()
          row.hostile_renderings = row.hostile_renderings + 1
          return "/private/cycle6d/" .. string.rep("secret", 256)
        end,
      })

      local function note()
        if not row.exercise then
          return
        end
        if row.released then
          row.after_release = row.after_release + 1
        elseif not row.held then
          row.held_violations = row.held_violations + 1
        end
      end

      for _, name in ipairs({
        "realpath",
        "readlink",
        "fstat",
        "read",
        "write",
        "mkdir",
        "scandir_next",
        "hash",
        "uid",
        "pid",
        "hrtime",
        "resolve_git",
        "revalidate_git",
        "system",
      }) do
        local dependency_name = name
        dependencies[dependency_name] = function(...)
          note()
          return native[dependency_name](...)
        end
      end
      dependencies.after_read = function()
        note()
      end

      local function basename(path)
        return type(path) == "string" and path:match("([^/]+)$") or nil
      end

      local function operation_role(path)
        if not row.exercise or spec.publication and not row.cleanup_started then
          return nil
        end
        if path == reviews_path then
          return spec.prefix .. "-reviews"
        end
        local name = basename(path)
        if name == "objects" then
          return spec.prefix .. "-objects"
        end
        if name == spec.phase_name .. review_id then
          return spec.prefix .. "-review"
        end
        return nil
      end

      local function arm(path, token, role)
        local parent = vim.fs.dirname(path)
        local lifetime = row.anchors[parent]
        if
          row.armed[path] ~= nil
          or not lifetime
          or lifetime.role ~= role
          or lifetime.active ~= true
          or lifetime.close_attempts ~= 0
        then
          row.arm_exact = false
        end
        local required = {
          token = token,
          role = role,
          lifetime = lifetime,
          generation = lifetime and lifetime.generation or nil,
        }
        row.armed[path] = required
        table.insert(row.arm_order, token)
      end

      local function arm_object_pair(source, target, object_name)
        local index = object_index[object_name]
        if not index then
          row.arm_exact = false
          return
        end
        arm(source, "absent-object-" .. index, spec.prefix .. "-objects")
        arm(target, "absent-owned-object-" .. index, spec.prefix .. "-objects")
      end

      local function arm_manifest_pair(source, target)
        arm(source, "absent-manifest", spec.prefix .. "-review")
        arm(target, "absent-owned-manifest", spec.prefix .. "-review")
      end

      local function arm_objects_pair(source, target)
        arm(source, "absent-objects", spec.prefix .. "-review")
        arm(target, "absent-owned-objects", spec.prefix .. "-review")
      end

      local function arm_review_group(parent)
        arm(vim.fs.joinpath(parent, review_id), "absent-review", spec.prefix .. "-reviews")
        arm(
          vim.fs.joinpath(parent, ".publishing-" .. review_id),
          "absent-publishing",
          spec.prefix .. "-reviews"
        )
        arm(
          vim.fs.joinpath(parent, spec.phase_name .. review_id),
          spec.publication and "absent-cleanup" or "absent-removing",
          spec.prefix .. "-reviews"
        )
        arm(
          vim.fs.joinpath(parent, spec.owned_review_prefix .. review_id),
          "absent-owned-review",
          spec.prefix .. "-reviews"
        )
      end

      dependencies.open = function(path, flags, mode)
        note()
        local fd, open_error, open_code = tracked_open(path, flags, mode)
        if fd ~= nil then
          local lifetime = descriptors[fd]
          for index = 1, #lifetimes - 1 do
            local prior = lifetimes[index]
            if prior.fd == fd and prior.active then
              row.live_reuse = row.live_reuse + 1
            end
          end
          lifetime.role = operation_role(path)
          if lifetime.role then
            table.insert(row.operation_lifetimes, lifetime)
          end
        end
        return fd, open_error, open_code
      end

      dependencies.fd_path = function(fd)
        note()
        local lifetime = descriptors[fd]
        for _, prefix in ipairs({ "/proc/self/fd/", "/dev/fd/" }) do
          local path = prefix .. tostring(fd)
          if native.lstat(path) then
            if lifetime then
              lifetime.anchor_path = path
              lifetime.anchor_identity = native.fstat(fd)
              row.anchors[path] = lifetime
            else
              row.arm_exact = false
            end
            return path
          end
        end
        return nil, "stable directory descriptor path is unavailable"
      end

      dependencies.lstat = function(path)
        note()
        local stat, stat_error, stat_code = native.lstat(path)
        local required = row.armed[path]
        if not required then
          return stat, stat_error, stat_code
        end

        row.proof_counts[required.token] = (row.proof_counts[required.token] or 0) + 1
        table.insert(row.proofs, required.token)

        local parent = vim.fs.dirname(path)
        local lifetime = row.anchors[parent]
        local opened = lifetime and native.fstat(lifetime.fd) or nil
        local anchored = lifetime and native.lstat(parent .. "/.") or nil
        if
          not lifetime
          or not rawequal(lifetime, required.lifetime)
          or lifetime.generation ~= required.generation
          or lifetime.role ~= required.role
          or lifetime.active ~= true
          or lifetime.close_attempts ~= 0
          or not same_directory_identity(lifetime.anchor_identity, opened)
          or not same_directory_identity(lifetime.anchor_identity, anchored)
        then
          row.anchor_exact = false
        end
        if not row.held or row.released then
          row.held_violations = row.held_violations + 1
        end
        if stat ~= nil or stat_code ~= "ENOENT" then
          row.native_absent = false
        end

        if required.token == "absent-owned-review" then
          row.injection_count = row.injection_count + 1
          if spec.selected_kind == "visible" then
            if type(row.selected_identity) ~= "table" then
              row.arm_exact = false
              return { type = "directory" }
            end
            return copy(row.selected_identity)
          end
          return nil, hostile, "EIO"
        end
        return stat, stat_error, stat_code
      end

      local publish_function

      dependencies.rename = function(source, target)
        note()
        local renamed, rename_error, rename_code = native.rename(source, target)
        if renamed == true and rename_error == nil and rename_code == nil then
          local caller = debug.getinfo(2, "f")
          row.claim_sources[target] = source
          local target_parent = vim.fs.dirname(target)
          local reviews_lifetime = row.anchors[target_parent]
          if
            spec.publication
            and type(review_id) == "string"
            and type(review_path) == "string"
            and type(publish_function) == "function"
            and type(caller) == "table"
            and rawequal(caller.func, publish_function)
            and reviews_lifetime
            and reviews_lifetime.active == true
            and reviews_lifetime.close_attempts == 0
            and reviews_lifetime.path == reviews_path
            and reviews_lifetime.anchor_path == target_parent
            and rawequal(descriptors[reviews_lifetime.fd], reviews_lifetime)
            and row.claim_sources[source] == target
            and source == vim.fs.joinpath(target_parent, ".publishing-" .. review_id)
            and target == vim.fs.joinpath(target_parent, review_id)
            and same_directory_identity(
              reviews_lifetime.anchor_identity,
              native.fstat(reviews_lifetime.fd)
            )
            and same_directory_identity(
              reviews_lifetime.anchor_identity,
              native.lstat(target_parent .. "/.")
            )
            and same_directory_identity(
              reviews_lifetime.anchor_identity,
              native.lstat(reviews_path)
            )
            and same_directory_identity(native.lstat(target), native.lstat(review_path))
          then
            row.published = true
          end
        end
        return renamed, rename_error, rename_code
      end

      dependencies.unlink = function(path)
        note()
        local removed, remove_error, remove_code = native.unlink(path)
        if removed == true and row.exercise then
          local name = basename(path)
          local source = row.claim_sources[path]
          if not source then
            row.arm_exact = false
          elseif name == spec.owned_manifest_prefix .. review_id then
            arm_manifest_pair(source, path)
          else
            local object_name
            if spec.publication then
              object_name = name
                and name:match("^%.owned%-cleanup%-" .. review_id .. "%-([0-9a-f]+)$")
            else
              object_name = name and name:match("^%.owned%-" .. review_id .. "%-([0-9a-f]+)$")
            end
            if object_name then
              arm_object_pair(source, path, object_name)
            end
          end
        end
        return removed, remove_error, remove_code
      end

      dependencies.rmdir = function(path)
        note()
        local name = basename(path)
        local selected = type(review_id) == "string"
          and name == spec.owned_review_prefix .. review_id
        local selected_identity = selected and native.lstat(path) or nil
        local removed, remove_error, remove_code = native.rmdir(path)
        if removed == true and row.exercise then
          local source = row.claim_sources[path]
          if not source then
            row.arm_exact = false
          elseif name == spec.owned_objects_prefix .. review_id then
            arm_objects_pair(source, path)
          elseif selected then
            row.selected_identity = selected_identity
            arm_review_group(vim.fs.dirname(path))
          end
        end
        return removed, remove_error, remove_code
      end

      dependencies.fsync = function(fd)
        note()
        local lifetime = descriptors[fd]
        local role = lifetime and lifetime.role or nil
        local required_count = role == spec.prefix .. "-objects" and (spec.publication and 4 or 6)
          or role == spec.prefix .. "-review" and 8
          or role == spec.prefix .. "-reviews" and 12
          or nil
        if required_count and #row.proofs ~= required_count then
          row.order_exact = false
        end
        local synced, sync_error, sync_code = native.fsync(fd)
        if required_count then
          lifetime.synced = synced == true
          if synced ~= true or sync_error ~= nil or sync_code ~= nil then
            row.order_exact = false
          end
        end
        return synced, sync_error, sync_code
      end

      dependencies.close = function(fd)
        note()
        local lifetime = descriptors[fd]
        if not lifetime then
          row.unowned_closes = row.unowned_closes + 1
          return nil, "untracked descriptor", "EBADF"
        end
        local role = lifetime.role
        if role and lifetime.synced ~= true then
          row.order_exact = false
        end
        local closed, close_error, close_code = tracked_close(fd)
        if role and (closed ~= true or close_error ~= nil or close_code ~= nil) then
          row.close_exact = false
        end
        local stat, _, code = native.fstat(fd)
        lifetime.immediate_ebadf = stat == nil and code == "EBADF"
        if not lifetime.immediate_ebadf then
          row.immediate_ebadf = false
        end
        return closed, close_error, close_code
      end

      dependencies.scandir = function(path)
        note()
        if spec.publication and row.published and row.load_faults == 0 and path == review_path then
          row.load_faults = row.load_faults + 1
          row.cleanup_started = true
          return nil, "injected Cycle 6D load failure", "EIO"
        end
        return native.scandir(path)
      end

      function serializer.acquire(root, passed)
        row.acquire_count = row.acquire_count + 1
        if row.acquire_count ~= 1 or row.held then
          row.recursive = row.recursive + 1
        end
        row.exercise = true
        row.held = true
        row.root_exact = row.root_exact and root == fixture.state
        row.dependency_exact = row.dependency_exact
          and type(passed) == "table"
          and passed.serialization == serializer
          and passed.open == dependencies.open
          and passed.close == dependencies.close
          and passed.lstat == dependencies.lstat
          and passed.unlink == dependencies.unlink
          and passed.rmdir == dependencies.rmdir
          and passed.rename == dependencies.rename
          and passed.fsync == dependencies.fsync
          and passed.fd_path == dependencies.fd_path
        return lease
      end

      function lease:release()
        row.release_count = row.release_count + 1
        if not rawequal(self, lease) then
          row.receiver_exact = false
        end
        if row.release_count ~= 1 or not row.held or row.released then
          row.held_violations = row.held_violations + 1
        end
        row.physical_release_count = row.physical_release_count + 1
        row.release_proof_exact = #row.expected == 12
          and vim.deep_equal(row.arm_order, row.expected)
          and vim.deep_equal(row.proofs, row.expected)
          and row.injection_count == 1
        row.release_closed_exact = true
        for _, lifetime in ipairs(row.operation_lifetimes) do
          if lifetime.active or lifetime.close_attempts ~= 1 or lifetime.physical_close ~= true then
            row.release_closed_exact = false
          end
        end
        row.held = false
        row.released = true
        return true
      end

      dependencies.serialization = serializer
      local module = baseline_module._test.new(dependencies)
      local create_under_lease = named_upvalue(module.create, "create_under_lease")
      publish_function = named_upvalue(create_under_lease, "publish")
      local status_before = fixture:status_bytes()
      local objects_before = fixture:object_count()
      local call_ok
      local value
      local row_error

      if spec.publication then
        call_ok, value, row_error = pcall(module.create, identity, store)
      else
        local opened = assert(module.open(identity, real_store, review_id))
        call_ok, value, row_error = pcall(function()
          return opened:remove()
        end)
      end

      for _, lifetime in ipairs(lifetimes) do
        local stat, _, code = native.fstat(lifetime.fd)
        if stat ~= nil or code ~= "EBADF" then
          row.final_ebadf = false
        end
        if
          lifetime.close_attempts ~= 1
          or lifetime.physical_close ~= true
          or lifetime.active ~= false
          or lifetime.immediate_ebadf ~= true
        then
          row.close_exact = false
        end
      end

      local rescued = {}
      for _, lifetime in ipairs(lifetimes) do
        if lifetime.active then
          row.rescue = row.rescue + 1
          if not rescued[lifetime.fd] then
            rescued[lifetime.fd] = true
            pcall(vim.uv.fs_close, lifetime.fd)
          end
        end
      end

      local entries_ok, entries = pcall(review_entries, fixture)
      local residue_exact = entries_ok and type(entries) == "table" and #entries == 0
      local git_exact = fixture:status_bytes() == status_before
        and fixture:object_count() == objects_before

      local harness_exact = object_names[1] ~= object_names[2]
        and row.arm_exact
        and row.live_reuse == 0
        and row.unowned_closes == 0
        and (not spec.publication or row.published and row.load_faults == 1)
      if not harness_exact then
        add_finding(harness_findings, spec.label .. " harness mismatch")
      end

      local proof_counts_exact = true
      for _, token in ipairs(row.expected) do
        if row.proof_counts[token] ~= 1 then
          proof_counts_exact = false
        end
      end
      local rejected_exact = call_ok and value == nil and row_error == spec.expected_error
      local behavior_exact = rejected_exact
        and #row.expected == 12
        and #row.arm_order == 12
        and #row.proofs == 12
        and vim.deep_equal(row.arm_order, row.expected)
        and proof_counts_exact
        and vim.deep_equal(row.proofs, row.expected)
        and row.injection_count == 1
        and row.anchor_exact
        and row.native_absent
        and row.order_exact
        and row.release_proof_exact
        and row.release_closed_exact
        and row.hostile_renderings == 0
        and row.acquire_count == 1
        and row.release_count == 1
        and row.physical_release_count == 1
        and row.recursive == 0
        and row.held == false
        and row.released
        and row.held_violations == 0
        and row.after_release == 0
        and row.dependency_exact
        and row.receiver_exact
        and row.root_exact
        and row.close_exact
        and row.immediate_ebadf
        and row.final_ebadf
        and row.rescue == 0
        and residue_exact
        and git_exact
      if not behavior_exact then
        add_finding(behavior_findings, spec.finding)
      end

      table.insert(
        observations,
        string.format(
          "%s reject=%s proofs=%d/%d inject=%d anchor=%s native=%s order=%s close=%s/%s lease=%d/%d/%d release=%s/%s residue=%s git=%s hostile=%d",
          spec.label,
          tostring(rejected_exact),
          #row.proofs,
          #row.expected,
          row.injection_count,
          tostring(row.anchor_exact),
          tostring(row.native_absent),
          tostring(row.order_exact),
          tostring(row.close_exact),
          tostring(row.final_ebadf),
          row.acquire_count,
          row.release_count,
          row.physical_release_count,
          tostring(row.release_proof_exact),
          tostring(row.release_closed_exact),
          tostring(residue_exact),
          tostring(git_exact),
          row.hostile_renderings
        )
      )
    end

    for _, spec in ipairs(specs) do
      run_row(spec)
    end

    local diagnostic = "Cycle 6D absence failures: harness="
      .. (#harness_findings == 0 and "none" or table.concat(harness_findings, ", "))
      .. " behavior="
      .. (#behavior_findings == 0 and "none" or table.concat(behavior_findings, ", "))
      .. " | observations: "
      .. table.concat(observations, "; ")
    assert(#diagnostic <= 1024, "Cycle 6D absence diagnostic overflow")
    if #harness_findings > 0 or #behavior_findings > 0 then
      error(diagnostic, 0)
    end
  end

  do
    local fixture = Fixture.new("cycle-6e-private-mode-tracker-cleanup")
    fixture:write("dirty.txt", "committed\n")
    fixture:commit("private mode tracker cleanup")
    fixture:write("dirty.txt", "dirty\n")

    local identity = fixture:identity()
    local store = fixture:store()
    local lock_path = vim.fs.joinpath(fixture.state, ".baseline-serialization")
    local reviews_path = vim.fs.joinpath(fixture.state, "reviews")
    local current_uid = vim.uv.getuid()
    local mode_counts = {
      state = 0,
      lock = 0,
      reviews = 0,
      review = 0,
      objects = 0,
    }
    local expected_mode_counts = {
      state = 3,
      lock = 2,
      reviews = 3,
      review = 2,
      objects = 2,
    }
    local modes_exact = true

    local function physical_directory(path, permissions)
      if type(path) ~= "string" or path:sub(1, 1) ~= "/" or type(current_uid) ~= "number" then
        return false
      end

      local direct = vim.uv.fs_lstat(path)
      local physical = vim.uv.fs_realpath(path)
      local resolved = type(physical) == "string" and vim.uv.fs_lstat(physical) or nil
      if
        type(direct) ~= "table"
        or direct.type ~= "directory"
        or direct.uid ~= current_uid
        or type(direct.mode) ~= "number"
        or mode_bits(direct) ~= permissions
        or physical ~= path
        or type(resolved) ~= "table"
      then
        return false
      end

      for _, field in ipairs({
        "dev",
        "ino",
        "type",
        "uid",
        "gid",
        "mode",
      }) do
        if
          direct[field] == nil
          or resolved[field] == nil
          or not vim.deep_equal(direct[field], resolved[field])
        then
          return false
        end
      end
      return true
    end

    local function sample_mode(role, path)
      mode_counts[role] = mode_counts[role] + 1
      local exact = physical_directory(path, 448)
      modes_exact = exact and modes_exact
    end

    local negative_path = vim.fs.joinpath(fixture.base, "mode-negative-control")
    assert(vim.uv.fs_mkdir(negative_path, 493), "could not create Cycle 6E negative mode control")
    assert(vim.uv.fs_chmod(negative_path, 493), "could not chmod Cycle 6E negative mode control")
    local negative_control_exact = physical_directory(negative_path, 493)
      and not physical_directory(negative_path, 448)

    local function absent(path)
      local stat, _, code = vim.uv.fs_lstat(path)
      return stat == nil and code == "ENOENT"
    end

    local dependencies
    local descriptors
    local lifetimes
    dependencies, descriptors, lifetimes = tracked_open_close_dependencies()
    local tracked_close = dependencies.close
    dependencies.close = function(fd)
      local lifetime = descriptors[fd]
      local closed, close_error, close_code = tracked_close(fd)
      local final_stat, _, final_code = vim.uv.fs_fstat(fd)
      local immediate_exact = lifetime ~= nil and final_stat == nil and final_code == "EBADF"
      if lifetime then
        lifetime.immediate_ebadf = immediate_exact
      end
      return closed, close_error, close_code
    end

    local function active_lifetimes()
      local count = 0
      for _, lifetime in ipairs(lifetimes) do
        if lifetime.active then
          count = count + 1
        end
      end
      return count
    end

    local events = {}
    local acquire_lifetimes = {}
    local release_lifetimes = {}
    local release_records = {}
    local acquire_count = 0
    local release_count = 0
    local physical_release_count = 0
    local root_exact = true
    local dependency_exact = true
    local expected_dependencies
    local serializer = {}

    local function event(value)
      table.insert(events, value)
    end

    function serializer.acquire(root, passed)
      acquire_count = acquire_count + 1
      root_exact = root_exact and root == fixture.state
      local current_dependency_exact = type(passed) == "table"
        and passed.serialization == serializer
        and passed.open == dependencies.open
        and passed.close == dependencies.close
      if expected_dependencies == nil then
        expected_dependencies = passed
      else
        current_dependency_exact = current_dependency_exact
          and rawequal(passed, expected_dependencies)
      end
      dependency_exact = dependency_exact and current_dependency_exact

      local lease, acquire_error = serialization.acquire(root, passed)
      if not lease then
        return nil, acquire_error
      end

      table.insert(acquire_lifetimes, #lifetimes)
      event("acquire-" .. acquire_count)
      sample_mode("state", fixture.state)
      sample_mode("lock", lock_path)

      local physical_release = lease.release
      local release_index = #release_records + 1
      local record = {
        calls = 0,
        receiver_exact = true,
        result_exact = false,
        lock_absent = false,
      }
      table.insert(release_records, record)

      function lease:release()
        record.calls = record.calls + 1
        release_count = release_count + 1
        record.receiver_exact = record.receiver_exact and rawequal(self, lease)
        record.active_before = active_lifetimes()

        local released, release_error = physical_release(self)
        record.result_exact = released == true and release_error == nil
        record.active_after = active_lifetimes()
        record.lock_absent = absent(lock_path)
        if record.calls == 1 and record.result_exact then
          physical_release_count = physical_release_count + 1
        end

        table.insert(release_lifetimes, #lifetimes)
        event("release-" .. release_index)
        return released, release_error
      end

      return lease
    end

    dependencies.serialization = serializer
    local production = baseline_module._test.new(dependencies)

    local create_count = 0
    local remove_count = 0
    local fingerprint_calls = 0
    local hostile_tostring_calls = 0
    local create_arguments_exact = true
    local create_result_exact = false
    local remove_method_exact = false
    local remove_receiver_exact = false
    local remove_result_exact = false
    local review_id
    local review_path
    local objects_path

    local tracker_baseline = {
      _internal = baseline_module._internal,
    }

    function tracker_baseline.create(received_identity, received_store)
      create_count = create_count + 1
      event("create")
      create_arguments_exact = create_arguments_exact
        and rawequal(received_identity, identity)
        and rawequal(received_store, store)

      local created, create_error = production.create(received_identity, received_store)
      create_result_exact = type(created) == "table" and create_error == nil
      if not created then
        return nil, create_error
      end

      review_id = created:id()
      review_path = vim.fs.joinpath(reviews_path, review_id)
      objects_path = vim.fs.joinpath(review_path, "objects")
      sample_mode("reviews", reviews_path)
      sample_mode("review", review_path)
      sample_mode("objects", objects_path)

      local public_remove = created.remove
      remove_method_exact = type(public_remove) == "function"

      created.remove = function(receiver)
        remove_count = remove_count + 1
        event("remove")
        remove_receiver_exact = rawequal(receiver, created)

        sample_mode("reviews", reviews_path)
        sample_mode("review", review_path)
        sample_mode("objects", objects_path)

        if type(public_remove) ~= "function" then
          return nil, "public baseline removal is unavailable"
        end
        local removed, remove_error = public_remove(receiver)
        remove_result_exact = removed == true and remove_error == nil
        if remove_result_exact then
          sample_mode("state", fixture.state)
          sample_mode("reviews", reviews_path)
        end
        return removed, remove_error
      end

      return created
    end

    local hostile = setmetatable({}, {
      __tostring = function()
        hostile_tostring_calls = hostile_tostring_calls + 1
        return "/private/cycle6e/secret"
      end,
    })

    local tracker = tracker_module._test.new({
      identity = identity,
      store = store,
      baseline_module = tracker_baseline,
      fingerprint_hash = function()
        fingerprint_calls = fingerprint_calls + 1
        event("fingerprint")
        error(hostile, 0)
      end,
      start_watchers = false,
    })

    local supplied_baseline_slots = 0
    local supplied_baseline_nil = false
    for index = 1, 64 do
      local ok, name, value = pcall(debug.getupvalue, tracker.ensure_batch, index)
      if not ok or name == nil then
        break
      end
      if name == "supplied_baseline" then
        supplied_baseline_slots = supplied_baseline_slots + 1
        supplied_baseline_nil = value == nil
      end
    end

    local status_before = fixture:status_bytes()
    local objects_before = fixture:object_count()
    local ensure_ok, batch, batch_error = pcall(tracker.ensure_batch, tracker)

    local final_ebadf = true
    for _, lifetime in ipairs(lifetimes) do
      local stat, _, code = vim.uv.fs_fstat(lifetime.fd)
      final_ebadf = final_ebadf and stat == nil and code == "EBADF"
    end

    local rescue_count = 0
    for fd, lifetime in pairs(descriptors) do
      if lifetime.active then
        rescue_count = rescue_count + 1
        pcall(vim.uv.fs_close, fd)
      end
    end

    local shutdown_ok, shutdown_result = pcall(tracker.shutdown, tracker)
    local shutdown_exact = shutdown_ok and shutdown_result == true

    local descriptor_exact = #lifetimes == 17
    local seen_generations = {}
    for _, lifetime in ipairs(lifetimes) do
      local expected_generation = (seen_generations[lifetime.fd] or 0) + 1
      seen_generations[lifetime.fd] = expected_generation
      descriptor_exact = descriptor_exact
        and lifetime.open_succeeded == true
        and type(lifetime.path) == "string"
        and lifetime.generation == expected_generation
        and lifetime.close_attempts == 1
        and lifetime.physical_close == true
        and lifetime.physical_close_error == nil
        and lifetime.physical_close_code == nil
        and lifetime.active == false
        and lifetime.immediate_ebadf == true
    end
    for fd, lifetime in pairs(descriptors) do
      descriptor_exact = descriptor_exact
        and lifetime.generation == seen_generations[fd]
        and lifetime.active == false
    end
    descriptor_exact = descriptor_exact and final_ebadf and rescue_count == 0

    local function exact_sequence(actual, expected)
      if #actual ~= #expected then
        return false
      end
      for index, value in ipairs(expected) do
        if actual[index] ~= value then
          return false
        end
      end
      return true
    end

    local acquire_checkpoints_exact = exact_sequence(acquire_lifetimes, { 4, 14 })
    local release_checkpoints_exact = exact_sequence(release_lifetimes, { 12, 17 })

    local lease_records_exact = #release_records == 2
    for _, record in ipairs(release_records) do
      lease_records_exact = lease_records_exact
        and record.calls == 1
        and record.receiver_exact
        and record.result_exact
        and record.active_before == 2
        and record.active_after == 0
        and record.lock_absent
    end

    local serialization_exact = acquire_count == 2
      and release_count == 2
      and physical_release_count == 2
      and root_exact
      and dependency_exact
      and expected_dependencies ~= nil
      and acquire_checkpoints_exact
      and release_checkpoints_exact
      and lease_records_exact

    local mode_exact = modes_exact
      and negative_control_exact
      and vim.deep_equal(mode_counts, expected_mode_counts)

    local tracker_exact = ensure_ok
      and batch == nil
      and batch_error == "review baseline manifest initialization raised an exception"
      and supplied_baseline_slots == 1
      and supplied_baseline_nil
      and create_count == 1
      and create_arguments_exact
      and create_result_exact
      and type(review_id) == "string"
      and review_id:match("^[0-9a-f]+$") ~= nil
      and #review_id == 32
      and fingerprint_calls == 1
      and remove_count == 1
      and remove_method_exact
      and remove_receiver_exact
      and remove_result_exact
      and hostile_tostring_calls == 0
      and shutdown_exact

    local reviews_ok, remaining_reviews = pcall(review_entries, fixture)
    local state_ok, state_entries = pcall(vim.fn.readdir, fixture.state)
    if state_ok and type(state_entries) == "table" then
      table.sort(state_entries)
    end
    local residue_exact = reviews_ok
      and vim.deep_equal(remaining_reviews, {})
      and state_ok
      and vim.deep_equal(state_entries, { "reviews" })
      and absent(lock_path)
      and type(review_path) == "string"
      and absent(review_path)
      and type(objects_path) == "string"
      and absent(objects_path)

    local git_ok, status_after, objects_after = pcall(function()
      return fixture:status_bytes(), fixture:object_count()
    end)
    local git_exact = git_ok and status_after == status_before and objects_after == objects_before

    local lifecycle_exact = exact_sequence(events, {
      "create",
      "acquire-1",
      "release-1",
      "fingerprint",
      "remove",
      "acquire-2",
      "release-2",
    })

    local findings = {}
    if not mode_exact then
      table.insert(findings, "private directory mode contract mismatch")
    end
    if not acquire_checkpoints_exact then
      table.insert(findings, "successful post-acquire lifetime checkpoints mismatch")
    end
    if not release_checkpoints_exact then
      table.insert(findings, "successful post-release lifetime checkpoints mismatch")
    end
    if not serialization_exact then
      table.insert(findings, "serialization lifecycle mismatch")
    end
    if not descriptor_exact then
      table.insert(findings, "descriptor lifecycle mismatch")
    end
    if not tracker_exact then
      table.insert(findings, "tracker public cleanup mismatch")
    end
    if not lifecycle_exact then
      table.insert(findings, "tracker cleanup order mismatch")
    end
    if not residue_exact then
      table.insert(findings, "tracker cleanup residue mismatch")
    end
    if not git_exact then
      table.insert(findings, "tracker cleanup Git state mismatch")
    end

    local diagnostic = string.format(
      "Cycle 6E lifecycle failures: %s | acquire=%d checkpoints=%s release=%d/%d checkpoints=%s descriptors=%d fstat=%s mode=%s tracker=%s residue=%s git=%s hostile=%d events=%s",
      #findings == 0 and "none" or table.concat(findings, ", "),
      acquire_count,
      table.concat(acquire_lifetimes, "/"),
      release_count,
      physical_release_count,
      table.concat(release_lifetimes, "/"),
      #lifetimes,
      tostring(final_ebadf),
      tostring(mode_exact),
      tostring(tracker_exact),
      tostring(residue_exact),
      tostring(git_exact),
      hostile_tostring_calls,
      table.concat(events, ",")
    )
    assert(#diagnostic <= 1024, "Cycle 6E lifecycle diagnostic overflow")
    assert(#findings == 0, diagnostic)
  end

  do
    local cross_race = Fixture.new("cross-file-race")
    cross_race:write("a.txt", "first before\n")
    cross_race:write("z.txt", "last before\n")
    cross_race:commit("cross-file race")
    local cross_raced = false
    local cross_race_module = baseline_module._test.new({
      after_read = function(path)
        if path == cross_race:path("z.txt") and not cross_raced then
          cross_raced = true
          cross_race:write("a.txt", "first after\n")
        end
      end,
    })
    local cross_baseline, cross_error =
      cross_race_module.create(cross_race:identity(), cross_race:store())
    rejected(
      cross_baseline,
      cross_error,
      "changed before baseline capture completed",
      "cross-file capture race rejected"
    )
    eq(cross_raced, true, "cross-file capture race was exercised")
    eq(review_entries(cross_race), {}, "cross-file capture race leaves no review")
  end

  do
    local publication_race = Fixture.new("publication-race")
    publication_race:write("dirty.txt", "committed\n")
    publication_race:commit("publication race")
    publication_race:write("dirty.txt", "captured\n")
    local publication_raced = false
    local publication_state_identity =
      assert(vim.uv.fs_lstat(publication_race.state), "state directory lstat failed")
    local publication_race_module = baseline_module._test.new({
      fsync = function(fd)
        local fd_identity = assert(vim.uv.fs_fstat(fd), "state directory fs_fstat failed")
        if
          fd_identity
          and fd_identity.dev == publication_state_identity.dev
          and fd_identity.ino == publication_state_identity.ino
          and fd_identity.type == publication_state_identity.type
          and fd_identity.uid == publication_state_identity.uid
          and fd_identity.mode == publication_state_identity.mode
        then
          return vim.uv.fs_fsync(fd)
        end
        if not publication_raced then
          publication_raced = true
          publication_race:write("dirty.txt", "changed during publication\n")
        end
        return vim.uv.fs_fsync(fd)
      end,
    })
    local publication_baseline, publication_error =
      publication_race_module.create(publication_race:identity(), publication_race:store())
    rejected(
      publication_baseline,
      publication_error,
      "changed before baseline capture completed",
      "publication-window capture race rejected"
    )
    eq(publication_raced, true, "publication-window capture race was exercised")
    assert(
      not tostring(publication_error):find("publication cleanup failed", 1, true),
      tostring(publication_error)
    )
    eq(review_entries(publication_race), {}, "publication-window race leaves no review")
  end

  do
    local publication_swap = Fixture.new("publication-storage-swap")
    publication_swap:write("dirty.txt", "committed\n")
    publication_swap:commit("publication storage swap")
    publication_swap:write("dirty.txt", "captured\n")
    local store = publication_swap:store()
    local create_review_dir = store.review_dir
    local review_dir
    function store:review_dir(review_id)
      local path, err = create_review_dir(self, review_id)
      review_dir = path
      return path, err
    end
    local saved_review
    local outside = vim.fs.joinpath(publication_swap.base, "publication-outside")
    assert(vim.fn.mkdir(outside, "p", 448) == 1)
    local swapped = false
    local function swap_review()
      if swapped or not review_dir or not vim.uv.fs_lstat(review_dir) then
        return
      end
      saved_review = review_dir .. "-saved"
      assert(vim.uv.fs_rename(review_dir, saved_review))
      assert(vim.uv.fs_symlink(outside, review_dir))
      swapped = true
    end
    local publication_swap_module = baseline_module._test.new({
      mkdir = function(path, mode)
        if review_dir and path == vim.fs.joinpath(review_dir, "objects") then
          swap_review()
        end
        return vim.uv.fs_mkdir(path, mode)
      end,
      rename = function(source, destination)
        if
          review_dir
          and source:match("([^/]+)$") == review_dir:match("([^/]+)$")
          and destination:find("/.publishing-", 1, true)
          and not swapped
        then
          swap_review()
        end
        return vim.uv.fs_rename(source, destination)
      end,
    })
    local published, publish_error =
      publication_swap_module.create(publication_swap:identity(), store)
    rejected(published, publish_error, "review", "publication storage substitution rejected")
    eq(swapped, true, "publication storage substitution was exercised")
    eq(
      vim.uv.fs_lstat(vim.fs.joinpath(outside, "objects")),
      nil,
      "publication writes no objects outside owned review"
    )
    eq(
      vim.uv.fs_lstat(vim.fs.joinpath(outside, "manifest.json")),
      nil,
      "publication writes no manifest outside owned review"
    )
  end

  do
    local cleanup_failure = Fixture.new("publication-cleanup-report")
    cleanup_failure:write("dirty.txt", "one\n")
    cleanup_failure:commit("one")
    cleanup_failure:write("dirty.txt", "two\n")
    local cleanup_failure_module = baseline_module._test.new({
      scandir = function(path)
        if path == vim.fs.joinpath(cleanup_failure.state, ".baseline-serialization") then
          return vim.uv.fs_scandir(path)
        end
        return nil, "injected persistent storage scan failure"
      end,
    })
    local unpublished, unpublished_error =
      cleanup_failure_module.create(cleanup_failure:identity(), cleanup_failure:store())
    rejected(
      unpublished,
      unpublished_error,
      "publication cleanup failed",
      "cleanup failure reported"
    )
    eq(#review_entries(cleanup_failure), 1, "unsafe cleanup leaves owned publication intact")
  end

  do
    local function exercise_cleanup_leaf_substitution(kind)
      local fixture = Fixture.new("cleanup-" .. kind .. "-leaf-race")
      fixture:write("dirty.txt", "one\n")
      fixture:commit("one")
      fixture:write("dirty.txt", "two\n")
      local store = fixture:store()
      local create_review_dir = store.review_dir
      local review_dir
      function store:review_dir(review_id)
        local path, err = create_review_dir(self, review_id)
        review_dir = path
        return path, err
      end
      local armed = false
      local swapped = false
      local target_name
      local saved_original = vim.fs.joinpath(fixture.base, "saved-cleanup-" .. kind)
      local victim_bytes = "unrelated cleanup " .. kind .. " victim\n"
      local function matches(path)
        local name = path:match("([^/]+)$")
        return kind == "manifest" and name == "manifest.json"
          or kind == "object" and name:match("^[0-9a-f]+$") and #name == 64
      end
      local function substitute(path)
        if swapped then
          return
        end
        target_name = path:match("([^/]+)$")
        assert(vim.uv.fs_rename(path, saved_original))
        write_file(path, victim_bytes, 384)
        swapped = true
      end
      local cleanup_race_module = baseline_module._test.new({
        scandir = function(path)
          if path == vim.fs.joinpath(fixture.state, ".baseline-serialization") then
            return vim.uv.fs_scandir(path)
          end
          if not armed then
            armed = true
            return nil, "injected post-publication load failure"
          end
          return vim.uv.fs_scandir(path)
        end,
        rename = function(source, destination)
          if armed and matches(source) then
            substitute(source)
          end
          return vim.uv.fs_rename(source, destination)
        end,
        unlink = function(path)
          if armed and matches(path) then
            substitute(path)
          end
          return vim.uv.fs_unlink(path)
        end,
      })
      local unpublished, unpublished_error = cleanup_race_module.create(fixture:identity(), store)
      rejected(
        unpublished,
        unpublished_error,
        "publication cleanup failed",
        kind .. " cleanup leaf substitution reported"
      )
      eq(swapped, true, kind .. " cleanup leaf substitution was exercised")
      local logical_path = kind == "manifest" and vim.fs.joinpath(review_dir, "manifest.json")
        or vim.fs.joinpath(review_dir, "objects", target_name)
      eq(read_file(logical_path), victim_bytes, kind .. " cleanup victim leaf is preserved")
      assert(read_file(saved_original):len() > 0, kind .. " cleanup original was preserved")
    end

    exercise_cleanup_leaf_substitution("object")
    exercise_cleanup_leaf_substitution("manifest")
  end

  local cycle6e = {
    dependency_names = {
      "close",
      "fd_path",
      "fstat",
      "fsync",
      "hash",
      "hrtime",
      "lstat",
      "mkdir",
      "open",
      "pid",
      "read",
      "readlink",
      "realpath",
      "rename",
      "revalidate_git",
      "rmdir",
      "scandir",
      "scandir_next",
      "system",
      "uid",
      "unlink",
      "write",
      "resolve_git",
    },
  }

  function cycle6e.directory_identity(stat, label)
    assert(type(stat) == "table", label .. " stat")
    local identity = {
      dev = stat.dev,
      ino = stat.ino,
      type = stat.type,
      uid = stat.uid,
      gid = stat.gid,
      mode = stat.mode,
    }
    for _, field in ipairs({ "dev", "ino", "type", "uid", "gid", "mode" }) do
      assert(identity[field] ~= nil, label .. " missing " .. field)
    end
    eq(identity.type, "directory", label .. " type")
    return identity
  end

  function cycle6e.is_private_physical_directory(stat, path, physical, uid)
    return type(stat) == "table"
      and stat.type == "directory"
      and stat.uid == uid
      and type(stat.mode) == "number"
      and mode_bits(stat) == 448
      and physical == path
  end

  function cycle6e.assert_private_directory(path, label)
    local stat = assert(vim.uv.fs_lstat(path), label .. " stat")
    local physical = assert(vim.uv.fs_realpath(path), label .. " physical path")
    assert(
      cycle6e.is_private_physical_directory(stat, path, physical, vim.uv.getuid()),
      label .. " is not a current-user physical mode-0700 directory"
    )
    return stat
  end

  function cycle6e.same_directory_identity(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then
      return false
    end
    for _, field in ipairs({ "dev", "ino", "type", "uid", "gid", "mode" }) do
      if
        left[field] == nil
        or right[field] == nil
        or not vim.deep_equal(left[field], right[field])
      then
        return false
      end
    end
    return left.type == "directory"
  end

  function cycle6e.new_state(label)
    return {
      label = label,
      acquire_count = 0,
      release_count = 0,
      physical_release_count = 0,
      acquire_checkpoints = {},
      release_checkpoints = {},
      release_results = {},
      transactions = {},
      state_mode_count = 0,
      lock_mode_count = 0,
      held = false,
      active_lease = nil,
      call_open = false,
      release_completed = false,
      after_release_calls = 0,
      root_exact = true,
      dependency_exact = true,
      dependency_table_exact = true,
      release_exact = true,
      release_order_exact = true,
      recursive = 0,
      live_reuse = 0,
      unowned_closes = 0,
      events = {},
    }
  end

  function cycle6e.begin_call(state, name)
    assert(not state.call_open, state.label .. " nested public-call harness")
    state.call_open = true
    state.release_completed = false
    table.insert(state.events, "call-" .. name)
  end

  function cycle6e.end_call(state, name)
    state.call_open = false
    table.insert(state.events, "return-" .. name)
  end

  function cycle6e.new_dependencies(fixture, state)
    local dependencies
    local descriptors
    local lifetimes
    dependencies, descriptors, lifetimes = tracked_open_close_dependencies()
    local tracked_open = dependencies.open
    local tracked_close = dependencies.close
    local first_dependencies

    local function note_dependency()
      if state.call_open and state.release_completed and not state.held then
        state.after_release_calls = state.after_release_calls + 1
      end
    end
    state.note_dependency = note_dependency

    local native = {
      fd_path = function(fd)
        for _, prefix in ipairs({ "/proc/self/fd/", "/dev/fd/" }) do
          local path = prefix .. tostring(fd)
          if vim.uv.fs_lstat(path) then
            return path
          end
        end
        return nil, "stable directory descriptor path is unavailable"
      end,
      fstat = vim.uv.fs_fstat,
      fsync = vim.uv.fs_fsync,
      hash = vim.fn.sha256,
      hrtime = vim.uv.hrtime,
      lstat = vim.uv.fs_lstat,
      mkdir = vim.uv.fs_mkdir,
      pid = vim.fn.getpid,
      read = vim.uv.fs_read,
      readlink = vim.uv.fs_readlink,
      realpath = vim.uv.fs_realpath,
      rename = vim.uv.fs_rename,
      revalidate_git = require("ai.tools").revalidate,
      rmdir = vim.uv.fs_rmdir,
      scandir = vim.uv.fs_scandir,
      scandir_next = vim.uv.fs_scandir_next,
      system = function(argv, options)
        return vim.system(argv, options):wait(30000)
      end,
      uid = vim.uv.getuid,
      unlink = vim.uv.fs_unlink,
      write = vim.uv.fs_write,
      resolve_git = function()
        return require("ai.tools").resolve("git")
      end,
    }

    for name, callback in pairs(native) do
      local dependency_name = name
      local dependency_callback = callback
      dependencies[dependency_name] = function(...)
        note_dependency()
        return dependency_callback(...)
      end
    end

    dependencies.open = function(path, flags, mode)
      note_dependency()
      local fd, open_error, open_code = tracked_open(path, flags, mode)
      if fd ~= nil then
        local current = descriptors[fd]
        current.flags = flags
        for index = 1, #lifetimes - 1 do
          local prior = lifetimes[index]
          if prior.fd == fd and prior.active then
            state.live_reuse = state.live_reuse + 1
          end
        end
        assert(rawequal(current, lifetimes[#lifetimes]))
      end
      return fd, open_error, open_code
    end

    dependencies.close = function(fd)
      note_dependency()
      local lifetime = descriptors[fd]
      if not lifetime or lifetime.active ~= true then
        state.unowned_closes = state.unowned_closes + 1
      end

      local closed, close_error, close_code = tracked_close(fd)
      local final_stat, _, final_code = vim.uv.fs_fstat(fd)
      if lifetime then
        lifetime.immediate_ebadf = final_stat == nil and final_code == "EBADF"
      end
      return closed, close_error, close_code
    end

    local serializer = {}
    function serializer.acquire(state_root, passed)
      state.acquire_count = state.acquire_count + 1
      if state.held then
        state.recursive = state.recursive + 1
      end
      state.root_exact = state.root_exact and state_root == fixture.state
      local functions_exact = type(passed) == "table" and passed.serialization == serializer
      for _, name in ipairs(cycle6e.dependency_names) do
        functions_exact = functions_exact and passed[name] == dependencies[name]
      end
      state.dependency_exact = state.dependency_exact and functions_exact
      if first_dependencies == nil then
        first_dependencies = passed
      else
        state.dependency_table_exact = state.dependency_table_exact
          and rawequal(first_dependencies, passed)
      end

      local transaction = {
        first = #lifetimes + 1,
        state_root = state_root,
        lock_path = vim.fs.joinpath(state_root, ".baseline-serialization"),
      }
      table.insert(state.transactions, transaction)
      local inner, acquire_error = serialization.acquire(state_root, passed)
      if not inner then
        return nil, acquire_error
      end

      local wrapped = {}
      transaction.lease = wrapped
      transaction.inner = inner
      transaction.held = true
      state.held = true
      state.active_lease = wrapped
      table.insert(state.acquire_checkpoints, #lifetimes)
      table.insert(state.events, "acquire-" .. state.acquire_count)

      cycle6e.assert_private_directory(
        state_root,
        state.label .. " state root at acquire " .. state.acquire_count
      )
      cycle6e.assert_private_directory(
        transaction.lock_path,
        state.label .. " lock at acquire " .. state.acquire_count
      )
      state.state_mode_count = state.state_mode_count + 1
      state.lock_mode_count = state.lock_mode_count + 1
      if state.after_acquire then
        state.after_acquire(state.acquire_count)
      end

      function wrapped:release()
        state.release_count = state.release_count + 1
        state.release_exact = state.release_exact
          and rawequal(self, wrapped)
          and state.held == true
          and transaction.held == true
          and rawequal(state.active_lease, wrapped)

        local active = {}
        for index = transaction.first, #lifetimes do
          local lifetime = lifetimes[index]
          if lifetime.active then
            table.insert(active, lifetime)
          end
        end
        local state_anchors = 0
        local lock_anchors = 0
        for _, lifetime in ipairs(active) do
          if lifetime.path == transaction.state_root and lifetime.close_attempts == 0 then
            state_anchors = state_anchors + 1
          elseif lifetime.path == transaction.lock_path and lifetime.close_attempts == 0 then
            lock_anchors = lock_anchors + 1
          end
        end
        transaction.pre_release_exact = #active == 2 and state_anchors == 1 and lock_anchors == 1
        state.release_order_exact = state.release_order_exact and transaction.pre_release_exact

        state.physical_release_count = state.physical_release_count + 1
        local released, release_error = inner:release()
        transaction.post_release_exact = true
        for index = transaction.first, #lifetimes do
          local lifetime = lifetimes[index]
          if
            lifetime.active
            or lifetime.close_attempts ~= 1
            or lifetime.physical_close ~= true
            or lifetime.immediate_ebadf ~= true
          then
            transaction.post_release_exact = false
          end
        end
        state.release_order_exact = state.release_order_exact and transaction.post_release_exact
        transaction.held = false
        state.held = false
        state.active_lease = nil
        state.release_completed = true
        table.insert(state.release_checkpoints, #lifetimes)
        table.insert(state.release_results, {
          value = released,
          error = release_error,
        })
        table.insert(state.events, "release-" .. state.release_count)
        return released, release_error
      end

      return wrapped
    end
    dependencies.serialization = serializer

    return dependencies, lifetimes
  end

  function cycle6e.assert_lifetimes(state, lifetimes, first, expected_count, expected_flags, label)
    eq(#lifetimes, first + expected_count, label .. " descriptor count")
    eq(state.live_reuse, 0, label .. " live descriptor reuse")
    eq(state.unowned_closes, 0, label .. " unowned closes")

    local flags = {}
    local unique_fds = {}
    for index = first + 1, #lifetimes do
      local lifetime = lifetimes[index]
      flags[lifetime.flags] = (flags[lifetime.flags] or 0) + 1
      unique_fds[lifetime.fd] = true
      eq(lifetime.open_succeeded, true, label .. " descriptor open " .. index)
      eq(lifetime.close_attempts, 1, label .. " descriptor close count " .. index)
      eq(lifetime.physical_close, true, label .. " descriptor physical close " .. index)
      eq(lifetime.immediate_ebadf, true, label .. " descriptor immediate EBADF " .. index)
      eq(lifetime.active, false, label .. " descriptor inactive " .. index)
    end
    eq(flags, expected_flags, label .. " descriptor flags")
    for fd in pairs(unique_fds) do
      local stat, _, code = vim.uv.fs_fstat(fd)
      eq(stat, nil, label .. " descriptor final stat")
      eq(code, "EBADF", label .. " descriptor final code")
    end
  end

  function cycle6e.assert_release(
    state,
    expected_count,
    expected_acquire_checkpoints,
    expected_release_checkpoints,
    label
  )
    eq(state.acquire_count, expected_count, label .. " acquire count")
    eq(state.release_count, expected_count, label .. " release count")
    eq(state.physical_release_count, expected_count, label .. " physical release count")
    eq(#state.release_results, expected_count, label .. " release result count")
    eq(state.acquire_checkpoints, expected_acquire_checkpoints, label .. " acquire checkpoints")
    eq(state.release_checkpoints, expected_release_checkpoints, label .. " release checkpoints")
    eq(state.root_exact, true, label .. " serialization root")
    eq(state.dependency_exact, true, label .. " serialization dependencies")
    eq(state.dependency_table_exact, true, label .. " dependency table identity")
    eq(state.release_exact, true, label .. " release receiver")
    eq(state.release_order_exact, true, label .. " release descriptor order")
    eq(state.recursive, 0, label .. " recursive acquisition")
    eq(state.held, false, label .. " lease held")
    eq(state.active_lease, nil, label .. " active lease")
    eq(state.call_open, false, label .. " public call open")
    eq(state.release_completed, true, label .. " release completed")
    eq(state.after_release_calls, 0, label .. " post-release dependencies")
    eq(state.state_mode_count, expected_count, label .. " state mode count")
    eq(state.lock_mode_count, expected_count, label .. " lock mode count")

    for index, result in ipairs(state.release_results) do
      eq(result.value, true, label .. " release value " .. index)
      eq(result.error, nil, label .. " release error " .. index)
    end
  end

  function cycle6e.assert_saved_directory(
    fixture,
    original_stat,
    saved_original,
    saved_physical,
    label
  )
    local saved_stat = assert(vim.uv.fs_lstat(saved_original), label .. " moved original missing")
    eq(
      cycle6e.directory_identity(saved_stat, label .. " moved original"),
      cycle6e.directory_identity(original_stat, label .. " original"),
      label .. " moved original identity and mode"
    )
    eq(saved_stat.uid, vim.uv.getuid(), label .. " moved original owner")
    eq(mode_bits(saved_stat), 448, label .. " moved original mode")
    local fixture_physical =
      assert(vim.uv.fs_realpath(fixture.base), label .. " fixture physical path")
    eq(vim.fs.dirname(saved_physical), fixture_physical, label .. " saved path containment")
  end

  function cycle6e.assert_no_residue(
    fixture,
    review_id,
    phase_prefix,
    owned_objects_prefix,
    owned_review_prefix,
    label
  )
    local reviews_path = vim.fs.joinpath(fixture.state, "reviews")
    local owned_objects_name = owned_objects_prefix .. review_id
    local parents = {
      review_id,
      ".publishing-" .. review_id,
      phase_prefix .. review_id,
      owned_review_prefix .. review_id,
    }

    eq(review_entries(fixture), {}, label .. " review entries")
    assert_absent(
      vim.fs.joinpath(fixture.state, ".baseline-serialization"),
      label .. " serialization lock"
    )
    for _, parent in ipairs(parents) do
      assert_absent(vim.fs.joinpath(reviews_path, parent), label .. " review name " .. parent)
      assert_absent(
        vim.fs.joinpath(reviews_path, parent, owned_objects_name),
        label .. " owned objects under " .. parent
      )
    end
    eq(vim.fn.readdir(fixture.state), { "reviews" }, label .. " exact state residue")
  end

  do
    local function exercise_cleanup_directory_characterization(spec)
      local fixture = Fixture.new(spec.fixture)
      fixture:write("dirty.txt", "one\n")
      fixture:commit("one")
      fixture:write("dirty.txt", "two\n")

      local status_before = fixture:status_bytes()
      local objects_before = fixture:object_count()
      local state = cycle6e.new_state(spec.label)
      local dependencies, lifetimes = cycle6e.new_dependencies(fixture, state)
      local armed = false
      local arm_count = 0
      local prearm_matches = 0
      local armed_matches = 0
      local unexpected_family_matches = 0
      local substitution_count = 0
      local native_rmdir_calls = 0
      local matching_native_rmdir_calls = 0
      local matching_native_exact = true
      local timing_exact = true
      local binding_count = 0
      local review_id
      local review_path
      local reviews_path
      local expected_name
      local expected_parent_identity
      local expected_physical_path
      local victim_path
      local original_stat
      local replacement_stat
      local replacement_physical
      local saved_physical
      local saved_original = vim.fs.joinpath(fixture.base, "saved-" .. spec.fixture)

      local function family_match(path)
        local name = type(path) == "string" and path:match("([^/]+)$") or nil
        if type(name) ~= "string" or name:sub(1, #spec.owned_prefix) ~= spec.owned_prefix then
          return false
        end
        local suffix = name:sub(#spec.owned_prefix + 1)
        return #suffix == 32 and suffix:match("^[0-9a-f]+$") ~= nil
      end

      local function exact_match(path)
        return review_id ~= nil
          and type(path) == "string"
          and path:match("([^/]+)$") == expected_name
      end

      local function substitute(path)
        substitution_count = substitution_count + 1
        table.insert(state.events, "substitute")

        local parent_stat =
          assert(vim.uv.fs_lstat(vim.fs.dirname(path) .. "/."), spec.label .. " live parent stat")
        eq(
          cycle6e.directory_identity(parent_stat, spec.label .. " live parent"),
          expected_parent_identity,
          spec.label .. " parent identity"
        )

        victim_path = assert(vim.uv.fs_realpath(path), spec.label .. " target physical path")
        eq(victim_path, expected_physical_path, spec.label .. " exact physical target")
        original_stat = assert(vim.uv.fs_lstat(path), spec.label .. " original stat")
        assert(
          cycle6e.is_private_physical_directory(
            original_stat,
            victim_path,
            victim_path,
            vim.uv.getuid()
          ),
          spec.label .. " original directory mode"
        )
        assert(vim.uv.fs_rename(path, saved_original), spec.label .. " move original")
        saved_physical =
          assert(vim.uv.fs_realpath(saved_original), spec.label .. " saved physical path")

        assert(vim.uv.fs_mkdir(path, 448), spec.label .. " create replacement")
        replacement_stat = assert(vim.uv.fs_lstat(path), spec.label .. " replacement stat")
        replacement_physical =
          assert(vim.uv.fs_realpath(path), spec.label .. " replacement physical path")
        eq(replacement_physical, victim_path, spec.label .. " replacement path")
        eq(replacement_stat.type, "directory", spec.label .. " replacement type")
        eq(replacement_stat.uid, vim.uv.getuid(), spec.label .. " replacement owner")
        eq(mode_bits(replacement_stat), 448, spec.label .. " replacement mode")
      end

      local store = fixture:store()
      local original_review_dir = store.review_dir
      store.review_dir = function(self, candidate)
        binding_count = binding_count + 1
        if review_id ~= nil then
          eq(candidate, review_id, spec.label .. " stable review id")
        end
        eq(type(candidate), "string", spec.label .. " review id type")
        eq(#candidate, 32, spec.label .. " review id length")
        assert(candidate:match("^[0-9a-f]+$"), spec.label .. " review id alphabet")
        review_id = candidate
        expected_name = spec.owned_prefix .. review_id

        local path, review_error = original_review_dir(self, candidate)
        assert(path, tostring(review_error))
        review_path = path
        reviews_path = vim.fs.dirname(path)
        local review_stat =
          assert(vim.uv.fs_lstat(review_path), spec.label .. " expected review stat")
        local reviews_stat =
          assert(vim.uv.fs_lstat(reviews_path), spec.label .. " expected reviews stat")
        expected_parent_identity = cycle6e.directory_identity(
          spec.kind == "objects" and review_stat or reviews_stat,
          spec.label .. " expected parent"
        )
        local reviews_physical =
          assert(vim.uv.fs_realpath(reviews_path), spec.label .. " reviews physical path")
        expected_physical_path = spec.kind == "objects"
            and vim.fs.joinpath(reviews_physical, ".cleanup-" .. review_id, expected_name)
          or vim.fs.joinpath(reviews_physical, expected_name)
        table.insert(state.events, "review-dir")
        return path
      end

      dependencies.scandir = function(path)
        state.note_dependency()
        if path == vim.fs.joinpath(fixture.state, ".baseline-serialization") then
          return vim.uv.fs_scandir(path)
        end
        if not armed then
          armed = true
          arm_count = arm_count + 1
          timing_exact = timing_exact
            and state.held == true
            and review_id ~= nil
            and state.acquire_count == 1
            and state.release_count == 0
          table.insert(state.events, "load-fault")
          return nil, "injected post-publication load failure"
        end
        return vim.uv.fs_scandir(path)
      end

      dependencies.rmdir = function(path)
        state.note_dependency()
        local family = family_match(path)
        local matched = exact_match(path)
        if family then
          if not armed then
            prearm_matches = prearm_matches + 1
          elseif matched then
            armed_matches = armed_matches + 1
            timing_exact = timing_exact
              and state.held == true
              and state.acquire_count == 1
              and state.release_count == 0
              and rawequal(state.active_lease, state.transactions[1].lease)
            if substitution_count == 0 then
              substitute(path)
            end
          else
            unexpected_family_matches = unexpected_family_matches + 1
          end
        end

        native_rmdir_calls = native_rmdir_calls + 1
        local removed, remove_error, remove_code = vim.uv.fs_rmdir(path)
        if matched then
          matching_native_rmdir_calls = matching_native_rmdir_calls + 1
          matching_native_exact = matching_native_exact
            and removed == true
            and remove_error == nil
            and remove_code == nil
        end
        return removed, remove_error, remove_code
      end

      local module = baseline_module._test.new(dependencies)
      cycle6e.begin_call(state, "create")
      local call_ok, unpublished, unpublished_error =
        pcall(module.create, fixture:identity(), store)
      cycle6e.end_call(state, "create")

      cycle6e.assert_lifetimes(state, lifetimes, 0, 13, { r = 11, wx = 2 }, spec.label)
      cycle6e.assert_release(state, 1, { 4 }, { 13 }, spec.label)

      eq(call_ok, true, spec.label .. " call")
      eq(unpublished, nil, spec.label .. " value")
      eq(
        unpublished_error,
        "could not scan baseline storage: injected post-publication load failure",
        spec.label .. " error"
      )
      eq(binding_count, 1, spec.label .. " review binding count")
      eq(expected_name, spec.owned_prefix .. review_id, spec.label .. " exact name")
      eq(arm_count, 1, spec.label .. " arm count")
      eq(prearm_matches, 0, spec.label .. " prearm matches")
      eq(armed_matches, 1, spec.label .. " armed matches")
      eq(unexpected_family_matches, 0, spec.label .. " unexpected family matches")
      eq(substitution_count, 1, spec.label .. " substitution count")
      eq(native_rmdir_calls, 3, spec.label .. " native rmdir count")
      eq(matching_native_rmdir_calls, 1, spec.label .. " target rmdir count")
      eq(matching_native_exact, true, spec.label .. " target native rmdir result")
      eq(timing_exact, true, spec.label .. " lease timing")
      eq(state.events, {
        "call-create",
        "acquire-1",
        "review-dir",
        "load-fault",
        "substitute",
        "release-1",
        "return-create",
      }, spec.label .. " event order")

      assert(victim_path, spec.label .. " missing replacement path")
      assert(original_stat, spec.label .. " missing original identity")
      eq(replacement_physical, victim_path, spec.label .. " replacement physical identity")
      assert_absent(victim_path, spec.label .. " replacement deleted")
      cycle6e.assert_saved_directory(
        fixture,
        original_stat,
        saved_original,
        saved_physical,
        spec.label
      )
      cycle6e.assert_no_residue(
        fixture,
        review_id,
        ".cleanup-",
        ".owned-cleanup-objects-",
        ".owned-cleanup-review-",
        spec.label
      )
      eq(fixture:status_bytes(), status_before, spec.label .. " Git status")
      eq(fixture:object_count(), objects_before, spec.label .. " Git object count")
    end

    exercise_cleanup_directory_characterization({
      fixture = "cycle-6e-cleanup-objects",
      kind = "objects",
      label = "out-of-scope same-credential cleanup objects owned-name substitution",
      owned_prefix = ".owned-cleanup-objects-",
    })
    exercise_cleanup_directory_characterization({
      fixture = "cycle-6e-cleanup-review",
      kind = "review",
      label = "out-of-scope same-credential cleanup review owned-name substitution",
      owned_prefix = ".owned-cleanup-review-",
    })
  end

  local corrupt = Fixture.new("corrupt")
  corrupt:write("dirty.txt", "one\n")
  corrupt:commit("one")
  corrupt:write("dirty.txt", "two\n")
  local corrupt_baseline = assert(baseline_module.create(corrupt:identity(), corrupt:store()))
  write_file(manifest_path(corrupt, corrupt_baseline), "{", 384)
  local corrupt_opened, corrupt_error =
    baseline_module.open(corrupt:identity(), corrupt:store(), corrupt_baseline:id())
  rejected(corrupt_opened, corrupt_error, "manifest", "corrupt manifest rejected")

  local missing_object = Fixture.new("missing-object")
  missing_object:write("dirty.txt", "one\n")
  missing_object:commit("one")
  missing_object:write("dirty.txt", "two\n")
  local missing_baseline =
    assert(baseline_module.create(missing_object:identity(), missing_object:store()))
  assert(vim.uv.fs_unlink(copied_object_path(missing_object, missing_baseline, "dirty.txt")))
  local missing_opened, missing_error =
    baseline_module.open(missing_object:identity(), missing_object:store(), missing_baseline:id())
  rejected(missing_opened, missing_error, "copied object", "missing copied object rejected")

  local wrong_mode = Fixture.new("wrong-mode")
  wrong_mode:write("dirty.txt", "one\n")
  wrong_mode:commit("one")
  wrong_mode:write("dirty.txt", "two\n")
  local mode_baseline = assert(baseline_module.create(wrong_mode:identity(), wrong_mode:store()))
  assert(vim.uv.fs_chmod(copied_object_path(wrong_mode, mode_baseline, "dirty.txt"), 420))
  local mode_opened, mode_error =
    baseline_module.open(wrong_mode:identity(), wrong_mode:store(), mode_baseline:id())
  rejected(mode_opened, mode_error, "mode 0600", "wrong copied-object mode rejected")

  local linked_storage = Fixture.new("linked-storage")
  linked_storage:write("dirty.txt", "one\n")
  linked_storage:commit("one")
  linked_storage:write("dirty.txt", "two\n")
  local linked_baseline =
    assert(baseline_module.create(linked_storage:identity(), linked_storage:store()))
  local storage_path = copied_object_path(linked_storage, linked_baseline, "dirty.txt")
  local outside = vim.fs.joinpath(linked_storage.base, "outside")
  write_file(outside, "two\n", 384)
  assert(vim.uv.fs_unlink(storage_path))
  assert(vim.uv.fs_symlink(outside, storage_path))
  local linked_opened, linked_error =
    baseline_module.open(linked_storage:identity(), linked_storage:store(), linked_baseline:id())
  rejected(linked_opened, linked_error, "nonsymlink", "symlinked storage rejected")

  local escaping = Fixture.new("escaping")
  escaping:write("parent/file.txt", "inside\n")
  escaping:commit("inside")
  assert(vim.fn.delete(escaping:path("parent"), "rf") == 0)
  local outside_parent = vim.fs.joinpath(escaping.base, "outside-parent")
  assert(vim.fn.mkdir(outside_parent, "p", 448) == 1)
  write_file(vim.fs.joinpath(outside_parent, "file.txt"), "outside\n", 384)
  assert(vim.uv.fs_symlink(outside_parent, escaping:path("parent")))
  local escaped, escape_error = baseline_module.create(escaping:identity(), escaping:store())
  rejected(escaped, escape_error, "escaped", "symlink-parent escape rejected")

  local fsync_failure = Fixture.new("fsync-failure")
  fsync_failure:write("dirty.txt", "one\n")
  fsync_failure:commit("one")
  fsync_failure:write("dirty.txt", "two\n")
  local fsync_state_identity =
    assert(vim.uv.fs_lstat(fsync_failure.state), "state directory lstat failed")
  local fsync_module = baseline_module._test.new({
    fsync = function(fd)
      local fd_identity = assert(vim.uv.fs_fstat(fd), "state directory fs_fstat failed")
      if
        fd_identity
        and fd_identity.dev == fsync_state_identity.dev
        and fd_identity.ino == fsync_state_identity.ino
        and fd_identity.type == fsync_state_identity.type
        and fd_identity.uid == fsync_state_identity.uid
        and fd_identity.mode == fsync_state_identity.mode
      then
        return vim.uv.fs_fsync(fd)
      end
      return nil, "injected fsync failure"
    end,
  })
  local fsync_baseline, fsync_error =
    fsync_module.create(fsync_failure:identity(), fsync_failure:store())
  rejected(fsync_baseline, fsync_error, "fsync", "object fsync failure rejected")
  eq(review_entries(fsync_failure), {}, "object fsync failure leaves no review")

  local manifest_failure = Fixture.new("manifest-failure")
  manifest_failure:write("dirty.txt", "one\n")
  manifest_failure:commit("one")
  manifest_failure:write("dirty.txt", "two\n")
  local creates = 0
  local manifest_failure_module = baseline_module._test.new({
    open = function(path, flags, mode)
      if flags == "wx" then
        creates = creates + 1
        if creates == 2 then
          return nil, "injected manifest open failure"
        end
      end
      return vim.uv.fs_open(path, flags, mode)
    end,
  })
  local unpublished, unpublished_error =
    manifest_failure_module.create(manifest_failure:identity(), manifest_failure:store())
  rejected(unpublished, unpublished_error, "manifest open failure", "manifest publication failure")
  eq(review_entries(manifest_failure), {}, "manifest publication failure leaves no review")

  local load_failure = Fixture.new("load-failure")
  load_failure:write("dirty.txt", "one\n")
  load_failure:commit("one")
  load_failure:write("dirty.txt", "two\n")
  local load_scan_failed = false
  local load_failure_module = baseline_module._test.new({
    scandir = function(path)
      if path == vim.fs.joinpath(load_failure.state, ".baseline-serialization") then
        return vim.uv.fs_scandir(path)
      end
      if not load_scan_failed then
        load_scan_failed = true
        return nil, "injected post-publication scan failure"
      end
      return vim.uv.fs_scandir(path)
    end,
  })
  local unloaded, unloaded_error =
    load_failure_module.create(load_failure:identity(), load_failure:store())
  rejected(unloaded, unloaded_error, "scan baseline storage", "post-publication load failure")
  eq(review_entries(load_failure), {}, "post-publication load failure leaves no review")

  do
    local fixture = Fixture.new("cycle-6a-cleanup-review-close")
    fixture:write("dirty.txt", "one\n")
    fixture:commit("one")
    fixture:write("dirty.txt", "two\n")

    local store = fixture:store()
    local create_review_dir = store.review_dir
    local review_id
    local review_path
    local reviews_path
    local reviews_identity
    function store:review_dir(candidate)
      local path, review_error = create_review_dir(self, candidate)
      if path then
        review_id = candidate
        review_path = path
        reviews_path = vim.fs.dirname(path)
        reviews_identity = vim.uv.fs_lstat(reviews_path)
      end
      return path, review_error
    end

    local dependencies
    local descriptors
    local lifetimes
    dependencies, descriptors, lifetimes = tracked_open_close_dependencies()
    local cleanup_lifetime_start
    local load_failures = 0
    local cleanup_rmdir_calls = 0
    local delegated_cleanup_rmdirs = 0
    local final_rmdir_failures = 0
    local final_rmdir_proof_failures = 0

    local function cleanup_reviews_lifetime()
      if not cleanup_lifetime_start or not reviews_path then
        return nil
      end
      local found
      for index = cleanup_lifetime_start + 1, #lifetimes do
        local lifetime = lifetimes[index]
        if lifetime.path == reviews_path and lifetime.active then
          if found then
            return nil
          end
          found = lifetime
        end
      end
      return found
    end

    local function same_directory_identity(left, right)
      if type(left) ~= "table" or type(right) ~= "table" then
        return false
      end
      for _, field in ipairs({ "dev", "ino", "type", "uid", "gid", "mode" }) do
        if
          left[field] == nil
          or right[field] == nil
          or not vim.deep_equal(left[field], right[field])
        then
          return false
        end
      end
      return left.type == "directory"
    end

    dependencies.scandir = function(path)
      if review_path and path == review_path and load_failures == 0 then
        cleanup_lifetime_start = #lifetimes
        load_failures = load_failures + 1
        return nil, "injected post-publication scan failure", "EIO"
      end
      return vim.uv.fs_scandir(path)
    end

    dependencies.rmdir = function(path)
      local name = path:match("([^/]+)$")
      local objects_name = review_id and ".owned-cleanup-objects-" .. review_id or nil
      local review_name = review_id and ".owned-cleanup-review-" .. review_id or nil
      if name == objects_name then
        cleanup_rmdir_calls = cleanup_rmdir_calls + 1
        delegated_cleanup_rmdirs = delegated_cleanup_rmdirs + 1
        return vim.uv.fs_rmdir(path)
      end
      if name == review_name then
        cleanup_rmdir_calls = cleanup_rmdir_calls + 1
        if final_rmdir_failures == 0 then
          local parent = cleanup_reviews_lifetime()
          local anchor_parent = vim.fs.dirname(path)
          local proc_parent = parent and "/proc/self/fd/" .. tostring(parent.fd) or nil
          local dev_parent = parent and "/dev/fd/" .. tostring(parent.fd) or nil
          local parent_stat = parent and vim.uv.fs_fstat(parent.fd) or nil
          local anchor_stat = vim.uv.fs_lstat(anchor_parent .. "/.")
          if
            parent
            and (anchor_parent == proc_parent or anchor_parent == dev_parent)
            and same_directory_identity(reviews_identity, parent_stat)
            and same_directory_identity(reviews_identity, anchor_stat)
          then
            final_rmdir_failures = final_rmdir_failures + 1
            return nil, "injected final cleanup review rmdir failure", "EIO"
          end
        end
        final_rmdir_proof_failures = final_rmdir_proof_failures + 1
        return nil, "injected final cleanup review rmdir proof mismatch", "EIO"
      end
      return vim.uv.fs_rmdir(path)
    end

    local identity = fixture:identity()
    local cycle6a_module = baseline_module._test.new(dependencies)
    local unpublished
    local unpublished_error
    local create_ok = xpcall(function()
      unpublished, unpublished_error = cycle6a_module.create(identity, store)
    end, debug.traceback)

    local findings = {}
    local finding_set = {}
    local function add_finding(label)
      if not finding_set[label] then
        finding_set[label] = true
        table.insert(findings, label)
      end
    end

    if not create_ok then
      add_finding("production call raised")
    end
    if unpublished ~= nil then
      add_finding("failed publication returned a value")
    end
    local expected_error = "could not scan baseline storage: injected post-publication scan failure"
      .. "; publication cleanup failed: could not clean failed review publication: "
      .. "injected final cleanup review rmdir failure"
    if unpublished_error ~= expected_error then
      add_finding("failed publication error mismatch")
    end
    if load_failures ~= 1 or not cleanup_lifetime_start then
      add_finding("load fault count mismatch")
    end
    if
      cleanup_rmdir_calls ~= 2
      or delegated_cleanup_rmdirs ~= 1
      or final_rmdir_failures ~= 1
      or final_rmdir_proof_failures ~= 0
    then
      add_finding("cleanup rmdir contract mismatch")
    end

    local failed_review_name = review_id and ".cleanup-" .. review_id or nil
    local failed_review_lifetime
    local failed_review_count = 0
    local reviews_lifetime
    local reviews_lifetime_count = 0
    if cleanup_lifetime_start then
      for index = cleanup_lifetime_start + 1, #lifetimes do
        local lifetime = lifetimes[index]
        if lifetime.path:match("([^/]+)$") == failed_review_name then
          failed_review_count = failed_review_count + 1
          failed_review_lifetime = lifetime
        elseif lifetime.path == reviews_path then
          reviews_lifetime_count = reviews_lifetime_count + 1
          reviews_lifetime = lifetime
        end
      end
    end

    if
      failed_review_count ~= 1
      or not failed_review_lifetime
      or failed_review_lifetime.close_attempts ~= 1
      or failed_review_lifetime.physical_close ~= true
      or failed_review_lifetime.active ~= false
    then
      add_finding("failed review close contract mismatch")
    end
    if
      reviews_lifetime_count ~= 1
      or not reviews_lifetime
      or reviews_lifetime.close_attempts ~= 1
      or reviews_lifetime.physical_close ~= true
      or reviews_lifetime.active ~= false
    then
      add_finding("reviews parent close contract mismatch")
    end

    for _, lifetime in ipairs(lifetimes) do
      if
        lifetime ~= failed_review_lifetime
        and lifetime ~= reviews_lifetime
        and (
          lifetime.close_attempts ~= 1
          or lifetime.physical_close ~= true
          or lifetime.active ~= false
        )
      then
        add_finding("other descriptor close contract mismatch")
      end
    end

    for fd, lifetime in pairs(descriptors) do
      local stat, _, code = vim.uv.fs_fstat(fd)
      if lifetime.active then
        if not stat then
          add_finding("latest descriptor live-state mismatch")
        end
      elseif stat or code ~= "EBADF" then
        add_finding("latest descriptor closed-state mismatch")
      end
    end

    local rescue_count = 0
    local rescued_fds = {}
    for _, lifetime in ipairs(lifetimes) do
      if lifetime.active then
        rescue_count = rescue_count + 1
        if rescued_fds[lifetime.fd] then
          add_finding("duplicate active descriptor generation")
        else
          rescued_fds[lifetime.fd] = true
          local rescued_ok, rescued = pcall(vim.uv.fs_close, lifetime.fd)
          if not rescued_ok or rescued ~= true then
            add_finding("descriptor rescue failed")
          end
        end
      end
    end
    if rescue_count ~= 0 then
      add_finding("failed review close contract mismatch")
    end

    for fd in pairs(descriptors) do
      local stat, _, code = vim.uv.fs_fstat(fd)
      if stat or code ~= "EBADF" then
        add_finding("descriptor remained live after rescue")
      end
    end

    local owned_review_name = review_id and ".owned-cleanup-review-" .. review_id
      or "missing-review-id"
    local owned_review_path = vim.fs.joinpath(reviews_path or fixture.state, owned_review_name)
    local reviews_read_ok, current_review_entries = pcall(review_entries, fixture)
    if
      not reviews_read_ok
      or type(current_review_entries) ~= "table"
      or not vim.deep_equal(current_review_entries, { owned_review_name })
    then
      add_finding("owned review residue mismatch")
    end
    local residue_stat_ok, residue_stat = pcall(vim.uv.fs_lstat, owned_review_path)
    local residue_read_ok = false
    local residue_entries
    if residue_stat_ok and type(residue_stat) == "table" and residue_stat.type == "directory" then
      residue_read_ok, residue_entries = pcall(vim.fn.readdir, owned_review_path)
    end
    if
      not residue_read_ok
      or type(residue_entries) ~= "table"
      or not vim.deep_equal(residue_entries, {})
    then
      add_finding("owned review residue was not empty")
    end

    table.sort(findings)
    local diagnostic = "Cycle 6A descriptor failures: " .. table.concat(findings, ", ")
    assert(#diagnostic <= 512, "Cycle 6A descriptor diagnostic overflow")
    if #findings > 0 then
      error(diagnostic, 0)
    end
  end

  do
    local fixture = Fixture.new("cycle-6b-removal-review-close")
    fixture:write("dirty.txt", "one\n")
    fixture:commit("one")
    fixture:write("dirty.txt", "two\n")

    local identity = fixture:identity()
    local store = fixture:store()
    local created = assert(baseline_module.create(identity, store))
    local review_id = created:id()
    local reviews_path = vim.fs.joinpath(fixture.state, "reviews")
    local reviews_identity = vim.uv.fs_lstat(reviews_path)

    local dependencies
    local descriptors
    local lifetimes
    dependencies, descriptors, lifetimes = tracked_open_close_dependencies()
    local removal_lifetime_start
    local removal_rmdir_calls = 0
    local delegated_removal_rmdirs = 0
    local final_rmdir_failures = 0
    local final_rmdir_proof_failures = 0

    local function removal_reviews_lifetime()
      if removal_lifetime_start == nil then
        return nil
      end
      local found
      for index = removal_lifetime_start + 1, #lifetimes do
        local lifetime = lifetimes[index]
        if lifetime.path == reviews_path and lifetime.active then
          if found then
            return nil
          end
          found = lifetime
        end
      end
      return found
    end

    local function same_directory_identity(left, right)
      if type(left) ~= "table" or type(right) ~= "table" then
        return false
      end
      for _, field in ipairs({ "dev", "ino", "type", "uid", "gid", "mode" }) do
        if
          left[field] == nil
          or right[field] == nil
          or not vim.deep_equal(left[field], right[field])
        then
          return false
        end
      end
      return left.type == "directory"
    end

    dependencies.rmdir = function(path)
      local name = path:match("([^/]+)$")
      local objects_name = ".owned-removing-objects-" .. review_id
      local review_name = ".owned-removing-review-" .. review_id
      if name == objects_name then
        removal_rmdir_calls = removal_rmdir_calls + 1
        delegated_removal_rmdirs = delegated_removal_rmdirs + 1
        return vim.uv.fs_rmdir(path)
      end
      if name == review_name then
        removal_rmdir_calls = removal_rmdir_calls + 1
        if final_rmdir_failures == 0 then
          local parent = removal_reviews_lifetime()
          local anchor_parent = vim.fs.dirname(path)
          local proc_parent = parent and "/proc/self/fd/" .. tostring(parent.fd) or nil
          local dev_parent = parent and "/dev/fd/" .. tostring(parent.fd) or nil
          local parent_stat = parent and vim.uv.fs_fstat(parent.fd) or nil
          local anchor_stat = vim.uv.fs_lstat(anchor_parent .. "/.")
          if
            parent
            and (anchor_parent == proc_parent or anchor_parent == dev_parent)
            and same_directory_identity(reviews_identity, parent_stat)
            and same_directory_identity(reviews_identity, anchor_stat)
          then
            final_rmdir_failures = final_rmdir_failures + 1
            return nil, "injected final removal review rmdir failure", "EIO"
          end
        end
        final_rmdir_proof_failures = final_rmdir_proof_failures + 1
        return nil, "injected final removal review rmdir proof mismatch", "EIO"
      end
      return vim.uv.fs_rmdir(path)
    end

    local cycle6b_module = baseline_module._test.new(dependencies)
    local baseline = assert(cycle6b_module.open(identity, store, review_id))
    removal_lifetime_start = #lifetimes

    local removed
    local remove_error
    local remove_ok = xpcall(function()
      removed, remove_error = baseline:remove()
    end, debug.traceback)

    local findings = {}
    local finding_set = {}
    local function add_finding(label)
      if not finding_set[label] then
        finding_set[label] = true
        table.insert(findings, label)
      end
    end

    if not remove_ok then
      add_finding("production call raised")
    end
    if removed ~= nil then
      add_finding("failed removal returned a value")
    end
    local expected_error =
      "could not remove baseline review directory: injected final removal review rmdir failure"
    if remove_error ~= expected_error then
      add_finding("removal error mismatch")
    end
    if
      removal_rmdir_calls ~= 2
      or delegated_removal_rmdirs ~= 1
      or final_rmdir_failures ~= 1
      or final_rmdir_proof_failures ~= 0
    then
      add_finding("removal rmdir contract mismatch")
    end

    local claimed_review_name = ".removing-" .. review_id
    local claimed_review_lifetime
    local claimed_review_count = 0
    local reviews_lifetime
    local reviews_lifetime_count = 0
    for index = removal_lifetime_start + 1, #lifetimes do
      local lifetime = lifetimes[index]
      if lifetime.path:match("([^/]+)$") == claimed_review_name then
        claimed_review_count = claimed_review_count + 1
        claimed_review_lifetime = lifetime
      elseif lifetime.path == reviews_path then
        reviews_lifetime_count = reviews_lifetime_count + 1
        reviews_lifetime = lifetime
      end
    end

    if
      claimed_review_count ~= 1
      or not claimed_review_lifetime
      or claimed_review_lifetime.close_attempts ~= 1
      or claimed_review_lifetime.physical_close ~= true
      or claimed_review_lifetime.active ~= false
    then
      add_finding("claimed review close contract mismatch")
    end
    if
      reviews_lifetime_count ~= 1
      or not reviews_lifetime
      or reviews_lifetime.close_attempts ~= 1
      or reviews_lifetime.physical_close ~= true
      or reviews_lifetime.active ~= false
    then
      add_finding("reviews parent close contract mismatch")
    end

    for _, lifetime in ipairs(lifetimes) do
      if
        lifetime ~= claimed_review_lifetime
        and lifetime ~= reviews_lifetime
        and (
          lifetime.close_attempts ~= 1
          or lifetime.physical_close ~= true
          or lifetime.active ~= false
        )
      then
        add_finding("other descriptor close contract mismatch")
      end
    end

    for fd, lifetime in pairs(descriptors) do
      local stat, _, code = vim.uv.fs_fstat(fd)
      if lifetime.active then
        if not stat then
          add_finding("latest descriptor live-state mismatch")
        end
      elseif stat or code ~= "EBADF" then
        add_finding("latest descriptor closed-state mismatch")
      end
    end

    local rescue_count = 0
    local rescued_fds = {}
    for _, lifetime in ipairs(lifetimes) do
      if lifetime.active then
        rescue_count = rescue_count + 1
        if rescued_fds[lifetime.fd] then
          add_finding("duplicate active descriptor generation")
        else
          rescued_fds[lifetime.fd] = true
          local rescued_ok, rescued = pcall(vim.uv.fs_close, lifetime.fd)
          if not rescued_ok or rescued ~= true then
            add_finding("descriptor rescue failed")
          end
        end
      end
    end
    if rescue_count ~= 0 then
      add_finding("claimed review close contract mismatch")
    end

    for fd in pairs(descriptors) do
      local stat, _, code = vim.uv.fs_fstat(fd)
      if stat or code ~= "EBADF" then
        add_finding("descriptor remained live after rescue")
      end
    end

    local owned_review_name = ".owned-removing-review-" .. review_id
    local owned_review_path = vim.fs.joinpath(reviews_path, owned_review_name)
    local reviews_read_ok, current_review_entries = pcall(review_entries, fixture)
    if
      not reviews_read_ok
      or type(current_review_entries) ~= "table"
      or not vim.deep_equal(current_review_entries, { owned_review_name })
    then
      add_finding("owned removal review residue mismatch")
    end
    local residue_stat_ok, residue_stat = pcall(vim.uv.fs_lstat, owned_review_path)
    local residue_read_ok = false
    local residue_entries
    if residue_stat_ok and type(residue_stat) == "table" and residue_stat.type == "directory" then
      residue_read_ok, residue_entries = pcall(vim.fn.readdir, owned_review_path)
    end
    if
      not residue_read_ok
      or type(residue_entries) ~= "table"
      or not vim.deep_equal(residue_entries, {})
    then
      add_finding("owned removal review residue was not empty")
    end

    table.sort(findings)
    local diagnostic = "Cycle 6B descriptor failures: " .. table.concat(findings, ", ")
    assert(#diagnostic <= 512, "Cycle 6B descriptor diagnostic overflow")
    if #findings > 0 then
      error(diagnostic, 0)
    end
  end

  do
    local fixture = Fixture.new("busy-removal")
    fixture:write("dirty.txt", "one\n")
    fixture:commit("one")
    fixture:write("dirty.txt", "two\n")

    local reviews_path = vim.fs.joinpath(fixture.state, "reviews")
    local lock_path = vim.fs.joinpath(fixture.state, ".baseline-serialization")
    local counts = { mkdir = 0, rename = 0, unlink = 0, rmdir = 0 }
    local review_reads = 0
    local function review_path(path)
      return type(path) == "string"
        and (path == reviews_path or path:sub(1, #reviews_path + 1) == reviews_path .. "/")
    end
    local function counted_read(operation)
      return function(path, ...)
        if review_path(path) then
          review_reads = review_reads + 1
        end
        return operation(path, ...)
      end
    end
    local function counted_mutation(name, operation)
      return function(path, ...)
        if name ~= "mkdir" or path ~= lock_path then
          counts[name] = counts[name] + 1
        end
        return operation(path, ...)
      end
    end

    local injected_dependencies = {
      lstat = counted_read(vim.uv.fs_lstat),
      open = counted_read(vim.uv.fs_open),
      scandir = counted_read(vim.uv.fs_scandir),
      mkdir = counted_mutation("mkdir", vim.uv.fs_mkdir),
      rename = counted_mutation("rename", vim.uv.fs_rename),
      unlink = counted_mutation("unlink", vim.uv.fs_unlink),
      rmdir = counted_mutation("rmdir", vim.uv.fs_rmdir),
    }
    local busy_module = baseline_module._test.new(injected_dependencies)
    local created = assert(busy_module.create(fixture:identity(), fixture:store()))
    local baseline = assert(busy_module.open(fixture:identity(), fixture:store(), created:id()))
    local holder_lease = assert(serialization.acquire(fixture.state, injected_dependencies))
    for name in pairs(counts) do
      counts[name] = 0
    end
    review_reads = 0

    local remove_value
    local remove_error
    local before
    local after
    local mutation_counts
    local review_read_count
    local zero_mutations = {
      mkdir = 0,
      rename = 0,
      unlink = 0,
      rmdir = 0,
    }
    local protected_ok, protected_error = xpcall(function()
      before = snapshot_tree(reviews_path)
      remove_value, remove_error = baseline:remove()
      mutation_counts = copy(counts)
      review_read_count = review_reads
      after = snapshot_tree(reviews_path)
    end, debug.traceback)

    local released, release_error = holder_lease:release()
    assert(released, tostring(release_error))
    assert(protected_ok, protected_error)
    eq(remove_value, nil, "busy removal value")
    eq(
      remove_error,
      "baseline serialization unavailable: lock exists (active or stale)",
      "busy removal error"
    )
    eq(after, before, "busy removal content-complete snapshot")
    eq(mutation_counts, zero_mutations, "busy removal mutation calls")
    eq(review_read_count, 0, "busy removal review-path reads")
  end

  do
    local fixture = Fixture.new("released-removal")
    fixture:write("dirty.txt", "one\n")
    fixture:commit("one")
    fixture:write("dirty.txt", "two\n")

    local identity = fixture:identity()
    local store = fixture:store()
    local created = assert(baseline_module.create(identity, store))
    local baseline = assert(baseline_module.open(identity, store, created:id()))
    local holder_lease = assert(serialization.acquire(fixture.state))
    local released, release_error = holder_lease:release()
    eq(released, true, "released removal holder value")
    eq(release_error, nil, "released removal holder error")

    local removed, remove_error = baseline:remove()
    eq(removed, true, "released removal value")
    eq(remove_error, nil, "released removal error")
    eq(review_entries(fixture), {}, "released removal review tree")
  end

  local collision = Fixture.new("collision")
  collision:write("dirty.txt", "one\n")
  collision:commit("one")
  collision:write("dirty.txt", "two\n")
  local collision_module = baseline_module._test.new({
    pid = function()
      return 17
    end,
    hrtime = function()
      return 23
    end,
  })
  local collision_baseline =
    assert(collision_module.create(collision:identity(), collision:store()))
  local duplicate, duplicate_error =
    collision_module.create(collision:identity(), collision:store())
  rejected(duplicate, duplicate_error, "collided", "review id collision rejected")
  eq(#review_entries(collision), 1, "collision preserves original review")
  assert(collision_baseline:remove())

  local hardlink = Fixture.new("hardlink")
  hardlink:write("dirty.txt", "one\n")
  hardlink:commit("one")
  hardlink:write("dirty.txt", "two\n")
  local hardlink_baseline = assert(baseline_module.create(hardlink:identity(), hardlink:store()))
  local hardlink_object = copied_object_path(hardlink, hardlink_baseline, "dirty.txt")
  local exposed_object = vim.fs.joinpath(hardlink.base, "exposed-object")
  assert(vim.uv.fs_link(hardlink_object, exposed_object))
  local hardlink_opened, hardlink_error =
    baseline_module.open(hardlink:identity(), hardlink:store(), hardlink_baseline:id())
  rejected(hardlink_opened, hardlink_error, "mode 0600", "hard-linked storage rejected")
  assert(vim.uv.fs_unlink(exposed_object))

  local substituted = Fixture.new("substituted-remove")
  substituted:write("dirty.txt", "one\n")
  substituted:commit("one")
  substituted:write("dirty.txt", "two\n")
  local substituted_baseline =
    assert(baseline_module.create(substituted:identity(), substituted:store()))
  local review_dir = vim.fs.joinpath(substituted.state, "reviews", substituted_baseline:id())
  local saved_review = review_dir .. "-saved"
  assert(vim.uv.fs_rename(review_dir, saved_review))
  local unrelated = vim.fs.joinpath(substituted.base, "unrelated")
  assert(vim.fn.mkdir(unrelated, "p", 448) == 1)
  write_file(vim.fs.joinpath(unrelated, "keep"), "keep\n", 384)
  assert(vim.uv.fs_symlink(unrelated, review_dir))
  local removed, remove_error = substituted_baseline:remove()
  rejected(removed, remove_error, "changed before removal", "substituted review removal rejected")
  eq(
    read_file(vim.fs.joinpath(unrelated, "keep")),
    "keep\n",
    "substituted removal preserves target"
  )

  do
    local removal_race = Fixture.new("removal-race")
    removal_race:write("dirty.txt", "one\n")
    removal_race:commit("one")
    removal_race:write("dirty.txt", "two\n")
    local removal_review
    local saved_removal_review
    local removal_outside = vim.fs.joinpath(removal_race.base, "removal-outside")
    assert(vim.fn.mkdir(vim.fs.joinpath(removal_outside, "objects"), "p", 448) == 1)
    write_file(vim.fs.joinpath(removal_outside, "objects", vim.fn.sha256("two\n")), "keep\n", 384)
    write_file(vim.fs.joinpath(removal_outside, "manifest.json"), "keep manifest\n", 384)
    local removal_swapped = false
    local function swap_removal_review()
      if removal_swapped then
        return
      end
      removal_swapped = true
      assert(vim.uv.fs_rename(removal_review, saved_removal_review))
      assert(vim.uv.fs_symlink(removal_outside, removal_review))
    end
    local removal_module = baseline_module._test.new({
      rename = function(source, destination)
        if
          not removal_swapped
          and (source == removal_review or destination:find("/.removing-", 1, true) ~= nil)
        then
          swap_removal_review()
        end
        return vim.uv.fs_rename(source, destination)
      end,
      unlink = function(path)
        if path:sub(1, #removal_review + 1) == removal_review .. "/" then
          swap_removal_review()
        end
        return vim.uv.fs_unlink(path)
      end,
    })
    local removal_baseline =
      assert(removal_module.create(removal_race:identity(), removal_race:store()))
    removal_review = vim.fs.joinpath(removal_race.state, "reviews", removal_baseline:id())
    saved_removal_review = removal_review .. "-saved"
    local raced_removal, raced_removal_error = removal_baseline:remove()
    rejected(
      raced_removal,
      raced_removal_error,
      "changed during removal",
      "removal-time substitution rejected"
    )
    eq(removal_swapped, true, "removal-time substitution was exercised")
    eq(
      read_file(vim.fs.joinpath(removal_outside, "objects", vim.fn.sha256("two\n"))),
      "keep\n",
      "removal race preserves unrelated object"
    )
    eq(
      read_file(vim.fs.joinpath(removal_outside, "manifest.json")),
      "keep manifest\n",
      "removal race preserves unrelated manifest"
    )
  end

  do
    local parent_race = Fixture.new("removal-parent-race")
    parent_race:write("dirty.txt", "one\n")
    parent_race:commit("one")
    parent_race:write("dirty.txt", "two\n")
    local parent_reviews = vim.fs.joinpath(parent_race.state, "reviews")
    local saved_parent_reviews = parent_reviews .. "-saved"
    local parent_outside = vim.fs.joinpath(parent_race.base, "parent-outside")
    assert(vim.fn.mkdir(parent_outside, "p", 448) == 1)
    write_file(vim.fs.joinpath(parent_outside, "keep"), "keep parent\n", 384)
    local parent_swapped = false
    local parent_race_module = baseline_module._test.new({
      rename = function(source, destination)
        if not parent_swapped and destination:find("/.removing-", 1, true) then
          parent_swapped = true
          assert(vim.uv.fs_rename(parent_reviews, saved_parent_reviews))
          assert(vim.uv.fs_symlink(parent_outside, parent_reviews))
        end
        return vim.uv.fs_rename(source, destination)
      end,
    })
    local parent_race_baseline =
      assert(parent_race_module.create(parent_race:identity(), parent_race:store()))
    local parent_removed, parent_remove_error = parent_race_baseline:remove()
    rejected(
      parent_removed,
      parent_remove_error,
      "changed during removal",
      "reviews-parent substitution rejected"
    )
    eq(parent_swapped, true, "reviews-parent substitution was exercised")
    eq(
      read_file(vim.fs.joinpath(parent_outside, "keep")),
      "keep parent\n",
      "reviews-parent race preserves unrelated data"
    )
  end

  do
    local function exercise_leaf_substitution(kind)
      local fixture = Fixture.new("removal-" .. kind .. "-leaf-race")
      fixture:write("dirty.txt", "one\n")
      fixture:commit("one")
      fixture:write("dirty.txt", "two\n")
      local armed = false
      local target_name
      local saved_original = vim.fs.joinpath(fixture.base, "saved-original-" .. kind)
      local victim_bytes = "unrelated " .. kind .. " victim\n"
      local swapped = false
      local function substitute(path)
        if swapped then
          return
        end
        assert(vim.uv.fs_rename(path, saved_original))
        write_file(path, victim_bytes, 384)
        swapped = true
      end
      local leaf_race_module = baseline_module._test.new({
        rename = function(source, destination)
          if armed and source:match("([^/]+)$") == target_name then
            substitute(source)
          end
          return vim.uv.fs_rename(source, destination)
        end,
        unlink = function(path)
          if armed and path:match("([^/]+)$") == target_name then
            substitute(path)
          end
          return vim.uv.fs_unlink(path)
        end,
      })
      local active = assert(leaf_race_module.create(fixture:identity(), fixture:store()))
      local logical_path
      if kind == "object" then
        logical_path = copied_object_path(fixture, active, "dirty.txt")
      else
        logical_path = manifest_path(fixture, active)
      end
      target_name = logical_path:match("([^/]+)$")
      armed = true
      local removed, remove_error = active:remove()
      rejected(removed, remove_error, "changed", kind .. " leaf substitution rejected")
      eq(swapped, true, kind .. " leaf substitution was exercised")
      eq(read_file(logical_path), victim_bytes, kind .. " victim leaf is preserved")
      assert(read_file(saved_original):len() > 0, kind .. " original was not preserved")
    end

    exercise_leaf_substitution("object")
    exercise_leaf_substitution("manifest")
  end

  do
    local function exercise_removal_directory_characterization(spec)
      local fixture = Fixture.new(spec.fixture)
      fixture:write("dirty.txt", "one\n")
      fixture:commit("one")
      fixture:write("dirty.txt", "two\n")

      local status_before = fixture:status_bytes()
      local objects_before = fixture:object_count()
      local identity = fixture:identity()
      local store = fixture:store()
      local created = assert(baseline_module.create(identity, store))
      local review_id = created:id()
      eq(type(review_id), "string", spec.label .. " review id type")
      eq(#review_id, 32, spec.label .. " review id length")
      assert(review_id:match("^[0-9a-f]+$"), spec.label .. " review id alphabet")

      local reviews_path = vim.fs.joinpath(fixture.state, "reviews")
      local review_path = vim.fs.joinpath(reviews_path, review_id)
      local expected_name = spec.owned_prefix .. review_id
      local review_stat =
        assert(vim.uv.fs_lstat(review_path), spec.label .. " expected review stat")
      local reviews_stat =
        assert(vim.uv.fs_lstat(reviews_path), spec.label .. " expected reviews stat")
      local expected_parent_identity = cycle6e.directory_identity(
        spec.kind == "objects" and review_stat or reviews_stat,
        spec.label .. " expected parent"
      )
      local reviews_physical =
        assert(vim.uv.fs_realpath(reviews_path), spec.label .. " reviews physical path")
      local expected_physical_path = spec.kind == "objects"
          and vim.fs.joinpath(reviews_physical, ".removing-" .. review_id, expected_name)
        or vim.fs.joinpath(reviews_physical, expected_name)

      local state = cycle6e.new_state(spec.label)
      local dependencies, lifetimes = cycle6e.new_dependencies(fixture, state)
      local armed = false
      local prearm_matches = 0
      local armed_matches = 0
      local unexpected_family_matches = 0
      local substitution_count = 0
      local native_rmdir_calls = 0
      local matching_native_rmdir_calls = 0
      local matching_native_exact = true
      local timing_exact = true
      local victim_path
      local original_stat
      local replacement_stat
      local replacement_physical
      local saved_physical
      local saved_original = vim.fs.joinpath(fixture.base, "saved-" .. spec.fixture)

      local function family_match(path)
        local name = type(path) == "string" and path:match("([^/]+)$") or nil
        if type(name) ~= "string" or name:sub(1, #spec.owned_prefix) ~= spec.owned_prefix then
          return false
        end
        local suffix = name:sub(#spec.owned_prefix + 1)
        return #suffix == 32 and suffix:match("^[0-9a-f]+$") ~= nil
      end

      local function exact_match(path)
        return type(path) == "string" and path:match("([^/]+)$") == expected_name
      end

      local function substitute(path)
        substitution_count = substitution_count + 1
        table.insert(state.events, "substitute")

        local parent_stat =
          assert(vim.uv.fs_lstat(vim.fs.dirname(path) .. "/."), spec.label .. " live parent stat")
        eq(
          cycle6e.directory_identity(parent_stat, spec.label .. " live parent"),
          expected_parent_identity,
          spec.label .. " parent identity"
        )

        victim_path = assert(vim.uv.fs_realpath(path), spec.label .. " target physical path")
        eq(victim_path, expected_physical_path, spec.label .. " exact physical target")
        original_stat = assert(vim.uv.fs_lstat(path), spec.label .. " original stat")
        assert(
          cycle6e.is_private_physical_directory(
            original_stat,
            victim_path,
            victim_path,
            vim.uv.getuid()
          ),
          spec.label .. " original directory mode"
        )
        assert(vim.uv.fs_rename(path, saved_original), spec.label .. " move original")
        saved_physical =
          assert(vim.uv.fs_realpath(saved_original), spec.label .. " saved physical path")

        assert(vim.uv.fs_mkdir(path, 448), spec.label .. " create replacement")
        replacement_stat = assert(vim.uv.fs_lstat(path), spec.label .. " replacement stat")
        replacement_physical =
          assert(vim.uv.fs_realpath(path), spec.label .. " replacement physical path")
        eq(replacement_physical, victim_path, spec.label .. " replacement path")
        eq(replacement_stat.type, "directory", spec.label .. " replacement type")
        eq(replacement_stat.uid, vim.uv.getuid(), spec.label .. " replacement owner")
        eq(mode_bits(replacement_stat), 448, spec.label .. " replacement mode")
      end

      dependencies.rmdir = function(path)
        state.note_dependency()
        local family = family_match(path)
        local matched = exact_match(path)
        if family then
          if not armed then
            prearm_matches = prearm_matches + 1
          elseif matched then
            armed_matches = armed_matches + 1
            timing_exact = timing_exact
              and state.held == true
              and state.acquire_count == 1
              and state.release_count == 0
              and rawequal(state.active_lease, state.transactions[1].lease)
            if substitution_count == 0 then
              substitute(path)
            end
          else
            unexpected_family_matches = unexpected_family_matches + 1
          end
        end

        native_rmdir_calls = native_rmdir_calls + 1
        local removed, remove_error, remove_code = vim.uv.fs_rmdir(path)
        if matched then
          matching_native_rmdir_calls = matching_native_rmdir_calls + 1
          matching_native_exact = matching_native_exact
            and removed == true
            and remove_error == nil
            and remove_code == nil
        end
        return removed, remove_error, remove_code
      end

      local module = baseline_module._test.new(dependencies)
      local open_ok, active, open_error = pcall(module.open, identity, store, review_id)
      eq(open_ok, true, spec.label .. " reopen call")
      assert(active, tostring(open_error))
      cycle6e.assert_lifetimes(state, lifetimes, 0, 2, { r = 2 }, spec.label .. " reopen")
      eq(state.acquire_count, 0, spec.label .. " reopen lock freedom")
      eq(active:id(), review_id, spec.label .. " reopened review id")

      local removal_start = #lifetimes
      armed = true
      cycle6e.begin_call(state, "remove")
      local call_ok, removed, remove_error = pcall(active.remove, active)
      cycle6e.end_call(state, "remove")

      cycle6e.assert_lifetimes(
        state,
        lifetimes,
        removal_start,
        5,
        { r = 5 },
        spec.label .. " removal"
      )
      cycle6e.assert_release(state, 1, { 4 }, { 7 }, spec.label)

      eq(call_ok, true, spec.label .. " call")
      eq(removed, true, spec.label .. " value")
      eq(remove_error, nil, spec.label .. " error")
      eq(expected_name, spec.owned_prefix .. review_id, spec.label .. " exact name")
      eq(prearm_matches, 0, spec.label .. " prearm matches")
      eq(armed_matches, 1, spec.label .. " armed matches")
      eq(unexpected_family_matches, 0, spec.label .. " unexpected family matches")
      eq(substitution_count, 1, spec.label .. " substitution count")
      eq(native_rmdir_calls, 3, spec.label .. " native rmdir count")
      eq(matching_native_rmdir_calls, 1, spec.label .. " target rmdir count")
      eq(matching_native_exact, true, spec.label .. " target native rmdir result")
      eq(timing_exact, true, spec.label .. " lease timing")
      eq(state.events, {
        "call-remove",
        "acquire-1",
        "substitute",
        "release-1",
        "return-remove",
      }, spec.label .. " event order")

      assert(victim_path, spec.label .. " missing replacement path")
      assert(original_stat, spec.label .. " missing original identity")
      eq(replacement_physical, victim_path, spec.label .. " replacement physical identity")
      assert_absent(victim_path, spec.label .. " replacement deleted")
      cycle6e.assert_saved_directory(
        fixture,
        original_stat,
        saved_original,
        saved_physical,
        spec.label
      )
      cycle6e.assert_no_residue(
        fixture,
        review_id,
        ".removing-",
        ".owned-removing-objects-",
        ".owned-removing-review-",
        spec.label
      )
      eq(fixture:status_bytes(), status_before, spec.label .. " Git status")
      eq(fixture:object_count(), objects_before, spec.label .. " Git object count")
    end

    exercise_removal_directory_characterization({
      fixture = "cycle-6e-removal-objects",
      kind = "objects",
      label = "out-of-scope same-credential removal objects owned-name substitution",
      owned_prefix = ".owned-removing-objects-",
    })
    exercise_removal_directory_characterization({
      fixture = "cycle-6e-removal-review",
      kind = "review",
      label = "out-of-scope same-credential removal review owned-name substitution",
      owned_prefix = ".owned-removing-review-",
    })
  end

  local cases = {
    {
      name = "unchanged",
      baseline = "A",
      current = "A",
      nvim = nil,
      external = false,
      state = "unchanged",
      writer = "none",
    },
    {
      name = "external",
      baseline = "A",
      current = "B",
      nvim = nil,
      external = true,
      state = "unresolved",
      writer = "external",
    },
    {
      name = "user only",
      baseline = "A",
      current = "B",
      nvim = "B",
      external = false,
      state = "unchanged",
      writer = "nvim",
    },
    {
      name = "external after user",
      baseline = "A",
      current = "C",
      nvim = "B",
      external = true,
      state = "conflicted",
      writer = "mixed",
    },
    {
      name = "user after external",
      baseline = "A",
      current = "C",
      nvim = "C",
      external = true,
      state = "conflicted",
      writer = "mixed",
    },
  }
  for _, case in ipairs(cases) do
    local result = tracker_module._test.classify_writer({
      baseline_hash = vim.fn.sha256(case.baseline),
      current_hash = vim.fn.sha256(case.current),
      last_nvim_hash = case.nvim and vim.fn.sha256(case.nvim) or nil,
      external_seen = case.external,
      nvim_seen = case.nvim ~= nil,
    })
    eq(
      { state = result.state, writer = result.writer },
      { state = case.state, writer = case.writer },
      case.name
    )
  end

  local function tracker_fixture(options)
    options = options or {}
    local baseline_paths = options.baseline_paths or { ["src/agent.lua"] = entry("A") }
    local ignored = options.ignored or {}
    local active_baseline = fake_baseline(baseline_paths, ignored, options.conflict_only)
    local snapshot = options.snapshot or { paths = copy(baseline_paths), ignored = copy(ignored) }
    local reloads = {}
    local buffer_states = options.buffer_states or {}
    local buffer_paths = options.buffer_paths or { [11] = "src/agent.lua" }
    local tracker = tracker_module._test.new({
      identity = {
        key = string.rep("a", 32),
        root = "/work/repo",
        inside_git = not options.conflict_only,
        namespace = "nvim:tracker-test",
      },
      store = {},
      baseline = active_baseline,
      scanner = function(identity, requested, reason)
        if options.scan_error then
          return nil, options.scan_error
        end
        if options.scanner then
          return options.scanner(identity, requested, reason)
        end
        return copy(snapshot)
      end,
      revalidate_baseline = options.revalidate_baseline or function()
        if options.baseline_error then
          return nil, options.baseline_error
        end
        return active_baseline
      end,
      buffer_state = options.buffer_state or function(path)
        return copy(buffer_states[path] or { loaded = false, modified = false })
      end,
      reload = function(bufnr, expected_hash)
        table.insert(reloads, { bufnr = bufnr, expected_hash = expected_hash })
        return true
      end,
      path_for_buffer = function(bufnr)
        return buffer_paths[bufnr]
      end,
      fingerprint_path = function(path)
        local item = snapshot.paths[path]
        if item then
          return copy(item)
        end
        item = snapshot.ignored[path]
        if item then
          local result = copy(item)
          result.ignored = true
          return result
        end
        return entry(nil, { kind = "absent" })
      end,
      start_watchers = false,
    })
    return {
      tracker = tracker,
      baseline = active_baseline,
      reloads = reloads,
      snapshot = snapshot,
      buffer_states = buffer_states,
    }
  end

  local external = tracker_fixture({
    buffer_states = { ["src/agent.lua"] = { loaded = true, modified = false, bufnr = 9 } },
  })
  assert(external.tracker:ensure_batch())
  external.snapshot.paths["src/agent.lua"] = entry("B")
  external.tracker:signal("src/agent.lua")
  assert(external.tracker:scan("filesystem"))
  eq(external.tracker:get("src/agent.lua").state, "unresolved", "external delta")
  eq(external.tracker:get("src/agent.lua").writer, "external", "external writer")
  eq(#external.reloads, 1, "unmodified buffer reload")

  local modified = tracker_fixture({
    buffer_states = { ["src/agent.lua"] = { loaded = true, modified = true, bufnr = 10 } },
  })
  assert(modified.tracker:ensure_batch())
  modified.snapshot.paths["src/agent.lua"] = entry("B")
  modified.tracker:signal("src/agent.lua")
  assert(modified.tracker:scan("filesystem"))
  eq(modified.tracker:get("src/agent.lua").state, "conflicted", "modified buffer conflict")
  eq(#modified.reloads, 0, "modified buffer never reloaded")

  do
    local buffer_checks = 0
    local modified_during_check = tracker_fixture({
      buffer_state = function()
        buffer_checks = buffer_checks + 1
        return {
          loaded = true,
          modified = buffer_checks > 1,
          bufnr = 13,
        }
      end,
    })
    assert(modified_during_check.tracker:ensure_batch())
    modified_during_check.snapshot.paths["src/agent.lua"] = entry("B")
    assert(modified_during_check.tracker:scan("filesystem"))
    eq(
      modified_during_check.tracker:get("src/agent.lua").state,
      "conflicted",
      "buffer modified during fingerprint conflicts"
    )
    assert(buffer_checks > 1, "modified-buffer state was not rechecked")
    eq(#modified_during_check.reloads, 0, "buffer modified during fingerprint is not reloaded")
  end

  local missed = tracker_fixture()
  assert(missed.tracker:ensure_batch())
  missed.snapshot.paths["new/agent.lua"] = entry("new\n")
  assert(missed.tracker:scan("periodic"))
  eq(missed.tracker:get("new/agent.lua").state, "unresolved", "full scan finds missed new path")

  local user_only = tracker_fixture()
  assert(user_only.tracker:ensure_batch())
  user_only.snapshot.paths["src/agent.lua"] = entry("B")
  assert(user_only.tracker:record_nvim_write(11))
  eq(user_only.tracker:get("src/agent.lua").state, "unchanged", "user-only write excluded")
  eq(user_only.tracker:get("src/agent.lua").writer, "nvim", "user-only writer")

  local external_then_user = tracker_fixture()
  assert(external_then_user.tracker:ensure_batch())
  external_then_user.snapshot.paths["src/agent.lua"] = entry("B")
  assert(external_then_user.tracker:scan("filesystem"))
  external_then_user.snapshot.paths["src/agent.lua"] = entry("C")
  assert(external_then_user.tracker:record_nvim_write(11))
  eq(external_then_user.tracker:get("src/agent.lua").state, "conflicted", "external then user")
  eq(external_then_user.tracker:get("src/agent.lua").writer, "mixed", "external then user writer")
  local unsafe_reject, unsafe_reject_error =
    external_then_user.tracker:resolve("src/agent.lua", "rejected")
  rejected(unsafe_reject, unsafe_reject_error, "safely resolvable", "mixed path reject refused")
  eq(
    external_then_user.tracker:resolve("src/agent.lua", "accepted"),
    nil,
    "legacy cached manual conflict acceptance is refused"
  )
  external_then_user.snapshot.paths["src/agent.lua"] = entry("D")
  assert(external_then_user.tracker:scan("filesystem"))
  eq(
    external_then_user.tracker:get("src/agent.lua").state,
    "conflicted",
    "mixed conflict remains latched"
  )

  local user_then_external = tracker_fixture()
  assert(user_then_external.tracker:ensure_batch())
  user_then_external.snapshot.paths["src/agent.lua"] = entry("B")
  assert(user_then_external.tracker:record_nvim_write(11))
  user_then_external.snapshot.paths["src/agent.lua"] = entry("C")
  assert(user_then_external.tracker:scan("filesystem"))
  eq(user_then_external.tracker:get("src/agent.lua").state, "conflicted", "user then external")
  user_then_external.snapshot.paths["src/agent.lua"] = entry("A")
  assert(user_then_external.tracker:scan("periodic"))
  eq(
    user_then_external.tracker:get("src/agent.lua").state,
    "conflicted",
    "mixed-writer conflict remains latched after baseline return"
  )

  local reverted = tracker_fixture()
  assert(reverted.tracker:ensure_batch())
  reverted.snapshot.paths["src/agent.lua"] = entry("B")
  assert(reverted.tracker:scan("filesystem"))
  reverted.snapshot.paths["src/agent.lua"] = entry("A")
  assert(reverted.tracker:scan("periodic"))
  eq(reverted.tracker:get("src/agent.lua").state, "unchanged", "external return to baseline")

  local reverted_modified = tracker_fixture()
  assert(reverted_modified.tracker:ensure_batch())
  reverted_modified.snapshot.paths["src/agent.lua"] = entry("B")
  assert(reverted_modified.tracker:scan("filesystem"))
  reverted_modified.buffer_states["src/agent.lua"] = { loaded = true, modified = true, bufnr = 12 }
  reverted_modified.snapshot.paths["src/agent.lua"] = entry("A")
  assert(reverted_modified.tracker:scan("periodic"))
  eq(
    reverted_modified.tracker:get("src/agent.lua").state,
    "conflicted",
    "modified buffer conflicts when external bytes return to baseline"
  )

  local ignored_baseline = { ["ignored.log"] = entry("old\n") }
  local ignored = tracker_fixture({ baseline_paths = {}, ignored = ignored_baseline })
  assert(ignored.tracker:ensure_batch())
  ignored.snapshot.ignored["ignored.log"] = entry("new\n")
  assert(ignored.tracker:scan("filesystem"))
  eq(ignored.tracker:get("ignored.log").state, "ignored", "ignored change remains ignored")
  eq(ignored.tracker:get("ignored.log").action, "none", "ignored action")
  local ignored_write = tracker_fixture({
    baseline_paths = {},
    ignored = ignored_baseline,
    buffer_paths = { [14] = "ignored.log" },
  })
  assert(ignored_write.tracker:ensure_batch())
  ignored_write.snapshot.ignored["ignored.log"] = entry("written\n")
  assert(ignored_write.tracker:record_nvim_write(14))
  eq(
    ignored_write.tracker:get("ignored.log").state,
    "ignored",
    "ignored Neovim write remains ignored"
  )
  local ignored_deleted = tracker_fixture({ baseline_paths = {}, ignored = ignored_baseline })
  assert(ignored_deleted.tracker:ensure_batch())
  ignored_deleted.snapshot.ignored["ignored.log"] = nil
  assert(ignored_deleted.tracker:scan("filesystem"))
  eq(
    ignored_deleted.tracker:get("ignored.log").state,
    "ignored",
    "deleted ignored path remains ignored"
  )
  local ignored_new = tracker_fixture({ baseline_paths = {}, ignored = {} })
  assert(ignored_new.tracker:ensure_batch())
  ignored_new.snapshot.ignored["new.log"] = entry("new ignored\n")
  assert(ignored_new.tracker:scan("filesystem"))
  eq(ignored_new.tracker:get("new.log").state, "ignored", "new ignored path is reported")
  ignored.snapshot.ignored["ignored.log"] = nil
  ignored.snapshot.paths["ignored.log"] = entry("now visible\n")
  assert(ignored.tracker:scan("filesystem"))
  eq(ignored.tracker:get("ignored.log").state, "conflicted", "exposed ignored path conflicts")

  local baseline_binary = entry("\0old")
  baseline_binary.bytes = "\0old"
  local shapes = tracker_fixture({
    baseline_paths = {
      ["text.txt"] = entry("A", { storage = "copy:a" }),
      ["binary.bin"] = entry(nil, { kind = "absent" }),
      ["binary-to-text.bin"] = baseline_binary,
      ["mode.sh"] = entry("same\n", { mode = "100644" }),
      ["linked"] = entry("old", { kind = "symlink" }),
      ["deleted.txt"] = entry("present\n"),
      ["new.txt"] = entry(nil, { kind = "absent" }),
      ["unsupported"] = entry(nil, { kind = "absent" }),
    },
  })
  assert(shapes.tracker:ensure_batch())
  shapes.snapshot.paths = {
    ["text.txt"] = entry("B"),
    ["binary.bin"] = entry("\0binary"),
    ["binary-to-text.bin"] = entry("now text\n"),
    ["mode.sh"] = entry("same\n", { mode = "100755" }),
    ["linked"] = entry("new", { kind = "symlink" }),
    ["deleted.txt"] = entry(nil, { kind = "absent" }),
    ["new.txt"] = entry("created\n"),
    ["unsupported"] = entry("", { kind = "unsupported", mode = nil }),
  }
  assert(shapes.tracker:scan("filesystem"))
  eq(shapes.tracker:get("text.txt").action, "hunks", "text action")
  eq(shapes.tracker:get("binary.bin").action, "whole", "binary action")
  eq(shapes.tracker:get("binary-to-text.bin").action, "whole", "baseline binary action")
  eq(shapes.tracker:get("mode.sh").action, "whole", "mode-only action")
  eq(shapes.tracker:get("linked").action, "whole", "symlink action")
  eq(shapes.tracker:get("deleted.txt").action, "whole", "deletion action")
  eq(shapes.tracker:get("new.txt").action, "whole", "addition action")
  eq(shapes.tracker:get("unsupported").action, "none", "unsupported action")
  eq(shapes.tracker:get("unsupported").state, "conflicted", "unsupported conflict")

  local nongit = tracker_fixture({ baseline_paths = {}, conflict_only = true })
  assert(nongit.tracker:ensure_batch())
  nongit.snapshot.paths["plain.txt"] = entry("changed\n")
  nongit.tracker:signal("plain.txt")
  assert(nongit.tracker:scan("filesystem"))
  eq(nongit.tracker:get("plain.txt").state, "conflicted", "non-Git path conflicts")
  eq(nongit.tracker:get("plain.txt").action, "none", "non-Git path has no action")

  local failed = tracker_fixture({ scan_error = "scan exploded" })
  assert(failed.tracker:ensure_batch())
  local scanned, scan_error = failed.tracker:scan("periodic")
  rejected(scanned, scan_error, "scan exploded", "scan failure returned")
  eq(failed.tracker:get("src/agent.lua").state, "conflicted", "scan failure latches conflict")

  do
    local lost_baseline = tracker_fixture({ baseline_error = "baseline storage disappeared" })
    assert(lost_baseline.tracker:ensure_batch())
    local lost_scan, lost_error = lost_baseline.tracker:scan("periodic")
    rejected(lost_scan, lost_error, "baseline storage disappeared", "baseline loss returned")
    eq(
      lost_baseline.tracker:get("src/agent.lua").state,
      "conflicted",
      "baseline loss latches conflict"
    )
  end

  do
    local malformed = tracker_fixture({
      scanner = function()
        return {
          paths = {
            [7] = entry("bad"),
            ["src/agent.lua"] = entry("B"),
          },
          ignored = {},
        }
      end,
    })
    assert(malformed.tracker:ensure_batch())
    local scan_invoked, malformed_result, malformed_error =
      pcall(malformed.tracker.scan, malformed.tracker, "periodic")
    eq(scan_invoked, true, "malformed scanner data does not throw")
    rejected(malformed_result, malformed_error, "invalid path", "malformed scanner data returned")
    eq(
      malformed.tracker:get("src/agent.lua").state,
      "conflicted",
      "malformed scanner data latches conflict"
    )
  end

  local empty_failure_baseline = fake_baseline({}, {}, false)
  local empty_failure_active = true
  local empty_failure_snapshot = { paths = {}, ignored = {} }
  local empty_failure = tracker_module._test.new({
    identity = {
      key = string.rep("b", 32),
      root = "/work/repo",
      inside_git = true,
      namespace = "nvim:empty-failure",
    },
    store = {},
    baseline = empty_failure_baseline,
    revalidate_baseline = function()
      return empty_failure_baseline
    end,
    scanner = function()
      if empty_failure_active then
        return nil, "empty batch scan failed"
      end
      return copy(empty_failure_snapshot)
    end,
    buffer_state = function()
      return { loaded = false, modified = false }
    end,
    start_watchers = false,
  })
  assert(empty_failure:ensure_batch())
  local empty_scanned, empty_scan_error = empty_failure:scan("periodic")
  rejected(empty_scanned, empty_scan_error, "empty batch scan failed", "empty scan failure")
  empty_failure_active = false
  empty_failure_snapshot.paths["later.txt"] = entry("later\n")
  assert(empty_failure:scan("periodic"))
  eq(empty_failure:get("later.txt").state, "conflicted", "empty scan failure latches batch")
  local batch_accept, batch_accept_error = empty_failure:resolve("later.txt", "accepted")
  rejected(
    batch_accept,
    batch_accept_error,
    "latched conflicted",
    "latched batch cannot be accepted"
  )

  local decisions = tracker_fixture()
  assert(decisions.tracker:ensure_batch())
  decisions.snapshot.paths["src/agent.lua"] = entry("B")
  assert(decisions.tracker:scan("filesystem"))
  eq(
    decisions.tracker:resolve("src/agent.lua", "accepted"),
    nil,
    "legacy acceptance requires an exact reviewed hash"
  )
  decisions.snapshot.paths["src/agent.lua"] = entry("C")
  assert(decisions.tracker:scan("filesystem"))
  eq(decisions.tracker:get("src/agent.lua").state, "unresolved", "changed decision invalidated")

  local notifications = {}
  local subscribed = tracker_fixture()
  subscribed.tracker:subscribe(function(records, reason)
    table.insert(notifications, { records = records, reason = reason })
  end)
  assert(subscribed.tracker:ensure_batch())
  subscribed.snapshot.paths["src/agent.lua"] = entry("B")
  assert(subscribed.tracker:scan("completion"))
  eq(#notifications, 1, "tracker subscriber notified")
  eq(notifications[1].reason, "completion", "tracker notification reason")
  assert(subscribed.tracker:abandon())
  eq(subscribed.baseline:remove_count(), 1, "abandon removes baseline")
  eq(subscribed.tracker:paths(), {}, "abandon clears records")
  eq(subscribed.tracker:shutdown(), true, "tracker shutdown")
  eq(subscribed.tracker:shutdown(), true, "tracker repeated shutdown")

  do
    local watcher_baseline = fake_baseline({ ["src/agent.lua"] = entry("A") }, {}, false)
    local watcher_snapshot = { paths = { ["src/agent.lua"] = entry("A") }, ignored = {} }
    local watcher_handle = { closing = false }
    function watcher_handle:start(root, options, callback)
      self.root = root
      self.options = options
      self.callback = callback
      return true
    end
    function watcher_handle:stop()
      self.stopped = true
      return true
    end
    function watcher_handle:close()
      self.closing = true
    end
    function watcher_handle:is_closing()
      return self.closing
    end
    function watcher_handle:unref()
      self.unreferenced = true
    end
    local timers = {}
    local autocmds = {}
    local deleted_augroups = {}
    local function new_timer()
      local timer = { closing = false }
      function timer:start(timeout, repeat_interval, callback)
        self.timeout = timeout
        self.repeat_interval = repeat_interval
        self.callback = callback
        return true
      end
      function timer:stop()
        self.stopped = true
        return true
      end
      function timer:close()
        self.closing = true
      end
      function timer:is_closing()
        return self.closing
      end
      function timer:unref()
        self.unreferenced = true
      end
      table.insert(timers, timer)
      return timer
    end
    local watched = tracker_module._test.new({
      identity = {
        key = string.rep("c", 32),
        root = "/work/repo",
        inside_git = true,
        namespace = "nvim:watcher",
      },
      store = {},
      baseline = watcher_baseline,
      revalidate_baseline = function()
        return watcher_baseline
      end,
      scanner = function()
        return copy(watcher_snapshot)
      end,
      buffer_state = function()
        return { loaded = false, modified = false }
      end,
      new_fs_event = function()
        return watcher_handle
      end,
      new_timer = new_timer,
      create_augroup = function(name, options)
        eq(options, { clear = true }, "review augroup options")
        assert(name:find("NvimAIReview", 1, true), "review augroup name")
        return 71
      end,
      create_autocmd = function(events, options)
        table.insert(autocmds, { events = copy(events), options = options })
        return #autocmds
      end,
      del_augroup = function(group)
        table.insert(deleted_augroups, group)
        return true
      end,
      path_for_buffer = function()
        return "src/user.lua"
      end,
      fingerprint_path = function(path)
        return copy(watcher_snapshot.paths[path] or entry(nil, { kind = "absent" }))
      end,
      schedule = function(callback)
        callback()
      end,
    })
    assert(watched:ensure_batch())
    eq(watcher_handle.root, "/work/repo", "root watcher path")
    eq(#timers, 2, "debounce and periodic timers")
    eq(timers[2].timeout, 2000, "periodic scan delay")
    eq(timers[2].repeat_interval, 2000, "periodic scan interval")
    eq(#autocmds, 2, "review event autocmds")
    local event_callbacks = {}
    for _, autocmd in ipairs(autocmds) do
      local events = type(autocmd.events) == "table" and autocmd.events or { autocmd.events }
      for _, event_name in ipairs(events) do
        event_callbacks[event_name] = autocmd.options.callback
      end
    end
    assert(event_callbacks.FocusGained, "FocusGained review scan missing")
    assert(event_callbacks.BufEnter, "BufEnter review scan missing")
    assert(event_callbacks.BufWritePost, "BufWritePost review record missing")
    watcher_snapshot.paths["src/user.lua"] = entry("user write\n")
    event_callbacks.BufWritePost({ buf = 11 })
    eq(watched:get("src/user.lua").state, "unchanged", "BufWritePost is synchronous")
    eq(watched:get("src/user.lua").writer, "nvim", "BufWritePost records Neovim writer")
    watcher_snapshot.paths["src/agent.lua"] = entry("B")
    event_callbacks.FocusGained({ event = "FocusGained" })
    eq(watched:get("src/agent.lua").state, "unresolved", "FocusGained scans immediately")
    watcher_snapshot.paths["src/agent.lua"] = entry("C")
    watcher_handle.callback(nil, "src/agent.lua")
    eq(timers[1].timeout, 120, "filesystem debounce delay")
    timers[1].callback()
    eq(watched:get("src/agent.lua").state, "unresolved", "debounced watcher scan")
    eq(watched:shutdown(), true, "watched tracker shutdown")
    eq(watcher_handle.closing, true, "watcher closed")
    eq(timers[1].closing, true, "debounce timer closed")
    eq(timers[2].closing, true, "periodic timer closed")
    eq(deleted_augroups, { 71 }, "review augroup deleted")
  end

  do
    local orphaned_baseline = fake_baseline({ ["src/agent.lua"] = entry("A") }, {}, false)
    local orphaned_tracker = tracker_module._test.new({
      identity = {
        key = string.rep("1", 32),
        root = "/work/repo",
        inside_git = true,
        namespace = "nvim:orphaned",
      },
      store = {},
      baseline_module = created_baseline_module(
        orphaned_baseline,
        baseline_module._internal.decode_hex
      ),
      new_fs_event = function()
        return nil
      end,
      new_timer = function()
        return inert_handle(true)
      end,
    })
    local orphaned, orphaned_error = orphaned_tracker:ensure_batch()
    rejected(orphaned, orphaned_error, "allocation", "watcher allocation failure returned")
    eq(orphaned_baseline:remove_count(), 1, "watcher failure removes newly created baseline")
  end

  do
    local watcher_start_baseline = fake_baseline({ ["src/agent.lua"] = entry("A") }, {}, false)
    local watcher_start_handle = inert_handle(false)
    local watcher_start_tracker = tracker_module._test.new({
      identity = {
        key = string.rep("5", 32),
        root = "/work/repo",
        inside_git = true,
        namespace = "nvim:watcher-start-failure",
      },
      store = {},
      baseline_module = created_baseline_module(
        watcher_start_baseline,
        baseline_module._internal.decode_hex
      ),
      new_fs_event = function()
        return watcher_start_handle
      end,
      new_timer = function()
        return inert_handle(true)
      end,
    })
    local watcher_started, watcher_start_error = watcher_start_tracker:ensure_batch()
    rejected(
      watcher_started,
      watcher_start_error,
      "watcher start",
      "watcher startup failure returned"
    )
    eq(
      watcher_start_baseline:remove_count(),
      1,
      "watcher startup failure removes newly created baseline"
    )
    eq(watcher_start_handle.close_attempted, true, "failed watcher start closes handle")
  end

  do
    local periodic_baseline = fake_baseline({ ["src/agent.lua"] = entry("A") }, {}, false)
    local periodic_watcher = inert_handle(true)
    local periodic_timers = { inert_handle(true), inert_handle(false) }
    local periodic_index = 0
    local periodic_failure = tracker_module._test.new({
      identity = {
        key = string.rep("2", 32),
        root = "/work/repo",
        inside_git = true,
        namespace = "nvim:periodic-failure",
      },
      store = {},
      baseline_module = created_baseline_module(
        periodic_baseline,
        baseline_module._internal.decode_hex
      ),
      new_fs_event = function()
        return periodic_watcher
      end,
      new_timer = function()
        periodic_index = periodic_index + 1
        return periodic_timers[periodic_index]
      end,
      create_augroup = function()
        return 72
      end,
      create_autocmd = function()
        return 1
      end,
      del_augroup = function()
        return true
      end,
    })
    local periodic_started, periodic_error = periodic_failure:ensure_batch()
    rejected(
      periodic_started,
      periodic_error,
      "periodic timer",
      "periodic timer startup failure returned"
    )
    eq(periodic_baseline:remove_count(), 1, "periodic failure removes newly created baseline")
  end

  do
    local failing_watcher = inert_handle(true, "watcher stop exploded")
    local failing_timers = {
      inert_handle(true, "debounce stop exploded"),
      inert_handle(true, "periodic stop exploded"),
    }
    local failing_timer_index = 0
    local removed_groups = {}
    local closing_tracker = tracker_module._test.new({
      identity = {
        key = string.rep("3", 32),
        root = "/work/repo",
        inside_git = true,
        namespace = "nvim:closing",
      },
      store = {},
      baseline = fake_baseline({ ["src/agent.lua"] = entry("A") }, {}, false),
      new_fs_event = function()
        return failing_watcher
      end,
      new_timer = function()
        failing_timer_index = failing_timer_index + 1
        return failing_timers[failing_timer_index]
      end,
      create_augroup = function()
        return 73
      end,
      create_autocmd = function()
        return 1
      end,
      del_augroup = function(group)
        table.insert(removed_groups, group)
        return true
      end,
    })
    assert(closing_tracker:ensure_batch())
    eq(closing_tracker:shutdown(), false, "shutdown reports handle failures")
    eq(failing_watcher.close_attempted, true, "watcher close attempted after stop failure")
    eq(failing_timers[1].close_attempted, true, "debounce close attempted after stop failure")
    eq(failing_timers[2].close_attempted, true, "periodic close attempted after stop failure")
    eq(removed_groups, { 73 }, "augroup removal attempted after handle failures")
  end

  do
    local debounce_baseline = fake_baseline({ ["src/agent.lua"] = entry("A") }, {}, false)
    local debounce_watcher = inert_handle(true)
    local debounce_timers = { inert_handle(false), inert_handle(true) }
    local debounce_index = 0
    local debounce_failure = tracker_module._test.new({
      identity = {
        key = string.rep("4", 32),
        root = "/work/repo",
        inside_git = true,
        namespace = "nvim:debounce-failure",
      },
      store = {},
      baseline = debounce_baseline,
      scanner = function()
        return { paths = { ["src/agent.lua"] = entry("A") }, ignored = {} }
      end,
      revalidate_baseline = function()
        return debounce_baseline
      end,
      new_fs_event = function()
        return debounce_watcher
      end,
      new_timer = function()
        debounce_index = debounce_index + 1
        return debounce_timers[debounce_index]
      end,
      create_augroup = function()
        return 74
      end,
      create_autocmd = function()
        return 1
      end,
      del_augroup = function()
        return true
      end,
    })
    assert(debounce_failure:ensure_batch())
    local signaled, signal_error = debounce_failure:signal("src/agent.lua")
    rejected(signaled, signal_error, "debounce timer", "debounce restart failure returned")
    eq(
      debounce_failure:get("src/agent.lua").state,
      "conflicted",
      "debounce restart failure latches conflict"
    )
    debounce_failure:shutdown()
  end

  do
    local real_tracker_fixture = Fixture.new("real-tracker")
    real_tracker_fixture:write("agent.txt", "before\n")
    real_tracker_fixture:commit("before")
    local real_identity = real_tracker_fixture:identity()
    local real_store = real_tracker_fixture:store()
    local real_baseline = assert(baseline_module.create(real_identity, real_store))
    local real_objects_before = real_tracker_fixture:object_count()
    local real_tracker = tracker_module.new({
      identity = real_identity,
      store = real_store,
      baseline = real_baseline,
      buffer_state = function()
        return { loaded = false, modified = false }
      end,
      start_watchers = false,
    })
    assert(real_tracker:ensure_batch())
    real_tracker_fixture:write("agent.txt", "after\n")
    assert(real_tracker:scan("completion"))
    eq(real_tracker:get("agent.txt").state, "unresolved", "real Git tracker delta")
    eq(real_tracker:get("agent.txt").writer, "external", "real Git tracker writer")
    eq(real_tracker:get("agent.txt").action, "hunks", "real Git tracker text action")
    eq(real_tracker_fixture:object_count(), real_objects_before, "tracker writes no Git object")
    assert(real_tracker:abandon())
  end

  do
    local real_loss_fixture = Fixture.new("real-baseline-loss")
    real_loss_fixture:write("agent.txt", "before\n")
    real_loss_fixture:commit("before")
    local real_loss_identity = real_loss_fixture:identity()
    local real_loss_store = real_loss_fixture:store()
    local real_loss_baseline = assert(baseline_module.create(real_loss_identity, real_loss_store))
    local real_loss_tracker = tracker_module.new({
      identity = real_loss_identity,
      store = real_loss_store,
      baseline = real_loss_baseline,
      buffer_state = function()
        return { loaded = false, modified = false }
      end,
      start_watchers = false,
    })
    assert(real_loss_tracker:ensure_batch())
    assert(vim.uv.fs_unlink(manifest_path(real_loss_fixture, real_loss_baseline)))
    local real_loss_scan, real_loss_error = real_loss_tracker:scan("periodic")
    rejected(real_loss_scan, real_loss_error, "baseline storage", "real baseline loss returned")
    eq(
      real_loss_tracker:get("agent.txt").state,
      "conflicted",
      "real baseline loss latches conflict"
    )
    real_loss_tracker:shutdown()
  end

  do
    local action_fixture = Fixture.new("review-actions")
    action_fixture:write("src/two-hunks.txt", "committed\n")
    action_fixture:commit("review action fixture")
    local base_bytes = "one\ntwo\nthree\nfour\n"
    local agent_bytes = "one\nTWO\nthree\nFOUR\n"
    action_fixture:write("src/two-hunks.txt", base_bytes)
    action_fixture:write("src/reject.txt", base_bytes)
    local action_identity = action_fixture:identity()
    local action_store = assert(require("ai.state")._test.open({
      identity = action_identity,
      uid = vim.uv.getuid(),
      runtime_base = action_fixture.base .. "/run",
      state_base = action_fixture.base .. "/durable",
    }))
    local action_baseline = assert(baseline_module.create(action_identity, action_store))
    local action_tools = {
      python = assert(require("ai.tools").resolve("/usr/bin/python3")),
      bwrap = assert(require("ai.tools").resolve("/usr/bin/bwrap")),
    }
    local action_helpers = { review_helper = worktree .. "/scripts/nvim-ai-review.py" }
    local mutation_calls, temporary_actions = {}, {}
    local function mutation_runner(argv, run_options)
      eq(
        argv[1],
        action_tools.bwrap,
        "review mutation uses the pinned canonical Bubblewrap executable"
      )
      eq(
        vim.list_slice(argv, #argv - 5),
        { action_tools.python, "-I", "-B", action_helpers.review_helper, "--manifest", argv[#argv] },
        "isolated Python executes only the fixed review helper"
      )
      assert(
        vim.tbl_contains(argv, "--unshare-net") and vim.tbl_contains(argv, "--tmpfs"),
        "review helper is isolated"
      )
      assert(
        run_options.clear_env and run_options.close_fds and not run_options.env.TMUX,
        "review helper inherits no tmux environment or extra descriptors"
      )
      local action_path = argv[#argv]
      local action = vim.json.decode(read_file(action_path))
      eq(vim.uv.fs_lstat(action_path).mode % 512, 384, "action manifest is private")
      local path = assert(baseline_module._internal.decode_hex(action.path_hex))
      mutation_calls[#mutation_calls + 1] = copy(action)
      temporary_actions[#temporary_actions + 1] = action_path
      local desired = action.desired
      eq(action.expected, {
        kind = "regular",
        mode = "100644",
        size = #agent_bytes,
        sha256 = vim.fn.sha256(agent_bytes),
      }, "mutation manifest carries the exact reviewed object")
      local bytes = read_file(desired.source)
      temporary_actions[#temporary_actions + 1] = desired.source
      eq(vim.uv.fs_lstat(desired.source).mode % 512, 384, "desired action object is private")
      eq(bytes, "one\nTWO\nthree\nfour\n", "manifest desired object preserves the accepted hunk")
      action_fixture:write(path, bytes, desired.mode == "100755" and 493 or 420)
      desired.source = nil
      return { code = 0, signal = 0, stdout = vim.json.encode(desired), stderr = "" }
    end
    local action_tracker = tracker_module.new({
      identity = action_identity,
      store = action_store,
      baseline = action_baseline,
      tools = action_tools,
      helpers = action_helpers,
      mutation_runner = mutation_runner,
      start_watchers = false,
    })
    assert(action_tracker:ensure_batch())
    action_fixture:write("src/two-hunks.txt", agent_bytes)
    action_fixture:write("src/reject.txt", agent_bytes)
    assert(action_tracker:scan("agent-completion"))
    local item = assert(action_tracker:get("src/two-hunks.txt"))
    local index_before = read_file(action_identity.git_dir .. "/index")
    local objects_before = action_fixture:object_count()
    local accepted = assert(action_tracker:accept_hunk(item.path, 1, item.current_hash))
    eq(accepted, {
      path = item.path,
      state = "unresolved",
      current_hash = item.current_hash,
      unresolved_hunks = 1,
    }, "accepting one hunk leaves the other unresolved")
    eq(
      read_file(action_fixture:path(item.path)),
      agent_bytes,
      "hunk acceptance never writes the worktree"
    )
    eq(
      action_baseline:bytes(item.path),
      base_bytes,
      "hunk acceptance never changes the immutable dirty baseline"
    )
    eq(
      read_file(action_identity.git_dir .. "/index"),
      index_before,
      "review acceptance preserves the real fixture index"
    )
    eq(action_fixture:object_count(), objects_before, "review acceptance writes no Git objects")
    local decision_record =
      assert(action_store:read_review_decision(action_baseline:id(), item.path))
    eq(
      assert(
        action_store:read_review_object(action_baseline:id(), decision_record.decision_base.sha256)
      ),
      "one\nTWO\nthree\nfour\n",
      "private decision bytes contain exactly the accepted hunk"
    )
    local reopened_tracker = tracker_module.new({
      identity = action_identity,
      store = action_store,
      baseline = assert(baseline_module.open(action_identity, action_store, action_baseline:id())),
      tools = action_tools,
      helpers = action_helpers,
      mutation_runner = mutation_runner,
      start_watchers = false,
    })
    assert(reopened_tracker:ensure_batch())
    assert(reopened_tracker:scan("reopen"))
    eq(
      reopened_tracker:get(item.path).decision_base,
      decision_record.decision_base,
      "reopening preserves the partial decision base"
    )
    local remaining_item = reopened_tracker:get(item.path)
    eq(
      assert(reopened_tracker:accept_hunk(item.path, 1, remaining_item.current_hash)).state,
      "accepted",
      "reopened review accepts only its remaining hunk"
    )
    local reject_item = reopened_tracker:get("src/reject.txt")
    assert(reopened_tracker:accept_hunk(reject_item.path, 1, reject_item.current_hash))
    local result = assert(
      reopened_tracker:reject_hunk(
        reject_item.path,
        1,
        reopened_tracker:get(reject_item.path).current_hash
      )
    )
    eq(result.state, "accepted", "rejecting the remaining hunk retains accepted bytes")
    eq(result.unresolved_hunks, 0, "mixed accept/reject decisions resolve all hunks")
    eq(
      read_file(action_fixture:path(reject_item.path)),
      "one\nTWO\nthree\nfour\n",
      "reject changes only the chosen hunk"
    )
    eq(#mutation_calls, 1, "accepts never invoke the filesystem mutation runner")
    for _, path in ipairs(temporary_actions) do
      assert(
        not vim.uv.fs_lstat(path),
        "one-time action inputs are removed after helper completion"
      )
    end
    reopened_tracker:shutdown()
    assert(action_tracker:abandon())
  end

  local function task8_fixture(label, initial, inside_git)
    local f = Fixture.new(label)
    f:write("anchor", "committed\n")
    f:commit("private review action fixture")
    local function put(path, object)
      if vim.uv.fs_lstat(f:path(path)) then
        f:unlink(path)
      end
      if object.kind == "regular" then
        f:write(path, object.bytes, object.mode == "100755" and 493 or 420)
      elseif object.kind == "symlink" then
        f:symlink(path, object.bytes)
      end
    end
    for path, object in pairs(initial or {}) do
      put(path, object)
    end
    local id = f:identity(inside_git)
    local storage = assert(require("ai.state")._test.open({
      identity = id,
      uid = vim.uv.getuid(),
      runtime_base = f.base .. "/run",
      state_base = f.base .. "/durable",
    }))
    local saved = assert(baseline_module.create(id, storage))
    local t = { fixture = f, store = storage, baseline = saved, put = put, calls = {}, inputs = {} }
    t.options = {
      identity = id,
      store = storage,
      baseline = saved,
      start_watchers = false,
      tools = {
        python = assert(require("ai.tools").resolve("/usr/bin/python3")),
        bwrap = assert(require("ai.tools").resolve("/usr/bin/bwrap")),
      },
      helpers = { review_helper = worktree .. "/scripts/nvim-ai-review.py" },
    }
    t.options.mutation_runner = function(argv, run_options)
      local action = vim.json.decode(read_file(argv[#argv]))
      local path = assert(baseline_module._internal.decode_hex(action.path_hex))
      t.calls[#t.calls + 1] = copy(action)
      t.inputs[#t.inputs + 1] = argv[#argv]
      local desired = copy(action.desired)
      if desired.source ~= vim.NIL then
        t.inputs[#t.inputs + 1] = desired.source
        desired.bytes = read_file(desired.source)
      end
      if t.runner then
        return t.runner(action, desired, argv, run_options)
      end
      put(path, desired)
      desired.source, desired.bytes = nil, nil
      return { code = 0, signal = 0, stdout = vim.json.encode(desired), stderr = "" }
    end
    t.tracker = tracker_module.new(t.options)
    assert(t.tracker:ensure_batch())
    return t
  end

  do
    for _, case in ipairs({ "created", "changed", "deleted", "modified", "symlink", "read-hook" }) do
      local initial = case == "created" and {}
        or { item = { kind = "regular", bytes = "before\n" } }
      local t = task8_fixture("native-reload-" .. case, initial)
      local current = vim.api.nvim_get_current_buf()
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, t.fixture:path("item"))
      vim.api.nvim_buf_call(buf, function()
        vim.cmd.edit()
      end)
      vim.bo[buf].autoread = false
      if case == "modified" then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved user text" })
      elseif case == "read-hook" then
        vim.api.nvim_create_autocmd("BufReadPost", {
          buffer = buf,
          once = true,
          callback = function()
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "user edit from read hook" })
          end,
        })
      end
      if case == "deleted" then
        t.put("item", { kind = "absent" })
      elseif case == "symlink" then
        local target = t.fixture.base .. "/outside"
        write_file(target, "outside content must not be loaded\n", 384)
        t.put("item", { kind = "symlink", bytes = target })
      else
        t.put("item", { kind = "regular", bytes = "external edit\n" })
      end
      assert(t.tracker:scan("native-reload"))
      local expected = case == "modified" and "unsaved user text"
        or case == "read-hook" and "user edit from read hook"
        or (case == "deleted" or case == "symlink") and "before"
        or "external edit"
      eq(
        vim.api.nvim_buf_get_lines(buf, 0, -1, false),
        { expected },
        "native reload preserves correct text: " .. case
      )
      eq(
        vim.bo[buf].autoread,
        false,
        "native reload does not change the user's local autoread option"
      )
      eq(vim.api.nvim_get_current_buf(), current, "hidden-buffer reload preserves editor focus")
      local manual = case == "modified" or case == "symlink" or case == "read-hook"
      eq(
        t.tracker:get("item").state,
        manual and "conflicted" or "unresolved",
        "unsafe reload stays manual-only: " .. case
      )
      assert(t.tracker:abandon())
      t.tracker:shutdown()
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end

  do
    local kinds = {
      { kind = "absent" },
      { kind = "regular", mode = "100755", bytes = "dirty\0baseline\255\n" },
      { kind = "symlink", bytes = "literal-$HOME-target" },
    }
    for base_index, base in ipairs(kinds) do
      for current_index, current in ipairs(kinds) do
        if base_index ~= current_index or base.kind ~= "absent" then
          local t =
            task8_fixture("whole-matrix-" .. base_index .. "-" .. current_index, { item = base })
          current = copy(current)
          if current.bytes then
            current.bytes = current.bytes .. "agent"
          end
          t.put("item", current)
          assert(t.tracker:scan("agent"))
          local item = t.tracker:get("item")
          eq(item.action, "whole", "type, mode and binary changes expose whole-file actions")
          local result = assert(t.tracker:reject_file("item", item.current_hash))
          eq(result.state, "rejected", "whole-file rejection restores the immutable dirty baseline")
          eq(result.unresolved_hunks, 0, "whole-file rejection resolves the path")
          eq(
            baseline_module._internal.read_current(t.options.identity, "item").object,
            t.tracker:get("item").current,
            "result is freshly fingerprinted"
          )
          eq(
            result.current_hash,
            baseline_module._internal.fingerprint_hash(t.tracker:get("item").baseline),
            "kind, mode, size and bytes match the baseline"
          )
          eq(#t.calls, 1, "whole-file rejection uses one confined mutation")
          for _, input in ipairs(t.inputs) do
            assert(not vim.uv.fs_lstat(input), "one-time inputs cleaned")
          end
          assert(t.tracker:abandon())
        end
      end
    end
    local t = task8_fixture("whole-accept", { item = { kind = "regular", bytes = "before\n" } })
    t.put("item", { kind = "regular", bytes = "after\255\n" })
    assert(t.tracker:scan("agent"))
    local item = t.tracker:get("item")
    eq(item.action, "whole", "invalid UTF-8 routes to whole-file review")
    local result = assert(t.tracker:accept_file("item", item.current_hash))
    eq(result.state, "accepted", "whole-file acceptance resolves binary bytes")
    eq(
      read_file(t.fixture:path("item")),
      "after\255\n",
      "whole-file acceptance does not write disk"
    )
    eq(#t.calls, 0, "whole-file acceptance does not invoke mutation")
    assert(t.tracker:abandon())
  end

  do
    local t = task8_fixture("action-races", {
      race = { kind = "regular", bytes = "before\n" },
      ignored = { kind = "regular", bytes = "before\n" },
      ["literal-$HOME"] = { kind = "regular", bytes = "before\n" },
      journal = { kind = "regular", bytes = "one\ntwo\nthree\nfour\n" },
    })
    for _, path in ipairs({ "race", "ignored", "literal-$HOME" }) do
      t.put(path, { kind = "regular", bytes = "agent\n" })
    end
    t.put("journal", { kind = "regular", bytes = "one\nTWO\nthree\nFOUR\n" })
    assert(t.tracker:scan("agent"))
    local stale = t.tracker:get("race")
    t.put("race", { kind = "regular", bytes = "changed after render\n" })
    local result, err = t.tracker:reject_file("race", stale.current_hash)
    eq(result, nil, "stale whole-file rejection refused")
    assert(err:find("hash", 1, true), "hash-race detail")
    eq(t.tracker:get("race").state, "conflicted", "hash race latches conflict")
    eq(
      assert(t.store:read_review_decision(t.baseline:id(), "race")).state,
      "conflicted",
      "action failure persists its conflict latch"
    )
    t.fixture:write(".gitignore", "ignored\n")
    eq(
      t.tracker:accept_file("ignored", t.tracker:get("ignored").current_hash),
      nil,
      "an ignored transition cannot be accepted from a stale view"
    )
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, t.fixture:path("literal-$HOME"))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved user text" })
    eq(
      t.tracker:reject_file("literal-$HOME", t.tracker:get("literal-$HOME").current_hash),
      nil,
      "all loaded buffers are checked using literal path names"
    )
    eq(
      vim.api.nvim_buf_get_lines(buf, 0, -1, false),
      { "unsaved user text" },
      "modified buffer is untouched"
    )
    vim.api.nvim_buf_delete(buf, { force = true })
    local other = tracker_module.new(t.options)
    assert(other:ensure_batch())
    assert(other:scan("second-editor"))
    local journal_hash = t.tracker:get("journal").current_hash
    assert(other:accept_hunk("journal", 1, journal_hash))
    local newer_decision = assert(t.store:read_review_decision(t.baseline:id(), "journal"))
    eq(
      t.tracker:reject_hunk("journal", 1, journal_hash),
      nil,
      "another editor's accepted decision invalidates stale hunk indices even when disk hash matches"
    )
    eq(
      assert(t.store:read_review_decision(t.baseline:id(), "journal")),
      newer_decision,
      "a stale editor must not replace another editor's accepted decision journal"
    )
    eq(
      read_file(t.fixture:path("journal")),
      "one\nTWO\nthree\nFOUR\n",
      "stale decision journal never authorizes a write"
    )
    eq(#t.calls, 0, "failed preconditions invoke no mutation")
    other:shutdown()
    assert(t.tracker:abandon())
  end

  do
    local t = task8_fixture("manual-exact", { item = { kind = "regular", bytes = "before\n" } })
    t.put("item", { kind = "regular", bytes = "agent\n" })
    assert(t.tracker:scan("agent"))
    local item = t.tracker:get("item")
    eq(
      t.tracker:resolve("item", "accepted"),
      nil,
      "cached resolution without an explicit reviewed hash is forbidden"
    )
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, t.fixture:path("item"))
    vim.api.nvim_set_option_value("modified", false, { buf = buf })
    t.put("item", { kind = "regular", bytes = "manual disk edit\n" })
    assert(t.tracker:record_nvim_write(buf))
    item = t.tracker:get("item")
    eq(item.state, "conflicted", "manual fixture has mixed writers")
    eq(
      assert(t.tracker:resolve("item", "manual", item.current_hash)).state,
      "accepted",
      "manual resolution requires the exact displayed hash"
    )
    eq(t.tracker:get("item").writer, "mixed", "manual resolution preserves writer attribution")
    eq(
      t.tracker:get("item").reason,
      "manually resolved",
      "manual resolution is explicitly identified"
    )
    local journal = assert(t.store:read_review_decision(t.baseline:id(), "item"))
    eq(journal.decision_base, nil, "manual resolution creates no recovery object")
    local other = tracker_module.new(t.options)
    assert(other:ensure_batch())
    assert(other:scan("reopen"))
    eq(other:get("item").state, "accepted", "exact manual resolution survives reopen")
    t.put("item", { kind = "regular", bytes = "later writer\n" })
    assert(other:scan("later-writer"))
    eq(
      other:get("item").state,
      "conflicted",
      "later external writer invalidates a mixed manual resolution"
    )
    eq(#t.calls, 0, "manual resolution never mutates disk")
    other:shutdown()
    vim.api.nvim_buf_delete(buf, { force = true })
    assert(t.tracker:abandon())
  end

  do
    local t = task8_fixture("batch-resolution", { item = { kind = "regular", bytes = "before\n" } })
    local launches, permit = 0, false
    t.options.finish_review = function(review_id)
      eq(review_id, t.baseline:id(), "read-only coordinator callback receives this exact batch")
      assert(
        baseline_module.open(t.options.identity, t.store, review_id),
        "immutable baseline is retained until read-only relaunch succeeds"
      )
      launches = launches + 1
      return permit, "injected read-only relaunch failure"
    end
    t.tracker:shutdown()
    t.tracker = tracker_module.new(t.options)
    assert(t.tracker:ensure_batch())
    assert(t.tracker:scan("empty"))
    eq(t.tracker:finish_review(), nil, "an unobserved empty batch cannot auto-resolve")
    eq(launches, 0, "empty batch never relaunches the session")
    t.put("item", { kind = "regular", bytes = "agent\n" })
    assert(t.tracker:scan("agent"))
    assert(t.tracker:reject_file("item", t.tracker:get("item").current_hash))
    eq(launches, 1, "last decision requests read-only relaunch")
    eq(t.tracker:batch_status().state, "resolved", "all exact decisions resolve the batch")
    assert(
      baseline_module.open(t.options.identity, t.store, t.baseline:id()),
      "failed relaunch retains recovery storage"
    )
    permit = true
    assert(t.tracker:finish_review())
    eq(launches, 2, "read-only relaunch has an explicit retry")
    eq(t.tracker:paths(), {}, "successful relaunch closes the batch")
    eq(
      vim.uv.fs_lstat(t.store:state_dir() .. "/reviews/" .. t.baseline:id()),
      nil,
      "baseline is removed only after successful relaunch"
    )
    eq(
      vim.uv.fs_lstat(t.store:state_dir() .. "/decisions/" .. t.baseline:id()),
      nil,
      "resolved private decisions are removed with the baseline"
    )
  end

  do
    for _, failure in ipairs({
      "runner-error",
      "runner-throws",
      "wrong-result",
      "post-write-hash",
      "post-write-visibility",
      "nvim-writer",
      "modified-after-write",
    }) do
      local t = task8_fixture(
        "action-failure-" .. failure,
        { item = { kind = "regular", bytes = "before\n" } }
      )
      t.put("item", { kind = "regular", bytes = "agent\n" })
      assert(t.tracker:scan("agent"))
      local buf
      t.runner = function(_, desired)
        if failure == "runner-error" then
          return { code = 1, signal = 0, stdout = "", stderr = "private error text" }
        end
        if failure == "runner-throws" then
          error("private runner exception")
        end
        if failure == "wrong-result" then
          return { code = 0, signal = 0, stdout = "{}", stderr = "" }
        end
        if failure == "post-write-visibility" then
          t.put("item", desired)
          t.fixture:write(".gitignore", "item\n")
        else
          t.put("item", { kind = "regular", bytes = "newer writer\n" })
        end
        if failure == "nvim-writer" or failure == "modified-after-write" then
          buf = vim.api.nvim_create_buf(true, false)
          vim.api.nvim_buf_set_name(buf, t.fixture:path("item"))
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "user bytes" })
          if failure == "nvim-writer" then
            vim.api.nvim_set_option_value("modified", false, { buf = buf })
            assert(t.tracker:record_nvim_write(buf))
          end
        end
        desired.source, desired.bytes = nil, nil
        return { code = 0, signal = 0, stdout = vim.json.encode(desired), stderr = "" }
      end
      local result, err = t.tracker:reject_file("item", t.tracker:get("item").current_hash)
      eq(result, nil, "helper and postcondition failures refuse the action")
      assert(not err:find("private", 1, true), "runner diagnostics cannot leak source text")
      eq(t.tracker:get("item").state, "conflicted", "failed action latches conflict")
      eq(#t.calls, 1, "failed mutation is never retried unconfined")
      for _, input in ipairs(t.inputs) do
        assert(not vim.uv.fs_lstat(input), "failed action cleans all one-time inputs")
      end
      if buf then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      local other = tracker_module.new(t.options)
      assert(other:ensure_batch())
      assert(other:scan("failure-reopen"))
      eq(other:get("item").state, "conflicted", "postcondition failures survive reopen")
      other:shutdown()
      assert(t.tracker:abandon())
    end
  end

  do
    local t =
      task8_fixture("multi-buffer-reload", { item = { kind = "regular", bytes = "before\n" } })
    t.options.buffer_state = function()
      return { loaded = true, modified = false, bufnr = 21, bufnrs = { 21, 22 } }
    end
    local reloads = {}
    t.options.reload = function(bufnr)
      reloads[#reloads + 1] = bufnr
      return true
    end
    t.tracker:shutdown()
    t.tracker = tracker_module.new(t.options)
    assert(t.tracker:ensure_batch())
    t.put("item", { kind = "regular", bytes = "agent\n" })
    assert(t.tracker:scan("agent"))
    reloads = {}
    assert(t.tracker:reject_file("item", t.tracker:get("item").current_hash))
    eq(
      reloads,
      { 21, 22 },
      "normal checktime synchronizes every unmodified loaded buffer for the path"
    )
    assert(t.tracker:abandon())
  end

  do
    local t = task8_fixture(
      "native-confined-review",
      { item = { kind = "regular", mode = "100755", bytes = "dirty baseline\0\255\n" } }
    )
    t.options.mutation_runner = nil
    t.tracker:shutdown()
    t.tracker = tracker_module.new(t.options)
    assert(t.tracker:ensure_batch())
    t.put("item", { kind = "regular", bytes = "agent\n" })
    assert(t.tracker:scan("agent"))
    local index_bytes = read_file(t.options.identity.git_dir .. "/index")
    local objects_before = t.fixture:object_count()
    assert(
      t.tracker:reject_file("item", t.tracker:get("item").current_hash),
      "native Bubblewrap/Python rejection must succeed on Linux"
    )
    eq(
      read_file(t.fixture:path("item")),
      "dirty baseline\0\255\n",
      "real confined helper restores exact binary bytes"
    )
    eq(
      vim.uv.fs_lstat(t.fixture:path("item")).mode % 512,
      493,
      "real confined helper restores executable mode"
    )
    local mutation = require("ai.review.mutation").new(t.options)
    local desired =
      { kind = "regular", mode = "100644", size = 6, sha256 = vim.fn.sha256("denied") }
    local expected = {
      kind = "regular",
      mode = "100644",
      size = #index_bytes,
      sha256 = vim.fn.sha256(index_bytes),
    }
    eq(
      mutation:apply(t.baseline:id(), ".git/index", expected, desired, "denied"),
      nil,
      "real Bubblewrap mask refuses writes to Git administration"
    )
    eq(
      read_file(t.options.identity.git_dir .. "/index"),
      index_bytes,
      "real fixture index remains byte-identical"
    )
    eq(t.fixture:object_count(), objects_before, "review writes no Git objects")
    write_file(t.fixture.base .. "/outside", "outside sentinel", 384)
    expected =
      { kind = "regular", mode = "100644", size = 16, sha256 = vim.fn.sha256("outside sentinel") }
    eq(
      mutation:apply(t.baseline:id(), "../outside", expected, desired, "denied"),
      nil,
      "real helper refuses root escape"
    )
    eq(
      read_file(t.fixture.base .. "/outside"),
      "outside sentinel",
      "outside fixture sentinel remains untouched"
    )
    assert(
      t.store:read_review_decisions(t.baseline:id()),
      "native helper successes and failures leave no one-time input residue"
    )
    assert(t.tracker:abandon())
  end

  do
    local before = "one\ntwo\nthree\nfour\n"
    local t = task8_fixture("decision-reset", { item = { kind = "regular", bytes = before } })
    t.put("item", { kind = "regular", bytes = "one\nTWO\nthree\nFOUR\n" })
    assert(t.tracker:scan("agent"))
    assert(t.tracker:accept_hunk("item", 1, t.tracker:get("item").current_hash))
    t.put("item", { kind = "regular", bytes = "one\nLATER\nthree\nfour\n" })
    assert(t.tracker:scan("later-writer"))
    eq(
      t.tracker:get("item").decision_base,
      nil,
      "a later writer discards the mutable decision base"
    )
    assert(t.tracker:reject_hunk("item", 1, t.tracker:get("item").current_hash))
    eq(
      read_file(t.fixture:path("item")),
      before,
      "new decisions compare against the immutable baseline"
    )
    eq(
      t.tracker:get("item").state,
      "rejected",
      "discarded acceptance cannot survive a later writer"
    )
    assert(t.tracker:abandon())
  end

  do
    local t = task8_fixture(
      "mode-and-tool-drift",
      { item = { kind = "regular", bytes = "same\n", mode = "100755" } }
    )
    t.put("item", { kind = "regular", bytes = "same\n" })
    assert(t.tracker:scan("mode-change"))
    eq(t.tracker:get("item").action, "whole", "mode-only change is whole-file review")
    eq(
      t.tracker:accept_hunk("item", 1, t.tracker:get("item").current_hash),
      nil,
      "unadvertised hunk action cannot bypass mode review"
    )
    assert(t.tracker:reject_file("item", t.tracker:get("item").current_hash))
    eq(
      vim.uv.fs_lstat(t.fixture:path("item")).mode % 512,
      493,
      "mode-only rejection preserves exact baseline executable status"
    )
    local helper = t.fixture.base .. "/review-helper.py"
    write_file(helper, read_file(t.options.helpers.review_helper), 448)
    t.options.helpers = { review_helper = helper }
    t.tracker:shutdown()
    t.tracker = tracker_module.new(t.options)
    assert(t.tracker:ensure_batch())
    t.put("item", { kind = "regular", bytes = "agent\n" })
    assert(t.tracker:scan("agent"))
    assert(vim.uv.fs_chmod(helper, 384))
    local calls = #t.calls
    eq(
      t.tracker:reject_file("item", t.tracker:get("item").current_hash),
      nil,
      "pinned helper metadata drift refuses the next action"
    )
    eq(#t.calls, calls, "tool metadata failure never launches the helper")
    assert(t.tracker:abandon())
  end

  do
    for _, writer in ipairs({ "external-aba", "nvim", "same-byte-nvim" }) do
      local t = task8_fixture(
        "durable-observation-" .. writer,
        { item = { kind = "regular", bytes = "one\ntwo\nthree\nfour\n" } }
      )
      local agent = "one\nTWO\nthree\nFOUR\n"
      t.put("item", { kind = "regular", bytes = agent })
      assert(t.tracker:scan("agent"))
      assert(t.tracker:accept_hunk("item", 1, t.tracker:get("item").current_hash))
      t.put(
        "item",
        { kind = "regular", bytes = writer == "same-byte-nvim" and agent or "later writer\n" }
      )
      if writer == "external-aba" then
        assert(t.tracker:scan("later-writer"))
        t.put("item", { kind = "regular", bytes = agent })
        assert(t.tracker:scan("original-bytes-again"))
      else
        local buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(buf, t.fixture:path("item"))
        vim.api.nvim_set_option_value("modified", false, { buf = buf })
        assert(t.tracker:record_nvim_write(buf))
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      local other = tracker_module.new(t.options)
      assert(other:ensure_batch())
      assert(other:scan("reopen-after-observation"))
      eq(
        other:get("item").decision_base,
        nil,
        "invalidated partial acceptance cannot resurrect on reopen"
      )
      eq(
        other:get("item").state,
        writer == "external-aba" and "unresolved" or "conflicted",
        "writer safety survives reopening"
      )
      if writer ~= "external-aba" then
        eq(
          other:get("item").writer,
          "mixed",
          "saved Neovim writes retain their mixed-writer protection"
        )
        eq(
          other:reject_file("item", other:get("item").current_hash),
          nil,
          "reopening never enables automatic rejection of saved user edits"
        )
      end
      other:shutdown()
      assert(t.tracker:abandon())
    end
  end

  do
    for _, reopen in ipairs({ false, true }) do
      local t = task8_fixture(
        "one-shot-cleanup-" .. tostring(reopen),
        { item = { kind = "regular", bytes = "before\n" } }
      )
      local launches, cleanups = 0, 0
      t.options.finish_review = function()
        launches = launches + 1
        return launches == 1, "coordinator already cleared this exact review ID"
      end
      local cleanup = t.store.cleanup_review_decisions
      t.store.cleanup_review_decisions = function(self, ...)
        cleanups = cleanups + 1
        if cleanups == 1 then
          return nil, "injected transient cleanup failure"
        end
        return cleanup(self, ...)
      end
      t.tracker:shutdown()
      t.tracker = tracker_module.new(t.options)
      assert(t.tracker:ensure_batch())
      t.put("item", { kind = "regular", bytes = "agent\n" })
      assert(t.tracker:scan("agent"))
      assert(t.tracker:accept_file("item", t.tracker:get("item").current_hash))
      eq(launches, 1, "last decision completes the one-shot read-only transition")
      eq(cleanups, 1, "cleanup fails only after successful relaunch")
      if reopen then
        t.tracker:shutdown()
        t.tracker = tracker_module.new(t.options)
        assert(t.tracker:ensure_batch())
      end
      assert(
        t.tracker:finish_review(),
        "cleanup retry must not repeat the completed coordinator transition"
      )
      eq(launches, 1, "successful read-only relaunch is acknowledged durably")
      eq(t.tracker:paths(), {}, "cleanup retry closes the batch")
    end
    local t =
      task8_fixture("changed-during-relaunch", { item = { kind = "regular", bytes = "before\n" } })
    local launches = 0
    t.options.finish_review = function()
      launches = launches + 1
      if launches ~= 1 then
        return nil, "read-only transition is already complete"
      end
      t.put("later", { kind = "regular", bytes = "later writer\n" })
      return true
    end
    t.tracker:shutdown()
    t.tracker = tracker_module.new(t.options)
    assert(t.tracker:ensure_batch())
    t.put("item", { kind = "regular", bytes = "agent\n" })
    assert(t.tracker:scan("agent"))
    assert(t.tracker:accept_file("item", t.tracker:get("item").current_hash))
    eq(
      t.tracker:batch_status().state,
      "open",
      "post-relaunch changes retain the baseline for more explicit decisions"
    )
    assert(t.tracker:accept_file("later", t.tracker:get("later").current_hash))
    eq(launches, 1, "later decisions do not repeat an already completed relaunch")
    eq(t.tracker:paths(), {}, "later exact decisions allow cleanup of the already read-only batch")
  end

  do
    for _, operation in ipairs({ "accept_file", "manual" }) do
      local t = task8_fixture(
        "stale-hash-journal-" .. operation:gsub("_", "-"),
        { item = { kind = "regular", bytes = "one\ntwo\nthree\nfour\n" } }
      )
      t.put("item", { kind = "regular", bytes = "one\nTWO\nthree\nFOUR\n" })
      assert(t.tracker:scan("agent"))
      local other = tracker_module.new(t.options)
      assert(other:ensure_batch())
      assert(other:scan("second-editor"))
      assert(other:accept_hunk("item", 1, other:get("item").current_hash))
      local latest = assert(t.store:read_review_decision(t.baseline:id(), "item"))
      local result
      if operation == "manual" then
        result = t.tracker:resolve("item", "manual", string.rep("0", 64))
      else
        result = t.tracker:accept_file("item", string.rep("0", 64))
      end
      eq(result, nil, "outdated requested hash is refused")
      eq(
        assert(t.store:read_review_decision(t.baseline:id(), "item")),
        latest,
        "every precondition failure preserves a newer journal"
      )
      other:shutdown()
      assert(t.tracker:abandon())
    end
  end

  do
    local t =
      task8_fixture("relaunch-receipt-reopen", { item = { kind = "regular", bytes = "before\n" } })
    local session_options = {
      identity = t.options.identity,
      store = t.store,
      transport = {
        discover = function()
          return {}
        end,
      },
    }
    local coordinator = assert(require("ai.session").new(session_options))
    local review_id = "review_" .. t.baseline:id()
    assert(coordinator:prepare_review(review_id))
    t.options.finish_review = function(id)
      return coordinator:finish_review("review_" .. id)
    end
    local writes = 0
    local write_record = t.store.write_record
    t.store.write_record = function(self, ...)
      writes = writes + 1
      return write_record(self, ...)
    end
    local publish_phase = t.store.write_review_phase
    t.store.write_review_phase = function()
      return nil, "injected failure before acknowledgement publication"
    end
    t.tracker:shutdown()
    t.tracker = tracker_module.new(t.options)
    assert(t.tracker:ensure_batch())
    t.put("item", { kind = "regular", bytes = "agent\n" })
    assert(t.tracker:scan("agent"))
    assert(t.tracker:accept_file("item", t.tracker:get("item").current_hash))
    eq(
      t.store:read_review_phase(t.baseline:id()),
      nil,
      "tracker acknowledgement was never published"
    )
    eq(
      t.store:read_record().completed_review_id,
      review_id,
      "coordinator still durably acknowledges completion"
    )
    eq(writes, 1, "coordinator publishes the completed transition once")
    t.tracker:shutdown()
    coordinator:shutdown()
    local completed_writes = writes
    coordinator = assert(require("ai.session").new(session_options))
    t.store.write_review_phase = publish_phase
    t.options.baseline = assert(baseline_module.open(t.options.identity, t.store, t.baseline:id()))
    t.tracker = tracker_module.new(t.options)
    assert(t.tracker:ensure_batch())
    assert(t.tracker:finish_review(), "fresh tracker retries across an unpublished acknowledgement")
    eq(
      writes,
      completed_writes,
      "exact coordinator receipt avoids repeating the completed transition"
    )
    eq(t.tracker:paths(), {}, "receipt retry closes the resolved batch")
    coordinator:shutdown()
  end

  do
    local t = task8_fixture(
      "removed-baseline-cleanup-reopen",
      { item = { kind = "regular", bytes = "before\n" } }
    )
    local launches = 0
    t.options.finish_review = function()
      launches = launches + 1
      return launches == 1
    end
    local cleanup = t.store.cleanup_review_decisions
    t.store.cleanup_review_decisions = function(self, id, keep_phase)
      if not keep_phase then
        return nil, "injected final acknowledgement cleanup failure"
      end
      return cleanup(self, id, keep_phase)
    end
    t.tracker:shutdown()
    t.tracker = tracker_module.new(t.options)
    assert(t.tracker:ensure_batch())
    t.put("item", { kind = "regular", bytes = "agent\n" })
    assert(t.tracker:scan("agent"))
    assert(t.tracker:accept_file("item", t.tracker:get("item").current_hash))
    local id = t.baseline:id()
    local review_path = t.store:state_dir() .. "/reviews/" .. id
    eq(vim.uv.fs_lstat(review_path), nil, "baseline is already gone when final cleanup fails")
    eq(t.store:read_review_phase(id).phase, "cleanup", "final acknowledgement remains for recovery")
    t.tracker:shutdown()
    t.options.baseline = nil
    t.store.cleanup_review_decisions = cleanup
    t.tracker = tracker_module.new(t.options)
    eq(t.tracker:finish_review("../unsafe"), nil, "cleanup retry refuses an invalid exact ID")
    assert(
      t.tracker:finish_review(id),
      "fresh tracker can clean residue without reopening a removed baseline"
    )
    eq(
      vim.uv.fs_lstat(t.store:state_dir() .. "/decisions/" .. id),
      nil,
      "only completed private residue is removed"
    )
    eq(vim.uv.fs_lstat(review_path), nil, "cleanup retry does not create a replacement baseline")
    eq(launches, 1, "baseline-independent cleanup does not repeat the coordinator transition")
    assert(t.tracker:finish_review(id), "completed residue cleanup is idempotent")
    t.tracker:shutdown()
  end

  do
    local t = task8_fixture("removed-review-cleanup-guards")
    local id, hash = t.baseline:id(), t.baseline:manifest().baseline_hash
    local review_path = t.store:state_dir() .. "/reviews/" .. id
    local decision_path = t.store:state_dir() .. "/decisions/" .. id
    t.options.baseline = nil
    local recovering = tracker_module.new(t.options)
    assert(t.store:write_review_phase(id, hash, "cleanup"))
    eq(recovering:finish_review(id), nil, "residue recovery never removes a surviving baseline")
    assert(baseline_module.open(t.options.identity, t.store, id))
    assert(t.baseline:remove())
    assert(vim.uv.fs_symlink(t.fixture.root, review_path))
    eq(recovering:finish_review(id), nil, "a symlink is not an absent baseline")
    assert(vim.uv.fs_unlink(review_path))
    assert(t.store:write_review_phase(id, hash, "read-only"))
    eq(
      recovering:finish_review(id),
      nil,
      "read-only acknowledgement alone does not permit residue deletion"
    )
    assert(vim.uv.fs_unlink(decision_path .. "/phase.json"))
    local object_path = decision_path .. "/" .. string.rep("a", 64) .. ".object"
    write_file(object_path, "private recovery sentinel", 384)
    eq(
      recovering:finish_review(id),
      nil,
      "missing acknowledgement preserves private recovery bytes"
    )
    eq(
      read_file(object_path),
      "private recovery sentinel",
      "unacknowledged recovery object is untouched"
    )
    assert(vim.uv.fs_unlink(object_path))
    local lease = assert(require("ai.review.serialization").acquire(t.store:state_dir()))
    eq(recovering:finish_review(id), nil, "residue cleanup requires exclusive review serialization")
    assert(lease:release())
    assert(
      recovering:finish_review(id),
      "only empty residue can be retried after its final acknowledgement was removed"
    )
    eq(vim.uv.fs_lstat(decision_path), nil, "empty residue is removed exactly")
    t.tracker:shutdown()
    recovering:shutdown()
  end

  do
    local t = task8_fixture(
      "removed-review-rmdir-retry",
      { item = { kind = "regular", bytes = "before\n" } }
    )
    local id = t.baseline:id()
    local directory = t.store:state_dir() .. "/decisions/" .. id
    local fail_rmdir, launches = true, 0
    t.store = assert(require("ai.state")._test.open({
      identity = t.options.identity,
      uid = vim.uv.getuid(),
      runtime_base = t.fixture.base .. "/run",
      state_base = t.fixture.base .. "/durable",
      fs_rmdir = function(path)
        if fail_rmdir and path == directory then
          return nil, "injected final rmdir failure", "EIO"
        end
        return vim.uv.fs_rmdir(path)
      end,
    }))
    t.options.store = t.store
    t.options.finish_review = function()
      launches = launches + 1
      return launches == 1
    end
    t.tracker:shutdown()
    t.tracker = tracker_module.new(t.options)
    assert(t.tracker:ensure_batch())
    t.put("item", { kind = "regular", bytes = "agent\n" })
    assert(t.tracker:scan("agent"))
    assert(t.tracker:accept_file("item", t.tracker:get("item").current_hash))
    eq(
      t.store:read_review_phase(id),
      nil,
      "final rmdir failure occurs after acknowledgement unlink"
    )
    eq(vim.uv.fs_lstat(directory).type, "directory", "empty private residue remains")
    t.tracker:shutdown()
    fail_rmdir = false
    t.options.baseline = nil
    t.tracker = tracker_module.new(t.options)
    assert(
      t.tracker:finish_review(id),
      "fresh tracker retries a failure after acknowledgement removal"
    )
    eq(vim.uv.fs_lstat(directory), nil, "post-acknowledgement retry removes the empty directory")
    eq(launches, 1, "post-acknowledgement retry does not repeat the read-only transition")
    t.tracker:shutdown()
  end

  do
    local t = task8_fixture("ui-picker-cancel", {
      ["a.lua"] = { kind = "regular", bytes = "before\n" },
      ["z $\n.lua"] = { kind = "regular", bytes = "before\n" },
    })
    t.put("a.lua", { kind = "regular", bytes = "agent\n" })
    assert(t.tracker:scan("agent"))
    local before = t.tracker:paths()
    local tabs, buffers = vim.api.nvim_list_tabpages(), vim.api.nvim_list_bufs()
    local picked
    local ui = require("ai.review.ui").new({
      tracker = t.tracker,
      review_id = "review_" .. t.baseline:id(),
      select = function(items, options, callback)
        picked = items
        eq(
          options.prompt,
          "AI review batch review_" .. t.baseline:id(),
          "picker names the exact batch"
        )
        eq(
          options.format_item(items[1]),
          "[unresolved] a.lua - Git-visible external change",
          "picker labels use tracker state and reason"
        )
        callback(nil)
      end,
    })
    assert(ui:open())
    eq(
      picked[3].label,
      "[unchanged] z%20%24%0A.lua",
      "picker sorts literal paths and percent-encodes unsafe bytes"
    )
    eq(
      picked[4].label,
      "[batch] Abandon review batch",
      "picker ends with explicit batch abandonment"
    )
    eq(vim.api.nvim_list_tabpages(), tabs, "picker cancellation opens no tab")
    eq(vim.api.nvim_list_bufs(), buffers, "picker cancellation creates no scratch buffer")
    eq(t.tracker:paths(), before, "picker cancellation changes no decision")
    assert(ui:close())
    assert(t.tracker:abandon())
  end

  do
    local original, agent = "one\r\ntwo\r\nthree\r\nfour", "one\r\nTWO\r\nthree\r\nFOUR"
    local t =
      task8_fixture("ui-exact-view", { ["item.lua"] = { kind = "regular", bytes = original } })
    t.put("item.lua", { kind = "regular", bytes = agent })
    assert(t.tracker:scan("agent"))
    local view = assert(t.tracker:view("item.lua"))
    eq(view.review_id, "review_" .. t.baseline:id(), "view identifies its exact batch")
    eq(
      t.tracker:batch_status().review_id,
      view.review_id,
      "picker metadata identifies the active batch"
    )
    eq(view.root, t.options.identity.root, "view retains the pinned physical root")
    eq(
      view.baseline_bytes,
      original,
      "view preserves exact baseline line endings and missing final newline"
    )
    eq(view.current_bytes, agent, "view preserves exact current bytes")
    eq(view.hunks, {
      { base_start = 2, base_count = 1, current_start = 2, current_count = 1 },
      { base_start = 4, base_count = 1, current_start = 4, current_count = 1 },
    }, "view exposes independent exact hunk coordinates")
    eq(
      assert(t.store:read_review_decisions(t.baseline:id())),
      {},
      "view writes no private decision"
    )
    assert(t.tracker:accept_hunk("item.lua", 1, view.current_hash))
    local partial = assert(t.tracker:view("item.lua"))
    eq(
      partial.baseline_bytes,
      "one\r\nTWO\r\nthree\r\nfour",
      "partial acceptance becomes the displayed decision base"
    )
    eq(
      partial.hunks,
      { { base_start = 4, base_count = 1, current_start = 4, current_count = 1 } },
      "view exposes only the remaining unresolved hunk"
    )
    eq(
      t.baseline:bytes("item.lua"),
      original,
      "display never changes the immutable recovery baseline"
    )
    eq(
      read_file(t.fixture:path("item.lua")),
      agent,
      "view and acceptance never change current disk bytes"
    )
    view.current.kind = "tampered"
    eq(t.tracker:view("item.lua").current.kind, "regular", "view records are isolated snapshots")
    t.put("item.lua", { kind = "regular", bytes = "later writer\n" })
    eq(t.tracker:view("item.lua"), nil, "view refuses bytes newer than the tracked hash")
    assert(t.tracker:abandon())
  end

  local function review_buffer(review_id, side, encoded_path)
    local name = "nvim-ai-" .. side .. "://" .. review_id .. "/" .. encoded_path
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buf) == name then
        return buf
      end
    end
    error("owned review buffer was not found: " .. side)
  end

  do
    local t = task8_fixture(
      "ui-native-diff",
      { ["item.lua"] = { kind = "regular", bytes = "local a = 1\nlocal b = 2" } }
    )
    t.put("item.lua", { kind = "regular", bytes = "local a = 10\nlocal b = 2" })
    assert(t.tracker:scan("agent"))
    local original_tab, original_buffer =
      vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_buf()
    local tab_count = #vim.api.nvim_list_tabpages()
    local ui = require("ai.review.ui").new({ tracker = t.tracker })
    assert(ui:open_path("item.lua"))
    local review_id = "review_" .. t.baseline:id()
    local left, right =
      review_buffer(review_id, "baseline", "item.lua"),
      review_buffer(review_id, "current", "item.lua")
    local tab = vim.api.nvim_get_current_tabpage()
    assert(tab ~= original_tab, "review opens in its own tab")
    eq(#vim.api.nvim_list_tabpages(), tab_count + 1, "one dedicated review tab is created")
    eq(
      vim.api.nvim_buf_get_lines(left, 0, -1, false),
      { "local a = 1", "local b = 2" },
      "left side shows exact baseline lines"
    )
    eq(
      vim.api.nvim_buf_get_lines(right, 0, -1, false),
      { "local a = 10", "local b = 2" },
      "right side shows current lines"
    )
    local windows = vim.api.nvim_tabpage_list_wins(tab)
    eq(#windows, 2, "native review has two windows")
    eq(vim.api.nvim_win_get_buf(windows[1]), left, "baseline is on the left")
    eq(vim.api.nvim_win_get_buf(windows[2]), right, "current file is on the right")
    for _, buf in ipairs({ left, right }) do
      eq(vim.bo[buf].buftype, "nofile", "review content is scratch-only")
      eq(vim.bo[buf].bufhidden, "wipe", "review scratch is wiped when hidden")
      eq(vim.bo[buf].swapfile, false, "review content has no swap file")
      eq(vim.bo[buf].modifiable, false, "published review scratch is never writable")
      eq(vim.bo[buf].filetype, "lua", "review filetype follows the real source name")
      eq(vim.bo[buf].endofline, false, "review retains missing final newline metadata")
      eq(vim.b[buf].nvim_ai_review_path, "item.lua", "review buffer stores the exact relative path")
      eq(
        vim.b[buf].nvim_ai_review_hash,
        t.tracker:get("item.lua").current_hash,
        "review buffer stores its displayed exact hash"
      )
      eq(vim.b[buf].nvim_ai_review_hunk, 1, "review buffer stores the current hunk index")
    end
    for _, win in ipairs(windows) do
      eq(vim.wo[win].diff, true, "both native windows enable diff mode")
    end
    vim.api.nvim_set_current_tabpage(original_tab)
    assert(ui:close())
    eq(
      vim.api.nvim_get_current_tabpage(),
      original_tab,
      "closing a background review does not steal focus"
    )
    eq(
      vim.api.nvim_get_current_buf(),
      original_buffer,
      "closing review preserves the original buffer"
    )
    eq(vim.api.nvim_tabpage_is_valid(tab), false, "close removes only the owned review tab")
    eq(vim.api.nvim_buf_is_valid(left), false, "baseline scratch is wiped on close")
    eq(vim.api.nvim_buf_is_valid(right), false, "current scratch is wiped on close")
    assert(ui:close(), "review close is idempotent")
    assert(t.tracker:abandon())
  end

  local function review_mapping(buf, lhs)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if map.lhs == lhs then
        return map.callback
      end
    end
  end

  do
    local t = task8_fixture(
      "ui-hunk-actions",
      { ["item.lua"] = { kind = "regular", bytes = "one\ntwo\nthree\nfour\n" } }
    )
    local agent = "one\nTWO\nthree\nFOUR\n"
    t.put("item.lua", { kind = "regular", bytes = agent })
    assert(t.tracker:scan("agent"))
    local ui = require("ai.review.ui").new({ tracker = t.tracker, notify = function() end })
    assert(ui:open_path("item.lua"))
    local review_id = "review_" .. t.baseline:id()
    local left, right =
      review_buffer(review_id, "baseline", "item.lua"),
      review_buffer(review_id, "current", "item.lua")
    local windows = vim.api.nvim_tabpage_list_wins(0)
    vim.api.nvim_win_set_cursor(windows[2], { 2, 0 })
    vim.api.nvim_win_set_cursor(windows[1], { 4, 0 })
    vim.api.nvim_set_current_win(windows[1])
    local accept = assert(review_mapping(left, "a"), "owned diff installs hunk acceptance")
    assert(accept(), "left-side mapping uses the current-side cursor to accept the first hunk")
    eq(
      read_file(t.fixture:path("item.lua")),
      agent,
      "accepting a displayed hunk does not write disk"
    )
    eq(
      vim.api.nvim_buf_is_valid(left),
      false,
      "successful action recreates scratch without making the old one writable"
    )
    left, right =
      review_buffer(review_id, "baseline", "item.lua"),
      review_buffer(review_id, "current", "item.lua")
    eq(
      vim.api.nvim_buf_get_lines(left, 0, -1, false),
      { "one", "TWO", "three", "four" },
      "accepted hunk is reflected in the new decision-base view"
    )
    eq(#t.tracker:view("item.lua").hunks, 1, "only the unaccepted hunk remains")
    vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { 4, 0 })
    assert(assert(review_mapping(right, "r"), "owned diff installs hunk rejection")())
    eq(
      read_file(t.fixture:path("item.lua")),
      "one\nTWO\nthree\nfour\n",
      "displayed rejection changes only the selected remaining hunk"
    )
    eq(
      t.tracker:get("item.lua").state,
      "accepted",
      "mixed accept/reject decisions resolve the displayed file"
    )
    eq(t.tracker:get("item.lua").unresolved_hunks, 0, "resolved view has no remaining hunks")
    right = review_buffer(review_id, "current", "item.lua")
    eq(vim.bo[right].modifiable, false, "refreshed current scratch remains read-only")
    eq(review_mapping(right, "a"), nil, "resolved views do not advertise more automatic actions")
    assert(ui:close())
    assert(t.tracker:abandon())
  end

  do
    local cases = {
      {
        name = "binary",
        before = { kind = "regular", bytes = "base\0" },
        after = { kind = "regular", bytes = "agent\0" },
        key = "A",
      },
      {
        name = "invalid-utf8",
        before = { kind = "regular", bytes = "before\n" },
        after = { kind = "regular", bytes = "agent\255" },
        key = "R",
      },
      {
        name = "symlink",
        before = { kind = "symlink", bytes = "old$target" },
        after = { kind = "symlink", bytes = "$HOME/new\n" },
        key = "R",
      },
      {
        name = "mode",
        before = { kind = "regular", mode = "100755", bytes = "same\n" },
        after = { kind = "regular", bytes = "same\n" },
        key = "R",
      },
      {
        name = "created",
        before = { kind = "absent" },
        after = { kind = "regular", bytes = "created\n" },
        key = "R",
      },
      {
        name = "deleted",
        before = { kind = "regular", bytes = "before\n" },
        after = { kind = "absent" },
        key = "R",
      },
    }
    for _, case in ipairs(cases) do
      local t = task8_fixture("ui-whole-" .. case.name, { item = case.before })
      t.put("item", case.after)
      assert(t.tracker:scan("agent"))
      local ui = require("ai.review.ui").new({ tracker = t.tracker, notify = function() end })
      assert(ui:open_path("item"))
      local right = review_buffer("review_" .. t.baseline:id(), "current", "item")
      eq(review_mapping(right, "a"), nil, "whole-file view has no hunk acceptance")
      eq(review_mapping(right, "r"), nil, "whole-file view has no hunk rejection")
      assert(review_mapping(right, "A"), "whole-file view offers file acceptance")
      assert(review_mapping(right, "R"), "whole-file view offers file rejection")
      local lines = vim.api.nvim_buf_get_lines(right, 0, -1, false)
      assert(
        vim.tbl_contains(lines, "Kind: " .. case.after.kind),
        "whole-file view describes its exact object kind"
      )
      local display = table.concat(lines, "\n")
      assert(
        not display:find("\0", 1, true) and not display:find("\255", 1, true),
        "binary content is metadata, not unsafe scratch text"
      )
      if case.name == "symlink" then
        assert(
          vim.tbl_contains(lines, "Target: %24HOME/new%0A"),
          "symlink target is literal and byte-escaped"
        )
      end
      assert(review_mapping(right, case.key)())
      eq(
        t.tracker:get("item").state,
        case.key == "A" and "accepted" or "rejected",
        "whole-file control resolves the exact displayed object"
      )
      local expected = case.key == "A" and case.after or case.before
      local current = assert(t.tracker:view("item"))
      eq(
        current.current.kind,
        expected.kind,
        "whole-file decision preserves or restores the expected object kind"
      )
      if expected.kind ~= "absent" then
        eq(
          current.current_bytes,
          expected.bytes,
          "whole-file decision preserves exact object bytes"
        )
      end
      if expected.kind == "regular" then
        eq(
          current.current.mode,
          expected.mode or "100644",
          "whole-file rejection restores executable mode"
        )
      end
      assert(ui:close())
      assert(t.tracker:abandon())
    end
  end

  do
    for _, kind in ipairs({ "mixed", "ignored", "unsupported", "non-git" }) do
      local initial = { item = { kind = "regular", bytes = "before\n" } }
      if kind == "ignored" then
        initial[".gitignore"] = { kind = "regular", bytes = "item\n" }
      end
      local t = task8_fixture("ui-manual-" .. kind, initial, kind ~= "non-git")
      if kind == "unsupported" then
        t.put("item", { kind = "absent" })
        assert(vim.uv.fs_mkdir(t.fixture:path("item"), 448))
      else
        t.put("item", { kind = "regular", bytes = "agent\n" })
      end
      assert(t.tracker:scan("agent"))
      if kind == "mixed" then
        t.put("item", { kind = "regular", bytes = "saved by Neovim\n" })
        local buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(buf, t.fixture:path("item"))
        vim.bo[buf].modified = false
        assert(t.tracker:record_nvim_write(buf))
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      if kind == "non-git" then
        assert(t.tracker:signal("item"))
        assert(t.tracker:scan("explicit-source"))
      end
      local before = t.tracker:get("item")
      local confirmed = false
      local ui = require("ai.review.ui").new({
        tracker = t.tracker,
        notify = function() end,
        confirm = function(message)
          assert(
            message:find("exact", 1, true),
            "manual confirmation describes exact-version resolution"
          )
          return confirmed
        end,
      })
      local opened, open_error = ui:open_path("item")
      assert(
        opened,
        kind
          .. ": conflict-only and fingerprint-only objects remain inspectable: "
          .. tostring(open_error)
      )
      local right = review_buffer("review_" .. t.baseline:id(), "current", "item")
      local guidance = table.concat(vim.api.nvim_buf_get_lines(right, 0, -1, false), "\n")
      assert(
        guidance:find("Automatic accept/reject is disabled", 1, true)
          and guidance:find(":NvimAIReview", 1, true)
          and guidance:find("press m", 1, true),
        "manual-only review explains the safe resolution workflow"
      )
      if kind == "mixed" then
        assert(
          guidance:find("Writer: mixed", 1, true) and guidance:find("Neovim", 1, true),
          "mixed-writer review explains why automatic rejection is unavailable"
        )
      end
      for _, key in ipairs({ "a", "r", "A", "R" }) do
        eq(review_mapping(right, key), nil, "manual-only view has no automatic decision mapping")
      end
      local manual =
        assert(review_mapping(right, "m"), "manual-only view provides explicit resolution")
      eq(manual(), nil, "manual resolution requires confirmation")
      eq(t.tracker:get("item"), before, "cancelled manual confirmation leaves the record unchanged")
      confirmed = true
      assert(manual())
      local resolved = t.tracker:get("item")
      eq(resolved.state, "accepted", "manual UI resolves the exact displayed fingerprint")
      eq(
        resolved.current_hash,
        before.current_hash,
        "manual resolution keeps the displayed exact hash"
      )
      eq(resolved.writer, before.writer, "manual resolution retains original writer attribution")
      eq(resolved.reason, "manually resolved", "manual resolution is explicitly identified")
      eq(#t.calls, 0, "manual UI never launches a mutation helper")
      assert(ui:close())
      assert(t.tracker:abandon())
    end
  end

  do
    local literal, encoded = 'z $HOME|"\n.lua', "z%20%24HOME%7C%22%0A.lua"
    local t = task8_fixture("ui-navigation-source", {
      ["a.lua"] = { kind = "regular", bytes = "before\n" },
      [literal] = { kind = "regular", bytes = "before\n" },
    })
    t.put("a.lua", { kind = "regular", bytes = "agent\n" })
    t.put(literal, { kind = "regular", bytes = "literal agent\n" })
    assert(t.tracker:scan("agent"))
    local global_maps = vim.api.nvim_get_keymap("n")
    local ui = require("ai.review.ui").new({ tracker = t.tracker, notify = function() end })
    local id = "review_" .. t.baseline:id()
    assert(ui:open_path("a.lua"))
    local right = review_buffer(id, "current", "a.lua")
    for _, key in ipairs({ "a", "r", "A", "R", "m", "]r", "[r", "o", "q" }) do
      assert(review_mapping(right, key), "review buffer is missing its local control " .. key)
    end
    assert(review_mapping(right, "]r")())
    right = review_buffer(id, "current", encoded)
    eq(
      vim.b[right].nvim_ai_review_path,
      literal,
      "next unresolved path retains literal filename bytes"
    )
    assert(review_mapping(right, "]r")())
    right = review_buffer(id, "current", "a.lua")
    assert(ui:next(-1), "previous unresolved path wraps at the beginning")
    right = review_buffer(id, "current", encoded)
    assert(review_mapping(right, "[r")())
    right = review_buffer(id, "current", "a.lua")
    assert(review_mapping(right, "A")())
    assert(ui:next(1), "navigation skips accepted and unchanged paths")
    right = review_buffer(id, "current", encoded)
    local review_tab = vim.api.nvim_get_current_tabpage()
    local quit = review_mapping(right, "q")
    assert(
      review_mapping(right, "o")(),
      "open-source control opens the real literal path for editing"
    )
    local source_tab, source_buf =
      vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_buf()
    assert(source_tab ~= review_tab, "manual editing does not replace an owned review window")
    eq(
      vim.api.nvim_buf_get_name(source_buf),
      t.fixture:path(literal),
      "source opening never expands environment variables or Ex metacharacters"
    )
    eq(
      vim.api.nvim_buf_get_lines(source_buf, 0, -1, false),
      { "literal agent" },
      "manual editing opens actual current file contents"
    )
    eq(vim.bo[source_buf].buftype, "", "manual editing uses a real file buffer")
    eq(vim.bo[source_buf].modifiable, true, "only the real source buffer permits manual editing")
    assert(quit())
    eq(
      vim.api.nvim_get_current_tabpage(),
      source_tab,
      "q closes only the background owned review tab"
    )
    eq(vim.api.nvim_buf_is_valid(source_buf), true, "q preserves the real source buffer")
    eq(vim.api.nvim_tabpage_is_valid(review_tab), false, "q removes the owned review tab")
    eq(vim.api.nvim_get_keymap("n"), global_maps, "review controls never install global mappings")
    vim.api.nvim_cmd(
      { cmd = "tabclose", args = { tostring(vim.api.nvim_tabpage_get_number(source_tab)) } },
      {}
    )
    vim.api.nvim_buf_delete(source_buf, { force = true })
    assert(t.tracker:abandon())
  end

  do
    for _, changed in ipairs({ false, true }) do
      local t = task8_fixture(
        "ui-confirmed-abandon-" .. tostring(changed),
        { item = { kind = "regular", bytes = "before\n" } }
      )
      if changed then
        t.put("item", { kind = "regular", bytes = "agent\n" })
        assert(t.tracker:scan("agent"))
      end
      local permitted, requests = false, 0
      local ui = require("ai.review.ui").new({
        tracker = t.tracker,
        notify = function() end,
        select = function(items, _, callback)
          callback(items[#items])
        end,
        abandon = function(review_id)
          eq(
            review_id,
            "review_" .. t.baseline:id(),
            "picker delegates the exact batch to the shared confirmed transaction"
          )
          requests = requests + 1
          if not permitted then
            return nil, "abandonment cancelled"
          end
          return t.tracker:abandon()
        end,
      })
      assert(ui:open())
      eq(requests, 1, "abandon picker delegates instead of directly removing storage")
      assert(
        t.tracker:batch_status().state ~= "closed",
        "declined abandonment preserves an empty or changed batch"
      )
      permitted = true
      assert(ui:open())
      eq(requests, 2, "confirmed abandonment uses the same transaction")
      eq(t.tracker:batch_status().state, "closed", "confirmed transaction closes the batch")
      eq(ui:open(), nil, "opening a closed batch does not create a new review")
      assert(ui:close())
    end
  end

  do
    local t = task8_fixture("ui-stale-picker")
    local request, removals
    removals = 0
    local ui = require("ai.review.ui").new({
      tracker = t.tracker,
      notify = function() end,
      select = function(items, _, callback)
        request = { item = items[#items], complete = callback }
      end,
      abandon = function()
        removals = removals + 1
        return true
      end,
    })
    assert(ui:open())
    local cancelled = request
    assert(ui:close())
    cancelled.complete(cancelled.item)
    eq(removals, 0, "closing review invalidates pending picker callbacks")
    assert(ui:open())
    local outdated = request
    assert(t.tracker:abandon())
    local new_batch = assert(t.tracker:ensure_batch())
    assert(new_batch:id() ~= t.baseline:id(), "fixture opened a different batch")
    outdated.complete(outdated.item)
    eq(removals, 0, "a delayed picker cannot abandon a newer batch")
    assert(ui:close())
    assert(t.tracker:abandon())
  end

  do
    for _, external in ipairs({ false, true }) do
      local t = task8_fixture(
        "ui-batch-cleanup-" .. tostring(external),
        { item = { kind = "regular", bytes = "before\n" } }
      )
      local transitions = 0
      t.options.finish_review = function(id)
        eq(id, t.baseline:id(), "UI resolution requests the exact batch transition")
        transitions = transitions + 1
        return true
      end
      t.tracker:shutdown()
      t.tracker = tracker_module.new(t.options)
      assert(t.tracker:ensure_batch())
      t.put("item", { kind = "regular", bytes = "agent\n" })
      assert(t.tracker:scan("agent"))
      local ui = require("ai.review.ui").new({ tracker = t.tracker, notify = function() end })
      assert(ui:open_path("item"))
      local tab = vim.api.nvim_get_current_tabpage()
      local right = review_buffer("review_" .. t.baseline:id(), "current", "item")
      local accept = assert(review_mapping(right, "A"))
      if external then
        assert(t.tracker:abandon())
      else
        assert(accept())
      end
      assert(
        vim.wait(1000, function()
          return not vim.api.nvim_tabpage_is_valid(tab)
        end, 10),
        "batch cleanup closes its owned UI even when completed outside a mapping"
      )
      eq(
        transitions,
        external and 0 or 1,
        "last UI decision requests exactly one read-only transition"
      )
      eq(t.tracker:batch_status().state, "closed", "UI cleanup never reopens the finished batch")
      eq(accept(), nil, "a callback from a wiped review buffer cannot act again")
      assert(ui:close())
    end
  end

  do
    for _, change in ipairs({
      "disk-hunk",
      "disk-file",
      "decision-base",
      "journal",
      "confirmation",
      "closed-buffer",
    }) do
      local original, agent = "one\ntwo\nthree\nfour\n", "one\nTWO\nthree\nFOUR\n"
      local initial = { item = { kind = "regular", bytes = original } }
      if change == "confirmation" then
        initial[".gitignore"] = { kind = "regular", bytes = "item\n" }
      end
      local t = task8_fixture("ui-stale-" .. change, initial)
      t.put("item", { kind = "regular", bytes = agent })
      assert(t.tracker:scan("agent"))
      local ui = require("ai.review.ui").new({
        tracker = t.tracker,
        notify = function() end,
        confirm = function()
          t.put("item", { kind = "regular", bytes = "changed during confirmation\n" })
          return true
        end,
      })
      assert(ui:open_path("item"))
      local right = review_buffer("review_" .. t.baseline:id(), "current", "item")
      vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { 2, 0 })
      local key = change == "confirmation" and "m" or change == "disk-file" and "R" or "r"
      local act = assert(review_mapping(right, key))
      local other
      if change == "disk-hunk" or change == "disk-file" then
        t.put("item", { kind = "regular", bytes = "later writer\n" })
      elseif change == "decision-base" then
        assert(t.tracker:accept_hunk("item", 1, t.tracker:get("item").current_hash))
      elseif change == "journal" then
        other = tracker_module.new(t.options)
        assert(other:ensure_batch())
        assert(other:scan("other-editor"))
        assert(other:accept_hunk("item", 1, other:get("item").current_hash))
      elseif change == "closed-buffer" then
        assert(ui:close())
        eq(
          vim.api.nvim_buf_is_valid(right),
          false,
          "closed review really wiped the displayed buffer"
        )
      end
      local journal = t.store:read_review_decision(t.baseline:id(), "item")
      local disk = read_file(t.fixture:path("item"))
      eq(act(), nil, "a stale or closed review callback is refused: " .. change)
      eq(#t.calls, 0, "stale UI cannot invoke a mutation helper")
      eq(
        read_file(t.fixture:path("item")),
        change == "confirmation" and "changed during confirmation\n" or disk,
        "stale UI preserves the latest writer's bytes"
      )
      eq(
        t.store:read_review_decision(t.baseline:id(), "item"),
        journal,
        "stale UI preserves the latest private decision"
      )
      if change == "disk-hunk" or change == "disk-file" then
        assert(ui:refresh(), "explicit refresh can display a newly observed exact version")
        right = review_buffer("review_" .. t.baseline:id(), "current", "item")
        eq(
          vim.b[right].nvim_ai_review_hash,
          t.tracker:get("item").current_hash,
          "refreshed UI advertises only the new hash"
        )
      end
      if other then
        other:shutdown()
      end
      assert(ui:close())
      assert(t.tracker:abandon())
    end
  end

  do
    local t = task8_fixture(
      "ui-cursor-metadata",
      { item = { kind = "regular", bytes = "one\ntwo\nthree\nfour\n" } }
    )
    t.put("item", { kind = "regular", bytes = "one\nTWO\nthree\nFOUR\n" })
    assert(t.tracker:scan("agent"))
    local ui = require("ai.review.ui").new({ tracker = t.tracker, notify = function() end })
    assert(ui:open_path("item"))
    local id = "review_" .. t.baseline:id()
    local left, right = review_buffer(id, "baseline", "item"), review_buffer(id, "current", "item")
    vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { 4, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = right, modeline = false })
    eq(vim.b[left].nvim_ai_review_hunk, 2, "baseline metadata tracks the current-side cursor hunk")
    eq(vim.b[right].nvim_ai_review_hunk, 2, "current metadata tracks the current-side cursor hunk")
    vim.api.nvim_win_set_cursor(vim.api.nvim_get_current_win(), { 3, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = right, modeline = false })
    eq(vim.b[right].nvim_ai_review_hunk, 0, "unchanged lines do not claim an unresolved hunk")
    eq(review_mapping(right, "r")(), nil, "an unchanged cursor line cannot reject a nearby hunk")
    eq(#t.calls, 0, "off-hunk cursor refusal performs no mutation")
    assert(ui:close())
    assert(t.tracker:abandon())
  end

  do
    local t = task8_fixture(
      "ui-deletion-anchor",
      { item = { kind = "regular", bytes = "one\ndelete\nthree\n" } }
    )
    t.put("item", { kind = "regular", bytes = "one\nthree\n" })
    assert(t.tracker:scan("agent"))
    local ui = require("ai.review.ui").new({ tracker = t.tracker, notify = function() end })
    assert(ui:open_path("item"))
    local right = review_buffer("review_" .. t.baseline:id(), "current", "item")
    eq(vim.api.nvim_win_get_cursor(0)[1], 1, "zero-line deletion uses its current-side anchor")
    assert(review_mapping(right, "r")(), "deletion anchor can restore its exact missing hunk")
    eq(
      read_file(t.fixture:path("item")),
      "one\ndelete\nthree\n",
      "zero-count rejection restores only the deleted lines"
    )
    assert(ui:close())
    assert(t.tracker:abandon())
  end

  assert(baseline:remove())
  eq(
    vim.uv.fs_lstat(vim.fs.joinpath(fixture.state, "reviews", baseline:id())),
    nil,
    "baseline removed"
  )
end

local ok, err = xpcall(run, debug.traceback)
local finalizer_failures = {}
local processes_final = task7_finalize_children(finalizer_failures)
local descriptors_final = false
local roots_final = false
if processes_final then
  descriptors_final = task7_finalize_descriptors(finalizer_failures)
end
if processes_final and descriptors_final then
  roots_final = task7_finalize_roots(finalizer_failures)
end
if not processes_final or not descriptors_final or not roots_final or #finalizer_failures ~= 0 then
  local retained = {}
  for index = 1, math.min(#finalizer_failures, 8) do
    table.insert(retained, finalizer_failures[index])
  end
  error(
    string.format(
      "Task 7 finalization failed: %s remaining=%d",
      #retained == 0 and "unknown" or table.concat(retained, "; "),
      #finalizer_failures - #retained
    ),
    0
  )
end
if not ok then
  error(err, 0)
end
assert(#children == 2, "Task 7 did not create exactly two child processes")

io.stdout:write("AI review assertions: ok\n")
