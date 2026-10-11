# Auditioner — Plan of record

*Agreed with Milai Walker (product owner, professional cellist) through a grill-me
design interview, 2026-10-10. This file is the source of truth for **what** we are
building and **why**. `CLAUDE.md` holds the standing rules for **how** we build it.
Change a decision here only with Milai's say-so, in the same commit as the code that
depends on it.*

---

## 1. What Auditioner is (plain words)

An iPhone/iPad app that helps orchestral musicians — professionals, students and
amateurs — **prepare for orchestra auditions**.

**Hero feature:** scan or import your part → the app recognises the excerpt →
you get a **reference audio file** you can slow down and loop, the **orchestra
recording and a solo audition-style recording** cued to the excerpt, and an excerpt
page with **tempo, techniques to watch, history, common pitfalls**, and **how often
orchestras ask for it**.

Around it: a simple forScore-like reader (Apple Pencil markup + AirTurn pedal), practice
tools (metronome, drone, record & compare, mock audition), a feed of **open
auditions** with their repertoire lists, and "**My upcoming audition**" to track
readiness for a specific audition.

Sister project: **Tutti** (`milaiwalkerproject-ui/tutti`) helps people *find* an
orchestra and its auditions; Auditioner helps them *win the seat*.

---

## 2. Decision log

### Audience & scope
| # | Decision |
|---|---|
| A1 | Orchestra auditions only (not solo competitions / conservatory entrance) — for professionals **and** students/amateurs (youth, student, community, college placement auditions). |
| A2 | Instruments: Violin, Viola, Cello, Double Bass, Harp · Flute, Piccolo, Oboe, English Horn, Clarinet, E♭ Clarinet, Bass Clarinet, Bassoon, Contrabassoon · Horn, Trumpet, Trombone, Bass Trombone, Tuba · Timpani, Percussion (tagged snare/xylophone/glockenspiel/cymbals/bass drum/tambourine/triangle…) · Piano/Celesta. (21; no sax, euphonium, Wagner tuba, alto flute, organ.) |
| A3 | Excerpts are tagged by **position** (principal / assistant / section / utility; horn high/low; violin concertmaster solos). Onboarding asks instrument + position. |
| A4 | **Cello first** for content depth and review. Every other instrument gets a top-~10 draft set. Brass seeded from the MIT-licensed BrassXcerpts dataset (~800 records), every range re-checked. |
| A5 | Ages **13+** in the terms for now; lower later after a COPPA check. Everything works signed out. |
| A6 | Storefronts: **exclude mainland China, Russia, Belarus** (Claude unsupported, YouTube blocked, China ICP filing). **Hong Kong & Macau included with AI notes hidden.** (2026-10-11, in the app: the App Store storefront decides — HKG / MAC, read once at launch with StoreKit; when it is unknown, as in the simulator, the device region HK / MO decides. There, notes with origin `ai` and every machine translation are left out, curated notes show in English, and the Notes box says once "Some notes aren't available in your region.") |
| A7 | Languages (all in v1): English, Spanish, Simplified Chinese, Traditional Chinese, Italian, Russian, Japanese, Korean, German, French, Portuguese (BR). UI AI-translated and marked "beta translation" until a native speaker checks it; excerpt content translated by Claude on first open, cached, labelled "machine-translated"; **score markings stay in the original language** (tap for a translation). |
| A7b | (2026-10-11) The app's language follows the device's language setting (iOS picks it; Settings → Auditioner → Language can override it). Scans and parts are never translated or changed. Excerpt notes follow the device language too: their machine translations are prepared now, checked by code that every number, bar and marking survived unchanged, and are shown **from 12 Nov 2026** (the I2 date; one moment worldwide, 12:00 UTC, when it is 12 November everywhere), labelled "Machine-translated" with the AI label ("AI-generated — may contain errors, check against your part" — a translation is AI text, also of a curated note) and a "Show original" switch; until then notes appear in English. Work titles and score markings stay in the original language. |

### Platform & build
| # | Decision |
|---|---|
| P1 | Native **SwiftUI**, iOS/iPadOS **17+**, one universal app. iPad: music left, info/video right. |
| P2 | Milai builds on a **MacBook Air M5, macOS Tahoe 26.6.2** (current Xcode 27 OK; App Store uploads need Xcode 26+). Apple Developer account active. |
| P3 | Repo is **public** (free GitHub cloud-Mac build checks). Make it private before the App Store launch. |
| P4 | The cloud coding session has no Swift compiler → **every push is compiled by GitHub Actions on macOS**; Milai runs it from Xcode on the Mac/iPad. |
| P5 | Reader is deliberately simple: open PDFs/scans, **Apple Pencil markup**, **AirTurn** page turns. No setlists, half-page turns, links, face gestures, Cue, stamps/layers. Backup arrives with iCloud sync in v1.1. |

### Backend, accounts, money
| # | Decision |
|---|---|
| B1 | Small backend: **Supabase** (database + Sign in with Apple, same as Tutti) + **Google Cloud Run** for heavy jobs (note reading, crawler, Claude). One US region. |
| B2 | Login: **Sign in with Apple only**, optional, with a Skip button; **in-app account deletion** (revoke Apple token). Signed in = higher daily scan limit, credit for corrections, future purchases. |
| B3 | Server protected by **App Attest** + per-device daily limits (e.g. 30 scans/day). |
| B4 | Keys (Anthropic, YouTube, Google Cloud) live only in server secrets — never in the app or the repo. |
| B5 | Free during TestFlight, **no ads ever**. One-time vs subscription decided before the App Store. YouTube/Apple Music playback can never sit behind a paywall. |
| B6 | EU trader status: **non-trader** while free; switch before charging. |
| B7 | Expected costs: Supabase Pro ~$25/mo once testers arrive; Cloud Run ~$0–20/mo early; AI catalogue ~$300–600 one-time; feed extraction ~$450–900/yr; cello recording pilot ~$500–1,500 (later). |

### Excerpt data & IMSLP
| # | Decision |
|---|---|
| D1 | **IMSLP is not our database.** It is used for (1) work identity/facts, (2) a "Get this part on IMSLP" link — the user downloads the PDF themselves and imports it, (3) showing IMSLP's per-country copyright label with a warning. We never download, store or redistribute IMSLP files. Written permission requested before App Store. |
| D2 | Our own catalogue is built from **facts only**: orchestras' published audition lists (bar numbers, rehearsal marks) + published frequency studies as cross-checks + Wikidata/Open Opus (CC0). Never copy excerpt-book engravings, bowings, fingerings or anyone's prose. |
| D3 | **Honesty contract** (adopted from Tutti): a fact is `verified` (value + source + asOf) or `unverified` ("Check the official list"), never a guess. |
| D4 | Each excerpt has a **standard bar range plus variants** seen on real lists; the user can set the exact bars for *their* audition. |
| D5 | Recommendations: "What orchestras ask" = recency-weighted frequency (3-year half-life) per instrument + position + region, blended with published studies; always shows its evidence ("asked in 68% of 41 section-cello lists, 2023–2026"). Separate badge: "**On N open auditions now**". Tiers: Core ≥50%, Common 20–50%, Occasional. Region tag, defaulting to the user's region. |
| D6 | "Popular with cellists" (community trend) is **opt-in, off by default**, uploads only {instrument, excerpt IDs, week}, shown only with **≥20 contributors**, as tiers not counts, hidden for under-18s, and never mixed into "what orchestras ask". |
| D6b | (2026-10-11) Popularity is shown only to players who share what they practise (they confirmed they are 18 or older). Signed-in players get **60 scans a day**, signed-out 30. |

### Reference audio, note reading
| # | Decision |
|---|---|
| R1 | **Identify first, read notes second**: for catalogued excerpts serve checked MusicXML + audio; note reading (OMR) handles the rest and helps recognition. |
| R2 | OMR runs **on our server** (AGPL engines, unmodified, separate process): **homr** for photos, **both homr + Audiveris** for clean PDFs (best validation wins), **Audiveris** for percussion and parts needing bowings/8va/dynamics. Percussion/harp/keyboard labelled beta. Meter never taken from homr. |
| R3 | Expect ~90–97% notes right from clean PDFs, fewer from photos → a **correction editor** is core (tap a note ↔ highlight on the scan, pitch/accidental/duration/tie/triplet edits, red badge on bars that don't add up, play-from-here with highlighting). Your **original scan stays the main view**. |
| R4 | Sounds: **GeneralUser GS** bundled for on-device playback (tempo slider, loops, count-in, A=440/442); server renders the downloadable audio file; VSCO-2 (CC0) upgrade after listening tests. Transposition comes from the key printed on the part, never from the user's instrument profile. |
| R5 | Scans: consent screen on first upload; deleted from the server right after processing (≤24 h); opt-in donation to improve recognition. |

### Recordings
| # | Decision |
|---|---|
| M1 | **YouTube** official embedded player for everyone (orchestra + solo clips, one player per screen), with "Open in YouTube" fallback; **Apple Music** for subscribers (exact start/end, offsets keyed by ISRC); **link-outs** to IDAGIO / Presto / medici.tv / Digital Concert Hall / Naxos; a small library of **free-licence orchestra recordings we host** (PD/CC0/CC BY/BY-SA, clear in US+EU) that can be slowed, looped and score-followed. No Spotify. |
| M2 | Never touch YouTube audio or build data from YouTube description text. Timestamps: curated + **user "mark start/end" taps** (verified at 3 users within 1.5 s or 1 curator); a live **starting guess** from the bar position (never stored). |
| M3 | Slow-down/loop/score-following only on our own audio, free-licence recordings and the user's own (non-DRM) files; YouTube gets only its own speed control + A–B loop. |
| M4 | v1.x: find the excerpt automatically inside the user's own recordings (on-device alignment). Later: **commissioned cello recordings** (hired player, full-rights contract, public-domain works first). |

### AI content
| # | Decision |
|---|---|
| I1 | Claude writes long-tail excerpt notes **offline, in batch, from facts we supply** (no user data in prompts), stored once and shared. Labelled "AI-generated — may contain errors, check against your part", thumbs up/down + "Report an error". Human-checked pages get a **Curated** badge. |
| I2 | Until **12 Nov 2026** (Anthropic usage policy in force) nothing AI-written is shown unreviewed. Milai reviews cello. |

### Open auditions feed & My upcoming audition
| # | Decision |
|---|---|
| F1 | Sources: **orchestras' own public audition pages** + user uploads only. Aggregators (AFM *International Musician*, League job board, Musical Chairs, muvac, OrchestraPLAN, Audition Cafe, Facebook groups) are never read automatically; licensed partnerships later. Polite crawler rules published in `BOT.md`; facts + link only; no PDFs or staff names/emails stored. |
| F2 | Registry ≈ **250 sources**: ICSOM, ROPA and other US orchestras, major Canadian, top UK/DE/FR/IT/ES/NL/Nordic, Japan Orchestra Federation, 6 Australian, HK Phil, Singapore SO, and youth orchestras (Tutti's 24 first). Cello lists checked first. |
| F3 | **Milai reviews every extracted list** for the first ~200, then auto-publish high-confidence with 10% spot checks, via a simple admin page. |
| F4 | **My upcoming audition**: pick from the feed or add manually; attach the full list (Files incl. Google Drive/iCloud/Dropbox, Photos, camera, Share sheet, pasted link) → checklist matched to excerpts → readiness, countdown, practice plan, deadline reminders. File deleted after reading. Private by default; opt-in to share only which excerpts were listed. |
| F5 | (2026-10-11) Feed and "My upcoming audition" details, Milai's answers: chair words on lists map concertmaster and high horn → principal, utility/any → section, "second" → section on strings and other elsewhere, low/third horn → other. "On N open auditions now" counts every region and every chair. An audition leaves the open list the day after its deadline (it stays in My upcoming audition). A published audition whose page changes goes back to review. One list = source address + year + chair. Matches ≥ 90 % with no close runner-up are pre-ticked; the rest wait for a tap. Reminders 7 days and 1 day before the deadline and the audition, 9:00. Deleting an audition **archives** it (restorable; delete for good from the archive). The Auditions tab offers **All regions** as well as the player's region. Brass catalogues (no chair on their lists) default to **Include all chairs** on. The readiness ring counts only "Nearly there" (4) and "Audition-ready" (5) as ready. |

### Practice tools
| # | Decision |
|---|---|
| T1 | v1: metronome (subdivisions, accents, saved per excerpt), drone, record & compare vs reference at the same tempo, **mock audition** (random order, hidden titles, timer, one continuous recording, self-rating). v1.x: tuner, practice log charts. |
| T2 | (2026-10-11) Record & compare plays a count-in only when the player's Count-in switch is on. Metronome keeps its tempo-marking hints, labelled "rough guide". The note editor marks a short first bar red unless the file marks it as a pickup. Saving a correction keeps both the original reading and the corrected copy. Once the server is deployed, its address is built into the app so testers don't paste it. |

### Tutti
| # | Decision |
|---|---|
| U1 | **v1:** links both ways ("Prepare in Auditioner" on Tutti audition cards; "Find an orchestra near you" → Tutti) and the shared honesty contract. |
| U1b | (2026-10-11) Tutti's site **https://tutti-orchestra.com** is live: "Find an orchestra near you" links there. Auditioner has no website of its own for now, so Tutti links into the app with `auditioner://` links (`docs/TUTTI.md`). |
| U2 | **v1.x:** Auditioner's crawler proposes Tutti audition-window updates as `provenanceType: scraped`, `listingStatus: in_review` drafts **for Milai to approve**; Tutti's orgs join the crawl registry. |
| U3 | Later: brand family, shared accounts, Tutti map inside the app. |

### Working agreement
| # | Decision |
|---|---|
| W1 | Feature branches → cloud-Mac build check → self code review → plain-words summary with try-it steps → **Milai approves every merge**. |
| W2 | Working name **"Auditioner"**; check App Store + trademark availability before launch. |

---

## 3. Architecture

```
iPhone / iPad app (SwiftUI, iOS 17+)                     Server
┌────────────────────────────────────────┐        ┌─────────────────────────────────┐
│ Catalog (bundled snapshot + updates)   │◀──────▶│ Supabase: catalogue, timestamps,│
│ Excerpt page · recordings · notes      │        │ auditions feed, users, votes    │
│ Scan/import → crop → OCR (Vision)      │───────▶│ Cloud Run "api": identify, OMR  │
│ Notation (Verovio in WKWebView)        │◀───────│ (homr / Audiveris), render audio│
│ Playback (AVAudioEngine + SoundFont)   │        │ Cloud Run jobs: crawler, Claude │
│ Reader (PDFKit + PencilKit + AirTurn)  │        │ batch notes, feed extraction    │
│ Practice tools · My audition           │        └─────────────────────────────────┘
│ Local data: SwiftData + files          │
└────────────────────────────────────────┘
```

**Repo layout**

```
ios/Auditioner.xcodeproj        Xcode project (folder-synchronised groups: add files, no project edits)
ios/Auditioner/                 app source — App/, Core/, Features/<Feature>/, Resources/
ios/AuditionerTests/            unit tests
backend/                        Python 3.12 FastAPI service + Dockerfile + tests
supabase/migrations/            Postgres schema (append-only)
content/catalog/                excerpt catalogue source of truth (JSON) + schema
docs/                           SETUP (accounts), TESTFLIGHT, BOT.md, privacy policy drafts
.github/workflows/              ios.yml (macOS build + tests), backend.yml (pytest)
```

**Catalogue contract.** `content/catalog/*.json` validated by
`content/schema/catalog.schema.json`; the app bundles a snapshot and fetches newer
versions. Volatile facts use the Tutti shape
`{status: verified|unverified|not_applicable, value?, source?, asOf?}`. Prose blocks
carry `origin` (curated | ai), `reviewStatus` (draft | approved) and are hidden unless
approved.

---

## 4. Milestones

| | Milestone | Contents | Testers? |
|---|---|---|---|
| **M0** | Setup | Xcode project, cloud-Mac build + tests, backend skeleton + tests, catalogue schema, first run on Milai's Mac/iPad | — |
| **M1** | Hero, cello | Scan/import → crop → recognise → reference audio with tempo/loop/count-in + note highlighting → excerpt page → YouTube/Apple Music clips; cello catalogue (review-gated) | first TestFlight (internal) |
| **M2** | Notes & reader | Note-reading for unknown excerpts + correction editor; Apple Pencil markup; AirTurn | |
| **M3** | Practice | Metronome, drone, record & compare, mock audition | |
| **M4** | Auditions | Open-auditions feed, My upcoming audition, recommendations, admin review page | |
| **M5** | Launch prep | Sign in with Apple + deletion, community trends, 11 languages, privacy policy, Tutti links → external TestFlight | public TestFlight |

**Status (2026-10-10):** M0 done. M1 built and green on the cloud Mac (Xcode 26.3,
101 unit tests passing): scan/import → crop → recognise → reference audio with
notation highlighting; excerpt pages with YouTube/Apple Music; My parts with Apple
Pencil + AirTurn; onboarding and settings. Apple Pencil markup and AirTurn (planned
for M2) shipped early in M1. Server (note reading, identify, catalogue, limits,
Cloud Run deploy) built with 167 tests; not yet deployed. Catalogue: 19 cello
excerpts reviewed and published by Milai; 806 BrassXcerpts excerpts published with
the "Imported — bars not yet checked" label (Milai's decision). Privacy policy in
`docs/PRIVACY.md`; there is no public contact email — users reach us through the
in-app "Send feedback" / "Report an error" (Milai's decision, 2026-10-11).

**Status (2026-10-11):** M3 practice tools built (metronome, drone, record & compare,
mock audition, My recordings); the M2 note-correction editor built (scan beside the
notes, pitch/accidental/duration/rest/tie/insert/delete, bar check, undo); in-app
feedback built end to end (queued on the device, stored in a separate Auditioner
Supabase project via the server). M4 backend built: polite crawler, Claude list
extraction with code verification, Supabase schema with RLS, 128-orchestra registry
(80 confirmed audition pages). M4 app screens built: an Auditions tab with open
auditions from the feed and "My upcoming audition" (add from the feed, the catalogue,
a typed line or a list read on the device, readiness per excerpt, practise-next,
reminders, mock audition from the list); "Most asked for your chair" in the excerpt
browser, counted on the device from the catalogue's lists or from the server
(`/v1/auditions`, `/v1/recommendations`). Next: M5.

**Status (2026-10-11, later):** M5 built, not yet merged. Sign in with Apple (B2): optional,
Skip always possible, server checks Apple's token itself and stores only a keyed hash
of Apple's id, an encrypted refresh token (used only to revoke on deletion), dates
and session hashes — no name, no email; in-app Delete account revokes at Apple and
deletes everything at once; signed-in scans get a higher daily limit (60 vs 30).
Community trends (D6): off by default, 18+ question, uploads only instrument + week
+ catalogue excerpt ids under a keyed device hash, kept 26 weeks, shown from 20
players as two tiers, never counts, kept apart from "what orchestras ask". Tutti
links (U1): `auditioner://excerpt/<id>` and `auditioner://audition/new?…` prefill
the New audition form, nothing saved until Add; the "Find an orchestra near you" row
links to https://tutti-orchestra.com (U1b; `docs/TUTTI.md`).
Localisation (A7): string catalogue, Info.plist strings, Language row and "Beta
translation" tag are in place, and all 850 app strings plus the permission prompts
are machine-translated into the 10 other languages, each reviewed by a second pass
(`ios/l10n/README.md`); the 76 approved cello notes are translated too, shown from
12 Nov 2026 (A7b). A native speaker's check is still to come. Privacy policy v0.3
(`docs/PRIVACY.md`) and the in-app Privacy page describe accounts and trends. Two
Supabase migrations (`20261012000000_accounts.sql`, `20261012010000_trends.sql`).

Still needs Milai: (1) read and approve `docs/PRIVACY.md` v0.3 — it is a promise to
users; (2) Apple Developer: switch on Sign in with Apple for the bundle id, create
the `.p8` key and run `docs/SETUP.md` step 8; (3) apply the two migrations and
redeploy with Supabase so trends get their salt (`docs/SETUP.md` step 7); (4) Tutti's
https address for the Settings row; (5) answers to the builders' open questions
(who sees the popularity lists; whether "Play" alone counts as practised; whether B1
"Supabase handles Sign in with Apple" is fine as "our server checks Apple's token"
instead; TestFlight before App Attest); (6) the translations and the external
TestFlight build (`docs/TESTFLIGHT.md`).

Milai wants testers (orchestra/tour colleagues) as early as possible, so M1 aims at an
**internal TestFlight** build: the app works offline for catalogue, excerpt pages,
recordings and reader; scanning needs the server to be deployed (see `docs/SETUP.md`).

---

## 5. What Milai sets up (once)

1. **Google Cloud** project with billing → Cloud Run + YouTube Data API key.
2. **Anthropic API** account → key for the server.
3. **Supabase** project (same account as Tutti).
4. **App Store Connect**: app record (bundle ID `com.milaiwalker.auditioner` unless
   changed), TestFlight internal testers.
Step-by-step instructions live in `docs/SETUP.md` and `docs/TESTFLIGHT.md`.

---

## 6. Before the App Store (not needed for TestFlight)

- Re-verify facts the research could not confirm (search cap / blocked sites): IMSLP
  forum ban policy, 15-second wait, membership prices; forScore and competitor details;
  aggregator terms; survey statistics (read primary documents before showing any).
- Written permission from IMSLP (API use, name/logo, link-out + import flow).
- Notify indexed orchestras with an opt-out; keep a permission log (guideline 5.2.2).
- Legal review: privacy policy (EU/UK, Japan APPI, Korea PIPA, Brazil LGPD), YouTube
  30-day API-data rule and user-marked timestamps, hosted free-licence audio by country,
  commissioned-recording contract, AGPL server use.
- Privacy manifest + App Privacy label, age-rating questionnaire, Declared Age Range
  (iOS 26+), EU DSA trader status, App Store name/trademark check, make repo private.
