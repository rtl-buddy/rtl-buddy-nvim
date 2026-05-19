-- Default keymaps. Anything <C-]> remains LSP's; we deliberately stay
-- on <leader>r? prefix to avoid trampling user mappings.
local M = {}

function M.apply(spec)
  if not spec then return end
  local bindings = {
    { spec.show,    "<cmd>RtlBuddyShow<cr>",   "rtl-buddy: show cursor at hub" },
    { spec.to_wave, "<cmd>RtlBuddyToWave<cr>", "rtl-buddy: add cword to wave" },
    { spec.domain,  "<cmd>RtlBuddyDomain<cr>", "rtl-buddy: overlay info" },
  }
  for _, b in ipairs(bindings) do
    if b[1] then
      vim.keymap.set("n", b[1], b[2], { desc = b[3], silent = true })
    end
  end
end

return M
