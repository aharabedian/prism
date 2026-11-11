# Changelog

All notable changes to this project. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
