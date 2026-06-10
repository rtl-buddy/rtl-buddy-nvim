-- Tests for the wave annotation module (folded in from rtl_buddy#272).
-- Hermetic: no `rb wave` / Surfer / hub required. The launch-time env vars
-- (WAVE_VALUE / WAVE_CTRL_SOCK) are simulated with vim.fn.setenv.
local wave = require("rtlbuddy.wave")

local NS = vim.api.nvim_create_namespace("rtlbuddy_wave_value")

local function clear_annotations()
  vim.api.nvim_buf_clear_namespace(0, NS, 0, -1)
end

local function extmarks()
  return vim.api.nvim_buf_get_extmarks(0, NS, 0, -1, { details = true })
end

local function keymap_with_desc(mode, desc)
  for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
    if m.desc == desc then
      return m
    end
  end
  return nil
end

local WA_DESC = "rtl-buddy wave: add signal under cursor to Surfer"

describe("rtlbuddy.wave.setup", function()
  before_each(function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "logic clk;" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    clear_annotations()
  end)

  it("defines the WaveValue highlight group", function()
    wave.setup({})
    local hl = vim.api.nvim_get_hl(0, { name = "WaveValue" })
    assert.are.equal(0xfffacd, hl.bg)
    assert.is_true(hl.bold)
  end)

  it("maps the Surfer add-variable keymap by default", function()
    wave.setup({})
    assert.is_not_nil(keymap_with_desc("n", WA_DESC))
  end)

  it("omits the keymap when keymap = false", function()
    -- Clear any mapping a prior test set, then confirm setup respects false.
    local existing = keymap_with_desc("n", WA_DESC)
    if existing then
      vim.keymap.del("n", existing.lhs)
    end
    wave.setup({ keymap = false })
    assert.is_nil(keymap_with_desc("n", WA_DESC))
  end)

  it("is idempotent — calling setup twice does not stack ColorScheme autocmds", function()
    wave.setup({})
    wave.setup({})
    local autocmds = vim.api.nvim_get_autocmds({ group = "RtlBuddyWave", event = "ColorScheme" })
    assert.are.equal(1, #autocmds)
  end)
end)

describe("rtlbuddy.wave annotation", function()
  before_each(function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "logic clk;" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    clear_annotations()
  end)

  it("draws EOL virtual text with the signal value", function()
    wave._draw_annotation("8'h0a")
    local marks = extmarks()
    assert.are.equal(1, #marks)
    local details = marks[1][4]
    assert.are.equal("eol", details.virt_text_pos)
    assert.are.equal("▶ 8'h0a", details.virt_text[1][1])
    assert.are.equal("WaveValue", details.virt_text[1][2])
  end)

  it("annotates from WAVE_VALUE when set", function()
    vim.fn.setenv("WAVE_VALUE", "1'b1")
    wave._annotate_from_env()
    vim.wait(200, function()
      return #extmarks() > 0
    end)
    local marks = extmarks()
    assert.are.equal(1, #marks)
    assert.are.equal("▶ 1'b1", marks[1][4].virt_text[1][1])
  end)

  it("is a no-op when WAVE_VALUE is unset", function()
    vim.fn.setenv("WAVE_VALUE", vim.NIL)
    wave._annotate_from_env()
    vim.wait(50)
    assert.are.equal(0, #extmarks())
  end)
end)

describe("rtlbuddy.wave add_variable message", function()
  it("encodes a newline-terminated add_variable command", function()
    local msg = wave._build_add_variable_msg("rst")
    assert.are.equal("\n", msg:sub(-1))
    local decoded = vim.json.decode(msg)
    assert.are.equal("add_variable", decoded.cmd)
    assert.are.equal("rst", decoded.name)
  end)
end)
