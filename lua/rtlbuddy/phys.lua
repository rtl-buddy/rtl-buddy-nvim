-- rtlbuddy.nvim — `rb phys` inline annotation: a module's cells, area and the
-- power of its instances, as end-of-line virtual text at its declaration.
--
-- The editor's share of rtl-buddy/rtl_buddy#558 Phase 5, carried by
-- rtl-buddy/rtl_buddy#596 §2 and tracked here as rtl-buddy/rtl-buddy-nvim#12.
-- Nothing here goes over the hub wire and no hub need be running: `rb phys`
-- reads artefacts already on disk and runs no tool, so the annotation is a
-- subprocess and a JSON parse, nothing more.
--
-- **One call makes one refresh**: `phys summary --limit 0`, whose payload holds
-- both halves of the physical model — every synthesis row (`cell_count`,
-- `area_um2`) and every instance row (path, cell, power). One subprocess per
-- project, cached per project root for the session, and the numbers for every
-- declaration in the buffer come out of that one payload.
--
-- The two halves spell `module` in two different namespaces, and which numbers
-- a name can carry follows from that:
--
--   * **cells and area** come from the synthesis half, whose `module` is an RTL
--     module as Yosys' `stat` saw it after elaboration;
--   * **power** is summed over the instance half's rows, whose `module` is the
--     Liberty cell each leaf is an instance of (`DFF_X1`, `NAND2_X1`) — so it
--     is shown for a declaration whose name is a *cell* name, and only then;
--   * a name **both** halves carry is two measurements of two different things
--     (an RTL module's cells beside an unrelated cell type's power), so the
--     power part is dropped rather than presented as one module's totals;
--   * a name the **synthesis half alone** carries gets no power, because no
--     instance row carries an RTL module's name. Attributing an RTL module's
--     power needs the instance hierarchy, which the schematic owns
--     (rtl-buddy/rtl-buddy-sch#22), not this annotation.
--
-- Those are exactly the answers `rb phys module <name>` gives today — its
-- `instance_join` note says "liberty-cell names only" for the third case and
-- "name collision" for the second — so the roll-up is summed from the summary
-- payload rather than fanned out into one subprocess per declared module. A
-- 30-module file would otherwise spawn 30 `rb` processes on one `BufEnter`.
--
-- Cost of that trade: `--limit 0` emits every instance row, which on a
-- 40k-instance run is ~5.8 MB of JSON and ~28 ms to decode — once per project
-- per session. A modules-only listing would make the read cheap without
-- costing the roll-up; that is rtl-buddy/rtl_buddy#606, not a reason to
-- head the ranking (a headed summary would leave most declarations blank).
--
-- Everything is async (`vim.system`) and debounced: BufEnter fires on every
-- window hop, and the UI may never wait on a process spawn.
local M = {}

local NS_NAME = "rtlbuddy_phys"
local HL_GROUP = "RtlBuddyPhys"
local AUGROUP = "RtlBuddyPhys"

-- Filetypes a buffer event refreshes for.
local FILETYPES = { verilog = true, systemverilog = true }

-- Coalescing window for buffer events, in ms.
local DEBOUNCE_MS = 150

local _state = {
  -- Live toggle (`:RtlBuddyPhys`), seeded from `phys.annotate`.
  annotate = false,
  -- The `rb` seam; injected by the tests, nil means the real subprocess.
  runner = nil,
  -- project root -> { index, error, notified, pending }
  cache = {},
  -- bufnr -> uv timer
  timers = {},
  -- bufnr -> refresh generation. A refresh spans a subprocess, so a buffer
  -- edited (or re-entered) while one is in flight has a newer answer on the
  -- way; the stale callback must not draw.
  generations = {},
}

local function namespace()
  return vim.api.nvim_create_namespace(NS_NAME)
end

-- Deliberately quieter than WaveValue: a wave value is a launch-time answer to
-- a question just asked, while these are ambient numbers trailing code that
-- must stay the thing being read.
local function set_hl()
  vim.api.nvim_set_hl(0, HL_GROUP, { fg = "#6c7086", italic = true })
end

-- ---------------------------------------------------------------------------
-- formatting
-- ---------------------------------------------------------------------------

-- "1234" -> "1 234". A virtual-text line is read at a glance beside the
-- declaration, and "12345 cells" is not read at a glance. The sign is split
-- off first, so a three-digit negative does not come back as "- 123".
local function group(digits)
  local sign, rest = digits:match("^(%-?)(%d+)$")
  if not rest then
    return digits
  end
  local out = rest:sub(-3)
  rest = rest:sub(1, -4)
  while #rest > 3 do
    out = rest:sub(-3) .. " " .. out
    rest = rest:sub(1, -4)
  end
  if rest ~= "" then
    out = rest .. " " .. out
  end
  return sign .. out
end

-- One physical scalar. Two decimals below 10 so a fraction-of-a-µW total does
-- not render as "0.0 µW" — absent and negligible are different answers — and
-- one above it so the common case stays short.
local function scalar(value)
  local text = string.format(math.abs(value) < 10 and "%.2f" or "%.1f", value)
  local int, frac = text:match("^(%-?%d+)%.(%d+)$")
  if not int then
    return text
  end
  return group(int) .. "." .. frac
end

-- The annotation for one module, or nil when nothing at all is known about it
-- (which is how a name the model holds no numbers for gets no mark rather than
-- an empty one).
local function annotation(cells, area, power)
  local parts = {}
  if type(cells) == "number" then
    table.insert(parts, group(string.format("%d", cells)) .. " cells")
  end
  if type(area) == "number" then
    table.insert(parts, scalar(area) .. " µm²")
  end
  if type(power) == "number" then
    table.insert(parts, scalar(power) .. " µW")
  end
  if #parts == 0 then
    return nil
  end
  return "▸ " .. table.concat(parts, " · ")
end

-- ---------------------------------------------------------------------------
-- the buffer's declarations
-- ---------------------------------------------------------------------------

-- The module name a line declares, or nil.
--
-- A plain pattern match on the keyword, not a parse: this plugin never
-- re-parses Verilog (Verible and the hub own that), and a declaration line is
-- the one construct a pattern gets right. Anchored at the start of the line so
-- `endmodule` and an instantiation mentioning the word are never matched, and
-- a name is only taken when the keyword opens the line. SystemVerilog allows a
-- lifetime qualifier between the keyword and the name (`module automatic foo`),
-- which is skipped rather than read as the name; both are reserved words, so a
-- module cannot be called either.
local function declared_name(line)
  local rest = line:match("^%s*module%s+(.*)$") or line:match("^%s*macromodule%s+(.*)$")
  if not rest then
    return nil
  end
  rest = rest:gsub("^static%s+", "")
  rest = rest:gsub("^automatic%s+", "")
  return rest:match("^([%a_][%w_$]*)")
end

-- Every declaration in the buffer, with 0-based line numbers.
local function declarations(bufnr)
  local found = {}
  for lnum, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local name = declared_name(line)
    if name then
      table.insert(found, { lnum = lnum - 1, name = name })
    end
  end
  return found
end

-- ---------------------------------------------------------------------------
-- reading `rb --machine phys`
-- ---------------------------------------------------------------------------

-- JSON `null` decodes to `vim.NIL`, which is *truthy* in Lua, and every field
-- of these payloads is optional by design. Each one is read through here.
local function present(value)
  if value == nil or value == vim.NIL then
    return nil
  end
  return value
end

-- The machine envelope out of one `rb` run. `rb` logs ahead of it on stdout,
-- so the envelope is the last line that parses as JSON and carries a payload —
-- which is how rtl_buddy's own tests read it (tests/test_phys_verbs.py).
local function decode_envelope(stdout)
  local lines = vim.split(stdout or "", "\n", { plain = true, trimempty = true })
  for i = #lines, 1, -1 do
    local ok, decoded = pcall(vim.json.decode, lines[i])
    if ok and type(decoded) == "table" and type(decoded.payload) == "table" then
      return decoded
    end
  end
  return nil
end

-- One run's stdout and exit code -> its payload, or nil and a one-line reason.
--
-- A refusal is an envelope whose payload carries `error`, and its `exit_code`
-- is the verb's own rather than the process' (machine mode reports the refusal
-- in the document and still exits 0 in some paths, so both are checked). No
-- envelope at all — `rb` missing, a crash, a traceback — is the same kind of
-- answer here: no numbers.
local function envelope_result(stdout, code, shown)
  local envelope = decode_envelope(stdout)
  if not envelope then
    return nil, string.format("`%s` emitted no machine envelope (exit %s)", shown, tostring(code))
  end
  local refusal = present(envelope.payload.error)
  if refusal then
    return nil, tostring(refusal)
  end
  local reported = present(envelope.exit_code) or code
  if reported ~= 0 then
    return nil, string.format("`%s` exited %s", shown, tostring(reported))
  end
  return envelope.payload
end

-- The real runner: `rb --machine phys <args…>` in `cwd`, calling
-- `done(payload)` on success and `done(nil, why)` otherwise.
local function spawn(args, cwd, done)
  local shown = "rb phys " .. table.concat(args, " ")
  if vim.fn.executable("rb") == 0 then
    done(nil, "`rb` is not on PATH")
    return
  end
  local argv = { "rb", "--machine", "phys" }
  vim.list_extend(argv, args)
  vim.system(argv, { cwd = cwd, text = true }, function(result)
    -- vim.system's on_exit runs in a fast event context; nothing below may
    -- touch the API from there.
    vim.schedule(function()
      done(envelope_result(result.stdout, result.code, shown))
    end)
  end)
end

local function runner()
  return _state.runner or spawn
end

-- ---------------------------------------------------------------------------
-- the per-project cache
-- ---------------------------------------------------------------------------

local function cache_for(root)
  local entry = _state.cache[root]
  if not entry then
    entry = {}
    _state.cache[root] = entry
  end
  return entry
end

-- One line, at DEBUG, once per project: a project with no physical model is
-- the normal state of most buffers, not something to interrupt anyone over,
-- and `:checkhealth rtlbuddy` is where the standing answer lives.
local function report(entry, reason)
  if entry.notified then
    return
  end
  entry.notified = true
  vim.notify("rtlbuddy phys: " .. reason, vim.log.levels.DEBUG)
end

-- One name out of either half's `module` column. `name` is accepted as well,
-- so a future spelling of the column would not blank the display.
local function row_name(row)
  local name = present(row.module) or present(row.name)
  return name and tostring(name) or nil
end

-- The whole payload as one index: name -> { cells, area, power }.
--
-- Which numbers a name may carry is the namespace rule this module's header
-- sets out. The power sum skips rows whose total was never measured (`null` in,
-- `null` out, as rtl_buddy's own `_power_sum` has it), so a cell type nothing
-- reported power for stays a known name with no numbers rather than 0 µW; and
-- a name the synthesis half also carries keeps its cells and area and gets no
-- power at all.
local function index_payload(payload)
  local index = {}
  for _, row in ipairs(present(payload.modules) or {}) do
    local name = row_name(row)
    if name then
      index[name] = { cells = present(row.cell_count), area = present(row.area_um2) }
    end
  end
  -- Summed into a table of its own and merged after, because one cell name has
  -- many instance rows: accumulating straight into `index` would make the
  -- second row of a cell look like a name already claimed by the first.
  -- `false` is a name whose rows carried no measured total — a known name with
  -- no numbers, which is not the same as 0 µW.
  local power = {}
  for _, row in ipairs(present(payload.instances) or {}) do
    local name = row_name(row)
    -- Only for a cell name the synthesis half does not also claim: see above.
    if name and index[name] == nil then
      local total = present(row.total_uw)
      if type(total) == "number" then
        power[name] = (power[name] or 0.0) + total
      elseif power[name] == nil then
        power[name] = false
      end
    end
  end
  for name, total in pairs(power) do
    index[name] = { power = total or nil }
  end
  return index
end

-- `done(index)` with the project's index, or `done(nil)` when there is none.
-- Cached for the session — the physical model changes when `rb synth` or
-- `rb power` runs, not when a buffer is written, and `:RtlBuddyPhysRefresh` is
-- the way to say it did. Concurrent callers (two windows entered before the
-- first answer lands) share the one subprocess.
local function with_index(root, done)
  local entry = cache_for(root)
  if entry.error then
    done(nil)
    return
  end
  if entry.index then
    done(entry.index)
    return
  end
  if entry.pending then
    table.insert(entry.pending, done)
    return
  end
  entry.pending = { done }
  runner()({ "summary", "--limit", "0" }, root, function(payload, err)
    local waiters = entry.pending or {}
    entry.pending = nil
    if not payload then
      entry.error = err or "no physical model"
      report(entry, entry.error)
      for _, waiter in ipairs(waiters) do
        waiter(nil)
      end
      return
    end
    entry.index = index_payload(payload)
    for _, waiter in ipairs(waiters) do
      waiter(entry.index)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- drawing
-- ---------------------------------------------------------------------------

local function clear(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, namespace(), 0, -1)
  end
end

local function clear_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    clear(bufnr)
  end
end

-- Draw every declaration's numbers, from the index.
--
-- The declarations are re-derived here rather than taken from the scan the
-- refresh started with, because a subprocess sits between the two: the lines
-- that scan recorded may have moved, or stopped declaring anything, and a mark
-- placed at a snapshotted line number is then simply in the wrong place.
local function render(bufnr, index)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local ns = namespace()
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for _, decl in ipairs(declarations(bufnr)) do
    local row = index[decl.name]
    local text = row and annotation(row.cells, row.area, row.power)
    if text then
      vim.api.nvim_buf_set_extmark(bufnr, ns, decl.lnum, 0, {
        virt_text = { { text, HL_GROUP } },
        virt_text_pos = "eol",
      })
    end
  end
end

-- The buffer's project root: the directory `rb` is run in, since that is what
-- decides which project's artefacts it discovers. nil outside a project, and
-- then nothing is spawned at all — there is nothing to run `rb` against.
local function root_for(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local start = (name ~= "" and vim.fs.dirname(name)) or vim.uv.cwd()
  return require("rtlbuddy.discovery").project_root(start)
end

-- One buffer's annotation, from scratch.
function M.refresh(bufnr)
  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  if not _state.annotate or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  -- Bumped before the early returns below, not after them: a buffer whose last
  -- declaration was just deleted, or which has moved out of a project, must
  -- still invalidate the refresh that is in flight for it — otherwise that
  -- answer comes back and draws on lines this refresh has just found nothing
  -- at.
  local generation = (_state.generations[bufnr] or 0) + 1
  _state.generations[bufnr] = generation
  -- Whether this refresh is still the buffer's current one.
  local function current()
    return _state.annotate and _state.generations[bufnr] == generation
  end

  if #declarations(bufnr) == 0 then
    clear(bufnr)
    return
  end
  local root = root_for(bufnr)
  if not root then
    clear(bufnr)
    return
  end
  with_index(root, function(index)
    if not current() then
      return
    end
    if not index then
      clear(bufnr)
      return
    end
    render(bufnr, index)
  end)
end

-- Coalesce the buffer events. One timer per buffer, restarted on every event,
-- so a `:bnext` sweep through ten files spawns one refresh for the one you
-- stopped on.
local function schedule_refresh(bufnr)
  local timer = _state.timers[bufnr]
  if timer then
    timer:stop()
    timer:close()
  end
  timer = vim.uv.new_timer()
  _state.timers[bufnr] = timer
  timer:start(DEBOUNCE_MS, 0, function()
    timer:stop()
    timer:close()
    _state.timers[bufnr] = nil
    vim.schedule(function()
      M.refresh(bufnr)
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- public surface
-- ---------------------------------------------------------------------------

-- :RtlBuddyPhys — flip the annotation for the session; returns the new state.
-- Switching off clears every buffer's marks rather than only this one's: the
-- namespace is the feature, and a toggle that left marks behind in the windows
-- you had open elsewhere reads as a bug.
function M.toggle()
  _state.annotate = not _state.annotate
  if _state.annotate then
    M.refresh(vim.api.nvim_get_current_buf())
  else
    clear_all()
  end
  return _state.annotate
end

-- :RtlBuddyPhysRefresh — drop what was read for this buffer's project and read
-- it again. The cache is deliberately session-long, so this is how a `rb synth`
-- or `rb power` run in another terminal becomes visible. The whole entry goes:
-- everything in it came out of the one payload that is about to be re-read.
function M.force_refresh()
  local bufnr = vim.api.nvim_get_current_buf()
  local root = root_for(bufnr)
  if root then
    _state.cache[root] = nil
  end
  M.refresh(bufnr)
end

function M.enabled()
  return _state.annotate
end

-- Idempotent. Installs the highlight group, the buffer autocmds and the toggle
-- keymap. Re-running clears the autocmd group first, so calling setup() twice
-- does not stack duplicate autocmds.
--
-- opts: { annotate = true, keymap = "<leader>rp", runner = <fn> }. The
-- autocmds are installed even with annotate = false, because `:RtlBuddyPhys`
-- can switch it on later and the refresh itself is what the flag gates;
-- `runner` is the `rb` seam the tests inject and has no place in a config.
function M.setup(opts)
  opts = opts or {}
  local annotate = opts.annotate
  if annotate == nil then
    annotate = true
  end
  local key = opts.keymap
  if key == nil then
    key = "<leader>rp"
  end
  _state.annotate = annotate and true or false
  _state.runner = opts.runner
  -- A re-setup is a fresh configuration, possibly with a different runner;
  -- answers read through the old one are not this one's to reuse.
  _state.cache = {}

  set_hl()
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  -- :colorscheme wipes custom highlight groups; reapply on change.
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_hl })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
    group = group,
    callback = function(args)
      if FILETYPES[vim.bo[args.buf].filetype] then
        schedule_refresh(args.buf)
      end
    end,
  })

  if key then
    vim.keymap.set("n", key, M.toggle, {
      desc = "rtl-buddy phys: toggle module cells/area/power annotation",
    })
  end

  -- The buffer nvim was started on has already been entered by the time a
  -- lazy-loaded setup() runs, so its BufEnter will never fire again.
  if vim.v.vim_did_enter == 1 then
    local bufnr = vim.api.nvim_get_current_buf()
    if FILETYPES[vim.bo[bufnr].filetype] then
      schedule_refresh(bufnr)
    end
  else
    vim.api.nvim_create_autocmd("VimEnter", {
      group = group,
      callback = function()
        local bufnr = vim.api.nvim_get_current_buf()
        if FILETYPES[vim.bo[bufnr].filetype] then
          schedule_refresh(bufnr)
        end
      end,
    })
  end
end

-- Exposed for tests (hermetic: `runner` is injected, so no `rb` is needed).
M._declarations = declarations
M._annotation = annotation
M._index_payload = index_payload
M._decode_envelope = decode_envelope
M._envelope_result = envelope_result
M._state = _state

return M
