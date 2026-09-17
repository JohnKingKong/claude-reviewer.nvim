local M = {}

M.config = {
	keymaps = {
		approve = "<leader>ca",
		deny = "<leader>cd",
	},
}

local written_files = {}

local function cwd_socket_path(cwd)
	local hash = vim.fn.sha256(cwd):sub(1, 8)
	return string.format("/tmp/claude-nvim-cwd-%s.txt", hash)
end

local function cmux_socket_path(workspace_id)
	return string.format("/tmp/claude-nvim-cmux-%s.txt", workspace_id)
end

local function write_socket_file_at(path)
	local f = io.open(path, "w")
	if f then
		f:write(vim.v.servername)
		f:close()
		written_files[path] = true
	end
end

-- Also registers under the git root in case nvim was started in a subdirectory.
local function register_dir(dir)
	write_socket_file_at(cwd_socket_path(dir))

	local result = vim.fn.system({ "git", "-C", dir, "rev-parse", "--show-toplevel" })
	if vim.v.shell_error == 0 then
		local git_root = vim.trim(result)
		if git_root ~= dir then
			write_socket_file_at(cwd_socket_path(git_root))
		end
	end
end

-- Registers a socket file for every currently open tab's own local working
-- directory, not just "the current" one. Workspace-per-tab plugins (e.g.
-- floo-network.nvim) can set up several tabs with different tab-local cwds
-- during their own VeryLazy-triggered session restore. Plugin load order
-- across a shared event like VeryLazy is unspecified — a single "current
-- cwd" snapshot can miss every tab except whichever happened to be current
-- when this ran, especially if it runs before such a restore.
local function write_socket_file()
	local seen = {}
	for _, tabid in ipairs(vim.api.nvim_list_tabpages()) do
		local tabnr = vim.api.nvim_tabpage_get_number(tabid)
		local dir = vim.fn.getcwd(-1, tabnr)
		if not seen[dir] then
			seen[dir] = true
			register_dir(dir)
		end
	end

	-- Register under the CMUX workspace id, when running inside CMUX. This is
	-- the strongest signal: a workspace groups the panes for one task, so it
	-- disambiguates "same repo, unrelated task in another pane" from "same
	-- task, nvim and claude in different panes/dirs" — cwd/git-root alone
	-- can't tell those apart in a monorepo.
	local workspace_id = vim.env.CMUX_WORKSPACE_ID
	if workspace_id and workspace_id ~= "" then
		write_socket_file_at(cmux_socket_path(workspace_id))
	end
end

local function cleanup_socket_files()
	for path in pairs(written_files) do
		os.remove(path)
	end
	written_files = {}
end

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

	-- Write immediately since LazyVim loads plugins dynamically
	write_socket_file()

	-- Also defer a scan past the current tick: if another VeryLazy-loaded
	-- plugin (e.g. a workspace manager restoring several tabs/directories)
	-- hasn't run yet at the point above - which depends on unspecified
	-- cross-plugin VeryLazy ordering - its tabs won't exist yet to scan. By
	-- the time this runs, every synchronous VeryLazy handler dispatched in
	-- this tick has already completed, regardless of registration order.
	vim.schedule(write_socket_file)

	-- Also register autocmd as a fallback safety net
	vim.api.nvim_create_autocmd("VimEnter", {
		callback = write_socket_file,
	})

	-- Keep cwd socket fresh if the user changes directory inside Neovim
	vim.api.nvim_create_autocmd("DirChanged", {
		callback = write_socket_file,
	})

	-- Clean up all socket files this instance wrote on exit
	vim.api.nvim_create_autocmd("VimLeavePre", {
		callback = cleanup_socket_files,
	})

	-- 1. Dynamically find the absolute path of the bridge script inside the plugin folder
	local source = debug.getinfo(1, "S").source:sub(2)
	local plugin_root = vim.fn.fnamemodify(source, ":h:h:h")
	if not plugin_root or plugin_root == "" then
		return
	end
	local bridge_path = plugin_root .. "/bin/claude-nvim-bridge"
	local post_bridge_path = plugin_root .. "/bin/claude-nvim-post-bridge"

	-- 2. Make sure the bridge scripts are executable
	vim.fn.system({ "chmod", "+x", bridge_path })
	vim.fn.system({ "chmod", "+x", post_bridge_path })

	-- 3. Automatically inject the hook into ~/.claude/settings.json
	local settings_path = vim.fn.expand("~/.claude/settings.json")
	local settings = {}

	if vim.fn.filereadable(settings_path) == 1 then
		local f = io.open(settings_path, "r")
		if f then
			local content = f:read("*a")
			f:close()
			pcall(function()
				settings = vim.fn.json_decode(content) or {}
			end)
		end
	end

	-- Initialize required JSON structure if empty
	settings.hooks = settings.hooks or {}
	settings.hooks.PermissionRequest = settings.hooks.PermissionRequest or {}

	-- Remove any stale bridge entries left in PreToolUse from older versions
	if settings.hooks.PreToolUse then
		local cleaned = {}
		for _, item in ipairs(settings.hooks.PreToolUse) do
			local has_bridge = false
			for _, hook in ipairs(item.hooks or {}) do
				if hook.command and hook.command:match("claude%-nvim%-bridge") then
					has_bridge = true
					break
				end
			end
			if not has_bridge then
				table.insert(cleaned, item)
			end
		end
		settings.hooks.PreToolUse = cleaned
	end

	-- Check if the bridge hook is already registered
	local exists = false
	for _, item in ipairs(settings.hooks.PermissionRequest) do
		if item.hooks then
			for _, hook in ipairs(item.hooks) do
				if hook.command and hook.command:match("claude%-nvim%-bridge") then
					hook.command = bridge_path -- Always ensure the path is up to date
					exists = true
				end
			end
		end
	end

	-- Inject the hook if it is missing
	if not exists then
		table.insert(settings.hooks.PermissionRequest, {
			matcher = "Edit|Write",
			hooks = {
				{
					type = "command",
					command = bridge_path,
				},
			},
		})
	end

	-- Register the PostToolUse hook that applies user-modified content after Claude writes
	settings.hooks.PostToolUse = settings.hooks.PostToolUse or {}
	local post_exists = false
	for _, item in ipairs(settings.hooks.PostToolUse) do
		if item.hooks then
			for _, hook in ipairs(item.hooks) do
				if hook.command and hook.command:match("claude%-nvim%-post%-bridge") then
					hook.command = post_bridge_path
					post_exists = true
				end
			end
		end
	end
	if not post_exists then
		table.insert(settings.hooks.PostToolUse, {
			matcher = "Edit|Write",
			hooks = {
				{
					type = "command",
					command = post_bridge_path,
				},
			},
		})
	end

	vim.fn.mkdir(vim.fn.expand("~/.claude"), "p")
	local f = io.open(settings_path, "w")
	if f then
		f:write(vim.fn.json_encode(settings))
		f:close()
	end
end
-- Label for a tab in notifications: floo-network.nvim's own workspace name
-- if set (soft integration - no hard dependency on floo being installed),
-- else the tab-local directory's basename.
local function tab_label(tabid)
	local ok, name = pcall(vim.api.nvim_tabpage_get_var, tabid, "floo_workspace_name")
	if ok and name then
		return name
	end
	local tabnr = vim.api.nvim_tabpage_get_number(tabid)
	local cwd = vim.fn.getcwd(-1, tabnr)
	return vim.fn.fnamemodify(cwd, ":t")
end

-- Finds the existing tab whose own tab-local directory contains `dir`.
-- Resolves symlinks on both sides: getcwd() returns the realpath (e.g.
-- macOS /tmp -> /private/tmp), but the caller's path may not.
local function find_tab_for_dir(dir)
	local resolved_dir = vim.uv.fs_realpath(dir) or dir
	for _, tabid in ipairs(vim.api.nvim_list_tabpages()) do
		local tabnr = vim.api.nvim_tabpage_get_number(tabid)
		local tab_cwd = vim.fn.getcwd(-1, tabnr)
		local resolved_cwd = vim.uv.fs_realpath(tab_cwd) or tab_cwd
		if vim.startswith(resolved_dir, resolved_cwd) then
			return tabid
		end
	end
	return nil
end

function M.start_review(target_file, temp_content_file, status_file, alive_file)
	vim.schedule(function()
		local abs_target = vim.fn.fnamemodify(target_file, ":p")
		local target_dir = vim.fn.fnamemodify(abs_target, ":h")

		-- Never synthesize a new tab for a directory that isn't already open
		-- as a workspace: that would look like a duplicate of a real one in
		-- a workspace-per-tab switcher (e.g. floo-network.nvim), counting as
		-- an extra tab that wasn't there before. If no open tab's own
		-- directory covers this file, decline entirely - status "3" tells
		-- the bridge to behave exactly as if no nvim instance were found at
		-- all, so Claude Code's own default permission UI takes over.
		local target_tab = find_tab_for_dir(target_dir)
		if not target_tab then
			local f = io.open(status_file, "w")
			if f then
				f:write("3")
				f:close()
			end
			return
		end

		-- Track whether the target file was already open before this review so we
		-- know whether to close it when the review ends.
		local was_preexisting = vim.fn.bufnr(abs_target) ~= -1

		local origin_tab = vim.api.nvim_get_current_tabpage()
		local same_workspace = target_tab == origin_tab

		-- Build the diff as a split inside the real workspace tab, never a
		-- new tab of its own - scope diffthis to exactly these two windows
		-- rather than `windo`, since target_tab may already have other
		-- windows (e.g. a neo-tree sidebar) that must be left alone.
		vim.api.nvim_set_current_tabpage(target_tab)

		vim.cmd("vsplit " .. vim.fn.fnameescape(target_file))
		local orig_win = vim.api.nvim_get_current_win()
		local orig_buf = vim.api.nvim_get_current_buf()
		vim.api.nvim_win_call(orig_win, function()
			vim.cmd("diffthis")
		end)

		vim.cmd("vsplit " .. vim.fn.fnameescape(temp_content_file))
		local temp_win = vim.api.nvim_get_current_win()
		local temp_buf = vim.api.nvim_get_current_buf()
		vim.api.nvim_win_call(temp_win, function()
			vim.cmd("diffthis")
		end)

		-- The diff is fully built; now decide whether to leave it focused or
		-- hand focus back to wherever the user actually was.
		if not same_workspace and vim.api.nvim_tabpage_is_valid(origin_tab) then
			vim.api.nvim_set_current_tabpage(origin_tab)
		end

		local done = false

		local function finish_review(exit_code, notify_msg, notify_level)
			if done then
				return
			end
			done = true

			-- If the user edited Claude's proposed content, save it to a side-channel
			-- file keyed by the target path. The PostToolUse hook (claude-nvim-post-bridge)
			-- will overwrite the file after Claude's write completes, without denying.
			if exit_code == 0 and vim.api.nvim_get_option_value("modified", { buf = temp_buf }) then
				local hash = vim.fn.sha256(abs_target):sub(1, 8)
				local side_channel = "/tmp/claude-nvim-pending-" .. hash .. ".txt"
				local lines = vim.api.nvim_buf_get_lines(temp_buf, 0, -1, false)
				local has_eol = vim.api.nvim_get_option_value("eol", { buf = temp_buf })
				local content = table.concat(lines, "\n")
				if has_eol then
					content = content .. "\n"
				end
				local fh = io.open(side_channel, "w")
				if fh then
					fh:write(content)
					fh:close()
					notify_msg = "Claude edit accepted with your modifications!"
				end
			end

			-- 1. CLEAN UP NVIM LAYOUT FIRST
			-- Close just the two split windows we created, restoring whatever
			-- else target_tab had (e.g. neo-tree) - never the whole tab, which
			-- is a real workspace that may predate this review entirely.
			if vim.api.nvim_win_is_valid(temp_win) then
				pcall(vim.api.nvim_win_close, temp_win, true)
			end
			if vim.api.nvim_buf_is_valid(temp_buf) then
				pcall(vim.api.nvim_buf_delete, temp_buf, { force = true })
			end
			-- Close the target file's window/buffer only if it wasn't open before this review.
			if not was_preexisting then
				if vim.api.nvim_win_is_valid(orig_win) then
					pcall(vim.api.nvim_win_close, orig_win, true)
				end
				if vim.api.nvim_buf_is_valid(orig_buf) then
					pcall(vim.api.nvim_buf_delete, orig_buf, { force = true })
				end
			elseif vim.api.nvim_buf_is_valid(orig_buf) then
				-- The buffer survives the review (it was already open), so its
				-- buffer-local approve/deny maps won't be cleared by deletion.
				-- Remove them explicitly or they permanently shadow the user's
				-- normal keymaps (e.g. LSP code action on the same key) in this buffer.
				pcall(vim.keymap.del, "n", M.config.keymaps.approve, { buffer = orig_buf })
				pcall(vim.keymap.del, "n", M.config.keymaps.deny, { buffer = orig_buf })
			end

			-- 2. NOW UNBLOCK CLAUDE
			-- Once Neovim is safely back in its normal layout, we release the bash loop.
			if exit_code ~= nil then
				local f = io.open(status_file, "w")
				if f then
					f:write(tostring(exit_code))
					f:close()
				end
			end

			-- 3. SEND NOTIFICATION
			if notify_msg then
				vim.notify(notify_msg, notify_level, { title = "Claude Reviewer" })
			end

			-- 4. REFRESH FILE EXPLORER
			-- Delay slightly so the file is on disk before neo-tree scans
			vim.defer_fn(function()
				local ok, manager = pcall(require, "neo-tree.sources.manager")
				if ok then
					manager.refresh("filesystem")
				end
			end, 300)
		end

		for _, buf in ipairs({ temp_buf, orig_buf }) do
			vim.keymap.set("n", M.config.keymaps.approve, function()
				if vim.api.nvim_get_current_tabpage() == target_tab then
					finish_review(0, "Claude edit approved!", vim.log.levels.INFO)
				end
			end, { buffer = buf, desc = "Approve Claude Edit" })

			vim.keymap.set("n", M.config.keymaps.deny, function()
				if vim.api.nvim_get_current_tabpage() == target_tab then
					finish_review(2, "Claude edit rejected.", vim.log.levels.WARN)
				end
			end, { buffer = buf, desc = "Deny Claude Edit" })
		end

		-- Close the diff if Claude Code decides before the user reviews in nvim.
		-- Two signals: (1) bridge PID dies, (2) target file mtime changes because
		-- Claude Code accepted via its own UI and wrote the file while the bridge
		-- was still running (orphaned subprocess).
		local initial_mtime = vim.fn.getftime(target_file)
		local timer = vim.uv.new_timer()
		timer:start(
			500,
			500,
			vim.schedule_wrap(function()
				if done then
					timer:stop()
					timer:close()
					return
				end
				local lines = vim.fn.filereadable(alive_file) == 1 and vim.fn.readfile(alive_file) or {}
				local pid = tonumber(lines[1])
				local bridge_alive = pid ~= nil and pcall(vim.uv.kill, pid, 0)
				local file_changed = vim.fn.getftime(target_file) ~= initial_mtime
				if not bridge_alive or file_changed then
					timer:stop()
					timer:close()
					if file_changed then
						finish_review(nil, "Claude edit approved!", vim.log.levels.INFO)
					else
						finish_review(nil, "Claude review cancelled.", vim.log.levels.WARN)
					end
				end
			end)
		)

		if same_workspace then
			vim.notify(
				string.format("Review pending!\nApprove: %s\nDeny: %s", M.config.keymaps.approve, M.config.keymaps.deny),
				vim.log.levels.INFO,
				{ title = "Claude Reviewer" }
			)
		else
			vim.notify(
				string.format(
					"Claude review pending in %s: %s\nApprove: %s\nDeny: %s",
					tab_label(target_tab),
					vim.fn.fnamemodify(target_file, ":t"),
					M.config.keymaps.approve,
					M.config.keymaps.deny
				),
				vim.log.levels.WARN,
				{ title = "Claude Reviewer" }
			)
		end
	end)
end

return M
