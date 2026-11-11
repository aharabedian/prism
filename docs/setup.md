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

Put an adapter against each GT machine (or multiblock controller). `prism-setup` lists them with their
coordinates and state; toggle one with a soft mallet to tell which is which (it shows `disabled`).

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

This puts `prism`, `prism-control`, `prism-setup`, `prism-discover` and `prism-update` in `/home/bin` (on the shell path)
and the annotated `prism.example.cfg` in `/home` for reference.

Without an Internet Card, copy the files from `src/` into `/home/bin/` by any means you like (pastebin, a floppy, etc.).

## First run

Run `prism-setup` on each computer. It first asks whether the computer is the **router** or the
**control screen** (guessing from what's attached), then walks through that role's settings.
Defaults are in `[brackets]`: Enter keeps one, `-` removes it, Ctrl+D cancels without saving.
Run it again any time to change something.

### Router

Before you start, put a different marker item in slot 1 of each export bus's filter by hand
(cobblestone in the washer bus, dirt in the centrifuge bus...) so you can tell the buses apart.

| Step | You answer |
|---|---|
| Processes | which of crush, wash, thermal, centrifuge, sift (or your own names) you have machines for; it writes the matching [starting rules](configuration.md#rules), asking first if you already have rules |
| ME network, database | which one, only if there are several |
| Export buses | Capacity Cards per bus, then for each bus (shown with its marker item) a process (number or new name) and optional name, or Enter to skip |
| Feeders | for each transposer (interface and machine sides found automatically): process and name, or Enter to skip |
| GT machines | for each machine (shown with state and coordinates): process and name, or Enter to skip |
| Wireless | port (default 4242, 0 = off) and an optional shared secret |
| Start on boot | `y` to start `prism` when the computer boots |
| Review | warnings for processes with no bus/feeder or no rule; `y` saves `/home/prism.cfg` |

It ends by printing the port and secret to enter on the control screen. Settings it doesn't ask about
(`interval`, `overrides`...) are kept, and the previous file is saved as `prism.cfg.bak`.
Prefer editing by hand? See [configuration.md](configuration.md); `prism-discover` prints config lines for
every component.

### Control screen

| Step | You answer |
|---|---|
| Wireless | the same port and secret as the router |
| Alerts | beep on new alerts or not |
| Start on boot | `y` to start `prism-control` when the computer boots |

It saves `/home/prism-control.cfg`, and warns if there's no tier 3 GPU and screen.

Then run `prism` on the router (it logs each filter change and any item with no rule) and `prism-control`
on the screen (it shows **LIVE** in the header once it hears the router).

## Start on boot

`prism-setup`'s start-on-boot step adds the program's name as a line in `/home/.shrc`, which the OpenOS shell
runs when the computer boots, and removes the other PRISM program's line if the computer changed role.
Other lines in `.shrc` are kept. Ctrl+C in the program gets you to the shell.

## Updating

Coming from a setup that predates the PRISM name (`/home/router.cfg`)? The first `prism-update`
renames `router.cfg` and `router-*.cfg` to `prism.cfg` / `prism-*.cfg`, keeping your settings and data.


Run `prism-update` on each computer, then restart `prism` / `prism-control`. Your config files are kept;
run `prism-setup` and press Enter through it to rewrite the config with any new options. If the router and screen run different
versions, the screen's header shows a yellow `router X ≠ screen Y` badge.
