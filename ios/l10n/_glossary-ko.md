# Glossary — Korean (ko)

Terms chosen for `ko.json`, used consistently. Sentences use 해요체 (…해요 / …하세요 /
…할까요?); buttons and labels are short noun forms (저장, 삭제, 녹음). "Your/my" in UI
labels is 내 (내 오디션, 내 파트보), as iOS Korean does. iOS system terms follow Apple's
Korean wording: 설정, 취소, 완료, 삭제, 공유, 저장, 확인 (OK), 파일 (Files app), 사진
(Photos app), 마크업 (Markup), Apple로 로그인 (Sign in with Apple). Korean has no plural
forms and no CLDR plural categories beyond `other`, so every value is a plain string.
Counters attach to the number without a space (%lld개, %lld페이지, %lld박, %@마디). Default
titles put the date first, as Korean modifiers precede the noun (%@ 스캔, %@ 사진, %@ 파트보,
%@ 스캔한 파트보).
Western punctuation; a space before "(" only when the bracket follows a Korean word
(튜닝 (A4)) and none when it follows a format argument inside a sentence (연도(%@)).

| English | Korean | Notes |
|---|---|---|
| audition (the event the player attends) | 오디션 | tab title, dates, My auditions = 내 오디션, mock audition = 모의 오디션 |
| open auditions / feed (orchestras' calls) | 오디션 공고 | "No open cello auditions right now" = 지금 열려 있는 첼로 오디션이 없어요; "On N open auditions now" = 현재 오디션 공고 N건에 포함; feed = 공고 (피드) |
| My upcoming audition | 다가오는 내 오디션 | |
| audition day | 오디션 날짜 | |
| application deadline | 지원 마감일 | "Deadline" alone = 마감일; reminder title "Application deadline %@" = %@ 지원 마감 (time phrase first) |
| excerpt | 발췌곡 | orchestral excerpts = 오케스트라 발췌곡; counted with 곡 (발췌곡 %lld곡) |
| excerpt page | 발췌곡 페이지 | |
| part (sheet music) | 파트보 | My parts = 내 파트보; Scan my part = 내 파트보 스캔 |
| list (audition repertoire list) | 리스트 | 곡목 리스트 where the noun stands alone: lists.phrase.allChairs = 이 악기의 곡목 리스트, lists.phrase.chair = 이 포지션의 곡목 리스트 (the key takes no format argument, so the instrument name is dropped; "이", not "내", because on an excerpt page the instrument is the excerpt's, not always the player's); official list = 공식 리스트; "list"/"lists" both 리스트 |
| repertoire | 레퍼토리 | |
| catalogue (the app's excerpt catalogue) | 카탈로그 | match to catalogue = 카탈로그와 연결; catalogue match = 카탈로그 연결; Link / Unlink = 연결 / 연결 해제 |
| chair / position | 포지션 | "Which chair?" = 어느 포지션이에요?; "Include all chairs" = 모든 포지션 포함; ", all chairs" = , 모든 포지션 |
| principal | 수석 | |
| assistant principal | 부수석 | |
| section (player) | 단원 | "Section cello" = 첼로 단원 |
| second (chair) | 세컨드 | e.g. 2nd flute |
| utility | 유틸리티 | |
| high / low (horn) | 하이 / 로우 | |
| concertmaster | 악장 | |
| any (chair) | 포지션 무관 | |
| round | 라운드 | preliminary = 예선, semi-final = 준결선, final = 결선; sight-reading = 초견 |
| readiness | 준비 상태 | not started = 시작 전, learning the notes = 음 익히는 중, under tempo = 템포 미달, nearly there = 거의 다 됨, audition-ready = 오디션 준비 완료, not rated yet = 아직 평가 안 함 |
| count (lists, statistics) | 집계하다 / 계산하다 | never 세요 (reads as an imperative) |
| reference audio | 레퍼런스 오디오 | "Reference" (player segment) = 레퍼런스; "You" (same key: player segment and the Settings header) = 내 연주; "Both" = 둘 다; "Listen to" (segment label) = 듣기 |
| how often it's asked | 오디션에 나오는 빈도 | section header and filter; "Any frequency" = 모든 빈도 |
| recording / take | 녹음 | "Record" (button) = 녹음; untitled take = 제목 없는 녹음 |
| mock audition | 모의 오디션 | behind the screen (rule) = 블라인드; run = 이번 모의 오디션 |
| count-in | 예비박 | |
| drone | 드론 | sustained note = 지속음 |
| metronome | 메트로놈 | tap tempo = 탭 템포 |
| tempo | 템포 | typical tempo = 일반적인 템포; tempo marking = 빠르기말; aiming for = 목표; at (current) = 현재 |
| beat / beats per bar | 박 / 마디당 박 수 | beat unit = 박 단위; subdivision = 분할; accent beat 1 = 첫 박 강세; "Beat" card = 박 |
| bar | 마디 | %@마디 (From bar = %@마디부터, To bar = %@마디까지); "Bars to check" (label before the chips) = 확인할 마디; "All bars add up" = 모든 마디의 박이 맞아요 |
| meter / key / clef | 박자 / 조성 / 음자리표 | |
| tuning (A = 440) | 튜닝 | "Tuning (A4)" = 튜닝 (A4); "Tuning of A" = A 튜닝 |
| note lengths | 온음표, 2분음표, 4분음표, 8분음표, 16분음표, 32분음표 | dotted quarter = 점4분음표 |
| sharp / flat / natural | 올림표 / 내림표 / 제자리표 | accidental = 임시표; no sign = 기호 없음 |
| tie / dot / rest | 붙임줄 / 점 / 쉼표 | |
| top voice | 윗성부 | |
| scan | 스캔 | scans a day = 하루 스캔 횟수; scan limit = 스캔 한도 |
| read the notes (OMR) | 음표 읽기 | "Read from your scan" = 스캔에서 읽음 |
| fix notes | 음표 수정 | corrected = 수정됨; corrected by you = 직접 수정함 |
| mark start / mark end | 시작 표시 / 끝 표시 | my marks = 내 표시 |
| mark the excerpt (crop) | 발췌곡 영역 표시 | |
| loop | 반복 | loop my marks = 내 표시 구간 반복 |
| checked / verified | 확인됨 | checked transcription = 확인된 채보 |
| draft | 초안 | reviewer = 검수자; review (catalogue) = 검수 |
| curated (prose) | 사람이 작성 | AI-generated = AI 생성 |
| notes (text, all senses) | 노트 | |
| tier: core / common / occasional | 핵심 / 자주 / 가끔 | share = 비율; tier = 등급 |
| popular / very popular | 인기 / 매우 인기 | |
| server | 서버 | |
| account / sign in / sign out | 계정 / 로그인 / 로그아웃 | Sign in with Apple = Apple로 로그인; signed in with Apple = Apple로 로그인됨 |
| send feedback / report an error | 의견 보내기 / 오류 신고 | thanks (app to player) = 감사해요, never 고마워요 |
| scrambled install code | 뒤섞인 설치 코드 | |
| region | 지역 | 북미, 유럽 (독일어권), 유럽 (기타), 영국, 아시아·태평양, 기타 |
| instrument | 악기 | families: 현악, 목관, 금관, 팀파니와 타악기, 건반 |
| player (musician) | 연주자 | |
| orchestra | 오케스트라 | |
| review (mock audition results) | 결과 | "Finish and review" = 마치고 결과 보기; your verdict = 총평; overall = 종합 |
