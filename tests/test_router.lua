-- test_router.lua: Export bus routing: filter selection, stable slots, clearing, remote assign, status broadcasts.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check

local GT = "gregtech:gt.metaitem.01"
local function item(d, label, size) return { name = GT, damage = d, label = label, size = size } end

-- 12 crushed ores (more than 9 slots), 2 impure dusts, 1 raw ore block, 1 unknown, 1 override target
M.items = {}
for i = 1, 12 do M.items[#M.items + 1] = item(5000 + i, "Crushed Ore" .. i .. " Ore", i * 10) end
for i = 1, 12 do M.items[i].label = "Crushed Metal" .. i .. " Ore" end
M.items[#M.items + 1] = item(6001, "Impure Pile of Copper Dust", 50)
M.items[#M.items + 1] = item(6002, "Impure Pile of Tin Dust", 20)
M.items[#M.items + 1] = { name = "gregtech:gt.blockores", damage = 35, label = "Copper Ore", size = 7 }
M.items[#M.items + 1] = item(9999, "Mystery Thing", 3)
M.items[#M.items + 1] = item(7001, "Copper Dust", 100) -- unassigned (no ignore rule active)

-- pre-existing junk filter in washer bus slot 4 (stale) should be replaced/cleared
M.busHosts["eb111111-1111"][2][4] = { name = "minecraft:dirt", damage = 0.0, label = "Dirt" }

-- write a config for the test
local cfgPath = H.TMP .. "/test-prism.cfg"
local f = assert(io.open(cfgPath, "w"))
f:write([[
return {
  interval = 5, slotsPerBus = 9, modemPort = 4242, verbose = false, defaultPriority = 10,
  buses = {
    { address = "eb11", side = sides.north, process = "wash",       name = "Washer 1" },
    { address = "eb11", side = sides.south, process = "centrifuge", name = "Centrifuge 1" },
    { address = "eb22", side = sides.up,    process = "wash",       name = "Washer 2" },
  },
  rules = {
    { pattern = "^Crushed .+ Ore$",           process = "wash",       priority = 10 },
    { pattern = "^Impure Pile of .+ Dust$",   process = "centrifuge", priority = 10 },
    { pattern = "Ore$",                       process = "crush",      priority = 5  },
  },
  overrides = { ["gregtech:gt.metaitem.01:5001"] = { process = "wash", priority = 99 } },
}
]])
f:close()
os.remove(H.TMP .. "/test-prism-overrides.cfg")

local function slotKeys(addr, side)
  local out = {}
  for s = 1, 9 do local st = M.busHosts[addr][side][s]; out[s] = st and (st.name .. ":" .. math.floor(st.damage)) or false end
  return out
end
local function setOf(list) local s = {}; for _, k in ipairs(list) do if k then s[k] = true end end; return s end

-- Script: cycle 1 runs before pull 1. After pull 1 (cycle 2 boundary) we check state, then mutate.
local checkpoints = {}
M.onPull = function(n)
  if n == 1 then
    -- after first cycle
    checkpoints[1] = { washer1 = slotKeys("eb111111-1111", 2), washer2 = slotKeys("eb222222-2222", 1),
                       cent = slotKeys("eb111111-1111", 3), sets = M.setCalls }
    return nil
  elseif n == 2 then
    -- second cycle happened (pull 1 timed out → cycle → pull 2). nothing changed → no new writes
    checkpoints[2] = { sets = M.setCalls }
    -- now: deplete the top washer item and remote-assign the mystery item
    for i, it in ipairs(M.items) do if it.damage == 5001 then table.remove(M.items, i); break end end
    local cmd = M.serialization.serialize({ cmd = "assign", key = GT .. ":9999", process = "centrifuge", priority = 50 })
    return { "modem_message", "localaddr", "remote-gui", 4242, 3, cmd }
  elseif n == 3 then
    checkpoints[3] = { washer1 = slotKeys("eb111111-1111", 2), cent = slotKeys("eb111111-1111", 3), sets = M.setCalls }
    -- ask for status
    return { "modem_message", "localaddr", "remote-gui", 4242, 3, M.serialization.serialize({ cmd = "status" }) }
  elseif n == 4 then
    -- empty the centrifuge queue entirely → should clear its slots
    for i = #M.items, 1, -1 do local d = M.items[i].damage; if d == 6001 or d == 6002 or d == 9999 then table.remove(M.items, i) end end
    return nil
  elseif n == 5 then
    checkpoints[5] = { cent = slotKeys("eb111111-1111", 3) }
    return { "interrupted" }
  end
end

local chunk = assert(loadfile(H.SRC .. "/prism.lua"))
chunk(cfgPath)

-- ---------- assertions
local c1 = checkpoints[1]
local expectedTop9 = { GT .. ":5001" } -- override prio 99 first
for i = 12, 5, -1 do expectedTop9[#expectedTop9 + 1] = GT .. ":" .. (5000 + i) end -- then by size desc
check(#expectedTop9 == 9, "expected list has 9")
local w1 = setOf(c1.washer1)
for _, k in ipairs(expectedTop9) do check(w1[k], "washer1 has " .. k) end
check(not w1["minecraft:dirt:0"], "stale dirt filter replaced")
check(c1.washer1[1] == GT .. ":5001", "highest priority item lands in slot 1")
local w2 = setOf(c1.washer2)
for _, k in ipairs(expectedTop9) do check(w2[k], "washer2 has " .. k) end
local cs = setOf(c1.cent)
check(cs[GT .. ":6001"] and cs[GT .. ":6002"], "centrifuge has both impure dusts")
local cnt = 0; for _ in pairs(cs) do cnt = cnt + 1 end
check(cnt == 2, "centrifuge only has 2 filters")

check(checkpoints[2].sets == c1.sets, "steady state: no writes on unchanged network (" .. c1.sets .. " writes total)")

local c3 = checkpoints[3]
local w1b = setOf(c3.washer1)
check(not w1b[GT .. ":5001"], "depleted item removed from washer")
check(w1b[GT .. ":5004"], "next item (5004) promoted into washer")
local moved = 0
for s = 1, 9 do if c1.washer1[s] ~= c3.washer1[s] then moved = moved + 1 end end
check(moved == 1, "only one washer slot rewritten (stable slots), moved=" .. moved)
check(setOf(c3.cent)[GT .. ":9999"], "remote assign routed mystery item to centrifuge")
check(c3.cent[1] ~= nil, "centrifuge slots populated")

local ov = io.open(H.TMP .. "/test-prism-overrides.cfg"):read("*a")
check(ov:find("9999") ~= nil, "override persisted to file")

check(#M.sent >= 3, "status broadcasts sent (" .. #M.sent .. ")")
local direct
for _, s in ipairs(M.sent) do if s.to == "remote-gui" then direct = s end end
check(direct ~= nil, "status reply sent directly to requester")
local st = M.serialization.unserialize(M.sent[1].data)
check(st.type == "router-status", "status has type")
check(st.processes.wash.types == 12 and st.processes.wash.buses == 2, "status wash backlog/buses")
check(st.processes.crush and st.processes.crush.buses == 0, "crush has items but no bus (flagged)")
check(st.unassignedCount == 2, "two unassigned items reported in first status (mystery + copper dust)")
check(st.unassigned[1].label == "Copper Dust", "unassigned sorted by size")

local c5 = checkpoints[5]
local any = false; for s = 1, 9 do if c5.cent[s] then any = true end end
check(not any, "centrifuge filters cleared when queue empties")
H.done()
