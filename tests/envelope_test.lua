local H = require("helpers")
local S = require("synth")
local env = require("tom_autocut.envelope")
local SR = 48000
local T = {}

local function detect(buf)
  local fr = env.new_framer(SR, 0.001)
  fr:push(buf, #buf)
  local peaks = fr:finish()
  local fast, slow = env.envelopes(peaks, fr.frame_rate)
  return env.pick_candidates(env.onset_function(fast, slow), fast, fr.frame_rate)
end

T["framer outputs one max per ms"] = function()
  local fr = env.new_framer(SR, 0.001)
  local b = {}
  for i = 1, 480 do b[i] = (i == 100) and -0.5 or 0.01 end
  fr:push(b, 480)
  local p = fr:finish()
  H.eq(#p, 10)
  H.near(p[3], 0.5, 1e-12)
  H.near(p[1], 0.01, 1e-12)
end

T["framer handles blocks not aligned to frames"] = function()
  local fr = env.new_framer(SR, 0.001)
  local b = {}
  for i = 1, 100 do b[i] = 0.1 end
  for _ = 1, 9 do fr:push(b, 100) end
  H.eq(#fr:finish(), 19)
end

T["single tom hit is detected near its onset"] = function()
  local buf = S.silence(SR, 2.0)
  S.add_noise(buf, 1e-4)
  S.add_tom(buf, SR, 0.5003, { f0 = 90, amp = 0.8, decay = 0.6 })
  local c = detect(buf)
  H.eq(#c, 1, "candidate count")
  H.near(c[1].time, 0.5003, 0.0015, "frame time")
  H.truthy(c[1].peak_db > -6, "peak")
  H.truthy(c[1].sharpness > 0, "sharpness")
end

T["refine_onset finds the attack within 1 ms"] = function()
  local buf = S.silence(SR, 0.05)
  S.add_noise(buf, 1e-4)
  S.add_tom(buf, SR, 0.0200, { f0 = 90, amp = 0.8, decay = 0.6 })
  local w0 = 0.016
  local i0 = math.floor(w0 * SR)
  local win = {}
  for i = 1, math.floor(0.010 * SR) do win[i] = buf[i0 + i] end
  H.near(env.refine_onset(win, SR, w0), 0.0200, 0.001)
end

T["sixteenth-note roll at 180 BPM yields a candidate per hit"] = function()
  local buf = S.silence(SR, 2.0)
  S.add_noise(buf, 1e-4)
  for k = 0, 7 do S.add_tom(buf, SR, 0.3 + k * 60 / 180 / 4, { f0 = 90, amp = 0.6, decay = 0.6 }) end
  local c = detect(buf)
  H.truthy(#c >= 7 and #c <= 8, "got " .. #c)
end

T["onsets closer than 15 ms collapse to one"] = function()
  local buf = S.silence(SR, 1.0)
  S.add_tom(buf, SR, 0.300, { amp = 0.5 })
  S.add_tom(buf, SR, 0.308, { amp = 0.8 })
  H.eq(#detect(buf), 1)
end

T["silence yields no candidate"] = function()
  H.eq(#detect(S.silence(SR, 1.0)), 0)
end

T["item starting mid-ring yields no t=0 candidate"] = function()
  local buf = S.silence(SR, 1.0)
  for i = 1, #buf do
    local t = (i - 1) / SR
    buf[i] = 0.5 * math.exp(-t * 6.9 / 0.6) * math.sin(2 * math.pi * 90 * t + 1)
  end
  H.eq(#detect(buf), 0)
end

T["attack at the very start of an item is still detected"] = function()
  local buf = S.silence(SR, 1.0)
  S.add_tom(buf, SR, 0.002, { f0 = 90, amp = 0.8, decay = 0.6 })
  local c = detect(buf)
  H.eq(#c, 1, "candidate count")
  H.truthy(c[1].time < 0.005, "time " .. c[1].time)
end

return T
