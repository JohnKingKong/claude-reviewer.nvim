# claude-reviewer.nvim

A lightweight Neovim plugin that intercepts **Claude Code** file edits and forces a native side-by-side diff review in Neovim *before* any changes are written to disk.

## Why this exists

Running Claude Code inside a Neovim terminal toggle means accidentally closing Neovim (`:q` spam) kills the Claude process and destroys your entire session context.

Running Claude Code in a separate terminal (tmux, CMUX, Alacritty) protects your session — but you lose visual diff review and Claude writes directly to disk.

**`claude-reviewer.nvim` bridges this gap.** It hooks into Claude Code's permission system and pipes every proposed file edit back into your live Neovim session for explicit approval, with no external dependencies.

---

## How it works

1. Claude Code fires a `PermissionRequest` hook before every `Edit` or `Write`
2. The hook script (`claude-nvim-bridge`) finds your Neovim instance for the current workspace via a socket file
3. Neovim opens the diff in a new tab — side by side, using its native diff engine
4. You approve with `<leader>ca` or deny with `<leader>cd`
5. Claude Code receives the decision and proceeds (or stops)

**If no Neovim is open for the workspace**, the bridge exits cleanly and Claude Code falls back to its own built-in permission UI — no hanging, no auto-deny.

**If you accept or deny in Claude Code's UI while the diff is open in Neovim**, the diff closes automatically.

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

The plugin has two components:

**`bin/claude-nvim-bridge`** — a bash script registered as a Claude Code `PermissionRequest` hook. On every `Edit`/`Write`:
- Looks up the workspace's Neovim socket from `/tmp/claude-nvim-cwd-<hash>.txt`
- If found, sends an RPC to Neovim and waits for the decision (5-minute timeout)
- If not found, exits 0 so Claude Code shows its own UI
- Creates an "alive" sentinel file that Neovim polls; removing it on exit signals Neovim to close any open diff

**`lua/claude-reviewer/init.lua`** — the Neovim plugin:
- Writes a workspace socket file at startup (keyed by cwd hash and git root)
- Cleans up its socket files on exit
- Exposes `start_review()` as an RPC entry point that opens the diff tab, sets up keymaps, and polls for the alive sentinel file

The hook and settings injection into `~/.claude/settings.json` happen automatically on `setup()`.

---

## License

MIT
