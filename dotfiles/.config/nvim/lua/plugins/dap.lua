local dap = require("dap")
local dapui = require("dapui")

require("dapui").setup()

local function mason_package_path(pkg, rel)
	local base = vim.fn.stdpath("data") .. "/mason/packages/" .. pkg
	if rel and rel ~= "" then
		return base .. "/" .. rel
	end
	return base
end

local codelldb_root = mason_package_path("codelldb", "extension")
local codelldb_bin = codelldb_root .. "/adapter/codelldb"
local liblldb = codelldb_root .. (vim.fn.has("mac") == 1 and "/lldb/lib/liblldb.dylib" or "/lldb/lib/liblldb.so")

if vim.fn.executable(codelldb_bin) == 1 and vim.fn.filereadable(liblldb) == 1 then
	dap.adapters.codelldb = {
		type = "server",
		port = "${port}",
		executable = {
			command = codelldb_bin,
			args = { "--port", "${port}" },
			detached = false,
		},
	}

	dap.configurations.c = {
		{
			name = "Launch file",
			type = "codelldb",
			request = "launch",
			program = function()
				return vim.fn.input("Path to executable: ", vim.fn.getcwd() .. "/", "file")
			end,
			cwd = "${workspaceFolder}",
			stopOnEntry = false,
		},
	}

	dap.configurations.cpp = dap.configurations.c
	dap.configurations.rust = dap.configurations.c
end

local debugpy_path = mason_package_path("debugpy", "venv/bin/python")
if vim.fn.executable(debugpy_path) == 1 then
	dap.adapters.python = {
		type = "executable",
		command = debugpy_path,
		args = { "-m", "debugpy.adapter" },
	}

	dap.configurations.python = {
		{
			type = "python",
			request = "launch",
			name = "Launch file",
			program = "${file}",
			console = "integratedTerminal",
			justMyCode = false,
		},
	}
end

local delve_path = mason_package_path("delve")
if vim.fn.executable(delve_path .. "/dlv") == 1 then
	dap.adapters.go = {
		type = "server",
		port = "${port}",
		executable = {
			command = delve_path .. "/dlv",
			args = { "dap", "-l", "127.0.0.1:${port}" },
		},
	}

	dap.configurations.go = {
		{
			type = "go",
			name = "Debug file",
			request = "launch",
			program = "${file}",
		},
		{
			type = "go",
			name = "Debug package",
			request = "launch",
			program = "${fileDirname}",
		},
		{
			type = "go",
			name = "Debug test",
			request = "launch",
			mode = "test",
			program = "${file}",
		},
	}
end

dap.listeners.before.attach.dapui_config = function()
	dapui.open()
end

dap.listeners.before.launch.dapui_config = function()
	dapui.open()
end

dap.listeners.before.event_terminated.dapui_config = function()
	dapui.close()
end

dap.listeners.before.event_exited.dapui_config = function()
	dapui.close()
end
