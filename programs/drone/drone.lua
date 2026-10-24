--[[
drone.lua - a repair drone: puts back broken blocks                     v1.0.1
A turtle with a Weak Automata Core and a Compass (Advanced Peripherals) -
with the Compass the core places a block exactly (its facing, half, axis)
up to 3 blocks away. That fills both upgrade slots, so it has no modem of
its own: at its dock a full wired modem block touches it (any side but the
front), cabled to the repair computer, and its pickup chest stands in
front of it, on the same cables (a wired modem on the chest, switched on).
The repair computer finds which chest that is by itself (a test item in
each); drone.cfg pickup only if that ever picks wrong.

  drone        wait at the dock for jobs (put this in startup)

The repair computer (repair.lua) finds which dock it is (it turns the drone
while the scout looks), puts the parts in its pickup chest and sends a job:
the cells to fly and the blocks to place. The drone takes everything from
the chest, flies, places, flies back the way it came, puts what is left in
the chest and reports. It never digs, never places into an occupied cell
and moves only on a job (the repair computer's one permit: one turtle out
at a time). Something in the way: it waits `wait` s, then gives up and
comes home; another turtle in the way: it turns back at once. Fuel (coal
blocks, coal, charcoal): the repair computer puts some in its chest when
it runs low.

drone.cfg:
  pickup = ""          the pickup chest's peripheral name, e.g. "minecraft:chest_4"
                       ("" = the repair computer finds it)
  pickupSide = "front" where that chest is: front, up or down
  wait = 20            s to wait for something in the way
]]

local ARGS = { ... }
local D = { VERSION = "1.0.1" }
D.PROTO, D.HOST = "destroyer.repair", "repair"
D.FILES = { cfg = "/drone.cfg", log = "/drone.log" }
D.DEFAULTS = { pickup = "", pickupSide = "front", wait = 20 }
D.FACE = { north = { 0, 0, -1 }, east = { 1, 0, 0 }, south = { 0, 0, 1 }, west = { -1, 0, 0 } }
D.RIGHT = { north = "east", east = "south", south = "west", west = "north" }
D.LEFT = { north = "west", west = "south", south = "east", east = "north" }
local SUCK = { front = "suck", up = "suckUp", down = "suckDown" }
local DROP = { front = "drop", up = "dropUp", down = "dropDown" }

local now = os.clock

function D.log(text)
  pcall(function()
    if fs.exists(D.FILES.log) and fs.getSize(D.FILES.log) > 16384 then
      if fs.exists(D.FILES.log .. ".old") then fs.delete(D.FILES.log .. ".old") end
      fs.move(D.FILES.log, D.FILES.log .. ".old")
    end
    local h = fs.open(D.FILES.log, "a")
    h.writeLine(("%8.1f %s"):format(now(), tostring(text)))
    h.close()
  end)
end

function D.loadConfig()
  local cfg
  if fs.exists(D.FILES.cfg) then
    local h = fs.open(D.FILES.cfg, "r")
    cfg = textutils.unserialize(h.readAll())
    h.close()
  end
  local fresh = type(cfg) ~= "table"
  cfg = fresh and {} or cfg
  for k, v in pairs(D.DEFAULTS) do
    if cfg[k] == nil then cfg[k] = v end
  end
  D.cfg = cfg
  if fresh then
    pcall(function()
      local h = fs.open(D.FILES.cfg, "w")
      h.write("-- drone.cfg - settings for drone.lua " .. D.VERSION .. " (see its header). Edit, save, reboot.\n" .. textutils.serialize(cfg))
      h.close()
    end)
  end
end

---------------------------------------------------------------- moving

D.pos, D.facing, D.trail = { 0, 0, 0 }, "north", {}

function D.turnTo(f)
  if D.facing == f or not D.FACE[f] then return end
  if D.RIGHT[D.facing] == f then
    turtle.turnRight()
  elseif D.LEFT[D.facing] == f then
    turtle.turnLeft()
  else
    turtle.turnRight()
    turtle.turnRight()
  end
  D.facing = f
end

-- (another turtle where a move would go? - it cannot look behind itself)
local LOOK = { forward = "inspect", up = "inspectUp", down = "inspectDown" }
local function turtleThere(fn)
  local look = LOOK[fn]
  if not look or not turtle[look] then return false end
  local ok, info = turtle[look]()
  return ok and type(info) == "table" and tostring(info.name):find("computercraft:turtle", 1, true) ~= nil
end

-- A move; something in the way: tries again for up to wait s - another
-- turtle: gives up at once (it never pushes on into one). -> true, or false + why
local function try(fn, wait)
  local deadline = now() + (wait or 10)
  while true do
    if turtle[fn]() then return true end
    if turtleThere(fn) then return false, "another turtle in the way" end
    if now() >= deadline then return false, "something in the way" end
    sleep(0.5)
  end
end

-- To a cell next to it (copy frame); the trail remembers the way back
function D.stepTo(c, wait, back)
  local p = D.pos
  local dx, dy, dz = c[1] - p[1], c[2] - p[2], c[3] - p[3]
  if math.abs(dx) + math.abs(dy) + math.abs(dz) ~= 1 then return false, "not next to it" end
  local ok, why
  if dy ~= 0 then
    ok, why = try(dy > 0 and "up" or "down", wait)
  else
    local v = D.FACE[D.facing]
    if dx == -v[1] and dz == -v[3] and not back then
      ok, why = try("back", wait)                           -- (behind it: backs up, no turning)
    else
      for f, w in pairs(D.FACE) do
        if w[1] == dx and w[3] == dz then D.turnTo(f) end
      end
      ok, why = try("forward", wait)                        -- (going home it faces the way it goes: it can see a turtle there)
    end
  end
  if ok then
    D.pos = { c[1], c[2], c[3] }
    if not back then D.trail[#D.trail + 1] = { c[1], c[2], c[3] } end
  end
  return ok, why
end

-- Step aside (up, down, left, right - anywhere free but the way ahead and
-- back) to let another turtle by. -> the cell it left, or nil
function D.sidestep(ahead, behind)
  local here = { D.pos[1], D.pos[2], D.pos[3] }
  local tries = { { here[1], here[2] + 1, here[3] }, { here[1], here[2] - 1, here[3] } }
  for _, f in ipairs({ D.LEFT[D.facing], D.RIGHT[D.facing] }) do
    local v = D.FACE[f]
    tries[#tries + 1] = { here[1] + v[1], here[2], here[3] + v[3] }
  end
  local function same(a, b) return b and a[1] == b[1] and a[2] == b[2] and a[3] == b[3] end
  for _, c in ipairs(tries) do
    if not same(c, ahead) and not same(c, behind) and D.stepTo(c, 0.5, true) then return here end
  end
end

-- Back to the dock the way it came. It keeps trying. Another turtle in the
-- way: it waits (longer the higher its id - two that meet never both give
-- way at once), then steps aside to let it by, and goes on
function D.goBack()
  for i = #D.trail - 1, 1, -1 do
    local told, met = nil, 0
    while true do
      local ok, why = D.stepTo(D.trail[i], 30, true)
      if ok then break end
      if not told then
        told = true
        D.log(("going home at %d %d %d: %s - still trying"):format(D.pos[1], D.pos[2], D.pos[3], tostring(why)))
      end
      if why == "another turtle in the way" then
        met = met + 1
        sleep(2 + (os.getComputerID() % 5) * 2)
        local from = D.sidestep(D.trail[i], D.trail[i + 2])        -- (not ahead, not where it just was)
        if from then
          sleep(6)
          while not D.stepTo(from, 30, true) do sleep(2) end      -- (back onto its way)
        end
      else
        sleep(2)
      end
    end
  end
  D.trail = { D.trail[1] }
end

---------------------------------------------------------------- items

function D.findItem(name)
  for slot = 1, 16 do
    local d = turtle.getItemDetail(slot)
    if d and d.name == name then return slot end
  end
end

-- (the job's fuel list as a set)
local function fuelSet(fuels)
  local s = {}
  for _, f in ipairs(type(fuels) == "table" and fuels or { fuels }) do s[f] = true end
  return s
end

function D.refuel(need, fuels)
  if turtle.getFuelLevel() == "unlimited" then return true end
  local burnable = fuelSet(fuels)
  for slot = 1, 16 do
    if turtle.getFuelLevel() >= need then break end
    local d = turtle.getItemDetail(slot)
    if d and burnable[d.name] then
      turtle.select(slot)
      while turtle.getFuelLevel() < need and turtle.refuel(1) do end
    end
  end
  turtle.select(1)
  return turtle.getFuelLevel() >= need
end

-- Its parts from its chest: the first `stacks` stacks (the repair computer put
-- them there, in front of anything else the chest holds) - no count: all
function D.load(stacks)
  local suck = SUCK[D.cfg.pickupSide] or "suck"
  turtle.select(1)
  for _ = 1, stacks or 32 do
    if not turtle[suck]() then break end
  end
end

-- What the pickup chest holds: { [item] = count } (nil: no chest there) -
-- the repair computer finds which chest it is by putting a test item in each
function D.peek()
  local ok, list = pcall(peripheral.call, D.cfg.pickupSide or "front", "list")
  if not ok or type(list) ~= "table" then return nil end
  local out = {}
  for _, it in pairs(list) do
    if type(it) == "table" and it.name then out[it.name] = (out[it.name] or 0) + (it.count or 0) end
  end
  return out
end

-- What is left (not fuel) back into the pickup chest
function D.unload(fuels)
  local drop = DROP[D.cfg.pickupSide] or "drop"
  local keep = fuelSet(fuels)
  for slot = 1, 16 do
    local d = turtle.getItemDetail(slot)
    if d and not keep[d.name] then
      turtle.select(slot)
      turtle[drop]()
    end
  end
  turtle.select(1)
end

---------------------------------------------------------------- placing

-- One block, as the job says: the item, where (off: from the drone, the
-- ship's grid) and how (front / top / anchor). A double slab gets its
-- second half from right above. -> true, or false + why
function D.place(st)
  local slot = D.findItem(st.item)
  if not slot then return false, "no " .. tostring(st.item) end
  turtle.select(slot)
  local a = type(st.args) == "table" and st.args or {}
  local args = { x = st.off[1], y = st.off[2], z = st.off[3], front = a.front, top = a.top, anchor = a.anchor }
  local ok, err
  for _ = 1, 20 do
    ok, err = D.core.placeBlock(args)
    if ok or not tostring(err):lower():find("cooldown") then break end
    sleep(0.25)
  end
  if not ok then return false, tostring(err) end
  if st.double then
    local s2 = D.findItem(st.item)
    if s2 then
      turtle.select(s2)
      turtle.placeDown()
    end
  end
  return true
end

---------------------------------------------------------------- a job

-- { at, facing, steps = { { "go", cells = { { x, y, z }, ... } }, { "place", k, off, item, args, double }, ... }, fuel }
-- -> { done = { keys }, failed = { { key, why } }, why }
function D.runJob(job)
  D.pos = { job.at[1], job.at[2], job.at[3] }
  D.facing = job.facing
  D.trail = { { job.at[1], job.at[2], job.at[3] } }
  local cells = 0
  for _, st in ipairs(job.steps) do if st[1] == "go" then cells = cells + #st.cells end end
  local done, failed, why = {}, {}, nil
  local fuels = job.fuels or job.fuel
  if not D.refuel(2 * cells + 20, fuels) then
    why = ("needs fuel: %d for the trip, has %s"):format(2 * cells + 20, tostring(turtle.getFuelLevel()))
  end
  for si, st in ipairs(job.steps) do
    if why then
      for j = si, #job.steps do
        if job.steps[j][1] == "place" then failed[#failed + 1] = { job.steps[j].k, "not reached" } end
      end
      break
    end
    if st[1] == "go" then
      for _, c in ipairs(st.cells) do
        local ok, blocked = D.stepTo(c, tonumber(D.cfg.wait) or 20)
        if not ok then
          why = ("%s at %d %d %d"):format(tostring(blocked), c[1], c[2], c[3])
          break
        end
      end
    elseif st[1] == "place" then
      local ok, err = D.place(st)
      if ok then done[#done + 1] = st.k else failed[#failed + 1] = { st.k, err } end
    end
  end
  D.goBack()
  D.turnTo(job.facing)
  D.unload(fuels)
  return { done = done, failed = failed, why = why }
end

---------------------------------------------------------------- talking

function D.openModem()
  for _, side in ipairs({ "bottom", "top", "back", "left", "right", "front" }) do
    if peripheral.hasType(side, "modem") then
      pcall(rednet.open, side)
      return side
    end
  end
end

function D.hello()
  if not D.repairId then
    local ok, id = pcall(rednet.lookup, D.PROTO, D.HOST)
    if ok and id then D.repairId = id end
  end
  if not D.repairId then return false end
  pcall(rednet.send, D.repairId, { op = "hello", role = "drone", pickup = D.cfg.pickup, fuel = turtle.getFuelLevel(),
    version = D.VERSION }, D.PROTO)
  return true
end

function D.start()
  D.core = peripheral.find("weak_automata") or peripheral.find("weakAutomata")
  if not D.core then error("No Weak Automata Core on this turtle (Advanced Peripherals turtle upgrade)", 0) end
  if not peripheral.find("compass") then error("No Compass on this turtle - the core cannot place blocks exactly without it", 0) end
  if not D.openModem() then error("No modem touching it - put a full wired modem block (cabled to the repair computer) next to its dock", 0) end
  if not D.peek() then print("No chest " .. (D.cfg.pickupSide or "front") .. " of it - its pickup chest goes there") end
end

function D.serve()
  D.hello()
  local heard = now()
  while true do
    term.clear()
    term.setCursorPos(1, 1)
    print(("DRONE %s (turtle %d)"):format(D.VERSION, os.getComputerID()))
    print(("repair computer: %s"):format(D.repairId and tostring(D.repairId) or "not found yet"))
    print(("pickup chest: %s"):format(D.cfg.pickup ~= "" and D.cfg.pickup or (D.peek() and "in front (the repair computer finds its name)" or "NONE IN FRONT")))
    print(("fuel: %s"):format(tostring(turtle.getFuelLevel())))
    if D.last then print("last job: " .. D.last) end
    local id, msg = rednet.receive(D.PROTO, 10)
    if type(msg) == "table" then
      if msg.op == "welcome" then
        D.repairId, heard = id, now()
      elseif msg.op == "hello?" then
        D.repairId = id                             -- (the repair computer restarted: it asks)
        D.hello()
        heard = now()
      elseif msg.op == "turn" then
        if msg.way == "left" then turtle.turnLeft() else turtle.turnRight() end
        pcall(rednet.send, id, { op = "turned" }, D.PROTO)
      elseif msg.op == "peek" then
        pcall(rednet.send, id, { op = "peeked", items = D.peek() }, D.PROTO)
      elseif msg.op == "job" and type(msg.steps) == "table" and type(msg.at) == "table" then
        D.repairId = id
        D.load(msg.load)                            -- (its parts, then "going": the repair computer may load the next drone)
        pcall(rednet.send, id, { op = "going", id = msg.id }, D.PROTO)
        D.log(("job %s: %d steps"):format(tostring(msg.id), #msg.steps))
        local rep = D.runJob(msg)
        D.openModem()
        rep.op, rep.id, rep.fuel = "report", msg.id, turtle.getFuelLevel()
        D.last = ("%d placed, %d failed%s"):format(#rep.done, #rep.failed, rep.why and (" - " .. rep.why) or "")
        D.log(D.last)
        pcall(rednet.send, id, rep, D.PROTO)
      end
    end
    if now() - heard >= 10 then
      D.hello()
      heard = now()
    end
  end
end

if ARGS[1] == "lib" then return D end
D.loadConfig()
D.start()
D.serve()
