local H = require("helpers")
local regions = require("tom_autocut.regions")
local FR = 100
local T = {}

-- Synthetic band envelope: each hit {t, peak_db} decays linearly at `slope` dB/s.
local function env_line(dur, hits, slope, noise)
  local e = {}
  for i = 1, math.floor(dur * FR) do
    local t, v = (i - 1) / FR, noise
    for _, h in ipairs(hits) do
      if t >= h[1] then v = math.max(v, h[2] + slope * (t - h[1])) end
    end
    e[i] = v
  end
  return e
end

local BUILD = { preroll_s = 0.005, merge_gap_s = 0.12, fade_in_s = 0.002, fade_out_s = 0.03, auto = true }

T["measure_slope recovers the decay slope"] = function()
  local e = env_line(3, { { 0.5, -6 } }, -100, -90)
  H.near(regions.measure_slope(e, FR, 0.5, -90, 1.5), -100, 2)
end

T["hit_end: a loud hit rings longer than a soft one"] = function()
  local e = env_line(3, { { 0.5, -6 }, { 1.5, -18 } }, -100, -90)
  local o = { target_db = -46, noise_db = -90, slope = -100, min_s = 0.06, max_s = 2.5 }
  H.near(regions.hit_end(e, FR, 0.5, o) - 0.5, 0.40, 0.02)
  H.near(regions.hit_end(e, FR, 1.5, o) - 1.5, 0.28, 0.02)
end

T["hit_end extrapolates when another source masks the tail"] = function()
  local e = env_line(3, { { 0.5, -6 }, { 0.8, -10 } }, -100, -90)
  local o = { target_db = -46, noise_db = -90, slope = -100, min_s = 0.06, max_s = 2.5 }
  H.near(regions.hit_end(e, FR, 0.5, o) - 0.5, 0.40, 0.03)
end

T["hit_end respects min and max"] = function()
  local e = env_line(3, { { 0.5, -6 } }, -100, -90)
  H.near(regions.hit_end(e, FR, 0.5, { target_db = -10, noise_db = -90, slope = -100, min_s = 0.06, max_s = 2.5 }), 0.56, 1e-9)
  H.near(regions.hit_end(e, FR, 0.5, { target_db = -200, noise_db = -300, slope = -100, min_s = 0.06, max_s = 0.3 }), 0.8, 1e-9)
end

T["model_end follows the given slope"] = function()
  local e = env_line(3, { { 0.5, -6 } }, -100, -90)
  H.near(regions.model_end(e, FR, 0.5, { target_db = -46, slope = -200, min_s = 0.06, max_s = 2.5 }) - 0.5, 0.20, 0.02)
end

T["decay_model uses isolated hits only"] = function()
  local hits = { { 0.5, -6 }, { 3.0, -6 }, { 5.0, -30 }, { 5.1, -30 } }
  local e = env_line(7, hits, -100, -90)
  local dm = regions.decay_model({ { onsets = { 0.5, 3.0, 5.0, 5.1 }, env_db = e, fr = FR, noise_db = -90 } })
  H.near(dm.slope_db_s, -100, 3)
  H.eq(dm.n_isolated, 3)
  H.near(dm.typical_peak_db, -6, 0.5)
end

T["build: a roll gives one region"] = function()
  local on, en = {}, {}
  for k = 0, 7 do on[#on + 1] = 0.3 + k * 0.0833; en[#en + 1] = on[#on] + 0.3 end
  local r = regions.build(on, en, 5, BUILD)
  H.eq(#r, 1)
  H.eq(r[1].hits, 8)
  H.near(r[1].s, 0.295, 1e-9)
  H.near(r[1].e, on[8] + 0.3, 1e-9)
end

T["build: merge gap joins close regions"] = function()
  local o = {}
  for k, v in pairs(BUILD) do o[k] = v end
  o.merge_gap_s = 0.25
  H.eq(#regions.build({ 0.5, 1.0 }, { 0.8, 1.3 }, 5, o), 1)
  o.merge_gap_s = 0.1
  H.eq(#regions.build({ 0.5, 1.0 }, { 0.8, 1.3 }, 5, o), 2)
end

T["build clamps regions to the item bounds"] = function()
  local r = regions.build({ 0.002, 4.9 }, { 0.3, 5.4 }, 5, BUILD)
  H.eq(r[1].s, 0)
  H.eq(r[2].e, 5)
end

T["build: fades never cover the attack"] = function()
  local r = regions.build({ 1.0 }, { 1.02 }, 5, BUILD)
  H.truthy(r[1].fade_out <= r[1].e - r[1].last + 1e-12)
  H.truthy(r[1].fade_in <= 0.002 + 1e-12)
end

T["build: no preroll means no fade-in over the attack"] = function()
  local o = {}
  for k, v in pairs(BUILD) do o[k] = v end
  o.preroll_s = 0
  local r = regions.build({ 1.0 }, { 1.3 }, 5, o)
  H.eq(r[1].fade_in, 0)
  o.preroll_s = 0.001
  H.near(regions.build({ 1.0 }, { 1.3 }, 5, o)[1].fade_in, 0.001, 1e-12)
end

return T
