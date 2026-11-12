--[[ lens.codec: lens/1 messages on the wire (docs/telemetry.md): the envelope, splitting into parts that
  fit a packet, and putting them back together. Pure apart from OpenOS `serialization`.

  codec.PROTO           "lens/1"
  codec.DEFAULT_PORT    4243
  codec.LIMIT           7168: the most bytes one serialized message may take

  codec.newBoot() -> integer   a random boot id. Use this, not math.random(m, n): in OpenComputers that
                               doesn't return an integer.

  Sending (agents, and the hub for hello):
    local enc = codec.encoder{ node, role, boot, interval?, version?, token?, limit? }
      boot: chosen once at program start (codec.newBoot()); any whole number is taken as an integer.
      interval: seconds between snapshots (agents)
    enc:hello()           -> { data }
    enc:describe(d)       -> { data, ... }   d = metrics:describe()
    enc:snapshot(s)       -> { data, ... }   s = metrics:snapshot()
    Each data string is one packet to broadcast, in order. Every packet gets the next seq. A message that
    doesn't fit is split: the list (snapshot samples, describe metrics) is spread over parts; part 1 alone
    carries the other fields. If part 1 is too big by itself, the snapshot keeps the worst alerts that fit
    and sets moreAlerts = how many it left out.

  Receiving (the hub, and agents for hello):
    codec.decode(data, token?) -> msg | nil, reason
      reason: "garbled", "proto", "token", "kind", "envelope". Whole-number floats in boot, seq, sid, part
      and parts are turned into integers.
    local asm = codec.assembler()
    asm:add(msg, now) -> whole message | nil
      hello and one-part messages come straight back. Parts are kept until all have arrived, then come back
      joined, as one message with part = 1, parts = 1. Parts of an older sid than the node's latest are
      dropped; an incomplete message is dropped when a newer sid arrives or `interval` seconds (default 10)
      after its first part.
]]

local serialization = require("serialization")

local codec = {}

codec.PROTO = "lens/1"
codec.DEFAULT_PORT = 4243
codec.LIMIT = 7 * 1024

local KINDS = { hello = true, describe = true, snapshot = true }
local LIST = { snapshot = "samples", describe = "metrics" }
local SEVERITY = { bad = 2, warn = 1 }

-- A whole number as an integer (2.0 -> 2); anything else unchanged.
local function asInteger(v)
  if type(v) == "number" and math.type(v) == "float" and v == math.floor(v) then return math.tointeger(v) or v end
  return v
end

function codec.newBoot()
  return math.tointeger(math.floor(math.random() * 0x7ffffffe)) + 1
end

local function shallow(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

---------------------------------------------------------------- sending
local Encoder = {}
Encoder.__index = Encoder

function codec.encoder(o)
  assert(type(o) == "table" and type(o.node) == "string" and type(o.role) == "string", "encoder needs node and role")
  local boot = asInteger(o.boot)
  assert(math.type(boot) == "integer", "encoder needs a whole-number boot, got " .. tostring(o.boot))
  return setmetatable({
    node = o.node, role = o.role, boot = boot, interval = o.interval, version = o.version,
    token = o.token, limit = o.limit or codec.LIMIT, seq = 0,
  }, Encoder)
end

function Encoder:envelope(kind, seq)
  return { proto = codec.PROTO, kind = kind, node = self.node, role = self.role, boot = self.boot,
    seq = seq, version = self.version, token = self.token }
end

-- Keep the worst alerts that fit `budget` bytes; returns the kept list and how many were left out.
local function fitAlerts(alerts, budget)
  local sorted = {}
  for i, a in ipairs(alerts) do sorted[i] = { a = a, i = i } end
  table.sort(sorted, function(x, y)
    local sx, sy = SEVERITY[x.a.level] or 0, SEVERITY[y.a.level] or 0
    if sx ~= sy then return sx > sy end
    return x.i < y.i
  end)
  local kept, used = {}, 0
  for _, e in ipairs(sorted) do
    local size = #serialization.serialize(e.a) + 12
    if used + size > budget then break end
    used = used + size
    kept[#kept + 1] = e.a
  end
  return kept, #alerts - #kept
end

-- Split `body` (a describe or snapshot) into packets. Entries of its list field are packed greedily by
-- their serialized size; if a packed part still serializes too big (the estimate is per entry), the budget
-- shrinks and packing starts over.
function Encoder:pack(kind, body)
  local listField = LIST[kind]
  local head = shallow(body)
  local list = head[listField] or {}
  head[listField] = nil
  if kind == "snapshot" then head.interval = head.interval or self.interval end

  local entries = {}
  if kind == "describe" then
    local names = {}
    for name in pairs(list) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do entries[#entries + 1] = { key = name, value = list[name] } end
  else
    for _, v in ipairs(list) do entries[#entries + 1] = { value = v } end
  end
  for _, e in ipairs(entries) do
    e.size = #serialization.serialize(e.key and { [e.key] = e.value } or { e.value }) + 8
  end

  -- What every part costs before any entries: the envelope with numbers as long as they can get.
  local BIG = math.maxinteger
  local probe = self:envelope(kind, BIG)
  probe.sid, probe.part, probe.parts = BIG, 99999, 99999
  probe[listField] = {}
  local base = #serialization.serialize(probe)
  local headProbe = shallow(probe)
  for k, v in pairs(head) do headProbe[k] = v end
  local headBase = #serialization.serialize(headProbe)

  if headBase > self.limit and head.alerts then
    local without = shallow(headProbe)
    without.alerts, without.moreAlerts = {}, #head.alerts
    local room = self.limit - #serialization.serialize(without)
    local more
    head.alerts, more = fitAlerts(head.alerts, room)
    head.moreAlerts = more > 0 and more or nil
    headProbe.alerts, headProbe.moreAlerts = head.alerts, head.moreAlerts
    headBase = #serialization.serialize(headProbe)
  end
  if headBase > self.limit then error(kind .. ": header alone is larger than a packet") end

  local budget = self.limit
  for _ = 1, 8 do
    local parts, cur, used = {}, {}, headBase
    for _, e in ipairs(entries) do
      if base + e.size > budget then error(kind .. ": one entry is larger than a packet") end
      if used + e.size > budget then
        parts[#parts + 1], cur, used = cur, {}, base
      end
      cur[#cur + 1] = e
      used = used + e.size
    end
    parts[#parts + 1] = cur

    local out, sid, ok = {}, self.seq + 1, true
    for i, p in ipairs(parts) do
      local msg = self:envelope(kind, self.seq + i)
      if i == 1 then for k, v in pairs(head) do msg[k] = v end end
      local l = {}
      for _, e in ipairs(p) do
        if e.key then l[e.key] = e.value else l[#l + 1] = e.value end
      end
      msg[listField], msg.sid, msg.part, msg.parts = l, sid, i, #parts
      local data = serialization.serialize(msg)
      if #data > self.limit then ok = false; break end
      out[i] = data
    end
    if ok then
      self.seq = self.seq + #parts
      return out
    end
    budget = budget - 256
  end
  error(kind .. ": could not split into packets")
end

function Encoder:hello()
  self.seq = self.seq + 1
  return { serialization.serialize(self:envelope("hello", self.seq)) }
end
function Encoder:describe(d) return self:pack("describe", d) end
function Encoder:snapshot(s) return self:pack("snapshot", s) end

---------------------------------------------------------------- receiving
function codec.decode(data, token)
  if type(data) ~= "string" then return nil, "garbled" end
  local msg = serialization.unserialize(data)
  if type(msg) ~= "table" then return nil, "garbled" end
  if msg.proto ~= codec.PROTO then return nil, "proto" end
  if token and msg.token ~= token then return nil, "token" end
  if not KINDS[msg.kind] then return nil, "kind" end
  for _, k in ipairs({ "boot", "seq", "sid", "part", "parts" }) do msg[k] = asInteger(msg[k]) end
  if type(msg.node) ~= "string" or math.type(msg.boot) ~= "integer" or math.type(msg.seq) ~= "integer" then
    return nil, "envelope"
  end
  if msg.kind ~= "hello" then
    local p, n = msg.part or 1, msg.parts or 1
    if math.type(p) ~= "integer" or math.type(n) ~= "integer" or p < 1 or p > n or n > 1000 then
      return nil, "envelope"
    end
    if n > 1 and math.type(msg.sid) ~= "integer" then return nil, "envelope" end
    if type(msg[LIST[msg.kind]] or {}) ~= "table" then return nil, "envelope" end
  end
  return msg
end

local Assembler = {}
Assembler.__index = Assembler

function codec.assembler() return setmetatable({ pending = {}, latest = {} }, Assembler) end

local function join(kind, got, parts)
  local whole = shallow(got[1])
  local listField = LIST[kind]
  local l = {}
  for i = 1, parts do
    if kind == "describe" then
      for k, v in pairs(got[i].metrics or {}) do l[k] = v end
    else
      for _, v in ipairs(got[i].samples or {}) do l[#l + 1] = v end
    end
  end
  whole[listField], whole.part, whole.parts = l, 1, 1
  return whole
end

function Assembler:add(msg, now)
  if msg.kind == "hello" then return msg end
  local key = msg.node .. "\0" .. msg.kind
  local sid = msg.sid or msg.seq

  -- Remember the newest (boot, sid) per node and kind; older parts are late and useless.
  local last = self.latest[key]
  if last and last.boot == msg.boot and sid < last.sid then return nil end
  self.latest[key] = { boot = msg.boot, sid = sid }

  local parts = msg.parts or 1
  if parts == 1 then self.pending[key] = nil; return msg end

  local p = self.pending[key]
  if p and (p.boot ~= msg.boot or p.sid ~= sid or now - p.first > p.ttl) then p = nil end
  if not p then
    p = { boot = msg.boot, sid = sid, parts = parts, got = {}, count = 0, first = now, ttl = 10 }
    self.pending[key] = p
  end
  if msg.part == 1 and type(msg.interval) == "number" and msg.interval > 0 then p.ttl = msg.interval end
  if p.got[msg.part] then return nil end
  p.got[msg.part], p.count = msg, p.count + 1
  if p.count < p.parts then return nil end
  self.pending[key] = nil
  return join(msg.kind, p.got, p.parts)
end

return codec
