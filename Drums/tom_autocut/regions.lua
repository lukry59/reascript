-- @noindex
-- Regions: decay-driven ends, rolls, merge gap, fades (pure Lua).
local M = {}
local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil

M.DEFAULT_SLOPE_DB_S = -60

function M.band_peak(env_db, fr, t)
  local i0 = max(1, floor(t * fr) + 1)
  local i1 = min(#env_db, i0 + ceil(0.05 * fr))
  local ip, pk = i0, -math.huge
  for i = i0, i1 do
    if env_db[i] > pk then pk, ip = env_db[i], i end
  end
  return pk, ip
end

function M.measure_slope(env_db, fr, t, noise_db, max_s)
  local pk, ip = M.band_peak(env_db, fr, t)
  if pk == -math.huge then return nil end
  local stop = max(pk - 30, noise_db + 6)
  local last = min(#env_db, ip + floor((max_s or 2.5) * fr))
  local sx, sy, sxx, sxy, n, lowest = 0, 0, 0, 0, 0, math.huge
  for i = ip, last do
    local y = env_db[i]
    if y < stop or y > lowest + 3 then break end
    if y < lowest then lowest = y end
    local x = (i - ip) / fr
    sx, sy, sxx, sxy, n = sx + x, sy + y, sxx + x * x, sxy + x * y, n + 1
  end
  if n < 5 then return nil end
  local den = n * sxx - sx * sx
  if den <= 0 then return nil end
  local slope = (n * sxy - sx * sy) / den
  if slope >= -1 then return nil end
  return slope
end

function M.decay_model(entries, opts)
  local iso = (opts and opts.isolation_s) or 1.5
  local slopes, peaks = {}, {}
  for _, e in ipairs(entries) do
    for k, t in ipairs(e.onsets) do
      local pk = M.band_peak(e.env_db, e.fr, t)
      if pk > -math.huge then peaks[#peaks + 1] = pk end
      local nxt = e.onsets[k + 1]
      if not nxt or nxt - t >= iso then
        local s = M.measure_slope(e.env_db, e.fr, t, e.noise_db, iso)
        if s then slopes[#slopes + 1] = s end
      end
    end
  end
  table.sort(slopes)
  table.sort(peaks)
  local typical
  if #peaks > 0 then
    local ntop = max(1, floor(#peaks * 0.2 + 0.5))
    typical = peaks[#peaks - floor((ntop - 1) / 2)]
  end
  return {
    slope_db_s = #slopes > 0 and slopes[floor((#slopes + 1) / 2)] or nil,
    typical_peak_db = typical,
    n_isolated = #slopes,
  }
end

function M.hit_end(env_db, fr, t, o)
  local lo, hi = t + o.min_s, t + o.max_s
  local _, ip = M.band_peak(env_db, fr, t)
  local target = max(o.target_db, o.noise_db + 3)
  local last = min(#env_db, floor(hi * fr) + 1)
  local mval, mi, e = math.huge, ip, nil
  for i = ip, last do
    local y = env_db[i]
    if y <= target then
      e = (i - 1) / fr
      break
    end
    if y < mval then
      mval, mi = y, i
    elseif y > mval + 3 then
      break
    end
  end
  if not e then
    if mval == math.huge then
      e = hi
    else
      e = (mi - 1) / fr + (mval - target) / -o.slope
    end
  end
  return min(max(e, lo), hi)
end

function M.model_end(env_db, fr, t, o)
  local pk = M.band_peak(env_db, fr, t)
  local e = (pk == -math.huge) and (t + o.max_s) or (t + (pk - o.target_db) / -o.slope)
  return min(max(e, t + o.min_s), t + o.max_s)
end

function M.build(onsets, ends, item_len, o)
  local regs, cur = {}, nil
  for i, t in ipairs(onsets) do
    if cur and t <= cur.e then
      if ends[i] > cur.e then cur.e = ends[i] end
      cur.last, cur.hits = t, cur.hits + 1
    else
      if cur then regs[#regs + 1] = cur end
      cur = { s = t - o.preroll_s, e = ends[i], first = t, last = t, hits = 1 }
    end
  end
  if cur then regs[#regs + 1] = cur end
  local merged = {}
  for _, r in ipairs(regs) do
    local p = merged[#merged]
    if p and r.s - p.e < o.merge_gap_s then
      if r.e > p.e then p.e = r.e end
      p.last, p.hits = r.last, p.hits + r.hits
    else
      merged[#merged + 1] = r
    end
  end
  local out = {}
  for _, r in ipairs(merged) do
    r.s, r.e = max(0, r.s), min(item_len, r.e)
    if r.e > r.s then
      local len, tail = r.e - r.s, max(0, r.e - r.last)
      local fo = o.fade_out_s
      if o.auto then fo = min(max(0.3 * tail, o.fade_out_s), 0.5) end
      r.fade_in = min(o.fade_in_s, len / 2)
      r.fade_out = min(fo, tail, len / 2)
      out[#out + 1] = r
    end
  end
  return out
end

return M
