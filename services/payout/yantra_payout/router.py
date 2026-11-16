"""HTTP surface of the payout module. Workers read their statement and register the bank account they are paid
into; finance closes, approves and pays the window, retries or releases a failed line, handles the bank file and
reconciles; operators read the money pages and hold an account (trust and safety). Odoo's service account holds
`ops`, so every read it needs stays open to operators. The RazorpayX webhook is the one route without a caller:
the gateway forwards it unauthenticated and the HMAC signature over the raw body is checked here."""

import uuid
from datetime import datetime
from decimal import Decimal
from typing import Annotated, Any, Literal, Self

from fastapi import APIRouter, Depends, Header, Query, Request, status
from fastapi.responses import PlainTextResponse
from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, field_serializer, model_validator
from sqlalchemy import select

from yantra_common.deps import DB, Finance, FinanceOrOps, Ops, Roles, Worker, WorkerId, require_any
from yantra_common.errors import Invalid, NotFound
from yantra_common.pii import ACCOUNT_NUMBER, IFSC
from yantra_payout import accounts, paying, service
from yantra_payout.config import PayoutSettings
from yantra_payout.models import (
    JOB_LEASE,
    Adjustment,
    BankAccount,
    PayWindow,
    ReconciliationRun,
    WindowLine,
    WorkerAccount,
)
from yantra_payout.rails import Rail

router = APIRouter(prefix="/v1/payout", tags=["payout"])


class WindowOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    starts_at: datetime
    ends_at: datetime
    currency: str
    status: str
    gross_total: Decimal
    held_total: Decimal
    paid_at: datetime | None
    rail_reference: str | None
    rail: str | None
    paid_total: Decimal
    reconciled_at: datetime | None
    cap_override_by: uuid.UUID | None = None
    cap_override_reason: str | None = None
    cap_override_at: datetime | None = None


class PayIn(BaseModel):
    """Paying a window over the per-window cap takes an explicit override and a reason, both recorded."""

    override_cap: bool = False
    reason: str | None = Field(default=None, max_length=500)

    @model_validator(mode="after")
    def _an_override_says_why(self) -> Self:
        if self.override_cap and not (self.reason or "").strip():
            raise ValueError("reason: overriding the per-window cap needs a reason")
        return self


class LineOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    window_id: uuid.UUID
    worker_id: uuid.UUID
    gross: Decimal
    earning_count: int
    status: str
    hold_reason: str | None
    attempts: int
    rail: str | None
    rail_reference: str | None
    rail_status: str | None
    utr: str | None
    failure_reason: str | None
    submitted_at: datetime | None
    settled_at: datetime | None


WindowStatus = Literal["closed", "approved", "paying", "paid"]


class CloseIn(BaseModel):
    currency: str = Field(pattern=r"^[A-Z]{3}$")
    as_of: AwareDatetime | None = Field(
        default=None, description="close the window that precedes this instant (replays)"
    )


class HoldIn(BaseModel):
    reason: str | None = Field(default=None, max_length=40)
    until: AwareDatetime | None = None


class AccountOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    worker_id: uuid.UUID
    first_paid_at: datetime | None
    hold_until: datetime | None
    hold_reason: str | None


class AdjustmentIn(BaseModel):
    """A bonus or a correction. Always positive: an adjustment adds pay, it never takes any back."""

    worker_id: uuid.UUID
    amount: Decimal = Field(gt=0, max_digits=18, decimal_places=6)
    currency: str = Field(pattern=r"^[A-Z]{3}$")
    kind: Literal["bonus", "correction"]
    reason: str = Field(min_length=1, max_length=500)


class DecideIn(BaseModel):
    note: str | None = Field(default=None, max_length=500)


class AdjustmentOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    worker_id: uuid.UUID
    amount: Decimal
    currency: str
    kind: str
    reason: str
    status: str
    proposed_by: uuid.UUID
    decided_by: uuid.UUID | None
    decision_note: str | None
    created_at: datetime
    decided_at: datetime | None

    @field_serializer("amount")
    def _paisa(self, amount: Decimal) -> str:
        return str(service.money(amount))


AdjustmentStatus = Literal["pending", "approved", "rejected"]
Money = dict[str, str]  # per currency, as a string like every amount


class OpenWindowOut(BaseModel):
    starts_at: datetime
    ends_at: datetime
    closes_in_seconds: int


class WindowCountsOut(BaseModel):
    closed: int
    approved: int
    paying: int
    paid: int


class OverviewOut(BaseModel):
    payable_now: Money
    paid_total: Money
    held_total: Money
    open_window: OpenWindowOut
    windows: WindowCountsOut
    margin_total: Money
    pending_adjustments: int


class TotalsOut(BaseModel):
    payable: str
    paid: str
    held: str
    currency: str


class BankOut(BaseModel):
    status: str
    verification: str
    account_name: str
    account_last4: str
    ifsc: str
    registered_name_match: bool | None
    verified_at: datetime | None
    failure_reason: str | None
    awaiting_confirmation: bool = False  # verified, but the penny drop proved no name: finance confirms first
    confirmed_at: datetime | None = None


class AccountSummaryOut(BaseModel):
    account: AccountOut
    totals: TotalsOut
    bank: BankOut | None = None


class BankAccountIn(BaseModel):
    """The account a worker is paid into. The name must be the name the bank holds for it: letters, spaces and
    . ' - only, so it can never start a spreadsheet formula in the bank file."""

    account_name: str = Field(pattern=r"^[A-Za-z .'-]{2,120}$")
    account_number: str = Field(pattern=ACCOUNT_NUMBER)
    ifsc: str = Field(pattern=IFSC)


class RunOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: uuid.UUID
    window_id: uuid.UUID
    ran_at: datetime
    earnings_total: Decimal
    lines_total: Decimal
    paid_total: Decimal
    rail_total: Decimal
    delta_lines: Decimal
    delta_rail: Decimal
    failed_lines: int
    processing_lines: int
    balanced: bool


def rail(request: Request) -> Rail:
    chosen: Rail = request.app.state.rail
    return chosen


def payout_config(request: Request) -> PayoutSettings:
    config: PayoutSettings = request.app.state.payout_settings
    return config


RailDep = Annotated[Rail, Depends(rail)]
Config = Annotated[PayoutSettings, Depends(payout_config)]
StatementReader = Depends(require_any("worker", "ops", "finance", message="worker or finance role required"))
# whoever earns reads their own statement: a worker, a reviewer (paid per review), an operator walking the flow
Earner = Depends(require_any("worker", "reviewer", "ops", message="worker role required"))


@router.get("/statement", dependencies=[Earner])
def statement(worker_id: WorkerId, session: DB) -> dict[str, Any]:
    return service.statement(session, worker_id)


@router.get("/windows", response_model=list[WindowOut], dependencies=[FinanceOrOps])
def list_windows(session: DB, status: WindowStatus | None = None) -> list[PayWindow]:
    return service.list_windows(session, status)


@router.get("/windows/{window_id}/lines", response_model=list[LineOut], dependencies=[FinanceOrOps])
def window_lines(window_id: uuid.UUID, session: DB) -> list[WindowLine]:
    """What finance bills per worker: the gross per line and whether it was held."""
    return service.window_lines(session, window_id)


@router.get("/windows/{window_id}", response_model=WindowOut, dependencies=[FinanceOrOps])
def get_window(window_id: uuid.UUID, session: DB) -> PayWindow:
    return service.get_window(session, window_id)


@router.post("/windows/close", response_model=WindowOut, status_code=status.HTTP_201_CREATED, dependencies=[Finance])
def close_window(body: CloseIn, session: DB, config: Config) -> PayWindow:
    return service.close_window(session, body.currency, now=body.as_of, max_per_worker=config.payout_max_per_worker)


@router.post("/windows/{window_id}/approve", response_model=WindowOut, dependencies=[Finance])
def approve(window_id: uuid.UUID, worker_id: WorkerId, session: DB) -> PayWindow:
    """The approver is the caller the gateway identified, never a name the client chose."""
    return service.approve_window(session, window_id, str(worker_id))


@router.post("/windows/{window_id}/pay", response_model=WindowOut, dependencies=[Finance])
def pay(
    window_id: uuid.UUID, worker_id: WorkerId, session: DB, chosen: RailDep, config: Config, body: PayIn | None = None
) -> PayWindow:
    """Queue every payable line on the rail; the dispatch job sends them. Over the per-window cap only with
    `{override_cap: true, reason}`; the caller, the reason and the time are recorded on the window."""
    override = body is not None and body.override_cap
    return paying.pay_window(
        session,
        window_id,
        chosen.name,
        config.payout_max_per_window,
        override_by=worker_id if override else None,
        override_reason=body.reason if body is not None and override else None,
    )


@router.post("/windows/{window_id}/lines/{line_id}/retry", response_model=LineOut, dependencies=[Finance])
def retry_line(window_id: uuid.UUID, line_id: uuid.UUID, session: DB, chosen: RailDep) -> WindowLine:
    return paying.retry_line(session, window_id, line_id, chosen.name)


@router.post("/windows/{window_id}/lines/{line_id}/release", response_model=LineOut, dependencies=[Finance])
def release_line(window_id: uuid.UUID, line_id: uuid.UUID, session: DB) -> WindowLine:
    return paying.release_line(session, window_id, line_id)


@router.get(
    "/windows/{window_id}/bank-file",
    response_class=PlainTextResponse,
    dependencies=[Finance],
    responses={200: {"content": {"text/csv": {}}}},
)
def bank_file(window_id: uuid.UUID, session: DB) -> PlainTextResponse:
    """The bank file. Lines left out of it (worker held, account gone or changed since dispatch) go back to the
    queue and are named in `X-Skipped-Lines` as `<line_id>:<reason>`, comma-separated."""
    body, skipped = paying.bank_file(session, window_id)
    headers = {"Content-Disposition": f'attachment; filename="bank-file-{str(window_id)[:8]}.csv"'}
    if skipped:
        headers["X-Skipped-Lines"] = ",".join(f"{s['line_id']}:{s['reason']}" for s in skipped)
    return PlainTextResponse(body, media_type="text/csv", headers=headers)


@router.post("/windows/{window_id}/bank-file/reconcile", dependencies=[Finance])
async def reconcile_bank_file(window_id: uuid.UUID, request: Request, session: DB) -> dict[str, Any]:
    """The bank's return file as `text/csv`: `reference,status,utr,reason`."""
    raw = await request.body()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as e:
        raise Invalid("the return file must be UTF-8 text") from e
    return paying.reconcile_bank_file(session, window_id, text)


@router.get("/windows/{window_id}/reconcile", dependencies=[FinanceOrOps])
def reconcile(window_id: uuid.UUID, session: DB) -> dict[str, Any]:
    """The live numbers, not recorded."""
    return paying.reconcile(session, window_id)


@router.post("/windows/{window_id}/reconcile", dependencies=[Finance])
def reconcile_now(window_id: uuid.UUID, session: DB) -> dict[str, Any]:
    """A recorded run: the first balanced run of a paid window releases its statements."""
    return paying.reconcile(session, window_id, persist=True)


@router.get("/reconciliation-runs", response_model=list[RunOut], dependencies=[FinanceOrOps])
def reconciliation_runs(
    session: DB, window_id: uuid.UUID | None = None, balanced: bool | None = None
) -> list[ReconciliationRun]:
    return paying.list_runs(session, window_id, balanced)


@router.get("/statements/{window_id}/export", dependencies=[StatementReader])
def statement_export(
    window_id: uuid.UUID, worker_id: WorkerId, roles: Roles, session: DB, format: str = "csv"
) -> PlainTextResponse:
    """A window's statement as CSV, once the window reconciled. Workers get their own earnings in it."""
    if format != "csv":
        raise Invalid("only format=csv is offered")
    everyone = not roles.isdisjoint({"finance", "ops"})
    body = paying.statement_export(session, window_id, worker_id, everyone)
    return PlainTextResponse(
        body,
        media_type="text/csv",
        headers={"Content-Disposition": f'attachment; filename="statement-{str(window_id)[:8]}.csv"'},
    )


@router.get("/rail", dependencies=[FinanceOrOps])
def rail_state(session: DB, chosen: RailDep) -> dict[str, Any]:
    leases: dict[str, datetime | None] = {
        name: at for name, at in session.execute(select(JOB_LEASE.c.name, JOB_LEASE.c.last_finished_at))
    }
    return paying.rail_state(session, chosen, leases)


@router.get("/attention", dependencies=[FinanceOrOps])
def attention(session: DB) -> dict[str, Any]:
    return paying.attention(session)


@router.put("/accounts/me", response_model=BankOut, dependencies=[Worker])
def register_bank_account(
    body: BankAccountIn, worker_id: WorkerId, session: DB, chosen: RailDep, config: Config
) -> dict[str, Any]:
    """Register the account the worker is paid into and start the penny drop. The number never comes back."""
    account = accounts.register_account(
        session,
        chosen,
        worker_id,
        accounts.AccountIn(body.account_name.strip(), body.account_number, body.ifsc),
        validations_per_day=config.validations_per_day,
    )
    view = accounts.account_view(account)
    assert view is not None
    return view


@router.get("/accounts/me", response_model=BankOut, dependencies=[Worker])
def my_bank_account(worker_id: WorkerId, session: DB) -> dict[str, Any]:
    view = accounts.account_view(accounts.get_account(session, worker_id))
    assert view is not None
    return view


@router.get("/accounts", dependencies=[FinanceOrOps])
def held_accounts(
    session: DB,
    held: bool = Query(default=True, description="only accounts on a live hold (the one listing offered)"),
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
) -> dict[str, Any]:
    if not held:
        raise Invalid("only held=true is offered")
    return service.held_accounts(session, limit=limit, offset=offset)


@router.post("/webhooks/razorpayx")
async def razorpayx_webhook(
    request: Request,
    session: DB,
    config: Config,
    signature: Annotated[str | None, Header(alias="X-Razorpay-Signature")] = None,
) -> dict[str, Any]:
    """RazorpayX calls this. It exists only when the rail is RazorpayX and a webhook secret is configured (at least
    32 characters, checked at boot). Replays are recognised from the signed body, not the unsigned event-id header."""
    if config.rail != "razorpayx" or config.razorpayx_webhook_secret is None:
        raise NotFound("no webhook on this rail")
    raw = await request.body()
    return paying.ingest_webhook(
        session,
        raw,
        signature,
        config.razorpayx_webhook_secret.get_secret_value(),
        config.webhook_tolerance_seconds,
    )


@router.get("/margin", dependencies=[FinanceOrOps])
def margin(session: DB) -> list[dict[str, Any]]:
    return service.margin_report(session)


@router.put("/accounts/{worker_id}/hold", response_model=AccountOut, dependencies=[Ops])
def hold(worker_id: uuid.UUID, body: HoldIn, caller: WorkerId, session: DB) -> WorkerAccount:
    """Set or lift (`until` null) a hold. Never on the caller's own account (409 `same_person`); a live integrity or
    bank-change hold is never shortened (the response shows the hold that stands)."""
    return service.set_hold(session, worker_id, body.reason, body.until, by=caller)


@router.post("/accounts/{worker_id}/confirm", response_model=BankOut, dependencies=[Finance])
def confirm_account(worker_id: uuid.UUID, caller: WorkerId, session: DB) -> dict[str, Any]:
    """Finance confirms an account whose penny drop proved no registered name; until then nothing is paid into it.
    Who and when are recorded. 409 `same_person` for one's own account, `not_awaiting_confirmation` otherwise."""
    view = accounts.account_view(accounts.confirm_account(session, worker_id, by=caller))
    assert view is not None
    return view


@router.get("/overview", response_model=OverviewOut, dependencies=[FinanceOrOps])
def overview(session: DB) -> OverviewOut:
    return OverviewOut(**service.overview(session))


@router.post(
    "/adjustments", response_model=AdjustmentOut, status_code=status.HTTP_201_CREATED, dependencies=[FinanceOrOps]
)
def propose_adjustment(body: AdjustmentIn, worker_id: WorkerId, session: DB) -> Adjustment:
    """The proposer is the caller the gateway identified; a different caller must decide it."""
    return service.propose_adjustment(
        session, body.worker_id, body.amount, body.currency, body.kind, body.reason, proposed_by=worker_id
    )


@router.get("/adjustments", response_model=list[AdjustmentOut], dependencies=[FinanceOrOps])
def list_adjustments(session: DB, status: AdjustmentStatus | None = None) -> list[Adjustment]:
    return service.list_adjustments(session, status)


@router.post("/adjustments/{adjustment_id}/approve", response_model=AdjustmentOut, dependencies=[Finance])
def approve_adjustment(
    adjustment_id: uuid.UUID, worker_id: WorkerId, session: DB, body: DecideIn | None = None
) -> Adjustment:
    return service.decide_adjustment(session, adjustment_id, worker_id, "approved", body.note if body else None)


@router.post("/adjustments/{adjustment_id}/reject", response_model=AdjustmentOut, dependencies=[Finance])
def reject_adjustment(
    adjustment_id: uuid.UUID, worker_id: WorkerId, session: DB, body: DecideIn | None = None
) -> Adjustment:
    return service.decide_adjustment(session, adjustment_id, worker_id, "rejected", body.note if body else None)


@router.get("/accounts/{worker_id}", response_model=AccountSummaryOut, dependencies=[FinanceOrOps])
def account_summary(worker_id: uuid.UUID, session: DB) -> AccountSummaryOut:
    summary = service.account_summary(session, worker_id)
    bank = accounts.account_view(session.get(BankAccount, worker_id))
    return AccountSummaryOut(**summary, bank=None if bank is None else BankOut(**bank))
