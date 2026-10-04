# Install, upgrade and roll back Draft

Use one Draft installation per Neovim process. Keep the plugin checkout intact:
Lua code loads its Python helpers from that checkout's `scripts/` directory.
Remove an old embedded `lua/ai` copy from the runtime path before using the plugin.

## Choose an available version

| Version | Availability | Matching managed OpenCode |
| --- | --- | --- |
| `v0.1.0-alpha.1` (`514d9460cf09e970ba325c29fd7aadc5e2e15ba3`) | Published baseline | 1.18.30 |
| Proposed `v0.1.0-beta.1` | Local candidate; exact tested checkpoint in the [validation record](../validation/2026-10-04-linux-beta-release.md) | 1.18.34 / ACP 1 |

The candidate tag does not exist yet, and its local commit may not be fetchable
from GitHub. Test an available local checkout. Once a reviewed candidate commit
is pushed, pin that exact published commit; do not substitute an unrelated
branch tip. Keep your plugin-manager lockfile with your Neovim configuration.

For the published alpha baseline, a lazy.nvim spec can pin the exact commit:

```lua
{
  "ruohao1/draft.nvim",
  commit = "514d9460cf09e970ba325c29fd7aadc5e2e15ba3",
  config = function()
    require("draft").setup()
  end,
}
```

For a candidate that is only available locally, replace that spec with:

```lua
{
  name = "draft.nvim",
  dir = vim.fn.expand("~/src/draft.nvim"), -- your actual candidate checkout
  config = function()
    require("draft").setup()
  end,
}
```

A `dir` spec uses the files on disk; a lockfile does not pin that local checkout.
Record `git -C ~/src/draft.nvim rev-parse HEAD` before testing. Alternatively,
prepend that directory to `runtimepath` and call `require("draft").setup()` as
shown in the [README](../../README.md#install).

## Fresh installation

1. Install the [required Linux tools](../../README.md#requirements) and the
   matching OpenCode version separately. Core chat does not require tmux.
2. Add one plugin spec. Let the plugin manager install it, then restart Neovim.
   For a local checkout, confirm its commit before opening the editor.
3. Run `:checkhealth draft` and `:help draft`. Confirm the loaded module comes
   from the intended checkout with:

   ```vim
   :lua print(vim.api.nvim_get_runtime_file("lua/draft/init.lua", false)[1])
   ```

4. Open a saved text file with permissions `0644` or `0755`. Run
   `:NvimAIStageSetup`, select an available model and any required auth path,
   then choose **Save and enable**. Setup saves preferences but sends no prompt.
5. Run `:NvimAIChat`. Confirm the selected file and idle state. Send only when
   ready to use the configured provider; follow the
   [chat quickstart](../../README.md#start-with-opencode-chat).

Do not treat a health pass or idle chat as a successful provider request.

## Upgrade

1. Record your current plugin commit/spec, lockfile and OpenCode version. Preserve
   unsaved source edits and unsent drafts. Resolve pending reviews, then close
   chat with `:NvimAIChatClose` and any native companion with `:NvimAIClose`.
   Wait for confirmed cleanup. If cleanup is uncertain, follow the displayed
   recovery instructions and inspect uncertain files first.
2. Quit the old editor before replacing plugin/helper code. For a Git checkout,
   select the desired available revision while Neovim is closed. For lazy.nvim,
   change the `commit` pin and run `:Lazy update draft.nvim` in a maintenance
   editor without starting Draft work; quit when the update finishes. Restart
   again before using Draft. Do not hot-reload its Lua modules.
3. Install the matching OpenCode version separately, then run `:checkhealth draft`
   in a fresh editor. Confirm the module path and saved model with
   `:NvimAIStageStatus`. Opening `:NvimAIChat` should remain idle until Send.
4. Start a new conversation for the new version. Saved source files and staging
   preferences survive; open chat context, unsent drafts and pending approval
   authority do not migrate between editor processes.

Preferences are stored at
`stdpath("state")/draft.nvim/staged/settings.json`. They contain the model, an
optional auth-file path, enabled state and prompt review mode; credentials are
not copied into that file. Retain the configured auth file separately.

An old native OpenCode companion record can require `:NvimAIClose` and confirmed
closure before `:NvimAIOpen` creates a profile for 1.18.34. Saved references may
remain for inspection. They do not grant a new conversation permission to write.

## Roll back

Use the same close, preserve and restart sequence, selecting your previously
recorded plugin commit. With lazy.nvim, restore the previous `commit` pin and run
`:Lazy update draft.nvim`, then restart. Keep the spec and lockfile consistent;
restoring the lockfile alone while retaining a new explicit pin is insufficient.

Rolling back to alpha.1 also requires its matching OpenCode 1.18.30. Do not
assume a newer OpenCode database can be opened safely by an older executable.
The passive plugin checks do not exercise a real OpenCode downgrade; arrange a
separate compatible provider profile before sending work with the old version.

Code rollback does not undo accepted project edits. Inspect and revert source
changes separately using your normal version-control workflow if needed. Keep
saved preferences, but never restore an old process/session/review-state backup
as active approval authority. Start a fresh conversation and review new proposals.

The [release validation record](../validation/2026-10-04-linux-beta-release.md)
identifies the exact fresh-install, upgrade and rollback checks, including which
checks use fixtures and which do not launch a provider.
