"""Ethara's Assessment v2, driven over HTTP: v2's own `/api/v1` routes for papers, rosters, launches, attempts and
releases, and the `yantra_assess_bridge` addon's `/api/v1/yantra/service/*` routes for what v2 has no API for (a
person keyed on their Keycloak subject, a one-time launch ticket, the service's own token).

Auth: the work process holds the confidential Keycloak client `yantra-assess`. A client-credentials token signs the
bridge calls; the bridge trades it for a short-lived v2 token of the `yantra_assess_service` user (a v2 Admin), which
signs every v2 call. Both are cached until 30 s before they expire; a 401 mints them again once.

v2 answers `{ok, data, meta}` with a real HTTP status; a refusal carries `{ok: false, error: {code, message}}` plus
extras. Reads are retried on a dropped connection or a 5xx (three tries, jittered backoff); writes are not, since v2
has no idempotency keys: a write that may have landed surfaces as `EngineUnavailable` and the caller looks before it
tries again. No request or response body is logged (both can carry names and emails)."""

import base64
import csv
import io
import logging
import random
import threading
import time
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from typing import Any

import httpx

from yantra_assess.engine import (
    Attempt,
    EngineAssessment,
    EngineError,
    EngineUnavailable,
    Gate,
    Person,
    PersonKind,
    QuickQuestion,
    Ticket,
)
from yantra_common.metrics import ASSESS_ENGINE_CALLS, ASSESS_ENGINE_UP

log = logging.getLogger("yantra.assess.v2")
TRIES = 3
PAGE = 200
EARLY = timedelta(seconds=30)
# v2's detail `rules` names -> the assessment fields `/assessments/create` takes
RULE_FIELDS = {
    "tab_switch": "rule_block_tab_switch",
    "copy_paste": "rule_block_copy_paste",
    "right_click": "rule_block_right_click",
    "devtools": "rule_block_devtools",
    "fullscreen": "rule_fullscreen",
    "webcam": "rule_webcam",
    "ai_proctor": "rule_ai_proctor",
    "seb": "rule_require_seb",
    "watermark": "rule_watermark",
}
CSV_COLUMNS = ["title", "question_type", "prompt", "difficulty", "time_minutes", "options", "correct_answer"]
COPIED_FIELDS = (
    "duration_minutes",
    "pass_threshold",
    "subjective_threshold",
    "transcription_threshold",
    "llm_auto_score",
    "require_reviewed_rubric",
    "results_show_answers",
    "shuffle_questions",
    "max_violations",
    "violation_action",
    "ai_max_violations",
    "ai_violation_action",
)


def _when(value: Any) -> datetime | None:
    if not value:
        return None
    parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)


def _iso(value: datetime) -> str:
    return value.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def to_assessment(row: dict[str, Any]) -> EngineAssessment:
    """A list row or a detail: the detail adds `questions` and `rules`."""
    questions = row.get("questions") or []
    limit = int(row.get("question_limit") or 0)
    count = limit or len(questions) or int(row.get("questions_available") or 0)
    kinds = sorted({str(q.get("question_type") or q.get("type")) for q in questions if isinstance(q, dict)})
    generator = row.get("generator") or {}
    return EngineAssessment(
        id=int(row["id"]),
        name=str(row.get("name") or ""),
        state=str(row.get("state") or "draft"),
        duration_minutes=int(row.get("duration_minutes") or 0),
        pass_threshold=float(row.get("pass_threshold") or 0.0),
        question_count=count,
        question_types=[k for k in kinds if k and k != "None"],
        rules=dict(row.get("rules") or {}),
        generator_id=int(generator["id"]) if generator.get("id") else None,
        raw=row,
    )


def to_attempt(row: dict[str, Any]) -> Attempt:
    subjective = row.get("subjective") or {}
    flags = row.get("flags") or {}
    return Attempt(
        id=int(row["id"]),
        assessment_id=int(row["assessment_id"]),
        state=str(row.get("state") or "pending"),
        result=str(row.get("result") or "pending"),
        released=bool(row.get("results_released")),
        score_percent=float(row.get("score_percent") or 0.0),
        subjective_max=int(subjective.get("max") or 0),
        subjective_state=str(subjective.get("state") or "pending"),
        integrity_alert=bool(flags.get("integrity_alert")),
        violation_limit_breached=bool(flags.get("violation_limit_breached")),
        deadline=_when(row.get("deadline")),
        started_at=_when(row.get("started_at")),
        submitted_at=_when(row.get("submitted_at")),
    )


def quick_csv(questions: list[QuickQuestion]) -> str:
    """The questions in v2's bank-import CSV (`POST /api/v1/bank/template` names the columns), base64: options and
    a several-answer key are `|`-separated, so no option may contain one (checked when the paper is written)."""
    out = io.StringIO()
    writer = csv.DictWriter(out, fieldnames=CSV_COLUMNS)
    writer.writeheader()
    for q in questions:
        answer = q.answer if isinstance(q.answer, str) else "|".join(q.answer)
        writer.writerow(
            {
                "title": q.id,
                "question_type": "mcq" if q.kind == "single" else "msq",
                "prompt": q.prompt,
                "difficulty": "medium",
                "time_minutes": 1,
                "options": "|".join(q.options),
                "correct_answer": answer,
            }
        )
    return base64.b64encode(out.getvalue().encode()).decode()


class V2Engine:
    name = "v2"

    def __init__(
        self,
        odoo_url: str,
        token_url: str,
        client_id: str,
        client_secret: str,
        timeout: float = 10.0,
        client: httpx.Client | None = None,
        sleep: Callable[[float], None] = time.sleep,
        rng: random.Random | None = None,
        clock: Callable[[], datetime] = lambda: datetime.now(UTC),
    ) -> None:
        self.odoo_url = odoo_url.rstrip("/")
        self.token_url = token_url
        self.client_id, self.client_secret = client_id, client_secret
        self.http = client or httpx.Client(timeout=httpx.Timeout(timeout, connect=3.0))
        self.sleep, self.rng, self.clock = sleep, rng or random.Random(), clock
        self._lock = threading.Lock()
        self._kc: tuple[str, datetime] | None = None
        self._odoo: tuple[str, datetime] | None = None

    # ---------- tokens ----------

    def _keycloak_token(self) -> str:
        with self._lock:
            now = self.clock()
            if self._kc and self._kc[1] - EARLY > now:
                return self._kc[0]
            try:
                r = self.http.post(
                    self.token_url,
                    data={
                        "grant_type": "client_credentials",
                        "client_id": self.client_id,
                        "client_secret": self.client_secret,
                    },
                )
            except httpx.HTTPError as e:
                raise EngineUnavailable(f"Keycloak unreachable: {type(e).__name__}") from e
            if r.status_code != 200:
                raise EngineUnavailable(f"Keycloak refused the assess client: {r.status_code}")
            doc = r.json()
            self._kc = (str(doc["access_token"]), now + timedelta(seconds=int(doc.get("expires_in", 60))))
            return self._kc[0]

    def _odoo_token(self) -> str:
        if self._odoo and self._odoo[1] - EARLY > self.clock():
            return self._odoo[0]
        data = self._call("/api/v1/yantra/service/token", {}, op="service_token", bridge=True, retry=True)
        token = str(data["access_token"])
        self._odoo = (token, _when(data.get("expires_at")) or self.clock() + timedelta(minutes=15))
        return token

    def _forget_tokens(self) -> None:
        self._kc = self._odoo = None

    # ---------- one call ----------

    def _call(
        self,
        path: str,
        body: dict[str, Any],
        op: str,
        bridge: bool = False,
        retry: bool = False,
        whole: bool = False,
    ) -> Any:
        """POST `body` (v2's json2 routes read parameters from the body, never the query string) and return `data`
        (or the whole envelope when `whole`)."""
        reauthed = False
        attempt = 0
        while True:
            attempt += 1
            token = self._keycloak_token() if bridge else self._odoo_token()
            try:
                r = self.http.post(self.odoo_url + path, json=body, headers={"Authorization": f"Bearer {token}"})
            except httpx.HTTPError as e:
                if retry and attempt < TRIES:
                    self._backoff(attempt)
                    continue
                ASSESS_ENGINE_CALLS.labels(op, "unreachable").inc()
                ASSESS_ENGINE_UP.set(0)
                log.warning("engine unreachable op=%s error=%s", op, type(e).__name__)
                raise EngineUnavailable(f"Assessment engine unreachable ({type(e).__name__})") from e
            if r.status_code == 401 and not reauthed:
                reauthed = True
                self._forget_tokens()
                continue
            if r.status_code >= 500:
                if retry and attempt < TRIES:
                    self._backoff(attempt)
                    continue
                ASSESS_ENGINE_CALLS.labels(op, "error").inc()
                ASSESS_ENGINE_UP.set(0)
                log.warning("engine error op=%s status=%s", op, r.status_code)
                raise EngineUnavailable(f"Assessment engine error {r.status_code}")
            ASSESS_ENGINE_UP.set(1)
            doc = self._json(r)
            if r.status_code >= 400 or doc.get("ok") is False:
                error = doc.get("error")
                code, message = (
                    (str(error.get("code") or "refused"), str(error.get("message") or ""))
                    if isinstance(error, dict)
                    else ("refused", str(error or r.reason_phrase))
                )
                extra = {k: v for k, v in doc.items() if k not in ("ok", "error", "data")}
                ASSESS_ENGINE_CALLS.labels(op, "refused").inc()
                log.info("engine refused op=%s status=%s code=%s", op, r.status_code, code)
                raise EngineError(code, message, status=r.status_code, **extra)
            ASSESS_ENGINE_CALLS.labels(op, "ok").inc()
            return doc if whole else doc.get("data")

    @staticmethod
    def _json(r: httpx.Response) -> dict[str, Any]:
        try:
            doc = r.json()
        except ValueError:
            return {}
        return doc if isinstance(doc, dict) else {}

    def _backoff(self, attempt: int) -> None:
        self.sleep(self.rng.uniform(0, min(4.0, 0.25 * 2**attempt)))

    # ---------- the Engine protocol ----------

    def ensure_person(self, sub: str, email: str, email_verified: bool, name: str, kind: PersonKind) -> Person:
        data = self._call(
            "/api/v1/yantra/service/people",
            {"sub": sub, "email": email, "email_verified": email_verified, "name": name, "kind": kind},
            op="people",
            bridge=True,
        )
        applicant = data.get("applicant_id")
        return Person(user_id=int(data["user_id"]), applicant_id=int(applicant) if applicant else None)

    def assessments(self, state: str | None = None) -> list[EngineAssessment]:
        rows: list[EngineAssessment] = []
        offset = 0
        while True:
            body: dict[str, Any] = {"limit": PAGE, "offset": offset}
            if state:
                body["state"] = state
            doc = self._call("/api/v1/assessments", body, op="assessments", retry=True, whole=True)
            page = doc.get("data") or []
            rows += [to_assessment(r) for r in page]
            if not (doc.get("meta") or {}).get("has_more") or not page:
                return rows
            offset += len(page)

    def assessment(self, assessment_id: int) -> EngineAssessment:
        return to_assessment(self._call(f"/api/v1/assessments/{assessment_id}", {}, op="assessment", retry=True))

    def create_quick(
        self, title: str, duration_minutes: int, pass_mark: Decimal, questions: list[QuickQuestion]
    ) -> int:
        imported = self._call(
            "/api/v1/bank/import",
            {"content": quick_csv(questions), "filename": "quick.csv", "generator_name": f"Yantra quick: {title}"},
            op="bank_import",
        )
        gid = int(imported["generator_id"])
        approved = self._call(f"/api/v1/generators/{gid}/approve_all", {"acknowledge_warnings": True}, op="approve_all")
        if int((approved or {}).get("approved_count") or 0) < len(questions):
            raise EngineError("questions_held", "The engine held back some of the questions", status=422)
        created = self._call(
            "/api/v1/assessments/create",
            {
                "name": title,
                "generator_id": gid,
                "duration_minutes": duration_minutes,
                "pass_threshold": float(pass_mark * 100),
                "results_release": "manual",
                "llm_auto_score": False,
            },
            op="assessment_create",
        )
        return int(created["id"])

    def clone(self, base_id: int, name: str) -> int:
        base = self.assessment(base_id).raw
        values: dict[str, Any] = {"name": name}
        for key in COPIED_FIELDS:
            if base.get(key) is not None:
                values[key] = base[key]
        generator = base.get("generator") or {}
        if generator.get("id"):
            values["generator_id"] = generator["id"]
        # A launched base's `questions` is its draw. When that draw was a random subset of the pool, the copy draws
        # afresh from the generator (a retake must not see the same questions); otherwise it keeps the same set.
        question_ids = [q["id"] for q in base.get("questions") or [] if isinstance(q, dict) and q.get("id")]
        limit = int(base.get("question_limit") or 0)
        if limit:
            values["question_limit"] = limit
        if question_ids and not 0 < limit < len(base.get("pool") or question_ids):
            values["question_ids"] = question_ids
        for rule, field_name in RULE_FIELDS.items():
            if rule in (base.get("rules") or {}):
                values[field_name] = bool(base["rules"][rule])
        created = self._call("/api/v1/assessments/create", values, op="assessment_clone")
        return int(created["id"])

    def launch_gates(self, assessment_id: int) -> list[Gate]:
        data = self._call(f"/api/v1/assessments/{assessment_id}/launch", {}, op="launch_check", retry=True)
        return [
            Gate(str(g.get("code")), str(g.get("label") or ""), bool(g.get("passed")), str(g.get("reason") or ""))
            for g in data.get("gates") or []
        ]

    def assign(self, assessment_id: int, user_ids: list[int]) -> None:
        data = self._call(f"/api/v1/assessments/{assessment_id}/assign", {"user_ids": user_ids}, op="assign")
        data = data or {}
        if data.get("not_provisioned") or data.get("skipped"):
            raise EngineError("not_provisioned", "The engine could not give this person the paper", status=422)

    def launch(self, assessment_id: int) -> None:
        self._call(f"/api/v1/assessments/{assessment_id}/launch", {"confirm": True}, op="launch")

    def unassign(self, assessment_id: int, applicant_ids: list[int]) -> None:
        self._call(
            f"/api/v1/assessments/{assessment_id}/assign",
            {"applicant_ids": applicant_ids, "remove": True},
            op="unassign",
        )

    def close(self, assessment_id: int) -> None:
        self._call(f"/api/v1/assessments/{assessment_id}/close", {}, op="close")

    def release(self, assessment_id: int, attempt_ids: list[int] | None = None) -> int:
        body: dict[str, Any] = {} if attempt_ids is None else {"evaluator_ids": attempt_ids}
        data = self._call(f"/api/v1/assessments/{assessment_id}/release", body, op="release")
        return int((data or {}).get("released_count") or 0)

    def ticket(
        self,
        sub: str,
        kind: PersonKind,
        return_url: str,
        assessment_id: int | None = None,
        exam_token: str | None = None,
        next_path: str | None = None,
    ) -> Ticket:
        # the bridge's ticket kinds: a worker sits as a `candidate`
        body: dict[str, Any] = {
            "sub": sub,
            "kind": "candidate" if kind == "worker" else "staff",
            "return_url": return_url,
        }
        if assessment_id is not None:
            body["assessment_id"] = assessment_id
        if exam_token:
            body["exam_token"] = exam_token
        if next_path:
            body["next"] = next_path
        data = self._call("/api/v1/yantra/service/tickets", body, op="ticket", bridge=True)
        evaluator = data.get("evaluator_id")
        return Ticket(
            launch_url=str(data["launch_url"]),
            expires_at=_when(data.get("expires_at")) or self.clock() + timedelta(minutes=2),
            evaluator_id=int(evaluator) if evaluator else None,
            attempt_state=str(data["attempt_state"]) if data.get("attempt_state") else None,
        )

    def attempts_since(self, since: datetime | None) -> tuple[list[Attempt], datetime]:
        rows: list[Attempt] = []
        offset = 0
        server_time: datetime | None = None
        while True:
            body: dict[str, Any] = {"limit": PAGE, "offset": offset}
            if since is not None:
                body["changed_since"] = _iso(since)
            doc = self._call("/api/v1/attempts", body, op="attempts", retry=True, whole=True)
            meta = doc.get("meta") or {}
            if server_time is None:
                server_time = _when(meta.get("server_time")) or self.clock()
            page = doc.get("data") or []
            rows += [to_attempt(r) for r in page]
            if not meta.get("has_more") or not page:
                return rows, server_time
            offset += len(page)
