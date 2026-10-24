--[[
strike.lua - Super Destroyer strike computer                        v2.0.1
CC:Tweaked. Runs on its own computer on the ship, next to helm (never instead
of it: helm stays the only flight computer).

A stratagem is called from the pocket computer (remote.lua): an arrow code
plus where the caller stands, measured by the GPS hosts on the ship as blocks
right/up/forward of the nav table. This computer then
  1 asks helm (wired network) to fly the nav table to that point plus the
    stratagem's offset (e.g. 30 blocks above it),
  2 passes helm's progress back to the pocket,
  3 on station: pulses the stratagem's redstone output (a Create redstone
    link to a toggle latch: weapon ON), waits fireTime, pulses again (OFF);
    or (fireEvery) pulses it every few ticks for fireTime; or (carpet) pulses
    the ammo link at the call and fires one pulse per volley once loaded;
    or (gun) aims the autocannon bank and fires it once,
  4 releases helm, which keeps holding where it is.
Abort from the pocket, from helm (pilot took over) or a lost link always sends
the OFF pulse first if the weapon was switched on.

One stratagem holds the ship at a time; a call while it is busy waits in the
queue (maxQueue) and starts when it is done - loading its ammo then, flying
to where it was called (helm keeps that spot fixed in the world). An
aimable stratagem (the Gatling: kind "gun", or aimable = true) that can reach
its target from where the ship is fires right away beside the current one;
if it cannot, it waits in the queue too. Abort calls off everything.

PA system (pa.lua on its own computer): every stratagem's `voice` lines are
sent to it - call (the request, always said in full), aim, fire, done,
arrive - plus the ship's move ("align"), "awaiting" for a queued call and
the failure lines.

HUD glasses (hd2hud, Advanced Peripherals smart glasses) call like the
pocket, on world coordinates (their IDs go in pockets too). The list they get
says whether each stratagem can be called now (ok / why) and its voice lines;
every fire line is also broadcast to all of them (destroyer.hud), and so are
the radar's contacts once a second, for their map, and the ship's state
(speed, mission, queue, weapons, readouts) for their status hologram.

Peripherals: an ender (or wireless) modem for the pocket, a wired modem on
helm's network, and the outputs: this computer's own sides, or Redstone
Relays on the wired network.

Commands: type at the strike computer, then Enter (type help for the list):
  call he carpet 1912 -60 -816   call a stratagem on F3 world coordinates
                            (needs the plane radar; the pocket's C key too)
  height barrage 750        set a stratagem's firing height (blocks above the
  barrage height 750        caller; any part of its name, or its arrow code)
  height all 1000           every stratagem at once
  heights                   show them all
  abort                     call off the mission
  gunner status | cal | down | up | point <bearing> <elev> | stop
                            the gun bank (gunner.lua): calibrate, test, stop
  debris <who>              mark a wreck: never auto-locked, never a
  undebris <who>            railcannon target, grey on the maps; debris alone
  debris auto <s> | off     lists them; auto = a ship still for <s> seconds
                            counts as debris until it moves
  engaged                   the gun groups the Geo Scanners see: blocks now /
  engaged reset             most seen (stowed); reset forgets the most seen
Heights are saved to strike.cfg and apply from the next call.

Files: strike.cfg (settings and the stratagem list, hand-editable),
strike.log, strike_status.txt, strike.engaged (each gun group's blocks
seen at most).
]]

local S = { VERSION = "2.15.1" }
S.MAX_HEIGHT = 10000

-- gun laying (gunner.lua, next to this file); missing = no gun stratagems
local G
do
  local ok, mod = pcall(dofile, GUNNER_PATH or "/gunner.lua")
  if ok and type(mod) == "table" then G = mod end
end
S.G = G
S.FILES = { cfg = "/strike.cfg", log = "/strike.log", status = "/strike_status.txt", engaged = "/strike.engaged" }
S.PROTO_POCKET = "destroyer.strike"
S.PROTO_HELM = "destroyer.helm"
S.PROTO_HUD = "destroyer.hud"          -- broadcast to every pair of HUD glasses
S.HOSTNAME = "destroyer"

S.DEFAULTS = {
  helmId = 16,
  -- pocket computer IDs allowed to call stratagems
  pockets = { 17 },
  -- longest trip accepted, blocks: only a guard against a wildly wrong GPS fix
  -- (ender modems and helm have no range limit of their own)
  maxRange = 100000,
  -- redstone pulse length, seconds (0.2 = 4 ticks)
  pulse = 0.2,
  -- seconds without word from helm during a mission before it is aborted
  helmTimeout = 3,
  -- calls that may wait for the ship at once
  maxQueue = 4,
  -- seconds between the ship's position + heading going to the HUD glasses
  -- (the war table moves with the ship); false = never
  hudPose = 0.25,
  -- friendlies: radar track id (a player's UUID, a sub-level's id) = a label.
  -- Everything else on the radar is hostile. Set from the war table (F on a
  -- contact) or here; S.isFriendly(id) is for the weapons
  friendly = {},
  -- autoLock: with no lock, the radar lock goes to the nearest player or
  -- ship that is not friendly (the friendly list, a friendly icon, a
  -- helldiver in glasses, anyone aboard). The railcannon fires at the lock.
  -- "autolock off" at the strike computer turns it off
  autoLock = true,
  -- designations: radar track id = the icon the maps show it as (helldiver,
  -- friendly_player, hostile_player, friendly_ship, hostile_ship) - I on a
  -- contact on the map cycles it; nil = by the radar (and the friendly list)
  designate = {},
  -- ships' names on the maps: radar track id = name (the radar gives ships no
  -- names, and a ship's nameplate can only be read on board). Over 16
  -- letters: not shown. Players are named by a Player Detector on the network
  shipNames = {},
  -- debris: radar track id = true - wrecks the weapons ignore: never
  -- auto-locked, never a railcannon target, a lock on one is refused; the
  -- maps draw them grey. Typed: debris <who>, undebris <who>, debris (list)
  debris = {},
  -- debrisAfter: seconds a ship (a sub-level) may sit without moving before
  -- it counts as debris as well, until it moves again; false = off. Keep it
  -- long: a hostile ship hovering still that long is ignored too
  debrisAfter = false,
  -- demo: true = every stratagem a dry run (the ship flies, beacons show,
  -- nothing is loaded or fired) - for showing it off
  demo = false,
  -- the ship status hologram (HUD glasses, status.lua): every hudStatus s
  -- the ship's state goes to every pair of glasses; false = never
  hudStatus = 1,
  -- where the hologram stands - set from the glasses (H in the map, place it)
  statusAnchor = false,
  -- readouts on it, read every readoutEvery s: { label = "FUEL", peripheral =
  -- "<peripheral type or name>", method = "<its method>", args = { ... },
  -- scale = 1, unit = "%", decimals = 0 } - e.g. a tank's fill level
  readouts = {},
  readoutEvery = 5,
  -- engaged guns (the hologram draws them out): every engagedScan s each Geo
  -- Scanner on the wired network looks round it (engagedRadius; 8 costs no
  -- energy). A gun group whose cannons (engagedBlocks: part of their block
  -- names) have mostly gone from what they see is assembled - engaged.
  -- Put a scanner near each gun group. false = never
  engagedScan = 3,
  engagedRadius = 8,
  engagedBlocks = { gun = "heavy_autocannon", turret = "twin_autocannon", barrage = "quickfiring_breech",
    rail = "screw_breech" },
  -- code: U D L R (arrow keys / WASD on the pocket)
  -- output: { side = "back" } for this computer's side, or
  --         { relay = "redstone_relay_0", side = "top" } for a Redstone Relay
  -- offset: where the nav table should stop, relative to the caller: r right,
  --         u up, f forward (ship's frame), blocks
  -- fireTime: seconds between the ON pulse and the OFF pulse
  -- fireEvery: instead of ON/OFF, pulse the output every this many seconds
  --           for fireTime (0.25 = every 5 ticks: a mount fired directly)
  -- accuracy: blocks from the exact spot that count as on station (fires
  --           sooner with a bigger number; default 0.5)
  -- dryRun: fly there but never touch the output
  -- kind = "gun": aimed by gunner.lua (one pulse fires); offset.u = the gun
  --   bank's height above the target; no fireTime needed
  -- kind = "carpet": at the call, pulse `load` (dispenses the ammo), then
  --   one pulse of `output` per volley: the first loadTime s after the load
  --   pulse (or on arrival, if later), then after each of volleyGaps. The
  --   stratagem completes with the last volley; flushAfter s later one more
  --   pulse clears leftover ammo in the background (a new call cancels it)
  -- kind = "barrage": `load` at the call (each load is 2 volleys); from
  --   fireDelay s after it (or on arrival) pulse `output` every fireEvery s
  --   for fireTime, then flush s more to clear leftovers. All loads are
  --   called from the start, loadEvery s apart (so the dispenser does not
  --   clog), flying or not. load may be a list of
  --   links used in turn (Hybrid: gas, napalm, gas, napalm)
  -- kind = "rail" (Helldivers railcannon, guided shells): at the call the
  --   ships within pickRadius of the caller are noted from the radar and
  --   kept - any of them may take the hit, whichever the network locks
  --   (none: nothing is loaded or fired; caller out of radar range: the
  --   ship moves into range and the caller calls again). Then `load` (ready
  --   loadTime s later); move only if the target is over guidedRange across,
  --   or another ship is nearer this ship; stop the radar a moment
  --   (radar.resetLink clutch) so the network's auto-lock (the Create Aero
  --   Radar yaw controller, Targeting Filter on contraptions) takes the
  --   nearest ship; fire when the network's lock is one of them (lockWait s,
  --   else called off - leftover shells then fire after a 10 s warning).
  --   One pulse of `output`, done; flushAfter s later a background flush.
  --   targets = "ships" (default) or "all" (players too)
  -- kind = "escape": calls off everything (running and queued) and climbs
  --   straight up until the nav table is at world Y `altitude`; done there
  -- voice: the PA lines (file names on the PA computer): call = the request
  --   (said in full), aim, fire, done (completed), arrive (on station);
  --   noAlign = say no movement line (the call line says it)
  -- holo: { r, u, f } where its weapon is on the ship (from the nav table) -
  --   the status hologram's firing animation (default: the railcannon's
  --   muzzle, the gun bank, else under the ship's middle) when the ship
  --   model has no barrels for it
  -- sys: which gun group fires it on the hologram (rail, gun, barrage,
  --   turret - the ship model's; default: its kind)
  stratagems = {
    { name = "Orbital Railcannon Strike", code = "RUDDR", kind = "rail",
      flyAccuracy = 8, accuracy = 0.5, offset = { r = 0, u = 1000, f = 0 },
      load = { relay = "redstone_relay_2", side = "back" }, loadTime = 20,
      output = { relay = "redstone_relay_2", side = "right" }, flushAfter = 5,
      pickRadius = 15, guidedRange = 200, approach = 150, lockWait = 20, targets = "ships",
      voice = { call = "rail_request", aim = "rail_target", fire = "rail_firing" } },
    { name = "Cannon Barrage", code = "RRDLRD", output = { side = "back" }, fireTime = 60,
      fireEvery = 0.25, accuracy = 8, offset = { r = 0, u = 1000, f = 0 },
      voice = { call = "barrage_request", fire = "barrage_commencing", done = "barrage_complete" } },
    { name = "HE Barrage", code = "RDUULDD", kind = "barrage", accuracy = 8, offset = { r = 0, u = 1000, f = 0 },
      load = { relay = "redstone_relay_0", side = "top" }, output = { relay = "redstone_relay_2", side = "right" },
      fireDelay = 0, loads = 8, loadEvery = 10, fireEvery = 0.25, fireTime = 60, flush = 10,
      voice = { call = "barrage_he", fire = "barrage_commencing", done = "barrage_complete" } },
    { name = "Napalm Barrage", code = "RRDLRU", kind = "barrage", accuracy = 8, offset = { r = 0, u = 1000, f = 0 },
      load = { relay = "redstone_relay_0", side = "front" }, output = { relay = "redstone_relay_2", side = "right" },
      fireDelay = 0, loads = 8, loadEvery = 10, fireEvery = 0.25, fireTime = 60, flush = 10,
      voice = { call = "barrage_napalm", fire = "barrage_commencing", done = "barrage_complete" } },
    { name = "Gas Barrage", code = "RRDR", kind = "barrage", accuracy = 8, offset = { r = 0, u = 1000, f = 0 },
      load = { relay = "redstone_relay_0", side = "back" }, output = { relay = "redstone_relay_2", side = "right" },
      fireDelay = 0, loads = 8, loadEvery = 10, fireEvery = 0.25, fireTime = 60, flush = 10,
      voice = { call = "barrage_gas", fire = "barrage_commencing", done = "barrage_complete" } },
    { name = "Hybrid Barrage", code = "RRDD", kind = "barrage", accuracy = 8, offset = { r = 0, u = 1000, f = 0 },
      load = { { relay = "redstone_relay_0", side = "back" }, { relay = "redstone_relay_0", side = "front" } },
      output = { relay = "redstone_relay_2", side = "right" },
      fireDelay = 0, loads = 8, loadEvery = 10, fireEvery = 0.25, fireTime = 60, flush = 10,
      voice = { call = "barrage_hybrid", fire = "barrage_commencing", done = "barrage_complete" } },
    { name = "HE Carpet", code = "URDR", kind = "carpet", accuracy = 8, offset = { r = 0, u = 1000, f = 0 },
      load = { relay = "redstone_relay_0", side = "top" }, output = { relay = "redstone_relay_2", side = "right" },
      loadTime = 20, volleyGaps = {}, flushAfter = 5,
      voice = { call = "carpet_he", fire = "carpet_fired" } },
    { name = "Napalm Carpet", code = "URDU", kind = "carpet", accuracy = 8, offset = { r = 0, u = 1000, f = 0 },
      load = { relay = "redstone_relay_0", side = "front" }, output = { relay = "redstone_relay_2", side = "right" },
      loadTime = 20, volleyGaps = {}, flushAfter = 5,
      voice = { call = "carpet_napalm", fire = "carpet_fired" } },
    { name = "Gas Carpet", code = "URDL", kind = "carpet", accuracy = 8, offset = { r = 0, u = 1000, f = 0 },
      load = { relay = "redstone_relay_0", side = "back" }, output = { relay = "redstone_relay_2", side = "right" },
      loadTime = 20, volleyGaps = {}, flushAfter = 5,
      voice = { call = "carpet_gas", fire = "carpet_fired" } },
    { name = "Flyover Test", code = "UDUD", dryRun = true, fireTime = 5,
      accuracy = 1, offset = { r = 0, u = 100, f = 0 },
      voice = { call = "pickup", arrive = "in_position", noAlign = true } },
    { name = "Gatling Barrage", code = "RDLUU", kind = "gun", dryRun = true,
      accuracy = 8, offset = { r = 0, u = 1000, f = 0 },
      voice = { call = "gatling_request", aim = "gatling_aiming", fire = "gatling_fired" } },
    { name = "Escape", code = "LRLRLRLRLR", kind = "escape", altitude = 10000, accuracy = 8,
      offset = { r = 0, u = 0, f = 0 },
      voice = { call = "escape_call", arrive = "escape_reached", noAlign = true } },
  },
  -- the gun bank (see gunner.lua): peripherals, where it is, shell physics
  gun = G and G.DEFAULTS or nil,
  -- Create Radar on the ship (railcannon), all on the wired network:
  --   radar: the radar bearing; monitor: its radar monitor (a player's
  --   selection there wins); anchor: a plane radar, only read for its true
  --   world position. "auto" = the first one found.
  --   anchorFromNav: the plane radar's block from the nav table's block,
  --   ship's frame (F3 on each block: r = x difference, u = y, f = -z), REQUIRED
  --   gunFromNav: the railcannon's muzzle from the nav table (r, f; it is
  --   put right over the target)
  --   selfRadius: players this close to the caller are never targets
  --   shipRadius: a sub-level this close to the ship is the ship itself
  --   resetLink: a clutch on the radar's drive, resetTime s on = the radar
  --   stops and the network drops its lock (the dummy then re-picks)
  --   range: how far sideways the radar sees ("auto" = 20 + 10 per dish,
  --   at most maxRange)
  radar = {
    radar = "auto", monitor = "auto", anchor = "auto",
    anchorFromNav = false, gunFromNav = { r = 0, f = 0 },
    selfRadius = 8, shipRadius = 60,
    resetLink = { relay = "redstone_relay_1", side = "front" }, resetTime = 2,
    range = "auto", maxRange = 1000,
  },
}

---------------------------------------------------------------- utilities

local function now() return os.clock() end

function S.log(msg)
  local line = ("[%10.2f] %s\n"):format(now(), tostring(msg))
  pcall(function()
    if fs.exists(S.FILES.log) and fs.getSize(S.FILES.log) > 32000 then
      if fs.exists(S.FILES.log .. ".old") then fs.delete(S.FILES.log .. ".old") end
      fs.move(S.FILES.log, S.FILES.log .. ".old")
    end
    local h = fs.open(S.FILES.log, "a")
    if h then h.write(line) h.close() end
  end)
end

local function copy(t)
  if type(t) ~= "table" then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = copy(v) end
  return r
end

local function v3add(a, b) return { a[1] + b[1], a[2] + b[2], a[3] + b[3] } end
local function v3sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function v3of(p)
  if type(p) == "table" and tonumber(p.x) and tonumber(p.y) and tonumber(p.z) then return { p.x, p.y, p.z } end
end
-- ship-frame {r,u,f} -> world, axes = { f, r, u } world unit vectors (helm)
local function shipToWorld(v, ax)
  local r, u, f = v.r or 0, v.u or 0, v.f or 0
  return { ax.r[1] * r + ax.u[1] * u + ax.f[1] * f, ax.r[2] * r + ax.u[2] * u + ax.f[2] * f,
    ax.r[3] * r + ax.u[3] * u + ax.f[3] * f }
end
local function worldToShip(w, ax)
  local function d(a) return a[1] * w[1] + a[2] * w[2] + a[3] * w[3] end
  return { r = d(ax.r), u = d(ax.u), f = d(ax.f) }
end

function S.loadConfig()
  if fs.exists(S.FILES.cfg) then
    local h = fs.open(S.FILES.cfg, "r")
    local text = h.readAll()
    h.close()
    local cfg = textutils.unserialize(text)
    if type(cfg) ~= "table" then error("strike.cfg has an error (fix it or delete it)", 0) end
    for k, v in pairs(S.DEFAULTS) do
      if cfg[k] == nil then cfg[k] = copy(v) end
    end
    -- new gun / radar settings appear in an older strike.cfg
    for _, sec in ipairs({ "gun", "radar" }) do
      if type(cfg[sec]) == "table" and S.DEFAULTS[sec] then
        for k, v in pairs(S.DEFAULTS[sec]) do
          if cfg[sec][k] == nil then cfg[sec][k] = copy(v) end
        end
      end
    end
    -- PA lines for the stratagems of an older strike.cfg: those of the
    -- built-in stratagem with the same name (else the same code)
    for _, s in ipairs(type(cfg.stratagems) == "table" and cfg.stratagems or {}) do
      if type(s) == "table" and s.voice == nil then
        local match
        for _, d in ipairs(S.DEFAULTS.stratagems) do
          if d.name == s.name then match = d break end
          if d.code == s.code then match = match or d end
        end
        if match then s.voice = copy(match.voice) end
      end
    end
    S.cfg = cfg
  else
    S.cfg = copy(S.DEFAULTS)
    S.saveConfig()
  end
  S.applyDemo()
end

-- demo: every stratagem made a dry run while running (each one's own
-- dryRun kept in S.realDry - that is what strike.cfg is saved with)
function S.applyDemo()
  local list = type(S.cfg.stratagems) == "table" and S.cfg.stratagems or {}
  for i, real in pairs(S.realDry or {}) do
    if list[i] then list[i].dryRun = real or nil end
  end
  S.realDry = {}
  if S.cfg.demo ~= true then return end
  for i, s in ipairs(list) do
    if type(s) == "table" then
      S.realDry[i] = s.dryRun or false
      s.dryRun = true
    end
  end
end

function S.saveConfig()
  local list = type(S.cfg.stratagems) == "table" and S.cfg.stratagems or {}
  for i, real in pairs(S.realDry or {}) do
    if list[i] then list[i].dryRun = real or nil end
  end
  local ok = pcall(function()
    local h = fs.open(S.FILES.cfg, "w")
    h.write("-- strike.cfg - settings for strike " .. S.VERSION .. ". Edit, save, then reboot (heights: use the height command).\n")
    h.write(textutils.serialize(S.cfg))
    h.close()
  end)
  for i in pairs(S.realDry or {}) do
    if list[i] then list[i].dryRun = true end
  end
  return ok
end

-- Check the stratagem list; returns a list of problems (empty = fine)
function S.checkStratagems(list)
  local problems, codes = {}, {}
  for i, s in ipairs(list or {}) do
    local tag = "stratagem " .. i .. " (" .. tostring(s.name) .. ")"
    if type(s.name) ~= "string" then problems[#problems + 1] = tag .. ": no name" end
    if type(s.code) ~= "string" or not s.code:match("^[UDLR]+$") then
      problems[#problems + 1] = tag .. ": code must be letters U D L R"
    elseif codes[s.code] then
      problems[#problems + 1] = tag .. ": same code as " .. codes[s.code]
    else
      codes[s.code] = tostring(s.name)
    end
    if not s.dryRun and s.kind ~= "escape" and (type(s.output) ~= "table" or type(s.output.side) ~= "string") then
      problems[#problems + 1] = tag .. ": needs output = { side = ... } (or dryRun = true)"
    end
    if s.kind == "escape" then
      if type(s.altitude) ~= "number" then problems[#problems + 1] = tag .. ": altitude must be a world Y" end
    elseif s.kind == "gun" then
      if not G then problems[#problems + 1] = tag .. ": gunner.lua is missing" end
    elseif s.kind == "carpet" or s.kind == "barrage" then
      -- load: one ammo link, or (barrage) a list used in turn
      local loads = type(s.load) == "table" and (s.load[1] and s.load or { s.load }) or {}
      local okLoad = #loads > 0
      for _, l in ipairs(loads) do
        if type(l) ~= "table" or type(l.side) ~= "string" then okLoad = false end
      end
      if not s.dryRun and not okLoad then
        problems[#problems + 1] = tag .. ": needs load = { relay = ..., side = ... } (the ammo link)"
      end
      if s.kind == "carpet" then
        if type(s.loadTime) ~= "number" or s.loadTime < 0 then problems[#problems + 1] = tag .. ": bad loadTime" end
        if s.load and s.load[1] then problems[#problems + 1] = tag .. ": a carpet takes one load link" end
        if type(s.volleyGaps) ~= "table" then problems[#problems + 1] = tag .. ": volleyGaps must be a list of seconds" end
        if s.flushAfter ~= nil and (type(s.flushAfter) ~= "number" or s.flushAfter < 0) then problems[#problems + 1] = tag .. ": bad flushAfter" end
      else
        if type(s.fireTime) ~= "number" or s.fireTime < 0 then problems[#problems + 1] = tag .. ": bad fireTime" end
        if type(s.fireEvery) ~= "number" or s.fireEvery < 0.1 then problems[#problems + 1] = tag .. ": fireEvery must be at least 0.1 s" end
        if type(s.loads) ~= "number" or s.loads < 1 then problems[#problems + 1] = tag .. ": loads must be 1 or more" end
        if type(s.loadEvery) ~= "number" or s.loadEvery < 1 then problems[#problems + 1] = tag .. ": loadEvery must be at least 1 s" end
        if type(s.fireDelay) ~= "number" or s.fireDelay < 0 then problems[#problems + 1] = tag .. ": bad fireDelay" end
        for _, k in ipairs({ "flush" }) do
          if s[k] ~= nil and (type(s[k]) ~= "number" or s[k] < 0) then problems[#problems + 1] = tag .. ": bad " .. k end
        end
      end
    elseif s.kind == "rail" and not s.fireEvery then
      -- one pulse (like a carpet volley): no fireTime
      if s.flushAfter ~= nil and (type(s.flushAfter) ~= "number" or s.flushAfter < 0) then
        problems[#problems + 1] = tag .. ": bad flushAfter"
      end
    elseif type(s.fireTime) ~= "number" or s.fireTime < 0 then
      problems[#problems + 1] = tag .. ": bad fireTime"
    elseif s.fireEvery ~= nil and (type(s.fireEvery) ~= "number" or s.fireEvery < 0.1) then
      problems[#problems + 1] = tag .. ": fireEvery must be at least 0.1 s"
    end
    if s.kind == "rail" and s.pickRadius ~= nil and (type(s.pickRadius) ~= "number" or s.pickRadius <= 0) then
      problems[#problems + 1] = tag .. ": pickRadius must be a number of blocks"
    end
    if s.kind == "rail" and s.load ~= nil and (type(s.load) ~= "table" or type(s.load.side) ~= "string"
      or type(s.loadTime) ~= "number") then
      problems[#problems + 1] = tag .. ": load needs { relay = ..., side = ... } and loadTime (seconds)"
    end
    if s.accuracy ~= nil and (type(s.accuracy) ~= "number" or s.accuracy <= 0) then
      problems[#problems + 1] = tag .. ": accuracy must be a number of blocks"
    end
    local o = s.offset
    if type(o) ~= "table" or type(o.r) ~= "number" or type(o.u) ~= "number" or type(o.f) ~= "number" then
      problems[#problems + 1] = tag .. ": offset must be { r = .., u = .., f = .. }"
    end
  end
  -- the pocket calls a code as soon as it is complete: a code that starts
  -- another one would make the longer one impossible to call
  for _, a in ipairs(list or {}) do
    for _, b in ipairs(list or {}) do
      if a ~= b and type(a.code) == "string" and type(b.code) == "string" and #a.code < #b.code
        and b.code:sub(1, #a.code) == a.code then
        problems[#problems + 1] = ("%s (%s) can never be called: %s (%s) is the start of it"):format(
          tostring(b.name), b.code, tostring(a.name), a.code)
      end
    end
  end
  return problems
end

function S.findStratagem(code)
  for _, s in ipairs(S.cfg.stratagems) do
    if s.code == code then return s end
  end
end

local function allowedPocket(id)
  for _, p in ipairs(S.cfg.pockets) do
    if p == id then return true end
  end
  return false
end

---------------------------------------------------------------- redstone outputs
-- Pulses are queued per output so ON and OFF can never merge into one pulse.

S.pulses = {}       -- key -> { queue = n, high = bool, timer = id }
S.timers = {}       -- timer id -> key

local function outKey(out) return (out.relay or "computer") .. ":" .. out.side end

local function setOut(out, on)
  if out.relay then
    return pcall(peripheral.call, out.relay, "setOutput", out.side, on)
  end
  return pcall(redstone.setOutput, out.side, on)
end

function S.pulse(out)
  local key = outKey(out)
  local p = S.pulses[key]
  if not p then
    p = { out = out, queue = 0, high = false }
    S.pulses[key] = p
  end
  p.queue = p.queue + 1
  if not p.timer then S.pulseNext(key) end
end

-- Timer step: go high (start a pulse), go low, or rest one pulse length between pulses
function S.pulseNext(key)
  local p = S.pulses[key]
  if p.high then
    setOut(p.out, false)
    p.high = false
    p.timer = os.startTimer(S.cfg.pulse)       -- gap before any next pulse
  elseif p.queue > 0 then
    p.queue = p.queue - 1
    local ok, err = setOut(p.out, true)
    if not ok then
      S.log("Output " .. key .. " failed: " .. tostring(err))
      if now() >= (S.malfunctionAt or -1e9) then
        S.malfunctionAt = now() + 10
        S.say("malfunction", "strike")
      end
    end
    p.high = true
    p.timer = os.startTimer(S.cfg.pulse)
  else
    p.timer = nil
    return
  end
  S.timers[p.timer] = key
end

-- Run fn after `secs` (a main-loop timer)
S.calls = {}
function S.after(secs, fn)
  local id = os.startTimer(secs)
  S.calls[id] = fn
  return id
end

-- Pulse `out` every `every` seconds until m.fireEnd or the mission ends:
-- high for half the period in whole ticks (0.25 s: 2 ticks on, 3 off)
function S.rapidFire(m, out, every)
  local hi = math.max(0.05, math.floor(every * 10) / 20)
  local lo = math.max(0.05, every - hi)
  m.rapid = { out = out, n = 0 }
  local function step()
    if S.mission ~= m or not m.rapid or now() >= m.fireEnd then return end
    setOut(out, true)
    m.rapid.n = m.rapid.n + 1
    S.after(hi, function()
      setOut(out, false)
      S.after(lo, step)
    end)
  end
  step()
end

---------------------------------------------------------------- messaging

function S.openModems()
  S.haveWired, S.haveWireless = false, false
  for _, side in ipairs(rs.getSides()) do
    if peripheral.hasType(side, "modem") then
      pcall(rednet.open, side)
      if peripheral.call(side, "isWireless") then S.haveWireless = true else S.haveWired = true end
    end
  end
  if S.haveWireless then pcall(rednet.host, S.PROTO_POCKET, S.HOSTNAME) end
end

-- (id 0 = typed at this computer: no pocket to tell)
function S.toPocket(id, msg)
  if id and id ~= 0 then pcall(rednet.send, id, msg, S.PROTO_POCKET) end
end

function S.toHelm(msg)
  pcall(rednet.send, S.cfg.helmId, msg, S.PROTO_HELM)
end

-- Tell the caller how the mission is going (m: default the ship's mission)
function S.report(text, extra, m)
  m = m or S.mission
  if not m or m == S.mission then S.statusText = text end
  if not m then return end
  local msg = { op = "status", id = m.id, name = m.strat.name, text = text }
  for k, v in pairs(extra or {}) do msg[k] = v end
  S.toPocket(m.pocket, msg)
end

---------------------------------------------------------------- PA system
-- pa.lua on its own computer on the wired network says the lines. It says
-- "hello" when it starts and answers "who" (sent when strike starts).
-- group: lines of one stratagem share it ("m" .. mission id) - a newer one
-- cuts off the one playing; hold: always said in full (request lines).

S.PROTO_PA = "destroyer.pa"
S.paPending = {}

function S.say(line, group, hold)
  if type(line) ~= "string" then return end
  local msg = { op = "say", line = line, group = group, hold = hold or nil }
  if S.paId then
    pcall(rednet.send, S.paId, msg, S.PROTO_PA)
  else
    -- no PA heard from yet: keep the last few for when it answers
    S.paPending[#S.paPending + 1] = { msg = msg, at = now() }
    if #S.paPending > 8 then table.remove(S.paPending, 1) end
  end
end

function S.fromPA(id, msg)
  if msg.op ~= "hello" then return end
  S.paId = id
  local pending = S.paPending
  S.paPending = {}
  for _, p in ipairs(pending) do
    if now() - p.at < 60 then pcall(rednet.send, id, p.msg, S.PROTO_PA) end
  end
end

-- A line of mission m: its stratagem's voice[key], or a line by name
function S.voice(m, key, hold)
  local v = m.strat.voice
  if type(v) == "table" and type(v[key]) == "string" then
    S.say(v[key], "m" .. m.id, hold)
    -- the fire line in every pair of HUD glasses too (a volley loop says it
    -- more than once: the glasses play it once per mission)
    if key == "fire" and S.haveWireless then
      pcall(rednet.broadcast, { op = "voice", key = key, line = v[key], id = m.id, name = m.strat.name }, S.PROTO_HUD)
    end
  end
end
function S.sayFor(m, line) S.say(line, "m" .. m.id) end

-- The ship's move line for a trip of `dist` blocks
function S.alignLine(dist)
  if dist < 150 then return "align_near" end
  if dist <= 1000 then return "align_mid" end
  return "align_far"
end

---------------------------------------------------------------- missions
-- S.mission = the stratagem holding the ship: { id, pocket, strat, disp,
--   stage = "FLY"|"AIM"|"SCAN"|"FIRE"|"END", latchOn, fireEnd, call }
-- S.side = an aimable stratagem firing from where the ship is, beside it
-- S.queue = calls waiting for the ship: { id, pocket, msg, strat, rel, tW }

S.queue = {}

function S.refuse(pocket, id, why)
  S.log("Call refused: " .. why)
  if pocket == 0 then S.reply = "call refused: " .. why end
  S.toPocket(pocket, { op = "status", id = id, text = "REFUSED: " .. why, done = true, ok = false })
  S.say("denied", "strike")
end

-- aimable: fires at its target from wherever the ship is in reach (Gatling)
function S.aimable(strat)
  if strat.aimable ~= nil then return strat.aimable == true end
  return strat.kind == "gun"
end

-- Can stratagem s be called right now? false + why = greyed out on the HUD
-- (cfg: disabled = true or a reason marks one broken by hand)
function S.ready(s)
  if s.disabled then return false, type(s.disabled) == "string" and s.disabled or "disabled" end
  if not S.helmSeen or now() - S.helmSeen > S.cfg.helmTimeout then return false, "helm not answering" end
  if not S.helmCalibrated then return false, "helm not calibrated" end
  if s.dryRun then return true end
  local links = {}
  if type(s.output) == "table" then links[#links + 1] = s.output end
  if type(s.load) == "table" then
    for _, l in ipairs(s.load[1] and s.load or { s.load }) do links[#links + 1] = l end
  end
  for _, l in ipairs(links) do
    if type(l) == "table" and l.relay and not peripheral.isPresent(l.relay) then
      return false, l.relay .. " missing"
    end
  end
  if s.kind == "rail" then
    local ok, why = S.radarReady()
    if not ok then return false, why end
  elseif s.kind == "gun" then
    if not G then return false, "gunner.lua missing" end
    if not G.calReady(S.gunner and S.gunner.cal) then return false, "guns not calibrated" end
  end
  return true
end

function S.call(pocket, msg)
  local function refuse(why) S.refuse(pocket, msg.id, why) end
  local strat = S.findStratagem(msg.code)
  if not strat then return refuse("unknown code") end
  local r = msg.rel
  if type(r) ~= "table" or type(r.r) ~= "number" or type(r.u) ~= "number" or type(r.f) ~= "number" then
    return refuse("no position")
  end
  if not S.helmSeen or now() - S.helmSeen > S.cfg.helmTimeout then return refuse("helm not answering") end
  if not S.helmCalibrated then return refuse("helm not calibrated") end
  S.nextId = (S.nextId or 0) + 1
  local c = { id = S.nextId, pocket = pocket, msg = msg, strat = strat, rel = { r = r.r, u = r.u, f = r.f }, at = now() }
  -- the caller's spot fixed in the world (helm's frame), so a call that
  -- waits still goes where it was made, wherever the ship flies meanwhile
  if type(S.helmNav) == "table" and S.helmAxes then c.tW = v3add(S.helmNav, shipToWorld(c.rel, S.helmAxes)) end
  if strat.kind == "escape" then
    -- an emergency: everything else is called off, no waiting in the queue
    -- (but only once it is sure it can go)
    if type(S.helmNav) ~= "table" or not S.helmAxes then return refuse("no ship height from helm yet (update helm)") end
    if S.mission or S.side or #S.queue > 0 then S.cancelAll("emergency escape", true) end
    return S.begin(c)
  end
  if not (S.mission or S.side or #S.queue > 0) then return S.begin(c) end
  -- aimable and in reach from here: fire beside the current stratagem
  -- (the gun bank free, the ship not flying)
  if S.aimable(strat) and not S.side and not (S.mission and (S.mission.gun or S.mission.stage == "FLY")) then
    local ok, why = S.sideStart(c)
    if ok then return end
    if why then return refuse(why) end
  end
  if not c.tW then return refuse("busy with another stratagem (update helm to queue calls)") end
  if #S.queue >= (S.cfg.maxQueue or 4) then return refuse("too many stratagems waiting") end
  c.queued = true
  S.queue[#S.queue + 1] = c
  local ahead = #S.queue - 1 + ((S.mission or S.side) and 1 or 0)
  S.log(("Call %s from pocket %d queued (%d ahead)"):format(strat.name, pocket, ahead))
  S.say("awaiting", "m" .. c.id)
  S.toPocket(pocket, { op = "status", id = c.id, name = strat.name,
    text = ("QUEUED - awaiting current stratagem (%d ahead)"):format(ahead) })
end

-- A call on world coordinates (F3: the pocket's C screen, or "call
-- <stratagem> x y z" typed here). The plane radar gives the ship's true
-- world position, so the spot becomes a position from the nav table, the
-- same as a GPS call. Reading the radar waits on the server, so it is done
-- in the gun coroutine (S.coordService).
S.coordQueue = {}

function S.worldToRel(w)
  local R = S.cfg.radar
  if not S.helmAxes then return nil, "no ship orientation from helm yet" end
  if type(R) ~= "table" or type(R.anchorFromNav) ~= "table" then
    return nil, "coordinates need the plane radar (radar.anchorFromNav in strike.cfg)"
  end
  local name = S.radarName("anchor")
  if not name then return nil, "coordinates need the plane radar - none on the network" end
  local ok, p = pcall(peripheral.call, name, "getPosition")
  local a = ok and v3of(p)
  if not a then return nil, "cannot read the plane radar's position" end
  local navW = v3sub(a, shipToWorld(R.anchorFromNav, S.helmAxes))
  return worldToShip(v3sub(w, navW), S.helmAxes), navW
end

function S.coordService()
  while #S.coordQueue > 0 do
    local q = table.remove(S.coordQueue, 1)
    local rel, navW = S.worldToRel(q.world)
    if not rel then
      S.refuse(q.pocket, q.msg.id, navW)
    else
      S.log(("Coordinates %.1f %.1f %.1f: nav table at %.1f %.1f %.1f -> r %.1f u %.1f f %.1f"):format(
        q.world[1], q.world[2], q.world[3], navW[1], navW[2], navW[3], rel.r, rel.u, rel.f))
      if q.pocket == 0 then S.reply = nil end
      S.call(q.pocket, { op = "call", id = q.msg.id, code = q.msg.code, rel = { r = rel.r, u = rel.u, f = rel.f } })
      if q.pocket == 0 and not S.reply then
        S.reply = ("%s called at %g %g %g"):format(q.name or q.msg.code, q.world[1], q.world[2], q.world[3])
      end
    end
    if q.pocket == 0 then S.draw() end
  end
end

-- Start the next waiting call once the ship (and the gun bank) are free
function S.advance()
  while not S.mission and not S.side and #S.queue > 0 do
    S.begin(table.remove(S.queue, 1))
  end
end

-- Tell everyone waiting that they are called off
function S.dropQueue(text)
  for _, c in ipairs(S.queue) do
    S.toPocket(c.pocket, { op = "status", id = c.id, name = c.strat.name, text = "ABORTED: " .. text, done = true, ok = false })
  end
  if #S.queue > 0 then S.log(("%d waiting call(s) dropped: %s"):format(#S.queue, text)) end
  S.queue = {}
end

-- Abort: everything (the ship's stratagem, the aimable one, the queue).
-- Returns false if there was nothing to call off.
function S.cancelAll(text, quiet)
  local m = S.mission or S.side
  local any = m or #S.queue > 0
  local group = m and ("m" .. m.id) or "strike"
  S.dropQueue(text)
  if S.side then S.finish(false, text, S.side) end
  if S.mission then S.finish(false, text, S.mission) end
  if any and not quiet then S.say("cancelled", group) end
  return any and true or false
end

-- An aimable stratagem beside the current one: only if it can fire from
-- where the ship is. Returns true (started), false (out of reach: queue it)
-- or false + why (refused)
function S.sideStart(c)
  local strat, r = c.strat, c.rel
  if strat.kind ~= "gun" or not G or not S.helmAxes then return false end
  local cal = S.gunner and S.gunner.cal
  local calOk = G.calReady(cal)
  if not calOk and not strat.dryRun then return false, "guns not calibrated - type gunner cal at the strike computer" end
  local plan = G.plan(r, S.helmAxes, strat.offset.u, S.cfg.gun, calOk and cal or nil)
  if not plan or not plan.stay then return false end
  local m = { id = c.id, pocket = c.pocket, strat = strat, side = true, stage = "AIM", aimStart = now(),
    heard = now(), started = now(), gun = { plan = plan, calOk = calOk }, call = c,
    -- the caller from the nav table (world), if helm gives no position
    aimW = shipToWorld(r, S.helmAxes) }
  S.side = m
  S.log(("Call %s from pocket %d beside %s - %s"):format(strat.name, c.pocket,
    S.mission and S.mission.strat.name or "the queue", plan.why))
  S.voice(m, "call", true)
  S.voice(m, "aim")
  S.report(("%s called - firing from here"):format(strat.name), { phase = "AIM" }, m)
  S.sideTrack({})
  return true
end

-- Keep the aimable stratagem's target up to date from helm's reports
function S.sideTrack(msg)
  local m = S.side
  if not m or not S.helmAxes then return end
  local tW = m.call and m.call.tW
  local aim = (tW and type(S.helmNav) == "table") and v3sub(tW, S.helmNav) or m.aimW
  local g = m.gun
  S.gunSolve(m, { aim = aim, axes = S.helmAxes, speed = msg.speed or g.speed, turn = msg.turn or g.turn })
end

-- Start a call (at once, or when its turn in the queue comes)
function S.begin(c)
  local strat, pocket, msg = c.strat, c.pocket, c.msg
  local function refuse(why) S.refuse(pocket, c.id, why) end
  local r = c.rel
  if c.queued then
    if not S.helmSeen or now() - S.helmSeen > S.cfg.helmTimeout then return refuse("helm not answering") end
    -- where it was called, from where the ship is now
    if c.tW and type(S.helmNav) == "table" and S.helmAxes then r = worldToShip(v3sub(c.tW, S.helmNav), S.helmAxes) end
  end
  local o = strat.offset
  local disp = { r = r.r + o.r, u = r.u + o.u, f = r.f + o.f }
  local gun, aim
  if strat.kind == "gun" then
    -- fire from where the ship is if it can, else from the stand-off point
    if not S.helmAxes then return refuse("no ship orientation from helm yet (update helm)") end
    local cal = S.gunner and S.gunner.cal
    local calOk = G.calReady(cal)
    if not calOk and not strat.dryRun then return refuse("guns not calibrated - type gunner cal at the strike computer") end
    local plan, why = G.plan(r, S.helmAxes, o.u, S.cfg.gun, calOk and cal or nil)
    if not plan then return refuse(why) end
    disp, aim = plan.disp, { r = r.r, u = r.u, f = r.f }
    gun = { plan = plan, calOk = calOk }
  end
  if strat.kind == "escape" then
    -- straight up to world Y `altitude` (helm's height is the true one)
    if type(S.helmNav) ~= "table" or not S.helmAxes then return refuse("no ship height from helm yet (update helm)") end
    local up = strat.altitude - S.helmNav[2]
    if up <= (strat.accuracy or 8) then
      S.log(("Escape: already at Y %.0f"):format(S.helmNav[2]))
      S.say(type(strat.voice) == "table" and strat.voice.arrive or nil, "m" .. c.id)
      S.toPocket(pocket, { op = "status", id = c.id, name = strat.name, done = true, ok = true,
        text = ("COMPLETE: already at Y %.0f"):format(S.helmNav[2]) })
      return
    end
    local d = worldToShip({ 0, up, 0 }, S.helmAxes)
    disp = { r = d.r, u = d.u, f = d.f }
  end
  local rail
  if strat.kind == "rail" then
    -- the railcannon starts where the ship is: the target is picked from
    -- the radar first (S.railService); no target, no loading
    if not S.helmAxes then return refuse("no ship orientation from helm yet") end
    local ok, why = S.radarReady()
    if not ok then return refuse(why) end
    if S.flushJob then
      S.flushJob = nil
      S.log("Flush cancelled - new stratagem called")
    end
    S.mission = { id = c.id, pocket = pocket, strat = strat, disp = { r = 0, u = 0, f = 0 }, stage = "SCAN",
      heard = now(), started = now(), call = c, rail = { phase = "PICK", rel = { r = r.r, u = r.u, f = r.f } } }
    S.log(("%s %s from pocket %d: caller r %.1f u %.1f f %.1f - picking the target"):format(
      c.queued and "Starting queued" or "Call", strat.name, pocket, r.r, r.u, r.f))
    S.voice(S.mission, "call", true)
    S.report(("%s %s - picking the target"):format(strat.name, c.queued and "starting" or "called"), { phase = "AIM" })
    return
  end
  local dist = math.sqrt(disp.r ^ 2 + disp.u ^ 2 + disp.f ^ 2)
  -- (maxRange guards against a wild GPS fix: the escape climb uses none)
  if dist > S.cfg.maxRange and strat.kind ~= "escape" then
    return refuse(("too far (%.0f > %.0f blocks)"):format(dist, S.cfg.maxRange))
  end
  if S.flushJob then
    S.flushJob = nil
    S.log("Flush cancelled - new stratagem called")
  end
  S.mission = { id = c.id, pocket = pocket, strat = strat, disp = disp, stage = "FLY",
    heard = now(), started = now(), gun = gun, rail = rail, call = c }
  S.log(("%s %s from pocket %d: disp r %.1f u %.1f f %.1f (%.0f blocks)%s"):format(c.queued and "Starting queued" or "Call",
    strat.name, pocket, disp.r, disp.u, disp.f, dist, gun and (" - " .. gun.plan.why) or ""))
  -- the request line in full, then the move line (if the ship moves)
  local tol = rail and (strat.flyAccuracy or 8) or strat.accuracy or 0.5
  S.voice(S.mission, "call", true)
  if dist > tol and not (type(strat.voice) == "table" and strat.voice.noAlign) then
    S.sayFor(S.mission, S.alignLine(dist))
  end
  if strat.kind == "carpet" or strat.kind == "barrage" then
    -- loading takes the time: dispense the ammo before flying anywhere
    -- (a barrage needs no full volley: it starts after fireDelay)
    local m = S.mission
    local wait = strat.kind == "barrage" and strat.fireDelay or strat.loadTime
    m.readyAt, m.loads = now() + wait, 1
    if strat.dryRun then
      S.log("Loading (dry run - no output)")
    else
      S.pulse(S.loadOut(strat, 1))
      S.log(("Ammo dispensing - firing starts in %g s or on arrival, whichever is later"):format(wait))
    end
    if strat.kind == "barrage" then
      if strat.dryRun then S.log("Ammo load 1/" .. strat.loads .. " (dry run)") end
      S.after(strat.loadEvery, function() S.reload(m) end)
    end
  end
  S.mission.gotoMsg = { op = "goto", id = S.mission.id, disp = disp, tol = tol, aim = aim }
  S.toHelm(S.mission.gotoMsg)
  S.report(gun and gun.plan.stay and ("%s %s - firing from here"):format(strat.name, c.queued and "starting" or "called")
    or ("%s %s - %.0f blocks"):format(strat.name, c.queued and "starting" or "called", dist), { phase = "CALLED", dist = dist })
end

---------------------------------------------------------------- guns
-- Everything that touches the gun hardware runs in S.gunLoop, its own
-- coroutine: a peripheral call makes the caller wait, and while one waits
-- the other events that reach it are lost (helm messages, pulse timers).

S.gunQueue = {}

-- The gun bank's firing solution from helm's latest state: aim = the caller
-- from the nav table (world), axes = the ship's bow/right/up (world)
-- (main loop: only store it - solving takes a few tenths of a second in CC
-- and is done by the gun coroutine, S.gunResolve)
function S.gunSolve(m, msg)
  if type(msg.aim) ~= "table" or type(msg.axes) ~= "table" then return end
  local P = S.cfg.gun
  m.gun.latest = { aim = msg.aim, axes = msg.axes }
  m.gun.speed, m.gun.turn = msg.speed, msg.turn
  m.gun.steady = (msg.speed or 99) < P.steadySpeed and math.abs(msg.turn or 99) < P.steadyTurn
end

-- Solve again when the target moved a third of a block, the ship turned, or
-- a second passed - not on every report
function S.gunResolve(m)
  local g = m.gun
  local L = g.latest
  if not L then return end
  local P = S.cfg.gun
  local a = G.shipToWorld(P.arrayFromNav, L.axes)
  local d = { L.aim[1] - a[1], L.aim[2] - a[2], L.aim[3] - a[3] }
  if g.d and g.axes and g.solvedAt and now() - g.solvedAt < 1 then
    local moved = math.sqrt((d[1] - g.d[1]) ^ 2 + (d[2] - g.d[2]) ^ 2 + (d[3] - g.d[3]) ^ 2)
    local same = L.axes.f[1] * g.axes.f[1] + L.axes.f[2] * g.axes.f[2] + L.axes.f[3] * g.axes.f[3] > 0.99999
    if moved < 0.3 and same then return end
  end
  local cal = g.calOk and S.gunner.cal or nil
  local sol = G.fireSolution(d, P, cal and cal.eMin, cal and cal.eMax, g.sol and g.sol.elev)
  g.sol, g.axes, g.d, g.solvedAt, g.new = sol, L.axes, d, now(), sol ~= nil
end

-- On station but no shot from here (the ship stopped off its mark, or ended
-- up facing so the gun bank is out of reach): fly again, to the approach
-- point from where the ship is now, instead of waiting for the timeout
function S.gunReplan(m)
  local g, L = m.gun, m.gun.latest
  if m.side then
    -- beside another stratagem it cannot move the ship: wait for it
    S.side, S.gunStop = nil, true
    local c = m.call
    c.queued = true
    if c.tW then table.insert(S.queue, 1, c) end
    S.log("No shot from here - " .. (c.tW and "waiting for the ship" or "called off (update helm to queue calls)"))
    if c.tW then
      S.sayFor(m, "awaiting")
      S.report("QUEUED - out of reach from here, awaiting current stratagem", { phase = "QUEUED" }, m)
      S.after(0.5, S.advance)                 -- (in case the ship is free by now)
    else
      S.finish(false, "no shot from here while the ship is busy", m, "no_solution")
    end
    return
  end
  local cal = g.calOk and S.gunner.cal or nil
  local rel = G.worldToShip(L.aim, L.axes)
  local plan, why = G.plan(rel, L.axes, m.strat.offset.u, S.cfg.gun, cal, true)
  if not plan then return S.finish(false, "no firing solution: " .. tostring(why), m, "no_solution") end
  g.replans = (g.replans or 0) + 1
  g.plan, g.noSolSince, g.onSince = plan, nil, nil
  m.stage, m.heard, m.disp = "FLY", now(), plan.disp
  S.log("No shot from here - moving again: " .. plan.why)
  S.sayFor(m, "repositioning")
  S.toHelm({ op = "release", id = m.id })
  S.toHelm({ op = "goto", id = m.id, disp = plan.disp, tol = m.strat.accuracy or 0.5,
    aim = { r = rel.r, u = rel.u, f = rel.f } })
  S.report("MOVING CLOSER", { phase = "FLY" }, m)
end

function S.fireGun(m)
  local g = m.gun
  m.stage = "FIRE"
  local secs = g.sol and g.sol.ticks / 20
  local what = g.sol and ("elevation %.1f, impact in %.1f s, target %.0f across %.0f down"):format(
    g.sol.elev, secs, math.sqrt(g.d[1] ^ 2 + g.d[3] ^ 2), -g.d[2]) or "no solution"
  if m.strat.dryRun then
    S.log("On target (dry run - not fired): " .. what)
  else
    S.pulse(m.strat.output)                   -- one pulse fires
    S.log("FIRED: " .. what)
  end
  S.voice(m, "fire")
  g.impactAt = secs and now() + secs
  m.fireEnd = now() + (m.strat.fireTime or 2)
  S.report(m.strat.dryRun and "ON TARGET (dry run)" or ("FIRED - impact in %.0f s"):format(secs or 0),
    { phase = "FIRE", remaining = secs }, m)
end

-- The mission using the gun bank: the aimable one beside, or the ship's
function S.gunMission()
  if S.side then return S.side end
  if S.mission and S.mission.gun then return S.mission end
end

-- One gun step (every 0.2 s, in the gun coroutine)
function S.gunService()
  local gn = S.gunner
  if not gn then return end
  if not S.gunStarted then
    S.gunStarted = true
    S.log("gunner: " .. gn:startup())
  end
  while #S.gunQueue > 0 do
    local words = table.remove(S.gunQueue, 1)
    local ok, reply = pcall(S.gunCommand, words)
    if not ok then reply = "gunner error: " .. tostring(reply) end
    S.reply = reply or S.reply
    S.log("> " .. table.concat(words, " ") .. "  ->  " .. tostring(reply))
    S.draw()
  end
  if S.gunStop then
    S.gunStop = false
    gn:stopAll()
  end
  local m = S.gunMission()
  local g = m and m.gun
  if g and (m.stage == "FLY" or m.stage == "AIM") then S.gunResolve(m) end
  if g and g.calOk and (m.stage == "FLY" or m.stage == "AIM") and g.new then
    g.new = false
    local ok, why = gn:point(g.sol.dir, g.axes)
    g.pointErr = not ok and why or nil
  end
  if gn.job or next(gn.axis) then gn:step() end
  if g and m.stage == "AIM" then
    local P = S.cfg.gun
    if g.calOk and g.pointErr then return S.finish(false, "cannot aim: " .. g.pointErr, m, "malfunction") end
    if g.calOk and gn.msg and gn.msg:find("not turning") then return S.finish(false, "guns: " .. gn.msg, m, "malfunction") end
    local on = (not g.calOk) or gn:onTarget()
    if now() >= (g.logAt or 0) then
      g.logAt = now() + 2
      local ya, pa = gn.axis.yaw, gn.axis.pitch
      S.log(("aim: yaw err %s, pitch err %s, on %s, steady %s (speed %.2f turn %.2f), solution %s"):format(
        ya and ("%.2f"):format(ya.err or 0) or "-", pa and ("%.2f"):format(pa.err or 0) or "-", tostring(on),
        tostring(g.steady), g.speed or -1, g.turn or -1, g.sol and ("%.1f"):format(g.sol.elev) or "none"))
    end
    if on and g.steady and g.sol then
      g.onSince = g.onSince or now()
      if now() - g.onSince >= P.settle then S.fireGun(m) end
    else
      g.onSince = nil
    end
    if g.sol or not g.latest then
      g.noSolSince = nil
    else
      g.noSolSince = g.noSolSince or now()
      if now() - g.noSolSince >= (P.replanAfter or 3) and (g.replans or 0) < 2 then
        return S.gunReplan(m)
      end
    end
    if m.stage == "AIM" and now() - m.aimStart > P.aimTimeout then
      S.finish(false, g.sol and "could not get on target in time" or "no firing solution from here", m, "no_solution")
    end
  end
end

-- The radar's locked target as last seen: { id, pos = {x, y, z}, vel, at, category }
-- (nil: none, or not seen for maxAge s) - for the weapons to aim by
function S.lockedTrack(maxAge)
  local l = S.locked
  if not (S.lockTrack and l and l.id == S.lockTrack) then return nil end
  if now() - l.at > (maxAge or 5) then return nil end
  return l
end

-- Is a radar track friendly? (set on this ship; anything else is hostile)
function S.isFriendly(id)
  return type(S.cfg.friendly) == "table" and id ~= nil and S.cfg.friendly[tostring(id)] ~= nil
end

-- Mark a radar track friendly (label) or not (on = false) - from the war table
function S.setFriendly(id, on, label)
  id = tostring(id or "")
  if id == "" then return false end
  if type(S.cfg.friendly) ~= "table" then S.cfg.friendly = {} end
  S.cfg.friendly[id] = on and tostring(label or "FRIENDLY"):sub(1, 24) or nil
  S.saveConfig()
  S.log(("%s %s (%s)"):format(on and "Friendly:" or "No longer friendly:", id, tostring(label or "")))
  return true
end

-- Debris (wreckage): on strike.cfg's debris list, or (debrisAfter) a ship
-- the radar has seen sitting still that long - until it moves
S.still = {}                -- track id -> { p = where it stopped, since, seen }
S.STILL_MOVE = 1            -- blocks: less than this from where it stopped is still
function S.isDebris(id)
  id = tostring(id or "")
  if id == "" then return false end
  if type(S.cfg.debris) == "table" and S.cfg.debris[id] then return true end
  local after, s = tonumber(S.cfg.debrisAfter), S.still[id]
  return after ~= nil and after > 0 and s ~= nil and now() - s.since >= after
end

-- Mark a radar track debris (on) or not - typed at the strike computer
function S.setDebris(id, on)
  id = tostring(id or "")
  if id == "" then return false end
  if type(S.cfg.debris) ~= "table" then S.cfg.debris = {} end
  S.cfg.debris[id] = on and true or nil
  S.saveConfig()
  S.log(("%s %s"):format(on and "Debris:" or "No longer debris:", id))
  return true
end

-- Every radar look: when each ship last moved (for debrisAfter); a lock on
-- debris is let go (the weapons never aim at wreckage)
function S.noteStill(tracks)
  for _, t in ipairs(tracks) do
    local p, id = v3of(t.position), tostring(t.id or "")
    if p and id ~= "" and tostring(t.category or ""):upper() == "SABLE" and not (S.ownShipId and t.id == S.ownShipId) then
      local s = S.still[id]
      local moved = not s or math.max(math.abs(p[1] - s.p[1]), math.abs(p[2] - s.p[2]), math.abs(p[3] - s.p[3])) >= S.STILL_MOVE
      if moved then S.still[id] = { p = p, since = now(), seen = now() } else s.seen = now() end
    end
  end
  for id, s in pairs(S.still) do
    if now() - s.seen > 60 then S.still[id] = nil end
  end
  if S.lockTrack and S.isDebris(S.lockTrack) then
    S.log(("Radar lock: %s is debris - let go"):format(S.lockTrack:sub(1, 8)))
    S.lockTrack, S.lockManual = nil, nil
  end
end

-- Friendly for targeting: on the friendly list, shown as a friendly icon
-- (I on the map), or a helldiver whose glasses are heard (their own id)
S.FRIEND_ICONS = { helldiver = true, friendly_player = true, friendly_ship = true }
S.crew = {}
function S.isFriendlyTarget(id)
  id = tostring(id or "")
  if S.isFriendly(id) then return true end
  local d = type(S.cfg.designate) == "table" and S.cfg.designate[id]
  if d and S.FRIEND_ICONS[d] then return true end
  local c = S.crew[id]
  return c ~= nil and now() - c.at < 60
end

-- A helldiver's glasses telling the squad where they are (hd2.team "hi"):
-- their Minecraft id is a friendly player
function S.noteCrew(msg)
  if type(msg.uuid) == "string" and msg.uuid ~= "" then
    S.crew[msg.uuid] = { name = type(msg.user) == "string" and msg.user or tostring(msg.name or "?"), at = now() }
  end
end

-- Auto-lock (strike.cfg autoLock): no lock, or an auto lock gone from the
-- radar for 5 s -> the nearest player or ship that is not friendly and not
-- aboard (within radar.shipRadius of the nav table). A lock picked on the
-- map stays while the radar sees it; one let go there is not taken back for 30 s
function S.autoLock(tracks)
  if S.cfg.autoLock == false then return end
  local here = S.navWorld
  if not here then return end
  if S.lockTrack then
    for _, t in ipairs(tracks) do
      if tostring(t.id) == S.lockTrack and v3of(t.position) then
        S.lockSeen = now()
        return
      end
    end
    if now() - (S.lockSeen or now()) < 5 then return end
    S.log(("Radar lock: %s gone from the radar"):format(S.lockTrack:sub(1, 8)))
    S.lockTrack, S.lockManual = nil, nil
  end
  if S.lockReleasedAt and now() - S.lockReleasedAt < 30 then return end
  local R = type(S.cfg.radar) == "table" and S.cfg.radar or {}
  local best, bestD
  for _, t in ipairs(tracks) do
    local p, id, cat = v3of(t.position), tostring(t.id or ""), tostring(t.category or ""):upper()
    if p and id ~= "" and (cat == "PLAYER" or cat == "SABLE") and not (S.ownShipId and t.id == S.ownShipId)
      and not S.isFriendlyTarget(id) and not S.isDebris(id) then
      local dx, dy, dz = p[1] - here[1], p[2] - here[2], p[3] - here[3]
      local d = math.sqrt(dx * dx + dy * dy + dz * dz)
      if d > (R.shipRadius or 60) and (not bestD or d < bestD) then best, bestD = { id = id, cat = cat }, d end
    end
  end
  if best then
    S.lockTrack, S.lockSeen, S.lockManual = best.id, now(), nil
    S.log(("Auto-lock: %s %s, %.0f blocks"):format(best.cat == "PLAYER" and "player" or "ship", best.id:sub(1, 8), bestD))
  end
end

-- Players' usernames for the maps: the radar gives only UUIDs, so a Player
-- Detector (Advanced Peripherals) on the network, matched by where each
-- player is (the nearest within 3 blocks). A UUID once named stays named;
-- unnamed ones are looked for every 5 s at most
S.playerNames = {}
function S.namePlayers(tracks)
  local want = {}
  for _, t in ipairs(tracks) do
    local p = v3of(t.position)
    local id = tostring(t.id or "")
    if p and id ~= "" and tostring(t.category or ""):upper() == "PLAYER" and not S.playerNames[id] then
      want[#want + 1] = { id = id, p = p }
    end
  end
  if #want == 0 or now() < (S.nameAskAt or 0) then return end
  S.nameAskAt = now() + 5
  local okd, det = pcall(peripheral.find, "playerDetector")
  if not okd or type(det) ~= "table" then return end
  local ok, names = pcall(det.getOnlinePlayers)
  if not ok or type(names) ~= "table" then return end
  for i, name in ipairs(names) do
    if i > 16 then break end
    local okp, pos = pcall(det.getPlayerPos, name)
    local x = okp and type(pos) == "table" and tonumber(pos.x)
    if x then
      local y, z = tonumber(pos.y) or 0, tonumber(pos.z) or 0
      local best, bestD
      for _, w in ipairs(want) do
        local d = math.max(math.abs(w.p[1] - x), math.abs(w.p[2] - y), math.abs(w.p[3] - z))
        if not S.playerNames[w.id] and d < 3 and (not bestD or d < bestD) then best, bestD = w, d end
      end
      if best then S.playerNames[best.id] = tostring(name) end
    end
  end
end

-- The radar's contacts for the HUD glasses' map, once a second (radar reads
-- wait on the server, so this runs in the gun coroutine). hudRadar = false in
-- strike.cfg turns it off.
function S.hudRadar()
  if not S.haveWireless or S.cfg.hudRadar == false or now() < (S.hudRadarAt or 0) then return end
  S.hudRadarAt = now() + 1
  local name = S.radarName("radar")
  -- (what the radar gives, logged when it changes: why the maps go empty)
  local function state(s)
    S.radarState = s
    if s ~= S.radarLogged then
      S.radarLogged = s
      S.log("HUD radar: " .. s)
    end
  end
  if not name then return state("no radar on the network") end
  local ok, tr = pcall(peripheral.call, name, "getTracks")
  if not ok or type(tr) ~= "table" then return state("cannot read " .. name .. " (" .. tostring(tr) .. ")") end
  state(#tr > 0 and ("seeing contacts on " .. name) or ("no contacts on " .. name))
  S.lastTracks, S.lastTracksAt = tr, now()
  pcall(S.findOwnShip)
  -- (this ship's own track is the middle of its bounds - smooth, not snapped
  -- to a block like the plane radar's position. Where it is from the nav
  -- table, in the ship's frame, is averaged over the still moments at
  -- different blocks: the snapping evens out. Then, still, the nav table is
  -- placed from the track to a fraction of a block)
  if S.ownShipId and S.helmAxes then
    for _, t in ipairs(tr) do
      local p = v3of(t.position)
      if p and t.id == S.ownShipId then
        S.ownTrack = { p = p, at = now() }
        local sn = S.snapNav
        if S.shipStill() and sn and now() - (S.snapNavAt or -100) < 1.5 then
          local key = ("%.1f,%.1f,%.1f"):format(sn[1], sn[2], sn[3])
          if key ~= S.centreKey then
            S.centreKey = key
            local c = worldToShip(v3sub(p, sn), S.helmAxes)
            local a, n = S.centreAvg, math.min((S.centreN or 0) + 1, 50)
            if not a then
              a = { r = c.r, u = c.u, f = c.f }
            else
              a = { r = a.r + (c.r - a.r) / n, u = a.u + (c.u - a.u) / n, f = a.f + (c.f - a.f) / n }
            end
            S.centreAvg, S.centreN, S.centreFromNav = a, n, a
          end
        end
      end
    end
  end
  local okn, errn = pcall(S.namePlayers, tr)
  if not okn then S.log("player names: " .. tostring(errn)) end
  local okd, errd = pcall(S.noteStill, tr)
  if not okd then S.log("debris: " .. tostring(errd)) end
  local oka, erra = pcall(S.autoLock, tr)
  if not oka then S.log("auto-lock: " .. tostring(erra)) end
  local shipNames = type(S.cfg.shipNames) == "table" and S.cfg.shipNames or {}
  local out = {}
  -- (projectiles - shells, arrows - as blips: where and how fast, so the
  -- maps move them on between looks; at most 32, after everything else)
  local shots = 0
  for _, t in ipairs(tr) do
    local p, cat = v3of(t.position), tostring(t.category or ""):upper()
    if p and cat == "PROJECTILE" and shots < 32 then
      shots = shots + 1
      local v = v3of(t.velocity) or { 0, 0, 0 }
      local function r1(x) return math.floor(x * 10 + 0.5) / 10 end
      local function r2(x) return math.floor(x * 100 + 0.5) / 100 end
      out[#out + 1] = { x = r1(p[1]), y = r1(p[2]), z = r1(p[3]), c = "PROJECTILE", v = { r2(v[1]), r2(v[2]), r2(v[3]) } }
    end
  end
  local limit = 64 + shots
  for _, t in ipairs(tr) do
    local p = v3of(t.position)
    if p and #out < limit and tostring(t.category or ""):upper() ~= "PROJECTILE" and not (S.ownShipId and t.id == S.ownShipId) then
      local id = tostring(t.id or "")
      -- (f: friendly - set on this ship; n: its label; l: the radar's locked target)
      out[#out + 1] = { x = p[1], y = p[2], z = p[3], c = tostring(t.category or ""):upper(), id = id,
        f = S.isFriendly(id) or nil, n = S.isFriendly(id) and tostring(S.cfg.friendly[id]) or nil,
        l = (S.lockTrack ~= nil and id == S.lockTrack) or nil,
        d = type(S.cfg.designate) == "table" and S.cfg.designate[id] or nil,
        -- (dbr: debris - the maps draw it grey, with no icon)
        dbr = S.isDebris(id) or nil,
        -- (u: a player's username; sn: a ship's name - the maps show them)
        u = S.playerNames[id], sn = shipNames[id] ~= nil and tostring(shipNames[id]) or nil }
      if S.lockTrack and id == S.lockTrack then
        S.locked = { id = id, pos = p, vel = v3of(t.velocity), at = now(), category = out[#out].c }
      end
    end
  end
  pcall(rednet.broadcast, { op = "radar", tracks = out }, S.PROTO_HUD)
end

-- The ship's pose for the HUD glasses' war table: the nav table's world
-- position (plane radar - anchorFromNav) and helm's axes, every hudPose s.
-- t = server time (ms), so the glasses can tell how old it is and lead it
function S.hudPose()
  local every = S.cfg.hudPose
  if not S.haveWireless or not every or now() < (S.hudPoseAt or 0) then return end
  S.hudPoseAt = now() + every
  local R = S.cfg.radar
  if not S.helmAxes or type(R) ~= "table" or type(R.anchorFromNav) ~= "table" then return end
  local name = S.radarName("anchor")
  if not name then return end
  local ok, p = pcall(peripheral.call, name, "getPosition")
  local a = ok and v3of(p)
  if not a then return end
  local nav = v3sub(a, shipToWorld(R.anchorFromNav, S.helmAxes))
  S.snapNav, S.snapNavAt = nav, now()
  -- (still, with this ship's own radar track: the nav table from the track's
  -- smooth middle - the plane radar's position is snapped to a whole block)
  local own = S.ownTrack
  if own and now() - own.at < 1.5 and S.centreAvg and S.shipStill() then
    nav = v3sub(own.p, shipToWorld(S.centreAvg, S.helmAxes))
  end
  S.navWorld = nav                         -- (where the ship is, for the auto-lock's "nearest")
  -- (centre: the middle of the ship from the nav table {r, u, f}, when its own
  -- radar track is known; moving: under way - the war table hides meanwhile)
  pcall(rednet.broadcast, { op = "pose", nav = nav, axes = S.helmAxes, t = os.epoch("utc"), centre = S.centreFromNav,
    moving = S.shipMoving() or nil }, S.PROTO_HUD)
end

-- The ship status hologram (HUD glasses, status.lua): the ship's state every
-- hudStatus s. Where a stratagem's weapon is on the ship (from the nav table),
-- for its firing animation: its holo, else the railcannon's muzzle or the gun
-- bank; nil: the glasses draw it under the ship's middle
function S.weaponAt(s)
  local function rel(v)
    if type(v) ~= "table" then return nil end
    return { r = tonumber(v.r) or 0, u = tonumber(v.u) or 0, f = tonumber(v.f) or 0 }
  end
  if type(s.holo) == "table" then return rel(s.holo) end
  if s.kind == "rail" then return rel(S.cfg.radar and S.cfg.radar.gunFromNav) end
  if s.kind == "gun" then return rel(S.cfg.gun and S.cfg.gun.arrayFromNav) end
end

-- Where the hologram stands, as the glasses sent it - nil if not sensible
-- (ship: r u f from the nav table, moves with the ship; world: fixed)
function S.cleanAnchor(a)
  if type(a) ~= "table" then return nil end
  local v = a.mode == "world" and a.world or a.rel
  if type(v) ~= "table" or not (tonumber(v[1]) and tonumber(v[2]) and tonumber(v[3])) then return nil end
  local size = tonumber(a.size) or 3
  local out = { mode = a.mode == "world" and "world" or "ship", yaw = tonumber(a.yaw) or 0,
    size = math.max(0.5, math.min(16, size)) }
  out[out.mode == "world" and "world" or "rel"] = { tonumber(v[1]), tonumber(v[2]), tonumber(v[3]) }
  return out
end

function S.hudStatus()
  local every = S.cfg.hudStatus
  if not S.haveWireless or not every or now() < (S.hudStatusAt or 0) then return end
  S.hudStatusAt = now() + every
  -- (which stratagems can be called: worked out every 3 s - it asks the network)
  if not S.readyAt or now() - S.readyAt >= 3 then
    S.readyAt = now()
    local list = {}
    for _, s in ipairs(S.cfg.stratagems) do
      local ok, why = S.ready(s)
      list[#list + 1] = { n = s.name, ok = ok or nil, why = why }
    end
    S.readyList = list
  end
  local function mission(m)
    if not m then return nil end
    return { n = m.strat.name, stage = m.stage, phase = m.phase, dist = m.dist,
      left = m.stage == "FIRE" and m.fireEnd and math.max(0, m.fireEnd - now()) or nil }
  end
  local firing = {}
  for _, m in ipairs({ S.mission or false, S.side or false }) do
    if m and m.stage == "FIRE" then
      firing[#firing + 1] = { n = m.strat.name, kind = m.strat.kind, sys = m.strat.sys, at = S.weaponAt(m.strat) }
    end
  end
  local queue = {}
  for _, c in ipairs(S.queue) do queue[#queue + 1] = c.strat.name end
  local helmOk = S.helmSeen ~= nil and now() - S.helmSeen < S.cfg.helmTimeout
  local hdg
  local ax = S.helmAxes
  if type(ax) == "table" and type(ax.f) == "table" and tonumber(ax.f[1]) and tonumber(ax.f[3]) then
    local atan2 = math.atan2 or math.atan
    hdg = math.floor(math.deg(atan2(ax.f[1], ax.f[3])) % 360 + 0.5) % 360   -- (0 = south, 90 = east, as F3)
  end
  pcall(rednet.broadcast, {
    op = "shipstatus", t = os.epoch("utc"),
    helm = helmOk and (S.helmCalibrated and "online" or "uncalibrated") or "silent",
    speed = (S.helmSpeedAt and now() - S.helmSpeedAt < 3) and S.helmSpeed or nil,
    alt = S.navWorld and S.navWorld[2] or nil, hdg = hdg, moving = S.shipMoving() or nil,
    mission = mission(S.mission), side = mission(S.side), queue = queue, text = S.statusText,
    strats = S.readyList, firing = firing, lock = S.lockTrack, demo = S.cfg.demo == true or nil,
    readouts = S.readoutValues, anchor = S.cfg.statusAnchor or nil, engaged = S.engaged,
  }, S.PROTO_HUD)
end

-- The hologram's readouts (strike.cfg readouts): each a peripheral's method,
-- read every readoutEvery s in the gun coroutine (reads wait on the server)
function S.readReadouts()
  local list = type(S.cfg.readouts) == "table" and S.cfg.readouts or {}
  if #list == 0 then
    S.readoutValues = nil
    return
  end
  if now() < (S.readoutsAt or 0) then return end
  S.readoutsAt = now() + (tonumber(S.cfg.readoutEvery) or 5)
  S.readoutErr = S.readoutErr or {}
  local out = {}
  for i, r in ipairs(list) do
    local v, why
    local name = type(r) == "table" and r.peripheral
    if type(name) == "string" and not peripheral.isPresent(name) then
      -- (a peripheral type, not a name: the first one of it)
      local ok, p = pcall(peripheral.find, name)
      local okn, n = pcall(function() return p and peripheral.getName(p) end)
      name = ok and okn and n or nil
    end
    if not name then
      why = "no " .. tostring(type(r) == "table" and r.peripheral) .. " on the network"
    elseif type(r.method) ~= "string" then
      why = "no method set"
    else
      local ok, val = pcall(peripheral.call, name, r.method, table.unpack(type(r.args) == "table" and r.args or {}))
      if ok and tonumber(val) then
        local d = 10 ^ (tonumber(r.decimals) or 0)
        v = math.floor(tonumber(val) * (tonumber(r.scale) or 1) * d + 0.5) / d
      else
        why = ok and ("not a number: " .. tostring(val)) or tostring(val)
      end
    end
    -- (what went wrong, logged when it changes - not every few seconds)
    if why ~= S.readoutErr[i] then
      S.readoutErr[i] = why
      if why then S.log(("Readout %s: %s"):format(tostring(type(r) == "table" and r.label or i), why)) end
    end
    out[i] = { l = tostring(type(r) == "table" and r.label or ("READOUT " .. i)), v = v, u = type(r) == "table" and r.unit or nil }
  end
  S.readoutValues = out
end

-- Engaged guns, from the Geo Scanners on the network (gun coroutine: scans
-- wait on the server). Each gun group's blocks are counted in every scan;
-- the most ever seen (kept in strike.engaged) is the group stowed. Under
-- half of that, its cannons are assembled - a moving contraption, no longer
-- blocks - so it is engaged. -> S.engaged = { group = true | false } or nil
-- (no scanner, or none of a group's blocks ever seen)
function S.readEngagedMost()
  if not fs.exists(S.FILES.engaged) then return {} end
  local h = fs.open(S.FILES.engaged, "r")
  local t = textutils.unserialize(h.readAll())
  h.close()
  return type(t) == "table" and t or {}
end

function S.writeEngagedMost()
  pcall(function()
    local h = fs.open(S.FILES.engaged, "w")
    h.write(textutils.serialize(S.engagedMost))
    h.close()
  end)
end

function S.scanEngaged()
  local every = S.cfg.engagedScan
  if not every or now() < (S.engagedAt or 0) then return end
  S.engagedAt = now() + every
  local scanners = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType(n, "geoScanner") or peripheral.hasType(n, "geo_scanner") then scanners[#scanners + 1] = n end
  end
  if #scanners == 0 then
    S.engaged, S.engagedCount = nil, nil
    return
  end
  local blocks = type(S.cfg.engagedBlocks) == "table" and S.cfg.engagedBlocks or {}
  local count = {}
  for sys in pairs(blocks) do count[sys] = 0 end
  for _, n in ipairs(scanners) do
    -- (Advanced Peripherals 0.8.2a calls it scanBlocks - older ones scan)
    local r = tonumber(S.cfg.engagedRadius) or 8
    local ok, list, err = pcall(peripheral.call, n, "scanBlocks", r)
    if not ok and tostring(list):find("No such method", 1, true) then ok, list, err = pcall(peripheral.call, n, "scan", r) end
    if not ok or type(list) ~= "table" then
      -- (a round with a scan missing proves nothing: the last word stands; the trouble logged once)
      local why = tostring(ok and err or list)
      if why ~= S.engagedErr then
        S.engagedErr = why
        S.log(("Geo Scanner %s: %s"):format(n, why))
      end
      return
    end
    for _, b in ipairs(list) do
      -- (on a ship it also scans the world round it, marked notOnShip: left out)
      local name = type(b) == "table" and not b.notOnShip and tostring(b.name or "") or ""
      for sys, part in pairs(blocks) do
        if name:find(tostring(part), 1, true) then count[sys] = count[sys] + 1 end
      end
    end
  end
  S.engagedErr = nil
  S.engagedMost = S.engagedMost or S.readEngagedMost()
  local grew, out = false, {}
  for sys, c in pairs(count) do
    if c > (tonumber(S.engagedMost[sys]) or 0) then S.engagedMost[sys], grew = c, true end
    local most = tonumber(S.engagedMost[sys]) or 0
    if most >= 2 then out[sys] = c <= most / 2 end
  end
  if grew then S.writeEngagedMost() end
  -- (a change logged: the guns going out or being stowed)
  for sys, on in pairs(out) do
    if S.engaged and S.engaged[sys] ~= nil and S.engaged[sys] ~= on then
      S.log(("Guns %s: %s"):format(sys, on and "ENGAGED (gone from the scan)" or "stowed"))
    end
  end
  S.engaged, S.engagedCount = next(out) and out or nil, count
end

-- Is the ship still (helm's speed under 0.2 b/s, heard lately)?
function S.shipStill()
  return S.helmSpeedAt ~= nil and now() - S.helmSpeedAt < 3 and (S.helmSpeed or 99) < 0.2
end

function S.gunLoop()
  while true do
    -- (not sleep(): a terminate must reach the main loop's clean shutdown)
    local t = os.startTimer(0.2)
    repeat
      local e, id = os.pullEventRaw()
    until e == "timer" and id == t
    local ok, err = pcall(S.gunService)
    if not ok then
      S.log("gunner error: " .. tostring(err))
      pcall(function() S.gunner:stopAll() end)
    end
    local ok3, err3 = pcall(S.coordService)
    if not ok3 then S.log("coordinate call error: " .. tostring(err3)) end
    local ok2, err2 = pcall(S.railService)
    if not ok2 then
      S.log("railcannon error: " .. tostring(err2))
      if S.mission and S.mission.rail then S.finish(false, "railcannon error: " .. tostring(err2), S.mission, "malfunction") end
    end
    local ok4, err4 = pcall(S.hudRadar)
    if not ok4 then S.log("HUD radar error: " .. tostring(err4)) end
    local ok5, err5 = pcall(S.hudPose)
    if not ok5 then S.log("HUD pose error: " .. tostring(err5)) end
    local ok6, err6 = pcall(S.readReadouts)
    if not ok6 then S.log("readouts error: " .. tostring(err6)) end
    local ok7, err7 = pcall(S.scanEngaged)
    if not ok7 then S.log("engaged scan error: " .. tostring(err7)) end
  end
end

---------------------------------------------------------------- railcannon (radar)
-- Create Radar can only be READ from a computer (no command selects a
-- target), so strike picks the target and puts the ship right over it.
-- Peripheral types as CC reports them:
S.RADAR_TYPES = { radar = "create_radar:radar", monitor = "create_radar:monitor",
  anchor = "create_radar:plane_radar" }

-- What each kind offers. Another mod may wrap the block in its own
-- peripheral (Create Avionics turns a radar bearing into "radar_bearing_N"
-- and merges Create Radar's methods in), so the type name is not enough:
-- match by the methods too
S.RADAR_METHODS = { radar = { "getTracks", "getDishCount" }, monitor = { "getSelectedTrack" },
  anchor = { "getTracks", "getPosition" } }
local function hasMethods(n, list)
  local ok, ms = pcall(peripheral.getMethods, n)
  if not ok or type(ms) ~= "table" then return false end
  local set = {}
  for _, m in ipairs(ms) do set[m] = true end
  for _, m in ipairs(list) do if not set[m] then return false end end
  return true
end

-- The peripheral name for radar / monitor / anchor (nil = none on the network)
function S.radarName(kind)
  local want = S.cfg.radar and S.cfg.radar[kind]
  if want and want ~= "auto" then return peripheral.isPresent(want) and want or nil end
  local names = peripheral.getNames()
  for _, n in ipairs(names) do
    if peripheral.hasType(n, S.RADAR_TYPES[kind]) then return n end
  end
  for _, n in ipairs(names) do
    if hasMethods(n, S.RADAR_METHODS[kind]) then return n end
  end
end

function S.radarReady()
  local R = S.cfg.radar
  if type(R) ~= "table" then return false, "no radar settings in strike.cfg" end
  if type(R.anchorFromNav) ~= "table" then
    return false, "set radar.anchorFromNav in strike.cfg (where the plane radar is on the ship)"
  end
  if not S.radarName("radar") then return false, "no radar on the network (radar bearing + wired modem)" end
  if not S.radarName("anchor") then return false, "no plane radar on the network (needed for the ship's position)" end
  return true
end

-- One look at the radar: anchor = the plane radar's world position (block
-- centre), selected = a track a player picked on the monitor, tracks = all
function S.radarRead()
  local out = { tracks = {} }
  local ok, p = pcall(peripheral.call, S.radarName("anchor"), "getPosition")
  out.anchor = ok and v3of(p) or nil
  local mon = S.radarName("monitor")
  if mon then
    -- (the monitor reports the radar network's target - a player's pick
    -- or its auto-targeting - but gives its position only when that track
    -- is in the monitor's own list: else look the id up in the radar's)
    local ok1, id = pcall(peripheral.call, mon, "getSelectedTrackId")
    if ok1 and type(id) == "string" and id ~= "" then
      out.selectedId = id
      local ok2, t = pcall(peripheral.call, mon, "getSelectedTrack")
      if ok2 and type(t) == "table" and v3of(t.position) then out.selected = t end
    end
  end
  local ok3, tr = pcall(peripheral.call, S.radarName("radar"), "getTracks")
  if ok3 and type(tr) == "table" then out.tracks = tr end
  if out.selectedId and not out.selected then
    for _, t in ipairs(out.tracks) do
      if t.id == out.selectedId and v3of(t.position) then out.selected = t break end
    end
  end
  S.findOwnShip()
  return out
end

-- this ship's own sub-level id (Create Avionics physics assembler), once
-- (false: none on the network - this ship's radar track is not known)
function S.findOwnShip()
  if S.ownShipId ~= nil then return end
  local pa
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType(n, "physics_assembler") then pa = n break end
  end
  local ok4, sid = false, nil
  if pa then ok4, sid = pcall(peripheral.call, pa, "getSubLevelId") end
  S.ownShipId = (ok4 and type(sid) == "string") and sid or false
end

-- "radar" typed at the strike computer: what is connected and what it sees
function S.radarStatus(withPlayers)
  local names = {}
  for _, k in ipairs({ "radar", "anchor", "monitor" }) do
    names[#names + 1] = ("%s %s"):format(k == "anchor" and "plane radar" or k, S.radarName(k) or "MISSING")
  end
  if not S.radarName("radar") then
    -- say what the radar-like peripherals do offer
    for _, n in ipairs(peripheral.getNames()) do
      if n:lower():find("radar") and n ~= S.radarName("anchor") then
        local ok, ms = pcall(peripheral.getMethods, n)
        names[#names + 1] = ("%s [%s: %s]"):format(n, tostring(peripheral.getType(n)),
          ok and type(ms) == "table" and table.concat(ms, " ") or "?")
      end
    end
  end
  if not S.radarName("radar") then return "radar: " .. table.concat(names, ", ") end
  local sens = S.radarRead()
  local count = {}
  for _, t in ipairs(sens.tracks) do
    local c = tostring(t.category or "?"):lower()
    count[c] = (count[c] or 0) + 1
  end
  local seen = {}
  for c, n in pairs(count) do seen[#seen + 1] = n .. " " .. c end
  table.sort(seen)
  if withPlayers then
    -- where each player is (world), for checking from the ground
    for _, t in ipairs(sens.tracks) do
      local p = v3of(t.position)
      local c = tostring(t.category):upper()
      if p and (c == "PLAYER" or c == "SABLE") then
        seen[#seen + 1] = ("%s %s at %.0f %.0f %.0f"):format(c == "SABLE" and "ship" or "player",
          tostring(t.id):sub(1, 8), p[1], p[2], p[3])
      end
    end
  end
  local where = "no position"
  if sens.anchor and S.helmAxes and type(S.cfg.radar.anchorFromNav) == "table" then
    local nav = v3sub(sens.anchor, shipToWorld(S.cfg.radar.anchorFromNav, S.helmAxes))
    where = ("nav table at %.0f %.0f %.0f"):format(nav[1], nav[2], nav[3])
  elseif sens.anchor then
    where = ("plane radar at %.0f %.0f %.0f"):format(sens.anchor[1], sens.anchor[2], sens.anchor[3])
  end
  return ("radar: %s; %s; sees %s%s; own ship %s"):format(table.concat(names, ", "), where,
    #seen > 0 and table.concat(seen, ", ") or "nothing",
    sens.selected and (", selected " .. tostring(sens.selected.id):sub(1, 8) .. " " .. tostring(sens.selected.entityType or ""))
      or sens.selectedId and (", selected " .. sens.selectedId:sub(1, 8) .. " (not on the radar)") or "",
    S.ownShipId and "known" or "unknown (no physics assembler)")
end

-- Railcannon targets on the radar: ships (Sable sub-levels) other than this
-- ship and anything within shipRadius of the nav table (the lock dummy's
-- platform); with targets = "all" also players not near the caller. Never
-- debris
function S.railCandidates(sens, navW, callerW, s)
  local R, list = S.cfg.radar, {}
  for _, t in ipairs(sens.tracks) do
    local p, cat = v3of(t.position), tostring(t.category or ""):upper()
    if p and not S.isDebris(t.id) then
      local ok = false
      if cat == "SABLE" then
        local e = v3sub(p, navW)
        ok = not (S.ownShipId and t.id == S.ownShipId)
          and math.sqrt(e[1] * e[1] + e[2] * e[2] + e[3] * e[3]) > (R.shipRadius or 60)
      elseif cat == "PLAYER" and s.targets == "all" then
        local e = v3sub(p, callerW)
        ok = math.sqrt(e[1] * e[1] + e[2] * e[2] + e[3] * e[3]) > (R.selfRadius or 8)
      end
      if ok then list[#list + 1] = { id = t.id, w = p, what = cat == "SABLE" and "ship" or "player" } end
    end
  end
  return list
end

local function hdist(a, b)
  local dx, dz = a[1] - b[1], a[3] - b[3]
  return math.sqrt(dx * dx + dz * dz)
end
local function dist3(a, b)
  local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- How far sideways the radar sees: radar.range blocks, or "auto" = 20 + 10
-- per dish, at most radar.maxRange
function S.radarRange()
  local R = S.cfg.radar
  if type(R.range) == "number" then return R.range end
  local ok, n = pcall(peripheral.call, S.radarName("radar"), "getDishCount")
  n = ok and tonumber(n) or 0
  return math.min(20 + 10 * n, R.maxRange or 1000)
end

-- Fire the railcannon: like a carpet - one pulse of `output` (the barrage
-- cannons' firing link), the stratagem completes, and flushAfter s later a
-- background flush pulse unless a new stratagem is called. (With fireEvery:
-- pulse every fireEvery s for fireTime instead.)
function S.railFire(m)
  local s = m.strat
  if s.fireEvery then return S.startFire() end
  m.stage = "FIRE"
  if s.dryRun then
    S.log("Volley (dry run - no output)")
  else
    S.pulse(s.output)
    S.log("Volley fired")
  end
  S.voice(m, "fire")
  if s.flushAfter then S.queueFlush(s, s.flushAfter) end
  S.finish(true, s.name .. " fired")
end

-- Leftover railcannon shells (called off after loading): warn the caller,
-- fire one pulse of the firing link RAIL_FLUSH_WARN s later - whatever else
-- happens meanwhile
S.RAIL_FLUSH_WARN = 10
function S.railLeftovers(m)
  local s, pocket = m.strat, m.pocket
  local secs = S.RAIL_FLUSH_WARN
  S.log(("Leftover railcannon shells: firing them in %d s"):format(secs))
  S.toPocket(pocket, { op = "status", id = m.id, name = s.name,
    text = ("WARNING: leftover railcannon shells fire in %d s - get clear"):format(secs) })
  S.after(secs, function()
    S.pulse(s.output)
    S.log("Leftover railcannon shells fired")
    S.toPocket(pocket, { op = "status", id = m.id, name = s.name, text = "Leftover railcannon shells fired" })
  end)
end

-- Every 0.2 s in the gun coroutine (radar reads wait on the server). The
-- railcannon, step by step (m.rail.phase):
--   PICK   once: the ship nearest the caller within pickRadius (10) - kept
--          for the whole stratagem. Caller out of radar range: RANGE.
--          Nothing there: called off before any loading.
--   RANGE  flying until the caller is in radar range, then done ("call it
--          again")
--   PLACE  (loading) move if the target is over guidedRange across from the
--          guns, or another ship is nearer this ship than the target (the
--          lock dummy locks the nearest)
--   RESET  the radar stopped resetTime s (clutch, radar.resetLink): the
--          network drops its old lock and the dummy takes the nearest
--   LOCK   fire once loaded and the network's lock is the target (the guided
--          shells follow only that); not within lockWait s: called off
function S.railService()
  if S.radarQuery then
    S.radarQuery = false
    S.reply = S.radarStatus()
    S.log("> radar  ->  " .. S.reply)
    S.draw()
  end
  if S.radarWatch and now() >= (S.radarWatchNext or 0) then
    if now() > S.radarWatch then
      S.radarWatch = nil
      S.log("radar watch: done")
    else
      S.radarWatchNext = now() + 5
      S.log("radar watch: " .. S.radarStatus(true))
    end
  end
  local m = S.mission
  if not (m and m.rail and m.stage == "SCAN") then return end
  local rl, R, s = m.rail, S.cfg.radar, m.strat
  if rl.phase == "RESET" then return end              -- (the clutch timer moves it on)
  if now() < (rl.nextLook or 0) then return end
  rl.nextLook = now() + 0.5
  local axes = S.helmAxes
  if not axes then return S.finish(false, "no ship orientation from helm", m, "malfunction") end
  local sens = S.radarRead()
  if not sens.anchor then return S.finish(false, "cannot read the plane radar's position", m, "malfunction") end
  local navW = v3sub(sens.anchor, shipToWorld(R.anchorFromNav, axes))
  -- the caller's spot in the world, from where the ship was at the call
  if not rl.callerW then rl.callerW = v3add(navW, shipToWorld(rl.rel, axes)) end
  local callerW, o = rl.callerW, s.offset
  -- the radar lock is the target when the radar sees it: one picked by hand
  -- (L on the map, "lock" typed) wherever it is - precise; the auto-lock's
  -- only when it is by the beacon (else the beacon picks, as ever)
  local lockT
  if rl.phase == "PICK" and S.lockTrack and not S.isFriendlyTarget(S.lockTrack) and not S.isDebris(S.lockTrack) then
    for _, t in ipairs(sens.tracks) do
      local p = v3of(t.position)
      if p and tostring(t.id) == S.lockTrack and (S.lockManual or hdist(p, callerW) <= (s.pickRadius or 15)) then
        lockT = { id = t.id, w = p, what = tostring(t.category or ""):upper() == "PLAYER" and "player" or "ship" }
      end
    end
  end
  if lockT then
    rl.target, rl.eligible, rl.byLock = lockT, { [lockT.id] = true }, true
    S.log(("Pick: the radar lock, %s %s at %.1f %.1f %.1f"):format(lockT.what, tostring(lockT.id):sub(1, 8),
      lockT.w[1], lockT.w[2], lockT.w[3]))
    S.voice(m, "aim")                                   -- "target acquired"
    m.readyAt = now() + (s.loadTime or 0)
    if s.load then
      m.loads = 1
      if s.dryRun then
        S.log("Loading (dry run - no output)")
      else
        S.pulse(s.load)
        S.log(("Ammo dispensing - ready in %g s"):format(s.loadTime or 0))
      end
    end
    rl.phase = "PLACE"
  end
  if rl.phase == "PICK" then
    local range = S.radarRange()
    local h = hdist(callerW, sens.anchor)
    if h > range * 0.9 then
      -- the radar cannot see there: get in range, the caller calls again
      local k = 1 - range * 0.75 / h
      local st = { navW[1] + (callerW[1] - navW[1]) * k, callerW[2] + o.u, navW[3] + (callerW[3] - navW[3]) * k }
      rl.phase = "RANGE"
      S.log(("Caller %.0f blocks from the radar, range %.0f: moving into range"):format(h, range))
      S.sayFor(m, "repositioning")
      return S.railGoto(m, st, navW, axes, s.flyAccuracy or 8, ("OUT OF RADAR RANGE - moving %.0f blocks closer"):format(h - range * 0.75))
    end
    -- every target within pickRadius now is kept as fair game for the
    -- whole stratagem (whichever the network locks); the nearest is the pick
    local best, bestD, names = nil, nil, {}
    rl.eligible = {}
    for _, t in ipairs(S.railCandidates(sens, navW, callerW, s)) do
      local d = hdist(t.w, callerW)
      if d <= (s.pickRadius or 15) and not S.isFriendlyTarget(t.id) then
        rl.eligible[t.id] = true
        names[#names + 1] = ("%s %s (%.1f)"):format(t.what, tostring(t.id):sub(1, 8), d)
        if not bestD or d < bestD then best, bestD = t, d end
      end
    end
    if not best then
      return S.finish(false, ("no target within %g blocks of you - nothing loaded"):format(s.pickRadius or 15), m, "no_solution")
    end
    rl.target = best
    S.log(("Targets within %g blocks of you: %s"):format(s.pickRadius or 15, table.concat(names, ", ")))
    S.log(("Pick: %s %s at %.1f %.1f %.1f, %.1f blocks from you"):format(best.what, tostring(best.id):sub(1, 8),
      best.w[1], best.w[2], best.w[3], bestD))
    S.voice(m, "aim")                                   -- "target acquired"
    -- loading only now there is a target
    m.readyAt = now() + (s.loadTime or 0)
    if s.load then
      m.loads = 1
      if s.dryRun then
        S.log("Loading (dry run - no output)")
      else
        S.pulse(s.load)
        S.log(("Ammo dispensing - ready in %g s"):format(s.loadTime or 0))
      end
    end
    rl.phase = "PLACE"
  end
  -- the target's latest position (by id; a moving ship is followed)
  local tgt = rl.target
  for _, t in ipairs(sens.tracks) do
    if t.id == tgt.id and v3of(t.position) then tgt.w = v3of(t.position) break end
  end
  if rl.phase == "PLACE" then
    local gf = R.gunFromNav or {}
    local gunOff = shipToWorld({ r = gf.r or 0, f = gf.f or 0 }, axes)
    local across = hdist(tgt.w, v3add(navW, gunOff))
    local nearest, nd
    for _, t in ipairs(S.railCandidates(sens, navW, callerW, s)) do
      if t.what == "ship" then
        local d = dist3(t.w, navW)
        if not nd or d < nd then nearest, nd = t, d end
      end
    end
    local why
    if across > (s.guidedRange or 200) then
      why = "range"
    elseif nearest and not rl.eligible[nearest.id] and not rl.overDone then
      why = "nearest"
    end
    if why and (rl.moves or 0) < 3 then
      rl.moves = (rl.moves or 0) + 1
      local st
      if why == "range" then
        -- the nav table `approach` blocks across from it, on this side
        local hx, hz = navW[1] - tgt.w[1], navW[3] - tgt.w[3]
        local hl = math.sqrt(hx * hx + hz * hz)
        if hl < 1e-6 then hx, hz, hl = 1, 0, 1 end
        local a = s.approach or 150
        st = { tgt.w[1] + hx / hl * a, tgt.w[2] + o.u, tgt.w[3] + hz / hl * a }
      else
        -- another ship is nearer this one: the guns right over the target
        rl.overDone = true
        st = { tgt.w[1] - gunOff[1], tgt.w[2] + o.u, tgt.w[3] - gunOff[3] }
      end
      S.log(("Target %.0f blocks across from the guns%s: moving %s"):format(across,
        why == "nearest" and (", ship %s is nearer to us"):format(tostring(nearest.id):sub(1, 8)) or "",
        why == "range" and "into guided range" or "over it"))
      if rl.moves > 1 then S.sayFor(m, "repositioning") end
      return S.railGoto(m, st, navW, axes, why == "range" and (s.flyAccuracy or 8) or 2,
        ("MOVING - target %.0f blocks across"):format(across))
    end
    S.log("Monitor lock before the reset: " .. S.lockText(sens, tgt))
    rl.lastSel = sens.selectedId or ""
    return S.railReset(m)
  end
  -- LOCK: the network's lock as the monitor reports it - logged as it changes
  local loaded = now() >= (m.readyAt or 0)
  if (sens.selectedId or "") ~= rl.lastSel then
    rl.lastSel = sens.selectedId or ""
    S.log("Monitor lock now: " .. S.lockText(sens, tgt))
  end
  -- on a target: one of the ships within pickRadius at the call, or (in case
  -- its id reads differently) a target that is within pickRadius of the call
  -- spot now. Whichever it is becomes the target and is kept
  local onTarget = sens.selectedId ~= nil and rl.eligible[sens.selectedId] == true
  -- (firing at the radar lock: only that very contact will do)
  if not onTarget and sens.selected and not rl.byLock then
    for _, t in ipairs(S.railCandidates({ tracks = { sens.selected } }, navW, callerW, s)) do
      if hdist(t.w, callerW) <= (s.pickRadius or 15) then
        onTarget = true
        rl.eligible[t.id] = true
      end
    end
  end
  if onTarget and sens.selectedId ~= tgt.id then
    local selW = sens.selected and v3of(sens.selected.position)
    tgt = { id = sens.selectedId, w = selW or tgt.w,
      what = tostring(sens.selected and sens.selected.category or ""):upper() == "PLAYER" and "player" or "ship" }
    rl.target = tgt
    S.log(("Radar network locked %s %s (not the pick, but within %g blocks of the call) - now the target"):format(
      tgt.what, tostring(tgt.id):sub(1, 8), s.pickRadius or 15))
  end
  if onTarget then
    if not rl.lockLogged then
      rl.lockLogged = true
      S.log("Radar network locked on the target - the guided fuzes follow it")
    end
    if loaded then
      S.log(("Firing guided on %s %s at %.1f %.1f %.1f"):format(tgt.what, tostring(tgt.id):sub(1, 8),
        tgt.w[1], tgt.w[2], tgt.w[3]))
      return S.railFire(m)
    end
  elseif now() - rl.lockSince > (s.lockWait or 20) then
    return S.finish(false, sens.selectedId
      and ("the radar network is locked on something else (%s) - not firing"):format(sens.selectedId:sub(1, 8))
      or "the radar network did not lock on the target - not firing (is the radar monitor on the same filterer?)",
      m, "no_solution")
  end
  if now() >= (rl.msgAt or 0) then
    rl.msgAt = now() + 1
    S.report(loaded and "WAITING FOR LOCK" or ("LOADING %ds"):format(math.ceil(m.readyAt - now())), { phase = "AIM" })
  end
end

-- What the monitor says the network is locked on, for the log
function S.lockText(sens, tgt)
  if not sens.selectedId or sens.selectedId == "" then return "nothing selected" end
  local w = sens.selected and v3of(sens.selected.position)
  return ("%s%s, %s (the pick is %s)"):format(sens.selectedId:sub(1, 8),
    sens.selected and (" " .. tostring(sens.selected.category or "") .. " " .. tostring(sens.selected.entityType or "")) or "",
    w and ("at %.1f %.1f %.1f, %.1f blocks from the pick"):format(w[1], w[2], w[3], dist3(w, tgt.w)) or "not on the radar",
    tostring(tgt.id):sub(1, 8))
end

-- Fly so the nav table ends at world point st (radar frame)
function S.railGoto(m, st, navW, axes, tol, text)
  local d = worldToShip(v3sub(st, navW), axes)
  m.stage, m.heard, m.disp = "FLY", now(), { r = d.r, u = d.u, f = d.f }
  S.toHelm({ op = "release", id = m.id })
  S.toHelm({ op = "goto", id = m.id, disp = m.disp, tol = tol })
  S.report(text, { phase = "FLY" })
end

-- Stop the radar a moment (a clutch on its drive, radar.resetLink) so the
-- network drops its old lock; the lock dummy then takes the nearest ship
function S.railReset(m)
  local R, rl = S.cfg.radar, m.rail
  rl.phase = "RESET"
  local function done()
    if S.mission ~= m then return end
    rl.phase, rl.lockSince = "LOCK", now()
    S.report("WAITING FOR LOCK", { phase = "AIM" })
  end
  if type(R.resetLink) ~= "table" or m.strat.dryRun then
    S.log("No radar reset (resetLink not set or dry run) - waiting for the lock as it is")
    return done()
  end
  setOut(R.resetLink, true)
  S.log(("Radar stopped for %g s (lock reset)"):format(R.resetTime or 2))
  S.report("RESETTING LOCK", { phase = "AIM" })
  S.after(R.resetTime or 2, function()
    setOut(R.resetLink, false)                         -- (always: never leave the radar stopped)
    done()
  end)
end

-- The gun relay's latest report (gunrelay.lua): fresh within a second
S.PROTO_RELAY = "destroyer.gunrelay"
function S.fromRelay(msg)
  if type(msg.yaw) == "number" and type(msg.pitch) == "number" then
    S.relay = { yaw = msg.yaw, pitch = msg.pitch, facing = msg.facing, at = now() }
  end
end
function S.relayRead()
  local r = S.relay
  if r and now() - r.at < 1 then return r.yaw, r.pitch end
  return nil
end
function S.relayFacing()
  return S.relay and S.relay.facing
end

-- "gunner ..." commands (run in the gun coroutine)
function S.gunCommand(words)
  local gn = S.gunner
  local sub = (words[2] or "status"):lower()
  if sub == "status" then
    local y, p = gn:read()
    local dud, yc, pc, ctls = gn:names()
    local mounts = gn.io.find(G.TYPE_MOUNT)
    local src = S.cfg.gun.relay and ("relay " .. tostring(S.cfg.gun.relay) .. (S.relay and "" or " (silent)")) or tostring(dud)
    return ("gunner: %s; reading %s %s; mounts on network: %s; controllers %d%s"):format(
      G.calReady(gn.cal) and "calibrated" or "NOT calibrated",
      src, y and ("yaw %.1f pitch %.1f"):format(y, p) or "(no reading)",
      #mounts > 0 and table.concat(mounts, ", ") or "none", #(ctls or {}),
      gn.msg and (" - " .. gn.msg) or "")
  elseif sub == "cal" then
    if S.mission or S.side then return "not during a mission" end
    gn.msg = nil
    return "gunner: " .. gn:startCal()
  elseif sub == "down" or sub == "up" or sub == "vertical" or sub == "level" or G.LEAN[sub] then
    return "gunner: " .. gn:answer(sub)
  elseif sub == "stop" then
    gn:stopAll()
    return "gunner: shafts stopped"
  elseif sub == "point" then
    -- gunner point <bearing> <elevation>: ship frame, bearing 0 = bow, 90 = right
    local b, e = tonumber(words[3]), tonumber(words[4])
    if not b or not e then return "gunner point <bearing 0=bow 90=right> <elevation, -90=down>" end
    if not S.helmAxes then return "no ship orientation from helm yet" end
    local ax = S.helmAxes
    local cb, sb, ce, se = math.cos(math.rad(b)), math.sin(math.rad(b)), math.cos(math.rad(e)), math.sin(math.rad(e))
    local dir = G.shipToWorld({ r = sb * ce, u = se, f = cb * ce }, ax)
    local ok, why = gn:point(dir, ax)
    return ok and ("gunner: pointing %g / %g"):format(b, e) or ("gunner: " .. tostring(why))
  end
  return "gunner status | cal | vertical/level | bow/stern/left/right | down/up | point <bearing> <elev> | stop"
end

-- End mission m (default: the ship's). ok=false: aborted (the weapon is
-- switched off first); line = the PA line that says why. The next waiting
-- call starts half a second later.
function S.finish(ok, text, m, line)
  m = m or S.mission
  if not m then return end
  if m.latchOn and m.strat.output then
    S.pulse(m.strat.output)                 -- weapon OFF
    m.latchOn = false
    S.log("Weapon OFF (" .. (ok and "done" or "abort") .. ")")
  end
  if m.rapid then
    setOut(m.rapid.out, false)
    S.log(("Stopped firing after %d pulses (%s)"):format(m.rapid.n, ok and "done" or "abort"))
    m.rapid = nil
  end
  if m.loads and not ok and not m.strat.dryRun then
    S.log(("Note: %d ammo load(s) were dispensed for this call"):format(m.loads))
    -- railcannon called off with its guided shells loaded: they would go out
    -- with the next carpet/barrage volley, steering at whatever the radar
    -- network is locked on. Warn the caller, then fire them 10 s later.
    if m.rail and m.strat.output then S.railLeftovers(m) end
  end
  if m.gun then S.gunStop = true end          -- shafts to 0 (gun coroutine)
  if m.stage ~= "END" and not m.side then
    S.toHelm({ op = ok and "release" or "abort", id = m.id })
  end
  m.stage = "END"
  S.log((ok and "Complete: " or "Aborted: ") .. m.strat.name .. " - " .. text)
  S.report((ok and "COMPLETE: " or "ABORTED: ") .. text, { done = true, ok = ok }, m)
  if ok then S.voice(m, "done") elseif line then S.sayFor(m, line) end
  if S.mission == m then S.mission = nil end
  if S.side == m then S.side = nil end
  S.after(0.5, S.advance)
end

function S.startFire()
  local m = S.mission
  m.stage = "FIRE"
  if m.strat.kind == "carpet" then return S.startVolleys(m) end
  if m.strat.kind == "barrage" then return S.startBarrage(m) end
  m.fireEnd = now() + m.strat.fireTime
  if m.strat.dryRun then
    S.log("On station (dry run - no output)")
  elseif m.strat.fireEvery then
    S.rapidFire(m, m.strat.output, m.strat.fireEvery)
    S.log(("Firing every %g s for %g s"):format(m.strat.fireEvery, m.strat.fireTime))
  else
    S.pulse(m.strat.output)                 -- weapon ON
    m.latchOn = true
    S.log("Weapon ON for " .. m.strat.fireTime .. " s")
  end
  S.voice(m, "fire")
  S.report(m.strat.dryRun and "ON STATION (dry run)" or "FIRING", { phase = "FIRE", remaining = m.strat.fireTime })
end

-- The ammo link for load number i: one link, or a list taken in turn
-- (Hybrid Barrage: gas, napalm, gas, napalm)
function S.loadOut(s, i)
  if type(s.load) == "table" and s.load[1] then return s.load[(i - 1) % #s.load + 1] end
  return s.load
end

-- Loaded barrage: every load is called from the start - `loads` of them,
-- loadEvery s apart (spaced so the dispenser does not clog), whether the
-- ship is still flying or not. Calling it off stops the rest.
function S.reload(m)
  if S.mission ~= m then return end
  local s = m.strat
  if m.loads >= s.loads then return end
  m.loads = m.loads + 1
  local out = S.loadOut(s, m.loads)
  if not s.dryRun then S.pulse(out) end
  S.log(("Ammo load %d/%d (%s)%s"):format(m.loads, s.loads, out and out.side or "-", s.dryRun and " (dry run)" or ""))
  S.after(s.loadEvery, function() S.reload(m) end)
end

function S.startBarrage(m)
  local s = m.strat
  local first = math.max(now(), m.readyAt or now())
  m.mainEnd = first + s.fireTime
  m.fireEnd = m.mainEnd + (s.flush or 0)
  local function go()
    if S.mission ~= m then return end
    if s.dryRun then
      S.log("Barrage would fire now (dry run - no output)")
    else
      S.rapidFire(m, s.output, s.fireEvery)
      S.log(("Firing every %g s for %g s + %g s flush"):format(s.fireEvery, s.fireTime, s.flush or 0))
    end
    S.voice(m, "fire")
    S.report("FIRING", { phase = "FIRE", remaining = m.fireEnd - now() })
  end
  local wait = first - now()
  if wait > 0.05 then
    S.log(("On station - loading, firing in %.0f s"):format(wait))
    S.report(("LOADING %ds"):format(math.ceil(wait)), { phase = "FIRE", remaining = m.fireEnd - now() })
    S.after(wait, go)
  else
    go()
  end
end

-- Carpet: one output pulse per volley, the first once the ammo is loaded
-- (loadTime after the call) and the ship is here, then after each gap
-- A background flush: one pulse of the stratagem's output `secs` from now,
-- after its mission has completed. A new call cancels it (S.call).
function S.queueFlush(strat, secs)
  local job = { out = strat.output, dry = strat.dryRun, name = strat.name }
  S.flushJob = job
  S.after(secs, function()
    if S.flushJob ~= job then return end
    S.flushJob = nil
    if job.dry then
      S.log("Flush (dry run - no output)")
    else
      S.pulse(job.out)
      S.log("Flush fired (" .. job.name .. ")")
    end
  end)
end

function S.startVolleys(m)
  local times = { math.max(now(), m.readyAt or now()) }
  for _, gap in ipairs(m.strat.volleyGaps) do times[#times + 1] = times[#times] + gap end
  m.volleyTimes, m.volleysFired = times, 0
  m.fireEnd = times[#times] + 1
  for i, t in ipairs(times) do
    S.after(math.max(0, t - now()), function()
      if S.mission ~= m then return end
      m.volleysFired = i
      if m.strat.dryRun then
        S.log(("Volley %d/%d (dry run - no output)"):format(i, #times))
      else
        S.pulse(m.strat.output)
        S.log(("Volley %d/%d fired"):format(i, #times))
      end
      S.voice(m, "fire")
      S.report(("VOLLEY %d/%d"):format(i, #times), { phase = "FIRE" })
      if i == #times then
        -- done: the stratagem completes now; the flush shot (leftover ammo)
        -- goes flushAfter s later in the background, unless a new
        -- stratagem is called first
        if m.strat.flushAfter then S.queueFlush(m.strat, m.strat.flushAfter) end
        S.finish(true, m.strat.name .. " fired")
      end
    end)
  end
  local wait = times[1] - now()
  S.log(wait > 0.05 and ("On station - loading, first volley in %.0f s"):format(wait) or "On station - firing")
  S.report(wait > 0.05 and ("LOADING %ds"):format(math.ceil(wait)) or "FIRING", { phase = "FIRE", remaining = m.fireEnd - now() })
end

-- Is the ship under way? Cruising or braking to a stratagem, or flown faster
-- than 3 b/s by hand - and until it is under 1 b/s again for a second (no
-- flicker). The war table hides meanwhile (it cannot keep up with the ship)
function S.shipMoving()
  local m = S.mission
  local phase = m and m.stage == "FLY" and m.phase
  local speed = (S.helmSpeedAt and now() - S.helmSpeedAt < 3) and S.helmSpeed or 0
  local under = phase == "CRUISE" or phase == "BRAKE" or speed > 3
  if under then
    S.movingUntil = now() + 1
  elseif speed > 1 and S.movingUntil then
    S.movingUntil = now() + 1
  end
  return S.movingUntil ~= nil and now() < S.movingUntil
end

function S.fromHelm(msg)
  S.helmSeen = now()
  if type(msg.axes) == "table" then S.helmAxes = msg.axes end
  if tonumber(msg.speed) then S.helmSpeed, S.helmSpeedAt = tonumber(msg.speed), now() end
  -- the nav table's position in helm's world frame (keeps queued calls' spots)
  if type(msg.nav) == "table" and type(msg.nav[1]) == "number" then S.helmNav = msg.nav end
  if S.side and (msg.op == "pong" or msg.op == "state") then S.sideTrack(msg) end
  if msg.op == "pong" then
    S.helmCalibrated = msg.calibrated
    return
  end
  local m = S.mission
  if not m or (msg.id and msg.id ~= m.id) then return end
  m.heard = now()
  if msg.op == "accepted" then
    S.report("helm accepted", { phase = "ACCEPTED", dist = msg.dist })
  elseif msg.op == "refused" and tostring(msg.reason):find("busy", 1, true) and m.gotoMsg and not m.busyRetried then
    -- helm still holding a trip strike has forgotten (strike restarted, or
    -- a release went missing): only strike sends helm trips, so let it go
    -- and ask again - the call carries on instead of being called off
    m.busyRetried = true
    S.log("Helm still busy with an old trip - releasing it and asking again")
    S.toHelm({ op = "release" })
    S.report("WAITING FOR HELM", { phase = "ACCEPTED" }, m)
    S.after(1, function()
      if S.mission == m and m.stage == "FLY" then S.toHelm(m.gotoMsg) end
    end)
  elseif msg.op == "refused" then
    m.stage = "END"
    S.finish(false, "helm refused: " .. tostring(msg.reason), m, "unable_to_reach")
  elseif msg.op == "aborted" then
    m.stage = "END"
    local reason = tostring(msg.reason)
    if reason:find("lost contact", 1, true) then
      S.finish(false, "helm: " .. reason, m, "unable_to_reach")
    else
      -- the pilot took over at helm (a key, hold, park, cal, stop): the
      -- waiting calls go too. (Helm itself says "manual control engaged".)
      S.dropQueue("helm: " .. reason)
      if S.side then S.finish(false, "helm: " .. reason, S.side) end
      S.finish(false, "helm: " .. reason, m, not reason:find("pilot", 1, true) and "cancelled" or nil)
    end
  elseif msg.op == "state" and (m.stage == "FLY" or m.stage == "AIM" or m.stage == "SCAN") then
    if m.gun then S.gunSolve(m, msg) end
    if m.stage == "FLY" then
      m.phase, m.dist = msg.phase, msg.dist
      if now() >= (m.reportAt or 0) then
        m.reportAt = now() + 1
        S.report(("%s %.0f blocks"):format(msg.phase, msg.dist or 0), { phase = msg.phase, dist = msg.dist })
      end
    end
  elseif msg.op == "onstation" and m.stage == "FLY" then
    S.voice(m, "arrive")                       -- (pickup: "in position"; escape: "altitude reached")
    if m.strat.kind == "escape" then
      return S.finish(true, ("escape altitude reached (Y %s)"):format(
        type(S.helmNav) == "table" and ("%.0f"):format(S.helmNav[2]) or tostring(m.strat.altitude)))
    end
    if m.gun then
      m.stage, m.aimStart = "AIM", now()
      S.log("On station - aiming")
      S.voice(m, "aim")
      S.report("AIMING", { phase = "AIM" })
    elseif m.rail then
      if m.rail.phase == "RANGE" then
        -- (no target was picked: the caller calls again from here)
        return S.finish(true, "in radar range now - call the railcannon again")
      end
      -- the radar work runs in the gun coroutine (S.railService)
      m.stage = "SCAN"
      S.log("On station - checking the target")
      S.report("CHECKING TARGET", { phase = "AIM" })
    else
      S.startFire()
    end
  end
end

function S.fromPocket(id, msg)
  if not allowedPocket(id) then
    S.log("Ignored message from computer " .. id .. " (not in pockets)")
    S.toPocket(id, { op = "status", text = "REFUSED: this pocket (ID " .. id .. ") is not in strike.cfg pockets", done = true, ok = false })
    return
  end
  if msg.op == "list" then
    local list = {}
    for _, s in ipairs(S.cfg.stratagems) do
      local ok, why = S.ready(s)
      list[#list + 1] = { name = s.name, code = s.code, kind = s.kind, voice = s.voice, ok = ok, why = why }
    end
    S.toPocket(id, { op = "list", stratagems = list, busy = S.mission ~= nil, queue = #S.queue })
  elseif msg.op == "statusanchor" then
    -- (the status hologram placed from a pair of glasses: kept here for everyone)
    local a = S.cleanAnchor(msg.anchor)
    if a then
      S.cfg.statusAnchor = a
      S.saveConfig()
      S.hudStatusAt = 0
      S.log(("Status hologram placed (%s, %.1f blocks) from computer %d"):format(a.mode, a.size, id))
    end
  elseif msg.op == "call" and type(msg.world) == "table" then
    local w = msg.world
    local x, y, z = tonumber(w.x), tonumber(w.y), tonumber(w.z)
    if not (x and y and z) then return S.refuse(id, msg.id, "bad coordinates") end
    S.coordQueue[#S.coordQueue + 1] = { pocket = id, msg = msg, world = { x, y, z } }
  elseif msg.op == "call" then
    S.call(id, msg)
  elseif msg.op == "abort" then
    S.cancelAll("called off from the pocket")
  elseif msg.op == "lock" then
    -- (the map: L on a contact, or middle-click its token on the table) the radar's target; on = false lets go
    if msg.on and msg.track and S.isDebris(msg.track) then
      -- (wreckage is never a target: the lock stays as it was)
      S.log("Radar lock on debris refused: " .. tostring(msg.track))
      S.toPocket(id, { op = "lock", track = S.lockTrack, refused = "debris" })
      return
    end
    S.lockTrack = msg.on and msg.track and tostring(msg.track) or nil
    -- (picked by hand: kept while seen; let go by hand: no auto-lock for 30 s)
    S.lockManual, S.lockSeen = S.lockTrack ~= nil or nil, now()
    if not S.lockTrack then S.lockReleasedAt = now() end
    S.log(S.lockTrack and ("Radar lock: " .. S.lockTrack) or "Radar lock released")
    S.toPocket(id, { op = "lock", track = S.lockTrack })
    S.hudRadarAt = 0
  elseif msg.op == "friend" then
    -- (the war table: F on a contact) on = friendly / not
    local ok = S.setFriendly(msg.track, msg.on == true, msg.label)
    S.toPocket(id, { op = "friend", track = msg.track, on = ok and msg.on == true, ok = ok })
    S.hudRadarAt = 0                       -- (the maps hear it straight away)
  elseif msg.op == "designate" then
    -- (the map: I on a contact) the icon the maps show it as; nil = by the radar
    local tid = tostring(msg.track or "")
    if tid ~= "" and (msg.ent == nil or S.DESIGNATIONS[msg.ent]) then
      if type(S.cfg.designate) ~= "table" then S.cfg.designate = {} end
      S.cfg.designate[tid] = msg.ent
      S.saveConfig()
      S.log(("Designated %s: %s"):format(tid, tostring(msg.ent or "by the radar")))
    end
    S.hudRadarAt = 0
  end
end
S.DESIGNATIONS = { helldiver = true, friendly_player = true, hostile_player = true, friendly_ship = true, hostile_ship = true }

-- Once a second: keep helm's link alive, count down the weapon, watch helm
function S.tick()
  S.toHelm({ op = "ping" })
  local okst, errst = pcall(S.hudStatus)
  if not okst then S.log("HUD status error: " .. tostring(errst)) end
  -- no PA yet: ask again every 5 s (its "hello" may have been missed)
  if not S.paId and now() >= (S.paAskAt or 0) then
    S.paAskAt = now() + 5
    pcall(rednet.broadcast, { op = "who" }, S.PROTO_PA)
  end
  local sd = S.side
  if sd and sd.stage == "FIRE" and now() >= sd.fireEnd then
    local imp = sd.gun.impactAt and sd.gun.impactAt - now()
    S.finish(true, sd.strat.name .. (imp and imp > 0 and (" fired - impact in %.0f s"):format(imp) or " finished"), sd)
  end
  local m = S.mission
  if not m then return end
  if m.stage == "FLY" and now() - m.heard > S.cfg.helmTimeout then
    S.finish(false, "lost contact with helm", m, "unable_to_reach")
  elseif m.stage == "FIRE" then
    local left = m.fireEnd - now()
    if left <= 0 then
      local imp = m.gun and m.gun.impactAt and m.gun.impactAt - now()
      S.finish(true, m.strat.name .. (imp and imp > 0 and (" fired - impact in %.0f s"):format(imp) or " finished"))
    elseif m.mainEnd then
      local start = m.mainEnd - m.strat.fireTime
      local txt = now() < start and ("LOADING %ds"):format(math.ceil(start - now()))
        or now() < m.mainEnd and ("FIRING %ds"):format(math.ceil(left))
        or ("FLUSHING %ds"):format(math.ceil(left))
      S.report(txt, { phase = "FIRE", remaining = left })
    elseif m.volleyTimes then
      local first = m.volleyTimes[1] - now()
      if m.volleysFired == 0 and first > 0 then
        S.report(("LOADING %ds"):format(math.ceil(first)), { phase = "FIRE", remaining = left })
      end
    elseif not m.gun then
      S.report((m.strat.dryRun and "ON STATION %ds" or "FIRING %ds"):format(math.ceil(left)), { phase = "FIRE", remaining = left })
    end
  end
end

---------------------------------------------------------------- commands
-- Typed at the strike computer, then Enter. S.command returns the reply line.

local function squash(s) return (tostring(s):lower():gsub("[^%w]", "")) end

-- The stratagems a word means: "all", an arrow code, a name, or part of a
-- name (spaces and capitals ignored: "barrage", "CannonBarrage", "RRDLRD")
function S.matchStratagems(word)
  local list, w = S.cfg.stratagems, squash(word)
  if w == "" then return {} end
  if w == "all" then return list end
  for _, s in ipairs(list) do
    if s.code == word:upper() or squash(s.name) == w then return { s } end
  end
  local found = {}
  for _, s in ipairs(list) do
    if squash(s.name):find(w, 1, true) then found[#found + 1] = s end
  end
  return found
end

S.HELP = "call <stratagem> <x> <y> <z>, height <stratagem|all> <blocks>, <stratagem> height <blocks>, heights, abort, radar, radar watch, "
  .. "contacts, friends, friend <who> [label], unfriend <who>, lock <who>, unlock, autolock on|off, "
  .. "debris [<who>], undebris <who>, debris auto <seconds>|off, engaged [reset], gunner help"

-- Who a word means: radar contacts by the start of their id (4+ letters) or
-- a player's / ship's name; friends = true: the friendly list as well (id
-- start or label); debris = true: the debris list as well (id start or ship
-- name). A whole id written out counts even if not on the radar
function S.findContacts(word, friends, debris)
  local w = tostring(word or ""):lower()
  local out, seen = {}, {}
  local shipNames = type(S.cfg.shipNames) == "table" and S.cfg.shipNames or {}
  local function add(id, label, cat)
    if not seen[id] then
      seen[id] = true
      out[#out + 1] = { id = id, label = label, cat = cat }
    end
  end
  for _, t in ipairs(S.lastTracks or {}) do
    local id = tostring(t.id or "")
    local name = S.playerNames[id] or shipNames[id] or (S.crew[id] and S.crew[id].name)
    if id ~= "" and ((#w >= 4 and id:lower():sub(1, #w) == w) or (name and tostring(name):lower() == w)) then
      add(id, name and tostring(name) or nil, tostring(t.category or ""):upper())
    end
  end
  if friends and type(S.cfg.friendly) == "table" then
    for id, label in pairs(S.cfg.friendly) do
      if (#w >= 4 and id:lower():sub(1, #w) == w) or tostring(label):lower() == w then add(id, tostring(label)) end
    end
  end
  if debris and type(S.cfg.debris) == "table" then
    for id in pairs(S.cfg.debris) do
      local name = shipNames[id] and tostring(shipNames[id])
      if (#w >= 4 and id:lower():sub(1, #w) == w) or (name and name:lower() == w) then add(id, name) end
    end
  end
  if #out == 0 and #w >= 32 then add(tostring(word), nil) end
  return out
end

local function which(list)
  local parts = {}
  for _, c in ipairs(list) do parts[#parts + 1] = c.id:sub(1, 8) .. (c.label and (" " .. c.label) or "") end
  return table.concat(parts, ", ")
end

-- The friendly list (everything else on the radar is hostile), for the screen and the log
function S.friendsText()
  local list = {}
  for id, label in pairs(type(S.cfg.friendly) == "table" and S.cfg.friendly or {}) do list[#list + 1] = { id = id, label = label } end
  table.sort(list, function(a, b) return tostring(a.label) < tostring(b.label) end)
  if #list == 0 then return "no friendlies - everything on the radar is hostile (friend <who> adds one)" end
  local parts = {}
  for _, f in ipairs(list) do parts[#parts + 1] = ("%s %s"):format(f.id:sub(1, 8), tostring(f.label)) end
  S.log("Friendlies: " .. table.concat(parts, "; "))
  return ("friendlies (%d): %s"):format(#list, table.concat(parts, "; "))
end

-- The debris list, and (debrisAfter) the ships counted as debris now for
-- sitting still
function S.debrisText()
  local shipNames = type(S.cfg.shipNames) == "table" and S.cfg.shipNames or {}
  local listed = type(S.cfg.debris) == "table" and S.cfg.debris or {}
  local parts = {}
  for id in pairs(listed) do parts[#parts + 1] = id:sub(1, 8) .. (shipNames[id] and (" " .. tostring(shipNames[id])) or "") end
  table.sort(parts)
  local after, auto = tonumber(S.cfg.debrisAfter), {}
  local autoText = "; auto off"
  if after and after > 0 then
    for id, s in pairs(S.still) do
      if not listed[id] and now() - s.since >= after then auto[#auto + 1] = ("%s still %.0f s"):format(id:sub(1, 8), now() - s.since) end
    end
    table.sort(auto)
    autoText = ("; auto after %g s still: %s"):format(after, #auto > 0 and table.concat(auto, ", ") or "none now")
  end
  local text = #parts == 0 and ("no debris marked (debris <who> marks a wreck)" .. autoText)
    or ("debris (%d): %s%s"):format(#parts, table.concat(parts, "; "), autoText)
  S.log(text)
  return text
end

-- What the radar sees now, nearest first: id, kind, name, distance, F = friendly, L = locked, D = debris
function S.contactsText()
  local tr = S.lastTracks
  if not tr or now() - (S.lastTracksAt or -100) > 10 then return "no radar contacts read lately (is the radar turning?)" end
  local here = S.navWorld
  local shipNames = type(S.cfg.shipNames) == "table" and S.cfg.shipNames or {}
  local list = {}
  for _, t in ipairs(tr) do
    local p, id, cat = v3of(t.position), tostring(t.id or ""), tostring(t.category or ""):upper()
    if p and (cat == "PLAYER" or cat == "SABLE") and not (S.ownShipId and t.id == S.ownShipId) then
      local d = here and math.sqrt((p[1] - here[1]) ^ 2 + (p[2] - here[2]) ^ 2 + (p[3] - here[3]) ^ 2) or 0
      local name = S.playerNames[id] or shipNames[id] or (S.crew[id] and S.crew[id].name)
      list[#list + 1] = { d = d, text = ("%s %s%s %.0fm%s%s"):format(id:sub(1, 8), cat == "PLAYER" and "player" or "ship",
        name and (" " .. tostring(name)) or "", d, S.isFriendlyTarget(id) and " F" or "", id == S.lockTrack and " L" or "")
        .. (S.isDebris(id) and " D" or "") }
    end
  end
  table.sort(list, function(a, b) return a.d < b.d end)
  if #list == 0 then return "no players or ships on the radar" end
  local parts = {}
  for i, c in ipairs(list) do parts[i] = c.text end
  S.log("Contacts: " .. table.concat(parts, "; "))
  return ("contacts (%d, nearest first): %s"):format(#list, table.concat(parts, "; "))
end

-- friends / contacts / friend / unfriend / lock / unlock / autolock (nil: not one of them)
function S.targetCommand(verb, words)
  if verb == "friends" or verb == "friendlies" then return S.friendsText() end
  if verb == "contacts" then return S.contactsText() end
  if verb == "autolock" then
    local w = words[2] and words[2]:lower()
    if w ~= "on" and w ~= "off" then return "autolock is " .. (S.cfg.autoLock == false and "off" or "on") .. " - autolock on|off" end
    S.cfg.autoLock = w == "on"
    S.saveConfig()
    S.log("Auto-lock " .. w)
    return "auto-lock " .. w .. (w == "on" and " - the nearest hostile player or ship is locked when nothing is" or "")
  end
  if verb == "unlock" then
    if not S.lockTrack then return "no radar lock" end
    S.log("Radar lock released at the strike computer")
    S.lockTrack, S.lockManual, S.lockReleasedAt = nil, nil, now()
    S.hudRadarAt = 0
    return "radar lock released (auto-lock waits 30 s)"
  end
  if verb == "debris" or verb == "wrecks" then
    local w2 = words[2] and words[2]:lower()
    if not w2 or verb == "wrecks" then return S.debrisText() end
    if w2 == "auto" then
      local v = words[3] and words[3]:lower()
      local n = tonumber(v)
      if v == "off" then
        S.cfg.debrisAfter = false
      elseif n and n > 0 then
        S.cfg.debrisAfter = n
      else
        local cur = tonumber(S.cfg.debrisAfter)
        return "debris auto is " .. (cur and cur > 0 and (cur .. " s") or "off") .. " - debris auto <seconds> | off"
      end
      S.saveConfig()
      S.hudRadarAt = 0
      S.log("Debris auto: " .. tostring(S.cfg.debrisAfter))
      return n and ("debris auto: a ship still for %g s counts as debris until it moves"):format(n) or "debris auto off"
    end
  end
  if verb ~= "friend" and verb ~= "unfriend" and verb ~= "lock" and verb ~= "debris" and verb ~= "undebris" then return nil end
  if not words[2] then return verb .. " <id start or name> - contacts lists them" end
  local found = S.findContacts(words[2], verb == "unfriend", verb == "undebris")
  if verb == "unfriend" then
    local fr = {}
    for _, c in ipairs(found) do if S.isFriendly(c.id) then fr[#fr + 1] = c end end
    found = fr
  elseif verb == "undebris" then
    local listed, still = {}, nil
    for _, c in ipairs(found) do
      if type(S.cfg.debris) == "table" and S.cfg.debris[c.id] then listed[#listed + 1] = c
      elseif S.isDebris(c.id) then still = c end
    end
    if #listed == 0 and still then
      return ("%s counts as debris for sitting still - it clears when it moves (or: debris auto off)"):format(still.label or still.id:sub(1, 8))
    end
    found = listed
  end
  if #found == 0 then
    return ("nothing matches '%s'%s"):format(words[2], verb == "unfriend" and " on the friendly list"
      or verb == "undebris" and " on the debris list" or " on the radar (contacts lists it)")
  end
  if #found > 1 then return ("'%s' matches %d: %s - be more exact"):format(words[2], #found, which(found)) end
  local c = found[1]
  if verb == "debris" then
    S.setDebris(c.id, true)
    if S.lockTrack == c.id then S.lockTrack, S.lockManual = nil, nil end   -- (never stay locked on wreckage)
    S.hudRadarAt = 0
    return ("debris: %s %s - the weapons ignore it"):format(c.id:sub(1, 8), c.label or "")
  end
  if verb == "undebris" then
    S.setDebris(c.id, false)
    S.hudRadarAt = 0
    return ("%s %s is no longer debris"):format(c.id:sub(1, 8), c.label or "")
  end
  if verb == "unfriend" then
    S.setFriendly(c.id, false)
    S.hudRadarAt = 0
    return ("%s %s is hostile again"):format(c.id:sub(1, 8), c.label or "")
  end
  if verb == "friend" then
    local label = #words > 2 and table.concat(words, " ", 3) or c.label
      or ((c.cat == "PLAYER" and "PLAYER " or "SHIP ") .. c.id:sub(1, 8))
    S.setFriendly(c.id, true, label)
    if S.lockTrack == c.id then S.lockTrack, S.lockManual = nil, nil end   -- (never stay locked on a friendly)
    S.hudRadarAt = 0
    return ("friendly: %s (%s)"):format(label, c.id:sub(1, 8))
  end
  -- lock
  if S.isFriendlyTarget(c.id) then return ("%s is friendly - unfriend it first"):format(c.label or c.id:sub(1, 8)) end
  if S.isDebris(c.id) then return ("%s is debris - undebris it first"):format(c.label or c.id:sub(1, 8)) end
  S.lockTrack, S.lockManual, S.lockSeen = c.id, true, now()
  S.log("Radar lock (typed): " .. c.id)
  S.hudRadarAt = 0
  return ("radar lock: %s %s - the railcannon fires at it"):format(c.id:sub(1, 8), c.label or "")
end

function S.command(line)
  local words = {}
  for w in line:gmatch("%S+") do words[#words + 1] = w end
  if #words == 0 then return nil end
  local verb = words[1]:lower()
  if verb == "help" or verb == "?" then return S.HELP end
  local tr = S.targetCommand(verb, words)
  if tr then return tr end
  if verb == "gunner" then
    if not S.gunner then return "gunner.lua is not installed" end
    S.gunQueue[#S.gunQueue + 1] = words
    return "gunner: working..."
  end
  if verb == "radar" then
    if words[2] and words[2]:lower() == "watch" then
      -- log what the radar sees every 5 s for 2 minutes (read strike.log)
      S.radarWatch, S.radarWatchNext = now() + 120, 0
      return "radar: logging what it sees every 5 s for 2 minutes"
    end
    S.radarQuery = true                       -- answered by the gun coroutine
    return "radar: looking..."
  end
  if verb == "engaged" then
    if words[2] and words[2]:lower() == "reset" then
      S.engagedMost, S.engaged = {}, nil
      S.writeEngagedMost()
      return "engaged: the most seen forgotten - each gun group is learnt again (stow them all for a scan)"
    end
    if not S.engagedCount then return "engaged: no Geo Scanner on the network (or no scan yet)" end
    local parts, most = {}, S.engagedMost or {}
    for sys, c in pairs(S.engagedCount) do
      local on = S.engaged and S.engaged[sys]
      parts[#parts + 1] = ("%s %d/%d%s"):format(sys, c, tonumber(most[sys]) or 0, on == true and " ENGAGED" or on == false and " stowed" or " (never seen)")
    end
    table.sort(parts)
    return "engaged (blocks now/most seen): " .. table.concat(parts, ", ")
  end
  if verb == "call" then
    -- call <stratagem name, part of it, or code> <x> <y> <z> (F3 world coordinates)
    local x, y, z = tonumber(words[#words - 2] or ""), tonumber(words[#words - 1] or ""), tonumber(words[#words] or "")
    if #words < 5 or not (x and y and z) then return "call <stratagem> <x> <y> <z> (F3 world coordinates)" end
    local who = table.concat(words, " ", 2, #words - 3)
    local list = S.matchStratagems(who)
    if #list == 0 then return "no stratagem matches '" .. who .. "' (heights lists them)" end
    if #list > 1 then return "'" .. who .. "' matches several stratagems - be more exact" end
    S.coordQueue[#S.coordQueue + 1] = { pocket = 0, msg = { code = list[1].code }, world = { x, y, z }, name = list[1].name }
    return ("calling %s at %g %g %g..."):format(list[1].name, x, y, z)
  end
  if verb == "abort" then
    if not S.cancelAll("called off at the strike computer") then return "no mission to abort" end
    return "mission aborted"
  end
  if verb == "heights" or (verb == "height" and #words == 1) then
    local parts = {}
    for _, s in ipairs(S.cfg.stratagems) do parts[#parts + 1] = ("%s %g"):format(s.name, s.offset.u) end
    return "heights: " .. table.concat(parts, ", ")
  end
  -- "height <who> <n>" or "<who> height <n>"
  local who, n
  if verb == "height" then
    who, n = table.concat(words, " ", 2, #words - 1), words[#words]
  else
    for i = 2, #words - 1 do
      if words[i]:lower() == "height" and i + 1 == #words then
        who, n = table.concat(words, " ", 1, i - 1), words[i + 1]
      end
    end
  end
  if not who then return "unknown command - " .. S.HELP end
  if squash(who) == "" then return "which stratagem? e.g. height barrage 750 (or height all 1000)" end
  local h = tonumber(n)
  if not h or h <= 0 or h > S.MAX_HEIGHT then
    return ("height must be a number of blocks, 1-%d"):format(S.MAX_HEIGHT)
  end
  local list = S.matchStratagems(who)
  local names = {}
  for _, s in ipairs(list) do names[#names + 1] = s.name end
  if #list == 0 then return "no stratagem matches '" .. who .. "' (heights lists them)" end
  if #list > 1 and squash(who) ~= "all" then
    return "'" .. who .. "' matches " .. table.concat(names, ", ") .. " - be more exact"
  end
  for _, s in ipairs(list) do s.offset.u = h end
  local saved = S.saveConfig()
  S.log(("Height of %s set to %g%s"):format(table.concat(names, ", "), h, saved and "" or " (strike.cfg NOT saved)"))
  local busy = S.mission and " - the current mission keeps its height" or ""
  return ("%s: height %g%s%s"):format(table.concat(names, ", "), h, saved and "" or " (NOT saved)", busy)
end

---------------------------------------------------------------- screen

function S.draw()
  local w, h = term.getSize()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.yellow)
  print("STRIKE " .. S.VERSION .. "  computer " .. os.getComputerID())
  term.setTextColor(colors.white)
  local helmOk = S.helmSeen and now() - S.helmSeen < S.cfg.helmTimeout
  print(("helm %d: %s%s"):format(S.cfg.helmId, helmOk and "online" or "NOT ANSWERING",
    helmOk and not S.helmCalibrated and " (not calibrated)" or ""))
  print(("pocket link: %s   pockets: %s"):format(S.haveWireless and "ok" or "NO WIRELESS MODEM",
    #S.cfg.pockets > 0 and table.concat(S.cfg.pockets, ",") or "NONE SET"))
  print("")
  local m = S.mission
  if m then
    term.setTextColor(colors.orange)
    print("MISSION: " .. m.strat.name)
    term.setTextColor(colors.white)
    print(S.statusText or "")
  else
    print("Ready. Stratagems:")
    for _, s in ipairs(S.cfg.stratagems) do
      print((" %-18s %-8s %5g up%s"):format(s.name, s.code, s.offset.u, s.dryRun and "  (dry run)" or ""))
    end
    if S.statusText then print("") print("Last: " .. S.statusText) end
  end
  if S.side then
    term.setTextColor(colors.orange)
    print("BESIDE: " .. S.side.strat.name .. " (" .. S.side.stage .. ")")
    term.setTextColor(colors.white)
  end
  if #S.queue > 0 then
    local names = {}
    for _, c in ipairs(S.queue) do names[#names + 1] = c.strat.name end
    print("Waiting: " .. table.concat(names, ", "))
  end
  if S.gunner then
    print(("guns: %s%s"):format(G.calReady(S.gunner.cal) and "calibrated" or "not calibrated (gunner cal)",
      S.gunner.msg and (" - " .. S.gunner.msg) or ""))
  end
  if S.reply then
    -- a long reply wraps upward over up to 6 lines above the prompt
    local lines, rest = {}, S.reply
    while #rest > 0 and #lines < 6 do
      local cut = #rest <= w and #rest or (rest:sub(1, w):match("^.*()[ ,;]") or w)
      lines[#lines + 1] = rest:sub(1, cut):gsub("^%s+", "")
      rest = rest:sub(cut + 1)
    end
    term.setTextColor(colors.lightBlue)
    for i, l in ipairs(lines) do
      term.setCursorPos(1, h - 2 - #lines + i)
      term.clearLine()
      term.write(l)
    end
  end
  term.setCursorPos(1, h - 1)
  term.setTextColor(colors.yellow)
  term.write("> " .. (S.input or ""))
  term.setCursorPos(1, h)
  term.setTextColor(colors.lightGray)
  term.write("type help + Enter   abort = call off   Ctrl+T = quit")
  term.setTextColor(colors.white)
  term.setCursorPos(math.min(3 + #(S.input or ""), w), h - 1)
  term.setCursorBlink(true)
  -- the same for reading from outside the game
  pcall(function()
    local f = fs.open(S.FILES.status, "w")
    local waiting = {}
    for _, c in ipairs(S.queue) do waiting[#waiting + 1] = c.strat.name end
    f.write(("strike %s at clock %.1f\nhelm %s calibrated %s\nmission %s\n%s\nbeside %s, waiting: %s, PA %s\n"):format(
      S.VERSION, now(), helmOk and "online" or "silent", tostring(S.helmCalibrated),
      m and (m.strat.name .. " " .. m.stage) or "none", S.statusText or "",
      S.side and (S.side.strat.name .. " " .. S.side.stage) or "none",
      #waiting > 0 and table.concat(waiting, ", ") or "none", S.paId and ("computer " .. S.paId) or "not found"))
    f.write(("radar %s, demo %s\n"):format(tostring(S.radarState or "not read yet"), tostring(S.cfg.demo == true)))
    local gn = S.gunner
    if gn then
      local rp = {}
      for k, v in pairs(gn.rpm) do rp[#rp + 1] = k .. "=" .. tostring(v) end
      f.write(("guns: %s, job %s, dud yaw %s pitch %s, rpm %s, msg %s\nlast reply: %s\n"):format(
        G.calReady(gn.cal) and "calibrated" or "not calibrated", gn.job and (gn.job.kind .. "/" .. tostring(gn.job.stage)) or "none",
        tostring(gn.yaw), tostring(gn.pitch), table.concat(rp, " "), tostring(gn.msg), tostring(S.reply)))
    end
    f.close()
  end)
end

---------------------------------------------------------------- main

function S.run()
  S.loadConfig()
  local problems = S.checkStratagems(S.cfg.stratagems)
  if #problems > 0 then
    for _, p in ipairs(problems) do printError(p) end
    error("Fix strike.cfg, then reboot", 0)
  end
  S.openModems()
  -- every output starts low
  for _, s in ipairs(S.cfg.stratagems) do
    if s.output then setOut(s.output, false) end
    if type(s.load) == "table" then
      for _, l in ipairs(s.load[1] and s.load or { s.load }) do setOut(l, false) end
    end
  end
  if type(S.cfg.radar) == "table" and type(S.cfg.radar.resetLink) == "table" then
    setOut(S.cfg.radar.resetLink, false)      -- never leave the radar stopped
  end
  if G and S.cfg.gun then
    S.gunner = G.new({
      call = peripheral.call,
      find = function(ty)
        local t = {}
        for _, n in ipairs(peripheral.getNames()) do
          if peripheral.hasType(n, ty) then t[#t + 1] = n end
        end
        table.sort(t)
        return t
      end,
      now = now, log = S.log, fs = fs,
      -- a relay computer on an array gun (gun.relay = its ID) replaces the dud
      mountRead = S.cfg.gun.relay and S.relayRead or nil,
      mountFacing = S.cfg.gun.relay and S.relayFacing or nil,
    }, S.cfg.gun)
    S.gunner:stopAll()                        -- never resume an old shaft speed
  end
  S.log("started")
  -- (a trip helm still holds from before a restart is one strike no longer
  -- knows about: let it go, or the first call is refused as "autopilot busy")
  S.toHelm({ op = "release" })
  if S.cfg.demo == true then S.log("DEMO: every stratagem a dry run - nothing is loaded or fired") end
  -- find the PA (it answers "hello"); the line waits for it
  pcall(rednet.broadcast, { op = "who" }, S.PROTO_PA)
  S.say("weapons_online", "strike")
  parallel.waitForAny(S.mainLoop, S.gunLoop)
  if S.gunner then pcall(function() S.gunner:stopAll() end) end
  S.log("stopped")
end

function S.mainLoop()
  local tick = os.startTimer(0)
  S.draw()
  while true do
    local ev = { os.pullEventRaw() }
    local e = ev[1]
    if e == "terminate" then
      S.dropQueue("strike computer stopped")
      if S.side then S.finish(false, "strike computer stopped", S.side) end
      if S.mission then S.finish(false, "strike computer stopped") end
      -- let a queued OFF pulse go out before quitting
      local deadline = os.startTimer(1)
      while true do
        local ev2 = { os.pullEventRaw() }
        if ev2[1] == "timer" and S.timers[ev2[2]] then
          local key = S.timers[ev2[2]]
          S.timers[ev2[2]] = nil
          S.pulseNext(key)
        elseif ev2[1] == "timer" and ev2[2] == deadline then
          break
        end
      end
      return
    elseif e == "timer" then
      if ev[2] == tick then
        S.tick()
        S.draw()
        tick = os.startTimer(1)
      elseif S.timers[ev[2]] then
        local key = S.timers[ev[2]]
        S.timers[ev[2]] = nil
        S.pulseNext(key)
      elseif S.calls[ev[2]] then
        local fn = S.calls[ev[2]]
        S.calls[ev[2]] = nil
        fn()
      end
    elseif e == "rednet_message" then
      local id, msg, proto = ev[2], ev[3], ev[4]
      if type(msg) == "table" then
        if proto == S.PROTO_HELM and id == S.cfg.helmId then
          S.fromHelm(msg)
        elseif proto == S.PROTO_POCKET then
          S.fromPocket(id, msg)
          S.draw()
        elseif proto == S.PROTO_RELAY and S.cfg.gun and id == S.cfg.gun.relay then
          S.fromRelay(msg)
        elseif proto == S.PROTO_PA then
          S.fromPA(id, msg)
        elseif proto == "hd2.team" and msg.op == "hi" then
          S.noteCrew(msg)                    -- (helldivers' glasses: friendly players)
        end
      end
    elseif e == "char" then
      S.input = ((S.input or "") .. ev[2]):sub(1, 60)
      S.draw()
    elseif e == "key" then
      if ev[2] == keys.backspace then
        S.input = (S.input or ""):sub(1, -2)
        S.draw()
      elseif ev[2] == keys.enter or ev[2] == keys.numPadEnter then
        local line = S.input or ""
        S.input = ""
        S.reply = S.command(line) or S.reply
        S.draw()
      end
    end
  end
end

-- Offline tests (test/strike_test.lua) load this file with STRIKE_TEST set
if STRIKE_TEST then return S end

local ok, err = pcall(S.run)
if not ok then
  -- never leave a weapon latched on by accident
  if S.mission and S.mission.rapid then setOut(S.mission.rapid.out, false) end
  if S.mission and S.mission.latchOn and S.mission.strat.output then
    local out, len = S.mission.strat.output, (S.cfg and S.cfg.pulse) or 0.2
    setOut(out, false)
    sleep(len)
    setOut(out, true)
    sleep(len)
    setOut(out, false)
  end
  if S.gunner then pcall(function() S.gunner:stopAll() end) end
  S.log("CRASH " .. tostring(err))
  printError("strike: " .. tostring(err))
end
