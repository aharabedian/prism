-- test_example_config.lua: the shipped config/prism.example.cfg loads and routes with its default rules.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check
local ser = M.serialization

local src = assert(io.open(H.ROOT .. "/config/prism.example.cfg")):read("*a")
local cfg = H.config("example", src)   -- copied to the temp dir so data files land there

local GT = "gregtech:gt.metaitem.01"
M.items = {
  { name = GT, damage = 5035, label = "Crushed Copper Ore", size = 10 },
  { name = GT, damage = 6035, label = "Purified Copper Ore", size = 5 },
  { name = GT, damage = 7035, label = "Impure Pile of Copper Dust", size = 7 },
  { name = "gregtech:gt.blockores", damage = 35, label = "Copper Ore", size = 3 },
  { name = GT, damage = 2035, label = "Copper Dust", size = 64 },
}
M.onPull = function(n) if n >= 3 then return { "interrupted" } end end
local logged = {}
local realWrite = io.write
io.write = function(...) for _, s in ipairs({ ... }) do logged[#logged + 1] = tostring(s) end end
local ok, err = pcall(H.run, "prism.lua", cfg)
io.write = realWrite
local log = table.concat(logged)

check(ok, "router starts with the example config " .. tostring(err))
check(log:find("0 bus%(es%), 0 stocker%(s%), 0 interface%(s%), 0 feeder%(s%), 0 machine%(s%)"), "no hardware configured in the example")
local st
for _, s in ipairs(M.sent) do local m = ser.unserialize(s.data); if m.type == "router-status" then st = m end end
check(st, "broadcasts status on the example's modemPort")
check(st.processes.wash and st.processes.crush and st.processes.centrifuge, "default rules sort ores into wash / crush / centrifuge")
check(st.processes.crush.types == 2, "purified ore and raw ore block both go to crush")
check(st.unassignedCount == 1 and st.unassigned[1].label == "Copper Dust", "finished dust is unassigned")
check(log:find("no bus, stocker, interface or feeder is configured"), "warns that processes have nowhere to go")
H.done()
