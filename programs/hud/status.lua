--[[
status.lua - the ship status hologram, part of the HD2 HUD (hud.lua loads it)  v1.1.0
A hologram standing on the destroyer, shared by every HUD wearer near it.
It is long and narrow - made for a 5 long x 2 wide x 4 high space: 4.4 x 1.5
(its length = its size; scroll while placing), standing at table height so
the ship's top is just below eye level, its text above:
  - the ship (icons/ship_model.txt) along its length, turned as the real
    ship is (a quarter turn while placing lays it along the space)
  - ships within 300 blocks of the destroyer (its radar): friendly green,
    hostile red, wrecks grey; one closing in pulses and says INCOMING. The
    ship sits in the middle at true scale, the 300 blocks round it an oval
    band out to the hologram's edge
  - its guns, when engaged: a gun group whose cannons are gone from the
    scan (assembled - strike's Geo Scanners, or the repair computer's) or
    firing has its barrels drawn sticking out of the hull, where the ship
    model (tools/shipmodel.py) says they are
  - a weapon firing: muzzle flashes and tracers from its barrels (the
    gatling fast, barrage shells slower, the railcannon charging then a
    beam, a carpet's bombs dropping) - for show, not where the shots go
  - thruster plumes: the stern thrusters burn as the ship flies ahead (an
    idle glow while the helm is on), the lift thrusters while it hovers
  - damage groups in red (sent by the repair computer, destroyer.repair):
    middle-click one to pick it (yellow), middle-click REPAIR to send the
    picked ones to the repair computer
  - above it: speed, altitude and heading, the active stratagems, the
    queue, the engaged guns, weapons ready, hellpods, fuel and the strike
    computer's other readouts
Place it with H in the map menu, then as the war table (drag, scroll,
middle-click turns, Enter). The strike computer keeps where it stands
(strike.cfg statusAnchor) and tells every pair of glasses. Settings: hud.cfg
status.
]]

return function(H)
local ST = { VERSION = "1.1.0" }
H.ST = ST
ST.PROTO_REPAIR, ST.HOST_REPAIR = "destroyer.repair", "repair"

ST.DEFAULTS = {
  near = 40,          -- shown within this many blocks of where it stands
  range = 300,        -- ships within this many blocks of the destroyer
  width = 0.34,       -- its width, x its length (4.4 long: 1.5 wide)
  shipWidth = 0.6,    -- the ship takes this share of its width (the rest: the band of ships round it)
  opacity = 0.75,     -- the ship's
  textWidth = 0.42,   -- the text's widest line, x its length (it turns to face you: kept inside the width too)
  plumes = true,      -- thruster plumes
}
ST.SIZE = 4.4         -- a new one's length: a 5 x 2 x 4 space with room round it
ST.LINE_CHARS = 42    -- longer readout lines are cut short
ST.FRESH = 10         -- s: older word from strike = "no word"
ST.EVERY = 0.25       -- s between moves of the hologram (it glides between)
ST.GLIDE = 5          -- ticks a move takes
ST.MAX_CONTACTS = 16
ST.MAX_GROUPS = 40
ST.MAX_FIRING = 5     -- barrels of a gun group animated while it fires
ST.HOLO = 0x55B4FF    -- the hologram's blue
ST.COLOUR = {
  friendly = 0x5DD55D, hostile = 0xFF3030, debris = 0x8C8C8C,
  damaged = 0xFF3030, picked = 0xFFD23F, queued = 0xFF8A3D, fixing = 0x55B4FF,
  flash = 0xFFB020, muzzle = 0xFFF2B0, shot = 0xFFE14D, tracer = 0xFFB43C, shell = 0xFF8A3D, bomb = 0xFF7A30,
  rail = 0x9AD8FF, barrel = 0xD6E8F5, plume = 0x3FA9FF, core = 0xDDF6FF,
  text = 0xDDEEFF, warn = 0xFF4A3D, good = 0x6EE07A,
}
-- the gun groups (shipmodel.py's systems = strike's stratagem kinds) by name, in the order listed
ST.SYSTEMS = { { "rail", "RAILCANNON" }, { "gun", "GATLING" }, { "barrage", "BARRAGE GUNS" }, { "turret", "TURRETS" },
  { "carpet", "BOMB BAY" } }
-- a way in the ship's frame (shipmodel.py's letters) -> the hologram's (x right, y up, z astern)
ST.DIRV = { r = { 1, 0, 0 }, l = { -1, 0, 0 }, u = { 0, 1, 0 }, d = { 0, -1, 0 }, f = { 0, 0, -1 }, b = { 0, 0, 1 } }

local now = os.clock
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function W() return H.W end

ST.status, ST.statusAt, ST.anchor = nil, nil, nil
ST.groups = nil        -- { list, at } from the repair computer
ST.sel = {}            -- picked group ids
ST.track = {}          -- radar ship id -> { d, at, closing } (closing: blocks a second nearer)

---------------------------------------------------------------- messages

-- strike's "shipstatus" (destroyer.hud)
function ST.onStatus(msg)
  if type(msg) ~= "table" then return end
  ST.status, ST.statusAt = msg, now()
  -- (a weapon starting or stopping, guns going out or in: shown at once)
  local guns = textutils.serialize({ f = msg.firing, e = msg.engaged })
  if guns ~= ST.gunsWord then ST.gunsWord, ST.dirty = guns, true end
  local a = msg.anchor
  if type(a) == "table" and ((a.mode == "ship" and type(a.rel) == "table") or (a.mode == "world" and type(a.world) == "table")) then
    if not ST.anchor or textutils.serialize(a) ~= textutils.serialize(ST.anchor) then ST.dirty = true end
    ST.anchor = a
  end
end

-- The repair computer (destroyer.repair). "groups": the damage, each
-- { id, c = { r, u, f } its middle from the nav table, n = blocks broken,
-- box = { r0, u0, f0, r1, u1, f1 } (optional), st = "damaged" | "queued" |
-- "fixing" }, and (optional) engaged = { <gun group> = true | false } from
-- its scan; "said": a line for the wearer
function ST.onRepair(from, msg)
  if type(msg) ~= "table" then return end
  if type(msg.engaged) == "table" then ST.repairEngaged = { map = msg.engaged, at = now() } end
  if msg.op == "groups" and type(msg.groups) == "table" then
    ST.repairId = from
    ST.groups = { list = msg.groups, at = now() }
    local live = {}
    for _, g in ipairs(msg.groups) do if type(g) == "table" and g.id ~= nil then live[g.id] = true end end
    for id in pairs(ST.sel) do if not live[id] then ST.sel[id] = nil end end   -- (a picked group gone: unpicked)
    ST.dirty = true
  elseif msg.op == "said" and msg.text then
    H.toast(tostring(msg.text):upper(), H.C.yellow, 3)
  end
end

-- (from the HUD's network loop, once a second) the repair computer, when it is about
function ST.netTick()
  if ST.repairId or now() < (ST.lookAt or 0) then return end
  ST.lookAt = now() + 30
  local ok, id = pcall(rednet.lookup, ST.PROTO_REPAIR, ST.HOST_REPAIR)
  if ok and id then ST.repairId = id end
end

-- What is firing now (strike's word): { { n, kind, sys, at }, ... } - sys:
-- the gun group (the stratagem's own `sys`, else its kind)
function ST.firingNow()
  local s, out = ST.status, {}
  if not (s and ST.statusAt and now() - ST.statusAt < ST.FRESH and type(s.firing) == "table") then return out end
  for _, f in ipairs(s.firing) do
    if type(f) == "table" then out[#out + 1] = { n = f.n, kind = f.kind, sys = tostring(f.sys or f.kind or "?"), at = f.at } end
  end
  return out
end

-- Which gun groups are engaged: a scan's word (strike's Geo Scanners, the
-- repair computer's - a group whose cannons are gone from it is assembled,
-- out) and any firing now. -> { sys = "on" | "firing" }, known (a scan said)
function ST.engagedNow(firing)
  local out, known = {}, false
  local function take(t)
    if type(t) ~= "table" then return end
    known = true
    for k, v in pairs(t) do if v == true then out[tostring(k)] = "on" end end
  end
  local s = ST.status
  if s and ST.statusAt and now() - ST.statusAt < ST.FRESH then take(s.engaged) end
  if ST.repairEngaged and now() - ST.repairEngaged.at < 30 then take(ST.repairEngaged.map) end
  for _, f in ipairs(firing or ST.firingNow()) do out[f.sys] = "firing" end
  return out, known
end

-- The engaged groups by name, in ST.SYSTEMS' order: { { name, firing }, ... }
function ST.engagedNames(set)
  local out, seen = {}, {}
  for _, sy in ipairs(ST.SYSTEMS) do
    if set[sy[1]] then out[#out + 1] = { sy[2], set[sy[1]] == "firing" } end
    seen[sy[1]] = true
  end
  local rest = {}
  for k in pairs(set) do if not seen[k] then rest[#rest + 1] = k end end
  table.sort(rest)
  for _, k in ipairs(rest) do out[#out + 1] = { k:upper(), set[k] == "firing" } end
  return out
end

-- war.lua's table setup finished for the hologram: here at once, and kept on the strike computer
function ST.placed(a)
  ST.anchor, ST.dirty = a, true
  if H.strike then
    pcall(rednet.send, H.strike, { op = "statusanchor", anchor = a }, H.PROTO_STRIKE)
    H.toast("STATUS HOLOGRAM PLACED", H.C.yellow, 2)
  else
    H.toast("STATUS HOLOGRAM PLACED ON THESE GLASSES ONLY (NO STRIKE COMPUTER)", H.C.red, 4)
  end
end

---------------------------------------------------------------- the readouts

local function num(v, fmt) return tonumber(v) and fmt:format(tonumber(v)) or "-" end
local STAGE = { FLY = "EN ROUTE", AIM = "AIMING", SCAN = "FINDING THE TARGET", FIRE = "FIRING", END = "DONE" }

-- The text over the hologram: { { text, colour }, ... } top line first.
-- s = strike's last status (nil: none); fresh = heard lately; extra =
-- { contacts, incoming, groups, picked, engaged = ST.engagedNames(..), known }
function ST.lines(s, fresh, extra)
  local C, out = ST.COLOUR, {}
  local function add(t, c) out[#out + 1] = { t, c or C.text } end
  extra = extra or {}
  if not s or not fresh then
    add("NO WORD FROM THE STRIKE COMPUTER", C.warn)
  else
    -- (at most 7 lines: speed, active, queue, engaged, weapons, readouts, ships - it stands in a small space)
    local moving = tonumber(s.speed) and tonumber(s.speed) >= 0.5
    local helmBad = s.helm ~= "online"
    add(("SPEED %s B/S   ALT %s   HDG %s%s"):format(num(s.speed, "%.0f"), num(s.alt, "%.0f"), num(s.hdg, "%03d"),
      helmBad and ("   HELM " .. tostring(s.helm or "silent"):upper()) or ""), helmBad and C.warn or moving and C.text or C.good)
    -- the stratagems running now (the mission and one beside it)
    local act, hot = {}, false
    for _, m in ipairs({ s.mission or false, s.side or false }) do
      if type(m) == "table" then
        local tail = ""
        if m.stage == "FIRE" and tonumber(m.left) then tail = (" %.0fS"):format(tonumber(m.left))
        elseif m.stage == "FLY" and tonumber(m.dist) then tail = (" %.0fM"):format(tonumber(m.dist)) end
        act[#act + 1] = ("%s (%s%s)"):format(tostring(m.n or "?"):upper(), STAGE[m.stage] or tostring(m.stage or ""), tail)
        if m.stage == "FIRE" then hot = true end
      end
    end
    local aline = #act > 0 and ("ACTIVE: " .. table.concat(act, " + ")) or "NO ACTIVE STRATAGEMS - READY"
    if s.demo then aline = aline .. "  (DEMO)" end
    add(aline, (hot or s.demo) and C.warn or #act > 0 and C.text or C.good)
    local q = type(s.queue) == "table" and s.queue or {}
    add(#q > 0 and ("QUEUED: " .. table.concat(q, ", "):upper()) or "QUEUE EMPTY")
    -- the guns out (a scan's word, or firing); no scan and none firing: not shown
    local eng = type(extra.engaged) == "table" and extra.engaged or {}
    if #eng > 0 then
      local names = {}
      for _, e in ipairs(eng) do names[#names + 1] = e[1] .. (e[2] and " (FIRING)" or "") end
      add("ENGAGED: " .. table.concat(names, ", "), C.warn)
    elseif extra.known then
      add("ENGAGED: NONE - GUNS STOWED", C.good)
    end
    local strats = type(s.strats) == "table" and s.strats or {}
    local ready, firstBad = 0, nil
    for _, st in ipairs(strats) do
      if st.ok then ready = ready + 1 elseif not firstBad then firstBad = st end
    end
    if #strats > 0 then
      add(("WEAPONS %d/%d READY%s"):format(ready, #strats, firstBad and (" - " .. tostring(firstBad.n):upper() .. ": "
        .. tostring(firstBad.why or "not ready"):upper()) or ""), ready == #strats and C.good or C.warn)
    end
    -- readouts: hellpods and fuel always (a dash until the strike computer reads them), then the rest
    local rd, byLabel = type(s.readouts) == "table" and s.readouts or {}, {}
    for _, r in ipairs(rd) do byLabel[tostring(r.l or ""):upper()] = r end
    local function show(r) return r and tonumber(r.v) and (tostring(r.v) .. (r.u and tostring(r.u) or "")) or "-" end
    local parts = { "HELLPODS " .. show(byLabel.HELLPODS), "FUEL " .. show(byLabel.FUEL) }
    for _, r in ipairs(rd) do
      local l = tostring(r.l or ""):upper()
      if l ~= "HELLPODS" and l ~= "FUEL" then parts[#parts + 1] = l .. " " .. show(r) end
    end
    add(table.concat(parts, "   "))
  end
  -- ships round it and (with a repair computer) the damage share the last line
  local c, inc = tonumber(extra.contacts) or 0, tonumber(extra.incoming) or 0
  local last = ("SHIPS IN %dM: %d%s"):format(ST.cfgRange(), c, inc > 0 and (" (" .. inc .. " INCOMING)") or "")
  local lcol = inc > 0 and C.warn or C.text
  if extra.groups then
    local g, p = tonumber(extra.groups) or 0, tonumber(extra.picked) or 0
    last = last .. (g == 0 and "   NO DAMAGE" or ("   DAMAGE: %d GROUP%s%s"):format(g, g == 1 and "" or "S",
      p > 0 and (" - " .. p .. " PICKED") or " - MIDDLE-CLICK TO PICK"))
    if g > 0 then lcol = C.warn end
  end
  add(last, lcol)
  return out
end

-- A line cut to at most n characters (the hologram is narrow)
function ST.fit(text, n)
  text = tostring(text)
  if #text <= n then return text end
  return text:sub(1, n - 2) .. ".."
end

-- A long line as two (broken after a ", " / " + " / space within n), the
-- second cut short -> { line, ... }
function ST.wrap(text, n)
  text = tostring(text)
  if #text <= n then return { text } end
  local cut
  for i = n, math.floor(n / 2), -1 do
    local two = text:sub(i - 1, i)
    if two == ", " or two == "+ " or text:sub(i, i) == " " then cut = i break end
  end
  if not cut then return { ST.fit(text, n) } end
  local first, rest = text:sub(1, cut):gsub("[%s,+]+$", ""), text:sub(cut + 1):gsub("^%s+", "")
  return { first, ST.fit("  " .. rest, n) }
end

function ST.cfgRange() return tonumber(H.cfg.status and H.cfg.status.range) or ST.DEFAULTS.range end

---------------------------------------------------------------- geometry

-- Where a ship goes on the hologram: it lies (r, f) blocks from the
-- destroyer's middle (r right, f ahead), d of them. Inside the destroyer's own
-- oval (half-length a, half-width b, hologram units) at true scale; beyond it,
-- the range round it spread across the band out to the edge oval (A, B).
-- -> x (right), z (astern) in hologram units
function ST.band(r, f, d, g, range)
  if d <= 0 then return 0, 0 end
  local ur, uf = r / d, f / d
  local inner = 1 / math.sqrt((ur / g.b) ^ 2 + (uf / g.a) ^ 2)     -- (the ship's oval that way)
  local outer = 1 / math.sqrt((ur / g.B) ^ 2 + (uf / g.A) ^ 2)     -- (the edge that way)
  local extent = inner / g.k                                       -- (blocks from its middle to its side that way)
  local h
  if d <= extent then
    h = d * g.k
  else
    h = inner + math.min(1, (d - extent) / range) * (outer - inner)
  end
  return ur * h, -uf * h
end

-- The ship's middle from the nav table: strike's measure, else hud.cfg war.ship.centre
function ST.centre()
  local w = W()
  local c = (w and w.pose and w.pose.centre) or (type(H.cfg.war) == "table" and type(H.cfg.war.ship) == "table" and H.cfg.war.ship.centre) or {}
  return tonumber(c.r) or 0, tonumber(c.u) or 0, tonumber(c.f) or 0
end

-- The geometry for a hologram `size` blocks long (width = size x width):
-- blocks -> hologram units (the ship fills shipWidth of the width), the
-- ship's oval (a, b), the edge oval (A, B), how high the ship's middle and
-- top stand, and how far up the ships round it may go
function ST.geom(size)
  local cfg = H.cfg.status
  local sm = W() and W().shipModel()
  local length, width, height = sm and sm.length or 262, sm and sm.width or 112, sm and sm.height or 68
  local wide = size * (tonumber(cfg.width) or ST.DEFAULTS.width)
  local k = (tonumber(cfg.shipWidth) or ST.DEFAULTS.shipWidth) * wide / width
  k = math.min(k, 0.9 * size / length)                -- (a stubby ship model: its length fits too)
  local base = 0.07 * size                             -- (it floats: room under it for the guns' shots and the lift plumes)
  local g = { size = size, wide = wide, k = k, sm = sm, height = height,
    a = length / 2 * k, b = width / 2 * k, A = 0.5 * size, B = 0.4 * wide,
    lift = base + height / 2 * k, top = base + height * k }
  g.cTop = g.top + 0.02 * size                         -- (ships round it: no higher than just over its top)
  return g
end

-- A point in the ship's frame (r, u, f from its middle) -> hologram units
-- (x = right, y = up, z = astern: the war table's map frame)
function ST.toHolo(g, r, u, f) return r * g.k, g.lift + u * g.k, -f * g.k end

-- How high above the wearer's feet a new one stands: the ship's top at 1.5,
-- just below eye level (1.62)
function ST.standHeight(size) return 1.5 - ST.geom(size or ST.SIZE).top end

---------------------------------------------------------------- objects

local EASED = { x = "X", y = "Y", z = "Z", rotX = "RotX", rotY = "RotY", rotZ = "RotZ", sizeX = "SizeX", sizeY = "SizeY",
  sizeZ = "SizeZ", opacity = "Opacity", fontSize = "FontSize" }

-- An object made hidden, its easing off, then set and shown (it appears in
-- place - the overlay would ease it in from nowhere); glide: ticks its moves take
function ST.make(kind, props, glide)
  local base, later = {}, {}
  for k, v in pairs(props) do
    if EASED[k] then later[k] = v else base[k] = v end
  end
  base.enabled = false
  local o = H.make(kind, base)
  if not o then return nil end
  for _, f in pairs(EASED) do
    local set = o.o["set" .. f .. "LerpSteps"]
    if set then pcall(set, 0) end
  end
  for k, v in pairs(later) do o:set(EASED[k], v) end
  if glide then
    for _, f in ipairs({ "setXLerpSteps", "setYLerpSteps", "setZLerpSteps" }) do
      if o.o[f] then pcall(o.o[f], glide) end
    end
  end
  return o
end

function ST.reset()
  ST.objs = { ship = {}, groups = {}, contacts = {}, labels = {}, guns = {}, fx = {}, plume = {}, lines = {} }
  ST.placedAt, ST.dirty = nil, true
end
ST.reset()

-- One object of a pool (made the first time), placed and shown. rot: its
-- turn (the hologram's); nil: left to the caller (text, turned to face you)
local function place(pool, i, kind, x, y, z, sx, sy, sz, look, rot, glide)
  local o = pool[i]
  if not o then
    local props = { x = x, y = y, z = z, sizeX = sx, sizeY = sy, sizeZ = sz }
    if rot then props.rotY, props.rotX, props.rotZ = rot[1], rot[2], rot[3] end
    for k, v in pairs(look or {}) do props[k] = v end
    o = ST.make(kind, props, glide)
    pool[i] = o
    if o then o:show(true) end
    return o
  end
  o:pos(x, y, z)
  if rot then o:set("RotY", rot[1]) o:set("RotX", rot[2]) o:set("RotZ", rot[3]) end
  if sx then o:set("SizeX", sx) end
  if sy then o:set("SizeY", sy) end
  if sz then o:set("SizeZ", sz) end
  for k, v in pairs(look or {}) do o:set(k:sub(1, 1):upper() .. k:sub(2), v) end
  o:show(true)
  return o
end

local function hideFrom(pool, n)
  for i = n, #pool do if pool[i] then pool[i]:show(false) end end
end

function ST.hideAll()
  for _, pool in pairs(ST.objs) do hideFrom(pool, 1) end
  ST.shown = false
end

-- (the ship's own colours, turned to the hologram's blue by how light they are)
local function holoColour(c)
  local r, g, b = math.floor(c / 65536) % 256, math.floor(c / 256) % 256, c % 256
  local l = (0.3 * r + 0.59 * g + 0.11 * b) / 255
  local f = 0.55 + 0.45 * l
  local hr, hg, hb = math.floor(ST.HOLO / 65536) % 256, math.floor(ST.HOLO / 256) % 256, ST.HOLO % 256
  return math.floor(hr * f) * 65536 + math.floor(hg * f) * 256 + math.floor(hb * f)
end

---------------------------------------------------------------- each frame

-- Where it stands now: being placed (war.lua's setup), else strike's
function ST.anchorNow()
  local w = W()
  local m = w and w.menu
  if m and m.open and m.setup and m.setupFor == "status" then return m.setup, true end
  return ST.anchor, false
end

-- The ships within range, in the destroyer's frame (r, u, f from its middle) -> list nearest first
function ST.contacts()
  local w = W()
  local r = H.radar
  if not (w and r and now() - r.at < 5) then return {} end
  local nav, ax = w.shipNow(0)
  if not nav then return {} end
  local cr, cu, cf = ST.centre()
  local mid = { nav[1] + ax.r[1] * cr + ax.u[1] * cu + ax.f[1] * cf, nav[2] + ax.r[2] * cr + ax.u[2] * cu + ax.f[2] * cf,
    nav[3] + ax.r[3] * cr + ax.u[3] * cu + ax.f[3] * cf }
  local g = ST.geomNow
  local reach = (g and g.a / g.k or 131) + ST.cfgRange()             -- (its half-length + the range)
  local out = {}
  for _, tr in ipairs(r.tracks) do
    if tonumber(tr.x) and w.trackKind(tr.c) == "ship" then
      local d3 = { tr.x - mid[1], (tonumber(tr.y) or 0) - mid[2], tr.z - mid[3] }
      local function dot(a) return a[1] * d3[1] + a[2] * d3[2] + a[3] * d3[3] end
      local sr, su, sf = dot(ax.r), dot(ax.u), dot(ax.f)
      local d = math.sqrt(sr * sr + sf * sf)
      if d <= reach then
        local t = ST.track[tr.id]
        if t and now() - t.at >= 1 then
          t.closing, t.d, t.at = (t.d - d) / (now() - t.at), d, now()
        elseif not t then
          ST.track[tr.id] = { d = d, at = now(), closing = 0 }
        end
        local closing = ST.track[tr.id] and ST.track[tr.id].closing or 0
        out[#out + 1] = { id = tr.id, r = sr, u = su, f = sf, d = d, friend = tr.f == true, debris = tr.dbr == true,
          name = w.nameOf(tr.sn), incoming = closing > 1 and not tr.f and not tr.dbr }
      end
    end
  end
  table.sort(out, function(a, b) return a.d < b.d end)
  return out
end

function ST.frame()
  if not H.ov then return end
  local w = W()
  if not w then return end
  local anchor, placing = ST.anchorNow()
  local m = w.menu
  local want = anchor and H.worn and H.me and (not m.open or placing) and true or false
  local origin, rot
  if want then
    origin, rot = w.tableFrame(anchor, 0, ST.EVERY)
    local near = tonumber(H.cfg.status.near) or ST.DEFAULTS.near
    if not origin or (H.me.x - origin[1]) ^ 2 + (H.me.z - origin[3]) ^ 2 > near * near then want = false end
  end
  if not want then
    if ST.shown then ST.hideAll() end
    return
  end
  if placing or ST.dirty or not ST.placedAt or now() - ST.placedAt >= ST.EVERY then
    ST.placedAt, ST.dirty = now(), false
    ST.layout(anchor, origin, rot)
  end
  ST.animate()
  ST.shown = true
end

-- Everything placed again: the ship, the damage, the ships round it, the text
function ST.layout(anchor, origin, rot)
  local w = W()
  local g = ST.geom(tonumber(anchor.size) or ST.SIZE)
  ST.geomNow, ST.originNow, ST.rotNow = g, origin, rot
  local a, b, c = w.euler(rot)
  local turn = { a, b, c }
  local function world(x, y, z)
    local p = w.apply(rot, { x, y, z })
    return origin[1] + p[1], origin[2] + p[2], origin[3] + p[3]
  end
  ST.world = world
  local O = ST.objs
  local op = tonumber(H.cfg.status.opacity) or ST.DEFAULTS.opacity
  -- the plate it stands on: as long as its size, as wide as its width
  local px, py, pz = world(0, -0.01, 0)
  place(O.ship, 1, "Box", px, py, pz, g.wide, 0.02, g.size, { color = 0x0A1A14, opacity = 0.6 }, turn, ST.GLIDE)
  -- the ship
  local n = 1
  if g.sm then
    for _, bx in ipairs(g.sm.boxes) do
      n = n + 1
      local x, y, z = ST.toHolo(g, (bx[1] + bx[4]) / 2, (bx[2] + bx[5]) / 2, (bx[3] + bx[6]) / 2)
      local wx, wy, wz = world(x, y, z)
      place(O.ship, n, "Box", wx, wy, wz, (bx[4] - bx[1]) * g.k, (bx[5] - bx[2]) * g.k, (bx[6] - bx[3]) * g.k,
        { color = holoColour(bx[7]), opacity = op }, turn, ST.GLIDE)
    end
  end
  hideFrom(O.ship, n + 1)
  -- the damage groups (from the repair computer)
  local cr, cu, cf = ST.centre()
  ST.picks = {}
  local gi = 0
  local groups = ST.groups and ST.groups.list or {}
  for _, gr in ipairs(groups) do
    if gi >= ST.MAX_GROUPS then break end
    local gc = type(gr) == "table" and type(gr.c) == "table" and gr.c
    if gc and tonumber(gc.r) and tonumber(gc.f) then
      gi = gi + 1
      local x, y, z = ST.toHolo(g, gc.r - cr, (tonumber(gc.u) or 0) - cu, gc.f - cf)
      local bx = type(gr.box) == "table" and gr.box
      local s = 0.02 * g.size
      local sx, sy, sz = s, s, s
      if bx and tonumber(bx[1]) and tonumber(bx[6]) then
        sx = clamp((bx[4] - bx[1] + 1) * g.k, s, 0.15 * g.size)
        sy = clamp((bx[5] - bx[2] + 1) * g.k, s, 0.15 * g.size)
        sz = clamp((bx[6] - bx[3] + 1) * g.k, s, 0.15 * g.size)
      end
      local colour = ST.sel[gr.id] and ST.COLOUR.picked or ST.COLOUR[gr.st] or ST.COLOUR.damaged
      local wx, wy, wz = world(x, y, z)
      place(O.groups, gi, "Box", wx, wy, wz, sx, sy, sz, { color = colour, opacity = 0.9 }, turn, ST.GLIDE)
      ST.picks[#ST.picks + 1] = { id = gr.id, x = wx, y = wy, z = wz, rad = math.max(sx, sy, sz) * 0.75 + 0.03 * g.size,
        fixing = gr.st == "fixing" }
    end
  end
  hideFrom(O.groups, gi + 1)
  -- the guns out: each engaged group's barrels sticking out of the hull the
  -- way they point (where its shots start - ST.tips - for the animation)
  local firing = ST.firingNow()
  local engaged, known = ST.engagedNow(firing)
  ST.fireList, ST.tips = firing, {}
  local bi = 0
  local len, thick, inset = 0.03 * g.size, 0.004 * g.size, 0.004 * g.size
  for _, gun in ipairs(g.sm and g.sm.guns or {}) do
    local d = ST.DIRV[gun.dir]
    if engaged[gun.sys] and d then
      local x, y, z = ST.toHolo(g, gun.r, gun.u, gun.f)
      local mid = len / 2 - inset                     -- (from just inside the hull)
      bi = bi + 1
      local wx, wy, wz = world(x + d[1] * mid, y + d[2] * mid, z + d[3] * mid)
      place(O.guns, bi, "Box", wx, wy, wz, d[1] ~= 0 and len or thick, d[2] ~= 0 and len or thick, d[3] ~= 0 and len or thick,
        { color = ST.COLOUR.barrel, opacity = 0.95 }, turn, ST.GLIDE)
      local tips = ST.tips[gun.sys] or {}
      ST.tips[gun.sys] = tips
      local out = len - inset
      tips[#tips + 1] = { x + d[1] * out, y + d[2] * out, z + d[3] * out, d }
    end
  end
  hideFrom(O.guns, bi + 1)
  -- the ships round it
  local cs = ST.contacts()
  local ci, incoming = 0, 0
  for _, ct in ipairs(cs) do
    if ct.incoming then incoming = incoming + 1 end
    if ci < ST.MAX_CONTACTS then
      ci = ci + 1
      local x, z = ST.band(ct.r, ct.f, ct.d, g, ST.cfgRange())
      local y = clamp(g.lift + ct.u * g.k, 0.01 * g.size, g.cTop)      -- (never through the plate or high above the ship)
      local colour = ct.debris and ST.COLOUR.debris or ct.friend and ST.COLOUR.friendly or ST.COLOUR.hostile
      local size = 0.018 * g.size
      local wx, wy, wz = world(x, y, z)
      place(O.contacts, ci, "Box", wx, wy, wz, size, size, size, { color = colour, opacity = 0.95 }, turn, ST.GLIDE)
      O.contacts[ci].pulse = ct.incoming and size or nil
      local label = (ct.incoming and "INCOMING " or "") .. (ct.name or (ct.debris and "DEBRIS" or ct.friend and "FRIENDLY" or "HOSTILE"))
        .. (" %dM"):format(math.floor(ct.d + 0.5))
      local lx, ly, lz = world(x, y + size + 0.01 * g.size, z)
      local t = place(O.labels, ci, "Text", lx, ly, lz, nil, nil, nil,
        { content = label, color = colour, fontSize = g.size * 0.0016, center = true, shadow = true }, nil, ST.GLIDE)
      if t then H.face(t, lx, ly, lz) end
    end
  end
  hideFrom(O.contacts, ci + 1)
  hideFrom(O.labels, ci + 1)
  ST.contactCount, ST.incoming = #cs, incoming
  -- the text over it
  local picked = 0
  for _ in pairs(ST.sel) do picked = picked + 1 end
  local lines = ST.lines(ST.status, ST.statusAt and now() - ST.statusAt < ST.FRESH,
    { contacts = #cs, incoming = incoming, groups = ST.groups and #groups or nil, picked = picked,
      engaged = ST.engagedNames(engaged), known = known })
  local wrapped = {}
  for _, l in ipairs(lines) do
    for _, part in ipairs(ST.wrap(l[1], ST.LINE_CHARS)) do wrapped[#wrapped + 1] = { part, l[2] } end
  end
  lines = wrapped
  -- (as big as fits: its widest line within textWidth of its length - a
  -- character is about 6 font pixels wide, a line 10 high)
  local longest = 0
  for _, l in ipairs(lines) do longest = math.max(longest, math.min(#l[1], ST.LINE_CHARS)) end
  local fs = math.min((tonumber(H.cfg.status.textWidth) or ST.DEFAULTS.textWidth) * g.size / (6 * math.max(longest, 20)), 0.0035 * g.size)
  local lineH = fs * 10
  local top = g.top + 0.03 * g.size
  ST.textTop = top + (#lines + (picked > 0 and 1.5 or 0)) * lineH      -- (how high the text goes: kept in its space)
  local li = 0
  -- (the REPAIR button first, lowest: middle-click it to send the picked groups)
  if picked > 0 then
    li = li + 1
    local bx, by, bz = world(0, top, 0)
    local t = place(O.lines, li, "Text", bx, by, bz, nil, nil, nil,
      { content = ("[ REPAIR %d PICKED ]"):format(picked), color = ST.COLOUR.picked, fontSize = fs * 1.2, center = true, shadow = true },
      nil, ST.GLIDE)
    if t then H.face(t, bx, by, bz) end
    ST.button = { x = bx, y = by, z = bz, rad = math.max(0.06 * g.size, fs * 30) }
  else
    ST.button = nil
  end
  for i = #lines, 1, -1 do
    li = li + 1
    local ly = top + (li - 1) * lineH + (picked > 0 and lineH * 0.5 or 0)
    local x, y, z = world(0, ly, 0)
    local t = place(O.lines, li, "Text", x, y, z, nil, nil, nil,
      { content = ST.fit(lines[i][1], ST.LINE_CHARS), color = lines[i][2], fontSize = fs, center = true, shadow = true }, nil, ST.GLIDE)
    if t then H.face(t, x, y, z) end
  end
  hideFrom(O.lines, li + 1)
end

-- (a steady pseudo-random 0..1 for a number: the shots' flicker)
local function noise(n)
  local v = math.sin(n * 12.9898) * 43758.5453
  return v - math.floor(v)
end
ST.noise = noise

-- How far a shot from (x, y, z) going d flies: down to the plate, else out
-- to the hologram's edge
function ST.shotReach(g, x, y, z, d)
  if d[2] < 0 then return math.max(0.02 * g.size, y - 0.01) end
  if d[2] > 0 then return 0.25 * g.size end
  if d[1] ~= 0 then return math.max(0.02 * g.size, g.wide / 2 - math.abs(x)) end
  return math.max(0.02 * g.size, g.size / 2 - math.abs(z))
end

-- One barrel firing (tip = { x, y, z, d }: where its shots start, which way),
-- drawn with fx(x, y, z, sx, sy, sz, colour, opacity). Not where the shots
-- really go - it shows that it fires: the gatling and turrets rattling with
-- tracers, barrage shells, the railcannon charging then a beam, bombs falling
function ST.shots(fx, kind, tip, seed, t, g)
  local C, S = ST.COLOUR, g.size
  local x, y, z, d = tip[1], tip[2], tip[3], tip[4]
  local reach = ST.shotReach(g, x, y, z, d)
  -- (a box long along d, and a flat one across it: a muzzle flash is both)
  local function along(cx, cy, cz, long, thin, colour, op)
    fx(cx, cy, cz, d[1] ~= 0 and long or thin, d[2] ~= 0 and long or thin, d[3] ~= 0 and long or thin, colour, op)
  end
  local function flash(size, colour)
    fx(x, y, z, d[1] ~= 0 and size * 0.3 or size, d[2] ~= 0 and size * 0.3 or size, d[3] ~= 0 and size * 0.3 or size, colour, 0.95)
    along(x + d[1] * size * 0.7, y + d[2] * size * 0.7, z + d[3] * size * 0.7, size * 1.5, size * 0.3, C.muzzle, 0.9)
  end
  local function at(p) return x + d[1] * p, y + d[2] * p, z + d[3] * p end
  if kind == "rail" then
    local c = (t / 1.8 + noise(seed) * 0.3) % 1
    if c < 0.65 then
      local q = c / 0.65                              -- (charging: a glow growing at the muzzle)
      local s = 0.004 * S + 0.02 * S * q
      fx(x, y, z, s, s, s, C.rail, 0.4 + 0.5 * q)
    else
      local q = (c - 0.65) / 0.35                     -- (the shot: a beam out to the edge, fading)
      local bx, by, bz = at(reach / 2)
      along(bx, by, bz, reach, 0.008 * S * (1 - 0.6 * q), C.rail, 0.95 * (1 - q))
      flash(0.03 * S * (1 - q), C.flash)
    end
  elseif kind == "barrage" then
    local ph = t * 1.4 + noise(seed)
    if ph % 1 < 0.22 then flash(0.018 * S, C.flash) end
    local p = (t * 1.1 + noise(seed + 1)) % 1
    local sx, sy, sz = at(p * reach)
    along(sx, sy, sz, 0.012 * S, 0.006 * S, C.shell, 0.95 - 0.5 * p)
  elseif kind == "carpet" then
    for j = 0, 2 do                                   -- (bombs tumbling out of the bay, faster as they fall)
      local p = (t * 0.8 + j / 3 + noise(seed) * 0.2) % 1
      local bx, by, bz = at(p * p * reach)
      fx(bx, by, bz + (j - 1) * 0.03 * S, 0.007 * S, 0.01 * S, 0.007 * S, C.bomb, 0.95 - 0.4 * p)
    end
  else
    local ph = t * 9 + noise(seed)                    -- (the gatling and turrets: a fast rattle)
    if ph % 1 < 0.45 then flash(0.011 * S * (0.7 + 0.6 * noise(seed + math.floor(ph))), C.flash) end
    for j = 0, 1 do
      local p = (t * 2.6 + j * 0.5 + noise(seed + 2) * 0.5) % 1
      local sx, sy, sz = at(p * reach)
      along(sx, sy, sz, 0.022 * S, 0.0028 * S, C.tracer, 0.95 - 0.6 * p)
    end
  end
end

-- Thruster plumes, every frame: each thruster group's exhaust face (the ship
-- model's THRUST lines) burns by how hard it would push - the ship's speed
-- its way, plus an idle glow while the helm is on (the lift thrusters more:
-- they hold the ship up). A face is cut into nozzles of about a dozen blocks
function ST.plumes(turn, t)
  local g, world, O = ST.geomNow, ST.world, ST.objs
  local list = g and g.sm and g.sm.thrust or {}
  local p = W() and W().pose
  local s = ST.status
  local helmOn = s and ST.statusAt and now() - ST.statusAt < ST.FRESH and s.helm == "online"
  local n = 0
  for ti, th in ipairs(list) do
    local e = ST.DIRV[th.dir]
    local push = 0
    if e and p and type(p.v) == "table" and type(p.axes) == "table" then
      local v = p.v
      local function dot(a) return a[1] * v[1] + a[2] * v[2] + a[3] * v[3] end
      -- (the way they push, in the ship's frame: against the exhaust - hologram x = r, y = u, z = -f)
      push = -e[1] * dot(p.axes.r) - e[2] * dot(p.axes.u) + e[3] * dot(p.axes.f)
    end
    local level = e and clamp((helmOn and (th.dir == "d" and 0.45 or 0.18) or 0) + math.max(0, push) / 25, 0, 1) or 0
    if level > 0.03 then
      local b = th.box
      local x0, y0, z0 = ST.toHolo(g, b[1], b[2], b[3])
      local x1, y1, z1 = ST.toHolo(g, b[4], b[5], b[6])
      local lo, hi = { math.min(x0, x1), math.min(y0, y1), math.min(z0, z1) }, { math.max(x0, x1), math.max(y0, y1), math.max(z0, z1) }
      local axis = e[1] ~= 0 and 1 or e[2] ~= 0 and 2 or 3
      local ax = {}
      for i = 1, 3 do if i ~= axis then ax[#ax + 1] = i end end
      local cuts = {}
      for k, i in ipairs(ax) do cuts[k] = clamp(math.floor((hi[i] - lo[i]) / g.k / 12 + 0.5), 1, 3) end
      for a = 1, cuts[1] do
        for c = 1, cuts[2] do
          local cell, mid = {}, { lo[1], lo[2], lo[3] }
          mid[axis] = lo[axis]
          for k, i in ipairs(ax) do
            cell[k] = math.max((hi[i] - lo[i]) / cuts[k], 0.006 * g.size)
            mid[i] = lo[i] + ((k == 1 and a or c) - 0.5) * (hi[i] - lo[i]) / cuts[k]
          end
          local L = level * 0.1 * g.size * (0.85 + 0.3 * noise(math.floor(t * 15) + ti * 13 + a * 3 + c))
          for part = 1, 2 do
            -- (a faint glow the whole length, a bright core near the nozzle)
            local long, wide = part == 1 and L or L * 0.5, part == 1 and 0.85 or 0.45
            local sz = { 0, 0, 0 }
            sz[axis] = long
            sz[ax[1]], sz[ax[2]] = cell[1] * wide, cell[2] * wide
            local px, py, pz = mid[1] + e[1] * long / 2, mid[2] + e[2] * long / 2, mid[3] + e[3] * long / 2
            n = n + 1
            local wx, wy, wz = world(px, py, pz)
            place(O.plume, n, "Box", wx, wy, wz, sz[1], sz[2], sz[3],
              { color = part == 1 and ST.COLOUR.plume or ST.COLOUR.core,
                opacity = part == 1 and 0.25 + 0.3 * level or 0.6 + 0.35 * level }, turn)
          end
        end
      end
    end
  end
  hideFrom(O.plume, n + 1)
end

-- The moving parts, every frame: weapons firing, thruster plumes, ships closing in, groups being fixed
function ST.animate()
  local g, world = ST.geomNow, ST.world
  if not (g and world) then return end
  local O, t = ST.objs, now()
  local turn = { 0, 0, 0 }
  if ST.rotNow then
    local a, b, c = W().euler(ST.rotNow)
    turn = { a, b, c }
  end
  local fi = 0
  local function fx(x, y, z, sx, sy, sz, colour, opacity)
    fi = fi + 1
    local wx, wy, wz = world(x, y, z)
    place(O.fx, fi, "Box", wx, wy, wz, sx, sy, sz, { color = colour, opacity = opacity }, turn)
  end
  for fn, f in ipairs(ST.fireList or {}) do
    local tips = ST.tips and ST.tips[f.sys]
    if not tips or #tips == 0 then
      -- (no barrels for it in the model - a carpet's bombs: from the weapon's spot, else under the ship's middle, down)
      local cr, cu, cf = ST.centre()
      local at = type(f.at) == "table" and f.at
      local r, u, ff = 0, -g.height / 2, 0
      if at then r, u, ff = (tonumber(at.r) or 0) - cr, (tonumber(at.u) or 0) - cu, (tonumber(at.f) or 0) - cf end
      local x, y, z = ST.toHolo(g, r, u, ff)
      tips = { { x, y, z, ST.DIRV.d } }
    end
    -- (at most MAX_FIRING of its barrels, spread over them)
    local step = math.max(1, #tips / ST.MAX_FIRING)
    local k, n = 1, 0
    while k <= #tips + 1e-9 and n < ST.MAX_FIRING do
      n = n + 1
      ST.shots(fx, f.kind == "rail" and "rail" or f.kind == "barrage" and "barrage" or f.kind == "carpet" and "carpet" or "gun",
        tips[math.floor(k)], fn * 31 + n * 7, t, g)
      k = k + step
    end
  end
  hideFrom(O.fx, fi + 1)
  if H.cfg.status.plumes ~= false then ST.plumes(turn, t) else hideFrom(O.plume, 1) end
  -- ships closing in pulse
  for _, o in ipairs(O.contacts) do
    if o and o.pulse and o.v.enabled then
      local sz = o.pulse * (0.8 + 0.6 * math.abs(math.sin(t * 6)))
      o:set("SizeX", sz) o:set("SizeY", sz) o:set("SizeZ", sz)
    end
  end
  -- groups being fixed pulse
  for i, p in ipairs(ST.picks or {}) do
    local o = O.groups[i]
    if p.fixing and o then o:set("Opacity", 0.4 + 0.5 * math.abs(math.sin(t * 5))) end
  end
end

---------------------------------------------------------------- picking

-- (a ray from e along d against a ball at p, radius r: how far along it hits, nil = misses)
local function rayBall(e, d, x, y, z, r)
  local cx, cy, cz = x - e[1], y - e[2], z - e[3]
  local t = cx * d[1] + cy * d[2] + cz * d[3]
  if t < 0 then return nil end
  local dd = cx * cx + cy * cy + cz * cz - t * t
  if dd > r * r then return nil end
  return t
end

-- A middle-click in the world (the keyboard module): on a damage group, pick
-- it or not; on REPAIR, send the picked ones. -> true if it was the hologram's
function ST.onWorldClick(button)
  if tonumber(button) ~= 3 or not ST.shown or not H.eye or not H.me then return false end
  local d = H.lookDir(H.me.yaw or 0, H.me.pitch or 0)
  local e = H.eye
  local best, bestT
  if ST.button then
    local t = rayBall(e, d, ST.button.x, ST.button.y, ST.button.z, ST.button.rad)
    if t then best, bestT = "repair", t end
  end
  for _, p in ipairs(ST.picks or {}) do
    local t = rayBall(e, d, p.x, p.y, p.z, p.rad)
    if t and (not bestT or t < bestT) then best, bestT = p, t end
  end
  if not best then return false end
  if best == "repair" then
    ST.sendRepair()
  else
    ST.sel[best.id] = not ST.sel[best.id] or nil
    ST.dirty = true
  end
  return true
end

-- The picked groups to the repair computer (destroyer.repair "fix")
function ST.sendRepair()
  local ids = {}
  for id in pairs(ST.sel) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
  if #ids == 0 then return end
  if not ST.repairId then
    H.toast("NO REPAIR COMPUTER ON THE NETWORK", H.C.red, 3)
    return
  end
  pcall(rednet.send, ST.repairId, { op = "fix", groups = ids }, ST.PROTO_REPAIR)
  H.toast(("REPAIR ORDERED: %d GROUP%s"):format(#ids, #ids == 1 and "" or "S"), H.C.yellow, 3)
  ST.sel, ST.dirty = {}, true
end

return ST
end
