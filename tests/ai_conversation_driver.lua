-- Existing owner interface, with a real process at the trusted controller seam.
-- This fixture does not claim ACP, store, provider or publication integration.
local conversation = require("ai.conversation")
local process_driver = require("ai.conversation_driver")
local root = vim.fs.dirname(vim.fs.dirname(vim.uv.fs_realpath(debug.getinfo(1, "S").source:sub(2))))
local fixture = root .. "/tests/fixtures/ai/conversation_controller.py"
local count = 0
local function eq(actual, expected)
  assert(vim.deep_equal(actual, expected), vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
end
local function act(owner, action)
  return owner:dispatch(action, owner:snapshot().view_revision)
end
local function phase(owner, expected)
  assert(
    vim.wait(3000, function()
      return owner:snapshot().phase == expected
    end, 5),
    vim.inspect(owner:snapshot())
  )
end
local function create(mode, options)
  local driver = assert(process_driver.new(vim.tbl_extend("force", {
    command = { vim.fn.exepath("python3"), "-I", "-B", fixture, mode or "answer" },
    timeout_ms = 2000,
    stop_timeout_ms = 100,
  }, options or {})))
  local owner = assert(conversation.new({
    root = "/tmp/conversation-pipe-fixture",
    selection = { "example.txt" },
    model = "fixture/model",
    driver = driver,
  }))
  return owner, driver
end
local function scenario(name, run)
  run()
  count = count + 1
  print("ok - " .. name)
end

scenario("a real controller pipe carries explicit sequential turns and confirmed close", function()
  local owner = create()
  eq(owner:snapshot().phase, "idle")
  assert(act(owner, { kind = "submit", text = "first question" }))
  phase(owner, "idle")
  eq(owner:snapshot().turns[1].text, "Fixture answer: first question")
  assert(act(owner, { kind = "submit", text = "second question" }))
  phase(owner, "idle")
  eq(owner:snapshot().turns[2].text, "Fixture answer: second question")
  assert(act(owner, { kind = "close" }))
  phase(owner, "closed")
  eq(owner:snapshot().recovery_required, false)
end)

scenario("controller death during a turn or idle requires recovery without relaunch", function()
  for _, mode in ipairs({ "crash", "idle-crash" }) do
    local owner = create(mode)
    assert(act(owner, { kind = "submit", text = "may have been submitted" }))
    phase(owner, "failed")
    eq(owner:snapshot().retry_safe, false)
    eq(owner:snapshot().recovery_required, true)
    assert(not act(owner, { kind = "retry", text = "do not replay" }))
    assert(act(owner, { kind = "close" }))
    phase(owner, "failed")
  end
end)

scenario("a close assertion followed by failed process exit never claims cleanup", function()
  local owner = create("false-close")
  assert(act(owner, { kind = "close" }))
  phase(owner, "failed")
  eq(owner:snapshot().recovery_required, true)
end)

scenario("malformed bounded pipe frames cannot expose semantic success", function()
  for _, mode in ipairs({
    "bad-json",
    "duplicate",
    "escaped-duplicate",
    "wrong-version",
    "future",
    "extra",
    "deep",
    "oversize",
    "truncated",
    "nan",
    "utf8",
  }) do
    local owner = create(mode)
    local successes = 0
    owner:subscribe(function(view)
      if view.confirmed_model then
        successes = successes + 1
      end
    end)
    assert(act(owner, { kind = "submit", text = "fault fixture" }))
    phase(owner, "failed")
    eq(successes, 0)
    eq(owner:snapshot().retry_safe, false)
  end
end)

scenario("silent controllers and incomplete exit boundaries fail within bounded time", function()
  for _, mode in ipairs({ "silent", "eof-alive", "held-output", "close-alive", "close-trailing" }) do
    local owner = create(mode, { timeout_ms = 200 })
    local started = vim.uv.hrtime()
    local closed = false
    owner:subscribe(function(view)
      closed = closed or view.phase == "closed"
    end)
    assert(
      act(
        owner,
        mode:match("^close") and { kind = "close" } or { kind = "submit", text = "bounded fixture" }
      )
    )
    phase(owner, "failed")
    assert((vim.uv.hrtime() - started) / 1e6 < 700, mode)
    eq(closed, false)
    eq(owner:snapshot().recovery_required, true)
  end
end)

scenario("fragmented UTF-8 frames round-trip without terminal interpretation", function()
  local owner = create("fragmented")
  local message = 'réviser 日本語\n"quoted" \\ path'
  assert(act(owner, { kind = "submit", text = message }))
  phase(owner, "idle")
  eq(owner:snapshot().turns[1].text, "Fixture answer: " .. message)
  assert(act(owner, { kind = "close" }))
  phase(owner, "closed")
end)

scenario("cancel correlates its own command and ignores late prior-command completion", function()
  local owner = create("cancel-stale")
  assert(act(owner, { kind = "submit", text = "wait for cancel" }))
  phase(owner, "generating")
  assert(act(owner, { kind = "cancel" }))
  phase(owner, "idle")
  eq(owner:snapshot().rounds, {})
  eq(owner:snapshot().turns[1].status, "cancelled")
  assert(act(owner, { kind = "close" }))
  phase(owner, "closed")
end)

scenario("observation and model choice never spawn and failed launch never resubmits", function()
  local owner = create(nil, { command = { "/nonexistent/nvim-ai-controller-fixture" } })
  local remove = owner:subscribe(function() end)
  assert(act(owner, { kind = "choose-model", model = "fixture/model" }))
  vim.wait(30, function()
    return false
  end, 5)
  eq(owner:snapshot().phase, "idle")
  eq(owner:snapshot().turns, {})
  remove()
  assert(act(owner, { kind = "submit", text = "explicit launch" }))
  phase(owner, "failed")
  eq(owner:snapshot().retry_safe, false)
end)

scenario("a broken input pipe is never evidence of an unsubmitted safe retry", function()
  local owner = create("epipe")
  assert(act(owner, { kind = "submit", text = string.rep("x", 32768) }))
  phase(owner, "failed")
  eq(owner:snapshot().retry_safe, false)
  eq(owner:snapshot().turns[1].submission, "possibly_submitted")
end)

scenario("controller death while reviewing blocks pending approval", function()
  local owner = create("review-crash")
  assert(act(owner, { kind = "submit", text = "fixture proposal" }))
  phase(owner, "review")
  phase(owner, "failed")
  local view = owner:snapshot()
  eq(view.review.files[1].state, "blocked")
  eq(view.publication_recovery, true)
  assert(not act(owner, {
    kind = "decide",
    choice = "approve",
    path = "example.txt",
    round_id = view.review.id,
    proposal_revision = view.review.revision,
    proposal_token = view.review.token,
  }))
end)

scenario("a driver cannot transfer a live connection to another owner", function()
  local first, driver = create()
  assert(act(first, { kind = "submit", text = "first owner" }))
  phase(first, "idle")
  local second = assert(conversation.new({
    root = "/tmp/second-controller-owner",
    selection = { "example.txt" },
    model = "fixture/model",
    driver = driver,
  }))
  assert(act(second, { kind = "submit", text = "must not bind" }))
  phase(second, "failed")
  eq(first:snapshot().phase, "idle")
  assert(act(first, { kind = "close" }))
  phase(first, "closed")
end)

scenario("duplicate event floods consume wire budgets without growing the transcript", function()
  for _, mode in ipairs({ "byte-flood", "event-flood" }) do
    local owner = create(mode, { timeout_ms = 5000 })
    assert(act(owner, { kind = "submit", text = "bounded duplicate output" }))
    phase(owner, "failed")
    eq(owner:snapshot().turns[1].text, "")
    eq(owner:snapshot().retry_safe, false)
  end
end)

scenario("nested editor event loops do not reenter the controller frame drain", function()
  local owner = create("nested")
  local nested = false
  owner:subscribe(function(view)
    if view.phase == "generating" and not nested then
      nested = true
      vim.wait(50, function()
        return false
      end, 5)
    end
  end)
  assert(act(owner, { kind = "submit", text = "nested event loop" }))
  phase(owner, "idle")
  eq(owner:snapshot().turns[1].text, "Fixture answer: nested event loop")
  assert(act(owner, { kind = "close" }))
  phase(owner, "closed")
end)

scenario("exit waits for every queued frame before evaluating the final close receipt", function()
  for _ = 1, 5 do
    local owner = create("close-burst")
    assert(act(owner, { kind = "submit", text = "first command" }))
    phase(owner, "idle")
    assert(act(owner, { kind = "close" }))
    -- Let the bounded fixture finish writing and exit before Neovim drains the
    -- pipe; process-exit and EOF can then precede the second scheduled batch.
    vim.uv.sleep(100)
    phase(owner, "closed")
  end
end)

scenario("leaving a real editor closes controller input without sending another prompt", function()
  local scratch = vim.fn.tempname()
  assert(vim.fn.mkdir(scratch, "p", 448) == 1)
  local marker = scratch .. "/eof-observed"
  local result = vim
    .system({
      vim.v.progpath,
      "--clean",
      "--headless",
      "-u",
      "NONE",
      "-i",
      "NONE",
      "--cmd",
      "lua vim.opt.rtp:prepend(" .. string.format("%q", root) .. ")",
      "-l",
      root .. "/tests/fixtures/ai/conversation_editor.lua",
      marker,
    }, { env = { NVIM_LOG_FILE = "/dev/null" }, timeout = 3000 })
    :wait()
  eq(result.code, 0)
  assert(vim.wait(2000, function()
    return vim.fn.filereadable(marker) == 1
  end, 5))
  eq(vim.fn.readfile(marker), { "editor EOF observed" })
  assert(vim.fn.delete(scratch, "rf") == 0)
end)

print("ai_conversation_driver: " .. count .. " scenarios passed")
