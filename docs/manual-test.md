# Test manuel dans REAPER

Projet de test : 3 pistes de toms réelles (Tom 1, Tom 2, Floor), une caisse claire, un kick.

- [ ] Sans ReaImGui : message d'installation, pas d'erreur Lua.
- [ ] Ouverture : toutes les pistes listées, dossiers indentés et repliables, couleurs ; pistes
      « tom/floor/ft/rack » pré-cochées à la première ouverture ; filtre par nom.
- [ ] Analyser sur un item continu de 5 min : barre de progression, REAPER reste réactif, Annuler fonctionne.
- [ ] Preview : markers verts sur les coups, orange sur la repisse (« bleed ← Floor »), `[` `]` autour
      des régions ; un roulement = une seule paire `[ ]`.
- [ ] Bouger Sensibilité / Merge gap / Profondeur : markers mis à jour sans relancer l'analyse.
- [ ] Item avec playrate 1,5 et offset de take : markers et coupes alignés sur les attaques.
- [ ] Items déjà découpés (comp) : chaque item traité séparément, edits respectés.
- [ ] Appliquer : Mute → morceaux hors région muets et assombris, un seul Undo ; fades en place.
- [ ] Option REAPER « auto-crossfade on split » active : pas de chevauchement entre morceaux.
- [ ] Clean muted (pistes cochées puis tout le projet) : confirmation avec le nombre d'items.
- [ ] Reset : piste revenue à l'item d'origine (heal), couleurs restaurées.
- [ ] Appliquer : Delete avec ripple editing actif : rien ne se décale, ripple restauré ensuite.
- [ ] Déplacer un item entre Analyser et Appliquer : item non traité, statut « à réanalyser ».
- [ ] Bande corrigée à la main (ex. 70-180) : réanalyse de bande automatique, valeur conservée à la réouverture.
- [ ] Caisse claire en Référence (live) : la repisse de caisse claire est marquée « bleed ← Snare ».
- [ ] Fermer la fenêtre : plus aucun take marker `GD·` dans le projet.
