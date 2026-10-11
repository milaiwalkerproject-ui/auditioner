# Auditioner API (backend)

The small server behind **Scan my part**: it reads a photo of a page with
[homr](https://github.com/liebharc/homr), tidies the MusicXML for the app, matches
printed text against the excerpt catalogue, serves the catalogue files, and passes
the reviewed open-auditions feed and "What orchestras ask" on to the app.
Python 3.12 · FastAPI · uvicorn · runs on Google Cloud Run (one US region).

The iOS client contract is `ios/Auditioner/Core/Networking/APIClient.swift`; keep
the two in step.

## Endpoints

| Method & path | Request | Response |
|---|---|---|
| `GET /healthz` | — | `{"status":"ok","engine":"homr","version":"0.1.0"}` |
| `POST /v1/omr` | multipart: `image` (JPEG/PNG), `instrument` (catalogue id, e.g. `cello`), `transposition` (int semitones written→sounding, default 0), `meter` (optional, `3/4`), `hints` (JSON array of OCR text lines). Header `X-Device-Id` required. | `{"musicxml": "<?xml …", "warnings": ["…"], "engine": "homr", "measures": 12}` |
| `POST /v1/identify` | JSON `{"ocrText": "…", "instrument": "cello"}` | `{"candidates": [{"excerptId": "…", "score": 0.63}, …]}` — top 5, score 0‒1 |
| `POST /v1/feedback` | JSON `{"context": "excerpt-note:pitfalls", "excerptId": "…"?, "message": "…", "appVersion": "0.1"?}` — `context` 1–64 chars of `a-z 0-9 : -`, `excerptId` ≤ 128, `message` 1–2000 chars after trimming, `appVersion` ≤ 32. Header `X-Device-Id` required. | `201 {"status": "received"}` — the row is in the Supabase table `feedback` (see below) |
| `GET /v1/catalog/{instrument}` | optional `If-None-Match` | the `content/catalog/<instrument>.json` file with an `ETag` (304 when unchanged); 404 if there is no file |
| `GET /v1/instruments` | — | `{"instruments": ["violin", …]}` (handy for checks) |
| `GET /v1/auditions?instrument=cello&region=uk` | `instrument` (catalogue id, required), `region` (optional; absent = every region) | `{"auditions": [FeedVacancy]}` — open, published auditions only (see below) |
| `GET /v1/recommendations?instrument=cello&position=section&region=uk` | `instrument`, `position` (the app's position id), `region` (optional; absent = every region) | `{"recommendations": [Recommendation]}` — most asked first, from published lists only (see below) |
| `POST /v1/trends` | JSON `{"instrument": "cello", "week": "2026-W41", "excerptIds": ["…"]}` — this or last ISO week (UTC), at most 50 ids. Header `X-Device-Id` required. | `204` — community trends, opt-in (see "Community trends" below) |
| `DELETE /v1/trends` | header `X-Device-Id` | `204` — everything this device shared is deleted |
| `GET /v1/trends?instrument=cello` | `instrument` (catalogue id) | `{"enough": true, "fromWeek": "2026-W34", "toWeek": "2026-W41", "trends": [{"excerptId": "…", "tier": "very-popular"}]}` — tiers only, never counts |
| `POST /v1/account/apple` | JSON `{"identityToken": "…", "authorizationCode": "…", "nonce": "<raw nonce>"}` from Sign in with Apple | `{"accountId": "<uuid>", "sessionToken": "…", "dailyScanLimit": 60}` (see "Accounts" below) |
| `GET /v1/account` | header `Authorization: Bearer <sessionToken>` | `{"accountId": "…", "dailyScanLimit": 60, "createdAt": "YYYY-MM-DD"}` |
| `POST /v1/account/signout` | Bearer | `204` — this session only |
| `DELETE /v1/account` | Bearer | `204` — Apple token revoked, then the account and all its sessions deleted |

Errors are always JSON `{"detail": "plain words for a musician"}` and nothing else
in the body — the app decodes it as a flat `[String: String]` dictionary:

| Status | When |
|---|---|
| 400 | missing `X-Device-Id`, unknown instrument, bad meter / transposition / hints, or a picture claiming over 50 megapixels; for `/v1/feedback` also a blank message or one over 2000 characters after trimming; for `/v1/auditions` and `/v1/recommendations` a missing or unknown instrument, position or region |
| 401 | `/v1/account…`: no, malformed, unknown or expired Bearer session — `"You're signed out. Sign in again."` (never on `/v1/omr`: a bad token there just means the device limit) |
| 413 | upload over 15 MB (refused by Content-Length before reading, or cut off while a chunked body streams in) |
| 415 | the file isn't a JPEG/PNG (or another picture Pillow can read) |
| 422 | a field is missing or has the wrong type (for `/v1/feedback`: `context` outside `[a-z0-9:-]{1,64}`, over-long fields) |
| 429 | daily scan limit reached for this device (`/v1/omr`), or daily feedback limit (`/v1/feedback`, `DAILY_FEEDBACK_LIMIT`) |
| 500 | homr failed or produced nothing readable (or any unexpected server error) |
| 502 | `/v1/feedback`: Supabase did not take the row (unreachable, refused, table missing) — not charged. `/v1/auditions`, `/v1/recommendations`: `"The auditions feed didn't answer. Try again in a few minutes."` — Supabase unreachable, refused (e.g. the auditions migration isn't applied) or sent something unexpected |
| 503 | the instance is busy: the short queue is full, or the scan could not start within `OMR_QUEUE_WAIT_SECONDS` — `Retry-After: 60`, not charged. For `/v1/feedback`: `"Feedback isn't set up on the server yet."` while `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` are not set (the app keeps the report queued). For `/v1/auditions` and `/v1/recommendations`: `"The auditions feed isn't set up on the server yet."`, same condition (parameters are checked first, so a bad one is still a 400) |
| 504 | homr ran past `OMR_TIMEOUT_SECONDS` |

### What `/v1/feedback` does with a message

`app/feedback.py`. In-app "Report an error" / "Send feedback" — there is no public
contact email. After validation and the per-device daily limit (20, a separate
`DailyLimiter` from the scan one), one PostgREST insert goes to
`SUPABASE_URL/rest/v1/feedback` with the service-role key (`apikey` +
`Authorization: Bearer`, `Prefer: return=minimal`, httpx, 10 s timeout). The table
(`supabase/migrations/20261011000000_feedback.sql`) has RLS on and **no policies**,
so only the service role can read or write it. Privacy rules the code keeps:

- the **message body is never logged** — the one log line is
  `feedback stored context=… excerpt=… chars=…`; Supabase failures log only the
  status code or the exception class (PostgREST error bodies can quote values);
- the **raw device id is never stored** — the row carries
  `device_hash = sha256(FEEDBACK_HASH_SALT + X-Device-Id)`. If `FEEDBACK_HASH_SALT`
  is empty the salt falls back to `"auditioner-feedback:" + SUPABASE_URL` — fixed per
  deployment (hashes stay stable across restarts, differ per Supabase project) but
  guessable, so set a real salt before public TestFlight; the server logs one warning
  at start-up while the fallback is in use;
- a failed insert (502) refunds the device's daily allowance; an unconfigured server
  (503) never charges it.

### What `/v1/auditions` and `/v1/recommendations` read

`app/feed.py`. Read-only, from the Auditioner Supabase project — the same
`SUPABASE_URL` + service-role key as feedback; the schema is
`supabase/migrations/20261011010000_auditions.sql` and the pipeline that fills it is
`docs/FEED.md`. The service role bypasses row level security, so **every query asks
for published data itself**. Shapes are the fixed `FeedVacancy` / `FeedVacancyItem` /
`Recommendation` in `ios/Auditioner/Core/Networking/APIClient.swift`; every
non-optional Swift field is always present with the right JSON type (a row that
cannot fill one is left out and logged, rather than breaking the whole answer).

**Parameters.** `instrument`: one of the 22 catalogue ids (`/v1/instruments`).
`position`: one of the app's `principal`, `assistant-principal`, `section`, `utility`,
`second`, `high`, `low`, `concertmaster`, `any`. `region`: `north-america`,
`europe-german`, `europe-other`, `uk`, `asia-pacific`, `other`, or absent/empty for
every region. Anything else is a 400 in plain words. No `X-Device-Id` is needed (read
only, cached); nothing about the device or the person is sent to Supabase.

**`/v1/auditions`** — one GET on the `open_auditions` view (published vacancies with
their orchestra's registry facts) for the instrument (and region), narrowed to
auditions **still open**: a deadline from yesterday (UTC) on — so a deadline that is
still today somewhere in the world stays listed — or no deadline and seen on the
orchestra's page in the last 60 days (the window of the `excerpt_open_now` view).
Soonest deadline first (no deadline last), at most 500. Every id the view returns is
then checked against the `vacancies` **table** itself (`review_status=eq.published`
and the same instrument): the view already filters on published, but the service
role skips row level security, so this second lock keeps an unpublished audition out
of the app even if the view is ever redefined (a mismatch is left out and logged).
Then `vacancy_items` with `review_status=eq.published` for exactly the checked
vacancies (20 ids per request, paged at 1,000 rows — Supabase's default maximum), in
list order. A vacancy id appears at most once in an answer.

| field | from |
|---|---|
| `id` | the vacancy's uuid |
| `orchestra`, `orchestraId`, `region` | the registry entry (the name falls back to the id) |
| `position` | as printed; the chair is added in brackets when it says more ("Horn (Third horn)") |
| `instrument` | catalogue id |
| `applicationDeadline` | `YYYY-MM-DD`, or null when the source gives none we could verify |
| `auditionDates` | the verified dates, `YYYY-MM-DD`, sorted, duplicates removed; anything that is not a real calendar date is dropped, never guessed |
| `listCompleteness` | `full` · `partial_public` · `works_only` · `revealed_on_invitation` · `unknown` |
| `sourceURL` | the orchestra's own page or document (always http/https; uploaded lists never reach the feed) |
| `lastCheckedAt` | `YYYY-MM-DD` of `last_seen_at`: the last night the crawler found this vacancy's source still there (unchanged, or re-read) |
| `items` | published items only: `rawText` (the source line, verbatim), `category` (`solo` · `excerpt` · `sight_reading` · `chamber` · `other`), `round` (`""` when the list doesn't say), `excerptId` (null when not matched to the catalogue) |

**`/v1/recommendations`** — the app's position is mapped to the database's coarse
position class (below), then `POST rpc/excerpt_recommendations` (recency-weighted
frequency, 3-year half-life, blended with the all-regions share as a prior, k = 10 —
PLAN D5) and one GET on `excerpt_open_now` for the "On N open auditions now" badge.
Without a region the function has nothing to answer with, so the server sums the
`excerpt_frequency` view over every region instead; there the blend changes nothing
(the prior *is* the all-region share), and the tier uses the same thresholds.

| field | meaning |
|---|---|
| `excerptId` | catalogue id, most asked first |
| `tier` | `core` (≥ 50 %) · `common` (20–50 %) · `occasional` |
| `share` | 0–1, 4 decimals: the recency-weighted, blended share the tier comes from (the function's `score`) |
| `listCount` / `totalLists` | published lists in that region and position class that include the excerpt / all of them (plain counts) |
| `openNow` | open auditions for this instrument that list it now — any region, any position (`excerpt_open_now`) |
| `evidence` | a plain line written from those counts only: "On 7 of 12 section cello lists in North America, 2024–2026" · "Not on any of the 4 principal horn lists we have in the UK — the tier comes from other regions" · "No section cello lists in Asia-Pacific yet — the tier comes from other regions" · without a region "… across all regions, …". The function's own `evidence` column (ids such as `north-america`) is not used. |

| app position | database class | why |
|---|---|---|
| `principal`, `concertmaster` | `principal` | `position_class()` files "Concertmaster" under principal |
| `high` (horn) | `principal` | "Principal Horn" lists; "Third Horn" lists are classed `other` |
| `assistant-principal` | `assistant-principal` | |
| `section`, `utility` | `section` | `position_class()` files "Utility" under section |
| `second` on violin, viola, cello, double bass | `section` | "Section Second Violin" |
| `second` on any other instrument | `other` | "Second Oboe", "2nd Trumpet" |
| `low` (horn) | `other` | "Second Horn", "Fourth Horn" |
| `any` | `section` | not offered in onboarding; section lists are the broadest set |

Each evidence line names the class it counted ("principal horn lists", "oboe lists for
second and other chairs"), so the mapping never claims more than the lists show.

**Cache and errors.** Answers are kept in memory for **10 minutes per query** (per
Cloud Run instance; a failed answer is never kept), so something Milai publishes or
unpublishes reaches the app within ten minutes. 503 while Supabase isn't configured;
502 when it is unreachable (including a malformed `SUPABASE_URL`), answers with an
error, or sends something that isn't a list of rows — only the status code or the
exception class is logged, never PostgREST's error body.

**What rests on the database views.** `/v1/recommendations` sends only counts and
excerpt ids, never a vacancy or an item; those counts come from `excerpt_frequency`,
`excerpt_recommendations` and `excerpt_open_now`, which count published lists and
published items only. Unlike `/v1/auditions` there is no row to re-check, so a change
to those views must keep their `review_status = 'published'` filters. Two known gaps
of the views as written (migration `20261011010000`): a region and position class
whose published lists have **no** item matched to the catalogue yet does not appear in
`excerpt_frequency` at all, so its lists are missing from `totalLists` (the function
then says "No … lists … yet" for that region, and the every-region sum leaves them
out); and `excerpt_open_now` counts a deadline as open up to *today* (database time),
while the feed keeps it one day longer.

### Community trends (`/v1/trends`)

`app/trends.py`. "Popular with cellists" (PLAN D6): **opt-in in the app, off by
default**, shown only with **at least 20 contributors**, as **tiers, never counts**,
hidden for under-18s and never mixed into "What orchestras ask" (those last two are the
app's job). Same `SUPABASE_URL` + service-role key as the feed, plus `TRENDS_SALT`;
the table is `trend_contributions`
(`supabase/migrations/20261012010000_trends.sql`, RLS on, no policies, service role
only).

**What is stored.** One row per contributor + instrument + ISO week: the instrument,
the excerpt ids, the week, `updated_at`. The contributor is
`HMAC-SHA256(TRENDS_SALT, X-Device-Id)` (hex) — the raw device id is never stored,
sent to Supabase or logged, and neither the hash nor the salt is ever logged (httpx's
own request log line has the hash blanked out). **Never change `TRENDS_SALT` once it
is set**: rows hashed with the old salt can no longer be found, so a player who turns
sharing off could not have them deleted (the 26-week retention would still remove
them). `deploy.sh` creates it once and refuses to replace it.

**`POST /v1/trends`** — checks, in order: `X-Device-Id` (400), `instrument` (one of
the 22 ids, 400), `week` (`YYYY-Www` with ASCII digits and a capital W; a real ISO week —
`2025-W53` is not one; and only **this week or last week, reckoned in UTC** — 400 in
plain words otherwise), at most **50** `excerptIds` (more → 400, nothing stored), then
503 while not set up. Excerpt ids the **server catalogue** does not list for that
instrument are dropped silently: `Catalog.excerpts` — the `content/catalog/<instrument>.json`
file baked into the image, `published` only (drafts too when `INCLUDE_DRAFTS=1`); an
instrument without a catalogue file keeps nothing. Repeats and blanks are dropped,
the rest sorted, and the row is **upserted** (PostgREST `on_conflict` +
`Prefer: resolution=merge-duplicates`), replacing that week's earlier post. If no
known id is left, that week's row is **deleted** instead (an empty list is never
stored). 204, no body.

**`DELETE /v1/trends`** — deletes every row of that contributor, every instrument and
week (the app calls it when the player turns sharing off). 204.

**`GET /v1/trends?instrument=`** — no device id needed. Reads the 8 most recent ISO
weeks, the current one included (`fromWeek`…`toWeek`), paged at 1,000 rows. A
contributor counts once however many weeks they shared; an excerpt counts once per
contributor who listed it. `enough` is true from **20 distinct contributors**; below
that `trends` is `[]`. Otherwise each excerpt still in the catalogue gets a tier from
the share of contributors who listed it — `very-popular` ≥ 40 %, `popular` ≥ 15 %
(whole-number maths: 8 of 20 is exactly 40 %), left out below — sorted by tier, then
by excerpt id, so not even the ranking within a tier leaks. **No counts or shares are
ever in the answer.** Kept in memory for **an hour** per instrument and week (per
instance; a failed answer is never kept) and sent with
`Cache-Control: public, max-age=3600`.

**Retention.** Rows for weeks more than 26 weeks before the current one are deleted
(`DELETE …?week=lt.<cutoff>`; the fixed-width week text sorts in week order), at most
once an hour per instance, on any `/v1/trends` request. A failed retention delete is
logged and retried on the next request; it never fails the request itself.

**Errors.** 400 as above; 422 when `excerptIds` is not a list of strings; 502
`"Practice trends didn't answer. Try again in a few minutes."` when Supabase is
unreachable, refuses (e.g. the migration isn't applied) or sends something
unexpected — only the status or exception class is logged; 503 `"Sharing what you
practise isn't set up on the server yet."` while `SUPABASE_URL`,
`SUPABASE_SERVICE_ROLE_KEY` or `TRENDS_SALT` is missing (parameters are checked first,
so a bad one is still a 400).

**Known limits.** Device ids are minted by the app, so someone determined could post
as many "contributors" as they like and push an excerpt up a tier; the 20-contributor
floor and the coarse tiers limit what that achieves, and App Attest (PLAN B3) is the
real fix. Counting is per Supabase project, not per Cloud Run instance; only the cache
and the retention timer are per instance.

### Accounts (`/v1/account…`, Sign in with Apple)

`app/accounts.py` (Apple, crypto, Supabase, sessions) and `app/accounts_api.py`
(routes, scan limit). PLAN B2: optional — every part of the app works without an
account; signing in only raises the daily scan limit for now — and deletable in the
app, which revokes Apple's token. Off (503 `"Accounts aren't set up on the server
yet."`) until `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY`, `ACCOUNT_SECRET`,
`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are all set, the key reads as an EC
P-256 `.p8` and `ACCOUNT_SECRET` is at least 32 characters (the server logs which
names are missing, never values). Tables: `supabase/migrations/20261012000000_accounts.sql`.

**Signing in** (`POST /v1/account/apple`):

1. The identity token is checked: RS256 against Apple's keys
   (`https://appleid.apple.com/auth/keys`, kept 24 h; a token signed with a key id we
   haven't seen makes the server look again, at most once a minute; if Apple can't be
   reached the last good set is used), issuer `https://appleid.apple.com`, audience
   `APPLE_BUNDLE_ID`, not expired (60 s leeway for clocks), and its `nonce` claim must
   be the sha256 hex of the raw `nonce` in the request (the app sends Apple the hash
   and us the raw value). Anything wrong → 400 `"Apple couldn't confirm this sign-in.
   Try signing in again."`
2. The one-time `authorizationCode` is swapped at `https://appleid.apple.com/auth/token`
   with a client secret the server signs per call (ES256 with the `.p8` key: `iss` =
   Team ID, `sub` = bundle id, `aud` = `https://appleid.apple.com`, `kid` = Key ID,
   5 minutes). An expired or used code → 400; the `id_token` Apple returns must name
   the same user. Apple unreachable, refusing our client secret or answering without
   a refresh token → 502 `"Couldn't reach Apple to finish signing in. Try again in a
   few minutes."` — and **nothing is stored**.
3. One upsert into `accounts` keyed on `apple_sub_hash = HMAC-SHA256(ACCOUNT_SECRET,
   sub)` (a returning player gets the same account; the newest refresh token replaces
   the old one), then a session: `secrets.token_urlsafe(32)` goes to the app, only its
   sha256 hex goes into `account_sessions`. Sessions unused for 365 days are deleted on
   the next sign-in. Supabase trouble → 502 `"Our account store didn't answer. …"`.

**Using a session.** `Authorization: Bearer <sessionToken>`. `last_used_at` (and the
account's `last_seen_at`) are written at most once a day. A session unused for 365
days → 401 and it is deleted.

**Deleting** (`DELETE /v1/account`): the stored refresh token is decrypted and
revoked at `https://appleid.apple.com/auth/revoke` (`token_type_hint=refresh_token`);
only when Apple confirms (or says the token was already invalid) are the account and
— by `on delete cascade` — all its sessions deleted. Apple unreachable or refusing →
502 `"Couldn't reach Apple to finish deleting your account. Try again in a few
minutes."` and nothing is deleted. One exception: if the stored token can't be
decrypted (only possible after `ACCOUNT_SECRET` changed) it can never be revoked by
us, so the account is deleted anyway and a warning is logged.

**What is kept.** Per account: the HMAC of Apple's user id (never the id), the
refresh token encrypted with Fernet (key = HKDF-SHA256 of `ACCOUNT_SECRET`), two
dates. No email, no name — the app doesn't ask Apple for them. Per session: the
sha256 of the token and two dates. Log lines carry only HTTP status codes, Apple's
fixed error codes and exception class names — never a token, code, nonce, refresh
token, Apple id or secret (`tests/test_accounts.py` checks this). Answers carrying a
session token are sent with `Cache-Control: no-store`.

**`ACCOUNT_SECRET` must never change** once players have signed in: a new value
gives every returning player a fresh, empty account (their old one is orphaned) and
makes the stored refresh tokens unreadable, so deleting an old account can no longer
revoke Apple's token.

**Scan limit.** A `/v1/omr` request with a valid Bearer session counts against a
per-account allowance (`SIGNED_IN_DAILY_SCAN_LIMIT`, default 60, a separate in-memory
`DailyLimiter` keyed by account id) instead of the device's `DAILY_SCAN_LIMIT`. The
session look-up has a 3-second budget and its answer (also "no such session") is
kept 5 minutes per token per instance; signing out or deleting on the same instance
forgets it at once (another instance may keep counting the old token as signed in for
up to 5 minutes — only the limit is affected). A missing, malformed, unknown or
expired token, accounts being off or Supabase being down **never fail a scan**: it
simply counts against the device limit.

### What `/v1/omr` does with the picture

1. Reads the upload (chunked, capped at 15 MB) and reads the picture's header only:
   format and declared size. Anything over 50 megapixels (`app/imaging.py`,
   `MAX_PIXELS`, also set as Pillow's `MAX_IMAGE_PIXELS`) is refused before a pixel
   is decoded — a decompression bomb is a few hundred bytes claiming 900 MP.
2. Checks the per-device daily limit and takes the single OMR slot (`app/limits.py`).
   The app stops waiting 120 s after its request (APIClient.swift), so the wait in
   the queue is capped (`OMR_QUEUE_WAIT_SECONDS`) and homr only gets what is left of
   that budget, at most `OMR_TIMEOUT_SECONDS`.
3. `app/omr.py`: in a fresh temporary directory, normalises the picture with Pillow
   (EXIF rotation, flatten onto white, RGB, longest side ≤ 3000 px, saved as PNG) and
   runs **the unmodified homr command line** as a separate process — `homr page.png`,
   in its own process group, with a minimal environment — with a timeout. homr
   writes `page.musicxml` next to the input. On timeout, or if the client goes away,
   the whole process group is killed.
4. `app/postprocess.py` (plain `xml.etree`): names the part after the instrument,
   writes `<transpose>` for transposing instruments (double bass −12 → chromatic 0 +
   octave-change −1), replaces every `<time>` with the catalogue meter when one is
   given (warning "Meter set to 3/4 from the catalogue"), checks every bar's length
   (voice 1; chords and grace notes ignored; `<backup>`/`<forward>` followed; a short
   first bar is a pickup) and warns "Bar 7 doesn't add up (3.5 beats in a 4/4 bar) —
   check it", adds a `<direction>` with `<sound tempo>` to bar 1 when a hint carries a
   metronome mark ("♩ = 96", "q = 96", "= 96"; 40–240) and the score has no tempo,
   and counts the measures. homr's `<!-- imgpos -->` comments are preserved.
5. The temporary directory — upload, normalised image, homr's output and preview —
   is deleted in a `finally` block before the response is sent. Request bodies and
   images are never logged; on failure only the tail of homr's stderr is logged, with
   its "Found title:" line (homr's OCR of the text above the first staff) removed.

### homr 0.7.0 facts the adapter relies on

Checked against the wheel on PyPI (`homr==0.7.0`, `homr/main.py`), not the GitHub
main branch, which has moved on:

- Command line: `homr <image>` plus `--init`, `--debug`, `--cache`,
  `--output-large-page`, `--output-metronome N`, `--output-tempo N`,
  `--write-staff-positions`, `--read-staff-positions`, `--coreml-encoder`. **There is
  no `--no-title`** in 0.7.0 — an unknown flag makes homr exit 2 without reading the
  picture, so `HOMR_EXTRA_ARGS` is empty by default.
- Output: `<image stem>.musicxml` next to the input, plus `<stem>_teaser.png` and
  `<stem>_tesseract_input.png` (the crop its title OCR reads). Everything lands in
  our per-request directory.
- Title detection (RapidOCR) always runs; its models ship inside the `rapidocr`
  wheel, so no download happens at request time. The title only lands in
  `<work-title>`.
- A recognition error raises → non-zero exit and homr deletes any half-written
  output. The adapter treats non-zero exit, a missing file and an empty file alike.
- `homr --init` downloads the segmentation + transformer models (CPU variants on a
  machine without CUDA) into site-packages and exits — done once in the Dockerfile.
- `onnxruntime` is a plain dependency of 0.7.0 on PyPI; the `homr[cpu]` extra the
  README on main mentions does not exist in this release (`provides_extra` is empty).

### Rate limits

In-memory, per instance, per `X-Device-Id`: a sliding 24-hour window of
`DAILY_SCAN_LIMIT` scans (default 30), plus one OMR job at a time with a queue of
`OMR_QUEUE_LIMIT` (default 4) — beyond that, or when the queue does not move within
`OMR_QUEUE_WAIT_SECONDS`, the server answers 503. A 503 does not count against the
device's daily limit. This stops a runaway client; it is not a security boundary
(anyone can mint device ids, and the counters reset with the instance). **M5
(PLAN.md B3): App Attest replaces/augments it** — the app proves it is the genuine
build on a real device. The header-based limiter stays as the fallback. Signed-in
players (a valid Bearer session) already get their own per-account allowance,
`SIGNED_IN_DAILY_SCAN_LIMIT` (default 60) — see "Accounts" above; it is in memory per
instance too.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `PORT` | `8080` | port uvicorn listens on (Cloud Run sets it) |
| `HOMR_CMD` | `homr` | command to run, split like a shell line (tests use `python3 tests/fixtures/fake_homr.py`) |
| `HOMR_EXTRA_ARGS` | *(empty)* | arguments placed before the image path — only flags `homr --help` lists for the pinned version (0.7.0 has no `--no-title`) |
| `OMR_TIMEOUT_SECONDS` | `110` | kill homr after this long → 504 (keep under the app's 120 s request timeout) |
| `OMR_QUEUE_WAIT_SECONDS` | `30` | a scan that cannot start within this → 503, not charged |
| `DAILY_SCAN_LIMIT` | `30` | scans per device per sliding 24 h |
| `OMR_QUEUE_LIMIT` | `4` | scans allowed to wait behind the running one |
| `MAX_UPLOAD_BYTES` | `15728640` | 15 MB |
| `MAX_IMAGE_SIDE` | `3000` | longest side after normalisation, px |
| `CATALOG_DIR` | `content/catalog` (checkout) or `/srv/content/catalog` (image) | catalogue files |
| `INCLUDE_DRAFTS` | unset | `1` makes `/v1/identify` also match `draft` / `in_review` excerpts |
| `OMR_WORK_DIR` | system temp dir | where the per-request directories are created |
| `SUPABASE_URL` | unset | Supabase project URL (`https://xxxx.supabase.co`); with the key below it turns `/v1/feedback`, `/v1/auditions` and `/v1/recommendations` on |
| `SUPABASE_SERVICE_ROLE_KEY` | unset | Supabase service-role key — **a secret**: on Cloud Run it comes from Secret Manager (`backend/deploy.sh`, secret `auditioner-supabase-service-key`), never from the repo |
| `FEEDBACK_HASH_SALT` | unset | salt for hashing device ids in feedback rows; empty → fallback derived from `SUPABASE_URL` (see above) |
| `DAILY_FEEDBACK_LIMIT` | `20` | feedback messages per device per sliding 24 h |
| `APPLE_TEAM_ID` | unset | Apple Developer Team ID (10 characters); one of the settings that turn `/v1/account…` on |
| `APPLE_KEY_ID` | unset | Key ID of the Sign in with Apple key (10 characters) |
| `APPLE_PRIVATE_KEY` | unset | **a secret**: the text of the Sign in with Apple `.p8` key (EC P-256). On Cloud Run it comes from Secret Manager (secret `auditioner-apple-signin-key`) |
| `APPLE_BUNDLE_ID` | `com.milaiwalker.auditioner` | the app's bundle id: the identity token's audience and the `client_id` sent to Apple |
| `ACCOUNT_SECRET` | unset | **a secret**, at least 32 characters: key for `HMAC-SHA256` of Apple's user id and (through HKDF-SHA256) for encrypting Apple refresh tokens. On Cloud Run it comes from Secret Manager (secret `auditioner-account-secret`). Never change it once set |
| `SIGNED_IN_DAILY_SCAN_LIMIT` | `60` | scans per signed-in account per sliding 24 h (instead of `DAILY_SCAN_LIMIT`) |
| `TRENDS_SALT` | unset | **a secret**: key for `HMAC-SHA256(TRENDS_SALT, X-Device-Id)` in `trend_contributions`; with Supabase it turns `/v1/trends` on (503 without it). On Cloud Run it comes from Secret Manager (`deploy.sh`, secret `auditioner-trends-salt`, created once with a random value). Never change it once set |

The only secret so far is the Supabase service-role key, and it lives in Google
Secret Manager (`deploy.sh` stores it from the `SUPABASE_SERVICE_ROLE_KEY` variable
in Milai's Terminal and mounts it with `--update-secrets`; it is never echoed).
`TRENDS_SALT` takes the same route (secret `auditioner-trends-salt`), except that
`deploy.sh` makes it up itself the first time and never replaces it. The Sign in
with Apple key (`.p8`) and `ACCOUNT_SECRET` are put into Secret Manager once by hand
with the commands in `docs/SETUP.md` ("Sign in with Apple (once)"); `deploy.sh` only
checks they exist and mounts them (`APPLE_PRIVATE_KEY`, `ACCOUNT_SECRET`) when
`APPLE_TEAM_ID` and `APPLE_KEY_ID` are exported. Later
keys (Anthropic, YouTube) follow the same route — never into the repo (CLAUDE.md).

## Run it locally

```sh
cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt      # tests only — no homr
pip install -r requirements.txt          # add the real engine (~1 GB with models)
homr --init                              # download the models once
uvicorn app.main:app --reload --port 8080
curl localhost:8080/healthz
curl -F image=@page.jpg -F instrument=cello -F transposition=0 -F 'hints=["♩ = 96"]' \
     -H 'X-Device-Id: dev' localhost:8080/v1/omr
```

Without homr installed, point the server at the fake engine the tests use:
`HOMR_CMD="python3 tests/fixtures/fake_homr.py" uvicorn app.main:app` — it returns a
fixed four-bar score for any picture.

## Tests

```sh
pip install -r backend/requirements-dev.txt
pytest -q backend/tests           # from the repo root (backend/pytest.ini sets the path)
```

`tests/fixtures/fake_homr.py` stands in for the homr command line (same options as
homr 0.7.0, strict about unknown flags); `FAKE_HOMR_MODE` makes it crash, hang, hang
with a child process, stay silent, print a title or write garbage so the error
paths, the process-group kill and the temp-file clean-up are covered. The real
engine is never run in CI. `tests/test_feedback.py` drives `/v1/feedback` against an
`httpx.MockTransport` standing in for Supabase (row shape and hashed device id, 503
unconfigured, 400/422 validation, 429 after 20, 502 on Supabase errors, and a
`caplog` check that the message never reaches a log line) — no network either.
`tests/test_feed.py` drives `/v1/auditions` and `/v1/recommendations` against a small
fake PostgREST on an `httpx.MockTransport`: the exact app contract, published-only and
still-open filters (including a fake view that "forgot" its published or instrument
filter, which the check against the `vacancies` table must catch), item order, chunking and paging, every position mapping, the
evidence wording, the all-regions sum, the 10-minute cache (fake clock), 400/503/502
and that PostgREST error bodies are never logged. Its orchestras and works are
fictional and it contains no bar numbers. The fixture catalogue in `tests/fixtures/catalog/`
keeps the tests independent of `content/catalog`, which is also exercised when files
exist there. `tests/test_trends.py` drives `/v1/trends` against a fake
`trend_contributions` table on an `httpx.MockTransport`: ISO-week helpers (week 53,
the year boundary, UTC), the 19/20-contributor threshold, the 40 %/15 % tier
boundaries, no numbers anywhere in the answer, unknown and draft excerpts dropped,
the 50-id cap, replace-on-repost, delete-everything, 26-week retention (hourly, never
failing a request), the one-hour cache, 400/422/502/503, and that neither the raw
device id, the contributor hash nor the salt reaches Supabase or a log line.
`tests/test_accounts.py` drives `/v1/account…` and the signed-in scan limit against a
fake Apple and a fake Supabase on one `httpx.MockTransport`, with an RSA key (Apple's
signing key) and an EC P-256 key (the `.p8`) generated at test time — no key material
in the repo: the happy path (hashed id, encrypted refresh token, hashed session, a
valid ES256 client secret), wrong audience/issuer, expired, nonce mismatch, HS256,
key rotation and the 24-hour key cache, 503 for each missing setting, code-exchange
failures (502, nothing stored), GET/sign-out/delete, delete with Apple down (502,
account kept), the 365-day expiry, signed-in vs device limits on `/v1/omr` with
valid, bad and unknown tokens and with Supabase down, the 5-minute look-up cache, and
that no token, code, nonce, refresh token, Apple id or secret reaches a log line or a
response.
`.github/workflows/backend.yml` runs the suite on every push that
touches `backend/**` or `content/**`.

## Docker and Cloud Run

`backend/Dockerfile` (python:3.12-slim, non-root, models baked in with `homr --init`,
`content/catalog` copied in) must be built from the **repo root**:

```sh
docker build -f backend/Dockerfile -t auditioner-api .
docker run --rm -p 8080:8080 auditioner-api
```

`backend/deploy.sh` does the whole Cloud Run deployment (Cloud Build with
`backend/cloudbuild.yaml`, service `auditioner-api`, us-central1, 2 CPU / 4 GiB,
concurrency 4 so health checks and `/v1/identify` keep answering while a scan runs,
300 s timeout, 0–3 instances, env vars merged with `--update-env-vars` so a re-run
keeps what was set by hand) and prints the URL to paste into the app. When
`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are exported before running it, the
script also enables Secret Manager, stores the key as `auditioner-supabase-service-key`
(a new version only when it changed), grants the service's runtime account
`roles/secretmanager.secretAccessor`, and deploys with `--update-secrets
SUPABASE_SERVICE_ROLE_KEY=auditioner-supabase-service-key:latest` plus
`SUPABASE_URL` in the env vars (this also turns on the auditions feed endpoints, which
read with the same key); without them it deploys as before and leaves those settings
untouched. On the same runs it makes sure the community-trends salt exists as
`auditioner-trends-salt` (created once — random, or `TRENDS_SALT` if exported — and
never replaced; a different exported value stops the script), grants the same
account access, and mounts it with `--update-secrets TRENDS_SALT=auditioner-trends-salt:latest`.
The non-programmer walkthrough is in `docs/SETUP.md`.

The image has not been built in the cloud coding environment (no Docker daemon,
GitHub release downloads blocked), so the first `deploy.sh` run is the first real
build. The engine's OS library needs (`libglib2.0-0`, `libgomp1`) and the ~1–2 GB
image size are expectations, not measurements.

## Licensing note (AGPL)

homr is licensed under the GNU AGPL-3.0. We use it **unmodified**, as its own
command-line program in its own process, and only exchange files with it; nothing in
`app/` imports it, and the app on the phone never contains it. Keep it that way — if
homr ever needs a change, it must be published under the AGPL. Audiveris (M2) follows
the same rule. See `THIRD_PARTY_NOTICES.md`.
