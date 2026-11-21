# Wireless protocol

Every message is an OpenOS `serialization.serialize`d table, sent on `modemPort` (default 4242).
The router **broadcasts** `router-status` and `router-machines`; everything else is a reply sent
directly to whoever asked. The control screen sends commands to the router's address once it has heard
a status, and broadcasts before that.

If `token` is set in `prism.cfg`, every command must carry the same `token` field or it's ignored.
Every command from the control screen also carries `player`: who tapped (from the `touch` event). The router
writes it into the event log for changes, and keeps it with screen overrides.

Packets are limited to about 8 KB (`modem.maxPacketSize()`). The router trims `unassigned` / `list`
until a message fits and sets `truncated = true` when it had to, then drops `buses[].filters`. That's why
items and previews are paged. Encoding and decoding live in `lib/prism/protocol.lua`; the router's command
handlers are the table in `lib/prism/router/commands.lua` (a test checks it matches the table below).

## Commands (screen → router)

| `cmd` | Fields | Effect / reply |
|---|---|---|
| `status` | | `router-status` (latest) |
| `assign` | `key`, `process`, `priority?`, `batch?`, `fallback?`, `label?` | Save a screen override → `router-ack`, rescan |
| `unassign` | `key` | Remove a screen override → `router-ack`, rescan |
| `forget` | `key` | Drop from the catalog, plus its screen override → `router-ack` |
| `forgetAbsent` | | Drop every absent catalog item without an override → `router-ack` |
| `items` | `offset`, `req` | `router-items`: one page (≤ 40) of the catalog |
| `overrides` | | `router-overrides` |
| `rules` | | `router-rules` |
| `setRule` | `index?`, `pattern`, `process`, `priority?`, `batch?`, `fallback?` | Replace rule `index`, or insert a new rule at the top → `router-ack` |
| `deleteRule` | `index` | → `router-ack` |
| `moveRule` | `index`, `dir` (`-1` up, `1` down) | → `router-ack` |
| `resetRules` | | Delete `prism-rules.cfg`, back to `prism.cfg` rules → `router-ack` |
| `previewRule` | `pattern`, `index?`, `process?`, `req` | `router-log` | `req`, `offset`, `total`, `filter`, `now` (the router's time), `real` (whether `now` and `at` are real time), `list = { at, kind, text, level?, lasted?, player?, process? }[]`; `kind`: `alert`, `ended` (`lasted` seconds), `share`, `hold`, `edit`, `start`, `stop` |
| `router-queue` | `req`, `process`, `offset`, `total`, `list = { rank, key, label, size, batch, prio, now, level }[]` (`now`: a short line on what the item is doing, such as `on Washer bus (slot 3)`, `↷ shared with wash`, `below batch: 25 of 36`; `level` as in `router-explain`) |
| `router-explain` | `req`, `key`, `text` (one line: on which outputs, or why it waits), `level` (`ok` on an output, `warn` waiting for something to change, `dim`) |
| `router-preview` |
| `alwaysShare` | `process`, `on` (boolean) | Share every item of a process that has a fallback (`on`), or only on overflow; saved in `prism-always-share.cfg` → `router-ack`, rescan |
| `log` | `offset?`, `filter?` (`alerts` or `changes`), `req?` | `router-log`: one page (≤ 40) of the event log, newest first |
| `explain` | `key`, `req?` | `router-explain`: what the item is doing now |
| `queue` | `process`, `offset?`, `req?` | `router-queue`: one page (≤ 40) of the process's queue in rank order |
| `setOverflow` | `process`, `overflow?` (number), `player?` | The process's overflow mark, saved in `prism-processes.cfg` (it wins over `processes.<name>.overflow` in prism.cfg); no `overflow` goes back to prism.cfg's → `router-ack`, rescan |
| `hold` | `process`, `on` (boolean), `player?` | Put a process on hold (`on`): its outputs are cleared and its stall and idle alerts stop; or resume it. Saved in `prism-held.cfg` → `router-ack`, rescan |
| `reload` | | Re-read `prism.cfg` → `router-ack` |

## Messages (router → screen)

### `router-status` (broadcast every scan)

| Field | Type | Meaning |
|---|---|---|
| `version` | string | Router version |
| `uptime`, `interval`, `cycles`, `cycleMs`, `writes` | number | Housekeeping |
| `lastError` | string? | Problem during the last scan |
| `processes` | `{ [name] = { types, items, buses, stalled?, spilled?, overflow?, alwaysShare?, below?, outRate?, inRate?, busy? } }` | Backlog per process, after [spilling](configuration.md#fallbacks-and-overflow). `buses` counts outputs; `stalled` is seconds; `spilled` is items shared with fallbacks this scan; `overflow` and `alwaysShare` are its settings (`overflowFrom`: `screen` or `cfg`, where the mark comes from); `below` is items in stacks below their batch; `outRate` / `inRate` are items leaving / arriving per minute over the last 5 minutes (from the second scan on); `busy` is the share of scans its monitored machines were working over the last hour, 0..1; `held`, `heldBy` and `heldFor` (seconds) while it's on hold |
| `buses` | `{ name, process, filters = { label... }, kind? }[]` | Export buses, then stockers (`kind = "stocker"`), then interfaces (`kind = "interface"`); for those two `filters` are the stocked items. `filters` may be dropped to fit the packet |
| `feeders` | `{ name, process, state, level, label?, batch?, fed }[]` | `level`: `ok`, `idle`, `warn` or `bad` (since 0.6.0; for older routers the screen reads `state`) |
| `machines` | `{ name, process, state, progress?, eu?, idle? }[]` | `progress`/`eu` are 0..1; `idle` is seconds idle with work waiting |
| `unassigned` | `{ key, label, size }[]` | Top 25 by quantity |
| `unassignedCount`, `catalogCount` | number | |
| `knownProcesses` | string[] | Every process named by buses, stockers, feeders, machines, rules or overrides |
| `alerts` | `{ id, level = "bad"|"warn", text }[]` | |
| `events` | number | Events added to the log since the router started; the screen fetches LOG again when it changes |

### Replies

| `type` | Fields |
|---|---|
| `router-machines` | `machines` (as in status), broadcast between scans |
| `router-ack` | `ok`, `text` |
| `router-items` | `req`, `offset`, `total`, `list = { key, label, size, process?, priority?, batch?, fallback?, spilled, source? }[]` (`source` is `gui`, `cfg` or `rule`; `spilled`: shared with its fallback in the latest scan) |
| `router-overrides` | `now` (the router's time), `list = { key, label?, process, priority?, batch?, fallback?, source, by?, at? }[]` (`by`, `at`: who made a screen override and when) |
| `router-rules` | `source` (`config` or `screen`), `list = { index, pattern, process, priority?, batch?, fallback?, used }[]` (`used` = catalog items this rule currently decides) |
| `router-preview` | `req`, and either `error`, or `total`, `applies`, `list = { key, label, now?, effect }[]` (≤ 40; `effect` is `applies`, `override wins` or `rule #N wins`) |

## Changing the protocol

Add fields rather than renaming them, so a screen and router one version apart still work.
Update this file, the tests that cover the message, and the CHANGELOG in the same change.
