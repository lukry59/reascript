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
