"""A deterministic, in-process engine for tests (and a rig without Odoo). It keeps assessments, people and attempts
in memory and follows v2's rules where Yantra depends on them: one attempt per person per assessment, an assessment
launches once with at least one person on it, a closed one takes nobody, results are released by hand, and a
cohort whose every attempt is submitted and released closes. Tests drive
the exam itself with `begin`, `submit` and `release`; `fail_next` makes the next call raise."""

import itertools
import threading
from collections.abc import Callable
from dataclasses import dataclass, field, replace
from datetime import UTC, datetime, timedelta
from decimal import Decimal

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

DEFAULT_RULES = {"webcam": False, "ai_proctor": False, "fullscreen": False, "tab_switch": True, "seb": False}


@dataclass
class _Assessment:
    id: int
    name: str
    duration_minutes: int
    pass_threshold: float
    question_types: list[str]
    question_count: int
    state: str = "draft"
    roster: set[int] = field(default_factory=set)  # user ids
    rules: dict[str, object] = field(default_factory=lambda: dict(DEFAULT_RULES))


class FakeEngine:
    name = "fake"

    def __init__(self, app_url: str = "http://localhost:8096") -> None:
        self.app_url = app_url
        self._ids = itertools.count(1)
        self._lock = threading.Lock()
        self._assessments: dict[int, _Assessment] = {}
        self._people: dict[str, Person] = {}  # sub -> person
        self._attempts: dict[int, Attempt] = {}
        self._attempt_user: dict[int, int] = {}
        self._changed: dict[int, datetime] = {}
        self.calls: list[str] = []
        self.fail_next: Exception | None = None
        self.now: Callable[[], datetime] = lambda: datetime.now(UTC)

    # ---------- plumbing ----------

    def _call(self, op: str) -> None:
        self.calls.append(op)
        if self.fail_next is not None:
            error, self.fail_next = self.fail_next, None
            raise error

    def _get(self, assessment_id: int) -> _Assessment:
        found = self._assessments.get(assessment_id)
        if found is None:
            raise EngineError("not_found", "Assessment not found", status=404)
        return found

    def _view(self, a: _Assessment) -> EngineAssessment:
        return EngineAssessment(
            id=a.id,
            name=a.name,
            state=a.state,
            duration_minutes=a.duration_minutes,
            pass_threshold=a.pass_threshold,
            question_count=a.question_count,
            question_types=list(a.question_types),
            rules=dict(a.rules),
        )

    def _touch(self, attempt: Attempt) -> None:
        self._attempts[attempt.id] = attempt
        self._changed[attempt.id] = self.now()

    # ---------- the Engine protocol ----------

    def ensure_person(self, sub: str, email: str, email_verified: bool, name: str, kind: PersonKind) -> Person:
        self._call("ensure_person")
        with self._lock:
            if sub not in self._people:
                uid = next(self._ids)
                self._people[sub] = Person(user_id=uid, applicant_id=uid + 100_000)
            return self._people[sub]

    def assessments(self, state: str | None = None) -> list[EngineAssessment]:
        self._call("assessments")
        return [self._view(a) for a in self._assessments.values() if state is None or a.state == state]

    def assessment(self, assessment_id: int) -> EngineAssessment:
        self._call("assessment")
        return self._view(self._get(assessment_id))

    def add_assessment(
        self, name: str = "Linked paper", duration_minutes: int = 30, pass_threshold: float = 60.0, types: int = 2
    ) -> int:
        """A test's stand-in for a paper built in the Assessment admin (any question types, any rules)."""
        aid = next(self._ids)
        kinds = ["mcq", "subjective_rubric", "image_ab", "transcription"][:types]
        self._assessments[aid] = _Assessment(aid, name, duration_minutes, pass_threshold, kinds, 5)
        return aid

    def create_quick(
        self, title: str, duration_minutes: int, pass_mark: Decimal, questions: list[QuickQuestion]
    ) -> int:
        self._call("create_quick")
        aid = next(self._ids)
        kinds = sorted({"mcq" if q.kind == "single" else "msq" for q in questions})
        self._assessments[aid] = _Assessment(
            aid, title, duration_minutes, float(pass_mark * 100), kinds, len(questions)
        )
        return aid

    def clone(self, base_id: int, name: str) -> int:
        self._call("clone")
        base = self._get(base_id)
        aid = next(self._ids)
        self._assessments[aid] = _Assessment(
            aid,
            name,
            base.duration_minutes,
            base.pass_threshold,
            list(base.question_types),
            base.question_count,
            rules=dict(base.rules),
        )
        return aid

    def launch_gates(self, assessment_id: int) -> list[Gate]:
        self._call("launch_gates")
        a = self._get(assessment_id)
        return [
            Gate("duration", "Duration set", a.duration_minutes >= 2, "" if a.duration_minutes >= 2 else "too short"),
            Gate("questions", "Questions", a.question_count > 0, "" if a.question_count else "no questions"),
            Gate("candidates", "Candidates", bool(a.roster), "" if a.roster else "nobody assigned"),
        ]

    def assign(self, assessment_id: int, user_ids: list[int]) -> None:
        self._call("assign")
        with self._lock:
            a = self._get(assessment_id)
            if a.state in ("done", "cancelled"):
                raise EngineError("assessment_closed", f"Cannot assign candidates to a {a.state} assessment")
            for uid in user_ids:
                a.roster.add(uid)
                if a.state == "in_progress":
                    self._open_attempt(a, uid)

    def _open_attempt(self, a: _Assessment, uid: int) -> None:
        if any(self._attempt_user[i] == uid and t.assessment_id == a.id for i, t in self._attempts.items()):
            return
        attempt = Attempt(
            id=next(self._ids),
            assessment_id=a.id,
            state="pending",
            result="pending",
            released=False,
            score_percent=0.0,
            subjective_max=0 if set(a.question_types) <= {"mcq", "msq"} else 10,
            subjective_state="pending",
            integrity_alert=False,
            violation_limit_breached=False,
        )
        self._attempt_user[attempt.id] = uid
        self._touch(attempt)

    def launch(self, assessment_id: int) -> None:
        self._call("launch")
        with self._lock:
            a = self._get(assessment_id)
            if a.state != "draft":
                raise EngineError("not_draft", "Only a draft assessment launches")
            if not a.roster:
                raise EngineError("launch_blocked", "Launch blocked: Candidates - nobody assigned", status=422)
            a.state = "in_progress"
            for uid in a.roster:
                self._open_attempt(a, uid)

    def unassign(self, assessment_id: int, applicant_ids: list[int]) -> None:
        self._call("unassign")
        a = self._get(assessment_id)
        users = {p.user_id for p in self._people.values() if p.applicant_id in applicant_ids}
        a.roster -= users
        for aid in [i for i, t in self._attempts.items() if t.assessment_id == a.id]:
            if self._attempt_user[aid] in users and self._attempts[aid].state == "pending":
                del self._attempts[aid]

    def close(self, assessment_id: int) -> None:
        self._call("close")
        self._get(assessment_id).state = "done"

    def release(self, assessment_id: int, attempt_ids: list[int] | None = None) -> int:
        self._call("release")
        self._get(assessment_id)
        released = 0
        for attempt in list(self._attempts.values()):
            if attempt.assessment_id != assessment_id or attempt.state != "submitted" or attempt.released:
                continue
            if attempt_ids is not None and attempt.id not in attempt_ids:
                continue
            self._touch(replace(attempt, released=True))
            released += 1
        if not released:
            raise EngineError("nothing_to_release", "No submitted candidates awaiting release", status=422)
        cohort = [t for t in self._attempts.values() if t.assessment_id == assessment_id]
        if all(t.state == "submitted" and t.released for t in cohort):  # v2 closes a fully released cohort
            self._get(assessment_id).state = "done"
        return released

    def ticket(
        self,
        sub: str,
        kind: PersonKind,
        return_url: str,
        assessment_id: int | None = None,
        exam_token: str | None = None,
        next_path: str | None = None,
    ) -> Ticket:
        self._call("ticket")
        person = self._people.get(sub)
        if person is None:
            raise EngineError("unknown_person", "Provision the person first", status=404)
        attempt = None
        if assessment_id is not None:
            attempt = next(
                (
                    t
                    for i, t in self._attempts.items()
                    if t.assessment_id == assessment_id and self._attempt_user[i] == person.user_id
                ),
                None,
            )
            if attempt is None:
                raise EngineError("not_assigned", "That person is not on this assessment", status=409)
        return Ticket(
            launch_url=f"{self.app_url}/yantra/launch#ticket=fake-{next(self._ids)}",
            expires_at=self.now() + timedelta(minutes=2),
            evaluator_id=attempt.id if attempt else None,
            attempt_state=attempt.state if attempt else None,
        )

    def attempts_since(self, since: datetime | None) -> tuple[list[Attempt], datetime]:
        self._call("attempts_since")
        server_time = self.now()
        rows = [t for i, t in self._attempts.items() if since is None or self._changed[i] >= since]
        return rows, server_time

    # ---------- the exam itself, for tests ----------

    def begin(self, attempt_id: int, minutes: int = 30) -> None:
        a = self._attempts[attempt_id]
        now = self.now()
        self._touch(replace(a, state="in_progress", started_at=now, deadline=now + timedelta(minutes=minutes)))

    def submit(
        self,
        attempt_id: int,
        result: str = "pass",
        score: float = 100.0,
        subjective_max: int | None = None,
        integrity_alert: bool = False,
        violation_limit_breached: bool = False,
    ) -> None:
        a = self._attempts[attempt_id]
        self._touch(
            replace(
                a,
                state="submitted",
                result=result,
                score_percent=score,
                submitted_at=self.now(),
                subjective_max=a.subjective_max if subjective_max is None else subjective_max,
                subjective_state="scored" if result != "pending" else "pending",
                integrity_alert=integrity_alert,
                violation_limit_breached=violation_limit_breached,
            )
        )

    def drop(self) -> None:
        """Stand-in for an engine outage, for the next call."""
        self.fail_next = EngineUnavailable("the engine is down")

    def attempt(self, attempt_id: int) -> Attempt:
        return self._attempts[attempt_id]
