-- test_log.lua: the event log. The router keeps alerts starting and ending (how long they lasted), sharing,
-- holds, edits made on a screen (with the player) and its own starts and stops in prism-log.cfg, with real times
-- from the clock file, across restarts; the log command pages it newest first, all or alerts or changes.
-- The screen's LOG tab: clock times with timezone set, "ago" without, the filters, and the help panel.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check
local ser = M.serialization
local computer = require("computer")

local GT = "gregtech:gt.metaitem.01"
M.items = { { name = GT, damage = 5001, label = "Crushed Iron Ore", size = 500 }, { name = GT, damage = 9001, label = "Odd Dust", size = 5 } }
M.stocker("st111111-1111")
local washer = M.machine("ow01", { isMachineActive = false, isWorkAllowed = true, getEUStored = 9000, getEUMaxStored = 10000 })
local cfg = H.config("lg", [[
return { modemPort = 4242, idleAlert = 20, stallAfter = 600, stuckAfter = false,
  stockers = { { address = "st11", process = "wash", name = "Washer" } },
  machines = { { address = "ow01", process = "wash", name = "Washer A" } },
  rules = { { pattern = "^Crushed", process = "wash" } } }
]])
local function cmd(t) return { "modem_message", "x", "gui", 4242, 2, ser.serialize(t) } end
local marks = {}
M.onPull = function()
  local t = computer.uptime()
  if t >= 40 and not marks.working then marks.working = true; washer.isMachineActive = true end
  if t >= 60 and not marks.assign then
    marks.assign = true
    return cmd({ cmd = "assign", key = GT .. ":9001", process = "wash", label = "Odd Dust", player = "Aaron" })
  end
  if t >= 70 and not marks.hold then marks.hold = true; return cmd({ cmd = "hold", process = "wash", on = true, player = "Sam" }) end
  if t >= 80 then return { "interrupted" } end
end
H.run("prism.lua", cfg)
local saved = H.readTable(H.TMP .. "/lg-log.cfg")
local kinds = {}
for _, e in ipairs(saved) do kinds[#kinds + 1] = e.kind end
check(table.concat(kinds, " ") == "start alert ended edit hold stop", "prism-log.cfg: start, alert, ended, edit, hold, stop ("
  .. table.concat(kinds, " ") .. ")")
local alert, ended, edit, hold = saved[2], saved[3], saved[4], saved[5]
check(alert.text:find("Washer A idle", 1, true) and alert.level == "warn", "the alert, with its text and level")
check(ended.text == alert.text and ended.lasted and ended.lasted >= 10 and ended.lasted <= 25, "its end, and how long it lasted")
check(edit.text == "Odd Dust → wash" and edit.player == "Aaron", "an edit, and who made it")
check(hold.kind == "hold" and hold.text == "wash held: outputs cleared" and hold.player == "Sam", "a hold")
check(saved[1].at >= M.epoch and saved[1].at < M.epoch + 5 and alert.at > saved[1].at, "real times, from the clock file")

------------------------------------------------ restart: the log is kept; paging and filters
M.sent = {}
local pulls = 0
M.onPull = function()
  pulls = pulls + 1
  if pulls == 2 then return cmd({ cmd = "log", req = 3 }) end
  if pulls == 3 then return cmd({ cmd = "log", req = 4, filter = "alerts" }) end
  if pulls == 4 then return cmd({ cmd = "log", req = 5, filter = "changes" }) end
  if pulls == 5 then return { "interrupted" } end
end
H.run("prism.lua", cfg)
local logs = {}
local status
for _, s in ipairs(M.sent) do
  local m = ser.unserialize(s.data)
  if m.type == "router-log" then logs[m.req] = m end
  if m.type == "router-status" then status = m end
end
local all = logs[3]
check(all.total == 7 and all.list[1].kind == "start" and all.list[2].kind == "stop" and all.list[7].kind == "start",
  "after a restart: the old entries, and the new start first")
check(all.real == true and all.now >= M.epoch, "the reply says the router's time is real")
check(logs[4].total == 2 and logs[4].list[1].kind == "ended" and logs[4].list[2].kind == "alert", "alerts: alerts and their ends")
check(logs[5].total == 5, "changes: the rest")
check(status.events >= 1, "router-status counts the events added")

------------------------------------------------ the screen
local RX = math.floor(M.W * 0.56) + 3
local function tap(text, minY, minX)
  local x, y = M.find(text, minY, minX)
  assert(x, "can't find '" .. text .. "' on screen")
  return { "touch", "screen", x + 1, y, 0, "Aaron" }
end
local function msg(t) return { "modem_message", "x", "router-addr", 4242, 4, ser.serialize(t) } end
local function lastSent() return ser.unserialize(M.sent[#M.sent].data) end
local function screen(tz)
  M.sent = {}
  local path = H.TMP .. "/lg-control.cfg"
  local f = assert(io.open(path, "w"))
  f:write(tz and ("return { timezone = " .. tz .. " }") or "return {}")
  f:close()
  local seen = {}
  local steps = {
    function() return msg(status) end,
    function() return tap(" LOG ", 3, RX) end,
    function()
      local c = lastSent()
      seen.asked = c.cmd == "log" and c.offset == 0
      local reply = ser.unserialize(ser.serialize(all))
      reply.req = c.req
      return msg(reply)
    end,
    function()
      H.screen(tz and "log-clock" or "log-ago")
      seen.screen = true
      local _, y = M.find("Odd Dust → wash", 5, RX)
      seen.who = y and M.row(y):find("Aaron", 1, true) ~= nil
      local _, ey = M.find("Washer A idle", 5, RX)
      seen.lasted = ey and M.find("✓", 5, RX) ~= nil
      seen.help = M.find("What the router did and saw", M.H - 14, RX) ~= nil
      seen.rows = {}
      for yy = 5, 12 do seen.rows[#seen.rows + 1] = M.row(yy) end
      return tap(" ALERTS ", M.H - 16, RX)
    end,
    function()
      local c = lastSent()
      seen.filter = c.cmd == "log" and c.filter == "alerts"
      return tap(" QUIT ", M.H)
    end,
  }
  local n = 0
  M.onPull = function()
    n = n + 1
    local f2 = steps[n]
    if f2 then return f2() end
    return { "interrupted" }
  end
  H.run("prism-control.lua", path)
  return seen
end
local seen = screen(0)
local rows = table.concat(seen.rows, "\n")
check(seen.asked, "LOG asks the router for its log")
check(rows:find("06:0%d +● router started") and rows:find("06:0%d +✎ Odd Dust → wash"), "with timezone: clock times")
check(seen.who and seen.lasted and seen.help, "who made each change, the ended alerts, and the help panel")
check(seen.filter, "ALERTS asks for alerts only")
seen = screen(nil)
rows = table.concat(seen.rows, "\n")
check(rows:find("now +● router started") or rows:find("1m ago +● router started"), "without a timezone: how long ago")

H.done()
