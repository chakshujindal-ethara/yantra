"""The bank account a worker is paid into. The module that pays owns it: the number is sealed here, registered
with the rail here, and verified by the rail's penny drop here. Talent never sees it; it learns the outcome from
`payout.account.verified.v1` (a keyed digest of the name on the account, compared there with the legal name).

Rules: one account per number across the platform (409 `account_in_use`); at most `validations_per_day` penny
drops per worker per day (429 `validation_limit`, a penny drop is a paid call); the bank's registered name must
match the name given (`name_mismatch`); a penny drop that proves no name at all leaves the account verified but
`awaiting_confirmation`, and nothing is paid into it until finance confirms it (`POST .../accounts/{id}/confirm`);
changing a verified account holds payouts for 72 hours (`bank_change`). A rail without a penny drop (the bank file)
registers the account as given: `verification=none`."""

import logging
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, sessionmaker

from yantra_common.crypto import key_id_of, open_sealed, seal
from yantra_common.db import unit_of_work
from yantra_common.errors import Conflict, DomainError, NotFound
from yantra_common.events import Envelope
from yantra_common.outbox import emit
from yantra_common.pii import normalise_name, pii_hash
from yantra_contracts.events.v1 import PayoutAccountRejected, PayoutAccountVerified, WorkerErasureCompleted
from yantra_payout.models import OUTBOX, BankAccount, Earning, WorkerAccount
from yantra_payout.rails import Rail, RailError, RailUnavailable, Validation

log = logging.getLogger("yantra.payout.accounts")
BANK_CHANGE_HOLD = timedelta(hours=72)
DAY = timedelta(days=1)


class RailDown(DomainError):
    status = 503
    code = "rail_unavailable"


class TooManyValidations(DomainError):
    status = 429
    code = "validation_limit"


@dataclass(frozen=True)
class AccountIn:
    account_name: str
    account_number: str
    ifsc: str


def number_of(account: BankAccount) -> str:
    """The plain account number, for the rail call or the bank file only. Never logged."""
    plain: bytes = open_sealed(account.account_sealed, account.worker_id.bytes)
    return plain.decode()


def awaiting_confirmation(account: BankAccount) -> bool:
    """A penny drop that came back verified without the bank's registered name proved the account exists, not
    whose it is: finance confirms it before anything is paid into it."""
    return (
        account.status == "verified"
        and account.verification == "penny_drop"
        and account.registered_name_match is None
        and account.confirmed_at is None
    )


def account_view(account: BankAccount | None) -> dict[str, Any] | None:
    """What a worker or finance may read: never the number."""
    if account is None:
        return None
    return {
        "status": account.status,
        "verification": account.verification,
        "account_name": account.account_name,
        "account_last4": account.account_last4,
        "ifsc": account.ifsc,
        "registered_name_match": account.registered_name_match,
        "verified_at": None if account.verified_at is None else account.verified_at.astimezone(UTC).isoformat(),
        "failure_reason": account.failure_reason,
        "awaiting_confirmation": awaiting_confirmation(account),
        "confirmed_at": None if account.confirmed_at is None else account.confirmed_at.astimezone(UTC).isoformat(),
    }


def _holder_account(session: Session, worker_id: uuid.UUID) -> WorkerAccount:
    account = session.get(WorkerAccount, worker_id)
    if account is None:
        account = WorkerAccount(worker_id=worker_id)
        session.add(account)
        session.flush()
    return account


def _count_validation(account: BankAccount, now: datetime, per_day: int) -> None:
    if account.validations_reset_at is None or account.validations_reset_at <= now - DAY:
        account.validations_today, account.validations_reset_at = 0, now
    if account.validations_today >= per_day:
        raise TooManyValidations("too many bank account checks today; try again tomorrow", limit=per_day)
    account.validations_today += 1


def register_account(
    session: Session,
    rail: Rail,
    worker_id: uuid.UUID,
    body: AccountIn,
    now: datetime | None = None,
    validations_per_day: int = 3,
) -> BankAccount:
    """Seal and store the account, register it with the rail and start the penny drop. The same account sent
    again while it is verifying or verified is a no-op; a different one replaces it (and, if the old one was
    verified, holds payouts for 72 hours)."""
    now = now or datetime.now(UTC)
    account_hash = pii_hash(f"{body.ifsc}:{body.account_number}")
    owner = session.scalar(select(BankAccount.worker_id).where(BankAccount.account_hash == account_hash))
    if owner is not None and owner != worker_id:
        raise Conflict("this bank account belongs to another worker").with_code("account_in_use")
    account = session.scalar(select(BankAccount).where(BankAccount.worker_id == worker_id).with_for_update())
    if account is not None and account.account_hash == account_hash and account.status in ("verifying", "verified"):
        return account
    if account is None:
        account = BankAccount(worker_id=worker_id, validations_today=0)
        session.add(account)
    elif account.status == "verified":
        holder = _holder_account(session, worker_id)
        until = now + BANK_CHANGE_HOLD
        if holder.hold_until is None or holder.hold_until < until:
            holder.hold_until, holder.hold_reason = until, "bank_change"
    _count_validation(account, now, validations_per_day)
    sealed = seal(body.account_number.encode(), worker_id.bytes)
    account.account_name, account.account_name_hash = body.account_name, pii_hash(normalise_name(body.account_name))
    account.account_last4, account.ifsc = body.account_number[-4:], body.ifsc
    account.account_sealed, account.key_id, account.account_hash = sealed, key_id_of(sealed), account_hash
    account.status, account.rail, account.failure_reason = "verifying", rail.name, None
    account.verification = "penny_drop" if rail.supports_penny_drop else "none"
    account.registered_name_match, account.verified_at, account.updated_at = None, None, now
    account.confirmed_by = account.confirmed_at = None
    try:
        with session.begin_nested():
            session.flush()
    except IntegrityError as e:  # another worker registered the same number between the check and the write
        raise Conflict("this bank account belongs to another worker").with_code("account_in_use") from e
    try:
        registered = rail.register(worker_id, body.account_name, body.account_number, body.ifsc)
        account.rail_contact_id, account.rail_fund_account_id = registered.contact_id, registered.fund_account_id
        validation = rail.start_validation(registered.fund_account_id, body.account_name, worker_id)
    except RailError as e:
        log.warning("bank account refused by the rail worker_id=%s code=%s", worker_id, e.code)
        _fail(session, account, "rail_error", now)
        return account
    except RailUnavailable as e:
        raise RailDown("the payout rail is unavailable; try again in a few minutes") from e
    account.validation_id = validation.id
    complete_validation(session, account, validation, now)
    return account


def _fail(session: Session, account: BankAccount, reason: str, now: datetime) -> None:
    account.status, account.failure_reason, account.updated_at = "failed", reason, now
    emit(
        session,
        OUTBOX,
        f"account/{account.worker_id}",
        PayoutAccountRejected(worker_id=account.worker_id, reason=reason),
    )
    session.flush()


def complete_validation(
    session: Session, account: BankAccount, validation: Validation, now: datetime | None = None
) -> None:
    """Apply a penny-drop outcome once. A pending outcome changes nothing; a settled account ignores late news."""
    now = now or datetime.now(UTC)
    if account.status != "verifying" or validation.status == "pending":
        return
    if validation.status == "failed":
        _fail(session, account, validation.reason or "invalid_account", now)
        return
    if validation.registered_name is not None:
        account.registered_name_match = normalise_name(validation.registered_name) == normalise_name(
            account.account_name
        )
        if not account.registered_name_match:
            _fail(session, account, "name_mismatch", now)
            return
    account.status, account.verified_at, account.updated_at = "verified", now, now
    emit(
        session,
        OUTBOX,
        f"account/{account.worker_id}",
        PayoutAccountVerified(
            worker_id=account.worker_id,
            account_name_hash=account.account_name_hash,
            account_last4=account.account_last4,
            ifsc=account.ifsc,
            verification="penny_drop" if account.verification == "penny_drop" else "none",
        ),
    )
    session.flush()


def get_account(session: Session, worker_id: uuid.UUID) -> BankAccount:
    account = session.get(BankAccount, worker_id)
    if account is None:
        raise NotFound("no bank account yet", worker_id=str(worker_id))
    return account


def poll_verifying(factory: sessionmaker[Session], rail: Rail, now: datetime | None = None, limit: int = 50) -> int:
    """The backstop for a penny drop whose webhook never came: ask the rail, apply the answer. Returns how many
    accounts settled."""
    with unit_of_work(factory) as session:
        pending = session.execute(
            select(BankAccount.worker_id, BankAccount.validation_id)
            .where(BankAccount.status == "verifying", BankAccount.validation_id.is_not(None))
            .order_by(BankAccount.updated_at)
            .limit(limit)
        ).all()
    settled = 0
    for worker_id, validation_id in pending:
        try:
            validation = rail.fetch_validation(validation_id)
        except (RailError, RailUnavailable) as e:
            log.warning("penny drop lookup failed worker_id=%s error=%s", worker_id, type(e).__name__)
            continue
        with unit_of_work(factory) as session:
            account = session.scalar(select(BankAccount).where(BankAccount.worker_id == worker_id).with_for_update())
            if account is not None and account.validation_id == validation_id:
                before = account.status
                complete_validation(session, account, validation, now)
                settled += int(account.status != before)
    return settled


def verified_fund_account(session: Session, worker_id: uuid.UUID) -> BankAccount | None:
    """The account money may go to now: verified, and confirmed by finance when the penny drop proved no name."""
    account = session.get(BankAccount, worker_id)
    if account is None or account.status != "verified" or awaiting_confirmation(account):
        return None
    return account


def confirm_account(session: Session, worker_id: uuid.UUID, by: uuid.UUID, now: datetime | None = None) -> BankAccount:
    """Finance confirms an account the penny drop could not name. Recorded with who and when; never by the worker
    whose account it is."""
    if by == worker_id:
        raise Conflict("nobody confirms their own bank account").with_code("same_person")
    account = session.scalar(select(BankAccount).where(BankAccount.worker_id == worker_id).with_for_update())
    if account is None:
        raise NotFound("no bank account", worker_id=str(worker_id))
    if not awaiting_confirmation(account):
        raise Conflict("this account is not awaiting confirmation", status=account.status).with_code(
            "not_awaiting_confirmation"
        )
    now = now or datetime.now(UTC)
    account.confirmed_by, account.confirmed_at, account.updated_at = by, now, now
    session.flush()
    log.info("bank account confirmed worker_id=%s by=%s", worker_id, by)
    return account


def erase_when_paid(session: Session, worker_id: uuid.UUID, now: datetime | None = None) -> bool:
    """Delete the worker's bank account (the sealed number with it) once nothing is owed: no earning payable (in no
    window yet, held, or released), windowed (on a line not yet paid) or returned. Until then the account stays to
    pay what is owed and is marked for erasure (`erasures_pending` on finance's attention list). Ledger rows keep
    the worker id (legal retention). Returns True when the account is gone."""
    account = session.scalar(select(BankAccount).where(BankAccount.worker_id == worker_id).with_for_update())
    if account is None:
        return True
    owed = session.scalar(select(Earning.id).where(Earning.worker_id == worker_id, Earning.status != "paid").limit(1))
    if owed is not None:
        if account.erasure_requested_at is None:
            account.erasure_requested_at = now or datetime.now(UTC)
            session.flush()
        return False
    session.delete(account)
    session.flush()
    log.info("bank account erased worker_id=%s", worker_id)
    return True


def on_erasure_completed(session: Session, env: Envelope) -> None:
    """Talent erased the worker's personal data: erase the bank account now, or as soon as the last owed line
    settles."""
    erase_when_paid(session, WorkerErasureCompleted.model_validate(env.data).worker_id, env.occurred_at)


def erase_if_requested(session: Session, worker_id: uuid.UUID) -> None:
    """Called after a line is paid or released: finish an erasure that was waiting on this money."""
    account = session.get(BankAccount, worker_id)
    if account is not None and account.erasure_requested_at is not None:
        erase_when_paid(session, worker_id)
