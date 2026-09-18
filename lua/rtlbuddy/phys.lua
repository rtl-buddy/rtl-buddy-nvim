-- rtlbuddy.nvim — `rb phys` inline annotation: a module's cells, area and the
-- power of its instances, as end-of-line virtual text at its declaration.
--
-- The editor's share of rtl-buddy/rtl_buddy#558 Phase 5, carried by
-- rtl-buddy/rtl_buddy#596 §2 and tracked here as rtl-buddy/rtl-buddy-nvim#12.
-- Nothing here goes over the hub wire and no hub need be running: `rb phys`
-- reads artefacts already on disk and runs no tool, so the annotation is a
-- subprocess and a JSON parse, nothing more.
--
-- Two calls make one refresh, because the two halves of the physical model
-- spell `module` in two different namespaces:
--
--   * `phys summary --limit 0` — every name the model holds, with the cells
--     and area the synthesis half has for it. One subprocess for the whole
--     project, cached per project root for the session.
--   * `phys module <name>` — the power roll-up, one call per module *declared
--     in the buffer* (a file declares a handful, not thousands) and only for
--     names the summary knows.
--
-- The roll-up is asked of the verb rather than summed here, because the join
-- it makes is the whole difficulty: the power half's `module` column names
-- Liberty *cells* (`DFF_X1`), never RTL modules, so summing instance rows by
-- name in the editor would attribute one namespace's power to the other's
-- blocks. `instance_join` on the payload is how the verb says the rows it
-- joined are *not* the named module's power — a name that is a module in one
-- half and a cell in the other, or the RTL-module join that cannot see leaves
-- named after cells — and the power part is omitted whenever it is set. Until
-- rtl_buddy's hierarchy join lands (rtl-buddy/rtl_buddy#558) that is most RTL
-- modules, so most marks are cells and area alone; nothing here has to change
-- when it does.
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
  -- project root -> { token, modules, power, error, notified, pending }
  cache = {},
  -- bufnr -> uv timer
  timers = {},
  -- bufnr -> refresh generation. A refresh spans two subprocesses, so a buffer
  -- edited (or re-entered) while one is in flight has a newer set of rows on
  -- the way; the stale callback must not draw over it.
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
-- declaration, and "12345 cells" is not read at a glance.
local function group(digits)
  local out = digits:sub(-3)
  local rest = digits:sub(1, -4)
  while #rest > 3 do
    out = rest:sub(-3) .. " " .. out
    rest = rest:sub(1, -4)
  end
  if rest ~= "" then
    out = rest .. " " .. out
  end
  return out
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
-- (which is how an undeclared-in-the-model module gets no mark rather than an
-- empty one).
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

-- Every `module <name>` declaration line in the buffer, 0-based.
--
-- A plain pattern match on the keyword, not a parse: this plugin never
-- re-parses Verilog (Verible and the hub own that), and a declaration line is
-- the one construct a pattern gets right. Anchored at the start of the line so
-- `endmodule` and an instantiation mentioning the word are never matched, and
-- a name is only taken when the keyword opens the line.
local function declarations(bufnr)
  local found = {}
  for lnum, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local name = line:match("^%s*module%s+([%a_][%w_$]*)")
      or line:match("^%s*macromodule%s+([%a_][%w_$]*)")
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

-- The real runner: `rb --machine phys <args…>` in `cwd`, calling
-- `done(payload)` on success and `done(nil, why)` otherwise. A refusal is a
-- payload with an `error` on a non-zero `exit_code`, and both a missing `rb`
-- and an unparseable stdout are the same kind of answer here: no numbers.
local function spawn(args, cwd, done)
  if vim.fn.executable("rb") == 0 then
    done(nil, "`rb` is not on PATH")
    return
  end
  local argv = { "rb", "--machine", "phys" }
  vim.list_extend(argv, args)
  local shown = "rb phys " .. table.concat(args, " ")
  vim.system(argv, { cwd = cwd, text = true }, function(result)
    -- vim.system's on_exit runs in a fast event context; nothing below may
    -- touch the API from there.
    vim.schedule(function()
      local envelope = decode_envelope(result.stdout)
      if not envelope then
        done(nil, string.format("`%s` emitted no machine envelope (exit %d)", shown, result.code))
        return
      end
      local refusal = present(envelope.payload.error)
      if refusal then
        done(nil, refusal)
        return
      end
      local code = present(envelope.exit_code) or result.code
      if code ~= 0 then
        done(nil, string.format("`%s` exited %s", shown, tostring(code)))
        return
      end
      done(envelope.payload)
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
    entry = { power = {} }
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

-- What tells one publication of the model from the next. The payload does not
-- carry the model's own `publication` token, so this is the triple that moves
-- with it: which manifest was read, which model it named, and when that pair
-- was written. A change invalidates the per-module power roll-ups, which were
-- read out of the previous publication.
local function publication_token(payload)
  return table.concat({
    tostring(present(payload.manifest) or "?"),
    tostring(present(payload.model) or "?"),
    tostring(present(payload.generated_at) or "?"),
  }, "|")
end

-- Every name the model can be asked about, keyed by name, carrying the cells
-- and area the synthesis half has for it.
--
-- `module` is what the column is called in both halves of the payload (`name`
-- is accepted as well, so a future spelling would not blank the display), but
-- they are two namespaces: the synthesis ranking names RTL modules as Yosys'
-- `stat` saw them, and the instance ranking names the Liberty cell each leaf
-- is an instance of. Both are indexed, because both are names a buffer can
-- declare and the second is the only one power can be attributed to today;
-- a name from the instance ranking alone carries no cells or area, which are
-- the synthesis half's columns and nothing else's.
--
-- This is why the summary is read with `--limit 0`: a headed ranking would
-- index the ten heaviest modules and silently leave every other declaration
-- in the buffer unannotated.
local function index_modules(payload)
  local rows = {}
  for _, row in ipairs(present(payload.modules) or {}) do
    local name = present(row.module) or present(row.name)
    if name then
      rows[tostring(name)] = { cells = present(row.cell_count), area = present(row.area_um2) }
    end
  end
  for _, row in ipairs(present(payload.instances) or {}) do
    local name = present(row.module) or present(row.name)
    if name and not rows[tostring(name)] then
      rows[tostring(name)] = {}
    end
  end
  return rows
end

-- `done(modules)` with the project's module index, or `done(nil)` when there
-- is none. Cached for the session — the physical model changes when `rb synth`
-- or `rb power` runs, not when a buffer is written, and
-- `:RtlBuddyPhysRefresh` is the way to say it did. Concurrent callers (two
-- windows entered before the first answer lands) share the one subprocess.
local function with_summary(root, done)
  local entry = cache_for(root)
  if entry.error then
    done(nil)
    return
  end
  if entry.modules then
    done(entry.modules)
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
    local token = publication_token(payload)
    if entry.token and entry.token ~= token then
      entry.power = {}
    end
    entry.token = token
    entry.modules = index_modules(payload)
    for _, waiter in ipairs(waiters) do
      waiter(entry.modules)
    end
  end)
end

-- One module payload -> its instances' total power in µW, or nil.
--
-- nil in the three cases the verb keeps apart, and this annotation must not
-- blur: no power half at all (`instances` is null), a power half with no rows
-- for this module (`instances` empty), and any payload carrying an
-- `instance_join` note — which is the verb saying the rows it joined are not
-- this module's power. See `module_payload` in rtl_buddy's
-- src/rtl_buddy/phys/query.py.
local function module_power(payload)
  if present(payload.instance_join) then
    return nil
  end
  local instances = present(payload.instances)
  if type(instances) ~= "table" or vim.tbl_isempty(instances) then
    return nil
  end
  local power = present(payload.power)
  if type(power) ~= "table" then
    return nil
  end
  local total = present(power.total_uw)
  if type(total) ~= "number" then
    return nil
  end
  return total
end

-- `done(total_uw)` for one module, cached per root. `false` is a cached "there
-- is none": a module whose power is genuinely absent — the common shape on a
-- synthesis-only run — must not be re-asked on every BufEnter.
local function with_power(root, name, done)
  local entry = cache_for(root)
  local cached = entry.power[name]
  if cached ~= nil then
    done(cached or nil)
    return
  end
  runner()({ "module", name }, root, function(payload, err)
    if not payload then
      entry.power[name] = false
      report(entry, err or ("no power for module " .. name))
      done(nil)
      return
    end
    local total = module_power(payload)
    entry.power[name] = total or false
    done(total)
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

-- Redraw the whole set. Called once when the summary lands and again as each
-- power roll-up arrives, so cells and area appear immediately rather than at
-- the speed of the slowest call. The line count is re-checked because the
-- buffer may have been edited while a subprocess was in flight.
local function render(bufnr, rows)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local ns = namespace()
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local lines = vim.api.nvim_buf_line_count(bufnr)
  for _, row in ipairs(rows) do
    local text = annotation(row.cells, row.area, row.power)
    if text and row.lnum < lines then
      vim.api.nvim_buf_set_extmark(bufnr, ns, row.lnum, 0, {
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
  local decls = declarations(bufnr)
  if #decls == 0 then
    clear(bufnr)
    return
  end
  local root = root_for(bufnr)
  if not root then
    return
  end
  local generation = (_state.generations[bufnr] or 0) + 1
  _state.generations[bufnr] = generation
  -- Whether this refresh is still the buffer's current one.
  local function current()
    return _state.annotate and _state.generations[bufnr] == generation
  end
  with_summary(root, function(modules)
    if not current() then
      return
    end
    if not modules then
      clear(bufnr)
      return
    end
    local rows = {}
    for _, decl in ipairs(decls) do
      local row = modules[decl.name]
      -- A declaration the model knows no name for gets no mark at all: the
      -- model is of one run of one top, and a buffer's other modules were
      -- simply not in it.
      if row then
        table.insert(rows, {
          lnum = decl.lnum,
          name = decl.name,
          cells = row.cells,
          area = row.area,
        })
      end
    end
    render(bufnr, rows)
    for _, row in ipairs(rows) do
      with_power(root, row.name, function(total)
        if total and current() then
          row.power = total
          render(bufnr, rows)
        end
      end)
    end
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
-- or `rb power` run in another terminal becomes visible. The power roll-ups
-- are carried over and dropped only if the new summary names a different
-- publication, which is the one thing that can have staled them.
function M.force_refresh()
  local bufnr = vim.api.nvim_get_current_buf()
  local root = root_for(bufnr)
  if root then
    local entry = _state.cache[root]
    _state.cache[root] = {
      power = (entry and entry.power) or {},
      token = entry and entry.token or nil,
    }
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
M._module_power = module_power
M._decode_envelope = decode_envelope
M._publication_token = publication_token
M._state = _state

return M
