local lint = require("lint")

local plugin_dir = vim.fn.stdpath("data") .. "/clang-tidy/plugins"
local clang_tidy_args = {}

if vim.fn.isdirectory(plugin_dir) == 1 then
	local plugins = {}

	for name, type in vim.fs.dir(plugin_dir) do
		if type == "file" and name:match("%.so$") then
			table.insert(plugins, plugin_dir .. "/" .. name)
		end
	end

	table.sort(plugins)

	for _, path in ipairs(plugins) do
		table.insert(clang_tidy_args, "--load=" .. path)
	end
end

table.insert(clang_tidy_args, "-p")
table.insert(clang_tidy_args, "build")
-- table.insert(clang_tidy_args, "--quiet")

lint.linters.clangtidy.args = clang_tidy_args

lint.linters_by_ft = {
	bash = { "shellcheck" },
	javascript = { "eslint_d" },
	javascriptreact = { "eslint_d" },
	markdown = { "markdownlint-cli2" },
	python = { "ruff" },
	sh = { "shellcheck" },
	typescript = { "eslint_d" },
	typescriptreact = { "eslint_d" },
	cpp = { "clangtidy" },
	c = { "clangtidy" },
	yaml = { "yamllint" },
}

local lint_augroup = vim.api.nvim_create_augroup("nvim_lint", { clear = true })

vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "InsertLeave", "TextChanged", "TextChangedI" }, {
	group = lint_augroup,
	callback = function()
		require("lint").try_lint()
	end,
})
