"""Email goes only to an address its owner proved, with a code mailed to it; ticket context is a small bag."""

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import select

from yantra_common.errors import Conflict, Invalid
from yantra_common.events import Envelope
from yantra_notify import service
from yantra_notify.models import Channel, Notification
from yantra_notify.testing import FakeMailer

NOW = datetime.now(UTC)


def accepted(session, worker):
    data = {
        "unit_id": str(uuid.uuid4()),
        "batch_id": str(uuid.uuid4()),
        "submission_id": str(uuid.uuid4()),
        "worker_id": str(worker),
        "reviewer_id": str(uuid.uuid4()),
        "auditor_id": None,
        "rubric_version": "v1",
    }
    env = Envelope(id=uuid.uuid4(), type="quality.verdict.accepted.v1", subject="s", occurred_at=NOW, data=data)
    service.on_verdict_accepted(session, env)


def code_of(mailer: FakeMailer) -> str:
    return mailer.sent[-1][2].split("Your code is ")[1][:6]


def test_an_address_is_used_only_after_its_code_comes_back(session):
    worker = uuid.uuid4()
    channel = service.set_channel(session, worker, "w@example.test", NOW)
    assert (channel.email, channel.pending_email) == (None, "w@example.test")
    assert channel.verify_expires_at == NOW + timedelta(minutes=15) and channel.verify_nonce
    accepted(session, worker)
    session.commit()
    mailer = FakeMailer()
    assert service.deliver_pending(session, mailer) == 0  # unverified: nothing goes
    assert service.send_verifications(session, mailer, now=NOW) == 1
    assert service.send_verifications(session, mailer, now=NOW) == 0  # once
    [(to, subject, body)] = mailer.sent
    code = code_of(mailer)
    assert to == "w@example.test" and subject == "Your Yantra email code" and len(code) == 6 and code.isdigit()
    stored = session.execute(select(Channel.__table__)).one()._mapping
    assert code not in " ".join(str(v) for v in stored.values())  # the code is never stored
    verified = service.verify_channel(session, worker, code, NOW + timedelta(minutes=1))
    assert (verified.email, verified.pending_email, verified.verify_nonce) == ("w@example.test", None, None)
    assert verified.email_verified_at == NOW + timedelta(minutes=1)
    session.commit()
    assert service.deliver_pending(session, mailer) == 1 and mailer.sent[-1][0] == "w@example.test"
    # setting the verified address again changes nothing; a new one waits while the old keeps receiving
    assert service.set_channel(session, worker, "w@example.test").pending_email is None
    changed = service.set_channel(session, worker, "new@example.test", NOW)
    assert (changed.email, changed.pending_email) == ("w@example.test", "new@example.test")
    first_nonce = changed.verify_nonce
    assert service.set_channel(session, worker, "new@example.test", NOW).verify_nonce != first_nonce  # resend


def test_a_wrong_code_counts_a_try_that_survives_the_failed_request(session, factory):
    worker = uuid.uuid4()
    service.set_channel(session, worker, "w@example.test", NOW)
    session.commit()
    mailer = FakeMailer()
    service.send_verifications(session, mailer, now=NOW)
    session.commit()
    right = code_of(mailer)
    wrong = f"{(int(right) + 1) % 1_000_000:06d}"
    for left in range(4, -1, -1):
        with pytest.raises(Invalid) as e:
            service.verify_channel(session, worker, wrong, NOW)
        assert e.value.code == "wrong_code" and e.value.context["attempts_left"] == left
        session.rollback()  # what the request's unit of work does on the 422
    with factory() as other:
        assert other.get(Channel, worker).verify_attempts == 5
    with pytest.raises(Conflict) as e:
        service.verify_channel(session, worker, right, NOW)
    assert e.value.code == "too_many_attempts"


def test_an_expired_or_missing_code_is_refused_and_never_mailed(session):
    worker = uuid.uuid4()
    with pytest.raises(Conflict) as e:
        service.verify_channel(session, worker, "123456", NOW)
    assert e.value.code == "nothing_to_verify"
    service.set_channel(session, worker, "w@example.test", NOW - timedelta(minutes=16))
    mailer = FakeMailer()
    assert service.send_verifications(session, mailer, now=NOW) == 0 and mailer.sent == []
    with pytest.raises(Conflict) as e:
        service.verify_channel(session, worker, "123456", NOW)
    assert e.value.code == "code_expired"
    service.set_channel(session, worker, None)
    channel = session.get(Channel, worker)
    assert (channel.email, channel.pending_email, channel.verify_expires_at) == (None, None, None)


def test_a_failed_code_mail_is_recorded_and_not_retried(session, caplog):
    worker = uuid.uuid4()
    service.set_channel(session, worker, "w@example.test", NOW)
    mailer = FakeMailer()
    mailer.failing = True
    assert service.send_verifications(session, mailer, now=NOW) == 0
    assert session.get(Channel, worker).verify_error == "ConnectionRefusedError"
    assert "verification email failed" in caplog.text
    mailer.failing = False
    assert service.send_verifications(session, mailer, now=NOW) == 0
    service.set_channel(session, worker, "w@example.test", NOW)  # asking again clears it
    assert service.send_verifications(session, mailer, now=NOW) == 1


def test_ticket_context_is_capped_by_keys_and_size(session):
    author = uuid.uuid4()
    ok = {f"k{i}": "x" for i in range(service.CONTEXT_MAX_KEYS)}
    assert service.create_ticket(session, author, "bug", "t", "b", None, ok).context == ok
    for bad in ({f"k{i}": 1 for i in range(service.CONTEXT_MAX_KEYS + 1)}, {"blob": "x" * service.CONTEXT_MAX_BYTES}):
        with pytest.raises(Invalid) as e:
            service.create_ticket(session, author, "bug", "t", "b", None, bad)
        assert e.value.code == "too_large" and e.value.status == 422
    assert session.scalar(select(Notification.id)) is None
