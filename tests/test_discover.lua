-- test_discover.lua: discover lists networks, databases, buses (with marker items), interfaces, transposers and GT machines.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check

-- a marker item in one bus, an interface, a transposer and two machines
M.busHosts["eb111111-1111"][2][1] = { name = "minecraft:cobblestone", damage = 0.0, label = "Cobblestone" }
M.proxies["if000000-iiii"] = { address = "if000000-iiii", type = "me_interface" }
M.proxies["tp000000-tttt"] = { address = "tp000000-tttt", type = "transposer",
  getInventorySize = function(s) if s == 4 then return 9 elseif s == 5 then return 3 end return nil, "no inventory" end,
  getInventoryName = function(s) return s == 4 and "appliedenergistics2:tile.BlockInterface" or "gregtech:gt.blockmachines" end }
M.machine("gm010000-aaaa", { isMachineActive = true, isWorkAllowed = true })
M.proxies["gm010000-aaaa"].getCoordinates = function() return 120, 64, -340 end
M.machine("gm020000-bbbb", { isMachineActive = false, isWorkAllowed = false })

local lines = {}
local realPrint = print
print = function(...)                                    -- capture discover's output
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  lines[#lines + 1] = table.concat(parts, "\t")
end
H.run("prism-discover.lua")
print = realPrint
local out = table.concat(lines, "\n")
local function has(s) return out:find(s, 1, true) ~= nil end

check(has("me_controller  me000000-cccc"), "lists the ME controller")
check(has("db000000-aaaa"), "lists the database")
check(has('{ address = "eb111111", side = sides.north, process = "?" }, -- slot 1: Cobblestone'), "bus line shows its marker item")
check(has('{ address = "eb111111", side = sides.south, process = "?" }, -- slot 1: (empty)'), "empty bus shown")
check(has('{ address = "eb222222", side = sides.up, process = "?" }'), "bus on another cable block")
check(not has("sides.down"), "sides without a bus are skipped")
check(has("if000000-iiii"), "lists ME interfaces")
check(has("sides.west   appliedenergistics2:tile.BlockInterface") and has("9 slots"), "transposer shows what each side touches")
check(has('{ address = "gm010000", process = "?", name = "?" }, -- working  at 120 64 -340'), "machine with state and coordinates")
check(has('{ address = "gm020000", process = "?", name = "?" }, -- disabled'), "soft-malleted machine shows disabled (false is not nil)")
H.done()
