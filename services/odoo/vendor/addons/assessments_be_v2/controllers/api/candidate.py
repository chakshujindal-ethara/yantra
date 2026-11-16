# -*- coding: utf-8 -*-
"""Candidate surface: my attempts, my dashboard, and the exam runner.

Every route here runs its reads through ``sudo()`` because candidates are
portal users with no model ACL, and binds each read strictly to either the
logged-in user's own applicant or to a resolved exam token - exactly the
pattern candidate_portal.py and portal.py use. The token is the capability;
``is_assigned_candidate`` is the second gate on every write.

Nothing in this file may emit a score outside ``serializers.candidate_result``
(see INVARIANTS 2 and 3 in that module).
"""
import functools
import json
import logging

from botocore.exceptions import BotoCoreError, ClientError
from psycopg2 import IntegrityError

from odoo import fields, http
from odoo.http import request

from ...constants import SETTING_RANGES, clean_clip_answers
from ...services import app_origins, audit, evidence, seb
from . import serializers as S
from .common import (
    API_METHODS, API_TYPE, api_endpoint, arg, bool_arg, evaluator_from_token,
    fail, id_list_arg, int_arg, is_assigned_candidate, may_view_attempt, ok,
    request_evaluator_id, require_candidate, resolve_applicant, str_arg,
)

_logger = logging.getLogger(__name__)

# Same hard caps the web portal applies before any candidate free text is
# stored or reaches the LLM scorer. An answer is prose, not a document; the
# cap stops a candidate stuffing megabytes into `justification` to run up the
# Vertex bill. Long answers are TRUNCATED, never rejected, so an honest
# candidate never loses their attempt.
_JUSTIFICATION_MAX_LEN = 8000
_LABEL_VALUE_MAX_LEN = 500

#: Returned by `_record_response` when a CONCURRENT request is already storing
#: this same answer.
#:
#: Distinct from False, which means "the payload does not satisfy the question
#: type" and is answered with 422. Conflating the two told a candidate their
#: complete answer was incomplete - see the IntegrityError branch below.
_CONCURRENT_SAVE = object()

#: Returned by `_record_response` when the save was skipped as `stale`: the
#: same client session already stored a newer edit of this answer. Truthy, so
#: the route answers as for a save; distinct so the audit line says "stale".
_STALE_SAVE = object()

#: Returned by `_record_response` for `cleared: true`: the stored answer was
#: emptied (or there was none to empty). Truthy; the route adds `cleared`.
_CLEARED_SAVE = object()

#: The client's `updated_at` (ms since epoch) is believed only inside this
#: range; anything else (NaN, a negative, 1e300, a 400-digit integer) is read
#: as absent rather than stored. What keeps an answer from being locked is
#: the session scoping in `_update_response`, not this range.
_STAMP_MIN, _STAMP_MAX = 1, 1e14

#: How late an answer may land after the deadline and still be kept. The
#: runner's last autosave or Next can be in flight as the clock hits zero;
#: anything later was typed behind the time-up overlay and is not stored.
ANSWER_GRACE_SECONDS = 10

#: Most items one `/answers/batch` call may carry (413 beyond). A paper is far
#: shorter; the cap bounds the one transaction a single call can hold open.
BATCH_MAX_ANSWERS = 200

#: Top-level `data` key on every successful `/state` and `/begin` reply: this
#: server has `/answers/batch`. Cross-origin, a server without the route fails
#: the browser's preflight, so the client sees a transport error, never a 404 -
#: and an overloaded load balancer's 503 looks the same. The client batches
#: only when it has seen this flag, rather than guessing from errors.
ANSWERS_BATCH_FLAG = "answers_batch"

#: Companion `data` key: seconds the client waits between batches. Read from
#: this `ir.config_parameter`, clamped to `SETTING_RANGES`, 0 or junk = default.
ANSWERS_FLUSH_PARAM = "assessments_be_v2.answers_flush_seconds"
ANSWERS_FLUSH_KEY = "answers_flush_seconds"

#: Companion `data` key, present (true) only while this Boolean setting is
#: on: the client may fetch the whole paper once from `/paper` and move
#: between questions with no request. Absent means today's per-question flow.
PAPER_PREFETCH_PARAM = "assessments_be_v2.paper_prefetch"
PAPER_PREFETCH_FLAG = "paper_prefetch"


def _paper_prefetch(env):
    """The setting, read as `media_stream._prefers_redirect` reads its own:
    the Odoo form stores "True", the settings API "1", off is absent or "".
    Also what `GET /api/v1/settings` reports, so the two cannot disagree."""
    raw = env["ir.config_parameter"].sudo().get_param(
        PAPER_PREFETCH_PARAM, "")
    return str(raw or "").strip().lower() in ("1", "true", "yes", "on", "t")


def _answers_flush_seconds(env):
    """Also what `GET /api/v1/settings` reports, so the two cannot disagree."""
    low, high, default = SETTING_RANGES["answers_flush_seconds"]
    raw = env["ir.config_parameter"].sudo().get_param(
        ANSWERS_FLUSH_PARAM, str(default))
    try:
        seconds = int(raw) or default
    except (TypeError, ValueError):
        seconds = default
    return max(low, min(seconds, high))


def _advertises_batch(func):
    """Put `ANSWERS_BATCH_FLAG` on every successful reply of a route (`ok()`
    builds a dict with a `data` dict; a refusal is a built Response), so no
    return branch can be missed."""
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        result = func(*args, **kwargs)
        if isinstance(result, dict) and isinstance(result.get("data"), dict):
            result["data"][ANSWERS_BATCH_FLAG] = True
            result["data"][ANSWERS_FLUSH_KEY] = _answers_flush_seconds(
                request.env)
            if _paper_prefetch(request.env):
                result["data"][PAPER_PREFETCH_FLAG] = True
        return result
    return wrapper

# The 8 gate outcomes of /exam/<token>/state. This is the whole state machine
# the client switches on.
GATE_INVALID = "invalid"
GATE_LOGIN_REQUIRED = "login_required"
GATE_WRONG_CANDIDATE = "wrong_candidate"
GATE_CLOSED = "closed"
GATE_INSTRUCTIONS = "instructions"
GATE_QUESTION = "question"
GATE_COMPLETE = "complete"
# Locked mode is on and this browser is not our Safe Exam Browser config.
GATE_SEB_REQUIRED = "seb_required"


@require_candidate
def _candidate_group_denial():
    """None when the caller holds Candidate; the shared 403 envelope when not.

    THE SAME GATE AS THE DECORATOR, USABLE MID-FUNCTION. Most candidate routes
    wear `require_candidate` directly, but two places need the check as a value
    rather than as a wrapper:

      * `_write_guard`, which already returns "an envelope, or None when
        allowed" for three other conditions and has to run this one FIRST;
      * `exam_state`, which is `auth="public"` and must keep answering an
        ANONYMOUS visitor with the `login_required` gate - a 403 there would tell
        every candidate their account was disabled the moment their session
        expired.

    Decorating a body of `return None` reuses the shipped decorator verbatim, so
    there is exactly one definition of the group tested, the error code and the
    status. A second hand-written copy of that check is how the three identity
    walks in this addon drifted apart in the first place.
    """
    return None


def _own_attempts(applicant):
    """Every attempt this candidate is entitled to SEE.

    A DRAFT ASSESSMENT IS NOT ONE OF THEM, and that is the whole reason this
    helper exists. Assigning a candidate calls `_sync_roster_rows`, which
    creates the evaluator row immediately - before launch, by design, because
    the Odoo candidates table reads those rows rather than the m2m roster. So
    merely putting somebody on the roster of a draft published it to them: the
    assessment appeared on their "My assessments" list, with a Start button
    whose only possible outcome was the "This assessment is closed" page,
    while the operator was still deciding whether to launch it at all.

    Nothing has been promised to the candidate until launch - that is the act
    that freezes the paper, mints the token and sends the invitation - so
    before it there is nothing for them to see. Filtered here rather than in
    each route so the list, the dashboard KPIs and the analytics can never
    disagree about which attempts exist.

    A launched assessment reset back to draft disappears again, which is
    correct for the same reason: its links are no longer being honoured.
    """
    return request.env["assessments.be.evaluator"].sudo().search(
        [("applicant_id", "=", applicant.id),
         ("assessment_id.state", "!=", "draft")],
        order="create_date desc")


class EtpAssessmentApiCandidate(http.Controller):

    # My assessments / dashboard

    @http.route("/api/v1/me/assessments", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_candidate
    def my_assessments(self, **kw):
        """The candidate's own attempts, bucketed exactly as the web portal.

        Bucketing is delegated to serializers.attempt_bucket, which is a
        line-for-line port of candidate_portal._single_item, so the app's tabs
        and the portal's tabs can never disagree.
        """
        applicant = resolve_applicant()
        if not applicant:
            # Not an error: an ENTITLED user with no applicant row - an admin,
            # or somebody granted access before they were rostered. The app
            # renders an empty state, not a failure. A user with no assessment
            # access at all never gets here; `require_candidate` answers 403.
            return ok({
                "applicant": None,
                "buckets": {"available": [], "in_progress": [], "upcoming": [],
                            "completed": [], "closed": []},
                "total_count": 0,
            })
        evaluators = _own_attempts(applicant)
        buckets = {"available": [], "in_progress": [], "upcoming": [],
                   "completed": [], "closed": []}
        for evaluator in evaluators:
            item = S.attempt(evaluator)
            buckets[item["state"]].append(item)
        return ok({
            "applicant": S.applicant_brief(applicant),
            "buckets": buckets,
            "total_count": sum(len(v) for v in buckets.values()),
        })

    @http.route("/api/v1/me/dashboard", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_candidate
    def my_dashboard(self, **kw):
        """Candidate KPIs over RELEASED results only.

        Built from the same serialized attempts the list endpoint returns, so
        an unreleased attempt is structurally incapable of contributing a
        score to a KPI (it has no score keys to read).
        """
        applicant = resolve_applicant()
        if not applicant:
            return ok({"applicant": None, "kpis": None})
        evaluators = _own_attempts(applicant)
        attempts = [S.attempt(e) for e in evaluators]
        return ok({
            "applicant": S.applicant_brief(applicant),
            "kpis": S.candidate_dashboard(attempts),
        })

    @http.route("/api/v1/me/analytics", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_candidate
    def my_analytics(self, **kw):
        """The candidate's own analytics KPIs, over RELEASED results only.

        The JSON twin of the portal's "My Performance" tab
        (candidate_portal.my_dashboard -> _candidate_kpis). Built from the
        same serialized attempts /me/dashboard uses, so an unreleased attempt
        is structurally incapable of contributing a score: it carries no score
        keys for a KPI to read.

        Unlike /me/dashboard this never returns a null payload. A logged-in
        non-candidate (an admin, say) is not an error condition, and answering
        with nulls would make every client write a null check to render the
        same empty screen the zeros below already describe.
        """
        applicant = resolve_applicant()
        if not applicant:
            return ok({
                "applicant": None,
                "analytics": S.empty_candidate_analytics(),
            })
        evaluators = _own_attempts(applicant)
        attempts = [S.attempt(e) for e in evaluators]
        return ok({
            "applicant": S.applicant_brief(applicant),
            "analytics": S.candidate_analytics(attempts),
        })

    # Exam runner

    @http.route("/api/v1/exam/<string:token>/state", type=API_TYPE,
                auth="public", methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @_advertises_batch
    def exam_state(self, token, **kw):
        """Resolve a token to exactly one of the 8 gate outcomes.

        This is the ONLY navigation authority for the runner: the client never
        decides for itself whether the exam is open. The branch order mirrors
        portal.assessment_landing, and it matters -- a submitted attempt reads
        'complete' even after its assessment closes, and an expired attempt is
        settled (auto-submitted) before it is reported complete, so a
        candidate who closes the app mid-exam is not left in limbo.
        """
        evaluator = evaluator_from_token(token)
        if not evaluator:
            return ok(S.exam_state_envelope(GATE_INVALID))
        # BEFORE THE SIGN-IN GATE, so a candidate who opened the link in an
        # ordinary browser is sent to Safe Exam Browser first and signs in
        # once, inside it. No evaluator in the envelope: an anonymous caller
        # learns only that the paper is locked, nothing about it or them.
        if self._seb_blocks(evaluator):
            return ok(S.exam_state_envelope(
                GATE_SEB_REQUIRED, extra={"seb": seb.links(evaluator)}))
        if request.env.user._is_public():
            return ok(S.exam_state_envelope(GATE_LOGIN_REQUIRED))
        # THE GROUP GATE SITS BETWEEN "are you signed in" AND "is this yours",
        # and that position is the whole point.
        #
        # This route cannot wear `require_candidate` as a decorator: it is
        # `auth="public"` by design, because an anonymous visitor following an
        # invitation link has to be TOLD to sign in - `login_required` is what
        # puts the login screen in front of them. A 403 in that slot would
        # replace the sign-in prompt with "access is not enabled for this
        # account" for every candidate whose session had simply expired.
        #
        # So the anonymous case is answered above and refused nothing; only a
        # caller who IS somebody, and who is not entitled to sit assessments,
        # falls through to the 403 here. The order also keeps the group check
        # ahead of `may_view_attempt`, whose `wrong_candidate` payload names the
        # invited candidate - which an unentitled account must not read.
        denied = _candidate_group_denial()
        if denied:
            return denied
        if not may_view_attempt(evaluator):
            return ok(S.exam_state_envelope(GATE_WRONG_CANDIDATE, extra={
                "expected_candidate": S.applicant_brief(
                    evaluator.applicant_id),
                "current_user": request.env.user.login,
            }))

        assessment = evaluator.assessment_id
        # A manager holding the token but with no bound candidate user is in
        # preview: they may look, never write. The flag lets the app grey out
        # its controls instead of letting the candidate hit a 403 later.
        preview = not is_assigned_candidate(evaluator)

        if evaluator.is_locked or evaluator.state == "submitted":
            return ok(S.exam_state_envelope(GATE_COMPLETE, evaluator, {
                "preview": preview,
                "result": S.candidate_result(
                    evaluator, S.attempt_bucket(evaluator)),
                "can_review_answers": bool(evaluator.results_released),
            }))
        if assessment.state != "in_progress":
            return ok(S.exam_state_envelope(GATE_CLOSED, evaluator, {
                "preview": preview,
                "reason": "This assessment is not currently open.",
            }))
        if not evaluator.started_at:
            return ok(self._with_evidence_upload(S.exam_state_envelope(
                GATE_INSTRUCTIONS, evaluator, {
                    "preview": preview,
                    "instructions": {
                        "duration_minutes": assessment.duration_minutes or 0,
                        "total_questions": evaluator.total_questions or 0,
                        "question_limit": assessment.question_limit or 0,
                    },
                }), evaluator, preview))
        if evaluator.is_time_expired():
            # Settle the abandoned attempt through the model's own path so it
            # ends identically to the cron sweep, then report it complete.
            evaluator.sudo()._auto_submit_expired(reason_code="expired")
            return ok(S.exam_state_envelope(GATE_COMPLETE, evaluator, {
                "preview": preview,
                "expired": True,
                "result": S.candidate_result(
                    evaluator, S.attempt_bucket(evaluator)),
                "can_review_answers": bool(evaluator.results_released),
            }))
        if not preview:
            self._claim_session(evaluator)
        return ok(self._question_payload(
            evaluator, token, requested_index=arg("q"), preview=preview))

    @http.route("/api/v1/exam/<string:token>/begin", type=API_TYPE,
                auth="user", methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    @_advertises_batch
    def exam_begin(self, token, **kw):
        """Start the clock. Idempotent: re-calling never resets started_at.

        started_at is what deadline_datetime is computed from, so re-stamping
        it would silently hand a candidate extra time on every reconnect.
        """
        evaluator = evaluator_from_token(token)
        guard = self._write_guard(evaluator, begun=False)
        if guard:
            return guard
        if evaluator.assessment_id.state != "in_progress":
            return fail("assessment_closed",
                        "This assessment is not open", status=409)
        t0 = audit.start()
        resumed = bool(evaluator.started_at)
        if not evaluator.started_at:
            evaluator.write({"started_at": fields.Datetime.now()})
        if evaluator.state == "pending":
            evaluator.write({"state": "in_progress"})
        self._claim_session(evaluator)
        payload = self._question_payload(evaluator, token, preview=False)
        audit.emit("exam.begin", evaluator, t0=t0,
                   outcome="resumed" if resumed else "started")
        return ok(payload)

    @http.route("/api/v1/exam/<string:token>/answer", type=API_TYPE,
                auth="user", methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    def exam_answer(self, token, **kw):
        """Save (and submit) one response, then hand back the next question.

        The exam is answered one item at a time and each item is submitted as
        it is saved, matching the web runner: a dropped connection therefore
        loses at most the item in hand, never the whole attempt.
        """
        t0 = audit.start()
        evaluator = evaluator_from_token(token)
        guard = self._write_guard(evaluator)
        if guard:
            return guard
        if evaluator.assessment_id.state != "in_progress":
            return fail("assessment_closed",
                        "This assessment is not open", status=409)
        question_id = int_arg("question_id")
        if not question_id:
            return fail("missing_question", "question_id is required",
                        status=400)

        # THE ANSWER IN FLIGHT IS SAVED BEFORE THE CLOCK IS ENFORCED.
        #
        # This check used to run BEFORE `question_id` was even parsed, so an
        # answer that arrived in the same request as the expiry was never read.
        # `_auto_submit_expired` then wrote a blank
        # "[Auto-submitted: time expired]" placeholder over that question, which
        # sets `auto_submitted=True`, which forces `needs_llm` False - so the
        # answer was excluded from grading, scored 0, and invisible to the admin.
        # The 409 said only "your time has expired"; nothing anywhere said an
        # answer had been discarded.
        #
        # A candidate who typed something and pressed Next as the clock ran out
        # had their work silently thrown away. Saving first costs nothing: the
        # deadline is enforced on the very next line, the attempt is still
        # settled in this request, and the response row is the one the
        # placeholder would otherwise have replaced.
        #
        # `saved_in_flight` is reported so the client can tell the candidate the
        # truth either way - "we kept it" or, if the payload was incomplete,
        # that it was not kept.
        #
        # IN FLIGHT MEANS WITHIN `ANSWER_GRACE_SECONDS`. Without a bound, text
        # typed after time-up behind the overlay was stored by the next
        # autosave, and the 409 even said "your last answer was saved".
        saved_in_flight = None
        if evaluator.is_time_expired():
            in_grace = (fields.Datetime.now() - evaluator.deadline_datetime
                        ).total_seconds() <= ANSWER_GRACE_SECONDS
            from_old_tab = in_grace and not self._session_is_current(evaluator)
            saved_in_flight = (self._record_response(evaluator, question_id)
                               if in_grace and not from_old_tab else False)
            evaluator.sudo()._auto_submit_expired(reason_code="expired")
            audit.emit("exam.answer", evaluator, outcome="time_expired",
                       t0=t0, question=question_id,
                       answer_saved=saved_in_flight is not False)
            if saved_in_flight is not False:
                tail = " and your last answer was saved."
            elif from_old_tab:
                tail = (", but your last answer came from a tab this exam has"
                        " since moved away from and was not saved.")
            elif in_grace:
                tail = (", but your last answer was incomplete and was not"
                        " saved.")
            else:
                tail = (", but your last answer arrived after the deadline"
                        " and was not saved.")
            return fail(
                "time_expired",
                "Your time has expired; the attempt was submitted" + tail,
                status=409,
                answer_saved=saved_in_flight is not False)
        saved = self._record_response(evaluator, question_id)
        if saved is False:
            audit.emit("exam.answer", evaluator, outcome="incomplete", t0=t0,
                       question=question_id)
            return fail("incomplete_answer",
                        "This answer is incomplete for its question type",
                        status=422)
        # ONE LINE PER SAVE, AND IT IS EMITTED HERE RATHER THAN AT THE FOUR
        # `ok(...)` RETURNS BELOW. All four mean the same thing to an
        # operator - the answer is stored - and they differ only in what was
        # built to hand back next, which `question.view` already records.
        # `nav` is carried so the debounced autosave (`nav="stay"`, the most
        # frequent call the runner makes) can be told apart from a real
        # navigation.
        audit.emit("exam.answer", evaluator, t0=t0, question=question_id,
                   outcome="concurrent" if saved is _CONCURRENT_SAVE
                   else "stale" if saved is _STALE_SAVE
                   else "cleared" if saved is _CLEARED_SAVE else "saved",
                   nav=str_arg("nav", "next"))
        # `concurrent: true` on every ok below when THIS request stored
        # nothing: it lost the first INSERT to a sibling, which under
        # write-behind may carry OLDER content, so the client re-sends.
        # `saved` stays true for older clients; absent on a normal save.
        # `cleared: true` when the answer was emptied (`cleared` body key).
        extra = ({"concurrent": True} if saved is _CONCURRENT_SAVE
                 else {"cleared": True} if saved is _CLEARED_SAVE else {})
        if evaluator.state == "pending":
            evaluator.write({"state": "in_progress"})

        # SAVING NO LONGER ENDS THE ATTEMPT - but something else may have.
        #
        # `action_submit` used to lock the evaluator as soon as the submitted
        # count reached total_questions, which made answering the last question
        # hand the paper in: every navigation posts the current answer, so a
        # candidate who had finished and pressed PREVIOUS submitted their exam.
        # That auto-lock is gone (see assessment.py, action_submit).
        #
        # This branch stays, because the attempt can still be locked out from
        # under an open runner by something that is not the save: the expiry
        # cron, or the proctoring violation cap. A client that keeps writing
        # then is not misbehaving, it simply has not been told yet - and being
        # told once is what stops it navigating on to a question that refuses
        # every keystroke with "This attempt is already submitted".
        #
        # Re-read rather than trusting the in-memory record: a concurrent
        # settlement is written on another transaction's side.
        evaluator.invalidate_recordset()
        if evaluator.is_locked or evaluator.state == "submitted":
            return ok({
                "saved": True,
                "next": None,
                "attempt_closed": True,
                "outcome": GATE_COMPLETE,
                "attempt": {
                    "state": evaluator.state,
                    "is_locked": True,
                    "submitted_at": S.iso(evaluator.submitted_at),
                    "answered_count": evaluator.answered_count or 0,
                    "total_questions": evaluator.total_questions or 0,
                },
                "result": S.candidate_result(
                    evaluator, S.attempt_bucket(evaluator)),
                **extra,
            })

        nav = str_arg("nav", "next")

        # `nav="stay"` - SAVE ONLY, BUILD NOTHING (SNo 147).
        #
        # Every other value ends by composing the next question: its prompt,
        # its dimensions and options, and a signed URL per image and per clip.
        # Measured on the real endpoint, one `/answer` costs 24 queries and the
        # largest single share of them is that build.
        #
        # The DEBOUNCED AUTOSAVE never looks at it. It fires while the
        # candidate is typing, throws the response away by design, and is the
        # most frequent call the runner makes - so the paper's next question
        # was assembled, serialized and signed, over and over, for a client
        # that had already discarded the last copy.
        #
        # A sentinel rather than "guess from the absence of nav": the default
        # is `next`, and a client that simply omits the field still means
        # "next". Only a caller that says it wants nothing gets nothing, so an
        # older client keeps working unchanged.
        #
        # Deliberately AFTER the settlement check above: a save that lands on
        # an attempt the expiry cron or the violation cap has just closed must
        # still be told, whatever it asked for.
        if nav == "stay":
            return ok({"saved": True, "next": None, "attempt_closed": False,
                       **extra})

        order = self._live_order(evaluator)
        target = self._next_index(order, question_id, nav)
        if target is None:
            return ok({"saved": True, "next": None, "attempt_closed": False,
                       "review": self._review_payload(evaluator, order),
                       **extra})
        return ok({"saved": True, "attempt_closed": False,
                   "next": self._question_payload(
                       evaluator, token, requested_index=target,
                       preview=False),
                   **extra})

    @http.route("/api/v1/exam/<string:token>/answers/batch", type=API_TYPE,
                auth="user", methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    def exam_answers_batch(self, token, **kw):
        """Save many answers in one transaction, then optionally hand in.

        Body ``{answers: [{question_id, selected_option_ids, justification,
        label_answers, updated_at?}], submit, force}``; an item
        ``{question_id, cleared: true, updated_at?}`` empties the stored
        answer (``reason: "cleared"``). Each item goes through
        `_record_response_values` - the rules `/answer` applies - and gets
        ``{question_id, accepted, reason}``; a refused item never blocks the
        others. Create-or-update on the (attempt, question) unique index, so a
        retried batch changes nothing. `updated_at` orders saves INSIDE one
        session (the request's `session_key`): an item older than what that
        session already stored is skipped as `stale`; any other save wins and
        replaces the stamp (`_update_response`). `submit: true` then runs
        exactly `/submit` (`_submit_attempt`, `force` included) and returns
        its payload plus `results`.

        A CLOSED PAPER (not `in_progress`, e.g. an admin marked it Done)
        stores no answers: without `submit` the batch is refused 409
        `assessment_closed`, as `/answer` is; with `submit` the items are
        skipped and it answers exactly what `/submit` answers there (which has
        no such check), so an untimed paper can still be handed in.

        `/answers` (no suffix) is the post-release review read, hence the path.
        """
        t0 = audit.start()
        evaluator = evaluator_from_token(token)
        guard = self._write_guard(evaluator)
        if guard:
            return guard
        if evaluator.assessment_id.state != "in_progress":
            if bool_arg("submit"):
                return self._submit_attempt(evaluator, t0, results=[])
            return fail("assessment_closed",
                        "This assessment is not open", status=409)
        items = arg("answers") or []
        if not isinstance(items, list):
            return fail("invalid_answers", "`answers` must be a list",
                        status=400)
        if len(items) > BATCH_MAX_ANSWERS:
            return fail("too_many_answers",
                        "At most %d answers per batch" % BATCH_MAX_ANSWERS,
                        status=413)
        # Past the deadline exactly as `/answer`: what lands inside the grace
        # is kept, then the attempt is settled and the call answered 409.
        if evaluator.is_time_expired():
            in_grace = (fields.Datetime.now() - evaluator.deadline_datetime
                        ).total_seconds() <= ANSWER_GRACE_SECONDS
            if not in_grace:
                results = []
            elif self._session_is_current(evaluator):
                results = self._save_batch(evaluator, items)
            else:
                results = [{"question_id": int_arg(
                                "question_id", source=item
                                if isinstance(item, dict) else {}) or None,
                            "accepted": False, "reason": "session_replaced"}
                           for item in items]
            evaluator.sudo()._auto_submit_expired(reason_code="expired")
            # NOTHING SENT MEANS NOTHING LOST. An empty batch (the final
            # `submit: true` of a candidate with nothing pending) said
            # `answer_saved: false`, which the client shows as "your last
            # change reached us after the deadline" to every timed-out
            # candidate - over a third of production submissions.
            saved = not items or any(r["accepted"] for r in results)
            audit.emit("exam.batch", evaluator, outcome="time_expired",
                       t0=t0, items=len(items), answer_saved=saved,
                       stale=sum(1 for r in results
                                 if r["reason"] == "stale"),
                       cleared=sum(1 for r in results
                                   if r["reason"] == "cleared"))
            return fail("time_expired",
                        "Your time has expired; the attempt was submitted.",
                        status=409, answer_saved=saved, results=results)
        results = self._save_batch(evaluator, items)
        accepted = sum(1 for r in results if r["accepted"])
        if accepted and evaluator.state == "pending":
            evaluator.write({"state": "in_progress"})
        audit.emit("exam.batch", evaluator, t0=t0, items=len(items),
                   accepted=accepted,
                   stale=sum(1 for r in results if r["reason"] == "stale"),
                   cleared=sum(1 for r in results if r["reason"] == "cleared"))
        if bool_arg("submit"):
            return self._submit_attempt(evaluator, t0, results=results)
        return ok({"results": results})

    def _save_batch(self, evaluator, items):
        """One `{question_id, accepted, reason}` per `/answers/batch` item."""
        Question = request.env["assessments.be.question"].sudo()
        results = []
        for item in items:
            item = item if isinstance(item, dict) else {}
            question_id = int_arg("question_id", source=item)
            accepted, reason = (
                self._record_response_values(
                    evaluator, Question.browse(question_id),
                    *self._answer_values(item))
                if question_id else (False, "missing_question"))
            results.append({"question_id": question_id or None,
                            "accepted": accepted, "reason": reason})
        # ONE flush for the whole batch: every answer's marks and state, and
        # the attempt's recomputed totals, go out as one UPDATE per table.
        request.env.flush_all()
        return results

    @http.route("/api/v1/exam/<string:token>/review", type=API_TYPE,
                auth="user", methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    def exam_review(self, token, **kw):
        """The pre-submit checklist: every question, answered or not.

        A candidate needs to see what they are about to hand in BEFORE the
        irreversible step, and needs to be able to jump back to a specific gap.
        The rows carry no marks and no correctness: nothing has been graded
        yet, and showing a hint of one here would leak the answer key.

        THAT LAST SENTENCE USED TO BE FALSE. This built its rows with what is
        now `S.released_answer_review_row`, the post-release builder, which for
        mcq/msq emits
        `correct` - the names of the right options - plus a Correct/Incorrect
        verdict derived from `score`/`max_score`, both stored computes that
        evaluate the moment an answer is saved. The only gate here is
        `_write_guard`, which an in-progress attempt passes. So a candidate
        could answer anything, call this route, read the key for every objective
        question, navigate back, and resubmit. Upstream never had the bug: its
        pre-submit page uses `_render_review` (portal.py) and the answer-key
        builder is reachable only from `/answers`, gated on submitted AND
        released. This now uses `_review_payload`, the same shape `/answer`
        returns, which has no representation for correctness at all.

        Browsing `order` directly rather than `assessment.question_ids` also
        fixes a second bug: a candidate provisioned after launch can hold
        questions that were never added to the assessment, and those were
        silently skipped here while still counting toward the total.
        """
        evaluator = evaluator_from_token(token)
        guard = self._write_guard(evaluator)
        if guard:
            return guard

        payload = self._review_payload(evaluator, self._live_order(evaluator))
        payload["deadline"] = S.iso(evaluator.deadline_datetime)
        payload["server_now"] = S.iso(fields.Datetime.now())
        return ok(payload)

    @http.route("/api/v1/exam/<string:token>/paper", type=API_TYPE,
                auth="user", methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    def exam_paper(self, token, **kw):
        """Every question of the candidate's paper in one reply (prefetch).

        Only while `paper_prefetch` is on: 404 `prefetch_off` otherwise.
        Guarded as `/review` is (the assigned candidate, a begun attempt not
        yet submitted, the tab holding the sitting) and read-only: it claims
        no session. Each question comes from `question_for_candidate` exactly
        as `/state?q=N` builds it, so no answer key, the question cache
        serves the whole paper in one round trip when on, and it carries `index`, `total` and the saved
        `answer`; in the candidate's own order. The candidate could already
        open each one by number, so nothing new is revealed. One `paper.fetch`
        audit line replaces the per-question `question.view` lines.
        """
        t0 = audit.start()
        if not _paper_prefetch(request.env):
            return fail("prefetch_off", "Whole-paper prefetch is off.",
                        status=404)
        evaluator = evaluator_from_token(token)
        guard = self._write_guard(evaluator)
        if guard:
            return guard
        # Where `/state` serves no question, this serves none either: a paper
        # not open, or a clock that has run out (a read settles nothing).
        if evaluator.assessment_id.state != "in_progress":
            return fail("assessment_closed",
                        "This assessment is not open", status=409)
        if evaluator.is_time_expired():
            return fail("time_expired", "Your time has expired.", status=409)
        order = self._live_order(evaluator)
        responses = {
            r.question_id.id: r for r in
            request.env["assessments.be.response"].sudo().search([
                ("assessment_evaluator_id", "=", evaluator.id),
                ("question_id", "in", order)])}
        paper = request.env["assessments.be.question"].sudo().browse(order)
        # One Redis round trip for the whole paper, not one per question.
        contents = S.paper_content(paper, self._label_boxes)
        questions = [
            S.question_for_candidate(
                question, token, i + 1, len(order),
                responses.get(question.id), content=contents[question.id])
            for i, question in enumerate(paper)]
        payload = {
            "questions": questions,
            "answered_question_ids": sorted(
                self._answered_question_ids(evaluator)),
            "total": len(order),
        }
        policy = evidence.upload_policy(evaluator)
        if policy:
            payload["evidence_upload"] = policy
        audit.emit("paper.fetch", evaluator, t0=t0, count=len(questions))
        return ok(payload)

    @http.route("/api/v1/exam/<string:token>/submit", type=API_TYPE,
                auth="user", methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    def exam_submit(self, token, **kw):
        """Finish the attempt.

        Refuses while questions are unanswered UNLESS time has expired, which
        is exactly portal.assessment_finish_single's rule: a candidate must
        not accidentally end an exam early, but an expired one must always be
        able to settle. Settling delegates to the model's _auto_submit_expired
        so the placeholder-filling, locking and assessment-completion cascade
        stay in one place.
        """
        t0 = audit.start()
        evaluator = evaluator_from_token(token)
        guard = self._write_guard(evaluator)
        if guard:
            return guard
        return self._submit_attempt(evaluator, t0)

    def _submit_attempt(self, evaluator, t0, **extra):
        """`/submit` past its guard, and `/answers/batch` with `submit: true`,
        so the two cannot settle a paper differently. ``extra`` rides on
        whatever is returned (the batch's per-item `results`)."""
        if evaluator.is_locked or evaluator.state == "submitted":
            audit.emit("exam.submit", evaluator, outcome="already", t0=t0)
            return ok({"submitted": True, "already": True, **extra})
        unanswered = self._unanswered_question_ids(evaluator)
        if unanswered and not evaluator.is_time_expired():
            # bool_arg, NOT arg: a JSON body is not always typed, and every
            # non-empty STRING is truthy - so `{"force": "0"}` and
            # `{"force": "false"}`, which a form-encoded or loosely typed
            # client sends to mean the opposite, walked straight past this
            # guard and ended the candidate's exam with questions unanswered.
            if not bool_arg("force"):
                return fail("incomplete_attempt",
                            "%d question(s) are still unanswered"
                            % len(unanswered),
                            status=409, unanswered=unanswered, **extra)
        # The blank reason is chosen from what ACTUALLY happened rather than
        # left at the model's default. `_auto_submit_expired` stamps
        # "[Auto-submitted: time expired]" on every unanswered question, and
        # this path is reached with time remaining whenever a candidate submits
        # an incomplete paper on purpose (`force`). Recording that as an expiry
        # put a deadline breach that never occurred into the audit trail and
        # into the CSV export a reviewer reads.
        #
        # A fully answered paper is unaffected either way: no question is
        # missing, so no placeholder is written.
        expired = evaluator.is_time_expired()
        evaluator.sudo()._auto_submit_expired(
            blank_reason=None if expired
            else "[Submitted with unanswered questions]",
            # A candidate pressing Submit is NOT an auto-submit, so the reason
            # stays empty unless the clock had already run out under them.
            reason_code="expired" if expired else None)
        audit.emit("exam.submit", evaluator, t0=t0,
                   outcome="expired" if expired
                   else ("forced" if unanswered else "complete"),
                   unanswered=len(unanswered))
        return ok({
            "submitted": True,
            "already": False,
            # INVARIANT 3: submitting does not release anything. The result
            # block here reports 'awaiting_results' until a person releases.
            "result": S.candidate_result(
                evaluator, S.attempt_bucket(evaluator)),
            **extra,
        })

    @http.route("/api/v1/exam/<string:token>/violation", type=API_TYPE,
                auth="user", methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    def exam_violation(self, token, **kw):
        """Record one proctoring violation.

        Reimplements portal._record_violation_single's dedup + atomic counter
        rather than calling it, because that method lives on the controller
        (not the model) and takes a rendered redirect path. The behaviour is
        identical and the reasons are preserved below.
        """
        t0 = audit.start()
        evaluator = evaluator_from_token(token)
        guard = self._write_guard(evaluator)
        if guard:
            return guard
        # TIME-UP IS NOT A PROCTORING EVENT. Leaving fullscreen or the tab
        # after the deadline beaconed here and settled the paper as a
        # 'violation', with "[Auto-submitted: proctoring violation ...]" on
        # every blank - a candidate who only ran out of time, recorded as a
        # proctoring auto-submit. Settle it as the expiry it is, count
        # nothing, and answer exactly as `/answer` does past the deadline.
        #
        # WITHIN `ANSWER_GRACE_SECONDS` IT DOES NOT SETTLE. The runner's clock
        # can trail the server's by a second or two, so a tab switch lands
        # here just after the deadline while an autosave is still pending;
        # settling now would lock the paper and `/answer` would refuse that
        # last text. The client flushes it on this 409, and `/answer` settles.
        if evaluator.is_time_expired():
            in_grace = (fields.Datetime.now() - evaluator.deadline_datetime
                        ).total_seconds() <= ANSWER_GRACE_SECONDS
            if not in_grace:
                evaluator.sudo()._auto_submit_expired(reason_code="expired")
            audit.emit("exam.violation", evaluator, t0=t0,
                       outcome="time_expired")
            return fail("time_expired",
                        "Your time has expired."
                        if in_grace else
                        "Your time has expired; the attempt was submitted.",
                        status=409, answer_saved=False)
        reason = str_arg("reason", "Unknown violation", max_len=240) \
            or "Unknown violation"
        # THE REPORT'S OWN STAMP (BR-D15 review, P2-2). A client that kept a
        # report it got no reply to sends it again; the stamp says it is the
        # SAME report, so a reply lost on the way back (a reload, a dropped
        # connection) does not count it twice. Epoch milliseconds; absent or
        # nonsense from an older client, which keeps today's behaviour.
        client_at = int_arg("at")
        recorded = self._record_violation(
            evaluator, reason,
            client_at=client_at if 0 < client_at < 10 ** 14 else None)
        evaluator.invalidate_recordset(
            ["violation_count", "ai_violation_count", "is_locked", "state",
             "violation_limit_breached", "ai_violation_limit_breached"])
        audit.emit("exam.violation", evaluator, t0=t0,
                   outcome="recorded" if recorded else "deduped",
                   reason=reason[:80],
                   count=evaluator.violation_count or 0,
                   ended=bool(evaluator.is_locked))
        return ok({
            "recorded": recorded,
            "violation_count": evaluator.violation_count or 0,
            "max_violations": evaluator.assessment_id.max_violations or 0,
            "violation_action": evaluator.assessment_id.violation_action or "",
            # INVARIANT 6: a violation is advisory for scoring. It can END an
            # attempt (auto-submit) but it never changes a mark.
            "attempt_ended": bool(evaluator.is_locked),
            # The violation limit was reached, in either mode: the label.
            # Auto-submit also ended the exam (`attempt_ended`); Log only
            # never does.
            "violation_limit_breached": bool(
                evaluator.violation_limit_breached),
            # The AI kind's own count, limit and mode (R5).
            "ai_violation_count": evaluator.ai_violation_count or 0,
            "ai_max_violations": evaluator.assessment_id.ai_max_violations or 0,
            "ai_violation_action":
                evaluator.assessment_id.ai_violation_action or "log_only",
            "ai_violation_limit_breached": bool(
                evaluator.ai_violation_limit_breached),
        })

    @http.route("/api/v1/exam/<string:token>/review-flag", type=API_TYPE,
                auth="user", methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    def exam_review_flag(self, token, **kw):
        """Always refused: eye movement (`rule_gaze_review`) is off for good
        (19 Oct), and no runner is told to run it (`proctoring_rules`).

        Kept so a stray call from an old app gets the 409 it already handles
        rather than a 404. Same guard as `/violation`; nothing is recorded.
        """
        evaluator = evaluator_from_token(token)
        guard = self._write_guard(evaluator)
        if guard:
            return guard
        return fail("gaze_review_off",
                    "Eye movement review is not on for this assessment.",
                    status=409)

    @http.route("/api/v1/exam/<string:token>/ai-status", type=API_TYPE,
                auth="user", methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    def exam_ai_status(self, token, **kw):
        """Note whether the AI proctoring, and its eye tracking, started on
        the candidate's device (`ai_status`, R9d), so an admin can tell an AI
        that never ran from a candidate who broke no rule.

        Same guard as `/review-flag`, except that the attempt need not be
        begun: the app starts the AI before `/begin` commits, and a status it
        reports then must not be lost to a 409. A value the Selection does not
        offer is 422, and the same value again writes nothing.
        """
        evaluator = evaluator_from_token(token)
        guard = self._write_guard(evaluator, begun=False, one_tab=True)
        if guard:
            return guard
        if not evaluator.assessment_id.rule_ai_proctor:
            return fail("ai_proctor_off",
                        "AI proctoring is not on for this assessment.",
                        status=409)
        if evaluator.is_time_expired():
            return fail("time_expired", "Your time has expired.", status=409)
        status = str_arg("status", max_len=32)
        if status not in dict(evaluator._fields["ai_status"].selection):
            return fail("invalid", "Unknown AI proctoring status.", status=422)
        if evaluator.ai_status != status:
            evaluator.write({"ai_status": status})
        return ok({"ai_status": status})

    @http.route("/api/v1/exam/<string:token>/evidence/landed", type=API_TYPE,
                auth="user", methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    def exam_evidence_landed(self, token, **kw):
        """Whether one AI proctoring snapshot (`key`, as the runner named it)
        is in S3. Asked after an upload whose reply the browser could not
        read: a bucket with no CORS rule for POST stores the file but
        withholds the answer, and the runner otherwise sends it again.

        Same guard as `/violation`, minus "begun" (the policy, and so a
        snapshot, exists from the instructions screen) and minus "not yet
        submitted" (it reads, so a snapshot in flight at submit can still be
        confirmed). Only the assigned
        candidate, only this attempt, and only a snapshot-shaped key under its
        own prefix (`evidence.snapshot_landed`): never a "does key X exist"
        check on the bucket.
        """
        evaluator = evaluator_from_token(token)
        guard = self._write_guard(evaluator, begun=False, locked_ok=True)
        if guard:
            return guard
        try:
            landed = evidence.snapshot_landed(
                evaluator, str_arg("key", max_len=512))
        except (BotoCoreError, ClientError):
            _logger.warning("Evidence check for attempt %s failed",
                            evaluator.id, exc_info=True)
            return fail("s3_failed", "Could not check storage.", status=502)
        if landed is None:
            return fail("bad_key", "That is not one of this attempt's "
                        "snapshots.", status=400)
        return ok({"landed": landed})

    @http.route("/api/v1/exam/<string:token>/seb-config", type="http",
                auth="public", methods=["GET"], csrf=False)
    def exam_seb_config(self, token, **kw):
        """The .seb file behind "Open in Safe Exam Browser" (`sebs://` link).

        Fetched by SEB itself, with no session, so the token is the only key -
        the same capability the exam link already is. It holds the start page,
        the quit URL and the quit password's hash, never the password.
        """
        evaluator = evaluator_from_token(token)
        if not evaluator or not evaluator.assessment_id.rule_require_seb:
            return request.not_found()
        return request.make_response(seb.config_file(evaluator), headers=[
            ("Content-Type", "application/seb"),
            ("Content-Disposition", 'attachment; filename="assessment.seb"'),
            ("Cache-Control", "no-store"),
        ])

    @http.route("/api/v1/seb/check-config", type="http", auth="public",
                methods=["GET"], csrf=False)
    def seb_check_config(self, **kw):
        """The .seb behind the public `/seb-check` page's "Test in Safe Exam
        Browser" (R4): the app's check page with the camera allowed and no
        quit password (`seb.check_settings`). Fetched by SEB with no session;
        it is no exam's file, so no Config Key moves with it.
        """
        origin = app_origins.client_app_origin(request.env(su=True))
        return request.make_response(seb.check_config_file(origin), headers=[
            ("Content-Type", "application/seb"),
            ("Content-Disposition", 'attachment; filename="seb-check.seb"'),
            ("Cache-Control", "no-store"),
        ])

    @http.route("/api/v1/exam/<string:token>/answers", type=API_TYPE,
                auth="user", methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_candidate
    def exam_answers(self, token, **kw):
        """Post-release answer review.

        Gated on BOTH conditions the portal requires: the attempt must be
        finished AND results_released must be set by a person. Without the
        second gate this endpoint would be a back door around INVARIANT 3.

        THE SEVENTH EXAM ROUTE, AND THE ONLY READ ONE THAT DOES NOT GO THROUGH
        `_write_guard` - it must not, because reading a finished paper is not a
        write and an attempt is locked by then. So it carries the group gate as a
        decorator instead. Left out, this would stay the one candidate route an
        account with assessment access switched off could still reach.
        """
        evaluator = evaluator_from_token(token)
        if not evaluator:
            return fail("invalid_token", "Unknown assessment link", status=404)
        if not may_view_attempt(evaluator):
            return fail("wrong_candidate",
                        "This assessment belongs to another candidate",
                        status=403)
        finished = evaluator.is_locked or evaluator.state == "submitted"
        if not (finished and evaluator.results_released):
            return fail("not_released",
                        "Results for this assessment have not been released",
                        status=403)
        order = json.loads(evaluator.question_order or "[]")
        questions = request.env["assessments.be.question"].sudo() \
            .browse(order).exists()
        responses = request.env["assessments.be.response"].sudo().search([
            ("assessment_evaluator_id", "=", evaluator.id),
            ("question_id", "in", questions.ids)])
        by_question = {r.question_id.id: r for r in responses}
        reveal = evaluator.assessment_id.results_show_answers
        rows = [S.released_answer_review_row(
                    i + 1, q, by_question.get(q.id), token,
                    label_boxes=self._label_boxes(q), reveal=reveal)
                for i, q in enumerate(questions)]
        return ok({
            # `pass_threshold` BELONGS ON THE ASSESSMENT BLOCK, not only on
            # `result`. The client builds its Assessment from this object and
            # falls back to 70 when the key is absent - so a candidate sitting
            # a 60% paper was told, on their own results page, that the pass
            # mark was 70%. The figure is the one `_compute_result` actually
            # applied, so it cannot disagree with the verdict shown beside it.
            "assessment": {"id": evaluator.assessment_id.id,
                           "name": evaluator.assessment_id.name or "",
                           "pass_threshold": (
                               evaluator.pass_threshold
                               or evaluator.assessment_id
                               ._effective_pass_threshold()
                               or 0.0)},
            "result": S.candidate_result(
                evaluator, S.attempt_bucket(evaluator)),
            "rows": rows,
        })

    # Guards and helpers

    def _write_guard(self, evaluator, begun=True, locked_ok=False,
                     one_tab=None):
        """Common gate for every mutating exam route, or None when allowed.

        ``locked_ok`` (read-only checks only, `/evidence/landed`): a submitted
        attempt still passes, so a snapshot in flight at submit is confirmed
        rather than re-sent until its upload policy expires.

        ``begun`` (all but `/begin`): the attempt must have been started. The
        clock starts at `/begin`; without this a candidate who never pressed
        Start could answer, read the next question and submit through the API
        with no deadline at all. The app only calls these after `/begin` (the
        instructions gate), and a resume has `started_at` already.

        ``one_tab`` (defaults to ``begun``): refuse a write from a tab since
        replaced. `/ai-status` keeps it without ``begun``.

        Order matters: no Candidate group -> unknown token -> not your attempt
        -> already locked. Only the ASSIGNED candidate may write, so a manager
        holding the token for preview can read the runner but never write into
        a real attempt.

        THE GROUP CHECK IS FIRST, AND IT IS THE ONE THAT WAS MISSING. Every
        other step here answers "is this the right attempt for you"; none of
        them answered "may you sit assessments at all". `auth="user"` only means
        "not the public user" (base/models/ir_http.py), so candidate ability rode
        on `base.group_user` - which every employee in the instance holds. A
        person set to "Assessment v2 Access = No" therefore still sat exams.

        It runs BEFORE the token is judged on purpose: an account with no access
        must not be able to tell a live token from a dead one by reading the
        difference between 403 and 404.
        """
        denied = _candidate_group_denial()
        if denied:
            return denied
        if not evaluator:
            return fail("invalid_token", "Unknown assessment link", status=404)
        if not is_assigned_candidate(evaluator):
            return fail("wrong_candidate",
                        "Only the assigned candidate can do this", status=403)
        if evaluator.is_locked and not locked_ok:
            return fail("attempt_locked",
                        "This attempt is already submitted", status=409)
        if self._seb_blocks(evaluator):
            return fail("seb_required",
                        "This assessment opens only in Safe Exam Browser.",
                        status=403)
        if begun and not evaluator.started_at:
            return fail("not_started",
                        "This assessment has not been started. Press Start "
                        "Assessment first.", status=409)
        # ONE SITTING AT A TIME, THE NEWEST TAB WINNING. `/state` and `/begin`
        # store the app's per-tab `session_key` (`_claim_session`); a write
        # carrying a different one comes from a tab since replaced, and would
        # overwrite what the live tab saved. No key (an app older than this
        # check) is admitted as before, and an expired attempt falls through to
        # the route's own time-up answer.
        session_key = str_arg("session_key", max_len=64)
        if one_tab is None:
            one_tab = begun
        if (one_tab and session_key and evaluator.exam_session_key
                and session_key != evaluator.exam_session_key
                and not evaluator.is_time_expired()):
            return fail("session_replaced",
                        "This exam is now open in another tab or device.",
                        status=409)
        return None

    def _session_is_current(self, evaluator):
        """Whether this request may STORE inside the grace after the deadline.

        `_write_guard` skips the session check once the clock has run out, so
        the time-up answer still lands. But "Continue Here" after a takeover
        starts a NEW key, and a request this tab sent before the reclaim (in
        a retry ladder, say) carries the old one: stored in the grace, it
        would overwrite the newer save. So only no key (an older client) or
        the attempt's current `exam_session_key` stores there; the sitting is
        settled either way. An attempt that never recorded a key has no
        session to protect, exactly as in `_write_guard`: it stores.
        """
        key = str_arg("session_key", max_len=64)
        current = evaluator.exam_session_key
        return not key or not current or key == current

    def _seb_blocks(self, evaluator):
        """True when locked mode is on and this request is not from inside
        Safe Exam Browser running this attempt's settings (`services/seb.py`).

        Only the candidate (or an anonymous visitor) is sent to SEB. A manager
        previewing and a signed-in wrong account fall through to their own
        gates. A paper that is closed or an attempt already submitted is not
        locked: its result screen opens anywhere.
        """
        assessment = evaluator.assessment_id
        if (not assessment.rule_require_seb or evaluator.is_locked
                or evaluator.state == "submitted"
                or assessment.state != "in_progress"):
            return False
        if not (request.env.user._is_public()
                or is_assigned_candidate(evaluator)):
            return False
        return not seb.proof_ok(evaluator,
                                str_arg("seb_url", max_len=2048),
                                str_arg("seb_key", max_len=128))

    def _claim_session(self, evaluator):
        """Make the calling tab the one holding this sitting (`/state` on the
        question gate, `/begin`). Written only when the key changes, so a
        reload or a question hop costs nothing."""
        session_key = str_arg("session_key", max_len=64)
        if session_key and session_key != evaluator.exam_session_key:
            evaluator.write({"exam_session_key": session_key})

    def _with_evidence_upload(self, payload, evaluator, preview=False):
        """Add `evidence_upload` (AI proctoring's S3 policy for THIS attempt's
        snapshots, `services/evidence.py`) to an open attempt's instructions or
        question envelope (`/state`, `/begin`, `/answer`'s `next`). Never for
        a manager's preview, never on any other outcome; omitted when the
        rule is off or storage is not configured."""
        if not preview and payload.get("outcome") in (GATE_INSTRUCTIONS,
                                                      GATE_QUESTION):
            policy = evidence.upload_policy(evaluator)
            if policy:
                payload["evidence_upload"] = policy
        return payload

    def _live_order(self, evaluator):
        """The attempt's question order, minus any question since deleted.

        A frozen order can outlive a question; serving a dangling id would
        strand the candidate on an item that cannot render.
        """
        order = json.loads(evaluator.question_order or "[]")
        if not order:
            return []
        live = set(request.env["assessments.be.question"].sudo()
                   .browse(order).exists().ids)
        return [q for q in order if q in live]

    def _answered_question_ids(self, evaluator):
        # `_is_answered`, so `/review`, the submit guard and the admin count
        # agree: a cleared answer (draft) and a placeholder are not answers.
        return set(request.env["assessments.be.response"].sudo().search([
            ("state", "=", "submitted"),
            ("assessment_evaluator_id", "=", evaluator.id),
        ]).filtered(lambda r: r._is_answered()).mapped("question_id.id"))

    def _unanswered_question_ids(self, evaluator):
        answered = self._answered_question_ids(evaluator)
        return [q for q in self._live_order(evaluator) if q not in answered]

    def _next_index(self, order, current_id, nav):
        """1-based index to move to, or None to go to the review screen.

        ``nav='review'`` means "save this answer, THEN review", which is why
        saving and navigating are one call: a separate review fetch would let
        the client lose the answer in hand.
        """
        total = len(order)
        if not total or nav == "review":
            return None
        try:
            current = int(current_id or 0)
        except (TypeError, ValueError):
            current = 0
        index = order.index(current) if current in order else 0
        if nav == "prev":
            return max(1, index)
        nxt = index + 2
        return nxt if nxt <= total else None

    def _question_payload(self, evaluator, token, requested_index=None,
                          preview=False):
        """The 'question' gate envelope: one item plus runner context.

        THE ONE PLACE A QUESTION IS SERVED. `/state`, `/begin` and `/answer`
        all reach a candidate's next item through here, so the `question.view`
        audit line is emitted once, here, rather than three times at the
        callers - and a fourth caller added later is instrumented for free.
        """
        t0 = audit.start()
        order = self._live_order(evaluator)
        if not order:
            # AN EMPTY PAPER IS BROKEN, NOT FINISHED.
            #
            # `_live_order` drops questions that have since been deleted, so an
            # empty order means this attempt has nothing to answer: either the
            # paper was launched with no questions, or every one of them was
            # deleted under a candidate who was mid-sitting. Reporting
            # `complete` told that candidate they had finished an exam they were
            # never shown, and the attempt then scores zero off no answers -
            # indistinguishable from someone who sat it and got everything
            # wrong. etp_local carried 5 such attempts.
            #
            # A candidate who HAS answered is a different case and still
            # completes: they did the work, and the questions disappearing
            # afterwards must not retract it.
            if not self._answered_question_ids(evaluator):
                audit.emit("question.view", evaluator, outcome="empty_paper",
                           t0=t0, preview=preview)
                return S.exam_state_envelope(GATE_CLOSED, evaluator, {
                    "preview": preview,
                    "reason": "This assessment has no questions to answer. "
                              "Nobody has marked you down for it - tell "
                              "whoever invited you, so they can fix the paper.",
                })
            return S.exam_state_envelope(GATE_COMPLETE, evaluator,
                                         {"preview": preview})
        answered = self._answered_question_ids(evaluator)
        index = None
        if requested_index:
            try:
                candidate_index = int(requested_index)
                if 1 <= candidate_index <= len(order):
                    index = candidate_index
            # OverflowError: a JSON `q` of 1e400 arrives as float("inf").
            except (TypeError, ValueError, OverflowError):
                index = None
        if index is None:
            # Resume where they left off: the first unanswered item.
            index = 1
            for i, qid in enumerate(order):
                if qid not in answered:
                    index = i + 1
                    break
        question_id = order[index - 1]
        question = request.env["assessments.be.question"].sudo().browse(
            question_id)
        response = request.env["assessments.be.response"].sudo().search([
            ("question_id", "=", question_id),
            ("assessment_evaluator_id", "=", evaluator.id),
        ], limit=1)
        payload = S.exam_state_envelope(GATE_QUESTION, evaluator, {
            "preview": preview,
            # A callable, so a question-cache hit never derives the boxes.
            "question": S.question_for_candidate(
                question, token, index, len(order), response,
                label_boxes=lambda: self._label_boxes(question)),
            "answered_question_ids": sorted(answered),
            "progress_percent": int(100.0 * len(answered) / len(order))
            if order else 0,
        })
        # Here, not at the callers: every question served refreshes the
        # policy, so an untimed paper's 60-minute one never runs out mid-sitting.
        self._with_evidence_upload(payload, evaluator, preview)
        audit.emit("question.view", evaluator, t0=t0, question=question_id,
                   idx=index, total=len(order), answered=len(answered),
                   preview=preview)
        return payload

    def _label_boxes(self, question):
        """Box numbers an image_label answer expects, for per-box inputs.

        The scoring key's numbering and its ONE overlay
        (`services/labelling.label_overlay`): ``{number, box_2d}`` pairs when
        the client draws the regions on the plain picture, bare numbers when
        the overlay is the baked picture or there is none. Only if that yields
        nothing: detections_json, then the count the answer key implies. The
        labels/descriptions are the answer key and are never included.
        """
        if question.question_type != "image_label":
            return []
        # THE SCORING KEY'S NUMBERING, and its one overlay (2026-09-29). This
        # used to prefer detections_json whatever the key was: on a question
        # graded by its authored 4-box key the candidate got 17 inputs over 17
        # detected markers and was graded on 4 other boxes.
        from odoo.addons.assessments_be_v2.services.labelling import (
            label_overlay,
        )
        _mode, boxes = label_overlay(question)
        if boxes:
            return boxes
        image = question.image_ids.filtered(lambda i: i.slot == "single")[:1]
        if image and image.detections_json:
            detections = S.loads(image.detections_json, [])
            boxes = {}
            for d in detections:
                if isinstance(d, dict) and isinstance(d.get("number"), int):
                    box = d.get("box_2d")
                    has_geometry = (
                        isinstance(box, (list, tuple)) and len(box) >= 4
                        and all(isinstance(v, (int, float)) for v in box[:4]))
                    boxes[d["number"]] = (
                        {"number": d["number"], "box_2d": list(box[:4])}
                        if has_geometry else None)
            if boxes:
                if all(v is not None for v in boxes.values()):
                    return [boxes[n] for n in sorted(boxes)]
                return sorted(boxes)
        try:
            from odoo.addons.assessments_be_v2.services import scoring
            # STRAIGHT FROM THE SERVICE. This used to import
            # `_ideal_labels_count` out of `controllers/portal.py`, which was
            # only ever a re-export of this same function - so the JSON API
            # depended on the QWeb runner's module for a pure helper. Worse, the
            # import sits inside the broad `except` below, so losing that module
            # would not have raised: it would have returned `[]`, and every
            # labelling question would have rendered ZERO input boxes over an
            # image with numbered boxes baked into it. Silent, and wrong in the
            # one way a candidate cannot work around.
            from odoo.addons.assessments_be_v2.services.labelling import (
                ideal_labels_count,
            )
            # NO cap, deliberately, so this resolves to
            # DEFAULT_IMAGE_LABEL_COUNT. The generator is reachable from here
            # (question.generator_id.image_label_count) but must not be used: the
            # boxes are already BAKED into the image the candidate is looking at,
            # so lowering a generator's cap after the fact would hide the input
            # for a box still drawn on their screen - the one direction of
            # inconsistency the cap must never create.
            count = ideal_labels_count(
                scoring._image_label_key(question).get("ideal_labels"))
        except Exception:  # noqa: BLE001 - never fail a question render
            _logger.exception("label box derivation failed for question %s "
                              "evaluator_id=%s", question.id,
                              request_evaluator_id())
            return []
        return list(range(1, count + 1))

    def _review_payload(self, evaluator, order):
        """The end-of-exam checklist: which items are answered."""
        answered = self._answered_question_ids(evaluator)
        questions = request.env["assessments.be.question"].sudo().browse(
            order)
        # `rows_unanswered`: the option rows (dimensions with options) of a
        # multi-row question that no stored response line answers, so a
        # reloaded runner can flag a partly answered grid. 0 when complete or
        # when the question has fewer than two option rows.
        picked = {}
        for response in request.env["assessments.be.response"].sudo().search([
                ("assessment_evaluator_id", "=", evaluator.id),
                ("question_id", "in", questions.ids)]):
            picked[response.question_id.id] = set(
                response.line_ids.question_dimension_id.ids)

        def rows_unanswered(question):
            option_rows = question.question_dimension_ids.filtered(
                "option_line_ids")
            if len(option_rows) < 2:
                return 0
            return len(set(option_rows.ids) - picked.get(question.id, set()))

        rows = [{"index": i + 1, "question_id": q.id, "name": q.name or "",
                 "answered": q.id in answered,
                 "rows_unanswered": rows_unanswered(q)}
                for i, q in enumerate(questions)]
        return {
            "rows": rows,
            "answered_count": len(answered),
            "total_questions": len(order),
            "unanswered": [q for q in order if q not in answered],
        }

    def _collect_label_answers(self, raw):
        """image_label per-box answers as {"1": "...", "2": "..."}.

        Accepts a JSON object (the body's ``label_answers``). Stored as JSON in
        the shared ``justification`` column, which is what scoring reads back.
        """
        if not isinstance(raw, dict):
            return {}
        labels = {}
        for key, value in raw.items():
            number = str(key).strip()
            if not number.isdigit():
                continue
            text = str(value or "").strip()[:_LABEL_VALUE_MAX_LEN]
            if text:
                labels[number] = text
        return {k: labels[k] for k in sorted(labels, key=int)}

    def _selected_option_lines(self, question, selected_option_ids):
        """Validated (0, 0, vals) command list for the chosen options.

        Every submitted option id is checked against the dimension it claims
        to belong to, so a crafted payload cannot attach an option from a
        different question (which would corrupt scoring) or duplicate one.
        """
        selected = set(selected_option_ids)
        if not selected:
            return []
        lines, seen = [], set()
        for dimension in question.question_dimension_ids:
            valid = set(dimension.option_line_ids.ids)
            for option_id in sorted(selected & valid):
                if option_id in seen:
                    continue
                seen.add(option_id)
                lines.append((0, 0, {
                    "question_dimension_id": dimension.id,
                    "selected_option_id": option_id,
                }))
        return lines

    def _answer_values(self, source=None):
        """``(selected_option_ids, justification, label_answers, updated_at,
        session_key, cleared, clip_answers)`` read off the request body, or off one
        `/answers/batch` item (``source``).

        ``updated_at`` is the client's ms-since-epoch stamp, None when absent
        or outside `_STAMP_MIN`..`_STAMP_MAX` (OverflowError included: a
        400-digit integer must not 500). ``session_key`` is the REQUEST's (a
        batch item has none of its own), None when absent."""
        stamp = arg("updated_at", source=source)
        try:
            stamp = None if isinstance(stamp, bool) else float(stamp)
        except (TypeError, ValueError, OverflowError):
            stamp = None
        if stamp is not None and not _STAMP_MIN <= stamp <= _STAMP_MAX:
            stamp = None  # NaN fails both comparisons and lands here too
        return (id_list_arg("selected_option_ids", source),
                str_arg("justification", max_len=_JUSTIFICATION_MAX_LEN,
                        source=source),
                arg("label_answers", source=source),
                stamp,
                str_arg("session_key", max_len=64) or None,
                bool_arg("cleared", source=source),
                arg("clip_answers", source=source))

    def _record_response(self, evaluator, question_id):
        """`/answer`'s save: parse the body, store it through
        `_record_response_values`, which holds every rule.

        Returns True when stored, `_STALE_SAVE` when skipped because this
        session already stored a newer edit, False when refused or held as a
        draft (the caller answers 422), `_CONCURRENT_SAVE` when a sibling
        request is storing this same answer, and `_CLEARED_SAVE` when the
        answer was emptied (`cleared: true`).
        """
        saved, reason = self._record_response_values(
            evaluator,
            request.env["assessments.be.question"].sudo().browse(question_id),
            *self._answer_values())
        # ONE flush for the save, here. Left to the next read, the next
        # question's search flushed the answer half-recomputed and its stored
        # related marks followed as a second UPDATE of the same row.
        request.env.flush_all()
        if not saved:
            return False
        return {"concurrent": _CONCURRENT_SAVE, "stale": _STALE_SAVE,
                "cleared": _CLEARED_SAVE}.get(reason, True)

    def _record_response_values(self, evaluator, question,
                                selected_option_ids, justification,
                                label_answers, updated_at=None,
                                session_key=None, cleared=False,
                                clip_answers=None):
        """Create or update one response and submit it.

        Returns ``(ok, reason)``: ``(True, "saved")``, ``(True, "concurrent")``
        (a sibling request is storing it), ``(True, "stale")`` (the SAME
        session already stored a newer ``updated_at``, so nothing is written;
        see `_update_response`), ``(True, "cleared")`` for ``cleared`` (see
        `_clear_response`), or False with
        ``unknown_question``, ``not_in_paper``, ``incomplete_answer`` or
        ``held_draft`` (kept as a draft, not submitted). Mirrors
        portal._record_response, including its IntegrityError retry: the
        (evaluator, question) unique index means a double-tap can race, and
        the loser must fold into the winner rather than 500.
        """
        Response = request.env["assessments.be.response"].sudo()
        if not question.exists():
            return False, "unknown_question"
        question_id = question.id
        if question_id not in json.loads(evaluator.question_order or "[]"):
            # The token scopes WHICH questions this attempt may answer; an id
            # outside the frozen order is not this candidate's to answer.
            return False, "not_in_paper"
        if cleared:
            # An emptied answer carries no content, whatever else was sent.
            selected_option_ids, justification, label_answers = [], False, None

        if question.question_type == "image_label":
            labels = self._collect_label_answers(label_answers)
            if labels:
                justification = json.dumps(labels, ensure_ascii=False)
        lines = self._selected_option_lines(question, selected_option_ids)
        # A transcription's category / characteristics / speakers. Absent from
        # the payload means "not sent", never "cleared": the stored ones stay.
        clip_json = None
        clip_category = None
        if question.question_type == "transcription" and not cleared:
            if isinstance(clip_answers, dict):
                clip = clean_clip_answers(clip_answers)
                clip_category = clip["category"]
                clip_json = json.dumps(clip, sort_keys=True)
        subjective = question.question_type in (
            "subjective_rubric", "image_prompt", "image_label",
            "video_prompt", "transcription")
        # A rubric authored in Form Studio carries its answer in the axes, and
        # its free-text item is usually conditional ("explain any FAILED
        # check"). Demanding prose from a candidate who passed everything
        # rejected a fully answered paper with a 422. Axes answered = complete;
        # a rubric with no axes is still pure prose and still requires it.
        carried_by_axes = (question.question_type == "subjective_rubric"
                           and bool(question.question_dimension_ids)
                           and bool(lines))
        # A category other than None means the clip is not transcribed, so an
        # empty box is that transcription's complete answer.
        not_transcribed = clip_category not in (None, "none")
        if (subjective and not justification and not carried_by_axes
                and not cleared and not not_transcribed):
            return False, "incomplete_answer"

        # An image_ab with prose but no verdict yet is NOT refused: the runner
        # autosaves the justification per keystroke, and a candidate who writes
        # first and picks second lost that text to a 422 (prod, 2026-09-29,
        # questions 1167/1178). It is held as a draft below instead.
        if not lines and not cleared and (
                question.question_type in ("mcq", "msq")
                or (question.question_type == "image_ab"
                    and not justification)):
            return False, "incomplete_answer"
        # An image/label question that also carries objective checks is only
        # complete once those checks are answered too; until then the text is
        # kept as a draft so nothing the candidate typed is lost.
        # video_prompt included: its checks are keyed sub-questions worth a
        # mark each now, so an unanswered one costs the candidate real marks and
        # must hold the answer as a draft rather than submit around it. Matches
        # the same gate in `action_submit`.
        #
        # A COMPARISON THAT ASKS FOR A JUSTIFICATION IS THE SAME SHAPE: the
        # verdicts are answered and the prose is not, so it is held as a draft
        # rather than refused outright. `S.wants_justification` is the one
        # derivation of Form Studio's switch, so this asks exactly what the
        # candidate's own screen was told to show - a box they were never shown
        # can never hold them up. Held rather than dropped because the verdicts
        # ARE marks: discarding them to punish an empty box would cost the
        # candidate answers they had already given, and the draft is promoted
        # the moment they type (or at expiry, which settles a paper regardless).
        # subjective_rubric too (2026-09-29): its rating items are marks just
        # like these checks, so prose with the ratings still blank is a draft,
        # not an answer that silently scores 0 on every rating.
        # Only axes with options to pick count: a Form Studio text item has
        # none, and gating on it would hold the answer as a draft forever.
        gate_incomplete = bool(
            question.question_type in ("subjective_rubric", "image_prompt",
                                       "image_label", "video_prompt")
            and question.question_dimension_ids.filtered("option_line_ids")
            and not lines)
        if question.question_type == "image_ab" and (
                not lines
                or (S.wants_justification(question) and not justification)):
            gate_incomplete = True

        domain = [("question_id", "=", question_id),
                  ("assessment_evaluator_id", "=", evaluator.id)]
        existing = Response.search(domain, limit=1)
        if existing and cleared:
            return self._clear_response(existing, updated_at, session_key)
        if existing:
            return self._update_response(
                existing, justification, lines, gate_incomplete, updated_at,
                session_key, clip_json)

        # A CLEAR WITH NO ROW YET IS STORED AS A CLEARED ROW (draft, empty),
        # not skipped: it carries its stamp, so an OLDER first save of this
        # question from the same session that lands after it is `stale`
        # instead of storing content the screen no longer shows.
        vals = {
            "assessment_id": evaluator.assessment_id.id,
            "assessment_evaluator_id": evaluator.id,
            "evaluator_id": evaluator.applicant_id.id,
            "question_id": question_id,
            "justification": justification,
            "line_ids": lines,
            # In the INSERT, so a stamped first save costs no extra write.
            "client_updated_at": updated_at or 0.0,
            "client_session_key": session_key or False,
            "cleared": cleared,
        }
        if clip_json is not None:
            vals["clip_answers_json"] = clip_json
        try:
            # NOTHING IS FLUSHED HERE. The default savepoint flushes the WHOLE
            # transaction on entry and exit, and `flush_recordset` wrote the
            # new row's computed marks as an UPDATE of their own: a save was 6
            # writes (2 of them on the attempt row) and a 6-item
            # `/answers/batch` 36, with the attempt's totals recomputed twice
            # per item. `create` runs its INSERT inside this block, so the
            # unique-index collision below is still caught here; the marks,
            # the `submitted` state and the totals go out together when the
            # request flushes (one UPDATE per table).
            #
            # A DEPARTURE FROM THE HOUSE RULE (odoo.md: "wrap caught ORM writes
            # in `env.cr.savepoint()`", the flushing one), and SAFE ONLY WHILE
            # `Response.create` FLUSHES NOTHING BEFORE ITS INSERT. A
            # non-flushing savepoint does not clear the cache on rollback, so
            # if `create` ever flushed other pending writes in here (a new
            # override, a constraint that searches), the rollback would undo
            # them while the cache still believed them stored: lost writes,
            # with no error. Re-check this if `create` changes.
            with request.env.cr.savepoint(flush=False):
                response = Response.create(vals)
        except IntegrityError:
            existing = Response.search(domain, limit=1)
            if not existing:
                # A COLLISION IS NOT AN INCOMPLETE ANSWER.
                #
                # The IntegrityError came from the (evaluator, question) unique
                # index, so a row for this answer certainly EXISTS - a sibling
                # request inserted it microseconds ago. That transaction has
                # not committed yet, so under READ COMMITTED this re-search
                # cannot see it, and returning False made the route answer
                # 422 "This answer is incomplete for its question type".
                #
                # Both halves of that sentence were untrue: the payload was
                # complete, and it had just been stored. The candidate saw a
                # red refusal over a question they had correctly answered -
                # observed as a 200 and a 422 on /answer three milliseconds
                # apart, because the runner's debounced autosave and its
                # navigation save both post the same answer.
                #
                # Accepted, so the caller does not refuse it - but THIS request
                # stored nothing. The winner is not guaranteed to carry this
                # payload: under write-behind a timer batch with OLDER content
                # can win the first INSERT while Next's `/answer` carries the
                # newer. Racing it with an UPDATE we cannot see would only
                # block on its row lock, so instead the client is TOLD
                # (`concurrent: true` on `/answer`, `reason: "concurrent"` on a
                # batch item) and re-sends, which lands as an ordinary update.
                return True, "concurrent"
            if cleared:
                return self._clear_response(existing, updated_at, session_key)
            return self._update_response(
                existing, justification, lines, gate_incomplete, updated_at,
                session_key, clip_json)
        if cleared:
            return True, "cleared"
        if gate_incomplete:
            return False, "held_draft"
        response.action_submit()
        return True, "saved"

    def _update_response(self, response, justification, lines,
                         gate_incomplete, updated_at=None, session_key=None,
                         clip_json=None):
        """Rewrite an existing answer, submitting it when it is complete.
        ``(ok, reason)`` as `_record_response_values`.

        ``clip_json``: a transcription's cleaned clip answers, or None when the
        payload carried none (the stored ones then stand)."""
        # AN OLDER SAVE NEVER OVERWRITES A NEWER ONE - INSIDE ONE SESSION. A
        # write-behind batch is retried, so it can land after a newer save
        # from the same tab; that is the one case acknowledged and dropped.
        # The stamps are the client's clock, so ANY other save (no key,
        # another tab or device, no stamp) goes through and replaces the
        # stamp. This cannot lock an answer AS LONG AS the client keeps its
        # stamp monotonic for the life of a session key, ACROSS RELOADS (the
        # runner persists a high-water mark for this). A client that breaks
        # the rule (a reload that restarts its clock lower under the same
        # key) is recovered by a new session key (a new tab) or by one
        # unstamped save, both of which replace the stamp.
        if self._is_stale(response, updated_at, session_key):
            return True, "stale"
        if response.cleared:
            # A real answer refills an emptied one, held draft included: a
            # row still `cleared` at settlement is overwritten as blank.
            response.write({"cleared": False})
        if gate_incomplete:
            if response.state != "submitted":
                # Compared first, like every write on this path: an unchanged
                # draft autosave would otherwise UPDATE the row only to move
                # `write_date`.
                if (response.justification or "") != (justification or ""):
                    response.write({"justification": justification})
                self._stamp_response(response, updated_at, session_key)
            # Over a SUBMITTED answer nothing is stored, so nothing is
            # stamped: the stamp must keep describing the answer on record.
            return False, "held_draft"
        # DIFF, never delete-all-and-re-add.
        #
        # THE BUG THIS FIXES. This used to be `response.line_ids.unlink()`
        # followed by a re-insert of the same lines. Both runners post an answer
        # more than once by design - the Flutter client's debounced autosave and
        # every navigation both send the current answer - so two requests
        # routinely rewrite the same response. Deleting every line made each of
        # them write rows the other was reading:
        #
        #     ERROR: could not serialize access due to concurrent delete
        #     DELETE FROM "assessments_be_response_line" WHERE id IN (...)
        #
        # Odoo replays a serialization failure (`service.model.retrying`), but
        # at 588 concurrent candidates the collisions exhausted all five
        # attempts - `_retry=5` in the logs - and surfaced as a 500 on a THIRD
        # of every answer save during the 2026-09-03 assessment. No answer was
        # lost, because the client re-posts, but candidates burnt their clock on
        # retries and 58 attempts auto-submitted with questions unanswered.
        #
        # Re-posting an unchanged answer now writes NOTHING - no delete, no
        # insert - so there is no row for a sibling request to collide with.
        # ONE implementation, in `services/`. It used to be imported out of
        # `controllers/portal.py` - one controller reaching into another for the
        # write rule at the centre of its own hot path. The import is
        # function-local, so that dependency would not have failed at install
        # time; it would have failed at REQUEST time, as a 500 on every answer
        # save, which is the same symptom this function exists to have fixed.
        from odoo.addons.assessments_be_v2.services.answer_lines import (
            reconcile_response_lines,
        )
        reconcile_response_lines(response, lines)
        # Only when it actually differs. An unchanged re-post of an already
        # submitted answer must not write the row at all: `write` bumps
        # `write_date`, and that UPDATE is itself a row two concurrent saves
        # can serialize against.
        if (response.justification or "") != (justification or ""):
            response.write({"justification": justification})
        if clip_json is not None and \
                (response.clip_answers_json or "") != clip_json:
            response.write({"clip_answers_json": clip_json})
        if response.state != "submitted":
            response.action_submit()
        elif (response.justification or "").strip() \
                or response.question_id.question_type in (
                    "image_ab", "transcription"):
            # Already submitted and edited: re-queue subjective scoring. The
            # model dedups on a hash of the text, so unchanged text is not
            # re-graded (that would be a candidate-driven cost loop).
            response._enqueue_subjective_scoring()
        # LAST, so it joins the answer's own UPDATE at the request's flush
        # instead of being flushed early by the line diff above.
        self._stamp_response(response, updated_at, session_key)
        return True, "saved"

    @staticmethod
    def _stamp_response(response, updated_at, session_key):
        """Replace the answer's ordering stamp with this save's - both
        fields, even when absent, so a later save is compared with the save
        actually on record. Compared first: an unchanged pair writes
        nothing."""
        vals = {}
        if (response.client_updated_at or 0.0) != (updated_at or 0.0):
            vals["client_updated_at"] = updated_at or 0.0
        if (response.client_session_key or False) != (session_key or False):
            vals["client_session_key"] = session_key or False
        if vals:
            response.write(vals)

    @staticmethod
    def _is_stale(response, updated_at, session_key):
        """The stale rule (see `_update_response`): the SAME session already
        stored a newer edit. Shared by a save and a clear, so a clear stored
        first makes an older same-session save `stale`. Across sessions the
        last write wins, a clear included."""
        return bool(updated_at is not None and session_key
                    and session_key == response.client_session_key
                    and updated_at < (response.client_updated_at or 0.0))

    def _clear_response(self, response, updated_at=None, session_key=None):
        """Empty a stored answer: no options, no text, `cleared`, back to
        draft so it is neither graded nor counted, and the grade it may carry
        dropped. Same stale rule and stamp as a save; every field compared
        first, so a repeated clear writes nothing. ``(ok, reason)``."""
        if self._is_stale(response, updated_at, session_key):
            return True, "stale"
        from odoo.addons.assessments_be_v2.services.answer_lines import (
            reconcile_response_lines,
        )
        was_graded = response.needs_llm
        reconcile_response_lines(response, [])
        # The old grade's prose goes too, or the CSV and the admin audit keep
        # showing a verdict on text that no longer exists.
        vals = {k: v for k, v in {
            "cleared": True, "state": "draft", "justification": False,
            "llm_state": "not_needed", "llm_raw_100": 0.0,
            "llm_feedback": False, "llm_verdict": False,
            "llm_reasoning": False, "llm_deductions_json": False,
            "llm_credit_json": False, "label_box_scores_json": False,
            "llm_judge_model": False, "clip_answers_json": False,
            "llm_critical_count": 0, "llm_minor_count": 0,
        }.items() if (response[k] or False) != v}
        if vals:
            response.write(vals)
        self._stamp_response(response, updated_at, session_key)
        if was_graded and response.assessment_evaluator_id:
            # A written answer just left the grader's set.
            response.assessment_evaluator_id._compute_subjective_rollup()
        return True, "cleared"

    def _record_violation(self, evaluator, reason, client_at=None):
        """Record one violation and act on the assessment's policy.

        The COUNTING, DEDUPE and LOGGING now live on the model
        (`evaluator._record_violation`) so this path and the portal path cannot
        drift; see that method for why the counter bump and the log append share
        one atomic UPDATE. This wrapper keeps what is genuinely this route's:
        the 'Log only means log only' policy decision and the auto-submit tail
        it drives.

        A deduped beacon returns None from the model and is a no-op here too -
        one physical action counts once and ends the sitting at most once.
        So does a report sent again with a `client_at` already recorded.
        """
        assessment = evaluator.assessment_id
        new_count = evaluator._record_violation(reason, client_at=client_at)
        if new_count is None:
            return False
        # EACH KIND BY ITS OWN PAIR (R5). The model returned that kind's own
        # count; an "AI: " reason is held to the AI limit and mode (when the
        # paper's AI proctoring is on), anything else to the regular ones, and
        # the ending names which.
        ai = evaluator._counts_as_ai(reason)
        cap = (assessment.ai_max_violations if ai
               else assessment.max_violations) or 0
        action = (assessment.ai_violation_action if ai
                  else assessment.violation_action)
        # LOG ONLY MEANS LOG ONLY (owner, A-074, clarified 2026-09-24):
        # "Log violations captures violations, lists them but never end the
        # paper. Auto-submit ends the paper upon breaching number of
        # violations." Under Log only a reached cap is a label
        # (`violation_limit_breached`), never an ending, and the count keeps
        # rising for the admin to read. Under Auto-submit, cap 0 ends the
        # sitting on the very first violation.
        if action != "auto_submit":
            end_now = False
        elif cap:
            end_now = new_count >= cap
        else:
            end_now = True
        if end_now:
            # Also not an expiry: the attempt is being ended by proctoring,
            # usually with time still on the clock. Naming the real cause is
            # what lets an appeal be answered.
            evaluator.sudo()._auto_submit_expired(
                blank_reason="[Auto-submitted: proctoring violation (%s)]"
                             % reason,
                reason_code="ai_violation" if ai else "violation")
        return True
