# rtlbuddy.nvim

Neovim adapter for [`rtl-buddy-hub`](https://github.com/rtl-buddy/rtl_buddy) — the daemon that
synchronises the rtl-buddy schematic viewer, surfer (waveform), and your editor.

This plugin is the **source-side** participant in the hub mesh. With it loaded:

- Clicking an instance in the schematic viewer (or `goto_declaration` from surfer/WCP) opens
  the relevant file in this Neovim instance at the right line.
- `:RtlBuddyShow` broadcasts the cursor's file/line/column to the hub; the viewer pans, surfer
  highlights the matching scope.
- `:RtlBuddyToWave` asks surfer (via the hub) to add the signal under the cursor to the wave.
- `rb wave` launches nvim with the selected signal's value rendered inline as virtual text at
  its declaration, and `<leader>wa` adds the signal under the cursor straight to the Surfer
  waveform (folded in from rtl_buddy's old standalone `rtl_buddy_wave.lua`).
- Each `module` declaration carries its physical numbers — cells, area and instance power —
  as virtual text, read from the artefacts `rb synth` / `rb power` left on disk.

The plugin **composes with** `verible-verilog-ls`. It never shadows `<C-]>`, never claims the
LSP diagnostics namespace, and never re-parses Verilog — it leans on Verible for symbol
information and view.json for design-level mapping.

## Install

### Recommended: `rb nvim-install` (managed by rtl_buddy)

If you use the `rtl_buddy` CLI, let it manage this plugin — one command, no plugin
manager and no hand-written `init.lua`:

```bash
rb nvim-install            # clone the pinned, hub-compatible revision and wire it up
rb nvim-install --update   # re-sync to the revision pinned by your installed rtl_buddy
rb nvim-install --force    # overwrite an existing install
```

It clones this repo (at a revision pinned to your rtl_buddy's hub protocol) into
`~/.local/share/nvim/site/pack/rtlbuddy/start/rtl-buddy-nvim` and drops a managed
`~/.local/share/nvim/site/plugin/rtl_buddy_setup.lua` that calls `setup()` with
`auto_connect = true` and starts `verible-verilog-ls` when it's on `PATH`. Restart nvim
and run `:checkhealth rtlbuddy` — hub + LSP should be green. (`rb wave-install-nvim` is a
back-compat alias for the same command.)

### Manual (plugin manager)

For a hand-managed setup, install with your plugin manager and call `setup()` yourself.

#### lazy.nvim

```lua
{
  "rtl-buddy/rtl-buddy-nvim",
  ft = { "verilog", "systemverilog" },
  opts = {},
}
```

#### packer.nvim

```lua
use({ "rtl-buddy/rtl-buddy-nvim", config = function() require("rtlbuddy").setup({}) end })
```

## Requirements

- Neovim ≥ 0.10
- A running `rtl-buddy-hub` (`rb hub start` from a project that has a `view.json`).
- Optional: `verible-verilog-ls` attached to the buffer for symbol resolution and hover
  augmentation. The plugin degrades to `<cword>` if no LSP is attached.

### Recommended: pin `verible-verilog-ls` to rtl-buddy-view's Verible release

`rtl-buddy-view` pins a specific Verible release for its CST extractor (currently
`v0.0-4053-g89d4d98a`; see `_verible_install.VERIBLE_PINNED_VERSION` in that repo).
If `verible-verilog-ls` is on a different version, `:RtlBuddyShow`'s symbol-declaration
resolution can disagree with the schematic's `view.json` source anchors — same file,
slightly different line/col — which shows up as the viewer panning to "almost the right
place" after a click. Pointing the LSP at the same binary that `rtl-buddy-view` uses
avoids that drift.

```lua
-- nvim-lspconfig
local rb_view_vendor = vim.fn.expand(
  "~/path/to/rtl-buddy-view/vendor/verible/v0.0-4053-g89d4d98a"
)
local platform = jit.os == "OSX" and "macos-arm64" or "linux-x86_64"
require("lspconfig").verible.setup({
  cmd = { rb_view_vendor .. "/" .. platform .. "/bin/verible-verilog-ls" },
})
```

Or just install Verible system-wide (e.g. `brew install verible`) and bump it in lockstep
when you rotate `rtl-buddy-view`'s pin.

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
  wave = {
    annotate = true,            -- `rb wave` inline signal-value virtual text
    keymap   = "<leader>wa",    -- add signal under cursor to Surfer (false to disable)
  },
  phys = {
    annotate = true,            -- cells/area/power virtual text at module declarations
    keymap   = "<leader>rp",    -- :RtlBuddyPhys toggle (false to disable)
  },
})
```

## Wave annotation (`rb wave`)

When you open a design via `rb wave` with `editor-sock` configured, rtl-buddy launches
this nvim with two env vars set, which the `wave` module consumes:

| Env var | Used for |
|---|---|
| `WAVE_VALUE` | the selected signal's value — rendered as `▶ <value>` end-of-line virtual text (the `WaveValue` highlight: black on lemon-chiffon) at the cursor line on launch. |
| `WAVE_CTRL_SOCK` | a unix socket back to Surfer — `<leader>wa` sends the word under the cursor as an `add_variable` command so it appears in the waveform. |

Both degrade gracefully: with no `WAVE_VALUE` there's no annotation, and `<leader>wa`
warns if the control socket isn't reachable (i.e. `rb wave` isn't running). See the
[rtl_buddy wave docs](https://rtl-buddy.github.io/rtl_buddy/concepts/wave/) for the
`cfg-surfer` `editor-sock` / `ctrl-sock` setup.

## Phys annotation (`rb phys`)

Every `module <name>` declaration in a verilog/systemverilog buffer gets its physical
numbers as end-of-line virtual text (the `RtlBuddyPhys` highlight):

```systemverilog
module alu (            ▸ 1 234 cells · 72.1 µm²
module DFF_X1 (         ▸ 15.2 µW
```

The numbers come from the artefacts `rb synth` and `rb power` already wrote (rtl_buddy
≥ 6.49.0), via **one** machine-mode read run in the buffer's project root:

```bash
rb --machine phys summary --limit 0
```

Its payload holds both halves of the physical model — every synthesis row
(`cell_count`, `area_um2`) and every instance row (path, cell, power) — so every
declaration's numbers come out of that one read. No hub connection is needed and nothing
crosses the hub wire: `rb phys` runs no tool, it reads JSON off disk. The read is async
(`vim.system`) and debounced, cached per project root for the session, and the marks
refresh on `BufEnter` / `BufWritePost`. `:RtlBuddyPhys` toggles them,
`:RtlBuddyPhysRefresh` re-reads the model after a `rb synth` / `rb power` run in another
terminal.

The two halves spell `module` in two different namespaces, and that decides which numbers
a declaration can carry:

| Declaration's name is | Shown |
|---|---|
| an RTL module (synthesis half) | cells and area — **no power**: no instance row carries an RTL module's name |
| a Liberty cell (instance half), e.g. `DFF_X1` | the sum of its instances' `total_uw` |
| in both halves | its own cells and area only — the power would be a different thing's |
| in neither | nothing: no mark at all |

Those are the same answers `rb phys module <name>` gives (its `instance_join` note is how
the verb says the rows it joined are not that module's power), which is why the roll-up is
summed from the one payload rather than fanned out into a subprocess per declared module.
Attributing power to an RTL module needs the instance hierarchy, which the schematic owns
([rtl-buddy-sch#22](https://github.com/rtl-buddy/rtl-buddy-sch/issues/22)).

With no `rb` on `PATH`, no physical model, or a refusal from the verb: no marks and one
`vim.notify` at DEBUG level. `:checkhealth rtlbuddy` carries the standing answer.

## Commands

| Command | What it does |
|---|---|
| `:RtlBuddyShow` | Broadcast `source_focused {file,line,col}` to the hub. With LSP attached, this is the symbol's **declaration** location (via `textDocument/declaration`, falling back to `textDocument/definition`); without LSP it's the raw cursor location. |
| `:RtlBuddyOpen <file> <line> [<col>]` | Open and jump. Usually invoked by the hub via RPC; useful for scripting. |
| `:RtlBuddyToWave` | Request `wave_add_variables` for the symbol under the cursor. |
| `:RtlBuddyDomain` | Show hub-resolved overlay info at the cursor in a floating window. |
| `:RtlBuddyStatus` | Print hub connection state and registered peers. |
| `:RtlBuddyPhys` | Toggle the phys annotation (cells / area / power at module declarations). |
| `:RtlBuddyPhysRefresh` | Re-read the physical model for this buffer's project and redraw. |

## Composition with Verible-LSP

The plugin and the LSP own different layers:

| Concern | verible-verilog-ls | rtlbuddy.nvim |
|---|---|---|
| Symbol under cursor | `textDocument/hover`, `documentSymbol` | — |
| Go-to-definition (`<C-]>`) | yes — never touched by this plugin | — |
| Lint diagnostics | own namespace | separate `rtlbuddy` namespace (populated by hub `diagnostics_set` events — CDC/RDC/lint findings appear in `:Telescope diagnostics`, `:lua vim.diagnostic.open_float()`, signcolumn) |
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

The wire contract — line-delimited JSON envelopes over TCP — is owned by
[`rtl-buddy-sch/schemas/hub-protocol-v1.json`](https://github.com/rtl-buddy/rtl-buddy-sch/blob/main/schemas/hub-protocol-v1.json);
rtl_buddy and this plugin both vendor it (`lua/rtlbuddy/schema/hub-protocol-v1.json`),
and CI's `schema-drift` job fails if our copy diverges from that `main`.
The plugin registers as `origin: "src"`; the hub broadcasts to all other origins,
suppressing echo-back to `src`.

Adding an origin to the vocabulary is a lockstep edit across all three repos, in a
fixed merge order (schema first — the drift job is red by construction until it lands).
The checklist, with the test that catches each missed copy, is
[`docs/hub-protocol.md` §13](https://github.com/rtl-buddy/rtl-buddy-sch/blob/main/docs/hub-protocol.md#13-adding-or-renaming-an-origin--lockstep-checklist)
in that repo; this plugin's share of it is `PEERS` in `lua/rtlbuddy/schema.lua` and
`VALID_ORIGIN` in `lua/rtlbuddy/protocol.lua`, both fenced by `tests/schema_spec.lua`.

## Tests

Hermetic unit + mock-hub tests (no `rb` required):

```sh
nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
```

Live integration against a real `rtl-buddy-hub` daemon — installs `rtl_buddy` into
a temp venv, starts `rb hub`, drives nvim, asserts the broadcast on the wire:

```sh
# from a PyPI rtl_buddy
RTLBUDDY_INTEGRATION=1 tests/integration/run_live_hub.sh

# or from a sibling checkout
RTLBUDDY_INTEGRATION=1 RTLBUDDY_RB_SRC=../rtl_buddy tests/integration/run_live_hub.sh
```

The integration script is a no-op without `RTLBUDDY_INTEGRATION=1` so the default
test surface stays hermetic.

## License

BSD 3-Clause — see `LICENSE`. Matches the rest of the rtl-buddy project.
