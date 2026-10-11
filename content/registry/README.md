# Orchestra registry (`content/registry/`)

The list of orchestras whose **own** public audition pages the open-auditions crawler
is allowed to read (PLAN F1, F2; polite-crawler rules in `docs/BOT.md`). One JSON file,
one schema, one validator.

| File | What it is |
|---|---|
| `orchestras.json` | The registry. Source of truth for the crawler's source list. |
| `schema.json` | JSON Schema (draft 2020-12) for `orchestras.json`. |
| `validate_registry.py` | Schema + honesty checks. Run before every commit. |

```sh
pip install jsonschema
python3 content/registry/validate_registry.py     # exit 1 on any problem
```

## What an entry looks like

```json
{
  "id": "boston-symphony",
  "name": "Boston Symphony Orchestra",
  "country": "US",
  "region": "north-america",
  "city": "Boston",
  "type": "professional",
  "auditionsUrl": "https://bso.org/about/jobs/bso-auditions",
  "homepageUrl": "https://bso.org",
  "notes": "'BSO Auditions' page seen on bso.org (HTML; audition announcements as PDFs on cdn.bso.org).",
  "source": "https://bso.org/about/jobs/bso-auditions",
  "asOf": "2026-10-11",
  "groups": ["icsom"]
}
```

| Field | Rule |
|---|---|
| `id` | kebab-case, unique, never changes once the crawler has stored data under it. For Tutti orgs it is Tutti's org id. |
| `name` | As the orchestra writes it. |
| `country` | ISO 3166-1 alpha-2 (`PR` Puerto Rico, `HK` Hong Kong). |
| `region` | `north-america` · `europe-german` (DE/AT/CH) · `europe-other` · `uk` · `asia-pacific` · `other`. Same buckets as the catalogue's `frequencyEvidence.region`. The validator checks it matches `country`. |
| `city` | Home city (Tutti's `area` for Southern California orgs). |
| `type` | `professional` · `youth` · `collegiate` · `community` (Tutti's types, same words). |
| `auditionsUrl` | **Optional.** The orchestra's own page that lists auditions/vacancies, exactly as seen. Leave it out if you have not seen it. |
| `homepageUrl` | **Optional.** The orchestra's own site, only if seen. |
| `notes` | Plain words for the next person: where the URL came from, whether the page is an HTML list or links to PDFs, or `audition page not yet found`. |
| `source` | Where this entry was seen: Tutti's `data.json`, the orchestra's own page, or (when no official page has been seen yet) a reference page such as the ICSOM roster or Wikipedia. |
| `asOf` | The day you looked. |
| `tutti.orgId` | **Optional.** Tutti `organizations[].id`, so the crawler can later propose audition-window drafts to Tutti (PLAN U2). |
| `groups` | **Optional.** Which PLAN F2 bucket this fills: `icsom`, `tutti-socal`, `canada-majors`, `australia-six`, `uk-majors`, `europe-majors`, `japan`, `asia`, `la-phil-family`. |

## The honesty rules (the validator enforces what it can)

1. **Never guess a URL from a pattern.** `aso.org/auditions` is not a fact until you have
   seen that exact address on the orchestra's site or in a search result pointing at it.
   If you have not seen the auditions page, leave `auditionsUrl` out and write
   `audition page not yet found` in `notes` (the validator insists on this phrase).
2. **Only the orchestra's own pages.** Aggregators and third-party republishers are never
   crawled or linked, anywhere in the file: Musical Chairs, muvac, OrchestraPLAN, Audition
   Cafe, AFM / *International Musician*, League of American Orchestras job board,
   Facebook/Instagram, and job-board republishers such as The Violin Channel, CelloBello,
   Harp Column. The validator rejects these hosts (and their subdomains). Many orchestras
   *say* "apply via muvac" on their own page; that is fine, we read their page and link to it.
3. **https only.** No `http://` anywhere.
4. **Facts + link only.** The registry stores no staff names, emails or phone numbers.
   Do not paste contact details into `notes`.
5. `auditionsUrl` must be on the same domain as `homepageUrl` (when both are present);
   if it is not, ask yourself whether it is really the orchestra's page.

## How to add an orchestra

1. Search for the orchestra's own audition/vacancy page, e.g. `"<orchestra> auditions site:<its domain>"`.
   You are looking for a page **on their domain** whose title says auditions / vacancies /
   careers / employment / "work with us".
2. Add an entry with the fields above. Put the exact URL you saw in `auditionsUrl`
   and in `source`. Say in `notes` what the page looks like (HTML list, PDF links,
   individual postings under a path, WordPress `?p=` short link, and so on). That tells
   the crawler author what to expect.
3. If you only found individual posting pages (one per vacancy) but no index page,
   leave `auditionsUrl` out, put one posting URL in `source`, and say so in `notes`.
4. Run `python3 content/registry/validate_registry.py`.
5. Commit the JSON together with any doc change it needs. Milai approves the merge.

Southern California entries (36, `groups: ["tutti-socal"]`) were derived from Tutti's
verified `data.json` (`milaiwalkerproject-ui/tutti`): `auditionsUrl` is Tutti's
`auditions[].source` (or `applyUrl`) when that page is not just the homepage; `type`,
`name`, `area` and `website` are Tutti's. Keep them in step with Tutti by hand for now; a
re-import script can live in this folder when Tutti's orgs formally join the crawl
registry (PLAN U2).

## State of the list (as of 2026-10-11, version 0.1.0)

128 orchestras, 80 with a verified `auditionsUrl`.

| Region | Entries | With auditions page |
|---|---|---|
| north-america | 92 | 68 |
| uk | 8 | 2 |
| europe-german | 6 | 1 |
| europe-other | 12 | 3 |
| asia-pacific | 10 | 6 |

By type: 102 professional, 24 youth, 2 community, 0 collegiate.

Buckets: all 51 ICSOM orchestras are listed (34 with an auditions page); all 36 Tutti
Southern California orgs (32 with a page); 6 Canadian majors (3); the Australian six (4);
HK Phil, Singapore SO, Sapporo SO, Tokyo Metropolitan SO; 8 UK, 6 German/Austrian and
12 other European majors as a first pass.

**Notable gaps to fill next** (each has a stub entry marked `audition page not yet found`):

- ICSOM orchestras whose own page did not surface in search: New York Philharmonic,
  Seattle Symphony, Cincinnati Symphony, Baltimore Symphony, National Symphony, The
  Florida Orchestra, Grand Rapids Symphony, Alabama Symphony, Jacksonville Symphony,
  Rochester Philharmonic, San Antonio Philharmonic, Orquesta Sinfónica de Puerto Rico,
  Kennedy Center Opera House Orchestra. Four more have individual posting pages but no
  index page seen: Philadelphia Orchestra, Indianapolis Symphony, Phoenix Symphony,
  San Francisco Opera Orchestra.
- Canada: OSM and Vancouver publish auditions as PDFs (no index page seen); Hamilton
  Philharmonic not found.
- Australia: Queensland and West Australian have per-vacancy pages only.
- Europe: most German/Austrian/French/Nordic/Spanish/Italian majors need a second look
  with native-language queries (Probespiel, concours, prøvespill, provspelning,
  audizioni, convocatoria); several publish only PDFs or use Muvac.
- Not yet started: ROPA and other US regional orchestras, Japan Orchestra Federation
  members beyond Sapporo/Tokyo Metropolitan (NHK SO not found), the Nordic radio
  orchestras, Korea/Taiwan/New Zealand.
- Tutti professional orgs with no auditions page found: LACO, Pasadena Symphony,
  San Bernardino Symphony, Culver City Symphony.

The crawler should treat an entry **without** `auditionsUrl` as "not crawlable yet";
it may read `homepageUrl` only to help a human find the page, never to infer one.
