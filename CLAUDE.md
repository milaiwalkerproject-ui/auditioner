# CLAUDE.md — standing rules for every session in this repo

Auditioner is an iPhone/iPad app that helps orchestral musicians prepare for orchestra
auditions. It is owned by **Milai Walker** (professional cellist and music teacher,
non-programmer, product owner and sole approver). `PLAN.md` is the decision record —
read it before changing anything; it outranks your own judgement on product questions.

## The honesty contract (never weaken it)

- An excerpt or audition fact is either **verified** `{status:"verified", value,
  source, asOf}` — value shown, source cited — or **unverified**
  `{status:"unverified"[, source]}` — shown as "Check the official list", never a value.
  `not_applicable` hides the row. Same contract as Tutti.
- **Never invent or infer** bar numbers, rehearsal marks, tempo markings, metronome
  ranges, audition dates, frequencies, recording timestamps or any other fact — not in
  code, copy, fixtures or seed data. If a fact is unknown, mark it unverified.
- Prose (history, technique, pitfalls) carries `origin` (curated | ai) and `reviewStatus`
  (draft | approved). The app shows only `approved` prose. Until 2026-11-12 nothing
  AI-written is shown unreviewed. AI prose always carries the "AI-generated — may contain
  errors, check against your part" label.
- Never copy excerpt-book engravings, bowings, fingerings, or anyone's written
  commentary. Facts only, with links to the source.
- No survey statistic is shown in the app until someone has read it from the primary
  document.

## Hard "never" list

- Never download, cache, analyse or modify YouTube audio/video; never build stored
  data from YouTube description/comment text; one YouTube player per screen; no
  overlays on the player; no background play; YouTube/Apple Music never paywalled.
- Never download, proxy, store or redistribute IMSLP files; link out, the user imports.
- Never automate aggregator sites (AFM, League, Musical Chairs, muvac, OrchestraPLAN,
  Audition Cafe, Facebook). Crawl only orchestras' own public pages per `docs/BOT.md`.
- Never put API keys, tokens or secrets in the app or the repo (the repo is public).
- Never send user scans or personal data to Claude/Anthropic. OMR uses homr/Audiveris
  on our server, unmodified, as a separate process (AGPL).
- Never skip, disable or weaken a test or a CHECK constraint to get green.

## Engineering rules

- iOS: SwiftUI, deployment target **iOS 17.0**, Swift language mode 5, no third-party
  Swift packages unless the plan says so. The Xcode project uses **folder-synchronised
  groups**: put new files under `ios/Auditioner/` (or `ios/AuditionerTests/`) and they
  are picked up automatically — do not hand-edit `project.pbxproj` unless adding a
  target, capability or build setting.
- **This cloud environment has no Swift compiler.** GitHub Actions (`.github/workflows/
  ios.yml`, macOS runner) is the compiler: after pushing, read the run's logs and fix
  every error before calling work done. Write conservative, explicit Swift: annotate
  types where inference is non-obvious, guard iOS-version-specific APIs with
  `#available`, keep UIKit bridges small.
- Backend: Python 3.12, FastAPI, pytest (`backend/`). Run `pytest` locally before pushing.
- Database: Supabase migrations are **append-only** (new numbered files only).
- Catalogue: `content/catalog/*.json` is the source of truth; validate against
  `content/schema/catalog.schema.json` (`python3 content/validate.py`) before committing.
- Keep docs updated in the same commit as the change they describe.

## Working agreement

- Work on a feature branch, push, get the cloud-Mac build green, self-review with
  /code-review, then give Milai a **plain-words summary** plus "how to try it on your
  Mac/iPad" steps. Milai approves every merge.
- Copy is written for musicians, plain words, sentence case. Name things by what the
  player does ("Scan my part", "Mark start", "Slow down").

## Escalate to Milai instead of guessing

Business choices (money, providers, scope, countries), anything that changes a promise
to users, any new data source, catalogue facts, and anything where two readings of the
task are plausible. One clear question beats a wrong build.
