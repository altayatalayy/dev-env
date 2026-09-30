vim.keymap.set("n", "-", "<cmd>Oil<cr>", { desc = "Open parent directory" })

vim.keymap.set("n", "<leader>fm", function()
	require("conform").format({ async = true, lsp_format = "fallback" })
end, { desc = "Format buffer" })

vim.keymap.set("n", "<leader>cl", "<cmd>LspInfo<cr>", { desc = "LSP info" })
vim.keymap.set("n", "<leader>cm", "<cmd>Mason<cr>", { desc = "Mason" })

vim.keymap.set("n", "gd", vim.lsp.buf.definition, { desc = "Go to definition" })
vim.keymap.set("n", "gD", vim.lsp.buf.declaration, { desc = "Go to declaration" })
vim.keymap.set("n", "gr", vim.lsp.buf.references, { desc = "References" })
vim.keymap.set("n", "gi", vim.lsp.buf.implementation, { desc = "Implementation" })
vim.keymap.set("n", "gt", vim.lsp.buf.type_definition, { desc = "Type definition" })
vim.keymap.set("n", "K", vim.lsp.buf.hover, { desc = "Hover" })
vim.keymap.set("n", "<leader>cr", vim.lsp.buf.rename, { desc = "Rename symbol" })
vim.keymap.set({ "n", "v" }, "<leader>ca", vim.lsp.buf.code_action, { desc = "Code action" })
vim.keymap.set("n", "<leader>cd", vim.diagnostic.open_float, { desc = "Line diagnostics" })
vim.keymap.set("n", "[d", vim.diagnostic.goto_prev, { desc = "Previous diagnostic" })
vim.keymap.set("n", "]d", vim.diagnostic.goto_next, { desc = "Next diagnostic" })

vim.keymap.set("n", "<leader>tt", function()
	require("neotest").run.run(vim.fn.expand("%"))
end, { desc = "Run file tests" })
vim.keymap.set("n", "<leader>tn", function()
	require("neotest").run.run()
end, { desc = "Run nearest test" })
vim.keymap.set("n", "<leader>ts", function()
	require("neotest").summary.toggle()
end, { desc = "Toggle test summary" })
vim.keymap.set("n", "<leader>to", function()
	require("neotest").output.open({ enter = true, auto_close = false })
end, { desc = "Open test output" })

vim.keymap.set("n", "<leader>db", function()
	require("dap").toggle_breakpoint()
end, { desc = "Toggle breakpoint" })
vim.keymap.set("n", "<leader>dc", function()
	require("dap").continue()
end, { desc = "Continue debug" })
vim.keymap.set("n", "<leader>di", function()
	require("dap").step_into()
end, { desc = "Step into" })
vim.keymap.set("n", "<leader>do", function()
	require("dap").step_over()
end, { desc = "Step over" })
vim.keymap.set("n", "<leader>dO", function()
	require("dap").step_out()
end, { desc = "Step out" })
vim.keymap.set("n", "<leader>du", function()
	require("dapui").toggle({})
end, { desc = "Toggle DAP UI" })
vim.keymap.set("n", "<leader>dr", function()
	require("dap").repl.toggle()
end, { desc = "Toggle DAP REPL" })

vim.keymap.set("n", "<C-S>", ":%s/", { desc = "" })

-- Move text up and down
vim.keymap.set("v", "J", ":m '>+1<CR>gv=gv", { desc = "move text down" })
vim.keymap.set("v", "K", ":m '<-2<CR>gv=gv", { desc = "move text up" })

-- dont copy into register when pasting
vim.keymap.set("v", "p", '"_dP')

-- stay in indent mode
vim.keymap.set("v", "<", "<gv")
vim.keymap.set("v", ">", ">gv")

-- keep the cursor inplace when using J
vim.keymap.set("n", "J", "mzJ`z")

-- keep the cursor in the middle when scrolling with Ctrl-u Ctrl-d
vim.keymap.set("n", "<C-d>", "<C-d>zz")
vim.keymap.set("n", "<C-u>", "<C-u>zz")

-- keep search terms in the middle
vim.keymap.set("n", "n", "nzzzv")
vim.keymap.set("n", "N", "Nzzzv")

-- find and replace the word under the cursor, global
vim.keymap.set("n", "<leader>s", [[:%s/\<<C-r><C-w>\>/<C-r><C-w>/gI<Left><Left><Left>]], { desc = "replace cur word" })
-- find and replace the word under the cursor, current line, cok sacma oldu ama visualla secip yapmak mantikli olabilir
vim.keymap.set("n", "<leader>S", [[:.s/\<<C-r><C-w>\>/<C-r><C-w>/gI<Left><Left><Left>]], { desc = "replace cur word" })

-- make current file executable
vim.keymap.set("n", "<leader>x", "<cmd>!chmod +x %<CR>", { silent = true, desc = "make file exec" })

-- disable Q
vim.keymap.set("n", "Q", "<nop>")
