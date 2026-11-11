--[[ prism.router.health: stall detection and alerts. Keeps state between scans.

  A process is stalled when it has items waiting and at least one output, but for cfg.stallAfter
  seconds none of these happened: any of its items' quantity dropped or left the network, a
  feeder for it moved items, a monitored machine for it was working.

  Health.new(cfg, log) -> health
  health:stalls(now, scan, before, outputs, machines, classify) -> { [process] = seconds stalled }
    before    { present = { [key] = qty } } from the previous scan
    classify  function(key) -> process, for items that left the network
    Also sets m.idleFor on idle machines with work waiting.
  health:alerts(backlog, stalled, outputs, machines) -> { id, level = "bad"|"warn", text }[]
    Ids are stable (stall:wash, feeder:<name>, machine:<name>, idle:<name>); logs each alert
    when it starts and when it resolves.
]]

local U = require("prism.util")

local Health = {}
Health.__index = Health

function Health.new(cfg, log)
  return setmetatable({ cfg = cfg, log = log, stallState = {}, fedAtScan = {}, active = {} }, Health)
end

function Health:stalls(now, scan, before, outputs, machines, classify)
  local moved, working, hasOutput = {}, {}, {}

  for proc, q in pairs(scan.queues) do
    for _, e in ipairs(q) do
      local was = before.present[e.key]
      if was and e.size < was then moved[proc] = true; break end
    end
  end
  for key in pairs(before.present) do
    if not scan.present[key] then
      local proc = classify(key)
      if proc then moved[proc] = true end
    end
  end
  local fedNow = {}
  for _, o in ipairs(outputs) do
    hasOutput[o.process] = true
    if o.fed then fedNow[o.process] = (fedNow[o.process] or 0) + o.fed end
  end
  for proc, n in pairs(fedNow) do
    if n > (self.fedAtScan[proc] or 0) then moved[proc] = true end
  end
  self.fedAtScan = fedNow
  for _, m in ipairs(machines) do
    if m.state == "working" then working[m.process or ""] = true end
    local waiting = m.process and scan.backlog[m.process] and scan.backlog[m.process].items > 0
    if m.state == "idle" and waiting then
      m.idleSince = m.idleSince or now
      m.idleFor = math.floor(now - m.idleSince)
    else
      m.idleSince, m.idleFor = nil, nil
    end
  end

  local stalled = {}
  for proc in pairs(scan.backlog) do
    local s = self.stallState[proc] or {}
    self.stallState[proc] = s
    if moved[proc] or working[proc] or not hasOutput[proc] then
      s.since = nil
    else
      s.since = s.since or now
      if now - s.since >= self.cfg.stallAfter then stalled[proc] = math.floor(now - s.since) end
    end
  end
  for proc in pairs(self.stallState) do if not scan.backlog[proc] then self.stallState[proc] = nil end end
  return stalled
end

function Health:alerts(backlog, stalled, outputs, machines)
  local list = {}
  local function add(id, level, text) list[#list + 1] = { id = id, level = level, text = text } end
  local procs = {}
  for proc in pairs(stalled) do procs[#procs + 1] = proc end
  table.sort(procs)
  for _, proc in ipairs(procs) do
    add("stall:" .. proc, "bad", ("%s stalled %s - %s waiting, nothing moving"):format(
      proc, U.fmtSecs(stalled[proc]), U.fmtNum(backlog[proc].items)))
  end
  for _, o in ipairs(outputs) do
    local a = o:alert()
    if a then list[#list + 1] = a end
  end
  for _, m in ipairs(machines) do
    if m.state == "offline" or m.state == "no power" or m.state == "maintenance" then
      add("machine:" .. m.name, "bad", m.name .. ": " .. m.state)
    elseif m.state == "disabled" then
      add("machine:" .. m.name, "warn", m.name .. ": disabled (soft mallet)")
    elseif m.idleFor and m.idleFor >= self.cfg.idleAlert then
      add("idle:" .. m.name, "warn", ("%s idle %s with work waiting"):format(m.name, U.fmtSecs(m.idleFor)))
    end
  end

  local seen = {}
  for _, a in ipairs(list) do
    seen[a.id] = true
    if not self.active[a.id] then self.log("ALERT %s", a.text) end
  end
  for id in pairs(self.active) do
    if not seen[id] then self.log("resolved: %s", id) end
  end
  self.active = seen
  return list
end

return Health
