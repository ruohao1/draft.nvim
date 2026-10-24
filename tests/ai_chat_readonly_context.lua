-- Public snapshots travel through real controllers and confined peers on both backends.
vim.o.columns, vim.o.lines = 140, 42
local root = assert(vim.uv.fs_mkdtemp("/tmp/draft-chat-context-XXXXXX"))
local make =
  dofile(assert(vim.api.nvim_get_runtime_file("tests/fixtures/ai/chat_approval.lua", false)[1]))
vim.diagnostic.config({ signs = false, virtual_text = false, underline = false })
-- Same Neovim headless redraw limitation as ai_chat_diagnostics; real TUI keeps it.
vim.api.nvim_del_augroup_by_name("nvim.diagnostic.status")
local ns = vim.api.nvim_create_namespace("readonly-context-integration")
local spawn, fs_open = vim.uv.spawn, vim.uv.fs_open
local launches, auth_reads = 0, 0
vim.uv.spawn = function(path, options, callback)
  for _, arg in ipairs(options.args or {}) do
    if arg:match("/nvim%-ai%-conversation%.py$") then
      launches = launches + 1
    end
  end
  return spawn(path, options, callback)
end
vim.uv.fs_open = function(path, ...)
  if tostring(path):find("synthetic auth", 1, true) then
    auth_reads = auth_reads + 1
  end
  return fs_open(path, ...)
end
local f
local ok, reason = xpcall(function()
  for _, backend in ipairs({ "opencode", "codex" }) do
    local directory = root .. "/" .. backend
    assert(vim.uv.fs_mkdir(directory, 448))
    f = make(directory, nil, backend, "edit")
    local started, authenticated = launches, auth_reads
    local function source(buf)
      f.runtime:chat_hide()
      vim.api.nvim_set_current_buf(buf)
    end
    local context = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(context, f.project .. "/context-only.txt")
    source(context)
    vim.api.nvim_buf_set_lines(context, 0, -1, false, { "unsaved-readonly-marker" })
    vim.diagnostic.set(ns, context, {
      { lnum = 0, col = 2, severity = 2, message = "cached-only-diagnostic-marker" },
    })
    f.compose("Edit selected files using this context.")
    assert(f.runtime:chat_attach())
    source(context)
    assert(f.runtime:chat_diagnostics())
    local visible = f.text("draft-chat-input")
    assert(visible:find("unsaved-readonly-marker", 1, true))
    assert(visible:find("cached-only-diagnostic-marker", 1, true))
    assert(f.snapshot().turn_id == 0 and #f.audit == 0)
    assert(launches == started and auth_reads == authenticated)
    assert(vim.deep_equal(f.snapshot().selection, f.paths))
    assert(vim.bo[context].modified and vim.uv.fs_stat(f.project .. "/context-only.txt") == nil)

    local editable = assert(vim.fn.bufnr(f.files[1]))
    vim.api.nvim_buf_set_lines(editable, 0, -1, false, { "dirty editable source" })
    assert(not f.runtime:chat_send(), "Dirty editable buffers must still refuse Send")
    assert(f.text("draft-chat-input") == visible and launches == started and #f.audit == 0)
    vim.api.nvim_buf_set_lines(editable, 0, -1, false, { "original text" })
    vim.bo[editable].modified = false
    assert(f.runtime:chat_send())
    assert(f.text("draft-chat-input") == "")
    assert(f.snapshot().phase == "starting", "Draft preparation begins during an active turn")
    source(context)
    vim.api.nvim_buf_set_lines(context, 0, -1, false, { "newly prepared snapshot" })
    f.compose("Follow up on the pending proposal.")
    assert(f.runtime:chat_attach())
    local next_draft = f.text("draft-chat-input")
    assert(not next_draft:find("unsaved-readonly-marker", 1, true))
    f.phase("review")
    assert(f.text("draft-chat-input") == next_draft)
    local function prompts()
      local values = {}
      for _, event in ipairs(f.audit) do
        if event.method == "session/prompt" then
          values[#values + 1] = event.params.prompt[#event.params.prompt].text
        elseif event.method == "turn/start" then
          values[#values + 1] = event.params.input[1].text
        elseif event.editable_paths then
          assert(vim.deep_equal(event.editable_paths, f.paths))
        elseif event.workspace then
          local paths = vim.tbl_keys(event.workspace)
          table.sort(paths)
          assert(vim.deep_equal(paths, f.paths))
        end
      end
      return values
    end
    local sent = prompts()
    assert(#sent == 1)
    if backend == "opencode" then
      assert(sent[1] == visible)
    else
      assert(vim.endswith(sent[1], "\n" .. visible))
    end
    assert(f.snapshot().turns[1].prompt == visible)
    for _, file in ipairs(f.snapshot().review.files) do
      assert(vim.list_contains(f.paths, file.path))
    end
    assert(f.runtime:chat_send(), "Explicit Send follows up on a pending proposal")
    f.phase("review")
    sent = prompts()
    assert(#sent == 2 and vim.endswith(sent[2], next_draft))
    assert(not sent[2]:find("unsaved-readonly-marker", 1, true))
    assert(not sent[2]:find("cached-only-diagnostic-marker", 1, true))
    assert(f.snapshot().turns[2].prompt == next_draft)
    assert(vim.deep_equal(f.snapshot().selection, f.paths))
    for i = 1, #f.paths do
      assert(f.disk(i) == "original text")
    end
    assert(vim.uv.fs_stat(f.project .. "/context-only.txt") == nil)
    assert(vim.bo[context].modified)
    f.cleanup()
    f = nil
    print(
      "ok - " .. backend .. " keeps context passive, message-only and outside editable authority"
    )
  end
end, debug.traceback)
if f then
  f.cleanup()
end
vim.uv.spawn, vim.uv.fs_open = spawn, fs_open
vim.fn.delete(root, "rf")
assert(ok, reason)
