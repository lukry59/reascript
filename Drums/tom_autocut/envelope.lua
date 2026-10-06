-- @noindex
-- Peak envelopes and onset detection (pure Lua).
local M = {}
local log, max, min, floor, abs, exp = math.log, math.max, math.min, math.floor, math.abs, math.exp

function M.to_db(x) return 20 * log(max(x, 1e-10), 10) end

-- Streaming framer: maximum absolute sample value per frame.
local Framer = {}
Framer.__index = Framer

function M.new_framer(sr, frame_s)
  local len = max(1, floor(sr * (frame_s or 0.001) + 0.5))
  return setmetatable({ frame_len = len, frame_rate = sr / len, pos = 0, cur = 0, peaks = {} }, Framer)
end

function Framer:push(block, n)
  local pos, cur, len, peaks = self.pos, self.cur, self.frame_len, self.peaks
  local np = #peaks
  for i = 1, n or #block do
    local x = block[i]
    if x < 0 then x = -x end
    if x > cur then cur = x end
    pos = pos + 1
    if pos == len then
      np = np + 1
      peaks[np] = cur
      pos, cur = 0, 0
    end
  end
  self.pos, self.cur = pos, cur
end

function Framer:finish()
  if self.pos > 0 then
    self.peaks[#self.peaks + 1] = self.cur
    self.pos, self.cur = 0, 0
  end
  return self.peaks
end

-- fast: peak hold over hold_s (instant attack, no ripple above 1/(2*hold_s) Hz).
-- slow: one-pole smoothing of fast; it lags behind every attack.
function M.envelopes(peaks, frame_rate, opts)
  opts = opts or {}
  local hold = max(1, floor((opts.hold_s or 0.010) * frame_rate + 0.5))
  local a = 1 - exp(-1 / ((opts.slow_s or 0.020) * frame_rate))
  local fast, slow = {}, {}
  local dq, head, tail, s = {}, 1, 0, nil
  for i = 1, #peaks do
    local v = peaks[i]
    while tail >= head and peaks[dq[tail]] <= v do tail = tail - 1 end
    tail = tail + 1
    dq[tail] = i
    if dq[head] <= i - hold then head = head + 1 end
    local f = peaks[dq[head]]
    fast[i] = f
    s = s and (s + a * (f - s)) or f
    slow[i] = s
  end
  return fast, slow
end

-- Rise of the fast envelope above the previous slow value, in dB (>= 0).
function M.onset_function(fast, slow)
  local odf, prev = {}, fast[1] or 0
  for i = 1, #fast do
    local d = M.to_db(fast[i]) - M.to_db(prev)
    odf[i] = d > 0 and d or 0
    prev = slow[i]
  end
  return odf
end

-- Sliding median (window_s) + k_db, recomputed every 250 ms.
function M.adaptive_threshold(odf, frame_rate, window_s, k_db)
  local n = #odf
  local hop = max(1, floor(0.25 * frame_rate))
  local half = floor(window_s * frame_rate / 2)
  local thr, i = {}, 1
  while i <= n do
    local c = i + floor(hop / 2)
    local w = {}
    for j = max(1, c - half), min(n, c + half) do w[#w + 1] = odf[j] end
    table.sort(w)
    local med = w[floor((#w + 1) / 2)] or 0
    for j = i, min(n, i + hop - 1) do thr[j] = med + k_db end
    i = i + hop
  end
  return thr
end

function M.pick_candidates(odf, fast, frame_rate, opts)
  opts = opts or {}
  local thr = M.adaptive_threshold(odf, frame_rate, opts.median_s or 1.0, opts.k_db or 3)
  local abs_floor = opts.abs_floor_db or -70
  local min_gap = max(1, floor((opts.min_gap_s or 0.015) * frame_rate + 0.5))
  local peak_win = max(1, floor(0.010 * frame_rate + 0.5))
  local n, out = #odf, {}
  for i = 1, n do
    local v = odf[i]
    if v > thr[i] and v >= (odf[i - 1] or 0) and v > (odf[i + 1] or 0) then
      local st = i
      while st > 1 and i - st < 10 and odf[st - 1] >= 1 do st = st - 1 end
      local pf, pv = i, fast[i]
      for j = i, min(n, i + peak_win) do
        if fast[j] > pv then pv, pf = fast[j], j end
      end
      local pdb = M.to_db(pv)
      if pdb > abs_floor then
        local rise_ms = max(1, (pf - st + 1) * 1000 / frame_rate)
        local c = { frame = st, time = (st - 1) / frame_rate, peak = pv, peak_db = pdb,
                    odf_db = v, sharpness = v / rise_ms }
        local last = out[#out]
        if last and st - last.frame < min_gap then
          if v > last.odf_db then out[#out] = c end
        else
          out[#out + 1] = c
        end
      end
    end
  end
  return out
end

-- window: mono samples starting at time t0. Returns the time of the attack start.
function M.refine_onset(window, sr, t0)
  local n = #window
  local pk = 0
  for i = 1, n do
    local a = abs(window[i])
    if a > pk then pk = a end
  end
  if pk == 0 then return t0 end
  local noise = 0
  for i = 1, min(n, floor(sr * 0.002)) do
    local a = abs(window[i])
    if a > noise then noise = a end
  end
  local thr = noise + 0.1 * (pk - noise)
  for i = 1, n do
    if abs(window[i]) >= thr then
      local j = i
      while j > 1 and window[j - 1] * window[i] > 0 and (i - j) < sr * 0.002 do j = j - 1 end
      return t0 + (j - 1) / sr
    end
  end
  return t0
end

return M
