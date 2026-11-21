--[[ prism.router.events: the router's event log, kept in <base>-log.cfg across restarts.

  Events.open(path, log) -> ev
  ev:add(entry)                  entry = { at, kind, text, level?, lasted?, player?, process? }
    at       seconds since 1970 (prism.clock), or uptime when the clock isn't real
    kind     "alert" (started), "ended" (an alert ended; lasted = seconds), "share" (sharing with fallbacks on
             or off), "hold", "edit" (a change made on a screen), "start", "stop" (the router)
  ev:page(offset, n, filter?) -> total, list   newest first; filter "alerts" (alert, ended) or "changes" (the rest)
  ev:save(now) -> saved?         writes the file when something was added, at most once a minute (now = uptime);
  ev:save()                      always, when something was added (on exit)
  ev.added                       entries added since the router started (router-status carries it as `events`,
                                 so a screen knows when to fetch the log again)
  Events.KEEP = 300              the oldest entries go first
]]

local files = require("prism.files")

local Events = { KEEP = 300, EVERY = 60 }
Events.__index = Events

function Events.open(path, log)
  local list = files.readTable(path)
  if type(list) ~= "table" then list = {} end
  return setmetatable({ path = path, log = log, list = list, dirty = false, savedAt = nil, added = 0 }, Events)
end

function Events:add(entry)
  local l = self.list
  l[#l + 1] = entry
  while #l > Events.KEEP do table.remove(l, 1) end
  self.dirty, self.added = true, self.added + 1
end

local ALERTS = { alert = true, ended = true }

function Events:page(offset, n, filter)
  local picked = {}
  for i = #self.list, 1, -1 do
    local e = self.list[i]
    if not filter or (filter == "alerts") == (ALERTS[e.kind] == true) then picked[#picked + 1] = e end
  end
  local out = {}
  for i = offset + 1, math.min(#picked, offset + n) do out[#out + 1] = picked[i] end
  return #picked, out
end

function Events:save(now)
  if not self.dirty then return false end
  if now and self.savedAt and now - self.savedAt < Events.EVERY then return false end
  local ok, err = files.writeTable(self.path, self.list)
  if not ok and self.log then self.log("can't save %s: %s", self.path, tostring(err)) end
  self.dirty, self.savedAt = false, now or self.savedAt
  return ok
end

return Events
