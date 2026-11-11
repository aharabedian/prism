--[[ prism.setup.router: prism-setup for the router computer -> /home/prism.cfg.
  run()   processes and rules, ME network, database, export buses, stockers, feeders, interfaces, machines,
          wireless, start on boot; then review and save.
]]

local filesystem = require("filesystem")
local sides      = require("sides")
local files      = require("prism.files")
local probe      = require("prism.probe")
local input      = require("prism.setup.input")
local paths      = require("prism.setup.paths")
local render     = require("prism.setup.render")
local processes  = require("prism.setup.processes")
local hardware   = require("prism.setup.hardware")
local autostart  = require("prism.setup.autostart")
local save       = require("prism.setup.save")

local R = {}

function R.run()
  input.begin(10)
  local cfgPath = paths.ROUTER_CFG
  local old = files.loadLua(cfgPath, { sides = sides }) or {}
  if filesystem.exists(cfgPath) then print("Editing " .. cfgPath) end
  local c = {}
  for k, v in pairs(old) do c[k] = v end

  local procs
  procs, c.rules = processes.step(old)
  c.network = hardware.network(old.network)
  if not c.network then return end
  c.database = hardware.database(old.database)
  -- Without a database, export buses and feeders can't be configured: keep what was there.
  if c.database then
    c.buses, c.slotsPerBus = hardware.buses(old.buses, old.slotsPerBus, procs)
  else
    c.buses = old.buses or {}; input.skipStep()
  end
  c.stockers = hardware.stockers(old.stockers, procs)
  if c.database then
    -- Feeders and interface outputs each need their own interface block.
    c.feeders = hardware.feeders(old.feeders, c.network, procs, function(a)
      for _, e in ipairs(old.interfaces or {}) do if input.sameAddr(a, e.address) then return true end end
    end)
    local feeding = {}
    for _, f in ipairs(c.feeders) do feeding[f.interface] = true end
    c.interfaces = hardware.interfaces(old.interfaces, function(a) return a == c.network or feeding[a] end, procs)
  else
    c.feeders = old.feeders or {}; input.skipStep()
    c.interfaces = old.interfaces or {}; input.skipStep()
  end
  c.machines = hardware.machines(old.machines, procs)

  input.header("Wireless link to the control screen")
  if not probe.isWireless() then print("  no Wireless Network Card found - the control screen needs one in this computer") end
  c.modemPort = input.askPort(old.modemPort)
  c.token = c.modemPort and input.askToken(old.token) or nil

  local shrc = autostart.step("prism")
  local text = render.router(c)
  save.review(cfgPath, text, shrc)
  for _, w in ipairs(processes.coverage(c, procs)) do print("warning: " .. w) end
  if not c.database and #c.buses + #c.feeders + #c.interfaces > 0 then
    print("warning: export buses, interfaces and feeders need a Database Upgrade - the router won't start without one")
  end
  if not input.yes("Save?", true) then print("nothing saved"); return end
  if not save.commit(cfgPath, text, shrc) then return end
  print(("saved %d bus(es), %d stocker(s), %d interface(s), %d feeder(s), %d machine(s), %d rule(s)."):format(
    #c.buses, #c.stockers, #c.interfaces, #c.feeders, #c.machines, #c.rules))
  if c.modemPort then
    print(("On the control computer, run prism-setup and choose the control screen: port %d, secret %s.")
      :format(c.modemPort, c.token and ("%q"):format(c.token) or "none"))
  end
  print("Start prism to use it (or press RELOAD CFG on the control screen if it's running).")
end

return R
