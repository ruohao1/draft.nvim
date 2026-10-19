-- Passive RPC observation for the pinned, opt-in study; never a filesystem writer.
local M = {}

function M.install(opts)
  local server = require("claudecode.server")
  local request_handler, response_sender = server._handle_request, server.send_response
  local sequence, pending = 0, {}
  local observer = { errors = {} }
  local root = vim.fs.normalize(opts.root) .. "/"
  local file = vim.fs.normalize(opts.file)
  assert(file:sub(1, #root) == root, "checkpoint file must be inside fixture")

  local function relative(path)
    if type(path) ~= "string" then
      return nil
    end
    path = vim.fs.normalize(path)
    return path:sub(1, #root) == root and path:sub(#root + 1) or "[outside fixture]"
  end

  local function bytes(text, label)
    local name = string.format("%04d-%s.bin", sequence, label)
    local handle = assert(io.open(opts.output .. "/" .. name, "wb"))
    assert(handle:write(text))
    assert(handle:close())
    return { length = #text, sha256 = vim.fn.sha256(text), snapshot = name }
  end

  local function checkpoint(kind, fields)
    sequence = sequence + 1
    local event = vim.deepcopy(fields or {})
    event.origin = "nvim"
    event.sequence = sequence
    event.monotonic_ns = vim.uv.hrtime()
    event.kind = kind
    local stat, err, code = vim.uv.fs_stat(file)
    assert(stat or code == "ENOENT", err)
    event.file = { path = relative(file), exists = stat ~= nil }
    if stat then
      local handle = assert(io.open(file, "rb"))
      local text = assert(handle:read("*a"))
      assert(handle:close())
      event.file = bytes(text, "source")
      event.file.path = relative(file)
      event.file.exists = true
      event.file.device, event.file.inode = stat.dev, stat.ino
    end
    for _, label in ipairs({ "proposal", "accepted" }) do
      if event[label] then
        event[label] = bytes(event[label], label)
      end
    end
    local output = assert(io.open(opts.output .. "/events.jsonl", "ab"))
    assert(output:write(vim.json.encode(event) .. "\n"))
    assert(output:close())
  end

  -- Observation failure invalidates the run without suppressing the original RPC.
  function observer.checkpoint(kind, fields)
    local ok, err = pcall(checkpoint, kind, fields)
    if not ok then
      observer.errors[#observer.errors + 1] = tostring(err)
    end
  end

  server._handle_request = function(client, request)
    local params = request.params or {}
    local args = type(params.arguments) == "table" and params.arguments or {}
    local fields = {
      client = client.id,
      request_id = request.id,
      method = request.method,
      tool = params.name,
      tab_name = args.tab_name,
      old_path = relative(args.old_file_path),
      new_path = relative(args.new_file_path),
    }
    pending[client.id] = pending[client.id] or {}
    pending[client.id][request.id] = fields
    local event = vim.deepcopy(fields)
    if params.name == "openDiff" and type(args.new_file_contents) == "string" then
      event.proposal = args.new_file_contents
    end
    observer.checkpoint("request", event)
    local result = request_handler(client, request)
    if params.name == "close_tab" then
      observer.checkpoint("finalization", fields)
    end
    return result
  end

  server.send_response = function(client, id, result, error_data)
    local fields = vim.deepcopy((pending[client.id] or {})[id] or {})
    fields.client, fields.request_id = client.id, id
    fields.error_code = error_data and error_data.code or nil
    local content = type(result) == "table" and result.content or nil
    if content and content[1] then
      local status = content[1].text
      if status == "FILE_SAVED" or status == "DIFF_REJECTED" or status == "TAB_CLOSED" then
        fields.status = status
      end
      if status == "FILE_SAVED" and content[2] then
        fields.accepted = content[2].text
      end
    end
    observer.checkpoint("response_attempt", fields)
    local sent = response_sender(client, id, result, error_data)
    fields.accepted = nil
    fields.delegated_return = sent
    observer.checkpoint("response_return", fields)
    if pending[client.id] then
      pending[client.id][id] = nil
    end
    return sent
  end

  return observer
end

return M
