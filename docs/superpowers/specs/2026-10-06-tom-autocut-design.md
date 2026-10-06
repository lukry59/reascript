# GD Tom auto-cut — Design

Date : 2026-10-06
Statut : validé en brainstorming, en attente de relecture de la spec

## 1. Objectif

Script ReaScript (Lua) pour REAPER qui nettoie automatiquement les pistes de toms :
il analyse l'audio (transitoires + spectre), détermine les vrais coups de chaque tom
(en écartant la repisse), construit des régions qui suivent le decay réel du fût et
gèrent les roulements, puis découpe les items.

Distribution via **ReaPack** depuis le dépôt GitHub `lukry59/reascript`
(`index.xml` à la racine, URL raw ajoutée dans *Extensions → ReaPack → Import repositories*).

### Critères de réussite

- Un coup de tom isolé est détecté à ±1 ms de son attaque réelle.
- La repisse d'un tom voisin, de la caisse claire ou des cymbales n'ouvre pas de région.
- Un roulement produit une seule région continue, quel que soit le tempo.
- La fin de chaque région suit le decay réel du coup (coup fort → région plus longue).
- Mode Mute réversible (Undo, Reset), Clean séparé après vérification.
- Analyse non bloquante, ajustement des réglages avec preview en temps réel.

### Hors périmètre (v1)

- Déclenchement de samples, création de markers/régions de projet, traitement MIDI.
- Pistes autres que des toms comme cibles de découpe (kick/snare ne servent que de référence).

## 2. Modes de sortie

- **Mute** : découpe, les morceaux hors région sont rendus muets et tagués.
  L'action **Clean muted** (bouton + action séparée) les supprime après vérification.
- **Delete** : découpe et suppression directe des morceaux hors région.
- **Reset** : rétablit une piste traitée en Mute (unmute des morceaux tagués + *Heal splits*).

## 3. Architecture et packaging

```
reascript/
├── index.xml                              index ReaPack (reapack-index)
├── Drums/
│   ├── GD_Tom auto-cut.lua                point d'entrée, UI ReaImGui, @provides des modules
│   ├── GD_Tom auto-cut - Clean muted.lua  action séparée
│   └── tom_autocut/
│       ├── audio.lua        lecture audio accessor par blocs, somme mono
│       ├── envelope.lua     suiveurs Peak rapide/lent, fonction d'onset, détection candidats
│       ├── fft.lua          FFT radix-2 Lua pur, fenêtre de Hann
│       ├── bandtrack.lua    passe-bande (2 biquads) sur la bande du fût + enveloppe 10 ms
│       ├── cuts.lua         découpage pur d'un item en morceaux gardés/hors région
│       ├── settings.lua     valeurs par défaut, presets, (dé)sérialisation, noms de pistes
│       ├── pipeline.lua     étage léger : scores → attribution → decay → régions
│       ├── analysis.lua     étage lourd : passes A (onsets+features) et B (bande)
│       ├── project.lua      pistes du projet, persistance, tags
│       ├── preview.lua      take markers GD·
│       ├── features.lua     features spectrales, apprentissage bande fût et decay
│       ├── attribution.lua  regroupement inter-pistes, attribution coup/repisse
│       ├── regions.lua      régions : pré-roll, decay auto, roulements, merge gap
│       ├── apply.lua        split, mute/delete, fades, tags, clean, reset
│       └── ui.lua           fenêtre ImGui, liste des pistes, réglages, preview
└── tests/
    ├── run.lua              lanceur des tests
    └── *_test.lua           tests sur signaux synthétiques
```

Principes :

- `envelope`, `fft`, `features`, `attribution`, `regions` sont **purs** (tableaux de nombres
  en entrée/sortie, aucun appel `reaper.*`) et testables avec `lua` 5.4 hors REAPER.
- `audio`, `apply`, `ui` sont les seuls modules qui touchent l'API REAPER.
- Analyse exécutée par tranches dans la boucle `defer` d'ImGui (barre de progression, Annuler).
- **Cache à deux niveaux** : analyse lourde (enveloppes, candidats, features, mesures de
  decay) calculée une fois par item ; attribution + régions recalculées à chaque changement
  de réglage (quasi instantané).
- Préfixe `GD_` pour les actions. Dépendance ReaImGui : vérifiée au lancement, message
  d'installation si absente.
- Persistance : sélection des pistes et rôles par projet (`SetProjExtState`), bande de fût
  et decay corrigés par piste (`P_EXT` de piste), derniers réglages et presets (`SetExtState`).

## 4. Interface

### Liste des pistes

À l'ouverture, la fenêtre affiche **toutes les pistes du projet**, dans l'ordre, avec
indentation des dossiers (dossiers repliables), nom et couleur de la piste. La liste se
rafraîchit si le projet change.

Colonnes : case à cocher · nom · rôle (**Tom** / **Référence** / **Ignorer**) ·
bande fût apprise (ex. « 92 Hz (70–180) », éditable) · decay appris (ex. « ~1,4 s »,
éditable) · statut (coups retenus, repisses, régions, % conservé, ignorés).

- **Filtre** par nom en haut de la liste.
- **Pré-sélection auto** à la première ouverture dans un projet : pistes dont le nom contient
  `tom`, `floor`, `ft` ou `rack` (insensible à la casse) cochées en rôle Tom. Ensuite, la
  sélection mémorisée dans le projet est restaurée.
- Le rôle **Référence** (kick, snare) est optionnel : la piste est analysée mais jamais découpée.

### Déroulé

1. Cocher les pistes, choisir les rôles.
2. **Analyser** (progression par piste, Annuler possible ; rien n'est modifié dans le projet).
3. Preview par **take markers** préfixés `GD·` sur les items :
   🟢 coup retenu · 🟠 repisse (avec la piste dominante, ex. « bleed ← Floor ») ·
   ⚪ rejeté (si « montrer rejetés » coché) · `[` `]` bornes de région.
4. Ajuster les réglages → preview mise à jour en temps réel.
5. **Appliquer : Mute** ou **Appliquer : Delete** (un bloc d'Undo, markers de preview retirés).
6. **Clean muted** / **Reset** à tout moment.

### Réglages

| Groupe | Réglage | Défaut |
|---|---|---|
| Détection | Sensibilité (seuil de score) | 50 % |
| | Plancher de niveau (dB sous le coup typique) | −30 dB |
| Régions | Mode de longueur | Auto (decay) / Fixe |
| | Pré-roll | 5 ms |
| | Profondeur de decay (mode Auto) | −40 dB |
| | Durée fixe (mode Fixe) | 300 ms |
| | Durée min / max | 60 ms / 2,5 s |
| | Merge gap | 120 ms |
| | Fade in / fade out | 2 ms / 30 ms (fade out calé sur la queue en mode Auto) |
| Attribution | Fenêtre inter-pistes | ±3 ms |
| | Marge de dominance | 6 dB |
| Avancé | Taille FFT (base 48 kHz, mise à l'échelle avec le sample rate) | 2048 |
| | Fenêtre d'analyse spectrale | 0–50 ms après l'onset |
| | Pondération des indices d'attribution | énergie 0,6 · arrivée 0,25 · netteté 0,15 |

Presets nommés sauvegardables (livrés : « Studio », « Live (bleed fort) »).

## 5. Moteur de détection

### Étage 1 — Candidats (par item)

- Lecture via `CreateTakeAudioAccessor` par blocs de 65 536 échantillons, canaux sommés en
  mono (prise en compte de l'offset de take et du playrate par l'accessor).
- Signal redressé. Deux suiveurs **Peak** (attaque instantanée) :
  rapide (release ≈ 5 ms) et lent (release ≈ 50 ms), calculés à l'échantillon,
  réduits au **maximum par trame de 1 ms**.
- **Fonction d'onset** = écart en dB entre suiveur rapide et lent (borné à ≥ 0).
- Candidat = maximum local de la fonction d'onset au-dessus d'un seuil adaptatif
  (médiane glissante sur 1 s + k dB). Écart minimum 15 ms entre candidats (anti double
  déclenchement uniquement, sans rapport avec les roulements).
- **Affinage** : recherche à l'échantillon du début de montée sur le signal brut autour du
  candidat.

### Étage 2 — Features (par candidat)

- FFT de `next_pow2(2048 · sr / 48000)` points (≈ 43–46 ms), Hann, depuis l'onset.
- `E_band` (énergie dans la bande du fût), `R_low/high` (40–400 Hz / 2–10 kHz),
  `f0` (pic dominant 50–400 Hz), `sharpness` (pente d'attaque en dB/ms), `peak_dB`.
- **Bande du fût apprise** : candidats « forts » = dominés par le grave (`e_low > e_high`) et
  à moins de 6 dB du plus fort, limités aux `max(5, 20 %)` plus forts ; `f0_track` = médiane
  de leurs `f0` ; bande = `[0,75·f0_track ; 2·f0_track]`. Si moins de 2 candidats forts :
  bande par défaut 60–300 Hz + avertissement. Correction manuelle possible.
  (Un tom peut ne jouer que quelques coups par morceau : exiger 5 coups forts ferait
  apprendre la bande sur la repisse.)
- **Coup typique** de la piste = médiane `E_band` des candidats forts (sert à normaliser).
- **Score piste seule** (0–1) : combinaison pondérée de `E_band` normalisé, `R_low/high`,
  `sharpness`, cohérence `f0`/`f0_track`. Rejet si `peak_dB` < coup typique + plancher.

### Étage 3 — Attribution inter-pistes (si ≥ 2 pistes cochées)

- Regroupement en événements des candidats de toutes les pistes (Tom et Référence)
  situés dans la fenêtre inter-pistes (±3 ms).
- Dominance par piste = combinaison pondérée de l'énergie normalisée dans **sa propre**
  bande, d'un bonus d'arrivée (onset le plus précoce) et de la netteté d'attaque.
- Une piste Tom garde le coup si sa dominance est à moins de la marge (6 dB) de la meilleure
  **et** si son score dépasse le seuil → les coups simultanés (flams) sont conservés sur
  chaque piste concernée.
- Si une piste Référence domine au-delà de la marge, le candidat est repisse sur les pistes Tom.
- Une seule piste cochée → pas d'étage 3, score piste seule uniquement.

### Étage 4 — Régions et decay automatique

- **Suivi du decay** : passe B sur tout l'item, filtre passe-bande (2 biquads RBJ en cascade)
  centré sur la bande du fût, enveloppe crête par trames de 10 ms (en dB). Remplace le
  Goertzel initialement prévu : une fenêtre de 10 ms est plus courte qu'une période à 80 Hz,
  le Goertzel n'y a aucune résolution, et le filtre coûte moins cher en Lua.
- **Modèle de decay par piste** : sur les coups isolés (aucun autre coup dans les 1,5 s),
  régression linéaire de la pente en dB/s → decay typique (éditable dans la liste).
- **Fin de région** (mode Auto) : premier instant où l'énergie de bande passe sous
  `max(coup_typique_bande − profondeur, bruit + 3 dB)` (niveau **absolu** par piste, d'où
  coup fort → région plus longue) ; si l'énergie remonte de plus de 3 dB (autre source,
  coup suivant) avant, extrapolation depuis le point le plus bas avec la pente du modèle.
  Bornée par durée min/max.
- Decay corrigé à la main : la fin devient `onset + (pic_du_coup − cible) / pente`, avec
  `pente = −profondeur / decay_corrigé` (le réglage manuel est alors déterminant).
- Mode Fixe : fin = onset + durée fixe.
- Début de région = `onset − pré-roll`.
- **Roulements** : un coup retenu qui arrive avant la fin calculée de la région ouverte la
  prolonge ; la fin est recalculée à partir du dernier coup.
- **Merge gap** : deux régions séparées de moins de la valeur sont fusionnées.
- Régions bornées à l'item d'origine ; chaque item est traité indépendamment.

## 6. Application

- Conversion en temps projet, `SplitMediaItem` à chaque borne.
- Morceaux gardés : fade in = réglage Fade in (dans le pré-roll), fade out sur la fin de queue
  (Auto : `clamp(0,3 · queue, Fade out, 0,5 s)`, jamais avant le dernier onset) ;
  fades existants aux extrémités de l'item d'origine conservés.
- Morceaux hors région :
  - Mute : `B_MUTE = 1`, `P_EXT:GD_TOMCUT = muted`, couleur assombrie.
  - Delete : suppression ; ripple editing désactivé pendant l'opération puis restauré.
- Position, longueur et offset de chaque morceau sont réécrits après le split (insensible à
  l'option « auto-crossfade on split » de REAPER).
- `PreventUIRefresh` + un bloc d'Undo par application
  (« GD Tom auto-cut : Mute (3 pistes, 128 régions) »).
- **Clean muted** : supprime les items muets **et** tagués, sur les pistes cochées ou tout le
  projet, après confirmation indiquant le nombre d'items.
- **Reset** : unmute des items tagués, suppression du tag et de la couleur, *Heal splits*.

## 7. Cas particuliers

| Situation | Comportement |
|---|---|
| ReaImGui absent | Message avec procédure d'installation via ReaPack, arrêt |
| Items verrouillés, MIDI ou vides | Ignorés, comptés dans le statut |
| Items déjà traités | Morceaux muets tagués ignorés à l'analyse ; avertissement proposant Reset |
| Item modifié entre analyse et application | Empreinte (GUID, position, longueur, offset) ; item marqué « à réanalyser » et non traité |
| Aucun coup / bande non apprise | Avertissement sur la ligne, bande par défaut 60–300 Hz |
| Analyse longue | Annuler ; aucune modification du projet avant application |
| Take markers `GD·` orphelins | Nettoyés à l'ouverture suivante |

## 8. Tests

1. **Unitaires, Lua 5.4 pur** (`lua tests/run.lua`), signaux synthétiques :
   - sinus amorti 90 Hz (decay connu) → onset à ±1 ms, longueur de région cohérente avec
     le decay théorique, coup fort plus long qu'un coup faible ;
   - bruit filtré dans l'aigu (caisse claire/cymbales) → rejeté ;
   - roulement en doubles croches à 180 BPM → une seule région ;
   - deux pistes, repisse retardée de 2 ms et atténuée de 12 dB → attribution correcte ;
   - flam simultané sur deux toms → coup gardé sur les deux ;
   - FFT comparée à des valeurs de référence, filtre passe-bande (gain au centre, réjection).
2. **ReaPack** : `reapack-index --check` avant chaque release.
3. **Manuel dans REAPER** : item continu, items déjà découpés, Mute → Clean, Delete avec
   ripple actif, Reset, Undo.
