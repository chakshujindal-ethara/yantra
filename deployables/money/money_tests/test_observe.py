"""The money probe: lines by status in windows not yet paid, the last close, and each window's latest
reconciliation delta (an older unbalanced run no longer counts once a newer one balances)."""

import uuid
from datetime import UTC, datetime, timedelta
from decimal import Decimal

from prometheus_client import REGISTRY

from yantra_money.observe import OBSERVERS, observe_reconciliation, observe_windows
from yantra_payout.models import PayWindow, ReconciliationRun, WindowLine

NOW = datetime(2026, 11, 4, 12, 0, tzinfo=UTC)


def value(name: str, **labels: str) -> float:
    return REGISTRY.get_sample_value(name, labels) or 0.0


def window(s, ends: datetime, status: str) -> PayWindow:
    w = PayWindow(starts_at=ends - timedelta(days=7), ends_at=ends, currency="INR", status=status, closed_at=ends)
    s.add(w)
    s.flush()
    return w


def run(s, w: PayWindow, at: datetime, delta_lines: str, delta_rail: str) -> None:
    zero = Decimal("0")
    s.add(
        ReconciliationRun(
            window_id=w.id,
            ran_at=at,
            earnings_total=zero,
            lines_total=zero,
            paid_total=zero,
            rail_total=zero,
            delta_lines=Decimal(delta_lines),
            delta_rail=Decimal(delta_rail),
            failed_lines=0,
            processing_lines=0,
            balanced=delta_lines == delta_rail == "0",
        )
    )


def test_lines_of_open_windows_by_status_and_the_last_close(factory):
    with factory() as s:
        observe_windows(s, NOW)
        assert value("yantra_window_lines", status="failed") == 0
        assert value("yantra_pay_window_last_closed_timestamp") == 0
        open_w = window(s, NOW - timedelta(days=1), "paying")
        paid_w = window(s, NOW - timedelta(days=8), "paid")
        for w, status in ((open_w, "paid"), (open_w, "failed"), (open_w, "failed"), (paid_w, "paid")):
            s.add(
                WindowLine(window_id=w.id, worker_id=uuid.uuid4(), gross=Decimal("10"), earning_count=1, status=status)
            )
        s.commit()
        observe_windows(s, NOW)
    assert value("yantra_window_lines", status="failed") == 2
    assert value("yantra_window_lines", status="paid") == 1  # the paid window's line is history
    assert value("yantra_window_lines", status="queued") == 0
    assert value("yantra_pay_window_last_closed_timestamp") == (NOW - timedelta(days=1)).timestamp()


def test_only_each_windows_latest_run_counts_toward_the_delta(factory):
    with factory() as s:
        observe_reconciliation(s, NOW)
        assert value("yantra_pay_window_reconciliation_delta") == 0
        a = window(s, NOW - timedelta(days=1), "paid")
        b = window(s, NOW - timedelta(days=8), "paid")
        run(s, a, NOW - timedelta(hours=2), "5.00", "1.00")
        run(s, a, NOW - timedelta(hours=1), "0", "0")  # fixed since
        run(s, b, NOW - timedelta(hours=1), "-2.50", "0.50")
        s.commit()
        observe_reconciliation(s, NOW)
    assert value("yantra_pay_window_reconciliation_delta") == 3.0
    assert OBSERVERS == [observe_windows, observe_reconciliation]
