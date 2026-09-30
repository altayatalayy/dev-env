require('oil').setup({
  default_file_explorer = true,
  columns = { 'icon' },
  delete_to_trash = true,
  skip_confirm_for_simple_edits = true,
  view_options = {
    show_hidden = true,
  },
  keymaps = {
    ['q'] = 'actions.close',
    ['<C-h>'] = false,
    ['<C-l>'] = false,
  },
})
