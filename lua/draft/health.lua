-- Read-only diagnostics: no state store, session, installation or provider requests.
local M = {}
local bit = require("bit")

local function safe(value)
  value = type(value) == "string" and value or "unavailable"
  value = vim.fn.strtrans((value:gsub("[%z\1-\31\127]", ""):gsub("\194[\128-\159]", "")))
  while #value > 1024 do
    value = vim.fn.strcharpart(value, 0, vim.fn.strchars(value) - 1)
  end
  return value
end

local function execute(argv, milliseconds)
  local output = ""
  local result = vim
    .system(argv, {
      clear_env = true,
      env = { PATH = "/usr/bin:/bin", LANG = "C" },
      stdin = false,
      stdout = function(_, bytes)
        if bytes and #output < 1024 then
          output = output .. bytes:sub(1, 1024 - #output)
        end
      end,
      stderr = function() end,
    })
    :wait(milliseconds)
  return { code = result.code, signal = result.signal, stdout = output }
end

-- Inspect the exact paths state.open would use, without creating any of them.
local function readiness(ancestor, segments, private_from, private_ancestor, shared_tmp)
  if
    type(ancestor) ~= "string"
    or ancestor:sub(1, 1) ~= "/"
    or safe(ancestor) ~= ancestor
    or vim.fs.normalize(ancestor, { expand_env = false }) ~= ancestor
    or vim.uv.fs_realpath(ancestor) ~= ancestor
  then
    return nil, "ancestor is missing or noncanonical"
  end
  local function valid(path, private, shared)
    local stat = vim.uv.fs_lstat(path)
    if not stat or stat.type ~= "directory" or vim.uv.fs_realpath(path) ~= path then
      return false
    end
    if shared then
      return path == "/tmp" and stat.uid == 0 and stat.mode % 4096 == 1023
    end
    return stat.uid == vim.uv.getuid()
      and bit.band(stat.mode, 18) == 0
      and (not private or stat.mode % 512 == 448)
  end
  if
    not valid(ancestor, private_ancestor, shared_tmp)
    or not vim.uv.fs_access(ancestor, "W")
    or not vim.uv.fs_access(ancestor, "X")
  then
    return nil, "ancestor ownership or access is unsafe"
  end
  local path = ancestor
  for index, segment in ipairs(segments) do
    path = path .. "/" .. segment
    if not vim.uv.fs_lstat(path) then
      return true, "ready to create privately (not created)"
    end
    if
      not valid(path, index >= private_from)
      or not vim.uv.fs_access(path, "W")
      or not vim.uv.fs_access(path, "X")
    then
      return nil, "existing directory is unsafe"
    end
  end
  return true, "existing private directories are ready"
end

function M.check(options)
  options = options or {}
  local health = options.report or vim.health
  local function report(level, message)
    health[level](safe(message))
  end
  report("start", "Draft: Neovim AI companion")
  local platform = (options.platform or function()
    return vim.uv.os_uname().sysname
  end)()
  report("info", "Neovim platform: " .. safe(platform))
  if platform ~= "Linux" then
    report(
      "warn",
      "Native AI launch disabled outside Linux; macOS integration is not yet validated."
    )
    return true
  end
  local version = vim.version()
  report("info", string.format("Neovim %d.%d.%d", version.major, version.minor, version.patch))
  local tools = require("ai.tools")
  local system = options.system or execute
  local function run(argv)
    if not tools.revalidate(argv[1]) then
      return nil
    end
    local ok, result = pcall(system, argv, 2000)
    return ok and type(result) == "table" and result or nil
  end
  local tmux = tools.resolve("tmux")
  if tmux then
    local result = run({ tmux, "-V" })
    report(
      result and result.code == 0 and "ok" or "warn",
      "tmux: " .. tmux .. " " .. safe(result and result.stdout)
    )
    local major, minor = (result and type(result.stdout) == "string" and result.stdout or ""):match(
      "^tmux (%d+)%.(%d+)"
    )
    if not major or tonumber(major) < 3 or (tonumber(major) == 3 and tonumber(minor) < 7) then
      report("warn", "tmux 3.7 or newer is required for the approved tmux integration.")
    end
  else
    report("info", "tmux unavailable; standalone Neovim terminals remain available.")
  end
  local bwrap, bwrap_error = tools.resolve("bwrap")
  if bwrap then
    report("info", "Bubblewrap: " .. bwrap)
    local result = run({
      bwrap,
      "--new-session",
      "--unshare-pid",
      "--unshare-ipc",
      "--unshare-uts",
      "--die-with-parent",
      "--ro-bind",
      "/",
      "/",
      "--dev",
      "/dev",
      "--proc",
      "/proc",
      "--",
      "/bin/true",
    })
    report(
      result and result.code == 0 and (result.signal or 0) == 0 and "ok" or "error",
      result and result.code == 0 and "Read-only Bubblewrap self-check passed."
        or "Read-only Bubblewrap self-check failed; launch is unavailable."
    )
  else
    report("error", "Bubblewrap unavailable: " .. safe(bwrap_error))
  end
  local resolved, identity = pcall(function()
    return require("ai.identity").resolve()
  end)
  if resolved and type(identity) == "table" then
    report("ok", "Physical root: " .. identity.root)
    report(
      "info",
      "Identity: " .. identity.key .. "; owner: " .. (identity.owner_pane or "standalone Neovim")
    )
    local runtime_ancestor, runtime_segments, shared_tmp =
      vim.env.XDG_RUNTIME_DIR, { "draft.nvim", identity.key }, false
    if not runtime_ancestor or runtime_ancestor == "" then
      runtime_ancestor, runtime_segments, shared_tmp =
        "/tmp", { "draft.nvim-" .. vim.uv.getuid(), identity.key }, true
    end
    local ready, reason =
      readiness(runtime_ancestor, runtime_segments, 1, not shared_tmp, shared_tmp)
    report(
      ready and "ok" or "error",
      "Private runtime: "
        .. safe(runtime_ancestor)
        .. "/"
        .. table.concat(runtime_segments, "/")
        .. " — "
        .. reason
    )
    local state_ancestor, segments, private_from =
      vim.env.XDG_STATE_HOME, { "draft.nvim", identity.key }, 1
    if not state_ancestor or state_ancestor == "" then
      state_ancestor, segments, private_from =
        vim.env.HOME, { ".local", "state", "draft.nvim", identity.key }, 3
    end
    ready, reason = readiness(state_ancestor, segments, private_from)
    report(
      ready and "ok" or "error",
      "Private durable state: "
        .. safe(state_ancestor)
        .. "/"
        .. table.concat(segments, "/")
        .. " — "
        .. reason
    )
    if identity.owner_pane and identity.tmux_socket and tmux then
      report("info", "tmux socket: " .. identity.tmux_socket)
      local called, panes = pcall(function()
        local transport = require("ai.transports.tmux").new({ tmux = tmux })
        return transport and transport:discover(identity)
      end)
      if not called or type(panes) ~= "table" then
        report("error", "Pane metadata discovery failed.")
      elseif #panes > 1 then
        report(
          "error",
          "Multiple identity-matching companion panes; explicit reconciliation is required."
        )
      else
        report("info", "Identity-matching tmux companions: " .. #panes)
      end
    else
      report("info", "Standalone terminal: pane ownership remains local to this Neovim instance.")
    end
  else
    report("error", "Physical AI identity is unavailable; no session was created.")
  end
  local backend_health = options.backend_health
    or function(name)
      return require("ai.backends").health(name)
    end
  for _, name in ipairs({ "codex", "claude", "opencode" }) do
    local ok, value = pcall(backend_health, name)
    if not ok or type(value) ~= "table" then
      report("error", name .. ": local health probe failed.")
    else
      report("info", name .. " executable: " .. safe(value.executable))
      report("info", name .. " version: " .. safe(value.version))
      local auth = ({
        authenticated = true,
        unauthenticated = true,
        unknown = true,
        unsupported = true,
      })[value.auth] and value.auth or "unknown"
      report(
        auth == "authenticated" and "ok" or "warn",
        name .. " local authentication: " .. auth .. " (no login attempted)"
      )
      local capabilities = { "open", "closed", "failed" }
      for _, capability in ipairs({ "approval", "busy", "completion", "exact_session" }) do
        if type(value.capabilities) == "table" and value.capabilities[capability] == true then
          capabilities[#capabilities + 1] = capability
        end
      end
      report("info", name .. " capabilities: " .. table.concat(capabilities, ", "))
      if value.installed ~= true or value.error ~= "" then
        report("warn", name .. ": " .. safe(value.error))
      end
    end
  end
  return true
end

return M
