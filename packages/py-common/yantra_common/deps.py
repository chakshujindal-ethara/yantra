"""The FastAPI dependencies every module's router shares, and the trusted-header contract in one place:
the gateway sets `X-Worker-Id` (the caller), `X-Email` and `X-Email-Verified` (the token's email,
percent-encoded, and whether Keycloak verified it; both absent when the token has none) and `X-Role` (the
caller's realm roles, comma-separated, in the order `admin,ops,finance,reviewer,client,worker`, an empty string
when the caller holds none); the services trust them. A plain worker carries `X-Role: worker`.

Six realm roles: `worker` (claims, pay, onboarding), `reviewer` (claims review and audit tasks; also a worker for
pay), `ops` (projects, batches, listings, papers, workers, quality, support), `finance` (closes, approves and pays
windows, decides adjustments), `admin` (dead letters and jobs), `client` (the client console). `admin` does not
imply `ops` or `finance`."""

import uuid
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from typing import Annotated
from urllib.parse import unquote

from fastapi import Depends, Header, Request
from sqlalchemy.orm import Session

from yantra_common.db import unit_of_work
from yantra_common.errors import Forbidden
from yantra_common.storage import Storage, StorageUnconfigured

ROLE_ORDER = ("admin", "ops", "finance", "reviewer", "client", "worker")


def db(request: Request) -> Iterator[Session]:
    """One unit of work per request: commit on success, roll back on any error."""
    with unit_of_work(request.app.state.factory) as session:
        yield session


def storage(request: Request) -> Storage:
    """The process's object store; 503 `storage_unconfigured` when the deployable runs without one."""
    store: Storage | None = getattr(request.app.state, "storage", None)
    if store is None:
        raise StorageUnconfigured("object storage is not configured on this deployment")
    return store


def optional_storage(request: Request) -> Storage | None:
    """The object store when the deployment has one; for routes that work without it (an import of plain lines)."""
    return getattr(request.app.state, "storage", None)


def parse_roles(header: str | None) -> frozenset[str]:
    return frozenset(r.strip() for r in (header or "").split(",") if r.strip())


def role_header(roles: frozenset[str] | set[str]) -> str:
    """The header value for a set of roles: known roles in a fixed order, unknown ones dropped."""
    return ",".join(r for r in ROLE_ORDER if r in roles)


def roles(role: Annotated[str | None, Header(alias="X-Role")] = None) -> frozenset[str]:
    return parse_roles(role)


def require_any(*names: str, message: str) -> Callable[[str | None], None]:
    """A guard that passes when the caller holds any of `names`; `message` is the 403's text."""
    wanted = frozenset(names)

    def guard(role: Annotated[str | None, Header(alias="X-Role")] = None) -> None:
        if parse_roles(role).isdisjoint(wanted):
            raise Forbidden(message)

    return guard


require_ops = require_any("ops", message="operator role required")
require_finance = require_any("finance", message="finance role required")
require_finance_or_ops = require_any("finance", "ops", message="finance or operator role required")
require_reviewer = require_any("reviewer", "ops", message="reviewer role required")
require_admin = require_any("admin", message="admin role required")
require_admin_or_ops = require_any("admin", "ops", message="admin or operator role required")
# A client console caller; an operator may look too.
require_client = require_any("client", "ops", message="client role required")
# A worker surface (pay, claims, sittings, onboarding, inbox); an operator may walk the flow in the rig too.
require_worker = require_any("worker", "ops", message="worker role required")

DB = Annotated[Session, Depends(db)]
Ops = Depends(require_ops)
Finance = Depends(require_finance)
FinanceOrOps = Depends(require_finance_or_ops)
Reviewer = Depends(require_reviewer)
Admin = Depends(require_admin)
AdminOrOps = Depends(require_admin_or_ops)
ClientRole = Depends(require_client)
Worker = Depends(require_worker)
Roles = Annotated[frozenset[str], Depends(roles)]
StorageDep = Annotated[Storage, Depends(storage)]
MaybeStorage = Annotated[Storage | None, Depends(optional_storage)]
WorkerId = Annotated[uuid.UUID, Header(alias="X-Worker-Id")]


@dataclass(frozen=True)
class Email:
    """The caller's email as the gateway forwarded it: `address` is empty when the token carries none."""

    address: str
    verified: bool


def caller_email(
    x_email: Annotated[str | None, Header(alias="X-Email")] = None,
    x_email_verified: Annotated[str | None, Header(alias="X-Email-Verified")] = None,
) -> Email:
    address = unquote(x_email).strip()[:254] if x_email else ""
    return Email(address=address, verified=bool(address) and x_email_verified == "true")


CallerEmail = Annotated[Email, Depends(caller_email)]
