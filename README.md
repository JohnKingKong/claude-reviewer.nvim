# **claude-reviewer.nvim**

A lightweight Neovim plugin that intercepts **Claude Code** file edits and forces a native side-by-side diff review in Neovim *before* any changes are written to disk.

## Why this exists

Running Claude Code inside a Neovim terminal toggle means accidentally closing Neovim (`:q` spam) kills the Claude process and destroys your entire session context.

Running Claude Code in a separate terminal (tmux, CMUX, Alacritty) protects your session — but you lose visual diff review and Claude writes directly to disk.

**`claude-reviewer.nvim` bridges this gap.** It hooks into Claude Code's permission system and pipes every proposed file edit back into your live Neovim session for explicit approval, with no external dependencies.

---

## How it works

1. Claude Code fires a `PermissionRequest` hook before every `Edit` or `Write`.
2. The hook script (`claude-nvim-bridge`) finds the right Neovim instance, in priority order:
   - the Neovim terminal Claude is running inside (if any)
   - the CMUX workspace running that task
   - the current working directory (falling back to its git root)
3. Neovim opens the diff as a pair of floating windows overlaying the existing tab whose own directory covers the edited file — never a new tab of its own (so a workspace-per-tab setup, e.g. floo-network.nvim, never grows a phantom extra workspace) and never a split carved out of whatever else is in that tab (another file, the startup dashboard, anything — floats don't touch the tab's layout at all). If that tab isn't the one you're currently viewing, the floats are built in the background instead of stealing your focus, and a notification tells you which workspace it's waiting in.
4. You approve with `<leader>ca` or deny with `<leader>cd`.
5. Claude Code receives the decision and proceeds (or stops).

If you edit Claude's proposed content in the diff before approving, your edits are preserved: a `PostToolUse` hook (`claude-nvim-post-bridge`) overwrites the file Claude just wrote with your version.

**If no Neovim is open for the workspace, *or* the edit is for a directory that isn't currently open as a tab in it**, the bridge exits cleanly and Claude Code falls back to its own built-in permission UI — no hanging, no auto-deny, and no tab gets created for a workspace that doesn't exist yet.

**If you approve or deny in Claude Code's own UI while the diff is still open in Neovim**, the diff closes automatically and reports the outcome accordingly (approved vs. cancelled).

---

## Installation

> **Important:** Use `lazy = false`. The plugin must load at startup to register its workspace socket. If lazy-loaded, Neovim won't be found when Claude fires its first hook.

### lazy.nvim

```lua
return {
  {
    "johnkingkong/claude-reviewer.nvim",
    lazy = false,
    config = function()
      require("claude-reviewer").setup({
        keymaps = {
          approve = "<leader>ca",
          deny = "<leader>cd",
        }
      })
    end,
  }
}
```

### vim-plug

```vim
Plug 'johnkingkong/claude-reviewer.nvim'
```

```lua
require('claude-reviewer').setup()
```

### pckr.nvim

```lua
require('pckr').add({
  {
    'johnkingkong/claude-reviewer.nvim',
    config = function()
      require('claude-reviewer').setup()
    end
  };
})
```

### mini.deps

```lua
local MiniDeps = require('mini.deps')
MiniDeps.add({ source = 'johnkingkong/claude-reviewer.nvim' })
require('claude-reviewer').setup()
```

---

## Configuration

```lua
require('claude-reviewer').setup({
  keymaps = {
    approve = "<leader>ca", -- accept the edit and let Claude proceed
    deny = "<leader>cd",    -- reject the edit and block Claude
  }
})
```

---

## Architecture

The plugin has three components:

**`bin/claude-nvim-bridge`** — a bash script registered as a Claude Code `PermissionRequest` hook. On every `Edit`/`Write`:
- Finds the right Neovim socket: the terminal Claude is running inside, then the CMUX workspace, then the cwd/git-root hash file
- For `Edit` calls (which only carry an `old_string`/`new_string` fragment, not the full file) it reconstructs the full post-edit content so the diff shows complete before/after files
- If a socket is found, sends an RPC to Neovim and waits for the decision (30-minute timeout)
- If not found, exits 0 so Claude Code shows its own UI. Neovim can also decline after being reached — the edit's directory doesn't match any currently open tab — in which case the bridge treats it exactly the same way
- Creates an "alive" sentinel file that Neovim polls; the bridge process dying signals Neovim to close any open diff

**`bin/claude-nvim-post-bridge`** — a bash script registered as a Claude Code `PostToolUse` hook, running after Claude's write actually completes. If you edited Claude's proposed content during review, this overwrites the file Claude just wrote with your version. Either way, it also reloads any open Neovim buffer for that file — Neovim has no way to notice the on-disk change on its own, since the write happens entirely outside its event loop.

**`lua/claude-reviewer/init.lua`** — the Neovim plugin:
- Writes a socket file for every open tab's own local directory (keyed by cwd hash, git root, and CMUX workspace id), not just the current one — a workspace-per-tab setup (e.g. floo-network.nvim) can have several tabs with different directories, so a single "current" snapshot would miss all but one. Registration is deferred with `vim.schedule()` so it runs after any other plugin's own startup has finished setting up its tabs, and stays fresh on `DirChanged`.
- Cleans up its socket files on exit
- Exposes `start_review()` as an RPC entry point: finds the open tab whose own directory covers the edited file and builds the diff there as a pair of floating windows (in the background, without stealing focus, if it isn't the tab you're currently viewing) — declining entirely, with no tab created, if no open tab matches. Sets up the approve/deny keymaps, and polls the bridge's liveness and the target file's mtime to detect a decision made from Claude's own UI.
- Exposes `reload_buffer()` as a second RPC entry point, called by `claude-nvim-post-bridge` once Claude's write actually completes, to refresh any buffer for that file that was already open (and therefore left alive) — skipping it if it has unsaved local changes.

The hook and settings injection into `~/.claude/settings.json` happen automatically on `setup()`.

---

## License

MIT
