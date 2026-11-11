--[[ prism.util: small helpers every program uses. Pure functions, no OpenComputers calls.

  keyOf(stack)       "name:damage", the key items are known by everywhere
  sideName(side)     "north" for sides.north, or the number as text
  count(t)           number of keys in a table (nil counts as empty)
  copy(t)            shallow copy
  trim(s)            without leading/trailing whitespace
  fmtNum(n)          1234 -> "1234", 12345 -> "12.3k", 1.2e6 -> "1.2M"
  fmtSecs(s)         45 -> "45s", 125 -> "2m05s"            (router log/alert text)
  fmtTime(s)         45 -> "0m45s", 3720 -> "1h02m"         (control screen)
  pct(x)             0.426 -> "43%", nil -> ""
  round2(x)          to two decimals, nil stays nil
]]

local U = {}

U.SIDE_NAMES = { [0] = "down", "up", "north", "south", "west", "east" }

function U.keyOf(stack)
  return stack.name .. ":" .. math.floor(stack.damage or 0)
end

function U.sideName(side)
  return U.SIDE_NAMES[side] or tostring(side)
end

function U.count(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

function U.copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

function U.trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function U.fmtNum(n)
  n = n or 0
  if n >= 1e6 then return ("%.1fM"):format(n / 1e6) end
  if n >= 1e4 then return ("%.1fk"):format(n / 1e3) end
  return tostring(math.floor(n))
end

function U.fmtSecs(s)
  s = math.floor(s or 0)
  if s < 60 then return s .. "s" end
  return ("%dm%02ds"):format(math.floor(s / 60), s % 60)
end

function U.fmtTime(s)
  s = math.floor(s or 0)
  local h, m = math.floor(s / 3600), math.floor(s % 3600 / 60)
  if h > 0 then return ("%dh%02dm"):format(h, m) end
  return ("%dm%02ds"):format(m, s % 60)
end

function U.pct(x)
  return x and (math.floor(x * 100 + 0.5) .. "%") or ""
end

function U.round2(x)
  return x and math.floor(x * 100 + 0.5) / 100 or nil
end

return U
