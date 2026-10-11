from __future__ import annotations

import pytest

from crawler.policy import HostPolicy, is_document_url

PAGE = "https://www.example-phil.org/auditions"


@pytest.fixture
def policy() -> HostPolicy:
    return HostPolicy(["www.example-phil.org", "jugend.example.de"])


def test_registry_hosts_and_subdomains_are_allowed(policy: HostPolicy):
    assert policy.check("https://www.example-phil.org/auditions").allowed
    assert policy.check("https://example-phil.org/x").allowed  # www. stripped
    assert policy.check("https://cdn.example-phil.org/list.pdf", kind="document").allowed
    assert policy.check("http://jugend.example.de/probespiel").allowed


@pytest.mark.parametrize(
    "url",
    [
        "https://www.musicalchairs.info/cello/jobs",
        "https://muvac.com/en/vacancies",
        "https://www.muvac.com/vacancy/123",
        "https://auditioncafe.com/x",
        "https://www.facebook.com/examplephil",
        "https://internationalmusician.org/auditions",
        "https://americanorchestras.org/jobs",
        "https://imslp.org/wiki/x",
    ],
)
def test_aggregators_and_social_networks_are_refused_even_when_linked(policy: HostPolicy, url: str):
    for kind in ("page", "document"):
        decision = policy.check(url, linked_from=PAGE, kind=kind)
        assert not decision.allowed, url
        assert "never reads" in decision.reason


def test_muvac_assets_only_as_a_document_linked_from_the_orchestra(policy: HostPolicy):
    url = "https://assets.muvac.com/files/repertoire.pdf"
    assert policy.check(url, linked_from=PAGE, kind="document").allowed
    assert not policy.check(url, kind="document").allowed  # no link from an orchestra page
    assert not policy.check(url, linked_from=PAGE, kind="page").allowed
    assert not policy.check(url, linked_from="https://www.musicalchairs.info/x", kind="document").allowed
    assert not policy.check("https://muvac.com/vacancy/1", linked_from=PAGE, kind="document").allowed


def test_foreign_documents_need_a_link_from_the_orchestra(policy: HostPolicy):
    pdf = "https://files.cdn-example.net/lists/cello.pdf"
    assert policy.check(pdf, linked_from=PAGE, kind="document").allowed
    assert not policy.check(pdf, kind="document").allowed
    assert not policy.check("https://files.cdn-example.net/page.html", linked_from=PAGE, kind="page").allowed


@pytest.mark.parametrize("url", ["ftp://www.example-phil.org/x", "file:///etc/passwd", "javascript:alert(1)", "https://user:pw@www.example-phil.org/x", "not a url"])
def test_odd_schemes_and_credentials_are_refused(policy: HostPolicy, url: str):
    assert not policy.check(url).allowed


def test_is_document_url():
    assert is_document_url("https://x.example/a/list.PDF?x=1")
    assert is_document_url("https://x.example/a/list.docx")
    assert not is_document_url("https://x.example/a/list.pdf.html")


def test_job_boards_are_refused_even_for_documents_linked_from_an_orchestra_page():
    from crawler.policy import HostPolicy

    policy = HostPolicy(["example-phil.org"])
    page = "https://www.example-phil.org/auditions"
    for url in (
        "https://theviolinchannel.com/jobs/list.pdf",
        "https://www.indeed.com/viewjob?jk=1",
        "https://cellobello.org/auditions/list.pdf",
        "https://symphony.org/jobs/x.pdf",
        "https://www.musicalchairs.info/jobs/list.pdf",
    ):
        assert not policy.check(url, linked_from=page, kind="document").allowed, url
    # The one written exception still holds.
    assert policy.check("https://assets.muvac.com/x/list.pdf", linked_from=page, kind="document").allowed
