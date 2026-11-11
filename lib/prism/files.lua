--[[ prism.files: reading and writing the files PRISM keeps.

  exists(path)                 true if the file can be opened
  read(path)                   whole file as text, or nil
  readTable(path)              a serialized table (data files), or {} when missing/unreadable
  writeTable(path, t)          serialize t into path -> true | false, err
  loadLua(path, env)           run a Lua config file that returns a table -> table | nil, err
                               (err is nil when the file doesn't exist)
  writeAtomic(path, text)      write path.new, then swap it in -> true | false, err
  saveWithBackup(path, text)   keep the old contents as path.bak, then writeAtomic
]]

local serialization = require("serialization")

local F = {}

function F.exists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

function F.read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

function F.readTable(path)
  local data = F.read(path)
  return data and serialization.unserialize(data) or {}
end

function F.writeTable(path, t)
  local f, err = io.open(path, "w")
  if not f then return false, err end
  f:write(serialization.serialize(t))
  f:close()
  return true
end

function F.loadLua(path, env)
  if not F.exists(path) then return nil end
  local fn, err = loadfile(path, "t", env or {})
  if not fn then return nil, tostring(err) end
  local ok, t = pcall(fn)
  if not ok or type(t) ~= "table" then return nil, tostring(t) end
  return t
end

function F.writeAtomic(path, text)
  local filesystem = require("filesystem")
  local tmp = path .. ".new"
  local f, err = io.open(tmp, "w")
  if not f then return false, err end
  f:write(text)
  f:close()
  if filesystem.exists(path) then filesystem.remove(path) end
  filesystem.rename(tmp, path)
  return true
end

function F.saveWithBackup(path, text)
  local old = F.read(path)
  if old and old ~= text then
    local ok, err = F.writeAtomic(path .. ".bak", old)
    if not ok then return false, err end
  end
  return F.writeAtomic(path, text)
end

return F
