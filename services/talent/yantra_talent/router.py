"""HTTP surface of the talent module (docs/PRODUCT.md section 5.2). The gateway authenticates; this layer trusts
`X-Worker-Id`, `X-Role` and `X-Name`. Every handler is one unit of work. Every request also records the caller's
display name on first sight (`seen`), in the same unit of work."""

import uuid
from typing import Literal

from fastapi import APIRouter, Depends, Query, status

from yantra_common.deps import DB, Ops, Roles, StorageDep, Worker, WorkerId
from yantra_common.errors import Conflict, Forbidden
from yantra_common.people import Name, kind_of
from yantra_talent import service
from yantra_talent.models import Application, DocumentKind, Erasure, Listing, Onboarding
from yantra_talent.schemas import (
    AgreementIn,
    ApplicationOut,
    ApplyIn,
    ConsentIn,
    DecideIn,
    DocumentIn,
    DocumentOut,
    DocumentPresignIn,
    ErasureOut,
    IdentityIn,
    ListingIn,
    ListingOut,
    ListingPatch,
    OfferAnswerIn,
    OnboardingOut,
    OnboardingRowOut,
    OpsListingOut,
    PayoutAckIn,
    PersonOut,
    PolicyIn,
    PolicyOut,
    PresignedOut,
    ProfileIn,
    UrlOut,
    WorkerListingOut,
)

BANK_LOCATION = "/v1/payout/accounts/me"


def seen(caller: WorkerId, roles: Roles, name: Name, session: DB) -> None:
    """Record the caller's display name from the token (`X-Name`) the first time it is seen or changes. (Named
    `caller`, not `worker_id`: a route's own `{worker_id}` path parameter would collide.)"""
    service.see(session, caller, name, kind_of(roles))


router = APIRouter(prefix="/v1/talent", tags=["talent"], dependencies=[Depends(seen)])


# ---------- listings ----------


@router.get("/listings", response_model=list[WorkerListingOut] | list[OpsListingOut], dependencies=[Worker])
def listings(
    worker_id: WorkerId,
    roles: Roles,
    session: DB,
    all: bool = Query(default=False),  # noqa: A002 - the contract's query name
    domain: str | None = Query(default=None, max_length=80),
    commitment: Literal["task_based", "part_time"] | None = Query(default=None),
) -> list[WorkerListingOut] | list[OpsListingOut]:
    """Open listings with the caller's angle on each; `all=true` (ops) is every listing with its pipeline counts."""
    now = service.now_utc()
    if all:
        if "ops" not in roles:
            raise Forbidden("operator role required")
        rows = service.all_listings(session)
        counts = service.application_counts(session, [r.id for r in rows])
        hired = service.hired_this_week(session, [r.id for r in rows], now)
        return [
            OpsListingOut(
                **{**ListingOut.model_validate(r).model_dump(), "hired_this_week": hired.get(r.id, 0)},
                applications=counts[r.id],
            )
            for r in rows
        ]
    rows = service.open_listings(session, now, domain=domain, commitment=commitment)
    viewers = service.viewers_of(session, rows, worker_id)
    hired = service.hired_this_week(session, [r.id for r in rows], now)
    return [
        WorkerListingOut(
            **{**ListingOut.model_validate(r).model_dump(), "hired_this_week": hired.get(r.id, 0)},
            viewer=viewers[r.id],
        )
        for r in rows
    ]


@router.post("/listings", response_model=ListingOut, status_code=status.HTTP_201_CREATED, dependencies=[Ops])
def create_listing(body: ListingIn, session: DB) -> Listing:
    return service.create_listing(session, body, service.now_utc())


@router.get("/listings/{listing_id}", response_model=WorkerListingOut, dependencies=[Worker])
def get_listing(listing_id: uuid.UUID, worker_id: WorkerId, roles: Roles, session: DB) -> WorkerListingOut:
    """A closed listing comes back as closed with `viewer.redirect` to an open pool of the same domain."""
    return service.worker_listing(session, listing_id, worker_id, service.now_utc(), ops="ops" in roles)


@router.patch("/listings/{listing_id}", response_model=ListingOut, dependencies=[Ops])
def patch_listing(listing_id: uuid.UUID, body: ListingPatch, session: DB) -> Listing:
    return service.patch_listing(session, listing_id, body, service.now_utc())


@router.get("/listings/{listing_id}/applications", response_model=list[ApplicationOut], dependencies=[Ops])
def listing_applications(
    listing_id: uuid.UUID,
    session: DB,
    status: Literal[
        "applied", "assessment", "screening", "offered", "accepted", "declined", "rejected", "withdrawn", "expired"
    ]
    | None = Query(default=None),  # noqa: E501
) -> list[ApplicationOut]:
    """Every application with the worker's display name and the latest paper outcome."""
    return service.listing_applications(session, listing_id, status, service.now_utc())


@router.post(
    "/listings/{listing_id}/applications",
    response_model=ApplicationOut,
    status_code=status.HTTP_201_CREATED,
    dependencies=[Worker],
)
def apply(listing_id: uuid.UUID, body: ApplyIn, worker_id: WorkerId, session: DB) -> ApplicationOut:
    app = service.apply(session, listing_id, worker_id, body.answers, service.now_utc())
    return service.application_out(app, service.get_listing(session, listing_id))


# ---------- applications ----------


def _out(session: DB, app: Application) -> ApplicationOut:
    return service.application_out(app, service.get_listing(session, app.listing_id))


@router.get("/applications/me", response_model=list[ApplicationOut], dependencies=[Worker])
def my_applications(worker_id: WorkerId, session: DB) -> list[ApplicationOut]:
    return service.my_applications(session, worker_id, service.now_utc())


@router.post("/applications/{application_id}/withdraw", response_model=ApplicationOut, dependencies=[Worker])
def withdraw(application_id: uuid.UUID, worker_id: WorkerId, session: DB) -> ApplicationOut:
    return _out(session, service.withdraw(session, application_id, worker_id))


@router.post("/applications/{application_id}/offer", response_model=ApplicationOut, dependencies=[Worker])
def answer_offer(application_id: uuid.UUID, body: OfferAnswerIn, worker_id: WorkerId, session: DB) -> ApplicationOut:
    return _out(session, service.answer_offer(session, application_id, worker_id, body.accept, service.now_utc()))


@router.post("/applications/{application_id}/decide", response_model=ApplicationOut, dependencies=[Ops])
def decide(application_id: uuid.UUID, body: DecideIn, worker_id: WorkerId, session: DB) -> ApplicationOut:
    """`X-Worker-Id` is the deciding operator: recorded as `decided_by`."""
    app = service.decide(
        session, application_id, worker_id, body.decision, body.note, body.offer_days, service.now_utc()
    )
    return _out(session, app)


# ---------- onboarding ----------


def _onboarding(session: DB, row: Onboarding) -> OnboardingOut:
    return service.my_onboarding(session, row.worker_id)


@router.get("/workers/me/onboarding", response_model=OnboardingOut, dependencies=[Worker])
def my_onboarding(worker_id: WorkerId, session: DB) -> OnboardingOut:
    return service.my_onboarding(session, worker_id)


@router.put("/workers/me/onboarding/profile", response_model=OnboardingOut, dependencies=[Worker])
def profile(body: ProfileIn, worker_id: WorkerId, session: DB) -> OnboardingOut:
    return _onboarding(session, service.set_profile(session, worker_id, body, service.now_utc()))


@router.put("/workers/me/onboarding/agreement", response_model=OnboardingOut, dependencies=[Worker])
def agreement(body: AgreementIn, worker_id: WorkerId, session: DB) -> OnboardingOut:
    return _onboarding(session, service.set_agreement(session, worker_id, body, service.now_utc()))


@router.put("/workers/me/onboarding/consent", response_model=OnboardingOut, dependencies=[Worker])
def consent(body: ConsentIn, worker_id: WorkerId, session: DB) -> OnboardingOut:
    """`accepted: false` withdraws the consent (the step reopens; payouts stop)."""
    return _onboarding(session, service.set_consent(session, worker_id, body, service.now_utc()))


@router.put("/workers/me/onboarding/identity", response_model=OnboardingOut, dependencies=[Worker])
def identity(body: IdentityIn, worker_id: WorkerId, session: DB) -> OnboardingOut:
    return _onboarding(session, service.set_identity(session, worker_id, body, service.now_utc()))


@router.put("/workers/me/onboarding/bank", dependencies=[Worker])
def bank() -> None:
    """Moved: the account belongs to the module that pays. The step completes when payout verifies the account."""
    raise Conflict("the bank step moved to payout", location=BANK_LOCATION).with_code("bank_moved")


@router.put("/workers/me/onboarding/payout_ack", response_model=OnboardingOut, dependencies=[Worker])
def payout_ack(body: PayoutAckIn, worker_id: WorkerId, session: DB) -> OnboardingOut:
    return _onboarding(session, service.set_payout_ack(session, worker_id, service.now_utc()))


@router.get("/onboarding", response_model=list[OnboardingRowOut], dependencies=[Ops])
def onboarding_rows(
    session: DB, status: Literal["complete", "incomplete"] | None = Query(default=None)
) -> list[OnboardingRowOut]:
    return service.list_onboarding(session, status)


# ---------- documents ----------


@router.post("/workers/me/documents/presign", response_model=PresignedOut, dependencies=[Worker])
def presign_document(body: DocumentPresignIn, worker_id: WorkerId, storage: StorageDep) -> PresignedOut:
    """Where to PUT the file: the browser sends it straight to storage with the returned headers."""
    return service.presign_document(storage, worker_id, body, service.now_utc())


@router.put("/workers/me/documents/{kind}", response_model=DocumentOut, dependencies=[Worker])
def register_document(
    kind: DocumentKind, body: DocumentIn, worker_id: WorkerId, storage: StorageDep, session: DB
) -> DocumentOut:
    return DocumentOut.model_validate(service.register_document(session, storage, worker_id, kind, body))


@router.get("/workers/me/documents", response_model=list[DocumentOut], dependencies=[Worker])
def my_documents(worker_id: WorkerId, session: DB) -> list[DocumentOut]:
    return [DocumentOut.model_validate(d) for d in service.my_documents(session, worker_id)]


@router.get("/workers/{worker_id}/documents", response_model=list[DocumentOut], dependencies=[Ops])
def worker_documents(worker_id: uuid.UUID, session: DB) -> list[DocumentOut]:
    return [DocumentOut.model_validate(d) for d in service.my_documents(session, worker_id)]


@router.get("/workers/{worker_id}/documents/{kind}/url", response_model=UrlOut, dependencies=[Ops])
def worker_document_url(worker_id: uuid.UUID, kind: DocumentKind, storage: StorageDep, session: DB) -> UrlOut:
    """A five-minute link for ops to check a document; issuing one is logged with the ids."""
    url, expires_at = service.document_url(session, storage, worker_id, kind, service.now_utc())
    return UrlOut(url=url, expires_at=expires_at)


# ---------- people ----------


@router.put("/people/me", response_model=PersonOut)
def people_me(worker_id: WorkerId, session: DB) -> PersonOut:
    """Any signed-in person: the app calls it once per session so a staff or client name is known everywhere
    (the router's `seen` dependency has already recorded it from `X-Name`)."""
    return service.person(session, worker_id)


# ---------- policies ----------


@router.get("/policies", response_model=list[PolicyOut])
def policies(session: DB) -> list[PolicyOut]:
    """The current version of every policy; any signed-in person."""
    return [service.policy_out(p) for p in service.current_policies(session)]


@router.get("/policies/{slug}", response_model=PolicyOut)
def policy(slug: str, session: DB, revision: int | None = Query(default=None, ge=1)) -> PolicyOut:
    row = service.current_policy(session, slug) if revision is None else service.policy_version(session, slug, revision)
    return service.policy_out(row)


@router.put("/policies/{slug}", response_model=PolicyOut, dependencies=[Ops])
def put_policy(slug: str, body: PolicyIn, worker_id: WorkerId, session: DB) -> PolicyOut:
    """A new version; the previous ones stay readable by `revision`."""
    return service.policy_out(service.put_policy(session, slug, body, worker_id))


# ---------- erasure ----------


@router.post(
    "/workers/me/erasure", response_model=ErasureOut, status_code=status.HTTP_201_CREATED, dependencies=[Worker]
)
def request_erasure(worker_id: WorkerId, session: DB) -> Erasure:
    """Erase my personal data: done within 30 days, or sooner when ops approve."""
    return service.request_erasure(session, worker_id, service.now_utc())


@router.get("/erasures", response_model=list[ErasureOut], dependencies=[Ops])
def erasures(
    session: DB, status: Literal["requested", "approved", "done"] | None = Query(default=None)
) -> list[Erasure]:
    return service.list_erasures(session, status)


@router.post("/erasures/{worker_id}/approve", response_model=ErasureOut, dependencies=[Ops])
def approve_erasure(worker_id: uuid.UUID, caller: WorkerId, session: DB) -> Erasure:
    return service.approve_erasure(session, worker_id, caller, service.now_utc())


# ---------- attention ----------


@router.get("/attention", response_model=dict[str, int], dependencies=[Ops])
def attention(session: DB) -> dict[str, int]:
    return service.attention(session, service.now_utc())
