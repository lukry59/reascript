-- GD Tom auto-cut: audio accessor probe (dev only). Select ONE audio track, run via Actions > Load ReaScript.
-- Reads 10 s at 50 s of its first item in different execution contexts and prints the peak level.
local function log(fmt, ...) reaper.ShowConsoleMsg((fmt):format(...) .. "\n") end
local function db(x) return 20 * math.log(math.max(x, 1e-10), 10) end

local track = reaper.GetSelectedTrack(0, 0)
local item = track and reaper.GetTrackMediaItem(track, 0)
local take = item and reaper.GetActiveTake(item)
if not take then
  reaper.MB("Select one track with an audio item.", "accessor probe", 0)
  return
end
local src = reaper.GetMediaItemTake_Source(take)
local sr, nch = reaper.GetMediaSourceSampleRate(src), reaper.GetMediaSourceNumChannels(src)
local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
local T0 = (len > 70) and 50 or 0
local N = math.floor(math.min(len - T0, 10) * sr)

local function read(acc, label, validate)
  if validate then reaper.AudioAccessorValidateState(acc) end
  local buf = reaper.new_array(N * nch)
  buf.clear()
  local rv = reaper.GetAudioAccessorSamples(acc, sr, nch, T0, N, buf)
  local p = 0
  for _, v in ipairs(buf.table()) do
    local a = math.abs(v)
    if a > p then p = a end
  end
  log("%-55s retval=%s peak=%.1f dBFS", label, tostring(rv), db(p))
end

reaper.ClearConsole()
log("accessor probe: sr=%d nch=%d read %.0f s at %.0f s", sr, nch, N / sr, T0)

-- A: plain, synchronous
local accA = reaper.CreateTakeAudioAccessor(take)
read(accA, "A  sync, main chunk")

-- B: inside a coroutine resumed synchronously
local accB = reaper.CreateTakeAudioAccessor(take)
local co = coroutine.create(function() read(accB, "B  sync, inside coroutine") end)
local ok, err = coroutine.resume(co)
if not ok then log("B error: %s", tostring(err)) end

local accC = reaper.CreateTakeAudioAccessor(take)
local cycle = 0
local function step()
  cycle = cycle + 1
  if cycle == 1 then
    -- C: accessor created in the main chunk, read in a later defer cycle
    read(accC, "C  created sync, read in defer")
    read(accC, "C' same, after AudioAccessorValidateState", true)
    -- D: accessor created and read in the same defer cycle
    local accD = reaper.CreateTakeAudioAccessor(take)
    read(accD, "D  created + read in same defer cycle")
    reaper.DestroyAudioAccessor(accD)
    -- E: inside a coroutine resumed from defer (what the window does)
    local accE = reaper.CreateTakeAudioAccessor(take)
    local coE = coroutine.create(function() read(accE, "E  defer + coroutine, same cycle") end)
    local okE, errE = coroutine.resume(coE)
    if not okE then log("E error: %s", tostring(errE)) end
    _G.__probe_accE = accE
  elseif cycle == 2 then
    -- F: accessor created in previous defer cycle, read now (with and without validate)
    local accE = _G.__probe_accE
    read(accE, "F  created in previous defer cycle, read now")
    read(accE, "F' same, after AudioAccessorValidateState", true)
    for _, a in ipairs({ accA, accB, accC, accE }) do reaper.DestroyAudioAccessor(a) end
    log("Done.")
    return
  end
  reaper.defer(step)
end
reaper.defer(step)
