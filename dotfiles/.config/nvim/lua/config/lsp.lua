local capabilities = require("blink.cmp").get_lsp_capabilities()

vim.diagnostic.config({
	severity_sort = true,
	float = { border = "rounded", source = "if_many" },
	signs = {
		text = {
			[vim.diagnostic.severity.ERROR] = " ",
			[vim.diagnostic.severity.WARN] = " ",
			[vim.diagnostic.severity.INFO] = " ",
			[vim.diagnostic.severity.HINT] = " ",
		},
	},
	underline = true,
	virtual_text = { spacing = 2, source = "if_many" },
	update_in_insert = false,
})

local servers = {
	"astro",
	"bashls",
	"basedpyright",
	"clangd",
	"cssls",
	"gopls",
	"html",
	"lua_ls",
	"marksman",
	"ruff",
	"rust_analyzer",
	"tailwindcss",
	"terraformls",
	"vtsls",
	"yamlls",
	"zls",
}

for _, server in ipairs(servers) do
	vim.lsp.config(server, {
		capabilities = capabilities,
	})
	vim.lsp.enable(server)
end

vim.lsp.config("lua_ls", {
	capabilities = capabilities,
	settings = {
		Lua = {
			completion = {
				callSnippet = "Replace",
			},
			hint = {
				enable = true,
			},
			telemetry = {
				enable = false,
			},
			workspace = {
				checkThirdParty = false,
			},
		},
	},
})

vim.lsp.config("clangd", {
	capabilities = capabilities,
	cmd = {
		"clangd",
		"--background-index",
		"--header-insertion=iwyu",
	},
})

vim.lsp.config("gopls", {
	capabilities = capabilities,
	settings = {
		gopls = {
			analyses = {
				unusedparams = true,
			},
			gofumpt = true,
			staticcheck = true,
		},
	},
})

vim.lsp.config("vtsls", {
	capabilities = capabilities,
	settings = {
		complete_function_calls = true,
		vtsls = {
			autoUseWorkspaceTsdk = true,
			enableMoveToFileCodeAction = true,
		},
		typescript = {
			updateImportsOnFileMove = { enabled = "always" },
			suggest = { completeFunctionCalls = true },
			inlayHints = {
				enumMemberValues = { enabled = true },
				functionLikeReturnTypes = { enabled = true },
				parameterNames = { enabled = "literals" },
				parameterTypes = { enabled = true },
				propertyDeclarationTypes = { enabled = true },
				variableTypes = { enabled = false },
			},
		},
		javascript = {
			updateImportsOnFileMove = { enabled = "always" },
			suggest = { completeFunctionCalls = true },
		},
	},
})

vim.lsp.config("basedpyright", {
	capabilities = capabilities,
	settings = {
		basedpyright = {
			analysis = {
				autoImportCompletions = true,
				typeCheckingMode = "recommended",
			},
		},
	},
})
