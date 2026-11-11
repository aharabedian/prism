-- test_setup.lua: prism-setup sets up the router (processes/rules, hardware, wireless, start on boot) or the control
-- screen (wireless, beep, start on boot), rewrites the config keeping a .bak, and both programs use the result.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check

-- /home lives in the test's temp dir
local home = H.TMP .. "/root/home"
os.execute('mkdir -p "' .. home .. '"')
local realGetenv = os.getenv
os.getenv = function(k) if k == "PRISM_PREFIX" then return H.TMP .. "/root" end return realGetenv(k) end
local ROUTER_CFG, CONTROL_CFG, SHRC = home .. "/prism.cfg", home .. "/prism-control.cfg", home .. "/.shrc"

-- World: one controller, one database, three buses (one with a marker), a stocking input bus, an
-- interface + transposer feeding a machine, two GT machines and a wireless card.
M.busHosts["eb111111-1111"][2][1] = { name = "minecraft:cobblestone", damage = 0.0, label = "Cobblestone" }
M.proxies["if000000-iiii"] = { address = "if000000-iiii", type = "me_interface",
  setInterfaceConfiguration = function() return true end }
M.proxies["tp000000-tttt"] = { address = "tp000000-tttt", type = "transposer",
  getInventorySize = function(s) if s == 4 then return 9 elseif s == 5 then return 3 end return nil, "no inventory" end,
  getInventoryName = function(s) return s == 4 and "appliedenergistics2:tile.BlockInterface" or "gregtech:gt.blockmachines" end }
M.machine("gm010000-aaaa", { isMachineActive = true, isWorkAllowed = true })
M.proxies["gm010000-aaaa"].getCoordinates = function() return 120, 64, -340 end
M.machine("gm020000-bbbb", { isMachineActive = false, isWorkAllowed = false })
local stocker = M.stocker("st010000-ssss", { advanced = true })
stocker.slots[1] = { name = "minecraft:sand", damage = 0, label = "Sand" }

local function read(path) local f = io.open(path); if not f then return nil end; local s = f:read("*a"); f:close(); return s end
local function write(path, s) local f = assert(io.open(path, "w")); f:write(s); f:close() end
local function loadCfg(path) return assert(loadfile(path, "t", { sides = require("sides") }))() end

local ORIGINAL = [[
return { interval = 7, myNote = "keep me",
         overrides = { ["minecraft:cobblestone:0"] = { process = "ignore" } },
         rules = { { pattern = "^Crushed .+ Ore$", process = "wash" }, { pattern = "Ore$", process = "crush" } } }
]]
write(ROUTER_CFG, ORIGINAL)
write(SHRC, "echo hello\nprism-control\n")

-- Run prism-setup with scripted answers; returns everything it printed or prompted.
local function wizard(answers)
  local out = {}
  local realPrint, realWrite, realRead = print, io.write, io.read
  print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    out[#out + 1] = table.concat(parts, "\t") .. "\n"
  end
  io.write = function(...) for _, s in ipairs({ ... }) do out[#out + 1] = tostring(s) end end
  local i = 0
  io.read = function() i = i + 1; return answers[i] end   -- nil after the last answer = Ctrl+D
  local ok, err = pcall(H.run, "prism-setup.lua")
  print, io.write, io.read = realPrint, realWrite, realRead
  if not ok then error(err, 0) end
  return table.concat(out)
end
-- `before`, then n blank answers (Enter: keep every default), then `after`.
local function answers(before, n, after)
  local t = {}
  for _, a in ipairs(before) do t[#t + 1] = a end
  for _ = 1, n do t[#t + 1] = "" end
  for _, a in ipairs(after) do t[#t + 1] = a end
  return t
end
local out
local function has(s) return out:find(s, 1, true) ~= nil end

---------------------------------------------------------------- router, first run
out = wizard({
  "",                          -- role: router is the default (ME parts attached)
  "1 2 4", "y",                -- crush, wash, centrifuge; use the standard rules
  "",                          -- 2 Capacity Cards (default)
  "2", "Washer 1",             -- eb111111 north (Cobblestone marker): wash, by number
  "",                          -- eb111111 south: skip
  "crush", "",                 -- eb222222 up, by name, no display name
  "2", "Washer M",             -- stocking bus st010000 (Sand marker): wash
  "centrifuge", "Centrifuge 2",-- feeder through tp000000
  "wash", "Washer 1",          -- gm010000
  "",                          -- gm020000: skip
  "", "s3cret",                -- wireless: default port, a secret
  "",                          -- start on boot: yes
  "y",                         -- save
})

check(has("choose 1-2 [1]"), "router suggested when ME parts are attached")
check(has("[1 2]"), "processes the current rules use are preselected")
check(has("Thermal Centrifuge") and has("Sifter"), "standard processes are listed with their machines")
check(has("instead of your current 2 rule(s)? (y/n) [n]"), "asks before replacing rules, defaulting to keep")
check(has("me000000-cccc") and has("db000000-aaaa"), "only ME controller and database are picked without asking")
check(has("1) crush  2) wash  3) centrifuge"), "chosen processes offered by number")
check(has("Cobblestone") and has("120 64 -340") and has("disabled"), "buses show markers, machines state and coordinates")
check(has("stocking bus st010000, advanced - slot 1: Sand"), "stocking buses show their slot 1 marker")
check(has("interface on west") and has("machine on east"), "feeder sides found from what the transposer touches")
check(not has("warning:"), "no coverage warnings when every process has a bus or feeder")
check(has('port 4242, secret "s3cret"'), "tells the user what to enter on the control computer")
check(has("removing prism-control from .shrc"), "says it drops the other program from .shrc")

check(read(ROUTER_CFG .. ".bak") == ORIGINAL, "previous prism.cfg kept as prism.cfg.bak")
local c = loadCfg(ROUTER_CFG)
check(c.network == "me000000-cccc" and c.database == "db000000-aaaa", "network and database saved")
check(c.modemPort == 4242 and c.token == "s3cret" and c.slotsPerBus == 9, "wireless and slots saved")
check(c.interval == 7 and c.myNote == "keep me" and c.overrides["minecraft:cobblestone:0"].process == "ignore",
  "settings the wizard doesn't ask about are kept")
check(c.stallAfter == 60 and c.verbose == false, "every other option written with its default")
check(#c.rules == 6 and c.rules[1].process == "wash" and c.rules[6].pattern == "Ore$" and c.rules[6].priority == 5,
  "standard rules for crush/wash/centrifuge saved")
check(#c.buses == 2 and c.buses[1].address == "eb111111-1111" and c.buses[1].side == 2
  and c.buses[1].process == "wash" and c.buses[1].name == "Washer 1", "bus process picked by number")
check(c.buses[2].side == 1 and c.buses[2].process == "crush" and c.buses[2].name == nil, "blank name left out")
check(#c.stockers == 1 and c.stockers[1].address == "st010000-ssss" and c.stockers[1].process == "wash"
  and c.stockers[1].name == "Washer M", "stocking bus saved")
local f = c.feeders[1]
check(#c.feeders == 1 and f.interface == "if000000-iiii" and f.transposer == "tp000000-tttt" and f.interfaceSide == 4
  and f.machineSide == 5 and f.process == "centrifuge" and f.name == "Centrifuge 2", "feeder saved")
check(#c.machines == 1 and c.machines[1].address == "gm010000-aaaa", "skipped machine left out")
check(read(ROUTER_CFG):find("side = sides.north", 1, true), "file is readable Lua using sides names")
check(read(SHRC) == "echo hello\nprism\n", ".shrc starts prism, keeps other lines")

---------------------------------------------------------------- the router runs on it
M.items = { { name = "gregtech:gt.metaitem.01", damage = 5001, label = "Crushed Copper Ore", size = 64 },
            { name = "gregtech:gt.metaitem.01", damage = 5002, label = "Copper Ore", size = 64 } }
local realWrite = io.write
io.write = function() end
M.onPull = function(n) if n == 3 then return { "interrupted" } end end
H.run("prism.lua", ROUTER_CFG)
io.write = realWrite
M.onPull = nil
check(M.busHosts["eb111111-1111"][2][1] and M.busHosts["eb111111-1111"][2][1].label == "Crushed Copper Ore",
  "router routes crushed ore to the washer bus")
check(M.busHosts["eb222222-2222"][1][1] and M.busHosts["eb222222-2222"][1][1].label == "Copper Ore",
  "raw ore goes to the macerator by the catch-all rule")
check(#M.sent > 0 and M.sent[#M.sent].port == 4242, "router broadcasts on the chosen port")
check(stocker.slots[1] and stocker.slots[1].label == "Crushed Copper Ore", "router stocks crushed ore in the stocking bus")

local okMissing, errMissing = pcall(H.run, "prism.lua", home .. "/nothing.cfg")
check(not okMissing and tostring(errMissing):find("run prism-setup", 1, true), "router without a config says to run prism-setup")

---------------------------------------------------------------- router, re-run: defaults come from prism.cfg
out = wizard({
  "",                          -- router
  "",                          -- same processes: rules unchanged, no question
  "1",                         -- now 1 Capacity Card
  "", "",                      -- north: keep wash / Washer 1
  "smelt", "",                 -- south: a new process name
  "-",                         -- up: was crush, now removed
  "", "",                      -- stocking bus: keep
  "", "",                      -- feeder: keep
  "", "",                      -- gm01: keep
  "",                          -- gm02: skip
  "", "",                      -- wireless: keep 4242 / s3cret
  "",                          -- start on boot: already there
  "",                          -- save (default yes)
})
check(has("[1 2 4]") and has("Capacity Cards per bus: 0, 1 or 2 [2]"), "previous processes and cards are the defaults")
check(has("the 6 standard rules") and not has("instead of your current"), "unchanged rules need no question")
check(has("[wash]") and has("[Washer 1]") and has("[4242]") and has("[s3cret]"), "previous answers offered as defaults")
check(has('warning: no bus, stocker, interface or feeder for "crush"'), "warns when a routed process has nowhere to go")
check(has('warning: no rule sends anything to "smelt"'), "warns when a bus has a process no rule uses")
check(not has(".shrc will be"), ".shrc left alone when nothing changes")
c = loadCfg(ROUTER_CFG)
check(c.slotsPerBus == 5, "1 Capacity Card = 5 filter slots")
check(#c.buses == 2 and c.buses[1].process == "wash" and c.buses[2].process == "smelt", "kept one bus, added a custom process")
check(#c.rules == 6 and c.token == "s3cret" and #c.feeders == 1 and #c.machines == 1 and #c.stockers == 1
  and c.myNote == "keep me", "the rest kept")

---------------------------------------------------------------- no Database Upgrade: stocking buses still work
local db = M.proxies["db000000-aaaa"]
M.proxies["db000000-aaaa"] = nil
local cfgBefore = read(ROUTER_CFG)
out = wizard(answers({ "", "" }, 8, { "n" }))   -- 8 = stocking bus, machines, wireless, boot
check(has("only export buses and feeders need one") and not has("Capacity Cards"), "no database: bus and feeder steps skipped")
check(has("stocking bus st010000"), "no database: stocking buses still asked about")
check(read(ROUTER_CFG) == cfgBefore, "declined: nothing saved")
M.proxies["db000000-aaaa"] = db

---------------------------------------------------------------- other processes get other rules; cancelling saves nothing
local before, shrcBefore = read(ROUTER_CFG), read(SHRC)
out = wizard({ "", "3 5", "y" })       -- thermal + sift, then input ends (Ctrl+D)
check(has("^Purified Diamond Ore$") and has("-> sift"), "sifter gets gem ore rules")
check(out:find("%^Crushed %.%+ Ore%$%s+%-> thermal") ~= nil, "crushed ore falls back to the thermal centrifuge without a washer")
check(has("nothing saved") and read(ROUTER_CFG) == before, "Ctrl+D cancels without saving")
out = wizard(answers({}, 18, { "n" }))   -- every default, then decline
check(has("nothing saved") and read(ROUTER_CFG) == before and read(SHRC) == shrcBefore, "answering n at the end saves nothing")

---------------------------------------------------------------- several candidates; wireless off; boot off
M.proxies["me999999-cccc"] = { address = "me999999-cccc", type = "me_controller", getItemsInNetwork = function() return { n = 0 } end }
out = wizard(answers({ "", "", "2" }, 13, { "0", "n", "y" }))   -- 13 = cards, bus, stocker, feeder and machine prompts
check(has("1) me000000-cccc") and has("2) me999999-cccc"), "lists ME controllers to choose from")
c = loadCfg(ROUTER_CFG)
check(c.network == "me999999-cccc", "chosen controller saved")
check(c.modemPort == false and c.token == nil, "port 0 turns wireless off")
check(not has("On the control computer"), "no control screen instructions with wireless off")
check(read(SHRC) == "echo hello\n", "start on boot turned off removes the line")
out = wizard(answers({ "", "", "7", "1" }, 13, { "", "", "y" }))
check(has("enter a number") and has("[0]"), "re-asks on an invalid choice; wireless off is the new default")
check(loadCfg(ROUTER_CFG).network == "me000000-cccc", "valid answer after a bad one is used")
check(read(SHRC) == "echo hello\nprism\n", "start on boot added back")

---------------------------------------------------------------- an interface another network pulls from
-- Answer by prompt instead of position: fn(prompt) -> answer. Returns everything printed.
local function wizardBy(fn)
  local printed, last, n = {}, "", 0
  local oldPrint, oldWrite, oldRead = print, io.write, io.read
  print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    printed[#printed + 1] = table.concat(parts, "\t") .. "\n"
  end
  io.write = function(...) for _, s in ipairs({ ... }) do last = tostring(s); printed[#printed + 1] = last end end
  io.read = function() n = n + 1; assert(n < 200, "wizard looped"); return fn(last) end
  local ok, err = pcall(H.run, "prism-setup.lua")
  print, io.write, io.read = oldPrint, oldWrite, oldRead
  if not ok then error(err, 0) end
  return table.concat(printed)
end
local mainIface = M.iface("if222222-2222")
mainIface.config[1] = { name = "minecraft:sand", damage = 0, label = "Sand", want = 1 }   -- marker
local naming = false
out = wizardBy(function(prompt)
  if prompt:find("process for this interface", 1, true) then naming = true; return "export" end
  if naming and prompt:find("name (optional)", 1, true) then naming = false; return "Main net" end
  if prompt:find("Save?", 1, true) then return "y" end
  return ""
end)
check(has("which ME interface block") and has("Interfaces another network pulls from"),
  "a second interface block: the feeder asks which it uses, then the interfaces step")
check(has("interface if222222 - slot 1: Sand") and not has("interface if000000 - slot 1"),
  "offers the new interface with its marker, not the feeder's")
c = loadCfg(ROUTER_CFG)
check(#c.interfaces == 1 and c.interfaces[1].address == "if222222-2222" and c.interfaces[1].process == "export"
  and c.interfaces[1].name == "Main net", "interface saved")
check(c.feeders[1].interface == "if000000-iiii", "the feeder keeps its own interface")
check(has('warning: no rule sends anything to "export"'), "coverage counts interfaces as outputs")
out = wizardBy(function(prompt) if prompt:find("Save?", 1, true) then return "y" end return "" end)
check(not has("which ME interface block") and has("[export]") and has("[Main net]"),
  "re-run: the feeder no longer offers the output interface; its answers are the defaults")
check(#loadCfg(ROUTER_CFG).interfaces == 1, "interface kept")

---------------------------------------------------------------- control screen
out = wizard({ "2", "5555", "abc", "n", "", "y" })
check(has("Alerts") and has("3/3 Start on boot"), "control screen has its own short set of steps")
check(has("removing prism from .shrc"), "switching roles drops the router from .shrc")
c = loadCfg(CONTROL_CFG)
check(c.modemPort == 5555 and c.token == "abc" and c.beep == false and c.history == 60, "prism-control.cfg saved")
check(read(SHRC) == "echo hello\nprism-control\n", ".shrc starts prism-control")
check(read(ROUTER_CFG) ~= nil, "router config left alone")

out = wizard({ "2", "", "", "", "", "" })
check(has("[5555]") and has("[abc]") and has("alert appears? (y/n) [n]"), "re-run offers the screen's current settings")

-- prism-control uses the file: its first command goes out on its port with its token
local sentBefore = #M.sent
M.onPull = function() return { "interrupted" } end
local okRun, errRun = pcall(function() assert(loadfile(H.SRC .. "/prism-control.lua"))(CONTROL_CFG) end)
M.onPull = nil
check(okRun, "prism-control starts with the generated config: " .. tostring(errRun))
local mine = M.sent[sentBefore + 1]
check(mine and mine.port == 5555 and mine.data:find('"abc"', 1, true), "prism-control sends on its configured port with its token")
H.done()
