--[[
war.lua - the war table, part of the HD2 HUD (hud.lua loads it)      v1.15.0

  M (while the keyboard is the glasses')  the war table menu. The mouse works
       the menu instead of your head:
         top-down map   drag = move, scroll = zoom, click = that spot in 3D,
                        right-click = a target: the stratagem list opens,
                        its code typed with the arrows calls it there
                        (Backspace: no target), type x z + Enter = go to
                        coordinates; the cursor shows x y z and the block
         3D             left-drag = turn / tilt, right-drag = move, scroll =
                        zoom, Page Up / Down = the heights shown, right-click
                        = a target on the block under the cursor (as on the
                        top-down map), Tab / middle click = back to the
                        top-down map, Enter = put it on the table now. Up to
                        256 blocks across the ground comes in squares fitted
                        to its heights, each topped with a picture of its
                        blocks (their textures close up), lit from the
                        north-west, shaded under anything taller; close up,
                        with boxes to spare, single blocks as the real block
                        (stairs, slabs ... facing as in the world)
         [ ]            (top-down map / 3D) detail 1-5: more squares, more
                        layers - kept in hud.cfg; more costs frames
       Both maps show the field: you @, helldivers by tag, hostiles x red,
       friendlies o green, other players ? orange, ships # purple, the
       destroyer D, stratagems with their icons and beacons
         T              place the table: look at it, then drag = slide it,
                        right-drag = up / down, scroll = size, middle click /
                        [ ] = turn, Home = to where you stand, arrows / Page
                        Up / Down = fine steps, Enter = done
       Esc leaves - and puts the 3D view you chose on the table.
  The table: every HUD wearer near it sees that area in 3D, real blocks,
  standing on it; on the destroyer it moves with the ship (strike sends the
  ship's position). The map computer (warmap.lua, "warmap") keeps the terrain
  every helldiver scans and the table, and tells every pair of glasses.
]]

return function(H)
local W = { VERSION = "1.25.1" }
H.W = W
H.PROTO_MAP = "hd2.map"
H.MAP_HOST = "warmap"

local now = os.clock
local atan2 = math.atan2 or math.atan
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function epoch() return os.epoch("utc") end
local function copy(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = copy(v) end
  return c
end

W.DEFAULTS = {
  key = "m",                 -- CC key name: the field map (while the keyboard is the glasses') - never changes the table
  tableKey = "n",            -- CC key name: the war table's editor (what it shows, where it stands)
  imageSize = 512,           -- the top-down map's pixels a side (a block a pixel up to this many across)
  view3dSize = 2.0,          -- the menu's 3D view: its width (blocks, 1.8 blocks ahead of the eye)
  view3dObjects = 3200,      -- most overlay objects it may use
  perFrame = 1024,           -- overlay objects changed per frame (10 frames a second)
  near = 40,                 -- the table shows within this many blocks of it
  moveEvery = 0.5,           -- s between moves of the table while the ship moves (it glides between)
  glide = 10,                -- ticks a table move takes
  -- heights are true to scale (a block up = a block across); the model is at
  -- most this many times its width tall - higher is cut off (Page Up / Down
  -- in the 3D view moves the heights shown)
  heightLimit = 1.0,
  tableObjects = 6000,       -- most overlay objects the table may use (more: simpler blocks)
  detail = 2,                -- 1-5 (- / = in the menu): more squares, layers kept apart closer - more FPS cost
  renderer = "slices",       -- the 3D view: "slices" (every block, see-through levels) or "squares" (V switches)
  -- the destroyer on the maps: its outline (icons/ent_destroyer.png, bow up,
  -- from the MOR schematic - tools/shipicon.py) at its real size, blocks.
  -- centre: its middle from the nav table (r right, f ahead) - strike's
  -- measure from the radar wins when it has one. flip: the bow the other way
  -- scale: drawn at this many times its real size (0.125: an eighth - a marker, not a wall)
  ship = { length = 262, width = 112, centre = { r = 0, f = 0 }, flip = false, scale = 0.125 },
}

-- The detail levels: squares in the 3D view (the table gets 1.65x), layers
-- closer than `gap` blocks joined, at most `cap` layers a column, pictures
-- about `px` pixels across the whole view (the view is ~760 on screen)
W.DETAIL = {
  { squares = 900, gap = 6, cap = 3, px = 256, vox = 64 },
  { squares = 1450, gap = 4, cap = 4, px = 384, vox = 96 },
  { squares = 2200, gap = 3, cap = 5, px = 512, vox = 128 },
  { squares = 3200, gap = 2, cap = 6, px = 640, vox = 192 },
  { squares = 4500, gap = 1, cap = 8, px = 768, vox = 256 },
}
-- (vox: the slices renderer's blocks across at most - wider views: a voxel is several blocks)
W.TABLE_SHARE = 1.65

function W.detail()
  local n = clamp(math.floor(tonumber(H.cfg.war.detail) or 2), 1, #W.DETAIL)
  return W.DETAIL[n], n
end

---------------------------------------------------------------- maths
-- 3x3 matrices, m[row][col]

function W.mul(a, b)
  local m = {}
  for r = 1, 3 do
    m[r] = {}
    for c = 1, 3 do m[r][c] = a[r][1] * b[1][c] + a[r][2] * b[2][c] + a[r][3] * b[3][c] end
  end
  return m
end

function W.apply(m, v)
  return { m[1][1] * v[1] + m[1][2] * v[2] + m[1][3] * v[3], m[2][1] * v[1] + m[2][2] * v[2] + m[2][3] * v[3],
    m[3][1] * v[1] + m[3][2] * v[2] + m[3][3] * v[3] }
end

function W.rotY(deg)
  local a = math.rad(deg)
  local c, s = math.cos(a), math.sin(a)
  return { { c, 0, s }, { 0, 1, 0 }, { -s, 0, c } }
end

function W.rotX(deg)
  local a = math.rad(deg)
  local c, s = math.cos(a), math.sin(a)
  return { { 1, 0, 0 }, { 0, c, -s }, { 0, s, c } }
end

-- m = Ry(a) Rx(b) Rz(c) - the overlay's rotation order - -> a, b, c degrees
function W.euler(m)
  local sb = clamp(-m[2][3], -1, 1)
  local b = math.asin(sb)
  local a, c
  if math.abs(sb) < 0.99999 then
    a, c = atan2(m[1][3], m[3][3]), atan2(m[2][1], m[2][2])
  else
    a, c = atan2(-m[3][1], m[1][1]), 0
  end
  return math.deg(a), math.deg(b), math.deg(c)
end

---------------------------------------------------------------- the ship

-- strike's pose: the nav table's world position + the ship's axes (r u f)
function W.onPose(msg)
  local n, ax = msg.nav, msg.axes
  if type(n) ~= "table" or type(ax) ~= "table" then return end
  local nav = { tonumber(n[1] or n.x), tonumber(n[2] or n.y), tonumber(n[3] or n.z) }
  if not (nav[1] and nav[2] and nav[3]) then return end
  for _, k in ipairs({ "r", "u", "f" }) do
    if type(ax[k]) ~= "table" or not (tonumber(ax[k][1]) and tonumber(ax[k][2]) and tonumber(ax[k][3])) then return end
  end
  local t = tonumber(msg.t) or epoch()
  local p, v = W.pose, { 0, 0, 0 }
  if p then
    local dt = (t - p.t) / 1000
    if dt > 0.05 and dt < 3 then
      v = { (nav[1] - p.nav[1]) / dt, (nav[2] - p.nav[2]) / dt, (nav[3] - p.nav[3]) / dt }
      if v[1] * v[1] + v[2] * v[2] + v[3] * v[3] > 200 * 200 then v = { 0, 0, 0 } end   -- (a jump, not flight)
    elseif dt >= 0 and dt <= 0.05 then
      v = p.v
    end
  end
  -- (centre: the ship's middle from the nav table, measured by strike from its own radar track)
  local c = msg.centre
  local centre = type(c) == "table" and tonumber(c.r) and tonumber(c.f) and { r = tonumber(c.r), u = tonumber(c.u) or 0,
    f = tonumber(c.f) } or nil
  W.pose = { nav = nav, axes = { r = ax.r, u = ax.u, f = ax.f }, t = t, v = v, at = now(), centre = centre,
    moving = msg.moving == true }
end

-- Is the ship under way (cruising, braking, flown fast)? A table on it hides
-- meanwhile and comes back placed afresh once the ship is still
function W.shipMoving()
  local p = W.pose
  return p ~= nil and p.moving and now() - p.at < 3 or false
end

-- The destroyer's middle in the world and its heading on the map (x east,
-- z south; unit), from the latest pose - nil: no pose lately
function W.shipOutline()
  local nav, ax = W.shipNow(0)
  if not nav then return nil end
  local S = H.cfg.war.ship or {}
  local c = W.pose.centre or (type(S.centre) == "table" and S.centre) or {}
  local cr, cu, cf = tonumber(c.r) or 0, tonumber(c.u) or 0, tonumber(c.f) or 0
  local o = {}
  for i = 1, 3 do o[i] = ax.r[i] * cr + ax.u[i] * cu + ax.f[i] * cf end
  local fx, fz = ax.f[1], ax.f[3]
  local n = math.sqrt(fx * fx + fz * fz)
  if n < 1e-6 then return nil end
  fx, fz = fx / n, fz / n
  if S.flip then fx, fz = -fx, -fz end
  local k = tonumber(S.scale) or 0.125
  return { x = nav[1] + o[1], y = nav[2] + o[2], z = nav[3] + o[3], fx = fx, fz = fz,
    length = (tonumber(S.length) or 262) * k, width = (tonumber(S.width) or 112) * k }
end

-- The nav table now (+ lead s), led on from the last pose; nil = nothing from strike lately
function W.shipNow(lead)
  local p = W.pose
  if not p or now() - p.at > 10 then return nil end
  local dt = clamp((epoch() - p.t) / 1000 + (lead or 0), 0, 1.5)
  return { p.nav[1] + p.v[1] * dt, p.nav[2] + p.v[2] * dt, p.nav[3] + p.v[3] * dt }, p.axes
end

local function shipMatrix(ax)        -- ship (r, u, f) -> world
  return { { ax.r[1], ax.u[1], ax.f[1] }, { ax.r[2], ax.u[2], ax.f[2] }, { ax.r[3], ax.u[3], ax.f[3] } }
end
local FLIP = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, -1 } }   -- map (x east, z south) -> ship (r, f ahead)

-- A table's turn: square to the ship (the table) - the nearest quarter turn
function W.snapYaw(yaw) return (math.floor((tonumber(yaw) or 0) / 90 + 0.5) * 90) % 360 end

-- The table map's centre (world) and its map -> world turn. (The 3D view's
-- own turn is only how it was looked at: the table keeps square to the ship)
function W.tableFrame(anchor, _, lead)
  if type(anchor) ~= "table" then return nil end
  local yaw = W.snapYaw(anchor.yaw)
  if anchor.mode == "world" then
    local w = anchor.world
    return { w[1], w[2], w[3] }, W.rotY(yaw)
  end
  local nav, ax = W.shipNow(lead)
  if not nav then return nil end
  local A = shipMatrix(ax)
  local o = W.apply(A, anchor.rel)
  return { nav[1] + o[1], nav[2] + o[2], nav[3] + o[3] }, W.mul(W.mul(A, FLIP), W.rotY(yaw))
end

-- A world point / direction in the ship's frame {r, u, f} (nil: no pose)
function W.toShip(w, isDir)
  local nav, ax = W.shipNow(0)
  if not nav then return nil end
  local d = isDir and w or { w[1] - nav[1], w[2] - nav[2], w[3] - nav[3] }
  local function dot(a) return a[1] * d[1] + a[2] * d[2] + a[3] * d[3] end
  return { dot(ax.r), dot(ax.u), dot(ax.f) }
end

-- A new table spot 1.5 blocks ahead of the wearer at table height, its
-- north pointing the way they face; on the ship when strike is heard
function W.anchorHere(me)
  local y = math.rad(me.yaw or 0)
  local fwd = { -math.sin(y), 0, math.cos(y) }
  local w = { me.x + fwd[1] * 1.5, me.y + 0.9, me.z + fwd[3] * 1.5 }
  local rel = W.toShip(w)
  if rel then
    local f = W.toShip(fwd, true)
    return { mode = "ship", rel = rel, yaw = math.deg(atan2(-f[1], f[3])), size = 3 }
  end
  return { mode = "world", world = w, yaw = math.deg(atan2(-fwd[1], -fwd[3])), size = 3 }
end

---------------------------------------------------------------- map pieces

-- From the map computer: a square `size` blocks across from x0, z0, as
-- squares { i, j, s, runs } (i east, j south, s blocks a side, from the
-- corner), each square's solid runs highest first: { top, bottom, block }
-- (bottom -2048 = down to the bottom).
--   kind "quad": qs, squares fitted to the ground (warmap 1.2)
--   rs (grid): n x n cells of `cell`, index i*n + j + 1; hs/bs: one height a cell
-- low = the lowest ground (each square's lowest run's top), high = the highest
-- top; colour[name] = the map computer's colour for each block
function W.decode(d)
  if type(d) ~= "table" then return nil end
  local names = type(d.names) == "table" and d.names or {}
  local out = { x0 = tonumber(d.x0) or 0, z0 = tonumber(d.z0) or 0, cells = {}, colour = {}, known = 0 }
  -- (textures: tops, and sides - a log's bark, grass's dirt edge - 4 x 4 or 8 x 8 RGB)
  out.tiles, out.sides, out.sideColour = {}, {}, {}
  for i, nm in ipairs(names) do
    nm = tostring(nm)
    local c = type(d.colours) == "table" and tonumber(d.colours[i])
    if c then out.colour[nm] = c end
    local t = type(d.tiles) == "table" and d.tiles[i]
    if type(t) == "string" and (#t == 48 or #t == 192) then out.tiles[nm] = t end
    local s = type(d.sides) == "table" and d.sides[i]
    if type(s) == "string" and (#s == 48 or #s == 192) then
      out.sides[nm] = s
      local r, g, b, n = 0, 0, 0, #s / 3
      for p = 1, #s, 3 do
        local rr, gg, bb = s:byte(p, p + 2)
        r, g, b = r + rr, g + gg, b + bb
      end
      out.sideColour[nm] = math.floor(r / n) * 65536 + math.floor(g / n) * 256 + math.floor(b / n)
    end
  end
  local function name(i) return tostring(names[i] or "minecraft:stone") end
  -- (rb 9: each run also has its layers - the top block's thickness, the
  -- block under it and its thickness, the block most of the rest is)
  local rb = tonumber(d.rb) == 9 and 9 or 5
  -- one square's runs from s at p -> runs, next p (nil: broken)
  local function runsAt(s, p)
    local c = s:byte(p)
    if not c then return nil end
    p = p + 1
    local list = {}
    for r = 1, c do
      local a, b, e, f, g = s:byte(p, p + 4)
      if not g then return nil end
      local bot = e * 256 + f
      local run = { a * 256 + b - 2048, bot == 0 and -2048 or bot - 2048, name(g) }
      if rb == 9 then
        local t1, un, t2, dp = s:byte(p + 5, p + 8)
        if not dp then return nil end
        if t1 > 0 then
          run[4], run[5], run[6], run[7] = t1, un > 0 and name(un) or nil, t2, dp > 0 and name(dp) or nil
        end
      end
      p = p + rb
      list[r] = run
    end
    return list, p
  end
  out.names = names
  out.vox = d.vox == true                     -- (for the slices renderer: every column's runs, a grid)
  W.pieceSeq = (W.pieceSeq or 0) + 1
  out.id = W.pieceSeq                         -- (pictures are shaded by their neighbours: a new piece repaints them)
  if (d.kind == "quad" or d.kind == "quad2" or d.kind == "quad3" or d.kind == "quad4") and type(d.qs) == "string" then
    -- (quad2: a square over 1 block then has a picture of its top - 1 byte 0,
    -- or 1 and a block a pixel, rows north -> south; quad3: then its heights
    -- - 1 byte 0 = flat, or 1 and each column's top below the square's;
    -- quad4: squares in samples of `cell` blocks, pictures a texel every
    -- `tcell` blocks - a picture over 1 texel, heights over 1 sample)
    local samples, count = tonumber(d.size), tonumber(d.count)
    local cell, tcell = 1, 1
    if d.kind == "quad4" then cell, tcell = tonumber(d.cell) or 1, tonumber(d.tcell) or 1 end
    if not samples or not count or samples < 1 or cell < 1 or tcell < 1 or cell % tcell ~= 0 then return nil end
    out.size, out.cellStep, out.texCell = samples * cell, cell, tcell
    if out.size > 8192 then return nil end
    local per = cell / tcell
    local qs, p = d.qs, 1
    local parts = (d.kind == "quad3" or d.kind == "quad4") and { "tex", "hts" } or d.kind == "quad2" and { "tex" } or {}
    for _ = 1, count do
      local x1, x2, z1, z2, s1, s2 = qs:byte(p, p + 5)
      if not s2 then return nil end
      local list
      list, p = runsAt(qs, p + 6)
      if not list then return nil end
      local ss = s1 * 256 + s2
      -- i, j, s in blocks; ss samples a side, ts texels a side
      local c = { i = (x1 * 256 + x2) * cell, j = (z1 * 256 + z2) * cell, s = ss * cell, ss = ss, ts = ss * per, runs = list }
      for _, key in ipairs(parts) do
        local side = key == "tex" and c.ts or c.ss
        if side > 1 then
          local flag = qs:byte(p)
          if not flag then return nil end
          if flag == 1 then
            c[key] = qs:sub(p + 1, p + side * side)
            if #c[key] ~= side * side then return nil end
            p = p + side * side
          end
          p = p + 1
        end
      end
      out.cells[#out.cells + 1] = c
    end
    if p ~= #qs + 1 then return nil end
  else
    local n, cell = tonumber(d.n), tonumber(d.cell) or 1
    if not n or n < 1 or n > 256 then return nil end
    out.size, out.cellStep = n * cell, cell
    if type(d.rs) == "string" then
      local rs, p = d.rs, 1
      for k = 1, n * n do
        local list
        list, p = runsAt(rs, p)
        if not list then return nil end
        out.cells[k] = { i = math.floor((k - 1) / n) * cell, j = (k - 1) % n * cell, s = cell, runs = list }
      end
      if p ~= #rs + 1 then return nil end
    elseif type(d.hs) == "string" and type(d.bs) == "string" and #d.hs == 2 * n * n and #d.bs == n * n then
      for k = 1, n * n do
        local hi, lo = d.hs:byte(2 * k - 1, 2 * k)
        local v = hi * 256 + lo
        out.cells[k] = { i = math.floor((k - 1) / n) * cell, j = (k - 1) % n * cell, s = cell,
          runs = v > 0 and { { v - 2048, -2048, name(d.bs:byte(k)) } } or {} }
      end
    else
      return nil
    end
  end
  for _, c in ipairs(out.cells) do
    local list = c.runs
    if #list > 0 then
      local ground = list[#list][1]
      out.low = math.min(out.low or ground, ground)
      out.high = math.max(out.high or list[1][1], list[1][1])
      out.known = out.known + 1
    end
  end
  return out
end

-- The ground at a world spot from a piece (nil: not in it / nothing there)
function W.pieceTop(d, x, z)
  if not d then return nil end
  local i, j = math.floor(x - d.x0), math.floor(z - d.z0)
  for _, c in ipairs(d.cells) do
    if i >= c.i and i < c.i + c.s and j >= c.j and j < c.j + c.s and c.runs[1] then return c.runs[1][1], c.runs[1][3] end
  end
end

-- "minecraft:oak_stairs|facing=east,half=bottom" -> "minecraft:oak_stairs", { facing = "east", half = "bottom" }
function W.splitBlock(name)
  local id, st = tostring(name):match("^([^|]*)|?(.*)$")
  local states
  if st and st ~= "" then
    states = {}
    for k, v in st:gmatch("([%w_]+)=([%w_]+)") do states[k] = v:lower() end
  end
  return id, states, st or ""
end

-- Every block's top in a piece, a grid at the piece's finest step (a
-- square's picture heights where it has them, else its top all over), and
-- from it each block's light: lit from the north-west like Xaero's map (a
-- slope facing the light brighter, away darker) and darker beside taller
-- blocks (the ground at a wall's foot). -> light(i, j) (1 = as it is)
function W.lighting(d)
  if d.light then return d.light end
  local N = d.size
  local cellStep = d.cellStep or 1                     -- (grid / wide pieces: a height a cell / sample)
  local grid = {}
  for _, c in ipairs(d.cells) do
    local top = c.runs[1] and c.runs[1][1]
    if top then
      local ss = c.ss or math.max(1, math.floor(c.s / cellStep))      -- (samples a side)
      for sj = 0, ss - 1 do
        for si = 0, ss - 1 do
          local y = top
          if c.hts then
            local h = c.hts:byte(sj * ss + si + 1)
            y = h ~= 255 and top - h or nil
          end
          grid[(c.i + si * cellStep) * N + (c.j + sj * cellStep)] = y
        end
      end
    end
  end
  local function at(i, j) return grid[i * N + j] end
  local cache = {}
  d.light = function(i, j)
    i, j = i - i % cellStep, j - j % cellStep          -- (a block -> its sample)
    local k = i * N + j
    local f = cache[k]
    if f then return f end
    local h = at(i, j)
    if not h then
      f = 1
    else
      local s = cellStep
      local hn, hw = at(i, j - s) or h, at(i - s, j) or h
      local slope = ((h - hn) + (h - hw)) / s
      f = 1 + clamp(slope * 0.12, -0.35, 0.3)
      local occ = 0
      for di = -s, s, s do
        for dj = -s, s, s do
          local nh = (di ~= 0 or dj ~= 0) and at(i + di, j + dj)
          if nh and nh > h then occ = occ + math.min((nh - h) / s, 4) end
        end
      end
      f = f * (1 - math.min(0.4, occ * 0.035))
    end
    cache[k] = f
    return f
  end
  return d.light
end

local function shade(rgb, f)
  if f == 1 then return rgb end
  local r, g, b = math.floor(rgb / 65536) % 256, math.floor(rgb / 256) % 256, rgb % 256
  return clamp(math.floor(r * f), 0, 255) * 65536 + clamp(math.floor(g * f), 0, 255) * 256 + clamp(math.floor(b * f), 0, 255)
end
W.shade = shade

-- What a column's top is drawn as: the block itself (real textures), but
-- fluids have no block model (they draw nothing): stand-ins
W.CAP_SWAP = { { "water", "minecraft:light_blue_concrete" }, { "bubble_column", "minecraft:light_blue_concrete" },
  { "lava", "minecraft:magma_block" } }
W.UNDER = { { "grass_block", 0x6B4C2E }, { "podzol", 0x6B4C2E }, { "mycelium", 0x6B4C2E }, { "dirt_path", 0x6B4C2E },
  { "snow", 0x707070 } }
local capCache, bodyCache = {}, {}

function W.capBlock(name)
  local n = tostring(name)
  local c = capCache[n]
  if c then return c end
  c = n:find(":", 1, true) and n or "minecraft:stone"
  for _, s in ipairs(W.CAP_SWAP) do
    if n:find(s[1], 1, true) then c = s[2] break end
  end
  capCache[n] = c
  return c
end

local function darker(c, f)
  local r, g, b = math.floor(c / 65536) % 256, math.floor(c / 256) % 256, c % 256
  return math.floor(r * f) * 65536 + math.floor(g * f) * 256 + math.floor(b * f)
end

-- The column under the top: what is usually under it (grass stands on dirt),
-- else the top's colour (`real`: from its texture, the map computer's), darker
function W.bodyColour(name, real)
  local n = tostring(name)
  local c = bodyCache[n]
  if c then return c end
  for _, u in ipairs(W.UNDER) do
    if n:find(u[1], 1, true) then c = u[2] break end
  end
  c = c or darker(real or H.blockColour(n), 0.7)
  bodyCache[n] = c
  return c
end

-- A run's sides between y lo and hi (blocks) in layers, top first: its top
-- block's layer, the block under that, then the rest - each in its own
-- colour, darker than a top (a box is lit the same all over). A run with no
-- layers known (a scan, the height maps): one colour, as before.
-- -> { { lo, hi, colour }, ... }
function W.bands(r, lo, hi, colours, sides)
  local out = {}
  if hi - lo <= 0.02 then return out end
  -- (a block's side colour where known - a log's bark, grass's dirt edge - else its colour)
  local function col(n, f)
    return darker((sides and sides[n]) or (colours and colours[n]) or H.blockColour(W.splitBlock(n)), f)
  end
  local top = sides and sides[r[3]] and darker(sides[r[3]], 0.85) or W.bodyColour(r[3], colours and colours[r[3]])
  local layers
  if r[4] then
    local y1 = r[1] + 1 - r[4]                 -- (the top block's layer starts here)
    local y2 = y1 - (r[6] or 0)                -- (the next one's)
    layers = { { y1, r[1] + 1, top } }
    if r[5] then layers[#layers + 1] = { y2, y1, col(r[5], 0.8) } end
    layers[#layers + 1] = { -1e9, r[5] and y2 or y1, r[7] and col(r[7], 0.75) or r[5] and col(r[5], 0.75) or top }
  else
    layers = { { -1e9, 1e9, top } }
  end
  for _, L in ipairs(layers) do
    local a, b = math.max(L[1], lo), math.min(L[2], hi)
    if b - a > 0.02 then
      local last = out[#out]
      if last and last.colour == L[3] and math.abs(last.lo - b) < 1e-6 then
        last.lo = a
      else
        out[#out + 1] = { lo = a, hi = b, colour = L[3] }
      end
    end
  end
  return out
end

---------------------------------------------------------------- 3D models
-- The map piece's squares (one block, or many where the ground is all
-- alike); each solid run in a square (the ground, a floating island, a
-- bridge) is a top on a plain darker body (a Box): a small square's top is
-- the block itself (a Block object, real textures), a big one's a box in the
-- block's colour (a texture stretched over many blocks looks wrong). Drawn a
-- few hundred objects a frame. Used by the table (in the world) and the
-- menu's 3D view (fixed to the camera)

local Model = {}
Model.__index = Model
W.Model = Model
W.TEXTURED_VIEW = 32    -- single blocks show real textures in views up to this many blocks across
W.MAX_PPB = 8           -- pictures: at most this many pixels a block a side (the textures are 8 x 8)
-- pixels a block for want (1, 2, 4 or 8: the textures shrink evenly)
function W.ppbFor(want)
  for _, n in ipairs({ 8, 4, 2 }) do
    if n <= W.MAX_PPB and want >= n then return n end
  end
  return 1
end
W.LAY_FLAT = W.rotX(-90) -- a picture (upright in its own x, y) laid face up, its top edge north

-- opts: size (across), relative (camera-locked), glide (ticks), heightLimit
-- (tallest, x size), maxObjects, plate (colour of a plate under it)
function W.newModel(opts)
  return setmetatable({ size = opts.size or 1, relative = opts.relative, glide = opts.glide,
    heightLimit = opts.heightLimit or 1, maxObjects = opts.maxObjects or 4000, lift = 0, plateColour = opts.plate,
    cols = {}, cursor = 1, want = false, extra = 0 }, Model)
end

-- True to scale: a block up is as tall as a block across. The heights shown
-- start at the lowest ground's top block (+ lift: it shows 1 block thick)
-- and go up heightLimit x the width; runs above are cut there. Too many
-- objects: one top a run, stretched (no bodies), then only a square's
-- ground and highest run
function Model:layout()
  local d = self.data
  if not d then return end
  local u = self.size / d.size                    -- one block, in model units
  local floor = (d.low or 0) + (self.lift or 0)
  local ceil = floor + self.heightLimit * self.size / u
  self.u, self.floor, self.ceil = u, floor, ceil
  -- pictures: about the detail level's pixels across the view - a texel a
  -- block (or every few blocks wide), close up the blocks' textures (4 x 4
  -- or 2 x 2 pixels a block)
  local want = W.detail().px / d.size
  self.ppb = (d.texCell or 1) > 1 and 1 or W.ppbFor(want)
  local light = W.lighting(d)
  local shape, objects, runs, cut, layered = {}, 0, 0, false, 0
  for k, c in ipairs(d.cells) do
    local sh = false
    if #c.runs > 0 then
      sh = {}
      for n, r in ipairs(c.runs) do
        local b, t = math.max(r[2], floor), math.min(r[1] + 1, ceil)
        if r[1] + 1 > ceil then cut = true end
        if t > b then
          local hb = (t - b) * u
          local cap = math.min(hb, u)              -- (the top block: one block thick)
          local colour = d.colour[r[3]] or H.blockColour(W.splitBlock(r[3]))
          -- (a single block's top shaded by the light there)
          if n == 1 and c.s == 1 then colour = shade(colour, light(c.i, c.j)) end
          -- the top run of a square over one block: a picture of its top (shaded) is its top
          local pic = n == 1 and c.s > 1 and r[1] + 1 <= ceil or false
          -- its sides in layers (grass over dirt over stone, leaves over a log)
          local bands = W.bands(r, b, pic and t or t - 1, d.colour, d.sideColour)
          for _, bd in ipairs(bands) do bd.y0, bd.h = (bd.lo - floor) * u, (bd.hi - bd.lo) * u end
          sh[#sh + 1] = { y0 = (b - floor) * u, hb = hb, cap = pic and 0 or cap, block = r[3],
            colour = colour, bands = bands, pic = pic, top = r[1], single = c.s == 1 }
          objects = objects + 1 + #bands
          layered = layered + math.max(0, #bands - 1)
          runs = runs + 1
        end
      end
      if #sh == 0 then sh = false end
    end
    shape[k] = sh
  end
  -- real block shapes (stairs, slabs, fences - and their real textures) for
  -- single blocks: close up always; up to 128 across while there are boxes
  -- to spare (a quarter of the budget left): a real block costs the box its
  -- plain top would, but takes more to draw
  self.realShapes = (d.cellStep or 1) == 1
    and (d.size <= W.TEXTURED_VIEW or (d.size <= 128 and objects <= self.maxObjects * 0.75))
  for _, sh in pairs(shape) do
    if sh then
      for _, run in ipairs(sh) do run.textured = run.single and self.realShapes end
    end
  end
  -- too many objects for every layer: one side colour a run (its biggest layer's)
  if objects > self.maxObjects and layered > 0 then
    for _, sh in pairs(shape) do
      if sh then
        for _, run in ipairs(sh) do
          if #run.bands > 1 then
            local big = run.bands[1]
            for _, bd in ipairs(run.bands) do if bd.h > big.h then big = bd end end
            run.bands = { { y0 = run.bands[#run.bands].y0, h = run.bands[1].y0 + run.bands[1].h - run.bands[#run.bands].y0,
              colour = big.colour } }
          end
        end
      end
    end
    objects = objects - layered
  end
  self.single = objects > self.maxObjects
  if self.single and runs > self.maxObjects then
    for k = 1, #d.cells do
      local sh = shape[k]
      if sh and #sh > 2 then shape[k] = { sh[1], sh[#sh] } end
    end
  end
  self.shape, self.cut, self.cursor, self.objects = shape, cut, 1, objects
end

function Model:setData(d)
  if not d then return end
  -- (squares the new piece does not have are hidden on the next pass)
  self.extra = math.max(self.extra or 0, self.data and #self.data.cells or 0)
  self.data = d
  self:layout()
end

function Model:setSize(size)
  if math.abs(size - self.size) > 1e-6 then
    self.size = size
    self:layout()
  end
end

-- Move the heights shown up / down (blocks)
function Model:setLift(lift)
  lift = tonumber(lift) or 0
  if lift ~= self.lift then
    self.lift = lift
    self:layout()
  end
end

-- Where it is: centre + map -> world (or camera) turn. Small changes are ignored
function Model:setFrame(origin, m)
  local o = self.origin
  if o and self.m then
    local moved = math.abs(o[1] - origin[1]) + math.abs(o[2] - origin[2]) + math.abs(o[3] - origin[3])
    local turned = 0
    for r = 1, 3 do
      for c = 1, 3 do turned = turned + math.abs(self.m[r][c] - m[r][c]) end
    end
    if moved < 0.004 and turned < 1e-4 then return false end
  end
  self.origin, self.m = { origin[1], origin[2], origin[3] }, m
  local a, b, c = W.euler(m)
  self.rot = { a, b, c }
  a, b, c = W.euler(W.mul(m, W.LAY_FLAT))
  self.flatRot = { a, b, c }
  self.cursor = 1
  return true
end

function Model:setVisible(on)
  on = on and true or false
  if on ~= self.want then
    self.want = on
    self.cursor = 1
  end
end

W.MAX_BANDS = 3          -- side layers a run (its top block's, the next, the rest)

local function hideSlot(sl)
  if sl.cap then sl.cap:show(false) end
  if sl.capBox then sl.capBox:show(false) end
  if sl.body then sl.body:show(false) end
  if sl.body2 then sl.body2:show(false) end
  if sl.body3 then sl.body3:show(false) end
  if sl.pic then sl.pic:show(false) end
end

-- Hide every column now (a model being replaced)
function Model:clear()
  for _, slots in pairs(self.cols) do
    for _, sl in ipairs(slots) do hideSlot(sl) end
  end
  self.cols, self.cursor = {}, 1
end

function Model:point(x, y, z)
  local p = W.apply(self.m, { x, y, z })
  return self.origin[1] + p[1], self.origin[2] + p[2], self.origin[3] + p[3]
end

local function glideObj(o, n)
  if not o or not n then return end
  for _, f in ipairs({ "setXLerpSteps", "setYLerpSteps", "setZLerpSteps" }) do
    if o.o[f] then pcall(o.o[f], n) end
  end
end

-- The glasses ease every change of these over 2 ticks unless told not to
-- (Advanced Peripherals' default): a new object would ease out from where a
-- new one starts (the camera, on a camera-fixed map) and a turn eases each
-- angle on its own (a slice swings wildly while the view turns)
local EASED = { x = "X", y = "Y", z = "Z", rotX = "RotX", rotY = "RotY", rotZ = "RotZ", sizeX = "SizeX", sizeY = "SizeY",
  sizeZ = "SizeZ", opacity = "Opacity", fontSize = "FontSize" }

-- A model's object: made hidden with no eased values, its easing off, then
-- put where it goes and shown - it appears in place. Afterwards nothing eases
-- but a gliding model's moves (the table, following the ship)
function Model:make(kind, props, rot)
  rot = rot or self.rot
  props.rotY, props.rotX, props.rotZ = rot[1], rot[2], rot[3]
  if self.relative then props.relativePosition, props.relativeRotation = true, true end
  local base, later = {}, {}
  for k, v in pairs(props) do
    if EASED[k] then later[k] = v else base[k] = v end
  end
  local shown = base.enabled ~= false
  base.enabled = false
  local o = H.make(kind, base)
  if not o then return nil end
  if self.relative then
    if o.o.setRelativePosition then pcall(o.o.setRelativePosition, true) end
    if o.o.setRelativeRotation then pcall(o.o.setRelativeRotation, true) end
  end
  for _, f in pairs(EASED) do
    local set = o.o["set" .. f .. "LerpSteps"]
    if set then pcall(set, 0) end
  end
  for k, v in pairs(later) do o:set(EASED[k], v) end
  glideObj(o, self.glide)
  if shown then o:show(true) end
  return o
end

-- Put one object where it goes (made if it does not exist yet); rot: its
-- own turn (a picture lies flat), else the model's
function Model:place(c, key, kind, x, y, z, sx, sy, sz, look, rot)
  rot = rot or self.rot
  local o = c[key]
  if not o then
    local props = { x = x, y = y, z = z, sizeX = sx, sizeY = sy, sizeZ = sz }
    for k, v in pairs(look) do props[k] = v end
    o = self:make(kind, props, rot)
    c[key] = o
    if not o then return end
    for k, v in pairs(props) do o.v[k] = v end
    return o
  end
  o:pos(x, y, z)
  o:set("RotY", rot[1]) o:set("RotX", rot[2]) o:set("RotZ", rot[3])
  o:set("SizeX", sx) o:set("SizeY", sy)
  if sz then o:set("SizeZ", sz) end
  for k, v in pairs(look) do o:set(k:sub(1, 1):upper() .. k:sub(2), v) end
  o:show(true)
  return o
end

-- Take an overlay object away (hidden first, in case the glasses cannot)
function W.removeObj(o)
  if not o then return end
  o:show(false)
  if H.ov and H.ov.removeObject and o.o.getId then
    local ok, id = pcall(o.o.getId)
    if ok and id then pcall(H.ov.removeObject, id) end
  end
end

local function argb(rgb) return rgb + 0xFF000000 - 2 ^ 32 end   -- (opaque, as signed 32-bit ARGB)

-- A block's look at ppb x ppb pixels (RGB): its texture shrunk (tiles.txt,
-- 8 x 8 or 4 x 4) where the map computer has it, else its colour. side: its
-- side's texture (a log's bark, grass's dirt edge) where there is one
function Model:tilePixels(name, ppb, side)
  local d = self.data
  d.tileCache = d.tileCache or {}
  local key = tostring(name) .. (side and "s" or "t") .. ppb
  local px = d.tileCache[key]
  if px then return px end
  px = {}
  local t = name and ((side and d.sides and d.sides[name]) or (d.tiles and d.tiles[name]))
  if t and ppb > 1 then
    local T = #t == 192 and 8 or 4                    -- (the tile's pixels a side)
    for ty = 0, ppb - 1 do
      for tx = 0, ppb - 1 do
        -- (the tile's pixels under this one: several averaged, or the one it falls in)
        local y0 = math.floor(ty * T / ppb)
        local y1 = math.max(y0, math.floor((ty + 1) * T / ppb) - 1)
        local x0 = math.floor(tx * T / ppb)
        local x1 = math.max(x0, math.floor((tx + 1) * T / ppb) - 1)
        local r, g, b, n = 0, 0, 0, 0
        for sy = y0, y1 do
          for sx = x0, x1 do
            local p = 3 * (sy * T + sx) + 1
            local rr, gg, bb = t:byte(p, p + 2)
            r, g, b, n = r + rr, g + gg, b + bb, n + 1
          end
        end
        px[#px + 1] = math.floor(r / n) * 65536 + math.floor(g / n) * 256 + math.floor(b / n)
      end
    end
  else
    local c = name and ((side and d.sideColour and d.sideColour[name]) or d.colour[name]
      or H.blockColour(W.splitBlock(name))) or 0x101418
    for k = 1, ppb * ppb do px[k] = c end
  end
  d.tileCache[key] = px
  return px
end

-- A square's picture: its blocks as seen from above - ppb x ppb pixels a
-- block (their textures close up), each shaded by the light on it (slopes,
-- the foot of walls), rows north -> south, laid flat on top.
-- A picture is never resized: the glasses' mod crashes the game when a
-- texture changes size with new pixels still waiting to be sent - a picture
-- of another size is a new one
function Model:picture(sl, c, x, y, z, w)
  local d = self.data
  local s = c.ts or c.s                                          -- (texels a side)
  local tcell = d.texCell or 1                                   -- (blocks a texel)
  local ppb = self.ppb or 1                                      -- (pixels a texel)
  if s * ppb > 256 then ppb = math.max(1, math.floor(256 / s)) end
  local px = s * ppb
  if sl.pic and sl.pic.v.width ~= px then
    W.removeObj(sl.pic)
    sl.pic = nil
  end
  local o = self:place(sl, "pic", "Texture", x, y, z, w, w, nil, { width = px, height = px, culling = false }, self.flatRot)
  local sig = d.id .. "|" .. c.i .. "," .. c.j .. "|" .. ppb
  if not o or o.v.picture == sig then return end
  o.v.picture = sig
  local light, flat = W.lighting(d), {}
  local only = not c.tex and c.runs[1] and c.runs[1][3]          -- (one block all over)
  for bj = 0, s - 1 do
    for bi = 0, s - 1 do
      local tp = self:tilePixels(only or d.names[c.tex:byte(bj * s + bi + 1)], ppb)
      local f = light(c.i + bi * tcell, c.j + bj * tcell)
      local k = 1
      for ty = 0, ppb - 1 do
        local row = (bj * ppb + ty) * px + bi * ppb
        for tx = 1, ppb do
          flat[row + tx] = argb(shade(tp[k], f))
          k = k + 1
        end
      end
    end
  end
  local ok, err = pcall(o.o.setPixels, 1, 1, px, px, flat)
  if not ok then H.log("war table picture: " .. tostring(err)) end
end

-- A single block drawn as itself: its model (stairs, slab, fence), its
-- textures, turned as in the world (its state, kept by tools/dhruns.py)
function Model:realBlock(sl, run, x, y, z, w, capH)
  local id, states, st = W.splitBlock(run.block)
  local o = self:place(sl, "cap", "Block", x, y, z, w, capH, w, { block = W.capBlock(id) })
  if o and o.v.states ~= st then
    o.v.states = st
    if states and o.o.setStates then pcall(o.o.setStates, states) end
  end
end

-- One square: a slot (top + body) a run; slots left over are hidden
function Model:column(k)
  local slots = self.cols[k]
  local c = self.data.cells[k]
  local sh = c and self.shape and self.shape[k]
  local show = self.want and sh and self.origin and true or false
  if not show then
    if slots then
      for _, sl in ipairs(slots) do hideSlot(sl) end
      return #slots > 0 and #slots or 0
    end
    return 0
  end
  if not slots then
    slots = {}
    self.cols[k] = slots
  end
  local u, half = self.u, self.data.size / 2
  local px, pz = (c.i + c.s / 2 - half) * u, (c.j + c.s / 2 - half) * u
  local w = c.s * u * 0.998
  local used = 0
  for r, run in ipairs(sh) do
    local sl = slots[r]
    if not sl then
      sl = {}
      slots[r] = sl
    end
    local capH = (self.single and not run.pic) and run.hb or run.cap
    local x, y, z
    if run.pic then
      -- the picture on top: laid flat, its corner (a picture's origin) at the square's south-west
      x, y, z = self:point(px - c.s * u / 2, run.y0 + run.hb + u * 0.02, pz + c.s * u / 2)
      self:picture(sl, c, x, y, z, w)
      if sl.cap then sl.cap:show(false) end
      if sl.capBox then sl.capBox:show(false) end
      used = used + 1
    else
      x, y, z = self:point(px, run.y0 + run.hb - capH / 2, pz)
      if run.textured then
        self:realBlock(sl, run, x, y, z, w, capH)
        if sl.capBox then sl.capBox:show(false) end
      else
        self:place(sl, "capBox", "Box", x, y, z, w, capH, w, { color = run.colour })
        if sl.cap then sl.cap:show(false) end
      end
      if sl.pic then sl.pic:show(false) end
    end
    -- its sides: a box a layer (none when the whole run is drawn as its top)
    local bands = (self.single and not run.pic) and {} or run.bands
    for n = 1, W.MAX_BANDS do
      local bd, key = bands[n], n == 1 and "body" or "body" .. n
      if bd then
        x, y, z = self:point(px, bd.y0 + bd.h / 2, pz)
        self:place(sl, key, "Box", x, y, z, w, bd.h, w, { color = bd.colour })
        used = used + 1
      elseif sl[key] then
        sl[key]:show(false)
      end
    end
    used = used + 1
  end
  for r = #sh + 1, #slots do hideSlot(slots[r]) end
  return math.max(1, used)
end

-- The plate the model stands on (the menu's 3D view)
function Model:placePlate()
  if not self.plateColour then return end
  local pl = self.plate or {}
  self.plate = pl
  if self.want and self.origin then
    local x, y, z = self:point(0, -0.01 * self.size, 0)
    self:place(pl, "box", "Box", x, y, z, self.size * 1.04, 0.02 * self.size, self.size * 1.04,
      { color = self.plateColour, opacity = 0.9 })
  elseif pl.box then
    pl.box:show(false)
  end
end

-- Work through the squares: at most `budget` objects; -> objects used
function Model:step(budget)
  if not self.data then return 0 end
  local total = math.max(#self.data.cells, self.extra or 0)
  local used = 0
  if self.cursor == 1 and total > 0 then self:placePlate() end
  while used < budget and self.cursor <= total do
    used = used + self:column(self.cursor)
    self.cursor = self.cursor + 1
  end
  if self.cursor > total then self.extra = #self.data.cells end
  return used
end

function Model:busy()
  return self.data ~= nil and self.cursor <= math.max(#self.data.cells, self.extra or 0)
end

-- An icon or a word that faces whoever looks: fixed to the camera it just
-- stands upright (it faces the eye already); on the table it is turned to
-- the wearer's eye each time
function Model:facing(sl, key, kind, x, y, z, s, look)
  if self.relative then
    -- (a picture's origin is its corner: half its size back; words are centred)
    local ox = kind == "Texture" and s / 2 or 0
    local o = self:place(sl, key, kind, x - ox, y - (kind == "Texture" and s / 2 or 0), z, s, s, nil, look, { 0, 0, 0 })
    return o
  end
  local o = self:place(sl, key, kind, x, y, z, s, s, nil, look)
  if o and kind == "Texture" then H.placeIcon(o, x, y, z, s) elseif o then H.face(o, x, y, z) end
  return o
end

-- The field on the model (W.pins): a cube in their colour for helldivers,
-- hostiles, friendlies, ships...; a beam with the stratagem's icon on top for
-- a stratagem; names over helldivers, the destroyer, stratagems and the target
function Model:drawPins(pins)
  self.pinSlots = self.pinSlots or {}
  local used = 0
  local d = self.data
  if d and self.origin and self.want and self.floor then
    local u, half, size = self.u, d.size / 2, self.size
    for _, p in ipairs(pins) do
      local ix, iz = p.x - d.x0, p.z - d.z0
      if ix >= 0 and iz >= 0 and ix < d.size and iz < d.size then
        used = used + 1
        local sl = self.pinSlots[used] or {}
        self.pinSlots[used] = sl
        local px, pz = (ix - half) * u, (iz - half) * u
        local py = clamp((p.y - self.floor) * u, 0, self.heightLimit * size)
        if p.kind == "beacon" or p.kind == "target" then
          local hgt = size * 0.25
          local x, y, z = self:point(px, py + hgt / 2, pz)
          self:place(sl, "beam", "Box", x, y, z, size * 0.004, hgt, size * 0.004, { color = p.colour, opacity = 0.85 })
          if sl.cube then sl.cube:show(false) end
          W.hideShip(sl)
          local top = py + hgt + size * 0.04
          x, y, z = self:point(px, top, pz)
          if p.icon then
            local o = self:facing(sl, "icon", "Texture", x, y, z, size * 0.07, { culling = false })
            if o then o:icon(p.icon) end
          elseif sl.icon then
            sl.icon:show(false)
          end
          x, y, z = self:point(px, top + size * 0.055, pz)
          local o = self:facing(sl, "text", "Text", x, y, z, size * 0.0025, { content = p.label or "", color = p.colour,
            center = true, shadow = true })
          if o then o:set("FontSize", size * 0.0025) o:set("Content", p.label or "") o:set("Color", p.colour) end
        elseif p.ship and p.ship.length <= d.size * W.SHIP_FITS then
          -- the destroyer: its outline from above (hud.cfg war.ship's size x
          -- its scale), turned with it, given depth like a token: copies of the
          -- picture stacked through its thickness, the outer two its faces, the
          -- ones between darker (its sides)
          for _, lay in ipairs(sl.layers or {}) do if lay.o then lay.o:show(false) end end
          if sl.cube then sl.cube:show(false) end
          if sl.beam then sl.beam:show(false) end
          if sl.icon then sl.icon:show(false) end
          if sl.ship then sl.ship:show(false) end                 -- (an older one-picture outline)
          local sp = p.ship
          local fx, fz = sp.fx, sp.fz
          local rx, rz = -fz, fx
          local len, wid = sp.length * u, sp.width * u
          local y0 = py + u * 0.05
          -- (the ship's turn on the map: its right, up and astern as the box's x, y, z)
          local Rm = { { -fz, 0, -fx }, { 0, 1, 0 }, { fx, 0, -fz } }
          local top
          local sm = W.shipModel()
          if sm then
            -- its real shape (icons/ship_model.txt): solid boxes, lighter higher up
            for _, lay in ipairs(sl.shipLayers or {}) do if lay.o then lay.o:show(false) end end
            local kk = len / sm.length                           -- (model units a ship block)
            local a, b, c = W.euler(W.mul(self.m, Rm))
            sl.shipBoxes = sl.shipBoxes or {}
            for i, bx in ipairs(sm.boxes) do
              local rc, uc, fc = (bx[1] + bx[4]) / 2, (bx[2] + bx[5]) / 2, (bx[3] + bx[6]) / 2
              local x, y, z = self:point(px + (-fz * rc + fx * fc) * kk, y0 + (uc + sm.height / 2) * kk, pz + (fx * rc + fz * fc) * kk)
              local slot = sl.shipBoxes[i] or {}
              sl.shipBoxes[i] = slot
              self:place(slot, "o", "Box", x, y, z, (bx[4] - bx[1]) * kk, (bx[5] - bx[2]) * kk, (bx[6] - bx[3]) * kk,
                { color = bx[7] }, { a, b, c })
            end
            for i = #sm.boxes + 1, #sl.shipBoxes do
              if sl.shipBoxes[i].o then sl.shipBoxes[i].o:show(false) end
            end
            top = y0 + sm.height * kk
          else
            -- (no model file: its outline, stacked through a thickness)
            local thick = wid * W.SHIP_DEPTH
            -- (a picture's corner is its bottom left: the stern, port side)
            local cx, cz = px - (rx * wid + fx * len) / 2, pz - (rz * wid + fz * len) / 2
            local a, b, c = W.euler(W.mul(W.mul(self.m, Rm), W.LAY_FLAT))
            local pw, ph = W.iconSize("ent_destroyer")
            sl.shipLayers = sl.shipLayers or {}
            for n = 1, W.SHIP_LAYERS do
              local lay = sl.shipLayers[n] or {}
              sl.shipLayers[n] = lay
              local x, y, z = self:point(cx, y0 + thick * (n - 1) / (W.SHIP_LAYERS - 1), cz)
              local o = self:place(lay, "o", "Texture", x, y, z, wid, len, nil, { culling = false, width = pw, height = ph }, { a, b, c })
              local edge = n ~= 1 and n ~= W.SHIP_LAYERS
              if o then o:icon(edge and "ent_destroyer_edge" or "ent_destroyer") end
            end
            top = y0 + thick
          end
          local x, y, z = self:point(px, top + size * 0.03, pz)
          local t = self:facing(sl, "text", "Text", x, y, z, size * W.NAME_FONT, { content = p.label or "", color = p.colour,
            center = true, shadow = true })
          if t then t:set("FontSize", size * W.NAME_FONT) t:set("Content", p.label or "") t:set("Color", p.colour) end
        elseif p.ent then
          -- a helldiver / player / ship: its icon as a solid token, its tag / name over it
          W.hideShip(sl)
          local s = self:token(sl, p, px, py, pz)
          if sl.cube then sl.cube:show(false) end
          if sl.beam then sl.beam:show(false) end
          if sl.icon then sl.icon:show(false) end
          if p.label then
            local x, y, z = self:point(px, py + s + size * 0.02, pz)
            local o = self:facing(sl, "text", "Text", x, y, z, size * W.NAME_FONT, { content = p.label, color = p.colour,
              center = true, shadow = true })
            if o then o:set("FontSize", size * W.NAME_FONT) o:set("Content", p.label) o:set("Color", p.colour) end
          elseif sl.text then
            sl.text:show(false)
          end
        elseif p.kind == "shot" then
          -- a projectile: a tiny blip, no name
          for _, lay in ipairs(sl.layers or {}) do if lay.o then lay.o:show(false) end end
          W.hideShip(sl)
          if sl.beam then sl.beam:show(false) end
          if sl.icon then sl.icon:show(false) end
          if sl.text then sl.text:show(false) end
          local bl = math.max(u * 0.6, size * 0.005)
          local x, y, z = self:point(px, py + bl / 2, pz)
          self:place(sl, "cube", "Box", x, y, z, bl, bl, bl, { color = p.colour })
        else
          for _, lay in ipairs(sl.layers or {}) do if lay.o then lay.o:show(false) end end
          W.hideShip(sl)
          local cube = math.max(u * 1.2, size * 0.012)
          local x, y, z = self:point(px, py + cube / 2, pz)
          self:place(sl, "cube", "Box", x, y, z, cube, cube, cube, { color = p.colour })
          if sl.beam then sl.beam:show(false) end
          if sl.icon then sl.icon:show(false) end
          if p.label then
            x, y, z = self:point(px, py + cube + size * 0.03, pz)
            local o = self:facing(sl, "text", "Text", x, y, z, size * 0.0025, { content = p.label, color = p.colour,
              center = true, shadow = true })
            if o then o:set("FontSize", size * 0.0025) o:set("Content", p.label) o:set("Color", p.colour) end
          elseif sl.text then
            sl.text:show(false)
          end
        end
      end
    end
  end
  for i = used + 1, #self.pinSlots do
    local sl = self.pinSlots[i]
    for _, k in ipairs({ "cube", "beam", "icon", "text" }) do
      if sl[k] then sl[k]:show(false) end
    end
    for _, lay in ipairs(sl.layers or {}) do if lay.o then lay.o:show(false) end end
    W.hideShip(sl)
  end
end

-- The destroyer's outline is drawn while it is at most this many times the
-- map's width (a bigger one would stick out far past the map: a marker
-- instead); W.SHIP_LAYERS copies of it through a thickness of W.SHIP_DEPTH x its width
W.SHIP_FITS = 1.5
W.SHIP_LAYERS, W.SHIP_DEPTH = 4, 0.15

-- (a pin slot's destroyer outline hidden: its layers, and an older one-picture one)
function W.hideShip(sl)
  if sl.ship then sl.ship:show(false) end
  for _, lay in ipairs(sl.shipLayers or {}) do if lay.o then lay.o:show(false) end end
  for _, bx in ipairs(sl.shipBoxes or {}) do if bx.o then bx.o:show(false) end end
end

-- The destroyer's shape (icons/ship_model.txt, from its schematic by
-- tools/shipmodel.py): its size and solid boxes {r0, u0, f0, r1, u1, f1,
-- colour} in blocks from its middle - read once; nil: no file (the outline then)
function W.shipModel()
  if W.shipModelData ~= nil then return W.shipModelData or nil end
  W.shipModelData = false
  local path = fs.combine(H.FILES.icons, "ship_model.txt")
  local h = fs.exists(path) and fs.open(path, "r")
  if not h then return nil end
  local text = h.readAll()
  h.close()
  -- (and its guns and thrusters, for the status hologram: tools/shipmodel.py)
  local m = { boxes = {}, guns = {}, thrust = {} }
  for line in tostring(text):gmatch("[^\r\n]+") do
    local L, Wd, Ht = line:match("^SHIP (%S+) (%S+) (%S+)")
    local gs, gd, gr, gu, gf = line:match("^GUN (%S+) ([rludfb]) (%S+) (%S+) (%S+)$")
    local td, t0, t1, t2, t3, t4, t5 = line:match("^THRUST ([rludfb]) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+)$")
    if L then
      m.length, m.width, m.height = tonumber(L), tonumber(Wd), tonumber(Ht)
    elseif gs then
      if tonumber(gr) and tonumber(gu) and tonumber(gf) then
        m.guns[#m.guns + 1] = { sys = gs, dir = gd, r = tonumber(gr), u = tonumber(gu), f = tonumber(gf) }
      end
    elseif td then
      local b = { tonumber(t0), tonumber(t1), tonumber(t2), tonumber(t3), tonumber(t4), tonumber(t5) }
      if b[1] and b[2] and b[3] and b[4] and b[5] and b[6] then
        m.thrust[#m.thrust + 1] = { dir = td, box = b }
      end
    else
      local r0, u0, f0, r1, u1, f1, c = line:match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%x+)$")
      if r0 and tonumber(r0) and tonumber(f1) then
        m.boxes[#m.boxes + 1] = { tonumber(r0), tonumber(u0), tonumber(f0), tonumber(r1), tonumber(u1), tonumber(f1), tonumber(c, 16) }
      end
    end
  end
  if m.length and m.height and #m.boxes > 0 then W.shipModelData = m end
  return W.shipModelData or nil
end

-- An icon's picture size in pixels, from its PNG's header (16 x 16 if none)
W.iconSizes = {}
function W.iconSize(name)
  local s = W.iconSizes[name]
  if s then return s[1], s[2] end
  local d = H.iconData(name)
  local w, h = 16, 16
  if d and #d >= 24 and d:sub(2, 4) == "PNG" then
    local a, b, c, e = d:byte(17, 20)
    w = ((a * 256 + b) * 256 + c) * 256 + e
    a, b, c, e = d:byte(21, 24)
    h = ((a * 256 + b) * 256 + c) * 256 + e
  end
  W.iconSizes[name] = { w, h }
  return w, h
end

-- A token: the icon (icons/ent_<name>.png) given depth - W.TOKEN_LAYERS
-- copies through its thickness, the outer two its faces, the ones between
-- darker (its edge, seen from an angle). Stood on the spot, turned to the
-- eye and a little past it (so its depth shows). -> its height (model units)
W.TOKEN_LAYERS, W.TOKEN_SIZE, W.TOKEN_DEPTH, W.TOKEN_TURN = 5, 0.05, 0.25, 25
-- names over the icons: font (x the model's size) in 3D, text scale on the top-down map
W.NAME_FONT, W.NAME_SCALE = 0.0016, 0.5
function Model:token(sl, p, px, py, pz)
  local S = self.size * W.TOKEN_SIZE
  local D = S * W.TOKEN_DEPTH
  local eye = self.relative and { 0, 0, 0 } or (H.me and { H.me.x, H.me.y + (H.me.eyeHeight or 1.62), H.me.z }) or { 0, 0, 0 }
  local wx, wy, wz = self:point(px, py, pz)
  local v, M = { eye[1] - wx, eye[2] - wy, eye[3] - wz }, self.m
  local dx = M[1][1] * v[1] + M[2][1] * v[2] + M[3][1] * v[3]
  local dz = M[1][3] * v[1] + M[2][3] * v[2] + M[3][3] * v[3]
  local R = W.rotY(math.deg(atan2(dx, dz)) + W.TOKEN_TURN)
  local a, b, c = W.euler(W.mul(M, R))
  local rot = { a, b, c }
  sl.layers = sl.layers or {}
  for n = 1, W.TOKEN_LAYERS do
    local depth = -D / 2 + D * (n - 1) / (W.TOKEN_LAYERS - 1)
    local off = W.apply(R, { -S / 2, 0, depth })               -- (a picture's origin: its bottom-left)
    local x, y, z = self:point(px + off[1], py + off[2], pz + off[3])
    local lay = sl.layers[n] or {}
    sl.layers[n] = lay
    local o = self:place(lay, "o", "Texture", x, y, z, S, S, nil, { culling = false }, rot)
    local edge = n ~= 1 and n ~= W.TOKEN_LAYERS
    if o then o:icon("ent_" .. p.ent .. (edge and "_edge" or "")) end
  end
  return S
end

-- (a ray against a box: the distance along it where it enters, nil = misses)
local function rayBox(o, d, lo, hi)
  local tmin, tmax = 0, math.huge
  for a = 1, 3 do
    if math.abs(d[a]) < 1e-12 then
      if o[a] < lo[a] or o[a] > hi[a] then return nil end
    else
      local t1, t2 = (lo[a] - o[a]) / d[a], (hi[a] - o[a]) / d[a]
      if t1 > t2 then t1, t2 = t2, t1 end
      tmin, tmax = math.max(tmin, t1), math.min(tmax, t2)
      if tmin > tmax then return nil end
    end
  end
  return tmin
end

-- The block under a GUI spot on a camera-fixed model (the menu's 3D view):
-- a ray from the eye through it (the FOV of hud.cfg), into the model ->
-- world x, z and that run's top y (nil: nothing there)
function Model:pick(gx, gy)
  local d = self.data
  if not (d and self.origin and self.shape and self.relative) then return nil end
  local L = H.L
  local tn = math.tan(math.rad(H.cfg.fov / 2))
  local dir = { (gx - L.w / 2) / (L.h / 2) * tn, -(gy - L.h / 2) / (L.h / 2) * tn, -1 }
  local M, o = self.m, self.origin
  local function toModel(v)                           -- (the model's turn back: its transpose)
    return { M[1][1] * v[1] + M[2][1] * v[2] + M[3][1] * v[3], M[1][2] * v[1] + M[2][2] * v[2] + M[3][2] * v[3],
      M[1][3] * v[1] + M[2][3] * v[2] + M[3][3] * v[3] }
  end
  return self:castRay(toModel({ -o[1], -o[2], -o[3] }), toModel(dir))
end

-- A ray in the world (an eye and a look direction) into this model (the
-- table's hologram) -> world x, z and that run's top y (nil: misses it)
function Model:pickWorld(eye, dir)
  if not (self.data and self.origin and self.shape and self.m) then return nil end
  local M, o = self.m, self.origin
  local function toModel(v)
    return { M[1][1] * v[1] + M[2][1] * v[2] + M[3][1] * v[3], M[1][2] * v[1] + M[2][2] * v[2] + M[3][2] * v[3],
      M[1][3] * v[1] + M[2][3] * v[2] + M[3][3] * v[3] }
  end
  return self:castRay(toModel({ eye[1] - o[1], eye[2] - o[2], eye[3] - o[3] }), toModel(dir))
end

-- (the columns in squares of W.RAY_GROUP a side, each square's bounds - the
-- very numbers of its runs' boxes: a ray that misses a square, or meets it
-- further on than a hit already found, cannot hit anything in it. Made once
-- a shape)
W.RAY_GROUP = 16
function Model:rayGroups()
  local g = self.rayG
  local d = self.data
  if g and g.shape == self.shape and g.data == d and g.u == self.u then return g end
  local u, half = self.u, d.size / 2
  g = { shape = self.shape, data = d, u = u, keys = {}, cells = {}, lo = {}, hi = {} }
  local floor, R = math.floor, W.RAY_GROUP
  for k, c in ipairs(d.cells) do
    local sh = self.shape[k]
    if sh and #sh > 0 then
      local key = floor(c.i / R) * 65536 + floor(c.j / R)
      local lo, hi = g.lo[key], g.hi[key]
      if not lo then
        lo, hi = { math.huge, math.huge, math.huge }, { -math.huge, -math.huge, -math.huge }
        g.lo[key], g.hi[key], g.cells[key] = lo, hi, {}
        g.keys[#g.keys + 1] = key
      end
      local list = g.cells[key]
      list[#list + 1] = k
      local x1, z1 = (c.i - half) * u, (c.j - half) * u
      local x2, z2 = x1 + c.s * u, z1 + c.s * u
      for _, run in ipairs(sh) do
        local y1, y2 = run.y0, run.y0 + run.hb
        if x1 < lo[1] then lo[1] = x1 end
        if y1 < lo[2] then lo[2] = y1 end
        if z1 < lo[3] then lo[3] = z1 end
        if x2 > hi[1] then hi[1] = x2 end
        if y2 > hi[2] then hi[2] = y2 end
        if z2 > hi[3] then hi[3] = z2 end
      end
    end
  end
  self.rayG = g
  return g
end

-- (a ray in the model's own space - from ro, along rd - against its runs)
function Model:castRay(ro, rd)
  local d = self.data
  local u, half = self.u, d.size / 2
  local best, bk, bt
  local g = self:rayGroups()
  -- the squares the ray passes through, nearest first
  local hit = {}
  for _, key in ipairs(g.keys) do
    local te = rayBox(ro, rd, g.lo[key], g.hi[key])
    if te then hit[#hit + 1] = { te, key } end
  end
  table.sort(hit, function(a, b) return a[1] < b[1] end)
  local lo, hi = {}, {}                               -- (one box at a time: no new tables a box)
  local cells, shape = d.cells, self.shape
  for _, h in ipairs(hit) do
    if best and h[1] > best then break end            -- (every square left starts further on)
    for _, k in ipairs(g.cells[h[2]]) do
      local c = cells[k]
      local x1, z1 = (c.i - half) * u, (c.j - half) * u
      lo[1], lo[3], hi[1], hi[3] = x1, z1, x1 + c.s * u, z1 + c.s * u
      for _, run in ipairs(shape[k]) do
        lo[2], hi[2] = run.y0, run.y0 + run.hb
        local t = rayBox(ro, rd, lo, hi)
        -- (the nearest; at the same distance the first column, as when every column was looked at in turn)
        if t and (not best or t < best or (t == best and k < bk)) then best, bk, bt = t, k, run.top end
      end
    end
  end
  if not best then return nil end
  local c = d.cells[bk]
  local bx = clamp(math.floor((ro[1] + rd[1] * best) / u + half), c.i, c.i + c.s - 1)
  local bz = clamp(math.floor((ro[3] + rd[3] * best) / u + half), c.j, c.j + c.s - 1)
  return d.x0 + bx, d.z0 + bz, bt
end

---------------------------------------------------------------- slices (every block, not just tops)
-- The ground as see-through slices: a picture a block level (air left
-- clear, so it shows what is under it), stacked up - every block a column
-- has is drawn where it is: overhangs, a ship's decks and hull, the gap under
-- a bridge - nothing is filled in under the top. Seen from low down a stack
-- of flat slices thins out, so upright slices (across x or z, whichever
-- faces the eye most) stand in it too. A slice is one texture: flat ground
-- is a few slices, not thousands of boxes.

local Vox = setmetatable({}, { __index = Model })
Vox.__index = Vox
W.Vox = Vox

function W.newVoxels(opts)
  local v = W.newModel(opts)
  v.vox = true
  return setmetatable(v, Vox)
end

-- a run's block at height y (its layers: the top block's, the next, the rest)
local function bandAt(r, y)
  if not r[4] then return r[3] end
  if y > r[1] - r[4] then return r[3] end
  if r[5] and y > r[1] - r[4] - (r[6] or 0) then return r[5] end
  return r[7] or r[5] or r[3]
end
W.bandAt = bandAt

-- Every column as segments of voxel levels (1 = the floor's), top first:
-- { hi, lo, palette number, top of its run }; and each column's runs as
-- boxes (shape: for picking a spot)
function Vox:columns(d)
  local c, u, floor, ceil, L = self.c, self.u, self.floor, self.ceil, self.L
  local function pal(n)
    local p = self.palIdx[n]
    if not p then
      p = #self.pal + 1
      self.pal[p], self.palIdx[n] = n, p
    end
    return p
  end
  local segs, shape, cut, cand = {}, {}, false, {}
  for k, cell in ipairs(d.cells) do
    local list, sh = {}, false
    for _, r in ipairs(cell.runs) do
      local top, bot = math.min(r[1] + 1, ceil), math.max(r[2], floor)
      if r[1] + 1 > ceil then cut = true end
      if top > bot then
        sh = sh or {}
        sh[#sh + 1] = { y0 = (bot - floor) * u, hb = (top - bot) * u, top = r[1] }
        -- (a level is solid if the run reaches into it; its block: the run's at the level's highest block in it)
        local hiL = math.min(L, math.floor((top - 1 - floor) / c) + 1)
        local loL = math.max(1, math.floor((bot - floor) / c) + 1)
        local first = true
        local kk = hiL
        while kk >= loL do
          local n = bandAt(r, math.min(top - 1, floor + kk * c - 1))
          -- (levels with the same block: one segment)
          local k2 = kk
          while k2 - 1 >= loL and bandAt(r, math.min(top - 1, floor + (k2 - 1) * c - 1)) == n do k2 = k2 - 1 end
          list[#list + 1] = { kk, k2, pal(n), first }
          first = false
          kk = k2 - 1
        end
      end
    end
    segs[k], shape[k] = list, sh
    -- (the boundaries where this column may have a top or an underside: its segments' ends)
    for si = 1, #list do
      local s = list[si]
      local kb = s[1]
      for _ = 1, 2 do
        local cl = cand[kb]
        if not cl then cl = {} cand[kb] = cl end
        cl[#cl + 1] = k
        kb = s[2] - 1
      end
    end
  end
  return segs, shape, cut, cand
end

-- (the segment holding level k in a column, nil: air)
local function voxAt(list, k)
  for i = 1, #list do
    local s = list[i]
    if s[2] <= k and k <= s[1] then return s end
  end
end

-- (what a voxel looks like: its block, and whether it is its run's top / the block under it)
local function voxKey(s, k)
  if not s then return "" end
  return s[3] .. (s[4] and (k == s[1] and "t" or k == s[1] - 1 and "u") or "")
end
-- (a column's segments as a string: what changed between two pieces)
local function segSig(list)
  local out = {}
  for i, s in ipairs(list) do out[i] = s[1] .. "," .. s[2] .. "," .. s[3] .. (s[4] and "t" or "") end
  return table.concat(out, ";")
end

function Vox:layout(keepFloor)
  local d = self.data
  if not d then return end
  local c = d.cellStep or 1
  local G = math.max(1, math.floor(d.size / c + 0.5))
  local u = self.size / d.size
  local floor = keepFloor or ((d.low or 0) + (self.lift or 0))
  local ceil = floor + self.heightLimit * self.size / u
  local L = math.max(1, math.ceil((ceil - floor) / c))
  self.G, self.c, self.u, self.floor, self.ceil, self.L = G, c, u, floor, ceil, L
  self.ppv = 1                                          -- (pixels a voxel: close up, the blocks' textures)
  local want = W.detail().px / d.size
  if c == 1 then self.ppv = W.ppbFor(want) end
  if not keepFloor then self.pal, self.palIdx = {}, {} end
  self.segs, self.shape, self.cut, self.cand = self:columns(d)
  self.sigs = {}
  for k, list in ipairs(self.segs) do self.sigs[k] = segSig(list) end
  self.slices = self.slices or { y = {}, x = {}, z = {} }
  -- everything to make: a flat level (top first) and an upright slice each way
  -- in turn - the walls come up with the floors, not after them
  self.todo = {}
  local flats = {}
  for kb in pairs(self.cand) do if kb >= 1 and kb <= L then flats[#flats + 1] = kb end end
  table.sort(flats, function(x, y) return x > y end)
  for n = 1, math.max(#flats, G + 1) do
    if flats[n] then self.todo[#self.todo + 1] = { "y", flats[n] } end
    if n <= G + 1 then
      self.todo[#self.todo + 1] = { "x", n - 1 }
      self.todo[#self.todo + 1] = { "z", n - 1 }
    end
  end
  self.placeAt = 1
end

-- A newer piece of the same area (scans, more from Distant Horizons): only
-- the slices through columns that changed are made again - the rest stay
-- as they are, and the old ones show until their new ones are ready
function Vox:update(d)
  local oldSigs = self.sigs
  local oldSegs = self.segs
  self.data = d
  local segs, shape, cut, cand = self:columns(d)
  local G = self.G
  local levels, xs, zs = {}, {}, {}
  local sigs = {}
  for k, list in ipairs(segs) do
    sigs[k] = segSig(list)
    if sigs[k] ~= oldSigs[k] then
      local i, j = math.floor((k - 1) / G), (k - 1) % G
      xs[i], zs[j], xs[i + 1], zs[j + 1] = true, true, true, true
      -- (only the levels whose block, or how it looks, changed - not every level of the column)
      local was, seen = oldSegs[k] or {}, {}
      for _, l2 in ipairs({ list, was }) do
        for _, s in ipairs(l2) do
          for lv = s[2], s[1] do
            if not seen[lv] then
              seen[lv] = true
              if voxKey(voxAt(list, lv), lv) ~= voxKey(voxAt(was, lv), lv) then levels[lv], levels[lv - 1] = true, true end
            end
          end
        end
      end
    end
  end
  self.segs, self.shape, self.cut, self.sigs, self.cand = segs, shape, cut, sigs, cand
  self.todo = self.todo or {}
  for lv = self.L, 1, -1 do
    if levels[lv] then self.todo[#self.todo + 1] = { "y", lv } end
  end
  for n = 0, G do
    if xs[n] then self.todo[#self.todo + 1] = { "x", n } end
    if zs[n] then self.todo[#self.todo + 1] = { "z", n } end
  end
end

-- The colour (RGB) of palette number p, shaded: f
function Vox:shadeOf(p, f, px, side)
  local name = self.pal[p]
  local tp = self:tilePixels(name, px or 1, side)
  if f == 1 then return tp end
  local out = {}
  for i, c in ipairs(tp) do out[i] = shade(c, f) end
  return out
end

-- one slice's pixels from a grid of voxels: get(a, b) -> palette, f, side (nil: air);
-- a across (columns), b down (rows); w x h voxels -> flat ARGB, pixels a side
function Vox:paint(w, h, get, ppv)
  ppv = ppv or self.ppv
  local pw = w * ppv
  local flat, cache, n = {}, {}, 0
  local floor = math.floor
  local tiles = {}                      -- (one row of voxels: each one's pixels, false: air)
  for b = 0, h - 1 do
    for a = 0, w - 1 do
      local p, f, side = get(a, b)
      local tp = false
      if p then
        local key = (p * 1000 + floor(f * 100 + 0.5)) * 2 + (side and 1 or 0)
        tp = cache[key]
        if not tp then
          tp = {}
          for i, c in ipairs(self:shadeOf(p, f, ppv, side)) do tp[i] = argb(c) end      -- (a copy: tiles are shared)
          cache[key] = tp
        end
      end
      tiles[a] = tp
    end
    -- (written in order, pixel row by pixel row: the picture stays a plain
    -- list instead of filling in out of order)
    for ty = 0, ppv - 1 do
      local i0 = ty * ppv
      local a = 0
      while a < w do
        local tp = tiles[a]
        if tp then
          for tx = 1, ppv do flat[n + tx] = tp[i0 + tx] end
          n = n + ppv
          a = a + 1
        else
          -- (a run of air: one span of clear pixels)
          local a2 = a + 1
          while a2 < w and not tiles[a2] do a2 = a2 + 1 end
          local n2 = n + (a2 - a) * ppv
          for m = n + 1, n2 do flat[m] = 0 end
          n, a = n2, a2
        end
      end
    end
  end
  return flat, pw, h * ppv
end

-- Faces, as Minecraft shades them: tops lit (and by slope / the foot of
-- walls, as the top-down pictures), sides darker by which way they face,
-- undersides darkest. Every slice lies on a boundary between blocks and
-- holds only the faces there that meet air - so every face outside is drawn
-- once, where it really is (the outermost blocks' outer faces, undersides)
W.FACE = { down = 0.55, x = 0.72, z = 0.86 }

-- (a side face's block: its run's top block lightest, the one under it a
-- little darker, deeper darker still - each layer of blocks shows)
local function voxDepth(s, k)
  if s[4] and k == s[1] then return 1 end
  if s[4] and k == s[1] - 1 then return 0.93 end
  return 0.86
end

-- (a slice's faces cut into tiles, each one texture of at most 256 pixels a
-- side: a 256-across view at 2 pixels a block is 4 tiles, not one blurred
-- picture). cells: list of { u, v, value } (u, v voxels on the slice);
-- -> parts { u0, u1, v0, v1, cells = { [u * 4096 + v] = value } }, tight
local function tileUp(cells, T)
  local parts, byKey, order = {}, {}, {}
  for _, cell in ipairs(cells) do
    local u, v = cell[1], cell[2]
    local key = math.floor(u / T) * 4096 + math.floor(v / T)
    local p = byKey[key]
    if not p then
      p = { u0 = u, u1 = u, v0 = v, v1 = v, cells = {}, key = key }
      byKey[key] = p
      order[#order + 1] = key
    end
    if u < p.u0 then p.u0 = u end
    if u > p.u1 then p.u1 = u end
    if v < p.v0 then p.v0 = v end
    if v > p.v1 then p.v1 = v end
    p.cells[u * 4096 + v] = cell[3]
  end
  table.sort(order)
  for _, key in ipairs(order) do parts[#parts + 1] = byKey[key] end
  return parts
end

-- (the first part's place copied onto the slice: one-tile slices read as before)
local function mirror(sl, names)
  local p = sl.parts[1]
  if p and #sl.parts == 1 then
    for _, n in ipairs(names) do sl[n] = p[n] end
    sl.pw, sl.ph = p.pw, p.ph
  end
end

-- Flat slice on boundary k (the top of level k): the tops of blocks with air
-- above, the undersides of blocks with air below - looked for only in the
-- columns with a run ending at k -> the slice (empty: none)
function Vox:buildFlat(k)
  local G, L, segs, c = self.G, self.L, self.segs, self.c
  local light = W.lighting(self.data)
  local cells, seen = {}, {}
  for _, col in ipairs(self.cand[k] or {}) do
    if not seen[col] then
      seen[col] = true
      local i, j = math.floor((col - 1) / G), (col - 1) % G
      local below = k >= 1 and voxAt(segs[col], k)
      local above = k + 1 <= L and voxAt(segs[col], k + 1)
      if below and not above then
        cells[#cells + 1] = { i, j, { below[3], light(i * c, j * c), false } }    -- (a top: its top's texture)
      elseif above and not below then
        cells[#cells + 1] = { i, j, { above[3], W.FACE.down, true } }           -- (an underside)
      end
    end
  end
  local sl = { stack = "y", k = k, ops = #(self.cand[k] or {}) }
  sl.parts = tileUp(cells, math.floor(256 / self.ppv))
  if #sl.parts == 0 then
    sl.empty = true
    return sl
  end
  for _, p in ipairs(sl.parts) do
    p.i0, p.i1, p.j0, p.j1 = p.u0, p.u1, p.v0, p.v1
    local pc, i0, j0 = p.cells, p.i0, p.j0
    p.flat, p.pw, p.ph = self:paint(p.i1 - p.i0 + 1, p.j1 - p.j0 + 1, function(a, b)
      local v = pc[(i0 + a) * 4096 + (j0 + b)]
      if v then return v[1], v[2], v[3] end
    end)
    p.cells = nil
  end
  mirror(sl, { "i0", "i1", "j0", "j1" })
  return sl
end

-- Upright slice on boundary b across x (between columns b-1 and b) or z:
-- the side faces there that meet air (outside the area is air: the edges'
-- outer faces) -> the slice
function Vox:buildUpright(axis, b)
  local G, segs = self.G, self.segs
  local none = {}
  local function column(i, j)
    if i < 0 or j < 0 or i >= G or j >= G then return none end
    return segs[i * G + j + 1]
  end
  local shadeF = axis == "x" and W.FACE.x or W.FACE.z
  local cells, ops, nc = {}, 0, 0
  for a = 0, G - 1 do
    local s1 = axis == "x" and column(b - 1, a) or column(a, b - 1)
    local s2 = axis == "x" and column(b, a) or column(a, b)
    local seen = {}
    -- (each level either column reaches, once: a face where only one is solid)
    for pass = 1, 2 do
      local list = pass == 1 and s1 or s2
      for si = 1, #list do
        local s = list[si]
        for k = s[2], s[1] do
          if not seen[k] then
            seen[k] = true
            ops = ops + 1
            local v1, v2 = voxAt(s1, k), voxAt(s2, k)
            if (v1 == nil) ~= (v2 == nil) then
              local s0 = v1 or v2
              nc = nc + 1
              cells[nc] = { a, k, { s0[3], shadeF * voxDepth(s0, k), true } }
            end
          end
        end
      end
    end
  end
  local sl = { stack = axis, n = b, ops = ops }
  -- (close up at the flat slices' pixels a block; tall ones in tiles too)
  local pp = self.ppv
  sl.parts = tileUp(cells, math.floor(256 / pp))
  if #sl.parts == 0 then
    sl.empty = true
    return sl
  end
  -- (pixels: rows from the top level down; across x the picture runs south -> north, across z west -> east)
  for _, p in ipairs(sl.parts) do
    p.a0, p.a1, p.k0, p.k1 = p.u0, p.u1, p.v0, p.v1
    local pc, a0, a1, k1 = p.cells, p.a0, p.a1, p.k1
    local get
    if axis == "x" then
      get = function(x, y)
        local v = pc[(a1 - x) * 4096 + (k1 - y)]
        if v then return v[1], v[2], v[3] end
      end
    else
      get = function(x, y)
        local v = pc[(a0 + x) * 4096 + (k1 - y)]
        if v then return v[1], v[2], v[3] end
      end
    end
    p.flat, p.pw, p.ph = self:paint(p.a1 - p.a0 + 1, p.k1 - p.k0 + 1, get, pp)
    p.cells = nil
  end
  mirror(sl, { "a0", "a1", "k0", "k1" })
  return sl
end

-- Where one part of a slice goes and how it is turned (model units / degrees)
function Vox:slicePlace(sl, p)
  local u, c, half = self.u, self.c, self.data.size / 2
  if sl.stack == "y" then
    -- flat, on its boundary (level k's top); its corner (a picture's origin) at the south-west
    local x, y, z = self:point((p.i0 * c - half) * u, sl.k * c * u + u * 0.002, ((p.j1 + 1) * c - half) * u)
    return x, y, z, (p.i1 - p.i0 + 1) * c * u, (p.j1 - p.j0 + 1) * c * u, self.flatRot
  elseif sl.stack == "x" then
    -- upright on the boundary x = n: its left edge at the south end
    local x, y, z = self:point((sl.n * c - half) * u, (p.k0 - 1) * c * u, ((p.a1 + 1) * c - half) * u)
    return x, y, z, (p.a1 - p.a0 + 1) * c * u, (p.k1 - p.k0 + 1) * c * u, self.rotX90
  else
    local x, y, z = self:point((p.a0 * c - half) * u, (p.k0 - 1) * c * u, (sl.n * c - half) * u)
    return x, y, z, (p.a1 - p.a0 + 1) * c * u, (p.k1 - p.k0 + 1) * c * u, self.rot
  end
end

function Vox:setFrame(origin, m)
  local moved = Model.setFrame(self, origin, m)
  if moved then
    local a, b, cc = W.euler(W.mul(m, W.rotY(90)))
    self.rotX90 = { a, b, cc }
    self.placeAt = 1
  end
  return moved
end

-- Show / place a slice's parts (their pixels sent the first time they show)
function Vox:show(sl)
  local used = 0
  for _, p in ipairs(sl.parts or {}) do
    local x, y, z, w, h, rot = self:slicePlace(sl, p)
    local o = self:place(p, "o", "Texture", x, y, z, w, h, nil, { width = p.pw, height = p.ph, culling = false }, rot)
    used = used + 1
    if o and p.flat then
      local ok, err = pcall(o.o.setPixels, 1, 1, p.pw, p.ph, p.flat)
      if not ok then H.log("war table slice: " .. tostring(err)) end
      p.flat = nil                                     -- (sent: the glasses keep it)
      -- (a frame's budget in pixels too: 1024 = 64k pixels a frame - the game has to take them in)
      used = used + math.floor(p.pw * p.ph / 64)
    end
  end
  sl.o = sl.parts and sl.parts[1] and #sl.parts == 1 and sl.parts[1].o or nil
  return used
end

local function sliceObjs(sl)
  local out = {}
  for _, p in ipairs(sl.parts or {}) do if p.o then out[#out + 1] = p.o end end
  return out
end

-- A slice made (again): in place of the old one - each part's texture kept
-- when its size is the same (new pixels into it), else a new one (never resized)
function Vox:install(new)
  local t = self.slices[new.stack]
  local key = new.stack == "y" and new.k or new.n
  local old = t[key]
  if old then
    for idx, p in ipairs(new.parts or {}) do
      local q = old.parts and old.parts[idx]
      if q and q.o and q.pw == p.pw and q.ph == p.ph then
        p.o, q.o = q.o, nil
      end
    end
    for _, o in ipairs(sliceObjs(old)) do W.removeObj(o) end
  end
  t[key] = new
end

function Vox:step(budget)
  if not self.data or not self.segs then return 0 end
  local used = 0
  if not (self.want and self.origin) then
    if not self.hidden then
      for _, t in pairs(self.slices) do
        for _, sl in pairs(t) do
          for _, o in ipairs(sliceObjs(sl)) do o:show(false) end
        end
      end
      if self.plate and self.plate.box then self.plate.box:show(false) end
      self.hidden = true
    end
    return 0
  end
  if self.hidden then self.placeAt = 1 end              -- (shown again: every slice back)
  self.hidden = false
  if self.placeAt == 1 then self:placePlate() end
  -- 1: what is to be made (the looking counts too, found or not)
  while used < budget and #self.todo > 0 do
    local job = table.remove(self.todo, 1)
    local sl = job[1] == "y" and self:buildFlat(job[2]) or self:buildUpright(job[1], job[2])
    self:install(sl)
    used = used + 1 + math.floor((sl.ops or 0) / 512) + self:show(sl)
  end
  -- 2: moved / turned: every slice goes where it now is
  if self.placeAt then
    local list = {}
    for k = self.L, 0, -1 do
      if self.slices.y[k] then list[#list + 1] = self.slices.y[k] end
    end
    for n = 0, self.G do
      if self.slices.x[n] then list[#list + 1] = self.slices.x[n] end
      if self.slices.z[n] then list[#list + 1] = self.slices.z[n] end
    end
    while used < budget and self.placeAt <= #list do
      used = used + self:show(list[self.placeAt])
      self.placeAt = self.placeAt + 1
    end
    if self.placeAt > #list then self.placeAt = nil end
  end
  return used
end

function Vox:busy()
  return self.data ~= nil and (#(self.todo or {}) > 0 or self.placeAt ~= nil)
end

-- A new piece: the same area again (an update) - only what changed is made
-- again; another area - every slice anew
function Vox:setData(d)
  if not d then return end
  local old = self.data
  if old and self.segs and old.x0 == d.x0 and old.z0 == d.z0 and old.size == d.size
    and (old.cellStep or 1) == (d.cellStep or 1) then
    return self:update(d)
  end
  self:clear()
  self.data = d
  self:layout()
end

function Vox:clear()
  for _, t in pairs(self.slices or {}) do
    for _, sl in pairs(t) do
      for _, p in ipairs(sl.parts or {}) do W.removeObj(p.o) end
    end
  end
  self.slices = { y = {}, x = {}, z = {} }
  self.todo = {}
end

function Vox:setLift(lift)
  lift = tonumber(lift) or 0
  if lift ~= self.lift then
    self.lift = lift
    self:clear()
    self:layout()
  end
end

-- (bigger / smaller: the same slices, only placed further apart)
function Vox:setSize(size)
  if math.abs(size - self.size) > 1e-6 then
    self.size = size
    if self.data then
      self.u = size / self.data.size
      self.shape = select(2, self:columns(self.data))      -- (for picking: the runs' boxes at the new size)
      self.placeAt = 1
    end
  end
end

-- the renderer: "slices" (every block) or "squares" (tops and sides, as before) - V in the 3D view
function W.slicesOn() return H.cfg.war.renderer ~= "squares" end

function W.previewOpts()
  return { size = H.cfg.war.view3dSize, relative = true, heightLimit = H.cfg.war.heightLimit,
    maxObjects = W.objectsFor(W.detail().squares, H.cfg.war.view3dObjects), plate = 0x0A1A14 }
end

function W.newPreview()
  return W.slicesOn() and W.newVoxels(W.previewOpts()) or W.newModel(W.previewOpts())
end

---------------------------------------------------------------- the map computer

W.seq, W.waiting = 0, {}

function W.ask(msg)
  if not W.server or not H.modem then return false end
  W.seq = W.seq + 1
  msg.id = W.seq
  W.waiting[msg.op] = W.seq
  pcall(rednet.send, W.server, msg, H.PROTO_MAP)
  return true
end

-- (from the HUD's network loop, once a second)
function W.netTick()
  if not H.modem then return end
  if not W.server and now() - (W.lookedAt or -100) > 10 then
    W.lookedAt = now()
    W.server = rednet.lookup(H.PROTO_MAP, H.MAP_HOST)
    if W.server then H.log("war table: map computer " .. W.server) end
  end
  if W.server and now() - (W.table.askedAt or -100) > (W.table.rev and 60 or 5) then
    W.table.askedAt = now()
    pcall(rednet.send, W.server, { op = "table?" }, H.PROTO_MAP)
  end
end

function W.onMessage(from, msg)
  if msg.op == "table" then
    W.server = W.server or from
    if from == W.server then W.onTable(msg) end
  elseif from ~= W.server then
    return
  elseif msg.op == "overview" and msg.id == W.waiting.overview then
    W.showOverview(msg)
  elseif msg.op == "view" and msg.id == W.waiting.corner then
    W.onCorner(msg)
  elseif msg.op == "view" and msg.id == W.waiting.view then
    W.menu.loading = nil
    local d = W.decode(msg)
    if d then
      W.menu.piece = d
      -- (the renderer changed (V): a new model of the other kind)
      if W.preview and (W.preview.vox == true) ~= d.vox then
        W.preview:clear()
        W.preview = nil
      end
      if not W.preview then W.preview = d.vox and W.newVoxels(W.previewOpts()) or W.newModel(W.previewOpts()) end
      W.preview:setData(d)
    end
  elseif msg.op == "point" then
    W.onPoint(msg)
  elseif msg.op == "error" then
    W.menu.loading = nil
    H.toast("MAP COMPUTER: " .. tostring(msg.text):upper(), H.C.red, 4)
  end
end

-- What is at a spot: for the cursor's readout, or the target's height
function W.onPoint(msg)
  local m = W.menu
  local x, z = tonumber(msg.x), tonumber(msg.z)
  if not (x and z) then return end
  local y = tonumber(msg.y)
  if m.hoverAsk and m.hoverAsk.x == x and m.hoverAsk.z == z then
    m.hover = { x = x, z = z, y = y, name = msg.name }
  end
  local t = m.target
  if t and t.x == x and t.z == z then t.y, t.name = y, msg.name end
end

-- A target picked on the map (right-click): the stratagem list opens, its
-- code typed with the arrows calls it there
function W.setTarget(x, z)
  local m = W.menu
  m.target = { x = math.floor(x), z = math.floor(z) }
  W.askPoint(m.target.x, m.target.z)
  H.ui.input = ""
  H.openMenu()
end

-- The target as a call spot (on top of the ground there); nil: no height yet
function W.targetPoint()
  local t = W.menu.target
  if not t or not t.y then return nil end
  return { x = t.x + 0.5, y = t.y + 1, z = t.z + 0.5 }
end

---------------------------------------------------------------- the table

W.table = {}

function W.onTable(msg)
  local t = W.table
  if t.rev == msg.rev then return end
  t.rev = msg.rev
  t.view = type(msg.view) == "table" and msg.view or nil
  local a = msg.anchor
  if type(a) == "table" and ((a.mode == "ship" and type(a.rel) == "table") or (a.mode == "world" and type(a.world) == "table")) then
    t.anchor = a
  else
    t.anchor = nil
  end
  local d = W.decode(msg.data)
  if d then
    t.data = d
    -- (slices / squares changed: a new model of the other kind)
    if t.model and (t.model.vox == true) ~= d.vox then
      t.model:clear()
      t.model = nil
    end
    if t.model then
      t.model.maxObjects = W.objectsFor(t.view and t.view.cells or 0, H.cfg.war.tableObjects)
      t.model:setData(d)
    end
  end
end

-- (each frame) the table: shown near it, moved with the ship, hidden while
-- the menu is up (the 3D view is in front of you then) unless placing it
function W.tableTick(budget)
  local t, m = W.table, W.menu
  -- (placing the status hologram is not placing the table)
  local placing = m.open and m.setup and m.setupFor ~= "status"
  local anchor = (placing and m.setup) or t.anchor
  local me = H.me
  local want = anchor and H.worn and me and (not m.open or placing) and true or false
  -- (on a ship under way: hidden - it cannot keep up; back once the ship is still)
  if want and anchor.mode == "ship" and not m.setup and W.shipMoving() then want = false end
  local origin, rot
  if want then
    origin, rot = W.tableFrame(anchor, t.view and t.view.yaw or 0, (H.cfg.war.glide or 10) / 20)
    if not origin or (me.x - origin[1]) ^ 2 + (me.z - origin[3]) ^ 2 > H.cfg.war.near ^ 2 then want = false end
  end
  -- the plate it stands on (also shows where the table is before it has a map)
  if want and not t.plate and H.ov then
    t.plate = H.make("Box", { x = origin[1], y = origin[2], z = origin[3], sizeX = anchor.size, sizeY = 0.02,
      sizeZ = anchor.size, color = 0x0A1A14, opacity = 0.85 })
    glideObj(t.plate, H.cfg.war.glide)
  end
  if t.data and not t.model then
    local opts = { size = anchor and anchor.size or 3, glide = H.cfg.war.glide, heightLimit = H.cfg.war.heightLimit,
      maxObjects = W.objectsFor(t.view and t.view.cells or 0, H.cfg.war.tableObjects) }
    t.model = t.data.vox and W.newVoxels(opts) or W.newModel(opts)
    t.model:setData(t.data)
  end
  local used = 0
  if want then
    local due = m.setup or now() - (t.movedAt or -100) >= H.cfg.war.moveEvery
    if due then
      t.movedAt = now()
      if t.model then
        t.model:setSize(anchor.size)
        t.model:setLift(t.view and t.view.lift or 0)
        t.model:setFrame(origin, rot)
      end
      if t.plate then
        local p = W.apply(rot, { 0, -0.012, 0 })
        t.plate:pos(origin[1] + p[1], origin[2] + p[2], origin[3] + p[3])
        local a, b, c = W.euler(rot)
        t.plate:set("RotY", a) t.plate:set("RotX", b) t.plate:set("RotZ", c)
        t.plate:set("SizeX", anchor.size) t.plate:set("SizeZ", anchor.size)
      end
    end
  end
  if t.plate then t.plate:show(want) end
  if t.model then
    t.model:setVisible(want)
    used = t.model:step(budget)
    t.pinsAt = W.pinsTick(t.model, want, t.pinsAt, 0.5)
  end
  return used
end

---------------------------------------------------------------- the field
-- Everything shown on both maps, each kind its own mark and colour:
--   you @ white, helldivers their tag in their colour, hostiles x red,
--   friendlies o green, other players ? orange, ships # purple, the
--   destroyer D blue, stratagems their icon on a beacon (yellow called,
--   red firing...), the map's target X red, debris (wrecks marked on the
--   strike computer) # grey with no icon - F, L and I pass it by

W.KIND = {
  debris = { colour = 0x8C8C8C, glyph = "#" },
  me = { colour = 0xFFFFFF, glyph = "@" },
  hostile = { colour = 0xFF3030, glyph = "x" },
  friendly = { colour = 0x5DD55D, glyph = "o" },
  player = { colour = 0xFF9A3D, glyph = "?" },
  ship = { colour = 0xC050FF, glyph = "#" },
  destroyer = { colour = 0x55B4FF, glyph = "D" },
  target = { colour = 0xFF3B2F, glyph = "X" },
  shot = { colour = 0xFFD23F, glyph = "." },          -- (a projectile: a tiny blip)
}

-- A radar track's kind (Create Radar's categories), nil = not shown
function W.trackKind(c)
  c = tostring(c):upper()
  if c:find("HOSTILE") or c:find("MONSTER") or c:find("MOB") or c:find("ENEMY") then return "hostile" end
  if c:find("PASSIVE") or c:find("ANIMAL") or c:find("FRIEND") or c:find("NEUTRAL") or c:find("CREATURE")
    or c:find("VILLAGER") or c:find("AMBIENT") or c:find("WATER") then return "friendly" end
  if c == "PLAYER" then return "player" end
  if c == "SABLE" or c:find("SHIP") then return "ship" end
  if c == "PROJECTILE" then return "shot" end
end

-- A name to write over an icon: players and helldivers their username,
-- ships their name - none, or over W.NAME_MAX letters (an unnamed one's
-- long id): nil, nothing written
W.NAME_MAX = 16
function W.nameOf(s)
  if type(s) ~= "string" then return nil end
  s = s:match("^%s*(.-)%s*$")
  if s == "" or #s > W.NAME_MAX then return nil end
  return s
end

-- Everything on the field now: { kind, x, y (feet), z, colour, glyph, label, icon }
function W.pins()
  local out, me = {}, H.me
  local function add(p) out[#out + 1] = p end
  local function nearDiver(x, y, z, id)
    if me and ((id and me.uuid == id) or (math.abs(me.x - x) < 3 and math.abs(me.z - z) < 3 and math.abs(me.y - y) < 4)) then return true end
    for _, t in pairs(H.team) do
      if t.x and now() - t.at < H.TEAM_FRESH and ((id and t.uuid == id)
        or (math.abs(t.x - x) < 3 and math.abs(t.z - z) < 3 and math.abs(t.y - y) < 5)) then return true end
    end
  end
  -- (a radar player who is a helldiver, by their id: their username)
  local function diverName(id)
    for _, t in pairs(H.team) do if id and t.uuid == id then return t.user end end
  end
  local function beacons(list)
    for _, b in ipairs(list or {}) do
      if tonumber(b.x) and tonumber(b.z) then
        add({ kind = "beacon", x = b.x, y = tonumber(b.y) or 0, z = b.z, colour = tonumber(b.c) or H.C.yellow, glyph = "!",
          label = tostring(b.n or "STRATAGEM"):upper(), status = b.t, icon = b.i or H.iconFor(b.n) })
      end
    end
  end
  for _, t in pairs(H.team) do
    if t.x and now() - t.at < H.TEAM_FRESH then
      local tag = H.tagOf(t.name, t.slot)
      add({ kind = "diver", ent = "helldiver", x = t.x, y = t.y - 1.6, z = t.z,
        colour = t.dead and H.C.grey or H.colourOf(t.slot), glyph = tag, label = W.nameOf(t.user) })
      beacons(t.calls)
    end
  end
  local r = H.radar
  if r and now() - r.at < 5 then
    for _, tr in ipairs(r.tracks) do
      local kind = tonumber(tr.x) and W.trackKind(tr.c)
      -- (a wreck: grey, no icon, never picked by F / L / I - those take players and ships)
      if kind == "ship" and tr.dbr then kind = "debris" end
      if kind and not (kind == "player" and nearDiver(tr.x, tr.y, tr.z, tr.id)) then
        local k = W.KIND[kind]
        local px, py, pz = tr.x, tonumber(tr.y) or 0, tr.z
        -- (a projectile moved on by its speed since the radar saw it - at most 2 s)
        if kind == "shot" and type(tr.v) == "table" then
          local age = clamp(now() - r.at, 0, 2)
          px, py, pz = px + (tonumber(tr.v[1]) or 0) * 20 * age, py + (tonumber(tr.v[2]) or 0) * 20 * age, pz + (tonumber(tr.v[3]) or 0) * 20 * age
        end
        local p = { kind = kind, x = px, y = py, z = pz, colour = k.colour, glyph = k.glyph,
          id = tr.id, friend = tr.f == true, locked = tr.l == true }
        -- players and ships (sub-levels): their icons - friendly as set on the ship (strike), else hostile
        if kind == "player" or kind == "ship" then
          p.ent = (p.friend and "friendly_" or "hostile_") .. kind
          p.colour = p.friend and W.KIND.friendly.colour or W.KIND.hostile.colour
          -- (over it: a player's username - from the ship's Player Detector, or the squad's;
          -- a ship's name - none: nothing)
          local name = kind == "player" and (W.nameOf(tr.u) or W.nameOf(diverName(tr.id))) or W.nameOf(tr.sn)
          p.label, p.name = name, name
          -- (designated on the ship - G on the map: any icon, whatever the radar says)
          if W.DESIGNATE[tr.d] then
            local d = W.DESIGNATE[tr.d]
            p.ent, p.designated = tr.d, tr.d
            p.colour = d.friend and W.KIND.friendly.colour or W.KIND.hostile.colour
          end
          if p.locked then p.label = p.label and ("[LOCKED] " .. p.label) or "[LOCKED]" end
        elseif kind == "debris" then
          p.label = W.nameOf(tr.sn) or "DEBRIS"
        end
        add(p)
      end
    end
  end
  beacons(H.myBeacons())
  local nav = W.shipNow(0)
  -- (the destroyer: at its middle, with its outline's heading and size)
  local ship = nav and W.shipOutline()
  if ship then
    add({ kind = "destroyer", x = ship.x, y = ship.y, z = ship.z, colour = W.KIND.destroyer.colour, glyph = "D", label = "DESTROYER",
      ship = ship })
  elseif nav then
    add({ kind = "destroyer", x = nav[1], y = nav[2], z = nav[3], colour = W.KIND.destroyer.colour, glyph = "D", label = "DESTROYER" })
  end
  local t = W.menu.target
  if t then add({ kind = "target", x = t.x + 0.5, y = (t.y or 0) + 1, z = t.z + 0.5, colour = W.KIND.target.colour, glyph = "X", label = "TARGET" }) end
  -- (the hologram's: a locked target, or where you aim on it with the stratagem menu up)
  local hl = W.holoLock and now() - W.holoLock.at < W.HOLO_LOCK and W.holoLock.spot or W.holoAimSpot
  if hl and not t then
    add({ kind = "target", x = hl.x, y = hl.y, z = hl.z, colour = W.KIND.target.colour, glyph = "X",
      label = W.holoLock and "TARGET" or "AIM" })
  end
  if me then add({ kind = "me", ent = "helldiver", x = me.x, y = me.y, z = me.z, colour = W.KIND.me.colour, glyph = "@", label = W.nameOf(me.user) }) end
  return out
end

-- Stratagem icons as pixels (icons/px.txt, made from the PNGs by
-- tools/iconpixels.py): name -> 16 x 16 ARGB, for painting into the map image
W.ICON_PX = 16
function W.iconPixels(name)
  if not W.iconPx then
    W.iconPx = {}
    local h = fs.exists("icons/px.txt") and fs.open("icons/px.txt", "r")
    if h then
      for line in h.readAll():gmatch("[^\n]+") do
        local n, list = line:match("^(%S+)%s+(%S+)")
        if n then
          local px = {}
          for hex in list:gmatch("%x%x%x%x%x%x%x%x") do px[#px + 1] = tonumber(hex, 16) end
          if #px == W.ICON_PX * W.ICON_PX then W.iconPx[n] = px end
        end
      end
      h.close()
    end
  end
  return W.iconPx[name] or W.iconPx.generic
end

---------------------------------------------------------------- the menu

W.menu = { open = false }
-- zoom steps: each about 1.5x the last (1 or 3 x a power of 2 - the map
-- computer splits those evenly)
W.SPANS = { 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096, 6144, 8192 }
W.AREAS = { 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048 }     -- the 3D view: blocks across

local function stepIn(list, v, dir)
  local best = 1
  for i, x in ipairs(list) do
    if math.abs(x - v) < math.abs(list[best] - v) then best = i end
  end
  return list[clamp(best + dir, 1, #list)]
end

-- The map (M - the old table key N opens the same): look, pick targets,
-- call stratagems, mark friendlies, lock the radar, T places the table. The
-- war table changes only on Enter in 3D (what the view shows goes on it);
-- Esc or anything else leaves it as it is
function W.open()
  if not H.ov then return end
  H.closeMenu()                          -- (the stratagem menu)
  local m, me = W.menu, H.me
  m.mode = "map"
  m.open, m.screen, m.input, m.drag, m.setup = true, "overview", "", nil, nil
  m.cur = m.cur or { x = H.L.w / 2, y = H.L.h / 2 }
  if not m.cx then
    m.cx, m.cz = me and math.floor(me.x) or 0, me and math.floor(me.z) or 0
  end
  m.span = m.span or 256
  m.view = m.view or { cx = m.cx, cz = m.cz, area = 64, yaw = 0, tilt = 55 }
  m.view.area = m.view.area or 64
  m.chosen, m.target = false, nil
  -- (at the table: its own view, in 3D - leaving puts nothing on it; Enter does)
  m.fromTable = false
  local tv, md = W.table.view, W.table.model
  if tv and md and md.origin and me
    and (me.x - md.origin[1]) ^ 2 + (me.z - md.origin[3]) ^ 2 <= W.TABLE_REACH ^ 2 then
    m.view = { cx = tv.cx, cz = tv.cz, area = tv.area or m.view.area, yaw = tv.yaw or 0, tilt = m.view.tilt or 55,
      lift = tv.lift or 0 }
    m.screen, m.fromTable = "3d", true
  end
  if H.kb then pcall(H.kb.setCaptureMouse, true) end
  W.buildMenu()
  if not W.server then H.toast("NO MAP COMPUTER IN RANGE - LOOKING", H.C.red, 3) W.lookedAt = nil end
  W.askOverview()
  if m.fromTable then
    W.askView()
    H.toast("THE WAR TABLE'S VIEW - ENTER PUTS CHANGES ON IT, ESC LEAVES IT AS IT IS", H.C.yellow, 3)
  end
end

-- F: the player / ship under the cursor friendly <-> hostile, kept on the
-- ship (strike's friendly list - its weapons will read it too)
-- The player / ship (a radar contact) nearest the cursor: on the top-down
-- map within W.PICK_PX pixels, in 3D within W.PICK_3D of the view's width of
-- the block under the cursor (nil: none near)
W.PICK_PX, W.PICK_3D = 30, 1 / 12
function W.contactAt()
  local m = W.menu
  local best, bestD
  local function try(p, d, limit)
    if p.id and (p.kind == "player" or p.kind == "ship") and d <= limit and (not bestD or d < bestD) then best, bestD = p, d end
  end
  local pins = W.pins()
  if m.screen == "overview" then
    for _, p in ipairs(pins) do
      local gx, gy = W.toGui(p.x, p.z)
      if gx then try(p, math.sqrt((gx - m.cur.x) ^ 2 + (gy - m.cur.y) ^ 2), W.PICK_PX) end
    end
  elseif m.hover3d then
    local h = m.hover3d
    for _, p in ipairs(pins) do
      try(p, math.sqrt((p.x - h.x) ^ 2 + (p.z - h.z) ^ 2), math.max(8, m.view.area * W.PICK_3D))
    end
  end
  return best
end

-- L: the radar's target - the contact under the cursor (again: let go). The
-- strike computer keeps it (its weapons aim by it); the maps mark it LOCKED
function W.toggleLock(p)
  p = p or W.contactAt()
  if not p then return H.toast("NO PLAYER OR SHIP THERE - POINT AT ONE", H.C.red, 2) end
  if not H.strike then return H.toast("NO DESTROYER IN RANGE", H.C.red, 2) end
  local on = not p.locked
  pcall(rednet.send, H.strike, { op = "lock", track = on and p.id or nil, on = on }, H.PROTO_STRIKE)
  H.toast(on and ("RADAR LOCK: " .. (p.name or (p.kind == "player" and "PLAYER " or "SHIP ") .. tostring(p.id):sub(1, 8)):upper())
    or "RADAR LOCK RELEASED", H.C.yellow, 3)
end

-- I: the contact under the cursor shown as the next icon (not G: the glasses' own key - letting it go closes the menu) - by the radar ->
-- helldiver -> friendly / hostile player -> friendly / hostile ship -> by
-- the radar. Kept on the ship (strike's designate list)
W.DESIGNATE = {
  helldiver = { label = "HELLDIVER", friend = true },
  friendly_player = { label = "FRIENDLY PLAYER", friend = true },
  hostile_player = { label = "HOSTILE PLAYER" },
  friendly_ship = { label = "FRIENDLY SHIP", friend = true },
  hostile_ship = { label = "HOSTILE SHIP" },
}
W.DESIGNATE_ORDER = { "helldiver", "friendly_player", "hostile_player", "friendly_ship", "hostile_ship" }
function W.designate()
  local best = W.contactAt()
  if not best then return H.toast("NO PLAYER OR SHIP THERE - POINT AT ONE", H.C.red, 2) end
  if not H.strike then return H.toast("NO DESTROYER IN RANGE", H.C.red, 2) end
  local nextOne = W.DESIGNATE_ORDER[1]
  for i, e in ipairs(W.DESIGNATE_ORDER) do
    if best.designated == e then nextOne = W.DESIGNATE_ORDER[i + 1] end
  end
  pcall(rednet.send, H.strike, { op = "designate", track = best.id, ent = nextOne }, H.PROTO_STRIKE)
  H.toast("SHOWN AS: " .. (nextOne and W.DESIGNATE[nextOne].label or "BY THE RADAR"), H.C.yellow, 3)
end

function W.toggleFriend()
  local best = W.contactAt()
  if not best then return H.toast("NO PLAYER OR SHIP THERE - POINT AT ONE", H.C.red, 2) end
  if not H.strike then return H.toast("NO DESTROYER IN RANGE", H.C.red, 2) end
  local on = not best.friend
  local label = (best.kind == "player" and "PLAYER " or "SHIP ") .. tostring(best.id):sub(1, 8)
  pcall(rednet.send, H.strike, { op = "friend", track = best.id, on = on, label = best.name or label }, H.PROTO_STRIKE)
  H.toast((on and "FRIENDLY: " or "HOSTILE: ") .. (best.name or label):upper(), on and W.KIND.friendly.colour or W.KIND.hostile.colour, 3)
end

---------------------------------------------------------------- the corner map
-- A small 3D map where the old one was (bottom left, hud.cfg map: left /
-- up / px / dist / tilt): slices, W.CORNER_AREA blocks across around where
-- you were when you last pressed Right Alt in the stratagem menu - it does
-- not follow you. Left Alt: 3D -> top-down (the same slices from straight
-- above) -> off. Square to the screen, north up. Who is on the field moves live

W.CORNER_AREA = 96
W.corner = { on = false }

function W.cornerToggle()
  local c = W.corner
  -- (off -> 3D -> top-down -> off)
  if not c.on then
    c.on, c.top = true, false
  elseif not c.top then
    c.top = true
  else
    c.on, c.top = false, false
  end
  if c.on and not c.data and not c.asked then return W.cornerUpdate() end
  H.toast(not c.on and "CORNER MAP OFF" or c.top and "CORNER MAP: TOP-DOWN (LEFT ALT: OFF)"
    or "CORNER MAP: 3D (LEFT ALT: TOP-DOWN) - RIGHT ALT IN THE STRATAGEM MENU CENTRES IT ON YOU", H.C.grey, 2)
end

-- The corner map's turn: tilted (3D) or looking straight down, square to the screen
function W.cornerTurn()
  return W.rotX(W.corner.top and 90 or H.cfg.map.tilt)
end

-- Right Alt in the stratagem menu: the corner map, around you now
function W.cornerUpdate()
  local me = H.me
  if not (me and W.server and H.modem) then return H.toast("CORNER MAP: NO MAP COMPUTER IN RANGE", H.C.red, 2) end
  W.seq = W.seq + 1
  W.waiting.corner = W.seq
  W.corner.asked, W.corner.on = now(), true
  pcall(rednet.send, W.server, { op = "view", id = W.seq, cx = math.floor(me.x), cz = math.floor(me.z), area = W.CORNER_AREA,
    vox = W.CORNER_AREA }, H.PROTO_MAP)
  H.toast("CORNER MAP: CENTRED ON YOU", H.C.grey, 1.5)
end

function W.cornerOpts()
  local _, _, _, per = H.mapFrame()
  return { size = H.cfg.map.px * per, relative = true, heightLimit = 1, plate = 0x0A1A14 }
end

function W.onCorner(msg)
  local d = W.decode(msg)
  if not d then return end
  local c = W.corner
  c.data = d
  if c.model then c.model:setData(d) end
end

-- (each frame) shown in the corner unless a menu is up; its slices a few at a time
function W.cornerTick(budget)
  local c = W.corner
  if c.data and not c.model then
    c.model = W.newVoxels(W.cornerOpts())
    c.model:setData(c.data)
  end
  local md = c.model
  if not md then return 0 end
  local want = c.on and H.worn and not W.menu.open and true or false
  md:setVisible(want)
  if want then
    local m = H.cfg.map
    local cx, cy, cz, per = H.mapFrame()
    md:setSize(m.px * per)
    -- (not turned to face the eye: its edges stay parallel to the screen's)
    md:setFrame({ cx, cy, cz }, W.cornerTurn())
  end
  local used = md:step(budget)
  c.pinsAt = W.pinsTick(md, want, c.pinsAt, 0.3)
  return used
end

---------------------------------------------------------------- the hologram, touched
-- The table can be aimed at like the ground: where your look meets the
-- hologram is a spot in the world. While the stratagem menu is up the spot
-- shows on the table (a red X); a call goes there. Middle-click on the
-- table locks a target there (it stays while you look away and type the
-- code); middle-click off it lets it go. W.HOLO_LOCK s and it is forgotten

W.HOLO_LOCK = 60
W.TABLE_REACH = 6       -- blocks: M this close to the table opens on its view

-- Your look into the table's hologram -> the world spot { x, y, z } (on top of the block), nil: not on it
function W.holoAim(me)
  me = me or H.me
  local md = W.table.model
  if not (me and md and md.want and md.origin) then return nil end
  local eye = { me.x, me.y + (me.eyeHeight or 1.62), me.z }
  local x, z, y = md:pickWorld(eye, H.lookDir(me.yaw or 0, me.pitch or 0))
  if not x then return nil end
  return { x = x + 0.5, y = (y or 0) + 1, z = z + 0.5 }
end

-- The target for a call from the hologram: the locked one, else where you look on it (nil: neither)
function W.holoTarget(me)
  local l = W.holoLock
  if l and now() - l.at < W.HOLO_LOCK then return l.spot, "locked on the war table" end
  W.holoLock = nil
  local spot = W.holoAim(me)
  if spot then return spot, "where you look on the war table" end
end

-- A click in the world (the keyboard module: button 3 = middle) - on the table: lock a target there
function W.onWorldClick(button)
  if tonumber(button) ~= 3 then return end
  local spot = W.holoAim()
  -- (on a player's / ship's token on the hologram: the radar's lock goes to it)
  if spot then
    for _, p in ipairs(W.pins()) do
      if p.id and (p.kind == "player" or p.kind == "ship") and (p.x - spot.x) ^ 2 + (p.z - spot.z) ^ 2 <= 3 ^ 2 then
        return W.toggleLock(p)
      end
    end
  end
  if spot then
    W.holoLock = { spot = spot, at = now() }
    H.toast(("TARGET %d %d ON THE TABLE - HOLD THE GLASSES KEY, TYPE A CODE"):format(math.floor(spot.x), math.floor(spot.z)),
      H.C.red, 4)
  elseif W.holoLock then
    W.holoLock = nil
    H.toast("TABLE TARGET LET GO", H.C.yellow, 2)
  end
end

-- (each frame, the stratagem menu up: where you aim on the table, for its X)
function W.holoTick()
  W.holoAimSpot = H.ui.open and not W.menu.open and W.holoAim() or nil
end

-- Esc: the menu goes; the war table stays as it is (only Enter changes it)
function W.leave()
  local m = W.menu
  if not m.open then return end
  if H.kb then pcall(H.kb.setCaptureMouse, false) end
  if m.setup then W.finishSetup() end
  if m.target then H.closeMenu() end
  m.open, m.setup, m.drag, m.target = false, nil, nil, nil
  W.showMenu(false)
end

function W.sendTable()
  local m = W.menu
  if not W.server then
    H.toast("NO MAP COMPUTER - THE TABLE IS UNCHANGED", H.C.red, 3)
    return
  end
  local lv = W.detail()
  W.ask({ op = "settable", view = { cx = m.view.cx, cz = m.view.cz, area = m.view.area, yaw = m.view.yaw, lift = m.view.lift or 0,
    cells = math.floor(lv.squares * W.TABLE_SHARE), gap = lv.gap, cap = lv.cap, px = lv.px,
    vox = W.slicesOn() and lv.vox or nil } })
  H.toast("SENT TO THE WAR TABLE", H.C.yellow, 3)
  m.chosen = false
end

function W.askOverview()
  local m = W.menu
  if W.ask({ op = "overview", cx = m.cx, cz = m.cz, span = m.span, size = math.min(H.cfg.war.imageSize, m.span) }) then
    m.loading = now()
  end
end

-- (squares: about 2.2 objects each - a top, a body, now and then a second run)
function W.askView()
  local m = W.menu
  local lv = W.detail()
  if W.ask({ op = "view", cx = m.view.cx, cz = m.view.cz, area = m.view.area, cells = lv.squares, gap = lv.gap, cap = lv.cap,
    px = lv.px, vox = W.slicesOn() and lv.vox or nil }) then
    m.loading = now()
  end
end

-- - / = in the 3D view: the hologram's height (its tallest, x its width) - kept
-- in hud.cfg; the 3D view and the table both. Fine steps round 1 (a tenth
-- of a 5-wide table is half a block), coarse above 2
W.HEIGHTS = { 0.5, 0.75, 1, 1.1, 1.2, 1.3, 1.4, 1.5, 1.75, 2, 2.5, 3, 4, 6, 8 }
function W.setHeight(dir)
  local cur = tonumber(H.cfg.war.heightLimit) or 1
  local new = stepIn(W.HEIGHTS, cur, dir)
  if new == cur then return end
  H.cfg.war.heightLimit = new
  H.saveConfig()
  for _, md in ipairs({ W.preview or false, W.table.model or false }) do
    if md then
      md.heightLimit = new
      if md.vox then md:clear() end
      md:layout()
    end
  end
  local size = W.table.anchor and tonumber(W.table.anchor.size)
  H.toast(("HEIGHT: UP TO %s x ITS WIDTH%s"):format(tostring(new),
    size and (" (THE TABLE: %s BLOCKS)"):format(tostring(math.floor(new * size * 10 + 0.5) / 10)) or ""), H.C.yellow, 2)
end

-- [ / ] in the menu: less / more detail (kept in hud.cfg); the 3D view asks again
function W.setDetail(dir)
  local _, n = W.detail()
  local new = clamp(n + dir, 1, #W.DETAIL)
  if new == n then return end
  H.cfg.war.detail = new
  H.saveConfig()
  if W.preview then W.preview.maxObjects = W.objectsFor(W.DETAIL[new].squares, H.cfg.war.view3dObjects) end
  W.menu.dirty, W.menu.chosen = true, W.menu.piece ~= nil
  H.toast(("DETAIL %d OF %d%s"):format(new, #W.DETAIL, new >= 4 and " - MAY COST FPS" or ""), H.C.yellow, 2)
end

-- the most objects a model may use for so many squares (never under the setting)
function W.objectsFor(squares, floor) return math.max(floor or 0, math.floor(squares * 2.2)) end

-- What is at a spot (the cursor, a target): the map computer answers "point"
function W.askPoint(x, z)
  if not W.server or not H.modem then return end
  W.seq = W.seq + 1
  pcall(rednet.send, W.server, { op = "point", id = W.seq, x = math.floor(x), z = math.floor(z) }, H.PROTO_MAP)
end

-- The image square on screen
function W.geom()
  local L = H.L
  local S = math.floor(math.min(320, L.h - 130))
  return math.floor(L.w / 2 - S / 2), math.floor((L.h - S) / 2) - 6, S
end

-- (the glasses draw text after every other kind of 2D object - and rectangles
-- and images in no set order - so whatever must show over the map image is
-- text: the cursor, the marks, the areas' corners, the target)
function W.buildMenu()
  if W.gui then return end
  local x0, y0, S = W.geom()
  local g = { marks = {}, area = {}, tbl = {} }
  local function text(x, y, colour, size, centre)
    return H.make("Text", { gui = true, x = x, y = y, content = "", color = colour or H.C.white, shadow = true,
      fontSize = size, center = centre })
  end
  g.back = H.make("Rectangle", { gui = true, x = x0 + S / 2, y = y0 + S / 2, sizeX = S + 8, sizeY = S + 8,
    color = 0x000000, opacity = 0.65 })
  g.img = H.make("Texture", { gui = true, x = x0, y = y0, sizeX = S, sizeY = S, width = 8, height = 8 })
  for i = 1, 4 do g.tbl[i] = text(-100, -100, 0x6EE07A, 1, true) end
  for i = 1, 4 do g.area[i] = text(-100, -100, H.C.yellow, 1, true) end
  for i = 1, 40 do g.marks[i] = text(-100, -100, H.C.white, 1, true) end
  g.cursor = text(-100, -100, H.C.white, 1.5, true)
  g.target = text(-100, -100, 0xFF3B2F, 1.5, true)
  g.title = text(x0, y0 - 16, H.C.yellow)
  g.status = text(x0, y0 + S + 6, H.C.white)
  g.help = text(x0, y0 + S + 18, H.C.grey)
  g.help2 = text(x0, y0 + S + 30, H.C.grey)
  g.coord = text(0, 0, H.C.white)
  W.gui = g
  for _, o in ipairs({ g.back, g.img }) do if o then o:show(false) end end
end

function W.showMenu(on)
  local g = W.gui
  if not g then return end
  local function each(f)
    for _, k in ipairs({ "back", "img", "cursor", "target", "title", "status", "help", "help2", "coord", "ship" }) do f(g[k]) end
    for _, list in ipairs({ g.marks, g.area, g.tbl }) do for _, o in ipairs(list) do f(o) end end
  end
  if not on then each(function(o) if o then o:show(false) end end) end
end

-- A text mark centred on a GUI spot (a font line is 8 px x size tall)
local function mark(o, gx, gy, glyph, colour, size)
  if not o then return end
  size = size or 1
  o:set("Content", glyph) o:set("Color", colour) o:set("FontSize", size)
  o:pos(math.floor(gx), math.floor(gy - 4 * size))
  o:show(true)
end

-- New image from the map computer
function W.showOverview(msg)
  local m, g = W.menu, W.gui
  m.loading = nil
  local size = tonumber(msg.size)
  if not g or not g.img or not size or type(msg.px2) ~= "string" or #msg.px2 ~= 2 * size * size or type(msg.pal) ~= "table" then return end
  local pal = {}
  for i, c in ipairs(msg.pal) do
    c = tonumber(c) or 0
    if c >= 2 ^ 31 then c = c - 2 ^ 32 end             -- (signed 32-bit ARGB)
    pal[i] = c
  end
  local flat, px = {}, msg.px2
  for k = 1, size * size do
    local hi, lo = px:byte(2 * k - 1, 2 * k)
    flat[k] = pal[hi * 256 + lo] or -15723496
  end
  if g.img.v.width ~= size then                       -- (never resized: see Model:picture)
    local x0, y0, S = W.geom()
    W.removeObj(g.img)
    g.img = H.make("Texture", { gui = true, x = x0, y = y0, sizeX = S, sizeY = S, width = size, height = size })
    if not g.img then return end
  end
  local ok, err = pcall(g.img.o.setPixels, 1, 1, size, size, flat)
  if not ok then H.log("war table image: " .. tostring(err)) end
  m.shown = { cx = tonumber(msg.cx) or m.cx, cz = tonumber(msg.cz) or m.cz, span = tonumber(msg.span) or m.span,
    known = tonumber(msg.known), size = size }
  m.base, m.iconSig, m.iconRegions = flat, nil, {}
  W.paintIcons()
end

-- The stratagems' icons painted into the map image (an image on top of
-- another can end up under it; painted in, they always show). Repainted
-- when they change: the pixels under the old ones put back first
function W.paintIcons()
  local m, g = W.menu, W.gui
  local sh = m.shown
  if not (g and g.img and sh and m.base) then return end
  local size, span = sh.size, sh.span
  local x0, z0 = sh.cx - span / 2, sh.cz - span / 2
  local list, sig = {}, {}
  for _, p in ipairs(W.pins()) do
    -- (stratagems' icons, and the field's: helldivers' skulls, players' pawns, ships)
    local icon = p.kind == "beacon" and p.icon or p.ent and ("ent_" .. p.ent)
    if icon then
      local ix, iz = math.floor((p.x - x0) * size / span), math.floor((p.z - z0) * size / span)
      if ix >= 0 and iz >= 0 and ix < size and iz < size then
        list[#list + 1] = { ix = ix, iz = iz, icon = icon }
        sig[#sig + 1] = ix .. "," .. iz .. "," .. tostring(icon)
      end
    end
  end
  sig = table.concat(sig, ";")
  if sig == m.iconSig then return end
  m.iconSig = sig
  local half = W.ICON_PX / 2
  local function region(ix, iz)
    local rx, rz = math.max(0, ix - half), math.max(0, iz - half)
    return rx, rz, math.min(size, ix + half) - rx, math.min(size, iz + half) - rz
  end
  local function put(rx, rz, rw, rh, px)
    if rw > 0 and rh > 0 then pcall(g.img.o.setPixels, rx + 1, rz + 1, rw, rh, px) end
  end
  -- the ground back under the old icons
  for _, r in ipairs(m.iconRegions or {}) do
    local px = {}
    for z = r[2], r[2] + r[4] - 1 do
      for x = r[1], r[1] + r[3] - 1 do px[#px + 1] = m.base[z * size + x + 1] end
    end
    put(r[1], r[2], r[3], r[4], px)
  end
  m.iconRegions = {}
  for _, b in ipairs(list) do
    local icon = W.iconPixels(b.icon)
    if icon then
      local rx, rz, rw, rh = region(b.ix, b.iz)
      local px = {}
      for z = rz, rz + rh - 1 do
        for x = rx, rx + rw - 1 do
          local under = m.base[z * size + x + 1] or -15723496
          if under < 0 then under = under + 2 ^ 32 end
          local c = icon[(z - (b.iz - half)) * W.ICON_PX + (x - (b.ix - half)) + 1] or 0
          local a = math.floor(c / 2 ^ 24) / 255
          local out = 0xFF000000
          for _, sh8 in ipairs({ 65536, 256, 1 }) do
            local ci, ui = math.floor(c / sh8) % 256, math.floor(under / sh8) % 256
            out = out + math.floor(ci * a + ui * (1 - a) + 0.5) * sh8
          end
          px[#px + 1] = out - 2 ^ 32
        end
      end
      put(rx, rz, rw, rh, px)
      m.iconRegions[#m.iconRegions + 1] = { rx, rz, rw, rh }
    end
  end
end

-- The destroyer on the top-down map: its outline (one picture) at its real
-- size, turned with it - while its middle is on the map and it is not far
-- bigger than the map. (A screen picture turns clockwise about its top left)
function W.drawShip2D(on, S)
  local g, m = W.gui, W.menu
  local ship = on and W.shipOutline() or nil
  local gx, gy
  if ship then gx, gy = W.toGui(ship.x, ship.z) end
  local scale = S / m.span
  local len, wid = ship and ship.length * scale or 0, ship and ship.width * scale or 0
  if not (gx and len >= 4 and len <= S * W.SHIP_FITS) then
    if g.ship then g.ship:show(false) end
    return
  end
  if not g.ship then
    local pw, ph = W.iconSize("ent_destroyer")
    g.ship = H.make("Texture", { gui = true, x = 0, y = 0, sizeX = 1, sizeY = 1, width = pw, height = ph, enabled = false })
    if not g.ship then return end
    for _, f in ipairs({ "X", "Y", "RotZ", "SizeX", "SizeY" }) do
      local set = g.ship.o["set" .. f .. "LerpSteps"]
      if set then pcall(set, 0) end
    end
    g.ship:icon("ent_destroyer")
  end
  local th = atan2(ship.fx, -ship.fz)              -- (clockwise from up: the picture's bow to the ship's)
  local c, s = math.cos(th), math.sin(th)
  local hw, hh = wid / 2, len / 2
  g.ship:set("SizeX", wid) g.ship:set("SizeY", len)
  g.ship:set("RotZ", math.deg(th))
  g.ship:pos(gx - (hw * c - hh * s), gy - (hw * s + hh * c))
  g.ship:show(true)
end

W.EMPTY = "NOTHING RECORDED HERE YET - WALK IT WITH THE GLASSES OR EXPORT DISTANT HORIZONS FOR IT"

-- "minecraft:grass_block" -> "GRASS BLOCK"
function W.blockLabel(name)
  if not name then return "" end
  return (tostring(W.splitBlock(name)):gsub("^.-:", ""):gsub("_", " "):upper())
end

-- world x, z -> GUI on the top-down map (nil when off it)
function W.toGui(x, z)
  local m = W.menu
  local x0, y0, S = W.geom()
  local gx = x0 + S / 2 + (x - m.cx) / m.span * S
  local gy = y0 + S / 2 + (z - m.cz) / m.span * S
  if gx < x0 or gx > x0 + S or gy < y0 or gy > y0 + S then return nil end
  return gx, gy
end

function W.fromGui(gx, gy)
  local m = W.menu
  local x0, y0, S = W.geom()
  return m.cx + (gx - x0 - S / 2) / S * m.span, m.cz + (gy - y0 - S / 2) / S * m.span
end

-- A world square's 4 corners marked (text, so over the image; ASCII only:
-- ComputerCraft hands the glasses text a byte a letter)
local CORNERS = { "+", "+", "+", "+" }
local function outline(list, x1, z1, x2, z2, on, colour)
  local ax, ay = W.toGui(x1, z1)
  local bx, by = W.toGui(x2, z2)
  local spots = on and ax and bx and { { ax, ay }, { bx, ay }, { ax, by }, { bx, by } } or {}
  for i, o in ipairs(list) do
    local s = spots[i]
    if s and o then mark(o, s[1], s[2], CORNERS[i], colour, 1.5) elseif o then o:show(false) end
  end
end

function W.drawMenu()
  local m, g = W.menu, W.gui
  if not g then return end
  local x0, y0, S = W.geom()
  local over = m.screen == "overview"
  local three = m.screen == "3d"
  -- the image (moved with a drag until the new one comes)
  if g.back then g.back:show(over) end
  if g.img then
    local sh = m.shown
    if sh and over then
      local scale = sh.span / m.span
      g.img:set("SizeX", math.floor(S * scale)) g.img:set("SizeY", math.floor(S * scale))
      g.img:pos(math.floor(x0 + S / 2 + (sh.cx - m.cx) / m.span * S - S * scale / 2),
        math.floor(y0 + S / 2 + (sh.cz - m.cz) / m.span * S - S * scale / 2))
    end
    g.img:show(over and sh ~= nil)
  end
  -- who and what is on it (text: shows over the image); stratagems: their
  -- icons are painted into the image, their names written beside them
  local used = 0
  if over then
    for _, p in ipairs(W.pins()) do
      local gx, gy = W.toGui(p.x, p.z)
      if gx and used + 1 < #g.marks then
        if p.kind == "beacon" then
          used = used + 1
          local o = g.marks[used]
          mark(o, gx, gy + 9, p.label .. (p.status and (" - " .. tostring(p.status)) or ""), p.colour, 0.6)
        elseif p.ent then
          -- (its icon is painted into the image: just its tag / name above it)
          if p.label then
            used = used + 1
            mark(g.marks[used], gx, gy - 9, p.label, p.colour, W.NAME_SCALE)
          end
        elseif p.kind ~= "target" then
          used = used + 1
          mark(g.marks[used], gx, gy, p.glyph, p.colour, (p.kind == "me" or p.kind == "diver") and 1.2 or 1)
        end
      end
    end
  end
  for i = used + 1, #g.marks do
    if g.marks[i] then g.marks[i]:show(false) end
  end
  W.drawShip2D(over, S)
  -- the table's area (green corners) and the 3D view's (yellow)
  local tv = W.table.data
  if tv then
    outline(g.tbl, tv.x0, tv.z0, tv.x0 + tv.size, tv.z0 + tv.size, over, 0x6EE07A)
  else
    outline(g.tbl, 0, 0, 0, 0, false)
  end
  local v = m.view
  local half = v.area / 2
  outline(g.area, v.cx - half, v.cz - half, v.cx + half, v.cz + half, over and m.piece ~= nil, H.C.yellow)
  -- the cursor: a cross, and where it is - x y z and the block there
  local onMap = over and m.cur.x >= x0 and m.cur.x <= x0 + S and m.cur.y >= y0 and m.cur.y <= y0 + S
  if over or three then mark(g.cursor, m.cur.x, m.cur.y, "+", H.C.white, 2) else g.cursor:show(false) end
  local h3 = three and m.hover3d
  if h3 then
    g.coord:set("Content", ("%d %d %d"):format(h3.x, h3.y or 0, h3.z))
    g.coord:pos(m.cur.x + 9, m.cur.y + 6)
  elseif onMap then
    local wx, wz = W.fromGui(m.cur.x, m.cur.y)
    wx, wz = math.floor(wx), math.floor(wz)
    local h = m.hover
    local here = h and h.x == wx and h.z == wz
    g.coord:set("Content", here and h.y and ("%d %d %d  %s"):format(wx, h.y, wz, W.blockLabel(h.name))
      or ("%d %d"):format(wx, wz))
    g.coord:pos(m.cur.x + 9, m.cur.y + 6)
  end
  g.coord:show(onMap or h3 ~= nil and h3 ~= false)
  -- the target picked for a stratagem
  local t = m.target
  local tgx, tgy
  if t and over then tgx, tgy = W.toGui(t.x + 0.5, t.z + 0.5) end
  if tgx then mark(g.target, tgx, tgy, "X", 0xFF3B2F, 1.5) else g.target:show(false) end
  -- words
  local wait = m.loading and now() - m.loading < 45          -- (a 2 km view takes storage a while)
  if m.setup then
    g.title:set("Content", "WAR TABLE - PLACING THE TABLE")
    g.status:set("Content", ("%.1f BLOCKS ACROSS%s"):format(m.setup.size, m.setup.mode == "world" and "  (FIXED IN THE WORLD: NO SHIP POSITION)" or ""))
    g.help:set("Content", "DRAG: SLIDE IT   RIGHT-DRAG: UP / DOWN   SCROLL: BIGGER / SMALLER   MIDDLE-CLICK or [ ]: TURN")
    g.help2:set("Content", "HOME: TO WHERE YOU STAND   ARROWS / PAGE UP / DOWN: FINE STEPS   ENTER: DONE   ESC: DONE AND LEAVE")
  elseif t then
    g.title:set("Content", "WAR TABLE - CALL A STRATAGEM ON THE MAP")
    g.status:set("Content", t.y and ("TARGET %d %d %d  %s - TYPE ITS CODE WITH THE ARROWS"):format(t.x, t.y, t.z, W.blockLabel(t.name))
      or ("TARGET %d %d - FINDING THE GROUND..."):format(t.x, t.z))
    g.help:set("Content", "RIGHT-CLICK: ANOTHER TARGET   BACKSPACE: NO TARGET   SCROLL / DRAG: MOVE THE MAP")
    g.help2:set("Content", "ESC: LEAVE")
  elseif over then
    g.title:set("Content", ("MAP - %d BLOCKS ACROSS"):format(m.span))
    g.status:set("Content", m.input ~= "" and ("GO TO: " .. m.input .. "_") or wait and "LOADING..." or
      (not W.server and "NO MAP COMPUTER") or (m.shown and m.shown.known == 0 and W.EMPTY) or "")
    g.help:set("Content", "DRAG: MOVE   SCROLL: ZOOM   CLICK: SEE IT IN 3D   RIGHT-CLICK: CALL A STRATAGEM THERE")
    g.help2:set("Content", "TYPE X Z + ENTER: GO TO   F: FRIENDLY / HOSTILE   I: ICON   L: RADAR LOCK   T: PLACE THE TABLE   ESC: LEAVE")
  else
    local pv = W.preview
    local _, dn = W.detail()
    g.title:set("Content", ("%s - 3D, %d BLOCKS ACROSS%s   DETAIL %d/%d ([ ])   %s (V)"):format(
      m.fromTable and "WAR TABLE" or "MAP", v.area,
      m.piece and not m.piece.vox and (", %d SQUARES"):format(#m.piece.cells) or "", dn, #W.DETAIL,
      W.slicesOn() and "SLICES" or "SQUARES"))
    local heights = pv and pv.floor and ("   HEIGHTS Y %d TO %d%s"):format(math.floor(pv.floor + 1), math.floor(pv.ceil),
      pv.cut and " (TALLER IS CUT OFF)" or "") or ""
    g.status:set("Content", wait and "LOADING..." or (m.piece and m.piece.known == 0 and W.EMPTY)
      or ("%d %d%s"):format(math.floor(v.cx), math.floor(v.cz), heights))
    g.help:set("Content", "LEFT-DRAG: TURN / TILT   RIGHT-DRAG: MOVE   SCROLL: ZOOM   PAGE UP / DOWN: HIGHER / LOWER   - =: TALLER   TAB: TOP-DOWN")
    g.help2:set("Content", "RIGHT-CLICK: CALL A STRATAGEM THERE   F: FRIENDLY / HOSTILE   I: ICON   L: RADAR LOCK   ENTER: PUT IT ON THE WAR TABLE   ESC: LEAVE (TABLE UNCHANGED)")
  end
  -- (the 3D screen's words sit above and below the model)
  local ty = three and math.floor(H.L.h * 0.12) or y0 - 16
  local by = three and math.floor(H.L.h * 0.80) or y0 + S + 6
  g.title:pos(x0, ty) g.status:pos(x0, by) g.help:pos(x0, by + 12) g.help2:pos(x0, by + 24)
  for _, k in ipairs({ "title", "status", "help", "help2" }) do g[k]:show(true) end
end

-- The 3D view: in front of the eye (as big as the top-down map), turned and
-- tilted as dragged
W.PREVIEW_AT = { 0, -0.25, -1.8 }

function W.previewTick(budget)
  local pv, m = W.preview, W.menu
  if not pv then return 0 end
  local want = m.open and m.screen == "3d"
  pv:setVisible(want)
  if want then
    pv:setLift(m.view.lift or 0)
    pv:setFrame(W.PREVIEW_AT, W.mul(W.rotX(m.view.tilt), W.rotY(m.view.yaw)))
  end
  local used = pv:step(budget)
  -- who and what is on the field, 3 times a second (and gone with the view)
  W.previewPinsAt = W.pinsTick(pv, want, W.previewPinsAt, 0.3)
  return used
end

-- A model's pins (who and what is on the field): gone at once when the model
-- is hidden - a hidden model never finishes building, so waiting for that
-- left them floating on the screen; while shown, drawn again every `every` s
-- once it is built. -> when they were last drawn
function W.pinsTick(md, want, stamp, every)
  if not want then
    if md.pinsShown ~= false then
      md.pinsShown = false
      md:drawPins({})
    end
    return stamp
  end
  if not md:busy() and (now() - (stamp or -100) > every or md.pinsShown ~= true) then
    md.pinsShown = true
    md:drawPins(W.pins())
    return now()
  end
  return stamp
end

-- Each frame (from the HUD)
function W.frame()
  local budget = H.cfg.war.perFrame
  local m = W.menu
  pcall(W.holoTick)
  if m.open then
    pcall(W.drawMenu)
    -- a drag that moved the map: ask again (at most twice a second)
    if m.dirty and now() - (m.askedAt or -100) > 0.5 and not (m.drag and m.drag.b) then
      m.dirty, m.askedAt = nil, now()
      if m.screen == "overview" then W.askOverview() else W.askView() end
    end
    if m.screen == "overview" and now() - (m.iconsAt or -100) > 0.5 then
      m.iconsAt = now()
      W.paintIcons()
    end
    -- in 3D: the block under the cursor (a ray into the model)
    if m.screen == "3d" and W.preview and now() - (m.pickAt or -100) > 0.15
      and (not m.pickCur or m.pickCur[1] ~= m.cur.x or m.pickCur[2] ~= m.cur.y or W.preview:busy()) then
      m.pickAt, m.pickCur = now(), { m.cur.x, m.cur.y }
      local px, pz, py = W.preview:pick(m.cur.x, m.cur.y)
      m.hover3d = px and { x = px, y = py, z = pz } or nil
    end
    -- the cursor resting on a block: ask what is there
    local x0, y0, S = W.geom()
    if m.screen == "overview" and m.cur.x >= x0 and m.cur.x <= x0 + S and m.cur.y >= y0 and m.cur.y <= y0 + S then
      local wx, wz = W.fromGui(m.cur.x, m.cur.y)
      wx, wz = math.floor(wx), math.floor(wz)
      local hw = m.hoverWant
      if not hw or hw.x ~= wx or hw.z ~= wz then
        m.hoverWant = { x = wx, z = wz, at = now() }
      elseif now() - hw.at > 0.25 and not (m.hoverAsk and m.hoverAsk.x == wx and m.hoverAsk.z == wz) then
        m.hoverAsk = { x = wx, z = wz }
        W.askPoint(wx, wz)
      end
    end
  end
  budget = budget - W.previewTick(budget)
  budget = budget - W.cornerTick(math.max(0, budget))
  W.tableTick(math.max(0, budget))
end

-- The overlay was cleared (the HUD rebuilt it): every object is gone
function W.reset()
  W.gui, W.preview = nil, nil
  W.table.model, W.table.plate = nil, nil
  W.corner.model = nil                       -- (made again from its piece)
  if W.menu.open then W.buildMenu() end
  if W.menu.piece then
    W.preview = W.menu.piece.vox and W.newVoxels(W.previewOpts()) or W.newModel(W.previewOpts())
    W.preview:setData(W.menu.piece)
  end
  if W.menu.shown then W.menu.shown = nil W.menu.dirty = true end
end

---------------------------------------------------------------- input

function W.to3d(x, z)
  local m = W.menu
  m.screen = "3d"
  m.view.cx, m.view.cz = math.floor(x), math.floor(z)
  -- show about a quarter of what the top-down map showed
  m.view.area = stepIn(W.AREAS, m.span / 4, 0)
  m.chosen = true
  W.askView()
end

-- player_mouse_move dx dy / _click b / _up b / _scroll dy dx (b: 1 left, 2 right, 3 middle)
function W.onMouse(e, a, b)
  local m = W.menu
  if not m.open then return end
  if m.setup then return W.setupMouse(e, a, b) end
  if e == "player_mouse_move" then
    local dx, dy = tonumber(a) or 0, tonumber(b) or 0
    -- (the first move after the mouse is taken comes measured from the
    -- window's middle in pixels, not GUI units: a huge jump - not a move)
    if math.abs(dx) > H.L.w / 2 or math.abs(dy) > H.L.h / 2 then return end
    m.cur.x = clamp(m.cur.x + dx, 0, H.L.w)
    m.cur.y = clamp(m.cur.y + dy, 0, H.L.h)
    local d = m.drag
    if d then
      d.moved = d.moved + math.abs(dx) + math.abs(dy)
      if m.screen == "overview" and d.b == 1 then
        local _, _, S = W.geom()
        m.cx, m.cz = m.cx - dx / S * m.span, m.cz - dy / S * m.span
        m.dirty = true
      elseif m.screen == "3d" and d.b == 1 then
        m.view.yaw = (m.view.yaw + dx * 0.5) % 360
        m.view.tilt = clamp(m.view.tilt + dy * 0.35, 10, 90)
      elseif m.screen == "3d" and d.b == 2 then
        -- move the area: the drag's direction turned into the map's
        local per = m.view.area / 240
        local yaw = math.rad(-m.view.yaw)
        local mx, mz = math.cos(yaw) * dx + math.sin(yaw) * dy, -math.sin(yaw) * dx + math.cos(yaw) * dy
        m.view.cx, m.view.cz = m.view.cx - mx * per, m.view.cz - mz * per
        m.dirty, m.chosen = true, true
      end
    end
  elseif e == "player_mouse_click" then
    local btn = tonumber(a)
    if btn == 3 then return W.toggleScreen() end
    m.drag = { b = btn, moved = 0 }
  elseif e == "player_mouse_up" then
    local d = m.drag
    m.drag = nil
    local x0, y0, S = W.geom()
    local onMap = m.cur.x >= x0 and m.cur.x <= x0 + S and m.cur.y >= y0 and m.cur.y <= y0 + S
    if d and d.b == 1 and d.moved < 4 and m.screen == "overview" then
      if onMap then W.to3d(W.fromGui(m.cur.x, m.cur.y)) end
    elseif d and d.b == 2 and d.moved < 4 and m.screen == "overview" then
      if onMap then W.setTarget(W.fromGui(m.cur.x, m.cur.y)) end
    elseif d and d.b == 2 and d.moved < 4 and m.screen == "3d" and W.preview then
      -- a right-click (not a drag) on the 3D view: the block under the cursor is the target
      local px, pz = W.preview:pick(m.cur.x, m.cur.y)
      if px then W.setTarget(px, pz) else H.toast("NOTHING THERE TO TARGET", H.C.red, 2) end
    elseif d and d.b == 1 and m.screen == "3d" and d.moved > 0 then
      m.chosen = true
    end
  elseif e == "player_mouse_scroll" then
    local dy = tonumber(a) or 0                           -- (the glasses send the wheel's y first)
    if dy == 0 then return end
    local dir = dy > 0 and -1 or 1                        -- wheel up = closer
    if m.screen == "overview" then
      local s = stepIn(W.SPANS, m.span, dir)
      if s ~= m.span then m.span, m.dirty = s, true end
    else
      local a = stepIn(W.AREAS, m.view.area, dir)
      if a ~= m.view.area then m.view.area, m.dirty, m.chosen = a, true, true end
    end
  end
end

function W.toggleScreen()
  local m = W.menu
  if m.screen == "overview" then
    if m.piece then m.screen = "3d" else W.to3d(m.cx, m.cz) end
  else
    m.screen = "overview"
    m.cx, m.cz = m.view.cx, m.view.cz
    m.dirty = true
  end
end

-- Keys while the menu is up (held = a key repeat)
function W.onKey(k, held)
  local m = W.menu
  if m.setup then return W.setupKey(k) end
  if held then return end
  -- a target picked: the arrows type a stratagem's code (as the HUD's menu)
  if m.target and H.ARROWS[k] then
    local spot = W.targetPoint()
    if not spot then return H.toast("FINDING THE GROUND THERE - TRY AGAIN", H.C.red, 2) end
    local r = H.addArrow(H.ARROWS[k], spot)
    if r == "called" then
      m.target = nil                       -- (called - its beacon shows on the map: done with this target)
      H.closeMenu()
    end
    return
  end
  if m.target and k == keys.backspace then
    if H.ui.input ~= "" then
      H.ui.input = ""
      H.menuUpdate()
    else
      m.target = nil
      H.closeMenu()
    end
    return
  end
  if k == keys.tab then return W.toggleScreen() end
  if k == keys.t then return W.startSetup() end
  if keys.h and k == keys.h and H.ST then return W.startSetup("status") end
  if k == keys.l then return W.toggleLock() end
  if k == keys.leftBracket then return W.setDetail(-1) end
  if k == keys.rightBracket then return W.setDetail(1) end
  if (k == keys.minus or k == keys.equals) and m.screen == "3d" then return W.setHeight(k == keys.equals and 1 or -1) end
  if k == keys.f then return W.toggleFriend() end
  if k == keys.i then return W.designate() end
  if k == keys.v and m.screen == "3d" then
    -- the other renderer: slices (every block) / squares (tops and sides)
    H.cfg.war.renderer = W.slicesOn() and "squares" or "slices"
    H.saveConfig()
    m.dirty = true
    H.toast(W.slicesOn() and "3D: SLICES - EVERY BLOCK" or "3D: SQUARES - TOPS AND SIDES", H.C.yellow, 2)
    return
  end
  if k == keys.enter or k == keys.numPadEnter then
    local x, z = m.input:match("^%s*(%-?%d+)[%s,]+(%-?%d+)%s*$")
    if x then
      m.input = ""
      if m.screen == "overview" then
        m.cx, m.cz, m.dirty = tonumber(x), tonumber(z), true
      else
        m.view.cx, m.view.cz, m.dirty, m.chosen = tonumber(x), tonumber(z), true, true
      end
    elseif m.screen == "3d" then
      W.sendTable()
    else
      H.toast("ENTER PUTS THE 3D VIEW ON THE WAR TABLE - CLICK THE MAP TO SEE IT IN 3D FIRST", H.C.yellow, 3)
    end
  elseif k == keys.backspace then
    m.input = m.input:sub(1, -2)
  elseif (k == keys.pageUp or k == keys.pageDown) and m.screen == "3d" then
    -- the heights shown, an eighth of the width at a time
    m.view.lift = (m.view.lift or 0) + (k == keys.pageUp and 1 or -1) * math.max(4, m.view.area / 8)
    m.chosen = true
  end
end

function W.onChar(ch)
  local m = W.menu
  if not m.open or m.setup then return end
  if ch:match("[%d%-%s,]") and #m.input < 16 then m.input = m.input .. ch end
end

---------------------------------------------------------------- placing the table

-- T: place the table (H: the status hologram, status.lua - placed the same
-- way). Look at where it is (or should be) first: the mouse moves it now,
-- not your head
function W.startSetup(kind)
  local m, me = W.menu, H.me
  if not me then return end
  m.setupFor = kind == "status" and H.ST and "status" or "table"
  local current = m.setupFor == "status" and H.ST.anchor or W.table.anchor
  m.setup = current and copy(current) or W.anchorHere(me)
  if not current and m.setupFor == "status" then
    -- (a new hologram: its own size, low enough that the ship's top is just below eye level)
    m.setup.size = H.ST.SIZE
    W.nudge(m.setup, { 0, H.ST.standHeight(m.setup.size) - 0.9, 0 })
  end
  m.drag = nil
  if W.preview then W.preview:setVisible(false) end
  local what = m.setupFor == "status" and "THE STATUS HOLOGRAM" or "THE TABLE"
  H.toast(m.setup.mode == "ship" and ("PLACING " .. what .. " (ON THE SHIP)")
    or ("PLACING " .. what .. " (NO SHIP POSITION: FIXED IN THE WORLD)"), H.C.yellow, 3)
end

W.SLIDE = 0.01        -- blocks the table moves a pixel of mouse drag

-- The mouse while placing the table: left-drag slides it (up = away from
-- you), right-drag raises / lowers it, scroll = bigger / smaller, middle
-- click = a quarter turn
function W.setupMouse(e, a, b)
  local m, me = W.menu, H.me
  local s = m.setup
  if not s or not me then return end
  if e == "player_mouse_click" then
    local btn = tonumber(a)
    if btn == 3 then
      s.yaw = (W.snapYaw(s.yaw) - 90) % 360
    else
      m.drag = { b = btn, moved = 0 }
    end
  elseif e == "player_mouse_up" then
    m.drag = nil
  elseif e == "player_mouse_scroll" then
    local dy = tonumber(a) or 0
    if dy ~= 0 then s.size = clamp(s.size + (dy > 0 and 0.25 or -0.25), 0.5, 16) end
  elseif e == "player_mouse_move" and m.drag then
    local dx, dy = tonumber(a) or 0, tonumber(b) or 0
    if math.abs(dx) > H.L.w / 2 or math.abs(dy) > H.L.h / 2 then return end     -- (the bogus first move)
    local y = math.rad(me.yaw or 0)
    local fwd, right = { -math.sin(y), 0, math.cos(y) }, { -math.cos(y), 0, -math.sin(y) }
    local k = W.SLIDE
    if m.drag.b == 1 then
      W.nudge(s, { (right[1] * dx - fwd[1] * dy) * k, 0, (right[3] * dx - fwd[3] * dy) * k })
    elseif m.drag.b == 2 then
      W.nudge(s, { 0, -dy * k * 0.5, 0 })
    end
  end
end

-- Move the table by a world step (the ship's frame on the ship)
function W.nudge(a, dw)
  if a.mode == "ship" then
    local d = W.toShip(dw, true)
    if not d then return end
    a.rel = { a.rel[1] + d[1], a.rel[2] + d[2], a.rel[3] + d[3] }
  else
    a.world = { a.world[1] + dw[1], a.world[2] + dw[2], a.world[3] + dw[3] }
  end
end

function W.setupKey(k)
  local m, me = W.menu, H.me
  local a = m.setup
  if not a or not me then return end
  local y = math.rad(me.yaw or 0)
  local fwd, right = { -math.sin(y), 0, math.cos(y) }, { -math.cos(y), 0, -math.sin(y) }
  local step = 0.1
  if k == keys.up then W.nudge(a, { fwd[1] * step, 0, fwd[3] * step })
  elseif k == keys.down then W.nudge(a, { -fwd[1] * step, 0, -fwd[3] * step })
  elseif k == keys.right then W.nudge(a, { right[1] * step, 0, right[3] * step })
  elseif k == keys.left then W.nudge(a, { -right[1] * step, 0, -right[3] * step })
  elseif k == keys.pageUp then W.nudge(a, { 0, 0.05, 0 })
  elseif k == keys.pageDown then W.nudge(a, { 0, -0.05, 0 })
  elseif k == keys.leftBracket then a.yaw = (W.snapYaw(a.yaw) + 90) % 360
  elseif k == keys.rightBracket then a.yaw = (W.snapYaw(a.yaw) - 90) % 360
  elseif k == keys.minus then a.size = clamp(a.size - 0.25, 0.5, 16)
  elseif k == keys.equals then a.size = clamp(a.size + 0.25, 0.5, 16)
  elseif k == keys.home then
    -- (to you: just ahead of where you stand, at table height - its size and turn kept)
    local here = W.anchorHere(me)
    a.mode, a.rel, a.world = here.mode, here.rel, here.world
  elseif k == keys.enter or k == keys.numPadEnter then
    W.finishSetup()
    m.setup, m.drag = nil, nil
  end
end

function W.finishSetup()
  local a = W.menu.setup
  if not a then return end
  if W.menu.setupFor == "status" and H.ST then
    W.menu.setupFor = nil
    return H.ST.placed(copy(a))
  end
  W.table.anchor = copy(a)
  if W.server then
    pcall(rednet.send, W.server, { op = "setanchor", anchor = a }, H.PROTO_MAP)
    H.toast("TABLE PLACED", H.C.yellow, 2)
  else
    H.toast("TABLE PLACED ON THESE GLASSES ONLY (NO MAP COMPUTER)", H.C.red, 4)
  end
end

return W
end
