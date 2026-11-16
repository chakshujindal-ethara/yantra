"""Listings as the worker browses them (open, slots left first, prequalified, the evergreen redirect) and as
ops shape them (create, patch validated as a whole)."""

import uuid
from datetime import UTC, datetime, timedelta
from decimal import Decimal

import pytest

from yantra_common.errors import Invalid, NotFound
from yantra_talent.schemas import ListingIn, ListingPatch, QuestionIn
from yantra_talent.service import (
    all_listings,
    application_counts,
    apply,
    create_listing,
    evergreen,
    open_listings,
    patch_listing,
    viewers_of,
    worker_listing,
)
from yantra_talent.testing import QUESTIONS, grant_gate, make_listing

NOW = datetime.now(UTC)


def listing_in(**overrides):
    fields = dict(
        title="t",
        domain="d",
        summary="s",
        pay_min="10",
        pay_max="20",
        currency="INR",
        commitment="task_based",
        slots_total=2,
    )
    return ListingIn.model_validate({**fields, **overrides})


def test_open_listings_hide_drafts_closed_and_lapsed_and_sort_slots_left_first(session):
    older, newer = NOW - timedelta(days=2), NOW - timedelta(days=1)
    full = make_listing(session, title="full", slots_total=1, slots_filled=1, posted_at=NOW)
    old = make_listing(session, title="old", posted_at=older)
    new = make_listing(session, title="new", posted_at=newer)
    unposted = make_listing(session, title="unposted", posted_at=None)
    make_listing(session, title="draft", status="draft")
    make_listing(session, title="closed", status="closed")
    make_listing(session, title="lapsed", closes_at=NOW - timedelta(minutes=1))
    make_listing(session, title="later", closes_at=NOW + timedelta(days=1), domain="other", commitment="part_time")
    rows = open_listings(session, NOW)
    assert [r.title for r in rows] == ["later", "new", "old", "unposted", "full"]
    assert [r.id for r in open_listings(session, NOW, domain="transcription")] == [new.id, old.id, unposted.id, full.id]
    assert [r.title for r in open_listings(session, NOW, commitment="part_time")] == ["later"]
    assert len(all_listings(session)) == 8


def test_viewer_carries_prequalified_and_the_latest_application(session, worker):
    gated = make_listing(session, cert_gate="transcription")
    ungated = make_listing(session, cert_gate=None)
    grant_gate(session, worker, "transcription")
    app = apply(session, gated.id, worker, {"experience": "3"}, NOW)
    session.commit()
    views = viewers_of(session, [gated, ungated], worker)
    assert views[gated.id].model_dump() == {
        "prequalified": True,
        "application_id": app.id,
        "application_status": "screening",
        "redirect": None,
    }
    assert views[ungated.id].model_dump() == {
        "prequalified": False,
        "application_id": None,
        "application_status": None,
        "redirect": None,
    }
    assert viewers_of(session, [gated], uuid.uuid4())[gated.id].prequalified is False


def test_a_closed_listing_is_shown_closed_with_the_evergreen_redirect(session, worker):
    closed = make_listing(session, title="closed", status="closed")
    lapsed = make_listing(session, title="lapsed", closes_at=NOW - timedelta(minutes=1))
    assert evergreen(session, closed, NOW) is None
    view = worker_listing(session, closed.id, worker, NOW)
    assert view.status == "closed" and view.viewer.redirect is None
    other = make_listing(session, title="evergreen")
    make_listing(session, title="elsewhere", domain="other")
    view = worker_listing(session, lapsed.id, worker, NOW)
    assert view.status == "closed" and view.viewer.redirect.model_dump() == {
        "listing_id": other.id,
        "title": "evergreen",
    }
    assert worker_listing(session, other.id, worker, NOW).viewer.redirect is None
    assert evergreen(session, other, NOW) is None  # never itself


def test_a_draft_is_invisible_to_workers_but_not_to_ops(session, worker):
    draft = make_listing(session, status="draft")
    with pytest.raises(NotFound):
        worker_listing(session, draft.id, worker, NOW)
    assert worker_listing(session, draft.id, worker, NOW, ops=True).status == "draft"
    with pytest.raises(NotFound):
        worker_listing(session, uuid.uuid4(), worker, NOW)


def test_listing_in_validates_pay_questions_and_paper():
    with pytest.raises(ValueError, match="pay_min"):
        listing_in(pay_min="30")
    with pytest.raises(ValueError, match="unique"):
        listing_in(questions=[{"key": "a", "prompt": "p"}, {"key": "a", "prompt": "q"}])
    with pytest.raises(ValueError, match="cert_gate"):
        listing_in(paper_id=str(uuid.uuid4()))
    with pytest.raises(ValueError, match="two options"):
        QuestionIn(key="a", prompt="p", kind="choice", options=["x"])
    with pytest.raises(ValueError, match="no options"):
        QuestionIn(key="a", prompt="p", kind="text", options=["x"])
    with pytest.raises(ValueError):
        listing_in(currency="inr")
    with pytest.raises(ValueError):
        listing_in(slots_total=0)
    with pytest.raises(ValueError):
        listing_in(commitment="full_time")
    assert listing_in(paper_id=str(uuid.uuid4()), cert_gate="g").cert_gate == "g"


def test_create_and_patch_keep_the_listing_consistent(session):
    draft = create_listing(session, listing_in(), NOW)
    session.commit()
    assert (draft.status, draft.posted_at, draft.slots_filled, draft.pay_unit) == ("draft", None, 0, "per_unit")
    opened = patch_listing(session, draft.id, ListingPatch(status="open", pay_max=Decimal("25")), NOW)
    session.commit()
    assert opened.status == "open" and opened.posted_at == NOW and opened.pay_max == Decimal("25")
    later = NOW + timedelta(hours=1)
    assert patch_listing(session, draft.id, ListingPatch(title="renamed"), later).posted_at == NOW  # posted once
    with pytest.raises(Invalid) as e:
        patch_listing(session, draft.id, ListingPatch(pay_min=Decimal("40")), NOW)
    assert "pay_min" in e.value.message and e.value.context["fields"]
    with pytest.raises(NotFound):
        patch_listing(session, uuid.uuid4(), ListingPatch(title="x"), NOW)
    posted = create_listing(session, listing_in(status="open"), NOW)
    posted.slots_filled = 2
    session.flush()
    with pytest.raises(Invalid, match="slots_total"):
        patch_listing(session, posted.id, ListingPatch(slots_total=1), NOW)
    assert posted.posted_at == NOW


def test_application_counts_cover_every_status_for_every_listing(session, worker):
    a = make_listing(session)
    b = make_listing(session)
    apply(session, a.id, worker, {"experience": "3"}, NOW)
    apply(session, a.id, uuid.uuid4(), {"experience": "3"}, NOW)
    session.commit()
    counts = application_counts(session, [a.id, b.id])
    assert (
        counts[a.id]["screening"] == 2
        and counts[a.id]["offered"] == 0
        and set(counts[a.id])
        == {"applied", "assessment", "screening", "offered", "accepted", "declined", "rejected", "withdrawn", "expired"}
    )
    assert sum(counts[b.id].values()) == 0
    assert QUESTIONS[0]["required"] is True
