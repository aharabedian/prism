--[[ prism.router.outputs: everything that sends a process's items somewhere.

  Every output kind implements the same interface, so the rest of the router never asks
  which kind it has:

    output.kind           "bus" | "stocker" | "feeder"
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

  open(cfg, env) -> outputs[]   export buses, then stockers, then feeders; raises a readable
                                error for a missing or misconfigured component
  env = { cfg, db, stats, log, proxyOf, labelOf }
    db       prism.router.database (nil if there's none; buses and feeders then can't open)
    stats    { writes, lastError }, shared with the router's status
    proxyOf  function(ctype, address?) -> proxy | nil
    labelOf  function(key) -> label from the latest scan
  To add a kind: write lib/prism/router/<kind>.lua with open(spec, index, env), add it below,
  and document its config in docs/configuration.md.
]]

local KINDS = {
  { list = "buses",    module = "prism.router.exportbus" },
  { list = "stockers", module = "prism.router.stocker" },
  { list = "feeders",  module = "prism.router.feeder" },
}

local O = {}

function O.open(cfg, env)
  local out = {}
  for _, k in ipairs(KINDS) do
    local kind = require(k.module)
    for i, spec in ipairs(cfg[k.list]) do out[#out + 1] = kind.open(spec, i, env) end
  end
  return out
end

-- Every output of a given kind, in order.
function O.ofKind(outputs, kind)
  local list = {}
  for _, o in ipairs(outputs) do if o.kind == kind then list[#list + 1] = o end end
  return list
end

return O
