# **claude-reviewer.nvim**

A lightweight Neovim plugin that intercepts **Claude Code** file edits and forces a native side-by-side diff review in Neovim *before* any changes are written to disk.

## Why this exists

Running Claude Code inside a Neovim terminal toggle means accidentally closing Neovim (`:q` spam) kills the Claude process and destroys your entire session context.

Running Claude Code in a separate terminal (tmux, CMUX, Alacritty) protects your session — but you lose visual diff review and Claude writes directly to disk.

**`claude-reviewer.nvim` bridges this gap.** It hooks into Claude Code before every edit and pipes the proposed change back into your live Neovim session for explicit approval. It works from any terminal, with no Neovim plugin dependencies.

---

## How it works

1. Claude Code fires a `PreToolUse` hook before every `Edit` or `Write`. The edit can't happen until the hook answers, and Claude Code hasn't shown any permission prompt yet, so nothing else can approve the edit while the diff is open: not Claude Code's own prompt, and not a terminal integration's own permission hook (cmux, for example, injects one into every session it launches).
2. The hook script (`claude-nvim-bridge`) finds the right Neovim instance, in priority order:
   - the Neovim terminal Claude is running inside (if any)
   - the CMUX workspace running that task (when running inside CMUX)
   - the nearest directory, walking up from the edited file and then from Claude's working directory, that a running Neovim has open as a tab (or that tab's git root). Registrations left behind by a crashed Neovim are skipped.

   None of these depend on the terminal, so this works the same in any terminal: Ghostty, iTerm2, Alacritty, WezTerm, kitty, tmux, CMUX, or the macOS Terminal.
3. Neovim opens the diff as a pair of floating windows overlaying the existing tab whose own directory covers the edited file — never a new tab of its own (so a workspace-per-tab setup, e.g. floo-network.nvim, never grows a phantom extra workspace) and never a split carved out of whatever else is in that tab (another file, the startup dashboard, anything — floats don't touch the tab's layout at all). If that tab isn't the one you're currently viewing, the floats are built in the background instead of stealing your focus, and a notification tells you which workspace it's waiting in.
4. You approve with `<leader>ca` (or clicking the ✅ Approve button in either pane's winbar) or deny with `<leader>cd` (or ❌ Reject). The panes render above other floating windows (e.g. a lazygit terminal) rather than tying with them, so neither pane gets stuck hidden behind one.
5. Claude Code receives the decision and proceeds (or stops).

If you edit Claude's proposed content in the diff before approving, your edits are preserved: a `PostToolUse` hook (`claude-nvim-post-bridge`) overwrites the file Claude just wrote with your version.

**If no Neovim is open for the workspace, *or* the edit is for a directory that isn't currently open as a tab in it**, the bridge exits cleanly and Claude Code falls back to its own built-in permission UI — no hanging, no auto-deny, and no tab gets created for a workspace that doesn't exist yet.

**While a diff is open, Claude Code waits for you** and shows no prompt of its own. To cancel from the Claude side, press `Esc` in Claude Code: the hook is stopped, the edit doesn't happen, and the diff in Neovim closes on its own.

---

## Requirements

- Neovim 0.10+
- Claude Code with hooks support (`PreToolUse` / `PostToolUse`)
- `python3` on your `PATH` (used by the hook scripts to read Claude Code's JSON payload)
- macOS or Linux

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

## Upgrading from an earlier version

Versions before the move to `PreToolUse` registered the review as a `PermissionRequest` hook. That could be approved out from under an open diff by anything else answering the same permission request (Claude Code's own prompt, or a terminal integration such as cmux), so edits sometimes went through while the review was still open in Neovim.

`setup()` migrates `~/.claude/settings.json` for you: it removes the old `PermissionRequest` entry and registers the `PreToolUse` one. After updating:

1. Restart Neovim, so `setup()` runs and rewrites the hooks.
2. Restart your Claude Code sessions, so they pick up the new hook.

---

## Troubleshooting

Both hook scripts and the Neovim side log every step to `/tmp/claude-reviewer-debug.log`, so a single edit can be traced end to end.

- **`no live Neovim found`**: no running Neovim has a tab whose directory (or git root) contains the edited file or Claude's working directory. Open the project as a tab, or make sure the plugin loads at startup (`lazy = false`).
- **The diff never opens but Claude Code prompts instead**: same cause. Without a matching Neovim tab, Claude Code's own permission flow takes over on purpose.
- **The diff opens in a tab you're not looking at**: reviews open in the tab whose directory covers the file, without stealing focus. A notification names the tab it's waiting in.

---

## Architecture

The plugin has four components:

**`bin/claude-nvim-bridge`** — a bash script registered as a Claude Code `PreToolUse` hook (with a 30-minute timeout). On every `Edit`/`Write`:
- Finds the right Neovim socket (shared with the post-bridge via `bin/claude-nvim-lib.sh`): the terminal Claude is running inside, then the CMUX workspace, then the nearest registered directory walking up from the edited file and Claude's cwd
- Answers with `permissionDecision: "allow"` or `"deny"`, so an approved edit goes through without a second prompt in Claude Code
- For `Edit` calls (which only carry an `old_string`/`new_string` fragment, not the full file) it reconstructs the full post-edit content so the diff shows complete before/after files
- If a socket is found, sends an RPC to Neovim and waits for the decision (30-minute timeout)
- If not found, exits 0 so Claude Code shows its own UI. Neovim can also decline after being reached — the edit's directory doesn't match any currently open tab — in which case the bridge treats it exactly the same way
- Creates an "alive" sentinel file that Neovim polls; the bridge process dying signals Neovim to close any open diff

**`bin/claude-nvim-post-bridge`** — a bash script registered as a Claude Code `PostToolUse` hook, running after Claude's write actually completes. If you edited Claude's proposed content during review, this overwrites the file Claude just wrote with your version. Either way, it also reloads any open Neovim buffer for that file — Neovim has no way to notice the on-disk change on its own, since the write happens entirely outside its event loop.

**`bin/claude-nvim-lib.sh`** — shared by both hook scripts (sourced, not registered as a hook): logging, payload parsing, and the Neovim socket lookup, so the post-bridge always reaches the same Neovim that showed the review.

**`lua/claude-reviewer/init.lua`** — the Neovim plugin:
- Writes a socket file for every open tab's own local directory (keyed by cwd hash, git root, and CMUX workspace id), not just the current one — a workspace-per-tab setup (e.g. floo-network.nvim) can have several tabs with different directories, so a single "current" snapshot would miss all but one. Registration is deferred with `vim.schedule()` so it runs after any other plugin's own startup has finished setting up its tabs, and stays fresh on `DirChanged`.
- Cleans up its socket files on exit
- Exposes `start_review()` as an RPC entry point: finds the open tab whose own directory covers the edited file and builds the diff there as a pair of floating windows (in the background, without stealing focus, if it isn't the tab you're currently viewing) — declining entirely, with no tab created, if no open tab matches. Sets up the approve/deny keymaps, and polls the bridge's liveness so the diff closes if Claude Code cancels the hook.
- Exposes `reload_buffer()` as a second RPC entry point, called by `claude-nvim-post-bridge` once Claude's write actually completes, to refresh any buffer for that file that was already open (and therefore left alive) — skipping it if it has unsaved local changes.

The hook and settings injection into `~/.claude/settings.json` happen automatically on `setup()`.

---

## License

MIT
