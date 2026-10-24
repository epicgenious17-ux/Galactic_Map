--[[
shipcheck.lua - what a turtle can do on the destroyer (a Sable ship)    v1.0.1
A one-off probe. Place the turtle on the ship, run it, then read
shipcheck.txt (in singleplayer: saves\<world>\computercraft\computer\<id>\
on the PC). Every run adds its findings to the end of that file.

  shipcheck            parked: kit, fuel, blocks round it, a ship GPS fix,
                       a move test (forward/back, up/down where free), a
                       Geo Scanner look, what every peripheral can do
  shipcheck moving     the same quick look, then for `duration` s (60) a GPS
                       fix every `fixEvery` s and a forward/back step every
                       `moveEvery` s - fly the ship meanwhile
  shipcheck reach      put another ship's block right in front: can the
                       turtle see it? (`shipcheck reach dig` then asks Y/N
                       before trying to dig that one block)
  shipcheck warp save  End Automata fitted: save a warp point here
  shipcheck warp go    later (after a step off it and the ship flying a
                       while): how far the point is, then warp to it - does
                       the point move with the ship? Do it low over ground:
                       if the point stayed in the world the turtle ends up
                       hanging where the ship was

Needs: shipgps.lua (from Documents\destroyer) next to it and a wireless or
ender modem for the ship GPS fix (hosts 23-26). It never digs except the
one block `reach dig` asks about, and only moves into free space.

shipcheck.cfg:
  rounds = 5         GPS pings averaged per fix
  duration = 60      seconds of the moving test
  fixEvery = 2       seconds between GPS fixes while moving
  moveEvery = 10     seconds between forward/back steps while moving
  scanRadius = 8     Geo Scanner radius (8 is free)
]]

local ARGS = { ... }
local K = { VERSION = "1.0.1" }
K.FILES = { cfg = "/shipcheck.cfg", out = "/shipcheck.txt", log = "/shipcheck.log", gps = "/shipgps.lua" }
K.DEFAULTS = { rounds = 5, duration = 60, fixEvery = 2, moveEvery = 10, scanRadius = 8 }
K.POINT = "shipcheck"

local now = os.clock

function K.log(text)
  pcall(function()
    if fs.exists(K.FILES.log) and fs.getSize(K.FILES.log) > 16384 then
      if fs.exists(K.FILES.log .. ".old") then fs.delete(K.FILES.log .. ".old") end
      fs.move(K.FILES.log, K.FILES.log .. ".old")
    end
    local h = fs.open(K.FILES.log, "a")
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

function K.loadConfig()
  local cfg = readTable(K.FILES.cfg)
  local fresh = cfg == nil
  cfg = cfg or {}
  for k, v in pairs(K.DEFAULTS) do
    if cfg[k] == nil then cfg[k] = v end
  end
  K.cfg = cfg
  if fresh then
    pcall(function()
      local h = fs.open(K.FILES.cfg, "w")
      h.write("-- shipcheck.cfg - settings for shipcheck.lua " .. K.VERSION .. " (see its header). Edit, save, run again.\n"
        .. textutils.serialize(cfg))
      h.close()
    end)
  end
end

---------------------------------------------------------------- the report

-- Lines go on the screen and into the report (written at the end of a run,
-- and as it goes, so a stopped run still leaves what it found)
K.lines = {}
function K.say(text)
  text = tostring(text)
  K.lines[#K.lines + 1] = text
  print(text)
end

function K.save()
  if #K.lines == 0 then return end
  pcall(function()
    local h = fs.open(K.FILES.out, "a")
    for _, l in ipairs(K.lines) do h.writeLine(l) end
    h.close()
  end)
  K.lines = {}
end

---------------------------------------------------------------- what it has

function K.kit()
  local out = {}
  for _, side in ipairs({ "left", "right" }) do
    local ok, ty = pcall(peripheral.getType, side)
    out[side] = ok and ty or nil
  end
  return out
end

-- Every peripheral it can reach (its upgrades, anything touching it) and its
-- methods - the mods' own names, so later programs call the right ones
function K.methods()
  local out = {}
  local names = peripheral.getNames and peripheral.getNames() or {}
  table.sort(names)
  for _, n in ipairs(names) do
    local okt, ty = pcall(peripheral.getType, n)
    local okm, ms = pcall(peripheral.getMethods, n)
    if okm and type(ms) == "table" then table.sort(ms) end
    out[#out + 1] = { name = n, type = okt and ty or "?", methods = okm and type(ms) == "table" and ms or {} }
  end
  return out
end

function K.findType(ty)
  for _, n in ipairs(peripheral.getNames and peripheral.getNames() or {}) do
    local ok, t = pcall(peripheral.getType, n)
    if ok and t == ty then return peripheral.wrap(n), n end
  end
end

-- The three blocks next to it: { front = name or false, up = ..., down = ... }
function K.around()
  local out = {}
  for side, fn in pairs({ front = "inspect", up = "inspectUp", down = "inspectDown" }) do
    local ok, d = turtle[fn]()
    out[side] = ok and type(d) == "table" and tostring(d.name) or false
  end
  return out
end

---------------------------------------------------------------- positions

-- The ship GPS (shipgps.lua) and a modem for it; nil + why if not
function K.gpsSetup()
  if K.G == nil then
    local ok, G = pcall(dofile, K.FILES.gps)
    K.G = ok and type(G) == "table" and G or false
  end
  if not K.G then
    K.gpsWhy = "no shipgps.lua next to shipcheck (copy it from Documents\\destroyer)"
    return nil
  end
  if K.modem == nil then
    K.modem = peripheral.find("modem", function(_, m) return m.isWireless and m.isWireless() end) or false
  end
  if not K.modem then
    K.gpsWhy = "no wireless or ender modem on the turtle"
    return nil
  end
  return true
end

-- One ship GPS fix: { r, u, f, err, hosts } or nil, why
function K.fix()
  if not K.gpsSetup() then return nil, K.gpsWhy end
  local ok, p, err, n = pcall(K.G.locate, K.modem, 1, K.cfg.rounds)
  if not ok then return nil, tostring(p) end
  if not p then return nil, tostring(err) end
  return { r = p[1], u = p[2], f = p[3], err = err, hosts = n }
end

local function fixText(p, why)
  if not p then return "NO FIX (" .. tostring(why) .. ")" end
  return ("r %.2f u %.2f f %.2f (error %.2f, %d hosts)"):format(p.r, p.u, p.f, p.err or 0, p.hosts or 0)
end

-- Which way a move went in the ship's frame: the biggest of the GPS change
function K.direction(a, b)
  if not (a and b) then return nil end
  local d = { r = b.r - a.r, u = b.u - a.u, f = b.f - a.f }
  local best, size = nil, 0
  for k, v in pairs(d) do
    if math.abs(v) > size then best, size = k, math.abs(v) end
  end
  if size < 0.4 then return nil, d end
  local names = { r = { "right (starboard)", "left (port)" }, u = { "up", "down" }, f = { "forward (to the bow)", "back (to the stern)" } }
  return (d[best] > 0 and "+" or "-") .. best .. " = " .. names[best][d[best] > 0 and 1 or 2], d
end

---------------------------------------------------------------- moves

-- A step and its way back, only into free space. -> "ok" / "blocked: ..." /
-- "not tried: ..." , and the GPS fixes before and after the first step
K.PAIRS = {
  { "forward", "back", "inspect" },
  { "up", "down", "inspectUp" },
}
function K.stepTest(pair, withFix)
  local go, back, look = pair[1], pair[2], pair[3]
  local filled, what = turtle[look]()
  if filled then return ("not tried: %s is there"):format(type(what) == "table" and tostring(what.name) or "a block") end
  if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < 2 then return "not tried: no fuel (put coal in, then refuel)" end
  local before = withFix and K.fix() or nil
  local ok, why = turtle[go]()
  if not ok then return "blocked: " .. tostring(why) end
  local after = withFix and K.fix() or nil
  local okb, whyb = turtle[back]()
  if not okb then
    -- (it never stays off its spot: keep trying for a while)
    local deadline = now() + 20
    while not okb and now() < deadline do
      sleep(0.5)
      okb, whyb = turtle[back]()
    end
    if not okb then return ("moved %s but CANNOT GET BACK (%s)"):format(go, tostring(whyb)), before, after end
  end
  return "ok", before, after
end

---------------------------------------------------------------- the runs

function K.header(what)
  K.say("")
  K.say(("==== shipcheck %s: %s - turtle %d, clock %.1f, day %s ===="):format(K.VERSION, what, os.getComputerID(), now(),
    tostring(os.day and os.day() or "?")))
end

function K.parked()
  local kit = K.kit()
  K.say(("kit: left %s, right %s"):format(tostring(kit.left or "nothing"), tostring(kit.right or "nothing")))
  K.say(("fuel: %s"):format(tostring(turtle.getFuelLevel())))
  local ar = K.around()
  K.say(("blocks: front %s, up %s, down %s"):format(tostring(ar.front or "air"), tostring(ar.up or "air"), tostring(ar.down or "air")))
  -- positions
  local p, why = K.fix()
  K.say("ship GPS: " .. fixText(p, why))
  local okw, wx, wy, wz = pcall(gps.locate, 2)
  K.say("world GPS (expected to fail, no world hosts): " .. (okw and wx and ("%.1f %.1f %.1f"):format(wx, wy, wz) or "no fix"))
  -- moves
  local answers = { moved = false, fix = p ~= nil }
  for _, pair in ipairs(K.PAIRS) do
    local res, before, after = K.stepTest(pair, true)
    local line = ("move %s/%s: %s"):format(pair[1], pair[2], res)
    if res == "ok" then
      answers.moved = true
      local dir, d = K.direction(before, after)
      if dir then
        line = line .. " - " .. pair[1] .. " is " .. dir
      elseif d then
        line = line .. (" - GPS change r %.2f u %.2f f %.2f (too small to tell the way)"):format(d.r, d.u, d.f)
      end
    end
    K.say(line)
  end
  -- the Geo Scanner
  local geo = K.findType("geoScanner")
  if geo then
    -- (Advanced Peripherals 0.8.2a calls it scanBlocks - older ones scan)
    local ok, list = pcall(geo.scanBlocks or geo.scan, K.cfg.scanRadius)
    if ok and type(list) == "table" then
      local names, samples = {}, {}
      for _, b in ipairs(list) do names[tostring(b.name)] = (names[tostring(b.name)] or 0) + 1 end
      for i = 1, math.min(5, #list) do
        local b = list[i]
        samples[#samples + 1] = ("%s at %s %s %s"):format(tostring(b.name), tostring(b.x), tostring(b.y), tostring(b.z))
      end
      local kinds = 0
      for _ in pairs(names) do kinds = kinds + 1 end
      K.say(("geo scan r%d: %d blocks, %d kinds; e.g. %s"):format(K.cfg.scanRadius, #list, kinds, table.concat(samples, "; ")))
      answers.scan = #list > 0
    else
      K.say("geo scan: FAILED (" .. tostring(list) .. ")")
      answers.scan = false
    end
  else
    K.say("geo scan: no Geo Scanner fitted")
  end
  -- every peripheral's methods
  for _, m in ipairs(K.methods()) do
    K.say(("peripheral %s (%s): %s"):format(m.name, tostring(m.type), table.concat(m.methods, " ")))
  end
  return answers
end

function K.moving()
  local d, fe, me = tonumber(K.cfg.duration) or 60, tonumber(K.cfg.fixEvery) or 2, tonumber(K.cfg.moveEvery) or 10
  K.say(("moving test: %d s - fly the ship now"):format(d))
  K.save()
  local t0 = now()
  local nextFix, nextMove = t0, t0 + me
  local fixes, moves, okMoves = {}, 0, 0
  while now() - t0 < d do
    if now() >= nextFix then
      nextFix = nextFix + fe
      local p, why = K.fix()
      if p then fixes[#fixes + 1] = p end
      K.say(("%6.1f s  fix %s"):format(now() - t0, fixText(p, why)))
    end
    if now() >= nextMove then
      nextMove = nextMove + me
      local res = K.stepTest(K.PAIRS[1], false)
      if res:sub(1, 9) ~= "not tried" then moves = moves + 1 end
      if res == "ok" then okMoves = okMoves + 1 end
      K.say(("%6.1f s  forward/back: %s"):format(now() - t0, res))
    end
    K.save()
    sleep(0.1)
  end
  -- steadiness: the spread of the fixes (the turtle did not move between them)
  local lo, hi = {}, {}
  for _, p in ipairs(fixes) do
    for _, k in ipairs({ "r", "u", "f" }) do
      lo[k] = math.min(lo[k] or p[k], p[k])
      hi[k] = math.max(hi[k] or p[k], p[k])
    end
  end
  local spread = #fixes > 0 and math.max(hi.r - lo.r, hi.u - lo.u, hi.f - lo.f) or nil
  K.say(("moving test done: %d fixes%s; steps %d of %d ok"):format(#fixes,
    spread and (", spread %.2f blocks"):format(spread) or "", okMoves, moves))
  return { fixes = #fixes, spread = spread, moves = moves, okMoves = okMoves }
end

-- Another ship's block in front: what the turtle sees, and (asked first) a dig
function K.reach(dig)
  local ar = K.around()
  K.say(("reach: front %s, up %s, down %s"):format(tostring(ar.front or "nothing seen"), tostring(ar.up or "nothing seen"),
    tostring(ar.down or "nothing seen")))
  if not dig then return ar end
  if not ar.front then
    K.say("reach dig: nothing seen in front - not digging")
    return ar
  end
  print(("Dig %s in front? It must NOT be part of the destroyer. Y / N"):format(ar.front))
  local _, ch = os.pullEvent("char")
  if ch ~= "y" and ch ~= "Y" then
    K.say("reach dig: not confirmed - nothing dug")
    return ar
  end
  local ok, why = turtle.dig()
  K.say(("reach dig %s: %s"):format(ar.front, ok and "DUG" or ("failed (" .. tostring(why) .. ")")))
  ar.dug = ok
  return ar
end

-- End Automata warp points: does one saved on the ship move with the ship?
function K.warp(what)
  local core = K.findType("endAutomata")
  if not core then
    K.say("warp: no End Automata fitted")
    return false
  end
  if what == "save" then
    local ok, res, err = pcall(core.savePoint, K.POINT)
    K.say(("warp save: %s"):format(ok and (res ~= false and "saved '" .. K.POINT .. "'" or ("refused (" .. tostring(err) .. ")")) or tostring(res)))
    local p, why = K.fix()
    K.say("warp save: here = " .. fixText(p, why))
    K.say("now step the turtle off this spot, fly the ship a good way, then: shipcheck warp go")
    return ok
  end
  local okd, dist = pcall(core.distanceToPoint, K.POINT)
  K.say(("warp go: distance to the point %s"):format(okd and tostring(dist) or ("? (" .. tostring(dist) .. ")")))
  local okc, cost = pcall(core.estimateWarpCost, K.POINT)
  K.say(("warp go: cost %s, fuel %s"):format(okc and tostring(cost) or ("? (" .. tostring(cost) .. ")"), tostring(turtle.getFuelLevel())))
  local before = K.fix()
  local ok, res, err = pcall(core.warpToPoint, K.POINT)
  K.say(("warp go: %s"):format(ok and (res ~= false and "warped" or ("refused (" .. tostring(err) .. ")")) or tostring(res)))
  local after, why = K.fix()
  K.say("warp go: before " .. fixText(before) .. "; after " .. fixText(after, why))
  K.say("(after = the saved spot on the ship -> points move with the ship; no fix -> it is off the ship)")
  return ok
end

---------------------------------------------------------------- main

function K.main(args)
  K.loadConfig()
  local mode = args[1] or "parked"
  term.clear()
  term.setCursorPos(1, 1)
  K.header(mode .. (args[2] and (" " .. args[2]) or ""))
  if mode == "reach" then
    K.reach(args[2] == "dig")
  elseif mode == "warp" then
    K.warp(args[2] == "save" and "save" or "go")
  else
    local a = K.parked()
    K.save()
    local m = mode == "moving" and K.moving() or nil
    K.say("ANSWERS:")
    K.say("  can it move on the ship? " .. (a.moved and "YES" or "NO (see the move lines)")
      .. (m and (", while flying %d of %d steps"):format(m.okMoves, m.moves) or ""))
    K.say("  ship GPS: " .. (a.fix and "works" or "NO FIX")
      .. (m and m.spread and (", spread while flying %.2f blocks (under 1 = steady)"):format(m.spread) or ""))
    K.say("  geo scanner on board: " .. (a.scan == nil and "not fitted" or a.scan and "works" or "FAILED or saw nothing"))
  end
  K.save()
  K.log("run done: " .. mode)
  print("Written to " .. K.FILES.out)
end

if ARGS[1] == "lib" then return K end
K.main(ARGS)
