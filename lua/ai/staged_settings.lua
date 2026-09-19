-- Lazy local preferences; setup never probes a provider or opens credentials.
local M = {}
local root = debug.getinfo(1, "S").source:sub(2):match("^(.*)/lua/ai/staged_settings.lua$")
local script = root and vim.uv.fs_realpath(root .. "/scripts/nvim-ai-staged-settings.py")

local function invoke(operation, options, settings)
  local tools = require("ai.tools")
  local python, why = tools.resolve(options.python or "python3")
  if not python or not tools.revalidate(python) or not script then
    return nil, why or "Preferences helper is unavailable"
  end
  local directory = options.settings_directory or (vim.fn.stdpath("state") .. "/draft.nvim/staged")
  local ok, result = pcall(function()
    return vim
      .system({ python, "-I", "-B", script, operation }, {
        text = true,
        clear_env = true,
        env = { PATH = "/usr/bin:/bin", LANG = "C.UTF-8" },
        stdin = vim.json.encode({ directory = directory, settings = settings }),
      })
      :wait(1000)
  end)
  if not ok or result.code ~= 0 then
    return nil, "Preferences helper failed; no settings activated"
  end
  local decoded, value = pcall(vim.json.decode, result.stdout or "")
  if
    not decoded
    or type(value) ~= "table"
    or value.ok ~= true
    or type(value.settings) ~= "table"
  then
    return nil, "Preferences refused; check settings permissions and the model/auth-file path"
  end
  return value.settings
end

function M.load(options)
  return invoke("load", options or {})
end

function M.save(options, settings)
  -- Never persist provider configuration, executable overrides, or credentials.
  local value = { schema = 1, enabled = settings.enabled == true }
  if settings.review_mode ~= nil then
    value.review_mode = settings.review_mode
  end
  if value.enabled then
    value.model, value.auth_file = settings.model, settings.auth_file
  end
  return invoke("save", options or {}, value)
end

return M
