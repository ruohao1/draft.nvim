-- An explicitly opt-in transport demonstration, not the companion public API.
assert(vim.uv.os_uname().sysname == "Linux", "validate this demo on Linux first")
local commands = { "AITransportPaste", "AITransportRestart", "AITransportClose" }
for _, name in ipairs(commands) do
  assert(vim.fn.exists(":" .. name) == 0, "command already exists: " .. name)
end

local tools = require("ai.tools")
local python = assert(tools.resolve("python3"))
local fixture = assert(vim.api.nvim_get_runtime_file("tests/fixtures/ai/fake_cli.py", false)[1])
local terminal = assert(require("ai.transports.terminal").new())
local root = assert(vim.uv.fs_mkdtemp("/tmp/nvim-ai-manual.XXXXXX"))
assert(vim.uv.fs_chmod(root, 448))
local identity = {
  key = vim.fn.sha256(root):sub(1, 32),
  namespace = "nvim:manual-" .. root,
  root = root,
  inside_git = false,
}
local invocation = { argv = { python, "-I", "-B", fixture, root .. "/events.jsonl" } }
local registered = {}
local handle, group
local closed = false
local demo = { root = root }

function demo.close()
  if closed then
    return true
  end
  local ok, err = terminal:shutdown()
  if not ok then
    return nil, err
  end
  if vim.fn.delete(root, "rf") ~= 0 then
    return nil, "could not remove demo fixture: " .. root
  end
  closed = true
  for _, name in ipairs(registered) do
    pcall(vim.api.nvim_del_user_command, name)
  end
  if group then
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end
  return true
end

local function register(name, callback, description)
  vim.api.nvim_create_user_command(name, callback, { desc = description, force = false })
  registered[#registered + 1] = name
end

local ok, err = xpcall(function()
  local instructions = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(instructions)
  vim.bo[instructions].buftype = "nofile"
  vim.bo[instructions].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(instructions, 0, -1, false, {
    "Linux AI transport smoke demo — FAKE CLI, no provider",
    "",
    "This tests the terminal pane only, not the finished companion.",
    "The fake CLI runs in a disposable /tmp directory.",
    "",
    "Wait for FAKE CLI READY in the right-hand pane, then:",
    "  :AITransportPaste    paste a fixed context reference, without Enter",
    "  :AITransportRestart  replace the fake process in the same window",
    "  :AITransportClose    stop it and delete its temporary state",
    "",
    "You can press i in the terminal and type to interact directly.",
    "Ctrl-\\ then Ctrl-n returns to Neovim normal mode.",
    "Use :qa to leave. Exit also cleans up the demo.",
    "",
    "No real provider, authentication, Git edit, or live tmux server is used.",
    "NvimAIOpen / NvimAIPrompt / NvimAIReview are not wired yet.",
  })
  vim.bo[instructions].modified = false
  vim.bo[instructions].modifiable = false
  handle = assert(terminal:create(identity, invocation))
  register("AITransportPaste", function()
    assert(terminal:paste(handle, "Regarding demo.lua:7:3: "))
    assert(terminal:focus(handle))
  end, "Paste a fixed reference into the provider-free demo")
  register("AITransportRestart", function()
    assert(terminal:respawn(handle, invocation, { signal = 1, timeout = 2000 }))
    assert(terminal:focus(handle))
  end, "Restart the provider-free demo in its existing pane")
  register("AITransportClose", function()
    assert(demo.close())
  end, "Stop the provider-free demo and clean up")
  group = vim.api.nvim_create_augroup("AITransportManual" .. identity.key, { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      local cleaned, cleanup_error = demo.close()
      if not cleaned then
        vim.api.nvim_err_writeln(tostring(cleanup_error))
      end
    end,
  })
end, debug.traceback)
if not ok then
  local cleaned, cleanup_error = demo.close()
  error(err .. (cleaned and "" or ("\nCleanup failed: " .. tostring(cleanup_error))))
end
return demo
