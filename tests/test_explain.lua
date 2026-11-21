-- test_explain.lua: why an item waits. The router's explain command for each reason (on an output and where,
-- below its batch, a batch item nothing can take, ranked below what the outputs hold, nothing serving its
-- process, unassigned, ignored, absent), and the screen's "Now:" line in ROUTE ITEM, asked again on each status.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check
local ser = M.serialization

local GT = "gregtech:gt.metaitem.01"
local function item(d, label, size) return { name = GT, damage = d, label = label, size = size } end
M.items = {
  item(5001, "Crushed Iron Ore", 500), item(5002, "Crushed Tin Ore", 100),
  item(2834, "End Stone Dust", 25), item(2835, "Netherrack Dust", 40),
  item(2826, "Cinnabar Dust", 40), item(6001, "Purified Ruby Ore", 12),
  item(9001, "Weird Thing", 3), item(2299, "Stone Dust", 900),
}
M.stocker("st111111-1111")

local cfg = H.config("ex", [[
return { modemPort = 4242, slotsPerBus = 1,
  buses = { { address = "eb11", side = sides.north, process = "wash", name = "Washer bus" },
            { address = "eb11", side = sides.south, process = "crush", name = "Macerator bus" } },
  stockers = { { address = "st11", process = "centrifuge", name = "Centrifuge" } },
  rules = { { pattern = "^Crushed .+ Ore$", process = "wash" },
            { pattern = "^End Stone Dust$", process = "centrifuge", batch = 36 },
            { pattern = "^Netherrack Dust$", process = "centrifuge", batch = 36 },
            { pattern = "^Cinnabar Dust$", process = "crush", batch = 2 },
            { pattern = "^Purified .+ Ore$", process = "sift" },
            { pattern = "^Stone Dust$", process = "ignore" } } }
]])

local function cmd(t) return { "modem_message", "x", "gui", 4242, 2, ser.serialize(t) } end
local asks = { 5001, 5002, 2834, 2835, 2826, 6001, 9001, 2299, 4444 }
M.onPull = function(n)
  if n <= #asks then return cmd({ cmd = "explain", key = GT .. ":" .. asks[n], req = n }) end
  return { "interrupted" }
end
H.run("prism.lua", cfg)
local said = {}
for _, s in ipairs(M.sent) do
  local m = ser.unserialize(s.data)
  if m.type == "router-explain" then said[tonumber(m.key:match("(%d+)$"))] = m end
end
local function says(d, text, level)
  local m = said[d]
  return m and m.text:find(text, 1, true) and m.level == level
end
check(says(5001, "On Washer bus (slot 1).", "ok"), "on an output: which one and the slot")
check(says(5002, "Rank 2 of 2 in wash; its outputs hold the top 1.", "dim"), "ranked below what the outputs hold")
check(says(2834, "Waits for a full batch: 25 of 36, needs 11 more.", "warn"), "below its batch: how many more")
check(says(2835, "Waits for a full batch: 40 of 36", "warn") == nil and said[2835].text:find("Rank 1", 1, true) == nil
  and said[2835].text:find("On Centrifuge (slot 1)", 1, true), "a full batch on a stocker is on it")
check(says(2826, "Needs batches of 2, and crush has no feeder or stocker to take them.", "warn"),
  "a batch item with only export buses for its process")
check(says(6001, "Nothing serves sift", "warn"), "nothing serves its process")
check(says(9001, "Unassigned: no rule or override matches its name.", "warn"), "unassigned")
check(says(2299, "Ignored", "dim"), "ignored")
check(says(4444, "Not in the network now.", "dim"), "absent")
check(said[5001].req == 1, "the reply carries the request number")

------------------------------------------------ the screen: the Now: line
local status
for _, s in ipairs(M.sent) do
  local m = ser.unserialize(s.data)
  if m.type == "router-status" then status = m end
end
M.sent = {}
local PT = M.H - 14
local function tap(text, minY)
  local x, y = M.find(text, minY)
  assert(x, "can't find '" .. text .. "' on screen")
  return { "touch", "screen", x + 1, y, 0, "Aaron" }
end
local function msg(t) return { "modem_message", "x", "router-addr", 4242, 4, ser.serialize(t) } end
local function lastSent() return ser.unserialize(M.sent[#M.sent].data) end
local seen = {}
local steps = {
  function() return msg(status) end,
  function() return tap("Weird Thing", 5) end,
  function()
    local c = lastSent()
    seen.asked = c.cmd == "explain" and c.key == GT .. ":9001"
    seen.waiting = M.find("Now: asking the router ...", PT) ~= nil
    seen.req = c.req
    return msg({ type = "router-explain", req = c.req, key = c.key, text = "Unassigned: no rule or override matches its name.",
      level = "warn" })
  end,
  function()
    local x, y = M.find("Now: Unassigned: no rule or override matches its name.", PT)
    seen.shown = x and M.fgb[y][x + 6] == 0xffd24d
    H.screen("explain-unassigned")
    local s = ser.unserialize(ser.serialize(status))
    s.cycles = s.cycles + 1
    return msg(s)
  end,
  function()
    local c = lastSent()
    seen.again = c.cmd == "explain" and c.req == seen.req + 1
    return msg({ type = "router-explain", req = seen.req, key = c.key, text = "an old answer", level = "ok" })
  end,
  function()
    seen.stale = M.find("an old answer", PT) == nil
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
M.pulls = 0
H.run("prism-control.lua")
check(seen.asked and seen.waiting, "tapping an item asks the router, and the panel says so")
check(seen.shown, "the answer shows as the Now: line, coloured by its level")
check(seen.again, "a new status asks again")
check(seen.stale, "an answer to an older question is ignored")

H.done()
