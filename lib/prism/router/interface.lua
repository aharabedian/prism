--[[ prism.router.interface: an ME Interface block that another network pulls from.
  Implements the output interface in prism.router.outputs.

  Config: { address, process, name?, slots? }. The interface sits on the subnet; an import bus on the
  other network faces it and takes whatever it stocks, and the interface restocks from the subnet.
  Each of its first `slots` (default 9) config slots stocks a full stack of one of the process's top
  items. Like export buses, only batch-1 items: the import bus takes any amount. Slots are set from a
  database entry, so a database is required. All slots are cleared when the router starts and stops,
  so nothing left over from before is stocked and the stock goes back to the subnet.
]]

local slots = require("prism.router.slots")
local Bus   = require("prism.router.exportbus")

local Interface = { kind = "interface", takesBatches = false, statusList = "buses" }
Interface.__index = Interface

local SLOTS = 9

function Interface.open(spec, i, env)
  if not spec.process then error(("interface #%d has no process"):format(i), 0) end
  local name = spec.name or (spec.process .. " interface #" .. i)
  local p = env.proxyOf("me_interface", spec.address)
  if not p then error(("%s: no me_interface matching %q"):format(name, tostring(spec.address)), 0) end
  if env.net and p.address == env.net.address then
    error(("%s: %s is the network PRISM scans - use another ME interface block"):format(name, p.address:sub(1, 8)), 0)
  end
  local n = math.floor(tonumber(spec.slots) or SLOTS)
  if n < 1 or n > SLOTS then error(("%s: slots must be 1 to %d"):format(name, SLOTS), 0) end
  local o = setmetatable({ proxy = p, process = spec.process, name = name, env = env, size = n, slots = {},
                           claims = {} }, Interface)
  for s = 1, n do
    o.slots[s] = true                                -- unknown: cleared below
    o.claims[s] = { address = p.address, slot = s }
  end
  for s = 1, n do
    local ok, err = o:write(s, nil)
    if not ok then error(("%s: can't configure the interface: %s"):format(name, tostring(err)), 0) end
  end
  return o
end

function Interface:write(slot, e)
  local db = self.env.db
  local ok, res
  if e then
    local entry, err = db:stage(e.key, e.stack)
    if not entry then return false, err end
    ok, res = pcall(self.proxy.setInterfaceConfiguration, slot, db.address, entry, math.min(64, e.stack.maxSize or 64))
  else
    ok, res = pcall(self.proxy.setInterfaceConfiguration, slot, db.address, db.emptySlot)
  end
  if not ok then return false, tostring(res) end
  self.slots[slot] = e and e.key or false
  self.env.stats.writes = self.env.stats.writes + 1
  if self.env.cfg.verbose then self.env.log("%s slot %d -> %s", self.name, slot, e and (e.label or e.key) or "(cleared)") end
  return true
end

function Interface:apply(queue)
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

function Interface:status(labels) return Bus.statusRow(self, labels, "interface") end
function Interface.step() end
function Interface.alert() return nil end

function Interface:close()
  for s = 1, self.size do
    if self.slots[s] then pcall(self.write, self, s, nil) end
  end
end

return Interface
