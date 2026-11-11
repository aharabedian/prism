--[[ prism.lua - PRISM router: Programmable Routing & Item Sorting for ME (AE2) networks

  Every few seconds: scan the ME (sub)network, decide each item's process, priority and batch size,
  point export buses and GT stocking input buses at the top items per process, detect stalls and
  broadcast status for the control screen. Every second, feeders move exact batches into machines.
  Every couple of seconds, monitored GT machines are polled.

  Usage: prism [path/to/prism.cfg]     (default /home/prism.cfg)
  The work is done by the modules in /home/lib/prism/router/ - see docs/architecture.md.
]]

-- Modules live in /home/lib/prism (prism-update installs them). Forget copies cached by an earlier
-- run, so restarting after an update loads the new ones.
if not package.path:find("/home/lib/?.lua", 1, true) then package.path = package.path .. ";/home/lib/?.lua" end
for name in pairs(package.loaded) do if name:find("^prism%.") then package.loaded[name] = nil end end
if not pcall(require, "prism.version") then error("PRISM's modules are missing from /home/lib/prism - run prism-update", 0) end

local Router = require("prism.router.core")

local router = Router.new(({ ... })[1] or "/home/prism.cfg")
router:setup()
router:run()
