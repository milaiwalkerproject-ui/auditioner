-- Auditioner: in-app "Report an error" / "Send feedback" messages.
-- Written by the server only (POST /v1/feedback, backend/app/feedback.py) with the
-- service-role key, which bypasses row level security. RLS is on and there are NO
-- policies, so the anon and authenticated roles can neither read nor write a row.
--
-- Privacy (docs/PRIVACY.md, "Feedback you send"): no name, email or device id is
-- stored — device_hash is sha256(salt + per-install random id). Rows are deleted
-- once handled, within 12 months at the latest.

create table if not exists public.feedback (
    id           uuid primary key default gen_random_uuid(),
    created_at   timestamptz not null default now(),
    -- Where in the app it came from, e.g. "excerpt-note:pitfalls", "excerpt-fact", "settings".
    context      text not null check (char_length(context) <= 64),
    -- Catalogue excerpt id when the report is about one excerpt.
    excerpt_id   text check (excerpt_id is null or char_length(excerpt_id) <= 128),
    message      text not null check (char_length(message) between 1 and 2000),
    app_version  text check (app_version is null or char_length(app_version) <= 32),
    -- sha256(FEEDBACK_HASH_SALT + X-Device-Id), hex. Never the raw device id.
    device_hash  text not null,
    -- Triage, set by hand in the Supabase table editor.
    status       text not null default 'new' check (status in ('new', 'handled', 'ignored'))
);

comment on table public.feedback is
    'In-app feedback and error reports from Auditioner. Service role only; no RLS policies on purpose.';

create index if not exists feedback_created_at_idx on public.feedback (created_at);

alter table public.feedback enable row level security;

-- No policies: only the service role (used by the server) can read or write.
-- Belt and braces — take away the table privileges PostgREST would otherwise grant.
revoke all on table public.feedback from anon, authenticated;
