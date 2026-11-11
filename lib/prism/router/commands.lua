--[[ prism.router.commands: the wireless commands the router answers (docs/protocol.md).

  COMMANDS[cmd] = { fields = { name = "string", ... }, run = function(r, msg, reply) -> rescan }
    fields  required fields and their Lua types; a command missing one is ignored
    r       the router (prism.router.core)
    reply   function(message) sends a reply to whoever asked
    rescan  true when the command changed routing and a scan should run now

  handle(r, msg, reply) -> rescan    dispatch one decoded command
]]

local rules    = require("prism.rules")
local protocol = require("prism.protocol")

local C = {}

local function nameOf(r, key) return r.store:labelOf(key, r.last.labels[key]) or key end
local function acker(reply)
  return function(ok, text) reply({ type = "router-ack", ok = ok, text = text }) end
end

local COMMANDS = {}
C.COMMANDS = COMMANDS

---------------------------------------------------------------- routing items

COMMANDS.assign = { fields = { key = "string", process = "string" }, run = function(r, msg, reply)
  local store = r.store
  local label = type(msg.label) == "string" and msg.label or nameOf(r, msg.key)
  local batch = math.max(1, math.floor(tonumber(msg.batch) or 1))
  store.overrides[msg.key] = { process = msg.process, priority = tonumber(msg.priority),
                               batch = batch > 1 and batch or nil, label = label }
  store:saveOverrides()
  if not store.catalog[msg.key] then store.catalog[msg.key] = { label = label }; store:saveCatalog() end
  r.reported[msg.key], r.reported["batch:" .. msg.key] = nil, nil
  r.log("override: %s -> %s (priority %s, batch %d)", label, msg.process, tostring(msg.priority or "default"), batch)
  acker(reply)(true, ("%s -> %s%s"):format(label, msg.process, batch > 1 and (" in batches of " .. batch) or ""))
  return true
end }

COMMANDS.unassign = { fields = { key = "string" }, run = function(r, msg, reply)
  local store = r.store
  local had = store.overrides[msg.key] ~= nil
  store.overrides[msg.key] = nil
  store:saveOverrides()
  r.reported[msg.key] = nil
  r.log("override removed: %s", msg.key)
  acker(reply)(had, had and ("removed override for " .. nameOf(r, msg.key))
                         or "that override lives in prism.cfg - edit it there")
  return true
end }

COMMANDS.forget = { fields = { key = "string" }, run = function(r, msg, reply)
  local store = r.store
  local name = nameOf(r, msg.key)
  local had = store.catalog[msg.key] ~= nil
  store.catalog[msg.key] = nil
  store:saveCatalog()
  local hadOverride = store.overrides[msg.key] ~= nil
  if hadOverride then store.overrides[msg.key] = nil; store:saveOverrides() end
  local text = "forgot " .. name .. (hadOverride and " and its override" or "")
  if r.last.present[msg.key] then text = text .. " - it's still in the network, so it'll be re-added" end
  r.log("%s", text)
  acker(reply)(had, text)
  return true
end }

COMMANDS.forgetAbsent = { run = function(r, _, reply)
  local store = r.store
  local removed, kept = 0, 0
  for key in pairs(store.catalog) do
    if not r.last.present[key] then
      if store.overrides[key] or r.cfg.overrides[key] then kept = kept + 1
      else store.catalog[key] = nil; removed = removed + 1 end
    end
  end
  store:saveCatalog()
  local text = ("forgot %d absent item(s)"):format(removed)
  if kept > 0 then text = text .. (" - kept %d with overrides"):format(kept) end
  r.log("%s", text)
  acker(reply)(true, text)
  return true
end }

---------------------------------------------------------------- rules

COMMANDS.setRule = { run = function(r, msg, reply)
  local rule, err = rules.fromMsg(msg)
  if not rule then acker(reply)(false, err); return false end
  local list = r.store:editableRules()
  local index = tonumber(msg.index)
  if index and list[index] then list[index] = rule
  else table.insert(list, 1, rule); index = 1 end
  r.store:saveRules()
  r.log("rule #%d: %s -> %s", index, rule.pattern, rule.process)
  acker(reply)(true, ("rule #%d saved: %s -> %s"):format(index, rule.pattern, rule.process))
  return true
end }

COMMANDS.deleteRule = { run = function(r, msg, reply)
  local list = r.store:editableRules()
  local index = tonumber(msg.index)
  local rule = index and list[index]
  if not rule then acker(reply)(false, "no rule #" .. tostring(msg.index)); return false end
  table.remove(list, index)
  r.store:saveRules()
  r.log("rule #%d deleted: %s", index, rule.pattern)
  acker(reply)(true, ("deleted rule #%d (%s)"):format(index, rule.pattern))
  return true
end }

COMMANDS.moveRule = { run = function(r, msg, reply)
  local list = r.store:editableRules()
  local index, dir = tonumber(msg.index), tonumber(msg.dir)
  local target = index and dir and index + (dir < 0 and -1 or 1)
  if not (target and list[index] and list[target]) then acker(reply)(false, "can't move that rule"); return false end
  list[index], list[target] = list[target], list[index]
  r.store:saveRules()
  acker(reply)(true, ("rule moved to #%d"):format(target))
  return true
end }

COMMANDS.resetRules = { run = function(r, _, reply)
  r.store:resetRules()
  r.log("screen rules removed - back to the rules in prism.cfg")
  acker(reply)(true, "back to the rules in prism.cfg")
  return true
end }

COMMANDS.reload = { run = function(r, _, reply)
  local ok, err = pcall(r.setup, r)
  if not ok then r.stats.lastError = tostring(err); r.log("reload failed: %s", tostring(err)) end
  acker(reply)(ok, ok and "config reloaded" or ("reload failed: " .. tostring(err)))
  return true
end }

---------------------------------------------------------------- queries (no changes)

COMMANDS.status = { run = function(r, _, reply)
  if r.lastStatus then reply(r.lastStatus) end
end }

COMMANDS.overrides = { run = function(r, _, reply)
  local store, list = r.store, {}
  local function add(key, o, source)
    list[#list + 1] = { key = key, process = o.process, priority = o.priority, batch = o.batch,
                        label = o.label or store:labelOf(key, r.last.labels[key]), source = source }
  end
  for key, o in pairs(r.cfg.overrides) do if not store.overrides[key] then add(key, o, "cfg") end end
  for key, o in pairs(store.overrides) do add(key, o, "gui") end
  table.sort(list, function(a, b) return (a.label or a.key):lower() < (b.label or b.key):lower() end)
  reply({ type = "router-overrides", list = list })
end }

COMMANDS.rules = { run = function(r, _, reply)
  local store = r.store
  local list = store:rules()
  local used = rules.usage(store.overrides, r.cfg, list, store.catalog)
  local out = {}
  for i, rule in ipairs(list) do
    out[i] = { index = i, pattern = rule.pattern, process = rule.process, priority = rule.priority,
               batch = rule.batch, used = used[i] or 0 }
  end
  reply({ type = "router-rules", source = store.screenRules and "screen" or "config", list = out })
end }

COMMANDS.previewRule = { run = function(r, msg, reply)
  local store = r.store
  local p = rules.preview(store.overrides, r.cfg, store:rules(), store.catalog, msg, protocol.PAGE)
  p.type, p.req = "router-preview", msg.req
  reply(p)
end }

COMMANDS.items = { run = function(r, msg, reply)
  local all = {}
  for key, c in pairs(r.store.catalog) do
    local label = c.label or key
    local proc, prio, batch, src = r.store:classify(label, key)
    all[#all + 1] = { key = key, label = label, size = r.last.present[key] or 0,
                      process = proc, priority = prio, batch = batch, source = src }
  end
  table.sort(all, function(a, b) return a.label:lower() < b.label:lower() end)
  local offset = math.max(0, math.floor(tonumber(msg.offset) or 0))
  local page = {}
  for i = offset + 1, math.min(#all, offset + protocol.PAGE) do page[#page + 1] = all[i] end
  reply({ type = "router-items", req = msg.req, offset = offset, total = #all, list = page })
end }

---------------------------------------------------------------- dispatch

function C.handle(r, msg, reply)
  local c = COMMANDS[msg.cmd]
  if not c then return false end
  for field, kind in pairs(c.fields or {}) do
    if type(msg[field]) ~= kind then return false end
  end
  return c.run(r, msg, reply) == true
end

return C
