# Architecture

## Programs

| Program (`src/`) | Runs on | Role |
|---|---|---|
| `prism.lua` | router computer | Scans, decides, configures buses and feeders, monitors machines, serves the protocol |
| `prism-control.lua` | control computer | Touchscreen UI; holds no state the router doesn't have |
| `prism-setup.lua` | both | Guided setup: router or screen, writes `prism.cfg` or `prism-control.cfg` and `.shrc`; on a router that has `prism.cfg` and a tier 2+ screen, a full-screen hardware editor instead (`--text` for the questions) |
| `prism-discover.lua` | router computer | Lists components and prints config lines |
| `prism-update.lua` | both | Installs and updates from GitHub what [manifest.lua](../manifest.lua) lists: the latest release by default, or a branch/tag |

Programs are thin: they load modules from `lib/prism/` and wire them together. Installed, programs live in
`/home/bin` and modules in `/home/lib/prism`. Each program starts with the same three lines: add
`/home/lib/?.lua` to `package.path`, forget `prism.*` modules cached by an earlier run (OpenOS keeps
`package.loaded` until reboot, so a restart after an update would otherwise run old code), and stop with
"run prism-update" if the modules are missing. `prism-update.lua` is the exception: it's the bootstrap, so it
stays self-contained.

## Modules

Each module starts with a header comment that is its interface: what it exports, the shapes it takes and
returns. Read that rather than the code. Modules hold no state at load time; state lives in the objects they return.

| Module (`lib/prism/`) | Interface | Used by |
|---|---|---|
| `version` | the release string | all |
| `util` | `keyOf`, `sideName`, `fmtNum`/`fmtSecs`/`fmtTime`/`pct`, `count`, `copy`, `trim` (pure) | all |
| `log` | `log(fmt, ...)`: one timestamped line | router |
| `files` | read/write data tables and Lua configs, atomic writes, `.bak` backups | router, setup |
| `config` | the settings and defaults of both config files (`ROUTER_TUNING`, `CONTROL_TUNING`), `loadRouter`, `loadControl` | router, screen, setup |
| `protocol` | `encode` (trims to fit without changing the message), `decode`, `feederLevel`, page sizes | router, screen |
| `rules` | `classify` (screen override → cfg override → rules), `clean`, `fromMsg`, `usage`, `preview` (pure) | router |
| `probe` | finding and describing components: export buses, stockers, transposer sides, machines; `snapshot()` of all of them | setup, discover |
| `gui` | GPU primitives, colors, buttons and touch targets | screen, setup |
| `router/core` | the router object: `setup()`, `cycle()`, `run()`; owns the state below | `prism.lua` |
| `router/store` | the data files (`overrides`, `catalog`, `screenRules`, `alwaysShare`), `classify` against them, `limits` | core, commands, status |
| `router/planner` | `plan(items, classify)` → queues, backlog, unassigned; `spill` to fallbacks (pure) | core |
| `router/outputs` | the **output interface** and `open(cfg, env)`; see below | core |
| `router/exportbus`, `router/stocker`, `router/interface`, `router/feeder` | the output kinds | outputs |
| `router/slots` | `apply(slots, n, wanted, write)`: minimal-write slot keeping (pure) | exportbus, stocker, interface |
| `router/database` | staging items in a Database Upgrade: `stage(key, stack)` | exportbus, interface, feeder |
| `router/machines` | `open`, `poll`, `summary` for monitored GT machines | core, status |
| `router/health` | stall detection and alerts, with their state between scans | core |
| `router/status` | `build()` the `router-status` message | core |
| `router/commands` | the command table: `{ fields, run }` per wireless command | core |
| `router/telemetry` | reporting to [LENS](https://github.com/aharabedian/lens) on `lensPort`: describe at start, a snapshot after each scan, answering `hello`. Every call is protected, so a failure never stops routing | core |
| `lens/metrics`, `lens/codec` | **vendored** from LENS (`tools/sync-lens.sh`), byte for byte; don't edit here. `test_modules` compares them with a `../lens` checkout | telemetry |
| `control/ui` | the control screen's layout on top of `gui`, sparklines | screen views |
| `control/model` | screen state (`S`), actions, handling router messages; no drawing | screen |
| `control/status_view`, `list_view`, `panel_view` | header + left column; the tabbed list (one descriptor per tab); the panels and footer | screen |
| `setup/*` | `input` (prompts), `render` (config text), `processes`, `hardware`, `autostart`, `save`, `router`/`control` (the two roles), `paths`; the editor: `editor` (found vs configured hardware and the edits, pure) and `screen` (drawing, touch, keys) | `prism-setup.lua` |

Dependencies point one way: programs → role modules (`router/`, `control/`, `setup/`) → shared modules.
Shared modules never require role modules, and role modules never require each other's.

### Outputs

Everything that sends a process's items somewhere implements one interface (`lib/prism/router/outputs.lua`):
`kind`, `name`, `process`, `takesBatches`, `statusList`, `apply(queue)` after each scan, `step(queue)`
between scans (feeders), `status(labels)`, `alert()`, `close()`, `fed` for feeders, and `claims` (the ME
interface slots it configures; two outputs claiming one slot won't start). The scan, stall detection, status
and warnings only use this interface, so a new kind of output is one new module plus a line in `outputs.lua`.

| Kind | Config list | Takes | Needs a database |
|---|---|---|---|
| `bus` (export bus) | `buses` | top `slotsPerBus` batch-1 items | yes |
| `stocker` (GT Stocking Input Bus) | `stockers` | top 16 items, any batch | no |
| `interface` (ME interface another network pulls from) | `interfaces` | top 9 batch-1 items, a stack each | yes |
| `feeder` (interface + transposer + machine) | `feeders` | one item at a time, exact batches | yes |

## Router main loop

One loop, three timers, woken early by wireless commands:

| Timer | Default | Work |
|---|---|---|
| monitor | 2 s | Poll each `gt_machine`; broadcast `router-machines` between scans |
| scan | 5 s | The cycle below; broadcast `router-status` |
| feed | 1 s | One step per feeder |

A command that changes routing (assign, rule edit, reload...) triggers an immediate scan.

### Scan cycle

`Router:cycle()` in `router/core`:

1. `getItemsInNetwork()`, then `planner.plan`: merge stacks of the same `name:damage` (NBT variants),
   classify each item (screen override → cfg override → rules) into process, priority and batch, and
   rank each process's queue by priority, then quantity.
   Then `planner.spill` shares items with a `fallback` from a process past its `overflow` or set to always share:
   a copy joins the fallback's queue ([Fallbacks and overflow](configuration.md#fallbacks-and-overflow)).
   Which items are shared is kept until the next scan, for the hysteresis. Everything after this step
   sees the queues after sharing.
2. Add new items to the catalog (`prism-items.cfg`); log new problems once.
3. `output:apply(queue)` for every output (what each kind takes: [Outputs](#outputs)); feeders do nothing here.
4. `health`: detect stalls and build alerts.
5. `status.build`, then broadcast it.

### Export bus filters

`slots.apply` keeps every slot that already holds a wanted item, fills the remaining slots with the
missing ones in priority order, and clears slots holding items no longer wanted. An unchanged network
causes zero writes, and one item running out rewrites exactly one slot.

### Stocking input buses

A GT Stocking Input Bus (ME) shows the multiblock the network's stock of each configured item, and the
multiblock extracts exactly what a recipe needs when it starts. So there is no transfer rate to keep up
with, and batch sizes take care of themselves; items with less than one batch in stock aren't stocked,
since they can't run a recipe. The router configures one with
`setConfiguration(slot, { name, damage })` (no table clears the slot) and reads back slots with
`getConfiguration` at startup. No database is involved. It keeps slots stable the same way as export buses (`slots.apply`).
At startup, auto-pull is switched off on Advanced buses, because it would replace the router's choices.

### Database staging

Filters and interface configs can only be set from a Database Upgrade entry. To set one, the router
`store()`s the item from the network into a database slot and points the bus at that slot. The bus
keeps its own copy, so database slots are reused round-robin. The database never fills up, and any
tier works (a bigger one just means fewer `store()` calls). The last slot is kept empty and is used to clear configs.

### Feeders

Each step, per feeder:

1. Read the machine's inventory and the interface's stock through the transposer.
2. Pick the item already in the machine (to top it up), else the first queued item with at least one full batch available.
3. If the interface isn't stocking that item, reconfigure it and wait one step for stock.
4. Move `floor(min(stock, room) / batch) * batch` items.

If the machine already holds a non-multiple of the batch (a leftover from before), the feeder reports
`blocked` instead of adding to it. Remainders smaller than a batch stay in the network.

### Stall detection

A process is **stalled** when it has items ready (at least one batch of an item) and at least one bus, stocker
or feeder, but for `stallAfter` seconds none of these happened (likewise, a machine is only idle with work
waiting when its process has items ready):

- any of its items' quantity dropped, or an item left the network entirely
- a feeder for it moved items
- a monitored machine for it was `working`

Without monitored machines this relies on items leaving the network, so a process whose input arrives
exactly as fast as it's processed can be falsely flagged; monitoring its machines fixes that.

Alerts are rebuilt every scan, with stable ids (`stall:wash`, `machine:Washer 1`...). The router logs
each alert when it starts and when it resolves. The control screen beeps when a new id appears.

### Machine states

From the `gt_machine` component: `disabled` (work not allowed), `maintenance` (sensor info reports
`Problems: N` > 0), `working`, `no power` (idle with EU stored < 5%), `idle`, or `offline` when calls fail.

## Control screen

- Redraws fully on status, touch and key events; machine updates redraw only the machine rows.
- Item lists are fetched in pages, because wireless packets are limited to about 8 KB.
- All edits are commands to the router; the screen re-fetches after each `router-ack`.
- The left column switches to one row per bus and feeder when everything wouldn't otherwise fit.
- Stockers and interfaces are listed under BUSES as "N stocked"; export buses show "N filters".
- Tapping a process row opens its panel (overflow, what's shared, SHARE ON OVERFLOW / ALWAYS SHARE).

## Wireless protocol

See [protocol.md](protocol.md).

## In-game verification status

The test suite runs against [tests/mocks/oc.lua](../tests/mocks/oc.lua), which mirrors the
OpenComputers/AE2/GregTech APIs as we understand them. This table tracks which assumptions have been
confirmed in a real game. **Update it when you confirm or disprove something**, and fix the mock to
match the game first if they differ.

| API / behavior | Status |
|---|---|
| `me_controller.getItemsInNetwork`, `store`; Database Upgrade `get`/`clear` | Verified in-game (0.1) |
| `me_exportbus.get/setExportConfiguration` via adapter, clearing with an empty database slot | Verified in-game (0.1) |
| Wireless status/commands, control screen rendering and touch | Reported working (0.2) |
| `me_interface.setInterfaceConfiguration` (block), transposer reading interface stock and `transferItem` | Reported working (0.3) |
| `math.random(m, n)` doesn't return an integer (the mock returns floats); LENS boot ids use `codec.newBoot()` | Seen in-game (LENS reporting crashed on it) |
| `gt_machine` method names (`isMachineActive`, `getWorkProgress`, `getWorkMaxProgress`, `getEUStored`, `getEUMaxStored`, `isWorkAllowed`, `getSensorInformation`, `getCoordinates`) | **Unverified** |
| Multiblock `Problems:` line format in sensor info | **Unverified** |
| `internet.request` streaming, `/home/bin` on the OpenOS shell path | Reported working |
| `/home/lib/?.lua` appended to `package.path` finds `/home/lib/prism/*.lua`; clearing `package.loaded["prism.*"]` reloads modules on restart | Reported working (modules branch) |
| `filesystem.makeDirectory` creating `/home/lib/prism/router` (prism-update creates each level itself) | Reported working (modules branch) |
| `handle.response()` giving the HTTP status after a failed read (404 for a repo with no releases, a missing tag) | Reported working (0.5.0) |
| `internet.request(url, nil, headers)` to `api.github.com` returning the latest release's `tag_name` | Reported working (0.5.0) |
| GT Stocking Input Bus `me_inputbus`: `getSlotSize`, `get/setConfiguration` (`{name, damage}`, no table clears), `isAdvanced`, `get/setAutoPull` (from GTNewHorizons/OpenComputers #222, merged 2026-09-21) | Reported working (stocking-buses branch) |
| A multiblock with the same item in two stocking buses still runs | **Unverified**; docs say one stocker per multiblock |
| Two multiblocks whose stocking buses hold the same item both pull from its stock (sharing with a fallback) | Reported working (fallbacks branch) |
| ME interface block as an output: `setInterfaceConfiguration` on slots 2..9, the interface restocking as another network's import bus empties it, clearing a slot handing its stock back | Reported working (interfaces branch) |
| `me_interface.getInterfaceConfiguration(slot)` (only for the slot 1 marker in prism-setup/discover; missing = "(empty)") | **Unverified** |
| `io.read()` line input for `prism-setup` (returns `nil` on Ctrl+D) | **Unverified** |
| `/home/.shrc` run by the shell at boot (start on boot) | **Unverified** |
| prism-setup's editor: `touch` and `scroll` events from a tier 2 screen, `component.isAvailable("screen")`, `key_down` codes (Enter 28, Esc 1, Backspace 14, arrows 200/208/203/205) | Reported working (1.1.0) |
