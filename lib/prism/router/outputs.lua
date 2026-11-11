--[[ prism.router.outputs: everything that sends a process's items somewhere.

  Every output kind implements the same interface, so the rest of the router never asks
  which kind it has:

    output.kind           "bus" | "stocker" | "interface" | "feeder"
    output.name           display name
    output.process        the process it serves
    output.takesBatches   true if it can deliver exact batch sizes (stockers, feeders)
    output.statusList     which router-status list it reports in: "buses" | "feeders"
    output.fed            feeders only: items moved so far (stall detection watches it)
    output:apply(queue)   after each scan: take items from the process's ranked queue
    output:step(queue)    feeders only: one feed step, every feedInterval
    output:status(labels) its row in router-status
    output:alert()        -> { id, level, text } | nil
    output:close()        on exit: hand anything held back to the network
    output.claims         optional { address, slot }[]: ME interface slots it configures; two outputs
                          claiming the same slot is a configuration error

  open(cfg, env) -> outputs[]   export buses, stockers, interfaces, then feeders; raises a readable
                                error for a missing or misconfigured component
  needsDatabase(cfg) -> list names ("buses", ...) configured that need a database, or nil
  env = { cfg, db, net, stats, log, proxyOf, labelOf }
    db       prism.router.database (nil if there's none; see needsDatabase)
    net      the network component PRISM scans
    stats    { writes, lastError }, shared with the router's status
    proxyOf  function(ctype, address?) -> proxy | nil
    labelOf  function(key) -> label from the latest scan
  To add a kind: write lib/prism/router/<kind>.lua with open(spec, index, env), add it below with
  its prism.cfg list, add the list to prism.config's ROUTER_LISTS and prism-setup, and document it
  in docs/configuration.md.
]]

local KINDS = {
  { list = "buses",      module = "prism.router.exportbus", database = true },
  { list = "stockers",   module = "prism.router.stocker" },
  { list = "interfaces", module = "prism.router.interface", database = true },
  { list = "feeders",    module = "prism.router.feeder",    database = true },
}

local O = {}

function O.needsDatabase(cfg)
  local lists = {}
  for _, k in ipairs(KINDS) do
    if k.database and #(cfg[k.list] or {}) > 0 then lists[#lists + 1] = k.list end
  end
  return #lists > 0 and lists or nil
end

-- Two outputs configuring the same ME interface slot would undo each other's writes.
local function checkClaims(outputs)
  local owner = {}
  for _, o in ipairs(outputs) do
    for _, c in ipairs(o.claims or {}) do
      local id = c.address .. ":" .. c.slot
      if owner[id] then
        error(("%s and %s both use slot %d of ME interface %s - give one of them another interface")
          :format(owner[id].name, o.name, c.slot, c.address:sub(1, 8)), 0)
      end
      owner[id] = o
    end
  end
end

function O.open(cfg, env)
  local out = {}
  for _, k in ipairs(KINDS) do
    local kind = require(k.module)
    for i, spec in ipairs(cfg[k.list] or {}) do out[#out + 1] = kind.open(spec, i, env) end
  end
  checkClaims(out)
  return out
end

-- Every output of a given kind, in order.
function O.ofKind(outputs, kind)
  local list = {}
  for _, o in ipairs(outputs) do if o.kind == kind then list[#list + 1] = o end end
  return list
end

return O
