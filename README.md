# rtlbuddy.nvim

Neovim adapter for [`rtl-buddy-hub`](https://github.com/rtl-buddy/rtl_buddy) — the daemon that
synchronises the rtl-buddy schematic viewer, surfer (waveform), and your editor.

This plugin is the **source-side** participant in the hub mesh. With it loaded:

- Clicking an instance in the schematic viewer (or `goto_declaration` from surfer/WCP) opens
  the relevant file in this Neovim instance at the right line.
- `:RtlBuddyShow` broadcasts the cursor's file/line/column to the hub; the viewer pans, surfer
  highlights the matching scope.
- `:RtlBuddyToWave` asks surfer (via the hub) to add the signal under the cursor to the wave.

The plugin **composes with** `verible-verilog-ls`. It never shadows `<C-]>`, never claims the
LSP diagnostics namespace, and never re-parses Verilog — it leans on Verible for symbol
information and view.json for design-level mapping.

## Install

### lazy.nvim

```lua
{
  "rtl-buddy/rtlbuddy.nvim",
  ft = { "verilog", "systemverilog" },
  opts = {},
}
```

### packer.nvim

```lua
use({ "rtl-buddy/rtlbuddy.nvim", config = function() require("rtlbuddy").setup({}) end })
```

## Requirements

- Neovim ≥ 0.10
- A running `rtl-buddy-hub` (`rb hub start` from a project that has a `view.json`).
- Optional: `verible-verilog-ls` attached to the buffer for symbol resolution and hover
  augmentation. The plugin degrades to `<cword>` if no LSP is attached.

## Configuration

```lua
require("rtlbuddy").setup({
  -- Hub discovery: by default the plugin walks up from CWD for
  -- .rtl-buddy/hub.json. Set $RTL_BUDDY_HUB=host:port to override.
  auto_connect = true,
  use_lsp_for_symbol = true,
  augment_lsp_hover = false,           -- opt-in: append overlay info under verible's hover
  diagnostics_namespace = "rtlbuddy",  -- kept distinct from verible's diagnostics
  keymaps = {
    show    = "<leader>rs",  -- :RtlBuddyShow
    to_wave = "<leader>rw",  -- :RtlBuddyToWave
    domain  = "<leader>rd",  -- :RtlBuddyDomain
    -- set any key to nil to disable that mapping
  },
})
```

## Commands

| Command | What it does |
|---|---|
| `:RtlBuddyShow` | Broadcast `source_focused {file,line,col}` to the hub. |
| `:RtlBuddyOpen <file> <line> [<col>]` | Open and jump. Usually invoked by the hub via RPC; useful for scripting. |
| `:RtlBuddyToWave` | Request `wave_add_variables` for the symbol under the cursor. |
| `:RtlBuddyDomain` | Show hub-resolved overlay info at the cursor in a floating window. |
| `:RtlBuddyStatus` | Print hub connection state and registered peers. |

## Composition with Verible-LSP

The plugin and the LSP own different layers:

| Concern | verible-verilog-ls | rtlbuddy.nvim |
|---|---|---|
| Symbol under cursor | `textDocument/hover`, `documentSymbol` | — |
| Go-to-definition (`<C-]>`) | yes — never touched by this plugin | — |
| Lint diagnostics | own namespace | separate `rtlbuddy` namespace |
| Hover popup | primary | optional secondary contributor (opt-in) |
| File parsing | yes | no — relies on hub + view.json |

If LSP is unattached the plugin falls back to `expand('<cword>')` for symbol resolution and
skips hover augmentation. It never errors out for missing LSP.

## Troubleshooting

Run `:checkhealth rtlbuddy` first — it reports Neovim version, hub state, and LSP attach
status with red/yellow/green indicators.

| Symptom | Likely cause |
|---|---|
| `hub disconnected: no .rtl-buddy/hub.json found` | `rb hub start` not run from this project. |
| `:RtlBuddyShow` does nothing | Buffer has no file name, or hub state ≠ `ready`. |
| Wrong file opened by viewer click | `view.json` source anchors out of date; re-run `rb hier`. |
| Verible hover shows but no overlay info | `augment_lsp_hover` is the off-by-default opt-in. |

## Protocol

The wire contract — line-delimited JSON envelopes over TCP — lives in
[`rtl_buddy/src/rtl_buddy/hub/schema/hub-protocol-v1.json`](https://github.com/rtl-buddy/rtl_buddy/blob/main/src/rtl_buddy/hub/schema/hub-protocol-v1.json).
The plugin registers as `origin: "src"`; the hub broadcasts to all other origins,
suppressing echo-back to `src`.

## Tests

```sh
nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
```

(plenary.nvim is the typical test harness; the assertions follow the busted DSL.)

## License

MIT — see `LICENSE`.
