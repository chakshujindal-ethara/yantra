"""Every subcommand as a function of (gateway, parsed args) returning what to print. Thin by design: the
rules live in the services; this file only shapes requests."""

import json
from pathlib import Path
from typing import Any

from yantra_cli.client import Gateway


def _json_arg(inline: str | None, file: str | None, what: str) -> Any:
    if file:
        return json.loads(Path(file).read_text())
    if inline:
        return json.loads(inline)
    raise SystemExit(f"{what}: give --{what}-json or --{what}-file")


# ---------- ops: projects, batches, units ----------


def project_create(gw: Gateway, a: Any) -> Any:
    body: dict[str, Any] = {
        "name": a.name,
        "currency": a.currency,
        "payload_schema": _json_arg(a.schema_json, a.schema_file, "schema"),
        "rubric_version": a.rubric_version,
    }
    if a.margin_floor is not None:
        body["margin_floor"] = a.margin_floor
    if a.cert_gate:
        body["cert_gate"] = a.cert_gate
    if a.answer_schema_json:
        body["answer_schema"] = json.loads(a.answer_schema_json)
    return gw.post("/v1/projects", body)


def batch_create(gw: Gateway, a: Any) -> Any:
    body = {
        "title": a.title,
        "mode": a.mode,
        "unit_pay": a.unit_pay,
        "unit_price": a.unit_price,
        "review_pay": a.review_pay,
        "claim_ttl_minutes": a.ttl_minutes,
    }
    return gw.post(f"/v1/projects/{a.project_id}/batches", body)


def units_import(gw: Gateway, a: Any) -> Any:
    lines = _json_arg(a.lines_json, a.lines_file, "lines")
    return gw.post(f"/v1/batches/{a.batch_id}/units/import", {"lines": lines}, dry_run="false" if a.commit else "true")


def batch_publish(gw: Gateway, a: Any) -> Any:
    body = {k: v for k, v in {"approved_by": a.approved_by, "approval_note": a.note}.items() if v}
    return gw.post(f"/v1/batches/{a.batch_id}/publish", body)


def batch_manifest(gw: Gateway, a: Any) -> Any:
    return gw.get(f"/v1/batches/{a.batch_id}/manifest")


def worker_set(gw: Gateway, a: Any) -> Any:
    gates = [g for g in (a.gates or "").split(",") if g]
    body: dict[str, Any] = {"status": a.status, "cert_gates": gates}
    if a.partner_ref is not None:
        body["partner_ref"] = a.partner_ref
    return gw.put(f"/v1/workers/{a.worker_id}", body)


def release_expired(gw: Gateway, a: Any) -> Any:
    return {"claims": gw.post("/v1/claims/release-expired"), "reviews": gw.post("/v1/quality/reviews/release-expired")}


# ---------- worker: browse, claim, work, submit ----------


def me(gw: Gateway, a: Any) -> Any:
    return gw.get("/v1/workers/me")


def availability(gw: Gateway, a: Any) -> Any:
    return gw.put("/v1/workers/me/availability", {"weekly_hours": a.hours, "paused_until": a.paused_until})


def batches(gw: Gateway, a: Any) -> Any:
    return gw.get("/v1/batches")


def claim(gw: Gateway, a: Any) -> Any:
    return gw.post(f"/v1/batches/{a.batch_id}/claims")


def active(gw: Gateway, a: Any) -> Any:
    return gw.get("/v1/claims/active")


def unit(gw: Gateway, a: Any) -> Any:
    return gw.get(f"/v1/units/{a.unit_id}")


def submit(gw: Gateway, a: Any) -> Any:
    return gw.post(f"/v1/claims/{a.claim_id}/submission", {"answer": _json_arg(a.answer_json, a.answer_file, "answer")})


# ---------- review ----------


def review_claim(gw: Gateway, a: Any) -> Any:
    return gw.post("/v1/quality/reviews/claim", kind=a.kind)


def review_task(gw: Gateway, a: Any) -> Any:
    return gw.get(f"/v1/quality/tasks/{a.task_id}")


def review_record(gw: Gateway, a: Any) -> Any:
    body = {"verdict": a.verdict, "reason_code": a.reason, "rubric_unclear": a.rubric_unclear, "note": a.note}
    return gw.post(f"/v1/quality/tasks/{a.task_id}/review", body)


def flags(gw: Gateway, a: Any) -> Any:
    return gw.get("/v1/quality/flags")


def flag_answer(gw: Gateway, a: Any) -> Any:
    return gw.post(f"/v1/quality/flags/{a.flag_id}/answer", {"answer": a.answer})


# ---------- the author: my work and disputes ----------


def my_work(gw: Gateway, a: Any) -> Any:
    return gw.get("/v1/quality/my-work")


def dispute(gw: Gateway, a: Any) -> Any:
    return gw.post(f"/v1/quality/tasks/{a.task_id}/dispute", {"reason": a.reason})


def disputes(gw: Gateway, a: Any) -> Any:
    return gw.get("/v1/quality/disputes")


def dispute_resolve(gw: Gateway, a: Any) -> Any:
    return gw.post(f"/v1/quality/disputes/{a.dispute_id}/resolve", {"outcome": a.outcome, "answer": a.answer})


# ---------- money ----------


def statement(gw: Gateway, a: Any) -> Any:
    return gw.get("/v1/payout/statement")


def windows(gw: Gateway, a: Any) -> Any:
    return gw.get("/v1/payout/windows", status=a.status)


def window_close(gw: Gateway, a: Any) -> Any:
    body: dict[str, Any] = {"currency": a.currency}
    if a.as_of:
        body["as_of"] = a.as_of
    return gw.post("/v1/payout/windows/close", body)


def window_approve(gw: Gateway, a: Any) -> Any:
    return gw.post(f"/v1/payout/windows/{a.window_id}/approve")


def window_lines(gw: Gateway, a: Any) -> Any:
    return gw.get(f"/v1/payout/windows/{a.window_id}/lines")


def bank_file(gw: Gateway, a: Any) -> Any:
    return gw.get(f"/v1/payout/windows/{a.window_id}/bank-file")


def window_pay(gw: Gateway, a: Any) -> Any:
    return gw.post(f"/v1/payout/windows/{a.window_id}/pay")


def line_retry(gw: Gateway, a: Any) -> Any:
    return gw.post(f"/v1/payout/windows/{a.window_id}/lines/{a.line_id}/retry")


def line_release(gw: Gateway, a: Any) -> Any:
    return gw.post(f"/v1/payout/windows/{a.window_id}/lines/{a.line_id}/release")


def bank_file_reconcile(gw: Gateway, a: Any) -> Any:
    """The bank's return file (`reference,status,utr,reason`) settles each line of a window paid by bank file."""
    with open(a.file, "rb") as f:
        content = f.read()
    return gw.call("POST", f"/v1/payout/windows/{a.window_id}/bank-file/reconcile", content=content)


def window_reconcile(gw: Gateway, a: Any) -> Any:
    return gw.post(f"/v1/payout/windows/{a.window_id}/reconcile")


def reconciliation_runs(gw: Gateway, a: Any) -> Any:
    return gw.get("/v1/payout/reconciliation-runs", window_id=a.window)


def rail_status(gw: Gateway, a: Any) -> Any:
    return gw.get("/v1/payout/rail")


def bank_account(gw: Gateway, a: Any) -> Any:
    """Without arguments, the account on file; with all three, register (or replace) it."""
    given = [a.name, a.number, a.ifsc]
    if not any(given):
        return gw.get("/v1/payout/accounts/me")
    if not all(given):
        raise SystemExit("give --name, --number and --ifsc together")
    return gw.put("/v1/payout/accounts/me", {"account_name": a.name, "account_number": a.number, "ifsc": a.ifsc})


def statement_export(gw: Gateway, a: Any) -> Any:
    text = gw.get(f"/v1/payout/statements/{a.window_id}/export", format="csv")
    if a.out is None:
        return text
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(text)
    return {"written": a.out, "lines": text.count("\n")}


def reconcile(gw: Gateway, a: Any) -> Any:
    return gw.get(f"/v1/payout/windows/{a.window_id}/reconcile")


def margin(gw: Gateway, a: Any) -> Any:
    return gw.get("/v1/payout/margin")


def hold(gw: Gateway, a: Any) -> Any:
    return gw.put(f"/v1/payout/accounts/{a.worker_id}/hold", {"reason": a.reason, "until": a.until})


# ---------- notify ----------


def inbox(gw: Gateway, a: Any) -> Any:
    return gw.get("/v1/notify/inbox")


def inbox_read(gw: Gateway, a: Any) -> Any:
    return gw.post(f"/v1/notify/inbox/{a.notification_id}/read")


def channel(gw: Gateway, a: Any) -> Any:
    if a.email is None:
        return gw.get("/v1/notify/channel")
    return gw.put("/v1/notify/channel", {"email": a.email or None})


def channel_verify(gw: Gateway, a: Any) -> Any:
    return gw.post("/v1/notify/channel/verify", {"code": a.code})


# ---------- operations ----------

MODULES = ("market", "talent", "assess", "quality", "notify", "payout", "tracker", "analytics")


def dead_letters(gw: Gateway, a: Any) -> Any:
    return gw.get(f"/v1/{a.module}/dead-letters")


def dead_letter_replay(gw: Gateway, a: Any) -> Any:
    return gw.post(f"/v1/{a.module}/dead-letters/{a.dead_id}/replay")


def jobs(gw: Gateway, a: Any) -> Any:
    return gw.get(f"/v1/{a.module}/jobs")


# ---------- tracker ----------


def track_sessions(gw: Gateway, a: Any) -> Any:
    """ops with --worker-id: that worker's sessions; otherwise the caller's own week."""
    if a.worker_id:
        return gw.get("/v1/tracker/sessions", worker_id=a.worker_id)
    return gw.get("/v1/tracker/sessions/me")


def anomalies(gw: Gateway, a: Any) -> Any:
    return gw.get("/v1/tracker/anomalies", status=a.status)


def anomaly_decide(gw: Gateway, a: Any) -> Any:
    action = "uphold" if a.outcome == "uphold" else "dismiss"
    return gw.post(f"/v1/tracker/anomalies/{a.anomaly_id}/{action}", {"note": a.note})


# ---------- analytics ----------


def leadership(gw: Gateway, a: Any) -> Any:
    return gw.get("/v1/analytics/leadership", days=a.days)


def baselines_set(gw: Gateway, a: Any) -> Any:
    fields = (
        "currency",
        "days_to_staff",
        "idle_cost_weekly",
        "first_pass_acceptance",
        "cost_per_accepted_unit",
        "idle_hourly_cost",
        "idle_hours_per_week",
        "staffing_workers",
        "rail_fee_per_payout",
        "levy_rate",
        "payout_sla_days",
        "note",
    )
    return gw.put("/v1/analytics/baselines", {f: getattr(a, f) for f in fields if getattr(a, f) is not None})


# ---------- quality integrity, the deliverable, stuck work, attention ----------


def reasons(gw: Gateway, a: Any) -> Any:
    return gw.get("/v1/quality/reasons", all="true" if a.all else None)


def reviewer_set(gw: Gateway, a: Any) -> Any:
    return gw.put(f"/v1/quality/reviewers/{a.worker_id}", {"sensitive_cleared": a.sensitive_cleared})


def deliverable(gw: Gateway, a: Any) -> Any:
    """ops: the batch's delivery as files (JSONL and manifest), with five-minute download links."""
    return gw.get(f"/v1/batches/{a.batch_id}/deliverable")


def attention(gw: Gateway, a: Any) -> Any:
    return gw.get("/v1/attention")


def stuck(gw: Gateway, a: Any) -> Any:
    """admin/ops: claims and reviews past their time, and what was released in the last `days`."""
    return {
        "claims": gw.get("/v1/claims/expired"),
        "reviews": gw.get("/v1/quality/reviews/expired"),
        "released_claims": gw.get("/v1/claims/released", days=a.days),
        "released_reviews": gw.get("/v1/quality/reviews/released", days=a.days),
    }


def stuck_release(gw: Gateway, a: Any) -> Any:
    """admin/ops: release one stuck claim or review (`--kind`), or every one of both with `all`."""
    if a.target == "all":
        return {
            "claims": gw.post("/v1/claims/release-expired"),
            "reviews": gw.post("/v1/quality/reviews/release-expired"),
        }
    if a.kind == "review":
        return gw.post(f"/v1/quality/reviews/{a.target}/release-expired")
    return gw.post(f"/v1/claims/{a.target}/release-expired")
