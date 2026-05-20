-- User-facing :RtlBuddy* commands. Each one is thin: it gathers cursor
-- state, talks to the hub, and reports back via vim.notify. The hub
-- does the heavy lifting (view.json resolution, surfer signaling).
local proto = require("rtlbuddy.protocol")
local M = {}

local function rtl()
  return require("rtlbuddy").state()
end

local function cursor_position()
  local file = vim.api.nvim_buf_get_name(0)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  return file, row, col + 1 -- col returned 0-based; protocol wants 1-based
end

local function require_hub_ready(client)
  if not client or client.state ~= "ready" then
    vim.notify("rtlbuddy: hub not connected (run `rb hub start`)", vim.log.levels.WARN)
    return false
  end
  return true
end

-- :RtlBuddyShow — broadcast source_focused. With LSP attached we
-- broadcast the symbol's *declaration* location (the hub then matches
-- that against view.json source anchors); without LSP we fall back
-- to the raw cursor file/line/col.
function M.show()
  local r = rtl()
  if not require_hub_ready(r.client) then
    return
  end

  local file, line, col
  if r.config.use_lsp_for_symbol then
    local decl = require("rtlbuddy.lsp").resolve_declaration()
    if decl then
      file, line, col = decl.file, decl.line, decl.col
    end
  end
  if not file then
    file, line, col = cursor_position()
  end

  if file == "" then
    vim.notify("rtlbuddy: current buffer has no file", vim.log.levels.WARN)
    return
  end
  require("rtlbuddy.hub").send(r.client, proto.source_focused(file, line, col))
end

-- :RtlBuddyOpen <file> <line> [<col>] — used by the hub via the
-- open_source request handler; also exposed as a manual command for
-- scripting. Loads the file (if not loaded) and jumps to line/col.
function M.open(file, line, col)
  if not file or file == "" then
    vim.notify("rtlbuddy: :RtlBuddyOpen requires a file", vim.log.levels.ERROR)
    return false
  end
  line = tonumber(line) or 1
  col = tonumber(col) or 1
  local target_bufnr = vim.fn.bufnr(file)
  if target_bufnr == -1 then
    vim.cmd.edit(vim.fn.fnameescape(file))
  else
    local winid = vim.fn.bufwinid(target_bufnr)
    if winid ~= -1 then
      vim.api.nvim_set_current_win(winid)
    else
      vim.api.nvim_set_current_buf(target_bufnr)
    end
  end
  pcall(vim.api.nvim_win_set_cursor, 0, { line, math.max(col - 1, 0) })
  return true
end

-- :RtlBuddyToWave — request the hub to add the symbol under the
-- cursor to the waveform viewer. The hub resolves cword → wave_scope
-- via view.json and forwards to surfer.
function M.to_wave()
  local r = rtl()
  if not require_hub_ready(r.client) then
    return
  end
  local symbol = require("rtlbuddy.lsp").symbol_under_cursor(0, r.config.use_lsp_for_symbol)
  if symbol == "" then
    vim.notify("rtlbuddy: no symbol under cursor", vim.log.levels.WARN)
    return
  end
  require("rtlbuddy.hub").request(r.client, proto.wave_add_variables({ symbol }), function(env, err)
    if err then
      vim.notify("rtlbuddy: wave_add_variables failed: " .. err, vim.log.levels.ERROR)
      return
    end
    if env.kind == proto.KIND.ERROR then
      vim.notify(
        "rtlbuddy: hub error: " .. (env.payload and env.payload.message or "?"),
        vim.log.levels.ERROR
      )
    end
  end, 5000)
end

-- :RtlBuddyDomain — query the hub for overlay info at the cursor and
-- show it in a floating window. The hub does not yet implement a
-- single overlay-fetch RPC; this command surfaces what we have today
-- (selection / scope / cursor time) so the UX hooks exist.
function M.domain()
  local r = rtl()
  if not require_hub_ready(r.client) then
    return
  end
  local symbol = require("rtlbuddy.lsp").symbol_under_cursor(0, r.config.use_lsp_for_symbol)
  local lines = {
    "rtlbuddy — overlay info",
    "",
    "symbol: " .. symbol,
    "hub:    " .. (r.client.last_endpoint or "?"),
    "state:  " .. r.client.state,
  }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = 60,
    height = #lines,
    style = "minimal",
    border = "rounded",
  })
end

-- :RtlBuddyStatus — print hub connection state and registered peers.
function M.status()
  local r = rtl()
  local s = require("rtlbuddy.hub").status(r.client)
  local lines = {
    "rtlbuddy.nvim status",
    "  state:           " .. s.state,
    "  endpoint:        " .. (s.endpoint or "(none)"),
    "  server_version:  " .. (s.server_version or "(none)"),
    "  registered:      " .. table.concat(s.registered_clients or {}, ", "),
    "  last_error:      " .. (s.last_error or "(none)"),
  }
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

-- Handler for hub→plugin `open_source` requests. Returns the response
-- payload the hub expects.
function M.handle_open_source_request(env)
  local p = env.payload or {}
  local ok = M.open(p.file, p.line, p.col)
  return { ok = ok }
end

function M.register()
  vim.api.nvim_create_user_command(
    "RtlBuddyShow",
    M.show,
    { desc = "Broadcast cursor location to rtl-buddy-hub" }
  )
  vim.api.nvim_create_user_command("RtlBuddyOpen", function(opts)
    local args = opts.fargs
    M.open(args[1], args[2], args[3])
  end, { nargs = "+", desc = "Open <file> <line> [<col>]" })
  vim.api.nvim_create_user_command(
    "RtlBuddyToWave",
    M.to_wave,
    { desc = "Add cword to waveform via hub" }
  )
  vim.api.nvim_create_user_command(
    "RtlBuddyDomain",
    M.domain,
    { desc = "Show overlay info at cursor" }
  )
  vim.api.nvim_create_user_command(
    "RtlBuddyStatus",
    M.status,
    { desc = "Show hub connection status" }
  )
end

return M
