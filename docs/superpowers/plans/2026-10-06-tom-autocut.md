# GD Tom auto-cut — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Script ReaScript Lua distribué par ReaPack qui analyse des pistes de toms (transitoires + spectre + comparaison inter-pistes), construit des régions qui suivent le decay du fût et gèrent les roulements, puis découpe les items (Mute / Delete / Clean / Reset) depuis une fenêtre ReaImGui avec preview.

**Architecture:** Un cœur DSP en Lua pur (`envelope`, `fft`, `features`, `bandtrack`, `attribution`, `regions`, `cuts`, `settings`, `pipeline`, `analysis`) testé hors REAPER sur signaux synthétiques ; une fine couche REAPER (`audio`, `project`, `preview`, `apply`, `ui`) qui lit l'audio par audio accessor, persiste l'état et applique les coupes. L'analyse lourde (passes A et B) tourne dans une coroutine reprise par la boucle `defer` ; le recalcul léger (`pipeline.recompute`) est instantané et alimente la preview.

**Tech Stack:** Lua 5.4 (REAPER ReaScript), ReaImGui ≥ 0.9 (`require 'imgui' '0.9'`), ReaPack (`index.xml`, `reapack-index`), tests en Lua 5.4 pur.

**Spec:** `docs/superpowers/specs/2026-10-06-tom-autocut-design.md`

## Global Constraints

- Code compatible **Lua 5.4** : pas de mot-clé `global`, pas d'affectation aux variables de boucle `for`, opérateurs entiers `<<`/`>>`/`&` uniquement sur des valeurs entières.
- Les modules purs n'appellent **jamais** `reaper.*` (même indirectement au chargement).
- Modules requis par `require("tom_autocut.<nom>")` ; le point d'entrée ajoute `<dossier du script>/?.lua` à `package.path`.
- Tests : `sh tests/run.sh` (trouve `lua5.4` dans le PATH, sinon `/usr/local/opt/lua@5.4/bin/lua5.4`).
- Temps internes en **secondes, temps item** (0 = début de l'item) ; `ptime` = temps projet ; positions de take markers en **temps source** (`startoffs + t · playrate`).
- Préfixe d'actions `GD_` ; titre de fenêtre et d'Undo « GD Tom auto-cut » ; préfixe des take markers `GD·`.
- Tags d'items : `P_EXT:GD_TOMCUT` = `kept` | `muted` ; couleur d'origine dans `P_EXT:GD_TOMCUT_COL`.
- Section ExtState / ProjExtState : `GD_TomAutoCut`. Overrides de piste : `P_EXT:GD_TOMCUT_BAND` (`"lo-hi"`), `P_EXT:GD_TOMCUT_DECAY` (secondes).
- Valeurs par défaut (spec §4) : sensibilité 50 %, plancher −30 dB, pré-roll 5 ms, profondeur −40 dB, durée fixe 300 ms, min/max 60 ms / 2,5 s, merge gap 120 ms, fade in/out 2/30 ms, fenêtre inter-pistes ±3 ms, marge 6 dB, FFT 2048, poids 0,6 / 0,25 / 0,15.
- Textes UI en français.
- Pas de `git push` sans accord explicite de l'utilisateur.

## Review Focus

1. **Item avec playrate ≠ 1 ou offset de take ≠ 0** → markers et coupes aux bons instants (conversion temps item ↔ source). Test : `cuts_test` « item_to_src ».
2. **Piste silencieuse ou sans coup** → aucune erreur, aucune région, bande par défaut signalée. Test : `analysis_test` « silent track ».
3. **Source stéréo / multicanal** → somme mono correcte, pas de décalage d'échantillons. Test : `audio_test` « mix_to_mono ».
4. **Coup au tout début ou queue au-delà de la fin de l'item** → régions bornées à `[0, len]`, fenêtre FFT zero-paddée. Tests : `regions_test` « build clamps », `fft_test` « zero-pads ».
5. **Sample rate 96 kHz / 44,1 kHz** → taille FFT et f0 cohérents. Test : `features_test` « 96 kHz ».

---

### Task 1: Harnais de tests, générateur de signaux, FFT

**Files:**
- Create: `tests/run.sh`, `tests/run.lua`, `tests/helpers.lua`, `tests/synth.lua`
- Create: `Drums/tom_autocut/fft.lua`
- Test: `tests/fft_test.lua`

**Interfaces:**
- Produces: `fft.fft(re, im, n)` (in-place, n puissance de 2) ; `fft.hann(n) -> table` ; `fft.power_spectrum(samples, first, n) -> p[1..n/2+1]` (|X|², bin k à `k·sr/n`) ; `fft.next_pow2(x) -> int`.
- Produces (tests): `helpers.eq(a,b,msg)`, `helpers.near(a,b,tol,msg)`, `helpers.truthy(v,msg)` ; `synth.silence(sr,dur)`, `synth.add_tom(buf,sr,t0,{f0,amp,decay})` (decay = secondes jusqu'à −60 dB), `synth.add_noise_burst(buf,sr,t0,{amp,dur,seed})`, `synth.add_noise(buf,amp,seed)`, `synth.rng(seed)`.

- [ ] **Step 1: Écrire le harnais**

`tests/run.sh` :
```sh
#!/bin/sh
cd "$(dirname "$0")/.." || exit 1
LUA=$(command -v lua5.4 || echo /usr/local/opt/lua@5.4/bin/lua5.4)
exec "$LUA" tests/run.lua "$@"
```

`tests/run.lua` :
```lua
-- Usage: sh tests/run.sh [filter]
package.path = "./Drums/?.lua;./tests/?.lua;" .. package.path

local files = {}
local p = io.popen("ls tests/*_test.lua")
for line in p:lines() do files[#files + 1] = line:match("tests/(.+)%.lua$") end
p:close()

local filter = arg[1]
local passed, failed = 0, 0
for _, name in ipairs(files) do
  local ok_load, cases = pcall(require, name)
  if not ok_load then
    print("LOAD FAIL " .. name .. ": " .. tostring(cases))
    failed = failed + 1
  else
    local names = {}
    for k in pairs(cases) do names[#names + 1] = k end
    table.sort(names)
    for _, case in ipairs(names) do
      local full = name .. " :: " .. case
      if not filter or full:find(filter, 1, true) then
        local ok, err = xpcall(cases[case], debug.traceback)
        if ok then
          passed = passed + 1
          print("ok   " .. full)
        else
          failed = failed + 1
          print("FAIL " .. full .. "\n" .. err)
        end
      end
    end
  end
end
print(("\n%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
```

`tests/helpers.lua` :
```lua
local H = {}

function H.eq(a, b, msg)
  if a ~= b then error(("%s: expected %s, got %s"):format(msg or "eq", tostring(b), tostring(a)), 2) end
end

function H.near(a, b, tol, msg)
  if type(a) ~= "number" or math.abs(a - b) > tol then
    error(("%s: expected %.6g ± %.3g, got %s"):format(msg or "near", b, tol, tostring(a)), 2)
  end
end

function H.truthy(v, msg)
  if not v then error(msg or "expected truthy", 2) end
end

return H
```

`tests/synth.lua` :
```lua
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
```

- [ ] **Step 2: Écrire les tests FFT (en échec)**

`tests/fft_test.lua` :
```lua
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
```

- [ ] **Step 3: Lancer, constater l'échec**

Run: `sh tests/run.sh`
Expected: `LOAD FAIL fft_test: module 'tom_autocut.fft' not found`, `0 passed, 1 failed`.

- [ ] **Step 4: Implémenter `Drums/tom_autocut/fft.lua`**

```lua
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
```

- [ ] **Step 5: Lancer, constater le succès**

Run: `sh tests/run.sh`
Expected: `5 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
chmod +x tests/run.sh
git add tests Drums/tom_autocut/fft.lua
git commit -m "feat: add test harness, synthetic signals and FFT"
```

---

### Task 2: Enveloppes Peak et détection d'onsets

**Files:**
- Create: `Drums/tom_autocut/envelope.lua`
- Test: `tests/envelope_test.lua`

**Interfaces:**
- Produces: `envelope.to_db(x)` ; `envelope.new_framer(sr, frame_s) -> framer` avec `framer:push(block, n)`, `framer:finish() -> peaks`, `framer.frame_rate` ; `envelope.envelopes(peaks, frame_rate, {hold_s=0.010, slow_s=0.020}) -> fast, slow` ; `envelope.onset_function(fast, slow) -> odf` ; `envelope.adaptive_threshold(odf, frame_rate, window_s, k_db) -> thr` ; `envelope.pick_candidates(odf, fast, frame_rate, {k_db=3, median_s=1, min_gap_s=0.015, abs_floor_db=-70}) -> { {frame, time, peak, peak_db, odf_db, sharpness} }` ; `envelope.refine_onset(window, sr, t0) -> time`.

- [ ] **Step 1: Écrire les tests (en échec)**

`tests/envelope_test.lua` :
```lua
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

return T
```

- [ ] **Step 2: Lancer, constater l'échec**

Run: `sh tests/run.sh envelope`
Expected: `LOAD FAIL envelope_test: module 'tom_autocut.envelope' not found`.

- [ ] **Step 3: Implémenter `Drums/tom_autocut/envelope.lua`**

```lua
-- @noindex
-- Peak envelopes and onset detection (pure Lua).
local M = {}
local log, max, min, floor, abs, exp = math.log, math.max, math.min, math.floor, math.abs, math.exp

function M.to_db(x) return 20 * log(max(x, 1e-10), 10) end

-- Streaming framer: maximum absolute sample value per frame.
local Framer = {}
Framer.__index = Framer

function M.new_framer(sr, frame_s)
  local len = max(1, floor(sr * (frame_s or 0.001) + 0.5))
  return setmetatable({ frame_len = len, frame_rate = sr / len, pos = 0, cur = 0, peaks = {} }, Framer)
end

function Framer:push(block, n)
  local pos, cur, len, peaks = self.pos, self.cur, self.frame_len, self.peaks
  local np = #peaks
  for i = 1, n or #block do
    local x = block[i]
    if x < 0 then x = -x end
    if x > cur then cur = x end
    pos = pos + 1
    if pos == len then
      np = np + 1
      peaks[np] = cur
      pos, cur = 0, 0
    end
  end
  self.pos, self.cur = pos, cur
end

function Framer:finish()
  if self.pos > 0 then
    self.peaks[#self.peaks + 1] = self.cur
    self.pos, self.cur = 0, 0
  end
  return self.peaks
end

-- fast: peak hold over hold_s (instant attack, no ripple above 1/(2*hold_s) Hz).
-- slow: one-pole smoothing of fast; it lags behind every attack.
function M.envelopes(peaks, frame_rate, opts)
  opts = opts or {}
  local hold = max(1, floor((opts.hold_s or 0.010) * frame_rate + 0.5))
  local a = 1 - exp(-1 / ((opts.slow_s or 0.020) * frame_rate))
  local fast, slow = {}, {}
  local dq, head, tail, s = {}, 1, 0, 0
  for i = 1, #peaks do
    local v = peaks[i]
    while tail >= head and peaks[dq[tail]] <= v do tail = tail - 1 end
    tail = tail + 1
    dq[tail] = i
    if dq[head] <= i - hold then head = head + 1 end
    local f = peaks[dq[head]]
    fast[i] = f
    s = s + a * (f - s)
    slow[i] = s
  end
  return fast, slow
end

-- Rise of the fast envelope above the previous slow value, in dB (>= 0).
function M.onset_function(fast, slow)
  local odf, prev = {}, 0
  for i = 1, #fast do
    local d = M.to_db(fast[i]) - M.to_db(prev)
    odf[i] = d > 0 and d or 0
    prev = slow[i]
  end
  return odf
end

-- Sliding median (window_s) + k_db, recomputed every 250 ms.
function M.adaptive_threshold(odf, frame_rate, window_s, k_db)
  local n = #odf
  local hop = max(1, floor(0.25 * frame_rate))
  local half = floor(window_s * frame_rate / 2)
  local thr, i = {}, 1
  while i <= n do
    local c = i + floor(hop / 2)
    local w = {}
    for j = max(1, c - half), min(n, c + half) do w[#w + 1] = odf[j] end
    table.sort(w)
    local med = w[floor((#w + 1) / 2)] or 0
    for j = i, min(n, i + hop - 1) do thr[j] = med + k_db end
    i = i + hop
  end
  return thr
end

function M.pick_candidates(odf, fast, frame_rate, opts)
  opts = opts or {}
  local thr = M.adaptive_threshold(odf, frame_rate, opts.median_s or 1.0, opts.k_db or 3)
  local abs_floor = opts.abs_floor_db or -70
  local min_gap = max(1, floor((opts.min_gap_s or 0.015) * frame_rate + 0.5))
  local peak_win = max(1, floor(0.010 * frame_rate + 0.5))
  local n, out = #odf, {}
  for i = 1, n do
    local v = odf[i]
    if v > thr[i] and v >= (odf[i - 1] or 0) and v > (odf[i + 1] or 0) then
      local st = i
      while st > 1 and i - st < 10 and odf[st - 1] >= 1 do st = st - 1 end
      local pf, pv = i, fast[i]
      for j = i, min(n, i + peak_win) do
        if fast[j] > pv then pv, pf = fast[j], j end
      end
      local pdb = M.to_db(pv)
      if pdb > abs_floor then
        local rise_ms = max(1, (pf - st + 1) * 1000 / frame_rate)
        local c = { frame = st, time = (st - 1) / frame_rate, peak = pv, peak_db = pdb,
                    odf_db = v, sharpness = v / rise_ms }
        local last = out[#out]
        if last and st - last.frame < min_gap then
          if v > last.odf_db then out[#out] = c end
        else
          out[#out + 1] = c
        end
      end
    end
  end
  return out
end

-- window: mono samples starting at time t0. Returns the time of the attack start.
function M.refine_onset(window, sr, t0)
  local n = #window
  local pk = 0
  for i = 1, n do
    local a = abs(window[i])
    if a > pk then pk = a end
  end
  if pk == 0 then return t0 end
  local noise = 0
  for i = 1, min(n, floor(sr * 0.002)) do
    local a = abs(window[i])
    if a > noise then noise = a end
  end
  local thr = noise + 0.1 * (pk - noise)
  for i = 1, n do
    if abs(window[i]) >= thr then
      local j = i
      while j > 1 and window[j - 1] * window[i] > 0 and (i - j) < sr * 0.002 do j = j - 1 end
      return t0 + (j - 1) / sr
    end
  end
  return t0
end

return M
```

- [ ] **Step 4: Lancer, constater le succès**

Run: `sh tests/run.sh envelope`
Expected: `7 passed, 0 failed`. Si le test de roulement échoue (ex. 6 candidats), ne pas relâcher l'assertion : examiner `odf` autour des coups manqués et ajuster `k_db` (défaut 3) ou `slow_s` (défaut 0.020) ; noter la valeur retenue dans le commit.

- [ ] **Step 5: Commit**

```bash
git add Drums/tom_autocut/envelope.lua tests/envelope_test.lua
git commit -m "feat: add dual peak envelope and onset detection"
```

---

### Task 3: Features spectrales, modèle de piste, score

**Files:**
- Create: `Drums/tom_autocut/features.lua`
- Test: `tests/features_test.lua`

**Interfaces:**
- Consumes: `fft.power_spectrum`, `fft.next_pow2`.
- Produces: `features.fft_size(sr, base) -> int` ; `features.extract(samples, sr, n_fft) -> {f0, e_low, e_high, low (|X|² bins 0..1000 Hz), bin_hz}` ; `features.band_energy(feat, lo, hi) -> number` ; `features.learn_track(cands, {band={lo,hi}}?) -> model {ok, manual, f0, band_lo, band_hi, typical_e, typical_peak_db, typical_ratio_db, typical_sharp, n_strong}` ; `features.score(c, model, floor_db) -> 0..1` (c: `{feat, peak_db, sharpness, band_e}`) ; `features.DEFAULT_BAND = {60, 300}`.

- [ ] **Step 1: Écrire les tests (en échec)**

`tests/features_test.lua` :
```lua
local H = require("helpers")
local S = require("synth")
local features = require("tom_autocut.features")
local SR = 48000
local T = {}

local function tom_buf(sr, f0, amp)
  local b = S.silence(sr, 0.2)
  S.add_tom(b, sr, 0, { f0 = f0, amp = amp or 0.8, decay = 0.6 })
  return b
end

local function noise_buf(sr)
  local b = S.silence(sr, 0.2)
  S.add_noise_burst(b, sr, 0, { amp = 0.5 })
  return b
end

local function cand(buf, sr, peak_db, sharp)
  return { feat = features.extract(buf, sr, features.fft_size(sr, 2048)), peak_db = peak_db, sharpness = sharp or 10 }
end

local function ratio_db(f) return 10 * math.log(f.e_low / f.e_high, 10) end

T["fft_size scales with the sample rate"] = function()
  H.eq(features.fft_size(44100, 2048), 2048)
  H.eq(features.fft_size(48000, 2048), 2048)
  H.eq(features.fft_size(96000, 2048), 4096)
end

T["tom: f0 found and low band dominates"] = function()
  local f = features.extract(tom_buf(SR, 90), SR, 2048)
  H.near(f.f0, 95, 12, "f0")
  H.truthy(ratio_db(f) > 20, "ratio " .. ratio_db(f))
end

T["noise burst: high band dominates"] = function()
  H.truthy(ratio_db(features.extract(noise_buf(SR), SR, 2048)) < 0)
end

T["96 kHz: same f0 with a scaled FFT"] = function()
  local f = features.extract(tom_buf(96000, 90), 96000, features.fft_size(96000, 2048))
  H.near(f.f0, 95, 12)
end

T["band_energy sums the kept bins in range"] = function()
  local feat = { low = { 1, 1, 1, 1, 1, 1 }, bin_hz = 10 }
  H.eq(features.band_energy(feat, 20, 40), 3)
end

T["learn_track: band from the strongest low-dominant hits"] = function()
  local cs = {}
  for i = 1, 6 do cs[#cs + 1] = cand(tom_buf(SR, 90, 0.8), SR, -2 - i * 0.5) end
  for i = 1, 4 do cs[#cs + 1] = cand(tom_buf(SR, 150, 0.1), SR, -20) end
  cs[#cs + 1] = cand(noise_buf(SR), SR, 0)
  local m = features.learn_track(cs)
  H.truthy(m.ok, "ok")
  H.near(m.f0, 95, 12, "f0")
  H.near(m.band_lo, 0.75 * m.f0, 1e-9)
  H.near(m.band_hi, 2 * m.f0, 1e-9)
end

T["learn_track: two strong hits are enough"] = function()
  local cs = { cand(tom_buf(SR, 90), SR, -3), cand(tom_buf(SR, 90), SR, -4) }
  H.truthy(features.learn_track(cs).ok)
end

T["learn_track: no hit gives the default band"] = function()
  local m = features.learn_track({})
  H.truthy(not m.ok)
  H.eq(m.band_lo, 60); H.eq(m.band_hi, 300)
end

T["learn_track: manual band wins"] = function()
  local cs = { cand(tom_buf(SR, 90), SR, -3), cand(tom_buf(SR, 90), SR, -4) }
  local m = features.learn_track(cs, { band = { 70, 180 } })
  H.eq(m.band_lo, 70); H.eq(m.band_hi, 180); H.truthy(m.manual)
end

T["score: real hit high, snare-like bleed low, below floor zero"] = function()
  local cs = {}
  for i = 1, 5 do cs[#cs + 1] = cand(tom_buf(SR, 90), SR, -3) end
  local m = features.learn_track(cs)
  local function scored(c)
    c.band_e = features.band_energy(c.feat, m.band_lo, m.band_hi)
    return features.score(c, m, -30)
  end
  H.truthy(scored(cand(tom_buf(SR, 90), SR, -3)) > 0.7, "hit")
  H.truthy(scored(cand(noise_buf(SR), SR, -10)) < 0.4, "noise")
  H.eq(scored(cand(tom_buf(SR, 90), SR, -40)), 0, "floor")
end

return T
```

- [ ] **Step 2: Lancer, constater l'échec**

Run: `sh tests/run.sh features`
Expected: `LOAD FAIL features_test: module 'tom_autocut.features' not found`.

- [ ] **Step 3: Implémenter `Drums/tom_autocut/features.lua`**

```lua
-- @noindex
-- Spectral features, per-track model and single-track score (pure Lua).
local fft = require("tom_autocut.fft")
local M = {}
local log, max, min, floor, ceil, abs = math.log, math.max, math.min, math.floor, math.ceil, math.abs

M.DEFAULT_BAND = { 60, 300 }
M.KEEP_HZ = 1000

local function db10(x) return 10 * log(max(x, 1e-30), 10) end
local function clamp01(x) return x < 0 and 0 or (x > 1 and 1 or x) end

local function median(t)
  if #t == 0 then return nil end
  local s = {}
  for i, v in ipairs(t) do s[i] = v end
  table.sort(s)
  return s[floor((#s + 1) / 2)]
end
M.median = median

function M.fft_size(sr, base) return fft.next_pow2((base or 2048) * sr / 48000) end

function M.extract(samples, sr, n_fft)
  local p = fft.power_spectrum(samples, 1, n_fft)
  local bin_hz = sr / n_fft
  local last = #p - 1
  local function band(lo, hi)
    local s = 0
    for k = max(1, floor(lo / bin_hz)), min(last, ceil(hi / bin_hz)) do s = s + p[k + 1] end
    return s
  end
  local kb, best = nil, -1
  for k = max(1, ceil(50 / bin_hz)), min(last - 1, floor(400 / bin_hz)) do
    if p[k + 1] > best then best, kb = p[k + 1], k end
  end
  local f0 = (kb or 1) * bin_hz
  if kb then
    local a, b, c = log(p[kb] + 1e-30), log(p[kb + 1] + 1e-30), log(p[kb + 2] + 1e-30)
    local d = a - 2 * b + c
    if d < 0 then f0 = (kb + 0.5 * (a - c) / d) * bin_hz end
  end
  local low = {}
  for k = 0, min(last, floor(M.KEEP_HZ / bin_hz)) do low[k + 1] = p[k + 1] end
  return { f0 = f0, e_low = band(40, 400), e_high = band(2000, 10000), low = low, bin_hz = bin_hz }
end

function M.band_energy(feat, lo, hi)
  local s = 0
  for k = max(0, ceil(lo / feat.bin_hz)), min(#feat.low - 1, floor(hi / feat.bin_hz)) do
    s = s + feat.low[k + 1]
  end
  return s
end

function M.learn_track(cands, opts)
  opts = opts or {}
  local pool = {}
  for _, c in ipairs(cands) do
    if c.feat.e_low > c.feat.e_high then pool[#pool + 1] = c end
  end
  table.sort(pool, function(a, b) return a.peak_db > b.peak_db end)
  local strong = {}
  local cap = max(5, ceil(#pool * 0.2))
  for _, c in ipairs(pool) do
    if c.peak_db >= pool[1].peak_db - 6 and #strong < cap then strong[#strong + 1] = c end
  end
  local m = { ok = #strong >= 2, n_strong = #strong }
  local f0s = {}
  for i, c in ipairs(strong) do f0s[i] = c.feat.f0 end
  if opts.band then
    m.manual = true
    m.band_lo, m.band_hi = opts.band[1], opts.band[2]
    m.f0 = m.band_lo / 0.75
  elseif m.ok then
    m.f0 = median(f0s)
    m.band_lo, m.band_hi = 0.75 * m.f0, 2 * m.f0
  else
    m.band_lo, m.band_hi = M.DEFAULT_BAND[1], M.DEFAULT_BAND[2]
    m.f0 = m.band_lo / 0.75
  end
  local es, peaks, ratios, sharps = {}, {}, {}, {}
  for i, c in ipairs(strong) do
    es[i] = M.band_energy(c.feat, m.band_lo, m.band_hi)
    peaks[i] = c.peak_db
    ratios[i] = db10(c.feat.e_low / max(c.feat.e_high, 1e-30))
    sharps[i] = c.sharpness
  end
  m.typical_e = median(es) or 1e-12
  m.typical_peak_db = median(peaks) or 0
  m.typical_ratio_db = median(ratios) or 20
  m.typical_sharp = median(sharps) or 1
  return m
end

function M.score(c, model, floor_db)
  if c.peak_db < model.typical_peak_db + floor_db then return 0 end
  local s_e = clamp01((db10(c.band_e / max(model.typical_e, 1e-30)) + 20) / 20)
  local r_db = db10(c.feat.e_low / max(c.feat.e_high, 1e-30))
  local s_r = clamp01(1 + (r_db - model.typical_ratio_db) / 20)
  local s_s = clamp01(c.sharpness / max(model.typical_sharp, 1e-9))
  local s_f = clamp01(1 - abs(log(max(c.feat.f0, 1) / model.f0, 2)) / 0.5)
  return 0.45 * s_e + 0.25 * s_r + 0.15 * s_s + 0.15 * s_f
end

return M
```

- [ ] **Step 4: Lancer, constater le succès**

Run: `sh tests/run.sh features`
Expected: `10 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add Drums/tom_autocut/features.lua tests/features_test.lua
git commit -m "feat: add spectral features, track model and score"
```

---

### Task 4: Suivi de bande (decay)

**Files:**
- Create: `Drums/tom_autocut/bandtrack.lua`
- Test: `tests/bandtrack_test.lua`

**Interfaces:**
- Produces: `bandtrack.new(sr, lo, hi, frame_s) -> tracker` avec `tracker:push(block, n)` et `tracker:finish() -> band {env_db, fr, noise_db, lo, hi}` ; `bandtrack.percentile(t, q) -> number`.

- [ ] **Step 1: Écrire les tests (en échec)**

`tests/bandtrack_test.lua` :
```lua
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
```

- [ ] **Step 2: Lancer, constater l'échec**

Run: `sh tests/run.sh bandtrack`
Expected: `LOAD FAIL bandtrack_test`.

- [ ] **Step 3: Implémenter `Drums/tom_autocut/bandtrack.lua`**

```lua
-- @noindex
-- Band-pass (two cascaded RBJ biquads) + 10 ms peak envelope (pure Lua).
local M = {}
local floor, max, log, sqrt, sin, cos, pi = math.floor, math.max, math.log, math.sqrt, math.sin, math.cos, math.pi

local Tracker = {}
Tracker.__index = Tracker

function M.new(sr, lo, hi, frame_s)
  local fc = sqrt(lo * hi)
  local q = fc / max(hi - lo, 1)
  local w0 = 2 * pi * fc / sr
  local alpha = sin(w0) / (2 * q)
  local a0 = 1 + alpha
  local len = max(1, floor(sr * (frame_s or 0.010) + 0.5))
  return setmetatable({
    b0 = alpha / a0, b2 = -alpha / a0, a1 = -2 * cos(w0) / a0, a2 = (1 - alpha) / a0,
    x1 = 0, x2 = 0, y1 = 0, y2 = 0, v1 = 0, v2 = 0,
    frame_len = len, frame_rate = sr / len, pos = 0, cur = 0, env = {}, lo = lo, hi = hi,
  }, Tracker)
end

function Tracker:push(block, n)
  local b0, b2, a1, a2 = self.b0, self.b2, self.a1, self.a2
  local x1, x2, y1, y2, v1, v2 = self.x1, self.x2, self.y1, self.y2, self.v1, self.v2
  local pos, cur, len, env = self.pos, self.cur, self.frame_len, self.env
  local ne = #env
  for i = 1, n or #block do
    local x = block[i]
    local y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
    x2, x1 = x1, x
    -- second section takes y as input; its x history is (y1, y2) before the shift
    local v = b0 * y + b2 * y2 - a1 * v1 - a2 * v2
    y2, y1 = y1, y
    v2, v1 = v1, v
    if v < 0 then v = -v end
    if v > cur then cur = v end
    pos = pos + 1
    if pos == len then
      ne = ne + 1
      env[ne] = cur
      pos, cur = 0, 0
    end
  end
  self.x1, self.x2, self.y1, self.y2, self.v1, self.v2 = x1, x2, y1, y2, v1, v2
  self.pos, self.cur = pos, cur
end

function M.percentile(t, q)
  if #t == 0 then return -200 end
  local s = {}
  for i, v in ipairs(t) do s[i] = v end
  table.sort(s)
  return s[max(1, floor(#s * q + 0.5))]
end

function Tracker:finish()
  if self.pos > 0 then
    self.env[#self.env + 1] = self.cur
    self.pos, self.cur = 0, 0
  end
  local env, db = self.env, {}
  for i = 1, #env do
    local v = env[i]
    local p = env[i - 1]
    if p and p > v then v = p end
    db[i] = 20 * log(max(v, 1e-10), 10)
  end
  return { env_db = db, fr = self.frame_rate, noise_db = M.percentile(db, 0.10), lo = self.lo, hi = self.hi }
end

return M
```

Note : la seconde section utilise `y2` (sortie de la section 1 à n−2) comme entrée retardée ; le `b1` du passe-bande RBJ est nul, donc seuls `x[n]` et `x[n−2]` interviennent.

- [ ] **Step 4: Lancer, constater le succès**

Run: `sh tests/run.sh bandtrack`
Expected: `4 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add Drums/tom_autocut/bandtrack.lua tests/bandtrack_test.lua
git commit -m "feat: add band-pass decay tracker"
```

---

### Task 5: Attribution inter-pistes

**Files:**
- Create: `Drums/tom_autocut/attribution.lua`
- Test: `tests/attribution_test.lua`

**Interfaces:**
- Consumes: pistes `{name, role="tom"|"ref", model={typical_e, typical_sharp}, cands={ {ptime, band_e, sharpness, score} }}`.
- Produces: `attribution.attribute(tracks, opts)` avec `opts = {threshold, window_s, margin_db, weights={energy, arrival, sharp}}` ; écrit `c.status` (`"hit"|"bleed"|"rejected"|"ref"`), `c.bleed_from` (nom de piste), `c.dominance`.

- [ ] **Step 1: Écrire les tests (en échec)**

`tests/attribution_test.lua` :
```lua
local H = require("helpers")
local attribution = require("tom_autocut.attribution")
local T = {}

local OPTS = { threshold = 0.5, window_s = 0.003, margin_db = 6,
               weights = { energy = 0.6, arrival = 0.25, sharp = 0.15 } }

local function track(name, role, cands)
  return { name = name, role = role, model = { typical_e = 1, typical_sharp = 10 }, cands = cands }
end

local function cand(ptime, band_e, sharp, score)
  return { ptime = ptime, band_e = band_e, sharpness = sharp or 10, score = score or 0.9 }
end

T["bleed 2 ms late and 12 dB down goes to the source"] = function()
  local a, b = cand(1.0, 1), cand(1.002, 10 ^ -1.2, 5, 0.8)
  attribution.attribute({ track("Floor", "tom", { a }), track("Tom 1", "tom", { b }) }, OPTS)
  H.eq(a.status, "hit")
  H.eq(b.status, "bleed")
  H.eq(b.bleed_from, "Floor")
end

T["simultaneous flam keeps both hits"] = function()
  local a, b = cand(1.0, 1), cand(1.0005, 0.8)
  attribution.attribute({ track("Floor", "tom", { a }), track("Tom 1", "tom", { b }) }, OPTS)
  H.eq(a.status, "hit")
  H.eq(b.status, "hit")
end

T["dominant reference marks the tom as bleed"] = function()
  local s, t = cand(2.0, 1), cand(2.001, 0.05)
  attribution.attribute({ track("Snare", "ref", { s }), track("Tom 1", "tom", { t }) }, OPTS)
  H.eq(s.status, "ref")
  H.eq(t.status, "bleed")
  H.eq(t.bleed_from, "Snare")
end

T["isolated candidate is judged on its score"] = function()
  local lo, hi = cand(1.0, 1, 10, 0.3), cand(2.0, 1, 10, 0.7)
  attribution.attribute({ track("Tom 1", "tom", { lo, hi }) }, OPTS)
  H.eq(lo.status, "rejected")
  H.eq(hi.status, "hit")
end

T["clusters do not chain beyond the window"] = function()
  local a, b, c = cand(0, 1), cand(0.0025, 0.01), cand(0.0050, 1)
  attribution.attribute({ track("A", "tom", { a }), track("B", "tom", { b }), track("C", "tom", { c }) }, OPTS)
  H.eq(b.status, "bleed")
  H.eq(c.status, "hit")
end

return T
```

- [ ] **Step 2: Lancer, constater l'échec**

Run: `sh tests/run.sh attribution`
Expected: `LOAD FAIL attribution_test`.

- [ ] **Step 3: Implémenter `Drums/tom_autocut/attribution.lua`**

```lua
-- @noindex
-- Cross-track attribution of hits vs bleed (pure Lua).
local M = {}
local log, max = math.log, math.max

local function db10(x) return 10 * log(max(x, 1e-30), 10) end

local function dominance(c, tr, t_min, opts)
  local w = opts.weights
  local e = db10(c.band_e / max(tr.model.typical_e, 1e-30))
  local a = -12 * (c.ptime - t_min) / opts.window_s
  local s = db10(c.sharpness / max(tr.model.typical_sharp, 1e-9))
  return (w.energy * e + w.arrival * a + w.sharp * s) / (w.energy + w.arrival + w.sharp)
end

function M.attribute(tracks, opts)
  local all = {}
  for _, tr in ipairs(tracks) do
    for _, c in ipairs(tr.cands) do
      c.status, c.bleed_from, c.dominance = nil, nil, nil
      all[#all + 1] = { c = c, tr = tr }
    end
  end
  table.sort(all, function(a, b) return a.c.ptime < b.c.ptime end)
  local i = 1
  while i <= #all do
    local t0 = all[i].c.ptime
    local j = i
    while j < #all and all[j + 1].c.ptime - t0 <= opts.window_s do j = j + 1 end
    local best_tom, best_ref
    for k = i, j do
      local m = all[k]
      m.c.dominance = dominance(m.c, m.tr, t0, opts)
      if m.tr.role == "ref" then
        if not best_ref or m.c.dominance > best_ref.c.dominance then best_ref = m end
      elseif not best_tom or m.c.dominance > best_tom.c.dominance then
        best_tom = m
      end
    end
    for k = i, j do
      local m = all[k]
      local c = m.c
      if m.tr.role == "ref" then
        c.status = "ref"
      elseif best_ref and best_ref.c.dominance > c.dominance + opts.margin_db then
        c.status, c.bleed_from = "bleed", best_ref.tr.name
      elseif best_tom ~= m and best_tom.c.dominance > c.dominance + opts.margin_db then
        c.status, c.bleed_from = "bleed", best_tom.tr.name
      elseif c.score < opts.threshold then
        c.status = "rejected"
      else
        c.status = "hit"
      end
    end
    i = j + 1
  end
end

return M
```

- [ ] **Step 4: Lancer, constater le succès**

Run: `sh tests/run.sh attribution`
Expected: `5 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add Drums/tom_autocut/attribution.lua tests/attribution_test.lua
git commit -m "feat: add cross-track hit attribution"
```

---

### Task 6: Régions, decay automatique, roulements

**Files:**
- Create: `Drums/tom_autocut/regions.lua`
- Test: `tests/regions_test.lua`

**Interfaces:**
- Produces: `regions.DEFAULT_SLOPE_DB_S = -60` ; `regions.band_peak(env_db, fr, t) -> peak_db, frame` ; `regions.measure_slope(env_db, fr, t, noise_db, max_s) -> slope|nil` ; `regions.decay_model(entries, {isolation_s=1.5}) -> {slope_db_s|nil, typical_peak_db|nil, n_isolated}` avec `entries = { {onsets, env_db, fr, noise_db} }` ; `regions.hit_end(env_db, fr, t, {target_db, noise_db, slope, min_s, max_s}) -> time` ; `regions.model_end(env_db, fr, t, {target_db, slope, min_s, max_s}) -> time` ; `regions.build(onsets, ends, item_len, {preroll_s, merge_gap_s, fade_in_s, fade_out_s, auto}) -> { {s, e, first, last, hits, fade_in, fade_out} }`.

- [ ] **Step 1: Écrire les tests (en échec)**

`tests/regions_test.lua` :
```lua
local H = require("helpers")
local regions = require("tom_autocut.regions")
local FR = 100
local T = {}

-- Synthetic band envelope: each hit {t, peak_db} decays linearly at `slope` dB/s.
local function env_line(dur, hits, slope, noise)
  local e = {}
  for i = 1, math.floor(dur * FR) do
    local t, v = (i - 1) / FR, noise
    for _, h in ipairs(hits) do
      if t >= h[1] then v = math.max(v, h[2] + slope * (t - h[1])) end
    end
    e[i] = v
  end
  return e
end

local BUILD = { preroll_s = 0.005, merge_gap_s = 0.12, fade_in_s = 0.002, fade_out_s = 0.03, auto = true }

T["measure_slope recovers the decay slope"] = function()
  local e = env_line(3, { { 0.5, -6 } }, -100, -90)
  H.near(regions.measure_slope(e, FR, 0.5, -90, 1.5), -100, 2)
end

T["hit_end: a loud hit rings longer than a soft one"] = function()
  local e = env_line(3, { { 0.5, -6 }, { 1.5, -18 } }, -100, -90)
  local o = { target_db = -46, noise_db = -90, slope = -100, min_s = 0.06, max_s = 2.5 }
  H.near(regions.hit_end(e, FR, 0.5, o) - 0.5, 0.40, 0.02)
  H.near(regions.hit_end(e, FR, 1.5, o) - 1.5, 0.28, 0.02)
end

T["hit_end extrapolates when another source masks the tail"] = function()
  local e = env_line(3, { { 0.5, -6 }, { 0.8, -10 } }, -100, -90)
  local o = { target_db = -46, noise_db = -90, slope = -100, min_s = 0.06, max_s = 2.5 }
  H.near(regions.hit_end(e, FR, 0.5, o) - 0.5, 0.40, 0.03)
end

T["hit_end respects min and max"] = function()
  local e = env_line(3, { { 0.5, -6 } }, -100, -90)
  H.near(regions.hit_end(e, FR, 0.5, { target_db = -10, noise_db = -90, slope = -100, min_s = 0.06, max_s = 2.5 }), 0.56, 1e-9)
  H.near(regions.hit_end(e, FR, 0.5, { target_db = -200, noise_db = -300, slope = -100, min_s = 0.06, max_s = 0.3 }), 0.8, 1e-9)
end

T["model_end follows the given slope"] = function()
  local e = env_line(3, { { 0.5, -6 } }, -100, -90)
  H.near(regions.model_end(e, FR, 0.5, { target_db = -46, slope = -200, min_s = 0.06, max_s = 2.5 }) - 0.5, 0.20, 0.02)
end

T["decay_model uses isolated hits only"] = function()
  local hits = { { 0.5, -6 }, { 3.0, -6 }, { 5.0, -30 }, { 5.1, -30 } }
  local e = env_line(7, hits, -100, -90)
  local dm = regions.decay_model({ { onsets = { 0.5, 3.0, 5.0, 5.1 }, env_db = e, fr = FR, noise_db = -90 } })
  H.near(dm.slope_db_s, -100, 3)
  H.eq(dm.n_isolated, 3)
  H.near(dm.typical_peak_db, -6, 0.5)
end

T["build: a roll gives one region"] = function()
  local on, en = {}, {}
  for k = 0, 7 do on[#on + 1] = 0.3 + k * 0.0833; en[#en + 1] = on[#on] + 0.3 end
  local r = regions.build(on, en, 5, BUILD)
  H.eq(#r, 1)
  H.eq(r[1].hits, 8)
  H.near(r[1].s, 0.295, 1e-9)
  H.near(r[1].e, on[8] + 0.3, 1e-9)
end

T["build: merge gap joins close regions"] = function()
  local o = {}
  for k, v in pairs(BUILD) do o[k] = v end
  o.merge_gap_s = 0.25
  H.eq(#regions.build({ 0.5, 1.0 }, { 0.8, 1.3 }, 5, o), 1)
  o.merge_gap_s = 0.1
  H.eq(#regions.build({ 0.5, 1.0 }, { 0.8, 1.3 }, 5, o), 2)
end

T["build clamps regions to the item bounds"] = function()
  local r = regions.build({ 0.002, 4.9 }, { 0.3, 5.4 }, 5, BUILD)
  H.eq(r[1].s, 0)
  H.eq(r[2].e, 5)
end

T["build: fades never cover the attack"] = function()
  local r = regions.build({ 1.0 }, { 1.02 }, 5, BUILD)
  H.truthy(r[1].fade_out <= r[1].e - r[1].last + 1e-12)
  H.truthy(r[1].fade_in <= 0.002 + 1e-12)
end

return T
```

- [ ] **Step 2: Lancer, constater l'échec**

Run: `sh tests/run.sh regions`
Expected: `LOAD FAIL regions_test`.

- [ ] **Step 3: Implémenter `Drums/tom_autocut/regions.lua`**

```lua
-- @noindex
-- Regions: decay-driven ends, rolls, merge gap, fades (pure Lua).
local M = {}
local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil

M.DEFAULT_SLOPE_DB_S = -60

function M.band_peak(env_db, fr, t)
  local i0 = max(1, floor(t * fr) + 1)
  local i1 = min(#env_db, i0 + ceil(0.05 * fr))
  local ip, pk = i0, -math.huge
  for i = i0, i1 do
    if env_db[i] > pk then pk, ip = env_db[i], i end
  end
  return pk, ip
end

function M.measure_slope(env_db, fr, t, noise_db, max_s)
  local pk, ip = M.band_peak(env_db, fr, t)
  if pk == -math.huge then return nil end
  local stop = max(pk - 30, noise_db + 6)
  local last = min(#env_db, ip + floor((max_s or 2.5) * fr))
  local sx, sy, sxx, sxy, n, lowest = 0, 0, 0, 0, 0, math.huge
  for i = ip, last do
    local y = env_db[i]
    if y < stop or y > lowest + 3 then break end
    if y < lowest then lowest = y end
    local x = (i - ip) / fr
    sx, sy, sxx, sxy, n = sx + x, sy + y, sxx + x * x, sxy + x * y, n + 1
  end
  if n < 5 then return nil end
  local den = n * sxx - sx * sx
  if den <= 0 then return nil end
  local slope = (n * sxy - sx * sy) / den
  if slope >= -1 then return nil end
  return slope
end

function M.decay_model(entries, opts)
  local iso = (opts and opts.isolation_s) or 1.5
  local slopes, peaks = {}, {}
  for _, e in ipairs(entries) do
    for k, t in ipairs(e.onsets) do
      local pk = M.band_peak(e.env_db, e.fr, t)
      if pk > -math.huge then peaks[#peaks + 1] = pk end
      local nxt = e.onsets[k + 1]
      if not nxt or nxt - t >= iso then
        local s = M.measure_slope(e.env_db, e.fr, t, e.noise_db, iso)
        if s then slopes[#slopes + 1] = s end
      end
    end
  end
  table.sort(slopes)
  table.sort(peaks)
  local typical
  if #peaks > 0 then
    local ntop = max(1, floor(#peaks * 0.2 + 0.5))
    typical = peaks[#peaks - floor((ntop - 1) / 2)]
  end
  return {
    slope_db_s = #slopes > 0 and slopes[floor((#slopes + 1) / 2)] or nil,
    typical_peak_db = typical,
    n_isolated = #slopes,
  }
end

function M.hit_end(env_db, fr, t, o)
  local lo, hi = t + o.min_s, t + o.max_s
  local _, ip = M.band_peak(env_db, fr, t)
  local target = max(o.target_db, o.noise_db + 3)
  local last = min(#env_db, floor(hi * fr) + 1)
  local mval, mi, e = math.huge, ip, nil
  for i = ip, last do
    local y = env_db[i]
    if y <= target then
      e = (i - 1) / fr
      break
    end
    if y < mval then
      mval, mi = y, i
    elseif y > mval + 3 then
      break
    end
  end
  if not e then
    if mval == math.huge then
      e = hi
    else
      e = (mi - 1) / fr + (mval - target) / -o.slope
    end
  end
  return min(max(e, lo), hi)
end

function M.model_end(env_db, fr, t, o)
  local pk = M.band_peak(env_db, fr, t)
  local e = (pk == -math.huge) and (t + o.max_s) or (t + (pk - o.target_db) / -o.slope)
  return min(max(e, t + o.min_s), t + o.max_s)
end

function M.build(onsets, ends, item_len, o)
  local regs, cur = {}, nil
  for i, t in ipairs(onsets) do
    if cur and t <= cur.e then
      if ends[i] > cur.e then cur.e = ends[i] end
      cur.last, cur.hits = t, cur.hits + 1
    else
      if cur then regs[#regs + 1] = cur end
      cur = { s = t - o.preroll_s, e = ends[i], first = t, last = t, hits = 1 }
    end
  end
  if cur then regs[#regs + 1] = cur end
  local merged = {}
  for _, r in ipairs(regs) do
    local p = merged[#merged]
    if p and r.s - p.e < o.merge_gap_s then
      if r.e > p.e then p.e = r.e end
      p.last, p.hits = r.last, p.hits + r.hits
    else
      merged[#merged + 1] = r
    end
  end
  local out = {}
  for _, r in ipairs(merged) do
    r.s, r.e = max(0, r.s), min(item_len, r.e)
    if r.e > r.s then
      local len, tail = r.e - r.s, max(0, r.e - r.last)
      local fo = o.fade_out_s
      if o.auto then fo = min(max(0.3 * tail, o.fade_out_s), 0.5) end
      r.fade_in = min(o.fade_in_s, len / 2)
      r.fade_out = min(fo, tail, len / 2)
      out[#out + 1] = r
    end
  end
  return out
end

return M
```

- [ ] **Step 4: Lancer, constater le succès**

Run: `sh tests/run.sh regions`
Expected: `10 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add Drums/tom_autocut/regions.lua tests/regions_test.lua
git commit -m "feat: add decay-driven regions with roll handling"
```

---

### Task 7: Réglages, presets, persistance pure, découpage d'items

**Files:**
- Create: `Drums/tom_autocut/settings.lua`, `Drums/tom_autocut/cuts.lua`
- Test: `tests/settings_test.lua`, `tests/cuts_test.lua`

**Interfaces:**
- Produces: `settings.DEFAULTS` (clés : `sensitivity_pct=50, floor_db=-30, length_mode="auto", preroll_ms=5, decay_depth_db=40, fixed_ms=300, min_ms=60, max_ms=2500, merge_gap_ms=120, fade_in_ms=2, fade_out_ms=30, xwindow_ms=3, margin_db=6, fft_base=2048, w_energy=0.6, w_arrival=0.25, w_sharp=0.15, show_rejected=false`) ; `settings.PRESETS` (`Studio`, `Live (bleed fort)`) ; `settings.copy(t)` ; `settings.merge(base, over)` ; `settings.serialize(t) -> string` ; `settings.deserialize(s) -> table` (complète avec DEFAULTS) ; `settings.is_tom_name(name) -> bool` ; `settings.parse_band(str) -> {lo,hi}|nil` ; `settings.serialize_selection(sel) -> string` ; `settings.parse_selection(str) -> sel|nil` (`sel[guid] = {role, checked}`).
- Produces: `cuts.plan(regions, item_len, eps) -> { {s, e, keep, fade_in?, fade_out?} }` couvrant `[0, len]` ; `cuts.item_to_src(t, startoffs, playrate) -> number`.

- [ ] **Step 1: Écrire les tests (en échec)**

`tests/settings_test.lua` :
```lua
local H = require("helpers")
local settings = require("tom_autocut.settings")
local T = {}

T["serialize / deserialize round-trip"] = function()
  local s = settings.copy(settings.DEFAULTS)
  s.sensitivity_pct, s.length_mode, s.show_rejected = 72.5, "fixed", true
  local back = settings.deserialize(settings.serialize(s))
  H.eq(back.sensitivity_pct, 72.5)
  H.eq(back.length_mode, "fixed")
  H.eq(back.show_rejected, true)
  H.eq(back.merge_gap_ms, 120)
end

T["deserialize ignores garbage and unknown keys"] = function()
  local s = settings.deserialize("foo=1;sensitivity_pct=abc;;merge_gap_ms=80")
  H.eq(s.foo, nil)
  H.eq(s.sensitivity_pct, 50)
  H.eq(s.merge_gap_ms, 80)
  H.eq(settings.deserialize("").floor_db, -30)
end

T["presets merge over defaults"] = function()
  local live = settings.merge(settings.DEFAULTS, settings.PRESETS["Live (bleed fort)"])
  H.eq(live.margin_db, 4)
  H.eq(live.preroll_ms, 5)
end

T["tom names"] = function()
  for _, n in ipairs({ "Tom 1", "TOM2", "Floor Tom", "FT", "ft 16", "Rack", "rack tom" }) do
    H.truthy(settings.is_tom_name(n), n)
  end
  for _, n in ipairs({ "Snare", "Left OH", "Soft synth", "Kick In", "" }) do
    H.truthy(not settings.is_tom_name(n), n)
  end
end

T["parse_band"] = function()
  local b = settings.parse_band("70-180")
  H.eq(b[1], 70); H.eq(b[2], 180)
  b = settings.parse_band(" 180 – 70 ")
  H.eq(b[1], 70); H.eq(b[2], 180)
  H.eq(settings.parse_band(""), nil)
  H.eq(settings.parse_band("abc"), nil)
end

T["selection round-trip"] = function()
  local sel = { ["{A-1}"] = { role = "tom", checked = true }, ["{B-2}"] = { role = "ref", checked = false } }
  local back = settings.parse_selection(settings.serialize_selection(sel))
  H.eq(back["{A-1}"].role, "tom"); H.eq(back["{A-1}"].checked, true)
  H.eq(back["{B-2}"].role, "ref"); H.eq(back["{B-2}"].checked, false)
  H.eq(settings.parse_selection(""), nil)
end

return T
```

`tests/cuts_test.lua` :
```lua
local H = require("helpers")
local cuts = require("tom_autocut.cuts")
local T = {}

local function check_cover(p, len)
  H.eq(p[1].s, 0)
  H.eq(p[#p].e, len)
  for k = 2, #p do H.eq(p[k].s, p[k - 1].e, "contiguous") end
end

T["regions alternate with muted gaps"] = function()
  local p = cuts.plan({ { s = 1, e = 2, fade_in = 0.002, fade_out = 0.03 }, { s = 3, e = 4 } }, 5)
  H.eq(#p, 5)
  check_cover(p, 5)
  H.eq(p[1].keep, false); H.eq(p[2].keep, true); H.eq(p[3].keep, false)
  H.eq(p[2].fade_out, 0.03)
end

T["no region gives one muted piece"] = function()
  local p = cuts.plan({}, 5)
  H.eq(#p, 1); H.eq(p[1].keep, false); check_cover(p, 5)
end

T["regions touching the edges"] = function()
  local p = cuts.plan({ { s = 0, e = 2 }, { s = 3, e = 5 } }, 5)
  H.eq(#p, 3); check_cover(p, 5)
  H.eq(p[1].keep, true); H.eq(p[3].keep, true)
end

T["tiny gaps are absorbed"] = function()
  local p = cuts.plan({ { s = 0.00005, e = 2 }, { s = 2.00001, e = 4.99995 } }, 5)
  H.eq(#p, 2); check_cover(p, 5)
end

T["item_to_src applies offset and playrate"] = function()
  H.near(cuts.item_to_src(1.5, 10, 2), 13, 1e-12)
  H.near(cuts.item_to_src(0, 0.25, 1), 0.25, 1e-12)
end

return T
```

- [ ] **Step 2: Lancer, constater l'échec**

Run: `sh tests/run.sh settings` puis `sh tests/run.sh cuts`
Expected: `LOAD FAIL` pour les deux.

- [ ] **Step 3: Implémenter `Drums/tom_autocut/settings.lua`**

```lua
-- @noindex
-- Defaults, presets and pure (de)serialization helpers.
local M = {}

M.DEFAULTS = {
  sensitivity_pct = 50, floor_db = -30,
  length_mode = "auto", preroll_ms = 5, decay_depth_db = 40, fixed_ms = 300,
  min_ms = 60, max_ms = 2500, merge_gap_ms = 120, fade_in_ms = 2, fade_out_ms = 30,
  xwindow_ms = 3, margin_db = 6,
  fft_base = 2048, w_energy = 0.6, w_arrival = 0.25, w_sharp = 0.15,
  show_rejected = false,
}

M.PRESETS = {
  ["Studio"] = {},
  ["Live (bleed fort)"] = { sensitivity_pct = 40, floor_db = -24, margin_db = 4, decay_depth_db = 35, merge_gap_ms = 80 },
}

function M.copy(t)
  local o = {}
  for k, v in pairs(t) do o[k] = v end
  return o
end

function M.merge(base, over)
  local o = M.copy(base)
  for k, v in pairs(over or {}) do o[k] = v end
  return o
end

function M.serialize(t)
  local keys = {}
  for k in pairs(M.DEFAULTS) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = t[k]
    if v == nil then v = M.DEFAULTS[k] end
    parts[#parts + 1] = k .. "=" .. tostring(v)
  end
  return table.concat(parts, ";")
end

function M.deserialize(s)
  local o = M.copy(M.DEFAULTS)
  for k, v in (s or ""):gmatch("([%w_]+)=([^;]*)") do
    local d = M.DEFAULTS[k]
    if type(d) == "number" then
      local n = tonumber(v)
      if n then o[k] = n end
    elseif type(d) == "boolean" then
      o[k] = v == "true"
    elseif type(d) == "string" then
      o[k] = v
    end
  end
  return o
end

function M.is_tom_name(name)
  local n = (name or ""):lower()
  return n:find("tom", 1, true) ~= nil
      or n:find("floor", 1, true) ~= nil
      or n:find("%f[%w]rack%f[%W]") ~= nil
      or n:find("%f[%w]ft%f[%W]") ~= nil
      or n:find("%f[%w]ft%d") ~= nil
end

function M.parse_band(str)
  local a, b = (str or ""):match("(%d+%.?%d*)%s*[^%d%.]+%s*(%d+%.?%d*)")
  a, b = tonumber(a), tonumber(b)
  if not a or not b or a == b then return nil end
  if a > b then a, b = b, a end
  return { a, b }
end

function M.serialize_selection(sel)
  local parts = {}
  for guid, v in pairs(sel) do
    parts[#parts + 1] = ("%s=%s,%d"):format(guid, v.role, v.checked and 1 or 0)
  end
  table.sort(parts)
  return table.concat(parts, ";")
end

function M.parse_selection(str)
  if not str or str == "" then return nil end
  local sel = {}
  for guid, role, chk in str:gmatch("([^=;]+)=(%a+),(%d)") do
    sel[guid] = { role = role, checked = chk == "1" }
  end
  return sel
end

return M
```

Note : `is_tom_name("Left OH")` est faux car `%f[%w]ft%f[%W]` exige que « ft » soit un mot entier ; « soft » ne matche pas non plus.

- [ ] **Step 4: Implémenter `Drums/tom_autocut/cuts.lua`**

```lua
-- @noindex
-- Pure item cutting plan: kept regions and out-of-region pieces covering [0, len].
local M = {}
local max, min = math.max, math.min

function M.plan(regs, len, eps)
  eps = eps or 1e-4
  local pieces, t = {}, 0
  for _, r in ipairs(regs) do
    local s, e = max(0, r.s), min(len, r.e)
    if e - s > eps and e > t then
      if s - t > eps then
        pieces[#pieces + 1] = { s = t, e = s, keep = false }
      else
        s = t
      end
      pieces[#pieces + 1] = { s = s, e = e, keep = true, fade_in = r.fade_in, fade_out = r.fade_out }
      t = e
    end
  end
  if len - t > eps then
    pieces[#pieces + 1] = { s = t, e = len, keep = false }
  elseif #pieces > 0 then
    pieces[#pieces].e = len
  end
  if #pieces == 0 then pieces[1] = { s = 0, e = len, keep = false } end
  return pieces
end

function M.item_to_src(t, startoffs, playrate)
  return startoffs + t * playrate
end

return M
```

- [ ] **Step 5: Lancer, constater le succès**

Run: `sh tests/run.sh`
Expected: tous les tests passent (`0 failed`).

- [ ] **Step 6: Commit**

```bash
git add Drums/tom_autocut/settings.lua Drums/tom_autocut/cuts.lua tests/settings_test.lua tests/cuts_test.lua
git commit -m "feat: add settings, presets, selection codec and cut planning"
```

---

### Task 8: Analyse (passes A/B) et recalcul léger (pipeline) — intégration

**Files:**
- Create: `Drums/tom_autocut/analysis.lua`, `Drums/tom_autocut/pipeline.lua`
- Test: `tests/analysis_test.lua`

**Interfaces:**
- Consumes: `envelope.*`, `features.*`, `bandtrack.*`, `attribution.attribute`, `regions.*`, `settings.DEFAULTS`.
- Item d'analyse (fourni par la couche REAPER ou les tests) : `{key, pos, len, sr, startoffs, playrate, reader(t0, n) -> mono table de n valeurs, close()?}`.
- Piste d'analyse : `{key, name, role="tom"|"ref", band_override={lo,hi}|nil, decay_override_s|nil, items={...}}`.
- Produces: `analysis.pass_a(item, settings, progress) -> cands` ; `analysis.pass_b(item, lo, hi, progress) -> band` ; `analysis.run(tracks, settings, yield) -> state {tracks}` (appelle `yield(fraction, label)`) ; `analysis.rerun_band(track, yield)`.
- Produces: `pipeline.options(settings)` ; `pipeline.recompute(state, settings)` qui renseigne `tr.model`, `tr.cands`, `c.band_e`, `c.score`, `c.status`, `it.hits`, `it.regions`, `tr.stats {hits, bleeds, rejected, regions, kept, total}`, `tr.decay_s`, `tr.decay_measured`, `tr.needs_band_pass`, `state.by_key[key] = tr`.

- [ ] **Step 1: Écrire les tests (en échec)**

`tests/analysis_test.lua` :
```lua
local H = require("helpers")
local S = require("synth")
local analysis = require("tom_autocut.analysis")
local pipeline = require("tom_autocut.pipeline")
local settings = require("tom_autocut.settings")
local SR = 44100
local T = {}

local function reader_for(buf)
  return function(t0, n)
    local out, i0 = {}, math.floor(t0 * SR + 0.5)
    for i = 1, n do out[i] = buf[i0 + i] or 0 end
    return out
  end
end

local function item(buf, pos)
  return { key = "it", pos = pos or 0, len = #buf / SR, sr = SR, startoffs = 0, playrate = 1, reader = reader_for(buf) }
end

-- Floor (80 Hz) and Tom 1 (140 Hz) bleeding into each other 2 ms late, 14 dB down;
-- Tom 1 plays a single hit then a 16th roll; a snare-like burst on the tom mic.
local function scenario(pos)
  local dur = 5.0
  local fl, tm = S.silence(SR, dur), S.silence(SR, dur)
  S.add_noise(fl, 2e-4, 1); S.add_noise(tm, 2e-4, 2)
  for _, t in ipairs({ 0.5, 2.0 }) do
    S.add_tom(fl, SR, t, { f0 = 80, amp = 0.8, decay = 1.0 })
    S.add_tom(tm, SR, t + 0.002, { f0 = 80, amp = 0.16, decay = 1.0 })
  end
  local hits = { 1.2 }
  for k = 0, 7 do hits[#hits + 1] = 3.0 + k * 0.0833 end
  for _, t in ipairs(hits) do
    S.add_tom(tm, SR, t, { f0 = 140, amp = 0.7, decay = 0.5 })
    S.add_tom(fl, SR, t + 0.002, { f0 = 140, amp = 0.14, decay = 0.5 })
  end
  S.add_noise_burst(tm, SR, 4.3, { amp = 0.3 })
  return {
    { key = "floor", name = "Floor", role = "tom", items = { item(fl, pos) } },
    { key = "tom", name = "Tom 1", role = "tom", items = { item(tm, pos) } },
  }
end

local function analyse(s, pos)
  local state = analysis.run(scenario(pos), s)
  pipeline.recompute(state, s)
  return state
end

T["full analysis: regions on the right tracks"] = function()
  local state = analyse(settings.DEFAULTS)
  local fl = state.tracks[1].items[1].regions
  local tm = state.tracks[2].items[1].regions
  H.eq(#fl, 2, "floor regions")
  H.eq(#tm, 2, "tom regions")
  H.near(fl[1].s, 0.495, 0.002)
  H.near(fl[2].s, 1.995, 0.002)
  H.near(tm[1].s, 1.195, 0.002)
  H.near(tm[2].s, 2.995, 0.002)
  H.truthy(tm[2].hits >= 6, "roll hits " .. tm[2].hits)
  H.truthy(tm[2].e > 3.0 + 7 * 0.0833, "roll end")
  H.truthy(state.tracks[2].stats.bleeds >= 2, "tom bleeds")
  H.truthy(state.tracks[1].stats.bleeds >= 1, "floor bleeds")
  H.eq(state.by_key["tom"], state.tracks[2])
end

T["loud floor hit region outlasts its decay target"] = function()
  local state = analyse(settings.DEFAULTS)
  local r = state.tracks[1].items[1].regions[1]
  -- 1.0 s to -60 dB => -60 dB/s; -40 dB below typical => ~0.67 s
  H.near(r.e - 0.5, 0.67, 0.12)
end

T["item position only shifts project times"] = function()
  local state = analyse(settings.DEFAULTS, 10.0)
  H.near(state.tracks[1].items[1].regions[1].s, 0.495, 0.002)
  H.near(state.tracks[1].cands[1].ptime - state.tracks[1].cands[1].time, 10.0, 1e-9)
end

T["fixed length mode"] = function()
  local s = settings.merge(settings.DEFAULTS, { length_mode = "fixed", fixed_ms = 200 })
  local r = analyse(s).tracks[1].items[1].regions[1]
  H.near(r.e - 0.5, 0.2, 0.003)
end

T["manual decay overrides the measured one"] = function()
  local state = analysis.run(scenario(), settings.DEFAULTS)
  state.tracks[1].decay_override_s = 0.2
  pipeline.recompute(state, settings.DEFAULTS)
  local r = state.tracks[1].items[1].regions[1]
  H.near(r.e - 0.5, 0.2, 0.05)
  H.near(state.tracks[1].decay_s, 0.2, 1e-9)
end

T["silent track: no candidates, default band, no region"] = function()
  local tracks = { { key = "s", name = "Silent", role = "tom", items = { item(S.silence(SR, 2.0)) } } }
  local state = analysis.run(tracks, settings.DEFAULTS)
  pipeline.recompute(state, settings.DEFAULTS)
  local tr = state.tracks[1]
  H.eq(#tr.cands, 0)
  H.truthy(not tr.model.ok)
  H.eq(#tr.items[1].regions, 0)
end

T["yield reports monotonic progress up to 1"] = function()
  local last = 0
  analysis.run(scenario(), settings.DEFAULTS, function(f)
    H.truthy(f >= last - 1e-9 and f <= 1 + 1e-9, "progress " .. f)
    last = f
  end)
  H.near(last, 1, 1e-6)
end

return T
```

- [ ] **Step 2: Lancer, constater l'échec**

Run: `sh tests/run.sh analysis`
Expected: `LOAD FAIL analysis_test`.

- [ ] **Step 3: Implémenter `Drums/tom_autocut/analysis.lua`**

```lua
-- @noindex
-- Heavy analysis: pass A (onsets + features) and pass B (band envelope). Pure Lua:
-- audio comes from item.reader(t0, n).
local envelope = require("tom_autocut.envelope")
local features = require("tom_autocut.features")
local bandtrack = require("tom_autocut.bandtrack")
local M = {}
M.BLOCK = 65536
local floor, max, min = math.floor, math.max, math.min
local function noop() end

local function stream(it, sink, progress)
  local total = floor(it.len * it.sr)
  local done = 0
  while done < total do
    local n = min(M.BLOCK, total - done)
    sink:push(it.reader(done / it.sr, n), n)
    done = done + n
    progress(done / total)
  end
end

function M.pass_a(it, settings, progress)
  progress = progress or noop
  local framer = envelope.new_framer(it.sr, 0.001)
  stream(it, framer, progress)
  local fast, slow = envelope.envelopes(framer:finish(), framer.frame_rate)
  local cands = envelope.pick_candidates(envelope.onset_function(fast, slow), fast, framer.frame_rate)
  local top = -math.huge
  for _, c in ipairs(cands) do top = max(top, c.peak_db) end
  local n_fft = features.fft_size(it.sr, settings.fft_base)
  local out = {}
  for k, c in ipairs(cands) do
    if c.peak_db >= top - 45 then
      local w0 = max(0, c.time - 0.004)
      c.time = envelope.refine_onset(it.reader(w0, floor(0.010 * it.sr)), it.sr, w0)
      c.feat = features.extract(it.reader(c.time, n_fft), it.sr, n_fft)
      c.ptime = it.pos + c.time
      out[#out + 1] = c
    end
    if k % 64 == 0 then progress(1) end
  end
  return out
end

function M.pass_b(it, lo, hi, progress)
  local tk = bandtrack.new(it.sr, lo, hi, 0.010)
  stream(it, tk, progress or noop)
  return tk:finish()
end

local function close(it) if it.close then it.close() end end

function M.run(tracks, settings, yield)
  yield = yield or noop
  local total, done = 0, 0
  for _, tr in ipairs(tracks) do
    for _, it in ipairs(tr.items) do total = total + it.len * (tr.role == "tom" and 2 or 1) end
  end
  total = max(total, 1e-9)
  for _, tr in ipairs(tracks) do
    local all = {}
    for _, it in ipairs(tr.items) do
      it.cands = M.pass_a(it, settings, function(f) yield(min(1, (done + f * it.len) / total), tr.name) end)
      done = done + it.len
      close(it)
      for _, c in ipairs(it.cands) do all[#all + 1] = c end
    end
    if tr.role == "tom" then
      local model = features.learn_track(all, { band = tr.band_override })
      for _, it in ipairs(tr.items) do
        it.band = M.pass_b(it, model.band_lo, model.band_hi,
          function(f) yield(min(1, (done + f * it.len) / total), tr.name) end)
        done = done + it.len
        close(it)
      end
    end
  end
  yield(1, "")
  return { tracks = tracks }
end

function M.rerun_band(tr, yield)
  yield = yield or noop
  local total, done = 0, 0
  for _, it in ipairs(tr.items) do total = total + it.len end
  total = max(total, 1e-9)
  for _, it in ipairs(tr.items) do
    it.band = M.pass_b(it, tr.model.band_lo, tr.model.band_hi,
      function(f) yield(min(1, (done + f * it.len) / total), tr.name) end)
    done = done + it.len
    close(it)
  end
end

return M
```

- [ ] **Step 4: Implémenter `Drums/tom_autocut/pipeline.lua`**

```lua
-- @noindex
-- Light stage, recomputed on every settings change: scores -> attribution -> decay -> regions.
local features = require("tom_autocut.features")
local attribution = require("tom_autocut.attribution")
local regions = require("tom_autocut.regions")
local M = {}
local max, min = math.max, math.min

function M.options(s)
  return {
    threshold = 1 - s.sensitivity_pct / 100,
    floor_db = s.floor_db,
    window_s = s.xwindow_ms / 1000,
    margin_db = s.margin_db,
    weights = { energy = s.w_energy, arrival = s.w_arrival, sharp = s.w_sharp },
  }
end

local function build_track(tr, s, st)
  local entries, needs = {}, false
  for _, it in ipairs(tr.items) do
    it.hits = {}
    for _, c in ipairs(it.cands or {}) do
      if c.status == "hit" then
        it.hits[#it.hits + 1] = c.time
        st.hits = st.hits + 1
      elseif c.status == "bleed" then
        st.bleeds = st.bleeds + 1
      elseif c.status == "rejected" then
        st.rejected = st.rejected + 1
      end
    end
    table.sort(it.hits)
    if it.band then
      if it.band.lo ~= tr.model.band_lo or it.band.hi ~= tr.model.band_hi then needs = true end
      entries[#entries + 1] = { onsets = it.hits, env_db = it.band.env_db, fr = it.band.fr, noise_db = it.band.noise_db }
    end
  end
  tr.needs_band_pass = needs

  local dm = regions.decay_model(entries)
  local depth = s.decay_depth_db
  local override = tr.decay_override_s and tr.decay_override_s > 0
  local slope = override and (-depth / tr.decay_override_s) or (dm.slope_db_s or regions.DEFAULT_SLOPE_DB_S)
  tr.decay_s = depth / -slope
  tr.decay_measured = (not override) and dm.slope_db_s ~= nil

  local auto = s.length_mode == "auto"
  local min_s, max_s = s.min_ms / 1000, s.max_ms / 1000
  local bopts = { preroll_s = s.preroll_ms / 1000, merge_gap_s = s.merge_gap_ms / 1000,
                  fade_in_s = s.fade_in_ms / 1000, fade_out_s = s.fade_out_ms / 1000, auto = auto }
  for _, it in ipairs(tr.items) do
    local ends = {}
    for k, t in ipairs(it.hits) do
      if not auto then
        ends[k] = t + s.fixed_ms / 1000
      elseif it.band and dm.typical_peak_db then
        local o = { target_db = dm.typical_peak_db - depth, noise_db = it.band.noise_db,
                    slope = slope, min_s = min_s, max_s = max_s }
        if override then
          ends[k] = regions.model_end(it.band.env_db, it.band.fr, t, o)
        else
          ends[k] = regions.hit_end(it.band.env_db, it.band.fr, t, o)
        end
      else
        ends[k] = t + min(max(tr.decay_s, min_s), max_s)
      end
    end
    it.regions = regions.build(it.hits, ends, it.len, bopts)
    st.regions = st.regions + #it.regions
    st.total = st.total + it.len
    for _, r in ipairs(it.regions) do st.kept = st.kept + (r.e - r.s) end
  end
end

function M.recompute(state, s)
  local o = M.options(s)
  state.by_key = {}
  for _, tr in ipairs(state.tracks) do
    state.by_key[tr.key] = tr
    local all = {}
    for _, it in ipairs(tr.items) do
      for _, c in ipairs(it.cands or {}) do all[#all + 1] = c end
    end
    tr.model = features.learn_track(all, { band = tr.band_override })
    for _, c in ipairs(all) do
      c.band_e = features.band_energy(c.feat, tr.model.band_lo, tr.model.band_hi)
      c.score = features.score(c, tr.model, o.floor_db)
    end
    tr.cands = all
  end
  attribution.attribute(state.tracks, o)
  for _, tr in ipairs(state.tracks) do
    tr.stats = { hits = 0, bleeds = 0, rejected = 0, regions = 0, kept = 0, total = 0 }
    if tr.role == "tom" then build_track(tr, s, tr.stats) end
  end
end

return M
```

Note : dans le test « manual decay », `0,2 s` d'override donne une pente de −200 dB/s ; la cible est `typical − 40` et le coup est le plus fort de la piste, donc `model_end ≈ t + 40/200 = t + 0,2`.

- [ ] **Step 5: Lancer, constater le succès**

Run: `sh tests/run.sh`
Expected: tous les tests passent. En cas d'échec d'un test d'intégration, imprimer `c.time`, `c.status`, `c.score`, `c.dominance` des candidats de chaque piste (`for _, c in ipairs(state.tracks[i].cands) do print(...) end`) pour localiser l'étage fautif, corriger dans le module concerné et ajouter un test unitaire qui reproduit le cas avant le correctif.

- [ ] **Step 6: Commit**

```bash
git add Drums/tom_autocut/analysis.lua Drums/tom_autocut/pipeline.lua tests/analysis_test.lua
git commit -m "feat: add analysis passes and light recompute pipeline"
```

---

### Task 9: Couche REAPER — audio, projet, preview, application des coupes

**Files:**
- Create: `Drums/tom_autocut/audio.lua`, `Drums/tom_autocut/project.lua`, `Drums/tom_autocut/preview.lua`, `Drums/tom_autocut/apply.lua`
- Test: `tests/audio_test.lua` (partie pure)

**Interfaces:**
- Consumes: `cuts.plan`, `cuts.item_to_src`, `settings.*`.
- Produces: `audio.mix_to_mono(t, n, nch)` (pur) ; `audio.item_reader(take, sr, nch) -> read, close` (accessor ouvert à la demande) ; `audio.fingerprint(item) -> string` ; `audio.item_info(item) -> info|nil, reason` (`info = {item, take, key, pos, len, startoffs, playrate, sr, nch, fingerprint, reader, close}` ; reasons `"empty"|"midi"|"locked"`).
- Produces: `project.SECTION`, `project.TAG`, `project.TAG_COLOR`, `project.get_tag(item)`, `project.set_tag(item, v)`, `project.list_tracks() -> rows {track, guid, name, level, is_folder, rgb}`, `project.load_selection() -> sel|nil`, `project.save_selection(sel)`, `project.get_overrides(track) -> band|nil, decay|nil`, `project.set_overrides(track, band, decay)`, `project.load_settings()`, `project.save_settings(t)`, `project.preset_names() -> list`, `project.load_preset(name) -> settings`, `project.save_preset(name, t)`, `project.build_sources(rows) -> tracks` (rows `{track, guid, name, role}` ; ajoute `tr.track`, `tr.processed`, `tr.skipped`), `project.close_sources(tracks)`.
- Produces: `preview.PREFIX = "GD·"`, `preview.clear_take(take)`, `preview.clear_all()`, `preview.draw(state, settings)`.
- Produces: `apply.disable_ripple() -> restore_fn`, `apply.apply(state, mode) -> {tracks, items, regions, stale}` (`mode = "mute"|"delete"`), `apply.find_muted(tracks|nil) -> { {track, item} }`, `apply.clean(tracks|nil) -> count`, `apply.clean_interactive(tracks|nil) -> count`, `apply.reset(tracks) -> count`.

- [ ] **Step 1: Écrire le test pur (en échec)**

`tests/audio_test.lua` :
```lua
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
```

- [ ] **Step 2: Lancer, constater l'échec**

Run: `sh tests/run.sh audio`
Expected: `LOAD FAIL audio_test`.

- [ ] **Step 3: Implémenter `Drums/tom_autocut/audio.lua`**

```lua
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

function M.item_reader(take, sr, nch)
  local acc, buf, cap, t_start = nil, nil, 0, 0
  local function read(t0, n)
    if n <= 0 then return {} end
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
  local function close()
    if acc then
      reaper.DestroyAudioAccessor(acc)
      acc = nil
    end
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
  info.reader, info.close = M.item_reader(take, sr, nch)
  return info
end

return M
```

- [ ] **Step 4: Lancer le test pur**

Run: `sh tests/run.sh audio`
Expected: `3 passed, 0 failed`.

- [ ] **Step 5: Implémenter `Drums/tom_autocut/project.lua`**

```lua
-- @noindex
-- Project-side helpers: track list, persistence, tags, analysis sources.
local settings = require("tom_autocut.settings")
local audio = require("tom_autocut.audio")
local M = {}

M.SECTION = "GD_TomAutoCut"
M.TAG = "P_EXT:GD_TOMCUT"
M.TAG_COLOR = "P_EXT:GD_TOMCUT_COL"
local BAND_KEY, DECAY_KEY = "P_EXT:GD_TOMCUT_BAND", "P_EXT:GD_TOMCUT_DECAY"

function M.get_tag(item)
  local _, v = reaper.GetSetMediaItemInfo_String(item, M.TAG, "", false)
  return v or ""
end

function M.set_tag(item, v)
  reaper.GetSetMediaItemInfo_String(item, M.TAG, v, true)
end

function M.list_tracks()
  local rows, level = {}, 0
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, name = reaper.GetTrackName(tr)
    local fd = math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH"))
    local col = math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR"))
    local rgb
    if col & 0x1000000 ~= 0 then
      local r, g, b = reaper.ColorFromNative(col & 0xFFFFFF)
      rgb = (r << 16) | (g << 8) | b
    end
    rows[#rows + 1] = { track = tr, guid = reaper.GetTrackGUID(tr), name = name, level = level,
                        is_folder = fd == 1, rgb = rgb }
    level = math.max(0, level + fd)
  end
  return rows
end

function M.load_selection()
  local ok, s = reaper.GetProjExtState(0, M.SECTION, "tracks")
  if ok == 0 then return nil end
  return settings.parse_selection(s)
end

function M.save_selection(sel)
  reaper.SetProjExtState(0, M.SECTION, "tracks", settings.serialize_selection(sel))
end

function M.get_overrides(track)
  local _, b = reaper.GetSetMediaTrackInfo_String(track, BAND_KEY, "", false)
  local _, d = reaper.GetSetMediaTrackInfo_String(track, DECAY_KEY, "", false)
  return settings.parse_band(b), tonumber(d)
end

function M.set_overrides(track, band, decay_s)
  reaper.GetSetMediaTrackInfo_String(track, BAND_KEY, band and ("%g-%g"):format(band[1], band[2]) or "", true)
  reaper.GetSetMediaTrackInfo_String(track, DECAY_KEY, decay_s and ("%g"):format(decay_s) or "", true)
end

function M.load_settings()
  return settings.deserialize(reaper.GetExtState(M.SECTION, "settings"))
end

function M.save_settings(t)
  reaper.SetExtState(M.SECTION, "settings", settings.serialize(t), true)
end

local function user_preset_names()
  local s, out = reaper.GetExtState(M.SECTION, "presets"), {}
  for name in s:gmatch("[^|]+") do out[#out + 1] = name end
  return out
end

function M.preset_names()
  local out = { "Studio", "Live (bleed fort)" }
  for _, n in ipairs(user_preset_names()) do
    if not settings.PRESETS[n] then out[#out + 1] = n end
  end
  return out
end

function M.load_preset(name)
  if settings.PRESETS[name] then return settings.merge(settings.DEFAULTS, settings.PRESETS[name]) end
  return settings.deserialize(reaper.GetExtState(M.SECTION, "preset:" .. name))
end

function M.save_preset(name, t)
  name = name:gsub("|", "/")
  reaper.SetExtState(M.SECTION, "preset:" .. name, settings.serialize(t), true)
  local names = user_preset_names()
  for _, n in ipairs(names) do if n == name then return end end
  names[#names + 1] = name
  reaper.SetExtState(M.SECTION, "presets", table.concat(names, "|"), true)
end

function M.build_sources(rows)
  local tracks = {}
  for _, r in ipairs(rows) do
    local band, decay = M.get_overrides(r.track)
    local tr = { key = r.guid, name = r.name, role = r.role, track = r.track,
                 band_override = band, decay_override_s = decay,
                 items = {}, processed = false, skipped = 0 }
    for i = 0, reaper.CountTrackMediaItems(r.track) - 1 do
      local item = reaper.GetTrackMediaItem(r.track, i)
      local tag = M.get_tag(item)
      if tag ~= "" then tr.processed = true end
      if tag ~= "muted" then
        local info = audio.item_info(item)
        if info then
          tr.items[#tr.items + 1] = info
        else
          tr.skipped = tr.skipped + 1
        end
      end
    end
    tracks[#tracks + 1] = tr
  end
  return tracks
end

function M.close_sources(tracks)
  for _, tr in ipairs(tracks or {}) do
    for _, it in ipairs(tr.items) do if it.close then it.close() end end
  end
end

return M
```

- [ ] **Step 6: Implémenter `Drums/tom_autocut/preview.lua`**

```lua
-- @noindex
-- Preview as take markers prefixed "GD·" on analysed items.
local cuts = require("tom_autocut.cuts")
local M = {}
M.PREFIX = "GD·"

local function col(r, g, b) return reaper.ColorToNative(r, g, b) | 0x1000000 end

function M.clear_take(take)
  for i = reaper.GetNumTakeMarkers(take) - 1, 0, -1 do
    local _, name = reaper.GetTakeMarker(take, i)
    if name:sub(1, #M.PREFIX) == M.PREFIX then reaper.DeleteTakeMarker(take, i) end
  end
end

function M.clear_all()
  reaper.PreventUIRefresh(1)
  for i = 0, reaper.CountMediaItems(0) - 1 do
    local item = reaper.GetMediaItem(0, i)
    for t = 0, reaper.CountTakes(item) - 1 do
      local take = reaper.GetTake(item, t)
      if take then M.clear_take(take) end
    end
  end
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
end

function M.draw(state, settings)
  local GREEN, ORANGE, GREY, WHITE = col(60, 200, 90), col(240, 150, 40), col(130, 130, 130), col(235, 235, 235)
  reaper.PreventUIRefresh(1)
  for _, tr in ipairs(state.tracks) do
    if tr.role == "tom" then
      for _, it in ipairs(tr.items) do
        if reaper.ValidatePtr2(0, it.take, "MediaItem_Take*") then
          M.clear_take(it.take)
          local function mark(t, name, color)
            reaper.SetTakeMarker(it.take, -1, M.PREFIX .. name, cuts.item_to_src(t, it.startoffs, it.playrate), color)
          end
          for _, c in ipairs(it.cands or {}) do
            if c.status == "hit" then
              mark(c.time, "hit", GREEN)
            elseif c.status == "bleed" then
              mark(c.time, "bleed ← " .. (c.bleed_from or "?"), ORANGE)
            elseif c.status == "rejected" and settings.show_rejected then
              mark(c.time, "rej", GREY)
            end
          end
          for _, r in ipairs(it.regions or {}) do
            mark(r.s, "[", WHITE)
            mark(r.e, "]", WHITE)
          end
        end
      end
    end
  end
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
end

return M
```

- [ ] **Step 7: Implémenter `Drums/tom_autocut/apply.lua`**

```lua
-- @noindex
-- Apply cuts (mute / delete), clean muted pieces, reset processed tracks.
local audio = require("tom_autocut.audio")
local cuts = require("tom_autocut.cuts")
local project = require("tom_autocut.project")
local M = {}

local TITLE = "GD Tom auto-cut"
local RIPPLE_OFF, RIPPLE_TRACK, RIPPLE_ALL = 40309, 40310, 40311
local UNSELECT_ALL_ITEMS, HEAL_SPLITS = 40289, 40548

function M.disable_ripple()
  local prev
  if reaper.GetToggleCommandState(RIPPLE_TRACK) == 1 then
    prev = RIPPLE_TRACK
  elseif reaper.GetToggleCommandState(RIPPLE_ALL) == 1 then
    prev = RIPPLE_ALL
  end
  if prev then reaper.Main_OnCommand(RIPPLE_OFF, 0) end
  return function() if prev then reaper.Main_OnCommand(prev, 0) end end
end

local function dimmed(native)
  local r, g, b = reaper.ColorFromNative(native & 0xFFFFFF)
  return reaper.ColorToNative(math.floor(r * 0.35), math.floor(g * 0.35), math.floor(b * 0.35)) | 0x1000000
end

local function snapshot(item)
  local o = {
    fadein = reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN"),
    fadeout = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN"),
    color = math.floor(reaper.GetMediaItemInfo_Value(item, "I_CUSTOMCOLOR")),
    takes = {},
  }
  for t = 0, reaper.CountTakes(item) - 1 do
    local take = reaper.GetTake(item, t)
    if take then
      o.takes[t] = { reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"),
                     reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") }
    end
  end
  return o
end

-- Rewrite geometry so the result does not depend on "auto-crossfade on split".
local function set_geometry(o, p, it, orig)
  reaper.SetMediaItemInfo_Value(o, "D_POSITION", it.pos + p.s)
  reaper.SetMediaItemInfo_Value(o, "D_LENGTH", p.e - p.s)
  for t = 0, reaper.CountTakes(o) - 1 do
    local take, g = reaper.GetTake(o, t), orig.takes[t]
    if take and g then
      reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", cuts.item_to_src(p.s, g[1], g[2]))
    end
  end
end

local function apply_item(it, mode)
  local item = it.item
  local track = reaper.GetMediaItem_Track(item)
  local pieces = cuts.plan(it.regions or {}, it.len)
  local orig = snapshot(item)
  local fallback = reaper.GetTrackColor(track)
  if fallback == 0 then fallback = reaper.ColorToNative(70, 70, 70) | 0x1000000 end
  local objs = { item }
  for k = #pieces, 2, -1 do objs[k] = reaper.SplitMediaItem(item, it.pos + pieces[k].s) end
  local n = #pieces
  for k = 1, n do
    local o, p = objs[k], pieces[k]
    if o then
      set_geometry(o, p, it, orig)
      reaper.SetMediaItemInfo_Value(o, "D_FADEINLEN", k == 1 and orig.fadein or (p.keep and p.fade_in or 0))
      reaper.SetMediaItemInfo_Value(o, "D_FADEOUTLEN", k == n and orig.fadeout or (p.keep and p.fade_out or 0))
      reaper.SetMediaItemInfo_Value(o, "D_FADEINLEN_AUTO", 0)
      reaper.SetMediaItemInfo_Value(o, "D_FADEOUTLEN_AUTO", 0)
      reaper.GetSetMediaItemInfo_String(o, project.TAG_COLOR, tostring(orig.color), true)
      if p.keep then
        project.set_tag(o, "kept")
        reaper.SetMediaItemInfo_Value(o, "I_CUSTOMCOLOR", orig.color)
      elseif mode == "delete" then
        reaper.DeleteTrackMediaItem(track, o)
      else
        project.set_tag(o, "muted")
        reaper.SetMediaItemInfo_Value(o, "B_MUTE", 1)
        reaper.SetMediaItemInfo_Value(o, "I_CUSTOMCOLOR", dimmed(orig.color ~= 0 and orig.color or fallback))
      end
    end
  end
end

function M.apply(state, mode)
  local res = { tracks = 0, items = 0, regions = 0, stale = 0 }
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  local restore = (mode == "delete") and M.disable_ripple() or function() end
  for _, tr in ipairs(state.tracks) do
    if tr.role == "tom" then
      res.tracks = res.tracks + 1
      for _, it in ipairs(tr.items) do
        if reaper.ValidatePtr2(0, it.item, "MediaItem*") and audio.fingerprint(it.item) == it.fingerprint then
          apply_item(it, mode)
          res.items = res.items + 1
          res.regions = res.regions + #(it.regions or {})
        else
          it.stale = true
          res.stale = res.stale + 1
        end
      end
    end
  end
  restore()
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock(("GD Tom auto-cut : %s (%d pistes, %d régions)"):format(
    mode == "delete" and "Delete" or "Mute", res.tracks, res.regions), -1)
  return res
end

local function each_track(tracks)
  if tracks then return ipairs(tracks) end
  local all = {}
  for i = 0, reaper.CountTracks(0) - 1 do all[#all + 1] = reaper.GetTrack(0, i) end
  return ipairs(all)
end

function M.find_muted(tracks)
  local out = {}
  for _, track in each_track(tracks) do
    for i = 0, reaper.CountTrackMediaItems(track) - 1 do
      local item = reaper.GetTrackMediaItem(track, i)
      if project.get_tag(item) == "muted" and reaper.GetMediaItemInfo_Value(item, "B_MUTE") == 1 then
        out[#out + 1] = { track = track, item = item }
      end
    end
  end
  return out
end

function M.clean(tracks)
  local list = M.find_muted(tracks)
  if #list == 0 then return 0 end
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  local restore = M.disable_ripple()
  for _, e in ipairs(list) do reaper.DeleteTrackMediaItem(e.track, e.item) end
  restore()
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock(("GD Tom auto-cut : Clean (%d items)"):format(#list), -1)
  return #list
end

function M.clean_interactive(tracks)
  local scope = nil
  if tracks and #tracks > 0 then
    local r = reaper.MB("Supprimer les morceaux muets créés par Tom auto-cut :\n\n"
      .. "Oui = pistes cochées uniquement\nNon = tout le projet", TITLE .. " : Clean muted", 3)
    if r == 2 then return 0 end
    if r == 6 then scope = tracks end
  end
  local list = M.find_muted(scope)
  if #list == 0 then
    reaper.MB("Aucun morceau muet tagué trouvé.", TITLE, 0)
    return 0
  end
  if reaper.MB(("%d items muets vont être supprimés. Continuer ?"):format(#list), TITLE, 1) ~= 1 then return 0 end
  return M.clean(scope)
end

function M.reset(tracks)
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  local saved = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do saved[#saved + 1] = reaper.GetSelectedMediaItem(0, i) end
  reaper.Main_OnCommand(UNSELECT_ALL_ITEMS, 0)
  local n = 0
  for _, track in ipairs(tracks) do
    for i = 0, reaper.CountTrackMediaItems(track) - 1 do
      local item = reaper.GetTrackMediaItem(track, i)
      if project.get_tag(item) ~= "" then
        reaper.SetMediaItemInfo_Value(item, "B_MUTE", 0)
        local _, c = reaper.GetSetMediaItemInfo_String(item, project.TAG_COLOR, "", false)
        if tonumber(c) then reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", tonumber(c)) end
        reaper.SetMediaItemSelected(item, true)
        n = n + 1
      end
    end
  end
  reaper.Main_OnCommand(HEAL_SPLITS, 0)
  for _, track in ipairs(tracks) do
    for i = 0, reaper.CountTrackMediaItems(track) - 1 do
      local item = reaper.GetTrackMediaItem(track, i)
      project.set_tag(item, "")
      reaper.GetSetMediaItemInfo_String(item, project.TAG_COLOR, "", true)
    end
  end
  reaper.Main_OnCommand(UNSELECT_ALL_ITEMS, 0)
  for _, item in ipairs(saved) do
    if reaper.ValidatePtr2(0, item, "MediaItem*") then reaper.SetMediaItemSelected(item, true) end
  end
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock(("GD Tom auto-cut : Reset (%d items)"):format(n), -1)
  return n
end

return M
```

- [ ] **Step 8: Vérifier que les modules REAPER se chargent sans `reaper`**

Run: `sh tests/run.sh` puis
`/usr/local/opt/lua@5.4/bin/lua5.4 -e 'package.path="./Drums/?.lua;"..package.path; for _,m in ipairs{"audio","project","preview","apply"} do require("tom_autocut."..m) end print("load ok")'`
Expected: tous les tests passent ; `load ok` (aucun appel `reaper.*` au chargement).

- [ ] **Step 9: Commit**

```bash
git add Drums/tom_autocut/audio.lua Drums/tom_autocut/project.lua Drums/tom_autocut/preview.lua Drums/tom_autocut/apply.lua tests/audio_test.lua
git commit -m "feat: add REAPER layer for audio, project state, preview and cuts"
```

---

### Task 10: Fenêtre ReaImGui et points d'entrée

**Files:**
- Create: `Drums/tom_autocut/ui.lua`, `Drums/GD_Tom auto-cut.lua`, `Drums/GD_Tom auto-cut - Clean muted.lua`

**Interfaces:**
- Consumes: tout ce qui précède. ImGui ≥ 0.9 : `CreateContext`, `Begin/End`, `BeginTable/TableSetupColumn/TableSetupScrollFreeze/TableHeadersRow/TableNextRow/TableNextColumn/EndTable`, `Checkbox`, `Combo`, `InputTextWithHint`, `SliderDouble`, `Button`, `SmallButton`, `ColorButton`, `ProgressBar`, `BeginTabBar/BeginTabItem/EndTabItem/EndTabBar`, `SeparatorText`, `BeginDisabled/EndDisabled`, `BeginCombo/Selectable/EndCombo`, `IsItemDeactivatedAfterEdit`, `IsItemHovered`, `SetTooltip`, `TextWrapped`, `Dummy`, `SameLine`, `PushID/PopID`, `SetNextItemWidth`, `SetNextWindowSize`.
- Produces: `ui.run(ImGui)`.

- [ ] **Step 1: Implémenter `Drums/tom_autocut/ui.lua`**

```lua
-- @noindex
-- ReaImGui window: track list, analysis job, settings, preview, apply.
local settings_mod = require("tom_autocut.settings")
local project = require("tom_autocut.project")
local analysis = require("tom_autocut.analysis")
local pipeline = require("tom_autocut.pipeline")
local preview = require("tom_autocut.preview")
local apply = require("tom_autocut.apply")

local M = {}
local TITLE = "GD Tom auto-cut"
local ROLES = { [0] = "tom", [1] = "ref", [2] = "ignore" }
local ROLE_INDEX = { tom = 0, ref = 1, ignore = 2 }

function M.run(ImGui)
  local ctx = ImGui.CreateContext(TITLE)
  local stored = project.load_selection()
  local S = {
    settings = project.load_settings(),
    sel = stored or {}, first_open = stored == nil,
    rows = {}, change_count = -1, filter = "", collapsed = {},
    state = nil, job = nil, job_kind = nil, job_tracks = nil, progress = 0, label = "",
    preview_dirty = false, last_edit = 0, message = "",
    preset_label = nil, preset_name = "", edits = {}, closed = false,
  }
  preview.clear_all()

  local function now() return reaper.time_precise() end

  local function refresh_rows()
    local cc = reaper.GetProjectStateChangeCount(0)
    if cc == S.change_count then return end
    S.change_count = cc
    S.rows = project.list_tracks()
    for _, r in ipairs(S.rows) do
      if not S.sel[r.guid] then
        S.sel[r.guid] = { role = "tom", checked = S.first_open and settings_mod.is_tom_name(r.name) }
      end
    end
    if S.first_open then
      S.first_open = false
      project.save_selection(S.sel)
    end
  end

  local function checked_rows(only_toms)
    local out = {}
    for _, r in ipairs(S.rows) do
      local s = S.sel[r.guid]
      if s and s.checked and s.role ~= "ignore" and (not only_toms or s.role == "tom") then
        out[#out + 1] = { track = r.track, guid = r.guid, name = r.name, role = s.role }
      end
    end
    return out
  end

  local function checked_tom_tracks()
    local out = {}
    for _, r in ipairs(checked_rows(true)) do out[#out + 1] = r.track end
    return out
  end

  local function mark_changed()
    if S.state then
      pipeline.recompute(S.state, S.settings)
      S.preview_dirty = true
    end
    S.last_edit = now()
  end

  local function start_job(kind, tracks, fn)
    S.job_kind, S.job_tracks, S.progress, S.label = kind, tracks, 0, ""
    S.job = coroutine.create(fn)
  end

  local function start_analysis()
    local rows = checked_rows(false)
    if #rows == 0 then
      S.message = "Cochez au moins une piste (rôle Tom ou Référence)."
      return
    end
    preview.clear_all()
    S.state, S.message = nil, ""
    local tracks = project.build_sources(rows)
    start_job("full", tracks, function() return analysis.run(tracks, S.settings, coroutine.yield) end)
  end

  local function start_band_job(tr)
    start_job("band", { tr }, function()
      analysis.rerun_band(tr, coroutine.yield)
      return S.state
    end)
  end

  local function cancel_job()
    project.close_sources(S.job_tracks)
    if S.job_kind == "full" then S.state = nil end
    S.job, S.message = nil, "Analyse annulée."
  end

  local function step_job()
    local deadline = now() + 0.025
    while S.job and now() < deadline do
      local ok, a, b = coroutine.resume(S.job)
      if not ok then
        project.close_sources(S.job_tracks)
        S.job, S.state = nil, nil
        S.message = "Erreur pendant l'analyse : " .. tostring(a)
      elseif coroutine.status(S.job) == "dead" then
        project.close_sources(S.job_tracks)
        S.job = nil
        S.state = a
        pipeline.recompute(S.state, S.settings)
        S.preview_dirty, S.last_edit = true, 0
      else
        S.progress, S.label = a or S.progress, b or S.label
      end
    end
  end

  local function commit_overrides(r, e)
    local band = settings_mod.parse_band(e.band)
    local decay = tonumber((e.decay:gsub(",", ".")))
    if decay and decay <= 0 then decay = nil end
    project.set_overrides(r.track, band, decay)
    local tr = S.state and S.state.by_key[r.guid]
    if tr then
      tr.band_override, tr.decay_override_s = band, decay
      mark_changed()
      if tr.needs_band_pass and not S.job then start_band_job(tr) end
    end
  end

  local function edit_buffers(r)
    local e = S.edits[r.guid]
    if not e then
      local band, decay = project.get_overrides(r.track)
      e = { band = band and ("%g-%g"):format(band[1], band[2]) or "", decay = decay and ("%g"):format(decay) or "" }
      S.edits[r.guid] = e
    end
    return e
  end

  local function status_text(st)
    if not st then return "" end
    local parts = {}
    if st.role == "ref" then
      parts[1] = ("%d événements (référence)"):format(#(st.cands or {}))
    elseif st.stats then
      local s = st.stats
      parts[1] = ("%d coups · %d repisses · %d régions · %.0f %% conservé"):format(
        s.hits, s.bleeds, s.regions, s.total > 0 and 100 * s.kept / s.total or 0)
    end
    if st.skipped and st.skipped > 0 then parts[#parts + 1] = ("%d items ignorés"):format(st.skipped) end
    if st.processed then parts[#parts + 1] = "déjà traitée : Reset conseillé" end
    if st.model and not st.model.ok and not st.model.manual then parts[#parts + 1] = "bande par défaut (peu de coups)" end
    if st.needs_band_pass then parts[#parts + 1] = "bande modifiée : réanalyse…" end
    local stale = 0
    for _, it in ipairs(st.items or {}) do if it.stale then stale = stale + 1 end end
    if stale > 0 then parts[#parts + 1] = ("%d items à réanalyser"):format(stale) end
    return table.concat(parts, " · ")
  end

  local function visible_rows()
    local out, hide_below = {}, nil
    local f = S.filter:lower()
    for _, r in ipairs(S.rows) do
      if not (hide_below and r.level > hide_below) then
        hide_below = nil
        if f == "" or r.name:lower():find(f, 1, true) then out[#out + 1] = r end
        if r.is_folder and S.collapsed[r.guid] then hide_below = r.level end
      end
    end
    return out
  end

  local function draw_tracks()
    ImGui.SetNextItemWidth(ctx, 240)
    local _, f = ImGui.InputTextWithHint(ctx, "##filter", "Filtrer les pistes…", S.filter)
    S.filter = f
    local flags = ImGui.TableFlags_RowBg | ImGui.TableFlags_BordersInnerV | ImGui.TableFlags_ScrollY | ImGui.TableFlags_Resizable
    if ImGui.BeginTable(ctx, "tracks", 6, flags, 0, 260) then
      ImGui.TableSetupScrollFreeze(ctx, 0, 1)
      ImGui.TableSetupColumn(ctx, "", ImGui.TableColumnFlags_WidthFixed, 24)
      ImGui.TableSetupColumn(ctx, "Piste", ImGui.TableColumnFlags_WidthStretch)
      ImGui.TableSetupColumn(ctx, "Rôle", ImGui.TableColumnFlags_WidthFixed, 110)
      ImGui.TableSetupColumn(ctx, "Bande fût (Hz)", ImGui.TableColumnFlags_WidthFixed, 170)
      ImGui.TableSetupColumn(ctx, "Decay (s)", ImGui.TableColumnFlags_WidthFixed, 120)
      ImGui.TableSetupColumn(ctx, "Statut", ImGui.TableColumnFlags_WidthStretch)
      ImGui.TableHeadersRow(ctx)
      for _, r in ipairs(visible_rows()) do
        local sel = S.sel[r.guid]
        local st = S.state and S.state.by_key and S.state.by_key[r.guid]
        local e = edit_buffers(r)
        ImGui.PushID(ctx, r.guid)
        ImGui.TableNextRow(ctx)

        ImGui.TableNextColumn(ctx)
        local ch, v = ImGui.Checkbox(ctx, "##chk", sel.checked)
        if ch then sel.checked = v; project.save_selection(S.sel) end

        ImGui.TableNextColumn(ctx)
        if r.level > 0 then ImGui.Dummy(ctx, r.level * 14, 1); ImGui.SameLine(ctx) end
        if r.is_folder then
          if ImGui.SmallButton(ctx, S.collapsed[r.guid] and "+" or "-") then
            S.collapsed[r.guid] = not S.collapsed[r.guid]
          end
          ImGui.SameLine(ctx)
        end
        if r.rgb then
          ImGui.ColorButton(ctx, "##col", (r.rgb << 8) | 0xFF, ImGui.ColorEditFlags_NoTooltip, 10, 10)
          ImGui.SameLine(ctx)
        end
        ImGui.Text(ctx, r.name)

        ImGui.TableNextColumn(ctx)
        ImGui.SetNextItemWidth(ctx, -1)
        local rc, ri = ImGui.Combo(ctx, "##role", ROLE_INDEX[sel.role] or 0, "Tom\0Référence\0Ignorer\0")
        if rc then sel.role = ROLES[ri]; project.save_selection(S.sel) end

        ImGui.TableNextColumn(ctx)
        local hint = "auto"
        if st and st.model then
          hint = ("auto : %.0f Hz (%.0f–%.0f)"):format(st.model.f0, st.model.band_lo, st.model.band_hi)
        end
        ImGui.SetNextItemWidth(ctx, -1)
        local _, bv = ImGui.InputTextWithHint(ctx, "##band", hint, e.band)
        e.band = bv
        if ImGui.IsItemDeactivatedAfterEdit(ctx) then commit_overrides(r, e) end
        if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Bande du fût en Hz, ex. 70-180. Vide = apprentissage automatique.") end

        ImGui.TableNextColumn(ctx)
        local dhint = "auto"
        if st and st.decay_s then
          dhint = ("auto : ~%.1f s%s"):format(st.decay_s, st.decay_measured and "" or " (défaut)")
        end
        ImGui.SetNextItemWidth(ctx, -1)
        local _, dv = ImGui.InputTextWithHint(ctx, "##decay", dhint, e.decay)
        e.decay = dv
        if ImGui.IsItemDeactivatedAfterEdit(ctx) then commit_overrides(r, e) end
        if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Temps de decay du fût en secondes. Vide = mesuré sur les coups isolés.") end

        ImGui.TableNextColumn(ctx)
        ImGui.Text(ctx, status_text(st))
        ImGui.PopID(ctx)
      end
      ImGui.EndTable(ctx)
    end
  end

  local function slider(label, key, lo, hi, fmt)
    ImGui.SetNextItemWidth(ctx, 240)
    local ch, v = ImGui.SliderDouble(ctx, label, S.settings[key], lo, hi, fmt)
    if ch then S.settings[key] = v; mark_changed() end
  end

  local function draw_presets()
    ImGui.SetNextItemWidth(ctx, 200)
    if ImGui.BeginCombo(ctx, "Preset", S.preset_label or "—") then
      for _, name in ipairs(project.preset_names()) do
        if ImGui.Selectable(ctx, name, name == S.preset_label) then
          local keep = S.settings.show_rejected
          S.settings = project.load_preset(name)
          S.settings.show_rejected = keep
          S.preset_label = name
          mark_changed()
        end
      end
      ImGui.EndCombo(ctx)
    end
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, 160)
    local _, nm = ImGui.InputTextWithHint(ctx, "##pname", "Nom du preset", S.preset_name)
    S.preset_name = nm
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Sauver le preset") and S.preset_name ~= "" then
      project.save_preset(S.preset_name, S.settings)
      S.preset_label, S.message = S.preset_name, ("Preset « %s » sauvegardé."):format(S.preset_name)
    end
  end

  local function draw_settings()
    ImGui.SeparatorText(ctx, "Détection")
    slider("Sensibilité", "sensitivity_pct", 0, 100, "%.0f %%")
    slider("Plancher de niveau", "floor_db", -45, -6, "%.0f dB")
    ImGui.SeparatorText(ctx, "Régions et roulements")
    ImGui.SetNextItemWidth(ctx, 240)
    local mc, mi = ImGui.Combo(ctx, "Longueur", S.settings.length_mode == "fixed" and 1 or 0, "Auto (decay)\0Fixe\0")
    if mc then S.settings.length_mode = (mi == 1) and "fixed" or "auto"; mark_changed() end
    slider("Pré-roll", "preroll_ms", 0, 20, "%.1f ms")
    if S.settings.length_mode == "auto" then
      slider("Profondeur de decay", "decay_depth_db", 10, 60, "-%.0f dB")
    else
      slider("Durée fixe", "fixed_ms", 50, 2000, "%.0f ms")
    end
    slider("Durée min", "min_ms", 20, 500, "%.0f ms")
    slider("Durée max", "max_ms", 300, 5000, "%.0f ms")
    slider("Merge gap", "merge_gap_ms", 0, 500, "%.0f ms")
    slider("Fade in", "fade_in_ms", 0, 20, "%.1f ms")
    slider("Fade out", "fade_out_ms", 0, 200, "%.0f ms")
    ImGui.SeparatorText(ctx, "Attribution entre pistes")
    slider("Fenêtre", "xwindow_ms", 0.5, 10, "±%.1f ms")
    slider("Marge de dominance", "margin_db", 1, 20, "%.1f dB")
    ImGui.SeparatorText(ctx, "Presets")
    draw_presets()
  end

  local function draw_advanced()
    ImGui.SetNextItemWidth(ctx, 240)
    local sizes = { [0] = 1024, [1] = 2048, [2] = 4096 }
    local cur = (S.settings.fft_base == 1024) and 0 or ((S.settings.fft_base == 4096) and 2 or 1)
    local fc, fi = ImGui.Combo(ctx, "Taille FFT (base 48 kHz)", cur, "1024\0002048\0004096\0")
    if fc then S.settings.fft_base = sizes[fi]; S.message = "Taille FFT modifiée : relancez l'analyse." end
    slider("Poids énergie", "w_energy", 0, 1, "%.2f")
    slider("Poids arrivée", "w_arrival", 0, 1, "%.2f")
    slider("Poids netteté", "w_sharp", 0, 1, "%.2f")
  end

  local function do_apply(mode)
    preview.clear_all()
    local res = apply.apply(S.state, mode)
    S.message = ("%s appliqué : %d régions sur %d items."):format(mode == "delete" and "Delete" or "Mute", res.regions, res.items)
    if res.stale > 0 then
      S.message = S.message .. (" %d items modifiés depuis l'analyse n'ont pas été traités (à réanalyser)."):format(res.stale)
    end
    S.state = nil
  end

  local function draw()
    draw_tracks()
    ImGui.Separator(ctx)
    if S.job then
      if ImGui.Button(ctx, "Annuler") then cancel_job() end
      ImGui.SameLine(ctx)
      ImGui.ProgressBar(ctx, S.progress, -1, 0, S.label)
    else
      if ImGui.Button(ctx, "Analyser") then start_analysis() end
      if S.state then
        ImGui.SameLine(ctx)
        local ch, v = ImGui.Checkbox(ctx, "Montrer les rejetés", S.settings.show_rejected)
        if ch then S.settings.show_rejected = v; S.preview_dirty = true; S.last_edit = now() end
      end
    end
    if ImGui.BeginTabBar(ctx, "tabs") then
      if ImGui.BeginTabItem(ctx, "Réglages") then draw_settings(); ImGui.EndTabItem(ctx) end
      if ImGui.BeginTabItem(ctx, "Avancé") then draw_advanced(); ImGui.EndTabItem(ctx) end
      ImGui.EndTabBar(ctx)
    end
    ImGui.Separator(ctx)
    ImGui.BeginDisabled(ctx, S.state == nil or S.job ~= nil)
    if ImGui.Button(ctx, "Appliquer : Mute") then do_apply("mute") end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Appliquer : Delete") then do_apply("delete") end
    ImGui.EndDisabled(ctx)
    ImGui.SameLine(ctx)
    ImGui.Dummy(ctx, 24, 1)
    ImGui.SameLine(ctx)
    ImGui.BeginDisabled(ctx, S.job ~= nil)
    if ImGui.Button(ctx, "Clean muted") then
      local n = apply.clean_interactive(checked_tom_tracks())
      if n > 0 then S.message = ("%d items muets supprimés."):format(n) end
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Reset") then
      local tracks = checked_tom_tracks()
      if #tracks > 0 and reaper.MB(("Rétablir %d piste(s) cochée(s) dans leur état d'avant traitement ?"):format(#tracks), TITLE, 1) == 1 then
        preview.clear_all()
        S.state = nil
        S.message = ("Reset : %d items rétablis."):format(apply.reset(tracks))
      end
    end
    ImGui.EndDisabled(ctx)
    if S.message ~= "" then ImGui.TextWrapped(ctx, S.message) end
  end

  local function on_close()
    if S.closed then return end
    S.closed = true
    if S.job then project.close_sources(S.job_tracks) end
    preview.clear_all()
    project.save_settings(S.settings)
    project.save_selection(S.sel)
  end

  local function loop()
    refresh_rows()
    if S.job then step_job() end
    if S.preview_dirty and not S.job and now() - S.last_edit > 0.15 then
      S.preview_dirty = false
      if S.state then preview.draw(S.state, S.settings) end
    end
    ImGui.SetNextWindowSize(ctx, 920, 680, ImGui.Cond_FirstUseEver)
    local visible, open = ImGui.Begin(ctx, TITLE, true)
    if visible then
      draw()
      ImGui.End(ctx)
    end
    if open then reaper.defer(loop) else on_close() end
  end

  reaper.atexit(on_close)
  reaper.defer(loop)
end

return M
```

- [ ] **Step 2: Implémenter le point d'entrée `Drums/GD_Tom auto-cut.lua`**

```lua
-- @description Tom auto-cut (transitoires + spectre, roulements, repisse inter-pistes)
-- @author Guillaume Delachat
-- @version 1.0.0
-- @changelog Première version
-- @provides
--   [nomain] tom_autocut/*.lua
--   [main] GD_Tom auto-cut - Clean muted.lua
-- @about
--   # Tom auto-cut
--   Analyse les pistes de toms (transitoires Peak, spectre, comparaison entre pistes),
--   construit des régions qui suivent le decay de chaque coup et gardent les roulements
--   d'un seul tenant, puis découpe les items en mode Mute (avec Clean et Reset) ou Delete.
--
--   Nécessite l'extension ReaImGui (ReaPack → ReaTeam Extensions).

local script_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])")
package.path = script_dir .. "?.lua;" .. package.path

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("Ce script nécessite l'extension ReaImGui.\n\n"
    .. "Installez-la via Extensions → ReaPack → Browse packages → « ReaImGui: ReaScript binding for Dear ImGui », "
    .. "puis redémarrez REAPER.", "GD Tom auto-cut", 0)
  return
end

package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
local ImGui = require("imgui")("0.9")
require("tom_autocut.ui").run(ImGui)
```

- [ ] **Step 3: Implémenter `Drums/GD_Tom auto-cut - Clean muted.lua`**

```lua
-- @noindex
-- Supprime les morceaux muets créés par GD Tom auto-cut (pistes cochées ou tout le projet).
local script_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])")
package.path = script_dir .. "?.lua;" .. package.path

local project = require("tom_autocut.project")
local apply = require("tom_autocut.apply")

local sel = project.load_selection() or {}
local tracks = {}
for _, r in ipairs(project.list_tracks()) do
  local s = sel[r.guid]
  if s and s.checked and s.role == "tom" then tracks[#tracks + 1] = r.track end
end
apply.clean_interactive(tracks)
```

- [ ] **Step 4: Vérification syntaxique et tests**

Run: `for f in Drums/tom_autocut/*.lua "Drums/GD_Tom auto-cut.lua" "Drums/GD_Tom auto-cut - Clean muted.lua"; do /usr/local/opt/lua@5.4/bin/luac5.4 -p "$f" || echo "SYNTAX $f"; done; sh tests/run.sh`
Expected: aucune ligne `SYNTAX`, tous les tests passent.

- [ ] **Step 5: Commit**

```bash
git add Drums/tom_autocut/ui.lua "Drums/GD_Tom auto-cut.lua" "Drums/GD_Tom auto-cut - Clean muted.lua"
git commit -m "feat: add ReaImGui window and entry scripts"
```

---

### Task 11: Packaging ReaPack, README, checklist de test manuel

**Files:**
- Create: `index.xml`, `docs/manual-test.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: en-tête ReaPack de `Drums/GD_Tom auto-cut.lua` (Task 10).
- Produces: dépôt ReaPack importable via `https://github.com/lukry59/reascript/raw/main/index.xml`.

- [ ] **Step 1: Installer et lancer `reapack-index`**

Run: `gem install --user-install reapack-index && export PATH="$(ruby -e 'print Gem.user_dir')/bin:$PATH" && reapack-index --version`
Si l'installation réussit :
Run: `reapack-index --check` puis `reapack-index --rebuild --name "GD Scripts" --no-commit`
Expected: `--check` sans erreur ; `index.xml` créé à la racine avec un package `Drums/GD_Tom auto-cut.lua` version 1.0.0, ses sources `tom_autocut/*.lua` et l'action `GD_Tom auto-cut - Clean muted.lua`.

Si la gem ne s'installe pas (dépendance native `rugged`), écrire `index.xml` à la main avec `<COMMIT>` = `git rev-parse HEAD` et une `<source>` par fichier de `Drums/tom_autocut/` :
```xml
<?xml version="1.0" encoding="utf-8"?>
<index version="1" name="GD Scripts">
  <category name="Drums">
    <reapack name="GD_Tom auto-cut.lua" type="script" desc="Tom auto-cut (transitoires + spectre, roulements, repisse inter-pistes)">
      <metadata>
        <description><![CDATA[Analyse les pistes de toms et découpe les items (Mute, Delete, Clean, Reset). Nécessite ReaImGui.]]></description>
      </metadata>
      <version name="1.0.0" author="Guillaume Delachat" time="2026-10-06T00:00:00Z">
        <changelog><![CDATA[Première version]]></changelog>
        <source main="main">https://github.com/lukry59/reascript/raw/<COMMIT>/Drums/GD_Tom%20auto-cut.lua</source>
        <source main="main" file="GD_Tom auto-cut - Clean muted.lua">https://github.com/lukry59/reascript/raw/<COMMIT>/Drums/GD_Tom%20auto-cut%20-%20Clean%20muted.lua</source>
        <source file="tom_autocut/analysis.lua">https://github.com/lukry59/reascript/raw/<COMMIT>/Drums/tom_autocut/analysis.lua</source>
        <source file="tom_autocut/apply.lua">https://github.com/lukry59/reascript/raw/<COMMIT>/Drums/tom_autocut/apply.lua</source>
        <source file="tom_autocut/attribution.lua">https://github.com/lukry59/reascript/raw/<COMMIT>/Drums/tom_autocut/attribution.lua</source>
        <source file="tom_autocut/audio.lua">https://github.com/lukry59/reascript/raw/<COMMIT>/Drums/tom_autocut/audio.lua</source>
        <source file="tom_autocut/bandtrack.lua">https://github.com/lukry59/reascript/raw/<COMMIT>/Drums/tom_autocut/bandtrack.lua</source>
        <source file="tom_autocut/cuts.lua">https://github.com/lukry59/reascript/raw/<COMMIT>/Drums/tom_autocut/cuts.lua</source>
        <source file="tom_autocut/envelope.lua">https://github.com/lukry59/reascript/raw/<COMMIT>/Drums/tom_autocut/envelope.lua</source>
        <source file="tom_autocut/features.lua">https://github.com/lukry59/reascript/raw/<COMMIT>/Drums/tom_autocut/features.lua</source>
        <source file="tom_autocut/fft.lua">https://github.com/lukry59/reascript/raw/<COMMIT>/Drums/tom_autocut/fft.lua</source>
        <source file="tom_autocut/pipeline.lua">https://github.com/lukry59/reascript/raw/<COMMIT>/Drums/tom_autocut/pipeline.lua</source>
        <source file="tom_autocut/preview.lua">https://github.com/lukry59/reascript/raw/<COMMIT>/Drums/tom_autocut/preview.lua</source>
        <source file="tom_autocut/project.lua">https://github.com/lukry59/reascript/raw/<COMMIT>/Drums/tom_autocut/project.lua</source>
        <source file="tom_autocut/regions.lua">https://github.com/lukry59/reascript/raw/<COMMIT>/Drums/tom_autocut/regions.lua</source>
        <source file="tom_autocut/settings.lua">https://github.com/lukry59/reascript/raw/<COMMIT>/Drums/tom_autocut/settings.lua</source>
        <source file="tom_autocut/ui.lua">https://github.com/lukry59/reascript/raw/<COMMIT>/Drums/tom_autocut/ui.lua</source>
      </version>
    </reapack>
  </category>
</index>
```
Remplacer `<COMMIT>` partout ; vérifier avec `grep -c 'tom_autocut/' index.xml` → `15`.

- [ ] **Step 2: Écrire `README.md`**

```markdown
# GD Scripts pour REAPER

## Installation (ReaPack)

1. Installer [ReaPack](https://reapack.com) si besoin.
2. *Extensions → ReaPack → Import repositories…* et coller :
   `https://github.com/lukry59/reascript/raw/main/index.xml`
3. *Extensions → ReaPack → Browse packages*, installer **GD_Tom auto-cut** et
   **ReaImGui: ReaScript binding for Dear ImGui** (dépôt ReaTeam Extensions), puis redémarrer REAPER.

## GD Tom auto-cut

Action **GD_Tom auto-cut** :
1. Cocher les pistes de toms (rôle *Tom*) ; optionnellement kick / caisse claire en *Référence*
   quand la repisse pose problème (multipiste live).
2. **Analyser** : les coups retenus (vert), la repisse (orange, avec la piste source) et les bornes
   de régions `[` `]` apparaissent en take markers sur les items.
3. Ajuster les réglages (preview en temps réel), éventuellement corriger la bande du fût ou le decay
   d'une piste dans le tableau.
4. **Appliquer : Mute** (réversible, puis **Clean muted** après écoute) ou **Appliquer : Delete**.
5. **Reset** rétablit une piste traitée en Mute.

Action **GD_Tom auto-cut - Clean muted** : supprime les morceaux muets créés par le script.

## Développement

Tests (Lua 5.4) : `sh tests/run.sh [filtre]`.
```

- [ ] **Step 3: Écrire `docs/manual-test.md`**

```markdown
# Test manuel dans REAPER

Projet de test : 3 pistes de toms réelles (Tom 1, Tom 2, Floor), une caisse claire, un kick.

- [ ] Sans ReaImGui : message d'installation, pas d'erreur Lua.
- [ ] Ouverture : toutes les pistes listées, dossiers indentés et repliables, couleurs ; pistes
      « tom/floor/ft/rack » pré-cochées à la première ouverture ; filtre par nom.
- [ ] Analyser sur un item continu de 5 min : barre de progression, REAPER reste réactif, Annuler fonctionne.
- [ ] Preview : markers verts sur les coups, orange sur la repisse (« bleed ← Floor »), `[` `]` autour
      des régions ; un roulement = une seule paire `[ ]`.
- [ ] Bouger Sensibilité / Merge gap / Profondeur : markers mis à jour sans relancer l'analyse.
- [ ] Item avec playrate 1,5 et offset de take : markers et coupes alignés sur les attaques.
- [ ] Items déjà découpés (comp) : chaque item traité séparément, edits respectés.
- [ ] Appliquer : Mute → morceaux hors région muets et assombris, un seul Undo ; fades en place.
- [ ] Option REAPER « auto-crossfade on split » active : pas de chevauchement entre morceaux.
- [ ] Clean muted (pistes cochées puis tout le projet) : confirmation avec le nombre d'items.
- [ ] Reset : piste revenue à l'item d'origine (heal), couleurs restaurées.
- [ ] Appliquer : Delete avec ripple editing actif : rien ne se décale, ripple restauré ensuite.
- [ ] Déplacer un item entre Analyser et Appliquer : item non traité, statut « à réanalyser ».
- [ ] Bande corrigée à la main (ex. 70-180) : réanalyse de bande automatique, valeur conservée à la réouverture.
- [ ] Caisse claire en Référence (live) : la repisse de caisse claire est marquée « bleed ← Snare ».
- [ ] Fermer la fenêtre : plus aucun take marker `GD·` dans le projet.
```

- [ ] **Step 4: Commit**

```bash
git add index.xml README.md docs/manual-test.md
git commit -m "chore: add ReaPack index, README and manual test checklist"
```

- [ ] **Step 5: Publication**

Demander à l'utilisateur l'autorisation de `git push origin main` (les URLs de l'index ne résolvent qu'après le push), puis lui faire dérouler `docs/manual-test.md` dans REAPER.
