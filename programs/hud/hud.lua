--[[
hud.lua - Helldivers 2 HUD for Advanced Peripherals smart glasses    v1.0.0
Runs on the glasses (startup.lua starts it). The glasses need the Overlay,
Keyboard and Hotkey modules, and in the upgrade slots an ender (or wireless)
modem, a speaker, a Distance Detector and a Geo Scanner.

  Hold the glasses key  (Options > Controls > Key Binds > Smart Glasses
                Hotkey: G, C, whatever it is set to) the stratagem menu.
                The ARROW KEYS enter a code (hud.cfg wasd = true: WASD too).
                A complete code calls it at once on the block you look at
                (standing on a Sable ship: on the ground under you).
  Let go        the menu closes. The keyboard stays the glasses' until Esc
                (the mod has no other way to give it back): press the key
                again for the next stratagem, Esc to get your hands back.
  Left Alt      (while the keyboard is the glasses') the 3D map: off ->
                LOCAL (16 blocks around you) -> SQUAD (zoomed out until
                every teammate fits) -> AREA (256 blocks around you, needs a
                Distant Horizons map) -> off. It stays up when you let go of
                the keyboard. Every pair of glasses scans the ground around
                its wearer and shares it with the squad, so the map is live
                around everyone; elsewhere it shows dhmap.bin, the terrain
                Distant Horizons saw (tools/dhmap.py makes it on the PC).
                High above the ground (the destroyer) heights are drawn from
                the ground's own top, so the terrain keeps its shape.
  Backspace     clear the code
  M             (while the keyboard is the glasses') the war table menu: the
                mouse picks a spot on a top-down map, turns and zooms it in
                3D, and Esc puts it on the war table; right-click on the map
                picks a target for a stratagem (war.lua; the map computer
                is warmap.lua)

Laid out as in the game: stratagems top right (a STRATAGEMS tab always
there), the health bar block bottom left (your tag, health, stims, grenades,
what is in hand) with the map above it, the squad bottom right.
The menu shows each stratagem's arrows (typed ones light up), greys out the
ones the ship cannot do now (with why), and shows your calls: queue place,
ship inbound, loading, firing countdown. A beacon (beam, icon, name, status)
stands where each call goes, yours and your squad's.
Squad: every pair of glasses shares its wearer - tag = first letter of the
name + a number in that number's colour, health, calls. Tags over teammates
show through walls at any distance.
Voice (the glasses' speaker): the stratagem's request line when the ship
takes the call, "denied" when it does not, and every fire line on every pair
of glasses.
Calls go to the destroyer's strike computer (destroyer.strike, as the pocket
remote); this computer's ID must be in strike.cfg pockets.
Files: hud.cfg (settings), hud.log, icons/*.png, voice/*.dfpwm
]]

local ARG = ...
local H = { VERSION = "1.9.0" }
H.PROTO_STRIKE = "destroyer.strike"
H.PROTO_HUD = "destroyer.hud"        -- strike -> every pair of glasses: fire lines, radar
H.PROTO_TEAM = "hd2.team"            -- glasses <-> glasses: the squad
H.HOSTNAME = "destroyer"
H.FILES = { cfg = "hud.cfg", log = "hud.log", icons = "icons", voice = "voice", dhmap = "dhmap.bin" }

H.DEFAULTS = {
  name = nil,                -- the name on your squad tag (nil: your Minecraft name)
  slot = nil,                -- your squad number 1-8 (nil: the first one free)
  hotkey = nil,              -- learnt from the glasses (the Smart Glasses Hotkey)
  mapKey = "leftAlt",        -- CC key name: map on / off while the keyboard is the glasses'
  wasd = false,              -- WASD enter codes too (off: arrows only, WASD stays for walking)
  gui = { w = 1706, h = 480 },   -- GUI size (5120x1440 at GUI scale 3); the glasses update it
  fov = 110,                 -- your Minecraft FOV (Options; Quake Pro = 110): where the 3D map lands
  menuY = 40,                -- top of the stratagem list (top right, as in the game)
  colours = { 0xF5C518, 0x3FA9F5, 0x5DD55D, 0xE06CE0, 0xFF8A3D, 0x40E0D0, 0xF0F0F0, 0xA0A0FF },
  range = 64,                -- how far the distance detector looks (the server's limit is 64)
  throw = 30,                -- nothing in reach: the call goes this far ahead
  volume = 1.0,
  tagScale = 0.0035,         -- name tag text size per block away
  -- shown at the end of the list, not callable yet: icon and arrows are ?s
  placeholders = { { name = "Titanfall", length = 6 } },
  -- the 3D map, bottom left: its centre `left` GUI px in from the 16:9 middle's
  -- left edge and `up` px up from the bottom, `px` wide, `dist` blocks from the eye
  -- scan = geo scan radius (16 is free on glasses: pocket fuel is off in this
  -- pack); share = send scans to the squad; keep = how far from you or a
  -- teammate scanned terrain is remembered; cells = map columns per side
  -- area = AREA view radius (and the SQUAD view's limit) with a Distant Horizons map
  map = { open = false, radius = 16, cell = 2, depth = 8, scan = 16, share = true, keep = 160, cells = 16, area = 256,
          squadPad = 12, left = 130, up = 150, px = 190, dist = 1.1, tilt = 50, heightScale = 1 },
  -- the health bar's counters: any part of an item's id or name (lower case)
  items = { stims = { "golden_apple", "healing", "regeneration" },
            grenades = { "splash_potion", "lingering_potion", "fire_charge", "tnt" },
            ammo = { "arrow" } },
}

-- the ship's voice lines per stratagem, for a strike that does not send them
H.VOICE = {
  ["Orbital Railcannon Strike"] = { call = "rail_request", fire = "rail_firing" },
  ["Cannon Barrage"] = { call = "barrage_request", fire = "barrage_commencing" },
  ["HE Barrage"] = { call = "barrage_he", fire = "barrage_commencing" },
  ["Napalm Barrage"] = { call = "barrage_napalm", fire = "barrage_commencing" },
  ["Gas Barrage"] = { call = "barrage_gas", fire = "barrage_commencing" },
  ["Hybrid Barrage"] = { call = "barrage_hybrid", fire = "barrage_commencing" },
  ["HE Carpet"] = { call = "carpet_he", fire = "carpet_fired" },
  ["Napalm Carpet"] = { call = "carpet_napalm", fire = "carpet_fired" },
  ["Gas Carpet"] = { call = "carpet_gas", fire = "carpet_fired" },
  ["Gatling Barrage"] = { call = "gatling_request", fire = "gatling_fired" },
  ["Escape"] = { call = "escape_call" },
}

H.ICONS = {
  ["Cannon Barrage"] = "he_barrage", ["HE Barrage"] = "he_barrage", ["Napalm Barrage"] = "napalm_barrage",
  ["Gas Barrage"] = "gas_barrage", ["Hybrid Barrage"] = "hybrid_barrage", ["HE Carpet"] = "he_carpet",
  ["Napalm Carpet"] = "napalm_carpet", ["Gas Carpet"] = "gas_carpet", ["Orbital Railcannon Strike"] = "railcannon",
  ["Gatling Barrage"] = "gatling", ["Escape"] = "escape", ["Flyover Test"] = "extraction",
}

H.C = { white = 0xFFFFFF, grey = 0x8C8C8C, dark = 0x5A5A5A, yellow = 0xFFE14D, red = 0xFF4A3D,
        green = 0x6EE07A, amber = 0xFFB020, blue = 0x55B4FF, back = 0x000000 }

H.MAP_COLOURS = {
  { "water", 0x3A6FD8 }, { "lava", 0xFF6A00 }, { "grass_block", 0x5E9E36 }, { "moss", 0x5E9E36 },
  { "leaves", 0x2F7A2F }, { "log", 0x6B4F2A }, { "wood", 0x8A6A3F }, { "plank", 0xA88654 },
  { "sand", 0xDCCB8C }, { "snow", 0xF2F2F2 }, { "ice", 0x9CC8FF }, { "dirt", 0x86603A },
  { "mud", 0x5A4A3A }, { "gravel", 0x8A8580 }, { "deepslate", 0x505058 }, { "stone", 0x8C8C8C },
  { "bedrock", 0x333333 }, { "glass", 0xBFE8F0 }, { "concrete", 0xB0B0B0 }, { "terracotta", 0xA8664A },
  { "brick", 0x9A4A3A }, { "iron", 0xC8C8C8 }, { "copper", 0xC07040 }, { "netherrack", 0x7A2A2A },
}
-- the war table (war.lua, next to this file): its settings are hud.cfg's war
do
  local ok, mod = pcall(require, "war")
  if ok and type(mod) == "function" and pcall(mod, H) and H.W then
    H.DEFAULTS.war = H.W.DEFAULTS
  else
    H.W = nil
    H.warError = tostring(mod)
  end
end
-- the ship status hologram (status.lua, next to this file; needs war.lua): hud.cfg's status
do
  local ok, mod = pcall(require, "status")
  if H.W and ok and type(mod) == "function" and pcall(mod, H) and H.ST then
    H.DEFAULTS.status = H.ST.DEFAULTS
  else
    H.ST = nil
    H.statusError = tostring(mod)
  end
end

-- plants and bits that are not the ground (the map looks under them)
H.MAP_SKIP = { "short_grass", "tall_grass", "fern", "flower", "dandelion", "poppy", "orchid", "allium",
  "tulip", "daisy", "torch", "sapling", "bush", "vine", "button", "lever", "rail", "carpet", "sign",
  "pressure_plate", "snow$", "lily", "kelp", "seagrass", "dead_bush", "rose", "peony", "lilac" }

local now = os.clock
local atan2 = math.atan2 or math.atan
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function round(v, step) step = step or 1e-3 return math.floor(v / step + 0.5) * step end
local function copy(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = copy(v) end
  return c
end

---------------------------------------------------------------- log, settings

function H.log(text)
  local ok = pcall(function()
    if fs.exists(H.FILES.log) and fs.getSize(H.FILES.log) > 32768 then
      if fs.exists(H.FILES.log .. ".old") then fs.delete(H.FILES.log .. ".old") end
      fs.move(H.FILES.log, H.FILES.log .. ".old")
    end
    local h = fs.open(H.FILES.log, "a")
    h.writeLine(("%8.1f %s"):format(now(), tostring(text)))
    h.close()
  end)
  return ok
end

function H.loadConfig()
  local cfg
  if fs.exists(H.FILES.cfg) then
    local h = fs.open(H.FILES.cfg, "r")
    cfg = textutils.unserialize(h.readAll())
    h.close()
  end
  if type(cfg) ~= "table" then cfg = {} end
  for k, v in pairs(H.DEFAULTS) do
    if cfg[k] == nil then cfg[k] = copy(v) end
  end
  for _, sec in ipairs({ "gui", "map", "items", "war", "status" }) do
    if H.DEFAULTS[sec] then
      if type(cfg[sec]) ~= "table" then cfg[sec] = {} end
      for k, v in pairs(H.DEFAULTS[sec]) do
        if cfg[sec][k] == nil then cfg[sec][k] = v end
      end
    end
  end
  H.cfg = cfg
end

function H.saveConfig()
  pcall(function()
    local h = fs.open(H.FILES.cfg, "w")
    h.write("-- hud.cfg - settings for hud.lua " .. H.VERSION .. ". Edit, save, then restart the glasses.\n")
    h.write(textutils.serialize(H.cfg))
    h.close()
  end)
end

---------------------------------------------------------------- keys

-- "key.keyboard.left.alt" (the glasses' name for a key) -> keys.leftAlt
function H.keyCode(name)
  if type(name) ~= "string" then return nil end
  local k = name:match("^key%.keyboard%.(.+)$")
  if not k then return nil end
  k = k:gsub("%.(%a)", function(c) return c:upper() end)
  return keys[k]
end

-- the key's label for the hints ("key.keyboard.g" -> "G")
function H.keyLabel(name)
  local k = type(name) == "string" and name:match("^key%.keyboard%.(.+)$")
  return k and k:gsub("%.", " "):upper() or "THE GLASSES KEY"
end

H.ARROWS = { [keys.up] = "U", [keys.down] = "D", [keys.left] = "L", [keys.right] = "R" }
H.WASD = { [keys.w] = "U", [keys.s] = "D", [keys.a] = "L", [keys.d] = "R" }

---------------------------------------------------------------- overlay objects

-- An overlay object and the values last sent to it (nothing is sent twice)
local Obj = {}
Obj.__index = Obj

local function lowerFirst(k) return k:sub(1, 1):lower() .. k:sub(2) end

function H.make(kind, props)
  if not H.ov then return nil end
  local ok, o = pcall(H.ov["create" .. kind], props)
  if not ok or type(o) ~= "table" then
    H.log(("create%s failed: %s"):format(kind, tostring(o)))
    return nil
  end
  local w = setmetatable({ o = o, v = {}, kind = kind }, Obj)
  for k, val in pairs(props) do w.v[k] = val end
  H.objs[#H.objs + 1] = w
  return w
end

-- obj:set("X", 3) calls setX(3) if x is not 3 already
function Obj:set(key, value)
  local k = lowerFirst(key)
  if self.v[k] == value then return end
  self.v[k] = value
  local f = self.o["set" .. key]
  if f then pcall(f, value) end
end

function Obj:pos(x, y, z)
  self:set("X", round(x)) self:set("Y", round(y)) if z then self:set("Z", round(z)) end
end

function Obj:show(on) self:set("Enabled", on and true or false) end

-- a setter with several values (a triangle's corners): sent when any changes
function Obj:setN(fn, ...)
  local key = table.concat({ ... }, ",")
  if self.v[fn] == key then return end
  self.v[fn] = key
  local f = self.o[fn]
  if f then pcall(f, ...) end
end

-- smooth movement for world objects: the client eases each change over n ticks
function Obj:lerp(n)
  for _, f in ipairs({ "setXLerpSteps", "setYLerpSteps", "setZLerpSteps", "setRotXLerpSteps", "setRotYLerpSteps" }) do
    if self.o[f] then pcall(self.o[f], n) end
  end
end

-- the PNG of an icon (icons/<name>.png), read once
H.png = {}
function H.iconData(name)
  if H.png[name] == nil then
    local path = fs.combine(H.FILES.icons, name .. ".png")
    local h = fs.exists(path) and fs.open(path, "rb")
    H.png[name] = h and h.readAll() or false
    if h then h.close() end
  end
  return H.png[name] or nil
end

function Obj:icon(name)
  if self.v.icon == name then return end
  self.v.icon = name
  local data = H.iconData(name) or H.iconData("generic")
  if data and self.o.load then
    local ok, err = pcall(self.o.load, data)
    if not ok then H.log("icon " .. name .. ": " .. tostring(err)) end
  end
end

function H.iconFor(name, kind)
  if H.ICONS[name] then return H.ICONS[name] end
  local n = tostring(name or ""):lower()
  local what = n:find("napalm") and "napalm" or n:find("gas") and "gas" or n:find("hybrid") and "hybrid" or "he"
  if n:find("carpet") then return (what == "hybrid" and "he" or what) .. "_carpet" end
  if n:find("barrage") or kind == "barrage" then return what .. "_barrage" end
  if n:find("rail") or kind == "rail" then return "railcannon" end
  if n:find("gatling") or kind == "gun" then return "gatling" end
  if n:find("escape") or kind == "escape" then return "escape" end
  return "generic"
end

-- GUI triangles are wound like Minecraft's own (else they may not show)
local function wind(x1, y1, x2, y2, x3, y3)
  if (x2 - x1) * (y3 - y1) - (y2 - y1) * (x3 - x1) > 0 then
    return x1, y1, x3, y3, x2, y2
  end
  return x1, y1, x2, y2, x3, y3
end

-- An arrow (U D L R) as a head + a stem, centred on cx, cy, size s
function H.arrowShape(dir, cx, cy, s)
  local h = s / 2
  local tri, stem
  if dir == "U" then
    tri = { cx, cy - h, cx - h, cy, cx + h, cy }
    stem = { cx, cy + h * 0.5, s * 0.36, h }
  elseif dir == "D" then
    tri = { cx, cy + h, cx + h, cy, cx - h, cy }
    stem = { cx, cy - h * 0.5, s * 0.36, h }
  elseif dir == "L" then
    tri = { cx - h, cy, cx, cy + h, cx, cy - h }
    stem = { cx + h * 0.5, cy, h, s * 0.36 }
  else
    tri = { cx + h, cy, cx, cy - h, cx, cy + h }
    stem = { cx - h * 0.5, cy, h, s * 0.36 }
  end
  return { wind(table.unpack(tri)) }, stem
end

function H.makeArrow(dir, cx, cy, s)
  local tri, stem = H.arrowShape(dir, cx, cy, s)
  local a = {}
  a.head = H.make("Triangle", { gui = true, x = 0, y = 0, x1 = tri[1], y1 = tri[2], x2 = tri[3], y2 = tri[4],
    x3 = tri[5], y3 = tri[6], color = H.C.white })
  a.stem = H.make("Rectangle", { gui = true, x = stem[1], y = stem[2], sizeX = stem[3], sizeY = stem[4], color = H.C.white })
  return a
end

function H.arrowSet(a, colour, opacity, on)
  for _, o in ipairs({ a.head, a.stem }) do
    if o then o:set("Color", colour) o:set("Opacity", opacity) o:show(on) end
  end
end

---------------------------------------------------------------- the target

-- Facing (MC yaw / pitch in degrees) -> unit look vector
function H.lookDir(yaw, pitch)
  local y, p = math.rad(yaw), math.rad(pitch)
  return { -math.sin(y) * math.cos(p), -math.sin(p), math.cos(y) * math.cos(p) }
end

-- A block's key in a scan's set: a number from where it is from the scan's
-- centre (no string made a block - a scan is thousands of them); nil for a
-- spot no scan can hold (over 127 away, or not a whole block): nothing there
local function bkey(s, x, y, z)
  local dx, dy, dz = x - s.ox, y - s.oy, z - s.oz
  if dx < -127 or dx > 127 or dy < -127 or dy > 127 or dz < -127 or dz > 127
    or dx % 1 ~= 0 or dy % 1 ~= 0 or dz % 1 ~= 0 then return nil end
  return ((dx + 128) * 256 + (dy + 128)) * 256 + (dz + 128)
end
H.scanKey = bkey

-- Is there a block here in the last scan? true / false, nil = not scanned
function H.blockKnown(x, y, z)
  local s = H.scan
  if not s or now() - s.at > 6 then return nil end
  if math.abs(x - s.ox) > s.r or math.abs(y - s.oy) > s.r or math.abs(z - s.oz) > s.r then return nil end
  local k = bkey(s, x, y, z)
  return k ~= nil and s.solid[k] == true
end

-- Standing on a Sable ship: nothing under the feet in the world, not falling
function H.onSable(me)
  local fx, fy, fz = math.floor(me.x), math.floor(me.y + 0.01), math.floor(me.z)
  local seen = false
  for dy = 1, 2 do
    for dx = -1, 1 do
      for dz = -1, 1 do
        local k = H.blockKnown(fx + dx, fy - dy, fz + dz)
        if k then return false end
        if k == false then seen = true end
      end
    end
  end
  return seen and (me.dy or 0) > -0.3
end

-- The ground under the wearer (the world's, not a ship's)
function H.under(me)
  local fx, fy, fz = math.floor(me.x), math.floor(me.y + 0.01), math.floor(me.z)
  local s = H.scan
  if s and now() - s.at < 6 then
    for y = fy - 1, s.oy - s.r, -1 do
      local k = bkey(s, fx, y, fz)
      if k and s.solid[k] then return { x = me.x, y = y + 1, z = me.z } end
    end
  end
  return { x = me.x, y = me.y - 1, z = me.z }
end

-- Where a call goes: the block looked at (distance detector); a Sable
-- object (a block the world does not have) or standing on a ship with
-- nothing in reach: the ground under the wearer; nothing in reach: a throw
-- ahead. d = the detector's reading (nil: nothing hit). Returns target, how
function H.aim(me, d)
  local dir = H.lookDir(me.yaw or 0, me.pitch or 0)
  local eye = { me.x, me.y + (me.eyeHeight or 1.62), me.z }
  local ship = H.onSable(me)
  if d then
    local hit = { eye[1] + dir[1] * d, eye[2] + dir[2] * d, eye[3] + dir[3] * d }
    local k = H.blockKnown(math.floor(hit[1] + dir[1] * 0.05), math.floor(hit[2] + dir[2] * 0.05),
      math.floor(hit[3] + dir[3] * 0.05))
    if k == false then return H.under(me), "under you (a Sable object)" end
    return { x = hit[1], y = hit[2], z = hit[3] }, "where you look"
  end
  if ship then return H.under(me), "under you (on a ship)" end
  local yaw = math.rad(me.yaw or 0)
  return { x = me.x - math.sin(yaw) * H.cfg.throw, y = me.y, z = me.z + math.cos(yaw) * H.cfg.throw },
    ("%d blocks ahead (nothing in reach)"):format(H.cfg.throw)
end

-- The distance detector's reading now (nil: nothing hit) - waits a tick
function H.distance()
  if not H.dd then return nil end
  local ok, d = pcall(H.dd.calculateDistance)
  d = ok and tonumber(d)
  if not d or d <= 0 or d >= H.cfg.range - 0.5 then return nil end
  return d
end

---------------------------------------------------------------- calls

H.calls = {}       -- strike mission id -> my call
H.jobs = {}
H.seq = 0

function H.toast(text, colour, secs)
  H.ui.toast = { text = text, colour = colour or H.C.white, untilT = now() + (secs or 3) }
end

function H.say(line)
  if type(line) ~= "string" or not H.speaker then return end
  if #H.voiceQ >= 3 then table.remove(H.voiceQ, 1) end
  H.voiceQ[#H.voiceQ + 1] = line
  os.queueEvent("hud_voice")
end

function H.deny(name, why)
  H.say("denied")
  H.toast(("%s DENIED - %s"):format(tostring(name or "STRATAGEM"):upper(), tostring(why or ""):upper()), H.C.red, 4)
  H.log(("denied %s: %s"):format(tostring(name), tostring(why)))
end

function H.job(kind, arg)
  H.jobs[#H.jobs + 1] = { kind = kind, arg = arg }
  os.queueEvent("hud_job")
end

-- Call stratagem s (worker: reads the wearer and the detector, both wait a
-- tick) where you look - or on `target`, a spot picked on the war table's map
function H.call(s, target)
  if not H.strike then return H.deny(s.name, "no uplink to the destroyer") end
  H.sense()
  local me = H.me
  if not me then return H.deny(s.name, "glasses not worn") end
  local t, how
  if target then
    t, how = target, ("on the map at %d %d %d"):format(math.floor(target.x), math.floor(target.y), math.floor(target.z))
  else
    -- (the war table's hologram: a target locked on it, or where you look on it)
    if H.W then
      local ok, spot, why = pcall(H.W.holoTarget, me)
      if ok and spot then
        t, how = spot, why
        H.W.holoLock = nil
      end
    end
    if not t then t, how = H.aim(me, H.distance()) end
  end
  H.seq = H.seq + 1
  local ourId = ("g%d-%d"):format(os.getComputerID(), H.seq)
  H.pending = { ourId = ourId, name = s.name, code = s.code, voice = s.voice, icon = s.icon, target = t, at = now() }
  rednet.send(H.strike, { op = "call", code = s.code, world = { x = t.x, y = t.y, z = t.z }, id = ourId }, H.PROTO_STRIKE)
  H.log(("call %s at %.1f %.1f %.1f (%s)"):format(s.name, t.x, t.y, t.z, how))
  H.toast(s.name:upper() .. " - " .. how:upper(), H.C.yellow, 2.5)
end

-- The ship's word on a call
function H.onStatus(msg)
  local c, p = H.calls[msg.id], H.pending
  if not c and p then
    if msg.id == p.ourId or (msg.id == nil and msg.done and msg.ok == false) then
      -- refused before it began (coordinates, unknown code, not allowed)
      H.pending = nil
      return H.deny(p.name, tostring(msg.text or ""):gsub("^REFUSED: ", ""))
    end
    if type(msg.id) == "number" and msg.name == p.name then
      c = { id = msg.id, name = p.name, code = p.code, voice = p.voice, icon = p.icon, target = p.target, at = now() }
      H.calls[msg.id] = c
      H.pending = nil
      H.say(c.voice and c.voice.call)           -- the ship took it: its request line
    end
  end
  if not c then
    if msg.done and msg.ok == false and msg.id == nil then H.toast(tostring(msg.text):upper(), H.C.red, 4) end
    return
  end
  c.text, c.phase = msg.text, msg.phase or c.phase
  c.queued = tostring(msg.text or ""):find("^QUEUED") ~= nil
  c.ahead = tonumber(tostring(msg.text or ""):match("(%d+) ahead")) or c.ahead
  c.dist = msg.dist
  if msg.remaining then c.endAt = now() + msg.remaining else c.endAt = nil end
  local load = tostring(msg.text or ""):match("LOADING (%d+)s")
  if load and not msg.remaining then c.endAt = now() + tonumber(load) end
  if msg.done then
    c.done, c.ok, c.doneAt = true, msg.ok ~= false, now()
    if not c.ok then H.toast(c.name:upper() .. " - " .. tostring(msg.text):upper(), H.C.red, 4) end
  end
end

-- One short status for a call (and its colour)
function H.callText(c)
  if c.done then return c.ok and "COMPLETE" or "ABORTED", c.ok and H.C.green or H.C.red end
  if c.queued then return ("QUEUED - %d AHEAD"):format(c.ahead or 0), H.C.amber end
  local left = c.endAt and math.max(0, math.ceil(c.endAt - now()))
  local text = tostring(c.text or ""):upper()
  if c.phase == "FIRE" then
    if text:find("LOADING") then return ("LOADING %ds"):format(left or 0), H.C.amber end
    return left and ("IMPACT - FIRING %ds"):format(left) or "IMPACT", H.C.red
  end
  if c.phase == "CALLED" or c.phase == "FLY" then
    return c.dist and ("INBOUND %dm"):format(math.floor(c.dist + 0.5)) or "INBOUND", H.C.yellow
  end
  if text:find("LOADING") then return ("LOADING %ds"):format(left or 0), H.C.amber end
  if text:find("LOCK") then return "WAITING FOR LOCK", H.C.amber end
  return "AIMING", H.C.yellow
end

function H.onFireLine(msg)
  H.fired = H.fired or {}
  local key = tostring(msg.id) .. ":" .. tostring(msg.line)
  if H.fired[key] and now() - H.fired[key] < 30 then return end
  H.fired[key] = now()
  H.say(msg.line)
end

-- Forget finished calls; a call the ship never answered
function H.expire()
  for id, c in pairs(H.calls) do
    if c.done and now() - c.doneAt > 6 then H.calls[id] = nil end
  end
  local p = H.pending
  if p and now() - p.at > 10 then
    H.pending = nil
    H.deny(p.name, "no answer from the destroyer")
    H.strike = nil
  end
end

---------------------------------------------------------------- the list

function H.takeList(msg)
  local list = {}
  for _, s in ipairs(type(msg.stratagems) == "table" and msg.stratagems or {}) do
    if type(s) == "table" and type(s.code) == "string" and type(s.name) == "string" then
      list[#list + 1] = { name = s.name, code = s.code, kind = s.kind, ok = s.ok ~= false, why = s.why,
        voice = type(s.voice) == "table" and s.voice or H.VOICE[s.name] or {}, icon = H.iconFor(s.name, s.kind) }
    end
  end
  -- placeholders: no code (typing never reaches them), ? arrows, ? icon
  for _, p in ipairs(type(H.cfg.placeholders) == "table" and H.cfg.placeholders or {}) do
    if type(p) == "table" and p.name then
      list[#list + 1] = { name = tostring(p.name), code = "", placeholder = true, length = tonumber(p.length) or 6,
        ok = true, voice = {}, icon = "unknown" }
    end
  end
  local sig = {}
  for _, s in ipairs(list) do sig[#sig + 1] = s.name .. "=" .. s.code end
  sig = table.concat(sig, ";")
  H.list, H.listAt = list, now()
  if sig ~= H.listSig then
    H.listSig = sig
    H.log(("list: %d stratagems"):format(#list))
    H.needRebuild = true
  end
end

---------------------------------------------------------------- the menu

function H.layout()
  local w, h = H.cfg.gui.w, H.cfg.gui.h
  local safe = math.max(8, math.floor((w - h * 16 / 9) / 2))
  H.L = { w = w, h = h, left = safe + 14, right = w - safe - 14, cx = math.floor(w / 2) }
end

H.ROW = 26
H.ARROW = 11

-- (built by H.rebuild: a new list rebuilds the whole overlay)
function H.buildMenu()
  local m = { rows = {}, all = {} }
  H.menu = m
  local function keep(o) if o then m.all[#m.all + 1] = o end return o end
  local width = 250
  local x0, y0, list = H.L.right - width, H.cfg.menuY, H.list or {}
  local rows = math.max(1, #list)
  -- the tab that is always there (top right, as in the game): the key + STRATAGEMS
  m.tabBack = H.make("Rectangle", { gui = true, x = x0 + 46, y = y0 - 13, sizeX = 92, sizeY = 11,
    color = H.C.back, opacity = 0.4 })
  m.tabKey = H.make("Rectangle", { gui = true, x = x0 + 6, y = y0 - 13, sizeX = 9, sizeY = 9, color = 0xE8E8E8 })
  m.tabKeyText = H.make("Text", { gui = true, x = x0 + 6, y = y0 - 16, content = H.keyLabel(H.cfg.hotkey):sub(1, 1),
    center = true, color = 0x111111, fontSize = 0.75 })
  m.tabText = H.make("Text", { gui = true, x = x0 + 14, y = y0 - 17, content = "STRATAGEMS", shadow = true,
    color = 0xF2EBD0, fontSize = 0.8 })
  m.back = keep(H.make("Rectangle", { gui = true, x = x0 + width / 2 - 4, y = y0 + rows * H.ROW / 2 - 2,
    sizeX = width + 8, sizeY = rows * H.ROW + 8, color = H.C.back, opacity = 0.35 }))
  m.info = keep(H.make("Text", { gui = true, x = x0, y = y0 + 4, content = "", color = H.C.grey, shadow = true }))
  for i, s in ipairs(list) do
    local top = y0 + (i - 1) * H.ROW
    local r = { s = s, arrows = {} }
    r.icon = keep(H.make("Texture", { gui = true, x = x0, y = top + 1, sizeX = 22, sizeY = 22 }))
    if r.icon then r.icon:icon(s.icon) end
    r.name = keep(H.make("Text", { gui = true, x = x0 + 27, y = top + 2, content = s.name:upper(),
      color = H.C.white, shadow = true }))
    for j = 1, #s.code do
      local a = H.makeArrow(s.code:sub(j, j), x0 + 31 + (j - 1) * H.ARROW, top + 17, 8)
      keep(a.head) keep(a.stem)
      r.arrows[j] = a
    end
    r.marks = {}
    for j = 1, s.placeholder and s.length or 0 do
      r.marks[j] = keep(H.make("Text", { gui = true, x = x0 + 31 + (j - 1) * H.ARROW, y = top + 13, content = "?",
        center = true, color = H.C.white, shadow = true }))
    end
    local slots = s.placeholder and s.length or #s.code
    r.status = keep(H.make("Text", { gui = true, x = x0 + 31 + slots * H.ARROW + 2, y = top + 13,
      content = "", color = H.C.grey, shadow = true, fontSize = 0.8 }))
    m.rows[i] = r
  end
  for _, o in ipairs(m.all) do o:show(false) end
  H.menuUpdate()
end

-- Newest call of mine for stratagem `name`
function H.callFor(name)
  local best
  for _, c in pairs(H.calls) do
    if c.name == name and (not best or c.at > best.at) then best = c end
  end
  return best
end

function H.menuUpdate()
  local m = H.menu
  if not m then return end
  local open, input = H.ui.open, H.ui.input
  if m.back then m.back:show(open) end
  if m.info then
    local text = not H.strike and "NO UPLINK - SEARCHING FOR THE DESTROYER"
      or not H.list and "CONNECTING TO THE DESTROYER" or #H.list == 0 and "NO STRATAGEMS" or ""
    m.info:set("Content", text)
    m.info:show(open and text ~= "")
  end
  for _, r in ipairs(m.rows) do
    local s = r.s
    local match = s.code:sub(1, #input) == input
    local fade = match and 1 or 0.3
    local avail = s.ok
    if r.icon then r.icon:set("Opacity", avail and fade or 0.35 * fade) r.icon:show(open) end
    if r.name then
      r.name:set("Color", avail and H.C.white or H.C.grey)
      r.name:set("Opacity", fade)
      r.name:show(open)
    end
    for j, a in ipairs(r.arrows) do
      local typed = match and j <= #input
      H.arrowSet(a, typed and H.C.yellow or (avail and H.C.white or H.C.dark), fade, open)
    end
    for _, q in ipairs(r.marks or {}) do
      q:set("Opacity", fade)
      q:show(open)
    end
    if r.status then
      local text, colour = "", H.C.grey
      local c = H.callFor(s.name)
      if c then
        text, colour = H.callText(c)
      elseif H.pending and H.pending.name == s.name then
        text, colour = "CALLING", H.C.yellow
      elseif not avail then
        text, colour = "UNAVAILABLE - " .. tostring(s.why or ""):upper():sub(1, 34), H.C.red
      end
      r.status:set("Content", text)
      r.status:set("Color", colour)
      r.status:set("Opacity", fade)
      r.status:show(open and text ~= "")
    end
  end
end

function H.openMenu()
  if not H.ui.open then
    H.ui.open, H.ui.input, H.ui.openedAt = true, "", now()
    if not H.list or now() - (H.listAt or -100) > 3 then H.wantList = true end
  end
  H.menuUpdate()
end

function H.closeMenu()
  if H.ui.open then
    H.ui.open, H.ui.input = false, ""
    H.menuUpdate()
  end
end

-- One arrow typed; target = a spot picked on the war table's map (else the
-- call goes where you look). -> "called", "denied", "typing", "wrong", "offline"
function H.addArrow(a, target)
  if not H.list then
    H.toast(H.strike and "CONNECTING TO THE DESTROYER" or "NO UPLINK", H.C.red, 2)
    return "offline"
  end
  local input = H.ui.input .. a
  local any, hit = false, nil
  for _, s in ipairs(H.list) do
    if s.code == input then hit = s end
    if s.code:sub(1, #input) == input then any = true end
  end
  local result
  if hit then
    H.ui.input = ""
    if hit.placeholder or not hit.ok then
      H.deny(hit.name, hit.why or "unavailable")
      result = "denied"
    elseif target then
      H.job("mapcall", { s = hit, target = target })
      result = "called"
    else
      H.job("call", hit)
      result = "called"
    end
  elseif any then
    H.ui.input = input
    result = "typing"
  else
    H.ui.input = ""                 -- a wrong arrow: start again, as in the game
    result = "wrong"
  end
  H.menuUpdate()
  return result
end

---------------------------------------------------------------- squad

H.team = {}
H.TEAM_FRESH = 6

function H.myName()
  local n = H.cfg.name or (H.me and H.me.name) or "Diver"
  return tostring(n)
end

function H.tagOf(name, slot) return tostring(name):sub(1, 1):upper() .. tostring(slot or "?") end
function H.colourOf(slot) local c = H.cfg.colours return c[((slot or 1) - 1) % #c + 1] end

-- My squad number: hud.cfg slot, else the one I have, else the first free
-- (two on one number: the lower computer ID keeps it)
function H.pickSlot()
  if H.cfg.slot then return H.cfg.slot end
  local used, me = {}, os.getComputerID()
  for id, m in pairs(H.team) do
    if now() - m.at < H.TEAM_FRESH and m.slot then
      if not used[m.slot] or id < used[m.slot] then used[m.slot] = id end
    end
  end
  if H.slot and (not used[H.slot] or used[H.slot] > me) then return H.slot end
  for n = 1, 8 do
    if not used[n] then return n end
  end
  return 1
end

function H.onTeam(from, msg)
  local m = H.team[from] or {}
  H.team[from] = m
  m.id, m.at = from, now()
  m.name, m.slot = tostring(msg.name or "?"), tonumber(msg.slot)
  m.user = type(msg.user) == "string" and msg.user or nil
  m.uuid = type(msg.uuid) == "string" and msg.uuid or nil
  m.x, m.y, m.z = tonumber(msg.x), tonumber(msg.y), tonumber(msg.z)
  m.health, m.max = tonumber(msg.health) or 0, tonumber(msg.max) or 20
  m.dead, m.reinforcing = msg.dead == true, msg.reinforcing == true
  m.dim = msg.dim
  m.calls = type(msg.calls) == "table" and msg.calls or {}
end

-- My calls for my squad's beacons
function H.myBeacons()
  local out = {}
  local function add(name, icon, t, text, colour)
    if t then out[#out + 1] = { n = name, i = icon, x = t.x, y = t.y, z = t.z, t = text, c = colour } end
  end
  if H.pending then add(H.pending.name, H.pending.icon, H.pending.target, "CALLING", H.C.yellow) end
  for _, c in pairs(H.calls) do
    local text, colour = H.callText(c)
    add(c.name, c.icon, c.target, text, colour)
  end
  return out
end

-- Tell the squad where I am (every 0.25 s, from the worker)
function H.broadcast()
  local me = H.me
  if not me or not H.modem then return end
  if now() - (H.started or 0) > 1.5 then H.slot = H.pickSlot() end
  if not H.slot then return end
  -- (user, uuid: the Minecraft name and id - the maps name you by them, and know you on the radar)
  rednet.broadcast({ op = "hi", v = 1, name = H.myName(), slot = H.slot, user = me.user, uuid = me.uuid,
    x = me.x, y = me.y + (me.eyeHeight or 1.62), z = me.z, dim = me.dim,
    health = me.health, max = me.maxHealth, dead = (me.health or 1) <= 0, reinforcing = false,
    calls = H.myBeacons() }, H.PROTO_TEAM)
end

---------------------------------------------------------------- world objects

-- Turn a world object at p to face the wearer (yaw then pitch, like a name tag)
function H.face(o, px, py, pz)
  local e = H.eye
  if not e or not o then return 0, 0 end
  local dx, dy, dz = px - e[1], py - e[2], pz - e[3]
  local yaw = math.deg(atan2(-dx, dz))
  local pitch = math.deg(atan2(-dy, math.sqrt(dx * dx + dz * dz)))
  local ry, rx = round(180 - yaw, 0.5), round(-pitch, 0.5)
  o:set("RotY", ry)
  o:set("RotX", rx)
  return ry, rx
end

local function dist3(e, x, y, z)
  if not e then return 0 end
  return math.sqrt((x - e[1]) ^ 2 + (y - e[2]) ^ 2 + (z - e[3]) ^ 2)
end

-- A world texture of size s centred on p, facing the wearer (a texture's
-- corner is its bottom-left: move it back half a size along its own axes)
function H.placeIcon(o, px, py, pz, s)
  local ry, rx = H.face(o, px, py, pz)
  local a, b = math.rad(ry), math.rad(rx)
  local rX, rZ = math.cos(a), -math.sin(a)
  local uX, uY, uZ = math.sin(a) * math.sin(b), math.cos(b), math.cos(a) * math.sin(b)
  o:set("SizeX", round(s, 0.01)) o:set("SizeY", round(s, 0.01))
  o:pos(px - s / 2 * (rX + uX), py - s / 2 * uY, pz - s / 2 * (rZ + uZ))
end

function H.buildWorld()
  H.tags, H.beacons = {}, {}
  for i = 1, 8 do
    local t = H.make("Text", { x = 0, y = -1000, z = 0, content = "", center = true, depthTest = false,
      culling = false, shadow = false, fontSize = 0.05, color = H.C.white })
    if t then t:lerp(2) t:show(false) end
    H.tags[i] = t
  end
  for i = 1, 6 do
    local b = {}
    b.beam = H.make("Box", { x = 0, y = -1000, z = 0, sizeX = 0.3, sizeY = 64, sizeZ = 0.3, color = H.C.red, opacity = 0.45 })
    b.label = H.make("Text", { x = 0, y = -1000, z = 0, content = "", center = true, depthTest = false,
      culling = false, fontSize = 0.05, color = H.C.white })
    b.icon = H.make("Texture", { x = 0, y = -1000, z = 0, sizeX = 1, sizeY = 1, depthTest = false, culling = false })
    for _, o in pairs(b) do o:lerp(2) o:show(false) end
    H.beacons[i] = b
  end
end

-- Name tags over teammates: tag + distance, through walls, the same size on
-- screen at any distance
function H.drawTags()
  local i = 0
  for _, m in pairs(H.team) do
    if i < #H.tags and now() - m.at < H.TEAM_FRESH and m.x and (not m.dim or not H.me or m.dim == H.me.dim) then
      i = i + 1
      local t = H.tags[i]
      if t then
        local d = dist3(H.eye, m.x, m.y, m.z)
        local fsz = clamp(d * H.cfg.tagScale, 0.012, 4)
        local tag = H.tagOf(m.name, m.slot)
        t:set("Content", m.dead and (tag .. "  KIA") or ("%s  %dm"):format(tag, math.floor(d + 0.5)))
        t:set("Color", m.dead and H.C.grey or H.colourOf(m.slot))
        t:set("FontSize", round(fsz, 0.002))
        local y = m.y + 0.55 + fsz * 8
        t:pos(m.x, y, m.z)
        H.face(t, m.x, y, m.z)
        t:show(true)
      end
    end
  end
  for j = i + 1, #H.tags do if H.tags[j] then H.tags[j]:show(false) end end
end

-- Beacons where calls go: beam, icon, name and status
function H.drawBeacons()
  local list = H.myBeacons()
  for _, m in pairs(H.team) do
    if now() - m.at < H.TEAM_FRESH then
      for _, c in ipairs(m.calls or {}) do list[#list + 1] = c end
    end
  end
  for i, b in ipairs(H.beacons) do
    local c = list[i]
    if c and tonumber(c.x) then
      local x, y, z = c.x, c.y, c.z
      local d = dist3(H.eye, x, y, z)
      local live = c.c ~= H.C.green and c.c ~= H.C.red
      if b.beam then
        b.beam:pos(x, y + 32, z)
        b.beam:set("Color", live and 0xFF3B2F or c.c)
        b.beam:show(true)
      end
      local fsz = clamp(d * 0.0045, 0.015, 4)
      local ly = y + 2 + fsz * 10
      if b.label then
        b.label:set("Content", ("%s  %s"):format(tostring(c.n):upper(), tostring(c.t or "")))
        b.label:set("Color", c.c or H.C.white)
        b.label:set("FontSize", round(fsz, 0.002))
        b.label:pos(x, ly, z)
        H.face(b.label, x, ly, z)
        b.label:show(true)
      end
      if b.icon then
        local s = round(clamp(d * 0.05, 0.8, 40), 0.05)
        b.icon:icon(c.i or "generic")
        H.placeIcon(b.icon, x, ly + s * 0.65, z, s)
        b.icon:show(true)
      end
    else
      for _, o in pairs(b) do o:show(false) end
    end
  end
end

---------------------------------------------------------------- squad list, hints

-- The squad (teammates; you are in the health bar): bottom right
function H.buildPanel()
  H.panel = {}
  local x, y = H.L.right - 180, H.L.h - 90
  for i = 1, 4 do
    local top = y + (i - 1) * 14
    local p = {}
    p.tag = H.make("Text", { gui = true, x = x, y = top, content = "", shadow = true })
    p.name = H.make("Text", { gui = true, x = x + 20, y = top + 1, content = "", shadow = true, fontSize = 0.8,
      color = H.C.white })
    p.bar = H.make("Rectangle", { gui = true, x = x + 20 + 40, y = top + 11, sizeX = 80, sizeY = 2,
      color = H.C.back, opacity = 0.6 })
    p.fill = H.make("Rectangle", { gui = true, x = x + 20 + 40, y = top + 11, sizeX = 80, sizeY = 2,
      color = H.C.green })
    p.state = H.make("Text", { gui = true, x = x + 106, y = top + 1, content = "", shadow = true, fontSize = 0.8 })
    for _, o in pairs(p) do o:show(false) end
    H.panel[i] = p
  end
  H.hint = H.make("Text", { gui = true, x = H.L.cx, y = H.L.h - 100, content = "", center = true, shadow = true,
    color = H.C.grey, fontSize = 0.8 })
  H.toastText = H.make("Text", { gui = true, x = H.L.cx, y = math.floor(H.L.h * 0.62), content = "",
    center = true, shadow = true, fontSize = 1.25 })
  if H.hint then H.hint:show(false) end
  if H.toastText then H.toastText:show(false) end
end

function H.drawPanel()
  local rows = {}
  for _, m in pairs(H.team) do
    if now() - m.at < 30 then
      rows[#rows + 1] = { name = m.name, slot = m.slot, health = m.health, max = m.max, dead = m.dead,
        reinforcing = m.reinforcing, lost = now() - m.at > H.TEAM_FRESH }
    end
  end
  table.sort(rows, function(a, b) return (a.slot or 99) < (b.slot or 99) end)
  for i, p in ipairs(H.panel or {}) do
    local r = rows[i]
    if r then
      local colour = H.colourOf(r.slot)
      p.tag:set("Content", H.tagOf(r.name, r.slot))
      p.tag:set("Color", colour)
      p.name:set("Content", tostring(r.name):sub(1, 14))
      local frac = clamp((r.health or 0) / math.max(1, r.max or 20), 0, 1)
      local w = round(80 * frac, 0.5)
      local left = H.L.right - 180 + 20
      p.fill:set("SizeX", w)
      p.fill:pos(left + w / 2, p.fill.v.y)
      p.fill:set("Color", frac > 0.5 and H.C.green or frac > 0.25 and H.C.amber or H.C.red)
      local state, sc = "", H.C.grey
      if r.lost then state, sc = "SIGNAL LOST", H.C.grey
      elseif r.reinforcing then state, sc = "REINFORCING", H.C.blue
      elseif r.dead then state, sc = "KIA", H.C.red end
      p.state:set("Content", state)
      p.state:set("Color", sc)
      for _, o in pairs(p) do o:show(true) end
      p.fill:show(not r.dead and not r.lost and frac > 0)
      p.state:show(state ~= "")
    else
      for _, o in pairs(p) do o:show(false) end
    end
  end
end

-- The health bar block, bottom left as in the game:
--     [G] grenade x4  |  what is in hand           (top row)
--   > [H1] [=========== health ===========] stim x3  (bottom row)
-- Minecraft stand-ins: grenades = splash potions, fire charges, TNT; stims =
-- golden apples, healing / regeneration potions; magazines = arrows (shown
-- with a bow or crossbow in hand) - hud.cfg items
local TIMES = "\215"            -- (the multiplication sign; the glasses' text is Latin-1)
local CREAM = 0xF2EBD0

function H.buildVitals()
  local x0, a, b = H.L.left, H.L.h - 58, H.L.h - 42
  local v = {}
  -- the bracket down the left, and the little arrow at the health row
  v.side = H.make("Rectangle", { gui = true, x = x0 - 8, y = a + 12, sizeX = 1, sizeY = 30, color = CREAM, opacity = 0.5 })
  v.tickA = H.make("Rectangle", { gui = true, x = x0 - 6.5, y = a - 3, sizeX = 4, sizeY = 1, color = CREAM, opacity = 0.5 })
  v.tickB = H.make("Rectangle", { gui = true, x = x0 - 6.5, y = b + 12, sizeX = 4, sizeY = 1, color = CREAM, opacity = 0.5 })
  local p1x, p1y, p2x, p2y, p3x, p3y = wind(x0 - 5, b + 1, x0 - 5, b + 7, x0 - 2, b + 4)
  v.point = H.make("Triangle", { gui = true, x = 0, y = 0, x1 = p1x, y1 = p1y, x2 = p2x, y2 = p2y, x3 = p3x, y3 = p3y,
    color = H.C.grey })
  -- top row: grenades | what is in hand
  v.gKey = H.make("Rectangle", { gui = true, x = x0 + 4, y = a + 4, sizeX = 8, sizeY = 8, color = 0xE8E8E8 })
  v.gKeyText = H.make("Text", { gui = true, x = x0 + 4, y = a + 1, content = "G", center = true, color = 0x111111,
    fontSize = 0.7 })
  v.grenade = H.make("Texture", { gui = true, x = x0 + 11, y = a - 1, sizeX = 8, sizeY = 10 })
  if v.grenade then v.grenade:icon("hud_grenade") end
  v.grenades = H.make("Text", { gui = true, x = x0 + 20, y = a + 1, content = "", color = CREAM, shadow = true,
    fontSize = 0.85 })
  v.sep = H.make("Rectangle", { gui = true, x = x0 + 44, y = a + 4, sizeX = 1, sizeY = 9, color = CREAM, opacity = 0.5 })
  v.mag = H.make("Texture", { gui = true, x = x0 + 50, y = a - 1, sizeX = 6, sizeY = 10 })
  if v.mag then v.mag:icon("hud_mag") end
  v.held = H.make("Text", { gui = true, x = x0 + 50, y = a + 1, content = "", color = CREAM, shadow = true,
    fontSize = 0.85 })
  -- bottom row: your tag, the health bar between brackets, stims
  v.tagBox = H.make("Rectangle", { gui = true, x = x0 + 11, y = b + 4, sizeX = 22, sizeY = 11, color = H.C.amber })
  v.tagIn = H.make("Rectangle", { gui = true, x = x0 + 11, y = b + 4, sizeX = 20, sizeY = 9, color = 0x140C08 })
  v.tag = H.make("Text", { gui = true, x = x0 + 11, y = b + 1, content = "", center = true, color = H.C.amber,
    fontSize = 0.9 })
  local bx = x0 + 28
  v.lb = H.make("Rectangle", { gui = true, x = bx, y = b + 4, sizeX = 1, sizeY = 9, color = CREAM, opacity = 0.7 })
  v.back = H.make("Rectangle", { gui = true, x = bx + 57, y = b + 4, sizeX = 110, sizeY = 5, color = H.C.back,
    opacity = 0.5 })
  v.fill = H.make("Rectangle", { gui = true, x = bx + 57, y = b + 4, sizeX = 110, sizeY = 5, color = CREAM })
  v.rb = H.make("Rectangle", { gui = true, x = bx + 114, y = b + 4, sizeX = 1, sizeY = 9, color = CREAM, opacity = 0.7 })
  v.stim = H.make("Texture", { gui = true, x = bx + 120, y = b, sizeX = 16, sizeY = 8 })
  if v.stim then v.stim:icon("hud_stim") end
  v.stims = H.make("Text", { gui = true, x = bx + 138, y = b + 1, content = "", color = CREAM, shadow = true,
    fontSize = 0.85 })
  H.vitals = { o = v, fillLeft = bx + 2, fillY = b + 4, heldX = x0 + 50, heldY = a + 1 }
end

-- What the wearer carries, for the health bar (from getOwner's inventory)
function H.kit(owner)
  local out = { stims = 0, grenades = 0, arrows = 0 }
  local inv, it = owner.inventory, H.cfg.items or {}
  if type(inv) ~= "table" then return out end
  local function is(list, s)
    for _, p in ipairs(list or {}) do
      if s:find(p, 1, true) then return true end
    end
    return false
  end
  for _, item in pairs(inv) do
    if type(item) == "table" then
      local s = (tostring(item.name) .. " " .. tostring(item.displayName)):lower()
      local n = tonumber(item.count) or 1
      if is(it.stims, s) then out.stims = out.stims + n
      elseif is(it.grenades, s) then out.grenades = out.grenades + n
      elseif is(it.ammo, s) then out.arrows = out.arrows + n end
    end
  end
  local slot = tonumber(owner.handSlot)
  local held = slot and (inv[slot] or inv[tostring(slot)])
  if type(held) == "table" then
    out.held = (tostring(held.displayName or held.name):gsub("^%[", ""):gsub("%]$", ""))
    out.heldCount = tonumber(held.count) or 1
    out.heldId = tostring(held.name)
  end
  return out
end

function H.drawVitals()
  local V, me = H.vitals, H.me
  if not V then return end
  local v = V.o
  for _, o in pairs(v) do o:show(me ~= nil) end
  if not me then return end
  local frac = clamp((me.health or 0) / math.max(1, me.maxHealth or 20), 0, 1)
  local w = round(110 * frac, 0.5)
  if v.fill then
    v.fill:set("SizeX", w)
    v.fill:pos(V.fillLeft + w / 2, V.fillY)
    v.fill:set("Color", frac > 0.5 and CREAM or H.C.red)     -- red under half, as in the game
    v.fill:show(w > 0)
  end
  local colour = H.slot and H.colourOf(H.slot) or H.C.amber
  if v.tag then v.tag:set("Content", H.tagOf(H.myName(), H.slot)) v.tag:set("Color", colour) end
  if v.tagBox then v.tagBox:set("Color", colour) end
  local kit = me.kit or {}
  if v.grenades then v.grenades:set("Content", TIMES .. (kit.grenades or 0)) end
  if v.stims then v.stims:set("Content", TIMES .. (kit.stims or 0)) end
  if v.held then
    local id = tostring(kit.heldId or "")
    local ranged = id:find("bow") ~= nil
    if v.mag then v.mag:show(ranged) end
    if ranged then
      v.held:pos(V.heldX + 8, V.heldY)
      v.held:set("Content", TIMES .. (kit.arrows or 0) .. "  " .. tostring(kit.held):upper())
    else
      v.held:pos(V.heldX, V.heldY)
      v.held:set("Content", kit.held and (tostring(kit.held):upper()
        .. ((kit.heldCount or 1) > 1 and ("  " .. TIMES .. kit.heldCount) or "")) or "")
    end
  end
end

function H.drawHint()
  if H.hint then
    local key = H.keyLabel(H.cfg.hotkey)
    local mk = tostring(H.cfg.mapKey):gsub("(%l)(%u)", "%1 %2"):upper()
    local on = H.ui.capture and not H.ui.open and not (H.W and H.W.menu.open)
    local war = H.W and ("    [%s] WAR TABLE"):format(tostring(H.cfg.war.key):upper()) or ""
    H.hint:set("Content", ("[ESC] HANDS BACK    [%s] STRATAGEMS    [%s] MAP%s"):format(key, mk, war))
    H.hint:show(on)
  end
  local t = H.ui.toast
  if H.toastText then
    if t and now() < t.untilT then
      H.toastText:set("Content", t.text)
      H.toastText:set("Color", t.colour)
      H.toastText:show(true)
    else
      H.toastText:show(false)
    end
  end
end

---------------------------------------------------------------- the map

H.cols = {}         -- "x,z" -> { y = top block, c = its map colour, x, z }
H.mapState = { built = false }

-- (a radius-16 scan is ~17,000 blocks of a few dozen kinds: remember answers)
H.skipCache, H.colourCache = {}, {}

function H.mapSkip(name)
  local n = tostring(name)
  local hit = H.skipCache[n]
  if hit ~= nil then return hit end
  hit = false
  for _, p in ipairs(H.MAP_SKIP) do
    if n:find(p) then hit = true break end
  end
  H.skipCache[n] = hit
  return hit
end

H.GREY = 0x9A9A9A

-- A block's map colour index (H.MAP_COLOURS; 0 = plain grey)
function H.colourIndex(name)
  local n = tostring(name)
  local i = H.colourCache[n]
  if i then return i end
  i = 0
  for k, c in ipairs(H.MAP_COLOURS) do
    if n:find(c[1], 1, true) then i = k break end
  end
  H.colourCache[n] = i
  return i
end

function H.indexColour(i)
  local c = H.MAP_COLOURS[i]
  return c and c[2] or H.GREY
end

function H.blockColour(name) return H.indexColour(H.colourIndex(name)) end

-- Replace the columns of a square (2r+1 wide around ox, oz) with tops
-- ("x,z" -> { y, i = colour index, n = block }; missing = nothing there)
local function putColumns(ox, oz, r, tops)
  for dx = -r, r do
    for dz = -r, r do
      local x, z = ox + dx, oz + dz
      local k = x .. "," .. z
      local t = tops[k]
      H.cols[k] = t and { y = t.y, c = H.indexColour(t.i), b = t.n, x = x, z = z } or nil
    end
  end
  H.mapDirty = true
end

-- A geo scan -> the scan set and the top of every column it covered. The
-- glasses' scanner measures from the wearer's EYE (its owner's position),
-- not the feet: each block's x y z = the block's middle - the eye, so
-- fractions (AP 0.8: x = bx + 0.5 - eye.x) - the block is floor(eye + x)
function H.takeScan(res, me, r)
  local ex, ey, ez = me.x, me.y + (me.eyeHeight or 1.62), me.z
  local floor = math.floor
  local ox, oy, oz = floor(ex), floor(ey), floor(ez)
  local scan = { ox = ox, oy = oy, oz = oz, r = r }
  local solid, best, skip = {}, {}, {}
  -- (numbers for keys while going through the blocks; each column's top
  -- becomes an "x,z" entry once, at the end)
  for _, b in ipairs(res) do
    local x, y, z = floor(ex + b.x), floor(ey + b.y), floor(ez + b.z)
    local k = bkey(scan, x, y, z)
    if k then solid[k] = true end
    local name = b.name
    local sk = skip[name]
    if sk == nil then sk = H.mapSkip(name) skip[name] = sk end
    if not sk then
      local ck = (x - ox) * 65536 + (z - oz)
      local t = best[ck]
      if not t or y > t.y then best[ck] = { y = y, n = name, x = x, z = z } end
    end
  end
  local tops = {}
  for _, t in pairs(best) do tops[t.x .. "," .. t.z] = { y = t.y, n = t.n, i = H.colourIndex(t.n) } end
  scan.at, scan.solid = now(), solid
  H.scan = scan
  -- every column the scan covered is replaced (a block gone is gone)
  putColumns(ox, oz, r, tops)
  H.shareTerrain(ox, oy, oz, r, tops)
  H.scans = (H.scans or 0) + 1
  if H.scans % 20 == 0 then H.pruneColumns() end
end

-- My scan for the squad (and the war table's map computer, which keeps
-- them): 2 bytes a column (height above the scan's bottom + 1, 0 = nothing;
-- the block, an index into names), row by row - 2.2 KB at radius 16
function H.shareTerrain(ox, oy, oz, r, tops)
  if not H.cfg.map.share or not H.modem then return end
  local out, names, idx = {}, {}, {}
  for dx = -r, r do
    for dz = -r, r do
      local t = tops[(ox + dx) .. "," .. (oz + dz)]
      local h = t and clamp(t.y - oy + r + 1, 1, 2 * r + 1) or 0
      local i = 0
      if t then
        i = idx[t.n]
        if not i and #names < 255 then
          names[#names + 1] = t.n
          i = #names
          idx[t.n] = i
        end
      end
      out[#out + 1] = string.char(h, i or 0)
    end
  end
  pcall(rednet.broadcast, { op = "terrain", v = 2, ox = ox, oy = oy, oz = oz, r = r, d = table.concat(out), names = names },
    H.PROTO_TEAM)
end

-- A teammate's scan (v1: the second byte was a map colour index)
function H.takeTerrain(msg)
  local ox, oy, oz, r, d = tonumber(msg.ox), tonumber(msg.oy), tonumber(msg.oz), tonumber(msg.r), msg.d
  if not (ox and oy and oz and r) or type(d) ~= "string" or r < 1 or r > 64 or #d ~= 2 * (2 * r + 1) ^ 2 then return end
  local names = msg.v == 2 and type(msg.names) == "table" and msg.names or nil
  local tops, p = {}, 1
  for dx = -r, r do
    for dz = -r, r do
      local h, i = d:byte(p, p + 1)
      p = p + 2
      if h > 0 then
        local name = names and names[i]
        tops[(ox + dx) .. "," .. (oz + dz)] = { y = oy + h - r - 1, i = name and H.colourIndex(name) or (names and 0 or i),
          n = name and tostring(name) or nil }
      end
    end
  end
  putColumns(ox, oz, r, tops)
end

-- Forget terrain far from me and from every teammate (memory)
function H.pruneColumns()
  local keep, near = H.cfg.map.keep, {}
  if H.me then near[1] = H.me end
  for _, m in pairs(H.team) do
    if m.x and now() - m.at < 60 then near[#near + 1] = m end
  end
  if #near == 0 then return end
  for k, c in pairs(H.cols) do
    local kept = false
    for _, p in ipairs(near) do
      if math.abs(c.x - p.x) <= keep and math.abs(c.z - p.z) <= keep then kept = true break end
    end
    if not kept then H.cols[k] = nil end
  end
end

-- Distant Horizons' terrain (dhmap.bin, made on the PC by tools/dhmap.py
-- from DH's own database): the map's base layer wherever no helldiver has
-- scanned lately
function H.loadDh(path)
  path = path or H.FILES.dhmap
  if not fs.exists(path) then return false end
  local f = fs.open(path, "rb")
  local raw = f.readAll()
  f.close()
  local l1 = raw and raw:find("\n", 1, true)
  local l2 = l1 and raw:find("\n", l1 + 1, true)
  if not l2 then return false end
  local ver, x0, z0, cell, w, h, base = raw:sub(1, l1 - 1):match("^DHMAP([12]) (%-?%d+) (%-?%d+) (%d+) (%d+) (%d+) (%-?%d+)$")
  if not x0 then return false end
  -- (DHMAP2: two bytes of height - ground more than 255 blocks from bottom to top)
  local dh = { x0 = tonumber(x0), z0 = tonumber(z0), cell = tonumber(cell), w = tonumber(w), h = tonumber(h),
    base = tonumber(base), colour = {}, data = raw:sub(l2 + 1), per = ver == "2" and 3 or 2 }
  if #dh.data < dh.per * dh.w * dh.h then return false end
  local i = 0
  for name in raw:sub(l1 + 1, l2 - 1):gmatch("[^,]+") do
    i = i + 1
    dh.colour[i] = H.blockColour(name)
  end
  H.dh = dh
  H.log(("Distant Horizons map: %dx%d cells of %d from %d,%d"):format(dh.w, dh.h, dh.cell, dh.x0, dh.z0))
  return true
end

function H.dhTop(x, z)
  local d = H.dh
  if not d then return nil end
  local ix, iz = math.floor((x - d.x0) / d.cell), math.floor((z - d.z0) / d.cell)
  if ix < 0 or iz < 0 or ix >= d.w or iz >= d.h then return nil end
  local k = d.per * (ix * d.h + iz) + 1
  local hb, p
  if d.per == 3 then
    local h1, h2
    h1, h2, p = d.data:byte(k, k + 2)
    hb = h1 and h1 * 256 + h2
  else
    hb, p = d.data:byte(k, k + 1)
  end
  if not hb or hb == 0 then return nil end
  return d.base + hb, d.colour[p] or H.GREY
end

-- The highest column in a cell (big cells: sampled, at most 4 x 4 looks).
-- A helldiver's recent scan wins; elsewhere Distant Horizons' terrain
function H.cellTop(wx, wz, cell)
  local top, colour
  wx, wz = math.floor(wx), math.floor(wz)
  local step = math.max(1, math.floor(cell / 4))
  for x = wx, wx + cell - 1, step do
    for z = wz, wz + cell - 1, step do
      local c = H.cols[x .. "," .. z]
      local y, col
      if c then y, col = c.y, c.c else y, col = H.dhTop(x, z) end
      if y and (not top or y > top) then top, colour = y, col end
    end
  end
  return top, colour
end

-- Where the map sits, in camera space (x right, y up, -z ahead): its place on
-- screen (GUI px) at `dist` blocks, from the FOV; also blocks per GUI px there
-- and its yaw (turned to face the eye: it sits far off to the side)
function H.mapFrame()
  local m, L = H.cfg.map, H.L
  local per = 2 * m.dist * math.tan(math.rad(H.cfg.fov / 2)) / L.h
  local gx, gy = L.left + m.left, L.h - m.up
  local x, y = (gx - L.w / 2) * per, -(gy - L.h / 2) * per
  return x, y, -m.dist, per, math.deg(atan2(-x, m.dist))
end

-- What the map shows. "local": around you, `cell` blocks a column;
-- "squad": zoomed out (whole-block cells) until every teammate fits, up to
-- `keep` blocks. radius = blocks from your cell to the edge, depth = blocks
-- above / below your feet shown, boost = heights stretched when zoomed out
function H.mapView()
  local m = H.cfg.map
  local cell = m.cell
  if H.ui.map == "squad" and H.me then
    local far = 0
    for _, t in pairs(H.team) do
      if t.x and now() - t.at < H.TEAM_FRESH then
        far = math.max(far, math.abs(t.x - H.me.x), math.abs(t.z - H.me.z))
      end
    end
    far = math.min(far + m.squadPad, H.dh and m.area or m.keep)
    cell = math.max(m.cell, math.ceil(2 * far / m.cells))
  elseif H.ui.map == "area" then
    cell = math.max(m.cell, math.ceil(2 * m.area / m.cells))
  end
  local radius = cell * m.cells / 2
  local zoom = radius / (m.cell * m.cells / 2)
  return { radius = radius, cell = cell, depth = math.min(64, math.floor(m.depth * zoom)),
    boost = math.min(2, zoom), mode = H.ui.map }
end

-- (a column is always the same size on screen: zooming changes what a
-- column covers, not how big it is)
function H.mapGeom()
  local m = H.cfg.map
  local v = H.view or H.mapView()
  local _, _, _, per = H.mapFrame()
  return m, m.cells, m.px * per / (2 * v.radius), v
end

-- map point (blocks east, up, south of the wearer) -> camera space: the map
-- tilted toward the eye, then turned to face it
function H.mapPoint(u, h, v)
  local m, _, S, view = H.mapGeom()
  local cx, cy, cz, _, yaw = H.mapFrame()
  local th, ps = math.rad(m.tilt), math.rad(yaw)
  local x, y, z = u * S, h * S * m.heightScale * view.boost, v * S
  y, z = y * math.cos(th) - z * math.sin(th), y * math.sin(th) + z * math.cos(th)
  x, z = x * math.cos(ps) + z * math.sin(ps), -x * math.sin(ps) + z * math.cos(ps)
  return cx + x, cy + y, cz + z
end

local function mapObj(kind, props)
  props.relativePosition, props.relativeRotation = true, true
  local o = H.make(kind, props)
  if o then
    if o.o.setRelativePosition then pcall(o.o.setRelativePosition, true) end
    if o.o.setRelativeRotation then pcall(o.o.setRelativeRotation, true) end
    o:show(false)
  end
  return o
end

function H.buildMap()
  local m, n = H.mapGeom()
  local ms = { built = true, boxes = {}, marks = {}, arrow = {} }
  H.mapState = ms
  local _, _, _, per, yaw = H.mapFrame()
  local col = m.px * per / n                     -- one column's width (any zoom)
  local cs = round(col * 0.96, 1e-4)
  -- (map coordinates are blocks from the centre of the wearer's cell; the
  -- columns' centres run from -radius to radius - cell; drawMap places it)
  yaw = round(yaw, 0.01)
  ms.plate = mapObj("Box", { x = 0, y = 0, z = 0, rotX = m.tilt, rotY = yaw, sizeX = m.px * per,
    sizeY = 0.002, sizeZ = m.px * per, color = 0x0A1A14, opacity = 0.55 })
  for i = 1, n * n do
    ms.boxes[i] = mapObj("Box", { x = 0, y = 0, z = 0, rotX = m.tilt, rotY = yaw, sizeX = cs, sizeY = cs, sizeZ = cs,
      color = H.GREY })
  end
  local mk = round(col * 1.1, 1e-4)
  for i = 1, 32 do
    ms.marks[i] = mapObj("Box", { x = 0, y = 0, z = 0, rotX = m.tilt, rotY = yaw, sizeX = mk, sizeY = mk, sizeZ = mk,
      color = H.C.red })
  end
  -- the wearer: an arrow (both windings, so it shows from either side)
  for i = 1, 2 do
    ms.arrow[i] = mapObj("Triangle", { x = 0, y = 0, z = 0, color = H.C.white })
  end
  H.mapDirty = true
end

function H.showMap(on)
  local ms = H.mapState
  if not ms.built then return end
  if ms.plate then ms.plate:show(on) end
  if not on then
    for _, list in ipairs({ ms.boxes, ms.marks, ms.arrow }) do
      for _, o in ipairs(list) do if o then o:show(false) end end
    end
  end
end

-- The map key: off -> local -> squad -> area (Distant Horizons map loaded) -> off
H.MAP_NEXT = { [false] = "local", ["local"] = "squad", squad = "area", area = false }
H.MAP_NAMES = { ["local"] = "MAP - LOCAL", squad = "MAP - SQUAD", area = "MAP - AREA" }

function H.toggleMap()
  H.ui.map = H.MAP_NEXT[H.ui.map or false]
  if H.ui.map == "area" and not H.dh then H.ui.map = false end
  if H.ui.map and not H.mapState.built then H.buildMap() end
  H.showMap(H.ui.map ~= false)
  H.view = H.mapView()
  H.mapDirty, H.marksAt = true, 0
  H.toast(H.MAP_NAMES[H.ui.map] or "MAP OFF", H.C.grey, 1)
end

-- The terrain: one column per cell, around the wearer's cell
function H.drawMap()
  local ms, me = H.mapState, H.me
  if not ms.built or not me then return end
  local m, n, S, v = H.mapGeom()
  local cell = v.cell
  local cx0, cz0 = math.floor(me.x / cell) * cell, math.floor(me.z / cell) * cell
  local bottom = -v.depth - 1
  local half = math.floor(n / 2)             -- (whole numbers: they make the column keys)
  -- heights are shown from your feet; far above the ground (the destroyer)
  -- from the highest ground in view instead, so the terrain still has shape
  local tops, highest = {}, nil
  for i = 0, n - 1 do
    for j = 0, n - 1 do
      local top, colour = H.cellTop(cx0 + (i - half) * cell, cz0 + (j - half) * cell, cell)
      tops[i * n + j + 1] = top and { top, colour } or false
      if top and (not highest or top > highest) then highest = top end
    end
  end
  local feet = math.floor(me.y + 0.01)
  if highest and feet - highest > v.depth then feet = highest end
  ms.cx0, ms.cz0, ms.feet, ms.cell = cx0, cz0, feet, cell
  if ms.plate then
    local px, py, pz = H.mapPoint(-cell / 2, bottom - 0.05, -cell / 2)
    ms.plate:pos(px, py, pz)
  end
  for i = 0, n - 1 do
    for j = 0, n - 1 do
      local b = ms.boxes[i * n + j + 1]
      if b then
        local wx, wz = cx0 + (i - half) * cell, cz0 + (j - half) * cell
        local t = tops[i * n + j + 1]
        local top, colour = t and t[1], t and t[2]
        if not top then
          b:show(false)
        else
          local dh = clamp(top - feet, -v.depth, v.depth)
          local hgt = dh + 1 - bottom
          local x, y, z = H.mapPoint(wx - cx0, bottom + hgt / 2, wz - cz0)
          b:pos(x, y, z)
          b:set("SizeY", round(hgt * S * m.heightScale * v.boost, 1e-4))
          b:set("Color", colour or H.GREY)
          b:show(true)
        end
      end
    end
  end
end

-- What the map marks: squad (their colour), radar contacts (red: hostile,
-- purple: ships, orange: players not in the squad)
function H.mapContacts()
  local out = {}
  local function near(x, y, z, r)
    for _, m in pairs(H.team) do
      if m.x and math.abs(m.x - x) < r and math.abs(m.z - z) < r and math.abs(m.y - y) < r + 2 then return true end
    end
    local me = H.me
    return me and math.abs(me.x - x) < r and math.abs(me.z - z) < r
  end
  for _, m in pairs(H.team) do
    if now() - m.at < H.TEAM_FRESH and m.x then
      out[#out + 1] = { x = m.x, y = m.y - 1.6, z = m.z, c = m.dead and H.C.grey or H.colourOf(m.slot) }
    end
  end
  local r = H.radar
  if r and now() - r.at < 5 then
    for _, t in ipairs(r.tracks) do
      local c = tostring(t.c)
      local colour
      if c == "SABLE" then colour = 0xC050FF
      elseif c == "PLAYER" then colour = (not near(t.x, t.y, t.z, 4)) and 0xFF9A3D or nil
      elseif c:find("HOSTILE") or c:find("MONSTER") or c:find("MOB") or c:find("ENEMY") then colour = 0xFF3030 end
      if colour and tonumber(t.x) then out[#out + 1] = { x = t.x, y = t.y, z = t.z, c = colour } end
    end
  end
  for _, b in ipairs(H.myBeacons()) do out[#out + 1] = { x = b.x, y = b.y, z = b.z, c = 0xFF3B2F } end
  return out
end

function H.drawMarks()
  local ms, me = H.mapState, H.me
  if not ms.built or not me or not ms.cx0 then return end
  local _, _, _, v = H.mapGeom()
  local m = { cell = ms.cell or v.cell, radius = v.radius, depth = v.depth }
  local ccx, ccz = ms.cx0 + m.cell / 2, ms.cz0 + m.cell / 2
  local edge = m.radius - m.cell / 2
  local list = H.mapContacts()
  for i, o in ipairs(ms.marks) do
    local c = list[i]
    if c and o then
      local u, v = c.x - ccx, c.z - ccz
      local far = math.max(math.abs(u), math.abs(v))
      if far > edge then u, v = u * edge / far, v * edge / far end
      local h = clamp(c.y - ms.feet, -m.depth, m.depth) + 1.5
      local x, y, z = H.mapPoint(u, h, v)
      o:pos(x, y, z)
      o:set("Color", c.c)
      o:set("Opacity", far > edge and 0.5 or 1)
      o:show(true)
    elseif o then
      o:show(false)
    end
  end
  -- the wearer's arrow, pointing the way they face
  local yaw = math.rad(me.yaw or 0)
  local fx, fz = -math.sin(yaw), math.cos(yaw)
  local L = m.cell * 1.6
  local function pt(ang, len)
    local ca, sa = math.cos(ang), math.sin(ang)
    local x, z = (fx * ca - fz * sa) * len, (fx * sa + fz * ca) * len
    local h = clamp(me.y - ms.feet, -m.depth, m.depth) + 1.6
    return H.mapPoint(x + (me.x - ccx), h, z + (me.z - ccz))
  end
  local ax, ay, az = pt(0, L)
  local bx, by, bz = pt(math.rad(140), L * 0.7)
  local cx, cy, cz = pt(math.rad(-140), L * 0.7)
  local r3 = function(v) return round(v, 1e-4) end
  if ms.arrow[1] then
    ms.arrow[1]:setN("setPos1", r3(ax), r3(ay), r3(az)) ms.arrow[1]:setN("setPos2", r3(bx), r3(by), r3(bz))
    ms.arrow[1]:setN("setPos3", r3(cx), r3(cy), r3(cz)) ms.arrow[1]:show(true)
  end
  if ms.arrow[2] then
    ms.arrow[2]:setN("setPos1", r3(ax), r3(ay), r3(az)) ms.arrow[2]:setN("setPos2", r3(cx), r3(cy), r3(cz))
    ms.arrow[2]:setN("setPos3", r3(bx), r3(by), r3(bz)) ms.arrow[2]:show(true)
  end
end

---------------------------------------------------------------- frames

function H.rebuild()
  H.needRebuild = false
  if not H.ov then return end
  pcall(H.ov.clear)
  H.objs, H.menu, H.mapState = {}, nil, { built = false }
  H.layout()
  H.buildMenu()
  H.buildPanel()
  H.buildVitals()
  H.buildWorld()
  if H.ui.map then H.buildMap() H.showMap(true) end
  if H.W then H.W.reset() end            -- (the war table's objects went too: they come back a frame at a time)
  if H.ST then H.ST.reset() end          -- (and the status hologram's)
  H.log("overlay built: " .. #H.objs .. " objects")
end

function H.frame()
  if H.needRebuild then H.rebuild() end
  if not H.worn or not H.ov then return end
  local ok, ex, ey, ez = pcall(H.ov.getEyePosition)
  if ok and tonumber(ex) then H.eye = { ex, ey, ez } end
  H.expire()
  if H.ui.open then H.menuUpdate() end
  H.drawTags()
  H.drawBeacons()
  H.drawPanel()
  H.drawVitals()
  H.drawHint()
  if H.ui.map then
    local ms = H.mapState
    local me = H.me
    if me and ms.built then
      H.view = H.mapView()
      local cell = H.view.cell
      local key = cell .. ":" .. math.floor(me.x / cell) .. "," .. math.floor(me.z / cell) .. "," .. math.floor(me.y + 0.01)
      if H.mapDirty or key ~= ms.key then
        ms.key, H.mapDirty = key, false
        H.drawMap()
      end
      if now() - (H.marksAt or 0) > 0.3 then
        H.marksAt = now()
        H.drawMarks()
      end
    end
  end
  if H.W then H.W.frame() end
  if H.ST then
    local ok, err = pcall(H.ST.frame)    -- (a fault there never stops the rest of the HUD)
    if not ok then H.log("status hologram: " .. tostring(err)) end
  end
end

-- What the glasses' own screen shows (open it with the Interface)
function H.drawTerm()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.yellow)
  print("HD2 HUD " .. H.VERSION .. "  (computer " .. os.getComputerID() .. ")")
  term.setTextColor(colors.white)
  print("worn: " .. tostring(H.worn) .. "   destroyer: " .. (H.strike and ("computer " .. H.strike) or "searching"))
  print(("stratagems: %s   squad #%s %s"):format(H.list and #H.list or "-", tostring(H.slot or "-"), H.myName()))
  local n = 0
  for _ in pairs(H.team) do n = n + 1 end
  local cols = 0
  for _ in pairs(H.cols) do cols = cols + 1 end
  print(("teammates heard: %d   map: %s (%d columns known)"):format(n, H.ui.map or "off", cols))
  if H.W then
    local t = H.W.table
    print(("war table: %s, %s"):format(H.W.server and ("map computer " .. H.W.server) or "no map computer yet",
      t.anchor and (t.anchor.mode == "ship" and "on the ship" or "fixed in the world") or "not placed"))
  else
    print("war table: war.lua missing (" .. tostring(H.warError) .. ")")
  end
  print("glasses key: " .. H.keyLabel(H.cfg.hotkey) .. "   map key: " .. tostring(H.cfg.mapKey))
  local missing = {}
  for k, v in pairs({ overlay = H.ov, keyboard = H.kb, modem = H.modem, speaker = H.speaker,
    distance_detector = H.dd, geo_scanner = H.geo }) do
    if not v then missing[#missing + 1] = k end
  end
  table.sort(missing)
  if #missing > 0 then
    term.setTextColor(colors.red)
    print("missing: " .. table.concat(missing, ", "))
  end
  term.setTextColor(colors.lightGray)
  print("")
  print("Hold the glasses key: stratagems (arrows)")
  print("Left Alt: corner map (Right Alt in the stratagem menu: centre it on you)")
  print("M: field map    N: war table (edit it)    middle-click the table: target / radar lock")
  print("Ctrl+T: stop the HUD")
end

---------------------------------------------------------------- input

function H.onKey(k, held)
  if H.W and H.W.menu.open then return H.W.onKey(k, held) end   -- (the war table has the keyboard)
  if held then return end                                -- key repeats
  if H.hotkey and k == H.hotkey then return H.openMenu() end   -- the key again, keyboard still ours
  -- (the 3D corner map: Left Alt on / off; the old one where the war table is not loaded)
  if k == keys[H.cfg.mapKey] then
    if H.W then return H.W.cornerToggle() end
    return H.toggleMap()
  end
  if H.W and k == keys[H.cfg.war.key] then return H.W.open("field") end
  if H.W and k == keys[H.cfg.war.tableKey or "n"] then return H.W.open("table") end
  if not H.ui.open then return end
  -- Right Alt in the stratagem menu: the corner map, centred on you now
  if H.W and k == keys.rightAlt then return H.W.cornerUpdate() end
  local a = H.ARROWS[k] or (H.cfg.wasd and H.WASD[k])
  if a then
    H.addArrow(a)
  elseif k == keys.backspace then
    H.ui.input = ""
    H.menuUpdate()
  end
end

function H.onKeyUp(k)
  H.lastUp = { k = k, t = now() }
  if H.hotkey and k == H.hotkey then H.closeMenu() end
end

-- The glasses name their key once it is let go (and right after the
-- keyboard opens): remember it
function H.learnHotkey(name)
  local code = H.keyCode(name)
  if not code then return end
  if code ~= H.hotkey then
    H.hotkey = code
    H.cfg.hotkey = name
    H.saveConfig()
    H.log("glasses key: " .. tostring(name))
  end
  -- a quick tap: its key_up came before this
  local up = H.lastUp
  if up and up.k == code and now() - up.t < 0.5 and now() - (H.ui.openedAt or 0) < 0.5 then H.closeMenu() end
end

function H.onMessage(from, msg, proto)
  if type(msg) ~= "table" then return end
  if proto == H.PROTO_STRIKE then
    if H.strike and from ~= H.strike then return end
    if msg.op == "list" then
      H.takeList(msg)
    elseif msg.op == "status" then
      if not msg.id and tostring(msg.text):find("not in strike.cfg pockets") then
        H.toast("THESE GLASSES (ID " .. os.getComputerID() .. ") ARE NOT IN STRIKE.CFG POCKETS", H.C.red, 6)
        H.notAllowed = true
      end
      H.onStatus(msg)
    elseif msg.op == "lock" and msg.refused == "debris" then
      H.toast("NOT LOCKED: THAT IS DEBRIS (UNDEBRIS IT ON THE STRIKE COMPUTER)", H.C.red, 3)
    end
  elseif proto == H.PROTO_HUD then
    if msg.op == "voice" then
      H.onFireLine(msg)
    elseif msg.op == "radar" and type(msg.tracks) == "table" then
      H.radar = { at = now(), tracks = msg.tracks }
    elseif msg.op == "pose" and H.W then
      H.W.onPose(msg)
    elseif msg.op == "shipstatus" and H.ST then
      H.ST.onStatus(msg)
    end
  elseif proto == "destroyer.repair" and H.ST then
    H.ST.onRepair(from, msg)
  elseif proto == H.PROTO_MAP and H.W then
    H.W.onMessage(from, msg)
  elseif proto == H.PROTO_TEAM and from ~= os.getComputerID() then
    if msg.op == "hi" then
      H.onTeam(from, msg)
    elseif msg.op == "terrain" then
      H.takeTerrain(msg)
    end
  end
end

-- (the glasses report the window in pixels: GUI units = pixels / GUI scale)
function H.guiUnits(w, h, s)
  s = tonumber(s) or 1
  if s <= 1 and w > 2500 then s = 3 end
  return math.floor(w / s), math.floor(h / s)
end

function H.onResize()
  local ok, w, h, s = pcall(H.ov.getGuiSize)
  if ok and tonumber(w) and w > 0 and h > 0 then
    H.cfg.gui.w, H.cfg.gui.h = H.guiUnits(w, h, s)
    H.saveConfig()
    H.needRebuild = true
  end
end

---------------------------------------------------------------- loops

-- Keys, messages and drawing: never waits on the server (a wait would lose
-- key presses)
function H.uiLoop()
  local frame = os.startTimer(0.1)
  local termAt = 0
  while true do
    local ev = table.pack(os.pullEventRaw())
    local e = ev[1]
    if e == "terminate" then
      return
    elseif e == "keyboard_open" then
      H.ui.capture = true
      H.openMenu()
    elseif e == "keyboard_close" then
      H.ui.capture = false
      H.closeMenu()
      if H.W then pcall(H.W.leave) end
    elseif e == "glasses_key_pressed" then
      H.learnHotkey(ev[2])
    elseif e == "key" then
      H.onKey(ev[2], ev[3])
    elseif e == "key_up" then
      H.onKeyUp(ev[2])
    elseif e == "char" and H.W then
      H.W.onChar(ev[2])
    elseif H.W and (e == "player_mouse_move" or e == "player_mouse_click" or e == "player_mouse_up"
      or e == "player_mouse_scroll") then
      local ok, err = pcall(H.W.onMouse, e, ev[2], ev[3])
      if not ok then H.log("mouse: " .. tostring(err)) end
    elseif e == "player_interaction" and (H.W or H.ST) then
      -- (a middle-click in the world: on the status hologram, a damage group or
      -- REPAIR; else on the war table's hologram, a target)
      local used = false
      if H.ST then
        local ok, r = pcall(H.ST.onWorldClick, ev[2], ev[3], ev[4])
        if not ok then H.log("status click: " .. tostring(r)) end
        used = ok and r == true
      end
      if not used and H.W then
        local ok, err = pcall(H.W.onWorldClick, ev[2], ev[3], ev[4])
        if not ok then H.log("click: " .. tostring(err)) end
      end
    elseif e == "rednet_message" then
      H.onMessage(ev[2], ev[3], ev[4])
    elseif e == "overlay_resize" then
      H.onResize()
    elseif e == "timer" and ev[2] == frame then
      local ok, err = pcall(H.frame)
      if not ok then H.log("frame: " .. tostring(err)) end
      if now() - termAt > 2 then
        termAt = now()
        pcall(H.drawTerm)
      end
      frame = os.startTimer(0.1)
    end
  end
end

-- The wearer (getOwner waits a tick), calls, the squad broadcast
function H.sense()
  local ok, worn = pcall(smartglasses.isEquipped)
  worn = ok and worn == true
  if worn and not H.worn then H.needRebuild = true end
  H.worn = worn
  if not worn then return end
  local ok2, me = pcall(smartglasses.getOwner)
  if ok2 and type(me) == "table" and tonumber(me.x) then
    H.me = { x = me.x, y = me.y, z = me.z, yaw = me.yaw, pitch = me.pitch, eyeHeight = me.eyeHeight,
      health = me.health, maxHealth = me.maxHealth, dy = me.dy, name = me.displayName or me.name,
      user = me.displayName, uuid = me.uuid and tostring(me.uuid) or nil,
      dim = me.dimension, at = now(), kit = H.kit(me) }
  end
end

function H.workLoop()
  while true do
    while #H.jobs > 0 do
      local j = table.remove(H.jobs, 1)
      local ok, err = pcall(function()
        if j.kind == "call" then H.call(j.arg) end
        if j.kind == "mapcall" then H.call(j.arg.s, j.arg.target) end
      end)
      if not ok then H.log("job " .. j.kind .. ": " .. tostring(err)) end
    end
    local ok, err = pcall(H.sense)
    if not ok then H.log("sense: " .. tostring(err)) end
    pcall(H.broadcast)
    if #H.jobs == 0 then
      local t = os.startTimer(0.25)
      repeat
        local e, id = os.pullEvent()
      until (e == "timer" and id == t) or e == "hud_job"
    end
  end
end

-- Geo scans for the map and the Sable check (one scan per 2 s at most)
function H.scanLoop()
  while true do
    if H.geo and H.worn and H.me then
      local r = H.scanR or H.cfg.map.scan
      -- (fallen back to 8: now and then the full radius again - it may have been only high up)
      if H.scanR and not H.scanProbe and (H.scanOk or 0) % 20 == 19 then r = H.cfg.map.scan end
      local me = H.me
      local ok, res, why = pcall(H.geo.scanBlocks, r)
      if ok and type(res) == "table" then
        local ok2, err = pcall(H.takeScan, res, me, r)
        if not ok2 then H.log("scan: " .. tostring(err)) end
        H.scanOk = (H.scanOk or 0) + 1
        if H.scanOk == 1 or H.scanOk % 50 == 0 then
          H.log(("scans: %d done (radius %d, %d blocks, shared %s)"):format(H.scanOk, r, #res,
            tostring(H.cfg.map.share and H.modem ~= nil)))
        end
        if #res == 0 then
          -- (an empty scan: say what came back once; past the free radius, try the free radius)
          H.emptyScans = (H.emptyScans or 0) + 1
          if H.emptyScans == 1 then
            local keys = {}
            for k, v in pairs(res) do
              if #keys < 8 then keys[#keys + 1] = tostring(k) .. "=" .. tostring(v) end
            end
            H.log(("scan at radius %d found nothing (%s) - eye at %.1f %.1f %.1f"):format(r,
              #keys > 0 and table.concat(keys, " ") or "empty list", me.x or 0, me.y or 0, me.z or 0))
          end
          if r > 8 and H.emptyScans >= 2 then
            -- (nothing in reach - high up - or the scanner refusing past its free radius: try 8 once)
            H.scanR, H.scanProbe = 8, r
          elseif H.scanProbe then
            H.scanR, H.scanProbe = nil, nil        -- (8 finds nothing either: just high up)
          end
        else
          if H.scanProbe then
            H.log(("radius %d scans came back empty where radius 8 found %d blocks - using 8"):format(H.scanProbe, #res))
            H.scanProbe = nil
          elseif H.scanR and r > H.scanR then
            H.scanR = nil                          -- (the full radius works again)
          end
          H.emptyScans = 0
        end
      else
        -- (each new kind of refusal once in the log)
        local msg = tostring(ok and why or res)
        if msg ~= H.scanWhy then
          H.scanWhy = msg
          H.log("scan refused: " .. msg)
        end
      end
      if not (ok and type(res) == "table") and r > 8 and not tostring(why or res):lower():find("cooldown") then
        -- (a server with a smaller scan limit, or fuel needed beyond 8: the free radius)
        H.scanR = 8
        H.log(("scan radius %d refused (%s) - using 8"):format(r, tostring(why or res)))
      end
    end
    sleep(H.ui.map and 2.2 or 3)
  end
end

-- Find the destroyer; keep the stratagem list fresh
function H.netLoop()
  while true do
    if not H.strike then
      local id = rednet.lookup(H.PROTO_STRIKE, H.HOSTNAME)
      if id then
        H.strike = id
        H.log("destroyer: computer " .. id)
        rednet.send(id, { op = "list" }, H.PROTO_STRIKE)
        H.listAsked = now()
      end
    elseif H.wantList or now() - (H.listAsked or -100) > (H.ui.open and 3 or 8) then
      H.wantList = false
      rednet.send(H.strike, { op = "list" }, H.PROTO_STRIKE)
      H.listAsked = now()
    end
    -- asked twice and nothing heard: look for it again
    if H.strike and H.listAsked and not H.notAllowed and now() - (H.listAt or H.started) > 20 then
      H.strike, H.listAt = nil, now()
    end
    if H.W then
      local ok, err = pcall(H.W.netTick)
      if not ok then H.log("war table: " .. tostring(err)) end
    end
    if H.ST then pcall(H.ST.netTick) end
    sleep(1)
  end
end

-- The speaker: one line after another
function H.voiceLoop()
  local dfpwm = require("cc.audio.dfpwm")
  while true do
    if #H.voiceQ == 0 then os.pullEvent("hud_voice") end
    local line = table.remove(H.voiceQ, 1)
    local path = line and fs.combine(H.FILES.voice, line .. ".dfpwm")
    if path and H.speaker and fs.exists(path) then
      local decode = dfpwm.make_decoder()
      local h = fs.open(path, "rb")
      while true do
        local chunk = h.read(16 * 1024)
        if not chunk then break end
        local buf = decode(chunk)
        while not H.speaker.playAudio(buf, H.cfg.volume) do os.pullEvent("speaker_audio_empty") end
      end
      h.close()
    elseif line then
      H.log("no voice line " .. line)
    end
  end
end

---------------------------------------------------------------- start

function H.init()
  H.loadConfig()
  H.objs, H.voiceQ = {}, {}
  H.ui = { open = false, input = "", capture = false,
    map = (H.cfg.map.open == true and "local") or (H.MAP_NEXT[H.cfg.map.open] ~= nil and H.cfg.map.open) or false }
  H.hotkey = H.keyCode(H.cfg.hotkey) or keys.g
  H.started = now()
  if type(smartglasses) ~= "table" then error("hud.lua runs on Advanced Peripherals smart glasses", 0) end
  local mods = smartglasses.modules or {}
  H.ov = mods["advancedperipherals:overlay"] or mods.overlay
  H.kb = mods["advancedperipherals:keyboard"] or mods.keyboard
  -- (middle-clicks in the world come to the glasses: aiming at the war table's hologram)
  if H.kb and H.kb.setHandlingInteraction then pcall(H.kb.setHandlingInteraction, 3, true) end
  H.modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
  H.speaker = peripheral.find("speaker")
  H.dd = peripheral.find("distance_detector")
  H.geo = peripheral.find("geo_scanner")
  if H.modem then rednet.open(peripheral.getName(H.modem)) end
  if H.dd then
    pcall(H.dd.setDetectionMode, "BLOCK")
    pcall(H.dd.setMaxRange, H.cfg.range)
    pcall(H.dd.setCalculatePeriodically, false)
    pcall(H.dd.setLaserVisibility, false)
  end
  if H.ov then
    pcall(H.ov.setAutoUpdate, true)
    local ok, w, h, s = pcall(H.ov.getGuiSize)
    if ok and tonumber(w) and w > 0 and h > 0 then H.cfg.gui.w, H.cfg.gui.h = H.guiUnits(w, h, s) end
  end
  local okDh, errDh = pcall(H.loadDh)
  if not okDh then H.log("dhmap.bin: " .. tostring(errDh)) end
  H.layout()
  H.needRebuild = true
  H.log("started " .. H.VERSION)
end

function H.main()
  H.init()
  local ok, err = pcall(parallel.waitForAny, H.uiLoop, H.workLoop, H.scanLoop, H.netLoop, H.voiceLoop)
  if H.ov then pcall(H.ov.clear) end
  if not ok and err ~= "Terminated" then
    H.log("stopped: " .. tostring(err))
    printError(err)
  end
  print("HUD stopped")
end

if ARG == "lib" then return H end
H.main()
