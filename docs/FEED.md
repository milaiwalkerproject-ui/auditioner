# The open-auditions feed: how lists get from an orchestra's website into the app

*For Milai (plain words first), then the technical notes. The code lives in
`backend/crawler/`; the public rules the bot follows are in `docs/BOT.md`.*

## 1. In one paragraph

Every night a small program (the **crawler**) visits the audition page of each
orchestra on our list, notices when the page or a linked repertoire list has changed,
asks Claude to copy the list into a fixed form (position, deadline, works, bars),
**checks every line in plain code against the text it came from**, matches the
excerpts to our catalogue, and puts the result into a **review queue**. Nothing is
shown in the app until you set it to *published*. Pages that did not change cost
nothing: no model is called.

## 2. Your part: reviewing a list

For the first ~200 lists you review every one (PLAN F3). For now the review tool is
the Supabase table editor; a small admin page comes later.

1. Open Supabase → **Table editor** → `vacancies`. Filter `review_status = in_review`.
2. Open the row. Check `position`, `instrument`, `application_deadline`,
   `audition_dates`, `list_completeness`, and `flags` (anything odd the checks found —
   for example `deadline:date_not_in_cited_lines` means the model named a date the
   source does not print, so the date was dropped; `contact_details_removed` means an
   email address or phone number was stripped from the text, see `redact.py`).
3. Open `vacancy_items` filtered by that `vacancy_id`. Each item shows:
   - `raw_text` — the source line(s) it was read from, verbatim (the evidence);
   - `composer`, `work`, `movement`, `location` — what was read;
   - `verification` — `ok: true` when the cited lines really contain the composer,
     the work and the bar numbers; otherwise the `flags` say what was missing;
   - `excerpt_id`, `match_confidence`, `match_bucket` — the catalogue match:
     `auto` (≥ 0.90), `review` (0.60–0.90, a suggestion to confirm), or
     `new_candidate` (nothing in the catalogue fits — a candidate for a new excerpt).
4. Fix what needs fixing (edit the cell), clear a wrong `excerpt_id`, or set an item's
   `review_status` to `rejected`.
5. To publish: set `reviewed_by` to your name on the vacancy and set its
   `review_status` to `published`; do the same on each item you want shown. The
   database refuses to publish a vacancy without a public `source_url`, a position
   and an instrument, or an item without evidence (`raw_text`) that is neither
   verified by the code nor signed off by you (`reviewed_by`). That is the honesty
   contract, enforced where it cannot be forgotten.
6. If the orchestra changes the list later, the crawler replaces the items and sets
   the vacancy back to `in_review`, because the content is new.

## 3. Running it

### On your Mac (dry run, no database needed)

```
cd auditioner
python3 -m venv .venv && source .venv/bin/activate
pip install -r backend/crawler/requirements.txt
cd backend
python -m crawler check-registry                 # is the orchestra list well formed?
python -m crawler run --dry-run --limit 3        # fetch 3 orchestras, write JSON to backend/crawler/out/
python -m crawler run --dry-run --orchestra chicago-symphony-orchestra
python -m crawler extract-file ~/Downloads/cello-list.pdf --instrument cello
```

Without `ANTHROPIC_API_KEY` in the environment the crawler still fetches pages and
notices changes, but extracts nothing (it says so in the report). To extract, export
the key first (`export ANTHROPIC_API_KEY=...` in the same Terminal — never put it in a
file in the repo). Without `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` every run is
a dry run that writes JSON under `backend/crawler/out/` (git-ignored):
`vacancies/<orchestra>/<key>.json`, `orchestras/`, `runs/<time>.json` and
`state.json` (what we last saw at each address, so the next dry run only re-reads
what changed).

### On Google Cloud (the nightly job)

```
./backend/crawler/deploy_job.sh
```

It builds the image with Cloud Build, creates/updates the Cloud Run **Job**
`auditioner-crawler` and a Cloud Scheduler trigger that runs it every night at
03:17 UTC. The first time it asks you to paste the Anthropic key and the Supabase
service-role key (typed hidden, stored in Secret Manager, never in the repo) and the
Supabase project URL. Run it again whenever the crawler, the catalogue or the
registry changes. Before the first run apply the database migration:
`supabase/migrations/20261011010000_auditions.sql` (Supabase → SQL editor, or
`supabase db push`).

Run it by hand: `gcloud run jobs execute auditioner-crawler --region us-central1`.
Logs: Cloud Run → Jobs → auditioner-crawler → the execution. The last lines are the
JSON run report (also stored in the `crawl_runs` table).

## 4. What it costs

- **Fetching** is free apart from the job's minutes (one small Cloud Run task, a
  few hours a night at most; well under a dollar a month).
- **Claude**, only for pages or documents that changed:
  - triage of a changed page with Claude Haiku 5.5: well under a cent;
  - extraction of a changed list with Claude Opus 5.5: typically **5–25 cents per
    list** (a 3–6 page PDF, sent both as text lines and as the PDF itself, with the
    fixed instructions served from the prompt cache). A long list can reach 50 cents.
  - Expected: a few dollars in the first weeks (the first visit extracts every list
    we have), then cents per night, since lists change rarely. The run report shows
    `estimatedCostUsd` per orchestra and in total.
- **Budget alert**: in the Anthropic console (Settings → Limits) set a monthly spend
  limit and an email alert — $30/month is plenty to start. The Google Cloud budget
  from `docs/SETUP.md` covers the job's minutes.
- Prices change; the numbers above are the price table of October 2026 and the
  console is the source of truth. `python -m crawler run` prints its own estimate
  from the token counts of each call.

## 5. The registry file (`content/registry/orchestras.json`)

The list of orchestras whose own sites the bot may read (PLAN F1, F2). Either a
JSON list of entries, or an object `{ "version": "…", "generatedAt": "YYYY-MM-DD",
"orchestras": [ … ] }`. Each entry:

| field | required | meaning |
|---|---|---|
| `id` | yes | lower-case kebab-case, unique, stable (`chicago-symphony-orchestra`) |
| `name` | yes | as the orchestra writes it |
| `country` | yes | ISO 3166 two letters preferred (`US`, `DE`, `JP`) |
| `region` | yes | `north-america` · `europe-german` · `europe-other` · `uk` · `asia-pacific` · `other` |
| `city` | no | |
| `type` | yes | `professional` · `youth` · `collegiate` · `community` |
| `auditionsUrl` | no* | the orchestra's own auditions / vacancies page |
| `homepageUrl` | no* | the orchestra's own site (used when there is no auditions page) |
| `notes` | no | a line for the crawler's context (never a source of facts) |
| `source` | yes | where the entry's facts come from (http(s) address) |
| `asOf` | yes | `YYYY-MM-DD` when they were checked |
| `tutti` | no | `{ "orgId": "…" }` — the matching organisation in Tutti (PLAN U2) |
| `groups` | no | free tags such as `["icsom"]`, ignored by the crawler |

\* at least one of `auditionsUrl` / `homepageUrl`; an entry without either is kept in
the registry but not crawled (a *note* in the report, not an error).

Unknown fields are ignored. The loader (`crawler/registry.py`) skips an entry it
cannot use (bad id, unknown region or type, non-http address, duplicate id) and says
why; `python -m crawler check-registry` prints `problems` (exit code 1) and `notes`
(exit code 0). Aggregator addresses in the registry are refused by the policy anyway
(`crawler/policy.py`).

## 6. The pipeline, step by step (technical)

```
registry → fetch page (conditional GET) → change detection → linked documents
  → triage (Haiku) → extraction (Opus, structured output) → verification (code)
  → catalogue mapping (code) → writer (Supabase or JSON)
```

1. **Fetcher** (`fetcher.py`, `policy.py`, `robots.py`): identifies as AuditionerBot,
   reads `robots.txt` first, one request per host at a time with ≥ 10 s between them
   (or the `Crawl-delay` — a long one is honoured in full and that site simply gets
   fewer requests that night, see `CRAWLER_HOST_TIME_BUDGET_SECONDS`; `www.` and the
   bare domain share one gap), conditional GET with the stored ETag / Last-Modified, backs
   off on 429/503 (`Retry-After`), stops the host for the run on 403, never sends
   cookies, follows redirects by hand so every hop obeys the same rules, 15 MB cap.
   Only registry hosts, plus documents (pdf/doc/docx) linked from them; aggregators
   and social networks are refused (the list is in `policy.py` and `docs/BOT.md`).
2. **Change detection** (`pages.py`, `documents.py`): the page's main text (no
   scripts, navigation, cookie banners; dates and times stripped) is hashed; linked
   documents are hashed as bytes and as extracted text. Unchanged → no model call.
   Discovered links are stored with the page's state so a 304 on the page still lets
   the known documents be re-checked (also conditional).
3. **Documents**: PDF text via pypdf (page by page, every line gets an id `L0001…`);
   `.docx` read directly; legacy `.doc` converted with LibreOffice when installed
   (not in the Cloud image), else skipped with a note. schema.org `JobPosting` JSON-LD
   on a page becomes extra citable lines (`JobPosting validThrough: …`).
4. **Triage** (`llm.py`, Claude Haiku 5.5, effort `low`, fixed instructions cached):
   is the page about auditions, does the page itself list repertoire, which linked
   documents are repertoire/audition lists. Documents with "repertoire", "excerpts",
   "Probespiel" … in their link or address are extracted even if triage missed them.
5. **Extraction** (Claude Opus 5.5, structured outputs with the fixed schema in
   `schema.py`, effort `high`, fixed instructions cached, the PDF attached as a
   document block up to 10 MB / 100 pages, the numbered lines as text). The schema has
   only required fields with `""`/`0` sentinels, no nullable unions, no numeric
   constraints, no "reasoning" field. `stop_reason` is checked: `refusal` and
   `max_tokens` are errors, never data. The server-side refusal fallback is on by
   default for the Opus call (`CRAWLER_REFUSAL_FALLBACK=0` turns it off).
6. **Verification** (`verify.py`, deterministic, diacritic-insensitive): every item
   must cite line ids that exist; the cited lines must contain the composer (surname,
   fuzzy), the work (a significant token or the catalogue number) and, for a bar
   range, both numbers; `end ≥ start ≥ 1`. Dates survive only when their cited lines
   print them. Model confidence is never asked for or used.
   **Redaction** (`redact.py`) runs right after: email addresses and phone numbers are
   removed by pattern from every text the crawler stores (positions, the verbatim item
   lines, notes, stored link texts); the vacancy gets the flag `contact_details_removed`
   and the run report counts them (`contactsRedacted`). Staff names are kept out by the
   extraction instructions and by review — no pattern can tell them from composers.
7. **Mapping** (`mapping.py`): candidate excerpts by composer + work (numbers must
   agree) + movement; confidence = 0.55·name + 0.25·bar-overlap (with the excerpt's
   location or any variant) + 0.10·catalogue-number agreement + 0.10·verified; capped
   at 0.85 when unverified, 0.5 on a catalogue-number conflict, 0.89 when two
   excerpts nearly tie. ≥ 0.9 `auto`, 0.6–0.9 `review`, < 0.6 `new_candidate`.
8. **Writer** (`store.py`): Supabase REST (PostgREST) with the service-role key —
   upserts keyed by a natural key (orchestra, source, position, instrument, chair);
   unchanged snapshot → only `last_seen_at`; changed → items replaced, vacancy back to
   `in_review`. A page or document that answers unchanged (304, or the same text)
   moves `last_seen_at` on for every vacancy read from it (`touch_source`), so a
   notice still on the site stays in the feed and "Last checked" shows the night it
   was last seen. Dry run → JSON files.

**Batch API**: `ExtractionClient.submit_extraction_batch` / `collect_batch` build the
same requests for Anthropic's Message Batches (50 % price, results within hours).
The nightly job does not use it yet because a night's changed lists are few and the
review queue benefits from same-night results; it is there for the first full pass
over a new registry (hundreds of lists) if that ever matters.

**User-uploaded lists** (PLAN F4): `python -m crawler extract-file PATH` runs the same
extraction, verification and mapping on a local file. Its `source_url` is
`file:<name>`, which the database never lets into the public feed.

## 7. Environment variables

| name | default | meaning |
|---|---|---|
| `ANTHROPIC_API_KEY` | — | from Secret Manager; without it nothing is extracted |
| `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` | — | without both: dry run |
| `CRAWLER_REGISTRY` | `content/registry/orchestras.json` | |
| `CATALOG_DIR` | `content/catalog` | |
| `CRAWLER_OUT_DIR` | `backend/crawler/out` | dry-run output |
| `CRAWLER_EXTRACTION_MODEL` | `claude-opus-5-5` | |
| `CRAWLER_TRIAGE_MODEL` | `claude-haiku-5-5` | |
| `CRAWLER_EXTRACTION_EFFORT` | `high` | `low`…`max` |
| `CRAWLER_REFUSAL_FALLBACK` | `1` | server-side fallback on a refusal (Opus call) |
| `CRAWLER_CONCURRENCY` | `1` (`3` in the job) | orchestras in flight; the per-host gap still holds |
| `CRAWLER_MIN_HOST_GAP_SECONDS` | `10` | cannot go below 10 |
| `CRAWLER_HOST_TIME_BUDGET_SECONDS` | `1200` | most request time spent on one site per night; a long `Crawl-delay` means fewer pages, never a shorter wait |
| `CRAWLER_MAX_DOCUMENT_BYTES` | 15 MB | cannot go above 15 MB |
| `CRAWLER_MAX_SUBPAGES`, `CRAWLER_MAX_DOCUMENTS` | 8, 12 | per orchestra per run |

## 8. Database (`supabase/migrations/20261011010000_auditions.sql`)

`orchestras` (registry mirror) · `audition_sources` (per-URL crawl state) ·
`vacancies` · `vacancy_items` · `crawl_runs`. CHECK constraints mirror the honesty
contract (published rows need a public source, evidence, verification or a
reviewer; bar ranges must parse; confidence in 0–1). RLS: the app's anon key can
only `select` published vacancies/items and the orchestra registry; writes are
service-role only.

Views and a function for the app:

- `open_auditions` — published vacancies with the orchestra's name, country, region.
- `excerpt_frequency` — per (instrument, position class, region, excerpt): the
  recency-weighted frequency, half-life 3 years (PLAN D5), from published lists.
- `excerpt_recommendations(instrument, position_class, region, k := 10)` — the
  frequency blended with the excerpt's share across all regions as a prior, with the
  tier (`core` ≥ 50 %, `common` ≥ 20 %, `occasional`) and a plain-words `evidence`
  line ("On 7 of 12 section cello lists (north-america), 2024–2026").
- `excerpt_open_now` — "On N open auditions now", kept separate from the frequency.

## 9. App endpoints (what the app reads)

The app never reads Supabase directly for the feed. It asks our server
(`backend/app/feed.py`), which reads with the service-role key and only ever passes
on **published** rows — the service role skips row level security, so each query
asks for `published` itself, and every audition the `open_auditions` view returns is
checked once more against the `vacancies` table before it is sent. Details, field by
field: `backend/README.md`.

- `GET /v1/auditions?instrument=cello&region=uk` → `{"auditions": [...]}`: vacancies
  from `open_auditions` for that instrument (and region; none = every region) that
  are **still open** — deadline from yesterday (UTC) on, or no deadline and seen on
  the orchestra's page in the last 60 days — soonest deadline first, each with its
  published `vacancy_items` in list order (`rawText`, `category`, `round`,
  `excerptId`).
- `GET /v1/recommendations?instrument=cello&position=section&region=uk` →
  `{"recommendations": [...]}`: `excerpt_recommendations(...)` for the position's
  class, plus `excerpt_open_now` for "On N open auditions now". Without a region the
  server sums `excerpt_frequency` over every region. Each entry carries the tier, the
  share it comes from, the plain counts and an evidence line written from those
  counts ("On 7 of 12 section cello lists in North America, 2024–2026").

When the server isn't set up, can't be reached or has no reviewed lists for the
player's chair yet, the app counts the lists cited in its own catalogue instead, on
the phone, and says which source it used ("From the lists in the app's catalogue" /
"From orchestra lists on our server").

The app's positions map to the database's classes like this: principal,
concertmaster and high horn → `principal`; assistant principal → `assistant-principal`;
section, utility and "any" → `section`; "second" → `section` on violin, viola, cello
and double bass, `other` on every other instrument ("Second Oboe"); low horn →
`other` ("Second Horn", "Fourth Horn"). The evidence line always names the class it
counted.

What this means for you as the reviewer:

- something you publish (or unpublish) reaches the app **within 10 minutes** — the
  server keeps each answer that long;
- an item you leave `in_review` or set to `rejected` is never sent, even when its
  vacancy is published; a vacancy that isn't `published` is never sent at all;
- a vacancy drops out of the feed the day after its deadline, but its list keeps
  counting for "What orchestras ask";
- a vacancy **without a deadline** stays in the feed for 60 days after `last_seen_at`.
  The crawler moves `last_seen_at` on every night the page or document it came from
  is still there unchanged, so it drops out 60 days after it was last seen on the
  orchestra's site (or after its page changed and the new version no longer lists it);
- for "What orchestras ask", a region's lists for one chair are counted only once at
  least one item on one of them is matched to a catalogue excerpt; until then that
  region shows as having no lists for that chair (a gap in the database views, noted
  in `backend/README.md`);
- with Supabase not set up on the server the app gets "The auditions feed isn't set
  up on the server yet."; if Supabase doesn't answer, "The auditions feed didn't
  answer. Try again in a few minutes."

## 10. Tests

`pytest -q backend/crawler/tests` — 100+ tests, no network (httpx `MockTransport`),
no real model (a fake Anthropic client with the same call shape). They cover
robots.txt, the per-host gap (fake clock), conditional GET/304, 429/503/403 handling,
the size cap, redirect policy, link discovery and aggregator refusal, PDF/DOCX
reading, the structured-output schema limits, request shape (models, caching,
document block, effort, no forced tool use), refusal/max_tokens handling, the SDK
error chain, verification rules, mapping confidence on a fictional fixture catalogue,
the Supabase request shape and the dry-run files, and the whole pipeline end to end.
CI runs them in `.github/workflows/backend.yml`.

The app endpoints are covered by `pytest -q backend/tests/test_feed.py` (a fake
PostgREST on `httpx.MockTransport`; fictional orchestras, no bar numbers).
