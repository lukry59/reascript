-- @noindex
-- Radix-2 FFT and windowed power spectrum (pure Lua).
local M = {}
local cos, sin, pi = math.cos, math.sin, math.pi

function M.fft(re, im, n)
  local j = 0
  for i = 0, n - 2 do
    if i < j then
      re[i + 1], re[j + 1] = re[j + 1], re[i + 1]
      im[i + 1], im[j + 1] = im[j + 1], im[i + 1]
    end
    local m = n >> 1
    while m >= 1 and j >= m do
      j = j - m
      m = m >> 1
    end
    j = j + m
  end
  local len = 2
  while len <= n do
    local half = len >> 1
    local ang = -2 * pi / len
    local wr, wi = cos(ang), sin(ang)
    for s = 0, n - 1, len do
      local cr, ci = 1.0, 0.0
      for k = 0, half - 1 do
        local a, b = s + k + 1, s + k + half + 1
        local tr = re[b] * cr - im[b] * ci
        local ti = re[b] * ci + im[b] * cr
        re[b], im[b] = re[a] - tr, im[a] - ti
        re[a], im[a] = re[a] + tr, im[a] + ti
        cr, ci = cr * wr - ci * wi, cr * wi + ci * wr
      end
    end
    len = len << 1
  end
end

local hann_cache = {}
function M.hann(n)
  local w = hann_cache[n]
  if not w then
    w = {}
    for i = 0, n - 1 do w[i + 1] = 0.5 - 0.5 * cos(2 * pi * i / (n - 1)) end
    hann_cache[n] = w
  end
  return w
end

-- Hann-windowed |X|^2 of samples[first .. first+n-1], zero-padded past the end.
function M.power_spectrum(samples, first, n)
  local w = M.hann(n)
  local re, im, count = {}, {}, #samples
  for i = 1, n do
    local idx = first + i - 1
    local x = (idx >= 1 and idx <= count) and samples[idx] or 0
    re[i] = x * w[i]
    im[i] = 0
  end
  M.fft(re, im, n)
  local p = {}
  for k = 1, (n >> 1) + 1 do p[k] = re[k] * re[k] + im[k] * im[k] end
  return p
end

function M.next_pow2(x)
  local n = 1
  while n < x do n = n << 1 end
  return n
end

return M
