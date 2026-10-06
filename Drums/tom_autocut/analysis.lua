-- @noindex
-- Heavy analysis: pass A (onsets + features) and pass B (band envelope). Pure Lua:
-- audio comes from item.reader(t0, n).
local envelope = require("tom_autocut.envelope")
local features = require("tom_autocut.features")
local bandtrack = require("tom_autocut.bandtrack")
local M = {}
M.BLOCK = 65536
local floor, max, min = math.floor, math.max, math.min
local function noop() end

local function stream(it, sink, progress)
  local total = floor(it.len * it.sr)
  local done = 0
  while done < total do
    local n = min(M.BLOCK, total - done)
    sink:push(it.reader(done / it.sr, n), n)
    done = done + n
    progress(done / total)
  end
end

function M.pass_a(it, settings, progress)
  progress = progress or noop
  local framer = envelope.new_framer(it.sr, 0.001)
  stream(it, framer, progress)
  local fast, slow = envelope.envelopes(framer:finish(), framer.frame_rate)
  local cands = envelope.pick_candidates(envelope.onset_function(fast, slow), fast, framer.frame_rate)
  local top = -math.huge
  for _, c in ipairs(cands) do top = max(top, c.peak_db) end
  local n_fft = features.fft_size(it.sr, settings.fft_base)
  local out = {}
  for k, c in ipairs(cands) do
    if c.peak_db >= top - 45 then
      local w0 = max(0, c.time - 0.004)
      c.time = envelope.refine_onset(it.reader(w0, floor(0.010 * it.sr)), it.sr, w0)
      c.feat = features.extract(it.reader(c.time, n_fft), it.sr, n_fft)
      c.ptime = it.pos + c.time
      out[#out + 1] = c
    end
    if k % 64 == 0 then progress(1) end
  end
  return out
end

function M.pass_b(it, lo, hi, progress)
  local tk = bandtrack.new(it.sr, lo, hi, 0.010)
  stream(it, tk, progress or noop)
  return tk:finish()
end

local function close(it) if it.close then it.close() end end

function M.run(tracks, settings, yield)
  yield = yield or noop
  local total, done = 0, 0
  for _, tr in ipairs(tracks) do
    for _, it in ipairs(tr.items) do total = total + it.len * (tr.role == "tom" and 2 or 1) end
  end
  total = max(total, 1e-9)
  for _, tr in ipairs(tracks) do
    local all = {}
    for _, it in ipairs(tr.items) do
      it.cands = M.pass_a(it, settings, function(f) yield(min(1, (done + f * it.len) / total), tr.name) end)
      done = done + it.len
      close(it)
      for _, c in ipairs(it.cands) do all[#all + 1] = c end
    end
    if tr.role == "tom" then
      local model = features.learn_track(all, { band = tr.band_override })
      for _, it in ipairs(tr.items) do
        it.band = M.pass_b(it, model.band_lo, model.band_hi,
          function(f) yield(min(1, (done + f * it.len) / total), tr.name) end)
        done = done + it.len
        close(it)
      end
    end
  end
  yield(1, "")
  return { tracks = tracks }
end

function M.rerun_band(tr, yield)
  yield = yield or noop
  local total, done = 0, 0
  for _, it in ipairs(tr.items) do total = total + it.len end
  total = max(total, 1e-9)
  for _, it in ipairs(tr.items) do
    it.band = M.pass_b(it, tr.model.band_lo, tr.model.band_hi,
      function(f) yield(min(1, (done + f * it.len) / total), tr.name) end)
    done = done + it.len
    close(it)
  end
end

return M
