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

return T
