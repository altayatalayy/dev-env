-- headless mode
if #vim.api.nvim_list_uis() == 0 then
	vim.opt.shortmess = ""
	vim.opt.more = false
	vim.opt.cmdheight = 9999
	vim.opt.columns = 9999
	vim.opt.swapfile = false
	vim.opt.termguicolors = true
	return
end

-- encoding and UI
vim.opt.termguicolors = true
vim.opt.fileencoding = "utf-8"
vim.opt.showmode = false
vim.opt.showtabline = 2
vim.opt.laststatus = 3
vim.opt.cmdheight = 0
vim.opt.pumheight = 10

-- messages
vim.opt.shortmess:append("cIW")
vim.opt.more = false

-- timing and completion
vim.opt.updatetime = 100
vim.opt.timeoutlen = 250
vim.opt.completeopt = { "menu", "menuone", "noselect", "popup", "fuzzy" }
vim.opt.wildmode = "longest:full,full"

-- spelling
vim.opt.spelllang = { "en", "cjk" }

-- search
vim.opt.incsearch = true
vim.opt.hlsearch = false
vim.opt.ignorecase = true
vim.opt.smartcase = true

-- files and undo
vim.opt.undofile = true
vim.opt.swapfile = false
vim.opt.backup = false

-- line numbers and cursor
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.numberwidth = 3
vim.opt.ruler = true
vim.opt.cursorline = true
vim.opt.signcolumn = "yes"

-- indentation
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.softtabstop = 4
vim.opt.expandtab = true
vim.opt.smarttab = true
vim.opt.smartindent = true
vim.opt.shiftround = true

-- window movement
vim.opt.wrap = false
vim.opt.scrolloff = 8
vim.opt.sidescrolloff = 8
vim.opt.splitbelow = true
vim.opt.splitright = true
vim.opt.virtualedit = "block"
vim.opt.whichwrap = "b,h,l,s,<,>,[,],~"

-- editing display
vim.opt.list = true
vim.opt.listchars = {
	nbsp = "⦸",
	tab = "▷-",
	trail = "•",
}
vim.opt.conceallevel = 0
vim.opt.joinspaces = false
vim.opt.lazyredraw = false

-- clipboard
vim.opt.clipboard = "unnamedplus"

-- disable netrw for oil
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

-- markdown
vim.g.markdown_recommended_style = 0

vim.api.nvim_create_user_command("W", "wa", {})
vim.api.nvim_create_user_command("Q", "qa", {})
