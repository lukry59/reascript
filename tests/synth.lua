-- Deterministic synthetic drum signals for tests.
local S = {}

function S.rng(seed)
  local s = seed or 12345
  return function()
    s = (s * 1103515245 + 12345) % 2147483648
    return s / 2147483648 * 2 - 1
  end
end

function S.silence(sr, dur)
  local t = {}
  for i = 1, math.floor(sr * dur + 0.5) do t[i] = 0 end
  return t
end

-- Damped sine with a short pitch bend; `decay` = seconds to reach -60 dB.
function S.add_tom(buf, sr, t0, opts)
  local f0, amp, decay = opts.f0 or 90, opts.amp or 0.8, opts.decay or 0.6
  local k = math.log(1000) / decay
  local i0 = math.floor(t0 * sr + 0.5) + 1
  local n = math.min(#buf - i0 + 1, math.floor(decay * 1.5 * sr))
  local phase = 0
  for j = 0, n - 1 do
    local t = j / sr
    local f = f0 * (1 + 0.15 * math.exp(-t / 0.03))
    phase = phase + 2 * math.pi * f / sr
    local a = amp * math.exp(-k * t) * math.min(1, j / 8)
    buf[i0 + j] = buf[i0 + j] + a * math.sin(phase)
  end
end

-- High-passed noise burst (snare / cymbal-like bleed).
function S.add_noise_burst(buf, sr, t0, opts)
  local amp, dur = opts.amp or 0.5, opts.dur or 0.15
  local r = S.rng(opts.seed or 7)
  local i0 = math.floor(t0 * sr + 0.5) + 1
  local n = math.min(#buf - i0 + 1, math.floor(dur * sr))
  local prev = 0
  for j = 0, n - 1 do
    local x = r()
    buf[i0 + j] = buf[i0 + j] + amp * 0.5 * (x - prev) * math.exp(-j / sr / (dur / 5))
    prev = x
  end
end

function S.add_noise(buf, amp, seed)
  local r = S.rng(seed or 99)
  for i = 1, #buf do buf[i] = buf[i] + amp * r() end
end

return S
