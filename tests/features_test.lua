local H = require("helpers")
local S = require("synth")
local features = require("tom_autocut.features")
local SR = 48000
local T = {}

local function tom_buf(sr, f0, amp)
  local b = S.silence(sr, 0.2)
  S.add_tom(b, sr, 0, { f0 = f0, amp = amp or 0.8, decay = 0.6 })
  return b
end

local function noise_buf(sr)
  local b = S.silence(sr, 0.2)
  S.add_noise_burst(b, sr, 0, { amp = 0.5 })
  return b
end

local function cand(buf, sr, peak_db, sharp)
  return { feat = features.extract(buf, sr, features.fft_size(sr, 2048)), peak_db = peak_db, sharpness = sharp or 10 }
end

local function ratio_db(f) return 10 * math.log(f.e_low / f.e_high, 10) end

T["fft_size scales with the sample rate"] = function()
  H.eq(features.fft_size(44100, 2048), 2048)
  H.eq(features.fft_size(48000, 2048), 2048)
  H.eq(features.fft_size(96000, 2048), 4096)
end

T["tom: f0 found and low band dominates"] = function()
  local f = features.extract(tom_buf(SR, 90), SR, 2048)
  H.near(f.f0, 95, 12, "f0")
  H.truthy(ratio_db(f) > 20, "ratio " .. ratio_db(f))
end

T["noise burst: high band dominates"] = function()
  H.truthy(ratio_db(features.extract(noise_buf(SR), SR, 2048)) < 0)
end

T["96 kHz: same f0 with a scaled FFT"] = function()
  local f = features.extract(tom_buf(96000, 90), 96000, features.fft_size(96000, 2048))
  H.near(f.f0, 95, 12)
end

T["band_energy sums the kept bins in range"] = function()
  local feat = { low = { 1, 1, 1, 1, 1, 1 }, bin_hz = 10 }
  H.eq(features.band_energy(feat, 20, 40), 3)
end

T["learn_track: band from the strongest low-dominant hits"] = function()
  local cs = {}
  for i = 1, 6 do cs[#cs + 1] = cand(tom_buf(SR, 90, 0.8), SR, -2 - i * 0.5) end
  for i = 1, 4 do cs[#cs + 1] = cand(tom_buf(SR, 150, 0.1), SR, -20) end
  cs[#cs + 1] = cand(noise_buf(SR), SR, 0)
  local m = features.learn_track(cs)
  H.truthy(m.ok, "ok")
  H.near(m.f0, 95, 12, "f0")
  H.near(m.band_lo, 0.75 * m.f0, 1e-9)
  H.near(m.band_hi, 2 * m.f0, 1e-9)
end

T["learn_track: two strong hits are enough"] = function()
  local cs = { cand(tom_buf(SR, 90), SR, -3), cand(tom_buf(SR, 90), SR, -4) }
  H.truthy(features.learn_track(cs).ok)
end

T["learn_track: no hit gives the default band"] = function()
  local m = features.learn_track({})
  H.truthy(not m.ok)
  H.eq(m.band_lo, 60); H.eq(m.band_hi, 300)
end

T["learn_track: manual band wins"] = function()
  local cs = { cand(tom_buf(SR, 90), SR, -3), cand(tom_buf(SR, 90), SR, -4) }
  local m = features.learn_track(cs, { band = { 70, 180 } })
  H.eq(m.band_lo, 70); H.eq(m.band_hi, 180); H.truthy(m.manual)
end

T["learn_track: usable when strong hits exist"] = function()
  local cs = { cand(tom_buf(SR, 90), SR, -3), cand(tom_buf(SR, 90), SR, -4) }
  H.eq(features.learn_track(cs).usable, true)
end

T["learn_track: empty strong pool is unusable, medians over all candidates"] = function()
  local cs = { cand(noise_buf(SR), SR, -3, 4), cand(noise_buf(SR), SR, -5, 6), cand(noise_buf(SR), SR, -7, 8) }
  local m = features.learn_track(cs)
  H.eq(m.n_strong, 0)
  H.eq(m.usable, false)
  H.eq(m.typical_peak_db, -5, "peak")
  H.eq(m.typical_sharp, 6, "sharp")
  local e = features.band_energy(cs[1].feat, m.band_lo, m.band_hi)
  H.near(m.typical_e, e, e * 1e-9, "energy")
  H.near(m.typical_ratio_db, ratio_db(cs[1].feat), 1e-9, "ratio")
end

T["score: real hit high, snare-like bleed low, below floor zero"] = function()
  local cs = {}
  for i = 1, 5 do cs[#cs + 1] = cand(tom_buf(SR, 90), SR, -3) end
  local m = features.learn_track(cs)
  local function scored(c)
    c.band_e = features.band_energy(c.feat, m.band_lo, m.band_hi)
    return features.score(c, m, -30)
  end
  H.truthy(scored(cand(tom_buf(SR, 90), SR, -3)) > 0.7, "hit")
  H.truthy(scored(cand(noise_buf(SR), SR, -10)) < 0.4, "noise")
  H.eq(scored(cand(tom_buf(SR, 90), SR, -40)), 0, "floor")
end

return T
