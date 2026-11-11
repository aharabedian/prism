# CLAUDE.md

Guidance for Claude Code working in this repo. Keep it short and current; details live in `docs/`.

## What this is

**PRISM** (Programmable Routing & Item Sorting for ME): OpenComputers programs for GregTech: New Horizons.
`src/prism.lua` (the router) routes items from an AE2 subnet to machines (export bus filters + batch
feeders) using pattern rules and overrides, monitors GT machines, and detects stalls.
`src/prism-control.lua` is a touchscreen UI that talks to it over wireless.
Read [docs/architecture.md](docs/architecture.md) before changing behavior.

## Commands

```
make check                        # lint + all tests: run before every commit
lua5.3 tests/run.lua [filter]     # tests (add -v for every check)
luacheck .                        # lint
make screens                      # render the control screen from tests to PNGs (Python + Pillow)
```

## Rules

- **Test first, against the mock.** Every behavior change gets a check in `tests/` (see `tests/README.md`).
  Screen changes get a screen test (find text, tap it, assert what's drawn and what's sent).
  Never mark work done without `make check` passing.
- **The mock mirrors the game, not the other way round.** `tests/mocks/oc.lua` encodes our understanding
  of the OpenComputers/AE2/GregTech APIs. If the user reports in-game behavior that differs, fix the mock
  first, then the code, and update the verification table in `docs/architecture.md`.
  Don't present unverified API assumptions as fact; that table says what's confirmed.
- **Runtime constraints (OpenComputers):**
  - Lua 5.3, no 5.4 features, OpenOS `unicode` instead of `utf8` in `src/`.
  - Each `src/` file is self-contained (no project-local `require`).
  - Never block without yielding.
  - Wireless packets are ~8 KB max: page or trim.
  - GPU calls are rationed, so redraw only what changed for frequent updates.
- **Compatibility:**
  - New config keys get defaults in `loadConfig()`.
  - Protocol changes add fields rather than renaming them.
  - Never overwrite the user's `prism.cfg` or `prism-*.cfg` data files.
- **Docs move with code**, in the same change: see the table in `CONTRIBUTING.md` (config →
  `docs/configuration.md` + `config/prism.example.cfg`; messages → `docs/protocol.md`; behavior →
  `docs/architecture.md`; user-visible → `CHANGELOG.md` Unreleased). Keep docs tight: tables over prose,
  no duplicated explanations; link instead.
- **Versions:** `VERSION` is in all four `src/*.lua` files; bump them together when releasing.

## Layout

```
src/        prism.lua (router), prism-control.lua (screen), prism-discover.lua, prism-update.lua
config/     prism.example.cfg, the annotated config users start from
docs/       setup, configuration, architecture, protocol, troubleshooting, images/
tests/      run.lua, helper.lua, mocks/oc.lua, test_*.lua
tools/      render_screens.py
```
