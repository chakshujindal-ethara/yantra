"""Test helpers for the payout module: envelopes shaped like the events it consumes."""

import uuid
from datetime import UTC, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from yantra_common.crypto import key_id_of, seal
from yantra_common.events import Envelope
from yantra_common.pii import normalise_name, pii_hash
from yantra_common.testing import database_fixtures as _database_fixtures
from yantra_payout.models import TABLES, BankAccount, PayWindow, WindowLine

ALEMBIC_INI = Path(__file__).resolve().parents[1] / "alembic.ini"


def database_fixtures(db_name: str) -> tuple[Any, Any, Any]:
    return _database_fixtures(db_name, [ALEMBIC_INI], TABLES)


def envelope(type_: str, data: dict[str, Any]) -> Envelope:
    return Envelope(id=uuid.uuid4(), type=type_, subject="test", occurred_at=datetime.now(UTC), data=data)


def published(batch_id: uuid.UUID, unit_pay: str = "28", unit_price: str = "60", review_pay: str = "6") -> Envelope:
    return envelope(
        "work.unit.published.v1",
        {
            "batch_id": str(batch_id),
            "unit_count": 10,
            "unit_pay": unit_pay,
            "unit_price": unit_price,
            "review_pay": review_pay,
            "currency": "INR",
            "mode": "open",
        },
    )


def accepted(batch_id: uuid.UUID, worker: uuid.UUID, reviewer: uuid.UUID, auditor: uuid.UUID | None = None) -> Envelope:
    return envelope(
        "quality.verdict.accepted.v1",
        {
            "unit_id": str(uuid.uuid4()),
            "batch_id": str(batch_id),
            "submission_id": str(uuid.uuid4()),
            "worker_id": str(worker),
            "reviewer_id": str(reviewer),
            "auditor_id": None if auditor is None else str(auditor),
            "rubric_version": "v1",
        },
    )


def rejected(batch_id: uuid.UUID, worker: uuid.UUID, reviewer: uuid.UUID, billable: bool = False) -> Envelope:
    return envelope(
        "quality.verdict.rejected.v1",
        {
            "unit_id": str(uuid.uuid4()),
            "batch_id": str(batch_id),
            "submission_id": str(uuid.uuid4()),
            "worker_id": str(worker),
            "reviewer_id": str(reviewer),
            "auditor_id": None,
            "rubric_version": "v1",
            "verdict": "reject",
            "reason_code": "client_glossary_change" if billable else "low_quality",
            "billable": billable,
        },
    )


def verified_account(
    session: Session,
    worker_id: uuid.UUID,
    number: str | None = None,
    ifsc: str = "HDFC0001234",
    name: str = "Asha Rao",
    rail: str = "fake",
) -> BankAccount:
    """A bank account already registered and verified, the state a worker reaches after the penny drop. The
    number defaults to one derived from the worker id, so two workers never share an account."""
    existing = session.get(BankAccount, worker_id)
    if existing is not None:
        return existing
    number = number or str(worker_id.int)[:12]
    sealed = seal(number.encode(), worker_id.bytes)
    account = BankAccount(
        worker_id=worker_id,
        account_name=name,
        account_name_hash=pii_hash(normalise_name(name)),
        account_last4=number[-4:],
        ifsc=ifsc,
        account_sealed=sealed,
        key_id=key_id_of(sealed),
        account_hash=pii_hash(f"{ifsc}:{number}"),
        status="verified",
        verification="penny_drop",
        registered_name_match=True,
        rail=rail,
        rail_contact_id=f"cont_test_{worker_id.hex[:12]}",
        rail_fund_account_id=f"fa_test_{worker_id.hex[:12]}",
        validations_today=0,
        verified_at=datetime.now(UTC),
    )
    session.add(account)
    session.flush()
    return account


def pay_out(session: Session, window_id: uuid.UUID, now: datetime | None = None, rail: str = "fake") -> PayWindow:
    """Pay an approved window as if the rail paid every line at once: pay, then settle each line paid."""
    from yantra_payout.paying import pay_window, settle_line
    from yantra_payout.rails import PayoutResult

    window = pay_window(session, window_id, rail, Decimal("1e12"), now)
    for line in list(
        session.scalars(select(WindowLine).where(WindowLine.window_id == window_id, WindowLine.status == "queued"))
    ):
        line.status = "processing"
        result = PayoutResult(
            reference=f"pout_test_{line.id.hex[:12]}",
            status="paid",
            utr=f"UTR{line.id.hex[:8]}",
            reference_id=f"{line.id}:{line.attempts}",
        )
        settle_line(session, line, result, now)
    session.flush()
    return window
