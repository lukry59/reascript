-- @noindex
-- ReaImGui window: track list, analysis job, settings, preview, apply.
local settings_mod = require("tom_autocut.settings")
local project = require("tom_autocut.project")
local analysis = require("tom_autocut.analysis")
local pipeline = require("tom_autocut.pipeline")
local preview = require("tom_autocut.preview")
local apply = require("tom_autocut.apply")
local features = require("tom_autocut.features")

local M = {}
local TITLE = "GD Tom auto-cut"
local ROLES = { [0] = "tom", [1] = "ref", [2] = "ignore" }
local ROLE_INDEX = { tom = 0, ref = 1, ignore = 2 }

function M.run(ImGui)
  local ctx = ImGui.CreateContext(TITLE)
  local stored = project.load_selection()
  local S = {
    settings = project.load_settings(),
    sel = stored or {}, first_open = stored == nil,
    rows = {}, change_count = -1, filter = "", collapsed = {},
    state = nil, job = nil, job_kind = nil, job_tracks = nil, progress = 0, label = "",
    preview_dirty = false, last_edit = 0, message = "",
    preset_label = nil, preset_name = "", edits = {}, closed = false, band_cancelled = false,
  }
  preview.clear_all()

  local function now() return reaper.time_precise() end

  local function refresh_rows()
    local cc = reaper.GetProjectStateChangeCount(0)
    if cc == S.change_count then return end
    S.change_count = cc
    S.rows = project.list_tracks()
    for _, r in ipairs(S.rows) do
      if not S.sel[r.guid] then
        S.sel[r.guid] = { role = "tom", checked = S.first_open and settings_mod.is_tom_name(r.name) }
      end
    end
    if S.first_open then
      S.first_open = false
      project.save_selection(S.sel)
    end
  end

  local function checked_rows(only_toms)
    local out = {}
    for _, r in ipairs(S.rows) do
      local s = S.sel[r.guid]
      if s and s.checked and s.role ~= "ignore" and (not only_toms or s.role == "tom") then
        out[#out + 1] = { track = r.track, guid = r.guid, name = r.name, role = s.role }
      end
    end
    return out
  end

  local function checked_tom_tracks()
    local out = {}
    for _, r in ipairs(checked_rows(true)) do out[#out + 1] = r.track end
    return out
  end

  local function mark_changed()
    if S.state then
      pipeline.recompute(S.state, S.settings)
      S.preview_dirty = true
    end
    S.last_edit = now()
  end

  local function start_job(kind, tracks, fn)
    S.job_kind, S.job_tracks, S.progress, S.label = kind, tracks, 0, ""
    S.job = coroutine.create(fn)
  end

  local function start_analysis()
    local rows = checked_rows(false)
    if #rows == 0 then
      S.message = "Cochez au moins une piste (rôle Tom ou Référence)."
      return
    end
    preview.clear_all()
    S.state, S.message = nil, ""
    local tracks = project.build_sources(rows)
    start_job("full", tracks, function() return analysis.run(tracks, S.settings, coroutine.yield) end)
  end

  local function start_band_job(tr)
    start_job("band", { tr }, function()
      analysis.rerun_band(tr, coroutine.yield)
      return S.state
    end)
  end

  local function cancel_job()
    project.close_sources(S.job_tracks)
    if S.job_kind == "full" then S.state = nil end
    if S.job_kind == "band" then S.band_cancelled = true end
    S.job, S.message = nil, "Analyse annulée."
  end

  -- Ticking/unticking or changing the role of an analysed track invalidates the analysis.
  local function selection_changed(guid)
    if not (S.state and S.state.by_key and S.state.by_key[guid]) then return end
    if S.job then
      project.close_sources(S.job_tracks)
      S.job = nil
    end
    S.state = nil
    preview.clear_all()
    S.message = "Sélection modifiée : relancez Analyser."
  end

  local function pending_band_track()
    if not S.state then return nil end
    for _, tr in ipairs(S.state.tracks or {}) do
      if tr.needs_band_pass then return tr end
    end
    return nil
  end

  local function step_job()
    local deadline = now() + 0.025
    while S.job and now() < deadline do
      local ok, a, b = coroutine.resume(S.job)
      if not ok then
        project.close_sources(S.job_tracks)
        if S.job_kind == "full" then S.state = nil else S.band_cancelled = true end
        S.job = nil
        S.message = "Erreur pendant l'analyse : " .. tostring(a)
      elseif coroutine.status(S.job) == "dead" then
        project.close_sources(S.job_tracks)
        S.job = nil
        S.state = a
        if S.state then
          pipeline.recompute(S.state, S.settings)
          S.preview_dirty, S.last_edit = true, 0
        end
      else
        S.progress, S.label = a or S.progress, b or S.label
      end
    end
  end

  local function commit_overrides(r, e)
    local band = settings_mod.parse_band(e.band)
    if band and band[2] > features.KEEP_HZ then
      if band[1] >= features.KEEP_HZ then
        band = nil
        S.message = ("Bande au-dessus de %d Hz ignorée."):format(features.KEEP_HZ)
      else
        band[2] = features.KEEP_HZ
        e.band = ("%g-%g"):format(band[1], band[2])
        S.message = ("Bande limitée à %d Hz."):format(features.KEEP_HZ)
      end
    end
    local decay = tonumber((e.decay:gsub(",", ".")))
    if decay and decay <= 0 then decay = nil end
    project.set_overrides(r.track, band, decay)
    local tr = S.state and S.state.by_key[r.guid]
    if tr then
      tr.band_override, tr.decay_override_s = band, decay
      mark_changed()
      S.band_cancelled = false
      if tr.needs_band_pass and not S.job then start_band_job(tr) end
    end
  end

  local function edit_buffers(r)
    local e = S.edits[r.guid]
    if not e then
      local band, decay = project.get_overrides(r.track)
      e = { band = band and ("%g-%g"):format(band[1], band[2]) or "", decay = decay and ("%g"):format(decay) or "" }
      S.edits[r.guid] = e
    end
    return e
  end

  local function status_text(st)
    if not st then return "" end
    local parts = {}
    if st.role == "ref" then
      parts[1] = ("%d événements (référence)"):format(#(st.cands or {}))
    elseif st.stats then
      local s = st.stats
      parts[1] = ("%d coups · %d repisses · %d régions · %.0f %% conservé"):format(
        s.hits, s.bleeds, s.regions, s.total > 0 and 100 * s.kept / s.total or 0)
    end
    if st.skipped and st.skipped > 0 then parts[#parts + 1] = ("%d items ignorés"):format(st.skipped) end
    if st.processed then parts[#parts + 1] = "déjà traitée : Reset conseillé" end
    if st.model and not st.model.ok and not st.model.manual then parts[#parts + 1] = "bande par défaut (peu de coups)" end
    if st.needs_band_pass then parts[#parts + 1] = "bande modifiée : réanalyse…" end
    local stale = 0
    for _, it in ipairs(st.items or {}) do if it.stale then stale = stale + 1 end end
    if stale > 0 then parts[#parts + 1] = ("%d items à réanalyser"):format(stale) end
    return table.concat(parts, " · ")
  end

  local function visible_rows()
    local out, hide_below = {}, nil
    local f = S.filter:lower()
    for _, r in ipairs(S.rows) do
      if not (hide_below and r.level > hide_below) then
        hide_below = nil
        if f == "" or r.name:lower():find(f, 1, true) then out[#out + 1] = r end
        if r.is_folder and S.collapsed[r.guid] then hide_below = r.level end
      end
    end
    return out
  end

  local function draw_tracks()
    ImGui.SetNextItemWidth(ctx, 240)
    local _, f = ImGui.InputTextWithHint(ctx, "##filter", "Filtrer les pistes…", S.filter)
    S.filter = f
    local flags = ImGui.TableFlags_RowBg | ImGui.TableFlags_BordersInnerV | ImGui.TableFlags_ScrollY | ImGui.TableFlags_Resizable
    if ImGui.BeginTable(ctx, "tracks", 6, flags, 0, 260) then
      ImGui.TableSetupScrollFreeze(ctx, 0, 1)
      ImGui.TableSetupColumn(ctx, "", ImGui.TableColumnFlags_WidthFixed, 24)
      ImGui.TableSetupColumn(ctx, "Piste", ImGui.TableColumnFlags_WidthStretch)
      ImGui.TableSetupColumn(ctx, "Rôle", ImGui.TableColumnFlags_WidthFixed, 110)
      ImGui.TableSetupColumn(ctx, "Bande fût (Hz)", ImGui.TableColumnFlags_WidthFixed, 170)
      ImGui.TableSetupColumn(ctx, "Decay (s)", ImGui.TableColumnFlags_WidthFixed, 120)
      ImGui.TableSetupColumn(ctx, "Statut", ImGui.TableColumnFlags_WidthStretch)
      ImGui.TableHeadersRow(ctx)
      for _, r in ipairs(visible_rows()) do
        local sel = S.sel[r.guid]
        local st = S.state and S.state.by_key and S.state.by_key[r.guid]
        local e = edit_buffers(r)
        ImGui.PushID(ctx, r.guid)
        ImGui.TableNextRow(ctx)

        ImGui.TableNextColumn(ctx)
        local ch, v = ImGui.Checkbox(ctx, "##chk", sel.checked)
        if ch then
          sel.checked = v
          project.save_selection(S.sel)
          selection_changed(r.guid)
        end

        ImGui.TableNextColumn(ctx)
        if r.level > 0 then ImGui.Dummy(ctx, r.level * 14, 1); ImGui.SameLine(ctx) end
        if r.is_folder then
          if ImGui.SmallButton(ctx, S.collapsed[r.guid] and "+" or "-") then
            S.collapsed[r.guid] = not S.collapsed[r.guid]
          end
          ImGui.SameLine(ctx)
        end
        if r.rgb then
          ImGui.ColorButton(ctx, "##col", (r.rgb << 8) | 0xFF, ImGui.ColorEditFlags_NoTooltip, 10, 10)
          ImGui.SameLine(ctx)
        end
        ImGui.Text(ctx, r.name)

        ImGui.TableNextColumn(ctx)
        ImGui.SetNextItemWidth(ctx, -1)
        local rc, ri = ImGui.Combo(ctx, "##role", ROLE_INDEX[sel.role] or 0, "Tom\0Référence\0Ignorer\0")
        if rc then
          sel.role = ROLES[ri]
          project.save_selection(S.sel)
          selection_changed(r.guid)
        end

        ImGui.TableNextColumn(ctx)
        local hint = "auto"
        if st and st.model then
          hint = ("auto : %.0f Hz (%.0f–%.0f)"):format(st.model.f0, st.model.band_lo, st.model.band_hi)
        end
        ImGui.SetNextItemWidth(ctx, -1)
        local _, bv = ImGui.InputTextWithHint(ctx, "##band", hint, e.band)
        e.band = bv
        if ImGui.IsItemDeactivatedAfterEdit(ctx) then commit_overrides(r, e) end
        if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Bande du fût en Hz, ex. 70-180. Vide = apprentissage automatique.") end

        ImGui.TableNextColumn(ctx)
        local dhint = "auto"
        if st and st.decay_s then
          dhint = ("auto : ~%.1f s%s"):format(st.decay_s, st.decay_measured and "" or " (défaut)")
        end
        ImGui.SetNextItemWidth(ctx, -1)
        local _, dv = ImGui.InputTextWithHint(ctx, "##decay", dhint, e.decay)
        e.decay = dv
        if ImGui.IsItemDeactivatedAfterEdit(ctx) then commit_overrides(r, e) end
        if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Temps de decay du fût en secondes. Vide = mesuré sur les coups isolés.") end

        ImGui.TableNextColumn(ctx)
        ImGui.Text(ctx, status_text(st))
        ImGui.PopID(ctx)
      end
      ImGui.EndTable(ctx)
    end
  end

  local function slider(label, key, lo, hi, fmt)
    ImGui.SetNextItemWidth(ctx, 240)
    local ch, v = ImGui.SliderDouble(ctx, label, S.settings[key], lo, hi, fmt)
    if ch then S.settings[key] = v; mark_changed() end
  end

  local function draw_presets()
    ImGui.SetNextItemWidth(ctx, 200)
    if ImGui.BeginCombo(ctx, "Preset", S.preset_label or "—") then
      for _, name in ipairs(project.preset_names()) do
        if ImGui.Selectable(ctx, name, name == S.preset_label) then
          local keep = S.settings.show_rejected
          S.settings = project.load_preset(name)
          S.settings.show_rejected = keep
          S.preset_label = name
          mark_changed()
        end
      end
      ImGui.EndCombo(ctx)
    end
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, 160)
    local _, nm = ImGui.InputTextWithHint(ctx, "##pname", "Nom du preset", S.preset_name)
    S.preset_name = nm
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Sauver le preset") and S.preset_name ~= "" then
      project.save_preset(S.preset_name, S.settings)
      S.preset_label, S.message = S.preset_name, ("Preset « %s » sauvegardé."):format(S.preset_name)
    end
  end

  local function draw_settings()
    ImGui.SeparatorText(ctx, "Détection")
    slider("Sensibilité", "sensitivity_pct", 0, 100, "%.0f %%")
    slider("Plancher de niveau", "floor_db", -45, -6, "%.0f dB")
    ImGui.SeparatorText(ctx, "Régions et roulements")
    ImGui.SetNextItemWidth(ctx, 240)
    local mc, mi = ImGui.Combo(ctx, "Longueur", S.settings.length_mode == "fixed" and 1 or 0, "Auto (decay)\0Fixe\0")
    if mc then S.settings.length_mode = (mi == 1) and "fixed" or "auto"; mark_changed() end
    slider("Pré-roll", "preroll_ms", 0, 20, "%.1f ms")
    if S.settings.length_mode == "auto" then
      slider("Profondeur de decay", "decay_depth_db", 10, 60, "-%.0f dB")
    else
      slider("Durée fixe", "fixed_ms", 50, 2000, "%.0f ms")
    end
    slider("Durée min", "min_ms", 20, 500, "%.0f ms")
    slider("Durée max", "max_ms", 300, 5000, "%.0f ms")
    slider("Merge gap", "merge_gap_ms", 0, 500, "%.0f ms")
    slider("Fade in", "fade_in_ms", 0, 20, "%.1f ms")
    slider("Fade out", "fade_out_ms", 0, 200, "%.0f ms")
    ImGui.SeparatorText(ctx, "Attribution entre pistes")
    slider("Fenêtre", "xwindow_ms", 0.5, 10, "±%.1f ms")
    slider("Marge de dominance", "margin_db", 1, 20, "%.1f dB")
    ImGui.SeparatorText(ctx, "Presets")
    draw_presets()
  end

  local function draw_advanced()
    ImGui.SetNextItemWidth(ctx, 240)
    local sizes = { [0] = 1024, [1] = 2048, [2] = 4096 }
    local cur = (S.settings.fft_base == 1024) and 0 or ((S.settings.fft_base == 4096) and 2 or 1)
    local fc, fi = ImGui.Combo(ctx, "Taille FFT (base 48 kHz)", cur, "1024\0002048\0004096\0")
    if fc then S.settings.fft_base = sizes[fi]; S.message = "Taille FFT modifiée : relancez l'analyse." end
    slider("Poids énergie", "w_energy", 0, 1, "%.2f")
    slider("Poids arrivée", "w_arrival", 0, 1, "%.2f")
    slider("Poids netteté", "w_sharp", 0, 1, "%.2f")
  end

  local function do_apply(mode)
    preview.clear_all()
    local tracks = {}
    for _, tr in ipairs(S.state.tracks) do
      local sel = S.sel[tr.key]
      if sel and sel.checked and sel.role == "tom" then tracks[#tracks + 1] = tr end
    end
    local ok, res = pcall(apply.apply, { tracks = tracks }, mode)
    if not ok then
      S.state = nil
      S.message = "Erreur pendant l'application : " .. tostring(res)
      return
    end
    S.message = ("%s appliqué : %d régions sur %d items."):format(mode == "delete" and "Delete" or "Mute", res.regions, res.items)
    if res.stale > 0 then
      S.message = S.message .. (" %d items modifiés depuis l'analyse n'ont pas été traités (à réanalyser)."):format(res.stale)
    end
    S.state = nil
  end

  local function draw()
    draw_tracks()
    ImGui.Separator(ctx)
    if S.job then
      if ImGui.Button(ctx, "Annuler") then cancel_job() end
      ImGui.SameLine(ctx)
      ImGui.ProgressBar(ctx, S.progress, -1, 0, S.label)
    else
      if ImGui.Button(ctx, "Analyser") then start_analysis() end
      if S.state then
        ImGui.SameLine(ctx)
        local ch, v = ImGui.Checkbox(ctx, "Montrer les rejetés", S.settings.show_rejected)
        if ch then S.settings.show_rejected = v; S.preview_dirty = true; S.last_edit = now() end
      end
    end
    if ImGui.BeginTabBar(ctx, "tabs") then
      if ImGui.BeginTabItem(ctx, "Réglages") then draw_settings(); ImGui.EndTabItem(ctx) end
      if ImGui.BeginTabItem(ctx, "Avancé") then draw_advanced(); ImGui.EndTabItem(ctx) end
      ImGui.EndTabBar(ctx)
    end
    ImGui.Separator(ctx)
    ImGui.BeginDisabled(ctx, S.state == nil or S.job ~= nil or pending_band_track() ~= nil)
    if ImGui.Button(ctx, "Appliquer : Mute") then do_apply("mute") end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Appliquer : Delete") then do_apply("delete") end
    ImGui.EndDisabled(ctx)
    ImGui.SameLine(ctx)
    ImGui.Dummy(ctx, 24, 1)
    ImGui.SameLine(ctx)
    ImGui.BeginDisabled(ctx, S.job ~= nil)
    if ImGui.Button(ctx, "Clean muted") then
      local ok, n = pcall(apply.clean_interactive, checked_tom_tracks())
      if not ok then
        S.message = "Erreur pendant Clean muted : " .. tostring(n)
      elseif n > 0 then
        S.message = ("%d items muets supprimés."):format(n)
      end
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Reset") then
      local tracks = checked_tom_tracks()
      if #tracks > 0 and reaper.MB(("Rétablir %d piste(s) cochée(s) dans leur état d'avant traitement ?"):format(#tracks), TITLE, 1) == 1 then
        preview.clear_all()
        S.state = nil
        local ok, n = pcall(apply.reset, tracks)
        S.message = ok and ("Reset : %d items rétablis."):format(n) or ("Erreur pendant Reset : " .. tostring(n))
      end
    end
    ImGui.EndDisabled(ctx)
    if S.message ~= "" then ImGui.TextWrapped(ctx, S.message) end
  end

  local function on_close()
    if S.closed then return end
    S.closed = true
    if S.job then project.close_sources(S.job_tracks) end
    preview.clear_all()
    project.save_settings(S.settings)
    project.save_selection(S.sel)
  end

  local function loop()
    refresh_rows()
    if S.job then step_job() end
    if not S.job and S.state and not S.band_cancelled then
      local tr = pending_band_track()
      if tr then start_band_job(tr) end
    end
    if S.preview_dirty and not S.job and now() - S.last_edit > 0.15 then
      S.preview_dirty = false
      if S.state then preview.draw(S.state, S.settings) end
    end
    ImGui.SetNextWindowSize(ctx, 920, 680, ImGui.Cond_FirstUseEver)
    local visible, open = ImGui.Begin(ctx, TITLE, true)
    if visible then
      draw()
      ImGui.End(ctx)
    end
    if open then reaper.defer(loop) else on_close() end
  end

  reaper.atexit(on_close)
  reaper.defer(loop)
end

return M
