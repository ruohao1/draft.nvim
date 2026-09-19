-- Fresh-editor public setup/commands; only choices are simulated, never I/O.
local calls, notices, inputs, native_calls = {}, {}, 0, 0
local system = vim.system
vim.system = function(argv, ...)
  assert(argv[4] and argv[4]:match("/nvim%-ai%-staged%-settings%.py$"), "unexpected subprocess")
  calls[#calls + 1] = argv[5]
  return system(argv, ...)
end
vim.notify = function(message)
  notices[#notices + 1] = message
end
local staged = require("ai.staged")
assert(vim.fn.exists(":NvimAIStage") == 0, "require is passive")
local config = { settings_directory = vim.env.STAGED_TEST_DIRECTORY }
if vim.env.STAGED_TEST_ACTION == "read_override" then
  config.enabled, config.model = true, "fixture/model"
end
local runtime = require("ai").setup({ staged = config })
if vim.env.STAGED_TEST_ACTION == "normal_prompt_cancel" then
  runtime.native_prompt = function()
    native_calls = native_calls + 1
    return nil, "unexpected native fallback"
  end
end
assert(#calls == 0, "startup must not read settings, credentials, or launch processes")
for _, command in ipairs({
  "NvimAIStage",
  "NvimAIStageSetup",
  "NvimAIStageReset",
  "NvimAIStageApprove",
  "NvimAIPrompt",
  "NvimAINativePrompt",
  "NvimAIReviewMode",
  "NvimAIReview",
}) do
  assert(vim.fn.exists(":" .. command) == 2, command .. " must be discoverable")
end
for _, key in ipairs({ "ae", "ac", "ap", "ar" }) do
  assert(vim.fn.maparg("\\" .. key, "n") ~= "", "missing mapping " .. key)
end
local action = vim.env.STAGED_TEST_ACTION
local auth = vim.env.STAGED_TEST_AUTH
if action == "prompt_cancel" or action == "late_prompt" or action == "normal_prompt_cancel" then
  local file = vim.fs.dirname(vim.env.STAGED_TEST_DIRECTORY) .. "/prompt-source.txt"
  vim.fn.writefile({ "disposable prompt source" }, file)
  assert(vim.uv.fs_chmod(file, 420))
  vim.cmd.edit(vim.fn.fnameescape(file))
end
local pending
vim.ui.input = function(_, callback)
  inputs = inputs + 1
  if action == "late_setup" or action == "late_prompt" then
    pending = callback
  elseif
    action == "cancel_model"
    or action == "prompt_cancel"
    or action == "normal_prompt_cancel"
  then
    callback(nil)
    callback("fixture/model") -- A dismissed UI callback must stay cancelled.
  elseif inputs == 1 then
    callback(action == "invalid_model" and "missing-provider" or "fixture/model")
  elseif action == "cancel_auth" then
    callback(nil)
    callback(auth or "")
  else
    callback(auth or "")
  end
end
vim.ui.select = function(_, _, callback)
  if action == "mode_late" then
    pending = callback
    return
  elseif action == "mode_cancel" then
    callback("Cancel")
    callback("native") -- A dismissed mode choice cannot later be accepted.
    return
  elseif action == "mode_native" or action == "mode_pre_write" then
    callback(action:sub(6))
    return
  end
  callback(
    action == "reset" and "Forget and disable"
      or action == "cancel_confirm" and "Cancel"
      or "Save and enable"
  )
  if action == "cancel_confirm" then
    callback("Save and enable")
  end
end
if action:match("^mode_") then
  vim.cmd("NvimAIReviewMode " .. (action == "mode_pre_write" and "pre_write" or "native"))
  if action == "mode_late" then
    vim.cmd("NvimAIStageCancel")
    pending("native")
  end
elseif action == "save" or action:match("^cancel_") or action == "invalid_model" then
  vim.cmd("NvimAIStageSetup")
elseif action == "reset" then
  vim.cmd("NvimAIStageReset")
elseif action == "late_setup" then
  vim.cmd("NvimAIStageSetup")
  vim.cmd("NvimAIStageCancel")
  pending("fixture/model")
  assert(inputs == 1, "cancelled dialog must not progress")
elseif action == "late_prompt" then
  vim.cmd("NvimAIStage")
  vim.api.nvim_buf_set_name(0, vim.env.STAGED_TEST_DIRECTORY .. "/different-file")
  pending("do not send this")
  assert(table.concat(notices, "\n"):find("Source buffer changed", 1, true))
elseif action == "normal_prompt_cancel" then
  vim.cmd("NvimAIPrompt")
elseif action == "prompt_cancel" or action == "disabled" then
  vim.cmd("NvimAIStage")
end
local status = staged.status()
assert(status.phase == "idle", "setup/cancel must not start staging")
io.stdout:write(vim.json.encode({
  settings = status.settings,
  calls = calls,
  notices = notices,
  inputs = inputs,
  native_calls = native_calls,
}))
