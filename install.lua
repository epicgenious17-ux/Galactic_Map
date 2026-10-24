--[[
install.lua - puts the HD2 programs on this computer, from GitHub
(made by the PC's tools/dhremote.py - epicgenious17-ux/Galactic_Map)

  wget run https://raw.githubusercontent.com/epicgenious17-ux/Galactic_Map/main/install.lua <set>
  (this file itself may be a few minutes old after an upload - it still
  installs the newest programs: it asks git which commit is newest)

  warmap   the war table (map 52, storage 53) - also points it at epicgenious17-ux/Galactic_Map
  hud      smart glasses (51, 56...): hud, war table view, icons, voice lines
  strike   the strike computer (18): strike, gunner
  courier  a turtle that keeps something stocked (then: courier record)
  mender   a turtle with a Geo Scanner that puts back missing blocks (then: mender snapshot)
  shipcheck  a one-off probe of what a turtle on the ship can do (then: shipcheck)
  repair   the repair computer (ender + wired modem): repair, startup
  scout    the repair scout turtle (Geo Scanner + ender modem): records its route on its first start
  drone    a repair drone turtle (Weak Automata + Compass)

Settings (*.cfg), logs and the map's own files stay as they are. Reboot after.
]]
local REPO, BRANCH = "epicgenious17-ux/Galactic_Map", "main"
local set = ...

local function get(path, ref)
  local url = ("https://raw.githubusercontent.com/%s/%s/%s"):format(REPO, ref, path)
  local h, err = http.get({ url = url, binary = true })
  if not h then error(path .. ": " .. tostring(err), 0) end
  local body = h.readAll()
  h.close()
  return body
end

-- The newest commit from git's own ref listing (never cached: the branch's
-- copy on raw.githubusercontent.com can lag 5+ minutes)
local function head()
  local h = http.get({ url = ("https://github.com/%s.git/info/refs?service=git-upload-pack"):format(REPO), binary = true })
  if not h then return nil end
  local body = h.readAll() or ""
  h.close()
  for sha, ref in body:gmatch("(" .. ("%x"):rep(40) .. ") ([^\n]+)") do
    if ref:match("^[^%c]+") == "refs/heads/" .. BRANCH then return sha end
  end
end
local man = get("manifest.txt", head() or BRANCH)
local commit = man:match("\ncommit (%x+)")
if man:sub(1, 8) ~= "WARMAP 1" or not commit then error("manifest.txt is not the war table's", 0) end
local files, sets = {}, {}
for name, dest, size in man:gmatch("\nprog (%S+) (%S+) (%d+)") do
  sets[name] = true
  if name == set then files[#files + 1] = { dest = dest, size = tonumber(size) } end
end
if #files == 0 then
  local names = {}
  for name in pairs(sets) do names[#names + 1] = name end
  table.sort(names)
  print("install " .. table.concat(names, " | "))
  return
end

print(("installing %s (%d files) from %s"):format(set, #files, REPO))
for _, f in ipairs(files) do
  local body = get("programs/" .. set .. "/" .. f.dest, commit)
  if #body ~= f.size then error(("%s: got %d of %d bytes - try again"):format(f.dest, #body, f.size), 0) end
  local dir = fs.getDir(f.dest)
  if dir ~= "" then fs.makeDir(dir) end
  local h = fs.open(f.dest .. ".tmp", "wb")
  h.write(body)
  h.close()
  if fs.exists(f.dest) then fs.delete(f.dest) end
  fs.move(f.dest .. ".tmp", f.dest)
  print("  " .. f.dest)
end

if set == "warmap" then
  -- (the table downloads its map from the same place)
  local cfg = {}
  if fs.exists("warmap.cfg") then
    local h = fs.open("warmap.cfg", "r")
    cfg = textutils.unserialize(h.readAll()) or {}
    h.close()
  end
  cfg.remote, cfg.remoteBranch = REPO, BRANCH
  local h = fs.open("warmap.cfg", "w")
  h.write("-- warmap.cfg - settings for warmap.lua. Edit, save, then reboot.\n")
  h.write(textutils.serialize(cfg))
  h.close()
  print("  warmap.cfg: map from " .. REPO)
end
print("done - reboot this computer")
