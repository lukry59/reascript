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
