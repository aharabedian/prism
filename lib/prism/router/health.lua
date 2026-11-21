--[[ prism.router.health: stall detection and alerts. Keeps state between scans.

  A process is stalled when it has items ready (at least one batch) and at least one output, but for
  cfg.stallAfter seconds none of these happened: any of its items' quantity dropped or left the network, a
  feeder for it moved items, a monitored machine for it was working.

  Health.new(cfg, log) -> health
  health:stalls(now, scan, before, outputs, machines, classify, held) -> { [process] = seconds stalled }
    before    { present = { [key] = qty } } from the previous scan
    classify  function(key) -> process, for items that left the network
    held      { [process] = truthy }: processes on hold are never stalled, and their machines never idle
              with work waiting
    Also sets m.idleFor on idle machines with work ready. Less than one batch isn't work: it can't run.
  health:stuck(now, scan, before, outputs, held, stalled) -> { key, label, process, secs }[]   longest first
    An item with at least one batch, on one of its process's outputs, that hasn't gone down for cfg.stuckAfter
    seconds while its process used other items in that time. Not for held or stalled processes, nor shared
    copies; off when cfg.stuckAfter is false.
  health:alerts(backlog, stalled, outputs, machines, stuck, unassigned) -> { id, level = "bad"|"warn", text }[]
    unassigned: how many items have stayed unassigned for cfg.unassignedAlert seconds (a warn, id "unassigned")
    Ids are stable (stall:wash, feeder:<name>, machine:<name>, idle:<name>, stuck:<key>; at most 5 stuck);
    logs each alert when it starts and when it resolves, and leaves health.changes = { started = alerts[],
    ended = { id, text }[] } for the event log.
]]

local U = require("prism.util")

local Health = {}
Health.__index = Health

function Health.new(cfg, log)
  return setmetatable({ cfg = cfg, log = log, stallState = {}, fedAtScan = {}, active = {} }, Health)
end

function Health:stalls(now, scan, before, outputs, machines, classify, held)
  held = held or {}
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
    local waiting = m.process and not held[m.process] and scan.backlog[m.process] and scan.backlog[m.process].ready > 0
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
    if moved[proc] or working[proc] or not hasOutput[proc] or scan.backlog[proc].ready == 0 or held[proc] then
      s.since = nil
    else
      s.since = s.since or now
      if now - s.since >= self.cfg.stallAfter then stalled[proc] = math.floor(now - s.since) end
    end
  end
  for proc in pairs(self.stallState) do if not scan.backlog[proc] then self.stallState[proc] = nil end end
  return stalled
end

function Health:stuck(now, scan, before, outputs, held, stalled)
  local after = self.cfg.stuckAfter
  if not after then self.items = {}; return {} end
  local items, procMoved = self.items or {}, self.procMoved or {}
  for proc, q in pairs(scan.queues) do
    for _, e in ipairs(q) do
      local was = before.present[e.key]
      if was and e.size < was then procMoved[proc] = now end
    end
  end
  local out, seen = {}, {}
  for proc, q in pairs(scan.queues) do
    if not (held or {})[proc] and not stalled[proc] then
      for _, e in ipairs(q) do
        local on = false
        if not e.from and e.size >= e.batch then
          for _, o in ipairs(outputs) do
            if o.process == proc and o:holds(e.key) then on = true; break end
          end
        end
        if on then
          seen[e.key] = true
          local s, was = items[e.key], before.present[e.key]
          if not s or (was and e.size < was) then s = { since = now }; items[e.key] = s end
          local secs = now - s.since
          if secs >= after and (procMoved[proc] or -1) > s.since then
            out[#out + 1] = { key = e.key, label = e.label, process = proc, secs = math.floor(secs) }
          end
        end
      end
    end
  end
  for k in pairs(items) do if not seen[k] then items[k] = nil end end
  self.items, self.procMoved = items, procMoved
  table.sort(out, function(a, b) if a.secs ~= b.secs then return a.secs > b.secs end return a.key < b.key end)
  return out
end

function Health:alerts(backlog, stalled, outputs, machines, stuck, unassigned)
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

  if (unassigned or 0) > 0 then
    add("unassigned", "warn", ("%d item%s unassigned for %s or more: route %s in UNASSIGNED"):format(unassigned,
      unassigned == 1 and "" or "s", U.fmtShort(self.cfg.unassignedAlert), unassigned == 1 and "it" or "them"))
  end
  for i, s in ipairs(stuck or {}) do
    if i > 5 then break end
    add("stuck:" .. s.key, "warn", ("%s stuck for %s (%s)"):format(s.label, U.fmtShort(s.secs), s.process))
  end

  local seen, started, ended = {}, {}, {}
  for _, a in ipairs(list) do
    seen[a.id] = self.active[a.id] or a.text            -- the text it started with, for the log's ended entry
    if not self.active[a.id] then self.log("ALERT %s", a.text); started[#started + 1] = a end
  end
  for id, text in pairs(self.active) do
    if not seen[id] then self.log("resolved: %s", id); ended[#ended + 1] = { id = id, text = text } end
  end
  table.sort(ended, function(a, b) return a.id < b.id end)
  self.active, self.changes = seen, { started = started, ended = ended }
  return list
end

return Health
