-- Public runtime with real identity, state, context, review and session modules.
-- Only provider health/processes and user-interface choices are simulated.
local function eq(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    (label or "mismatch")
      .. "\nexpected: "
      .. vim.inspect(expected)
      .. "\nactual: "
      .. vim.inspect(actual)
  )
end
local uv, ai = vim.uv, require("ai")
local base = assert(uv.fs_mkdtemp("/tmp/ai-runtime-XXXXXX"))
assert(uv.fs_chmod(base, 448))
local old_cwd, old_runtime, old_state =
  vim.fn.getcwd(), vim.env.XDG_RUNTIME_DIR, vim.env.XDG_STATE_HOME
local old_select, old_input = vim.ui.select, vim.ui.input
local cleanups, sequence = {}, 0
local function directory(path)
  vim.fn.mkdir(path, "p", 448)
  assert(uv.fs_chmod(path, 448))
  return path
end
local function fixture(config)
  config = config or {}
  sequence = sequence + 1
  local f = {
    base = directory(base .. "/" .. sequence),
    invocations = {},
    pasted = {},
    notices = {},
    selections = {},
  }
  f.root = directory(f.base .. "/repo")
  f.home = directory(f.base .. "/home")
  f.data_home = directory(f.home .. "/data")
  vim.env.XDG_RUNTIME_DIR = directory(f.base .. "/run")
  vim.env.XDG_STATE_HOME = directory(f.base .. "/state")
  eq(vim.system({ "/usr/bin/git", "init", "-q", f.root }):wait().code, 0, "private Git fixture")
  vim.fn.writefile({ "original text", "second line" }, f.root .. "/demo.lua")
  eq(
    vim.system({ "/usr/bin/git", "-C", f.root, "add", "demo.lua" }):wait().code,
    0,
    "fixture is Git-visible"
  )
  vim.api.nvim_set_current_dir(f.root)
  f.buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(f.buf, f.root .. "/demo.lua")
  vim.api.nvim_set_current_buf(f.buf)
  vim.cmd.edit()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local uuid = "11111111-1111-4111-8111-111111111111"
  f.transport = {
    discover = function()
      return f.panes or {}
    end,
    owned_panes = function()
      return f.panes or {}
    end,
    create = function(_, _, invocation)
      f.invocations[#f.invocations + 1] = invocation
      return "term:10:20"
    end,
    respawn = function(_, _, invocation)
      f.invocations[#f.invocations + 1] = invocation
      return true
    end,
    tag = function(_, pane, metadata)
      f.panes = { vim.tbl_extend("force", { pane = pane }, metadata) }
      return true
    end,
    paste = function(_, _, text)
      f.pasted[#f.pasted + 1] = text
      return true
    end,
    focus = function()
      f.focused = true
      return true
    end,
    close = function()
      f.panes = {}
      return true
    end,
  }
  local backend = {
    new_session = function()
      return { backend = "claude", session = uuid }
    end,
    resume_session = function()
      return { backend = "claude", session = uuid }
    end,
    session_reference = function(_, launch)
      return launch.session
    end,
    capabilities = function()
      return { busy = true, completion = true, approval = true, exact_session = true }
    end,
    format_context = function(_, context)
      f.last_context = context.context_file
      if context.kind == "selection" then
        return "Use exact selection at " .. context.context_file .. ": "
      end
      return "Regarding " .. context.path .. ":" .. context.line .. ":" .. context.column .. ": "
    end,
    suspend = function()
      return { signal = 1, timeout = 2000 }
    end,
    stop = function()
      return { signal = 15, timeout = 2000 }
    end,
  }
  local codex = vim.tbl_extend("force", {}, backend, {
    new_session = function()
      return { backend = "codex", session = "last" }
    end,
    resume_session = function()
      return { backend = "codex", session = "last" }
    end,
    capabilities = function()
      return { busy = false, completion = false, approval = false, exact_session = false }
    end,
  })
  f.adapter = backend
  f.options = {
    staged = {
      settings_directory = f.base .. "/preferences",
      enabled = false,
      review_mode = "native",
    },
    home = f.home,
    data_home = f.data_home,
    transport = f.transport,
    registry = {
      names = function()
        return { "codex", "claude", "opencode" }
      end,
      get = function(_, name)
        return ({ claude = backend, codex = codex })[name]
      end,
      health = function(_, name)
        local installed = name == "claude" or (config.codex and name == "codex")
        return {
          installed = installed,
          executable = "/usr/bin/true",
          version = "1.0.0",
          auth = config.auth or "authenticated",
          error = installed and "" or "not installed",
          capabilities = backend:capabilities(),
        }
      end,
      shutdown = function()
        f.registry_stopped = true
        return true
      end,
    },
    sandbox = {
      prepare = function(options)
        assert(
          uv.fs_lstat(options.control_socket),
          "scope socket is ready before any native launch"
        )
        f.event_file, f.control_socket = options.event_file, options.control_socket
        f.control_token = options.control_token
        local path = assert(options.write_manifest({ token = options.token }))
        return {
          token = options.token,
          path = path,
          argv = { "simulated-provider" },
          review_id = options.review_id,
          writable = options.review_id ~= nil,
        }
      end,
    },
    select = function(items, options, callback)
      f.selections[#f.selections + 1] = items
      for _, item in ipairs(items) do
        if item.name == "claude" then
          callback(item)
          return
        end
      end
      callback(nil)
    end,
    confirm = function()
      return true
    end,
    notify = function(message)
      f.notices[#f.notices + 1] = message
    end,
  }
  if config.configure then
    config.configure(f)
  end
  f.runtime = assert(ai.setup(f.options))
  cleanups[#cleanups + 1] = function()
    f.runtime:shutdown()
  end
  return f
end

local function staging_fixture(configure)
  local f = fixture({
    configure = function(value)
      local peer = value.base .. "/opencode"
      local script =
        assert(vim.api.nvim_get_runtime_file("tests/fixtures/ai/staged_acp.py", false)[1])
      vim.fn.writefile(vim.fn.readfile(script, "b"), peer, "b")
      assert(uv.fs_chmod(peer, 448))
      assert(uv.fs_chmod(value.root .. "/demo.lua", 420))
      value.options.staged = vim.tbl_extend("force", value.options.staged, {
        enabled = true,
        model = "fixture/model",
        opencode = peer,
        root = value.root,
      })
      if configure then
        configure(value)
      end
    end,
  })
  cleanups[#cleanups + 1] = function()
    local staged = require("ai.staged")
    staged.cancel()
    vim.wait(6000, function()
      local phase = staged.status().phase
      return phase ~= "preparing" and phase ~= "refining"
    end, 10)
    local proposal = staged.status().proposal
    if proposal and proposal:match("^/tmp/nvim%-ai%-staged%-[^/]+/proposal%.json$") then
      vim.fn.delete(vim.fs.dirname(proposal), "rf")
    end
  end
  return f
end

local function await_staged()
  local staged = require("ai.staged")
  assert(vim.wait(6000, function()
    return staged.status().phase ~= "preparing"
  end, 10))
  eq(staged.status().phase, "review_ready", "fixture reached actual frozen ACP review")
  local proposal = staged.status().proposal
  assert(proposal:match("^/tmp/nvim%-ai%-staged%-[^/]+/proposal%.json$"))
  cleanups[#cleanups + 1] = function()
    -- Multi-file cancellation retains evidence; keep this exact fixture path
    -- even after a later ai.setup() replaces the module's current turn.
    vim.fn.delete(vim.fs.dirname(proposal), "rf")
  end
end

local ok, err = xpcall(function()
  do
    local f = staging_fixture()
    assert(f.runtime:chat_open({ f.root .. "/demo.lua" }))
    assert(f.runtime:chat_hide())
    assert(not f.runtime:open(), "hidden idle chat excludes native activity")
    assert(not f.runtime:shutdown(), "hidden chat still owns its runtime lease")
    vim.cmd("NvimAIStage TEST:approve")
    assert(not require("ai.staged").busy(), "hidden chat excludes standalone staging")
    assert(f.runtime:chat_close())
    assert(
      vim.wait(3000, function()
        return f.runtime:shutdown() == true
      end, 10),
      "only confirmed close permits runtime shutdown"
    )
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      assert(
        not vim.bo[buf].filetype:match("^draft%-chat"),
        "shutdown disposes closed chat buffers"
      )
    end
    eq(#f.invocations, 0, "passive chat and cleanup never launch a native provider")
  end
  do
    local f = fixture()
    local config = {
      root = f.root,
      selection = { "demo.lua" },
      model = "fixture/model",
      opencode = "/usr/bin/true",
    }
    local owner = assert(f.runtime:conversation(config))
    eq(owner:snapshot().phase, "idle", "runtime conversation construction remains passive")
    assert(not f.runtime:conversation(config), "A second owner must not acquire the runtime lease")
    assert(not f.runtime:open(), "An idle conversation still excludes native activity")
    assert(not f.runtime:shutdown(), "Shutdown cannot discard an unclosed conversation lease")
    assert(owner:dispatch({ kind = "close" }, owner:snapshot().view_revision))
    assert(vim.wait(3000, function()
      return owner:snapshot().phase == "closed"
    end, 10))
    assert(f.runtime:open(), "Confirmed close releases the conversation lease")
    assert(not f.runtime:conversation(config), "An active native pane excludes a conversation")
    f.runtime:shutdown()
  end
  do
    local f = fixture({
      configure = function(value)
        value.options.select = function(items, _, callback)
          value.pick, value.choice = callback, items[2]
        end
      end,
    })
    assert(f.runtime:prompt("n"))
    local owner = assert(f.runtime:conversation({
      root = f.root,
      selection = { "demo.lua" },
      model = "fixture/model",
      opencode = "/usr/bin/true",
    }))
    assert(owner:dispatch({ kind = "close" }, owner:snapshot().view_revision))
    assert(vim.wait(3000, function()
      return owner:snapshot().phase == "closed"
    end, 10))
    f.pick(f.choice)
    eq(#f.invocations, 0, "a picker predating the conversation cannot launch after it closes")
    assert(f.runtime:shutdown())
  end
  do
    local f = staging_fixture()
    local staged = require("ai.staged")
    assert(f.runtime:native_prompt("n"))
    assert(f.invocations[1].writable, "native fixture has write access")
    -- Session-only preference changes must not disconnect the runtime guard.
    staged.setup(f.options.staged)
    local inputs, scans = 0, 0
    vim.ui.input = function(_, callback)
      inputs = inputs + 1
      callback("TEST:approve")
    end
    local picker = require("ai.staged_picker")
    local original_open = picker.open
    picker.open = function()
      scans = scans + 1
      return function() end
    end
    cleanups[#cleanups + 1] = function()
      picker.open = original_open
    end
    for _, native in ipairs({ "live", "unresolved" }) do
      if native == "unresolved" then
        assert(f.runtime:close())
      end
      for _, command in ipairs({
        "NvimAIStage TEST:approve",
        "NvimAIStage",
        "NvimAIStageFiles demo.lua",
        "NvimAIStageFiles",
      }) do
        vim.api.nvim_set_current_buf(f.buf)
        vim.cmd(command)
        assert(not staged.busy(), command .. " must refuse " .. native .. " native activity")
      end
    end
    eq(inputs, 0, "native activity is rejected before instruction dialogs")
    eq(scans, 0, "native activity is rejected before file discovery")
    picker.open, vim.ui.input = original_open, old_input
    assert(f.runtime:review({ bang = true }))
    vim.cmd("NvimAIStage TEST:approve")
    await_staged()
    local invocations = #f.invocations
    assert(not f.runtime:open(), "native open cannot overlap frozen staging")
    assert(not f.runtime:backend("claude"), "native switching cannot overlap frozen staging")
    assert(not f.runtime:native_prompt("n"))
    eq(#f.invocations, invocations, "no native launch while staged review is active")
    staged.cancel()
    assert(f.runtime:shutdown())
  end
  for _, operation in ipairs({ "open", "backend" }) do
    local f = staging_fixture(function(value)
      value.options.select = function(items, _, callback)
        value.pick, value.choice = callback, items[2]
      end
    end)
    assert(f.runtime[operation](f))
    assert(f.pick and f.choice, "native backend choice is still pending")
    vim.cmd("NvimAIStage TEST:approve")
    await_staged()
    require("ai.staged").cancel()
    f.pick(f.choice)
    eq(#f.invocations, 0, "late native choice stays invalid even after staging has finished")
    assert(f.runtime:shutdown())
  end
  do
    local f = staging_fixture(function(value)
      local create = value.transport.create
      value.transport.create = function(...)
        vim.cmd("NvimAIStage TEST:approve")
        assert(not require("ai.staged").busy(), "reentrant staging cannot overlap native launch")
        return create(...)
      end
    end)
    assert(f.runtime:open())
    assert(f.runtime:shutdown())
  end
  do
    local f = staging_fixture()
    local staged, submit = require("ai.staged")
    vim.ui.input = function(_, callback)
      submit = callback
    end
    vim.cmd("NvimAIStage")
    assert(submit and staged.busy(), "staged instruction dialog owns the workflow")
    assert(not f.runtime:conversation({
      root = f.root,
      selection = { "demo.lua" },
      model = "fixture/model",
      opencode = "/usr/bin/true",
    }), "staged dialog excludes conversation")
    for _, operation in ipairs({ "open", "backend", "native_prompt" }) do
      assert(not f.runtime[operation](f), "native activity waits for the instruction dialog")
    end
    staged.cancel()
    assert(f.runtime:open(), "cancelling staging releases the native workflow")
    submit("TEST:approve")
    assert(not staged.busy(), "cancelled input cannot stage after native launch")
    vim.ui.input = old_input
    assert(f.runtime:shutdown())
  end
  for _, cancel in ipairs({ false, true }) do
    local f = staging_fixture()
    local staged, reads = require("ai.staged"), 0
    local file = f.root .. "/unloaded.lua"
    vim.fn.writefile({ "original text" }, file)
    assert(uv.fs_chmod(file, 420))
    local hook = vim.api.nvim_create_autocmd("BufReadPost", {
      pattern = file,
      callback = function()
        reads = reads + 1
        assert(staged.busy(), "source capture reserves the staged workflow")
        assert(not f.runtime:open(), "read hooks cannot launch native work during capture")
        if cancel then
          staged.cancel()
        end
      end,
    })
    staged.start("TEST:approve", { file })
    vim.api.nvim_del_autocmd(hook)
    eq(reads, 1, "an unloaded selected file exercised its real read hook")
    if cancel then
      assert(not staged.busy(), "cancelled source capture does not continue to launch")
    else
      await_staged()
      staged.cancel()
    end
    eq(#f.invocations, 0, "source capture did not overlap a native launch")
    assert(f.runtime:shutdown())
  end

  local f = fixture()
  eq(#f.invocations, 0, "setup starts no provider process")
  assert(f.runtime:prompt("n"))
  eq(#f.invocations, 1, "first prompt launches directly writable without a preliminary TUI")
  assert(
    f.invocations[1].writable and f.invocations[1].review_id,
    "prompt has an exact review before launch"
  )
  eq(
    f.pasted,
    { "Regarding demo.lua:1:1: " },
    "normal prompt contains only a relative location and no Enter"
  )
  assert(f.focused, "successful prompt focuses the managed TUI")
  assert(
    table.concat(f.notices, "\n"):find("not submitted; :NvimAIReview after edits", 1, true),
    "prepared context explains explicit review without automatic submission"
  )
  eq(#vim.api.nvim_list_tabpages(), 1, "preparing context does not open review automatically")
  eq(#f.selections[1], 3, "unavailable backends remain visible in picker")
  local first_id = f.invocations[1].review_id
  assert(f.runtime:prompt("n"))
  eq(#f.invocations, 1, "existing writable batch is reused")
  eq(#f.pasted, 2, "second explicit prompt pastes once")
  eq(#vim.tbl_filter(function(message)
    return message:find("not submitted; :NvimAIReview after edits", 1, true) ~= nil
  end, f.notices), 1, "review guidance is shown once per delivered batch")
  assert(f.runtime:close())
  eq(f.panes, {}, "explicit close stops the owned process")
  assert(f.runtime:shutdown())

  do
    f = fixture({
      configure = function(value)
        value.options.staged.review_mode = "pre_write"
      end,
    })
    for _, backend in ipairs({ "codex", "claude" }) do
      local selected, why = f.runtime:backend(backend)
      assert(not selected and why:find("does not support pre-write", 1, true))
    end
    eq(#f.invocations, 0, "unsupported staged backends never launch natively")
    eq(f.runtime:show_status().settings.review_mode, "pre_write")
    assert(not f.runtime:prompt("x"), "pre-write selection does not silently send the whole file")
    vim.cmd("NvimAINativePrompt")
    eq(#f.invocations, 1)
    vim.cmd("NvimAIReviewMode native")
    eq(require("ai.staged").review_mode(), "pre_write", "mode change refuses a live native pane")
    assert(not f.runtime:prompt("n"), "pre-write staging refuses a live native companion")
    assert(f.runtime:close())
    local routed, why = f.runtime:prompt("n")
    assert(
      not routed and why:find("does not support pre-write", 1, true),
      "remembered Claude is not silently switched"
    )
    assert(f.runtime:backend("opencode"))
    local ready, review_error = f.runtime:prompt("n")
    assert(not ready and review_error:find("Resolve the native after-write review", 1, true))
    assert(f.runtime:review({ bang = true }), "retire the native review before independent staging")
    assert(f.runtime:prompt("n")) -- Disabled staging reports setup, not native fallback.
    eq(#f.invocations, 1, "disabled staging cannot restore native writes")
    assert(not require("ai.staged").busy(), "refused staging leaves no phantom prompt dialog")
    assert(f.runtime:shutdown())
  end
  for _, invalid in ipairs({ "unknown", false, {} }) do
    f = fixture({
      configure = function(value)
        value.options.staged.review_mode = invalid
      end,
    })
    assert(not f.runtime:prompt("n"), "invalid review policy never falls back to native")
    assert(not f.runtime:backend("codex"))
    eq(#f.invocations, 0, "invalid policy launches nothing")
    eq(require("ai.staged").status().settings.review_mode, "unavailable")
    assert(f.runtime:shutdown())
  end
  do
    f = fixture()
    local select, choose_mode = vim.ui.select
    vim.ui.select = function(_, _, callback)
      choose_mode = callback
    end
    vim.cmd("NvimAIReviewMode pre_write")
    assert(not f.runtime:open(), "native opening waits for the review-mode dialog")
    choose_mode("pre_write")
    eq(
      require("ai.staged").review_mode(),
      "pre_write",
      "a blocked native opening does not invalidate the active mode dialog"
    )
    vim.ui.select = select
    assert(f.runtime:shutdown())
  end
  for _, switch_back in ipairs({ false, true }) do
    f = fixture({
      configure = function(value)
        value.options.select = function(items, _, callback)
          value.pick, value.choice = callback, items[2]
        end
      end,
    })
    assert(f.runtime:prompt("n"))
    local staging = require("ai.staged")
    staging.setup(vim.tbl_extend("force", f.options.staged, { review_mode = "pre_write" }))
    if switch_back then
      staging.setup(f.options.staged)
    end
    f.pick(f.choice)
    eq(#f.invocations, 0, "old native picker cannot launch after review-policy changes")
    assert(f.runtime:shutdown())
  end
  do
    f = fixture({
      configure = function(value)
        value.options.staged.review_mode = "pre_write"
        value.options.select = function(items, _, callback)
          value.pick, value.choice = callback, items[1]
        end
      end,
    })
    assert(f.runtime:backend())
    require("ai.staged").setup(
      vim.tbl_extend("force", f.options.staged, { review_mode = "native" })
    )
    f.pick(f.choice)
    eq(#f.invocations, 0, "stale staged backend choice cannot start native work")
    assert(f.runtime:shutdown())
  end
  do
    -- The native notice can be undisplayed when ruler/showcmd consume every
    -- cell. Keep the success hint eligible for a later explicit prompt.
    local notice = require("ai.notice")
    local original_info, displayed, attempts = notice.info, false, 0
    cleanups[#cleanups + 1] = function()
      notice.info = original_info
    end
    notice.info = function()
      attempts = attempts + 1
      return displayed
    end
    f = fixture()
    assert(f.runtime:prompt("n"))
    eq(attempts, 1, "zero-space prompt attempts informational feedback once")
    displayed = true
    assert(f.runtime:prompt("n"))
    eq(attempts, 2, "later explicit prompt retries only the undisplayed hint")
    assert(f.runtime:prompt("n"))
    eq(attempts, 2, "displayed success hint stays once per review")
    eq(#f.pasted, 3, "context delivery remains exactly once per explicit prompt")
    assert(f.runtime:close())
    assert(f.runtime:shutdown())
    notice.info = original_info
  end
  for _, auth in ipairs({ "unknown", "unsupported" }) do
    f = fixture({ auth = auth })
    assert(f.runtime:prompt("n"), "locally unverified authentication may use the native TUI")
    assert(
      f.selections[1][2].enabled,
      "unverified authentication is a warning, not a disabled backend"
    )
    assert(f.runtime:shutdown())
  end
  f = fixture({ auth = "unauthenticated" })
  assert(not f.runtime:prompt("n"), "explicit authentication failure disables launch")
  eq(#f.invocations, 0, "disabled backend never launches or initiates login")
  assert(f.runtime:shutdown())
  assert(f.registry_stopped, "runtime owns registry shutdown")

  f = fixture()
  assert(f.runtime:open())
  eq(f.invocations[1].writable, false, "explicit open starts read-only")
  eq(f.runtime:compact(), "AI:L open", "runtime publishes session status")
  assert(f.runtime:prompt("n"))
  eq(#f.invocations, 2, "prompt transitions the existing pane to writable")
  eq(f.invocations[2].writable, true, "existing pane receives a review-backed manifest")
  assert(f.runtime:open())
  eq(#f.invocations, 2, "reopen focuses without relaunching")
  assert(f.runtime:shutdown())

  f = fixture({
    configure = function(value)
      value.options.select = function(items, _, callback)
        value.pick, value.choice = callback, items[2]
      end
    end,
  })
  assert(f.runtime:prompt("n"))
  assert(f.runtime:close())
  f.pick(f.choice)
  eq(#f.invocations, 0, "closing cancels a pending prompt picker")
  assert(f.runtime:shutdown())

  f = fixture({
    configure = function(value)
      value.options.select = function(items, _, callback)
        value.pick, value.choice = callback, items[2]
      end
    end,
  })
  vim.cmd.NvimAIPrompt()
  vim.api.nvim_buf_set_lines(f.buf, 0, 1, false, { "changed while picking" })
  f.pick(f.choice)
  assert(
    vim.wait(500, function()
      return table.concat(f.notices, "\n"):find("context changed while choosing", 1, true) ~= nil
    end),
    "asynchronous command failures are reported after the picker returns"
  )
  eq(#f.invocations, 0, "stale asynchronous context never launches")
  assert(f.runtime:shutdown())

  f = fixture()
  vim.fn.setpos("'<", { 0, 2, 1, 0 })
  vim.fn.setpos("'>", { 0, 2, 4, 0 })
  vim.cmd.normal({ args = { "gg0vl" }, bang = true })
  assert(f.runtime:prompt("x"))
  vim.cmd.normal({ args = { "\27" }, bang = true })
  eq(
    table.concat(vim.fn.readfile(f.last_context, "b"), "\n"),
    "or",
    "live selection wins over stale visual marks"
  )
  assert(f.runtime:shutdown())

  f = fixture()
  vim.cmd.normal({ args = { "gg0vl" }, bang = true })
  assert(f.runtime:prompt("x"))
  local delivered_context = f.last_context
  local formatter = f.adapter.format_context
  f.adapter.format_context = function()
    error("PRIVATE_FORMATTER_ERROR")
  end
  assert(not f.runtime:prompt("x"))
  assert(
    uv.fs_lstat(delivered_context),
    "failed replacement formatting retains the delivered selection"
  )
  f.adapter.format_context = formatter
  f.transport.paste = function()
    return nil, "simulated replacement paste failure"
  end
  assert(not f.runtime:prompt("x"))
  assert(uv.fs_lstat(delivered_context), "failed replacement paste retains the delivered selection")
  assert(not uv.fs_lstat(f.last_context), "failed replacement paste removes only the new selection")
  vim.cmd.normal({ args = { "\27" }, bang = true })
  assert(f.runtime:shutdown())

  f = fixture({
    configure = function(value)
      value.transport.paste = function()
        vim.fn.writefile({ "external change during failed transfer" }, value.root .. "/demo.lua")
        return nil, "simulated paste failure"
      end
    end,
  })
  assert(not f.runtime:prompt("n"))
  first_id = f.invocations[1].review_id
  f.transport.paste = function()
    return true
  end
  assert(f.runtime:prompt("n"))
  eq(
    f.invocations[#f.invocations].review_id,
    first_id,
    "failure rescans and retains a batch that already observed a change"
  )
  assert(f.runtime:shutdown())

  f = fixture()
  assert(f.runtime:prompt("n"))
  first_id = f.invocations[1].review_id
  assert(f.runtime:shutdown())
  f.runtime = ai.setup(f.options)
  assert(f.runtime:prompt("n"))
  eq(
    f.invocations[#f.invocations].review_id,
    first_id,
    "restart reopens the exact durable review baseline"
  )
  assert(f.runtime:shutdown())

  local identity = assert(require("ai.identity").resolve())
  local store = assert(require("ai.state").open(identity))
  assert(require("ai.review.baseline").open(identity, store, first_id:sub(8)):remove())
  f.runtime = ai.setup(f.options)
  local launched = #f.invocations
  assert(not f.runtime:open(), "missing durable baseline disables launch")
  assert(not f.runtime:prompt("n"), "missing durable baseline cannot be replaced by a prompt")
  eq(#f.invocations, launched, "unverifiable review never launches writable")
  eq(store:read_record().review_id, first_id, "missing baseline retains the durable review ID")
  eq(f.runtime:compact(), "AI:L !", "unverifiable review is conflict-only")
  assert(f.runtime:review({ bang = true }))
  eq(
    store:read_record().review_id,
    vim.NIL,
    "explicit confirmed abandonment clears the missing review ID"
  )
  assert(f.runtime:shutdown())

  for _, damage in ipairs({ "removed", "corrupt", "corrupt-direct" }) do
    f = fixture({ codex = true })
    assert(f.runtime:prompt("n"))
    local review_id = f.invocations[1].review_id
    local pinned = assert(require("ai.identity").resolve())
    local durable = assert(require("ai.state").open(pinned))
    local baseline = assert(require("ai.review.baseline").open(pinned, durable, review_id:sub(8)))
    if damage == "removed" then
      assert(baseline:remove())
    else
      vim.fn.writefile(
        { "invalid manifest" },
        durable:state_dir() .. "/reviews/" .. review_id:sub(8) .. "/manifest.json"
      )
    end
    local before = #f.invocations
    if damage ~= "corrupt-direct" then
      assert(
        not f.runtime:backend("codex"),
        "live " .. damage .. " baseline disables backend relaunch"
      )
      assert(not f.runtime:open(), "live damaged baseline disables reopening")
      assert(not f.runtime:prompt("n"), "live damaged baseline disables new prompt delivery")
      eq(#f.invocations, before, "live recovery damage never creates another writable launch")
      eq(f.runtime:compact(), "AI:L !", "live recovery damage is visibly conflicted")
    end
    local abandoned, abandon_error = f.runtime:review({ bang = true })
    assert(
      abandoned,
      "confirmed abandonment closes an unverifiable live batch: " .. tostring(abandon_error)
    )
    if damage ~= "removed" then
      eq(
        vim.fn.readfile(durable:state_dir() .. "/reviews/" .. review_id:sub(8) .. "/manifest.json"),
        { "invalid manifest" },
        "abandonment preserves unknown private baseline remnants"
      )
    end
    assert(f.runtime:prompt("n"), "explicit abandonment permits a new independent review")
    assert(f.runtime:shutdown())
  end

  f = fixture()
  assert(f.runtime:prompt("n"))
  vim.fn.writefile({ "external edit" }, f.root .. "/demo.lua")
  assert(f.runtime:review())
  eq(
    f.selections[#f.selections][1].path,
    "demo.lua",
    "ordinary review opens the detected-path picker"
  )
  assert(
    vim.wait(500, function()
      return table.concat(f.notices, "\n"):find("AI files changed", 1, true) ~= nil
    end),
    "detected edits publish a review notification"
  )
  local confirmation
  f.options.confirm = function(message)
    confirmation = message
    return true
  end
  assert(f.runtime:review({ bang = true }))
  assert(
    confirmation:find("automatic rejection capability for unresolved changes", 1, true),
    "abandonment states lost recovery capability"
  )
  eq(
    vim.fn.readfile(f.root .. "/demo.lua"),
    { "external edit" },
    "abandonment never changes project files"
  )
  eq(f.panes, {}, "abandonment stops writable execution before deleting recovery data")
  assert(f.runtime:open())
  eq(f.invocations[#f.invocations].writable, false, "open after abandonment is read-only")
  assert(f.runtime:shutdown())

  f = fixture()
  assert(f.runtime:prompt("n"))
  local failed_finish_id = f.invocations[1].review_id
  vim.fn.writefile({ "external delta awaiting read-only transition" }, f.root .. "/demo.lua")
  f.options.select = function(items, _, callback)
    callback(items[1])
  end
  local successful_respawn = f.transport.respawn
  f.transport.respawn = function(transport, pane, invocation)
    if not invocation.writable then
      return nil, "simulated read-only relaunch failure", "not_started"
    end
    return successful_respawn(transport, pane, invocation)
  end
  assert(f.runtime:review())
  assert(vim.fn.maparg("A", "n", false, true).callback())
  vim.cmd.tabprevious()
  assert(not f.runtime:prompt("n"), "failed read-only resolution blocks another prompt")
  f.transport.respawn = successful_respawn
  assert(f.runtime:review(), "explicit review retries a failed read-only transition")
  eq(
    f.invocations[#f.invocations].writable,
    false,
    "retried resolution restores read-only execution"
  )
  local failed_finish_identity = assert(require("ai.identity").resolve())
  local failed_finish_store = assert(require("ai.state").open(failed_finish_identity))
  assert(
    not uv.fs_lstat(failed_finish_store:state_dir() .. "/reviews/" .. failed_finish_id:sub(8)),
    "successful retry cleans the retained resolved baseline"
  )
  assert(f.runtime:shutdown())

  for _, restart in ipairs({ false, true }) do
    f = fixture({
      configure = function(value)
        local respawn = value.transport.respawn
        value.transport.respawn = function(transport, pane, invocation)
          if not invocation.writable then
            vim.fn.writefile({ "later external delta" }, value.root .. "/demo.lua")
          end
          return respawn(transport, pane, invocation)
        end
      end,
    })
    assert(f.runtime:prompt("n"))
    local retained_id = f.invocations[1].review_id
    local pinned = assert(require("ai.identity").resolve())
    local durable = assert(require("ai.state").open(pinned))
    vim.fn.writefile({ "first external delta" }, f.root .. "/demo.lua")
    f.options.select = function(items, _, callback)
      for _, item in ipairs(items) do
        if item.path == "demo.lua" then
          callback(item)
          return
        end
      end
      callback(nil)
    end
    assert(f.runtime:review())
    local accept = vim.fn.maparg("A", "n", false, true).callback
    assert(type(accept) == "function", "review exposes its whole-file accept control")
    assert(accept())
    eq(
      durable:read_record().completed_review_id,
      retained_id,
      "read-only transition leaves an exact receipt"
    )
    eq(
      durable:read_review_phase(retained_id:sub(8)).phase,
      "read-only",
      "post-relaunch delta retains its acknowledged batch"
    )
    vim.cmd.tabprevious()
    if restart then
      assert(f.runtime:shutdown())
      f.runtime = ai.setup(f.options)
    end
    local before = #f.invocations
    assert(not f.runtime:prompt("n"), "pending read-only review cannot be made writable again")
    eq(#f.invocations, before, "retained receipt blocks writable re-arming")
    assert(f.runtime:review(), "retained read-only review remains available for explicit decisions")
    local resolve = vim.fn.maparg("A", "n", false, true).callback
    assert(
      type(resolve) == "function",
      "retained exact review exposes acceptance of the later delta"
    )
    assert(resolve())
    assert(
      not uv.fs_lstat(durable:state_dir() .. "/reviews/" .. retained_id:sub(8)),
      "explicit resolution cleans the exact old baseline"
    )
    eq(
      durable:read_record().review_id,
      vim.NIL,
      "baseline cleanup never leaves a writable review binding"
    )
    assert(f.runtime:shutdown())
  end

  f = fixture({
    configure = function(value)
      local respawn = value.transport.respawn
      value.transport.respawn = function(transport, pane, invocation)
        if not invocation.writable then
          local pinned = assert(require("ai.identity").resolve())
          local durable = assert(require("ai.state").open(pinned))
          value.blocked_phase = directory(
            durable:state_dir() .. "/decisions/" .. value.review_id:sub(8) .. "/phase.json"
          )
        end
        return respawn(transport, pane, invocation)
      end
    end,
  })
  assert(f.runtime:prompt("n"))
  f.review_id = f.invocations[1].review_id
  vim.fn.writefile({ "accepted external delta" }, f.root .. "/demo.lua")
  f.options.select = function(items, _, callback)
    callback(items[1])
  end
  assert(f.runtime:review())
  assert(vim.fn.maparg("A", "n", false, true).callback())
  assert(f.runtime:shutdown())
  assert(uv.fs_rmdir(f.blocked_phase))
  local receipt_identity = assert(require("ai.identity").resolve())
  local receipt_store = assert(require("ai.state").open(receipt_identity))
  eq(
    receipt_store:read_record().completed_review_id,
    f.review_id,
    "session receipt survives failed tracker acknowledgement"
  )
  eq(
    receipt_store:read_review_phase(f.review_id:sub(8)),
    nil,
    "failed phase publication left no acknowledgement"
  )
  f.runtime = ai.setup(f.options)
  local before_receipt_cleanup = #f.invocations
  assert(not f.runtime:prompt("n"), "unpublished tracker acknowledgement still blocks re-arming")
  assert(f.runtime:review(), "exact coordinator receipt completes retained resolved review")
  eq(
    #f.invocations,
    before_receipt_cleanup,
    "receipt recovery does not repeat the read-only transition"
  )
  assert(
    not uv.fs_lstat(receipt_store:state_dir() .. "/reviews/" .. f.review_id:sub(8)),
    "receipt recovery removes only the completed baseline"
  )
  assert(f.runtime:shutdown())

  for _, residue in ipairs({ "cleanup", "empty" }) do
    f = fixture()
    assert(f.runtime:prompt("n"))
    local completed_id = f.invocations[1].review_id
    assert(f.runtime:shutdown())
    local pinned = assert(require("ai.identity").resolve())
    local durable = assert(require("ai.state").open(pinned))
    local baseline =
      assert(require("ai.review.baseline").open(pinned, durable, completed_id:sub(8)))
    local saved = durable:read_record()
    saved.review_id, saved.completed_review_id = vim.NIL, completed_id
    assert(durable:write_record(saved))
    assert(
      durable:write_review_phase(completed_id:sub(8), baseline:manifest().baseline_hash, "cleanup")
    )
    assert(baseline:remove())
    local decision_dir = durable:state_dir() .. "/decisions/" .. completed_id:sub(8)
    if residue == "empty" then
      assert(uv.fs_unlink(decision_dir .. "/phase.json"))
    end
    f.runtime = ai.setup(f.options)
    assert(not f.runtime:prompt("n"), "a completed receipt with cleanup residue blocks new batches")
    assert(f.runtime:review(), "explicit review retries acknowledged cleanup without a baseline")
    assert(not uv.fs_lstat(decision_dir), "exact acknowledged residue is removed")
    local launches = #f.invocations
    assert(f.runtime:prompt("n"), "cleaned receipt permits a fresh review")
    eq(#f.invocations, launches + 1, "cleanup itself never launches a provider")
    assert(
      f.invocations[#f.invocations].review_id ~= completed_id,
      "cleanup never substitutes a baseline under the old ID"
    )
    assert(f.runtime:shutdown())
  end

  -- A faster review scan must not replay an expected old-process stop event
  -- after the writable replacement is already running in the same pane.
  for _, poll_during_stop in ipairs({ true, false }) do
    f = fixture()
    assert(f.runtime:open())
    local respawn = f.transport.respawn
    f.transport.respawn = function(...)
      vim.fn.writefile({
        vim.json.encode({
          schema = 1,
          backend = "claude",
          session = "11111111-1111-4111-8111-111111111111",
          state = "failed",
          time = 1,
        }),
      }, f.event_file, "a")
      if poll_during_stop then
        vim.wait(300)
      end
      local result = respawn(...)
      vim.fn.writefile({
        vim.json.encode({
          schema = 1,
          backend = "claude",
          session = "11111111-1111-4111-8111-111111111111",
          state = "open",
          time = 2,
        }),
      }, f.event_file, "a")
      return result
    end
    assert(f.runtime:prompt("n"))
    if not poll_during_stop then
      vim.wait(300)
    end
    eq(#f.invocations, 2, "one writable relaunch")
    assert(f.runtime:open())
    eq(#f.invocations, 2, "expected old-process failure never triggers a second relaunch")
    assert(
      not table.concat(f.notices, "\n"):find("AI companion failed", 1, true),
      "expected old-process event is never replayed as a failure"
    )
    vim.fn.writefile({
      vim.json.encode({
        schema = 1,
        backend = "claude",
        session = "11111111-1111-4111-8111-111111111111",
        state = "failed",
        time = 3,
      }),
    }, f.event_file, "a")
    vim.wait(300)
    eq(
      assert(f.runtime:show_status()).state,
      "failed",
      "a genuine failure after replacement remains visible"
    )
    assert(f.runtime:shutdown())
  end

  f = fixture()
  assert(f.runtime:prompt("n"))
  vim.fn.writefile({
    vim.json.encode({
      schema = 1,
      backend = "claude",
      session = "11111111-1111-4111-8111-111111111111",
      state = "approval",
      time = 1,
    }),
  }, f.event_file, "a")
  assert(
    vim.wait(1500, function()
      return f.runtime:compact() == "AI:L ?"
    end),
    "structured events reach the public compact status"
  )
  local detail = assert(f.runtime:show_status())
  eq(detail.state, "approval", "detailed status uses the same event state")
  eq(
    detail.sessions.claude,
    true,
    "detailed status discloses resumability, not session identifiers"
  )
  assert(
    not vim.inspect(detail):find("11111111", 1, true),
    "detailed status excludes actual session identifiers"
  )
  assert(f.runtime:shutdown())

  f = fixture({ codex = true })
  assert(f.runtime:prompt("n"))
  first_id = f.invocations[1].review_id
  assert(f.runtime:backend("codex"))
  eq(f.runtime:compact(), "AI:C open", "explicit backend switching updates compact status")
  eq(
    f.invocations[#f.invocations].review_id,
    first_id,
    "backend switching preserves the exact review"
  )
  assert(f.runtime:backend())
  eq(f.runtime:compact(), "AI:L open", "backend command without a name always offers the picker")
  assert(not f.runtime:backend("claude; invalid"), "backend names are exact identifiers")
  assert(f.runtime:shutdown())

  f = fixture()
  eq(f.runtime:grants(), {}, "grant listing is empty before any approval")
  assert(not f.runtime:grants(f.root), "revocation requires an exact current grant")
  eq(#f.invocations, 0, "listing grants never opens a provider")
  assert(f.runtime:shutdown())

  f = fixture()
  assert(f.runtime:prompt("n"))
  local outside = directory(f.base .. "/outside")
  vim.ui.select = function(items, _, callback)
    callback(items[2])
  end
  local function request_scope(path)
    local pipe, received, complete = assert(uv.new_pipe(false)), "", false
    pipe:connect(f.control_socket, function(connect_error)
      assert(not connect_error, connect_error)
      pipe:read_start(function(read_error, bytes)
        assert(not read_error, read_error)
        if bytes then
          received = received .. bytes
        else
          complete = true
          pipe:close()
        end
      end)
      pipe:write(vim.json.encode({
        schema = 1,
        operation = "request_scope",
        token = f.control_token,
        path = path,
        reason = "Read a temporary fixture",
      }) .. "\n")
      pipe:shutdown()
    end)
    assert(
      vim.wait(2000, function()
        return complete
      end),
      "private scope request completes"
    )
    return vim.json.decode(received)
  end
  vim.fn.writefile({ "global instructions" }, f.home .. "/AGENTS.md")
  assert(
    not request_scope(f.home .. "/AGENTS.md").ok,
    "global provider instructions cannot be granted writable"
  )
  assert(request_scope(outside).ok, "explicit local scope approval succeeds")
  vim.ui.select = old_select
  assert(
    vim.wait(500, function()
      return table.concat(f.notices, "\n"):find("temporary scope granted", 1, true) ~= nil
    end),
    "scope approval produces a content-free runtime notification"
  )
  eq(f.runtime:show_status().grants, { outside }, "detailed status lists canonical active grants")
  f.options.select = function(items, _, callback)
    callback(items[1])
  end
  eq(f.runtime:grants(outside), { outside }, "revocation picker targets the exact current grant")
  eq(f.runtime:show_status().grants, {}, "picker revocation removes the grant")
  local before_scope = #f.invocations
  vim.ui.select = function(items, _, callback)
    vim.schedule(function()
      local pinned = assert(require("ai.identity").resolve())
      local durable = assert(require("ai.state").open(pinned))
      local id = durable:read_record().review_id
      assert(require("ai.review.baseline").open(pinned, durable, id:sub(8)):remove())
      callback(items[2])
    end)
  end
  assert(not request_scope(outside).ok, "delayed scope approval revalidates the durable baseline")
  eq(#f.invocations, before_scope, "damaged review cannot launch through the scope broker")
  vim.ui.select = old_select
  assert(f.runtime:shutdown())

  f = fixture({
    configure = function(value)
      value.transport.paste = function()
        return nil
      end
    end,
  })
  vim.cmd.normal({ args = { "gg0vl" }, bang = true })
  assert(not f.runtime:prompt("x"))
  vim.cmd.normal({ args = { "\27" }, bang = true })
  first_id = f.invocations[1].review_id
  assert(not uv.fs_lstat(f.last_context), "failed paste removes only its newly prepared context")
  eq(
    f.invocations[#f.invocations].writable,
    false,
    "failed paste restores read-only execution for a new empty batch"
  )
  f.transport.paste = function()
    return true
  end
  assert(f.runtime:prompt("n"))
  assert(
    f.invocations[#f.invocations].review_id ~= first_id,
    "next prompt starts a new batch after empty rollback"
  )
  assert(f.runtime:shutdown())

  f = fixture({
    configure = function(value)
      value.transport.focus = function()
        return nil
      end
    end,
  })
  vim.cmd.normal({ args = { "gg0vl" }, bang = true })
  assert(not f.runtime:prompt("x"))
  vim.cmd.normal({ args = { "\27" }, bang = true })
  assert(
    uv.fs_lstat(f.last_context),
    "focus failure after successful paste preserves delivered context"
  )
  first_id = f.invocations[1].review_id
  f.transport.focus = function()
    return true
  end
  assert(f.runtime:prompt("n"))
  eq(
    f.invocations[#f.invocations].review_id,
    first_id,
    "focus failure retains the delivered review batch"
  )
  assert(f.runtime:shutdown())

  f = fixture()
  assert(f.runtime:prompt("n"))
  first_id = f.invocations[1].review_id
  f.adapter.format_context = function()
    error("PRIVATE_FORMATTER_ERROR")
  end
  assert(not f.runtime:prompt("n"))
  eq(
    f.invocations[#f.invocations].review_id,
    first_id,
    "formatter failure never abandons an existing batch"
  )
  assert(
    not vim.inspect(f.notices):find("PRIVATE_FORMATTER_ERROR", 1, true),
    "formatter exceptions are not displayed"
  )
  local other = directory(f.base .. "/other")
  vim.fn.writefile({ "other project" }, other .. "/different.lua")
  eq(vim.system({ "/usr/bin/git", "init", "-q", other }):wait().code, 0, "second physical Git root")
  local other_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(other_buf, other .. "/different.lua")
  vim.api.nvim_set_current_buf(other_buf)
  local changed, change_error = f.runtime:prompt("n")
  assert(
    not changed and change_error:find("own Neovim", 1, true),
    "runtime pins the first physical identity: " .. tostring(change_error)
  )
  assert(f.runtime:shutdown())

  f = staging_fixture(function(value)
    local health = value.options.registry.health
    value.validation_requests = {}
    value.options.registry.health = function(registry, name)
      if name ~= "opencode" then
        return health(registry, name)
      end
      return {
        installed = true,
        version = "",
        auth = "unknown",
        error = "compatibility not ready",
        compatibility = #value.validation_requests == 0 and "not_checked" or "checking",
      }
    end
    value.options.registry.ensure_opencode_compatibility = function(_, request)
      value.validation_requests[#value.validation_requests + 1] = request
      return { state = "checking" }
    end
    value.options.select = function(items, options, callback)
      value.picker_label = options.format_item(items[3])
      callback(nil)
    end
  end)
  assert(not f.runtime:backend())
  assert(
    f.picker_label:find("checking compatibility; reopen picker", 1, true),
    "pending validation is not presented as an unavailable backend"
  )
  eq(
    f.validation_requests,
    { { reason = "picker" } },
    "explicit picker initiates compatibility validation without queuing an opening"
  )
  local opened, opening_error = f.runtime:backend("opencode")
  assert(not opened and opening_error:find("opening queued", 1, true))
  eq(
    f.validation_requests[2].reason,
    "open",
    "an exact OpenCode request may queue a content-free opening"
  )
  vim.cmd("NvimAIStage TEST:approve")
  assert(not require("ai.staged").busy(), "queued native opening blocks direct staging")
  assert(not f.runtime:conversation({
    root = f.root,
    selection = { "demo.lua" },
    model = "fixture/model",
    opencode = "/usr/bin/true",
  }), "queued native opening excludes conversation")
  eq(#f.invocations, 0, "compatibility checking never starts a provider TUI early")
  assert(f.runtime:close(), "explicit close cancels the queued native opening")
  vim.cmd("NvimAIStage TEST:approve")
  await_staged()
  assert(not f.runtime:conversation({
    root = f.root,
    selection = { "demo.lua" },
    model = "fixture/model",
    opencode = "/usr/bin/true",
  }), "pending staged review excludes conversation")
  require("ai.staged").cancel()
  assert(f.runtime:shutdown())

  do
    f = staging_fixture(function(value)
      value.validation = "checking"
      local health = value.options.registry.health
      value.options.registry.health = function(registry, name)
        if name == "opencode" then
          return { installed = true, auth = "unknown", compatibility = value.validation }
        end
        return health(registry, name)
      end
      value.options.registry.ensure_opencode_compatibility = function()
        value.queued = true
        return { state = value.validation }
      end
      value.options.registry.take_opencode_open = function()
        if value.validation == "ready" and value.queued then
          value.queued = false
          return true
        end
        return false
      end
      value.options.registry.subscribe_opencode_compatibility = function(_, callback)
        value.validated = callback
        return function() end
      end
      local discover = value.transport.discover
      value.transport.discover = function(...)
        if value.validation == "ready" and not value.queue_scanned then
          value.queue_scanned = true
          require("ai.staged").start("TEST:approve")
          value.staging_overlapped = require("ai.staged").busy()
        end
        return discover(...)
      end
    end)
    assert(not f.runtime:backend("opencode"))
    assert(f.queued, "an exact OpenCode request queued the native opening")
    f.validation = "ready"
    f.validated({ state = "ready" })
    assert(
      vim.wait(1500, function()
        return f.queue_scanned
      end, 10),
      "queued completion rechecks native pane ownership"
    )
    assert(
      not f.staging_overlapped,
      "queued native completion reserves the workflow during rediscovery"
    )
    assert(f.runtime:shutdown())
  end

  for _, phase in ipairs({ "failed", "not_checked" }) do
    f = fixture({
      configure = function(value)
        local health = value.options.registry.health
        value.options.registry.health = function(registry, name)
          if name == "opencode" then
            return { installed = true, auth = "unknown", error = "not ready", compatibility = phase }
          end
          return health(registry, name)
        end
        value.options.select = function(items, options, callback)
          local text = options.format_item(items[3])
          local expected = phase == "failed" and "validation failed; :checkhealth draft"
            or "validation not started; :NvimAIBackend opencode"
          assert(
            text:find(expected, 1, true),
            "picker explains the validation state and next action"
          )
          callback(items[3])
        end
      end,
    })
    local opened, reason = f.runtime:backend()
    assert(
      not opened and reason:find("opencode", 1, true),
      "disabled choice identifies its backend"
    )
    eq(#f.invocations, 0, "disabled choice never starts a provider")
    assert(f.runtime:shutdown())
  end

  f = fixture()
  assert(f.runtime:prompt("n"))
  f.panes[1].session = "22222222-2222-4222-8222-222222222222"
  assert(not f.runtime:open(), "stale surviving metadata is not adopted")
  eq(f.runtime:show_status().state, "failed", "failed attachment remains inspectable")
  assert(
    f.runtime:close(),
    "explicit close can reconcile one verified identity-matching stale pane"
  )
  eq(f.panes, {}, "stale owned pane was closed")
  assert(f.runtime:shutdown())

  f = fixture({
    configure = function(value)
      local respawn = value.transport.respawn
      value.transport.paste = function()
        return nil
      end
      value.transport.respawn = function(transport, pane, invocation)
        if not invocation.writable then
          return nil, "simulated read-only relaunch failure", "not_started"
        end
        return respawn(transport, pane, invocation)
      end
    end,
  })
  assert(not f.runtime:prompt("n"))
  eq(
    f.panes,
    {},
    "failed read-only rollback closes the writable process before abandoning its empty batch"
  )
  assert(f.runtime:open())
  eq(
    f.invocations[#f.invocations].writable,
    false,
    "successful rollback cleanup leaves no writable review binding"
  )
  assert(f.runtime:shutdown())
end, debug.traceback)
vim.ui.select, vim.ui.input = old_select, old_input
for _, cleanup in ipairs(cleanups) do
  pcall(cleanup)
end
vim.api.nvim_set_current_dir(old_cwd)
vim.env.XDG_RUNTIME_DIR, vim.env.XDG_STATE_HOME = old_runtime, old_state
vim.fn.delete(base, "rf")
assert(not uv.fs_lstat(base), "runtime fixture cleanup")
assert(ok, err)
print("AI runtime assertions: ok")
