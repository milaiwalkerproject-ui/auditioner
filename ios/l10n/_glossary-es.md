# Glossary — Spanish (es, neutral Spain + Latin America)

Machine translation (PLAN A7, shown with the "Traducción beta" label until a native speaker
checks it). The user is addressed as **tú**. iOS system wording: Ajustes, Cancelar, OK,
Eliminar, Compartir, Archivos, Fotos, Iniciar sesión con Apple. Sentence case throughout.

| English | Spanish | Notes |
|---|---|---|
| audition | audición | |
| open auditions (the feed) | audiciones abiertas | "feed" is never translated literally |
| My upcoming audition | Mi próxima audición | |
| mock audition / run | simulacro de audición / el simulacro | |
| excerpt | extracto | "extractos orquestales" for orchestral excerpts |
| excerpt page | página del extracto | |
| part (the player's printed part) | parte | "Escanear mi parte", "Mis partes" |
| reference audio / reference | audio de referencia / referencia | |
| take | toma | |
| recording | grabación | "Grabar" = Record (button) |
| catalogue | catálogo | |
| list (repertoire list) | lista | "lista oficial" = official list |
| repertoire | repertorio | |
| chair / position | posición | one word for both, because the key "Position" is shared with the playback-position slider; "Incluir todas las posiciones", "Lo más pedido para tu posición" |
| Principal | Principal | |
| Assistant principal | Asistente de principal | Spain also says "ayuda de solista" |
| Section | Tutti | the usual word in Spanish orchestra vacancies ("violonchelo tutti") |
| Utility | Utility | US-specific chair; no Spanish equivalent, left as is |
| Second | Segundo | |
| High / Low (horn) | Agudo / Grave | |
| Concertmaster | Concertino | |
| Any (chair) | Cualquiera | |
| round | ronda | Ronda preliminar · Semifinal · Ronda final |
| sight-reading | lectura a primera vista | |
| readiness | preparación | "Listo para la audición" = audition-ready, "Por debajo del tempo" = under tempo |
| application deadline / deadline | plazo de solicitud / plazo | |
| bar | compás | "Compases" = Bars |
| meter | compás | same word as "bar" in Spanish; it is the time signature row |
| beat | pulso / tiempo | "pulso" for the beat concept (Unidad de pulso, Subdividir cada pulso); "tiempo" when counted ("Tiempo 2 de 4", "Tiempos por compás") |
| beats per minute | pulsaciones por minuto | |
| count-in | cuenta de entrada | |
| drone | nota pedal | |
| metronome | metrónomo | |
| tap tempo | marcar tempo | |
| tuning (A) | afinación (del la) | "A = 440 Hz" stays as is |
| loop | bucle | "Repetir entre mis marcas" = Loop my marks |
| Mark start / Mark end | Marcar inicio / Marcar final | |
| play / pause / stop | reproducir / pausa / detener | |
| rehearsal mark | letra de ensayo | not used in a key yet |
| note values | redonda, blanca, negra, corchea, semicorchea, fusa | |
| accidentals | sostenido, bemol, becuadro; "Sin alteración" = No sign | |
| rest / tie / dot | silencio / ligadura / puntillo | |
| scan (noun / verb) | escaneo / escanear | |
| tier (Core / Common / Occasional) | nivel (Esencial / Habitual / Ocasional) | |
| share (the statistic) | proporción | |
| players (generic) | músicos | "intérpretes de %@" when an instrument is named |
| curated (prose written by people) | Escrito por personas | pill label |
| draft | borrador | |
| checked / verified | comprobado | "Consulta la lista oficial" = Check the official list |
| scrambled (code) | anonimizado | a code that cannot be turned back into the original |
| Settings → Server | Ajustes → Servidor | |
| Send feedback / Report an error | Enviar comentarios / Informar de un error | |
| Sign in / Sign out / Delete account | Iniciar sesión / Cerrar sesión / Eliminar cuenta | |
| Done / OK / Cancel | Listo / OK / Cancelar | |
| Add / Remove / Delete | Añadir / Quitar / Eliminar | |
| Horn | Trompa | Latin America often says "corno (francés)" |
| Timpani | Timbales | |
| Behind the screen | Detrás del biombo | |
| video | vídeo | Spain spelling; Latin America writes "video" |
| Public domain / Protected (copyright row) | Dominio público en … / Con derechos de autor en … | |
| Faster by N / Slower by N (tempo buttons) | N más rápido / N más lento | also "5 más rápido" / "5 más lento" |
| Overall (mock audition rating) | General | |
| Practise next (section) | Qué practicar ahora | |
| Something went wrong | Algo salió mal | simple past reads neutral in Spain and Latin America; "¿Cómo te fue?", "¿Ves un error?" likewise |
| note (a notice banner, not a pitch) | aviso | "Ocultar este aviso" |

Keys `lists.phrase.chair` and `lists.phrase.allChairs` are translated without the instrument
and chair words ("listas para tu posición", "listas de este instrumento") because `_keys.json`
records them without format arguments and `merge_translations.py` rejects any `%@` in them.
`lists.phrase.allChairs` says "este instrumento" — “this instrument”, not “your instrument”, because the excerpt page builds its query from the excerpt's instrument (`ExcerptFrequencySection`), which need not be the player's own; the chair always comes from the player's Settings, so `lists.phrase.chair` keeps “your chair”.
The wording that keeps the words, for when the script accepts positional arguments:
`lists.phrase.chair` → `%3$@ de %2$@ %1$@` (e.g. "listas de violonchelo tutti"),
`lists.phrase.allChairs` → `%2$@ de %1$@` (e.g. "listas de violonchelo").
