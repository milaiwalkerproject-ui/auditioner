# Auditioner API (backend)

The small server behind **Scan my part**: it reads a photo of a page with
[homr](https://github.com/liebharc/homr), tidies the MusicXML for the app, matches
printed text against the excerpt catalogue, and serves the catalogue files.
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

Errors are always JSON `{"detail": "plain words for a musician"}` and nothing else
in the body — the app decodes it as a flat `[String: String]` dictionary:

| Status | When |
|---|---|
| 400 | missing `X-Device-Id`, unknown instrument, bad meter / transposition / hints, or a picture claiming over 50 megapixels; for `/v1/feedback` also a blank message or one over 2000 characters after trimming |
| 413 | upload over 15 MB (refused by Content-Length before reading, or cut off while a chunked body streams in) |
| 415 | the file isn't a JPEG/PNG (or another picture Pillow can read) |
| 422 | a field is missing or has the wrong type (for `/v1/feedback`: `context` outside `[a-z0-9:-]{1,64}`, over-long fields) |
| 429 | daily scan limit reached for this device (`/v1/omr`), or daily feedback limit (`/v1/feedback`, `DAILY_FEEDBACK_LIMIT`) |
| 500 | homr failed or produced nothing readable (or any unexpected server error) |
| 502 | `/v1/feedback`: Supabase did not take the row (unreachable, refused, table missing) — not charged |
| 503 | the instance is busy: the short queue is full, or the scan could not start within `OMR_QUEUE_WAIT_SECONDS` — `Retry-After: 60`, not charged. For `/v1/feedback`: `"Feedback isn't set up on the server yet."` while `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` are not set (the app keeps the report queued) |
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
build on a real device and signed-in users get a higher, server-stored limit. The
header-based limiter stays as the fallback.

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
| `SUPABASE_URL` | unset | Supabase project URL (`https://xxxx.supabase.co`); with the key below it turns `/v1/feedback` on |
| `SUPABASE_SERVICE_ROLE_KEY` | unset | Supabase service-role key — **a secret**: on Cloud Run it comes from Secret Manager (`backend/deploy.sh`, secret `auditioner-supabase-service-key`), never from the repo |
| `FEEDBACK_HASH_SALT` | unset | salt for hashing device ids in feedback rows; empty → fallback derived from `SUPABASE_URL` (see above) |
| `DAILY_FEEDBACK_LIMIT` | `20` | feedback messages per device per sliding 24 h |

The only secret so far is the Supabase service-role key, and it lives in Google
Secret Manager (`deploy.sh` stores it from the `SUPABASE_SERVICE_ROLE_KEY` variable
in Milai's Terminal and mounts it with `--update-secrets`; it is never echoed). Later
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
`caplog` check that the message never reaches a log line) — no network either. The fixture catalogue in `tests/fixtures/catalog/`
keeps the tests independent of `content/catalog`, which is also exercised when files
exist there. `.github/workflows/backend.yml` runs the suite on every push that
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
`SUPABASE_URL` in the env vars; without them it deploys as before and leaves feedback
settings untouched. The non-programmer walkthrough is in `docs/SETUP.md`.

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
