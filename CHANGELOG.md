# Changelog

All notable changes to this project. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
