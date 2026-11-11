# PRISM

**Programmable Routing & Item Sorting for ME.** Dynamic item routing for **Applied Energistics 2**
using **OpenComputers**, built for **GregTech: New Horizons** ore processing but useful for any
"send these items to that machine" job.

Instead of hand-managing ore dictionary cards, a computer scans an AE2 subnet, decides where each
item should go from pattern rules and per-item overrides, and rewrites export bus filters to match.
A second computer runs a touchscreen control panel.

![Control screen](docs/images/dashboard.png)

## Features

- **Rule-based routing**: Lua patterns on item names (`^Crushed .+ Ore$` → `wash`), per-item overrides, priorities.
- **Export buses** that always hold the 9 highest-priority items waiting for their machine.
- **Batch feeders** that send exact multiples (2, 9, 36…) for recipes that would otherwise clog on leftovers.
- **Item catalog**: every item ever seen, so you can set up routing before you have any in stock.
- **Machine monitoring**: GT machines' working/idle state, progress, power and maintenance.
- **Stall detection and alerts**: stalled processes, idle machines with work waiting, blocked feeders.
- **Touchscreen control panel**: backlog charts, assign items, edit rules with a live preview of what they'd catch.
- **One-command install and updates** from GitHub on each computer.

| Routing an item | Editing a rule |
|---|---|
| ![Routing an item](docs/images/route-item.png) | ![Rule editor](docs/images/rule-editor.png) |

## Requirements

- OpenComputers and Applied Energistics 2, as shipped in GTNH. Computers on the Lua 5.3 architecture (switch a CPU's architecture by shift-right-clicking it in hand).
- A **router computer** with a wireless card, adapters, and a Database Upgrade.
- A **control computer** with a tier 3 GPU and screen, keyboard, and wireless card. Optional, but it's most of the fun.
- An **Internet Card** on each computer for `prism-update`. Optional: you can copy files manually instead.

Full hardware list and build steps: **[docs/setup.md](docs/setup.md)**.

## Install

On each computer, with an Internet Card:

```
wget -f https://raw.githubusercontent.com/aharabedian/prism/main/src/prism-update.lua /home/prism-update.lua
/home/prism-update aharabedian/prism
```

Replace `aharabedian` with the GitHub account hosting the repo. This installs `prism`, `prism-control`, `prism-discover`
and `prism-update` onto the shell path and creates `/home/prism.cfg` from the example.
Run `prism-update` again any time to update; your config and data are never overwritten.

## Quick start

1. Run `prism-discover` on the router computer. It prints ready-to-paste config lines for your buses, feeders and machines.
2. Edit `/home/prism.cfg`: paste the buses in and give each one a `process`.
3. Run `prism`.
4. Run `prism-control` on the control computer.
5. Tap anything under **UNASSIGNED** to route it, or write rules in the **RULES** tab.

## Documentation

| Doc | What's in it |
|---|---|
| [docs/setup.md](docs/setup.md) | Hardware, in-game build, first run |
| [docs/configuration.md](docs/configuration.md) | Every `prism.cfg` option, rules and patterns, data files |
| [docs/architecture.md](docs/architecture.md) | How routing, feeders and stall detection work; in-game verification status |
| [docs/protocol.md](docs/protocol.md) | Wireless messages between the router and the control screen |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Common problems and fixes |
| [tests/README.md](tests/README.md) | The mocked test suite |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Development workflow and conventions |

## Development

Everything is tested against a mocked OpenComputers/AE2/GregTech world, so no Minecraft is needed:

```
lua5.3 tests/run.lua      # all tests
luacheck .                # lint
make screens              # render the control screen from tests into PNGs (needs Python + Pillow)
```

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
