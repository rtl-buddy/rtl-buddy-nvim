local discovery = require("rtlbuddy.discovery")

describe("rtlbuddy.discovery", function()
  it("honours RTL_BUDDY_HUB override", function()
    vim.env.RTL_BUDDY_HUB = "127.0.0.1:54321"
    local r = discovery.locate()
    assert.are.equal("127.0.0.1", r.host)
    assert.are.equal(54321, r.port)
    vim.env.RTL_BUDDY_HUB = nil
  end)

  it("rejects malformed RTL_BUDDY_HUB", function()
    vim.env.RTL_BUDDY_HUB = "not-a-host-port"
    local r = discovery.locate()
    assert.is_string(r.error)
    vim.env.RTL_BUDDY_HUB = nil
  end)

  it("returns an error when no hub.json is found", function()
    -- A tmpdir we know has no .rtl-buddy/ above it would be the right
    -- thing here, but mac /private/tmp may sit under a tree that does.
    -- Smoke-test only: a real CI runs from a clean tmpdir.
    local r = discovery.locate("/")
    assert.is_string(r.error)
  end)
end)
