require("blink.cmp").setup({
	keymap = {
		preset = "default",
		["<C-Space>"] = { "show", "show_documentation", "hide_documentation" },
		["<C-j>"] = { "select_next", "fallback" },
		["<C-k>"] = { "select_prev", "fallback" },
		["<C-y>"] = { "accept", "fallback" },
		["<C-e>"] = false, -- or {}
	},
	appearance = {
		nerd_font_variant = "mono",
	},
	completion = {
		accept = {
			auto_brackets = {
				enabled = true,
			},
		},
		documentation = {
			auto_show = true,
			auto_show_delay_ms = 200,
		},
		list = {
			selection = {
				preselect = false,
				auto_insert = false,
			},
		},
		menu = {
			border = "rounded",
			auto_show = true,
		},
	},
	signature = {
		enabled = true,
		window = {
			border = "rounded",
		},
	},
	snippets = {
		preset = "default",
	},
	fuzzy = {
		implementation = "prefer_rust_with_warning",
	},
	sources = {
		default = { "lsp", "path", "snippets", "buffer" },
		providers = {
			cmdline = {
				min_keyword_length = 2,
			},
		},
	},
	cmdline = {
		enabled = true,
		keymap = { preset = "inherit" },
		completion = {
			menu = {
				auto_show = true,
			},
		},
	},
})
