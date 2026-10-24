--[[
warmap.lua - the war table's computers                                v1.14.0
One program for both; the modems pick the job (warmap.cfg role = "map" or
"store" forces one):

  MAP computer (52: ender modem + wired modem) - "warmap" on hd2.map
    - passes every helldiver's terrain scans (hd2.team) on to storage
    - answers the glasses: top-down map images, 3D map pieces
    - keeps the war table - what it shows and where it stands - and tells
      every pair of glasses when it changes; scans inside the table's area
      refresh it
  STORAGE computer (53: wired modem only) - "warstore" on hd2.store
    - keeps every scan (each column's top block, in 32x32-block tiles in
      scan/) and the Distant Horizons terrain (dh/*.bin, made on the PC by
      tools/dhmap.py), and answers "the ground over this area" for the map
      computer: a helldiver's scan wins, else the finest Distant Horizons layer

Wire the two together (wired modems + cable, nothing else on that cable).
Files: warmap.cfg (settings), warmap.log, table.dat (map), scan/ + dh/ (storage)
On a server (warmap.cfg remote = "owner/repo") both download what the PC's
dhwatch.py puts on GitHub instead: storage dh/, the map its colours.
]]

local ARG = ...
local W = { VERSION = "1.15.3" }
W.PROTO_MAP, W.PROTO_STORE = "hd2.map", "hd2.store"
W.PROTO_TEAM = "hd2.team"
W.HOST_MAP, W.HOST_STORE = "warmap", "warstore"
W.FILES = { cfg = "warmap.cfg", log = "warmap.log", table = "table.dat", scan = "scan", dh = "dh" }
W.TILE = 32
W.Y0 = 2048                 -- heights are sent as y + 2048 in two bytes (0 = unknown)

W.DEFAULTS = {
  role = "auto",            -- "map", "store" or "auto" (ender modem = map)
  tableSquares = 2400,      -- the table's 3D squares at most (each pair of glasses draws ~2 objects a square)
  tableRefresh = 10,        -- s: at most this often, new scans inside the table's area redraw it
  imageSamples = 1,         -- looks per pixel side for the top-down map (256 pixels: 1 is plenty; more = slower)
  viewSamples = 4,          -- looks per cell side for 3D pieces
  keepFree = 60000,         -- bytes: storage stops making new scan tiles below this much free space
  maxTiles = 128,           -- scan tiles kept in memory
  runTiles = 48,            -- full-detail tiles kept unpacked in memory
  gap = 4,                  -- 3D: runs closer than this many blocks of air are joined (a building's floors)
  maxRuns = 4,              -- 3D: at most this many separate runs a column (the ground always kept)
  fineUpTo = 8,             -- 3D: every block's runs up to this many blocks a column (more: one height a cell)
  storeWait = 40,           -- s to wait for storage (a 512-pixel map of every block, a 2 km 3D view: a few to many)
  remote = "",              -- servers: GitHub "owner/repo" the PC's dhwatch.py puts the map in ("" = singleplayer)
  remoteBranch = "main",
  remoteEvery = 60,         -- s between looks for a new one
}

W.MAP_COLOURS = {
  { "water", 0x3A6FD8 }, { "lava", 0xFF6A00 }, { "grass_block", 0x5E9E36 }, { "moss", 0x5E9E36 },
  { "leaves", 0x2F7A2F }, { "log", 0x6B4F2A }, { "wood", 0x8A6A3F }, { "plank", 0xA88654 },
  { "sand", 0xDCCB8C }, { "snow", 0xF2F2F2 }, { "ice", 0x9CC8FF }, { "dirt", 0x86603A },
  { "mud", 0x5A4A3A }, { "gravel", 0x8A8580 }, { "deepslate", 0x505058 }, { "stone", 0x8C8C8C },
  { "bedrock", 0x333333 }, { "glass", 0xBFE8F0 }, { "concrete", 0xB0B0B0 }, { "terracotta", 0xA8664A },
  { "brick", 0x9A4A3A }, { "iron", 0xC8C8C8 }, { "copper", 0xC07040 }, { "netherrack", 0x7A2A2A },
}
W.GREY, W.UNKNOWN = 0x9A9A9A, 0x101418
W.SHADES = { 0.68, 0.84, 1.0, 1.14, 1.28 }

local now = os.clock
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function copy(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = copy(v) end
  return c
end

function W.log(text)
  pcall(function()
    if fs.exists(W.FILES.log) and fs.getSize(W.FILES.log) > 32768 then
      if fs.exists(W.FILES.log .. ".old") then fs.delete(W.FILES.log .. ".old") end
      fs.move(W.FILES.log, W.FILES.log .. ".old")
    end
    local h = fs.open(W.FILES.log, "a")
    h.writeLine(("%8.1f %s"):format(now(), tostring(text)))
    h.close()
  end)
end

function W.loadConfig()
  local cfg
  if fs.exists(W.FILES.cfg) then
    local h = fs.open(W.FILES.cfg, "r")
    cfg = textutils.unserialize(h.readAll())
    h.close()
  end
  if type(cfg) ~= "table" then cfg = {} end
  for k, v in pairs(W.DEFAULTS) do
    if cfg[k] == nil then cfg[k] = copy(v) end
  end
  W.cfg = cfg
  if not fs.exists(W.FILES.cfg) then
    pcall(function()
      local h = fs.open(W.FILES.cfg, "w")
      h.write("-- warmap.cfg - settings for warmap.lua " .. W.VERSION .. ". Edit, save, then reboot.\n")
      h.write(textutils.serialize(cfg))
      h.close()
    end)
  end
end

-- colours.txt (tools/blockcolours.py: each block's texture, averaged) - the map computer's
W.colours = {}
function W.loadColours()
  W.colours = {}
  if not fs.exists("colours.txt") then return 0 end
  local h = fs.open("colours.txt", "r")
  local n = 0
  for line in h.readAll():gmatch("[^\n]+") do
    local name, hex = line:match("^(%S+)%s+(%x%x%x%x%x%x)")
    if name then
      W.colours[name] = tonumber(hex, 16)
      n = n + 1
    end
  end
  h.close()
  return n
end

-- tiles.txt (tools/blockcolours.py): each block's texture, its top then its
-- side (a log's bark, grass's dirt edge), at 8 x 8 (older files: 4 x 4, top
-- only), for the glasses' close-up pictures -> RGB strings (3 bytes a pixel)
W.tiles, W.sideTiles = {}, {}
local function tileBytes(list)
  local bytes = {}
  for hex in (list or ""):gmatch("%x%x%x%x%x%x") do
    local v = tonumber(hex, 16)
    bytes[#bytes + 1] = string.char(math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256)
  end
  if #bytes == 16 or #bytes == 64 then return table.concat(bytes) end
end

function W.loadTiles()
  W.tiles, W.sideTiles = {}, {}
  if not fs.exists("tiles.txt") then return 0 end
  local h = fs.open("tiles.txt", "r")
  local n = 0
  for line in h.readAll():gmatch("[^\n]+") do
    local name, top, side = line:match("^(%S+)%s+(%S+)%s*(%S*)")
    local t = name and tileBytes(top)
    if t then
      W.tiles[name] = t
      W.sideTiles[name] = tileBytes(side)
      n = n + 1
    end
  end
  h.close()
  return n
end

-- "minecraft:oak_stairs|facing=east" -> "minecraft:oak_stairs" (colours are a block's, not a state's)
function W.base(name) return (tostring(name):match("^[^|]*")) end

local colourCache = {}
function W.colour(name)
  local n = W.base(name)
  local c = W.colours[n] or colourCache[n]
  if c then return c end
  c = W.GREY
  for _, e in ipairs(W.MAP_COLOURS) do
    if n:find(e[1], 1, true) then c = e[2] break end
  end
  colourCache[n] = c
  return c
end

local function u16(v) return string.char(math.floor(v / 256) % 256, v % 256) end

-- A list of byte values -> a string (in chunks: string.char takes so many at once)
function W.bytes(list)
  local parts = {}
  for i = 1, #list, 2048 do parts[#parts + 1] = string.char(table.unpack(list, i, math.min(#list, i + 2047))) end
  return table.concat(parts)
end

---------------------------------------------------------------- inflate
-- Raw DEFLATE (RFC 1951) -> string: the full-detail terrain tiles are
-- packed on the PC with zlib. After zlib's puff.c (arithmetic only - no bit
-- operators in this Lua)

local P2 = {}
for i = 0, 32 do P2[i] = 2 ^ i end
local LBASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEXT = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DBASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
  4097, 6145, 8193, 12289, 16385, 24577 }
local DEXT = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

-- canonical Huffman code from code lengths[0..n-1]
local function huffman(lengths, n)
  local count, symbol, offs = {}, {}, {}
  for len = 0, 15 do count[len] = 0 end
  for s = 0, n - 1 do count[lengths[s] or 0] = count[lengths[s] or 0] + 1 end
  offs[1] = 0
  for len = 1, 14 do offs[len + 1] = offs[len] + count[len] end
  for s = 0, n - 1 do
    local l = lengths[s] or 0
    if l ~= 0 then
      symbol[offs[l]] = s
      offs[l] = offs[l] + 1
    end
  end
  return { count = count, symbol = symbol }
end

local FIXED_LEN, FIXED_DIST
do
  local l = {}
  for s = 0, 143 do l[s] = 8 end
  for s = 144, 255 do l[s] = 9 end
  for s = 256, 279 do l[s] = 7 end
  for s = 280, 287 do l[s] = 8 end
  FIXED_LEN = huffman(l, 288)
  local d = {}
  for s = 0, 29 do d[s] = 5 end
  FIXED_DIST = huffman(d, 30)
end

function W.inflate(src)
  local pos, bitbuf, bitcnt = 1, 0, 0
  local out, n = {}, 0
  local byte = string.byte
  local tmove = table.move                   -- (nil in a Lua without it: copied byte by byte)
  local function bits(k)
    while bitcnt < k do
      local b = byte(src, pos)
      if not b then error("inflate: the data ends early", 0) end
      pos = pos + 1
      bitbuf = bitbuf + b * P2[bitcnt]
      bitcnt = bitcnt + 8
    end
    local v = bitbuf % P2[k]
    bitbuf = (bitbuf - v) / P2[k]
    bitcnt = bitcnt - k
    return v
  end
  local function decode(h)
    local code, first, index = 0, 0, 0
    local count = h.count
    for len = 1, 15 do
      if bitcnt == 0 then
        local b = byte(src, pos)
        if not b then error("inflate: the data ends early", 0) end
        pos = pos + 1
        bitbuf, bitcnt = b, 8
      end
      local bit = bitbuf % 2
      bitbuf = (bitbuf - bit) / 2
      bitcnt = bitcnt - 1
      code = code + bit
      local c = count[len]
      if code - c < first then return h.symbol[index + code - first] end
      index = index + c
      first = (first + c) * 2
      code = code * 2
    end
    error("inflate: bad code", 0)
  end
  local function codes(lencode, distcode)
    while true do
      local sym = decode(lencode)
      if sym < 256 then
        n = n + 1
        out[n] = sym
      elseif sym == 256 then
        return
      else
        sym = sym - 256
        if sym > 29 then error("inflate: bad length", 0) end
        local len = LBASE[sym] + bits(LEXT[sym])
        local ds = decode(distcode)
        if ds > 29 then error("inflate: bad distance", 0) end
        local from = n - (DBASE[ds + 1] + bits(DEXT[ds + 1]))
        if from < 0 then error("inflate: distance too far back", 0) end
        local dist = n - from
        if not tmove then
          for i = 1, len do out[n + i] = out[from + i] end  -- (byte by byte: an overlap repeats itself)
        elseif dist >= len then
          tmove(out, from + 1, from + len, n + 1)          -- (not overlapping: one copy)
        else
          -- (overlapping: the last dist bytes repeat - copied in whole repeats,
          -- doubling, each read only from what is already written)
          local done = 0
          while done < len do
            local chunk = dist + done
            if chunk > len - done then chunk = len - done end
            tmove(out, from + 1, from + chunk, n + done + 1)
            done = done + chunk
          end
        end
        n = n + len
      end
    end
  end
  repeat
    local last = bits(1)
    local kind = bits(2)
    if kind == 0 then
      bitbuf, bitcnt = 0, 0                   -- (to the next whole byte)
      local a, b = byte(src, pos, pos + 1)
      if not b then error("inflate: the data ends early", 0) end
      local len = a + b * 256
      pos = pos + 4
      for i = 0, len - 1 do out[n + 1 + i] = byte(src, pos + i) end
      n, pos = n + len, pos + len
    elseif kind == 1 then
      codes(FIXED_LEN, FIXED_DIST)
    elseif kind == 2 then
      local nlen, ndist, ncode = bits(5) + 257, bits(5) + 1, bits(4) + 4
      local lengths = {}
      for i = 0, 18 do lengths[i] = 0 end
      for i = 1, ncode do lengths[ORDER[i]] = bits(3) end
      local lencode = huffman(lengths, 19)
      lengths = {}
      local index = 0
      while index < nlen + ndist do
        local sym = decode(lencode)
        if sym < 16 then
          lengths[index] = sym
          index = index + 1
        else
          local len, rep = 0, 0
          if sym == 16 then
            if index == 0 then error("inflate: repeat with nothing before", 0) end
            len, rep = lengths[index - 1], 3 + bits(2)
          elseif sym == 17 then
            rep = 3 + bits(3)
          else
            rep = 11 + bits(7)
          end
          for _ = 1, rep do
            lengths[index] = len
            index = index + 1
          end
        end
      end
      local dl = {}
      for i = 0, ndist - 1 do dl[i] = lengths[nlen + i] end
      codes(huffman(lengths, nlen), huffman(dl, ndist))
    else
      error("inflate: bad block type", 0)
    end
  until last == 1
  local parts = {}
  for i = 1, n, 2048 do parts[#parts + 1] = string.char(table.unpack(out, i, math.min(n, i + 2047))) end
  return table.concat(parts)
end

---------------------------------------------------------------- storage

local S = { tiles = {}, have = {}, loaded = 0, pal = {}, palIdx = {}, layers = {}, runLayers = {}, runCache = {},
  runCached = 0, full = false }
W.S = S

-- (numeric tile keys: string keys would be built on every lookup)
local function tkey(tx, tz) return (tx + 32768) * 65536 + (tz + 32768) end
function S.tilePath(tx, tz) return fs.combine(W.FILES.scan, ("t%d_%d.bin"):format(tx, tz)) end

function S.loadPal()
  S.pal, S.palIdx = {}, {}
  local path = fs.combine(W.FILES.scan, "pal.txt")
  if fs.exists(path) then
    local h = fs.open(path, "r")
    for line in h.readAll():gmatch("[^\n]+") do
      S.pal[#S.pal + 1] = line
      S.palIdx[line] = #S.pal
    end
    h.close()
  end
end

function S.palIndex(name)
  local i = S.palIdx[name]
  if i then return i end
  if #S.pal >= 65535 then return 1 end
  S.pal[#S.pal + 1] = name
  i = #S.pal
  S.palIdx[name] = i
  S.palDirty = true
  return i
end

-- Every tile on disk (so a lookup never has to ask the disk)
function S.index()
  S.have = {}
  if not fs.exists(W.FILES.scan) then fs.makeDir(W.FILES.scan) end
  local n = 0
  for _, f in ipairs(fs.list(W.FILES.scan)) do
    local tx, tz = f:match("^t(%-?%d+)_(%-?%d+)%.bin$")
    if tx then
      S.have[tkey(tonumber(tx), tonumber(tz))] = true
      n = n + 1
    end
  end
  S.onDisk = n
end

-- The Distant Horizons layers in dh/: one height a cell (DHMAP1/2, as the
-- glasses' dhmap.bin) or every block with its floating parts (DHRUN1,
-- tools/dhruns.py: 64 x 64-block tiles, each DEFLATE-packed)
-- (the .bin files and their sizes: the PC's dhwatch.py replaces them as you go)
function S.layerSig()
  if not fs.exists(W.FILES.dh) then return "" end
  local out = {}
  for _, f in ipairs(fs.list(W.FILES.dh)) do
    if f:sub(-4) == ".bin" then out[#out + 1] = f .. ":" .. fs.getSize(fs.combine(W.FILES.dh, f)) end
  end
  return table.concat(out, ",")
end

function S.loadLayers()
  S.layers, S.runLayers, S.runCache, S.runCached = {}, {}, {}, 0
  S.sig = S.layerSig()
  if not fs.exists(W.FILES.dh) then return end
  for _, f in ipairs(fs.list(W.FILES.dh)) do
    -- (only .bin: a .tmp is one still being written)
    if f:sub(-4) == ".bin" then S.loadLayer(f, fs.combine(W.FILES.dh, f)) end
  end
  table.sort(S.layers, function(a, b) return a.cell < b.cell end)
  for _, d in ipairs(S.layers) do
    W.log(("Distant Horizons layer %s: %dx%d cells of %d from %d,%d"):format(d.file, d.w, d.h, d.cell, d.x0, d.z0))
  end
end

function S.loadLayer(f, path)
  local h = fs.open(path, "rb")
  local raw = h and h.readAll()
  if h then h.close() end
  local l1 = raw and raw:find("\n", 1, true)
  local l2 = l1 and raw:find("\n", l1 + 1, true)
  local ver, x0, z0, cell, w, hh, base
  local rv, rx0, rz0, rw, rh = nil, nil, nil, nil, nil
  if l2 then rv, rx0, rz0, rw, rh = raw:sub(1, l1 - 1):match("^DHRUN([12]) (%-?%d+) (%-?%d+) (%d+) (%d+)$") end
  if rx0 then
    -- (DHRUN2: each run with its layers - 12 bytes a run; DHRUN1: 6)
    local d = { file = f, sx0 = tonumber(rx0), sz0 = tonumber(rz0), sw = tonumber(rw), sh = tonumber(rh),
      names = {}, raw = raw, index = l2 + 1, rb = rv == "2" and 12 or 6 }
    -- (names with their shape state - "id|facing=east,..." - are split by ";")
    local line = raw:sub(l1 + 1, l2 - 1)
    for name in line:gmatch(line:find(";", 1, true) and "[^;]+" or "[^,]+") do d.names[#d.names + 1] = name end
    d.blobs = d.index + 7 * d.sw * d.sh
    S.runLayers[#S.runLayers + 1] = d
    W.log(("full-detail layer %s: %dx%d blocks from %d,%d"):format(f, d.sw * 64, d.sh * 64, d.sx0 * 64, d.sz0 * 64))
    l2 = nil
  end
  if l2 then
    ver, x0, z0, cell, w, hh, base = raw:sub(1, l1 - 1):match("^DHMAP([123]) (%-?%d+) (%-?%d+) (%d+) (%d+) (%d+) (%-?%d+)$")
  end
  if x0 then
    -- (DHMAP1: height, block - 2 bytes a cell; DHMAP2: 2 bytes of height, block;
    -- DHMAP3: DHMAP2 packed - unpacked here, once)
    local data = raw:sub(l2 + 1)
    if ver == "3" then
      local ok, un = pcall(W.inflate, data)
      if not ok then
        W.log(("dh/%s: %s"):format(f, tostring(un)))
        return
      end
      data = un
    end
    local d = { file = f, x0 = tonumber(x0), z0 = tonumber(z0), cell = tonumber(cell), w = tonumber(w),
      h = tonumber(hh), base = tonumber(base), names = {}, data = data, per = ver == "1" and 2 or 3 }
    for name in raw:sub(l1 + 1, l2 - 1):gmatch("[^,]+") do d.names[#d.names + 1] = name end
    if #d.data >= d.per * d.w * d.h then S.layers[#S.layers + 1] = d end
  elseif not rx0 then
    W.log("dh/" .. f .. ": not a Distant Horizons map")
  end
end

-- Where helldivers are and where the map looks (for the PC's dhwatch.py,
-- which exports Distant Horizons around it into dh/): where.txt
function S.noteWhere(kind, x, z)
  x, z = tonumber(x), tonumber(z)
  if not (x and z) then return end
  S.where = S.where or {}
  S.where[kind] = { x = math.floor(x), z = math.floor(z), t = os.epoch and os.epoch("utc") or 0 }
  S.whereDirty = true
end

function S.saveWhere()
  if not S.whereDirty then return end
  S.whereDirty = false
  local out = {}
  for _, kind in ipairs({ "scan", "view" }) do
    local w = S.where[kind]
    if w then out[#out + 1] = ("%s %d %d %d"):format(kind, w.x, w.z, w.t) end
  end
  local f = fs.open("where.txt", "w")
  if f then
    f.write(table.concat(out, "\n") .. "\n")
    f.close()
  end
end

-- New layers from the PC (dh/ changed): read them again
function S.checkLayers()
  if S.layerSig() == S.sig then return false end
  S.loadLayers()
  W.log(("Distant Horizons layers changed: %d full-detail, %d height maps"):format(#S.runLayers, #S.layers))
  return true
end

-- A scan tile (32 x 32 columns): in memory, from disk, or a new empty one
function S.tile(tx, tz, create)
  local k = tkey(tx, tz)
  local t = S.tiles[k]
  if t then
    t.used = now()
    return t
  end
  if not S.have[k] and not create then return nil end
  t = { tx = tx, tz = tz, h = {}, b = {}, used = now() }
  if S.have[k] then
    local f = fs.open(S.tilePath(tx, tz), "rb")
    local raw = f and f.readAll() or ""
    if f then f.close() end
    for c = 1, math.min(W.TILE * W.TILE, math.floor(#raw / 4)) do
      local p = 4 * (c - 1)
      local h1, h2, b1, b2 = raw:byte(p + 1, p + 4)
      local v = h1 * 256 + h2
      if v > 0 then
        t.h[c] = v - W.Y0
        t.b[c] = b1 * 256 + b2
      end
    end
  else
    -- a new file: only with room on the disk
    if (fs.getFreeSpace("/") or 0) < W.cfg.keepFree then
      if not S.full then W.log("storage nearly full - new areas are no longer recorded") end
      S.full = true
      return nil
    end
    t.dirty = true
  end
  S.tiles[k] = t
  S.loaded = S.loaded + 1
  if S.loaded > W.cfg.maxTiles then S.trim() end
  return t
end

function S.saveTile(t)
  local out = {}
  for c = 1, W.TILE * W.TILE do
    local y = t.h[c]
    out[c] = y and (u16(clamp(y + W.Y0, 1, 65535)) .. u16(t.b[c] or 0)) or "\0\0\0\0"
  end
  local f = fs.open(S.tilePath(t.tx, t.tz), "wb")
  if f then
    f.write(table.concat(out))
    f.close()
    S.have[tkey(t.tx, t.tz)] = true
  end
  t.dirty = false
end

function S.flush()
  for _, t in pairs(S.tiles) do
    if t.dirty then S.saveTile(t) end
  end
  if S.palDirty then
    local f = fs.open(fs.combine(W.FILES.scan, "pal.txt"), "w")
    f.write(table.concat(S.pal, "\n") .. "\n")
    f.close()
    S.palDirty = false
  end
end

-- Room for a server's every-block layer (R.storeOnce): scan tiles go - those
-- the layer covers first (it wins there anyway), then the farthest from its
-- middle - until `need` bytes are free. -> bytes freed
function S.makeRoom(need, cx, cz, radius)
  local list = {}
  for k in pairs(S.have) do
    local tx, tz = math.floor(k / 65536) - 32768, k % 65536 - 32768
    local d = math.max(math.abs(tx * W.TILE + W.TILE / 2 - cx), math.abs(tz * W.TILE + W.TILE / 2 - cz))
    list[#list + 1] = { k = k, tx = tx, tz = tz, d = d, covered = d <= radius - W.TILE }
  end
  table.sort(list, function(a, b)
    if a.covered ~= b.covered then return a.covered end
    return a.d > b.d
  end)
  local freed, n = 0, 0
  for _, t in ipairs(list) do
    if freed >= need then break end
    local path = S.tilePath(t.tx, t.tz)
    freed = freed + (fs.exists(path) and fs.getSize(path) or 0)
    fs.delete(path)
    S.have[t.k] = nil
    if S.tiles[t.k] then
      S.tiles[t.k] = nil
      S.loaded = S.loaded - 1
    end
    n = n + 1
  end
  if n > 0 then
    S.full, S.onDisk = false, math.max(0, (S.onDisk or n) - n)
    W.log(("server map: %d old scan tiles cleared (%d KB) for the every-block layer"):format(n, math.floor(freed / 1000)))
  end
  return freed
end

-- Too many tiles in memory: save, then forget the least used half
function S.trim()
  S.flush()
  local list = {}
  for k, t in pairs(S.tiles) do list[#list + 1] = { k = k, used = t.used } end
  table.sort(list, function(a, b) return a.used < b.used end)
  for i = 1, math.floor(#list / 2) do
    S.tiles[list[i].k] = nil
    S.loaded = S.loaded - 1
  end
end

-- A helldiver's scan (hd2.team "terrain", v2: names), every column it found
function S.putScan(msg)
  local ox, oy, oz, r, d, names = tonumber(msg.ox), tonumber(msg.oy), tonumber(msg.oz), tonumber(msg.r), msg.d, msg.names
  if msg.v ~= 2 or not (ox and oy and oz and r) or type(d) ~= "string" or type(names) ~= "table" then return 0 end
  if r < 1 or r > 64 or #d ~= 2 * (2 * r + 1) ^ 2 then return 0 end
  local p, n = 1, 0
  for dx = -r, r do
    for dz = -r, r do
      local hb, ib = d:byte(p, p + 1)
      p = p + 2
      -- (0 = nothing found in reach: from high up that is not "no ground", so keep what is known)
      local name = hb > 0 and names[ib]
      if name then
        local x, z = ox + dx, oz + dz
        local tx, tz = math.floor(x / W.TILE), math.floor(z / W.TILE)
        local t = S.tile(tx, tz, true)
        if t then
          local c = (x - tx * W.TILE) * W.TILE + (z - tz * W.TILE) + 1
          t.h[c], t.b[c] = oy + hb - r - 1, S.palIndex(tostring(name))
          t.dirty = true
          n = n + 1
        end
      end
    end
  end
  S.scans = (S.scans or 0) + 1
  return n
end

-- A helldiver's scan of one column: its top, block (nil: never scanned)
function S.scanTop(x, z)
  local tx, tz = math.floor(x / W.TILE), math.floor(z / W.TILE)
  local k = tkey(tx, tz)
  local t = S.tiles[k] or (S.have[k] and S.tile(tx, tz))
  if t then
    local c = (x - tx * W.TILE) * W.TILE + (z - tz * W.TILE) + 1
    local y = t.h[c]
    if y then return y, S.pal[t.b[c]] end
  end
end

-- A full-detail tile, unpacked (the last runTiles used stay unpacked):
-- raw = 64 x 64 columns, off[c] = where column c starts in it
function S.runTile(d, i, j)
  local key = i * d.sh + j                    -- (a number: no string built on every look)
  d.cache = d.cache or {}
  local t = d.cache[key]
  if t then
    t.used = now()
    return t
  end
  local e = d.index + 7 * (i * d.sh + j)
  local o1, o2, o3, o4, l1, l2, l3 = d.raw:byte(e, e + 6)
  local len = l1 and (l1 * 65536 + l2 * 256 + l3) or 0
  if len == 0 then
    t = { empty = true, used = now() }
  else
    local at = d.blobs + ((o1 * 256 + o2) * 256 + o3) * 256 + o4
    local ok, raw = pcall(W.inflate, d.raw:sub(at, at + len - 1))
    if not ok then
      W.log(("%s tile %d,%d: %s"):format(d.file, i, j, tostring(raw)))
      t = { empty = true, used = now() }
    else
      local off, p, rb = {}, 1, d.rb or 6
      for c = 1, 4096 do
        off[c] = p
        p = p + 1 + rb * (raw:byte(p) or 0)
      end
      t = { raw = raw, off = off, used = now() }
    end
  end
  d.cache[key] = t
  S.runCached = S.runCached + 1
  if S.runCached > W.cfg.runTiles then
    local list = {}
    for _, layer in ipairs(S.runLayers) do
      for k2, v in pairs(layer.cache or {}) do list[#list + 1] = { c = layer.cache, k = k2, used = v.used } end
    end
    table.sort(list, function(a, b) return a.used < b.used end)
    for n = 1, math.floor(#list / 2) do
      list[n].c[list[n].k] = nil
      S.runCached = S.runCached - 1
    end
  end
  return t
end

-- One column's top and top block from the full-detail layers (no tables
-- made: the top-down map asks this for every pixel)
function S.colTop(x, z)
  local sx, sz = math.floor(x / 64), math.floor(z / 64)
  for _, d in ipairs(S.runLayers) do
    local i, j = sx - d.sx0, sz - d.sz0
    if i >= 0 and j >= 0 and i < d.sw and j < d.sh then
      local t = S.runTile(d, i, j)
      if t.raw then
        local p = t.off[(x - sx * 64) * 64 + (z - sz * 64) + 1]
        local n, a, b, _, _, f, g = t.raw:byte(p, p + 6)
        if n and n > 0 then return a * 256 + b - W.Y0, d.names[f * 256 + g] or "minecraft:stone" end
      end
    end
  end
end

-- One column's solid runs from the full-detail layers, highest first:
-- { { top, bottom, block, t1, under, t2, deep }, ... } (nil: not covered /
-- unknown) - t1..deep (DHRUN2): the top block's layer thickness, the block
-- under it and its thickness, the block most of the rest is (nil: not known)
function S.colRuns(x, z)
  for _, d in ipairs(S.runLayers) do
    local sx, sz = math.floor(x / 64), math.floor(z / 64)
    local i, j = sx - d.sx0, sz - d.sz0
    if i >= 0 and j >= 0 and i < d.sw and j < d.sh then
      local t = S.runTile(d, i, j)
      if t.raw then
        local p = t.off[(x - sx * 64) * 64 + (z - sz * 64) + 1]
        local raw, rb, names = t.raw, d.rb or 6, d.names
        local n = raw:byte(p) or 0
        if n > 0 then
          local out = {}
          for r = 1, n do
            local q = p + 1 + rb * (r - 1)
            local a, b, c, e, f, g = raw:byte(q, q + 5)
            local run = { a * 256 + b - W.Y0, c * 256 + e - W.Y0, names[f * 256 + g] or "minecraft:stone" }
            if rb == 12 then
              local t1, u1, u2, t2, d1, d2 = raw:byte(q + 6, q + 11)
              run[4], run[5], run[6], run[7] = t1, names[u1 * 256 + u2], t2, names[d1 * 256 + d2]
            end
            out[r] = run
          end
          return out
        end
      end
    end
  end
end

-- One column's runs: the full-detail layer's (fine), else one run from the
-- top down. (A helldiver's scan is only a column's top: where every block is
-- known it is not used - made solid down to the bottom it would be a wall
-- under whatever floats, and the watcher keeps the full detail fresh)
function S.columnRuns(x, z, fine)
  local runs = fine and S.colRuns(x, z)
  if runs then return runs end
  local y, n = S.top(x, z, false)
  return y and { { y, -W.Y0, n } } or nil
end

-- The top of one column: (fine) the full-detail layer's, else a scan's, else
-- the finest one-height-a-cell Distant Horizons layer's
function S.top(x, z, fine)
  if fine then
    local y, n = S.colTop(x, z)
    if y then return y, n end
  end
  local sy, sn = S.scanTop(x, z)
  if sy then return sy, sn end
  for _, d in ipairs(S.layers) do
    local ix, iz = math.floor((x - d.x0) / d.cell), math.floor((z - d.z0) / d.cell)
    if ix >= 0 and iz >= 0 and ix < d.w and iz < d.h then
      local i = d.per * (ix * d.h + iz) + 1
      local hb, pb
      if d.per == 3 then
        local h1, h2
        h1, h2, pb = d.data:byte(i, i + 2)
        hb = h1 and h1 * 256 + h2
      else
        hb, pb = d.data:byte(i, i + 1)
      end
      if hb and hb > 0 then return d.base + hb, d.names[pb] end
    end
  end
end

-- The ground over an area: w x h cells of `cell` blocks from x0, z0 (index
-- i*h + j + 1, i east, j south), each the highest of samples^2 looks.
-- hs: 2 bytes a cell (y + 2048, 0 = unknown); bs: 1 byte (names index, 0 = none)
function S.tops(q, yield)
  local x0, z0 = math.floor(tonumber(q.x0) or 0), math.floor(tonumber(q.z0) or 0)
  local cell = clamp(math.floor(tonumber(q.cell) or 1), 1, 512)
  local w, h = clamp(math.floor(tonumber(q.w) or 1), 1, 512), clamp(math.floor(tonumber(q.h) or 1), 1, 512)
  local step = math.max(1, math.floor(cell / clamp(tonumber(q.samples) or 2, 1, 8)))
  -- (every block only close up: unpacking full-detail tiles for a wide map would take too long)
  local fine = cell <= 2
  local hs, bs, names, nidx = {}, {}, {}, {}           -- (bytes as numbers: made into strings once at the end)
  local top = S.top
  for i = 0, w - 1 do
    for j = 0, h - 1 do
      local best, bn
      local bx, bz = x0 + i * cell, z0 + j * cell
      for sx = bx, bx + cell - 1, step do
        for sz = bz, bz + cell - 1, step do
          local y, n = top(sx, sz, fine)
          if y and (not best or y > best) then best, bn = y, n end
        end
      end
      local k = i * h + j + 1
      if best then
        local v = clamp(best + W.Y0, 1, 65535)
        hs[2 * k - 1], hs[2 * k] = math.floor(v / 256), v % 256
        local id = bn and nidx[bn]
        if bn and not id and #names < 255 then
          names[#names + 1] = bn
          id = #names
          nidx[bn] = id
        end
        bs[k] = id or 0
      else
        hs[2 * k - 1], hs[2 * k], bs[k] = 0, 0, 0
      end
    end
    if yield and i % 4 == 3 then yield() end
  end
  return { x0 = x0, z0 = z0, cell = cell, w = w, h = h, hs = W.bytes(hs), bs = W.bytes(bs), names = names }
end

-- The 3D ground over an area: w x h cells (index i*h + j + 1) of `cell`
-- blocks, each its solid runs highest first - sampled columns' runs put
-- together, runs closer than `gap` blocks joined, at most `cap` (the lowest
-- always kept: the ground). rs: per cell 1 byte n, then n x (top + 2048,
-- bottom + 2048 (0 = down to the bottom), names index): 2 + 2 + 1 bytes
-- Runs put together: highest first, closer than `gap` joined, at most
-- `cap` (the lowest - the ground - always kept)
-- (leaves: a tree's crown stays up in the air - never joined across the air
-- under it to the ground, which would make the tree a green pillar)
local function foliage(n) return n and (n:find("leaves", 1, true) or n:find("azalea", 1, true)) end

-- Run r (lower) taken into `last`: last's layers stay; what it lacks of them
-- comes from r (the air between counted as r's top block)
local function absorb(last, r)
  if r[2] >= last[2] then return end
  if last[4] then
    if not last[5] then
      if r[3] ~= last[3] then
        last[5], last[6], last[7] = r[3], math.max(1, (last[1] - last[4]) - (r[1] - (r[4] or 1))), r[5] or r[7]
      else
        last[4] = math.min(255, (last[1] - r[1]) + (r[4] or 1))
        last[5], last[6], last[7] = r[5], r[6], r[7]
      end
    elseif not last[7] then
      last[7] = r[3] ~= last[5] and r[3] or r[5] or r[7]
    end
  end
  last[2] = r[2]
end

local function joinRuns(all, gap, cap)
  table.sort(all, function(a, b) return a[1] > b[1] end)
  local merged = {}
  for _, r in ipairs(all) do
    local last = merged[#merged]
    local air = last and last[2] - r[1] - 1
    if last and air < gap and not (air > 0 and foliage(last[7] or last[5] or last[3])) then
      absorb(last, r)
    else
      merged[#merged + 1] = { r[1], r[2], r[3], r[4], r[5], r[6], r[7] }
    end
  end
  if #merged > cap then
    local low = merged[#merged]
    for n = #merged, cap, -1 do merged[n] = nil end
    merged[cap] = low
  end
  return merged
end

-- A reply's block names: name -> index (at most 255; 0 = unnamed). Full:
-- a state's plain block where it has one ("oak_stairs" for "oak_stairs|...")
local function namer()
  local names, nidx = {}, {}
  local function index(n)
    local id = n and nidx[n]
    if n and not id and #names < 255 then
      names[#names + 1] = n
      id = #names
      nidx[n] = id
    end
    return id
  end
  return names, function(n)
    local id = index(n)
    if not id and n and n:find("|", 1, true) then id = index(W.base(n)) end
    return id or 0
  end
end

-- per run: top, bottom (2 bytes each), block (1), then its layers - the top
-- block's thickness (1, 0 = not known), the block under it (1), that one's
-- thickness (1), the block most of the rest is (1): 9 bytes (replies' rb)
W.RUN_BYTES = 9
local function encodeRuns(runs, nameIndex)
  local char, floor, Y0 = string.char, math.floor, W.Y0
  local parts = { char(#runs) }
  for i, r in ipairs(runs) do
    -- (one string a run; the names looked up in the same order as ever - new ones are numbered as they come)
    local a, b = clamp(r[1] + Y0, 1, 65535), clamp(r[2] + Y0, 0, 65535)
    local n3 = nameIndex(r[3])
    local t1 = clamp(r[4] or 0, 0, 255)
    local n5 = r[5] and nameIndex(r[5]) or 0
    local t2 = clamp(r[6] or 0, 0, 255)
    local n7 = r[7] and nameIndex(r[7]) or 0
    parts[i + 1] = char(floor(a / 256) % 256, a % 256, floor(b / 256) % 256, b % 256, n3, t1, n5, t2, n7)
  end
  return table.concat(parts)
end

function S.runs(q, yield)
  local x0, z0 = math.floor(tonumber(q.x0) or 0), math.floor(tonumber(q.z0) or 0)
  local cell = clamp(math.floor(tonumber(q.cell) or 1), 1, 512)
  local w, h = clamp(math.floor(tonumber(q.w) or 1), 1, 256), clamp(math.floor(tonumber(q.h) or 1), 1, 256)
  local step = math.max(1, math.floor(cell / clamp(tonumber(q.samples) or 4, 1, 8)))
  local gap, cap = clamp(tonumber(q.gap) or 4, 1, 4096), clamp(math.floor(tonumber(q.cap) or 4), 1, 16)
  local fine = cell <= (tonumber(q.fineUpTo) or 8)
  local out = {}
  local names, nameIndex = namer()
  for i = 0, w - 1 do
    for j = 0, h - 1 do
      local all = {}
      local bx, bz = x0 + i * cell, z0 + j * cell
      for sx = bx, bx + cell - 1, step do
        for sz = bz, bz + cell - 1, step do
          local runs = S.columnRuns(sx, sz, fine)
          if runs then
            for _, r in ipairs(runs) do all[#all + 1] = r end
          end
        end
      end
      out[i * h + j + 1] = encodeRuns(joinRuns(all, gap, cap), nameIndex)
    end
    if yield and i % 2 == 1 then yield() end
  end
  return { x0 = x0, z0 = z0, cell = cell, w = w, h = h, rs = table.concat(out), names = names, rb = W.RUN_BYTES }
end

-- The 3D ground over a square of `size` samples of `cell` blocks (size = 1 or
-- 3 x a power of 2, at most 256) from x0, z0 as at most `cells` squares of
-- their own sizes: one big square where the ground is all one height, down
-- to single samples where it is not - the most uneven (and biggest) split
-- first, until the squares run out. What the blocks are does not split a
-- square: a square carries a picture of its top, a texel every `tcell`
-- blocks (a ship's deck markings cost one square and a picture, not a
-- square a block). Wide views: a sample is `cell` blocks (the heights there
-- as finely as Distant Horizons has them), the picture finer than that.
-- qs (kind quad4): per square x, z offsets and size (samples, 2 bytes each),
-- its runs as S.runs, then (over 1 texel) its picture - 1 byte: 0 = one
-- block all over, or 1 + texels^2 bytes: each texel's top block (names index;
-- rows north -> south, each west -> east) - then (over 1 sample) its heights
-- - 1 byte: 0 = flat, or 1 + size^2 bytes: each sample's top below the
-- square's (255 = unknown)
function S.quad(q, yield)
  local x0, z0 = math.floor(tonumber(q.x0) or 0), math.floor(tonumber(q.z0) or 0)
  local N = clamp(math.floor(tonumber(q.size) or 64), 1, 256)
  local odd = N
  while odd % 2 == 0 do odd = odd / 2 end
  if odd ~= 1 and odd ~= 3 then                     -- (else: the next power of 2)
    local p = 1
    while p < N do p = p * 2 end
    N = p
  end
  local cell = clamp(math.floor(tonumber(q.cell) or 1), 1, 64)
  local tcell = clamp(math.floor(tonumber(q.tcell) or cell), 1, cell)
  if cell % tcell ~= 0 then tcell = cell end
  local per = math.floor(cell / tcell)              -- texels a sample, a side
  local maxCells = clamp(math.floor(tonumber(q.cells) or 2000), 4, 16000)
  local gap, cap = clamp(tonumber(q.gap) or 4, 1, 4096), clamp(math.floor(tonumber(q.cap) or 4), 1, 16)
  -- every sample: its runs (packed), top, top block, run count. A block a
  -- sample: that column; 2: all 4 columns (every block); wider: the height
  -- maps (4 and 8 blocks a cell), 1 or 4 looks a sample
  local fine = cell <= 2
  local step = cell <= 2 and 1 or math.max(4, cell / 2)
  local packed, top, nm, nr = {}, {}, {}, {}
  for i = 0, N - 1 do
    for j = 0, N - 1 do
      local runs
      if cell == 1 then
        runs = S.columnRuns(x0 + i, z0 + j, true)
      else
        local all, bx, bz = {}, x0 + i * cell, z0 + j * cell
        for sx = bx, bx + cell - 1, step do
          for sz = bz, bz + cell - 1, step do
            local r = S.columnRuns(sx, sz, fine)
            if r then for _, v in ipairs(r) do all[#all + 1] = v end end
          end
        end
        runs = #all > 0 and all or nil
      end
      local k = i * N + j + 1
      if runs then
        runs = joinRuns(runs, gap, cap)
        packed[k] = runs
        top[k], nm[k], nr[k] = runs[1][1], runs[1][3], #runs
      end
    end
    if yield and i % 4 == 3 then yield() end
  end
  -- texels finer than the samples: each one's top block (west -> east
  -- strips, so the full-detail tiles unpack once each)
  local T = N * per
  local texName = nm
  if per > 1 then
    texName = {}
    local tfine, topAt = tcell <= 2, S.top
    for ti = 0, T - 1 do
      for tj = 0, T - 1 do
        local _, n = topAt(x0 + ti * tcell, z0 + tj * tcell, tfine)
        texName[ti * T + tj + 1] = n
      end
      if yield and ti % 8 == 7 then yield() end
    end
  end
  -- every square of every size, bottom up: lowest / highest top, one block
  -- all over (or false), more than one run anywhere, columns known
  local levels = { { size = 1, n = N } }
  do
    local L = levels[1]
    L.lo, L.hi, L.name, L.multi, L.known = {}, {}, {}, {}, {}
    for k = 1, N * N do
      L.lo[k], L.hi[k], L.name[k] = top[k], top[k], nm[k] or false
      L.multi[k], L.known[k] = (nr[k] or 0) > 1, top[k] and 1 or 0
    end
  end
  -- (3 x a power of 2 across: 3 x 3 biggest squares to start from)
  while levels[#levels].n % 2 == 0 do
    local C = levels[#levels]
    local n = C.n / 2
    local L = { size = C.size * 2, n = n, lo = {}, hi = {}, name = {}, multi = {}, known = {} }
    for i = 0, n - 1 do
      for j = 0, n - 1 do
        local k = i * n + j + 1
        local lo, hi, name, multi, known = nil, nil, nil, false, 0
        for di = 0, 1 do
          for dj = 0, 1 do
            local c = (2 * i + di) * C.n + (2 * j + dj) + 1
            if C.lo[c] and (not lo or C.lo[c] < lo) then lo = C.lo[c] end
            if C.hi[c] and (not hi or C.hi[c] > hi) then hi = C.hi[c] end
            local cn = C.name[c]
            if name == nil then name = cn elseif name ~= cn then name = false end
            multi = multi or C.multi[c]
            known = known + C.known[c]
          end
        end
        L.lo[k], L.hi[k], L.name[k], L.multi[k], L.known[k] = lo, hi, name or false, multi, known
      end
    end
    levels[#levels + 1] = L
    if yield then yield() end
  end
  -- how badly one square's shape shows what is in it (0 = exactly; its
  -- blocks' colours go in its picture)
  local function err(lv, k)
    local L = levels[lv]
    local known, full = L.known[k], L.size * L.size
    if known == 0 then return 0 end
    local e = (L.hi[k] - L.lo[k]) + (L.multi[k] and 6 or 0)
    if known < full then e = e + 3 end
    if L.multi[k] and L.size == 1 then e = 0 end
    return e
  end
  -- split the worst squares first (a heap on err x size)
  local heap, hn = {}, 0
  local function push(item)
    hn = hn + 1
    heap[hn] = item
    local i = hn
    while i > 1 do
      local p = math.floor(i / 2)
      if heap[p].pri >= heap[i].pri then break end
      heap[p], heap[i] = heap[i], heap[p]
      i = p
    end
  end
  local function pop()
    local top1 = heap[1]
    heap[1] = heap[hn]
    heap[hn] = nil
    hn = hn - 1
    local i = 1
    while true do
      local l, r, m = 2 * i, 2 * i + 1, i
      if l <= hn and heap[l].pri > heap[m].pri then m = l end
      if r <= hn and heap[r].pri > heap[m].pri then m = r end
      if m == i then break end
      heap[m], heap[i] = heap[i], heap[m]
      i = m
    end
    return top1
  end
  local MUST = 1e6
  local function node(lv, i, j)
    local L = levels[lv]
    local k = i * L.n + j + 1
    local e = err(lv, k)
    -- (a picture over 256 texels across is too big for the glasses: split it)
    if lv > 1 and L.size * per > 256 then e = MUST end
    return { lv = lv, i = i, j = j, k = k, e = e, pri = e * L.size }
  end
  local final = {}
  local Ltop = levels[#levels]
  for i = 0, Ltop.n - 1 do
    for j = 0, Ltop.n - 1 do push(node(#levels, i, j)) end
  end
  local cells = Ltop.n * Ltop.n
  while hn > 0 do
    local it = heap[1]
    if it.e == 0 or it.lv == 1 or (cells + 3 > maxCells and it.e < MUST) then break end
    pop()
    cells = cells + 3
    for di = 0, 1 do
      for dj = 0, 1 do push(node(it.lv - 1, 2 * it.i + di, 2 * it.j + dj)) end
    end
  end
  for n = 1, hn do final[#final + 1] = heap[n] end
  -- each square's runs: one column's, or every column in it put together
  local names, nameIndex = namer()
  local out = {}
  for c, it in ipairs(final) do
    local L = levels[it.lv]
    local s = L.size
    local bi, bj = it.i * s, it.j * s
    local runs
    if L.known[it.k] == 0 then
      runs = {}
    elseif s == 1 then
      runs = packed[bi * N + bj + 1]
    else
      local all = {}
      for i = bi, bi + s - 1 do
        for j = bj, bj + s - 1 do
          local p = packed[i * N + j + 1]
          if p then for _, r in ipairs(p) do all[#all + 1] = r end end
        end
      end
      runs = joinRuns(all, gap, cap)
    end
    -- the picture of its top, and each column's height under the square's
    -- top (its picture is shaded by them: the relief shows even where the
    -- square is not split)
    local tex, hts = "", ""
    local ts = s * per                                -- (texels a side)
    if ts > 1 then
      if per == 1 and L.name[it.k] then
        tex = "\0"
      else
        local px, first, same = {}, nil, true
        for tj = bj * per, (bj + s) * per - 1 do
          for ti = bi * per, (bi + s) * per - 1 do
            local id = nameIndex(texName[ti * T + tj + 1])
            px[#px + 1] = id
            if first == nil then first = id elseif id ~= first then same = false end
          end
        end
        tex = same and "\0" or "\1" .. W.bytes(px)
      end
    end
    if s > 1 then
      local hi = L.hi[it.k]
      if not hi or hi == L.lo[it.k] then
        hts = "\0"
      else
        local px = {}
        for j = bj, bj + s - 1 do
          for i = bi, bi + s - 1 do
            local y = top[i * N + j + 1]
            px[#px + 1] = y and clamp(hi - y, 0, 254) or 255
          end
        end
        hts = "\1" .. W.bytes(px)
      end
    end
    out[c] = u16(bi) .. u16(bj) .. u16(s) .. encodeRuns(runs, nameIndex) .. tex .. hts
    if yield and c % 256 == 0 then yield() end
  end
  return { kind = "quad4", x0 = x0, z0 = z0, size = N, cell = cell, tcell = tcell, count = #final,
    qs = table.concat(out), names = names, rb = W.RUN_BYTES }
end

-- One column: its top, top block and runs (what is at a spot on the map)
function S.point(q)
  local x, z = math.floor(tonumber(q.x) or 0), math.floor(tonumber(q.z) or 0)
  local runs = S.columnRuns(x, z, true)
  return { x = x, z = z, y = runs and runs[1][1] or nil, name = runs and runs[1][3] or nil, runs = runs }
end

function S.info()
  local tiles = 0
  for _ in pairs(S.have) do tiles = tiles + 1 end
  local layers = {}
  -- (fine: where every block is known - x0, z0, x1, z1 - a helldiver's scan there changes nothing on the table)
  local fine = {}
  for _, d in ipairs(S.runLayers) do
    layers[#layers + 1] = ("%s (every block)"):format(d.file)
    fine[#fine + 1] = { d.sx0 * 64, d.sz0 * 64, (d.sx0 + d.sw) * 64 - 1, (d.sz0 + d.sh) * 64 - 1 }
  end
  for _, d in ipairs(S.layers) do layers[#layers + 1] = ("%s (%d blocks a cell)"):format(d.file, d.cell) end
  return { op = "info", tiles = tiles, layers = layers, free = fs.getFreeSpace("/"), full = S.full, scans = S.scans or 0,
    version = W.VERSION, sig = S.sig, fine = fine }
end

---------------------------------------------------------------- map computer

local M = { jobs = {}, table = { rev = 0 }, seq = 0 }
W.M = M

function M.loadTable()
  if fs.exists(W.FILES.table) then
    local h = fs.open(W.FILES.table, "r")
    local t = textutils.unserialize(h.readAll())
    h.close()
    if type(t) == "table" then M.table = t end
  end
  M.table.rev = tonumber(M.table.rev) or 0
  -- (storage may know more since: fetch the table's ground again)
  if M.table.view then M.table.dirty = true end
end

-- (where the table is and what it shows - not its ground: that is fetched
-- again at start, and serialized it would fill the disk)
function M.saveTable()
  pcall(function()
    local t = M.table
    local h = fs.open(W.FILES.table, "w")
    h.write(textutils.serialize({ rev = t.rev, view = t.view, anchor = t.anchor }))
    h.close()
  end)
end

-- Ask storage (waits; only from the worker). nil, why on no answer
function M.storeAsk(q, op)
  if not M.store then M.store = rednet.lookup(W.PROTO_STORE, W.HOST_STORE) end
  if not M.store then return nil, "no storage computer (warstore) on the wire" end
  M.seq = M.seq + 1
  local id = M.seq
  q.op, q.id = op, id
  rednet.send(M.store, q, W.PROTO_STORE)
  local deadline = os.startTimer(W.cfg.storeWait)
  while true do
    local e, a, b, c = os.pullEvent()
    if e == "rednet_message" and a == M.store and c == W.PROTO_STORE and type(b) == "table" and b.op == op and b.id == id then
      return b
    elseif e == "timer" and a == deadline then
      M.store = nil
      return nil, "storage did not answer"
    end
  end
end

function M.storeTops(q) return M.storeAsk(q, "tops") end
function M.storeRuns(q) return M.storeAsk(q, "runs") end

-- The top-down map: size x size pixels, each a cell's colour (the block's
-- texture, colours.txt), lit like Xaero's / a vanilla map by its slope to the
-- north and west. px2: 2 bytes a pixel (rows north -> south, each west ->
-- east) into pal (0xAARRGGBB)
function M.image(r, size, cell)
  local ys, cols, known = {}, {}, 0
  local names = r.names
  for k = 1, size * size do
    local hi, lo = r.hs:byte(2 * k - 1, 2 * k)
    local v = hi * 256 + lo
    if v > 0 then
      ys[k] = v - W.Y0
      cols[k] = W.colour(names[r.bs:byte(k)] or "")
      known = known + 1
    end
  end
  local pal, pidx, px = {}, {}, {}
  local function index(argb)
    local i = pidx[argb]
    if not i then
      if #pal >= 65535 then return 1 end
      pal[#pal + 1] = argb
      i = #pal
      pidx[argb] = i
    end
    return i
  end
  local unknown = index(0xFF000000 + W.UNKNOWN)
  local n = 0
  for j = 0, size - 1 do               -- rows: z
    for i = 0, size - 1 do             -- columns: x
      local k = i * size + j + 1
      local y = ys[k]
      local pi
      if not y then
        pi = unknown
      else
        local yw, yn = ys[k - size] or y, ys[k - 1] or y
        if j == 0 then yn = y end
        local slope = ((y - yw) + (y - yn)) / cell
        local level = clamp(math.floor(slope * 0.6 + 3.5), 1, #W.SHADES)
        local c, f = cols[k], W.SHADES[level]
        local rr = clamp(math.floor(math.floor(c / 65536) % 256 * f), 0, 255)
        local gg = clamp(math.floor(math.floor(c / 256) % 256 * f), 0, 255)
        local bb = clamp(math.floor(c % 256 * f), 0, 255)
        pi = index(0xFF000000 + rr * 65536 + gg * 256 + bb)
      end
      px[n + 1], px[n + 2] = math.floor(pi / 256), pi % 256
      n = n + 2
    end
  end
  return W.bytes(px), pal, known
end

-- What a pair of glasses asked for -> the answer to send back
function M.answer(req)
  local op = req.op
  if op == "overview" then
    local size = clamp(math.floor(tonumber(req.size) or 256), 8, 512)
    local span = clamp(math.floor(tonumber(req.span) or 256), 8, 16384)
    -- (whole blocks a pixel, as close to the span asked as that allows: 768 = 384 pixels of 2)
    local cell = math.max(1, math.ceil(span / size))
    size = clamp(math.floor(span / cell), 8, 512)
    local cx, cz = tonumber(req.cx) or 0, tonumber(req.cz) or 0
    local x0, z0 = math.floor(cx - cell * size / 2), math.floor(cz - cell * size / 2)
    local r, why = M.storeTops({ x0 = x0, z0 = z0, cell = cell, w = size, h = size, samples = W.cfg.imageSamples })
    if not r then return { op = "error", id = req.id, text = why } end
    local px, pal, known = M.image(r, size, cell)
    return { op = "overview", id = req.id, cx = x0 + cell * size / 2, cz = z0 + cell * size / 2, span = cell * size,
      size = size, px2 = px, pal = pal, known = known }
  elseif op == "view" then
    local r, why
    if tonumber(req.vox) then
      r, why = M.voxPiece(tonumber(req.cx) or 0, tonumber(req.cz) or 0, tonumber(req.area) or 64, tonumber(req.vox))
    else
      r, why = M.piece(tonumber(req.cx) or 0, tonumber(req.cz) or 0, tonumber(req.area) or 64,
        clamp(math.floor(tonumber(req.cells) or 1200), 16, 12000), tonumber(req.gap), tonumber(req.cap), tonumber(req.px))
    end
    if not r then return { op = "error", id = req.id, text = why } end
    r.op, r.id = "view", req.id
    return r
  elseif op == "point" then
    local r, why = M.storeAsk({ x = req.x, z = req.z }, "point")
    if not r then return { op = "error", id = req.id, text = why } end
    return { op = "point", id = req.id, x = r.x, z = r.z, y = r.y, name = r.name, colour = r.name and W.colour(r.name) }
  end
end

-- How a 3D view of `area` blocks across is made: area = 1 or 3 x a power of
-- 2 (else the next power of 2). Up to 256 across a sample is a block; wider,
-- 256 (or 192) samples of `cell` blocks - as fine as the terrain is known
-- there (every block within ~500 of the middle, then 4, then 8). The
-- pictures on top: a texel every `tcell` blocks, about `px` texels across
-- the view (the glasses' detail level; at most 768 - more than the view
-- shows on screen) -> area, samples, cell, tcell
function W.plan(area, px)
  area = clamp(math.floor(tonumber(area) or 64), 4, 4096)
  local odd = area
  while odd % 2 == 0 do odd = odd / 2 end
  if odd ~= 1 and odd ~= 3 then
    local p = 4
    while p < area do p = p * 2 end
    area = p
  end
  local cell = 1
  if area > 256 then cell = math.floor(area / (odd == 3 and 192 or 256)) end
  local tcell = 1
  if cell > 1 then
    px = clamp(tonumber(px) or 384, 128, 768)
    local want = math.max(area / (1.4 * px), area / 768)
    while tcell < want and tcell < cell do tcell = tcell * 2 end
  end
  return area, math.floor(area / cell), cell, tcell
end

-- `area` blocks square centred on cx, cz in 3D (what the glasses draw), at
-- most `cells` squares fitted to the ground (storage's quad: detail where
-- there is detail, down to single samples), topped with pictures about
-- `px` texels across. colours: the names' map colours (gap, cap, px: the
-- glasses' detail level - else warmap.cfg's)
function M.piece(cx, cz, area, cells, gap, cap, px)
  gap, cap = clamp(gap or W.cfg.gap, 1, 64), clamp(cap or W.cfg.maxRuns, 1, 16)
  local N, cell, tcell
  area, N, cell, tcell = W.plan(area, px)
  local x0, z0 = math.floor(cx - area / 2), math.floor(cz - area / 2)
  local r, why = M.storeAsk({ x0 = x0, z0 = z0, size = N, cell = cell, tcell = tcell, cells = cells, gap = gap, cap = cap },
    "quad")
  if not r then return nil, why end
  -- (size: samples across; area: blocks)
  local out = { kind = r.kind or "quad", size = r.size or N, cell = r.cell, tcell = r.tcell, area = area, x0 = x0, z0 = z0,
    cx = x0 + area / 2, cz = z0 + area / 2, qs = r.qs, count = r.count, rb = r.rb }
  out.names, out.colours, out.tiles, out.sides = r.names, {}, {}, {}
  for i, name in ipairs(r.names) do
    out.colours[i] = W.colour(name)
    out.tiles[i] = W.tiles[W.base(name)] or false
    out.sides[i] = W.sideTiles[W.base(name)] or false
  end
  return out
end

function M.coloursSig()
  local out = {}
  for _, f in ipairs({ "colours.txt", "tiles.txt" }) do out[#out + 1] = fs.exists(f) and fs.getSize(f) or 0 end
  return table.concat(out, ",")
end

-- For the glasses' slices (every block): `area` blocks square around cx, cz
-- as a grid of at most `most` columns a side (a column of several blocks
-- wide), each with every run in it - only touching runs joined, air gaps kept
-- (the gap under a bridge, between a ship's decks) - and their layers
function M.voxPiece(cx, cz, area, most)
  area = clamp(math.floor(tonumber(area) or 64), 4, 4096)
  most = clamp(math.floor(tonumber(most) or 64), 16, 256)
  -- (a view that fits 256 across: always a column a block, whatever the
  -- glasses' detail level - merged blocks look like Distant Horizons' far
  -- terrain. The detail level still sets how sharp the pictures are)
  if area <= 256 and most < area then most = area end
  local cell = math.max(1, math.ceil(area / most))
  while area % cell ~= 0 do cell = cell + 1 end
  local n = math.floor(area / cell)
  local x0, z0 = math.floor(cx - area / 2), math.floor(cz - area / 2)
  local r, why = M.storeRuns({ x0 = x0, z0 = z0, cell = cell, w = n, h = n, samples = cell <= 2 and cell or 2,
    gap = 1, cap = 12, fineUpTo = W.cfg.fineUpTo })
  if not r then return nil, why end
  local out = { kind = "grid", vox = true, n = n, cell = cell, size = n * cell, area = n * cell, x0 = x0, z0 = z0,
    cx = x0 + n * cell / 2, cz = z0 + n * cell / 2, rs = r.rs, rb = r.rb }
  out.names, out.colours, out.tiles, out.sides = r.names, {}, {}, {}
  for i, name in ipairs(r.names) do
    out.colours[i] = W.colour(name)
    out.tiles[i] = W.tiles[W.base(name)] or false
    out.sides[i] = W.sideTiles[W.base(name)] or false
  end
  return out
end

function M.tableMsg()
  local t = M.table
  return { op = "table", rev = t.rev, view = t.view, anchor = t.anchor, data = t.data }
end

function M.broadcastTable()
  pcall(rednet.broadcast, M.tableMsg(), W.PROTO_MAP)
end

-- The table's ground: slices (every block - the glasses' renderer, vox) or squares
function M.tablePiece(cx, cz, area, o)
  if o.vox then return M.voxPiece(cx, cz, area, o.vox) end
  return M.piece(cx, cz, area, o.cells or W.cfg.tableSquares, o.gap, o.cap, o.px)
end

-- The table shows `area` blocks (what the glasses' 3D view showed) around cx, cz
function M.setView(v)
  local area = clamp(tonumber(v.area) or 64, 4, 8192)
  local cx, cz = tonumber(v.cx) or 0, tonumber(v.cz) or 0
  -- (the glasses' detail level: squares, gap, cap - else warmap.cfg's)
  local cells = clamp(math.floor(tonumber(v.cells) or W.cfg.tableSquares), 16, 12000)
  local data, why = M.tablePiece(cx, cz, area, { cells = cells, gap = tonumber(v.gap), cap = tonumber(v.cap),
    px = tonumber(v.px), vox = tonumber(v.vox) })
  if not data then return false, why end
  local t = M.table
  t.view = { cx = data.cx, cz = data.cz, area = data.area or area, yaw = tonumber(v.yaw) or 0, lift = tonumber(v.lift) or 0,
    cells = cells, gap = tonumber(v.gap), cap = tonumber(v.cap), px = tonumber(v.px), vox = tonumber(v.vox) }
  t.data, t.rev, t.dirty = data, t.rev + 1, false
  M.refreshedAt = now()
  M.saveTable()
  M.broadcastTable()
  return true
end

-- Where the table stands: ship = r u f from the nav table (moves with the
-- ship), world = fixed coordinates; yaw degrees; size blocks across
function M.cleanAnchor(a)
  if type(a) ~= "table" then return nil end
  local out = { yaw = tonumber(a.yaw) or 0, size = clamp(tonumber(a.size) or 3, 0.5, 16) }
  local v = a.mode == "world" and a.world or a.rel
  if type(v) ~= "table" or not (tonumber(v[1]) and tonumber(v[2]) and tonumber(v[3])) then return nil end
  out.mode = a.mode == "world" and "world" or "ship"
  out[out.mode == "world" and "world" or "rel"] = { tonumber(v[1]), tonumber(v[2]), tonumber(v[3]) }
  return out
end

-- Did a scan find any ground (a height byte over 0)?
function M.found(msg)
  local d = type(msg.d) == "string" and msg.d or ""
  for p = 1, #d, 2 do
    if d:byte(p) > 0 then return true end
  end
  return false
end

-- New scans inside the table's area: redraw it (at most every tableRefresh s)
function M.touches(msg)
  local t = M.table
  if not t.data then return false end
  local x0, z0 = t.data.x0, t.data.z0
  local size = t.data.area or t.data.size or ((t.data.cell or 1) * (t.data.n or 1))
  local ox, oz, r = tonumber(msg.ox), tonumber(msg.oz), tonumber(msg.r) or 0
  if not (ox and oz) then return false end
  return ox + r >= x0 and ox - r < x0 + size and oz + r >= z0 and oz - r < z0 + size
end

-- A scan wholly where storage knows every block, the table drawn from every
-- block there (1 or 2 blocks a cell): it cannot change the table (the full
-- detail wins over scans) - no redraw for it. Not known: false (redraw as before)
function M.fineCovers(msg)
  local info, data = M.storeInfo, M.table.data
  if not (info and type(info.fine) == "table" and data) then return false end
  local cell = tonumber(data.cell) or 1
  if cell > 2 then return false end
  local ox, oz, r = tonumber(msg.ox), tonumber(msg.oz), tonumber(msg.r) or 0
  if not (ox and oz) then return false end
  for _, f in ipairs(info.fine) do
    if type(f) == "table" and tonumber(f[1]) and ox - r >= f[1] and oz - r >= f[2] and ox + r <= f[3] and oz + r <= f[4] then
      return true
    end
  end
  return false
end

function M.refresh()
  local t = M.table
  -- (just started: no ground yet - straight away)
  if not (t.dirty and t.view) or (t.data and now() - (M.refreshedAt or -100) < W.cfg.tableRefresh) then return end
  M.refreshedAt = now()
  -- (a table set by warmap 1.0 / 1.1 has cell and n, not area)
  local area = t.view.area or ((t.view.cell or 1) * (t.view.n or 40))
  local data, why = M.tablePiece(t.view.cx, t.view.cz, area, t.view)
  if data then
    t.view.area = area
    t.data, t.rev, t.dirty = data, t.rev + 1, false
    M.saveTable()
    M.broadcastTable()
    W.log(("table redrawn (%s)"):format(M.refreshWhy or "newer ground"))
  else
    W.log("table redraw failed: " .. tostring(why))
  end
  M.refreshWhy = nil
end

-- Messages: quick ones here, slow ones (storage) to the worker
function M.onMessage(from, msg, proto)
  if type(msg) ~= "table" then return end
  if proto == W.PROTO_TEAM and msg.op == "terrain" and msg.v == 2 then
    local ok, err
    if M.store then
      ok, err = pcall(rednet.send, M.store, msg, W.PROTO_STORE)
    else
      -- (storage not found just now - it answers lookups slowly when busy: to anyone on the wire)
      ok, err = pcall(rednet.broadcast, msg, W.PROTO_STORE)
      err = err or "storage not found - sent to the wire"
    end
    M.scans = (M.scans or 0) + 1
    if M.scans == 1 or M.scans % 50 == 0 or not ok then
      W.log(("scans from helldivers: %d (last from %d at %d,%d) -> storage %s%s"):format(M.scans, from, msg.ox or 0,
        msg.oz or 0, tostring(M.store), ok and "" or (": NOT PASSED ON - " .. tostring(err))))
    end
    -- (a scan that found nothing - from high up, from a ship - changes nothing: no redraw)
    -- (nor does one where every block is known already)
    if M.touches(msg) and M.found(msg) and not M.fineCovers(msg) then
      M.table.dirty, M.refreshWhy = true, M.refreshWhy or "a helldiver's scan"
    end
  elseif proto == W.PROTO_MAP then
    if msg.op == "table?" then
      pcall(rednet.send, from, M.tableMsg(), W.PROTO_MAP)
    elseif msg.op == "setanchor" then
      local a = M.cleanAnchor(msg.anchor)
      if a then
        M.table.anchor, M.table.rev = a, M.table.rev + 1
        M.saveTable()
        M.broadcastTable()
        W.log(("table placed (%s, %.1f blocks)"):format(a.mode, a.size))
      end
    elseif msg.op == "overview" or msg.op == "view" or msg.op == "settable" or msg.op == "point" then
      -- (one of each kind per pair of glasses waiting: a newer ask replaces an older)
      for i = #M.jobs, 1, -1 do
        if M.jobs[i].from == from and M.jobs[i].msg.op == msg.op then table.remove(M.jobs, i) end
      end
      M.jobs[#M.jobs + 1] = { from = from, msg = msg }
      os.queueEvent("warmap_job")
    end
  elseif proto == W.PROTO_STORE and msg.op == "info" then
    -- (new Distant Horizons layers from the PC: the table's ground again)
    local sig = tostring(msg.sig or (type(msg.layers) == "table" and table.concat(msg.layers, ",")) or "")
    if M.storeInfo and M.layerSig ~= sig and M.table.view then M.table.dirty, M.refreshWhy = true, "new Distant Horizons layers" end
    M.storeInfo, M.layerSig = msg, sig
  end
end

function M.worker()
  while true do
    while #M.jobs > 0 do
      local j = table.remove(M.jobs, 1)
      local ok, err = pcall(function()
        if j.msg.op == "settable" then
          local done, why = M.setView(type(j.msg.view) == "table" and j.msg.view or {})
          if not done then rednet.send(j.from, { op = "error", id = j.msg.id, text = why }, W.PROTO_MAP) end
          W.log(done and ("table view: %d,%d %d blocks across"):format(M.table.view.cx, M.table.view.cz, M.table.view.area)
            or ("table view failed: " .. tostring(why)))
        else
          local reply = M.answer(j.msg)
          if reply then rednet.send(j.from, reply, W.PROTO_MAP) end
        end
      end)
      if not ok then W.log("job " .. tostring(j.msg.op) .. ": " .. tostring(err)) end
    end
    pcall(M.refresh)
    local t = os.startTimer(1)
    repeat
      local e, id = os.pullEvent()
    until e == "warmap_job" or (e == "timer" and id == t)
  end
end

---------------------------------------------------------------- loops

function W.openModems()
  local wireless, wired = false, false
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name, "modem") then
      rednet.open(name)
      if peripheral.call(name, "isWireless") then wireless = true else wired = true end
    end
  end
  return wireless, wired
end

-- Servers: the map from GitHub. There the PC cannot write this computer's
-- files, so its dhwatch.py puts them in a GitHub repository (warmap.cfg
-- remote) and this downloads them: storage the terrain layers (dh/), the map
-- computer the block colours. manifest.txt says what is there and the commit
-- to take it from (that name never changes under a download).
local R = { have = {}, file = "remote.txt" }
W.R = R

function R.on()
  return type(W.cfg.remote) == "string" and W.cfg.remote:match("^[%w%-_.]+/[%w%-_.]+$") ~= nil
end

function R.get(path, ref)
  if not http then error("http is off on this server", 0) end
  local url = ("https://raw.githubusercontent.com/%s/%s/%s"):format(W.cfg.remote, ref, path)
  local h, err, bad = http.get({ url = url, binary = true })
  if not h then
    if bad then pcall(bad.close) end
    error(path:gsub("%?.*$", "") .. ": " .. tostring(err), 0)      -- (the same error, the same words: logged once)
  end
  local body = h.readAll() or ""
  h.close()
  return body
end

-- The branch's newest commit, from git's own ref listing on github.com (never
-- cached - raw.githubusercontent.com's copy of a branch can lag 5+ minutes)
local HEX40 = ("%x"):rep(40)
function R.head()
  if not http then return nil end
  local h, _, bad = http.get({ url = ("https://github.com/%s.git/info/refs?service=git-upload-pack"):format(W.cfg.remote), binary = true })
  if not h then
    if bad then pcall(bad.close) end
    return nil
  end
  local body = h.readAll() or ""
  h.close()
  for sha, ref in body:gmatch("(" .. HEX40 .. ") ([^\n]+)") do
    if ref:match("^[^%c]+") == "refs/heads/" .. W.cfg.remoteBranch then return sha end
  end
end

function R.manifest()
  -- (by the commit when git says which; else the branch, maybe a few minutes old)
  local body = R.get("manifest.txt", R.head() or W.cfg.remoteBranch)
  local m = { commit = body:match("\ncommit (%x+)"), made = tonumber(body:match("\nmade (%d+)")), files = {}, runs = {} }
  local cx, cz = body:match("\ncentre (%-?%d+) (%-?%d+)")
  m.cx, m.cz = tonumber(cx), tonumber(cz)
  if body:sub(1, 8) ~= "WARMAP 1" or not m.commit then error("manifest.txt is not the war table's", 0) end
  for kind, path, size, sha, radius in body:gmatch("\n(%a+) (%S+) (%d+) (%x+) ?(%d*)") do
    local e = { path = path, size = tonumber(size), sha = sha, radius = tonumber(radius) }
    if kind == "file" then m.files[#m.files + 1] = e elseif kind == "runs" then m.runs[#m.runs + 1] = e end
  end
  return m
end

-- remote.txt: which download each file is (none again after a reboot)
function R.load()
  R.have = {}
  if not fs.exists(R.file) then return end
  local h = fs.open(R.file, "r")
  for name, sha in h.readAll():gmatch("(%S+) (%x+)") do R.have[name] = sha end
  h.close()
end

function R.save()
  local out = {}
  for name, sha in pairs(R.have) do out[#out + 1] = name .. " " .. sha end
  local h = fs.open(R.file, "w")
  if h then
    h.write(table.concat(out, "\n") .. "\n")
    h.close()
  end
end

-- One file of the manifest -> dest, unless dest is that one already
function R.take(m, e, dest)
  if R.have[dest] == e.sha and fs.exists(dest) then return false end
  local old = fs.exists(dest) and fs.getSize(dest) or 0
  local free = fs.getFreeSpace("/") - (W.role == "store" and W.cfg.keepFree or 0)
  if e.size > free then
    if e.size > free + old then
      error(("%s: %d KB, only %d KB free"):format(e.path, math.ceil(e.size / 1000), math.floor((free + old) / 1000)), 0)
    end
    fs.delete(dest)                       -- (room for the new one)
  end
  local body = R.get(e.path, m.commit)
  if #body ~= e.size then error(("%s: got %d of %d bytes"):format(e.path, #body, e.size), 0) end
  local f = fs.open(dest .. ".tmp", "wb")
  f.write(body)
  f.close()
  if fs.exists(dest) then fs.delete(dest) end
  fs.move(dest .. ".tmp", dest)
  R.have[dest] = e.sha
  R.save()
  return true
end

-- Storage: the height maps, the biggest every-block layer that fits (the rest
-- of storage is helldiver scans); layers no longer offered go
function R.storeOnce(m)
  fs.makeDir(W.FILES.dh)
  local n, want = 0, {}
  local dest = fs.combine(W.FILES.dh, "auto_runs.bin")
  local function size(p) return fs.exists(p) and fs.getSize(p) or 0 end
  table.sort(m.runs, function(a, b) return a.size > b.size end)
  -- (the height maps and the biggest every-block layer win over old helldiver
  -- scans: on a server Distant Horizons is the map) - room for all of it first
  local best, coming = m.runs[1], 0
  for _, e in ipairs(m.files) do
    local name = e.path:match("^dh/(auto_[%w_]+%.bin)$")
    local p = name and fs.combine(W.FILES.dh, name)
    if p and R.have[p] ~= e.sha then coming = coming + e.size - size(p) end
  end
  if best and R.have[dest] ~= best.sha then coming = coming + best.size - size(dest) end
  local spare = fs.getFreeSpace("/") - W.cfg.keepFree - 20000
  if m.cx and coming > spare then S.makeRoom(coming - spare, m.cx, m.cz, best and best.radius or 0) end
  for _, e in ipairs(m.files) do
    local name = e.path:match("^dh/(auto_[%w_]+%.bin)$")
    if name then
      want[name] = true
      if R.take(m, e, fs.combine(W.FILES.dh, name)) then n = n + 1 end
    end
  end
  local room = fs.getFreeSpace("/") - W.cfg.keepFree - 20000 + size(dest)
  for _, e in ipairs(m.runs) do
    if e.size <= room then
      want["auto_runs.bin"] = true
      if R.take(m, e, dest) then n = n + 1 end
      break
    end
  end
  if #m.runs > 0 and not want["auto_runs.bin"] then
    W.log("server map: no every-block layer fits - storage is full of scans")
  end
  for _, f in ipairs(fs.list(W.FILES.dh)) do
    if f:match("^auto_.*%.bin$") and not want[f] then
      fs.delete(fs.combine(W.FILES.dh, f))
      n = n + 1
    end
  end
  return n
end

-- Map computer: the block colours (keeper reads them again itself)
function R.mapOnce(m)
  local n = 0
  for _, e in ipairs(m.files) do
    if (e.path == "colours.txt" or e.path == "tiles.txt") and R.take(m, e, e.path) then n = n + 1 end
  end
  return n
end

function R.loop()
  R.load()
  local last
  while true do
    local ok, err = pcall(function()
      local m = R.manifest()
      if m.commit == R.commit then return end
      local n = W.role == "store" and R.storeOnce(m) or R.mapOnce(m)
      R.commit, R.made = m.commit, m.made
      if n > 0 then W.log(("server map: %d file(s) from %s (%s)"):format(n, W.cfg.remote, m.commit:sub(1, 7))) end
    end)
    if ok then
      local age = R.made and os.epoch and math.floor((os.epoch("utc") / 1000 - R.made) / 60)
      R.status = ("server map: %s%s"):format(W.cfg.remote, age and (", made %d min ago"):format(math.max(0, age)) or "")
    else
      R.status = "server map: " .. tostring(err)
      if err ~= last then W.log(R.status) end
    end
    last = not ok and err or nil
    sleep(math.max(15, tonumber(W.cfg.remoteEvery) or 60))
  end
end

function W.status()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.yellow)
  print(("WAR TABLE %s - %s (computer %d)"):format(W.VERSION, W.role == "map" and "MAP" or "STORAGE", os.getComputerID()))
  term.setTextColor(colors.white)
  if W.role == "map" then
    print("storage: " .. (M.store and ("computer " .. M.store) or "NOT FOUND (wired modems + cable?)"))
    local t = M.table
    print(("table: %s, %s"):format(t.view and ("%d,%d, %d blocks across"):format(t.view.cx, t.view.cz,
      t.view.area or (t.view.cell or 1) * (t.view.n or 40)) or "no view yet",
      t.anchor and ("placed (" .. t.anchor.mode .. ")") or "not placed yet"))
    print(("scans passed on: %d   waiting: %d"):format(M.scans or 0, #M.jobs))
    local i = M.storeInfo
    if i then
      print(("storage: %d tiles, %d KB free%s"):format(i.tiles or 0, math.floor((i.free or 0) / 1000), i.full and " - FULL" or ""))
      for _, l in ipairs(i.layers or {}) do print("  DH " .. l) end
    end
  else
    local tiles = 0
    for _ in pairs(S.have) do tiles = tiles + 1 end
    print(("scans recorded: %d   tiles: %d   free: %d KB%s"):format(S.scans or 0, tiles,
      math.floor((fs.getFreeSpace("/") or 0) / 1000), S.full and " - FULL" or ""))
    print(#S.layers + #S.runLayers .. " Distant Horizons layer(s):")
    for _, d in ipairs(S.runLayers) do
      print(("  %s: %dx%d blocks, every block (%d tiles unpacked)"):format(d.file, d.sw * 64, d.sh * 64, S.runCached))
    end
    for _, d in ipairs(S.layers) do print(("  %s: %dx%d cells of %d"):format(d.file, d.w, d.h, d.cell)) end
  end
  if R.on() then print(R.status or ("server map: " .. W.cfg.remote .. " - looking")) end
  term.setTextColor(colors.lightGray)
  print("")
  print("Ctrl+T: stop")
end

function W.storeMain()
  S.loadPal()
  S.index()
  S.loadLayers()
  rednet.host(W.PROTO_STORE, W.HOST_STORE)
  local jobs = {}
  local function receiver()
    while true do
      local from, msg = rednet.receive(W.PROTO_STORE)
      if type(msg) == "table" then
        if msg.op == "terrain" then
          S.noteWhere("scan", msg.ox, msg.oz)
          local ok, err = pcall(S.putScan, msg)
          if not ok then W.log("scan: " .. tostring(err))
          elseif S.scans == 1 or (S.scans or 0) % 50 == 0
            or (err == 0 and now() - (S.emptyLoggedAt or -100) >= 60) then
            -- (scans that stored nothing: logged once a minute at most, not every one)
            if err == 0 then S.emptyLoggedAt = now() end
            W.log(("scans recorded: %d (last at %d,%d: %s columns)%s"):format(S.scans or 0, tonumber(msg.ox) or 0,
              tonumber(msg.oz) or 0, tostring(err), S.full and " - STORAGE FULL" or ""))
          end
        elseif msg.op == "tops" or msg.op == "runs" or msg.op == "quad" or msg.op == "point" or msg.op == "info" then
          -- (the middle of what the map asks for)
          local x0, z0 = tonumber(msg.x0), tonumber(msg.z0)
          if x0 and z0 and msg.op == "quad" then
            S.noteWhere("view", x0 + (tonumber(msg.size) or 0) / 2, z0 + (tonumber(msg.size) or 0) / 2)
          elseif x0 and z0 and msg.op ~= "point" and msg.op ~= "info" then
            local cell = tonumber(msg.cell) or 1
            S.noteWhere("view", x0 + cell * (tonumber(msg.w) or 0) / 2, z0 + cell * (tonumber(msg.h) or 0) / 2)
          end
          jobs[#jobs + 1] = { from = from, msg = msg }
          os.queueEvent("warstore_job")
        end
      end
    end
  end
  local function yield()
    os.queueEvent("warstore_yield")
    os.pullEvent("warstore_yield")
  end
  local function worker()
    local flushAt, statusAt = now(), 0
    while true do
      while #jobs > 0 do
        local j = table.remove(jobs, 1)
        local ok, err = pcall(function()
          local fn = ({ tops = S.tops, runs = S.runs, quad = S.quad, point = S.point })[j.msg.op]
          if fn then
            local r = fn(j.msg, yield)
            r.op, r.id = j.msg.op, j.msg.id
            rednet.send(j.from, r, W.PROTO_STORE)
          else
            rednet.send(j.from, S.info(), W.PROTO_STORE)
          end
        end)
        if not ok then W.log("tops: " .. tostring(err)) end
      end
      if now() - flushAt > 10 then
        flushAt = now()
        local ok, err = pcall(S.flush)
        if not ok then W.log("saving: " .. tostring(err)) end
        pcall(S.saveWhere)
        ok, err = pcall(S.checkLayers)
        if not ok then W.log("layers: " .. tostring(err)) end
      end
      if now() - statusAt > 2 then
        statusAt = now()
        pcall(W.status)
      end
      local t = os.startTimer(1)
      repeat
        local e, id = os.pullEvent()
      until e == "warstore_job" or (e == "timer" and id == t)
    end
  end
  local tasks = { receiver, worker }
  if R.on() then tasks[#tasks + 1] = R.loop end
  local ok, err = pcall(parallel.waitForAny, table.unpack(tasks))
  pcall(S.flush)
  if not ok and err ~= "Terminated" then
    W.log("stopped: " .. tostring(err))
    printError(err)
  end
end

function W.mapMain()
  M.loadTable()
  W.log(("block colours: %d from colours.txt, %d textures from tiles.txt"):format(W.loadColours(), W.loadTiles()))
  rednet.host(W.PROTO_MAP, W.HOST_MAP)
  local function receiver()
    while true do
      local e, from, msg, proto = os.pullEvent("rednet_message")
      local ok, err = pcall(M.onMessage, from, msg, proto)
      if not ok then W.log("message: " .. tostring(err)) end
    end
  end
  local function keeper()
    local coloursSig = M.coloursSig()
    while true do
      -- (the PC's dhwatch.py adds the colours of new kinds of block)
      local sig = M.coloursSig()
      if sig ~= coloursSig then
        coloursSig = sig
        W.log(("block colours again: %d from colours.txt, %d textures from tiles.txt"):format(W.loadColours(), W.loadTiles()))
        if M.table.view then M.table.dirty = true end
      end
      if not M.store then M.store = rednet.lookup(W.PROTO_STORE, W.HOST_STORE) end
      if M.store then pcall(rednet.send, M.store, { op = "info" }, W.PROTO_STORE) end
      -- (glasses that missed a change catch up)
      if M.table.anchor and M.table.data then M.broadcastTable() end
      pcall(W.status)
      sleep(M.store and 15 or 3)
    end
  end
  local tasks = { receiver, M.worker, keeper }
  if R.on() then tasks[#tasks + 1] = R.loop end
  local ok, err = pcall(parallel.waitForAny, table.unpack(tasks))
  if not ok and err ~= "Terminated" then
    W.log("stopped: " .. tostring(err))
    printError(err)
  end
end

function W.main()
  W.loadConfig()
  local wireless, wired = W.openModems()
  W.role = W.cfg.role
  if W.role ~= "map" and W.role ~= "store" then W.role = wireless and "map" or "store" end
  if not wired then print("No wired modem: wire this computer to the other war table computer.") end
  if W.role == "map" and not wireless then print("No ender modem: the glasses cannot reach this computer.") end
  W.log(("started %s as %s"):format(W.VERSION, W.role))
  if W.role == "map" then W.mapMain() else W.storeMain() end
  print("war table stopped")
end

if ARG == "lib" then return W end
W.main()
