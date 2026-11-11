LUA ?= lua5.3

.PHONY: check test lint screens docs-images clean

check: lint test

test:
	$(LUA) tests/run.lua

lint:
	luacheck .

# Render every screen the tests draw into build/screens/*.png
screens:
	rm -rf build/screens && mkdir -p build/screens
	SCREENS=build/screens $(LUA) tests/run.lua control
	python3 tools/render_screens.py build/screens build/screens

# Refresh the images used in the README
docs-images: screens
	cp build/screens/rules-dashboard.png docs/images/dashboard.png
	cp build/screens/rules-rule.png docs/images/rule-editor.png
	cp build/screens/route-assign.png docs/images/route-item.png

clean:
	rm -rf build
