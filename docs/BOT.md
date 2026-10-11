# AuditionerBot — what our crawler does on your website

**AuditionerBot** is the web crawler of [Auditioner](https://github.com/milaiwalkerproject-ui/auditioner),
an iPhone/iPad app that helps orchestral musicians prepare for orchestra auditions.
It visits the **public audition pages of orchestras** so the app can tell musicians
"this orchestra is holding an audition; here is the repertoire list, on the
orchestra's own site". This page explains what the bot does, what it never does, and
how to keep it off your site.

## How it identifies itself

User-Agent: `AuditionerBot/0.1 (+https://github.com/milaiwalkerproject-ui/auditioner/blob/main/docs/BOT.md)`

## What it reads

- Only **orchestras' own public websites**, from a short list we keep by hand
  (`content/registry/orchestras.json` in the repository). An orchestra is on the list
  because it publishes audition information on its own site.
- On those sites: the audition / vacancies page, pages it links to on the same site
  that are about auditions, and **repertoire or audition documents** (PDF, Word) that
  those pages link to — also when the document is hosted elsewhere (a CDN, a file
  host), as long as the orchestra's own page links to it.
- From what it reads it keeps **facts only**: the position, the instrument, the
  application deadline and audition dates the page states, and the list of works and
  excerpts with the bar numbers or rehearsal marks printed on the list — each with a
  link back to your page or document as the source.

## What it never does

- It never reads audition aggregators or job boards (AFM *International Musician*,
  League of American Orchestras jobs, Musical Chairs, muvac listing pages,
  OrchestraPLAN, Audition Cafe), social networks, or score libraries. One narrow
  exception: a document on `assets.muvac.com` that an orchestra's own page links to.
- It never logs in, never sends cookies, never fills in forms, never solves CAPTCHAs
  and never runs your page's scripts. It only reads what any visitor sees without an
  account.
- It never republishes your documents. PDFs and Word files are read, the facts are
  taken down with a link to the original, and the file is not stored or served
  anywhere by us.
- It never stores personal data. Email addresses and phone numbers are stripped by
  code from everything the bot keeps (`backend/crawler/redact.py`); staff names are
  left out by the instructions the extraction follows and by the person who checks
  every list before it is shown. Only the orchestra's name and the position remain.
- It makes **one request at a time per website, at least 10 seconds apart** (longer
  if your `robots.txt` asks with `Crawl-delay` — a long delay is honoured in full and
  the bot simply reads fewer pages that night, never more than about 20 minutes of
  requests per site), visits each page about **once a night**, and asks "has this
  changed?" first (`If-None-Match` / `If-Modified-Since`), so an unchanged page costs
  your server a 304 and nothing more.
- It reads at most 15 MB per document and only `http(s)` addresses.
- If your server answers **429 or 503** it waits as long as `Retry-After` says (or an
  hour) before asking again; if it answers **403** it stops for the night.

## How to keep it off your site

Add a rule for it to your `robots.txt`; the bot reads `robots.txt` before anything
else and follows `Disallow` and `Crawl-delay`:

```
User-agent: AuditionerBot
Disallow: /
```

To keep it away from one folder only:

```
User-agent: AuditionerBot
Disallow: /internal/
Crawl-delay: 30
```

If you would rather not change `robots.txt`, or want your orchestra removed from the
list altogether, contact us **through the app** (Settings → Report a problem) and say
which site; we remove it by hand. We keep a log of removals.

## Why it exists

Musicians preparing for an audition want one honest answer to "what will they ask
me to play?". Orchestras already publish that answer; the bot only makes it findable
inside the app, with a link to the orchestra's own page, and a person checks every
list before it is shown. The rules on this page are the rules the code enforces
(`backend/crawler/` in the repository — `policy.py`, `robots.py`, `fetcher.py`), and
the tests there check them.
