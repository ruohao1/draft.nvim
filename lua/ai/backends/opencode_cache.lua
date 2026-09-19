local bit = require("bit")
local managed = require("ai.backends.opencode_managed")
local tools = require("ai.tools")
local M = {}

-- Only the small validator/policy sources are hashed, never the large binary.
-- Executables use inode + size + nanosecond mtime/ctime, including replacements
-- and in-place updates. This is a private optimization, not same-UID attestation.
local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.uv.fs_realpath(source:match("^(.*)/lua/ai/backends/opencode_cache.lua$") or "")
local sources = {
  "lua/ai/backends/init.lua",
  "lua/ai/backends/opencode_validation.lua",
  "lua/ai/backends/opencode_managed.lua",
  "lua/ai/backends/opencode_cache.lua",
  "lua/ai/tools.lua",
  "scripts/nvim-ai-opencode-cache.py",
  "scripts/nvim-ai-review.py",
}
local MAX_BYTES = 65536

local function stamp(path, runtime_source)
  local s = vim.uv.fs_lstat(path)
  if
    not s
    or s.type ~= "file"
    or (not runtime_source and bit.band(s.mode, 18) ~= 0)
    or (s.uid ~= 0 and s.uid ~= vim.uv.getuid())
    or vim.uv.fs_realpath(path) ~= path
  then
    return nil
  end
  return {
    path,
    s.dev,
    s.ino,
    s.mode,
    s.uid,
    s.size,
    s.mtime.sec,
    s.mtime.nsec,
    s.ctime.sec,
    s.ctime.nsec,
  }
end

local function fingerprint_sources()
  if not root then
    return nil
  end
  local result = {}
  for _, relative in ipairs(sources) do
    local path = root .. "/" .. relative
    -- These sources are already trusted/executed by Neovim; do not require
    -- private permissions on the user's checkout. Receipts are stricter.
    local before = stamp(path, true)
    if not before or before[6] > 1024 * 1024 then
      return nil
    end
    local fd = vim.uv.fs_open(path, "r", 0)
    if not fd then
      return nil
    end
    local data = vim.uv.fs_read(fd, before[6] + 1, 0)
    vim.uv.fs_close(fd)
    if not data or #data ~= before[6] or not vim.deep_equal(before, stamp(path, true)) then
      return nil
    end
    result[#result + 1] = { relative, vim.fn.sha256(data) }
  end
  return vim.fn.sha256(vim.json.encode(result))
end

-- Capture while the runtime loads. If these files change underneath a running
-- editor, it must restart before that editor can read or publish a receipt.
local loaded_sources = fingerprint_sources()

local function context(identity)
  if
    not loaded_sources
    or fingerprint_sources() ~= loaded_sources
    or type(identity) ~= "table"
    or identity.installed ~= true
    or type(identity.metadata) ~= "string"
    or identity.metadata == ""
  then
    return nil
  end
  local uname = vim.uv.os_uname()
  if uname.sysname ~= "Linux" then
    return nil
  end
  local executable = stamp(identity.executable)
  local python = tools.resolve("python3")
  local bwrap = tools.resolve("bwrap")
  local shell = tools.resolve("/bin/sh")
  if not executable or not python or not bwrap or not shell then
    return nil
  end
  local hosts = {}
  for _, path in ipairs({ python, bwrap, shell }) do
    local value = stamp(path)
    if not value or not tools.revalidate(path) then
      return nil
    end
    hosts[#hosts + 1] = value
  end
  local fd = vim.uv.fs_open("/proc/sys/kernel/random/boot_id", "r", 0)
  if not fd then
    return nil
  end
  local boot = vim.uv.fs_read(fd, 64, 0)
  vim.uv.fs_close(fd)
  if not boot or not boot:match("^[a-f0-9%-]+\n$") or #boot ~= 37 then
    return nil
  end
  local version = vim.version()
  local key = vim.fn.sha256(vim.json.encode({
    1,
    root,
    loaded_sources,
    managed.version(),
    managed.config_json(),
    managed.policy_json(),
    identity.metadata,
    executable,
    hosts,
    vim.uv.getuid(),
    { uname.sysname, uname.release, uname.version, uname.machine, boot },
    { version.major, version.minor, version.patch, tostring(version.prerelease or "") },
  }))
  return { key = key, python = python }
end

local function invoke(operation, directory, current, report)
  local request = { directory = directory, key = current.key, report = report }
  local input = vim.json.encode(request)
  if #input > MAX_BYTES then
    return nil
  end
  local result = vim
    .system({ current.python, "-I", "-B", root .. "/scripts/nvim-ai-opencode-cache.py", operation }, {
      text = true,
      clear_env = true,
      env = { LANG = "C.UTF-8" },
      stdin = input,
    })
    :wait(250)
  if
    result.code ~= 0
    or result.signal ~= 0
    or result.stderr ~= ""
    or #result.stdout > MAX_BYTES
  then
    return nil
  end
  return vim.json.decode(result.stdout)
end

function M.new(options)
  local directory = options and options.directory
    or (vim.fn.stdpath("cache") .. "/draft.nvim/opencode-compat")
  local cache = {}

  -- A usable miss also returns a ticket: publication must match the context
  -- observed before the full audit, not merely the context at its completion.
  function cache:lookup(identity)
    local ok, current = pcall(context, identity)
    if not ok or not current then
      return nil
    end
    local loaded, value = pcall(invoke, "lookup", directory, current)
    -- Recheck after the helper: the executable or policy may have changed.
    local checked, after = pcall(context, identity)
    if not checked or not after or after.key ~= current.key then
      return nil
    end
    local ticket = { key = current.key }
    if
      loaded
      and type(value) == "table"
      and value.hit == true
      and managed.validate_compatibility(value.report)
    then
      return vim.deepcopy(value.report), ticket
    end
    return nil, ticket
  end

  function cache:publish(ticket, identity, report)
    if type(ticket) ~= "table" or not managed.validate_compatibility(report) then
      return false
    end
    local ok, current = pcall(context, identity)
    if not ok or not current or ticket.key ~= current.key then
      return false
    end
    local stored, value = pcall(invoke, "store", directory, current, report)
    return stored and type(value) == "table" and value.stored == true
  end

  return cache
end

return M
