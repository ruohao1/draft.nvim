-- Passive public entry points. Companion construction belongs to the first command.
local M = {}
local active
local bindings = {
  { "NvimAIOpen", "aa", "open", "AI: open or focus companion" },
  { "NvimAIPrompt", "ap", "prompt", "AI: prompt using configured review mode" },
  { "NvimAINativePrompt", false, "native_prompt", "AI: native prompt (after-write review)" },
  { "NvimAIBackend", "ab", "backend", "AI: switch backend" },
  { "NvimAIReview", "ar", "review", "AI: review native changes after write" },
  { "NvimAIGrants", "ag", "grants", "AI: inspect or revoke temporary grants" },
  { "NvimAIStatus", "as", "show_status", "AI: show companion status" },
  { "NvimAIClose", "ax", "close", "AI: close companion" },
  { "NvimAIChat", "at", "chat_open", "Draft: open or focus conversation" },
  { "NvimAIChatNew", false, "chat_new", "Draft: start a new conversation after close" },
  { "NvimAIChatSend", false, "chat_send", "Draft: explicitly send composer" },
  { "NvimAIChatHide", false, "chat_hide", "Draft: hide conversation without stopping it" },
  { "NvimAIChatCancel", false, "chat_cancel", "Draft: cancel turn or pending review" },
  { "NvimAIChatRetry", false, "chat_retry", "Draft: explicitly retry a safe failed turn" },
  { "NvimAIChatClose", false, "chat_close", "Draft: close conversation and release scope" },
  { "NvimAIChatReview", false, "chat_review", "Draft: open a frozen proposal preview" },
  { "NvimAIChatApprove", false, "chat_approve", "Draft: accept the visible frozen file" },
  { "NvimAIChatReject", false, "chat_reject", "Draft: reject the visible frozen file" },
  { "NvimAIChatApproveAll", false, "chat_approve_all", "Draft: confirm accepting remaining files" },
  { "NvimAIChatRejectAll", false, "chat_reject_all", "Draft: confirm rejecting remaining files" },
}

local function backend_hint(health, enabled)
  if enabled then
    return health.auth == "authenticated" and "" or "authentication not verified"
  end
  if not health or health.installed ~= true then
    return "not installed; :checkhealth draft"
  end
  if health.auth == "unauthenticated" then
    return "login required; :checkhealth draft"
  end
  if health.compatibility == "checking" then
    return "checking compatibility; reopen picker"
  end
  if health.compatibility == "not_checked" then
    return "validation not started; :NvimAIBackend opencode"
  end
  if health.compatibility and health.compatibility ~= "ready" then
    return "validation failed; :checkhealth draft"
  end
  return "unavailable; :checkhealth draft"
end

function M.setup(options)
  if active and not active.stopped then
    return active.runtime
  end
  options = options or {}
  local state = { stopped = false, runtime = {}, generation = 0 }
  local runtime = state.runtime
  local display = require("ai.status").new(
    vim.tbl_extend("keep", options.status or {}, { notify = options.notify })
  )
  state.display = display
  active = state
  local companion
  local native_running = false
  local function before_staging()
    if state.stopped then
      return nil, "AI runtime is stopped"
    end
    if state.conversation then
      return nil, "Close the conversation before standalone staged activity"
    end
    if native_running then
      return nil, "Wait for the native lifecycle operation before staging"
    end
    local snapshot = companion and companion.session:snapshot() or {}
    if snapshot.pane or snapshot.queued then
      return nil, "Close the native companion with :NvimAIClose before pre-write staging"
    end
    if companion then
      local id, _, why = companion:review_id()
      if id or why then
        return nil,
          "Resolve the native after-write review with :NvimAIReview, or explicitly abandon it with :NvimAIReview!, before pre-write staging"
      end
    end
    -- A native picker opened before staging cannot launch later, even after
    -- the staged turn/dialog has finished and busy() becomes false again.
    state.generation = state.generation + 1
    return true
  end
  local staged =
    require("ai.staged").setup(options.staged, before_staging, options.keymaps ~= false)
  function runtime:conversation(config)
    if type(config) ~= "table" then
      return nil, "Invalid trusted conversation configuration"
    end
    local allowed, why = before_staging()
    if not allowed then
      return nil, why
    end
    if staged.busy() then
      return nil, "Finish or cancel the staged turn/dialog before starting a conversation"
    end
    local lease = {}
    state.conversation = lease
    local callback = config.on_close
    local configured = vim.tbl_extend("force", {}, config, {
      on_close = function()
        if state.conversation == lease then
          state.conversation = nil
          state.generation = state.generation + 1
        end
        if type(callback) == "function" then
          callback()
        end
      end,
    })
    local ran, owner, reason = pcall(require("ai.conversation_controller").new, configured)
    if not ran or not owner then
      state.conversation = nil
      return nil, ran and reason or "Conversation construction failed"
    end
    lease.owner = owner
    return owner
  end
  for _, method in ipairs({
    "open",
    "new",
    "send",
    "hide",
    "cancel",
    "retry",
    "close",
    "review",
    "approve",
    "reject",
    "approve_all",
    "reject_all",
  }) do
    runtime["chat_" .. method] = function(_, files)
      if state.stopped then
        return nil, "AI runtime is stopped"
      end
      if not state.chat then
        state.chat = require("ai.chat").new({
          create = function(config)
            return runtime:conversation(config)
          end,
          configuration = staged.conversation_options,
          notify = options.notify,
        })
      end
      if method == "new" then
        return state.chat:open(files, true)
      end
      return state.chat[method](state.chat, files)
    end
  end
  local function native_transaction(callback, ...)
    if state.stopped or native_running then
      return nil, "AI native lifecycle is busy or stopped"
    end
    if staged.busy() then
      return nil, "Finish or cancel the staged turn/dialog before native activity"
    end
    if state.conversation then
      return nil, "Close the conversation before native activity"
    end
    native_running = true
    local ok, result, why = pcall(callback, ...)
    native_running = false
    if not ok then
      return nil, "AI command failed"
    end
    return result, why
  end
  local function ensure(continuation, allow_detached)
    if not continuation then
      state.generation = state.generation + 1
    end
    if state.stopped then
      return nil, "AI runtime is stopped"
    end
    if state.conversation then
      return nil, "Close the conversation before native activity"
    end
    if vim.uv.os_uname().sysname ~= "Linux" then
      return nil, "AI launch is disabled outside Linux"
    end
    local identity_module = companion and companion.modules["ai.identity"] or require("ai.identity")
    local identity, err = identity_module.resolve()
    if not identity then
      return nil, err
    end
    if
      companion
      and (identity.key ~= companion.identity.key or identity.root ~= companion.identity.root)
    then
      return nil,
        "Open this worktree in its own Neovim instance, or request an explicit scope grant from the pinned companion"
    end
    if not companion then
      companion, err = require("ai.companion").new(vim.tbl_extend("force", {}, options, {
        identity = identity,
        publish = function(snapshot, category)
          display:update(snapshot, category)
        end,
        -- Validation completion is a native lifecycle operation too. Keep its
        -- identity checks, pane rediscovery and launch behind the same guard
        -- after the original user command has returned.
        schedule_native = function(callback)
          vim.schedule(function()
            local completed, why = native_transaction(function()
              callback()
              return true
            end)
            if not completed and not state.stopped then
              (options.notify or vim.notify)(why, vim.log.levels.WARN)
            end
          end)
        end,
      }))
      if not companion then
        return nil, err
      end
    end
    if not companion:revalidate() then
      return nil, "AI trusted host tool changed"
    end
    local attached, attach_error = companion.session:attach()
    companion:refresh(nil, nil, true)
    if not attached and not allow_detached then
      return nil, attach_error
    end
    return companion
  end

  local function choose_backend(current, callback, requested)
    local remembered = current.session:snapshot().backend
    if remembered and not requested then
      return callback(remembered)
    end
    local entries = {}
    for _, name in ipairs({ "codex", "claude", "opencode" }) do
      local health = current.registry:health(name)
      if
        name == "opencode"
        and health
        and health.installed == true
        and health.compatibility == "not_checked"
        and current.registry.ensure_opencode_compatibility
      then
        current.registry:ensure_opencode_compatibility({ reason = "picker" })
        health = current.registry:health(name)
      end
      local enabled = current.modules["ai.backends"].is_available(health)
      entries[#entries + 1] = {
        name = name,
        enabled = enabled,
        auth = health and health.auth or "unknown",
        hint = backend_hint(health, enabled),
      }
    end
    if type(requested) == "string" then
      for _, item in ipairs(entries) do
        if item.name == requested then
          if item.enabled then
            return callback(item.name)
          end
          return nil, item.name .. ": " .. item.hint
        end
      end
      return nil, "AI backend is unavailable; check AI health"
    end
    local completed, returned, result, failure = false, false, nil, nil
    local generation = state.generation
    local select = options.select or vim.ui.select
    select(entries, {
      prompt = "AI backend",
      format_item = function(item)
        return item.name .. (item.hint ~= "" and (" (" .. item.hint .. ")") or "")
      end,
    }, function(choice)
      if completed or state.stopped or generation ~= state.generation then
        return
      end
      completed = true
      local function complete()
        if not choice or not vim.tbl_contains(entries, choice) then
          return nil, "AI backend selection cancelled"
        end
        if not choice.enabled then
          return nil, choice.name .. ": " .. choice.hint
        end
        local verified, verify_error = ensure(true)
        if verified ~= current then
          return nil, verify_error or "AI identity changed"
        end
        return callback(choice.name)
      end
      if returned then
        result, failure = native_transaction(complete)
      else
        local called
        called, result, failure = pcall(complete)
        if not called then
          result, failure = nil, "AI command failed"
        end
      end
      if returned and not result then
        vim.schedule(function()
          if not state.stopped then
            (options.notify or vim.notify)(failure or "AI command failed", vim.log.levels.WARN)
          end
        end)
      end
    end)
    returned = true
    if not completed then
      return true, "AI backend selection pending"
    end
    return result, failure
  end

  function runtime:open()
    local current, err = ensure()
    if not current then
      return nil, err
    end
    local ready, review_error = current:review_ready()
    if not ready then
      return nil, review_error
    end
    return choose_backend(current, function(backend)
      local listening, listen_error = current.scope:start()
      if not listening then
        return nil, listen_error
      end
      return current.session:open(backend)
    end)
  end

  function runtime:prompt(mode)
    if state.stopped then
      return nil, "AI runtime is stopped"
    end
    local policy, why, revision = staged.review_mode()
    if not policy then
      return nil, why
    end
    if policy == "native" then
      return self:native_prompt(mode, function()
        local selected, _, current_revision = staged.review_mode()
        return selected == "native" and current_revision == revision
      end)
    end
    -- Routing happens before native identity, tmux, or backend-health work.
    state.generation = state.generation + 1
    if mode == "x" then
      return nil,
        "Pre-write mode currently supports saved whole files only; use :NvimAIPrompt without a range. No selection or prompt sent"
    end
    local snapshot = companion and companion.session:snapshot() or {}
    local backend = state.staged_backend or snapshot.backend or "opencode"
    if backend ~= "opencode" then
      return nil,
        backend
          .. " does not support pre-write review; choose :NvimAIBackend opencode. No native fallback"
    end
    local allowed, stage_error = before_staging()
    if not allowed then
      return nil, stage_error
    end
    staged.prompt()
    return true
  end

  function runtime:native_prompt(mode, route_valid)
    if staged.busy() then
      return nil, "Finish or cancel the staged turn/dialog before native after-write prompting"
    end
    local current, err = ensure()
    if not current then
      return nil, err
    end
    local ready, review_error = current:review_ready()
    if not ready then
      return nil, review_error
    end
    local buf, cursor = vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local visual = vim.api.nvim_get_mode().mode
    local live = visual == "v" or visual == "V" or visual == "\22"
    local marks = {
      mode = live and visual or vim.fn.visualmode(),
      first = vim.fn.getpos(live and "v" or "'<"),
      last = vim.fn.getpos(live and "." or "'>"),
    }
    return choose_backend(current, function(backend)
      if staged.busy() or (route_valid and not route_valid()) then
        return nil,
          "AI prompt cancelled because the review mode or staged turn changed; prepare it again"
      end
      local still_ready, readiness_error = current:review_ready()
      if not still_ready then
        return nil, readiness_error
      end
      if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_changedtick(buf) ~= tick then
        return nil, "AI prompt context changed while choosing a backend; prepare it again"
      end
      local context, context_error = current.context:stage({
        identity = current.identity,
        bufnr = buf,
        marks = mode == "x" and marks or nil,
        cursor = mode ~= "x" and cursor or nil,
      })
      if not context then
        return nil, context_error
      end
      local previous_batch = current.tracker:batch_status().review_id
      local batch, batch_error = current.tracker:ensure_batch()
      if not batch then
        local cleaned, cleanup_error = context:cancel()
        return nil, cleaned and batch_error or cleanup_error
      end
      local id = "review_" .. batch:id()
      local function rollback(message)
        if current.session:snapshot().queued and current.registry.cancel_opencode_compatibility then
          current.registry:cancel_opencode_compatibility("close")
        end
        local cleaned, cleanup_error = context:cancel()
        message = cleaned and message or cleanup_error
        local scanned = current.tracker:scan("prompt_failure")
        if
          not previous_batch
          and scanned
          and not current.tracker:batch_status().observed_delta
          and not current.tracker:batch_status().reason
        then
          local snapshot = current.session:snapshot()
          local read_only = not snapshot.review_id
            and (snapshot.transfer_ready or (not snapshot.pane and snapshot.state == "closed"))
          if snapshot.review_id == id then
            read_only = current.session:finish_review(id)
          end
          if not read_only then
            local closed = runtime:close()
            if closed then
              local bound = current.session:snapshot().review_id
              read_only = not bound or (bound == id and current.session:finish_review(id))
            end
          end
          if not read_only then
            return nil,
              "AI prompt failed and read-only rollback could not be verified; recovery was retained. Close the companion explicitly."
          end
          if not current.tracker:abandon() then
            return nil,
              "AI prompt failed; read-only execution is restored but private review cleanup needs retry."
          end
        end
        return nil, message
      end
      local listening, listen_error = current.scope:start()
      if not listening then
        return rollback(listen_error)
      end
      local activation = current.session:snapshot().activation
      local bound, bind_error = current.session:prepare_review(id)
      if not bound then
        return rollback(bind_error)
      end
      if not current.session:snapshot().transfer_ready then
        local opened, open_error = current.session:open(backend)
        if not opened then
          return rollback(open_error)
        end
      end
      if backend == "opencode" and current.session:snapshot().activation ~= activation then
        -- OpenCode may flush terminal input while initializing its native TUI.
        -- Neither pane creation nor its event bus acknowledges prompt readiness.
        -- Keep the review-backed launch, but never queue or replay context into it.
        local cleaned, cleanup_error = context:cancel()
        if not cleaned then
          return nil, cleanup_error
        end
        if not current.transport:focus(current.session:snapshot().pane) then
          return nil,
            "OpenCode started, but focus failed; prepare context again once its TUI is ready"
        end
        require("ai.notice").info(
          "OpenCode started. Once its TUI is ready, run :NvimAIPrompt again; no context was pasted or queued.",
          "AI: retry :NvimAIPrompt when ready; nothing sent",
          options.notify
        )
        return true
      end
      local adapter = current.registry:get(backend)
      local text, format_error = context:format(adapter)
      if not text then
        return rollback(format_error)
      end
      local pasted, paste_error, uncertain = current.session:paste(text)
      if not pasted then
        if uncertain then
          -- A lost publication response is not evidence that the TUI did not
          -- receive the reference. Retain its file and review; never replay it.
          local retained, retain_error = context:commit()
          return nil, retained and paste_error or retain_error
        end
        return rollback(paste_error)
      end
      local committed, commit_error = context:commit()
      if not committed then
        return nil, commit_error
      end
      if not current.transport:focus(current.session:snapshot().pane) then
        return nil, "AI context was transferred, but focus failed"
      end
      if state.prompt_hint_review ~= id then
        local message = backend == "opencode"
            and "Context published to OpenCode, not submitted; :NvimAIReview after edits. Check its prompt: HTTP does not confirm insertion."
          or "Context prepared, not submitted; :NvimAIReview after edits."
        local shown = require("ai.notice").info(
          message,
          "AI: not submitted. Check prompt; :NvimAIReview after edits",
          options.notify
        )
        if shown then
          state.prompt_hint_review = id
        end
      end
      return true
    end)
  end

  function runtime:backend(name)
    if name ~= nil and not ({ codex = true, claude = true, opencode = true })[name] then
      return nil, "AI backend name is invalid"
    end
    local policy, why, revision = staged.review_mode()
    if not policy then
      return nil, why
    end
    if policy == "pre_write" then
      if state.stopped or staged.busy() then
        return nil, "Finish or cancel the staged turn/dialog before choosing a backend"
      end
      local function select_staged(backend)
        if backend ~= "opencode" then
          return nil,
            backend
              .. " does not support pre-write review; OpenCode is the only staged backend. No native fallback"
        end
        state.staged_backend = backend
        return true
      end
      state.generation = state.generation + 1
      if name then
        return select_staged(name)
      end
      local generation = state.generation
      local entries = { "opencode", "codex", "claude" }
      local completed = false
      local select = options.select or vim.ui.select
      select(entries, {
        prompt = "Pre-write backend (selection does not launch an agent)",
        format_item = function(backend)
          return backend
            .. (backend == "opencode" and " (staged)" or " (pre-write review unsupported)")
        end,
      }, function(choice)
        local selected, _, current_revision = staged.review_mode()
        if
          completed
          or state.stopped
          or state.generation ~= generation
          or selected ~= "pre_write"
          or revision ~= current_revision
          or staged.busy()
        then
          return
        end
        completed = true
        if not vim.tbl_contains(entries, choice) then
          return
        end
        local ok, message = select_staged(choice)
        if not ok then
          (options.notify or vim.notify)(message, vim.log.levels.WARN)
        end
      end)
      return true
    end
    local current, err = ensure()
    if not current then
      return nil, err
    end
    local ready, review_error = current:review_ready()
    if not ready then
      return nil, review_error
    end
    if name == "opencode" then
      local health = current.registry:health(name)
      if
        health
        and health.installed == true
        and health.compatibility
        and health.compatibility ~= "ready"
      then
        local listening, listen_error = current.scope:start()
        if not listening then
          return nil, listen_error
        end
        return current.session:switch(name)
      end
    end
    return choose_backend(current, function(backend)
      local listening, listen_error = current.scope:start()
      if not listening then
        return nil, listen_error
      end
      return current.session:switch(backend)
    end, name or true)
  end

  function runtime:review(review_options)
    local current, err = ensure(nil, review_options and review_options.bang)
    if not current then
      return nil, err
    end
    local id, _, id_error = current:review_id()
    if not id then
      return nil, id_error or "AI review batch is not open"
    end
    local function abandon(expected)
      if expected ~= id then
        return nil, "AI review batch changed"
      end
      local generation = state.generation
      local confirm = options.confirm
        or function(message)
          return vim.fn.confirm(message, "&Abandon\n&Cancel", 2) == 1
        end
      if
        not confirm(
          "Abandon this review batch? This removes automatic rejection capability for unresolved changes and closes the companion. Project files will not be changed."
        )
      then
        return nil, "AI review abandonment cancelled"
      end
      if
        generation ~= state.generation
        or ensure(true, true) ~= current
        or current:review_id() ~= id
      then
        return nil, "AI review changed while confirming; review it again"
      end
      -- No process may retain write access after its recovery baseline is removed.
      local closed, close_error = runtime:close()
      if not closed then
        return nil, close_error
      end
      local preserve_storage = current.missing_review ~= nil
      local removed, remove_error = current.tracker:abandon({ preserve_storage = preserve_storage })
      if not removed then
        return nil, remove_error
      end
      if not preserve_storage then
        local cleaned, cleanup_error = current.store:cleanup_review_decisions(id:sub(8))
        if not cleaned then
          return nil, cleanup_error
        end
      end
      local finished, finish_error = current.session:abandon_review(id)
      if not finished then
        current.missing_review = id
        current:refresh()
        return nil, finish_error
      end
      current.missing_review = nil
      current:refresh()
      return true
    end
    if review_options and review_options.bang then
      -- Notice fresh damage even when no launch command has inspected it yet.
      current:review_ready(nil, true)
      return abandon(id)
    end
    local ready, review_error = current:review_ready(nil, true)
    if not ready then
      return nil, review_error
    end
    local batch = current.tracker:batch_status()
    if not batch.review_id or batch.cleanup_pending or batch.state == "resolved" then
      local finished, finish_error = current.tracker:finish_review(id:sub(8))
      current:refresh()
      return finished, finish_error
    end
    local scanned, scan_error = current.tracker:scan("review_command")
    if not scanned then
      return nil, scan_error
    end
    if current.review then
      local closed, close_error = current.review:close()
      if not closed then
        return nil, close_error
      end
    end
    current.review = current.modules["ai.review.ui"].new({
      tracker = current.tracker,
      select = options.select,
      confirm = options.confirm,
      notify = options.notify,
      abandon = abandon,
    })
    return current.review:open()
  end

  function runtime:grants(path)
    local current, err = ensure()
    if not current then
      return nil, err
    end
    local grants = current.scope:list()
    local items = {}
    for _, grant in ipairs(grants) do
      if not path or grant == path then
        items[#items + 1] = grant
      end
    end
    if path and #items == 0 then
      return nil, "AI path is not an exact current grant"
    end
    if #items == 0 then
      return grants
    end
    local generation = state.generation
    local select = options.select or vim.ui.select
    select(items, {
      prompt = "Revoke temporary AI grant (cancel to keep)",
      format_item = function(item)
        return item
      end,
    }, function(choice)
      if
        not choice
        or state.stopped
        or generation ~= state.generation
        or not vim.tbl_contains(items, choice)
      then
        return
      end
      if ensure(true) ~= current or not current:review_ready() then
        return
      end
      state.generation = state.generation + 1
      local listening, listen_error = current.scope:start()
      if not listening then
        (options.notify or vim.notify)(listen_error, vim.log.levels.WARN)
        return
      end
      current.scope:revoke(choice, function(result)
        current:refresh(nil, result.ok and "scope_revoked" or "scope_refused")
      end)
    end)
    return grants
  end

  function runtime:show_status()
    local policy, why = staged.review_mode()
    if not policy then
      return nil, why
    end
    if policy == "pre_write" then
      local detail = staged.status()
      local notify = options.notify or vim.notify
      notify(vim.inspect(detail), vim.log.levels.INFO)
      return detail
    end
    local current, err = ensure(nil, true)
    if not current then
      return nil, err
    end
    local detail = display:detail()
    local notify = options.notify or vim.notify
    notify(vim.inspect(detail), vim.log.levels.INFO)
    return detail
  end

  function runtime:close()
    local current, err = ensure(nil, true)
    if not current then
      return nil, err
    end
    local closed, close_error = current.session:close()
    if not closed then
      return nil, close_error
    end
    local cleaned, cleanup_error = current.context:cleanup()
    if not cleaned then
      return nil, cleanup_error
    end
    local result
    current.scope:clear_for_close(function(value)
      result = value
    end)
    return result and result.ok or nil, result and result.message or "AI scope cleanup failed"
  end
  function runtime:shutdown()
    if state.stopped then
      return state.shutdown_result
    end
    if state.conversation then
      return nil, "Close the conversation before stopping the runtime"
    end
    if state.chat then
      state.chat:dispose()
    end
    state.stopped = true
    display:stop()
    state.shutdown_result = not companion or companion:shutdown()
    return state.shutdown_result
  end
  function runtime:compact()
    return display:compact()
  end

  for _, name in ipairs({ "open", "native_prompt", "backend" }) do
    local operation = runtime[name]
    runtime[name] = function(self, ...)
      return native_transaction(operation, self, ...)
    end
  end

  local function dispatch(method, argument)
    local ok, result, err = pcall(runtime[method], runtime, argument)
    if not ok or (not result and not method:match("^chat_")) then
      (options.notify or vim.notify)(
        ok and (err or "AI command was cancelled") or "AI command failed",
        vim.log.levels.WARN
      )
    end
    return result
  end
  for _, binding in ipairs(bindings) do
    local name, key, method, description = unpack(binding)
    local command_options = { desc = description, force = true }
    if method == "review" then
      command_options.bang = true
    end
    if method == "prompt" or method == "native_prompt" then
      command_options.range = true
    end
    if method == "backend" or method == "grants" then
      command_options.nargs = "?"
    end
    if method == "chat_open" or method == "chat_new" then
      command_options.nargs, command_options.complete = "*", "file"
    end
    if method == "backend" then
      command_options.complete = function()
        return { "codex", "claude", "opencode" }
      end
    end
    vim.api.nvim_create_user_command(name, function(args)
      local argument
      if method == "review" then
        argument = { bang = args.bang }
      elseif method == "prompt" or method == "native_prompt" then
        argument = args.range > 0 and "x" or "n"
      elseif method == "chat_open" or method == "chat_new" then
        argument = #args.fargs > 0 and args.fargs or nil
      elseif args.args ~= "" then
        argument = args.args
      end
      dispatch(method, argument)
    end, command_options)
    if key and options.keymaps ~= false then
      vim.keymap.set("n", "<leader>" .. key, function()
        dispatch(method, method == "prompt" and "n" or nil)
      end, { silent = true, desc = description })
    end
  end
  vim.api.nvim_create_user_command("NvimAIReviewMode", function(args)
    local snapshot = companion and companion.session:snapshot() or {}
    if snapshot.pane or snapshot.queued then
      return (options.notify or vim.notify)(
        "Close the native companion with :NvimAIClose before changing review mode",
        vim.log.levels.WARN
      )
    end
    state.generation = state.generation + 1
    local generation = state.generation
    staged.configure_review_mode(args.args ~= "" and args.args or nil, function()
      local latest = companion and companion.session:snapshot() or {}
      return not state.stopped
        and generation == state.generation
        and not latest.pane
        and not latest.queued
    end)
  end, {
    nargs = "?",
    force = true,
    complete = function()
      return { "pre_write", "native" }
    end,
    desc = "AI: choose and save prompt review mode (no prompt sent)",
  })
  if options.keymaps ~= false then
    vim.keymap.set("x", "<leader>ap", function()
      dispatch("prompt", "x")
    end, { silent = true, desc = "AI: selection prompt (native review mode only)" })
  end
  local group = vim.api.nvim_create_augroup("NvimAI", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      runtime:shutdown()
    end,
  })
  return runtime
end

function M.compact()
  return active and active.display:compact() or ""
end

return M
