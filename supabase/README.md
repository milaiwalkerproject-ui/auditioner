# Supabase (database) for Auditioner

Auditioner has its **own** Supabase project, separate from Tutti's. Same account is
fine; a separate project keeps the two apps' data and keys apart.

`migrations/` holds the database schema as numbered SQL files. The folder is
**append-only**: to change the database, add a new file with a later timestamp —
never edit or delete an existing one (CLAUDE.md). Each file is written so running it
twice is harmless (`create table if not exists`, …).

| File | What it creates |
|---|---|
| `20261011000000_feedback.sql` | `public.feedback` — in-app "Report an error" / "Send feedback" messages (server-only, no RLS policies) |
| `20261011010000_auditions.sql` | Open-auditions feed: `orchestras`, `audition_sources`, `vacancies`, `vacancy_items`, `crawl_runs`, the `open_auditions` / `excerpt_frequency` / `excerpt_open_now` views and the `excerpt_recommendations` function (written by the crawler, read by the app — published rows only; see `docs/FEED.md`) |

## Applying a migration (Milai, plain words)

**Dashboard (easiest):**

1. Open <https://supabase.com/dashboard>, pick the **auditioner** project.
2. Left bar → **SQL Editor** → **New query**.
3. Open the migration file from this folder in a text editor (or on GitHub), copy
   everything, paste it into the SQL editor.
4. Click **Run**. "Success. No rows returned" is the good answer.
5. Repeat for every file you haven't run yet, oldest first.

**Command line (optional, if you use the Supabase CLI already):**

```sh
supabase link --project-ref YOUR-PROJECT-REF      # once; the ref is in Settings → General
supabase db push                                   # runs every file in supabase/migrations not yet applied
```

## What the server needs from this project

`backend/deploy.sh` turns feedback storage on when these two values are exported in
Terminal before running it (see `docs/SETUP.md`, "Turn on feedback (Supabase)"):

- `SUPABASE_URL` — **Project Settings → API → Project URL** (looks like
  `https://abcdefgh.supabase.co`).
- `SUPABASE_SERVICE_ROLE_KEY` — **Project Settings → API → service_role** (secret).
  It bypasses every security rule, so it lives only in Google Secret Manager and in
  your head — never in the app, the repo, a chat or an email.

## Reading feedback

**Table Editor → feedback.** Each row is one message: `created_at`, `context` (where
in the app), `excerpt_id`, `message`, `app_version`, `device_hash` (a scrambled
install code, not a device id), `status`. When you have dealt with a message, set
`status` to `handled` (or `ignored`); delete handled rows now and then — the privacy
policy promises deletion within 12 months.
