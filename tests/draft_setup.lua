-- Public setup must be passive and respect a user's existing mappings.
vim.g.mapleader = " "
local keys = { "aa", "ap", "ab", "ar", "ag", "as", "ax", "ae", "ac", "af" }
local calls = 0
local system = vim.system
vim.system = function(...)
  calls = calls + 1
  return system(...)
end
local before_state = vim.fn.glob(vim.env.XDG_STATE_HOME .. "/**", false, true)
local before_runtime = vim.fn.glob(vim.env.XDG_RUNTIME_DIR .. "/**", false, true)
vim.keymap.set("n", "<leader>ap", "<Nop>", { desc = "user mapping" })
local draft = require("draft")
assert(vim.fn.exists(":NvimAIOpen") == 0, "require must be passive")
local has = vim.fn.has
vim.fn.has = function(feature)
  return feature == "nvim-0.12" and 0 or has(feature)
end
local supported, reason = pcall(draft.setup)
vim.fn.has = has
assert(
  not supported and tostring(reason):find("Neovim 0.12", 1, true),
  "unsupported Neovim must fail clearly"
)
assert(vim.fn.exists(":NvimAIOpen") == 0, "version refusal must precede registration")
local options = { staged = { enabled = false } }
local runtime = assert(draft.setup(options))
assert(options.keymaps == nil, "setup must not mutate caller options")
assert(draft.setup() == runtime, "setup must be idempotent")
assert(draft.compact() == "", "passive status must be empty")
assert(package.loaded["ai.companion"] == nil, "setup must not construct a companion")
assert(vim.fn.exists(":NvimAIChat") == 0, "unfinished conversations must not be exposed")
for _, name in ipairs({
  "NvimAIOpen",
  "NvimAIPrompt",
  "NvimAIReview",
  "NvimAIStage",
  "NvimAIStageSetup",
}) do
  assert(vim.fn.exists(":" .. name) == 2, "setup must register " .. name)
end
local function unmapped()
  for _, key in ipairs(keys) do
    local map = vim.fn.maparg(" " .. key, "n", false, true)
    assert(
      key == "ap" and map.desc == "user mapping" or next(map) == nil,
      "default setup must preserve global mapping " .. key
    )
  end
  assert(vim.fn.maparg(" ap", "x") == "", "default setup must not map visual prompts")
end
unmapped()
require("ai.staged").setup({ enabled = false })
unmapped()
assert(calls == 0, "setup/reconfiguration must not launch helpers or providers")
assert(
  vim.deep_equal(before_state, vim.fn.glob(vim.env.XDG_STATE_HOME .. "/**", false, true)),
  "setup created state"
)
assert(
  vim.deep_equal(before_runtime, vim.fn.glob(vim.env.XDG_RUNTIME_DIR .. "/**", false, true)),
  "setup created runtime state"
)
vim.system = system
assert(runtime:shutdown())
runtime = assert(draft.setup({ keymaps = true }))
for _, key in ipairs(keys) do
  assert(
    type(vim.fn.maparg(" " .. key, "n", false, true).callback) == "function",
    "explicit opt-in must map " .. key
  )
end
assert(type(vim.fn.maparg(" ap", "x", false, true).callback) == "function")
assert(runtime:shutdown())

-- Observe the real redraw command while making personal integration observable.
local redraw, personal = 0, 0
local original = vim.cmd.redrawstatus
vim.cmd.redrawstatus = function(...)
  redraw = redraw + 1
  return original(...)
end
package.loaded["ui.statusline"] = {
  refresh = function()
    personal = personal + 1
  end,
}
local display = require("ai.status").new({
  schedule = function(callback)
    callback()
  end,
})
assert(display:update({ backend = "codex", state = "open" }))
assert(redraw == 1, "status must redraw through Neovim's public API")
assert(personal == 0, "status must not invoke a personal statusline module")
vim.cmd.redrawstatus = original
package.loaded["ui.statusline"] = nil
assert(require("draft.health") == require("nvim-ai.health"), "legacy health must alias Draft")
print("Draft setup: passive startup, optional mappings and portable status passed")
