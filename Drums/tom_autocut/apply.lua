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
