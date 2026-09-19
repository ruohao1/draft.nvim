-- Real public UI and semantic owner; deterministic in-process provider for TUI tests.
vim.o.swapfile, vim.o.undofile, vim.o.modeline = false, false, false
vim.o.termguicolors, vim.o.number, vim.o.showmode = true, true, true
vim.cmd("colorscheme habamax")
vim.cmd("syntax on")
vim.cmd.cd(vim.fn.fnameescape(vim.env.DRAFT_CHAT_UI_ROOT))
vim.cmd.edit("parser.lua")
vim.bo.filetype = "lua"
vim.g.chat_fixture_prompts = 0
require("ai.conversation_controller").new = function(config)
  local sequence = 0
  local driver = {}
  function driver:send(command, receive)
    local function emit(event)
      sequence = sequence + 1
      receive(vim.tbl_extend("force", event, {
        conversation_id = command.conversation_id,
        owner_generation = command.owner_generation,
        turn_id = command.turn_id,
        worker_generation = command.worker_generation,
        sequence = sequence,
      }))
    end
    if command.kind == "start" then
      vim.g.chat_fixture_prompts = vim.g.chat_fixture_prompts + 1
      vim.g.chat_fixture_message = command.message
      emit({ kind = "submitted", model = "fixture/model" })
      emit({
        kind = "text",
        text = vim.g.chat_fixture_prompts == 1
            and "The parser reads one key=value pair per line.\nIt returns a table of parsed settings.\n\nBlank lines are skipped. No files were changed."
          or "Two edge cases deserve a check:\n\n1. Whitespace around keys and values.\n2. A line with more than one equals sign.\n\nWe can inspect either case in the next turn.",
      })
      emit({ kind = "progress", tool_id = "read", title = "Read parser.lua", status = "completed" })
      emit({ kind = "stopping" })
      emit({
        kind = "settled",
        outcome = "answer",
        stopped = true,
        graceful = true,
        store_valid = true,
      })
    elseif command.kind == "close" then
      emit({ kind = "closed", stopped = true, cleaned = true, tokens_retired = true })
    else
      error("Unexpected TUI fixture operation")
    end
    return true
  end
  local owner = assert(require("ai.conversation").new({
    root = config.root,
    selection = config.selection,
    model = config.model,
    driver = driver,
  }))
  owner:subscribe(function(state)
    if state.phase == "closed" then
      config.on_close()
    end
  end)
  return owner
end
require("draft").setup({
  staged = { enabled = true, model = "fixture/model", root = vim.env.DRAFT_CHAT_UI_ROOT },
})
vim.cmd("NvimAIChat")
vim.g.chat_fixture_ready = true
