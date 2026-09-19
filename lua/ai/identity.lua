local M = {}

local CONTROL_PATTERN = "[%z\1-\31\127]"
local MAX_GIT_ENTRY_BYTES = 4096

local function has_control(value)
  return type(value) ~= "string" or value:find(CONTROL_PATTERN) ~= nil
end

local function path_within(root, path)
  if root == "/" then
    return path:sub(1, 1) == "/"
  end
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function same_node(left, right)
  return left
    and right
    and left.type == right.type
    and left.dev ~= nil
    and right.dev ~= nil
    and left.dev == right.dev
    and left.ino ~= nil
    and right.ino ~= nil
    and left.ino == right.ino
end

local function read_git_entry(path, expected, maximum)
  local fd = vim.uv.fs_open(path, "r", 0)
  if not fd then
    return nil
  end
  local opened = vim.uv.fs_fstat(fd)
  if
    not opened
    or opened.type ~= "file"
    or type(opened.size) ~= "number"
    or opened.size > maximum
    or not same_node(expected, opened)
  then
    vim.uv.fs_close(fd)
    return nil
  end
  local bytes = vim.uv.fs_read(fd, opened.size + 1, 0)
  local closed = vim.uv.fs_close(fd)
  local after = vim.uv.fs_lstat(path)
  if
    type(bytes) ~= "string"
    or #bytes ~= opened.size
    or not closed
    or not same_node(opened, after)
    or after.size ~= opened.size
  then
    return nil
  end
  return bytes
end

local function valid_pane(value)
  return type(value) == "string" and value:match("^%%%d+$") ~= nil
end

local function tmux_socket(value)
  if type(value) ~= "string" then
    return nil
  end
  return value:match("^(.*),%d+,%d+$")
end

local function split_lines(value)
  if type(value) ~= "string" then
    return {}
  end
  local lines = {}
  local offset = 1
  while true do
    local newline = value:find("\n", offset, true)
    if not newline then
      if offset <= #value then
        table.insert(lines, value:sub(offset))
      end
      break
    end
    table.insert(lines, value:sub(offset, newline - 1))
    offset = newline + 1
    if offset > #value then
      break
    end
  end
  return lines
end

local function new(deps)
  local standalone_nonce
  local resolver = {}

  local function physical(path)
    if type(path) ~= "string" or path == "" or path:sub(1, 1) ~= "/" or has_control(path) then
      return nil
    end
    local resolved = deps.realpath(path)
    if
      type(resolved) ~= "string"
      or resolved == ""
      or resolved:sub(1, 1) ~= "/"
      or has_control(resolved)
    then
      return nil
    end
    return vim.fs.normalize(resolved)
  end

  local function nearest_existing(path)
    local current = vim.fs.normalize(path)
    while current and current ~= "" do
      local resolved = physical(current)
      if resolved then
        local stat = deps.stat(resolved)
        if stat and (stat.type == "directory" or stat.type == "file") then
          return stat.type == "file" and vim.fs.dirname(resolved) or resolved
        end
      end
      local parent = vim.fs.dirname(current)
      if not parent or parent == current then
        break
      end
      current = parent
    end
    return nil
  end

  local function working_directory(context)
    local path = context.cwd
    if path == nil then
      path = deps.cwd()
    end
    local resolved = physical(path)
    if not resolved then
      return nil, "working directory is not physical"
    end
    local stat = deps.stat(resolved)
    if not stat or stat.type ~= "directory" then
      return nil, "working directory is not a directory"
    end
    return resolved, path
  end

  local function start_path(context, cwd, raw_cwd)
    local name = context.name
    if name == nil then
      name = deps.buffer_name()
    end
    local buftype = context.buftype
    if buftype == nil then
      buftype = deps.buffer_type()
    end
    if buftype == "" and type(name) == "string" and name ~= "" then
      if has_control(name) then
        return nil, "buffer path contains a control character"
      end
      local absolute
      if name:sub(1, 1) == "/" then
        absolute = vim.fs.normalize(name)
      else
        if type(raw_cwd) ~= "string" or raw_cwd:sub(1, 1) ~= "/" or has_control(raw_cwd) then
          return nil, "working directory is not physical"
        end
        absolute = vim.fs.normalize(vim.fs.joinpath(raw_cwd, name))
      end
      local stat = deps.stat(absolute)
      local candidate
      if stat and stat.type == "file" then
        local file = physical(absolute)
        if not file then
          return nil, "buffer file is not physical"
        end
        local file_stat = deps.stat(file)
        if not file_stat or file_stat.type ~= "file" then
          return nil, "buffer file is not a physical regular file"
        end
        candidate = vim.fs.dirname(file)
        local parent_stat = deps.stat(candidate)
        if not parent_stat or parent_stat.type ~= "directory" then
          return nil, "buffer file parent is not a physical directory"
        end
        return candidate
      elseif stat and stat.type == "directory" then
        candidate = physical(absolute)
        if not candidate then
          return nil, "buffer directory is not physical"
        end
        local directory_stat = deps.stat(candidate)
        if not directory_stat or directory_stat.type ~= "directory" then
          return nil, "buffer directory is not a physical directory"
        end
        return candidate
      else
        candidate = vim.fs.dirname(absolute)
      end
      local resolved = nearest_existing(candidate)
      if resolved then
        return resolved
      end
    end
    return cwd
  end

  local function query_git(start)
    if deps.revalidate_git then
      local called, valid, validation_error = pcall(deps.revalidate_git)
      if not called then
        return nil, "trusted Git executable revalidation failed: " .. tostring(valid)
      end
      if not valid then
        return nil,
          "trusted Git executable is no longer valid: " .. tostring(validation_error or "changed")
      end
    end
    local invoked, result = pcall(deps.git, start)
    if
      not invoked
      or not result
      or type(result.code) ~= "number"
      or type(result.signal) ~= "number"
      or result.signal ~= 0
      or result.code == 124
    then
      return nil, "Git root query did not complete safely"
    end
    return result
  end

  local function validate_git_entry(start, root, git_dir)
    if not path_within(root, start) then
      return nil, "Git root does not contain query start"
    end
    local entry = vim.fs.joinpath(root, ".git")
    local entry_stat = deps.lstat(entry)
    if not entry_stat or entry_stat.type == "link" then
      return nil, "Git metadata entry is not a bounded nonsymlink file or directory"
    end
    if entry_stat.type == "directory" then
      local target = physical(entry)
      local after = deps.lstat(entry)
      if not target or target ~= git_dir or not same_node(entry_stat, after) then
        return nil, "Git metadata entry does not match returned Git directory"
      end
      return entry
    end
    if
      entry_stat.type ~= "file"
      or type(entry_stat.size) ~= "number"
      or entry_stat.size < 1
      or entry_stat.size > MAX_GIT_ENTRY_BYTES
    then
      return nil, "Git metadata entry is not a bounded nonsymlink file or directory"
    end
    local bytes = deps.read_git_entry(entry, entry_stat, MAX_GIT_ENTRY_BYTES)
    if type(bytes) ~= "string" or #bytes > MAX_GIT_ENTRY_BYTES then
      return nil, "Git metadata entry could not be read safely"
    end
    local body = bytes:sub(-1) == "\n" and bytes:sub(1, -2) or bytes
    if body:find("[\r\n]") or body:sub(1, 8) ~= "gitdir: " then
      return nil, "Git metadata entry has an invalid shape"
    end
    local value = body:sub(9)
    if value == "" or has_control(value) then
      return nil, "Git metadata entry has an invalid shape"
    end
    local candidate = value:sub(1, 1) == "/" and vim.fs.normalize(value)
      or vim.fs.normalize(vim.fs.joinpath(root, value))
    local target = physical(candidate)
    local after = deps.lstat(entry)
    if not target or target ~= git_dir or not same_node(entry_stat, after) then
      return nil, "Git metadata entry does not match returned Git directory"
    end
    return entry
  end

  function resolver:resolve(context)
    context = context or {}
    local cwd, raw_cwd_or_error = working_directory(context)
    if not cwd then
      return nil, raw_cwd_or_error
    end
    local start, start_error = start_path(context, cwd, raw_cwd_or_error)
    if not start then
      return nil, start_error
    end
    local result, query_error = query_git(start)
    if not result then
      return nil, query_error
    end
    if result.code == 128 and start ~= cwd then
      if deps.find_git_entry(start) then
        return nil, "Git metadata exists but its worktree boundary could not be resolved"
      end
      start = cwd
      result, query_error = query_git(start)
      if not result then
        return nil, query_error
      end
    end

    local root, git_dir, git_common_dir, git_entry
    local inside_git = result.code == 0
    if inside_git then
      local lines = split_lines(result.stdout)
      if #lines ~= 3 or lines[1] == "" or lines[2] == "" or lines[3] == "" then
        return nil, "Git root query returned an invalid shape"
      end
      root = physical(lines[1])
      git_dir = physical(lines[2])
      git_common_dir = physical(lines[3])
      if not root or not git_dir or not git_common_dir then
        return nil, "Git root query returned a nonphysical path"
      end
      local root_stat = deps.stat(root)
      local git_dir_stat = deps.stat(git_dir)
      local git_common_stat = deps.stat(git_common_dir)
      if
        not root_stat
        or root_stat.type ~= "directory"
        or not git_dir_stat
        or git_dir_stat.type ~= "directory"
        or not git_common_stat
        or git_common_stat.type ~= "directory"
      then
        return nil, "Git root query returned a nonphysical path"
      end
      git_entry, query_error = validate_git_entry(start, root, git_dir)
      if not git_entry then
        return nil, query_error
      end
    else
      if result.code ~= 128 then
        return nil, "Git root query failed"
      end
      if deps.find_git_entry(start) then
        return nil, "Git metadata exists but its worktree boundary could not be resolved"
      end
      root = cwd
    end

    local raw_socket = tmux_socket(deps.env.TMUX)
    local pane = deps.env.TMUX_PANE
    local socket = raw_socket and physical(raw_socket) or nil
    local namespace
    local tmux_claimed = (type(deps.env.TMUX) == "string" and deps.env.TMUX ~= "")
      or (type(pane) == "string" and pane ~= "")
    if tmux_claimed and (not socket or not valid_pane(pane)) then
      return nil, "tmux identity is incomplete or invalid"
    end
    if tmux_claimed then
      local socket_stat = deps.stat(socket)
      if
        not socket_stat
        or socket_stat.type ~= "socket"
        or socket_stat.dev == nil
        or socket_stat.ino == nil
      then
        return nil, "tmux server socket identity is unavailable"
      end
      namespace = string.format("tmux:%s:%s:%s", socket, socket_stat.dev, socket_stat.ino)
    else
      if not standalone_nonce then
        local candidate = deps.nonce()
        if type(candidate) ~= "string" or candidate == "" or has_control(candidate) then
          return nil, "standalone identity nonce is invalid"
        end
        standalone_nonce = candidate
      end
      namespace = "nvim:" .. standalone_nonce
      pane = nil
      socket = nil
    end

    local digest = deps.hash(table.concat({ namespace, pane or "", root }, "\0"))
    if type(digest) ~= "string" then
      return nil, "identity hash is invalid"
    end
    local key = digest:sub(1, 32)
    if not key:match("^[0-9a-f]+$") or #key ~= 32 then
      return nil, "identity hash is invalid"
    end
    return {
      key = key,
      root = root,
      inside_git = inside_git,
      git_dir = git_dir,
      git_common_dir = git_common_dir,
      git_entry = git_entry,
      owner_pane = pane,
      tmux_socket = socket,
      namespace = namespace,
    }
  end

  return resolver
end

local trusted_tools = require("ai.tools")
local git_executable = assert(trusted_tools.resolve("git"))
local runtime = new({
  env = vim.env,
  pid = vim.fn.getpid,
  nonce = function()
    return string.format("%d_%d", vim.fn.getpid(), vim.uv.hrtime())
  end,
  cwd = function()
    return vim.fn.getcwd(0, 0)
  end,
  buffer_name = function()
    return vim.api.nvim_buf_get_name(0)
  end,
  buffer_type = function()
    return vim.bo.buftype
  end,
  realpath = vim.uv.fs_realpath,
  stat = vim.uv.fs_stat,
  lstat = vim.uv.fs_lstat,
  read_git_entry = read_git_entry,
  find_git_entry = function(start)
    return vim.fs.find(".git", { path = start, upward = true, limit = 1 })[1]
  end,
  hash = vim.fn.sha256,
  revalidate_git = function()
    return trusted_tools.revalidate(git_executable)
  end,
  git = function(start)
    return vim
      .system({
        git_executable,
        "-C",
        start,
        "rev-parse",
        "--path-format=absolute",
        "--show-toplevel",
        "--absolute-git-dir",
        "--git-common-dir",
      }, {
        text = true,
        clear_env = true,
        env = {
          LC_ALL = "C",
          GIT_OPTIONAL_LOCKS = "0",
          GIT_CONFIG_NOSYSTEM = "1",
          GIT_CONFIG_GLOBAL = "/dev/null",
          GIT_CONFIG_COUNT = "0",
        },
      })
      :wait(2000)
  end,
})

function M.resolve(context)
  return runtime:resolve(context)
end

M._test = { new = new, tmux_socket = tmux_socket, valid_pane = valid_pane }

return M
