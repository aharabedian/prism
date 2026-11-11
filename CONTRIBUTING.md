# Contributing

## Setup

- **Lua 5.3** (`lua5.3`) to run tests. Debian/Ubuntu: `sudo apt install lua5.3`. macOS: `brew install lua@5.3`.
- **luacheck** for linting: `luarocks --lua-version=5.3 install luacheck` (Debian/Ubuntu also need `liblua5.3-dev`).
- Optional: **Python 3 + Pillow** for `make screens`.
- On Windows, use WSL; the test runner shells out to `ls`, `mkdir` and `rm`.

## Workflow

1. Write or change a test in `tests/` that shows the behavior you want ([tests/README.md](tests/README.md)).
2. Change the code in `src/`.
3. `make check` (lint + tests) must pass. CI runs the same on every push and pull request.
4. Update the docs in the same change (see below).
5. If you could try it in game, say so in the PR and update the verification table in
   [docs/architecture.md](docs/architecture.md).

## Code conventions

- **Each program is one self-contained file.** No `require` of project files, so any file can be
  copied to a computer on its own.
- **Target OpenComputers' Lua 5.3.** No 5.4-only features. Use OpenOS's `unicode` library for text width,
  not `utf8`.
- **Don't block.** The router must keep yielding (`event.pull*`) between steps; long work without yielding
  crashes OpenComputers programs ("too long without yielding").
- **Wireless packets are about 8 KB.** Page or trim lists; never send unbounded data.
- **Never overwrite user files** except through `prism-setup` (which asks and keeps a `.bak`). New config
  keys get a default in `loadConfig()` and are written by `prism-setup`; data files (`prism-*.cfg`) stay
  backward compatible.
- **Protocol changes add fields; they don't rename them**, so router and screen can be one version apart.
- 2-space indent, `local` everything, short functions with a comment saying *why* when it isn't obvious.

## Which docs to update

| You changed | Update |
|---|---|
| A config option | `config/prism.example.cfg`, `docs/configuration.md`, the matching render in `src/prism-setup.lua` |
| A wireless message or command | `docs/protocol.md` |
| How routing, feeders, stalls or the loop work | `docs/architecture.md` |
| Hardware or build steps | `docs/setup.md` |
| A new failure mode with a known fix | `docs/troubleshooting.md` |
| Anything user-visible | `CHANGELOG.md` under **Unreleased** |

## Releasing

1. Move **Unreleased** in `CHANGELOG.md` to a new version heading with the date.
2. Bump `VERSION` in every `src/*.lua` file (`grep -n 'local VERSION' src/`).
3. `make check`, commit, tag `vX.Y.Z`, push. Players update with `prism-update`.
