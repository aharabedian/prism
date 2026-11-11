--[[ prism.router.slots: keep a row of config slots holding a wanted set of items, with as few
  writes as possible. Used by export buses and stocking buses.

  apply(slots, n, wanted, write) -> true | false, reason
    slots   { [1..n] = key | false }, what each slot holds now (write keeps it up to date)
    wanted  ordered entries { key, stack, label }
    write   function(slot, entry | nil) -> true | false, reason   (nil clears the slot)

  Slots already holding a wanted item are kept; the rest get the missing items in order, then
  are cleared. An unchanged set causes zero writes; one item running out rewrites one slot.
  Stops at the first failed write (the bus is probably unloaded; the next scan tries again).
]]

local S = {}

function S.apply(slots, n, wanted, write)
  local want = {}
  for _, e in ipairs(wanted) do want[e.key] = e end
  local placed = {}
  for s = 1, n do
    local k = slots[s]
    if k and want[k] and not placed[k] then placed[k] = true end
  end
  local todo = {}
  for _, e in ipairs(wanted) do if not placed[e.key] then todo[#todo + 1] = e end end

  local nextTodo = 1
  for s = 1, n do
    local k = slots[s]
    if k and want[k] and placed[k] == true then
      placed[k] = "kept"            -- a duplicate of k in a later slot gets replaced
    else
      local e = todo[nextTodo]
      local ok, err = true, nil
      if e then
        nextTodo = nextTodo + 1
        ok, err = write(s, e)
      elseif k then
        ok, err = write(s, nil)
      end
      if not ok then return false, err end
    end
  end
  return true
end

return S
