-- Bridge to nvim's built-in LSP. Used for: (1) resolving the symbol
-- under the cursor before broadcasting source_focused, and (2) optional
-- hover augmentation when augment_lsp_hover is enabled.
local M = {}

-- True if any LSP client is attached to the buffer that owns the
-- current window. We probe `verilog`/`systemverilog` filetypes the
-- same way; the plugin does not care which LSP server is responding.
function M.has_lsp(bufnr)
  bufnr = bufnr or 0
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  return #clients > 0
end

-- Resolve the symbol at the cursor. With LSP attached we *could* ask
-- for the hover-targeted symbol, but for :RtlBuddyToWave the cword is
-- the right input to the hub's resolver and an LSP round-trip would
-- only slow it down. Declaration-site resolution lives in
-- `resolve_declaration` below, which is what :RtlBuddyShow uses.
function M.symbol_under_cursor(bufnr, _use_lsp)
  bufnr = bufnr or 0
  return vim.fn.expand("<cword>")
end

-- Best-effort LSP location extraction from a single result item, which
-- may be a Location, a LocationLink, or an array of those. Returns
-- {file,line,col} (1-based) or nil.
local function location_from(item)
  if type(item) ~= "table" then return nil end
  if #item > 0 then item = item[1] end
  local uri = item.uri or item.targetUri
  local range = item.targetSelectionRange or item.targetRange or item.range
  if not uri or not range then return nil end
  local file = vim.uri_to_fname(uri)
  if not file or file == "" then return nil end
  return {
    file = file,
    line = (range.start.line or 0) + 1,
    col = (range.start.character or 0) + 1,
  }
end

-- Resolve the declaration site of the symbol under the cursor via LSP.
-- Tries `textDocument/declaration` first, then `textDocument/definition`
-- (verible-verilog-ls implements the latter, not the former). Returns
-- {file,line,col} or nil. Synchronous with a short timeout so :RtlBuddyShow
-- doesn't block long enough to surprise the user if LSP is slow.
function M.resolve_declaration(bufnr, win, timeout_ms)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  win = win or vim.api.nvim_get_current_win()
  timeout_ms = timeout_ms or 500
  if not M.has_lsp(bufnr) then return nil end

  local ok_params, params = pcall(vim.lsp.util.make_position_params, win, "utf-8")
  if not ok_params then return nil end

  for _, method in ipairs({ "textDocument/declaration", "textDocument/definition" }) do
    local ok, results = pcall(vim.lsp.buf_request_sync, bufnr, method, params, timeout_ms)
    if ok and type(results) == "table" then
      for _, r in pairs(results) do
        if r and r.result then
          local loc = location_from(r.result)
          if loc then return loc end
        end
      end
    end
  end
  return nil
end

-- Wrap textDocument/hover so hub-supplied overlay info is appended
-- below verible's own hover output. Opt-in via setup({augment_lsp_hover = true}).
-- get_overlay(symbol, bufnr) -> string | nil (markdown lines).
function M.install_hover_augmentation(get_overlay)
  if M._hover_installed then return end
  M._hover_installed = true
  local original = vim.lsp.handlers["textDocument/hover"]
  vim.lsp.handlers["textDocument/hover"] = function(err, result, ctx, config)
    local bufnr = ctx and ctx.bufnr or 0
    local symbol = vim.fn.expand("<cword>")
    local extra
    local ok, value = pcall(get_overlay, symbol, bufnr)
    if ok then extra = value end

    if extra and extra ~= "" then
      if result and result.contents then
        local existing = result.contents
        if type(existing) == "string" then
          result.contents = existing .. "\n\n---\n\n" .. extra
        elseif type(existing) == "table" then
          if existing.kind == "markdown" or existing.kind == "plaintext" then
            result.contents.value = (existing.value or "") .. "\n\n---\n\n" .. extra
          else
            table.insert(existing, { kind = "markdown", value = "---\n" .. extra })
          end
        end
      else
        result = { contents = { kind = "markdown", value = extra } }
      end
    end

    if original then return original(err, result, ctx, config) end
    return vim.lsp.handlers.hover(err, result, ctx, config)
  end
end

return M
