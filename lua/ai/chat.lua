-- One runtime-owned conversation; editor actions never own writer authority.
local M = {}
local sources = require("ai.staged_sources")

function M.new(options)
  local chat = {}
  local owner, view, unsubscribe, frozen
  local epoch, opening = 0, false

  local function detach()
    if unsubscribe then
      unsubscribe()
      unsubscribe = nil
    end
  end

  local function refusal(reason)
    if view then
      view:notice(reason)
    else
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

  local function fence()
    local current, revision, token = owner, owner and owner:snapshot().view_revision, epoch
    local current_view = view
    local _, _, stamp = view:draft()
    return function()
      if view ~= current_view or owner ~= current or epoch ~= token then
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

  local function show()
    epoch = epoch + 1
    detach()
    local state = owner:snapshot()
    local ok, reason = view:show(state)
    if not ok then
      return refusal(reason)
    end
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
      owner, frozen = created, nil
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
    local ok, err = dispatch({ kind = kind, text = text })
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

  function chat:hide()
    epoch = epoch + 1
    detach()
    return not view or view:hide()
  end

  local function stop(kind)
    local state, reason = snapshot()
    if not state then
      return refusal(reason)
    end
    if state.review and (state.review.status == "pending" or state.review.status == "revising") then
      return confirm("Discard the pending frozen review?", "Discard and " .. kind, function()
        dispatch({ kind = kind })
      end)
    end
    return dispatch({ kind = kind })
  end

  function chat:cancel()
    return stop("cancel")
  end

  function chat:close()
    return stop("close")
  end

  function chat:review()
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
      return refusal("No current frozen preview is available")
    end
    local paths = {}
    for _, file in ipairs(state.review.files) do
      paths[#paths + 1] = file.path
    end
    local valid = fence()
    vim.ui.select(paths, { prompt = "Open frozen proposal preview" }, function(path)
      if path and vim.list_contains(paths, path) and valid() and frozen == binding then
        local ran, result, reason = pcall(binding.handle.show, binding.handle, path)
        if not ran or not result then
          refusal(ran and (reason or "Cannot show frozen preview") or "Cannot show frozen preview")
        end
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
    end
    if state.retry_safe then
      add("Retry failed turn", "retry")
    end
    if state.phase == "starting" or state.phase == "generating" or state.phase == "review" then
      add("Cancel turn / discard review", "cancel")
    end
    if state.phase == "review" then
      add("Open frozen preview", "review")
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
    owner, view, frozen = nil, nil, nil
    return true
  end

  return chat
end

return M
