-- Cached diagnostics use the public API and the same guarded composer append.
vim.o.columns, vim.o.lines = 140, 42
local root = assert(vim.uv.fs_mkdtemp("/tmp/draft-diagnostics-test-XXXXXX"))
vim.fn.writefile({ "saved editable file" }, root .. "/parser.lua")
assert(vim.uv.fs_chmod(root .. "/parser.lua", 420))
vim.env.DRAFT_CHAT_UI_ROOT = root
dofile(assert(vim.api.nvim_get_runtime_file("tests/fixtures/ai/chat_ui.lua", false)[1]))
local runtime, context = require("draft").setup(), require("ai.chat_context")
local ns1 = vim.api.nvim_create_namespace("context-diagnostics-one")
local ns2 = vim.api.nvim_create_namespace("context-diagnostics-two")
vim.diagnostic.config({ signs = false, virtual_text = false, underline = false })
-- Neovim 0.12.4 crashes in this statusline redraw after headless split changes.
-- Real terminal coverage retains the callback; cache acquisition stays real here.
vim.api.nvim_del_augroup_by_name("nvim.diagnostic.status")
vim.cmd("NvimAIChatHide")
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(buf, root .. "/context-only.txt")
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_lines(
  buf,
  0,
  -1,
  false,
  { "source text is not implicit context", "second line" }
)
local count, get, system, request =
  vim.diagnostic.count, vim.diagnostic.get, vim.system, vim.lsp.buf_request
local get_calls, count_calls, effects = 0, 0, 0
vim.diagnostic.count = function(...)
  count_calls = count_calls + 1
  return count(...)
end
vim.diagnostic.get = function(...)
  get_calls = get_calls + 1
  return get(...)
end
vim.system = function()
  effects = effects + 1
  error("No process may start during attachment")
end
vim.lsp.buf_request = function()
  effects = effects + 1
  error("No LSP refresh during attachment")
end
local function input()
  for _, item in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(item) and vim.bo[item].filetype == "draft-chat-input" then
      return item
    end
  end
  error("Composer missing")
end
local function draft()
  return table.concat(vim.api.nvim_buf_get_lines(input(), 0, -1, false), "\n")
end
local function compose(text)
  vim.api.nvim_buf_set_lines(input(), 0, -1, false, vim.split(text, "\n", { plain = true }))
end
local function source()
  runtime:chat_hide()
  vim.api.nvim_set_current_buf(buf)
end
local function diagnostic(line, message)
  return {
    lnum = line,
    col = 0,
    severity = vim.diagnostic.severity.ERROR,
    message = message or "problem",
  }
end
local function seed(total)
  local records = {}
  for index = 1, total do
    records[index] = diagnostic(index == 1 and 0 or 1)
  end
  vim.diagnostic.set(ns1, buf, records)
  vim.diagnostic.reset(ns2, buf)
  get_calls, count_calls = 0, 0
end
local function capture(range)
  return context.capture_diagnostics(root, buf, range)
end
local ok, reason = xpcall(function()
  seed(1001)
  assert(not capture({ line1 = 1, line2 = 1 }))
  assert(count_calls == 1 and get_calls == 0, "Whole-cache refusal precedes get")
  seed(1000)
  assert(capture({ line1 = 1, line2 = 1 }))
  assert(count_calls == 1 and get_calls == 1, "Eligible cache is retrieved exactly once")
  seed(100)
  assert(capture())
  seed(101)
  assert(not capture(), "Matching record limit refuses rather than truncates")
  seed(0)
  local empty, why = capture()
  assert(not empty and why:find("No cached diagnostics", 1, true))
  assert(get_calls == 0)
  print("ok - whole-cache and output caps are independent; empty caches need no retrieval")

  local record = diagnostic(0, "multiline\né message")
  record.col, record.source, record.code = 2, "分析", 12
  record.user_data = { secret = "nested sentinel must not serialize" }
  local overlap = diagnostic(0, "starts before range")
  overlap.end_lnum = 1
  vim.diagnostic.set(ns1, buf, { record, diagnostic(1, "range match"), overlap })
  local duplicate = vim.deepcopy(record)
  duplicate.code = "12"
  local stale = diagnostic(90, "historical location")
  stale.severity = vim.diagnostic.severity.HINT
  vim.diagnostic.set(ns2, buf, { duplicate, record, stale })
  local result = assert(capture())
  local text = result.block
  assert(text:find('from "context-only.txt"', 1, true))
  assert(text:find("Cached diagnostics; freshness unverified", 1, true))
  assert(text:find("Captured: %d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ; modified: yes"))
  assert(text:find('1:3 ERROR source="分析" code=12 message="multiline\\né message"', 1, true))
  assert(text:find('1:3 ERROR source="分析" code="12"', 1, true))
  assert(text:find('91:1 HINT message="historical location"', 1, true))
  assert(not text:find("nested sentinel", 1, true))
  local _, copies = text:gsub("code=12 message=", "")
  assert(copies == 2, "Identical diagnostics remain duplicated")
  assert(text:find("code=12", 1, true) < text:find('code="12"', 1, true))
  assert(not text:find("source text is not implicit", 1, true))
  local ranged = assert(capture({ line1 = 2, line2 = 2 })).block
  assert(ranged:find("range match", 1, true) and not ranged:find("starts before range", 1, true))
  local saved = vim.deepcopy(vim.diagnostic.get(buf))
  assert(saved[1].user_data.secret == record.user_data.secret)
  assert(not capture({ line1 = 0, line2 = 1 }))
  assert(not capture({ line1 = 2, line2 = 1 }))
  assert(not capture({ line1 = 1, line2 = 3 }))
  print(
    "ok - allowed fields, duplicates, typed codes, range starts and stale positions are explicit"
  )

  local wrapped_count, wrapped_get = vim.diagnostic.count, vim.diagnostic.get
  for _, bad in ipairs({ -1, 0.5, "1", {}, { [5] = 1 }, { [1] = -1 }, { [1] = 0.5 } }) do
    vim.diagnostic.count = function()
      return bad
    end
    get_calls = 0
    assert(not capture() and get_calls == 0)
  end
  vim.diagnostic.count = function()
    error("count failed")
  end
  assert(not capture())
  vim.diagnostic.count = function()
    return { [1] = 1 }
  end
  vim.diagnostic.get = function()
    error("get failed")
  end
  assert(not capture())
  vim.diagnostic.get = function()
    return {}
  end
  assert(not capture(), "A preflight/result count mismatch must refuse")
  for _, bad in ipairs({
    { lnum = -1 },
    { col = -1 },
    { col = 0.5 },
    { severity = 5 },
    { message = "\0" },
    { message = "\r" },
    { message = "\27" },
    { message = "\255" },
    { source = {} },
    { source = "\194\128" },
    { code = false },
    { code = 0 / 0 },
    { message = string.rep("é", 16385) },
    { message = string.rep(string.char(96), 16300) },
  }) do
    local invalid = vim.tbl_extend("force", diagnostic(0), bad)
    vim.diagnostic.get = function()
      return { invalid }
    end
    assert(not capture(), vim.inspect(bad))
  end
  vim.diagnostic.count, vim.diagnostic.get = wrapped_count, wrapped_get
  print("ok - malformed API results and text are refused atomically")

  seed(1)
  compose("Keep my question")
  local selection = vim.deepcopy(runtime:conversation_status().selection)
  assert(vim.fn.exists(":NvimAIChatDiagnostics") == 2)
  assert(not pcall(vim.cmd, "NvimAIChatDiagnostics path.txt"), "No path argument is accepted")
  vim.cmd("1NvimAIChatDiagnostics")
  local attached = draft()
  assert(vim.startswith(attached, "Keep my question\n\nRead-only context snapshot"))
  assert(attached:find("Cached diagnostics; freshness unverified", 1, true))
  assert(vim.deep_equal(runtime:conversation_status().selection, selection))
  assert(effects == 0 and vim.g.chat_fixture_prompts == 0)
  assert(vim.bo[buf].modified and vim.uv.fs_stat(root .. "/context-only.txt") == nil)
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "source updated later" })
  vim.diagnostic.set(ns1, buf, { diagnostic(0, "diagnostic updated later") })
  assert(draft() == attached)
  compose("Edited question without the snapshot")
  source()
  vim.cmd("2NvimAIChatDiagnostics")
  assert(draft() == "Edited question without the snapshot", "No matches leave composer unchanged")
  for _, change in ipairs({
    function()
      vim.bo[buf].endofline = not vim.bo[buf].endofline
    end,
    function()
      compose("newer draft")
    end,
  }) do
    vim.api.nvim_create_autocmd("BufEnter", {
      callback = function(event)
        if vim.bo[event.buf].filetype == "draft-chat-input" then
          change()
          return true
        end
      end,
    })
    assert(not runtime:chat_diagnostics())
    assert(draft() == "Edited question without the snapshot" or draft() == "newer draft")
    source()
  end
  compose(string.rep("x", 32700))
  local prior = draft()
  assert(not runtime:chat_diagnostics() and draft() == prior)
  assert(effects == 0 and vim.g.chat_fixture_prompts == 0)
  print("ok - diagnostics remain passive snapshots and focus races preserve newer state")
end, debug.traceback)
vim.diagnostic.count, vim.diagnostic.get, vim.system, vim.lsp.buf_request =
  count, get, system, request
pcall(runtime.chat_close, runtime)
pcall(runtime.shutdown, runtime)
vim.fn.delete(root, "rf")
assert(ok, reason)
