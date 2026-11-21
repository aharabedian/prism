--[[ prism.router.flow: how fast items leave and arrive per process, and how busy its machines are.
  Keeps its own state between scans; time is passed in, so it is tested on its own.

  Flow.new() -> flow
  flow:update(now, scan, before, classify, machines) -> moved   { [process] = { out, arrived } } this scan
    scan       this scan (prism.router.planner: present, queues)
    before     the previous scan's { present, queues }, or nil for the first scan (nothing is counted)
    classify   function(key) -> process, for items that left the network
    machines   monitored machines { process, state }
    An item whose quantity dropped counts as out for every queue it's in (its own process, and its fallback
    while shared with it); one that rose counts as arrived. An item that left the network counts as out for
    its process.
  flow:rates(process, now) -> out, arrived   items per minute over the last WINDOW seconds; nil before a
                                             second scan
  flow:busy(process) -> 0..1 | nil           share of scans its machines were working, over the last hour
                                             (minute buckets); nil without machines
  Flow.WINDOW = 300, Flow.BUSY_MINUTES = 60
]]

local Flow = { WINDOW = 300, BUSY_MINUTES = 60 }
Flow.__index = Flow

function Flow.new() return setmetatable({ samples = {}, buckets = {}, started = nil }, Flow) end

local function add(t, proc, field, n)
  if n <= 0 then return end
  local m = t[proc] or { out = 0, arrived = 0 }
  m[field] = m[field] + n
  t[proc] = m
end

function Flow:update(now, scan, before, classify, machines)
  local moved = {}
  if before then
    self.started = self.started or self.lastAt or now
    for proc, q in pairs(scan.queues) do
      for _, e in ipairs(q) do
        local was = before.present[e.key]
        if was then
          add(moved, proc, "out", was - e.size)
          add(moved, proc, "arrived", e.size - was)
        else
          add(moved, proc, "arrived", e.size)
        end
      end
    end
    for key, was in pairs(before.present) do
      if not scan.present[key] then
        local proc = classify(key)
        if proc and proc ~= "ignore" then add(moved, proc, "out", was) end
      end
    end
  end

  -- Rates: one sample per scan and process, kept for WINDOW seconds.
  for proc, mv in pairs(moved) do
    local list = self.samples[proc] or {}
    list[#list + 1] = { t = now, out = mv.out, arrived = mv.arrived }
    self.samples[proc] = list
  end
  for proc, list in pairs(self.samples) do
    while list[1] and list[1].t <= now - Flow.WINDOW do table.remove(list, 1) end
    if #list == 0 then self.samples[proc] = nil end
  end

  -- Busy: per process, minute buckets of { working, polled }.
  local minute = math.floor(now / 60)
  for _, m in ipairs(machines or {}) do
    if m.process then
      local b = self.buckets[m.process] or {}
      self.buckets[m.process] = b
      local c = b[minute] or { working = 0, polled = 0 }
      b[minute] = c
      c.polled = c.polled + 1
      if m.state == "working" then c.working = c.working + 1 end
    end
  end
  for _, b in pairs(self.buckets) do
    for mn in pairs(b) do if mn <= minute - Flow.BUSY_MINUTES then b[mn] = nil end end
  end
  self.now, self.lastAt = now, now
  return moved
end

function Flow:rates(proc, now)
  now = now or self.now
  if not self.started or not now or now <= self.started then return nil end
  local out, arrived = 0, 0
  for _, s in ipairs(self.samples[proc] or {}) do out, arrived = out + s.out, arrived + s.arrived end
  local span = math.min(Flow.WINDOW, now - self.started)
  return out / span * 60, arrived / span * 60
end

function Flow:busy(proc)
  local working, polled = 0, 0
  for _, c in pairs(self.buckets[proc] or {}) do working, polled = working + c.working, polled + c.polled end
  if polled == 0 then return nil end
  return working / polled
end

return Flow
