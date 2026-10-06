local H = require("helpers")
local S = require("synth")
local analysis = require("tom_autocut.analysis")
local pipeline = require("tom_autocut.pipeline")
local settings = require("tom_autocut.settings")
local SR = 44100
local T = {}

local function reader_for(buf)
  return function(t0, n)
    local out, i0 = {}, math.floor(t0 * SR + 0.5)
    for i = 1, n do out[i] = buf[i0 + i] or 0 end
    return out
  end
end

local function item(buf, pos)
  return { key = "it", pos = pos or 0, len = #buf / SR, sr = SR, startoffs = 0, playrate = 1, reader = reader_for(buf) }
end

-- Floor (80 Hz) and Tom 1 (140 Hz) bleeding into each other 2 ms late, 14 dB down;
-- Tom 1 plays a single hit then a 16th roll; a snare-like burst on the tom mic.
local function scenario(pos)
  local dur = 5.0
  local fl, tm = S.silence(SR, dur), S.silence(SR, dur)
  S.add_noise(fl, 2e-4, 1); S.add_noise(tm, 2e-4, 2)
  for _, t in ipairs({ 0.5, 2.0 }) do
    S.add_tom(fl, SR, t, { f0 = 80, amp = 0.8, decay = 1.0 })
    S.add_tom(tm, SR, t + 0.002, { f0 = 80, amp = 0.16, decay = 1.0 })
  end
  local hits = { 1.2 }
  for k = 0, 7 do hits[#hits + 1] = 3.0 + k * 0.0833 end
  for _, t in ipairs(hits) do
    S.add_tom(tm, SR, t, { f0 = 140, amp = 0.7, decay = 0.5 })
    S.add_tom(fl, SR, t + 0.002, { f0 = 140, amp = 0.14, decay = 0.5 })
  end
  S.add_noise_burst(tm, SR, 4.3, { amp = 0.3 })
  return {
    { key = "floor", name = "Floor", role = "tom", items = { item(fl, pos) } },
    { key = "tom", name = "Tom 1", role = "tom", items = { item(tm, pos) } },
  }
end

local function analyse(s, pos)
  local state = analysis.run(scenario(pos), s)
  pipeline.recompute(state, s)
  return state
end

T["full analysis: regions on the right tracks"] = function()
  local state = analyse(settings.DEFAULTS)
  local fl = state.tracks[1].items[1].regions
  local tm = state.tracks[2].items[1].regions
  H.eq(#fl, 2, "floor regions")
  H.eq(#tm, 2, "tom regions")
  H.near(fl[1].s, 0.495, 0.002)
  H.near(fl[2].s, 1.995, 0.002)
  H.near(tm[1].s, 1.195, 0.002)
  H.near(tm[2].s, 2.995, 0.002)
  H.truthy(tm[2].hits >= 6, "roll hits " .. tm[2].hits)
  H.truthy(tm[2].e > 3.0 + 7 * 0.0833, "roll end")
  H.truthy(state.tracks[2].stats.bleeds >= 2, "tom bleeds")
  H.truthy(state.tracks[1].stats.bleeds >= 1, "floor bleeds")
  H.eq(state.by_key["tom"], state.tracks[2])
end

T["loud floor hit region outlasts its decay target"] = function()
  local state = analyse(settings.DEFAULTS)
  local r = state.tracks[1].items[1].regions[1]
  -- 1.0 s to -60 dB => -60 dB/s; -40 dB below typical => ~0.67 s
  H.near(r.e - 0.5, 0.67, 0.12)
end

T["item position only shifts project times"] = function()
  local state = analyse(settings.DEFAULTS, 10.0)
  H.near(state.tracks[1].items[1].regions[1].s, 0.495, 0.002)
  H.near(state.tracks[1].cands[1].ptime - state.tracks[1].cands[1].time, 10.0, 1e-9)
end

T["fixed length mode"] = function()
  local s = settings.merge(settings.DEFAULTS, { length_mode = "fixed", fixed_ms = 200 })
  local r = analyse(s).tracks[1].items[1].regions[1]
  H.near(r.e - 0.5, 0.2, 0.003)
end

T["manual decay overrides the measured one"] = function()
  local state = analysis.run(scenario(), settings.DEFAULTS)
  state.tracks[1].decay_override_s = 0.2
  pipeline.recompute(state, settings.DEFAULTS)
  local r = state.tracks[1].items[1].regions[1]
  H.near(r.e - 0.5, 0.2, 0.05)
  H.near(state.tracks[1].decay_s, 0.2, 1e-9)
end

T["silent track: no candidates, default band, no region"] = function()
  local tracks = { { key = "s", name = "Silent", role = "tom", items = { item(S.silence(SR, 2.0)) } } }
  local state = analysis.run(tracks, settings.DEFAULTS)
  pipeline.recompute(state, settings.DEFAULTS)
  local tr = state.tracks[1]
  H.eq(#tr.cands, 0)
  H.truthy(not tr.model.ok)
  H.eq(#tr.items[1].regions, 0)
end

T["cymbal-like reference aligned with tom hits keeps the tom hits"] = function()
  local dur = 3.0
  local tm, cy = S.silence(SR, dur), S.silence(SR, dur)
  S.add_noise(tm, 2e-4, 3); S.add_noise(cy, 2e-4, 4)
  for k, t in ipairs({ 0.5, 1.3, 2.1 }) do
    S.add_tom(tm, SR, t, { f0 = 110, amp = 0.7, decay = 0.5 })
    S.add_noise_burst(cy, SR, t + 0.001, { amp = 0.6, seed = k })
  end
  local tracks = {
    { key = "cy", name = "Cymbal", role = "ref", items = { item(cy) } },
    { key = "tom", name = "Tom 1", role = "tom", items = { item(tm) } },
  }
  local state = analysis.run(tracks, settings.DEFAULTS)
  pipeline.recompute(state, settings.DEFAULTS)
  H.eq(state.tracks[1].model.usable, false, "ref usable")
  local hits = 0
  for _, c in ipairs(state.tracks[2].cands) do
    H.truthy(c.status ~= "bleed", "tom candidate at " .. c.time .. " marked bleed")
    if c.status == "hit" then hits = hits + 1 end
  end
  H.eq(hits, 3, "tom hits")
end

T["yield reports monotonic progress up to 1"] = function()
  local last = 0
  analysis.run(scenario(), settings.DEFAULTS, function(f)
    H.truthy(f >= last - 1e-9 and f <= 1 + 1e-9, "progress " .. f)
    last = f
  end)
  H.near(last, 1, 1e-6)
end

return T
