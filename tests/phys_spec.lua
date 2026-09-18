-- Tests for the phys annotation (rtl-buddy/rtl-buddy-nvim#12, the editor's
-- share of rtl-buddy/rtl_buddy#596 §2).
--
-- Hermetic: no `rb` and no physical model. `setup({ runner = … })` injects the
-- seam that would spawn `rb --machine phys …`, and the fake answers with the
-- payload shapes rtl_buddy's own tests pin (tests/test_phys_verbs.py) —
-- `modules` rows keyed on `module` with `cell_count`/`area_um2`, and a module
-- payload carrying `instances`, `power.total_uw` and `instance_join`.
--
-- The injected runner answers synchronously, which the module tolerates by
-- design (it never assumes the callback lands on a later tick), so a refresh
-- is settled by the time the assertion runs.
local phys = require("rtlbuddy.phys")

local NS = vim.api.nvim_create_namespace("rtlbuddy_phys")

local SOURCE = {
  "module top (",
  "  input clk",
  ");",
  "  sub u_sub (.clk(clk));",
  "endmodule",
  "",
  "module sub;",
  "endmodule",
}

local SUMMARY = {
  manifest = "verif/blk/artefacts/both/phys-manifest.json",
  model = "verif/blk/artefacts/both/phys-model.json",
  generated_at = "2026-09-18T00:00:00Z",
  modules = {
    { module = "top", cell_count = 1234, area_um2 = 72.1 },
    { module = "sub", cell_count = 40, area_um2 = 96.0 },
  },
  -- The other namespace: the instance ranking's `module` is the Liberty cell
  -- each leaf is an instance of, never an RTL module.
  instances = {
    { instance_path = "u_sub/_64_", module = "DFF_X1", total_uw = 15.2 },
  },
}

-- `rb phys module <name>` for a module the power half can be joined to.
local function powered(total_uw)
  return {
    instances = { { instance_path = "u_sub/_64_", total_uw = total_uw } },
    power = { total_uw = total_uw },
    instance_join = vim.NIL,
  }
end

-- The same verb over a run with a power half that has no rows for the module.
local function unpowered()
  return { instances = {}, power = {}, instance_join = vim.NIL }
end

-- runner(args, cwd, done) — `summary` answers with SUMMARY, `module <name>`
-- with whatever `power_for` says. Every call is recorded for the callers that
-- assert nothing was spawned at all.
local function fake_runner(power_for, calls)
  return function(args, _cwd, done)
    table.insert(calls, table.concat(args, " "))
    if args[1] == "summary" then
      done(vim.deepcopy(SUMMARY))
    elseif args[1] == "module" then
      local answer = power_for and power_for(args[2])
      if answer then
        done(answer)
      else
        done(nil, "phys: no module " .. tostring(args[2]))
      end
    else
      done(nil, "unexpected verb")
    end
  end
end

local function extmarks()
  return vim.api.nvim_buf_get_extmarks(0, NS, 0, -1, { details = true })
end

-- lnum (0-based) -> the mark's virtual text.
local function annotations()
  local found = {}
  for _, mark in ipairs(extmarks()) do
    found[mark[2]] = mark[4].virt_text[1][1]
  end
  return found
end

local function setup(opts, calls)
  opts = opts or {}
  opts.keymap = false
  opts.runner = opts.runner or fake_runner(opts.power_for, calls or {})
  opts.power_for = nil
  phys.setup(opts)
end

describe("rtlbuddy.phys.setup", function()
  before_each(function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, SOURCE)
    vim.api.nvim_buf_clear_namespace(0, NS, 0, -1)
  end)

  it("defines its own highlight group, distinct from WaveValue", function()
    setup({})
    local hl = vim.api.nvim_get_hl(0, { name = "RtlBuddyPhys" })
    assert.are.equal(0x6c7086, hl.fg)
    assert.is_true(hl.italic)
  end)

  it("is idempotent — calling setup twice does not stack autocmds", function()
    setup({})
    setup({})
    local autocmds = vim.api.nvim_get_autocmds({ group = "RtlBuddyPhys", event = "BufEnter" })
    assert.are.equal(1, #autocmds)
  end)

  it("watches BufEnter and BufWritePost", function()
    setup({})
    for _, event in ipairs({ "BufEnter", "BufWritePost" }) do
      local autocmds = vim.api.nvim_get_autocmds({ group = "RtlBuddyPhys", event = event })
      assert.are.equal(1, #autocmds)
    end
  end)
end)

describe("rtlbuddy.phys annotation", function()
  before_each(function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, SOURCE)
    vim.api.nvim_buf_clear_namespace(0, NS, 0, -1)
  end)

  it("marks each declaration line with the module's cells and area", function()
    setup({
      power_for = function()
        return unpowered()
      end,
    })
    phys.force_refresh()

    local marks = annotations()
    assert.are.equal("▸ 1 234 cells · 72.1 µm²", marks[0])
    assert.are.equal("▸ 40 cells · 96.0 µm²", marks[6])
    -- The instantiation on line 4 names `sub` too; only declarations are marked.
    assert.are.equal(2, #extmarks())
  end)

  it("appends the power roll-up when the module's instances carry it", function()
    setup({
      power_for = function(name)
        return name == "top" and powered(15.2) or unpowered()
      end,
    })
    phys.force_refresh()

    local marks = annotations()
    assert.are.equal("▸ 1 234 cells · 72.1 µm² · 15.2 µW", marks[0])
    assert.are.equal("▸ 40 cells · 96.0 µm²", marks[6])
  end)

  it("omits the power part when the instances half is empty", function()
    setup({
      power_for = function()
        return unpowered()
      end,
    })
    phys.force_refresh()

    assert.is_nil(annotations()[0]:find("µW"))
  end)

  it("omits the power part when the verb flags the join as not the module's", function()
    -- `instance_join` is set on a liberty-cell name collision and on the
    -- RTL-module join that cannot see leaves named after cells; either way the
    -- total is a different thing's power and must not ride on this mark.
    setup({
      power_for = function()
        local payload = powered(999.0)
        payload.instance_join = "name collision: …"
        return payload
      end,
    })
    phys.force_refresh()

    assert.are.equal("▸ 1 234 cells · 72.1 µm²", annotations()[0])
  end)

  it("annotates a declaration the power half alone knows with its power", function()
    -- A name in the instance ranking only has no cells and no area — those are
    -- the synthesis half's columns — so the mark is the power on its own.
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "module DFF_X1;", "endmodule" })
    setup({
      power_for = function()
        return powered(15.2)
      end,
    })
    phys.force_refresh()

    assert.are.equal("▸ 15.2 µW", annotations()[0])
  end)

  it("leaves a name neither half knows unannotated", function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "module ghost;", "endmodule" })
    setup({
      power_for = function()
        return unpowered()
      end,
    })
    phys.force_refresh()

    assert.are.equal(0, #extmarks())
  end)

  it("draws nothing, and spawns nothing, when annotate = false", function()
    local calls = {}
    setup({ annotate = false }, calls)
    phys.force_refresh()

    assert.are.equal(0, #extmarks())
    assert.are.equal(0, #calls)
  end)

  it("clears the marks when toggled off, and redraws when toggled on", function()
    setup({
      power_for = function()
        return unpowered()
      end,
    })
    phys.force_refresh()
    assert.are.equal(2, #extmarks())

    assert.is_false(phys.toggle())
    assert.are.equal(0, #extmarks())

    assert.is_true(phys.toggle())
    assert.are.equal(2, #extmarks())
  end)

  it("asks for the summary once per project, and once per module for power", function()
    local calls = {}
    setup({
      power_for = function()
        return unpowered()
      end,
    }, calls)
    phys.force_refresh()
    phys.refresh(0)

    assert.are.same({ "summary --limit 0", "module top", "module sub" }, calls)
  end)

  it("draws no mark when the model cannot be read", function()
    setup({
      runner = function(_args, _cwd, done)
        done(nil, "phys: no phys-manifest.json under /tmp; run `rb synth` first")
      end,
    })
    phys.force_refresh()

    assert.are.equal(0, #extmarks())
  end)
end)

describe("rtlbuddy.phys declarations", function()
  it("matches a declaration at the start of a line and nothing else", function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "module top #(parameter W = 8) (",
      "  macromodule mac;",
      "endmodule",
      "// module commented;",
      "  sub u_sub ();",
      "module    spaced;",
    })
    local decls = phys._declarations(0)
    assert.are.same({
      { lnum = 0, name = "top" },
      { lnum = 1, name = "mac" },
      { lnum = 5, name = "spaced" },
    }, decls)
  end)
end)

describe("rtlbuddy.phys formatting", function()
  it("groups thousands and keeps sub-unit values legible", function()
    assert.are.equal("▸ 1 234 567 cells", phys._annotation(1234567, nil, nil))
    assert.are.equal("▸ 72.1 µm²", phys._annotation(nil, 72.1, nil))
    -- A fraction of a µW is negligible, not absent; "0.0 µW" would say absent.
    assert.are.equal("▸ 0.04 µW", phys._annotation(nil, nil, 0.0351))
    assert.is_nil(phys._annotation(nil, nil, nil))
  end)
end)

describe("rtlbuddy.phys machine envelope", function()
  it("takes the last JSON line, past whatever rb logged before it", function()
    local stdout = table.concat({
      "some rb log line",
      '{"command": "phys summary", "exit_code": 0, "payload": {"modules": []}}',
      "",
    }, "\n")
    local envelope = phys._decode_envelope(stdout)
    assert.are.equal(0, envelope.exit_code)
    assert.are.same({}, envelope.payload.modules)
  end)

  it("is nil when nothing on stdout is an envelope", function()
    assert.is_nil(phys._decode_envelope("rb: command not found"))
    assert.is_nil(phys._decode_envelope(""))
  end)
end)
