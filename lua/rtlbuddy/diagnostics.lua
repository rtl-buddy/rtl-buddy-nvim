-- Separate `vim.diagnostic` namespace so hub-published findings
-- (CDC/RDC warnings, etc.) do not collide with verible-LSP's own
-- diagnostics. Surfaces in `:Telescope diagnostics` under
-- `rtlbuddy` rather than `verible`.
--
-- The handler keeps a per-(source, file) table of items so:
--  - A `diagnostics_set` for source S replaces the previous set for S
--    on the affected files only, leaving other sources alone.
--  - Files not yet loaded into a buffer get their items remembered;
--    a BufReadPost / BufNewFile autocmd publishes them when the buffer
--    appears.
local M = {}

local SEVERITY_MAP = {
  error = vim.diagnostic.severity.ERROR,
  warning = vim.diagnostic.severity.WARN,
  info = vim.diagnostic.severity.INFO,
  hint = vim.diagnostic.severity.HINT,
}

local function ns()
  if not M._ns then
    M._ns = vim.api.nvim_create_namespace(M._ns_name or "rtlbuddy")
  end
  return M._ns
end

-- _by_source_file[source][canon_file] = list-of-items (1-based wire form)
M._by_source_file = M._by_source_file or {}

-- Canonicalise a path so cache keys match between "what the hub sent"
-- and "what nvim wrote into the buffer name". On macOS the divergence
-- is `/private/` vs no `/private/` (e.g. /tmp ↔ /private/tmp,
-- /var/folders/... ↔ /private/var/folders/...) which can survive even
-- a `:p` lookup. We prefer fs_realpath when the file exists, else fall
-- back to the as-given form; then strip a leading /private/ so the two
-- equivalent forms collapse to the same key for non-existent files
-- too.
local function canon(path)
  if not path or path == "" then
    return path
  end
  local real = vim.uv.fs_realpath(path)
  local p = (real and real ~= "") and real or path
  if p:sub(1, 9) == "/private/" then
    p = p:sub(9) -- "/private/var/..." → "/var/..." (note: leading slash preserved by sub(9))
  end
  return p
end

function M.ensure_namespace(name)
  M._ns_name = name or M._ns_name or "rtlbuddy"
  return ns()
end

-- Convert a wire item to nvim's vim.diagnostic shape.
local function to_diag(item)
  return {
    lnum = item.line - 1, -- 0-based
    col = (item.col or 1) - 1, -- 0-based
    end_lnum = (item.end_line or item.line) - 1,
    end_col = (item.end_col or item.col or 1) - 1,
    severity = SEVERITY_MAP[item.severity] or vim.diagnostic.severity.WARN,
    message = item.message,
    source = item.source_label, -- set by caller
    code = item.code,
  }
end

local function bufnr_for_file(file)
  if not file or file == "" then
    return nil
  end
  -- vim.fn.bufnr already resolves symlinks, so the canonical key
  -- matches even if the buffer was opened via the un-resolved path.
  local b = vim.fn.bufnr(file)
  if b == -1 then
    return nil
  end
  if not vim.api.nvim_buf_is_loaded(b) then
    return nil
  end
  return b
end

-- Re-publish the merged set for `file` across ALL sources to the
-- buffer (if loaded). Without merging, the last source written wins
-- and earlier sources' items disappear from the buffer.
local function republish_file(file)
  local bufnr = bufnr_for_file(file)
  if not bufnr then
    return
  end
  local merged = {}
  for source, by_file in pairs(M._by_source_file) do
    local items = by_file[file]
    if items then
      for _, item in ipairs(items) do
        local copy = vim.deepcopy(item)
        copy.source_label = source
        table.insert(merged, to_diag(copy))
      end
    end
  end
  vim.diagnostic.set(ns(), bufnr, merged)
end

-- Apply one `diagnostics_set` event payload. Replaces the cached
-- items for `source` and republishes the affected files.
function M.apply(source, items)
  if not source or source == "" then
    return
  end
  local previous = M._by_source_file[source] or {}
  local fresh = {}
  for _, item in ipairs(items or {}) do
    local f = canon(item.file)
    if f and f ~= "" then
      fresh[f] = fresh[f] or {}
      table.insert(fresh[f], item)
    end
  end
  M._by_source_file[source] = fresh

  -- Files that previously had items from this source but no longer
  -- do still need a republish so old entries disappear.
  local touched = {}
  for f in pairs(previous) do
    touched[f] = true
  end
  for f in pairs(fresh) do
    touched[f] = true
  end
  for f in pairs(touched) do
    republish_file(f)
  end
end

-- Republish whichever sources have items for the file that just
-- entered a buffer. Hooked up in install_autocmds().
function M.on_buf_loaded(bufnr)
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == "" then
    return
  end
  local key = canon(vim.fn.fnamemodify(file, ":p"))
  for _, by_file in pairs(M._by_source_file) do
    if by_file[key] then
      republish_file(key)
      return
    end
  end
end

function M.install_autocmds()
  if M._autocmds_installed then
    return
  end
  M._autocmds_installed = true
  local group = vim.api.nvim_create_augroup("rtlbuddy.diagnostics", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group,
    callback = function(args)
      M.on_buf_loaded(args.buf)
    end,
  })
end

-- Test helper: wipe all cached items + buffer diagnostics.
function M._reset()
  for source, by_file in pairs(M._by_source_file) do
    for file in pairs(by_file) do
      local b = bufnr_for_file(file)
      if b then
        vim.diagnostic.reset(ns(), b)
      end
    end
  end
  M._by_source_file = {}
end

-- Kept for callers that want to publish manually (LSP-style).
function M.publish(bufnr, items)
  vim.diagnostic.set(ns(), bufnr, items or {})
end

function M.clear(bufnr)
  vim.diagnostic.reset(ns(), bufnr)
end

return M
