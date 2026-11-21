-- test_routers.lua: several routers on one screen. router-status carries the router's name (the new `name`
-- setting); the screen shows the first router heard, lists every router in the header with the others' alert
-- counts, and tapping one shows its cards and sends commands to it. Replies from a router not shown are ignored.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check
local ser = M.serialization

-- the router sends its name
M.items = { { name = "gregtech:gt.metaitem.01", damage = 1, label = "Nether Gold Ore", size = 512 } }
M.stocker("st111111-1111")
local cfg = H.config("rt", [[
return { modemPort = 4242, name = "nether", stockers = { { address = "st11", process = "crush", name = "Nether Stocker" } },
  rules = { { pattern = "Ore$", process = "crush" } } }
]])
M.onPull = function(n) if n >= 2 then return { "interrupted" } end end
H.run("prism.lua", cfg)
local nether
for _, s in ipairs(M.sent) do
  local m = ser.unserialize(s.data)
  if m.type == "router-status" then nether = m end
end
check(nether.name == "nether", "router-status carries the router's name")

local ore = { type = "router-status", name = "ore-line", cycles = 5, interval = 5, processes = { wash = { items = 8959, types = 7, buses = 2 } },
  buses = {}, feeders = {}, machines = {}, unassigned = {}, unassignedCount = 0, catalogCount = 9, knownProcesses = { "wash" },
  alerts = { { id = "idle:Washer B", level = "warn", text = "Washer B idle 45s with work waiting" },
             { id = "stall:wash", level = "bad", text = "wash stalled" } } }

------------------------------------------------ the screen
M.sent = {}
local function from(addr, t) return { "modem_message", "x", addr, 4242, 4, ser.serialize(t) } end
local function lastSent() return M.sent[#M.sent] end
local function tap(text, minY, minX)
  local x, y = M.find(text, minY, minX)
  assert(x, "can't find '" .. text .. "' on screen")
  return { "touch", "screen", x + 1, y, 0, "Aaron" }
end
local seen = {}
local steps = {
  function() return from("ore-addr", ore) end,
  function()
    seen.single = M.find("ROUTER", 1) == nil
    return from("nether-addr", nether)
  end,
  function()
    H.screen("routers")
    seen.header = M.find("ROUTER", 1) and M.find(" ore-line ", 1) and M.find(" nether ", 1)
    seen.first = M.find("wash", 5) ~= nil and M.find("crush", 5) == nil
    return tap(" RULES ", 3)
  end,
  function()
    seen.toFirst = lastSent().to == "ore-addr"
    return tap(" nether ", 1)
  end,
  function()
    seen.switched = M.find("crush", 5) ~= nil and M.find("wash", 5) == nil
    local x = M.find(" ore-line ⚠2 ", 1)
    seen.others = x ~= nil and M.fgb[1][x + 1] == require("prism.control.ui").C.warn
    seen.toSecond = lastSent().to == "nether-addr"
    return from("ore-addr", { type = "router-rules", source = "config", list = { { index = 1, pattern = "^ORE ONLY$", process = "wash", used = 0 } } })
  end,
  function()
    seen.ignored = M.find("^ORE ONLY$", 5) == nil
    local s = ser.unserialize(ser.serialize(ore))
    s.cycles = 6
    s.processes.wash.items = 1
    return from("ore-addr", s)
  end,
  function()
    seen.stays = M.find("crush", 5) ~= nil and M.find("wash", 5) == nil
    return tap(" QUIT ", M.H)
  end,
}
local n = 0
M.onPull = function()
  n = n + 1
  local f = steps[n]
  if f then return f() end
  return { "interrupted" }
end
H.run("prism-control.lua")
check(seen.single, "one router: no router buttons")
check(seen.header, "two routers: a button for each in the header")
check(seen.first and seen.toFirst, "the first heard is shown, and commands go to it")
check(seen.switched and seen.toSecond, "tapping the other shows its cards and sends commands to it")
check(seen.others, "the router not shown says how many alerts it has, in yellow")
check(seen.ignored and seen.stays, "replies and statuses from the router not shown don't change the screen")

H.done()
