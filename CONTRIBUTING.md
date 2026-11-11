# Contributing

## Setup

- **Lua 5.3** (`lua5.3`) to run tests. Debian/Ubuntu: `sudo apt install lua5.3`. macOS: `brew install lua@5.3`.
- A C compiler, `make`, `curl` and **Python 3**.
- Then run **`make dev`** ([tools/setup-dev.sh](tools/setup-dev.sh)). It needs no sudo and installs:
  - **luacheck** into `.luarocks/`. It builds LuaRocks there, and uses the Lua 5.3 headers from lua.org
    if `liblua5.3-dev` isn't installed.
  - a Python venv in `.venv/` with [requirements.txt](requirements.txt) (Pillow, for `make screens`).
    It bootstraps pip if the system Python lacks `ensurepip`.

  The Makefile uses these when present, and otherwise falls back to `luacheck` and `python3` on the PATH.
  Re-running is safe.
- On Windows, use WSL; the test runner shells out to `ls`, `mkdir` and `rm`.

## Workflow

1. Write or change a test in `tests/` that shows the behavior you want ([tests/README.md](tests/README.md)).
2. Change the code in `src/`.
3. `make check` (lint + tests) must pass. CI runs the same on every push and pull request.
4. Update the docs in the same change (see below).
5. If you could try it in game, say so in the PR and update the verification table in
   [docs/architecture.md](docs/architecture.md).

## Code conventions

- **Programs are thin; modules do the work.** See the module map in [docs/architecture.md](docs/architecture.md).
  Each module's header comment is its interface. `prism-update.lua` stays self-contained: it installs the rest.
  A new file in `src/` or `lib/` needs a line in [manifest.lua](manifest.lua).
- **Target OpenComputers' Lua 5.3.** No 5.4-only features. Use OpenOS's `unicode` library for text width,
  not `utf8`.
- **Don't block.** The router must keep yielding (`event.pull*`) between steps; long work without yielding
  crashes OpenComputers programs ("too long without yielding").
- **Wireless packets are about 8 KB.** Page or trim lists; never send unbounded data.
- **Never overwrite user files** except through `prism-setup` (which asks and keeps a `.bak`). New config
  keys get a default in `lib/prism/config.lua` (which `prism-setup` writes from); data files (`prism-*.cfg`) stay
  backward compatible.
- **Protocol changes add fields; they don't rename them**, so router and screen can be one version apart.
- 2-space indent, `local` everything, short functions with a comment saying *why* when it isn't obvious.

## Which docs to update

| You changed | Update |
|---|---|
| A config option | `lib/prism/config.lua` (default), `config/prism.example.cfg`, `docs/configuration.md`; `lib/prism/setup/render.lua` if it isn't a plain tuning value |
| A module's interface | its header comment, and the module map in `docs/architecture.md` if its role changed |
| A wireless message or command | `docs/protocol.md` |
| How routing, feeders, stalls or the loop work | `docs/architecture.md` |
| Hardware or build steps | `docs/setup.md` |
| A new failure mode with a known fix | `docs/troubleshooting.md` |
| Anything user-visible | `CHANGELOG.md` under **Unreleased** |

## Releasing

1. Move **Unreleased** in `CHANGELOG.md` to a new version heading with the date.
2. Bump the version in `lib/prism/version.lua` and `VERSION` in `src/prism-update.lua`.
3. `make check`, commit and push to `main`.
4. Publish a GitHub **release** (a bare tag isn't enough: `prism-update` asks for the latest release):
   `gh release create vX.Y.Z --title "PRISM X.Y.Z" --notes-file <the changelog section>`.
   `prism-update` installs it on every computer that follows releases, which is the default.
