-- Provider-free regressions for repository-sized review work on the editor loop.
local root = vim.fn.tempname()
assert(vim.fn.mkdir(root, "p", 448) == 1)
assert(vim.uv.fs_chmod(root, 448))
local function write(path, bytes)
  local fd = assert(vim.uv.fs_open(path, "wx", 384))
  assert(vim.uv.fs_write(fd, bytes, 0) == #bytes)
  assert(vim.uv.fs_close(fd))
end
local function run()
  local project, state = root .. "/project", root .. "/state"
  assert(vim.fn.mkdir(project, "", 448) == 1)
  assert(vim.fn.mkdir(state, "", 448) == 1)
  local function git(...)
    local argv = {
      "git",
      "-C",
      project,
      "-c",
      "core.hooksPath=/dev/null",
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.invalid",
      "-c",
      "commit.gpgsign=false",
    }
    vim.list_extend(argv, { ... })
    local result = vim.system(argv, { text = false }):wait()
    assert(result.code == 0, result.stderr)
    return result.stdout
  end
  git("init", "--quiet")
  for i = 1, 32 do
    write(project .. "/file-" .. i, "original " .. i .. "\n")
  end
  write(project .. "/binary", "first\0second\nthird")
  write(project .. "/line\nname", "newline filename\n")
  git("add", ".")
  git("commit", "--quiet", "-m", "fixture")
  local identity = {
    key = string.rep("a", 32),
    root = project,
    inside_git = true,
    git_dir = project .. "/.git",
    git_common_dir = project .. "/.git",
  }
  local store = {
    state_dir = function()
      return state
    end,
    review_dir = function(_, id)
      local path = state .. "/reviews/" .. id
      assert(vim.fn.mkdir(path, "p", 448) == 1)
      return path
    end,
  }
  local calls = {}
  local baseline = require("ai.review.baseline")._test.new({
    system = function(argv, options)
      calls[argv[6]] = (calls[argv[6]] or 0) + 1
      return vim.system(argv, options):wait(30000)
    end,
  })
  local created = assert(baseline.create(identity, store))
  calls = {}
  local current = assert(baseline.scan_current(identity, {}))
  assert(vim.tbl_count(current.paths) == 34)
  assert(
    (calls["hash-object"] or 0) == 0,
    "current scans must not spawn Git once per file to compute unused storage references"
  )
  calls = {}
  local reopened = assert(baseline.open(identity, store, created:id()))
  assert(reopened:bytes("binary") == "first\0second\nthird")
  assert(reopened:bytes("line\nname") == "newline filename\n")
  assert(
    (calls["cat-file"] or 0) == 1,
    "baseline validation must read tree blobs in one batch, not once per file"
  )
  for _, damage in ipairs({ "truncated", "trailing", "type", "oid", "size", "fingerprint" }) do
    local damaged = require("ai.review.baseline")._test.new({
      system = function(argv, options)
        local result = vim.system(argv, options):wait(30000)
        if argv[6] == "cat-file" and argv[7] == "--batch" then
          if damage == "truncated" then
            result.stdout = result.stdout:sub(1, -2)
          elseif damage == "trailing" then
            result.stdout = result.stdout .. "extra"
          elseif damage == "type" then
            result.stdout = result.stdout:gsub(" blob ", " tree ", 1)
          elseif damage == "oid" then
            result.stdout = string.rep("0", 40) .. result.stdout:sub(41)
          elseif damage == "size" then
            result.stdout = result.stdout:gsub(" blob %d+\n", " blob 67108865\n", 1)
          else
            local ending = assert(result.stdout:find("\n", 1, true))
            result.stdout = result.stdout:sub(1, ending) .. "!" .. result.stdout:sub(ending + 2)
          end
        end
        return result
      end,
    })
    assert(
      not damaged.open(identity, store, created:id()),
      "damaged batch must fail closed: " .. damage
    )
  end
  print("AI review batched Git assertions: ok")
  local task = require("ai.review.task")
  local scans, notifications = 0, 0
  local tracker = require("ai.review.tracker")._test.new({
    identity = identity,
    store = store,
    baseline = reopened,
    start_watchers = false,
    revalidate_baseline = function()
      scans = scans + 1
      if task.current() then
        assert(task.system({ "/usr/bin/sleep", "0.2" }, {}).code == 0)
      end
      return assert(baseline.open(identity, store, created:id()))
    end,
  })
  assert(tracker:ensure_batch())
  tracker:subscribe(function()
    notifications = notifications + 1
  end)
  local heartbeat = false
  vim.defer_fn(function()
    heartbeat = true
  end, 20)
  local started = vim.uv.hrtime()
  assert(tracker:request_scan("periodic"))
  assert(
    (vim.uv.hrtime() - started) / 1e6 < 100,
    "requesting a slow scan must not block the editor"
  )
  for _ = 1, 10 do
    assert(tracker:request_scan("filesystem"))
  end
  assert(
    vim.wait(1000, function()
      return notifications == 2
    end, 5),
    "coalesced scans finish"
  )
  assert(
    heartbeat and scans == 2,
    "editor heartbeat runs while scans are pending; only one coalesced retry"
  )
  assert(tracker:request_scan("periodic"))
  assert(tracker:scan("before_review"), "an explicit fresh scan supersedes background work")
  local count = notifications
  vim.wait(250)
  assert(notifications == count, "cancelled background result cannot publish after a fresh scan")
  assert(tracker:request_scan("periodic"))
  assert(tracker:shutdown())
  count = notifications
  vim.wait(250)
  assert(notifications == count, "shutdown cancels pending work without late publication")
  local captured, completed = false, 0
  local raced = require("ai.review.tracker")._test.new({
    identity = identity,
    store = store,
    baseline = reopened,
    start_watchers = false,
    path_for_buffer = function()
      return "file-1"
    end,
    revalidate_baseline = function()
      return assert(baseline.open(identity, store, created:id()))
    end,
    scanner = function()
      local snapshot = assert(baseline.scan_current(identity, {}))
      if not captured then
        captured = true
        assert(task.system({ "/usr/bin/sleep", "0.1" }, {}).code == 0)
      end
      -- Foreground post-write fingerprinting uses this same scanner seam.
      if task.current() then
        completed = completed + 1
      end
      return snapshot
    end,
  })
  assert(raced:ensure_batch())
  assert(raced:request_scan("periodic"))
  assert(vim.wait(1000, function()
    return captured
  end, 5))
  vim.fn.writefile({ "user edit while scanning" }, project .. "/file-1")
  assert(raced:record_nvim_write(1))
  assert(
    vim.wait(1000, function()
      return completed == 2
    end, 5),
    "a buffer write invalidates and retries the earlier snapshot"
  )
  assert(
    raced:get("file-1").writer == "nvim" and raced:get("file-1").state == "unchanged",
    "stale snapshot must not misclassify the user edit as external"
  )
  assert(raced:shutdown())
  -- A loaded external edit triggers extra fingerprints while publishing. A
  -- write to a later path must also invalidate the rest of that snapshot.
  local checking_buffer, published = false, 0
  vim.fn.writefile({ "external edit" }, project .. "/file-2")
  local publishing = require("ai.review.tracker")._test.new({
    identity = identity,
    store = store,
    baseline = reopened,
    start_watchers = false,
    path_for_buffer = function()
      return "file-3"
    end,
    revalidate_baseline = function()
      return assert(baseline.open(identity, store, created:id()))
    end,
    buffer_state = function(path)
      return { loaded = path == "file-2", modified = false, bufnr = 1 }
    end,
    reload = function()
      return true
    end,
    scanner = function(_, _, reason)
      local snapshot = assert(baseline.scan_current(identity, {}))
      if task.current() and reason == nil and not checking_buffer then
        checking_buffer = true
        assert(task.system({ "/usr/bin/sleep", "0.1" }, {}).code == 0)
      end
      return snapshot
    end,
  })
  assert(publishing:ensure_batch())
  publishing:subscribe(function(_, reason)
    if reason == "coalesced" then
      published = published + 1
    end
  end)
  assert(publishing:request_scan("periodic"))
  assert(vim.wait(1000, function()
    return checking_buffer
  end, 5))
  vim.fn.writefile({ "user edit during buffer synchronization" }, project .. "/file-3")
  assert(publishing:record_nvim_write(1))
  assert(
    vim.wait(2000, function()
      return published == 1
    end, 5),
    "a write during buffer synchronization retries the remaining snapshot"
  )
  assert(
    publishing:get("file-3").writer == "nvim" and publishing:get("file-3").state == "unchanged",
    "publication cannot replay stale metadata over a newer Neovim write"
  )
  assert(publishing:shutdown())
  local failed = require("ai.review.tracker")._test.new({
    identity = identity,
    store = store,
    baseline = reopened,
    start_watchers = false,
    revalidate_baseline = function()
      task.system({ "/usr/bin/sleep", "0.02" }, {})
      return nil, "simulated baseline validation failure"
    end,
  })
  assert(failed:ensure_batch())
  assert(failed:request_scan("periodic"))
  assert(vim.wait(1000, function()
    return failed:batch_status().reason ~= nil
  end, 5))
  assert(
    failed:get("file-1").state == "conflicted",
    "asynchronous validation failure stays fail-closed"
  )
  assert(failed:shutdown())
  print("AI review asynchronous scan assertions: ok")
end
local ok, err = xpcall(run, debug.traceback)
assert(vim.uv.fs_realpath(root) == root and root ~= "/" and root ~= "/tmp")
assert(vim.fn.delete(root, "rf") == 0, "performance fixture cleanup failed")
if not ok then
  error(err, 0)
end
