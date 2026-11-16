"""The assess operations: Yantra's side of a paper whose exam runs in the engine (Ethara's Assessment v2).

Ops link a paper to an assessment built in the Assessment admin (any question type, SOP-generated or authored in Form
Studio, any proctoring) or write a quick one here (one-answer and several-answer questions), then publish it once the
engine's launch gates pass. A worker launches a paper: Yantra makes sure they exist in the engine, puts them on the
cohort for their attempt number (making that cohort when nobody needed it yet), and hands back a one-time launch URL
that signs them into the Assessment app at their exam. The sync job reads the engine's attempts every few seconds:
a released pass writes the certification and emits `assess.certified`, a released fail emits `assess.failed`, and a
paper whose release policy is `auto_objective` has its clean, objective-only attempts released by the adapter.

Yantra never certifies on an unreleased result: release is the engine's deliberate act. The operator who linked,
wrote or published a paper may have read its answers and may not sit it (403 `paper_author`)."""

import logging
import uuid
from collections import Counter
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from decimal import ROUND_HALF_UP, Decimal
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from yantra_assess.config import AssessSettings
from yantra_assess.engine import Engine, EngineAssessment, EngineError, EngineUnavailable, Gate, QuickQuestion, Ticket
from yantra_assess.models import (
    FINISHED,
    OPEN,
    OUTBOX,
    RELEASE_POLICIES,
    Certification,
    Cohort,
    EngineCursor,
    Paper,
    Sitting,
    WorkerLink,
)
from yantra_common.errors import Conflict, DomainError, Forbidden, Invalid, NotFound
from yantra_common.metrics import ASSESS_AWAITING, ASSESS_SYNC_LAG
from yantra_common.outbox import emit
from yantra_contracts.events.v1 import AssessCertified, AssessFailed

log = logging.getLogger("yantra.assess")
MAX_ATTEMPTS = 10
MAX_QUESTIONS = 100
MAX_DURATION_MINUTES = 600
PLACES = Decimal("0.0001")
OVERLAP = timedelta(seconds=5)  # v2 compares `changed_since` by whole second: read a little behind
SNAPSHOT_EVERY = timedelta(minutes=5)
CURSOR = "attempts"
# the launch gate about who is on the roster (v2's code): a paper is published before anybody sits it
ROSTER_GATES = {"candidates"}
AWAITING_REASONS = ("llm_scoring", "needs_release", "integrity_review", "violation_limit", "subjective_answers")


class EngineDown(DomainError):
    status = 503
    code = "engine_unavailable"


@dataclass(frozen=True)
class BriefView:
    paper: Paper
    attempts_used: int
    attempts_left: int
    certified: bool
    current: Sitting | None


def _refused(e: EngineError) -> DomainError:
    """The engine's refusal, said as Yantra's 409 with the engine's own reason kept."""
    return Conflict(e.message or "the assessment engine refused", engine_code=e.code, **e.context).with_code(
        "engine_refused"
    )


def _engine(fn: Any, *args: Any, **kwargs: Any) -> Any:
    try:
        return fn(*args, **kwargs)
    except EngineUnavailable as e:
        raise EngineDown("the assessment engine is not answering; try again shortly") from e
    except EngineError as e:
        raise _refused(e) from e


# ---------- papers (ops) ----------


def engine_assessments(engine: Engine, state: str | None = "draft") -> list[EngineAssessment]:
    """What ops may link a paper to (drafts by default: a launched assessment already has its own cohort)."""
    found: list[EngineAssessment] = _engine(engine.assessments, state)
    return found


def _check_quick(questions: list[QuickQuestion]) -> None:
    if not 1 <= len(questions) <= MAX_QUESTIONS:
        raise Invalid(f"a quick paper has 1 to {MAX_QUESTIONS} questions").with_code("invalid_questions")
    ids = [q.id for q in questions]
    if len(set(ids)) != len(ids):
        raise Invalid("question ids must be unique").with_code("invalid_question_id")
    for q in questions:
        if len(set(q.options)) != len(q.options) or len(q.options) < 2 or any("|" in o for o in q.options):
            raise Invalid("each question needs two or more different options", question_id=q.id).with_code(
                "invalid_options"
            )
        if q.kind == "single" and (not isinstance(q.answer, str) or q.answer not in q.options):
            raise Invalid("a single answer must be one of the options", question_id=q.id).with_code("invalid_answer")
        if q.kind == "multi" and (
            not isinstance(q.answer, list) or not q.answer or not set(q.answer) <= set(q.options)
        ):
            raise Invalid("a multi answer must be a non-empty subset of the options", question_id=q.id).with_code(
                "invalid_answer"
            )


def create_paper(
    session: Session,
    engine: Engine,
    gate: str,
    title: str,
    description: str,
    max_attempts: int,
    source: dict[str, Any],
    release_policy: str = "manual",
    assigned_ttl_days: int = 14,
    created_by: uuid.UUID | None = None,
    now: datetime | None = None,
) -> Paper:
    """A draft paper over an engine assessment: `source` is `{kind: "assessment", assessment_id}` (built in the
    Assessment admin; must still be a draft there) or `{kind: "quick", duration_minutes, pass_mark, questions}`."""
    if not 1 <= max_attempts <= MAX_ATTEMPTS:
        raise Invalid(f"max_attempts must be 1 to {MAX_ATTEMPTS}").with_code("invalid_max_attempts")
    if release_policy not in RELEASE_POLICIES:
        raise Invalid(f"release_policy must be one of {', '.join(RELEASE_POLICIES)}").with_code("invalid_policy")
    if not 1 <= assigned_ttl_days <= 90:
        raise Invalid("assigned_ttl_days must be 1 to 90").with_code("invalid_ttl")
    if source.get("kind") == "assessment":
        base = _engine(engine.assessment, int(source["assessment_id"]))
        if base.state != "draft":
            raise Conflict(
                "link a draft assessment: a launched one already has its own candidates", state=base.state
            ).with_code("assessment_not_draft")
        if session.scalar(select(Paper.id).where(Paper.engine_base_id == base.id)) is not None:
            raise Conflict("another paper already uses that assessment").with_code("assessment_in_use")
    elif source.get("kind") == "quick":
        duration, pass_mark = int(source["duration_minutes"]), Decimal(str(source["pass_mark"]))
        if not 2 <= duration <= MAX_DURATION_MINUTES:
            raise Invalid(f"duration_minutes must be 2 to {MAX_DURATION_MINUTES}").with_code("invalid_duration")
        if not 0 < pass_mark <= 1:
            raise Invalid("pass_mark must be above 0 and at most 1").with_code("invalid_pass_mark")
        questions: list[QuickQuestion] = source["questions"]
        _check_quick(questions)
        base_id = _engine(engine.create_quick, title, duration, pass_mark, questions)
        base = _engine(engine.assessment, base_id)
    else:
        raise Invalid("source.kind must be assessment or quick").with_code("invalid_source")
    paper = Paper(
        gate=gate,
        title=title,
        description=description,
        max_attempts=max_attempts,
        engine=engine.name,
        engine_base_id=base.id,
        release_policy=release_policy,
        assigned_ttl_days=assigned_ttl_days,
        snapshot=base.snapshot(),
        snapshot_at=now or datetime.now(UTC),
        created_by=created_by,
    )
    session.add(paper)
    session.flush()
    session.refresh(paper)
    return paper


def get_paper(session: Session, paper_id: uuid.UUID) -> Paper:
    paper = session.get(Paper, paper_id)
    if paper is None:
        raise NotFound("paper not found", paper_id=str(paper_id))
    return paper


def launch_problems(gates: list[Gate]) -> list[Gate]:
    """The gates that must pass before anybody sits: all but the roster ones."""
    return [g for g in gates if not g.passed and not any(word in g.code for word in ROSTER_GATES)]


def publish_paper(session: Session, engine: Engine, paper_id: uuid.UUID, by: uuid.UUID | None = None) -> Paper:
    """Opens the paper to workers once the engine's launch gates pass (all but the roster, which fills on launch).
    A refusal names every failing gate (422 `launch_blocked`)."""
    paper = get_paper(session, paper_id)
    if paper.status != "draft":
        raise Conflict("only a draft paper publishes", status=paper.status).with_code("already_published")
    assert paper.engine_base_id is not None  # an engine paper always has its base
    problems = launch_problems(_engine(engine.launch_gates, paper.engine_base_id))
    if problems:
        raise Invalid(
            "the assessment cannot launch yet: "
            + "; ".join(f"{g.label} ({g.reason})" if g.reason else g.label for g in problems),
            gates=[{"code": g.code, "label": g.label, "reason": g.reason} for g in problems],
        ).with_code("launch_blocked")
    paper.status, paper.published_at, paper.published_by = "published", datetime.now(UTC), by
    session.flush()
    return paper


def paper_stats(session: Session, paper_ids: list[uuid.UUID]) -> dict[uuid.UUID, dict[str, Any]]:
    """Per paper: finished attempts, passes and the pass rate, plus sittings waiting for a result and those held."""
    rows = session.execute(
        select(Sitting.paper_id, Sitting.status, Sitting.held_reason, func.count())
        .where(Sitting.paper_id.in_(paper_ids))
        .group_by(Sitting.paper_id, Sitting.status, Sitting.held_reason)
    ).all()
    counts: dict[uuid.UUID, Counter[str]] = {pid: Counter() for pid in paper_ids}
    for pid, status, held, n in rows:
        counts[pid][status] += n
        if held and held != "llm_scoring":
            counts[pid]["held"] += n
    out: dict[uuid.UUID, dict[str, Any]] = {}
    for pid, c in counts.items():
        total = sum(c[s] for s in FINISHED)
        rate = (Decimal(c["passed"]) / Decimal(total)).quantize(PLACES, ROUND_HALF_UP) if total else None
        out[pid] = {
            "total": total,
            "passed": c["passed"],
            "pass_rate": rate,
            "awaiting_result": c["awaiting_result"],
            "held": c["held"],
        }
    return out


def list_papers(session: Session, limit: int = 200) -> list[tuple[Paper, dict[str, Any]]]:
    papers = list(session.scalars(select(Paper).order_by(Paper.created_at.desc(), Paper.id.desc()).limit(limit)))
    stats = paper_stats(session, [p.id for p in papers])
    return [(p, stats[p.id]) for p in papers]


def cohorts_of(session: Session, paper_id: uuid.UUID) -> list[Cohort]:
    return list(
        session.scalars(
            select(Cohort).where(Cohort.paper_id == paper_id).order_by(Cohort.generation, Cohort.attempt_no)
        )
    )


def paper_sittings(session: Session, paper_id: uuid.UUID, limit: int = 500) -> list[Sitting]:
    get_paper(session, paper_id)
    return list(
        session.scalars(
            select(Sitting)
            .where(Sitting.paper_id == paper_id)
            .order_by(Sitting.created_at.desc(), Sitting.id.desc())
            .limit(limit)
        )
    )


def release(session: Session, engine: Engine, paper_id: uuid.UUID, sitting_ids: list[uuid.UUID] | None = None) -> int:
    """Releases results in the engine: the named sittings, or every one of this paper waiting for release. The sync
    turns each into a certification or a fail within seconds."""
    get_paper(session, paper_id)
    query = select(Sitting).where(
        Sitting.paper_id == paper_id,
        Sitting.status == "awaiting_result",
        Sitting.engine_attempt_id.is_not(None),
        Sitting.result.in_(("pass", "fail")),
    )
    if sitting_ids is not None:
        query = query.where(Sitting.id.in_(sitting_ids))
    by_cohort: dict[uuid.UUID, list[int]] = {}
    for s in session.scalars(query):
        assert s.cohort_id is not None and s.engine_attempt_id is not None
        by_cohort.setdefault(s.cohort_id, []).append(s.engine_attempt_id)
    if not by_cohort:
        raise Conflict("nothing waits for release on this paper").with_code("nothing_to_release")
    released = 0
    for cohort_id, attempt_ids in by_cohort.items():
        cohort = session.get(Cohort, cohort_id)
        assert cohort is not None
        released += int(_engine(engine.release, cohort.engine_assessment_id, attempt_ids))
    return released


def rotate(session: Session, engine: Engine, paper_id: uuid.UUID) -> Paper:
    """Closes the paper's running cohorts in the engine; the next launch of each attempt opens a fresh copy (a new
    question draw). Sittings still open in a closed cohort finish there; unstarted ones are withdrawn by the sync."""
    paper = session.scalar(select(Paper).where(Paper.id == paper_id).with_for_update())
    if paper is None:
        raise NotFound("paper not found", paper_id=str(paper_id))
    for cohort in session.scalars(
        select(Cohort).where(Cohort.paper_id == paper.id, Cohort.state.in_(("draft", "open")))
    ):
        if cohort.state == "open":
            _engine(engine.close, cohort.engine_assessment_id)
        cohort.state = "closed"
    paper.generation += 1
    session.flush()
    return paper


def admin_launch(
    engine: Engine, settings: AssessSettings, caller: uuid.UUID, email: str, verified: bool, name: str, next_path: str
) -> Ticket:
    """A launch URL that signs an operator into the Assessment admin at `next_path` (a relative app path)."""
    if not next_path.startswith("/") or next_path.startswith("//"):
        raise Invalid("next must be a path inside the Assessment app").with_code("invalid_next")
    _engine(engine.ensure_person, str(caller), email, verified, name, "staff")
    ticket: Ticket = _engine(
        engine.ticket, str(caller), "staff", settings.return_url + "/ops/papers", next_path=next_path
    )
    return ticket


# ---------- the worker's side ----------


def _published(session: Session, paper_id: uuid.UUID, lock: bool = False) -> Paper:
    """A worker sees only published papers; a draft is as good as absent, a retired one says so."""
    query = select(Paper).where(Paper.id == paper_id)
    paper = session.scalar(query.with_for_update() if lock else query)
    if paper is None or paper.status == "draft":
        raise NotFound("paper not found", paper_id=str(paper_id))
    if paper.status == "retired":
        raise Conflict("this paper was retired; ops will open a new one", paper_id=str(paper_id)).with_code(
            "paper_retired"
        )
    return paper


def _attempts_used(session: Session, paper_id: uuid.UUID, worker_id: uuid.UUID) -> int:
    return (
        session.scalar(
            select(func.count())
            .select_from(Sitting)
            .where(Sitting.paper_id == paper_id, Sitting.worker_id == worker_id, Sitting.status.in_(FINISHED))
        )
        or 0
    )


def _certified(session: Session, worker_id: uuid.UUID, gate: str) -> bool:
    return session.get(Certification, (worker_id, gate)) is not None


def _current(session: Session, paper_id: uuid.UUID, worker_id: uuid.UUID) -> Sitting | None:
    """The worker's open sitting of this paper, or else their latest one."""
    open_one = session.scalar(
        select(Sitting).where(Sitting.paper_id == paper_id, Sitting.worker_id == worker_id, Sitting.status.in_(OPEN))
    )
    if open_one is not None:
        return open_one
    return session.scalar(
        select(Sitting)
        .where(Sitting.paper_id == paper_id, Sitting.worker_id == worker_id)
        .order_by(Sitting.created_at.desc(), Sitting.id.desc())
        .limit(1)
    )


def brief(session: Session, paper_id: uuid.UUID, worker_id: uuid.UUID) -> BriefView:
    paper = session.get(Paper, paper_id)
    if paper is None or paper.status == "draft":
        raise NotFound("paper not found", paper_id=str(paper_id))
    used = _attempts_used(session, paper.id, worker_id)
    return BriefView(
        paper,
        used,
        max(0, paper.max_attempts - used),
        _certified(session, worker_id, paper.gate),
        _current(session, paper.id, worker_id),
    )


def _cohort(session: Session, engine: Engine, paper: Paper, attempt_no: int) -> Cohort:
    """The running cohort for this attempt number, made when nobody needed it yet. The paper row is locked by the
    caller, so two workers reaching a new attempt number at once make one cohort, not two."""
    found = session.scalar(
        select(Cohort).where(
            Cohort.paper_id == paper.id, Cohort.attempt_no == attempt_no, Cohort.state.in_(("draft", "open"))
        )
    )
    if found is not None:
        return found
    assert paper.engine_base_id is not None
    base_taken = session.scalar(select(Cohort.id).where(Cohort.engine_assessment_id == paper.engine_base_id))
    if attempt_no == 1 and base_taken is None:
        engine_id = paper.engine_base_id
    else:
        name = f"{paper.title} (attempt {attempt_no}, round {paper.generation})"
        engine_id = int(_engine(engine.clone, paper.engine_base_id, name))
    cohort = Cohort(
        paper_id=paper.id, attempt_no=attempt_no, generation=paper.generation, engine_assessment_id=engine_id
    )
    session.add(cohort)
    session.flush()
    return cohort


def _assign(session: Session, engine: Engine, cohort: Cohort, user_id: int) -> bool:
    """Puts the person on the cohort; False when the engine has closed it (v2 closes an assessment once its whole
    roster is submitted and released), which marks it closed here too so the caller makes the next one."""
    try:
        engine.assign(cohort.engine_assessment_id, [user_id])
    except EngineUnavailable as e:
        raise EngineDown("the assessment engine is not answering; try again shortly") from e
    except EngineError as e:
        if e.code != "assessment_closed":
            raise _refused(e) from e
        cohort.state = "closed"
        session.flush()
        log.info("cohort closed by the engine cohort_id=%s", cohort.id)
        return False
    return True


def _link(session: Session, engine: Engine, worker_id: uuid.UUID, email: str, verified: bool, name: str) -> WorkerLink:
    """Who the worker is in the engine, made or refreshed on every launch (an email change in Keycloak follows)."""
    person = _engine(engine.ensure_person, str(worker_id), email, verified, name, "worker")
    link = session.get(WorkerLink, worker_id)
    if link is None:
        link = WorkerLink(worker_id=worker_id, engine_user_id=person.user_id)
        session.add(link)
    link.engine_user_id, link.engine_applicant_id = person.user_id, person.applicant_id
    session.flush()
    return link


def launch(
    session: Session,
    engine: Engine,
    settings: AssessSettings,
    paper_id: uuid.UUID,
    worker_id: uuid.UUID,
    email: str = "",
    verified: bool = False,
    name: str = "",
) -> tuple[Ticket, Sitting]:
    """Puts the worker on the cohort of their next attempt and returns a one-time URL into their exam. An open
    sitting is resumed; one waiting for its result is 409 `result_pending`."""
    paper = _published(session, paper_id, lock=True)
    if worker_id in (paper.created_by, paper.published_by):
        raise Forbidden("you linked, wrote or published this paper and may have read its answers").with_code(
            "paper_author"
        )
    if _certified(session, worker_id, paper.gate):
        raise Conflict("gate already certified", gate=paper.gate).with_code("already_certified")
    sitting = session.scalar(
        select(Sitting).where(Sitting.paper_id == paper.id, Sitting.worker_id == worker_id, Sitting.status.in_(OPEN))
    )
    if sitting is not None and sitting.status == "awaiting_result":
        raise Conflict("your paper is submitted and waits for its result", sitting_id=str(sitting.id)).with_code(
            "result_pending"
        )
    if sitting is None and _attempts_used(session, paper.id, worker_id) >= paper.max_attempts:
        raise Conflict("no attempts left").with_code("attempts_exhausted")
    link = _link(session, engine, worker_id, email, verified, name)
    if sitting is None:
        attempt_no = _attempts_used(session, paper.id, worker_id) + 1
        cohort = _cohort(session, engine, paper, attempt_no)
        if not _assign(session, engine, cohort, link.engine_user_id):
            cohort = _cohort(session, engine, paper, attempt_no)  # the next copy
            _engine(engine.assign, cohort.engine_assessment_id, [link.engine_user_id])
    else:
        found = session.get(Cohort, sitting.cohort_id) if sitting.cohort_id else None
        if found is None:  # a quiz-era live sitting: it cannot be resumed in the engine
            raise Conflict("this sitting predates the Assessment app").with_code("paper_retired")
        cohort, attempt_no = found, sitting.attempt_no or 1
        _engine(engine.assign, cohort.engine_assessment_id, [link.engine_user_id])
    if cohort.state == "draft":
        _engine(engine.launch, cohort.engine_assessment_id)
        cohort.state = "open"
    back = f"{settings.return_url}/work/applications/assessment/{paper.id}"
    ticket: Ticket = _engine(engine.ticket, str(worker_id), "worker", back, assessment_id=cohort.engine_assessment_id)
    if sitting is None:
        sitting = Sitting(
            paper_id=paper.id,
            worker_id=worker_id,
            status="in_progress" if ticket.attempt_state == "in_progress" else "assigned",
            cohort_id=cohort.id,
            attempt_no=attempt_no,
            engine_attempt_id=ticket.evaluator_id,
            engine_state=ticket.attempt_state,
        )
        session.add(sitting)
    elif ticket.evaluator_id and sitting.engine_attempt_id is None:
        sitting.engine_attempt_id = ticket.evaluator_id
    session.flush()
    log.info("paper launched paper_id=%s sitting_id=%s attempt=%s", paper.id, sitting.id, attempt_no)
    return ticket, sitting


def launch_by_exam(
    engine: Engine,
    settings: AssessSettings,
    worker_id: uuid.UUID,
    exam_token: str,
    email: str = "",
    verified: bool = False,
    name: str = "",
) -> Ticket:
    """A fresh launch URL for an exam link the worker already holds: the Assessment app's "Continue with Yantra"
    (a lapsed session, or Safe Exam Browser opening the bare exam link) comes here and goes straight back."""
    if not exam_token or len(exam_token) > 128:
        raise Invalid("exam_token is required").with_code("invalid_exam_token")
    _engine(engine.ensure_person, str(worker_id), email, verified, name, "worker")
    ticket: Ticket = _engine(
        engine.ticket, str(worker_id), "worker", settings.return_url + "/work/applications", exam_token=exam_token
    )
    return ticket


def my_sittings(session: Session, worker_id: uuid.UUID, limit: int = 200) -> list[tuple[Sitting, Paper]]:
    query = (
        select(Sitting, Paper)
        .join(Paper, Paper.id == Sitting.paper_id)
        .where(Sitting.worker_id == worker_id)
        .order_by(Sitting.created_at.desc(), Sitting.id.desc())
        .limit(limit)
    )
    return [(s, p) for s, p in session.execute(query).all()]


# ---------- the sync ----------


def _score(percent: float) -> Decimal:
    return (Decimal(str(percent)) / 100).quantize(PLACES, ROUND_HALF_UP)


def _hold_reason(paper: Paper, a: Any) -> str | None:
    """Why a decided, unreleased attempt is not released by the adapter (None: release it)."""
    if paper.release_policy != "auto_objective":
        return "needs_release"
    if a.integrity_alert:
        return "integrity_review"
    if a.violation_limit_breached:
        return "violation_limit"
    if a.subjective_max:
        return "subjective_answers"
    return None


def _finish(session: Session, sitting: Sitting, paper: Paper, result: str, score: Decimal, now: datetime) -> None:
    """The released result: a pass certifies (the first pass of a gate wins), a fail counts down the attempts."""
    sitting.status = "passed" if result == "pass" else "failed"
    sitting.released, sitting.held_reason, sitting.score = True, None, score
    session.flush()
    subject = f"worker/{sitting.worker_id}"
    if sitting.status == "passed":
        if not _certified(session, sitting.worker_id, paper.gate):
            session.add(
                Certification(worker_id=sitting.worker_id, gate=paper.gate, paper_id=paper.id, score=score, at=now)
            )
        emit(
            session,
            OUTBOX,
            subject,
            AssessCertified(worker_id=sitting.worker_id, gate=paper.gate, paper_id=paper.id, score=score),
        )
    else:
        left = max(0, paper.max_attempts - _attempts_used(session, paper.id, sitting.worker_id))
        emit(
            session,
            OUTBOX,
            subject,
            AssessFailed(
                worker_id=sitting.worker_id, gate=paper.gate, paper_id=paper.id, score=score, attempts_left=left
            ),
        )
    log.info("sitting finished sitting_id=%s paper_id=%s result=%s", sitting.id, paper.id, sitting.status)


def apply_attempt(session: Session, engine: Engine, sitting: Sitting, a: Any, now: datetime) -> bool:
    """Moves one sitting along with the engine's attempt; True when anything changed. Idempotent: a finished
    sitting is never moved again, so re-reading an attempt changes nothing."""
    if sitting.status in ("passed", "failed", "void", "expired"):
        return False
    paper = session.get(Paper, sitting.paper_id)
    assert paper is not None
    before = (sitting.status, sitting.held_reason, sitting.result, sitting.engine_state)
    sitting.engine_state, sitting.deadline = a.state, a.deadline or sitting.deadline
    sitting.started_at, sitting.submitted_at = (
        a.started_at or sitting.started_at,
        a.submitted_at or sitting.submitted_at,
    )
    sitting.flags = {"integrity_alert": a.integrity_alert, "violation_limit_breached": a.violation_limit_breached}
    if a.state == "pending":
        sitting.status = "assigned"
    elif a.state == "in_progress":
        sitting.status = "in_progress"
    else:
        sitting.status, sitting.result = "awaiting_result", a.result
        if a.result not in ("pass", "fail"):
            sitting.held_reason = "llm_scoring"
        elif a.released:
            _finish(session, sitting, paper, a.result, _score(a.score_percent), now)
            return True
        else:
            reason = _hold_reason(paper, a)
            if reason is None:
                cohort = session.get(Cohort, sitting.cohort_id)
                assert cohort is not None
                try:
                    engine.release(cohort.engine_assessment_id, [a.id])
                except EngineError as e:
                    if e.code != "nothing_to_release":  # already released elsewhere: the result stands
                        sitting.held_reason = "release_refused"
                        session.flush()
                        log.warning("auto release refused sitting_id=%s code=%s", sitting.id, e.code)
                        return True
                _finish(session, sitting, paper, a.result, _score(a.score_percent), now)
                return True
            sitting.held_reason = reason
    session.flush()
    return before != (sitting.status, sitting.held_reason, sitting.result, sitting.engine_state)


def _void_stale(session: Session, engine: Engine, now: datetime) -> int:
    """Assigned sittings never started within the paper's `assigned_ttl_days` are taken off the engine's roster
    and voided (a void sitting is not an attempt), so a worker who walked away can come back to a fresh one."""
    voided = 0
    rows = session.execute(
        select(Sitting, Paper, Cohort)
        .join(Paper, Paper.id == Sitting.paper_id)
        .join(Cohort, Cohort.id == Sitting.cohort_id)
        .where(Sitting.status == "assigned")
        .limit(200)
    ).all()
    for sitting, paper, cohort in rows:
        if sitting.created_at + timedelta(days=paper.assigned_ttl_days) > now:
            continue
        link = session.get(WorkerLink, sitting.worker_id)
        if link is not None and link.engine_applicant_id is not None and cohort.state == "open":
            try:
                engine.unassign(cohort.engine_assessment_id, [link.engine_applicant_id])
            except EngineError as e:
                log.warning("unassign refused sitting_id=%s code=%s", sitting.id, e.code)
                continue
        sitting.status = "void"
        voided += 1
    session.flush()
    return voided


def _refresh_snapshots(session: Session, engine: Engine, now: datetime) -> int:
    """Re-reads each published paper's base assessment every few minutes (duration, questions, rules change in the
    Assessment admin); closes cohorts the engine closed and voids their unstarted sittings."""
    refreshed = 0
    for paper in session.scalars(
        select(Paper).where(
            Paper.status == "published",
            Paper.engine_base_id.is_not(None),
            (Paper.snapshot_at.is_(None)) | (Paper.snapshot_at < now - SNAPSHOT_EVERY),
        )
    ):
        assert paper.engine_base_id is not None
        paper.snapshot, paper.snapshot_at = engine.assessment(paper.engine_base_id).snapshot(), now
        refreshed += 1
        for cohort in session.scalars(select(Cohort).where(Cohort.paper_id == paper.id, Cohort.state == "open")):
            if engine.assessment(cohort.engine_assessment_id).state in ("done", "cancelled"):
                cohort.state = "closed"
                for s in session.scalars(
                    select(Sitting).where(Sitting.cohort_id == cohort.id, Sitting.status == "assigned")
                ):
                    s.status = "void"
    session.flush()
    return refreshed


def _awaiting_gauge(session: Session) -> None:
    counts: dict[str | None, int] = dict(
        session.execute(
            select(Sitting.held_reason, func.count())
            .where(Sitting.status == "awaiting_result")
            .group_by(Sitting.held_reason)
        )
        .tuples()
        .all()
    )
    for reason in AWAITING_REASONS:
        ASSESS_AWAITING.labels(reason).set(counts.get(reason, 0))


def sync(session: Session, engine: Engine, now: datetime | None = None) -> int:
    """One pass of the sync job: the engine's attempts changed since the cursor, the stale assignments, the
    snapshots. Returns how many sittings changed. An engine outage raises (the scheduler records the failure)."""
    now = now or datetime.now(UTC)
    cursor = session.get(EngineCursor, CURSOR)
    if cursor is None:
        cursor = EngineCursor(name=CURSOR)
        session.add(cursor)
    attempts, server_time = engine.attempts_since(cursor.since)
    changed = 0
    if attempts:
        by_id = {
            s.engine_attempt_id: s
            for s in session.scalars(
                select(Sitting)
                .where(Sitting.engine_attempt_id.in_([a.id for a in attempts]))
                .with_for_update(skip_locked=True)
            )
        }
        for a in attempts:
            sitting = by_id.get(a.id)
            if sitting is not None and apply_attempt(session, engine, sitting, a, now):
                changed += 1
    cursor.since, cursor.at = server_time - OVERLAP, now
    changed += _void_stale(session, engine, now)
    _refresh_snapshots(session, engine, now)
    session.flush()
    ASSESS_SYNC_LAG.set(0)
    _awaiting_gauge(session)
    return changed
