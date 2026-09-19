-- Content-free display state; this module never grants access or focuses a pane.
local M = {}
local letters = { codex = "C", claude = "L", opencode = "O" }
local states = {
  closed = true,
  starting = true,
  open = true,
  idle = true,
  busy = true,
  completed = true,
  changes = true,
  failed = true,
  paused = true,
  approval = true,
  attention = true,
  conflicted = true,
}

local function count(value)
  value = tonumber(value)
  if not value or value ~= value or value == math.huge or value == -math.huge then
    return 0
  end
  return math.max(0, math.min(999999999, math.floor(value)))
end

local function text(value, limit)
  if type(value) ~= "string" then
    return ""
  end
  value = value:gsub("[%z\1-\31\127]", ""):gsub("\194[\128-\159]", "")
  value = vim.fn.strtrans(value)
  while #value > limit do
    value = vim.fn.strcharpart(value, 0, vim.fn.strchars(value) - 1)
  end
  return value
end

local function detail(value)
  local capabilities, grants, sessions = {}, {}, {}
  for _, name in ipairs({ "approval", "busy", "completion", "exact_session" }) do
    if type(value.capabilities) == "table" and value.capabilities[name] == true then
      capabilities[#capabilities + 1] = name
    end
  end
  for _, path in ipairs(type(value.grants) == "table" and value.grants or {}) do
    if
      type(path) == "string"
      and path:sub(1, 1) == "/"
      and #path <= 4096
      and not path:find("[%z\1-\31\127]")
      and not path:find("\194[\128-\159]")
      and vim.fs.normalize(path, { expand_env = false }) == path
      and text(path, 4096) == path
    then
      grants[#grants + 1] = path
      if #grants == 128 then
        break
      end
    end
  end
  for _, name in ipairs({ "codex", "claude", "opencode" }) do
    local reference = type(value.sessions) == "table" and value.sessions[name]
    sessions[name] = reference == true or (type(reference) == "string" and reference ~= "")
  end
  return {
    backend = letters[value.backend] and value.backend or nil,
    state = states[value.state] and value.state or "open",
    root = text(value.root, 4096),
    identity_key = text(value.identity_key, 32),
    owner_pane = value.owner_pane and text(value.owner_pane, 64) or nil,
    pane = value.pane and text(tostring(value.pane), 64) or nil,
    grants = grants,
    capabilities = capabilities,
    sessions = sessions,
    unresolved = count(value.unresolved),
    conflicts = count(value.conflicts),
  }
end

local notices = {
  approval = { "AI approval requested; focus with :NvimAIOpen.", vim.log.levels.INFO },
  completed = { "AI turn completed.", vim.log.levels.INFO },
  failed = { "AI companion failed; inspect with :NvimAIStatus.", vim.log.levels.ERROR },
  changes = { "AI files changed; review with :NvimAIReview.", vim.log.levels.INFO },
  conflict = { "AI review conflict; resolve with :NvimAIReview.", vim.log.levels.WARN },
  scope_granted = { "AI temporary scope granted; the TUI restarted.", vim.log.levels.INFO },
  scope_refused = { "AI temporary scope request refused.", vim.log.levels.WARN },
  scope_revoked = { "AI temporary scope revoked; the TUI restarted.", vim.log.levels.INFO },
  paused = { "AI companion restored paused; resume with :NvimAIOpen.", vim.log.levels.INFO },
}

local function compact(snapshot)
  local letter = letters[snapshot.backend]
  if not letter then
    return ""
  end
  local suffix
  if snapshot.state == "paused" then
    suffix = "||"
  elseif count(snapshot.conflicts) > 0 or snapshot.state == "conflicted" then
    suffix = "!"
  elseif snapshot.state == "approval" or snapshot.state == "attention" then
    suffix = "?"
  elseif count(snapshot.unresolved) > 0 then
    local unresolved = count(snapshot.unresolved)
    suffix = "+" .. (unresolved > 999 and "999+" or tostring(unresolved))
  else
    suffix = states[snapshot.state] and snapshot.state or "open"
  end
  return "AI:" .. letter .. " " .. suffix
end

function M.new(options)
  options = options or {}
  local status, snapshot = {}, {}
  local stopped, transition, seen, subscribers = false, nil, {}, {}
  local schedule = options.schedule or vim.schedule
  local redraw = options.redraw or function()
    vim.cmd.redrawstatus()
  end
  function status:update(value, category)
    if stopped then
      return nil, "AI status is stopped"
    end
    value = type(value) == "table" and value or {}
    local next_snapshot = detail(value)
    local next_transition = {
      next_snapshot.backend or "",
      next_snapshot.state,
      text(value.review_id, 64),
      text(value.affected_path, 4096),
    }
    if not vim.deep_equal(next_transition, transition) then
      seen = {}
    end
    transition = next_transition
    if not vim.deep_equal(next_snapshot, snapshot) then
      snapshot = next_snapshot
      schedule(function()
        if stopped then
          return
        end
        pcall(redraw)
        for _, callback in ipairs(vim.deepcopy(subscribers)) do
          pcall(callback, status:detail())
        end
      end)
    end
    if notices[category] and not seen[category] then
      seen[category] = true
      local notice = notices[category]
      schedule(function()
        if not stopped then
          pcall(options.notify or vim.notify, notice[1], notice[2])
        end
      end)
    end
    return true
  end
  function status:compact()
    return stopped and "" or compact(snapshot)
  end
  function status:detail()
    return vim.deepcopy(snapshot)
  end
  function status:subscribe(callback)
    if stopped or type(callback) ~= "function" then
      return nil, "AI status observer is invalid"
    end
    subscribers[#subscribers + 1] = callback
    return function()
      for index, candidate in ipairs(subscribers) do
        if candidate == callback then
          table.remove(subscribers, index)
          break
        end
      end
    end
  end
  function status:stop()
    stopped, snapshot, subscribers, transition, seen = true, {}, {}, nil, {}
    return true
  end
  return status
end

return M
