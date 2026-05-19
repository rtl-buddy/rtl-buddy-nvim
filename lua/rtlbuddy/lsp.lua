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

-- Resolve the symbol at the cursor. With LSP attached we ask for the
-- hover-targeted symbol via document_symbol; without LSP we fall back
-- to <cword>. Returns a plain string.
function M.symbol_under_cursor(bufnr, use_lsp)
  bufnr = bufnr or 0
  local cword = vim.fn.expand("<cword>")
  if not use_lsp or not M.has_lsp(bufnr) then
    return cword
  end
  -- We don't synchronously round-trip to the LSP for every Show — the
  -- hub already de-dupes and falls back gracefully. cword is good
  -- enough for the broadcast; the hub's resolver turns it into an
  -- instance_path via view.json. Returning cword keeps :RtlBuddyShow
  -- non-blocking and avoids surprising the user with a hung command
  -- when verible-LSP is slow.
  return cword
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
