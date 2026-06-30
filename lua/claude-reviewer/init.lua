local M = {}

M.config = {
	keymaps = {
		approve = "<leader>ca",
		deny = "<leader>cd",
	},
}

local function write_socket_file()
	local cmux_id = os.getenv("CMUX_WINDOW_ID") or os.getenv("TMUX_PANE") or "default"
	local filename = string.format("/tmp/claude-nvim-server-%s.txt", cmux_id)
	local server_file = io.open(filename, "w")
	if server_file then
		server_file:write(vim.v.servername)
		server_file:close()
	end
end

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

	-- Write immediately since LazyVim loads plugins dynamically
	write_socket_file()

	-- Also register autocmd as a fallback safety net
	vim.api.nvim_create_autocmd("VimEnter", {
		callback = write_socket_file,
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

	settings.hooks = settings.hooks or {}
	settings.hooks.PreToolUse = settings.hooks.PreToolUse or {}
	settings.defaultMode = "acceptEdits"

	local exists = false
	for _, item in ipairs(settings.hooks.PreToolUse) do
		if item.hooks then
			for _, hook in ipairs(item.hooks) do
				if hook.command and hook.command:match("claude%-nvim%-bridge") then
					hook.command = bridge_path
					exists = true
				end
			end
		end
	end

	if not exists then
		table.insert(settings.hooks.PreToolUse, {
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
			vim.cmd("tabclose")
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
