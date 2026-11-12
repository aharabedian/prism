LUA ?= lua5.3
# Tools installed by `make dev` (tools/setup-dev.sh) are used when present, else the ones on PATH.
LUACHECK ?= $(if $(wildcard .luarocks/bin/luacheck),.luarocks/bin/luacheck,luacheck)
PYTHON   ?= $(if $(wildcard .venv/bin/python),.venv/bin/python,python3)

.PHONY: check test lint screens docs-images dev clean

check: lint test

test:
	$(LUA) tests/run.lua

lint:
	$(LUACHECK) .

# Install luacheck (.luarocks/) and a Python venv with requirements.txt (.venv/), no sudo needed
dev:
	tools/setup-dev.sh

# Render every screen the tests draw into build/screens/*.png
screens:
	rm -rf build/screens && mkdir -p build/screens
	SCREENS=build/screens $(LUA) tests/run.lua
	$(PYTHON) tools/render_screens.py build/screens build/screens

# Refresh the images used in the README
docs-images: screens
	cp build/screens/rules-dashboard.png docs/images/dashboard.png
	cp build/screens/rules-rule.png docs/images/rule-editor.png
	cp build/screens/route-assign.png docs/images/route-item.png
	cp build/screens/fallback-process.png docs/images/fallbacks.png
	cp build/screens/fallback-route.png docs/images/fallback-items.png
	cp build/screens/setup-bus-named.png docs/images/setup-editor.png

clean:
	rm -rf build
