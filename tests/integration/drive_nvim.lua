-- Headless-nvim driver: load the plugin, connect to whatever hub
-- $RTL_BUDDY_HUB or .rtl-buddy/hub.json points at, broadcast a
-- source_focused for a known cursor position, then disconnect.
-- Used by tests/integration/run_live_hub.sh.

require("rtlbuddy").setup({ keymaps = {}, auto_connect = false })
local state = require("rtlbuddy").state()
local hub = require("rtlbuddy.hub")

hub.connect(state.client)

local deadline = vim.uv.hrtime() + 5e9
while state.client.state ~= "ready" and vim.uv.hrtime() < deadline do
  vim.wait(50)
end
if state.client.state ~= "ready" then
  io.stderr:write("DRIVE: hub not ready, state=" .. state.client.state ..
                  " last_error=" .. tostring(state.client.last_error) .. "\n")
  vim.cmd("cq")
end

local fixture_path = (vim.uv.cwd() or ".") .. "/design/example.sv"
vim.cmd("edit " .. vim.fn.fnameescape(fixture_path))
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "module x;",
  "  logic clk;",
  "endmodule",
})
vim.api.nvim_win_set_cursor(0, { 2, 8 })  -- 1-based: line 2, col 9

require("rtlbuddy.commands").show()

-- Give the hub time to fan the broadcast out before we tear down.
vim.wait(500)
require("rtlbuddy").disconnect()
print("DRIVE: ok")
