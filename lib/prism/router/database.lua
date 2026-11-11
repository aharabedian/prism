--[[ prism.router.database: staging items in a Database Upgrade.

  Export bus filters and interface configs can only be set from a database entry, so an item
  is store()d from the network into a slot first. The bus or interface keeps its own copy, so
  slots are reused round-robin and the database never fills up. The last slot stays empty and
  is used to clear configs.

  Database.open(proxy, net) -> db      clears every slot; raises if the size can't be worked out
  db.address, db.size, db.emptySlot
  db:stage(key, stack) -> slot | nil, reason
]]

local U = require("prism.util")

local Database = {}
Database.__index = Database

function Database.open(proxy, net)
  local size
  for _, n in ipairs({ 81, 25, 9 }) do
    if pcall(proxy.get, n) then size = n; break end
  end
  if not size then error("couldn't work out the database size", 0) end
  for s = 1, size do pcall(proxy.clear, s) end
  return setmetatable({ proxy = proxy, net = net, address = proxy.address, size = size, emptySlot = size,
                        slotOf = {}, keyIn = {}, nextSlot = 1 }, Database)
end

function Database:stage(key, stack)
  local s = self.slotOf[key]
  if s then return s end
  s = self.nextSlot
  self.nextSlot = s % (self.size - 1) + 1
  if self.keyIn[s] then self.slotOf[self.keyIn[s]] = nil; self.keyIn[s] = nil end
  self.proxy.clear(s)
  self.net.store({ name = stack.name, damage = stack.damage }, self.address, s, 1)
  local got = self.proxy.get(s)
  if not got or U.keyOf(got) ~= key then
    return nil, "store() didn't put " .. key .. " into the database"
  end
  self.slotOf[key], self.keyIn[s] = s, key
  return s
end

return Database
