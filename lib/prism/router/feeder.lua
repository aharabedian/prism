--[[ prism.router.feeder: ME Interface -> transposer -> machine, moving exact multiples of an
  item's batch size. Implements the output interface in prism.router.outputs.

  Config: { interface, transposer, interfaceSide, machineSide, process, slot?, name? }
  (sides relative to the transposer). The interface slot is configured from a database entry.

  Each step:
    1. read the machine's inventory and the interface's stock through the transposer
    2. pick the item already in the machine (top it up), else the first queued item with a full batch
    3. if the interface isn't stocking it, reconfigure it and wait a step for stock
    4. move floor(min(stock, room) / batch) * batch
  A machine holding a non-multiple of the batch is reported "blocked" instead of fed.

  feeder.state   "starting" | "idle" | "stocking" | "feeding" | "waiting for stock" | "machine full"
                 | "machine not accepting" | "blocked: ..." | "warning: ..." | "error: ..."
  feeder.label, feeder.batch   what it's feeding now
]]

local U        = require("prism.util")
local protocol = require("prism.protocol")

local Feeder = { kind = "feeder", takesBatches = true, statusList = "feeders" }
Feeder.__index = Feeder

-- Point the interface slot at an item (stocking a full stack), or clear it (key = nil).
function Feeder:setIface(key, stack)
  local env, db = self.env, self.env.db
  local ok, res
  if key then
    local entry, err = db:stage(key, stack)
    if not entry then return false, err end
    ok, res = pcall(self.iface.setInterfaceConfiguration, self.slot, db.address, entry,
                    math.min(64, stack.maxSize or 64))
  else
    ok, res = pcall(self.iface.setInterfaceConfiguration, self.slot, db.address, db.emptySlot)
  end
  if not ok then return false, tostring(res) end
  self.item = key
  env.stats.writes = env.stats.writes + 1
  if env.cfg.verbose then env.log("%s interface -> %s", self.name, key and (env.labelOf(key) or key) or "(cleared)") end
  return true
end

function Feeder.open(spec, i, env)
  local name = spec.name or ((spec.process or "?") .. " feeder #" .. i)
  if not spec.process then error(name .. ": no process", 0) end
  local iface = env.proxyOf("me_interface", spec.interface)
  if not iface then error(("%s: no me_interface matching %q"):format(name, tostring(spec.interface)), 0) end
  local tp = env.proxyOf("transposer", spec.transposer)
  if not tp then error(("%s: no transposer matching %q"):format(name, tostring(spec.transposer)), 0) end
  for _, s in ipairs({ { spec.interfaceSide, "interfaceSide" }, { spec.machineSide, "machineSide" } }) do
    local okSize, n = pcall(tp.getInventorySize, s[1])
    if not okSize or type(n) ~= "number" then
      error(("%s: transposer sees no inventory on %s (%s)"):format(name, s[2], U.sideName(s[1])), 0)
    end
  end
  local f = setmetatable({ iface = iface, tp = tp, ifaceSide = spec.interfaceSide, machineSide = spec.machineSide,
                           process = spec.process, name = name, slot = spec.slot or 1, env = env,
                           item = "?", fed = 0, state = "starting",
                           claims = { { address = iface.address, slot = spec.slot or 1 } } }, Feeder)
  local ok, err = f:setIface(nil)
  if not ok then error(name .. ": can't configure the interface: " .. tostring(err), 0) end
  return f
end

-- { [key] = { size, label } } in the machine, or nil + reason.
function Feeder:machineContents()
  local n = self.tp.getInventorySize(self.machineSide)
  if type(n) ~= "number" then return nil, "can't see the machine" end
  local out = {}
  for s = 1, n do
    local st = self.tp.getStackInSlot(self.machineSide, s)
    if st and st.name then
      local k = U.keyOf(st)
      local e = out[k] or { size = 0, label = st.label }
      e.size = e.size + (st.size or 0)
      out[k] = e
    end
  end
  return out
end

function Feeder:feed(q)
  local machine, err = self:machineContents()
  if not machine then self.state = "error: " .. err; return end
  local stock = self.tp.getStackInSlot(self.ifaceSide, self.slot)
  local stockKey  = stock and stock.name and U.keyOf(stock) or nil
  local stockSize = stock and stock.size or 0

  -- Prefer whatever is already in the machine (top it up), then queue order.
  local pick
  for _, e in ipairs(q) do
    if machine[e.key] then pick = e; break end
  end
  if not pick then
    for _, e in ipairs(q) do
      local have = e.size + ((stockKey == e.key) and stockSize or 0)
      if have >= e.batch then pick = e; break end
    end
  end

  if not pick then
    if self.item then self:setIface(nil) end
    self.state, self.label, self.batch = "idle", nil, nil
    return
  end
  self.label, self.batch = pick.label, pick.batch

  local inMachine = machine[pick.key] and machine[pick.key].size or 0
  if inMachine % pick.batch ~= 0 then
    self.state = ("blocked: %d in machine, not a multiple of %d"):format(inMachine, pick.batch)
    return
  end

  if self.item ~= pick.key then
    local ok, e2 = self:setIface(pick.key, pick.stack)
    if not ok then self.state = "error: " .. tostring(e2); return end
    self.state = "stocking"              -- the interface needs a moment to pull stock
    return
  end

  local avail = (stockKey == pick.key) and stockSize or 0
  local room = (pick.stack.maxSize or 64) - inMachine
  local amount = math.floor(math.min(avail, room) / pick.batch) * pick.batch
  if amount <= 0 then
    self.state = (room < pick.batch) and "machine full" or "waiting for stock"
    return
  end

  local moved = tonumber((self.tp.transferItem(self.ifaceSide, self.machineSide, amount, self.slot))) or 0
  if moved == 0 then self.state = "machine not accepting"; return end
  self.fed = self.fed + moved
  if moved % pick.batch ~= 0 then
    self.state = ("warning: only %d of %d went in"):format(moved, amount)
    self.env.stats.lastError = self.name .. ": partial insert (" .. moved .. " of " .. amount .. ")"
    self.env.log("%s", self.env.stats.lastError)
  else
    self.state = "feeding"
  end
end

function Feeder:step(queue)
  local ok, err = pcall(self.feed, self, queue)
  if not ok then self.state = "error: " .. tostring(err) end
end

function Feeder.apply() end   -- feeders work between scans, in step()

function Feeder:status()
  return { name = self.name, process = self.process, state = self.state, level = protocol.feederLevel(self.state),
           label = self.label, batch = self.batch, fed = self.fed }
end

function Feeder:alert()
  if protocol.feederLevel(self.state) == "bad" then
    return { id = "feeder:" .. self.name, level = "bad", text = self.name .. ": " .. self.state }
  end
end

function Feeder:close() pcall(self.setIface, self, nil) end

return Feeder
