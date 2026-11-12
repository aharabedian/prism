--[[ lens.metrics: what an agent knows about itself, in lens/1 terms (docs/telemetry.md). Pure: no I/O.

  local m = require("lens.metrics").new{ role = "prism", clock = computer.uptime }
  local backlog = m:gauge("prism_backlog_items", "Items waiting per process", "items")
  local routed  = m:counter("prism_items_routed_total", "Items moved to outputs", "items")

  Each cycle (an agent's scan):
    m:beginCycle()                       drop last cycle's gauge series, alerts and health override
    backlog:set(4200, { process = "ore" })
    routed:add(64)
    m:alert("down:mac2", "warn", "mac2 stopped with work waiting")
    m:health("bad")                      optional; otherwise the worst alert level, or "ok"
    m:snapshot() -> { health, dseq, samples = { { name, value, labels? }... }, alerts = { { id, level, text, age }... } }
    m:describe() -> { dseq, metrics = { [name] = { type, help, unit? } } }

  new{ role, clock? }    role prefixes every metric name; clock() -> seconds (default: always 0)
  m:gauge(name, help, unit?)    -> g    declaring the same name and type again returns the same handle
  m:counter(name, help, unit?)  -> c    counter names end in _total
  g:set(value, labels?)   value nil, NaN or infinite removes the series (the spec omits missing readings)
  g:remove(labels?)
  c:add(n, labels?)       n >= 0; counters keep their totals across cycles
  m:alert(id, level, text)      level "warn" | "bad"; text is cut to 80 bytes. Age counts from the first
                                cycle the id was raised in, as long as every cycle since raised it again
  m:health(level | nil)         "ok" | "warn" | "bad"

  Programming mistakes (bad names, labels, levels, types) raise errors; readings never do.
  dseq counts metric declarations, so it changes whenever describe() would.
  Samples come out sorted by name, then labels, so snapshots are stable.
]]

local metrics = {}

local NAME = "^[a-z][a-z0-9_]*$"
local MAX_LABELS = 4
local MAX_TEXT = 80
local LEVELS = { ok = 0, warn = 1, bad = 2 }
local HEALTH_OF = { [0] = "ok", "warn", "bad" }

-- Canonical labels: a sorted copy with string values, plus a key string that identifies the series.
local function canon(labels)
  if labels == nil then return nil, "" end
  if type(labels) ~= "table" then error("labels must be a table", 3) end
  local keys = {}
  for k, v in pairs(labels) do
    if type(k) ~= "string" or not k:find(NAME) then error("bad label name: " .. tostring(k), 3) end
    if k == "node" then error("label 'node' is reserved for the hub", 3) end
    local tv = type(v)
    if tv ~= "string" and tv ~= "number" then error("label " .. k .. " must be a string", 3) end
    keys[#keys + 1] = k
  end
  if #keys > MAX_LABELS then error("at most " .. MAX_LABELS .. " labels per series", 3) end
  if #keys == 0 then return nil, "" end
  table.sort(keys)
  local copy, key = {}, {}
  for i, k in ipairs(keys) do
    copy[k] = tostring(labels[k])
    key[i] = k .. "=" .. copy[k]
  end
  return copy, table.concat(key, "\0")
end

local function finite(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- Cut to `max` bytes without leaving half a UTF-8 character at the end.
local function cut(text, max)
  text = tostring(text)
  if #text <= max then return text end
  local s = text:sub(1, max)
  local i = #s
  while i > 0 and s:byte(i) >= 0x80 and s:byte(i) < 0xC0 do i = i - 1 end
  if i > 0 and s:byte(i) >= 0xC0 then
    local need = s:byte(i) >= 0xF0 and 4 or s:byte(i) >= 0xE0 and 3 or 2
    if #s - i + 1 < need then s = s:sub(1, i - 1) end
  end
  return s
end

local Metric = {}
Metric.__index = Metric

function Metric:set(value, labels)
  if self.type ~= "gauge" then error(self.name .. " is a counter: use add", 2) end
  local l, key = canon(labels)
  if not finite(value) then self.series[key] = nil; return end
  self.series[key] = { labels = l, value = value }
end

function Metric:remove(labels)
  local _, key = canon(labels)
  self.series[key] = nil
end

function Metric:add(n, labels)
  if self.type ~= "counter" then error(self.name .. " is a gauge: use set", 2) end
  if not finite(n) or n < 0 then error("counters only go up: " .. tostring(n), 2) end
  local l, key = canon(labels)
  local s = self.series[key]
  if s then s.value = s.value + n else self.series[key] = { labels = l, value = n } end
end

local Registry = {}
Registry.__index = Registry

function metrics.new(opts)
  if type(opts) ~= "table" or type(opts.role) ~= "string" or not opts.role:find(NAME) then
    error("metrics.new needs a role made of a-z, 0-9 and _", 2)
  end
  return setmetatable({
    role = opts.role, clock = opts.clock or function() return 0 end,
    list = {}, byName = {}, dseq = 0,
    alerts = {}, order = {}, since = {}, prevSince = {}, override = nil,
  }, Registry)
end

local function declare(self, kind, name, help, unit)
  if type(name) ~= "string" or not name:find(NAME) then error("bad metric name: " .. tostring(name), 3) end
  if name:sub(1, #self.role + 1) ~= self.role .. "_" then
    error(name .. " must start with " .. self.role .. "_", 3)
  end
  if kind == "counter" and not name:find("_total$") then error("counter " .. name .. " must end in _total", 3) end
  local m = self.byName[name]
  if m then
    if m.type ~= kind then error(name .. " is already a " .. m.type, 3) end
    return m
  end
  m = setmetatable({ name = name, type = kind, help = tostring(help or ""), unit = unit, series = {} }, Metric)
  self.byName[name] = m
  self.list[#self.list + 1] = m
  table.sort(self.list, function(a, b) return a.name < b.name end)
  self.dseq = self.dseq + 1
  return m
end

function Registry:gauge(name, help, unit) return declare(self, "gauge", name, help, unit) end
function Registry:counter(name, help, unit) return declare(self, "counter", name, help, unit) end

function Registry:beginCycle()
  for _, m in ipairs(self.list) do
    if m.type == "gauge" then m.series = {} end
  end
  self.prevSince, self.since, self.alerts, self.order, self.override = self.since, {}, {}, {}, nil
end

function Registry:alert(id, level, text)
  if type(id) ~= "string" or id == "" then error("alert id must be a non-empty string", 2) end
  if level ~= "warn" and level ~= "bad" then error("alert level must be warn or bad", 2) end
  if not self.since[id] then
    self.since[id] = self.prevSince[id] or self.clock()
    self.order[#self.order + 1] = id
  end
  self.alerts[id] = { id = id, level = level, text = cut(text, MAX_TEXT) }
end

function Registry:health(level)
  if level ~= nil and not LEVELS[level] then error("health must be ok, warn or bad", 2) end
  self.override = level
end

function Registry:snapshot()
  local samples = {}
  for _, m in ipairs(self.list) do
    local keys = {}
    for k in pairs(m.series) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local s = m.series[k]
      samples[#samples + 1] = { m.name, s.value, s.labels }
    end
  end
  local alerts, worst, now = {}, 0, self.clock()
  for _, id in ipairs(self.order) do
    local a = self.alerts[id]
    alerts[#alerts + 1] = { id = a.id, level = a.level, text = a.text, age = now - self.since[id] }
    worst = math.max(worst, LEVELS[a.level])
  end
  return { health = self.override or HEALTH_OF[worst], dseq = self.dseq, samples = samples, alerts = alerts }
end

function Registry:describe()
  local out = {}
  for _, m in ipairs(self.list) do out[m.name] = { type = m.type, help = m.help, unit = m.unit } end
  return { dseq = self.dseq, metrics = out }
end

return metrics
