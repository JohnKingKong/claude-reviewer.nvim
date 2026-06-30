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

local function write_socket_file_at(path)
	local f = io.open(path, "w")
	if f then
		f:write(vim.v.servername)
		f:close()
		written_files[path] = true
	end
end

local function write_socket_file()
	write_socket_file_at(cwd_socket_path(vim.fn.getcwd()))
end

local function write_git_root_socket_file()
	local bufpath = vim.api.nvim_buf_get_name(0)
	if bufpath == "" then
		return
	end
	local dir = vim.fn.fnamemodify(bufpath, ":h")
	local result = vim.fn.system({ "git", "-C", dir, "rev-parse", "--show-toplevel" })
	if vim.v.shell_error ~= 0 then
		return
	end
	local root = vim.trim(result)
	if root == vim.fn.getcwd() then
		return
	end
	write_socket_file_at(cwd_socket_path(root))
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

	-- Also register autocmd as a fallback safety net
	vim.api.nvim_create_autocmd("VimEnter", {
		callback = write_socket_file,
	})

	-- Keep cwd socket fresh if the user changes directory inside Neovim
	vim.api.nvim_create_autocmd("DirChanged", {
		callback = write_socket_file,
	})

	-- Write a git-root socket file whenever a buffer is entered
	vim.api.nvim_create_autocmd("BufEnter", {
		callback = write_git_root_socket_file,
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

	-- 2. Make sure the bridge script is executable
	vim.fn.system({ "chmod", "+x", bridge_path })

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

	vim.fn.mkdir(vim.fn.expand("~/.claude"), "p")
	local f = io.open(settings_path, "w")
	if f then
		f:write(vim.fn.json_encode(settings))
		f:close()
	end
end

function M.start_review(target_file, temp_content_file, status_file)
	vim.schedule(function()
		vim.cmd("tabedit " .. target_file)
		vim.cmd("vsplit " .. temp_content_file)
		vim.cmd("windo diffthis")

		local temp_buf = vim.api.nvim_get_current_buf()

		local function finish_review(exit_code)
			local f = io.open(status_file, "w")
			if f then
				f:write(tostring(exit_code))
				f:close()
			end
			vim.cmd("windo diffoff")
			pcall(vim.cmd, "tabclose")
			pcall(vim.api.nvim_buf_delete, temp_buf, { force = true })
		end

		vim.keymap.set("n", M.config.keymaps.approve, function()
			finish_review(0)
			vim.notify("Claude edit approved!", vim.log.levels.INFO, { title = "Claude Reviewer" })
		end, { buffer = temp_buf, desc = "Approve Claude Edit" })

		vim.keymap.set("n", M.config.keymaps.deny, function()
			finish_review(2)
			vim.notify("Claude edit rejected.", vim.log.levels.WARN, { title = "Claude Reviewer" })
		end, { buffer = temp_buf, desc = "Deny Claude Edit" })

		vim.notify(
			string.format("Review pending!\nApprove: %s\nDeny: %s", M.config.keymaps.approve, M.config.keymaps.deny),
			vim.log.levels.INFO,
			{ title = "Claude Reviewer" }
		)
	end)
end

return M
