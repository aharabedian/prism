--[[ tests/mocks/oc.lua - a small OpenComputers + AE2 + GregTech world for tests

  require("oc") installs fake versions of the OpenOS libraries the programs use
  (component, computer, event, serialization, sides, unicode, term, filesystem,
  internet) through package.preload, then returns a handle for the test to
  drive and inspect:

    M.items                 the ME network contents: { name, damage, label, size }
    M.busHosts[addr][side]  export bus filter slots, per cable block and side
    M.dbSlots               the Database Upgrade's slots
    M.proxies[addr]         every component; add your own (machines, transposers...)
    M.machine(addr, fields) add a gt_machine whose methods return `fields` values
    M.stocker(addr, opts)   add a GT Stocking Input Bus (me_inputbus); returns { slots, autoPull }
    M.iface(addr, opts)     add an ME Interface block; returns { config, stock, exported, restock(), drain() }
    M.web[url] = text       content served by internet.request (missing -> HTTP 404,
                            { status = N } -> HTTP N); M.requests logs every request
    M.onPull(n)             called on every event.pullMultiple; return an event
                            table to deliver it, or nil to let time pass
    M.sent                  every modem send/broadcast: { to, port, data }
    M.row(y), M.find(text, minY, minX), M.dump(path)
                            read the 160x50 screen the GPU drew
    M.oob, M.beeps, M.cleared, M.setCalls

  Time only moves when a program waits: pullMultiple(timeout) with no event
  advances computer.uptime() by `timeout`. Returning an event doesn't.
  The mock mirrors the real APIs as far as we know them; docs/architecture.md
  lists which calls have been verified in-game.
]]

local M = { setCalls = 0, sent = {}, pulls = 0, oob = 0, beeps = 0, web = {} }

-- In game, math.random(1, 0x7fffffff) returned a number that wasn't an integer (math.type ~= "integer"),
-- which crashed the LENS reporting (2026-11-12). Mirror that: every result is a float.
local realRandom = math.random
math.random = function(m, n) -- luacheck: ignore 122
  if m == nil then return realRandom() end
  return realRandom(m, n or m) + 0.0
end

---------------------------------------------------------------- serialization
-- Round-trips like OpenOS serialization (non-pretty mode).
local function ser(v)
  local t = type(v)
  if t == "table" then
    local parts = {}
    for k, x in pairs(v) do
      local ks = type(k) == "string" and string.format("[%q]", k) or "[" .. tostring(k) .. "]"
      parts[#parts + 1] = ks .. "=" .. ser(x)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif t == "string" then
    return string.format("%q", v)
  else
    return tostring(v)
  end
end
local serialization = {
  serialize = ser,
  unserialize = function(s)
    local f = load("return " .. s, "=ser", "t", {})
    if not f then return nil end
    local ok, r = pcall(f)
    return ok and r or nil
  end,
}
M.serialization = serialization

local sides = { down = 0, bottom = 0, up = 1, top = 1, north = 2, south = 3, west = 4, east = 5 }

---------------------------------------------------------------- ME network + database
M.items = {}
local function findItem(name, damage)
  for _, it in ipairs(M.items) do if it.name == name and it.damage == damage then return it end end
end

local DB_SIZE = 25
local dbSlots = {}
M.dbSlots = dbSlots
local database = {
  address = "db000000-aaaa", type = "database",
  get = function(s)
    if s < 1 or s > DB_SIZE then error("invalid slot") end
    return dbSlots[s]
  end,
  clear = function(s)
    if s < 1 or s > DB_SIZE then error("invalid slot") end
    local had = dbSlots[s] ~= nil
    dbSlots[s] = nil
    return had
  end,
}

local controller = {
  address = "me000000-cccc", type = "me_controller",
  getItemsInNetwork = function()
    local out = { n = #M.items }
    for i, it in ipairs(M.items) do
      out[i] = { name = it.name, damage = it.damage + 0.0, label = it.label, size = it.size, maxSize = 64, hasTag = false }
    end
    return out
  end,
  store = function(filter, dbAddr, startSlot)
    assert(dbAddr == database.address, "bad db address")
    local it = findItem(filter.name, math.floor(filter.damage))
    if not it then return false end
    dbSlots[startSlot] = { name = it.name, damage = it.damage + 0.0, label = it.label, size = 1, maxSize = 64 }
    return true
  end,
}

---------------------------------------------------------------- export buses
-- Two cable blocks: eb11 has buses on north (2) and south (3), eb22 on up (1).
M.busHosts = {
  ["eb111111-1111"] = { [2] = {}, [3] = {} },
  ["eb222222-2222"] = { [1] = {} },
}
local function busProxy(addr)
  local host = M.busHosts[addr]
  return {
    address = addr, type = "me_exportbus",
    getExportConfiguration = function(side, slot)
      local b = host[side]
      if not b then return nil, "no export bus" end
      slot = slot or 1
      if slot < 1 or slot > 9 then error("invalid slot") end
      return b[slot]
    end,
    setExportConfiguration = function(side, slot, dbAddr, entry)
      local b = host[side]
      if not b then return nil, "no export bus" end
      assert(dbAddr == database.address, "bad db address")
      local st = dbSlots[entry]
      b[slot] = st and { name = st.name, damage = st.damage, label = st.label } or nil
      M.setCalls = M.setCalls + 1
      return true
    end,
  }
end

---------------------------------------------------------------- modem
local modem = {
  address = "mo000000-mmmm", type = "modem",
  isWireless = function() return true end,
  maxPacketSize = function() return 8192 end,
  open = function() return true end,
  close = function() return true end,
  broadcast = function(port, data) M.sent[#M.sent + 1] = { to = "*", port = port, data = data } end,
  send = function(to, port, data) M.sent[#M.sent + 1] = { to = to, port = port, data = data } end,
}

local proxies = { [database.address] = database, [controller.address] = controller, [modem.address] = modem }
for addr in pairs(M.busHosts) do proxies[addr] = busProxy(addr) end
M.proxies = proxies

-- A gt_machine whose methods return the current value of fields[method].
-- Set fields.broken = true to make every call throw (unloaded chunk).
function M.machine(addr, fields)
  proxies[addr] = setmetatable({ address = addr, type = "gt_machine" }, { __index = function(_, k)
    local v = fields[k]
    if v == nil then return nil end
    return function()
      if fields.broken then error("chunk unloaded") end
      if type(v) == "function" then return v() end
      return v
    end
  end })
  return fields
end

---------------------------------------------------------------- ME interface blocks
-- An ME Interface block (component "me_interface") with 9 config slots. setInterfaceConfiguration(slot,
-- database, entry, size) stocks the item in that database entry (size defaults to 64); an empty entry
-- clears the slot. Slots outside 1..9 throw. getInterfaceConfiguration(slot) returns the configured item. Returns { config, stock, exported } plus:
--   restock()  the interface pulls each configured item from the subnet (M.items) up to its size, and
--              hands back stock that is no longer configured
--   drain()    an import bus on another network takes everything stocked (counted in `exported`)
-- opts.broken: every call throws (chunk unloaded).
function M.iface(addr, opts)
  opts = opts or {}
  local i = { config = {}, stock = {}, exported = {} }
  local function key(t) return t.name .. ":" .. math.floor(t.damage) end
  local function giveBack(st)
    local it = findItem(st.name, math.floor(st.damage))
    if it then it.size = it.size + st.size
    else M.items[#M.items + 1] = { name = st.name, damage = math.floor(st.damage), label = st.label, size = st.size } end
  end
  function i.restock()
    for slot = 1, 9 do
      local c, st = i.config[slot], i.stock[slot]
      if st and (not c or key(c) ~= key(st)) then giveBack(st); i.stock[slot], st = nil, nil end
      if c then
        local it = findItem(c.name, math.floor(c.damage))
        local have = st and st.size or 0
        if it and have < c.want then
          local take = math.min(c.want - have, it.size)
          it.size = it.size - take
          for n, x in ipairs(M.items) do if x == it and x.size == 0 then table.remove(M.items, n) end end
          i.stock[slot] = { name = c.name, damage = c.damage, label = c.label, size = have + take }
        end
      end
    end
  end
  function i.drain()
    for slot, st in pairs(i.stock) do
      i.exported[key(st)] = (i.exported[key(st)] or 0) + st.size
      i.stock[slot] = nil
    end
  end
  proxies[addr] = {
    address = addr, type = "me_interface",
    getInterfaceConfiguration = function(slot)
      if opts.broken then error("chunk unloaded") end
      local c = i.config[slot or 1]
      return c and { name = c.name, damage = c.damage + 0.0, label = c.label, size = c.want, maxSize = 64 } or nil
    end,
    setInterfaceConfiguration = function(slot, dbAddr, entry, size)
      if opts.broken then error("chunk unloaded") end
      if math.type(slot) == nil or slot < 1 or slot > 9 then error("invalid slot") end
      assert(dbAddr == database.address, "bad db address")
      local st = dbSlots[entry]
      i.config[slot] = st and { name = st.name, damage = st.damage, label = st.label, want = size or 64 } or nil
      M.setCalls = M.setCalls + 1
      return true
    end,
  }
  return i
end

---------------------------------------------------------------- GT stocking input buses
-- A Stocking Input Bus (ME), component "me_inputbus" (GTNewHorizons/OpenComputers #222).
-- 16 slots, 1-based. setConfiguration(slot, {name, damage}) sets a slot (the table is parsed like an
-- OC item stack: name or id required, unknown items throw), setConfiguration(slot) clears it, and
-- getConfiguration returns an OC item table or nil. Returns the slot table for tests to inspect.
-- opts.advanced: has auto-pull (on unless opts.autoPull == false). opts.broken: every call throws.
function M.stocker(addr, opts)
  opts = opts or {}
  local slots, SLOTS = {}, 16
  local s = { slots = slots, autoPull = opts.advanced and opts.autoPull ~= false or false }
  local function live() if opts.broken then error("chunk unloaded") end end
  local function check(slot)
    live()
    if math.type(slot) == nil or slot < 1 or slot > SLOTS then error("invalid slot") end
  end
  proxies[addr] = {
    address = addr, type = "me_inputbus",
    getSlotSize = function() live(); return SLOTS end,
    isAdvanced = function() live(); return opts.advanced == true end,
    getAutoPull = function() live(); return s.autoPull end,
    setAutoPull = function(on) live(); if opts.advanced then s.autoPull = on end; return true end,
    getConfiguration = function(slot)
      check(slot)
      local c = slots[slot]
      return c and { name = c.name, damage = c.damage, label = c.label, size = 1, maxSize = 64, hasTag = false } or nil
    end,
    setConfiguration = function(slot, detail)
      check(slot)
      if detail == nil then slots[slot] = nil; M.setCalls = M.setCalls + 1; return true end
      if type(detail) ~= "table" then error("bad argument #2 (table expected)") end
      if not detail.name then error("item id or name expected") end
      local damage = math.floor(detail.damage or 0)
      local it = findItem(detail.name, damage)
      slots[slot] = { name = detail.name, damage = damage, label = it and it.label or detail.name }
      M.setCalls = M.setCalls + 1
      return true
    end,
  }
  return s
end

---------------------------------------------------------------- GPU + screen
local GW, GH, buf, fgb, bgb
-- A blank w x h screen (160x50 = tier 3, 80x25 = tier 2). The GPU's maxResolution follows it.
function M.resize(w, h)
  GW, GH = w, h
  M.W, M.H = GW, GH
  buf, fgb, bgb = {}, {}, {}
  for y = 1, GH do
    buf[y], fgb[y], bgb[y] = {}, {}, {}
    for x = 1, GW do buf[y][x], fgb[y][x], bgb[y][x] = " ", 0xffffff, 0 end
  end
  M.buf, M.fgb, M.bgb = buf, fgb, bgb
end
M.resize(160, 50)
local cf, cb = 0xffffff, 0
local function cell(x, y, ch)
  if x >= 1 and x <= GW and y >= 1 and y <= GH then
    buf[y][x], fgb[y][x], bgb[y][x] = ch, cf, cb
  else
    M.oob = M.oob + 1
    M.oobAt = M.oobAt or (x .. "," .. y .. " '" .. ch .. "'")
  end
end
local gpu = {
  address = "gp000000", type = "gpu",
  maxResolution = function() return GW, GH end,
  setResolution = function() return true end,
  setForeground = function(c) local o = cf; cf = c; return o end,
  setBackground = function(c) local o = cb; cb = c; return o end,
  set = function(x, y, s)
    assert(type(s) == "string", "gpu.set needs a string")
    local i = 0
    for _, cp in utf8.codes(s) do cell(x + i, y, utf8.char(cp)); i = i + 1 end
    return true
  end,
  fill = function(x, y, w, h, ch)
    assert(utf8.len(ch) == 1, "fill char must be 1 char")
    for yy = y, y + h - 1 do for xx = x, x + w - 1 do cell(xx, yy, ch) end end
    return true
  end,
}

function M.row(y) return table.concat(buf[y]) end

-- First occurrence of `text` (plain) at or below row minY, at or right of column minX.
function M.find(text, minY, minX)
  minX = minX or 1
  for y = minY or 1, GH do
    local r = table.concat(buf[y], "", minX)
    local i = r:find(text, 1, true)
    if i then return utf8.len(r:sub(1, i - 1)) + minX, y end
  end
end

-- A "size<TAB>W<TAB>H" line, then one "char<TAB>fg<TAB>bg" line per cell; tools/render_screens.py
-- turns it into a PNG.
function M.dump(path)
  local f = assert(io.open(path, "w"))
  f:write(string.format("size\t%d\t%d\n", GW, GH))
  for y = 1, GH do
    for x = 1, GW do f:write(string.format("%s\t%06x\t%06x\n", buf[y][x], fgb[y][x], bgb[y][x])) end
  end
  f:close()
end

---------------------------------------------------------------- OpenOS libraries
local component = {
  gpu = gpu,
  modem = modem,
  isAvailable = function(t)
    if t == "gpu" then return true end
    for _, p in pairs(proxies) do if p.type == t then return true end end
    return false
  end,
  list = function(ctype)
    local keys = {}
    for addr, p in pairs(proxies) do if not ctype or p.type == ctype then keys[#keys + 1] = addr end end
    table.sort(keys)
    local i = 0
    return function()
      i = i + 1
      local a = keys[i]
      if a then return a, proxies[a].type end
    end
  end,
  get = function(prefix, ctype)
    for addr, p in pairs(proxies) do
      if addr:sub(1, #prefix) == prefix and (not ctype or p.type == ctype) then return addr end
    end
    return nil, "no such component"
  end,
  proxy = function(addr) return proxies[addr] end,
}

local clock = 0
local computer = {
  uptime = function() return clock end,
  beep = function() M.beeps = M.beeps + 1 end,
}

local event = {
  pullMultiple = function(timeout)
    M.pulls = M.pulls + 1
    if M.onPull then
      local ev = M.onPull(M.pulls)
      if ev then return table.unpack(ev) end
    end
    clock = clock + timeout
    return nil
  end,
}

local unicode = {
  len = function(s) return utf8.len(s) end,
  sub = function(s, i, j)
    local n = utf8.len(s)
    j = j or n
    if i < 0 then i = n + i + 1 end
    if j < 0 then j = n + j + 1 end
    if i < 1 then i = 1 end
    if j > n then j = n end
    if i > j then return "" end
    local a, b = utf8.offset(s, i), utf8.offset(s, j + 1)
    return s:sub(a, b and b - 1 or #s)
  end,
}

local function sh(cmd) local ok = os.execute(cmd); return ok == true or ok == 0 end
local filesystem = {
  exists = function(p) return sh('test -e "' .. p .. '"') end,
  makeDirectory = function(p) return sh('mkdir -p "' .. p .. '"') end,
  remove = function(p) return os.remove(p) end,
  rename = function(a, b) return os.rename(a, b) end,
}

-- Like OpenOS internet.request: a callable handle that yields the body; reads of an HTTP error
-- throw (Java's message is the URL) and handle.response() gives code, message, headers.
-- M.web[url] = text serves 200; { status = 500 } serves that status; missing = 404.
-- Every request is logged in M.requests as { url, headers }.
M.requests = {}
local internet = {
  request = function(url, _, headers)
    M.requests[#M.requests + 1] = { url = url, headers = headers }
    local body = M.web[url]
    local status = body == nil and 404 or (type(body) == "table" and body.status) or 200
    local done = false
    return setmetatable({
      response = function() return status, status == 200 and "OK" or "Error", {} end,
      close = function() end,
    }, { __call = function()
      if status ~= 200 then error(url) end
      if done then return nil end
      done = true
      return body
    end })
  end,
}

package.preload.component     = function() return component end
package.preload.computer      = function() return computer end
package.preload.event         = function() return event end
package.preload.serialization = function() return serialization end
package.preload.sides         = function() return sides end
package.preload.unicode       = function() return unicode end
package.preload.term          = function() return { clear = function() M.cleared = true end } end
package.preload.filesystem    = function() return filesystem end
package.preload.internet      = function() return internet end

return M
