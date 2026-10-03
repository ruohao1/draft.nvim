-- Recovery through public chat actions, the production controller and confined ACP.
vim.o.columns, vim.o.lines = 140, 42
local root = assert(vim.uv.fs_mkdtemp("/tmp/draft-chat-recovery-XXXXXX"))
local make =
  dofile(assert(vim.api.nvim_get_runtime_file("tests/fixtures/ai/chat_approval.lua", false)[1]))
local f
local ok, reason = xpcall(function()
  local auth = root .. "/auth.json"
  f = make(root, {
    auth_file = auth,
    provider = { fixture = { options = { testCase = "answer" } } },
  })
  f.compose("Retry this question once credentials exist.")
  vim.cmd("NvimAIChatSend")
  f.phase("failed")
  assert(f.snapshot().retry_safe and not f.snapshot().recovery_required)
  local conversation = f.snapshot().conversation_id
  assert(#f.audit == 0, "missing credentials must fail before starting OpenCode")
  vim.fn.writefile(
    { vim.json.encode({ fixture = { type = "api", key = "synthetic-only" } }) },
    auth
  )
  assert(vim.uv.fs_chmod(auth, 384))
  local before = f.snapshot()
  assert(
    not f.owner():dispatch({ kind = "retry", text = "stale request" }, before.view_revision - 1)
  )
  f.compose("Keep this refused draft.")
  local source = assert(vim.fn.bufnr(f.files[1]))
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "unsaved source edit" })
  assert(not f.runtime:chat_retry(), "Retry must revalidate dirty selected buffers")
  assert(f.snapshot().turn_id == 1 and #f.audit == 0)
  assert(f.text("draft-chat-input") == "Keep this refused draft.")
  assert(vim.api.nvim_buf_get_lines(source, 0, -1, false)[1] == "unsaved source edit")
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "original text" })
  vim.bo[source].modified = false
  f.compose("")
  local sent, why = f.runtime:chat_retry()
  assert(sent, why)
  assert(not f.runtime:chat_retry(), "A second Retry cannot overlap the new turn")
  f.compose("Keep this later draft.")
  f.phase("idle")
  assert(f.snapshot().conversation_id == conversation and f.snapshot().turn_id == 2)
  assert(f.text("draft-chat-input") == "Keep this later draft.")
  local prompts = 0
  for _, event in ipairs(f.audit) do
    if event.method == "session/prompt" then
      prompts = prompts + 1
      assert(
        vim
          .inspect(event.params.prompt)
          :find("Retry this question once credentials exist.", 1, true)
      )
    end
  end
  assert(prompts == 1, "explicit safe Retry must submit exactly one prompt")
  assert(f.disk(1) == "original text")
  assert(vim.uv.fs_unlink(auth))
  f.compose("Second question with temporarily missing credentials.")
  vim.cmd("NvimAIChatSend")
  f.phase("failed")
  assert(f.snapshot().retry_safe and f.snapshot().turn_id == 3)
  vim.fn.writefile(
    { vim.json.encode({ fixture = { type = "api", key = "synthetic-only" } }) },
    auth
  )
  assert(vim.uv.fs_chmod(auth, 384))
  f.compose("Use this explicitly revised question.")
  assert(f.runtime:chat_retry())
  assert(f.text("draft-chat-input") == "", "Retry consumes an explicitly revised draft")
  f.phase("idle")
  assert(f.snapshot().turn_id == 4 and f.snapshot().conversation_id == conversation)
  local sessions, resumes = 0, 0
  prompts = 0
  for _, event in ipairs(f.audit) do
    sessions = sessions + (event.method == "session/new" and 1 or 0)
    resumes = resumes + (event.method == "session/resume" and 1 or 0)
    if event.method == "session/prompt" then
      prompts = prompts + 1
      if prompts == 2 then
        assert(
          vim.inspect(event.params.prompt):find("Use this explicitly revised question.", 1, true)
        )
      end
    end
  end
  assert(sessions == 1 and resumes == 1 and prompts == 2)
  vim.cmd("NvimAIChatClose")
  f.phase("closed")
  print("ok - safe Retry revalidates sources, submits once and resumes only the existing session")
  f.cleanup()
  f = nil

  local directory = root .. "/unsafe"
  assert(vim.uv.fs_mkdir(directory, 448))
  f = make(directory, { provider = { fixture = { options = { testCase = "wrong-version" } } } })
  f.compose("Never replay this refused request.")
  vim.cmd("NvimAIChatSend")
  f.phase("failed")
  assert(not f.snapshot().retry_safe and f.snapshot().recovery_required)
  local failed = f.snapshot()
  f.compose("Keep this refused draft too.")
  assert(not f.runtime:chat_retry())
  assert(f.snapshot().turn_id == failed.turn_id)
  assert(f.text("draft-chat-input") == "Keep this refused draft too.")
  f.compose("")
  vim.cmd("NvimAIChatClose")
  f.phase("closed")
  vim.cmd("NvimAIChatNew")
  local fresh = f.snapshot()
  assert(fresh.phase == "idle" and fresh.turn_id == 0 and #fresh.turns == 0)
  assert(fresh.conversation_id ~= failed.conversation_id and fresh.review == nil)
  assert(#fresh.rounds == 0 and f.text("draft-chat-input") == "")
  for _, event in ipairs(f.audit) do
    assert(event.method ~= "session/prompt" and event.method ~= "session/new")
  end
  vim.cmd("NvimAIChatClose")
  f.phase("closed")
  print("ok - unsafe failure stays fenced; explicit New has no old context or automatic prompt")
end, debug.traceback)
if f then
  f.cleanup()
end
vim.fn.delete(root, "rf")
assert(ok, reason)
