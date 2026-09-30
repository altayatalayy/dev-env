require('conform').setup({
  formatters_by_ft = {
    astro = { 'prettierd' },
    bash = { 'shfmt' },
    c = { 'clang-format' },
    cpp = { 'clang-format' },
    css = { 'prettierd' },
    go = { 'goimports', 'gofumpt' },
    html = { 'prettierd' },
    javascript = { 'prettierd' },
    javascriptreact = { 'prettierd' },
    json = { 'prettierd' },
    lua = { 'stylua' },
    markdown = { 'prettierd' },
    python = { 'black' },
    rust = { 'rustfmt' },
    sh = { 'shfmt' },
    terraform = { 'terraform_fmt' },
    typescript = { 'prettierd' },
    typescriptreact = { 'prettierd' },
    yaml = { 'prettierd' },
    zig = { 'zigfmt' },
  },
  format_on_save = function(bufnr)
    local disable_filetypes = { c = true, cpp = true }
    return {
      timeout_ms = 1000,
      lsp_format = disable_filetypes[vim.bo[bufnr].filetype] and 'never' or 'fallback',
    }
  end,
})
