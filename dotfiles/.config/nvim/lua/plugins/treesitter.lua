require("nvim-treesitter").install({
	"astro",
	"bash",
	"c",
	"cpp",
	"css",
	"go",
	"html",
	"javascript",
	"jsdoc",
	"json",
	"lua",
	"markdown",
	"markdown_inline",
	"python",
	"query",
	"regex",
	"rust",
	"terraform",
	"toml",
	"tsx",
	"typescript",
	"vim",
	"vimdoc",
	"yaml",
	"zig",
})

-- require('nvim-treesitter.configs').setup({
--   auto_install = true,
--   highlight = {
--     enable = true,
--   },
--   indent = {
--     enable = true,
--   },
--   textobjects = {
--     select = {
--       enable = true,
--       lookahead = true,
--       keymaps = {
--         ['af'] = '@function.outer',
--         ['if'] = '@function.inner',
--         ['ac'] = '@class.outer',
--         ['ic'] = '@class.inner',
--         ['aa'] = '@parameter.outer',
--         ['ia'] = '@parameter.inner',
--       },
--     },
--     move = {
--       enable = true,
--       set_jumps = true,
--       goto_next_start = {
--         [']f'] = '@function.outer',
--         [']c'] = '@class.outer',
--       },
--       goto_previous_start = {
--         ['[f'] = '@function.outer',
--         ['[c'] = '@class.outer',
--       },
--     },
--   },
-- })
