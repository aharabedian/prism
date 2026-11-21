-- test_history.lua: 24 hours per process. The router records each process's backlog and items out per 10
-- minutes in prism-history.cfg, kept across a restart, and the history command sends them; the process page's
-- 24 H shows them (backlog chart, an "out" row, the hours), 5 MIN the screen's own samples.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check
local ser = M.serialization
local computer = require("computer")

local GT = "gregtech:gt.metaitem.01"
local iron = { name = GT, damage = 5001, label = "Crushed Iron Ore", size = 9000 }
M.items = { iron }
M.stocker("st111111-1111")
local cfg = H.config("hi", [[
return { modemPort = 4242, stuckAfter = false, stallAfter = 3600,
  stockers = { { address = "st11", process = "wash", name = "Washer" } },
  rules = { { pattern = "^Crushed", process = "wash" } } }
]])
local function cmd(t) return { "modem_message", "x", "gui", 4242, 2, ser.serialize(t) } end
local last = -1
M.onPull = function()
  local t = computer.uptime()
  if t >= 1300 then return { "interrupted" } end
  if math.floor(t / 5) ~= last then last = math.floor(t / 5); if t > 0 then iron.size = iron.size - 5 end end
end
H.run("prism.lua", cfg)
check(H.readTable(H.TMP .. "/hi-history.cfg").wash ~= nil, "prism-history.cfg keeps wash's slots")

M.sent = {}
local pulls = 0
M.onPull = function()
  pulls = pulls + 1
  if pulls == 2 then return cmd({ cmd = "history", process = "wash", req = 4 }) end
  if pulls >= 3 then return { "interrupted" } end
end
H.run("prism.lua", cfg)
local hist
for _, s in ipairs(M.sent) do
  local m = ser.unserialize(s.data)
  if m.type == "router-history" then hist = m end
end
local filled, outs = 0, 0
for i = 1, 144 do
  if hist.backlog[i] then filled = filled + 1 end
  if hist.out[i] then outs = outs + hist.out[i] end
end
check(hist.req == 4 and #hist.backlog == 144 and hist.slot == 600, "history: 144 slots of 10 minutes")
check(filled >= 3 and hist.backlog[144] and hist.backlog[144] < 9000, "after a restart: the slots recorded before, and now")
check(outs >= 5 * 250, "items out per slot add up to what left (" .. outs .. ")")

------------------------------------------------ the screen
local status
for _, s in ipairs(M.sent) do
  local m = ser.unserialize(s.data)
  if m.type == "router-status" then status = m end
end
M.sent = {}
local RX = math.floor(M.W * 0.56) + 3
local function msg(t) return { "modem_message", "x", "router-addr", 4242, 4, ser.serialize(t) } end
local function lastSent() return ser.unserialize(M.sent[#M.sent].data) end
local function tap(text, minY, minX)
  local x, y = M.find(text, minY, minX)
  assert(x, "can't find '" .. text .. "' on screen")
  return { "touch", "screen", x + 1, y, 0, "Aaron" }
end
local seen = {}
local steps = {
  function() return msg(status) end,
  function() return tap("wash", 5) end,
  function()
    seen.five = M.find("last ", 9, RX) and M.find("one point per scan", 9, RX) ~= nil
    H.screen("history-5m")
    return tap(" 24 H ", 9, RX)
  end,
  function()
    local c = lastSent()
    seen.asked = c.cmd == "history" and c.process == "wash"
    hist.req = c.req
    return msg(hist)
  end,
  function()
    H.screen("history-24h")
    seen.day = M.find("last 24 hours, one point per 10 minutes", 9, RX) ~= nil and M.find("-24h", 9, RX) ~= nil
      and M.find("-12h", 9, RX) ~= nil and M.find("out", 16, RX) ~= nil
    return tap(" 5 MIN ", 9, RX)
  end,
  function()
    seen.back = M.find("one point per scan", 9, RX) ~= nil
    return { "interrupted" }
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
check(seen.five, "the page starts on 5 MIN, the screen's own samples")
check(seen.asked, "24 H asks the router for its 24 hours")
check(seen.day, "and charts them, with items out under the backlog")
check(seen.back, "5 MIN goes back")

H.done()
