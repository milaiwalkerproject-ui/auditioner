#!/usr/bin/env python3
"""Import brass excerpt metadata from the MIT-licensed BrassXcerpts app data.

Source: https://github.com/aburdiss/BrassExcerpts (Alexander Burdiss, MIT).
The clone is treated as untrusted DATA: nothing in it is executed. The
TypeScript object literals are read with a small tokenizer/parser written here,
and the job lists are plain JSON.

Usage (from the repo root, with a clone of BrassExcerpts checked out at the
pinned commit):

    python3 -I content/importers/brassxcerpts.py /path/to/BrassExcerpts \
        [--commit 4a06fc5be35c511397c6fe86e1ba976245d55b8b] [--as-of 2026-10-10] \
        [--out content/catalog] [--report]

Writes content/catalog/{horn,trumpet,trombone,bass-trombone,tuba}.json.

What is imported (see the mapping rules in the report printed with --report):
  * one catalogue excerpt per BrassXcerpts excerpt (composer, work, movement,
    bar-range text, part labels) — images are NOT imported;
  * YouTube recording links from YouTubeModel.ts (ids only, no timestamps);
  * frequency evidence from the real audition lists in Jobs/*.json.
Prose, bowings, fingerings, tempo guesses and the "professional advice"
quotations in the source are deliberately NOT imported (CLAUDE.md honesty
contract: facts only, nothing copied, nothing invented).
"""
from __future__ import annotations

import argparse
import collections
import json
import pathlib
import re
import sys
import unicodedata

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------

DEFAULT_COMMIT = "4a06fc5be35c511397c6fe86e1ba976245d55b8b"
DEFAULT_AS_OF = "2026-10-10"
REPO_WEB = "https://github.com/aburdiss/BrassExcerpts"

# BrassXcerpts file -> catalogue instrument(s) it feeds.
SOURCE_FILES = {
    "Horn": ["horn"],
    "Trumpet": ["trumpet"],
    "Trombone": ["trombone", "bass-trombone"],
    "Tuba": ["tuba"],
}

# YouTubeModel group that holds instrument-specific (solo / masterclass) videos.
SOLO_GROUP = {
    "horn": "horn",  # no such group exists in the data today; harmless
    "trumpet": "trumpet",
    "trombone": "trombone",
    "bass-trombone": "trombone",
    "tuba": "tuba",
}

# Groups that are full-ensemble performances.
FULL_GROUPS = ("full", "band")

YOUTUBE_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")

# Composition keys used in Jobs files that are typos of real keys.
KEY_ALIASES = {
    "wagnerGotterdamerung": "wagnerGotterdammerung",
}

# Spelling harmonisation only (same person, different spelling in the source).
COMPOSER_SPELLING = {
    "Ludwig Van Beethoven": "Ludwig van Beethoven",
    "Gioacchino Rossini": "Gioachino Rossini",
    "Nikolay Rimsky-Korsakov": "Nikolai Rimsky-Korsakov",
    "Pyotr Tchaikovsky": "Pyotr Ilyich Tchaikovsky",
}

REGION_BY_COUNTRY = {
    # north-america
    "USA": "north-america",
    "United States": "north-america",
    "Canada": "north-america",
    # europe-german
    "Germany": "europe-german",
    "Austria": "europe-german",
    "Switzerland": "europe-german",
    # uk
    "United Kingdom": "uk",
    "UK": "uk",
    # europe-other
    "Belgium": "europe-other",
    "Bulgaria": "europe-other",
    "Croatia": "europe-other",
    "Czech Republic": "europe-other",
    "Denmark": "europe-other",
    "Estonia": "europe-other",
    "Finland": "europe-other",
    "France": "europe-other",
    "Greece": "europe-other",
    "Hungary": "europe-other",
    "Iceland": "europe-other",
    "Ireland": "europe-other",
    "Italy": "europe-other",
    "Latvia": "europe-other",
    "Lithuania": "europe-other",
    "Luxembourg": "europe-other",
    "Netherlands": "europe-other",
    "Norway": "europe-other",
    "Poland": "europe-other",
    "Portugal": "europe-other",
    "Romania": "europe-other",
    "Slovakia": "europe-other",
    "Slovenia": "europe-other",
    "Spain": "europe-other",
    "Sweden": "europe-other",
    # asia-pacific
    "Australia": "asia-pacific",
    "China": "asia-pacific",
    "Hong Kong": "asia-pacific",
    "Japan": "asia-pacific",
    "Malaysia": "asia-pacific",
    "New Zealand": "asia-pacific",
    "Singapore": "asia-pacific",
    "South Korea": "asia-pacific",
    "Taiwan": "asia-pacific",
    # everything else (incl. Turkey, Israel, Egypt, South Africa, Mexico) -> other
}

MONTHS = {
    m: i + 1
    for i, m in enumerate(
        ["January", "February", "March", "April", "May", "June", "July",
         "August", "September", "October", "November", "December"]
    )
}

ROMAN = {"I": 1, "V": 5, "X": 10}


# --------------------------------------------------------------------------
# A tiny tokenizer + parser for the TS object-literal subset used by the data
# --------------------------------------------------------------------------

class Ident(str):
    """A bare identifier appearing as a value (e.g. a variable reference)."""


class Tok:
    __slots__ = ("kind", "val", "pos")

    def __init__(self, kind: str, val, pos: int):
        self.kind, self.val, self.pos = kind, val, pos

    def __repr__(self) -> str:  # pragma: no cover
        return f"Tok({self.kind},{self.val!r})"


_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "b": "\b", "f": "\f", "v": "\v", "0": "\0"}


def tokenize(src: str) -> list[Tok]:
    toks: list[Tok] = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c in " \t\r\n":
            i += 1
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j + 1
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            if j < 0:
                raise SyntaxError(f"unterminated block comment at {i}")
            i = j + 2
        elif c in "'\"`":
            quote = c
            j = i + 1
            buf = []
            while j < n and src[j] != quote:
                if src[j] == "\\" and j + 1 < n:
                    e = src[j + 1]
                    buf.append(_ESCAPES.get(e, e))
                    j += 2
                else:
                    if quote == "`" and src.startswith("${", j):
                        raise SyntaxError(f"template interpolation not supported at {j}")
                    buf.append(src[j])
                    j += 1
            if j >= n:
                raise SyntaxError(f"unterminated string at {i}")
            toks.append(Tok("str", "".join(buf), i))
            i = j + 1
        elif c.isdigit() or (c == "-" and i + 1 < n and src[i + 1].isdigit()):
            m = re.compile(r"-?\d+(?:\.\d+)?").match(src, i)
            txt = m.group(0)
            toks.append(Tok("num", float(txt) if "." in txt else int(txt), i))
            i = m.end()
        elif c.isalpha() or c in "_$":
            m = re.compile(r"[A-Za-z_$][A-Za-z0-9_$]*").match(src, i)
            toks.append(Tok("id", m.group(0), i))
            i = m.end()
        elif c in "{}[]:,;=()":
            toks.append(Tok(c, c, i))
            i += 1
        else:
            raise SyntaxError(f"unexpected character {c!r} at {i}: {src[i:i+40]!r}")
    return toks


class Parser:
    def __init__(self, toks: list[Tok]):
        self.toks = toks
        self.i = 0

    def peek(self, k: int = 0) -> Tok | None:
        j = self.i + k
        return self.toks[j] if j < len(self.toks) else None

    def next(self) -> Tok:
        t = self.toks[self.i]
        self.i += 1
        return t

    def expect(self, kind: str, val=None) -> Tok:
        t = self.next()
        if t.kind != kind or (val is not None and t.val != val):
            raise SyntaxError(f"expected {kind} {val or ''} got {t!r} at {t.pos}")
        return t

    def value(self):
        t = self.peek()
        if t is None:
            raise SyntaxError("unexpected end of input")
        if t.kind == "{":
            return self.object()
        if t.kind == "[":
            return self.array()
        if t.kind in ("str", "num"):
            return self.next().val
        if t.kind == "id":
            self.next()
            if t.val == "true":
                return True
            if t.val == "false":
                return False
            if t.val in ("null", "undefined"):
                return None
            return Ident(t.val)
        raise SyntaxError(f"unexpected token {t!r} at {t.pos}")

    def object(self) -> dict:
        self.expect("{")
        out: dict = {}
        while True:
            t = self.peek()
            if t.kind == "}":
                self.next()
                return out
            if t.kind in ("id", "str", "num"):
                key = self.next().val
            else:
                raise SyntaxError(f"bad object key {t!r} at {t.pos}")
            if self.peek().kind == ":":
                self.next()
                out[str(key)] = self.value()
            else:  # shorthand { foo }
                out[str(key)] = Ident(str(key))
            if self.peek().kind == ",":
                self.next()

    def array(self) -> list:
        self.expect("[")
        out: list = []
        while True:
            t = self.peek()
            if t.kind == "]":
                self.next()
                return out
            out.append(self.value())
            if self.peek().kind == ",":
                self.next()


def parse_top_level(src: str) -> dict[str, object]:
    """Return {name: value} for every `let|const|var|export const NAME = <value>;`."""
    p = Parser(tokenize(src))
    out: dict[str, object] = {}
    while p.peek() is not None:
        t = p.next()
        if t.kind == "id" and t.val == "export":
            t = p.next()
        if t.kind == "id" and t.val in ("let", "const", "var"):
            name = p.expect("id").val
            p.expect("=")
            out[name] = p.value()
            if p.peek() is not None and p.peek().kind == ";":
                p.next()
        # anything else (e.g. `export default X;`) is skipped token by token
    return out


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

def strip_accents(s: str) -> str:
    return "".join(c for c in unicodedata.normalize("NFKD", s) if not unicodedata.combining(c))


def norm_text(s: str) -> str:
    s = strip_accents(s).lower().replace("&", " and ")
    s = re.sub(r"[^a-z0-9]+", " ", s).strip()
    s = re.sub(r"\bthe\b", " ", s)
    s = re.sub(r"\bno\b\s*", "no ", s)
    return re.sub(r"\s+", " ", s).strip()


def key_slug(key: str) -> str:
    s = re.sub(r"(?<=[a-z])(?=[A-Z0-9])|(?<=[0-9])(?=[A-Z])", "-", key)
    s = strip_accents(s).lower()
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    return s


def roman_to_int(s: str) -> int | None:
    if s.isdigit():
        return int(s)
    total, prev = 0, 0
    for ch in reversed(s.upper()):
        v = ROMAN.get(ch)
        if v is None:
            return None
        total += -v if v < prev else v
        prev = max(prev, v)
    return total or None


def clean_spaces(s: str) -> str:
    return re.sub(r"\s+", " ", s).strip()


def fix_brace(s: str) -> str:
    """Source typo: '(Waltz}' -> '(Waltz)'. Only when a '(' is closed by '}'."""
    if "(" in s and "}" in s and ")" not in s:
        return s.replace("}", ")")
    return s


def parse_job_date(s: str) -> tuple[str | None, int | None]:
    """'June 19, 2021' -> ('June 19, 2021', 2021). Unknown format -> (text, None)."""
    s = clean_spaces(s or "")
    if not s:
        return None, None
    m = re.fullmatch(r"([A-Z][a-z]+) (\d{1,2}), (\d{4})", s)
    if m and m.group(1) in MONTHS:
        return s, int(m.group(3))
    return s, None


# --------------------------------------------------------------------------
# Measures text -> movement / title / bar points
# --------------------------------------------------------------------------

MOV_RE = re.compile(
    r"^Mov(?:ement)?\.?\s*([IVX]+|\d+)\b\.?(?:\s*\(([^)}]*)[)}])?\s*[,:]?\s*(.*)$"
)
RANGE_MARKERS = re.compile(r"mm\.|\[|\bEnd\b|\bBeginning\b|\d+\s*-\s*\d+|\s-\s", re.I)
PREFIX_RE = re.compile(r"^([^,\[\]]{1,60}?)\s*[:,]\s+(.*)$")

SIMPLE_FORMS = [
    (re.compile(r"^mm\.\s*(\d+)\s*(?:-|–|to)\s*(?:mm\.\s*)?(\d+)$", re.I), "bar", "bar"),
    (re.compile(r"^Beginning\s*(?:-|–|to)\s*(?:mm\.\s*)?(\d+)$", re.I), "beginning", "bar"),
    (re.compile(r"^mm\.\s*(\d+)\s*(?:-|–|to)\s*End$", re.I), "bar", "end"),
    (re.compile(r"^Beginning\s*(?:-|–|to)\s*End$", re.I), "beginning", "end"),
]


def split_movement(measures: str) -> tuple[dict | None, str]:
    """Return (movement-or-None, remainder) from a BrassXcerpts measures string.

    "Mov. I, mm. 12 - 25"            -> ({number: 1}, "mm. 12 - 25")
    "Overture, mm. 1 - 16"           -> ({title: "Overture"}, "mm. 1 - 16")
    "Act I, Scene 3, [46] to [47]"   -> ({title: "Act I, Scene 3"}, "[46] to [47]")
    "4 mm. before [A] - [B]"         -> (None, "4 mm. before [A] - [B]")
    """
    text = clean_spaces(measures)
    mov: dict | None = None
    m = MOV_RE.match(text)
    if m:
        num = roman_to_int(m.group(1))
        mov = {}
        if num:
            mov["number"] = num
        if m.group(2):
            mov["title"] = fix_brace(clean_spaces(m.group(2)))
        if not mov:  # unparsable numeral: keep as a title
            mov["title"] = clean_spaces(m.group(0)[: m.start(3)]).rstrip(",:")
        rest = clean_spaces(m.group(3))
    else:
        rest = text
        # "Overture, mm. 1 - 16" / "No. 17, ..." / "Finale: [17] to End" / "Act I, Scene 3, [46] to ..."
        titles: list[str] = []
        while True:
            pm = PREFIX_RE.match(rest)
            if not pm or RANGE_MARKERS.search(pm.group(1)) or not pm.group(2).strip():
                break
            titles.append(clean_spaces(pm.group(1)).rstrip(":,"))
            rest = clean_spaces(pm.group(2))
        if titles:
            mov = {"title": fix_brace(", ".join(titles))}
    return mov, rest


def parse_simple_range(rest: str) -> tuple[dict | None, dict | None]:
    for rx, kind_a, kind_b in SIMPLE_FORMS:
        m = rx.match(rest)
        if not m:
            continue
        groups = list(m.groups())
        start = {"edge": "beginning"} if kind_a == "beginning" else {"bar": int(groups.pop(0))}
        end = {"edge": "end"} if kind_b == "end" else {"bar": int(groups.pop(0))}
        if "bar" in start and "bar" in end and start["bar"] > end["bar"]:
            return None, None  # source error; leave as text only
        return start, end
    return None, None


def display_title(rest: str, start: dict | None, end: dict | None) -> str:
    """Short display label: 'mm. 12–25', 'Beginning – mm. 17', 'mm. 84 – end', else the text."""
    if start is not None and end is not None:
        if "bar" in start and "bar" in end:
            return f"mm. {start['bar']}–{end['bar']}"
        a = "Beginning" if "edge" in start else f"mm. {start['bar']}"
        b = "end" if "edge" in end else f"mm. {end['bar']}"
        return f"{a} – {b}"
    return clean_spaces(re.sub(r"\s+-\s+", " – ", rest))


# --------------------------------------------------------------------------
# Loading the source data
# --------------------------------------------------------------------------

class Source:
    def __init__(self, root: pathlib.Path, commit: str):
        self.root = root
        self.commit = commit
        self.warnings: list[str] = []
        self.compositions: dict[str, list[dict]] = {}   # source file stem -> ordered compositions
        self.youtube: dict = {}
        self.youtube_url = ""
        self.jobs: dict[str, list[dict]] = {}
        self.jobs_url: dict[str, str] = {}
        self.as_of = DEFAULT_AS_OF
        self.license_text = (root / "LICENSE").read_text(encoding="utf-8")

    def file_url(self, rel: str) -> str:
        return f"{REPO_WEB}/blob/{self.commit}/{rel}"

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)

    def load(self) -> None:
        for stem in SOURCE_FILES:
            rel = f"src/Model/Excerpts/{stem}Excerpts.ts"
            top = parse_top_level((self.root / rel).read_text(encoding="utf-8"))
            exported = top.get("excerpts")
            if not isinstance(exported, list):
                raise SystemExit(f"{rel}: no `export const excerpts = [...]` found")
            exported_names = {str(r) for r in exported}
            comps: list[dict] = []
            seen_keys: set[str] = set()
            # Every composition object literal, in definition order (the `excerpts`
            # export is in the same order; one composition is only reachable through
            # the `composers` export, so membership is not taken from `excerpts`).
            for name, val in top.items():
                if not (isinstance(val, dict) and isinstance(val.get("excerpts"), list) and "videos" in val):
                    continue
                comp = dict(val)
                comp["_var"] = name
                comp["_file"] = rel
                key = comp.get("videos")
                if not isinstance(key, str) or not key:
                    raise SystemExit(f"{rel}: composition {name} has no `videos` key")
                if key in seen_keys:
                    raise SystemExit(f"{rel}: duplicate videos key {key}")
                seen_keys.add(key)
                if name not in exported_names:
                    self.warn(f"{rel}: composition {name} ({key}) is not in `export const excerpts`; imported anyway")
                comps.append(comp)
            missing = sorted(exported_names - {c["_var"] for c in comps})
            if missing:
                self.warn(f"{rel}: exported names without an object literal (skipped): {missing}")
            self.compositions[stem] = comps

        yt_rel = "src/Model/YouTubeModel/YouTubeModel.ts"
        yt_top = parse_top_level((self.root / yt_rel).read_text(encoding="utf-8"))
        yt = yt_top.get("YouTubeModel")
        if not isinstance(yt, dict):
            raise SystemExit(f"{yt_rel}: `const YouTubeModel = {{...}}` not found")
        self.youtube = yt
        self.youtube_url = self.file_url(yt_rel)

        for stem in SOURCE_FILES:
            rel = f"src/Model/Jobs/{stem}Jobs.json"
            data = json.loads((self.root / rel).read_text(encoding="utf-8"))
            jobs = data.get("Jobs")
            if not isinstance(jobs, list):
                raise SystemExit(f"{rel}: no Jobs array")
            self.jobs[stem] = jobs
            self.jobs_url[stem] = self.file_url(rel)


# --------------------------------------------------------------------------
# Building catalogue entries
# --------------------------------------------------------------------------

def license_note(license_text: str) -> str:
    body = license_text.strip()
    if body.startswith("MIT License"):
        body = body[len("MIT License"):].strip()
    paragraphs = [clean_spaces(p) for p in re.split(r"\n\s*\n", body) if p.strip()]
    return (
        "Excerpt metadata imported from BrassXcerpts by Alexander Burdiss "
        f"({REPO_WEB}), MIT License: " + "\n\n".join(paragraphs)
    )


def build_recordings(src: Source, key: str, instrument: str, stats: collections.Counter) -> list[dict]:
    model = src.youtube.get(key)
    if not isinstance(model, dict):
        stats["compositions_without_youtube_entry"] += 1
        src.warn(f"YouTubeModel has no entry for {key} ({instrument}); no recordings imported")
        return []
    out: list[dict] = []
    seen: set[str] = set()

    def add(performer, yt_id, kind: str, title_prefix: str = "") -> None:
        if not isinstance(yt_id, str) or not YOUTUBE_ID_RE.match(yt_id):
            stats["youtube_ids_skipped_invalid"] += 1
            src.warn(f"YouTubeModel[{key}]: invalid YouTube id {yt_id!r} ({performer!r}) skipped")
            return
        if yt_id in seen:
            stats["youtube_ids_deduped"] += 1
            return
        seen.add(yt_id)
        performer = clean_spaces(str(performer))
        out.append({
            "id": f"yt-{yt_id}",
            "kind": kind,
            "provider": "youtube",
            "title": f"{title_prefix}{performer}",
            "performer": performer,
            "youtubeId": yt_id,
            "start": {"status": "unverified"},
            "end": {"status": "unverified"},
            "foundVia": src.youtube_url,
        })

    has_full = False
    for group in FULL_GROUPS:
        for entry in model.get(group) or []:
            if not (isinstance(entry, list) and len(entry) == 2):
                src.warn(f"YouTubeModel[{key}].{group}: malformed entry {entry!r} skipped")
                continue
            has_full = True
            if group == "band":
                stats["band_recordings_as_orchestra"] += 1
            add(entry[0], entry[1], "orchestra")
    solo_group = SOLO_GROUP[instrument]
    for entry in model.get(solo_group) or []:
        if not (isinstance(entry, list) and len(entry) == 2):
            src.warn(f"YouTubeModel[{key}].{solo_group}: malformed entry {entry!r} skipped")
            continue
        add(entry[0], entry[1], "solo")
    if not has_full:
        for entry in model.get("score") or []:
            if not (isinstance(entry, list) and len(entry) == 2):
                continue
            stats["score_videos_used_as_fallback"] += 1
            add(entry[0], entry[1], "orchestra", "Score video — ")
    return out


def match_free_text(entry: str, comps: list[dict]) -> str | None:
    """Return the videos key of the composition a free-text job entry names, or None.

    Only exact / near-exact matches (same composer surname and the same work
    title after accent/punctuation/case normalisation) are accepted.
    """
    m = re.match(r"^\s*(.+?)\s*(?:-|–|:)\s+(.+?)\s*$", entry)
    if not m:
        return None
    composer_q, work_q = norm_text(m.group(1)), norm_text(m.group(2))
    if not composer_q or not work_q:
        return None
    hits = []
    for comp in comps:
        last = norm_text(comp.get("composerLast", ""))
        full = norm_text(comp.get("composer", ""))
        if composer_q != last and composer_q not in full.split():
            continue
        if work_q == norm_text(comp.get("name", "")):
            hits.append(comp["videos"])
    return hits[0] if len(hits) == 1 else None


def build_frequency(src: Source, stem: str, comps: list[dict]) -> tuple[dict[str, list[dict]], dict[str, str], dict]:
    """Return (evidence by key, tier by key, stats) from this instrument's job lists."""
    keys = {c["videos"] for c in comps}
    evidence: dict[str, list[dict]] = collections.defaultdict(list)
    jobs_with_key: collections.Counter = collections.Counter()
    stats: dict = {"jobs": len(src.jobs[stem]), "jobs_with_list": 0, "free_text_matched": collections.Counter(),
                   "free_text_unmatched": collections.Counter(), "unknown_keys": collections.Counter(),
                   "unknown_countries": collections.Counter()}
    for job in src.jobs[stem]:
        entries = job.get("excerpts") or []
        if not entries:
            continue
        stats["jobs_with_list"] += 1
        matched: list[str] = []
        for e in entries:
            if not isinstance(e, str):
                continue
            e = e.strip()
            k = KEY_ALIASES.get(e, e)
            if k in keys:
                if k not in matched:
                    matched.append(k)
            elif re.fullmatch(r"[A-Za-z0-9]+", e):
                stats["unknown_keys"][e] += 1
            else:
                k2 = match_free_text(e, comps)
                if k2:
                    stats["free_text_matched"][f"{e} -> {k2}"] += 1
                    if k2 not in matched:
                        matched.append(k2)
                else:
                    stats["free_text_unmatched"][e] += 1
        if not matched:
            continue
        country = clean_spaces(str(job.get("country", "")))
        region = REGION_BY_COUNTRY.get(country)
        if region is None:
            region = "other"
            if country:
                stats["unknown_countries"][country] += 1
        date_text, year = parse_job_date(job.get("auditionDate") or "")
        if not date_text:
            date_text, year = parse_job_date(job.get("closingDate") or "")
        link = clean_spaces(str(job.get("link", "")))
        source = link if re.match(r"^https?://", link) else src.jobs_url[stem]
        orchestra = clean_spaces(str(job.get("orchestra", "")))
        position = clean_spaces(str(job.get("position", "")))
        desc = f"Work listed for {orchestra} {position} audition ({date_text or 'date not listed'})"
        for k in matched:
            jobs_with_key[k] += 1
            ev = {"description": desc, "orchestra": orchestra}
            if year:
                ev["year"] = year
            ev["region"] = region
            ev["source"] = source
            ev["asOf"] = src.as_of
            evidence[k].append(ev)
    tiers: dict[str, str] = {}
    denom = stats["jobs_with_list"]
    for k in keys:
        share = jobs_with_key[k] / denom if denom else 0
        tiers[k] = "core" if share >= 0.5 else "common" if share >= 0.2 else "occasional" if share > 0 else "unknown"
    stats["jobs_with_key"] = jobs_with_key
    return evidence, tiers, stats


def build_excerpts(src: Source, stem: str, instrument: str, stats: collections.Counter,
                   evidence: dict, tiers: dict) -> list[dict]:
    comps = src.compositions[stem]
    excerpts_url = src.file_url(f"src/Model/Excerpts/{stem}Excerpts.ts")
    out: list[dict] = []
    for comp in comps:
        key = comp["videos"]
        composer = COMPOSER_SPELLING.get(comp["composer"], comp["composer"])
        work = clean_spaces(comp["name"])
        recordings = build_recordings(src, key, instrument, stats)
        for n, ex in enumerate(comp.get("excerpts") or [], start=1):
            measures = ex.get("measures")
            if not isinstance(measures, str):
                src.warn(f"{stem}/{key} excerpt {n}: measures is not a string; skipped")
                stats["excerpts_skipped"] += 1
                continue
            description = clean_spaces(str(ex.get("description", "")))
            labels: list[str] = []
            for pic in ex.get("pictures") or []:
                if isinstance(pic, list) and pic and isinstance(pic[0], str):
                    label = clean_spaces(pic[0])
                    if label and label not in labels:
                        labels.append(label)
            if instrument == "bass-trombone":
                labels = [l for l in labels if "trombone 3" in l.lower() or "bass trombone" in l.lower()]
                if not labels:
                    continue
            movement, rest = split_movement(measures)
            start, end = parse_simple_range(rest)
            if re.match(r"^Excerpt\s*\d+", description) or not description:
                title = display_title(rest, start, end) if rest else description
            else:
                title = description  # e.g. "Sarabande", "Overture"
                stats["title_from_description"] += 1
            if not title:
                title = description or f"Excerpt {n}"
            if start is not None:
                stats["simple_ranges_parsed"] += 1
            if movement and "number" in movement:
                stats["movement_numbers_parsed"] += 1
            elif movement:
                stats["movement_titles_parsed"] += 1

            location_value: dict = {"text": measures.strip()}
            if start is not None and end is not None:
                location_value["start"] = start
                location_value["end"] = end

            entry: dict = {
                "id": f"{instrument}-{key_slug(key)}-{n}",
                "instrument": instrument,
            }
            if labels:
                entry["part"] = ", ".join(labels)
            entry["positions"] = ["any"]
            entry["composer"] = composer
            entry["work"] = work
            if movement:
                entry["movement"] = movement
            entry["title"] = title
            entry["location"] = {
                "status": "verified",
                "value": location_value,
                "source": excerpts_url,
                "asOf": src.as_of,
                "note": "As listed in BrassXcerpts; not yet re-checked against the part",
            }
            if instrument in ("trombone", "bass-trombone", "tuba"):
                if labels and all(re.match(r"^(Trombones?(\s|$)|Tuba(\s|$)|Ophicle|Cimbasso)", l) for l in labels):
                    entry["soundingTransposition"] = 0
                else:
                    stats["transposition_omitted_non_trombone_tuba_part"] += 1
            entry["frequency"] = {
                "tier": tiers.get(key, "unknown"),
                "tierStatus": "unverified",
                "evidence": evidence.get(key, []),
            }
            if recordings:
                entry["recordings"] = recordings
            sources = [excerpts_url]
            if recordings:
                sources.append(src.youtube_url)
            if evidence.get(key):
                sources.append(src.jobs_url[stem])
            entry["sources"] = sources
            entry["lastVerified"] = None
            entry["listingStatus"] = "in_review"
            entry["provenanceType"] = "imported"
            entry["importedFrom"] = f"BrassXcerpts (MIT) @ {src.commit[:7]}"
            out.append(entry)
    return out


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("clone", type=pathlib.Path, help="path to a checkout of aburdiss/BrassExcerpts")
    ap.add_argument("--commit", default=DEFAULT_COMMIT, help="commit the checkout is at (for source URLs)")
    ap.add_argument("--as-of", default=DEFAULT_AS_OF, help="asOf date recorded on every imported fact")
    ap.add_argument("--generated-at", default=None, help="generatedAt for the files (default: --as-of)")
    ap.add_argument("--out", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent.parent / "catalog")
    ap.add_argument("--report", action="store_true", help="print import statistics and warnings")
    args = ap.parse_args(argv)

    src = Source(args.clone.resolve(), args.commit)
    src.as_of = args.as_of
    src.load()
    note = license_note(src.license_text)
    report: dict = {}

    for stem, instruments in SOURCE_FILES.items():
        evidence, tiers, fstats = build_frequency(src, stem, src.compositions[stem])
        for instrument in instruments:
            stats: collections.Counter = collections.Counter()
            excerpts = build_excerpts(src, stem, instrument, stats, evidence, tiers)
            data = {
                "version": "0.1.0",
                "generatedAt": args.generated_at or args.as_of,
                "instrument": instrument,
                "licenseNotes": [note],
                "excerpts": excerpts,
            }
            args.out.mkdir(parents=True, exist_ok=True)
            path = args.out / f"{instrument}.json"
            path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            stats["excerpts"] = len(excerpts)
            stats["compositions"] = len({e["work"] + e["composer"] for e in excerpts})
            stats["with_recordings"] = sum(1 for e in excerpts if e.get("recordings"))
            stats["with_evidence"] = sum(1 for e in excerpts if e["frequency"]["evidence"])
            stats["tiers"] = dict(collections.Counter(e["frequency"]["tier"] for e in excerpts))
            report[instrument] = {"file": str(path), **stats, "jobs": {
                "jobs": fstats["jobs"], "jobs_with_list": fstats["jobs_with_list"],
                "free_text_matched": dict(fstats["free_text_matched"]),
                "unknown_keys": dict(fstats["unknown_keys"]),
                "unknown_countries": dict(fstats["unknown_countries"]),
                "works_by_job_count": dict(fstats["jobs_with_key"].most_common()),
            }}
            if args.report:
                print(f"{instrument}: {len(excerpts)} excerpts -> {path}")

    if args.report:
        print(json.dumps(report, indent=2, ensure_ascii=False))
        print("\nWARNINGS:")
        for w in src.warnings:
            print(" -", w)
    return 0


if __name__ == "__main__":
    sys.exit(main())
