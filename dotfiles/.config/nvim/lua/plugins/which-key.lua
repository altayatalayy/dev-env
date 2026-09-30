require('which-key').setup({
  preset = 'modern',
  delay = 200,
  icons = {
    mappings = true,
  },
  spec = {
    { '<leader>c', group = 'code' },
    { '<leader>d', group = 'debug' },
    { '<leader>t', group = 'test' },
  },
})
