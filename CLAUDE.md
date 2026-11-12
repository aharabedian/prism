# CLAUDE.md

Guidance for Claude Code working in this repo. Keep it short and current; details live in `docs/`.

## What this is

**PRISM** (Programmable Routing & Item Sorting for ME): OpenComputers programs for GregTech: New Horizons.
`src/prism.lua` (the router) routes items from an AE2 subnet to machines (export buses, GT stocking buses,
batch feeders) using pattern rules and overrides, monitors GT machines, and detects stalls.
`src/prism-control.lua` is a touchscreen UI that talks to it over wireless.
Programs in `src/` are thin; the code lives in modules under `lib/prism/`.
Read [docs/architecture.md](docs/architecture.md) (module map + interfaces) before changing behavior.

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
  - Lua 5.3, no 5.4 features, OpenOS `unicode` instead of `utf8` in `src/` and `lib/`.
  - `src/prism-update.lua` stays self-contained (it installs the modules). Other programs keep the
    three-line bootstrap at the top and `require("prism.…")` modules.
  - Never block without yielding.
  - Wireless packets are ~8 KB max: page or trim.
  - GPU calls are rationed, so redraw only what changed for frequent updates.
- **Compatibility:**
  - Config format compatibility isn't required yet (single user); still give new keys defaults in
    `lib/prism/config.lua` and make sure `prism-setup` writes them.
  - Protocol changes add fields rather than renaming them.
  - Only `prism-setup` writes `prism.cfg` / `prism-control.cfg` (after confirmation, keeping a `.bak`);
    nothing overwrites the `prism-*.cfg` data files.
- **Modules and interfaces:**
  - Each module's header comment is its interface (exports, shapes in and out). Change it with the code.
  - Dependencies point one way: programs → `router/`, `control/`, `setup/` → shared `lib/prism/*.lua`.
    Role modules don't require each other's; shared modules don't require role modules.
  - No state at module load (OpenOS caches modules); keep state in objects a module returns.
  - Keep logic pure where it can be (`rules`, `planner`, `slots`, `protocol`) and unit-test it in `tests/test_units.lua`.
  - A new output kind implements the interface in `lib/prism/router/outputs.lua`; don't special-case kinds elsewhere.
  - A new file in `src/` or `lib/` goes in `manifest.lua` (a test checks).
- **`lib/prism/lens/` is vendored from LENS** (`../lens`): never edit it here; change LENS, then
  `tools/sync-lens.sh` (a test checks they match when `../lens` exists).
- **Docs move with code**, in the same change: see the table in `CONTRIBUTING.md` (config →
  `docs/configuration.md` + `config/prism.example.cfg`; messages → `docs/protocol.md`; behavior →
  `docs/architecture.md`; user-visible → `CHANGELOG.md` Unreleased). Keep docs tight: tables over prose,
  no duplicated explanations; link instead.
- **Versions:** `lib/prism/version.lua` and `VERSION` in `src/prism-update.lua`; bump both when releasing (a test checks).

## Layout

```
src/        programs: prism.lua (router), prism-control.lua (screen), prism-setup.lua, prism-discover.lua, prism-update.lua
lib/prism/  modules: shared (config, protocol, rules, ...), router/, control/, setup/
manifest.lua  every file prism-update installs
config/     prism.example.cfg, the annotated config users start from
docs/       setup, configuration, architecture, protocol, troubleshooting, images/
tests/      run.lua, helper.lua, mocks/oc.lua, test_*.lua
tools/      render_screens.py
```
