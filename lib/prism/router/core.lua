--[[ prism.router.core: the router. Wires the parts together and runs the main loop.

  Router.new(configPath) -> r
  r:setup()     (re)load prism.cfg and the data files, open every component; raises a readable error
  r:run()       the main loop, until Ctrl+C
  r:cycle()     one scan (also used by tests through the loop)

  State the parts share (read by commands and status):
    r.cfg        prism.cfg with defaults (prism.config)
    r.store      data files + classification (prism.router.store)
    r.outputs    export buses, stockers, feeders (prism.router.outputs)
    r.machines   monitored GT machines (prism.router.machines)
    r.last       { labels, present, queues } from the latest scan
    r.stats      { cycles, writes, cycleMs, lastError }
    r.reported   things already warned about, so the log isn't spammed
    r.lastStatus the latest router-status
]]

local component = require("component")
local computer  = require("computer")
local event     = require("event")

local VERSION   = require("prism.version")
local U         = require("prism.util")
local log       = require("prism.log")
local config    = require("prism.config")
local protocol  = require("prism.protocol")
local Store     = require("prism.router.store")
local Database  = require("prism.router.database")
local outputs   = require("prism.router.outputs")
local machines  = require("prism.router.machines")
local planner   = require("prism.router.planner")
local Health    = require("prism.router.health")
local status    = require("prism.router.status")
local commands  = require("prism.router.commands")

local Router = {}
Router.__index = Router

-- A component by type and (prefix of) address, or the first of that type.
local function proxyOf(ctype, addr)
  local full
  if addr then full = component.get(addr, ctype) else full = component.list(ctype)() end
  return full and component.proxy(full) or nil
end

function Router.new(configPath)
  return setmetatable({
    version = VERSION, configPath = configPath, log = log,
    outputs = {}, machines = {},
    stats = { cycles = 0, writes = 0, cycleMs = 0, lastError = nil },
    last = { labels = {}, present = {}, queues = {} },
  }, Router)
end

---------------------------------------------------------------- setup

function Router:setup()
  local cfg = config.loadRouter(self.configPath, log)
  self.cfg = cfg
  self.store = Store.open(self.configPath, cfg, log)
  self.reported = {}
  self.health = Health.new(cfg, log)

  self.net = proxyOf("me_controller", cfg.network) or proxyOf("me_interface", cfg.network)
  if not self.net then error("no ME controller/interface found - is an adapter touching it?", 0) end

  -- Outputs set from a database entry need one; stocking buses take item tables directly.
  local dbProxy = proxyOf("database", cfg.database)
  self.db = dbProxy and Database.open(dbProxy, self.net) or nil
  local needDb = outputs.needsDatabase(cfg)
  if not self.db and needDb then
    error(("no database found - put a Database Upgrade in an adapter (%s need one)"):format(table.concat(needDb, " and ")), 0)
  end

  self.outputs = outputs.open(cfg, {
    cfg = cfg, db = self.db, net = self.net, stats = self.stats, log = log, proxyOf = proxyOf,
    labelOf = function(key) return self.last.labels[key] end,
  })
  self.feeders = outputs.ofKind(self.outputs, "feeder")
  self.machines = machines.open(cfg, proxyOf)

  self.modem = proxyOf("modem")
  if self.modem and cfg.modemPort then self.modem.open(cfg.modemPort) end

  local n = {}
  for _, o in ipairs(self.outputs) do n[o.kind] = (n[o.kind] or 0) + 1 end
  log("router %s - network %s, database %s, %d bus(es), %d stocker(s), %d interface(s), %d feeder(s), "
    .. "%d machine(s), %d known items, modem %s", VERSION, self.net.address:sub(1, 8), self.db and (self.db.size .. " slots") or "none",
    n.bus or 0, n.stocker or 0, n.interface or 0, n.feeder or 0, #self.machines, U.count(self.store.catalog),
    self.modem and ("port " .. tostring(cfg.modemPort)) or "none")
  if self.store.screenRules then
    log("using %d rule(s) from %s - rules in prism.cfg are ignored", #self.store.screenRules, self.store.paths.rules)
  end
  if #self.outputs == 0 then log("no buses, stockers, interfaces or feeders configured yet - run prism-setup") end
end

---------------------------------------------------------------- wireless

function Router:send(target, msg)
  local modem, port = self.modem, self.cfg.modemPort
  if not (modem and port) then return end
  local data = protocol.encode(msg, (modem.maxPacketSize and modem.maxPacketSize() or 8192) - 64)
  if not data then return end
  if target then modem.send(target, port, data) else modem.broadcast(port, data) end
end

-- Returns true when the command changed something and a scan should run now.
function Router:handleMessage(from, port, data)
  if port ~= self.cfg.modemPort then return false end
  local msg = protocol.decode(data)
  if not msg or not msg.cmd then return false end
  if self.cfg.token and msg.token ~= self.cfg.token then return false end
  return commands.handle(self, msg, function(reply) self:send(from, reply) end)
end

---------------------------------------------------------------- scan cycle

-- Log each problem once: unassigned items, processes nothing serves, batch items nothing can take.
function Router:warn(scan)
  local reported = self.reported
  for _, u in ipairs(scan.unassigned) do
    if not reported[u.key] then
      reported[u.key] = true
      log("unassigned: %s (%s) x%d", u.label, u.key, u.size)
    end
  end
  local served, batched = {}, {}
  for _, o in ipairs(self.outputs) do
    served[o.process] = true
    if o.takesBatches then batched[o.process] = true end
  end
  for proc, q in pairs(scan.queues) do
    if not served[proc] and not reported["proc:" .. proc] then
      reported["proc:" .. proc] = true
      log("items waiting for '%s' but no bus, stocker, interface or feeder is configured for it", proc)
    end
    if not batched[proc] then
      for _, e in ipairs(q) do
        if e.batch > 1 and not reported["batch:" .. e.key] then
          reported["batch:" .. e.key] = true
          log("%s needs batches of %d - '%s' has no feeder or stocker, so it won't be sent", e.label, e.batch, proc)
        end
      end
    end
  end
end

function Router:cycle()
  local t0 = computer.uptime()
  local store = self.store
  self.stats.lastError = nil               -- only report problems from this cycle

  local scan = planner.plan(self.net.getItemsInNetwork() or {}, function(label, key) return store:classify(label, key) end)

  local changed = false
  for _, key in ipairs(scan.order) do
    local label = scan.labels[key]
    if not store.catalog[key] or store.catalog[key].label ~= label then
      store.catalog[key] = { label = label }
      changed = true
    end
  end
  if changed then store:saveCatalog() end
  self:warn(scan)

  for _, o in ipairs(self.outputs) do o:apply(scan.queues[o.process] or {}) end

  local stalled = self.health:stalls(computer.uptime(), scan, self.last, self.outputs, self.machines, function(key)
    return (store:classify(store:labelOf(key, self.last.labels[key]), key))
  end)
  local alerts = self.health:alerts(scan.backlog, stalled, self.outputs, self.machines)

  self.last = { labels = scan.labels, present = scan.present, queues = scan.queues }
  self.stats.cycles = self.stats.cycles + 1
  self.stats.cycleMs = math.floor((computer.uptime() - t0) * 1000)
  self.lastStatus = status.build(self, scan, stalled, alerts)
  self:send(nil, self.lastStatus)
end

---------------------------------------------------------------- main loop

-- One loop, three timers (monitor, scan, feed), woken early by wireless commands.
function Router:run()
  local cfg = self.cfg
  log("scanning every %ss%s%s - Ctrl+C to stop", tostring(cfg.interval),
    #self.feeders > 0 and (", feeding every " .. tostring(cfg.feedInterval) .. "s") or "",
    #self.machines > 0 and (", watching machines every " .. tostring(cfg.monitorInterval) .. "s") or "")

  local nextScan, nextFeed, nextMonitor = 0, 0, 0
  while true do
    cfg = self.cfg                                   -- a reload replaces it
    if #self.machines > 0 and computer.uptime() >= nextMonitor then
      for _, m in ipairs(self.machines) do machines.poll(m) end
      if nextScan > computer.uptime() then          -- the scan sends its own full status
        self:send(nil, { type = "router-machines", machines = machines.summary(self.machines) })
      end
      nextMonitor = computer.uptime() + cfg.monitorInterval
    end
    if computer.uptime() >= nextScan then
      local ok, err = pcall(self.cycle, self)
      if not ok then
        self.stats.lastError = tostring(err)
        log("cycle failed: %s", tostring(err))
      end
      nextScan = computer.uptime() + cfg.interval
    end
    if #self.feeders > 0 and computer.uptime() >= nextFeed then
      for _, f in ipairs(self.feeders) do f:step(self.last.queues[f.process] or {}) end
      nextFeed = computer.uptime() + cfg.feedInterval
    end

    local wake = nextScan
    if #self.feeders > 0 and nextFeed < wake then wake = nextFeed end
    if #self.machines > 0 and nextMonitor < wake then wake = nextMonitor end
    local wait = wake - computer.uptime()
    if wait > 0 then
      local ev = table.pack(event.pullMultiple(wait, "modem_message", "interrupted"))
      if ev[1] == "interrupted" then break end
      if ev[1] == "modem_message" then
        -- modem_message: localAddress, remoteAddress, port, distance, payload...
        local ok, rescan = pcall(self.handleMessage, self, ev[3], ev[4], ev[6])
        if not ok then log("bad message: %s", tostring(rescan)) end
        if ok and rescan then nextScan = 0 end
      end
    end
  end

  for _, o in ipairs(self.outputs) do o:close() end   -- hand stock back to the network
  if self.modem and self.cfg.modemPort then self.modem.close(self.cfg.modemPort) end
  log("stopped")
end

return Router
