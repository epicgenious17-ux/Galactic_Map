--[[
repair.lua - the destroyer's self-repair computer                      v1.0.2
A computer with an ender modem (for the scout and the HUD glasses) and a
wired modem whose cables reach the depot (the parts store: chests, barrels,
vaults - any inventories), each drone's pickup chest, and a full wired
modem block touching each drone at its dock.

The scout (turtles/scout.lua: Geo Scanner + ender modem) follows a route
you drove it along once, scanning every few blocks (radius 8 is free).
  survey   makes the copy: every block the scout sees, exactly as it is
           (repair.copy). The whitelist (repair.whitelist) then lists every
           kind of block seen: "yes" = the drones may put it back. Plain
           building blocks start "yes"; anything with a function, moving
           parts or stored data starts "no". Edit it, or allow / deny.
           Then the drones near the scout's dock are found (register).
  sweep    (every sweepEvery s, or typed) looks again: a whitelisted block
           gone from where the copy has it is damage, and damage within 2
           blocks of other damage is one group. The groups show red on the
           ship status hologram: middle-click picks, REPAIR orders (or
           type fix). A block that turned into something else is never
           touched, and nothing is ever dug.
The drones (turtles/drone.lua: Weak Automata Core + Compass - no room for
a modem: they talk through the wired modem at their dock) take the parts
this computer puts in their pickup chest, follow the scout's route to the
damage, place each block as the copy has it (facing, half, axis) from up
to 3 blocks away, and come home.
Traffic: a turtle moves only while it holds a permit from this computer.
The scout (a run, recording its route) goes out alone; drones go out up to
maxOut at once, stagger s apart, each on different damage. A drone never
stops on another drone's way, never goes where another works, and no path
goes through a hole (so none fills a hole another uses) or another
turtle's dock. Permits are kept in repair.out: a reboot never forgets a
turtle that is out, and a permit comes back only when that turtle reports
or says hello from its dock. Turtles never dig and never place into an
occupied cell; a drone going out that meets another turtle turns back at
once, one coming home waits, then steps aside (sooner or later by its id).
Parts: every inventory on the wired network is the depot - a row of
chests, a vault - including each drone's own chest (the one touching it).
For a trip this computer moves exactly the parts it needs into the first
slots of that chest, moving anything there out of the way, and the drone
takes just those.
Glue: tools/shipglue.py reads the save's Create super glue and honey glue
(the moving parts) into repair.glue - glued blocks never count as damage.
Fuel: the scout tops up at its dock from a fuel-only inventory touching it
(front, top or bottom - a vault of coal blocks is ideal); if that is a
separate chest on the wired network this computer refills it from the
depot. Drones get fuel in their pickup chest when low. fuelItems, best first.

A monitor next to it (advanced: colour and touch) shows the materials: what
rebuilding the whole ship takes, minus what the depot holds - need, have,
short, the biggest shortage first. Tap its top line: WHOLE SHIP / REPAIRABLE
(only whitelisted blocks) / DAMAGE NOW; tap the list: the next page.

Commands (type, then Enter):
  survey | sweep | register | stop      the scout's runs / find the drones
  status | groups | need                what is known, what parts are short
  fix <id> | fix all | unfix            order repairs (as the hologram)
  ignore <id>                           a group's area never counts again
                                        (a door, a contraption's parts) -
                                        glued blocks never count anyway
  whitelist | allow <name> | deny <name>   which blocks may be put back
  pickup <drone> <chest> | pickup <drone> find   a drone's pickup chest
  clear                                 forget the permit of a turtle that
                                        never came back (check it is home!)

Frames: the copy frame is the scout's dock = 0,0,0 on the ship's own grid
(x east, y up, z south as the Geo Scanner gives them; it never changes as
the ship turns). The hologram gets the nav-table frame (r, u, f): navAt
(the nav table, found by the survey) and bow (which way the bow points in
the copy frame - "north", as the stern thrusters in the schematic say).

repair.cfg (hand-editable; saved by register / ignore):
  sweepEvery = 1800   s between sweeps (false = only when typed)
  bow = "north"       the bow in the copy frame
  navAt = false       the nav table in the copy frame (the survey finds it)
  docks = {}          drone id = { at = { x, y, z }, facing = "north" }
  pickups = {}        drone id = its pickup chest's peripheral name (found
                      by register: a test item put in each chest until the
                      drone sees it; drone.cfg pickup overrides)
  depot = "auto"      the parts: "auto" = every inventory on the wired
                      network but the drones' pickup chests, or a list of
                      peripheral names
  notDepot = {}       inventories never taken from
  ignore = {}         boxes { x0, y0, z0, x1, y1, z1 } never counted
  jobMax = 48         blocks a drone trip at most
  reach = 3           blocks a drone places at most away (the Compass's
                      range: AP compassAccurePlaceRadius)
  fuelItems = { "minecraft:coal_block", "minecraft:coal", "minecraft:charcoal" }
  fuelLow = 1000      a drone below this much fuel gets fuelGive in its chest
  fuelGive = 4000     (fuel units: a coal block is 800, coal 80)
  scoutFuel = false   the scout's fuel inventory's peripheral name (found by
                      register; it may be the depot's vault itself)
  jobTimeout = 1800   s a drone may be out
  maxOut = 3          drones out at once (each on different damage)
  stagger = 8         s between two drones leaving
  glue = true         glued blocks (repair.glue: Create super glue, honey
                      glue - the moving parts) never count as damage
  placeRules = {}     block name = "facing" | "opposite" | "none": how its
                      facing is set (see R.placeArgs) when the default is wrong
]]

local ARGS = { ... }
local R = { VERSION = "1.0.2" }
R.PROTO, R.HOST = "destroyer.repair", "repair"
R.FILES = { cfg = "/repair.cfg", copy = "/repair.copy", white = "/repair.whitelist", damage = "/repair.damage",
  route = "/repair.route", out = "/repair.out", glue = "/repair.glue", log = "/repair.log" }
R.DEFAULTS = {
  sweepEvery = 1800, bow = "north", navAt = false, docks = {}, pickups = {}, depot = "auto", notDepot = {}, ignore = {},
  jobMax = 48, reach = 3, fuelItems = { "minecraft:coal_block", "minecraft:coal", "minecraft:charcoal" }, fuelLow = 1000,
  fuelGive = 4000, scoutFuel = false, jobTimeout = 1800, maxOut = 3, stagger = 8, glue = true, placeRules = {},
}
-- fuel units an item gives a turtle
R.FUEL = { ["minecraft:coal_block"] = 800, ["minecraft:coal"] = 80, ["minecraft:charcoal"] = 80, ["minecraft:blaze_rod"] = 120,
  ["minecraft:dried_kelp_block"] = 200 }
-- blocks a turtle moves through and a hole may hold (part of the name)
R.PASS = { "minecraft:water", "minecraft:lava", "minecraft:light", "minecraft:fire", "minecraft:short_grass",
  "minecraft:tall_grass", "minecraft:bubble_column", "minecraft:cave_air", "minecraft:void_air" }
-- the whitelist's first guess: never these (parts of names)...
R.DENY = { "button", "lever", "piston", "redstone", "repeater", "comparator", "torch", "trapdoor", "door", "gate", "sign",
  "banner", "skull", "head", "chest", "barrel", "furnace", "smoker", "anvil", "lectern", "beacon", "dispenser", "dropper",
  "hopper", "rail", "pressure_plate", "daylight", "lightning_rod", "end_rod", "water", "lava", "fire", "grindstone",
  "lamp", "bed", "candle", "flower", "sapling", "leaves", "scaffolding", "ladder", "vine", "observer", "target", "bell",
  "shulker", "spawner", "portal", "tnt", "note_block", "jukebox", "crafter", "crafting_table", "loom", "cartography",
  "fletching", "smithing", "stonecutter", "brewing", "cauldron", "composter", "enchanting", "bulb", "slime", "honey",
  "pointed", "conduit", "respawn", "lodestone", "campfire", "pot", "egg", "coral", "kelp", "grass", "turtle", "lantern",
  "frame", "carpet", "snow", "ice", "powder", "web", "cake", "sculk", "spore", "amethyst_cluster", "bud" }
R.DENY_END = { "sand", "gravel", ":light" }           -- (names ending so: falling sand, light blocks)
R.ALLOW = { "sea_lantern", "sandstone", "glass" }     -- (...though these contain a denied part)
-- ...and from other mods only their plain building blocks
R.ALLOW_MODS = { "^create:.*bricks?$", "^create:.*_casing$", "^create:.*tiles?$", "^create:cut_", "^create:polished_cut_",
  "^create:layered_", "^create:.*_pillar$", "^create:small_.*_bricks" }

local now = os.clock
local OFF = 2048
local function K(x, y, z) return (x + OFF) + (y + OFF) * 4096 + (z + OFF) * 16777216 end
local function XYZ(k)
  local x = k % 4096
  local rest = math.floor(k / 4096)
  local y = rest % 4096
  return x - OFF, y - OFF, math.floor(rest / 4096) - OFF
end
R.K, R.XYZ = K, XYZ
local function cheb(ax, ay, az, bx, by, bz) return math.max(math.abs(ax - bx), math.abs(ay - by), math.abs(az - bz)) end

R.FACE = { north = { 0, 0, -1 }, east = { 1, 0, 0 }, south = { 0, 0, 1 }, west = { -1, 0, 0 } }
R.RIGHT = { north = "east", east = "south", south = "west", west = "north" }
R.LEFT = { north = "west", west = "south", south = "east", east = "north" }
R.OPP = { north = "south", south = "north", east = "west", west = "east", up = "down", down = "up" }
R.BOW = { north = { 0, -1 }, south = { 0, 1 }, east = { 1, 0 }, west = { -1, 0 } }

---------------------------------------------------------------- files

function R.log(text)
  pcall(function()
    if fs.exists(R.FILES.log) and fs.getSize(R.FILES.log) > 32768 then
      if fs.exists(R.FILES.log .. ".old") then fs.delete(R.FILES.log .. ".old") end
      fs.move(R.FILES.log, R.FILES.log .. ".old")
    end
    local h = fs.open(R.FILES.log, "a")
    h.writeLine(("%9.1f %s"):format(now(), tostring(text)))
    h.close()
  end)
end

-- A line on the screen and in the log; shout = also a toast on the HUD glasses
function R.say(text, shout)
  print(text)
  R.log(text)
  if shout and R.haveWireless then pcall(rednet.broadcast, { op = "said", text = text }, R.PROTO) end
end

local function readTable(path)
  if not fs.exists(path) then return nil end
  local h = fs.open(path, "r")
  local t = textutils.unserialize(h.readAll())
  h.close()
  return type(t) == "table" and t or nil
end

local function writeTable(path, head, t)
  local h = fs.open(path, "w")
  h.write(head .. "\n" .. textutils.serialize(t))
  h.close()
end

function R.loadConfig()
  local cfg = readTable(R.FILES.cfg)
  local fresh = cfg == nil
  cfg = cfg or {}
  local function copy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k2, v2 in pairs(v) do t[k2] = copy(v2) end
    return t
  end
  for k, v in pairs(R.DEFAULTS) do
    if cfg[k] == nil then cfg[k] = copy(v) end
  end
  R.cfg = cfg
  if fresh then R.saveConfig() end
end

function R.saveConfig()
  pcall(writeTable, R.FILES.cfg, "-- repair.cfg - settings for repair.lua " .. R.VERSION .. " (see its header). Edit, save, reboot.", R.cfg)
end

---------------------------------------------------------------- block states

-- "name[k=v,...]" (keys sorted) - one entry of the copy's palette
function R.stateKey(name, state)
  local parts = {}
  for k, v in pairs(type(state) == "table" and state or {}) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
  table.sort(parts)
  return #parts > 0 and (name .. "[" .. table.concat(parts, ",") .. "]") or name
end

function R.parseState(key)
  local name, rest = key:match("^([^%[]+)%[(.*)%]$")
  local props = {}
  if not name then return key, props end
  for k, v in rest:gmatch("([^=,]+)=([^,]*)") do props[k] = v end
  return name, props
end

-- the palette: R.pal[i] = { key, name, item, props }, R.palOf[key] = i
function R.resetCopy()
  R.copy, R.pal, R.palOf, R.centers, R.centerGrid = {}, {}, {}, {}, {}
end

function R.palIndex(key, item)
  local i = R.palOf[key]
  if i then
    if item and not R.pal[i].item then R.pal[i].item = item end
    return i
  end
  local name, props = R.parseState(key)
  i = #R.pal + 1
  R.pal[i] = { key = key, name = name, item = item, props = props }
  R.palOf[key] = i
  return i
end

local function hasPart(name, list)
  for _, p in ipairs(list) do if name:find(p, 1, true) then return true end end
  return false
end

function R.passable(name) return hasPart(name, R.PASS) end

local function isTurtle(name) return name:find("computercraft:turtle", 1, true) ~= nil end

-- The whitelist's first guess for a block name
function R.suggest(name)
  if hasPart(name, R.ALLOW) then return true end
  if hasPart(name, R.DENY) then return false end
  for _, e in ipairs(R.DENY_END) do
    if name:sub(-#e) == e then return false end
  end
  if name:sub(1, 10) == "minecraft:" then return true end
  for _, p in ipairs(R.ALLOW_MODS) do
    if name:find(p) then return true end
  end
  return false
end

function R.allowed(i)
  local p = R.pal[i]
  return p ~= nil and R.white[p.name] == true
end

---------------------------------------------------------------- where it has looked

-- Each scan's cube, kept so "never seen" can be told from "empty"
local function bucket(x, y, z) return math.floor(x / 16) .. "," .. math.floor(y / 16) .. "," .. math.floor(z / 16) end

function R.addCenter(x, y, z, r)
  local c = { x, y, z, r }
  R.centers[#R.centers + 1] = c
  for bx = math.floor((x - r) / 16), math.floor((x + r) / 16) do
    for by = math.floor((y - r) / 16), math.floor((y + r) / 16) do
      for bz = math.floor((z - r) / 16), math.floor((z + r) / 16) do
        local b = bx .. "," .. by .. "," .. bz
        local l = R.centerGrid[b] or {}
        R.centerGrid[b] = l
        l[#l + 1] = c
      end
    end
  end
end

function R.scanned(x, y, z)
  for _, c in ipairs(R.centerGrid[bucket(x, y, z)] or {}) do
    if cheb(x, y, z, c[1], c[2], c[3]) <= c[4] then return true end
  end
  return false
end

function R.ignored(x, y, z)
  for _, b in ipairs(R.cfg.ignore or {}) do
    if type(b) == "table" and x >= b[1] and x <= b[4] and y >= b[2] and y <= b[5] and z >= b[3] and z <= b[6] then return true end
  end
  return R.glued(K(x, y, z))
end

-- Glued blocks (repair.glue, made on the PC by tools/shipglue.py from the
-- save: Create super glue and honey glue round the ship - its moving parts,
-- which vanish whenever they move; the ship-wide assembly glue left out).
-- Boxes x0 y0 z0 x1 y1 z1 from the nav table on the ship's grid -> the copy
-- frame once navAt is known. They never count as damage (cfg glue = false: off)
function R.loadGlue()
  R.glueBoxes, R.glueSet, R.glueAt = {}, nil, nil
  if not fs.exists(R.FILES.glue) then return 0 end
  local h = fs.open(R.FILES.glue, "r")
  local text = h.readAll() or ""
  h.close()
  for line in text:gmatch("[^\n]+") do
    local a, b, c, d, e, f = line:match("^(%-?%d+) (%-?%d+) (%-?%d+) (%-?%d+) (%-?%d+) (%-?%d+)")
    if a then R.glueBoxes[#R.glueBoxes + 1] = { tonumber(a), tonumber(b), tonumber(c), tonumber(d), tonumber(e), tonumber(f) } end
  end
  return #R.glueBoxes
end

function R.glued(k)
  if R.cfg.glue == false or not R.glueBoxes or #R.glueBoxes == 0 or type(R.cfg.navAt) ~= "table" then return false end
  local n = R.cfg.navAt
  local at = n[1] .. "," .. n[2] .. "," .. n[3]
  if R.glueAt ~= at then
    R.glueSet, R.glueAt = {}, at
    for _, b in ipairs(R.glueBoxes) do
      for x = b[1], b[4] do
        for y = b[2], b[5] do
          for z = b[3], b[6] do R.glueSet[K(n[1] + x, n[2] + y, n[3] + z)] = true end
        end
      end
    end
  end
  return R.glueSet[k] == true
end

-- How many blocks of the copy are glued
function R.gluedCount()
  if not R.glued(K(0, 0, 0)) and not R.glueSet then return 0 end
  local n = 0
  for k in pairs(R.glueSet or {}) do if R.copy[k] then n = n + 1 end end
  return n
end

---------------------------------------------------------------- scans

-- One scan from the scout: { op = "scan", run, mode, n, at = { x, y, z },
-- r = radius, blocks = { { dx, dy, dz, state key, item }, ... } }.
-- survey: into the copy. sweep: against it - the damage in that cube.
-- -> blocks taken, damage found
function R.takeScan(msg, mode)
  local at, r = msg.at, tonumber(msg.r) or 8
  if type(at) ~= "table" or type(msg.blocks) ~= "table" then return 0, 0 end
  local ax, ay, az = tonumber(at[1]) or 0, tonumber(at[2]) or 0, tonumber(at[3]) or 0
  local got, turtles = {}, {}
  for _, b in ipairs(msg.blocks) do
    if type(b) == "table" and tonumber(b[1]) and type(b[4]) == "string" then
      local k = K(ax + b[1], ay + b[2], az + b[3])
      if isTurtle(b[4]) then turtles[k] = true else got[k] = b end
    end
  end
  local taken, found = 0, 0
  if mode == "survey" then
    for k, b in pairs(got) do
      R.copy[k] = R.palIndex(b[4], type(b[5]) == "string" and b[5] or nil)
      taken = taken + 1
    end
    R.addCenter(ax, ay, az, r)
  elseif mode == "sweep" then
    for x = ax - r, ax + r do
      for y = ay - r, ay + r do
        for z = az - r, az + r do
          local k = K(x, y, z)
          local want = R.copy[k]
          if want and not turtles[k] and R.allowed(want) and not R.ignored(x, y, z) then
            local b = got[k]
            if not b or (R.passable(b[4]) and not R.passable(R.pal[want].name)) then
              if not R.damage[k] then found = found + 1 end
              R.damage[k] = true
            elseif R.damage[k] then
              R.damage[k] = nil                           -- (back: someone put it back)
              R.ordered[k], R.tries[k] = nil, nil
            end
          end
        end
      end
    end
    taken = #msg.blocks
  end
  return taken, found
end

-- Turtles in a look from the scout's dock: { [key] = facing }
function R.turtlesIn(msg)
  local out = {}
  local at = type(msg.at) == "table" and msg.at or { 0, 0, 0 }
  for _, b in ipairs(type(msg.blocks) == "table" and msg.blocks or {}) do
    if type(b) == "table" and type(b[4]) == "string" and isTurtle(b[4]) and not (b[1] == 0 and b[2] == 0 and b[3] == 0) then
      local _, props = R.parseState(b[4])
      out[K(at[1] + b[1], at[2] + b[2], at[3] + b[3])] = props.facing
    end
  end
  return out
end

-- The one turtle that turned right between two looks -> its spot, facing before
function R.findTurned(before, after)
  local hit
  for k, f in pairs(before) do
    if f and after[k] == R.RIGHT[f] then
      if hit then return nil end                       -- (two turned: cannot tell)
      hit = k
    end
  end
  if not hit then return nil end
  local x, y, z = XYZ(hit)
  return { x, y, z }, before[hit]
end

-- The nav table in the copy (Create Avionics' navigation table) -> { x, y, z } or nil, how many
function R.findNav()
  local found = {}
  for k, i in pairs(R.copy) do
    if R.pal[i].name:find("navigation_table", 1, true) then found[#found + 1] = k end
  end
  if #found ~= 1 then return nil, #found end
  local x, y, z = XYZ(found[1])
  return { x, y, z }, 1
end

-- The scout's route (F B U D L R, from its dock) -> the cells it passes, in order
function R.routeCells(moves, facing)
  local x, y, z, f = 0, 0, 0, facing
  local out = { K(0, 0, 0) }
  if not R.FACE[f] then return out end
  for c in tostring(moves or ""):gmatch(".") do
    local v = R.FACE[f]
    if c == "F" then x, z = x + v[1], z + v[3]
    elseif c == "B" then x, z = x - v[1], z - v[3]
    elseif c == "U" then y = y + 1
    elseif c == "D" then y = y - 1
    elseif c == "R" then f = R.RIGHT[f]
    elseif c == "L" then f = R.LEFT[f] end
    if c == "F" or c == "B" or c == "U" or c == "D" then out[#out + 1] = K(x, y, z) end
  end
  return out
end

---------------------------------------------------------------- the copy on disk

-- repair.copy: a header (palette, scan cubes) then the blocks as runs along
-- z of one state, per (x, y) line - binary when string.pack is there
function R.saveCopy(path)
  path = path or R.FILES.copy
  local lines, order = {}, {}
  for k, i in pairs(R.copy) do
    local x, y, z = XYZ(k)
    local lk = x * 8192 + y
    local l = lines[lk]
    if not l then
      l = { x = x, y = y }
      lines[lk] = l
      order[#order + 1] = lk
    end
    l[#l + 1] = { z, i }
  end
  table.sort(order)
  local head = { "RCOPY1", "pal " .. #R.pal }
  for _, p in ipairs(R.pal) do head[#head + 1] = p.key .. "\t" .. (p.item or "-") end
  head[#head + 1] = "centers " .. #R.centers
  for _, c in ipairs(R.centers) do head[#head + 1] = table.concat(c, " ") end
  local binary = string.pack ~= nil and not R.TEXT_COPY
  head[#head + 1] = (binary and "runs " or "text ") .. #order
  local parts = { table.concat(head, "\n") .. "\n" }
  for _, lk in ipairs(order) do
    local l = lines[lk]
    R.breathe()
    table.sort(l, function(a, b) return a[1] < b[1] end)
    local runs, cur = {}, nil
    for _, e in ipairs(l) do
      if cur and e[1] == cur[1] + cur[2] and e[2] == cur[3] then cur[2] = cur[2] + 1
      else
        cur = { e[1], 1, e[2] }
        runs[#runs + 1] = cur
      end
    end
    if binary then
      local b = { string.pack("<i2i2I2", l.x, l.y, #runs) }
      for _, ru in ipairs(runs) do b[#b + 1] = string.pack("<i2I2I2", ru[1], ru[2], ru[3]) end
      parts[#parts + 1] = table.concat(b)
    else
      local t = {}
      for _, ru in ipairs(runs) do t[#t + 1] = ru[1] .. "+" .. ru[2] .. "*" .. ru[3] end
      parts[#parts + 1] = l.x .. "," .. l.y .. ":" .. table.concat(t, ";") .. "\n"
    end
  end
  local h = fs.open(path, "wb")
  h.write(table.concat(parts))
  h.close()
end

function R.loadCopy(path)
  path = path or R.FILES.copy
  R.resetCopy()
  if not fs.exists(path) then return false end
  local h = fs.open(path, "rb")
  local data = h.readAll()
  h.close()
  if not data or data:sub(1, 7) ~= "RCOPY1\n" then return false end
  local pos = 8
  local function line()
    local e = data:find("\n", pos, true)
    if not e then return nil end
    local s = data:sub(pos, e - 1)
    pos = e + 1
    return s
  end
  local np = tonumber((line() or ""):match("^pal (%d+)$"))
  if not np then return false end
  for _ = 1, np do
    local key, item = (line() or ""):match("^(.-)\t(.*)$")
    R.palIndex(key or "?", item ~= "-" and item or nil)
  end
  local nc = tonumber((line() or ""):match("^centers (%d+)$")) or 0
  for _ = 1, nc do
    local x, y, z, r = (line() or ""):match("^(%-?%d+) (%-?%d+) (%-?%d+) (%d+)$")
    if x then R.addCenter(tonumber(x), tonumber(y), tonumber(z), tonumber(r)) end
  end
  local kind, nl = (line() or ""):match("^(%a+) (%d+)$")
  nl = tonumber(nl) or 0
  if kind == "runs" then
    for _ = 1, nl do
      local x, y, nr
      R.breathe()
      x, y, nr, pos = string.unpack("<i2i2I2", data, pos)
      for _ = 1, nr do
        local z0, len, idx
        z0, len, idx, pos = string.unpack("<i2I2I2", data, pos)
        for z = z0, z0 + len - 1 do R.copy[K(x, y, z)] = idx end
      end
    end
  else
    for _ = 1, nl do
      local l = line() or ""
      R.breathe()
      local x, y, rest = l:match("^(%-?%d+),(%-?%d+):(.*)$")
      if x then
        x, y = tonumber(x), tonumber(y)
        for z0, len, idx in rest:gmatch("(%-?%d+)%+(%d+)%*(%d+)") do
          for z = tonumber(z0), tonumber(z0) + tonumber(len) - 1 do R.copy[K(x, y, z)] = tonumber(idx) end
        end
      end
    end
  end
  return true
end

function R.copySize()
  local n = 0
  for _ in pairs(R.copy) do n = n + 1 end
  R.copyCount = n
  return n
end

---------------------------------------------------------------- the whitelist

function R.loadWhitelist()
  R.white = {}
  if not fs.exists(R.FILES.white) then return end
  local h = fs.open(R.FILES.white, "r")
  local text = h.readAll() or ""
  h.close()
  for yes, name in text:gmatch("\n?%s*(%a+)%s+([%w_:%.%-/]+)") do
    if yes == "yes" or yes == "no" then R.white[name] = yes == "yes" end
  end
  R.whiteStamp = (R.whiteStamp or 0) + 1
end

-- Every block name in the copy, new ones guessed; written with how many there are
function R.saveWhitelist()
  local count = {}
  for _, i in pairs(R.copy) do
    local n = R.pal[i].name
    count[n] = (count[n] or 0) + 1
  end
  for n in pairs(count) do
    if R.white[n] == nil then R.white[n] = R.suggest(n) end
  end
  local names = {}
  for n in pairs(R.white) do names[#names + 1] = n end
  table.sort(names, function(a, b)
    if (count[a] or 0) ~= (count[b] or 0) then return (count[a] or 0) > (count[b] or 0) end
    return a < b
  end)
  local out = { "-- repair.whitelist - which blocks the drones may put back (repair.lua " .. R.VERSION .. ").",
    "-- yes / no, the block, how many the copy has. Edit and save (or type allow / deny at the repair computer)." }
  for _, n in ipairs(names) do out[#out + 1] = ("%-3s %s %d"):format(R.white[n] and "yes" or "no", n, count[n] or 0) end
  local h = fs.open(R.FILES.white, "w")
  h.write(table.concat(out, "\n") .. "\n")
  h.close()
  R.whiteStamp = (R.whiteStamp or 0) + 1
end

-- allow / deny every name containing `part` -> how many changed
function R.setWhite(part, yes)
  local n = 0
  for name, v in pairs(R.white) do
    if name:find(part, 1, true) and v ~= yes then
      R.white[name] = yes
      n = n + 1
    end
  end
  return n
end

---------------------------------------------------------------- damage and groups

function R.saveDamage()
  local t = { damage = {}, ordered = {}, tries = {} }
  for k in pairs(R.damage) do t.damage[#t.damage + 1] = k end
  for k in pairs(R.ordered) do t.ordered[#t.ordered + 1] = k end
  for k, n in pairs(R.tries) do t.tries[#t.tries + 1] = { k, n } end
  pcall(writeTable, R.FILES.damage, "-- repair.damage - the damage found, the repairs ordered", t)
end

function R.loadDamage()
  R.damage, R.ordered, R.tries, R.fixing = {}, {}, {}, {}
  local t = readTable(R.FILES.damage)
  if not t then return end
  for _, k in ipairs(t.damage or {}) do R.damage[k] = true end
  for _, k in ipairs(t.ordered or {}) do if R.damage[k] then R.ordered[k] = true end end
  for _, e in ipairs(t.tries or {}) do R.tries[e[1]] = e[2] end
end

-- The damage in groups: each missing block pulls in any other within 2 blocks.
-- -> list (biggest first) of { id = its lowest key, keys, box = { x0, y0, z0, x1, y1, z1 }, c = { x, y, z } }
function R.regroup()
  local parent = {}
  local function find(k)
    while parent[k] ~= k do
      parent[k] = parent[parent[k]]
      k = parent[k]
    end
    return k
  end
  for k in pairs(R.damage) do parent[k] = k end
  for k in pairs(R.damage) do
    local x, y, z = XYZ(k)
    for dx = -2, 2 do
      for dy = -2, 2 do
        for dz = -2, 2 do
          local o = K(x + dx, y + dy, z + dz)
          if o ~= k and parent[o] then
            local a, b = find(k), find(o)
            if a ~= b then parent[a] = b end
          end
        end
      end
    end
  end
  local byRoot, list = {}, {}
  for k in pairs(R.damage) do
    local root = find(k)
    local g = byRoot[root]
    if not g then
      g = { keys = {} }
      byRoot[root] = g
      list[#list + 1] = g
    end
    g.keys[#g.keys + 1] = k
  end
  for _, g in ipairs(list) do
    table.sort(g.keys)
    g.id = g.keys[1]
    local b = { math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge }
    local sx, sy, sz = 0, 0, 0
    for _, k in ipairs(g.keys) do
      local x, y, z = XYZ(k)
      b[1], b[2], b[3] = math.min(b[1], x), math.min(b[2], y), math.min(b[3], z)
      b[4], b[5], b[6] = math.max(b[4], x), math.max(b[5], y), math.max(b[6], z)
      sx, sy, sz = sx + x, sy + y, sz + z
    end
    g.box, g.c = b, { sx / #g.keys, sy / #g.keys, sz / #g.keys }
  end
  table.sort(list, function(a, b)
    if #a.keys ~= #b.keys then return #a.keys > #b.keys end
    return a.id < b.id
  end)
  R.groupList = list
  R.groupsDirty = true
  R.damageStamp = (R.damageStamp or 0) + 1
  return list
end

function R.groupState(g)
  local st = "damaged"
  for _, k in ipairs(g.keys) do
    if R.fixing[k] then return "fixing" end
    if R.ordered[k] then st = "queued" end
  end
  return st
end

function R.findGroup(id)
  for _, g in ipairs(R.groupList or {}) do if g.id == id then return g end end
end

-- A copy-frame point -> the nav-table frame { r, u, f } (nil: no nav table known)
function R.toNav(x, y, z)
  local n = R.cfg.navAt
  if type(n) ~= "table" then return nil end
  local b = R.BOW[R.cfg.bow] or R.BOW.north
  local dx, dy, dz = x - n[1], y - n[2], z - n[3]
  return { r = dx * -b[2] + dz * b[1], u = dy, f = dx * b[1] + dz * b[2] }
end

-- The groups for the hologram (status.lua): { id, c = { r, u, f }, n, box, st }
function R.groupsMessage()
  local out = {}
  for _, g in ipairs(R.groupList or {}) do
    local c = R.toNav(g.c[1], g.c[2], g.c[3])
    local a, b = R.toNav(g.box[1], g.box[2], g.box[3]), R.toNav(g.box[4], g.box[5], g.box[6])
    out[#out + 1] = { id = g.id, c = c, n = #g.keys, st = R.groupState(g),
      box = a and { math.min(a.r, b.r), math.min(a.u, b.u), math.min(a.f, b.f), math.max(a.r, b.r), math.max(a.u, b.u),
        math.max(a.f, b.f) } or nil }
  end
  return { op = "groups", groups = out }
end

function R.broadcastGroups()
  R.groupsDirty, R.groupsAt = false, now()
  if R.haveWireless then pcall(rednet.broadcast, R.groupsMessage(), R.PROTO) end
end

-- Order a group's repair (the hologram's REPAIR, or typed) -> blocks ordered
function R.order(id)
  local g = R.findGroup(id)
  if not g then return 0 end
  local n = 0
  for _, k in ipairs(g.keys) do
    if not R.ordered[k] then n = n + 1 end
    R.ordered[k], R.tries[k] = true, nil
  end
  R.groupsDirty = true
  return n
end

---------------------------------------------------------------- the depot

function R.inventories()
  local out = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType(n, "inventory") then out[#out + 1] = n end
  end
  table.sort(out)
  return out
end

-- Every inventory on the wired network (the drones' chests too: they hold
-- stock like any other) but notDepot
function R.depotNames()
  local d = R.cfg.depot
  if type(d) == "table" then return d end
  if type(d) == "string" and d ~= "auto" then return { d } end
  local skip = {}
  for _, n in ipairs(type(R.cfg.notDepot) == "table" and R.cfg.notDepot or {}) do skip[n] = true end
  local out = {}
  for _, n in ipairs(R.inventories()) do if not skip[n] then out[#out + 1] = n end end
  return out
end

-- What the depot holds: { [item] = { total, at = { { inv, slot, count }, ... } } }
function R.stock()
  local out = {}
  for _, inv in ipairs(R.depotNames()) do
    local ok, list = pcall(peripheral.call, inv, "list")
    if ok and type(list) == "table" then
      for slot, it in pairs(list) do
        if type(it) == "table" and it.name then
          local e = out[it.name] or { total = 0, at = {} }
          out[it.name] = e
          e.total = e.total + (it.count or 0)
          e.at[#e.at + 1] = { inv = inv, slot = slot, count = it.count or 0 }
        end
      end
    end
  end
  return out
end

-- n of item from the depot into inventory `to` -> how many went
function R.give(stock, item, n, to)
  local e, moved = stock[item], 0
  for _, a in ipairs(e and e.at or {}) do
    if moved >= n then break end
    if a.count > 0 and a.inv ~= to then
      local ok, m = pcall(peripheral.call, a.inv, "pushItems", to, a.slot, math.min(a.count, n - moved))
      m = ok and tonumber(m) or 0
      a.count, moved, e.total = a.count - m, moved + m, e.total - m
    end
  end
  return moved
end

function R.fuelItems()
  local l = type(R.cfg.fuelItems) == "table" and R.cfg.fuelItems or {}
  if #l == 0 and type(R.cfg.fuelItem) == "string" then l = { R.cfg.fuelItem } end    -- (an older repair.cfg)
  return l
end

-- Fuel worth `units` into inventory `to`, best fuel first -> units given
function R.giveFuel(stock, to, units)
  local given = 0
  for _, item in ipairs(R.fuelItems()) do
    local v = R.FUEL[item] or 80
    if given >= units then break end
    local n = math.ceil((units - given) / v)
    given = given + R.give(stock, item, n, to) * v
  end
  return given
end

-- The fuel an inventory holds, in units
function R.fuelIn(inv)
  local ok, list = pcall(peripheral.call, inv, "list")
  local units = 0
  if ok and type(list) == "table" then
    for _, it in pairs(list) do
      for _, f in ipairs(R.fuelItems()) do
        if it.name == f then units = units + (it.count or 0) * (R.FUEL[f] or 80) end
      end
    end
  end
  return units
end

-- The scout's fuel inventory kept full enough for a top-up from the rest of
-- the network (a vault of coal blocks already is: nothing to do)
function R.fuelScout(stock)
  local chest, s = R.cfg.scoutFuel, R.scout
  if not chest or not s then return 0 end
  local want = math.max((tonumber(s.limit) or 20000) - (tonumber(s.fuel) or 0), 800) - R.fuelIn(chest)
  if want <= 0 then return 0 end
  return R.giveFuel(stock or R.stock(), chest, want)
end

---------------------------------------------------------------- the permits (traffic)

-- The turtles out, each with its permit: id -> { kind, at, job, loading,
-- lost } - kept on disk across reboots. The scout (a run, recording) goes
-- out alone; drones on jobs up to maxOut at once, each on its own damage
-- (R.avoidFor keeps them apart)
R.outs = {}

function R.saveOuts()
  local t = {}
  for id, o in pairs(R.outs) do t[#t + 1] = { id = id, kind = o.kind } end
  if #t == 0 then
    if fs.exists(R.FILES.out) then fs.delete(R.FILES.out) end
    return
  end
  pcall(writeTable, R.FILES.out, "-- repair.out - the turtles out (each holds a permit to move)", t)
end

function R.setOut(id, kind, job)
  R.outs[id] = { kind = kind, at = now(), job = job }
  R.saveOuts()
end

-- (one turtle home; no id: all)
function R.clearOut(id)
  if id then R.outs[id] = nil else R.outs = {} end
  R.saveOuts()
end

-- (at start: turtles out before a reboot are still out - where, nobody knows:
-- nothing new goes out until they say hello from their docks)
function R.loadOut()
  R.outs = {}
  local t = readTable(R.FILES.out) or {}
  if t.id then t = { t } end                        -- (an older repair.out: one turtle)
  for _, e in ipairs(t) do
    if e.id then R.outs[e.id] = { kind = e.kind, at = now(), lost = true } end
  end
end

function R.anyOut() return next(R.outs) ~= nil end

function R.dronesOut()
  local n = 0
  for _, o in pairs(R.outs) do if o.kind == "job" then n = n + 1 end end
  return n
end

function R.outText()
  local ids, t = {}, {}
  for id in pairs(R.outs) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do t[#t + 1] = ("turtle %d (%s%s)"):format(id, tostring(R.outs[id].kind), R.outs[id].lost and ", since before a reboot" or "") end
  return #t > 0 and table.concat(t, ", ") or nil
end

-- What another drone's job holds: block = cells nobody may enter (where it
-- works, what it fills); noDwell = cells nobody may stop on (its way there
-- and back - a shared corridor is fine to pass through)
function R.avoidFor(self)
  local block, noDwell = {}, {}
  for id, o in pairs(R.outs) do
    if id ~= self and o.job then
      for _, k in ipairs(o.job.dwell or {}) do block[k] = true end
      for _, k in ipairs(o.job.keys or {}) do block[k] = true end
      for _, k in ipairs(o.job.cells or {}) do noDwell[k] = true end
    end
  end
  return { block = block, noDwell = noDwell }
end

-- A job's parts into the first slots of its drone's chest - whatever is there
-- moved out of the way, into the other inventories (else further down the
-- chest) - so the drone takes exactly those stacks. Nothing is ever put into
-- the scout's fuel inventory (fuel may come from it).
-- want = { { item, count }, ... } -> how many stacks, or nil + why
function R.stage(chest, want)
  local stacks = {}
  for _, w in ipairs(want) do
    local n = w[2]
    while n > 0 do
      local s = math.min(64, n)
      stacks[#stacks + 1] = { w[1], s }
      n = n - s
    end
  end
  if #stacks > 16 then return nil, "more than 16 stacks" end
  local lists = {}
  local function list(inv)
    if not lists[inv] then
      local ok, l = pcall(peripheral.call, inv, "list")
      lists[inv] = ok and type(l) == "table" and l or {}
    end
    return lists[inv]
  end
  local function push(from, slot, n, to, toSlot)
    local ok, m = pcall(peripheral.call, from, "pushItems", to, slot, n, toSlot)
    m = ok and tonumber(m) or 0
    if m > 0 then lists[from], lists[to] = nil, nil end
    return m
  end
  local others = {}
  for _, n in ipairs(R.depotNames()) do
    if n ~= chest and n ~= R.cfg.scoutFuel then others[#others + 1] = n end
  end
  -- (1) its first slots emptied
  for s = 1, #stacks do
    local it = list(chest)[s]
    if it then
      local left = it.count
      for _, o in ipairs(others) do
        if left <= 0 then break end
        left = left - push(chest, s, left, o)
      end
      if left > 0 then
        local ok, size = pcall(peripheral.call, chest, "size")
        for t = (ok and tonumber(size) or 27), #stacks + 1, -1 do
          if left <= 0 then break end
          if not list(chest)[t] then left = left - push(chest, s, left, chest, t) end
        end
      end
      if left > 0 then return nil, "no room to make way in " .. chest end
    end
  end
  -- (2) each stack into its slot: from the other inventories first, then the
  -- chest's own later slots, then (fuel) the scout's fuel inventory
  for j, st in ipairs(stacks) do
    local need = st[2]
    local sources = {}
    for _, o in ipairs(others) do sources[#sources + 1] = o end
    sources[#sources + 1] = chest
    if R.cfg.scoutFuel and R.cfg.scoutFuel ~= chest then sources[#sources + 1] = R.cfg.scoutFuel end
    for _, inv in ipairs(sources) do
      for slot, it in pairs(list(inv)) do
        if need <= 0 then break end
        if it.name == st[1] and not (inv == chest and slot <= #stacks) then
          need = need - push(inv, slot, math.min(need, it.count), chest, j)
        end
      end
      if need <= 0 then break end
    end
    if need > 0 then return nil, ("%d %s not found to load"):format(need, st[1]) end
  end
  return #stacks
end

-- Whatever is in a pickup chest back into the depot -> items moved
function R.takeBack(from)
  if not from then return 0 end
  local ok, list = pcall(peripheral.call, from, "list")
  if not ok or type(list) ~= "table" then return 0 end
  local moved = 0
  for slot, it in pairs(list) do
    local left = it.count or 0
    for _, inv in ipairs(R.depotNames()) do
      if left <= 0 then break end
      local ok2, m = pcall(peripheral.call, from, "pushItems", inv, slot, left)
      m = ok2 and tonumber(m) or 0
      left, moved = left - m, moved + m
    end
  end
  return moved
end

---------------------------------------------------------------- paths

local SIX = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }

-- (long sums give the server a moment now and then - the task never holds it 7 s)
local beats = 0
function R.breathe()
  beats = beats + 1
  if beats % 4000 == 0 then
    os.queueEvent("repair_breathe")
    os.pullEvent("repair_breathe")
  end
end

-- A cell a turtle may move into: empty in the copy (and looked at), or
-- something it moves through - not reserved. A missing block's spot is not:
-- no path goes through a hole, so no drone ever fills one another uses
function R.free(k, reserved)
  if reserved[k] then return false end
  local i = R.copy[k]
  if i then
    local p = R.pal[i]
    if p.pass == nil then p.pass = R.passable(p.name) end
    return p.pass
  end
  return R.scanned(XYZ(k))
end

-- Breadth-first from start over free cells inside box -> dist[k], prev[k]
function R.flood(sk, box, reserved)
  local dist, prev, q, head = { [sk] = 0 }, {}, { sk }, 1
  while q[head] do
    local k = q[head]
    head = head + 1
    local x, y, z = XYZ(k)
    for _, d in ipairs(SIX) do
      local nx, ny, nz = x + d[1], y + d[2], z + d[3]
      if nx >= box[1] and nx <= box[4] and ny >= box[2] and ny <= box[5] and nz >= box[3] and nz <= box[6] then
        local nk = K(nx, ny, nz)
        if dist[nk] == nil and R.free(nk, reserved) then
          dist[nk], prev[nk] = dist[k] + 1, k
          q[#q + 1] = nk
        end
      end
      R.breathe()
    end
  end
  return dist, prev
end

local function pathTo(prev, sk, gk)
  local out, k = {}, gk
  while k and k ~= sk do
    table.insert(out, 1, k)
    k = prev[k]
  end
  return out
end

local function around(x, y, z, r) return { x - r, y - r, z - r, x + r, y + r, z + r } end

-- The route from index a to b, loops cut out -> keys (route[a] first)
function R.slice(route, a, b)
  local out, at = {}, {}
  for i = a, b, a <= b and 1 or -1 do
    local k = route[i]
    if at[k] then
      for j = #out, at[k] + 1, -1 do
        at[out[j]] = nil
        out[j] = nil
      end
    else
      out[#out + 1] = k
      at[k] = #out
    end
  end
  return out
end

-- How a drone sets a block's state with the Weak Automata's placeBlock
-- (AdvanceDirectionalPlaceContext: the clicked face is `top`, the look is
-- `front`, the nearest look `anchor`):
--   slabs, stairs, trapdoors: half / type from top (up = bottom, down = top)
--   axis (logs, pillars, chains): top along the axis
--   stairs, fence gates, doors face where they look: front = facing;
--   everything else faces whoever placed it: front and anchor = opposite
-- -> args, double (a double slab: a second slab from right above)
function R.placeArgs(p)
  local s, rule, a = p.props or {}, R.cfg.placeRules[p.name], {}
  if rule == "none" then return a, false end
  local double = s.type == "double"
  if s.type == "top" or s.type == "bottom" or double then a.top = s.type == "top" and "down" or "up" end
  if s.half == "top" or s.half == "bottom" then a.top = s.half == "top" and "down" or "up" end
  if s.axis and not s.facing then a.top = ({ x = "east", y = "up", z = "south" })[s.axis] end
  local f = s.facing
  if f and R.OPP[f] then
    local looks = (s.shape ~= nil and s.half ~= nil) or s.in_wall ~= nil or s.hinge ~= nil
    local mode = rule or (looks and "facing" or "opposite")
    if mode == "facing" then a.front, a.anchor = f, f
    else a.front, a.anchor = R.OPP[f], R.OPP[f] end
    if a.front == "up" or a.front == "down" then a.front = nil end
  end
  return a, double
end

local function placeStep(t, from)
  local tx, ty, tz = XYZ(t)
  local x, y, z = XYZ(from)
  local p = R.pal[R.copy[t]]
  local args, double = R.placeArgs(p)
  return { "place", k = t, off = { tx - x, ty - y, tz - z }, item = p.item, args = args, double = double or nil }
end

-- Placing a set of targets from start inside region: each time the reachable
-- spot that covers the most targets (within reach, best within 1 - free),
-- walk there, place them. A double slab only from right above it. Never a
-- spot in noDwell (another drone's way).
-- -> { steps, placed = { keys }, dwell = { spots }, left = { key = true } }
function R.tour(start, targets, region, reserved, noDwell)
  local reach = tonumber(R.cfg.reach) or 3
  noDwell = noDwell or {}
  local left = {}
  for _, k in ipairs(targets) do left[k] = true end
  local steps, placed, dwell, pos = {}, {}, {}, start
  while next(left) do
    local dist, prev = R.flood(pos, region, reserved)
    local cand = {}
    for t in pairs(left) do
      local tx, ty, tz = XYZ(t)
      for dx = -reach, reach do
        for dy = -reach, reach do
          for dz = -reach, reach do
            local c = K(tx + dx, ty + dy, tz + dz)
            if dist[c] and c ~= t and not noDwell[c] then cand[c] = true end
          end
        end
      end
    end
    local best, bestScore, bestCovers
    for c in pairs(cand) do
      local x, y, z = XYZ(c)
      local n1, covers = 0, {}
      for t in pairs(left) do
        local tx, ty, tz = XYZ(t)
        local m = cheb(x, y, z, tx, ty, tz)
        local p = R.pal[R.copy[t]]
        local double = p.props.type == "double"
        if m <= reach and (not double or (x == tx and z == tz and y == ty + 1)) then
          covers[#covers + 1] = t
          if m <= 1 then n1 = n1 + 1 end
        end
      end
      if #covers > 0 then
        local score = 3 * n1 + #covers - 0.05 * dist[c]
        if not best or score > bestScore or (score == bestScore and c < best) then best, bestScore, bestCovers = c, score, covers end
      end
      R.breathe()
    end
    if not best then break end
    local path = pathTo(prev, pos, best)
    if #path > 0 then steps[#steps + 1] = { "go", cells = path } end
    pos = best
    dwell[#dwell + 1] = best
    table.sort(bestCovers)
    for _, t in ipairs(bestCovers) do
      steps[#steps + 1] = placeStep(t, best)
      placed[#placed + 1] = t
      left[t] = nil
    end
  end
  return { steps = steps, placed = placed, dwell = dwell, left = left, pos = pos }
end

-- A drone's trip from its dock to the targets: straight there when they are
-- near the dock, else to the scout's route, along it, and off it near them.
-- avoid (R.avoidFor): other drones' jobs - never into where they work, never
-- stopping on their way.
-- -> { steps (cells as { x, y, z }), placed, left, cells, dwell } or nil, why
function R.plan(dock, targets, self, avoid)
  local reach = tonumber(R.cfg.reach) or 3
  avoid = avoid or { block = {}, noDwell = {} }
  local reserved = { [K(0, 0, 0)] = true }                  -- (the scout's dock, and the other drones')
  for id, d in pairs(R.cfg.docks) do
    if id ~= self and type(d) == "table" and type(d.at) == "table" then reserved[K(d.at[1], d.at[2], d.at[3])] = true end
  end
  for k in pairs(avoid.block or {}) do reserved[k] = true end
  for _, k in ipairs(targets) do reserved[k] = true end      -- (never walked through: about to be filled)
  local box = { math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge }
  local mx, my, mz = 0, 0, 0
  for _, k in ipairs(targets) do
    local x, y, z = XYZ(k)
    box = { math.min(box[1], x), math.min(box[2], y), math.min(box[3], z), math.max(box[4], x), math.max(box[5], y), math.max(box[6], z) }
    mx, my, mz = mx + x / #targets, my + y / #targets, mz + z / #targets
  end
  local pad = reach + 6
  local function region(k)
    local x, y, z = XYZ(k)
    return { math.min(box[1] - pad, x - 1), math.min(box[2] - pad, y - 1), math.min(box[3] - pad, z - 1),
      math.max(box[4] + pad, x + 1), math.max(box[5] + pad, y + 1), math.max(box[6] + pad, z + 1) }
  end
  local dk = K(dock.at[1], dock.at[2], dock.at[3])
  -- (ways in: from the dock itself, or off the route at the cells nearest the damage)
  local entries = { { from = dk } }
  local route = R.route or {}
  if #route > 1 then
    local dist, prev = R.flood(dk, around(dock.at[1], dock.at[2], dock.at[3], 16), reserved)
    local iE, best
    for i, k in ipairs(route) do
      if dist[k] and (not best or dist[k] < best) then iE, best = i, dist[k] end
    end
    if iE then
      local near = {}
      for i, k in ipairs(route) do
        local x, y, z = XYZ(k)
        near[#near + 1] = { i = i, d = cheb(x, y, z, mx, my, mz) }
      end
      table.sort(near, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.i < b.i end)
      local tried = {}
      for _, n in ipairs(near) do
        if #entries >= 7 then break end
        local k = route[n.i]
        if not tried[k] and not reserved[k] then
          tried[k] = true
          local walk = pathTo(prev, dk, route[iE])
          local s = R.slice(route, iE, n.i)
          local clear = true
          for j = 2, #s do
            walk[#walk + 1] = s[j]
            if reserved[s[j]] then clear = false end          -- (past another turtle's dock: not that way)
          end
          if clear then entries[#entries + 1] = { from = k, walk = walk } end
        end
      end
    end
  end
  local best
  for _, e in ipairs(entries) do
    local x, y, z = XYZ(e.from)
    local close = e.walk or cheb(x, y, z, mx, my, mz) <= 24
    if close then
      local t = R.tour(e.from, targets, region(e.from), reserved, avoid.noDwell)
      if #t.placed > 0 and (not best or #t.placed > #best.tour.placed) then best = { entry = e, tour = t } end
      if best and #best.tour.placed == #targets then break end
    end
  end
  if not best then return nil, "no way to the damage (the scout's route never passes near it?)" end
  local steps = {}
  if best.entry.walk and #best.entry.walk > 0 then steps[1] = { "go", cells = best.entry.walk } end
  for _, st in ipairs(best.tour.steps) do
    local last = steps[#steps]
    if st[1] == "go" and last and last[1] == "go" then
      for _, c in ipairs(st.cells) do last.cells[#last.cells + 1] = c end
    else
      steps[#steps + 1] = st
    end
  end
  local cells = { dk }                                      -- (every cell it passes: other drones never stop there)
  for _, st in ipairs(steps) do
    if st[1] == "go" then
      for i, k in ipairs(st.cells) do
        cells[#cells + 1] = k
        local x, y, z = XYZ(k)
        st.cells[i] = { x, y, z }
      end
    end
  end
  return { steps = steps, placed = best.tour.placed, left = best.tour.left, cells = cells, dwell = best.tour.dwell }
end

---------------------------------------------------------------- jobs

-- What a trip can take: targets whose part is in the depot, at most jobMax
-- blocks and 15 stacks. -> targets, need = { [item] = n }
function R.pickTargets(keys, stock)
  local targets, need, used = {}, {}, {}
  local function stacks()
    local n = 0
    for _, c in pairs(used) do n = n + math.ceil(c / 64) end
    return n
  end
  for _, k in ipairs(keys) do
    local p = R.copy[k] and R.pal[R.copy[k]]
    if p then
      local item = p.item
      local n = p.props.type == "double" and 2 or 1
      if not item then
        need["(no item for " .. p.name .. ")"] = (need["(no item for " .. p.name .. ")"] or 0) + 1
      elseif ((stock[item] and stock[item].total) or 0) - (used[item] or 0) >= n then
        used[item] = (used[item] or 0) + n
        if #targets >= (tonumber(R.cfg.jobMax) or 48) or stacks() > 15 then
          used[item] = used[item] - n
          break
        end
        targets[#targets + 1] = k
      else
        need[item] = (need[item] or 0) + n
      end
    end
  end
  return targets, need
end

local function needText(need)
  local t = {}
  for item, n in pairs(need) do t[#t + 1] = n .. " " .. item:gsub("^minecraft:", "") end
  table.sort(t)
  return table.concat(t, ", ")
end

-- A drone's report: placed blocks are mended; failures counted (twice = given up)
function R.takeReport(rep)
  local done, failed = 0, 0
  for _, k in ipairs(type(rep.done) == "table" and rep.done or {}) do
    R.damage[k], R.ordered[k], R.fixing[k], R.tries[k] = nil, nil, nil, nil
    done = done + 1
  end
  for _, f in ipairs(type(rep.failed) == "table" and rep.failed or {}) do
    local k = type(f) == "table" and f[1] or f
    if R.fixing[k] ~= nil or R.ordered[k] then
      R.fixing[k] = nil
      R.tries[k] = (R.tries[k] or 0) + 1
      if R.tries[k] >= 2 then R.ordered[k] = nil end
      failed = failed + 1
    end
  end
  return done, failed
end

-- A drone back at its dock: its report (nil: lost - it said hello instead)
-- taken, its blocks no longer being fixed, its permit back (netLoop: no waiting)
function R.finishJob(id, rep)
  local o = R.outs[id]
  if not o or o.kind ~= "job" then return false end
  if rep and o.job and rep.id ~= o.job.id then return false end          -- (an old report)
  local done, failed = 0, 0
  if rep then done, failed = R.takeReport(rep) end
  for _, k in ipairs(o.job and o.job.keys or {}) do
    if R.fixing[k] == (o.job and o.job.id) then R.fixing[k] = nil end
  end
  R.clearOut(id)
  R.waitPlan = nil                                  -- (its area is free: others may go there now)
  local d = R.drones[id]
  if d then
    d.fuel = rep and tonumber(rep.fuel) or d.fuel
    d.seen = now()
  end
  R.regroup()
  R.saveDamage()
  R.broadcastGroups()
  if rep then
    R.say(("Drone %d back: %d block%s put back%s"):format(id, done, done == 1 and "" or "s",
      failed > 0 and (", " .. failed .. " failed" .. (rep.why and (" (" .. tostring(rep.why) .. ")") or "")) or ""), true)
  else
    R.say(("Drone %d is home (its report never came: the next sweep checks its work)"):format(id))
  end
  return true
end

---------------------------------------------------------------- talking

R.inbox = {}
R.drones = {}         -- id -> { seen, fuel, pickup, version }

-- A message from the network (netLoop - it never waits on anything)
function R.onMessage(from, msg)
  if type(msg) ~= "table" then return end
  local op = msg.op
  local o = R.outs[from]
  if op == "hello" and o and not o.loading and not (o.kind ~= "job" and R.task) then
    -- (a hello comes only from the dock: it is home)
    if o.kind == "job" and o.job then
      R.finishJob(from, nil)
    else
      R.say(("%s %d is home - its permit is free"):format(msg.role == "scout" and "The scout" or "Drone", from))
      R.clearOut(from)
    end
  end
  if op == "hello" and msg.role == "scout" then
    if not R.scout or R.scout.id ~= from then
      R.log(("scout %d said hello (route %d moves, facing %s)"):format(from, #tostring(msg.route or ""), tostring(msg.facing)))
    end
    R.scout = { id = from, seen = now(), fuel = tonumber(msg.fuel), limit = tonumber(msg.limit), facing = msg.facing,
      route = msg.route, version = msg.version, fuelSide = msg.fuelSide }
    local cells = R.routeCells(msg.route, msg.facing)
    if #cells > 1 then R.route = cells end
    pcall(rednet.send, from, { op = "welcome" }, R.PROTO)
  elseif op == "move?" then
    -- (the scout asks to be driven by hand: the permit, if nobody is out)
    if R.anyOut() or R.task then
      pcall(rednet.send, from, { op = "wait", why = R.anyOut() and (R.outText() .. " out") or ("busy: " .. R.task) }, R.PROTO)
    else
      R.setOut(from, tostring(msg.why or "by hand"))
      pcall(rednet.send, from, { op = "go" }, R.PROTO)
    end
  elseif op == "hello" and msg.role == "drone" then
    local d = R.drones[from] or {}
    R.drones[from] = d
    d.seen, d.fuel, d.version = now(), tonumber(msg.fuel), msg.version
    d.pickup = (type(msg.pickup) == "string" and msg.pickup ~= "" and msg.pickup) or R.cfg.pickups[from] or nil
    pcall(rednet.send, from, { op = "welcome", dock = R.cfg.docks[from] }, R.PROTO)
  elseif op == "fix" and type(msg.groups) == "table" then
    local n, g = 0, 0
    for _, id in ipairs(msg.groups) do
      local m = R.order(tonumber(id))
      if m > 0 then n, g = n + m, g + 1 end
    end
    if n > 0 then
      R.saveDamage()
      R.say(("Repair ordered: %d block%s in %d group%s"):format(n, n == 1 and "" or "s", g, g == 1 and "" or "s"), true)
    end
  elseif op == "report" then
    R.finishJob(from, msg)
  elseif op == "scan" or op == "done" or op == "trouble" or op == "turned" or op == "going" or op == "ack" or op == "peeked"
    or op == "alive" then
    if #R.inbox >= 64 then table.remove(R.inbox, 1) end
    R.inbox[#R.inbox + 1] = { from = from, msg = msg }
    os.queueEvent("repair_inbox")
  end
end

-- (inside a task) the next message that matches, or nil after timeout s
function R.await(match, timeout)
  local deadline = now() + (timeout or 10)
  while true do
    for i, m in ipairs(R.inbox) do
      if match(m.from, m.msg) then
        table.remove(R.inbox, i)
        return m.from, m.msg
      end
    end
    if now() >= deadline or R.stopRequested then return nil end
    local t = os.startTimer(math.min(1, math.max(0.05, deadline - now())))
    while true do
      local e, id = os.pullEvent()
      if e == "repair_inbox" or (e == "timer" and id == t) then break end
    end
  end
end

local runs = 0
function R.newRun()
  runs = runs + 1
  return os.getComputerID() * 100000 + runs
end

---------------------------------------------------------------- tasks

-- Every scout and drone listening at its dock: say hello (after this
-- computer restarts it knows none of them until they do)
function R.askHello()
  pcall(rednet.broadcast, { op = "hello?" }, R.PROTO)
end

-- A scout run: survey or sweep. -> stops scanned, or nil + why
function R.scoutRun(mode)
  if not R.haveWireless then return nil, "this computer has no ender (wireless) modem - the scout cannot reach it" end
  if not R.scout then
    R.askHello()
    for _ = 1, 20 do                                -- (its hello comes in through netLoop)
      if R.scout then break end
      sleep(0.25)
    end
  end
  if not R.scout then
    return nil, "the scout has not said hello - look at its screen: is it waiting for you to drive its route (press Enter when done)? "
      .. "Is scout.lua running, with an ender modem?"
  end
  local explore = (R.scout.route or "") == ""
  if explore and mode ~= "survey" then return nil, "the scout has no route yet - type survey: it explores the ship and makes one" end
  if R.anyOut() then return nil, R.outText() .. " out" end
  local run = R.newRun()
  local id = R.scout.id
  pcall(R.fuelScout)
  R.setOut(id, mode)
  if explore then R.say("The scout has no route: it explores the ship to make one (this takes a while)") end
  pcall(rednet.send, id, { op = explore and "explore" or mode, run = run }, R.PROTO)
  local stops, found = 0, 0
  while true do
    local _, msg = R.await(function(f, m) return f == id and m.run == run end, 120)
    if R.stopRequested then
      pcall(rednet.send, id, { op = "stop", run = run }, R.PROTO)
      return nil, "stopped (the permit is free when the scout says hello from its dock)"
    end
    if not msg then return nil, "no word from the scout for 2 minutes (it keeps the permit until it says hello from its dock)" end
    if msg.op == "scan" then
      local _, f = R.takeScan(msg, mode)
      stops, found = stops + 1, found + f
      pcall(rednet.send, id, { op = "ack", run = run, n = msg.n }, R.PROTO)
      if stops == 1 or stops % 10 == 0 then
        local at = type(msg.at) == "table" and msg.at or {}
        R.log(("%s: scan %d, from %s,%s,%s"):format(explore and "explore" or mode, stops, tostring(at[1]), tostring(at[2]), tostring(at[3])))
      end
    elseif msg.op == "done" then
      R.clearOut(id)                                -- (back at its dock)
      if type(msg.route) == "string" and msg.route ~= "" then
        R.scout.route = msg.route                   -- (the route it explored)
        local cells = R.routeCells(msg.route, R.scout.facing)
        if #cells > 1 then R.route = cells end
      end
      if msg.why then R.say("The scout: " .. tostring(msg.why)) end
      return stops, found
    elseif msg.op == "trouble" then
      R.clearOut(id)                                -- (it says trouble from its dock, after going home)
      return nil, "the scout: " .. tostring(msg.text)
    end
  end
end

function R.surveyTask()
  R.say("Survey: the copy starts afresh")
  local oldCopy, oldPal, oldPalOf, oldCenters, oldGrid = R.copy, R.pal, R.palOf, R.centers, R.centerGrid
  R.resetCopy()
  local stops, why = R.scoutRun("survey")
  if stops and R.copySize() == 0 then stops, why = nil, "its scans saw no blocks - see scout.log on the scout" end
  if not stops then
    R.copy, R.pal, R.palOf, R.centers, R.centerGrid = oldCopy, oldPal, oldPalOf, oldCenters, oldGrid
    R.copySize()
    return R.say("Survey stopped (" .. tostring(why) .. ") - the old copy is kept", true)
  end
  R.saveCopy()
  if R.route then pcall(writeTable, R.FILES.route, "-- repair.route - the scout's route cells", R.route) end
  R.saveWhitelist()
  local nav, n = R.findNav()
  if nav then R.cfg.navAt = nav
  else R.say(("The nav table: %s in the copy - set navAt in repair.cfg by hand"):format(n == 0 and "not seen" or (n .. " of them"))) end
  R.saveConfig()
  R.damage, R.ordered, R.tries, R.fixing = {}, {}, {}, {}
  R.regroup()
  R.saveDamage()
  local kinds, yes = 0, 0
  for _, v in pairs(R.white) do
    kinds = kinds + 1
    if v then yes = yes + 1 end
  end
  R.say(("Survey done: %d stops, %d blocks in the copy, %d kinds (%d may be put back - edit repair.whitelist)")
    :format(stops, R.copySize(), kinds, yes), true)
  R.registerTask()
end

function R.sweepTask()
  if R.copySize() == 0 then return R.say("No copy yet - type survey first") end
  local stops, found = R.scoutRun("sweep")
  R.lastSweep = now()
  R.regroup()
  R.saveDamage()
  if not stops then return R.say("Sweep stopped: " .. tostring(found)) end
  local n = 0
  for _ in pairs(R.damage) do n = n + 1 end
  R.say(("Sweep done: %d stops, %d block%s missing in %d group%s%s"):format(stops, n, n == 1 and "" or "s", #R.groupList,
    #R.groupList == 1 and "" or "s", found > 0 and (" (" .. found .. " new)") or ""), found > 0)
end

-- A look from the scout's dock -> the turtles round it { [key] = facing }
function R.look()
  local run = R.newRun()
  pcall(rednet.send, R.scout.id, { op = "look", run = run }, R.PROTO)
  local _, msg = R.await(function(f, m) return f == R.scout.id and m.run == run and m.op == "scan" end, 20)
  return msg and R.turtlesIn(msg) or nil
end

-- Which turtle near the scout's dock is which drone: each turns right while
-- the scout looks, the one whose facing turned is it
function R.registerTask(only)
  if not R.scout then return R.say("Register: no scout (it does the looking)") end
  if not only and not R.cfg.scoutFuel and R.scout.fuelSide then R.findScoutFuel() end
  local list = {}
  for id, d in pairs(R.drones) do
    if now() - d.seen < 30 and (not only or id == only) then list[#list + 1] = id end
  end
  table.sort(list)
  if #list == 0 then return R.say("Register: no drone has said hello from its dock") end
  for _, id in ipairs(list) do
    local before = R.look()
    if not before then return R.say("Register: the scout did not look") end
    pcall(rednet.send, id, { op = "turn", way = "right" }, R.PROTO)
    local turned = R.await(function(f, m) return f == id and m.op == "turned" end, 10)
    local after = turned and R.look()
    pcall(rednet.send, id, { op = "turn", way = "left" }, R.PROTO)
    R.await(function(f, m) return f == id and m.op == "turned" end, 10)
    local at, facing = nil, nil
    if after then at, facing = R.findTurned(before, after) end
    if at then
      R.cfg.docks[id] = { at = at, facing = facing }
      R.say(("Drone %d: dock at %d %d %d, facing %s"):format(id, at[1], at[2], at[3], facing))
    else
      R.say(("Drone %d: not found - it must be within 8 blocks of the scout's dock, the scout at home"):format(id))
    end
    if not R.drones[id].pickup then
      -- (any chest may be a drone's, two drones may share one - but never the
      -- scout's fuel inventory: parts put there would spoil its fuel)
      local taken = {}
      if R.cfg.scoutFuel then taken[R.cfg.scoutFuel] = true end
      local name, why = R.findChest(id, taken)
      if name then
        R.cfg.pickups[id], R.drones[id].pickup = name, name
        R.say(("Drone %d: its pickup chest is %s"):format(id, name))
      else
        R.say(("Drone %d: pickup chest not found - %s"):format(id, why))
      end
    end
  end
  -- (the scout's route must never pass a drone's dock: it would meet that drone every run)
  local onRoute = {}
  for _, k in ipairs(R.route or {}) do onRoute[k] = true end
  for id, d in pairs(R.cfg.docks) do
    if type(d) == "table" and onRoute[K(d.at[1], d.at[2], d.at[3])] then
      R.say(("Drone %d's dock is on the scout's route - record the route round it (scout record)"):format(id), true)
    end
  end
  R.saveConfig()
end

-- The scout's fuel inventory (touching its dock, on the wired network) -
-- found as the pickup chests are; it may be the depot's vault itself
function R.findScoutFuel()
  if not R.scout or not R.scout.fuelSide then return nil, "no inventory touches the scout" end
  local taken = {}
  for _, n in pairs(R.cfg.pickups) do taken[n] = true end
  local name, why = R.findChest(R.scout.id, taken)
  if name then
    R.cfg.scoutFuel = name
    R.saveConfig()
    R.say("The scout's fuel comes from " .. name)
  else
    R.say("The scout's fuel inventory is not on the wired network (" .. tostring(why) .. ") - keep it stocked by hand")
  end
  return name
end

-- Which inventory on the wired network is the one touching a turtle (a
-- drone's pickup chest, the scout's fuel): one item at a time is put in each
-- (and taken back) until the turtle sees it. -> its name, or nil + why
function R.findChest(id, taken)
  taken = taken or {}
  local invs = {}
  for _, n in ipairs(R.inventories()) do if not taken[n] then invs[#invs + 1] = n end end
  local function list(inv)
    local ok, l = pcall(peripheral.call, inv, "list")
    return ok and type(l) == "table" and l or {}
  end
  local src, item
  for _, inv in ipairs(invs) do
    for _, it in pairs(list(inv)) do
      src, item = inv, it.name
      break
    end
    if src then break end
  end
  if not src then return nil, "nothing on the network to test with (put something in the depot)" end
  local function peek()
    pcall(rednet.send, id, { op = "peek" }, R.PROTO)
    local _, m = R.await(function(f, mm) return f == id and mm.op == "peeked" end, 10)
    if not m then return nil end
    return type(m.items) == "table" and (tonumber(m.items[item]) or 0) or false
  end
  -- (move one of item from a to b -> moved)
  local function move(a, b)
    for slot, it in pairs(list(a)) do
      if it.name == item then
        local ok, n = pcall(peripheral.call, a, "pushItems", b, slot, 1)
        return ok and tonumber(n) or 0
      end
    end
    return 0
  end
  local base = peek()
  if base == nil then return nil, "the turtle did not answer" end
  if base == false then return nil, "the turtle has no chest by it" end
  for _, c in ipairs(invs) do
    if c ~= src and move(src, c) > 0 then
      local seen = peek()
      move(c, src)
      if seen and seen > base then return c end
    end
  end
  -- (the test item's own chest: one taken out of it)
  for _, c in ipairs(invs) do
    if c ~= src and move(src, c) > 0 then
      local seen = peek()
      move(c, src)
      if seen and seen < base then return src end
      break
    end
  end
  return nil, "none of the chests on the wired network is the one in front of it (is its modem switched on?)"
end

-- One drone sent out: the first of the candidate groups (each a list of
-- ordered keys - or one list) it can reach without getting in the way of the
-- drones already out. Its parts (and fuel when it is low) go into the first
-- slots of its chest; it takes them, says "going" and leaves - the next drone
-- can be sent while it works. Its report comes to R.finishJob.
function R.jobTask(droneId, candidates)
  local d, dock = R.drones[droneId], R.cfg.docks[droneId]
  if type(candidates[1]) ~= "table" then candidates = { candidates } end
  local stock = R.stock()
  local plan, targets, why, shortOf
  local avoid = R.avoidFor(droneId)
  for _, keys in ipairs(candidates) do
    local t, need = R.pickTargets(keys, stock)
    if next(need) then shortOf = need end
    if #t > 0 then
      local p, w = R.plan(dock, t, droneId, avoid)
      if p and #p.placed > 0 then
        plan, targets = p, t
        break
      end
      why = why or w
      if not R.anyOut() then                        -- (alone and still nowhere to stand: it cannot be reached at all)
        for _, k in ipairs(t) do
          R.tries[k] = (R.tries[k] or 0) + 1
          if R.tries[k] >= 2 then R.ordered[k] = nil end
        end
      end
    end
  end
  if shortOf then R.say("Short of parts: " .. needText(shortOf), true) end
  if not plan then
    if shortOf and not why then R.waitParts = now() else R.waitPlan = now() end
    R.saveDamage()
    if why and not R.anyOut() then R.say("Cannot reach the damage: " .. tostring(why), true) end
    return
  end
  -- (the parts by item, fuel when low)
  local want, wantAt = {}, {}
  local function add(item, n)
    if not wantAt[item] then
      want[#want + 1] = { item, 0 }
      wantAt[item] = #want
    end
    want[wantAt[item]][2] = want[wantAt[item]][2] + n
  end
  for _, st in ipairs(plan.steps) do
    if st[1] == "place" then add(st.item, st.double and 2 or 1) end
  end
  if d.fuel and d.fuel < (tonumber(R.cfg.fuelLow) or 1000) then
    local units = tonumber(R.cfg.fuelGive) or 4000
    for _, f in ipairs(R.fuelItems()) do
      local have = stock[f] and stock[f].total or 0
      if units > 0 and have > 0 then
        local n = math.min(have, math.ceil(units / (R.FUEL[f] or 80)))
        add(f, n)
        units = units - n * (R.FUEL[f] or 80)
      end
    end
  end
  local stacks, swhy = R.stage(d.pickup, want)
  if not stacks then
    R.waitPlan = now()
    return R.say(("Cannot load drone %d: %s"):format(droneId, tostring(swhy)))
  end
  local job = { op = "job", id = R.newRun(), at = dock.at, facing = dock.facing, steps = plan.steps, fuels = R.fuelItems(),
    load = stacks }
  R.setOut(droneId, "job", { id = job.id, keys = plan.placed, cells = plan.cells, dwell = plan.dwell })
  R.outs[droneId].loading = true
  for _, k in ipairs(plan.placed) do R.fixing[k] = job.id end
  R.broadcastGroups()
  R.lastDispatch = now()
  pcall(rednet.send, droneId, job, R.PROTO)
  local _, go = R.await(function(f, m) return f == droneId and m.op == "going" and m.id == job.id end, 15)
  local o = R.outs[droneId]
  local mine = o and o.job and o.job.id == job.id
  if not go then
    if mine then                                    -- (it never left its dock)
      for _, k in ipairs(plan.placed) do if R.fixing[k] == job.id then R.fixing[k] = nil end end
      R.clearOut(droneId)
      R.broadcastGroups()
    end
    return R.say(("Drone %d did not take the job"):format(droneId))
  end
  if mine then
    o.loading = nil
    R.say(("Drone %d out: %d block%s"):format(droneId, #plan.placed, #plan.placed == 1 and "" or "s"))
  end
end

-- The next drone to send, if any: no scout out, no turtle lost since a
-- reboot, fewer than maxOut drones out, the last one gone stagger s ago; the
-- groups with ordered blocks nobody is fixing yet. -> a free drone, the
-- candidate groups (or nil, why)
function R.nextJob()
  for _, o in pairs(R.outs) do
    if o.kind ~= "job" or o.lost or o.loading then return nil end
  end
  if R.dronesOut() >= (tonumber(R.cfg.maxOut) or 3) then return nil end
  if R.lastDispatch and now() - R.lastDispatch < (tonumber(R.cfg.stagger) or 8) then return nil end
  if R.waitParts and now() - R.waitParts < 60 then return nil end    -- (short of parts: look again in a minute)
  if R.waitPlan and now() - R.waitPlan < 20 then return nil end      -- (nothing reachable just now: in a while)
  local cands = {}
  for _, g in ipairs(R.groupList or {}) do
    local mine = {}
    for _, k in ipairs(g.keys) do if R.ordered[k] and not R.fixing[k] then mine[#mine + 1] = k end end
    if #mine > 0 then cands[#cands + 1] = mine end
  end
  if #cands == 0 then return nil end
  local ids = {}
  for id, d in pairs(R.drones) do
    if now() - d.seen < 30 and not R.outs[id] and R.cfg.docks[id] and d.pickup then ids[#ids + 1] = id end
  end
  table.sort(ids)
  if #ids == 0 then return nil, "no drone free (docked, registered, with a chest)" end
  return ids[1], cands
end

function R.startTask(name, fn, ...)
  if R.task then return false, "busy: " .. R.task end
  if R.anyOut() and name ~= "job" then return false, R.outText() .. " out - the scout waits until every turtle is home" end
  local args = table.pack(...)
  R.task, R.taskFn, R.stopRequested = name, function() return fn(table.unpack(args, 1, args.n)) end, false
  os.queueEvent("repair_task")
  return true
end

function R.taskLoop()
  while true do
    os.pullEvent("repair_task")
    if R.taskFn then
      local fn = R.taskFn
      R.taskFn = nil
      local ok, err = pcall(fn)
      if not ok then R.say("Task " .. tostring(R.task) .. " failed: " .. tostring(err)) end
      R.task = nil
    end
  end
end

---------------------------------------------------------------- the materials monitor

R.MODES = { { id = "whole", label = "WHOLE SHIP", short = "WHOLE" }, { id = "repairable", label = "REPAIRABLE", short = "REPAIR" },
  { id = "damage", label = "DAMAGE NOW", short = "DAMAGE" } }
R.mon = { mode = 1, page = 1 }

-- What a mode's blocks take: { [item] = n }, blocks with no item. A double
-- slab is two slabs; doors, tall plants and beds are one item for two blocks
function R.materials(mode)
  local stamp = mode .. ":" .. tostring(R.copyCount) .. ":" .. tostring(R.whiteStamp) .. ":" .. tostring(R.damageStamp)
    .. ":" .. tostring(R.glueAt) .. #(R.glueBoxes or {}) .. tostring(R.cfg.glue)
  if R.matCache and R.matCache.stamp == stamp then return R.matCache.need, R.matCache.noItem end
  local perPal = {}
  if mode == "damage" then
    for k in pairs(R.damage) do
      local i = R.copy[k]
      if i then perPal[i] = (perPal[i] or 0) + 1 end
    end
  else
    for _, i in pairs(R.copy) do
      perPal[i] = (perPal[i] or 0) + 1
      R.breathe()
    end
  end
  if mode == "repairable" then
    R.glued(K(0, 0, 0))                             -- (glued blocks are moving parts: never put back)
    for k in pairs(R.glueSet or {}) do
      local i = R.copy[k]
      if i and perPal[i] then perPal[i] = perPal[i] - 1 end
    end
  end
  local need, noItem = {}, 0
  for i, n in pairs(perPal) do
    local p = R.pal[i]
    local s = p.props or {}
    if mode ~= "repairable" or R.allowed(i) then
      if not p.item then
        noItem = noItem + n
      elseif s.half ~= "upper" and s.part ~= "head" then
        need[p.item] = (need[p.item] or 0) + n * (s.type == "double" and 2 or 1)
      end
    end
  end
  R.matCache = { stamp = stamp, need = need, noItem = noItem }
  return need, noItem
end

-- "minecraft:cyan_terracotta" -> "cyan terracotta"; another mod's: "thing (mod)"
local function itemName(item)
  local mod, name = tostring(item):match("^([^:]+):(.+)$")
  if not mod then return tostring(item) end
  name = name:gsub("_", " ")
  return mod == "minecraft" and name or (name .. " (" .. mod .. ")")
end

-- The rows for a mode: { { item, need, have, short }, ... } (short first), totals
function R.materialRows(mode, totals)
  local need, noItem = R.materials(mode)
  local rows, sum = {}, { need = 0, have = 0, short = 0, done = 0, noItem = noItem }
  for item, n in pairs(need) do
    local have = math.min(n, totals[item] or 0)
    local short = n - have
    sum.need, sum.have, sum.short = sum.need + n, sum.have + have, sum.short + short
    if short > 0 then rows[#rows + 1] = { item, n, totals[item] or 0, short } else sum.done = sum.done + 1 end
  end
  table.sort(rows, function(a, b)
    if a[4] ~= b[4] then return a[4] > b[4] end
    return a[1] < b[1]
  end)
  return rows, sum
end

function R.findMonitor()
  local best
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType(n, "monitor") then
      local m = peripheral.wrap(n)
      if m and (not best or (m.isColour and m.isColour())) then best = m end
    end
  end
  return best
end

-- Draw it; fresh = read the depot again (else the last reading)
function R.drawMonitor(fresh)
  local mon = R.findMonitor()
  if not mon then return false end
  if fresh or not R.monTotals then
    local totals = {}
    for item, e in pairs(R.stock()) do totals[item] = e.total end
    R.monTotals, R.monAt = totals, os.time and os.time() or 0
  end
  local mode = R.MODES[R.mon.mode] or R.MODES[1]
  local rows, sum = R.materialRows(mode.id, R.monTotals)
  pcall(mon.setTextScale, 0.5)
  local w, h = mon.getSize()
  local colour = mon.isColour and mon.isColour()
  local function col(fg, bg)
    if not colour then return end
    if fg then mon.setTextColour(fg) end
    if bg then mon.setBackgroundColour(bg) end
  end
  local function put(y, text, fg, bg)
    col(fg, bg)
    mon.setCursorPos(1, y)
    mon.write((tostring(text) .. string.rep(" ", w)):sub(1, w))
  end
  local function num(n, width) return (string.rep(" ", width) .. tostring(n)):sub(-width) end
  col(colours.white, colours.black)
  mon.clear()
  local small = w < 30
  local tab = "[" .. (small and mode.short or mode.label) .. "]"
  put(1, ((small and " PARTS" or " SHIP MATERIALS") .. string.rep(" ", w)):sub(1, math.max(1, w - #tab - 1)) .. tab, colours.white, colours.blue)
  if (R.copyCount or 0) == 0 then
    put(3, small and " No copy yet" or " No copy yet - type survey at the computer.", colours.lightGrey, colours.black)
    return true
  end
  -- (as many number columns as fit: need, have, short - short always)
  local nw = w >= 40 and 7 or 6
  local cols = w >= 40 and 3 or w >= 26 and 2 or 1
  local namew = math.max(4, w - cols * nw)
  put(2, small and (" short %d/%d"):format(sum.short, sum.need) or (" need %d, have %d, short %d%s"):format(sum.need, sum.have, sum.short,
    sum.noItem > 0 and (" (+%d with no item)"):format(sum.noItem) or ""), sum.short > 0 and colours.orange or colours.lime, colours.black)
  local heads = { "NEED", "HAVE", "SHORT" }
  local head = (" ITEM" .. string.rep(" ", namew)):sub(1, namew)
  for c = 4 - cols, 3 do head = head .. num(heads[c], nw) end
  put(3, head, colours.lightGrey, colours.black)
  local per = math.max(1, h - 4)
  local pages = math.max(1, math.ceil(#rows / per))
  if R.mon.page > pages then R.mon.page = 1 end
  local first = (R.mon.page - 1) * per
  for i = 1, per do
    local r = rows[first + i]
    if not r then break end
    col(colours.white, colours.black)
    mon.setCursorPos(1, 3 + i)
    local line = (" " .. itemName(r[1]) .. string.rep(" ", namew)):sub(1, namew)
    if cols >= 3 then line = line .. num(r[2], nw) end
    if cols >= 2 then line = line .. num(r[3], nw) end
    mon.write(line)
    col(colours.red)
    mon.write(num(r[4], nw))
  end
  if #rows == 0 then put(4, small and " All in stock" or " Nothing short - the depot has it all.", colours.lime, colours.black) end
  put(h, small and (" %d/%d tap" ):format(R.mon.page, pages)
    or (" page %d/%d - tap for more   %d kind%s complete"):format(R.mon.page, pages, sum.done, sum.done == 1 and "" or "s"),
    colours.lightGrey, colours.grey)
  return true
end

-- A tap: the top line changes the view, anywhere else turns the page
function R.monitorTouch(x, y)
  if y <= 1 then
    R.mon.mode, R.mon.page = R.mon.mode % #R.MODES + 1, 1
  else
    R.mon.page = R.mon.page + 1
  end
  return R.drawMonitor(false)
end

function R.monitorLoop()
  local t = os.startTimer(2)
  local stamp
  while true do
    local e, a, b, c = os.pullEvent()
    if e == "timer" and a == t then
      t = os.startTimer(5)
      -- (the depot read again every 30 s; drawn again when the copy, whitelist or damage changed)
      local s = tostring(R.copyCount) .. ":" .. tostring(R.whiteStamp) .. ":" .. tostring(R.damageStamp)
      if not R.monRead or now() - R.monRead >= 30 then
        R.monRead, stamp = now(), s
        pcall(R.drawMonitor, true)
      elseif s ~= stamp then
        stamp = s
        pcall(R.drawMonitor, false)
      end
    elseif e == "monitor_touch" then
      pcall(R.monitorTouch, b, c)
    elseif e == "monitor_resize" or e == "peripheral" then
      pcall(R.drawMonitor, false)
    end
  end
end

---------------------------------------------------------------- commands

function R.status()
  local dmg, ord = 0, 0
  for k in pairs(R.damage) do
    dmg = dmg + 1
    if R.ordered[k] then ord = ord + 1 end
  end
  local yes, kinds = 0, 0
  for _, v in pairs(R.white) do
    kinds = kinds + 1
    if v then yes = yes + 1 end
  end
  local out = {
    ("REPAIR %s  computer %d  %s"):format(R.VERSION, os.getComputerID(), R.task and ("busy: " .. R.task) or "idle"),
    ("out: %s"):format(R.outText() or "nobody - every turtle at home"),
    ("copy: %d blocks, %d kinds (%d may be put back); nav table %s"):format(R.copySize(), kinds, yes,
      type(R.cfg.navAt) == "table" and table.concat(R.cfg.navAt, " ") or "UNKNOWN"),
    ("damage: %d blocks in %d groups, %d ordered"):format(dmg, #(R.groupList or {}), ord),
    ("glued (never damage): %s"):format(#(R.glueBoxes or {}) == 0 and "no repair.glue" or R.cfg.glue == false and "OFF (repair.cfg glue)"
      or ("%d blocks of the copy in %d boxes"):format(R.gluedCount(), #R.glueBoxes)),
    ("scout: %s"):format(R.scout and ("%d (route %d cells, fuel %s, fuel from %s)"):format(R.scout.id, #(R.route or {}),
      tostring(R.scout.fuel), tostring(R.cfg.scoutFuel or (R.scout.fuelSide and ("its " .. R.scout.fuelSide)) or "NOTHING")) or "not heard"),
  }
  local ids = {}
  for id in pairs(R.drones) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local d, dock = R.drones[id], R.cfg.docks[id]
    out[#out + 1] = ("drone %d: %s, %s, fuel %s, chest %s"):format(id, R.outs[id] and "OUT" or now() - d.seen < 30 and "docked" or "silent",
      dock and ("dock " .. table.concat(dock.at, " ")) or "NOT REGISTERED", tostring(d.fuel), tostring(d.pickup or "NOT SET"))
  end
  return table.concat(out, "\n")
end

R.HELP = "survey, sweep, register, stop, status, groups, need, fix <id>|all, unfix, ignore <id>, whitelist, allow <name>, deny <name>, "
  .. "pickup <drone> <chest>|find"

function R.command(line)
  local w = {}
  for s in tostring(line):gmatch("%S+") do w[#w + 1] = s end
  local verb = (w[1] or ""):lower()
  if verb == "" then return nil end
  if verb == "help" or verb == "?" then return R.HELP end
  if verb == "status" then return R.status() end
  if verb == "survey" or verb == "sweep" or verb == "register" then
    local fn = verb == "survey" and R.surveyTask or verb == "sweep" and R.sweepTask or R.registerTask
    local ok, why = R.startTask(verb, fn)
    return ok and (verb .. ": started") or why
  end
  if verb == "stop" then
    if not R.task then return "nothing running" end
    R.stopRequested = true
    os.queueEvent("repair_inbox")
    return "stopping " .. R.task .. "..."
  end
  if verb == "groups" then
    if #(R.groupList or {}) == 0 then return "no damage" end
    local t = {}
    for i, g in ipairs(R.groupList) do
      if i > 12 then
        t[#t + 1] = ("... and %d more"):format(#R.groupList - 12)
        break
      end
      local c = g.c
      t[#t + 1] = ("%d: %d block%s at %d %d %d, %s"):format(g.id, #g.keys, #g.keys == 1 and "" or "s", math.floor(c[1] + 0.5),
        math.floor(c[2] + 0.5), math.floor(c[3] + 0.5), R.groupState(g))
    end
    return table.concat(t, "\n")
  end
  if verb == "fix" then
    local n = 0
    for _, g in ipairs(R.groupList or {}) do
      if w[2] == "all" or tonumber(w[2]) == g.id then n = n + R.order(g.id) end
    end
    R.saveDamage()
    return n > 0 and ("ordered " .. n .. " block" .. (n == 1 and "" or "s")) or "fix <group id> | fix all (groups lists them)"
  end
  if verb == "unfix" then
    R.ordered = {}
    R.groupsDirty = true
    R.saveDamage()
    return "all repair orders called off"
  end
  if verb == "ignore" then
    local g = R.findGroup(tonumber(w[2]))
    if not g then return "ignore <group id> (groups lists them)" end
    local b = g.box
    R.cfg.ignore[#R.cfg.ignore + 1] = { b[1] - 1, b[2] - 1, b[3] - 1, b[4] + 1, b[5] + 1, b[6] + 1 }
    for _, k in ipairs(g.keys) do R.damage[k], R.ordered[k] = nil, nil end
    R.saveConfig()
    R.regroup()
    R.saveDamage()
    return ("group %d's area is ignored from now on (repair.cfg ignore)"):format(g.id)
  end
  if verb == "clear" then
    if not R.anyOut() then return "nobody is out" end
    local id = tonumber(w[2])
    if w[2] and not (id and R.outs[id]) then return "clear [turtle id] - out now: " .. R.outText() end
    local was = id and ("turtle " .. id) or R.outText()
    if id and R.outs[id] and R.outs[id].kind == "job" then R.finishJob(id, nil) else R.clearOut(id) end
    return ("permit taken back from %s - make sure it really is at its dock"):format(was)
  end
  if verb == "pickup" then
    local id = tonumber(w[2])
    if not id or not w[3] then return "pickup <drone id> <chest's peripheral name> | pickup <drone id> find" end
    if w[3] == "find" then
      R.cfg.pickups[id] = nil
      if R.drones[id] then R.drones[id].pickup = nil end
      local ok, why = R.startTask("register", R.registerTask, id)
      return ok and "finding it (register)..." or why
    end
    R.cfg.pickups[id] = w[3]
    if R.drones[id] then R.drones[id].pickup = w[3] end
    R.saveConfig()
    return ("drone %d's pickup chest: %s"):format(id, w[3])
  end
  if verb == "whitelist" then
    local yes, no = {}, {}
    for n, v in pairs(R.white) do if v then yes[#yes + 1] = n else no[#no + 1] = n end end
    return ("%d may be put back, %d may not - the list is repair.whitelist"):format(#yes, #no)
  end
  if verb == "allow" or verb == "deny" then
    if not w[2] then return verb .. " <part of a block name>" end
    local n = R.setWhite(w[2], verb == "allow")
    R.saveWhitelist()
    return ("%s: %d kind%s changed"):format(verb, n, n == 1 and "" or "s")
  end
  if verb == "need" then
    local keys = {}
    for k in pairs(R.ordered) do keys[#keys + 1] = k end
    if #keys == 0 then return "nothing ordered" end
    local _, need = R.pickTargets(keys, R.stock())
    return next(need) and ("short: " .. needText(need)) or "the depot has every part ordered"
  end
  return "unknown command - " .. R.HELP
end

function R.commandLoop()
  while true do
    write("> ")
    local line = read()
    local ok, out = pcall(R.command, line)
    if out then print(ok and out or ("error: " .. tostring(out))) end
  end
end

---------------------------------------------------------------- the network loop

function R.netLoop()
  local tick = os.startTimer(1)
  while true do
    local e, a, b, c = os.pullEvent()
    if e == "rednet_message" and c == R.PROTO then
      R.onMessage(a, b)
    elseif e == "timer" and a == tick then
      tick = os.startTimer(1)
      if R.groupsDirty or not R.groupsAt or now() - R.groupsAt >= 5 then R.broadcastGroups() end
      if not R.task then
        local id, keys = R.nextJob()
        if id then
          R.toldNoDrone = false
          R.startTask("job", R.jobTask, id, keys)
        elseif keys and not R.toldNoDrone then
          R.toldNoDrone = true
          R.say("Repairs ordered but " .. tostring(keys))
        elseif not R.anyOut() and R.cfg.sweepEvery and R.scout and (R.copyCount or 0) > 0
          and now() - (R.lastSweep or 0) >= (tonumber(R.cfg.sweepEvery) or 1800) then
          R.startTask("sweep", R.sweepTask)
        end
      end
      -- (a drone out too long: said once - its area stays kept until it is home, or: clear <id>)
      for oid, o in pairs(R.outs) do
        if o.kind == "job" and not o.told and now() - o.at > (tonumber(R.cfg.jobTimeout) or 1800) then
          o.told = true
          R.say(("Drone %d has been out %d s - check on it (clear %d once it is home)"):format(oid, math.floor(now() - o.at), oid), true)
        end
      end
    end
  end
end

function R.start()
  R.loadConfig()
  R.loadCopy()
  R.copySize()
  R.loadWhitelist()
  R.loadDamage()
  local rt = readTable(R.FILES.route)
  if rt and #rt > 1 then R.route = rt end
  R.loadOut()
  R.loadGlue()
  for k in pairs(R.damage) do
    if R.glued(k) then R.damage[k], R.ordered[k] = nil, nil end   -- (glued since: not damage)
  end
  R.regroup()
  local modems = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType(n, "modem") then
      pcall(rednet.open, n)
      local wireless = peripheral.call(n, "isWireless")
      if wireless then R.haveWireless = true end
      modems[#modems + 1] = n .. (wireless and " (ender/wireless)" or " (wired)")
    end
  end
  pcall(rednet.host, R.PROTO, R.HOST)
  R.askHello()
  R.log(("started: repair %s on computer %d; modems: %s"):format(R.VERSION, os.getComputerID(),
    #modems > 0 and table.concat(modems, ", ") or "NONE"))
  if not R.haveWireless then R.log("NO ender modem: the scout and the glasses cannot reach this computer") end
  R.lastSweep = now()
end

function R.main()
  R.start()
  term.clear()
  term.setCursorPos(1, 1)
  print(R.status())
  if not R.haveWireless then print("No ender (wireless) modem: the scout and the glasses cannot reach this computer") end
  print("type help for the commands")
  parallel.waitForAll(R.netLoop, R.taskLoop, R.commandLoop, R.monitorLoop)
end

if ARGS[1] == "lib" then return R end
R.main()
