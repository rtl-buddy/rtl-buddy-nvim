-- Headless-nvim test bootstrap. Run with:
--   nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
-- (plenary.nvim is the typical busted-style harness for nvim plugins;
-- the tests below also run under stock `busted` once the runtime is mocked.)
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.swapfile = false

-- Make sure our plugin code loads in the same way lazy.nvim would.
vim.cmd("runtime plugin/rtlbuddy.lua")
