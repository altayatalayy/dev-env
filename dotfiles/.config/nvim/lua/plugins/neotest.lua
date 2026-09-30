require('neotest').setup({
  adapters = {
    require('neotest-python')({
      dap = { justMyCode = false },
      runner = 'pytest',
    }),
    require('neotest-golang')({
      go_test_args = { '-v' },
      dap_go_enabled = true,
    }),
    require('neotest-rust')({}),
    require('neotest-plenary'),
  },
  diagnostic = {
    enabled = true,
  },
  floating = {
    border = 'rounded',
  },
  output = {
    enabled = true,
    open_on_run = false,
  },
  quickfix = {
    enabled = false,
  },
  summary = {
    enabled = true,
  },
})
