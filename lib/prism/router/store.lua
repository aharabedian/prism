--[[ prism.router.store: the router's data files, and classifying items with them.

  Files next to prism.cfg (<base> = the config path without .cfg):
    <base>-overrides.cfg  overrides     { [key] = { process, priority?, batch?, label?, by?, at? } }  made on the
                                        screen (by: the player, at: when, prism.clock)
    <base>-items.cfg      catalog       { [key] = { label, seen? } }                         every item ever seen
                                        (seen: when it was first seen, prism.clock)
    <base>-overrides.cfg  (entries may also have fallback)
    <base>-rules.cfg      screenRules   { pattern, process, priority?, batch?, fallback? }[] rules edited on the screen
    <base>-always-share.cfg  alwaysShare  { [process] = true }                             set to ALWAYS SHARE on the screen
    <base>-held.cfg       held          { [process] = { by? } }                              put on HOLD on the screen
    <base>-processes.cfg  processes     { [process] = { overflow } }                         overflow marks set on the screen
    <base>-log.cfg        (prism.router.events reads and writes it: the event log)
    <base>-next.cfg       next          { [key] = { ends, by? } }                            RUN NEXT: first in its
                                        process until `ends` (prism.clock time)

  Store.open(configPath, cfg, log) -> store
  store.overrides, store.catalog, store.screenRules (nil until rules are edited on the screen)
  store:rules()                    the rules in use: screenRules, else cfg.rules
  store:classify(label, key, rules?)  see prism.rules.classify
  store:limits()                   { [process] = { overflow?, alwaysShare?, overflowFrom? } } for planner.spill;
                                   an overflow set on the screen wins over prism.cfg's (overflowFrom "screen" | "cfg")
  store:labelOf(key, fallback)     the catalog label, else fallback
  store:nextLeft(key, now) -> seconds | nil   RUN NEXT time left; store:expireNext(now) drops ended ones
  Store.NEXT_BOOST                 added to the priority of an item set to RUN NEXT
  store:saveOverrides(), store:saveCatalog(), store:saveRules(), store:saveAlwaysShare(), store:saveHeld(),
                                   store:saveProcesses(), store:saveNext()
  store:editableRules()            screenRules, copied from cfg.rules the first time
  store:resetRules()               delete prism-rules.cfg and go back to cfg.rules
]]

local files = require("prism.files")
local rules = require("prism.rules")

local Store = { NEXT_BOOST = 1000000 }
Store.__index = Store

function Store.open(configPath, cfg, log)
  local base = configPath:gsub("%.cfg$", "")
  local s = setmetatable({
    cfg = cfg, log = log,
    paths = { overrides = base .. "-overrides.cfg", catalog = base .. "-items.cfg", rules = base .. "-rules.cfg",
              alwaysShare = base .. "-always-share.cfg", held = base .. "-held.cfg",
              processes = base .. "-processes.cfg", log = base .. "-log.cfg",
              next = base .. "-next.cfg" },
  }, Store)
  s.overrides = files.readTable(s.paths.overrides)
  s.catalog = files.readTable(s.paths.catalog)
  s.alwaysShare = files.readTable(s.paths.alwaysShare)
  s.held = files.readTable(s.paths.held)
  s.processes = files.readTable(s.paths.processes)
  s.next = files.readTable(s.paths.next)
  if files.exists(s.paths.rules) then
    s.screenRules = rules.clean(files.readTable(s.paths.rules), "prism-rules.cfg", log)
  end
  return s
end

function Store:rules() return self.screenRules or self.cfg.rules end

function Store:classify(label, key, list)
  return rules.classify(self.overrides, self.cfg, list or self:rules(), label, key)
end

function Store:limits()
  local out = {}
  for proc, p in pairs(self.cfg.processes) do
    if type(p) == "table" and tonumber(p.overflow) then out[proc] = { overflow = tonumber(p.overflow), overflowFrom = "cfg" } end
  end
  for proc, p in pairs(self.processes) do
    if type(p) == "table" and tonumber(p.overflow) then out[proc] = { overflow = tonumber(p.overflow), overflowFrom = "screen" } end
  end
  for proc, on in pairs(self.alwaysShare) do
    if on then out[proc] = out[proc] or {}; out[proc].alwaysShare = true end
  end
  return out
end

function Store:labelOf(key, fallback)
  return (self.catalog[key] and self.catalog[key].label) or fallback
end

function Store:save(which, t)
  local ok, err = files.writeTable(self.paths[which], t)
  if not ok then self.log("can't save %s: %s", self.paths[which], tostring(err)) end
end

function Store:saveOverrides() self:save("overrides", self.overrides) end
function Store:saveCatalog() self:save("catalog", self.catalog) end
function Store:saveRules() self:save("rules", self.screenRules) end
function Store:saveAlwaysShare() self:save("alwaysShare", self.alwaysShare) end
function Store:saveHeld() self:save("held", self.held) end
function Store:saveProcesses() self:save("processes", self.processes) end
function Store:saveNext() self:save("next", self.next) end

-- RUN NEXT: seconds left for the item at time `now`, or nil.
function Store:nextLeft(key, now)
  local n = self.next[key]
  if type(n) == "table" and tonumber(n.ends) and n.ends > now then return math.floor(n.ends - now) end
  return nil
end

-- Drop RUN NEXT entries that ended; returns their keys.
function Store:expireNext(now)
  local gone = {}
  for key, n in pairs(self.next) do
    if not (type(n) == "table" and tonumber(n.ends) and n.ends > now) then gone[#gone + 1] = key; self.next[key] = nil end
  end
  if #gone > 0 then self:saveNext() end
  return gone
end

function Store:editableRules()
  if not self.screenRules then
    self.screenRules = {}
    for i, r in ipairs(self.cfg.rules) do
      self.screenRules[i] = { pattern = r.pattern, process = r.process, priority = r.priority, batch = r.batch,
                              fallback = r.fallback }
    end
  end
  return self.screenRules
end

function Store:resetRules()
  self.screenRules = nil
  os.remove(self.paths.rules)
end

return Store
