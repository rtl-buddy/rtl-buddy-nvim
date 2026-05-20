-- Diagnostics handler: maps hub `diagnostics_set` payloads onto the
-- `rtlbuddy` vim.diagnostic namespace, replays cached items when a
-- buffer for the affected file loads later, and merges across
-- multiple sources without losing earlier ones.
local diagnostics = require("rtlbuddy.diagnostics")

local TMP = vim.fn.tempname() .. ".sv"

local function items(file)
  return vim.diagnostic.get(vim.fn.bufnr(file), { namespace = diagnostics.ensure_namespace() })
end

describe("rtlbuddy.diagnostics", function()
  before_each(function()
    -- Wipe any state from a prior test.
    diagnostics._reset()
    pcall(vim.cmd, "bwipeout!")
  end)

  it("publishes items to a currently-loaded buffer", function()
    vim.cmd("edit " .. vim.fn.fnameescape(TMP))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "module a;", "  logic clk;", "endmodule" })

    diagnostics.apply("rtl-buddy-cdc", {
      { file = TMP, line = 2, col = 3, severity = "error", code = "CDC-001", message = "no sync" },
    })

    local got = items(TMP)
    assert.are.equal(1, #got)
    assert.are.equal(vim.diagnostic.severity.ERROR, got[1].severity)
    assert.are.equal(1, got[1].lnum) -- 0-based, was line 2
    assert.are.equal(2, got[1].col) -- 0-based, was col 3
    assert.are.equal("rtl-buddy-cdc", got[1].source)
    assert.are.equal("CDC-001", got[1].code)
  end)

  it("merges across multiple sources without dropping either set", function()
    vim.cmd("edit " .. vim.fn.fnameescape(TMP))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "module a;", "  logic clk;", "endmodule" })

    diagnostics.apply("rtl-buddy-cdc", {
      { file = TMP, line = 2, severity = "error", message = "cdc bad" },
    })
    diagnostics.apply("rtl-buddy-lint", {
      { file = TMP, line = 1, severity = "warning", message = "lint bad" },
    })

    local got = items(TMP)
    assert.are.equal(2, #got)
    local sources = { got[1].source, got[2].source }
    table.sort(sources)
    assert.are.same({ "rtl-buddy-cdc", "rtl-buddy-lint" }, sources)
  end)

  it("an empty items list clears the source but leaves other sources alone", function()
    vim.cmd("edit " .. vim.fn.fnameescape(TMP))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "module a;", "endmodule" })

    diagnostics.apply(
      "rtl-buddy-cdc",
      { { file = TMP, line = 1, severity = "error", message = "cdc bad" } }
    )
    diagnostics.apply(
      "rtl-buddy-lint",
      { { file = TMP, line = 1, severity = "warning", message = "lint" } }
    )
    assert.are.equal(2, #items(TMP))

    diagnostics.apply("rtl-buddy-cdc", {})
    local got = items(TMP)
    assert.are.equal(1, #got)
    assert.are.equal("rtl-buddy-lint", got[1].source)
  end)

  it("replays remembered items when the buffer loads later", function()
    -- Send items before the buffer exists.
    diagnostics.apply("rtl-buddy-cdc", {
      { file = TMP, line = 1, severity = "error", message = "late binding" },
    })
    -- Nothing to assert yet (no buffer); now open the file.
    diagnostics.install_autocmds()
    vim.cmd("edit " .. vim.fn.fnameescape(TMP))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "module a;", "endmodule" })

    local got = items(TMP)
    assert.are.equal(1, #got)
    assert.are.equal("late binding", got[1].message)
  end)

  it("maps every severity level", function()
    vim.cmd("edit " .. vim.fn.fnameescape(TMP))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "module a;", "endmodule" })

    diagnostics.apply("s", {
      { file = TMP, line = 1, severity = "error", message = "e" },
      { file = TMP, line = 1, severity = "warning", message = "w" },
      { file = TMP, line = 1, severity = "info", message = "i" },
      { file = TMP, line = 1, severity = "hint", message = "h" },
    })
    local got = items(TMP)
    local sevs = {}
    for _, d in ipairs(got) do
      sevs[d.message] = d.severity
    end
    assert.are.equal(vim.diagnostic.severity.ERROR, sevs["e"])
    assert.are.equal(vim.diagnostic.severity.WARN, sevs["w"])
    assert.are.equal(vim.diagnostic.severity.INFO, sevs["i"])
    assert.are.equal(vim.diagnostic.severity.HINT, sevs["h"])
  end)
end)
