--[[
gunner.lua - Super Destroyer gun laying (loaded by strike.lua)        v1.1.0
Aims a bank of CBC: Advanced Technologies heavy autocannons that all turn
together on shared yaw and pitch shafts:
  * a "dud" heavy autocannon on its own mount on the same shafts, with a
    wired modem (cbcperipheral: cbc_cannon_mount) - only its angles are READ;
  * two Create Rotation Speed Controllers with wired modems, one per shaft
    line - their speed is the only thing gunner sets (0 = stopped).

Ballistics (from the mods' code; heavy autocannon HE shell):
  every tick (AbstractCannonProjectile.tick): F = -dir * min(drag * v^2, v)
  + (0, -gravity, 0); position += velocity + F / 2; velocity += F.
  gravity 0.03, drag 0.013 (quadratic). Lifetime = steel 60 ticks x 3 (x3
  for heavy autocannons); the destroyer-autocannon datapack raises steel to
  250 (750 ticks). Muzzle speed = (3 + 1.5 per heavy autocannon block in
  front of the breech, at most 4) x 1.5 with strong powder, blocks/tick:
  recoil spring + barrel + muzzle brake = 3 -> 11.25. The shell appears
  3.5 blocks out from the breech (MountedHeavyAutocannonContraption).

Frames: "world" = Minecraft axes (y up). Helm sends the ship's bow / right /
up as world unit vectors (axes) and, during a mission, the caller's position
relative to the nav table (aim, world blocks). Mount angles relate to the
ship by gunner.cal, which "gunner cal" + "gunner bow" + "gunner right"
measure - nothing about CBC's sign conventions is assumed.
]]

local G = { VERSION = "1.1.0" }
G.CAL_FILE = "/gunner.cal"
G.TYPE_MOUNT = "cbc_cannon_mount"
G.TYPE_SPEED = "Create_RotationSpeedController"

G.DEFAULTS = {
  -- peripheral names; "auto" = find them (gunner cal tells the controllers apart)
  dud = "auto", yawController = "auto", pitchController = "auto",
  -- centre of the gun bank (the mount pivots) from the nav table, blocks:
  -- r right, u up, f forward (ship's frame)
  arrayFromNav = { r = 0, u = -10, f = 0 },
  -- blocks from the mount pivot (breech) to where the shells appear
  muzzle = 3.5,
  -- shell: speed blocks/tick, lifetime ticks, gravity and drag per tick.
  -- 11.25 = (3 + 1.5 x 3: recoil spring, barrel, muzzle brake) x 1.5 strong
  -- powder; matches the first test shot (planned 155, landed ~175 long)
  muzzleSpeed = 11.25, lifetime = 750, gravity = 0.03, drag = 0.013,
  -- fire without moving when the gun bank is this close sideways (blocks)
  -- and a shot exists; else fly the nav table to `approach` blocks from the
  -- target (closer if the reach needs it, whichever way the ship ends up
  -- facing), at the firing height
  standoff = 150, approach = 50, reachMargin = 10,
  -- degrees: how close the guns must be before firing (0.5 = 2-3 blocks at
  -- these ranges, well inside the array's own spread)
  aimTolerance = 0.5,
  -- Rotation Speed Controller rpm limits while aiming (256 = its maximum;
  -- a shaft line geared down a lot needs high rpm to turn the guns at all)
  maxRpm = 256, minRpm = 1,
  -- seconds the dud must stay on target, and the ship steady, before firing
  settle = 0.6, steadySpeed = 0.5, steadyTurn = 0.3,
  -- seconds to get on target before giving up; seconds on station with no
  -- firing solution before moving again (twice at most)
  aimTimeout = 90, replanAfter = 3,
  -- computer ID of a gun relay (gunrelay.lua on a computer touching an
  -- array gun mount); false = read the dud on the cable network
  relay = false,
}

---------------------------------------------------------------- vectors

local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function add(a, b) return { a[1] + b[1], a[2] + b[2], a[3] + b[3] } end
local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function scale(a, s) return { a[1] * s, a[2] * s, a[3] * s } end
local function len(a) return math.sqrt(dot(a, a)) end
local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end
local function wrap180(a) return (a + 180) % 360 - 180 end
local function sign(x) return x < 0 and -1 or 1 end
local atan2 = math.atan2 or math.atan        -- CC has atan2; Lua 5.4 a 2-arg atan

-- ship-frame {r,u,f} -> world, with axes = { f, r, u } world unit vectors
function G.shipToWorld(v, axes)
  return add(add(scale(axes.r, v.r), scale(axes.u, v.u)), scale(axes.f, v.f))
end

function G.worldToShip(w, axes)
  return { r = dot(w, axes.r), u = dot(w, axes.u), f = dot(w, axes.f) }
end

---------------------------------------------------------------- ballistics

-- Fly a shell launched at elevation e (degrees above level) in a vertical
-- plane. Returns the height (blocks, + up) where it crosses horizontal
-- distance h and the tick it does, or nil if it never gets that far.
function G.heightAt(e, h, P)
  local r = math.rad(e)
  local vx, vy = P.muzzleSpeed * math.cos(r), P.muzzleSpeed * math.sin(r)
  local x, y = 0, 0
  for t = 1, P.lifetime do
    local v = math.sqrt(vx * vx + vy * vy)
    if v < 1e-9 then return nil end
    local dr = math.min(P.drag * v * v, v)
    local fx, fy = -vx / v * dr, -vy / v * dr - P.gravity
    local nx, ny = x + vx + fx / 2, y + vy + fy / 2
    if nx >= h then
      local f = (nx > x) and (h - x) / (nx - x) or 0
      return y + (ny - y) * f, t - 1 + f
    end
    if nx <= x then return nil end              -- stopped going sideways
    x, y = nx, ny
    vx, vy = vx + fx, vy + fy
  end
  return nil
end

-- Straight down: does it fall `drop` blocks within its life? Returns ticks.
function G.dropTime(drop, P)
  local v, y = P.muzzleSpeed, 0
  for t = 1, P.lifetime do
    local f = -math.min(P.drag * v * v, v) + P.gravity
    local ny = y + v + f / 2
    if ny >= drop then return t - 1 + (drop - y) / (ny - y) end
    y, v = ny, v + f
  end
  return nil
end

-- Elevation (deg), world azimuth direction (unit {x,0,z}) and flight ticks
-- for a target d blocks away (world vector from the muzzle), between
-- elevations eMin..eMax. The lowest (fastest) arc is chosen.
function G.solve(d, P, eMin, eMax, hint)
  eMin, eMax = eMin or -90, eMax or 30
  local h = math.sqrt(d[1] * d[1] + d[3] * d[3])
  local hdir = h > 1e-6 and { d[1] / h, 0, d[3] / h } or { 0, 0, 1 }
  if h < 0.5 then
    if d[2] < 0 and eMin <= -89.9 then
      local t = G.dropTime(-d[2], P)
      if t then return -90, hdir, t end
    end
    return nil, "straight below but out of reach"
  end
  -- the height miss f(e) rises with elevation along the low arc: bisect a
  -- bracket where it goes from below the target to above it
  local function bisect(lo, hi)
    for _ = 1, 22 do
      local mid = (lo + hi) / 2
      local ym = G.heightAt(mid, h, P)
      if ym and ym - d[2] >= 0 then hi = mid else lo = mid end
    end
    local _, t = G.heightAt(hi, h, P)
    return hi, hdir, t
  end
  -- a solution from a moment ago is usually a fraction of a degree off:
  -- try a narrow bracket around it first (the full search is slow in CC)
  if hint then
    local lo, hi = math.max(eMin, hint - 2), math.min(eMax, hint + 2)
    local yl, yh = G.heightAt(lo, h, P), G.heightAt(hi, h, P)
    if yl and yh and yl - d[2] < 0 and yh - d[2] >= 0 then return bisect(lo, hi) end
  end
  -- straight down never travels sideways: the first "can't get there" edge
  local prevE, prevF, lastNil = nil, nil, (eMin <= -89.99) and -90 or nil
  local e = math.max(eMin, -89.8)
  while e <= eMax + 1e-9 do
    local y = G.heightAt(e, h, P)
    local f = y and (y - d[2])
    if not f then
      lastNil, prevE, prevF = e, nil, nil
    elseif prevF and prevF < 0 and f >= 0 then
      return bisect(prevE, e)
    elseif not prevF and f >= 0 and lastNil then
      -- steep shots: between "never gets that far" and "passes above" the
      -- shell can still reach it low and late - look closer at that edge
      local lo, hi = lastNil, e
      for _ = 1, 22 do
        local mid = (lo + hi) / 2
        local ym = G.heightAt(mid, h, P)
        if not ym then lo = mid
        elseif ym - d[2] < 0 then return bisect(mid, hi)
        else hi = mid end
      end
      prevE, prevF = e, f
    else
      prevE, prevF = e, f
    end
    e = e + 1
  end
  return nil, "out of reach"
end

-- Furthest sideways distance a shell can hit at `drop` blocks below
function G.reach(drop, P, eMin, eMax)
  local lo, hi = G.reachBand(drop, P, eMin, eMax)
  return hi or 0
end

-- The sideways distances a shell can hit at `drop` blocks below, with the
-- mounts' pitch limits: nearest, furthest (nil, nil if none). A mount that
-- cannot point straight down cannot hit close in: drag turns every shell
-- into a near-vertical fall after a while, so it lands a fixed way out.
G.bandCache = {}
function G.reachBand(drop, P, eMin, eMax)
  eMin, eMax = eMin or -90, eMax or 30
  local key = ("%g/%g/%g/%g/%g"):format(drop, eMin, eMax, P.muzzleSpeed, P.lifetime)
  local c = G.bandCache[key]
  if c then return c[1], c[2] end
  -- sideways distance at which a shell at elevation e has fallen `drop`
  local function xAt(e)
    local r = math.rad(e)
    local vx, vy = P.muzzleSpeed * math.cos(r), P.muzzleSpeed * math.sin(r)
    local x, y = 0, 0
    for _ = 1, P.lifetime do
      local v = math.sqrt(vx * vx + vy * vy)
      local dr = math.min(P.drag * v * v, v)
      local fx, fy = -vx / v * dr, -vy / v * dr - P.gravity
      local nx, ny = x + vx + fx / 2, y + vy + fy / 2
      if ny <= -drop then return x + (nx - x) * ((-drop - y) / (ny - y)) end
      x, y = nx, ny
      vx, vy = vx + fx, vy + fy
    end
    return nil
  end
  -- nearest: the steepest arc allowed; furthest: the best elevation
  local near, far, best
  for e = eMin, eMax, 1 do
    local x = xAt(e)
    if x then
      near = near or x
      if not far or x > far then far, best = x, e end
    end
  end
  if far then
    local a, b = best - 1, best + 1                -- refine the furthest
    for _ = 1, 20 do
      local m1, m2 = a + (b - a) / 3, b - (b - a) / 3
      if (xAt(m1) or -1) < (xAt(m2) or -1) then a = m1 else b = m2 end
    end
    far = math.max(far, xAt((a + b) / 2) or 0)
    if eMin <= -89.99 then near = 0 end
  end
  G.bandCache[key] = { near, far }
  return near, far
end

-- The full firing solution for a target at world vector d from the gun
-- bank's pivot: world direction (unit), elevation, flight ticks. The shells
-- appear `muzzle` blocks out along the barrels, so solve twice.
function G.fireSolution(d, P, eMin, eMax, hint)
  local e, hdir, t = G.solve(d, P, eMin, eMax, hint)
  if not e then return nil, hdir end
  for _ = 1, 1 do
    local dirW = { math.cos(math.rad(e)) * hdir[1], math.sin(math.rad(e)), math.cos(math.rad(e)) * hdir[3] }
    local e2, h2, t2 = G.solve(sub(d, scale(dirW, P.muzzle)), P, eMin, eMax, e)
    if not e2 then break end
    e, hdir, t = e2, h2, t2
  end
  local dirW = { math.cos(math.rad(e)) * hdir[1], math.sin(math.rad(e)), math.cos(math.rad(e)) * hdir[3] }
  return { dir = dirW, elev = e, ticks = t }
end

---------------------------------------------------------------- mount angles

-- Ship-frame elevation / bearing (0 = bow, +90 = right) of a world direction
function G.shipAngles(dirW, axes)
  local s = G.worldToShip(dirW, axes)
  return math.deg(math.asin(clamp(s.u, -1, 1))), math.deg(atan2(s.r, s.f))
end

-- Dud readings that point the guns along world direction dirW
function G.mountAngles(dirW, axes, cal)
  local elev, bearing = G.shipAngles(dirW, axes)
  local pitch = elev * cal.pitchSign
  local yaw = wrap180(cal.yawBow + cal.yawSign * bearing)
  return yaw, pitch, elev, bearing
end

---------------------------------------------------------------- where to fire from

-- rel: the caller from the nav table {r,u,f} (ship frame); axes from helm;
-- height: firing height of the gun bank above the target. move = true:
-- never "stay" (a re-plan after arriving with no shot). Returns { stay = bool,
-- disp = {r,u,f} for helm, why = text, ticks = flight time if staying }.
function G.plan(rel, axes, height, P, cal, move)
  local tW = G.shipToWorld(rel, axes)
  local aW = G.shipToWorld(P.arrayFromNav, axes)
  local d = sub(tW, aW)                         -- gun bank -> target
  local h = math.sqrt(d[1] * d[1] + d[3] * d[3])
  local eMin, eMax = (cal and cal.eMin) or -90, (cal and cal.eMax) or 30
  if h <= P.standoff and not move then
    local s = G.fireSolution(d, P, eMin, eMax)
    if s then
      return { stay = true, disp = { r = 0, u = 0, f = 0 }, ticks = s.ticks,
        why = ("in range: %.0f across, %.0f down"):format(h, -d[2]) }
    end
  end
  -- fly to `height` above the target with the gun bank inside the band of
  -- distances it can hit from there. The ship's heading on arrival is not
  -- known (the gun bank is far from the nav table), so place the NAV TABLE:
  -- the gun bank then ends up within `arm` of that point, whichever way the
  -- ship faces
  local near, far = G.reachBand(height, P, eMin, eMax)
  if not far then return nil, ("the guns cannot reach %.0f blocks down"):format(height) end
  local sMin = near + (near > 0.6 and P.reachMargin or 0)
  local sMax = far - P.reachMargin
  if sMin > sMax then
    return nil, ("from %.0f up the guns only reach %.0f-%.0f blocks across"):format(height, near, far)
  end
  local arm = math.sqrt(aW[1] * aW[1] + aW[3] * aW[3])
  local lo, hi = (sMin > 0 and sMin + arm or 0), sMax - arm
  local s, ux, uz
  if lo <= hi then
    -- nav table `approach` blocks short of the target, on the side it is now
    local hn = math.sqrt(tW[1] * tW[1] + tW[3] * tW[3])
    ux, uz = 0, 1
    if hn > 1e-6 then ux, uz = -tW[1] / hn, -tW[3] / hn
    elseif h > 1e-6 then ux, uz = -d[1] / h, -d[3] / h end
    s = clamp(P.approach or 50, lo, hi)
    -- (sideways: the nav table moves; up: the gun bank ends `height` above)
    local mv = { tW[1] + ux * s, d[2] + height, tW[3] + uz * s }
    return { stay = false, disp = G.worldToShip(mv, axes),
      why = ("moving %.0f blocks to %.0f across (ship centre), %.0f up"):format(len(mv), s, height) }
  end
  -- band too narrow for any heading: place the gun bank as the ship faces now
  s = clamp(h, sMin, sMax)
  ux, uz = 0, 1
  if h > 1e-6 then ux, uz = -d[1] / h, -d[3] / h end
  local back = { ux * s, 0, uz * s }             -- target -> firing point, sideways
  local station = add(back, { 0, height, 0 })   -- gun bank relative to the target
  local mv = add(d, station)                     -- gun bank (and nav table) move
  return { stay = false, disp = G.worldToShip(mv, axes),
    why = ("moving %.0f blocks to %.0f across, %.0f up"):format(len(mv), len(back), height) }
end

---------------------------------------------------------------- calibration file

function G.loadCal(fsapi)
  fsapi = fsapi or fs
  if not fsapi.exists(G.CAL_FILE) then return nil end
  local h = fsapi.open(G.CAL_FILE, "r")
  local t = textutils.unserialize(h.readAll())
  h.close()
  if type(t) == "table" and t.pitchSign and t.yawSign and t.yawBow then return t end
  return t
end

function G.saveCal(cal, fsapi)
  fsapi = fsapi or fs
  local h = fsapi.open(G.CAL_FILE, "w")
  h.write("-- gunner.cal - measured by gunner cal (+ gunner down/up). Delete to redo.\n")
  h.write(textutils.serialize(cal))
  h.close()
end

-- Complete enough to aim with?
function G.calReady(cal)
  if type(cal) ~= "table" or not (cal.yawCtl and cal.pitchCtl and cal.rate and cal.rate.yaw and cal.rate.pitch and cal.eMin) then
    return false
  end
  if cal.mode == "tilt" then return cal.posOffset ~= nil and cal.tiltPos ~= nil end
  return cal.pitchSign ~= nil
end

---------------------------------------------------------------- the gun layer
-- G.new(io): io = { call = peripheral.call, find = name list by type,
-- now = clock, log = fn, fs = fs }. All shaft movement goes through here.

function G.new(io, P)
  local g = { io = io, P = P, cal = G.loadCal(io.fs) or {}, rpm = {}, axis = {}, msg = nil }
  setmetatable(g, { __index = G })
  return g
end

function G:log(s) if self.io.log then self.io.log("gunner: " .. s) end end

function G:names()
  local P, cal = self.P, self.cal
  local dud = P.dud ~= "auto" and P.dud or self.io.find(G.TYPE_MOUNT)[1]
  local ctls = self.io.find(G.TYPE_SPEED)
  local yaw = P.yawController ~= "auto" and P.yawController or cal.yawCtl
  local pitch = P.pitchController ~= "auto" and P.pitchController or cal.pitchCtl
  return dud, yaw, pitch, ctls
end

-- Read the gun mount: yaw, pitch (numbers) or nil. With a relay computer
-- on an array gun (io.mountRead) its latest report; else the dud on the cable.
function G:read()
  if self.io.mountRead then return self.io.mountRead() end
  local dud = self:names()
  if not dud then return nil end
  local ok1, y = pcall(self.io.call, dud, "getYaw")
  local ok2, p = pcall(self.io.call, dud, "getPitch")
  if ok1 and ok2 and type(y) == "number" and type(p) == "number" then return y, p end
  return nil
end

function G:setRpm(ctl, rpm)
  if not ctl then return end
  rpm = math.floor(rpm + 0.5)
  if self.rpm[ctl] == rpm then return end
  local ok = pcall(self.io.call, ctl, "setTargetSpeed", rpm)
  if ok then self.rpm[ctl] = rpm else self.rpm[ctl] = nil end
end

-- Stop every shaft line (always safe to call)
function G:stopAll()
  local _, _, _, ctls = self:names()
  for _, c in ipairs(ctls or {}) do
    self.rpm[c] = nil
    pcall(self.io.call, c, "setTargetSpeed", 0)
  end
  self.axis = {}
  self.job = nil
  self.tiltSide = nil
end

-- Aim the dud at (yaw, pitch); nil leaves an axis where it is
-- (a new target keeps the axis's stall watch running: helm's reports re-aim
-- the guns twice a second)
function G:aimAt(yaw, pitch)
  local function set(name, target, wrap)
    if not target then self.axis[name] = nil return end
    local a = self.axis[name] or { wrap = wrap }
    a.target = target
    self.axis[name] = a
  end
  set("yaw", yaw, true)
  set("pitch", pitch, false)
end

function G:onTarget()
  for _, a in pairs(self.axis) do
    if not a.on then return false end
  end
  return next(self.axis) ~= nil
end

-- One control step (call every ~0.2 s): drive each axis toward its target.
-- Speed per axis = error x 1.5 /s, between minRpm and maxRpm, by the
-- measured degrees per second per rpm; a stuck axis is stopped and reported.
function G:step()
  local P, cal, now = self.P, self.cal, self.io.now()
  local y, p = self:read()
  if not y then
    self:stopAll()
    local dud = self:names()
    self.msg = "cannot read the dud mount (" .. tostring(dud) .. ")"
    self:log(self.msg)
    return
  end
  self.yaw, self.pitch = y, p
  for name, a in pairs(self.axis) do
    local ctl = name == "yaw" and cal.yawCtl or cal.pitchCtl
    local rate = cal.rate and cal.rate[name]          -- deg/s per rpm (signed)
    local cur = name == "yaw" and y or p
    local err = a.wrap and wrap180(a.target - cur) or (a.target - cur)
    a.err = err
    -- on target within the tolerance; a drift out of it is corrected (slowly:
    -- 1 rpm moves ~0.14 deg a step, well inside the +-0.5 window, so no
    -- hunting). Each 1 deg of pitch error is ~3 blocks on the ground.
    if math.abs(err) <= P.aimTolerance then
      a.on = true
      self:setRpm(ctl, 0)
    elseif ctl and rate and rate ~= 0 then
      a.on = false
      local want = clamp(math.abs(err) * 1.5, 0, 1e9)  -- deg/s
      local rpm = clamp(want / math.abs(rate), P.minRpm, P.maxRpm)
      self:setRpm(ctl, rpm * sign(err) * sign(rate))
      -- stuck: driven but moving under a fifth of what this speed should
      -- give, for ~1.6 s (slow gearing is not a jam). Pitch held at its own
      -- limit within 2 deg of the target (straight down) is as good as it gets.
      local expect = math.abs(rate) * math.abs(math.floor(rpm + 0.5)) * 0.2   -- deg per step
      local moved = a.last and (a.wrap and math.abs(wrap180(cur - a.last)) or math.abs(cur - a.last))
      if moved and expect > 0.02 and moved < expect * 0.2 then
        a.still = (a.still or 0) + 1
        if a.still >= 8 then
          self:setRpm(ctl, 0)
          if name == "pitch" and math.abs(err) < 2 then
            a.on = true
          else
            a.stuck = true
            self.msg = name .. " is not turning (stalled, jammed or no power)"
          end
        end
      else
        a.still, a.stuck = 0, nil
      end
    end
    a.last = cur
  end
  if self.job then self:jobStep(now, y, p) end
end

---------------------------------------------------------------- calibration
-- "gunner cal": for each controller, spin it slowly for a second and see
-- which dud angle moves (that tells yaw from pitch, the direction and the
-- degrees per second per rpm); then run pitch to both of its limits, tilt 20
-- deg toward the bigger one and ask (gunner down / gunner up) which way is
-- down. Yaw needs no pointing: CBC's yaw is the compass yRot on the ship's
-- block grid, and the mount's facing gives the bow (G:yawBow).

G.CAL_RPM = 8
G.CAL_STEPS = { 8, 32, 128 }

-- At start-up: a calibration from before a reassembly is kept. If the speed
-- controllers came back under new names, spin each for 1.5 s to see which
-- is which (everything else measured stays valid).
function G:startup()
  local cal = self.cal
  if not G.calReady(cal) then return "not calibrated (gunner cal)" end
  local _, _, _, ctls = self:names()
  local have = {}
  for _, c in ipairs(ctls or {}) do have[c] = true end
  if have[cal.yawCtl] and have[cal.pitchCtl] then return "calibration loaded" end
  if not ctls or #ctls < 2 then return "speed controllers missing on the network" end
  self.job = { kind = "cal", stage = "spin", ctls = ctls, i = 1, identOnly = true }
  cal.yawCtl, cal.pitchCtl = nil, nil
  self.msg = "speed controllers renamed: checking which is which"
  self:log(self.msg .. " (" .. table.concat(ctls, ", ") .. ")")
  return self.msg
end

function G:startCal()
  local _, _, _, ctls = self:names()
  local dud = self.io.mountRead and "relay" or self:names()
  if not dud then return "no dud mount (cbc_cannon_mount) on the network" end
  if not self:read() then return "no reading from the gun mount (relay silent?)" end
  if not ctls or #ctls < 2 then return "need two Rotation Speed Controllers on the network (found " .. #(ctls or {}) .. ")" end
  self:stopAll()
  self.cal = { rate = {} }
  self.job = { kind = "cal", stage = "spin", ctls = ctls, i = 1, t0 = nil }
  self.msg = "calibrating: spinning each controller in turn"
  self:log(("cal: dud %s, controllers %s"):format(tostring(dud), table.concat(ctls, ", ")))
  return "calibrating - keep clear of the guns"
end

function G:jobStep(now, y, p)
  local j = self.job
  if j.kind ~= "cal" then return end
  local cal = self.cal
  if j.stage == "spin" then
    local ctl = j.ctls[j.i]
    if not ctl then
      if not (cal.yawCtl and cal.pitchCtl) then
        self:stopAll()
        self.msg = ("calibration failed: the guns did not turn (yaw controller %s, pitch controller %s) - guns deployed and assembled? rotation going into both speed controllers?")
          :format(tostring(cal.yawCtl), tostring(cal.pitchCtl))
        self:log(self.msg)
        return
      end
      self:log(("cal: yaw = %s (%.4f deg/s per rpm), pitch = %s (%.4f)"):format(cal.yawCtl, cal.rate.yaw, cal.pitchCtl, cal.rate.pitch))
      if j.identOnly then
        self.job, self.msg = nil, nil
        G.saveCal(cal, self.io.fs)
        self:log("controllers re-identified and saved")
        return
      end
      j.stage, j.dir, j.t0 = "limit", 1, nil
      return
    end
    -- each controller: try 8 rpm, then faster (the shaft line may be geared
    -- down a lot), each way round (a pitch line may sit at its stop)
    local rpm = G.CAL_STEPS[j.step or 1]
    if not j.t0 then
      j.t0, j.y0, j.p0 = now, y, p
      self:setRpm(ctl, rpm * (j.sgn or 1))
      return
    end
    if now - j.t0 >= 1.5 + (j.step or 1) * 0.5 then
      local dt = now - j.t0
      local dy, dp = wrap180(y - j.y0), p - j.p0
      self:setRpm(ctl, 0)
      local s = (j.sgn or 1) * rpm
      self:log(("cal: %s at %d rpm for %.1f s moved yaw %.3f, pitch %.3f deg"):format(ctl, s, dt, dy, dp))
      local function nextCtl() j.i, j.t0, j.sgn, j.step = j.i + 1, nil, nil, nil end
      if math.abs(dy) > 0.05 and math.abs(dy) > math.abs(dp) then
        cal.yawCtl, cal.rate.yaw = ctl, dy / dt / s
        nextCtl()
      elseif math.abs(dp) > 0.05 then
        cal.pitchCtl, cal.rate.pitch = ctl, dp / dt / s
        nextCtl()
      elseif not j.sgn then
        j.t0, j.sgn = nil, -1                      -- maybe at a pitch limit: try the other way
      elseif (j.step or 1) < #G.CAL_STEPS then
        j.t0, j.sgn, j.step = nil, nil, (j.step or 1) + 1   -- faster
      else
        nextCtl()                                  -- this one turns nothing
      end
    end
  elseif j.stage == "limit" then
    -- drive pitch one way at a modest speed until it stops moving
    local ctl, rate = cal.pitchCtl, cal.rate.pitch
    if not j.t0 then
      j.rpm = math.max(1, math.floor(math.min(self.P.maxRpm, 6 / math.abs(rate)) + 0.5))
      j.t0, j.lastP, j.still = now, p, 0
      self:setRpm(ctl, j.rpm * j.dir * sign(rate))
      return
    end
    local expect = math.abs(rate) * j.rpm * 0.2      -- deg per step at this speed
    if math.abs(p - j.lastP) < math.max(0.01, expect * 0.2) then j.still = j.still + 1 else j.still = 0 end
    j.lastP = p
    if j.still >= 8 or now - j.t0 > 180 then
      self:setRpm(ctl, 0)
      self:log(("cal: pitch stopped at %.2f"):format(p))
      if j.dir == 1 then
        j.limA, j.dir, j.t0 = p, -1, nil
      else
        cal.limits = { math.min(j.limA, p), math.max(j.limA, p) }
        -- question 1: with pitch at 0 and yaw on an exact compass angle,
        -- do the guns hang straight down or point level?
        j.big = (math.abs(j.limA) >= math.abs(p)) and j.limA or p
        j.yc = self:facingYaw()
        j.stage = "ask0"
        self:aimAt(j.yc and wrap180(j.yc) or nil, 0)
        self.msg = "Pitch is at 0: are the guns pointing STRAIGHT DOWN or LEVEL? type gunner vertical or gunner level"
        self:log(("cal: pitch stops %.1f and %.1f; asking how pitch 0 looks"):format(cal.limits[1], cal.limits[2]))
      end
    end
  end
end

G.LEAN = { bow = 0, front = 0, right = 90, stern = 180, back = 180, left = -90 }

-- The calibration questions:
--   1 gunner vertical | level   - how the guns sit at pitch 0
--   2 vertical: gunner bow | stern | left | right - which way they lean at
--     20 toward the bigger stop;  level: gunner down | up
function G:answer(which)
  local j, cal = self.job, self.cal
  if not (j and j.kind == "cal" and (j.stage == "ask0" or j.stage == "ask1")) then
    return "no question asked - run gunner cal"
  end
  if j.stage == "ask0" then
    if which ~= "vertical" and which ~= "level" then return "answer gunner vertical or gunner level" end
    cal.mode = which == "vertical" and "tilt" or "level"
    j.stage, j.tilt = "ask1", sign(j.big) * 20
    self:aimAt(j.yc and wrap180(j.yc) or nil, j.tilt)
    self.msg = cal.mode == "tilt"
      and "Which way do the barrels lean now? type gunner bow, gunner stern, gunner left or gunner right"
      or "Are the guns tilted DOWN or UP now? type gunner down or gunner up"
    return self.msg
  end
  cal.calFacingYaw = j.yc
  if cal.mode == "level" then
    if which ~= "down" and which ~= "up" then return "answer gunner down or gunner up" end
    -- elevation = pitchSign * reading; the guns are at reading j.tilt
    cal.pitchSign = ((which == "down") and -1 or 1) * sign(j.tilt)
    local e1, e2 = cal.pitchSign * cal.limits[1], cal.pitchSign * cal.limits[2]
    cal.eMin, cal.eMax = math.min(e1, e2), math.max(e1, e2)
    -- yaw: CBC sets a cannon's yaw to Minecraft's yRot of its direction on
    -- the ship's block grid (south 0, west 90, north 180, east 270; + =
    -- clockwise from above): the bow is wherever the mount's facing says
    cal.yawSign, cal.facingOffset = 1, cal.facingOffset or 0
  else
    local lean = G.LEAN[which]
    if not lean then return "answer gunner bow, stern, left or right" end
    -- tilt from straight down: positive readings lean toward bearing
    -- yaw + posOffset (snapped to 90: CBC's directions are on the grid)
    local posBearing = j.tilt > 0 and lean or lean + 180
    local y = self.yaw or j.yc or 0
    cal.posOffset = math.floor(wrap180(posBearing - y) / 90 + 0.5) * 90
    cal.tiltPos, cal.tiltNeg = math.max(cal.limits[2], 0), math.max(-cal.limits[1], 0)
    cal.eMin, cal.eMax = -90, -90 + math.max(cal.tiltPos, cal.tiltNeg)
    cal.yawSign = 1
  end
  self.job = nil
  self:aimAt(nil, 0)
  G.saveCal(cal, self.io.fs)
  self.msg = nil
  self:log(("cal: saved (%s) - elevation %.0f to %.0f deg"):format(cal.mode, cal.eMin, cal.eMax))
  return ("calibrated: the guns reach %.0f to %.0f deg elevation. Check: gunner point 0 -45 (should lean 45 down toward the bow)")
    :format(cal.eMin, cal.eMax)
end

G.YROT = { south = 0, west = 90, north = 180, east = 270 }

-- Compass yaw of the read mount's facing (cached 30 s), or nil
function G:facingYaw()
  local now = self.io.now()
  if self.faceAt and now - self.faceAt < 30 then return self.faceYaw end
  local ok, f
  if self.io.mountFacing then
    f = self.io.mountFacing()
    ok = f ~= nil
  else
    ok, f = pcall(self.io.call, (self:names()), "getDirection")
  end
  local y = ok and G.YROT[tostring(f):lower()]
  if not y then return nil end
  self.faceYaw, self.faceAt = y, now
  return y
end

-- How far the ship's block grid turned since calibration (a reassembly
-- facing another way): the mount's facing turned with it
function G:gridTurn()
  local f = self:facingYaw()
  if not f or not self.cal.calFacingYaw then return 0 end
  return wrap180(f - self.cal.calFacingYaw)
end

-- The yaw reading that points the guns at the bow (level layout)
function G:yawBow()
  local f = self:facingYaw()
  if not f then return nil end
  return wrap180(f + (self.cal.facingOffset or 0))
end

-- Tilt layout (guns hang straight down at pitch 0): the readings for a ship
-- elevation / bearing. Leaning toward bearing b by t deg is yaw b - off,
-- pitch +t (the front, up to tiltPos) or yaw b - off + 180, pitch -t (the
-- back, up to tiltNeg); keep the side in use, else take the shorter turn.
function G.tiltAngles(elev, bearing, cal, off, curYaw, side)
  local t = 90 + elev
  local front = t <= cal.tiltPos + 0.3 and { yaw = wrap180(bearing - off), pitch = t, side = 1 } or nil
  local back = t <= cal.tiltNeg + 0.3 and { yaw = wrap180(bearing - off + 180), pitch = -t, side = -1 } or nil
  if front and back then
    if side == -1 then return back end
    if side == 1 then return front end
    if curYaw and math.abs(wrap180(back.yaw - curYaw)) < math.abs(wrap180(front.yaw - curYaw)) then return back end
    return front
  end
  return front or back
end

-- Point the guns along a world direction (needs the ship's axes)
function G:point(dirW, axes)
  local cal = self.cal
  if not G.calReady(cal) then return nil, "not calibrated" end
  local elev, bearing = G.shipAngles(dirW, axes)
  if elev < cal.eMin - 0.5 or elev > cal.eMax + 0.5 then
    return nil, ("needs %.1f deg elevation, the mounts reach %.0f to %.0f"):format(elev, cal.eMin, cal.eMax)
  end
  if cal.mode == "tilt" then
    local a = G.tiltAngles(elev, bearing, cal, cal.posOffset - self:gridTurn(), self.yaw, self.tiltSide)
    if not a then return nil, ("cannot lean %.0f deg from straight down"):format(90 + elev) end
    self.tiltSide = a.side
    -- (near) straight down the bearing hardly matters: leave yaw alone
    self:aimAt(math.abs(a.pitch) > 3 and a.yaw or nil, a.pitch)
    return true
  end
  local bow = self:yawBow()
  if not bow then return nil, "cannot read which way the gun mount faces" end
  local c = { pitchSign = cal.pitchSign, yawSign = cal.yawSign or 1, yawBow = bow }
  local yaw, pitch = G.mountAngles(dirW, axes, c)
  if math.abs(elev) > 87 then yaw = nil end
  self:aimAt(yaw, pitch)
  return true
end

return G
