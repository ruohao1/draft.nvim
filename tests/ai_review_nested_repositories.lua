local baseline_module = require("ai.review.baseline")
local uv = vim.uv
local base = assert(uv.fs_mkdtemp("/tmp/draft-nested-repositories-XXXXXX"))
assert(uv.fs_chmod(base, 448))

local function directory(path)
  assert(vim.fn.mkdir(path, "p", 448) >= 0)
  assert(uv.fs_chmod(path, 448))
  return path
end

local function git(root, ...)
  local argv = { "/usr/bin/git", "-C", root }
  vim.list_extend(argv, { ... })
  local result = vim.system(argv, { text = false }):wait()
  assert(result.code == 0, result.stderr)
  return result.stdout
end

local function commit(root)
  git(root, "add", "--all")
  git(
    root,
    "-c",
    "user.name=Draft test",
    "-c",
    "user.email=draft@example.invalid",
    "-c",
    "commit.gpgsign=false",
    "commit",
    "--quiet",
    "-m",
    "fixture"
  )
end

local function fixture(label, ignored, linked, staged_deletion)
  local root = directory(base .. "/" .. label .. "/repo")
  local state = directory(base .. "/" .. label .. "/state")
  git(root, "init", "--quiet")
  vim.fn.writefile({ "original" }, root .. "/tracked.txt")
  if ignored then
    vim.fn.writefile({ "nested/" }, root .. "/.gitignore")
  end
  if staged_deletion then
    vim.fn.writefile({ "tracked file" }, root .. "/nested")
  end
  commit(root)
  if staged_deletion then
    git(root, "rm", "--cached", "nested")
    assert(uv.fs_unlink(root .. "/nested"))
  end
  if linked then
    git(root, "worktree", "add", "--quiet", "--detach", "nested", "HEAD")
  else
    directory(root .. "/nested")
    git(root .. "/nested", "init", "--quiet")
    vim.fn.writefile({ "nested content" }, root .. "/nested/child.txt")
    commit(root .. "/nested")
  end
  local identity = {
    key = vim.fn.sha256(root):sub(1, 32),
    root = root,
    inside_git = true,
    git_dir = root .. "/.git",
    git_common_dir = root .. "/.git",
    git_entry = root .. "/.git",
    namespace = "nvim:nested-test",
  }
  local store = {
    state_dir = function()
      return state
    end,
    review_dir = function(_, id)
      return directory(state .. "/reviews/" .. id)
    end,
  }
  return root, identity, store
end

local ok, err = xpcall(function()
  for _, ignored in ipairs({ false, true }) do
    for _, linked in ipairs({ false, true }) do
      local label = (ignored and "ignored-" or "untracked-") .. (linked and "worktree" or "repo")
      local root, identity, store = fixture(label, ignored, linked)
      local args = { "ls-files", "-z", "--others", "--exclude-standard" }
      if ignored then
        args[#args + 1] = "--ignored"
      end
      assert(git(root, unpack(args)) == "nested/\0", "Git emits a directory record")
      local before = git(root, "status", "--porcelain=v1", "-z")
      local nested_before = git(root .. "/nested", "status", "--porcelain=v1", "-z")
      local baseline, why = baseline_module.create(identity, store)
      assert(baseline, label .. ": " .. tostring(why))
      local entry = ignored and baseline:ignored_fingerprint("nested") or baseline:read("nested")
      assert(entry and entry.kind == "unsupported", "nested repository stays unsupported")
      local manifest = baseline:manifest()
      for _, entries in ipairs({ manifest.paths, manifest.ignored }) do
        for _, item in ipairs(entries) do
          local path = baseline_module._internal.decode_hex(item.path_hex)
          assert(path:sub(1, 7) ~= "nested/", "nested repository contents are not captured")
        end
      end
      local reopened = assert(baseline_module.open(identity, store, baseline:id()))
      assert(reopened:manifest().baseline_hash == baseline:manifest().baseline_hash)
      local current = assert(baseline_module._internal.scan_current(identity))
      entry = (ignored and current.ignored or current.paths).nested
      assert(entry and entry.object.kind == "unsupported", "current scan accepts directory records")
      for _, entries in ipairs({ current.paths, current.ignored }) do
        for path in pairs(entries) do
          assert(path:sub(1, 7) ~= "nested/", "current scan does not traverse nested repositories")
        end
      end
      assert(git(root, "status", "--porcelain=v1", "-z") == before, "parent Git state preserved")
      assert(
        git(root .. "/nested", "status", "--porcelain=v1", "-z") == nested_before,
        "nested Git state preserved"
      )
    end
  end

  do
    local root, identity, store = fixture("staged-deletion", true, false, true)
    local before = git(root, "status", "--porcelain=v1", "-z")
    local baseline, why = baseline_module.create(identity, store)
    assert(baseline, "tracked file replaced by ignored repository: " .. tostring(why))
    assert(baseline:read("nested").kind == "unsupported")
    assert(not baseline:ignored_fingerprint("nested"), "tracked directory is not also ignored")
    assert(baseline_module.open(identity, store, baseline:id()), "replacement baseline reopens")
    local current = assert(baseline_module._internal.scan_current(identity))
    assert(current.paths.nested.object.kind == "unsupported" and not current.ignored.nested)
    assert(git(root, "status", "--porcelain=v1", "-z") == before, "staged deletion preserved")
  end

  local _, identity = fixture("invalid-records", false, false)
  for _, case in ipairs({
    { "/\0", "Git path" },
    { "../\0", "Git path" },
    { "/tmp/outside/\0", "Git path" },
    { "nested//\0", "Git path" },
    { "nested/./\0", "Git path" },
    { "nested/\0nested\0", "duplicate path" },
    { "nested\0nested/\0", "duplicate path" },
  }) do
    local probe = baseline_module._test.new({
      system = function(argv, options)
        if vim.tbl_contains(argv, "--others") and not vim.tbl_contains(argv, "--ignored") then
          return { code = 0, signal = 0, stdout = case[1], stderr = "" }
        end
        return vim.system(argv, options):wait()
      end,
    })
    local captured, why = probe.scan_current(identity)
    assert(not captured and why:find(case[2], 1, true), "unsafe directory record rejected")
  end

  local calls = 0
  local probe = baseline_module._test.new({
    system = function(argv, options)
      if vim.tbl_contains(argv, "--others") and not vim.tbl_contains(argv, "--ignored") then
        calls = calls + 1
        return {
          code = 0,
          signal = 0,
          stdout = calls == 1 and "nested/\0" or "nested\0",
          stderr = "",
        }
      end
      return vim.system(argv, options):wait()
    end,
  })
  local captured, why = probe.scan_current(identity)
  assert(
    not captured and why == "Git-visible paths changed before baseline capture completed",
    "normalization preserves directory markers for inventory race checks"
  )
end, debug.traceback)
vim.fn.delete(base, "rf")
assert(ok, err)
print("Nested Git repository baseline assertions: ok")
