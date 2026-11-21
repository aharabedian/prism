-- test_stuck.lua: stuck items. An item on one of its process's outputs that hasn't gone down for stuckAfter
-- seconds while the process used other items raises a warn; not for items the outputs don't hold, not while the
-- process is held, and not when stuckAfter is false. It clears when the item goes down.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check
local ser = M.serialization
local computer = require("computer")

local GT = "gregtech:gt.metaitem.01"
local iron = { name = GT, damage = 6032, label = "Purified Iron Ore", size = 5000 }
local tin = { name = GT, damage = 6057, label = "Purified Tin Ore", size = 390 }
local lead = { name = GT, damage = 6089, label = "Purified Lead Ore", size = 300 }
M.items = { iron, tin, lead }
local stocker = M.stocker("st111111-1111")
local function run(stuckAfter, stopAt, hook)
  M.sent = {}
  local cfg = H.config("sk", ([[
return { modemPort = 4242, stuckAfter = %s, stallAfter = 600,
  buses = { { address = "eb11", side = sides.north, process = "thermal", name = "Thermal bus" } },
  slotsPerBus = 2,
  rules = { { pattern = "^Purified .+ Ore$", process = "thermal" } } }
]]):format(stuckAfter))
  local last = -1
  M.onPull = function()
    local t = computer.uptime()
    if t >= stopAt then return { "interrupted" } end
    if math.floor(t / 5) ~= last then
      last = math.floor(t / 5)
      if t > 0 then iron.size = iron.size - 10 end       -- thermal works on iron; tin sits on the bus
    end
    if hook then return hook(t) end
  end
  H.run("prism.lua", cfg)
  local st
  for _, s in ipairs(M.sent) do
    local m = ser.unserialize(s.data)
    if m.type == "router-status" then st = m end
  end
  local ids = {}
  for _, a in ipairs(st.alerts) do ids[a.id] = a end
  return ids, st
end
local _ = stocker

local ids = run(60, 100)
local a = ids["stuck:" .. GT .. ":6057"]
check(a and a.level == "warn" and a.text:find("^Purified Tin Ore stuck for 1m %(thermal%)"), "tin on the bus, not going down while iron does: stuck")
check(ids["stuck:" .. GT .. ":6032"] == nil, "iron is going down: not stuck")
check(ids["stuck:" .. GT .. ":6089"] == nil, "lead isn't on the bus (rank 3 of 2 slots): waiting its turn, not stuck")

ids = run(60, 50)
check(ids["stuck:" .. GT .. ":6057"] == nil, "before stuckAfter: nothing")

ids = run("false", 100)
check(next(ids) == nil, "stuckAfter = false: off")

local moved = false
ids = run(60, 140, function(t)
  if t >= 90 and not moved then moved = true; tin.size = tin.size - 64 end
end)
check(ids["stuck:" .. GT .. ":6057"] == nil, "it clears once tin goes down")

H.done()
