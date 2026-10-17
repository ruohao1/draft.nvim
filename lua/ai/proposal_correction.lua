-- An editable scratch owns bytes, never proposal authority or project writes.
local M = {}
local sources = require("ai.staged_sources")
local safe = {
  -- acwrite retains Neovim's modified/quit protection; no write handler is installed.
  buftype = "acwrite",
  bufhidden = "hide",
  swapfile = false,
  undofile = false,
  modeline = false,
  binary = false,
  bomb = false,
  fileencoding = "utf-8",
  fileformat = "unix",
  fixendofline = false,
}

function M.open(path, text, on_actions)
  if not sources.valid_text(text) then
    return nil, "Proposal is not supported UTF-8 text"
  end
  local buf = vim.api.nvim_create_buf(true, true)
  local draft, win, locked, detached = { buf = buf }, nil, false, false
  local name = "draft://correction/" .. buf .. "/" .. path
  vim.api.nvim_buf_set_name(buf, name)
  for key, value in pairs(safe) do
    vim.bo[buf][key] = value
  end
  vim.bo[buf].filetype = "draft-proposal-correction"
  local levels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, sources.lines(text))
  vim.bo[buf].undolevels = levels
  vim.bo[buf].endofline = text:sub(-1) == "\n"
  vim.bo[buf].modified = false
  if on_actions then
    vim.keymap.set("n", "g?", on_actions, { buffer = buf, silent = true, desc = "Draft: actions" })
  end

  local function loaded()
    return vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)
  end

  function draft:stamp()
    if not loaded() then
      return nil
    end
    local stamp = {
      tick = vim.api.nvim_buf_get_changedtick(buf),
      name = vim.api.nvim_buf_get_name(buf),
      endofline = vim.bo[buf].endofline,
    }
    for key in pairs(safe) do
      stamp[key] = vim.bo[buf][key]
    end
    return stamp
  end

  function draft:unchanged(stamp)
    return stamp ~= nil and vim.deep_equal(stamp, self:stamp())
  end

  function draft:snapshot()
    local stamp = self:stamp()
    if not stamp or stamp.name ~= name then
      return nil, "Correction buffer is unavailable or was renamed"
    end
    for key, value in pairs(safe) do
      if stamp[key] ~= value then
        return nil, "Correction buffer metadata changed: " .. key
      end
    end
    local count = vim.api.nvim_buf_line_count(buf)
    if count > 20000 or vim.api.nvim_buf_get_offset(buf, count) > 1024 * 1024 + 1 then
      return nil, "Correction exceeds 1 MiB or 20,000 lines"
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for _, line in ipairs(lines) do
      if line:find("\n", 1, true) then
        return nil, "Correction contains an embedded NUL/newline"
      end
    end
    local bytes = table.concat(lines, "\n") .. (stamp.endofline and "\n" or "")
    if not sources.valid_text(bytes) then
      return nil, "Use UTF-8 text without BOM, NUL or CR, ending in LF (or an empty file)"
    end
    return bytes, stamp
  end

  function draft:modified()
    return loaded() and (vim.bo[buf].modified or self:snapshot() ~= text)
  end

  local function label()
    if not loaded() then
      return
    end
    local eof = vim.bo[buf].endofline and "final newline" or "no final newline"
    if
      vim.api.nvim_buf_get_offset(buf, vim.api.nvim_buf_line_count(buf)) == 1
      and not vim.bo[buf].endofline
    then
      eof = "0 bytes"
    end
    local title = (detached and "Detached correction" or "Editable correction")
      .. " · "
      .. path
      .. " · "
      .. eof
      .. " · not published"
      .. (detached and "" or " · :NvimAIChatFreezeProposal")
      .. (not detached and on_actions and " · g? actions" or "")
    for _, visible in ipairs(vim.fn.win_findbuf(buf)) do
      vim.wo[visible].winbar = (" " .. title):gsub("%%", "%%%%")
    end
  end

  function draft:show()
    if not loaded() then
      return nil, "Correction buffer is unavailable"
    end
    local visible = vim.fn.win_findbuf(buf)[1]
    if visible then
      vim.api.nvim_set_current_win(visible)
    else
      vim.cmd("tabnew")
      win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
    end
    label()
    return true
  end

  function draft:hide()
    if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      pcall(vim.api.nvim_win_close, win, true)
    end
    win = nil
    return true
  end

  function draft:lock(stamp)
    if detached or not self:unchanged(stamp) then
      return nil, "Correction changed before freezing; try again"
    end
    vim.bo[buf].modifiable, locked = false, true
    return true
  end

  function draft:release()
    if loaded() and locked then
      vim.bo[buf].modifiable = true
    end
    locked = false
  end

  function draft:detach()
    self:release()
    detached = true
    if loaded() then
      if on_actions then
        pcall(vim.keymap.del, "n", "g?", { buffer = buf })
      end
      vim.bo[buf].modifiable = true
      label()
    end
  end

  function draft:discard(stamp)
    self:hide()
    -- Window-leave callbacks may have added text after the caller's check.
    if stamp and not self:unchanged(stamp) then
      self:detach()
      return false
    end
    if loaded() then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    return true
  end

  local group = vim.api.nvim_create_augroup("draft_correction_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufEnter", "BufWinEnter" }, {
    group = group,
    buffer = buf,
    callback = label,
  })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = "endofline",
    callback = function()
      if vim.api.nvim_get_current_buf() == buf then
        label()
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    once = true,
    callback = function()
      vim.api.nvim_del_augroup_by_id(group)
    end,
  })
  draft:show()
  return draft
end

return M
