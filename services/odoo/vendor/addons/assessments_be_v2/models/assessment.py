# -*- coding: utf-8 -*-
import base64
import collections
import csv
import hashlib
import io
import json
import logging
import math
import random
import re
import uuid
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from datetime import datetime, timedelta

from odoo import models, fields, api, tools, _
from odoo.exceptions import ValidationError, UserError
from markupsafe import Markup, escape

from .hr_applicant import _norm_email, candidate_row_error
from .prompt import _TRANSIENT_DB_ERRORS, _warn_lost_race
from .simple_import import upload_text

from ..constants import (
    DEFAULT_PASS_THRESHOLD,
    DEFAULT_PASS_THRESHOLD_PARAM,
    DEFAULT_SUBJECTIVE_THRESHOLD,
    SUBJECTIVE_COMPONENT_TYPES,
    LABELLING_COMPONENT_TYPES,
    TRANSCRIPTION_MINOR_LIMIT,
    ADVISORY_LOCK_AUTOSCORE,
    ADVISORY_LOCK_AUTOSCORE_SHARD_BASE,
    ADVISORY_LOCK_EXPIRE_ATTEMPTS,
    ADVISORY_LOCK_INVITE_SEND,
    ADVISORY_LOCK_PII_PURGE,
    MAX_SCORING_SHARDS,
    SETTING_RANGES,
    SCORE_OUTLIER_SIGMA_DEFAULT,
    SCORE_OUTLIER_MIN_COHORT,
    PII_RETENTION_DAYS_DEFAULT,
    is_integrity_gate,
    GATE_KEY_DRIFT,
)

from psycopg2 import IntegrityError
from psycopg2.errors import (
    InFailedSqlTransaction, SerializationFailure, TransactionRollbackError)

from ..services import evidence, seb
from ..services.locks import cron_lock, queued_count

_logger = logging.getLogger(__name__)

# L-9: caps for the candidate-roster CSV import (action_import_candidates_csv).
_MAX_CANDIDATE_CSV_BYTES = 25 * 1024 * 1024
_MAX_CANDIDATE_CSV_ROWS = 5000



def _first_line(exc):
    """The first line of an exception's message, bounded.

    The portal refusal is a five-line explanation; a list of 172 of them is
    unreadable. The first line already names the person and the address, which
    is what the operator acts on.
    """
    return (str(exc) or type(exc).__name__).strip().split("\n", 1)[0][:200]


def _skipped_lines(rows, limit=20):
    """``(name, address, reason)`` rows as an indented list, the rest counted."""
    lines = ["  - %s <%s>: %s" % tuple(row) for row in rows[:limit]]
    if len(rows) > limit:
        lines.append("  and %d more" % (len(rows) - limit))
    return "\n".join(lines)


#: `<record>.code` of every scoring drainer is `model._cron_llm_auto_score(
#: shard=N)` (data/cron.xml), and N is the only thing that says whether that
#: record is supposed to be running at the current `scoring_shards`.
_CRON_SHARD_RE = re.compile(r"shard\s*=\s*(\d+)")


def _cron_shard_index(code):
    """Which scoring shard an `ir.cron` record drives.

    A record that names no shard is shard 0 - the lane that always runs -
    because that is what `_cron_llm_auto_score`'s own default argument makes
    it. Guessing high instead would quietly excuse a dead drainer from the
    health check, which is the failure this parsing exists to prevent.
    """
    hit = _CRON_SHARD_RE.search(code or "")
    return int(hit.group(1)) if hit else 0


def _run_is_back(run):
    """Whether every judge call this candidate dispatched has come back."""
    return all(future.done() for _job, future in run.pending)


def _pop_first_ready(in_flight):
    """The in-flight candidate whose judge calls are ALL back, waiting for the
    first one that is.

    Storing whoever is ready keeps every slot busy; draining strictly
    oldest-first lets one slow call idle the slots behind it (73% slot use in
    a stress run). Order between candidates does not matter: each is written
    on a savepoint of its own and no candidate's marks depend on another's.
    """
    pending = [f for _ev, run in in_flight for _job, f in run.pending]
    while pending and not any(_run_is_back(run) for _ev, run in in_flight):
        wait(pending, return_when=FIRST_COMPLETED)
        pending = [f for f in pending if not f.done()]
    for i, (ev, run) in enumerate(in_flight):
        if _run_is_back(run):
            del in_flight[i]
            return ev, run
    return in_flight.popleft()


def _lane_lock(shard):
    """The advisory lock scoring lane ``shard`` holds for its whole tick."""
    return (ADVISORY_LOCK_AUTOSCORE if shard == 0
            else ADVISORY_LOCK_AUTOSCORE_SHARD_BASE + shard)


def _busy_note(busy):
    """What a scoring button says about the candidates it left to a lane."""
    return (" Skipped %d candidate(s) being graded right now - try again in "
            "a minute." % len(busy)) if busy else ""


class RescoreRefused(UserError):
    """A re-score request refused before anything was queued.

    ``code`` is the API's refusal code - `not_on_attempt` (422), and
    `spend_limit`, `being_graded`, `released_confirm_required`, `erased`,
    `archived`, `stopping` and `released_results` (409) - so
    `/attempts/<id>/rescore` can answer with it rather than a generic 422.
    The route maps anything that is not
    `not_on_attempt` to 409 (`attempt_rescore` in `controllers/api/admin.py`),
    so a code added here without a thought for its status silently becomes a
    409. Any other route answers with ``code`` and ``http_status``
    (`api_endpoint`).
    """

    def __init__(self, message, code):
        super().__init__(message)
        self.code = code
        self.http_status = 422 if code == "not_on_attempt" else 409


class SittingRefused(UserError):
    """A change refused while candidates are mid-attempt. `api_endpoint`
    answers it as 409 `sitting_in_progress`, as `/regenerate` does."""
    code = "sitting_in_progress"
    http_status = 409


class EtpAssessment(models.Model):
    _name = "assessments.be"
    _description = "Assessment"
    _inherit = ["mail.thread"]
    _order = "create_date desc"

    #: The one context key that lets `_unlink_except_with_candidate_data`
    #: stand aside. Set in exactly TWO places, each behind its own deliberate
    #: confirmation, and NOWHERE else - if you are auditing who can disarm this
    #: guard, this list is the answer and it is meant to stay this short:
    #:
    #:   - `controllers/api/write.py` - the two-step API delete route, which
    #:     sets it only after the caller has echoed the assessment's own name
    #:     back, so it can never be arrived at by a client resending a stale
    #:     payload.
    #:   - `models/delete_wizard.py` - the back-office Delete action, which
    #:     sets it only from a manager-only modal that names the counts about
    #:     to be destroyed and how many people are sitting the paper RIGHT NOW.
    #:     A dialog raised by the operator's own click cannot be replayed by a
    #:     stale payload, so it clears a different bar rather than a lower one;
    #:     it asks for no typed name.
    #:
    #: Named rather than a bare `force_delete`
    #: because a generic key is the sort of thing a helper adds to a shared
    #: context "to make deletes work" and then silently disarms the guard for
    #: every unlink downstream of it.
    CONFIRMED_DESTROY_CTX = "assessment_confirmed_destroy"

    @api.ondelete(at_uninstall=False)
    def _unlink_except_with_candidate_data(self):
        """Refuse to destroy candidate results; point at Archive instead.

        Responses cascade off the assessment, so deleting one silently wipes
        every candidate's answers and score. That is unrecoverable and almost
        never what the admin means - they just want it out of the list, which
        is exactly what archiving does.

        THE DELIBERATE EXCEPTION. Both delete paths archive the assessment
        first and then destroy it only once the operator has confirmed - the
        API route by making them echo the name back, the back-office wizard by
        making them press a red button in a modal that states what is about to
        be destroyed - and that confirmed intent arrives here as
        `CONFIRMED_DESTROY_CTX`. Without this branch the guard would be a wall
        rather than a default - the very state the archive/delete review of
        2026-09-17 recorded, where every used assessment was permanently
        undeletable by any route that existed. The guard is NOT removed: an
        ordinary `unlink()` - the Odoo list's Delete action, a cascade, a
        script - carries no such key and is still refused.
        """
        if self.env.context.get(self.CONFIRMED_DESTROY_CTX):
            # The attempts go by cascade, and with them the only thing that
            # can list their AI proctoring snapshots: purge those first, or
            # every candidate's face stays in S3 with nothing left to find it.
            # Never raises for S3 (`purge_evidence` logs and moves on).
            started = self.env["assessments.be.evaluator"].sudo().with_context(
                active_test=False).search([
                    ("assessment_id", "in", self.ids),
                    ("started_at", "!=", False)])
            for ev in started:
                evidence.purge_evidence(self.env, ev)
            return
        Response = self.env["assessments.be.response"].sudo()
        with_data = Response.with_context(active_test=False).search([
            ("assessment_id", "in", self.ids)])
        if not with_data:
            return
        # THE MESSAGE HAS TO KNOW WHAT STATE THE RECORD IS IN. It said
        # "Archive it, then use Delete Permanently" unconditionally, so an
        # operator who had ALREADY archived - and who could see the Delete
        # Permanently button sitting in the header - was told to go and do the
        # thing they had just done. A refusal that names an action already
        # taken reads as the feature being broken rather than as a guard.
        blocked = self.filtered(lambda a: a.id in with_data.assessment_id.ids)
        if blocked and all(not a.active for a in blocked):
            raise UserError(_(
                "%(n)s candidate response(s) attached. Use Delete "
                "Permanently.",
                n=len(with_data)))
        raise UserError(_(
            "%(n)s candidate response(s) attached. Archive it, then use "
            "Delete Permanently.",
            n=len(with_data)))

    def _log_activity(self, body):
        """Post a timestamped audit line to each assessment's chatter.

        Single choke-point for user-action audit. Best-effort: an audit note
        must never sink the action that triggered it.
        """
        for rec in self:
            if not rec.id:
                continue
            try:
                rec.message_post(body=body, message_type="comment",
                                 subtype_xmlid="mail.mt_note")
            except Exception:  # noqa: BLE001 - logging is never load-bearing
                _logger.exception(
                    "Chatter audit post failed for assessment %s", rec.id)

    name = fields.Char(required=True)
    active = fields.Boolean(
        default=True,
        help="Untick to ARCHIVE this assessment: it disappears from the "
             "default list but every candidate response and score is kept "
             "intact. Archiving is the safe alternative to deleting - a "
             "finished assessment can never be deleted without destroying "
             "the candidate results attached to it.")
    state = fields.Selection(
        [
            ("draft", "Draft"),
            ("in_progress", "In Progress"),
            ("done", "Done"),
            ("cancelled", "Cancelled"),
        ],
        default="draft",
        required=True,
    )

    generator_id = fields.Many2one(
        "assessments.be.prompt",
        string="Question Generator",
        ondelete="restrict",
    )
    question_limit = fields.Integer(
        string="Number of Questions",
        help="Number of questions to pick from the generator. 0 = all questions.",
        default=0,
    )
    # RETIRED (ETP_PLANS_AND_STRATEGY.md §4.3): nothing reads it any more -
    # launch and late-add always draw one shared set (the ORDER is still per
    # candidate, see `shuffle_questions`) - and it is off the API, the forms
    # and Form Studio publish. The column stays and no row is rewritten.
    same_questions_for_all = fields.Boolean(
        string="Same questions for everybody",
        default=True,
        help="Off draws an independent sample per person.")
    preserve_question_order = fields.Boolean(
        string="Keep Authored Order",
        default=False,
        help="Serve questions in their authored (sequence) order instead of "
             "shuffling them per candidate. Set automatically for a form "
             "published from Form Studio, where the author grouped questions "
             "into sections and arranged them deliberately - a random shuffle "
             "silently threw that structure away. Off (default) for a "
             "generator-drawn paper, where per-candidate shuffling is a "
             "deliberate anti-cheating measure and stays on.")

    # THE OPERATOR'S SPELLING OF THE FIELD ABOVE, NOT A SECOND SETTING.
    #
    # Flutter asks the affirmative question - "Shuffle Questions", on = shuffled
    # - and the column stores the negative. Relabelling `preserve_question_order`
    # itself would have made the checkbox mean the opposite of what it says,
    # which is worse than the inconsistency it was meant to fix, so the form
    # gets this mirror instead: it computes as the negation of the stored field
    # and writes back through its inverse, and the two therefore cannot
    # disagree. NOT STORED and read by nothing - `action_start`, the late-add
    # provisioner in controllers/api/admin.py and Form Studio's publish all
    # branch on `preserve_question_order`, which stays the single source of
    # truth. The API already exposes the same inversion on the wire
    # (`_apply_shuffle_alias`, `assessment_detail`); this is the same idea for
    # the form, and the help below is copied word for word from
    # assessment_detail_screen.dart so the two consoles cannot drift again.
    shuffle_questions = fields.Boolean(
        string="Shuffle Questions",
        compute="_compute_shuffle_questions",
        inverse="_inverse_shuffle_questions",
        help="Each candidate gets the questions in a random order fixed for "
             "their sitting. The numbers they read still count 1..N in the "
             "order they see.")

    @api.depends("preserve_question_order")
    def _compute_shuffle_questions(self):
        for rec in self:
            rec.shuffle_questions = not rec.preserve_question_order

    def _inverse_shuffle_questions(self):
        for rec in self:
            rec.preserve_question_order = not rec.shuffle_questions

    duration_minutes = fields.Integer(
        string="Duration (Minutes)",
        help="Time limit in minutes. At least 2 - every assessment is timed.",
        # NOT 0. The default is what a create that never names the field gets,
        # and `@api.constrains` runs after defaults are applied - so a default
        # of 0 under a floor of 2 makes every such create raise, including
        # Odoo's own New button.
        default=30,
    )
    question_ids = fields.Many2many(
        "assessments.be.question",
        "assessments_be_question_rel",
        "assessment_id",
        "question_id",
        string="Selected Questions",
    )
    total_questions_available = fields.Integer(
        compute="_compute_total_questions_available"
    )

    results_release = fields.Selection(
        [
            ("manual", "Manual (admin releases)"),
        ],
        default="manual",
        required=True,
        string="Results Release",
        help="Candidate-facing results stay hidden until an admin explicitly "
             "releases them (per evaluator via Release Results). This is the "
             "only release mode: results are never auto-revealed.",
    )
    # Read when the candidate opens the review (`exam_answers`), so a change
    # applies to results already released.
    results_show_answers = fields.Boolean(
        string="Show correct answers and feedback", default=True,
        help="On, released candidates see the correct answers, each answer's "
             "verdict and the grader's feedback. Off, they see their own "
             "answers and marks only. Read when they open the review, so a "
             "change applies at once.")

    def init(self):
        # SHOWN IS ALSO THE DATABASE'S DEFAULT. During a rolling deploy a pod
        # still on the old code inserts papers without this column, and Odoo
        # sets no column default, so they held NULL - which the ORM reads as
        # False, the key hidden. A NULL cannot be told apart from False once
        # read, so it is prevented here rather than guessed at by each reader.
        self.env.cr.execute(
            "SELECT column_default FROM information_schema.columns "
            "WHERE table_name = 'assessments_be' "
            "AND column_name = 'results_show_answers'")
        if (self.env.cr.fetchone() or [None])[0] != "true":
            self.env.cr.execute(
                "ALTER TABLE assessments_be "
                "ALTER COLUMN results_show_answers SET DEFAULT TRUE")

    subjective_threshold = fields.Float(
        string="Subjective Pass Threshold (%)",
        default=DEFAULT_SUBJECTIVE_THRESHOLD,
        help="Cut-off (0-100) each subjective answer and each labelling box "
             "must clear to earn its mark. Editable anytime; changing it "
             "re-decides Pass/Fail without re-grading.")
    # No field default on purpose: -u would write it into every existing row.
    # Seeded for new records by `default_get`; 0 = not set.
    pass_threshold = fields.Float(
        string="Pass Threshold (%)",
        help="Cut-off (1-100) on the candidate's total score that decides "
             "Pass/Fail of the whole attempt. While 0 (not set) it follows the "
             "Subjective Pass Threshold. Editable anytime; changing it "
             "re-decides Pass/Fail without re-grading.")
    # No field default either: 0 (not set) follows subjective_threshold, so -u
    # moves no existing result.
    transcription_threshold = fields.Float(
        string="Transcription Pass Threshold (%)",
        help="Cut-off (0-100) a transcription clip's score must clear to earn "
             "its mark. 0 (not set) follows the Subjective Pass Threshold. A "
             "clip loses 20 per critical mistake and 5 per minor one, and 1 "
             "critical or 5 minor fail it regardless, so 80 or less adds "
             "nothing. Editable anytime; changing it re-decides Pass/Fail "
             "without re-grading.")
    pass_threshold_note = fields.Char(
        string="Pass Threshold Note", compute="_compute_pass_threshold_note")
    threshold_recompute_pending = fields.Boolean(default=False, copy=False)

    @api.model
    def default_get(self, fields_list):
        res = super().default_get(fields_list)
        if "pass_threshold" in fields_list and "pass_threshold" not in res:
            res["pass_threshold"] = self._default_pass_threshold()
        return res

    @api.model
    def _default_pass_threshold(self):
        """The Settings default for new assessments, 1-100, else 70."""
        raw = self.env["ir.config_parameter"].sudo().get_param(
            DEFAULT_PASS_THRESHOLD_PARAM)
        try:
            value = float(raw)
        except (TypeError, ValueError):
            return DEFAULT_PASS_THRESHOLD
        return value if 1 <= value <= 100 else DEFAULT_PASS_THRESHOLD

    def _effective_pass_threshold(self):
        """The cut-off on score_percent: pass_threshold once set, else the
        subjective threshold (every assessment made before the field)."""
        return self.pass_threshold or self.subjective_threshold

    @api.depends("pass_threshold", "subjective_threshold")
    def _compute_pass_threshold_note(self):
        for rec in self:
            rec.pass_threshold_note = False if rec.pass_threshold else (
                "Not set - uses the subjective threshold: %g%%"
                % rec.subjective_threshold)

    @api.model
    def _refuse_bad_pass_threshold(self, vals):
        """0 is refused too: only rows made before the field are "not set".
        None is the one exemption - the copy of such a row (`copy_data`)."""
        value = vals.get("pass_threshold")
        if ("pass_threshold" in vals and value is not None
                and not 1 <= (value or 0) <= 100):
            raise ValidationError("Pass threshold must be between 1 and 100.")

    @api.model_create_multi
    def create(self, vals_list):
        for vals in vals_list:
            self._refuse_bad_pass_threshold(vals)
        records = super().create(vals_list)
        records._refuse_short_quit_password()
        return records

    def copy_data(self, default=None):
        vals_list = super().copy_data(default)
        for rec, vals in zip(self, vals_list):
            if vals and not rec.pass_threshold and \
                    "pass_threshold" not in (default or {}):
                vals["pass_threshold"] = None  # a not-set source stays not set
        return vals_list

    #: Legacy "outliers need a recompute" flag. The cohort outlier pass runs in
    #: `_cron_recompute_subjective_results`, once per paper, never inline with
    #: the marks: run inline, its write to every peer row collided between
    #: lanes and the abort unwound the marks too (451 of 1,669 runs on the
    #: 2026-09-03 drain).
    #:
    #: NO LONGER SET. Raising it was itself a write on the one paper row every
    #: lane shares, and its collisions threw away paid grading calls.
    #: Staleness is derived from `score_outlier_checked_at` below
    #: (`_outlier_stale_papers`); the cron still honours and clears a flag
    #: left up by the previous build.
    score_outlier_stale = fields.Boolean(default=False, copy=False)

    #: When `_cron_recompute_subjective_results` last recomputed this paper's
    #: outlier flags. Written by that cron ONLY - no grading lane writes the
    #: paper row any more (see `_outlier_stale_papers`). Empty on every paper
    #: that existed before it; the old flag above is still honoured for those.
    score_outlier_checked_at = fields.Datetime(copy=False, readonly=True)

    #: No longer set: settlements stopped raising it (SEB review #4), since
    #: the close pass sweeps every `in_progress` paper anyway. The pass still
    #: drains rows that hold it. The history below is why it existed.
    #:
    #: EXACTLY THE SAME REASONING AS `score_outlier_stale` ABOVE, applied to the
    #: cohort's own state instead of to a statistic.
    #:
    #: `_auto_submit_expired` used to end by loading every sibling evaluator and
    #: writing `state = "done"` on THIS row - the one the whole cohort shares -
    #: inside the transaction that had just settled one candidate's paper. Exams
    #: end in a burst, so settlements collided on this row; Postgres raised a
    #: serialization failure, and because the shared write shared a transaction
    #: with the settlement, the SETTLEMENT was discarded too. A cohort statistic
    #: took a candidate's paper down with it.
    #:
    #: The flag is also cheaper: the rollup reads the cohort ONCE per assessment
    #: rather than once per candidate, which at 1,200 candidates settling near
    #: one deadline is the difference between ~1.4M sibling row reads in the
    #: sharpest minute and a single grouped count.
    cohort_close_stale = fields.Boolean(default=False, copy=False)

    # copy=False required: a copied (now-past) schedule trips _check_schedule_dates.
    start_date = fields.Datetime(string="Start Date", copy=False)
    end_date = fields.Datetime(string="End Date", copy=False)
    # When `action_start` actually ran. `start_date` cannot say: an admin may
    # pre-set it, and launch keeps that scheduled time.
    launched_at = fields.Datetime(readonly=True, copy=False)

    evaluator_ids = fields.Many2many(
        "hr.applicant",
        "assessments_be_applicant_rel",
        "assessment_id",
        "applicant_id",
        string="Candidates",
    )
    assessment_evaluator_ids = fields.One2many(
        "assessments.be.evaluator", "assessment_id",
        string="Candidate Assignments"
    )
    response_ids = fields.One2many(
        "assessments.be.response", "assessment_id", string="Responses"
    )
    # NOT STORED, and that is a concurrency fix rather than a preference.
    #
    # THE DEFECT, measured on stage. This was `store=True` with
    # `@api.depends("response_ids")`, so EVERY answer any candidate saved
    # recomputed it and issued an `UPDATE assessments_be SET response_count`
    # against the ONE row the whole cohort shares. Postgres serialises those, and
    # Odoo's `retrying()` gives up after 5 attempts with an exponential backoff of
    # `random.uniform(0, 2**i)` - so a losing request slept up to ~30s and then
    # answered HTTP 500 `psycopg2.errors.SerializationFailure`.
    #
    # What that cost, from three runs against the deployed stage build:
    #
    #     3 candidates    0 of 3 failed     median 35 answers each
    #    25 candidates   12 of 25 failed    median 32
    #   100 candidates   82 of 100 failed   median  5      922 failures on
    #                                                      THIS column alone
    #
    # A candidate lost their answers mid-exam so an admin list could show a
    # counter. Read-only latency was untouched throughout (`/state` p99 792 ms
    # against `/answer` p99 22.7 s), which is what identifies it as write
    # contention on a shared row rather than saturation.
    #
    # SAFE TO UNSTORE because nothing searches, sorts or groups on it: the only
    # readers are `serializers.assessment_row` and three read-only view fields.
    # A non-stored compute costs one COUNT per record read instead of an UPDATE
    # per answer written, and the write is the one on the candidate's hot path.
    response_count = fields.Integer(compute="_compute_response_count")
    submitted_count = fields.Integer(
        string="Submitted", compute="_compute_release_state",
        help="Candidates who have submitted their attempt.")
    awaiting_scoring_count = fields.Integer(
        string="Awaiting Subjective Scoring", compute="_compute_release_state",
        help="Submitted candidates with subjective answers not yet graded.")
    # What Retry Failed Scoring would re-queue; it gates that button.
    scoring_failed_count = fields.Integer(
        string="Failed Scoring", compute="_compute_scoring_failed_count",
        help="Submitted candidates whose subjective grading failed, partly "
             "failed or errored.")
    releasable_count = fields.Integer(
        string="Releasable", compute="_compute_release_state",
        help="Submitted, scored candidates whose results are not yet "
             "released. One still waiting for the grader is not counted.")
    released_count = fields.Integer(
        string="Released", compute="_compute_release_state",
        help="Submitted candidates whose results have been released. "
             "Serialized on the list row so a client that holds no attempt "
             "records still reports this truthfully: counting it client-side "
             "renders 0 on a cold load of the assessment list, next to "
             "submitted/assigned counts that came from here.")
    release_label = fields.Char(
        compute="_compute_release_state", string="Release Button Label",
        help="\"Release N result(s)\" - the count Flutter puts on its own "
             "release button, for the header button to render.")
    invite_summary = fields.Char(
        compute="_compute_invite_summary", string="Invitations",
        help="Live status of the background invitation-send job.")

    # ── What the operator can see about a scoring run, while it runs ────────
    #
    # `awaiting_scoring_count` is WORK REMAINING, and it was being read as A
    # RUN IN FLIGHT. The Kill button was gated on `awaiting_scoring_count == 0`
    # (`views/assessment_views.xml`), so it stayed on screen for a cohort that
    # had never been queued, for one whose candidates an earlier kill had
    # already parked in `cancelled`, and for one whose grading had errored out:
    # every case where there is demonstrably nothing to stop. Pressing it then
    # posted "0 candidate(s) were still queued" to the chatter, which is the
    # button reporting its own irrelevance after the operator had already acted
    # on it. Two different questions had been collapsed onto one number.
    #
    # The honest question is the DRAINER'S OWN SELECTION PREDICATE
    # (`_scoring_shard_evaluators`): a candidate belongs to this run when it is
    # submitted, `scoring_requested`, and its `llm_state` is one the cron still
    # picks up. `scoring` on top of that means a worker is holding the row and
    # money is on the wire, which is the same test `action_kill_scoring` makes
    # before it decides whether to leave the kill flag raised. So the phase is
    # derived from the predicates that already govern the run rather than from
    # a fourth opinion about it.
    #
    # ONE SELECTION, THREE SURFACES. The Odoo header, the REST serializer and
    # the Flutter console all need the same answer, and three hand-rolled
    # conditions would drift the moment one of them was edited. `invite_summary`
    # beside this is the same pattern for the invitation job, down to the
    # ordering rule in `_compute_invite_summary`, so this is that shape reused
    # rather than a new one invented.
    scoring_phase = fields.Selection(
        [
            ("idle", "Not Scoring"),
            ("queued", "Queued"),
            ("scoring", "Scoring"),
            ("stopping", "Stopping"),
            # QUEUED BUT NOTHING IS DRAINING IT, which is the failure that hid
            # for six hours on 2026-09-03: all four `_cron_llm_auto_score`
            # records sat inactive with `nextcall` frozen, 1,948 answers
            # queued, 6 scored. A growing queue is indistinguishable from a
            # busy one, so 'Queued' would have been a true and completely
            # misleading badge for the whole outage.
            ("stalled", "Grader Not Running"),
        ],
        compute="_compute_scoring_progress", string="Scoring",
        help="Live phase of this assessment's subjective grading run. "
             "Queued = candidates are waiting for the background grader. "
             "Scoring = it is calling the model right now. "
             "Stopping = a kill was requested and the lane in flight will "
             "refuse its next call. Grader Not Running = work is queued but "
             "nothing is grading it: a scoring cron is inactive or overdue, "
             "or a grading lane has stored nothing in 15 minutes (the "
             "console's grader banner names which). Anything else is Not "
             "Scoring, and there is nothing to stop.")
    scoring_summary = fields.Char(
        compute="_compute_scoring_progress", string="Scoring Progress",
        help="Live tally of the subjective grading run - the scoring twin of "
             "Invitations.")
    # WHAT THE FINISHED-RUN LINE REPORTS: "Scored 400/650 candidates on Sep 21,
    # 2026 at 10:04pm". Idle: the live tally over submitted attempts, the time
    # being the latest `llm_scored_at`. While a run is live: the tally saved
    # when it started (`_remember_scoring_tally`), so the last finished result
    # stays on screen and changes only when this run ends.
    scoring_last_scored = fields.Integer(copy=False, readonly=True)
    scoring_last_candidates = fields.Integer(copy=False, readonly=True)
    scoring_last_finished_at = fields.Datetime(copy=False, readonly=True)
    scoring_scored_count = fields.Integer(
        compute="_compute_scoring_progress", string="Candidates Scored")
    scoring_candidate_count = fields.Integer(
        compute="_compute_scoring_progress", string="Candidates Submitted")
    scoring_finished_at = fields.Datetime(
        compute="_compute_scoring_progress", string="Scoring Finished At")

    rule_block_tab_switch = fields.Boolean(
        string="Blur on Tab/Window Switch", default=True,
        help="Blur assessment content when the candidate switches tabs.")
    rule_block_copy_paste = fields.Boolean(
        string="Block Copy / Paste", default=True)
    rule_block_right_click = fields.Boolean(
        string="Block Right-Click", default=True)
    rule_block_devtools = fields.Boolean(
        string="Block Developer Tools", default=True)
    rule_watermark = fields.Boolean(
        string="Watermark Content", default=True,
        help="Overlay the candidate's identity (name + email) faintly across "
             "the exam page to deter screenshots/photos of the questions.")
    rule_fullscreen = fields.Boolean(
        string="Require Fullscreen", default=True,
        help="Prompt the candidate into fullscreen when the exam opens; "
             "leaving fullscreen raises a proctoring violation.")
    rule_webcam = fields.Boolean(
        string="Require Webcam", default=False,
        help="Ask for webcam access when the exam opens; denying or losing "
             "the camera raises a proctoring violation.")
    # Runs in the candidate's browser (face and phone detection on the webcam
    # feed); the server only hands out the S3 upload policy for the snapshots
    # (`services/evidence.py`) and lists them back for the admin.
    rule_ai_proctor = fields.Boolean(
        string="AI proctoring (face and phone detection, camera snapshots)",
        default=False,
        help="Needs Require Webcam. The exam page watches the camera for no "
             "face, more than one face, the candidate leaving the frame and "
             "a phone in view. Each one is logged as a violation starting "
             "'AI: ' and a camera snapshot is kept as evidence on the "
             "attempt.")
    # Review-only pilot (owner, 7 Oct), OFF FOR GOOD (19 Oct): on stage it
    # never recorded a flag. Kept for the papers that still hold it, but
    # nothing reads it: no runner is told to run it (`proctoring_rules`),
    # `/review-flag` refuses, the API no longer writes it and the form hides it.
    rule_gaze_review = fields.Boolean(
        string="Eye movement (review only)",
        default=False,
        help="Needs AI proctoring. Looking well away from the screen three "
             "times within a minute raises a review flag with a camera "
             "snapshot. A review flag never counts as a violation, never "
             "ends the exam and is not shown to the candidate.")
    # Locked mode (ETP_PLANS_AND_STRATEGY.md Part 11). Enforced on the server
    # (`_seb_blocks` in controllers/api/candidate.py), not only in the app: a
    # browser that is not SEB gets the `seb_required` gate and no questions.
    rule_require_seb = fields.Boolean(
        string="Require Safe Exam Browser", default=False,
        help="The exam opens only in Safe Exam Browser (free, for Windows and "
             "macOS), which keeps the computer locked to the exam until the "
             "candidate submits. In any other browser the candidate gets an "
             "Open in Safe Exam Browser link instead of the questions.")
    # Admin only, here as on the API: the read-only Manager can open the form.
    seb_quit_password = fields.Char(
        string="Safe Exam Browser Quit Password", copy=False,
        groups="assessments_be_v2.group_assessment_manager",
        default=lambda self: seb.new_quit_password(),
        help="Invigilators type this to close Safe Exam Browser before the "
             "candidate submits. Changing it while candidates are inside Safe "
             "Exam Browser makes them reopen the exam from the link.")
    # THESE TWO HELP STRINGS STATE THE RULE THE RUNNER ENFORCES
    # (controllers/api/candidate.py `_record_violation`), because an operator
    # configuring proctoring reads THIS, not the controller. The owner's rule
    # (A-074, clarified 2026-09-24): "Log violations captures violations, lists
    # them but never end the paper. Auto-submit ends the paper upon breaching
    # number of violations. For both these modes default value is 5." Final
    # rule (24 Sep): Auto-submit ends the paper at the limit, Log only never
    # does, even at the limit. In BOTH modes a reached limit shows the
    # 'Violation Limit Breached' label (`violation_limit_breached` on the
    # attempt), which is how the admin and the candidate are told why.
    #
    # Log only + 5 for NEW papers only (owner, 24 Sep: "Both Flutter form and
    # Odoo form should start with Log only and 5 violations"): a field default
    # never rewrites a row that already exists, so papers made before keep
    # whatever they were saved with.
    max_violations = fields.Integer(
        string="Violation Limit", default=5,
        help="The violation limit, 5 unless you change it. Auto-submit: the "
             "exam ends when the count reaches it (0 ends it on the first "
             "violation). Log violation only: the exam is never ended, and 0 "
             "means no limit. In both modes, reaching the limit marks the "
             "attempt 'Violation limit breached' for you and for the "
             "candidate.",
    )
    violation_action = fields.Selection(
        [("auto_submit", "Auto-submit assessment"),
         ("log_only", "Log violation only")],
        string="On Violation", default="log_only", required=True,
        help="Auto-submit assessment = end the exam when the Violation Limit "
             "is reached (on the first violation when that is 0) and mark "
             "the attempt 'Violation limit breached'. Log violation only = "
             "record and list every violation and never end the exam; "
             "reaching the Violation Limit only shows 'Violation limit "
             "breached'.",
    )
    # THE SAME RULE, FOR "AI: " VIOLATIONS ONLY (R5). The camera's rules count
    # on their own pair so a misread face cannot spend the regular limit, and
    # each kind ends or labels the sitting by its own limit and mode. The
    # 19.0.3.28.0 upgrade starts every existing paper from its regular pair.
    ai_max_violations = fields.Integer(
        string="AI Violation Limit", default=5,
        help="The same rule as the Violation Limit, for AI proctoring "
             "violations only (no face, more than one face, leaving the frame, "
             "a phone). They are counted apart from the other violations.",
    )
    # NOT required: a pod still on the old code after -u (rolling deploy)
    # creates papers without it, and NOT NULL would refuse them. Every reader
    # takes an empty mode as Log only.
    ai_violation_action = fields.Selection(
        [("auto_submit", "Auto-submit assessment"),
         ("log_only", "Log violation only")],
        string="On AI Violation", default="log_only",
        help="Auto-submit assessment = end the exam when the AI Violation "
             "Limit is reached. Log violation only = record and list every AI "
             "violation and never end the exam for them.",
    )

    # A Python check, not a SQL CHECK: rows saved negative before it existed
    # (etp_local held 3 on 2026-09-25) would stop the CHECK being added on
    # upgrade, silently. Those rows read as 0 (`_compute_violation_limit_breached`).
    @api.constrains("max_violations", "ai_max_violations")
    def _check_max_violations(self):
        if any(rec.max_violations < 0 for rec in self):
            raise ValidationError("The violation limit cannot be negative.")
        if any(rec.ai_max_violations < 0 for rec in self):
            raise ValidationError("The AI violation limit cannot be negative.")

    # An empty password hashes to a real hash, and SEB would then quit for
    # anyone who presses Quit and Enter.
    @api.constrains("rule_require_seb", "seb_quit_password")
    def _check_seb_quit_password(self):
        if any(rec.rule_require_seb and not (rec.seb_quit_password or "").strip()
               for rec in self):
            raise ValidationError(
                "Safe Exam Browser needs a quit password for the invigilators.")

    def _refuse_short_quit_password(self):
        """A short password is guessed from the hash in the public .seb, so
        with SEB on one an admin types needs 12 characters. With SEB off it is
        unused, so turning SEB off never fails.

        Called by `create` and `write` only for papers whose password is new
        to SEB - changed, or SEB just turned on - never as a constraint: older
        apps save the whole settings object, and a paper still holding an
        older short password then refused every save, mid-sitting too, where
        the password cannot be changed."""
        if any(rec.rule_require_seb
               and len((rec.seb_quit_password or "").strip()) < 12
               for rec in self.sudo()):
            raise ValidationError(
                "The Safe Exam Browser quit password needs at least 12 "
                "characters.")

    def _quit_password_locked_by(self):
        """Why the quit password cannot change now, or "".

        Every .seb a candidate downloaded carries the current password's hash,
        so a new one strands anyone mid-attempt (`_sitting_count`).
        The one rule for `/regenerate` and for any write (the Odoo form)."""
        sitting = self._sitting_count()
        return ("%d candidate(s) are sitting this paper. Their Safe Exam "
                "Browser only quits with the current password, so it can be "
                "changed once they have submitted." % sitting) if sitting else ""

    def _sitting_count(self):
        """How many candidates are mid-attempt: in progress and not locked."""
        self.ensure_one()
        return self.env["assessments.be.evaluator"].sudo().search_count([
            ("assessment_id", "=", self.id), ("state", "=", "in_progress"),
            ("is_locked", "=", False)])

    # The AI rules read the webcam feed, so without the camera they would
    # watch nothing and log nothing while the operator believes they are on.
    @api.constrains("rule_ai_proctor", "rule_webcam")
    def _check_ai_proctor_needs_webcam(self):
        if any(rec.rule_ai_proctor and not rec.rule_webcam for rec in self):
            raise ValidationError(
                "AI proctoring needs Require Webcam. Turn on Require Webcam, "
                "or turn off AI proctoring.")

    # Turning Require Webcam off on the form turns AI proctoring off in the
    # same save, so the constraint above never refuses it.
    @api.onchange("rule_webcam")
    def _onchange_rule_webcam_off(self):
        if not self.rule_webcam:
            self.rule_ai_proctor = False
    # FLUTTER'S NAME AND FLUTTER'S SENTENCE: the two consoles configure one
    # system, so both must read as one setting. What the old help added and
    # what is still true:
    # a queued candidate is batched in 20s by the scoring cron and never scored
    # inline during the exam, and the by-hand route is the 'Run Subjective
    # Evaluation' button. The default already agrees with the Flutter create
    # screen (`_autoScore = false`), so nothing moves here.
    llm_auto_score = fields.Boolean(
        string="Grade subjective answers automatically", default=False,
        help="On, a submit queues the candidate for the background grader. "
             "Off, nothing is graded until someone runs it by hand - and "
             "nothing tells you it is waiting.")
    require_reviewed_rubric = fields.Boolean(
        string="Require Reviewed Rubric Before Launch", default=False,
        help="GOVERNANCE: when on, the assessment refuses to launch until every "
             "subjective question it would serve has its 'Rubric Reviewed' flag "
             "set - a human has signed off the AI-authored grading key. Off "
             "(default) preserves today's behaviour. Turn on for a defensible "
             "hiring gate where no candidate is graded by an unreviewed rubric.")

    # ── The scoring kill switch ─────────────────────────────────────────────
    #
    # THE SAME COOPERATIVE-CANCEL DESIGN AS SOP GENERATION, one level down. LLM
    # scoring runs inside a cron worker (`_cron_llm_auto_score`), not a job this
    # request can signal, so a Kill cannot stop a thread - it raises this flag
    # and commits, and every grading lane reads it back before its next billable
    # call (`services/vertex._check_scoring_cancelled`) and refuses. One flag on
    # the assessment stops every candidate being graded under it, without each
    # lane growing its own interrupt. The handle is the ASSESSMENT: a scoring
    # `usage_ctx` carries `evaluator_id`, and the checkpoint resolves that to its
    # assessment on a fresh cursor, so a kill on one assessment never touches a
    # different one being scored at the same time.
    #
    # WHAT IT CANNOT DO: the single Vertex call already in flight when Kill is
    # pressed completes and is billed. Every call after it is refused. Scores
    # already stored are kept - a kill never unwinds a mark. That is the honest
    # boundary, identical to the generator's.
    scoring_cancel_requested = fields.Boolean(
        string="Scoring Cancellation Requested", default=False, copy=False,
        help="Set by Kill Scoring. Every grading lane belonging to THIS "
             "assessment refuses its next LLM call while this is on, so a "
             "scoring run stops spending within one call rather than at the end "
             "of the batch. The one call already in flight finishes and is "
             "billed; scores already stored are kept.")
    scoring_cancelled_at = fields.Datetime(
        string="Scoring Cancelled At", readonly=True, copy=False)

    candidate_csv_file = fields.Binary(string="Upload Candidates CSV")
    candidate_csv_filename = fields.Char(string="CSV Filename")

    def write(self, vals):
        # ARCHIVING IS A SUSPEND, AND THAT IS A CHANGE OF CONTRACT.
        #
        # `active` used to be pure visibility - "the row leaves the list and
        # nothing else moves". It cost real money: `_cron_llm_auto_score`
        # searches `assessments.be.evaluator`, which has no `active` of its own
        # (the only one in this file is on the assessment, below), so Odoo's
        # `active_test` never reached it and an archived paper kept being
        # graded and kept spending. Archive now STOPS the cost-intensive and
        # queued work, reversibly.
        #
        # ON THE MODEL AND NOT ONLY ON THE API ROUTE, because the Odoo
        # back-office Archive action writes this field directly and would
        # otherwise be a second archive that does not suspend - the same split
        # brain the dashboard already had over archived cohorts.
        #
        # NOTHING IS SNAPSHOTTED. The crons select work by reading live columns
        # (`scoring_requested`, `llm_state`, `invite_state`,
        # `threshold_recompute_pending`) and now skip archived assessments, so
        # the queue is neither drained nor destroyed - it sits exactly as it
        # was. The untouched rows ARE the saved state, and unarchiving resumes
        # from them with no replay step. A snapshot field would be a second
        # source of truth for the same fact, free to drift from it.
        self._refuse_bad_pass_threshold(vals)
        new_to_seb = self.browse()
        if "seb_quit_password" in vals:
            new_to_seb = self.filtered(lambda a: (a.seb_quit_password or "")
                                       != (vals["seb_quit_password"] or ""))
            for paper in new_to_seb:
                locked_by = paper._quit_password_locked_by()
                if locked_by:
                    raise UserError(locked_by)
        if vals.get("rule_require_seb"):
            turning_on = self.filtered(lambda a: not a.rule_require_seb)
            # Turning SEB on mid-sitting would gate candidates already
            # answering in a normal browser, clock running. Off stays allowed:
            # it is the way out of a lockout.
            for paper in turning_on:
                sitting = paper._sitting_count()
                if sitting:
                    raise SittingRefused(
                        "%d candidate(s) are sitting this paper in a normal "
                        "browser. Turning on Safe Exam Browser now would stop "
                        "them mid-exam, so it can be turned on once they have "
                        "submitted." % sitting)
            new_to_seb |= turning_on
        suspending = resuming = self.browse()
        if "active" in vals:
            going_active = bool(vals["active"])
            suspending = self.filtered(
                lambda a: a.active and not going_active)
            resuming = self.filtered(lambda a: not a.active and going_active)
        res = super().write(vals)
        new_to_seb._refuse_short_quit_password()
        # AFTER the super() call, so a write that Odoo refuses (access rules,
        # a constraint) has not already raised a cancel flag on a row that
        # never moved.
        if suspending:
            suspending._suspend_scoring_for_archive()
        if resuming:
            resuming._resume_scoring_from_archive()
        if {"subjective_threshold", "pass_threshold",
                "transcription_threshold"} & set(vals):
            for a in self:
                if not a.assessment_evaluator_ids:
                    continue
                # DEFER WHILE A LANE IS GRADING. The inline recompute rewrites
                # up to 500 needs_llm answers in this web request, including
                # rows a lane is holding mid-call - the commit then hands that
                # lane a SerializationFailure and its paid results are rolled
                # back and bought again. `threshold_recompute_pending` is the
                # existing answer for "too big to do here" and works just as
                # well for "not mine to touch right now":
                # `_cron_recompute_subjective_results` picks the paper up on
                # its next tick, after the lane has let go.
                if (len(a.response_ids.filtered("needs_llm")) > 500
                        or a.assessment_evaluator_ids._being_graded()):
                    a.threshold_recompute_pending = True
                else:
                    a._recompute_subjective_results()
        return res

    def _suspend_scoring_for_archive(self):
        """Stop the spending an archive cannot reach with a domain, reversibly.

        THE ONE THING A PREDICATE CANNOT STOP. Skipping archived assessments in
        the cron domains stops every candidate the drainer has not started.
        It cannot reach the one candidate a worker is holding right now, whose
        Vertex call is already on the wire: that row was selected before the
        archive and the money is out of our hands.

        The cooperative handshake for exactly that already exists and is
        REUSED, not re-implemented: `scoring_cancel_requested` is raised here
        and read back by the grading lane on a fresh cursor before its NEXT
        billable call (`services/vertex._check_scoring_cancelled`), which then
        refuses. The flag is deliberately NOT cleared again in this
        transaction - `action_kill_scoring`'s docstring records the bug where
        doing so committed the column back down and let the in-flight lane
        carry on spending. It is lowered by `_resume_scoring_from_archive`.

        WHAT THIS DELIBERATELY DOES NOT DO is settle the queue. The kill parks
        what it stops as `llm_state = "cancelled"`, which is terminal and
        lossy - after it you cannot tell a candidate who was `pending` from one
        who was `failed`, so there is nothing faithful to resume to. Archive
        must be perfectly reversible, so `scoring_requested`, `llm_state`,
        `invite_state` and `threshold_recompute_pending` are left exactly as
        they are on every row.

        The one billable call already in flight completes and is billed. That
        is the same honest boundary the kill switch states, and it is
        unavoidable from this side of the wire.
        """
        # Only the assessments whose flag is actually down, so archiving does
        # not re-stamp `scoring_cancelled_at` on a paper an admin had already
        # killed - the timestamp answers "when was spending stopped", and the
        # kill stopped it.
        raise_it = self.filtered(lambda a: not a.scoring_cancel_requested)
        if raise_it:
            raise_it.write({
                "scoring_cancel_requested": True,
                "scoring_cancelled_at": fields.Datetime.now(),
            })

    def _resume_scoring_from_archive(self):
        """Put an unarchived assessment back in front of the crons.

        Lowering the flag is the whole of it, and that is the point of not
        having snapshotted anything. Every queued candidate still carries the
        `scoring_requested` / `llm_state` / `invite_state` it had when the
        paper was filed away, and the cron domains stop excluding it the
        moment `active` goes back to True - so a cohort that was mid-scoring
        comes back scoring the same candidates, from the same rows.

        NOTHING TO RE-ARM. The only row archiving could disturb is the one a
        worker was holding, and `_llm_score_guarded` parks that one back to
        `pending` with `scoring_requested` intact precisely so it is picked up
        again here rather than needing to be resurrected from `cancelled`. A
        row the worker never got to park is still sitting in `scoring`, which
        the drainer also selects. Either way the queue is already armed.

        Lowered directly, not through `_withdraw_scoring_kill`: that keeps the
        flag up while a lane holds a candidate, and a restored paper with the
        flag up reads as a Kill - the lane then parks its whole queue
        `cancelled` (R1-01). An archive is not a kill.
        """
        self.filtered("scoring_cancel_requested").write(
            {"scoring_cancel_requested": False})

    def action_archive(self):
        """The back-office Archive, refused while anybody is mid-exam.

        Mirrors `_live_attempt_refusal` in `controllers/api/write.py`: archiving
        does not pause a sitting or give time back, so a paper somebody is
        sitting is not filed away by a click. Only this entry point is guarded;
        the API route (with its `confirm_live_attempts`) and the Delete wizard
        (which names the live count first) write `active` directly.
        """
        live = self.assessment_evaluator_ids.filtered(
            lambda e: e.state == "in_progress")
        if live:
            raise UserError(
                "%d candidate(s) are sitting %s right now. Archiving does not "
                "pause their exam and does not give time back - each one is "
                "still submitted at their original deadline. Archive it once "
                "they have submitted."
                % (len(live), ", ".join(
                    live.mapped("assessment_id.name")) or "this assessment"))
        return super().action_archive()

    def _is_archived_now(self):
        """Is this assessment archived RIGHT NOW, on a FRESH cursor?

        WHY NOT PLAIN `self.active`. The caller is a grading lane inside a cron
        worker, and the archive that concerns it was committed by a web worker
        after that cron's transaction opened. Odoo runs REPEATABLE READ, so the
        cron's own snapshot cannot see it and `self.active` would answer the
        question as it stood minutes ago - which is exactly the wrong answer,
        because the lane only asks after `_check_scoring_cancelled` has already
        told it something changed.

        Same shape and same reasoning as `vertex._scoring_cancelled`, including
        `_side_cursor_is_safe`: under the test runner the caller's cursor is
        used, because a TestCursor never really commits and a side cursor would
        miss the test's own fixtures. Failure answers False - "not archived" -
        so a hiccup reading one boolean degrades to today's behaviour instead
        of quietly re-arming a candidate an admin genuinely cancelled.
        """
        self.ensure_one()
        from ..services import vertex
        if not vertex._side_cursor_is_safe(self.env):
            return not self.active
        try:
            with self.env.registry.cursor() as cr:
                cr.execute(
                    'SELECT active FROM "%s" WHERE id = %%s' % self._table,
                    (self.id,))
                row = cr.fetchone()
            return bool(row) and not row[0]
        except Exception as exc:  # noqa: BLE001 - never block the lane over it
            _logger.warning(
                "Could not read the archive flag for assessment %s (%s); "
                "treating it as live.", self.id, exc)
            return False

    def _recompute_subjective_results(self, batch=500, commit=False):
        # Must stay batched: one transaction over all responses locks the whole
        # response table; commit=True releases locks between batches.
        subj_fields = ["llm_raw_score", "llm_passed", "llm_score", "llm_max_score"]
        for a in self:
            responses = a.response_ids.filtered("needs_llm")
            for i in range(0, len(responses), batch):
                chunk = responses[i:i + batch]
                chunk.invalidate_recordset(subj_fields)
                chunk._compute_subjective_marks()
                chunk.flush_recordset(subj_fields)
                if commit:
                    self.env.cr.commit()
            evs = a.assessment_evaluator_ids
            evs.invalidate_recordset(
                ["llm_total_score", "subjective_pending", "score_percent",
                 "pass_threshold", "result"])
            evs._compute_llm_progress()
            evs._compute_result()
            evs.flush_recordset()
            if a.threshold_recompute_pending:
                a.threshold_recompute_pending = False
            if commit:
                self.env.cr.commit()

    def _recompute_question_marks(self, batch=500, commit=False):
        """Force `_compute_final_marks` and every total built on it.

        FOR A CHANGE TO THE RULE ITSELF, not to the data. Odoo recomputes a
        stored compute when one of its DEPENDENCIES moves; editing the method
        body moves nothing, so every row already on disk keeps the number the
        old rule gave it and the database quietly holds two scoring rules at
        once. Worse, the stale rows are not stable: the next rescore or
        threshold edit touches a dependency and flips them one at a time.

        Returns the evaluators whose `result` changed, so a caller can report
        which attempts moved rather than recomputing in silence.

        Batched for the same reason `_recompute_subjective_results` is: one
        transaction over every response locks the whole response table, and
        commit=True releases those locks between chunks.
        """
        mark_fields = ["mcq_mark", "objective_marks_max", "final_mark",
                       "final_max", "raw_score", "raw_max"]
        ev_fields = ["score_percent", "pass_threshold", "result",
                     "score_marks_display", "raw_result", "raw_max",
                     "raw_percent"]
        moved = self.env["assessments.be.evaluator"]
        for a in self:
            evs = a.assessment_evaluator_ids
            # READ THE OLD VERDICTS FIRST, before a single response is touched.
            #
            # `result` is a stored compute over `response_ids.final_mark`, so
            # assigning a mark below queues it for recomputation and the commit
            # between batches performs it. Reading afterwards therefore reads
            # the NEW verdict as though it were the old one, every attempt
            # compares equal to itself, and the script reports that nothing
            # moved on the exact run that moved things.
            before = {ev.id: ev.result for ev in evs}
            responses = a.response_ids
            for i in range(0, len(responses), batch):
                chunk = responses[i:i + batch]
                chunk.invalidate_recordset(mark_fields)
                chunk._compute_final_marks()
                chunk.flush_recordset(mark_fields)
                if commit:
                    self.env.cr.commit()
            evs.invalidate_recordset(ev_fields)
            evs._compute_result()
            evs._compute_score_marks_display()
            evs._compute_raw_result()
            evs.flush_recordset(ev_fields)
            moved |= evs.filtered(lambda e: e.result != before.get(e.id))
            if commit:
                self.env.cr.commit()
        return moved

    #: A score saved while a check was running is committed after the check's
    #: snapshot, so "scored after the last check" looks back this far.
    OUTLIER_CHECK_OVERLAP = timedelta(minutes=10)
    #: When this code first ran. A paper never checked is stale only if its old
    #: flag is up or a candidate was scored after this - so the first run does
    #: not recompute (or write) every historical paper. Set by the first cron
    #: run, not by a migration.
    OUTLIER_CHECKS_SINCE_PARAM = "assessments_be_v2.score_outlier_checks_since"

    @api.model
    def _outlier_stale_papers(self, limit):
        """Papers whose outlier flags need the cohort pass: a candidate scored
        after the last check, a submitted candidate with answers back to
        grade written after it, or the old `score_outlier_stale` still up.

        Derived from the data rather than from a flag the grading lanes raise:
        that flag was a write on the one row every lane shares, and its
        collisions threw away paid grading calls (see `finish_evaluator`).
        Oldest check first, so a busy paper cannot starve the rest.

        LEAVING THE COHORT COUNTS TOO. `llm_scored_at` moves only when a
        candidate becomes fully scored; a forced re-grade sends a scored one
        back to pending (then scored or error), the cohort's mean and spread
        move, and a flag it carried stayed up. Such a candidate is submitted
        with `subjective_pending` > 0, and its row was written when that
        happened.
        """
        icp = self.env["ir.config_parameter"].sudo()
        since = icp.get_param(self.OUTLIER_CHECKS_SINCE_PARAM)
        if not since:
            since = fields.Datetime.to_string(fields.Datetime.now())
            icp.set_param(self.OUTLIER_CHECKS_SINCE_PARAM, since)
        self.env.flush_all()
        self.env.cr.execute("""
            SELECT a.id
              FROM assessments_be a
             WHERE a.active
               AND (a.score_outlier_stale OR EXISTS (
                    SELECT 1 FROM assessments_be_evaluator e
                     WHERE e.assessment_id = a.id
                       AND (e.llm_scored_at > COALESCE(
                                a.score_outlier_checked_at,
                                %(since)s::timestamp) - %(overlap)s
                            OR (e.state = 'submitted'
                                AND e.subjective_pending > 0
                                AND e.write_date > COALESCE(
                                    a.score_outlier_checked_at,
                                    %(since)s::timestamp) - %(overlap)s))))
             ORDER BY a.score_outlier_checked_at NULLS FIRST, a.id
             LIMIT %(limit)s
        """, {"since": since, "overlap": self.OUTLIER_CHECK_OVERLAP,
              "limit": limit})
        return self.browse([row[0] for row in self.env.cr.fetchall()])

    @api.model
    def _cron_recompute_subjective_results(self, limit=20, commit=True):
        # ALREADY SKIPS ARCHIVED ASSESSMENTS, AND BY ACCIDENT - which is worth
        # knowing before somebody "aligns" it with the three crons that carry
        # an explicit `assessment_id.active` term. This one searches
        # `assessments.be`, which HAS an `active` field, so Odoo's `active_test`
        # excludes archived rows for free. The others search
        # `assessments.be.evaluator`, which has none, so `active_test` has
        # nothing to act on and the predicate has to be written out. The
        # difference is the model being searched, not the intent.
        pending = self.search(
            [("threshold_recompute_pending", "=", True)], limit=limit)
        for a in pending:
            try:
                # `commit` threaded through rather than hard-coded True: the test
                # harness forbids `cr.commit()` inside a test, so a test that
                # exercises this cron could not reach the cohort pass below.
                a._recompute_subjective_results(commit=commit)
            except Exception:
                _logger.exception(
                    "Threshold recompute failed for assessment %s", a.id)

        # THE COHORT OUTLIER PASS, once per assessment rather than once per
        # candidate. See `score_outlier_stale` for why it moved here out of
        # `services.scoring`: run inline it shared a transaction - and a
        # savepoint - with the marks, so a collision on the cohort's rows
        # discarded the scores that had just been written.
        #
        # COMMIT PER ASSESSMENT, and clear the flag and stamp
        # `score_outlier_checked_at` in the same transaction as the recompute
        # they stand for. Doing it first would drop the request if the
        # recompute then failed; doing it after, in its own transaction, would
        # leave a paper permanently re-queued if the commit never came.
        stale = self._outlier_stale_papers(limit)
        for a in stale:
            try:
                with self.env.cr.savepoint():
                    checked_at = fields.Datetime.now()
                    a.assessment_evaluator_ids._recompute_cohort_outliers()
                    a.write({"score_outlier_stale": False,
                             "score_outlier_checked_at": checked_at})
                # GUARDED, like `_recompute_subjective_results(commit=...)` above.
                # Odoo's test harness forbids `cr.commit()` inside a test and
                # raises AssertionError on it, which would make every assertion
                # here pass or fail for the wrong reason. In the cron the commit
                # is what releases the cohort's row locks between assessments.
                if commit:
                    self.env.cr.commit()
            except Exception:                            # noqa: BLE001
                # The paper STAYS STALE (`score_outlier_checked_at` does not
                # move, a legacy flag stays up), so the next tick retries. A
                # statistic is allowed to be late; it is not allowed to take a
                # mark with it, and nothing here writes one.
                #
                # WHAT THE SAVEPOINT DOES AND DOES NOT DO HERE. For an ordinary
                # exception it unwinds this assessment's attempt and the loop
                # continues. For a Postgres SERIALIZATION failure it cannot -
                # that dooms the whole transaction, which is the entire lesson of
                # the bug this moved away from.
                #
                # It is safe anyway, and that is the point of moving it: this
                # transaction holds NO MARKS. The worst case is that the tick
                # ends early with the paper still stale, so the next tick
                # retries. No explicit `cr.rollback()`, which would also
                # discard the threshold recomputes committed earlier in this same
                # tick; Odoo's request/cron teardown handles a doomed cursor.
                _logger.exception(
                    "Cohort outlier recompute failed for assessment %s; the "
                    "flag stays set and no mark is affected", a.id)

        # THE COHORT CLOSE PASS. Same shape, same reasons - see
        # `cohort_close_stale`. `_auto_submit_expired` used to do this inline, on
        # the row the whole cohort shares, inside the transaction holding a
        # candidate's settlement; a collision there discarded the paper.
        #
        # ADDED TO THIS EXISTING CRON RATHER THAN A NEW ONE, deliberately. This
        # job already runs every minute and already owns exactly this
        # flag-drain-commit pattern, so there is no new cron record to ship - and
        # `data/cron.xml` is `noupdate="1"`, which makes every new cron record a
        # thing someone has to remember to check after an upgrade.
        # THE FLAG IS AN OPTIMISATION, NOT THE CORRECTNESS CONDITION.
        #
        # A design that closed ONLY flagged assessments would have a way to lose
        # a cohort forever: a settlement reads `cohort_close_stale` as True from a
        # stale ORM cache and skips setting it, the cron clears the flag in
        # between, and the last candidate's settlement never re-raises it - the
        # assessment then sits `in_progress` with everybody submitted, and no
        # later event ever revisits it. An operator would have to notice by hand.
        #
        # So the domain is the flag OR any still-open assessment. The flag
        # never changed WHICH papers a tick visits (same order, same limit),
        # so settlements no longer raise it; the flag term only drains rows
        # raised before that.
        # ponytail: `limit` papers per tick, newest first - with more open
        # papers than that, older finished ones wait; select closable papers
        # in SQL if that is ever seen. There are tens of
        # assessments, not thousands, so the sweep costs a bounded indexed read
        # and the expensive part - counting outstanding evaluators - only runs
        # per candidate assessment inside the loop.
        closing = self.search(
            ["|",
             ("cohort_close_stale", "=", True),
             ("state", "=", "in_progress")],
            limit=limit)
        for a in closing:
            try:
                with self.env.cr.savepoint():
                    # ONE grouped count, not a walk of every sibling row. The
                    # inline version loaded the whole cohort into Python on every
                    # settlement to compute one boolean.
                    Ev = self.env["assessments.be.evaluator"].sudo()
                    assigned = Ev.search_count([("assessment_id", "=", a.id)])
                    outstanding = Ev.search_count([
                        ("assessment_id", "=", a.id),
                        ("state", "!=", "submitted"),
                    ])
                    # `assigned` IS LOAD-BEARING, not a tidiness check.
                    #
                    # A live assessment with nobody assigned yet has
                    # outstanding == 0, so a bare `not outstanding` would flip a
                    # paper NOBODY HAS SAT straight to done - and the inline
                    # version this replaces was safe from that only by accident,
                    # because it ran from a settlement and a settlement implies an
                    # evaluator. Sweeping `in_progress` rows removes that
                    # accident, so the condition has to be explicit. This is the
                    # `if evs and ...` half of the original three lines, kept.
                    #
                    # Only ever DRIVES A CLOSE, never reopens: an assessment an
                    # operator has moved on from must not be dragged back to
                    # in_progress by a late settlement.
                    if assigned and not outstanding and a.state == "in_progress":
                        a.state = "done"
                    a.cohort_close_stale = False
                if commit:
                    self.env.cr.commit()
            except Exception:                                # noqa: BLE001
                # The flag stays set, so the next tick retries. Nothing in this
                # transaction holds a mark or a settlement - which is the whole
                # reason the work moved here.
                _logger.exception(
                    "Cohort close failed for assessment %s; the flag stays set "
                    "and no settlement is affected", a.id)

    @api.depends("response_ids")
    def _compute_response_count(self):
        """Counted with a GROUPED COUNT, not by loading the rows.

        `len(rec.response_ids)` reads every response of every assessment in the
        recordset into the cache to measure how many there are - on a 100-question
        paper sat by 250 people that is 25,000 records materialised to produce one
        integer per row. `_read_group` answers it in the database, in one query
        for the whole recordset.

        The `depends` stays: it is what invalidates the cached value when an
        answer is saved. Without `store=True` that invalidation is in-memory only
        and writes nothing, which is the entire point - see the field.
        """
        counts = dict(
            self.env["assessments.be.response"]._read_group(
                [("assessment_id", "in", self.ids)],
                groupby=["assessment_id"],
                aggregates=["__count"],
            )
        ) if self.ids else {}
        for rec in self:
            rec.response_count = counts.get(rec, 0)

    @api.depends(
        "assessment_evaluator_ids.state",
        "assessment_evaluator_ids.results_released",
        "assessment_evaluator_ids.response_ids.needs_llm",
        "assessment_evaluator_ids.response_ids.llm_state")
    def _compute_release_state(self):
        """Four counts, answered by GROUPED COUNTS rather than by loading rows.

        SAME CHANGE AS `_compute_response_count` SIX LINES ABOVE, and for the
        same reason - this one was simply missed. It walked
        `assessment_evaluator_ids` four times with `.filtered()`, and the fourth
        pass descended into `e.response_ids` per attempt, so reading these
        counts materialised every ATTEMPT and every ANSWER of every assessment
        in the recordset. On a 5,000-candidate cohort at 35 questions that is
        ~175,000 `Response` records loaded to produce four integers per row -
        and `/api/v1/analytics` reads these fields for up to 25 assessments
        (`analytics` in `api/admin.py`), so the route repointed to fix the
        console's arithmetic triggered the worst of it.

        Three queries now, whatever the recordset size: one for the submitted
        counts split by `results_released`, one for the held attempts that are
        scored (releasable), one for the attempts still holding an unscored
        subjective answer, and nothing per record.

        The `depends` is unchanged and still load-bearing: without `store=True`
        it is what invalidates the cached value when an attempt or an answer
        moves. See the note on `_compute_response_count`.
        """
        Evaluator = self.env["assessments.be.evaluator"]
        Response = self.env["assessments.be.response"]
        submitted = {}
        released = {}
        releasable = {}
        awaiting = {}
        if self.ids:
            # Submitted attempts, grouped by assessment AND by whether their
            # results are out - so one query answers all three of the first
            # three counts.
            for assessment, is_released, count in Evaluator._read_group(
                    [("assessment_id", "in", self.ids),
                     ("state", "=", "submitted")],
                    groupby=["assessment_id", "results_released"],
                    aggregates=["__count"]):
                submitted[assessment] = submitted.get(assessment, 0) + count
                if is_released:
                    released[assessment] = released.get(assessment, 0) + count
            # RELEASABLE MEANS SCORED. A held attempt whose written answer was
            # never graded has no result to release - counting it offered
            # "Release 1 result" for a `pending` one on a paper with grading
            # off. Same predicate as the roster's Scored chip.
            releasable = dict(Evaluator._read_group(
                [("assessment_id", "in", self.ids),
                 ("results_released", "=", False)]
                + Evaluator._answers_scored_domain(),
                groupby=["assessment_id"], aggregates=["__count"]))
            # Attempts with at least one subjective answer the judge has not
            # resolved. Grouped over RESPONSES and counted distinctly by
            # attempt, because the question is "how many attempts are waiting",
            # not "how many answers".
            #
            # `needs_llm` is store=True on the response, so it is usable in a
            # domain - a non-stored compute would have to be filtered in
            # Python and this conversion would not be possible.
            for assessment, evaluator, _count in Response._read_group(
                    [("assessment_id", "in", self.ids),
                     ("needs_llm", "=", True),
                     ("llm_state", "!=", "scored"),
                     ("assessment_evaluator_id.state", "=", "submitted")],
                    groupby=["assessment_id", "assessment_evaluator_id"],
                    aggregates=["__count"]):
                if evaluator:
                    awaiting.setdefault(assessment, set()).add(evaluator.id)
        for rec in self:
            total = submitted.get(rec, 0)
            out = released.get(rec, 0)
            rec.submitted_count = total
            rec.released_count = out
            rec.releasable_count = releasable.get(rec, 0)
            rec.awaiting_scoring_count = len(awaiting.get(rec, ()))
            # THE COUNT IS ON THE BUTTON, as the app's is. A header button's
            # `string=` is a static attribute, so the number has to arrive as a
            # field rendered inside the button.
            rec.release_label = (
                "Release %d result(s)" % rec.releasable_count
                if rec.releasable_count else "Release Results")

    @api.depends("assessment_evaluator_ids.invite_state")
    def _compute_invite_summary(self):
        """The invite tally, grouped in the database.

        Third of the three computes on this model that walked the attempt table
        in Python; the same conversion as `_compute_response_count` and
        `_compute_release_state` above. Three `.filtered()` passes over every
        attempt of every assessment in the recordset, to build one short string.

        One query now. `invite_state` is a plain stored Selection, so the group
        is direct.
        """
        Evaluator = self.env["assessments.be.evaluator"]
        by_assessment = {}
        if self.ids:
            for assessment, state, count in Evaluator._read_group(
                    [("assessment_id", "in", self.ids),
                     ("invite_state", "in", ("queued", "sent", "failed"))],
                    groupby=["assessment_id", "invite_state"],
                    aggregates=["__count"]):
                by_assessment.setdefault(assessment, {})[state] = count
        for rec in self:
            counts = by_assessment.get(rec, {})
            # Order is deliberate and unchanged: what is still to happen, then
            # what happened, then what went wrong.
            parts = ["%d %s" % (counts[state], state)
                     for state in ("queued", "sent", "failed")
                     if counts.get(state)]
            rec.invite_summary = "  ·  ".join(parts)

    #: See `_running_cron_ids`. A tick's longest silence is one Vertex call.
    LANE_LOCK_SILENCE_LIMIT = timedelta(minutes=60)

    @api.model
    def _running_cron_ids(self, crons):
        """The ids in ``crons`` whose grading lane is draining right now.

        A lane holds its shard's lock for the whole tick
        (`_cron_llm_auto_score`; a lease row in lease mode), and Odoo moves
        `nextcall` only when the tick ends - so a held lock is a tick still
        running, not an overdue cron.

        READ FROM `pg_locks` AND THE LEASE TABLE (`_held_cron_locks`), WHICH
        TAKES NO LOCK. Locking the cron rows
        instead makes a cron worker acquiring a job in that instant skip it
        (`_process_jobs_loop`: "being processed by another worker") until its
        next wake-up, up to a minute later - and every open scoring screen
        polls this.
        """
        shard_of = {cron.id: _cron_shard_index(cron.code) for cron in crons}
        live = self._live_lane_shards(set(shard_of.values()))
        return {cron_id for cron_id, shard in shard_of.items()
                if shard in live}

    @api.model
    def _live_lane_shards(self, shards):
        """Those of ``shards`` whose lane holds its lock right now - read by
        `_held_cron_locks`, as `_running_cron_ids` explains."""
        keys = {_lane_lock(shard): shard for shard in shards}
        return {keys[key] for key in self._held_cron_locks(keys)}

    @api.model
    def _held_cron_locks(self, keys):
        """Those of ``keys`` (cron lock keys, `services/locks.cron_lock`) some
        tick holds right now: a granted session advisory lock, or a live
        lease row in lease mode. Also read by the generation progress route
        (`controllers/api/admin._generation_progress`) for its crons' locks."""
        if not keys:
            return set()
        # A LOCK WHOSE SESSION HAS BEEN SILENT FAR LONGER THAN ANY TICK IS
        # NOT A TICK. The lock is session-level, so one leaked onto a pooled
        # connection (or held by a hung thread) would otherwise read as
        # "running" for ever and hide a dead grader. A live lane issues a
        # statement at least once per Vertex call.
        # A LIVE LEASE IS HELD THE SAME WAY, and a lapsed one is not: its own
        # expiry plays the silence limit's part. Advisory mode leaves the
        # table empty. One statement, so a poll pays no extra round trip.
        self.env.cr.execute("""
            SELECT (l.classid::bigint << 32) | l.objid::bigint
              FROM pg_locks l
              LEFT JOIN pg_stat_activity s ON s.pid = l.pid
             WHERE l.locktype = 'advisory' AND l.granted AND l.objsubid = 1
               AND l.database = (SELECT oid FROM pg_database
                                  WHERE datname = current_database())
               AND (s.state_change IS NULL
                    OR s.state_change > clock_timestamp() - %s)
            UNION
            SELECT key FROM assessments_be_cron_lease WHERE expires_at > now()
        """, [self.LANE_LOCK_SILENCE_LIMIT])
        return {row[0] for row in self.env.cr.fetchall()} & set(keys)

    @api.model
    def _scoring_drainer_health(self):
        """Is the thing that drains the scoring queue dead, overdue or not
        moving?

        ONE DEFINITION for the console's stalled-grader banner
        (`controllers/api/admin.scoring_pipeline`) and the Odoo header: two
        hand-rolled copies of "is the cron alive" is how the two surfaces come
        to disagree.

        `nextcall` rather than a heartbeat, because it is the authoritative
        thing: Odoo advances it every tick, so a value in the past means the
        record is not running whatever its `active` says.

        SCOPED BY MODEL, not by code alone. `etp_assessment_pro` is still
        installed and its crons call a method of the SAME NAME - the fork
        deliberately did not rename Python methods - so matching on `code`
        alone counts the decommissioned module's disabled records as evidence
        that OUR drainer is dead.

        Returns the counts too, because the route that renders this needs a
        sentence naming WHICH crons are wrong, and computing the verdict in one
        place and the evidence in another is the same divergence by a slower
        route.

        A verdict already in the context (`be_drainer_health`) is returned as
        is: `/api/v1/scoring` computes it for its payload and then reads the
        paper's phase, whose compute would otherwise ask a second time.
        """
        known = self.env.context.get("be_drainer_health")
        if known:
            return known
        drainers = self.env["ir.cron"].sudo().with_context(
            active_test=False).search([
                ("code", "like", "_cron_llm_auto_score"),
                ("model_id.model", "=", "assessments.be"),
            ])
        # ONLY THE SHARDS THAT ARE SUPPOSED TO RUN ARE EVIDENCE OF ANYTHING.
        # Shard 0 always runs; shards 1-3 ship active but return at their first
        # line until `scoring_shards` is raised, so an operator running one
        # shard switches the other three off - and `migrations/19.0.3.15.0`
        # says in as many words that it leaves `active` alone precisely because
        # that is a legitimate installed state. Counting every record flat made
        # ONE disabled higher shard enough to declare the grader dead at the
        # shipped default, which reads to the operator as "Grader Not Running"
        # on a paper shard 0 is draining perfectly normally - and 'stalled' is
        # terminal to the header badge, so the form then stops polling a run
        # that is very much alive. Both terms are scoped, not just `inactive`:
        # Odoo never advances `nextcall` on a disabled cron, so a shard
        # switched off an hour ago is frozen in the past and would trip
        # `overdue` for ever on its own.
        shards = self._scoring_shard_count()
        expected = drainers.filtered(
            lambda c: _cron_shard_index(c.code) < shards)
        now = fields.Datetime.now()
        # A TICK STILL RUNNING IS NOT OVERDUE. Odoo advances `nextcall` only
        # when a run ends, and one tick grades up to `scoring_tick_limit`
        # candidates - at ~45s a call, past fifteen minutes on the serial
        # drain - so a lane holding its lock is excluded.
        running = self._running_cron_ids(expected)
        overdue = expected.filtered(
            lambda c: c.id not in running and c.nextcall
            and c.nextcall < now - timedelta(minutes=15))
        inactive = expected.filtered(lambda c: not c.active)
        # A LANE THAT TICKS BUT MOVES NOTHING. Everything above reads the
        # cron, and a lane skipping on a held lock (shard 2, 2026-09-30, 14
        # minutes) still advances `nextcall` - so it read healthy. A shard
        # whose oldest queued row is past the same threshold, with nothing of
        # that shard stored or picked up since, is not moving whatever its
        # cron says. A lane holding its lock is NOT excused here: a live tick
        # stores a candidate every call.
        # ponytail: `write_date` stands in for "queued since". Usually that
        # flags a stuck lane late (any later write makes a row read younger),
        # but EARLY where rows enter the queue without a write of their own:
        # an unarchived paper's parked rows, or rows a `scoring_shards` change
        # deals to a lane that was idle. Such a shard reads stuck until its
        # lane's first pickup. "Stored" is `llm_scored_at`, so a lane whose
        # every call fails or is refused for 15 minutes reads blocked too. A
        # `queued_at` column and a per-lane heartbeat if it must be exact.
        cutoff = now - timedelta(minutes=15)
        stuck = {shard: queued for shard, (queued, oldest, moved)
                 in self._scoring_lane_counts(shards, cutoff).items()
                 if queued and oldest and oldest < cutoff and not moved}
        return {
            # A missing record is the worst case, not the healthiest: a shard
            # with no cron to drive it drains nobody, and `len(expected)` short
            # of `shards` is exactly that - which also covers having no drainer
            # record at all.
            "blocked": (len(expected) < shards) or bool(overdue)
                       or bool(inactive) or bool(stuck),
            # {shard: queued} for each lane that is not moving, so the console
            # banner can name it.
            "stuck": stuck,
            # The counts are the EVIDENCE for the verdict, so they count the
            # same records it does. `%d of %d grading cron(s) inactive` reading
            # "1 of 4" while one shard is configured told the operator to go
            # and re-enable three crons that are meant to be off.
            "total": len(expected),
            "inactive": len(inactive),
            "overdue": len(overdue),
        }

    @api.depends("assessment_evaluator_ids.llm_state",
                 "assessment_evaluator_ids.scoring_requested",
                 "assessment_evaluator_ids.state",
                 "assessment_evaluator_ids.response_ids.rescore_request_key",
                 "scoring_cancel_requested", "active")
    def _compute_scoring_progress(self):
        """Phase and tally of the subjective grading run, in one query.

        Same shape as `_compute_invite_summary` above and for the same reason:
        the tally is a group over the attempt table, so it is grouped in the
        database rather than walked in Python. At 711 attempts the `.filtered()`
        version reads the whole roster to build one short string, inside a
        request handler, every time the form is polled.

        `scoring_requested` is in the groupby because it is what separates
        "waiting for the grader" from "the grader is done with this row".
        `llm_state` alone cannot: its default is `pending`, so a candidate who
        was never queued at all is indistinguishable from one who is first in
        line. That default is exactly what made `awaiting_scoring_count` the
        wrong gate for the Kill button.
        """
        Evaluator = self.env["assessments.be.evaluator"]
        blocked = None  # resolved lazily, at most once per recordset
        tally = {}
        if self.ids:
            for assessment, llm_state, requested, count in \
                    Evaluator._read_group(
                        [("assessment_id", "in", self.ids),
                         ("state", "=", "submitted")],
                        groupby=["assessment_id", "llm_state",
                                 "scoring_requested"],
                        aggregates=["__count"]):
                tally.setdefault(assessment, {})[(llm_state, requested)] = count
        finished = dict(Evaluator._read_group(
            [("assessment_id", "in", self.ids), ("state", "=", "submitted"),
             ("llm_state", "=", "scored")],
            groupby=["assessment_id"],
            aggregates=["llm_scored_at:max"])) if self.ids else {}
        # A queued re-score is queued work too, whatever the candidate's own
        # state - except where it is already counted as queued or running.
        rescoring = dict(Evaluator._read_group(
            [("assessment_id", "in", self.ids), ("state", "=", "submitted"),
             ("response_ids.rescore_request_key", "!=", False),
             ("llm_state", "!=", "scoring"),
             "|", ("scoring_requested", "=", False),
             ("llm_state", "not in", ("pending", "partial", "failed"))],
            groupby=["assessment_id"],
            aggregates=["__count"])) if self.ids else {}
        # "Scored X/Y" counts by answers (`_answers_scored_domain`), so an
        # objective-only candidate - never graded, never `scored` - is scored.
        scored_by_answers = dict(Evaluator._read_group(
            [("assessment_id", "in", self.ids)]
            + Evaluator._answers_scored_domain(),
            groupby=["assessment_id"],
            aggregates=["__count"])) if self.ids else {}
        for rec in self:
            counts = tally.get(rec, {})

            def total(states, requested=None):
                return sum(n for (state, req), n in counts.items()
                           if state in states
                           and (requested is None or req == requested))

            # WAITING, and by the cron's definition of waiting. `pending`,
            # `partial` and `failed` are the states `_scoring_shard_evaluators`
            # still selects; `scoring` is excluded because it is counted as
            # running below rather than twice.
            queued = total(("pending", "partial", "failed"), requested=True) \
                + rescoring.get(rec, 0)
            # HOLDING A ROW RIGHT NOW. The state `action_kill_scoring` reads
            # to decide whether to leave the kill flag raised, so the badge and
            # the kill agree about what "in flight" means. Kill also asks
            # whether the row's lane is alive (`_being_graded`) and parks it
            # if not; a poll does not pay for that `pg_locks` read, so a dead
            # lane's row counts here until its lane is back or a Kill parks it.
            running = total(("scoring",))
            scored = total(("scored",))
            # NEEDS A HUMAN, which is narrower than "went wrong". A `failed`
            # candidate that Retry Failed Scoring has already re-queued is
            # counted in `queued` above; counting it here too would report one
            # candidate as "1 queued  ·  1 failed" and read as two. `error` is
            # terminal by design - the drainer never selects it and nothing
            # retries it automatically - so every one of those belongs here.
            broken = total(("failed",), requested=False) + total(("error",))
            stopped = total(("cancelled",))

            # ARCHIVED IS NOT RUNNING, and the drainer says so itself: its
            # domain opens with `assessment_id.active = True`. Deriving the
            # phase from the same predicate rather than making an exception
            # for archive keeps one definition, and it closes a real leak.
            # `_suspend_scoring_for_archive` raises `scoring_cancel_requested`
            # and leaves it raised for as long as the paper is filed away, so
            # without this the phase would read 'stopping' forever - and the
            # header badge polls while the phase is busy, which is a timer
            # that never settles on a record nobody is even grading. The
            # tally below is still computed, so an operator opening an
            # archived cohort still sees what is parked in it.
            if not rec.active:
                rec.scoring_phase = "idle"
            # STOPPING NEEDS SOMETHING LEFT TO STOP, so the flag alone will
            # not do. `action_kill_scoring` leaves `scoring_cancel_requested`
            # raised while a lane is mid-call, and the lane that consumes the
            # kill parks ITSELF (`_llm_score_guarded`'s VertexCancelledError
            # branch writes `cancelled` / `scoring_requested = False`) without
            # lowering it; `_clear_finished_scoring_kills` lowers it only when
            # the lane's tick ends. Read off the flag alone the phase would say
            # 'stopping' with nothing running and nothing queued: the Kill
            # button offering to stop a run that has already stopped, and the
            # header badge polling every 3s for a change that is not coming.
            # So the phase is derived from what is ACTUALLY in flight.
            elif rec.scoring_cancel_requested and (running or queued):
                rec.scoring_phase = "stopping"
            elif running:
                # A candidate on the wire is proof the drainer is alive, so
                # `scoring` outranks `stalled` without needing to ask.
                rec.scoring_phase = "scoring"
            # The lanes never grade a cancelled paper, so its queue never moves.
            elif queued and rec.state != "cancelled":
                # THE CRON QUERY IS PAID FOR ONLY BY A QUEUE. Asked on every
                # read it would be four indexed rows per poll for nothing, on
                # records where there is no queue to starve. `blocked` is a
                # fact about the installation, not about this paper, so it is
                # resolved once for the whole recordset.
                if blocked is None:
                    blocked = self._scoring_drainer_health()["blocked"]
                rec.scoring_phase = "stalled" if blocked else "queued"
            else:
                rec.scoring_phase = "idle"

            # Same ordering rule as the invitation summary: what is still to
            # happen, then what happened, then what went wrong.
            parts = [
                "%d queued" % queued if queued else "",
                "%d scoring" % running if running else "",
                "%d scored" % scored if scored else "",
                "%d failed" % broken if broken else "",
                "%d stopped" % stopped if stopped else "",
            ]
            rec.scoring_summary = "  ·  ".join(p for p in parts if p)
            live_at = finished.get(rec) or False
            saved_at = rec.scoring_last_finished_at
            # A saved tally older than the latest mark is stale: work queued
            # without a click (auto-score on submit) saves none (R2-05). A
            # forced re-grade resets marks, so the live count is shown only
            # once it has caught up.
            live_scored = scored_by_answers.get(rec, 0)
            if rec.scoring_phase == "idle" or not saved_at or (
                    live_at and live_at > saved_at
                    and live_scored >= rec.scoring_last_scored):
                rec.scoring_scored_count = live_scored
                rec.scoring_candidate_count = sum(counts.values())
                rec.scoring_finished_at = live_at
            else:
                rec.scoring_scored_count = rec.scoring_last_scored
                rec.scoring_candidate_count = rec.scoring_last_candidates
                rec.scoring_finished_at = rec.scoring_last_finished_at

    def _remember_scoring_tally(self):
        """Save the tally a new run is about to move, if the paper is idle.

        Called by every explicit request to score, before it queues anyone -
        from the web request that asked, never from a grading lane, so it adds
        no writer to the cohort row. A request while a run is already live
        keeps the tally from before that run.
        """
        self.invalidate_recordset([
            "scoring_phase", "scoring_scored_count",
            "scoring_candidate_count", "scoring_finished_at"])
        for rec in self.filtered(lambda a: a.scoring_phase == "idle"):
            vals = {
                "scoring_last_scored": rec.scoring_scored_count,
                "scoring_last_candidates": rec.scoring_candidate_count,
                "scoring_last_finished_at": rec.scoring_finished_at,
            }
            # Concurrent clicks on one paper collide on this row (G1-17).
            if any(rec[f] != v for f, v in vals.items()):
                rec.write(vals)

    def action_requeue_all_invitations(self):
        self.ensure_one()
        if self.state != "in_progress":
            raise UserError(
                "Invitations can only be resent while the assessment is in "
                "progress.")
        self.assessment_evaluator_ids.action_requeue_invitation()

    @api.depends("generator_id")
    def _compute_total_questions_available(self):
        # Mirrors action_start's domain exactly, retired included. This figure
        # is what the operator sizes "Number of Questions" against; counting
        # questions the launch will refuse to draw promises a paper it then
        # declines to build.
        #
        # ONE GROUPED COUNT for the whole recordset: the list route reads this
        # on every row, and a count per row was its N+1.
        generators = self.generator_id._origin
        counts = {}
        if generators:
            counts = {
                generator.id: count
                for generator, count in self.env[
                    "assessments.be.question"]._read_group(
                        [("generator_id", "in", generators.ids),
                         ("active", "=", True),
                         ("retired", "=", False)],
                        ["generator_id"], ["__count"])}
        for rec in self:
            rec.total_questions_available = counts.get(
                rec.generator_id._origin.id, 0)

    @api.constrains("question_limit")
    def _check_question_limit(self):
        for rec in self:
            if rec.question_limit < 0:
                raise ValidationError("Number of Questions cannot be negative.")

    @api.constrains("generator_id", "question_ids")
    def _check_shortlist_belongs_to_the_generator(self):
        """A shortlisted question must come from the generator it draws from.

        THE FAILURE THIS CLOSES, exactly as it happened. Sprint 3A pointed at
        generator 46 and carried a shortlist of 149-161, which belong to
        generator 47. `action_start` builds the pool from the generator and
        then narrows it by the shortlist, so the intersection was empty and the
        launch was refused - correctly, and far too late. The record had been
        in that state since somebody duplicated an assessment and changed its
        generator without touching the questions they had already ticked.

        The refusal had to happen at the write, where the operator is still
        looking at both fields and the mistake is one undo away. By launch day
        the person who made it is gone and the only way to see it is to read
        the database.

        AN EMPTY SHORTLIST IS VALID and must stay valid - it means "the whole
        generator" everywhere else in this module, and it is the normal case.
        No generator is valid too: there is nothing to disagree with yet.

        `active_test=False` because an archived question drops out of the m2m
        read, and a shortlist that reads shorter than it is would let a foreign
        archived question through the one check meant to catch it.

        NO `copy()` OVERRIDE GOES WITH THIS. A duplicate copies both fields
        together and is therefore consistent; the divergence only ever arrives
        by a later write, which is what this catches. Clearing the shortlist on
        copy would silently discard a selection the operator made rather than
        telling them about it.
        """
        for rec in self:
            if not rec.generator_id:
                continue
            shortlist = rec.with_context(active_test=False).question_ids
            if not shortlist:
                continue
            foreign = shortlist.filtered(
                lambda q: q.generator_id != rec.generator_id)
            if foreign:
                raise ValidationError(
                    "%d selected question(s) do not belong to \"%s\": %s.\n"
                    "Either pick a different generator or clear the selection "
                    "- an empty selection draws from the whole generator."
                    % (len(foreign), rec.generator_id.name or "this generator",
                       ", ".join(
                           "%s (#%d)" % (q.name or "untitled", q.id)
                           for q in foreign[:10])))

    @api.constrains("duration_minutes")
    def _check_duration_minutes(self):
        """Every assessment is timed, and the floor is two minutes.

        ZERO USED TO MEAN "NO LIMIT" and is no longer accepted. That is a
        product decision, not a tightened bound: an untimed sitting never gets
        a `deadline_datetime`, so `_cron_expire_stale_attempts` skips it by
        design and the attempt can never be swept, pinning the assessment in
        `in_progress` forever. One was launched and its candidates were emailed
        "Duration: 0 minutes".

        One minute is refused for the older reason: it is not a shorter exam,
        it is a mis-typed one. It auto-submits before a candidate has read the
        first question, and what it leaves behind is indistinguishable from
        somebody who gave up.

        THIS CONSTRAINT IS NOT ENOUGH ON ITS OWN. It fires on create, and on
        write only when the field is in the vals - and `action_start` writes
        `state`, `question_ids` and `start_date`, never the duration. So a
        legacy row at 0 could still be launched. The launch gate is what
        catches that; see `action_start` and `_launch_gates`.
        """
        for rec in self:
            if rec.duration_minutes < 2:
                raise ValidationError(
                    "Duration must be at least 2 minutes (got %s)."
                    % rec.duration_minutes)

    @api.constrains("subjective_threshold", "transcription_threshold")
    def _check_subjective_threshold(self):
        # M-11: reject an out-of-range pass bar at the WRITE path, not just via
        # the read-time clamp in _compute_result. A stored -50 / 250 silently
        # changed pass/fail semantics and hid the bad value.
        for rec in self:
            if not (0.0 <= rec.subjective_threshold <= 100.0):
                raise ValidationError(
                    "Subjective Pass Threshold must be between 0 and 100 "
                    "(got %s)." % rec.subjective_threshold)
            if not (0.0 <= rec.transcription_threshold <= 100.0):
                raise ValidationError(
                    "Transcription Pass Threshold must be between 0 and 100 "
                    "(got %s)." % rec.transcription_threshold)

    @api.constrains("start_date", "end_date")
    def _check_dates(self):
        for rec in self:
            if rec.start_date and rec.end_date and rec.start_date >= rec.end_date:
                raise ValidationError("End Date must be after Start Date.")

    def _dropped_shortlist_note(self, pool):
        """The ticked questions the launch `pool` left out, and why:
        ' Not servable: Q1 (no image), Q2 (retired) +K more.', or "" when
        nothing ticked dropped. One sentence for `action_start` and the launch
        gate alike."""
        self.ensure_one()
        dropped = self.with_context(active_test=False).question_ids - pool
        if not dropped:
            return ""
        names = ", ".join(
            "%s (%s)" % (q.name, q._unservable_reason()
                         or "not in this generator")
            for q in dropped[:10])
        more = " +%d more" % (len(dropped) - 10) if len(dropped) > 10 else ""
        return " Not servable: %s%s." % (names, more)

    def action_start(self):
        for rec in self:
            if rec.state != "draft":
                raise UserError("Only draft assessments can be started.")
            if not rec.active:
                raise UserError(
                    "This assessment is archived; restore it before "
                    "launching.")
            # CHECKED HERE, not only by the constraint, and FIRST because it is
            # the cheapest gate and the one that got through. `@api.constrains`
            # fires on write of the field, and this method writes `state`,
            # `question_ids` and `start_date` - never the duration. So a row
            # that predates the floor, or one written straight to the column,
            # would sail through launch and take its candidates with it. That
            # is not hypothetical: an assessment WAS launched at 0 and its
            # candidates were emailed "Duration: 0 minutes", because none of
            # the gates below looks at the clock. Mirrors the `duration` gate
            # in the API's `_launch_gates`, which reports the same thing.
            if rec.duration_minutes < 2:
                raise UserError(
                    "Duration must be at least 2 minutes before launching "
                    "(currently %s)." % rec.duration_minutes)
            if not rec.evaluator_ids:
                raise UserError("Please assign at least one candidate before starting.")
            if not rec.generator_id:
                raise UserError("Please select a question generator.")

            # THE ONE PLACE A PAPER IS DRAWN FROM THE BANK, so the one place
            # that must exclude retired questions. Retiring is the operator's
            # "delete" for a question history still points at; without this
            # clause the very next launch pulls it back out of the bank and
            # serves it to a fresh cohort.
            #
            # The asymmetry is deliberate: every read of an EXISTING paper
            # (question_ids, the candidate's frozen question_order, and
            # response.question_id during scoring) must keep resolving retired
            # questions. Filtering them there would shrink a paper already in
            # flight and silently rewrite scores recorded against it.
            available_questions = self.env["assessments.be.question"].search([
                ("generator_id", "=", rec.generator_id.id),
                ("active", "=", True),
                ("retired", "=", False),
            ]).filtered(
                lambda q: q._has_required_images() and q._has_required_videos())
            if not available_questions:
                raise UserError(
                    "No usable questions found for the selected generator. "
                    "Questions retired from the bank are not drawn into a new "
                    "assessment.")

            # THE DRAFT'S SHORTLIST NARROWS THE DRAW.
            #
            # `question_ids` on a DRAFT is the operator's shortlist - the
            # Selected Questions tab writes it, and it is empty until they
            # narrow something. This method used to overwrite it with the whole
            # servable pool a few lines below, so a shortlist of 5 out of 20 was
            # silently discarded and the cohort sat all 20. The narrowing has to
            # happen HERE, before the limit and the answer-key gates, so those
            # gates judge the paper being built rather than questions this
            # launch will never draw: a keyless question the operator had
            # already excluded used to block the launch outright.
            #
            # An empty shortlist still means "the whole generator" - see
            # `assessment_pool` in the API serializers, which reads it the same
            # way. The two must agree or the screen ticks one set and the launch
            # draws another.
            #
            # `active_test=False`, AND THE GUARD BELOW IS UNREACHABLE WITHOUT IT.
            # Odoo applies the active filter to an x2many READ, so archiving a
            # shortlisted question does not merely take it out of the shortlist -
            # it makes `question_ids` shorter, and archiving ALL of them makes it
            # read EMPTY. An empty shortlist means "the whole generator", so a
            # paper deliberately narrowed to two questions silently widened to
            # every question in the generator the moment somebody archived both -
            # which the bank's own Archive button does in one click.
            #
            # Measured, not reasoned: shortlist of 2, archive both,
            # `len(rec.question_ids)` goes 2 -> 0 while
            # `with_context(active_test=False)` still reads 2.
            #
            # Reading the operator's INTENT here keeps the set non-empty, so the
            # `if not narrowed` refusal below fires and says what to do about it.
            # The partial case is unchanged: some archived, some live, and the
            # live ones are what `narrowed` keeps.
            shortlist = set(
                rec.with_context(active_test=False).question_ids.ids)
            if shortlist:
                narrowed = available_questions.filtered(
                    lambda q: q.id in shortlist)
                if not narrowed:
                    raise UserError(
                        "None of the %d shortlisted question(s) is still "
                        "usable - they have been retired, deactivated, or have "
                        "lost the media their type requires. Open Selected "
                        "Questions and shortlist again, or clear the shortlist "
                        "to use the whole generator." % len(shortlist))
                available_questions = narrowed

            limit = rec.question_limit or len(available_questions)
            if limit > len(available_questions):
                raise UserError(
                    f"Requested {limit} questions but only "
                    f"{len(available_questions)} available in this generator."
                    + rec._dropped_shortlist_note(available_questions))

            # H-11 + M-13: refuse to start if any question would score 0 for
            # EVERY candidate (an authoring fault); surface it before candidates
            # sit, not after the results look wrong.
            #
            # THE RULE ITSELF LIVES ON THE QUESTION (`_keyless_reason`) so this
            # gate and the launch dry run behind
            # /api/v1/assessments/<id>/launch_check cannot drift - they had
            # already drifted once, and both used to ask only about
            # mcq/msq/image_ab, so all-unkeyed axes on any other type passed.
            keyless = available_questions.filtered(
                lambda q: q._keyless_reason())
            if keyless:
                raise UserError(
                    "%s question(s) would score 0 for every candidate. Fix "
                    "their answer key before starting:\n- %s" % (
                        len(keyless),
                        "\n- ".join(
                            "%s (%s)" % (q.name, q._keyless_reason())
                            for q in keyless[:10])))

            # A WARNING, NEVER A BLOCK - the same check as the API's
            # `grading_keys` gate. These answers are graded against the task
            # alone and flagged `no_answer_key`.
            from ..services import scoring as scoring_svc
            unkeyed = available_questions.filtered(scoring_svc.lacks_answer_key)
            if unkeyed:
                rec._log_activity(Markup(
                    "<b>Warning</b> - %d question(s) have no answer key; their "
                    "answers will be graded against the task alone and flagged "
                    "'no answer key': %s") % (
                        len(unkeyed), ", ".join(unkeyed.mapped("name")[:10])))

            # GOVERNANCE: refuse to launch while any subjective question still
            # has an unreviewed (AI-authored) rubric - a human must sign off
            # each grading key. Objective mcq/msq carry none and are exempt.
            if rec.require_reviewed_rubric:
                unreviewed = available_questions.filtered(
                    lambda q: q.has_subjective and not q.rubric_reviewed)
                if unreviewed:
                    raise UserError(
                        "%s subjective question(s) have an unreviewed rubric and "
                        "this assessment requires reviewed rubrics before launch. "
                        "Open each question, verify its grading key, and tick "
                        "'Rubric Reviewed':\n- %s" % (
                            len(unreviewed),
                            "\n- ".join(unreviewed.mapped("name")[:10])))

            # Papers made before 19.0.3.28.0 hold the old 48-bit password,
            # whose hash is in the public .seb. Nobody can be sitting before
            # launch, so this is the safe moment to renew it - and one typed
            # below the 12-character minimum. A typed one that meets the
            # minimum is kept: invigilators may already have it.
            if rec.rule_require_seb and seb.weak_quit_password(
                    rec.sudo().seb_quit_password):
                rec.sudo().seb_quit_password = seb.new_quit_password()

            all_question_ids = available_questions.ids
            rec.write({
                "question_ids": [(6, 0, all_question_ids)],
                "state": "in_progress",
                "start_date": rec.start_date or fields.Datetime.now(),
                "launched_at": fields.Datetime.now(),
            })

            # FAIRNESS: ONE shared draw, always, so every candidate faces the
            # same instrument; order is still shuffled per candidate - UNLESS
            # preserve_question_order says the author's own sequence IS the
            # instrument (Form Studio's sections), in which case a shuffle
            # would silently discard it. `same_questions_for_all` is retired
            # and no longer read (ETP_PLANS_AND_STRATEGY.md §4.3): the column stays
            # and no row is rewritten, every assessment simply draws as if on.
            shared_questions = (
                list(all_question_ids)[:limit]
                if rec.preserve_question_order
                else random.sample(all_question_ids, limit))
            # FILL THE ROSTER ROW, do not create a second one.
            #
            # `_sync_roster_rows` now gives every assigned candidate a row the
            # moment they are assigned, so by the time launch runs the row
            # usually exists already - carrying no question draw and
            # `invite_state = none`. This loop used to create unconditionally,
            # which collides with the (assessment_id, applicant_id) unique
            # index and answers the launch route a 500:
            #
            #   duplicate key value violates unique constraint
            #   "assessments_be_evaluator_uniq_assess_appl"
            #
            # Every draft whose candidates were assigned through the app was
            # therefore impossible to launch, and retrying could not help - the
            # blocking row is the one assignment itself wrote.
            #
            # The TOKEN IS KEPT when the row already has one. `access_token`
            # defaults to a fresh uuid at create, so a roster row is already
            # carrying the link `candidate_link` computes and the roster's
            # "Copy candidate link" hands out. Minting a new one here would
            # silently void a link an admin may already have sent on.
            Evaluator = self.env["assessments.be.evaluator"]
            roster = {
                e.applicant_id.id: e for e in rec.assessment_evaluator_ids
            }
            # BEFORE the draw, and in one pass, so a cohort that cannot be
            # provisioned is reported whole instead of one name per attempt.
            # See `_be_provision_candidates`.
            #
            # NOW SUDO, WHERE THE BARE CALL THIS REPLACED WAS NOT. Provisioning
            # creates a `res.users` and grants it a group; a Manager who may
            # launch an assessment has no reason to hold user-creation rights,
            # so the unprivileged call was an AccessError waiting for the first
            # launch by somebody who was not an administrator. `_sync_roster_rows`
            # had already reached the same conclusion and sudo'd its own call.
            # Stated here because it is a privilege boundary moving, not a
            # refactor: the gate on WHO may launch is unchanged and still sits
            # on the action.
            rec._be_provision_candidates(rec.evaluator_ids)
            for evaluator in rec.evaluator_ids:
                candidate_questions = list(shared_questions)
                if not rec.preserve_question_order:
                    random.shuffle(candidate_questions)
                vals = {
                    "question_order": json.dumps(candidate_questions),
                    "invite_state": "queued",
                }
                existing = roster.get(evaluator.id)
                if existing:
                    if not existing.access_token:
                        vals["access_token"] = str(uuid.uuid4())
                    existing.write(vals)
                else:
                    Evaluator.create({
                        "assessment_id": rec.id,
                        "applicant_id": evaluator.id,
                        "access_token": str(uuid.uuid4()),
                        **vals,
                    })
            rec._log_activity(Markup(
                "<b>Launched &amp; Invited</b> - assessment started with %d "
                "candidate(s), %d question(s) each from generator '%s'.")
                % (len(rec.evaluator_ids), limit,
                   escape(rec.generator_id.name or "")))
            # WARM THE QUESTION CACHE, so a cohort starting together does not
            # all build the same questions from Postgres at once. Best effort:
            # a cache problem never fails the launch. No-op without Redis.
            from ..controllers.api.serializers import warm_question_cache
            warm_question_cache(self.env["assessments.be.question"].browse(
                shared_questions))

    def action_done(self):
        for rec in self:
            if rec.state != "in_progress":
                raise UserError("Only in-progress assessments can be marked done.")
        self.write({"state": "done"})
        self._log_activity(Markup("<b>Marked Done</b> - assessment closed."))

    def action_cancel(self):
        for rec in self:
            if rec.state in ("done", "cancelled"):
                raise UserError(
                    "Cannot cancel a completed or already cancelled assessment.")
        self.write({"state": "cancelled"})
        self._park_unheld_scoring({
            "llm_state": "cancelled",
            "llm_error": "Grading stopped: the assessment was cancelled."})
        self._log_activity(Markup(
            "<b>Cancelled</b> - candidates can no longer take this assessment."))

    def _park_unheld_scoring(self, vals):
        """Write ``vals`` on this paper's `scoring` rows no running lane holds.

        Such a row was left by a lane that died, and once the paper is
        cancelled no lane selects it again: it would read as grading for ever
        and hold the deploy gate shut (`lanes.scoring`). A row a live lane
        holds is left to that lane (`_being_graded`)."""
        rows = self.assessment_evaluator_ids.filtered(
            lambda ev: ev.llm_state == "scoring")
        (rows - rows._being_graded()).write(vals)

    def action_reset_draft(self):
        """``confirm_released`` in the context says the caller means to erase
        results candidates can already see; without it such a paper is
        refused (`released_results`, 409) and nothing is deleted (A-040)."""
        for rec in self:
            if rec.state != "cancelled":
                raise UserError("Only cancelled assessments can be reset to draft.")
            released = rec.assessment_evaluator_ids.filtered("results_released")
            if released and not self.env.context.get("confirm_released"):
                raise RescoreRefused(
                    "%d candidate(s) on '%s' can already see their released "
                    "results. Reset to Draft would permanently erase them. "
                    "Nothing was deleted - confirm it on purpose to go ahead."
                    % (len(released), rec.name), "released_results")
            rec.assessment_evaluator_ids.unlink()
            rec.response_ids.unlink()
            rec.write({"question_ids": [(5, 0, 0)],
                       "start_date": False, "end_date": False,
                       "launched_at": False})
        self.write({"state": "draft"})
        self._log_activity(Markup(
            "<b>Reset to Draft</b> - every candidate's attempt and answers "
            "were deleted, and the question selection and schedule were "
            "cleared. The candidate list was kept."))

    @api.constrains("start_date", "end_date")
    def _check_schedule_dates(self):
        today = fields.Date.context_today(self)
        for rec in self:
            if rec.state != "draft":
                continue
            if rec.start_date and rec.start_date.date() < today:
                raise ValidationError(
                    "Start Date cannot be in the past.")
            if rec.start_date and rec.end_date and rec.end_date < rec.start_date:
                raise ValidationError(
                    "End Date must be on or after the Start Date.")

    def _ensure_candidate_user(self, applicant):
        applicant = applicant.sudo()
        candidate_group = self.env.ref(
            "assessments_be_v2.group_assessment_candidate")
        if applicant.be_candidate_user_id:
            # ALREADY BOUND STILL NEEDS THE GROUP, and this is the path that
            # would otherwise lock a live candidate out.
            #
            # The Assign-candidates picker binds through
            # `hr.applicant._be_ensure_applicant_for_user`, which sets
            # `be_candidate_user_id` BEFORE the roster row exists - so by the
            # time launch calls this method the answer is already "exists" and
            # the early return used to be the end of it. Anyone assigned from
            # the directory would have arrived at their exam with no group and
            # been refused by the new gate. The write is additive and
            # idempotent, so re-running it on every launch costs one no-op
            # UPDATE and cannot demote anybody.
            self._be_grant_candidate_group(
                applicant.be_candidate_user_id, candidate_group)
            return "exists"
        email = (applicant.email_from or "").strip()
        if not email:
            return "skipped"
        Users = self.env["res.users"].sudo()
        # The search NARROWS, the address check DECIDES: `_be_same_person`
        # re-checks the address, because this bind is permanent (copy=False)
        # and every gate and every record rule keys on it - a wrong one hands
        # somebody else's account an exam, and on a fresh portal account the
        # seeded default password with it. The needle is escaped for the same
        # reason the sign-in gateway escapes its own: `=ilike` reads `_` and
        # `%` as patterns and `_` is legal - and common - in a local-part, so
        # an unescaped `a_b@corp.com` both matches `axb@corp.com` and can push
        # the real row past the limit below.
        #
        # The create at the bottom must use the address the search used. It
        # wrote `email_from` raw, so `Asha.Rao@Corp.com` - or the display-name
        # form `"Asha Rao" <asha@corp.com>` that this free-text field may hold
        # - became the login verbatim: an account nobody can ever sign in to.
        login_email = applicant._be_search_email() or email
        # The same address rule as a typed-in row, at the one place a login is
        # made, so an applicant made any other way ("x@@example" gave the
        # login "@example") cannot become an account nobody can sign in to.
        if candidate_row_error("-", login_email):
            raise UserError("%r is not an email address, so no sign-in can "
                            "be made. Correct it on the candidate."
                            % email[:100])
        needle = login_email.replace("\\", "\\\\").replace(
            "_", "\\_").replace("%", "\\%")
        user = Users.browse()
        for match in Users.with_context(active_test=False).search(
                [("login", "=ilike", needle)],
                limit=10):
            if applicant._be_same_person(match):
                user = match
                break
        if user and not user._is_internal():
            # A PORTAL ACCOUNT IS NOT A CANDIDATE, AND IS NOT CONVERTED INTO ONE.
            #
            # This platform is internal-users-only. Binding here would write
            # `be_candidate_user_id` and then grant `group_assessment_candidate`,
            # which implies `base.group_user` - and `_check_disjoint_groups`
            # forbids an account being both portal and internal. So the bind
            # succeeded, the grant queued, and the whole transaction died at
            # FLUSH with a ValidationError raised from somewhere with no mention
            # of this candidate or this address:
            #
            #   The user cannot have more than one user types.
            #
            # Nobody could act on that. Launching an assessment for a candidate
            # whose email happens to belong to an existing portal contact simply
            # 500'd, and the roster row was left half-written.
            #
            # REFUSE, DO NOT CONVERT. Silently promoting a portal contact to an
            # internal user changes what the account costs (a paid Odoo seat) and
            # hands it the back office - a decision that belongs to a person, not
            # to a launch. Raised as a UserError so it surfaces as a message on
            # the action the operator just took, with the address in it.
            raise UserError(
                "%s cannot sit an assessment: the address %s already belongs to "
                "a PORTAL account (%s), and this platform is for internal users "
                "only.\n\n"
                "Portal accounts are never converted automatically - that would "
                "change what the account costs and give it back-office access. "
                "Either invite this person on a different address, or have an "
                "administrator deliberately convert that account to an internal "
                "user first."
                % (applicant.partner_name or email, email, user.login))
        if user:
            # An EMPLOYEE sitting an assessment. Bind them like anybody else
            # rather than bailing out: the exam gate walks applicant ->
            # `be_candidate_user_id` -> user, so leaving staff unbound is what
            # made `/exam/<token>/state` answer `wrong_candidate` to the very
            # person the invitation named, after their own assessment list had
            # just offered them a Start button. The record rules key on this
            # field too, so an unbound candidate also has no row-level access.
            #
            # Nothing is PROVISIONED here - the account already exists - and the
            # two side effects that would be wrong for existing staff are
            # refused at their own call sites: `_seed_candidate_password` only
            # touches an account this module just created, and
            # `_deliver_invitation` sends no password-reset mail to an internal
            # user.
            _logger.info(
                # IDS, NOT NAMES OR ADDRESSES (services/audit.py: candidate
                # PII stays out of the log store several teams can read).
                "Candidate applicant=%s is an internal user (id=%s); binding "
                "without provisioning.", applicant.id, user.id)
        created = False
        if not user:
            company = (
                self.env.ref("base.main_company", raise_if_not_found=False)
                or self.env["res.company"].search([], limit=1, order="id asc")
            )
            # INTERNAL, not portal.
            #
            # A candidate account is an ordinary staff-shaped login here: the
            # people sitting these assessments are onboarding into the org, and
            # the invitation now tells them to sign in with their Odoo
            # credentials rather than follow a token link. Two consequences
            # worth knowing: an internal user occupies a paid Odoo seat where a
            # portal user did not, and an internal user can reach the Odoo back
            # office - with no groups beyond this one they see almost nothing
            # there, but they are through the door.
            #
            # THE GROUP IS `Candidate`, NOT `base.group_user`. It IMPLIES
            # base.group_user, so the paragraph above still holds exactly - same
            # internal seat, same back-office door - but the account now also
            # satisfies the gate on the candidate API, which base.group_user
            # alone must not (every employee holds that one, which is why
            # "Assessment v2 Access = No" used to still let a person sit an
            # exam).
            user = Users.with_company(company).with_context(
                no_reset_password=True,
                mail_create_nosubscribe=True,
                mail_create_nolog=True,
                tracking_disable=True,
            ).create({
                "name": applicant.partner_name or login_email,
                "login": login_email,
                "email": login_email,
                "company_id": company.id,
                "company_ids": [(6, 0, [company.id])],
                # (4, id) ADDITIVE, not (6, 0, [...]) replace. On a create the
                # two are equivalent, and it is written this way so that copying
                # this line - which is how the second grant site below came to
                # exist - cannot turn into a group RESET on an existing account.
                # A manager who is also sitting an assessment must not be
                # stripped back to Candidate by their own provisioning.
                "group_ids": [(4, candidate_group.id)],
            })
            created = True
        if not created and not user.active:
            _logger.warning(
                "Candidate applicant=%s matches a DEACTIVATED user "
                "(id=%s); linking but NOT reactivating - enable it manually if "
                "this candidate should sit the exam.",
                applicant.id, user.id)
        # H-1/H-2: never bind a portal user that is ALREADY the be_candidate_user_id
        # of a DIFFERENT applicant. Otherwise two applicants sharing an email
        # (duplicate CSV row, or an attacker who pre-registered it) resolve to
        # the same login -> either could sit the other's exam, and
        # _deliver_invitation fires a password-reset on the victim's account.
        if not created:
            other = self.env["hr.applicant"].sudo().search([
                ("be_candidate_user_id", "=", user.id),
                ("id", "!=", applicant.id),
            ], limit=1)
            if other:
                _logger.warning(
                    "That email is already bound to applicant %s (user %s); "
                    "refusing to rebind for applicant %s. Resolve the "
                    "duplicate email manually.",
                    other.id, user.id, applicant.id)
                return "skipped"
        applicant.be_candidate_user_id = user.id
        # THE BIND IS THE MOMENT SOMEBODY BECOMES A CANDIDATE, so it is where
        # the group belongs. The create branch above grants it in its vals, but
        # a PRE-EXISTING account reaches this line having been given nothing -
        # and that is the ordinary case for an employee sitting an assessment,
        # for anyone rostered from the directory, and for every re-launch. Every
        # gate and every record rule keys on this field; the group is the other
        # half of the same statement and must not be able to lag behind it.
        self._be_grant_candidate_group(user, candidate_group)
        if not applicant.partner_id and user.partner_id:
            applicant.partner_id = user.partner_id.id
        return "created" if created else "linked"

    def _be_grant_candidate_group(self, user, candidate_group=None):
        """Add the Candidate group to ``user``, additively. Never raises.

        Split out of `_ensure_candidate_user` because that method has THREE
        binding points (already-bound, freshly created, newly linked) and a
        group granted at only some of them is indistinguishable from no group at
        all to the person refused at the exam door.

        ADDITIVE, ALWAYS. `(4, id)` links; `(6, 0, [id])` would replace, and this
        runs on accounts that may already be Admin or Manager - an operator who
        is also sitting an assessment must not be demoted by being rostered.

        PORTAL AND PUBLIC ACCOUNTS ARE LEFT ALONE, and that is not tidiness. The
        Candidate group implies `base.group_user`, and
        `res.users._check_disjoint_groups` (base/models/res_users.py, an
        `@api.constrains` on `group_ids`) refuses any user who ends up in two of
        employee/portal/public. Granting it to a legacy portal candidate raises
        ValidationError - and because the constraint runs at FLUSH rather than at
        write, that error surfaces somewhere later in the transaction, which
        during a launch means the whole launch fails for the whole cohort. So the
        conflict is TESTED first; a try/except around the write would not catch
        it.

        The consequence is stated plainly in the log because it is a real
        product decision, not an edge case: a portal candidate keeps their bind
        and their attempt, and is refused by the API gate until somebody either
        converts the account to internal or re-provisions it. Every account this
        module creates has been internal for some time, so this is a legacy
        shape - but silently doing nothing about it would be worse than saying so.
        """
        if not user:
            return False
        candidate_group = candidate_group or self.env.ref(
            "assessments_be_v2.group_assessment_candidate")
        user = user.sudo()
        held = user.all_group_ids
        if candidate_group in held:
            # Already entitled, directly or through Manager/Admin.
            return True
        # `all_implied_ids` is the reflexive closure - Candidate plus
        # base.group_user - so subtracting it leaves exactly the type groups
        # that would COLLIDE: portal and public.
        exclusive = (self.env["res.groups"]._get_user_type_groups()
                     - candidate_group.all_implied_ids)
        blocking = held & exclusive
        if blocking:
            _logger.warning(
                "Candidate user %s (id=%s) is a %s account, which cannot hold "
                "%s because that group implies base.group_user and Odoo forbids "
                "being both. The bind is kept, but this account will be refused "
                "by the candidate API until it is converted to an internal user "
                "or re-provisioned.",
                user.login, user.id,
                ", ".join(blocking.mapped("name")),
                candidate_group.name)
            return False
        user.write({"group_ids": [(4, candidate_group.id)]})
        return True

    def _be_provision_candidates(self, applicants):
        """Provision every candidate's login, reporting ALL refusals at once.

        `_ensure_candidate_user` raises UserError for a candidate whose address
        already belongs to a PORTAL account - a deliberate refusal, on the
        stated grounds that converting one costs a paid seat and hands out the
        back office. (The seat half of that does not hold on a Community
        deployment; the back-office half does. Either way the refusal stands -
        this method does not second-guess it, it only reports it properly.)
        Called bare in a loop, as assign and launch both did, the FIRST such candidate
        aborts the transaction: a 652-row roster carrying 172 portal addresses
        imported NOBODY and named ONE person. The operator fixes that address,
        re-runs, and meets the next - 172 round trips to rediscover a list the
        very first run already held.

        So collect, and refuse ONCE with the whole list. Deliberately still
        all-or-nothing: a half-imported roster whose missing candidates cannot
        sign in is worse than a clean refusal, because the assessment looks
        ready and the gap only surfaces when those people try to sit it. And
        deliberately still no automatic conversion - that decision stays with
        a person.

        That is LAUNCH's rule. Assigning and importing skip instead
        (`_be_provision_each`), because there the refused people simply stay
        off the roster and are named in the response - the assessment does not
        look ready with them on it.
        """
        applicants = list(applicants)
        tally, blocked = self._be_provision_each(applicants)
        if not blocked:
            return tally
        raise UserError(
            "%d of %d candidate(s) cannot be provisioned. Nothing has been "
            "imported or launched.\n\n"
            "The usual cause is an address that already belongs to a PORTAL "
            "account: this platform is for internal users only, and an account "
            "is never converted automatically. Either have an administrator "
            "convert these accounts, or take these rows off the roster, then "
            "retry.\n\n%s"
            % (len(blocked), len(applicants),
               "\n".join("  - %s <%s>\n      %s" % row[1:] for row in blocked)))

    def _be_provision_each(self, applicants):
        """Provision each candidate on its own; never refuse the batch.

        Returns ``(tally, blocked)``, where `blocked` holds
        ``(applicant, name, address, reason)`` for every candidate whose login
        could not be made. Each failure is rolled back alone, so everybody else
        is provisioned.
        """
        tally = {"created": 0, "linked": 0, "exists": 0, "skipped": 0}
        blocked = []
        for applicant in applicants:
            name = applicant.partner_name or "(no name)"
            address = applicant.email_from or "(no address)"
            try:
                # ONE CANDIDATE'S FAILURE ROLLS BACK ONE CANDIDATE, and only a
                # savepoint makes that true. Catching per row without one is
                # the classic Odoo trap: a DATABASE-level error (a deadlock, a
                # serialization failure under REPEATABLE READ, a constraint on
                # the `res.users` create) aborts the whole Postgres
                # transaction, so every ORM call in every later iteration
                # raises "current transaction is aborted" - and the handlers
                # below then blame that on each remaining candidate in turn.
                # A 652-row roster with ONE bad row refused 652 people, naming
                # 651 who were perfectly fine, which is the same "re-run to
                # discover the truth" this method exists to end, at 651x the
                # scale. Same pattern, same reason, as the invitation cron.
                with self.env.cr.savepoint():
                    outcome = self.sudo()._ensure_candidate_user(applicant)
            except (SerializationFailure, TransactionRollbackError):
                # RETRYABLE, AND NO SAVEPOINT CAN RESCUE IT. Odoo replays the
                # whole request for these two in `service.model.retrying`, and
                # `_seed_candidate_password` re-raises them for exactly that
                # reason. Collecting one here instead would convert a transient
                # fault that was about to succeed on the replay into a
                # permanent refusal naming a candidate who has nothing wrong
                # with them, and the retry that would have fixed it never runs.
                raise
            except UserError as exc:
                blocked.append((applicant, name, address, _first_line(exc)))
            except Exception as exc:  # noqa: BLE001 - see the note below
                # EVERY FAILURE, NOT ONLY `UserError` (the portal refusal). A
                # `ValidationError` off `_check_disjoint_groups` or an
                # `AccessError` on the user create is reported per candidate
                # too, instead of aborting the run with a traceback naming
                # nobody. The reason is carried per candidate rather than
                # assumed, so the message stays true when the cause is not a
                # portal account.
                # The operator is told WHO failed - `blocked` carries the name
                # and address into the UserError below. The log gets the row
                # number instead: candidate PII does not belong in Loki.
                _logger.exception(
                    "Provisioning failed for candidate row %d of this import "
                    "(name and address withheld)", len(blocked) + 1)
                blocked.append((applicant, name, address, _first_line(exc)))
            else:
                tally[outcome] = tally.get(outcome, 0) + 1
        return tally, blocked

    @api.model
    def _be_sit_blockers(self, candidates):
        """Who could never sit, found BEFORE anything is written or provisioned.

        ``candidates`` is a list of ``(address, user)``: the address a login
        would be found or made under, and the account already bound to the
        candidate, if any. Returns one entry per candidate, in order: the
        reason they cannot sit, or None.

        Provisioning is the slow half of an import - 874 rows took 499 s on
        stage (19 Oct 2026) - and it was the only place a portal account was
        found, so the operator waited out the whole run to be told who could
        not sit. This is one query for the whole roster.

        A BOUND PORTAL ACCOUNT IS CAUGHT TOO. `_ensure_candidate_user` returns
        early for a bound candidate and `_be_grant_candidate_group` only logs
        that the account cannot hold Candidate, so on that roster 59 legacy
        portal candidates would have been assigned and then refused at sign-in,
        while 7 unbound ones with the very same kind of account were refused.
        """
        reasons, wanted = [None] * len(candidates), set()
        for index, (address, user) in enumerate(candidates):
            if user:
                continue
            folded = _norm_email(address)
            if not folded or candidate_row_error("-", folded):
                # The refusal `_ensure_candidate_user` would raise, earlier.
                reasons[index] = ("%r is not an email address, so no sign-in "
                                  "can be made." % (address or "")[:100])
            else:
                wanted.add(folded)
        by_login = {}
        if wanted:
            # lower(login), not `login in`: a login keeps whatever casing it
            # was created with, and the match has to be the case-folded one
            # `_be_same_person` uses.
            self.env.cr.execute(tools.SQL(
                "SELECT id FROM res_users WHERE lower(login) = ANY(%s)",
                sorted(wanted)))
            users = self.env["res.users"].sudo().with_context(
                active_test=False).browse([r[0] for r in self.env.cr.fetchall()])
            by_login = {_norm_email(u.login): u for u in users}
        for index, (address, user) in enumerate(candidates):
            if reasons[index]:
                continue
            user = user or by_login.get(_norm_email(address))
            if user and not user.sudo()._is_internal():
                reasons[index] = (
                    "%s belongs to a portal account, which cannot sign in to "
                    "sit. An administrator has to convert it to an internal "
                    "user first." % user.sudo().login)
        return reasons

    def _log_skipped(self, rows, limit=50):
        """Put who an assignment left out, and why, in the History.

        The response is not enough on its own: the 19 Oct 2026 import outlived
        the browser that asked for it, so nobody ever read the answer. The
        History is admin-only, like the roster, so the names belong there; the
        server log gets the count alone.
        """
        self.ensure_one()
        _logger.info("Assessment %s: %d candidate(s) skipped at assignment "
                     "(cannot sit)", self.id, len(rows))
        lines = [escape("%s <%s>: %s" % tuple(row)) for row in rows[:limit]]
        if len(rows) > limit:
            lines.append(escape("and %d more" % (len(rows) - limit)))
        self._log_activity(
            Markup("<b>%s</b><br/>%s") % (
                "%d candidate(s) skipped - they cannot sign in to sit:"
                % len(rows), Markup("<br/>").join(lines)))

    def _sync_roster_rows(self):
        """Give every assigned candidate a roster row.

        Assignment lands in the `evaluator_ids` m2m, but the roster table reads
        `assessment_evaluator_ids`, and those rows were only created at launch -
        so straight after a CSV import a draft's roster was empty: nothing to
        search, nothing to select, no way to take a mis-imported candidate back
        off. The rows carry no question draw yet; action_start still does that.

        A candidate whose login cannot be made is taken back off the
        assignment instead of refusing everybody, and is listed in the returned
        ``tally["refused"]`` as ``(applicant, name, address, reason)``. Launch
        does not come through here and keeps its all-or-nothing refusal.
        """
        Evaluator = self.env["assessments.be.evaluator"]
        # RETURNED so the CSV import can REPORT what this provisioned instead of
        # provisioning the same people a second time to find out. See
        # `action_import_candidates_csv`.
        tally = {"created": 0, "linked": 0, "exists": 0, "skipped": 0}
        refused = []

        def merge(counts):
            for key, value in (counts or {}).items():
                tally[key] = tally.get(key, 0) + value

        for rec in self:
            have = set(rec.assessment_evaluator_ids.mapped("applicant_id").ids)
            missing = [a for a in rec.evaluator_ids if a.id not in have]
            if not missing:
                continue
            # Provision the candidate's login at ASSIGN time, not launch: the
            # roster row makes the assessment appear in their "Upcoming"
            # bucket, and a candidate who cannot sign in cannot see it.
            # Idempotent, and launch still calls it as the safety net for
            # applicants assigned by other paths. BEFORE the rows, so a
            # skipped candidate never gets one.
            counts, blocked = rec._be_provision_each(missing)
            if blocked:
                gone = {row[0].id for row in blocked}
                rec.write({"evaluator_ids": [(3, aid) for aid in gone]})
                missing = [a for a in missing if a.id not in gone]
                refused += blocked
            merge(counts)
            Evaluator.create([
                {"assessment_id": rec.id, "applicant_id": applicant.id}
                for applicant in missing
            ])
        tally["refused"] = refused
        return tally

    @api.onchange("evaluator_ids")
    def _onchange_evaluator_ids_roster(self):
        # Reflect a manual add straight into the roster table so the admin sees
        # one list, not a tag box and a table that disagree. Only for a saved
        # record: an unsaved one has no id to hang evaluator rows off.
        for rec in self:
            if isinstance(rec.id, int):
                rec._sync_roster_rows()

    def action_import_candidates_csv(self):
        self.ensure_one()
        if not self.candidate_csv_file:
            raise UserError("Please upload a CSV file first.")
        try:
            csv_data = base64.b64decode(self.candidate_csv_file)
        except Exception:
            raise UserError(
                "Invalid CSV file. Please upload a valid UTF-8 CSV file.")
        # L-9: bound the roster import. Each row can create an hr.applicant, so
        # an unbounded file is a worker-pinning / record-bloat vector. The byte
        # guard rejects a huge file before it is decoded.
        if len(csv_data) > _MAX_CANDIDATE_CSV_BYTES:
            raise UserError(
                "CSV too large (%d bytes; max %dMB)."
                % (len(csv_data),
                   _MAX_CANDIDATE_CSV_BYTES // (1024 * 1024)))
        try:
            file_input = io.StringIO(upload_text(csv_data, fallback=None))
            reader = csv.DictReader(file_input)
        except Exception:
            raise UserError(
                "Invalid CSV file. Please upload a valid UTF-8 CSV file.")

        required_fields = {"name", "email"}
        if not required_fields.issubset(set(reader.fieldnames or [])):
            raise UserError(
                "CSV must contain 'name' and 'email' columns. "
                f"Found columns: {', '.join(reader.fieldnames or [])}")

        Applicant = self.env["hr.applicant"].sudo()
        imported_ids = []
        errors = []

        # EVERY ROW IS CHECKED BEFORE ANY IS WRITTEN, so one bad row refuses
        # the whole file, as `/assign` refuses its whole request. The refusal
        # used to come after the loop had already created applicants, which
        # the Odoo button rolled back but the API route (it catches the
        # UserError) committed.
        rows = []
        for row_num, row in enumerate(reader, start=2):
            if row_num - 1 > _MAX_CANDIDATE_CSV_ROWS:
                raise UserError(
                    "CSV has too many rows (max %d). Split the roster into "
                    "smaller batches." % _MAX_CANDIDATE_CSV_ROWS)
            name = (row.get("name") or "").strip()
            email = (row.get("email") or "").strip()
            if not name or not email:
                errors.append(f"Row {row_num}: name and email are required.")
                continue
            problem = candidate_row_error(name, email)
            if problem:
                errors.append(f"Row {row_num}: {problem}.")
                continue
            rows.append((name, email))
        if errors:
            raise UserError(
                "Nothing imported. Fix these rows and import again:\n"
                + "\n".join(errors))

        def lookup(email):
            # ESCAPED, for the same reason `_ensure_candidate_user` escapes its
            # own needle - and this is the third site in this codebase to need
            # it. `=ilike` reads `_` and `%` as wildcards, and `_` is legal and
            # common in a local-part, so a roster row for `a_b@corp.com`
            # MATCHED APPLICANT `axb@corp.com`. With `limit=1` that wrong row is
            # then reused: the exam token is minted against a colleague, the
            # invitation mails them somebody else's paper, and the candidate the
            # row named is never created. Worst of all it is silent - no
            # exception, nothing appended to `errors`, so THE IMPORT REPORTS
            # SUCCESS and the roster looks complete.
            #
            # The normalised re-check is the second half of the guard, mirroring
            # the login site. Escaping stops a WILDCARD matching the wrong row;
            # the fold comparison stops anything else the free-text `email_from`
            # may hold from counting as a match - that column can carry the
            # display-name form `"Asha Rao" <asha@corp.com>`, which `=ilike`
            # would not match anyway but a future looser search might.
            # `_norm_email` is deliberately the SAME fold `_be_same_person` and
            # the create below already use, so all three agree on identity.
            #
            # A window of 10 rather than `limit=1`: the whole failure was
            # accepting the first pattern hit, so the fix has to be able to look
            # past a bad one.
            needle = email.replace("\\", "\\\\").replace(
                "_", "\\_").replace("%", "\\%")
            wanted = _norm_email(email)
            for match in Applicant.search(
                    [("email_from", "=ilike", needle)], limit=10):
                if _norm_email(match.email_from) == wanted:
                    return match
            return Applicant.browse()

        # SOMEBODY WHO COULD NEVER SIT IS SKIPPED, not a reason to refuse the
        # file. 8 portal or non-company addresses in an 874-row roster used to
        # undo all 874 after a 499 s run (stage, 19 Oct 2026). A typo above
        # still refuses the file: the operator fixes that in the file, whereas
        # a portal account needs an administrator. People already on the
        # roster are left alone.
        found = [(name, email, lookup(email)) for name, email in rows]
        before = set(self.evaluator_ids.ids)
        fresh = [row for row in found if row[2].id not in before]
        reasons = self._be_sit_blockers(
            [(email, applicant.be_candidate_user_id)
             for _name, email, applicant in fresh])
        skipped, seen = [], set()

        def skip(name, email, reason):
            if _norm_email(email) not in seen:
                seen.add(_norm_email(email))
                skipped.append((name, email, reason))

        for (name, email, _applicant), reason in zip(fresh, reasons):
            if reason:
                skip(name, email, reason)

        for name, email, applicant in found:
            if _norm_email(email) in seen:
                continue
            # Looked up AGAIN, not reused from above: an earlier row of this
            # file may have just created this person.
            applicant = applicant or lookup(email)
            if not applicant:
                applicant = Applicant.create({
                    "partner_name": name,
                    # Store the case-folded address, not the CSV's exact
                    # casing. A roster typed `Asha.Rao@Corp.COM` in one file
                    # and `asha.rao@corp.com` in the next otherwise created two
                    # applicants for one person; `_norm_email` is the same fold
                    # the identity key uses. Raw kept when it folds to empty,
                    # since a blank address is worse than an unfolded one.
                    "email_from": _norm_email(email) or email,
                })
            elif not applicant.partner_name:
                applicant.partner_name = name
            imported_ids.append(applicant.id)

        existing_ids = self.evaluator_ids.ids
        new_ids = list(set(imported_ids) - set(existing_ids))
        if new_ids:
            self.write({"evaluator_ids": [(4, aid) for aid in new_ids]})
        # The m2m alone leaves the roster table empty on a draft, so the admin
        # imports a file and sees nothing.
        #
        # AND IT IS THE ONLY PROVISIONING PASS. This used to be followed by a
        # second loop that called `_ensure_candidate_user` again for every
        # imported applicant, purely to count outcomes - but `_sync_roster_rows`
        # has already provisioned each new candidate by the time it returns, so
        # the second pass could only ever answer "exists". A 652-row import
        # therefore did the work twice on the slowest admin operation there is
        # (one measured at 103.8s holding one of nine HTTP workers), and then
        # reported "0 invited, 0 linked, 652 already had one" about people it
        # had just created. The tally comes back from the pass that did the
        # work instead.
        provisioned = self._sync_roster_rows()
        self.write({
            "candidate_csv_file": False,
            "candidate_csv_filename": False,
        })
        # A login the up-front check could not foresee (another addon's rule
        # on the account, say) was taken back off the roster by the sync.
        late = {row[0].id for row in provisioned["refused"]}
        for _applicant, name, email, reason in provisioned["refused"]:
            skip(name, email, reason)
        if skipped:
            self._log_skipped(skipped)

        # Counted, not provisioned: an applicant already on the roster was not
        # touched by the sync above, and re-resolving them would reintroduce the
        # duplicate pass this just removed. A set, so a person named twice in
        # the file is not also "already assigned".
        already = len(set(imported_ids) & before - late)
        message = (f"{len(set(new_ids) - late)} new candidate(s) added. "
                   f"{already} already assigned.\n"
                   f"Portal access: {provisioned['created']} invited, "
                   f"{provisioned['linked']} linked, "
                   f"{provisioned['exists']} already had one.")
        if provisioned["skipped"]:
            message += (f"\n\u26a0 {provisioned['skipped']} candidate(s) had no "
                        f"email - no portal access created for them.")
        if skipped:
            message += "\n\u26a0 %d skipped - they cannot sign in to sit:\n%s" % (
                len(skipped), _skipped_lines(skipped))
        warn = bool(provisioned["skipped"] or skipped)
        return {
            "type": "ir.actions.client",
            "tag": "display_notification",
            "params": {
                "title": "Candidates Imported",
                "message": message,
                "type": "warning" if warn else "success",
                "sticky": warn,
            },
        }

    def action_download_candidate_template(self):
        self.ensure_one()
        csv_content = "name,email\n"
        csv_content += "John Doe,john.doe@gmail.com\n"
        csv_content += "Jane Smith,jane.smith@gmail.com\n"
        csv_bytes = base64.b64encode(csv_content.encode("utf-8"))
        attachment = self.env["ir.attachment"].create({
            "name": "candidate_import_template.csv",
            "type": "binary",
            "datas": csv_bytes,
            "mimetype": "text/csv",
        })
        return {
            "type": "ir.actions.act_url",
            "url": f"/web/content/{attachment.id}?download=true",
            "target": "new",
        }

    def _check_scoring_not_cancelled(self):
        """Refuse paid grading on a paper somebody explicitly called off.

        ONE PLACE, because both Odoo buttons and `POST /scoring/queue` route
        through these actions, so Odoo refuses what Flutter already hides:
        each click spends an LLM call per answer.

        A KILL IS NOT A CANCEL. `action_kill_scoring` and archiving both stay
        available on a cancelled paper; this refuses only the writers that
        start NEW spending.
        """
        self.ensure_one()
        if self.state == "cancelled":
            raise UserError(
                "'%s' is cancelled. Subjective grading spends an LLM call per "
                "answer, so it is not run on a cancelled assessment - reset "
                "it to draft or restore it first." % self.name)

    def _check_scoring_not_stopping(self):
        """Refuse to queue grading while a Kill is still stopping a lane: the
        lane's next checkpoint would park the new work back to `cancelled`
        (G1-08). Checked before anything is written."""
        for rec in self:
            if (rec.active and rec.scoring_cancel_requested
                    and rec.assessment_evaluator_ids._being_graded()):
                raise RescoreRefused(
                    "Kill is still stopping the grading of '%s'. Nothing was "
                    "queued - try again once it has stopped, usually within "
                    "a minute." % rec.name, "stopping")

    def action_llm_score_all(self):
        self.ensure_one()
        self._check_scoring_not_cancelled()
        self._check_scoring_not_stopping()
        # ONE QUERY, not a Python walk of every answer of the cohort (12,000
        # on a 750-candidate paper) on every click.
        todo = self.env["assessments.be.evaluator"].search(
            [("assessment_id", "=", self.id), ("pii_anonymized", "=", False)]
            + self.env["assessments.be.evaluator"]._answers_scored_domain(
                scored=False))
        if not todo:
            raise UserError("No submitted candidates awaiting subjective scoring.")
        # A candidate a lane is grading right now is left to it: rewriting
        # the row makes the lane's paid result collide, and hides it from Kill.
        busy = todo._being_graded()
        todo -= busy
        self._remember_scoring_tally()
        # Only a click that actually queues something withdraws the kill: one
        # that queues nobody (every candidate is busy) is not an admin asking
        # for this run to resume.
        if todo:
            self._withdraw_scoring_kill()
        todo.write({"scoring_requested": True, "llm_state": "pending"})
        self._log_activity(Markup(
            "<b>Run Subjective Evaluation</b> - queued %d candidate(s) for "
            "background subjective grading.") % len(todo))
        return {
            "type": "ir.actions.client",
            "tag": "display_notification",
            "params": {
                "title": "Subjective Grading Queued",
                "message": f"Queued {len(todo)} candidate(s). The background "
                           f"grader processes about 20 at a time; the status above "
                           f"updates on its own." + _busy_note(busy),
                "type": "success",
                "sticky": False,
                # REFRESH THE FORM THE ADMIN IS LOOKING AT. A
                # `display_notification` returns `params.next` to the action
                # service and nothing else, so with no `next` the open form
                # keeps the old state and the `be_auto_refresh` badge - which
                # only polls a record it was handed busy - never starts. An
                # `act_window_close` is the one action whose handler calls the
                # button's `onClose`, which is what reloads the view.
                "next": {"type": "ir.actions.act_window_close"},
            },
            # What `POST /scoring/queue` replies with; the web client ignores
            # it. Counted here because only this method knows what it skipped.
            "queue": {"queued": len(todo), "skipped": len(busy)},
        }

    def _failed_scoring_domain(self):
        """The candidates Retry Failed Scoring re-queues (and counts)."""
        return [("assessment_id", "in", self.ids),
                ("state", "=", "submitted"),
                ("llm_state", "in", ("failed", "partial", "error"))]

    def _compute_scoring_failed_count(self):
        counts = dict(self.env["assessments.be.evaluator"]._read_group(
            self._failed_scoring_domain(), ["assessment_id"], ["__count"]))
        for rec in self:
            rec.scoring_failed_count = counts.get(rec, 0)

    def action_llm_score_failed(self):
        """Re-queue only the candidates whose scoring did not finish clean.

        THE COMPANION TO Run Subjective Evaluation, for the retry after an
        outage. `action_llm_score_all` re-queues every submitted candidate; on
        a large cohort that re-spends on hundreds of answers already scored to
        clear a handful that hit a Vertex error. This picks out only the
        evaluators whose ROLLUP says something is unresolved - 'failed',
        'partial' or 'error' - and inside each of those resets ONLY the
        responses that are 'failed' or 'error'. An answer already 'scored' is
        left exactly as it is: it has been paid for and re-grading it would
        both cost again and risk moving a mark a human may have released on.
        """
        self.ensure_one()
        self._check_scoring_not_cancelled()
        self._check_scoring_not_stopping()
        # BY DOMAIN, NOT BY `filtered()`. The one-to-many walk read every
        # evaluator in the cohort into memory to select the handful that had
        # failed - at 572 candidates that is the whole roster loaded to find
        # perhaps five, inside a request handler. `llm_state` and `state` are
        # both stored columns and `assessment_id` is indexed, so the same
        # selection is one indexed query whose cost scales with the ANSWER
        # rather than with the cohort. This is what the parity inventory means
        # by "the fix must reset by domain, as the route already does".
        todo = self.env["assessments.be.evaluator"].search(
            self._failed_scoring_domain())
        if not todo:
            raise UserError(
                "No submitted candidates have a failed or errored subjective "
                "score to retry.")
        # Delegate the response-level reset so the "which states, zero the
        # attempts" rule stays in one place (action_reset_failed_scoring); this
        # sets scoring_requested/llm_state on each evaluator as a side effect,
        # which is exactly what the drainer selects on.
        self._remember_scoring_tally()
        # The kill is withdrawn by the delegate below, and only if it actually
        # resets an answer, so a click that resets nothing leaves it up.
        todo.action_reset_failed_scoring(states=("failed", "error"))
        self._log_activity(Markup(
            "<b>Retry Failed Scoring</b> - re-queued %d candidate(s) whose "
            "subjective grading had failed or errored; already-scored answers "
            "were left untouched.") % len(todo))
        return {
            "type": "ir.actions.client",
            "tag": "display_notification",
            "params": {
                "title": "Failed Scoring Re-queued",
                "message": f"Re-queued {len(todo)} candidate(s). Only their "
                           f"failed or errored answers were reset - scored "
                           f"answers keep their marks.",
                "type": "success",
                "sticky": False,
                # Reloads the form so the badge starts polling; see
                # `action_llm_score_all`.
                "next": {"type": "ir.actions.act_window_close"},
            },
        }

    # States a candidate's grading can be killed FROM: the ones the drainer
    # would still pick up and spend on. A 'scored' or 'error' evaluator has
    # already finished its run - there is nothing in flight to stop, and a
    # re-score it has queued is dropped by `_clear_rescore_requests` instead -
    # and 'cancelled' is where a kill lands, so listing it would make a second
    # kill re-park an already-parked candidate.
    _CANCELLABLE_SCORING_STATES = ("pending", "scoring", "partial", "failed")

    def action_kill_scoring(self):
        """Stop this assessment's subjective grading, and only this one's.

        WHAT IT ACTUALLY DOES. There is no process to signal - scoring runs in
        a cron worker - so this raises a flag and commits it, and every billable
        grading lane belonging to this assessment reads that flag back before
        its next call (`services/vertex._check_scoring_cancelled`) and refuses.
        A run stops within one call instead of at the end of its batch. The one
        request already on the wire completes and is billed; nothing after it
        is. `evaluator_id -> assessment` is what scopes it, so a second
        assessment being graded at the same time is untouched.

        SCORES ARE KEPT. A candidate whose answers were already scored keeps
        every mark. This clears `scoring_requested` on the queued/scoring
        evaluators no running lane holds, so the drainer stops selecting them,
        parks them in 'cancelled' so the list distinguishes a stopped candidate
        from a broken one, and drops the paper's queued re-score requests - it
        does not touch a single stored score.

        Idempotent: killing a run that has already stopped is a no-op that
        still reports success, because the admin's intent is satisfied.

        THE FLAG IS LEFT RAISED, AND THAT IS THE WHOLE MECHANISM. The lane's
        checkpoint reads it on a fresh cursor after this request commits, so
        lowering it in the same transaction would let the candidate being
        graded right now carry on calling Vertex.

        So the flag stays up while a lane is genuinely mid-call, exactly as
        `sop_gen_cancel_requested` does for a generator that is `generating`. It
        is lowered again immediately when nothing is in flight - no candidate a
        running lane holds, so there is nothing left to refuse - and otherwise
        by the drainer's settle, by `_clear_finished_scoring_kills` when the
        holding lane's tick ends, or by the next request to score, which is an
        admin withdrawing the kill. Kill and the drainer settle through the
        same `_settle_scoring_cancelled`, so the two cannot disagree about what
        a lane holds.
        """
        self.ensure_one()
        self.write({
            "scoring_cancel_requested": True,
            "scoring_cancelled_at": fields.Datetime.now(),
        })
        # NO EXPLICIT COMMIT HERE, mirroring the generator's action_cancel_
        # generation. The flag is made durable by the web request's own commit
        # on the way out, which is what the grading-lane checkpoint then reads
        # on its fresh cursor. Committing inside this method would break a
        # TransactionCase and, in production, would partially commit a request
        # that has not finished - the generator kill proves the request-level
        # commit is sufficient for the cooperative-cancel handshake.
        #
        # Park what no running lane holds, drop its re-score requests, and
        # lower the flag again only when nothing is in flight: a raised flag
        # with nothing left to refuse would sit up for ever (the cron only
        # revisits QUEUED candidates) and refuse the assessment's next run.
        # This is how the generator behaves: `action_cancel_generation` settles
        # a run still `queued` on the spot and leaves the flag up only for one
        # that is `generating`.
        settled, cleared, held = self._settle_scoring_cancelled(
            "stopped before the grader reached this candidate")
        self._log_activity(Markup(
            "<b>Kill scoring requested</b> - subjective grading will stop at "
            "the next LLM call. %d candidate(s) were still queued and have "
            "been parked, %d re-score request(s) cancelled; scores already "
            "stored are kept.") % (len(settled), cleared))
        stopped = []
        if settled:
            stopped.append("Stopped grading for %d candidate(s)." % len(settled))
        if cleared:
            stopped.append("%d re-score request(s) cancelled." % cleared)
        if held:
            stopped.append("%d candidate(s) being graded now will stop at "
                           "their next call." % len(held))
        return {
            "type": "ir.actions.client",
            "tag": "display_notification",
            "params": {
                "title": "Scoring stopped" if stopped else "Nothing to stop",
                "message": (
                    " ".join(stopped) + " Any answer already scored keeps its "
                    "mark.") if stopped else
                    "No candidate was being graded on this assessment.",
                "type": "success",
                "sticky": False,
                # Reloads the form so the badge starts polling; see
                # `action_llm_score_all`.
                "next": {"type": "ir.actions.act_window_close"},
            },
            # What THIS click stopped, for the API route to report. Counted
            # from the settle rather than from the paper's `cancelled` rows,
            # which are a lifetime tally: a second kill, or a paper carrying
            # older cancelled candidates, would otherwise report a number that
            # has nothing to do with the button just pressed.
            "kill": {"settled": len(settled), "cleared": cleared,
                     "held": len(held)},
        }

    def _withdraw_scoring_kill(self):
        """Lower a raised kill flag because scoring has been asked for again.

        `action_kill_scoring` deliberately leaves the flag up so the lanes
        mid-flight refuse their next call, and a flag still up refuses every
        later run at its first checkpoint. Pressing Score All or Score Failed
        Responses (Run Subjective Evaluation / Retry Failed Scoring in Odoo) is
        an admin withdrawing the kill, so it is the honest place to lower it.
        Writing it unconditionally would dirty every assessment on every run,
        so it is written only when it is actually up.

        NEVER WHILE A LANE IS STILL STOPPING. The raised flag is the ONLY
        thing refusing the calls a killed lane already has dispatched, so
        lowering it while that lane still holds a candidate un-kills a run
        mid-flight: the next call goes out, is billed, and the candidate
        finishes `scored` instead of `cancelled`. A click can withdraw a kill
        that has finished stopping - not one that is still working. Each
        caller decides the other half: it withdraws only when it actually
        queued or reset something.
        """
        for rec in self:
            if not rec.scoring_cancel_requested:
                continue
            if rec.assessment_evaluator_ids._being_graded():
                _logger.info(
                    "Kill on assessment %s is still stopping a running lane; "
                    "the flag stays raised and nothing was un-killed.", rec.id)
                continue
            rec.scoring_cancel_requested = False

    def _settle_scoring_cancelled(self, why="", lane_shard=None,
                                  in_flight=None):
        """Park this assessment's queued/scoring candidates and CLEAR the flag,
        unless a running lane still holds one of them.

        Returns ``(parked candidates, re-score requests dropped, candidates
        left to the running lane that holds them)``.

        Leaving the flag raised with nothing held would make the assessment
        permanently unable to be scored: every future run would refuse at its
        first checkpoint, and the only symptom would be scoring that produced
        nothing for no stated reason - the exact bug
        `_settle_generation_cancelled` documents for the generator.

        Only the evaluators the drainer would still touch are parked, and only
        their evaluator-level `scoring_requested` / `llm_state` move. No
        response row and no stored score is written, because a kill keeps what
        was already paid for.

        A CANDIDATE A RUNNING LANE IS GRADING IS LEFT TO THAT LANE, with its
        re-score requests, and the flag then stays up so the lane's queued
        calls are refused (`_being_graded`). Parking another lane's candidate
        and lowering the flag would let its queued calls through, billed, and
        its store would then collide with this write and discard the paid
        marks. A `scoring` row no running lane holds - its lane died - is
        parked whether or not `scoring_requested` is set: nothing else ever
        will.

        ``lane_shard`` / ``in_flight``: the calling lane, see `_being_graded`.
        """
        self.ensure_one()
        held = self.assessment_evaluator_ids._being_graded(
            lane_shard, in_flight)
        settling = self.assessment_evaluator_ids.filtered(
            lambda ev: ev.llm_state in self._CANCELLABLE_SCORING_STATES
            and (ev.scoring_requested or ev.llm_state == "scoring")) - held
        if settling:
            settling.write({
                "scoring_requested": False,
                "llm_state": "cancelled",
                "llm_error": (
                    "Scoring cancelled by an admin%s."
                    % (" - %s" % why if why else ""))[:240],
            })
        cleared = self._clear_rescore_requests(
            self.assessment_evaluator_ids - held)
        if not held:
            self.write({"scoring_cancel_requested": False})
        return settling, cleared, held

    def _clear_rescore_requests(self, evaluators):
        """Drop the queued re-score requests of ``evaluators`` and return how
        many there were. The key alone: no mark, state or attempt count moves."""
        pending = self.env["assessments.be.response"].search([
            ("assessment_evaluator_id", "in", evaluators.ids),
            ("rescore_request_key", "!=", False),
        ])
        pending.write({"rescore_request_key": False})
        return len(pending)

    def _releasable_evaluators(self):
        """Submitted attempts whose results are still held, and of those, the
        ones whose subjective answers are not finished. One pair, read by the
        confirm dialog and by the release itself, so the numbers the operator
        agreed to are the numbers that get written."""
        self.ensure_one()
        to_release = self.assessment_evaluator_ids.filtered(
            lambda r: r.state == "submitted" and not r.results_released)
        unscored = to_release.filtered(lambda e: any(
            r.needs_llm and r.llm_state != "scored" for r in e.response_ids))
        return to_release, unscored

    def action_release_all_results(self):
        """Ask first. RELEASE CANNOT BE UNDONE - there is no un-release path
        anywhere in the module - and it releases the whole cohort at once,
        including candidates whose written answers are still with the grader,
        so the "still being graded" count has to come BEFORE the write.

        A static `confirm=` cannot state a count, and the count is the point -
        Flutter's sheet leads with Submitted / Releasing now / Still grading
        and names the candidates still being graded. So this opens the same
        three numbers as a dialog; `action_confirm_release` there does the
        write.
        """
        self.ensure_one()
        to_release, unscored = self._releasable_evaluators()
        if not to_release:
            raise UserError(
                "No submitted candidates awaiting release. Results are only "
                "releasable once a candidate has submitted their attempt.")
        wizard = self.env["assessments.be.release.wizard"].create({
            "assessment_id": self.id,
        })
        return {
            "type": "ir.actions.act_window",
            "name": "Release Results",
            "res_model": "assessments.be.release.wizard",
            "res_id": wizard.id,
            "view_mode": "form",
            "views": [[self.env.ref(
                "assessments_be_v2.assessments_be_release_wizard_form").id,
                "form"]],
            "target": "new",
        }

    def action_confirm_release(self):
        """The write `action_release_all_results` asked about. Called by the
        confirm dialog, and directly by the API and by tests."""
        self.ensure_one()
        to_release, unscored = self._releasable_evaluators()
        if not to_release:
            raise UserError(
                "No submitted candidates awaiting release. Results are only "
                "releasable once a candidate has submitted their attempt.")
        # A CANDIDATE A LANE IS GRADING RIGHT NOW IS LEFT TO IT, the same rule
        # every other writer here follows: a commit into rows a lane holds
        # hands that lane a SerializationFailure, so its paid results are
        # rolled back and bought again on the next tick. They are released on
        # the next click, a minute later, with their marks final.
        busy = to_release._being_graded()
        to_release -= busy
        if not to_release:
            raise UserError(
                "Every candidate awaiting release is being graded right now. "
                "Their marks are not final yet - try again in a minute.")
        unscored = to_release.filtered(lambda e: any(
            r.needs_llm and r.llm_state != "scored" for r in e.response_ids))
        to_release.write({"results_released": True})
        self._log_activity(Markup(
            "<b>Release Results</b> - released results for %d candidate(s).")
            % len(to_release))
        msg = "Released results for %s candidate(s)." % len(to_release)
        if busy:
            msg += _busy_note(busy)
        warn = bool(unscored or busy)
        if unscored:
            msg += (" NOTE: %s of them still have subjective answers being "
                    "graded - their scores will fill in automatically as the "
                    "grader finishes (usually within a minute). Use 'Run "
                    "Subjective Evaluation' if it stays pending."
                    % len(unscored))
        return {
            "type": "ir.actions.client",
            "tag": "display_notification",
            "params": {
                "title": "Results Released",
                "message": msg,
                "type": "warning" if warn else "success",
                "sticky": warn,
                # Closes the confirm dialog and reloads the paper behind it,
                # so the counted button drops to zero and disappears instead
                # of still offering a release that has already happened.
                "next": {"type": "ir.actions.act_window_close"},
            },
            # What `POST /assessments/<id>/release` replies with; the web
            # client ignores it. What was written, not what was selected.
            "release": {"released": len(to_release), "skipped": len(busy)},
        }

    @api.model
    def _scoring_shard_count(self):
        """Configured parallel scoring lanes (ir.config_parameter
        assessments_be_v2.scoring_shards). Clamped to [1, MAX_SCORING_SHARDS];
        1 (default) is a single lane, shard 0. Calls in flight per lane are a
        separate setting (`_scoring_parallel_calls`).
        """
        raw = self.env["ir.config_parameter"].sudo().get_param(
            "assessments_be_v2.scoring_shards", "1")
        try:
            n = int(raw)
        except (TypeError, ValueError):
            n = 1
        return max(1, min(n, MAX_SCORING_SHARDS))

    @api.model
    def _cron_llm_auto_score(self, shard=0):
        """Drain one scoring shard. Each shard cron owns a disjoint slice of
        submitted evaluators (id %% shard_count == shard) under its OWN advisory
        lock, so N shard crons drain in parallel, each with up to
        `_scoring_parallel_calls()` candidates in flight (`_drain_in_parallel`;
        1 is the serial loop below). Shard 0 keeps ADVISORY_LOCK_AUTOSCORE;
        higher shards are no-ops until scoring_shards is raised, so the lane
        count is a pure config lever with no cron/code change.
        """
        shard_count = self._scoring_shard_count()
        if shard >= shard_count:
            return
        with cron_lock(self.env.cr, _lane_lock(shard),
                       name="scoring_lane_%s" % shard) as got:
            if not got:
                # A SKIP WITH WORK WAITING IS THE ONE WORTH A LINE. On
                # 2026-09-30 shard 2 sat on a leaked lock for 14 minutes with
                # 20 candidates left and nothing said so. An empty queue stays
                # silent. Logged here, not by `cron_lock` (no `queued=`), so
                # the lane keeps its own marker and the line is not doubled.
                # A count that fails is read as 0, never a crashed tick.
                queued = queued_count(
                    self.env.cr,
                    lambda: self._scoring_lane_counts(shard_count).get(
                        shard, (0,))[0],
                    name="scoring_lane_%s" % shard, key=_lane_lock(shard))
                if queued:
                    _logger.warning("SCORING_LANE_BLOCKED shard=%s queued=%s",
                                    shard, queued)
                return
            from ..services import vertex as vertex_svc
            # THE DAILY CAP ENDS THE TICK, HERE, ONCE: one WARNING anyone can
            # alert on, instead of a refusal per candidate deep in the call
            # (~19k INFO lines an hour across the lanes) and a tick that still
            # plans candidates it cannot grade.
            try:
                vertex_svc._check_spend(self.env, None)
            except vertex_svc.VertexBudgetError as exc:
                _logger.warning(
                    "SPEND_CAP daily: scoring lane %s planned nothing this "
                    "tick: %s", shard, exc)
                return
            limit = self._scoring_tick_limit()
            evaluators = self._scoring_shard_evaluators(
                shard, shard_count, limit=limit)
            workers = self._scoring_parallel_calls()
            stored = 0
            # Worker cursors must see what this cursor commits, which is exactly
            # what the test runner's cursor cannot offer.
            if workers > 1 and vertex_svc._side_cursor_is_safe(self.env):
                stored = self._drain_in_parallel(evaluators, workers,
                                                 renew=got.renew)
            else:
                for ev in evaluators:
                    # Lease mode: renewed here, saved by this candidate's
                    # first commit. A lane taken over stops before its next
                    # candidate, or two workers would grade it.
                    if not got.renew():
                        break
                    # The checkpoint writes (it may settle a killed paper), so
                    # a collision there is this candidate's failure, not the
                    # tick's.
                    try:
                        if not self._auto_score_eligible(ev):
                            continue
                        self._auto_score_mark_scoring(ev)
                        with self.env.cr.savepoint():
                            done = ev._action_llm_score()
                        got.renew()
                        self.env.cr.commit()
                        stored += done or 0
                    except Exception as exc:
                        self._auto_score_failed(ev, exc)
                        continue
            self._clear_finished_scoring_kills()
            if len(evaluators) >= limit and stored:
                # THE QUEUE IS STILL FULL, so the next tick is work waiting on
                # the minute grid rather than on Vertex. A 704-candidate paper
                # at 20 a tick spends ~35 whole minutes doing nothing but
                # waiting for the clock. Same handshake the tag-extract queue
                # uses; the periodic interval stays the safety net - and the
                # backoff when nothing was stored (every call deferred by a
                # 429, a cap or the pool), which would otherwise spin (R1-03).
                self._trigger_scoring_lane(shard)

    @api.model
    def _scoring_tick_limit(self):
        """How many candidates one lane tick plans (`scoring_tick_limit`, 20)."""
        raw = self.env["ir.config_parameter"].sudo().get_param(
            "assessments_be_v2.scoring_tick_limit", "20")
        try:
            limit = int(float(raw))
        except (TypeError, ValueError):
            return 20
        return limit if limit >= 1 else 20

    @api.model
    def _trigger_scoring_lane(self, shard):
        """Ask this lane's cron to run again at once instead of on the minute.

        Never raises: a lane that cannot find its own cron record (a partial
        install, a renamed record) simply keeps the periodic cadence.
        """
        try:
            crons = self.env["ir.cron"].sudo().with_context(
                active_test=False).search([
                    ("code", "like", "_cron_llm_auto_score"),
                    ("model_id.model", "=", "assessments.be"),
                ])
            mine = crons.filtered(
                lambda c: _cron_shard_index(c.code) == shard and c.active)
            if mine:
                mine[0]._trigger()
        except Exception:  # noqa: BLE001 - the periodic tick is the fallback
            _logger.warning(
                "scoring lane %s could not re-trigger its cron; it waits for "
                "the next tick.", shard, exc_info=True)

    @api.model
    def _clear_finished_scoring_kills(self):
        """Lower a kill flag whose last in-flight call has finished.

        `_settle_scoring_cancelled` lowers the flag only when nothing is held,
        and a kill that catches calls mid-flight is held by definition. If
        every one of those calls then returns successfully, NOTHING lowers it
        again: the paper reads `idle` with the flag still up, and the next
        candidate to submit is settled "cancelled by an admin" without ever
        being graded. Checked at the end of a lane's tick, when a lane that
        was holding candidates has just let go of them; a paper another lane
        still holds keeps its flag, so the two cannot disagree.

        Only the FLAG moves. Nothing is parked here: everything the kill meant
        to stop was parked when it was pressed, and a candidate queued since
        then is someone else's ask.

        AN ARCHIVED PAPER IS NOT TOUCHED, and the plain `search` is what keeps
        it that way (`active_test`). Archiving raises the same flag to SUSPEND
        grading, and that suspension must outlive any tick.
        """
        for asmt in self.sudo().search([("scoring_cancel_requested", "=", True)]):
            if asmt.assessment_evaluator_ids._being_graded():
                continue
            asmt.scoring_cancel_requested = False
            _logger.info(
                "Kill on assessment %s has finished stopping its run; the "
                "flag is lowered so later submissions grade normally.",
                asmt.id)

    @api.model
    def _auto_score_eligible(self, ev, in_flight=None):
        """Whether the drainer grades ``ev`` now. Settles a killed paper.

        ``in_flight``: the candidates this lane has calls out for."""
        # SUSPENDED IS NOT KILLED, and this is the whole difference.
        # The domain above already excludes archived assessments, but
        # it is read once at the top of the tick and this loop commits
        # between candidates - so a paper archived mid-drain is still
        # in the list we are walking, now with its
        # `scoring_cancel_requested` raised. Without this line the next
        # branch would read that flag, call `_settle_scoring_cancelled`
        # and park the whole queue to `cancelled` - terminal and lossy,
        # and the one outcome an archive must never produce, because a
        # `cancelled` row cannot be resumed as the `pending` or
        # `failed` it actually was. Skipping leaves every row exactly
        # as it is, which is what an unarchive resumes from.
        # A paper CANCELLED mid-tick is skipped the same way, and before the
        # re-score shortcut below: nobody pays to grade a cancelled paper
        # (RV1-02).
        if (not ev.assessment_id.active
                or ev.assessment_id.state == "cancelled"):
            return False
        # Cheapest possible checkpoint: a candidate whose assessment
        # was killed while it sat in the queue must never reach Vertex
        # at all. The per-call checkpoint in the service would also
        # catch it, but only after the run had started and paid for its
        # first call - so a killed assessment must cost nothing on the
        # next tick, mirroring the pre-run guard in the SOP-gen cron.
        if ev.assessment_id.scoring_cancel_requested:
            ev.assessment_id._settle_scoring_cancelled(
                "stopped before the grader reached this candidate",
                lane_shard=ev.id % self._scoring_shard_count(),
                in_flight=in_flight)
            self.env.cr.commit()
            return False
        # THE TICK'S LIST IS A SNAPSHOT; THE ROW IS NOT. The
        # assessment-level checkpoint above answers for the PAPER, and
        # `_settle_scoring_cancelled` may lower the flag as its last act -
        # so every other candidate of that paper still in this
        # already-browsed list, parked `cancelled` a moment earlier (here
        # or by `action_kill_scoring`), would pass it and be graded and
        # billed, since the per-call checkpoint re-reads the same lowered
        # flag. So the ROW is asked, not just the paper - one cheap read
        # of state the commit above has already refreshed.
        # A re-score request is its own ask, whatever the candidate's state:
        # a kill clears it, so one still standing was made after any kill.
        if ev._has_rescore_request():
            return True
        if not ev.scoring_requested or ev.llm_state == "cancelled":
            return False
        return True

    @api.model
    def _scoring_parallel_calls(self):
        """Judge calls one lane actually keeps on the wire at once: the setting
        (`_scoring_parallel_calls_setting`), lowered to what the DB pool
        allows. 1 is the serial drain."""
        # EACH CALL IN FLIGHT HOLDS ~2 DB CONNECTIONS: its worker cursor for
        # the whole call, plus a short second one for the ledger row, the kill
        # check or the bearer. In a threaded server the HTTP requests draw on
        # the same `db_maxconn` pool, so every lane together may take at most
        # half of it: a grading wave during a live exam must never be what
        # exhausts the pool. The lane's own cron cursor (and its short side
        # cursors) hold ~2 more, so they come off the top. Odoo's default pool
        # of 64 allows 3 per lane at 4 shards; prod's 600 allows the full
        # setting.
        pool = int(tools.config.get("db_maxconn") or 64)
        shards = self._scoring_shard_count()
        room = max(1, (pool // 2 - 2 * shards) // (2 * shards))
        return max(1, min(self._scoring_parallel_calls_setting(), room))

    @api.model
    def _scoring_parallel_calls_setting(self):
        """The stored `assessments_be_v2.scoring_parallel_calls`, clamped to
        its range. Absent, blank or 0 is the default (4)."""
        low, high, default = SETTING_RANGES["scoring_parallel_calls"]
        raw = self.env["ir.config_parameter"].sudo().get_param(
            "assessments_be_v2.scoring_parallel_calls", str(default))
        try:
            n = int(raw) or default
        except (TypeError, ValueError):
            n = default
        return max(low, min(n, high))

    @api.model
    def _drain_in_parallel(self, evaluators, workers, renew=None):
        """One tick with up to ``workers`` judge calls on the wire at once.

        A lane spends nearly all its time waiting on Vertex, one call after
        another. Here up to ``workers`` candidates are in flight: each is
        planned on this cursor and its calls handed to the pool, and once the
        window is full the FIRST candidate to come back whole is stored and
        committed before the next is planned (`_pop_first_ready`). The pool
        only ever holds calls - every mark is written on this cursor, one
        candidate per savepoint, as the serial loop writes them.

        ``renew``: the tick's `CronLock.renew`, called before each candidate
        is planned and each is stored; False stops the planning (the lane was
        taken over) and the calls already out are still stored.

        Returns how many answers the tick scored.
        """
        from ..services import scoring as scoring_svc
        renew = renew or (lambda: True)
        in_flight = collections.deque()
        stored = 0
        pool = ThreadPoolExecutor(
            max_workers=workers, thread_name_prefix="etp-grade")
        try:
            dispatch = scoring_svc.parallel_dispatch(self.env, pool)
            for ev in evaluators:
                if not renew():
                    break
                try:
                    eligible = self._auto_score_eligible(
                        ev, ev.browse([held.id for held, _run in in_flight]))
                except Exception as exc:
                    self._auto_score_failed(ev, exc)
                    continue
                if not eligible:
                    continue
                run = self._auto_score_begin(ev, dispatch)
                if run is not None:
                    in_flight.append((ev, run))
                if len(in_flight) >= workers:
                    ready = _pop_first_ready(in_flight)
                    renew()
                    stored += self._auto_score_finish(*ready)
            while in_flight:
                ready = _pop_first_ready(in_flight)
                renew()
                stored += self._auto_score_finish(*ready)
        finally:
            # A tick that dies early must not go on paying for calls whose
            # answers nobody will store.
            pool.shutdown(wait=True, cancel_futures=True)
        return stored

    @api.model
    def _auto_score_begin(self, ev, dispatch):
        try:
            self._auto_score_mark_scoring(ev)
            with self.env.cr.savepoint():
                return ev._llm_score_begin(dispatch)
        except Exception as exc:
            self._auto_score_failed(ev, exc)
            return None

    @api.model
    def _auto_score_finish(self, ev, run):
        """Store ``ev``'s run; returns how many answers it scored."""
        try:
            with self.env.cr.savepoint():
                scored = ev._llm_score_finish(run)
            self.env.cr.commit()
            return scored
        except Exception as exc:
            self._auto_score_failed(ev, exc)
            return 0

    @api.model
    def _auto_score_mark_scoring(self, ev):
        """Commit ``ev`` as `scoring` before any of its calls is sent.

        `scoring` is what Kill reads as "a lane holds this candidate": it then
        leaves the row alone and keeps the flag raised so the lane's next call
        is refused. Committed only with the grading transaction, it would land
        AFTER the call, and a Kill in between would see `pending`, park the row
        and lower the flag - and the call would go ahead.
        """
        with self.env.cr.savepoint():
            ev._llm_score_start()
        self.env.cr.commit()

    @api.model
    def _auto_score_failed(self, ev, exc):
        """Log a candidate the lane could not grade.

        After a serialization failure the transaction keeps its old snapshot,
        so every later candidate of the tick would fail the same way - each
        after paying for its call. Rolling back gives the next one a fresh
        snapshot.
        """
        _logger.exception("Auto-score failed for evaluator %s", ev.id)
        if isinstance(exc, (TransactionRollbackError, InFailedSqlTransaction)):
            self.env.cr.rollback()

    #: What a lane still has to grade. The drainer also selects `scoring` (a
    #: row a dead lane left behind); every count reads that as running.
    SCORING_QUEUED_STATES = ("pending", "partial", "failed")

    @api.model
    def _scoring_queue_domain(self, states=SCORING_QUEUED_STATES):
        """The drainer's selection predicate (`_scoring_shard_evaluators`),
        ONE definition, so `/api/v1/scoring`'s `queued` and the lane health
        count exactly what a lane would pick up."""
        return [
            # ARCHIVE IS A SUSPEND, AND THIS TERM IS WHAT MAKES IT ONE.
            # `assessments.be.evaluator` has no `active` column of its own, so
            # `active_test` cannot exclude an archived paper's candidates here
            # and this drainer kept grading - and kept spending - on an
            # assessment an operator had filed away. Written out rather than
            # inherited, and not a snapshot: the rows it stops selecting keep
            # their `scoring_requested` and `llm_state` untouched, which is
            # precisely what lets an unarchive resume the same cohort.
            ("assessment_id.active", "=", True),
            # Nobody pays to grade a cancelled paper or an erased attempt
            # (R7-01, G6-40, G6-41).
            ("assessment_id.state", "!=", "cancelled"),
            ("pii_anonymized", "=", False),
            ("state", "=", "submitted"),
            ("scoring_requested", "=", True),
            ("llm_state", "in", states),
        ]

    @api.model
    def _scoring_lane_counts(self, shard_count, since=None):
        """{shard: (queued, oldest queued write_date, moved)} per lane (id %%
        shard_count), in ONE grouped query: the queue
        (`_scoring_queue_domain`), and whether anything of that lane was
        stored (`llm_scored_at`) or picked up (`scoring`) since ``since``
        (default 15 minutes ago). Shards with neither are absent. One query on
        every path, because `/api/v1/scoring` polls this. Sudo: the queue is
        the installation's, not the caller's."""
        since = since or fields.Datetime.now() - timedelta(minutes=15)
        Evaluator = self.env["assessments.be.evaluator"].sudo()
        queue = fields.Domain(self._scoring_queue_domain())
        moved = fields.Domain([
            "|", ("llm_scored_at", ">=", since),
            "&", ("llm_state", "=", "scoring"), ("write_date", ">=", since)])
        query = Evaluator._search(queue | moved)

        def where(domain):
            return domain.optimize_full(Evaluator)._to_sql(
                Evaluator, query.table, query)

        in_queue = where(queue)
        lane = tools.SQL("%s %% %s",
                         Evaluator._field_to_sql(query.table, "id", query),
                         shard_count)
        query.groupby = lane
        rows = self.env.execute_query(query.select(
            lane,
            tools.SQL("COUNT(*) FILTER (WHERE %s)", in_queue),
            tools.SQL("MIN(%s) FILTER (WHERE %s)", Evaluator._field_to_sql(
                query.table, "write_date", query), in_queue),
            tools.SQL("BOOL_OR(%s)", where(moved))))
        return {shard: (queued, oldest, bool(went))
                for shard, queued, oldest, went in rows}

    @api.model
    def _scoring_shard_evaluators(self, shard, shard_count, limit=None):
        """Up to ``limit`` submitted-and-queued evaluators owned by this shard
        (id %% shard_count == shard), DEALT across the assessments that have
        work rather than taken flat off the front of the queue. shard_count=1
        makes the modulo a no-op rather than taking a second code path, for the
        reason spelled out at the search below. The matching queue is selected
        whole and capped in Python because the deal cannot be written as a SQL
        LIMIT: the tick's budget goes round the queued papers one candidate at
        a time, so which ids it wants is not known until they have all been
        seen. Queued evaluators are bounded by the live cohort, so that read
        stays proportional to what is actually waiting.

        Candidates with a queued re-score request come first, in any
        `llm_state`, and are dealt the same way; the queue fills what is left.

        ``limit`` defaults to the configurable per-tick throughput knob
        (assessments_be_v2.scoring_tick_limit, default 20) so a mass-hiring
        drive can drain faster without a code change - bounded by Vertex quota.
        """
        if limit is None:
            limit = self._scoring_tick_limit()
        Evaluator = self.env["assessments.be.evaluator"]
        domain = self._scoring_queue_domain(
            self.SCORING_QUEUED_STATES + ("scoring",))
        # ONE PATH, ONE ORDER: `order="id"`, oldest first, at every shard
        # count. A bare search takes the model's `_order` (`create_date
        # desc`, newest first), so a separate 1-shard path would reverse the
        # queue discipline with one config value. shard_count=1 makes the
        # modulo a no-op, so there is no second path to disagree.
        # RE-SCORE REQUESTS GO FIRST. An admin is waiting on each one, and it
        # is a few answers, not a cohort. Any `llm_state`: a scored candidate
        # can have one answer re-graded.
        keyed = Evaluator.search([
            ("assessment_id.active", "=", True),
            ("assessment_id.state", "!=", "cancelled"),
            ("pii_anonymized", "=", False),
            ("state", "=", "submitted"),
            ("response_ids.rescore_request_key", "!=", False),
        ], order="id").filtered(lambda e: e.id % shard_count == shard)
        # A key on an answer that no longer needs the grader (its question
        # changed type) is never graded, and would head every tick (G1-18).
        stale = keyed.response_ids.filtered(
            lambda r: r.rescore_request_key and not r.needs_llm)
        if stale:
            stale.write({"rescore_request_key": False})
            keyed = keyed.filtered(
                lambda e: any(e.response_ids.mapped("rescore_request_key")))
        matching = Evaluator.search(domain, order="id").filtered(
            lambda e: e.id % shard_count == shard) - keyed
        first = self._deal_across_assessments(keyed, limit)
        return first + self._deal_across_assessments(
            matching, limit - len(first))

    @api.model
    def _deal_across_assessments(self, evaluators, limit):
        """Deal a tick's budget out across the assessments that have work.

        WHY NOT SIMPLY THE FIRST `limit`. Taking the lowest ids in the whole
        queue is a global FIFO with no fairness between papers, and on
        2026-09-18 that meant one assessment could not be graded at all. Four
        were queued at once: 442 candidates on ids 5446-6095, 26 on 6774-6799,
        53 on 7478-7536, and 217 on 11919-12619. Evaluator ids ascend with the
        roster, so the newest paper holds the highest ids and sat behind 521
        others. Every tick for two and a half hours took twenty candidates
        from the oldest cohort; the newest took 468 billable calls' worth of
        waiting and received none of them, with `llm_attempts` still 0 on
        every one of its answers.

        NOTHING REPORTED IT, and that is what made it expensive. The run was
        not stuck, cancelled or failing - the crons were alive, the spend cap
        was nowhere near, no answer was in error. An operator watching that
        paper saw a queue that never moved and a grader that was demonstrably
        running, which is indistinguishable from a bug in the grader.

        A DEAL, NOT A SORT. One candidate per assessment in turn until the
        tick's budget is spent, so a 445-candidate cohort slows the others
        down instead of stopping them. Within a paper the order is the id
        order it was handed, so it stays oldest-first and deterministic, and
        a single queued assessment gets exactly the tick it got before.
        """
        queues = {}
        for evaluator in evaluators:
            queues.setdefault(evaluator.assessment_id.id, []).append(
                evaluator.id)
        picked = []
        while len(picked) < limit and any(queues.values()):
            for queue in queues.values():
                if queue:
                    picked.append(queue.pop(0))
                    if len(picked) >= limit:
                        break
        return self.env["assessments.be.evaluator"].browse(picked)

    def action_export_results(self):
        self.ensure_one()
        from ..services import export as export_svc
        return export_svc.export_results(self)

    def action_regrade_for_component_scoring(self):
        """Send answers whose SHAPE changed back through the grader.

        WHY A RE-GRADE AND NOT A RECOMPUTE. `_recompute_question_marks` is
        enough whenever the arithmetic changed but the stored inputs did not.
        That is not the case for image labelling: the grader used to return one
        score for the whole answer and the platform now marks each BOX against
        the threshold, so a row scored under the old contract has no per-box
        raws on disk to re-aggregate. There is nothing to recompute from - the
        judge has to look at the answer again.

        image_ab rides along because the MEANING of its stored number changed
        rather than its shape: `llm_raw_100` used to hold the grader's
        0.75*verdict + 0.25*justification blend, and it now holds the
        justification alone. Left as-is, a perfect-verdicts answer would keep a
        stored 75-plus that reads as a strong write-up it never earned.

        CLEARING `llm_scored_hash` IS THE LOAD-BEARING PART. Re-queueing alone
        does nothing: `_enqueue_subjective_scoring` skips a response whose hash
        still matches its `justification`, which is exactly the case here - the
        candidate's text is unchanged, only our reading of it moved. Without
        this the action would report success and grade nothing.

        Nothing is deleted: the old `llm_raw_100` and audit columns stay until
        the grader overwrites them, so a run that is interrupted leaves the
        attempt readable rather than blank.
        """
        targets = self.env["assessments.be.response"]
        for rec in self:
            targets |= rec.response_ids.filtered(
                lambda r: (r.question_id.question_type
                           in ("image_label", "image_ab"))
                and r.llm_state in ("scored", "error"))
        if targets:
            targets.write({
                "llm_state": "pending",
                "llm_attempts": 0,
                "llm_scored_hash": False,
                "label_box_scores_json": False,
            })
            # `scoring_requested` / `llm_state` live on the EVALUATOR, not on
            # the assessment - the attempt is what queues for grading. Only the
            # attempts that actually own a re-queued answer are woken, so an
            # assessment with one stale labelling answer does not re-run its
            # whole cohort.
            targets.mapped("assessment_evaluator_id").write({
                "scoring_requested": True, "llm_state": "pending"})
        return {
            "type": "ir.actions.client",
            "tag": "display_notification",
            "params": {
                "title": "Re-queued for re-grading",
                "message": "Sent %d labelling / A-B answer(s) back to the "
                           "grader. Marks for every other question type are "
                           "recomputed without an LLM call." % len(targets),
                "type": "success", "sticky": False,
            },
        }

    def action_export_responses(self):
        self.ensure_one()
        from ..services import export as export_svc
        return export_svc.export_responses(self)


class EtpAssessmentEvaluator(models.Model):
    _name = "assessments.be.evaluator"
    _description = "Assessment Candidate Assignment"
    _order = "create_date desc"
    _rec_name = "applicant_id"

    assessment_id = fields.Many2one(
        "assessments.be", required=True, ondelete="cascade", index=True)
    applicant_id = fields.Many2one(
        "hr.applicant", string="Candidate", required=True, ondelete="restrict",
        # The roster joins on this for every candidate row it renders.
        index=True)
    candidate_name = fields.Char(
        related="applicant_id.partner_name", store=True, index=True,
        string="Candidate Name", readonly=True,
        help="Denormalised so the candidate list can be SORTED by the name it "
             "renders. `order='applicant_id'` delegates to hr.applicant's own "
             "_order, which is not alphabetical by name, so the CANDIDATE "
             "column would have sorted the roster by something the operator "
             "cannot see on it; `candidate_email` is not a substitute either, "
             "because an address stops tracking the name the moment it is not "
             "first.last (kritika.kumari@ vs Kritika Kumari).")
    candidate_email = fields.Char(
        related="applicant_id.email_from", store=True, index=True,
        string="Candidate Email", readonly=True,
        help="Denormalised so the candidate list can be searched by address, "
             "which is how an admin usually identifies one person on a large "
             "roster.")
    invite_state = fields.Selection(
        [("none", "Not Invited"), ("queued", "Queued"),
         ("sent", "Sent"), ("failed", "Failed")],
        default="none", index=True, copy=False, string="Invite",
        help="Invitation email status. Launch queues invites; a background cron "
             "sends them in batches so a large cohort never blocks the request.")
    invite_error = fields.Char(readonly=True, copy=False)

    def init(self):
        self._cr.execute("""
            CREATE UNIQUE INDEX IF NOT EXISTS assessments_be_evaluator_uniq_assess_appl
            ON assessments_be_evaluator (assessment_id, applicant_id)
        """)
        # THE PAGING INDEX for `_attempt_page`, which serves
        # `/api/v1/attempts` and `/api/v1/assessments/<id>/candidates`.
        #
        # `create_date` carries no index of its own, so a roster page is a bitmap
        # scan of the whole cohort followed by a sort. This composite can serve
        # the `assessment_id` equality AND the ordering in one scan, so the sort
        # disappears - the DESC/DESC mix does not defeat it, because with
        # `assessment_id` pinned the index's own order IS
        # `create_date DESC, id DESC`.
        #
        # IT DOES NOTHING TODAY, AND THAT IS AN HONEST REASON TO KEEP IT RATHER
        # THAN A HIDDEN COST. Measured on this schema with EXPLAIN (ANALYZE) on
        # the exact SQL `_attempt_page` emits:
        #
        #   cohort / table      plan WITH the index          plan WITHOUT
        #   400 / 400           Seq Scan + Sort (ignored)    identical
        #   507 / 2,538         Bitmap + quicksort (ignored) identical
        #   10,000 / 50,000     Index Only Scan, NO Sort     Bitmap + top-N sort
        #                       0.16 ms                      4.24 ms   (26x)
        #
        # At stage's shape (2,538 attempts, ~572 per cohort) the planner declines
        # it: 507 of 2,538 rows is cheap enough to bitmap-and-sort. It becomes
        # load-bearing somewhere between 500 and 10,000 rows in a single cohort,
        # which is inside this platform's design space - the CONCURRENTLY
        # migration next door sizes the answers table off "a 5,000-candidate
        # cohort". Creating it now means no deploy to remember at the point the
        # roster starts sorting five thousand rows per page on a two-second poll.
        #
        # WHAT IT DOES NOT HELP: the GLOBAL `/api/v1/attempts` listing. With no
        # `assessment_id` equality the leading column is unconstrained, so that
        # route plans as Seq Scan + top-N heapsort at every size measured (8.7 ms
        # at 50,000 rows) with or without this index. The route the Flutter
        # client polls every two seconds is therefore NOT the one this speeds up;
        # the per-assessment roster is.
        #
        # ONGOING COST is insert-only. `assessment_id`, `create_date` and `id`
        # are never written again after creation, so the frequent updates to
        # `state` / `score` / `invite_state` stay HOT-eligible and never touch
        # this index. 120 kB at stage's row count.
        #
        # IN init() AND NOT IN A MIGRATION, unlike the CONCURRENTLY build in
        # `migrations/19.0.3.17.0/pre-migrate.py`. A plain `CREATE INDEX` takes a
        # SHARE lock that blocks writes for the length of the build, and
        # CONCURRENTLY cannot be used here because `init()` runs inside the
        # upgrade transaction. Measured build times:
        #
        #   2,538 rows -> 4.6 ms (120 kB)    50,000 -> 27 ms (2 MB)
        #   500,006 rows -> 817 ms (19 MB)
        #
        # So the blocked-write window is milliseconds at any size this platform
        # is near, and `init()` is ALREADY taking that lock on this table one
        # statement above for the unique index - moving only the second of two
        # builds out of the transaction would buy nothing. The migration next
        # door exists because its table holds ~175,000 rows on a 5,000-candidate
        # cohort and the write it would block is a candidate answering a question
        # mid-exam; the writes this one blocks are roster and lifecycle writes.
        # If this table ever reaches a size where a sub-second stall matters, the
        # move is that CONCURRENTLY pattern, not a different index.
        #
        # `IF NOT EXISTS` keeps `init()` idempotent, which is what lets it run on
        # every upgrade.
        self._cr.execute("""
            CREATE INDEX IF NOT EXISTS assessments_be_evaluator_page_idx
            ON assessments_be_evaluator (assessment_id, create_date DESC, id DESC)
        """)

    @api.model
    def _be_search_domain(self, term):
        """The ONE name-or-email predicate for finding a candidate.

        Odoo's search view and the API MUST use this expression and no other.
        Two consumers spelling "find this candidate" differently is what
        produced D7: the Flutter Candidates tab filtered its own cache with
        Dart's `String.contains` while the server offered no search at all, so
        the two surfaces could not even be compared.

        Semantics are not invented here - this is the predicate already shipped
        in `views/assessment_views.xml` (`assessments_be_evaluator_search`),
        which is what produced the verified `aahan` behaviour on stage.
        `('applicant_id', 'ilike', term)` resolves
        through `hr.applicant`'s name search, so it matches a SUBSTRING and not
        a prefix: `aahan` selects both "Aahan Trikha" and "Jaahanvi".
        `candidate_email` is a stored, indexed related field on this model,
        denormalised for exactly this lookup.

        WHY `%` AND `_` ARE ESCAPED. Postgres `ILIKE` reads them as wildcards;
        Dart's `toLowerCase().contains()` reads them literally. Escaping makes
        the server match the client's literal reading, so moving a search box
        from local filtering to this predicate changes no result for any term a
        person actually types. It is also the one place this predicate and the
        XML `filter_domain` deliberately differ - the view cannot escape, and a
        `%` typed into Odoo's own search bar still behaves as a wildcard there.
        `tests/test_one_search_predicate_serves_both_uis.py` asserts the
        equality for every term without a wildcard in it and pins the exception.
        """
        term = (term or "").strip()
        if not term:
            return []
        # Backslash FIRST, or the escapes added below get escaped in turn.
        term = term.replace("\\", "\\\\").replace("%", r"\%").replace("_", r"\_")
        return ["|", ("applicant_id", "ilike", term),
                ("candidate_email", "ilike", term)]

    def _candidate_user(self):
        """The user allowed to sit this attempt.

        One line, because the walk itself lives on `hr.applicant` and is shared
        with the reverse lookup the candidate's own list uses. It used to be
        inlined here with an extra "reject internal users" rule the reverse
        lookup did not have, and the two disagreeing is what told an employee
        candidate that their own link belonged to somebody else.
        """
        self.ensure_one()
        applicant = self.applicant_id
        if not applicant:
            return self.env["res.users"].browse()
        # sudo because this runs on `auth="public"` routes (the exam gate and
        # the media proxies), where the caller has no ACL on hr.applicant.
        return applicant.sudo()._be_candidate_user()
    access_token = fields.Char(
        string="Access Token", index=True, copy=False,
        default=lambda self: str(uuid.uuid4()))
    candidate_link = fields.Char(
        string="Candidate's Assessment Link", compute="_compute_candidate_link",
        help="Deep link into the candidate app for this assignment. Share this "
             "with the candidate if the invitation email did not reach them; "
             "it opens the timed, proctored exam runner gated by the access "
             "token. The invitation email itself sends the app's front door "
             "instead - see candidate_home_url.")

    @api.depends("access_token")
    def _compute_candidate_link(self):
        # DELEGATES, and used to hold a second implementation.
        #
        # This built `<web.base.url>/pro_assessment/<token>` inline - the retired
        # QWeb runner's path - while `assessment_api.py` overrode the same method
        # to build the app's `/exam/<token>`. Two implementations, one of them
        # dead: `models/__init__.py` imports `assessment_api` after this module,
        # which puts it EARLIER in the registry class's MRO, so the override won
        # and this body never ran.
        #
        # Dead is not harmless when it is also wrong. Anything that reordered
        # those imports would have silently switched every candidate link back to
        # a path that no longer renders a page, and nothing here said so. There is
        # one implementation now - `_candidate_link_for`, in `assessment_api.py`,
        # which is where the origin resolution lives.
        for rec in self:
            rec.candidate_link = rec._candidate_link_for(rec.access_token)
    question_order = fields.Text(string="Shuffled Question Order (JSON)")
    started_at = fields.Datetime(string="Started At")
    # The runner tab that holds the sitting: the app's per-tab `session_key`,
    # stored by `/state` and `/begin`, so a write from an older tab is refused
    # (candidate.py, `_write_guard`). Never serialized.
    exam_session_key = fields.Char(copy=False, readonly=True)
    submitted_at = fields.Datetime(
        string="Submitted On", readonly=True, copy=False)
    deadline_datetime = fields.Datetime(
        string="Candidate Deadline", compute="_compute_deadline_datetime",
        store=True)
    state = fields.Selection(
        [
            ("pending", "Pending"),
            ("in_progress", "In Progress"),
            ("submitted", "Submitted"),
        ],
        default="pending",
        required=True,
    )
    # SORTING THE STATE COLUMN ALPHABETICALLY IS WRONG, which is what this
    # column exists to avoid. The stored keys are `pending`, `in_progress`,
    # `submitted`, so `ORDER BY state` hands an operator
    # `in_progress, pending, submitted` - the middle of the lifecycle first.
    # The one question the STATE header is clicked to answer during a live run
    # ("who has not started?") is therefore the one it answers worst.
    #
    # A STORED RANK AND NOT A CASE EXPRESSION, because `search(order=...)` takes
    # field names and nothing else: `ORDER BY CASE state WHEN ...` would need a
    # `_search` override, which is a far wider change than one integer column.
    #
    # INDEXED, AND NOT LOAD-BEARING TODAY. The roster's domain pins
    # `assessment_id`, which is indexed, so a cohort sort is a few hundred rows
    # with or without this - it earns its keep at the same size the composite
    # paging index in `init()` does, and it costs one small btree on an integer
    # written once per lifecycle transition.
    #
    # DELIBERATELY NOT DONE FOR `invite_state` OR `result`, and that asymmetry is
    # a decision rather than an oversight. Their alphabetical orders are
    # defensible (`failed, none, queued, sent` puts the invitations needing
    # attention first; `fail, pass, pending` groups the decided ones), and a rank
    # column per selection is three more columns to keep honest for no operator
    # complaint. `state` is the one whose alphabetical order actively misleads.
    state_rank = fields.Integer(
        compute="_compute_state_rank", store=True, index=True,
        string="State Order", readonly=True,
        help="Lifecycle position of `state`, for sorting the roster's STATE "
             "column in the order an operator reads it (Not started, In "
             "progress, Submitted) rather than alphabetically by stored key.")

    @api.depends("state")
    def _compute_state_rank(self):
        # THE ORDER IS READ OFF THE SELECTION ITSELF rather than written out
        # here a second time. A fourth state added to the field above would
        # otherwise keep ranking 0 and sort first for as long as nobody
        # remembered this method - a silently wrong column, which is exactly the
        # defect the field was added to close. An unrecognised value ranks LAST
        # for the same reason: it is visible at the end of the table instead of
        # pretending to be the earliest step.
        ranks = {key: position for position, (key, _label)
                 in enumerate(self._fields["state"].selection)}
        for rec in self:
            rec.state_rank = ranks.get(rec.state, len(ranks))

    total_questions = fields.Integer(
        compute="_compute_total_questions", store=True,
        string="Total Questions")
    answered_count = fields.Integer(
        compute="_compute_progress", store=True, string="Answered")
    total_score = fields.Integer(
        compute="_compute_progress", store=True, string="Total Score")
    max_possible_score = fields.Integer(
        compute="_compute_progress", store=True, string="Max Possible Score")
    response_ids = fields.One2many(
        "assessments.be.response", "assessment_evaluator_id",
        string="Responses")

    is_locked = fields.Boolean(default=False, string="Locked")
    is_violated = fields.Boolean(default=False, string="Violated", readonly=True)
    violation_reason = fields.Char(string="Violation Reason", readonly=True)
    violation_datetime = fields.Datetime(string="Violation Time", readonly=True)
    violation_count = fields.Integer(
        string="Violations", default=0, readonly=True,
        help="Cumulative count of detected violations for this candidate. "
             "Compared against assessment.max_violations to decide auto-submit.",
    )
    # The "AI: " violations, counted apart (`_record_violation`).
    ai_violation_count = fields.Integer(
        string="AI Violations", default=0, readonly=True,
        help="Cumulative count of AI proctoring violations for this "
             "candidate. Compared against assessment.ai_max_violations.",
    )
    # THE ONE PLACE the breach label is decided, so the admin rows, the
    # candidate's exam payload, the /violation reply and the Odoo form agree.
    # "The violation limit was reached", in either mode (owner, 24 Sep): under
    # Auto-submit it is why the paper ended, under Log only it is all that
    # happens. Cap 0 is "the first violation" under Auto-submit and "no limit"
    # under Log only, so it never shows there.
    violation_limit_breached = fields.Boolean(
        string="Violation Limit Breached",
        compute="_compute_violation_limit_breached",
        help="This candidate's violations reached the Violation Limit (the "
             "first violation when that is 0 under Auto-submit). Auto-submit "
             "ended the exam there; Log violation only did not.")
    ai_violation_limit_breached = fields.Boolean(
        string="AI Violation Limit Breached",
        compute="_compute_violation_limit_breached",
        help="This candidate's AI violations reached the AI Violation Limit, "
             "by the same rule as the Violation Limit.")

    @api.depends("violation_count", "assessment_id.violation_action",
                 "assessment_id.max_violations", "ai_violation_count",
                 "assessment_id.ai_violation_action",
                 "assessment_id.ai_max_violations")
    def _compute_violation_limit_breached(self):
        def breached(count, cap, action):
            # max(): a negative cap ends on the first violation too
            # (`_record_violation`'s `elif cap`), so it reads as 0 here.
            limit = max(cap or 0, 0) or (1 if action == "auto_submit" else 0)
            return bool(limit and (count or 0) >= limit)

        for rec in self:
            paper = rec.assessment_id
            rec.violation_limit_breached = breached(
                rec.violation_count, paper.max_violations,
                paper.violation_action)
            rec.ai_violation_limit_breached = breached(
                rec.ai_violation_count, paper.ai_max_violations,
                paper.ai_violation_action)

    violation_log = fields.Json(
        string="Violation Log", copy=False, readonly=True,
        help="Every violation with its timestamp, in the order they were "
             "recorded: [{'reason': str, 'at': iso}], plus 'client_at' (the "
             "client's own stamp, epoch ms) when it sent one, so a report "
             "sent again counts once. `violation_reason` and "
             "`violation_datetime` keep only the LATEST one, which reads as a "
             "single event to a reviewer answering an appeal; this is the full "
             "history. Appended inside the same atomic SQL that bumps the "
             "counter, so two beacons microseconds apart cannot lose an entry. "
             "It keeps the first 500; the count goes on past them.")
    ai_violation_log = fields.Json(
        string="AI Violation Log", copy=False, readonly=True,
        help="Every AI proctoring violation, in the same shape and with the "
             "same guarantees as the Violation Log, which no longer holds "
             "them.")
    # Reported by the exam page once its AI models load (R9d), so the admin
    # can tell an AI that never ran from a candidate who broke no rule.
    ai_status = fields.Selection(
        [("running", "AI proctoring running"),
         ("running_gaze", "AI proctoring and eye tracking running"),
         ("gaze_failed", "AI proctoring running, eye tracking could not start"),
         ("failed", "AI proctoring could not start")],
        string="AI Proctoring Status", readonly=True, copy=False,
        help="What the candidate's exam page reported once its AI proctoring "
             "started. Empty when the paper has no AI proctoring or the page "
             "never reported.")
    # NOT A VIOLATION, AND KEPT APART FROM ONE. A note for the reviewer from
    # the eye-movement pilot (`rule_gaze_review`); nothing that counts,
    # labels or ends a sitting reads it. The pilot is off for good (19 Oct),
    # so nothing writes it now; old rows still read and erase.
    review_flags = fields.Json(
        string="Review Flags", copy=False, readonly=True, default=list,
        help="Advisory notes for the reviewer, never counted as violations: "
             "[{'reason': str, 'at': iso}], at most 50 per attempt.")
    auto_submit_reason = fields.Selection(
        [("expired", "Time expired"),
         ("violation", "Proctoring violations"),
         ("ai_violation", "AI proctoring violations")],
        string="Auto-Submitted Because", readonly=True, copy=False,
        help="Why this attempt was ended for the candidate rather than by "
             "them. Empty when they submitted it themselves.",
    )

    llm_state = fields.Selection(
        [
            ("pending", "Pending"),
            ("scoring", "Scoring"),
            ("scored", "Scored"),
            ("partial", "Partial"),
            ("failed", "Failed"),
            ("error", "Scoring Error"),
            ("cancelled", "Cancelled"),
        ],
        default="pending",
        string="Subjective Scoring",
        copy=False,
        help="error = at least one of the candidate's answers hit a hard "
             "scoring error after all retries (surfaced, not silently scored). "
             "cancelled = an admin stopped the assessment's scoring run before "
             "this candidate was graded; it is a deliberate halt, not a fault, "
             "and any answer already scored keeps its mark.",
    )
    objective_total = fields.Integer(
        related="total_score", store=True, string="Objective Total", readonly=True)
    objective_max_total = fields.Integer(
        related="max_possible_score", store=True,
        string="Objective Max", readonly=True)
    llm_total_score = fields.Integer(
        compute="_compute_llm_progress", store=True, string="Subjective Total")
    llm_max_score = fields.Integer(
        compute="_compute_llm_progress", store=True, string="Subjective Max")
    subjective_pending = fields.Integer(
        compute="_compute_llm_progress", store=True, string="Subjective Pending")
    subjective_raw_percent = fields.Float(
        compute="_compute_llm_progress", store=True,
        string="Subjective Raw %",
        help="Mean of the grader's RAW 0-100 score across this candidate's "
             "scored subjective answers. NOT the mark: llm_score is an equal "
             "mark, 1 or 0 either side of the subjective threshold, so a "
             "candidate whose answers were talked up from 60 to 95 earns the "
             "same marks and moves this figure 35 points. That sensitivity is "
             "the point - it is what score_outlier measures. Display and "
             "integrity review only; never feeds a mark or pass/fail.")
    llm_scored_at = fields.Datetime(string="Subjective Scored At", readonly=True)
    #: Why the grader did not finish: a re-score that fails keeps the old mark
    #: and writes why here; a deferral for a spend cap or a 429 writes
    #: "waiting to be graded, no attempt used" here; a kill writes its reason
    #: here. Shown on the attempt form and as an optional roster column, so a
    #: silent failure does not read like a re-grade that confirmed the mark.
    llm_error = fields.Char(string="Subjective Error", readonly=True)
    unresolved_answer_count = fields.Integer(
        compute="_compute_rescore_state", string="Unresolved Answers",
        help="Answers on this attempt that need the grader and have no mark "
             "yet - exactly what a re-score with no chosen questions would "
             "queue.")
    rescore_queued_count = fields.Integer(
        compute="_compute_rescore_state", string="Re-scores Queued",
        help="Answers on this attempt with a re-score request waiting for the "
             "grader.")
    rescore_label = fields.Char(
        compute="_compute_rescore_state", string="Re-score Button Label")

    @api.depends("response_ids.needs_llm", "response_ids.llm_state",
                 "response_ids.rescore_request_key")
    def _compute_rescore_state(self):
        """What the attempt's one re-score button should say, and whether a
        request is already waiting.

        ONE BUTTON, labelled with the count of unresolved answers as the
        console's is, and hidden at zero - so the screen never offers a spend
        that cannot do anything.
        """
        for rec in self:
            unresolved = rec.response_ids.filtered(
                lambda r: r.needs_llm and r.llm_state != "scored")
            queued = rec.response_ids.filtered("rescore_request_key")
            rec.unresolved_answer_count = len(unresolved)
            rec.rescore_queued_count = len(queued)
            rec.rescore_label = (
                "Re-score %d answer(s)" % len(unresolved)
                if unresolved else "Re-score")
    # ── D1: the operator's manual flag and internal remark ───────────────
    #
    # ON THE ATTEMPT, NOT ON THE PERSON, and that is the whole design
    # decision. One sitting is what a reviewer actually looks at: "the webcam
    # showed a second person at 14:03" is a fact about THIS paper on THIS day,
    # and the same person sitting a different assessment next month has not
    # done anything. A person-level flag makes every later attempt arrive
    # pre-suspected with no way to say "that concern was about the other
    # sitting", which is a worse defect than having to raise the flag twice
    # when a concern genuinely spans both.
    #
    # REAL STORED COLUMNS, not a related onto `hr.applicant`. A related would
    # put the value in one place for every attempt the person has ever sat -
    # exactly the bleed above - and could not be written per attempt at all.
    # `index=True` because `manual_flagged_only` is a selective predicate the
    # roster route has to apply SERVER-SIDE under the 200-row clamp that
    # `paging()` enforces: filtering it in the client is precisely the defect
    # (C2) the search work exists to remove.
    #
    # FLAG AND REMARK ARE INDEPENDENT. `manual_flagged` is a bare boolean with
    # no reason text attached, and `manual_remark` is free text that stands on
    # its own: an operator can leave a note about a sitting without accusing
    # anybody, and can raise a flag without being made to write a sentence
    # first. Coupling them is what leaves stale flags standing (nobody could
    # phrase the justification) and notes unwritten (there was nothing to
    # flag). The route honours the same split - only the keys PRESENT in the
    # body change - so setting one never silently blanks the other.
    #
    # DISTINCT FROM THE THREE ADVISORY FLAGS BELOW, deliberately and
    # permanently. `integrity_alert`, `score_outlier` and `scoring_error_flag`
    # are machine-derived and recomputed; this one is only ever set by a person.
    # `flagged_only` on the API keeps meaning exactly those three, and the
    # manual flag gets its own `manual_flagged_only` parameter - folding it in
    # would silently change what every existing review-queue call returns
    # (requirement 3.6).
    #
    # INTERNAL. None of these four may appear on any candidate-facing payload
    # at any nesting depth; `tests/test_api_invariants.py` pins that as
    # INVARIANT 5 and walks every candidate serializer recursively to prove it.
    manual_flagged = fields.Boolean(
        index=True,
        copy=False,
        default=False,
        string="Flagged",
        help="An operator flagged THIS sitting. Advisory and admin-only; it "
             "never affects the score or the pass/fail result, it is never "
             "sent to the candidate, and it says nothing about the same "
             "person's other attempts.",
    )
    # READONLY AND STAMPED BY THE ROUTE, not typed. An operator editing "who
    # flagged this" would make the trail worth less than no trail at all.
    manual_flagged_by_id = fields.Many2one(
        "res.users",
        readonly=True,
        copy=False,
        ondelete="set null",
        string="Flagged By",
    )
    manual_flagged_at = fields.Datetime(
        readonly=True, copy=False, string="Flagged At")
    manual_remark = fields.Text(
        copy=False,
        string="Internal Remarks",
        help="The operator's note about this sitting. Stands alone - a remark "
             "needs no flag and a flag needs no remark. Internal only; never "
             "included in any candidate-facing response.",
    )

    scoring_error_flag = fields.Char(
        compute="_compute_scoring_error_flag", store=True, string="Scoring Error",
        help="Shows '!' when a subjective answer hit a terminal scoring error "
             "(Vertex failure): the candidate can't be finalized until an admin "
             "runs 'Reset & Re-score Errored'.")

    @api.depends("response_ids.llm_state")
    def _compute_scoring_error_flag(self):
        for rec in self:
            rec.scoring_error_flag = "!" if any(
                r.llm_state == "error" for r in rec.response_ids) else False

    integrity_alert = fields.Boolean(
        compute="_compute_integrity_alert", store=True,
        string="Integrity Alert",
        help="True when any of this candidate's answers tripped a scoring "
             "integrity signal (empty/injection gate or answer-key drift), so "
             "an admin can spot and filter flagged candidates. Display only; "
             "never affects the score or pass/fail.")

    @api.depends("response_ids.integrity_alert")
    def _compute_integrity_alert(self):
        for rec in self:
            rec.integrity_alert = any(
                r.integrity_alert for r in rec.response_ids)

    score_outlier = fields.Boolean(
        string="Score Outlier",
        compute="_compute_score_outlier", store=True,
        help="INTEGRITY REVIEW (advisory): True when this candidate's "
             "SUBJECTIVE score sits an unusual number of standard deviations "
             "ABOVE the cohort mean (see Settings 'Score-Outlier Review "
             "Sigma') - the net for a prompt-injection that dodged the answer "
             "gate and inflated a grader score. Subjective marks only: an "
             "objective answer is marked against a stored key, so there is "
             "nothing there to manipulate. Human-review signal only; never "
             "changes the score or pass/fail. Needs a cohort of at least %d "
             "submitted, fully graded candidates to fire."
             % SCORE_OUTLIER_MIN_COHORT)

    # DEPENDS ON THIS CANDIDATE ONLY - NOT ON THEIR PEERS.
    #
    # THE DEFECT, measured on stage at 100 concurrent candidates: 355 HTTP 500s
    # from `psycopg2.errors.SerializationFailure` on
    # `UPDATE assessments_be_evaluator SET score_outlier`, second only to
    # `response_count`.
    #
    # The depends used to walk `assessment_id.assessment_evaluator_ids.*` - the
    # SIBLING candidates. That is honest about the maths (an outlier is defined
    # relative to its cohort) and ruinous as an invalidation rule: any one
    # candidate's grader score changing marked the flag dirty on EVERY evaluator
    # row of the paper, so a single answer being scored issued N UPDATEs and N
    # candidates answering at once issued N**2. They then serialised against each
    # other, Odoo's `retrying()` slept up to ~30s across its 5 attempts, and
    # whichever request lost returned 500 - to a candidate, mid-exam, for an
    # advisory admin flag that "never changes the score or pass/fail".
    #
    # The cohort maths is UNCHANGED: the compute below still reads every peer, so
    # a flag it sets is exactly as correct as before. What is gone is the claim
    # that a peer's write should rewrite THIS row - it should not, because the
    # flag is only meaningful once the cohort is submitted and graded, which is
    # the moment `_recompute_cohort_outliers` now covers explicitly.
    #
    # NOT unstored, which was the other option and the wrong one here:
    # `controllers/api/admin._attempt_domain` puts this field in a SEARCH domain
    # for the flagged-review queue, and `assessment_views.xml` offers it as a
    # filter. A non-stored boolean cannot be searched without a `search=` method,
    # and hand-writing one for a cohort-relative z-score means reimplementing the
    # statistics in SQL - far more risk than the contention warrants.
    @api.depends("subjective_raw_percent", "llm_max_score",
                 "subjective_pending", "state")
    def _compute_score_outlier(self):
        # Cohort-relative z-score over the assessment's SUBMITTED peers. Grouping
        # by assessment keeps it O(cohort) and avoids a per-record cohort scan.
        # Advisory only: this flag never feeds _compute_result / pass-fail.
        #
        # THE SUBJECTIVE MARKS, NOT THE WHOLE SCORE. This measured
        # `score_percent` - the candidate's total across every question - which
        # made it fire for two reasons it was never meant to catch:
        #
        #   - On a purely OBJECTIVE assessment it could only ever mean "scored
        #     well". There is always a top scorer, so the best candidate in a
        #     cohort got flagged for integrity review on a paper where no
        #     grader was ever asked anything. A signal that fires on the
        #     honest case is one people learn to ignore, and it takes the two
        #     real signals down with it.
        #   - On a MIXED assessment it pointed at the wrong half: someone who
        #     aced the objective questions and was ordinary on the subjective
        #     ones could clear the threshold, sending a reviewer to read
        #     answers that were never in question.
        #
        # Injection is a conversation with a model. An objective answer is
        # compared to a stored key, so there is no conversation to have.
        #
        # THE RAW GRADER SCORE, NOT THE MARKS. `llm_total_score / llm_max_score`
        # would have been the obvious aggregate and it is the wrong one:
        # `llm_score` is an EQUAL MARK, 1 or 0 either side of the subjective
        # threshold. Talking the grader up from 60 to 95 on every answer earns
        # a candidate exactly the same marks, so the measure this is meant to
        # catch inflation with would not have moved at all.
        # `subjective_raw_percent` averages the grader's own 0-100, which is
        # the number an injection actually moves.
        raw = self.env["ir.config_parameter"].sudo().get_param(
            "assessments_be_v2.score_outlier_sigma",
            str(SCORE_OUTLIER_SIGMA_DEFAULT))
        try:
            sigma_k = float(raw)
        except (TypeError, ValueError):
            sigma_k = SCORE_OUTLIER_SIGMA_DEFAULT
        by_assessment = {}
        outliers = set()
        for rec in self:
            by_assessment.setdefault(rec.assessment_id.id, rec.assessment_id)
        for assessment in by_assessment.values():
            if not assessment:
                continue
            # `llm_max_score > 0` is what "this candidate answered something a
            # grader marked" means, so it doubles as the objective-only gate:
            # a paper with no subjective questions yields an empty cohort and
            # nobody is flagged.
            #
            # `subjective_pending` excludes anyone still being graded. A
            # half-marked candidate scores low for a reason that has nothing to
            # do with their answers, which would both spare a real outlier and
            # drag the mean down for everyone else.
            cohort = assessment.assessment_evaluator_ids.filtered(
                lambda e: e.state == "submitted"
                and (e.llm_max_score or 0) > 0
                and not e.subjective_pending)
            n = len(cohort)
            if sigma_k <= 0 or n < SCORE_OUTLIER_MIN_COHORT:
                continue
            scores = [e.subjective_raw_percent or 0.0 for e in cohort]
            mean = sum(scores) / n
            var = sum((s - mean) ** 2 for s in scores) / n
            stdev = math.sqrt(var)
            if stdev <= 0.0:
                continue  # a degenerate all-equal cohort has no outlier
            threshold = mean + sigma_k * stdev
            outliers.update(
                e.id for e, pct in zip(cohort, scores) if pct > threshold)
        # ONE ASSIGNMENT PER ROW. Setting False and then True would write an
        # unchanged outlier on every pass (`_recompute_cohort_outliers`).
        for rec in self:
            rec.score_outlier = rec.id in outliers

    def _recompute_cohort_outliers(self):
        """Re-evaluate the outlier flag across every peer on these papers.

        WHY THIS EXISTS. `_compute_score_outlier` is cohort-relative - one
        candidate's grader score moves the mean and the standard deviation, so it
        can make a DIFFERENT candidate an outlier or stop them being one. The
        depends used to express that by watching every sibling, which is what made
        a single answer issue an UPDATE per candidate and 100 concurrent
        candidates serialise into 355 HTTP 500s.

        So the recompute is triggered EXPLICITLY instead. The flag is advisory,
        admin-facing, and gated on `SCORE_OUTLIER_MIN_COHORT` submitted and
        fully-graded peers - so it has no meaning at all until well after the
        sitting, and nothing is lost by not maintaining it per keystroke.

        CALLED FROM `_cron_recompute_subjective_results`, once per paper
        `_outlier_stale_papers` returns. NEVER inline from `services.scoring`:
        there it wrote every peer row of the cohort inside the savepoint that
        also held the marks, so a collision between two lanes unwound the
        SCORES along with the statistic. See `score_outlier_stale`.

        Runs on the WHOLE cohort of each affected assessment, because that is the
        unit the statistic is defined over.
        """
        if not self:
            return
        cohort = self.env["assessments.be.evaluator"].search([
            ("assessment_id", "in", self.mapped("assessment_id").ids),
        ])
        if not cohort:
            return
        # READ THE STORED FLAGS FIRST, so only the rows whose flag flips are
        # written. The compute's assignment skips a value equal to the cached
        # one (`Field.write`), but only when there IS a cached one - without
        # this read every row of the paper is rewritten on every pass, and a
        # candidate mid-grade collides with it.
        cohort.fetch(["score_outlier"])
        # `add_to_compute` is the explicit force: it queues the field for
        # recomputation whether or not the ORM thinks anything it depends on
        # changed, which is exactly the case here now that the peer-depends is
        # gone. Verified on the live registry - `records_to_compute` is non-empty
        # after this call - because `modified()` alone reads as if it should work
        # and there is no recordset-level `recompute()` in Odoo 19 to pair it with.
        self.env.add_to_compute(cohort._fields["score_outlier"], cohort)
        # ONE flush for the whole cohort. Left to the ORM these would land as one
        # write per candidate, which is the pattern being removed.
        cohort.env.flush_all()

    @api.model_create_multi
    def create(self, vals_list):
        """Roster a candidate and assign them - BOTH LINKS, as remove already does.

        `action_remove_from_assessment` states the rule for the REMOVE
        direction: a candidate is on an assessment twice over, as this attempt
        row and as an entry in the `evaluator_ids` m2m, and dropping only one
        of them leaves a roster that disagrees with itself. Nothing did the ADD
        half. `_sync_roster_rows` goes m2m -> rows and nothing came back, while
        the Candidates tab's inline list writes rows directly - so Assign
        Candidates > Add a line > pick > Save filled the roster table and left
        the m2m empty, and Launch & Invite then answered "Please assign at
        least one candidate before starting", because `action_start` gates on
        the m2m. Past that gate it was no better: the draw loop iterates the
        m2m too, so that candidate would have been launched with no
        `question_order` and no invitation - a paper that reads as ready and
        serves nobody.

        IN `create` AND NOT IN THE FORM'S ONCHANGE, so all four paths that write
        a row are covered at once: the o2m inline list, a direct create, the CSV
        import and the API assign route.

        ONLY WHAT IS MISSING, AND (4, id) WHICH IS A LINK. The rows
        `_sync_roster_rows` creates are made FROM the m2m and are already
        assigned, so that path writes nothing here and the two syncs cannot
        bounce. It also matters inside `action_start`, which creates rows while
        iterating `evaluator_ids` - writing into a recordset mid-iteration is a
        bug waiting for a cohort big enough to show it.

        sudo on the assessment because not every path that rosters somebody
        carries write access to the assessment itself (the API assign route
        runs it explicitly): the link is bookkeeping for a row the ORM has just
        accepted, not a fresh grant.
        """
        rows = super().create(vals_list)
        by_assessment = {}
        for row in rows:
            # A row with no candidate cannot be assigned to anybody. `required`
            # normally refuses it first; this does not depend on that.
            if row.applicant_id and row.assessment_id:
                by_assessment.setdefault(row.assessment_id.id, set()).add(
                    row.applicant_id.id)
        Assessment = self.env["assessments.be"].sudo()
        for assessment_id, applicant_ids in by_assessment.items():
            assessment = Assessment.browse(assessment_id)
            missing = applicant_ids - set(assessment.evaluator_ids.ids)
            if missing:
                assessment.write(
                    {"evaluator_ids": [(4, aid) for aid in sorted(missing)]})
        return rows

    def write(self, vals):
        if vals.get("state") == "submitted":
            stamp = fields.Datetime.now()
            for rec in self.filtered(lambda r: not r.submitted_at):
                super(EtpAssessmentEvaluator, rec).write(
                    {"submitted_at": stamp})
        res = super().write(vals)
        # "Grade subjective answers automatically" so the every-minute cron
        # (_cron_llm_auto_score) drains it: the Vertex call happens in the cron,
        # never in this request. Respects the per-assessment llm_auto_score
        # toggle (default OFF while the Vertex budget is frozen).
        if vals.get("state") == "submitted":
            to_queue = self.filtered(
                lambda r: r.assessment_id.llm_auto_score
                and not r.scoring_requested and any(
                    resp.needs_llm and resp.llm_state != "scored"
                    for resp in r.response_ids))
            if to_queue:
                super(EtpAssessmentEvaluator, to_queue).write(
                    {"scoring_requested": True, "llm_state": "pending"})
        return res

    score_percent = fields.Float(
        string="Score %", compute="_compute_result", store=True,
        aggregator="avg")
    score_marks_display = fields.Char(
        string="Score", compute="_compute_score_marks_display", store=True,
        help="Result expressed as whole marks (earned / marks available), the "
             "pass/fail view of the score. The denominator is the paper's "
             "COMPONENT count - one mark per keyed sub-question, per graded "
             "written answer and per labelling box set - so it is larger than "
             "the question count.")
    raw_result = fields.Float(
        string="Raw Score", compute="_compute_raw_result", store=True,
        digits=(16, 3),
        help="Secondary score: every component contributes its ungated quality "
             "as a 0-1 fraction INSTEAD of the thresholded mark - a keyed "
             "sub-question contributes its own mark, a written answer the "
             "grader's 0-100 as a fraction, a labelling answer the mean of its "
             "box raws. Read it out of `raw_max`, never alone.")
    raw_max = fields.Integer(
        string="Raw Available", compute="_compute_raw_result", store=True,
        readonly=True, copy=False,
        help="What `raw_result` is out of: the paper's component count, taken "
             "from the frozen draw rather than from the answers, so an "
             "abandoned question still occupies its share.")
    raw_percent = fields.Float(
        string="Raw %", compute="_compute_raw_result", store=True,
        readonly=True, copy=False,
        help="raw_result over the same denominator score_percent uses. The two "
             "measure one paper two ways: score_percent counts components that "
             "cleared the bar, raw_percent counts how close each one came.")
    pass_threshold = fields.Float(
        string="Pass Threshold %", compute="_compute_result", store=True,
        # SAYS WHY IT CANNOT BE TYPED IN: this is the per-candidate copy of the
        # assessment's setting, and the help names where to change it.
        help="Read-only: the assessment's Pass Threshold (%) for this "
             "candidate (its Subjective Pass Threshold while that is not "
             "set). Change it on the assessment, not here - results are "
             "re-decided without re-grading.")
    result = fields.Selection(
        [("pending", "Pending"), ("pass", "Pass"), ("fail", "Fail")],
        string="Result", compute="_compute_result", store=True, default="pending")
    results_released = fields.Boolean(
        string="Results Released", default=False,
        help="Gates candidate-facing results. An admin flips this by "
             "releasing results; until then the candidate sees no score.",
    )
    pii_anonymized = fields.Boolean(
        string="PII Anonymized", default=False, copy=False, readonly=True,
        help="True once this attempt's candidate free-text/PII has been scrubbed "
             "(by the retention cron or the 'Erase Candidate Data' action). "
             "Numeric scores and pass/fail are retained; only the person's words "
             "are removed.")
    scoring_requested = fields.Boolean(
        string="Subjective Grading Requested", default=False, copy=False,
        help="Set by 'Run Subjective Evaluation'. The background grader drains "
             "requested candidates in batches of 20; subjective scoring never "
             "runs during the exam.",
    )

    result_summary = fields.Html(
        string="Result Summary", compute="_compute_result_summary",
        sanitize=False,
        help="Post-scoring overview for this candidate: objective and "
             "subjective tallies, total, percentage, and pass/fail.")
    result_summary_public = fields.Html(
        string="Result Summary (Candidate)", compute="_compute_result_summary",
        sanitize=False,
        help="Candidate-facing variant of result_summary: the same cells "
             "without the internal descriptor sub-labels (pass/fail marks over "
             "the paper's components, the ungated raw of the graded components "
             "alone, threshold).")

    @api.depends(
        "state", "result", "score_percent", "pass_threshold",
        "total_score", "max_possible_score", "raw_result",
        "llm_total_score", "llm_max_score", "subjective_pending",
        "answered_count", "total_questions", "violation_count",
        # The card's denominator is `_paper_component_totals`, which reads the
        # frozen draw and each drawn question's component count - so the draw
        # belongs in the trigger list beside the answers.
        "question_order", "response_ids.question_id",
        "response_ids.state", "response_ids.has_objective",
        "response_ids.score", "response_ids.max_score",
        "response_ids.needs_llm", "response_ids.llm_state",
        "response_ids.llm_passed")
    def _compute_result_summary(self):
        import html as _html

        def esc(v):
            return _html.escape(str(v))

        for rec in self:
            submitted = rec.response_ids.filtered(
                lambda r: r.state == "submitted")
            obj = submitted.filtered(lambda r: r.has_objective)
            obj_total = len(obj)
            obj_correct = len(obj.filtered(
                lambda r: r.max_score and r.score >= r.max_score))
            subj = submitted.filtered(lambda r: r.needs_llm)
            subj_total = len(subj)
            subj_scored = subj.filtered(lambda r: r.llm_state == "scored")
            subj_pass = len(subj_scored.filtered("llm_passed"))

            obj_pts = rec.total_score or 0
            sub_pts = rec.llm_total_score or 0
            total_pts = obj_pts + sub_pts
            thr = rec.pass_threshold or 0.0

            if rec.state != "submitted":
                rec.result_summary = (
                    '<div class="alert alert-info mb-0" role="status">'
                    'Candidate has not submitted yet - '
                    f'{esc(rec.answered_count or 0)} of '
                    f'{esc(rec.total_questions or 0)} answered. '
                    'Summary appears once the assessment is submitted and '
                    'scored.</div>')
                rec.result_summary_public = rec.result_summary
                continue

            if rec.result == "pass":
                badge = ('<span class="badge text-bg-success" '
                         'style="font-size:1rem;padding:0.5em 0.9em">PASS</span>')
            elif rec.result == "fail":
                badge = ('<span class="badge text-bg-danger" '
                         'style="font-size:1rem;padding:0.5em 0.9em">FAIL</span>')
            else:
                badge = ('<span class="badge text-bg-secondary" '
                         'style="font-size:1rem;padding:0.5em 0.9em">'
                         'PENDING</span>')

            pending_note = ""
            if rec.subjective_pending:
                pending_note = (
                    '<div class="alert alert-warning mt-2 mb-0 py-1 px-2" '
                    'role="status">'
                    f'\u26a0 {esc(rec.subjective_pending)} subjective '
                    'response(s) still awaiting scoring - totals below are '
                    'not final.</div>')

            def cell(label, value, sub="", show_hints=True):
                sub_html = (f'<div class="text-muted small">{sub}</div>'
                            if (sub and show_hints) else "")
                return (
                    '<div style="flex:1;min-width:120px;padding:0.4em 0.6em">'
                    f'<div class="text-muted small text-uppercase">{label}</div>'
                    f'<div style="font-size:1.15rem;font-weight:600">{value}</div>'
                    f'{sub_html}</div>')

            # Score = marks earned over what the DRAWN PAPER is worth in
            # COMPONENTS: one mark per keyed sub-question, one per graded
            # written answer, one per labelling box set.
            #
            # THE NUMERATOR AND THE DENOMINATOR MUST COUNT THE SAME THING.
            # `total_pts` has been a component tally ever since a question
            # stopped being worth a flat 1, but this line kept dividing it by a
            # QUESTION COUNT, so any paper with multi-part questions printed an
            # impossible card - "12 / 8" on an eight-question paper. Calling
            # `_paper_component_totals` is not a nicety: it is the same helper
            # `_compute_result` and `_compute_score_marks_display` use, so the
            # card, the stored "7 / 18" string and the percentage are now three
            # readings of one number instead of three chances to disagree.
            total_denom, _raw_denom = rec._paper_component_totals()

            def build_card(show_hints):
                cells = []
                cells.append(cell(
                    "Objective",
                    f"{esc(obj_correct)} / {esc(obj_total)} correct")
                    if obj_total else "")
                if subj_total:
                    cells.append(cell(
                        "Subjective",
                        f"{esc(subj_pass)} / {esc(subj_total)} passed"))
                cells.append(cell(
                    "Total Marks",
                    f"{esc(total_pts)} / {esc(total_denom)}",
                    "pass/fail marks over the paper's components",
                    show_hints=show_hints))
                cells.append(cell(
                    "Raw Score",
                    # OUT OF ITS TOTAL, like the mark beside it. A bare
                    # "11.900" is unreadable without the denominator, and the
                    # hint underneath still said "graded components only" -
                    # true before every component carried a raw, and stale
                    # ever since.
                    f"{esc('%.2f' % (rec.raw_result or 0.0))} / "
                    f"{esc(str(rec.raw_max or 0))}",
                    "every component, ungated 0-1 each",
                    show_hints=show_hints))
                cells.append(cell(
                    "Score (%)",
                    f"{esc(round(rec.score_percent or 0.0, 2))}%",
                    f"threshold {esc(round(thr, 2))}%",
                    show_hints=show_hints))
                if rec.violation_count:
                    cells.append(cell(
                        "Violations", esc(rec.violation_count)))
                row = "".join(c for c in cells if c)
                return (
                    '<div class="border rounded p-2" '
                    'style="background:#f8f9fa">'
                    '<div style="display:flex;align-items:center;gap:0.75em;'
                    'flex-wrap:wrap">'
                    f'<div>{badge}</div>'
                    '<div style="display:flex;flex-wrap:wrap;flex:1">'
                    f'{row}</div></div>'
                    f'{pending_note}</div>')

            rec.result_summary = build_card(show_hints=True)
            rec.result_summary_public = build_card(show_hints=False)

    @api.depends("response_ids.needs_llm", "response_ids.llm_score",
                 "response_ids.llm_max_score", "response_ids.llm_state",
                 "response_ids.llm_raw_100")
    def _compute_llm_progress(self):
        for rec in self:
            need = rec.response_ids.filtered(lambda r: r.needs_llm)
            scored = need.filtered(lambda r: r.llm_state == "scored")
            rec.llm_total_score = sum(scored.mapped("llm_score"))
            rec.llm_max_score = sum(need.mapped("llm_max_score"))
            # A terminal 'error' (e.g. a Vertex outage, not the candidate's
            # fault) is counted as UNRESOLVED on purpose: it holds the result on
            # 'pending' so an admin can re-score it (Retry Failed Scoring or
            # the attempt's "Re-score N answer(s)"), rather than silently
            # finalizing a wrongful 0/FAIL. The '!' scoring_error_flag surfaces
            # it in the candidate list. (Audit H-9 proposed auto-releasing on
            # error; we deliberately do NOT, to avoid mis-failing on infra faults.)
            rec.subjective_pending = len(need.filtered(
                lambda r: r.llm_state in (
                    "pending", "queued", "failed", "error")))
            # Averaged over the answers actually SCORED, not over every
            # subjective answer: an ungraded one is not a zero, and dividing by
            # it would read as a candidate who did badly. `subjective_pending`
            # above is what says the figure is still provisional, and
            # `_compute_score_outlier` refuses to compare a candidate until it
            # is clear.
            rec.subjective_raw_percent = (
                sum(scored.mapped("llm_raw_100")) / len(scored)
            ) if scored else 0.0

    def _paper_component_totals(self):
        """(marks, raw_marks) the DRAWN paper is worth, question by question.

        THE DENOMINATOR IS THE PAPER, NOT THE ANSWERS. `question_order` is the
        candidate's frozen draw, so this counts every question they were given
        whether or not they opened it - abandoning a question scores 0 out of
        its marks rather than quietly leaving the total. Attempt 740 was an
        8-question paper scored out of 3 and reported 100% PASS; counting from
        the draw is what stops that, and moving to per-component marks does not
        change it, only makes the numbers finer.

        Falls back to the response rows when a draw was never recorded (a row
        created but never launched), which is the same fallback the previous
        question-count denominator used.
        """
        self.ensure_one()
        try:
            order = json.loads(self.question_order or "[]")
        except (ValueError, TypeError):
            order = []
        questions = self.env["assessments.be.question"].browse(
            [q for q in order if q]).exists() if order else None
        if not questions:
            questions = self.response_ids.mapped("question_id")
        marks = raw_marks = 0
        for q in questions:
            m, r = q._component_counts()
            marks += m
            raw_marks += r
        return marks, raw_marks

    @api.depends("response_ids.final_mark", "subjective_pending", "state",
                 "question_order", "response_ids.question_id",
                 "assessment_id.subjective_threshold",
                 "assessment_id.pass_threshold")
    def _compute_result(self):
        for rec in self:
            threshold = rec.assessment_id._effective_pass_threshold()
            if not (0.0 <= threshold <= 100.0):
                threshold = DEFAULT_SUBJECTIVE_THRESHOLD
            rec.pass_threshold = threshold
            earned = sum(rec.response_ids.mapped("final_mark"))
            possible, _raw_possible = rec._paper_component_totals()
            rec.score_percent = round(
                (earned / possible) * 100.0, 2) if possible else 0.0
            if rec.state != "submitted" or rec.subjective_pending or not possible:
                rec.result = "pending"
            else:
                rec.result = "pass" if rec.score_percent >= threshold else "fail"

    @api.depends("response_ids.final_mark", "question_order",
                 "response_ids.question_id")
    def _compute_score_marks_display(self):
        """Whole-marks view of the score ('7 / 18'): earned marks over the same
        denominator _compute_result uses, so the two never disagree.

        TWO INTEGERS, ALWAYS. Every component awards 1 or 0, so the sum cannot
        come out fractional. This used to print '4.25 / 10', which the client
        parses with `int.tryParse`: it read null, dropped the server's own
        total and fell back to re-deriving the score locally from whatever
        answers the screen happened to be holding. `round()` guards the float
        sum, nothing more.

        The numbers are LARGER than they used to be - a paper's denominator is
        now its component count, not its question count - but the shape the
        client parses is unchanged."""
        for rec in self:
            earned = sum(rec.response_ids.mapped("final_mark"))
            possible, _raw_possible = rec._paper_component_totals()
            rec.score_marks_display = "%d / %d" % (round(earned), possible)

    @api.depends("response_ids.raw_score", "question_order",
                 "response_ids.question_id")
    def _compute_raw_result(self):
        """The RAW total: ungated quality over EVERY component on the paper.

        SAME DENOMINATOR AS `score_percent`, deliberately. The two used to
        divide by different things - marks by every component, raw by the
        LLM-graded ones alone - so "3 / 5" and "1.40 / 2" appeared side by side
        on one screen describing one attempt, and no reader could tell that
        apart from a bug. They are now the same fraction measured two ways: the
        marks count components that cleared their bar, the raw counts how close
        each one came.

        Read beside `score_percent`, not instead of it. Only marks decide pass
        or fail.
        """
        for rec in self:
            raw_pts = sum(r.raw_score or 0.0 for r in rec.response_ids)
            rec.raw_result = round(raw_pts, 3)
            _possible, raw_possible = rec._paper_component_totals()
            # STORED, so the API can send the denominator with the numerator.
            # It could not before: the attempt payload carried `raw_result`
            # alone and the client re-derived the "/ N" by summing `raw_max`
            # across the answer rows - which only the detail route sends, so
            # every list route printed a bare raw with nothing to read it
            # against.
            rec.raw_max = raw_possible
            rec.raw_percent = round(
                (raw_pts / raw_possible) * 100.0, 2) if raw_possible else 0.0

    @api.model
    def _answers_scored_domain(self, scored=True):
        """Domain for "Scored" by the ANSWERS: submitted, and no answer that
        needs the grader is left unscored. ``scored=False`` is its complement
        among submitted attempts, "Score Pending".

        The candidate-level `llm_state` cannot answer this: an objective-only
        paper is never graded, so it never reaches `scored` and the tally
        counted it as unscored for ever. One definition, used by the "Scored
        X/Y" line and the queue click, so the two cannot disagree.
        """
        unscored = [("needs_llm", "=", True), ("llm_state", "!=", "scored")]
        return [("state", "=", "submitted"),
                ("response_ids", "not any" if scored else "any", unscored)]

    def _compute_subjective_rollup(self):
        for rec in self:
            need = rec.response_ids.filtered(lambda r: r.needs_llm)
            if not need:
                state = "scored"
            elif all(r.llm_state in ("scored", "error") for r in need):
                if any(r.llm_state == "error" for r in need):
                    state = "error"
                else:
                    state = "scored"
                    # Stamped when the attempt BECOMES scored (a grading run
                    # always passes through `scoring` first), not on every
                    # rollup: an image_ab verdict-only answer is "scored" at
                    # save, so each of its autosaves re-stamped this.
                    if rec.llm_state != "scored":
                        rec.llm_scored_at = fields.Datetime.now()
            elif any(r.llm_state == "failed" for r in need):
                state = "partial" if any(
                    r.llm_state in ("scored", "error") for r in need) else "failed"
            elif any(r.llm_state in ("scored", "error") for r in need):
                state = "partial"
            else:
                state = "pending"
            # Compared first: an ORM assignment of the SAME value still bumps
            # `write_date`, so every autosave of a subjective answer was an
            # UPDATE of the attempt row that changed nothing.
            if rec.llm_state != state:
                rec.llm_state = state

    def _send_single_invitation(self):
        """Mail the invitation, and REPORT what did not go out.

        Returns a dict of {evaluator id: reason} for every record this could
        not actually mail; an empty dict means every one was handed to the
        mail layer. The caller stamps `invite_state` from that, because both
        no-send paths below used to `return`/`continue` silently and the
        drainer wrote "sent" regardless - so an admin read "sent" beside a
        candidate who never got a link, and `action_requeue_invitation` SKIPS
        `sent` rows, leaving no way to retry short of editing the database.

        WHY A RETURN VALUE AND NOT AN EXCEPTION. The no-email branch
        deliberately creates a cancelled `mail.mail` carrying the portal link
        so an admin can pass it on by hand. The drainer calls us inside
        `self.env.cr.savepoint()`, so raising would roll that audit row back
        and destroy the one artefact that makes the failure recoverable.
        """
        unsent = {}
        tpl = self.env.ref(
            "assessments_be_v2.mail_template_candidate_invitation",
            raise_if_not_found=False)
        if not tpl:
            # The template is missing (an incomplete upgrade, or someone
            # deleted it). Nothing can be mailed, and every record must say so
            # rather than be marked sent.
            reason = ("The candidate invitation email template is missing, so "
                      "no invitation could be sent. Reinstall or upgrade "
                      "assessments_be_v2 to restore it.")
            return {rec.id: reason for rec in self}
        for rec in self:
            # The drainer already skips these; this is the one place every
            # send passes, so nothing else can mail a link the gate refuses.
            if rec.assessment_id.state != "in_progress":
                unsent[rec.id] = (
                    "Not sent: the assessment is %s, so the exam link would "
                    "not open." % rec.assessment_id.state)
                continue
            emp = rec.applicant_id
            to_email = (emp.email_from or
                        (emp.be_candidate_user_id.email
                         if emp.be_candidate_user_id else "") or "")
            if not to_email:
                # Through _candidate_link_for, not an inline portal URL: this
                # addon is headless and `/pro_assessment/*` belongs to the
                # module being decommissioned, so the inline form wrote a link
                # that will 404. The helper returns the Flutter app URL when
                # `candidate_app_base_url` is set.
                #
                # The token in this link is the exam credential, and it lands in
                # `failure_reason` - the one mail-metadata field that carries a
                # live token to every caller of the record-scoped email route.
                # It is masked by _PORTAL_LINK_RE in serializers.py, which MUST
                # match both link shapes this helper can return.
                link = rec._candidate_link_for(rec.access_token)
                self.env["mail.mail"].sudo().create({
                    # Filed against the attempt, as `send_mail` files a real
                    # invitation, or no Emails tab can ever show it.
                    "model": rec._name,
                    "res_id": rec.id,
                    "subject": f"[NO EMAIL] {rec.assessment_id.name}",
                    "body_html": tpl._render_field("body_html", rec.ids)[rec.id],
                    "email_to": "",
                    "state": "cancel",
                    "failure_reason": f"No email on candidate "
                                      f"{emp.partner_name!r}. "
                                      f"Portal link: {link}",
                    "auto_delete": False,
                })
                unsent[rec.id] = (
                    "No email address on candidate %s, so the invitation could "
                    "not be sent. The exam link is on the cancelled email "
                    "logged against this candidate - add an address and "
                    "requeue, or pass the link on by hand."
                    % (emp.partner_name or "?"))
                continue
            mail_id = tpl.send_mail(rec.id, force_send=True)
            # A REFUSED SEND DOES NOT RAISE. `force_send` hands the mail to
            # `mail.mail.send(raise_exception=False)`, which marks it
            # `exception` and returns, so "no exception" read as "delivered":
            # on stage (19 Oct 2026, its mail server deleted) every invitation
            # died with "Connection refused" and every attempt read `sent`,
            # which `action_requeue_invitation` skips.
            mail = self.env["mail.mail"].sudo().browse(mail_id).exists()
            if mail.state == "exception":
                unsent[rec.id] = (
                    "The mail server did not take the invitation (%s). Fix "
                    "the outgoing mail server, then requeue."
                    % " ".join((mail.failure_reason
                                or "no reason given").split())[:200])
        return unsent

    def _deliver_invitation(self):
        """Deliver one invitation, returning the reason it did not go out.

        None means it reached the mail layer. The drainer writes `invite_state`
        from this rather than assuming success.
        """
        self.ensure_one()
        user = self.applicant_id.be_candidate_user_id
        if user and not user.login_date and not user._is_internal():
            user.sudo().with_context(
                create_user=1, import_file=False, install_mode=False,
            ).action_reset_password()
        return self._send_single_invitation().get(self.id)

    #: The browser's camera rules prefix their reasons with this
    #: (`web/proctor_ai.js`); those violations count apart (R5).
    AI_REASON_PREFIX = "AI: "
    #: (count, log) column pair per kind, keyed on "is it an AI reason". The
    #: only names `_record_violation` formats into its SQL.
    _VIOLATION_COLUMNS = {False: ("violation_count", "violation_log"),
                          True: ("ai_violation_count", "ai_violation_log")}
    #: Entries each log keeps (`_record_violation`); the count goes on.
    VIOLATION_LOG_CAP = 500

    def _counts_as_ai(self, reason):
        """Whether ``reason`` goes on the AI pair: an "AI: " reason on a paper
        whose AI proctoring is on, or from a page that reported its AI running
        (`ai_status`, only accepted while the rule is on) - an admin turning a
        misfiring AI off mid-sitting must not move its flags onto the regular
        cap. Otherwise no AI rule is watching, so the prefix comes from a stale
        or tampered client and the reason is held to the regular cap it would
        otherwise dodge."""
        self.ensure_one()
        return bool(reason.startswith(self.AI_REASON_PREFIX)
                    and (self.assessment_id.rule_ai_proctor
                         or self.ai_status in ("running", "running_gaze",
                                               "gaze_failed")))

    def _record_violation(self, reason, client_at=None):
        """Count one proctoring violation and log it, deduping a burst.

        ONE COPY OF THIS RULE, ON THE MODEL. It lived twice - once in the JSON
        candidate controller and once in the portal controller - and the two
        drifted: a fix to the dedupe or the counter had to be made in both, and
        a violation logged through one path looked different from the same
        violation logged through the other. Both call sites now delegate here,
        so there is a single definition of what a violation is.

        THE 1.2s SAME-REASON BURST DEDUPE, UNCHANGED. A single physical action
        (switching tabs while fullscreen) fires several client events -
        visibilitychange, fullscreenchange, blur - and each beacons here. A
        repeat of the SAME reason within 1.2s of the last recorded one folds
        into it, so one action counts once; two genuinely different reasons
        back-to-back both count. Keyed on reason, not time alone, for exactly
        that reason. A deduped beacon returns None and writes nothing - not the
        counter, not the log - so a burst counts once AND logs once.

        THE COUNTER AND THE LOG MOVE IN ONE ATOMIC UPDATE. Two beacons arriving
        microseconds apart must not lose an increment OR a log entry, which is
        why the count was already raw SQL and why the append rides the same
        statement: `violation_log = COALESCE(violation_log,'[]'::jsonb) ||
        %s::jsonb`. A read-modify-write of the JSON in Python would drop one of
        two concurrent entries the same way a read-modify-write of the counter
        would drop an increment.

        RETURNS the raw new count so a caller can decide whether to end the
        sitting. The end decision itself stays with the caller: 'Log only
        means log only' is enforced there, and the two controllers auto-submit
        through different helpers, so folding the decision in here would force
        one of them to change behaviour.

        A REPORT SENT AGAIN COUNTS ONCE. `client_at` is the client's own stamp
        for the report (epoch milliseconds). A client that got no reply sends
        the same report again, and a reply lost on the way back would
        otherwise count it twice - at a cap of 2, one reload ending the exam.
        The stamp is kept on its log entry, and an entry with the SAME stamp
        already in the log makes this a no-op that returns None. EXACT match
        only: "at or below the last" would let one huge stamp silence every
        later report. No stamp (an older client, the portal) is today's
        behaviour.

        AN "AI: " REASON COUNTS ON ITS OWN PAIR (R5), on a paper with AI
        proctoring on (`_counts_as_ai`): `ai_violation_count` and
        `ai_violation_log`, chosen inside the same statement, and the RETURNED
        count is that kind's. The stamp is looked up in that kind's log. The
        latest-violation fields stay shared, and the 1.2s fold compares
        reasons, so the two kinds never fold into each other.
        """
        self.ensure_one()
        count_col, log_col = self._VIOLATION_COLUMNS[self._counts_as_ai(reason)]
        last_at = self.sudo().violation_datetime
        last_reason = self.sudo().violation_reason or ""
        # TO THE MICROSECOND, on both sides. `fields.Datetime.now()` drops
        # them, so the stored time and "now" were whole seconds and two tab
        # switches 1.8s apart (x.1s and x+1.9s read as x and x+1) folded into
        # one. `violation_datetime` keeps the microseconds written here (the
        # ORM stores what it is given); `violation_log` and the API still show
        # whole seconds.
        now = datetime.now()
        if (last_at and last_reason == reason
                and (now - last_at).total_seconds() < 1.2):
            _logger.info(
                "VIOLATION deduped same-reason burst within 1.2s "
                "evaluator=%s applicant=%s reason=%s (kept prior count)",
                self.id, self.applicant_id.id, reason)
            return None
        logged = {"reason": reason, "at": fields.Datetime.to_string(now)}
        if client_at:
            logged["client_at"] = client_at
        entry = json.dumps([logged])
        # The repeat check rides the same statement, so two copies of one
        # report racing each other still count once.
        repeat = (
            " AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements("
            "     COALESCE({log}, '[]'::jsonb)) v "
            "     WHERE v->>'client_at' = %s)" if client_at else "")
        # ONE UPDATE PER VIOLATION. The latest-violation fields used to follow
        # as an ORM write - a second UPDATE of this row per beacon. They ride
        # this statement now, with the `write_uid`/`write_date` that write
        # stamped. Pending ORM values for the row are flushed FIRST, so a later
        # flush cannot overwrite what this sets.
        self.flush_recordset()
        # THE LOG STOPS AT VIOLATION_LOG_CAP ENTRIES; THE COUNT DOES NOT. A
        # full log is left as it is, so a client stuck reporting in a loop
        # does not make each report rewrite (and the repeat check scan) an
        # ever larger jsonb. Past the cap a resent report can count twice.
        self.env.cr.execute((
            "UPDATE assessments_be_evaluator "
            "SET {count} = COALESCE({count}, 0) + 1, "
            # Nested CASE: a JSON null in an old row has no array length.
            "    {log} = CASE WHEN (CASE WHEN jsonb_typeof({log}) = 'array' "
            "        THEN jsonb_array_length({log}) ELSE 0 END) < %s "
            "        THEN COALESCE({log}, '[]'::jsonb) || %s::jsonb "
            "        ELSE {log} END, "
            "    is_violated = TRUE, violation_reason = %s, "
            "    violation_datetime = %s, write_uid = %s, write_date = %s "
            "WHERE id = %s" + repeat + " RETURNING {count}"
            ).format(count=count_col, log=log_col),
            (self.VIOLATION_LOG_CAP, entry, reason, now, self.env.uid,
             self.env.cr.now(), self.id)
            + ((str(client_at),) if client_at else ()))
        row = self.env.cr.fetchone()
        if row is None:
            _logger.info(
                "VIOLATION repeat of a recorded report ignored evaluator=%s "
                "applicant=%s reason=%s client_at=%s",
                self.id, self.applicant_id.id, reason, client_at)
            return None
        new_count = row[0]
        # The raw SQL wrote columns the ORM cache still holds stale copies of,
        # and the breach flags computed from them.
        self.sudo().invalidate_recordset(
            ["violation_count", "violation_log", "ai_violation_count",
             "ai_violation_log", "violation_limit_breached",
             "ai_violation_limit_breached", "is_violated", "violation_reason",
             "violation_datetime", "write_uid", "write_date"])
        _logger.warning(
            "VIOLATION evaluator=%s applicant=%s assessment=%s reason=%s "
            "count=%s", self.id, self.applicant_id.id, self.assessment_id.id,
            reason, new_count)
        return new_count

    def _auto_submit_expired(self, blank_reason=None, reason_code=None):
        """Settle an expired/finished attempt: fill placeholders for unanswered
        questions, lock it, and flip the assessment to done once all evaluators
        are submitted. Shared by the portal path and _cron_expire_stale_attempts
        so an abandoned tab settles identically; idempotent per response.

        ``blank_reason`` is the text stamped on each unanswered question, and it
        defaults to the expiry wording every existing caller relies on. Not
        every settlement IS an expiry: the JSON API ends an attempt when a
        candidate submits an incomplete paper on purpose, and when proctoring
        auto-submits with time still on the clock. Both already passed this
        argument, but the parameter did not exist - so every submit through
        /api/v1/exam/<token>/submit raised TypeError and 500'd, and no candidate
        could finish a paper at all. Naming the real cause is also what lets an
        appeal be answered, instead of putting a deadline breach that never
        happened into the audit trail and the reviewer's CSV export.
        """
        self.ensure_one()
        # Function-local like every other service import in this file, so a
        # cycle at load time stays impossible.
        from ..services import audit
        t0 = audit.start()

        # ── FIRST SETTLEMENT WINS, AND IT IS DECIDED UNDER A ROW LOCK ────────
        #
        # There are SIX production callers and they pass DIFFERENT reason_codes:
        # the deadline sweep and three expiry checks pass "expired", proctoring
        # passes its own, and the candidate's own /submit passes none. Submit
        # idempotency used to hold only by "two racers write the same values",
        # which is false the moment the values differ.
        #
        # The interleaving that reaches production: the violation cap commits
        # auto_submit_reason='violation' at T5; the candidate's /submit read
        # is_locked=False at T2, never re-read, and settles at T7 with
        # reason_code=None - the key is absent from `vals`, so 'violation'
        # SURVIVES on a paper the candidate handed in themselves. Reverse the
        # order and a real violation ending reads as a clean submit.
        # serializers.py derives `auto_submitted` from that field, so the
        # candidate's completion screen AND the reviewer's CSV both lie.
        #
        # Read through raw SQL, not `self.state`: the ORM cache may hold a value
        # fetched before a concurrent settlement committed, which is exactly the
        # stale read being closed. FOR UPDATE also serialises the placeholder
        # creation below, so two settlements cannot both fill the same blanks.
        #
        # `nowait` is deliberately NOT used. The loser waiting a few ms and then
        # discovering the paper is settled is the correct outcome; failing fast
        # would surface a 500 to a candidate whose paper is, in fact, safely in.
        #
        # FLUSH FIRST, or the SQL below cannot see this transaction's own work.
        # Odoo buffers ORM writes and sends them at the end of the transaction,
        # so a raw SELECT reads the pre-write row. Without this the guard passes
        # for a second settlement in the SAME transaction - which is not a test
        # artefact: `candidate.py` has two expiry checks and a violation path that
        # can each reach this function inside one request, and the deadline cron
        # settles a batch of attempts in a single transaction. Caught by
        # test_a_second_settlement_does_not_overwrite_the_first_reason.
        self.flush_recordset(["state", "is_locked"])
        self.env.cr.execute(
            "SELECT state, is_locked FROM assessments_be_evaluator "
            "WHERE id = %s FOR UPDATE", (self.id,))
        row = self.env.cr.fetchone()
        if not row:
            return False
        locked_state, already_locked = row
        if already_locked or locked_state == "submitted":
            # Someone settled it first. Their reason_code is the true one, and
            # their submitted_at is the true timestamp: returning here is what
            # stops the later caller overwriting both.
            _logger.info(
                "Attempt %s was already settled (state=%s, locked=%s); "
                "leaving the first settlement intact.",
                self.id, locked_state, already_locked)
            audit.emit("exam.settle", self, outcome="already", t0=t0,
                       reason=reason_code or "")
            return False

        # `reason_code` is the machine-readable half of `blank_reason`, stored
        # on the attempt so both UIs can say WHY a paper the candidate did not
        # submit came in. Without it the cause lived only inside the text
        # stamped on blank answers - unreadable by the candidate, who is shown
        # a completion screen, and invisible on every admin list.
        blank_reason = blank_reason or "[Auto-submitted: time expired]"
        Response = self.env["assessments.be.response"].sudo()
        question_order = json.loads(self.question_order or "[]")
        for q_id in question_order:
            existing = Response.search([
                ("assessment_evaluator_id", "=", self.id),
                ("question_id", "=", q_id),
                ("state", "=", "submitted"),
            ], limit=1)
            if existing:
                continue
            draft = Response.search([
                ("assessment_evaluator_id", "=", self.id),
                ("question_id", "=", q_id),
                ("state", "=", "draft"),
            ], limit=1)
            if draft and draft.cleared:
                # AN EMPTIED ANSWER IS AN UNANSWERED QUESTION, so it becomes
                # this question's placeholder in place: the unique index
                # allows one row, and `auto_submitted` keeps it ungraded and
                # out of `answered_count`, exactly like a blank one.
                # `llm_raw_100` too: a grade that landed after the clear
                # would otherwise stay in `raw_result`.
                draft.write({"state": "submitted", "auto_submitted": True,
                             "justification": blank_reason,
                             "llm_state": "not_needed", "llm_raw_100": 0.0})
            elif draft:
                # A PARKED DRAFT CAN HOLD A REAL ANSWER, so it must not be
                # force-promoted to 'not_needed'.
                #
                # `_record_response` deliberately parks a COMPLETE subjective
                # text as a draft while the question's objective sub-checks are
                # unanswered. Stamping 'not_needed' here told the grader there
                # was nothing to grade, while `needs_llm` still computed True
                # (auto_submitted was never set, unlike the create branch
                # below) - and `_compute_llm_progress` counts only
                # pending/queued/failed/error, so 'not_needed' is invisible to
                # the admin too. A candidate's full written answer was scored 0
                # with no flag, no pending state and no cue that anything had
                # gone wrong; only a manual re-score recovered it.
                #
                # `auto_submitted` is deliberately NOT set here. That flag means
                # "a placeholder this code wrote" and it drives
                # `_compute_scoring_kind` to force needs_llm False - setting it
                # on a draft holding real prose would suppress the very grading
                # this fix exists to trigger. It stays on the blank-placeholder
                # branch below, where it is true.
                # `scoring_requested` is NOT written here: it lives on the
                # EVALUATOR, not on the response, so writing it to `draft`
                # raised ValueError and took the whole settlement down with it
                # - no rows promoted, no attempt locked, nothing submitted. The
                # queueing it was reaching for happens anyway: `self.write`
                # below stamps state 'submitted', and this model's `write`
                # override queues the attempt when any of its answers is
                # `needs_llm` and unscored - which this promoted draft now is.
                # Going through that hook also keeps the per-assessment
                # `llm_auto_score` toggle in charge of whether the grader runs,
                # instead of forcing it on behind the toggle's back.
                vals = {"state": "submitted"}
                if draft.needs_llm:
                    vals["llm_state"] = "pending"
                else:
                    vals["llm_state"] = "not_needed"
                draft.write(vals)
            else:
                try:
                    with self.env.cr.savepoint():
                        Response.create({
                            "assessment_id": self.assessment_id.id,
                            "assessment_evaluator_id": self.id,
                            "evaluator_id": self.applicant_id.id,
                            "question_id": q_id,
                            "justification": blank_reason,
                            "auto_submitted": True,
                            "state": "submitted",
                            "llm_state": "not_needed",
                        }).flush_recordset()
                except IntegrityError:
                    continue
        vals = {"state": "submitted", "is_locked": True}
        # Only ever stamped for a settlement the module drove. A candidate who
        # presses Submit goes through a different path and keeps it empty.
        if reason_code:
            vals["auto_submit_reason"] = reason_code
        self.write(vals)

        # THE COHORT ROLLUP DOES NOT HAPPEN HERE.
        #
        # This used to end with:
        #
        #     evs = assessment.assessment_evaluator_ids
        #     if evs and all(e.state == "submitted" for e in evs):
        #         assessment.write({"state": "done"})
        #
        # Two separate defects in three lines, and the same bug class that
        # already cost this project the response_count incident (82 of 100
        # candidates failing at 100 concurrent - see the comment above
        # `response_count`).
        #
        # 1. IT WROTE THE ONE ROW THE WHOLE COHORT SHARES, inside the very
        #    transaction that had just written this candidate's settlement and
        #    their placeholder answers. Exams end in a BURST - a deadline, or a
        #    cohort finishing together - so many transactions evaluated
        #    all(submitted) against different snapshots and collided on that
        #    single assessment row. Postgres raises a serialization failure, Odoo
        #    retries five times and then gives up, and because the shared write
        #    shared a transaction with the settlement, THE SETTLEMENT WAS
        #    DISCARDED TOO: the candidate's paper was not handed in. A statistic
        #    took a paper down with it, which is precisely the lesson
        #    services/scoring.py already states in capitals about marks.
        #
        # 2. IT LOADED EVERY SIBLING ROW, on every settlement, to compute one
        #    boolean. At 1,200 candidates settling near one deadline that is
        #    ~1.4M row reads in the sharpest minute of the day.
        #
        # Both are fixed by deferring: the close pass of
        # `_cron_recompute_subjective_results` sweeps `in_progress`
        # assessments once per tick, in its own transaction. Settling writes
        # nothing on the assessment row - not even the `cohort_close_stale`
        # flag it used to raise, which never changed what that sweep visits
        # and made every settlement at a deadline queue on the one shared row.
        audit.emit("exam.settle", self, outcome=reason_code or "submitted",
                   t0=t0, questions=len(question_order))
        return True

    @api.model
    def _cron_expire_stale_attempts(self, limit=100):
        """Rescue abandoned in-progress attempts past their deadline. Without
        this, a candidate who closes the tab is never auto-submitted (that only
        happened on a live portal request), leaving answers unscored and the
        assessment pinned in 'in_progress'. Unlimited sittings (no deadline) are
        skipped by the '<' filter.
        """
        domain = [
            # THE EXAM CLOCK STOPS WHILE THE PAPER IS ARCHIVED. Archiving
            # is a suspend, and auto-submitting somebody's half-finished
            # sitting is not something a suspend may do. The evaluator has
            # no `active` of its own, so this has to be written out.
            #
            # DELIBERATELY NO DEADLINE ARITHMETIC ON RESTORE. An assessment
            # restored two days later brings back a backlog of attempts
            # whose deadline is long past, and this cron auto-submits them
            # on its next tick - which is correct, because archiving a
            # paper people are actually sitting is almost always a mistake
            # and the archive route refuses it without an explicit
            # confirmation for exactly that reason. Shifting every deadline
            # forward by the archived duration was the alternative; it buys
            # a rarer case a second, drifting source of truth for when a
            # sitting ends.
            ("assessment_id.active", "=", True),
            ("state", "=", "in_progress"),
            ("deadline_datetime", "!=", False),
            ("deadline_datetime", "<", fields.Datetime.now()),
        ]
        with cron_lock(self.env.cr, ADVISORY_LOCK_EXPIRE_ATTEMPTS,
                       name="expire_attempts",
                       queued=lambda: self.search_count(domain)) as got:
            if not got:
                return
            stale = self.search(domain, limit=limit)
            for ev in stale:
                try:
                    with self.env.cr.savepoint():
                        ev._auto_submit_expired(reason_code="expired")
                    got.renew()
                    self.env.cr.commit()
                except Exception:  # noqa: BLE001 - isolate per candidate
                    _logger.exception(
                        "Expire-stale: auto-submit failed for evaluator %s",
                        ev.id)
                    continue

    # PII retention / erasure (GDPR storage-limitation + right-to-erasure).
    # Anonymization SCRUBS candidate free text and grader audit prose while
    # KEEPING the numeric score / pass-fail (aggregate integrity, and a
    # defensible record that a decision was made), so a purged attempt still
    # shows its result but no longer carries the person's words.
    _PII_ANONYMIZED_TAG = "[anonymized]"

    def _anonymize_pii(self):
        """Scrub candidate free-text/PII on this evaluator and its responses.
        Idempotent; runs sudo from cron/admin action.
        """
        Response = self.env["assessments.be.response"].sudo()
        for ev in self.sudo():
            resp = Response.search(
                [("assessment_evaluator_id", "=", ev.id)])
            for r in resp:
                vals = {}
                if r.justification:
                    # INVARIANT: the tag MUST stay a non-empty, non-"[Auto-
                    # submitted" string. needs_llm (=> the scoring denominator)
                    # is `bool(justification) and not placeholder`; scrubbing to
                    # an empty string would flip needs_llm False and silently drop
                    # this answer from every cohort score. Keep a truthy sentinel.
                    vals["justification"] = self._PII_ANONYMIZED_TAG
                # Grader audit prose can quote the candidate verbatim; scrub the
                # free-text audit fields but keep llm_raw_100 / llm_state / marks.
                # Integrity review still works post-scrub: _compute_integrity_alert
                # reads the retained llm_gate + llm_flags_json first; only the
                # llm_result_json fallback (display-only, never score) goes dark.
                # rescore_request_key too: a queued re-score would grade the
                # tag and replace the kept mark (R2-04).
                for f in ("llm_feedback", "llm_reasoning", "llm_verdict",
                          "llm_reference_answer", "llm_result_json",
                          "llm_deductions_json", "llm_credit_json",
                          "rescore_request_key"):
                    if getattr(r, f, False):
                        vals[f] = False
                if vals:
                    r.write(vals)
            ev_vals = {"pii_anonymized": True}
            if ev.scoring_requested:
                ev_vals["scoring_requested"] = False
            # A lane holding this attempt committed `scoring` before its call,
            # and no lane ever selects an erased attempt again - so `scoring`
            # would stay forever and hold every deploy gate shut (RV1-01). The
            # lane stores nothing here: a serial lane's store collides with
            # this write, a parallel one re-reads `pii_anonymized` first
            # (`_llm_score_finish`).
            if ev.llm_state == "scoring":
                ev_vals["llm_state"] = "cancelled"
                ev_vals["llm_error"] = ("Grading stopped: this attempt's data "
                                        "was erased.")
            if ev.violation_reason:
                ev_vals["violation_reason"] = self._PII_ANONYMIZED_TAG
            # The log is the FULL history the latest-reason field summarises, so
            # scrubbing only `violation_reason` would leave every prior reason -
            # each a record of what the person did - readable in `violation_log`.
            # Emptied to [] rather than nulled so the serialized tally stays a
            # list and the count of violations (a non-PII integrity fact) is
            # kept in `violation_count`.
            if ev.violation_log:
                ev_vals["violation_log"] = []
            if ev.ai_violation_log:
                ev_vals["ai_violation_log"] = []
            # The same kind of record (what the camera saw the person do).
            if ev.review_flags:
                ev_vals["review_flags"] = []
            ev.write(ev_vals)
            # AI proctoring snapshots are the candidate's face: the scrub is
            # not done while they sit in S3. Never raises for S3.
            evidence.purge_evidence(self.env, ev)

    def action_erase_candidate_data(self):
        """Admin on-demand right-to-erasure: anonymize one candidate's
        attempt(s) immediately, regardless of the retention window.
        """
        self._anonymize_pii()
        self.assessment_id._log_activity(Markup(
            "<b>Erase Candidate Data</b> - anonymized PII for %d attempt(s) "
            "(scores retained).") % len(self))
        return {
            "type": "ir.actions.client",
            "tag": "display_notification",
            "params": {
                "title": "Candidate Data Erased",
                "message": "Anonymized free-text/PII for %d attempt(s). "
                           "Numeric scores and pass/fail were kept." % len(self),
                "type": "success",
                "sticky": False,
            },
        }

    @api.model
    def _cron_purge_expired_pii(self, limit=200):
        """Daily-ish retention sweep: anonymize submitted attempts whose submit
        date is older than assessments_be_v2.pii_retention_days. 0 (default)
        disables the purge entirely, so nothing is scrubbed until an admin opts
        in. Advisory-locked single-flight; commits per batch.
        """
        raw = self.env["ir.config_parameter"].sudo().get_param(
            "assessments_be_v2.pii_retention_days",
            str(PII_RETENTION_DAYS_DEFAULT))
        try:
            days = int(float(raw))
        except (TypeError, ValueError):
            days = PII_RETENTION_DAYS_DEFAULT
        if days <= 0:
            return  # retention disabled - never auto-scrub
        cutoff = fields.Datetime.now() - timedelta(days=days)
        # NO `assessment_id.active` TERM HERE, AND THE OMISSION IS
        # DELIBERATE. Do not "fix" the inconsistency with the three crons
        # that do carry it.
        #
        # Archiving is a suspend, and suspending the cost-intensive and
        # queued work is exactly what it is for. Retention is not that kind
        # of work: it is a legal duty with its own clock, and "we archived
        # it" is not a defence for holding a person's data past the date we
        # promised to erase it. Pausing this cron would make Archive a
        # one-click way to park PII indefinitely, which is the opposite of
        # what a storage-limitation control is for. So this sweep stays
        # blind to `active` and keeps anonymizing archived attempts on
        # schedule - it scrubs free text and keeps the numeric result, so
        # nothing an unarchive needs to resume is destroyed by it.
        domain = [
            ("state", "=", "submitted"),
            ("submitted_at", "!=", False),
            ("submitted_at", "<", cutoff),
            ("pii_anonymized", "=", False),
        ]
        with cron_lock(self.env.cr, ADVISORY_LOCK_PII_PURGE,
                       name="pii_purge",
                       queued=lambda: self.search_count(domain)) as got:
            if not got:
                return
            stale = self.search(domain, limit=limit)
            for ev in stale:
                try:
                    with self.env.cr.savepoint():
                        ev._anonymize_pii()
                    got.renew()
                    self.env.cr.commit()
                except Exception:  # noqa: BLE001 - isolate per candidate
                    _logger.exception(
                        "PII purge failed for evaluator %s", ev.id)
                    continue

    @api.model
    def _cron_send_pending_invitations(self, batch=None):
        """Drain the queued invitations.

        BATCH SIZE IS CONFIGURABLE, and the default was the whole problem at
        cohort scale. At `batch=25` on a one-minute cron, a 500-candidate launch
        took **20 minutes** for the last candidate to receive their link - the
        "invite and launch is too slow" report of 2026-09-03. 200 makes the same
        launch ~3 minutes.

        Read from `ir.config_parameter` rather than hard-coded so it can be tuned
        for a cohort without a deploy, and per call rather than cached so the
        change applies on the next tick. An explicit `batch=` argument still wins,
        which is what the tests pass.
        """
        if batch is None:
            raw = self.env["ir.config_parameter"].sudo().get_param(
                "assessments_be_v2.invite_batch_size", "200")
            try:
                batch = max(1, int(float(raw)))
            except (TypeError, ValueError):
                batch = 200
        # H-7: single-flight the invite drainer. Without a lock two workers (or a
        # worker racing a manual requeue) both select the same queued rows and
        # send duplicate invitation emails to every candidate in the overlap.
        #
        # A RETIRED PAPER MUST NOT MAIL PEOPLE. `assessment_id.active` is
        # written out because the evaluator carries no `active` of its own,
        # so `active_test` cannot do it. `invite_state` is left at `queued`
        # on every skipped row - the invitation is deferred, not cancelled,
        # and restoring the assessment sends it on the next tick.
        #
        # Nor may one that is not running: the exam gate refuses every
        # state but `in_progress`, so an invitation for a cancelled or done
        # paper is a link that cannot open (`action_cancel` leaves the
        # queue as it was).
        domain = [
            ("assessment_id.active", "=", True),
            ("assessment_id.state", "=", "in_progress"),
            ("invite_state", "=", "queued"),
        ]
        with cron_lock(self.env.cr, ADVISORY_LOCK_INVITE_SEND,
                       name="invite_send",
                       queued=lambda: self.search_count(domain)) as got:
            if not got:
                return
            pending = self.search(domain, limit=batch)
            for ev in pending:
                try:
                    with self.env.cr.savepoint():
                        # 'sent' ONLY when the mail layer actually took it. A
                        # missing template or a candidate with no address are
                        # both no-sends that used to be stamped 'sent', and
                        # `action_requeue_invitation` skips 'sent' - so the
                        # candidate never got a link and no retry could reach
                        # them. 'failed' is requeueable, which is the point.
                        reason = ev._deliver_invitation()
                        ev.invite_state = "failed" if reason else "sent"
                        ev.invite_error = reason or False
                    got.renew()
                    self.env.cr.commit()
                except Exception as exc:  # noqa: BLE001
                    # ROLL BACK FIRST. A failed flush or commit leaves this
                    # transaction aborted (or its snapshot stale), so the
                    # 'failed' write below - and every later invite in the
                    # batch - failed with it and nothing was recorded. Only
                    # this invite is lost: the earlier ones are committed.
                    self.env.cr.rollback()
                    if isinstance(exc, _TRANSIENT_DB_ERRORS):
                        # The DB asking to try again: left `queued`.
                        _warn_lost_race(ev, "Invitation for evaluator", exc)
                        continue
                    _logger.exception(
                        "Invite send failed for candidate %s (evaluator %s)",
                        ev.applicant_id.partner_name, ev.id)
                    try:
                        with self.env.cr.savepoint():
                            ev.invite_state = "failed"
                            ev.invite_error = str(exc)[:200]
                        got.renew()
                        self.env.cr.commit()
                    except Exception:
                        self.env.cr.rollback()
                        _logger.exception(
                            "Invite cron: could not flag evaluator %s failed", ev.id)

    def action_requeue_invitation(self):
        self.filtered(lambda e: e.invite_state != "sent").write(
            {"invite_state": "queued", "invite_error": False})

    def _action_llm_score(self):
        """The SERIAL lane's grading pass - the cron's, and nobody else's.

        PRIVATE ON PURPOSE. A public method is reachable by any manager
        through `/web/dataset/call_kw`: a stale client or a script could make
        a web worker sit on a Vertex call, with no `_being_graded` check, and
        write marks over the lane that owns the candidate. A leading
        underscore is what `service/model.get_public_method` refuses, so the
        name IS the guard. The cron reaches it as a plain method call.
        """
        from ..services import scoring as scoring_svc
        scored = 0
        for rec in self:
            rec._llm_score_start()
            done = rec._llm_score_guarded(
                lambda: scoring_svc.score_evaluator(self.env, rec))
            if done is not None:
                scored += done
                rec._compute_subjective_rollup()
        return scored

    def _llm_score_start(self):
        """Mark this candidate as held by a lane. Idempotent, and that matters.

        `_auto_score_mark_scoring` already committed exactly this write before
        the lane's first call. Writing it again would hold the row's lock for
        the length of a Vertex call, and any web writer touching the candidate
        (Release Results, a threshold change) would then lose the race with a
        serialization failure that throws away paid results. Re-reading is a
        SELECT; only a real change is written.
        """
        self.ensure_one()
        if self.state != "submitted":
            raise UserError(
                f"Candidate '{self.applicant_id.partner_name}' has not "
                f"submitted - scoring runs on submitted assessments only.")
        if self.llm_state != "scoring" or self.llm_error:
            self.write({"llm_state": "scoring", "llm_error": False})

    def _llm_score_begin(self, dispatch):
        """`_action_llm_score` for a parallel lane, first half: plan this
        candidate and hand its judge calls to ``dispatch``. None when the
        attempt was settled instead."""
        from ..services import scoring as scoring_svc
        self._llm_score_start()
        return self._llm_score_guarded(
            lambda: scoring_svc.begin_evaluator(self.env, self, dispatch))

    def _llm_score_finish(self, run):
        """Second half: store what the judge returned, then roll up."""
        from ..services import scoring as scoring_svc
        # ERASED WHILE ITS CALL WAS OUT. The parallel lane commits between
        # candidates, so this store can run in a transaction that began after
        # the erase and would write the grader's prose - which can quote the
        # candidate - back onto the scrubbed answers. Nothing is stored; the
        # attempt keeps the `cancelled` the erase gave it (F1).
        self.invalidate_recordset(["pii_anonymized"])
        if self.pii_anonymized:
            return 0
        scored = self._llm_score_guarded(
            lambda: scoring_svc.finish_evaluator(self.env, run))
        if scored is None:
            return 0
        self._compute_subjective_rollup()
        return scored

    def _llm_score_guarded(self, work):
        """Run ``work``. A kill or a failure becomes this candidate's state,
        and None."""
        from ..services import vertex
        rec = self
        try:
            return work()
        except vertex.VertexCancelledError:
            # AN ARCHIVE RAISES THE SAME FLAG AS A KILL AND MEANS THE
            # OPPOSITE THING, so the two must not share a landing state.
            #
            # Archiving suspends: it raises `scoring_cancel_requested` so
            # this lane refuses its next billable call, and every candidate
            # the drainer had not started keeps its `scoring_requested` and
            # `llm_state` untouched, because the cron domain simply stops
            # selecting them. This candidate is the single exception - the
            # archive landed while a Vertex call was on the wire - and
            # parking it in `cancelled` below would make it the one row a
            # restore could not bring back: `cancelled` is terminal and
            # carries no memory of whether it was `pending` or `failed`, so
            # a restored cohort would silently come back one candidate
            # short and nothing would report it.
            #
            # `pending` with `scoring_requested` LEFT ALONE is the park
            # that resumes: it is inside `_scoring_shard_evaluators`'
            # domain, so the drainer picks this candidate up on the first
            # tick after the paper is unarchived, with its attempt budget
            # intact. Answers scored before the refusal are already stored
            # and stay, exactly as on the kill path.
            #
            # `_is_archived_now` and not `rec.assessment_id.active`: the
            # archive was committed by a web worker after this cron's
            # transaction opened, so the lane's own snapshot cannot see it.
            if rec.assessment_id._is_archived_now():
                _logger.info(
                    "Subjective scoring for evaluator %s stopped because "
                    "its assessment was archived; answers scored before "
                    "it stopped were kept and the candidate is "
                    "re-queued for when the paper is restored.",
                    rec.id)
                rec.write({"llm_state": "pending", "llm_error": False})
                return None
            # A KILL IS A CHOICE, NOT A FAULT, so it must not land in
            # 'failed' beside genuine grader errors: the generic handler
            # below would read back to the operator as something broken, and
            # Score Failed Responses would pick the candidate up and re-spend
            # on them.
            #
            # The three generation lanes catch this error for the same
            # reason (the `except vertex.VertexCancelledError` branches in
            # models/prompt.py). Whatever was scored before the refusal is
            # already stored and stays.
            _logger.info(
                "Subjective scoring for evaluator %s stopped by an admin "
                "kill; answers scored before it stopped were kept.",
                rec.id)
            rec.write({
                "llm_state": "cancelled",
                "scoring_requested": False,
                "llm_error": "Scoring cancelled by an admin while this "
                             "candidate was being graded.",
            })
            # Kill left this held candidate's re-score keys to its lane; the
            # next tick would grade and bill them (R1-02).
            rec.assessment_id._clear_rescore_requests(rec)
            return None
        except Exception as exc:
            _logger.exception(
                "Subjective scoring failed for evaluator %s", rec.id)
            rec.write({
                "llm_state": "failed",
                "llm_error": str(exc)[:240],
            })
            return None

    def _being_graded(self, lane_shard=None, in_flight=None):
        """Those of these candidates a running lane is grading right now.

        `scoring` alone is not proof: a lane that died leaves it behind, and
        such a row is nobody's. The lane that owns the row (evaluator id %
        shards) must also be holding its lock (`_live_lane_shards`).

        ``lane_shard`` / ``in_flight``: when a lane asks, its shard and the
        candidates it has calls out for. Its other `scoring` rows were left by
        a tick of its own that died - it is not grading them.
        """
        scoring = self.filtered(lambda ev: ev.llm_state == "scoring")
        if not scoring:
            return scoring
        Assessment = self.env["assessments.be"]
        shards = Assessment._scoring_shard_count()
        live = Assessment._live_lane_shards(range(shards)) - {lane_shard}
        return scoring.filtered(lambda ev: ev.id % shards in live) | (
            scoring & (in_flight or scoring.browse()))

    def action_queue_llm_score(self):
        for rec in self:
            if rec.state != "submitted":
                raise UserError(
                    f"Candidate '{rec.applicant_id.partner_name}' has not "
                    f"submitted - scoring runs on submitted assessments only.")
        papers = self.mapped("assessment_id")
        for paper in papers:
            paper._check_scoring_not_cancelled()
        papers._check_scoring_not_stopping()
        # WITHDRAW ANY RAISED KILL BEFORE QUEUEING (see
        # `_withdraw_scoring_kill`): with the flag still up the cron settles
        # the row straight back to 'cancelled' on its next tick and silently
        # undoes the re-queue. `POST /scoring/queue` with `evaluator_ids`
        # reaches this without the assessment-level actions that withdraw.
        # A candidate a lane is grading right now is left to it: rewriting
        # the row makes the lane's paid result collide, and hides it from Kill.
        busy = self._being_graded()
        # An erased attempt is never re-graded (see action_reset_failed_scoring).
        erased = self.filtered("pii_anonymized")
        queued = self - busy - erased
        papers._remember_scoring_tally()
        # Only the papers something was actually queued on: a click that
        # queued nobody must not un-kill a run that is still stopping.
        queued.mapped("assessment_id")._withdraw_scoring_kill()
        queued.write({"scoring_requested": True, "llm_state": "pending"})
        return {
            "type": "ir.actions.client",
            "tag": "display_notification",
            "params": {
                "title": "Subjective Grading Queued",
                "message": "Queued for the background grader; the "
                           "Subjective Scoring badge updates on its own." + _busy_note(busy),
                "type": "success", "sticky": False,
                # Reloads the form so the badge starts polling; see
                # `action_llm_score_all`.
                "next": {"type": "ir.actions.act_window_close"},
            },
            # As `action_llm_score_all`: what `POST /scoring/queue` replies
            # with, not counting the candidates left to their lane.
            "queue": {"queued": len(queued),
                      "skipped": len(busy) + len(erased)},
        }

    def action_reset_failed_scoring(self, states=("failed", "error")):
        """Send responses in ``states`` back to 'pending' so the grader retries.

        THE RESET RULE LIVES HERE, ONCE. `action_reset_errored_scoring` is the
        narrow case of this - it resets only 'error' - and it now delegates
        here rather than carrying its own copy of the write. A second copy is
        how the two drifted last time: one learned to zero `llm_attempts` and
        the other did not, so a retry from one button kept counting against the
        attempt cap and a retry from the other did not.

        `llm_attempts` is zeroed on purpose. A terminal 'error' has already
        spent its retries, so leaving the counter raised would let the grader
        refuse the very answer this reset exists to re-try. The evaluator's own
        `scoring_requested` / `llm_state` are set so the drainer picks the row
        up on its next tick - the response-level reset alone is invisible to a
        cron that selects on the evaluator.
        """
        papers = self.mapped("assessment_id")
        # Checked here, not only in the callers: the reset alone queues paid
        # grading (R7-01).
        for paper in papers:
            paper._check_scoring_not_cancelled()
        papers._check_scoring_not_stopping()
        papers._remember_scoring_tally()
        # A candidate a lane is grading right now is left to it, as in
        # `action_queue_llm_score`. ONE SEARCH over the answers, not a Python
        # walk of every answer of every candidate.
        busy = self._being_graded()
        # AN ERASED ATTEMPT IS NEVER RE-GRADED. Erasure replaces every answer
        # with the `[anonymized]` tag and keeps the mark it already had; a
        # reset would pay the grader to mark that literal string and overwrite
        # the mark the erase promised to keep.
        erased = self.filtered("pii_anonymized")
        targets = self.env["assessments.be.response"].search([
            ("assessment_evaluator_id", "in", (self - busy - erased).ids),
            ("llm_state", "in", list(states)),
        ])
        targets.write({"llm_state": "pending", "llm_attempts": 0})
        targets.assessment_evaluator_id.write(
            {"scoring_requested": True, "llm_state": "pending"})
        # Same reason as `action_queue_llm_score`: this is reached from Retry
        # Failed Scoring and `/scoring/requeue_errored`, and a reset performed
        # while the assessment's kill flag is still raised would be reverted
        # to 'cancelled' by the next cron tick. AFTER the reset and only for
        # the papers it actually touched: a click that reset nothing must not
        # un-kill a run that is still stopping.
        targets.assessment_evaluator_id.mapped(
            "assessment_id")._withdraw_scoring_kill()
        message = (f"Reset {len(targets)} answer(s) to pending; the "
                   f"background grader will retry them." + _busy_note(busy))
        if erased:
            message += (" %d erased attempt(s) were left alone - their "
                        "answers were anonymised and keep their marks."
                        % len(erased))
        return {
            "type": "ir.actions.client",
            "tag": "display_notification",
            "params": {
                "title": "Re-queued for scoring",
                "message": message,
                "type": "success", "sticky": False,
                # Reloads the form so the badge starts polling; see
                # `action_llm_score_all`.
                "next": {"type": "ir.actions.act_window_close"},
            },
            # What the API route replies with; the web client ignores it.
            "reset": {"answers": len(targets),
                      "skipped": len(busy) + len(erased)},
        }

    def action_reset_errored_scoring(self):
        """Reset ONLY terminal 'error' answers - INVARIANT 5's manual retry.

        No button or route calls it now (`/scoring/requeue_errored` passes its
        states to `action_reset_failed_scoring`, and the attempt's re-score
        button is `action_rescore_individually`). Its contract stays narrower
        than the failed-and-errored reset: a 'failed' answer is a recoverable
        miss the cron already retries on its own, so touching it would
        re-queue work that was never stuck.
        """
        return self.action_reset_failed_scoring(states=("error",))

    def action_rescore_individually(self, question_ids=None,
                                    confirm_released=False):
        """Queue chosen answers of THIS candidate for the grader, on their own.

        The one path behind the attempt form's "Re-score N answer(s)", the
        answer form's "Re-score This Answer" and `POST /attempts/<id>/rescore`.
        Nothing is graded here: the chosen answers get one random key for this
        click, and the lane that owns the candidate grades them first on its
        next tick, in calls of their own (`scoring.begin_evaluator`).

        ``question_ids`` picks answers of this attempt; none = every answer
        that needs the grader and has no mark yet. A scored answer may be
        chosen: its mark is replaced only when the new grade succeeds. An
        answer already queued keeps its request, so it is graded once.

        ``confirm_released`` (or `rescore_confirm_released` in the context, for
        an Odoo button that has just asked) says the caller MEANS to re-grade
        an attempt whose results the candidate can already see. Without it
        such a request is refused (`released_confirm_required`) and nothing is
        written - the same rule `/scoring/requeue_errored` states with its
        `force`, for the same two reasons: it spends again, and the grader
        runs at temperature 0.2, so the new mark can differ from the one that
        was shown.

        Refused with nothing written when the daily or per-candidate spend cap
        is reached. The calls-per-minute limit is not a refusal: it clears on
        its own and the queued request simply waits for it. A candidate a lane
        is grading right now is refused too (`being_graded`), WITH OR WITHOUT
        chosen answers: "come back in a minute", never "nothing to re-score",
        which reads as "these answers are fine" (decided;
        `docs/ETP_PLANS_AND_STRATEGY.md` §3.8, W6).
        """
        self.ensure_one()
        from ..services import vertex as vertex_svc
        try:
            vertex_svc._check_spend(self.env, {"evaluator_id": self.id})
        except vertex_svc.VertexBudgetError as exc:
            raise RescoreRefused(
                "Nothing was queued: %s" % exc, "spend_limit") from None
        if self.state != "submitted":
            raise UserError(
                f"Candidate '{self.applicant_id.partner_name}' has not "
                f"submitted - scoring runs on submitted assessments only.")
        # THERE IS NOTHING LEFT TO GRADE ON AN ERASED ATTEMPT. Erasure keeps
        # the tag `[anonymized]` in place of every answer - deliberately
        # non-empty, so `needs_llm` stays true and the answer keeps its place
        # in the denominator - and keeps the mark it already had. Re-scoring
        # would pay the grader to mark that literal string and REPLACE the
        # mark "numeric scores and pass/fail were kept" promised to keep.
        if self.pii_anonymized:
            raise RescoreRefused(
                "This attempt's answers have been erased (anonymised); the "
                "marks it kept cannot be re-graded. Nothing was queued.",
                "erased")
        # No lane grades an archived paper, and queueing here would lower the
        # archive's stop flag (G4-11).
        if not self.assessment_id.active:
            raise RescoreRefused(
                "'%s' is archived; nothing is graded until it is restored. "
                "Nothing was queued." % self.assessment_id.name, "archived")
        self.assessment_id._check_scoring_not_cancelled()
        self.assessment_id._check_scoring_not_stopping()
        # THE LANE IS WRITING THESE ROWS RIGHT NOW. A key written over an
        # answer mid-grade makes the lane's paid result collide.
        if self._being_graded():
            raise RescoreRefused(
                "%s is being graded right now - try again in a minute. "
                "Nothing was queued." % self.applicant_id.partner_name,
                "being_graded")
        confirmed = confirm_released or self.env.context.get(
            "rescore_confirm_released")
        if self.results_released and not confirmed:
            raise RescoreRefused(
                "%s's results have already been released. Re-scoring costs "
                "another LLM call per answer and can change a mark the "
                "candidate has seen - confirm it on purpose. Nothing was "
                "queued." % self.applicant_id.partner_name,
                "released_confirm_required")
        Response = self.env["assessments.be.response"]
        skipped = Response
        if question_ids:
            wanted = {int(q) for q in question_ids}
            answers = self.response_ids.filtered(
                lambda r: r.question_id.id in wanted)
            missing = sorted(wanted - set(answers.question_id.ids))
            if missing:
                # Names the first 10 only; the echo is trimmed, the request
                # is not capped (G1-19).
                named = ", ".join(map(str, missing[:10]))
                if len(missing) > 10:
                    named += " and %d more" % (len(missing) - 10)
                raise RescoreRefused(
                    "Question(s) %s are not on this attempt; nothing was "
                    "queued." % named, "not_on_attempt")
            chosen = answers.filtered("needs_llm")
            # Scored in code (mcq/msq): there is nothing to grade.
            skipped = answers - chosen
        else:
            chosen = self.response_ids.filtered(
                lambda r: r.needs_llm and r.llm_state != "scored")
        if chosen:
            self.assessment_id._remember_scoring_tally()
            self.assessment_id._withdraw_scoring_kill()
        # ONLY THE CHOSEN ROWS ARE WRITTEN. The candidate's own row belongs to
        # the grading lane, which may be holding it mid-call.
        new = chosen.filtered(lambda r: not r.rescore_request_key)
        if new:
            self.assessment_id._log_activity(self._rescore_audit_line(new))
            key = uuid.uuid4().hex
            spent = new.filtered(lambda r: r.llm_state in ("failed", "error"))
            (new - spent).write({"rescore_request_key": key})
            # A fresh attempt budget, as Retry Failed gives.
            spent.write({"rescore_request_key": key, "llm_attempts": 0})
        return {
            "type": "ir.actions.client",
            "tag": "display_notification",
            "params": {
                "title": "Re-score queued" if chosen else "Nothing to re-score",
                "message": (
                    "%d answer(s) queued. The grader takes them first, usually "
                    "within a minute; a scored answer keeps its mark unless "
                    "the new grade succeeds." % len(chosen)) if chosen else (
                    "No answer here needs the grader. To grade a scored "
                    "answer again, open it and use Re-score This Answer."),
                "type": "success" if chosen else "warning",
                "sticky": False,
                # Reloads the form so the badge starts polling; see
                # `action_llm_score_all`.
                "next": {"type": "ir.actions.act_window_close"},
            },
            # What the API route replies with; the web client ignores it.
            "rescore": {
                "queued": len(chosen),
                "skipped": len(skipped),
                "question_ids": sorted(chosen.question_id.ids),
            },
        }

    def _rescore_audit_line(self, answers):
        """Chatter line: who asked, for which answers, and what they had."""
        rows = []
        for r in answers.sorted("id"):
            if r.llm_state == "scored":
                had = Markup("%s/100 by %s, prompt %s") % (
                    "%.0f" % r.llm_raw_100, r.llm_judge_model or "unknown model",
                    r.llm_prompt_version or "unversioned")
            else:
                had = Markup("no mark (%s)") % r.llm_state
            rows.append(Markup("%s - previous: %s") % (
                r.question_id.display_name, had))
        return Markup(
            "<b>Re-score requested</b> by %s for %s: %d answer(s) queued - %s"
        ) % (self.env.user.name,
             self.applicant_id.partner_name or self.candidate_email or "?",
             len(answers), Markup("; ").join(rows))

    def _has_rescore_request(self):
        """Is a re-score waiting on any of this candidate's answers? A query,
        not the cache, so a kill settled earlier in the tick is seen."""
        self.ensure_one()
        return bool(self.env["assessments.be.response"].search_count([
            ("assessment_evaluator_id", "=", self.id),
            ("rescore_request_key", "!=", False)], limit=1))

    def action_export_responses(self):
        self.ensure_one()
        from ..services import export as export_svc
        return export_svc.export_responses(self.assessment_id, evaluator=self)

    def action_remove_from_assessment(self):
        """Drop candidates from the roster.

        WHY THIS EXISTS HERE. The Candidates table's Remove button has always
        called this method, and this module never defined it - the only copy
        lives on `etp_assessment_pro`, which this model does not inherit. So
        the button raised a server error on every press.

        BOTH LINKS, not just the attempt row. A candidate is on an assessment
        twice over: the `assessments.be.evaluator` row (the sitting) and the
        `evaluator_ids` m2m on the assessment (the roster). Unlinking only the
        first is what upstream does, and `_sync_roster_rows` then recreates the
        attempt from the surviving m2m entry the next time anything touches the
        assessment - so the candidate silently comes back. This mirrors the API
        unassign route, which drops both.

        REFUSES A SITTING THAT HAS BEEN TOUCHED. An attempt that has started,
        been submitted, or been locked by the proctor carries answers, a score
        and a violation history. Removing it destroys all three with no undo,
        so it is refused and named rather than quietly skipped. The test is the
        API route's, not upstream's: a PENDING attempt that was locked or has a
        start time counts as touched, because the proctor ending somebody's
        exam is a finding about a person.
        """
        held = self.filtered(
            lambda r: r.state != "pending" or r.started_at or r.is_locked)
        if held:
            names = ", ".join(
                (r.applicant_id.partner_name or r.candidate_email or "?")
                for r in held[:5])
            more = "" if len(held) <= 5 else " and %d more" % (len(held) - 5)
            raise UserError(
                "%d candidate(s) have already started, submitted or been "
                "locked out of this assessment and were not removed: %s%s.\n\n"
                "Remove is for correcting the roster before anybody sits it."
                % (len(held), names, more))

        # Grouped, because `self` can in principle span assessments and the
        # m2m write has to land on the right parent.
        by_assessment = {}
        for rec in self:
            by_assessment.setdefault(rec.assessment_id, []).append(
                rec.applicant_id.id)
        count = len(self)
        self.unlink()
        for assessment, applicant_ids in by_assessment.items():
            on_roster = [a for a in applicant_ids
                         if a in assessment.evaluator_ids.ids]
            if on_roster:
                assessment.write(
                    {"evaluator_ids": [(3, aid) for aid in on_roster]})
        return {
            "type": "ir.actions.client",
            "tag": "display_notification",
            "params": {
                "title": "Candidates Removed",
                "message": "%d candidate(s) removed from the roster." % count,
                "type": "success", "sticky": False,
            },
        }

    def action_release_results(self):
        to_release = self.filtered(lambda r: not r.results_released)
        # Only a SUBMITTED attempt has results, as in the cohort-wide release
        # (`_releasable_evaluators`); a pending or live one is skipped.
        unsubmitted = to_release.filtered(lambda r: r.state != "submitted")
        to_release -= unsubmitted
        # Same rule as `action_llm_score_all` and the cohort-wide release: a
        # candidate a lane is grading right now is left to it, because a
        # commit into that row hands the lane a SerializationFailure and its
        # paid results are bought again. Their marks are not final anyway.
        busy = to_release._being_graded()
        to_release -= busy
        to_release.write({"results_released": True})
        already = (len(self) - len(to_release) - len(busy)
                   - len(unsubmitted))
        msg = "%s candidate(s) released." % len(to_release)
        if already:
            msg += " %s already released." % already
        if unsubmitted:
            msg += (" %s not submitted yet, so not released."
                    % len(unsubmitted))
        if busy:
            msg += _busy_note(busy)
        return {
            "type": "ir.actions.client",
            "tag": "display_notification",
            "params": {
                "title": "Results Released",
                "message": msg,
                "type": "warning" if busy or unsubmitted else "success",
                "sticky": bool(busy),
            },
            "release": {"released": len(to_release), "skipped": len(busy)},
        }

    @api.depends("question_order")
    def _compute_total_questions(self):
        for rec in self:
            try:
                rec.total_questions = len(
                    json.loads(rec.question_order or "[]"))
            except (ValueError, TypeError):
                rec.total_questions = 0

    @api.depends("response_ids", "response_ids.state", "response_ids.score",
                 "response_ids.auto_submitted", "response_ids.cleared",
                 "response_ids.justification", "response_ids.line_ids",
                 "response_ids.clip_answers_json")
    def _compute_progress(self):
        for rec in self:
            submitted = rec.response_ids.filtered(lambda r: r.state == "submitted")
            # Real answers only (`_is_answered`); the marks below still sum
            # every submitted row, placeholders included (they score 0).
            rec.answered_count = len(submitted.filtered(
                lambda r: r._is_answered()))
            rec.total_score = sum(submitted.mapped("score"))
            rec.max_possible_score = sum(submitted.mapped("max_score"))

    @api.depends("started_at", "assessment_id.duration_minutes")
    def _compute_deadline_datetime(self):
        from datetime import timedelta
        for rec in self:
            if rec.started_at and rec.assessment_id.duration_minutes > 0:
                rec.deadline_datetime = rec.started_at + timedelta(
                    minutes=rec.assessment_id.duration_minutes)
            else:
                rec.deadline_datetime = False

    def is_time_expired(self):
        self.ensure_one()
        if not self.deadline_datetime:
            return False
        return fields.Datetime.now() > self.deadline_datetime


class EtpAssessmentResponse(models.Model):
    _name = "assessments.be.response"
    _description = "Assessment Response"
    _order = "create_date desc"

    # INDEXED, like its two neighbours below. It was the only one of the three
    # foreign keys on this table without an index, while being the column the
    # per-assessment reads filter on: `/api/v1/responses` scoped to an
    # assessment (`api/admin.py`), the two exports, and the settlement's
    # own lookups - eleven filter sites in the module. On a 5,000-candidate
    # cohort that table holds ~175,000 rows, so each of those was a sequential
    # scan.
    #
    # The declaration covers a fresh install. Existing databases get it from
    # `migrations/19.0.3.17.0/pre-migrate.py`, which builds it CONCURRENTLY:
    # Odoo's own `init()` would take a plain `CREATE INDEX`, and that holds a
    # SHARE lock which blocks every write to the answers table for the length
    # of the build - i.e. it would stall a live exam mid-sitting.
    @api.model
    def _be_search_domain(self, term):
        """The ONE free-text predicate for finding an ANSWER.

        Same arrangement as `EtpAssessmentEvaluator._be_search_domain`, and for
        the same reason: `/api/v1/responses` and Odoo's own response search view
        must not be able to disagree about what a term selects.

        THE AXES ARE THE THREE ODOO ALREADY OFFERS - assessment, candidate and
        question (`views/assessment_views.xml`, the `assessments_be_response_search`
        record). They are `ilike` through each target's own name search, so a
        term matches a substring of an assessment title, a candidate's name or a
        question's name.

        WHAT IS DELIBERATELY NOT HERE: the answer TEXT. The Flutter Responses
        screen searches the REDACTED RENDERED answer - text built client-side by
        applying this platform's redaction rules to `justification` and the
        chosen options. The server cannot reproduce that string without a second
        copy of the redaction logic, and two copies of a redaction rule is how a
        redaction rule stops being one. That box therefore stays a local pass
        over the page in hand, and it says so on screen; these three axes are
        what moves to the server, which is what lets an operator reach an answer
        past row 400 of 31,462.

        `%` and `_` are escaped for the reason spelled out on the evaluator's
        copy: Postgres reads them as wildcards, a person typing them means them
        literally.
        """
        term = (term or "").strip()
        if not term:
            return []
        term = term.replace("\\", "\\\\").replace("%", r"\%").replace("_", r"\_")
        return ["|", "|",
                ("assessment_id", "ilike", term),
                ("evaluator_id", "ilike", term),
                ("question_id", "ilike", term)]

    assessment_id = fields.Many2one(
        "assessments.be", required=True, ondelete="cascade", index=True)
    assessment_evaluator_id = fields.Many2one(
        "assessments.be.evaluator", string="Candidate Assignment",
        ondelete="cascade", index=True)
    evaluator_id = fields.Many2one(
        "hr.applicant", string="Candidate", required=True,
        # REQUIRED, ON THE ANSWERS TABLE, AND UNINDEXED. Distinct from
        # `assessment_evaluator_id` above (which points at the ATTEMPT and was
        # already indexed) - this one points at the applicant and is what every
        # per-candidate answer read filters on.
        index=True)
    question_id = fields.Many2one(
        "assessments.be.question", required=True, ondelete="cascade",
        index=True)
    justification = fields.Text()
    # Transcription only: the candidate's whole-audio category, sound
    # characteristics and speakers, as `constants.clean_clip_answers` leaves
    # them. The transcription text itself is `justification`, like any written
    # answer. Codes, not prose, so it is not PII and survives erasure.
    clip_answers_json = fields.Text(string="Clip Answers (JSON)")
    # L-5: robust marker for a time-expiry auto-submission, replacing a fragile
    # match on a justification prefix a candidate could type verbatim. Set only
    # by the auto-submit paths; drives _compute_scoring_kind (an auto-submitted
    # placeholder must not trigger an LLM scoring call).
    auto_submitted = fields.Boolean(default=False, string="Auto-submitted")
    #: THE CANDIDATE EMPTIED THIS ANSWER (`cleared: true` on `/answer` or a
    #: batch item). The row is kept, with no options and no text, in `draft`,
    #: so it is neither graded nor counted; a later real answer refills it and
    #: turns this back off. At settlement it becomes the question's
    #: placeholder in place (`_auto_submit_expired`).
    cleared = fields.Boolean(default=False, copy=False, readonly=True)
    line_ids = fields.One2many(
        "assessments.be.response.line", "response_id",
        string="Dimension Answers")
    #: WHEN THE CANDIDATE'S DEVICE LAST CHANGED THIS ANSWER, as the client
    #: sent it (`updated_at`, ms since epoch), and the exam session (the tab's
    #: `session_key`) that sent it. The write-behind runner flushes answers in
    #: batches and retries them, so a batch can land after a newer save from
    #: the same tab; a save from the SAME session stamped OLDER than this is
    #: skipped as `stale` (`candidate.py::_update_response`). Any other save
    #: replaces both. A Float because Odoo's Integer is int4 and an epoch in
    #: ms is past 2^31; float8 holds it exactly.
    client_updated_at = fields.Float(
        string="Client Saved At (ms)", readonly=True, copy=False)
    client_session_key = fields.Char(
        string="Client Session", readonly=True, copy=False)
    state = fields.Selection(
        [("draft", "Draft"), ("submitted", "Submitted")], default="draft")
    # Answers are submitted one by one DURING the exam; this is whether the
    # candidate has handed in. Not stored - read by the response form only.
    attempt_state = fields.Selection(
        related="assessment_evaluator_id.state", string="Attempt State")
    #: HAS THE CANDIDATE SEEN THIS MARK? Re-scoring a released answer spends a
    #: model call and can move a number the candidate is already looking at,
    #: which is why the bulk requeue route demands `force: true` for it and
    #: says so in its error text. A static `confirm=` cannot be conditional,
    #: so this drives two Odoo buttons: the plain one, and a confirming one
    #: for a released attempt.
    attempt_released = fields.Boolean(
        related="assessment_evaluator_id.results_released",
        string="Results Released")

    score = fields.Integer(compute="_compute_score", store=True, string="Score")
    max_score = fields.Integer(
        compute="_compute_score", store=True, string="Max Possible")
    objective_score = fields.Integer(
        related="score", store=True, string="Objective Score", readonly=True)
    objective_max = fields.Integer(
        related="max_score", store=True, string="Objective Max", readonly=True)
    has_objective = fields.Boolean(
        compute="_compute_scoring_kind", store=True, string="Has Objective")

    needs_llm = fields.Boolean(
        compute="_compute_scoring_kind", store=True, string="Needs LLM")

    llm_raw_100 = fields.Float(
        string="Subjective Score (0-100)", readonly=True, copy=False,
        help="The grader's raw 0-100 quality score for this answer. Immutable "
             "truth: pass/fail and the earned mark are derived from this and "
             "the Settings threshold, so a threshold change re-decides them "
             "live without re-scoring.")
    # THE CLIENT'S RULE, STORED AS COUNTS. Transcription only: how many of the
    # judge's deductions were critical and minor (`scoring._store_scored` reads
    # them off the point sizes). Written once at grading and never recomputed
    # from `llm_deductions_json` - PII erasure blanks that, and a mark derived
    # from it would turn an erased failing answer into a pass.
    llm_critical_count = fields.Integer(
        string="Critical Mistakes", readonly=True, copy=False)
    llm_minor_count = fields.Integer(
        string="Minor Mistakes", readonly=True, copy=False)
    llm_raw_score = fields.Float(
        string="Subjective Raw (0-1)", compute="_compute_subjective_marks",
        store=True, readonly=True, copy=False,
        help="llm_raw_100 expressed as a 0-1 fraction (display).")

    # ── The per-question totals every attempt aggregate is built from ──────
    #
    # THE UNIT OF SCORING IS THE COMPONENT, NOT THE QUESTION. A question is
    # worth the sum of its components and each one is worth exactly 1: every
    # keyed sub-question, the LLM-graded free-text answer, and a labelling box
    # set as a whole. So `final_mark` is 0..N, not 0/1, and `final_max` says
    # what the N is - read them as a pair, never alone.
    #
    # EVERY COMPONENT CARRIES A RAW, so `raw_max` equals `final_max` and the two
    # fractions share a denominator. A keyed dimension's raw IS its mark (there
    # is no partial credit inside a dimension, so there is nothing else it could
    # be); a graded component contributes its ungated 0.0-1.0. The pair still
    # answers a different question from the marks - "by how much", not "did it
    # clear" - and they diverge exactly where a graded answer's quality and its
    # pass/fail disagree.
    #
    # The objective half used to be excluded from the raw entirely, on the
    # argument that its raw would only restate its mark. It does restate it; the
    # cost of leaving it out was that the raw and the mark were quoted out of
    # DIFFERENT denominators on the same screen ("Raw score 1.40 / 2" beside
    # "3 / 5"), which read as an error in the numbers rather than a distinction
    # between them.
    #
    # Read docs/ETP_KNOWLEDGE_BASE.md (4.6 Scoring, in engineering terms) before changing any of this.
    mcq_mark = fields.Float(
        string="Objective Marks Earned", compute="_compute_final_marks",
        store=True, readonly=True, copy=False,
        help="How many of this question's keyed sub-questions were exactly "
             "right, out of `objective_max`. Each is worth 1; one missing or "
             "one extra option scores that sub-question 0.")
    objective_marks_max = fields.Integer(
        string="Objective Marks Available", compute="_compute_final_marks",
        store=True, readonly=True, copy=False,
        help="How many keyed sub-questions this question has. A dimension with "
             "no correct option is keyless and counts here as 0.")
    label_fraction = fields.Float(
        string="Labelling Fraction (0-1)", compute="_compute_subjective_marks",
        store=True, readonly=True, copy=False, digits=(16, 4),
        help="Share of this question's labelling boxes whose graded raw "
             "cleared the subjective threshold. This is the figure the "
             "labelling mark's own threshold test uses.")
    label_box_scores_json = fields.Text(
        string="Per-Box Raw Scores (JSON)", readonly=True, copy=False,
        help="The grader's raw 0-100 for EACH labelling box, keyed by box "
             "number. Immutable truth: the per-box pass/fail, the fraction and "
             "the mark are all derived from this live, so moving the threshold "
             "re-decides a labelling question without re-running the LLM.")
    final_mark = fields.Float(
        string="Question Marks Earned", compute="_compute_final_marks",
        store=True, readonly=True, copy=False,
        help="What this question earned: the sum of its component marks, 0 to "
             "`final_max`. Every component is worth 1 and is won or lost on "
             "its own - there is no partial credit inside a component and no "
             "conjunction across them.")
    final_max = fields.Integer(
        string="Question Marks Available", compute="_compute_final_marks",
        store=True, readonly=True, copy=False,
        help="What this question is worth: one mark per keyed sub-question, "
             "plus one for the graded free-text answer, plus one for the "
             "labelling box set. Computed from the QUESTION, so an unanswered "
             "question still occupies its marks in the paper's denominator.")
    raw_score = fields.Float(
        string="Question Raw Earned", compute="_compute_final_marks",
        store=True, readonly=True, copy=False, digits=(16, 4),
        help="Ungated quality over ALL of this question's components, each "
             "contributing 0.0-1.0: a keyed sub-question contributes its own "
             "mark, a graded answer its 0-100 as a fraction.")
    raw_max = fields.Integer(
        string="Question Raw Available", compute="_compute_final_marks",
        store=True, readonly=True, copy=False,
        help="How many components this question has - the same number as "
             "`final_max`, because every component carries a raw.")
    llm_passed = fields.Boolean(
        string="Subjective Passed", compute="_compute_subjective_marks",
        store=True, readonly=True, copy=False)
    llm_score = fields.Integer(
        string="Subjective Mark", compute="_compute_subjective_marks",
        store=True, readonly=True, copy=False,
        help="EQUAL-MARKS earned mark: 1 when llm_raw_100 >= the per-answer "
             "subjective threshold, else 0. Computed, never frozen.")
    llm_max_score = fields.Integer(
        string="Subjective Max", compute="_compute_subjective_marks",
        store=True, readonly=True, copy=False,
        help="Always 1 for a needs_llm answer (equal marks). Computed, so it "
             "never drifts as scoring progresses.")
    llm_feedback = fields.Text(string="Subjective Reasoning", readonly=True, copy=False)
    llm_gate = fields.Char(
        string="Scoring Gate", readonly=True, copy=False,
        help="The SOP gate that fired (empty_answer, off_topic, wrong_item, "
             "injection_attempt, ...) or 'none'.")
    llm_rubric_source = fields.Char(
        string="Rubric Source", readonly=True, copy=False,
        help="'supplied' when the item carried a grading block, 'generated' "
             "when the grader authored one from the prompt + skill.")
    llm_reference_answer = fields.Text(
        string="Reference Answer", readonly=True, copy=False,
        help="The grader's quasi-ground-truth model answer used to anchor "
             "judging.")
    llm_reasoning = fields.Text(
        string="Scoring Audit", readonly=True, copy=False,
        help="The grader's full evidence-first audit: each checklist point with "
             "its quote and finding, constraints, quality errors, and what "
             "capped the score.")
    llm_flags_json = fields.Text(
        string="Scoring Flags (JSON)", readonly=True, copy=False)
    llm_result_json = fields.Text(
        string="Full Scoring Result (JSON)", readonly=True, copy=False,
        help="The complete per-field v6 result object from the grader, kept "
             "for audit.")
    llm_key_closeness = fields.Float(
        string="Key Closeness (0-100)", readonly=True, copy=False,
        help="v10: how close the worker answer is to the golden answer, judged "
             "claim by claim. Weight 0.60 of the score.")
    # Project-aware (drop 2) scoring outputs — queryable, surfaced in Review
    # Answers so the candidate sees WHY, itemized, not a raw JSON blob.
    llm_profile = fields.Char(
        string="Scoring Profile", readonly=True, copy=False,
        help="The project profile the platform detected for this item and graded "
             "it under (P1 Image A/B, P2 Defect Annotation, P3 UI Labelling, P4 "
             "Image Prompt, P5 Video Prompt, P6 Multiple Choice, P7 "
             "Transcription, or General).")
    llm_verdict = fields.Char(
        string="Scoring Verdict", readonly=True, copy=False,
        help="The judge's one-line overall judgement for this answer.")
    llm_deductions_json = fields.Text(
        string="Deductions (JSON)", readonly=True, copy=False,
        help="Project-aware score accounting: each lost-point line "
             "{points, reason, evidence}. The item score = 100 + sum(points); the "
             "platform re-derives it as a provable cross-check. Surfaced as a "
             "clean itemized list in Review Answers.")
    llm_credit_json = fields.Text(
        string="Credit (JSON)", readonly=True, copy=False,
        help="Project-aware score accounting: what the worker got RIGHT, each "
             "{reason, evidence} with the worker's own words.")
    llm_sop_coverage = fields.Float(
        string="SOP Coverage (0-100)", readonly=True, copy=False,
        help="v10: how many of the question's required elements the answer "
             "demonstrates. Weight 0.25 of the score.")
    llm_clarity = fields.Char(
        string="Clarity", readonly=True, copy=False,
        help="v10: clear / mixed / unclear. Weight 0.15 of the score.")
    llm_ai_confidence = fields.Char(
        string="AI-likeness Confidence", readonly=True, copy=False,
        help="v10: none / medium / high. Never changes the score, a flag only.")
    llm_verdict_consistency = fields.Char(
        string="Verdict Consistency", readonly=True, copy=False,
        help="v10: match / contradiction / indeterminate / not_applicable - "
             "does the worker's committed verdict agree with the answer key.")
    llm_golden_claims_json = fields.Text(
        string="Golden Claims (JSON)", readonly=True, copy=False,
        help="v10: the golden answer decomposed into deciding/supporting claims "
             "with the worker's per-claim hit/partial/miss verdict + evidence "
             "quote. The audit trail of how key closeness was judged.")
    llm_attempts = fields.Integer(
        string="Subjective Attempts", default=0, copy=False)
    llm_judge_model = fields.Char(
        string="Judge Model", readonly=True, copy=False,
        help="The exact Vertex model that produced this subjective score. "
             "Recorded so a hire/reject decision is auditable and a re-grade "
             "can be pinned to the same model. Empty for gated/verdict-only "
             "answers that never called the model.")
    llm_prompt_version = fields.Char(
        string="Judge Prompt Version", readonly=True, copy=False,
        help="Which grading prompt produced this score: a short "
             "content-addressed id of the system prompt the judge was given "
             "(e.g. 'bundled:3f9a1c2d' or 'override:7b4e02aa'). Recorded for "
             "the same reason as the judge model - two candidates graded "
             "under different prompts were not graded to the same standard, "
             "and until now nothing on the record said which one applied. "
             "Empty means the score predates versioning; it does NOT mean the "
             "score is wrong.")
    llm_scored_hash = fields.Char(
        string="Scored Answer Hash", copy=False,
        help="H-16: sha256 of the justification (and image_ab picks) that "
             "was last graded. A re-submit with identical text is not "
             "re-queued (stops a scored answer being re-scored in a loop when "
             "llm_auto_score is on).")
    rescore_request_key = fields.Char(
        string="Re-score Request", readonly=True, copy=False,
        help="Set when an admin asks for this one answer (or a chosen few) to "
             "be re-scored: one random key per click. The grading cron takes "
             "these first and grades each click's answers on their own, never "
             "together with another click or another candidate. Cleared once "
             "the answer is graded, errors out for good, or scoring is "
             "killed. Empty = no re-score waiting.")
    llm_state = fields.Selection(
        [
            ("not_needed", "Not Needed"),
            ("pending", "Pending"),
            ("queued", "Queued"),
            ("scored", "Scored"),
            ("failed", "Failed"),
            ("error", "Scoring Error"),
        ],
        default="not_needed",
        string="Subjective State",
        copy=False,
        help="scored = the grader returned a usable 0-100 score. error = the "
             "scoring call/parse failed after all attempts (surfaced, NOT a "
             "silent 0). failed = a recoverable miss the cron will retry.")

    subjective_score = fields.Integer(
        related="llm_score", string="Subjective Mark", readonly=True,
        help="The earned equal-marks subjective mark (0 or 1). For the raw "
             "0-100 grader score see llm_raw_100.")
    subjective_result = fields.Selection(
        [("pass", "Pass"), ("fail", "Fail")],
        string="Subjective Result", compute="_compute_subjective_result",
        store=True)
    subjective_reasoning = fields.Text(
        related="llm_feedback", string="Subjective Reasoning ", readonly=True)

    question_type = fields.Selection(
        related="question_id.question_type", string="Question Type",
        readonly=True)
    answer_summary = fields.Char(
        compute="_compute_answer_summary", string="Candidate Answer")
    correct_summary = fields.Char(
        compute="_compute_answer_summary", string="Correct Answer")
    ab_mcq_pct = fields.Float(
        compute="_compute_ab_scores", string="Verdict %",
        help="image_ab: % of scoring axes whose chosen verdict matches the key "
             "(objective, no LLM).")
    ab_final_pct = fields.Float(
        compute="_compute_ab_scores", string="Final %",
        help="image_ab RAW 0-100: the grader's score for the WRITTEN "
             "JUSTIFICATION and nothing else, read straight off llm_raw_100. "
             "The justification is the only part of an image_ab that carries a "
             "raw at all. NOTHING IS BLENDED into this any more: the verdict "
             "axes are keyed sub-questions, marked one mark each on whether "
             "the chosen verdict matches the key, and they never pass through "
             "a raw score - so this no longer starts at 75 before a word is "
             "read, and there is no AND between the verdicts and this figure. "
             "For the verdict lane read ab_mcq_pct beside it. The ceil() in "
             "_compute_ab_scores is a DISPLAY fallback for an answer the "
             "grader has not reached yet; the stored mark is never rounded "
             "up.")

    integrity_alert = fields.Boolean(
        string="Integrity Alert", compute="_compute_integrity_alert",
        store=True, copy=False,
        help="Read-only audit flag: True when the scoring audit signals an "
             "integrity event - a Phase-1 gate (empty_answer/injection_attempt), "
             "a Phase-3 answer-key drift, or an integrity/key_drift flag. "
             "Display + filter only; never affects the score or pass/fail.")
    ab_verdict_pct = fields.Float(
        string="AB Verdict %", compute="_compute_audit_subscores",
        help="image_ab verdict-lane sub-score read from the scoring audit "
             "(0-100). Display-only; does NOT affect llm_raw_100 or the mark.")
    ab_justification_pct = fields.Float(
        string="AB Justification %", compute="_compute_audit_subscores",
        help="image_ab justification-lane sub-score from the audit (0-100); "
             "0 when the answer was verdict-only. Display-only.")
    label_coverage_pct = fields.Float(
        string="Label Coverage %", compute="_compute_audit_subscores",
        help="Share of this question's labelling boxes the candidate actually "
             "attempted, 0-100. Coverage is now a REPORTING figure only - an "
             "unattempted box scores 0 on its own rather than ceilinging the "
             "whole answer. Display-only.")
    label_correctness_pct = fields.Float(
        string="Label Correctness %", compute="_compute_audit_subscores",
        help="Mean of this question's per-box raw scores, 0-100 - how well the "
             "boxes were labelled, ungated. The MARK comes from how many boxes "
             "individually cleared the threshold, not from this. Display-only.")

    @staticmethod
    def _audit_json(text):
        if not text:
            return None
        try:
            return json.loads(text)
        except (ValueError, TypeError):
            return None

    @api.depends("llm_gate", "llm_flags_json", "llm_result_json")
    def _compute_integrity_alert(self):
        # The FLAG vocabulary, not the gate vocabulary - a flag rides in
        # llm_flags_json while a gate lands in llm_gate. They share the
        # key_drift spelling on purpose, so name it from the one constant
        # rather than restating the literal and letting them drift apart.
        flag_alerts = ("integrity_alert", GATE_KEY_DRIFT)
        for rec in self:
            alert = is_integrity_gate(rec.llm_gate)
            if not alert:
                flags = rec._audit_json(rec.llm_flags_json)
                if isinstance(flags, list):
                    alert = any(
                        str(f).strip().lower() in flag_alerts for f in flags)
            if not alert:
                audit = rec._audit_json(rec.llm_result_json)
                if isinstance(audit, dict):
                    if audit.get("integrity_gated") or \
                            audit.get("integrity_key_drift"):
                        alert = True
                    else:
                        afl = audit.get("flags")
                        if isinstance(afl, list):
                            alert = any(
                                str(f).strip().lower() in flag_alerts
                                for f in afl)
            rec.integrity_alert = alert

    @staticmethod
    def _pct_from_fraction(value):
        try:
            return round(max(0.0, float(value)) * 100.0, 2)
        except (TypeError, ValueError):
            return 0.0

    @api.depends("llm_result_json")
    def _compute_audit_subscores(self):
        for rec in self:
            audit = rec._audit_json(rec.llm_result_json)
            ab = audit.get("ab_scores") if isinstance(audit, dict) else None
            lab = audit.get("label_scores") if isinstance(audit, dict) else None
            ab = ab if isinstance(ab, dict) else {}
            lab = lab if isinstance(lab, dict) else {}
            rec.ab_verdict_pct = rec._pct_from_fraction(ab.get("verdict_score"))
            rec.ab_justification_pct = rec._pct_from_fraction(
                ab.get("justification_score"))
            # Read from the per-box audit `_apply_image_label_boxes` writes.
            # `label_correctness_pct` used to read a "correctness" key that lane
            # stopped emitting long ago, so it read 0.0 on every row ever
            # scored; it now carries the mean box raw, which is the number the
            # column's name always promised.
            total_boxes = lab.get("total_boxes") or 0
            attempted = lab.get("attempted_boxes") or 0
            rec.label_coverage_pct = (
                round(100.0 * attempted / total_boxes, 2)
                if total_boxes else 0.0)
            # Already 0-100 (the mean of per-box raws), so it is NOT run
            # through _pct_from_fraction - that helper multiplies a 0-1
            # fraction by 100 and would report 8200% for a mean of 82.
            try:
                rec.label_correctness_pct = round(
                    float(lab.get("mean_box_raw") or 0.0), 2)
            except (TypeError, ValueError):
                rec.label_correctness_pct = 0.0

    def init(self):
        self._cr.execute("""
            CREATE UNIQUE INDEX IF NOT EXISTS assessments_be_response_uniq_eval_q_sess
            ON assessments_be_response
               (assessment_evaluator_id, question_id)
        """)
        # The cron asks "which candidates have a re-score waiting?" every tick.
        # Partial, so it holds only the handful of keyed rows, never the whole
        # answers table; its one-off build is a scan with nothing to insert.
        self._cr.execute("""
            CREATE INDEX IF NOT EXISTS assessments_be_response_rescore_idx
            ON assessments_be_response (assessment_evaluator_id)
            WHERE rescore_request_key IS NOT NULL
        """)

    @api.depends("line_ids.selected_option_id",
                 "question_id.question_dimension_ids.option_line_ids.is_correct")
    def _compute_answer_summary(self):
        for rec in self:
            rec_s = rec.sudo()
            chosen = [
                line.selected_option_id.name
                for line in rec_s.line_ids
                if line.selected_option_id
            ]
            rec.answer_summary = ", ".join(chosen)
            # A transcription left empty on purpose (its category says the
            # clip is not transcribed) is an answer, not a blank.
            if (rec_s.question_id.question_type == "transcription"
                    and not (rec_s.justification or "").strip()):
                category = rec_s._clip_answers().get("category")
                if category not in (None, "", "none"):
                    rec.answer_summary = "Not transcribed: %s" % (
                        category.replace("_", " "))
            correct = []
            for qd in rec_s.question_id.question_dimension_ids:
                for ol in qd.option_line_ids.filtered("is_correct"):
                    if ol.name:
                        correct.append(ol.name)
            rec.correct_summary = ", ".join(correct)

    def _dimension_marks(self):
        """(earned, total) over this question's KEYED sub-questions.

        Each keyed dimension is one component worth 1 mark, earned only when
        the candidate's selected option set equals the key set EXACTLY - one
        missing or one extra scores that dimension 0. That is the same rule for
        mcq, for msq and for every image_ab verdict axis, which is why there is
        one helper rather than three.

        NO PARTIAL CREDIT INSIDE A DIMENSION, and none across them either. The
        old rule was all-or-nothing across the WHOLE question, so a candidate
        who got two of three sub-questions right scored the same as one who got
        none. Each sub-question now stands or falls on its own; what does not
        happen is a fraction of a single sub-question.

        A keyless dimension is not a component and is counted in neither
        number - see `_keyed_dimension_count` on the question.
        """
        self.ensure_one()
        earned = total = 0
        for qd in self.question_id.question_dimension_ids:
            key = set(qd.option_line_ids.filtered("is_correct").ids)
            if not key:
                continue
            total += 1
            chosen = {line.selected_option_id.id for line in self.line_ids
                      if line.question_dimension_id.id == qd.id
                      and line.selected_option_id}
            if chosen == key:
                earned += 1
        return earned, total

    def _image_ab_mcq_pct(self):
        """The verdict axes as a percentage, for DISPLAY only.

        The mark is `_dimension_marks`; this is the same fact rendered for the
        audit surfaces, which have always shown a percentage here.
        """
        self.ensure_one()
        earned, total = self._dimension_marks()
        return (earned / total * 100.0) if total else 0.0

    def _has_mcq_component(self):
        self.ensure_one()
        return self.question_id.question_type in ("mcq", "msq", "image_ab")

    def _clip_answers(self):
        """The saved clip answers as a dict ({} when none were saved)."""
        self.ensure_one()
        try:
            data = json.loads(self.clip_answers_json or "{}")
        except (TypeError, ValueError):
            return {}
        return data if isinstance(data, dict) else {}

    def _transcription_has_answer(self):
        """A transcription is answered by its text OR by a category other than
        None: that category means the clip is not transcribed, so an empty box
        is the complete answer."""
        self.ensure_one()
        return bool((self.justification or "").strip()) or (
            self._clip_answers().get("category") not in (None, "", "none"))

    def _graded_answer_hash(self):
        """H-16's sha256 of what the grader is shown: the justification, plus
        the picks on an image_ab (`scoring._build_item` sends them too) and the
        clip answers on a transcription."""
        self.ensure_one()
        text = self.justification or ""
        if self.question_id.question_type == "transcription":
            text += self.clip_answers_json or ""
        if self.question_id.question_type == "image_ab":
            text += json.dumps(sorted(
                (line.question_dimension_id.id, line.selected_option_id.id)
                for line in self.line_ids))
        return hashlib.sha256(text.encode("utf-8")).hexdigest()

    def _image_ab_uses_llm(self):
        """Whether this image_ab answer has a justification to grade.

        NO LONGER A SETTING. It used to AND in
        `require_justification_image_comparison`, so an operator could switch
        image_ab to verdict-only - which never reached the LLM at all while
        `needs_llm` stayed true, so the awaiting-scoring counters and the
        rescore button kept counting answers the grader had short-circuited.
        Blended is now the only scoring mechanism.

        What remains is degenerate, not configured, and there are TWO ways
        to be degenerate:

        * the candidate wrote nothing, so there is no justification to mark; or
        * the QUESTION carries no `official_reasoning`, so there is no
          standard to mark one against. Form Studio publishes a comparison on
          its verdict alone, and `prompts/scoring.md` grades the justification
          "against official_reasoning" - handing the judge an empty standard
          is how a rubric gets invented per candidate, which is exactly what
          an answer key exists to prevent. `question._component_counts` drops
          the mark for the same reason, so these two must agree: no standard
          means no LLM call, no mark, and no component left pending.

        Either way the answer falls to the verdict-only store rather than
        paying for a call whose result could not be trusted.
        """
        self.ensure_one()
        return bool(
            self.question_id.question_type == "image_ab"
            and (self.justification or "").strip()
            and (self.question_id.official_reasoning or "").strip())

    @api.depends("question_id.question_type", "line_ids.selected_option_id",
                 "line_ids.question_dimension_id",
                 "question_id.question_dimension_ids.option_line_ids.is_correct",
                 "llm_raw_100", "llm_state")
    def _compute_ab_scores(self):
        for rec in self:
            if rec.question_id.question_type != "image_ab":
                rec.ab_mcq_pct = 0.0
                rec.ab_final_pct = 0.0
                continue
            mcq = rec._image_ab_mcq_pct()
            rec.ab_mcq_pct = round(mcq, 2)
            if rec.llm_state == "scored":
                rec.ab_final_pct = round(rec.llm_raw_100 or 0.0, 2)
            else:
                rec.ab_final_pct = float(math.ceil(mcq))

    def _subjective_threshold(self):
        """This assessment's pass bar, clamped, with the module default as the
        floor-and-ceiling fallback.

        One helper because the same clamp used to be written out in three
        places, and three copies of a rule is three chances for one of them to
        drift from the other two.
        """
        self.ensure_one()
        # A transcription clip's own bar, while set (R7); 0 follows subjective.
        raw_t = (self.question_id.question_type == "transcription"
                 and self.assessment_id.transcription_threshold
                 ) or self.assessment_id.subjective_threshold
        return raw_t if 0.0 <= raw_t <= 100.0 else DEFAULT_SUBJECTIVE_THRESHOLD

    def _label_box_raws(self):
        """The grader's per-box raws as {box number: 0-100}, or {} if none.

        Tolerant on the way in - the judge writes the keys as strings, and a
        box it failed to score at all must not take the whole question down
        with a parse error.
        """
        self.ensure_one()
        try:
            data = json.loads(self.label_box_scores_json or "{}")
        except (ValueError, TypeError):
            return {}
        if not isinstance(data, dict):
            return {}
        out = {}
        for k, v in data.items():
            try:
                out[int(k)] = max(0.0, min(100.0, float(v)))
            except (TypeError, ValueError):
                continue
        return out

    def _label_marks(self, threshold):
        """(mark, raw, fraction) for the labelling component of this answer.

        Each box is thresholded on its OWN raw, so a box clears or it does not;
        `fraction` is the share that cleared. The component's single mark is
        then that fraction tested against the same bar - 18 of 20 boxes at a
        60% bar is 0.9, which clears; 11 of 20 is 0.55, which does not.

        `raw` is the ungated twin: the mean of the box raws, 0.0-1.0.

        THE DENOMINATOR IS HOW MANY BOXES THE TASK ASKED FOR, never the number
        the grader happened to return. Normally that is the question's whole
        key: a box the grader omitted, or one the candidate never attempted,
        scores 0 rather than shrinking the denominator, or answering one box out
        of twenty and getting it right would read as a perfect score.

        "ANY N OF M" IS THE ONE CASE WHERE IT IS SMALLER. When the examiner said
        a complete answer marks three of the five boxes
        (`label_expected_count`), three is the denominator, and the candidate
        picks WHICH three: their best three by raw are the three that count.
        That follows from what the task said rather than being a kindness - the
        candidate was invited to choose, so a fourth box labelled badly is extra
        work, not a wrong answer, and it must not be able to pull the mark down.
        Attempting FEWER than three is the opposite case: the shortfall is
        unanswered, scores 0, and stays in the denominator, or a candidate could
        shrink the paper by leaving boxes blank.

        A box counts as attempted on the platform's existing rule - at least 2
        non-space characters, `_label_attempted_box_numbers` - and that rule
        lives in exactly one place on purpose. A second definition of
        "attempted" here would drift from the one `_apply_image_label_boxes`
        zeroes boxes with, and the two would disagree about the same answer.
        """
        self.ensure_one()
        from ..services import scoring as scoring_svc
        raws = self._label_box_raws()
        total = scoring_svc._label_total_boxes(self.question_id)
        if total <= 0:
            # No answer key to mark against. The question still costs its mark
            # (an authoring fault is not a candidate failure to hide) but there
            # is nothing to award.
            return 0.0, 0.0, 0.0
        if self.llm_state != "scored":
            return 0.0, 0.0, 0.0
        expected = scoring_svc._label_expected_boxes(self.question_id, total)
        if expected >= total:
            # The task asked for every box, which is every question that has
            # not been told otherwise. Read the whole key straight through -
            # no selection, and no attempted filter either, because a box
            # nobody attempted is already stored at 0 by
            # `_apply_image_label_boxes` and still owes its place in the
            # denominator.
            numbers = range(1, total + 1)
        else:
            # Their best `expected` boxes, chosen from the ones they actually
            # attempted. Unattempted boxes are excluded from the CHOICE rather
            # than scored 0 in it: with a subset denominator the two are not
            # the same, and letting a blank box win a slot would spend one of
            # the candidate's N on nothing.
            attempted = scoring_svc._label_attempted_box_numbers(self)
            numbers = sorted(
                (n for n in attempted if 1 <= n <= total),
                key=lambda n: raws.get(n, 0.0), reverse=True)[:expected]
        passed = sum(1 for n in numbers if raws.get(n, 0.0) >= threshold)
        summed = sum(raws.get(n, 0.0) for n in numbers)
        # `expected`, not len(numbers): a short answer is short, and dividing by
        # what they managed to attempt would hand full marks for two good boxes
        # out of the three the task asked for.
        fraction = passed / expected
        mark = 1.0 if fraction * 100.0 >= threshold else 0.0
        return mark, (summed / expected) / 100.0, fraction

    # `justification` and `label_expected_count` are here because `_label_marks`
    # now reads both: an "any N of M" question picks the candidate's best N from
    # the boxes they ATTEMPTED, and attempted is read off the answer JSON in
    # `justification`. These are stored computes, so a dependency the compute
    # reads but does not declare is a stale mark sitting in the database - an
    # examiner correcting the expected count would see the old fraction until
    # something unrelated happened to touch the row.
    @api.depends("llm_raw_100", "llm_state", "needs_llm",
                 "label_box_scores_json", "justification",
                 "question_id.question_type",
                 # Read below to decide whether image_ab has a gradable
                 # written component at all. Undeclared, adding a golden
                 # answer to a published comparison would leave
                 # `llm_max_score` stale at 0 and the justification unmarked.
                 "question_id.official_reasoning",
                 "question_id.image_ids.label_expected_count",
                 "assessment_id.subjective_threshold",
                 "assessment_id.transcription_threshold",
                 "llm_critical_count", "llm_minor_count")
    def _compute_subjective_marks(self):
        """The LLM-graded half: its raw, whether it cleared, and its mark.

        `llm_score` is 1 or 0 for the ordinary graded free-text answer. For a
        labelling question it is the labelling component's mark instead, which
        is decided per box and then on the share that cleared - see
        `_label_marks`.

        image_ab no longer gets a special case. Its justification is an
        ordinary graded answer now that the verdicts are marked as their own
        components, so the 0.75/0.25 blend that used to be folded into
        `llm_raw_100` before it reached here is gone.
        """
        for rec in self:
            threshold = rec._subjective_threshold()
            qtype = rec.question_id.question_type or ""
            if qtype in LABELLING_COMPONENT_TYPES:
                mark, raw, fraction = rec._label_marks(threshold)
                rec.label_fraction = round(fraction, 4)
                rec.llm_raw_score = round(raw, 4)
                rec.llm_max_score = 1
                rec.llm_passed = bool(mark)
                rec.llm_score = int(mark)
                continue
            rec.label_fraction = 0.0
            # An image_ab with no `official_reasoning` has no gradable
            # written component, so it is scored like a type that has none at
            # all. This MUST agree with `question._component_counts`, which
            # drops the same mark from the denominator: were `llm_max_score`
            # left at 1 here, the question would report a mark out of a total
            # nobody could earn and every candidate would lose it. See
            # `_image_ab_uses_llm`.
            no_written_standard = (
                qtype == "image_ab"
                and not (rec.question_id.official_reasoning or "").strip())
            if qtype not in SUBJECTIVE_COMPONENT_TYPES or no_written_standard:
                rec.llm_raw_score = 0.0
                rec.llm_passed = False
                rec.llm_score = 0
                rec.llm_max_score = 0
                continue
            raw100 = rec.llm_raw_100 or 0.0
            rec.llm_raw_score = round(raw100 / 100.0, 4)
            rec.llm_max_score = 1
            passed = rec.llm_state == "scored" and raw100 >= threshold
            if qtype == "transcription":
                # The client's rule on top of ours: one critical mistake, or
                # five minor ones, fails the clip whatever the score.
                passed = passed and not rec.llm_critical_count and (
                    (rec.llm_minor_count or 0) < TRANSCRIPTION_MINOR_LIMIT)
            rec.llm_passed = passed
            rec.llm_score = 1 if passed else 0

    @api.depends("line_ids.selected_option_id", "line_ids.question_dimension_id",
                 "question_id.question_type",
                 "question_id.question_dimension_ids.option_line_ids.is_correct",
                 # `_component_counts` reads it to decide whether an image_ab
                 # carries a justification mark, so `final_max`/`raw_max` move
                 # when a golden answer is added or removed.
                 "question_id.official_reasoning",
                 "llm_score", "llm_raw_score", "llm_passed", "llm_state",
                 "label_fraction")
    def _compute_final_marks(self):
        """Add this question's components up into its marks and its raw.

        EVERY COMPONENT IS WORTH 1 AND IS WON OR LOST ON ITS OWN. There is no
        weighting between the halves of a question any more and no conjunction
        across them: an image_ab candidate who calls three of four verdicts
        right and writes a weak justification scores 3, not 0 and not 3.75.
        The old rule made the whole question all-or-nothing, which meant one
        wrong verdict cost every mark on it.

        THE RAW COVERS EVERY COMPONENT, objective ones included. A keyed
        dimension's raw is its mark - there is no partial credit inside a
        dimension, so "how well" and "did it clear" are the same fact for it -
        while a graded component contributes its ungated 0.0-1.0. The two
        numbers therefore differ only where there is something to differ about:
        an answer graded 80 against a threshold of 60 earns 1 mark and 0.80 raw.

        The objective half used to be excluded from the raw on both sides. That
        was defensible per-answer and unreadable in aggregate: a paper of three
        MCQs and two written answers reported its raw out of 2 beside a mark out
        of 5, and the two could not be compared at all.
        """
        for rec in self:
            dim_earned, dim_total = rec._dimension_marks()
            marks, raw_marks = rec.question_id._component_counts()
            rec.mcq_mark = float(dim_earned)
            rec.objective_marks_max = dim_total
            rec.final_max = marks
            rec.raw_max = raw_marks
            # `llm_score` / `llm_raw_score` already carry whichever LLM-graded
            # component this question has - the graded free-text answer, or the
            # labelling box set. Both are 1 mark, and a question never has both
            # (a labelling answer's boxes live in the same `justification`
            # column the free-text answer would), so one term covers each.
            rec.final_mark = float(dim_earned) + float(rec.llm_score or 0)
            # `dim_earned`, not `mcq_mark`: both hold the same number, but the
            # local is the one this method just computed and does not depend on
            # the write above having landed.
            rec.raw_score = round(
                float(dim_earned) + float(rec.llm_raw_score or 0.0), 4)

    @api.depends("llm_state", "llm_passed", "needs_llm")
    def _compute_subjective_result(self):
        for rec in self:
            if rec.needs_llm and rec.llm_state == "scored":
                rec.subjective_result = "pass" if rec.llm_passed else "fail"
            else:
                rec.subjective_result = False

    @api.depends("question_id", "question_id.question_type", "justification",
                 "auto_submitted", "line_ids.selected_option_id",
                 "clip_answers_json")
    def _compute_scoring_kind(self):
        for rec in self:
            qtype = rec.question_id.question_type
            rec.has_objective = qtype in ("mcq", "msq")
            just = (rec.justification or "").strip()
            # L-5: trust the auto_submitted flag; fall back to the legacy prefix
            # only for rows written before the field existed (upgrade safety).
            is_placeholder = rec.auto_submitted or just.startswith(
                "[Auto-submitted")
            if qtype == "image_ab":
                rec.needs_llm = bool(rec.line_ids) and not is_placeholder
            elif qtype == "transcription":
                rec.needs_llm = (rec._transcription_has_answer()
                                 and not is_placeholder)
            else:
                rec.needs_llm = (
                    qtype in ("subjective_rubric",
                              "image_prompt", "image_label", "video_prompt")
                    and bool(just)
                    and not is_placeholder
                )

    @api.depends("line_ids.selected_option_id", "line_ids.question_dimension_id",
                 "question_id.question_type",
                 "question_id.question_dimension_ids.option_line_ids.is_correct")
    def _compute_score(self):
        """The objective tally, in the SAME currency as every other mark.

        This used to be its own scoring rule: all-or-nothing across the whole
        question, 1 out of 1. That made it disagree with `final_mark` the day
        the unit of scoring became the component - a candidate who got two of
        three sub-questions right earned 2 marks here and scored 0 out of 1
        there, and the candidate review reads THESE columns for its
        Correct/Incorrect label, so it called that answer "Incorrect".

        There is one rule now: each keyed sub-question is worth 1.

        A keyless objective question still scores 0/0 and drops OUT of the
        denominator - `_dimension_marks` skips unkeyed dimensions, so that
        falls out of the count rather than needing its own branch.
        """
        for rec in self:
            if rec.question_id.question_type not in ("mcq", "msq"):
                rec.score = 0
                rec.max_score = 0
                continue
            earned, total = rec._dimension_marks()
            rec.score = earned
            rec.max_score = total

    def _is_answered(self):
        """THE ONE DEFINITION of "answered", for every count an admin reads.

        Submitted is not enough: settlement writes a submitted, empty
        placeholder (`auto_submitted`) for every question left blank, so
        counting submitted rows read answered = questions on every handed-in
        paper. A cleared answer is draft and empty. Content is a chosen
        option or text (label answers are stored as JSON in `justification`).
        The legacy prefix test mirrors `_compute_scoring_kind`, for rows
        written before `auto_submitted` existed.
        """
        self.ensure_one()
        just = (self.justification or "").strip()
        return bool(self.state == "submitted" and not self.auto_submitted
                    and not self.cleared
                    and not just.startswith("[Auto-submitted")
                    and (self.line_ids or just
                         # A clip marked "not transcribed" is answered empty.
                         or (self.question_id.question_type == "transcription"
                             and self._transcription_has_answer())))

    def action_rescore_this_answer(self):
        """Odoo's "Re-score This Answer": this one answer, graded on its own."""
        self.ensure_one()
        if not self.assessment_evaluator_id:
            raise UserError("This answer belongs to no attempt.")
        return self.assessment_evaluator_id.action_rescore_individually(
            question_ids=[self.question_id.id])

    def action_submit(self):
        for rec in self:
            if rec.state == "submitted":
                raise UserError("This response is already submitted.")
            if (rec.assessment_evaluator_id
                    and rec.assessment_evaluator_id.is_locked):
                raise UserError(
                    "This assessment is already locked. Cannot modify responses.")
            qtype = rec.question_id.question_type
            has_dims = bool(rec.question_id.question_dimension_ids)
            if qtype in ("mcq", "msq", "image_ab") and not rec.line_ids:
                raise UserError(
                    "Please answer at least one dimension before submitting.")
            # A Form Studio rubric carries its answer in the axes; its
            # free-text item is conditional ("explain any FAILED check"), so a
            # candidate who passed everything has nothing to write. Same rule
            # as the API and portal _record_response. A rubric with no axes is
            # still pure prose and still requires it.
            carried_by_axes = (qtype == "subjective_rubric"
                               and has_dims and bool(rec.line_ids))
            if qtype in ("subjective_rubric",
                         "image_prompt", "image_label", "video_prompt") \
                    and not (rec.justification or "").strip() \
                    and not carried_by_axes:
                raise UserError(
                    "Please provide a justification before submitting.")
            # video_prompt BELONGS HERE and was missing. Its checks used to
            # be collected and scored nothing, so not requiring them cost the
            # candidate nothing either. They are keyed sub-questions now and
            # carry a mark each, so leaving them ungated let a candidate submit
            # and silently lose marks on questions nobody told them to answer.
            # subjective_rubric's rating items are marks too - same gate as
            # the API's held draft for it.
            if qtype in ("subjective_rubric", "image_prompt", "image_label",
                         "video_prompt") \
                    and rec.question_id.question_dimension_ids.filtered(
                        "option_line_ids") \
                    and not rec.line_ids:
                raise UserError(
                    "Please answer the multiple-choice checks before "
                    "submitting.")
            rec.write({"state": "submitted"})

            if qtype == "image_ab" or (rec.justification or "").strip() or (
                    qtype == "transcription"
                    and rec._transcription_has_answer()):
                rec._enqueue_subjective_scoring()

            # SAVING AN ANSWER DOES NOT END THE SITTING.
            #
            # This used to call `_check_all_submitted`, which locked the
            # evaluator the moment the submitted-response count reached
            # `total_questions`. Answering the last question therefore HANDED
            # THE PAPER IN - and because every navigation posts the current
            # answer, a candidate who had answered everything and then pressed
            # PREVIOUS submitted their exam by pressing a button whose entire
            # purpose is to go back. Reported as "the assessment submitted on
            # its own", and it did: at that point any button would do it.
            #
            # Ending an attempt now takes an explicit act, and there is already
            # exactly one route for it - `/api/v1/exam/<token>/submit`, which
            # refuses while questions are unanswered and settles through
            # `_auto_submit_expired`. The two paths that must NOT need the
            # candidate's consent still work, because both call that method
            # themselves: the expiry cron, and the proctoring violation cap.
            #
            # This is upstream's fix for the same report (e1b4f58, "fix:
            # previous auto submit bug") applied at the layer this fork's
            # runner actually uses. Upstream required a `confirm_finish` token
            # on its finish route; the equivalent here is refusing to treat a
            # SAVE as a FINISH at all.

    def _enqueue_subjective_scoring(self):
        # Queue only: LLM scoring never runs inline on the candidate's submit
        # path - the cron drains it.
        from ..services import scoring as scoring_svc
        auto_eval_ids = set()
        repend_eval_ids = set()
        # Every assignment below is compared first: assigning the SAME value
        # still bumps `write_date`, so an unchanged re-save (every autosave)
        # was an UPDATE of the answer and of the attempt that changed nothing.
        for rec in self:
            qtype = rec.question_id.question_type
            if qtype == "image_ab":
                if not rec.line_ids:
                    if rec.llm_state != "not_needed":
                        rec.llm_state = "not_needed"
                    continue
                if not rec._image_ab_uses_llm():
                    # H-16's test, here too: these picks are already stored,
                    # and storing them again rewrote the same values.
                    if not (rec.llm_state == "scored" and rec.llm_scored_hash
                            == rec._graded_answer_hash()):
                        scoring_svc._store_ab_verdict_only(rec)
                    if rec.assessment_evaluator_id:
                        repend_eval_ids.add(rec.assessment_evaluator_id.id)
                    continue
                # One the grader reads falls through to the H-16 guard below,
                # like every other type (A-257).
            elif not rec.needs_llm or not (
                    (rec.justification or "").strip()
                    # needs_llm already says a transcription is answered,
                    # text or not (`_transcription_has_answer`).
                    or qtype == "transcription"):
                if rec.llm_state != "not_needed":
                    rec.llm_state = "not_needed"
                continue
            # H-16: don't re-queue an answer that is ALREADY scored and whose
            # text has not changed. Otherwise a candidate re-submitting a scored
            # subjective answer (still in-progress, llm_auto_score on) forces the
            # cron to grade the same text repeatedly - a candidate-driven cost
            # loop. A genuine edit changes the hash and DOES re-queue (once); an
            # exhausted attempt budget is left alone.
            if (rec.llm_state == "scored"
                    and rec.llm_scored_hash == rec._graded_answer_hash()):
                continue
            if rec.llm_state != "pending":
                rec.llm_state = "pending"
            if rec.assessment_evaluator_id:
                repend_eval_ids.add(rec.assessment_evaluator_id.id)
                if rec.assessment_id.llm_auto_score:
                    auto_eval_ids.add(rec.assessment_evaluator_id.id)
        if auto_eval_ids:
            self.env["assessments.be.evaluator"].browse(
                auto_eval_ids).filtered(
                    lambda e: not e.scoring_requested).write(
                        {"scoring_requested": True})
        if repend_eval_ids:
            self.env["assessments.be.evaluator"].browse(
                repend_eval_ids)._compute_subjective_rollup()
        if repend_eval_ids or auto_eval_ids:
            # Per CALL, not per response: this runs over a recordset and a line
            # per row would be one per answer on the submit burst. Silent when
            # nothing was queued, which is the common case - this cohort has
            # llm_auto_score off, so the count here is the proof that no Vertex
            # spend was triggered.
            from ..services import audit
            audit.emit("scoring.enqueue", outcome="queued",
                       responses=len(self), attempts=len(repend_eval_ids),
                       auto=len(auto_eval_ids))

    # `_check_assessment_complete` lived here and was DEAD - zero callers. It
    # was orphaned when the auto-submit fix moved the all-submitted check into
    # `_auto_submit_expired`, which is where the in_progress -> done transition
    # actually happens now (and which the candidate submit path delegates to,
    # so behaviour never changed). Leaving an unreachable copy of a state
    # transition in the file is a trap: the next reader finds two
    # implementations, and no way to tell which one runs. Deleted rather than
    # wired up, because wiring it up would be a behaviour change nobody asked
    # for. See docs/ETP_KNOWLEDGE_BASE.md, corrected to stop naming it.

    @api.constrains("state")
    def _check_locked(self):
        for rec in self:
            if (rec.assessment_evaluator_id
                    and rec.assessment_evaluator_id.is_locked
                    and rec.state != "submitted"):
                raise ValidationError(
                    "Cannot modify responses after the assessment is locked.")


class EtpAssessmentResponseLine(models.Model):
    _name = "assessments.be.response.line"
    _description = "Assessment Response Line"

    response_id = fields.Many2one(
        "assessments.be.response", required=True, ondelete="cascade",
        # THE PARENT LINK ON THE LARGEST TABLE IN THE SCHEMA, and it carried no
        # index: `assessments_be_response_line` had exactly one, its primary
        # key. Every read of a response's lines - which is every answer render,
        # every re-grade, every export row - therefore scanned the table, and
        # `ondelete="cascade"` means Postgres re-scans it for each parent row
        # deleted. One sitting writes a line per answered dimension, so this
        # table grows fastest of all of them.
        #
        # Built CONCURRENTLY by migrations/19.0.3.18.0, because taking an
        # ACCESS EXCLUSIVE lock on this table is exactly the stall a live
        # cohort cannot absorb.
        index=True)
    question_dimension_id = fields.Many2one(
        "assessments.be.question.dimension",
        string="Dimension", required=True, ondelete="restrict",
        # `ondelete="restrict"` means Postgres must PROVE no line references a
        # dimension before it can be deleted - and with no index that proof is
        # a full scan of the biggest table in the schema, every time.
        index=True)
    selected_option_id = fields.Many2one(
        "assessments.be.question.dimension.option",
        string="Selected Option",
        ondelete="restrict",
        # Same restrict-scan as the dimension above, and this one is provoked
        # in the ordinary course of editing a question bank: the suite already
        # logs the refusal ("violates foreign key constraint
        # assessments_be_response_line_selected_option_id_fkey"), which is the
        # scan happening.
        index=True,
    )
