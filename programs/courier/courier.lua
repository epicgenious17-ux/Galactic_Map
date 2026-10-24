--[[
courier.lua - carries items from home to a drop-off and back           v1.0.0
A plain turtle (no tools). Keeps something stocked: the destroyer's fuel,
ammunition, anything that sits in a chest.

  courier record   drive it from home to the drop-off with the keys below;
                   Enter saves the route (courier.route) and it drives home
  courier go       one trip now
  courier          wait for the trigger (courier.cfg), make a trip, repeat

Keys while recording (in the turtle's screen): W / S forward / back, A / D
turn, Space up, Left Shift down, Backspace undo the last move, Enter done,
Q give up (it drives home).

Slot 16 is its own fuel (coal, charcoal...): never carried, never dropped.
It never digs: a player or mob in the way, it waits; still blocked after a
while, it goes home.

courier.cfg:
  pickup = "front"   where it takes from at home: front, up or down
  drop = "front"     where it puts things at the drop-off
  items = {}         what it carries: item names or parts of them (empty: anything)
  load = 64          most it carries a trip
  keep = 0           at the drop-off, fill up to this many of each (0: drop all it has)
  trigger = "redstone"  "redstone" (a signal turning on at home), "every" or "manual" (G key)
  every = 300        s between trips for "every"
]]

local ARGS = { ... }
local C = { VERSION = "1.0.0" }
C.FILES = { cfg = "/courier.cfg", route = "/courier.route", log = "/courier.log" }
C.DEFAULTS = {
  pickup = "front", drop = "front", items = {}, load = 64, keep = 0,
  trigger = "redstone", every = 300,
}
C.FUEL_SLOT = 16
C.NAMES = { F = "forward", B = "back", U = "up", D = "down", L = "turnLeft", R = "turnRight" }
C.OPPOSITE = { F = "B", B = "F", U = "D", D = "U", L = "R", R = "L" }
local SUCK = { front = "suck", up = "suckUp", down = "suckDown" }
local DROP = { front = "drop", up = "dropUp", down = "dropDown" }
local SIDE = { front = "front", up = "top", down = "bottom" }      -- (as a peripheral)

local now = os.clock

function C.log(text)
  pcall(function()
    if fs.exists(C.FILES.log) and fs.getSize(C.FILES.log) > 16384 then
      if fs.exists(C.FILES.log .. ".old") then fs.delete(C.FILES.log .. ".old") end
      fs.move(C.FILES.log, C.FILES.log .. ".old")
    end
    local h = fs.open(C.FILES.log, "a")
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

local function writeTable(path, head, t)
  local h = fs.open(path, "w")
  h.write(head .. "\n" .. textutils.serialize(t))
  h.close()
end

function C.loadConfig()
  local cfg = readTable(C.FILES.cfg)
  local fresh = cfg == nil
  cfg = cfg or {}
  for k, v in pairs(C.DEFAULTS) do
    if cfg[k] == nil then cfg[k] = v end
  end
  C.cfg = cfg
  if fresh then pcall(writeTable, C.FILES.cfg, "-- courier.cfg - settings for courier.lua " .. C.VERSION .. ". Edit, save, then reboot.", cfg) end
end

function C.loadRoute() C.route = readTable(C.FILES.route) end

function C.saveRoute(moves)
  C.route = moves
  writeTable(C.FILES.route, "-- courier.route - home to the drop-off (F B U D forward back up down, L R turns)", moves)
end

---------------------------------------------------------------- moving

-- One move; something in the way (a player, a mob): tries again for up to
-- `wait` s. -> true, or false + why
function C.step(c, wait)
  local deadline = now() + (wait or 10)
  while true do
    local ok, why = turtle[C.NAMES[c]]()
    if ok then return true end
    if now() >= deadline then return false, why end
    sleep(0.5)
  end
end

-- Moves in order. -> how many were made, why it stopped
function C.travel(moves, wait)
  for i, c in ipairs(moves) do
    local ok, why = C.step(c, wait)
    if not ok then return i - 1, why end
  end
  return #moves
end

-- The way back from after the first n moves: undone last first, backwards
-- (no turning round, so it ends facing as it started)
function C.reverse(moves, n)
  local out = {}
  for i = n or #moves, 1, -1 do out[#out + 1] = C.OPPOSITE[moves[i]] end
  return out
end

-- Home from after the first n moves of the route. It keeps trying - the
-- route is the only way it knows
function C.goHome(moves, n)
  local back = C.reverse(moves, n)
  local i, told = 1, nil
  while i <= #back do
    local ok, why = C.step(back[i], 5)
    if ok then
      i = i + 1
    elseif not told or now() - told > 60 then
      told = now()
      C.state = "STUCK"
      C.log(("stuck on the way home (%s) - still trying"):format(tostring(why)))
      pcall(C.draw)
    end
  end
end

function C.distance(moves)
  local n = 0
  for _, c in ipairs(moves) do if c ~= "L" and c ~= "R" then n = n + 1 end end
  return n
end

-- Enough fuel for `need` moves, from slot 16 if short
function C.fuelOk(need)
  local level = turtle.getFuelLevel()
  if level == "unlimited" or level >= need then return true end
  if turtle.getItemCount(C.FUEL_SLOT) > 0 then
    turtle.select(C.FUEL_SLOT)
    while turtle.getFuelLevel() < need and turtle.getItemCount(C.FUEL_SLOT) > 0 and turtle.refuel(1) do end
    turtle.select(1)
  end
  return turtle.getFuelLevel() >= need
end

---------------------------------------------------------------- loading

function C.allowed(name)
  local list = C.cfg.items
  if type(list) ~= "table" or #list == 0 then return true end
  for _, n in ipairs(list) do
    if name == n or name:find(n, 1, true) then return true end
  end
  return false
end

-- How many items it carries (slots 1-15)
function C.carried()
  local n = 0
  for slot = 1, 15 do n = n + turtle.getItemCount(slot) end
  return n
end

local function firstFull(list)
  local k
  for slot in pairs(list) do if not k or slot < k then k = slot end end
  return k
end

-- A turtle takes the first stack in an inventory: make that one it carries
-- (the inventory's own pushItems to itself - leave a free slot at the end)
function C.frontAllowed(inv, name)
  for _ = 1, 32 do
    local list = inv.list()
    local k = firstFull(list)
    if not k then return false, "nothing there" end
    if C.allowed(list[k].name) then return true end
    local s
    for slot, it in pairs(list) do
      if C.allowed(it.name) and (not s or slot < s) then s = slot end
    end
    if not s then return false, "nothing it carries there" end
    if k > 1 then
      inv.pushItems(name, s, nil, 1)            -- (the slots before k are empty)
      return true
    end
    local e
    for i = inv.size(), s + 1, -1 do
      if not list[i] then e = i break end
    end
    if not e then return false, "the pickup is full - leave a free slot at its end" end
    inv.pushItems(name, k, nil, e)              -- (the stack in the way to the back)
  end
  return false, "could not sort the pickup"
end

-- Takes up to cfg.load at home. -> how many
function C.load()
  local side = C.cfg.pickup
  local inv = peripheral.wrap(SIDE[side])
  local before = C.carried()
  turtle.select(1)
  for _ = 1, 15 do
    local want = (tonumber(C.cfg.load) or 64) - C.carried()
    if want <= 0 then break end
    if inv and inv.list then
      local ok, why = C.frontAllowed(inv, SIDE[side])
      if not ok then
        C.why = why
        break
      end
    end
    if not turtle[SUCK[side]](math.min(want, 64)) then break end
  end
  -- (anything it should not carry - an unsorted pickup - goes back)
  for slot = 1, 15 do
    local d = turtle.getItemDetail(slot)
    if d and not C.allowed(d.name) then
      turtle.select(slot)
      turtle[DROP[side]]()
    end
  end
  turtle.select(1)
  return C.carried() - before
end

-- At the drop-off: everything, or each kind up to cfg.keep. -> how many dropped
function C.unload()
  local side = C.cfg.drop
  local keep = tonumber(C.cfg.keep) or 0
  local inv = peripheral.wrap(SIDE[side])
  local has = {}
  if keep > 0 and inv and inv.list then
    for _, it in pairs(inv.list()) do has[it.name] = (has[it.name] or 0) + it.count end
  end
  local dropped = 0
  for slot = 1, 15 do
    local d = turtle.getItemDetail(slot)
    if d then
      local n = d.count
      if keep > 0 then n = math.max(0, math.min(n, keep - (has[d.name] or 0))) end
      if n > 0 then
        turtle.select(slot)
        turtle[DROP[side]](n)
        local moved = d.count - turtle.getItemCount(slot)
        has[d.name] = (has[d.name] or 0) + moved
        dropped = dropped + moved
      end
    end
  end
  turtle.select(1)
  return dropped
end

-- Back home: what is left goes back where it came from
function C.putBack()
  local side = C.cfg.pickup
  for slot = 1, 15 do
    if turtle.getItemCount(slot) > 0 then
      turtle.select(slot)
      turtle[DROP[side]]()
    end
  end
  turtle.select(1)
end

---------------------------------------------------------------- a trip

-- -> true + what it did, or false + why
function C.trip()
  local route = C.route
  if type(route) ~= "table" or #route == 0 then return false, "no route yet - courier record" end
  if not C.fuelOk(2 * C.distance(route) + 2) then return false, "needs fuel in slot 16" end
  C.state, C.why = "loading", nil
  C.load()
  if C.carried() == 0 then
    C.state = "home"
    return false, "nothing to carry at home" .. (C.why and (" (" .. C.why .. ")") or "")
  end
  C.state = "out"
  pcall(C.draw)
  local done, why = C.travel(route, 20)
  if done < #route then
    C.log(("blocked on the way (%s) after %d of %d moves - going home"):format(tostring(why), done, #route))
    C.state = "home"
    C.goHome(route, done)
    C.putBack()
    C.state = "home"
    return false, "blocked on the way"
  end
  C.state = "unloading"
  local dropped = C.unload()
  C.state = "back"
  pcall(C.draw)
  C.goHome(route, #route)
  C.putBack()
  C.state = "home"
  C.trips = (C.trips or 0) + 1
  return true, ("delivered %d"):format(dropped)
end

---------------------------------------------------------------- recording

C.KEYS = nil
function C.record()
  C.KEYS = C.KEYS or { [keys.w] = "F", [keys.s] = "B", [keys.a] = "L", [keys.d] = "R",
    [keys.space] = "U", [keys.leftShift] = "D" }
  term.clear()
  term.setCursorPos(1, 1)
  print("COURIER: recording the route")
  print("W/S forward/back  A/D turn")
  print("Space up  Left Shift down")
  print("Backspace undo  Enter done  Q give up")
  local moves = {}
  while true do
    local _, k = os.pullEvent("key")
    local c = C.KEYS[k]
    if c then
      if C.step(c, 0) then
        moves[#moves + 1] = c
        print(("%d moves (%s)"):format(#moves, C.NAMES[c]))
      else
        print("blocked")
      end
    elseif k == keys.backspace and #moves > 0 then
      if C.step(C.OPPOSITE[moves[#moves]], 2) then
        moves[#moves] = nil
        print(("%d moves (undone)"):format(#moves))
      end
    elseif k == keys.enter then
      C.saveRoute(moves)
      C.log(("route saved: %d moves, %d blocks"):format(#moves, C.distance(moves)))
      print("Saved. Going home...")
      C.goHome(moves, #moves)
      print("Home. Type courier to start.")
      return true
    elseif k == keys.q then
      print("Not saved. Going home...")
      C.goHome(moves, #moves)
      return false
    end
  end
end

---------------------------------------------------------------- the screen

function C.draw()
  term.clear()
  term.setCursorPos(1, 1)
  print(("COURIER %s (turtle %d)"):format(C.VERSION, os.getComputerID()))
  local route = C.route
  print(("route: %s"):format(type(route) == "table" and #route > 0 and (C.distance(route) .. " blocks") or "NONE - courier record"))
  print(("trigger: %s%s"):format(C.cfg.trigger, C.cfg.trigger == "every" and (" " .. C.cfg.every .. " s") or ""))
  print(("state: %s   trips: %d"):format(C.state or "home", C.trips or 0))
  print(("fuel: %s"):format(tostring(turtle.getFuelLevel())))
  if C.last then print("last: " .. C.last) end
  print("")
  print("G: a trip now   Ctrl+T: stop")
end

local function anyInput()
  for _, s in ipairs(rs.getSides()) do
    if rs.getInput(s) then return true end
  end
  return false
end

function C.run()
  local function go()
    local ok, msg = C.trip()
    C.last = (ok and "" or "NO: ") .. tostring(msg)
    C.log(C.last)
  end
  local was = anyInput()
  local timer = C.cfg.trigger == "every" and os.startTimer(tonumber(C.cfg.every) or 300)
  while true do
    C.draw()
    local e, a = os.pullEvent()
    if e == "key" and a == keys.g then
      go()
    elseif e == "redstone" and C.cfg.trigger == "redstone" then
      local on = anyInput()
      if on and not was then go() end
      was = anyInput()
    elseif e == "timer" and a == timer then
      go()
      timer = os.startTimer(tonumber(C.cfg.every) or 300)
    end
  end
end

if ARGS[1] == "lib" then return C end

C.loadConfig()
C.loadRoute()
if ARGS[1] == "record" then
  C.record()
elseif ARGS[1] == "go" then
  local ok, msg = C.trip()
  print((ok and "" or "NO: ") .. tostring(msg))
else
  C.state = "home"
  C.run()
end
