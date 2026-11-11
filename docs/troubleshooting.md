# Troubleshooting

The router's log is the first place to look: it prints every unassigned item, missing bus or feeder,
alert and error. `prism-discover` shows what the computer can actually see.

## Setup

| Symptom | Fix |
|---|---|
| `no ME controller/interface found` | Put an adapter against the subnet's controller (or an ME Interface on it) and connect it with cable. Set `network` if there are several |
| `no database found` | Put a Database Upgrade *inside* an adapter (needed for export buses, interfaces and feeders) |
| `prism-discover` lists no stocking input buses | Put an adapter against each one. Still none: your pack's OpenComputers predates the stocking bus driver; update GTNH |
| `<name>: no me_inputbus matching ...` | Wrong `address` in `stockers`; run `prism-discover` |
| `prism-discover` lists no export buses | The adapter must touch the **cable block** the buses are on, not the bus face or the machine |
| `bus ... (side x): no export bus` | Wrong `side`. Run `prism-setup` again, or use the line `prism-discover` printed |
| `transposer sees no inventory on interfaceSide` | Sides are relative to the transposer; check `prism-discover`'s transposer section. Use an ME Interface **block** |
| `<name>: ... is the network PRISM scans` | The interface in `interfaces` is the one the router reads the subnet through. Use another interface block (or point `network` at the controller) |
| `A and B both use slot N of ME interface ...` | Two outputs (interfaces, feeders) configure the same interface. Give each its own interface block, or feeders different `slot`s |
| Main net and subnet merged into one network | A main-net cable touches the interface block. Only the import bus may face it |
| `too many components` / components missing | Over the CPU's component limit; see [setup.md](setup.md) |

## Routing

| Symptom | Fix |
|---|---|
| Item stays in **UNASSIGNED** | No rule matches its name; add a rule or tap it and APPLY |
| A rule doesn't apply | An override or an earlier rule wins. Open it in the rule editor; the preview says which |
| `needs batches of N - '<process>' has no feeder or stocker` | Export buses and interfaces can't send exact amounts. Add a feeder or stocker, or set the batch to 1 |
| Multiblock with a stocker won't start | Check the items are in the subnet (the stocker shows the network, not its own stock), and that no other stocking bus on the same multiblock holds the same items |
| Process shows **NONE** in red | Items are waiting but nothing is configured for that process |
| Feeder `blocked: N in machine, not a multiple of B` | A leftover from before the feeder. Take it out of the machine by hand once |
| Feeder `machine not accepting` | The machine's input holds a different item, or the machine refuses insertion from that side |
| Bus filters change constantly | Two items of equal priority are trading the last slot; give one a higher priority |

## Control screen

| Symptom | Fix |
|---|---|
| `waiting for router` forever | Same `PORT` on both? Wireless card on both, within range? If `token` is set, the screen needs it too. Run `prism-setup` on both; the router's run prints the values |
| `NO SIGNAL` | The router stopped, crashed (check its screen) or is out of range |
| Yellow `router X ≠ screen Y` badge | Run `prism-update` on both computers and restart both |
| `prism-control.lua needs a tier 3 GPU and screen` | The display must be at least 100×36: T3 GPU and T3 screen |
| A machine shows `offline` | Its chunk is unloaded or the adapter lost contact. If it's clearly running, see the verification table in [architecture.md](architecture.md) and open an issue with `prism-discover`'s output |

## Updating

| Symptom | Fix |
|---|---|
| `doesn't look like valid Lua (wrong repo or branch?)` | GitHub returned an error page. Check `OWNER/REPO` and branch or tag; nothing was changed |
| `can't find the latest release of ...: HTTP 403` | GitHub's API limits each IP to 60 requests an hour. Wait, or `prism-update main` (no API call); nothing was changed |
| `can't download ...: HTTP 404` | That branch or tag doesn't exist, or the file isn't in it |
| `can't download ...` | Internet Card missing, or the server blocks outgoing HTTP (OpenComputers config) |
| New options don't appear | `prism-update` never overwrites `prism.cfg`; copy them from `/home/prism.example.cfg` |
