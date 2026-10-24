--[[
shipgps.lua - the Super Destroyer's private GPS                     v1.0.0
Shared by shiphost.lua (answers) and remote.lua (asks).

CC's own gps uses channel 65534, which every GPS host in the world answers
on - including hosts that announce world coordinates. Mixing those with the
ship's hosts (which announce blocks right/up/forward of the nav table) makes
a position impossible. So the ship uses its own channel and message.

locate() solves all replies at once (least squares on the sphere equations),
so 4 hosts not in one plane give one answer, and a host with wrong numbers
shows up as a large error instead of a wrong position.
]]

local G = {}
G.CHANNEL = 65100
G.PING = "DESTROYER_GPS_PING"

local function solve3(m, b)
  -- Cramer's rule for a 3x3 system m x = b
  local function det(a)
    return a[1][1] * (a[2][2] * a[3][3] - a[2][3] * a[3][2])
      - a[1][2] * (a[2][1] * a[3][3] - a[2][3] * a[3][1])
      + a[1][3] * (a[2][1] * a[3][2] - a[2][2] * a[3][1])
  end
  local d = det(m)
  if math.abs(d) < 1e-9 then return nil end
  local x = {}
  for c = 1, 3 do
    local mc = { { m[1][1], m[1][2], m[1][3] }, { m[2][1], m[2][2], m[2][3] }, { m[3][1], m[3][2], m[3][3] } }
    for r = 1, 3 do mc[r][c] = b[r] end
    x[c] = det(mc) / d
  end
  return x
end

-- fixes: list of { p = {x, y, z}, d = distance }. Returns position {x, y, z}
-- and the RMS distance error (blocks), or nil and a reason.
function G.solve(fixes)
  if #fixes < 4 then return nil, ("heard %d of 4 hosts"):format(#fixes) end
  local p1, d1 = fixes[1].p, fixes[1].d
  local n1 = p1[1] ^ 2 + p1[2] ^ 2 + p1[3] ^ 2
  -- rows: 2 (pi - p1) . x = |pi|^2 - |p1|^2 - di^2 + d1^2 ; normal equations
  local ata = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
  local atb = { 0, 0, 0 }
  for i = 2, #fixes do
    local p, d = fixes[i].p, fixes[i].d
    local a = { 2 * (p[1] - p1[1]), 2 * (p[2] - p1[2]), 2 * (p[3] - p1[3]) }
    local b = (p[1] ^ 2 + p[2] ^ 2 + p[3] ^ 2) - n1 - d * d + d1 * d1
    for r = 1, 3 do
      for c = 1, 3 do ata[r][c] = ata[r][c] + a[r] * a[c] end
      atb[r] = atb[r] + a[r] * b
    end
  end
  local x = solve3(ata, atb)
  if not x then return nil, "hosts are in one flat plane" end
  local sum = 0
  for _, f in ipairs(fixes) do
    local dx, dy, dz = x[1] - f.p[1], x[2] - f.p[2], x[3] - f.p[3]
    sum = sum + (math.sqrt(dx * dx + dy * dy + dz * dz) - f.d) ^ 2
  end
  return x, math.sqrt(sum / #fixes)
end

-- Ask the ship's hosts `rounds` times (one ping per tick) and average each
-- host's distance: from far away a small distance error grows into a large
-- position error (range / host spacing), and averaging shrinks it.
-- Returns {right, up, forward}, error, hostsHeard - or nil, reason.
-- Other events arriving meanwhile are dropped.
function G.locate(modem, timeout, rounds)
  rounds = rounds or 1
  modem.open(G.CHANNEL)
  local hosts, order = {}, {}
  local pings = 1
  modem.transmit(G.CHANNEL, G.CHANNEL, G.PING)
  local tick = os.startTimer(0.05)
  local timer = os.startTimer(timeout or 1)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == timer then break end
    if ev[1] == "timer" and ev[2] == tick then
      if pings < rounds then
        pings = pings + 1
        modem.transmit(G.CHANNEL, G.CHANNEL, G.PING)
        tick = os.startTimer(0.05)
      end
    elseif ev[1] == "modem_message" and ev[3] == G.CHANNEL and type(ev[5]) == "table" and ev[6] then
      local m = ev[5]
      if tonumber(m[1]) and tonumber(m[2]) and tonumber(m[3]) then
        local key = m[1] .. "," .. m[2] .. "," .. m[3]
        local h = hosts[key]
        if not h then
          h = { p = { m[1], m[2], m[3] }, sum = 0, n = 0 }
          hosts[key] = h
          order[#order + 1] = h
        end
        h.sum, h.n = h.sum + ev[6], h.n + 1
      end
    end
    -- done once every host has answered every ping
    if pings >= rounds and #order >= 4 then
      local all = true
      for _, h in ipairs(order) do
        if h.n < rounds then all = false end
      end
      if all then break end
    end
  end
  local fixes = {}
  for _, h in ipairs(order) do fixes[#fixes + 1] = { p = h.p, d = h.sum / h.n } end
  local x, err = G.solve(fixes)
  if not x then return nil, err end
  return x, err, #fixes
end

-- Answer pings forever (for shiphost.lua). pos = {r, u, f}
function G.host(modem, pos, onServe)
  modem.open(G.CHANNEL)
  while true do
    local _, side, ch, reply, msg, dist = os.pullEvent("modem_message")
    -- dist is nil for a message from another dimension: no use for a fix
    if ch == G.CHANNEL and msg == G.PING and dist then
      peripheral.call(side, "transmit", reply, G.CHANNEL, { pos.r, pos.u, pos.f })
      if onServe then onServe() end
    end
  end
end

return G
