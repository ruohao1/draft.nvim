-- One runtime-owned conversation; editor actions never own writer authority.
local M = {}
local sources = require("ai.staged_sources")

function M.new(options)
  local chat = {}
  local owner, view, unsubscribe, frozen, return_tab, navigation, normal_mode
  local epoch, opening = 0, false
  local correction

  local function detach()
    if unsubscribe then
      unsubscribe()
      unsubscribe = nil
    end
  end

  local function refusal(reason)
    if not view or not view:notice(reason) then
      (options.notify or vim.notify)(reason, vim.log.levels.WARN)
    end
    return nil, reason
  end

  local function snapshot()
    if not owner then
      return nil, "Open a conversation with :NvimAIChat first"
    end
    return owner:snapshot()
  end

  local function current_review()
    local state = owner and owner:snapshot()
    local binding = frozen
    if
      not state
      or state.phase ~= "review"
      or not state.review
      or not binding
      or binding.owner ~= owner
      or not binding.review
      or binding.review.id ~= state.review.id
      or binding.review.revision ~= state.review.revision
      or binding.review.token ~= state.review.token
    then
      return nil, "No current frozen review is available"
    end
    return binding, state
  end

  local function present_review(binding, path)
    local origin = not binding.handle:current() and vim.api.nvim_get_current_tabpage()
    local ran, result, reason = pcall(binding.handle.show, binding.handle, path)
    if not ran or not result then
      return refusal(
        ran and (reason or "Cannot show frozen preview") or "Cannot show frozen preview"
      )
    end
    binding.presented = true
    binding.waiting_for_normal = nil
    view:notice(nil)
    if origin then
      return_tab = origin
    end
    return true
  end

  local function open_pending_review()
    local binding, state = current_review()
    if not binding or binding.presented then
      return
    end
    binding.waiting_for_normal = nil
    if not view or not view:visible() then
      return
    end
    -- Never turn composer keystrokes into decisions or carry Insert mode into
    -- a frozen buffer. ModeChanged retries after the user leaves input mode.
    if vim.api.nvim_get_mode().mode ~= "n" then
      binding.waiting_for_normal = true
      view:notice("Proposal ready. Press Escape to open its diff.")
      return
    end
    for _, file in ipairs(state.review.files) do
      if file.state == "pending" then
        return present_review(binding, file.path)
      end
    end
  end

  local function fence()
    epoch = epoch + 1
    local current, revision, token = owner, owner and owner:snapshot().view_revision, epoch
    local current_view = view
    local tab = vim.api.nvim_get_current_tabpage()
    local _, _, stamp = view:draft()
    local draft, draft_stamp = correction, correction and correction.draft:stamp()
    return function()
      if
        view ~= current_view
        or owner ~= current
        or epoch ~= token
        or correction ~= draft
        or (draft and not vim.deep_equal(draft.draft:stamp(), draft_stamp))
        or vim.api.nvim_get_current_tabpage() ~= tab
      then
        return false
      end
      local _, _, now = view:draft()
      return now == stamp and (not owner or owner:snapshot().view_revision == revision)
    end
  end

  local function dispatch(action)
    local state, reason = snapshot()
    if not state then
      return refusal(reason)
    end
    local ok, why = owner:dispatch(action, state.view_revision)
    if not ok then
      return refusal(why)
    end
    view:notice(nil)
    return true
  end

  local function confirm(prompt, choice, callback)
    local valid = fence()
    vim.ui.select({ "Keep current conversation", choice }, { prompt = prompt }, function(selected)
      if selected == choice and valid() then
        callback()
      end
    end)
    return true
  end

  local function show(keep_composer)
    if not navigation then
      navigation = vim.api.nvim_create_autocmd("TabLeave", {
        callback = function()
          epoch = epoch + 1
          if frozen then
            frozen.waiting_for_normal = nil
          end
        end,
      })
      normal_mode = vim.api.nvim_create_autocmd("ModeChanged", {
        pattern = "*:n",
        callback = function()
          vim.schedule(function()
            if frozen and frozen.waiting_for_normal then
              open_pending_review()
            end
          end)
        end,
      })
    end
    epoch = epoch + 1
    detach()
    local state = owner:snapshot()
    if frozen and frozen.handle:current() then
      if
        return_tab
        and vim.api.nvim_tabpage_is_valid(return_tab)
        and return_tab ~= vim.api.nvim_get_current_tabpage()
      then
        vim.api.nvim_set_current_tabpage(return_tab)
      else
        vim.cmd("tabnew")
      end
    end
    local ok, reason = view:show(state)
    if not ok then
      return refusal(reason)
    end
    return_tab = vim.api.nvim_get_current_tabpage()
    if state.phase ~= "closed" then
      local current = owner
      unsubscribe = owner:subscribe(function(updated)
        if owner == current then
          view:update(updated)
          if updated.phase == "closed" then
            detach()
          end
        end
      end)
    end
    if not keep_composer then
      open_pending_review()
    end
    return true
  end

  local function construct(files)
    if opening then
      return refusal("Conversation opening is already in progress")
    end
    opening = true
    local ran, result, why = pcall(function()
      local config, reason = options.configuration()
      if not config then
        return nil, reason
      end
      config = vim.deepcopy(config)
      if not files and owner then
        local previous = owner:snapshot()
        files, config.root = {}, previous.root
        for _, path in ipairs(previous.selection) do
          files[#files + 1] = previous.root .. "/" .. path
        end
      end
      local captured, capture_reason = sources.capture(files, config.root)
      if not captured then
        return nil, capture_reason
      end
      config.root, config.selection = captured.root, {}
      for _, file in ipairs(captured.files) do
        config.selection[#config.selection + 1] = file.path
      end
      local created
      config.defer_review = true
      config.on_review = function(handle)
        if owner == created then
          frozen = { owner = created, handle = handle, review = created:snapshot().review }
          open_pending_review()
        end
      end
      config.on_review_action = function(name, argument)
        if owner == created then
          return chat[name](chat, argument)
        end
      end
      created, reason = options.create(config)
      if not created then
        return nil, reason
      end
      detach()
      if view then
        view:dispose()
      end
      owner, frozen, return_tab = created, nil, nil
      view = require("ai.chat_view").new({
        width = options.width,
        on_action = function(name)
          if name == "actions" then
            chat:actions()
          else
            chat[name](chat)
          end
        end,
        on_hide = function()
          epoch = epoch + 1
          if frozen then
            frozen.waiting_for_normal = nil
          end
          detach()
        end,
      })
      return show()
    end)
    opening = false
    if not ran or not result then
      return refusal(ran and why or "Conversation opening failed")
    end
    return true
  end

  function chat:open(files, fresh)
    files = files and #files > 0 and vim.deepcopy(files) or nil
    if opening then
      return refusal("Conversation opening is already in progress")
    end
    if owner and not fresh then
      if files then
        return refusal(
          "Conversation scope is fixed; close it and use :NvimAIChatNew to select files"
        )
      end
      return show()
    end
    if owner then
      if owner:snapshot().phase ~= "closed" then
        return refusal("Close the current conversation before starting a new one")
      end
      local text = view:draft()
      if text ~= "" then
        return confirm(
          "Discard the unsent draft and start a new conversation?",
          "Start new conversation",
          function()
            construct(files)
          end
        )
      end
    end
    return construct(files)
  end

  function chat:attach(selection)
    local state, reason = snapshot()
    if not state then
      return refusal(reason)
    end
    if state.phase == "closed" or state.phase == "closing" or state.recovery_required then
      return refusal("Open an eligible conversation with :NvimAIChatNew before attaching context")
    end
    local buf, marks = vim.api.nvim_get_current_buf()
    if selection == "x" then
      local mode = vim.api.nvim_get_mode().mode
      if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
        return refusal("Select text in Visual mode before attaching context")
      end
      marks = {
        mode = mode,
        first = vim.fn.getpos("v"),
        last = vim.fn.getpos("."),
        inclusive = vim.o.selection ~= "exclusive",
      }
    elseif type(selection) == "table" then
      marks = {
        mode = "V",
        first = { buf, selection.line1, 1, 0 },
        last = { buf, selection.line2, 2147483647, 0 },
      }
    else
      return refusal("Select text with Visual <leader>at or use :[range]NvimAIChatAttach")
    end
    local file = vim.api.nvim_buf_get_name(buf)
    if
      file:sub(1, #state.root + 1) ~= state.root .. "/"
      or not vim.list_contains(state.selection, file:sub(#state.root + 2))
    then
      return refusal("Context must come from a file already selected for this conversation")
    end
    local captured, why = sources.capture({ file }, state.root)
    if not captured then
      return refusal(why)
    end
    local item = captured.files[1]
    local function saved()
      local fd = vim.uv.fs_open(item.file, "r", 0)
      if not fd then
        return false
      end
      local bytes = vim.uv.fs_read(fd, 1024 * 1024 + 1, 0)
      vim.uv.fs_close(fd)
      return bytes == item.oldText and sources.unchanged(captured)
    end
    if not saved() then
      return refusal("Source changed on disk or in a buffer; reload or save it, then select again")
    end
    local region, region_reason = require("ai.context").selection(buf, marks)
    if not region then
      return refusal(region_reason)
    end
    if region.bytes:find("\0", 1, true) then
      return refusal("Select text without NUL bytes for the composer")
    end
    local fence_size = 3
    for run in region.bytes:gmatch("`+") do
      fence_size = math.max(fence_size, #run + 1)
    end
    local fence_text = string.rep("`", fence_size)
    local context = string.format(
      "Selection from %s (lines %d-%d):\n%s\n",
      vim.json.encode(item.path),
      region.first,
      region.last,
      fence_text
    ) .. region.bytes .. (region.bytes:sub(-1) == "\n" and "" or "\n") .. fence_text
    local current = owner
    local _, _, stamp = view:draft()
    if frozen then
      frozen.waiting_for_normal = nil
    end
    if selection == "x" then
      vim.cmd("normal! \27")
    end
    if not show(true) then
      return nil
    end
    local _, _, now = view:draft()
    if
      owner ~= current
      or owner:snapshot().view_revision ~= state.view_revision
      or now ~= stamp
      or not saved()
    then
      return refusal("Conversation, draft or source changed while attaching; select again")
    end
    local appended, append_reason = view:append_draft(context)
    if not appended then
      return refusal(append_reason)
    end
    view:notice("Selection attached. Edit or remove it in the composer; Ctrl-S sends.")
    return true
  end

  local function submit(kind)
    local state, reason = snapshot()
    if not state then
      return refusal(reason)
    end
    if kind == "retry" and not state.retry_safe then
      return refusal("This turn cannot be retried safely")
    end
    local text, why = view:draft()
    if not text then
      return refusal(why)
    end
    if kind == "retry" and text == "" then
      text = state.turns[#state.turns].prompt
    end
    local action = { kind = kind, text = text }
    if kind == "submit" and state.phase == "review" and state.review.status == "pending" then
      action.kind = "revise"
      action.round_id, action.proposal_revision, action.proposal_token =
        state.review.id, state.review.revision, state.review.token
    end
    local ok, err = dispatch(action)
    if ok then
      view:set_draft("")
    end
    return ok, err
  end

  function chat:send()
    return submit("submit")
  end

  function chat:retry()
    return submit("retry")
  end

  local function release_correction(record, consume)
    if correction ~= record then
      return
    end
    correction = nil
    if record.unsubscribe then
      record.unsubscribe()
    end
    if consume and record.draft:unchanged(record.submitted) then
      record.draft:discard(record.submitted)
    else
      record.draft:detach()
    end
  end

  function chat:edit_proposal()
    if correction and owner:snapshot().phase == "editing" then
      local ok, reason = correction.draft:show()
      return ok or refusal(reason)
    end
    local binding, state = current_review()
    if not binding then
      return refusal(state)
    end
    local material, reason = binding.handle:proposal()
    if not material then
      return refusal(reason)
    end
    local identity = {
      round_id = state.review.id,
      proposal_revision = state.review.revision,
      proposal_token = state.review.token,
      path = material.path,
    }
    if
      not dispatch(vim.tbl_extend("force", identity, {
        kind = "edit-proposal",
        seed_sha256 = vim.fn.sha256(material.text),
      }))
    then
      return nil
    end
    local ran, draft, why = pcall(
      require("ai.proposal_correction").open,
      material.path,
      material.text,
      function()
        chat:actions()
      end
    )
    if not ran or not draft then
      dispatch({ kind = "discard-correction" })
      return refusal(ran and why or "Cannot open correction buffer")
    end
    local record = { draft = draft, identity = identity }
    correction = record
    -- This subscription survives hiding the chat view and its windows.
    record.unsubscribe = owner:subscribe(function(updated)
      if correction ~= record then
        return
      end
      if updated.phase == "editing" then
        record.draft:release()
        record.submitted = nil
      elseif (updated.phase == "review" or updated.phase == "idle") and not updated.correction then
        release_correction(record, true)
      elseif updated.phase ~= "freezing" then
        release_correction(record, false)
      end
    end)
    return true
  end

  function chat:freeze_proposal()
    local record = correction
    if
      not record
      or owner:snapshot().phase ~= "editing"
      or vim.api.nvim_get_current_buf() ~= record.draft.buf
    then
      return refusal("Open the active correction with :NvimAIChatEditProposal before freezing")
    end
    local text, stamp = record.draft:snapshot()
    if not text then
      return refusal(stamp)
    end
    local locked, reason = record.draft:lock(stamp)
    if not locked then
      return refusal(reason)
    end
    record.submitted = stamp
    local ok, why = dispatch(vim.tbl_extend("force", record.identity, {
      kind = "correct",
      replacement = text,
    }))
    if not ok and correction == record then
      record.draft:release()
      record.submitted = nil
    end
    return ok, why
  end

  function chat:discard_correction()
    local record = correction
    if not record or owner:snapshot().phase ~= "editing" then
      return refusal("No editable correction can be discarded")
    end
    local function discard()
      record.submitted = record.draft:stamp()
      local ok, reason = dispatch({ kind = "discard-correction" })
      if not ok and correction == record then
        record.submitted = nil
      end
      return ok, reason
    end
    if record.draft:modified() then
      return confirm("Discard the edited correction?", "Discard correction", discard)
    end
    return discard()
  end

  function chat:hide()
    epoch = epoch + 1
    detach()
    if correction then
      correction.draft:hide()
    end
    return not view or view:hide()
  end

  local function stop(kind)
    local state, reason = snapshot()
    if not state then
      return refusal(reason)
    end
    if
      state.review
      and vim.list_contains({ "pending", "revising", "editing", "freezing" }, state.review.status)
    then
      return confirm(
        correction and "Discard the review? Correction text stays in an editable scratch buffer."
          or "Discard the pending frozen review?",
        "Discard and " .. kind,
        function()
          dispatch({ kind = kind })
        end
      )
    end
    return dispatch({ kind = kind })
  end

  function chat:cancel()
    return stop("cancel")
  end

  function chat:close()
    return stop("close")
  end

  function chat:followup()
    if not owner then
      return refusal("Open a conversation with :NvimAIChat first")
    end
    return show()
  end

  function chat:model()
    local state, reason = snapshot()
    if not state then
      return refusal(reason)
    end
    if state.phase ~= "idle" then
      return refusal(
        "Model selection requires an idle conversation; current state: " .. state.phase
      )
    end
    if not state.confirmed_model then
      return refusal(
        "Model choices are available after an explicitly sent, successfully negotiated turn"
      )
    end
    local choices, valid = vim.deepcopy(state.available_models), fence()
    vim.ui.select(choices, {
      prompt = "Model for next turn (conversation only)",
      format_item = function(value)
        return value .. (value == state.desired_model and " (selected)" or "")
      end,
    }, function(chosen)
      if chosen == nil then
        return
      end
      if not valid() then
        return refusal("Model choice expired; reopen the picker")
      end
      if not vim.list_contains(choices, chosen) then
        return refusal("Choose an advertised model")
      end
      return dispatch({ kind = "choose-model", model = chosen })
    end)
    return true
  end

  local function decide(choice, remaining)
    local binding, state = current_review()
    if not binding then
      return refusal(state)
    end
    local intent, reason = binding.handle:prepare(choice, remaining)
    if not intent then
      return refusal(reason)
    end
    local valid = fence()
    local function apply()
      if valid() and frozen == binding and intent.valid() then
        return dispatch({
          kind = "decide",
          choice = choice,
          path = intent.path,
          remaining = intent.remaining,
          round_id = state.review.id,
          proposal_revision = state.review.revision,
          proposal_token = state.review.token,
        })
      end
    end
    if not remaining then
      return apply()
    end
    local label = (choice == "approve" and "Accept" or "Reject")
      .. " remaining "
      .. intent.count
      .. " file(s)"
    vim.ui.select({ "Cancel", label }, { prompt = label .. "?" }, function(selected)
      if selected == label then
        apply()
      end
    end)
    return true
  end

  function chat:approve()
    return decide("approve")
  end

  function chat:reject()
    return decide("reject")
  end

  function chat:approve_all()
    return decide("approve", true)
  end

  function chat:reject_all()
    return decide("reject", true)
  end

  function chat:review(delta)
    local binding, state = current_review()
    if not binding then
      return refusal(state)
    end
    if delta ~= nil then
      local ok, reason = binding.handle:move(delta)
      return ok or refusal(reason)
    end
    local paths = {}
    for _, file in ipairs(state.review.files) do
      paths[#paths + 1] = file.path
    end
    local valid = fence()
    vim.ui.select(paths, { prompt = "Open frozen proposal preview" }, function(path)
      if path and vim.list_contains(paths, path) and valid() and frozen == binding then
        present_review(binding, path)
      end
    end)
    return true
  end

  function chat:actions()
    local state, reason = snapshot()
    if not state then
      return refusal(reason)
    end
    local choices, methods = {}, {}
    local function add(label, method)
      choices[#choices + 1], methods[label] = label, method
    end
    if state.phase == "idle" then
      add("Send draft", "send")
      add("Choose next-turn model", "model")
    end
    if state.retry_safe then
      add("Retry failed turn", "retry")
    end
    if
      vim.list_contains({ "starting", "generating", "review", "editing", "freezing" }, state.phase)
    then
      add("Cancel turn / discard review", "cancel")
    end
    if state.phase == "editing" then
      add("Edit proposal", "edit_proposal")
      if correction and vim.api.nvim_get_current_buf() == correction.draft.buf then
        add("Freeze proposal", "freeze_proposal")
      end
      add("Discard correction", "discard_correction")
    end
    if state.phase == "review" then
      add("Send follow-up", "send")
      add("Open frozen preview", "review")
      if frozen and frozen.handle:current() then
        add("Edit proposal", "edit_proposal")
        add("Accept current file", "approve")
        add("Reject current file", "reject")
        add("Accept remaining files", "approve_all")
        add("Reject remaining files", "reject_all")
      end
    end
    if state.phase == "closed" then
      add("New conversation", "new")
    elseif state.phase ~= "closing" and state.phase ~= "publishing" then
      add("Close conversation", "close")
    end
    add("Hide conversation", "hide")
    local valid = fence()
    vim.ui.select(choices, { prompt = "Draft actions" }, function(choice)
      if choice and methods[choice] and valid() then
        if methods[choice] == "new" then
          self:open(nil, true)
        else
          self[methods[choice]](self)
        end
      end
    end)
    return true
  end

  function chat:dispose()
    if owner and owner:snapshot().phase ~= "closed" then
      return nil, "Close the conversation before disposing its view"
    end
    self:hide()
    if view then
      view:dispose()
    end
    if navigation then
      pcall(vim.api.nvim_del_autocmd, navigation)
      pcall(vim.api.nvim_del_autocmd, normal_mode)
      navigation = nil
      normal_mode = nil
    end
    owner, view, frozen, return_tab = nil, nil, nil, nil
    return true
  end

  return chat
end

return M
