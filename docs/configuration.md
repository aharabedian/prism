# Configuration

The router reads `/home/prism.cfg` (or the path given as `prism <path>`); the control screen reads
`/home/prism-control.cfg` (or `prism-control <path>`). Both are Lua files that return a table.
`prism-setup` writes them (see [setup.md](setup.md#first-run)); you can also edit them by hand.
When `prism-setup` rewrites a file it keeps every value, including ones it doesn't ask about, and saves the
previous version as `<file>.bak`, but hand-written comments are lost.
[config/prism.example.cfg](../config/prism.example.cfg) is an annotated router config.

## Options

| Key | Default | Meaning |
|---|---|---|
| `interval` | `5` | Seconds between network scans |
| `feedInterval` | `1` | Seconds between feeder steps |
| `monitorInterval` | `2` | Seconds between GT machine polls |
| `stallAfter` | `60` | Seconds of no movement before a process is flagged stalled |
| `idleAlert` | `30` | Seconds a monitored machine may sit idle with work waiting before an alert |
| `slotsPerBus` | `9` | Filter slots per export bus: 1, 5 or 9 (0, 1 or 2 Capacity Cards) |
| `network` | first found | Address (or prefix) of the `me_controller` / `me_interface` to scan |
| `database` | first found | Address (or prefix) of the Database Upgrade. Only needed for `buses`, `interfaces` and `feeders` |
| `modemPort` | none | Wireless port for the control screen; `nil` or `false` disables networking |
| `token` | none | Shared secret; commands without it are ignored. Set the same `token` in `prism-control.cfg` |
| `verbose` | `false` | Log every filter and interface change |
| `defaultPriority` | `10` | Priority for rules/overrides that don't set one |
| `buses` | `{}` | Export buses, see below |
| `stockers` | `{}` | GT Stocking Input Buses, see below |
| `interfaces` | `{}` | ME interfaces another network pulls from, see below |
| `feeders` | `{}` | Batch feeders, see below |
| `machines` | `{}` | Monitored GT machines, see below |
| `processes` | `{}` | Per-process settings: `overflow`, see [Fallbacks and overflow](#fallbacks-and-overflow) |
| `rules` | `{}` | Pattern rules, see below |
| `overrides` | `{}` | Per-item overrides, see below |

### `buses`

```lua
{ address = "1a2b3c4d", side = sides.north, process = "wash", name = "Washer 1" },
```

`address` is the `me_exportbus` component (the adapter next to the cable block). `side` is which face
of that cable block the bus is on. Several buses with the same `process` each get the same top items.

### `stockers`

```lua
{ address = "7a8b9c0d", process = "ebf", name = "EBF 1" },
```

`address` is the `me_inputbus` component: a GT **Stocking Input Bus (ME)** (or Advanced) with an adapter
touching it. Each scan the router puts the top 16 items waiting for `process` in its slots. The multiblock
pulls straight from the network and takes exactly what each recipe needs, so stockers also take
[batch](#batch-sizes) items and aren't limited by bus or feeder speed. Auto-pull on an Advanced bus is
switched off at startup. Use one stocker per multiblock: several stockers with the same `process` each hold
the same top items, like export buses.

### `interfaces`

```lua
{ address = "2b3c4d5e", process = "export", name = "Main net" },
```

`address` is an ME Interface **block** on the subnet (the adapter touching it). Another network's import bus
faces it and takes what it stocks ([layout](setup.md#interfaces-another-network-pulls-the-items)). Each scan
the router configures its slots to stock a full stack of each of the top items waiting for `process`, batch-1
items only, as with export buses. Optional `slots` (1 to 9, default 9) limits how many slots it uses. Every slot is
cleared when the router starts and stops. An interface can't also be the `network` or a feeder's `interface`.

### `feeders`

```lua
{ interface = "9c8d7e6f", transposer = "1f2e3d4c", interfaceSide = sides.west,
  machineSide = sides.east, process = "centrifuge", name = "Centrifuge 2" },
```

Sides are relative to the **transposer**. Optional `slot` (default 1) picks the interface slot to use.

### `machines`

```lua
{ address = "3a4b5c6d", process = "wash", name = "Washer 1" },
```

`process` ties the machine to a process for stall and idle detection.

## How an item's process is decided

First match wins:

1. **Screen overrides** (made on the control screen; stored in `prism-overrides.cfg`)
2. **`overrides`** in `prism.cfg`
3. **Rules**, top to bottom. These come from `prism-rules.cfg` once you've edited rules on the screen,
   otherwise from `rules` in `prism.cfg`.
4. Nothing matched: the item is **unassigned** and stays in the network.

`process = "ignore"` means "leave it alone and don't report it as unassigned".

Within a process, items are ranked by **priority** (higher first), then by quantity waiting.

## Fallbacks and overflow

A rule or override may name a `fallback` process: where its items go when their own process has too much
waiting, or is diverted. Without a `fallback`, an item always waits for its own process.

```lua
processes = { chembath = { overflow = 2000 } },
rules = {
  { pattern = "^Crushed Platinum Ore$", process = "chembath" },                    -- always waits
  { pattern = "^Crushed .+ Ore$",       process = "chembath", fallback = "wash" },
},
```

| Trigger | Set by | Effect |
|---|---|---|
| `overflow = N` | `processes` in `prism.cfg` | While more than N items wait, items with a fallback go there, lowest-ranked (priority, then quantity) first, until N or fewer are left. A whole item moves, even the biggest stack if it's the only one with a fallback. It comes back once the process's items plus it fit under 3/4 of N, so items don't bounce between processes |
| Divert | Tap the process on the screen → DIVERT TO FALLBACKS (saved in `prism-diverts.cfg`) | Every item with a fallback goes there until STOP DIVERTING |

- Items without a fallback count toward `overflow` but never move.
- Spilled items keep their priority and batch, and don't spill again from the fallback (no chains).
- The router logs when a process starts and stops sending items to fallbacks. On the screen, the process is
  marked `↷`, and lists show `process›fallback`.
- A process whose machines have stopped still raises its stall alert for the items it keeps.

## Rules

`prism-setup` writes a starting set for the processes you pick:

| Rule | Goes to (first one you have) |
|---|---|
| `^Purified <gem> Ore$` (Diamond, Emerald, Ruby, Sapphire, Green Sapphire, Olivine, Topaz, Tanzanite, Amethyst, Opal) | `sift` |
| `^Crushed .+ Ore$` | `wash`, `thermal`, `crush` |
| `^Purified .+ Ore$` | `crush`, `thermal` |
| `^Centrifuged .+ Ore$` | `crush` |
| `^Impure Pile of .+ Dust$`, `^Purified Pile of .+ Dust$` | `centrifuge` |
| `Ore$` (priority 5, catches raw ores) | `crush` |

To write your own:

```lua
rules = {
  { pattern = "^Crushed .+ Ore$",         process = "wash",       priority = 10 },
  { pattern = "^Impure Pile of .+ Dust$", process = "centrifuge" },
  { pattern = "^Cinnabar Dust$",          process = "centrifuge", batch = 2 },
  { pattern = "^Crushed Nickel Ore$",      process = "chembath",   fallback = "wash" },
  { pattern = "Ore$",                     process = "crush",      priority = 5 },
},
```

Patterns are [Lua patterns](https://www.lua.org/manual/5.3/manual.html#6.4.1) matched against the
item's display name:

| Write | Matches |
|---|---|
| `^` / `$` | start / end of the name |
| `.+` | one or more of anything |
| `%.` `%-` `%(` | a literal `.` `-` `(` (escape these with `%`) |
| `[AB]` | `A` or `B` |
| `%d+` | digits |

Put specific rules above general ones. The control screen's rule editor shows exactly which items a
pattern catches, and whether an override or an earlier rule wins, before you save. Malformed patterns
are rejected (and skipped with a log line if they're in a file).

## Overrides

```lua
overrides = {
  ["gregtech:gt.metaitem.01:2826"] = { process = "centrifuge", priority = 30, batch = 2 },
  ["minecraft:cobblestone:0"]      = { process = "ignore" },
},
```

Keys are `itemname:damage`. The router logs the key of every unassigned item, and the control screen shows it.

## Batch sizes

`batch = N` (on a rule or override, or set on the screen) means "only ever send multiples of N".
**Feeders** send batch items in exact multiples, and **stockers** offer them to a multiblock, which only
takes whole recipes. Export buses skip them, and the router logs a warning if a process has batch items
but no feeder or stocker. A remainder smaller than N waits in the network until more arrives.

## Data files

Kept next to the config, never touched by `prism-update` or `prism-setup`:

| File | Contents |
|---|---|
| `prism-overrides.cfg` | Overrides made on the control screen |
| `prism-items.cfg` | The catalog of every item seen (key → name) |
| `prism-rules.cfg` | Rules edited on the screen; replaces `rules` in `prism.cfg`. **RESET** on the screen deletes it |
| `prism-diverts.cfg` | Processes diverted on the screen |

## Control screen settings

`/home/prism-control.cfg`; every key is optional.

| Key | Default | Meaning |
|---|---|---|
| `modemPort` | `4242` | Must match the router's `modemPort`; `false` turns wireless off |
| `token` | `nil` | Must match the router's `token` |
| `beep` | `true` | Beep when a new alert appears |
| `history` | `60` | Backlog samples kept for the sparklines |
| `staleAfter` | `3` | Missed router cycles before showing NO SIGNAL |
| `batches` | `{ 1, 2, 3, 4, 6, 8, 9, 16, 32, 36, 64 }` | Batch buttons offered on the screen |
