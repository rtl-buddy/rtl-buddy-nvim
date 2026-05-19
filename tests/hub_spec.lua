-- End-to-end test: start a mock hub TCP server in-process, point the
-- plugin at it via RTL_BUDDY_HUB, run :RtlBuddyShow, assert the right
-- envelope arrived on the wire.
local proto = require("rtlbuddy.protocol")

-- Tiny TCP server that does the hello/welcome dance and records frames.
local function start_mock_hub()
  local server = vim.uv.new_tcp()
  server:bind("127.0.0.1", 0)
  local frames = {}
  local clients = {}
  server:listen(8, function(err)
    assert(not err, err)
    local sock = vim.uv.new_tcp()
    server:accept(sock)
    table.insert(clients, sock)
    local buf = ""
    sock:read_start(function(rerr, chunk)
      assert(not rerr, rerr)
      if not chunk then return end
      buf = buf .. chunk
      while true do
        local nl = buf:find("\n", 1, true)
        if not nl then break end
        local line = buf:sub(1, nl - 1)
        buf = buf:sub(nl + 1)
        local env = proto.decode(line)
        table.insert(frames, env)
        if env.type == "hello" then
          local welcome = proto.envelope("cli", "response", "welcome", {
            server_version = "test-0.0",
            registered_clients = { "src" },
          }, env.id)
          sock:write(proto.encode(welcome) .. "\n")
        end
      end
    end)
  end)
  local _, port = server:getsockname().port and server:getsockname() or { port = 0 }, server:getsockname().port
  return server, port, frames
end

describe("rtlbuddy.hub end-to-end", function()
  it("sends hello and broadcasts source_focused on :RtlBuddyShow", function()
    local server, port, frames = start_mock_hub()
    vim.env.RTL_BUDDY_HUB = "127.0.0.1:" .. tostring(port)

    require("rtlbuddy").setup({ keymaps = {}, auto_connect = false })
    local state = require("rtlbuddy").state()
    require("rtlbuddy.hub").connect(state.client)

    -- Wait for handshake.
    local deadline = vim.uv.hrtime() + 2e9
    while state.client.state ~= "ready" and vim.uv.hrtime() < deadline do
      vim.wait(20)
    end
    assert.are.equal("ready", state.client.state)

    -- Use a real buffer so RtlBuddyShow has a file path.
    vim.cmd("edit /tmp/rtlbuddy_test.sv")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "module x;", "endmodule" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    require("rtlbuddy.commands").show()
    vim.wait(200, function()
      for _, f in ipairs(frames) do
        if f.type == "source_focused" then return true end
      end
      return false
    end)

    local saw_source = false
    for _, f in ipairs(frames) do
      if f.type == "source_focused" then
        saw_source = true
        assert.are.equal("src", f.origin)
        -- macOS resolves /tmp → /private/tmp; assert by basename.
        assert.is_true(f.payload.file:match("rtlbuddy_test%.sv$") ~= nil)
        assert.are.equal(1, f.payload.line)
        assert.are.equal(1, f.payload.col)
      end
    end
    assert.is_true(saw_source)

    require("rtlbuddy").disconnect()
    server:close()
    vim.env.RTL_BUDDY_HUB = nil
  end)
end)
