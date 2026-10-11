-- Auditioner: optional accounts with Sign in with Apple (PLAN B2).
-- Written and read by the server only (backend/app/accounts.py, /v1/account…) with the
-- service-role key, which bypasses row level security. RLS is on and there are NO
-- policies, so the anon and authenticated roles can neither read nor write a row.
--
-- What is kept, and what never is:
--   * apple_sub_hash — HMAC-SHA256(ACCOUNT_SECRET, Apple's user id), hex. Never the id.
--   * apple_refresh_token_enc — Apple's refresh token, Fernet-encrypted with a key
--     derived from ACCOUNT_SECRET. Kept only to revoke it when the account is deleted.
--   * No email, no name.
--   * account_sessions.token_hash — sha256 hex of the session token the app holds.
--     A session unused for 365 days stops working and is deleted.
-- Deleting the account (DELETE /v1/account) removes its row and, by cascade, every
-- session.

create table if not exists public.accounts (
    id                       uuid primary key default gen_random_uuid(),
    apple_sub_hash           text unique not null,
    apple_refresh_token_enc  text not null,
    created_at               timestamptz default now(),
    last_seen_at             timestamptz
);

comment on table public.accounts is
    'Sign in with Apple accounts. Hashed Apple id and encrypted refresh token only. Service role only; no RLS policies on purpose.';

create table if not exists public.account_sessions (
    token_hash    text primary key,
    account_id    uuid not null references public.accounts (id) on delete cascade,
    created_at    timestamptz default now(),
    last_used_at  timestamptz default now()
);

comment on table public.account_sessions is
    'App sessions (sha256 of the session token). Service role only; no RLS policies on purpose.';

-- Deleting an account cascades through this; signing in clears sessions unused for a year.
create index if not exists account_sessions_account_id_idx on public.account_sessions (account_id);
create index if not exists account_sessions_last_used_at_idx on public.account_sessions (last_used_at);

alter table public.accounts enable row level security;
alter table public.account_sessions enable row level security;

-- No policies: only the service role (used by the server) can read or write.
-- Belt and braces — take away the table privileges PostgREST would otherwise grant.
revoke all on table public.accounts from anon, authenticated;
revoke all on table public.account_sessions from anon, authenticated;
