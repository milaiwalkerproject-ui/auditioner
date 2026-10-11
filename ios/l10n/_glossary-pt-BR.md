# Glossary — Brazilian Portuguese (pt-BR)

Machine translation (PLAN A7, shown with the "Tradução beta" label until a native speaker
checks it). The user is addressed as **você**. iOS system wording (Brazil): Ajustes, Cancelar,
OK (also for "Done"), Apagar, Compartilhar, Salvar, Arquivos, Fotos, Marcação, Iniciar sessão
com a Apple, Sair. Sentence case throughout.

| English | Portuguese (BR) | Notes |
|---|---|---|
| audition | audição | |
| open auditions (the feed) | audições abertas | "feed" is never translated literally ("a lista de audições abertas") |
| My upcoming audition | Minha próxima audição | |
| mock audition / the run | audição simulada / a simulação | "Gravar a simulação inteira" = Record the whole run |
| excerpt | excerto | "excertos orquestrais", as in Brazilian editais; not "trecho" |
| excerpt page | página do excerto | |
| part (the player's printed part) | parte | "Escanear minha parte", "Minhas partes" |
| reference audio / reference | áudio de referência / referência | |
| take | take (m.) | the usual studio word in Brazil; "Take sem título" |
| recording | gravação | "Gravar" = Record (button); "Gravado em" = Recorded (date label) |
| catalogue | catálogo | |
| list (repertoire list) | lista | "lista oficial" = official list |
| repertoire | repertório | |
| chair / position | posição | one word for both, because the key "Position" is shared with the playback-position slider; "Incluir todas as posições", "Qual posição?" |
| Principal | Chefe de naipe | |
| Assistant principal | Assistente de chefe de naipe | |
| Section | Tutti | the word Brazilian orchestras use in vacancies ("Violoncelo tutti") |
| Utility | Utility | US-specific chair, left as is |
| Second | Segundo | |
| High / Low (horn) | Agudo / Grave | |
| Concertmaster | Spalla | |
| Any (chair) | Qualquer | |
| round | fase | Fase preliminar · Semifinal · Fase final |
| sight-reading | leitura à primeira vista | |
| readiness | preparo | "Pronto para a audição" = audition-ready, "Abaixo do andamento" = under tempo, "Não iniciado", "Aprendendo as notas", "Quase lá" |
| application deadline / deadline | prazo de inscrição / prazo | |
| tempo | andamento | the musical term; "Andamento típico", "Indicação de andamento", "Andamento de referência" |
| tap tempo | marcar andamento | |
| bar | compasso | "Compassos" = Bars; "Todos os compassos fecham" = All bars add up |
| meter | fórmula de compasso | the time-signature row |
| beat | tempo / pulso | "tempo" when counted ("Tempo 2 de 4", "Tempos por compasso", "Subdividir cada tempo"); "Pulso" is the metronome card title |
| beats per minute | batidas por minuto | BPM stays |
| count-in | contagem de entrada | "Contagem…" while it runs |
| drone | drone (m.) | common among Brazilian musicians; "nota pedal" not used |
| metronome | metrônomo | |
| tuning (A) | afinação (do lá) | "A = 440 Hz", "Afinação (A4)" stay as is |
| loop | loop | toggle label; "Repetir entre minhas marcas" = Loop my marks |
| Mark start / Mark end | Marcar início / Marcar fim | |
| play / pause / stop | reproduzir / pausar / parar | |
| rehearsal mark | letra de ensaio | not used in a key yet |
| note values | semibreve, mínima, semínima, colcheia, semicolcheia, fusa | |
| accidentals | sustenido, bemol, bequadro; "Sem acidente" = No sign | |
| rest / tie / dot | pausa / ligadura / ponto | editor buttons |
| scan (noun / verb) | escaneamento / escanear | iOS Brazil says "Escanear" (Notes, Files); "Escaneamentos por dia" |
| tier (Core / Common / Occasional) | categoria (Essencial / Frequente / Ocasional) | "categoria" so it never collides with "Nível %lld de 5" (difficulty) |
| share (the statistic) | proporção | |
| players (generic) | músicos | "músicos de %@" when an instrument is named |
| practise (verb) / Practice (tab) | estudar / Estudo | the idiomatic Brazilian verb for practising an instrument; "Estudar a seguir", "Estudado hoje", "Dicas de estudo", "player de estudo" |
| notes (prose, free text) | anotações | so it never reads as musical notes ("Corrigir as notas") |
| curated (prose written by people) | Escrito por pessoas | pill label |
| draft | rascunho | |
| checked / verified | verificado | "Confira a lista oficial" = Check the official list |
| scrambled (code) | embaralhado | a code that cannot be turned back into the original |
| device | dispositivo | iOS wording, never "aparelho" |
| Settings → Server | Ajustes → Servidor | |
| Send feedback / Report an error | Enviar feedback / Informar um erro | |
| Sign in / Sign out / Delete account | Iniciar sessão / Sair / Apagar conta | Apple's pt-BR wording; "Sessão iniciada com a Apple" |
| Done / OK / Cancel | OK / OK / Cancelar | iOS Brazil uses "OK" for Done |
| Add / Remove / Delete | Adicionar / Remover / Apagar | |
| Try again / Retry / Not now | Tentar novamente / Tentar novamente / Agora não | |
| Horn | Trompa | |
| Timpani | Tímpanos | |
| E♭ clarinet | Requinta | the Brazilian name for the E♭ clarinet |
| Bass clarinet | Clarone | the Brazilian name for the bass clarinet |
| Piccolo | Flautim | |
| Behind the screen | Atrás do biombo | |
| Markup (PDF) | Marcação | Apple's pt-BR term |
| video | vídeo | |

Keys `lists.phrase.chair` and `lists.phrase.allChairs` are translated without the instrument
and chair words because `_keys.json` records them without format arguments and
`merge_translations.py` rejects any `%@` in them. The phrase is only the qualifier — "da sua
posição" / "do seu instrumento" — and the sentences around it carry "lista"/"listas", so the
singular case reads naturally: "Em 7 das 9 listas da sua posição que coletamos (2022–2026)",
"Na única lista da sua posição que coletamos (2025)", "Em 3 das 4 listas do seu instrumento que
coletamos, todas as posições (2024–2026)", "Ainda não coletamos listas da sua posição.".
The wording that keeps the words, for when the script accepts positional arguments:
`lists.phrase.chair` → `%3$@ de %2$@ %1$@` (e.g. "listas de violoncelo tutti"),
`lists.phrase.allChairs` → `%2$@ de %1$@` (e.g. "listas de violoncelo") — the sentences would
then drop their own "listas".

Other choices worth knowing: "Other" → "Outros" (one key for the region list and the line-kind
list, so neither "Outro" nor "Outra" fits both); the mock-audition review screen is "Revisão"
("Terminar e revisar"); the tempo row summary "At 72, aiming for 96" is "Atual 72, meta 96"
(the form fields are "Alcançado" and "Meta"); "Time to prepare" is "Tempo de preparação".
