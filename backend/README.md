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
| `GET /v1/catalog/{instrument}` | optional `If-None-Match` | the `content/catalog/<instrument>.json` file with an `ETag` (304 when unchanged); 404 if there is no file |
| `GET /v1/instruments` | — | `{"instruments": ["violin", …]}` (handy for checks) |

Errors are always JSON `{"detail": "plain words for a musician"}`:

| Status | When |
|---|---|
| 400 | missing `X-Device-Id`, unknown instrument, bad meter / transposition / hints |
| 413 | image over 15 MB |
| 415 | the file isn't a JPEG/PNG (or another picture Pillow can read) |
| 422 | a field is missing or has the wrong type |
| 429 | daily scan limit reached for this device |
| 500 | homr failed or produced nothing readable |
| 503 | the instance is busy (one scan at a time, four waiting) — `Retry-After: 60` |
| 504 | homr ran past `OMR_TIMEOUT_SECONDS` |

### What `/v1/omr` does with the picture

1. Reads the upload (chunked, capped at 15 MB) and checks it really is a picture.
2. Checks the per-device daily limit and takes the single OMR slot (`app/limits.py`).
3. `app/omr.py`: in a fresh temporary directory, normalises the picture with Pillow
   (EXIF rotation, flatten onto white, RGB, longest side ≤ 3000 px, saved as PNG) and
   runs **the unmodified homr command line** as a separate process — `homr --no-title
   page.png` — with a timeout. homr writes `page.musicxml` next to the input.
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
   images are never logged.

### Rate limits

In-memory, per instance, per `X-Device-Id`: a sliding 24-hour window of
`DAILY_SCAN_LIMIT` scans (default 30), plus one OMR job at a time with a queue of
`OMR_QUEUE_LIMIT` (default 4) — beyond that the server answers 503 at once. A 503
does not count against the device's daily limit. This stops a runaway client; it is
not a security boundary. **M5 (PLAN.md B3): App Attest replaces/augments it** — the
app proves it is the genuine build on a real device and signed-in users get a higher,
server-stored limit. The header-based limiter stays as the fallback.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `PORT` | `8080` | port uvicorn listens on (Cloud Run sets it) |
| `HOMR_CMD` | `homr` | command to run, split like a shell line (tests use `python3 tests/fixtures/fake_homr.py`) |
| `HOMR_EXTRA_ARGS` | `--no-title` | arguments placed before the image path (`--no-title` skips homr's own OCR; the app sends the printed text as hints) |
| `OMR_TIMEOUT_SECONDS` | `150` | kill homr after this long → 504 |
| `DAILY_SCAN_LIMIT` | `30` | scans per device per sliding 24 h |
| `OMR_QUEUE_LIMIT` | `4` | scans allowed to wait behind the running one |
| `MAX_UPLOAD_BYTES` | `15728640` | 15 MB |
| `MAX_IMAGE_SIDE` | `3000` | longest side after normalisation, px |
| `CATALOG_DIR` | `content/catalog` (checkout) or `/srv/content/catalog` (image) | catalogue files |
| `INCLUDE_DRAFTS` | unset | `1` makes `/v1/identify` also match `draft` / `in_review` excerpts |
| `OMR_WORK_DIR` | system temp dir | where the per-request directories are created |

No secrets are needed in M1. Later keys (Anthropic, YouTube, Supabase) go into Cloud
Run secrets, never into the repo (CLAUDE.md).

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

`tests/fixtures/fake_homr.py` stands in for the homr command line; `FAKE_HOMR_MODE`
makes it crash, hang, stay silent or write garbage so the error paths and the
temp-file clean-up are covered. The fixture catalogue in `tests/fixtures/catalog/`
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
concurrency 1, 300 s timeout, 0–3 instances) and prints the URL to paste into the
app. The non-programmer walkthrough is in `docs/SETUP.md`.

## Licensing note (AGPL)

homr is licensed under the GNU AGPL-3.0. We use it **unmodified**, as its own
command-line program in its own process, and only exchange files with it; nothing in
`app/` imports it, and the app on the phone never contains it. Keep it that way — if
homr ever needs a change, it must be published under the AGPL. Audiveris (M2) follows
the same rule. See `THIRD_PARTY_NOTICES.md`.
