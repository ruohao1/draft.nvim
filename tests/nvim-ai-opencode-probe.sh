#!/bin/sh

# Linux-only, provider-free regression: the caller's permissive mask must not
# weaken private probe artifacts, nor be changed by background validation.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
NVIM_AI_TEST_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)
export NVIM_AI_TEST_ROOT
umask 0002

env -u TMUX -u TMUX_PANE NVIM_LOG_FILE=/dev/null \
  nvim --clean --headless -u NONE -i NONE \
  --cmd 'lua vim.opt.runtimepath:prepend(vim.env.NVIM_AI_TEST_ROOT)' \
  -l /dev/stdin <<'LUA'
local function caller_mask()
  for _, line in ipairs(vim.fn.readfile("/proc/self/status")) do
    local mask = line:match("^Umask:%s+(%d+)$")
    if mask then return mask end
  end
  error("Linux process umask is unavailable")
end

assert(caller_mask() == "0002", "regression requires a permissive caller mask")
local controller = require("ai.backends")._test.new_opencode_validation({
  notify = function() end,
})
local ok, err = xpcall(function()
  assert(controller:ensure({ reason = "open", identity_key = string.rep("a", 32) }))
  assert(vim.wait(20000, function()
    local state = controller:snapshot().state
    return state == "ready" or state == "failed"
  end, 10), "installed OpenCode compatibility timed out")
  local result = controller:snapshot()
  assert(result.state == "ready", "installed OpenCode compatibility failed: " .. result.category)
  assert(result.version == "1.18.30", "unexpected audited OpenCode version")
end, debug.traceback)
assert(controller:shutdown(true), "compatibility cleanup was not proved")
assert(caller_mask() == "0002", "background validation changed the caller's umask")
assert(ok, err)
print("AI OpenCode installed-version and private-umask assertions: ok")
LUA
