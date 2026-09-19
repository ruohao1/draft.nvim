-- Trusted internal assembly; only explicit owner actions start an ACP worker.
local M = {}
local sources = require("ai.staged_sources")
local review = require("ai.staged_review")
local tools = require("ai.tools")
local module_root =
  debug.getinfo(1, "S").source:sub(2):match("^(.*)/lua/ai/conversation_controller.lua$")
local script = module_root and vim.uv.fs_realpath(module_root .. "/scripts/nvim-ai-conversation.py")
local staged_script = module_root
  and vim.uv.fs_realpath(module_root .. "/scripts/nvim-ai-staged.py")

local function plain(value)
  return type(value) == "table" and getmetatable(value) == nil
end

local function inspect_review(python, reference, token)
  if
    not plain(reference)
    or type(reference.manifest) ~= "string"
    or reference.token ~= token
    or type(token) ~= "string"
    or #token ~= 32
    or not token:match("^[0-9a-f]+$")
    or not reference.manifest:match("^/tmp/nvim%-ai%-staged%-[%w_-]+/proposal%.json$")
  then
    return nil, "Invalid controller review reference"
  end
  for key in pairs(reference) do
    if key ~= "manifest" and key ~= "token" then
      return nil, "Unexpected review reference field"
    end
  end
  local chunks, bytes, failed, process = {}, 0, false, nil
  local ran, result = pcall(function()
    process = vim.system({
      python,
      "-I",
      "-B",
      staged_script,
      "inspect-review",
      "--proposal",
      reference.manifest,
      "--id",
      reference.token,
    }, {
      clear_env = true,
      env = { PATH = "/usr/bin:/bin", LANG = "C.UTF-8" },
      stderr = false,
      stdout = function(error, data)
        failed = failed or error ~= nil
        if data then
          bytes = bytes + #data
          if bytes > 16 * 1024 * 1024 then
            failed = true
            if process then
              process:kill(9)
            end
          elseif not failed then
            chunks[#chunks + 1] = data
          end
        end
      end,
    })
    return process:wait(5000)
  end)
  if not ran or failed or result.code ~= 0 then
    return nil, "Frozen review inspection failed"
  end
  local decoded, value = pcall(vim.json.decode, table.concat(chunks))
  if
    not decoded
    or not plain(value)
    or value.phase ~= "review_ready"
    or value.id ~= token
    or value.proposal ~= reference.manifest
  then
    return nil, "Frozen review inspection did not confirm the registered proposal"
  end
  for key in pairs(value) do
    if
      not (
        { phase = true, proposal = true, id = true, root = true, files = true, decisions = true }
      )[key]
    then
      return nil, "Unexpected frozen review material"
    end
  end
  return value
end

local function private_config(value)
  local ok, payload = pcall(vim.json.encode, value)
  if not ok or #payload > 1024 * 1024 then
    return nil, "Invalid controller launch configuration"
  end
  local directory = vim.uv.fs_mkdtemp("/tmp/draft-conversation-config-XXXXXX")
  if not directory then
    return nil, "Cannot create private controller configuration"
  end
  local path = directory .. "/launch.json"
  local fd = vim.uv.fs_open(path, "wx", 384)
  local written = fd and vim.uv.fs_write(fd, payload, 0)
  if fd then
    vim.uv.fs_close(fd)
  end
  if written ~= #payload then
    vim.uv.fs_unlink(path)
    vim.uv.fs_rmdir(directory)
    return nil, "Cannot write private controller configuration"
  end
  local closed = false
  local function cleanup()
    if closed then
      return true
    end
    if not vim.uv.fs_unlink(path) or not vim.uv.fs_rmdir(directory) then
      return nil, "Private controller configuration cleanup failed"
    end
    closed = true
    return true
  end
  return path, cleanup
end

function M.new(options)
  local allowed = {
    root = true,
    selection = true,
    model = true,
    opencode = true,
    bwrap = true,
    python = true,
    auth_file = true,
    provider = true,
    timeout_ms = true,
    stop_timeout_ms = true,
    on_close = true,
    on_review = true,
  }
  if not plain(options) then
    return nil, "Invalid trusted conversation configuration"
  end
  options = vim.deepcopy(options)
  for key in pairs(options) do
    if not allowed[key] then
      return nil, "Unknown trusted conversation option"
    end
  end
  if
    not script
    or type(options.root) ~= "string"
    or vim.uv.fs_realpath(options.root) ~= options.root
    or (options.on_close ~= nil and type(options.on_close) ~= "function")
    or (options.on_review ~= nil and type(options.on_review) ~= "function")
  then
    return nil, "Invalid conversation root, helper or callback"
  end
  local wrapper = {
    send = function()
      return false
    end,
  }
  local owner, why = require("ai.conversation").new({
    root = options.root,
    selection = options.selection,
    model = options.model,
    driver = wrapper,
  })
  if not owner then
    return nil, why
  end
  local python, python_error = tools.resolve(options.python or "python3")
  local opencode, opencode_error = tools.resolve(options.opencode or "opencode")
  local bwrap, bwrap_error = tools.resolve(options.bwrap or "bwrap")
  if not python or not opencode or not bwrap then
    return nil, python_error or opencode_error or bwrap_error
  end
  local config, cleanup = private_config({
    opencode = opencode,
    bwrap = bwrap,
    model = options.model,
    auth_file = options.auth_file,
    provider = options.provider,
  })
  if not config then
    return nil, cleanup
  end
  local pipe, pipe_error = require("ai.conversation_driver").new({
    command = { python, "-I", "-B", script, "--config", config },
    timeout_ms = options.timeout_ms or 270000,
    stop_timeout_ms = options.stop_timeout_ms or 10000,
  })
  if not pipe then
    cleanup()
    return nil, pipe_error
  end
  local leave = vim.api.nvim_create_autocmd("VimLeavePre", { once = true, callback = cleanup })
  local captured, handle, binding, fenced
  function wrapper:send(command, receive, disconnected)
    if not tools.revalidate(python) or (fenced and command.kind ~= "close") then
      return false
    end
    command = vim.deepcopy(command)
    if command.kind == "start" or command.kind == "revise" then
      if not captured or not sources.unchanged(captured) then
        return false
      end
      command.sources = {}
      for _, item in ipairs(captured.files) do
        command.sources[#command.sources + 1] =
          { path = item.path, snapshot_sha256 = vim.fn.sha256(item.oldText) }
      end
    end
    local refresh_failed = false
    if command.kind == "decide" then
      if
        not handle
        or not binding
        or command.proposal_token ~= binding.token
        or command.round_id ~= binding.id
        or command.proposal_revision ~= binding.revision
      then
        fenced = true
        return false
      end
      local verdict, reason = handle:decide(command.choice, command.path)
      if not verdict then
        fenced = true
        return false
      end
      refresh_failed = reason ~= nil
    end
    local turn_capture = captured
    return pipe:send(command, function(event)
      local replacement
      local guarded = true
      if event.kind == "settled" and (event.outcome == "review" or event.prior_review ~= nil) then
        guarded = turn_capture ~= nil and sources.unchanged(turn_capture)
        if event.prior_review then
          guarded = guarded
            and handle ~= nil
            and handle:intact()
            and binding ~= nil
            and event.prior_review.proposal_token == binding.token
          event.prior_review.context_valid = guarded == true
        end
        if event.outcome == "review" and guarded then
          local frozen = type(event.proposal) == "table"
            and inspect_review(python, event.review_ref, event.proposal.token)
          if frozen and sources.unchanged(turn_capture) then
            replacement = review.open(
              frozen,
              turn_capture,
              { python = python, decisions = event.prior_review and event.prior_review.files }
            )
          end
          guarded = replacement ~= nil and sources.unchanged(turn_capture)
        end
        if not guarded then
          fenced = true
          if replacement then
            replacement:close()
            replacement = nil
          end
          event.outcome, event.submission = "failed", "submitted"
          event.proposal, event.prior_review, event.candidates_retired = nil, nil, nil
          event.tokens_retired = false
        end
      elseif event.review_ref ~= nil then
        fenced = true
        return false
      end
      event.review_ref = nil
      if event.kind == "decided" and refresh_failed then
        event.sources_valid = false
      end
      if event.kind == "closed" and not cleanup() then
        return false
      end
      if event.kind == "closed" then
        local current = owner:snapshot().review
        if not current or current.status == "recovery_required" then
          -- The owner already fenced this review. Controller retirement still
          -- proves tokens_retired; retained journals preserve its writer facts.
          event.receipt = nil
        end
      end
      local accepted, reason = receive(event)
      local view = owner:snapshot()
      if accepted and replacement then
        if handle then
          handle:close()
        end
        handle, binding = replacement, view.review
        if options.on_review and binding then
          local current_handle = handle
          pcall(options.on_review, {
            show = function(_, path)
              return current_handle:show(path)
            end,
          })
        end
      elseif replacement then
        replacement:close()
      end
      if accepted and event.kind == "decided" and view.review and handle then
        binding = view.review
        handle:show(view.review.files[view.review.current_index].path)
      end
      if accepted and not view.review and handle then
        handle:close()
        handle, binding = nil, nil
      end
      if view.phase == "failed" then
        fenced = true
        -- Ingested guard failure retains a cleanup-only route. No generation
        -- or publication can pass wrapper.send until close proves retirement.
        return true
      end
      if accepted and event.kind == "closed" and owner:snapshot().phase == "closed" then
        if handle then
          handle:close()
        end
        pcall(vim.api.nvim_del_autocmd, leave)
        if options.on_close then
          pcall(options.on_close)
        end
      end
      return accepted, reason
    end, disconnected)
  end
  local dispatch = owner.dispatch
  function owner:dispatch(action, revision)
    local view = self:snapshot()
    if fenced and (not plain(action) or action.kind ~= "close") then
      return nil, "Conversation guards failed; close before further work"
    end
    if
      plain(action)
      and revision == view.view_revision
      and (
        (action.kind == "submit" and view.phase == "idle")
        or (action.kind == "retry" and view.phase == "failed" and view.retry_safe)
        or (
          action.kind == "revise"
          and view.phase == "review"
          and view.review.status == "pending"
          and action.round_id == view.review.id
          and action.proposal_revision == view.review.revision
          and action.proposal_token == view.review.token
        )
      )
    then
      if action.kind == "revise" and (not handle or not handle:intact()) then
        fenced = true
        return nil, "Frozen review or captured sources changed; close the conversation"
      end
      local selected = {}
      for _, path in ipairs(view.selection) do
        selected[#selected + 1] = view.root .. "/" .. path
      end
      local value, reason = sources.capture(selected, view.root)
      if not value then
        return nil, reason
      end
      captured = value
    end
    return dispatch(self, action, revision)
  end
  return owner
end

return M
