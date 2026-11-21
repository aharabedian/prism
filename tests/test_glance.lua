-- test_glance.lua: glance mode. With glanceAfter set, after that many minutes without a touch the control screen
-- switches to a third of its resolution (53 x 16) and draws each process big: backlog, trend, machine dots,
-- held / stalled / time to clear, the newest alerts. A touch goes back to the full screen without acting on it.
-- Off by default.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check
local ser = M.serialization

local function msg(t) return { "modem_message", "x", "router-addr", 4242, 4, ser.serialize(t) } end
local status = { type = "router-status", cycles = 1, interval = 5, uptime = 100, processes = {
    wash = { items = 8959, types = 7, buses = 2, outRate = 212, inRate = 0 },
    crush = { items = 1920, types = 4, buses = 1, outRate = 140, inRate = 150 },
    ebf = { items = 1024, types = 2, buses = 2, held = true, heldBy = "Aaron", heldFor = 720 },
    export = { items = 53200, types = 3, buses = 1, stalled = 120 },
  }, buses = {}, feeders = {},
  machines = { { name = "Washer A", process = "wash", state = "working", progress = 0.7 },
               { name = "Washer B", process = "wash", state = "idle", idle = 45 },
               { name = "EBF 1", process = "ebf", state = "idle" } },
  unassigned = {}, unassignedCount = 0, catalogCount = 9, knownProcesses = { "crush", "ebf", "export", "wash" },
  alerts = { { id = "idle:Washer B", level = "warn", text = "Washer B idle 45s with work waiting" },
             { id = "stall:export", level = "bad", text = "export stalled 2m00s - 53.2k waiting, nothing moving" } } }

local function run(cfgText, steps)
  local path = H.TMP .. "/gl-control.cfg"
  local f = assert(io.open(path, "w"))
  f:write(cfgText)
  f:close()
  local n = 0
  M.onPull = function()
    n = n + 1
    local s = steps[n]
    if s then return s() end
    return { "interrupted" }
  end
  H.run("prism-control.lua", path)
end

local seen = {}
local cycle = 1
-- a status every 5 s, wash going down
local function tick(i)
  if i % 5 ~= 0 then return nil end
  cycle = cycle + 1
  local s = ser.unserialize(ser.serialize(status))
  s.cycles = cycle
  s.processes.wash.items = 8959 + 600 - cycle * 20
  return msg(s)
end
local computer = require("computer")
local phase, i = 0, 0
local steps = setmetatable({}, { __index = function()
  return function()
    i = i + 1
    local t = computer.uptime()
    if phase == 0 then phase = 1; return msg(status) end
    if phase == 1 and t >= 50 then phase = 2; seen.notYet = M.resW == 160 end
    if phase == 2 and t >= 63 then
      phase = 3
      H.screen("glance")
      seen.size = M.resW == 53 and M.resH == 16
      local function at(text) local x, y = M.find(text); return x and x <= 53 and y <= 16 and y end
      local wy = at("wash")
      seen.wash = wy and M.row(wy):find(" ▼ ●○", 1, true) and M.row(wy):find("clears 4", 1, true)
      seen.live = at("● LIVE") ~= nil
      local cy = at("crush")
      seen.crush = cy and M.row(cy):find("growing 10/min", 1, true)
      seen.held = at("‖ ebf") and M.row(at("‖ ebf")):find("held", 1, true)
      seen.stalled = at("⚠ export") and M.row(at("⚠ export")):find("stalled 2m", 1, true)
      seen.alerts = at("⚠ export stalled") and at("⚠ Washer B idle") and at(" ⚠ 2 ALERTS ")
      seen.hint = at("tap anywhere for the full screen")
      local x, y = M.find("wash")
      return { "touch", "screen", x, y, 0, "Aaron" }           -- on the wash row: must not open anything
    end
    if phase == 3 then
      seen.back = M.resW == 160 and M.find("PROCESSES", 3) ~= nil and M.find("PROCESS wash", 3) == nil
      return { "interrupted" }
    end
    return tick(i)
  end
end })
run("return { glanceAfter = 1 }", steps)
check(seen.notYet, "not before glanceAfter minutes")
check(seen.size, "then a third of the resolution: 53 x 16")
check(seen.wash and seen.live, "a process: backlog, trend, a dot per machine, time to clear")
check(seen.crush and seen.held and seen.stalled, "growing, held and stalled say so")
check(seen.alerts and seen.hint, "the newest alerts and how to go back")
check(seen.back, "a touch goes back to the full screen, without acting on it")

seen = {}
steps = { function() return msg(status) end }
for _ = 1, 400 do steps[#steps + 1] = function() return nil end end
steps[#steps + 1] = function() seen.off = M.resW == 160; return { "interrupted" } end
run("return {}", steps)
check(seen.off, "off by default")

H.done()
