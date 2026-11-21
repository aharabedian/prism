--[[ prism.util: small helpers every program uses. Pure functions, no OpenComputers calls.

  keyOf(stack)       "name:damage", the key items are known by everywhere
  sideName(side)     "north" for sides.north, or the number as text
  count(t)           number of keys in a table (nil counts as empty)
  copy(t)            shallow copy
  trim(s)            without leading/trailing whitespace
  fmtNum(n)          1234 -> "1234", 12345 -> "12.3k", 1.2e6 -> "1.2M"
  fmtSecs(s)         45 -> "45s", 125 -> "2m05s"            (router log/alert text)
  fmtTime(s)         45 -> "0m45s", 3720 -> "1h02m"         (control screen)
  fmtShort(s)        45 -> "<1m", 2520 -> "42m", 8160 -> "2h16m", over 99 hours -> "99h+"   (how long until)
  pct(x)             0.426 -> "43%", nil -> ""
  round2(x)          to two decimals, nil stays nil
  natLess(a, b)      a before b with numbers compared by value: "Washer 2" < "Washer 10"
  fmtAge(s)          how old, in one unit: 30 -> "now", 300 -> "5m", 7300 -> "2h", 200000 -> "2d"
  fmtWhen(at, now, tz)  when something happened, for lists: with tz (hours from UTC) "19:40" the same day,
                     "Thu 23:10" within 6 days, else "12 Nov"; without tz "3h12m ago" (at, now: seconds since 1970)
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

function U.fmtShort(s)
  s = math.floor(s or 0)
  if s < 60 then return "<1m" end
  if s < 3600 then return math.floor(s / 60) .. "m" end
  if s >= 99 * 3600 then return "99h+" end
  return ("%dh%02dm"):format(math.floor(s / 3600), math.floor(s % 3600 / 60))
end

function U.pct(x)
  return x and (math.floor(x * 100 + 0.5) .. "%") or ""
end

local function natKey(s)
  return (tostring(s or ""):lower():gsub("%d+", function(d) return ("%012d"):format(tonumber(d)) end))
end
function U.natLess(a, b) return natKey(a) < natKey(b) end

function U.round2(x)
  return x and math.floor(x * 100 + 0.5) / 100 or nil
end

local DAYS = { "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" }   -- 1970-01-01 was a Thursday
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- Day of the month and month (1-12) from days since 1970 (Howard Hinnant's civil_from_days).
local function civil(days)
  local z = days + 719468
  local era = (z >= 0 and z or z - 146096) // 146097
  local doe = z - era * 146097
  local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
  local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
  local mp = (5 * doy + 2) // 153
  local d = doy - (153 * mp + 2) // 5 + 1
  local m = mp < 10 and mp + 3 or mp - 9
  return d, m
end

function U.fmtAge(s)
  s = math.floor(s or 0)
  if s < 60 then return "now" end
  if s < 3600 then return s // 60 .. "m" end
  if s < 86400 then return s // 3600 .. "h" end
  return s // 86400 .. "d"
end

function U.fmtWhen(at, now, tz)
  at, now = math.floor(at or 0), math.floor(now or 0)
  if not tz then return U.fmtShort(now - at):gsub("^<1m$", "now") .. (now - at >= 60 and " ago" or "") end
  local off = math.floor(tz * 3600)
  local t, n = at + off, now + off
  local day, today = t // 86400, n // 86400
  local hm = ("%02d:%02d"):format(t % 86400 // 3600, t % 3600 // 60)
  if day == today then return hm end
  if today - day < 6 and day < today then return DAYS[day % 7 + 1] .. " " .. hm end
  local d, m = civil(day)
  return d .. " " .. MONTHS[m]
end

return U
