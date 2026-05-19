-- Separate `vim.diagnostic` namespace so hub-published findings
-- (CDC/RDC warnings, etc.) do not collide with verible-LSP's own
-- diagnostics. Surfaces in `:Telescope diagnostics` under
-- `rtlbuddy` rather than `verible`.
local M = {}

function M.ensure_namespace(name)
  name = name or "rtlbuddy"
  if not M._ns then
    M._ns = vim.api.nvim_create_namespace(name)
  end
  return M._ns
end

function M.publish(bufnr, items)
  local ns = M.ensure_namespace()
  vim.diagnostic.set(ns, bufnr, items or {})
end

function M.clear(bufnr)
  local ns = M.ensure_namespace()
  vim.diagnostic.reset(ns, bufnr)
end

return M
