--[[ prism.clock: real time, so the event log keeps its dates across restarts. OpenComputers has no wall clock
  (os.time is the game's), but a file's modification time is real (seen in game in LUMEN): the clock writes a
  small file and reads its lastModified back.

  Clock.new(filesystem, path) -> c
    filesystem   OpenOS's (its lastModified, in milliseconds); path: the file it writes
  c:at(now) -> seconds since 1970 (UTC) at uptime `now` (computer.uptime). Read from the file the first time and
               once an hour after, carried on with uptime in between. Without a usable time (lastModified 0 or
               failing, the file not writable): `now` itself, and c.real is false
  c.real
]]

local Clock = { RESYNC = 3600 }
Clock.__index = Clock

function Clock.new(filesystem, path)
  return setmetatable({ fs = filesystem, path = path, real = false }, Clock)
end

function Clock:sync(now)
  local ms
  local f = self.path and io.open(self.path, "w")
  if f then
    f:write("prism clock\n")
    f:close()
    local ok, v = pcall(function() return self.fs.lastModified(self.path) end)
    if ok and type(v) == "number" and v > 0 then ms = v end
  end
  self.real = ms ~= nil
  self.base, self.syncedAt = ms and ms / 1000 or now, now
end

function Clock:at(now)
  if not self.syncedAt or now - self.syncedAt >= Clock.RESYNC then self:sync(now) end
  return self.base + (now - self.syncedAt)
end

return Clock
