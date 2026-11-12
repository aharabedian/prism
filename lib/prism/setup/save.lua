--[[ prism.setup.save: showing what will be written, then writing it.

  review(path, text, shrc)   print the new config (and .shrc, if it changes)
  commit(path, text, shrc)   save path keeping path.bak, then .shrc -> true | false, reason
]]

local files = require("prism.files")
local paths = require("prism.setup.paths")

local S = {}

function S.review(path, text, shrc)
  print("")
  print("This will be saved to " .. path .. ":")
  io.write(text)
  if shrc then print(""); print("and " .. paths.SHRC .. " will be:"); io.write(shrc ~= "" and shrc or "(empty)\n") end
end

function S.commit(path, text, shrc)
  local ok, err = files.saveWithBackup(path, text)
  if not ok then return false, "can't write " .. path .. ": " .. tostring(err) end
  if shrc then
    ok, err = files.writeAtomic(paths.SHRC, shrc)
    if not ok then return false, "can't write " .. paths.SHRC .. ": " .. tostring(err) end
  end
  return true
end

return S
