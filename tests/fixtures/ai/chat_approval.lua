-- Disposable production runtime with a confined scripted ACP peer, never a writer substitute.
return function(root, settings, backend, case)
  local f = { root = root, audit = {}, owners = {}, proposals = {}, clients = {}, waiters = {} }
  f.project, f.peer = root .. "/project with spaces", root .. "/opencode"
  vim.fn.mkdir(f.project, "p", "0700")
  f.paths = { "first.txt", "second.txt", "third.txt" }
  f.files = {}
  for _, path in ipairs(f.paths) do
    local file = f.project .. "/" .. path
    f.files[#f.files + 1] = file
    vim.fn.writefile({ "original text" }, file)
    assert(vim.uv.fs_chmod(file, 420))
  end
  local fixture =
    assert(vim.api.nvim_get_runtime_file("tests/fixtures/ai/conversation_acp.py", false)[1])
  vim.fn.writefile(vim.fn.readfile(fixture, "b"), f.peer, "b")
  assert(vim.uv.fs_chmod(f.peer, 448))
  vim.o.swapfile, vim.o.undofile, vim.o.modeline, vim.o.autoread = false, false, false, true
  vim.cmd.edit(vim.fn.fnameescape(f.files[1]))
  local server = assert(vim.uv.new_tcp())
  assert(server:bind("127.0.0.1", 0))
  assert(server:listen(64, function(error)
    assert(not error)
    local client, bytes = assert(vim.uv.new_tcp()), ""
    f.clients[#f.clients + 1] = client
    assert(server:accept(client))
    client:read_start(function(failed, data)
      assert(not failed)
      if data then
        bytes = bytes .. data
        if bytes:find("\n", 1, true) then
          local event = vim.json.decode(bytes)
          f.audit[#f.audit + 1] = event
          client:read_stop()
          if event.waiting then
            f.waiters[#f.waiters + 1] = client
          else
            client:close()
          end
        end
      elseif not client:is_closing() then
        client:close()
      end
    end)
  end))
  function f.release()
    for _, client in ipairs(f.waiters) do
      if not client:is_closing() then
        client:write("continue\n", function()
          if not client:is_closing() then
            client:close()
          end
        end)
      end
    end
    f.waiters = {}
  end
  if backend == "codex" then
    fixture =
      assert(vim.api.nvim_get_runtime_file("tests/fixtures/ai/conversation_codex.py", false)[1])
    local text = table.concat(vim.fn.readfile(fixture, "b"), "\n")
    text = text
      :gsub('CASE = "answer"', function()
        return "CASE = " .. vim.json.encode(case or "edit")
      end)
      :gsub("AUDIT_PORT = 0", "AUDIT_PORT = " .. server:getsockname().port)
    vim.fn.writefile(vim.split(text, "\n", { plain = true }), f.peer, "b")
    f.auth_file = root .. "/synthetic auth 二.json"
    vim.fn.writefile({ '{"OPENAI_API_KEY":"synthetic-key"}' }, f.auth_file)
    assert(vim.uv.fs_chmod(f.auth_file, 384))
  end
  local factory, system = require("ai.conversation_controller"), vim.system
  local create = factory.new
  factory.new = function(config)
    f.configuration = vim.deepcopy(config)
    local owner, reason = create(config)
    if owner then
      f.owners[#f.owners + 1] = owner
    end
    return owner, reason
  end
  vim.system = function(command, ...)
    for index, part in ipairs(command) do
      if part == "--proposal" then
        f.proposals[vim.fs.dirname(command[index + 1])] = true
      end
    end
    return system(command, ...)
  end
  local configured = {
    staged = vim.tbl_deep_extend("force", {
      enabled = true,
      root = f.project,
      model = "fixture/model",
      opencode = f.peer,
      provider = {
        fixture = { options = { testCase = "edit", auditPort = server:getsockname().port } },
      },
    }, backend == "codex" and {} or settings or {}),
  }
  if backend == "codex" then
    configured.chat = vim.tbl_extend("force", {
      backend = "codex",
      model = "openai/gpt-5.4",
      codex = f.peer,
      auth_file = f.auth_file,
      root = f.project,
    }, settings or {})
    configured.staged.opencode = root .. "/missing-opencode"
    configured.staged.auth_file = root .. "/must-not-inherit-auth.json"
  end
  f.runtime = require("draft").setup(configured)
  function f.owner()
    return f.owners[#f.owners]
  end
  function f.snapshot()
    return f.owner():snapshot()
  end
  function f.buffer(kind)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == kind then
        return buf
      end
    end
  end
  function f.text(kind)
    return table.concat(
      vim.api.nvim_buf_get_lines(assert(f.buffer(kind or "draft-chat")), 0, -1, false),
      "\n"
    )
  end
  function f.compose(value)
    vim.api.nvim_buf_set_lines(assert(f.buffer("draft-chat-input")), 0, -1, false, { value })
  end
  function f.phase(value)
    assert(
      vim.wait(12000, function()
        return f.snapshot().phase == value
      end, 10),
      vim.inspect(f.snapshot())
    )
  end
  function f.rendered(value)
    assert(
      vim.wait(1000, function()
        return f.text():find(value, 1, true) ~= nil
      end, 10),
      f.text()
    )
  end
  function f.disk(index)
    return vim.fn.readfile(f.files[index])[1]
  end
  function f.key(lhs)
    return assert(vim.fn.maparg(lhs, "n", false, true).callback)
  end
  function f.cleanup()
    f.release()
    local owner = f.owner()
    if owner and owner:snapshot().phase ~= "closed" then
      owner:dispatch({ kind = "close" }, owner:snapshot().view_revision)
      vim.wait(12000, function()
        return owner:snapshot().phase == "closed"
      end, 10)
    end
    f.runtime:shutdown()
    factory.new, vim.system = create, system
    for _, client in ipairs(f.clients) do
      if not client:is_closing() then
        client:close()
      end
    end
    server:close()
    for directory in pairs(f.proposals) do
      assert(directory:match("^/tmp/nvim%-ai%-staged%-[^/]+$"))
      vim.fn.delete(directory, "rf")
    end
  end
  local escaped = vim.tbl_map(vim.fn.fnameescape, f.files)
  vim.cmd("NvimAIChat " .. table.concat(escaped, " "))
  return f
end
