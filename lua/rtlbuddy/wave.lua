-- rtlbuddy.nvim — `rb wave` inline annotation + Surfer add-variable keymap.
--
-- Folded in from rtl_buddy's standalone `rtl_buddy_wave.lua` so the editor
-- integration is a single plugin covering both the hub and the waveform
-- annotation. See rtl-buddy/rtl_buddy#272.
--
-- Two features, both driven by env vars that `rb wave` sets on the nvim it
-- launches:
--   * WAVE_VALUE      — the selected signal's value; rendered as end-of-line
--                       virtual text at the cursor line on launch.
--   * WAVE_CTRL_SOCK  — a unix socket back to Surfer; <leader>wa sends the
--                       signal under the cursor to it as an add_variable cmd.
local M = {}

local NS_NAME = "rtlbuddy_wave_value"
local HL_GROUP = "WaveValue"
local AUGROUP = "RtlBuddyWave"

local function set_hl()
  vim.api.nvim_set_hl(0, HL_GROUP, { fg = "#000000", bg = "#fffacd", bold = true })
end

-- Render `value` as EOL virtual text at the current cursor line. Synchronous;
-- the env-reading wrapper schedules this so it runs after the UI is ready.
local function draw_annotation(value)
  local ns = vim.api.nvim_create_namespace(NS_NAME)
  local line = vim.fn.line(".") - 1
  vim.api.nvim_buf_set_extmark(0, ns, line, 0, {
    virt_text = { { "▶ " .. value, HL_GROUP } },
    virt_text_pos = "eol",
  })
end

-- Read WAVE_VALUE (set by `rb wave`) and annotate. No-op when unset/empty.
local function annotate_from_env()
  local value = vim.fn.getenv("WAVE_VALUE")
  if value == vim.NIL or value == "" then
    return
  end
  vim.schedule(function()
    draw_annotation(value)
  end)
end

local function build_add_variable_msg(name)
  return vim.json.encode({ cmd = "add_variable", name = name }) .. "\n"
end

-- <leader>wa — push the word under the cursor to Surfer over the wave control
-- socket. WAVE_CTRL_SOCK is read lazily (in the callback, not at setup time) so
-- a socket that only appears once `rb wave` is running is still picked up.
local function wave_add_variable()
  local name = vim.fn.expand("<cword>")
  if name == "" then
    return
  end
  local ctrl_sock = vim.fn.getenv("WAVE_CTRL_SOCK")
  if ctrl_sock == vim.NIL or ctrl_sock == "" then
    vim.notify(
      "rb wave: WAVE_CTRL_SOCK unset — launch this nvim from `rb wave` (ctrl-sock in cfg-surfer)",
      vim.log.levels.WARN
    )
    return
  end
  local pipe = vim.uv.new_pipe(false)
  pipe:connect(ctrl_sock, function(err)
    if err then
      vim.schedule(function()
        vim.notify(
          "rb wave: ctrl-sock unavailable — is `rb wave` running? (" .. err .. ")",
          vim.log.levels.WARN
        )
      end)
      return
    end
    pipe:write(build_add_variable_msg(name), function()
      pipe:close()
    end)
  end)
end

-- Idempotent. Installs the WaveValue highlight + launch-time annotation
-- autocmd and the <leader>wa Surfer keymap. Re-running clears the autocmd
-- group first, so calling setup() twice does not stack duplicate autocmds.
-- opts: { annotate = true, keymap = "<leader>wa" }; set annotate=false or
-- keymap=false to disable either half.
function M.setup(opts)
  opts = opts or {}
  local annotate = opts.annotate
  if annotate == nil then
    annotate = true
  end
  local key = opts.keymap
  if key == nil then
    key = "<leader>wa"
  end

  if annotate then
    set_hl()
    -- :colorscheme wipes custom highlight groups; reapply on change.
    local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
    vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_hl })
    -- Normal launch: VimEnter fires after startup, before the first prompt.
    -- Lazy-load path (ft-triggered setup() after startup): vim_did_enter is
    -- already 1, so VimEnter will never fire again — annotate immediately.
    if vim.v.vim_did_enter == 1 then
      annotate_from_env()
    else
      vim.api.nvim_create_autocmd("VimEnter", { group = group, callback = annotate_from_env })
    end
  end

  if key then
    vim.keymap.set("n", key, wave_add_variable, {
      desc = "rtl-buddy wave: add signal under cursor to Surfer",
    })
  end
end

-- Exposed for tests (hermetic, no `rb wave` running).
M._draw_annotation = draw_annotation
M._annotate_from_env = annotate_from_env
M._build_add_variable_msg = build_add_variable_msg

return M
