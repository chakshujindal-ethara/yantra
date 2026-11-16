"""The v2 client against a stand-in of Odoo (v2's `/api/v1` routes and the bridge's `/api/v1/yantra/service/*`) and
Keycloak: request shapes, the two tokens and their caching, a 401 re-mint, retries on reads only, the envelope. Where
a response matters to Yantra the stand-in serves one recorded from the real v2 (`fixtures/v2/`, see its README)."""

import base64
import csv
import io
import json
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from pathlib import Path
from typing import Any

import httpx
import pytest

from yantra_assess.engine import EngineError, EngineUnavailable, QuickQuestion
from yantra_assess.engine.v2 import V2Engine, quick_csv, to_assessment, to_attempt

ODOO = "http://odoo.test"
TOKEN_URL = "http://kc.test/realms/yantra/protocol/openid-connect/token"
NOW = datetime(2026, 11, 12, 10, 0, tzinfo=UTC)
FIXTURES = Path(__file__).parent / "fixtures" / "v2"


def recorded(name: str) -> Any:
    return json.loads((FIXTURES / f"{name}.json").read_text())


def replay(name: str, status: int = 200) -> httpx.Response:
    """A response v2 really gave (`fixtures/v2/<name>.json`)."""
    return httpx.Response(status, json=recorded(name))


DETAIL = {
    "id": 7,
    "name": "Hindi basics",
    "state": "draft",
    "duration_minutes": 30,
    "pass_threshold": 60.0,
    "question_limit": 0,
    "questions_available": 9,
    "generator": {"id": 3, "name": "SOP"},
    "questions": [{"id": 11, "question_type": "mcq"}, {"id": 12, "question_type": "transcription"}],
    "pool": [{"id": 11}, {"id": 12}, {"id": 13}],
    "rules": {"webcam": True, "ai_proctor": True, "tab_switch": True, "seb": False},
    "max_violations": 5,
    "violation_action": "log_only",
    "shuffle_questions": True,
    "subjective_threshold": 0.0,
}
ATTEMPT = {
    "id": 501,
    "assessment_id": 7,
    "state": "submitted",
    "result": "pass",
    "results_released": False,
    "score_percent": 80.0,
    "deadline": "2026-11-12T10:30:00Z",
    "started_at": "2026-11-12T10:00:00",
    "submitted_at": None,
    "subjective": {"max": 0, "state": "pending"},
    "flags": {"integrity_alert": False, "violation_limit_breached": True},
}


class Odoo:
    """A scriptable stand-in: `faults[path]` is a list of responses served before the real answer."""

    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []
        self.faults: dict[str, list[Any]] = {}
        self.kc_tokens = 0
        self.odoo_tokens = 0
        self.attempt_pages = [[ATTEMPT], [dict(ATTEMPT, id=502, state="pending")]]

    def ok(self, data: Any = None, **extra: Any) -> httpx.Response:
        return httpx.Response(200, json={"ok": True, "data": data, **extra})

    def handle(self, r: httpx.Request) -> httpx.Response:
        self.requests.append(r)
        path = r.url.path
        for fault in self.faults.get(path, [])[:1]:
            self.faults[path].pop(0)
            if isinstance(fault, Exception):
                raise fault
            return fault
        if str(r.url) == TOKEN_URL:
            self.kc_tokens += 1
            form = dict(x.split("=", 1) for x in r.content.decode().split("&"))
            assert form["grant_type"] == "client_credentials" and form["client_id"] == "yantra-assess"
            return httpx.Response(200, json={"access_token": f"kc-{self.kc_tokens}", "expires_in": 300})
        body = json.loads(r.content or b"{}")
        auth = r.headers["Authorization"]
        if path.startswith("/api/v1/yantra/service/"):
            assert auth.startswith("Bearer kc-"), "the bridge is signed with the Keycloak client token"
        else:
            assert auth.startswith("Bearer odoo-"), "v2 is signed with the service user's v2 token"
        if path == "/api/v1/yantra/service/token":
            self.odoo_tokens += 1
            expires = (NOW + timedelta(minutes=15)).isoformat()
            return self.ok({"access_token": f"odoo-{self.odoo_tokens}", "expires_at": expires})
        if path == "/api/v1/yantra/service/people":
            assert body["kind"] in ("worker", "staff") and "sub" in body
            return self.ok({"user_id": 40, "applicant_id": 90 if body["kind"] == "worker" else None})
        if path == "/api/v1/yantra/service/tickets":
            assert body["kind"] in ("candidate", "staff"), "the bridge's ticket kinds"
            return self.ok(
                {
                    "ticket": "t",
                    "launch_url": "http://exam.test/yantra/launch#ticket=t",
                    "expires_at": "2026-11-12T10:02:00Z",
                    "evaluator_id": 501 if body.get("assessment_id") else None,
                    "attempt_state": "pending" if body.get("assessment_id") else None,
                }
            )
        if path == "/api/v1/assessments":
            offset = body.get("offset", 0)
            rows = [dict(DETAIL, id=7 + offset)] if offset < 2 else []
            return self.ok(rows, meta={"total": 2, "has_more": offset + 1 < 2})
        if path == "/api/v1/assessments/7":
            return self.ok(DETAIL)
        if path == "/api/v1/bank/import":
            return replay("bank-import")
        if path == "/api/v1/generators/1/approve_all":
            return replay("approve-all")
        if path == "/api/v1/assessments/create":
            return replay("assessment-create")
        if path == "/api/v1/assessments/7/launch":
            if body.get("confirm"):
                return replay("launch")
            return self.ok({"gates": recorded("launch-no-candidates")["gates"], "can_launch": False, "dry_run": True})
        if path == "/api/v1/assessments/7/assign":
            if body.get("user_ids") == [667]:
                return replay("assign-after-done", 409)
            if body.get("user_ids") == [666]:
                skipped = [{"name": "P", "email": "p@x", "reason": "a portal account"}]
                return self.ok(dict(recorded("assign-draft")["data"], skipped=skipped))
            return replay("assign-after-launch" if body.get("user_ids") == [41] else "assign-draft")
        if path in ("/api/v1/assessments/7/close",):
            return self.ok({})
        if path == "/api/v1/assessments/7/release":
            return replay("release-one" if "evaluator_ids" in body else "release")
        if path == "/api/v1/attempts":
            page = self.attempt_pages[body.get("offset", 0)] if body.get("offset", 0) < 2 else []
            return self.ok(page, meta={"server_time": "2026-11-12T09:59:00Z", "has_more": body.get("offset", 0) == 0})
        return httpx.Response(404, json={"ok": False, "error": {"code": "not_found", "message": "no route"}})


@pytest.fixture
def odoo() -> Odoo:
    return Odoo()


def make(odoo: Odoo, **kw: Any) -> V2Engine:
    return V2Engine(
        odoo_url=ODOO + "/",
        token_url=TOKEN_URL,
        client_id="yantra-assess",
        client_secret="s",
        client=httpx.Client(transport=httpx.MockTransport(odoo.handle)),
        sleep=lambda s: None,
        clock=lambda: NOW,
        **kw,
    )


def test_people_and_tickets_go_through_the_bridge(odoo):
    v2 = make(odoo)
    person = v2.ensure_person("sub-1", "w@yantra.local", True, "W", "worker")
    assert (person.user_id, person.applicant_id) == (40, 90)
    assert v2.ensure_person("sub-2", "", False, "", "staff").applicant_id is None
    ticket = v2.ticket("sub-1", "worker", "http://app.test/back", assessment_id=7)
    assert ticket.evaluator_id == 501 and ticket.attempt_state == "pending"
    assert ticket.expires_at == datetime(2026, 11, 12, 10, 2, tzinfo=UTC)
    staff = v2.ticket("sub-2", "staff", "http://app.test/ops", exam_token="e", next_path="/x")
    assert staff.evaluator_id is None and staff.attempt_state is None
    worker_ticket = json.loads(next(r for r in odoo.requests if r.url.path.endswith("/tickets")).content)
    assert worker_ticket["kind"] == "candidate", "a worker sits as a v2 candidate"
    sent = json.loads(odoo.requests[-1].content)
    assert sent == {
        "sub": "sub-2",
        "kind": "staff",
        "return_url": "http://app.test/ops",
        "exam_token": "e",
        "next": "/x",
    }
    assert odoo.kc_tokens == 1, "the Keycloak token is cached"


def test_v2_calls_use_the_service_users_token_minted_once(odoo):
    v2 = make(odoo)
    a = v2.assessment(7)
    assert (a.name, a.question_count, a.question_types, a.generator_id) == (
        "Hindi basics",
        2,
        ["mcq", "transcription"],
        3,
    )
    assert a.rules["ai_proctor"] and a.snapshot()["question_count"] == 2
    v2.assessment(7)
    assert odoo.odoo_tokens == 1


def test_lists_page_through_the_engine(odoo):
    v2 = make(odoo)
    assert [a.id for a in v2.assessments("draft")] == [7, 8]
    assert json.loads(odoo.requests[-1].content)["state"] == "draft"
    attempts, server_time = v2.attempts_since(NOW)
    assert [a.id for a in attempts] == [501, 502] and server_time == datetime(2026, 11, 12, 9, 59, tzinfo=UTC)
    first = json.loads(next(r for r in odoo.requests if r.url.path == "/api/v1/attempts").content)
    assert first["changed_since"] == "2026-11-12T10:00:00Z"
    a = attempts[0]
    assert (a.result, a.released, a.violation_limit_breached, a.started_at.tzinfo) == ("pass", False, True, UTC)


def test_an_empty_page_ends_a_list(odoo):
    v2 = make(odoo)
    odoo.attempt_pages = [[], []]
    rows, server_time = v2.attempts_since(None)
    assert rows == [] and "changed_since" not in json.loads(odoo.requests[-1].content)
    odoo.faults["/api/v1/attempts"] = [httpx.Response(200, json={"ok": True, "data": [], "meta": {}})]
    rows, server_time = v2.attempts_since(None)
    assert rows == [] and server_time == NOW


def test_a_quick_paper_is_a_csv_import_an_approval_and_an_assessment(odoo):
    v2 = make(odoo)
    questions = [
        QuickQuestion("q1", "2+2?", "single", ["3", "4"], "4"),
        QuickQuestion("q2", "Even?", "multi", ["1", "2", "4"], ["2", "4"]),
    ]
    assert v2.create_quick("Hindi", 30, Decimal("0.75"), questions) == 1
    paths = [r.url.path for r in odoo.requests if r.url.path.startswith("/api/v1/") and "yantra" not in r.url.path]
    assert paths == ["/api/v1/bank/import", "/api/v1/generators/1/approve_all", "/api/v1/assessments/create"]
    imported = json.loads(next(r for r in odoo.requests if r.url.path == "/api/v1/bank/import").content)
    assert (imported["filename"], imported["generator_name"]) == ("quick.csv", "Yantra quick: Hindi")
    rows = list(csv.DictReader(io.StringIO(base64.b64decode(imported["content"]).decode())))
    assert [(r["question_type"], r["options"], r["correct_answer"]) for r in rows] == [
        ("mcq", "3|4", "4"),
        ("msq", "1|2|4", "2|4"),
    ]
    created = json.loads(odoo.requests[-1].content)
    assert created["pass_threshold"] == 75.0 and created["generator_id"] == 1
    assert created["results_release"] == "manual" and created["llm_auto_score"] is False


def test_a_quick_paper_whose_questions_were_held_is_refused(odoo):
    v2 = make(odoo)
    held = recorded("approve-all")
    held["data"]["approved_count"] = 1
    odoo.faults["/api/v1/generators/1/approve_all"] = [httpx.Response(200, json=held)]
    questions = [
        QuickQuestion("q1", "?", "single", ["a", "b"], "a"),
        QuickQuestion("q2", "?", "single", ["a", "b"], "b"),
    ]
    with pytest.raises(EngineError) as e:
        v2.create_quick("Hindi", 30, Decimal("0.75"), questions)
    assert e.value.code == "questions_held"
    assert not any(r.url.path == "/api/v1/assessments/create" for r in odoo.requests)


def test_a_clone_copies_the_rules_and_policy_and_redraws_a_random_subset(odoo):
    v2 = make(odoo)
    assert v2.clone(7, "Hindi (attempt 2)") == 1
    body = json.loads(odoo.requests[-1].content)
    assert body["name"] == "Hindi (attempt 2)" and body["generator_id"] == 3 and body["question_ids"] == [11, 12]
    assert body["rule_webcam"] and body["rule_ai_proctor"] and body["rule_require_seb"] is False
    assert body["max_violations"] == 5 and "question_limit" not in body
    odoo.faults["/api/v1/assessments/7"] = [
        httpx.Response(200, json={"ok": True, "data": dict(DETAIL, question_limit=2)})
    ]
    v2.clone(7, "drawn")
    body = json.loads(odoo.requests[-1].content)
    assert body["question_limit"] == 2 and "question_ids" not in body, "2 of a pool of 3 were drawn: draw again"
    odoo.faults["/api/v1/assessments/7"] = [
        httpx.Response(200, json={"ok": True, "data": dict(DETAIL, generator=None, questions=[], question_limit=4)})
    ]
    v2.clone(7, "bare")
    body = json.loads(odoo.requests[-1].content)
    assert "generator_id" not in body and "question_ids" not in body and body["question_limit"] == 4


def test_roster_launch_close_and_release(odoo):
    v2 = make(odoo)
    gates = v2.launch_gates(7)
    assert [g.code for g in gates if not g.passed] == ["candidates"]
    assert json.loads(odoo.requests[-1].content) == {}, "a launch without confirm is v2's dry run"
    v2.assign(7, [40])
    v2.assign(7, [41])
    for user, code in ((666, "not_provisioned"), (667, "assessment_closed")):
        with pytest.raises(EngineError) as e:
            v2.assign(7, [user])
        assert e.value.code == code
    v2.launch(7)
    assert json.loads(odoo.requests[-1].content) == {"confirm": True}
    v2.unassign(7, [90])
    assert json.loads(odoo.requests[-1].content) == {"applicant_ids": [90], "remove": True}
    v2.close(7)
    assert v2.release(7, [2]) == 1 and v2.release(7) == 1
    assert json.loads(odoo.requests[-2].content) == {"evaluator_ids": [2]}


def test_the_recorded_reads_map_to_what_yantra_needs(odoo):
    a = to_assessment(recorded("assessment-detail")["data"])
    assert (a.id, a.state, a.question_count, a.question_types, a.generator_id) == (
        2,
        "in_progress",
        2,
        ["mcq", "msq"],
        1,
    )
    assert a.rules["tab_switch"] and not a.rules["webcam"] and a.pass_threshold == 75.0
    draft = to_assessment(recorded("assessment-create")["data"])
    assert (draft.state, draft.question_count) == ("draft", 2), "a draft counts its pool"
    v2 = make(odoo)
    odoo.faults["/api/v1/assessments"] = [replay("assessments-list")]
    assert [(x.id, x.state) for x in v2.assessments()] == [(2, "in_progress"), (1, "done")]
    odoo.faults["/api/v1/attempts"] = [replay("attempts-fail-and-pending")]
    attempts, server_time = v2.attempts_since(NOW)
    assert server_time == datetime(2026, 11, 12, 11, 30, 44, tzinfo=UTC)
    pending, failed = attempts
    assert (pending.id, pending.state, pending.result, pending.released) == (3, "pending", "pending", False)
    assert (failed.id, failed.assessment_id, failed.state, failed.result) == (2, 2, "submitted", "fail")
    assert (failed.released, failed.subjective_max, failed.integrity_alert, failed.score_percent) == (
        False,
        0,
        False,
        0.0,
    )
    assert failed.submitted_at == datetime(2026, 11, 12, 11, 30, 42, tzinfo=UTC)
    odoo.faults["/api/v1/attempts"] = [replay("attempts-changed-since-released")]
    (released,), _ = v2.attempts_since(NOW)
    assert (released.result, released.released, released.score_percent) == ("pass", True, 100.0)


def test_a_401_mints_both_tokens_again_once(odoo):
    v2 = make(odoo)
    v2.assessment(7)
    odoo.faults["/api/v1/assessments/7"] = [httpx.Response(401, json={"ok": False})]
    v2.assessment(7)
    assert (odoo.kc_tokens, odoo.odoo_tokens) == (2, 2)
    odoo.faults["/api/v1/assessments/7"] = [httpx.Response(401, json={})] * 2
    with pytest.raises(EngineError) as e:
        v2.assessment(7)
    assert e.value.status == 401


def test_reads_retry_a_dropped_connection_and_a_5xx_writes_do_not(odoo):
    v2 = make(odoo)
    odoo.faults["/api/v1/assessments/7"] = [httpx.ConnectError("x"), httpx.Response(503)]
    assert v2.assessment(7).id == 7
    odoo.faults["/api/v1/assessments/7"] = [httpx.Response(502)] * 3
    with pytest.raises(EngineUnavailable):
        v2.assessment(7)
    odoo.faults["/api/v1/assessments/7/close"] = [httpx.Response(500)]
    with pytest.raises(EngineUnavailable):
        v2.close(7)
    odoo.faults["/api/v1/assessments/7/close"] = [httpx.ReadTimeout("slow")]
    with pytest.raises(EngineUnavailable):
        v2.close(7)


def test_a_refusal_carries_the_engines_code_and_extras(odoo):
    v2 = make(odoo)
    odoo.faults["/api/v1/assessments/7/launch"] = [
        httpx.Response(
            422,
            json={"ok": False, "error": {"code": "launch_blocked", "message": "Launch blocked"}, "failed_gates": ["x"]},
        )
    ]
    with pytest.raises(EngineError) as e:
        v2.launch(7)
    assert (e.value.code, e.value.status, e.value.context) == ("launch_blocked", 422, {"failed_gates": ["x"]})
    odoo.faults["/api/v1/assessments/7/close"] = [httpx.Response(409, json={"ok": False, "error": "plain words"})]
    with pytest.raises(EngineError) as e:
        v2.close(7)
    assert (e.value.code, e.value.message) == ("refused", "plain words")
    odoo.faults["/api/v1/assessments/7/close"] = [httpx.Response(409, text="<html>")]
    with pytest.raises(EngineError) as e:
        v2.close(7)
    assert e.value.code == "refused"
    odoo.faults["/api/v1/assessments/7/close"] = [httpx.Response(200, json=["not", "an", "object"])]
    assert v2.close(7) is None


def test_keycloak_trouble_is_an_outage(odoo):
    v2 = make(odoo)
    odoo.faults["/realms/yantra/protocol/openid-connect/token"] = [httpx.Response(401, json={})]
    with pytest.raises(EngineUnavailable):
        v2.assessment(7)
    odoo.faults["/realms/yantra/protocol/openid-connect/token"] = [httpx.ConnectError("down")]
    with pytest.raises(EngineUnavailable):
        v2.ensure_person("s", "", False, "", "worker")


def test_a_service_token_without_an_expiry_lasts_fifteen_minutes(odoo):
    v2 = make(odoo)
    odoo.faults["/api/v1/yantra/service/token"] = [
        httpx.Response(200, json={"ok": True, "data": {"access_token": "odoo-x"}})
    ]
    v2.assessment(7)
    assert v2._odoo == ("odoo-x", NOW + timedelta(minutes=15))


def test_the_mappers_tolerate_missing_fields():
    a = to_assessment({"id": 1})
    assert (a.state, a.question_count, a.question_types, a.rules, a.generator_id) == ("draft", 0, [], {}, None)
    t = to_attempt({"id": 2, "assessment_id": 1})
    assert (t.state, t.result, t.deadline, t.subjective_state) == ("pending", "pending", None, "pending")
    header = base64.b64decode(quick_csv([])).decode().strip()
    assert header == "title,question_type,prompt,difficulty,time_minutes,options,correct_answer"


def test_the_default_client_has_a_timeout():
    v2 = V2Engine(ODOO, TOKEN_URL, "c", "s", timeout=4)
    assert v2.http.timeout.read == 4 and v2.http.timeout.connect == 3.0
