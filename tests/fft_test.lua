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
  -- Verify actual values: with Hann window, w[1]=0, so only x[2]*w[2] is nonzero.
  -- This produces a delta function spectrum with all bins having power w[2]^2.
  local w = fft.hann(8)
  local expected = w[2] * w[2]
  for k = 1, #p do
    H.near(p[k], expected, 1e-12)
    H.truthy(p[k] == p[k] and p[k] ~= 1/0 and p[k] ~= -1/0, "bin " .. k .. " must be finite")
  end

  -- Test with first=0: sample index 0 is padding, samples[1] and [2] land at window positions 2 and 3.
  -- DC component should be (w[2] + w[3])^2.
  local p2 = fft.power_spectrum({ 1, 1 }, 0, 8)
  H.eq(#p2, 5)
  local expected_dc = (w[2] + w[3]) * (w[2] + w[3])
  H.near(p2[1], expected_dc, 1e-12)
  for k = 1, #p2 do
    H.truthy(p2[k] == p2[k] and p2[k] ~= 1/0 and p2[k] ~= -1/0, "bin " .. k .. " must be finite")
  end
end

T["next_pow2"] = function()
  H.eq(fft.next_pow2(1881), 2048)
  H.eq(fft.next_pow2(2048), 2048)
  H.eq(fft.next_pow2(2049), 4096)
end

return T
