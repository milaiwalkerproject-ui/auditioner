# Glossary — Italian (it)

Terms chosen for the machine translation of the Auditioner UI (`it.json`). The app
addresses the user as *tu*. iOS system wording: Impostazioni, Annulla, Fine, Elimina,
Condividi, Accedi con Apple, File (Files app), Foto (Photos app).

| English | Italian | Notes |
|---|---|---|
| excerpt | passo | "passi d'orchestra" is the standard term; "Excerpts" tab → Passi |
| excerpt page | pagina del passo | |
| part (sheet music) | parte | "My parts" → Le mie parti |
| audition | audizione | |
| open auditions | audizioni aperte | |
| mock audition | audizione simulata | |
| behind the screen | dietro il paravento | |
| audition panel / round | commissione / turno | Preliminary round → Turno preliminare, Semi-final → Semifinale, Final round → Finale |
| chair / position | ruolo | "Which chair?" → Quale ruolo?; "Include all chairs" → Includi tutti i ruoli |
| principal | prima parte | |
| assistant principal | concertino | Italian string-section usage; unsure for winds |
| section | fila / di fila | standalone chair label "Section" → Fila; "section cello" → violoncello di fila |
| second | secondo | |
| utility | utility | no Italian equivalent; kept |
| concertmaster | spalla | |
| high / low (horn) | acuto / grave | |
| (excerpt) list | lista | "lists" → liste; "official list" → lista ufficiale. The two `lists.phrase.*` keys have no format arguments, so they are plain complements — "per questo strumento" / "per il tuo ruolo" — and the noun "lista/liste" sits in the surrounding sentences ("In 7 delle 9 liste per il tuo ruolo che abbiamo raccolto", "In 3 delle 4 liste per questo strumento che abbiamo raccolto, tutti i ruoli"). "questo strumento", not "il tuo strumento": “this instrument”, not “your instrument”, because the excerpt page builds its query from the excerpt's instrument (`ExcerptFrequencySection`), which need not be the player's own; the chair always comes from the player's Settings, so `lists.phrase.chair` keeps “your chair”. |
| repertoire | repertorio | |
| catalogue | catalogo | |
| match (to catalogue) | corrispondenza / abbinare | "Match to catalogue" → Abbina al catalogo; "Link"/"Unlink" → Collega/Scollega |
| line (of a list) | riga | |
| item (list entry) | voce | |
| readiness | preparazione | Not started → Non iniziato, Learning the notes → Sto imparando le note, Under tempo → Sotto tempo, Nearly there → Quasi pronto, Audition-ready → Pronto per l'audizione |
| practice / practise | studio / studiare | "Practice" tab → Studio; "Practised today" → Studiato oggi |
| practice tools | strumenti per lo studio | "Tools" → Strumenti; "Instrument" → Strumento |
| reference audio | audio di riferimento | "Reference" → Riferimento |
| take | take | feminine, as used by Italian musicians |
| rating (self-rating, stars) | valutazione | "Your rating" → La tua valutazione; "Overall" → Nel complesso; "Your verdict" → Il tuo giudizio |
| recording | registrazione | |
| record (button) | Registra | |
| record & compare | registra e confronta | |
| count-in | conteggio | |
| drone | bordone | "Pure tone" → Suono puro; "Instrument sound" → Suono strumentale |
| metronome | metronomo | |
| beat | battito | "beats per minute" → battiti al minuto; beats inside a bar → tempi |
| beat unit | figura di riferimento | |
| subdivision | suddivisione | |
| tap tempo | tap tempo | "Tap four times…" → Batti quattro volte a ritmo… |
| tempo marking | indicazione di tempo | |
| typical tempo | tempo abituale | |
| meter (time signature) | metro | |
| key (signature) | tonalità | |
| bar / measure | battuta | "From bar 12" → Dalla battuta 12 |
| rehearsal mark | lettera / numero di chiamata | not used in UI keys yet |
| bowing | arcata | |
| note values | semibreve, minima, semiminima, croma, semicroma, biscroma | Whole, Half, Quarter, 8th, 16th, 32nd |
| dotted quarter | semiminima puntata | |
| rest | pausa | "Pause" (playback) is also Pausa |
| tie | legatura | |
| dot | punto | |
| sharp / flat / natural | diesis / bemolle / bequadro | |
| accidental | alterazione | |
| tuning | intonazione | "A = 440 Hz" stays; "Tuning of A" → Intonazione del La |
| scan (noun / verb) | scansione / scansiona | "Scan my part" → Scansiona la mia parte |
| mark start / mark end | Segna inizio / Segna fine | user's own marks → i miei segni |
| mark the excerpt (crop) | Delimita il passo | |
| markup (Apple Pencil) | Annota | |
| loop | loop | |
| slow down / speed up | rallenta / accelera | |
| checked (by a person) | verificato | "Check the official list" → Controlla la lista ufficiale |
| draft | bozza | |
| curated (human-written) | Redazione | pill label |
| AI-generated | generato dall'IA | |
| frequency tiers | Fondamentale / Frequente / Occasionale | Core / Common / Occasional |
| share (of lists) | quota | "tiers" → fasce |
| scrambled (install code) | mascherato | hashed, not reversible |
| deadline / application deadline | scadenza / scadenza iscrizione | "applications close" → le iscrizioni chiudono; "before applying" → prima di iscriverti |
| player (musician) | musicista | "Popular with other players" → Popolari tra gli altri musicisti; "what other players practise" → cosa studiano gli altri musicisti |
| region | regione | UK → Regno Unito, North America → Nord America, Asia-Pacific → Asia-Pacifico, Europe (German-speaking) → Europa (di lingua tedesca) |
| instrument families | Archi / Legni / Ottoni / Tastiere / Timpani e percussioni | |

Reviewed 2026-10-11: 36 entries corrected (see git history).
