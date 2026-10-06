local H = require("helpers")
local S = require("synth")
local bandtrack = require("tom_autocut.bandtrack")
local SR = 48000
local T = {}

local function run(buf, lo, hi)
  local t = bandtrack.new(SR, lo, hi, 0.010)
  t:push(buf, #buf)
  return t:finish()
end

local function sine(f, dur)
  local b = {}
  for i = 1, math.floor(SR * dur) do b[i] = math.sin(2 * math.pi * f * (i - 1) / SR) end
  return b
end

T["passes the band centre at about 0 dB"] = function()
  local band = run(sine(math.sqrt(70 * 180), 1.0), 70, 180)
  H.near(band.env_db[60], 0, 1.5)
  H.near(band.fr, 100, 1e-9)
end

T["rejects 5 kHz by more than 40 dB"] = function()
  H.truthy(run(sine(5000, 0.5), 70, 180).env_db[30] < -40)
end

T["noise floor is the 10th percentile"] = function()
  H.eq(bandtrack.percentile({ 5, 1, 4, 2, 3, 6, 7, 8, 9, 10 }, 0.10), 1)
end

T["tom decay shows up as a falling envelope"] = function()
  local buf = S.silence(SR, 1.0)
  S.add_tom(buf, SR, 0.1, { f0 = 112, amp = 0.8, decay = 0.6 })
  local e = run(buf, 70, 180).env_db
  -- -100 dB/s: 0.2 s later the band should be ~20 dB lower
  H.near(e[35] - e[55], 20, 3)
end

return T
