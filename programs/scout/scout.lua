--[[
scout.lua - the repair system's scout: scans the ship along a route      v1.0.3
A turtle with a Geo Scanner and an ender (or wireless) modem. It sits at
its dock (anywhere inside the ship); the repair computer (repair.lua) sends
it round its route to make the copy (survey) or look for damage (sweep).

  scout          wait for the repair computer's orders (its startup). The
                 first survey makes its route by itself: it explores -
                 scans where it is, goes to the nearest place no scan has
                 come within scanEvery of, scans again, until every place
                 it can reach inside the ship (ship blocks above and below)
                 is scanned near - then comes home and keeps the moves (S
                 where it scanned) as its route for the sweeps
  scout record   (instead) drive the route by hand with the keys below;
                 Enter saves it and it drives home. It scans every
                 scanEvery blocks, radius 8 round it, through walls.
Everything it finds at start (its kit, its facing, the repair computer) is
written to scout.log, and on a run each scan and anything in its way. On a
run each move is written to scout.trail before it is made: restarted away
from its dock, it goes back there before anything else.

Keys while recording (in the turtle's screen): W / S forward / back, A / D
turn, Space up, Left Shift down, Backspace undo the last move, Enter done,
Q give up (it drives home, nothing saved).

It never digs, and it moves only with the repair computer's permit (its
runs; recording asks for it first). A player or mob in the way: it waits
`wait` s, then gives up the run and goes home; another turtle in the way:
it turns back at once. Other turtles near its dock are the drones: the
repair computer tells them apart by turning each while the scout looks.

Fuel: before every run it tops itself up (to nearly full) from a fuel-only
inventory touching its dock - in front, above or below - e.g. a vault of
coal blocks. If that is a small chest on the repair computer's wired
network, the repair computer keeps it filled from the depot.

scout.cfg:
  radius = 8        scan radius (8 is free; up to 16 costs a lot of fuel)
  scanEvery = 8     blocks moved between scans
  wait = 20         s to wait for something in the way
  fuelFrom = "auto" where its fuel inventory is: "front", "up", "down", or
                    "auto" (whichever of those has an inventory), false = none
  facing = false    its facing at the dock, if the Geo Scanner does not
                    show its own block ("north", "east" ...)
]]

local ARGS = { ... }
local SC = { VERSION = "1.0.3" }
SC.PROTO, SC.HOST = "destroyer.repair", "repair"
SC.FILES = { cfg = "/scout.cfg", route = "/scout.route", log = "/scout.log", trail = "/scout.trail" }
SC.DEFAULTS = { radius = 8, scanEvery = 8, wait = 20, fuelFrom = "auto", facing = false }
-- what it burns (fuel units each)
SC.FUEL = { ["minecraft:coal_block"] = 800, ["minecraft:coal"] = 80, ["minecraft:charcoal"] = 80, ["minecraft:blaze_rod"] = 120,
  ["minecraft:dried_kelp_block"] = 200 }
SC.NAMES = { F = "forward", B = "back", U = "up", D = "down", L = "turnLeft", R = "turnRight" }
SC.OPPOSITE = { F = "B", B = "F", U = "D", D = "U", L = "R", R = "L" }
SC.FACE = { north = { 0, 0, -1 }, east = { 1, 0, 0 }, south = { 0, 0, 1 }, west = { -1, 0, 0 } }
SC.RIGHT = { north = "east", east = "south", south = "west", west = "north" }
SC.LEFT = { north = "west", west = "south", south = "east", east = "north" }

local now = os.clock

function SC.log(text)
  pcall(function()
    if fs.exists(SC.FILES.log) and fs.getSize(SC.FILES.log) > 16384 then
      if fs.exists(SC.FILES.log .. ".old") then fs.delete(SC.FILES.log .. ".old") end
      fs.move(SC.FILES.log, SC.FILES.log .. ".old")
    end
    local h = fs.open(SC.FILES.log, "a")
    h.writeLine(("%8.1f %s"):format(now(), tostring(text)))
    h.close()
  end)
end

local function readTable(path)
  if not fs.exists(path) then return nil end
  local h = fs.open(path, "r")
  local t = textutils.unserialize(h.readAll())
  h.close()
  return type(t) == "table" and t or nil
end

function SC.loadConfig()
  local cfg = readTable(SC.FILES.cfg)
  local fresh = cfg == nil
  cfg = cfg or {}
  for k, v in pairs(SC.DEFAULTS) do
    if cfg[k] == nil then cfg[k] = v end
  end
  SC.cfg = cfg
  if fresh then
    pcall(function()
      local h = fs.open(SC.FILES.cfg, "w")
      h.write("-- scout.cfg - settings for scout.lua " .. SC.VERSION .. " (see its header). Edit, save, reboot.\n" .. textutils.serialize(cfg))
      h.close()
    end)
  end
end

function SC.loadRoute()
  SC.route = nil
  if not fs.exists(SC.FILES.route) then return end
  local h = fs.open(SC.FILES.route, "r")
  local text = h.readAll() or ""
  h.close()
  SC.route = text:match("^[FBUDLR]*") or ""
end

function SC.saveRoute(moves)
  local h = fs.open(SC.FILES.route, "w")
  h.write(moves)
  h.close()
  SC.route = moves
end

---------------------------------------------------------------- looking

-- "name[k=v,...]" (as repair.lua's copy keeps block states)
function SC.stateKey(name, state)
  local parts = {}
  for k, v in pairs(type(state) == "table" and state or {}) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
  table.sort(parts)
  return #parts > 0 and (name .. "[" .. table.concat(parts, ",") .. "]") or name
end

-- A scan round it -> { { dx, dy, dz, state key, item }, ... }, its own
-- facing (from its block), how many were off the ship - or nil, why
-- (Advanced Peripherals 0.8.2a calls it scanBlocks - older ones scan. On a
-- ship it may also scan the world round the ship, marked notOnShip: left out)
function SC.look()
  local scan = SC.geo.scanBlocks or SC.geo.scan
  if not scan then return nil, "the Geo Scanner has no scanBlocks method" end
  local list, err
  for _ = 1, 10 do
    local ok, a, b = pcall(scan, tonumber(SC.cfg.radius) or 8)
    if ok then list, err = a, b else list, err = nil, a end
    if list then break end
    if not tostring(err):lower():find("cooldown") then break end
    sleep(0.5)
  end
  if type(list) ~= "table" then return nil, tostring(err) end
  local out, facing, off = {}, nil, 0
  for _, b in ipairs(list) do
    if type(b) == "table" and b.name and b.notOnShip then
      off = off + 1
    elseif type(b) == "table" and b.name then
      out[#out + 1] = { b.x, b.y, b.z, SC.stateKey(b.name, b.state), b.item }
      if b.x == 0 and b.y == 0 and b.z == 0 and type(b.state) == "table" then facing = b.state.facing end
    end
  end
  return out, facing, off
end

-- How many blocks a scan saw besides the turtle itself
function SC.seen(blocks)
  local n = 0
  for _, b in ipairs(blocks or {}) do
    if not (b[1] == 0 and b[2] == 0 and b[3] == 0) then n = n + 1 end
  end
  return n
end

-- (in scout.log: what its first scan saw and what touches it - if the copy
-- comes out empty, this says why)
function SC.describe(blocks, off)
  local names = {}
  for _, b in ipairs(blocks or {}) do
    if not (b[1] == 0 and b[2] == 0 and b[3] == 0) then
      local name = b[4]:match("^[^%[]+")
      names[name] = (names[name] or 0) + 1
    end
  end
  local top = {}
  for name, c in pairs(names) do top[#top + 1] = { name, c } end
  table.sort(top, function(a, b) return a[2] > b[2] end)
  local parts = {}
  for i = 1, math.min(5, #top) do parts[i] = top[i][1] .. " x" .. top[i][2] end
  SC.log(("first scan: %d blocks round it%s%s"):format(SC.seen(blocks), (off or 0) > 0 and (" (and " .. off .. " off the ship, left out)") or "",
    #parts > 0 and (" - " .. table.concat(parts, ", ")) or ""))
  local near = {}
  for _, w in ipairs({ { "front", "inspect" }, { "up", "inspectUp" }, { "down", "inspectDown" } }) do
    local ok, d = turtle[w[2]]()
    near[#near + 1] = w[1] .. " " .. (ok and type(d) == "table" and tostring(d.name) or "nothing")
  end
  SC.log("touching it: " .. table.concat(near, ", ") .. "; its fuel inventory: " .. tostring(SC.fuelSide() or "none found"))
end

---------------------------------------------------------------- moving

SC.pos, SC.facing = { 0, 0, 0 }, "north"

-- Is another turtle in the way of move c? (not behind it: a turtle cannot look back)
local LOOK = { F = "inspect", U = "inspectUp", D = "inspectDown" }
function SC.turtleInWay(c)
  local fn = LOOK[c]
  if not fn or not turtle[fn] then return false end
  local ok, info = turtle[fn]()
  return ok and type(info) == "table" and tostring(info.name):find("computercraft:turtle", 1, true) ~= nil
end

-- On a run every move is written to scout.trail before it is made, with the
-- fuel then (a move that happened used 1): "HOME <facing>", then "<move>
-- <fuel>", "- <fuel>" (going home: the last move undone) or "x" (the line
-- before did not happen). Restarted away from its dock, it reads the way
-- back from it (SC.recover)
function SC.trail(line)
  if not SC.trailing then return end
  pcall(function()
    local h = fs.open(SC.FILES.trail, "a")
    h.writeLine(line)
    h.close()
  end)
end

function SC.trailStart()
  pcall(function()
    local h = fs.open(SC.FILES.trail, "w")
    h.writeLine("HOME " .. tostring(SC.homeFacing))
    h.close()
  end)
  SC.trailing = true
end

function SC.trailDone()
  SC.trailing = false
  pcall(function() if fs.exists(SC.FILES.trail) then fs.delete(SC.FILES.trail) end end)
end

-- scout.trail -> the moves not yet undone (a string), its facing at the dock
-- - or nil (no trail)
function SC.readTrail()
  if not fs.exists(SC.FILES.trail) then return nil end
  local h = fs.open(SC.FILES.trail, "r")
  local text = h.readAll() or ""
  h.close()
  local home, stack, last, popped = nil, {}, nil, nil
  for line in text:gmatch("[^\n]+") do
    local a, b = line:match("^(%S+)%s*(%S*)")
    if a == "HOME" then
      home = b
    elseif a == "x" then
      if last == "push" then stack[#stack] = nil elseif last == "pop" then stack[#stack + 1] = popped end
      last = nil
    elseif a == "-" then
      popped, last = stack[#stack], nil
      if popped then
        stack[#stack] = nil
        popped.undoFuel, last = tonumber(b), "pop"
      end
    elseif SC.NAMES[a or ""] then
      stack[#stack + 1] = { c = a, fuel = tonumber(b) }
      last = "push"
    end
  end
  -- (the last line was written before its move: a move that used no fuel did
  -- not happen. A turn cannot tell - SC.recover turns to where the trail says)
  local fuel = turtle.getFuelLevel()
  if last == "push" and ("FBUD"):find(stack[#stack].c, 1, true) and fuel == stack[#stack].fuel then
    stack[#stack] = nil
  elseif last == "pop" and ("FBUD"):find(popped.c, 1, true) and fuel == popped.undoFuel then
    stack[#stack + 1] = popped
  end
  local moves = {}
  for i, s in ipairs(stack) do moves[i] = s.c end
  return table.concat(moves), home
end

-- One move (counted; written to the trail on a run). Something in the way:
-- tries again for up to wait s - another turtle: gives up at once. undo: it
-- is going home (the last move undone). -> true, or false + why
function SC.step(c, wait, undo)
  SC.trail((undo and "-" or c) .. " " .. tostring(turtle.getFuelLevel()))
  local deadline = now() + (wait or 10)
  while true do
    if turtle[SC.NAMES[c]]() then
      local v, p = SC.FACE[SC.facing], SC.pos
      if c == "F" then p[1], p[3] = p[1] + v[1], p[3] + v[3]
      elseif c == "B" then p[1], p[3] = p[1] - v[1], p[3] - v[3]
      elseif c == "U" then p[2] = p[2] + 1
      elseif c == "D" then p[2] = p[2] - 1
      elseif c == "R" then SC.facing = SC.RIGHT[SC.facing]
      else SC.facing = SC.LEFT[SC.facing] end
      return true
    end
    if SC.turtleInWay(c) then
      SC.trail("x")
      return false, "another turtle in the way"
    end
    if now() >= deadline then
      SC.trail("x")
      return false, "something in the way"
    end
    sleep(0.5)
  end
end

-- Home from after the first n moves of the route: undone last first,
-- backwards (no turning round). It keeps trying
function SC.goHome(moves, n)
  for i = n, 1, -1 do
    local c = SC.OPPOSITE[moves:sub(i, i)]
    local told
    while c do                                      -- (S - a scan mark - is no move)
      local ok, why = SC.step(c, 30, true)
      if ok then break end
      if not told then
        told = true
        SC.log("going home: " .. tostring(why) .. " - still trying")
      end
      sleep(2)
    end
  end
end

-- Its fuel inventory: "front" / "up" / "down" (nil: none) - as scout.cfg
-- says, or (auto) whichever of those has an inventory
local AS_PERIPHERAL = { front = "front", up = "top", down = "bottom" }
function SC.fuelSide()
  local f = SC.cfg.fuelFrom
  if AS_PERIPHERAL[f or ""] then return f end
  if f ~= "auto" then return nil end
  for _, s in ipairs({ "down", "up", "front" }) do
    if peripheral.hasType(AS_PERIPHERAL[s], "inventory") then return s end
  end
end

-- What its fuel inventory holds: { [item] = count } (nil: none)
function SC.peek()
  local s = SC.fuelSide()
  if not s then return nil end
  local ok, list = pcall(peripheral.call, AS_PERIPHERAL[s], "list")
  if not ok or type(list) ~= "table" then return nil end
  local out = {}
  for _, it in pairs(list) do
    if type(it) == "table" and it.name then out[it.name] = (out[it.name] or 0) + (it.count or 0) end
  end
  return out
end

-- Burn what it carries, then take more from its fuel inventory, until it has
-- `need` (and, with an inventory to take from, nearly a full tank).
-- -> true if it has need, false + why
function SC.refuel(need)
  local level = turtle.getFuelLevel()
  if level == "unlimited" then return true end
  local side = SC.fuelSide()
  local limit = turtle.getFuelLimit and turtle.getFuelLimit() or 20000
  local target = side and math.max(need, limit - 800) or need
  local function burn()
    -- (as many of a stack as it needs at once: one by one is a tick each)
    for slot = 1, 16 do
      local d = turtle.getItemDetail(slot)
      local each = d and SC.FUEL[d.name]
      if each then
        local have = turtle.getFuelLevel()
        local n = math.min(d.count, math.floor((limit - have) / each), math.ceil((target - have) / each))
        if n > 0 then
          turtle.select(slot)
          turtle.refuel(n)
        end
      end
    end
  end
  burn()
  local suck = ({ up = "suckUp", down = "suckDown", front = "suck" })[side or ""]
  local drop = ({ up = "dropUp", down = "dropDown", front = "drop" })[side or ""]
  local why
  for _ = 1, 8 do
    if not suck or turtle.getFuelLevel() >= target then break end
    local free
    for slot = 1, 16 do if turtle.getItemCount(slot) == 0 then free = slot break end end
    if not free then break end
    turtle.select(free)
    if not turtle[suck](64) then break end
    local d = turtle.getItemDetail(free)
    if not d or not SC.FUEL[d.name] then
      turtle[drop]()                                -- (not fuel: back where it came from)
      why = "its fuel inventory has other things in it (keep it fuel only)"
      break
    end
    burn()
  end
  turtle.select(1)
  if turtle.getFuelLevel() ~= level then SC.log(("fuel %s -> %s"):format(tostring(level), tostring(turtle.getFuelLevel()))) end
  if turtle.getFuelLevel() >= need then return true end
  return false, why or ("needs fuel: %d for the route, has %d"):format(need, turtle.getFuelLevel())
end

---------------------------------------------------------------- talking

function SC.findRepair()
  local ok, id = pcall(rednet.lookup, SC.PROTO, SC.HOST)
  if ok and id then SC.repairId = id end
  return SC.repairId
end

function SC.hello()
  if not SC.repairId then SC.findRepair() end
  if not SC.repairId then
    if SC.toldRepair ~= false then
      SC.toldRepair = false
      SC.log("repair computer not found (rednet lookup destroyer.repair) - is repair.lua running there, with an ender modem?")
    end
    return false
  end
  if SC.toldRepair ~= true then
    SC.toldRepair = true
    SC.log("repair computer: " .. tostring(SC.repairId))
  end
  pcall(rednet.send, SC.repairId, { op = "hello", role = "scout", route = SC.route or "", facing = SC.homeFacing,
    fuel = turtle.getFuelLevel(), limit = turtle.getFuelLimit and turtle.getFuelLimit() or nil, fuelSide = SC.fuelSide(),
    version = SC.VERSION }, SC.PROTO)
  return true
end

-- The permit to move by hand (recording its route): -> true, or false + why.
-- No repair computer at all: nothing else can be moving - allowed
function SC.askPermit(why)
  if not SC.findRepair() then return true end
  pcall(rednet.send, SC.repairId, { op = "move?", why = why }, SC.PROTO)
  local deadline = now() + 5
  while now() < deadline do
    local id, m = rednet.receive(SC.PROTO, math.max(0.1, deadline - now()))
    if id == SC.repairId and type(m) == "table" then
      if m.op == "go" then return true end
      if m.op == "wait" then return false, tostring(m.why) end
    end
  end
  return true
end

function SC.openModem()
  local modem = peripheral.find("modem", function(_, m) return m.isWireless and m.isWireless() end)
  if not modem then return false end
  rednet.open(peripheral.getName(modem))
  return true
end

-- What it is doing, on its screen (a run says nothing else there)
function SC.show(text)
  term.clear()
  term.setCursorPos(1, 1)
  print(("SCOUT %s (turtle %d)"):format(SC.VERSION, os.getComputerID()))
  print(text)
end

-- (on a run, nothing sent for 30 s: tells the repair computer it is still
-- busy, so it does not give up on it)
function SC.alive(run, info)
  if now() - (SC.lastSent or 0) < 30 then return end
  SC.lastSent = now()
  pcall(rednet.send, SC.repairId, { op = "alive", run = run, info = info }, SC.PROTO)
end

-- Send a scan and wait for the repair computer to take it (3 tries). A stop
-- order meanwhile is noted. -> true if taken
function SC.send(msg)
  SC.lastSent = now()
  for _ = 1, 3 do
    pcall(rednet.send, SC.repairId, msg, SC.PROTO)
    local deadline = now() + 6
    while now() < deadline do
      local id, m = rednet.receive(SC.PROTO, math.max(0.1, deadline - now()))
      if id == SC.repairId and type(m) == "table" and m.run == msg.run then
        if m.op == "stop" then SC.stopped = true return true end
        if m.op == "ack" and m.n == msg.n then return true end
      end
    end
  end
  return false
end

function SC.scanHere(mode, run, n)
  local blocks, why = SC.look()
  if not blocks then return false, "scanner: " .. tostring(why) end
  local p = SC.pos
  if not SC.send({ op = "scan", run = run, mode = mode, n = n, at = { p[1], p[2], p[3] }, r = tonumber(SC.cfg.radius) or 8, blocks = blocks }) then
    return false, "the repair computer stopped answering"
  end
  return true
end

-- A survey or sweep: along the route, scanning at the dock and at each S in
-- it (a route it explored) - or every scanEvery blocks (a route driven by
-- hand), then home. -> nil, or why it stopped
function SC.run(mode, run)
  local moves = SC.route or ""
  if #moves == 0 then return "no route yet (survey makes one: the scout explores)" end
  local marked = moves:find("S", 1, true) ~= nil
  local walk = 0
  for c in moves:gmatch("[FBUD]") do walk = walk + 1 end
  local fueled, short = SC.refuel(2 * walk + 40)
  if not fueled then return short end
  SC.pos, SC.facing, SC.stopped = { 0, 0, 0 }, SC.homeFacing, false
  local n, since, done, why = 0, 0, 0, nil
  local ok, err = SC.scanHere(mode, run, n)
  if not ok then return err end
  SC.trailStart()
  for i = 1, #moves do
    if SC.stopped then why = "stopped" break end
    local c = moves:sub(i, i)
    SC.alive(run, ("move %d of %d"):format(i, #moves))
    if i % 50 == 1 then SC.show(("%s: move %d of %d, fuel %s"):format(mode:upper(), i, #moves, tostring(turtle.getFuelLevel()))) end
    if c == "S" then
      n = n + 1
      ok, err = SC.scanHere(mode, run, n)
      if not ok then why = err break end
    else
      local moved, blocked = SC.step(c, tonumber(SC.cfg.wait) or 20)
      if not moved then
        why = ("blocked at move %d of %d (%s)"):format(i, #moves, tostring(blocked))
        break
      end
      if c ~= "L" and c ~= "R" then since = since + 1 end
      if not marked and (since >= (tonumber(SC.cfg.scanEvery) or 8) or i == #moves) then
        since, n = 0, n + 1
        ok, err = SC.scanHere(mode, run, n)
        if not ok then
          done = i
          why = err
          break
        end
      end
    end
    done = i
  end
  SC.goHome(moves, done)
  for _ = 1, 4 do
    if SC.facing == SC.homeFacing then break end
    turtle.turnRight()
    SC.facing = SC.RIGHT[SC.facing]
  end
  SC.trailDone()
  return why
end

---------------------------------------------------------------- exploring: the route made by itself

-- With no route yet, a survey explores: scan where it is, go to the nearest
-- free cell no scan has come within scanEvery of, scan again - until every
-- reachable place has been scanned near. It stays inside the ship (a free
-- cell needs ship blocks both above and below it) and never digs. The moves
-- it made, with S where it scanned, become its route for the sweeps.

local function mapKey(x, y, z) return (x + 2048) + (y + 2048) * 4096 + (z + 2048) * 16777216 end
local SIX = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }
SC.PASS = { "minecraft:water", "minecraft:light", "minecraft:short_grass", "minecraft:tall_grass", "minecraft:bubble_column" }
SC.ROOF = 48           -- blocks to look up and down for ship blocks (inside the ship)

local beats = 0
local function breathe()
  beats = beats + 1
  if beats % 3000 == 0 then
    os.queueEvent("scout_breathe")
    os.pullEvent("scout_breathe")
  end
end

-- What it knows of the ship: the solid cells, each column's solid heights, where it scanned
function SC.newMap(r) return { solid = {}, cols = {}, centers = {}, grid = {}, r = r } end

function SC.mapAdd(map, blocks, at)
  local r = map.r
  for _, b in ipairs(blocks) do
    if not (b[1] == 0 and b[2] == 0 and b[3] == 0) then
      local pass = false
      for _, p in ipairs(SC.PASS) do if b[4]:find(p, 1, true) == 1 then pass = true end end
      if not pass then
        local x, y, z = at[1] + b[1], at[2] + b[2], at[3] + b[3]
        local k = mapKey(x, y, z)
        if not map.solid[k] then
          map.solid[k] = true
          local ck = x * 8192 + z
          local l = map.cols[ck]
          if not l then
            l = {}
            map.cols[ck] = l
          end
          l[#l + 1] = y
        end
      end
    end
  end
  local c = { at[1], at[2], at[3] }
  map.centers[#map.centers + 1] = c
  for bx = math.floor((at[1] - r) / 16), math.floor((at[1] + r) / 16) do
    for by = math.floor((at[2] - r) / 16), math.floor((at[2] + r) / 16) do
      for bz = math.floor((at[3] - r) / 16), math.floor((at[3] + r) / 16) do
        local b = bx .. "," .. by .. "," .. bz
        map.grid[b] = map.grid[b] or {}
        table.insert(map.grid[b], c)
      end
    end
  end
end

-- Is a scan centre within d of (x, y, z)? (d at most the scan radius)
function SC.nearScan(map, x, y, z, d)
  for _, c in ipairs(map.grid[math.floor(x / 16) .. "," .. math.floor(y / 16) .. "," .. math.floor(z / 16)] or {}) do
    if math.max(math.abs(x - c[1]), math.abs(y - c[2]), math.abs(z - c[3])) <= d then return true end
  end
  return false
end

-- A cell it may move into: seen, not solid, ship blocks above and below it
function SC.freeCell(map, x, y, z)
  if map.solid[mapKey(x, y, z)] or not SC.nearScan(map, x, y, z, map.r) then return false end
  local l = map.cols[x * 8192 + z]
  if not l then return false end
  local up, down = false, false
  for _, yy in ipairs(l) do
    if yy > y and yy - y <= SC.ROOF then up = true elseif yy < y and y - yy <= SC.ROOF then down = true end
    if up and down then return true end
  end
  return false
end

-- The way to the nearest free cell no scan has come within gap of -
-- breadth-first over free cells, a box round it at a time. -> cells, or nil
function SC.nextTarget(map, pos, gap, avoid)
  local sk = mapKey(pos[1], pos[2], pos[3])
  for _, reach in ipairs({ 24, 72, 400 }) do
    local prev, q, head = { [sk] = false }, { { pos[1], pos[2], pos[3] } }, 1
    while q[head] do
      local c = q[head]
      head = head + 1
      if head > 2 and not SC.nearScan(map, c[1], c[2], c[3], gap - 1) then
        local path, cc = {}, c
        while cc do
          table.insert(path, 1, cc)
          cc = prev[mapKey(cc[1], cc[2], cc[3])]
        end
        table.remove(path, 1)
        return path
      end
      for _, d in ipairs(SIX) do
        local x, y, z = c[1] + d[1], c[2] + d[2], c[3] + d[3]
        if math.abs(x - pos[1]) <= reach and math.abs(y - pos[2]) <= reach and math.abs(z - pos[3]) <= reach then
          local nk = mapKey(x, y, z)
          if prev[nk] == nil and not avoid[nk] and SC.freeCell(map, x, y, z) then
            prev[nk] = c
            q[#q + 1] = { x, y, z }
          end
        end
        breathe()
      end
    end
  end
  return nil
end

-- One step to a cell next to it (turning as needed). -> the moves made, ok
function SC.moveTo(c)
  local p = SC.pos
  local dx, dy, dz = c[1] - p[1], c[2] - p[2], c[3] - p[3]
  local wait = tonumber(SC.cfg.wait) or 20
  if dy ~= 0 then
    local m = dy > 0 and "U" or "D"
    return m, SC.step(m, wait)
  end
  local v = SC.FACE[SC.facing]
  if dx == -v[1] and dz == -v[3] then return "B", SC.step("B", wait) end
  local done = ""
  for _ = 1, 2 do
    v = SC.FACE[SC.facing]
    if v[1] == dx and v[3] == dz then break end
    local t = (SC.FACE[SC.RIGHT[SC.facing]][1] == dx and SC.FACE[SC.RIGHT[SC.facing]][3] == dz) and "R" or "L"
    SC.step(t, wait)
    done = done .. t
  end
  return done .. "F", SC.step("F", wait)
end

-- Explore, sending each scan to the repair computer as a survey's. -> the route, or nil + why
function SC.explore(run)
  local r = tonumber(SC.cfg.radius) or 8
  local gap = tonumber(SC.cfg.scanEvery) or 8
  local limit = turtle.getFuelLimit and turtle.getFuelLimit() or 20000
  if turtle.getFuelLevel() ~= "unlimited" then
    local fueled, short = SC.refuel(math.min(limit - 800, 6000))
    if not fueled then return nil, short end
  end
  local map = SC.newMap(r)
  SC.pos, SC.facing, SC.stopped = { 0, 0, 0 }, SC.homeFacing, false
  local moves, n, walked, why = {}, 0, 0, nil
  local function where()
    return ("%d moves, at %d,%d,%d from the dock, fuel %s"):format(walked, SC.pos[1], SC.pos[2], SC.pos[3], tostring(turtle.getFuelLevel()))
  end
  local function scan()
    local blocks, err = SC.look()
    if not blocks then return false, "scanner: " .. tostring(err) end
    SC.mapAdd(map, blocks, SC.pos)
    local p = SC.pos
    if not SC.send({ op = "scan", run = run, mode = "survey", n = n, at = { p[1], p[2], p[3] }, r = r, blocks = blocks }) then
      return false, "the repair computer stopped answering"
    end
    n = n + 1
    local text = ("scan %d: %d blocks - %s"):format(n, #blocks, where())
    SC.log(text)
    SC.show("EXPLORING (survey)\n" .. text)
    return true
  end
  SC.trailStart()
  local ok, err = scan()
  if not ok then
    SC.trailDone()
    return nil, err
  end
  if not next(map.solid) then
    SC.trailDone()
    SC.log("its scan saw no blocks round it but itself - see 'first scan' and 'touching it' above")
    return nil, "its scan sees no blocks round it but itself (is it on the ship? see scout.log)"
  end
  local avoid = {}
  local maxMoves = tonumber(SC.cfg.maxMoves) or 20000
  while not SC.stopped do
    local fuel = turtle.getFuelLevel()
    if fuel ~= "unlimited" and fuel < walked + 200 then
      if not SC.refuel(walked + 600) then why = "fuel low - it explored what it could" break end
    end
    if #moves >= maxMoves then why = "the most moves allowed (maxMoves)" break end
    local path = SC.nextTarget(map, SC.pos, gap, avoid)
    if not path then break end                      -- (everywhere it can reach is scanned)
    local arrived = true
    for _, c in ipairs(path) do
      SC.alive(run, where())
      local made, moved, blocked = SC.moveTo(c)
      -- (record what really happened: the turns always, the last step only if it went)
      for i = 1, #made do
        local ch = made:sub(i, i)
        if i < #made or moved then
          moves[#moves + 1] = ch
          if ch ~= "L" and ch ~= "R" then walked = walked + 1 end
        end
      end
      if not moved then
        avoid[mapKey(c[1], c[2], c[3])] = true      -- (something in the way: round it next time)
        arrived = false
        SC.log(("could not go to %d,%d,%d (%s) - %s"):format(c[1], c[2], c[3], tostring(blocked), where()))
        break
      end
    end
    if arrived then
      moves[#moves + 1] = "S"
      ok, err = scan()
      if not ok then why = err break end
    end
  end
  if SC.stopped then why = "stopped" end
  local route = table.concat(moves)
  SC.show("EXPLORING: going home\n" .. where())
  SC.goHome(route, #route)
  for _ = 1, 4 do
    if SC.facing == SC.homeFacing then break end
    turtle.turnRight()
    SC.facing = SC.RIGHT[SC.facing]
  end
  SC.trailDone()
  if route:find("[FBUD]") then SC.saveRoute(route) end
  SC.log(("explored: %d scans, %d moves%s"):format(n, walked, why and (" - " .. why) or ""))
  return route, why
end

---------------------------------------------------------------- recording

function SC.record()
  SC.openModem()
  local allowed, why = SC.askPermit("recording its route")
  if not allowed then
    print("Not now: " .. why .. ". Try again when it is home.")
    return false
  end
  local moves = {}
  local function show()
    term.clear()
    term.setCursorPos(1, 1)
    print("SCOUT: recording the route")
    print("W/S fwd/back  A/D turn  Space up  Shift down")
    print("Backspace undo   Enter save   Q give up")
    print("")
    local walk = 0
    for _, c in ipairs(moves) do if c ~= "L" and c ~= "R" then walk = walk + 1 end end
    print(("%d moves (%d blocks), fuel %s"):format(#moves, walk, tostring(turtle.getFuelLevel())))
  end
  local KEYS = { [keys.w] = "F", [keys.s] = "B", [keys.a] = "L", [keys.d] = "R", [keys.space] = "U", [keys.leftShift] = "D" }
  show()
  while true do
    local _, k = os.pullEvent("key")
    if KEYS[k] then
      local c = KEYS[k]
      if turtle[SC.NAMES[c]]() then moves[#moves + 1] = c end
      show()
    elseif k == keys.backspace and #moves > 0 then
      if turtle[SC.NAMES[SC.OPPOSITE[moves[#moves]]]]() then moves[#moves] = nil end
      show()
    elseif k == keys.enter or k == keys.q then
      local text = table.concat(moves)
      if k == keys.enter then SC.saveRoute(text) end
      print(k == keys.enter and "Saved - driving home..." or "Not saved - driving home...")
      SC.goHome(text, #text)
      SC.hello()                                    -- (home: the permit goes back)
      return k == keys.enter
    end
  end
end

---------------------------------------------------------------- main

-- Its kit and its facing - each step written to scout.log. A missing upgrade:
-- it says so and keeps looking (fit it and it carries on)
function SC.start()
  SC.log(("started: scout %s on turtle %d"):format(SC.VERSION, os.getComputerID()))
  local told
  while true do
    SC.geo = peripheral.find("geo_scanner") or peripheral.find("geoScanner")
    local modem = SC.openModem()
    if SC.geo and modem then break end
    local missing = {}
    if not SC.geo then missing[#missing + 1] = "a Geo Scanner" end
    if not modem then missing[#missing + 1] = "an ender modem" end
    local text = "Missing " .. table.concat(missing, " and ") .. " - fit it as a turtle upgrade (it keeps looking)"
    if text ~= told then
      told = text
      print(text)
      SC.log(text)
    end
    sleep(5)
  end
  SC.log("Geo Scanner and ender modem found")
  local blocks, f, off = SC.look()
  if not blocks then SC.log("first scan failed: " .. tostring(f)) else SC.describe(blocks, off) end
  local facing = (blocks and f) or SC.cfg.facing
  if not SC.FACE[facing or ""] then
    SC.log("cannot tell which way it faces (set facing in scout.cfg)")
    error("Cannot tell which way it faces - set facing in scout.cfg (north, east, south, west)", 0)
  end
  SC.homeFacing = SC.recover(facing)
  SC.log("facing " .. SC.homeFacing)
  SC.facing = SC.homeFacing
end

-- Restarted in the middle of a run (scout.trail left): back to its dock
-- first, the way the trail says. facing: where it faces now. -> its facing
-- at the dock
function SC.recover(facing)
  local moves, home = SC.readTrail()
  if not moves or not SC.FACE[home or ""] then
    SC.trailDone()
    return facing
  end
  -- (the trail settled - written afresh, so a restart on the way home goes on from here)
  pcall(function()
    local h = fs.open(SC.FILES.trail, "w")
    h.writeLine("HOME " .. home)
    for c in moves:gmatch(".") do h.writeLine(c .. " done") end
    h.close()
  end)
  local want = home
  for c in moves:gmatch("[LR]") do want = c == "R" and SC.RIGHT[want] or SC.LEFT[want] end
  local walk = select(2, moves:gsub("[FBUD]", ""))
  SC.log(("restarted away from its dock: going back (%d moves, from scout.trail)"):format(walk))
  SC.show(("Restarted away from its dock: going back (%d moves)"):format(walk))
  SC.homeFacing, SC.facing, SC.trailing = home, facing, true
  -- (facing otherwise than the trail says: a turn that never got written, or never happened)
  for _ = 1, 4 do
    if SC.facing == want then break end
    turtle.turnRight()
    SC.facing = SC.RIGHT[SC.facing]
  end
  SC.goHome(moves, #moves)
  for _ = 1, 4 do
    if SC.facing == home then break end
    turtle.turnRight()
    SC.facing = SC.RIGHT[SC.facing]
  end
  SC.trailDone()
  SC.log("back at its dock")
  return home
end

function SC.serve()
  SC.hello()
  local heard = now()
  while true do
    term.clear()
    term.setCursorPos(1, 1)
    print(("SCOUT %s (turtle %d)"):format(SC.VERSION, os.getComputerID()))
    print(("route: %d moves, facing %s at the dock"):format(#(SC.route or ""), SC.homeFacing))
    print(("repair computer: %s"):format(SC.repairId and tostring(SC.repairId) or "not found yet"))
    print(("fuel: %s, from %s"):format(tostring(turtle.getFuelLevel()), SC.fuelSide() and ("the inventory " .. SC.fuelSide())
      or "NOTHING (put a fuel-only inventory in front, above or below)"))
    if SC.last then print("last run: " .. SC.last) end
    local id, msg = rednet.receive(SC.PROTO, 30)
    if type(msg) == "table" and msg.op == "explore" then
      SC.repairId = id
      SC.log("explore started")
      local route, why = SC.explore(msg.run)
      SC.last = "explore: " .. (why or "done")
      pcall(rednet.send, id, route and { op = "done", run = msg.run, route = route, why = why }
        or { op = "trouble", run = msg.run, text = why }, SC.PROTO)
    elseif type(msg) == "table" and (msg.op == "survey" or msg.op == "sweep" or msg.op == "look") then
      SC.repairId = id
      if msg.op == "look" then
        SC.pos = { 0, 0, 0 }
        local ok, err = SC.scanHere("look", msg.run, 0)
        if not ok then pcall(rednet.send, id, { op = "trouble", run = msg.run, text = err }, SC.PROTO) end
      else
        SC.log(msg.op .. " started")
        local why = SC.run(msg.op, msg.run)
        SC.last = msg.op .. ": " .. (why or "done")
        SC.log(SC.last)
        pcall(rednet.send, id, why and { op = "trouble", run = msg.run, text = why } or { op = "done", run = msg.run }, SC.PROTO)
      end
    elseif type(msg) == "table" and msg.op == "peek" then
      pcall(rednet.send, id, { op = "peeked", items = SC.peek() }, SC.PROTO)
    elseif type(msg) == "table" and msg.op == "welcome" then
      SC.repairId, heard = id, now()
    elseif type(msg) == "table" and msg.op == "hello?" then
      SC.repairId = id                              -- (the repair computer restarted: it asks)
      SC.hello()
      heard = now()
    end
    if now() - heard >= 30 then
      SC.hello()
      heard = now()
    end
  end
end

if ARGS[1] == "lib" then return SC end
SC.loadConfig()
SC.loadRoute()
if ARGS[1] == "record" then
  SC.openModem()
  SC.record()
  return
end
-- (any error is written to scout.log as well as the screen)
local ok, err = xpcall(function()
  SC.start()
  SC.hello()                                        -- (the repair computer knows it at once, route or not)
  SC.serve()
end, function(e) return tostring(e) .. "\n" .. (debug and debug.traceback and debug.traceback() or "") end)
if not ok then
  SC.log("STOPPED: " .. tostring(err))
  printError(tostring(err):match("^[^\n]*"))
end
