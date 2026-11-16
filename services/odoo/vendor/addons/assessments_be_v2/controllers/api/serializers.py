# -*- coding: utf-8 -*-
"""Single source of truth for every JSON shape this API emits.

Serialization lives here and NOWHERE else so a field rename in
assessments_be_v2 breaks in one file, and so the domain invariants that are
easy to violate accidentally are enforced structurally rather than by
convention in each controller:

  * ``candidate_result()`` is the ONLY function allowed to emit a
    candidate-facing score, and it refuses to emit anything at all unless the
    attempt is released. score_percent is INTERNAL (it exists to be compared
    against pass_threshold) and never leaves this module on a candidate route.
  * ``question_for_candidate()`` never touches is_correct / the answer key.
    Options are emitted as bare (id, name) so the correct flag has no
    representation to leak through.
"""
import html
import json
import logging
import re

from odoo import fields

from .. import media_stream
from ...constants import GROUP_MANAGER, TRANSCRIPTION_MINOR_LIMIT
from ...services import question_cache, seb, transcript_diff
from ...services.labelling import draft_label_overlay, label_overlay

_logger = logging.getLogger(__name__)

# Candidate-facing bucket labels. The bucket names mirror the web portal's
# _single_item() states exactly so the app and the portal can never disagree
# about which list an attempt belongs in.
STATE_LABELS = {
    "available": "Available",
    "in_progress": "In Progress",
    "upcoming": "Upcoming",
    "completed": "Completed",
    "closed": "Closed",
}

# The web portal maps its 5 states onto 5 chip kinds; carried through verbatim
# so the app can reuse the same colour vocabulary.
STATUS_KIND = {
    "available": "available",
    "in_progress": "progress",
    "upcoming": "locked",
    "completed": "done",
    "closed": "missed",
}

# Question types whose grading is subjective and therefore asynchronous. Kept
# local (rather than imported from constants) so a candidate payload never
# depends on scoring internals.
_SUBJECTIVE_TYPES = ("subjective_rubric", "image_prompt", "image_label",
                     "video_prompt", "transcription")


def wants_justification(question):
    """Whether this question asks the candidate for written prose.

    `image_ab` IS NOT IN `_SUBJECTIVE_TYPES` and must not be: that tuple means
    "graded asynchronously with prose as the only answer", and a comparison is
    marked on its verdicts in code. Its written half is OPTIONAL, chosen per
    question by Form Studio's "Require justification" switch - so it is the one
    type whose answer depends on the record rather than on the type alone.

    THE SWITCH IS READ BACK OFF `official_reasoning`, because publish makes the
    two the same fact: on means a rationale was authored, off means it was
    forced empty (`studio_form._item_spec`). Every other reader of the switch
    derives it the same way, so the textarea, the marks
    (`question._component_counts`) and the judge (`_image_ab_uses_llm`) cannot
    disagree about whether this question has a written half.

    ONLY THE BOOLEAN CROSSES TO THE CANDIDATE. `official_reasoning` is the
    answer key and is a forbidden key on an exam payload
    (`tests/test_api_invariants.py`); "a standard exists" says nothing about
    what the standard says.
    """
    if question.question_type == "image_ab":
        return bool((question.official_reasoning or "").strip())
    return question.question_type in _SUBJECTIVE_TYPES


def iso(value):
    """Datetime -> ISO-8601 UTC string, or None.

    The API speaks UTC only; formatting into the user's timezone is the
    client's job, because the server has no reliable timezone for a mobile
    client and a formatted string cannot be sorted or diffed.
    """
    if not value:
        return None
    return fields.Datetime.to_string(value).replace(" ", "T") + "Z"


def loads(raw, fallback=None):
    """Parse a stored JSON text column, never raising into a response."""
    if not raw:
        return fallback
    try:
        return json.loads(raw)
    except (TypeError, ValueError):
        return fallback


def violation_tally(evaluator, field="violation_log"):
    """Aggregate an evaluator's violation log into a per-reason count.

    `field="ai_violation_log"` tallies the AI proctoring violations, which are
    logged apart (R5).

    Returns [{"reason": str, "count": int}] ordered by count DESCENDING, so the
    reviewer reads the most frequent breach first. `violation_reason` alone only
    ever showed the LATEST event; this is the distribution behind the count.

    A legacy attempt logged before `violation_log` existed carries null, and an
    erased one carries []. Both must serialize as an empty list and never
    crash - the field is `fields.Json`, so a bad shape is possible on old rows,
    and anything that is not the expected list of dicts is treated as empty
    rather than raising into the response.
    """
    log = evaluator[field] or []
    if not isinstance(log, list):
        return []
    counts = {}
    for entry in log:
        if not isinstance(entry, dict):
            continue
        reason = entry.get("reason")
        if reason is None:
            continue
        reason = str(reason)
        counts[reason] = counts.get(reason, 0) + 1
    # Count descending; a stable secondary sort on the reason keeps the output
    # deterministic when two reasons tie, which a test can then pin.
    return [{"reason": reason, "count": count}
            for reason, count in sorted(
                counts.items(), key=lambda kv: (-kv[1], kv[0]))]


def marks_pair(marks):
    """Split a '4 / 10' marks label into (earned, possible), else (0, 0).

    Marks are the only score representation a candidate surface may carry, so
    a KPI that needs arithmetic recovers its two numbers from that label
    instead of reaching for the internal score_percent.
    """
    try:
        earned, possible = (int(p.strip())
                            for p in (marks or "").split("/", 1))
    except (ValueError, TypeError):
        return 0, 0
    return earned, possible


def clamped_percent(value):
    """A stored score percentage, made safe to render as a bar fill.

    Clients draw these the same way the backend dashboard does, so a value
    outside 0-100 (a row left behind by a threshold change) is clamped rather
    than allowed to overflow the track.
    """
    return round(max(0.0, min(100.0, value or 0.0)), 1)


# Identity

def portal_role(user):
    """Coarse client-side role, derived from group membership.

    The app uses this only to decide which screens to draw. It is NOT a
    security boundary: every endpoint re-checks the group it needs, because a
    client can send whatever role string it likes.
    """
    if user.has_group("assessments_be_v2.group_assessment_manager_restricted"):
        # BOTH ADMIN-SHAPED ROLES REPORT "admin" HERE, deliberately. This value
        # decides which SHELL the client draws - the operator console or the
        # candidate surface - and a read-only Manager belongs in the console.
        # Which rows of it they see is `capabilities` and `access_role`, not
        # this. Reporting "member" for a Manager would drop them into My
        # Assessments, which is not a narrower console, it is the wrong one.
        #
        # `_restricted` is the group tested because Admin implies it, so one
        # positive test covers both.
        return "admin"
    # No "pm" any more: that was the Evaluator role, which has been retired.
    # Anyone who is not a Manager is a candidate as far as this app is
    # concerned, and `member` is what opens the candidate surface.
    return "member"


def access_role(user):
    """Which rung of the Assessment v2 ladder this user is on.

    The four values match the field on the user form exactly - `none`,
    `candidate`, `manager`, `admin` - so an operator reading the dropdown and a
    developer reading a payload are looking at the same word.

    ORDERED HIGHEST FIRST, because the groups nest: an Admin holds the Manager
    and Candidate groups too (`implied_ids`), so asking "is this a candidate?"
    first would answer `candidate` for everybody.
    """
    if user.has_group("assessments_be_v2.group_assessment_manager"):
        return "admin"
    if user.has_group("assessments_be_v2.group_assessment_manager_restricted"):
        return "manager"
    if user.has_group("assessments_be_v2.group_assessment_candidate"):
        return "candidate"
    return "none"


#: What each capability unlocks in the console, and which group grants it.
#:
#: `authoring` and `platform` are the two the read-only Manager does NOT get -
#: everything that creates a question or changes how the system runs. The other
#: four are the operator verbs, and they are Admin-only too because a Manager
#: writes nothing at all; they are listed separately because the client already
#: gates individual controls on them and hiding a whole screen is a blunter
#: instrument than disabling its buttons.
CAPABILITIES = (
    "configure",   # edit an assessment's own settings and thresholds
    "launch",      # assign candidates and start a sitting
    "release",     # publish results to candidates
    "lifecycle",   # cancel, archive, reset to draft, re-score
    "authoring",   # Generators, Review Queue, question and tag authoring
    "platform",    # Settings, LLM budget, credentials
)


def capabilities_for(user):
    """The capability names this user holds, for the client to draw with.

    NOT A SECURITY BOUNDARY, exactly like `portal_role` above: every route
    re-checks its own group, because a client can believe whatever it likes.
    This exists so the console can hide what it cannot use instead of showing
    an operator a screen that answers 403 - and so that "hidden" and "refused"
    are derived from the same fact rather than drifting apart.

    ADMIN GETS EVERYTHING; MANAGER GETS NOTHING. That is not an oversight - the
    Manager role is read-only, so it holds no capability at all and the client
    filters its navigation on the surfaces it may READ (see the FE's own
    `operatorNav`). A capability here always means "may change something".

    Tested with `has_groups` and a NEGATION rather than `has_group`, because
    Admin implies Manager: a positive test alone cannot tell the two apart, and
    every Manager would read as an Admin.
    """
    is_admin = user.has_group("assessments_be_v2.group_assessment_manager")
    return list(CAPABILITIES) if is_admin else []


def session_user(user, applicant=None):
    return {
        "uid": user.id,
        "name": user.name,
        "login": user.login,
        "email": user.email or "",
        "partner_id": user.partner_id.id if user.partner_id else None,
        "role": portal_role(user),
        # THE THREE ADMIN-SHAPED ROLES THE CLIENT HAS TO TELL APART. `role` is
        # binary and predates the read-only Manager, so it reports "admin" for
        # both - kept as-is for backward compatibility, because a client that
        # has not been updated must keep working rather than fall through to the
        # candidate surface. `access_role` and `capabilities` are what a current
        # client reads.
        "access_role": access_role(user),
        "capabilities": capabilities_for(user),
        "is_internal": bool(user._is_internal()),
        "lang": user.lang or "en_US",
        "tz": user.tz or "UTC",
        "applicant_id": applicant.id if applicant else None,
        "applicant_name": (applicant.partner_name or "") if applicant else "",
    }


def user_brief(user):
    """One selectable person for the Assign-candidates picker.

    KEYED ON res.users, not hr.applicant. The picker used to offer whoever had
    already sat something, because its list was de-duplicated out of the
    attempts table - so the first assignment of a new person could only be made
    by typing their address into the invite sheet. The directory is the honest
    source: everyone with an account is assignable, and the assign route makes
    the applicant for whoever is picked.

    `email` falls back to the login because the login IS the address this
    module identifies a candidate by - see hr.applicant._be_candidate_user.
    """
    if not user:
        return None
    return {
        "id": user.id,
        "name": user.name or user.login or "",
        "email": user.email or user.login or "",
        "login": user.login or "",
        "is_internal": bool(user._is_internal()),
    }


def applicant_brief(applicant):
    if not applicant:
        return None
    return {
        "id": applicant.id,
        "name": applicant.partner_name or applicant.display_name or "",
        "email": applicant.email_from or "",
        "has_portal_user": bool(applicant.be_candidate_user_id),
    }
    # D1 - THE FLAG IS NOT ADDED HERE, and the omission is the contract.
    #
    # `applicant_brief` is SHARED: `evaluator_admin_row` calls it on admin
    # routes, and it is also reachable from candidate-facing payloads, nested
    # one and two levels down. It is therefore the single realistic path by
    # which an internal annotation reaches the person it is about. The rule is
    # that the flag lives on the ADMIN ATTEMPT ROW (`candidate_flag_block`
    # below, spent only inside `evaluator_admin_row`) and never on the shared
    # brief, so no candidate route has a path to pick it up at all.
    #
    # Enforced rather than merely intended: `tests/test_api_invariants.py`
    # walks every candidate serializer recursively and fails on any flag key at
    # any depth.


def candidate_flag_block(evaluator):
    """D1 - one SITTING's operator flag and internal remark, ADMIN only.

    TAKES AN ATTEMPT, not a person. The flag is per-attempt: a concern about
    the paper somebody sat on Tuesday must not follow them onto the next
    assessment, so there is no person-level state for this to read.

    THE FLAG AND THE REMARK ARE REPORTED INDEPENDENTLY. A remark with no flag
    is a legitimate state - an operator noting something without accusing
    anybody - so the remark is included whether or not `flagged` is true, and
    reading `flagged` is the only way to learn whether a flag stands. Returning
    the remark only alongside a flag would make a note silently invisible the
    moment somebody withdrew the flag beside it.

    ABSENT, NOT `false`, is a rule about the CANDIDATE side and not about this
    one: an admin row always carries the block so the console can render a
    consistent shape, and it is simply never reachable from a candidate route.

    The remark is sent in full. It exists so a decision made months ago can be
    justified, and a truncated justification is worse than none.

    NOTHING SET REPORTS THE TWO KEYS AND STOPS. `by`/`by_id`/`at` describe an
    act that never happened on an untouched attempt, and shipping them empty
    invites a console to render "Raised by  on " - so the caller reads
    `flagged` and `remark`, and the provenance appears only once there is
    provenance to report.
    """
    if not evaluator:
        return {"flagged": False, "remark": ""}
    if not evaluator.manual_flagged and not evaluator.manual_remark:
        return {"flagged": False, "remark": ""}
    return {
        "flagged": bool(evaluator.manual_flagged),
        "remark": evaluator.manual_remark or "",
        "by": (evaluator.manual_flagged_by_id.display_name
               if evaluator.manual_flagged_by_id else ""),
        "by_id": evaluator.manual_flagged_by_id.id or 0,
        "at": iso(evaluator.manual_flagged_at),
    }


# Candidate-facing: attempts, results, dashboard

def attempt_bucket(evaluator):
    """Which of the 5 candidate buckets this attempt falls into.

    Ported line for line from candidate_portal._single_item so the app's
    tabs and the portal's tabs are guaranteed to agree. The order of the
    branches is load-bearing: a submitted/locked attempt is 'completed' even
    when its assessment has since been closed.

    CANCELLED COUNTS AS CLOSED. It used to fall past every branch to the
    'upcoming' default, so an assessment the operator had cancelled told the
    candidate it was still to come - "Opens ..." under a live-looking card -
    when in fact the link would only ever answer "This assessment is closed".
    Cancelled and done are the same fact to a candidate: it is over and they
    cannot sit it. Only `draft` legitimately reaches the default now, and the
    candidate routes filter those out before they ever get here.
    """
    assessment = evaluator.assessment_id
    if evaluator.is_locked or evaluator.state == "submitted":
        return "completed"
    if assessment.state in ("done", "cancelled"):
        return "closed"
    if evaluator.state == "in_progress" and evaluator.started_at:
        return "in_progress"
    if assessment.state == "in_progress":
        return "available"
    return "upcoming"


def candidate_result(evaluator, bucket):
    """The candidate's own result, or an explicit not-yet-released marker.

    INVARIANT 2 + 3: results are never revealed automatically and never as a
    percentage. Until a person sets results_released this returns
    released=False with NO score keys at all - not a null score, not a zero,
    no key - so a client bug cannot render a placeholder as a real mark. Once
    released it returns marks ("4 / 10"), never score_percent.
    """
    if bucket not in ("completed", "closed") or not evaluator.results_released:
        return {
            "released": False,
            "status": "awaiting_results",
            "label": "Awaiting results",
        }
    verdict = evaluator.result if evaluator.result in ("pass", "fail") else ""
    return {
        "released": True,
        "status": "released",
        # INVARIANT 2: marks, never percentages, on a candidate surface.
        "score_marks": evaluator.score_marks_display or "",
        # INVARIANT 4: an unresolved subjective answer holds result at
        # 'pending'; surfaced as-is so the app can say "still grading".
        "result": evaluator.result or "pending",
        # The pass RULE this attempt was judged by - the assessment's, not the
        # candidate's score, which is why invariant 2 still holds with a
        # percentage in the payload. It is here because it is what `result`
        # above MEANS, and no candidate route carries the assessment record
        # that would otherwise state it: without it the app fell back to a
        # hardcoded 70%, re-derived this very attempt against the wrong bar,
        # and drew a released 6/10 PASS as a FAIL.
        "pass_threshold": evaluator.pass_threshold or 0.0,
        "verdict": verdict,
        "is_pending": evaluator.result == "pending",
        "subjective_pending": evaluator.subjective_pending or 0,
        "label": "%s%s" % (evaluator.score_marks_display or "",
                           " - %s" % verdict.upper() if verdict else ""),
        "breakdown": candidate_result_breakdown(evaluator),
    }


def candidate_result_breakdown(evaluator):
    """The released result, split by section - objective, subjective, marks.

    WHY THIS IS HERE. The model already computes exactly this, twice, into
    `result_summary` (staff) and `result_summary_public` (candidate) - and both
    are HTML. The QWeb runner rendered the public one on its completion page, so
    a candidate could see WHERE their marks came from; the API sent neither, so
    the app could only ever print one total. "6 / 10" tells somebody they failed
    and nothing about what to work on.

    STRUCTURED, NOT THE SERVER'S HTML. `result_summary_public` is a styled card
    with inline `background:#f8f9fa` and Bootstrap classes - it belongs to the
    backend's theme, not the app's, and shipping it would mean the client either
    renders foreign markup or strips it. It is also user-adjacent HTML, and the
    one thing worse than an ugly card is an injection surface on a candidate
    screen. The client draws its own rows from these numbers.

    INVARIANT 2 HOLDS: counts and marks, never a percentage of this candidate's
    score. `pass_threshold` is already on the parent payload and is the
    assessment's rule rather than the candidate's result, which is why it may be
    stated at all - see `evaluator_admin_row`'s note on the same point.

    EMPTY WHEN THERE IS NOTHING TO SPLIT. A paper of six objective questions has
    no subjective section, and a section with a zero denominator is noise rather
    than information, so it is omitted and the client renders one row fewer.
    """
    submitted = evaluator.response_ids.filtered(
        lambda r: r.state == "submitted")
    objective = submitted.filtered(lambda r: r.has_objective)
    subjective = submitted.filtered(lambda r: r.needs_llm)
    scored = subjective.filtered(lambda r: r.llm_state == "scored")
    # The switch `exam_answers` passes as `reveal`: a paper that hides answers
    # drops the per-answer verdicts ("correct", "passed") for the marks those
    # answers earned, out of what they were worth.
    reveal = evaluator.assessment_id.results_show_answers
    # Marks add up to the headline, so a written question left blank (never
    # graded, so not `needs_llm`) still counts in the written total.
    written = subjective if reveal else submitted - objective

    def marks(answers):
        return (int(round(sum(answers.mapped("final_mark")))),
                sum(answers.mapped("final_max")))

    rows = []
    if objective:
        # `score >= max_score` is the model's own definition of a fully
        # correct answer; mirroring the comparison rather than the number
        # keeps this from drifting off `result_summary`.
        value, total = (len(objective.filtered(
            lambda r: r.max_score and r.score >= r.max_score)),
            len(objective)) if reveal else marks(objective)
        rows.append({
            "key": "objective",
            "label": "Objective",
            "value": value,
            "total": total,
            "unit": "correct" if reveal else "marks",
        })
    if written:
        value, total = (len(scored.filtered("llm_passed")),
                        len(subjective)) if reveal else marks(written)
        rows.append({
            "key": "subjective",
            "label": "Written",
            "value": value,
            "total": total,
            "unit": "passed" if reveal else "marks",
            # A candidate whose written answers are still being graded is
            # looking at an incomplete figure and has to be told so, or the
            # partial count reads as the final one.
            "pending": len(subjective) - len(scored),
        })
    return rows


def attempt(evaluator):
    """One row of the candidate's 'My Assessments' list."""
    assessment = evaluator.assessment_id
    bucket = attempt_bucket(evaluator)
    total_q = evaluator.total_questions or 0
    answered = evaluator.answered_count or 0
    return {
        "id": evaluator.id,
        "token": evaluator.access_token or "",
        "assessment_id": assessment.id,
        "name": assessment.name or "",
        "state": bucket,
        "state_label": STATE_LABELS.get(bucket, bucket),
        "status_kind": STATUS_KIND.get(bucket, "locked"),
        "progress": {
            "answered": answered,
            "total": total_q,
            "percent": int(round(100.0 * answered / total_q)) if total_q else 0,
        },
        "duration_minutes": assessment.duration_minutes or 0,
        "scheduled_start": iso(assessment.start_date),
        "deadline": iso(evaluator.deadline_datetime),
        # See `server_now` in `exam_state_envelope`.
        "server_now": iso(fields.Datetime.now()),
        "started_at": iso(evaluator.started_at),
        "submitted_at": iso(evaluator.submitted_at),
        # Advisory only (INVARIANT 6): a violation count never changes a mark.
        "proctoring": {
            "is_violated": bool(evaluator.is_violated),
            "violation_count": evaluator.violation_count or 0,
            # The violation limit was reached, in either mode (the model
            # decides it once).
            "violation_limit_breached": bool(
                evaluator.violation_limit_breached),
            "violation_reason": evaluator.violation_reason or "",
            # THE DISTRIBUTION, not just the latest event. Without this the
            # candidate's own card fell through to the client's legacy branch
            # and printed "3 violations recorded. Last reason: Exited
            # fullscreen." on an attempt that had breached three DIFFERENT
            # rules - naming one of them and hiding the rest, on the one
            # screen the candidate can actually see. The admin row has carried
            # the tally since `evaluator_admin_row`; the client already reads
            # `proctoring.violations` here, so this is the key that was
            # missing rather than a new contract.
            "violations": violation_tally(evaluator),
            # The AI proctoring violations, counted apart (R5).
            "ai_violation_count": evaluator.ai_violation_count or 0,
            "ai_violation_limit_breached": bool(
                evaluator.ai_violation_limit_breached),
            "ai_violations": violation_tally(evaluator, "ai_violation_log"),
        },
        # WHY a paper the candidate did not submit came in. "" when they
        # submitted it themselves. Both UIs read this: a candidate whose exam
        # ends under them is owed the reason, and a reviewer looking at a short
        # paper needs to know it was cut off rather than abandoned.
        #
        # THE BOOLEAN IS DERIVED, because there is no such column. The evaluator
        # has no `auto_submitted` field - only a response does - so the clients
        # had nothing on the wire to gate on and inferred it locally, which every
        # refresh then overwrote with False. The reason IS the flag: it is
        # stamped only on a settlement the module drove.
        "auto_submitted": bool(evaluator.auto_submit_reason),
        "auto_submit_reason": evaluator.auto_submit_reason or "",
        "result": candidate_result(evaluator, bucket),
        # Post-release answer review is only reachable once BOTH conditions
        # the portal enforces are true, so the app can hide the button rather
        # than discover a 403.
        "can_review_answers": bool(
            (evaluator.is_locked or evaluator.state == "submitted")
            and evaluator.results_released),
    }


def candidate_dashboard(attempts):
    """Candidate KPIs over their own RELEASED attempts only.

    Mirrors candidate_portal._candidate_kpis. Percentages survive here (avg /
    pass-rate aggregate across assessments, where marks are meaningless), but
    every single-attempt figure carries its marks label alongside, and nothing
    unreleased is counted at all.
    """
    completed = [a for a in attempts if a["state"] == "completed"]
    released = [a for a in completed if a["result"]["released"]]
    taken = len(completed)
    scored = len(released)
    passed = sum(1 for a in released if a["result"]["result"] == "pass")

    def _pct(row):
        # Recovered from the marks string rather than reading score_percent,
        # so the internal percentage never has to travel to build a KPI.
        earned, possible = marks_pair(row["result"].get("score_marks"))
        return round(100.0 * earned / possible, 1) if possible else 0.0

    scores = [_pct(a) for a in released]
    best_row = max(released, key=_pct, default=None)
    breakdown = sorted(
        ({"assessment_id": a["assessment_id"],
          "name": a["name"],
          "score_marks": a["result"].get("score_marks") or "",
          "score_pct": _pct(a),
          "result": a["result"].get("result") or "pending",
          "submitted_at": a["submitted_at"]}
         for a in released),
        key=lambda r: r["score_pct"], reverse=True)
    return {
        "taken": taken,
        "scored": scored,
        "passed": passed,
        "awaiting": taken - scored,
        "avg_score": round(sum(scores) / scored, 1) if scored else 0.0,
        "best_score": max(scores) if scores else 0.0,
        "best_score_marks": (
            best_row["result"].get("score_marks") or "") if best_row else "",
        "pass_rate": int(round(passed / scored * 100.0)) if scored else 0,
        "has_any": taken > 0,
        "breakdown": breakdown,
    }


def candidate_analytics(attempts):
    """Candidate analytics KPIs, in the flat shape an analytics screen wants.

    Same numbers and the same release gate as ``candidate_dashboard`` (which
    is itself a port of candidate_portal._candidate_kpis); this is a second
    PROJECTION of them, not a second computation, so the two can never drift.
    The rows carry marks and NOT a percentage: INVARIANT 2 makes marks the
    only score representation a candidate is shown.
    """
    kpis = candidate_dashboard(attempts)
    per_assessment = []
    for row in kpis["breakdown"]:
        earned, possible = marks_pair(row["score_marks"])
        per_assessment.append({
            "assessment_id": row["assessment_id"],
            "assessment_name": row["name"],
            "score_marks": earned,
            "total_marks": possible,
            "passed": row["result"] == "pass",
            # Always True here: an unreleased attempt never reaches breakdown.
            # Carried anyway so a client reads one row shape whatever the
            # release state, instead of inferring it from a missing key.
            "released": True,
        })
    return {
        "pass_rate": float(kpis["pass_rate"]),
        "avg_score": float(kpis["avg_score"]),
        "best_score": float(kpis["best_score"]),
        "completed": kpis["taken"],
        "passed": kpis["passed"],
        "awaiting": kpis["awaiting"],
        "per_assessment": per_assessment,
    }


def empty_candidate_analytics():
    """The analytics payload for a caller who is not a candidate.

    Zeros and an empty list rather than nulls: "no data yet" is not an error
    state, and a null would force every client to branch on it before it can
    render the very same empty screen these zeros already describe.
    """
    return {
        "pass_rate": 0.0,
        "avg_score": 0.0,
        "best_score": 0.0,
        "completed": 0,
        "passed": 0,
        "awaiting": 0,
        "per_assessment": [],
    }


def leaderboard_row(rank, applicant, attempts, avg_score, best_score, passed):
    """One ranked candidate on the global leaderboard.

    Percentages are correct HERE for the same reason they are on the admin
    analytics route: these aggregate ACROSS assessments, where an "X / N"
    mark from a 10-question paper is not comparable with one from a 40. This
    is a staff-only cross-candidate ranking, not a candidate's own result.
    """
    return {
        "rank": rank,
        "applicant_id": applicant.id,
        "applicant_name": applicant.partner_name or applicant.display_name
        or "Unknown",
        "attempts": attempts,
        "avg_score": clamped_percent(avg_score),
        "best_score": clamped_percent(best_score),
        "passed": passed,
        # D1 - NO FLAG KEY HERE, and the omission is the design. This row
        # aggregates ONE PERSON ACROSS assessments, and the flag belongs to a
        # single sitting: there is no honest value to put here. "Flagged" on a
        # cross-assessment row would either mean "on at least one of these",
        # which reads as an accusation about all of them, or would need a
        # per-attempt breakdown this row has no place for. The flag is read on
        # the attempt row (`evaluator_admin_row`), where it is true.
    }


# Exam runner

def proctoring_rules(assessment, evaluator=None):
    """Proctoring policy for the runner, matching portal._rules_json.

    auto_submit ends the exam when the count reaches max_violations; 0 and 1
    both mean "end on the first violation", and the app must not reinterpret
    0 as "unlimited". log_only never ends the exam, and 0 there means no
    limit. In both modes a reached limit sets `violation_limit_breached` on
    the attempt: the reason auto_submit ended it, the only effect under
    log_only.
    """
    watermark_label = ""
    if evaluator and assessment.rule_watermark:
        applicant = evaluator.applicant_id
        parts = [applicant.partner_name or applicant.display_name or ""]
        if applicant.email_from:
            parts.append(applicant.email_from)
        watermark_label = "  ".join(p for p in parts if p)
    return {
        "tab_switch": bool(assessment.rule_block_tab_switch),
        "copy_paste": bool(assessment.rule_block_copy_paste),
        "right_click": bool(assessment.rule_block_right_click),
        "devtools": bool(assessment.rule_block_devtools),
        "fullscreen": bool(assessment.rule_fullscreen),
        "webcam": bool(assessment.rule_webcam),
        "ai_proctor": bool(assessment.rule_ai_proctor),
        # Eye movement is off for good (19 Oct: the pilot never recorded a
        # flag). Always False, whatever `rule_gaze_review` holds, so no
        # runner, an old cached one included, loads the eye model.
        "gaze_review": False,
        "seb": bool(assessment.rule_require_seb),
        "watermark": bool(assessment.rule_watermark),
        "watermark_label": watermark_label,
        "max_violations": int(assessment.max_violations or 0),
        "violation_action": assessment.violation_action or "log_only",
        "violation_count": int(evaluator.violation_count or 0)
        if evaluator else 0,
        # The same rule for the "AI: " violations, counted apart (R5).
        "ai_max_violations": int(assessment.ai_max_violations or 0),
        "ai_violation_action": assessment.ai_violation_action or "log_only",
        "ai_violation_count": int(evaluator.ai_violation_count or 0)
        if evaluator else 0,
    }


def question_option(option):
    """One selectable option. Deliberately has no is_correct key.

    The answer key must not be representable in a candidate payload, so the
    correct flag is not omitted conditionally - it simply does not exist in
    this shape. There is nothing to forget to strip.
    """
    return {"id": option.id, "name": option.name or ""}


def question_dimension(dimension):
    return {
        "id": dimension.id,
        "name": dimension.name or "",
        "sequence": dimension.sequence or 0,
        # The Form Studio control the examiner drew. Empty means a plain
        # single-choice axis, which is what every axis was before templates
        # could carry a scale or a grid, so old questions read unchanged.
        "input_kind": dimension.input_kind or "",
        "options": [question_option(o)
                    for o in dimension.option_line_ids.sorted("sequence")],
    }


_PUBLIC_VIDEO_HOSTS = re.compile(
    r"^(https?://)?([\w-]+\.)?(youtube\.com|youtu\.be|vimeo\.com)/", re.I)


def _is_public_video_link(url):
    """A public video-HOSTING page (YouTube/Vimeo), not a file this app can
    stream bytes for.

    Mirrors the client's own `publicVideoEmbedRef` host check
    (video_plate.dart) - kept in sync by hand since one lives in Dart and the
    other in Python, with no shared schema to drift silently.
    """
    return bool(url) and bool(_PUBLIC_VIDEO_HOSTS.match(url.strip()))


def admin_video_url(video, bust=False):
    """A URL an ADMIN's `<video>` can actually play.

    THE DEFECT THIS FIXES. The bank/draft payload sent the proxy path
    `/assessments_be/admin_qvideo/<id>` for anything that was not a
    YouTube/Vimeo page. That route does not stream those bytes - it 302s to
    wherever the clip really lives (`media_stream.serve_video`: somebody else's
    URL is handed straight over, ours is presigned). A 302 is fine for a plain
    `<video src>`, and the exam runner uses exactly that, which is why clips
    played for candidates.

    The ADMIN plate cannot use it. `admin_qvideo` is `auth="user"`, so the
    client fetches it with an `Authorization` header - and an XHR that follows
    a cross-origin redirect needs CORS headers FROM THE REDIRECT TARGET. An
    examiner's own CDN does not send them, and neither does S3 without a bucket
    rule, so the browser refused a perfectly good clip and the reviewer saw "No
    video yet for this question." on a question that had one. It is the same
    trap `media_stream.py` documents for images, and it bit videos precisely
    because videos take the redirect path unconditionally.

    So: hand over a URL that needs no redirect and no credential.

      * a public video PAGE (YouTube/Vimeo) - the link, as before
      * any other external URL - the link itself; the proxy could only 302
        there anyway, so the hop bought nothing and cost the preview
      * our own bucket - a presigned URL, which is exactly what the 302 would
        have sent the browser to
      * bytes on the record with no URL at all - the proxy path, which streams
        them and never redirects, so the bearer fetch works

    Nothing is exposed that the 302 did not already hand the same browser.
    """
    def proxy():
        # `bust` is the write stamp the LIST row wants so a replaced clip is
        # not served from cache. It only makes sense on the proxy path - a
        # presigned URL carries its own signature and an external link is not
        # ours to version.
        if bust:
            return _admin_media_url("qvideo", video.id, video.write_date)
        return "/assessments_be/admin_qvideo/%s" % video.id

    url = (video.video_url or "").strip()
    if not url:
        # Inline Binary on the record. The proxy streams it; no redirect.
        return proxy()
    if _is_public_video_link(url):
        return url
    from ...services import s3_service
    try:
        key = s3_service.object_key_from_url(video.env, url)
    except Exception:                                           # noqa: BLE001
        key = None
    if not key:
        # Somebody else's URL. Exactly what serve_video would redirect to.
        return url
    signed = s3_service.presigned_url(
        video.env, key,
        expires=media_stream._presign_seconds(video.env))
    # Could not sign for our own bucket: fall back to the proxy, which logs the
    # real reason rather than handing the player a URL that can only 403.
    return signed or proxy()


def question_media(question, token):
    """Image/video descriptors pointing at the token-scoped portal routes.

    The API returns URLs, not bytes: the existing portal routes already
    presign private S3 and stream ranges, and re-implementing that here would
    fork the media security model.

    A PUBLIC video link (YouTube/Vimeo) is the one exception: `qvideo`
    proxies THIS APP's own stored bytes, and a public host's video is never
    stored here - `video.video_url` IS the whole video, an embeddable page,
    not a file this route could stream. Proxying it anyway fed the browser's
    native `<video>` tag an HTML page as if it were an MP4: no error, just a
    silent 0:00 forever, because there were never any video bytes to decode.
    The client's own embed player only ever activates when it receives the
    real host URL, so serving the proxy path here made every public video
    link dead on the one surface it needed to work: the candidate's exam.
    """
    return _media_urls(*_media_assets(question), token)


def _media_assets(question):
    """The token-free half of `question_media`: asset ids, kinds and flags.

    This is what the question cache holds; `_media_urls` adds the
    candidate's token. Split so a cached question needs no database read to
    produce its URLs.
    """
    images = []
    for image in question.image_ids.sorted("sequence"):
        # ONLY NAME THE OVERLAY WHEN ONE EXISTS.
        #
        # This URL used to be formatted unconditionally, and the client takes a
        # non-empty `annotated_url` as "there is a marked plate, show that one".
        # For a labelling question that is the ONLY plate it shows - and when no
        # overlay had been rendered the route it points at answers 404, so the
        # candidate got a broken image above numbered inputs referring to
        # regions they could not see. The portal has always guarded on the
        # overlay actually existing; this is that guard, on the wire.
        #
        # An empty string is the right absent value: the client reads it as "no
        # overlay" and falls back to the plain plate, where a URL that 404s
        # reads as a broken question.
        # MUST match the route's own gate, not just "an overlay exists".
        # `serve_exam_image` refuses `?annotated=1` for a defect-annotation
        # question because the markers ARE the answer key (Finding L-2). If
        # this advertised the URL anyway, the client would request an overlay
        # the route answers 404 for - the exact broken-plate symptom the
        # comment above describes fixing. One predicate, read from the same
        # place the route reads it.
        # ONE OVERLAY (2026-09-29): a labelling question whose client draws
        # the key's own rectangles must not also get the baked detection
        # picture - two numberings on one image, graded against one of them.
        has_overlay = bool(
            (image.annotated_image or image.annotated_image_url)
            and media_stream.annotated_is_worker_safe(image.question_id)
            and serves_baked_overlay(question))
        images.append({
            "id": image.id,
            "slot": image.slot or "single",
            "label": image.label or "",
            "has_annotated": has_overlay,
        })
    videos = []
    for video in question.video_ids.sorted("sequence"):
        videos.append({
            "id": video.id,
            "slot": video.slot or "single",
            "label": video.label or "",
            # A public host's page is the video itself; anything else streams
            # through the candidate's token route (`_media_urls`).
            "public_url": (video.video_url
                           if _is_public_video_link(video.video_url) else ""),
            "poster_url": video.poster_url or "",
            "duration_s": video.duration_s or 0.0,
            "has_audio": bool(video.has_audio),
            # "audio" plays in an audio player; same qvideo route either way.
            "kind": video.media_kind or "video",
        })
    return images, videos


def _media_urls(images, videos, token):
    """`_media_assets` plus the candidate's token: the shape the exam emits."""
    return [{
        "id": image["id"],
        "slot": image["slot"],
        "label": image["label"],
        "url": "/assessments_be/exam/qimage/%s/%s" % (token, image["id"]),
        "annotated_url": (
            "/assessments_be/exam/qimage/%s/%s?annotated=1"
            % (token, image["id"]) if image["has_annotated"] else ""),
        "has_annotated": image["has_annotated"],
    } for image in images], [{
        "id": video["id"],
        "slot": video["slot"],
        "label": video["label"],
        "url": (video["public_url"]
                or "/assessments_be/exam/qvideo/%s/%s" % (token, video["id"])),
        "poster_url": video["poster_url"],
        "duration_s": video["duration_s"],
        "has_audio": video["has_audio"],
        "kind": video["kind"],
    } for video in videos]


def split_label_answers(question, response):
    """Pull a labelling answer out of the shared `justification` column.

    An image_label answer is stored as a JSON object keyed by box number in the
    SAME column subjective prose uses, so every surface that prints an answer
    has to know that. Only the candidate runner did: the admin screens read an
    empty `labels` and printed "No boxes labelled" over an answer the candidate
    had filled in, and the released review handed the candidate the raw JSON of
    their own answer.

    Returns (justification, label_answers): for a labelling question the prose
    is emptied and the map is populated, for anything else the prose is passed
    through untouched.
    """
    justification = (response.justification or "") if response else ""
    if not response or question.question_type != "image_label":
        return justification, {}
    parsed = loads(justification, None)
    if not isinstance(parsed, dict):
        return justification, {}
    return "", {str(k): v for k, v in parsed.items()}


def question_content(question, label_boxes=None):
    """The half of `question_for_candidate` that is the same for everyone.

    THIS IS WHAT THE QUESTION CACHE STORES (services/question_cache.py), so
    it holds question content only: no index, total or order, no token or
    URL, no saved answer, and no answer key. `label_boxes` is a list or a
    callable returning one, so a cache hit never derives it.
    """
    images, videos = _media_assets(question)
    if callable(label_boxes):
        label_boxes = label_boxes()
    return {
        "name": question.name or "",
        "prompt": question.prompt or "",
        "description": question.description or "",
        # Empty for anything not authored in Form Studio, which the client
        # renders as no heading rather than an invented one.
        "section_title": question.section_title or "",
        "question_type": question.question_type,
        "time_minutes": question.time_minutes or 0,
        "requires_justification": wants_justification(question),
        "dimensions": [question_dimension(d)
                       for d in question.question_dimension_ids.sorted(
                           "sequence")],
        "images": images,
        "videos": videos,
        "label_boxes": label_boxes or [],
    }


#: Every key `question_content` returns: a cached value missing one is a
#: miss, never a KeyError.
CONTENT_KEYS = frozenset((
    "name", "prompt", "description", "section_title", "question_type",
    "time_minutes", "requires_justification", "dimensions", "images",
    "videos", "label_boxes"))


def paper_content(questions, label_boxes):
    """`{question id: content}` for a whole paper (`/paper`), through the
    question cache in one round trip. `label_boxes(question)` is called only
    for what has to be built."""
    return question_cache.fetch_many(
        questions, lambda q: question_content(q, label_boxes(q)),
        CONTENT_KEYS)


def warm_question_cache(questions):
    """Cache every question of a launched paper (`assessment.action_start`),
    built exactly as `/state`, `/begin` and `/answer` build it. Best effort,
    see `question_cache.warm`; everything that can fail runs inside it."""
    def build(question):
        from .candidate import EtpAssessmentApiCandidate
        return question_content(
            question, EtpAssessmentApiCandidate()._label_boxes(question))
    question_cache.warm(questions.sudo(), build)


def question_for_candidate(question, token, index, total, response=None,
                           label_boxes=None, content=None):
    """One exam question as the candidate may see it.

    Carries the prompt, the dimensions with their options, media URLs and any
    previously saved answer. It never carries is_correct, grading_json,
    subjective_rubric_json, solution_json or official_reasoning.

    The content comes from `question_content`, through the question cache
    when one is configured; everything per candidate is built fresh here.
    ONLY WITH `label_boxes` GIVEN: they are an argument, not part of the key,
    so a caller that omits them would cache a labelling question's boxes as
    `[]` for a day. Without them the content is built and never cached.
    `content` given (`paper_content`) is used as is.
    """
    if content is not None:
        pass
    elif label_boxes is None:
        content = question_content(question)
    else:
        content = question_cache.fetch(
            question, lambda: question_content(question, label_boxes),
            CONTENT_KEYS)
    images, videos = _media_urls(content["images"], content["videos"], token)
    selected = []
    justification = ""
    label_answers = {}
    if response:
        selected = response.line_ids.mapped("selected_option_id").ids
        justification, label_answers = split_label_answers(question, response)
    payload = {
        "id": question.id,
        "index": index,
        "total": total,
        "name": content["name"],
        "prompt": content["prompt"],
        "description": content["description"],
        "section_title": content["section_title"],
        "question_type": content["question_type"],
        "time_minutes": content["time_minutes"],
        "requires_justification": content["requires_justification"],
        "dimensions": content["dimensions"],
        "images": images,
        "videos": videos,
        "label_boxes": content["label_boxes"],
        "answer": {
            "answered": bool(response and response.state == "submitted"),
            "selected_option_ids": selected,
            "justification": justification,
            "label_answers": label_answers,
        },
    }
    if question.question_type == "transcription":
        # Which script the candidate types, and their own saved clip answers.
        # The correct ones stay in `solution_json`, which never leaves here.
        payload["transcription_language"] = (
            question.transcription_language or "hi")
        payload["answer"]["clip_answers"] = (
            response._clip_answers() if response else {})
    return payload


def exam_state_envelope(outcome, evaluator=None, extra=None):
    """Uniform gate response for /exam/<token>/state.

    Every outcome carries the same top-level shape so the client has one
    switch on ``outcome`` and never has to probe for optional keys.
    """
    payload = {"outcome": outcome}
    if evaluator is not None:
        assessment = evaluator.assessment_id
        rules = proctoring_rules(assessment, evaluator)
        payload["assessment"] = {
            "id": assessment.id,
            "name": assessment.name or "",
            "state": assessment.state,
            "duration_minutes": assessment.duration_minutes or 0,
            # NESTED, not merely a sibling of "assessment" below.
            #
            # The runner reads its rule set off the ASSESSMENT object it
            # parses out of this envelope, exactly as it does on the admin
            # detail route (see assessment_detail, which has always nested it
            # here). While this lived only at the top level the client's
            # parser looked inside the assessment map, found nothing, and
            # resolved all eight rules to False - so no browser listener was
            # ever attached and proctoring was silently off for every
            # candidate. The key names were right the whole time; only the
            # location was wrong.
            "rules": rules,
            # Hoisted OUT of the rules block for the same reason. The cap and
            # the policy are read from the assessment's own level, and with
            # them missing the client fell back to its own defaults (log-only,
            # cap 3) - which is not what the operator configured.
            "max_violations": rules["max_violations"],
            "violation_action": rules["violation_action"],
            "ai_max_violations": rules["ai_max_violations"],
            "ai_violation_action": rules["ai_violation_action"],
            # The sibling flag was already here; this one was not, so the exam
            # runner had no way to know whether the justification box it draws
            # on an image_ab question is actually marked. It hardcoded "Scored
            # at 25% alongside the verdict" and said that even on an assessment
            # scored on the verdicts alone - telling a candidate their writing
            # carries a quarter of the mark when it carries none.
            # The pass mark, as the percentage `_compute_result` actually
            # applied (already clamped there, so this cannot disagree with the
            # verdict). The instructions page states it to the candidate in
            # MARKS before they begin; with the key absent the app assumed 70%
            # and told a candidate sitting a 60% paper that they needed 7 of 10.
            "pass_threshold": (evaluator.pass_threshold
                               or assessment._effective_pass_threshold()
                               or 0.0),
        }
        payload["attempt"] = {
            "id": evaluator.id,
            "state": evaluator.state,
            "is_locked": bool(evaluator.is_locked),
            "started_at": iso(evaluator.started_at),
            "deadline": iso(evaluator.deadline_datetime),
            # THE SERVER'S CLOCK BESIDE THE DEADLINE. The runner counts down
            # on the device's clock, and `/answer` keeps a late answer only
            # within ANSWER_GRACE_SECONDS of the server's; a device running
            # slow would count past the grace. The client offsets by this.
            "server_now": iso(fields.Datetime.now()),
            "submitted_at": iso(evaluator.submitted_at),
            "total_questions": evaluator.total_questions or 0,
            "answered_count": evaluator.answered_count or 0,
            "results_released": bool(evaluator.results_released),
            # The SERVER's violation tally, which is the only authoritative
            # one: the client counted locally and never reconciled, so a
            # reload reset the count to zero and a candidate got a fresh
            # allowance of violations on every refresh. Advisory for scoring
            # (INVARIANT 6) but decisive for the cap.
            "violation_count": evaluator.violation_count or 0,
            # The violation limit was reached (either mode): the runner shows
            # the label.
            "violation_limit_breached": bool(
                evaluator.violation_limit_breached),
            # The AI pair, authoritative for its own cap the same way (R5).
            "ai_violation_count": evaluator.ai_violation_count or 0,
            "ai_violation_limit_breached": bool(
                evaluator.ai_violation_limit_breached),
            "violation_reason": evaluator.violation_reason or "",
            "is_violated": bool(evaluator.is_violated),
            # Derived, not stored - see `attempt()`. The completion screen gates
            # its whole "why did this end" notice on the boolean, so sending the
            # reason without it left the reason unread.
            "auto_submitted": bool(evaluator.auto_submit_reason),
            "auto_submit_reason": evaluator.auto_submit_reason or "",
        }
        # Kept as a top-level sibling too. It is the shape the route documented
        # first, and anything already reading it here keeps working; the copy
        # nested in "assessment" above is what the runner actually consumes.
        payload["rules"] = rules
        # On every outcome while locked mode is on: the complete screen needs
        # `quit_url` for its Exit Safe Exam Browser button.
        if assessment.rule_require_seb:
            payload["seb"] = seb.links(evaluator)
    if extra:
        payload.update(extra)
    return payload


def _objective_answer_lines(question, response):
    """(chosen, correct) for an mcq/msq, ATTRIBUTED TO THEIR SUB-QUESTION.

    Both lists used to be flattened across every dimension:
    `question_dimension_ids.mapped("option_line_ids").filtered("is_correct")`.
    On a single-axis question that is right and reads fine. On a GRID it threw
    away the only thing that made the answer sheet legible - a three-row grid
    showed three bare column names in a row with nothing saying which row each
    belonged to, and the candidate's own answer was flattened the same way.
    Multi-column keys make it worse: the same grid now has six or more names in
    one undifferentiated line.

    So a multi-axis question is rendered `"Row: A, B"` per axis, which is the
    format `services/export.py` already uses for the reviewer's CSV - the same
    fact should not be shaped two ways. A single-axis question keeps bare names,
    so mcq and checkboxes are byte-identical to before.

    The client joins these with ", " for display and does not parse them
    (`exam_screen.dart`), so this is a rendering change, not a contract change.
    """
    dims = question.question_dimension_ids
    chosen_by_dim = {}
    if response:
        for line in response.line_ids:
            if line.selected_option_id:
                chosen_by_dim.setdefault(
                    line.question_dimension_id.id, []
                ).append(line.selected_option_id.name)

    if len(dims) <= 1:
        correct = dims.mapped("option_line_ids").filtered(
            "is_correct").mapped("name")
        chosen = [n for names in chosen_by_dim.values() for n in names]
        return chosen, [n for n in correct if n]

    chosen_parts, correct_parts = [], []
    for qd in dims:
        picked = [n for n in chosen_by_dim.get(qd.id, []) if n]
        keyed = [ol.name for ol in qd.option_line_ids.filtered("is_correct")
                 if ol.name]
        if picked:
            chosen_parts.append("%s: %s" % (qd.name, ", ".join(picked)))
        if keyed:
            correct_parts.append("%s: %s" % (qd.name, ", ".join(keyed)))
    return chosen_parts, correct_parts


#: Send a candidate only verdicts written under the CURRENT grading
#: instructions. On by default; `0`/`false`/`no`/`off` shows every verdict
#: again. Documented in `docs/ETP_PLANS_AND_STRATEGY.md` §0.5 J (the switch
#: table) and §5.2.
VERDICT_GATE_PARAM = "assessments_be_v2.verdict_requires_current_prompt"


def _verdict_is_for_current_instructions(response):
    """Whether this answer's verdict was written under today's instructions.

    THE VERDICT IS THE ONE ADMIN-ONLY FIELD W12 MADE CANDIDATE-FACING. Every
    verdict written before that decision was addressed to an admin - the old
    prompt said so in as many words ("`feedback` IS THE ONLY THING YOU WRITE
    THAT THE CANDIDATE READS") - so a historical one may name profiles, caps,
    thresholds or point arithmetic. `llm_prompt_version` records exactly which
    instructions graded an answer, so comparing it with the fingerprint in
    force is the whole test; an answer with no recorded version (graded before
    versioning existed) is never current.

    BEHIND A SWITCH: `VERDICT_GATE_PARAM = 0` shows every verdict again
    without a deploy - a product decision, never a deploy step. Never raises
    and never drops the key: a withheld verdict is the empty string, and the
    app shows `score_verdict` only when it is non-empty.
    """
    try:
        icp = response.env["ir.config_parameter"].sudo()
        raw = str(icp.get_param(VERDICT_GATE_PARAM, "1") or "").strip().lower()
        if raw in ("0", "false", "no", "off"):
            return True
        from ...services import scoring as scoring_svc
        return bool(response.llm_prompt_version) and (
            response.llm_prompt_version
            == scoring_svc.current_scoring_prompt_version())
    except Exception as exc:  # noqa: BLE001 - a review page never dies
        # WITHHOLD ON DOUBT: the failure mode this guards is a leak, so the
        # safe answer when the check itself breaks is "not current".
        # One line, no traceback: this runs once per answer.
        from .common import request_evaluator_id
        _logger.warning("etp_assessment verdict gate check failed (%s: %s); "
                        "withholding the verdict evaluator_id=%s",
                        type(exc).__name__, exc, request_evaluator_id())
        return False


def released_answer_review_row(index, question, response, token,
                               label_boxes=None, reveal=True):
    """One POST-RELEASE review row, mirroring portal._build_answer_review.

    CARRIES THE QUESTION'S MEDIA, same shape and same token-scoped routes as
    `question_for_candidate`. It did not, and this was the only serializer in
    this file that rendered a question to a candidate with the pictures
    stripped out: the review screen showed "Response A, Both Good" over an
    image_ab pair the candidate could no longer see, and a labelling answer as
    a numbered list with no screenshot above it. An answer sheet that omits
    what the question was asking about is not a review of anything.

    The exam media routes are `auth="public"` and scoped by the token in the
    path (`controllers/exam_media.py`), with no submitted/locked gate, so the
    URLs the live exam used keep working here - no second media lane needed.

    CALLER MUST HAVE CHECKED `results_released`. The name says "released"
    because this row carries the answer key: `correct` holds the names of the
    right options for mcq/msq, and `verdict` is a live Correct/Incorrect read
    off stored computes that settle the instant an answer is saved. It was
    once called `answer_review_row`, and the pre-submit checklist picked it up
    on that generic name - handing every in-progress candidate the key to every
    objective question. The only legitimate caller is `exam_answers`, which
    gates on submitted AND released. Anything pre-submit wants
    `_review_payload`, which has no representation for correctness.

    Emits the grader's itemized verdict/deductions/credit only for a genuinely
    scored subjective answer - the verdict only when it was written under the
    current instructions (`_verdict_is_for_current_instructions`) - and the
    raw grader score as a 0-1 decimal (the admin 'Raw Score' convention),
    never as a percentage.

    ``reveal=False`` (the paper's `results_show_answers` off, R6): the row
    keeps the candidate's own answer, marks and tags, and blanks the key and
    the grader's judgement - `correct`, `score_raw`, `feedback`,
    `score_verdict`, `deductions`, `credit`, and a Correct / Incorrect /
    Partly correct / Passed / Failed verdict (kind `info`). A status such as
    "Not answered" or "Awaiting grading" stays. Every key stays, because an
    older app reads them unconditionally.
    """
    qtype = question.question_type
    images, videos = question_media(question, token)
    justification, label_answers = split_label_answers(question, response)
    # THE PLACEHOLDER IS NOT THE CANDIDATE'S ANSWER. `_auto_submit_expired`
    # fills each unanswered question with "[Auto-submitted: time expired]" (or
    # the force-submit / proctoring variant) in `justification`. Blanked, so
    # the client shows "You did not answer this question." instead of the
    # system string under "Your answer".
    if response and response.auto_submitted:
        justification = ""
    chosen, correct, score_raw = [], [], None
    if qtype in ("mcq", "msq"):
        # PER SUB-QUESTION, not one flat list across all of them. See
        # `_objective_answer_lines`.
        chosen, correct = _objective_answer_lines(question, response)
        if not response:
            verdict, kind = "Not answered", "info"
        elif response.auto_submitted:
            # AHEAD OF THE SCORE COMPARISONS, mirroring the subjective branch
            # below: an expiry placeholder is a submitted response scoring 0
            # against a real `max_score`, which would otherwise read
            # "Incorrect" for a question the candidate never saw.
            verdict, kind = "Not answered", "info"
        elif response.max_score and response.score >= response.max_score:
            verdict, kind = "Correct", "pass"
        elif response.max_score and response.score:
            # PARTLY CORRECT IS A REAL OUTCOME NOW, and saying "Incorrect"
            # here was a lie the candidate could check. Each sub-question is
            # marked on its own, so a candidate who got two of three right
            # earned two marks; the old two-state label told them they got the
            # question wrong while their score said otherwise.
            verdict = "Partly correct (%d of %d)" % (
                response.score, response.max_score)
            kind = "partial"
        else:
            verdict, kind = "Incorrect", "fail"
    else:
        chosen = response.line_ids.mapped("selected_option_id").mapped("name") \
            if response else []
        # A transcription answered only by its category (the clip is not
        # transcribed) has an empty box and is still an answer.
        answered = justification or chosen or label_answers or (
            qtype == "transcription" and response
            and response._transcription_has_answer())
        if not response or not answered:
            verdict, kind = "Not answered", "info"
        elif response.llm_state == "scored":
            verdict = "Passed" if response.llm_passed else "Failed"
            kind = "pass" if response.llm_passed else "fail"
            # `llm_raw_score`, NOT `response.raw_score`, and it stays that way.
            # The answer-level raw now spans every component, objective ones
            # included; this row is the candidate's own view of ONE graded
            # written answer, so the graded component's own number is the only
            # one that belongs here. Swapping it for `raw_score` would add the
            # question's objective marks into a figure labelled as their
            # written grade, and hand them the objective breakdown with it.
            score_raw = round(response.llm_raw_score or 0.0, 3)
        elif response.auto_submitted:
            # A time-expiry placeholder is never sent to the grader, so it has
            # no grade at all - distinct from "still awaiting" one.
            verdict, kind = "No Grade", "info"
        else:
            verdict, kind = "Awaiting grading", "info"
    scored_subjective = bool(
        response and qtype not in ("mcq", "msq")
        and response.llm_state == "scored")
    row = {
        "index": index,
        "question_id": question.id,
        "name": question.name or "Question %s" % index,
        "prompt": question.prompt or question.name or "",
        "question_type": qtype,
        # Same keys `question_for_candidate` emits, so the client parses a
        # review row's media with the code that already parses a live one.
        "images": images,
        "videos": videos,
        # The NUMBERS only, exactly as during the exam. They say which marker
        # each typed answer belongs to; the labels themselves are the key and
        # travel in `correct` or not at all.
        "label_boxes": label_boxes or [],
        "chosen": chosen,
        "correct": correct,
        "justification": justification,
        # Same derivation as the live payload, so a review row agrees with
        # the question the candidate actually answered about whether it had a
        # written half at all.
        "requires_justification": wants_justification(question),
        "label_answers": label_answers,
        # The candidate's OWN category / characteristics / speakers, so their
        # review shows what they answered. Never the key.
        **({"clip_answers": response._clip_answers()}
           if qtype == "transcription" and response else {}),
        "verdict": verdict,
        "kind": kind,
        "score_raw": score_raw,
        # THE CANDIDATE'S OWN MARKS ON THIS ANSWER, as a pair.
        #
        # ALWAYS READ AS A PAIR: a question is worth one mark per component
        # (each keyed sub-question, the graded write-up, the labelling box
        # set), so "2" means nothing without the "3" beside it.
        #
        # WHY THIS IS NOT A LEAK. The candidate already reads this figure in
        # prose - `verdict` above says "Partly correct (2 of 3)" - and their
        # attempt total has always been candidate-facing as `score_marks`
        # ("7 / 18"). What the review must never carry is how the platform
        # WEIGHS an answer: the lane weights, the thresholds, the judge's
        # internal audit. A candidate's own marks on their own answer are what
        # they did, not how it was decided, and tests/test_api_invariants.py
        # pins that distinction.
        #
        # WITHOUT IT the candidate's strengths/weaknesses panel had no mark to
        # group by and weighted every question as 1, so a 3-mark question
        # counted the same as a 1-mark one and every category percentage that
        # mixed the two was wrong.
        "marks_earned": round(response.final_mark or 0.0, 2) if response else 0,
        "marks_available": (response.final_max or 0) if response
        else question._component_counts()[0],
        # THE CATEGORIES THIS ANSWER EXERCISED, for the candidate's own
        # strengths/weaknesses breakdown.
        #
        # Same source and same spelling as `response_row`'s `tags`: the names
        # live on the QUESTION, and an answer has none of its own. Sent here as
        # well because this is the ONLY route a candidate has that carries their
        # per-answer marks - `/me/assessments` is a list of sittings with no
        # answers in it, so without this key the candidate side of the feature
        # has nothing to group and silently renders no panel.
        #
        # SAFE TO SEND: this route is already gated on `results_released` (it is
        # what `can_review_answers` reports), and a tag names a skill, never a
        # mark or an answer key.
        "tags": [t.name for t in question.tag_ids],
        "feedback": (response.llm_feedback or "").strip()
        if scored_subjective else "",
        "score_verdict": (response.llm_verdict or "").strip()
        if scored_subjective and _verdict_is_for_current_instructions(response)
        else "",
        "deductions": score_lines(response.llm_deductions_json)
        if scored_subjective else [],
        "credit": score_lines(response.llm_credit_json)
        if scored_subjective else [],
    }
    if not reveal:
        row.update(correct=[], score_raw=None, feedback="", score_verdict="",
                   deductions=[], credit=[])
        if row["kind"] in ("pass", "fail", "partial"):
            row.update(verdict="", kind="info")
    return row


def score_lines(raw_json):
    """Parse a deductions/credit JSON column into clean dicts, never raising."""
    data = loads(raw_json, [])
    out = []
    for entry in data if isinstance(data, list) else []:
        if not isinstance(entry, dict):
            continue
        row = {
            "reason": str(entry.get("reason") or "").strip(),
            "evidence": str(entry.get("evidence") or "").strip(),
        }
        points = entry.get("points")
        if points is not None:
            try:
                row["points"] = int(round(float(points)))
            except (TypeError, ValueError):
                row["points"] = None
        if row["reason"] or row["evidence"]:
            out.append(row)
    return out


# Admin: assessments

def assessment_row(assessment):
    """Assessment list row: identity, lifecycle and roll-up counters."""
    return {
        "id": assessment.id,
        "name": assessment.name or "",
        "state": assessment.state,
        "active": bool(assessment.active),
        "generator": {
            "id": assessment.generator_id.id,
            "name": assessment.generator_id.name or "",
        } if assessment.generator_id else None,
        "question_limit": assessment.question_limit or 0,
        "questions_available": assessment.total_questions_available or 0,
        "duration_minutes": assessment.duration_minutes or 0,
        # The effective bar, never 0: older rows follow subjective_threshold.
        "pass_threshold": assessment._effective_pass_threshold() or 0.0,
        "start_date": iso(assessment.start_date),
        # Rows launched before `launched_at` existed have none; launch wrote
        # `start_date` (now, unless pre-scheduled), the nearest stand-in. Only
        # for a paper that launched: a draft's, or one cancelled straight from
        # draft, is only a schedule, so those get none.
        "launched_at": iso(assessment.launched_at or (
            assessment.state in ("in_progress", "done")
            and assessment.start_date)),
        "end_date": iso(assessment.end_date),
        "candidate_count": len(assessment.evaluator_ids),
        "assigned_count": len(assessment.assessment_evaluator_ids),
        "submitted_count": assessment.submitted_count or 0,
        "releasable_count": assessment.releasable_count or 0,
        "released_count": assessment.released_count or 0,
        "awaiting_scoring_count": assessment.awaiting_scoring_count or 0,
        "response_count": assessment.response_count or 0,
        "invite_summary": assessment.invite_summary or "",
        # THE RUN, AS DISTINCT FROM THE WORK LEFT. `awaiting_scoring_count`
        # above is "attempts with an ungraded subjective answer", which stays
        # high for a cohort nobody has queued and for one an admin already
        # killed. The console was gating its Kill button on a client-side walk
        # of `attempts` to work around that, and that cache is a global,
        # page-capped read - so at roster scale the button's visibility
        # depended on how much of the cohort happened to be loaded. These two
        # are the server's own answer, computed from the drainer's selection
        # predicate, so every surface gates on the same fact.
        "scoring_phase": assessment.scoring_phase or "idle",
        "scoring_summary": assessment.scoring_summary or "",
        "scoring_scored": assessment.scoring_scored_count,
        "scoring_candidates": assessment.scoring_candidate_count,
        "scoring_finished_at": iso(assessment.scoring_finished_at),
        "create_date": iso(assessment.create_date),
    }


def assessment_detail(assessment):
    """Assessment row plus its full policy block.

    subjective_threshold IS returned here: on an admin surface the pass bar is
    the thing being configured, and it is the assessment's property, not a
    candidate's score.
    """
    data = assessment_row(assessment)
    data.update({
        # THE OPERATOR THINKS IN "SHUFFLE", THE MODEL STORES "KEEP ORDER".
        #
        # `preserve_question_order` is the stored truth, but it was never
        # serialized, so the config screen had no way to show or set it and the
        # operator could not tell whether a paper was being shuffled. The screen
        # asks the affirmative question - "shuffle the questions?" - so it is
        # exposed as its inverse rather than surfacing a double-negative
        # ("keep authored order = off") nobody reads correctly under pressure.
        # No column is added: this is a view onto the field that already exists.
        "shuffle_questions": not assessment.preserve_question_order,
        "subjective_threshold": assessment.subjective_threshold or 0.0,
        "results_release": assessment.results_release or "manual",
        "llm_auto_score": bool(assessment.llm_auto_score),
        "require_reviewed_rubric": bool(assessment.require_reviewed_rubric),
        "threshold_recompute_pending": bool(
            assessment.threshold_recompute_pending),
        # The ROSTER, as distinct from the attempts.
        #
        # `/candidates` lists `assessment_evaluator_ids` - the per-candidate
        # ATTEMPT records - and those only exist after launch. On a draft the
        # roster lives in `evaluator_ids` (hr.applicant), so somebody invited
        # to a draft was stored correctly and then displayed nowhere: the
        # Assign tab kept reading "0" and the invitation looked like it had
        # failed. Only `candidate_count` was exposed, which could say "1" while
        # no screen could name who.
        "roster": [
            {
                "id": a.id,
                "name": a.partner_name or a.email_from or "",
                "email": a.email_from or "",
            }
            for a in assessment.evaluator_ids
        ],
        # The QUESTIONS actually selected onto this assessment.
        #
        # Only `questions_available` (a COUNT) used to be exposed, so a client
        # had no way to name a single selected question. The Flutter detail
        # screen derives its heading and its marks denominator from the length
        # of this list, so its absence rendered "0 questions" and a score of
        # "0 / 0" on an assessment that plainly had 11 questions and a graded
        # attempt. A count cannot stand in for the rows: the Selected Questions
        # tab has to list them.
        #
        # bank_question_row is reused rather than a bespoke shape so the bank
        # screen and this tab cannot drift apart.
        "questions": [
            bank_question_row(q)
            for q in assessment.question_ids.sorted(lambda q: q.sequence)
        ],
        "pool": assessment_pool(assessment),
        "rules": proctoring_rules(assessment),
        # Also at this level, not only inside "rules". The admin form binds the
        # cap and the policy from the assessment's own fields, so nested-only
        # meant the editor opened showing its client-side defaults instead of
        # the stored values - and saving then wrote those defaults back.
        "max_violations": int(assessment.max_violations or 0),
        "violation_action": assessment.violation_action or "log_only",
        "ai_max_violations": int(assessment.ai_max_violations or 0),
        "ai_violation_action": assessment.ai_violation_action or "log_only",
        # Read when a released candidate opens their review (R6).
        "results_show_answers": bool(assessment.results_show_answers),
        # 0 = follows `subjective_threshold`. Detail-only, like that one (R7).
        "transcription_threshold": assessment.transcription_threshold or 0.0,
        # The detail is readable by the read-only Manager too
        # (`require_operator`), so the password goes to an Admin only and
        # every other role gets null (the app then hides Copy and Renew). Never
        # in a candidate payload: the candidate's .seb carries only its hash.
        "seb_quit_password": (assessment.seb_quit_password or "")
        if assessment.env.user.has_group(GROUP_MANAGER) else None,
    })
    return data


def assessment_pool(assessment):
    """Every question this assessment MAY draw from, each flagged in or out.

    "questions" above is the SELECTION; this is the CHOICE the selection was
    made from, so the operator can narrow a launch without editing the
    generator. Without it the client could only ever show what was already
    picked, which on a draft is nothing at all - `question_ids` is empty until
    `action_start` writes it, so the Selected Questions tab read "0 questions"
    on a draft whose generator held 20.

    ON A DRAFT the pool is the generator's servable set, filtered exactly as
    `action_start` filters it. Listing anything looser would offer a question
    the launch then declines to draw, which is the same class of lie
    `_launch_gates` was fixed for.

    ONCE LAUNCHED the pool is still the generator's servable set unioned with
    the selection, and rows outside the selection come back `in_use: False`.
    This used to be `question_ids` alone - "the paper is the instrument and is no
    longer a choice" - and the consequence was that a question the operator
    deliberately un-ticked before launching VANISHED from the tab: the row count
    dropped from 9 to 8 and nothing anywhere distinguished "excluded on purpose"
    from "never existed". The tick is the record of that decision and this tab is
    where it is read, so an excluded row stays listed and unticked. The client
    renders every tick inert once launched either way, so nothing here becomes
    editable that was not before.

    `in_use` DEFAULTS TO TRUE ON AN EMPTY SELECTION. An untouched draft has no
    shortlist, and "no shortlist" means the whole generator - not an empty
    paper. Reading empty as "nothing ticked" would show every question greyed
    out on a draft nobody had shortlisted yet.

    READ WITH `active_test=False`, for the same reason `action_start` does. Odoo
    applies the active filter to an x2many read, so an archived question does not
    just leave the pool - it leaves `question_ids`, and this tab would then
    report a DIFFERENT shortlist from the one the operator wrote. The two must
    agree: the note at the top of `action_start`'s narrowing says so, and the
    empty case is exactly where they used to part company.
    """
    selected = set(
        assessment.with_context(active_test=False).question_ids.ids)
    # THE SELECTION IS ALWAYS IN THE POOL. Retiring or unpublishing a question
    # after it was ticked drops it from the search below, so it would vanish from
    # this list while remaining in `question_ids` - and the launch would then
    # draw a paper the operator was never shown. Its row already carries
    # `active`/`servable` so the client can mark it as the problem it is.
    pool = assessment.question_ids
    if assessment.generator_id:
        pool |= assessment.env["assessments.be.question"].search([
            ("generator_id", "=", assessment.generator_id.id),
            ("active", "=", True),
            ("retired", "=", False),
        ]).filtered(
            lambda q: q._has_required_images() and q._has_required_videos())
    rows = []
    for q in pool.sorted(lambda q: (q.sequence, q.id)):
        row = bank_question_row(q)
        row["in_use"] = (q.id in selected) if selected else True
        rows.append(row)
    return rows


def evaluator_admin_row(evaluator, with_link=False):
    """One candidate row on an admin screen.

    score_percent appears HERE and only here: an admin is the audience the
    internal percentage exists for (it is what pass/fail is decided against).
    No candidate route may call this function.

    pass_threshold is the exception, and deliberately not exclusive to this
    function: a candidate is TOLD the pass mark before they sit (invariant 2
    only forbids their own score as a percentage, and the module's own
    result_summary_public states the threshold too). `candidate_result` and
    `exam_state_envelope` emit it for that reason.

    `with_link` controls the candidate's ACCESS TOKEN, and it defaults to
    False. The token is not an identifier - it is a bearer credential: anyone
    holding it can open /exam/<token> and sit that person's paper as them,
    with no password. It was on every row of every admin list, which put a
    working impersonation link for the entire cohort into one response that
    any Evaluator could fetch (and into that browser's cache, and any log or
    proxy on the way). Detail routes opt in for a Manager, because copying the
    link is a real thing a Manager does when an invitation does not arrive.
    """
    data = {
        "id": evaluator.id,
        "assessment_id": evaluator.assessment_id.id,
        "assessment_name": evaluator.assessment_id.name or "",
        "candidate": applicant_brief(evaluator.applicant_id),
        "state": evaluator.state,
        "is_locked": bool(evaluator.is_locked),
        "invite_state": evaluator.invite_state or "none",
        "invite_error": evaluator.invite_error or "",
        "started_at": iso(evaluator.started_at),
        "submitted_at": iso(evaluator.submitted_at),
        "deadline": iso(evaluator.deadline_datetime),
        "total_questions": evaluator.total_questions or 0,
        "answered_count": evaluator.answered_count or 0,
        "score_marks": evaluator.score_marks_display or "",
        "score_percent": evaluator.score_percent or 0.0,
        "pass_threshold": evaluator.pass_threshold or 0.0,
        # ALWAYS AS A PAIR. `raw_result` alone is unreadable - the client used
        # to recover the denominator by summing `raw_max` across `answers`,
        # which only the detail route sends, so every list route printed a bare
        # number. `raw_max` is the paper's component count, the same
        # denominator `score_marks` uses.
        "raw_result": evaluator.raw_result or 0.0,
        "raw_max": evaluator.raw_max or 0,
        "raw_percent": evaluator.raw_percent or 0.0,
        "result": evaluator.result or "pending",
        "results_released": bool(evaluator.results_released),
        "objective": {
            "score": evaluator.objective_total or 0,
            "max": evaluator.objective_max_total or 0,
        },
        "subjective": {
            "score": evaluator.llm_total_score or 0,
            "max": evaluator.llm_max_score or 0,
            "pending": evaluator.subjective_pending or 0,
            "state": evaluator.llm_state or "pending",
            "error": evaluator.llm_error or "",
            "scored_at": iso(evaluator.llm_scored_at),
            "scoring_requested": bool(evaluator.scoring_requested),
            # INVARIANT 5: a terminal error is never retried automatically;
            # this flag is the admin's cue to run Reset & Re-score by hand.
            "has_terminal_error": bool(evaluator.scoring_error_flag),
        },
        # INVARIANT 6: both flags are advisory review signals. They are
        # reported so a human can look, and they never alter a score.
        "flags": {
            "integrity_alert": bool(evaluator.integrity_alert),
            "score_outlier": bool(evaluator.score_outlier),
            "is_violated": bool(evaluator.is_violated),
            "violation_count": evaluator.violation_count or 0,
            # The violation limit was reached (either mode): the "Violation
            # limit breached" label.
            "violation_limit_breached": bool(
                evaluator.violation_limit_breached),
            "violation_reason": evaluator.violation_reason or "",
            # The distribution behind the count: every reason with how many
            # times it fired, most frequent first. `violation_reason` above is
            # only the latest event; a reviewer answering an appeal needs the
            # whole tally. A legacy attempt with a null/empty log serializes as
            # [] here, never a crash.
            "violations": violation_tally(evaluator),
            # The AI proctoring violations, counted apart (R5), and whether
            # the AI ran on the candidate's device at all (R9d).
            "ai_violation_count": evaluator.ai_violation_count or 0,
            "ai_violation_limit_breached": bool(
                evaluator.ai_violation_limit_breached),
            "ai_violations": violation_tally(evaluator, "ai_violation_log"),
            "ai_status": evaluator.ai_status or "",
            "pii_anonymized": bool(evaluator.pii_anonymized),
            # D1. Sits BESIDE the advisory flags, never inside their meaning:
            # `flagged_only` on the API still selects exactly the three
            # machine-derived signals above, and the manual one is reached by
            # its own `manual_flagged_only` parameter (requirement 3.6).
            "manual_flagged": bool(evaluator.manual_flagged),
            # Eye-movement review flags (count). Advisory like the rest and,
            # like `manual_flagged`, NOT part of `flagged_only`.
            "review_flags": len(evaluator.review_flags or []),
        },
        "review_flag_count": len(evaluator.review_flags or []),
        # D1 - the flag, the remark, and who raised it, for THIS sitting.
        # Admin-only by construction: this function's own docstring records
        # that no candidate route may call it.
        "candidate_flag": candidate_flag_block(evaluator),
        # Derived, not stored - see `attempt()`. The roster's "Auto" badge and
        # the attempt detail's KPI both read the boolean.
        "auto_submitted": bool(evaluator.auto_submit_reason),
        "auto_submit_reason": evaluator.auto_submit_reason or "",
    }
    if with_link:
        data["access_token"] = evaluator.access_token or ""
        data["candidate_link"] = evaluator.candidate_link or ""
    return data


def launch_gate(code, label, passed, reason=""):
    return {"code": code, "label": label, "passed": bool(passed),
            "reason": reason or ""}


# Admin: generators, drafts, bank

def generator_row(generator):
    return {
        "id": generator.id,
        "name": generator.name or "",
        "active": bool(generator.active),
        # Deleted with its history kept: inactive too, never restorable.
        "deleted": bool(generator.deleted),
        "state": generator.state or "draft",
        "sop_title": generator.sop_title or "",
        "sop_gen_state": generator.sop_gen_state or "idle",
        "sop_gen_error": generator.sop_gen_error or "",
        # WHAT THE LAST RUN YIELDED, always - not only when it errored. A run
        # that returns items and has every one rejected is not an error, and it
        # is also not a success; the console needs the counts to say so.
        "sop_gen_report": generator.sop_gen_report or "",
        # The latest run's window; null on runs from before it was recorded.
        "sop_gen_started_at": iso(generator.sop_gen_started_at),
        "sop_gen_finished_at": iso(generator.sop_gen_finished_at),
        # THE KILL SWITCH, as two separate facts the client must not conflate.
        #
        # `can_cancel` is whether the button should be offered at all;
        # `sop_gen_cancel_requested` is whether a kill is already in flight and
        # the run has simply not reached its next checkpoint yet. Without the
        # second, pressing Kill looked like it had done nothing for up to a
        # cron tick and invited a second press.
        "sop_gen_cancel_requested": bool(generator.sop_gen_cancel_requested),
        "sop_gen_cancelled_at": iso(generator.sop_gen_cancelled_at),
        "can_cancel_generation": (
            generator.sop_gen_state in generator.CANCELLABLE_GEN_STATES),
        "tag_extract_state": generator.tag_extract_state or "idle",
        "tag_extract_error": generator.tag_extract_error or "",
        # Stop pressed on Extract skills, not yet settled ("Stopping...").
        "tag_extract_cancel_requested": bool(
            generator.tag_extract_cancel_requested),
        "tag_extract_last_run": iso(generator.tag_extract_last_run),
        "question_count": generator.question_count or 0,
        "approved_count": generator.approved_count or 0,
        "resource_count": generator.resource_count or 0,
        "similar_count": generator.similar_count or 0,
        "tags": [tag_row(t) for t in generator.tag_ids],
        "plain_tags": generator.plain_tags or "",
        "create_date": iso(generator.create_date),
        # The console's "Owner" column (Generator.owner, a plain string). A
        # generator has no owner field, so it is whoever made it.
        "owner": generator.create_uid.name or "",
    }


def similarity_row(pair):
    """One persisted, directed similarity pair.

    THE SCORES STAY 0-100. The module stores and labels them as percentages
    ("Match %"), and rescaling to 0-1 here would mean two representations of
    the same number in one system, with the band thresholds (>=75, 40-74)
    stated in only one of them.

    `mode` is carried because it is an honest-degradation record: a semantic
    pass that failed its retries is filed as 'lexical-fallback', never
    'hybrid'. Dropping it would let a lexical-only number be read as blended.
    """
    return {
        "id": pair.target_id.id,
        "pair_id": pair.id,
        "name": pair.target_id.name or "",
        "score": pair.overall or 0,
        "lexical": pair.lexical or 0,
        "semantic": pair.semantic or 0,
        "band": pair.band or "new-territory",
        "mode": pair.mode or "lexical",
        # Two different kinds of reason, and they are not interchangeable:
        # `evidence` is computed from the mapping arrays and always present,
        # `why` is the model's prose and empty on a lexical-only row. The
        # client shows whichever it has, preferring the model's.
        "why": pair.why or pair.evidence or "",
        "evidence": pair.evidence or "",
        "computed_on": iso(pair.computed_on),
    }


def generator_detail(generator):
    """Generator row plus the analysed-SOP artefacts, grouped into tabs.

    The heavy *_json columns are parsed once here rather than shipped raw, so
    the client never has to double-decode a string inside JSON.
    """
    data = generator_row(generator)
    data.update({
        # THE RANKED PAIRS THEMSELVES, which nothing sent before.
        #
        # Only `similar_count` was serialized, so the client's Similarity tab -
        # which reads the pair list - was empty on every generator, forever,
        # including ones with a full ranking stored. It read "No similar
        # generators" beside a badge saying otherwise, and no amount of
        # re-running the ranking could change it.
        "similar": [similarity_row(s) for s in generator.similarity_source_ids],
        "sop_summary": generator.sop_summary or "",
        "source_text": generator.source_text or "",
        "question_count_mode": generator.question_count_mode or "",
        "sop_question_count": generator.sop_question_count or 0,
        # PER-SHAPE COUNTS the examiner set: {"mcq": 2, "template:7": 3}. The
        # screen derives its total from these, so it must read back exactly what
        # generation will honour.
        "shape_quotas": loads(generator.shape_quota_json, {}),
        # EVERY task the SOP defines, each with its own answer contract. One
        # entry for a single-task SOP; more when the SOP teaches several jobs.
        "tasks": loads(generator.tasks_json, []),
        "task_count": generator.task_count or 0,
        # Not `or DEFAULT`: the field is required-with-a-default and
        # constrained >= 1, so a falsy value here means the column is
        # genuinely unset (a row predating the field) - and the client
        # needs to see that rather than be shown a default the server
        # is not actually applying.
        "image_label_count": generator.image_label_count or 0,
        "image_label_live_capture": bool(generator.image_label_live_capture),
        "force_question_type": generator.force_question_type or "",
        # The types this generator is allowed to author, and whether the form's
        # "select all" is on. The client had to guess: it defaulted to a
        # hardcoded 12 questions and an empty type list, so the Generation tab
        # showed "0 selected" over a generator that had produced 5 drafts from
        # one type. `allowed_question_type_ids` is the field the Odoo form
        # binds, so it is the one an API client needs.
        "allowed_types": [
            t.code for t in generator.allowed_question_type_ids if t.code
        ],
        "select_all_types": bool(generator.select_all_types),
        # Question STRUCTURES are a feature of the host module that may not be
        # present: it arrived as uncommitted work, so a checkout without it has
        # no `structure_mode` and attribute access would raise, taking the whole
        # generator payload down with it. Absent means "the module does not do
        # structures here", which the client already renders as empty.
        "structure_mode": getattr(generator, "structure_mode", "") or "",
        "structure_count": getattr(generator, "structure_count", 0) or 0,
        "selected_structure_count": getattr(
            generator, "selected_structure_count", 0) or 0,
        "structure_extract_state": getattr(
            generator, "structure_extract_state", "") or "idle",
        "last_extract_summary": generator.last_extract_summary or "",
        "tabs": {
            "analysis": {
                "metadata": loads(generator.metadata_json, {}),
                "mapping": loads(generator.mapping_json, {}),
                "skills": loads(generator.skills_json, []),
                "evidence": loads(generator.evidence_json, []),
            },
            "requirements": {
                "required_elements": loads(
                    generator.required_elements_json, []),
                "covered_by_all": loads(generator.covered_by_all_json, []),
                "question_spec": loads(generator.question_spec_json, {}),
                "rating_scheme": loads(generator.rating_scheme_json, {}),
            },
            "quality": {
                "quality_criteria": loads(generator.quality_criteria_json, []),
                "failure_modes": loads(generator.failure_modes_json, []),
                "gaps": loads(generator.gaps_json, []),
                "conflicts": loads(generator.conflicts_json, []),
                "injection_flags": loads(generator.injection_flags_json, []),
            },
            "resources": [resource_row(r) for r in generator.resource_ids],
        },
    })
    return data


def resource_row(resource):
    return {
        "id": resource.id,
        "name": resource.name or "",
        # 'golden' is the old name of the sample list; `init()` renames rows.
        "category": ("sample" if resource.category == "golden"
                     else resource.category or "other"),
        "status": resource.status or "pending",
        "char_count": resource.char_count or 0,
        # The stored size, off the ATTACHMENT not the record: `file` is a Binary
        # with attachment=True, so there is no `file_size` field here and reading
        # one raised AttributeError, 500ing the whole generator payload. Without
        # a size the corpus tab could not tell a 6 MB PDF from an empty one - a
        # PDF is never text-extracted, so char_count is 0 either way.
        "file_size": _attachment_bytes(resource),
        "extraction_error": resource.extraction_error or "",
        "sequence": resource.sequence or 0,
    }


def _attachment_bytes(resource):
    """Stored byte count for a resource's file, or 0 when it has none.

    `sudo` because an operator who may read the generator may not have direct
    ir.attachment access, and a size is not privileged information. Failure
    returns 0 rather than raising: a missing size is a cosmetic gap, and it is
    not worth losing the record it belongs to.
    """
    try:
        att = resource.env["ir.attachment"].sudo().search(
            [("res_model", "=", resource._name),
             ("res_id", "=", resource.id),
             ("res_field", "=", "file")],
            limit=1)
        return att.file_size or 0
    except Exception:  # pragma: no cover - defensive, size is never critical
        return 0


def draft_media(draft):
    """A draft's staged images and clips as URLs, never as bytes.

    WHAT THIS REPLACES. Both lists used to be the raw `images_json` /
    `video_files_json`, whose `data` key holds a whole base64 `data:` URI. An
    image_ab draft carries two of them at a few hundred KB each, and the review
    queue re-fetches the detail route on every card it moves to - so walking the
    queue shipped roughly a megabyte per keystroke, and a staged mp4 is worse.

    The proxy routes already exist for exactly this (`admin_draft_qimage` /
    `admin_draft_qvideo`): they presign private S3, fall back to streaming the
    inline data, and gate on the reviewer's own read access to the draft. The
    client already sends its bearer to `/assessments_be/admin_` URLs, which is
    how every bank image on the same screens is loaded, so this needs nothing
    new on either side.

    Built from `_image_specs()` / `_video_files()` - the SAME parse the serving
    route does - so a URL emitted here can never name a slot that route cannot
    resolve.

    `data` is REMOVED rather than left alongside: the client reads `data` first,
    so leaving it in means the URL is never used and nothing improves.
    """
    stamp = int(fields.Datetime.to_datetime(draft.write_date).timestamp()) \
        if draft.write_date else 0

    def _url(kind, slot):
        # ?v= mirrors the bank's admin URLs. Without it the browser serves a
        # cached picture after `apply_image` replaces one - the single moment a
        # reviewer must see the new bytes.
        return "/assessments_be/admin_draft_q%s/%s/%s?v=%s" % (
            kind, draft.id, slot, stamp)

    # ONE overlay, the one the approved question will carry.
    label_mode = draft_label_overlay(draft)[0]
    images = []
    for position, spec in enumerate(draft._image_specs()):
        slot = spec.get("slot") or "single"
        annotated = bool(spec.get("annotated_url") or spec.get("annotated_data"))
        plain = annotated and slot == "single" and label_mode == "regions"
        annotated = annotated and not plain
        has_source = bool(annotated or spec.get("url") or spec.get("data")
                          or spec.get("src"))
        images.append({
            # A staged spec has no record id. A stable synthetic one lets the
            # client key a widget per slot; '' would collide across slots.
            "id": "%s-%s" % (draft.id, slot),
            "slot": slot,
            "label": spec.get("label") or "",
            # Empty, not a URL, when nothing is staged - the client reads an
            # empty string as "absent" and renders its own missing-stimulus
            # state, whereas a URL that 404s reads as a broken image.
            "admin_url": ((_url("image", slot) + ("&plain=1" if plain else ""))
                          if has_source else ""),
            # One URL per slot. The route prefers the overlay, except with
            # `&plain=1`, added above when the one overlay is drawn
            # client-side ("regions").
            "has_annotated": annotated,
            "sequence": (position + 1) * 10,
        })

    videos = []
    for position, spec in enumerate(draft._video_files()):
        slot = spec.get("slot") or "single"
        has_source = bool(spec.get("url") or spec.get("data"))
        videos.append({
            "id": "%s-%s" % (draft.id, slot),
            "slot": slot,
            "label": spec.get("label") or "",
            "admin_url": _url("video", slot) if has_source else "",
            "poster_url": spec.get("poster_url") or "",
            "duration_s": spec.get("duration_s") or 0.0,
            "has_audio": bool(spec.get("has_audio")),
            "sequence": (position + 1) * 10,
        })
    return images, videos


def draft_dimensions(draft):
    """A draft's answer key as the axis tree the reviewer is signing off.

    WHY THIS EXISTS. `draft_detail` used to send `dimensions_json`, which the
    generator fills for `image_ab` and NOTHING else. For an mcq or msq it is
    empty, so the client received `dimensions: []` for a question whose key was
    sitting in `options_json`/`correct_answer_json` all along - five options and
    three correct answers rendered as an empty option list under a red "No
    answer key", on a draft Odoo displayed in full.

    THE RESOLUTION ORDER IS `_dimension_specs`' ORDER, DELIBERATELY. That method
    (prompt.py) is what `_materialize_dimensions` publishes from at approve time:
    the relational `answer_dimension_ids` rows win, and the JSON is only the
    fallback they were built from. Serializing anything else would show a
    reviewer a key that is not the one approving would publish, which is worse
    than showing none.

    The JSON fallback goes through the model's own `_specs_from_json` rather
    than re-parsing here, because that method owns `_normalize_correct` - the
    string / casefolded-string / integer-index resolution a correct answer may
    arrive as. A second answer-key parser would disagree with the first on
    exactly the rows that are already wrong.

    Admin-only, like the rest of this shape. INVARIANT 1 is unaffected: this is
    a DRAFT, which by definition is not servable to a candidate, and the
    candidate's own `question_dimension`/`question_option` pair is untouched -
    it still has no `is_correct` key to leak.
    """
    rows = []
    for dimension in draft.answer_dimension_ids.sorted("sequence"):
        options = dimension.option_line_ids.sorted("sequence")
        # An axis with no options is not a key; `_dimension_specs` skips it and
        # so must this, or the two disagree about whether a key exists.
        if not any(o.name for o in options):
            continue
        rows.append({
            "id": dimension.id,
            # `label` is the draft spelling; the bank calls the same idea
            # `name`. Each side is named after its own column so a field rename
            # upstream breaks in one file. The client reads either.
            "label": dimension.label or "",
            "sequence": dimension.sequence or 0,
            # See `bank_question_detail` for why the scoring type alone is not
            # enough to name the control. Stored per axis by
            # `_sync_dimensions`, and sent to the candidate already.
            "input_kind": dimension.input_kind or "",
            "options": [{
                "id": option.id,
                "name": option.name or "",
                "sequence": option.sequence or 0,
                "is_correct": bool(option.is_correct),
            } for option in options if option.name],
        })
    if rows:
        return rows

    # No relational rows: project the JSON specs into the same shape. `id` is
    # None rather than a placeholder because these records genuinely do not
    # exist yet - the client's `jid(None)` gives '', which `_sync_dimensions`
    # reads as "create me".
    try:
        specs = draft._specs_from_json()
    except Exception:  # pragma: no cover - a malformed draft must still render
        specs = []
    out = []
    for index, spec in enumerate(specs):
        correct = {str(c).strip().casefold() for c in spec.get("correct") or []}
        out.append({
            "id": None,
            "label": spec.get("label") or "",
            "sequence": (index + 1) * 10,
            # `_specs_from_json` spells the same field `kind`, which is the
            # spelling `_sync_dimensions` reads back when it materialises these
            # specs into rows - so the two branches of this function agree.
            "input_kind": spec.get("kind") or "",
            "options": [{
                "id": None,
                "name": name,
                "sequence": (position + 1) * 10,
                "is_correct": str(name).strip().casefold() in correct,
            } for position, name in enumerate(spec.get("options") or [])],
        })
    return out


def draft_key_valid(draft, dimensions=None):
    """Whether this draft's answer key can score anything.

    Derived FROM `draft_dimensions` rather than computed beside it, so the flag
    and the tree can never disagree - that divergence is the whole bug this
    fixes.

    DELIBERATELY LOOSER THAN THE BANK'S `has_valid_key`, which requires an
    image_label question to hold BOTH drawn boxes and a key. A DRAFT is the one
    place where holding the key first is legitimate: the defect lane stamps its
    markers at render time, and the detect-after-render lane fills
    `detections_json` later still, so a draft that has a key and no geometry yet
    is mid-pipeline rather than broken. Flagging it here would put a blocking
    badge on every labelling draft in the queue before the renderer had run.
    Nothing is at stake in being loose: a draft is unreviewed by definition and
    can never be served to a candidate. The bank flag is what stands between a
    keyless labelling question and an exam, and the marker-shortfall and
    missing-box warnings are what tell the reviewer before they approve.

    Every other non-mcq/msq type is valid by default: those are graded by a
    rubric, not by a correct option, and the client's own `isObjective` draws
    the line in exactly the same place.
    """
    if draft.question_type not in ("mcq", "msq"):
        return True
    rows = draft_dimensions(draft) if dimensions is None else dimensions
    return any(o["is_correct"] for row in rows for o in row["options"])


def draft_row(draft):
    """One draft in the review queue.

    INVARIANT 1 lives on the OTHER side of this shape: a draft is by
    definition unreviewed, so nothing here is ever servable to a candidate.
    Drafts are admin-only, which is why the answer key is safe to include -
    approving it is precisely the review being asked for.

    THE ANSWER KEY IS ON THE ROW, NOT ONLY THE DETAIL. Two reasons, both
    load-bearing:

      * The review queue renders its per-draft warnings from the LIST payload.
        `has_valid_key` absent from a row means the client falls back to "no
        key", so every objective draft in the queue carried a BLOCKING "No
        answer key" badge - over a key the server had stored correctly.
      * The client replaces its draft cache wholesale on every refresh, and a
        refresh follows every mutation. Anything only the detail route carries
        survives until the next action and then vanishes.

    It costs a few hundred bytes on a ~700-byte row, against a list that clamps
    at 200 - and far less than the base64 images this route no longer sends.
    """
    dimensions = draft_dimensions(draft)
    return {
        "id": draft.id,
        "name": draft.name or "",
        "generator": {
            "id": draft.prompt_id.id,
            "name": draft.prompt_id.name or "",
        } if draft.prompt_id else None,
        "state": draft.state or "draft",
        "question_type": draft.question_type or "",
        "medium": draft.medium_display or "",
        "difficulty": draft.difficulty or "",
        "time_minutes": draft.time_minutes or 0,
        "prompt": draft.question_prompt or "",
        "description": draft.description or "",
        "generation_status": draft.generation_status or "",
        "image_state": draft.image_state or "",
        # null when no reason was stored: the app then shows its own text.
        "image_error": draft.image_error or None,
        "video_state": draft.video_state or "",
        "video_error": draft.video_error_short or draft.video_error or "",
        "has_images": bool(draft.has_images),
        "has_video_clips": bool(draft.has_video_clips),
        "has_dimensions": bool(draft.has_dimensions),
        "approved_question_id": draft.approved_question_id.id
        if draft.approved_question_id else None,
        # Authoring smells the reviewer must look at before approving.
        "warnings": {
            "revealing_option": bool(draft.has_revealing_option),
            "source_reference": bool(draft.has_source_reference),
        },
        "gen_batch": draft.gen_batch or "",
        "gen_batch_label": draft.gen_batch_label or "",
        # Why this draft needs a closer look before approval. Nothing is dropped
        # any more, so this is the only signal that an item was coerced or
        # failed a shape check.
        "gen_warnings": draft.gen_warnings or "",
        # WHETHER THE RATIONALE EXISTS, on the LIST row.
        #
        # The full `official_reasoning` paragraph is detail-route only, which is
        # right - it is long and no list renders it. But the review queue builds
        # its quality badges from list rows, and with no field to read it
        # assumed the rationale was missing: every A/B question in the queue was
        # badged "No answer rationale" while the rationale sat on the page right
        # next to it. A boolean is all the badge needs.
        "has_official_reasoning": bool(draft.official_reasoning),
        # WHETHER A MARKING GUIDE EXISTS, on the LIST row - the third field to
        # need this and for the identical reason as the two above.
        #
        # THE DEFECT. `bank_question_row` sends `has_rubric`; this row did not.
        # The client's `Question.warnings` raises "No rubric" whenever
        # `type.isSubjective && !hasRubric`, and an absent key parses as false -
        # so the SAME question was badged correctly in the Review Queue (built
        # from bank rows) and warned about nothing in the generator's Drafts tab
        # (built from these), or warned when the guide was there. A reviewer
        # comparing the two screens saw them disagree about a draft neither of
        # them had changed.
        #
        # READ FROM `rubric_json`, WHICH IS WHERE A DRAFT KEEPS IT. The question
        # field is `subjective_rubric_json` and `action_approve` copies one into
        # the other (models/prompt.py) - so reading the question's spelling here
        # would raise AttributeError, and reading it defensively would report
        # "no rubric" for every draft ever written. Same emptiness test as the
        # bank row: "[]" and "{}" are stored when a rubric was attempted and
        # came back empty, and they are not a marking guide.
        "has_rubric": bool(
            (draft.rubric_json or "").strip() not in ("", "[]", "{}")),
        # WHAT THE EXAMINER CALLED THIS TASK. A template-authored draft is a
        # reproduction of a shape a human named ("Verify a single photo edit"),
        # and labelling it with the internal engine type instead - "Image A/B" -
        # tells the reviewer nothing about which task they are approving, and
        # actively misleads when the task is not an A/B comparison at all.
        "source_template": (
            {"id": draft.source_template_id.id,
             "name": draft.source_template_id.name or ""}
            if draft.source_template_id else None),
        # THE FLAT ANSWER KEY, for the SAME reason `dimensions` is here.
        #
        # THE DEFECT THIS FIXES. `showDraftEditor` is handed the LIST ROW - the
        # review queue, the generator's Drafts tab and the assessment preview
        # all pass the cached row, never a detail fetch. The editor seeds its
        # option rows from `options` + `correct_answer`, and those two lived
        # ONLY in `draft_detail`. So opening Edit Draft on an mcq showed Title,
        # Question, Description, Time, Rationale, Difficulty - and NO options
        # section at all, over a draft with four options and a key the review
        # card was rendering correctly two inches above the pencil. Measured on
        # draft 197 (4 options, key "...Anatomy class."): the sheet ended at
        # DIFFICULTY.
        #
        # A reviewer therefore could not fix the one thing this editor exists to
        # fix - "fix it here rather than denying and regenerating" - and a save
        # from that sheet posted an EMPTY option list over a good key.
        #
        # Same argument the docstring makes for `dimensions` above: the client
        # replaces its draft cache wholesale on every refresh, so anything only
        # the detail route carries is not there when the editor opens.
        "options": loads(draft.options_json, []),
        "correct_answer": loads(draft.correct_answer_json, None),
        # The answer key, and the verdict derived from it. See the docstring.
        "dimensions": dimensions,
        "dimension_count": len(dimensions),
        # Named for the bank's stored field of the same meaning, so the client
        # reads one key for both models.
        "has_valid_key": draft_key_valid(draft, dimensions),
    }


def draft_detail(draft):
    """Draft row plus everything the Odoo draft form shows.

    `dimensions` is NOT re-sent here. The row already carries the published
    answer key, and this route used to overwrite it with `dimensions_json` - a
    DIFFERENT field with a different meaning, empty for every mcq and msq. A
    detail route silently narrowing a key the row got right is the trap that
    produced the original bug; the raw column is still available, under
    `advanced.raw`, where it cannot be mistaken for the key.

    `options` and `correct_answer` stay: they are the shape `/drafts/<id>/update`
    accepts, so the editor round-trips through them.
    """
    data = draft_row(draft)
    images, videos = draft_media(draft)
    data.update({
        "answer_key": {
            "ideal_answer": draft.ak_ideal_answer or "",
            "mandatory_elements": draft.ak_mandatory_elements or "",
            "penalty_rules": draft.ak_penalty_rules or "",
            "scoring_guide": draft.ak_scoring_guide or "",
            "checklist": draft.ak_checklist or "",
            "constraints": draft.ak_constraints or "",
            "pass_condition": draft.ak_pass_condition or "",
        },
        "options": loads(draft.options_json, []),
        "correct_answer": loads(draft.correct_answer_json, None),
        "rubric": loads(draft.rubric_json, {}),
        "solution": loads(draft.solution_json, {}),
        "solution_rationale": draft.solution_rationale or "",
        "covers_elements": loads(draft.covers_elements_json, []),
        "official_reasoning": draft.official_reasoning or "",
        # The numbering the approved question will be graded on, and only
        # drawable geometry when that overlay is drawn client-side.
        "label_boxes": (draft_label_overlay(draft)[1]
                        if draft.question_type == "image_label"
                        else loads(draft.label_boxes_json, [])),
        "images": images,
        "image_briefs": loads(draft.image_brief_json, []),
        "video_briefs": loads(draft.video_brief_json, []),
        "video_files": videos,
        # Everything else the module stores about this draft.
        #
        # NESTED, not eighteen more top-level keys: these are pipeline
        # artefacts, not part of the contract every screen reads, and the group
        # says so. It also keeps names like `source_url` from sitting beside
        # `images[].url` and meaning something else.
        #
        # They are here because `action_approve` PUBLISHES them - the flaw plan,
        # the verification record, the behavioural key and the capture
        # directives all end up on the bank question or its image - so a
        # reviewer needs them BEFORE deciding, not after. Most appear on no Odoo
        # form at all, which is the gap this closes rather than mirrors.
        "advanced": {
            "flaw_plan": loads(draft.flaw_plan_json, None),
            "verification": loads(draft.verification_json, None),
            "defect_plan": loads(draft.defect_plan_json, None),
            "behavioural_key": loads(draft.behavioural_key_json, []),
            "coverage_expected": draft.coverage_expected or "",
            "omitted_element": loads(draft.omitted_element_json, None),
            "label_application": draft.label_application or "",
            "detection_mode": draft.detection_mode or "",
            "source_url": draft.source_url or "",
            "capture_config": loads(draft.capture_config_json, None),
            "omit_spec": loads(draft.omit_spec_json, None),
            "image_summary": draft.image_summary or "",
            "image_render_attempts": draft.image_render_attempts or 0,
            "gen_batch": draft.gen_batch or "",
            # The original LLM output, grouped the way the Odoo form groups it
            # under "Advanced (raw JSON)" - behind a banner saying the published
            # key is the one above. Presenting these as peers of `dimensions`
            # would invite a client to edit the wrong thing.
            "raw": {
                "options_json": draft.options_json or "",
                "correct_answer_json": draft.correct_answer_json or "",
                "dimensions_json": draft.dimensions_json or "",
                "rubric_json": draft.rubric_json or "",
            },
        },
    })
    return data


def _admin_media_url(kind, record_id, write_date):
    """The ACL-checked admin proxy URL for one media record.

    ``?v=`` is the write stamp, mirroring `draft_media`: without it a browser
    keeps serving the cached picture after an admin replaces one, which is the
    single moment the new bytes have to be seen.

    Built from the id rather than read off `question.image.image_admin_url`
    because that computed field depends on an ``attachment=True`` binary - see
    the note in `bank_question_row`.
    """
    stamp = int(fields.Datetime.to_datetime(write_date).timestamp()) \
        if write_date else 0
    return "/assessments_be/admin_%s/%s?v=%s" % (kind, record_id, stamp)


def bank_question_row(question):
    """One approved bank question, admin view.

    ``servable`` is the machine-checkable form of INVARIANT 1: a question only
    reaches a candidate when it is active, has a usable answer key and carries
    the media its type requires. Anything false here is silently skipped at
    launch, so it is surfaced explicitly rather than discovered post-hoc.
    """
    return {
        "id": question.id,
        "name": question.name or "",
        "question_type": question.question_type or "",
        "difficulty": question.difficulty or "",
        "prompt": question.prompt or "",
        "description": question.description or "",
        "time_minutes": question.time_minutes or 0,
        "sequence": question.sequence or 0,
        "active": bool(question.active),
        # THE SKILLS THIS QUESTION COVERS.
        #
        # Copied down from the generator by "Backfill onto questions", and
        # editable afterwards. Sent as the canonical names the vocabulary uses
        # rather than as ids: every tag surface in the client - the bank rows,
        # the generator's own chips, the Tags screen - already speaks names,
        # and an id here would be the only place that did not.
        "tags": [t.name for t in question.tag_ids],
        # A BANK QUESTION IS APPROVED BY DEFINITION - it only exists because a
        # human approved a draft into the bank.
        #
        # This key was absent, and the client parses a missing state to
        # `DraftState.draft`. Every bank row therefore looked like a draft, so
        # opening one fetched `/api/v1/drafts/<id>` - a DIFFERENT record, on a
        # different sequence - and rendered that instead. The preview showed no
        # options and an empty answer key (a draft keeps its key as flat text,
        # not as dimension records), and the edit button offered the draft
        # editor for a live bank question. On a database where the two id
        # sequences have diverged it would show another question's content
        # under this one's title.
        "state": "approved",
        "generator": {
            "id": question.generator_id.id,
            "name": question.generator_id.name or "",
        } if question.generator_id else None,
        # WHICH SOP THIS CAME FROM, in words. `generator` above carries the id
        # and the name, but a question whose generator has been deleted keeps
        # neither - `generator_id` is ondelete="set null" - and `source_ref` is
        # stamped at approval time, so it still names the SOP that authored it.
        # It is the only attribution an orphaned question has left.
        "source_ref": question.source_ref or "",
        # WHAT THE EXAMINER CALLED THIS TASK, same key and same shape the draft
        # row sends. The client's `Question.taskLabel` prefers it over the
        # engine type, so a bank question authored from a template reads as the
        # task a human named rather than as the renderer that drew it -
        # "Labelling" told a reviewer nothing about which task they were
        # looking at, and actively misled when the task was not a labelling job.
        "source_template": (
            {"id": question.source_template_id.id,
             "name": question.source_template_id.name or ""}
            if question.source_template_id else None),
        # How many assessments use it. The client has parsed this key since it
        # was written and the server never sent it, so every bank row reported
        # "used in 0" - including questions sitting on a live paper.
        #
        # Read off the m2m rather than counted per row: `assessment_ids` is
        # prefetched across the whole list in one query.
        "used_in": len(question.assessment_ids),
        # Out of the bank, but still on every paper that used it. Only visible
        # at all when the caller asked for `include_retired`, so a row carrying
        # True is one the operator went looking for.
        "retired": bool(question.retired),
        # Deleted with its history kept: retired too, never restorable.
        "deleted": bool(question.deleted),
        "has_subjective": bool(question.has_subjective),
        "rubric_reviewed": bool(question.rubric_reviewed),
        # THE CONTROL THIS QUESTION WAS AUTHORED AS, as one scalar.
        #
        # A SCALAR AND NOT THE AXIS TREE, unlike `bank_question_detail`. This
        # row is the list shape - the bank screen and an assessment's Selected
        # Questions tab both read it, and the bank list clamps at 200 - so
        # embedding every axis and every option on every row to recover one
        # string would multiply the payload for a field that is the same on
        # every axis of a question anyway.
        #
        # WHY IT IS NEEDED AT ALL. `question_type` is a closed set of seven
        # SCORING primitives, so `dropdown`, `linearScale`, `rating` and
        # `multipleChoice` all store as `mcq` - correctly, because all four are
        # marked identically. That makes the type unable to name the control,
        # and this row carried no `dimensions` at all, so the client had nothing
        # else to read: every Form Studio question published from the designer
        # reported itself as "Objective - MCQ" on the Selected Questions tab
        # and as "MCQ" in the generator's question list, whatever the examiner
        # actually drew. Annotation and prompt-writing looked right only because
        # they happen to own distinct `question_type` codes.
        #
        # First axis that names one: a grid stamps its kind on every row and
        # they always agree, and a single-axis question has exactly one.
        "designer_kind": next(
            (d.input_kind for d in question.question_dimension_ids
             if d.input_kind), ""),
        # PRESENCE, NOT PROSE.
        #
        # The client computes its quality warnings from whatever a row carries,
        # and this row carried neither the rubric nor the answer rationale - so
        # every subjective question in the bank list showed "No rubric" and
        # every image_ab showed "No answer rationale", over records holding
        # both. Opening one fetched the DETAIL route, which has the text, and
        # the warning vanished: a count that contradicted the thing it counted.
        #
        # Booleans rather than the fields themselves because this is a paged
        # list: `official_reasoning` is a paragraph and `subjective_rubric_json`
        # a whole checklist, and the list only ever needed to know whether they
        # are there.
        "has_official_reasoning": bool(question.official_reasoning),
        "has_rubric": bool(
            (question.subjective_rubric_json or "").strip()
            not in ("", "[]", "{}")),
        "has_valid_key": bool(question.has_valid_key),
        "has_answer_key": bool(question.has_answer_key),
        "missing_media_warning": question.missing_media_warning or "",
        "warnings": {
            "revealing_option": bool(question.has_revealing_option),
            "source_reference": bool(question.has_source_reference),
        },
        "image_count": len(question.image_ids),
        "video_count": len(question.video_ids),
        # THE MEDIA ITSELF, not just a count of it.
        #
        # This row is what the question BANK renders, and what an assessment's
        # `questions` list is built from - so between them they are two of the
        # five places media is meant to appear, and both had only a number.
        # A bank row for an image_ab question said "2 images" and drew nothing;
        # the assessment's selected-question list did the same. The client has
        # read `images[].admin_url` since it was written.
        #
        # URLS BUILT BY HAND, NOT READ OFF `image_admin_url`. That computed
        # field depends on `image`, which is `attachment=True` - so touching it
        # here would read every stored PNG off the filestore to answer a
        # yes/no question, on a route that pages fifty questions at a time.
        # The id and write_date are already in memory (`image_count` above
        # loaded the recordset), so this costs nothing. The route itself is
        # ACL-checked and 404s a record with no bytes, which is the degenerate
        # case anyway: an image row exists because content was attached to it.
        # `bank_question_detail` keeps its richer block - detections, the
        # behavioural key, the annotated twin - because that is a single record
        # and can afford them.
        "images": [{
            "id": i.id,
            "slot": i.slot or "single",
            "label": i.label or "",
            "admin_url": _admin_media_url("qimage", i.id, i.write_date),
            "sequence": i.sequence or 0,
        } for i in question.image_ids.sorted("sequence")],
        "videos": [{
            "id": v.id,
            "slot": v.slot or "single",
            "label": v.label or "",
            # A public link (YouTube/Vimeo) IS the whole video - see the note
            # on question_media's own "admin_url" below for why this must
            # bypass the proxy rather than route through it.
            "admin_url": admin_video_url(v, bust=True),
            "poster_url": v.poster_url or "",
            "duration_s": v.duration_s or 0.0,
            "has_audio": bool(v.has_audio),
            # "audio" plays in an audio player, not a blank video box.
            "kind": v.media_kind or "video",
            "sequence": v.sequence or 0,
        } for v in question.video_ids.sorted("sequence")],
        "dimension_count": len(question.question_dimension_ids),
        "servable": bool(
            question.active and question.has_valid_key
            and not question.missing_media_warning),
    }


def question_usage(question):
    """What a delete would touch, and whether the row may be erased at all.

    THE DELETE PREFLIGHT. The confirmation an operator reads is built from
    this, and so is the branch that decides between erasing the row and
    retiring it.

    ``referenced`` is the safety answer, and it is deliberately conservative:
    ``response.question_id`` is ondelete="cascade", so unlinking a question
    somebody has answered DELETES THEIR ANSWER, and every score already
    computed from it silently changes. The paper loses a question at the same
    time. A question nothing points at carries no history, so deleting it
    really can delete it.

    ``answer_count`` is counted rather than listed: a popular question has
    thousands of answers and the operator only needs to know the order of the
    thing they are about to keep.
    """
    Response = question.env["assessments.be.response"].sudo()
    assessments = question.sudo().assessment_ids
    answers = Response.search_count([("question_id", "=", question.id)])
    return {
        "assessments": [{
            "id": a.id,
            "name": a.name or "",
            "state": a.state or "",
        } for a in assessments],
        "assessment_count": len(assessments),
        "answer_count": answers,
        # True means "delete must retire this instead of erasing it".
        "referenced": bool(assessments or answers),
    }


def serves_baked_overlay(question):
    """False only for a labelling question whose one overlay is NOT the baked
    picture (see services/labelling.label_overlay)."""
    return (question.question_type != "image_label"
            or label_overlay(question)[0] == "baked")


def bank_label_boxes(question):
    """The numbered boxes on a labelling question's stimulus.

    The candidate's route has always sent these; the ADMIN route never did, so
    a reviewer previewing an approved labelling question saw a bare screenshot
    with nothing to label - the one thing that question is about.

    ONLY TWO SHAPES ARE EVER EMITTED, and this is not a style choice. The client
    understands a box as either a map carrying `box_2d` (four numbers on a
    0-1000 grid) or a bare integer marker number. `detections_json` carries
    `box_px` - PIXEL coordinates - and a client handed those as maps reads no
    `box_2d`, falls through to x/y/w/h, defaults every one to zero, and paints a
    row of degenerate boxes in the corner of the image. So detections are
    reduced to their numbers rather than passed through as geometry.
    """
    if question.question_type != "image_label":
        return []
    # The SAME single overlay the candidate route sends, numbered as scoring
    # grades (services/labelling.label_overlay), so the bank preview never
    # shows a second numbering.
    _mode, boxes = label_overlay(question)
    if boxes:
        return boxes
    image = question.image_ids.filtered(lambda i: i.slot == "single")[:1]
    if not image:
        return []
    # The authored geometry, when it survived approval. `box_2d` is what the
    # client draws with, so an entry without it is not a box.
    boxes = loads(image.label_boxes_json, [])
    if isinstance(boxes, list):
        drawable = [b for b in boxes
                    if isinstance(b, dict)
                    and isinstance(b.get("box_2d"), list)
                    and len(b["box_2d"]) == 4]
        if drawable:
            return drawable
    # Otherwise the markers are baked into the picture and only their numbers
    # are knowable. Same derivation the candidate route uses.
    detections = loads(image.detections_json, [])
    if isinstance(detections, list):
        numbers = {d["number"] for d in detections
                   if isinstance(d, dict) and isinstance(d.get("number"), int)}
        if numbers:
            return sorted(numbers)
    return []


def bank_question_detail(question):
    """Bank row plus the answer key. Admin only - this IS the key."""
    data = bank_question_row(question)
    # The generator is on the ROW already; usage is detail-only because it
    # costs a count per question and the list must not pay that per row.
    data["usage"] = question_usage(question)
    data.update({
        "dimensions": [{
            "id": d.id,
            "name": d.name or "",
            "sequence": d.sequence or 0,
            # THE CONTROL THE EXAMINER DREW, not just the engine that scores it.
            #
            # `question_type` is a closed set of seven SCORING primitives, so a
            # dropdown, a linear scale, a rating and a plain multiple choice all
            # store as `mcq` - correctly, because all four are marked the same
            # way. `input_kind` is the field that remembers which of them was
            # authored, and the candidate serializer has always sent it. This
            # one did not, so `Question.designerKind` on the client had nothing
            # to read and every Form Studio question published from the designer
            # reported itself as "MCQ" on the admin surfaces.
            "input_kind": d.input_kind or "",
            "options": [{
                "id": o.id,
                "name": o.name or "",
                "sequence": o.sequence or 0,
                "is_correct": bool(o.is_correct),
            } for o in d.option_line_ids.sorted("sequence")],
        } for d in question.question_dimension_ids.sorted("sequence")],
        "official_reasoning": question.official_reasoning or "",
        "subjective_rubric": loads(question.subjective_rubric_json, {}),
        "grading": loads(question.grading_json, {}),
        "solution": loads(question.solution_json, {}),
        "solution_rationale": question.solution_rationale or "",
        "covers_elements": loads(question.covers_elements_json, []),
        "detection_mode": question.detection_mode or "",
        # The markers the candidate is asked to label. See bank_label_boxes for
        # why this is never raw `detections_json` geometry.
        "label_boxes": bank_label_boxes(question),
        "images": [{
            "id": i.id,
            "slot": i.slot or "single",
            "label": i.label or "",
            "admin_url": i.image_admin_url or "",
            "annotated_admin_url": (
                i.annotated_admin_url or ""
                if serves_baked_overlay(question) else ""),
            "has_detections": bool(i.detections_json),
            # The number -> label -> functionality key itself. Odoo renders this
            # as a table under the stimulus (`answer_key_preview`); the API had
            # no equivalent, so a labelling key could not be reviewed here at
            # all. Admin-only, and this serializer's whole purpose is the key.
            "detections": loads(i.detections_json, []),
            "behavioural_key": loads(i.behavioural_key_json, []),
            "label_application": i.label_application or "",
            "coverage_expected": i.coverage_expected or "",
            "source_url": i.source_url or "",
            "capture_viewport": i.capture_viewport or "",
            "sequence": i.sequence or 0,
        } for i in question.image_ids.sorted("sequence")],
        # The video carried NO URL, so an admin previewing a bank question saw
        # its duration and audio flag and no way to play it - the one thing a
        # reviewer opens a video question to do. Images already pointed at
        # upstream's ACL-checked /assessments_be/admin_qimage proxy; the
        # matching admin_qvideo route has existed all along and nothing
        # addressed it. The video model has no computed admin URL to mirror
        # `image_admin_url`, so it is built here against that same route.
        "videos": [{
            "id": v.id,
            "slot": v.slot or "single",
            "label": v.label or "",
            # `admin_qvideo` proxies bytes THIS APP stored; a public link
            # (YouTube/Vimeo) has none to proxy - passing the proxy path
            # anyway fed the browser's native <video> an HTML page and it
            # sat at 0:00 forever, same failure as the candidate route (see
            # question_media's own note).
            "admin_url": admin_video_url(v),
            "poster_url": v.poster_url or "",
            "duration_s": v.duration_s or 0.0,
            "has_audio": bool(v.has_audio),
            # "audio" plays in an audio player, not a blank video box.
            "kind": v.media_kind or "video",
        } for v in question.video_ids.sorted("sequence")],
    })
    return data


def tag_row(tag):
    return {
        "id": tag.id,
        "name": tag.name or "",
        "prefix": tag.prefix or "",
        "display": tag.display or "",
        "label": tag.label or "",
        "color": tag.color or 0,
        "usage_count": tag.usage_count or 0,
    }


# Admin: responses, scoring, ledger

def _preview(text, limit=200):
    """`text` on one line, cut to `limit` characters with "..." when cut."""
    text = " ".join((text or "").split())
    return text if len(text) <= limit else text[:limit] + "..."


def response_row(response):
    """One answer in the admin response list."""
    justification, label_answers = split_label_answers(
        response.question_id, response)
    return {
        # A LABELLING ANSWER LIVES IN `justification`, as JSON keyed by box.
        # Every admin screen reads `label_answers` and printed "No boxes
        # labelled" over a filled-in answer, because nothing but the candidate
        # runner ever decoded that column.
        "label_answers": label_answers,
        "id": response.id,
        "assessment_id": response.assessment_id.id,
        "evaluator_id": response.assessment_evaluator_id.id
        if response.assessment_evaluator_id else None,
        "candidate": applicant_brief(response.evaluator_id),
        "question_id": response.question_id.id,
        "question_name": response.question_id.name or "",
        "question_type": response.question_type or "",
        # THE SKILLS THIS ANSWER EXERCISED.
        #
        # Copied off the QUESTION, which is where the vocabulary lives - an
        # answer has no tags of its own. Sent as canonical names, matching
        # `bank_question_row`, so every tag surface in the client speaks one
        # language.
        #
        # WHY AN ANSWER NEEDS THEM AT ALL: strengths/weaknesses is an average of
        # marks GROUPED BY category, and the mark is on the answer while the
        # category is on the question. Without this key the client would have to
        # fetch the whole bank and join locally on every dashboard render, and a
        # question dropped from the bank would silently take its answers'
        # category with it.
        "tags": [t.name for t in response.question_id.tag_ids],
        "state": response.state or "draft",
        "auto_submitted": bool(response.auto_submitted),
        "answer_summary": response.answer_summary or "",
        # THE WRITTEN ANSWER, SHORT. `answer_summary` is built from option
        # picks only, so the Responses list said "Left blank" over every
        # written answer. Whitespace-collapsed, first 200 characters; "" when
        # there is no text or the candidate's data was erased.
        "justification_preview": _preview(
            "" if response.assessment_evaluator_id.pii_anonymized
            else justification),
        "has_objective": bool(response.has_objective),
        "needs_llm": bool(response.needs_llm),
        "score": response.score or 0,
        "max_score": response.max_score or 0,
        # THE MARKS THE MODULE ACTUALLY AWARDED, and what they were out of.
        #
        # ALWAYS READ THESE AS A PAIR. A question is no longer worth 1: it is
        # worth one mark per component (each keyed sub-question, the graded
        # written answer, the labelling box set), so `final_mark` alone is
        # meaningless without `final_max` beside it. A client that assumed 1
        # would render "3" as a fail on a question worth 3.
        #
        # `score` is the objective half and only that: `_compute_score`
        # short-circuits to 0 for anything that is not mcq/msq, so an image_ab
        # answer's mark was nowhere in this payload and the client printed
        # `llm_score` - the justification verdict alone - in a column headed
        # "Mark".
        "final_mark": response.final_mark or 0.0,
        "final_max": response.final_max or 0,
        "mcq_mark": response.mcq_mark or 0.0,
        "objective_marks_max": response.objective_marks_max or 0,
        # The ungated twin, over the LLM-graded components only. `raw_max` is 0
        # for a purely objective question, which is how a client tells "no raw
        # to show" from "a raw of zero".
        "raw_score": response.raw_score or 0.0,
        "raw_max": response.raw_max or 0,
        "llm_state": response.llm_state or "not_needed",
        # WHY A GRADER STATE IS error/failed, not only THAT it is.
        #
        # `services.scoring._store_error` writes the reason into `llm_feedback`
        # ("... (surfaced as a scoring error after N attempts)"), and this row -
        # the one the Responses table and its filters are built from - sent the
        # state without it. So the client could show a red "Scoring error" pill
        # and the banner "42 answer(s) hit a terminal grader error ... Recovery
        # is manual", with nothing anywhere saying WHAT went wrong: a bad
        # credential and a malformed rubric present identically, and only one is
        # fixed by pressing Re-score. Measured on stage: 42 errored answers, the
        # reason invisible on every one.
        #
        # ONLY ON THE FAILURE STATES. `llm_feedback` doubles as the judge's
        # prose for a SCORED answer, which the audit sheet already renders in
        # full and which has no business in a table cell headed Scoring - so this
        # key carries the diagnostic and nothing else.
        "llm_error": ((response.llm_feedback or "").strip()
                      if response.llm_state in ("error", "failed") else ""),
        "llm_raw_100": response.llm_raw_100 or 0.0,
        # A re-score is queued for this answer ("Re-score queued"); the mark
        # shown is still the current one until the grade succeeds.
        "rescore_requested": bool(response.rescore_request_key),
        "llm_score": response.llm_score or 0,
        "llm_max_score": response.llm_max_score or 0,
        "llm_passed": bool(response.llm_passed),
        "subjective_result": response.subjective_result or "",
        # INVARIANT 6: advisory, never scoring.
        "integrity_alert": bool(response.integrity_alert),
        "create_date": iso(response.create_date),
    }


def response_audit(response):
    """Full grading audit for one answer - the admin 'why did it score that'.

    This is the deepest admin payload in the API. It carries the answer key,
    the grader's reasoning, its per-claim evidence and the exact judge model,
    because a hire/reject decision has to be defensible after the fact.
    """
    justification, _labels = split_label_answers(response.question_id, response)
    data = response_row(response)
    data.update({
        "justification": justification,
        "correct_summary": response.correct_summary or "",
        "lines": [{
            "id": line.id,
            "dimension_id": line.question_dimension_id.id,
            "dimension_name": line.question_dimension_id.name or "",
            "selected_option_id": line.selected_option_id.id
            if line.selected_option_id else None,
            "selected_option_name": line.selected_option_id.name or ""
            if line.selected_option_id else "",
            "is_correct": bool(line.selected_option_id.is_correct)
            if line.selected_option_id else False,
        } for line in response.line_ids],
        "grading": {
            "gate": response.llm_gate or "",
            "profile": response.llm_profile or "",
            "verdict": response.llm_verdict or "",
            "feedback": response.llm_feedback or "",
            "reasoning": response.llm_reasoning or "",
            "reference_answer": response.llm_reference_answer or "",
            "rubric_source": response.llm_rubric_source or "",
            "judge_model": response.llm_judge_model or "",
            # WHICH GRADING PROMPT DECIDED THIS - the other half of
            # `judge_model`. An audit that can name the model and not the rubric
            # cannot answer "were these two candidates held to the same
            # standard?". Empty means the score predates versioning (SNo 124):
            # nothing was re-graded to add this, because re-grading to fill in a
            # field would change marks that were correctly awarded.
            "prompt_version": response.llm_prompt_version or "",
            "attempts": response.llm_attempts or 0,
            "key_closeness": response.llm_key_closeness or 0.0,
            "sop_coverage": response.llm_sop_coverage or 0.0,
            "clarity": response.llm_clarity or "",
            "ai_confidence": response.llm_ai_confidence or "",
            "verdict_consistency": response.llm_verdict_consistency or "",
            "deductions": score_lines(response.llm_deductions_json),
            "credit": score_lines(response.llm_credit_json),
            "golden_claims": loads(response.llm_golden_claims_json, []),
            "flags": loads(response.llm_flags_json, []),
            "result": loads(response.llm_result_json, {}),
        },
        "subscores": {
            "ab_mcq_pct": response.ab_mcq_pct or 0.0,
            "ab_final_pct": response.ab_final_pct or 0.0,
            "ab_verdict_pct": response.ab_verdict_pct or 0.0,
            "ab_justification_pct": response.ab_justification_pct or 0.0,
            "label_coverage_pct": response.label_coverage_pct or 0.0,
            "label_correctness_pct": response.label_correctness_pct or 0.0,
        },
    })
    if response.question_id.question_type == "transcription":
        data["transcription"] = transcription_audit(response)
    return data


def transcription_audit(response):
    """A transcription answer beside its key, for the admin's marked-answer
    view: both texts, the word differences, and the client's rule as the judge
    counted it. Admin-only - the key is in it."""
    question = response.question_id
    correct = loads(question.solution_json, {})
    correct = correct if isinstance(correct, dict) else {}
    clip = response._clip_answers()
    text = response.justification or ""
    critical = response.llm_critical_count or 0
    minor = response.llm_minor_count or 0
    return {
        "language": question.transcription_language or "hi",
        "correct": correct,
        "answer": {
            "transcription": text,
            "category": clip.get("category") or "none",
            "characteristics": clip.get("characteristics") or [],
            "speakers": clip.get("speakers") or [],
        },
        "differences": transcript_diff.word_differences(
            text, correct.get("transcription") or ""),
        "critical": critical,
        "minor": minor,
        "client_rule_passed": (response.llm_state == "scored"
                               and not critical
                               and minor < TRANSCRIPTION_MINOR_LIMIT),
    }


def usage_row(usage):
    return {
        "id": usage.id,
        "operation": usage.operation or "other",
        "model": usage.model or "",
        "tokens_in": usage.tokens_in or 0,
        "tokens_out": usage.tokens_out or 0,
        "thoughts_tokens": usage.thoughts_tokens or 0,
        "total_tokens": usage.total_tokens or 0,
        "image_count": usage.image_count or 0,
        "video_seconds": usage.video_seconds or 0.0,
        "cost_usd": usage.cost_usd or 0.0,
        "generator": {
            "id": usage.prompt_id.id,
            "name": usage.prompt_id.name or "",
        } if usage.prompt_id else None,
        "evaluator_id": usage.evaluator_id.id if usage.evaluator_id else None,
        "note": usage.note or "",
        "create_date": iso(usage.create_date),
    }


def chatter_row(message):
    """One audit line, flattened for a client.

    `body` is Odoo HTML (`<b>Extract Tags</b> run - 5 tags...`). The tags are
    stripped here rather than in the client: a Flutter Text widget renders
    markup literally, and shipping a HTML renderer to display four bold words
    is the wrong trade. `body_html` is kept for a caller that wants the markup.
    """
    raw = message.body or ""
    text = re.sub(r"<br\s*/?>", "\n", raw)
    text = re.sub(r"</p>", "\n", text)
    text = re.sub(r"<[^>]+>", "", text)
    text = html.unescape(text).strip()
    return {
        "id": message.id,
        "author": message.author_id.display_name or "System",
        "date": iso(message.date),
        "subtype": message.subtype_id.name or "",
        "text": text,
        "body_html": raw,
        # What was attached, so the client can show it rather than dropping
        # a file the operator can see in Odoo but not here.
        "attachments": [{
            "id": a.id,
            "name": a.name or "attachment",
            "mimetype": a.mimetype or "",
            "url": "/web/content/%s?download=true" % a.id,
        } for a in message.attachment_ids],
    }


# mail.mail's own `state` selection, with the wording Odoo's Emails list uses.
# Repeated rather than read off the field so the client gets a stable label
# even for a state this Odoo version does not define (an unknown value falls
# back to the raw key instead of rendering as blank).
EMAIL_STATE_LABELS = {
    "outgoing": "Queued",
    "sent": "Sent",
    "received": "Received",
    "exception": "Delivery Failed",
    "cancel": "Cancelled",
}

# The candidate's sign-in link as it appears inside mail bodies AND inside the
# `failure_reason` of the "[NO EMAIL]" audit row that `_send_single_invitation`
# writes (`Portal link: <base>/pro_assessment/<access_token>`). The token in
# that URL is the exam credential itself, so it is masked before any mail
# metadata leaves this module: `failure_reason` is otherwise the one metadata
# field that carries a live token, and it would hand it to every caller of the
# record-scoped email route.
#
# BOTH SHAPES, because `_candidate_link_for` returns either: `<app>/exam/<token>`
# when `candidate_app_base_url` is set, `<base>/pro_assessment/<token>` when it
# is not. Masking only the portal shape left every token unmasked on precisely
# the deployments this addon exists for - the ones running the Flutter client.
_PORTAL_LINK_RE = re.compile(
    r"(/(?:pro_assessment|exam)/)[A-Za-z0-9_\-]+")


def email_row(mail, include_body=False):
    """One outgoing mail, flattened for a client.

    Read through `mail_message_id` rather than off the mail: `mail.mail`
    _inherits `mail.message`, so subject, date, author and message_type are the
    MESSAGE's columns reached by delegation. Naming the delegation explicitly
    keeps the read on the same path as the search domain
    (`mail_message_id.model` / `mail_message_id.res_id`), which is what the
    callers must use because those two fields have no `mail.mail` column at all.

    `body_html` is opt-in and manager-only. The invitation body carries the
    candidate's `<base>/exam/<access_token>` sign-in link, which is the exam
    credential - returning it by default would reopen the exact leak the chatter
    route's message_type filter exists to close.
    """
    message = mail.mail_message_id
    state = mail.state or "outgoing"
    row = {
        "id": mail.id,
        "subject": message.subject or "",
        "state": state,
        "state_label": EMAIL_STATE_LABELS.get(state, state),
        "failure_type": mail.failure_type or "",
        "failure_reason": _PORTAL_LINK_RE.sub(
            r"\1***", mail.failure_reason or ""),
        "date": iso(message.date),
        "scheduled_date": iso(mail.scheduled_date),
        "message_type": message.message_type or "",
        "author": message.author_id.display_name or "System",
        "email_to": mail.email_to or "",
        "email_cc": mail.email_cc or "",
        "recipients": [
            {
                "id": partner.id,
                "name": partner.display_name or "",
                "email": partner.email or "",
            }
            for partner in mail.recipient_ids
        ],
        # Which record this mail belongs to, so a global-list row can link back
        # to it. Both live on the message, never on the mail.
        "record": {
            "model": message.model or "",
            "res_id": message.res_id or 0,
        },
    }
    if include_body:
        row["body_html"] = mail.body_html or ""
    return row
