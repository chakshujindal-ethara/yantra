# -*- coding: utf-8 -*-
"""Admin surface: assessments, launch gates, generators, drafts, bank, scoring.

House rule for this file: where assessments_be_v2 already has an action that
does the work (action_start, action_confirm_release, action_llm_score_all,
action_approve, action_deny, action_rescore_individually, ...) the route
CALLS it. Reimplementing a lifecycle transition here would fork the audit
trail (those actions post to the chatter), the validation and the side effects
- the API would then be able to reach states the backend refuses.

Reads are ACL-checked by the ORM under the caller's own user, not sudo: an
Evaluator sees what an Evaluator may see. sudo() appears only where a lookup
is a pure existence check.
"""
import json
import logging
import math
import random
from collections import namedtuple
from datetime import datetime, timedelta, timezone

from botocore.exceptions import BotoCoreError, ClientError
from markupsafe import Markup, escape as html_escape

from odoo import fields, http, tools
from odoo.exceptions import UserError
from odoo.http import request

from odoo.addons.assessments_be_v2.constants import (
    ADVISORY_LOCK_IMAGE_RENDER,
    ADVISORY_LOCK_QUESTION_GEN,
    ADVISORY_LOCK_VIDEO_POLL,
    CRON_LOCK_MODE_SELECTION,
    DEFAULT_DAILY_LLM_CAP_USD,
    DEFAULT_PER_EVALUATOR_LLM_CAP_USD,
    IMAGE_RENDER_BATCH,
    SCORE_OUTLIER_SIGMA_DEFAULT,
)

from ...services import (
    evidence, model_catalog, pace, question_cache, s3_service, secret_store,
)
# IMPORTED FOR THEIR RESOLVERS, not to do any work here. `vertex.spend_cap`,
# `scoring._max_attempts` and `scoring._scoring_batch_size` are what the
# runtime itself reads, and every number this file reports about a cap or a
# scheduler knob goes through them. Resolving a parameter locally instead is
# exactly what made these screens disagree with the gate they report on, so the
# two private names are imported deliberately rather than re-implemented here
# behind a public one.
from ...services import scoring as scoring_svc
from ...services import vertex as vertex_svc
from ...models.assessment import RescoreRefused
from ...models.hr_applicant import _norm_email, candidate_row_error
from .. import media_stream
from . import serializers as S
# The exam routes' own reader, so the console shows what they advertise.
from .candidate import _answers_flush_seconds, _paper_prefetch
from .common import (
    API_METHODS, API_TYPE, GROUP_MANAGER, MAX_LEADERBOARD, MAX_LIMIT,
    api_endpoint, arg, bool_arg, fail, id_list_arg, id_list_arg_strict,
    int_arg, is_operator, ok, paged, paging,
    record_read_guard, require_manager, require_operator, require_staff,
    str_arg,
)

_logger = logging.getLogger(__name__)


# THE ONLY SCORING STATES A RETRY MAY RESET, and the money guard behind
# `/api/v1/scoring/requeue_errored`. Module level so a test can pin it: this was
# once validated against the response `llm_state` Selection instead, which
# contains 'scored', so a manager could name that state and have every paid
# answer re-graded and re-billed. Widening this tuple spends real money.
RECOVERABLE_SCORING_STATES = ("failed", "error")

# EVERY OFFSET-PAGED LISTING NEEDS A TOTAL ORDER, and `create_date` is not one.
#
# Odoo stamps `create_date` from `cr.now()`, the TRANSACTION timestamp, so every
# row a bulk write creates carries an identical value to the microsecond. Offset
# paging re-runs the query per page, and Postgres orders equal keys by whatever
# the plan happens to produce: `LIMIT n OFFSET k` is a bounded top-N heapsort
# while `n + k` is below the row count and an unbounded quicksort once it is
# not, and the two emit ties in different orders. A row can therefore land on
# two pages while another lands on none.
#
# That is not theoretical. Walking `/api/v1/attempts` on stage at limit=200,
# exactly as the app's attempt walk does: `total` 2538, 2538 rows collected,
# **2077 distinct**, 461 attempts never returned once. The COUNT was right and
# the rows were wrong, so every state chip and KPI read correctly over a
# corrupted sample - which is why nobody saw it until a candidate search
# rendered one person twice and another not at all.
#
# `id` is the tiebreaker everywhere because it is the primary key: unique by
# definition, never null, already indexed, and on a newest-first listing it
# descends with the primary sort so the composite reads as one intent.
#
# WHAT THIS DOES NOT FIX, stated plainly because a caller could reasonably
# assume otherwise. A total order removes the instability WITHIN one walk of
# unchanged data. It does not make the walk a snapshot: offset paging still
# re-runs the query per page, so a row created or deleted between page 3 and
# page 4 shifts every later offset, and a walk that straddles a bulk invitation
# can still miss or repeat rows for that reason. The difference is that the loss
# is now bounded by concurrent WRITES rather than guaranteed by the SORT - 461
# of 2538 attempts were being lost with no writes happening at all.
#
# Nothing in the console currently depends on a guarantee stronger than this.
# `/api/v1/attempts` is polled every ~2s during generation and re-walked from
# offset 0 each time, so a mid-walk shift self-corrects on the next poll; the
# per-assessment roster is paged by an operator clicking, where the same shift
# reads as "a candidate was just invited". A surface that needed a true snapshot
# would have to page by keyset (`WHERE (create_date, id) < (:last_date, :last_id)`)
# rather than by offset, and none does today.
#
# NOT FIXED BY CHANGING THE MODEL'S `_order`. `assessments.be.evaluator._order`
# is deliberately left alone: it governs every back-office list, every embedded
# one2many and every bare `search()` in the addon, which is far wider than the
# defect. The explicit `order=` on each paged route is the narrow fix.
_NEWEST_FIRST = "create_date desc, id desc"

# `/api/v1/attempts?changed_since=`: the most recently changed first, `id` the
# tiebreaker for the reason above. Descending also means a row that changes
# mid-walk jumps to the FRONT, so a walk can repeat a row but never skip one it
# has not reached; the one that jumped is caught by the next poll.
_CHANGED_FIRST = "write_date desc, id desc"


def _utc_arg(name):
    """An ISO-8601 argument as a naive UTC datetime (how Odoo stores them), or
    None when absent. Raises ValueError when unreadable. No offset is read as
    UTC, the only zone this API speaks (`S.iso`)."""
    raw = str_arg(name, max_len=64)
    if not raw:
        return None
    stamp = datetime.fromisoformat(raw)  # 3.11+: reads a trailing "Z"
    if stamp.tzinfo:
        stamp = stamp.astimezone(timezone.utc).replace(tzinfo=None)
    return stamp

# THE ROSTER'S SORTABLE COLUMNS, keyed by the UI column and NOT by the field.
#
# An ALLOW-LIST, not a passthrough. `search(order=...)` takes any stored field
# on the model, so forwarding the client's string would let a caller order the
# roster by `access_token` (a bearer credential) or by any other column the UI
# never offers - and would 500 on a typo. Naming the nine columns here is what
# bounds it, and it is also the mapping itself: the CANDIDATE header sorts by
# `candidate_name` and the STATE header by `state_rank`, neither of which is
# the field the column renders.
#
# `candidate_name` and `state_rank` exist BECAUSE of this dict - see the two
# fields on `assessments.be.evaluator`, which record why sorting the rendered
# `applicant_id` and the raw `state` key would both have ordered the table by
# something the operator cannot see.
_SORTABLE = {
    "candidate": "candidate_name",
    "invite": "invite_state",
    "state": "state_rank",
    "answered": "answered_count",
    # `score_percent` AND NOT `total_score`, which is the OBJECTIVE sub-total
    # only (`objective_total` is an alias of it). The SCORE cell renders
    # `score_marks` - earned over the paper's component count, objective AND
    # graded subjective - and the RESULT pill beside it is decided by
    # `score_percent` over that same fraction. Sorting by `total_score` ordered
    # a subjective-heavy paper by its MCQ section alone, so "16 / 20" sat below
    # "5 / 20" under a descending caret. It is also the only key here that is
    # normalised: the denominator varies per drawn paper, which a bare
    # numerator cannot rank across candidates.
    "score": "score_percent",
    "result": "result",
    "released": "results_released",
    "remarks": "manual_remark",
    "flag": "manual_flagged",
}


def _attempt_order():
    """The ORDER BY for a roster page. ALWAYS a total order.

    EVERY BRANCH ENDS IN `id`, in the same direction as the column, and that is
    the whole reason this is a function rather than an expression at the call
    site. The `_NEWEST_FIRST` block above measures what a paged walk without a
    total order costs: 2538 rows collected, 2077 distinct, 461 attempts never
    returned once. These columns tie far worse than `create_date` did -
    `results_released` and `manual_flagged` are BOOLEANS, so sorting a 711-row
    cohort by FLAG puts ~700 rows on one key, and `manual_remark` is empty on
    nearly all of them. Without the tiebreaker that is not an edge case a big
    cohort might hit, it is every page of every sort.

    AN UNKNOWN OR ABSENT KEY IS NOT AN ERROR. A client one deploy behind, or
    one that remembers a column that has since been renamed, must get the
    roster it has always got - degrading to newest-first loses nothing, while
    a 400 loses the whole table over a sort nobody would miss.
    """
    field = _SORTABLE.get(str_arg("sort"))
    if not field:
        return _NEWEST_FIRST
    direction = "desc" if bool_arg("sort_desc") else "asc"
    return "%s %s, id %s" % (field, direction, direction)


# W8 - "SCORED" AND "SCORE PENDING", DEFINED ON ANSWERS, not on the attempt's
# own `llm_state`: an objective-only attempt is never rolled up and keeps
# `pending` for ever. Score Pending = submitted with at least one answer that
# needs the grader and is not scored (queued, never queued, in flight, partial,
# failed, error, cancelled, archived paper). Scored = every other submitted
# attempt, so the two always add up to Submitted. A queued re-score leaves the
# old mark in place, so it keeps the candidate in Scored. Same predicate as
# `assessments.be.awaiting_scoring_count`.
def _scoring_chip(state):
    """`scored` / `score_pending` as a domain - the evaluator's one definition,
    shared with the "Scored X/Y" line, so the chips and the line agree."""
    return request.env["assessments.be.evaluator"]._answers_scored_domain(
        scored=(state == "scored"))


_SCORING_CHIPS = ("scored", "score_pending")


def _state_domain(state):
    """The roster's `state` filter. Empty or `all` is everyone; `scored` and
    `score_pending` split Submitted by its answers; anything else is the
    attempt's own `state`, as it always was."""
    if not state or state == "all":
        return []
    if state in _SCORING_CHIPS:
        return _scoring_chip(state)
    return [("state", "=", state)]


#: One person an assign request names: where they came from (`id`, `user`
#: or `row`), their name and address, the applicant found for them (maybe
#: none yet) and the account already bound to them (maybe none).
_Entry = namedtuple("_Entry", "source name address found user")


class EtpAssessmentApiAdmin(http.Controller):

    # Assessments

    @http.route("/api/v1/assessments", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_operator
    def assessment_list(self, **kw):
        Assessment = request.env["assessments.be"]
        domain = []
        state = str_arg("state")
        if state:
            domain.append(("state", "=", state))
        search = str_arg("search", max_len=128)
        if search:
            domain.append(("name", "ilike", search))
        if bool_arg("include_archived"):
            Assessment = Assessment.with_context(active_test=False)
        limit, offset = paging()
        total = Assessment.search_count(domain)
        records = Assessment.search(
            domain, limit=limit, offset=offset, order=_NEWEST_FIRST)
        return paged([S.assessment_row(a) for a in records],
                     total, limit, offset)

    @http.route("/api/v1/assessments/<int:assessment_id>", type=API_TYPE,
                auth="user", methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_operator
    def assessment_detail(self, assessment_id, **kw):
        assessment = request.env["assessments.be"].browse(
            assessment_id).exists()
        if not assessment:
            return fail("not_found", "Assessment not found", status=404)
        # No `candidates`: the app reads `roster` and pages `/candidates`, and
        # every attempt serialised here was 904 KB of a 1 MB payload on a
        # 750-candidate paper.
        return ok(S.assessment_detail(assessment))

    @http.route("/api/v1/assessments/<int:assessment_id>/launch",
                type=API_TYPE, auth="user", methods=API_METHODS, csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def assessment_launch(self, assessment_id, **kw):
        """Evaluate the launch gates, then optionally launch.

        EVERY GATE IS ALWAYS EVALUATED - the loop never short-circuits.
        action_start raises on the FIRST problem it meets, so an admin fixing
        a launch played whack-a-mole: fix the missing generator, discover the
        keyless question, fix that, discover the unreviewed rubric. The API
        reports every failing gate with its own reason in one response.

        A dry run (the default) only reports. Pass ``confirm: true`` to launch,
        which delegates to action_start so the real transition, the chatter
        audit entry, the shared question draw and the invite queueing
        all stay in the model.
        """
        assessment = request.env["assessments.be"].browse(
            assessment_id).exists()
        if not assessment:
            return fail("not_found", "Assessment not found", status=404)
        gates = self._launch_gates(assessment)
        can_launch = all(g["passed"] for g in gates)
        if not bool_arg("confirm"):
            return ok({"gates": gates, "can_launch": can_launch,
                       "launched": False, "dry_run": True})
        if not can_launch:
            failed = [g for g in gates if not g["passed"]]
            # NAME THEM. This counted them - "2 launch gate(s) failed" - while
            # holding every reason it had just computed. A client that toasts
            # the message (every client does) threw the diagnosis away, and the
            # operator was left to guess which two of eight refused. That is
            # not hypothetical: Sprint 3A was refused for a shortlist drawn
            # from a different generator than the one it points at, and the
            # only way to learn that was to read the database.
            #
            # `failed_gates` stays a list of CODES - a client may branch on
            # them and must not have to parse prose. The message is for people.
            return fail("launch_blocked",
                        "Launch blocked: %s" % "; ".join(
                            "%s - %s" % (g["label"], g["reason"]) if g["reason"]
                            else g["label"] for g in failed),
                        status=422, gates=gates,
                        failed_gates=[g["code"] for g in failed])
        assessment.action_start()
        assessment.invalidate_recordset()
        return ok({"gates": gates, "can_launch": True, "launched": True,
                   "assessment": S.assessment_detail(assessment)})

    def _launch_gates(self, assessment):
        """The 8 preconditions action_start enforces, each evaluated alone,
        plus the `grading_keys` warning, which never blocks.

        The first four are cheap record checks; the rest need the candidate
        question pool, so it is resolved once and shared. When the pool cannot
        be built (no generator) the downstream gates report that as their
        reason rather than crashing - a gate must always return a verdict.
        """
        gates = []
        # DURATION IS A LAUNCH GATE, not just a field constraint. The model
        # constraint only fires when somebody writes the field, and launching
        # does not, so without this an assessment already sitting at 0 could be
        # launched and its candidates invited to a paper with no clock and no
        # way for the expiry cron to ever sweep it. It is first because it is
        # the cheapest and because it is the one that got through.
        timed = assessment.duration_minutes >= 2
        gates.append(S.launch_gate(
            "duration", "Duration is at least 2 minutes", timed,
            "" if timed
            else "Duration is %s minutes. Set at least 2 before launching."
                 % assessment.duration_minutes))
        # An ARCHIVED draft is refused here too (in this gate, so the gate
        # list keeps its shape), as `action_start` refuses it.
        # Archived: one sentence as the label, no reason, so the refusal
        # does not read "Assessment is in Draft - The assessment is archived".
        if assessment.state == "draft" and not assessment.active:
            gates.append(S.launch_gate(
                "state", "The assessment is archived; restore it before "
                "launching", False))
        else:
            gates.append(S.launch_gate(
                "state", "Assessment is in Draft", assessment.state == "draft",
                "" if assessment.state == "draft"
                else "State is '%s'; only a draft assessment can be launched."
                     % assessment.state))
        gates.append(S.launch_gate(
            "candidates", "At least one candidate assigned",
            bool(assessment.evaluator_ids),
            "" if assessment.evaluator_ids
            else "No candidates assigned. Add candidates before launching."))
        has_generator = bool(assessment.generator_id)
        gates.append(S.launch_gate(
            "generator", "Question generator selected", has_generator,
            "" if has_generator
            else "No question generator selected."))

        if not has_generator:
            blocked = "Cannot check: no question generator selected."
            gates.append(S.launch_gate(
                "questions_available", "Generator has servable questions",
                False, blocked))
            gates.append(S.launch_gate(
                "question_limit", "Requested question count is available",
                False, blocked))
            gates.append(S.launch_gate(
                "answer_keys", "Every objective question has an answer key",
                False, blocked))
            gates.append(S.launch_gate(
                "reviewed_rubrics", "Subjective rubrics are human-reviewed",
                False, blocked))
            return gates

        # INVARIANT 1: only ACTIVE, NON-RETIRED questions that carry the media
        # their type requires are servable. This is the same filter
        # action_start applies, so the count here is the real pool a candidate
        # would draw from. Retired questions stay active records so the
        # assessments that already used them keep resolving, which means
        # nothing else excludes them here - and without the explicit test this
        # gate promised the operator questions the launch would then refuse to
        # draw, so the count and the pool disagreed exactly when a deletion had
        # just happened.
        pool = request.env["assessments.be.question"].search([
            ("generator_id", "=", assessment.generator_id.id),
            ("active", "=", True),
            ("retired", "=", False),
        ]).filtered(
            lambda q: q._has_required_images() and q._has_required_videos())
        # NARROWED BY THE DRAFT'S SHORTLIST, exactly as `action_start` narrows
        # it. Without this the dry run counts the whole generator: a shortlist
        # of 5 with the limit left at 12 reported `question_limit` PASSING, the
        # operator pressed confirm, and `action_start` raised a UserError this
        # route cannot render as a gate failure. Same reason `answer_keys` asks
        # the model instead of re-deriving the rule - a gate that disagrees with
        # the launch spends the operator's confidence before it wastes their
        # time.
        shortlist = set(assessment.question_ids.ids)
        if shortlist:
            pool = pool.filtered(lambda q: q.id in shortlist)
        limit = assessment.question_limit or len(pool)
        enough = bool(pool) and limit <= len(pool)
        # Only priced when a pool gate actually fails: on the happy path this
        # route is polled by the console and owes nobody an extra count.
        retirement = ("" if pool and enough
                      else self._retirement_note(assessment))
        # NAME THE SHORTLIST WHEN THE SHORTLIST IS THE BLOCKER. Attributing an
        # empty pool to the generator sends the operator to fix the wrong
        # screen: the generator may be full and every servable question simply
        # excluded by hand.
        gates.append(S.launch_gate(
            "questions_available", "Generator has servable questions",
            bool(pool),
            "" if pool
            else ("None of the %d shortlisted question(s) is still usable. "
                  "Re-shortlist under Selected Questions, or clear the "
                  "shortlist to use the whole generator.%s"
                  % (len(shortlist), retirement)) if shortlist
            else ("No usable questions with their required media in generator "
                  "'%s'.%s" % (assessment.generator_id.name or "",
                               retirement))))
        gates.append(S.launch_gate(
            "question_limit", "Requested question count is available", enough,
            "" if enough
            else ("Requested %d question(s) but only %d are servable%s.%s%s"
                  % (limit, len(pool),
                     " in the shortlist" if shortlist else "",
                     assessment._dropped_shortlist_note(pool), retirement))))

        # ASKS THE MODEL, DOES NOT RE-DERIVE THE RULE. This was a hand-copy of
        # `action_start`'s gate and the two had already drifted once: this side
        # exempted a dimensionless objective question that `action_start`
        # refused, so the dry run reported `answer_keys` PASSING, the operator
        # pressed confirm, and `action_start` raised a UserError this route does
        # not render as a gate failure. A gate that disagrees with the one that
        # actually runs is worse than no gate: it spends the operator's
        # confidence before it wastes their time. One method, one verdict.
        keyless = pool.filtered(lambda q: q._keyless_reason())
        gates.append(S.launch_gate(
            "answer_keys", "Every question has something markable on it",
            not keyless,
            "" if not keyless
            else "%d question(s) would score 0 for every candidate: %s"
                 % (len(keyless),
                    ", ".join("%s (%s)" % (q.name, q._keyless_reason())
                              for q in keyless[:10]))))

        # A WARNING, NEVER A BLOCK: `passed` is always true. A question the
        # grader reads with no usable answer key is still graded - against its
        # task alone - and each answer is flagged `no_answer_key`.
        unkeyed = pool.filtered(scoring_svc.lacks_answer_key)
        gates.append(dict(S.launch_gate(
            "grading_keys", "Graded questions have an answer key", True,
            "" if not unkeyed
            else "Warning: %d question(s) have no answer key; their answers "
                 "will be graded against the task alone and flagged 'no "
                 "answer key': %s" % (
                     len(unkeyed), ", ".join(unkeyed.mapped("name")[:10]))),
            warning=bool(unkeyed)))

        # GOVERNANCE gate: only enforced when the assessment opts in, but it
        # is always REPORTED so an admin can see it is off.
        if assessment.require_reviewed_rubric:
            unreviewed = pool.filtered(
                lambda q: q.has_subjective and not q.rubric_reviewed)
            gates.append(S.launch_gate(
                "reviewed_rubrics", "Subjective rubrics are human-reviewed",
                not unreviewed,
                "" if not unreviewed
                else "%d subjective question(s) have an unreviewed rubric: %s"
                     % (len(unreviewed),
                        ", ".join(unreviewed.mapped("name")[:10]))))
        else:
            gates.append(S.launch_gate(
                "reviewed_rubrics",
                "Subjective rubrics are human-reviewed (not required)", True,
                ""))
        return gates

    def _retirement_note(self, assessment):
        """Name retirement as the blocker, and the only ways out of it.

        The pool gates used to say "no ACTIVE questions", which is not what
        happened: a retired question keeps active=True on purpose (the papers
        already built must keep resolving it), and the bank screen labels those
        very rows "Retired". So the operator read "no active questions" while
        looking at the rows in question and went hunting for an archiving
        problem that does not exist.

        Worse, a draft whose whole pool has been retired is STUCK: it cannot
        launch, and the question picker correctly excludes retired questions,
        so it cannot be re-picked either. The two genuine ways out are
        /api/v1/bank/<id>/restore (un-retire the questions) and choosing a
        different generator. reset_draft is NOT one of them: action_reset_draft
        refuses anything that is not cancelled, so it cannot unstick a draft.

        Returns "" - and the gate keeps its old wording - when no retirement is
        involved, because then it really is a media or authoring problem.
        """
        # The complement of the pool query above, under the caller's own ACL
        # like the pool is: active rows the bank hides because they are
        # retired.
        # Archived (restorable) and deleted (never) are counted apart, so the
        # advice below only offers Restore for what Restore can bring back.
        Question = request.env["assessments.be.question"]
        pool = [("generator_id", "=", assessment.generator_id.id),
                ("active", "=", True), ("retired", "=", True)]
        retired = Question.search_count(pool + [("deleted", "=", False)])
        deleted = Question.search_count(pool + [("deleted", "=", True)])
        held = (len(assessment.question_ids.filtered("retired"))
                if assessment.state == "draft" else 0)
        parts = []
        if retired:
            parts.append(
                "%d question(s) in this generator are retired from the bank, "
                "and a retired question is never drawn into a new assessment."
                % retired)
        if deleted:
            parts.append(
                "%d question(s) in this generator are deleted and can never "
                "be drawn again." % deleted)
        if held:
            parts.append(
                "This draft still holds %d retired question(s), and the "
                "picker only offers un-retired ones, so there is nothing to "
                "swap in."
                % held)
        if not parts:
            return ""
        parts.append("Restore them in the bank, or select a generator that "
                     "still has questions." if retired or held else
                     "Select a generator that still has questions.")
        return " " + " ".join(parts)

    @http.route("/api/v1/assessments/<int:assessment_id>/release",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def assessment_release(self, assessment_id, **kw):
        """Release results - the deliberate human act INVARIANT 3 requires.

        Releases the whole submitted cohort when ``evaluator_ids`` is absent,
        or just the ids it names; a present but unreadable ``evaluator_ids`` is
        422 `invalid` and releases nobody. Both paths call the model's own
        release action so the chatter audit line is written either way.

        A CANDIDATE A LANE IS GRADING RIGHT NOW IS SKIPPED, not released:
        writing that row hands the lane a SerializationFailure and its paid
        results are bought again. ``released_count`` and ``skipped_count``
        come from the action, ``candidates`` lists only who this call
        released, and any skip adds a warning ``notice``.
        """
        assessment = request.env["assessments.be"].browse(
            assessment_id).exists()
        if not assessment:
            return fail("not_found", "Assessment not found", status=404)
        # Strict: an unreadable `evaluator_ids` must not fall through to the
        # whole-cohort release, which cannot be undone.
        try:
            evaluator_ids = id_list_arg_strict(
                "evaluator_ids", "evaluator ids", null_ok=False)
        except ValueError as exc:
            return fail("invalid", str(exc), status=422)
        if evaluator_ids is not None:
            targets = assessment.assessment_evaluator_ids.filtered(
                lambda e: e.id in evaluator_ids and e.state == "submitted")
            if not targets:
                return fail("nothing_to_release",
                            "No submitted candidates matched those ids",
                            status=422)
            pending = targets.filtered(lambda e: not e.results_released)
            action = targets.action_release_results()
        else:
            pending = assessment.assessment_evaluator_ids.filtered(
                lambda e: e.state == "submitted" and not e.results_released)
            if not pending:
                return fail("nothing_to_release",
                            "No submitted candidates awaiting release",
                            status=422)
            # `action_release_all_results` is the Odoo BUTTON, which opens the
            # counted confirm dialog first. The write it confirms is
            # `action_confirm_release`; the console runs its own sheet, so the
            # route goes straight to the write.
            action = assessment.action_confirm_release()
        # Only what this call released: not the skipped, not earlier releases.
        released = pending.filtered("results_released")
        counts = action["release"]
        payload = {
            "released_count": counts["released"],
            "skipped_count": counts["skipped"],
            # Warn (do not block): released with marks still to fill in.
            "still_grading_count": len(
                released.filtered(lambda e: e.subjective_pending)),
            "candidates": [S.evaluator_admin_row(e) for e in released],
        }
        if counts["skipped"]:
            # Both app builds toast a `notice` in place of their fixed
            # "Result released"; neither bulk toast reads `skipped_count`.
            payload["notice"] = {
                "kind": "warning",
                "title": "Results Released",
                "message": (
                    "Released %d result(s). %d candidate(s) being graded "
                    "right now were not released - try again in a minute."
                    % (counts["released"], counts["skipped"])),
                "is_warning": True,
            }
        return ok(payload)

    @http.route("/api/v1/assessments/<int:assessment_id>/kill_scoring",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def assessment_kill_scoring(self, assessment_id, **kw):
        """Stop this assessment's subjective grading. Spends nothing more.

        The scoring twin of the generator's `cancel_generation` route, and a
        route of its own for the same reason: `scoring_cancel_requested` is not
        in the assessment update allow-list, because a client that could write
        it as part of a general save could freeze grading as a side effect of
        renaming the assessment. The model's `action_kill_scoring` raises the
        flag, commits it so the grading-lane checkpoint reads it back, parks the
        candidates still queued, and keeps every score already stored -
        idempotent, so a kill on a run that has already stopped still succeeds.
        """
        assessment = request.env["assessments.be"].browse(
            assessment_id).exists()
        if not assessment:
            return fail("not_found", "Assessment not found", status=404)
        # WHAT THIS CLICK STOPPED, from the settle itself - not the paper's
        # `cancelled` evaluators, a lifetime tally that includes earlier kills.
        # Every key is always present, so 0/0 really is "Nothing to stop".
        action = assessment.action_kill_scoring()
        counts = action.get("kill") or {}
        return ok({
            "assessment_id": assessment.id,
            "settled_count": counts.get("settled", 0),
            "cleared_count": counts.get("cleared", 0),
            # Being graded now; each stops at its next call (R1-05).
            "held_count": counts.get("held", 0),
        })

    def _attempt_filters(self, with_state=True, with_result=True):
        """The state/result/flag filters both attempt listings share.

        Written once because two listings answering the same filter names
        differently is the kind of divergence nobody notices until a count on
        one screen contradicts a count on another - which is also why `search`
        is appended here rather than on either route: both `/api/v1/attempts`
        and `/api/v1/assessments/<id>/candidates` gain it in one edit.

        `with_state=False` leaves the state term out: the roster's chip counts
        are every OTHER filter, split by state. `with_result=False` leaves the
        result term out, for the Passed / Failed counts.
        """
        domain = _state_domain(str_arg("state")) if with_state else []
        result = str_arg("result")
        # An unknown value is ignored, not turned into a filter nobody matches.
        if with_result and result in ("pass", "fail", "pending"):
            domain.append(("result", "=", result))
        if bool_arg("released_only"):
            domain.append(("results_released", "=", True))
        if bool_arg("flagged_only"):
            # Advisory review queue: either integrity signal, an outlier or a
            # terminal scoring error worth a human's eyes.
            domain += ["|", "|",
                       ("integrity_alert", "=", True),
                       ("score_outlier", "=", True),
                       ("scoring_error_flag", "!=", False)]
        # THE SEARCH PREDICATE GOES LAST, AND AS ITS OWN CLAUSE.
        #
        # A domain is an implicit AND of its terms, so appending the OR-pair
        # after the block above ANDs it with everything already there. Appending
        # it INTO that "|" chain would have widened the review queue to every
        # searched candidate instead of narrowing it - the operators are prefix,
        # so position is the whole meaning.
        #
        # Owned by the model (`assessments.be.evaluator._be_search_domain`) so
        # this route and Odoo's own search view cannot drift apart again; the
        # 128-character bound is the same one every other search argument on
        # this controller uses.
        # D1 - A SEPARATE PARAMETER, NEVER PART OF `flagged_only`.
        #
        # `flagged_only` above means exactly the three AUTOMATIC advisory
        # flags, and requirement 3.6 requires them to keep working
        # independently of anything an operator applies by hand. Appending the
        # manual flag into that "|" chain would have widened the review queue
        # to every flagged candidate and silently changed what every existing
        # caller of `flagged_only` gets back - the same prefix-operator trap as
        # the search predicate below, one line further up.
        #
        # As its own AND-ed term it composes instead: `flagged_only=1` is the
        # queue it has always been, `manual_flagged_only=1` is the operator's
        # own list, and both together is the intersection, which is a question
        # somebody reviewing an appeal will actually ask.
        if bool_arg("manual_flagged_only"):
            domain.append(("manual_flagged", "=", True))
        domain += request.env["assessments.be.evaluator"]._be_search_domain(
            str_arg("search", max_len=128))
        return domain

    def _attempt_page(self, domain, order=None):
        """One page of attempts under the caller's own record rules.

        THE C1 ORIGIN. This one helper serves both `/api/v1/attempts` and
        `/api/v1/assessments/<id>/candidates`, so the missing tiebreaker here
        was the whole of D2/D7 - see `_NEWEST_FIRST` at the top of this file for
        the measurement.

        `sort` / `sort_desc` are read through `_attempt_order()` for the same
        reason: one helper, one allow-list, one forced `id` tiebreaker, and both
        routes gain the sort in one edit rather than diverging.
        """
        Evaluator = request.env["assessments.be.evaluator"]
        limit, offset = paging()
        total = Evaluator.search_count(domain)
        records = Evaluator.search(
            domain, limit=limit, offset=offset,
            order=order or _attempt_order())
        return paged([S.evaluator_admin_row(e) for e in records],
                     total, limit, offset)

    @http.route("/api/v1/attempts", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_operator
    def attempt_list(self, **kw):
        """Every attempt the caller may see, across all assessments.

        WHY THIS EXISTS. Attempts were only reachable per assessment, so a
        console that needs them all - the roster, the release counts, every
        admin KPI - issued ONE REQUEST PER ASSESSMENT on every refresh. That is
        fine at five assessments and quietly becomes a hundred round trips at a
        hundred, on a poll that runs every couple of seconds during generation.

        Record rules still apply: this is an ordinary search as the calling
        user, so an Evaluator sees exactly the attempts their rule allows -
        the same set the per-assessment route would have returned, just
        gathered in one query instead of N.

        `changed_since` (ISO-8601 UTC) returns only the attempts whose row
        changed after it, most recent first, still paged. `meta.server_time`
        is always sent: the client's next `changed_since` is it minus a few
        seconds.
        """
        # THE TRANSACTION'S START (`cr.now()`), not the wall clock: never later
        # than this read's snapshot, so nothing committed after the snapshot
        # can carry an older stamp than the one handed back. Truncated to the
        # second by `S.iso`, which only moves it earlier.
        server_time = S.iso(request.env.cr.now())
        domain = self._attempt_filters()
        assessment_id = int_arg("assessment_id")
        if assessment_id:
            domain.append(("assessment_id", "=", assessment_id))
        order = None
        try:
            since = _utc_arg("changed_since")
        except ValueError:
            return fail("invalid", "changed_since must be an ISO-8601 UTC "
                        "time, e.g. 2026-09-29T09:59:55Z", status=422)
        if since:
            # Every value a row shows is a stored field on the attempt (the
            # grading, invite, release and flag writes, and the answer-driven
            # computes, all move its `write_date`) EXCEPT the paper's name and
            # `violation_limit_breached`, which read the assessment's own
            # settings - hence the second branch. One SQL statement.
            #
            # `>=`, NOT `>`: Odoo 19 compares datetimes by whole second and
            # rewrites `> 09:59:55` as `>= 09:59:56`, which would drop a row
            # stamped 09:59:55.4. A repeat is harmless; a skip is not.
            domain += ["|", ("write_date", ">=", since),
                       ("assessment_id.write_date", ">=", since)]
            order = _CHANGED_FIRST
        page = self._attempt_page(domain, order=order)
        page["meta"]["server_time"] = server_time
        return page

    @http.route("/api/v1/assessments/<int:assessment_id>/candidates",
                type=API_TYPE, auth="user", methods=API_METHODS, csrf=False,
                cors="*")
    @api_endpoint
    @require_operator
    def assessment_candidates(self, assessment_id, **kw):
        """The cohort with its results, filterable by state/result/flag.

        The page ANDs every filter sent (`state`, `result`, the flags and the
        search), so an older link carrying both `state` and `result` still
        lists their intersection.

        `meta.counts` carries every tile's number: one per value `state`
        accepts (`all`, each attempt state, `scored`, `score_pending`), plus
        `pass` / `fail` for `result`. EVERY TILE IS COUNTED OVER THE SAME
        COHORT - this paper, the search and the flags - and never under the
        tile being pressed. The tiles are one choice (R1, 14 Oct): pressing
        Failed leaves All and Passed as they were, and each number is what
        pressing that tile alone lists.
        """
        assessment = request.env["assessments.be"].browse(
            assessment_id).exists()
        if not assessment:
            return fail("not_found", "Assessment not found", status=404)
        scope = [("assessment_id", "=", assessment_id)]
        page = self._attempt_page(scope + self._attempt_filters())
        page["meta"]["counts"] = self._roster_counts(
            scope + self._attempt_filters(with_state=False, with_result=False))
        return page

    def _roster_counts(self, cohort):
        """Every tile's count in three queries, whatever the cohort's size:
        attempts by state, then the submitted ones still holding an unscored
        answer, then by result. Scored is the difference, so
        Scored + Score Pending = Submitted by construction."""
        Evaluator = request.env["assessments.be.evaluator"]
        counts = dict.fromkeys(
            (key for key, _label in Evaluator._fields["state"].selection), 0)
        for state, count in Evaluator._read_group(
                cohort, ["state"], ["__count"]):
            counts[state] = count
        counts["all"] = sum(counts.values())
        pending = Evaluator.search_count(
            cohort + _scoring_chip("score_pending"))
        counts["scored"] = counts["submitted"] - pending
        counts["score_pending"] = pending
        counts.update({"pass": 0, "fail": 0})
        for result, count in Evaluator._read_group(
                cohort + [("result", "in", ("pass", "fail"))],
                ["result"], ["__count"]):
            counts[result] = count
        return counts

    @http.route("/api/v1/assessments/<int:assessment_id>/assign",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def assessment_assign(self, assessment_id, **kw):
        """Assign candidates by applicant id and/or by name+email.

        A DRAFT assessment only gets its roster extended - the shared question
        draw happens at launch. An already-launched assessment gets
        the full treatment: portal user provisioning, a copy of the cohort's
        shared question set, and a queued invitation. Skipping that second
        path would create a roster entry that can never sit the exam; a
        candidate who cannot be given the cohort's full paper is listed in
        ``not_provisioned`` instead.

        ``remove`` takes the named applicants OFF the roster instead. The
        client has always sent this flag and this route never read it, so the
        Assign tab's Remove button re-ran an assignment: the only way off a
        roster was the Odoo back office, and a candidate added by a typo
        stayed on the assessment. An attempt that has been STARTED is never
        deleted - that is a record of somebody's exam, so it is reported back
        as blocked rather than silently discarded.

        Somebody who could never sit (a portal account, an address no login
        can be made from) is left off and listed in ``skipped`` with the
        reason, and named in the assessment's History; everybody else is
        assigned. When that leaves nobody assigned, the answer is 422
        ``nothing_assigned`` carrying ``skipped``. ``dry_run`` answers the
        same counts and ``skipped`` without writing anything.
        """
        assessment = request.env["assessments.be"].browse(
            assessment_id).exists()
        if not assessment:
            return fail("not_found", "Assessment not found", status=404)
        if assessment.state in ("done", "cancelled"):
            return fail("assessment_closed",
                        "Cannot assign candidates to a %s assessment"
                        % assessment.state, status=409)

        Applicant = request.env["hr.applicant"].sudo()
        applicants = Applicant.browse(id_list_arg("applicant_ids")).exists()
        dry_run = bool_arg("dry_run")
        if bool_arg("remove"):
            # There is no preview of a removal; read on, the flag would be
            # ignored and the people really taken off.
            if dry_run:
                return fail("invalid", "dry_run cannot be combined with remove.",
                            status=400)
            return self._assessment_unassign(assessment, applicants)
        # A TYPED-IN ROW BECOMES A PORTAL LOGIN at launch, so its address has
        # to be a real one (`candidate_row_error`, shared with the CSV import).
        # Checked for every row BEFORE anything is written, so a bad row
        # refuses the request instead of landing half of it. A row missing its
        # name or email is still skipped below, as before.
        bad = []
        for number, row in enumerate(arg("candidates") or [], start=1):
            if not isinstance(row, dict):
                continue
            name = str(row.get("name") or "").strip()
            email = str(row.get("email") or "").strip()
            problem = name and email and candidate_row_error(name, email)
            if problem:
                bad.append("row %d: %s" % (number, problem))
        if bad:
            return fail("invalid",
                        "Nothing was assigned. Fix these candidates: %s."
                        % "; ".join(bad), status=422)
        skipped, seen = [], set()

        def skip(name, address, reason):
            # One line per person, however often the request names them.
            key = _norm_email(address) or address
            if key not in seen:
                seen.add(key)
                skipped.append(
                    {"name": name, "email": address, "reason": reason})

        typed = []
        for row in (arg("candidates") or []):
            if not isinstance(row, dict):
                continue
            name = str(row.get("name") or "").strip()
            email = str(row.get("email") or "").strip()
            if not name or not email:
                skipped.append({"name": name, "email": email,
                                "reason": "name and email are required"})
                continue
            typed.append((name, email))

        # WHO COULD NEVER SIT IS SKIPPED, BEFORE ANYTHING IS WRITTEN. One bulk
        # check (`_be_sit_blockers`) instead of finding portal accounts at the
        # end of provisioning: 8 of them in an 874-row CSV refused all 874
        # after 499 s on stage (19 Oct 2026), and the browser had long given
        # up. People already on the roster are left alone.
        users = request.env["res.users"].sudo().browse(
            id_list_arg("user_ids")).exists()
        entries = (
            [_Entry("id", a.partner_name or "", a.email_from or "", a,
                    a.be_candidate_user_id) for a in applicants]
            # PICKED FROM THE DIRECTORY. The roster is keyed on hr.applicant,
            # so a picked res.users is mapped to its applicant - and given one
            # below when it has none. The mapping lives on the model beside
            # the identity walk it mirrors, so the picker and the exam gate
            # cannot drift apart on who somebody is.
            + [_Entry("user", u.name or "", u.login or "",
                      Applicant._be_find_applicant_for_user(u), u)
               for u in users]
            + [_Entry("row", name, email, found, found.be_candidate_user_id)
               for name, email in typed
               for found in [self._applicant_by_address(Applicant, email)]])
        if not entries and not skipped:
            return fail("no_candidates",
                        "Provide user_ids, applicant_ids and/or candidates",
                        status=400)
        before = set(assessment.evaluator_ids.ids)
        fresh = [i for i, e in enumerate(entries) if e.found.id not in before]
        reasons = request.env["assessments.be"]._be_sit_blockers(
            [(entries[i].address, entries[i].user) for i in fresh])
        blocked = {i for i, reason in zip(fresh, reasons) if reason}
        for i, reason in zip(fresh, reasons):
            if reason:
                skip(entries[i].name, entries[i].address, reason)
        kept = [e for i, e in enumerate(entries) if i not in blocked]

        if dry_run:
            # Nothing written: the import sheet shows this before the operator
            # commits to a run that can take minutes.
            return ok({
                "dry_run": True,
                "assigned_count": len({
                    e.found.id or _norm_email(e.address) or e.address
                    for e in kept if e.found.id not in before}),
                "already_assigned": len({
                    e.found.id for e in kept if e.found.id in before}),
                "skipped": skipped,
            })

        applicants, created = Applicant.browse(), []
        for e in kept:
            if e.source == "id":
                applicant, new = e.found, False
            elif e.source == "user":
                applicant, new = Applicant._be_ensure_applicant_for_user(
                    e.user)
            else:
                applicant, new = self._applicant_for_row(
                    Applicant, e.name, e.address)
            applicants |= applicant
            if new:
                created.append(applicant.id)

        new_ids = [a.id for a in applicants if a.id not in before]
        if new_ids:
            assessment.write({"evaluator_ids": [(4, aid) for aid in new_ids]})
        # The m2m is the roster before launch, but the Odoo candidate TABLE
        # reads `assessment_evaluator_ids` - so assigning from the API filled
        # the tag box and left that table empty until launch. Same sync the CSV
        # importer does, so both paths end in one place. A login the check
        # above could not foresee (another addon's rule on the account) is
        # taken back off the roster there and reported here.
        synced = assessment.sudo()._sync_roster_rows()
        late = {row[0].id for row in synced["refused"]}
        for _applicant, name, address, reason in synced["refused"]:
            skip(name, address, reason)
        new_ids = [aid for aid in new_ids if aid not in late]
        created = [aid for aid in created if aid not in late]
        already = len([a for a in applicants
                       if a.id in before and a.id not in late])
        if skipped:
            assessment.sudo()._log_skipped(
                [(s["name"], s["email"], s["reason"]) for s in skipped])
        if skipped and not new_ids and not already:
            # NOBODY ASSIGNED IS NOT A SUCCESS. Invite by Email, the picker
            # and a row's Assign button each send ONE person and toast any
            # 200 as done, so a skipped person has to come back as a refusal
            # that names them and says why.
            return fail("nothing_assigned", "Nobody was assigned. %s" % "; ".join(
                "%s <%s>: %s" % (s["name"], s["email"], s["reason"])
                for s in skipped[:3]) + (
                    "; and %d more" % (len(skipped) - 3)
                    if len(skipped) > 3 else ""),
                status=422, skipped=skipped)

        launched, refused = [], []
        if assessment.state == "in_progress":
            launched, refused = self._provision_late_candidates(
                assessment, request.env["hr.applicant"].sudo().browse(new_ids))
        assessment.invalidate_recordset()
        payload = {
            "assigned_count": len(new_ids),
            "already_assigned": already,
            "created_applicants": created,
            "skipped": skipped,
            "launched_attempts": launched,
            "assessment": S.assessment_detail(assessment),
        }
        # A CANDIDATE WITH NO SITTABLE ATTEMPT IS NOT A SUCCESS.
        #
        # They are on the roster - the m2m and the roster row were written above -
        # but they were given no question draw, so they cannot sit. Saying so in
        # the response is the whole point of collecting the refusals rather than
        # skipping quietly: the operator learns now, while they can restore the
        # missing question, instead of when the candidate reports a blank exam.
        if refused:
            payload["not_provisioned"] = refused
            payload["notice"] = (
                "%d candidate(s) were added to the roster but have no attempt: "
                "%s" % (len(refused),
                        "; ".join("%s - %s" % (r["name"] or r["applicant_id"],
                                               r["reason"])
                                  for r in refused)))
        return ok(payload)

    @staticmethod
    def _applicant_by_address(Applicant, email):
        """The applicant whose address is ``email``, archived ones included.

        MATCH ON THE NORMALISED ADDRESS, NOT AN ILIKE PATTERN. `=ilike`
        compiles to SQL ILIKE with no escaping, and `%` and `_` are both legal
        in an address local-part. An invite for `a_b@corp.com` therefore
        matched a pre-existing `axb@corp.com`, took that record, and never
        created the person who was actually being invited - reported as
        success, with no `skipped` row to say otherwise. `email_normalized` is
        the case-folded identity key mail.thread.blacklist already maintains,
        and it is indexed.

        active_test=False because refusing a candidate ARCHIVES them in
        hr_recruitment. Without it a re-invited candidate is invisible here, so
        a second hr.applicant is created for an address that already has one,
        and the assessment links to the empty duplicate instead of the
        person's real record and history.
        """
        normalized = tools.email_normalize(email)
        return Applicant.with_context(active_test=False).search(
            [("email_normalized", "=", normalized)] if normalized
            else [("email_from", "=", email)], limit=1)

    def _applicant_for_row(self, Applicant, name, email):
        """A typed-in row's applicant, revived or made: ``(applicant, new)``.

        Looked up AGAIN rather than reusing the check's lookup: an earlier
        entry of the same request - the same address typed twice, or picked
        from the directory as well - may have just made this person.
        """
        found = self._applicant_by_address(Applicant, email)
        if found:
            if not found.active:
                found.active = True
            if not found.partner_name:
                found.partner_name = name
            return found, False
        return Applicant.create({
            "partner_name": name,
            # STORE THE NORMALISED ADDRESS, NOT THE OPERATOR'S CASING. A
            # record whose visible address disagreed with the identity key
            # made a later lowercase invite of the same person miss it and
            # create a duplicate. `_norm_email` is the same folding the
            # identity key uses, and it handles the `"Asha Rao"
            # <asha@corp.com>` form email_from allows. Raw when folding yields
            # empty: a blank address is worse than an unfolded one.
            "email_from": _norm_email(email) or email,
        }), True

    def _assessment_unassign(self, assessment, applicants):
        """Take applicants off a roster, refusing to erase a started exam.

        Two records have to come off together, or the roster and the attempt
        table disagree: the m2m entry in ``evaluator_ids`` (which is the whole
        roster before launch) and any per-candidate ``evaluator`` record that
        launch created. A pending attempt is a placeholder and is deleted with
        the roster entry; an in-progress or submitted one is somebody's exam,
        so it is left alone and named in ``blocked`` for the operator to
        decide about. Deleting it would destroy answers, violation history and
        the audit trail with no confirmation and no undo.
        """
        if not applicants:
            return fail("no_candidates",
                        "Provide applicant_ids to remove", status=400)

        # `assessment.env`, not `request.env`: the same environment on every
        # real call, and it lets a unit test run this without an HTTP session.
        Evaluator = assessment.env["assessments.be.evaluator"].sudo()
        attempts = Evaluator.search([
            ("assessment_id", "=", assessment.id),
            ("applicant_id", "in", applicants.ids),
        ])
        # `is_locked` counts as touched even at state `pending`: a locked
        # attempt is one the proctor ended, which is a finding about a person.
        held = attempts.filtered(
            lambda e: e.state != "pending" or e.started_at or e.is_locked)
        blocked_ids = set(held.mapped("applicant_id").ids)
        removable = applicants.filtered(lambda a: a.id not in blocked_ids)
        if not removable:
            return fail(
                "attempt_in_progress",
                "Those candidates have already started or submitted this "
                "assessment, so they cannot be removed from the roster.",
                status=409,
                blocked=[{"id": a.id,
                          "name": a.partner_name or a.email_from or "",
                          "reason": "already started or submitted"}
                         for a in held.mapped("applicant_id")])

        on_roster = [a.id for a in removable
                     if a.id in assessment.evaluator_ids.ids]
        (attempts - held).unlink()
        if on_roster:
            assessment.write(
                {"evaluator_ids": [(3, aid) for aid in on_roster]})
        # `attempts - held` already dropped the roster rows for these people;
        # anything still standing without an m2m entry would be a row the table
        # shows and the tag box does not.
        stale = Evaluator.search([
            ("assessment_id", "=", assessment.id),
            ("applicant_id", "in", on_roster),
            ("state", "=", "pending"),
        ])
        (stale - held).unlink()
        assessment.invalidate_recordset()
        return ok({
            "removed_count": len(on_roster),
            "not_on_roster": len(removable) - len(on_roster),
            "blocked": [{"id": a.id,
                         "name": a.partner_name or a.email_from or "",
                         "reason": "already started or submitted"}
                        for a in held.mapped("applicant_id")],
            "assessment": S.assessment_detail(assessment),
        })

    def _provision_late_candidates(self, assessment, applicants):
        """Give a late-added candidate a real, sittable attempt.

        Mirrors the per-candidate half of action_start: provision the portal
        user, copy the cohort's shared question set (from the oldest attempt
        that holds a paper), shuffle it unless the author's order is kept, and
        queue the invite. A fresh random set would break the equal-instrument
        guarantee. A candidate whose paper would be shorter than the cohort's
        is refused rather than provisioned. Returns ``(ids, refusals)``.
        """
        if not applicants:
            return [], []
        # DRAW FROM THE ASSESSMENT'S OWN SNAPSHOT, NOT A FRESH POOL.
        #
        # action_start writes `question_ids` at launch - the set of questions
        # this assessment was launched against - and every report, export and
        # per-question statistic reads that field. Re-querying the live bank
        # here handed a late candidate questions approved AFTER the launch:
        # questions absent from `question_ids`, so the cohort sat one
        # instrument and this person sat another, and the extra questions
        # appeared in nobody's per-question breakdown. The snapshot is the
        # instrument; a late arrival joins it rather than redefining it.
        available = assessment.question_ids.filtered(
            lambda q: q.active
            and q._has_required_images() and q._has_required_videos()).ids
        if not available:
            # A launched assessment with an empty snapshot should not exist,
            # but falling back to the live pool is better than silently
            # creating an attempt with no questions in it. The fallback writes
            # what it finds back into question_ids, so a retired question drawn
            # here would not just reach one late candidate - it would become
            # the assessment's instrument for every report that reads the
            # snapshot. Retired means "no new assessment draws this", and this
            # rebuild is a new draw.
            available = assessment.env[
                "assessments.be.question"].sudo().search([
                    ("generator_id", "=", assessment.generator_id.id),
                    ("active", "=", True),
                    ("retired", "=", False),
                ]).filtered(
                    lambda q: q._has_required_images()
                    and q._has_required_videos()).ids
            if available:
                assessment.write({"question_ids": [(6, 0, available)]})
        if not available:
            return [], []
        # A SHORT POOL IS A REFUSAL, NOT A SHORTER PAPER. `action_start`
        # raises when the pool cannot fill `question_limit`; a late candidate
        # handed fewer questions would be ranked against a cohort that sat
        # more. The pool shrinks under a running paper whenever a question is
        # archived or loses its media (`available` filters on both).
        #
        # REPORTED, NOT RAISED, unlike launch: this runs after
        # `_assessment_assign` has written the roster for a whole batch, and
        # raising would lose that work for everyone because one paper could
        # not be filled. The refused candidate gets no attempt and the
        # operator is told.
        wanted = assessment.question_limit or len(available)
        limit = min(wanted, len(available))
        short_by = wanted - len(available)
        # ALWAYS THE SHARED SET (`same_questions_for_all` is retired and no
        # longer read), so an old per-person cohort also gets a copy here.
        # Read from the OLDEST attempt that holds a paper: the launch cohort's
        # set is authoritative, and the model's `_order` puts the newest -
        # possibly itself a late one - first. A bare roster row (no draw yet)
        # or a broken "[]" paper is not a paper and is skipped.
        peer = assessment.assessment_evaluator_ids.filtered(
            lambda e: (e.question_order or "").strip() not in ("", "[]")
        ).sorted("id")[:1]
        peer_paper = json.loads(peer.question_order or "[]")
        shared = [q for q in peer_paper if q in available]
        # The cohort's set lost questions after launch (archived, media gone):
        # the peers sat them, so a copy of what is left is a shorter paper.
        changed = [q for q in peer_paper if q not in available]
        # `assessment.env`, not `request.env`: the same environment on every
        # real call, and it lets a unit test run the draw without an HTTP
        # session.
        Evaluator = assessment.env["assessments.be.evaluator"].sudo()
        out = []
        # Candidates NOT provisioned, and why. Collected rather than raised, and
        # returned to the caller so the refusal reaches the operator instead of
        # being a silent skip - see the shortfall note above.
        refused = []
        for applicant in applicants:
            # `_sync_roster_rows` creates a BARE row at assign time, so "a row
            # exists" no longer means "already provisioned". Only a row that
            # holds a question draw is provisioned; a bare one gets filled in,
            # exactly as `action_start` fills pre-created rows at launch.
            existing = Evaluator.search([
                ("assessment_id", "=", assessment.id),
                ("applicant_id", "=", applicant.id),
            ], limit=1)
            if existing and existing.question_order:
                continue
            assessment._ensure_candidate_user(applicant)
            # THE SHORTFALL CHECKS GO HERE, after the shared set is resolved. A
            # set that lost questions since the cohort sat it is refused. An
            # intact shared set proceeds even when the pool is short: the peers
            # sat exactly that, so a copy matches them.
            if changed:
                refused.append({
                    "applicant_id": applicant.id,
                    "name": applicant.partner_name or "",
                    "reason": (
                        "The cohort sat %d question(s), but %d of them are no "
                        "longer available (archived or missing media; ids %s), "
                        "so this candidate would sit a shorter paper. Restore "
                        "them, then assign again."
                        % (len(peer_paper), len(changed),
                           ", ".join(map(str, changed)))),
                })
                continue
            if short_by > 0 and not shared:
                refused.append({
                    "applicant_id": applicant.id,
                    "name": applicant.partner_name or "",
                    "reason": (
                        "This assessment gives each candidate %d question(s) "
                        "but only %d are available in its launched set, so a "
                        "paper for this candidate would be shorter than the "
                        "one the cohort sat. Restore or replace the missing "
                        "question(s), then assign again."
                        % (wanted, len(available))),
                })
                continue
            # THE AUTHOR'S ORDER IS THE INSTRUMENT WHEN THEY SAID SO, as in
            # `action_start`: with `preserve_question_order` (a Form Studio
            # publish sets it, its sections arranged on purpose) the draw takes
            # the head of `available` - `search`-ordered by `sequence, id`, the
            # order `question_ids` holds - and nothing is shuffled.
            if not shared:
                # Nobody holds a paper yet: draw once, and the rest of this
                # batch copies that draw, so they share one set too.
                shared = (list(available)[:limit]
                          if assessment.preserve_question_order
                          else random.sample(available, limit))
            questions = list(shared)
            given = len(questions)
            if not assessment.preserve_question_order:
                random.shuffle(questions)
            vals = {
                "question_order": json.dumps(questions),
                "invite_state": "queued",
            }
            if existing:
                existing.write(vals)
                out.append(existing.id)
            else:
                evaluator = Evaluator.create(dict(
                    vals,
                    assessment_id=assessment.id,
                    applicant_id=applicant.id,
                ))
                out.append(evaluator.id)
        if out:
            # Launch logs to the chatter, and so does a late addition, or the
            # cohort grows with no record of when or by whom.
            assessment._log_activity(Markup(
                "<b>Candidates added after launch</b> - %d attempt(s) "
                "provisioned with %d question(s) each%s.")
                % (len(out), given,
                   Markup(" from the shared question set")
                   if shared else Markup("")))
        if refused:
            # THE REFUSAL IS LOGGED TOO, and it is the more important of the two:
            # a candidate who was assigned but has no sittable attempt is
            # invisible otherwise. The chatter is the durable record; the caller
            # returns the refusals as `not_provisioned` to tell the operator
            # now.
            assessment._log_activity(Markup(
                "<b>Candidate(s) not provisioned</b> - %d candidate(s) were "
                "added to the roster but given no attempt. %s Affected: %s.")
                % (len(refused),
                   " ".join(dict.fromkeys(r["reason"] for r in refused)),
                   ", ".join(r["name"] or str(r["applicant_id"])
                             for r in refused)))
        # RETURNS A PAIR (ids, refusals): a recordset refuses an arbitrary
        # attribute, and a return value keeps the refusals impossible for the
        # one caller (`_assessment_assign`) to ignore.
        return out, refused

    @http.route("/api/v1/assessments/<int:assessment_id>/close",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def assessment_close(self, assessment_id, **kw):
        """Mark an in-progress assessment done (delegates to action_done)."""
        assessment = request.env["assessments.be"].browse(
            assessment_id).exists()
        if not assessment:
            return fail("not_found", "Assessment not found", status=404)
        assessment.action_done()
        return ok(S.assessment_detail(assessment))

    # Generators and the draft review queue

    @http.route("/api/v1/generators", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_staff
    def generator_list(self, **kw):
        Prompt = request.env["assessments.be.prompt"]
        domain = []
        search = str_arg("search", max_len=128)
        if search:
            domain.append(("name", "ilike", search))
        state = str_arg("state")
        if state:
            domain.append(("state", "=", state))
        tag_ids = id_list_arg("tag_ids")
        if tag_ids:
            domain.append(("tag_ids", "in", tag_ids))
        if bool_arg("include_archived"):
            Prompt = Prompt.with_context(active_test=False)
        limit, offset = paging()
        total = Prompt.search_count(domain)
        records = Prompt.search(
            domain, limit=limit, offset=offset, order=_NEWEST_FIRST)
        return paged([S.generator_row(g) for g in records],
                     total, limit, offset)

    @http.route("/api/v1/generators/<int:generator_id>", type=API_TYPE,
                auth="user", methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_staff
    def generator_detail(self, generator_id, **kw):
        """Full generator with its analysis tabs and draft counters."""
        generator = request.env["assessments.be.prompt"].browse(
            generator_id).exists()
        if not generator:
            return fail("not_found", "Generator not found", status=404)
        data = S.generator_detail(generator)
        drafts = generator.question_ids
        data["draft_counts"] = {
            "pending": len(drafts.filtered(lambda d: d.state == "draft")),
            "approved": len(drafts.filtered(lambda d: d.state == "approved")),
            "denied": len(drafts.filtered(lambda d: d.state == "denied")),
            "total": len(drafts),
        }
        return ok(data)

    @http.route("/api/v1/generators/<int:generator_id>/progress",
                type=API_TYPE, auth="user", methods=API_METHODS, csrf=False,
                cors="*")
    @api_endpoint
    @require_staff
    def generator_progress(self, generator_id, **kw):
        """Live view of one generator's latest run: the `/scoring` twin.

        Polled by the generator screen, so it reads and never writes. Run cost
        is shown to the callers `/ledger` shows it to (`is_operator`).
        """
        generator = request.env["assessments.be.prompt"].browse(
            generator_id).exists()
        if not generator:
            return fail("not_found", "Generator not found", status=404)
        user = request.env.user
        return ok(_generation_progress(
            generator, show_cost=is_operator(user),
            can_retry=user.has_group(GROUP_MANAGER)))

    @http.route("/api/v1/generators/<int:generator_id>/tabs/<string:tab>",
                type=API_TYPE, auth="user", methods=API_METHODS, csrf=False,
                cors="*")
    @api_endpoint
    @require_staff
    def generator_tab(self, generator_id, tab, **kw):
        """One analysis tab on its own, so the app can lazy-load a big one."""
        generator = request.env["assessments.be.prompt"].browse(
            generator_id).exists()
        if not generator:
            return fail("not_found", "Generator not found", status=404)
        tabs = S.generator_detail(generator)["tabs"]
        if tab not in tabs:
            return fail("unknown_tab",
                        "Unknown tab '%s'; expected one of: %s"
                        % (tab, ", ".join(sorted(tabs))), status=404)
        return ok({"tab": tab, "content": tabs[tab]})

    @http.route("/api/v1/drafts", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_staff
    def draft_list(self, **kw):
        """The review queue.

        Defaults to state='draft' (pending review) because that IS the queue:
        INVARIANT 1 means nothing here has reached a candidate, and clearing
        this list is the human review step that lets a question do so.
        """
        Draft = request.env["assessments.be.prompt.question"]
        # A deleted generator's leftover drafts can never be approved.
        domain = [("prompt_id.deleted", "=", False)]
        state = str_arg("state", "draft")
        if state and state != "all":
            domain.append(("state", "=", state))
        generator_id = int_arg("generator_id")
        if generator_id:
            domain.append(("prompt_id", "=", generator_id))
        question_type = str_arg("question_type")
        if question_type:
            domain.append(("question_type", "=", question_type))
        search = str_arg("search", max_len=128)
        if search:
            domain.append(("name", "ilike", search))
        limit, offset = paging()
        total = Draft.search_count(domain)
        records = Draft.search(domain, limit=limit, offset=offset, order="id")
        return paged([S.draft_row(d) for d in records], total, limit, offset)

    @http.route("/api/v1/drafts/<int:draft_id>", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_staff
    def draft_detail(self, draft_id, **kw):
        draft = request.env["assessments.be.prompt.question"].browse(
            draft_id).exists()
        if not draft:
            return fail("not_found", "Draft not found", status=404)
        return ok(S.draft_detail(draft))

    @http.route("/api/v1/drafts/<int:draft_id>/approve", type=API_TYPE,
                auth="user", methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def draft_approve(self, draft_id, **kw):
        """Approve a draft into the bank.

        This is the human review INVARIANT 1 turns on. Delegates to
        action_approve, which materialises images, copies the answer key and
        runs the key-drift guard - none of which can be safely re-done here.

        `acknowledge_warnings` is REQUIRED when the draft carries an authoring
        smell. The client already shows a blocking acknowledgement gate and
        sends the flag; the server used to ignore it and approve regardless,
        which made that gate pure theatre - anything calling the route directly
        skipped the review the flag exists to record. Both warnings mean the
        item leaks: a revealing option puts the rationale in a name the
        candidate reads, and a source reference cites material they never see.
        """
        draft = request.env["assessments.be.prompt.question"].browse(
            draft_id).exists()
        if not draft:
            return fail("not_found", "Draft not found", status=404)
        if draft.state != "draft":
            return fail("already_reviewed",
                        "This draft is already %s" % draft.state, status=409)
        warnings = [name for name, raised in (
            ("revealing_option", draft.has_revealing_option),
            ("source_reference", draft.has_source_reference),
        ) if raised]
        if warnings and not bool_arg("acknowledge_warnings"):
            return fail(
                "warnings_unacknowledged",
                "This draft has unresolved authoring warnings. Re-send with "
                "acknowledge_warnings to approve it anyway.",
                status=422, warnings=warnings)
        draft.action_approve()
        draft.invalidate_recordset()
        approved = draft.approved_question_id
        return ok({
            "draft": S.draft_row(draft),
            "question": S.bank_question_detail(approved.sudo())
            if approved else None,
        })

    @http.route("/api/v1/drafts/<int:draft_id>/deny", type=API_TYPE,
                auth="user", methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def draft_deny(self, draft_id, **kw):
        """Deny a draft, recording WHY.

        The client has always collected a rejection reason and sent it; the
        route used to drop it on the floor. Upstream's `action_deny` takes no
        reason and the model has no field for one, so rather than add a column
        to a shared model the reason goes where the denial is already logged -
        the generator's chatter, next to `_log_drafts_to_generators`'s own
        line. That is the record an author reads when asking why an item never
        reached the bank.
        """
        draft = request.env["assessments.be.prompt.question"].browse(
            draft_id).exists()
        if not draft:
            return fail("not_found", "Draft not found", status=404)
        if draft.prompt_id.deleted:
            return fail("deleted", "This draft belongs to a deleted generator "
                        "and cannot be changed.", status=409)
        if draft.state != "draft":
            return fail("already_reviewed",
                        "This draft is already %s" % draft.state, status=409)
        reason = str_arg("reason", max_len=500)
        draft.action_deny()
        if reason and draft.prompt_id:
            # Escaped for the same reason chatter_post escapes: an operator's
            # free text rendered raw is stored XSS on every surface that shows
            # the chatter, Odoo's own included.
            draft.prompt_id.message_post(body=html_escape(
                "Denied %s: %s" % (draft.name or "draft %s" % draft.id,
                                   reason)))
        draft.invalidate_recordset()
        return ok({"draft": S.draft_row(draft), "reason": reason})

    # Question bank and tags

    @http.route("/api/v1/bank", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_operator
    def bank_list(self, **kw):
        """Approved bank questions.

        ``servable_only`` applies INVARIANT 1's filter as a query: active, a
        valid answer key, and the media its type needs. That is the set a
        launch would actually draw from.
        """
        Question = request.env["assessments.be.question"]
        domain = []
        generator_id = int_arg("generator_id")
        if generator_id:
            domain.append(("generator_id", "=", generator_id))
        question_type = str_arg("question_type")
        if question_type:
            domain.append(("question_type", "=", question_type))
        difficulty = str_arg("difficulty")
        if difficulty:
            domain.append(("difficulty", "=", difficulty))
        search = str_arg("search", max_len=128)
        if search:
            domain.append(("name", "ilike", search))
        if bool_arg("needs_rubric_review"):
            domain += [("has_subjective", "=", True),
                       ("rubric_reviewed", "=", False)]
        if bool_arg("include_archived"):
            Question = Question.with_context(active_test=False)
        # RETIRED QUESTIONS ARE NOT IN THE BANK. They are still active records -
        # the assessments using them must keep listing them, which archiving
        # would break - so nothing else filters them and this has to. Without
        # it a deleted question stays pickable for the next assessment, which
        # is the one thing "delete" has to stop.
        if not bool_arg("include_retired"):
            domain.append(("retired", "=", False))
        limit, offset = paging()
        if bool_arg("servable_only"):
            # _has_required_images/_has_required_videos are Python guards, not
            # stored columns, so the media half of the filter cannot be pushed
            # into SQL. Narrow in SQL first, then filter, then page.
            #
            # THE EXPLICIT `order=` HERE IS LOAD-BEARING, and it is easy to read
            # as redundant because the page is sliced in Python rather than by
            # SQL. It is the opposite: the slice below inherits whatever order
            # this search returns, so dropping it would page a Python slice out
            # of an unordered result and lose rows between pages exactly as a
            # missing SQL tiebreaker does. `sequence, id` ends in the primary
            # key, and `.filtered()` preserves recordset order.
            candidates = Question.search(
                domain + [("active", "=", True), ("has_valid_key", "=", True)],
                order="sequence, id")
            servable = candidates.filtered(
                lambda q: q._has_required_images()
                and q._has_required_videos())
            rows = servable[offset:offset + limit]
            return paged([S.bank_question_row(q) for q in rows],
                         len(servable), limit, offset)
        total = Question.search_count(domain)
        records = Question.search(
            domain, limit=limit, offset=offset, order="sequence, id")
        return paged([S.bank_question_row(q) for q in records],
                     total, limit, offset)

    @http.route("/api/v1/bank/<int:question_id>", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_operator
    def bank_detail(self, question_id, **kw):
        question = request.env["assessments.be.question"].browse(
            question_id).exists()
        if not question:
            return fail("not_found", "Question not found", status=404)
        return ok(S.bank_question_detail(question))

    # The SAVE counterpart is `/studio_item/save` in write.py, a separate path
    # rather than POST on this one: the client speaks POST for every call
    # including reads, so a method split here would make "open the editor" and
    # "write the answer key" the same request.
    @http.route("/api/v1/bank/<int:question_id>/studio_item",
                type=API_TYPE, auth="user", methods=API_METHODS, csrf=False,
                cors="*")
    @api_endpoint
    @require_operator
    def bank_studio_item(self, question_id, **kw):
        """This labelling question as a Form Studio item, ready to edit.

        The missing half of the Studio translation. `studio_form._item_spec`
        has always turned a designer item into a question; nothing turned a
        question back, so a GENERATED labelling draft could not be opened in
        the annotation editor that exists to edit exactly that (tracker SNo
        168). The editor is built and works - this route is what lets a
        generated draft reach it with its boxes and labels already in place.

        404 rather than an empty item when the question is not a labelling
        question or has no markers: the client uses the status to decide
        whether to offer the action at all, and an empty item would render an
        editor with nothing to edit.
        """
        question = request.env["assessments.be.question"].browse(
            question_id).exists()
        if not question:
            return fail("not_found", "Question not found", status=404)
        item = question.as_studio_annotation_item()
        if not item:
            return fail(
                "not_annotatable",
                "This question has no image markers to edit. Only a labelling "
                "question with a stimulus can open in the annotation editor.",
                status=404)
        return ok({"question_id": question.id, "item": item})

    @http.route("/api/v1/bank/<int:question_id>/review_rubric",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def bank_review_rubric(self, question_id, **kw):
        """Sign off (or un-sign) an AI-authored rubric.

        The generator writes both the question and its rubric, so an
        unreviewed rubric is a closed AI loop grading humans. This flag is the
        human in that loop, and the launch gate reads it.
        """
        question = request.env["assessments.be.question"].browse(
            question_id).exists()
        if not question:
            return fail("not_found", "Question not found", status=404)
        if question.deleted:
            return fail("deleted", "This question is deleted and cannot be "
                        "changed. Its assessments, answers and scores are "
                        "kept.", status=409)
        question.write({"rubric_reviewed": bool_arg("reviewed", True)})
        return ok(S.bank_question_row(question))

    @http.route("/api/v1/tags", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_operator
    def tag_list(self, **kw):
        Tag = request.env["assessments.be.tag"]
        domain = []
        search = str_arg("search", max_len=128)
        if search:
            domain += ["|", ("name", "ilike", search),
                       ("display", "ilike", search)]
        prefix = str_arg("prefix")
        if prefix:
            domain.append(("prefix", "=", prefix))
        limit, offset = paging()
        total = Tag.search_count(domain)
        # `name, id`, not `name`. A duplicate tag name is refused by
        # `_check_unique_name`, so `name` is a total order in practice - but that
        # is a Python constraint, not a database one, and a raw write or a race
        # between two `_get_or_create` calls can put two rows with one name in
        # the table. `id` costs nothing and removes the question.
        records = Tag.search(domain, limit=limit, offset=offset,
                             order="name, id")
        return paged([S.tag_row(t) for t in records], total, limit, offset)

    @http.route("/api/v1/users", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def user_list(self, **kw):
        """The directory the Assign-candidates picker searches.

        WHY THIS EXISTS. The picker had no options route at all: it filtered a
        list the console had built by de-duplicating the `candidate` object out
        of every attempt in the database. So it could only ever offer somebody
        who had already sat an assessment - assigning a new person meant typing
        their name and address into a separate invite sheet, and a typo there
        silently created a second applicant. Searching res.users instead means
        the picker offers everyone who has an account, which is what an
        operator expects a candidate search to do.

        Manager, not staff: this is a user directory, and an evaluator who may
        read attempts has no business enumerating accounts.

        Archived users are excluded. An account that has been switched off is
        not somebody to hand an exam to, and `_ensure_candidate_user` refuses
        to reactivate one anyway.
        """
        domain = [("active", "=", True)]
        search = str_arg("search", max_len=128)
        if search:
            domain += ["|", "|", ("name", "ilike", search),
                       ("login", "ilike", search), ("email", "ilike", search)]
        limit, offset = paging()
        # sudo for the READ only. res.users carries record rules that hide
        # other companies' users from a plain read; the gate above is what
        # decides who may call this.
        Users = request.env["res.users"].sudo()
        total = Users.search_count(domain)
        # `name, id`. Nothing makes a person's name unique, and a directory
        # holding two people called the same thing is the ordinary case: the
        # Assign picker pages this route, so without the tiebreaker one of the
        # namesakes can be unreachable on every page the operator looks at.
        records = Users.search(domain, limit=limit, offset=offset,
                               order="name, id")
        return paged([S.user_brief(u) for u in records], total, limit, offset)

    # Responses and the scoring pipeline

    @http.route("/api/v1/responses", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_operator
    def response_list(self, **kw):
        Response = request.env["assessments.be.response"]
        domain = []
        assessment_id = int_arg("assessment_id")
        if assessment_id:
            domain.append(("assessment_id", "=", assessment_id))
        evaluator_id = int_arg("evaluator_id")
        if evaluator_id:
            domain.append(("assessment_evaluator_id", "=", evaluator_id))
        question_id = int_arg("question_id")
        if question_id:
            domain.append(("question_id", "=", question_id))
        # `scoring_state` is the client's name for the same field. Accepting
        # both is not indulgence: the client sent `scoring_state`, the route
        # read `llm_state`, and an unread key is silence rather than a 400 - so
        # the filter appeared to work and quietly returned everything. Same
        # class of bug as option_ids/selected_option_ids.
        llm_state = str_arg("llm_state") or str_arg("scoring_state")
        if llm_state:
            domain.append(("llm_state", "=", llm_state))
        # `question_type` is a related, NON-STORED field on the response, so it
        # cannot go in a domain directly - it has to be reached through the
        # question. Filtering here rather than in Dart also means paging counts
        # the filtered set instead of a 200-row page the client then thins.
        question_type = str_arg("question_type")
        if question_type:
            domain.append(("question_id.question_type", "=", question_type))
        if bool_arg("needs_llm"):
            domain.append(("needs_llm", "=", True))
        if bool_arg("flagged_only"):
            domain.append(("integrity_alert", "=", True))
        # D2 - THE ANSWER LISTING GAINS A SEARCH TERM.
        #
        # This route paged correctly and had no predicate at all, so the client
        # had nowhere to send a term and filtered whatever it happened to hold:
        # a walk capped at 2 pages, 400 rows of 31,462 measured on stage. An
        # operator searching for a candidate past row 400 got "no matches" over
        # a table that held them.
        #
        # Owned by the model so this route and Odoo's own response search view
        # cannot drift, exactly as `_be_search_domain` does for the evaluator.
        # Appended LAST and as its own OR-group, so it ANDs with every filter
        # above rather than widening them - the operators are prefix, so
        # position is the whole meaning.
        domain += request.env["assessments.be.response"]._be_search_domain(
            str_arg("search", max_len=128))
        limit, offset = paging()
        total = Response.search_count(domain)
        records = Response.search(
            domain, limit=limit, offset=offset, order=_NEWEST_FIRST)
        return paged([S.response_row(r) for r in records],
                     total, limit, offset)

    @http.route("/api/v1/responses/<int:evaluator_id>/<int:question_id>",
                type=API_TYPE, auth="user", methods=API_METHODS, csrf=False,
                cors="*")
    @api_endpoint
    @require_operator
    def response_audit(self, evaluator_id, question_id, **kw):
        """The full audit payload for one candidate's answer to one question.

        Addressed by (evaluator, question) rather than response id because
        that pair is what an admin has in hand from the results grid, and the
        model enforces it unique.
        """
        response = request.env["assessments.be.response"].search([
            ("assessment_evaluator_id", "=", evaluator_id),
            ("question_id", "=", question_id),
        ], limit=1)
        if not response:
            return fail("not_found",
                        "No response for that candidate and question",
                        status=404)
        data = S.response_audit(response)
        data["question"] = S.bank_question_detail(response.question_id)
        data["candidate"] = S.evaluator_admin_row(
            response.assessment_evaluator_id)
        return ok(data)

    # ------------------------------------------------------------------
    # One attempt
    # ------------------------------------------------------------------
    #
    # The attempt is the unit an admin actually works with: it is what the
    # backend's Candidates tab opens, and it is where re-scoring and erasure
    # live as buttons. The results grid can only address an ANSWER
    # (evaluator + question); without these three an admin could read a single
    # answer but never the sitting that produced it.

    @http.route("/api/v1/attempts/<int:evaluator_id>", type=API_TYPE,
                auth="user", methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_operator
    def attempt_detail(self, evaluator_id, **kw):
        """One candidate's sitting: header, every answer, and its audit."""
        evaluator = request.env["assessments.be.evaluator"].browse(
            evaluator_id).exists()
        if not evaluator:
            return fail("not_found", "No such attempt", status=404)

        # The exam link is a bearer credential, so it rides on the DETAIL
        # response and only for a Manager - the person who resends a lost
        # invitation. Every list route omits it.
        data = S.evaluator_admin_row(
            evaluator,
            with_link=request.env.user.has_group(GROUP_MANAGER))
        # assessment_DETAIL, not assessment_row.
        #
        # The row shape carries counters, not records: no ``questions``. But
        # the screen this feeds marks one row PER QUESTION, joining the answers
        # below onto the assessment's question list - so it embedded an
        # assessment that could not answer the only question it was embedded to
        # answer, and the client had to fetch the record a second time to fill
        # a grid it had already been handed the data for. Every other endpoint
        # that embeds an assessment already sends the detail shape.
        data["assessment"] = S.assessment_detail(evaluator.assessment_id)
        data["answers"] = [
            S.response_audit(r)
            for r in evaluator.response_ids.sorted("id")
        ]
        # Time analysis: the paper's median sitting length, from the server so
        # an attempt opened by direct link is not compared with itself. DETAIL
        # ROUTE ONLY - it is one query over the whole paper, which the list
        # routes must not pay per row. Null when no sitting has a usable span.
        data["test_median_seconds"] = pace.median_seconds(
            evaluator.assessment_id)
        # Eye-movement review flags, every one with its time. Advisory: not
        # violations, and `flagged_only` does not select them.
        data["review_flags"] = [
            {"reason": str(f.get("reason") or ""), "at": f.get("at") or ""}
            for f in (evaluator.review_flags or [])
            if isinstance(f, dict)]
        return ok(data)

    @http.route("/api/v1/attempts/<int:evaluator_id>/evidence", type=API_TYPE,
                auth="user", methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_operator
    def attempt_evidence(self, evaluator_id, **kw):
        """AI proctoring snapshots for one attempt, newest first, each with a
        15-minute presigned GET (`services/evidence.py`)."""
        evaluator = request.env["assessments.be.evaluator"].browse(
            evaluator_id).exists()
        if not evaluator:
            return fail("not_found", "No such attempt", status=404)
        denied = record_read_guard(evaluator)
        if denied:
            return denied
        # No storage target is a normal state (local rig, UAT), not an outage:
        # a 200 that says so, so the panel can be calm and 5xx stays real.
        cli, bucket = s3_service.storage_target(request.env)
        storage = "ok" if cli is not None and bucket else "not_configured"
        try:
            # list_evidence never touches boto without a target.
            return ok(dict(evidence.list_evidence(evaluator), storage=storage))
        except (BotoCoreError, ClientError):
            _logger.warning("Listing evidence for attempt %s failed",
                            evaluator_id, exc_info=True)
            return fail("s3_failed",
                        "Could not list this attempt's evidence in storage.",
                        status=502)

    @http.route("/api/v1/attempts/<int:evaluator_id>/rescore", type=API_TYPE,
                auth="user", methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def attempt_rescore(self, evaluator_id, **kw):
        """Queue this attempt's answers for the grader - never grade here.

        Body: optional ``question_ids``. With them, exactly those answers are
        queued (ids not on this attempt: 422 `not_on_attempt`, nothing
        queued); ABSENT (or null), every answer that needs the grader and has
        no mark yet, which is what older app builds expect. The lane that owns
        the candidate grades them first on its next tick, so no web worker
        waits on a Vertex call and nothing collides with a running lane.

        ABSENT IS NOT THE SAME AS EMPTY. A key that is there but holds `[]`,
        `'abc'` or a list of objects is 422 `invalid`: reading it as "no ids"
        would turn "re-score this one answer" into a paid re-score of every
        unresolved answer.

        Body: optional ``confirm`` (bool). A released attempt's mark is one the
        candidate can already see, so moving it is asked for on purpose, the
        way `/scoring/requeue_errored` asks for `force`: without it, 409
        `released_confirm_required` and nothing is queued.

        Reply: the attempt row plus ``queued``, ``skipped`` (chosen answers
        scored in code) and ``question_ids`` (the queued ones). Refusals queue
        nothing: 409 `spend_limit` (daily or per-candidate cap reached),
        `being_graded` (a lane holds the candidate right now, with or without
        ``question_ids``), `erased`, `archived` and `stopping` (a Kill is
        still stopping the paper); a cancelled paper is 422 `rejected`.
        """
        evaluator = request.env["assessments.be.evaluator"].browse(
            evaluator_id).exists()
        if not evaluator:
            return fail("not_found", "No such attempt", status=404)
        if evaluator.state != "submitted":
            return fail(
                "not_submitted",
                "Only a submitted attempt can be re-scored.",
                status=409)
        try:
            question_ids = id_list_arg_strict("question_ids")
        except ValueError as exc:
            return fail("invalid", str(exc), status=422)
        try:
            action = evaluator.action_rescore_individually(
                question_ids, confirm_released=bool_arg("confirm"))
        except RescoreRefused as exc:
            return fail(exc.code, str(exc),
                        status=422 if exc.code == "not_on_attempt" else 409)
        data = S.evaluator_admin_row(evaluator)
        data.update(action["rescore"])
        return ok(data)

    @http.route("/api/v1/attempts/<int:evaluator_id>/erase", type=API_TYPE,
                auth="user", methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def attempt_erase(self, evaluator_id, **kw):
        """Remove the candidate's personal data, keeping scores and flags.

        Irreversible, and refused when already done so a double click cannot
        report a second erasure that did not happen.
        """
        evaluator = request.env["assessments.be.evaluator"].browse(
            evaluator_id).exists()
        if not evaluator:
            return fail("not_found", "No such attempt", status=404)
        if evaluator.pii_anonymized:
            return fail(
                "already_erased",
                "This candidate's data has already been erased.",
                status=409)

        evaluator.action_erase_candidate_data()
        return ok(S.evaluator_admin_row(evaluator))

    @http.route("/api/v1/scoring", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_staff
    def scoring_pipeline(self, **kw):
        """Live view of the subjective grading pipeline.

        The 'error' lane is called out separately because of INVARIANT 5: a
        terminal error is NEVER retried automatically, so anything sitting
        there stays there until a human runs the requeue action below. Every
        other lane drains on its own.
        """
        Evaluator = request.env["assessments.be.evaluator"]
        domain = [("state", "=", "submitted")]
        assessment_id = int_arg("assessment_id")
        if assessment_id:
            domain.append(("assessment_id", "=", assessment_id))

        # ONLY ATTEMPTS THAT HAVE SUBJECTIVE WORK COUNT AS "IN THE PIPELINE".
        #
        # The evaluator's `llm_state` has no `not_needed` value - the RESPONSE
        # model has one, the evaluator does not - so an entirely objective
        # paper keeps the field's default, `pending`, forever. Counting that
        # naively reported every mcq-only attempt as waiting to be graded, on a
        # system where all of them were correctly finished, and tripped the
        # console's "nothing is queued to grade them" warning permanently.
        # That is the same class of lie as the starvation it was written to
        # catch, just inverted.
        #
        # `needs_llm` is the response-level truth about whether the grader has
        # anything to do, so the pipeline is defined by it.
        graded_lanes = ("pending", "scoring", "partial", "failed")
        subjective = [("response_ids.needs_llm", "=", True)]
        lanes = dict.fromkeys(
            ("pending", "scoring", "scored", "partial", "failed", "error"), 0)
        # ONE GROUPED QUERY for the lanes and one count for the queue, not a
        # count per lane. The waiting lanes need the subjective filter;
        # `scored` and `error` are states the grader itself put there, so they
        # are real regardless.
        for lane, count in Evaluator._read_group(
                domain + ["|", ("llm_state", "in", ("scored", "error")),
                          "&", ("llm_state", "in", graded_lanes)]
                + subjective,
                ["llm_state"], ["__count"]):
            lanes[lane] = count
        Assessment = request.env["assessments.be"]
        # QUEUED IS WHAT A LANE WOULD PICK UP, by the drainer's own predicate.
        # `scoring_requested` alone is never cleared after a good score, so
        # it read "2102 queued" beside "2103 scored" on prod.
        queued = Evaluator.search_count(
            domain + Assessment._scoring_queue_domain())
        # Nothing errored is the usual poll, and then there is nothing to find.
        stuck = Evaluator.browse()
        if lanes["error"]:
            stuck = Evaluator.search(
                domain + [("llm_state", "=", "error")], limit=50,
                order="submitted_at desc")
        icp = request.env["ir.config_parameter"].sudo()

        # QUEUED BUT NOT DRAINING. A growing `queued` looks the same as a busy
        # one: on 2026-09-03 every grading cron sat inactive for six hours with
        # 1,948 answers queued, and nothing said so. `stalled` = work waiting
        # AND a grading cron inactive or overdue, or a lane not moving
        # (`stuck`), decided once on the model
        # (`_scoring_drainer_health`) so this payload, the Odoo header and
        # `scoring_phase` cannot disagree.
        health = Assessment._scoring_drainer_health()
        # Clamped 1-4 by the model, as the lanes themselves read it.
        shards = Assessment._scoring_shard_count()
        stalled = bool(queued and health["blocked"])
        reason = ""
        if stalled and health["inactive"]:
            reason = ("%d of %d grading cron(s) inactive and %d candidate(s) "
                      "queued - nothing will be scored until they are "
                      "re-enabled"
                      % (health["inactive"], health["total"], queued))
        elif stalled and health["stuck"] and not health["overdue"]:
            # Names the lane: shard N is the `SCORING_LANE_BLOCKED shard=N`
            # log line and the cron "Auto-score (shard N)"; shard 0's cron is
            # "Auto-score submitted candidates" (data/cron.xml).
            reason = "; ".join(
                "grading shard %d has stored nothing in 15 minutes with %d "
                "candidate(s) queued on it" % (shard, n)
                for shard, n in sorted(health["stuck"].items()))
        elif stalled:
            reason = ("the grading cron is overdue by more than 15 minutes "
                      "with %d candidate(s) queued" % queued)
        # THE PHASE, when the caller scoped the question to one assessment.
        # Cohort-wide it is meaningless - two papers can be in different
        # phases at once - so it is only answered when there is one paper to
        # answer for. Read from the model rather than re-derived here, so the
        # Odoo header, this payload and the console cannot disagree about
        # whether a run is live.
        # The phase compute asks for the same health verdict; hand it the one
        # already in hand, so the cron check runs once per request.
        scoped = (Assessment.with_context(be_drainer_health=health).browse(
            assessment_id).exists() if assessment_id else None)
        return ok({
            "lanes": lanes,
            "queued": queued,
            "phase": scoped.scoring_phase if scoped else None,
            "summary": scoped.scoring_summary if scoped else "",
            "needs_manual_requeue": lanes["error"],
            "config": {
                "scoring_shards": shards,
                "scoring_tick_limit": int(
                    icp.get_param("assessments_be_v2.scoring_tick_limit", "20")
                    or 20),
            },
            # The dashboard's grader banner shows for `stalled` or a non-zero
            # `needs_manual_requeue`; the counts and `reason` are what it
            # tells the operator.
            "drainer": {
                "stalled": stalled,
                "crons_total": health["total"],
                "crons_inactive": health["inactive"],
                "crons_overdue": health["overdue"],
                "reason": reason,
            },
            "errored": [S.evaluator_admin_row(e) for e in stuck],
        })

    @http.route("/api/v1/scoring/queue", type=API_TYPE, auth="user",
                methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def scoring_queue(self, **kw):
        """Queue submitted candidates for background subjective grading.

        Never scores inline: both paths only set scoring_requested, and the
        cron does the Vertex call. Grading inside a web request would stall a
        worker for the length of an LLM call.

        COUNTS COME FROM THE ACTION, NOT FROM THE ROUTE: ``queued`` is what
        was actually queued, and ``skipped`` counts the candidates left to a
        lane grading them right now (plus, for named ids, erased ones). A
        paper whose Kill is still stopping is 409 `stopping`; a cancelled one
        is 422 `rejected`. Nothing is queued in either case.
        """
        assessment_id = int_arg("assessment_id")
        # Both app builds send `evaluator_ids: []` with `assessment_id`.
        try:
            evaluator_ids = id_list_arg_strict(
                "evaluator_ids", "evaluator ids", empty_ok=True)
        except ValueError as exc:
            return fail("invalid", str(exc), status=422)
        if evaluator_ids:
            evaluators = request.env["assessments.be.evaluator"].browse(
                evaluator_ids).exists()
            if not evaluators:
                return fail("not_found", "No such candidates", status=404)
            action = evaluators.action_queue_llm_score()
            return ok(dict(action["queue"]))
        if not assessment_id:
            return fail("missing_target",
                        "Provide assessment_id or evaluator_ids", status=400)
        assessment = request.env["assessments.be"].browse(
            assessment_id).exists()
        if not assessment:
            return fail("not_found", "Assessment not found", status=404)
        action = assessment.action_llm_score_all()
        return ok(dict(action["queue"]))

    @http.route("/api/v1/scoring/requeue_errored", type=API_TYPE,
                auth="user", methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def scoring_requeue_errored(self, **kw):
        """Reset stuck scoring so the grader may retry it.

        INVARIANT 5: this is the ONLY way a terminal scoring state is ever
        retried. Nothing in the system does it on a timer, because a silent
        auto-retry on an infra fault can mis-fail a candidate.

        Takes `evaluator_ids` or an `assessment_id` (a whole paper's stuck
        candidates), and an optional `states` list that widens the reset from
        the terminal 'error' to the recoverable 'failed'. Without `states` it
        resets 'error' answers only.

        RE-GRADING A PAID ANSWER NEEDS `force`. `states` normally accepts only
        the two recoverable states, because naming 'scored' rewrites answers that
        have already been graded: a second Vertex bill for work already paid for,
        and - the grader runs at temperature 0.2 - a genuinely different mark
        written over one a human may already have released. That is a real
        operation in a real emergency (a rubric signed off wrong, a whole cohort
        graded against it) and it stays available, but it has to be ASKED FOR:
        pass `force: true` alongside the state. The point is that it cannot
        happen as a side effect of a state name in a payload, and that when it
        does happen the assessment's own log says who did it and to how many
        answers - which is what an emergency needs afterwards.

        REPLY: `requeued` counts the candidates targeted (older apps read
        it), `answers_reset` the answers actually reset. `candidates` is empty
        for an `assessment_id` call. A candidate a lane is grading right now,
        or an erased attempt, is left alone (`action_reset_failed_scoring`); a
        paper whose Kill is still stopping is 409 `stopping`, a cancelled one
        422 `rejected`. With `evaluator_ids` those papers' candidates are
        dropped instead, and `skipped` counts them.
        """
        RECOVERABLE = RECOVERABLE_SCORING_STATES
        forced = bool_arg("force")
        raw_states = kw.get("states")
        if raw_states is None:
            # Absent `states`: terminal errors only.
            states = ("error",)
        else:
            if isinstance(raw_states, str):
                raw_states = [s.strip() for s in raw_states.split(",")
                              if s.strip()]
            if not isinstance(raw_states, (list, tuple)) or not raw_states:
                return fail("invalid", "states must be a non-empty list",
                            status=422)
            # `force` widens the set to anything the field can hold, so a
            # deliberate emergency re-grade is possible; a typo is still caught.
            allowed = (
                dict(request.env["assessments.be.response"]
                     ._fields["llm_state"].selection)
                if forced else RECOVERABLE)
            unknown = [s for s in raw_states if s not in allowed]
            if unknown:
                return fail(
                    "invalid",
                    "cannot re-queue scoring state(s): %s. This route retries "
                    "stuck scoring, so it accepts: %s. Re-grading an answer "
                    "that is already scored costs another LLM call and can move "
                    "a mark that has been released - pass force:true to do it "
                    "on purpose."
                    % (", ".join(map(str, unknown)), ", ".join(RECOVERABLE)),
                    status=422)
            states = tuple(raw_states)

        assessment_id = int_arg("assessment_id")
        evaluator_ids = id_list_arg("evaluator_ids")
        if assessment_id:
            assessment = request.env["assessments.be"].browse(
                assessment_id).exists()
            if not assessment:
                return fail("not_found", "Assessment not found", status=404)
            evaluators = assessment.assessment_evaluator_ids
        elif evaluator_ids:
            evaluators = request.env["assessments.be.evaluator"].browse(
                evaluator_ids).exists()
        else:
            return fail("missing_target",
                        "assessment_id or evaluator_ids is required",
                        status=400)
        if not evaluators:
            return fail("not_found", "No such candidates", status=404)
        # AN ORG-WIDE LIST IS NOT REFUSED FOR ONE PAPER IN IT (RV4-01): the
        # candidates of a cancelled paper, or of one whose Kill is still
        # stopping, are dropped and counted in `skipped`. A single paper
        # (`assessment_id`) is still refused below.
        skipped = 0
        if not assessment_id:
            refused = evaluators.browse()
            for paper in evaluators.assessment_id:
                try:
                    paper._check_scoring_not_cancelled()
                    paper._check_scoring_not_stopping()
                except UserError:
                    refused |= evaluators.filtered(
                        lambda e, p=paper: e.assessment_id == p)
            evaluators -= refused
            skipped = len(refused)
        # A FORCED RE-GRADE LEAVES A TRAIL. It spends money on answers that were
        # already paid for and can move a released mark, so the assessment's own
        # log has to say it happened, to whom, and by whose hand - an emergency
        # is exactly the situation somebody reconstructs afterwards.
        if forced:
            for assessment in evaluators.mapped("assessment_id"):
                assessment._log_activity(Markup(
                    "<b>Forced re-grade</b> - an admin re-queued %d "
                    "candidate(s) in state(s) %s with force, which re-grades "
                    "answers that were already scored. This costs an LLM call "
                    "per answer and can change a mark that has been released."
                ) % (len(evaluators.filtered(
                    lambda e: e.assessment_id == assessment)),
                    ", ".join(states)))
        action = evaluators.action_reset_failed_scoring(states=states)
        evaluators.invalidate_recordset()
        return ok({"requeued": len(evaluators),
                   # `requeued` counts candidates, for older apps; the toast
                   # talks about answers.
                   "answers_reset": action["reset"]["answers"],
                   "states": list(states),
                   "forced": forced,
                   # Candidates dropped for a cancelled or stopping paper.
                   "skipped": skipped,
                   # No app reads these, and for a whole paper this was every
                   # attempt serialised on each click.
                   "candidates": [] if assessment_id else [
                       S.evaluator_admin_row(e) for e in evaluators]})

    # Analytics, budget, ledger, settings

    @http.route("/api/v1/analytics", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_operator
    def analytics(self, **kw):
        """Cohort KPIs, optionally scoped to one assessment.

        Percentages are correct HERE: these aggregate across candidates and
        assessments, where "X / N" marks are not comparable. INVARIANT 2 is
        about a candidate's own score on a candidate-facing surface, and this
        is neither.
        """
        Evaluator = request.env["assessments.be.evaluator"]
        domain = []
        assessment_id = int_arg("assessment_id")
        if assessment_id:
            domain.append(("assessment_id", "=", assessment_id))
        else:
            # ARCHIVED ASSESSMENTS ARE EXCLUDED, exactly as every list is.
            #
            # `assessment_id` is a many2one to a model with `active`, so a bare
            # search here crossed INTO archived assessments while
            # `/api/v1/assessments` and this route's own `by_assessment` list
            # both leave them out. Two denominators for one quantity, on one
            # screen: the tile read the server's 198 sittings and the header
            # strip beside it read the client's 194, off by the 4 sittings of
            # one archived assessment ("DEMO Safety Refresher - Results Held").
            # It moved `people` (159 vs 157), `submitted`, `decided` and
            # `passed` too, so the pass rate was computed over a cohort the
            # operator cannot open.
            #
            # Same bug class as SNo 162, one layer down: there the client summed
            # two different populations, here the server and the client disagree
            # on which population it is. Scoped to one assessment the caller
            # named it explicitly, so that branch is left alone - an operator
            # reading an archived assessment's own analytics wants its figures.
            domain.append(("assessment_id.active", "=", True))
        everyone = Evaluator.search(domain)
        submitted = everyone.filtered(lambda e: e.state == "submitted")
        scored = Evaluator.search(domain + Evaluator._answers_scored_domain())
        # RELEASED AND DECIDED, as the console labels these figures ("Cohort
        # Outcome - released and decided"). Counting held results showed 15
        # outcomes where only 9 had been released. A decided-but-held result
        # stays in `awaiting_result` below.
        decided = submitted.filtered(
            lambda e: e.results_released and e.result in ("pass", "fail"))
        passed = decided.filtered(lambda e: e.result == "pass")
        scores = [e.score_percent or 0.0 for e in decided]
        Assessment = request.env["assessments.be"]
        by_assessment = []
        assessments = (Assessment.browse(assessment_id).exists()
                       if assessment_id
                       else Assessment.search([], order="create_date desc",
                                              limit=25))
        for assessment in assessments:
            cohort = assessment.assessment_evaluator_ids.filtered(
                lambda e: e.state == "submitted" and e.results_released
                and e.result in ("pass", "fail"))
            cohort_scores = [e.score_percent or 0.0 for e in cohort]
            by_assessment.append({
                "id": assessment.id,
                "name": assessment.name or "",
                "state": assessment.state,
                "candidates": len(assessment.assessment_evaluator_ids),
                "submitted": assessment.submitted_count or 0,
                "decided": len(cohort),
                "passed": len(cohort.filtered(lambda e: e.result == "pass")),
                "avg_score": round(
                    sum(cohort_scores) / len(cohort_scores), 1)
                if cohort_scores else 0.0,
                "awaiting_scoring": assessment.awaiting_scoring_count or 0,
                "releasable": assessment.releasable_count or 0,
            })
        # TWO FIGURES, BOTH HONEST, EACH LABELLED FOR WHAT IT IS.
        #
        # `everyone` is one row per SITTING, and a person may legitimately sit
        # several papers - so its length is the number of attempts, not the
        # number of people. The dashboard read it as "Candidates" while taking
        # passed/failed/decided from the same recordset, and the client summed
        # each assessment's own `assignedCount` for the tile. Two denominators
        # on one screen is how "Passed 1466" came to exceed "CANDIDATES 1330":
        # a candidate on two papers counts twice in one figure and once in the
        # other.
        #
        # Measured on etp_local: 198 sittings across 159 distinct people, 11
        # people holding more than one, Priya Sharma alone counted 14 times.
        # There are ZERO per-assessment duplicates (the
        # (assessment_id, applicant_id) unique index guarantees that), so the
        # inflation comes entirely from summing ACROSS assessments.
        #
        # Neither number is wrong; conflating them is. `assigned` keeps its
        # meaning (sittings, which is what completion_rate and the score bands
        # divide by) and `people` is the new one the "Candidates" tile wants.
        people = len(set(everyone.mapped("applicant_id").ids))
        return ok({
            "totals": {
                "assigned": len(everyone),
                # DISTINCT HUMANS. The tile that says "Candidates" must divide
                # by this, never by `assigned`.
                "people": people,
                "submitted": len(submitted),
                "decided": len(decided),
                "passed": len(passed),
                "failed": len(decided) - len(passed),
                "awaiting_result": len(submitted) - len(decided),
                "avg_score": round(sum(scores) / len(scores), 1)
                if scores else 0.0,
                "pass_rate": round(len(passed) / len(decided) * 100.0, 1)
                if decided else 0.0,
                "completion_rate": round(
                    len(submitted) / len(everyone) * 100.0, 1)
                if everyone else 0.0,
                # assigned = not_started + in_progress + submitted.
                "in_progress": len(
                    everyone.filtered(lambda e: e.state == "in_progress")),
                "not_started": len(
                    everyone.filtered(lambda e: e.state == "pending")),
            },
            "flags": {
                "integrity_alert": len(
                    everyone.filtered(lambda e: e.integrity_alert)),
                "score_outlier": len(
                    everyone.filtered(lambda e: e.score_outlier)),
                "violated": len(everyone.filtered(lambda e: e.is_violated)),
                "scoring_error": len(
                    everyone.filtered(lambda e: e.scoring_error_flag)),
                # DISTINCT attempts with any of the three review flags, so
                # one attempt flagged twice is one row to review, not two.
                "needs_review": len(everyone.filtered(
                    lambda e: e.integrity_alert or e.score_outlier
                    or e.is_violated)),
            },
            # Pro's score-band histogram, same four buckets. Counts EVERY
            # SCORED submitted attempt, released or not: results_released
            # governs what a candidate sees in their own portal and must not
            # hide a score from the admin. An unscored one is left out, as on
            # the leaderboard: its 0.0 is "not marked yet", and counting it put
            # an ungraded sitting in the 0-49 bar.
            "score_bands": [
                {"label": label, "min": lo, "max": hi,
                 "count": len(scored.filtered(
                     lambda e, lo=lo, hi=hi: lo <= e.score_percent < hi))}
                for lo, hi, label in ((0, 50, "0-49"), (50, 70, "50-69"),
                                      (70, 85, "70-84"), (85, 101, "85-100"))
            ],
            "by_assessment": by_assessment,
            # WHERE THE COHORT IS STRONG AND WEAK, by category.
            #
            # Computed HERE rather than in the client because the client has no
            # per-answer data on this screen: the attempt LIST route carries no
            # answers, and `resp` is only filled by the per-attempt detail call.
            # Building this browser-side would mean one request per sitting.
            "cohort_categories": _cohort_categories(everyone),
        })


    @http.route("/api/v1/leaderboard", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_operator
    def leaderboard(self, **kw):
        """Candidate ranking by average score, across every assessment or one.

        Ported from dashboard._build_leaderboard, which renders the same
        ranking as HTML for the backend view. One gate from that method is
        load-bearing and reproduced exactly:

        * only SUBMITTED attempts count - and only SCORED ones, by the
          evaluator's one definition (`_answers_scored_domain`). An attempt
          whose written answer was never graded holds `score_percent` 0.0,
          which is "not marked yet", not a mark: averaged in, it ranked an
          ungraded sitting #1 at 0.0 on a paper with grading off (attempt
          2638, stage, 2026-10-13). It joins the board once it is scored.

        `results_released` is deliberately NOT a filter on who is ranked or on
        the attempts, average and best. Release governs what a CANDIDATE sees
        in their own portal; the admin sees every score whether released or
        not. Gating the board on it made the leaderboard disagree with the
        score distribution beside it - a candidate counted in the 85-100 bar
        was missing from the ranking - which is how the bug was found in pro.

        The one exception is `passed`, which counts RELEASED passes only, the
        same rule as the analytics pass-rate tile.

        Aggregation stays on the DB (two grouped reads over the group set,
        never a scan over raw evaluator rows), because this ranks the whole
        cohort and the row count is unbounded.
        """
        Evaluator = request.env["assessments.be.evaluator"]
        base = Evaluator._answers_scored_domain()
        # SCOPED HERE OR NOWHERE. The rows below are grouped by applicant, so
        # by the time they reach a client the assessment dimension is gone and
        # no client-side filter can recover it - which is why the dashboard's
        # assessment filter used to narrow every panel except this one.
        assessment_id = int_arg("assessment_id")
        if assessment_id:
            base.append(("assessment_id", "=", assessment_id))
        else:
            # ARCHIVED ASSESSMENTS EXCLUDED, for the reason spelled out in
            # `analytics` above: unscoped, this reached sittings on assessments
            # no list shows, so the board ranked people over a cohort that
            # disagreed with the score distribution printed beside it - the
            # exact class of disagreement that made this route's own release
            # gate a bug. Scoped, the caller named the assessment, so its own
            # figures are what they asked for.
            base.append(("assessment_id.active", "=", True))
        rows = {}
        for applicant, count, avg, best in Evaluator._read_group(
                base, ["applicant_id"],
                ["__count", "score_percent:avg", "score_percent:max"]):
            if applicant:
                rows[applicant.id] = {
                    "rec": applicant, "attempts": count,
                    "avg": avg or 0.0, "best": best or 0.0, "passed": 0,
                }
        # PASSED COUNTS RELEASED PASSES ONLY, the rule the analytics pass-rate
        # tile uses ("released and decided"): a held pass is not an outcome yet,
        # so it must not show here while the tile beside the board leaves it out.
        # The attempts, average and best above stay over every scored attempt.
        for applicant, count in Evaluator._read_group(
                base + [("results_released", "=", True),
                        ("result", "=", "pass")], ["applicant_id"],
                ["__count"]):
            if applicant and applicant.id in rows:
                rows[applicant.id]["passed"] = count

        # MAX_LEADERBOARD, NOT MAX_LIMIT. This is a whole-cohort ranking, not a
        # paged list: every submitted attempt has already been grouped in the
        # database and is already in memory by the time we get here, so the limit
        # governs only how many rows are SERIALIZED. Clamping it at MAX_LIMIT
        # (200) therefore saved no work and silently dropped people - the
        # 588-candidate cohort of 2026-09-03 was ranked 200 deep, omitting 388,
        # with nothing in the payload to say the board was partial. The
        # docstring above says this ranks "the whole cohort", and now it can.
        limit = max(1, min(int_arg("limit", MAX_LEADERBOARD) or MAX_LEADERBOARD,
                           MAX_LEADERBOARD))
        # Same tie-break chain as the backend board: a higher average wins,
        # then more passes, then more attempts - so a candidate who scored the
        # same average over more sittings ranks above a one-off.
        ranked = sorted(
            rows.values(),
            key=lambda r: (r["avg"], r["passed"], r["attempts"]),
            reverse=True)[:limit]
        # META BESIDE THE LIST, so truncation is never silent. `data` stays a
        # bare list - that is the existing contract the client reads - and
        # `total` lets any caller see whether it is holding the whole board.
        return ok(
            [
                S.leaderboard_row(rank, row["rec"], row["attempts"], row["avg"],
                                  row["best"], row["passed"])
                for rank, row in enumerate(ranked, start=1)
            ],
            meta={
                "total": len(rows),
                "returned": len(ranked),
                "truncated": len(ranked) < len(rows),
            },
        )

    @http.route("/api/v1/budget", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_operator
    def budget(self, **kw):
        """LLM spend against the configured caps.

        SPEND AND CAP BOTH COME FROM THE GATE'S OWN SOURCES. Spend is summed
        from the persisted usage ledger (recorded cost, not an estimate) and
        the caps are resolved by `vertex.spend_cap` - the same function
        `vertex._check_budget` refuses calls with - so this screen and the gate
        cannot disagree. That was not true before: a local helper here read the
        parameter with a default of "0", so with the rows absent from
        ir.config_parameter this screen reported `cap_usd: 0, capped: false`
        while the gate was refusing every call at $100/day. The docstring that
        used to sit here claimed the two "can never disagree", which is why
        nobody re-checked. The daily window is UTC midnight for the same reason
        the gate uses UTC.
        """
        Usage = request.env["assessments.be.llm.usage"].sudo()
        day_start = fields.Datetime.now().strftime("%Y-%m-%d 00:00:00")

        def _spend(domain):
            rows = Usage._read_group(domain, [], ["cost_usd:sum"])
            return (rows[0][0] or 0.0) if rows else 0.0

        daily_cap = vertex_svc.spend_cap(
            request.env, "daily_llm_cap_usd", DEFAULT_DAILY_LLM_CAP_USD)
        today = _spend([("create_date", ">=", day_start)])
        by_operation = []
        for operation, cost, tokens in Usage._read_group(
                [("create_date", ">=", day_start)], ["operation"],
                ["cost_usd:sum", "total_tokens:sum"]):
            by_operation.append({
                "operation": operation or "other",
                "cost_usd": round(cost or 0.0, 5),
                "total_tokens": tokens or 0,
            })
        return ok({
            "today": {
                "spend_usd": round(today, 5),
                "cap_usd": daily_cap,
                "remaining_usd": round(max(0.0, daily_cap - today), 5)
                if daily_cap > 0 else None,
                "capped": daily_cap > 0 and today >= daily_cap,
                "by_operation": sorted(
                    by_operation, key=lambda r: r["cost_usd"], reverse=True),
            },
            "per_evaluator_cap_usd": vertex_svc.spend_cap(
                request.env, "per_evaluator_llm_cap_usd",
                DEFAULT_PER_EVALUATOR_LLM_CAP_USD),
            "lifetime": {
                "spend_usd": round(_spend([]), 5),
                "calls": Usage.search_count([]),
            },
        })

    @http.route("/api/v1/ledger", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_operator
    def ledger(self, **kw):
        """Raw LLM call ledger: one row per billable call."""
        Usage = request.env["assessments.be.llm.usage"]
        domain = []
        operation = str_arg("operation")
        if operation:
            domain.append(("operation", "=", operation))
        model = str_arg("model")
        if model:
            domain.append(("model", "=", model))
        generator_id = int_arg("generator_id")
        if generator_id:
            domain.append(("prompt_id", "=", generator_id))
        evaluator_id = int_arg("evaluator_id")
        if evaluator_id:
            domain.append(("evaluator_id", "=", evaluator_id))
        since = str_arg("since")
        if since:
            domain.append(("create_date", ">=", since))
        limit, offset = paging()
        total = Usage.search_count(domain)
        records = Usage.search(
            domain, limit=limit, offset=offset, order=_NEWEST_FIRST)
        return paged([S.usage_row(u) for u in records], total, limit, offset)

    #: Records that carry a chatter, and the group needed to read each one.
    #:
    #: An allow-list, not a free `model` parameter: `/messages/<model>/<id>`
    #: with an unrestricted model name is a read primitive for every table in
    #: the database, including res.users and the mail queue.
    CHATTER_MODELS = {
        "assessment": "assessments.be",
        "generator": "assessments.be.prompt",
        "attempt": "assessments.be.evaluator",
    }

    @http.route("/api/v1/chatter/<string:kind>/<int:record_id>",
                type=API_TYPE, auth="user", methods=API_METHODS, csrf=False,
                cors="*")
    @api_endpoint
    @require_staff
    def chatter(self, kind, record_id, **kw):
        """The audit trail a record already keeps, as JSON.

        Every operator action in this module routes through `_log_activity`,
        which posts a note to the record's chatter - so the history exists and
        is complete, but only Odoo's own UI could read it. The Flutter console
        showed no history at all, which reads as "nothing has happened here"
        rather than "this surface cannot see it".

        Notes and comments only. The audit lines this module writes are notes,
        and an operator adding one writes a comment. Outgoing MAIL is excluded:
        the invitation carries the candidate's link and address in its body, and
        the docstring here used to claim that was filtered when the domain only
        dropped `user_notification` - so the leak it warned about was live.
        """
        model = self.CHATTER_MODELS.get(kind)
        if not model:
            return fail("bad_kind",
                        "Unknown record kind '%s'. Expected one of: %s."
                        % (kind, ", ".join(sorted(self.CHATTER_MODELS))),
                        status=400)
        record = request.env[model].browse(record_id).exists()
        if not record:
            return fail("not_found", "Record not found", status=404)
        # The ONLY line in this route that consults a record rule. Everything
        # below runs sudo, and `browse().exists()` is a bare SELECT id, so
        # without this an Evaluator could read the audit trail of any
        # assessment, generator or attempt by id - including the ones their
        # record rule hides.
        denied = record_read_guard(record)
        if denied:
            return denied

        limit, offset = paging()
        Message = request.env["mail.message"].sudo()
        # Filter on message_type by ALLOW-list, not a single exclusion.
        # `comment` is a human note or reply; `notification` is the module's own
        # audit line. `email_outgoing` and `auto_comment` are the invitation and
        # its variants, which is what leaked.
        domain = [
            ("model", "=", model),
            ("res_id", "=", record.id),
            ("message_type", "in", ["comment", "notification"]),
        ]
        total = Message.search_count(domain)
        # `date desc, id desc`. `mail.message.date` is stamped by
        # `fields.Datetime.now()`, which strips microseconds, so every note
        # `_log_activity` posts inside the same second carries an identical date -
        # and an audit trail that drops entries between pages is worse than no
        # audit trail, because it looks complete.
        messages = Message.search(
            domain, limit=limit, offset=offset, order="date desc, id desc")
        return paged([S.chatter_row(m) for m in messages],
                     total, limit, offset)

    # ------------------------------------------------------------------
    # Sent mail
    # ------------------------------------------------------------------
    #
    # WHY A SEPARATE SURFACE FROM /chatter. The chatter route deliberately
    # drops `email_outgoing` and `auto_comment` because those bodies carry the
    # candidate's sign-in link, and an operator therefore had no way at all to
    # answer "did the invitation go out, and did it bounce?" - the single most
    # common support question - without opening Odoo's own Settings >
    # Technical > Emails list. These routes answer it with METADATA: state,
    # failure_type, failure_reason, recipients. The body is manager-only and
    # opt-in (see `S.email_row`), so the leak stays closed.

    #: `mail.mail.state`'s own selection. Validated against rather than passed
    #: through, because an unknown state in the domain silently returns an
    #: empty page and reads to an operator as "no mail was ever sent".
    EMAIL_STATES = ("outgoing", "sent", "received", "exception", "cancel")

    #: THIS MODULE'S MAIL, and nothing else. Invitations are filed on the
    #: attempt, notes on the assessment and the generator - the records the
    #: chatter allow-list names. The global list and cancel used to span the
    #: whole queue, so every Manager read (and could cancel) any module's mail
    #: body, password-reset links included.
    ASSESSMENT_MAIL = [
        ("mail_message_id.model", "in", sorted(CHATTER_MODELS.values())),
    ]

    def _email_domain(self):
        """The `state` filter shared by both list routes, or a 400 envelope.

        Returns (domain, error): exactly one of the two is meaningful.
        """
        state = str_arg("state")
        if not state:
            return [], None
        if state not in self.EMAIL_STATES:
            return None, fail(
                "bad_state",
                "Unknown mail state '%s'. Expected one of: %s."
                % (state, ", ".join(self.EMAIL_STATES)),
                status=400)
        return [("state", "=", state)], None

    def _email_page(self, domain):
        """Search mail.mail under sudo and return the paged envelope.

        sudo because upstream grants `mail.mail` to `base.group_system` and to
        nobody else, so reading it as the caller raises AccessError for every
        Evaluator AND for an assessment Manager who is not a settings admin -
        which is most of them. The caller has already proved it may read the
        RECORD (or is a Manager, for the global list); that is the check that
        decides this, and turning it into "you must be a settings admin to see
        whether an invitation bounced" would be the wrong gate.

        Ordered by id, not by date: `date` is `mail.message`'s column reached
        by _inherits, and the ORM can only ORDER BY a column of the table it is
        querying. A mail row is created when its message is, so id is the same
        chronology.
        """
        limit, offset = paging()
        Mail = request.env["mail.mail"].sudo()
        total = Mail.search_count(domain)
        mails = Mail.search(domain, limit=limit, offset=offset, order="id desc")
        # Body only for a Manager. An Evaluator gets the metadata and nothing
        # that could be replayed as a candidate.
        include_body = request.env.user.has_group(GROUP_MANAGER)
        return paged(
            [S.email_row(m, include_body=include_body) for m in mails],
            total, limit, offset)

    @http.route("/api/v1/emails/<string:kind>/<int:record_id>",
                type=API_TYPE, auth="user", methods=API_METHODS, csrf=False,
                cors="*")
    @api_endpoint
    @require_staff
    def emails_for_record(self, kind, record_id, **kw):
        """Delivery history for one assessment, generator or attempt.

        Reuses the chatter allow-list for the same reason it exists: a free
        `model` parameter here would be a read primitive over the entire mail
        queue, which is every password-reset and invitation in the database.
        """
        model = self.CHATTER_MODELS.get(kind)
        if not model:
            return fail("bad_kind",
                        "Unknown record kind '%s'. Expected one of: %s."
                        % (kind, ", ".join(sorted(self.CHATTER_MODELS))),
                        status=400)
        record = request.env[model].browse(record_id).exists()
        if not record:
            return fail("not_found", "Record not found", status=404)
        # Same reason as the chatter route: the search below is sudo and
        # nothing else in this route reads a field as the caller, so this is
        # the only line that can refuse a record the caller may not see.
        denied = record_read_guard(record)
        if denied:
            return denied

        domain, error = self._email_domain()
        if error:
            return error
        # `mail_message_id.model` / `.res_id`, never `model` / `res_id`:
        # mail.mail has no such columns of its own, it delegates them to
        # mail.message through _inherits.
        scope = [
            ("mail_message_id.model", "=", model),
            ("mail_message_id.res_id", "=", record.id),
        ]
        # AN ASSESSMENT'S MAIL IS FILED AGAINST ITS ATTEMPTS. Invitations go
        # out through `send_mail` on each `assessments.be.evaluator`, so the
        # scope above alone matched nothing and every assessment's Emails tab
        # read "no email has been sent" beside a column of "Sent" invites.
        # Searched as the caller, so record rules decide which attempts count.
        if kind == "assessment":
            attempt_ids = request.env["assessments.be.evaluator"].search(
                [("assessment_id", "=", record.id)]).ids
            if attempt_ids:
                scope = ["|", "&"] + scope + [
                    "&",
                    ("mail_message_id.model", "=", "assessments.be.evaluator"),
                    ("mail_message_id.res_id", "in", attempt_ids),
                ]
        return self._email_page(scope + domain)

    @http.route("/api/v1/emails", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def email_list(self, **kw):
        """Every assessment mail queued or sent, newest first.

        Manager-only, unlike the record-scoped route: this one is not bound to
        a record the caller has been granted. Scoped to `ASSESSMENT_MAIL`, so
        another module's mail (a password reset, say) is never listed.
        `state` is the filter that matters in practice (`exception` is the
        bounce list).
        """
        domain, error = self._email_domain()
        if error:
            return error
        return self._email_page(self.ASSESSMENT_MAIL + domain)

    @http.route("/api/v1/emails/<int:mail_id>/cancel", type=API_TYPE,
                auth="user", methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def email_cancel(self, mail_id, **kw):
        """Stop a queued mail from ever being sent.

        Cancel rather than retry: this database is seeded with @example.com
        recipients that hard-bounce, so a stuck invitation is almost never
        worth another delivery attempt - it needs the address fixed on the
        candidate and a fresh invitation, which `/attempts/<id>/resend`
        already does.

        Calls `mail.mail.cancel()` rather than writing `state` directly so the
        transition stays whatever upstream decides it is.

        Only an unsent mail can be cancelled: writing `cancel` over a `sent`
        row would rewrite delivery history that actually happened, and this
        surface is what an operator uses to establish exactly that.
        """
        # Same scope as the list: a mail this surface cannot show is one it
        # cannot cancel either.
        mail = request.env["mail.mail"].sudo().search(
            [("id", "=", mail_id)] + self.ASSESSMENT_MAIL, limit=1)
        if not mail:
            return fail("not_found", "No such mail", status=404)
        if mail.state not in ("outgoing", "exception"):
            return fail(
                "not_cancellable",
                "Only a queued or failed mail can be cancelled; this one is "
                "'%s'." % (mail.state or "unknown"),
                status=422)
        mail.cancel()
        return ok(S.email_row(mail, include_body=False))

    @http.route("/api/v1/settings", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def settings(self, **kw):
        """Operational settings the app may display and edit.

        NO SECRET VALUE LEAVES THIS ROUTE. The API key, the static OAuth
        bearer, the service-account JSON and the S3 secret are reported as a
        BOOLEAN - set or not set - and never as their contents. A mobile
        client has no business holding provider credentials, and a settings
        screen does not need them: what an operator has to know is whether a
        credential is present and which identity it is, not what it says.

        What the identity IS is not secret and is reported: the SA's
        `client_email` and the filename it was uploaded under. Those are the
        two facts that answer "why is Vertex refusing me" without handing
        anybody a private key. The S3 access key ID is reported for the same
        reason and on the same footing as the module's own Odoo settings
        form, which renders it as plain text while masking the secret beside
        it: an access key ID is an identifier, useless without its secret.
        """
        icp = request.env["ir.config_parameter"].sudo()

        def _param(key, default=""):
            return icp.get_param("assessments_be_v2.%s" % key, default) or ""

        def _secret_set(key):
            """Whether a secret is configured, without reading its value.

            `secret_store.get_secret` would decrypt it; presence is decided on
            the STORED value so nothing is decrypted to answer a question that
            only needs a yes or no. PLACEHOLDER is the module's own convention
            for "a row exists to show the shape", and it is not configuration.
            """
            raw = (icp.get_param("assessments_be_v2.%s" % key, "") or "").strip()
            return bool(raw) and "PLACEHOLDER" not in raw

        def _sa_identity():
            """The uploaded service account's own email, or ''.

            Decrypting here is deliberate and is the one place it happens: the
            answer is a public identifier that the JSON carries alongside the
            key, and an operator staring at a 403 needs to know WHICH service
            account is being refused. A malformed or undecryptable blob yields
            '' rather than raising - a settings screen must still render.
            """
            raw = secret_store.get_secret(
                request.env, "assessments_be_v2.vertex_service_account_json")
            if not raw:
                return ""
            try:
                return (json.loads(raw) or {}).get("client_email", "") or ""
            except (ValueError, TypeError):
                return ""

        def _num(key, default=0.0):
            try:
                return float(_param(key, str(default)) or default)
            except (TypeError, ValueError):
                return default

        return ok({
            "models": {
                "generation": _param("generation_model"),
                "detection": _param("detection_model"),
                # Reads a rendered image back to confirm planted flaws landed.
                # Falls through to detection when empty.
                "verify": _param("verify_model"),
                "scoring": _param("scoring_model"),
                # Cheap lane for extract_tags / consolidate_vocab / skill
                # labelling. Falls through to generation when empty.
                "utility": _param("utility_model"),
                "fallback": _param("fallback_model"),
                "image": _param("image_model"),
                "video": _param("video_model"),
                # The DEFAULT every empty override falls back to. It governs
                # as much as the five above it and was the one model name the
                # screen could not show, so an operator reading five blank
                # overrides had no way to see what was actually running.
                "default": _param("vertex_model"),
                # WRITE-ONLY UNTIL NOW, which is the worst shape a setting can
                # have: `SETTINGS` in write.py accepts `thinking_level`, so the
                # console could set it and then had no way to show what it had
                # set. An operator who changed it saw the field snap back to
                # blank on the next read and could not tell whether the save
                # landed. Empty means "let the model decide"; the Odoo form
                # renders the same four choices.
                "thinking_level": _param("thinking_level"),
            },
            # WHERE the models run, and under WHOSE identity. Same block the
            # module's own Odoo form calls "Vertex AI".
            "vertex": {
                "project_id": _param("vertex_project_id"),
                "location": _param("vertex_location"),
                # The call-rate ceiling. Reported here because it is the one
                # bound nothing else enforces any more: v2's
                # `_check_llm_limits` is composed away by a same-named method
                # in `etp_assessment_pro`, so the Odoo form accepts a negative
                # and only the API refuses it.
                "max_rpm": int(_num("vertex_max_rpm", 0)),
                "api_key_set": _secret_set("vertex_api_key"),
                "access_token_set": _secret_set("vertex_access_token"),
                "service_account": {
                    "set": _secret_set("vertex_service_account_json"),
                    "filename": _param("vertex_service_account_filename"),
                    "client_email": _sa_identity(),
                },
                # Non-secret identity of the CURRENT key, and whether the
                # project id is following it. Without these, a key swap that
                # left the project pointing at the old GCP project was only
                # visible as a 403 at generation time.
                "sa_fingerprint": _param("vertex_sa_fingerprint"),
                "project_id_follows_key": bool(
                    _param("vertex_project_id_source")
                    and _param("vertex_project_id_source")
                    == _param("vertex_project_id")),
            },
            # Veo is REGIONAL where Gemini is global, and a clip request sent
            # to the wrong one 404s in a way that reads as a missing model.
            # Its own block, because its location is not the Vertex one.
            "video": {
                "model": _param("video_model"),
                "location": _param("video_location"),
                "default_duration_s": _param("video_default_duration_s"),
            },
            "scoring": {
                # Seeds a NEW assessment's pass threshold; 1-100.
                "default_pass_threshold": int(request.env[
                    "assessments.be"]._default_pass_threshold()),
                "shards": int(_num("scoring_shards", 1)),
                # THE STORED VALUE, because the panel posts it back on Save:
                # reporting the pool-lowered one wrote that over the setting.
                # What each lane actually runs is reported beside it.
                "parallel_calls": request.env[
                    "assessments.be"]._scoring_parallel_calls_setting(),
                "parallel_calls_effective":
                    request.env["assessments.be"]._scoring_parallel_calls(),
                "tick_limit": int(_num("scoring_tick_limit", 20)),
                # THE SCHEDULER'S OWN RESOLVERS, not `_num`, for these two.
                # They defaulted to 0 while the fields default to 8 and 3, and
                # 0 is also a value that really is STORED (the Odoo form writes
                # "0" for any falsy numeric, and the write route blesses 0 as
                # "use the module default") - so a missing-row fix alone would
                # still render 0 here. `scoring._scoring_batch_size` /
                # `_max_attempts` coerce both cases the way the grader does,
                # which is the only way this screen reports the batch size that
                # will actually be used.
                "batch_size": scoring_svc._scoring_batch_size(request.env),
                "llm_max_attempts": scoring_svc._max_attempts(request.env),
                # The model scoring RESOLVES to after every fallback, and
                # whether the catalog can price it and knows its limits - the
                # facts a scoring-model swap has to check first.
                "resolved_model": model_catalog.describe(
                    vertex_svc._scoring_model(request.env)),
                # What `services/locks.cron_lock` runs: advisory when unset
                # or unknown, so a Save of this value is always accepted.
                "cron_lock_mode": next(
                    (code for code, _label in CRON_LOCK_MODE_SELECTION
                     if code == _param("cron_lock_mode")), "advisory"),
            },
            "governance": {
                # THE MODULE DEFAULT, for the reason spelled out under the two
                # caps below: an absent row is "not configured", and the
                # runtime reader resolves it to SCORE_OUTLIER_SIGMA_DEFAULT
                # (`models/assessment.py`). Reporting 0.0 here said "outlier
                # flagging is off" about a net that was on, and the governance
                # panel posts all four keys back on any Save - so one Save of
                # a form prefilled with 0 turned it off for real. A STORED "0"
                # still reports 0: that is the operator asking for no net.
                "score_outlier_sigma": _num(
                    "score_outlier_sigma", SCORE_OUTLIER_SIGMA_DEFAULT),
                "pii_retention_days": int(_num("pii_retention_days", 0)),
                # THE CAPS THE GATE IS ACTUALLY ENFORCING. `_num(..., 0.0)`
                # showed 0.00 whenever the row was absent, and the Flutter
                # governance panel posts all four of these keys back on any
                # Save whether or not they were edited - so an operator who
                # opened Settings to change the retention days saved
                # daily_llm_cap_usd = 0.0 and genuinely disabled the cap. This
                # screen must prefill what `vertex._check_budget` will refuse
                # on, which means the same resolver and the same default.
                "daily_llm_cap_usd": vertex_svc.spend_cap(
                    request.env, "daily_llm_cap_usd",
                    DEFAULT_DAILY_LLM_CAP_USD),
                "per_evaluator_llm_cap_usd": vertex_svc.spend_cap(
                    request.env, "per_evaluator_llm_cap_usd",
                    DEFAULT_PER_EVALUATOR_LLM_CAP_USD),
            },
            "storage": {
                "s3_bucket": _param("s3_bucket"),
                "s3_region": _param("s3_region"),
                "s3_cdn_url": _param("s3_cdn_url"),
                # The prefix and the retry budget are as much a part of "where
                # does media go" as the bucket is, and an operator debugging a
                # bucket that fills under the wrong prefix could not see either.
                # Still no credential: key id and secret stay out, as the
                # docstring above promises.
                "s3_folder": _param("s3_folder"),
                "s3_max_retries": int(_num("s3_max_retries", 3)),
                # The IDENTITY, and whether its secret is present. The key ID
                # is an identifier - the module's own settings form renders it
                # unmasked next to the password-masked secret - and it is the
                # only thing that tells an operator WHICH IAM user is being
                # refused when uploads start failing.
                "s3_access_key_id": _param("s3_access_key_id"),
                # `""` is off, and every other spelling the stream reader
                # accepts ("1"/"true"/"yes"/"on") is on - normalised to a real
                # boolean here so the client never has to know that.
                "media_redirect_to_s3": str(
                    _param("media_redirect_to_s3") or "").strip().lower()
                in ("1", "true", "yes", "on", "t"),
                "s3_secret_set": _secret_set("s3_secret_key"),
                # THE SERVICE'S OWN PREDICATE, not a weaker restatement of it.
                #
                # `bool(_param("s3_bucket"))` called a bucket with no
                # credentials "configured", so the settings screen reported
                # storage as healthy while every upload raised "S3 not
                # configured". s3_service.is_configured requires bucket AND
                # access key AND secret, and strips PLACEHOLDER values the way
                # this route's local _param does not - so it is also the only
                # one of the two that a half-finished setup cannot fool.
                "configured": s3_service.is_configured(request.env),
                # HOW LONG A SIGNED MEDIA URL LIVES, because it is the setting
                # behind the most confusing media failure there is: a clip that
                # played at the start of a paper and 403s an hour in. The
                # signer's own default was 15 minutes and a `<video>` element
                # re-requests its source on every seek, reload and resumed
                # session.
                "media_presign_seconds": int(_num(
                    "media_presign_seconds",
                    media_stream.DEFAULT_PRESIGN_SECONDS)),
            },
            # The Redis question cache: on or off, `env` (REDIS_URL, which
            # wins) or `setting` (`redis_url`), and the target as
            # scheme://host:port/db. Never the URL itself, which can carry a
            # password - so it is not a value to post back to `redis_url`.
            "question_cache": question_cache.describe(request.env),
            # The exam runner, as `/state` and `/begin` advertise it, both
            # writable through `/settings/update`: whole-paper prefetch, and
            # the answer batch interval clamped to 15-300 with 0 or unset as
            # the default 60.
            "exam": {
                "paper_prefetch": _paper_prefetch(request.env),
                "answers_flush_seconds": _answers_flush_seconds(request.env),
            },
            "base_url": icp.get_param("web.base.url", ""),
        })


def _cohort_categories(evaluators, min_answers=2):
    """`[{tag, label, earned, possible, percent, answers}]`, strongest first.

    `label` is the tag's own readable name, not its machine key - see the
    `display` note in the bucket below.

    AVERAGED OVER MARKS, NOT OVER PERCENTAGES - the same rule the candidate-side
    panel follows. Averaging per-answer percentages would weight a 1-mark
    question the same as a 10-mark one, so a cohort could read "60% on Artifact
    detection" while it earned 6 of 60 marks. Summing both sides and dividing
    once is the only figure a person can check by hand.

    ONE FACET AT A TIME. Mixing `skill:` with `modality:` compares an ability
    against the format of the paper, and every answer would appear in several
    rows - so the "weakest category" could be a fact about the question type
    rather than about the cohort.

    UNTAGGED ANSWERS ARE SKIPPED, NOT BUCKETED. An "Other" row would present the
    absence of a vocabulary as a category people are weak at.
    """
    # AN ANSWER STILL WAITING FOR THE GRADER IS LEFT OUT, not counted as 0 of
    # its marks - the per-answer form of `_answers_scored_domain`.
    responses = evaluators.mapped("response_ids").filtered(
        lambda r: (r.state == "submitted" or r.final_mark or r.mcq_mark)
        and not (r.needs_llm and r.llm_state != "scored"))
    if not responses:
        return []
    Tag = evaluators.env["assessments.be.tag"]
    # Pick the facet the same way the client does: skill, then task, then
    # domain, then whatever is present.
    facets = set()
    for resp in responses:
        for tag in resp.question_id.tag_ids:
            name = tag.name or ""
            facets.add(name.split(":", 1)[0].strip().lower()
                       if ":" in name else "")
    for preferred in ("skill", "task", "domain"):
        if preferred in facets:
            chosen = preferred
            break
    else:
        chosen = sorted(facets)[0] if facets else ""

    buckets = {}
    for resp in responses:
        for tag in resp.question_id.tag_ids:
            name = (tag.name or "").strip()
            if not name:
                continue
            facet, _, rest = name.partition(":")
            if (facet.strip().lower() if rest else "") != chosen:
                continue
            row = buckets.setdefault(
                name, {"earned": 0.0, "possible": 0.0, "answers": 0,
                       # THE READABLE NAME, CARRIED FROM THE TAG ITSELF.
                       #
                       # `display` is the human alias the extraction model mints
                       # once per key and never changes ("AI Image Editing").
                       # The label used to be built by chopping the facet off
                       # the machine key, which handed the client
                       # `ai-image-editing` - and the client's own fallback
                       # capitalises the first word only, so the panel read
                       # "Ai image editing" on every screen that shows it.
                       "display": (tag.display or "").strip()
                                  or Tag._default_display(name)})
            # ONE ANSWER CONTRIBUTES THE MARKS IT WAS ACTUALLY OUT OF.
            #
            # This used to add a literal 1.0, with a comment asserting
            # `final_mark` is 1-or-0. That stopped being true when component
            # scoring landed: a multi-component question now earns 0..N, so a
            # numerator of 4.0 sat over a denominator of 1.0 and the dashboard
            # reported 400% for a single answer. Stage showed 111.8%.
            row["earned"] += resp.final_mark or 0.0
            row["possible"] += resp.final_max or 1.0
            row["answers"] += 1
    out = []
    for name, row in buckets.items():
        if row["answers"] < min_answers:
            # One answer is an anecdote, not a finding.
            continue
        percent = (100.0 * row["earned"] / row["possible"]
                   if row["possible"] else 0.0)
        out.append({
            "tag": name,
            "label": row["display"] or name.partition(":")[2].strip() or name,
            "earned": round(row["earned"], 2),
            "possible": round(row["possible"], 2),
            "answers": row["answers"],
            "percent": round(percent, 1),
        })
    out.sort(key=lambda r: r["percent"], reverse=True)
    return out


# ── Generation progress (`/api/v1/generators/<id>/progress`) ────────────────

#: sop_gen_state -> phase. `done` and `idle` are absent on purpose: whether
#: they read as media, ready or idle depends on the run's drafts.
_GEN_PHASES = {"queued": "queued", "generating": "authoring",
               "finalizing": "finalizing", "failed": "failed",
               "cancelled": "cancelled"}
_GEN_ACTIVE = ("queued", "authoring", "finalizing", "media")
#: Draft review state -> bucket, as `generator_detail`'s `draft_counts`.
_DRAFT_BUCKETS = {"draft": "pending", "approved": "approved",
                  "denied": "denied"}
#: video_state -> bucket. `generating` (a Veo op in flight) is still pending;
#: `partial` is failed, as `/drafts/<id>/retry_video` treats it.
_VIDEO_BUCKETS = {"pending": "pending", "generating": "pending",
                  "rendered": "ready", "partial": "failed", "failed": "failed",
                  "cancelled": "cancelled"}
_CRON_MINUTES = {"minutes": 1, "hours": 60, "days": 1440, "weeks": 10080,
                 "months": 43200}
#: How late a cron's nextcall may be before its lane reads as stalled. A tick
#: still running is not late - Odoo moves nextcall only when a tick ends - so
#: a held lock (or live lease) excuses it, as in `_scoring_drainer_health`.
_GEN_CRON_GRACE = timedelta(minutes=2)
# A run still `finalizing` this long has lost its draft saves to other writes;
# the generation cron settles it at 15 minutes (`_settle_stuck_finalizing`).
_FINALIZE_STALL = timedelta(minutes=5)
_IST = timezone(timedelta(hours=5, minutes=30))


def _gen_step(usage):
    """A short name for what a run's newest ledger row was doing.

    Generation calls share one operation and differ by the `note`
    `services/vertex` stamps: "topup" / "quota" for the fill-up calls,
    "critique", "backfill_solutions" (answer keys), "<name> (retry)" for the
    terse re-ask, and the generator's own name on the main call. Media rows
    differ by operation. Anything else shows its operation.
    """
    op, note = usage.operation or "other", usage.note or ""
    if op == "generate_questions":
        if note.startswith("critique"):
            return "critique"
        if note.startswith("backfill_solutions"):
            return "answer keys"
        if note.startswith(("topup", "quota")):
            return "top-up"
        return "retry" if "(retry)" in note else "main"
    if op in ("generate_image", "verify_planted_flaws",
              "detect_image_elements", "locate_defect"):
        return "image"
    if op in ("generate_video", "submit_video_op", "fetch_video_op"):
        return "video"
    return op.replace("_", " ")


def _ist(value):
    """HH:MM in IST for the one-line summary; the payload's times stay UTC."""
    return (value.replace(tzinfo=timezone.utc).astimezone(_IST)
            .strftime("%H:%M") if value else "")


def _plural(count, noun):
    return "%d %s%s" % (count, noun, "" if count == 1 else "s")


def _generation_progress(generator, show_cost=False, can_retry=False):
    """Phase, counts and one-line summary of a generator's latest run.

    The latest run's drafts are those created since `sop_gen_started_at`
    (every draft, on a run from before that column existed). Grouped reads
    only - the screen polls this - and no writes. Reads `generator.env`, not
    `request`, so a test can call it directly.
    """
    env = generator.env
    now = fields.Datetime.now()
    started = generator.sop_gen_started_at
    finished = generator.sop_gen_finished_at
    Draft = env["assessments.be.prompt.question"]
    domain = generator._latest_run_draft_domain()

    drafts = dict.fromkeys(("total", "pending", "approved", "denied"), 0)
    images = dict.fromkeys(
        ("total", "pending", "rendered", "uploaded", "failed", "cancelled"), 0)
    videos = dict.fromkeys(
        ("total", "pending", "ready", "failed", "cancelled"), 0)
    for state, image_state, video_state, count in Draft._read_group(
            domain, ["state", "image_state", "video_state"], ["__count"]):
        drafts["total"] += count
        if state in _DRAFT_BUCKETS:
            drafts[_DRAFT_BUCKETS[state]] += count
        # 'none' (no picture needed) is not a key, so it is not counted.
        if image_state in images:
            images["total"] += count
            images[image_state] += count
        if video_state in _VIDEO_BUCKETS:
            videos["total"] += count
            videos[_VIDEO_BUCKETS[video_state]] += count

    run = {"started_at": S.iso(started), "finished_at": S.iso(finished),
           "elapsed_s": None, "llm_calls": 0, "last_step": None,
           "last_step_at": None, "cost_usd": 0.0 if show_cost else None}
    if started:
        Usage = env["assessments.be.llm.usage"]
        ledger = [("prompt_id", "=", generator.id),
                  ("create_date", ">=", started)]
        [(calls, cost)] = Usage._read_group(
            ledger, aggregates=["__count", "cost_usd:sum"])
        run["elapsed_s"] = max(
            0, int(((finished or now) - started).total_seconds()))
        run["llm_calls"] = calls
        if show_cost:
            run["cost_usd"] = round(cost or 0.0, 4)
        if calls:
            last = Usage.search(ledger, limit=1, order=_NEWEST_FIRST)
            run["last_step"] = _gen_step(last)
            run["last_step_at"] = S.iso(last.create_date)

    sudo_env = env(su=True)
    gen_cron, image_cron, video_cron = (
        sudo_env.ref("assessments_be_v2.%s" % xmlid, raise_if_not_found=False)
        for xmlid in ("ir_cron_generate_from_sop",
                      "ir_cron_render_pending_images",
                      "ir_cron_poll_video_ops"))

    phase = _GEN_PHASES.get(generator.sop_gen_state)
    if not phase:
        phase = ("media" if images["pending"] or videos["pending"]
                 else "ready" if drafts["total"] else "idle")

    # STALLED = work waiting on a cron that is off, missing or late. Only a
    # lane with work is asked: an idle lane's cron being off stops nothing.
    lanes = []
    if phase == "queued":
        lanes.append((gen_cron, ADVISORY_LOCK_QUESTION_GEN,
                      "question generation", "this run is queued"))
    if images["pending"]:
        lanes.append((image_cron, ADVISORY_LOCK_IMAGE_RENDER, "image render",
                      "%d draft(s) are waiting for images" % images["pending"]))
    if videos["pending"]:
        lanes.append((video_cron, ADVISORY_LOCK_VIDEO_POLL, "video (Veo)",
                      "%d draft(s) are waiting for video" % videos["pending"]))
    reasons, held = [], None
    for cron, lock, name, waiting in lanes:
        if not cron or not cron.active:
            verdict = "switched off" if cron else "missing"
        elif cron.nextcall and cron.nextcall < now - _GEN_CRON_GRACE:
            if held is None:
                held = env["assessments.be"]._held_cron_locks(
                    [lane[1] for lane in lanes])
            if lock in held:
                continue
            verdict = "more than 2 minutes overdue"
        else:
            continue
        reasons.append("The %s cron is %s and %s." % (name, verdict, waiting))
    if (phase == "finalizing" and generator.write_date
            and generator.write_date < now - _FINALIZE_STALL):
        reasons.append(
            "Saving the generated drafts is taking longer than expected. It "
            "is retried automatically; after 15 minutes the run is closed - "
            "done if its drafts were saved, else failed so it can be "
            "generated again.")

    every_min = (image_cron.interval_number
                 * _CRON_MINUTES.get(image_cron.interval_type, 1)
                 if image_cron else None)
    next_image_at = image_cron.nextcall if image_cron else None
    media = {
        "next_image_run_at": S.iso(next_image_at),
        "images_per_run": IMAGE_RENDER_BATCH,
        "image_run_every_min": every_min,
        "est_minutes_left": (
            math.ceil(images["pending"] / IMAGE_RENDER_BATCH) * every_min
            if images["pending"] and every_min else None),
        "next_video_run_at": S.iso(video_cron.nextcall if video_cron
                                   else None),
    }

    minutes = (max(1, round(run["elapsed_s"] / 60.0))
               if run["elapsed_s"] is not None else None)
    if phase == "queued":
        at = _ist(gen_cron.nextcall) if gen_cron else ""
        summary = "Queued · starts at the next generation run%s" % (
            " (~%s IST)" % at if at else "")
    elif phase in ("authoring", "finalizing"):
        parts = ["Writing questions"]
        if run["last_step"]:
            parts.append("step %s" % run["last_step"])
        parts.append(_plural(run["llm_calls"], "model call"))
        if minutes is not None:
            parts.append("%d min elapsed" % minutes)
        if show_cost and started:
            parts.append("$%.2f" % run["cost_usd"])
        summary = " · ".join(parts)
    elif phase == "media":
        parts = ["Rendering media"]
        if images["total"]:
            parts.append("images %d/%d%s" % (
                images["rendered"] + images["uploaded"], images["total"],
                " (%d failed)" % images["failed"] if images["failed"] else ""))
        if videos["total"]:
            parts.append("videos %d/%d" % (videos["ready"], videos["total"]))
        # A nextcall in the past means the job is overdue: the stalled
        # notice explains that, so do not print a past time as "next".
        if images["pending"] and next_image_at and next_image_at >= now:
            parts.append("next image batch ~%s IST" % _ist(next_image_at))
        summary = " · ".join(parts)
    elif phase == "ready":
        parts = (["%s ready for review" % _plural(drafts["total"], "draft"),
                  "%d pending" % drafts["pending"]] if drafts["pending"]
                 else ["All %s reviewed" % _plural(drafts["total"], "draft")])
        parts += ["%d approved" % drafts["approved"],
                  "%d denied" % drafts["denied"]]
        if started and finished:
            parts.append("took %d min" % minutes)
        if show_cost and started:
            parts.append("run cost $%.2f" % run["cost_usd"])
        summary = " · ".join(parts)
    elif phase == "failed":
        summary = ("Generation failed - %s" % generator.sop_gen_error
                   if generator.sop_gen_error else "Generation failed.")
    elif phase == "cancelled":
        # `sop_gen_error` is always cleared on a cancel; the report says who
        # stopped it and what was kept.
        summary = generator.sop_gen_report or "Generation was cancelled."
    else:
        summary = ""

    failed_images = [
        {"id": row["id"], "name": row["name"] or ""}
        for row in Draft.search_read(
            domain + [("image_state", "=", "failed")], ["name"],
            limit=20, order="id")] if images["failed"] else []

    return {
        "generator_id": generator.id,
        "phase": phase,
        "active": phase in _GEN_ACTIVE,
        "summary": summary,
        "stalled": bool(reasons),
        "stalled_reason": " ".join(reasons) or None,
        "next_generation_run_at": S.iso(gen_cron.nextcall if gen_cron
                                        else None),
        "run": run,
        "drafts": drafts,
        "images": images,
        "videos": videos,
        "media": media,
        "failed_images": failed_images,
        "can_retry_images": bool(can_retry and images["failed"]),
        "show_cost": bool(show_cost),
    }
