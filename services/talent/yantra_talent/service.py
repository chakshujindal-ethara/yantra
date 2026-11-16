"""The talent operations. Each function works inside the caller's session and leaves the commit to the HTTP
layer (one exception, documented on `answer_offer`). Pure rules (answers, the initial state, hashing) sit at the
top; the database shell below them."""

import logging
import re
import uuid
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from typing import Any, Literal

from pydantic import ValidationError
from sqlalchemy import and_, delete, func, or_, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.orm import Session

from yantra_common.errors import Conflict, Invalid, NotFound
from yantra_common.outbox import emit
from yantra_common.people import Kind, names_of
from yantra_common.pii import PAN, normalise_name, pii_hash
from yantra_common.storage import Storage, document_key
from yantra_contracts.events.v1 import (
    TalentApplicationDecided,
    TalentApplicationMoved,
    TalentOfferAccepted,
    TalentPersonSeen,
    WorkerConsentGiven,
    WorkerConsentWithdrawn,
    WorkerEligible,
    WorkerErasureCompleted,
    WorkerErasureRequested,
)
from yantra_talent.models import (
    APPLICATION_STATUSES,
    LIVE_STATUSES,
    ONBOARDING_STEPS,
    OUTBOX,
    PERSON,
    Application,
    Erasure,
    Listing,
    Onboarding,
    Policy,
    WorkerDocument,
    WorkerGate,
)
from yantra_talent.policies_seed import CONTRACTOR_AGREEMENT, DPDP_CONSENT
from yantra_talent.schemas import (
    AgreementIn,
    ApplicationOut,
    ConsentIn,
    DocumentBriefOut,
    DocumentIn,
    DocumentPresignIn,
    ErasureOut,
    IdentityIn,
    ListingIn,
    ListingOut,
    ListingPatch,
    OnboardingOut,
    OnboardingRowOut,
    OnboardingStepOut,
    PersonOut,
    PolicyIn,
    PolicyOut,
    PresignedOut,
    ProfileIn,
    RedirectOut,
    ViewerOut,
    WorkerListingOut,
)

log = logging.getLogger("yantra.talent")
GROUPS: dict[str, str] = {
    "profile": "Profile",
    "agreement": "Documents",
    "consent": "Documents",
    "identity": "Identity",
    "bank": "Payment",
    "payout_ack": "Payment",
}
WITHDRAWABLE = ("assessment", "screening", "offered")
ERASURE_GRACE = timedelta(days=30)
HIRED_WINDOW = timedelta(days=7)
SEEN_CACHE_MAX = 10_000
Step = dict[str, str]
# people this process has confirmed are recorded with this name and kind: a repeat request skips the statement.
# Only confirmed no-ops are cached, never a write that might yet roll back.
_seen: dict[uuid.UUID, tuple[str, str]] = {}


def now_utc() -> datetime:
    return datetime.now(UTC)


# ---------- pure rules ----------


def check_answers(questions: list[dict[str, Any]], answers: dict[str, Any]) -> None:
    """The form step: every required question answered, every choice among its options, no stray keys."""
    keys = {q["key"] for q in questions}
    for key in answers:
        if key not in keys:
            raise Invalid(f"answers: unknown question {key}", key=key)
    for q in questions:
        key = str(q["key"])
        value = answers.get(key)
        missing = value is None or (isinstance(value, str) and not value.strip())
        if missing and q.get("required", True):
            raise Invalid(f"answers: {key} is required", key=key)
        if not missing and q.get("kind") == "choice" and value not in q.get("options", []):
            raise Invalid(f"answers: {key} must be one of the options", key=key)


def initial_state(steps: list[str], holds_gate: bool) -> tuple[str, list[Step]]:
    """Where a new application starts, from the listing's steps. The form is done by applying; the paper step is
    done at once when the worker already holds the gate; availability is given on the form."""
    has_paper = "paper" in steps
    out: list[Step] = []
    for kind in steps:
        status = "pending" if kind == "paper" and not holds_gate else "done"
        out.append({"kind": kind, "status": status})
    return ("assessment" if has_paper and not holds_gate else "screening"), out


def with_step(steps: list[Step], kind: str, status: str = "done") -> list[Step]:
    return [{**s, "status": status} if s["kind"] == kind else dict(s) for s in steps]


def is_open(listing: Listing, now: datetime) -> bool:
    return listing.status == "open" and (listing.closes_at is None or listing.closes_at > now)


def moved(session: Session, app: Application, from_status: str | None) -> None:
    """Announce one status change of an application (the funnel counts from these)."""
    emit(
        session,
        OUTBOX,
        str(app.id),
        TalentApplicationMoved(
            application_id=app.id,
            listing_id=app.listing_id,
            worker_id=app.worker_id,
            from_status=from_status,
            to_status=app.status,
        ),
    )


# ---------- listings ----------


def get_listing(session: Session, listing_id: uuid.UUID, lock: bool = False) -> Listing:
    stmt = select(Listing).where(Listing.id == listing_id)
    listing = session.scalar(stmt.with_for_update() if lock else stmt)
    if listing is None:
        raise NotFound("listing not found", listing_id=str(listing_id))
    return listing


def open_listings(
    session: Session, now: datetime, domain: str | None = None, commitment: str | None = None
) -> list[Listing]:
    """What a worker browses: open and not past `closes_at`; pools with a slot left first, newest posted next."""
    stmt = select(Listing).where(Listing.status == "open", or_(Listing.closes_at.is_(None), Listing.closes_at > now))
    if domain is not None:
        stmt = stmt.where(Listing.domain == domain)
    if commitment is not None:
        stmt = stmt.where(Listing.commitment == commitment)
    stmt = stmt.order_by(
        (Listing.slots_filled < Listing.slots_total).desc(), Listing.posted_at.desc().nulls_last(), Listing.id
    )
    return list(session.scalars(stmt))


def all_listings(session: Session) -> list[Listing]:
    return list(session.scalars(select(Listing).order_by(Listing.created_at.desc(), Listing.id)))


def hired_this_week(session: Session, listing_ids: list[uuid.UUID], now: datetime) -> dict[uuid.UUID, int]:
    """Accepted offers in the last seven days per listing (an accepted application is final, so its `updated_at`
    is when it was accepted)."""
    if not listing_ids:
        return {}
    stmt = (
        select(Application.listing_id, func.count())
        .where(
            Application.listing_id.in_(listing_ids),
            Application.status == "accepted",
            Application.updated_at >= now - HIRED_WINDOW,
        )
        .group_by(Application.listing_id)
    )
    return {listing_id: int(n) for listing_id, n in session.execute(stmt)}


def application_counts(session: Session, listing_ids: list[uuid.UUID]) -> dict[uuid.UUID, dict[str, int]]:
    counts = {lid: dict.fromkeys(APPLICATION_STATUSES, 0) for lid in listing_ids}
    stmt = (
        select(Application.listing_id, Application.status, func.count())
        .where(Application.listing_id.in_(listing_ids))
        .group_by(Application.listing_id, Application.status)
    )
    for listing_id, status, n in session.execute(stmt):
        counts[listing_id][status] = int(n)
    return counts


def viewers_of(session: Session, listings: list[Listing], worker_id: uuid.UUID) -> dict[uuid.UUID, ViewerOut]:
    """The worker's angle on each listing: prequalified when they hold its gate, plus their latest application."""
    gates = set(session.scalars(select(WorkerGate.gate).where(WorkerGate.worker_id == worker_id)))
    ids = [listing.id for listing in listings]
    latest: dict[uuid.UUID, Application] = {}
    stmt = (
        select(Application)
        .where(Application.worker_id == worker_id, Application.listing_id.in_(ids))
        .order_by(Application.created_at.desc())
    )
    for app in session.scalars(stmt):
        latest.setdefault(app.listing_id, app)
    out: dict[uuid.UUID, ViewerOut] = {}
    for listing in listings:
        mine = latest.get(listing.id)
        out[listing.id] = ViewerOut(
            prequalified=listing.cert_gate is not None and listing.cert_gate in gates,
            application_id=mine.id if mine else None,
            application_status=mine.status if mine else None,
        )
    return out


def evergreen(session: Session, listing: Listing, now: datetime) -> RedirectOut | None:
    """Where a closed listing sends the worker: an open pool of the same domain, when there is one."""
    for other in open_listings(session, now, domain=listing.domain):
        if other.id != listing.id:
            return RedirectOut(listing_id=other.id, title=other.title)
    return None


def worker_listing(
    session: Session, listing_id: uuid.UUID, worker_id: uuid.UUID, now: datetime, ops: bool = False
) -> WorkerListingOut:
    """One listing as the worker sees it. A draft is invisible to workers; a closed one is shown as closed with the
    evergreen redirect, never a dead end."""
    listing = get_listing(session, listing_id)
    if listing.status == "draft" and not ops:
        raise NotFound("listing not found", listing_id=str(listing_id))
    viewer = viewers_of(session, [listing], worker_id)[listing.id]
    fields = ListingOut.model_validate(listing).model_dump()
    fields["hired_this_week"] = hired_this_week(session, [listing.id], now).get(listing.id, 0)
    if listing.status != "draft" and not is_open(listing, now):
        fields["status"] = "closed"
        viewer.redirect = evergreen(session, listing, now)
    return WorkerListingOut(**fields, viewer=viewer)


def create_listing(session: Session, body: ListingIn, now: datetime) -> Listing:
    listing = Listing(**body.model_dump(), posted_at=now if body.status == "open" else None)
    session.add(listing)
    session.flush()
    return listing


def patch_listing(session: Session, listing_id: uuid.UUID, patch: ListingPatch, now: datetime) -> Listing:
    """The merged listing is validated as a whole, so a patch can never leave pay or questions inconsistent."""
    listing = get_listing(session, listing_id, lock=True)
    current = {name: getattr(listing, name) for name in ListingIn.model_fields}
    try:
        body = ListingIn.model_validate({**current, **patch.model_dump(exclude_unset=True)})
    except ValidationError as e:
        fields = [".".join(str(p) for p in err["loc"]) for err in e.errors()]
        raise Invalid("listing: " + "; ".join(err["msg"] for err in e.errors()), fields=fields) from None
    if body.slots_total < listing.slots_filled:
        raise Invalid("slots_total: below slots_filled", listing_id=str(listing_id), count=listing.slots_filled)
    for name, value in body.model_dump().items():
        setattr(listing, name, value)
    if listing.status == "open" and listing.posted_at is None:
        listing.posted_at = now
    session.flush()
    return listing


# ---------- gates ----------


def holds_gate(session: Session, worker_id: uuid.UUID, gate: str | None) -> bool:
    return gate is not None and session.get(WorkerGate, (worker_id, gate)) is not None


def upsert_gate(session: Session, worker_id: uuid.UUID, gate: str, source: str, at: datetime) -> None:
    stmt = (
        pg_insert(WorkerGate)
        .values(worker_id=worker_id, gate=gate, source=source, at=at)
        .on_conflict_do_update(index_elements=["worker_id", "gate"], set_={"source": source, "at": at})
    )
    session.execute(stmt)


def _waiting_on_paper(worker_id: uuid.UUID, gate: str) -> Any:
    return (
        select(Application)
        .join(Listing, Listing.id == Application.listing_id)
        .where(Application.worker_id == worker_id, Application.status == "assessment", Listing.cert_gate == gate)
        .with_for_update(of=Application)
    )


def certify_applications(
    session: Session, worker_id: uuid.UUID, gate: str, score: Decimal | None = None, at: datetime | None = None
) -> int:
    """The worker passed the paper for `gate`: every application of theirs waiting on it moves to screening."""
    count = 0
    for app in session.scalars(_waiting_on_paper(worker_id, gate)):
        app.status = "screening"
        app.steps = with_step(app.steps, "paper")
        if score is not None and at is not None:
            app.paper_result = {"status": "passed", "score": str(score), "at": at.isoformat()}
        moved(session, app, "assessment")
        count += 1
    session.flush()
    return count


def record_paper_failure(
    session: Session, worker_id: uuid.UUID, gate: str, score: Decimal, attempts_left: int, at: datetime
) -> int:
    """A failed sitting: the applications waiting on that paper keep waiting while attempts remain; with none left
    their paper step shows failed. The outcome is kept on the application for ops."""
    count = 0
    for app in session.scalars(_waiting_on_paper(worker_id, gate)):
        app.paper_result = {
            "status": "failed",
            "score": str(score),
            "at": at.isoformat(),
            "attempts_left": attempts_left,
        }
        if attempts_left <= 0:
            app.steps = with_step(app.steps, "paper", "failed")
        count += 1
    session.flush()
    return count


# ---------- applications ----------


def get_application(session: Session, application_id: uuid.UUID, lock: bool = False) -> Application:
    stmt = select(Application).where(Application.id == application_id)
    app = session.scalar(stmt.with_for_update() if lock else stmt)
    if app is None:
        raise NotFound("application not found", application_id=str(application_id))
    return app


def own_application(session: Session, application_id: uuid.UUID, worker_id: uuid.UUID, lock: bool) -> Application:
    app = get_application(session, application_id, lock=lock)
    if app.worker_id != worker_id:
        raise NotFound("application not found", application_id=str(application_id))
    return app


def application_out(app: Application, listing: Listing, worker_name: str | None = None) -> ApplicationOut:
    return ApplicationOut(
        id=app.id,
        listing_id=app.listing_id,
        listing_title=listing.title,
        worker_id=app.worker_id,
        status=app.status,  # the column's check constraint keeps it inside the Literal
        steps=app.steps,
        answers=app.answers,
        note=app.note,
        offer_expires_at=app.offer_expires_at,
        decided_by=app.decided_by,
        created_at=app.created_at,
        updated_at=app.updated_at,
        worker_name=worker_name,
        paper=app.paper_result,  # validated into PaperOut
    )


def apply(
    session: Session, listing_id: uuid.UUID, worker_id: uuid.UUID, answers: dict[str, Any], now: datetime
) -> Application:
    """The form step. The listing row is locked, so the slot check and the one-live-application check cannot
    race another apply or an accepted offer on the same listing."""
    listing = get_listing(session, listing_id, lock=True)
    if listing.status == "draft":
        raise NotFound("listing not found", listing_id=str(listing_id))
    if not is_open(listing, now):
        raise Conflict("listing is closed", listing_id=str(listing_id)).with_code("listing_closed")
    if listing.slots_filled >= listing.slots_total:
        raise Conflict("listing has no slot left", listing_id=str(listing_id)).with_code("listing_full")
    live = session.scalar(
        select(Application).where(
            Application.listing_id == listing_id,
            Application.worker_id == worker_id,
            Application.status.in_(LIVE_STATUSES),
        )
    )
    if live is not None:
        raise Conflict("already applied", application_id=str(live.id), status=live.status).with_code("already_applied")
    check_answers(listing.questions, answers)
    status, steps = initial_state(listing.steps, holds_gate(session, worker_id, listing.cert_gate))
    app = Application(listing_id=listing_id, worker_id=worker_id, status=status, steps=steps, answers=answers)
    session.add(app)
    session.flush()
    moved(session, app, None)
    return app


def expire_due_offers(
    session: Session, now: datetime, worker_id: uuid.UUID | None = None, listing_id: uuid.UUID | None = None
) -> int:
    """Expired equals declined: an offer past its expiry is marked by the minute job and on the next read that
    would show it. Each one is announced."""
    stmt = update(Application).where(Application.status == "offered", Application.offer_expires_at <= now)
    if worker_id is not None:
        stmt = stmt.where(Application.worker_id == worker_id)
    if listing_id is not None:
        stmt = stmt.where(Application.listing_id == listing_id)
    rows = session.execute(
        stmt.values(status="expired", updated_at=now).returning(
            Application.id, Application.listing_id, Application.worker_id
        )
    ).all()
    for app_id, lid, wid in rows:
        emit(
            session,
            OUTBOX,
            str(app_id),
            TalentApplicationMoved(
                application_id=app_id, listing_id=lid, worker_id=wid, from_status="offered", to_status="expired"
            ),
        )
    return len(rows)


def my_applications(session: Session, worker_id: uuid.UUID, now: datetime) -> list[ApplicationOut]:
    expire_due_offers(session, now, worker_id=worker_id)
    stmt = (
        select(Application, Listing)
        .join(Listing, Listing.id == Application.listing_id)
        .where(Application.worker_id == worker_id)
        .order_by(Application.created_at.desc(), Application.id)
        .execution_options(populate_existing=True)
    )
    return [application_out(app, listing) for app, listing in session.execute(stmt).tuples()]


def listing_applications(
    session: Session, listing_id: uuid.UUID, status: str | None, now: datetime
) -> list[ApplicationOut]:
    listing = get_listing(session, listing_id)
    expire_due_offers(session, now, listing_id=listing_id)
    stmt = (
        select(Application)
        .where(Application.listing_id == listing_id)
        .order_by(Application.created_at, Application.id)
        .execution_options(populate_existing=True)
    )
    if status is not None:
        stmt = stmt.where(Application.status == status)
    apps = list(session.scalars(stmt))
    people = names_of(session, PERSON, [a.worker_id for a in apps])
    return [
        application_out(app, listing, people[app.worker_id].name if app.worker_id in people else None) for app in apps
    ]


def withdraw(session: Session, application_id: uuid.UUID, worker_id: uuid.UUID) -> Application:
    app = own_application(session, application_id, worker_id, lock=True)
    if app.status not in WITHDRAWABLE:
        raise Conflict("application cannot be withdrawn", application_id=str(app.id), status=app.status).with_code(
            "not_withdrawable"
        )
    before, app.status = app.status, "withdrawn"
    session.flush()
    moved(session, app, before)
    return app


def decide(
    session: Session,
    application_id: uuid.UUID,
    decided_by: uuid.UUID,
    decision: Literal["offer", "reject"],
    note: str | None,
    offer_days: int,
    now: datetime,
) -> Application:
    """Ops decide a screened application: an offer with its expiry, or a rejection. Either is announced."""
    app = get_application(session, application_id, lock=True)
    if app.status != "screening":
        raise Conflict("application is not in screening", application_id=str(app.id), status=app.status).with_code(
            "not_screening"
        )
    listing = get_listing(session, app.listing_id)
    app.note, app.decided_by = note, decided_by
    if decision == "offer":
        app.status, app.offer_expires_at = "offered", now + timedelta(days=offer_days)
    else:
        app.status = "rejected"
    session.flush()
    moved(session, app, "screening")
    emit(
        session,
        OUTBOX,
        str(app.id),
        TalentApplicationDecided(
            application_id=app.id,
            listing_id=app.listing_id,
            listing_title=listing.title,
            worker_id=app.worker_id,
            decision=decision,
            offer_expires_at=app.offer_expires_at.isoformat() if app.offer_expires_at else None,
        ),
    )
    return app


def answer_offer(
    session: Session, application_id: uuid.UUID, worker_id: uuid.UUID, accept: bool, now: datetime
) -> Application:
    """Accept fills a slot under the listing's lock and opens the gate when the listing asks for no paper.
    An offer found past its expiry is marked expired in its own commit: that write must survive the 409."""
    app = own_application(session, application_id, worker_id, lock=True)
    if app.status == "offered" and app.offer_expires_at is not None and app.offer_expires_at <= now:
        app.status = "expired"
        moved(session, app, "offered")
        session.commit()
    if app.status == "expired":
        raise Conflict("offer has expired", application_id=str(app.id)).with_code("offer_expired")
    if app.status != "offered":
        raise Conflict("no offer to answer", application_id=str(app.id), status=app.status).with_code("not_offered")
    if not accept:
        app.status = "declined"
        session.flush()
        moved(session, app, "offered")
        return app
    listing = get_listing(session, app.listing_id, lock=True)
    if listing.slots_filled >= listing.slots_total:
        raise Conflict("listing filled meanwhile", listing_id=str(listing.id)).with_code("listing_full")
    listing.slots_filled += 1
    app.status = "accepted"
    gate = listing.cert_gate if listing.paper_id is None else None
    if gate is not None:
        upsert_gate(session, worker_id, gate, "offer", now)
    session.flush()
    moved(session, app, "offered")
    emit(
        session,
        OUTBOX,
        str(app.id),
        TalentOfferAccepted(application_id=app.id, listing_id=listing.id, worker_id=worker_id, gate=gate),
    )
    return app


# ---------- onboarding ----------


def ensure_onboarding(session: Session, worker_id: uuid.UUID) -> Onboarding:
    """The worker's row, created on first touch and locked for the step being written."""
    session.execute(
        pg_insert(Onboarding).values(worker_id=worker_id, steps={}).on_conflict_do_nothing(index_elements=["worker_id"])
    )
    return session.execute(
        select(Onboarding).where(Onboarding.worker_id == worker_id).with_for_update(),
        execution_options={"populate_existing": True},
    ).scalar_one()


def _finish(session: Session, row: Onboarding, step: str, now: datetime) -> Onboarding:
    """Mark the step done (again, harmlessly); the first time all six are done, announce the worker."""
    row.steps = {**row.steps, step: now.isoformat()}
    if row.eligible_sent_at is None and all(k in row.steps for k in ONBOARDING_STEPS):
        row.eligible_sent_at = now
        emit(
            session,
            OUTBOX,
            str(row.worker_id),
            WorkerEligible(
                worker_id=row.worker_id,
                legal_name_hash=pii_hash(normalise_name(row.legal_name or "")),
                pan_last4=row.pan_last4 or "",
            ),
        )
        log.info("worker eligible worker_id=%s", row.worker_id)
    session.flush()
    return row


def name_digest(name: str) -> str:
    return pii_hash(normalise_name(name))


def set_profile(session: Session, worker_id: uuid.UUID, body: ProfileIn, now: datetime) -> Onboarding:
    """The legal name becomes the worker's display name. Once the bank step is done the name may not drift from
    the verified account name; before that, a name that matches a verified account completes the bank step too."""
    row = ensure_onboarding(session, worker_id)
    digest = name_digest(body.legal_name)
    if "bank" in row.steps and row.account_name_hash is not None and row.account_name_hash != digest:
        raise Invalid("legal_name: must equal the verified bank account name").with_code("name_mismatch")
    row.legal_name, row.phone, row.city = body.legal_name, body.phone, body.city
    set_profile_name(session, worker_id, body.legal_name)
    row = _finish(session, row, "profile", now)
    if "bank" not in row.steps and row.account_name_hash == digest:
        row = _finish(session, row, "bank", now)
    return row


def on_account_verified(session: Session, worker_id: uuid.UUID, account_name_hash: str, now: datetime) -> Onboarding:
    """Payout verified the worker's bank account: the bank step is done when the account name equals the legal
    name. A mismatch (or no profile yet) leaves the step pending; a corrected profile name completes it."""
    row = ensure_onboarding(session, worker_id)
    row.account_name_hash, row.account_verified_at = account_name_hash, now
    if row.legal_name is not None and name_digest(row.legal_name) == account_name_hash:
        return _finish(session, row, "bank", now)
    log.warning("bank account name does not match the legal name yet worker_id=%s", worker_id)
    session.flush()
    return row


def set_agreement(session: Session, worker_id: uuid.UUID, body: AgreementIn, now: datetime) -> Onboarding:
    """The worker accepts the agreement they were shown; an older version than the current one is refused."""
    require_current(session, CONTRACTOR_AGREEMENT, body.version)
    row = ensure_onboarding(session, worker_id)
    row.agreement_version = body.version
    return _finish(session, row, "agreement", now)


def set_consent(session: Session, worker_id: uuid.UUID, body: ConsentIn, now: datetime) -> Onboarding:
    """Consent given records the version read and, when there was none, is announced (`worker.consent.given.v1`:
    the blocks a withdrawal put on lift). Consent withdrawn clears it, reopens the step, takes the worker off the
    eligible list (`eligible_sent_at` cleared, so `worker.eligible.v1` goes out again once the checklist is complete)
    and is announced (processing stops except what a legal duty needs: payout of earnings already accepted, tax
    records)."""
    row = ensure_onboarding(session, worker_id)
    if not body.accepted:
        was_given = row.consent_at is not None
        row.consent_at, row.consent_version = None, None
        row.steps = {k: v for k, v in row.steps.items() if k != "consent"}
        row.eligible_sent_at = None
        if was_given:
            emit(session, OUTBOX, str(worker_id), WorkerConsentWithdrawn(worker_id=worker_id))
            log.info("consent withdrawn worker_id=%s", worker_id)
        session.flush()
        return row
    current = current_policy(session, DPDP_CONSENT).label
    if body.version is not None and body.version != current:
        raise Invalid(f"version: the current consent text is {current}", latest=current).with_code("policy_outdated")
    if row.consent_at is None:
        emit(session, OUTBOX, str(worker_id), WorkerConsentGiven(worker_id=worker_id))
        log.info("consent given worker_id=%s", worker_id)
    row.consent_at, row.consent_version = now, current
    return _finish(session, row, "consent", now)


def set_identity(session: Session, worker_id: uuid.UUID, body: IdentityIn, now: datetime) -> Onboarding:
    """The PAN is normalised, checked, hashed and dropped; one PAN per person, and a person keeps their PAN."""
    pan = body.pan.strip().upper()
    if not re.fullmatch(PAN, pan):
        raise Invalid("pan: format ABCDE1234F")
    digest = pii_hash(pan)
    row = ensure_onboarding(session, worker_id)
    if row.pan_hash is not None and row.pan_hash != digest:
        raise Conflict("the PAN cannot change once set", worker_id=str(worker_id)).with_code("pan_locked")
    other = session.scalar(
        select(Onboarding.worker_id).where(Onboarding.pan_hash == digest, Onboarding.worker_id != worker_id)
    )
    if other is not None:
        raise Conflict("this PAN is already in use", worker_id=str(worker_id)).with_code("pan_in_use")
    row.pan_hash, row.pan_last4, row.aadhaar_last4 = digest, pan[-4:], body.aadhaar_last4
    return _finish(session, row, "identity", now)


def set_payout_ack(session: Session, worker_id: uuid.UUID, now: datetime) -> Onboarding:
    row = ensure_onboarding(session, worker_id)
    row.payout_ack_at = now
    return _finish(session, row, "payout_ack", now)


def steps_done(steps: dict[str, Any]) -> int:
    return sum(1 for k in ONBOARDING_STEPS if k in steps)


def onboarding_out(
    row: Onboarding | None, documents: list[WorkerDocument] | None = None, erasure: Erasure | None = None
) -> OnboardingOut:
    """The grouped checklist; a worker who has done nothing yet sees six pending steps, never a 404."""
    steps: dict[str, Any] = row.steps if row is not None else {}
    items = [
        OnboardingStepOut(
            key=k,
            status="done" if k in steps else "pending",
            done_at=datetime.fromisoformat(steps[k]) if k in steps else None,
            group=GROUPS[k],
        )
        for k in ONBOARDING_STEPS
    ]
    return OnboardingOut(
        complete=steps_done(steps) == len(ONBOARDING_STEPS),
        eligible_sent_at=row.eligible_sent_at if row is not None else None,
        steps=items,
        agreement_version=row.agreement_version if row is not None else None,
        consent_version=row.consent_version if row is not None else None,
        documents=[DocumentBriefOut(kind=d.kind, uploaded_at=d.uploaded_at) for d in documents or []],
        erasure=ErasureOut.model_validate(erasure) if erasure is not None else None,
    )


def my_onboarding(session: Session, worker_id: uuid.UUID) -> OnboardingOut:
    return onboarding_out(
        session.get(Onboarding, worker_id), my_documents(session, worker_id), session.get(Erasure, worker_id)
    )


def list_onboarding(session: Session, status: Literal["complete", "incomplete"] | None) -> list[OnboardingRowOut]:
    rows = session.scalars(select(Onboarding).order_by(Onboarding.updated_at.desc(), Onboarding.worker_id))
    out = [
        OnboardingRowOut(
            worker_id=r.worker_id,
            complete=steps_done(r.steps) == len(ONBOARDING_STEPS),
            steps_done=steps_done(r.steps),
            updated_at=r.updated_at,
        )
        for r in rows
    ]
    if status is None:
        return out
    return [o for o in out if o.complete == (status == "complete")]


# ---------- people ----------


def _announce_person(session: Session, person_id: uuid.UUID, name: str | None, kind: str) -> None:
    emit(session, OUTBOX, str(person_id), TalentPersonSeen(id=person_id, name=name, kind=kind))


def see(session: Session, person_id: uuid.UUID, name: str | None, kind: Kind) -> bool:
    """Record a caller by the name their token carries, once: a row whose name came from the worker's profile is
    never overwritten by a token name. Announces only a real change. Returns whether anything changed."""
    if name is None or _seen.get(person_id) == (name, kind):
        return False
    stmt = pg_insert(PERSON).values(id=person_id, name=name, kind=kind, source="token")
    changed = session.execute(
        stmt.on_conflict_do_update(
            index_elements=["id"],
            set_={"name": stmt.excluded.name, "kind": stmt.excluded.kind, "seen_at": func.now()},
            where=and_(
                PERSON.c.source == "token",
                or_(PERSON.c.name.is_distinct_from(stmt.excluded.name), PERSON.c.kind != stmt.excluded.kind),
            ),
        ).returning(PERSON.c.id)
    ).first()
    if changed is None:  # already recorded (or a profile name stands): safe to skip next time
        if len(_seen) >= SEEN_CACHE_MAX:
            _seen.clear()
        _seen[person_id] = (name, kind)
        return False
    _announce_person(session, person_id, name, kind)
    return True


def set_profile_name(session: Session, worker_id: uuid.UUID, legal_name: str) -> None:
    """The worker's legal name is their display name from now on; a token name never replaces it."""
    stmt = pg_insert(PERSON).values(id=worker_id, name=legal_name, kind="worker", source="profile")
    changed = session.execute(
        stmt.on_conflict_do_update(
            index_elements=["id"],
            set_={"name": legal_name, "kind": "worker", "source": "profile", "seen_at": func.now()},
            where=or_(PERSON.c.source != "profile", PERSON.c.name.is_distinct_from(legal_name)),
        ).returning(PERSON.c.id)
    ).first()
    _seen.pop(worker_id, None)
    if changed is not None:
        _announce_person(session, worker_id, legal_name, "worker")


def person(session: Session, person_id: uuid.UUID) -> PersonOut:
    row = session.execute(select(PERSON.c.name, PERSON.c.kind).where(PERSON.c.id == person_id)).first()
    if row is None:
        raise NotFound("person not known", person_id=str(person_id))
    return PersonOut(id=person_id, name=row.name, kind=row.kind)


# ---------- policies ----------


def policy_out(row: Policy) -> PolicyOut:
    return PolicyOut(
        slug=row.slug,
        version=row.label,
        revision=row.revision,
        title=row.title,
        summary=row.summary,
        sections=row.sections,  # validated into PolicySection
        updated_at=row.effective_at,
    )


def current_policies(session: Session) -> list[Policy]:
    stmt = select(Policy).distinct(Policy.slug).order_by(Policy.slug, Policy.revision.desc())
    return list(session.scalars(stmt))


def current_policy(session: Session, slug: str, lock: bool = False) -> Policy:
    stmt = select(Policy).where(Policy.slug == slug).order_by(Policy.revision.desc()).limit(1)
    row = session.scalar(stmt.with_for_update() if lock else stmt)
    if row is None:
        raise NotFound("policy not found", slug=slug)
    return row


def policy_version(session: Session, slug: str, revision: int) -> Policy:
    row = session.get(Policy, (slug, revision))
    if row is None:
        raise NotFound("policy version not found", slug=slug, revision=revision)
    return row


def require_current(session: Session, slug: str, label: str) -> None:
    current = current_policy(session, slug).label
    if label != current:
        raise Invalid(f"version: the current {slug} is {current}", latest=current).with_code("policy_outdated")


def put_policy(session: Session, slug: str, body: PolicyIn, by: uuid.UUID) -> Policy:
    """A new version, never an edit. The latest row is locked so two editors cannot both take the next number;
    a new slug starts at revision 1."""
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,39}", slug):
        raise Invalid("slug: lower-case letters, digits and '-', at most 40")
    latest = session.scalar(
        select(Policy).where(Policy.slug == slug).order_by(Policy.revision.desc()).limit(1).with_for_update()
    )
    revision = 1 if latest is None else latest.revision + 1
    row = Policy(
        slug=slug,
        revision=revision,
        label=body.label or str(revision),
        title=body.title,
        summary=body.summary,
        sections=[s.model_dump() for s in body.sections],
        created_by=by,
    )
    session.add(row)
    session.flush()
    session.refresh(row)
    log.info("policy version slug=%s revision=%d by=%s", slug, revision, by)
    return row


# ---------- documents ----------


def my_documents(session: Session, worker_id: uuid.UUID) -> list[WorkerDocument]:
    stmt = select(WorkerDocument).where(WorkerDocument.worker_id == worker_id).order_by(WorkerDocument.kind)
    return list(session.scalars(stmt))


def presign_document(storage: Storage, worker_id: uuid.UUID, body: DocumentPresignIn, now: datetime) -> PresignedOut:
    """Where the browser puts the file: a fresh key under the worker's own prefix, valid a few minutes."""
    key = document_key(worker_id, body.kind, uuid.uuid4())
    signed = storage.presign_put(key, body.content_type, body.size_bytes, size_bytes=body.size_bytes, now=now)
    return PresignedOut(
        key=key,
        url=signed.url,
        method=signed.method,
        headers=signed.headers,
        expires_at=signed.expires_at,
        max_bytes=body.size_bytes,
    )


def register_document(
    session: Session, storage: Storage, worker_id: uuid.UUID, kind: str, body: DocumentIn
) -> WorkerDocument:
    """Record an uploaded document after checking the object is there, under this worker's prefix for this kind,
    and the size the app declared. A replaced document's previous object is deleted. The sha256 is the app's own
    digest of the bytes (a single PUT's ETag is an MD5, not a sha256); storage vouches for the size."""
    prefix = f"workers/{worker_id}/documents/{kind}/"
    if not body.key.startswith(prefix) or ".." in body.key:
        raise Invalid("key: not one of your uploads for this kind").with_code("key_not_yours")
    info = storage.head(body.key)
    if info is None:
        raise Invalid("key: nothing was uploaded there").with_code("object_missing")
    if info.size != body.size_bytes:
        storage.delete([body.key])
        raise Invalid("size_bytes: the upload is not the size declared").with_code("size_mismatch")
    current = session.get(WorkerDocument, (worker_id, kind), with_for_update=True)
    old_key = current.key if current is not None and current.key != body.key else None
    if current is None:
        current = WorkerDocument(worker_id=worker_id, kind=kind)
        session.add(current)
    current.key, current.sha256, current.size_bytes = body.key, body.sha256, body.size_bytes
    current.content_type = info.content_type or "application/octet-stream"
    current.uploaded_at = datetime.now(UTC)
    session.flush()
    if old_key is not None:
        storage.delete([old_key])
    return current


def document_url(
    session: Session, storage: Storage, worker_id: uuid.UUID, kind: str, now: datetime
) -> tuple[str, datetime]:
    doc = session.get(WorkerDocument, (worker_id, kind))
    if doc is None:
        raise NotFound("document not found", worker_id=str(worker_id), kind=kind)
    signed = storage.presign_get(doc.key, now=now)
    log.info("document url issued worker_id=%s kind=%s", worker_id, kind)
    return signed.url, signed.expires_at


# ---------- erasure ----------


def request_erasure(session: Session, worker_id: uuid.UUID, now: datetime) -> Erasure:
    current = session.get(Erasure, worker_id, with_for_update=True)
    if current is not None:
        code = "erasure_done" if current.status == "done" else "erasure_pending"
        raise Conflict("an erasure request already exists", worker_id=str(worker_id), status=current.status).with_code(
            code
        )
    row = Erasure(worker_id=worker_id, status="requested", requested_at=now, due_at=now + ERASURE_GRACE)
    session.add(row)
    session.flush()
    emit(session, OUTBOX, str(worker_id), WorkerErasureRequested(worker_id=worker_id, due_at=row.due_at.isoformat()))
    log.info("erasure requested worker_id=%s", worker_id)
    return row


def approve_erasure(session: Session, worker_id: uuid.UUID, by: uuid.UUID, now: datetime) -> Erasure:
    """Ops bring the erasure forward: the next pass of the hourly job does it."""
    row = session.get(Erasure, worker_id, with_for_update=True)
    if row is None:
        raise NotFound("no erasure request", worker_id=str(worker_id))
    if row.status == "done":
        raise Conflict("already erased", worker_id=str(worker_id)).with_code("erasure_done")
    row.status, row.approved_at, row.approved_by, row.due_at = "approved", now, by, now
    session.flush()
    log.info("erasure approved worker_id=%s by=%s", worker_id, by)
    return row


def list_erasures(session: Session, status: str | None) -> list[Erasure]:
    stmt = select(Erasure).order_by(Erasure.due_at, Erasure.worker_id)
    if status is not None:
        stmt = stmt.where(Erasure.status == status)
    return list(session.scalars(stmt))


def worker_prefix(worker_id: uuid.UUID) -> str:
    """Everything a worker ever uploaded lives under this prefix (`document_key`), registered or not."""
    return f"workers/{worker_id}/"


def run_due_erasures(session: Session, storage: Storage | None, now: datetime | None = None, limit: int = 50) -> int:
    """Erase what is due. Kept: the PAN digest and last four (tax), the agreement and consent records (the consent
    itself is evidence), every id. Erased: name, phone, city, Aadhaar last four, the account-name digest, the answers
    on every application, the documents and every object under `workers/<id>/` (listed, so an upload never
    registered goes too), the display name everywhere (`talent.person.seen.v1` with no name). A worker with
    documents is skipped while storage is not configured: an erasure that left the files behind is not done."""
    now = now or datetime.now(UTC)
    due = session.scalars(
        select(Erasure)
        .where(Erasure.status != "done", Erasure.due_at <= now)
        .order_by(Erasure.due_at)
        .limit(limit)
        .with_for_update(skip_locked=True)
    ).all()
    done = 0
    for erasure in due:
        documents = my_documents(session, erasure.worker_id)
        if documents and storage is None:
            log.error("erasure waits for storage worker_id=%s documents=%d", erasure.worker_id, len(documents))
            continue
        if storage is not None:
            keys = sorted({*storage.list_keys(worker_prefix(erasure.worker_id)), *(d.key for d in documents)})
            if keys:
                storage.delete(keys)
        session.execute(delete(WorkerDocument).where(WorkerDocument.worker_id == erasure.worker_id))
        session.execute(update(Application).where(Application.worker_id == erasure.worker_id).values(answers={}))
        session.execute(
            update(Onboarding)
            .where(Onboarding.worker_id == erasure.worker_id)
            .values(legal_name=None, phone=None, city=None, aadhaar_last4=None, account_name_hash=None)
        )
        session.execute(
            pg_insert(PERSON)
            .values(id=erasure.worker_id, name=None, kind="worker", source="profile")
            .on_conflict_do_update(index_elements=["id"], set_={"name": None, "source": "profile"})
        )
        # no `_seen.pop` here: this runs in the events process, the cache lives in the API process. A stale entry
        # there is harmless: `see` never overwrites a `profile` row, which this erased row now is.
        _announce_person(session, erasure.worker_id, None, "worker")
        emit(session, OUTBOX, str(erasure.worker_id), WorkerErasureCompleted(worker_id=erasure.worker_id))
        erasure.status, erasure.done_at = "done", now
        done += 1
        log.info("erasure done worker_id=%s documents=%d", erasure.worker_id, len(documents))
    session.flush()
    return done


# ---------- attention ----------


def attention(session: Session, now: datetime) -> dict[str, int]:
    """What waits on ops in talent: applications to screen, erasures pending and overdue."""
    screening = session.scalar(select(func.count()).where(Application.status == "screening")) or 0
    pending = session.scalar(select(func.count()).select_from(Erasure).where(Erasure.status != "done")) or 0
    due = (
        session.scalar(select(func.count()).select_from(Erasure).where(Erasure.status != "done", Erasure.due_at <= now))
        or 0
    )
    return {"applications_screening": int(screening), "erasures_pending": int(pending), "erasures_due": int(due)}
