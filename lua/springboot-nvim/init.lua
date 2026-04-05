local generate_class = require("springboot-nvim.generateclass")
local springboot_nvim_ui = require("springboot-nvim.ui.springboot_nvim_ui")
require("create_springboot_project")

local lspconfig = require("lspconfig")
local jdtls = require("jdtls")

local function incremental_compile()
	jdtls.compile("incremental")
end

local function is_plugin_installed(plugin)
	local status, _ = pcall(require, plugin)
	return status
end

local function get_spring_boot_project_root()
	local current_file = vim.fn.expand("%:p")
	if current_file == "" then
		print("No file is currently open.")
		return nil
	end

	local root_pattern = { "pom.xml", "build.gradle", ".git" }

	local root_dir = lspconfig.util.root_pattern(unpack(root_pattern))(current_file)
	if not root_dir then
		print("Project root not found.")
		return nil
	end

	return root_dir
end

local function get_run_command(args)
	local project_root = get_spring_boot_project_root()
	if not project_root then
		return "Unknown"
	end

	-- Load project-specific profiles from JSON
	local config_file = vim.fn.stdpath("config") .. "/springboot_profiles.json"
	local profiles = {}

	if vim.fn.filereadable(config_file) == 1 then
		local content = vim.fn.readfile(config_file)
		local ok, data = pcall(vim.fn.json_decode, table.concat(content, "\n"))
		if ok and type(data) == "table" then
			local project = vim.fn.fnamemodify(project_root, ":t")
			profiles = data[project] or {}
		end
	end

	-- Combine profiles into a comma-separated string
	local profile_arg = ""
	if #profiles > 0 then
		profile_arg = "--spring.output.ansi.enabled=ALWAYS --spring.profiles.active=" .. table.concat(profiles, ",")
	end

	-- Allow extra args from the function call
	local extra_args = args or ""

	local maven_file = vim.fn.findfile("pom.xml", project_root)
	local gradle_file = vim.fn.findfile("build.gradle", project_root)

	if maven_file ~= "" then
		-- For Maven, append profiles as JVM args if needed
		return string.format(
			':call jobsend(b:terminal_job_id, "cd %s && mvn spring-boot:run %s %s \\n")',
			project_root,
			profile_arg,
			extra_args
		)
	elseif gradle_file ~= "" then
		return string.format(
			":call jobsend(b:terminal_job_id, \"cd %s && ./gradlew bootRun --args='%s' %s \\n\")",
			project_root,
			profile_arg,
			extra_args
		)
	else
		print("No build file (pom.xml or build.gradle) found in the project root.")
		return "Unknown"
	end
end

local function boot_run(args)
	local project_root = get_spring_boot_project_root()

	if project_root then
		vim.cmd("split | terminal")
		vim.cmd("resize 15")
		vim.cmd("norm G")
		local cd_cmd = ':call jobsend(b:terminal_job_id, "cd ' .. project_root .. '\\n")'
		vim.cmd(cd_cmd)
		local run_cmd = get_run_command(args or "")
		vim.cmd(run_cmd)
		vim.cmd("wincmd k")
	else
		print("Not in a Spring Boot project")
	end
end

local function boot_stop()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.bo[buf].buftype == "terminal" then
			local job_id = vim.b[buf].terminal_job_id
			if job_id and vim.fn.jobwait({ job_id }, 0)[1] == -1 then
				-- Send SIGINT to gracefully stop the Gradle process
				vim.fn.chansend(job_id, "\x03") -- Ctrl+C
				vim.fn.chansend(job_id, "exit\n") -- Exit terminal
				vim.cmd("bd! " .. buf) -- Close the terminal buffer
				print("Stopped Spring Boot process")
				return
			end
		end
	end
	print("No active terminal session found")
end

local function toggle_terminal()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.bo[buf].buftype == "terminal" then
			local job_id = vim.b[buf].terminal_job_id
			if job_id and vim.fn.jobwait({ job_id }, 0)[1] == -1 then
				local win_id = vim.fn.bufwinid(buf)
				if win_id ~= -1 then
					vim.cmd("hide") -- Hide the terminal window if visible
					print("Terminal session hidden")
				else
					vim.cmd("split | buffer " .. buf) -- Reopen the terminal buffer
					print("Terminal session restored")
				end
				return
			end
		end
	end
	print("No active terminal session found")
end

local function contains_package_info(file_path)
	local file = io.open(file_path, "r")
	if not file then
		return false
	end

	local has_package_info = false

	local line
	repeat
		line = file:read("*l")
		if line and string.match(line, "^package") then
			has_package_info = true
			break
		end
	until not line

	file:close()
	return has_package_info
end

local function get_java_package(file_path)
	local java_file_path = file_path:match("src/(.-)%.java")
	if java_file_path then
		local package_path = java_file_path:gsub("/", ".")

		local t = {}
		for str in string.gmatch(package_path, "([^.]+)") do
			table.insert(t, str)
		end

		local package = ""

		for i = 3, table.getn(t) - 1 do
			package = package .. "." .. t[i]
		end

		return string.sub(package, 2, -1)
	else
		return nil
	end
end

local function check_and_add_package()
	local file_path = vim.fn.expand("%:p")
	if not contains_package_info(file_path) then
		local package_location = get_java_package(file_path)
		local package_text = "package " .. package_location .. ";"
		local buf = vim.api.nvim_get_current_buf()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { package_text, "", "" })
		vim.api.nvim_win_set_cursor(0, { 3, 0 })
	end
end

local function fill_package_details()
	check_and_add_package()
end

-- key mapping

-- auto commands
local function setup()
	vim.api.nvim_exec(
		[[
    augroup JavaAutoCommands
        autocmd!
        autocmd BufWritePost *.java lua require('springboot-nvim').incremental_compile()
    augroup END
]],
		false
	)

	vim.api.nvim_exec(
		[[
    augroup JavaPackageDetails
    autocmd!
    autocmd BufReadPost *.java lua require('springboot-nvim').fill_package_details()
    augroup END
]],
		false
	)

	vim.api.nvim_exec(
		[[
  augroup ClosePluginBuffers
    autocmd!
    autocmd FileType springbootnvim autocmd QuitPre * lua require('springboot-nvim').close_ui()
  augroup END
]],
		false
	)
end

-- Utility functions
local function get_project_name()
	return vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
end

local function add_new_profile()
	local max_height = vim.api.nvim_win_get_height(0)
	local max_width = vim.api.nvim_win_get_width(0)
	local buf = vim.api.nvim_create_buf(false, true)

	-- Load the last profile for the project
	local config_file = vim.fn.stdpath("config") .. "/springboot_profiles.json"
	local last_profile = ""
	if vim.fn.filereadable(config_file) == 1 then
		local content = vim.fn.readfile(config_file)
		local ok, data = pcall(vim.fn.json_decode, table.concat(content, "\n"))
		if ok and type(data) == "table" then
			local project = get_project_name()
			local project_profiles = data[project] or {}
			if #project_profiles > 0 then
				last_profile = project_profiles[#project_profiles]
			end
		end
	end

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = math.floor(max_width * 0.5),
		height = 1,
		row = math.floor((max_height - 1) / 2),
		col = math.floor((max_width - math.floor(max_width * 0.5)) / 2),
		style = "minimal",
		border = "rounded",
		title = "Add new profile (" .. get_project_name() .. ")",
		title_pos = "center",
	})

	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = true

	-- Pre-fill last profile if it exists
	if last_profile ~= "" then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { last_profile })
		vim.api.nvim_win_set_cursor(win, { 1, #last_profile })
	end

	-- Reset modified flag to avoid ":q" prompt
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = buf,
		callback = function()
			vim.bo[buf].modified = false
		end,
	})

	-- <Enter> mapping: overwrite the last profile
	vim.keymap.set("i", "<CR>", function()
		local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
		if line ~= "" then
			-- Ensure folder exists
			vim.fn.mkdir(vim.fn.fnamemodify(config_file, ":h"), "p")

			-- Save as single profile for this project (overwrite)
			local all = {}
			if vim.fn.filereadable(config_file) == 1 then
				local content = vim.fn.readfile(config_file)
				local ok, data = pcall(vim.fn.json_decode, table.concat(content, "\n"))
				if ok and type(data) == "table" then
					all = data
				end
			end

			local project = get_project_name()
			all[project] = { line } -- overwrite previous profiles

			vim.fn.writefile({ vim.fn.json_encode(all) }, config_file)
			vim.g.springboot_selected_profile = line
			vim.notify("Profile saved for project " .. project .. ": " .. line)
		end

		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
			vim.cmd("stopinsert")
		end
	end, { buffer = buf })
	vim.cmd("startinsert")
end

return {
	profiles = add_new_profile,
	setup = setup,
	boot_run = boot_run,
	boot_stop = boot_stop,
	toggle_terminal = toggle_terminal,
	incremental_compile = incremental_compile,
	fill_package_details = fill_package_details,
	create_ui = generate_class.create_ui,
	close_ui = springboot_nvim_ui.close_ui,
	generate_class = springboot_nvim_ui.create_generate_class_ui,
	generate_record = springboot_nvim_ui.create_generate_record_ui,
	generate_interface = springboot_nvim_ui.create_generate_interface_ui,
	generate_enum = springboot_nvim_ui.create_generate_enum_ui,
}
