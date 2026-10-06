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

return T
