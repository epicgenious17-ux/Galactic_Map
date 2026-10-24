--[[
mender.lua - puts back blocks that have gone missing round it          v1.0.1
A turtle with a Geo Scanner (Advanced Peripherals) and a stock of the
ship's blocks in slots 1-15 (slot 16: its fuel). It sits at its dock, looks
round every so often, and puts back blocks that have gone (broken, blown
off) as they were in its saved copy.

  mender snapshot   save how things are now (put it at its dock first)
  mender check      list what is missing - changes nothing
  mender            look and mend every `every` s, forever

It only fills gaps: a block that became something else is counted, never
touched, and it never digs. What it has no block for is listed ("need") on
its screen and in mender.log. The Geo Scanner only gives block names, so a
put-back block faces the way it is placed (stairs, logs: check them).

mender.cfg:
  radius = 8     how far it looks and goes (up to 8 is free; more uses fuel)
  every = 30     s between looks
  most = 32      blocks put back an outing at most
  skip = {...}   names (or parts) it never puts back
]]

local ARGS = { ... }
local M = { VERSION = "1.0.1" }
M.FILES = { cfg = "/mender.cfg", copy = "/mender.copy", log = "/mender.log" }
M.DEFAULTS = {
  radius = 8, every = 30, most = 32,
  skip = { "air", "fire", "water", "lava", ":light", "portal", "bubble_column", "piston_head", "moving_piston",
    "computercraft:turtle", "_door", "_bed", "tall_", "sunflower", "lilac", "peony", "rose_bush", "large_fern" },
}
M.FUEL_SLOT = 16
-- (blocks placed from an item of another name)
M.ITEM = {
  ["minecraft:redstone_wire"] = "minecraft:redstone", ["minecraft:wall_torch"] = "minecraft:torch",
  ["minecraft:redstone_wall_torch"] = "minecraft:redstone_torch", ["minecraft:soul_wall_torch"] = "minecraft:soul_torch",
  ["minecraft:tripwire"] = "minecraft:string",
}

local now = os.clock
local function key(x, y, z) return x .. "," .. y .. "," .. z end

function M.log(text)
  pcall(function()
    if fs.exists(M.FILES.log) and fs.getSize(M.FILES.log) > 16384 then
      if fs.exists(M.FILES.log .. ".old") then fs.delete(M.FILES.log .. ".old") end
      fs.move(M.FILES.log, M.FILES.log .. ".old")
    end
    local h = fs.open(M.FILES.log, "a")
    h.writeLine(("%8.1f %s"):format(now(), tostring(text)))
    h.close()
  end)
end

function M.loadConfig()
  local cfg
  if fs.exists(M.FILES.cfg) then
    local h = fs.open(M.FILES.cfg, "r")
    cfg = textutils.unserialize(h.readAll())
    h.close()
  end
  local fresh = type(cfg) ~= "table"
  if fresh then cfg = {} end
  for k, v in pairs(M.DEFAULTS) do
    if cfg[k] == nil then cfg[k] = v end
  end
  M.cfg = cfg
  if fresh then
    pcall(function()
      local h = fs.open(M.FILES.cfg, "w")
      h.write("-- mender.cfg - settings for mender.lua " .. M.VERSION .. ". Edit, save, then reboot.\n")
      h.write(textutils.serialize(cfg))
      h.close()
    end)
  end
end

function M.skipped(name)
  for _, s in ipairs(M.cfg.skip or {}) do
    if name:find(s, 1, true) then return true end
  end
  return false
end

function M.itemFor(block)
  if M.ITEM[block] then return M.ITEM[block] end
  local s = block
  for _, p in ipairs({ { "_wall_hanging_sign$", "_hanging_sign" }, { "_wall_sign$", "_sign" }, { "_wall_banner$", "_banner" },
    { "_wall_head$", "_head" }, { "_wall_skull$", "_skull" }, { "_wall_fan$", "_fan" } }) do
    s = s:gsub(p[1], p[2])
  end
  return s
end

---------------------------------------------------------------- looking

function M.scanner()
  return peripheral.find("geoScanner") or peripheral.find("geo_scanner")
end

-- Everything round it: { ["x,y,z"] = name } (x east, y up, z south from the
-- turtle, as the scanner gives them; the turtle itself left out). Advanced
-- Peripherals 0.8.2a calls it scanBlocks - older ones scan. On a ship it also
-- scans the world round the ship, marked notOnShip: left out
function M.scan(r)
  local scan = M.geo.scanBlocks or M.geo.scan
  local list, err
  for _ = 1, 10 do
    list, err = scan(r)
    if list then break end
    if not tostring(err):lower():find("cooldown") then break end
    sleep(1)
  end
  if not list then return nil, err end
  local out = {}
  for _, b in ipairs(list) do
    if not (b.x == 0 and b.y == 0 and b.z == 0) and not b.notOnShip then out[key(b.x, b.y, b.z)] = b.name end
  end
  return out
end

function M.saveCopy(copy, facing)
  local lines = { ("MENDER1 %d %d"):format(facing and facing.x or 0, facing and facing.z or 0) }
  for k, name in pairs(copy) do lines[#lines + 1] = k .. " " .. name end
  local h = fs.open(M.FILES.copy, "w")
  h.write(table.concat(lines, "\n") .. "\n")
  h.close()
end

function M.loadCopy()
  if not fs.exists(M.FILES.copy) then return nil end
  local h = fs.open(M.FILES.copy, "r")
  local text = h.readAll()
  h.close()
  local fx, fz = text:match("^MENDER1 (%-?%d+) (%-?%d+)")
  if not fx then return nil end
  local copy = {}
  for k, name in text:gmatch("\n(%-?%d+,%-?%d+,%-?%d+) (%S+)") do copy[k] = name end
  local facing = (tonumber(fx) ~= 0 or tonumber(fz) ~= 0) and { x = tonumber(fx), z = tonumber(fz) } or nil
  return copy, facing
end

---------------------------------------------------------------- which way it faces

local function right(f) return { x = -f.z, z = f.x } end
local function left(f) return { x = f.z, z = -f.x } end
M.DIRS = { { x = 1, z = 0 }, { x = -1, z = 0 }, { x = 0, z = 1 }, { x = 0, z = -1 } }

-- The way it faces in the scanner's frame: the block in front of it against
-- the four round it (turning to try each side); failing that, a step and a
-- small look. -> {x, z} or nil
function M.findFacing(scan)
  for turn = 0, 3 do
    local ok, info = turtle.inspect()
    if ok then
      local hits = {}
      for _, d in ipairs(M.DIRS) do
        if scan[key(d.x, 0, d.z)] == info.name then hits[#hits + 1] = d end
      end
      if #hits == 1 then
        local f = hits[1]
        for _ = 1, turn do
          f = left(f)
          turtle.turnLeft()
        end
        return f
      end
    end
    turtle.turnRight()
  end
  -- (back as it was after four turns) - a step forward or back, then which
  -- shift lines the new look up with the old: the one with no blocks out of
  -- place (a plain floor matches any shift - only the differences tell)
  for _, how in ipairs({ { go = "forward", undo = "back", sign = 1 }, { go = "back", undo = "forward", sign = -1 } }) do
    if turtle[how.go]() then
      local near = M.scan(3)
      turtle[how.undo]()
      if near then
        local best, bestBad, second = nil, math.huge, math.huge
        for _, d in ipairs(M.DIRS) do
          local bad = M.misfits(near, scan, d, 3)
          if bad < bestBad then best, bestBad, second = d, bad, bestBad elseif bad < second then second = bad end
        end
        if best and bestBad <= 2 and second >= bestBad + 3 then
          return { x = best.x * how.sign, z = best.z * how.sign }
        end
      end
    end
  end
  return nil
end

local function parse(k)
  local x, y, z = k:match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
  return tonumber(x), tonumber(y), tonumber(z)
end

-- Blocks that do not agree if the turtle moved by d between the old look
-- and a near one (radius nr) - both ways round, inside the near look's cube
function M.misfits(near, scan, d, nr)
  local bad = 0
  for k, name in pairs(near) do
    local x, y, z = parse(k)
    if scan[key(x + d.x, y, z + d.z)] ~= name then bad = bad + 1 end
  end
  for k, name in pairs(scan) do
    local x, y, z = parse(k)
    local nx, nz = x - d.x, z - d.z
    if math.abs(nx) <= nr and math.abs(y) <= nr and math.abs(nz) <= nr and not (nx == 0 and y == 0 and nz == 0)
      and near[key(nx, y, nz)] ~= name then
      bad = bad + 1
    end
  end
  return bad
end

---------------------------------------------------------------- moving

M.pos = { x = 0, y = 0, z = 0 }

-- F B U D, counted. Something in the way: tries again for up to `wait` s
function M.move(c, wait)
  local fn = ({ F = "forward", B = "back", U = "up", D = "down" })[c]
  local deadline = now() + (wait or 10)
  while true do
    if turtle[fn]() then
      local f, p = M.facing, M.pos
      if c == "F" then p.x, p.z = p.x + f.x, p.z + f.z
      elseif c == "B" then p.x, p.z = p.x - f.x, p.z - f.z
      elseif c == "U" then p.y = p.y + 1
      else p.y = p.y - 1 end
      return true
    end
    if now() >= deadline then return false end
    sleep(0.5)
  end
end

function M.turnTo(d)
  local f = M.facing
  if f.x == d.x and f.z == d.z then return end
  local r, l = right(f), left(f)
  if r.x == d.x and r.z == d.z then
    turtle.turnRight()
    M.facing = r
  elseif l.x == d.x and l.z == d.z then
    turtle.turnLeft()
    M.facing = l
  else
    turtle.turnRight()
    turtle.turnRight()
    M.facing = right(r)
  end
end

-- To a cell next to it
function M.stepTo(p, wait)
  local dx, dy, dz = p.x - M.pos.x, p.y - M.pos.y, p.z - M.pos.z
  if dy == 1 then return M.move("U", wait) end
  if dy == -1 then return M.move("D", wait) end
  local f = M.facing
  if dx == -f.x and dz == -f.z then return M.move("B", wait) end   -- (behind: backs up, no turning)
  M.turnTo({ x = dx, z = dz })
  return M.move("F", wait)
end

local SIX = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }

-- The shortest way through free cells (inside the looked-at cube) from `from`
-- to `to`. -> the cells after `from`, or nil
function M.path(from, to, solid, r)
  local start, goal = key(from.x, from.y, from.z), key(to.x, to.y, to.z)
  if start == goal then return {} end
  local prev, queue, head = { [start] = false }, { from }, 1
  while queue[head] do
    local c = queue[head]
    head = head + 1
    for _, d in ipairs(SIX) do
      local n = { x = c.x + d[1], y = c.y + d[2], z = c.z + d[3] }
      local k = key(n.x, n.y, n.z)
      if prev[k] == nil and not solid[k] and math.abs(n.x) <= r and math.abs(n.y) <= r and math.abs(n.z) <= r then
        prev[k] = c
        if k == goal then
          local out, at = {}, n
          while at and key(at.x, at.y, at.z) ~= start do
            table.insert(out, 1, at)
            at = prev[key(at.x, at.y, at.z)]
          end
          return out
        end
        queue[#queue + 1] = n
      end
    end
  end
  return nil
end

function M.walk(path, wait)
  for _, c in ipairs(path) do
    if not M.stepTo(c, wait) then return false end
  end
  return true
end

---------------------------------------------------------------- mending

function M.findItem(name)
  for slot = 1, 15 do
    local d = turtle.getItemDetail(slot)
    if d and d.name == name then return slot end
  end
end

-- What the copy has and the world does not (nearest first), and how many
-- blocks changed into something else
function M.compare(copy, scan)
  local missing, changed = {}, 0
  for k, name in pairs(copy) do
    local now_ = scan[k]
    if not now_ then
      if not M.skipped(name) then
        local x, y, z = k:match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
        missing[#missing + 1] = { x = tonumber(x), y = tonumber(y), z = tonumber(z), name = name }
      end
    elseif now_ ~= name then
      changed = changed + 1
    end
  end
  table.sort(missing, function(a, b)
    local da, db = math.abs(a.x) + math.abs(a.y) + math.abs(a.z), math.abs(b.x) + math.abs(b.y) + math.abs(b.z)
    if da ~= db then return da < db end
    return key(a.x, a.y, a.z) < key(b.x, b.y, b.z)
  end)
  return missing, changed
end

-- Where to stand to put a block at t, and how: from above (placeDown) first,
-- then below (placeUp), then beside it facing it
local function spots(t)
  return {
    { x = t.x, y = t.y + 1, z = t.z, how = "placeDown" },
    { x = t.x, y = t.y - 1, z = t.z, how = "placeUp" },
    { x = t.x - 1, y = t.y, z = t.z, how = "place", face = { x = 1, z = 0 } },
    { x = t.x + 1, y = t.y, z = t.z, how = "place", face = { x = -1, z = 0 } },
    { x = t.x, y = t.y, z = t.z - 1, how = "place", face = { x = 0, z = 1 } },
    { x = t.x, y = t.y, z = t.z + 1, how = "place", face = { x = 0, z = -1 } },
  }
end

-- One look and one outing. -> a summary {missing, changed, fixed, need = {item = n}, unreachable, failed}
function M.mendOnce(dryRun)
  local r = tonumber(M.cfg.radius) or 8
  local scan, err = M.scan(r)
  if not scan then return nil, "scanner: " .. tostring(err) end
  local missing, changed = M.compare(M.copy, scan)
  local out = { missing = #missing, changed = changed, fixed = 0, need = {}, unreachable = 0, failed = 0 }
  if dryRun or #missing == 0 then
    for _, b in ipairs(missing) do
      local item = M.itemFor(b.name)
      if not M.findItem(item) then out.need[item] = (out.need[item] or 0) + 1 end
    end
    return out
  end
  local level = turtle.getFuelLevel()
  if level ~= "unlimited" and level < 6 * r then
    turtle.select(M.FUEL_SLOT)
    while turtle.getFuelLevel() < 20 * r and turtle.getItemCount(M.FUEL_SLOT) > 0 and turtle.refuel(1) do end
    turtle.select(1)
    if turtle.getFuelLevel() < 6 * r then return nil, "needs fuel in slot 16" end
  end
  local solid = {}
  for k in pairs(scan) do solid[k] = true end
  local done = 0
  for _, b in ipairs(missing) do
    if done >= (tonumber(M.cfg.most) or 32) then break end
    local item = M.itemFor(b.name)
    local slot = M.findItem(item)
    if not slot then
      out.need[item] = (out.need[item] or 0) + 1
    else
      local target = key(b.x, b.y, b.z)
      solid[target] = true                       -- (not a way through: it is about to be filled)
      local path, spot
      for _, s in ipairs(spots(b)) do
        local sk = key(s.x, s.y, s.z)
        if not solid[sk] then
          path = M.path(M.pos, s, solid, r)
          if path then spot = s break end
        end
      end
      if not spot then
        solid[target] = nil
        out.unreachable = out.unreachable + 1
      elseif not M.walk(path, 10) then
        solid[target] = nil
        out.failed = out.failed + 1
        break                                    -- (something in the way: home, try next time)
      else
        if spot.face then M.turnTo(spot.face) end
        turtle.select(slot)
        if turtle[spot.how]() then
          out.fixed = out.fixed + 1
          done = done + 1
        else
          solid[target] = nil
          out.failed = out.failed + 1
        end
        turtle.select(1)
      end
    end
  end
  M.goHome(solid, r)
  return out
end

-- Back to the dock, facing as it was. It keeps trying
function M.goHome(solid, r)
  local told
  while M.pos.x ~= 0 or M.pos.y ~= 0 or M.pos.z ~= 0 do
    local path = M.path(M.pos, { x = 0, y = 0, z = 0 }, solid, r)
    if path and M.walk(path, 10) then break end
    if not told or now() - told > 60 then
      told = now()
      M.log(("cannot get back to the dock from %d,%d,%d - still trying"):format(M.pos.x, M.pos.y, M.pos.z))
    end
    sleep(2)
  end
  if M.home then M.turnTo(M.home) end
end

---------------------------------------------------------------- the screen

function M.draw()
  term.clear()
  term.setCursorPos(1, 1)
  print(("MENDER %s (turtle %d)"):format(M.VERSION, os.getComputerID()))
  local n = 0
  for _ in pairs(M.copy or {}) do n = n + 1 end
  print(("copy: %d blocks, radius %d"):format(n, M.cfg.radius))
  print(("fuel: %s"):format(tostring(turtle.getFuelLevel())))
  local s = M.last
  if s then
    print(("last look: %d missing, %d fixed, %d changed"):format(s.missing, s.fixed, s.changed))
    if s.unreachable > 0 or s.failed > 0 then print(("  %d out of reach, %d failed"):format(s.unreachable, s.failed)) end
    local needs = {}
    for item, c in pairs(s.need) do needs[#needs + 1] = c .. " " .. item:gsub("^minecraft:", "") end
    if #needs > 0 then print("need: " .. table.concat(needs, ", ")) end
  elseif M.lastErr then
    print("last look: " .. M.lastErr)
  end
  print("")
  print("Ctrl+T: stop")
end

local function summary(s)
  local needs = {}
  for item, c in pairs(s.need) do needs[#needs + 1] = c .. " " .. item end
  return ("%d missing, %d fixed, %d changed, %d out of reach, %d failed%s"):format(s.missing, s.fixed, s.changed,
    s.unreachable, s.failed, #needs > 0 and ("; need " .. table.concat(needs, ", ")) or "")
end

function M.start()
  M.geo = M.scanner()
  if not M.geo then error("No Geo Scanner on this turtle (Advanced Peripherals turtle upgrade)", 0) end
end

if ARGS[1] == "lib" then return M end

M.loadConfig()
M.start()
if ARGS[1] == "snapshot" then
  local scan, err = M.scan(tonumber(M.cfg.radius) or 8)
  if not scan then error("scanner: " .. tostring(err), 0) end
  local facing = M.findFacing(scan)
  M.saveCopy(scan, facing)
  local n = 0
  for _ in pairs(scan) do n = n + 1 end
  M.log(("snapshot: %d blocks%s"):format(n, facing and "" or " (which way it faces: unknown)"))
  print(("Saved %d blocks round the dock."):format(n))
  if not facing then print("Could not tell which way it faces: put a different block in front of it and snapshot again.") end
  return
end

local copy, facing = M.loadCopy()
if not copy then error("No copy yet - put it at its dock and type: mender snapshot", 0) end
M.copy = copy
local scan = M.scan(tonumber(M.cfg.radius) or 8)
M.facing = scan and M.findFacing(scan) or facing
if not M.facing then error("Cannot tell which way it faces - put a different block in front of it", 0) end
M.home = { x = M.facing.x, z = M.facing.z }

if ARGS[1] == "check" then
  local s, err = M.mendOnce(true)
  print(s and summary(s) or ("NO: " .. tostring(err)))
  return
end

while true do
  local s, err = M.mendOnce(false)
  M.last, M.lastErr = s, err
  M.log(s and summary(s) or ("NO: " .. tostring(err)))
  M.draw()
  sleep(tonumber(M.cfg.every) or 30)
end
