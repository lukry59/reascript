-- @noindex
-- Band-pass (two cascaded RBJ biquads) + 10 ms peak envelope (pure Lua).
local M = {}
local floor, max, log, sqrt, sin, cos, pi = math.floor, math.max, math.log, math.sqrt, math.sin, math.cos, math.pi

local Tracker = {}
Tracker.__index = Tracker

function M.new(sr, lo, hi, frame_s)
  local fc = sqrt(lo * hi)
  local q = fc / max(hi - lo, 1)
  local w0 = 2 * pi * fc / sr
  local alpha = sin(w0) / (2 * q)
  local a0 = 1 + alpha
  local len = max(1, floor(sr * (frame_s or 0.010) + 0.5))
  return setmetatable({
    b0 = alpha / a0, b2 = -alpha / a0, a1 = -2 * cos(w0) / a0, a2 = (1 - alpha) / a0,
    x1 = 0, x2 = 0, y1 = 0, y2 = 0, v1 = 0, v2 = 0,
    frame_len = len, frame_rate = sr / len, pos = 0, cur = 0, env = {}, lo = lo, hi = hi,
  }, Tracker)
end

function Tracker:push(block, n)
  local b0, b2, a1, a2 = self.b0, self.b2, self.a1, self.a2
  local x1, x2, y1, y2, v1, v2 = self.x1, self.x2, self.y1, self.y2, self.v1, self.v2
  local pos, cur, len, env = self.pos, self.cur, self.frame_len, self.env
  local ne = #env
  for i = 1, n or #block do
    local x = block[i]
    local y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
    x2, x1 = x1, x
    -- second section takes y as input; its x history is (y1, y2) before the shift
    local v = b0 * y + b2 * y2 - a1 * v1 - a2 * v2
    y2, y1 = y1, y
    v2, v1 = v1, v
    if v < 0 then v = -v end
    if v > cur then cur = v end
    pos = pos + 1
    if pos == len then
      ne = ne + 1
      env[ne] = cur
      pos, cur = 0, 0
    end
  end
  self.x1, self.x2, self.y1, self.y2, self.v1, self.v2 = x1, x2, y1, y2, v1, v2
  self.pos, self.cur = pos, cur
end

function M.percentile(t, q)
  if #t == 0 then return -200 end
  local s = {}
  for i, v in ipairs(t) do s[i] = v end
  table.sort(s)
  return s[max(1, floor(#s * q + 0.5))]
end

function Tracker:finish()
  if self.pos > 0 then
    self.env[#self.env + 1] = self.cur
    self.pos, self.cur = 0, 0
  end
  local env, db = self.env, {}
  for i = 1, #env do
    local v = env[i]
    local p = env[i - 1]
    if p and p > v then v = p end
    db[i] = 20 * log(max(v, 1e-10), 10)
  end
  return { env_db = db, fr = self.frame_rate, noise_db = M.percentile(db, 0.10), lo = self.lo, hi = self.hi }
end

return M
