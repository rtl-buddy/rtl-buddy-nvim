-- :checkhealth rtlbuddy — reports hub + LSP + neovim version.
local M = {}

function M.check()
  local health = vim.health or require("health")
  health.start("rtlbuddy.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("rtlbuddy.nvim requires Neovim 0.10+")
  end

  local rtl_ok, rtl = pcall(require, "rtlbuddy")
  if not rtl_ok then
    health.error("rtlbuddy not loaded: " .. tostring(rtl))
    return
  end

  local state = rtl.state()
  if not state.client then
    health.warn("setup() has not been called; hub is not initialised")
  else
    local s = require("rtlbuddy.hub").status(state.client)
    if s.state == "ready" then
      health.ok(
        string.format(
          "hub connected @ %s (server %s, peers: %s)",
          s.endpoint or "?",
          s.server_version or "?",
          table.concat(s.registered_clients or {}, ",")
        )
      )
    elseif s.state == "connecting" or s.state == "handshake" then
      health.warn("hub " .. s.state .. " @ " .. (s.endpoint or "?"))
    else
      health.error("hub disconnected: " .. (s.last_error or "no hub.json found"))
      health.info("Start the hub with `rb hub start` from your project root.")
    end
  end

  local clients = vim.lsp.get_clients()
  if #clients > 0 then
    local names = {}
    for _, c in ipairs(clients) do
      table.insert(names, c.name)
    end
    health.ok("LSP attached: " .. table.concat(names, ", "))
  else
    health.warn(
      "no LSP clients attached (verible-verilog-ls recommended; plugin falls back to <cword>)"
    )
  end

  -- Wave annotation (rb wave inline values + <leader>wa) — folded in #272.
  local wave = state.config and state.config.wave
  if not wave or wave.annotate ~= false then
    health.ok("wave annotation enabled (`rb wave` inline values; <leader>wa → Surfer)")
  else
    health.info("wave annotation disabled (set wave.annotate = true to enable)")
  end

  -- Phys annotation (module cells/area/power virtual text) — nvim#12. The
  -- numbers are read by an `rb` subprocess, so a missing `rb` is the one way
  -- an enabled annotation still shows nothing; say so here rather than in a
  -- notification nobody asked for.
  local phys = state.config and state.config.phys
  if not phys or phys.annotate ~= false then
    if vim.fn.executable("rb") == 1 then
      health.ok("phys annotation enabled (`rb phys` cells/area/power at module declarations)")
    else
      health.warn("phys annotation enabled but `rb` is not on PATH — no numbers will be read")
    end
  else
    health.info("phys annotation disabled (set phys.annotate = true to enable)")
  end
end

return M
