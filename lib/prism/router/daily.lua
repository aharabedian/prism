--[[ prism.router.daily: each process's last 24 hours, one slot per 10 minutes, kept in <base>-history.cfg across
  restarts: the backlog at the end of each slot and the items out during it (prism.router.flow's counts).

  Daily.open(path, log) -> d
  d:add(t, proc, backlog, out)   t: real time (prism.clock); the slot is t // SLOT
  d:values(proc, t) -> backlog[], out[]   SLOTS values each, oldest first, ending with the slot of t;
                                           false where nothing was recorded
  d:save(t) -> saved?            writes the file when the slot has moved on since the last save (so once every
                                 10 minutes), dropping slots older than 24 hours; d:save() always (on exit)
  Daily.SLOT = 600, Daily.SLOTS = 144
  File: { [process] = { [slot] = { backlog, out } } }. About 3 KB per process on the router.
]]

local files = require("prism.files")

local Daily = { SLOT = 600, SLOTS = 144 }
Daily.__index = Daily

function Daily.open(path, log)
  local data = files.readTable(path)
  if type(data) ~= "table" then data = {} end
  return setmetatable({ path = path, log = log, data = data, savedSlot = nil, dirty = false }, Daily)
end

function Daily:add(t, proc, backlog, out)
  local slot = math.floor(t / Daily.SLOT)
  local p = self.data[proc] or {}
  self.data[proc] = p
  local s = p[slot] or { 0, 0 }
  p[slot] = s
  s[1], s[2] = backlog, s[2] + (out or 0)
  self.dirty = true
end

function Daily:values(proc, t)
  local last = math.floor(t / Daily.SLOT)
  local p = self.data[proc] or {}
  local backlog, out = {}, {}
  for i = 1, Daily.SLOTS do
    local s = p[last - Daily.SLOTS + i]
    backlog[i], out[i] = s and s[1] or false, s and s[2] or false
  end
  return backlog, out
end

function Daily:save(t)
  if not self.dirty then return false end
  local slot = t and math.floor(t / Daily.SLOT)
  if t and self.savedSlot == slot then return false end
  if slot then
    local oldest = slot - Daily.SLOTS
    for proc, p in pairs(self.data) do
      for k in pairs(p) do if k <= oldest then p[k] = nil end end
      if next(p) == nil then self.data[proc] = nil end
    end
  end
  local ok, err = files.writeTable(self.path, self.data)
  if not ok and self.log then self.log("can't save %s: %s", self.path, tostring(err)) end
  self.savedSlot, self.dirty = slot or self.savedSlot, false
  return ok
end

return Daily
