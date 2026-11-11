--[[ prism-setup.lua - guided setup for either PRISM computer.

  Usage: prism-setup

  Asks whether this computer is the router or the control screen, then:
    router:  processes and starting rules, ME network, database, export buses,
             stocking input buses, feeders, GT machines, wireless, start on boot
             -> /home/prism.cfg
    screen:  wireless, beep, start on boot                -> /home/prism-control.cfg
  Start on boot adds (or removes) the program in /home/.shrc, which the OpenOS
  shell runs when the computer boots.

  Run it again any time: the current settings are offered as defaults (press
  Enter to keep one, "-" to drop it). Settings it doesn't ask about, like
  interval or overrides, are kept. The previous file is saved as <file>.bak.
  Ctrl+D cancels without saving anything.

  Tip: to tell export buses apart, drop a different "marker" item into slot 1
  of each bus's filter by hand first (cobblestone in the washer bus, ...).
  Stocking input buses: the same, in slot 1 of their configuration.
  The steps live in /home/lib/prism/setup/.
]]

-- Modules live in /home/lib/prism (prism-update installs them). Forget copies cached by an earlier
-- run, so restarting after an update loads the new ones.
if not package.path:find("/home/lib/?.lua", 1, true) then package.path = package.path .. ";/home/lib/?.lua" end
for name in pairs(package.loaded) do if name:find("^prism%.") then package.loaded[name] = nil end end
if not pcall(require, "prism.version") then error("PRISM's modules are missing from /home/lib/prism - run prism-update", 0) end

local component = require("component")
local VERSION   = require("prism.version")
local input     = require("prism.setup.input")

local function main()
  print("prism-setup " .. VERSION .. " - Enter keeps the [default], - skips, Ctrl+D cancels")
  print("")
  print("What is this computer?")
  -- Guess from what's attached: the router has adapters on ME parts.
  local router = false
  for _, t in ipairs({ "me_controller", "me_interface", "me_exportbus", "me_inputbus", "database" }) do
    if component.isAvailable(t) then router = true end
  end
  local role = input.choose({
    "router - does the routing (adapters on the ME network, buses and machines)",
    "control screen - the touchscreen display that talks to the router",
  }, router and 1 or 2)
  require(role == 1 and "prism.setup.router" or "prism.setup.control").run()
end

local ok, err = pcall(main)
if not ok then
  if err == input.CANCEL then print(""); print("cancelled - nothing saved")
  else error(err, 0) end
end
