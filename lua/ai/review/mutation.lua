-- One confined mutation seam. The runtime supplies canonical paths; never search PATH.
local bit = require("bit")
local M = {}

local function canonical(path)
  return type(path) == "string"
    and path:sub(1, 1) == "/"
    and path ~= "/"
    and not path:find("[%z\1-\31\127]")
    and not path:find("\194[\128-\159]")
    and vim.fs.normalize(path, { expand_env = false }) == path
    and vim.uv.fs_realpath(path) == path
end

local function inspect(path, executable)
  if not canonical(path) then
    return nil
  end
  local stat = vim.uv.fs_lstat(path)
  if
    not stat
    or stat.type ~= "file"
    or bit.band(stat.mode, 18) ~= 0
    or (stat.uid ~= 0 and stat.uid ~= vim.uv.getuid())
    or (executable and bit.band(stat.mode, 73) == 0)
  then
    return nil
  end
  return {
    dev = stat.dev,
    ino = stat.ino,
    mode = stat.mode,
    uid = stat.uid,
    size = stat.size,
    mtime = stat.mtime,
    ctime = stat.ctime,
  }
end

local function execute(argv, options)
  -- vim.system/libuv inherits only its explicitly configured stdio. The helper
  -- also closes descriptors >= 3 before reading its one-time manifest.
  return vim
    .system(argv, { clear_env = options.clear_env, env = options.env, text = false })
    :wait(30000)
end

local function fingerprint(object)
  return {
    kind = object.kind,
    mode = object.mode or vim.NIL,
    size = object.size,
    sha256 = object.sha256 or vim.NIL,
  }
end

function M.new(options)
  local identity, store = options.identity, options.store
  local paths = {
    python = options.tools and options.tools.python,
    bwrap = options.tools and options.tools.bwrap,
    helper = options.helpers and options.helpers.review_helper,
  }
  local initial = {}
  for _, name in ipairs({ "python", "bwrap", "helper" }) do
    initial[name] = inspect(paths[name], true)
  end
  local mutation = {}

  function mutation:check()
    for _, name in ipairs({ "python", "bwrap", "helper" }) do
      if not initial[name] or not vim.deep_equal(initial[name], inspect(paths[name], true)) then
        return nil, "trusted review tool metadata changed or is unavailable"
      end
    end
    if not canonical(identity.root) or not identity.inside_git then
      return nil, "review mutation requires a canonical Git root"
    end
    for _, name in ipairs({ "git_entry", "git_dir", "git_common_dir" }) do
      if not canonical(identity[name]) then
        return nil, "review Git protection is unavailable"
      end
    end
    return true
  end

  function mutation:apply(review_id, path, expected, desired, bytes)
    local valid, err = self:check()
    if not valid then
      return nil, err
    end
    local action = {
      schema = 1,
      root = identity.root,
      path_hex = (path:gsub(".", function(byte)
        return string.format("%02x", byte:byte())
      end)),
      expected = fingerprint(expected),
      desired = fingerprint(desired),
    }
    local published, reference, publish_error, partial =
      pcall(store.write_review_action, store, review_id, action, bytes)
    if not published or not reference then
      if partial then
        pcall(store.remove_review_action, store, partial)
      end
      return nil, "private review action publication failed"
    end
    local function run()
      if not self:check() then
        return nil, "trusted review tools changed before mutation"
      end
      local argv = {
        paths.bwrap,
        "--die-with-parent",
        "--new-session",
        "--unshare-net",
        "--ro-bind",
        "/",
        "/",
        "--dev",
        "/dev",
        "--proc",
        "/proc",
        "--tmpfs",
        "/tmp",
        "--clearenv",
      }
      local directories = {}
      local function destination(path, directory)
        local parent = directory and path or vim.fs.dirname(path)
        if parent:sub(1, 5) == "/tmp/" and not directories[parent] then
          directories[parent] = true
          vim.list_extend(argv, { "--dir", parent })
        end
      end
      destination(identity.root, true)
      vim.list_extend(argv, { "--bind", identity.root, identity.root })
      local masked = {}
      local function protect(path)
        if masked[path] then
          return true
        end
        if not canonical(path) then
          return nil
        end
        local stat = vim.uv.fs_lstat(path)
        if not stat or (stat.type ~= "directory" and stat.type ~= "file") then
          return nil
        end
        destination(path, stat.type == "directory")
        vim.list_extend(argv, { "--ro-bind", path, path })
        masked[path] = true
        return true
      end
      for _, path in ipairs({
        identity.git_entry,
        identity.git_dir,
        identity.git_common_dir,
        store:state_dir(),
        paths.python,
        paths.bwrap,
        paths.helper,
        reference.manifest,
      }) do
        if not protect(path) then
          return nil, "review protection path changed or is unavailable"
        end
      end
      if reference.source and not protect(reference.source) then
        return nil, "desired review object is unavailable"
      end
      vim.list_extend(argv, {
        "--chdir",
        identity.root,
        "--",
        paths.python,
        "-I",
        "-B",
        paths.helper,
        "--manifest",
        reference.manifest,
      })
      local response = (options.mutation_runner or execute)(
        argv,
        { clear_env = true, env = { LC_ALL = "C", LANG = "C" }, close_fds = true }
      )
      if
        type(response) ~= "table"
        or response.code ~= 0
        or response.signal ~= 0
        or type(response.stdout) ~= "string"
        or #response.stdout > 2048
      then
        return nil, "confined review helper failed"
      end
      local decoded, result = pcall(vim.json.decode, response.stdout)
      if not decoded or not vim.deep_equal(result, fingerprint(desired)) then
        return nil, "review helper returned a mismatched fingerprint"
      end
      return {
        kind = result.kind,
        mode = result.mode ~= vim.NIL and result.mode or nil,
        size = result.size,
        sha256 = result.sha256 ~= vim.NIL and result.sha256 or nil,
      }
    end
    local invoked, result, run_error = pcall(run)
    local cleaned, removed = pcall(store.remove_review_action, store, reference)
    if not cleaned or not removed then
      return nil, "private review action cleanup failed"
    end
    if not invoked then
      return nil, "confined review helper failed"
    end
    return result, run_error
  end
  return mutation
end

return M
