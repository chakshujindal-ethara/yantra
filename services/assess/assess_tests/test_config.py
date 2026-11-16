"""The assess settings' boot guards, the engine they select, and the fake engine's own rules."""

import uuid

import pytest
from pydantic import ValidationError

from yantra_assess.config import LOCAL_CLIENT_SECRET, AssessSettings
from yantra_assess.engine import EngineError, select_engine
from yantra_assess.engine.fake import FakeEngine
from yantra_assess.engine.v2 import V2Engine
from yantra_assess.service import paper_stats
from yantra_assess.testing import make_paper, sit


def test_v2_needs_its_client_secret_and_selects_the_http_engine(monkeypatch):
    monkeypatch.delenv("YANTRA_ENV", raising=False)
    with pytest.raises(ValidationError, match="CLIENT_SECRET"):
        AssessSettings(engine="v2")
    engine = select_engine(AssessSettings(engine="v2", client_secret="s", odoo_url="http://o/"))
    assert isinstance(engine, V2Engine) and engine.odoo_url == "http://o"
    assert isinstance(select_engine(AssessSettings()), FakeEngine)


def test_outside_local_the_fake_engine_and_the_rigs_secret_are_refused(monkeypatch):
    monkeypatch.setenv("YANTRA_ENV", "staging")
    with pytest.raises(ValidationError, match="refuses YANTRA_ASSESS_ENGINE=fake"):
        AssessSettings()
    with pytest.raises(ValidationError, match="refuses the rig"):
        AssessSettings(engine="v2", client_secret=LOCAL_CLIENT_SECRET)
    assert AssessSettings(engine="v2", client_secret="a-real-one").engine == "v2"


def test_the_fake_engine_keeps_v2s_rules(fake):
    aid = fake.add_assessment()
    with pytest.raises(EngineError) as e:
        fake.launch(aid)
    assert e.value.code == "launch_blocked"
    person = fake.ensure_person("s", "", False, "", "worker")
    fake.assign(aid, [person.user_id])
    fake.launch(aid)
    with pytest.raises(EngineError):
        fake.launch(aid)
    fake.assign(aid, [person.user_id])  # already on it: nothing new
    assert len(fake.attempts_since(None)[0]) == 1
    fake.close(aid)
    with pytest.raises(EngineError) as e:
        fake.assign(aid, [person.user_id])
    assert e.value.code == "assessment_closed"
    with pytest.raises(EngineError) as e:
        fake.ticket("nobody", "worker", "http://x")
    assert e.value.code == "unknown_person"
    other = fake.add_assessment()
    with pytest.raises(EngineError) as e:
        fake.ticket("s", "worker", "http://x", assessment_id=other)
    assert e.value.code == "not_assigned"
    with pytest.raises(EngineError):
        fake.release(other)


def test_the_fake_engine_releases_only_what_it_was_asked(fake):
    aid = fake.add_assessment()
    people = [fake.ensure_person(f"s{i}", "", False, "", "worker").user_id for i in range(2)]
    fake.assign(aid, people)
    fake.launch(aid)
    first, second = (a.id for a in fake.attempts_since(None)[0])
    fake.submit(first)
    fake.submit(second)
    assert fake.release(aid, [second]) == 1
    assert fake.attempt(second).released and not fake.attempt(first).released
    fake.unassign(aid, [fake.ensure_person("s0", "", False, "", "worker").applicant_id])
    assert fake.attempt(first).state == "submitted", "a started attempt is never taken back"


def test_held_sittings_are_counted_apart_from_those_being_scored(session, fake):
    paper = make_paper(session, fake, release_policy="manual")
    sit(session, fake, paper, uuid.uuid4())
    sit(session, fake, paper, uuid.uuid4(), result="pending")
    stats = paper_stats(session, [paper.id])[paper.id]
    assert (stats["awaiting_result"], stats["held"]) == (2, 1)
