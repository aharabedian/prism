--[[ prism.router.exportbus: an AE2 export bus whose filter the router rewrites.
  Implements the output interface in prism.router.outputs.

  Config: { address, side, process, name? }. Filters are set from a database entry, so a database
  is required. Export buses can't send exact amounts, so they only take batch-1 items: the top
  cfg.slotsPerBus of them.
]]

local U     = require("prism.util")
local slots = require("prism.router.slots")

local Bus = { kind = "bus", takesBatches = false, statusList = "buses" }
Bus.__index = Bus

-- The filter stack, false for an empty slot, or nil + reason if there's no export bus on that
-- side (the driver either throws or returns nil, msg).
local function readSlot(proxy, side, slot)
  local ok, stack, err = pcall(proxy.getExportConfiguration, side, slot)
  if not ok then return nil, tostring(stack) end
  if stack == nil and err then return nil, tostring(err) end
  return stack or false
end

function Bus.open(spec, i, env)
  if not spec.process then error(("bus #%d has no process"):format(i), 0) end
  local p = env.proxyOf("me_exportbus", spec.address)
  if not p then error(("bus #%d: no me_exportbus matching %q"):format(i, tostring(spec.address)), 0) end
  local bus = setmetatable({ proxy = p, side = spec.side, process = spec.process, env = env,
                             name = spec.name or (spec.process .. "#" .. i), size = env.cfg.slotsPerBus, slots = {} }, Bus)
  for s = 1, bus.size do
    local st, err = readSlot(p, spec.side, s)
    if st == nil then error(("bus %s (side %s): %s"):format(bus.name, U.sideName(spec.side), err), 0) end
    bus.slots[s] = st and U.keyOf(st) or false
  end
  return bus
end

function Bus:write(slot, e)
  local db = self.env.db
  local entry = db.emptySlot
  if e then
    local err
    entry, err = db:stage(e.key, e.stack)
    if not entry then return false, err end
  end
  local ok, res = pcall(self.proxy.setExportConfiguration, self.side, slot, db.address, entry)
  if not ok then return false, tostring(res) end
  self.slots[slot] = e and e.key or false
  self.env.stats.writes = self.env.stats.writes + 1
  if self.env.cfg.verbose then self.env.log("%s slot %d -> %s", self.name, slot, e and (e.label or e.key) or "(cleared)") end
  return true
end

function Bus:apply(queue)
  local wanted = {}
  for _, e in ipairs(queue) do
    if #wanted >= self.size then break end
    if e.batch == 1 then wanted[#wanted + 1] = e end
  end
  local ok, err = slots.apply(self.slots, self.size, wanted, function(s, e) return self:write(s, e) end)
  if not ok then
    self.env.stats.lastError = self.name .. ": " .. tostring(err)
    self.env.log("%s", self.env.stats.lastError)
  end
end

-- Shared with stockers: the row in router-status's `buses`.
function Bus.statusRow(o, labels, kind)
  local filters = {}
  for i = 1, o.size do
    local k = o.slots[i]
    if k then filters[#filters + 1] = labels[k] or k end
  end
  return { name = o.name, process = o.process, filters = filters, kind = kind }
end

function Bus:status(labels) return Bus.statusRow(self, labels, nil) end
function Bus.step() end
function Bus.alert() return nil end
function Bus.close() end

return Bus
