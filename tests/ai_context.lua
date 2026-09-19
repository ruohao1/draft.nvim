local function eq(actual, expected, label)
  assert(vim.deep_equal(actual, expected), label .. "\n" .. vim.inspect(actual))
end

local context_module = require("ai.context")
local identity = { key = string.rep("a", 32), root = "/work/repo" }
local buffers = {}
local fixture = assert(vim.uv.fs_mkdtemp("/tmp/nvim-ai-context-XXXXXX"))
assert(vim.uv.fs_chmod(fixture, 448))
local function read_bytes(path)
  local fd = assert(vim.uv.fs_open(path, "r", 0))
  local bytes = assert(vim.uv.fs_read(fd, assert(vim.uv.fs_fstat(fd)).size, 0))
  assert(vim.uv.fs_close(fd))
  return bytes
end
local function new_store(suffix, overrides)
  return assert(require("ai.state")._test.open(vim.tbl_extend("force", {
    identity = vim.tbl_extend("force", identity, { namespace = "context-test" }),
    uid = vim.uv.getuid(),
    runtime_base = fixture .. "/run-" .. suffix,
    state_base = fixture .. "/state-" .. suffix,
  }, overrides or {})))
end
local function buffer(name, lines, buftype)
  local bufnr = vim.api.nvim_create_buf(false, true)
  buffers[#buffers + 1] = bufnr
  vim.bo[bufnr].buftype = buftype or ""
  if name then
    vim.api.nvim_buf_set_name(bufnr, name)
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or { "" })
  return bufnr
end

local ok, err = xpcall(function()
  local bufnr =
    buffer("/work/repo/lua/main.lua", { "local café = 1", "\talpha beta", "return café" })
  local context = assert(context_module.new())
  eq(context:location(identity, bufnr, { 1, 7 }), {
    kind = "location",
    path = "lua/main.lua",
    line = 1,
    column = 8,
  }, "normal context is root-relative and uses a one-based byte column")
  eq(
    context_module.location(identity, bufnr, { 1, 7 }),
    context:location(identity, bufnr, { 1, 7 }),
    "pure location helper has the same interface"
  )
  local unnamed = buffer(nil, { "unsaved secret" })
  assert(not context:location(identity, unnamed, { 1, 0 }), "unnamed normal context is refused")
  local nonfile = buffer("/work/repo/messages", { "not a file" }, "nofile")
  assert(not context:location(identity, nonfile, { 1, 0 }), "non-file normal context is refused")
  local outside = buffer("/work/other.lua", { "outside" })
  assert(
    not context:location(identity, outside, { 1, 0 }),
    "normal context cannot escape the pinned root"
  )

  local writes = {}
  local sequence = 98
  context = assert(context_module._test.new({
    write_private = function(name, bytes)
      writes[#writes + 1] = { name = name, bytes = bytes, mode = 384 }
      return "/run/ai/context/" .. name
    end,
    unlink = function()
      return true
    end,
    nonce = function()
      sequence = sequence + 1
      return "77_" .. sequence
    end,
    getregion = vim.fn.getregion,
    getregionpos = vim.fn.getregionpos,
  }))
  local function select(source, first, last, mode, inclusive)
    return assert(context:selection(identity, source, {
      first = { source, first[1], first[2], first[3] or 0 },
      last = { source, last[1], last[2], last[3] or 0 },
      mode = mode,
      inclusive = inclusive ~= false,
    }))
  end
  local prior_literal_value = vim.env.ISQ_CONTEXT_TEST_LITERAL
  vim.env.ISQ_CONTEXT_TEST_LITERAL = "synthetic-sensitive-value"
  local literal = buffer("/work/repo/$ISQ_CONTEXT_TEST_LITERAL.lua", { "literal" })
  local literal_location = context:location(identity, literal, { 1, 0 })
  vim.env.ISQ_CONTEXT_TEST_LITERAL = prior_literal_value
  eq(
    assert(literal_location).path,
    "%24ISQ_CONTEXT_TEST_LITERAL.lua",
    "literal source names never expand inherited environment variables"
  )
  local selected = select(bufnr, { 1, 7 }, { 1, 10 }, "v")
  eq(writes[#writes].bytes, "café", "characterwise UTF-8 is byte-exact")
  eq(selected, {
    kind = "selection",
    path = "lua/main.lua",
    first = 1,
    last = 1,
    context_file = "/run/ai/context/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-77_99.txt",
  }, "selection metadata contains only its source and private reference")
  select(bufnr, { 1, 1 }, { 2, 1 }, "V")
  eq(
    writes[#writes].bytes,
    "local café = 1\n\talpha beta\n",
    "linewise selection retains its final newline"
  )
  select(bufnr, { 2, 2 }, { 3, 6 }, "\22")
  eq(
    writes[#writes].bytes,
    "   a\nn ca",
    "block selection follows Neovim virtual columns across a partial tab"
  )
  local block = buffer("/work/repo/block.txt", { "\talpha beta", "12345678omega" })
  select(block, { 1, 2 }, { 2, 13 }, "\22")
  eq(writes[#writes].bytes, "alpha\nomega", "aligned block selects both full words")
  select(bufnr, { 1, 7 }, { 1, 10 }, "v", false)
  eq(writes[#writes].bytes, "caf", "exclusive multibyte endpoint is omitted")
  select(bufnr, { 1, 10 }, { 1, 7 }, "v")
  eq(writes[#writes].bytes, "café", "reversed marks preserve selected bytes")
  local special = buffer(
    "/work/repo/p%\t\n\r\27é.txt",
    { "e\204\129é", "'quote' $(shell); `syntax`\t\27[31m\0end" }
  )
  local escaped = select(special, { 1, 1 }, { 2, 1 }, "V")
  eq(
    escaped.path,
    "p%25%09%0A%0D%1B%C3%A9.txt",
    "source labels encode every unsafe byte, including percent itself"
  )
  eq(
    writes[#writes].bytes,
    "e\204\129é\n'quote' $(shell); `syntax`\t\27[31m\0end\n",
    "combining characters, shell syntax, controls and embedded NUL remain exact private bytes"
  )
  select(special, { 1, 1 }, { 1, 1 }, "v")
  eq(writes[#writes].bytes, "e\204\129", "combining sequence follows its selected base character")
  select(special, { 1, 4 }, { 1, 4 }, "v")
  eq(writes[#writes].bytes, "é", "multibyte final character is complete")

  local physical_root = fixture .. "/repo"
  local physical_outside = fixture .. "/outside"
  assert(vim.uv.fs_mkdir(physical_root, 448))
  assert(vim.uv.fs_mkdir(physical_outside, 448))
  assert(vim.uv.fs_symlink(physical_outside, physical_root .. "/link"))
  local linked_buffer = buffer(physical_root .. "/link/new/file.txt", { "outside secret" })
  local physical_identity = { key = identity.key, root = physical_root }
  assert(
    not context:location(physical_identity, linked_buffer, { 1, 0 }),
    "unsaved file through a symlinked parent cannot escape the physical root"
  )
  assert(
    not context:selection(
      physical_identity,
      linked_buffer,
      { first = { linked_buffer, 1, 1, 0 }, last = { linked_buffer, 1, 1, 0 }, mode = "v" }
    ),
    "visual file selection uses the same physical boundary"
  )
  local new_buffer = buffer(physical_root .. "/new/file.txt", { "new file" })
  eq(
    assert(context:location(physical_identity, new_buffer, { 1, 0 })).path,
    "new/file.txt",
    "unsaved file under physical root is allowed"
  )
  selected = select(unnamed, { 1, 1 }, { 1, 7 }, "v")
  eq(selected.path, "[No Name]", "explicit unnamed selection is allowed")
  eq(writes[#writes].bytes, "unsaved", "only explicit unnamed bytes are copied")
  selected = select(nonfile, { 1, 1 }, { 1, 3 }, "v")
  eq(selected.path, "messages", "non-file source is a bounded label")
  assert(
    not context:selection(
      identity,
      outside,
      { first = { outside, 1, 1, 0 }, last = { outside, 1, 3, 0 }, mode = "v" }
    ),
    "file selection outside root is refused"
  )
  for _, write in ipairs(writes) do
    assert(
      write.name:match("^" .. identity.key .. "%-77_%d+%.txt$"),
      "filename contains no source bytes"
    )
    eq(write.mode, 384, "selection file mode is private")
  end

  local store = new_store("private")
  local name = identity.key .. "-native.txt"
  assert(
    not store:prune_contexts(store:runtime_dir() .. "/contexts/" .. name),
    "replacement cannot retain a nonexistent context directory"
  )
  local bytes = "'quoted' $(no shell)\n\t\27[31msecret\0\n"
  local file = assert(store:write_context(name, bytes))
  eq(read_bytes(file), bytes, "private storage preserves all bytes")
  local stat = assert(vim.uv.fs_lstat(file))
  eq(
    { stat.type, stat.mode % 512, stat.nlink },
    { "file", 384, 1 },
    "context is an exclusive nonsymlink 0600 file"
  )
  eq(vim.uv.fs_stat(vim.fs.dirname(file)).mode % 512, 448, "context directory is private")
  assert(not store:write_context(name, "replacement"), "context collision is refused")
  eq(read_bytes(file), bytes, "collision never overwrites the earlier context")
  local collision_syncs = 0
  local collision_store = new_store("private", {
    fs_fsync = function(fd)
      collision_syncs = collision_syncs + 1
      if collision_syncs == 2 then
        return nil, "injected collision fsync failure"
      end
      return vim.uv.fs_fsync(fd)
    end,
  })
  assert(not collision_store:write_context(name, "replacement"))
  eq(read_bytes(file), bytes, "collision plus fsync failure never deletes someone else's context")
  local unprintable_store = new_store("c1-\194\133")
  assert(
    not unprintable_store:write_context(name, bytes),
    "unprintable private reference is rejected before publishing content"
  )
  assert(
    not vim.uv.fs_lstat(unprintable_store:runtime_dir() .. "/contexts"),
    "invalid reference creates no private payload"
  )
  assert(not store:write_context("../escape.txt", bytes), "context name is constrained")
  assert(
    not store:write_context(string.rep("b", 32) .. "-other.txt", bytes),
    "context is tied to its companion"
  )
  local maximum = string.rep("a", 4 * 1024 * 1024)
  local large = assert(store:write_context(identity.key .. "-large.txt", maximum))
  eq(
    assert(vim.uv.fs_stat(large)).size,
    #maximum,
    "context limit is independent of the smaller JSON limit"
  )
  assert(
    not store:write_context(identity.key .. "-oversized.txt", maximum .. "a"),
    "oversized context is rejected"
  )
  local link = vim.fs.dirname(file) .. "/" .. identity.key .. "-link.txt"
  assert(vim.uv.fs_symlink(file, link))
  assert(not store:write_context(vim.fs.basename(link), bytes), "symlink destination is refused")
  assert(not store:remove_context(link), "cleanup refuses symlink context")
  assert(vim.uv.fs_unlink(link))
  assert(
    not store:remove_context(fixture .. "/unrelated"),
    "cleanup cannot leave the companion context directory"
  )
  assert(store:remove_context(large))
  assert(not vim.uv.fs_lstat(large))
  local native = context_module.new({ store = store })
  local native_context = assert(
    native:selection(
      identity,
      bufnr,
      { first = { bufnr, 1, 7, 0 }, last = { bufnr, 1, 10, 0 }, mode = "v" }
    )
  )
  eq(
    read_bytes(native_context.context_file),
    "café",
    "production context uses the real private state store"
  )
  assert(
    not vim.uv.fs_lstat(file),
    "new publication supersedes contexts from an earlier editor instance"
  )
  local prepared = assert(native:prepare({
    identity = identity,
    bufnr = bufnr,
    marks = { first = { bufnr, 1, 7, 0 }, last = { bufnr, 1, 10, 0 }, mode = "v" },
    adapter = assert(require("ai.backends").get("claude")),
  }))
  eq(
    prepared.text,
    "Use the exact selection from lua/main.lua:1-1 stored at " .. prepared.file .. ": ",
    "paste is only a short reference, without a submit byte"
  )
  assert(not prepared.text:find("café", 1, true), "selection content never enters the paste")
  assert(
    not vim.uv.fs_lstat(native_context.context_file),
    "success supersedes the previous selection"
  )
  assert(native:consumed("/unrelated/file"))
  eq(read_bytes(prepared.file), "café", "unproven consumption retains the current context")
  assert(native:consumed(prepared.file))
  assert(not vim.uv.fs_lstat(prepared.file), "matching structured consumption removes the context")
  assert(native:consumed(prepared.file), "duplicate consumption is harmless")
  local mounted_directory = vim.fs.dirname(prepared.file)
  local mounted_inode = assert(vim.uv.fs_stat(mounted_directory)).ino
  for _, backend in ipairs({ "codex", "claude", "opencode" }) do
    local location = assert(native:prepare({
      identity = identity,
      bufnr = bufnr,
      cursor = { 1, 7 },
      adapter = assert(require("ai.backends").get(backend)),
    }))
    eq(location, {
      text = "Regarding lua/main.lua:1:8: ",
      metadata = { kind = "location", path = "lua/main.lua", line = 1, column = 8 },
    }, "every real adapter formats normal context without copying content")
    eq(
      assert(
        vim.uv.fs_stat(mounted_directory),
        "live sandbox context directory must survive location preparation"
      ).ino,
      mounted_inode,
      "normal preparation preserves the sandbox mount inode"
    )
  end
  local retained = assert(
    native:selection(
      identity,
      bufnr,
      { first = { bufnr, 1, 7, 0 }, last = { bufnr, 1, 10, 0 }, mode = "v" }
    )
  )
  for _, unsafe in ipairs({
    "",
    "\r",
    "\n",
    "\0",
    "\t",
    "\27",
    "\127",
    "\194\133",
    "\155",
    string.rep("x", 2049),
  }) do
    assert(not native:prepare({
      identity = identity,
      bufnr = bufnr,
      marks = { first = { bufnr, 1, 7, 0 }, last = { bufnr, 1, 10, 0 }, mode = "v" },
      adapter = {
        format_context = function()
          return unsafe
        end,
      },
    }), "unsafe formatted reference is refused")
    eq(
      read_bytes(retained.context_file),
      "café",
      "formatting failure retains the previous selection"
    )
    eq(
      #vim.fn.glob(vim.fs.dirname(retained.context_file) .. "/*", false, true),
      1,
      "formatting failure removes only its unpublished context"
    )
  end
  assert(native:supersede())
  eq(
    assert(
      vim.uv.fs_stat(mounted_directory),
      "live sandbox context directory must survive supersession"
    ).ino,
    mounted_inode,
    "supersession preserves the sandbox mount inode"
  )
  assert(
    not vim.uv.fs_lstat(retained.context_file),
    "explicit supersession removes unconsumed context"
  )
  retained = assert(
    native:selection(
      identity,
      bufnr,
      { first = { bufnr, 1, 7, 0 }, last = { bufnr, 1, 10, 0 }, mode = "v" }
    )
  )
  assert(native:cleanup())
  assert(
    not vim.uv.fs_lstat(retained.context_file),
    "pane-close cleanup removes unconsumed context"
  )
  assert(native:cleanup(), "cleanup is idempotent")
  eq(
    assert(vim.uv.fs_stat(mounted_directory)).ino,
    mounted_inode,
    "context-manager cleanup is safe while a sandbox still holds its mount"
  )

  local published, fail_write, fail_remove, order = {}, false, nil, {}
  local counter = 0
  local fault_context = context_module._test.new({
    nonce = function()
      counter = counter + 1
      return "fault" .. counter
    end,
    write_private = function(leaf, payload)
      if fail_write then
        return nil, "selected-secret must not become a diagnostic"
      end
      local path = "/run/context/" .. leaf
      published[path] = payload
      order[#order + 1] = "write:" .. path
      return path
    end,
    unlink = function(path)
      order[#order + 1] = "remove:" .. path
      if fail_remove == path or fail_remove == "all" then
        return nil
      end
      published[path] = nil
      return true
    end,
  })
  local fault_marks = { first = { bufnr, 1, 7, 0 }, last = { bufnr, 1, 10, 0 }, mode = "v" }
  local previous = assert(fault_context:selection(identity, bufnr, fault_marks)).context_file
  fail_write = true
  local missing, diagnostic = fault_context:selection(identity, bufnr, fault_marks)
  assert(
    not missing and not diagnostic:find("selected-secret", 1, true),
    "writer failure is sanitized"
  )
  eq(published[previous], "café", "writer failure leaves previous context intact")
  fail_write = false
  fail_remove = previous
  assert(
    not fault_context:selection(identity, bufnr, fault_marks),
    "failed supersession is not returned for paste"
  )
  eq(vim.tbl_keys(published), { previous }, "failed supersession rolls back its new file")
  fail_remove = "all"
  assert(
    not fault_context:selection(identity, bufnr, fault_marks),
    "rollback cleanup can fail closed"
  )
  local before = counter
  assert(
    not fault_context:selection(identity, bufnr, fault_marks),
    "unresolved rollback blocks more publications"
  )
  eq(counter, before, "failed cleanup does not accumulate private selections")
  fail_remove = nil
  assert(fault_context:cleanup())
  eq(published, {}, "cleanup retries both retained and rolled-back context")
  previous = assert(fault_context:selection(identity, bufnr, fault_marks)).context_file
  order = {}
  local replacement = assert(fault_context:selection(identity, bufnr, fault_marks)).context_file
  eq(
    order,
    { "write:" .. replacement, "remove:" .. previous },
    "new context is published before the old context is removed"
  )
  fail_remove = replacement
  assert(not fault_context:consumed(replacement), "failed consumption cleanup remains retryable")
  fail_remove = nil
  assert(fault_context:consumed(replacement))
  eq(published, {}, "consumption cleanup retry removes the retained file")

  local thrown_attempts, thrown_payloads = 0, {}
  local throwing = context_module._test.new({
    nonce = function()
      return "throw"
    end,
    write_private = function(leaf, payload)
      thrown_attempts = thrown_attempts + 1
      thrown_payloads[leaf] = payload
      error("post-publication selected-secret")
    end,
    cleanup_all = function()
      thrown_payloads = {}
      return true
    end,
  })
  local thrown_result, thrown_error = throwing:selection(identity, bufnr, fault_marks)
  assert(
    not thrown_result and not thrown_error:find("selected-secret", 1, true),
    "post-publication writer exception is sanitized"
  )
  assert(
    not throwing:selection(identity, bufnr, fault_marks),
    "writer exceptions block more publication"
  )
  eq(thrown_attempts, 1, "thrown publication never retries before cleanup")
  assert(not throwing:prepare({
    identity = identity,
    bufnr = bufnr,
    cursor = { 1, 0 },
    adapter = assert(require("ai.backends").get("claude")),
  }), "uncertain writer also blocks normal transfer")
  assert(throwing:cleanup())
  eq(
    thrown_payloads,
    {},
    "store cleanup recovers a file whose writer threw before returning its path"
  )
  assert(not throwing:selection(identity, bufnr, fault_marks))
  eq(thrown_attempts, 2, "successful cleanup releases the thrown-publication gate")
  assert(throwing:cleanup())

  local original_buffer = vim.api.nvim_get_current_buf()
  local invalid_positions = context_module._test.new({
    nonce = function()
      return "invalid"
    end,
    write_private = function()
      error("invalid extraction must not publish")
    end,
    getregionpos = function()
      return { false }
    end,
  })
  local did_not_throw, invalid =
    pcall(invalid_positions.selection, invalid_positions, identity, bufnr, fault_marks)
  assert(did_not_throw and not invalid, "malformed region positions fail closed without throwing")
  eq(
    vim.api.nvim_get_current_buf(),
    original_buffer,
    "extraction restores the editor's current buffer"
  )
  local before_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local before_tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local before_modified = vim.bo[bufnr].modified
  local registers = { vim.fn.getreginfo('"'), vim.fn.getreginfo("0") }
  assert(fault_context:selection(identity, bufnr, fault_marks))
  eq(
    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
    before_lines,
    "context never edits source buffers"
  )
  eq(
    { vim.api.nvim_buf_get_changedtick(bufnr), vim.bo[bufnr].modified },
    { before_tick, before_modified },
    "context never saves or clears unsaved state"
  )
  eq(
    { vim.fn.getreginfo('"'), vim.fn.getreginfo("0") },
    registers,
    "context never yanks into editor registers"
  )
  local boundary = buffer(nil, { maximum })
  local boundary_marks =
    { first = { boundary, 1, 1, 0 }, last = { boundary, 1, #maximum, 0 }, mode = "v" }
  assert(
    fault_context:selection(identity, boundary, boundary_marks),
    "exactly 4 MiB of selected bytes is accepted"
  )
  boundary_marks.mode = "V"
  assert(
    not fault_context:selection(identity, boundary, boundary_marks),
    "linewise final newline counts toward the 4 MiB limit"
  )
  assert(fault_context:cleanup())

  local reached_extraction = false
  local bounded = context_module._test.new({
    getregion = function()
      reached_extraction = true
      return {}
    end,
  })
  assert(
    not bounded:selection(
      identity,
      bufnr,
      { first = { bufnr, 1, 1, 0 }, last = { bufnr, 1, 1, 2147483647 }, mode = "\22" }
    )
  )
  assert(
    not reached_extraction,
    "unbounded virtual offsets are rejected before allocating selected text"
  )
  local renamed = buffer("/work/repo/before.lua", { "explicit" })
  local rename_context = context_module._test.new({
    nonce = function()
      return "renamed"
    end,
    write_private = function()
      return "/run/context/" .. identity.key .. "-renamed.txt"
    end,
    unlink = function()
      return true
    end,
    getregion = function(first, last, opts)
      local result = vim.fn.getregion(first, last, opts)
      vim.api.nvim_buf_set_name(renamed, "/work/outside/after.lua")
      return result
    end,
  })
  assert(
    not rename_context:selection(
      identity,
      renamed,
      { first = { renamed, 1, 1, 0 }, last = { renamed, 1, 2, 0 }, mode = "v" }
    ),
    "source identity is revalidated after entering the buffer"
  )

  local fsync_calls = 0
  local failed_store = new_store("fsync", {
    fs_fsync = function(fd)
      fsync_calls = fsync_calls + 1
      if fsync_calls == 2 then
        return nil, "injected directory fsync failure"
      end
      return vim.uv.fs_fsync(fd)
    end,
  })
  local failed_file = failed_store:runtime_dir() .. "/contexts/" .. name
  assert(not failed_store:write_context(name, bytes), "directory fsync failure rejects publication")
  assert(not vim.uv.fs_lstat(failed_file), "failed publication removes only the file it created")
  local uncertain_syncs, refuse_cleanup = 0, true
  local uncertain_store = new_store("uncertain", {
    fs_fsync = function(fd)
      uncertain_syncs = uncertain_syncs + 1
      if uncertain_syncs == 2 then
        return nil, "injected directory fsync failure"
      end
      return vim.uv.fs_fsync(fd)
    end,
    fs_unlink = function(path)
      if refuse_cleanup and vim.fs.basename(path):match("^[a-f0-9]+%-.*%.txt$") then
        return nil, "injected rollback failure"
      end
      return vim.uv.fs_unlink(path)
    end,
  })
  local uncertain_context = context_module.new({ store = uncertain_store })
  assert(
    not uncertain_context:selection(identity, bufnr, fault_marks),
    "uncertain real publication is refused"
  )
  local uncertain_files = vim.fn.glob(uncertain_store:runtime_dir() .. "/contexts/*", false, true)
  eq(#uncertain_files, 1, "failed native rollback retains its one owned file for cleanup")
  refuse_cleanup = false
  assert(
    not uncertain_context:selection(identity, bufnr, fault_marks),
    "uncertain native publication blocks more transfers until explicit cleanup"
  )
  eq(
    vim.fn.glob(uncertain_store:runtime_dir() .. "/contexts/*", false, true),
    uncertain_files,
    "blocked native publication does not create more contexts"
  )
  assert(uncertain_context:cleanup())
  assert(
    uncertain_context:selection(identity, bufnr, fault_marks),
    "successful cleanup releases the publication gate"
  )
  assert(uncertain_context:cleanup())
  assert(store:cleanup_contexts())
end, debug.traceback)

for _, bufnr in ipairs(buffers) do
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end
assert(vim.fn.delete(fixture, "rf") == 0, "remove only the owned context test fixture")
assert(ok, err)
print("AI context assertions: ok")
