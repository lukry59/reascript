-- GD Tom auto-cut: diagnostic (dev only, not in the ReaPack index).
-- Select the tom tracks in REAPER, then run this file via Actions > Load ReaScript.
-- It prints, per item, what the analysis reads and finds to the ReaScript console.
local script_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])")
package.path = script_dir .. "../Drums/?.lua;" .. package.path

local audio = require("tom_autocut.audio")
local analysis = require("tom_autocut.analysis")
local features = require("tom_autocut.features")
local settings = require("tom_autocut.settings")

local function log(fmt, ...) reaper.ShowConsoleMsg((fmt):format(...) .. "\n") end

local function peak_of(t)
  local p = 0
  for i = 1, #t do
    local a = math.abs(t[i])
    if a > p then p = a end
  end
  return p
end

local function db(x) return 20 * math.log(math.max(x, 1e-10), 10) end

reaper.ClearConsole()
local ntr = reaper.CountSelectedTracks(0)
log("GD Tom auto-cut diag: %d selected track(s)", ntr)
for ti = 0, ntr - 1 do
  local tr = reaper.GetSelectedTrack(0, ti)
  local _, name = reaper.GetTrackName(tr)
  local nitems = reaper.CountTrackMediaItems(tr)
  log("\n== Track '%s': %d item(s)", name, nitems)
  for ii = 0, nitems - 1 do
    local item = reaper.GetTrackMediaItem(tr, ii)
    local info, why = audio.item_info(item)
    if not info then
      log("  item %d: skipped (%s)", ii, tostring(why))
    else
      log("  item %d: pos=%.3f len=%.3f sr=%s nch=%s offs=%.3f rate=%.3f",
        ii, info.pos, info.len, tostring(info.sr), tostring(info.nch), info.startoffs, info.playrate)
      local acc = reaper.CreateTakeAudioAccessor(info.take)
      local a0, a1 = reaper.GetAudioAccessorStartTime(acc), reaper.GetAudioAccessorEndTime(acc)
      log("    accessor start=%.3f end=%.3f", a0, a1)
      -- Raw reads at both candidate time bases, 10 s starting 50 s in (or at 0 for short items)
      local skip = (info.len > 70) and 50 or 0
      local n = math.floor(math.min(info.len - skip, 10) * info.sr)
      for _, base in ipairs({ skip, a0 + skip }) do
        local buf = reaper.new_array(n * info.nch)
        buf.clear()
        local rv = reaper.GetAudioAccessorSamples(acc, info.sr, info.nch, base, n, buf)
        log("    raw read at t=%.3f: retval=%s peak=%.1f dBFS", base, tostring(rv), db(peak_of(buf.table())))
      end
      reaper.DestroyAudioAccessor(acc)
      -- Our reader (what the analysis actually sees), first 10 s
      local first = info.reader(skip, n)
      log("    reader(%.0f s, %d): #=%d peak=%.1f dBFS", skip, n, #first, db(peak_of(first)))
      -- Pass A on the whole item
      local t0 = reaper.time_precise()
      local win = setmetatable({ len = math.min(info.len, 120) }, { __index = info })
      local cands = analysis.pass_a(win, settings.DEFAULTS)
      log("    pass A on first %.0f s: %d candidate(s) in %.1f s", win.len, #cands, reaper.time_precise() - t0)
      local low = 0
      for k, c in ipairs(cands) do
        if c.feat.e_low > c.feat.e_high then low = low + 1 end
        if k <= 8 then
          log("      t=%.3f peak=%.1f dB odf=%.1f f0=%.0f Hz low/high=%.1f dB", c.time, c.peak_db, c.odf_db,
            c.feat.f0, 10 * math.log(math.max(c.feat.e_low, 1e-30) / math.max(c.feat.e_high, 1e-30), 10))
        end
      end
      log("    low-dominant candidates: %d", low)
      local m = features.learn_track(cands)
      log("    model: ok=%s f0=%.0f band=%.0f-%.0f strong=%d", tostring(m.ok), m.f0, m.band_lo, m.band_hi, m.n_strong)
      info.close()
    end
  end
end
log("\nDone.")

-- Part 2: the exact path the window takes (saved settings + build_sources + analysis.run + recompute).
local project = require("tom_autocut.project")
local pipeline = require("tom_autocut.pipeline")
local saved = project.load_settings()
log("\n== Saved settings (ExtState): %s", reaper.GetExtState(project.SECTION, "settings"))
log("   parsed: %s", settings.serialize(saved))
local rows = {}
for ti = 0, ntr - 1 do
  local tr = reaper.GetSelectedTrack(0, ti)
  local _, name = reaper.GetTrackName(tr)
  rows[#rows + 1] = { track = tr, guid = reaper.GetTrackGUID(tr), name = name, role = "tom" }
end
local tracks = project.build_sources(rows)
local t0 = reaper.time_precise()
local state = analysis.run(tracks, saved)
pipeline.recompute(state, saved)
log("   full analysis with saved settings: %.1f s", reaper.time_precise() - t0)
for _, tr in ipairs(state.tracks) do
  local s, m = tr.stats, tr.model
  log("   %s: items=%d skipped=%d processed=%s cands=%d model ok=%s f0=%.0f band=%.0f-%.0f | hits=%d bleeds=%d rejected=%d regions=%d",
    tr.name, #tr.items, tr.skipped, tostring(tr.processed), #tr.cands, tostring(m.ok), m.f0, m.band_lo, m.band_hi,
    s.hits, s.bleeds, s.rejected, s.regions)
end
project.close_sources(tracks)
log("Done (part 2).")

-- Part 3: same analysis, but resumed from reaper.defer in 25 ms slices, exactly like the window.
local tracks3 = project.build_sources(rows)
local stats = {}
for _, tr in ipairs(tracks3) do
  for _, it in ipairs(tr.items) do
    local st = { reads = 0, peak = 0, zero_reads = 0 }
    stats[it] = st
    local read = it.reader
    it.reader = function(t0, n)
      local out = read(t0, n)
      local p = peak_of(out)
      st.reads = st.reads + 1
      if p == 0 then st.zero_reads = st.zero_reads + 1 end
      if p > st.peak then st.peak = p end
      return out
    end
  end
end
local job = coroutine.create(function() return analysis.run(tracks3, saved, coroutine.yield) end)
local t3, resumes = reaper.time_precise(), 0
local function step()
  local deadline = reaper.time_precise() + 0.025
  while reaper.time_precise() < deadline do
    resumes = resumes + 1
    local ok, a = audio.resume(job)
    if not ok then log("\n== Part 3 ERROR: %s", tostring(a)) return end
    if coroutine.status(job) == "dead" then
      pipeline.recompute(a, saved)
      log("\n== Part 3 (defer + coroutine): %.1f s, %d resumes", reaper.time_precise() - t3, resumes)
      for _, tr in ipairs(a.tracks) do
        local s = tr.stats
        log("   %s: cands=%d model ok=%s | hits=%d bleeds=%d rejected=%d regions=%d",
          tr.name, #tr.cands, tostring(tr.model.ok), s.hits, s.bleeds, s.rejected, s.regions)
        for k, it in ipairs(tr.items) do
          local st = stats[it]
          log("     item %d: reads=%d zero-reads=%d peak=%.1f dBFS cands=%d stale=%s",
            k, st.reads, st.zero_reads, db(st.peak), #(it.cands or {}), tostring(it.stale))
        end
      end
      project.close_sources(tracks3)
      log("Done (part 3).")
      return
    end
  end
  reaper.defer(step)
end
reaper.defer(step)
