--[[ prism.protocol: the wire format between the router and the control screen.
  The messages themselves are documented in docs/protocol.md.

  DEFAULT_PORT        modemPort when a config doesn't set one
  PAGE                rows per router-items / router-preview reply
  UNASSIGNED_TOP      unassigned items carried in router-status
  encode(msg, max)    serialize msg into at most `max` bytes -> data | nil.
                      Too big: drops rows from msg.unassigned (or msg.list) and sets
                      truncated = true, then drops buses[].filters. Never changes msg itself.
  decode(data)        -> table | nil
  feederLevel(state)  "ok" | "idle" | "warn" | "bad" for a feeder state string. The router
                      sends it as feeders[].level; the screen falls back to this for older routers.
]]

local serialization = require("serialization")
local U = require("prism.util")

local P = {}

P.DEFAULT_PORT   = 4242
P.PAGE           = 40
P.UNASSIGNED_TOP = 25

function P.encode(msg, max)
  local data = serialization.serialize(msg)
  if #data <= max then return data end
  local m = U.copy(msg)
  local field = (msg.unassigned and "unassigned") or (msg.list and "list") or nil
  if field then
    m[field] = U.copy(msg[field])
    local rows = m[field]
    while #data > max and #rows > 0 do
      table.remove(rows)
      m.truncated = true
      data = serialization.serialize(m)
    end
  end
  if #data > max and m.buses then
    local buses = {}
    for i, b in ipairs(m.buses) do
      buses[i] = U.copy(b)
      buses[i].filters = nil
    end
    m.buses = buses
    data = serialization.serialize(m)
  end
  if #data > max then return nil end
  return data
end

function P.decode(data)
  if type(data) ~= "string" then return nil end
  local msg = serialization.unserialize(data)
  return type(msg) == "table" and msg or nil
end

function P.feederLevel(state)
  state = state or ""
  if state == "feeding" then return "ok" end
  if state == "idle" then return "idle" end
  if state:find("^blocked") or state:find("^error") or state:find("^warning") then return "bad" end
  return "warn"
end

return P
