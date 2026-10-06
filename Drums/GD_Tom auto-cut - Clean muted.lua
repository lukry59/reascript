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
