local augroup = vim.api.nvim_create_augroup("user_config", { clear = true })

vim.api.nvim_create_autocmd("TextYankPost", {
	group = augroup,
	callback = function()
		vim.hl.on_yank()
	end,
})

-- vim.api.nvim_create_autocmd("LspAttach", {
-- 	group = augroup,
-- 	callback = function(event)
-- 		vim.lsp.completion.enable(true, event.data.client_id, event.buf, { autotrigger = true })
-- 	end,
-- })

-- autocommand for detecting zsh functions
local zdotdir = os.getenv("ZDOTDIR") or ""
if zdotdir ~= "" then
	local functions_dir = zdotdir .. "/functions/*"

	vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
		pattern = functions_dir,
		callback = function()
			vim.bo.filetype = "zsh"
		end,
	})
end

-- autocommand for detecting git hooks
vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
	pattern = ".git/hooks/*",
	callback = function()
		vim.bo.filetype = "sh"
	end,
})

-- close some filetypes with <q>
vim.api.nvim_create_autocmd("FileType", {
	group = augroup,
	pattern = {
		"PlenaryTestPopup",
		"help",
		"lspinfo",
		"man",
		"notify",
		"qf",
		"spectre_panel",
		"startuptime",
		"tsplayground",
		"neotest-output",
		"checkhealth",
		"neotest-summary",
		"neotest-output-panel",
	},
	callback = function(event)
		vim.bo[event.buf].buflisted = false
		vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = event.buf, silent = true })
	end,
})
