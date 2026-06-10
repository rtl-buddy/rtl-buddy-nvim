-- rtlbuddy.nvim — Neovim adapter for rtl-buddy-hub.
-- Composes with verible-verilog-ls; never replaces or shadows LSP keymaps.
-- Issue: rtl-buddy/rtl_buddy#113 (Phase 10c).
local M = {}

local DEFAULT_CONFIG = {
  -- Plugin starts a hub client (TCP) and reads .rtl-buddy/hub.json from
  -- the project root upward. RTL_BUDDY_HUB env var overrides.
  hub_discovery = nil, -- accepted for forward compat; not used today
  use_lsp_for_symbol = true,
  augment_lsp_hover = false,
  diagnostics_namespace = "rtlbuddy",
  auto_connect = true,
  keymaps = {
    show = "<leader>rs",
    to_wave = "<leader>rw",
    domain = "<leader>rd",
  },
  -- `rb wave` inline annotation (WAVE_VALUE virtual text) + the <leader>wa
  -- Surfer add-variable keymap. Folded in from rtl_buddy#272.
  wave = {
    annotate = true,
    keymap = "<leader>wa",
  },
}

local _state = {
  config = nil,
  client = nil,
}

function M.state()
  return _state
end

local function merge(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table" then
      merge(dst[k], v)
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
  return dst
end

function M.setup(user_config)
  math.randomseed(os.time() + (vim.uv.hrtime() % 1e6))
  local config = vim.deepcopy(user_config or {})
  merge(config, DEFAULT_CONFIG)
  _state.config = config

  local diagnostics = require("rtlbuddy.diagnostics")
  diagnostics.ensure_namespace(config.diagnostics_namespace)
  diagnostics.install_autocmds()

  if config.augment_lsp_hover then
    require("rtlbuddy.lsp").install_hover_augmentation(function(_symbol, _bufnr)
      -- Overlay payload is not yet wired through the hub protocol; the
      -- hook is in place so the integration is a single function swap.
      return nil
    end)
  end

  local commands = require("rtlbuddy.commands")
  commands.register()
  require("rtlbuddy.keymaps").apply(config.keymaps)
  require("rtlbuddy.wave").setup(config.wave)

  local hub = require("rtlbuddy.hub")
  _state.client = hub.new({
    on_request = function(env)
      if env.type == "open_source" then
        return commands.handle_open_source_request(env)
      end
      return { ok = false, error = "unsupported request: " .. env.type }
    end,
    on_event = function(env)
      if env.type == "diagnostics_set" then
        local p = env.payload or {}
        diagnostics.apply(p.source, p.items or {})
      end
    end,
  })
  if config.auto_connect then
    hub.connect(_state.client)
  end

  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      if _state.client then
        pcall(require("rtlbuddy.hub").disconnect, _state.client)
      end
    end,
  })

  return _state
end

function M.connect()
  if not _state.client then
    return
  end
  _state.client.auto_reconnect = true
  require("rtlbuddy.hub").connect(_state.client)
end

function M.disconnect()
  if _state.client then
    require("rtlbuddy.hub").disconnect(_state.client)
  end
end

function M.health()
  require("rtlbuddy.health").check()
end

return M
