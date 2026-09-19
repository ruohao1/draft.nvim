-- Cooperative read-only review work. Foreground validation keeps its synchronous
-- contract; owned background scans await Git and yield between filesystem work.
local M = {}
local contexts = setmetatable({}, { __mode = "k" })
local pending = {}

function M.current()
  return contexts[coroutine.running()]
end

function M.run(operation, complete)
  local task = { live = true }
  local thread = coroutine.create(operation)
  contexts[thread] = task
  local function finish(ok, value, err)
    task.live = false
    contexts[thread] = nil
    complete(ok, value, err)
  end
  function task:current()
    return coroutine.running() == thread
  end
  function task:cancel()
    self.live = false
    contexts[thread] = nil
    if self.process then
      -- These children only read Git objects; no writable transaction is killed.
      pcall(self.process.kill, self.process, 9)
      self.process = nil
    end
  end
  function task:resume(value)
    if not self.live then
      return
    end
    self.since = vim.uv.hrtime()
    local ok, result, err = coroutine.resume(thread, value)
    if not ok or coroutine.status(thread) == "dead" then
      finish(ok, result, err)
    elseif result ~= pending then
      finish(false, "review task yielded outside its read-only executor")
    end
  end
  task:resume()
  return task
end

function M.system(argv, options)
  local task = M.current()
  if not task then
    return vim.system(argv, options):wait(30000)
  end
  task.process = vim.system(
    argv,
    vim.tbl_extend("keep", options, { timeout = 30000 }),
    function(result)
      vim.schedule(function()
        task.process = nil
        task:resume(result)
      end)
    end
  )
  return coroutine.yield(pending)
end

function M.checkpoint()
  local task = M.current()
  if task and (vim.uv.hrtime() - task.since) / 1e6 >= 4 then
    vim.schedule(function()
      task:resume()
    end)
    coroutine.yield(pending)
  end
end

return M
