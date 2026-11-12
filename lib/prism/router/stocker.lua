--[[ prism.router.stocker: a GT Stocking Input Bus (ME), component me_inputbus.
  Implements the output interface in prism.router.outputs.

  Config: { address, process, name? }. The bus shows a multiblock the network's stock of each
  configured item and the multiblock takes exactly what a recipe needs, so stockers take batch
  items too: the top getSlotSize() items of any batch size, with at least one full batch in stock
  (less can't run a recipe, and would only take a slot). Slots are set with
  setConfiguration(slot, { name, damage }) (no table clears it): no database needed.
  Auto-pull on an Advanced bus is switched off at open, because it would replace our choices.
]]

local U     = require("prism.util")
local slots = require("prism.router.slots")
local Bus   = require("prism.router.exportbus")

local Stocker = { kind = "stocker", takesBatches = true, statusList = "buses" }
Stocker.__index = Stocker

function Stocker.open(spec, i, env)
  if not spec.process then error(("stocker #%d has no process"):format(i), 0) end
  local name = spec.name or (spec.process .. " stocker #" .. i)
  local p = env.proxyOf("me_inputbus", spec.address)
  if not p then error(("%s: no me_inputbus matching %q"):format(name, tostring(spec.address)), 0) end
  local ok, n = pcall(p.getSlotSize)
  if not ok or type(n) ~= "number" then error(("%s: can't read the stocking bus: %s"):format(name, tostring(n)), 0) end
  local okAdv, adv = pcall(p.isAdvanced)
  if okAdv and adv and p.getAutoPull() then
    p.setAutoPull(false)
    env.log("%s: auto-pull switched off - PRISM picks its items", name)
  end
  local st = setmetatable({ proxy = p, process = spec.process, name = name, env = env,
                            size = math.floor(n), slots = {} }, Stocker)
  for s = 1, st.size do
    local okS, c = pcall(p.getConfiguration, s)
    if not okS then error(("%s: %s"):format(name, tostring(c)), 0) end
    st.slots[s] = type(c) == "table" and c.name and U.keyOf(c) or false
  end
  return st
end

function Stocker:write(slot, e)
  local ok, res
  if e then ok, res = pcall(self.proxy.setConfiguration, slot,
                            { name = e.stack.name, damage = math.floor(e.stack.damage or 0) })
  else ok, res = pcall(self.proxy.setConfiguration, slot) end
  if not ok then return false, tostring(res) end
  self.slots[slot] = e and e.key or false
  self.env.stats.writes = self.env.stats.writes + 1
  if self.env.cfg.verbose then self.env.log("%s slot %d -> %s", self.name, slot, e and (e.label or e.key) or "(cleared)") end
  return true
end

function Stocker:apply(queue)
  local wanted = {}
  for _, e in ipairs(queue) do
    if #wanted >= self.size then break end
    if e.size >= e.batch then wanted[#wanted + 1] = e end
  end
  local ok, err = slots.apply(self.slots, self.size, wanted, function(s, e) return self:write(s, e) end)
  if not ok then
    self.env.stats.lastError = self.name .. ": " .. tostring(err)
    self.env.log("%s", self.env.stats.lastError)
  end
end

function Stocker:status(labels) return Bus.statusRow(self, labels, "stocker") end
function Stocker.step() end
function Stocker.alert() return nil end
function Stocker.close() end

return Stocker
