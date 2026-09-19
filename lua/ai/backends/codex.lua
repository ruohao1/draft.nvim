local M = {}

local CAPABILITIES = {
  approval = false,
  busy = false,
  completion = false,
  exact_session = false,
}

local HELP_REQUIREMENTS = {
  {
    arguments = { "--help" },
    flags = { "-C", "--sandbox", "--ask-for-approval", "--add-dir" },
  },
  {
    arguments = { "resume", "--help" },
    flags = { "--last", "-C", "--sandbox", "--ask-for-approval", "--add-dir" },
  },
}

function M.new(deps)
  local adapter = {}

  local function build(identity, paths, resume)
    local validated, validation_error = deps.validate_launch(identity, paths)
    if not validated then
      return nil, validation_error
    end
    local executable, executable_error = deps.resolve_executable("codex")
    if not executable then
      return nil, executable_error
    end

    local global_home, home_error =
      deps.provider_path(paths.global_codex_home, "directory", "global Codex home")
    if home_error then
      return nil, home_error
    end

    local inputs, config_seed = {}, nil
    if global_home then
      for _, name in ipairs({ "auth.json" }) do
        local input, input_error = deps.read_only_input(
          global_home .. "/" .. name,
          name,
          "file",
          validated.backend_state,
          "global Codex " .. name
        )
        if input_error then
          return nil, input_error
        end
        if input then
          inputs[#inputs + 1] = input
        end
      end
      local config_error
      config_seed, config_error =
        deps.provider_path(global_home .. "/config.toml", "file", "global Codex config.toml")
      if config_error then
        return nil, config_error
      end
    end

    local argv = { executable }
    if resume then
      vim.list_extend(argv, { "resume", "--last" })
    end
    vim.list_extend(argv, {
      "-C",
      validated.root,
      "--sandbox",
      "workspace-write",
      "--ask-for-approval",
      "on-request",
    })
    deps.append_grants(argv, validated.grants)

    local protected_paths = { executable }
    if global_home then
      protected_paths[#protected_paths + 1] = global_home
    end
    table.sort(protected_paths)

    return {
      kind = "direct",
      backend = "codex",
      argv = argv,
      env = { CODEX_HOME = validated.backend_state },
      session = "last",
      capabilities = vim.deepcopy(CAPABILITIES),
      read_only_inputs = inputs,
      config_seed = config_seed,
      protected_paths = protected_paths,
    }
  end

  function adapter:new_session(identity, paths)
    return build(identity, paths, false)
  end

  function adapter:resume_session(identity, paths, session)
    if session ~= "last" then
      return nil, "Codex resume session must be exactly 'last'"
    end
    return build(identity, paths, true)
  end

  function adapter:format_context(context)
    return deps.format_context(context)
  end

  function adapter:capabilities()
    return vim.deepcopy(CAPABILITIES)
  end

  function adapter:session_reference(launch)
    return type(launch) == "table" and launch.session == "last" and "last" or ""
  end

  function adapter:suspend()
    return { signal = 1, timeout = 2000 }
  end

  function adapter:stop()
    return { signal = 15, timeout = 2000 }
  end

  function adapter:health()
    return deps.health_backend("codex", CAPABILITIES, HELP_REQUIREMENTS)
  end

  return adapter
end

return M
