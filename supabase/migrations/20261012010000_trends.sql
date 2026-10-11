-- Auditioner: community practice trends — "Popular with cellists" (PLAN D6).
-- Written and read by the server only (POST/DELETE/GET /v1/trends, backend/app/trends.py)
-- with the service-role key, which bypasses row level security. RLS is on and there
-- are NO policies, so the anon and authenticated roles can neither read nor write.
--
-- Append-only: never edit an applied migration — add a new numbered file.
--
-- Privacy: sharing is opt-in in the app (off by default). A row holds only an
-- instrument, catalogue excerpt ids and an ISO week. contributor_hash is
-- HMAC-SHA256(TRENDS_SALT, per-install random device id), hex — never the device id
-- itself. One row per contributor + instrument + week, replaced on each post; the
-- server deletes rows for weeks older than 26 weeks, and everything a contributor
-- shared when they turn sharing off. The app is only ever sent tiers, never counts,
-- and nothing at all below 20 contributors.

create table if not exists public.trend_contributions (
    -- HMAC-SHA256 hex: 64 lowercase hex characters.
    contributor_hash text not null check (contributor_hash ~ '^[0-9a-f]{64}$'),
    -- The app's Instrument raw id ("cello", "double-bass", …); checked by the server.
    instrument       text not null check (instrument ~ '^[a-z-]{1,40}$'),
    -- ISO week, 'YYYY-Www' (fixed width, so text order is week order).
    week             text not null check (week ~ '^[0-9]{4}-W(0[1-9]|[1-4][0-9]|5[0-3])$'),
    -- Catalogue excerpt ids the server knows for that instrument: 1–50, no nulls.
    excerpt_ids      text[] not null
                     check (cardinality(excerpt_ids) between 1 and 50
                            and array_position(excerpt_ids, null) is null),
    updated_at       timestamptz not null default now(),
    primary key (contributor_hash, instrument, week)
);

comment on table public.trend_contributions is
    'Opt-in community practice trends (PLAN D6). Service role only; no RLS policies on purpose.';

-- GET /v1/trends reads one instrument over 8 weeks; retention deletes by week.
create index if not exists trend_contributions_instrument_week_idx
    on public.trend_contributions (instrument, week);
create index if not exists trend_contributions_week_idx
    on public.trend_contributions (week);

alter table public.trend_contributions enable row level security;

-- No policies: only the service role (used by the server) can read or write.
-- Belt and braces — take away the table privileges PostgREST would otherwise grant.
revoke all on table public.trend_contributions from anon, authenticated;
