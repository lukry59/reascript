# GD Scripts pour REAPER

## Installation (ReaPack)

1. Installer [ReaPack](https://reapack.com) si besoin.
2. *Extensions → ReaPack → Import repositories…* et coller :
   `https://github.com/lukry59/reascript/raw/main/index.xml`
3. *Extensions → ReaPack → Browse packages*, installer **GD_Tom auto-cut** et
   **ReaImGui: ReaScript binding for Dear ImGui** (dépôt ReaTeam Extensions), puis redémarrer REAPER.

## GD Tom auto-cut

Action **GD_Tom auto-cut** :
1. Cocher les pistes de toms (rôle *Tom*) ; optionnellement kick / caisse claire en *Référence*
   quand la repisse pose problème (multipiste live).
2. **Analyser** : les coups retenus (vert), la repisse (orange, avec la piste source) et les bornes
   de régions `[` `]` apparaissent en take markers sur les items.
3. Ajuster les réglages (preview en temps réel), éventuellement corriger la bande du fût ou le decay
   d'une piste dans le tableau.
4. **Appliquer : Mute** (réversible, puis **Clean muted** après écoute) ou **Appliquer : Delete**.
5. **Reset** rétablit une piste traitée en Mute.

Action **GD_Tom auto-cut - Clean muted** : supprime les morceaux muets créés par le script.

## Développement

Tests (Lua 5.4) : `sh tests/run.sh [filtre]`.
