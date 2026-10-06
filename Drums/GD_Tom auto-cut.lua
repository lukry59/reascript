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
