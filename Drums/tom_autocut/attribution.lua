-- @noindex
-- Cross-track attribution of hits vs bleed (pure Lua).
local M = {}
local log, max = math.log, math.max

local function db10(x) return 10 * log(max(x, 1e-30), 10) end

local function usable(tr) return tr.model.usable ~= false end

local function dominance(c, tr, t_min, opts)
  local w = opts.weights
  local e = usable(tr) and db10(c.band_e / max(tr.model.typical_e, 1e-30)) or 0
  local sum = w.energy + w.arrival + w.sharp
  if sum <= 0 then return e end
  local a = -12 * (c.ptime - t_min) / opts.window_s
  local s = db10(c.sharpness / max(tr.model.typical_sharp, 1e-9))
  return (w.energy * e + w.arrival * a + w.sharp * s) / sum
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
      -- A track without a usable model never makes other candidates bleed.
      if usable(m.tr) then
        if m.tr.role == "ref" then
          if not best_ref or m.c.dominance > best_ref.c.dominance then best_ref = m end
        elseif not best_tom or m.c.dominance > best_tom.c.dominance then
          best_tom = m
        end
      end
    end
    for k = i, j do
      local m = all[k]
      local c = m.c
      if m.tr.role == "ref" then
        c.status = "ref"
      elseif best_ref and best_ref.c.dominance > c.dominance + opts.margin_db then
        c.status, c.bleed_from = "bleed", best_ref.tr.name
      elseif best_tom and best_tom ~= m and best_tom.c.dominance > c.dominance + opts.margin_db then
        c.status, c.bleed_from = "bleed", best_tom.tr.name
      elseif c.score <= 0 or c.score < opts.threshold then
        c.status = "rejected"
      else
        c.status = "hit"
      end
    end
    i = j + 1
  end
end

return M
