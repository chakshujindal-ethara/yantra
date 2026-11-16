"""The onboarding checklist: six steps in any order, idempotent redo, the PAN stored only as a keyed hash + last four,
one PAN per person, the bank step completed by payout's verification when the names match, consent versions and
withdrawal, `worker.eligible.v1` once."""

import hashlib
import hmac
import uuid
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import select

from yantra_common.config import LOCAL_PII_KEY, pii_settings
from yantra_common.errors import Conflict, Invalid
from yantra_common.events import Envelope
from yantra_common.pii import normalise_name, pii_hash
from yantra_talent.consumers import on_account_verified
from yantra_talent.models import OUTBOX, Onboarding
from yantra_talent.schemas import AgreementIn, ConsentIn, IdentityIn, ProfileIn
from yantra_talent.service import (
    list_onboarding,
    onboarding_out,
    set_agreement,
    set_consent,
    set_identity,
    set_payout_ack,
    set_profile,
)

NOW = datetime.now(UTC)
PROFILE = ProfileIn(legal_name="Asha  Rani", phone="9876543210", city="Pune")
IDENTITY = IdentityIn(pan=" abcde1234f ", aadhaar_last4="4321")
AGREE = AgreementIn(accepted=True, version="2026-11")
CONSENT = ConsentIn(accepted=True)


def events(session, kind=None):
    rows = [dict(r._mapping) for r in session.execute(select(OUTBOX).order_by(OUTBOX.c.occurred_at))]
    return [r for r in rows if kind is None or r["type"] == kind]


def verified(session, worker, account_name="asha rani", at=NOW):
    """payout.account.verified.v1 as payout emits it."""
    env = Envelope(
        id=uuid.uuid4(),
        type="payout.account.verified.v1",
        subject=str(worker),
        occurred_at=at,
        data={
            "worker_id": str(worker),
            "account_name_hash": pii_hash(normalise_name(account_name)),
            "account_last4": "9012",
            "ifsc": "HDFC0001234",
            "verification": "penny_drop",
        },
    )
    on_account_verified(session, env)
    return session.get(Onboarding, worker)


def complete(session, worker, now=NOW):
    set_profile(session, worker, PROFILE, now)
    set_agreement(session, worker, AGREE, now)
    set_consent(session, worker, CONSENT, now)
    set_identity(session, worker, IDENTITY, now)
    verified(session, worker, at=now)
    return set_payout_ack(session, worker, now)


def test_the_checklist_starts_empty_and_groups_its_steps(session, worker):
    out = onboarding_out(session.get(Onboarding, worker))
    assert out.complete is False and out.eligible_sent_at is None
    assert [(s.key, s.status, s.done_at, s.group) for s in out.steps] == [
        ("profile", "pending", None, "Profile"),
        ("agreement", "pending", None, "Documents"),
        ("consent", "pending", None, "Documents"),
        ("identity", "pending", None, "Identity"),
        ("bank", "pending", None, "Payment"),
        ("payout_ack", "pending", None, "Payment"),
    ]
    row = set_consent(session, worker, CONSENT, NOW)
    session.commit()
    out = onboarding_out(row)
    assert out.steps[2].model_dump() == {"key": "consent", "status": "done", "done_at": NOW, "group": "Documents"}
    assert row.consent_at == NOW and out.complete is False


def test_the_pii_hash_is_keyed_so_a_digest_beside_the_last_four_cannot_be_brute_forced(monkeypatch):
    assert pii_hash("ABCDE1234F") == hmac.new(LOCAL_PII_KEY.encode(), b"ABCDE1234F", hashlib.sha256).hexdigest()
    assert pii_hash("ABCDE1234F") != hashlib.sha256(b"ABCDE1234F").hexdigest()
    monkeypatch.setenv("YANTRA_PII_KEY", "another-key")
    pii_settings.cache_clear()
    try:
        assert pii_hash("ABCDE1234F") == hmac.new(b"another-key", b"ABCDE1234F", hashlib.sha256).hexdigest()
    finally:
        pii_settings.cache_clear()


def test_identity_stores_hash_and_last_four_only_and_locks_the_pan(session, worker):
    row = set_identity(session, worker, IDENTITY, NOW)
    session.commit()
    assert row.pan_hash == pii_hash("ABCDE1234F") and row.pan_last4 == "234F" and row.aadhaar_last4 == "4321"
    assert not any("ABCDE1234F" in str(v) for v in vars(row).values())
    assert (
        set_identity(session, worker, IdentityIn(pan="abcde1234f", aadhaar_last4="9999"), NOW).aadhaar_last4 == "9999"
    )
    with pytest.raises(Conflict) as e:
        set_identity(session, worker, IdentityIn(pan="ZZZZZ9999Z", aadhaar_last4="1111"), NOW)
    assert e.value.code == "pan_locked"
    with pytest.raises(Invalid, match="pan"):
        set_identity(session, worker, IdentityIn(pan="ABC1234567", aadhaar_last4="1111"), NOW)
    with pytest.raises(Conflict) as e:
        set_identity(session, uuid.uuid4(), IDENTITY, NOW)
    assert e.value.code == "pan_in_use"


def test_the_bank_step_completes_when_payout_verifies_an_account_in_the_legal_name(session, worker):
    row = verified(session, worker)  # before the profile: kept, step pending
    assert "bank" not in row.steps and row.account_name_hash == pii_hash("asha rani") and row.account_verified_at == NOW
    row = set_profile(session, worker, PROFILE, NOW)  # the profile name matches: both steps done
    session.commit()
    assert {"profile", "bank"} <= set(row.steps)
    assert not hasattr(row, "ifsc") and not hasattr(row, "bank_account_last4") and not hasattr(row, "account_name")
    with pytest.raises(Invalid) as e:  # once done, the legal name cannot drift from the account name
        set_profile(session, worker, ProfileIn(legal_name="Someone Else", phone="9876543210", city="Pune"), NOW)
    assert e.value.code == "name_mismatch"
    assert (
        set_profile(session, worker, ProfileIn(legal_name="ASHA RANI", phone="9876543211", city="Goa"), NOW).city
        == "Goa"
    )
    assert normalise_name("  Asha   RANI ") == "asha rani"


def test_an_account_in_another_name_leaves_the_step_pending_until_the_profile_matches(session, worker, caplog):
    set_profile(session, worker, PROFILE, NOW)
    row = verified(session, worker, account_name="A Rani")
    assert "bank" not in row.steps and "does not match" in caplog.text and "Rani" not in caplog.text
    row = set_profile(session, worker, ProfileIn(legal_name="A Rani", phone="9876543210", city="Pune"), NOW)
    assert "bank" in row.steps
    row = verified(session, worker)  # a new account in the old legal name: stored, the done step stays done
    assert "bank" in row.steps


def test_the_agreement_and_consent_versions_must_be_current(session, worker):
    with pytest.raises(Invalid) as e:
        set_agreement(session, worker, AgreementIn(accepted=True, version="2025-01"), NOW)
    assert e.value.code == "policy_outdated" and e.value.context["latest"] == "2026-11"
    with pytest.raises(Invalid) as e:
        set_consent(session, worker, ConsentIn(accepted=True, version="old"), NOW)
    assert e.value.code == "policy_outdated"
    row = set_consent(session, worker, ConsentIn(accepted=True, version="2026-11"), NOW)
    assert row.consent_version == "2026-11" and onboarding_out(row).consent_version == "2026-11"


def test_withdrawing_consent_reopens_the_step_and_is_announced_once(session, worker):
    row = set_consent(session, worker, ConsentIn(accepted=False), NOW)  # nothing given yet: nothing to announce
    assert events(session, "worker.consent.withdrawn.v1") == []
    set_consent(session, worker, CONSENT, NOW)
    row = set_consent(session, worker, ConsentIn(accepted=False), NOW)
    session.commit()
    assert "consent" not in row.steps and row.consent_at is None and row.consent_version is None
    sent = events(session, "worker.consent.withdrawn.v1")
    assert len(sent) == 1 and sent[0]["payload"] == {"worker_id": str(worker)}


def test_consent_given_is_announced_when_there_was_none_and_a_withdrawal_ends_eligibility(session, worker):
    row = complete(session, worker)
    assert row.eligible_sent_at is not None and len(events(session, "worker.eligible.v1")) == 1
    assert len(events(session, "worker.consent.given.v1")) == 1
    set_consent(session, worker, CONSENT, NOW)  # given again while given: nothing new to announce
    assert len(events(session, "worker.consent.given.v1")) == 1
    row = set_consent(session, worker, ConsentIn(accepted=False), NOW)
    out = onboarding_out(row)
    assert row.eligible_sent_at is None and out.complete is False and out.eligible_sent_at is None
    row = set_consent(session, worker, CONSENT, NOW + timedelta(minutes=1))
    session.commit()
    given = events(session, "worker.consent.given.v1")
    assert len(given) == 2 and given[-1]["payload"] == {"worker_id": str(worker)}
    assert row.eligible_sent_at == NOW + timedelta(minutes=1) and len(events(session, "worker.eligible.v1")) == 2


def test_bodies_validate_the_indian_formats():
    for bad in ("1234567890", "98765", "+919876543210"):
        with pytest.raises(ValueError):
            ProfileIn(legal_name="a", phone=bad, city="c")
    with pytest.raises(ValueError):
        AgreementIn(accepted=True, version="")
    with pytest.raises(ValueError):
        AgreementIn(accepted=False, version="v1")
    with pytest.raises(ValueError):
        IdentityIn(pan="ABCDE1234F", aadhaar_last4="12a4")


def test_the_last_step_emits_worker_eligible_once(session, worker):
    row = complete(session, worker)
    session.commit()
    out = onboarding_out(row)
    assert out.complete is True and out.eligible_sent_at == NOW and row.eligible_sent_at == NOW
    sent = events(session, "worker.eligible.v1")
    assert len(sent) == 1 and sent[0]["subject"] == str(worker)
    assert sent[0]["payload"] == {
        "worker_id": str(worker),
        "legal_name_hash": pii_hash("asha rani"),
        "pan_last4": "234F",
    }
    later = NOW + timedelta(days=1)
    redone = set_agreement(session, worker, AGREE, later)
    session.commit()
    assert redone.eligible_sent_at == NOW and len(events(session, "worker.eligible.v1")) == 1
    assert onboarding_out(redone).steps[1].done_at == later


def test_ops_list_filters_complete_and_incomplete(session):
    done, half = uuid.uuid4(), uuid.uuid4()
    complete(session, done)
    set_profile(session, half, PROFILE, NOW)
    set_payout_ack(session, half, NOW)
    session.commit()
    rows = {r.worker_id: r for r in list_onboarding(session, None)}
    assert (rows[done].complete, rows[done].steps_done) == (True, 6)
    assert (rows[half].complete, rows[half].steps_done) == (False, 2) and rows[half].updated_at is not None
    assert [r.worker_id for r in list_onboarding(session, "complete")] == [done]
    assert [r.worker_id for r in list_onboarding(session, "incomplete")] == [half]
