local bit = require("bit")

local M = {}

local CONTROL_PATTERN = "[%z\1-\31\127]"
local EXECUTE_BITS = 73
local GROUP_OR_OTHER_WRITE_BITS = 18

local function has_control(value)
  return type(value) ~= "string" or value:find(CONTROL_PATTERN) ~= nil
end

local function metadata(stat)
  if not stat then
    return nil
  end
  return {
    dev = stat.dev,
    ino = stat.ino,
    mode = stat.mode,
    type = stat.type,
    uid = stat.uid,
  }
end

local function new(deps)
  local by_input = {}
  local by_path = {}
  local resolver = {}

  local function inspect(input)
    if type(input) ~= "string" or input == "" then
      return nil, "host tool name is empty"
    end
    if has_control(input) then
      return nil, "host tool path contains a control character"
    end

    local direct = input:sub(1, 1) == "/"
    if not direct and input:find("/", 1, true) then
      return nil, "host tool path must be absolute"
    end
    local candidate = direct and input or deps.exepath(input)
    if type(candidate) ~= "string" or candidate == "" then
      return nil, "host tool not found: " .. input
    end
    if candidate:sub(1, 1) ~= "/" then
      return nil, "host tool path must be absolute"
    end
    if has_control(candidate) then
      return nil, "host tool path contains a control character"
    end

    local canonical = deps.realpath(candidate)
    if type(canonical) ~= "string" or canonical == "" or canonical:sub(1, 1) ~= "/" then
      return nil, "host tool target is not canonical: " .. candidate
    end
    if has_control(canonical) then
      return nil, "host tool path contains a control character"
    end
    if vim.fs.normalize(canonical) ~= canonical then
      return nil, "host tool target is not canonical: " .. canonical
    end

    local stat = deps.lstat(canonical)
    if not stat or stat.type ~= "file" then
      return nil, "host tool target is not a nonsymlink regular file: " .. canonical
    end
    if
      type(stat.mode) ~= "number"
      or type(stat.uid) ~= "number"
      or stat.dev == nil
      or stat.ino == nil
    then
      return nil, "host tool metadata is incomplete: " .. canonical
    end
    if bit.band(stat.mode, EXECUTE_BITS) == 0 then
      return nil, "host tool target is not executable: " .. canonical
    end
    if bit.band(stat.mode, GROUP_OR_OTHER_WRITE_BITS) ~= 0 then
      return nil, "host tool target is group- or world-writable: " .. canonical
    end
    if stat.uid ~= deps.uid() and deps.writable(canonical) then
      return nil, "host tool target has an untrusted owner and is writable: " .. canonical
    end

    return canonical, metadata(stat)
  end

  function resolver:resolve(input)
    local cached = by_input[input]
    if cached then
      return cached.path
    end
    local path, observed_or_error = inspect(input)
    if not path then
      return nil, observed_or_error
    end
    local observed = observed_or_error
    local existing = by_path[path]
    if existing and not vim.deep_equal(existing.metadata, observed) then
      return nil, "host tool metadata changed while resolving: " .. path
    end
    local entry = existing or { path = path, metadata = observed }
    by_input[input] = entry
    by_path[path] = entry
    return path
  end

  function resolver:revalidate(path)
    if type(path) ~= "string" or path:sub(1, 1) ~= "/" or has_control(path) then
      return nil, "host tool revalidation requires a canonical absolute path"
    end
    local cached = by_path[path]
    if not cached then
      return nil, "host tool was not resolved previously: " .. path
    end
    local current = deps.lstat(path)
    if
      not current
      or current.type ~= "file"
      or type(current.mode) ~= "number"
      or type(current.uid) ~= "number"
      or current.dev == nil
      or current.ino == nil
      or bit.band(current.mode, EXECUTE_BITS) == 0
      or bit.band(current.mode, GROUP_OR_OTHER_WRITE_BITS) ~= 0
      or (current.uid ~= deps.uid() and deps.writable(path))
      or not vim.deep_equal(cached.metadata, metadata(current))
    then
      return nil, "host tool changed since resolution: " .. path
    end
    return true
  end

  function resolver:resolve_host(options)
    options = options or {}
    if
      type(options.shell) ~= "string"
      or options.shell:sub(1, 1) ~= "/"
      or has_control(options.shell)
    then
      return nil, "configured login shell must be an absolute control-free path"
    end
    local result = {}
    local required = {
      { field = "git", value = "git" },
      { field = "python", value = "python3" },
      { field = "bwrap", value = "bwrap" },
      { field = "shell", value = options.shell },
    }
    if options.identity and options.identity.tmux_socket then
      table.insert(required, { field = "tmux", value = "tmux" })
    end
    for _, item in ipairs(required) do
      if type(item.value) ~= "string" or item.value == "" then
        return nil, "required host tool is not configured: " .. item.field
      end
      local path, err = self:resolve(item.value)
      if not path then
        return nil, string.format("invalid %s host tool: %s", item.field, tostring(err))
      end
      result[item.field] = path
    end
    if not result.tmux then
      result.tmux = nil
    end
    return result
  end

  return resolver
end

local runtime = new({
  exepath = vim.fn.exepath,
  realpath = vim.uv.fs_realpath,
  lstat = vim.uv.fs_lstat,
  writable = function(path)
    return vim.uv.fs_access(path, "W") == true
  end,
  uid = vim.uv.getuid,
})

function M.resolve(name_or_path)
  return runtime:resolve(name_or_path)
end

function M.revalidate(path)
  return runtime:revalidate(path)
end

function M.resolve_host(options)
  local configured = vim.tbl_extend("force", {}, options or {})
  configured.shell = configured.shell or vim.env.SHELL
  return runtime:resolve_host(configured)
end

M._test = { new = new }

return M
