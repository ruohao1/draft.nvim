-- Successful handoff feedback only. Errors and explicit status stay with notify.
local M = {}

function M.info(message, summary, notify)
  if notify then
    notify(message, vim.log.levels.INFO)
    return true
  end
  -- Keep complete guidance in :messages without ever overflowing a single echo.
  -- A redraw between chunks prevents them accumulating into a hit-enter prompt,
  -- including inside a Lua mapping. Never feed Enter or alter message options.
  vim.cmd.redraw()
  -- Both arguments are fixed ASCII guidance, never provider/user content.
  -- echospace accounts for the user's ruler/showcmd settings.
  local space = math.max(0, vim.v.echospace - 1)
  if space == 0 then
    return false
  end
  for first = 1, #message, space do
    vim.api.nvim_echo({ { message:sub(first, first + space - 1) } }, true, {})
    vim.cmd.redraw()
  end
  for _, candidate in ipairs({ summary, "AI: not submitted; :messages", "AI: :messages", "AI" }) do
    if #candidate <= space then
      vim.api.nvim_echo({ { candidate } }, false, {})
      return true
    end
  end
  return true
end

return M
