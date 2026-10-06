-- Offline run of the GD Tom auto-cut analysis on WAV files (dev only).
-- Usage: [START=s] [DUR=s] [LIST=from-to] lua5.4 tools/wav_analyse.lua [ref:]<name>=<file.wav> ...
package.path = "./Drums/?.lua;" .. package.path
local analysis = require("tom_autocut.analysis")
local pipeline = require("tom_autocut.pipeline")
local settings = require("tom_autocut.settings")

-- Minimal RIFF/WAVE reader: PCM 16/24/32-bit and IEEE float 32/64, any channel count.
-- Reads only the window [start_s, start_s + dur_s] so long session files stay small in memory.
local function read_wav(path, start_s, dur_s)
  local f = assert(io.open(path, "rb"))
  assert(f:read(4) == "RIFF")
  f:read(4)
  assert(f:read(4) == "WAVE", "not a WAVE file: " .. path)
  local fmt, data_pos, data_size
  while true do
    local hdr = f:read(8)
    if not hdr or #hdr < 8 then break end
    local id, size = hdr:sub(1, 4), string.unpack("<I4", hdr, 5)
    if id == "fmt " then
      local b = f:read(size + (size % 2))
      local tag, nch, sr, _, _, bits = string.unpack("<I2I2I4I4I2I2", b)
      if tag == 0xFFFE then tag = string.unpack("<I2", b, 25) end
      fmt = { tag = tag, nch = nch, sr = sr, bits = bits }
    elseif id == "data" then
      data_pos, data_size = f:seek(), size
      break
    else
      f:seek("cur", size + (size % 2))
    end
  end
  assert(fmt and data_pos, "missing fmt or data chunk: " .. path)
  local bps = fmt.bits // 8
  local fbytes = bps * fmt.nch
  local total = data_size // fbytes
  local first = math.min(total, math.floor((start_s or 0) * fmt.sr))
  local frames = math.min(total - first, dur_s and math.floor(dur_s * fmt.sr) or total)
  f:seek("set", data_pos + first * fbytes)
  local unpack_fmt, scale
  if fmt.tag == 3 then
    unpack_fmt, scale = (bps == 4) and "<f" or "<d", 1
  elseif bps == 2 then
    unpack_fmt, scale = "<i2", 1 / 32768
  elseif bps == 3 then
    unpack_fmt, scale = "<i3", 1 / 8388608
  elseif bps == 4 then
    unpack_fmt, scale = "<i4", 1 / 2147483648
  else
    error("unsupported sample format in " .. path)
  end
  local mono, inv, done = {}, 1 / fmt.nch, 0
  while done < frames do
    local chunk = math.min(65536, frames - done)
    local data = f:read(chunk * fbytes)
    local p = 1
    for i = 1, chunk do
      local s = 0
      for _ = 1, fmt.nch do
        s = s + string.unpack(unpack_fmt, data, p)
        p = p + bps
      end
      mono[done + i] = s * inv * scale
    end
    done = done + chunk
  end
  f:close()
  return mono, fmt.sr, fmt.nch, fmt.bits, fmt.tag, total / fmt.sr
end

local START, DUR = tonumber(os.getenv("START") or "0"), tonumber(os.getenv("DUR") or "")
local tracks = {}
for _, a in ipairs(arg) do
  local name, path = a:match("^([^=]+)=(.+)$")
  assert(name, "argument must be [ref:]name=path: " .. a)
  local role = "tom"
  if name:sub(1, 4) == "ref:" then role, name = "ref", name:sub(5) end
  local t0 = os.clock()
  local buf, sr, nch, bits, tag, file_s = read_wav(path, START, DUR)
  local peak = 0
  for i = 1, #buf do
    local v = math.abs(buf[i])
    if v > peak then peak = v end
  end
  print(("%s: %s  sr=%d nch=%d bits=%d tag=%d  file=%.1f s  window=%.1f+%.1f s  peak=%.1f dBFS  (read %.1f s)"):format(
    name, path, sr, nch, bits, tag, file_s, START, #buf / sr, 20 * math.log(math.max(peak, 1e-10), 10), os.clock() - t0))
  local reader = function(t, n)
    local out, i0 = {}, math.floor(t * sr + 0.5)
    for i = 1, n do out[i] = buf[i0 + i] or 0 end
    return out
  end
  tracks[#tracks + 1] = { key = name, name = name, role = role,
    items = { { key = name, pos = 0, len = #buf / sr, sr = sr, startoffs = 0, playrate = 1, reader = reader } } }
end

local t0 = os.clock()
local state = analysis.run(tracks, settings.DEFAULTS)
pipeline.recompute(state, settings.DEFAULTS)
print(("analysis: %.1f s"):format(os.clock() - t0))
for _, tr in ipairs(state.tracks) do
  local m, s = tr.model, tr.stats
  print(("\n== %s: %d cands | model ok=%s usable=%s f0=%.0f band=%.0f-%.0f strong=%d | hits=%d bleeds=%d rejected=%d regions=%d kept=%.0f%% decay=%.2fs"):format(
    tr.name, #tr.cands, tostring(m.ok), tostring(m.usable), m.f0, m.band_lo, m.band_hi, m.n_strong,
    s.hits, s.bleeds, s.rejected, s.regions, s.total > 0 and 100 * s.kept / s.total or 0, tr.decay_s or 0))
  local lf, lt = (os.getenv("LIST") or ""):match("([%d%.]+)%-([%d%.]+)")
  lf, lt = tonumber(lf), tonumber(lt)
  local shown = 0
  for k, c in ipairs(tr.cands) do
    if lf and (c.time < lf or c.time > lt) then goto continue end
    shown = shown + 1
    if shown > 25 then print("  ...") break end
    print(("  t=%7.3f peak=%6.1f odf=%5.1f f0=%4.0f lo/hi=%6.1f score=%.2f %s%s"):format(c.time, c.peak_db, c.odf_db,
      c.feat.f0, 10 * math.log(math.max(c.feat.e_low, 1e-30) / math.max(c.feat.e_high, 1e-30), 10), c.score or -1,
      c.status or "?", c.bleed_from and (" <- " .. c.bleed_from) or ""))
    ::continue::
  end
end
