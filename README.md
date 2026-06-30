# claude-reviewer.nvim

A lightweight Neovim plugin that intercepts standalone **Claude Code** file modifications from external terminal panes (like tmux, CMUX, or Alacritty) and forces a native side-by-side Neovim diff review *before* any changes are written to your disk.

## Why this exists

If you run Claude Code inside a Neovim terminal toggle pane, accidentally closing Neovim (like spamming `:q`) kills the parent process, completely destroying your AI chat history and context.

Running Claude Code externally in a dedicated tmux or CMUX tab prevents this context loss, but you lose the safe visual diff review—Claude writes directly to disk. **`claude-reviewer.nvim` bridges this gap.** It uses Claude Code's global lifecycle hooks and Neovim's RPC architecture to pipe external edits back into your live editor session for explicit approval.

---

## Features

* **Zero-Configuration Setup:** Automatically configures Claude's global `settings.json` hooks and permissions on startup.
* **Context Protection:** Keep your Claude terminal in a separate pane. Close or crash Neovim completely without losing your AI chat state.
* **Native Diff Engine:** Review code side-by-side inside your exact editor environment, using your existing color schemes and configurations.

---

## Installation

Install the plugin using **lazy.nvim**. The plugin will automatically configure everything else out-of-the-box on launch.

```lua
return {
  {
    "your-github-username/claude-reviewer.nvim",
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

---

## Environment Requirements

Because your terminal and Neovim instances are completely separated, the bridge script needs to find your active Neovim session.

Ensure your terminal multiplexer configuration or shell profiles expose the **`$NVIM_LISTEN_ADDRESS`** or **`$NVIM`** environment variable across your target splits/panes.

---

## License

MIT
