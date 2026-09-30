require('mason').setup()

require('mason-lspconfig').setup({
  ensure_installed = {
    'astro',
    'bashls',
    'clangd',
    'cssls',
    'gopls',
    'html',
    'lua_ls',
    'marksman',
    'ruff',
    'rust_analyzer',
    'tailwindcss',
    'terraformls',
    'vtsls',
    'yamlls',
    'zls',
    'basedpyright',
  },
  automatic_enable = false,
})

require('mason-tool-installer').setup({
  ensure_installed = {
    'black',
    'clang-format',
    'delve',
    'debugpy',
    'eslint_d',
    'goimports',
    'gofumpt',
    'js-debug-adapter',
    'markdownlint-cli2',
    'prettierd',
    'shellcheck',
    'shfmt',
    'stylua',
  },
  auto_update = false,
  run_on_start = true,
  start_delay = 3000,
})

require('mason-nvim-dap').setup({
  ensure_installed = {
    'codelldb',
    'debugpy',
    'delve',
    'js-debug-adapter',
  },
  automatic_installation = true,
})
