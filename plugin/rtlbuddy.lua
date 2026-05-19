if vim.g.loaded_rtlbuddy == 1 then
  return
end
vim.g.loaded_rtlbuddy = 1

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("rtlbuddy.nvim requires Neovim 0.10+", vim.log.levels.ERROR)
  return
end

require("rtlbuddy.commands").register()
