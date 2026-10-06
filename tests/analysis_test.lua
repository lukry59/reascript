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

T["pass_a reports progress often during the feature loop"] = function()
  local it = scenario()[2].items[1]
  local ones = 0
  local out = analysis.pass_a(it, settings.DEFAULTS, function(f) if f == 1 then ones = ones + 1 end end)
  H.truthy(#out >= 8, "candidates " .. #out)
  -- end of streaming + after pick_candidates + every 8 candidates
  H.truthy(ones >= 2 + math.floor(#out / 8), ("progress(1) calls %d for %d candidates"):format(ones, #out))
end

T["tom track split into two items: regions per item, hits in both"] = function()
  local full = S.silence(SR, 5.0)
  S.add_noise(full, 2e-4, 5)
  for _, t in ipairs({ 0.5, 1.5, 3.0, 4.0 }) do S.add_tom(full, SR, t, { f0 = 120, amp = 0.7, decay = 0.5 }) end
  local half = math.floor(2.5 * SR)
  local a, b = {}, {}
  for i = 1, half do a[i] = full[i] end
  for i = half + 1, #full do b[i - half] = full[i] end
  local ia, ib = item(a, 0), item(b, 2.5)
  ia.key, ib.key = "a", "b"
  local state = analysis.run({ { key = "tom", name = "Tom 1", role = "tom", items = { ia, ib } } }, settings.DEFAULTS)
  pipeline.recompute(state, settings.DEFAULTS)
  for _, it in ipairs({ ia, ib }) do
    H.eq(#it.hits, 2, "hits in item " .. it.key)
    H.eq(#it.regions, 2, "regions in item " .. it.key)
    H.near(it.regions[1].s, 0.495, 0.002, "first region " .. it.key)
    H.near(it.regions[2].s, 1.495, 0.002, "second region " .. it.key)
    for _, r in ipairs(it.regions) do H.truthy(r.e <= it.len + 1e-9, "region inside item " .. it.key) end
  end
  H.near(ib.cands[1].ptime, 3.0, 0.002, "second item project time")
  H.eq(state.tracks[1].stats.regions, 4)
end

T["kick reference: its bleed on the tom is attributed, tom hits kept"] = function()
  local dur = 4.0
  local tm, kk = S.silence(SR, dur), S.silence(SR, dur)
  S.add_noise(tm, 2e-4, 6); S.add_noise(kk, 2e-4, 7)
  for _, t in ipairs({ 0.8, 2.2 }) do
    S.add_tom(kk, SR, t, { f0 = 60, amp = 0.9, decay = 0.4 })
    S.add_tom(tm, SR, t + 0.002, { f0 = 60, amp = 0.1, decay = 0.4 })
  end
  for _, t in ipairs({ 0.4, 1.5, 3.0 }) do S.add_tom(tm, SR, t, { f0 = 130, amp = 0.7, decay = 0.5 }) end
  local tracks = {
    { key = "kick", name = "Kick", role = "ref", items = { item(kk) } },
    { key = "tom", name = "Tom 1", role = "tom", items = { item(tm) } },
  }
  local state = analysis.run(tracks, settings.DEFAULTS)
  pipeline.recompute(state, settings.DEFAULTS)
  local ref = state.tracks[1]
  H.truthy(#ref.cands >= 2, "kick events")
  for _, c in ipairs(ref.cands) do H.eq(c.status, "ref") end
  H.eq(ref.items[1].band, nil, "no band pass on a reference")
  local hits, bleeds = {}, 0
  for _, c in ipairs(state.tracks[2].cands) do
    if c.status == "hit" then hits[#hits + 1] = c.time end
    if c.status == "bleed" then
      bleeds = bleeds + 1
      H.eq(c.bleed_from, "Kick")
    end
  end
  H.eq(bleeds, 2, "kick bleeds")
  H.eq(#hits, 3, "tom hits")
  H.near(hits[1], 0.4, 0.002); H.near(hits[2], 1.5, 0.002); H.near(hits[3], 3.0, 0.002)
  H.eq(#state.tracks[2].items[1].regions, 3)
end

T["rerun_band after a band override clears needs_band_pass"] = function()
  local state = analysis.run(scenario(), settings.DEFAULTS)
  pipeline.recompute(state, settings.DEFAULTS)
  local tr = state.tracks[1]
  H.eq(tr.needs_band_pass, false, "fresh analysis")
  tr.band_override = { 100, 250 }
  pipeline.recompute(state, settings.DEFAULTS)
  H.eq(tr.needs_band_pass, true, "after override")
  analysis.rerun_band(tr)
  pipeline.recompute(state, settings.DEFAULTS)
  H.eq(tr.needs_band_pass, false, "after re-pass")
  H.eq(tr.items[1].band.lo, 100); H.eq(tr.items[1].band.hi, 250)
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
