-- @noindex
-- Spectral features, per-track model and single-track score (pure Lua).
local fft = require("tom_autocut.fft")
local M = {}
local log, max, min, floor, ceil, abs = math.log, math.max, math.min, math.floor, math.ceil, math.abs

M.DEFAULT_BAND = { 60, 300 }
M.KEEP_HZ = 1000

local function db10(x) return 10 * log(max(x, 1e-30), 10) end
local function clamp01(x) return x < 0 and 0 or (x > 1 and 1 or x) end

local function median(t)
  if #t == 0 then return nil end
  local s = {}
  for i, v in ipairs(t) do s[i] = v end
  table.sort(s)
  return s[floor((#s + 1) / 2)]
end
M.median = median

function M.fft_size(sr, base) return fft.next_pow2((base or 2048) * sr / 48000) end

function M.extract(samples, sr, n_fft)
  local p = fft.power_spectrum(samples, 1, n_fft)
  local bin_hz = sr / n_fft
  local last = #p - 1
  local function band(lo, hi)
    local s = 0
    for k = max(1, floor(lo / bin_hz)), min(last, ceil(hi / bin_hz)) do s = s + p[k + 1] end
    return s
  end
  local kb, best = nil, -1
  for k = max(1, ceil(50 / bin_hz)), min(last - 1, floor(400 / bin_hz)) do
    if p[k + 1] > best then best, kb = p[k + 1], k end
  end
  local f0 = (kb or 1) * bin_hz
  if kb then
    local a, b, c = log(p[kb] + 1e-30), log(p[kb + 1] + 1e-30), log(p[kb + 2] + 1e-30)
    local d = a - 2 * b + c
    if d < 0 then f0 = (kb + 0.5 * (a - c) / d) * bin_hz end
  end
  local low = {}
  for k = 0, min(last, floor(M.KEEP_HZ / bin_hz)) do low[k + 1] = p[k + 1] end
  return { f0 = f0, e_low = band(40, 400), e_high = band(2000, 10000), low = low, bin_hz = bin_hz }
end

function M.band_energy(feat, lo, hi)
  local s = 0
  for k = max(0, ceil(lo / feat.bin_hz)), min(#feat.low - 1, floor(hi / feat.bin_hz)) do
    s = s + feat.low[k + 1]
  end
  return s
end

function M.learn_track(cands, opts)
  opts = opts or {}
  local pool = {}
  for _, c in ipairs(cands) do
    if c.feat.e_low > c.feat.e_high then pool[#pool + 1] = c end
  end
  table.sort(pool, function(a, b) return a.peak_db > b.peak_db end)
  local strong = {}
  local cap = max(5, ceil(#pool * 0.2))
  for _, c in ipairs(pool) do
    if c.peak_db >= pool[1].peak_db - 6 and #strong < cap then strong[#strong + 1] = c end
  end
  local m = { ok = #strong >= 2, n_strong = #strong, usable = #strong > 0 }
  local f0s = {}
  for i, c in ipairs(strong) do f0s[i] = c.feat.f0 end
  if opts.band then
    m.manual = true
    m.band_lo, m.band_hi = opts.band[1], opts.band[2]
    m.f0 = m.band_lo / 0.75
  elseif m.ok then
    m.f0 = median(f0s)
    m.band_lo, m.band_hi = 0.75 * m.f0, 2 * m.f0
  else
    m.band_lo, m.band_hi = M.DEFAULT_BAND[1], M.DEFAULT_BAND[2]
    m.f0 = m.band_lo / 0.75
  end
  -- No strong low-dominant hit (e.g. cymbal-only reference): typicals from all candidates.
  local basis = m.usable and strong or cands
  local es, peaks, ratios, sharps = {}, {}, {}, {}
  for i, c in ipairs(basis) do
    es[i] = M.band_energy(c.feat, m.band_lo, m.band_hi)
    peaks[i] = c.peak_db
    ratios[i] = db10(c.feat.e_low / max(c.feat.e_high, 1e-30))
    sharps[i] = c.sharpness
  end
  m.typical_e = median(es) or 1e-12
  m.typical_peak_db = median(peaks) or 0
  m.typical_ratio_db = median(ratios) or 20
  m.typical_sharp = median(sharps) or 1
  return m
end

function M.score(c, model, floor_db)
  if c.peak_db < model.typical_peak_db + floor_db then return 0 end
  local s_e = clamp01((db10(c.band_e / max(model.typical_e, 1e-30)) + 20) / 20)
  local r_db = db10(c.feat.e_low / max(c.feat.e_high, 1e-30))
  local s_r = clamp01(1 + (r_db - model.typical_ratio_db) / 20)
  local s_s = clamp01(c.sharpness / max(model.typical_sharp, 1e-9))
  local s_f = clamp01(1 - abs(log(max(c.feat.f0, 1) / model.f0, 2)) / 0.5)
  return 0.45 * s_e + 0.25 * s_r + 0.15 * s_s + 0.15 * s_f
end

return M
