# claude-reviewer.nvim

A lightweight, zero-dependency Neovim plugin that intercepts standalone **Claude Code** file modifications from external terminal panes (like tmux, CMUX, or Alacritty) and forces a native side-by-side Neovim diff review *before* any changes are written to your disk.

## Why this exists

If you run Claude Code inside a Neovim terminal toggle pane, accidentally closing Neovim (like spamming `:q`) kills the parent process, completely destroying your AI chat history and context.

Running Claude Code externally in a dedicated tmux or CMUX tab prevents this context loss, but you lose the safe visual diff review—Claude writes directly to disk. **`claude-reviewer.nvim` bridges this gap.** It uses Claude Code's global lifecycle hooks and Neovim's RPC architecture to pipe external edits back into your live editor session for explicit approval.

---

## Features

* **Zero-Configuration Setup:** Automatically configures Claude's global `settings.json` hooks and permissions on startup.
* **Context Protection:** Keep your Claude terminal in a separate pane. Close or crash Neovim completely without losing your AI chat state.
* **Native Engine:** Review code side-by-side inside your exact editor environment with **zero external dependencies** required.

---

## Installation

Choose the installation snippet that matches your preferred Neovim package manager. The plugin automatically handles permissions and injects the necessary hooks into Claude's global configuration on launch.

### 1. Using lazy.nvim

```lua
return {
  {
    "johnkingkong/claude-reviewer.nvim",
    lazy = false,
    config = function()
      require("claude-reviewer").setup({
        keymaps = {
          approve = "<leader>ca", -- Approve the edit
          deny = "<leader>cd",    -- Reject and block the edit
        }
      })
    end,
  }
}
```

### 2. Using vim-plug

```vim
" In your init.vim or inside a lua << EOF block
Plug 'johnkingkong/claude-reviewer.nvim'

" Call the setup function in your Lua initialization
lua require('claude-reviewer').setup()
```

### 3. Using pckr.nvim

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

### 4. Using mini.deps

```lua
local MiniDeps = require('mini.deps')

MiniDeps.add({
  source = 'johnkingkong/claude-reviewer.nvim',
})

require('claude-reviewer').setup()
```

---

## Configuration Options

You can pass an optional table to the `setup()` function to customize your keymaps:

```lua
require('claude-reviewer').setup({
  keymaps = {
    approve = "<leader>ca", -- Keymap to accept changes and let Claude proceed
    deny = "<leader>cd",    -- Keymap to abort changes and block Claude
  }
})
```

---

## Environment Requirements

Because your terminal and Neovim instances are completely separated, they communicate over a fixed RPC Unix socket loopback file created automatically at `/tmp/nvim-claude-bridge.pipe`.

No manually exported environment variables are required; as long as Neovim is running on your machine, external Claude processes running in separate splits or tmux windows will connect seamlessly out-of-the-box.

---

## License

MIT
