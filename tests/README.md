# Tests

The programs run unmodified against a mocked OpenComputers/AE2/GregTech world, so behavior can be
tested without Minecraft. Every behavior change should come with a test here.

```
lua5.3 tests/run.lua            # everything
lua5.3 tests/run.lua feeders    # files whose name contains "feeders"
lua5.3 tests/run.lua -v         # print every check
```

Each `test_*.lua` runs in its own interpreter; the runner exits non-zero on any failure.

## Files

| File | Covers |
|---|---|
| `test_router.lua` | Filter selection, stable slots, clearing, remote assign, status |
| `test_stockers.lua` | GT stocking input buses: top items incl. batch items, stable slots, auto-pull off, no database, unloaded bus, screen row |
| `test_interfaces.lua` | ME interfaces another network pulls from: top batch-1 items, clearing at start and exit, one rewrite per item running out, status, screen row, configuration errors |
| `test_feeders.lua` | Exact-batch feeding against a machine that only consumes full batches; catalog paging, forget |
| `test_monitor_rules.lua` | Machine states, stall/idle alerts, rule commands and preview |
| `test_control.lua` | Screen: routing an item, ITEMS paging, search, batch, forget, clear absent, overrides |
| `test_control_rules.lua` | Screen: machines, alerts, beep, rule editor, MAKE RULE, compact layout, version badge |
| `test_discover.lua` | prism-discover output |
| `test_setup.lua` | prism-setup for router and screen: rules, hardware, wireless, start on boot, re-runs, backups, cancelling; both programs running on its output |
| `test_update.lua` | prism-update install/update, keeping config, pointing to prism-setup, rejecting bad downloads, migrating old `router*.cfg` |
| `test_example_config.lua` | The shipped example config loads and routes with its default rules |
| `test_units.lua` | Pure modules on their own: `rules`, `router/planner`, `router/slots`, `protocol` |
| `test_modules.lua` | Packaging and contracts: `manifest.lua` lists every file, one version, docs list every setting and command, the program bootstrap |
| `helper.lua` | Shared setup (`H`) |
| `mocks/oc.lua` | The mock world (`M`) |

## Writing a test

```lua
-- test_example.lua: one line saying what this covers.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check

M.items = { { name = "gregtech:gt.metaitem.01", damage = 5001, label = "Crushed Copper Ore", size = 64 } }
local cfg = H.config("example", [[
return { modemPort = 4242, buses = { { address = "eb11", side = sides.north, process = "wash" } },
         rules = { { pattern = "^Crushed .+ Ore$", process = "wash" } } }
]])

M.onPull = function(n)                 -- called whenever the program waits for an event
  if n == 3 then return { "interrupted" } end   -- stop after a few cycles
end
H.run("prism.lua", cfg)

check(M.busHosts["eb111111-1111"][2][1].label == "Crushed Copper Ore", "copper goes to the washer bus")
H.done()
```

Pure modules can also be tested directly, without running a program: `require("prism.rules")` and so on
(the helper puts `lib/` on `package.path`). See `test_units.lua`.

Key ideas:

- **Time is simulated.** `computer.uptime()` only advances when a program waits with no event to deliver.
  Returning an event from `M.onPull` delivers it instantly.
- **Drive the program with events:** `modem_message` (commands), `touch` and `key_down` (screen), and
  `interrupted` to end the run.
- **Inspect state directly:** `M.busHosts`, `M.stocker(...).slots`, `M.iface(...).config`, `M.dbSlots`, `M.sent` (every wireless message), and files in `H.TMP`.
- **Screen tests:** `M.find(text, minY, minX)` locates text, so tap it with `{ "touch", "screen", x + 1, y }`.
  `M.row(y)`, `M.fgb` / `M.bgb` (colors), `M.oob` (draws off-screen) and `M.beeps` cover the rest.
- **Run the router first to get real messages** for screen tests, rather than hand-writing status tables.
- Add machines with `M.machine(addr, fields)`, and other components by putting a table in `M.proxies`.
  See `test_feeders.lua` for a simulated interface, transposer and machine.

## Mock fidelity

The mock is only as good as our knowledge of the real APIs. When something behaves differently in
game, first change the mock to match the game and add a test that fails, then fix the code. Record
what was verified in the table in [docs/architecture.md](../docs/architecture.md).

## Screenshots

Screen tests call `H.screen(name)`. With `SCREENS` set, they dump the screen there:

```
make screens     # SCREENS=build/screens lua5.3 tests/run.lua, then tools/render_screens.py
```

`tools/render_screens.py` (Python 3 + Pillow) turns the dumps into PNGs. The images in `docs/images/` come from here.
