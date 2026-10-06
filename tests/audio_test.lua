local H = require("helpers")
local audio = require("tom_autocut.audio")
local T = {}

T["mix_to_mono averages interleaved channels"] = function()
  local m = audio.mix_to_mono({ 1, 3, -2, 2, 0.5, 0.5 }, 3, 2)
  H.eq(#m, 3)
  H.near(m[1], 2, 1e-12); H.near(m[2], 0, 1e-12); H.near(m[3], 0.5, 1e-12)
end

T["mix_to_mono passes mono through"] = function()
  local t = { 0.1, 0.2 }
  H.eq(audio.mix_to_mono(t, 2, 1), t)
end

T["mix_to_mono with 6 channels"] = function()
  local t = {}
  for i = 1, 12 do t[i] = (i <= 6) and 1 or 0 end
  local m = audio.mix_to_mono(t, 2, 6)
  H.near(m[1], 1, 1e-12); H.near(m[2], 0, 1e-12)
end

T["item_reader: deleted take reads silence and reports it"] = function()
  local valid, destroyed, created = true, 0, 0
  local prev = _G.reaper
  _G.reaper = {
    ValidatePtr2 = function() return valid end,
    CreateTakeAudioAccessor = function() created = created + 1; return {} end,
    GetAudioAccessorStartTime = function() return 0 end,
    DestroyAudioAccessor = function() destroyed = destroyed + 1 end,
    new_array = function(n)
      local a = {}
      return { clear = function() for i = 1, n do a[i] = 0.5 end end, table = function() return a end }
    end,
    GetAudioAccessorSamples = function() return 1 end,
  }
  local invalid = 0
  local ok, err = pcall(function()
    local read = audio.item_reader("take", 48000, 1, function() invalid = invalid + 1 end)
    H.eq(read(0, 4)[1], 0.5, "valid read")
    valid = false
    local z = read(0, 4)
    H.eq(#z, 4); H.eq(z[1], 0); H.eq(z[4], 0)
    H.eq(destroyed, 1, "accessor closed")
    H.eq(invalid, 1, "on_invalid called")
    read(0, 2)
    H.eq(created, 1, "no accessor on an invalid take")
  end)
  _G.reaper = prev
  if not ok then error(err, 0) end
end

-- REAPER's GetAudioAccessorSamples returns nil and leaves the buffer untouched when it is
-- called from inside a coroutine (measured with tools/accessor_probe.lua). The stub reproduces it.
local function coroutine_hostile_reaper()
  return {
    ValidatePtr2 = function() return true end,
    CreateTakeAudioAccessor = function() return {} end,
    GetAudioAccessorStartTime = function() return 0 end,
    DestroyAudioAccessor = function() end,
    new_array = function(n)
      local a = {}
      return {
        clear = function() for i = 1, n do a[i] = 0 end end,
        table = function(offset, size)
          if not offset then return a end
          local out = {}
          for i = 1, size do out[i] = a[offset + i - 1] end
          return out
        end,
        raw = a,
      }
    end,
    GetAudioAccessorSamples = function(_, _, _, _, n, buf)
      if coroutine.isyieldable() then return nil end
      local a = buf.raw
      for i = 1, n do a[i] = 0.25 end
      return 1
    end,
  }
end

T["item_reader inside a coroutine reads through audio.resume"] = function()
  local prev = _G.reaper
  _G.reaper = coroutine_hostile_reaper()
  local ok, err = pcall(function()
    local read = audio.item_reader("take", 48000, 1)
    local co = coroutine.create(function()
      local first = read(0, 3)
      coroutine.yield(0.5, "progress")
      return first, read(1, 2)
    end)
    local ok1, a, b = audio.resume(co)
    H.truthy(ok1, tostring(a))
    H.eq(a, 0.5, "progress yield passes through")
    H.eq(b, "progress")
    local ok2, first, second = audio.resume(co)
    H.truthy(ok2, tostring(first))
    H.eq(coroutine.status(co), "dead")
    H.eq(#first, 3); H.eq(first[1], 0.25, "first read has audio")
    H.eq(#second, 2); H.eq(second[2], 0.25, "second read has audio")
  end)
  _G.reaper = prev
  if not ok then error(err, 0) end
end

T["item_reader outside a coroutine reads directly"] = function()
  local prev = _G.reaper
  _G.reaper = coroutine_hostile_reaper()
  local ok, err = pcall(function()
    local read = audio.item_reader("take", 48000, 1)
    H.eq(read(0, 2)[2], 0.25)
  end)
  _G.reaper = prev
  if not ok then error(err, 0) end
end

T["audio.resume reports errors raised inside the job"] = function()
  local co = coroutine.create(function() error("boom", 0) end)
  local ok, msg = audio.resume(co)
  H.eq(ok, false)
  H.eq(msg, "boom")
end

return T
