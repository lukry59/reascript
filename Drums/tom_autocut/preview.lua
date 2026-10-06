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
