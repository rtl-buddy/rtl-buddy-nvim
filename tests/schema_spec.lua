-- Per-type payload validation. Each case asserts at least one
-- "valid" shape AND one violation, with the violation's error
-- mentioning the offending field so a regression on the wrong field
-- gets caught.
local schema = require("rtlbuddy.schema")

local function env(type_, kind, payload)
  return {
    v = 1,
    id = "00000000-0000-4000-8000-000000000000",
    origin = "src",
    kind = kind,
    type = type_,
    payload = payload,
  }
end

describe("rtlbuddy.schema.validate", function()
  before_each(function()
    schema._reset_reported()
  end)

  it("accepts a well-formed source_focused event", function()
    assert.is_nil(schema.validate(env("source_focused", "event", {
      file = "/abs/path.sv",
      line = 12,
      col = 3,
    })))
  end)

  it("rejects source_focused with line < 1", function()
    local err = schema.validate(env("source_focused", "event", {
      file = "/abs/path.sv",
      line = 0,
      col = 3,
    }))
    assert.is_string(err)
    assert.is_truthy(err:find("line"), "error should mention 'line', got: " .. err)
  end)

  it("rejects source_focused with extra fields", function()
    local err = schema.validate(env("source_focused", "event", {
      file = "/abs/path.sv",
      line = 1,
      col = 1,
      extra = true,
    }))
    assert.is_truthy(err and err:find("extra"))
  end)

  it("accepts selection_changed with a single instance_path", function()
    assert.is_nil(schema.validate(env("selection_changed", "event", {
      instance_path = "top.u_fifo",
    })))
  end)

  it("accepts selection_changed with array instance_path", function()
    assert.is_nil(schema.validate(env("selection_changed", "event", {
      instance_path = { "top.u_fifo", "top.u_dut" },
    })))
  end)

  it("rejects selection_changed with empty-string entry", function()
    local err = schema.validate(env("selection_changed", "event", {
      instance_path = { "top.u_fifo", "" },
    }))
    assert.is_string(err)
  end)

  it("validates cursor_time_changed.t_fs as decimal string", function()
    assert.is_nil(schema.validate(env("cursor_time_changed", "event", { t_fs = "1234567890" })))
    assert.is_nil(schema.validate(env("cursor_time_changed", "event", { t_fs = "-42" })))
    assert.is_string(schema.validate(env("cursor_time_changed", "event", { t_fs = "1.5e3" })))
    assert.is_string(schema.validate(env("cursor_time_changed", "event", { t_fs = 1234 })))
  end)

  it("welcome accepts every peer in the closed vocabulary", function()
    assert.is_nil(schema.validate(env("welcome", "response", {
      server_version = "1.0.0",
      registered_clients = { "view", "wave", "src", "cli", "notebook", "graph", "cov" },
    })))
  end)

  it("welcome.registered_clients must be from the origin enum", function()
    assert.is_nil(schema.validate(env("welcome", "response", {
      server_version = "1.0.0",
      registered_clients = { "view", "src" },
    })))
    local err = schema.validate(env("welcome", "response", {
      server_version = "1.0.0",
      registered_clients = { "view", "bogus" },
    }))
    assert.is_truthy(err and err:find("registered_clients"))
  end)

  it("hello requires client/version/capabilities and rejects duplicates", function()
    assert.is_nil(schema.validate(env("hello", "request", {
      client = "src",
      version = "0.1.0",
      capabilities = { "open_source" },
    })))
    local err = schema.validate(env("hello", "request", {
      client = "src",
      version = "0.1.0",
      capabilities = { "x", "x" },
    }))
    assert.is_truthy(err)
  end)

  it("error code must be in the catalog", function()
    assert.is_nil(schema.validate(env("error", "error", {
      code = "not_connected",
      message = "no wave client",
    })))
    local err = schema.validate(env("error", "error", {
      code = "made_up",
      message = "...",
    }))
    assert.is_truthy(err and err:find("code"))
  end)

  it("rejects kind mismatch (e.g. selection_changed sent as request)", function()
    local err = schema.validate(env("selection_changed", "request", { instance_path = "x" }))
    assert.is_truthy(err and err:find("kind"))
  end)

  it("passes unknown types silently (protocol §11)", function()
    assert.is_nil(schema.validate(env("future_type", "event", { whatever = true })))
  end)

  it("accepts a well-formed diagnostics_set", function()
    assert.is_nil(schema.validate(env("diagnostics_set", "event", {
      source = "rtl-buddy-cdc",
      items = {
        { file = "/x.sv", line = 1, severity = "error", message = "m" },
        {
          file = "/y.sv",
          line = 2,
          col = 3,
          end_line = 2,
          end_col = 5,
          severity = "warning",
          code = "CDC-002",
          message = "depth",
        },
      },
    })))
  end)

  it("rejects diagnostics_set with bad severity", function()
    local err = schema.validate(env("diagnostics_set", "event", {
      source = "x",
      items = { { file = "/x.sv", line = 1, severity = "fatal", message = "m" } },
    }))
    assert.is_truthy(err and err:find("severity"))
  end)

  it("rejects diagnostics_set with missing message", function()
    local err = schema.validate(env("diagnostics_set", "event", {
      source = "x",
      items = { { file = "/x.sv", line = 1, severity = "error" } },
    }))
    assert.is_truthy(err and err:find("message"))
  end)

  it("accepts diagnostics_set with empty items (clear)", function()
    assert.is_nil(schema.validate(env("diagnostics_set", "event", { source = "x", items = {} })))
  end)

  it("accepts diagnostics_set items with an optional instance_path", function()
    assert.is_nil(schema.validate(env("diagnostics_set", "event", {
      source = "claude-analysis",
      items = {
        {
          file = "/abs/x.sv",
          line = 42,
          severity = "warning",
          code = "WAVE-1",
          message = "wr_ptr_q sampled while ce==0",
          instance_path = "top.u_dma",
        },
      },
    })))
  end)

  it("rejects diagnostics_set items with empty instance_path", function()
    local err = schema.validate(env("diagnostics_set", "event", {
      source = "claude-analysis",
      items = {
        {
          file = "/abs/x.sv",
          line = 42,
          severity = "warning",
          message = "m",
          instance_path = "",
        },
      },
    }))
    assert.is_truthy(err and err:find("instance_path"))
  end)

  it("bye accepts null or empty object payload", function()
    assert.is_nil(schema.validate(env("bye", "event", nil)))
    assert.is_nil(schema.validate(env("bye", "event", {})))
    assert.is_truthy(schema.validate(env("bye", "event", { extra = 1 })))
  end)

  it("resolve_wave_to_view request/response accept symmetric payloads", function()
    assert.is_nil(
      schema.validate(env("resolve_wave_to_view", "request", { wave_scope = "tb.dut.u_ff" }))
    )
    assert.is_nil(
      schema.validate(env("resolve_wave_to_view", "response", { instance_path = "counter.u_ff" }))
    )
  end)

  it("resolve_wave_to_view rejects empty wave_scope", function()
    local err = schema.validate(env("resolve_wave_to_view", "request", { wave_scope = "" }))
    assert.is_truthy(err)
    assert.is_truthy(err:find("wave_scope"))
  end)

  it("state_snapshot request accepts an empty payload", function()
    assert.is_nil(schema.validate(env("state_snapshot", "request", {})))
  end)

  it("state_snapshot response accepts a fully-populated snapshot", function()
    assert.is_nil(schema.validate(env("state_snapshot", "response", {
      active_model = "ip_demo_tiny_npu",
      selection = { instance_path = "counter.u_ff", origin = "view" },
      cursor_time = { t_fs = "12500000", origin = "wave" },
      wave_scope = { wave_scope = "tb.dut.u_ff", origin = "wave" },
      peers = { "view", "wave", "src" },
      diagnostics_sources = { "rtl-buddy-cdc" },
    })))
  end)

  it("state_snapshot response accepts an empty hub (all event slots null)", function()
    assert.is_nil(schema.validate(env("state_snapshot", "response", {
      active_model = nil,
      selection = nil,
      cursor_time = nil,
      wave_scope = nil,
      peers = {},
      diagnostics_sources = {},
    })))
  end)

  it("state_snapshot rejects an unknown origin on a slot", function()
    local err = schema.validate(env("state_snapshot", "response", {
      active_model = nil,
      selection = { instance_path = "x", origin = "viewer" },
      cursor_time = nil,
      wave_scope = nil,
      peers = {},
      diagnostics_sources = {},
    }))
    assert.is_truthy(err)
    assert.is_truthy(err:find("origin"))
  end)

  it("state_snapshot rejects a non-numeric t_fs", function()
    local err = schema.validate(env("state_snapshot", "response", {
      active_model = nil,
      selection = nil,
      cursor_time = { t_fs = "not-a-number", origin = "wave" },
      wave_scope = nil,
      peers = {},
      diagnostics_sources = {},
    }))
    assert.is_truthy(err)
    assert.is_truthy(err:find("t_fs"))
  end)

  it("validate_or_report notifies once per (type,kind)", function()
    local notifies = 0
    local original = vim.notify
    vim.notify = function()
      notifies = notifies + 1
    end
    local bad = env("source_focused", "event", { file = "/x", line = 0, col = 1 })
    schema.validate_or_report(bad)
    schema.validate_or_report(bad)
    -- vim.schedule queues; flush.
    vim.wait(50, function()
      return notifies > 0
    end)
    vim.notify = original
    assert.are.equal(1, notifies)
  end)
end)

-- The origin vocabulary fence.
--
-- `properties.origin.enum` in the vendored `hub-protocol-v1.json` owns
-- the wire vocabulary; CI's `schema-drift` job keeps that file identical
-- to rtl-buddy-sch `main`. The two Lua tables below are hand-copies of
-- the enum — this validator is pure Lua and never parses the JSON at
-- runtime — so re-syncing the schema without updating them leaves the
-- plugin rejecting an origin the hub is entitled to send. That is the
-- half-landing rtl-buddy/rtl-buddy-sch#154 is about; this reads the
-- vendored file rather than repeating the list a third time.
describe("origin vocabulary tracks the vendored schema", function()
  local protocol = require("rtlbuddy.protocol")

  local function schema_origins()
    local path = schema.ensure_schema_loaded()
    local doc = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    return doc.properties.origin.enum
  end

  local function sorted(list)
    local out = vim.deepcopy(list)
    table.sort(out)
    return out
  end

  it("finds a non-empty enum to compare against", function()
    -- Guard the guard: a schema refactor that moved the enum would make
    -- every assertion below pass against nil.
    local origins = schema_origins()
    assert.is_table(origins)
    assert.is_true(#origins > 0)
  end)

  it("is exactly rtlbuddy.schema's PEERS, in the schema's order", function()
    assert.are.same(schema_origins(), schema.PEERS)
  end)

  it("is exactly rtlbuddy.protocol's VALID_ORIGIN set", function()
    local from_set = {}
    for origin in pairs(protocol.VALID_ORIGIN) do
      from_set[#from_set + 1] = origin
    end
    assert.are.same(sorted(schema_origins()), sorted(from_set))
  end)

  it("contains every origin the plugin may emit", function()
    -- M.ORIGIN is deliberately a SUBSET — the origins nvim itself sends
    -- as, not the ones it must accept. A typo in it is still a bug.
    local valid = {}
    for _, origin in ipairs(schema_origins()) do
      valid[origin] = true
    end
    for name, origin in pairs(protocol.ORIGIN) do
      assert.is_true(valid[origin] == true, "protocol.ORIGIN." .. name .. " is not a wire origin")
    end
  end)
end)
