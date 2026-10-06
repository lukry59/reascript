local H = require("helpers")
local attribution = require("tom_autocut.attribution")
local T = {}

local OPTS = { threshold = 0.5, window_s = 0.003, margin_db = 6,
               weights = { energy = 0.6, arrival = 0.25, sharp = 0.15 } }

local function track(name, role, cands)
  return { name = name, role = role, model = { typical_e = 1, typical_sharp = 10 }, cands = cands }
end

local function cand(ptime, band_e, sharp, score)
  return { ptime = ptime, band_e = band_e, sharpness = sharp or 10, score = score or 0.9 }
end

T["bleed 2 ms late and 12 dB down goes to the source"] = function()
  local a, b = cand(1.0, 1), cand(1.002, 10 ^ -1.2, 5, 0.8)
  attribution.attribute({ track("Floor", "tom", { a }), track("Tom 1", "tom", { b }) }, OPTS)
  H.eq(a.status, "hit")
  H.eq(b.status, "bleed")
  H.eq(b.bleed_from, "Floor")
end

T["simultaneous flam keeps both hits"] = function()
  local a, b = cand(1.0, 1), cand(1.0005, 0.8)
  attribution.attribute({ track("Floor", "tom", { a }), track("Tom 1", "tom", { b }) }, OPTS)
  H.eq(a.status, "hit")
  H.eq(b.status, "hit")
end

T["dominant reference marks the tom as bleed"] = function()
  local s, t = cand(2.0, 1), cand(2.001, 0.05)
  attribution.attribute({ track("Snare", "ref", { s }), track("Tom 1", "tom", { t }) }, OPTS)
  H.eq(s.status, "ref")
  H.eq(t.status, "bleed")
  H.eq(t.bleed_from, "Snare")
end

T["isolated candidate is judged on its score"] = function()
  local lo, hi = cand(1.0, 1, 10, 0.3), cand(2.0, 1, 10, 0.7)
  attribution.attribute({ track("Tom 1", "tom", { lo, hi }) }, OPTS)
  H.eq(lo.status, "rejected")
  H.eq(hi.status, "hit")
end

T["clusters do not chain beyond the window"] = function()
  local a, b, c = cand(0, 1), cand(0.0025, 0.01), cand(0.0050, 1)
  attribution.attribute({ track("A", "tom", { a }), track("B", "tom", { b }), track("C", "tom", { c }) }, OPTS)
  H.eq(b.status, "bleed")
  H.eq(c.status, "hit")
end

T["unusable reference never marks a tom as bleed"] = function()
  local s, t = cand(2.0, 1), cand(2.001, 0.05)
  local ref = track("Cymbal", "ref", { s })
  ref.model = { typical_e = 1e-12, typical_sharp = 10, usable = false }
  attribution.attribute({ ref, track("Tom 1", "tom", { t }) }, OPTS)
  H.eq(s.status, "ref")
  H.eq(t.status, "hit")
end

T["unusable tom track is never the bleed source"] = function()
  local a, b = cand(1.0, 1), cand(1.002, 10 ^ -1.2, 5, 0.8)
  local fl = track("Floor", "tom", { a })
  fl.model = { typical_e = 1e-12, typical_sharp = 10, usable = false }
  attribution.attribute({ fl, track("Tom 1", "tom", { b }) }, OPTS)
  H.eq(b.status, "hit")
  H.eq(a.status, "hit")
end

T["zero score is rejected even with threshold 0"] = function()
  local o = {}
  for k, v in pairs(OPTS) do o[k] = v end
  o.threshold = 0
  local z, p = cand(1.0, 1, 10, 0), cand(2.0, 1, 10, 0.01)
  attribution.attribute({ track("Tom 1", "tom", { z, p }) }, o)
  H.eq(z.status, "rejected")
  H.eq(p.status, "hit")
end

T["all weights zero: energy-only dominance, no NaN"] = function()
  local o = {}
  for k, v in pairs(OPTS) do o[k] = v end
  o.weights = { energy = 0, arrival = 0, sharp = 0 }
  local a, b = cand(1.0, 1), cand(1.002, 10 ^ -1.2, 5, 0.8)
  attribution.attribute({ track("Floor", "tom", { a }), track("Tom 1", "tom", { b }) }, o)
  H.truthy(b.dominance == b.dominance, "NaN dominance")
  H.near(b.dominance, -12, 1e-9)
  H.eq(a.status, "hit")
  H.eq(b.status, "bleed")
end

return T
