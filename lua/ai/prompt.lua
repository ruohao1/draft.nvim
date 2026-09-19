-- Private, single-shot OpenCode publication. HTTP credentials stay in the launcher.
local M = {}
local uv = vim.uv

function M.append(options)
  local directory = options.store:runtime_dir()
  local path = directory .. "/prompt.sock"
  local parent, before = uv.fs_lstat(directory), uv.fs_lstat(path)
  if
    #path > 107
    or uv.fs_realpath(directory) ~= directory
    or not parent
    or parent.type ~= "directory"
    or parent.uid ~= uv.getuid()
    or parent.mode % 512 ~= 448
    or not before
    or before.type ~= "socket"
    or before.uid ~= uv.getuid()
    or before.mode % 512 ~= 384
  then
    return "refused"
  end
  local token, token_error = options.store:read_control_token()
  if token_error or not token then
    return "refused"
  end
  local function same()
    local now, named = uv.fs_lstat(path), uv.fs_lstat(directory)
    return now
      and now.type == "socket"
      and now.uid == before.uid
      and now.mode == before.mode
      and now.dev == before.dev
      and now.ino == before.ino
      and named
      and named.type == "directory"
      and named.uid == parent.uid
      and named.mode == parent.mode
      and named.dev == parent.dev
      and named.ino == parent.ino
      and uv.fs_realpath(directory) == directory
      and options.current()
  end
  local connection = assert(uv.new_pipe(false))
  local done, sent, result, bytes = false, false, nil, ""
  local function finish(value)
    if done then
      return
    end
    done, result = true, value or (sent and "uncertain" or "refused")
    connection:read_stop()
    if not connection:is_closing() then
      connection:close()
    end
  end
  local connected = connection:connect(path, function(err)
    if done then
      return
    end
    if err or not same() then
      return finish()
    end
    connection:read_start(function(read_error, data)
      if done then
        return
      end
      if read_error or not data then
        return finish()
      end
      bytes = bytes .. data
      if #bytes > 256 then
        return finish()
      end
      if not bytes:find("\n", 1, true) then
        return
      end
      if sent then
        local replies = {
          ["published\n"] = "published",
          ["uncertain\n"] = "uncertain",
          ["refused\n"] = "refused",
        }
        return finish(replies[bytes])
      end
      local launch, identity, review = bytes:match("^([0-9a-f]+):([0-9a-f]+):(review_[0-9a-f]+)\n$")
      if
        not launch
        or #launch ~= 32
        or identity ~= options.identity.key
        or review ~= options.review_id
        or (options.launch and launch ~= options.launch)
        or not same()
      then
        return finish("refused")
      end
      bytes = ""
      local request = vim.json.encode({
        schema = 1,
        token = token,
        launch = launch,
        review_id = review,
        text = options.text,
      }) .. "\n"
      sent = true
      if
        not connection:write(request, function(write_error)
          if write_error then
            finish()
          end
        end)
      then
        finish()
      end
    end)
  end)
  if not connected then
    finish()
  end
  -- Keep Neovim responsive while the bounded launcher exchange is outstanding.
  vim.wait(1800, function()
    return done
  end, 5)
  finish()
  return result
end

return M
