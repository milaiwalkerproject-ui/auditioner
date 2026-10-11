from __future__ import annotations

from crawler.mapping import Catalogue, map_item
from crawler.schema import coerce_item
from crawler.verify import Verification


def ok() -> Verification:
    return Verification()


def failed() -> Verification:
    verification = Verification()
    verification.flag("composer_not_in_cited_lines")
    return verification


def item(**fields):
    base = {"sourceLineIds": ["L0001"], "category": "excerpt", "composer": "Beethoven", "work": "Symphony No. 5",
            "catalogueNumber": "Op. 67", "movement": "II", "location": {"type": "measures", "startBar": 1, "endBar": 106}}
    base.update(fields)
    return coerce_item(base)


def test_fixture_catalogue_loads_ranges_from_locations_and_variants(catalogue: Catalogue):
    assert len(catalogue) == 4
    sym5 = {e.id: e for e in catalogue.for_instrument("cello")}["cello-fixture-sym-5-mvt2"]
    assert sym5.ranges == ((1, 106), (1, 10), (49, 59), (98, 106))
    dvorak = {e.id: e for e in catalogue.for_instrument("cello")}["cello-fixture-dvorak-sym-8-mvt1"]
    assert dvorak.ranges == ((1, 18),)  # unverified location contributes nothing; the variant does
    assert Catalogue.load("/nonexistent/dir").instruments == []


def test_exact_match_maps_automatically(catalogue: Catalogue):
    mapping = map_item(item(), ok(), catalogue, "cello")
    assert mapping.bucket == "auto" and mapping.excerpt_id == "cello-fixture-sym-5-mvt2"
    assert mapping.confidence >= 0.9
    assert mapping.to_dict()["candidates"][0]["excerptId"] == "cello-fixture-sym-5-mvt2"


def test_variant_bars_and_spelling_variants_still_map(catalogue: Catalogue):
    mapping = map_item(item(composer="L. v. Beethoven", work="Sym. No. 5", movement="2nd mvt", catalogueNumber="",
                            location={"type": "measures", "startBar": 49, "endBar": 59}), ok(), catalogue, "cello")
    assert mapping.bucket == "auto" and mapping.excerpt_id == "cello-fixture-sym-5-mvt2"


def test_partial_overlap_goes_to_review_with_a_suggestion(catalogue: Catalogue):
    mapping = map_item(item(location={"type": "measures", "startBar": 60, "endBar": 160}), ok(), catalogue, "cello")
    assert mapping.bucket == "review" and mapping.excerpt_id == "cello-fixture-sym-5-mvt2"
    assert 0.6 <= mapping.confidence < 0.9


def test_wrong_movement_or_number_does_not_map(catalogue: Catalogue):
    movement = map_item(item(movement="IV"), ok(), catalogue, "cello")
    assert movement.bucket != "auto"
    number = map_item(item(work="Symphony No. 7", catalogueNumber=""), ok(), catalogue, "cello")
    assert number.bucket == "new_candidate" and number.excerpt_id is None


def test_unknown_work_is_a_new_excerpt_candidate(catalogue: Catalogue):
    mapping = map_item(item(composer="Brahms", work="Symphony No. 2", catalogueNumber="", movement="", location={"type": "unknown"}), ok(), catalogue, "cello")
    assert mapping.bucket == "new_candidate" and mapping.excerpt_id is None
    assert "no catalogue excerpt" in mapping.reasons[0]


def test_unverified_items_never_map_automatically(catalogue: Catalogue):
    mapping = map_item(item(), failed(), catalogue, "cello")
    assert mapping.bucket == "review" and mapping.confidence <= 0.85


def test_catalogue_number_conflict_caps_confidence(catalogue: Catalogue):
    mapping = map_item(item(catalogueNumber="Op. 68"), ok(), catalogue, "cello")
    assert mapping.confidence <= 0.5 and mapping.bucket == "new_candidate"


def test_works_only_lists_go_to_review(catalogue: Catalogue):
    mapping = map_item(item(location={"type": "unknown"}), ok(), catalogue, "cello")
    assert mapping.bucket == "review"


def test_diacritic_insensitive_composer_match(catalogue: Catalogue):
    mapping = map_item(item(composer="Dvorak", work="Symphony No. 8", catalogueNumber="Op. 88", movement="I",
                            location={"type": "measures", "startBar": 1, "endBar": 18}), ok(), catalogue, "cello")
    assert mapping.bucket == "auto" and mapping.excerpt_id == "cello-fixture-dvorak-sym-8-mvt1"


def test_other_instrument_or_non_excerpt_items_are_not_mapped(catalogue: Catalogue):
    assert map_item(item(), ok(), catalogue, "harp").bucket == "new_candidate"
    assert map_item(item(category="sight_reading"), ok(), catalogue, "cello").bucket == "new_candidate"
