-- Tests for the phys annotation (rtl-buddy/rtl-buddy-nvim#12, the editor's
-- share of rtl-buddy/rtl_buddy#596 §2).
--
-- Hermetic: no `rb` and no physical model. `setup({ runner = … })` injects the
-- seam that would spawn `rb --machine phys summary --limit 0`, and the fake
-- answers with the payload shape rtl_buddy's own tests pin
-- (tests/test_phys_verbs.py): `modules` rows keyed on `module` with
-- `cell_count`/`area_um2`, and `instances` rows keyed on `module` with the
-- Liberty cell each leaf instantiates plus its `total_uw`.
--
-- The specs run from a temp directory carrying a `root_config.yaml`, so the
-- buffer really is inside a project `rb` would be run in. Without that, every
-- assertion that nothing is drawn would pass for the wrong reason — no project
-- root, so no read is even attempted.
local phys = require("rtlbuddy.phys")
-- Required before the cd below: plenary's child nvim can carry a *relative*
-- runtimepath entry, and a module first required from another directory would
-- then not be found.
local discovery = require("rtlbuddy.discovery")

local NS = vim.api.nvim_create_namespace("rtlbuddy_phys")

local ROOT = vim.fn.tempname()
local NO_PROJECT = vim.fn.tempname()
vim.fn.mkdir(ROOT, "p")
vim.fn.mkdir(NO_PROJECT, "p")
-- Resolved, because macOS' temp directory is reached through a symlink
-- (`/var/folders/…` -> `/private/var/folders/…`) and `:cd` reports the target:
-- comparing the two spellings would fail for a reason that is not the code's.
ROOT = vim.uv.fs_realpath(ROOT)
NO_PROJECT = vim.uv.fs_realpath(NO_PROJECT)
vim.fn.writefile({ "# a project root marker" }, ROOT .. "/root_config.yaml")
vim.cmd.cd(ROOT)

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

-- One `rb phys summary --limit 0` payload holding both halves of the model.
--   `top`      — synthesis only: cells and area, and no power, because no
--                instance row carries an RTL module's name.
--   `sub`      — in both halves: an RTL module *and* (here) a cell name, so
--                the power is a different thing's and is dropped.
--   `DFF_X1`   — a cell name: the two rows sum to 15.2 µW.
--   `NAND2_X1` — a cell name whose power was never measured.
local SUMMARY = {
  manifest = "verif/blk/artefacts/both/phys-manifest.json",
  model = "verif/blk/artefacts/both/phys-model.json",
  generated_at = "2026-09-18T00:00:00Z",
  modules = {
    { module = "top", cell_count = 1234, area_um2 = 72.1 },
    { module = "sub", cell_count = 40, area_um2 = 96.0 },
  },
  instances = {
    { instance_path = "u_sub/_64_", module = "DFF_X1", total_uw = 12.7 },
    { instance_path = "u_sub/u_leaf/_12_", module = "DFF_X1", total_uw = 2.5 },
    { instance_path = "u_sub/_9_", module = "NAND2_X1", total_uw = vim.NIL },
    { instance_path = "u_sub/_7_", module = "sub", total_uw = 99.0 },
  },
}

-- runner(args, cwd, done) — answers the summary straight away and records the
-- call, so a spec can assert the read happened rather than only that nothing
-- was drawn.
local function fake_runner(calls)
  return function(args, cwd, done)
    table.insert(calls, { args = table.concat(args, " "), cwd = cwd })
    done(vim.deepcopy(SUMMARY))
  end
end

-- A runner that holds its answer until the spec releases it.
local function deferred_runner(calls)
  local held = {}
  return function(args, cwd, done)
    table.insert(calls, { args = table.concat(args, " "), cwd = cwd })
    table.insert(held, function()
      done(vim.deepcopy(SUMMARY))
    end)
  end, function()
    for _, release in ipairs(held) do
      release()
    end
    held = {}
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

local function verbs(calls)
  return vim.tbl_map(function(call)
    return call.args
  end, calls)
end

-- setup() with the keymap off and a runner installed; returns the call log.
local function setup(opts)
  opts = vim.tbl_extend("force", { keymap = false }, opts or {})
  local calls = opts.calls or {}
  opts.calls = nil
  opts.runner = opts.runner or fake_runner(calls)
  phys.setup(opts)
  return calls
end

describe("rtlbuddy.phys test project", function()
  it("really is a project root, and NO_PROJECT really is not", function()
    assert.are.equal(vim.fs.normalize(ROOT), discovery.project_root(ROOT))
    assert.is_nil(discovery.project_root(NO_PROJECT))
    assert.are.equal(vim.fs.normalize(ROOT), vim.fs.normalize(vim.uv.cwd()))
  end)
end)

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
    local calls = setup({})
    phys.force_refresh()

    local marks = annotations()
    assert.are.equal("▸ 1 234 cells · 72.1 µm²", marks[0])
    assert.are.equal("▸ 40 cells · 96.0 µm²", marks[6])
    -- The instantiation on line 4 names `sub` too; only declarations are marked.
    assert.are.equal(2, #extmarks())
    -- One read, in the project root, and no per-module fan-out.
    assert.are.same({ "summary --limit 0" }, verbs(calls))
    assert.are.equal(vim.fs.normalize(ROOT), vim.fs.normalize(calls[1].cwd))
  end)

  it("sums the instance rows of a liberty-cell name into its power", function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "module DFF_X1;", "endmodule" })
    local calls = setup({})
    phys.force_refresh()

    -- 12.7 + 2.5, and no cells or area: those are the synthesis half's columns.
    assert.are.equal("▸ 15.2 µW", annotations()[0])
    assert.are.same({ "summary --limit 0" }, verbs(calls))
  end)

  it("omits the power of a name both halves carry", function()
    -- `sub` is an RTL module here *and* the cell name on an instance row. The
    -- two are measurements of two different things, so only its own cells and
    -- area are shown — never that cell type's 99 µW.
    local calls = setup({})
    phys.force_refresh()

    assert.are.equal("▸ 40 cells · 96.0 µm²", annotations()[6])
    assert.is_nil(annotations()[6]:find("µW"))
    assert.are.same({ "summary --limit 0" }, verbs(calls))
  end)

  it("omits the power of a cell name nothing measured", function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "module NAND2_X1;", "endmodule" })
    local calls = setup({})
    phys.force_refresh()

    -- A known name with no numbers, which is not the same as 0.0 µW.
    assert.are.equal(0, #extmarks())
    assert.are.same({ "summary --limit 0" }, verbs(calls))
  end)

  it("leaves a name neither half knows unannotated", function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "module ghost;", "endmodule" })
    local calls = setup({})
    phys.force_refresh()

    assert.are.equal(0, #extmarks())
    -- Not vacuous: the model really was read, and simply has no such name.
    assert.are.same({ "summary --limit 0" }, verbs(calls))
  end)

  it("draws nothing, and spawns nothing, when annotate = false", function()
    local calls = setup({ annotate = false })
    phys.force_refresh()

    assert.are.equal(0, #extmarks())
    assert.are.equal(0, #calls)
  end)

  it("clears the marks when toggled off, and redraws when toggled on", function()
    setup({})
    phys.force_refresh()
    assert.are.equal(2, #extmarks())

    assert.is_false(phys.toggle())
    assert.are.equal(0, #extmarks())

    assert.is_true(phys.toggle())
    assert.are.equal(2, #extmarks())
  end)

  it("reads once per project, however many refreshes follow", function()
    local calls = setup({})
    phys.force_refresh()
    phys.refresh(0)
    phys.refresh(0)

    assert.are.same({ "summary --limit 0" }, verbs(calls))
  end)

  it("re-reads the model on :RtlBuddyPhysRefresh", function()
    local calls = setup({})
    phys.force_refresh()
    phys.force_refresh()

    assert.are.same({ "summary --limit 0", "summary --limit 0" }, verbs(calls))
  end)

  it("draws no mark when the model cannot be read", function()
    local calls = {}
    setup({
      runner = function(args, _cwd, done)
        table.insert(calls, table.concat(args, " "))
        done(nil, "phys: no phys-manifest.json under " .. ROOT .. "; run `rb synth` first")
      end,
    })
    phys.force_refresh()

    assert.are.equal(0, #extmarks())
    assert.are.same({ "summary --limit 0" }, calls)
  end)

  it("places the marks at the declarations as they are when the answer lands", function()
    -- The scan that starts a refresh and the draw that ends it are separated by
    -- a subprocess; a mark placed at the line number recorded before it would
    -- land in the wrong place.
    local calls = {}
    local runner, release = deferred_runner(calls)
    setup({ runner = runner })
    phys.refresh(0)
    -- Three lines inserted above while the read is in flight: the declarations
    -- have moved from lines 0 and 6 to 3 and 9.
    vim.api.nvim_buf_set_lines(0, 0, 0, false, { "// a", "// b", "// c" })
    release()

    local marks = annotations()
    assert.is_nil(marks[0])
    assert.are.equal("▸ 1 234 cells · 72.1 µm²", marks[3])
    assert.are.equal("▸ 40 cells · 96.0 µm²", marks[9])
    assert.are.equal(2, #extmarks())
    assert.are.same({ "summary --limit 0" }, verbs(calls))
  end)

  it("ignores an answer for a buffer that no longer declares anything", function()
    local calls = {}
    local runner, release = deferred_runner(calls)
    setup({ runner = runner })
    phys.refresh(0)

    -- The declarations are gone before the answer lands, and the refresh that
    -- notices it must invalidate the one in flight.
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "// nothing declared here" })
    phys.refresh(0)
    release()

    assert.are.equal(0, #extmarks())
  end)

  it("ignores an answer for a buffer that has left the project", function()
    local calls = {}
    local runner, release = deferred_runner(calls)
    setup({ runner = runner })
    phys.refresh(0)

    -- Still declaring modules, but no longer inside a project: the refresh that
    -- finds no root must invalidate the one in flight just the same, or its
    -- answer draws numbers from a project this buffer is not in.
    vim.cmd.cd(NO_PROJECT)
    phys.refresh(0)
    release()
    vim.cmd.cd(ROOT)

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
      "module automatic lifetime_a;",
      "module static lifetime_s;",
      "module staticky;",
    })
    assert.are.same({
      { lnum = 0, name = "top" },
      { lnum = 1, name = "mac" },
      { lnum = 5, name = "spaced" },
      { lnum = 6, name = "lifetime_a" },
      { lnum = 7, name = "lifetime_s" },
      { lnum = 8, name = "staticky" },
    }, phys._declarations(0))
  end)
end)

describe("rtlbuddy.phys index", function()
  it("keeps the two halves' namespaces apart", function()
    local index = phys._index_payload(vim.deepcopy(SUMMARY))
    assert.are.same({ cells = 1234, area = 72.1 }, index.top)
    assert.are.same({ cells = 40, area = 96.0 }, index.sub)
    assert.are.equal(15.2, index.DFF_X1.power)
    assert.is_nil(index.DFF_X1.cells)
    assert.are.same({}, index.NAND2_X1)
    assert.is_nil(index.ghost)
  end)

  it("survives a payload with a null half", function()
    local index = phys._index_payload({ modules = vim.NIL, instances = vim.NIL })
    assert.are.same({}, index)
  end)
end)

describe("rtlbuddy.phys formatting", function()
  it("groups thousands and keeps sub-unit values legible", function()
    assert.are.equal("▸ 1 234 567 cells", phys._annotation(1234567, nil, nil))
    assert.are.equal("▸ 72.1 µm²", phys._annotation(nil, 72.1, nil))
    -- A fraction of a µW is negligible, not absent; "0.0 µW" would say absent.
    assert.are.equal("▸ 0.04 µW", phys._annotation(nil, nil, 0.0351))
    -- A sign is split off before grouping, not treated as a leading digit.
    assert.are.equal("▸ -123.0 µW", phys._annotation(nil, nil, -123.0))
    assert.are.equal("▸ -1 234.0 µW", phys._annotation(nil, nil, -1234.0))
    assert.is_nil(phys._annotation(nil, nil, nil))
  end)
end)

describe("rtlbuddy.phys machine envelope", function()
  local function envelope(payload, exit_code)
    return vim.json.encode({ command = "phys summary", exit_code = exit_code, payload = payload })
  end

  it("takes the last JSON line, past whatever rb logged before it", function()
    local stdout = table.concat({ "some rb log line", envelope({ modules = {} }, 0), "" }, "\n")
    local decoded = phys._decode_envelope(stdout)
    assert.are.equal(0, decoded.exit_code)
    assert.are.same({}, decoded.payload.modules)
  end)

  it("is nil when nothing on stdout is an envelope", function()
    assert.is_nil(phys._decode_envelope("rb: command not found"))
    assert.is_nil(phys._decode_envelope(""))
  end)

  it("returns the payload of a clean run", function()
    local payload, err = phys._envelope_result(envelope({ modules = {} }, 0), 0, "rb phys summary")
    assert.is_nil(err)
    assert.are.same({}, payload.modules)
  end)

  it("reports the verb's own refusal verbatim", function()
    local refusal = "phys: no phys-manifest.json under /x; run `rb synth` or `rb power` first"
    local payload, err =
      phys._envelope_result(envelope({ error = refusal }, 2), 0, "rb phys summary")
    assert.is_nil(payload)
    assert.are.equal(refusal, err)
  end)

  it("reports a non-zero exit code even with no error in the payload", function()
    local payload, err = phys._envelope_result(envelope({ modules = {} }, 2), 0, "rb phys summary")
    assert.is_nil(payload)
    assert.are.equal("`rb phys summary` exited 2", err)
  end)

  it("reports stdout that carries no envelope at all", function()
    local payload, err = phys._envelope_result("Traceback (most recent call last):", 1, "rb phys x")
    assert.is_nil(payload)
    assert.are.equal("`rb phys x` emitted no machine envelope (exit 1)", err)
  end)
end)
