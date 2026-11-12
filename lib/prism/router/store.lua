--[[ prism.router.store: the router's data files, and classifying items with them.

  Files next to prism.cfg (<base> = the config path without .cfg):
    <base>-overrides.cfg  overrides     { [key] = { process, priority?, batch?, label? } }   made on the screen
    <base>-items.cfg      catalog       { [key] = { label } }                                every item ever seen
    <base>-overrides.cfg  (entries may also have fallback)
    <base>-rules.cfg      screenRules   { pattern, process, priority?, batch?, fallback? }[] rules edited on the screen
    <base>-diverts.cfg    diverts       { [process] = true }                                 diverted on the screen

  Store.open(configPath, cfg, log) -> store
  store.overrides, store.catalog, store.screenRules (nil until rules are edited on the screen)
  store:rules()                    the rules in use: screenRules, else cfg.rules
  store:classify(label, key, rules?)  see prism.rules.classify
  store:limits()                   { [process] = { overflow?, diverted? } } for planner.spill
  store:labelOf(key, fallback)     the catalog label, else fallback
  store:saveOverrides(), store:saveCatalog(), store:saveRules(), store:saveDiverts()
  store:editableRules()            screenRules, copied from cfg.rules the first time
  store:resetRules()               delete prism-rules.cfg and go back to cfg.rules
]]

local files = require("prism.files")
local rules = require("prism.rules")

local Store = {}
Store.__index = Store

function Store.open(configPath, cfg, log)
  local base = configPath:gsub("%.cfg$", "")
  local s = setmetatable({
    cfg = cfg, log = log,
    paths = { overrides = base .. "-overrides.cfg", catalog = base .. "-items.cfg", rules = base .. "-rules.cfg",
              diverts = base .. "-diverts.cfg" },
  }, Store)
  s.overrides = files.readTable(s.paths.overrides)
  s.catalog = files.readTable(s.paths.catalog)
  s.diverts = files.readTable(s.paths.diverts)
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
    if type(p) == "table" and tonumber(p.overflow) then out[proc] = { overflow = tonumber(p.overflow) } end
  end
  for proc, on in pairs(self.diverts) do
    if on then out[proc] = out[proc] or {}; out[proc].diverted = true end
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
function Store:saveDiverts() self:save("diverts", self.diverts) end

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
