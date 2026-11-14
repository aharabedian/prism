--[[ prism-control.lua - touchscreen control panel for prism.lua

  Runs on the display computer (tier 3 screen + GPU, wireless card).
  Left:  per-process backlog (stalls flagged), export/stocking buses, feeders and
         monitored machines with live progress.
  Right: UNASSIGNED, ITEMS (everything ever seen), OVERRIDES and RULES.
         Tap an item to route it; tap a rule (or + NEW RULE / MAKE RULE) to
         edit it with a live preview of what it would catch.
  Keyboard: types into the search box, or into the pattern while editing a rule.

  Usage: prism-control [path]   (default /home/prism-control.cfg; run prism-setup to write it)
  QUIT button or Ctrl+C to exit. The work is done by the modules in /home/lib/prism/control/.
]]

-- Modules live in /home/lib/prism (prism-update installs them). Forget copies cached by an earlier
-- run, so restarting after an update loads the new ones.
if not package.path:find("/home/lib/?.lua", 1, true) then package.path = package.path .. ";/home/lib/?.lua" end
for name in pairs(package.loaded) do if name:find("^prism%.") then package.loaded[name] = nil end end
if not pcall(require, "prism.version") then error("PRISM's modules are missing from /home/lib/prism - run prism-update", 0) end

local component  = require("component")
local computer   = require("computer")
local event      = require("event")
local term       = require("term")
local config     = require("prism.config")
local Ui         = require("prism.control.ui")
local Model      = require("prism.control.model")
local StatusView = require("prism.control.status_view")
local ListView   = require("prism.control.list_view")
local PanelView  = require("prism.control.panel_view")
local splash     = require("prism.splash")

local settings = config.loadControl(({ ... })[1] or "/home/prism-control.cfg")
local modem = settings.modemPort and component.isAvailable("modem") and component.modem or nil
local ui = Ui.new(component.gpu)
splash.show(component.gpu, ui.W, ui.H, "PRISM", require("prism.version"), ui.C.accent)
os.sleep(splash.SECONDS)   -- yields: OpenOS keeps running while the logo shows
local m = Model.new(settings, modem)
local status, list, panel = StatusView.new(ui, m), ListView.new(ui, m), PanelView.new(ui, m)

local function drawAll()
  ui.clearHits()
  status.drawHeader()
  status.draw()
  list.draw()
  panel.draw()
  panel.drawFooter()
end

local function main()
  if modem then modem.open(settings.modemPort) end
  ui.fill(1, 1, ui.W, ui.H, ui.C.bg)
  drawAll()
  m.start()

  while m.S.running do
    local ev = table.pack(event.pullMultiple(1, "modem_message", "touch", "key_down", "interrupted"))
    local name, dirty = ev[1], false
    if name == "modem_message" then
      -- modem_message: localAddress, remoteAddress, port, distance, payload
      local redraw = m.onMessage(ev[3], ev[4], ev[6])
      dirty = redraw == "full" or (redraw == "machines" and not status.redrawMachines())
    elseif name == "touch" then
      -- touch: screenAddress, x, y, button, player
      ui.tap(math.floor(ev[3]), math.floor(ev[4]))
      dirty = true
    elseif name == "key_down" then
      -- key_down: keyboardAddress, char, code, player
      dirty = m.onKey(ev[3], ev[4])
    elseif name == "interrupted" then
      m.quit()
    end

    if m.tick(computer.uptime()) then dirty = true end
    if not m.S.running then break end
    if dirty then drawAll() else status.drawHeader() end
  end
end

local ok, err = xpcall(main, debug.traceback)
if modem then modem.close(settings.modemPort) end
ui.restore()
term.clear()
if not ok then io.stderr:write(tostring(err) .. "\n") end
