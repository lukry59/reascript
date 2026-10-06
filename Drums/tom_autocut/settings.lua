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
