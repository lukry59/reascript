local H = require("helpers")
local fft = require("tom_autocut.fft")
local T = {}

T["impulse has a flat spectrum"] = function()
  local re, im = {}, {}
  for i = 1, 16 do re[i] = 0; im[i] = 0 end
  re[1] = 1
  fft.fft(re, im, 16)
  for k = 1, 16 do H.near(re[k], 1, 1e-12); H.near(im[k], 0, 1e-12) end
end

T["sine lands in its bin"] = function()
  local n = 1024
  local x = {}
  for i = 1, n do x[i] = math.sin(2 * math.pi * 64 * (i - 1) / n) end
  local p = fft.power_spectrum(x, 1, n)
  H.eq(#p, n / 2 + 1)
  local best, kb = -1, nil
  for k = 1, #p do if p[k] > best then best, kb = p[k], k - 1 end end
  H.eq(kb, 64)
end

T["Parseval holds on the raw fft"] = function()
  local n, re, im, e_t = 64, {}, {}, 0
  for i = 1, n do
    re[i] = math.sin(i * 0.37) + 0.3 * math.cos(i * 1.9); im[i] = 0
    e_t = e_t + re[i] ^ 2
  end
  fft.fft(re, im, n)
  local e_f = 0
  for k = 1, n do e_f = e_f + re[k] ^ 2 + im[k] ^ 2 end
  H.near(e_f / n, e_t, 1e-9)
end

T["power_spectrum zero-pads past the end"] = function()
  local p = fft.power_spectrum({ 1, 1 }, 1, 8)
  H.eq(#p, 5)
end

T["next_pow2"] = function()
  H.eq(fft.next_pow2(1881), 2048)
  H.eq(fft.next_pow2(2048), 2048)
  H.eq(fft.next_pow2(2049), 4096)
end

return T
