-- @noindex
-- REAPER audio access. Only functions reference `reaper`, so the module loads in tests.
local M = {}

function M.mix_to_mono(t, n, nch)
  if nch == 1 then return t end
  local out, inv = {}, 1 / nch
  for i = 1, n do
    local b, s = (i - 1) * nch, 0
    for c = 1, nch do s = s + t[b + c] end
    out[i] = s * inv
  end
  return out
end

local function zeros(n)
  local t = {}
  for i = 1, n do t[i] = 0 end
  return t
end

-- GetAudioAccessorSamples returns nil and fills nothing when called from inside a coroutine
-- (see tools/accessor_probe.lua). Inside a job, a read is therefore yielded as a request that
-- M.resume runs on the main context before resuming the job with its result.
M.READ_REQUEST = setmetatable({}, { __tostring = function() return "audio read request" end })

-- Drop-in for coroutine.resume on analysis jobs: serves read requests, passes every
-- other yield (progress) and the final return through unchanged.
function M.resume(co, ...)
  local res = table.pack(coroutine.resume(co, ...))
  while res[1] and res[2] == M.READ_REQUEST and coroutine.status(co) == "suspended" do
    res = table.pack(coroutine.resume(co, res[3]()))
  end
  return table.unpack(res, 1, res.n)
end

-- `on_invalid` is called when the take no longer exists (deleted while a job runs);
-- reads then return silence instead of touching a dead accessor.
function M.item_reader(take, sr, nch, on_invalid)
  local acc, buf, cap, t_start = nil, nil, 0, 0
  local function close()
    if acc then
      reaper.DestroyAudioAccessor(acc)
      acc = nil
    end
  end
  local function read_now(t0, n)
    if not reaper.ValidatePtr2(0, take, "MediaItem_Take*") then
      close()
      if on_invalid then on_invalid() end
      return zeros(n)
    end
    if not acc then
      acc = reaper.CreateTakeAudioAccessor(take)
      t_start = reaper.GetAudioAccessorStartTime(acc)
    end
    local need = n * nch
    if need > cap then
      buf = reaper.new_array(need)
      cap = need
    end
    buf.clear()
    reaper.GetAudioAccessorSamples(acc, sr, nch, t_start + t0, n, buf)
    return M.mix_to_mono(buf.table(1, need), n, nch)
  end
  local function read(t0, n)
    if n <= 0 then return {} end
    if coroutine.isyieldable() then
      return coroutine.yield(M.READ_REQUEST, function() return read_now(t0, n) end)
    end
    return read_now(t0, n)
  end
  return read, close
end

local function take_geometry(take)
  return reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"), reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
end

function M.fingerprint(item)
  local take = reaper.GetActiveTake(item)
  local offs, rate = 0, 1
  if take then offs, rate = take_geometry(take) end
  return ("%.9f|%.9f|%.9f|%.9f"):format(reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
    reaper.GetMediaItemInfo_Value(item, "D_LENGTH"), offs, rate)
end

function M.item_info(item)
  local take = reaper.GetActiveTake(item)
  if not take then return nil, "empty" end
  if reaper.TakeIsMIDI(take) then return nil, "midi" end
  if (math.floor(reaper.GetMediaItemInfo_Value(item, "C_LOCK")) & 1) == 1 then return nil, "locked" end
  local src = reaper.GetMediaItemTake_Source(take)
  local sr = reaper.GetMediaSourceSampleRate(src)
  if sr <= 0 then
    local parent = reaper.GetMediaSourceParent(src)
    if parent then
      src = parent
      sr = reaper.GetMediaSourceSampleRate(src)
    end
  end
  local nch = reaper.GetMediaSourceNumChannels(src)
  if sr <= 0 or nch <= 0 then return nil, "empty" end
  local offs, rate = take_geometry(take)
  local _, guid = reaper.GetSetMediaItemInfo_String(item, "GUID", "", false)
  local info = {
    item = item, take = take, key = guid,
    pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
    len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
    startoffs = offs, playrate = rate, sr = sr, nch = nch,
    fingerprint = M.fingerprint(item),
  }
  info.reader, info.close = M.item_reader(take, sr, nch, function() info.stale = true end)
  return info
end

return M
