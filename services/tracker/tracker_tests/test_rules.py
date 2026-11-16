from datetime import UTC, datetime
from decimal import Decimal

from yantra_common.pii import pii_hash
from yantra_tracker import service


def test_the_week_is_monday_to_monday_in_ist():
    # Sunday 23:00 IST is still the old week; Monday 00:00 IST starts the new one
    sunday_late = datetime(2026, 11, 8, 17, 30, tzinfo=UTC)
    starts, ends = service.week_bounds(sunday_late)
    assert starts == datetime(2026, 11, 1, 18, 30, tzinfo=UTC) and ends == datetime(2026, 11, 8, 18, 30, tzinfo=UTC)
    monday = datetime(2026, 11, 8, 18, 30, tzinfo=UTC)  # Monday 9 Nov, 00:00 IST
    assert service.week_bounds(monday)[0] == monday


def test_a_sample_lands_in_its_thirty_second_bucket():
    assert service.bucket(datetime(2026, 11, 4, 4, 30, 29, 999, tzinfo=UTC)) == datetime(2026, 11, 4, 4, 30, tzinfo=UTC)
    assert service.bucket(datetime(2026, 11, 4, 4, 30, 30, tzinfo=UTC)) == datetime(2026, 11, 4, 4, 30, 30, tzinfo=UTC)


def test_only_the_web_label_is_kept_in_the_clear():
    assert service.stored_label(None) is None
    assert service.stored_label("yantra-web") == "yantra-web"
    assert service.stored_label("Chrome - Inbox") == pii_hash("Chrome - Inbox")


def test_over_cap_is_strictly_more_than_the_cap():
    assert not service.over_cap(3600, Decimal("1"))
    assert service.over_cap(3601, Decimal("1"))


def test_the_policy_names_what_is_and_is_not_collected():
    p = service.policy(30, 40)
    assert p.retention_days == 30 and p.default_cap_hours == 40 and p.sample_seconds == 30
    text = " ".join(" ".join(s.paragraphs + s.bullets) for s in p.sections)
    assert "Keystrokes" in text and "40 hours" in text and "30 days" in text
