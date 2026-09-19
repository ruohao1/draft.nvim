-- Real private tmux sessions; only sleep processes stand in for editors and AI.
local tools = require("ai.tools")
local tmux = assert(tools.resolve("tmux"))
local sleep = assert(tools.resolve("sleep"))
local root = assert(vim.uv.fs_mkdtemp("/tmp/nvim-ai-project-pairs.XXXXXX"))
local socket = root .. "/tmux.sock"
local hold = "exec '" .. sleep:gsub("'", "'\\''") .. "' '3600'"

local function run(args)
  local argv = { tmux, "-f", "/dev/null", "-S", socket }
  vim.list_extend(argv, args)
  local result = vim
    .system(argv, {
      text = true,
      clear_env = true,
      env = { LC_ALL = "C", TERM = "xterm-256color", SHELL = "/bin/sh" },
    })
    :wait(3000)
  assert(result.code == 0, result.stderr)
  return result.stdout:gsub("\n$", "")
end

local function value(target, format)
  return run({ "display-message", "-p", "-t", target, format })
end

local function pair(name, key)
  local path = root .. "/" .. name
  assert(vim.uv.fs_mkdir(path, 448))
  local shell = run({
    "new-session",
    "-d",
    "-P",
    "-F",
    "#{session_id}",
    "-s",
    name .. "-shell",
    "-c",
    path,
    hold,
  })
  local owner = run({
    "new-session",
    "-d",
    "-P",
    "-F",
    "#{pane_id}",
    "-s",
    name .. "-editor",
    "-c",
    path,
    hold,
  })
  local editor = value(owner, "#{session_id}")
  run({ "set-option", "-t", editor, "@dotfiles_project_shell", shell })
  run({ "set-option", "-t", shell, "@dotfiles_project_editor", editor })
  run({ "set-option", "-t", shell, "@dotfiles_project_role", "shell" })
  local stat = assert(vim.uv.fs_lstat(socket))
  return {
    editor = editor,
    shell = shell,
    identity = {
      key = string.rep(key, 32),
      root = path,
      owner_pane = owner,
      tmux_socket = socket,
      namespace = string.format("tmux:%s:%s:%s", socket, stat.dev, stat.ino),
    },
  }
end

local ok, err = xpcall(function()
  local a, b = pair("a", "a"), pair("b", "b")
  local default = assert(require("ai.transports.tmux").new({ tmux = tmux }))
  local current = assert(default:create(a.identity, { command = hold, argv = { sleep, "3600" } }))
  assert(
    value(current, "#{session_id}") == a.editor,
    "default transport ignores project-pair metadata"
  )
  assert(default:close(current, { signal = 15, timeout = 2000 }))
  local transport = assert(require("ai.transports.tmux").new({ tmux = tmux, project_pairs = true }))
  local pane = assert(transport:create(a.identity, { command = hold, argv = { sleep, "3600" } }))
  assert(value(pane, "#{session_id}") == a.shell, "AI must launch in its owner's shell session")
  assert(value(a.identity.owner_pane, "#{window_panes}") == "1", "editor must remain full width")
  assert(
    value(b.shell .. ":", "#{session_windows}") == "1",
    "another project's shell must be untouched"
  )
  assert(transport:tag(pane, {
    key = a.identity.key,
    owner = a.identity.owner_pane,
    root = a.identity.root,
    backend = "codex",
    state = "open",
    grants = "0",
    session = "last",
    opencode_token = "",
    opencode_fingerprint = "",
    opencode_version = "",
  }))
  assert(assert(transport:discover(a.identity))[1].pane == pane, "discovery must span sessions")
  local editor_window = value(a.identity.owner_pane, "#{window_id}")
  assert(transport:focus(pane))
  assert(
    value(a.shell .. ":", "#{window_id}") == value(pane, "#{window_id}"),
    "shell must display the AI window"
  )
  assert(
    value(a.editor .. ":", "#{window_id}") == editor_window,
    "AI focus must leave the editor visible"
  )

  run({ "set-option", "-t", a.editor, "@dotfiles_project_shell", b.shell })
  local wrong, reason = transport:create(a.identity, { command = hold, argv = { sleep, "3600" } })
  assert(
    not wrong and reason:find("no longer matches", 1, true),
    "cross-worktree pairing must fail before launch"
  )
  assert(
    value(b.shell .. ":", "#{session_windows}") == "1",
    "invalid pairing must not create a window"
  )
  run({ "set-option", "-t", a.editor, "@dotfiles_project_shell", a.shell })
  run({ "set-option", "-t", a.shell, "@dotfiles_project_editor", b.editor })
  wrong, reason = transport:create(a.identity, { command = hold, argv = { sleep, "3600" } })
  assert(not wrong and reason:find("no longer matches", 1, true), "peer editor must also match")
  assert(transport:close(pane, { signal = 15, timeout = 2000 }))
  print("AI project pairs: separate sessions, discovery, focus, and worktree isolation passed")
end, debug.traceback)
pcall(run, { "kill-server" })
vim.fn.delete(root, "rf")
assert(ok, err)
