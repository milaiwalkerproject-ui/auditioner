from __future__ import annotations

from crawler.pages import (
    content_hash,
    discover_links,
    main_text,
    parse_job_postings,
    strip_dates,
)

PAGE_URL = "https://www.example-phil.org/auditions"

HTML = """
<html><head><title>Auditions</title><script>var x = 1;</script>
<script type="application/ld+json">
{"@context":"https://schema.org","@type":"JobPosting","title":"Section Cello","datePosted":"2026-09-01",
 "validThrough":"2026-11-15","hiringOrganization":{"@type":"Organization","name":"Example Philharmonic"},
 "description":"<p>Preliminary round 2026-12-01.</p>"}
</script></head>
<body>
<nav><a href="/">Home</a><a href="/concerts">Concerts</a></nav>
<div class="cookie-banner">We use cookies</div>
<main>
  <h1>Auditions</h1>
  <p>Section Cello — application deadline 15 November 2026.</p>
  <ul>
    <li><a href="/files/section-cello-repertoire.pdf">Repertoire list (PDF)</a></li>
    <li><a href="https://assets.muvac.com/x/excerpts.pdf">Excerpts</a></li>
    <li><a href="/files/annual-report.pdf">Annual report</a></li>
    <li><a href="https://www.musicalchairs.info/cello/123">Also on Musical Chairs</a></li>
    <li><a href="/auditions/principal-horn">Principal Horn audition</a></li>
    <li><a href="https://other.example/jobs">Jobs elsewhere</a></li>
    <li><a href="mailto:personnel@example-phil.org">Email us</a></li>
    <li><a href="/about">About</a></li>
  </ul>
  <p>Last updated 10 October 2026 at 14:05.</p>
</main>
<footer>© Example Philharmonic</footer>
</body></html>
"""


def test_main_text_drops_chrome_scripts_and_cookie_banner():
    text = main_text(HTML)
    assert "Auditions" in text and "Section Cello" in text
    assert "var x" not in text
    assert "cookies" not in text
    assert "Concerts" not in text
    assert "©" not in text


def test_content_hash_ignores_dates_and_whitespace():
    a = content_hash("Section Cello\nLast updated 10 October 2026 at 14:05.")
    b = content_hash("Section   Cello\nLast updated 11 October 2026 at 09:30.")
    c = content_hash("Section Viola\nLast updated 10 October 2026 at 14:05.")
    assert a == b
    assert a != c
    assert "2026" not in strip_dates("deadline 2026-11-15, 15.11.2026, Nov 15, 2026")


def test_discover_links_keeps_documents_and_audition_pages_only():
    links = discover_links(HTML, PAGE_URL)
    urls = [link.url for link in links]
    assert "https://www.example-phil.org/files/section-cello-repertoire.pdf" in urls
    assert "https://assets.muvac.com/x/excerpts.pdf" in urls  # policy decides later whether it may be fetched
    assert "https://www.example-phil.org/files/annual-report.pdf" not in urls  # no audition keyword
    assert "https://www.example-phil.org/auditions/principal-horn" in urls
    assert not any("musicalchairs" in u for u in urls)  # not a document and not our host
    assert not any("other.example" in u for u in urls)
    assert not any(u.startswith("mailto") for u in urls)
    assert "https://www.example-phil.org/about" not in urls
    by_url = {link.url: link for link in links}
    assert by_url["https://www.example-phil.org/files/section-cello-repertoire.pdf"].strong
    assert by_url["https://www.example-phil.org/files/section-cello-repertoire.pdf"].kind == "document"
    assert by_url["https://www.example-phil.org/auditions/principal-horn"].kind == "page"
    assert links[0].kind == "document"  # strong documents first


def test_job_posting_json_ld_is_parsed_into_citable_lines():
    postings = parse_job_postings(HTML)
    assert len(postings) == 1
    posting = postings[0]
    assert posting.title == "Section Cello"
    assert posting.valid_through == "2026-11-15"
    assert posting.organisation == "Example Philharmonic"
    lines = posting.to_lines()
    assert "JobPosting validThrough: 2026-11-15" in lines
    assert any(line.startswith("JobPosting description: Preliminary round") for line in lines)


def test_job_posting_inside_graph_and_broken_json_are_tolerated():
    html = """<script type="application/ld+json">{"@graph":[{"@type":"WebPage"},{"@type":["JobPosting"],"title":"Tutti Viola","validThrough":"2026-12-31",}]}</script>
    <script type="application/ld+json">not json at all</script>"""
    postings = parse_job_postings(html)
    assert [p.title for p in postings] == ["Tutti Viola"]
