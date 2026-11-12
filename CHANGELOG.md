# Changelog

All notable changes to this project. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
