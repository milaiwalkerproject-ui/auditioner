-- Open auditions feed: what the crawler writes, what Milai reviews, what the app reads.
-- PLAN F1–F4 (feed), D5 (recommendations), CLAUDE.md honesty contract.
--
-- Append-only: never edit an applied migration — add a new numbered file.
--
-- Who touches what:
--   * the crawler (backend/crawler) writes with the service-role key (bypasses RLS);
--   * Milai reviews in the Supabase table editor and sets review_status = 'published';
--   * the app reads with the public anon key and can only ever see published rows.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- helpers

create or replace function public.auditions_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- "Section cello" / "Assistant Principal Cello" / "Solo-Cellist" → a class the
-- recommendation view can group by. Deliberately coarse; the app maps finer.
create or replace function public.position_class(p text)
returns text
language sql
immutable
as $$
  select case
    when p is null or btrim(p) = '' then 'unknown'
    when lower(p) ~ '(assistant|associate|assoc\.|stellvertret|co-principal|coprincipal|vice)' then 'assistant-principal'
    when lower(p) ~ '(principal|concertmaster|konzertmeister|solo|leader|first chair|1st chair|erste)' then 'principal'
    when lower(p) ~ '(section|tutti|utility|rank and file|ripieno|sub-principal|sub principal)' then 'section'
    else 'other'
  end
$$;

-- ---------------------------------------------------------------- orchestras

-- Mirror of content/registry/orchestras.json (the registry file stays the source of truth).
create table if not exists public.orchestras (
  id          text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  data        jsonb not null check (jsonb_typeof(data) = 'object' and data ? 'name' and data ? 'region'),
  updated_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------- audition_sources

-- Per-address crawl state: validators for conditional GET, hashes for change detection.
create table if not exists public.audition_sources (
  url              text primary key check (url ~ '^https?://'),
  orchestra_id     text references public.orchestras(id) on delete set null,
  kind             text not null default 'page' check (kind in ('page', 'document')),
  etag             text,
  last_modified    text,
  content_hash     text,
  text_hash        text,
  last_checked_at  timestamptz,
  last_changed_at  timestamptz,
  status           text not null default 'ok'
                   check (status in ('ok', 'unchanged', 'gone', 'forbidden', 'rate_limited', 'error', 'refused', 'too_large', 'robots')),
  note             text,
  extra            jsonb not null default '{}'::jsonb check (jsonb_typeof(extra) = 'object')
);

create index if not exists audition_sources_orchestra_idx on public.audition_sources (orchestra_id);

-- ---------------------------------------------------------------- vacancies

create table if not exists public.vacancies (
  id                    uuid primary key default gen_random_uuid(),
  natural_key           text not null unique,              -- sha256(orchestra|source|position|instrument|chair), see crawler/store.py
  orchestra_id          text not null references public.orchestras(id) on delete cascade,
  position              text not null default '',
  instrument            text not null default 'other'
                        check (instrument in ('violin', 'viola', 'cello', 'double-bass', 'harp', 'flute', 'piccolo', 'oboe',
                                              'english-horn', 'clarinet', 'e-flat-clarinet', 'bass-clarinet', 'bassoon',
                                              'contrabassoon', 'horn', 'trumpet', 'trombone', 'bass-trombone', 'tuba',
                                              'timpani', 'percussion', 'keyboard', 'other')),
  chair                 text not null default '',
  application_deadline  date,                              -- null = the source gives none we could verify
  audition_dates        jsonb not null default '[]'::jsonb check (jsonb_typeof(audition_dates) = 'array'),
  list_completeness     text not null default 'unknown'
                        check (list_completeness in ('full', 'partial_public', 'works_only', 'revealed_on_invitation', 'unknown')),
  source_url            text not null check (source_url ~ '^(https?://|file:)'),
  source_kind           text not null default 'pdf',
  first_seen_at         timestamptz not null default now(),
  last_seen_at          timestamptz not null default now(),
  review_status         text not null default 'in_review'
                        check (review_status in ('draft', 'in_review', 'published', 'rejected')),
  snapshot_hash         text not null,
  extraction            jsonb not null default '{}'::jsonb check (jsonb_typeof(extraction) = 'object'),
  flags                 jsonb not null default '[]'::jsonb check (jsonb_typeof(flags) = 'array'),
  reviewed_by           text,
  reviewed_at           timestamptz,
  review_note           text,
  updated_at            timestamptz not null default now(),

  -- Honesty contract: nothing is published without a public address to check it
  -- against, a named position and instrument, and a human who looked at it.
  constraint vacancies_published_need_public_source
    check (review_status <> 'published' or source_url ~ '^https?://'),
  constraint vacancies_published_need_position
    check (review_status <> 'published' or (position <> '' and instrument <> 'other')),
  constraint vacancies_published_need_reviewer
    check (review_status <> 'published' or reviewed_by is not null)
);

create index if not exists vacancies_orchestra_idx on public.vacancies (orchestra_id);
create index if not exists vacancies_review_instrument_idx on public.vacancies (review_status, instrument);
create index if not exists vacancies_deadline_idx on public.vacancies (application_deadline);

drop trigger if exists vacancies_touch_updated_at on public.vacancies;
create trigger vacancies_touch_updated_at
  before update on public.vacancies
  for each row execute function public.auditions_touch_updated_at();

-- ---------------------------------------------------------------- vacancy_items

create table if not exists public.vacancy_items (
  id                uuid primary key default gen_random_uuid(),
  vacancy_id        uuid not null references public.vacancies(id) on delete cascade,
  ordinal           integer not null default 0,
  raw_text          text not null default '',             -- the source line(s), verbatim: the evidence
  round             text not null default '',
  category          text not null default 'other'
                    check (category in ('solo', 'excerpt', 'sight_reading', 'chamber', 'other')),
  composer          text not null default '',
  work              text not null default '',
  catalogue_number  text not null default '',
  movement          text not null default '',
  part              text not null default '',
  location          jsonb not null default '{}'::jsonb check (jsonb_typeof(location) = 'object'),
  source_line_ids   jsonb not null default '[]'::jsonb check (jsonb_typeof(source_line_ids) = 'array'),
  notes             text not null default '',
  excerpt_id        text,                                  -- content/catalog excerpt id when mapped
  match_confidence  numeric(4, 3)
                    check (match_confidence is null or (match_confidence >= 0 and match_confidence <= 1)),
  match_bucket      text not null default 'new_candidate'
                    check (match_bucket in ('auto', 'review', 'new_candidate')),
  verification      jsonb not null default '{}'::jsonb check (jsonb_typeof(verification) = 'object'),
  review_status     text not null default 'in_review'
                    check (review_status in ('draft', 'in_review', 'published', 'rejected')),
  reviewed_by       text,
  reviewed_at       timestamptz,
  review_note       text,
  updated_at        timestamptz not null default now(),

  -- Honesty contract, in the database:
  --   * a bar range is either absent or a parsed, ordered pair (end ≥ start ≥ 1);
  constraint vacancy_items_bars_parse check (
    coalesce(location->>'type', 'unknown') <> 'measures'
    or (
      coalesce(location->>'startBar', '') ~ '^[0-9]+$'
      and coalesce(location->>'endBar', '') ~ '^[0-9]+$'
      and (location->>'startBar')::integer >= 1
      and (location->>'endBar')::integer >= (location->>'startBar')::integer
    )
  ),
  --   * a mapped item always carries its confidence;
  constraint vacancy_items_mapping_needs_confidence
    check (excerpt_id is null or match_confidence is not null),
  --   * a published item shows its evidence, and is either verified against the
  --     cited source lines by the code or explicitly signed off by a person.
  constraint vacancy_items_published_need_evidence
    check (review_status <> 'published' or raw_text <> ''),
  constraint vacancy_items_published_need_verification_or_reviewer
    check (review_status <> 'published' or (verification->>'ok') = 'true' or reviewed_by is not null)
);

create index if not exists vacancy_items_vacancy_idx on public.vacancy_items (vacancy_id, ordinal);
create index if not exists vacancy_items_excerpt_idx on public.vacancy_items (excerpt_id) where excerpt_id is not null;

drop trigger if exists vacancy_items_touch_updated_at on public.vacancy_items;
create trigger vacancy_items_touch_updated_at
  before update on public.vacancy_items
  for each row execute function public.auditions_touch_updated_at();

-- ---------------------------------------------------------------- crawl_runs

-- One row per nightly run (the JSON summary the CLI prints). Service role only.
create table if not exists public.crawl_runs (
  id           uuid primary key default gen_random_uuid(),
  finished_at  timestamptz not null default now(),
  summary      jsonb not null default '{}'::jsonb check (jsonb_typeof(summary) = 'object')
);

-- ---------------------------------------------------------------- views for the app

-- Published vacancies with the orchestra's registry facts, ready for the feed.
create or replace view public.open_auditions
with (security_invoker = true)
as
select
  v.id,
  v.orchestra_id,
  o.data->>'name'    as orchestra_name,
  o.data->>'country' as country,
  o.data->>'region'  as region,
  o.data->>'city'    as city,
  o.data->>'type'    as orchestra_type,
  v.position,
  public.position_class(v.position) as position_class,
  v.instrument,
  v.chair,
  v.application_deadline,
  v.audition_dates,
  v.list_completeness,
  v.source_url,
  v.first_seen_at,
  v.last_seen_at
from public.vacancies v
join public.orchestras o on o.id = v.orchestra_id
where v.review_status = 'published';

-- "What orchestras ask": recency-weighted frequency with a 3-year half-life
-- (PLAN D5) per instrument + position class + region + excerpt, over published
-- lists only. A list dated by its deadline, else by when we first saw it.
create or replace view public.excerpt_frequency
with (security_invoker = true)
as
with lists as (
  select
    v.id,
    v.instrument,
    public.position_class(v.position) as position_class,
    coalesce(o.data->>'region', 'other') as region,
    coalesce(v.application_deadline, v.first_seen_at::date) as list_date,
    power(
      0.5,
      greatest(0, extract(epoch from (now() - coalesce(v.application_deadline::timestamptz, v.first_seen_at))))
        / (3.0 * 365.25 * 86400)
    ) as weight
  from public.vacancies v
  join public.orchestras o on o.id = v.orchestra_id
  where v.review_status = 'published'
),
totals as (
  select instrument, position_class, region,
         sum(weight) as weighted_lists,
         count(*)    as n_lists
  from lists
  group by 1, 2, 3
),
list_excerpts as (
  -- one row per (list, excerpt), however many items of the list map to that excerpt
  select distinct i.vacancy_id, i.excerpt_id
  from public.vacancy_items i
  where i.review_status = 'published' and i.excerpt_id is not null
),
hits as (
  select
    l.instrument, l.position_class, l.region, e.excerpt_id,
    sum(l.weight)     as weighted_hits,
    count(*)          as n_lists_with_excerpt,
    min(l.list_date)  as earliest_list_date,
    max(l.list_date)  as latest_list_date
  from lists l
  join list_excerpts e on e.vacancy_id = l.id
  group by 1, 2, 3, 4
)
select
  h.instrument,
  h.position_class,
  h.region,
  h.excerpt_id,
  h.weighted_hits,
  t.weighted_lists,
  h.n_lists_with_excerpt,
  t.n_lists,
  h.weighted_hits / nullif(t.weighted_lists, 0) as share,
  h.earliest_list_date,
  h.latest_list_date
from hits h
join totals t using (instrument, position_class, region);

-- The same frequency blended with a prior (PLAN D5: "blended with a prior, k≈10
-- lists"): the prior is the excerpt's share across all regions for the same
-- instrument and position class, so a region with three lists does not swing to
-- 100%/0%. score = (weighted_hits + k·prior) / (weighted_lists + k).
create or replace function public.excerpt_recommendations(
  p_instrument text,
  p_position_class text,
  p_region text,
  p_prior_lists numeric default 10
)
returns table (
  excerpt_id            text,
  score                 numeric,
  share                 numeric,
  prior_share           numeric,
  weighted_hits         numeric,
  weighted_lists        numeric,
  n_lists_with_excerpt  bigint,
  n_lists               bigint,
  earliest_list_date    date,
  latest_list_date      date,
  tier                  text,
  evidence              text
)
language sql
stable
security invoker
as $$
  with all_regions as (
    select * from public.excerpt_frequency
    where instrument = p_instrument and position_class = p_position_class
  ),
  region_total as (
    select coalesce(max(weighted_lists), 0) as weighted_lists, coalesce(max(n_lists), 0) as n_lists
    from all_regions where region = p_region
  ),
  global_total as (
    select coalesce(sum(weighted_lists), 0) as weighted_lists
    from (select distinct region, weighted_lists from all_regions) r
  ),
  global_hits as (
    select excerpt_id, sum(weighted_hits) as weighted_hits from all_regions group by excerpt_id
  ),
  region_hits as (
    select * from all_regions where region = p_region
  ),
  scored as (
    select
      g.excerpt_id,
      coalesce(r.weighted_hits, 0)                                   as weighted_hits,
      rt.weighted_lists                                              as weighted_lists,
      coalesce(r.n_lists_with_excerpt, 0)                            as n_lists_with_excerpt,
      rt.n_lists                                                     as n_lists,
      r.earliest_list_date,
      r.latest_list_date,
      case when gt.weighted_lists > 0 then g.weighted_hits / gt.weighted_lists else 0 end as prior_share,
      case when rt.weighted_lists > 0 then coalesce(r.weighted_hits, 0) / rt.weighted_lists end as share
    from global_hits g
    cross join region_total rt
    cross join global_total gt
    left join region_hits r on r.excerpt_id = g.excerpt_id
  )
  select
    s.excerpt_id,
    round((s.weighted_hits + p_prior_lists * s.prior_share) / nullif(s.weighted_lists + p_prior_lists, 0), 4) as score,
    round(s.share, 4)        as share,
    round(s.prior_share, 4)  as prior_share,
    round(s.weighted_hits, 4),
    round(s.weighted_lists, 4),
    s.n_lists_with_excerpt,
    s.n_lists,
    s.earliest_list_date,
    s.latest_list_date,
    case
      when (s.weighted_hits + p_prior_lists * s.prior_share) / nullif(s.weighted_lists + p_prior_lists, 0) >= 0.5 then 'core'
      when (s.weighted_hits + p_prior_lists * s.prior_share) / nullif(s.weighted_lists + p_prior_lists, 0) >= 0.2 then 'common'
      else 'occasional'
    end as tier,
    case
      when s.n_lists_with_excerpt > 0 then
        format('On %s of %s %s %s lists (%s), %s–%s',
               s.n_lists_with_excerpt, s.n_lists, p_position_class, p_instrument, p_region,
               extract(year from s.earliest_list_date)::int, extract(year from s.latest_list_date)::int)
      when s.n_lists > 0 then
        format('Not on any of the %s %s %s lists we have (%s); the score comes from other regions',
               s.n_lists, p_position_class, p_instrument, p_region)
      else format('No %s %s lists from %s yet; the score comes from other regions',
                  p_position_class, p_instrument, p_region)
    end as evidence
  from scored s
  order by score desc, s.excerpt_id
$$;

-- "On N open auditions now" (PLAN D5: kept separate from the frequency). Open =
-- deadline today or later, or no deadline but seen on the orchestra's page in the
-- last 60 days.
create or replace view public.excerpt_open_now
with (security_invoker = true)
as
select
  i.excerpt_id,
  v.instrument,
  count(distinct v.id) as open_vacancies
from public.vacancies v
join public.vacancy_items i on i.vacancy_id = v.id
where v.review_status = 'published'
  and i.review_status = 'published'
  and i.excerpt_id is not null
  and (
    v.application_deadline >= current_date
    or (v.application_deadline is null and v.last_seen_at >= now() - interval '60 days')
  )
group by 1, 2;

-- ---------------------------------------------------------------- row level security

alter table public.orchestras        enable row level security;
alter table public.audition_sources  enable row level security;
alter table public.vacancies         enable row level security;
alter table public.vacancy_items     enable row level security;
alter table public.crawl_runs        enable row level security;

-- The app (anon / signed-in users) may only read; and only what is published.
revoke all on public.audition_sources, public.crawl_runs from anon, authenticated;
revoke insert, update, delete, truncate, references, trigger
  on public.orchestras, public.vacancies, public.vacancy_items from anon, authenticated;
grant select on public.orchestras, public.vacancies, public.vacancy_items to anon, authenticated;
grant select on public.open_auditions, public.excerpt_frequency, public.excerpt_open_now to anon, authenticated;
grant execute on function public.position_class(text) to anon, authenticated;
grant execute on function public.excerpt_recommendations(text, text, text, numeric) to anon, authenticated;

drop policy if exists "anyone reads the orchestra registry" on public.orchestras;
create policy "anyone reads the orchestra registry"
  on public.orchestras for select to anon, authenticated
  using (true);

drop policy if exists "anyone reads published vacancies" on public.vacancies;
create policy "anyone reads published vacancies"
  on public.vacancies for select to anon, authenticated
  using (review_status = 'published');

drop policy if exists "anyone reads published items of published vacancies" on public.vacancy_items;
create policy "anyone reads published items of published vacancies"
  on public.vacancy_items for select to anon, authenticated
  using (
    review_status = 'published'
    and exists (
      select 1 from public.vacancies v
      where v.id = vacancy_items.vacancy_id and v.review_status = 'published'
    )
  );

-- No insert/update/delete policies: writes come only from the service role (the
-- crawler) and from the table editor, which also uses it.
