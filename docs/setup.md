# Setup

Two computers talk over wireless. The **router** does all the work; the **control** computer is a
touchscreen front end. Only the router is required.

## The router computer

| Part | Why |
|---|---|
| Computer case or server, T2+ CPU, 2× T3.5 RAM, HDD with OpenOS | runs `prism` |
| Wireless Network Card | status and commands for the control screen |
| Internet Card (optional) | `prism-update` |
| Adapter touching the subnet's **ME Controller** (or an ME Interface on it) | reads the network |
| **Database Upgrade** (any tier) inside an adapter | stages items for filters |
| Adapter touching each **cable block** that has export buses on it | one adapter covers every bus on that block |
| Adapter touching each **GT machine** you want to monitor (optional) | machine status, stall detection |
| Power Converter | OpenComputers doesn't run on EU directly |

Mind the component limit: a T3 CPU allows 16 components, and every adapter-adjacent block, card,
screen and the database counts. A server in a rack with component buses goes much higher.

## Export buses

For each machine (or group of identical machines):

1. Put an **Export Bus** on the subnet facing the machine's input.
2. Put **2 Capacity Cards** in it, for 9 filter slots (`slotsPerBus = 9`). Use 1 slot with no cards, or 5 with one.
3. Optionally add **Acceleration Cards** for throughput.

Export buses only get items with a batch size of 1. Use a feeder for anything else.

## Feeders (batch items)

For recipes that need exact amounts (2 Cinnabar, 9 of something, etc.):

```
[Adapter] - [ME Interface BLOCK on the subnet] - [Transposer] - [Machine]
```

The interface must be the full block, not the cable part, and it needs an adapter touching it.
The transposer must touch both the interface and the machine; it's a component on its own (connect it with cable).

## Machine monitoring

Put an adapter against each GT machine (or multiblock controller). `prism-discover` lists them with their
coordinates; toggle one with a soft mallet to tell which is which (it shows `disabled`).

## The control computer

| Part | Why |
|---|---|
| T3 GPU and T3 screen(s) (a multiblock wall works) | 160×50 display; touch is built into T3 screens |
| Keyboard | search and rule editing |
| Wireless Network Card | talks to the router (keep it within wireless range) |
| Internet Card (optional) | `prism-update` |

## Install

On each computer with an Internet Card:

```
wget -f https://raw.githubusercontent.com/aharabedian/prism/main/src/prism-update.lua /home/prism-update.lua
/home/prism-update aharabedian/prism
```

This puts `prism`, `prism-control`, `prism-discover` and `prism-update` in `/home/bin` (on the shell path),
copies `prism.example.cfg` to `/home`, and creates `/home/prism.cfg` if it doesn't exist.

Without an Internet Card, copy the files from `src/` into `/home/bin/` and `config/prism.example.cfg`
to `/home/prism.cfg` by any means you like (pastebin, a floppy, etc.).

## First run

1. **Identify your buses:** by hand, put a different marker item in slot 1 of each export bus's filter
   (cobblestone in the washer bus, dirt in the centrifuge bus...).
2. **Run `prism-discover`:** it prints config lines for every bus (showing its marker item), interface,
   transposer and machine.
3. **Edit `/home/prism.cfg`:** paste the lines into `buses`, `feeders` and `machines`, and set each `process`.
   See [configuration.md](configuration.md).
4. **Run `prism`:** it logs each filter change and any item that has no rule.
5. **Run `prism-control` on the control computer:** it shows **LIVE** in the header once it hears the router.

## Start on boot

Add the program name as a line in `/home/.shrc` on that computer: `prism` on the router, `prism-control` on the display.

## Updating

Coming from a setup that predates the PRISM name (`/home/router.cfg`)? The first `prism-update`
renames `router.cfg` and `router-*.cfg` to `prism.cfg` / `prism-*.cfg`, keeping your settings and data.


Run `prism-update` on each computer, then restart `prism` / `prism-control`. Your `prism.cfg` is kept;
compare it with `/home/prism.example.cfg` for new options. If the router and screen run different
versions, the screen's header shows a yellow `router X ≠ screen Y` badge.
