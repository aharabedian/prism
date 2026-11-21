--[[ prism.rules: deciding an item's process. Pure functions, no I/O.

  An item is decided by, first match wins:
    1. overrides[key]       screen overrides (prism-overrides.cfg)    source "gui"
    2. cfg.overrides[key]   overrides in prism.cfg                    source "cfg"
    3. rules, in order      label:find(rule.pattern)                  source "rule"

  validPattern(p)                       -> true | false, reason
  clean(list, where, log)               rules with a valid pattern and a process; logs the rest
  fromMsg(msg)                          a rule from a setRule command -> rule | nil, reason
  classify(overrides, cfg, rules, label, key)
                                        -> process, priority, batch, source, ruleIndex, fallback | nil
                                           (ruleIndex is nil for overrides; fallback: see validFallback)
  validFallback(process, fallback)      -> fallback if it's a process items can spill to, else nil
  usage(overrides, cfg, rules, catalog) -> { [ruleIndex] = catalog items it decides }
  preview(overrides, cfg, rules, catalog, msg, limit)
                                        -> fields of a router-preview reply (see docs/protocol.md)
  ideas(names) -> { pattern, names }[]  rules that would catch names differing in one word: "Purified Pile of
                                        Iron Dust" and "... of Tin Dust" give "^Purified Pile of .+ Dust$". Each
                                        name goes to the biggest idea that has it; ideas need 2+ names; biggest first
]]

local R = {}

function R.validPattern(p)
  if type(p) ~= "string" or p == "" then return false, "empty pattern" end
  local ok, err = pcall(string.find, "", p)
  if not ok then return false, (tostring(err):gsub("^.-:%d+: ", "")) end
  return true
end

-- A fallback is another real process; anything else means "never spill".
function R.validFallback(process, fallback)
  if type(fallback) == "string" and fallback ~= "" and fallback ~= process and fallback ~= "ignore"
     and process ~= "ignore" then return fallback end
  return nil
end

function R.clean(list, where, log)
  local out = {}
  for i, r in ipairs(list or {}) do
    local ok, err = R.validPattern(r.pattern)
    if ok and type(r.process) == "string" then out[#out + 1] = r
    elseif log then log("%s rule #%d skipped: %s", where, i, ok and "no process" or err) end
  end
  return out
end

function R.fromMsg(msg)
  local ok, err = R.validPattern(msg.pattern)
  if not ok then return nil, "bad pattern: " .. tostring(err) end
  if type(msg.process) ~= "string" or msg.process == "" then return nil, "pick a process for the rule" end
  local batch = math.max(1, math.floor(tonumber(msg.batch) or 1))
  return { pattern = msg.pattern, process = msg.process, priority = tonumber(msg.priority),
           batch = batch > 1 and batch or nil, fallback = R.validFallback(msg.process, msg.fallback) }
end

function R.classify(overrides, cfg, rules, label, key)
  local o = overrides[key]
  if o then return o.process, o.priority or cfg.defaultPriority, o.batch or 1, "gui", nil, R.validFallback(o.process, o.fallback) end
  o = cfg.overrides[key]
  if o then return o.process, o.priority or cfg.defaultPriority, o.batch or 1, "cfg", nil, R.validFallback(o.process, o.fallback) end
  label = label or ""
  for i, r in ipairs(rules) do
    if label:find(r.pattern) then
      return r.process, r.priority or cfg.defaultPriority, r.batch or 1, "rule", i, R.validFallback(r.process, r.fallback)
    end
  end
  return nil
end

function R.usage(overrides, cfg, rules, catalog)
  local used = {}
  for key, c in pairs(catalog) do
    local _, _, _, src, idx = R.classify(overrides, cfg, rules, c.label, key)
    if src == "rule" then used[idx] = (used[idx] or 0) + 1 end
  end
  return used
end

-- What would happen if msg.pattern were saved at msg.index (or as a new rule at the top)?
function R.preview(overrides, cfg, rules, catalog, msg, limit)
  local ok, err = R.validPattern(msg.pattern)
  if not ok then return { error = err } end
  local trial, pos = {}, 1
  for i, r in ipairs(rules) do trial[i] = r end
  local candidate = { pattern = msg.pattern, process = msg.process or "?" }
  local index = tonumber(msg.index)
  if index and trial[index] then trial[index] = candidate; pos = index
  else table.insert(trial, 1, candidate) end

  local list, applies = {}, 0
  for key, c in pairs(catalog) do
    local label = c.label or key
    if label:find(msg.pattern) then
      local _, _, _, src, idx = R.classify(overrides, cfg, trial, label, key)
      local now = R.classify(overrides, cfg, rules, label, key)
      local effect
      if src == "rule" and idx == pos then effect = "applies"; applies = applies + 1
      elseif src == "gui" or src == "cfg" then effect = "override wins"
      else effect = "rule #" .. tostring(idx) .. " wins" end
      list[#list + 1] = { key = key, label = label, now = now, effect = effect }
    end
  end
  table.sort(list, function(a, b) return a.label:lower() < b.label:lower() end)
  local total = #list
  for i = #list, limit + 1, -1 do list[i] = nil end
  return { total = total, applies = applies, list = list }
end

local function escape(s) return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end

function R.ideas(names)
  local groups, order = {}, {}
  for _, name in ipairs(names) do
    local words = {}
    for w in name:gmatch("%S+") do words[#words + 1] = w end
    if #words >= 2 then
      for i = 1, #words do
        local parts = {}
        for j, w in ipairs(words) do parts[j] = j == i and ".+" or escape(w) end
        local pattern = "^" .. table.concat(parts, " ") .. "$"
        local g = groups[pattern]
        if not g then g = { pattern = pattern, names = {} }; groups[pattern] = g; order[#order + 1] = g end
        g.names[#g.names + 1] = name
      end
    end
  end
  table.sort(order, function(a, b)
    if #a.names ~= #b.names then return #a.names > #b.names end
    return a.pattern < b.pattern
  end)
  local taken, out = {}, {}
  for _, g in ipairs(order) do
    local free = {}
    for _, n in ipairs(g.names) do if not taken[n] then free[#free + 1] = n end end
    if #free >= 2 then
      for _, n in ipairs(free) do taken[n] = true end
      out[#out + 1] = { pattern = g.pattern, names = free }
    end
  end
  return out
end

return R
