"""Every subcommand reaches the right route with the right body; the exit codes say what happened."""

import json

import httpx
import pytest

from yantra_cli.__main__ import main

from .conftest import WORKER, expired_session, fresh_session

ID = "11111111-1111-4111-8111-111111111111"


def run(backend, env, *argv, capsys):
    code = main(list(argv), http=backend.client, env=env)
    out, err = capsys.readouterr()
    return code, out, err


def test_login_whoami_and_not_logged_in(backend, env, capsys):
    code, out, err = run(backend, env, "whoami", capsys=capsys)
    assert code == 2 and "not logged in" in err
    code, out, _ = run(backend, env, "login", "worker1", "--password", "yantra", capsys=capsys)
    assert code == 0 and "logged in as worker1" in out and WORKER in out
    code, out, _ = run(backend, env, "--json", "whoami", capsys=capsys)
    assert code == 0 and json.loads(out)["roles"] == ["worker"]
    code, _, err = run(backend, {**env, "YANTRA_PASSWORD": "nope"}, "login", "worker1", capsys=capsys)
    assert code == 1 and "auth error" in err


COMMANDS = [
    (
        ["project-create", "--name", "p", "--schema-json", "{}", "--margin-floor", "0.3", "--cert-gate", "g"],
        "POST /v1/projects",
        {
            "name": "p",
            "currency": "INR",
            "payload_schema": {},
            "rubric_version": "v1",
            "margin_floor": "0.3",
            "cert_gate": "g",
        },
    ),
    (
        ["project-create", "--name", "p", "--schema-json", "{}", "--answer-schema-json", '{"type": "object"}'],
        "POST /v1/projects",
        {
            "name": "p",
            "currency": "INR",
            "payload_schema": {},
            "rubric_version": "v1",
            "answer_schema": {"type": "object"},
        },
    ),
    (
        ["batch-create", ID, "--title", "b", "--unit-pay", "28", "--unit-price", "60"],
        f"POST /v1/projects/{ID}/batches",
        {
            "title": "b",
            "mode": "open",
            "unit_pay": "28",
            "unit_price": "60",
            "review_pay": "0",
            "claim_ttl_minutes": 240,
        },
    ),
    (["units-import", ID, "--lines-json", "[]"], f"POST /v1/batches/{ID}/units/import", {"lines": []}),
    (["units-import", ID, "--lines-json", "[]", "--commit"], f"POST /v1/batches/{ID}/units/import", {"lines": []}),
    (["batch-publish", ID, "--approved-by", "cfo"], f"POST /v1/batches/{ID}/publish", {"approved_by": "cfo"}),
    (["batch-manifest", ID], f"GET /v1/batches/{ID}/manifest", None),
    (
        ["worker-set", ID, "--gates", "a,b", "--partner-ref", "7"],
        f"PUT /v1/workers/{ID}",
        {"status": "eligible", "cert_gates": ["a", "b"], "partner_ref": 7},
    ),
    (["batches"], "GET /v1/batches", None),
    (["claim", ID], f"POST /v1/batches/{ID}/claims", None),
    (["active"], "GET /v1/claims/active", None),
    (["me"], "GET /v1/workers/me", None),
    (["availability", "--hours", "20"], "PUT /v1/workers/me/availability", {"weekly_hours": 20, "paused_until": None}),
    (
        ["availability", "--hours", "0", "--paused-until", "2030-01-01T00:00:00+00:00"],
        "PUT /v1/workers/me/availability",
        {"weekly_hours": 0, "paused_until": "2030-01-01T00:00:00+00:00"},
    ),
    (["unit", ID], f"GET /v1/units/{ID}", None),
    (["submit", ID, "--answer-json", '{"t": 1}'], f"POST /v1/claims/{ID}/submission", {"answer": {"t": 1}}),
    (["review-claim", "--kind", "audit"], "POST /v1/quality/reviews/claim", None),
    (["review-task", ID], f"GET /v1/quality/tasks/{ID}", None),
    (
        ["review-record", ID, "--verdict", "reject", "--reason", "incomplete", "--rubric-unclear"],
        f"POST /v1/quality/tasks/{ID}/review",
        {"verdict": "reject", "reason_code": "incomplete", "rubric_unclear": True, "note": None},
    ),
    (["flags"], "GET /v1/quality/flags", None),
    (["flag-answer", ID, "--answer", "use v2"], f"POST /v1/quality/flags/{ID}/answer", {"answer": "use v2"}),
    (["my-work"], "GET /v1/quality/my-work", None),
    (
        ["dispute", ID, "--reason", "the glossary changed after I submitted"],
        f"POST /v1/quality/tasks/{ID}/dispute",
        {"reason": "the glossary changed after I submitted"},
    ),
    (["disputes"], "GET /v1/quality/disputes", None),
    (
        ["dispute-resolve", ID, "--outcome", "upheld", "--answer", "reviewer error"],
        f"POST /v1/quality/disputes/{ID}/resolve",
        {"outcome": "upheld", "answer": "reviewer error"},
    ),
    (["statement"], "GET /v1/payout/statement", None),
    (["windows", "--status", "paid"], "GET /v1/payout/windows", None),
    (
        ["window-close", "--as-of", "2030-01-05T04:30:00+00:00"],
        "POST /v1/payout/windows/close",
        {"currency": "INR", "as_of": "2030-01-05T04:30:00+00:00"},
    ),
    (["window-approve", ID], f"POST /v1/payout/windows/{ID}/approve", None),
    (["window-lines", ID], f"GET /v1/payout/windows/{ID}/lines", None),
    (["bank-file", ID], f"GET /v1/payout/windows/{ID}/bank-file", None),
    (["window-pay", ID], f"POST /v1/payout/windows/{ID}/pay", None),
    (["line-retry", ID, ID], f"POST /v1/payout/windows/{ID}/lines/{ID}/retry", None),
    (["line-release", ID, ID], f"POST /v1/payout/windows/{ID}/lines/{ID}/release", None),
    (["reconcile", ID], f"GET /v1/payout/windows/{ID}/reconcile", None),
    (["window-reconcile", ID], f"POST /v1/payout/windows/{ID}/reconcile", None),
    (["reconciliation-runs", "--window", ID], "GET /v1/payout/reconciliation-runs", None),
    (["rail-status"], "GET /v1/payout/rail", None),
    (["bank-account"], "GET /v1/payout/accounts/me", None),
    (
        ["bank-account", "--name", "Asha Rao", "--number", "123456789012", "--ifsc", "HDFC0001234"],
        "PUT /v1/payout/accounts/me",
        {"account_name": "Asha Rao", "account_number": "123456789012", "ifsc": "HDFC0001234"},
    ),
    (["statement-export", ID], f"GET /v1/payout/statements/{ID}/export", None),
    (["margin"], "GET /v1/payout/margin", None),
    (
        ["hold", ID, "--reason", "integrity"],
        f"PUT /v1/payout/accounts/{ID}/hold",
        {"reason": "integrity", "until": None},
    ),
    (["inbox"], "GET /v1/notify/inbox", None),
    (["inbox-read", ID], f"POST /v1/notify/inbox/{ID}/read", None),
    (["channel"], "GET /v1/notify/channel", None),
    (["channel", "--email", "w@example.test"], "PUT /v1/notify/channel", {"email": "w@example.test"}),
    (["channel", "--email", ""], "PUT /v1/notify/channel", {"email": None}),
    (["channel-verify", "482913"], "POST /v1/notify/channel/verify", {"code": "482913"}),
    (["reasons"], "GET /v1/quality/reasons", None),
    (["reasons", "--all"], "GET /v1/quality/reasons", None),
    (["reviewer-set", ID, "--sensitive-cleared"], f"PUT /v1/quality/reviewers/{ID}", {"sensitive_cleared": True}),
    (["reviewer-set", ID, "--no-sensitive-cleared"], f"PUT /v1/quality/reviewers/{ID}", {"sensitive_cleared": False}),
    (["deliverable", ID], f"GET /v1/batches/{ID}/deliverable", None),
    (["attention"], "GET /v1/attention", None),
    (["stuck-release", ID], f"POST /v1/claims/{ID}/release-expired", None),
    (["stuck-release", ID, "--kind", "review"], f"POST /v1/quality/reviews/{ID}/release-expired", None),
    (["dead-letters", "quality"], "GET /v1/quality/dead-letters", None),
    (["dead-letter-replay", "payout", ID], f"POST /v1/payout/dead-letters/{ID}/replay", None),
    (["jobs", "market"], "GET /v1/market/jobs", None),
    (["jobs", "tracker"], "GET /v1/tracker/jobs", None),
    (["track-sessions"], "GET /v1/tracker/sessions/me", None),
    (["track-sessions", "--worker-id", ID], "GET /v1/tracker/sessions", None),
    (["anomalies"], "GET /v1/tracker/anomalies", None),
    (
        ["anomaly-decide", ID, "--outcome", "uphold", "--note", "n"],
        f"POST /v1/tracker/anomalies/{ID}/uphold",
        {"note": "n"},
    ),
    (["anomaly-decide", ID, "--outcome", "dismiss"], f"POST /v1/tracker/anomalies/{ID}/dismiss", {"note": None}),
    (["leadership", "--days", "7"], "GET /v1/analytics/leadership", None),
    (
        ["baselines-set", "--days-to-staff", "3", "--staffing-workers", "4", "--note", "q4"],
        "PUT /v1/analytics/baselines",
        {"days_to_staff": "3", "staffing_workers": 4, "note": "q4"},
    ),
]


@pytest.mark.parametrize("argv,route,body", COMMANDS, ids=[c[0][0] + str(i) for i, c in enumerate(COMMANDS)])
def test_each_command_hits_its_route(backend, env, cfg, capsys, argv, route, body):
    fresh_session(cfg.session_file)
    backend.on(route, lambda r: httpx.Response(200, json={"echo": "ok"}))
    code, out, err = run(backend, env, *argv, capsys=capsys)
    assert code == 0, err
    assert "echo  ok" in out
    req = backend.requests[-1]
    assert f"{req.method} {req.url.path}" == route
    if body is not None:
        assert json.loads(req.content) == body
    if argv[0] == "units-import":
        assert req.url.params["dry_run"] == ("false" if "--commit" in argv else "true")
    if argv[0] == "windows":
        assert req.url.params["status"] == "paid"
    if argv[0] == "review-claim":
        assert req.url.params["kind"] == "audit"
    if argv[0] == "track-sessions" and len(argv) > 1:
        assert req.url.params["worker_id"] == ID
    if argv[0] == "leadership":
        assert req.url.params["days"] == "7"


def test_stuck_lists_both_queues_and_release_all_hits_both(backend, env, cfg, capsys):
    fresh_session(cfg.session_file)
    for route in (
        "GET /v1/claims/expired",
        "GET /v1/quality/reviews/expired",
        "GET /v1/claims/released",
        "GET /v1/quality/reviews/released",
    ):
        backend.on(route, httpx.Response(200, json=[]))
    code, out, _ = run(backend, env, "--json", "stuck", "--days", "3", capsys=capsys)
    assert code == 0 and json.loads(out) == {"claims": [], "reviews": [], "released_claims": [], "released_reviews": []}
    assert backend.requests[-1].url.params["days"] == "3"
    backend.on("POST /v1/claims/release-expired", {"released": 1, "more": False})
    backend.on("POST /v1/quality/reviews/release-expired", {"released": 0})
    code, out, _ = run(backend, env, "--json", "stuck-release", "all", capsys=capsys)
    assert code == 0 and json.loads(out) == {"claims": {"released": 1, "more": False}, "reviews": {"released": 0}}


def test_release_expired_calls_both_routes(backend, env, cfg, capsys):
    fresh_session(cfg.session_file)
    backend.on("POST /v1/claims/release-expired", {"released": 1, "more": False})
    backend.on("POST /v1/quality/reviews/release-expired", {"released": 2})
    code, out, _ = run(backend, env, "--json", "release-expired", capsys=capsys)
    assert code == 0 and json.loads(out) == {"claims": {"released": 1, "more": False}, "reviews": {"released": 2}}


def test_json_args_from_file_and_missing_json_is_a_usage_error(backend, env, cfg, capsys, tmp_path):
    fresh_session(cfg.session_file)
    f = tmp_path / "lines.json"
    f.write_text('[{"external_ref": "u1", "payload": {}}]')
    backend.on(f"POST /v1/batches/{ID}/units/import", {"total": 1})
    code, _, _ = run(backend, env, "units-import", ID, "--lines-file", str(f), capsys=capsys)
    assert code == 0 and json.loads(backend.requests[-1].content)["lines"][0]["external_ref"] == "u1"
    with pytest.raises(SystemExit, match="answer"):
        run(backend, env, "submit", ID, capsys=capsys)


def test_gateway_errors_exit_1_and_an_expired_session_is_refreshed_and_saved(backend, env, cfg, capsys):
    expired_session(cfg.session_file)
    backend.on("GET /v1/batches", httpx.Response(403, json={"code": "forbidden", "message": "no", "request_id": "r1"}))
    code, _, err = run(backend, env, "batches", capsys=capsys)
    assert code == 1 and "403 forbidden" in err and backend.tokens_issued == 1
    assert json.loads(cfg.session_file.read_text())["expires_at"] > 0


def test_the_bank_return_file_is_uploaded_as_csv_and_a_statement_can_be_written_to_a_file(
    backend, env, cfg, capsys, tmp_path
):
    fresh_session(cfg.session_file)
    returns = tmp_path / "returns.csv"
    returns.write_text("reference,status,utr,reason\nFILE-1,paid,UTR1,\n")
    backend.on(f"POST /v1/payout/windows/{ID}/bank-file/reconcile", {"applied": 1, "skipped": []})
    code, _, _ = run(backend, env, "bank-file-reconcile", ID, "--file", str(returns), capsys=capsys)
    req = backend.requests[-1]
    assert code == 0 and req.headers["content-type"] == "text/csv" and req.content.startswith(b"reference,status")
    assert req.headers["Idempotency-Key"]
    backend.on(
        f"GET /v1/payout/statements/{ID}/export",
        httpx.Response(200, text="a,b\n1,2\n", headers={"content-type": "text/csv"}),
    )
    out_file = tmp_path / "statement.csv"
    code, out, _ = run(backend, env, "--json", "statement-export", ID, "--out", str(out_file), capsys=capsys)
    assert code == 0 and out_file.read_text() == "a,b\n1,2\n" and json.loads(out)["lines"] == 2


def test_bank_account_flags_go_together(backend, env, cfg, capsys):
    fresh_session(cfg.session_file)
    with pytest.raises(SystemExit, match="together"):
        run(backend, env, "bank-account", "--name", "Asha", capsys=capsys)
