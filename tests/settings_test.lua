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
  for _, n in ipairs({ "Tom 1", "TOM2", "Floor Tom", "FT", "ft 16", "Rack", "rack tom", "Toms" }) do
    H.truthy(settings.is_tom_name(n), n)
  end
  for _, n in ipairs({ "Snare", "Left OH", "Soft synth", "Kick In", "", "Snare Bottom", "Bottom Mic", "Custom", "Atom" }) do
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
