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
| `clock` | real time from a file's `lastModified` (OpenComputers has no wall clock), carried on with uptime | router |
| `util` | `keyOf`, `sideName`, `fmtNum`/`fmtSecs`/`fmtTime`/`pct`, `count`, `copy`, `trim` (pure) | all |
| `log` | `log(fmt, ...)`: one timestamped line | router |
| `files` | read/write data tables and Lua configs, atomic writes, `.bak` backups | router, setup |
| `config` | the settings and defaults of both config files (`ROUTER_TUNING`, `CONTROL_TUNING`), `loadRouter`, `loadControl` | router, screen, setup |
| `protocol` | `encode` (trims to fit without changing the message), `decode`, `feederLevel`, page sizes | router, screen |
| `rules` | `classify` (screen override → cfg override → rules), `clean`, `fromMsg`, `usage`, `preview`, `ideas` (rules that would catch names differing in one word) (pure) | router, screen |
| `probe` | finding and describing components: export buses, stockers, transposer sides, machines; `snapshot()` of all of them | setup, discover |
| `gui` | GPU primitives, colors (the SPECTRA logo's, PRISM orange as the accent), buttons and touch targets | screen, setup, splash |
| `splash` | `show(gpu, w, h, name, version, accent)`: the SPECTRA logo in pixel art while a program starts; `rows(scale)` (pure) | prism-control |
| `router/core` | the router object: `setup()`, `cycle()`, `run()`; owns the state below | `prism.lua` |
| `router/store` | the data files (`overrides`, `catalog`, `screenRules`, `alwaysShare`), `classify` against them, `limits` | core, commands, status |
| `router/planner` | `plan(items, classify)` → queues, backlog, unassigned; `spill` to fallbacks (pure) | core |
| `router/outputs` | the **output interface** and `open(cfg, env)`; see below | core |
| `router/exportbus`, `router/stocker`, `router/interface`, `router/feeder` | the output kinds | outputs |
| `router/slots` | `apply(slots, n, wanted, write)`: minimal-write slot keeping (pure) | exportbus, stocker, interface |
| `router/database` | staging items in a Database Upgrade: `stage(key, stack)` | exportbus, interface, feeder |
| `router/machines` | `open`, `poll`, `summary` for monitored GT machines | core, status |
| `router/health` | stall detection and alerts, with their state between scans | core |
| `router/events` | the event log in `prism-log.cfg`: add, page newest first (all, alerts, changes), save at most once a minute | core, commands |
| `router/flow` | items leaving and arriving per process (rates over 5 minutes), and its machines' busy share over the last hour | core, status, telemetry |
| `router/status` | `build()` the `router-status` message | core |
| `router/commands` | the command table: `{ fields, run }` per wireless command | core |
| `router/explain` | `item(r, key)`: one line on what an item is doing now (on which output, or why it waits); `queue(r, process, ...)`: a process's queue with a short line per item. Uses the output interface only | commands |
| `router/telemetry` | reporting to [LENS](https://github.com/aharabedian/lens) on `lensPort`: describe at start, a snapshot after each scan, answering `hello`. Every call is protected, so a failure never stops routing | core |
| `lens/metrics`, `lens/codec` | **vendored** from LENS (`tools/sync-lens.sh`), byte for byte; don't edit here. `test_modules` compares them with a `../lens` checkout | telemetry |
| `control/ui` | the control screen's layout on top of `gui`, sparklines | screen views |
| `control/model` | screen state (`S`), actions, handling router messages; no drawing | screen |
| `control/status_view`, `list_view`, `panel_view` | header + left column; the tabbed list (one descriptor per tab); the panels and footer | screen |
| `control/glance_view` | glance mode: the screen at a third of its resolution, a row per process | screen |
| `control/process_view` | the process page, which replaces the list and panel while a process is selected | screen |
| `setup/*` | `input` (prompts), `render` (config text), `processes`, `hardware`, `autostart`, `save`, `router`/`control` (the two roles), `paths`; the editor: `editor` (found vs configured hardware and the edits, pure) and `screen` (drawing, touch, keys) | `prism-setup.lua` |

Dependencies point one way: programs → role modules (`router/`, `control/`, `setup/`) → shared modules.
Shared modules never require role modules, and role modules never require each other's.

### Outputs

Everything that sends a process's items somewhere implements one interface (`lib/prism/router/outputs.lua`):
`kind`, `name`, `process`, `takesBatches`, `statusList`, `apply(queue)` after each scan, `step(queue)`
between scans (feeders), `status(labels)`, `alert()`, `holds(key)` (where it holds an item now, for the
screen's "Now:" line), `size` (items held at once), `close()`, `fed` for feeders, and `claims` (the ME
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
   rank each process's queue by priority, then quantity. An item set to RUN NEXT (`prism-next.cfg`) gets a
   priority above every other until it ends; ended ones are dropped and logged.
   Then `planner.spill` shares items with a `fallback` from a process past its `overflow` or set to always share:
   a copy joins the fallback's queue ([Fallbacks and overflow](configuration.md#fallbacks-and-overflow)).
   Which items are shared is kept until the next scan, for the hysteresis. Everything after this step
   sees the queues after sharing.
2. Add new items to the catalog (`prism-items.cfg`); log new problems once.
3. `output:apply(queue)` for every output (what each kind takes: [Outputs](#outputs)); feeders do nothing here.
4. `health`: detect stalls and build alerts; `flow`: count what left and arrived since the last scan.
5. Alerts that started or ended go to the event log, with how long they lasted.
6. `status.build`, then broadcast it.

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

A process on hold (HOLD on its page, kept in `prism-held.cfg`) gets an empty queue: every output of it clears
its slots and its feeders stop. It is never stalled, and its machines are never idle with work waiting.

Without monitored machines this relies on items leaving the network, so a process whose input arrives
exactly as fast as it's processed can be falsely flagged; monitoring its machines fixes that.

An item is **stuck** when it has at least one batch, sits on one of its process's outputs (`holds`), and hasn't
gone down for `stuckAfter` seconds while the process used other items. It raises a warn (`stuck:<key>`, at most
five). Items the outputs don't hold are waiting their turn, so they never count; neither do held or stalled
processes.

Alerts are rebuilt every scan, with stable ids (`stall:wash`, `machine:Washer 1`...). The router logs
each alert when it starts and when it resolves. The control screen beeps when a new id appears.

### Machine states

From the `gt_machine` component: `disabled` (work not allowed), `maintenance` (sensor info reports
`Problems: N` > 0), `working`, `no power` (idle with EU stored < 5%), `idle`, or `offline` when calls fail.

## Control screen

- Redraws fully on status, touch and key events; machine updates redraw only the machine cells and
  each card's "N/M working" (everything, if machines were added, removed or moved to another process).
- Item lists are fetched in pages, because wireless packets are limited to about 8 KB.
- All edits are commands to the router; the screen re-fetches after each `router-ack`. Every command carries
  the player who tapped; OVERRIDES shows who made each screen override and how long ago.
- With `glanceAfter` set, the screen switches to glance mode (a third of its resolution) after that many minutes
  without a touch; the next touch only switches back.
- ROUTE ITEM's "Now:" line is the router's `explain` for the selected item, asked again with every status.
- The left column is one card per process: header (backlog, history, machines working), its machines,
  and a line about its outputs (export buses "N filters", stockers/interfaces "N stocked", feeders, items
  below their batch, and anything wrong). Things without a process get a last "(no process)" card.
- A card's outputs line ends with the process's throughput (`212/min  ·  clears 42m`, or `growing 20/min`);
  its panel adds the rates and what its machines' busy share means.
- When the cards don't fit, the biggest first list fewer machines ("+N more"), then shrink to their
  header with machines as dots (the outputs line stays only if something's wrong).
- Tapping a card opens its page in place of the list and panel: what's waiting and its throughput, a
  backlog chart from the screen's own samples, each machine's last 2 hours as a band (the screen counts the
  machine states it receives in 160 s cells), the queue in rank order with what each item is doing
  (`queue`, asked again with every status), its outputs, sharing (the overflow mark is a field: tap, type,
  Enter), and HOLD / SHARE ON OVERFLOW / ALWAYS SHARE / CLOSE.
- UNASSIGNED shows when each item was first seen (`new 4m` for the last hour); an item that appears with no
  rule shows in the footer, with one beep.
- UNASSIGNED groups items whose names differ in one word under the rule that would catch them
  (`rules.ideas`), with MAKE RULE opening the rule editor with it.
- LOG lists the router's event log, fetched in pages when the tab opens and when `router-status`'s `events`
  count changes; times are clock times with `timezone` set, else how long ago.
- ITEMS is grouped by process (collapsible; searching opens every group), or sorted A-Z or by quantity.
  BELOW BATCH lists only items with less than one batch, with how many more each needs.

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
| Reporting to LENS (`lensPort`): describe and snapshots reach the hub; machine states from `isMachineActive` / `isWorkAllowed` show as running, idle and down; a machine switched off raises its alert | Reported working (1.2.0) |
| `math.random(m, n)` doesn't return an integer (the mock returns floats); LENS boot ids use `codec.newBoot()` | Seen in-game (LENS reporting crashed on it) |
| `gt_machine` method names (`isMachineActive`, `getWorkProgress`, `getWorkMaxProgress`, `getEUStored`, `getEUMaxStored`, `isWorkAllowed`, `getSensorInformation`, `getCoordinates`) | **Unverified** |
| Multiblock `Problems:` line format in sensor info | **Unverified** |
| `gpu.setResolution` at run time (glance mode switches between a third and the full resolution) | Seen in game in LUMEN (big mode); **unverified** in PRISM |
| `os.sleep` (OpenOS) waits while yielding; `gpu.set` draws `▀` with the foreground on top (the splash's half-block pixels) | **Unverified** |
| `internet.request` streaming, `/home/bin` on the OpenOS shell path | Reported working |
| `/home/lib/?.lua` appended to `package.path` finds `/home/lib/prism/*.lua`; clearing `package.loaded["prism.*"]` reloads modules on restart | Reported working (modules branch) |
| `filesystem.lastModified(path)` gives real-world milliseconds, so `prism.clock` can tell the time (the event log's times) | Seen in game in LUMEN; **unverified** in PRISM |
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
| The player's name in `touch` events (the screen sends it as `player`) | Seen in game in LUMEN and LENS; **unverified** in PRISM |
| prism-setup's editor: `touch` and `scroll` events from a tier 2 screen, `component.isAvailable("screen")`, `key_down` codes (Enter 28, Esc 1, Backspace 14, arrows 200/208/203/205) | Reported working (1.1.0) |
