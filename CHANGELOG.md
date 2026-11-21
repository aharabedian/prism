# Changelog

All notable changes to this project. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **Why it waits**: ROUTE ITEM has a **Now:** line saying what the item is doing: on which bus, stocker,
  interface or feeder (and the slot), or why it waits (below its batch and how many more it needs, ranked below
  what its outputs hold, a batch item with no feeder or stocker, nothing serving its process). Protocol: the
  `explain` command and `router-explain` reply.
- **Below a full batch**: each process card says how many items wait below their batch ("56 below batch"), and
  ITEMS has a BELOW BATCH button that lists only those items, with how many more each needs. `router-status`
  processes carry `below`.
- **Throughput and time to clear**: the router counts items leaving and arriving per process. Each card ends
  with `212/min  ·  clears 42m` (or `growing 20/min` in yellow), and the process panel shows out and in per
  minute and how busy its machines were in the last hour, with what that means (`they are the limit`,
  `items reach them more slowly than they run`, `they wait for items`). `router-status` processes carry
  `outRate`, `inRate` and `busy`; LENS gets `prism_items_out_total{process}`.
- **Process page**: tapping a process card turns the right side into its page. It shows what's waiting and its
  throughput, a backlog chart, each machine's last 2 hours as a band with its busy share, the queue in rank
  order with what each item is doing (`on Washer bus (slot 1)`, `↷ shared with wash`, `below batch: 25 of 36`,
  `rank 12; outputs hold 9`), its outputs, sharing, and SHARE ON OVERFLOW / ALWAYS SHARE / CLOSE. It replaces
  the process panel. Protocol: the `queue` command and `router-queue` reply.
- **Hold a process**: HOLD on a process's page clears its export buses, stockers and interfaces and stops its
  feeders, so its items stay in the network (to rebuild a machine, say). It raises no stall or idle alerts
  while held; the card shows `‖` and `HELD by Aaron 12m`. RESUME sets the outputs again. Kept in
  `prism-held.cfg`, so it survives a restart. Protocol: the `hold` command; `held`, `heldBy`, `heldFor` on
  `router-status` processes.
- **Overflow mark on the screen**: the process page's **Share past** field sets how many items may wait before
  items with a fallback are shared. Tap it, type, Enter. It's saved in `prism-processes.cfg` and wins over
  `processes.<name>.overflow` in prism.cfg; an empty field goes back to prism.cfg's. Protocol: the `setOverflow`
  command; `overflowFrom` on `router-status` processes.
- **Stuck items**: an item on one of its process's buses or stockers that hasn't gone down for `stuckAfter`
  seconds (default 1200) while the process used other items raises a warn: `Purified Tin Ore stuck for 20m
  (thermal)`. Items still waiting for a slot don't count, nor do held or stalled processes. `stuckAfter = false`
  turns it off; `prism-setup` writes it.
- **Event log**: the router keeps its last 300 events in `prism-log.cfg`: alerts starting and ending (with how
  long they lasted), sharing on and off, holds, edits made on a screen, its own starts and stops. A **LOG** tab
  lists them newest first, with ALL / ALERTS / CHANGES. Times are clock times (`19:40`, `Thu 23:10`) with the new
  `timezone` setting in prism-control.cfg, else how long ago. The router reads the real time from a file's
  modification time (`.prism-clock`). Protocol: the `log` command and `router-log` reply; `events` on
  `router-status`.
- **Who changed it**: the control screen sends the name of the player who tapped with every command. The event
  log names them for each change, and OVERRIDES shows who made each screen override and how long ago
  (`Aaron · 2h`; `cfg` for prism.cfg's). Protocol: `player` on commands; `by`, `at` and `now` on
  `router-overrides`.
- **Rule ideas**: UNASSIGNED groups items whose names differ in one word under the rule that would catch them
  all (`^Purified Pile of .+ Dust$`, "catches 3 here"), with a MAKE RULE button that opens the rule editor with
  it; the preview shows what it catches before SAVE. Items with no common pattern go under "no rule idea for
  these".
- **New items**: the catalog keeps when each item was first seen. UNASSIGNED has a **seen** column (`new 4m` in
  orange for the last hour), and an item that appears with no rule for it shows in the footer with one beep. The
  new `unassignedAlert` setting (seconds, off by default) warns when items stay unassigned that long. Protocol:
  `seen` on `router-status` unassigned rows; `now` and `clockReal` on `router-status`.
- **Run next**: RUN NEXT in ROUTE ITEM puts an item first in its process for 30 minutes (every output takes it
  before anything else), then it goes back to its priority; STOP NEXT ends it early. The Now: line says how long
  is left, ITEMS marks it `▲`, OVERRIDES shows `next`, and the log has it starting and ending. Kept in
  `prism-next.cfg` across a restart. Protocol: the `runNext` command; `next` on items and overrides rows.
- **Glance mode**: with the new `glanceAfter` setting in prism-control.cfg (minutes, off by default), the screen
  switches to a third of its resolution after that long without a touch (53 × 16 on 160 × 50), so the text reads
  from across the room: each process's backlog, trend, a dot per machine and held / stalled / time to clear, and
  the two newest alerts. Any touch goes back to the full screen.

## [1.4.0] - 2026-11-18

### Added
- **`prism_backlog_ready_items`** for LENS: items waiting per process that can go out now, leaving out
  items still below their batch size.

### Changed
- **Process cards** on the control screen: the left column is one card per process with its backlog, its
  machines side by side (sorted by name, so all your washers are together) and a line about its buses,
  stockers and feeders that calls out anything wrong. Tap a card to see each output in the panel.
  When there are too many machines, the biggest cards list fewer ("+N more") or show them as dots.
- **ITEMS grouped by process**, under headers you can tap to collapse, with A-Z and BY QTY sorting too.
- **Batch is a field** on the control screen instead of a row of buttons: tap it and type any batch size
  (Enter or a tap elsewhere finishes). The `batches` setting in `prism-control.cfg` is gone.

## [1.3.0] - 2026-11-13

### Added
- **The SPECTRA logo** in pixel art for a moment while `prism-control` starts, with PRISM's name and version.

### Changed
- **Colors** follow the SPECTRA logo: PRISM orange (`#FF9F43`) as the accent, and the logo's ink, background
  and green, yellow and blue for status.

## [1.2.0] - 2026-11-12

### Added
- **Reporting to LENS**, the base-wide monitoring hub: with `lensPort` set, the router broadcasts its
  backlog, machine states (running / idle / down) and alerts after every scan, on its own port and secret
  (`lensNode`, `lensToken`). Off by default; `prism-setup` asks for them. See "Reporting to LENS" in
  docs/configuration.md.

## [1.1.0] - 2026-11-11

### Added
- **Setup editor**: on a router that already has `prism.cfg` and a tier 2 screen or better, `prism-setup`
  opens a full-screen editor. Tabs list every export bus, stocking bus, interface, transposer and GT machine
  found, plus configured ones that weren't; tap one to set its process or name, drop it, or change a feeder's
  interface and sides. GENERAL covers the network, database, Capacity Cards, wireless and start on boot.
  SAVE lists the changes and warnings before writing (keeping `prism.cfg.bak`). `prism-setup --text` (or TEXT
  SETUP) runs the guided questions as before.

## [1.0.0] - 2026-11-11

### Added
- **Fallbacks and overflow**: a rule or override can name a `fallback` process. When more than
  `processes.<name>.overflow` items wait for its process, items with a fallback are shared with it (both
  processes' outputs offer them), lowest-ranked first, until no more than that are left unshared (with
  hysteresis, so they don't flip back and forth). Items without a fallback always wait. Set the fallback
  with the new Fallback row when routing an item or editing a rule.
- **Always share** from the control screen: tap a process in PROCESSES, then ALWAYS SHARE. Every item with
  a fallback is shared until SHARE ON OVERFLOW. Saved in `prism-always-share.cfg`, so it survives a restart.
- Protocol: `alwaysShare` command; `fallback` on `assign`, `setRule` and the item, override and rule lists;
  `spilled`, `overflow` and `alwaysShare` on `router-status` processes. `prism-setup` writes `processes`.

### Fixed
- Less than one batch of an item (e.g. 25 dust in batches of 36) no longer flags its process as stalled or its
  machines as idle, and stockers no longer stock it, since it can't run a recipe. It still shows in the backlog.

## [0.6.0] - 2026-11-11

### Added
- **ME interfaces as outputs** (`interfaces` in `prism.cfg`): an ME Interface block on the subnet stocks a
  stack of each of a process's top 9 items, and another network's Import Bus (with Acceleration Cards) pulls
  them in. Use it instead of an export bus to send finished items to your main net. Set up by `prism-setup`,
  listed by `prism-discover`, shown under BUSES as "N stocked".
- The router refuses to start when two outputs configure the same ME interface slot, or when an output
  interface is the network it scans.

### Changed
- The programs are split into modules, installed into `/home/lib/prism/` next to the programs in `/home/bin`.
  `prism-update` installs whatever the release's `manifest.lua` lists. **Upgrading from 0.5.0: run
  `prism-update` twice** (the 0.5.0 updater doesn't know about modules; the new one it installs does).
  A program started without its modules says to run `prism-update`.
- Restarting a program after an update always loads the new modules (no reboot needed).
- `router-status` feeders carry a `level` (`ok`, `idle`, `warn`, `bad`); the screen colors feeders by it.
- A status message trimmed to fit a packet no longer loses those rows for later `status` replies.

## [0.5.0] - 2026-11-11

### Added
- **GT Stocking Input Bus (ME)** support (`stockers` in `prism.cfg`). The router fills each stocking bus's
  16 slots with the top items for its process, so the multiblock pulls straight from the subnet: no export
  bus or feeder speed limit, and batch items work. Auto-pull is switched off on Advanced buses. Shown under
  BUSES on the control screen; listed by `prism-discover` and set up by `prism-setup`. Needs a GTNH build
  whose OpenComputers has the stocking bus driver.
- The Database Upgrade is only required when export buses or feeders are configured.
- `prism-setup`: a guided setup wizard for either computer. It asks whether this is the router or the
  control screen.
  - Router: pick the processes you run from a list (crush, wash, thermal, centrifuge, sift, or your own) and
    get a matching set of starting rules; then the ME network, database, Capacity Cards, export buses (showing
    marker items), feeders (transposer sides found automatically), GT machines (processes chosen by number),
    wireless port and secret. Warns about processes with no bus/feeder or no rule. Writes `/home/prism.cfg`,
    keeping settings it doesn't ask about and the previous file as `prism.cfg.bak`.
  - Control screen: wireless port and secret, beep. Writes `/home/prism-control.cfg`.
  - Both: optionally start the program on boot via `/home/.shrc`.
  Run it again to change anything; current settings are the defaults.
- `prism-control` reads its settings from `/home/prism-control.cfg` (`modemPort`, `token`, `beep`, `history`,
  `staleAfter`, `batches`) instead of constants at the top of the program.

### Changed
- `prism-update` installs the **latest release** of `aharabedian/prism` by default, so computers get stable
  versions instead of whatever is on `main`. `prism-update main` follows the main branch, `prism-update v0.5.0`
  pins a release, `prism-update latest` goes back to releases, and `prism-update OWNER/REPO [REF]` uses a fork
  (its latest release, or `main` until it has one). The first install no longer needs the repo name.
  Computers that were following `main` switch to releases. Errors show the HTTP status.
- `prism-update` no longer creates `prism.cfg` from the example; it points to `prism-setup`.
- `prism` without a config says to run `prism-setup`.
- `prism-update` installs `prism-setup`.

## [0.4.0] - 2026-11-11

### Changed
- Named **PRISM**. Commands are `prism`, `prism-control`, `prism-discover` and `prism-update`;
  the config is `/home/prism.cfg`. `prism-update` moves an existing `router.cfg` and `router-*.cfg` over.

### Added
- GT machine monitoring: working/idle/disabled/maintenance/no power/offline, progress and EU, live on the screen.
- Stall detection and alerts: stalled processes, idle machines with work waiting, blocked feeders,
  machine problems. Alert badge, rotating footer, beep on new alerts.
- Rule editor on the control screen: RULES tab, edit/reorder/delete, live preview of matches and which
  rule or override wins, MAKE RULE from any item. Edited rules are saved to `prism-rules.cfg`.
- `prism-update`: install and update from GitHub; keeps `prism.cfg`; syntax-checks downloads.
- Version shown by every program; the screen flags a router/screen version mismatch.
- `prism-discover` lists GT machines with state and coordinates.
- Compact left column when many buses, feeders and machines are configured.
- Repository: tests runnable with plain Lua 5.3, luacheck, CI, documentation.

### Fixed
- `prism-discover` reported soft-malleted machines as idle instead of disabled.

## [0.3.0] - 2026-11-11

### Added
- Item catalog of everything seen; ITEMS tab with absent items, FORGET and CLEAR ABSENT.
- Keyboard search on the control screen.
- Batch sizes per item and feeders (ME Interface + transposer) that send exact multiples.

## [0.2.0] - 2026-11-11

### Added
- Touchscreen control panel: backlog bars and sparklines, bus filters, UNASSIGNED and OVERRIDES tabs.
- Wireless protocol: status broadcasts, assign/unassign/reload/status commands, screen overrides file.

## [0.1.0] - 2026-11-11

### Added
- Router: label rules and overrides, priority ranking, export bus filters rewritten with stable slots.
- `prism-discover` helper for finding buses.
