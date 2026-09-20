-- Public commands through the real runtime, owner, controller and confined ACP peer.
local root = assert(vim.uv.fs_mkdtemp("/tmp/draft-public-chat-XXXXXX"))
local project, peer = root .. "/project with spaces", root .. "/opencode"
vim.fn.mkdir(project, "p", "0700")
local source_path = project .. "/example.txt"
vim.fn.writefile({ "original text" }, source_path)
assert(vim.uv.fs_chmod(source_path, 420))
local fixture =
  assert(vim.api.nvim_get_runtime_file("tests/fixtures/ai/conversation_acp.py", false)[1])
vim.fn.writefile(vim.fn.readfile(fixture, "b"), peer, "b")
assert(vim.uv.fs_chmod(peer, 448))
vim.o.columns, vim.o.lines, vim.o.swapfile = 140, 42, false
vim.cmd.edit(vim.fn.fnameescape(source_path))
local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
local audit, clients, waiting, processes, proposals = {}, {}, {}, {}, {}
local server = assert(vim.uv.new_tcp())
assert(server:bind("127.0.0.1", 0))
assert(server:listen(64, function(error)
  assert(not error)
  local client, bytes = assert(vim.uv.new_tcp()), ""
  clients[#clients + 1] = client
  assert(server:accept(client))
  client:read_start(function(failed, data)
    assert(not failed)
    if data then
      bytes = bytes .. data
      if bytes:find("\n", 1, true) then
        local event = vim.json.decode(bytes)
        audit[#audit + 1] = event
        client:read_stop()
        if event.ready == "stream" then
          waiting[#waiting + 1] = client
        else
          client:close()
        end
      end
    elseif not client:is_closing() then
      client:close()
    end
  end)
end))
local system, select = vim.system, vim.ui.select
vim.system = function(command, ...)
  local process = system(command, ...)
  for index, part in ipairs(command) do
    if part:match("/nvim%-ai%-conversation%.py$") then
      processes[#processes + 1] = { pid = process.pid, launch = command[index + 2] }
    elseif part == "--proposal" then
      proposals[vim.fs.dirname(command[index + 1])] = true
    end
  end
  return process
end
vim.ui.select = function(items, options, callback)
  callback(items[options.prompt:find("preview", 1, true) and 1 or 2])
end
local notices = {}
local function config(case)
  return {
    enabled = true,
    root = project,
    model = "fixture/model",
    opencode = peer,
    provider = {
      fixture = { options = { testCase = case, auditPort = server:getsockname().port } },
    },
  }
end
local runtime = require("draft").setup({
  staged = config("stream"),
  notify = function(message)
    notices[#notices + 1] = message
  end,
})
local function buffer(kind)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == kind then
      return buf
    end
  end
end
local function text(kind)
  return table.concat(vim.api.nvim_buf_get_lines(assert(buffer(kind)), 0, -1, false), "\n")
end
local function compose(value)
  vim.api.nvim_buf_set_lines(assert(buffer("draft-chat-input")), 0, -1, false, { value })
end
local function wait_for(predicate, reason)
  assert(vim.wait(10000, predicate, 10), reason)
end
local function phase(value)
  wait_for(function()
    return text("draft-chat"):find("Draft · " .. value .. " ·", 1, true) ~= nil
  end, "Chat did not display " .. value)
end
local function count(key, value)
  local n = 0
  for _, event in ipairs(audit) do
    n = n + (event[key] == value and 1 or 0)
  end
  return n
end
local function release()
  for _, client in ipairs(waiting) do
    client:write("continue\n", function()
      if not client:is_closing() then
        client:close()
      end
    end)
  end
  waiting = {}
end
local function close()
  vim.cmd("NvimAIChatClose")
  phase("closed")
  for _, process in ipairs(processes) do
    wait_for(function()
      return not vim.uv.kill(process.pid, 0)
    end, "Controller survived confirmed close")
    assert(
      not vim.uv.fs_stat(vim.fs.dirname(process.launch)),
      "Private launch configuration survived close"
    )
  end
end
local ok, reason = xpcall(function()
  vim.cmd("NvimAIChat " .. vim.fn.fnameescape(source_path))
  assert(#audit == 0 and #processes == 0, "Opening must remain passive")
  vim.cmd("NvimAIChatModel")
  assert(#audit == 0 and #processes == 0, "Initial model refusal must remain passive")
  compose("First explicit question.")
  vim.cmd("NvimAIChatSend")
  vim.api.nvim_set_current_win(source_win)
  wait_for(function()
    return #waiting == 1
  end, "Stream fixture did not reach its gate")
  phase("generating")
  wait_for(function()
    return text("draft-chat"):find("Read selected file [completed]", 1, true) ~= nil
  end, "Progress was not displayed while generating")
  assert(text("draft-chat"):find("A bounded answer.", 1, true))
  assert(vim.api.nvim_get_current_win() == source_win)
  compose("Second explicit question.")
  vim.cmd("NvimAIChatSend")
  assert(
    count("method", "session/prompt") == 1
      and text("draft-chat-input") == "Second explicit question."
  )
  vim.cmd("NvimAIChatHide")
  assert(not runtime:open(), "Hidden generating chat owns the runtime")
  release()
  wait_for(function()
    return count("exiting", true) == 1
  end, "First worker did not exit")
  vim.cmd("NvimAIChat")
  phase("idle")
  assert(
    count("method", "session/prompt") == 1
      and text("draft-chat-input") == "Second explicit question."
  )
  local activity = #audit
  vim.cmd("NvimAIChatModel")
  wait_for(function()
    return text("draft-chat"):find("next: fixture/second-model", 1, true) ~= nil
  end, "Selected next-turn model did not render")
  assert(#audit == activity and text("draft-chat-input") == "Second explicit question.")
  vim.cmd("NvimAIChatSend")
  wait_for(function()
    return #waiting == 1
  end, "Second turn did not stream")
  release()
  phase("idle")
  assert(count("method", "session/new") == 1 and count("method", "session/resume") == 1)
  assert(count("method", "session/prompt") == 2)
  local models = {}
  for _, event in ipairs(audit) do
    if event.method == "session/set_config_option" and event.params.configId == "model" then
      models[#models + 1] = event.params.value
    end
  end
  assert(vim.deep_equal(models, { "fixture/model", "fixture/second-model" }))
  assert(text("draft-chat"):find("Assistant · fixture/model", 1, true))
  assert(text("draft-chat"):find("Assistant · fixture/second-model", 1, true))
  compose("Keep this refused draft")
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "unsaved local edit" })
  vim.cmd("NvimAIChatSend")
  assert(text("draft-chat-input") == "Keep this refused draft")
  assert(count("method", "session/prompt") == 2)
  assert(vim.fn.readfile(source_path)[1] == "original text")
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "original text" })
  vim.bo[source].modified = false
  close()
  print("ok - public commands stream two explicit turns, resume context and retain refused drafts")

  require("ai.staged").setup(config("cancel"))
  vim.cmd("NvimAIChatNew")
  compose("Cancel this request.")
  vim.cmd("NvimAIChatSend")
  wait_for(function()
    return count("ready", "cancel") == 1
  end, "Cancellation fixture was not ready")
  compose("Unsent next draft")
  vim.cmd("NvimAIChatHide")
  vim.cmd("NvimAIChatCancel")
  wait_for(function()
    return count("cancel_received", true) == 1
  end, "ACP cancellation was not received")
  vim.cmd("NvimAIChat")
  phase("idle")
  assert(text("draft-chat-input") == "Unsent next draft")
  close()
  print("ok - hidden public cancellation is cooperative and preserves unsent input")

  require("ai.staged").setup(config("edit"))
  vim.cmd("NvimAIChatNew")
  compose("Propose an edit.")
  local tabs = #vim.api.nvim_list_tabpages()
  vim.cmd("NvimAIChatSend")
  vim.api.nvim_set_current_win(source_win)
  phase("review")
  assert(#vim.api.nvim_list_tabpages() == tabs and vim.api.nvim_get_current_win() == source_win)
  vim.cmd("NvimAIChatReview")
  assert(#vim.api.nvim_list_tabpages() == tabs + 1)
  assert(vim.api.nvim_get_current_line() == "proposed edit")
  assert(vim.fn.readfile(source_path)[1] == "original text")
  vim.cmd("NvimAIChat")
  assert(vim.bo.filetype == "draft-chat-input")
  vim.cmd("NvimAIChatCancel")
  phase("idle")
  assert(#vim.api.nvim_list_tabpages() == tabs)
  close()
  assert(runtime:shutdown())
  assert(buffer("draft-chat") == nil and buffer("draft-chat-input") == nil)
  assert(vim.fn.readfile(source_path)[1] == "original text")
  assert(#notices == 0, vim.inspect(notices))
  print("ok - public frozen preview is explicit, read-only, cancellable and cleaned on close")
end, debug.traceback)
release()
pcall(function()
  vim.cmd("NvimAIChatClose")
end)
vim.wait(3000, function()
  return runtime:shutdown() == true
end, 10)
vim.system, vim.ui.select = system, select
for _, client in ipairs(clients) do
  if not client:is_closing() then
    client:close()
  end
end
server:close()
for proposal in pairs(proposals) do
  vim.fn.delete(proposal, "rf")
end
vim.fn.delete(root, "rf")
assert(ok, reason)
