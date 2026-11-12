--[[ prism.router.telemetry: reporting to LENS, the base-wide monitoring hub (https://github.com/aharabedian/lens).
  Speaks lens/1 on its own port and token, separate from the control screen's. Metrics: docs/configuration.md.

  Telemetry.open(cfg, modem, log) -> t | nil     nil when cfg.lensPort is off or there's no modem.
                                                 Raises when lensPort is the same as modemPort.
  t.port
  t:announce()                         send the describe; the router calls this once after open
  t:report(r, scan, stalled, alerts)   after each scan: refresh the metrics and broadcast a snapshot
  t:failed(err)                        a scan failed: broadcast health bad with the error as an alert
  t:handle(data)                       a packet that arrived on t.port: answers the hub's hello
  t:close()

  Machine states map onto LENS's running / idle / down: working is running; idle is idle until it has been
  idle with work waiting for idleAlert seconds, then down; no power, maintenance, disabled and offline are
  down. Machines not polled yet aren't reported.
]]

local computer = require("computer")
local metrics  = require("prism.lens.metrics")
local codec    = require("prism.lens.codec")

local Telemetry = {}
Telemetry.__index = Telemetry

local STATES = { "running", "idle", "down" }
local DOWN = { ["no power"] = true, maintenance = true, disabled = true, offline = true }

function Telemetry.open(cfg, modem, log)
  local port = cfg.lensPort
  if not port or not modem then return nil end
  if port == cfg.modemPort then
    error("lensPort must differ from modemPort: LENS and the control screen are separate networks", 0)
  end
  local t = setmetatable({ port = port, modem = modem, log = log, cfg = cfg, lastCycles = 0, lastWrites = 0 }, Telemetry)
  local m = metrics.new{ role = "prism", clock = computer.uptime }
  t.m = m
  t.backlogItems = m:gauge("prism_backlog_items", "Items waiting per process", "items")
  t.backlogTypes = m:gauge("prism_backlog_types", "Item types waiting per process", "types")
  t.stalled      = m:gauge("prism_stalled_seconds", "How long a process has been stalled", "s")
  t.unassigned   = m:gauge("prism_unassigned_types", "Item types no rule or override routes", "types")
  t.machineState = m:gauge("prism_machine_state", "Monitored machine state: one of running, idle, down (0/1)")
  t.progress     = m:gauge("prism_machine_progress_ratio", "Monitored machine recipe progress", "0..1")
  t.scanSeconds  = m:gauge("prism_scan_seconds", "How long the latest scan took", "s")
  t.scans        = m:counter("prism_scans_total", "Scans since the router started", "scans")
  t.writes       = m:counter("prism_writes_total", "Filter and interface writes since the router started", "writes")
  t.enc = codec.encoder{ node = cfg.lensNode or "prism", role = "prism", boot = math.random(1, 0x7fffffff),
    interval = cfg.interval, token = cfg.lensToken, version = require("prism.version") }
  modem.open(port)
  log("reporting to LENS as %s on port %d", cfg.lensNode or "prism", port)
  return t
end

function Telemetry:announce() self:broadcast(self.enc:describe(self.m:describe())) end

function Telemetry:broadcast(packets)
  for _, p in ipairs(packets) do self.modem.broadcast(self.port, p) end
end

local function machineState(m, idleAlert)
  if m.state == "working" then return "running" end
  if DOWN[m.state] then return "down" end
  if m.state == "idle" then return (m.idleFor and m.idleFor >= idleAlert) and "down" or "idle" end
  return nil
end

function Telemetry:report(r, scan, stalled, alerts)
  local m = self.m
  m:beginCycle()
  for proc, b in pairs(scan.backlog) do
    self.backlogItems:set(b.items, { process = proc })
    self.backlogTypes:set(b.types, { process = proc })
  end
  for proc, secs in pairs(stalled) do self.stalled:set(secs, { process = proc }) end
  self.unassigned:set(#scan.unassigned)
  for _, mc in ipairs(r.machines) do
    local state = machineState(mc, r.cfg.idleAlert)
    if state then
      for _, s in ipairs(STATES) do
        self.machineState:set(s == state and 1 or 0, { process = mc.process, machine = mc.name, state = s })
      end
    end
    if mc.progress then self.progress:set(mc.progress, { process = mc.process, machine = mc.name }) end
  end
  self.scanSeconds:set(r.stats.cycleMs / 1000)
  self.scans:add(math.max(0, r.stats.cycles - self.lastCycles))
  self.writes:add(math.max(0, r.stats.writes - self.lastWrites))
  self.lastCycles, self.lastWrites = r.stats.cycles, r.stats.writes
  for _, a in ipairs(alerts) do m:alert(a.id, a.level, a.text) end
  self:broadcast(self.enc:snapshot(m:snapshot()))
end

function Telemetry:failed(err)
  -- Keep the last scan's metrics (they're still the best we know) but say the router is in trouble.
  self.m:alert("scan-failed", "bad", "scan failed: " .. tostring(err))
  self.m:health("bad")
  self:broadcast(self.enc:snapshot(self.m:snapshot()))
end

function Telemetry:handle(data)
  local msg = codec.decode(data, self.cfg.lensToken)
  if msg and msg.kind == "hello" then
    self:broadcast(self.enc:describe(self.m:describe()))
    self:broadcast(self.enc:snapshot(self.m:snapshot()))
  end
end

function Telemetry:close() self.modem.close(self.port) end

return Telemetry
