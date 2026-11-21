--[[ prism.router.supplies: what a process needs from elsewhere (a fluid or an item, at least `min`), read from an
  ME network the router has an adapter on. Reads only: it never moves anything from that network.

  Config (prism.cfg `supplies`): { process, fluid = "Sulfuric Acid" | item = "Sulfuric Acid Cell", min,
                                   network? (address or prefix of an me_controller / me_interface; default the
                                   network PRISM scans), name? (shown; default the fluid or item) }
  Supplies.open(cfg, proxyOf, net, log) -> s      raises a readable error for a bad entry or missing network
  s:read(now)                     read every supply (protected: a failed read keeps the last amount)
  s:low() -> { [process] = supply }   supplies below `min` for HOLD seconds (back once above for HOLD seconds)
  s:rows() -> { [process] = { name, amount, min, unit, low, lowFor? } }   the first supply of each process, or
                                  its first low one, for router-status
  s.list                          { process, kind, label, min, name, unit, amount?, low, since? }[]
  Supplies.HOLD = 60
  A low supply makes its process share every item with a fallback (as ALWAYS SHARE) and replaces its stall and
  idle alerts with one warn (prism.router.core does both).
]]

local Supplies = { HOLD = 60 }
Supplies.__index = Supplies

function Supplies.open(cfg, proxyOf, net, log)
  local list = {}
  for i, spec in ipairs(cfg.supplies or {}) do
    local what = spec.fluid or spec.item
    local where = ("supplies #%d"):format(i)
    if type(spec.process) ~= "string" then error(where .. " has no process", 0) end
    if type(what) ~= "string" then error(where .. " needs fluid = \"...\" or item = \"...\"", 0) end
    if not tonumber(spec.min) then error(where .. " needs min = an amount", 0) end
    local proxy = net
    if spec.network then
      proxy = proxyOf("me_controller", spec.network) or proxyOf("me_interface", spec.network)
      if not proxy then error(("%s: no me_controller or me_interface matching %q"):format(where, spec.network), 0) end
    end
    list[#list + 1] = { process = spec.process, kind = spec.fluid and "fluid" or "item", label = what:lower(),
      min = tonumber(spec.min), name = spec.name or what, unit = spec.fluid and " L" or "", proxy = proxy, low = false }
  end
  return setmetatable({ list = list, log = log }, Supplies)
end

local function amountIn(sup)
  local call = sup.kind == "fluid" and sup.proxy.getFluidsInNetwork or sup.proxy.getItemsInNetwork
  if not call then return nil end
  local ok, res = pcall(call)
  if not ok or type(res) ~= "table" then return nil end
  local total = 0
  for _, st in ipairs(res) do
    if type(st) == "table" and type(st.label) == "string" and st.label:lower() == sup.label then
      total = total + (tonumber(sup.kind == "fluid" and st.amount or st.size) or 0)
    end
  end
  return total
end

function Supplies:read(now)
  for _, sup in ipairs(self.list) do
    local n = amountIn(sup)
    if n then sup.amount = n end
    local below = sup.amount ~= nil and sup.amount < sup.min
    if below ~= sup.low then
      sup.changing = sup.changing or now                  -- held for HOLD seconds before it flips
      if now - sup.changing >= Supplies.HOLD then
        sup.low, sup.changing = below, nil
        sup.since = below and now or nil
        if self.log then self.log("%s: %s %s (%d of %d)", sup.process, sup.name, below and "low" or "back",
          math.floor(sup.amount), math.floor(sup.min)) end
      end
    else
      sup.changing = nil
    end
    sup.now = now
  end
end

function Supplies:low()
  local out = {}
  for _, sup in ipairs(self.list) do if sup.low and not out[sup.process] then out[sup.process] = sup end end
  return out
end

function Supplies:rows()
  local out = {}
  for _, sup in ipairs(self.list) do
    local r = out[sup.process]
    if not r or (sup.low and not r.low) then
      out[sup.process] = { name = sup.name, amount = sup.amount, min = sup.min, unit = sup.unit, low = sup.low,
        lowFor = sup.low and sup.since and sup.now and math.floor(sup.now - sup.since) or nil }
    end
  end
  return out
end

return Supplies
