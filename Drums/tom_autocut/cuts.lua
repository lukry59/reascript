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
