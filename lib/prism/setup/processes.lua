--[[ prism.setup.processes: choosing processes and the starting rules for them.

  step(old) -> procs, rules     ask which processes there are machines for; offer standard rules
  rulesFor(has) -> rules        standard ore-processing rules for a set { [process] = true }
  coverage(c, procs) -> warnings[]   processes routed to but not served, and the other way round
  inConfig(c) -> names[]        every process a config's rules and hardware mention, first-seen order
]]

local filesystem = require("filesystem")
local input      = require("prism.setup.input")
local paths      = require("prism.setup.paths")

local P = {}

-- Processes offered, in ore-processing order. Names are free text to the router; these are
-- sensible defaults that the starting rules use.
P.STANDARD = {
  { id = "crush",      machine = "Macerator" },
  { id = "wash",       machine = "Ore Washer" },
  { id = "thermal",    machine = "Thermal Centrifuge" },
  { id = "centrifuge", machine = "Centrifuge" },
  { id = "sift",       machine = "Sifter (gem ores)" },
}
P.DEFAULT_PROCESSES = { "crush", "wash", "centrifuge" }
P.SIFT_GEMS = { "Diamond", "Emerald", "Ruby", "Sapphire", "Green Sapphire", "Olivine",
                "Topaz", "Tanzanite", "Amethyst", "Opal" }

-- Crushed ore is washed if possible, else thermal-centrifuged, else macerated, and so on.
function P.rulesFor(has)
  local rules = {}
  local function add(pattern, process, priority)
    if process then rules[#rules + 1] = { pattern = pattern, process = process, priority = priority } end
  end
  local function first(...)
    for _, p in ipairs({ ... }) do if has[p] then return p end end
  end
  if has.sift then
    for _, g in ipairs(P.SIFT_GEMS) do add("^Purified " .. g .. " Ore$", "sift", 15) end
  end
  add("^Crushed .+ Ore$",           first("wash", "thermal", "crush"), 10)
  add("^Purified .+ Ore$",          first("crush", "thermal"), 10)
  add("^Centrifuged .+ Ore$",       first("crush"), 10)
  add("^Impure Pile of .+ Dust$",   first("centrifuge"), 10)
  add("^Purified Pile of .+ Dust$", first("centrifuge"), 10)
  add("Ore$",                       first("crush"), 5)
  return rules
end

local function sameRules(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i].pattern ~= b[i].pattern or a[i].process ~= b[i].process or a[i].priority ~= b[i].priority
      or (a[i].batch or 1) ~= (b[i].batch or 1) then return false end
  end
  return true
end

-- Every process the current config mentions, in first-seen order.
function P.inConfig(old)
  local seen, list = {}, {}
  local function add(p)
    if type(p) == "string" and p ~= "ignore" and not seen[p] then seen[p] = true; list[#list + 1] = p end
  end
  for _, key in ipairs({ "rules", "buses", "stockers", "interfaces", "feeders", "machines" }) do
    for _, e in ipairs(old[key] or {}) do add(e.process) end
  end
  return list
end

function P.step(old)
  input.header("Processes and rules")
  print("  Which processes do you have machines for? Numbers separated by spaces; you can also type new names.")
  local options, isOption = {}, {}
  for _, s in ipairs(P.STANDARD) do
    options[#options + 1] = { id = s.id, label = ("%-11s %s"):format(s.id, s.machine) }
    isOption[s.id] = true
  end
  local previous = P.inConfig(old)
  for _, p in ipairs(previous) do
    if not isOption[p] then
      options[#options + 1] = { id = p, label = ("%-11s (from your config)"):format(p) }
      isOption[p] = true
    end
  end
  local defaults = {}
  for i, o in ipairs(options) do
    for _, p in ipairs(#previous > 0 and previous or P.DEFAULT_PROCESSES) do
      if o.id == p then defaults[#defaults + 1] = tostring(i) end
    end
  end
  for i, o in ipairs(options) do print(("  %d) %s"):format(i, o.label)) end

  local procs, has
  while true do
    procs, has = {}, {}
    local answer = input.ask("  processes", table.concat(defaults, " ")) or ""
    for word in answer:gmatch("[^%s,]+") do
      local n = tonumber(word)
      local p = n and options[n] and options[n].id or (not n and word) or nil
      if p and not has[p] then has[p] = true; procs[#procs + 1] = p end
    end
    if #procs > 0 then break end
    print("  pick at least one")
  end

  local generated = P.rulesFor(has)
  local current = old.rules or {}
  local rules
  if sameRules(generated, current) then
    print(("  rules: the %d standard rules for these processes"):format(#generated))
    rules = generated
  elseif #generated == 0 then
    print("  no standard rules for these processes - write your own on the control screen's RULES tab")
    rules = current
  else
    print("  Standard rules for these processes (first match wins):")
    for _, r in ipairs(generated) do print(("    %-30s -> %s"):format(r.pattern, r.process)) end
    if #current == 0 or input.yes(("  use these instead of your current %d rule(s)?"):format(#current), false) then
      rules = generated
    else
      rules = current
    end
  end
  if filesystem.exists(paths.RULES_PATH) then
    print("  note: rules edited on the control screen (" .. paths.RULES_PATH .. ") stay in use;")
    print("  press RESET TO prism.cfg on the RULES tab to switch to these.")
  end
  return procs, rules
end

function P.coverage(c, procs)
  local served, routed = {}, {}
  for _, key in ipairs({ "buses", "stockers", "interfaces", "feeders" }) do
    for _, e in ipairs(c[key] or {}) do served[e.process] = true end
  end
  for _, r in ipairs(c.rules or {}) do routed[r.process] = true end
  local warnings = {}
  for _, p in ipairs(procs) do
    if routed[p] and not served[p] then
      warnings[#warnings + 1] = ("no bus, stocker, interface or feeder for %q - its items will wait in the network"):format(p)
    elseif served[p] and not routed[p] then
      warnings[#warnings + 1] = ("no rule sends anything to %q - route items on the control screen"):format(p)
    end
  end
  return warnings
end

return P
