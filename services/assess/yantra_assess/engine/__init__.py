"""The assessment engine behind Yantra's papers: Ethara's Assessment v2 (`v2`) in production, a deterministic
in-process engine (`fake`) in tests. Yantra keeps the paper, the attempts and the certification; the engine owns the
questions, the exam itself (timer, proctoring, autosave), the scoring and the release of results.

The words: an engine *assessment* is one cohort of one paper (v2 allows one attempt per person per assessment, so
attempt k of every worker sits in cohort k); an engine *attempt* is one person's sitting of it; a *ticket* is a
one-time, two-minute pass that signs the worker into the Assessment app at their exam without a password."""

from dataclasses import dataclass, field
from datetime import datetime
from decimal import Decimal
from typing import TYPE_CHECKING, Any, Literal, Protocol

if TYPE_CHECKING:
    from yantra_assess.config import AssessSettings

PersonKind = Literal["worker", "staff"]


class EngineError(Exception):
    """The engine refused (a 4xx): `code` is the engine's own machine-readable reason."""

    def __init__(self, code: str, message: str, status: int = 409, **context: Any) -> None:
        super().__init__(message)
        self.code, self.message, self.status, self.context = code, message, status, context


class EngineUnavailable(Exception):
    """The engine did not answer usefully (timeout, connection refused, 5xx after retries)."""


@dataclass(frozen=True)
class Person:
    user_id: int
    applicant_id: int | None


@dataclass(frozen=True)
class Gate:
    """One launch precondition the engine checks (duration, roster, answer keys, media...)."""

    code: str
    label: str
    passed: bool
    reason: str = ""


@dataclass(frozen=True)
class EngineAssessment:
    id: int
    name: str
    state: str  # draft | in_progress | done | cancelled
    duration_minutes: int
    pass_threshold: float  # 0..100, the engine's percentage bar
    question_count: int
    question_types: list[str]
    rules: dict[str, Any]
    generator_id: int | None = None
    raw: dict[str, Any] = field(default_factory=dict, compare=False, repr=False)

    def snapshot(self) -> dict[str, Any]:
        """What Yantra keeps of it, to show a brief without asking the engine."""
        return {
            "name": self.name,
            "state": self.state,
            "duration_minutes": self.duration_minutes,
            "pass_threshold": self.pass_threshold,
            "question_count": self.question_count,
            "question_types": self.question_types,
            "rules": self.rules,
        }


@dataclass(frozen=True)
class Attempt:
    id: int
    assessment_id: int
    state: str  # pending | in_progress | submitted
    result: str  # pending | pass | fail
    released: bool
    score_percent: float
    subjective_max: int
    subjective_state: str  # the LLM grader's state: pending | scoring | scored | error | ...
    integrity_alert: bool
    violation_limit_breached: bool
    deadline: datetime | None = None
    started_at: datetime | None = None
    submitted_at: datetime | None = None


@dataclass(frozen=True)
class Ticket:
    launch_url: str
    expires_at: datetime
    evaluator_id: int | None
    attempt_state: str | None


@dataclass(frozen=True)
class QuickQuestion:
    """A question Yantra writes itself: one answer (`single`, v2 `mcq`) or several (`multi`, v2 `msq`)."""

    id: str
    prompt: str
    kind: Literal["single", "multi"]
    options: list[str]
    answer: str | list[str]


class Engine(Protocol):
    name: str

    def ensure_person(self, sub: str, email: str, email_verified: bool, name: str, kind: PersonKind) -> Person: ...

    def assessments(self, state: str | None = None) -> list[EngineAssessment]: ...

    def assessment(self, assessment_id: int) -> EngineAssessment: ...

    def create_quick(
        self, title: str, duration_minutes: int, pass_mark: Decimal, questions: list[QuickQuestion]
    ) -> int: ...

    def clone(self, base_id: int, name: str) -> int: ...

    def launch_gates(self, assessment_id: int) -> list[Gate]: ...

    def assign(self, assessment_id: int, user_ids: list[int]) -> None: ...

    def launch(self, assessment_id: int) -> None: ...

    def unassign(self, assessment_id: int, applicant_ids: list[int]) -> None: ...

    def close(self, assessment_id: int) -> None: ...

    def release(self, assessment_id: int, attempt_ids: list[int] | None = None) -> int: ...

    def ticket(
        self,
        sub: str,
        kind: PersonKind,
        return_url: str,
        assessment_id: int | None = None,
        exam_token: str | None = None,
        next_path: str | None = None,
    ) -> Ticket: ...

    def attempts_since(self, since: datetime | None) -> tuple[list[Attempt], datetime]: ...


def select_engine(settings: "AssessSettings") -> Engine:
    """The engine `YANTRA_ASSESS_ENGINE` names, built from the assess settings."""
    from yantra_assess.engine.fake import FakeEngine
    from yantra_assess.engine.v2 import V2Engine

    if settings.engine == "v2":
        assert settings.client_secret is not None  # the settings refuse v2 without it
        return V2Engine(
            odoo_url=settings.odoo_url,
            token_url=settings.keycloak_token_url,
            client_id=settings.client_id,
            client_secret=settings.client_secret.get_secret_value(),
            timeout=settings.timeout_seconds,
        )
    return FakeEngine(app_url=settings.app_url)
