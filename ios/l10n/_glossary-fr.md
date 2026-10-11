# Glossary — French (fr, France)

Machine translation (PLAN A7, shown with the "Traduction bêta" label until a native speaker
checks it). The user is addressed as **vous**. iOS system wording: Réglages, Annuler, OK (also
for "Done"), Supprimer, Partager, Fichiers, Photos, Annoter (Markup), Se connecter avec Apple.
Sentence case throughout. Typography: a non-breaking space (U+00A0) before `: ; ? !` and inside
`« »`, applied consistently to every string.

| English | French | Notes |
|---|---|---|
| audition | audition | |
| open auditions (the feed) | auditions ouvertes | "feed" is never translated literally |
| My upcoming audition | Ma prochaine audition | |
| mock audition / the run | audition blanche / la session | "Lancer l'audition blanche" |
| excerpt | trait | the word French orchestral players use; "traits d'orchestre" = orchestral excerpts; tab "Traits" |
| excerpt page | page du trait | |
| part (the player's printed part) | partition | "Scanner ma partition", "Mes partitions"; also in the editor ("n'est plus dans la partition"); "partie" only for the structure of a MusicXML file ("aucune partie à modifier", "aucune partie avec des mesures") |
| reference audio / reference | audio de référence / référence | |
| take | prise | |
| recording | enregistrement | "Enregistrer" = Record (button) and also Save (form button, iOS standard) |
| save audio (export to Files) | exporter l'audio | kept distinct from Record = Enregistrer |
| catalogue | catalogue | |
| list (repertoire list) | liste | "liste officielle" = official list |
| repertoire | répertoire | |
| chair | poste | "Inclure tous les postes", "Quel poste ?", "pour votre poste" |
| Position (shared key) | Position | one key serves the Settings row, the browser filter and the playback-position slider, so it stays "Position" |
| Principal | Soliste | French orchestras: "violoncelle solo", "hautbois solo" |
| Assistant principal | Co-soliste | |
| Section | Tutti | |
| Utility | Utility | US-specific chair; no French equivalent, left as is |
| Second | Second | |
| High / Low (horn) | Aigu / Grave | |
| Concertmaster | Violon solo | |
| Any (chair) | Indifférent | |
| round | tour | Tour préliminaire · Demi-finale · Finale; "Tous les tours" |
| sight-reading | déchiffrage | the conservatoire word; "Les lignes de déchiffrage sont écartées" |
| readiness | préparation | "Prêt pour l'audition" = audition-ready, "Sous le tempo" = under tempo, "Pas commencé" = not started |
| application deadline / deadline | date limite de candidature / date limite | |
| bar | mesure | "Mesures" = Bars |
| meter | chiffrage de mesure | kept distinct from "Mesures" in the same Facts box |
| key | tonalité | |
| beat | pulsation / temps | "Pulsation" for the metronome card; "temps" when counted ("Temps 2 sur 4", "Temps par mesure", "Unité de temps") |
| beats per minute | battements par minute | |
| count-in | décompte | |
| drone | bourdon | |
| metronome | métronome | |
| tap tempo | battre le tempo | |
| tuning (A) | diapason | "Diapason (A4)", "Diapason du la"; "A = 440 Hz" stays as is |
| loop | boucle | "Boucler entre mes repères" = Loop my marks |
| Mark start / Mark end | Marquer le début / Marquer la fin | "repères" = marks |
| play / pause / stop | Lecture / Pause / Arrêter | |
| note values | ronde, blanche, noire, croche, double croche, triple croche | "Noire pointée" = dotted quarter |
| accidentals | dièse, bémol, bécarre; "Sans altération" = No sign | |
| rest / tie / dot | silence / liaison / point | |
| scan (noun / verb) | scan / scanner | |
| tier (Core / Common / Occasional) | niveau (Incontournable / Courant / Occasionnel) | |
| share (the statistic) | part | "La part et les niveaux" |
| players (generic) | musiciens | "musiciens (%@)" when an instrument is named |
| practise / Practice (tab) | travailler / Travail | the musicians' word; "À travailler ensuite" = Practise next |
| curated (prose written by people) | Rédigé par des personnes | pill label |
| draft | brouillon | |
| checked / verified | vérifié | "Consultez la liste officielle" = Check the official list |
| scrambled (code) | brouillé | a code that cannot be turned back into the original |
| Settings → Server | Réglages → Serveur | |
| Send feedback / Report an error | Envoyer un commentaire / Signaler une erreur | |
| Sign in / Sign out / Delete account | Se connecter / Se déconnecter / Supprimer le compte | |
| Done / OK / Cancel | OK / OK / Annuler | |
| Add / Remove / Delete | Ajouter / Retirer / Supprimer | |
| Horn / English horn | Cor / Cor anglais | |
| Timpani | Timbales | |
| Viola | Alto | |
| Behind the screen | Derrière le paravent | |
| Facts (the verified rows) | Infos | "Infos sur le trait" = Excerpt facts |
| How often it's asked | Fréquence de demande | |
| Level N of 5 (difficulty) | Difficulté N sur 5 | kept apart from "niveau", which is the tier |
| Match to catalogue / Link / Unlink | Lier au catalogue / Lier / Délier | "correspondance" = a match (noun) |
| rough guide only | à titre indicatif | |
| Hide this note (a banner) | Masquer ce message | not a musical note |
| Jump to my start | Aller à mon repère | |
| No open <instrument> auditions right now | Aucune audition ouverte pour <instrument> en ce moment | "pour violoncelle", "pour alto": no article needed |

Keys `lists.phrase.chair` and `lists.phrase.allChairs` are recorded in `_keys.json` without
format arguments, and `merge_translations.py` rejects any `%@` in them, so the instrument and
chair words cannot be carried. The French phrases are therefore "pour votre poste" / "pour votre
instrument" **without the noun**, and the noun "liste(s)" is written into each sentence that uses
the phrase, where the count is known ("Figure sur %lld des %lld listes %@ que nous avons
collectées…", "Nous n'avons encore collecté aucune liste %@."). The region caveat reorders its
arguments so "pour votre poste" is not followed by another "pour": "Région %3$@ : moins de %1$lld
listes %2$@ jusqu'ici, …". The wording that keeps the words,
for when the script accepts positional arguments (noun still omitted, since the sentences carry it):
`lists.phrase.chair` → `de %2$@ %1$@` (e.g. "listes de violoncelle tutti"),
`lists.phrase.allChairs` → `de %1$@` (e.g. "listes de violoncelle").
