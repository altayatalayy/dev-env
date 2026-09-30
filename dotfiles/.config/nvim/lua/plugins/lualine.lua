local lualine = require('lualine')

local function show_macro_recording()
  local recording_register = vim.fn.reg_recording()
  if recording_register == '' then
    return ''
  end
  return 'Recording @' .. recording_register
end

vim.api.nvim_create_autocmd('RecordingEnter', {
  callback = function()
    lualine.refresh({
      place = { 'statusline' },
    })
  end,
})

vim.api.nvim_create_autocmd('RecordingLeave', {
  callback = function()
    local timer = vim.uv.new_timer()
    if timer == nil then
      return
    end

    timer:start(
      50,
      0,
      vim.schedule_wrap(function()
        lualine.refresh({
          place = { 'statusline' },
        })
      end)
    )
  end,
})

lualine.setup({
  options = {
    icons_enabled = true,
    theme = 'rose-pine',
    section_separators = { left = '', right = '' },
    component_separators = { left = '', right = '' },
    disabled_filetypes = {},
    globalstatus = true,
  },
  sections = {
    lualine_a = {
      {
        'mode',
        fmt = function(str)
          local value = show_macro_recording()
          if value == '' then
            return str
          end
          return value
        end,
      },
    },
    lualine_b = { 'branch' },
    lualine_c = {
      {
        'filename',
        file_status = true,
        path = 0,
      },
    },
    lualine_x = {
      {
        'diagnostics',
        sources = { 'nvim_diagnostic' },
        symbols = {
          error = ' ',
          warn = ' ',
          info = ' ',
          hint = ' ',
        },
      },
      'encoding',
      'filetype',
    },
    lualine_y = { 'progress' },
    lualine_z = { 'location' },
  },
  inactive_sections = {
    lualine_a = {},
    lualine_b = {},
    lualine_c = {
      {
        'filename',
        file_status = true,
        path = 1,
      },
    },
    lualine_x = { 'location' },
    lualine_y = {},
    lualine_z = {},
  },
  tabline = {},
  extensions = { 'fugitive' },
})
