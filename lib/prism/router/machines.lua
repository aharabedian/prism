--[[ prism.router.machines: monitored GT machines (component gt_machine).

  Config: { address, process?, name? }
  open(cfg, proxyOf) -> machine[]     raises if a machine can't be found
  poll(m)                             refresh m.state, m.progress, m.eu
  summary(list) -> rows for router-status / router-machines

  m.state: "disabled" (work not allowed), "maintenance" (sensor info "Problems: N" > 0), "working",
           "no power" (idle with EU stored < 5%), "idle", or "offline" when calls fail.
  m.progress, m.eu: 0..1 or nil.  m.idleFor: set by prism.router.health.
]]

local U = require("prism.util")

local M = {}

function M.open(cfg, proxyOf)
  local list = {}
  for i, mc in ipairs(cfg.machines) do
    local name = mc.name or ("machine #" .. i)
    local p = proxyOf("gt_machine", mc.address)
    if not p then error(("%s: no gt_machine matching %q"):format(name, tostring(mc.address)), 0) end
    list[#list + 1] = { proxy = p, name = name, process = mc.process, state = "?" }
  end
  return list
end

-- Call a method that may not exist on this machine; nil on any failure.
local function mcall(p, fn)
  if p[fn] == nil then return nil end
  local ok, v = pcall(p[fn])
  if ok then return v end
  return nil
end

local function poll(m)
  local p = m.proxy
  local active = mcall(p, "isMachineActive")
  if active == nil then m.state, m.progress, m.eu = "offline", nil, nil; return end
  local allowed = mcall(p, "isWorkAllowed")
  local prog, max = tonumber(mcall(p, "getWorkProgress")), tonumber(mcall(p, "getWorkMaxProgress"))
  local eu    = tonumber(mcall(p, "getEUStored") or mcall(p, "getStoredEU"))
  local euMax = tonumber(mcall(p, "getEUMaxStored") or mcall(p, "getEUCapacity"))
  m.progress = (max or 0) > 0 and U.round2(math.min(1, (prog or 0) / max)) or nil
  m.eu       = (euMax or 0) > 0 and U.round2(math.min(1, (eu or 0) / euMax)) or nil
  local problems = 0
  local info = mcall(p, "getSensorInformation")
  if type(info) == "table" then
    for _, line in ipairs(info) do
      local n = tostring(line):gsub("§.", ""):match("Problems:%s*(%d+)")
      if n then problems = tonumber(n) end
    end
  end
  if allowed == false then m.state = "disabled"
  elseif problems > 0 then m.state = "maintenance"
  elseif active then m.state = "working"
  elseif m.eu and m.eu < 0.05 then m.state = "no power"
  else m.state = "idle" end
end

function M.poll(m)
  if not pcall(poll, m) then m.state = "offline" end
end

function M.summary(list)
  local out = {}
  for _, m in ipairs(list) do
    out[#out + 1] = { name = m.name, process = m.process, state = m.state,
                      progress = m.progress, eu = m.eu, idle = m.idleFor }
  end
  return out
end

return M
