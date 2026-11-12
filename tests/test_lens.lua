-- test_lens.lua: reporting to LENS: describe at start, a snapshot every scan with backlog, machine states
-- and alerts, answering the hub's hello (with the LENS token only), staying off the control screen's port,
-- lensPort off, lensPort = modemPort refused, and routing that carries on when reporting fails.
local H = dofile((debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./") .. "helper.lua")
local M = require("oc")
local check = H.check
local ser = M.serialization
local computer = require("computer")
local codec = require("prism.lens.codec")
local VERSION = require("prism.version")

local GT = "gregtech:gt.metaitem.01"
local function item(d, label, size) return { name = GT, damage = d, label = label, size = size } end
M.items = {
  item(5001, "Crushed Copper Ore", 300),
  item(5002, "Crushed Tin Ore", 200),
  item(6001, "Impure Pile of Copper Dust", 120),
}

M.machine("gm01", { isMachineActive = true, isWorkAllowed = true, getWorkProgress = 30, getWorkMaxProgress = 100,
                    getEUStored = 8000, getEUMaxStored = 10000 })
M.machine("gm02", { isMachineActive = false, isWorkAllowed = true, getEUStored = 9000, getEUMaxStored = 10000 })
M.machine("gm04", { isMachineActive = false, isWorkAllowed = true, getEUStored = 10, getEUMaxStored = 10000 })

local function writeCfg(name, lens)
  local path = H.TMP .. "/" .. name .. ".cfg"
  local f = assert(io.open(path, "w"))
  f:write(([[
return {
  interval = 5, monitorInterval = 2, stallAfter = 60, idleAlert = 30, modemPort = 4242, verbose = false,
  %s
  buses = {
    { address = "eb11", side = sides.north, process = "wash",       name = "Washer bus" },
    { address = "eb11", side = sides.south, process = "centrifuge", name = "Centrifuge bus" },
  },
  machines = {
    { address = "gm01", process = "wash", name = "Washer A" },
    { address = "gm02", process = "wash", name = "Washer B" },
    { address = "gm04", name = "Macerator" },
  },
  rules = {
    { pattern = "^Crushed .+ Ore$",         process = "wash" },
    { pattern = "^Impure Pile of .+ Dust$", process = "centrifuge" },
  },
}
]]):format(lens))
  f:close()
  for _, s in ipairs({ "-overrides.cfg", "-items.cfg", "-rules.cfg", "-always-share.cfg" }) do os.remove(H.TMP .. "/" .. name .. s) end
  return path
end

local function lensMsg(t, port) return { "modem_message", "x", "lens-hub", port or 4243, 2, ser.serialize(t) } end
local function hello(token)
  return lensMsg({ proto = "lens/1", kind = "hello", node = "hub", role = "hub", boot = 1, seq = 1, token = token })
end

---------------------------------------------------------------- a router reporting to LENS
local cfgPath = writeCfg("lens-prism", 'lensPort = 4243, lensNode = "prism-ore", lensToken = "lens-s",')
local marks = {}
M.onPull = function()
  local t = computer.uptime()
  if t >= 40 and not marks.hello then
    marks.hello = #M.sent
    return hello("lens-s")
  end
  if marks.hello and not marks.wrong then
    marks.afterHello = #M.sent
    marks.wrong = #M.sent
    return hello("prism-secret")
  end
  if marks.wrong and not marks.cmd then
    marks.afterWrong = #M.sent
    marks.cmd = #M.sent
    -- a PRISM command on the LENS port, and a LENS hello on PRISM's port: neither is acted on
    return lensMsg({ cmd = "status" })
  end
  if marks.cmd and not marks.cross then
    marks.afterCmd = #M.sent
    marks.cross = #M.sent
    return lensMsg({ proto = "lens/1", kind = "hello", node = "hub", role = "hub", boot = 1, seq = 2, token = "lens-s" }, 4242)
  end
  if marks.cross and not marks.afterCross then marks.afterCross = #M.sent end
  if t >= 60 then return { "interrupted" } end
end
assert(loadfile(H.SRC .. "/prism.lua"))(cfgPath)

local lens, onPrismPort, undecoded = {}, 0, nil
for i, s in ipairs(M.sent) do
  if s.port == 4243 then
    local msg, why = codec.decode(s.data, "lens-s")
    if msg then
      msg.index = i
      lens[#lens + 1] = msg
    else
      undecoded = undecoded or why
    end
  elseif s.port == 4242 and codec.decode(s.data) then
    onPrismPort = onPrismPort + 1
  end
end
check(#lens > 0 and undecoded == nil, "every packet on the LENS port is a lens/1 message with the LENS token"
  .. (undecoded and (": " .. undecoded) or ""))
check(onPrismPort == 0, "nothing LENS goes out on the control screen's port")
check(lens[1].kind == "describe" and lens[1].node == "prism-ore" and lens[1].role == "prism" and lens[1].version == VERSION,
  "the router describes itself to LENS at start, under lensNode")
check(lens[1].metrics.prism_machine_state.type == "gauge" and lens[1].metrics.prism_scans_total.type == "counter",
  "the describe lists gauges and counters")

local asm = codec.assembler()
local snaps = {}
for _, msg in ipairs(lens) do
  local whole = asm:add(msg, 0)
  if whole and whole.kind == "snapshot" then whole.index = msg.index; snaps[#snaps + 1] = whole end
end
check(#snaps >= 8 and snaps[1].interval == 5, "a snapshot after every scan, with the scan interval")

local function samples(s, name, want)
  local out = {}
  for _, x in ipairs(s.samples) do
    if x[1] == name then
      local ok = true
      for k, v in pairs(want or {}) do if (x[3] or {})[k] ~= v then ok = false end end
      if ok then out[#out + 1] = x end
    end
  end
  return out
end
local function value(s, name, want) local l = samples(s, name, want); return l[1] and l[1][2] end
local function stateOf(s, machine)
  for _, x in ipairs(samples(s, "prism_machine_state", { machine = machine })) do
    if x[2] == 1 then return x[3].state end
  end
end

local first = snaps[2]
check(value(first, "prism_backlog_items", { process = "wash" }) == 500
  and value(first, "prism_backlog_types", { process = "wash" }) == 2
  and value(first, "prism_backlog_items", { process = "centrifuge" }) == 120, "backlog per process")
check(stateOf(first, "Washer A") == "running" and value(first, "prism_machine_progress_ratio", { machine = "Washer A" }) == 0.3,
  "a working machine is running, with its progress")
check(stateOf(first, "Washer B") == "idle", "an idle machine is idle at first")
check(stateOf(first, "Macerator") == "down", "a machine without power is down")
check(#samples(first, "prism_machine_state", { machine = "Washer A" }) == 3,
  "each machine has one series per state (running, idle, down)")
check(samples(first, "prism_machine_state", { machine = "Macerator" })[1][3].process == nil,
  "a machine without a process has no process label")

local late
for _, s in ipairs(snaps) do if s.index < marks.hello then late = s end end
check(stateOf(late, "Washer B") == "down", "idle with work waiting for idleAlert seconds: down")
local ids = {}
for _, a in ipairs(late.alerts) do ids[a.id] = a end
check(ids["machine:Macerator"] and ids["machine:Macerator"].level == "bad" and ids["idle:Washer B"]
  and late.health == "bad", "the router's alerts go to LENS with their ids, and set health")
check(value(late, "prism_scans_total") > value(first, "prism_scans_total"), "scans are counted")

local function kindsBetween(a, b)
  local kinds = {}
  for _, msg in ipairs(lens) do
    if msg.index > a and msg.index <= b then kinds[#kinds + 1] = msg.kind end
  end
  return kinds
end
local k = kindsBetween(marks.hello, marks.afterHello)
check(k[1] == "describe" and k[#k] == "snapshot", "the hub's hello is answered at once with describe and snapshot")
check(#kindsBetween(marks.wrong, marks.afterWrong) == 0, "a hello with another token is ignored")
local replies = 0
for i = marks.cmd + 1, marks.afterCmd do if M.sent[i].to == "lens-hub" then replies = replies + 1 end end
check(replies == 0, "a PRISM command on the LENS port gets no reply")
check(#kindsBetween(marks.cross, marks.afterCross) == 0, "a LENS hello on PRISM's port is ignored")

---------------------------------------------------------------- lensPort off
local before = #M.sent
M.onPull = function() if computer.uptime() >= 80 then return { "interrupted" } end end
assert(loadfile(H.SRC .. "/prism.lua"))(writeCfg("lens-off", "lensPort = false,"))
local any = false
for i = before + 1, #M.sent do if M.sent[i].port == 4243 or codec.decode(M.sent[i].data) then any = true end end
check(not any and #M.sent > before, "lensPort = false: the router runs and reports nothing")

---------------------------------------------------------------- lensPort = modemPort
local ok, err = pcall(assert(loadfile(H.SRC .. "/prism.lua")), writeCfg("lens-same", "lensPort = 4242,"))
check(not ok and tostring(err):find("lensPort must differ from modemPort", 1, true), "lensPort = modemPort is refused")

---------------------------------------------------------------- reporting fails, routing doesn't
local modem
for _, p in pairs(M.proxies) do if p.type == "modem" then modem = p end end
local realBroadcast = modem.broadcast
modem.broadcast = function(port, data)
  if port == 4243 then error("modem on fire") end
  return realBroadcast(port, data)
end
local logged = {}
local realWrite = io.write
io.write = function(...) logged[#logged + 1] = table.concat({ ... }) end
before = #M.sent
M.onPull = function() if computer.uptime() >= 120 then return { "interrupted" } end end
ok, err = pcall(assert(loadfile(H.SRC .. "/prism.lua")), writeCfg("lens-fail", 'lensPort = 4243, lensNode = "x",'))
io.write = realWrite
modem.broadcast = realBroadcast
local statuses = 0
for i = before + 1, #M.sent do
  local m = ser.unserialize(M.sent[i].data)
  if m and m.type == "router-status" then statuses = statuses + 1 end
end
local failures = 0
local announced = false
for _, l in ipairs(logged) do
  if l:find("LENS report failed", 1, true) then failures = failures + 1 end
  if l:find("LENS announce failed", 1, true) then announced = true end
end
check(statuses >= 5, "the router keeps scanning and serving the control screen when reporting fails"
  .. (ok and "" or (": " .. tostring(err))))
check(failures == 1 and announced, "and logs each kind of failure once")

H.done()
