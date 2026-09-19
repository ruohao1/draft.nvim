-- Approved seams: public status/runtime, editor commands, and UI publication.
local function eq(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    label .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual)
  )
end

local status_module = require("ai.status")
local status = assert(status_module.new({}))
for _, case in ipairs({
  { { state = "closed" }, "" },
  { { backend = "codex", state = "open" }, "AI:C open" },
  { { backend = "claude", state = "busy" }, "AI:L busy" },
  { { backend = "opencode", state = "approval" }, "AI:O ?" },
  { { backend = "codex", state = "changes", unresolved = 3 }, "AI:C +3" },
  { { backend = "claude", state = "conflicted", unresolved = 2, conflicts = 1 }, "AI:L !" },
  { { backend = "opencode", state = "paused" }, "AI:O ||" },
  { { backend = "codex", state = "changes", unresolved = 1000 }, "AI:C +999+" },
  { { backend = "bad", state = "busy" }, "" },
  { { backend = "codex", state = "invalid\27" }, "AI:C open" },
  { { backend = "claude", state = "paused", conflicts = 1, unresolved = 4 }, "AI:L ||" },
  { { backend = "opencode", state = "approval", conflicts = 1 }, "AI:O !" },
}) do
  assert(status:update(case[1]))
  eq(status:compact(), case[2], "compact state and precedence")
  assert(#status:compact() <= 32, "compact status stays bounded")
end

local notices, scheduled, redraws, observed = {}, {}, 0, 0
local private = assert(status_module.new({
  notify = function(message, level)
    notices[#notices + 1] = { message = message, level = level }
  end,
  schedule = function(callback)
    scheduled[#scheduled + 1] = callback
  end,
  redraw = function()
    redraws = redraws + 1
  end,
}))
local function drain()
  local callbacks = scheduled
  scheduled = {}
  for _, callback in ipairs(callbacks) do
    callback()
  end
end
private:subscribe(function()
  observed = observed + 1
end)
local payload = {
  backend = "claude",
  state = "approval",
  root = "/repo\n\194\133",
  identity_key = string.rep("a", 32),
  owner_pane = "%12",
  pane = "%40",
  review_id = "review_one",
  affected_path = "file.lua",
  capabilities = {
    busy = true,
    completion = true,
    approval = true,
    exact_session = true,
    secret = "token",
  },
  grants = { "/outside", "bad\0path" },
  unresolved = 3,
  conflicts = 1,
  sessions = {
    claude = "11111111-1111-4111-8111-111111111111",
    codex = "",
    opencode = "ses_private",
  },
  prompt = "prompt-canary",
  context = "context-canary",
  password = "password-canary",
  token = "token-canary",
  auth = { key = "credential-canary" },
}
private:update(payload, "approval")
private:update(payload, "approval")
eq(#notices, 0, "notifications are scheduled outside callback context")
drain()
eq(#notices, 1, "identical transition notifies once")
assert(
  notices[1].message:find(":NvimAIOpen", 1, true),
  "approval notification offers focus mapping"
)
eq(private:detail(), {
  backend = "claude",
  state = "approval",
  root = "/repo",
  identity_key = string.rep("a", 32),
  owner_pane = "%12",
  pane = "%40",
  grants = { "/outside" },
  unresolved = 3,
  conflicts = 1,
  capabilities = { "approval", "busy", "completion", "exact_session" },
  sessions = { claude = true, codex = false, opencode = true },
}, "detail is a content-free whitelist")
local detail = private:detail()
detail.grants[1] = "mutated"
eq(private:detail().grants, { "/outside" }, "detail cannot mutate display state")
payload.state = "busy"
private:update(payload)
payload.state = "approval"
private:update(payload, "approval")
drain()
eq(#notices, 2, "transition away and back can notify again")
for _, case in ipairs({
  { "completed", "completed", nil },
  { "failed", "failed", nil },
  { "changes", "changes", ":NvimAIReview" },
  { "conflicted", "conflict", ":NvimAIReview" },
  { "open", "scope_granted", nil },
  { "open", "scope_refused", nil },
  { "open", "scope_revoked", nil },
  { "paused", "paused", ":NvimAIOpen" },
}) do
  payload.state = case[1]
  private:update(payload, case[2])
  drain()
  if case[3] then
    assert(notices[#notices].message:find(case[3], 1, true), "notification mapping")
  end
end
eq(#notices, 10, "all required transition categories notify")
assert(redraws > 0 and observed > 0, "status changes publish and request redraw")
payload.state = "completed"
private:update(payload, "completed")
assert(private:stop())
drain()
eq(#notices, 10, "stop cancels queued notifications")
assert(not private:update(payload), "stopped status refuses updates")
eq(private:compact(), "", "stopped status is empty")

vim.g.mapleader = " "
local ai = require("ai")
local before = package.loaded["ai.session"]
local runtime = assert(ai.setup())
eq(ai.setup(), runtime, "setup is idempotent")
eq(package.loaded["ai.session"], before, "setup does not construct a session")
for _, name in ipairs({
  "NvimAIOpen",
  "NvimAIPrompt",
  "NvimAIBackend",
  "NvimAIReview",
  "NvimAIGrants",
  "NvimAIStatus",
  "NvimAIClose",
}) do
  eq(vim.fn.exists(":" .. name), 2, "registered public command " .. name)
end
for _, key in ipairs({ "aa", "ab", "ar", "ag", "as", "ax", "ap" }) do
  local mapping = vim.fn.maparg(" " .. key, "n", false, true)
  assert(type(mapping.callback) == "function" and mapping.silent == 1, "normal AI mapping " .. key)
end
local visual = vim.fn.maparg(" ap", "x", false, true)
assert(type(visual.callback) == "function" and visual.silent == 1, "visual prompt mapping")
eq(
  vim.fn.maparg(" aa", "n", false, true).desc,
  "AI: open or focus companion",
  "mapping description"
)
eq(
  #vim.api.nvim_get_autocmds({ group = "NvimAI", event = "VimLeavePre" }),
  1,
  "one shutdown callback"
)
eq(ai.compact(), "", "passive status does not initialize the companion")
assert(runtime:shutdown())

print("AI status assertions: ok")
