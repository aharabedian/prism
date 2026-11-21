-- test_who.lua: who changed it. The screen sends the player who tapped with every command; an override keeps who
-- made it and when (router-overrides carries by and at), and OVERRIDES shows "Aaron · 2h" (cfg for prism.cfg's).
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check
local ser = M.serialization
local computer = require("computer")

local GT = "gregtech:gt.metaitem.01"
M.items = { { name = GT, damage = 5085, label = "Crushed Platinum Ore", size = 96 }, { name = GT, damage = 2299, label = "Stone Dust", size = 900 } }
M.stocker("st111111-1111")
local cfg = H.config("who", [[
return { modemPort = 4242, stockers = { { address = "st11", process = "chembath", name = "Bath" } },
  overrides = { [ "gregtech:gt.metaitem.01:2299" ] = { process = "ignore" } },
  rules = { { pattern = "^Crushed", process = "wash" } } }
]])
local function cmd(t) return { "modem_message", "x", "gui", 4242, 2, ser.serialize(t) } end
local asked = false
M.onPull = function(n)
  if n == 1 then return cmd({ cmd = "assign", key = GT .. ":5085", process = "chembath", fallback = "wash", player = "Sam" }) end
  if computer.uptime() >= 7300 then
    if asked then return { "interrupted" } end
    asked = true
    return cmd({ cmd = "overrides" })
  end
end
H.run("prism.lua", cfg)
local ov
for _, s in ipairs(M.sent) do
  local m = ser.unserialize(s.data)
  if m.type == "router-overrides" then ov = m end
end
local byKey = {}
for _, r in ipairs(ov.list) do byKey[r.key] = r end
local plat = byKey[GT .. ":5085"]
check(plat.by == "Sam" and plat.at and ov.now - plat.at >= 7200, "an override keeps who made it and when")
check(byKey[GT .. ":2299"].by == nil and byKey[GT .. ":2299"].source == "cfg", "prism.cfg's overrides have no player")
check(H.readTable(H.TMP .. "/who-overrides.cfg")[GT .. ":5085"].by == "Sam", "kept in prism-overrides.cfg")

------------------------------------------------ the screen
M.sent = {}
local RX = math.floor(M.W * 0.56) + 3
local function tap(text, minY, minX, who)
  local x, y = M.find(text, minY, minX)
  assert(x, "can't find '" .. text .. "' on screen")
  return { "touch", "screen", x + 1, y, 0, who or "Aaron" }
end
local function msg(t) return { "modem_message", "x", "router-addr", 4242, 4, ser.serialize(t) } end
local function lastSent() return ser.unserialize(M.sent[#M.sent].data) end
local seen = {}
local steps = {
  function() return msg({ type = "router-status", cycles = 1, interval = 5, processes = {}, buses = {}, feeders = {}, machines = {},
    unassigned = {}, unassignedCount = 0, catalogCount = 2, knownProcesses = { "chembath", "wash" }, alerts = {} }) end,
  function() return tap(" OVERRIDES ", 3, RX, "Sam") end,
  function()
    seen.player = lastSent().cmd == "overrides" and lastSent().player == "Sam"
    return msg(ov)
  end,
  function()
    H.screen("who-overrides")
    local _, y = M.find("Crushed Platinum Ore", 5, RX)
    seen.by = y and M.row(y):find("Sam · 2h", 1, true) ~= nil
    local _, sy = M.find("Stone Dust", 5, RX)
    seen.cfg = sy and M.row(sy):find("cfg", 1, true) ~= nil
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
check(seen.player, "every command carries the player who tapped")
check(seen.by, "OVERRIDES: who made it and how long ago")
check(seen.cfg, "prism.cfg's say cfg")
H.done()
