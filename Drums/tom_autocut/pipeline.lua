-- @noindex
-- Light stage, recomputed on every settings change: scores -> attribution -> decay -> regions.
local features = require("tom_autocut.features")
local attribution = require("tom_autocut.attribution")
local regions = require("tom_autocut.regions")
local M = {}
local max, min = math.max, math.min

function M.options(s)
  return {
    threshold = 1 - s.sensitivity_pct / 100,
    floor_db = s.floor_db,
    window_s = s.xwindow_ms / 1000,
    margin_db = s.margin_db,
    weights = { energy = s.w_energy, arrival = s.w_arrival, sharp = s.w_sharp },
  }
end

local function build_track(tr, s, st)
  local entries, needs = {}, false
  for _, it in ipairs(tr.items) do
    it.hits = {}
    for _, c in ipairs(it.cands or {}) do
      if c.status == "hit" then
        it.hits[#it.hits + 1] = c.time
        st.hits = st.hits + 1
      elseif c.status == "bleed" then
        st.bleeds = st.bleeds + 1
      elseif c.status == "rejected" then
        st.rejected = st.rejected + 1
      end
    end
    table.sort(it.hits)
    if it.band then
      if it.band.lo ~= tr.model.band_lo or it.band.hi ~= tr.model.band_hi then needs = true end
      entries[#entries + 1] = { onsets = it.hits, env_db = it.band.env_db, fr = it.band.fr, noise_db = it.band.noise_db }
    end
  end
  tr.needs_band_pass = needs

  local dm = regions.decay_model(entries)
  local depth = s.decay_depth_db
  local override = tr.decay_override_s and tr.decay_override_s > 0
  local slope = override and (-depth / tr.decay_override_s) or (dm.slope_db_s or regions.DEFAULT_SLOPE_DB_S)
  tr.decay_s = depth / -slope
  tr.decay_measured = (not override) and dm.slope_db_s ~= nil

  local auto = s.length_mode == "auto"
  local min_s, max_s = s.min_ms / 1000, s.max_ms / 1000
  local bopts = { preroll_s = s.preroll_ms / 1000, merge_gap_s = s.merge_gap_ms / 1000,
                  fade_in_s = s.fade_in_ms / 1000, fade_out_s = s.fade_out_ms / 1000, auto = auto }
  for _, it in ipairs(tr.items) do
    local ends = {}
    for k, t in ipairs(it.hits) do
      if not auto then
        ends[k] = t + s.fixed_ms / 1000
      elseif it.band and dm.typical_peak_db then
        local o = { target_db = dm.typical_peak_db - depth, noise_db = it.band.noise_db,
                    slope = slope, min_s = min_s, max_s = max_s }
        if override then
          ends[k] = regions.model_end(it.band.env_db, it.band.fr, t, o)
        else
          ends[k] = regions.hit_end(it.band.env_db, it.band.fr, t, o)
        end
      else
        ends[k] = t + min(max(tr.decay_s, min_s), max_s)
      end
    end
    it.regions = regions.build(it.hits, ends, it.len, bopts)
    st.regions = st.regions + #it.regions
    st.total = st.total + it.len
    for _, r in ipairs(it.regions) do st.kept = st.kept + (r.e - r.s) end
  end
end

function M.recompute(state, s)
  local o = M.options(s)
  state.by_key = {}
  for _, tr in ipairs(state.tracks) do
    state.by_key[tr.key] = tr
    local all = {}
    for _, it in ipairs(tr.items) do
      for _, c in ipairs(it.cands or {}) do all[#all + 1] = c end
    end
    tr.model = features.learn_track(all, { band = tr.band_override })
    for _, c in ipairs(all) do
      c.band_e = features.band_energy(c.feat, tr.model.band_lo, tr.model.band_hi)
      c.score = features.score(c, tr.model, o.floor_db)
    end
    tr.cands = all
  end
  attribution.attribute(state.tracks, o)
  for _, tr in ipairs(state.tracks) do
    tr.stats = { hits = 0, bleeds = 0, rejected = 0, regions = 0, kept = 0, total = 0 }
    if tr.role == "tom" then build_track(tr, s, tr.stats) end
  end
end

return M
