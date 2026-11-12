--[[ prism.router.status: building the router-status message (fields in docs/protocol.md).

  build(r, scan, stalled, alerts) -> router-status table
    r = the router (prism.router.core): version, cfg, stats, store, outputs, machines
  knownProcesses(r) -> sorted process names named by outputs, machines, rules, overrides or `processes`
]]

local computer = require("computer")
local U        = require("prism.util")
local protocol = require("prism.protocol")
local machines = require("prism.router.machines")

local S = {}

function S.knownProcesses(r)
  local list, seen = {}, {}
  local function add(p)
    if p and p ~= "ignore" and not seen[p] then seen[p] = true; list[#list + 1] = p end
  end
  for _, o in ipairs(r.outputs) do add(o.process) end
  for _, m in ipairs(r.machines) do add(m.process) end
  for _, rule in ipairs(r.store:rules()) do add(rule.process); add(rule.fallback) end
  for _, o in pairs(r.cfg.overrides) do add(o.process); add(o.fallback) end
  for _, o in pairs(r.store.overrides) do add(o.process); add(o.fallback) end
  for p in pairs(r.cfg.processes) do add(p) end
  table.sort(list)
  return list
end

function S.build(r, scan, stalled, alerts)
  local s = {
    type = "router-status", version = r.version, uptime = math.floor(computer.uptime()), interval = r.cfg.interval,
    cycles = r.stats.cycles, cycleMs = r.stats.cycleMs, writes = r.stats.writes,
    lastError = r.stats.lastError, processes = {}, buses = {}, feeders = {}, unassigned = {},
    unassignedCount = #scan.unassigned, catalogCount = U.count(r.store.catalog),
    knownProcesses = S.knownProcesses(r), machines = machines.summary(r.machines), alerts = alerts,
  }
  for proc, b in pairs(scan.backlog) do
    s.processes[proc] = { types = b.types, items = b.items, buses = 0, stalled = stalled[proc] }
  end
  local function proc(name)
    local p = s.processes[name] or { types = 0, items = 0, buses = 0 }
    s.processes[name] = p
    return p
  end
  for name, sp in pairs(scan.spilled or {}) do proc(name).spilled = sp.items end
  for name, lim in pairs(r.store:limits()) do
    local p = proc(name)
    p.overflow, p.alwaysShare = lim.overflow, lim.alwaysShare
  end
  for _, o in ipairs(r.outputs) do
    local p = s.processes[o.process] or { types = 0, items = 0, buses = 0 }
    p.buses = p.buses + 1
    s.processes[o.process] = p
    local list = s[o.statusList]
    list[#list + 1] = o:status(scan.labels)
  end
  for i = 1, math.min(#scan.unassigned, protocol.UNASSIGNED_TOP) do s.unassigned[i] = scan.unassigned[i] end
  return s
end

return S
