# -*- coding: utf-8 -*-
"""Write routes: create and update the records the admin screens edit.

Separate from ``admin.py`` so the read/action surface stays as it was and this
addition can be reviewed on its own. Same house rule as that file: where the
module already has an action that does the work
(``action_extract_tags``, ``action_generate_from_sop``, ``action_merge_tags``,
...) the route CALLS it rather than reimplementing the transition, because a
reimplementation forks the audit trail, the validation and the side effects -
and the API could then reach states the backend itself refuses.

WHY AN ALLOW-LIST
Every route below copies named fields out of the payload instead of passing it
to ``create``/``write`` wholesale. A blind ``create(**payload)`` lets a caller
set ``state``, ``results_released`` or ``score`` directly, which walks straight
past the lifecycle actions and the release gate. The allow-lists are the
boundary: a field that is not named here cannot be written through the API.
"""
import base64
import binascii
import json
import logging
from markupsafe import Markup, escape as html_escape

from psycopg2 import IntegrityError

from odoo import fields, http
from odoo.exceptions import UserError, ValidationError
from odoo.http import request

from ...constants import (
    CRON_LOCK_MODE_SELECTION, DEFAULT_PASS_THRESHOLD_PARAM,
    SETTING_RANGES, VIDEO_ALLOWED_DURATIONS_S, parse_shape_quotas,
    is_template_shape, template_id_of_shape,
    ab_code_from_stored_label, ab_construction_keys, ab_dimension_display_label,
    ab_dimension_labels_map, ab_key_drift, ab_materialized_keys,
    parse_flaw_plan, takes_one_answer,
)
from ...models import bank_import_wizard as wizard_module
from ...models import simple_import
from ...models.assessment import _MAX_CANDIDATE_CSV_BYTES
from ...services import secret_store, seb
from ...services.model_catalog import THINKING_LEVELS
from . import serializers as S
from .common import (
    API_METHODS, API_TYPE, MAX_EXPORT_BYTES, api_endpoint, arg, body, bool_arg,
    fail, id_list_arg, int_arg, ok, record_read_guard, require_manager,
    require_staff, str_arg,
)

_logger = logging.getLogger(__name__)

#: D1 - the bound on the operator's internal remark.
#:
#: A `Text` column is unbounded in Postgres, so this is a product decision
#: rather than a schema one: a remark is a paragraph or two rather than a
#: document. REFUSED past the bound rather than truncated - see the note in
#: `attempt_flag` for why this route does not use `str_arg`'s silent clip.
MAX_FLAG_NOTE = 5000


#: Upload ceiling. Generous for a SOP (they are documents, not media) but
#: bounded, because the file is base64 in a JSON body: it is held in memory
#: whole, and an unbounded one is a trivial way to exhaust a worker.
_MAX_UPLOAD_BYTES = 25 * 1024 * 1024


def _too_large(b64, noun="That file", limit=None):
    """413 `too_large` when base64 text `b64` holds more than `limit` bytes
    (default `_MAX_UPLOAD_BYTES`), else None.

    Sized from the ENCODED length, so every upload route refuses an oversized
    file before a byte of it is decoded into memory. `limit` is read at call
    time, not bound as a default, so the ceiling stays one module constant.
    """
    limit = _MAX_UPLOAD_BYTES if limit is None else limit
    b64 = b64 or ""
    # Exact for unbroken base64: every 4 characters are 3 bytes, less one per
    # '=' of padding - without that a file of exactly the limit read 2 over.
    size = len(b64) * 3 // 4 - b64[-2:].count("=")
    if size <= limit:
        return None
    # Tenths of a MB in integers, the size rounded UP and the limit DOWN, so
    # a file just over never reads as "25.0 MB. The limit is 25 MB."
    return fail("too_large", "%s is %.1f MB. The limit is %.1f MB."
                % (noun, -(-size * 10 // 1048576) / 10.0,
                   limit * 10 // 1048576 / 10.0), status=413)

#: Mirrors the resource model's own `category` selection. Repeated rather than
#: imported so an unknown value is refused with a readable 422 instead of an
#: ORM ValidationError surfacing as a 500.
_RESOURCE_CATEGORIES = {
    "sop", "reference", "sample", "golden", "vendor", "client", "other",
}


#: Distinguishes "key absent" from "key sent as null". A partial update must
#: touch only what it named, so an absent key cannot be treated as a value.
_MISSING = object()

#: Ceiling on any one settings string. A model name is 30 characters and a
#: service-account JSON a couple of kilobytes; this is far above both and far
#: below anything that would make `ir.config_parameter` a place to store a
#: file. Bounded because these come from an authenticated route, not because a
#: Manager is untrusted: an unbounded write into a config table read on every
#: request is a footgun regardless of who fires it.
_MAX_SETTING_CHARS = 64 * 1024

#: Inclusive ranges the SETTINGS FORM also enforces, mirrored here because the
#: two write paths share one record and the form is the stricter of the two.
#:
#: `res.config.settings` is a single model for EVERY installed app, and Odoo
#: re-seeds every `config_parameter` field from its stored parameter on each
#: save (`base/models/res_config.py` `default_get`) - not just the fields of
#: the tab being saved. So a value written here that
#: `ResConfigSettings._check_llm_limits` refuses does not fail later on this
#: module's own screen; it raises on the next save of ANY settings tab, and
#: the Settings page stops working for the whole database until somebody edits
#: a System Parameter by hand.
#:
#: Refusing the value at the door is the only place that stays local. The
#: numbers are READ FROM `constants.SETTING_RANGES` rather than repeated here,
#: because that is the table the form constraint and the pre-deploy gate also
#: read: three hand-copies of one range is how the gate came to refuse a value
#: the constraint accepts. `scoring_shards` additionally cannot exceed the
#: number of shard crons in data/cron.xml, which is where its high bound comes
#: from.
_SETTING_BOUNDS = {
    "assessments_be_v2.%s" % key: (low, high)
    for key, (low, high, _default) in SETTING_RANGES.items()
}
_SETTING_BOUNDS.update({
    # THE ONE BOUND NOTHING ELSE ENFORCES. `res_config_settings._check_llm_limits`
    # range-checks this, but `etp_assessment_pro` defines a method of the same
    # name on the same model with no `super()` call, so on any deployment
    # carrying both modules - production does - v2's constraint is composed
    # away and none of its four checks run. The API is the only gate left.
    "assessments_be_v2.vertex_max_rpm": (1, 10000),
})

#: Settings whose field is a Selection, and the exact values it accepts.
#:
#: Same failure as `_SETTING_BOUNDS` and a nastier one: a Selection rejects an
#: unlisted value with a raw `ValueError` from the ORM rather than a readable
#: message, and it does it on `default_get` - so writing "7" here breaks the
#: Settings page for every app before this module's own form is even opened.
#: Veo does not accept an arbitrary duration either, so this is the same list
#: the field itself is built from.
#:
#: EVERY Selection-backed `config_parameter` BELONGS HERE, and `thinking_level`
#: is the second one: `assessments_be_thinking_level` is a Selection over
#: "" / LOW / MEDIUM / HIGH, and the Settings screen now edits it through a
#: free-text box. Without this entry a lowercase "medium" - which the runtime
#: resolver accepts and upper-cases - saved 200 and then raised
#: `Wrong value for ... 'medium'` on the next open of Settings for ANY app.
#: The values come from `model_catalog.THINKING_LEVELS`, the same tuple
#: `normalize_thinking_level` accepts; the field's fourth choice is the empty
#: string, which the `choices and text` guard below already lets through
#: because clearing an override is how it is removed.
_SETTING_CHOICES = {
    "assessments_be_v2.video_default_duration_s":
        tuple(str(s) for s in VIDEO_ALLOWED_DURATIONS_S),
    "assessments_be_v2.thinking_level": THINKING_LEVELS,
    # The third: advisory / lease, read by `services/locks.cron_lock`.
    "assessments_be_v2.cron_lock_mode":
        tuple(code for code, _label in CRON_LOCK_MODE_SELECTION),
}


def _number(value):
    """Coerce a payload value to a float, or None when it is not a number.

    Rejects bool/list/dict before the cast: ``float(True)`` is 1.0 and
    ``float(None)`` raises, so leaving them to a bare try/except would either
    write a nonsense value or crash on a field the caller simply nulled.
    """
    if value is None or isinstance(value, (bool, list, dict)):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _picked(names):
    """Return {field: value} for the payload keys the caller actually sent.

    Absent keys are omitted rather than defaulted, so a partial update touches
    only what it named. Sending ``duration_minutes`` alone must not silently
    reset ``question_limit`` to zero.
    """
    out = {}
    for name, kind in names.items():
        value = arg(name, _MISSING)
        if value is _MISSING:
            continue
        if kind == "int":
            out[name] = int_arg(name, 0)
        elif kind == "float":
            number = _number(value)
            # Skip rather than write 0.0: a malformed number must not silently
            # reset a threshold to "everything passes".
            if number is not None:
                out[name] = number
        elif kind == "bool":
            out[name] = bool_arg(name)
        elif kind == "ids":
            out[name] = [(6, 0, id_list_arg(name))]
        else:
            out[name] = str_arg(name)
    return out


def _bad_pass_threshold(values):
    """422 for a sent pass_threshold outside 1-100, 0 included, or not a
    number at all. `_picked` drops a non-number ("abc", "70%"), which answered
    200 and saved nothing; null or "" is still "not sent"."""
    sent = arg("pass_threshold")
    if sent not in (None, "") and "pass_threshold" not in values:
        return fail("invalid",
                    "pass_threshold must be a number between 1 and 100.",
                    status=422)
    if "pass_threshold" in values and not 1 <= values["pass_threshold"] <= 100:
        return fail("invalid", "pass_threshold must be between 1 and 100.",
                    status=422)
    return None


def _bad_selection(model, values):
    """422 `invalid` naming the first Selection value in ``values`` that
    ``model``'s field does not offer. The ORM raises a bare ValueError on one,
    which reached the client as a 500. An empty value clears an optional
    field, so only a required one refuses it."""
    for name, value in values.items():
        field = model._fields.get(name)
        if field is None or field.type != "selection":
            continue
        choices = field._description_selection(model.env)
        if value in dict(choices) or (not value and not field.required):
            continue
        return fail("invalid", "%s must be one of: %s."
                    % (field.string, ", ".join(label for _v, label in choices)),
                    status=422, field=name)
    return None


def _invitations_closed(assessment):
    """409 `assessment_closed` unless ``assessment`` is running: the invite
    sender mails nobody on any other state, so a resend would only queue."""
    if assessment.state == "in_progress":
        return None
    return fail("assessment_closed",
                "Invitations can only be resent while the assessment is in "
                "progress. This one is %s." % assessment.state, status=409)


def _deleted_refs(target, values):
    """409 when a paper would NEWLY point at a deleted generator or question.

    ``target`` is the model on create, the paper on update: what a paper
    already holds is its history and stays; nothing deleted is added to one.
    """
    generator = target.env["assessments.be.prompt"].browse(
        values.get("generator_id") or []).exists()
    if generator.deleted and generator != target.generator_id:
        return fail("deleted", "That generator is deleted and cannot be used "
                    "for an assessment.", status=409)
    ids = (values.get("question_ids") or [(6, 0, [])])[0][2]
    added = target.env["assessments.be.question"].browse(
        ids).exists() - target.question_ids
    if added.filtered("deleted"):
        return fail("deleted", "Deleted questions cannot be added to an "
                    "assessment.", status=409)
    return None


def _bad_violation_cap(values):
    """422 for a negative violation limit, regular or AI; 0 is a real
    setting."""
    for key in ("max_violations", "ai_max_violations"):
        if values.get(key, 0) < 0:
            return fail("invalid", "%s cannot be negative." % key,
                        status=422)
    return None


def _apply_shuffle_alias(values):
    """Fold the operator-facing ``shuffle_questions`` toggle onto the field it
    is the inverse of, ``preserve_question_order``.

    THE ALLOW-LIST CANNOT EXPRESS AN INVERSION. `_picked` maps a payload key to
    a field of the same name; there is no entry that means "write NOT this
    boolean into a differently-named column". So the alias is resolved here,
    out of the raw payload, and injected into ``values`` under the real field
    name BEFORE the caller writes or runs its draft gate. Doing it before the
    gate is deliberate: `preserve_question_order` decides the order candidates
    are served, so it belongs with `question_ids` on the wrong side
    of the post-draft lock, and folding it in first is what makes the existing
    gate refuse it on a running assessment without a second rule to maintain.

    Absent key -> nothing written, same partial-update contract `_picked`
    keeps. A malformed value cannot land here: `bool_arg` coerces it, and the
    only way to leave the field untouched is to not send the key at all.
    """
    if arg("shuffle_questions", _MISSING) is not _MISSING:
        values["preserve_question_order"] = not bool_arg("shuffle_questions")
    return values


class DeletedRefused(UserError):
    """Deleted is final: nothing is added to or changed on a deleted question
    or generator. `api_endpoint` answers it as 409 `deleted`."""

    def __init__(self, record):
        noun = ("generator" if record._name == "assessments.be.prompt"
                else "question")
        super().__init__(
            "This %s is deleted and cannot be changed. Its assessments, "
            "answers and scores are kept." % noun)
        self.code = "deleted"
        self.http_status = 409


def _refuse_if_deleted(record):
    """``record``, unless it is deleted - then the request is refused."""
    if record and record.deleted:
        raise DeletedRefused(record)
    return record


def _generator(generator_id, allow_deleted=False):
    """The generator, or None. ACL-checked under the caller's own user.

    Every caller is a write route, so a deleted generator is refused here:
    rename, SOP upload, generate, extract and the rest all stop at once.
    ``allow_deleted`` is for Stop only - stopping work must always be possible.
    """
    record = request.env["assessments.be.prompt"].browse(
        generator_id).exists() or None
    return record if allow_deleted else _refuse_if_deleted(record)


# ---------------------------------------------------------------------------
# Deleting: retire what is history, erase what is not
# ---------------------------------------------------------------------------
#
# ONE RULE, IN ONE PLACE, used by questions and by generators alike.
#
# "Delete" means "take it out of the bank", not "erase the record". The two are
# the same thing only when nothing points at the record:
#
#   * `response.question_id` is ondelete="cascade". Unlinking a question
#     somebody has answered DELETES THEIR ANSWER, and every score already
#     computed from it silently changes - a result an operator has released, and
#     may have hired or rejected somebody on, quietly becomes a different
#     number. There is no undo and no record that it happened.
#   * `assessment.question_ids` is a plain m2m. Unlinking a question removes it
#     from papers that were built, launched and possibly already sat, so a
#     six-question paper becomes a five-question paper after the fact.
#
# So a referenced question is ARCHIVED: `active = False`. The row survives, the
# paper still shows it, the answers stay attached to it, and it simply stops
# being reachable from the bank - it cannot be searched, previewed, or chosen
# for a new assessment. That is what "the user will not be able to use those
# questions for further use" means, without rewriting anybody's history.
#
# An unreferenced question has no history to protect, so it is really deleted.
# Either way the operator sees the same thing: it is gone from the bank.
#
# THE SAME RULE, ONE LEVEL UP, FOR A GENERATOR. `assessment.generator_id` is
# ondelete="restrict" and prompt.py raises a UserError before it - so a
# generator an assessment has used cannot be erased at all, no matter what this
# code would like to do:
#
#   * Not referenced -> the generator row is deleted, and each of its bank
#     questions takes the per-question branch above.
#   * Referenced     -> the generator is marked DELETED (and inactive): the
#     row survives for the papers that point at it, never restorable, and its
#     bank questions take the per-question branch above. Archive is its own,
#     reversible route.
#
# THE BRANCH IS DECIDED BEFORE ANYTHING IS WRITTEN, and that is the whole
# point. The old order retired and erased the questions first and only then
# tried the unlink, so the guard refused AFTER the bank had already been taken
# apart - and because `api_endpoint` RETURNS a fail envelope for a UserError
# instead of re-raising, Odoo committed that destruction while the operator
# read "Cannot delete - used by assessment. Archive it instead."

def _retire_or_delete_question(question):
    """Delete one question from the bank. Returns what actually happened.

    ``sudo`` on the write, not on the lookup: whether the caller may act on
    this question has already been settled by `require_manager` and the browse
    above, but the write has to be able to touch a record whose assessments the
    caller cannot necessarily read.
    """
    usage = S.question_usage(question)
    row = {
        "id": question.id,
        "name": question.name or "",
        "assessment_count": usage["assessment_count"],
        "answer_count": usage["answer_count"],
        "assessments": usage["assessments"],
    }
    if usage["referenced"]:
        # Delete on history: out of the bank and out of Archived, for good,
        # with every answer and score kept. Archive is the reversible one.
        question.sudo().write({"retired": True, "deleted": True})
        row["outcome"] = "retired"
        return row
    question.sudo().unlink()
    row["outcome"] = "deleted"
    return row


def _question_delete_preview(question):
    """What `_retire_or_delete_question` WOULD do, writing nothing.

    Shares `question_usage` with the real thing, so the sentence the operator
    confirms cannot disagree with the work that follows it.
    """
    usage = S.question_usage(question)
    return {
        "id": question.id,
        "name": question.name or "",
        "assessment_count": usage["assessment_count"],
        "answer_count": usage["answer_count"],
        "assessments": usage["assessments"],
        "outcome": "retired" if usage["referenced"] else "deleted",
    }


def _archived_template_shapes(env, quotas):
    """Names of the templates in `quotas` that are archived or gone.

    An archived template CANNOT generate: `_resolve_template_shapes` skips
    inactive records, so the run silently drops that shape, authors generic
    items in its place and only says so in the post-run report - after the
    spend, and after the button confidently offered "Generate N questions".
    Naming them here refuses the save while the operator is still looking at
    the screen that set it.

    Returns display names, not shape keys: "template:16" tells the operator
    nothing, "Verify a single photo edit" tells them exactly what to restore.
    """
    ids = {}
    for shape in (quotas or {}):
        if not is_template_shape(shape):
            continue
        template_id = template_id_of_shape(shape)
        if template_id:
            ids[template_id] = shape
    if not ids:
        return []
    Template = env["assessments.be.task.template"].sudo()
    # `active_test=False` or an archived row simply will not be found, and a
    # missing template would be indistinguishable from an archived one.
    found = Template.with_context(active_test=False).browse(list(ids)).exists()
    out = []
    for rec in found:
        if not rec.active:
            out.append(rec.name or ids[rec.id])
    # A template that was deleted outright is also unusable; report the raw
    # shape so the operator can clear it.
    for template_id, shape in ids.items():
        if template_id not in found.ids:
            out.append(shape)
    return sorted(out)


def _generator_bank_questions(generator):
    """Every bank question this generator authored, retired ones included.

    `active_test=False` so a second delete of an already-part-retired generator
    is not confused by rows it cannot see - and so the count an operator is
    shown matches the rows that exist rather than the rows still in the bank.

    Reads `generator.env` rather than `request.env`, like every other helper in
    this block, so the delete rule can be exercised by a TransactionCase with
    no request in scope - it is the one piece of logic here whose failure mode
    is destroying somebody's answers, so it has to be testable directly.
    """
    return generator.env["assessments.be.question"].sudo().with_context(
        active_test=False).search([("generator_id", "=", generator.id)])


def _generator_is_referenced(generator):
    """True when an assessment points at this generator, so it cannot be erased.

    THE BRANCH THAT HAS TO BE ANSWERED BEFORE ANYTHING IS WRITTEN. Mirrors
    `_unlink_except_used_by_assessment` (assessments_be_v2/models/prompt.py)
    exactly, `active_test=False` included: `assessment.generator_id` is
    ondelete="restrict" and an ARCHIVED assessment still holds its reference,
    so reading this under the default active filter would answer "safe to
    erase" for a generator the ondelete guard will refuse.

    That refusal is a UserError, and `api_endpoint` RETURNS a fail envelope for
    one rather than re-raising, so the questions retired or erased before the
    refusal used to be committed while the operator was told nothing had been
    deleted. Asking first is what makes that impossible; the safety net in
    common.py is the second line of defence, not the first.
    """
    return bool(generator.env["assessments.be"].sudo().with_context(
        active_test=False).search_count([("generator_id", "=", generator.id)]))


def _generator_erase_counts(generator, erasing):
    """The generator's OWN rows, counted only when they are really destroyed.

    `question_ids` (drafts) and `resource_ids` (SOP files) are both
    ondelete="cascade" on `prompt_id`, so they go with the generator ROW - and
    only the erase branch deletes that row. `_keep_generator_deleted` keeps
    the row, so its drafts and SOP files survive with it.

    Reporting them unconditionally is the bug this replaces: archiving a
    generator showed "Draft questions deleted with it 10 / SOP files deleted
    with it 1" over an operation that deleted neither, and the rows were still
    in the database afterwards.

    Must be read BEFORE `_erase_generator` unlinks: after the unlink there is
    no record left to count either o2m from.
    """
    if not erasing:
        return {"draft_count": 0, "resource_count": 0}
    return {
        "draft_count": len(generator.question_ids),
        "resource_count": len(generator.resource_ids),
    }


def _generator_summary(generator, name, rows, outcome, counts):
    """The one body shape a preview and a completed delete both report.

    ``counts`` comes from `_generator_erase_counts` on BOTH sides, so the
    confirmation and the outcome cannot disagree about what was destroyed - the
    same parity the branch itself is computed for.
    """
    return {
        "id": generator.id,
        "name": name,
        # "deleted" (the generator row is gone) or "kept" (an assessment uses
        # it: marked deleted, the row and its results survive).
        "outcome": outcome,
        # Zero on the kept branch: nothing of the generator's own is lost.
        "draft_count": counts["draft_count"],
        "resource_count": counts["resource_count"],
        "question_count": len(rows),
        "retired_question_count": sum(
            1 for r in rows if r["outcome"] == "retired"),
        "deleted_question_count": sum(
            1 for r in rows if r["outcome"] == "deleted"),
        "questions": rows,
        # De-duplicated across the generator's questions: one paper usually
        # uses several of them, and naming it once is the useful sentence.
        "assessments": list({
            a["id"]: a for r in rows for a in r["assessments"]}.values()),
    }


def _generator_delete_preview(generator):
    """What deleting this generator would cost, writing nothing.

    Runs the SAME branch `_delete_generator` runs, off the same helper, because
    a preview that disagrees with the work is worse than no preview at all: the
    operator confirms "3 questions erased" and gets an archive, or the reverse.
    """
    keeping = _generator_is_referenced(generator)
    questions = _generator_bank_questions(generator).filtered(
        lambda q: not q.deleted)
    previews = [_question_delete_preview(q) for q in questions]
    return _generator_summary(
        generator, generator.name or "", previews,
        "kept" if keeping else "deleted",
        _generator_erase_counts(generator, not keeping))


def _keep_generator_deleted(generator):
    """An assessment uses the generator: delete it for good, keep the row.

    The row cannot be erased - ondelete="restrict" plus the module's own
    ondelete guard - so it is marked `deleted` and inactive: out of every list
    and out of Archived, never restorable, its drafts and SOP files kept for
    the papers that still point at it. It used to be ARCHIVED here, so Restore
    brought back a generator the operator had deleted; Archive is now its own
    button (`/generators/<id>/archive`).

    Its bank questions take the bank's Delete rule: erased when nothing uses
    them, moved to Deleted with every answer kept when something does.
    """
    name = generator.name or ""
    # Stop what it is running first: a deleted generator must not go on
    # spending on drafts that can never be approved.
    generator = generator.sudo()
    generator.action_cancel_generation()
    generator.action_cancel_tag_extract()
    generator._cancel_pending_media()
    rows = [_retire_or_delete_question(q)
            for q in _generator_bank_questions(generator).filtered(
                lambda q: not q.deleted)]
    generator.write({"active": False, "deleted": True})
    # Zero drafts, zero files: this branch destroys neither, and saying
    # otherwise is what made the confirmation sheet describe an erasure that
    # never ran.
    return _generator_summary(
        generator, name, rows, "kept",
        _generator_erase_counts(generator, False))


def _erase_generator(generator):
    """Nothing references the generator: really delete it.

    Questions FIRST. `generator_id` is ondelete="set null", so once the
    generator row is gone there is nothing left to find them by, and they would
    stay in the bank as unattributable rows nobody can explain. Each one takes
    the per-question branch: erased when nothing points at it, retired when
    something does.
    """
    name = generator.name or ""
    # Counted before the unlink, with `name`, for the same reason: the o2ms are
    # unreadable once the row is gone, and these two numbers are the only
    # record of what the cascade took.
    counts = _generator_erase_counts(generator, True)
    rows = [_retire_or_delete_question(q)
            for q in _generator_bank_questions(generator).filtered(
                lambda q: not q.deleted)]
    generator.sudo().unlink()          # cascades its drafts and its SOP files
    return _generator_summary(generator, name, rows, "deleted", counts)


def _delete_generator(generator):
    """Take one generator out of the bank, by whichever branch applies."""
    if _generator_is_referenced(generator):
        return _keep_generator_deleted(generator)
    return _erase_generator(generator)


def _delete_generator_isolated(generator):
    """`_delete_generator`, contained so one refusal cannot cost anything else.

    TWO THINGS THE SAVEPOINT BUYS, and both of them are the same bug:

      * In a batch, Postgres aborts the WHOLE transaction on a failed
        statement. Without a savepoint per generator, a refusal on the third
        one takes the two already processed down with it, and the route reports
        a rolled-back transaction as a success.
      * On its own, the questions this call retired must not outlive a
        generator delete that was then refused - which is exactly the
        commit-what-you-refused failure this whole block was rewritten to stop.

    The refusal is then re-answered the way the rule answers a referenced
    generator: mark it deleted and keep the row with its results. The branch test
    mirrors the only ondelete="restrict" pointing at this model, so reaching
    the fallback should be impossible - but "impossible" is precisely what the
    previous version assumed while it was destroying banks.
    """
    try:
        with generator.env.cr.savepoint():
            return _delete_generator(generator)
    except (UserError, ValidationError, IntegrityError):
        with generator.env.cr.savepoint():
            return _keep_generator_deleted(generator)


def _run_simple_import(method, content):
    """Hand base64 file bytes to `assessments.be.simple.import`.

    The importer raises with a message naming the ROW, which is the only part
    an operator can act on, so it is passed through verbatim rather than
    replaced with a generic failure.

    ``filename`` IS READ, not ignored. Both import routes document their body as
    `{content, filename?}` and the client has always sent it, but nothing here
    ever looked at it - so the one identifier that tells an operator WHICH file
    a row-level refusal came from was dropped on the floor, and the contract
    audit correctly reported the key as unread. It is echoed back on the result
    so a caller importing several files can attribute the outcome.
    """
    if not content:
        return fail("invalid",
                    "`content` must carry the base64-encoded file bytes.",
                    status=422)
    refused = _too_large(content, limit=simple_import.MAX_CSV_BYTES)
    if refused:
        return refused
    filename = str_arg("filename", max_len=255) or ""
    try:
        result = getattr(
            request.env["assessments.be.simple.import"].sudo(), method)(content)
    except Exception as exc:                                    # noqa: BLE001
        # A returned failure is committed: drop the rows made before it.
        request.env.cr.rollback()
        return fail("import_failed",
                    ("%s: %s" % (filename, exc)) if filename else str(exc),
                    status=422)
    if isinstance(result, dict) and filename:
        result = dict(result, filename=filename)
    return ok(result)


def _template_payload(method, filename):
    """A CSV template in the shape every other download on this API uses:
    `{filename, mimetype, content}` with `content` base64 - see
    `/api/v1/candidates/template`."""
    csv_text = getattr(
        request.env["assessments.be.simple.import"].sudo(), method)()
    return {
        "filename": filename,
        "mimetype": "text/csv",
        "content": base64.b64encode(csv_text.encode("utf-8")).decode(),
    }


def _sop_action(generator_id, method, needs_sop="", context=None):
    """Run one of the generator's own ``action_*`` methods and return it.

    Every SOP action shares the same preamble - find it, 404 if it is gone,
    refuse when it has nothing to read - and the module's action does the
    actual work. Expressing that once keeps the routes below to their route
    decorator and one line, and stops the refusal wording drifting apart.

    ``needs_sop`` is the message to refuse with when the generator has no
    source; the LLM-spending actions pass one, the cheap ones do not.

    The readiness test is ``resource_ids or source_text``, deliberately the
    SAME condition ``action_generate_from_sop`` and ``action_extract_tags``
    raise on. ``sop_resource_ids`` is a COMPUTED subset holding only
    SOP-category files, so testing it would refuse a generator whose only
    document is filed as reference or vendor - one the module itself would
    happily read.

    ``context`` is merged onto the record before the action runs, for the
    actions that take a flag (``approve_all`` passes the reviewer's
    acknowledgement this way). Applied AFTER the readiness checks so a refusal
    is decided on the record itself.
    """
    record = _generator(generator_id)
    if not record:
        return fail("not_found", "Generator not found", status=404)
    if needs_sop and not (record.resource_ids or (record.source_text or "").strip()):
        return fail("no_source", needs_sop, status=409)
    if context:
        record = record.with_context(**context)

    # The action may not exist. `action_extract_structures` belongs to a host
    # module feature that is not always present, and a bare getattr call would
    # surface as a 500 with no explanation. Refuse in the client's own language
    # instead, so the button reports "this build does not do that" rather than
    # looking broken.
    action = getattr(record, method, None)
    if not callable(action):
        return fail(
            "not_supported",
            "This deployment of the assessment module does not provide "
            "'%s'." % method,
            status=501)

    result = action()
    # An Odoo action reports a PARTIAL failure by returning a display_notification
    # rather than by raising: action_approve_all_drafts approves what it can, logs
    # the rest to the generator's chatter and hands back "N approved; M skipped".
    # Discarding that return value turned "6 approved, 4 permanently rejected"
    # into a plain success envelope, so the app said everything was approved while
    # four drafts silently stayed in the review queue - the reason a missing bank
    # question looked like a bank bug instead of a refused approval.
    #
    # Only the notification shape is understood; anything else (True, an act_window
    # a JSON client cannot render) is not a message and is deliberately ignored.
    payload = S.generator_detail(record)
    if isinstance(result, dict) and result.get("tag") == "display_notification":
        params = result.get("params") or {}
        kind = params.get("type") or "info"
        message = str(params.get("message") or "").strip()
        if message:
            payload["notice"] = {
                "kind": kind,
                "title": str(params.get("title") or "").strip(),
                "message": message,
                # The client must not report unqualified success on this.
                "is_warning": kind in ("warning", "danger"),
            }
    return ok(payload)


# ---------------------------------------------------------------------------
# Editing a question's answer key
# ---------------------------------------------------------------------------
#
# WHY THIS EXISTS. Odoo's draft and bank forms are fully editable - the option
# rows are `<list editable="bottom">` and `is_correct` is a toggle - so a
# reviewer fixes a wrong question in place and then approves it. This app could
# only approve or deny, which meant any generated question with a typo or the
# wrong option flagged correct had to be thrown away and re-generated, at the
# cost of another paid model call and whatever else was good about it.
#
# The two models are the same shape with different names for one field: a DRAFT
# axis is `label`, a BANK dimension is `name`. That single difference is the
# only reason this takes a parameter rather than being one function.

def _sync_dimensions(record, rows, dim_field, dim_model, protect_answers):
    """Apply an incoming dimension/option tree to ``record``.

    ``rows`` is the client's whole intended answer key. A row carrying an ``id``
    updates that record, a row without one creates it, and anything absent from
    the list is removed - the same read-modify-write a form does.

    ``protect_answers`` refuses to delete an option a candidate has already
    selected. The column is ondelete="restrict", so the database would refuse
    anyway; catching it here turns a raw IntegrityError into a sentence that
    says which option and why.

    Returns None on success, or a ready-to-return failure envelope.
    """
    existing = record[dim_field]
    keep_dims, commands = [], []
    # Rows that only CHANGE are written directly, never through `dim_field`:
    # Odoo marks everything that depends on a relation for recompute on any
    # command through it, so a one-word rename re-scored every answer to the
    # question (50 s mid-exam on 3,700 answers, 12 Oct). Creates and deletes
    # still go through it. Validation all happens before the first write.
    row_writes = []

    # EACH ROW KEEPS ITS PLACE: a row with no `sequence` (the app sends none)
    # is placed by its position in the list. A flat 10 put an option added in
    # the middle last, by id, once approved.
    for i, row in enumerate(rows):
        if not isinstance(row, dict):
            continue
        label = str(row.get("name") or row.get("label") or "").strip()
        if not label:
            return fail("invalid", "Every answer axis needs a name", status=422)
        dim_vals = {dim_model: label,
                    "sequence": int(row.get("sequence") or (i + 1) * 10)}
        # The control the exam draws (checkboxes, a scale ...), when sent.
        if "input_kind" in row:
            dim_vals["input_kind"] = str(row.get("input_kind") or "")

        dim_id = row.get("id")
        dim = existing.filtered(lambda d, i=int(dim_id or 0): d.id == i)
        if dim_id and not dim:
            return fail("not_found",
                        "Answer axis %s is not on this question" % dim_id,
                        status=404)

        opt_rows = row.get("options") or []
        opt_commands, keep_opts = [], []
        for j, opt in enumerate(opt_rows):
            if not isinstance(opt, dict):
                continue
            oname = str(opt.get("name") or "").strip()
            if not oname:
                return fail("invalid", "Every option needs text", status=422)
            ovals = {
                "name": oname,
                "is_correct": bool(opt.get("is_correct")),
                "sequence": int(opt.get("sequence") or (j + 1) * 10),
            }
            oid = opt.get("id")
            if oid:
                # This axis's own options only: another question's id would
                # rewrite THAT key, past `protect_answers`, and a sibling
                # axis's id would rewrite that axis's option and delete it.
                option = dim.option_line_ids.filtered(
                    lambda o, i=int(oid): o.id == i)
                if not option:
                    return fail("not_found",
                                "Option %s is not on this answer axis" % oid,
                                status=404)
                keep_opts.append(option.id)
                row_writes.append((option, ovals))
            else:
                opt_commands.append((0, 0, ovals))

        if dim_id:
            gone = dim.option_line_ids.filtered(lambda o: o.id not in keep_opts)
            denied = _refuse_used_options(gone) if protect_answers else None
            if denied:
                return denied
            opt_commands += [(2, o.id, 0) for o in gone]
            keep_dims.append(int(dim_id))
            row_writes.append((dim, dim_vals))
            if opt_commands:
                commands.append((1, int(dim_id),
                                 {"option_line_ids": opt_commands}))
        else:
            commands.append((0, 0, dict(dim_vals,
                                        option_line_ids=opt_commands)))

    dropped = existing.filtered(lambda d: d.id not in keep_dims)
    if protect_answers:
        denied = _refuse_used_options(dropped.mapped("option_line_ids"))
        if denied:
            return denied
    commands += [(2, d.id, 0) for d in dropped]

    for row, vals in row_writes:
        row.write(vals)
    if commands:
        record.write({dim_field: commands})
    _resync_ab_construction_keys(record, dim_field, dim_model)
    return None


def _resync_ab_construction_keys(record, dim_field, dim_model):
    """An admin edit of an image_ab answer key IS the new key.

    A flaw-injected comparison keeps a second copy of its key in
    `flaw_plan_json.construction_keys`, and the drift guard (approve and score
    time) compares the stored options against it. Renaming a rating or an
    option here changed one copy and not the other, so every answer read as
    key drift and scored 0 (found 2026-09-29). Rebuild the copy from what was
    just saved: an unrenamed dimension keeps its code, a renamed one gets the
    code the guard itself derives from its new name.
    """
    if (getattr(record, "question_type", "") != "image_ab"
            or "flaw_plan_json" not in record._fields):
        return
    plan = parse_flaw_plan(record.flaw_plan_json)
    old_keys = ab_construction_keys(record.flaw_plan_json)
    if not old_keys:
        return
    old_labels = ab_dimension_labels_map(plan.get("dimension_labels"))
    keys, labels = {}, {}
    for dim in record[dim_field]:
        name = (dim[dim_model] or "").strip()
        code = ab_code_from_stored_label(name, old_keys, old_labels)
        correct = dim.option_line_ids.filtered("is_correct")
        if not code or code in keys or not correct:
            continue
        keys[code] = correct[0].name
        # Its SOP title stays only while the stored name is still the one that
        # title renders to; a renamed axis is read by its new name alone.
        title = old_labels.get(code)
        if title and ab_dimension_display_label(
                code, title).strip().casefold() == name.casefold():
            labels[code] = title
    plan["construction_keys"] = keys
    if "dimension_labels" in plan:
        plan["dimension_labels"] = labels
    record.flaw_plan_json = json.dumps(plan, ensure_ascii=False)
    drift = ab_key_drift(
        ab_materialized_keys(record[dim_field], keys,
                             plan.get("dimension_labels"),
                             name_field=dim_model), keys)
    if drift:
        _logger.warning(
            "etp_assessment: %s %s answer key edited but the flaw plan still "
            "disagrees: %s", record._name, record.id, drift)


def _refuse_used_options(options):
    """Refuse to delete options a candidate has already chosen."""
    if not options:
        return None
    used = request.env["assessments.be.response.line"].sudo().search([
        ("selected_option_id", "in", options.ids)], limit=1)
    if not used:
        return None
    opt = used.selected_option_id
    return fail(
        "option_in_use",
        "Cannot remove the option %r: a candidate has already selected it, "
        "and deleting it would rewrite their submitted answer. Edit its text "
        "instead, or retire the whole question." % (opt.name or opt.id),
        status=409)


def loads_list(raw):
    """A JSON array, or [] when the column is empty or malformed."""
    try:
        value = json.loads(raw or "[]")
    except (TypeError, ValueError):
        return []
    return value if isinstance(value, list) else []


def loads_any(raw):
    """Whatever the column holds, or "" when it is empty or malformed."""
    try:
        return json.loads(raw or '""')
    except (TypeError, ValueError):
        return ""


def answer_key_problem(question_type, options, correct):
    """Why this answer key would not work, or None when it is fine.

    A PURE PREDICATE returning a sentence rather than an HTTP envelope, so the
    rule can be exercised without a request context - the first version called
    `fail()` directly and could only be tested through the wire, which is how
    validation rules end up untested.

    The correct answer is stored as the option's TEXT, so the rule that matters
    most is that every correct value is actually one of the options. A key that
    names something absent scores nobody correct and looks entirely normal on
    screen, which is the same silent-defect shape as the two live bank
    questions that had to be archived for having no correct option at all.
    """
    if question_type not in ("mcq", "msq", "image_ab"):
        return None
    if len(options) < 2:
        return "A %s question needs at least two options" % question_type
    wanted = correct if isinstance(correct, list) else [correct]
    wanted = [str(c).strip() for c in wanted if str(c).strip()]
    if not wanted:
        return ("Nothing is marked correct, so the question could never be "
                "scored")
    missing = [c for c in wanted if c not in options]
    if missing:
        return "The correct answer %r is not one of the options" % missing[0]
    if takes_one_answer(question_type) and len(wanted) > 1:
        return ("A single-answer question cannot have %d correct options"
                % len(wanted))
    return None


def _check_answer_key(question_type, rows):
    """Refuse a key that would make the question unscoreable.

    Exactly the defect that had to be cleaned out of this bank by hand: two
    live questions with no options and nothing marked correct, which the exam
    guard silently skipped while they still showed in the UI. A save is the
    right moment to catch it, not a later audit.

    ONE PICK, ONE CORRECT (R8). Where a candidate picks one option
    (`takes_one_answer`: not an msq, not a checkboxes axis) a second correct
    one is a key nobody can earn. An image_ab rating axis left to the grader
    has no key by design, so there only a paper with no keyed axis at all is
    refused; every mcq / msq axis still needs one.
    """
    if question_type not in ("mcq", "msq", "image_ab"):
        return None
    if not rows:
        return fail("invalid",
                    "A %s question needs at least one answer axis"
                    % question_type, status=422)
    keyed = False
    for row in rows:
        name = row.get("name") or row.get("label") or "?"
        opts = [o for o in (row.get("options") or []) if isinstance(o, dict)]
        correct = [o for o in opts if o.get("is_correct")]
        if len(opts) < 2:
            return fail("invalid",
                        "Axis %r needs at least two options" % name,
                        status=422)
        if not correct and question_type != "image_ab":
            return fail("invalid",
                        "Axis %r has no correct option, so the question could "
                        "never be scored" % name, status=422)
        if len(correct) > 1 and takes_one_answer(question_type,
                                                 row.get("input_kind")):
            return fail("invalid",
                        "Axis %r takes one answer, so it cannot have %d "
                        "correct options" % (name, len(correct)), status=422)
        keyed = keyed or bool(correct)
    if not keyed:
        return fail("invalid",
                    "No axis has a correct option, so the question could "
                    "never be scored", status=422)
    return None


def _draft(draft_id):
    """A draft question, or None. ACL-checked under the caller's own user.

    Every caller is a write route, so a draft of a deleted generator is
    refused: nothing is edited, re-rendered or approved on it again.
    """
    record = request.env["assessments.be.prompt.question"].browse(
        draft_id).exists() or None
    if record:
        _refuse_if_deleted(record.prompt_id)
    return record


def _draft_action(draft_id, method, guard=None, refusal=""):
    """Run one of a draft's own ``action_*`` methods and return the draft.

    The draft counterpart to [_sop_action]: same preamble, same reason. The
    module's action does the work so the API cannot reach a state the backend
    itself refuses.

    ``guard`` is an optional predicate on the record; when it returns False the
    route refuses with ``refusal`` rather than calling the action, so a
    pointless retry does not look like a successful one.
    """
    record = _draft(draft_id)
    if not record:
        return fail("not_found", "Draft not found", status=404)
    if guard and not guard(record):
        return fail("not_applicable", refusal, status=409)

    getattr(record, method)()
    return ok(S.draft_detail(record))


def _live_attempt_refusal(assessment):
    """Refuse to archive a paper people are sitting RIGHT NOW, or None.

    ARCHIVING DOES NOT PAUSE A SITTING, and the message says so because the
    message is the whole content of the decision. `deadline_datetime` is
    `started_at + duration_minutes`, an absolute wall-clock instant that
    archiving never touches, and no candidate route gates on `active` - so an
    archived paper is still fully sittable and `/api/v1/exam/<token>/answer`
    still auto-submits each candidate at their ORIGINAL deadline. The one
    thing archive does suspend is `_cron_expire_stale_attempts`, the safety
    net for candidates who closed the tab; restoring the paper gives nobody
    any time back.

    This docstring used to claim the opposite - "every candidate currently
    `in_progress` is frozen mid-paper" - and so did the refusal, which is how
    an operator came to read a warning as a pause and confirm it.

    So it is refused once, by name and by number - the count is the whole point
    of the message, because "12 candidates are sitting this right now" is what
    tells an operator they have the wrong assessment, where a bare "are you
    sure?" does not. `confirm_live_attempts` is an ordinary `bool_arg` like
    every other switch in this file rather than a bespoke token: the act being
    confirmed here is archiving a paper mid-exam, which is reversible by
    restoring it. The irreversible one - destroying it - asks for the name.
    """
    live = assessment.assessment_evaluator_ids.filtered(
        lambda e: e.state == "in_progress")
    if not live or bool_arg("confirm_live_attempts"):
        return None
    return fail(
        "live_attempts",
        "%d candidate(s) are sitting this right now. Archiving does not pause "
        "their exam and does not give time back - each one is still submitted "
        "at their original deadline." % len(live),
        status=409, live_attempt_count=len(live))


class EtpAssessmentApiWrite(http.Controller):

    # Assessments

    #: Writable through the API. `state` is deliberately ABSENT: the lifecycle
    #: moves only through action_start / action_done / action_cancel, which
    #: run the gates and post to the chatter.
    ASSESSMENT_FIELDS = {
        "name": "str",
        "generator_id": "int",
        "question_limit": "int",
        "duration_minutes": "int",
        # `same_questions_for_all` is RETIRED (ETP_PLANS_AND_STRATEGY.md §4.3): off
        # this list, so an older client that still sends it is silently
        # ignored rather than refused. The column stays; nothing reads it.
        "results_release": "str",
        # A Float on the model, on a 0-100 PERCENTAGE POINT scale (default
        # 70.0), not a 0.0-1.0 fraction: 0.7 is a 0.7% pass bar, which every
        # candidate clears. `_check_subjective_threshold` refuses outside 0-100.
        "subjective_threshold": "float",
        # Cut-off on the total; 1-100, checked by `_bad_pass_threshold`.
        "pass_threshold": "float",
        "start_date": "str",
        "end_date": "str",
        "rule_block_tab_switch": "bool",
        "rule_block_copy_paste": "bool",
        "rule_block_right_click": "bool",
        "rule_block_devtools": "bool",
        # The remaining three proctoring rules. Their absence was silent: the
        # UI offered a watermark / fullscreen / webcam switch, the client sent
        # the field, `_picked` dropped it because it was not named here, and
        # the route answered 200. The operator saw a toggle move and nothing
        # persist.
        "rule_watermark": "bool",
        "rule_fullscreen": "bool",
        "rule_webcam": "bool",
        "rule_ai_proctor": "bool",
        # NOT `rule_gaze_review`: eye movement is off for good (19 Oct), so
        # nothing can turn it back on. A client that still sends it is ignored.
        "rule_require_seb": "bool",
        # NOT `seb_quit_password`: it changes only through `/regenerate`,
        # which refuses while a candidate is sitting the paper.
        "max_violations": "int",
        "violation_action": "str",
        # The same pair for the "AI: " violations, counted apart (R5).
        "ai_max_violations": "int",
        "ai_violation_action": "str",
        # Scoring policy. Same silent-drop problem as the rules above.
        "llm_auto_score": "bool",
        "require_reviewed_rubric": "bool",
        # Whether a release shows the key and the feedback (R6).
        "results_show_answers": "bool",
        # 0-100, checked by the model; 0 follows subjective_threshold (R7).
        "transcription_threshold": "float",
        "question_ids": "ids",
    }

    @http.route("/api/v1/assessments/create", type=API_TYPE, auth="user",
                methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def assessment_create(self, **kw):
        """Create a draft assessment.

        Always lands in `draft`, whatever the payload says - a new assessment
        with no questions and no candidates cannot be live, and letting the
        client choose would skip every launch gate.
        """
        name = str_arg("name").strip()
        if not name:
            return fail("invalid", "A name is required", status=422)

        values = _picked(self.ASSESSMENT_FIELDS)
        _apply_shuffle_alias(values)
        # THE COUNT FOLLOWS THE TICKS. An older client sends ticked questions
        # with no count, or a count above the ticks, and the launch then
        # refuses "Requested N but only M". Nothing ticked is still "the whole
        # generator" and keeps whatever count was sent.
        ticked = len(set(values.get("question_ids", [(6, 0, [])])[0][2]))
        limit = values.get("question_limit", 0)
        if ticked and (limit == 0 or limit > ticked):
            values["question_limit"] = ticked
        # A null or empty cap is "nothing given": the field default (5) applies
        # rather than `_picked`'s 0, which means "end on the first violation".
        # Same for the action: the field default (Log only) applies rather
        # than "", which the required Selection refuses.
        for key in ("max_violations", "violation_action",
                    "ai_max_violations", "ai_violation_action"):
            if arg(key) in (None, ""):
                values.pop(key, None)
        refused = (_bad_pass_threshold(values)
                   or _bad_selection(request.env["assessments.be"], values)
                   or _bad_violation_cap(values)
                   or _deleted_refs(request.env["assessments.be"], values))
        if refused:
            return refused
        values["name"] = name
        record = request.env["assessments.be"].create(values)
        return ok(S.assessment_detail(record))

    #: Editable AFTER the draft stage, unlike everything else above.
    #:
    #: The threshold is not part of the exam a candidate agreed to: it decides
    #: how already-stored raw scores are read, so moving it re-decides Pass and
    #: Fail without re-running the LLM or touching a single answer. The field's
    #: own help says "Editable anytime (even after Done)", and `write()` has
    #: the recompute wired to it - but this route refused every non-draft edit,
    #: so a threshold set wrongly could never be corrected once results
    #: existed, which is exactly when anybody discovers it was wrong.
    POST_DRAFT_FIELDS = {
        "subjective_threshold",
        "pass_threshold",
        # Unlocked post-launch (product decision, 2026-08-18): an operator
        # must be able to correct a missing time limit on a running
        # assessment; deadline_datetime recomputes from each candidate's own
        # start.
        "duration_minutes",
        # LISTED SO THE SAME VALUE PASSES, not so it can change: older apps
        # save the whole settings object. A CHANGED count after launch is
        # refused by `assessment_update` (`locked_after_launch`) - late
        # candidates copy the set already drawn, so a new count reaches nobody.
        "question_limit",
        # The backend form marks these `readonly="state in ('done',
        # 'cancelled')"`, i.e. still editable while an assessment is RUNNING,
        # and this route must agree with it. They govern how answers are
        # graded and how violations are handled, not what the candidate was
        # shown, so tightening a rule mid-sitting does not rewrite the exam.
        "rule_block_tab_switch",
        "rule_block_copy_paste",
        "rule_block_right_click",
        "rule_block_devtools",
        "rule_watermark",
        "rule_fullscreen",
        "rule_webcam",
        "rule_ai_proctor",
        "rule_require_seb",
        "max_violations",
        "violation_action",
        "ai_max_violations",
        "ai_violation_action",
        "llm_auto_score",
        "require_reviewed_rubric",
        "results_release",
        # Read when a released candidate opens the review, and re-decides
        # nothing, so it can change at any time - even after release (R6).
        "results_show_answers",
        # Same argument as `subjective_threshold` above (R7).
        "transcription_threshold",
        # A RENAME IS NOT A CHANGE TO THE EXAM. Nothing a candidate saw, agreed
        # to or answered depends on what the assessment is called, and the name
        # is the only handle an operator has on it in every list, export and
        # dashboard. Without this the title was editable for exactly as long as
        # nobody had sat it: the 409 landed the moment it launched, which is
        # when a wrong name actually starts costing somebody something. Same
        # argument as `subjective_threshold` above - see this set's docstring.
        "name",
    }

    @http.route("/api/v1/assessments/<int:assessment_id>/update",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def assessment_update(self, assessment_id, **kw):
        """Edit an assessment's configuration.

        Once the assessment has left draft only POST_DRAFT_FIELDS may change;
        anything else is 409 `not_draft`, because it would change the exam
        under candidates who are sitting it. A changed `question_limit` is 422
        `locked_after_launch`: late candidates copy the set drawn at launch.
        """
        record = request.env["assessments.be"].browse(
            assessment_id).exists()
        if not record:
            return fail("not_found", "Assessment not found", status=404)

        values = _picked(self.ASSESSMENT_FIELDS)
        _apply_shuffle_alias(values)
        refused = (_bad_pass_threshold(values)
                   or _bad_selection(record, values)
                   or _bad_violation_cap(values)
                   or _deleted_refs(record, values))
        if refused:
            return refused
        if record.state != "draft":
            if values.get("question_limit",
                          record.question_limit) != record.question_limit:
                return fail(
                    "locked_after_launch",
                    "The number of questions cannot change after launch. "
                    "Every candidate sits the question set drawn at launch.",
                    status=422)
            blocked = sorted(set(values) - self.POST_DRAFT_FIELDS)
            if blocked:
                return fail(
                    "not_draft",
                    "Only a draft assessment can be edited. This one is %s. "
                    "These cannot change now: %s."
                    % (record.state, ", ".join(blocked)),
                    status=409)

        if values:
            # `write` decides for itself whether to recompute inline or defer
            # to the cron via threshold_recompute_pending, based on how many
            # responses are involved. Doing it here would duplicate that.
            record.write(values)
        return ok(S.assessment_detail(record))

    @http.route(
        "/api/v1/assessments/<int:assessment_id>/seb-quit-password/regenerate",
        type=API_TYPE, auth="user", methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def assessment_seb_quit_password_regenerate(self, assessment_id, **kw):
        """Give the paper a new Safe Exam Browser quit password (R3).

        BETWEEN SITTINGS ONLY. Every .seb a candidate downloaded carries the
        old password's hash, so a new one strands anyone sitting the paper:
        409 `sitting_in_progress` while an attempt is in progress. The old
        password goes to the chatter, for a candidate who opened SEB but had
        not started; a failed post fails the change with it.
        """
        record = request.env["assessments.be"].browse(
            assessment_id).exists()
        if not record:
            return fail("not_found", "Assessment not found", status=404)
        sitting = record._quit_password_locked_by()
        if sitting:
            return fail("sitting_in_progress", sitting, status=409)
        old = record.seb_quit_password or ""
        record.seb_quit_password = seb.new_quit_password()
        record.message_post(
            body="Safe Exam Browser quit password changed. The previous one "
                 "was %s." % (old or "(none)"),
            message_type="comment", subtype_xmlid="mail.mt_note")
        return ok(S.assessment_detail(record))

    # Generators (assessments.be.prompt)

    GENERATOR_FIELDS = {
        "name": "str",
        "source_text": "str",
        "sop_title": "str",
        "sop_summary": "str",
        # HOW MANY QUESTIONS TO GENERATE. 0 means "let the model decide from
        # the SOP"; any positive number is a target. Only the integer is
        # exposed, not `question_count_mode`, because the mode is COMPUTED from
        # this value (`_compute_question_count_mode`) - offering both would let
        # a client send a contradiction (mode=fixed, count=0) and the
        # computed field would silently win.
        #
        # Without this the count was read-only everywhere in the app: "generate
        # 10 questions from this SOP" was not expressible, and an operator got
        # whatever was last pinned in Odoo.
        "sop_question_count": "int",
        # The per-generator cap on how many labelled boxes ONE image_label
        # question may carry. Unlike `sop_question_count`, 0 is NOT "auto":
        # `_check_image_label_count` refuses anything below 1, because the same
        # number is the denominator a labelling answer is normalised by.
        "image_label_count": "int",
        # Labelling pictures from a live website instead of AI (per project).
        "image_label_live_capture": "bool",
    }

    @http.route("/api/v1/assessments/<int:assessment_id>/cancel",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def assessment_cancel(self, assessment_id, **kw):
        """Cancel an assessment through the module's own lifecycle action.

        Calls `action_cancel` rather than writing `state`: the action posts to
        the chatter and runs whatever the model does on the way out, and a
        direct write would fork that audit trail.
        """
        record = request.env["assessments.be"].browse(
            assessment_id).exists()
        if not record:
            return fail("not_found", "Assessment not found", status=404)

        record.action_cancel()
        return ok(S.assessment_detail(record))

    @http.route("/api/v1/assessments/<int:assessment_id>/reset_draft",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def assessment_reset_draft(self, assessment_id, **kw):
        """Send an assessment back to draft so it can be reconfigured.

        It deletes every candidate and answer, so a paper with released
        results is 409 `released_results` unless the body says
        `confirm_released: true` (`action_reset_draft`)."""
        record = request.env["assessments.be"].browse(
            assessment_id).exists()
        if not record:
            return fail("not_found", "Assessment not found", status=404)

        record.with_context(
            confirm_released=bool_arg("confirm_released")
        ).action_reset_draft()
        return ok(S.assessment_detail(record))

    @http.route("/api/v1/assessments/<int:assessment_id>/archive",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def assessment_archive(self, assessment_id, **kw):
        """Archive an assessment, or restore one with ``archive: false``.

        A SEPARATE ROUTE RATHER THAN A FIELD ON `update`, for the two reasons
        `generator_archive` gives and one more of its own. Archiving is a
        decision and not an edit, so a client that could set `active` as part
        of a general write could file an assessment away as a side effect of
        saving a renamed title. And `assessment_update` refuses everything
        outside `POST_DRAFT_FIELDS` once an assessment has left draft - which
        would have made a live or finished sitting, the exact thing somebody
        wants out of the list, the one assessment that could never be archived.

        ARCHIVING IS A SUSPEND, AND THIS CONTRACT CHANGED ON 2026-09-17.

        This docstring used to say archiving was visibility and "nothing else
        moves": the state machine untouched, the sitting window untouched, the
        queues untouched. That was true, and it cost money. `assessments.be.
        evaluator` has no `active` column of its own, so Odoo's `active_test`
        never reached the scoring, invitation and expiry crons - they search
        the evaluator, not the assessment - and an archived paper went on being
        graded by Vertex, went on emailing invitations, and went on
        auto-submitting people's sittings. An operator who filed a finished
        cohort away to tidy the list was still paying for it.

        Archive now STOPS the cost-intensive and queued work, and it is still
        perfectly REVERSIBLE, because stopping is all it does:

        * the three crons skip archived assessments (`models/assessment.py`),
          so `scoring_requested`, `llm_state`, `invite_state` and
          `threshold_recompute_pending` are left exactly as they were on every
          row the drainer had not started. Nothing is snapshotted - the
          untouched rows ARE the saved state, and a snapshot would only be a
          second copy of the same fact, free to drift from it;
        * `scoring_cancel_requested` is raised so a lane already mid-Vertex-
          call refuses its NEXT call, reusing the cooperative handshake the
          kill switch owns. The one call already on the wire completes and is
          billed - the same honest boundary the kill states;
        * unarchiving lowers that flag and the crons resume from those rows,
          with no replay step. A cohort mid-scoring comes back scoring the
          same candidates.

        ARCHIVING IS STILL NOT CANCELLING. A kill parks what it stops in
        `llm_state = "cancelled"`, which is terminal and lossy - after it a
        candidate who was `pending` is indistinguishable from one who
        `failed`, so there is nothing faithful left to resume to. Archive
        never writes that state. An assessment that must stop FOR GOOD is
        cancelled; this one is suspended.

        Every candidate response and score still stays exactly where it was.
        That part of the old contract is unchanged and is what makes archive
        the safe alternative to deleting.
        """
        # `active_test=False` because an assessment, once archived, is
        # invisible to an ordinary browse - so without it the UNARCHIVE call
        # could never find its own record and always answered 404. The same
        # trap `generator_archive` documents.
        record = request.env["assessments.be"].with_context(
            active_test=False).browse(assessment_id).exists()
        if not record:
            return fail("not_found", "Assessment not found", status=404)

        denied = record_read_guard(record)
        if denied:
            return denied

        # Default True so a bare POST archives; unarchiving is the explicit
        # act, matching the button that sends it.
        archiving = bool_arg("archive", True)
        if archiving:
            refusal = _live_attempt_refusal(record)
            if refusal:
                return refusal
        record.write({"active": not archiving})
        return ok(S.assessment_detail(record))

    @http.route("/api/v1/assessments/<int:assessment_id>/delete",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def assessment_delete(self, assessment_id, **kw):
        """Permanently destroy an assessment - archive first, then confirm.

        TWO STEPS, AND THE REVERSIBLE ONE ALWAYS HAPPENS FIRST. Call one (no
        `confirm_name`) archives the assessment and answers 409 with exactly
        what the destructive call would destroy; call two echoes the name back
        and destroys it. Ordering it that way means an interrupted delete - a
        dropped connection, a closed tab, an operator who reads the numbers and
        changes their mind - leaves a SUSPENDED assessment rather than a
        half-destroyed one. Archiving is also a suspend now, so step one
        already stops the scoring and the invitations; the paper is costing
        nothing while the operator decides. It does NOT stop anybody's exam
        clock - see `_live_attempt_refusal` - which is why a live sitting is
        reported separately below.

        WHY ECHOING THE NAME AND NOT A BOOLEAN. `confirm: true` is one JSON
        key: a client that retries a failed request, a script that copies a
        payload, or a "confirm everything" helper sends it without a human ever
        reading what it applies to - and this is the one route in the module
        whose mistake cannot be undone. Typing the assessment's own name back
        cannot be produced by retrying the first call, and it proves the
        operator was looking at the paper they meant, not the row above it.
        Compared case-insensitively after stripping, because the confirmation
        is about intent and not about trailing whitespace.

        WHAT IS DESTROYED: the assessment, its candidate assignments and every
        response and score attached to them (both cascade off the assessment).
        The reply reports those counts so the UI can state them.

        WHAT SURVIVES, AND IT IS THE REQUIREMENT THAT MATTERS MOST: the
        `assessments.be.llm.usage` ledger. Those rows reference the evaluator
        with `ondelete="set null"` rather than `cascade`, so they outlive the
        cohort with a null evaluator, and the budget gate sums them without
        ever filtering on it - the day's spend is unchanged by a delete, and a
        deleted assessment cannot be used to buy back headroom under the daily
        cap. `llm_usage_kept` reports the count so the UI can say so, and a
        test pins it, because a future `ondelete="cascade"` on that field would
        start erasing spend history silently.

        `models/assessment.py`'s `_unlink_except_with_candidate_data` refuses
        any assessment carrying responses. It stands aside for the two
        CONFIRMED paths and nothing else, through `CONFIRMED_DESTROY_CTX` on a
        context built for the single `unlink` call - this route, which clears
        the bar by making the caller echo the assessment's own name back, and
        `models/delete_wizard.py`, the back-office Delete action, which clears
        a different bar: a manager-only modal naming the counts about to be
        destroyed, raised by the operator's own click and so unreplayable by a
        stale payload. An ordinary delete still carries no such key and is
        still refused.
        """
        record = request.env["assessments.be"].with_context(
            active_test=False).browse(assessment_id).exists()
        if not record:
            return fail("not_found", "Assessment not found", status=404)

        denied = record_read_guard(record)
        if denied:
            return denied

        Response = request.env["assessments.be.response"].sudo()
        evaluators = record.assessment_evaluator_ids
        counts = {
            "assessment_id": record.id,
            "name": record.name,
            "candidate_count": len(evaluators),
            "response_count": Response.with_context(
                active_test=False).search_count(
                    [("assessment_id", "=", record.id)]),
            # Reported on BOTH branches so the confirmation an operator reads
            # and the receipt they get afterwards name the same ledger.
            "llm_usage_kept": request.env[
                "assessments.be.llm.usage"].sudo().search_count(
                    [("evaluator_id", "in", evaluators.ids)]),
            # OUTSIDE the `record.active` gate below, because an ARCHIVED paper
            # still carries live sittings - archiving suspends the crons, not
            # the candidates - and that is the branch where the live-attempt
            # refusal never runs. Without this the API said nothing about them
            # while the Odoo wizard, which has no `active` gate, reported them.
            "live_attempt_count": len(evaluators.filtered(
                lambda e: e.state == "in_progress")),
        }

        # STEP ONE, unconditionally - including on the confirmed call, where it
        # is what makes an unlink that then fails leave a suspended paper
        # rather than a live one that the operator believes is gone. It is a
        # no-op on an already-archived assessment.
        if record.active:
            live = _live_attempt_refusal(record)
            if live:
                # A live sitting still needs its own confirmation before the
                # clock stops, and it is a DIFFERENT question from "destroy
                # this": the operator must answer both, in this order, because
                # the archive is the step that actually interrupts candidates.
                return live
            record.write({"active": False})

        confirm = str_arg("confirm_name")
        if confirm.strip().casefold() != (record.name or "").strip().casefold():
            return fail(
                "confirm_required",
                "Archived. Deletes %d candidate(s) and %d response(s). "
                "LLM spend is kept." % (counts["candidate_count"],
                                 counts["response_count"]),
                status=409, archived=True, **counts)

        record.with_context(
            **{record.CONFIRMED_DESTROY_CTX: True}).unlink()
        return ok(dict(counts, deleted=True))

    @http.route("/api/v1/generators/<int:generator_id>/question_types",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def generator_question_types(self, generator_id, **kw):
        """Set which question types a generator is allowed to author.

        Takes CODES ("mcq", "image_ab"), not database ids: the code is the
        stable identifier the client already knows from every other payload,
        and it survives a reinstall that renumbers the rows.

        Replaces the whole set rather than toggling one: a toggle needs the
        client and server to agree on the current state, and they will not
        after any concurrent edit. Sending the full list is idempotent.
        """
        record = _generator(generator_id)
        if not record:
            return fail("not_found", "Generator not found", status=404)

        codes = [str(c).strip() for c in (arg("codes") or []) if str(c).strip()]
        types = request.env["assessments.be.question.type"].search(
            [("code", "in", codes)]) if codes else \
            request.env["assessments.be.question.type"].browse()

        missing = set(codes) - set(types.mapped("code"))
        if missing:
            return fail("invalid", "Unknown question type(s): %s"
                        % ", ".join(sorted(missing)), status=422)

        record.allowed_question_type_ids = [(6, 0, types.ids)]
        # CHANGING THE TYPE PICKER MUST RE-VALIDATE THE QUOTAS IT AUTHORED.
        #
        # A per-type quota is an instruction about the allow-list. Turning a
        # type off - or clearing the picker entirely - used to leave its count
        # behind in `shape_quota_json`: invisible in the picker, but still on
        # the Generate button and still sent to the model as a directive.
        # Live example: generator 178 read "3 questions - 1 Rubric, 2 MCQ" with
        # nothing selected. Re-parsing against the NEW list drops exactly the
        # shapes that stopped meaning anything, and keeps template shapes,
        # which name their own type.
        stored = parse_shape_quotas(record.shape_quota_json)
        if stored:
            kept = parse_shape_quotas(
                stored, allowed_types=tuple(types.mapped("code")))
            if kept != stored:
                record.shape_quota_json = (
                    json.dumps(kept, ensure_ascii=False) if kept else "")
        return ok(S.generator_detail(record))

    @http.route("/api/v1/generators/create", type=API_TYPE, auth="user",
                methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def generator_create(self, **kw):
        name = str_arg("name").strip()
        if not name:
            return fail("invalid", "A name is required", status=422)

        values = _picked(self.GENERATOR_FIELDS)
        values["name"] = name
        record = request.env["assessments.be.prompt"].create(values)
        return ok(S.generator_detail(record))

    @http.route("/api/v1/generators/<int:generator_id>/resources",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def generator_resource_upload(self, generator_id, **kw):
        """Attach a SOP or reference document to a generator.

        This is step 2 of the question-bank flow: an admin uploads the SOP and
        the document is sent NATIVELY to the model, which authors the drafts
        from it. Nothing downstream works without it - extract_tags and
        generate both refuse with `no_source` until a generator has one.

        Base64 inside the JSON envelope rather than a multipart upload, so the
        whole API keeps ONE auth path and ONE error shape. A multipart route
        would need its own `type="http"` handler, its own session handling and
        its own failure format, for a file that is a few hundred KB.

        Creating the record is the whole job: the resource model's `create`
        runs `_run_extraction` itself, pulling text out of docx/txt/md/csv/
        html/json/xml. PDF and images are deliberately NOT text-extracted -
        they go to the model natively - so an empty `extracted_text` on a PDF
        is correct, not a failure.
        """
        record = _generator(generator_id)
        if not record:
            return fail("not_found", "Generator not found", status=404)

        name = str_arg("name").strip()
        content = str_arg("content")
        category = str_arg("category") or "sop"
        if not name:
            return fail("invalid", "A file name is required", status=422)
        if not content:
            return fail("invalid", "File content is required", status=422)
        if category not in _RESOURCE_CATEGORIES:
            return fail("invalid", "category must be one of: %s"
                        % ", ".join(sorted(_RESOURCE_CATEGORIES)), status=422)
        # 'golden' is still accepted from an older client, and stored as
        # 'sample' by the model: they are one list (owner, 2026-09-29).

        # A data URL is what a browser's FileReader produces; accepting it
        # saves every client from having to strip the prefix itself.
        if content.startswith("data:"):
            _, _, content = content.partition(",")
        # Refused up front rather than at the model call: an oversized
        # document fails INSIDE the paid generation request, which bills for
        # the attempt and reports it as a generation failure.
        refused = _too_large(content)
        if refused:
            return refused
        try:
            raw = base64.b64decode(content, validate=True)
        except (binascii.Error, ValueError):
            return fail("invalid", "content must be base64", status=422)

        if not raw:
            return fail("invalid", "The file is empty", status=422)

        resource = request.env["assessments.be.prompt.resource"].create({
            "prompt_id": record.id,
            "name": name,
            "category": category,
            # Re-encoded from the decoded bytes so a data-URL prefix or stray
            # whitespace cannot reach the field.
            "file": base64.b64encode(raw),
        })

        return ok({
            "resource": {
                "id": resource.id,
                "name": resource.name,
                "category": resource.category,
                "bytes": len(raw),
                "status": resource.status,
                "char_count": resource.char_count,
                "extraction_error": resource.extraction_error or "",
            },
            "generator": S.generator_detail(record),
        })

    @http.route("/api/v1/generators/<int:generator_id>/resources/"
                "<int:resource_id>/delete",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def generator_resource_delete(self, generator_id, resource_id, **kw):
        """Detach a document. Scoped to its generator so an id from another
        generator cannot be deleted by guessing a number."""
        record = _generator(generator_id)
        if not record:
            return fail("not_found", "Generator not found", status=404)

        resource = request.env["assessments.be.prompt.resource"].browse(
            resource_id).exists()
        if not resource or resource.prompt_id.id != record.id:
            return fail("not_found", "Resource not found", status=404)

        resource.unlink()
        return ok(S.generator_detail(record))

    @http.route("/api/v1/generators/<int:generator_id>/delete",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def generator_delete(self, generator_id, **kw):
        """Delete a generator, and take its bank questions out of the bank.

        NEVER REFUSED, and never destructive when it cannot comply - the two
        halves of the same promise, reported as `outcome`:

        "deleted" - NO ASSESSMENT USES THIS GENERATOR. The row really is
        deleted; its drafts and its SOP files go with it - both are
        ondelete="cascade" - and neither is history anybody can appeal to: a
        draft that was never approved and a document that has already been read
        into tags. Its approved questions each take the retire-or-erase
        decision a direct delete uses (`generator_id` is ondelete="set null",
        so otherwise they would linger in the bank, pickable for a new paper
        and unable to say which SOP justified them): erased when nothing points
        at one, moved to Deleted when something does.

        "kept" - AN ASSESSMENT USES THIS GENERATOR, so the row cannot be
        erased: `assessment.generator_id` is ondelete="restrict" and the
        model's own ondelete guard refuses first. It is marked `deleted` -
        out of every list and out of Archived, never restorable - and its
        questions take the same erase-or-Deleted rule. Every paper, answer and
        score built from it is untouched. Archive is `/generators/<id>/archive`.

        `draft_count` and `resource_count` describe DESTRUCTION ONLY, so they
        are zero on the kept branch - see `_generator_erase_counts`.

        Answers `preview` without writing anything, so the confirmation an
        operator reads and the work this does are computed by the same code -
        including which of the two branches applies.
        """
        record = _generator(generator_id)
        if not record:
            return fail("not_found", "Generator not found", status=404)
        if bool_arg("preview"):
            return ok(_generator_delete_preview(record))

        summary = _delete_generator_isolated(record)
        return ok(summary)

    @http.route("/api/v1/generators/delete", type=API_TYPE, auth="user",
                methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def generator_delete_many(self, **kw):
        """Bulk delete, for the list's checkbox selection.

        One route rather than N calls: the client shows ONE confirmation for
        the whole selection, so the whole selection has to be previewed and
        applied together or the sentence it showed stops being true halfway
        through.

        ONE UNIT TO PREVIEW, BUT NOT ONE UNIT TO SUCCEED OR FAIL. Each
        generator is decided and applied on its own, inside its own savepoint
        (`_delete_generator_isolated`), and reports its own `outcome` -
        "deleted" or "kept". A selection that mixes a fresh generator with
        one an assessment has already used is the normal case, not an error,
        and one that cannot be erased must neither abort the batch nor undo the
        siblings that were already processed.
        """
        ids = id_list_arg("ids")
        if not ids:
            return fail("no_ids", "Select at least one generator", status=400)
        records = request.env["assessments.be.prompt"].with_context(
            active_test=False).browse(ids).exists()
        if not records:
            return fail("not_found", "No such generators", status=404)

        if bool_arg("preview"):
            previews = [_generator_delete_preview(r) for r in records]
            return ok({
                "generators": previews,
                "generator_count": len(records),
                "deleted_count": sum(
                    1 for p in previews if p["outcome"] == "deleted"),
                "kept_count": sum(
                    1 for p in previews if p["outcome"] == "kept"),
                # Sums the per-generator counts, which are already zero for
                # every kept one - so a mixed selection reports only the
                # drafts and files the erase branch actually takes.
                "draft_count": sum(p["draft_count"] for p in previews),
                "resource_count": sum(p["resource_count"] for p in previews),
                "retired_question_count": sum(
                    p["retired_question_count"] for p in previews),
                "deleted_question_count": sum(
                    p["deleted_question_count"] for p in previews),
                "assessment_count": len({
                    a["id"] for p in previews for a in p["assessments"]}),
            })

        summaries = [_delete_generator_isolated(r) for r in records]
        # `deleted_count` counts the generators actually ERASED, not the ones
        # processed - it used to be `len(summaries)`, which now would report an
        # archived generator as deleted and put the client's summary line back
        # in the business of contradicting what happened.
        return ok({
            "generators": summaries,
            "generator_count": len(summaries),
            "deleted_count": sum(
                1 for s in summaries if s["outcome"] == "deleted"),
            "kept_count": sum(
                1 for s in summaries if s["outcome"] == "kept"),
            "draft_count": sum(s["draft_count"] for s in summaries),
            "resource_count": sum(s["resource_count"] for s in summaries),
            "retired_question_count": sum(
                s["retired_question_count"] for s in summaries),
            "deleted_question_count": sum(
                s["deleted_question_count"] for s in summaries),
        })

    @http.route("/api/v1/generators/<int:generator_id>/update",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def generator_update(self, generator_id, **kw):
        record = _generator(generator_id)
        if not record:
            return fail("not_found", "Generator not found", status=404)

        values = _picked(self.GENERATOR_FIELDS)
        # PER-SHAPE COUNTS. A dict, not a scalar, so it cannot ride
        # GENERATOR_FIELDS' type map. Validated through the same parser
        # generation uses, so what is stored is exactly what will be honoured -
        # a quota the parser would reject must not sit in the field looking
        # active. `{}` explicitly clears.
        quotas = body().get("shape_quotas")
        if quotas is not None:
            if not isinstance(quotas, dict):
                return fail("bad_request",
                            "`shape_quotas` must be an object of "
                            "{shape: count}.", status=400)
            allowed = tuple(
                t.code for t in record.allowed_question_type_ids if t.code)
            parsed = parse_shape_quotas(quotas, allowed_types=allowed)
            dropped = sorted(set(quotas) - set(parsed))
            if dropped:
                return fail(
                    "bad_request",
                    "These shapes cannot be used: %s. A question-type shape "
                    "must be one this generator allows, a template shape must "
                    "look like template:<id>, and every count must be a "
                    "positive whole number." % ", ".join(dropped),
                    status=400, dropped=dropped)
            # AN ARCHIVED TEMPLATE CANNOT GENERATE, so accepting the quota only
            # defers the failure to a paid run: `_resolve_template_shapes`
            # skips inactive templates, and the operator learns from the run
            # report AFTER the spend, having been shown a confident
            # "Generate N questions" beforehand. Refuse it here, naming the
            # template, while the operator is still on the screen that set it.
            archived = _archived_template_shapes(record.env, parsed)
            if archived:
                return fail(
                    "bad_request",
                    "These tasks are archived and cannot generate: %s. "
                    "Restore the template or remove it from the run."
                    % ", ".join(archived),
                    status=400, dropped=sorted(archived))
            values["shape_quota_json"] = (
                json.dumps(parsed, ensure_ascii=False) if parsed else "")
        if values:
            record.write(values)
        return ok(S.generator_detail(record))

    @http.route("/api/v1/generators/<int:generator_id>/archive",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def generator_archive(self, generator_id, **kw):
        """Archive or restore a generator.

        A SEPARATE ROUTE RATHER THAN A FIELD ON `update`, because archiving is
        a decision and not an edit: it removes the generator from every default
        list at once, and a client that could set `active` as part of a general
        write could do that as a side effect of saving a renamed title.

        Retiring rather than deleting is the point - an archived generator
        keeps the questions it authored, and those questions keep their link
        back to the document that justified them. Deleting would break that
        chain for every assessment already sat.
        """
        # `active_test=False` because a generator, once archived, is invisible
        # to an ordinary browse - so without it the UNARCHIVE call could never
        # find its own record and always answered 404.
        record = request.env["assessments.be.prompt"].with_context(
            active_test=False).browse(generator_id).exists()
        if not record:
            return fail("not_found", "Generator not found", status=404)

        denied = record_read_guard(record)
        if denied:
            return denied

        # Default True so a bare POST archives; unarchiving is the explicit
        # act, matching the button that sends it.
        if record.deleted:
            return fail("deleted", "A deleted generator cannot be restored. "
                        "Its assessments, answers and scores are kept.",
                        status=409)
        record.write({"active": not bool_arg("archive", True)})
        return ok(S.generator_detail(record))

    @http.route("/api/v1/generators/<int:generator_id>/extract_tags",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def generator_extract_tags(self, generator_id, **kw):
        """Read the SOP and derive its tags. Costs an LLM call."""
        return _sop_action(
            generator_id, "action_extract_tags",
            "Attach an SOP document before extracting tags")

    @http.route("/api/v1/generators/<int:generator_id>/generate",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def generator_generate(self, generator_id, **kw):
        """Generate question drafts from the SOP.

        The expensive one, so it refuses early when the generator has nothing
        to read rather than burning a call to discover the same thing.
        """
        return _sop_action(
            generator_id, "action_generate_from_sop",
            "Attach an SOP document before generating questions")

    @http.route("/api/v1/generators/<int:generator_id>/cancel_generation",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def generator_cancel_generation(self, generator_id, **kw):
        """Kill this generator's question generation. Spends nothing.

        A ROUTE OF ITS OWN, not a field on `update`, for the same reason
        `archive` is: `sop_gen_state` is deliberately absent from
        `GENERATOR_FIELDS`, because a client that could write the run's state
        as part of a general save could restart or fake a run as a side effect
        of renaming the generator.

        NOT `_sop_action`: every route that uses that helper refuses a
        generator with no SOP, and refusing to STOP a run because the document
        it was reading has since been removed is exactly backwards.

        `cancelled: false` means there was nothing running - reported as a
        success, because the caller's intent (this generator is not to spend
        any more) is satisfied either way.
        """
        record = _generator(generator_id, allow_deleted=True)
        if not record:
            return fail("not_found", "Generator not found", status=404)
        cancelled = bool(record.action_cancel_generation())
        payload = S.generator_detail(record)
        payload["cancelled"] = cancelled
        # Same `notice` shape `_sop_action` builds, so the client renders the
        # outcome of this button with the code it already has for the others.
        payload["notice"] = {
            "kind": "info",
            "title": "Generation cancelled" if cancelled
                     else "Nothing to cancel",
            "message": (
                "Generation will stop at the next model call. Draft questions "
                "already produced are kept for you to review or discard."
                if cancelled else
                "This generator has no run in progress."),
            "is_warning": False,
        }
        return ok(payload)

    @http.route("/api/v1/generators/<int:generator_id>/cancel_tag_extract",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def generator_cancel_tag_extract(self, generator_id, **kw):
        """Kill this generator's Extract skills run. Spends nothing.

        Its own route for the reasons `cancel_generation` gives. A queued run
        stops at once; a running one's reply is not applied when it lands.
        """
        record = _generator(generator_id, allow_deleted=True)
        if not record:
            return fail("not_found", "Generator not found", status=404)
        cancelled = bool(record.action_cancel_tag_extract())
        payload = S.generator_detail(record)
        payload["cancelled"] = cancelled
        payload["notice"] = {
            "kind": "info",
            "title": "Extract skills stopped" if cancelled
                     else "Nothing to stop",
            "message": (
                "The SOP reading is cancelled. The skills already on this "
                "generator are unchanged." if cancelled else
                "This generator is not extracting skills."),
            "is_warning": False,
        }
        return ok(payload)

    @http.route("/api/v1/generators/<int:generator_id>/retry_failed_images",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def generator_retry_failed_images(self, generator_id, **kw):
        """Queue the latest run's failed image renders again.

        The same drafts `/generators/<id>/progress` counts in
        `images.failed`, so the button's "(n)" is what it retries. Refused
        when nothing failed, as `/drafts/<id>/retry_images` is, so a click
        that queued nothing does not read as one that did.
        """
        record = _generator(generator_id)
        if not record:
            return fail("not_found", "Generator not found", status=404)
        failed = request.env["assessments.be.prompt.question"].search(
            record._latest_run_draft_domain()
            + [("image_state", "=", "failed")])
        if not failed:
            return fail("not_applicable",
                        "This generator has no failed images to retry.",
                        status=409)
        failed.action_retry_image_render()
        return ok({"retried": len(failed)})

    @http.route("/api/v1/generators/<int:generator_id>/extract_structures",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def generator_extract_structures(self, generator_id, **kw):
        return _sop_action(generator_id, "action_extract_structures")

    @http.route("/api/v1/generators/<int:generator_id>/approve_all",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def generator_approve_all(self, generator_id, **kw):
        """Approve every remaining draft on this generator.

        Drafts carrying an authoring smell are HELD, not approved, and named in
        the returned notice. This route used to reach `action_approve_all_drafts`
        with no gate at all while `/drafts/<id>/approve` refused those same
        drafts, so the bulk button banked in one click exactly what the per-draft
        gate had just stopped - and the client's own tooltip claimed the server
        refused them.

        `acknowledge_warnings` is the deliberate opt-out for a caller that has
        already reviewed them. The batch button does NOT send it: a single click
        cannot stand for a per-item human judgement on drafts nobody opened.
        """
        return _sop_action(
            generator_id, "action_approve_all_drafts",
            context={"acknowledge_warnings": bool_arg("acknowledge_warnings")})

    @http.route("/api/v1/generators/<int:generator_id>/backfill_tags",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def generator_backfill_tags(self, generator_id, **kw):
        """Re-tag every question this generator already produced.

        Distinct from `extract_tags`, which reads the SOP and populates the
        generator's own vocabulary. This one pushes that vocabulary DOWN onto
        questions authored before the vocabulary existed, which is the only way
        to make an older bank searchable by the tags a later extraction found.

        IT DISPATCHED TO THE WRONG METHOD. `action_backfill_all_tags` is an
        `@api.model` maintenance sweep: it discards the recordset, searches
        every generator that has NO tags, and queues tag EXTRACTION on them.
        So this route touched no question at all, ignored the generator it was
        called for, and - because the button that calls it is only rendered
        once a generator HAS tags - could not even act on its own caller. The
        docstring above described a feature nothing implemented.
        """
        return _sop_action(generator_id, "action_backfill_tags_to_questions")

    # Fields a reviewer may change on a draft, mirroring what the Odoo form
    # leaves editable. `question_type` is included deliberately: the generator
    # sometimes picks the wrong shape for an otherwise good question, and
    # re-generating to change one dropdown is exactly the waste this route
    # exists to stop.
    DRAFT_FIELDS = {
        "name": "str",
        "question_prompt": "str",
        "description": "str",
        "question_type": "str",
        "difficulty": "str",
        "time_minutes": "int",
        "official_reasoning": "str",
        # Computed with an inverse, so writable: the seven rubric fields the
        # form exposes for a subjective question.
        "ak_ideal_answer": "str",
        "ak_mandatory_elements": "str",
        "ak_penalty_rules": "str",
        "ak_scoring_guide": "str",
        "ak_checklist": "str",
        "ak_constraints": "str",
        "ak_pass_condition": "str",
    }

    @http.route("/api/v1/drafts/<int:draft_id>/update", type=API_TYPE,
                auth="user", methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def draft_update(self, draft_id, **kw):
        """Edit a draft question before approving it.

        The review queue is a human-in-the-loop step, and until now the human
        had no loop: approve as-is, or deny and pay for another generation.
        Odoo's form has always been editable down to the `is_correct` toggle;
        this is that capability over HTTP.

        A draft has no candidate answers behind it, so its answer key can be
        restructured freely - which is the whole reason editing is safe HERE
        and guarded on the bank.
        """
        record = _draft(draft_id)
        if not record:
            return fail("not_found", "Draft not found", status=404)
        if record.state != "draft":
            return fail("already_decided",
                        "This draft has already been %s; edit the bank "
                        "question instead." % record.state, status=409)

        values = _picked(self.DRAFT_FIELDS)
        refused = _bad_selection(record, values)
        if refused:
            return refused

        # A DRAFT HAS TWO REPRESENTATIONS OF ONE ANSWER KEY, AND THE RELATIONAL
        # ONE IS THE PUBLISHED ONE.
        #
        # `options_json` + `correct_answer_json` is what the generator writes.
        # `answer_dimension_ids` is the editable axis tree Odoo's form binds -
        # and `create()` seeds it from that JSON on every generated draft, so it
        # is NOT empty, whatever this comment used to claim. `_dimension_specs`
        # PREFERS it, and `_materialize_dimensions` publishes from it at approve
        # time.
        #
        # So a write to either one MUST rebuild the other. Without that, this
        # route rewrote the JSON, approval read the untouched relational rows,
        # and the bank question came out carrying the PRE-EDIT key: every answer
        # key corrected through this app was silently thrown away at the moment
        # it mattered, with a 200 on the save and no way to tell from the UI.
        qtype = values.get("question_type") or record.question_type
        options = arg("options")
        correct = arg("correct_answer", _MISSING)
        rows = arg("dimensions")
        flat = options is not None or correct is not _MISSING

        # Two spellings of the same key in one request has no correct
        # resolution - picking a winner would discard an edit the caller
        # believes it made, which is the bug above wearing a different hat.
        if flat and rows is not None:
            return fail("conflicting_key",
                        "Send either options/correct_answer or dimensions, "
                        "not both", status=422)

        # image_ab keys live in `dimensions_json`, which `_specs_from_json`
        # reads BEFORE the flat fields. Rebuilding after a flat edit would
        # therefore restore the pre-edit key - the same silent discard, one
        # layer down. The Odoo form hides the flat fields for this type for the
        # same reason, and a flat list cannot express its several axes anyway.
        if flat and qtype == "image_ab":
            return fail("use_dimensions",
                        "An A/B question is keyed per axis; send `dimensions`",
                        status=422)

        if flat:
            merged_options = options if options is not None \
                else loads_list(record.options_json)
            if not isinstance(merged_options, list):
                return fail("invalid", "options must be a list of strings",
                            status=422)
            merged_options = [str(o).strip() for o in merged_options
                              if str(o).strip()]
            merged_correct = correct if correct is not _MISSING \
                else loads_any(record.correct_answer_json)
            problem = answer_key_problem(qtype, merged_options,
                                         merged_correct)
            if problem:
                return fail("invalid", problem, status=422)
            values["options_json"] = json.dumps(merged_options,
                                                ensure_ascii=False)
            values["correct_answer_json"] = json.dumps(merged_correct,
                                                       ensure_ascii=False)
            # Belt and braces: empty for mcq/msq by construction, but a
            # hand-edited draft carrying one would send the rebuild below to the
            # wrong source and discard this edit exactly as before.
            values["dimensions_json"] = False

        # VALIDATE EVERYTHING BEFORE THE WRITE, like `bank_update` does.
        # `fail(...)` is RETURNED, not raised, so a rejected save still reaches
        # the end of the request and Odoo commits whatever was written before
        # it: these two checks used to run after `record.write(values)`, so a
        # request carrying a good title and a malformed answer key was answered
        # 422 while the title, the prompt and the question TYPE were quietly
        # persisted. A refusal has to leave the draft exactly as it found it.
        if rows is not None:
            if not isinstance(rows, list):
                return fail("invalid", "dimensions must be a list", status=422)
            problem = _check_answer_key(qtype, rows)
            if problem:
                return problem

        # THE AXES FIRST, BEFORE ANY OTHER WRITE. `_sync_dimensions` checks
        # every row before its first write, and its refusals (an unknown axis
        # id) are RETURNED, so syncing after the write below left the new
        # title saved behind a 404.
        if rows is not None:
            # protect_answers=False is safe here and only here: a draft's
            # options are a DIFFERENT model from the bank options a response
            # line points at, so no candidate answer can reference one.
            denied = _sync_dimensions(record, rows, "answer_dimension_ids",
                                      "label", protect_answers=False)
            if denied:
                return denied
            # The JSON copy follows the saved rows: Rebuild Answer Key reads
            # it and would bring the pre-edit key back. Re-read first, so the
            # options come back in stored order, not the order written.
            record.env.invalidate_all()
            if record.answer_dimension_ids:
                values["dimensions_json"] = json.dumps(
                    record._dimension_specs(), ensure_ascii=False)

        # WRITE FIRST, THEN REBUILD. The rebuild reads the stored JSON, so
        # running it before the write rebuilds from the pre-edit values and
        # changes nothing - the failure this whole block exists to stop.
        if values:
            record.write(values)

        if flat:
            # The same method the Odoo button and /rebuild_answer_key call, so
            # the three cannot drift apart.
            record.action_rebuild_answer_key_from_json()

        # Flush inside the request so a constraint violation is reported here
        # rather than surfacing later from the serializer.
        record.flush_recordset()
        return ok(S.draft_detail(record))

    # The bank counterpart. `active` is here so a question can be retired from
    # the same screen that shows it is broken.
    BANK_FIELDS = {
        "name": "str",
        "prompt": "str",
        "description": "str",
        "difficulty": "str",
        "time_minutes": "int",
        "sequence": "int",
        "official_reasoning": "str",
        "rubric_reviewed": "bool",
        "active": "bool",
    }

    @http.route("/api/v1/bank/<int:question_id>/delete", type=API_TYPE,
                auth="user", methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def bank_delete(self, question_id, **kw):
        """Take a question out of the bank.

        NEVER REFUSED. A question used by a live paper is a bad thing to
        delete, but it is the operator's call and not this route's - so the
        answer is a preview that names exactly what is at stake, and then
        whatever they decide. What the route DOES refuse to do is pretend: a
        question with history is retired rather than erased, because erasing it
        would delete answers and rewrite scores. See the module comment above
        `_retire_or_delete_question`.

        `preview` costs nothing and writes nothing; the confirmation the client
        shows is computed by the same code that does the work.
        """
        question = request.env["assessments.be.question"].with_context(
            active_test=False).browse(question_id).exists()
        if not question:
            return fail("not_found", "Question not found", status=404)
        if bool_arg("preview"):
            return ok(_question_delete_preview(question))
        return ok(_retire_or_delete_question(question))

    @http.route("/api/v1/bank/delete", type=API_TYPE, auth="user",
                methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def bank_delete_many(self, **kw):
        """Bulk delete, for the bank's checkbox selection.

        One route rather than N calls, for the same reason the generator bulk
        delete is one route: the operator confirms ONE sentence about the whole
        selection, so the whole selection is previewed and applied together.
        """
        ids = id_list_arg("ids")
        if not ids:
            return fail("no_ids", "Select at least one question", status=400)
        questions = request.env["assessments.be.question"].with_context(
            active_test=False).browse(ids).exists()
        if not questions:
            return fail("not_found", "No such questions", status=404)

        if bool_arg("preview"):
            rows = [_question_delete_preview(q) for q in questions]
        else:
            rows = [_retire_or_delete_question(q) for q in questions]
        return ok({
            "questions": rows,
            "question_count": len(rows),
            "retired_count": sum(
                1 for r in rows if r["outcome"] == "retired"),
            "deleted_count": sum(
                1 for r in rows if r["outcome"] == "deleted"),
            "assessments": list({
                a["id"]: a for r in rows for a in r["assessments"]}.values()),
        })

    @http.route("/api/v1/bank/<int:question_id>/restore", type=API_TYPE,
                auth="user", methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def bank_restore(self, question_id, **kw):
        """Put a retired question back in the bank.

        The other half of retiring, and the reason retiring is the safe branch:
        a delete pressed by mistake on a question with history is recoverable
        from the product rather than from the database. A question that was
        genuinely erased has no row to find, which is the honest difference
        between the two outcomes.

        `active_test=False` on the browse, or this could never find its own
        record - the row it exists to reach is archived by definition.
        """
        question = request.env["assessments.be.question"].with_context(
            active_test=False).browse(question_id).exists()
        if not question:
            return fail("not_found", "Question not found", status=404)
        if question.deleted:
            return fail("deleted", "A deleted question cannot be restored. "
                        "Its assessments, answers and scores are kept.",
                        status=409)
        question.sudo().retired = False
        return ok(S.bank_question_detail(question))

    @http.route("/api/v1/bank/archive", type=API_TYPE, auth="user",
                methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def bank_archive_many(self, **kw):
        """Archive questions, or restore them with `archive: false`.

        ERASES NOTHING, which is the whole point. The bank's Archive button used
        to call `bank/delete`, and that erases every selected question nothing
        points at. Archiving is `retired` - the flag `bank/<id>/restore` clears
        - and never `active`, which would drop the question out of papers
        already built.
        """
        ids = id_list_arg("ids")
        if not ids:
            return fail("no_ids", "Select at least one question", status=400)
        questions = request.env["assessments.be.question"].with_context(
            active_test=False).browse(ids).exists()
        if not questions:
            return fail("not_found", "No such questions", status=404)
        # A deleted question stays where Delete put it, either way.
        questions = questions.filtered(lambda q: not q.deleted)
        questions.sudo().write({"retired": bool_arg("archive", True)})
        return ok({"question_count": len(questions)})

    @http.route("/api/v1/bank/<int:question_id>/update", type=API_TYPE,
                auth="user", methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def bank_update(self, question_id, **kw):
        """Edit a bank question, including its answer key.

        RETROACTIVE BY NATURE, which is why the guard exists. A bank question
        may already have been sat: its options are referenced by
        `response.line.selected_option_id` with ondelete="restrict", so
        removing one would rewrite somebody's submitted answer. Text edits and
        adding options are always safe; deleting an option a candidate chose is
        refused with the option named.

        Changing `is_correct` on a question that has been answered re-decides
        those answers - the module scores against the live key on purpose, so
        a corrected key corrects the marks. That is the intended behaviour and
        it is why the answer key is worth being able to fix at all.
        """
        record = request.env["assessments.be.question"].with_context(
            active_test=False).browse(question_id).exists()
        if not record:
            return fail("not_found", "Question not found", status=404)
        _refuse_if_deleted(record)

        denied = record_read_guard(record)
        if denied:
            return denied

        values = _picked(self.BANK_FIELDS)
        refused = _bad_selection(record, values)
        if refused:
            return refused
        rows = arg("dimensions")
        if rows is not None:
            if not isinstance(rows, list):
                return fail("invalid", "dimensions must be a list", status=422)
            bad = _check_answer_key(record.question_type, rows)
            if bad:
                return bad

        # The key first, so a refused one (an option a candidate chose, an
        # unknown axis) leaves the rest unwritten too - see `draft_update`.
        if rows is not None:
            denied = _sync_dimensions(
                record, rows, "question_dimension_ids", "name",
                protect_answers=True)
            if denied:
                return denied
        if values:
            record.write(values)
        record.flush_recordset()
        return ok(S.bank_question_detail(record))

    @http.route("/api/v1/drafts/<int:draft_id>/apply_image",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def draft_apply_image(self, draft_id, **kw):
        """Replace one image slot on a draft question with an upload.

        ON THE DRAFT, NOT THE GENERATOR. `upload_image`, `upload_slot` and
        `action_apply_uploaded_image` all live on
        assessments.be.prompt.question - the individual question - which
        is the only place the slot letters mean anything. A generator has no
        image slots to replace.

        Odoo does this with a binary field plus a button; over HTTP the file
        arrives as base64 in `image`, is staged onto that same field, and the
        module's own action ingests it - so slot handling, the images_json
        rewrite and the `image_state` transition stay in one place rather than
        being reimplemented here and drifting.

        The staging field is cleared on failure: leaving a rejected upload
        parked on the record means the NEXT press of the button applies a file
        the operator thought had been discarded.
        """
        record = _draft(draft_id)
        if not record:
            return fail("not_found", "Draft not found", status=404)

        raw = str_arg("image") or ""
        if not raw:
            return fail("no_image", "Attach an image first", status=400)
        # Accept a data: URL as well as bare base64 - a browser's FileReader
        # hands back the former, and silently storing the "data:image/png;
        # base64," preamble as image bytes produces a corrupt slot.
        if raw.startswith("data:"):
            _, _, raw = raw.partition(",")
        # Sized before decoding, like every other upload here: this one had
        # no ceiling at all.
        refused = _too_large(raw, "That image")
        if refused:
            return refused
        try:
            base64.b64decode(raw, validate=True)
        except (ValueError, binascii.Error):
            return fail("bad_image", "Image is not valid base64", status=400)

        slot = (str_arg("slot", max_len=16) or "a").strip().lower()
        record.write({"upload_image": raw, "upload_slot": slot})
        try:
            record.action_apply_uploaded_image()
        except Exception:
            record.write({"upload_image": False})
            raise
        return ok(S.draft_detail(record))

    @http.route("/api/v1/generators/<int:generator_id>/rank_similarity",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def generator_rank_similarity(self, generator_id, **kw):
        """Re-run the hybrid (lexical + semantic) similarity ranking.

        The Similarity tab reads `similarity_source_ids`, which only exists
        once this has run. Without the route the tab showed "no similar
        generators" beside a `similar_count` badge that said otherwise - the
        count is computed lexically on the fly, the ranked pairs are persisted
        and were never being computed at all from the app.

        PAID: this one calls the model for embeddings, which is why it is a
        deliberate button rather than something the detail view triggers.
        """
        record = _generator(generator_id)
        if not record:
            return fail("not_found", "Generator not found", status=404)
        # THE GATE IS THE MAPPING, NOT THE SOP. Ranking compares extracted
        # mappings - `_recompute_similarity` selects peers on `mapping_json`
        # and reads nothing else. `_sop_action`'s shared readiness test is
        # "has a document attached", which would let a generator whose SOP has
        # never been extracted spend on embeddings to be ranked against an
        # empty mapping, and then report success.
        if not record.mapping_json:
            return fail(
                "not_extracted",
                "Extract this generator's skills first - ranking compares "
                "what was extracted, and nothing has been yet.",
                status=409)
        record.action_compute_similarity_semantic()
        return ok(S.generator_detail(record))


    # Drafts

    @http.route("/api/v1/drafts/<int:draft_id>/retry_video",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def draft_retry_video(self, draft_id, **kw):
        """Re-attempt ONLY the clips that failed, keeping the ones that worked.

        Guarded on the failure states rather than offered unconditionally: a
        retry on a draft whose clips all rendered would re-spend on Veo and
        return the same result, and a button that bills money for nothing is
        worse than a disabled one.
        """
        return _draft_action(
            draft_id,
            "action_retry_video_generation",
            guard=lambda d: d.video_state in ("failed", "partial"),
            refusal="This draft has no failed clips to retry.",
        )

    @http.route("/api/v1/drafts/<int:draft_id>/retry_images",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def draft_retry_images(self, draft_id, **kw):
        """Queue a failed image render again. Images already rendered are
        kept, so only the missing slots are paid for."""
        return _draft_action(
            draft_id,
            "action_retry_image_render",
            guard=lambda d: d.image_state == "failed",
            refusal="This draft has no failed images to retry.",
        )

    @http.route("/api/v1/drafts/<int:draft_id>/rebuild_answer_key",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def draft_rebuild_answer_key(self, draft_id, **kw):
        """Recompute the answer key from the draft's stored JSON.

        The recovery path for a key that drifted from its source - the module
        rebuilds it deterministically from the generation payload rather than
        asking a reviewer to retype it, so the key stays provable by
        construction.
        """
        return _draft_action(draft_id, "action_rebuild_answer_key_from_json")

    # Bank import

    @http.route("/api/v1/bank/import", type=API_TYPE, auth="user",
                methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def bank_import(self, **kw):
        """Import questions from a FILE or from a JSON payload.

        Delegates to the module's own `assessments.be.bank.import`, which
        validates every row, materialises answer keys and reports what it
        created. Reimplementing that here would fork the validation and let the
        API create questions the backend itself would reject.

        ONE DETECTED-FORMAT RULE FOR BOTH LANES (W9; `ETP_PLANS_AND_STRATEGY.md`
        §4.4). The file lane sniffs the JSON and routes it; the `payload` lane
        asks the same two predicates rather than trusting a `native` flag from
        the caller:

          harness shape - {id, instruction, fields, ...} or {questions: [...]}
                          -> review DRAFTS in Pending Approvals.
          native shape  - the `assessments_be_bank` sentinel from
                          `question._export_native` -> restored into the bank.
                          The one exemption from "drafts first", because a
                          round-trip restores questions that were already
                          approved here.
          anything else - 422 `invalid_json_shape`, naming both shapes.

        This route never calls `import_bank`, which creates ACTIVE bank
        questions and would put unreviewed JSON straight into the live bank.
        `native` is accepted and ignored: the shape decides, as it does for a
        file, and no caller can ask for one lane with the other's bytes.

        `dry_run` is honoured by neither importer, so it is refused explicitly
        rather than accepted and ignored - an import that silently commits when
        the caller asked for a preview is the worst possible outcome.
        """
        if bool_arg("dry_run"):
            return fail("not_supported",
                        "The module's importer has no dry-run mode. Import "
                        "into a scratch generator to preview.", status=400)

        # THE FILE LANE, and the one a client should use.
        #
        # It hands the bytes to the SAME wizard the Odoo back office uses
        # (`assessments.be.bank.import.wizard.run_import`), so both surfaces
        # accept the same three formats and produce the same records from the
        # same file. They did not: this route took JSON only, so the app
        # converted CSV itself with a six-column Dart parser against this
        # module's thirty-three - and the template an operator downloaded from
        # Odoo lost its dimensions, rubrics and images on the way in, with no
        # error anywhere.
        content = str_arg("content") or str_arg("file") or str_arg("csv")
        if content:
            return self._bank_import_file(content)

        payload = arg("payload")
        harness = wizard_module.harness_payload(payload)
        native = wizard_module.native_payload(payload)
        # Shape-checked HERE rather than letting the importer raise, because
        # its error ("Question bank must be a JSON object") names neither of
        # the two shapes this actually takes. JSON-SPECIFIC: a
        # `question_bank`-shaped body used to be accepted straight into the
        # bank, and the same bytes sent as a FILE answered with the CSV
        # parser's "CSV must have at least a title or prompt column".
        if harness is None and native is None:
            return fail("invalid_json_shape",
                        wizard_module.UNKNOWN_JSON_MESSAGE, status=422)

        model = request.env["assessments.be.bank.import"].sudo()
        try:
            if harness is not None:
                result = model.import_bank_harness(
                    harness,
                    generator_id=int_arg("generator_id", 0) or False,
                    generator_name=str_arg("generator_name") or None,
                )
            else:
                result = model.import_bank_native(native)
        except Exception as exc:                                # noqa: BLE001
            # The importer raises with a row-specific message; pass it through
            # verbatim so the operator learns WHICH row is wrong.
            request.env.cr.rollback()
            return fail("import_failed", str(exc), status=422)

        return ok(result if isinstance(result, dict) else {"result": result})

    @staticmethod
    def _bank_import_file(content):
        """Run an uploaded file through the back office's own importer.

        `content` is base64, with or without a `data:` prefix - a browser
        FileReader produces one and a script usually does not, and refusing
        either would be a difference between clients rather than between
        files.
        """
        raw = (content or "").strip()
        if raw.startswith("data:"):
            raw = raw.split(",", 1)[-1]
        # The wizard caps a CSV only after decoding it, and a JSON file not
        # at all; its own ceiling, checked before anything is decoded.
        refused = _too_large(raw, limit=request.env[
            "assessments.be.bank.import.wizard"]._MAX_CSV_BYTES)
        if refused:
            return refused
        try:
            base64.b64decode(raw, validate=True)
        except Exception:  # noqa: BLE001 - the caller's own encoding error
            return fail("invalid",
                        "`content` must be base64-encoded file bytes.",
                        status=422)

        wizard = request.env["assessments.be.bank.import.wizard"].sudo().create({
            "data_file": raw,
            "data_filename": str_arg("filename", max_len=255) or "import.csv",
            "generator_name": str_arg("generator_name", max_len=120) or False,
        })
        try:
            # The flag the back office's Restore button sends: on this route
            # the shape decides, as the docstring of `bank_import` says.
            result = wizard.with_context(
                confirm_native_restore=True).run_import()
        except Exception as exc:                                # noqa: BLE001
            # The importer raises with a ROW-SPECIFIC message ("Row 14: ...").
            # Passed through verbatim, because the row number is the only part
            # of it the operator can act on.
            request.env.cr.rollback()
            return fail("import_failed", str(exc), status=422)
        return ok(result)

    # Tags

    # ── CSV import for tags and generators ───────────────────────────────
    #
    # BOTH SURFACES, ONE PARSER. These call
    # `assessments.be.simple.import`, which is also what the back-office
    # wizards call - so the same file produces the same records whether it is
    # dropped in Odoo or in the app. Questions already work this way via
    # `/api/v1/bank/import`; before this, tags and generators had no importer
    # here at all and only Odoo's stock free-form `base_import` there, which
    # nothing outside Odoo can offer.

    @http.route("/api/v1/bank/template", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def bank_template(self, **kw):
        """The question CSV, with one example row per question type.

        THE SAME BYTES the back office's Download Template button emits
        (`build_template_csv`), so an operator cannot end up holding two
        different templates depending on where they got one.
        """
        csv_text = wizard_module.build_template_csv()
        return ok({
            "filename": "question_bank_import_template.csv",
            "mimetype": "text/csv",
            "content": base64.b64encode(csv_text.encode("utf-8")).decode(),
        })

    @http.route("/api/v1/bank/template/json", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def bank_template_json(self, **kw):
        """The JSON import template, in either flavour.

        `flavor=harness` (the default) is the authoring harness's shape;
        `flavor=native` is the lossless round-trip export's. THE SAME BYTES the
        wizard's two JSON buttons emit - both call
        `services/bank_json_template.template_json` - so an operator cannot end
        up holding two different templates depending on where they got one.

        AUTH: `auth="user"` + `@require_manager`, the same rung as
        `/api/v1/bank/template` immediately above and as every other template
        route on this API. A template is a read, but it is a read OF THE IMPORT
        CONTRACT for an admin-only importer, and leaving it more open than its
        neighbours would publish the field list of a route nobody below Admin can
        call.

        COST: constant. The harness template is a module constant; the native one
        is exported from a single in-memory `new()` record. Neither reads the
        live bank, so this route cannot be turned into a scan by asking for it
        repeatedly.
        """
        from ...services import bank_json_template

        # THE QUERY STRING HAS TO BE READ EXPLICITLY. `API_TYPE` is `json2`, and
        # Odoo's Json2Dispatcher sets `request.params = jsonrequest | args`
        # (http.py:2613) - the JSON body merged with the PATH parameters, and
        # nothing else. `?flavor=native` never reaches `str_arg`, so a route
        # relying on it alone answers every request with the default: verified in
        # a browser, where `?flavor=native` handed back the harness template with
        # a 200. The documented URL is a query string, so it is read from
        # `httprequest.args` and the body is still honoured for a JSON caller.
        flavor = (str_arg("flavor", max_len=16)
                  or (request.httprequest.args.get("flavor") or "")[:16]
                  or "harness")
        if flavor not in bank_json_template.FLAVORS:
            return fail("invalid",
                        "flavor must be one of %s."
                        % ", ".join(bank_json_template.FLAVORS), status=422)
        return ok(bank_json_template.template_api_payload(
            flavor, env=request.env))

    @http.route("/api/v1/tags/import", type=API_TYPE, auth="user",
                methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def tag_import(self, **kw):
        """Upsert the tag vocabulary from a CSV. Body: `{content, filename?}`."""
        return _run_simple_import("import_tags_csv", str_arg("content"))

    @http.route("/api/v1/tags/template", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def tag_template(self, **kw):
        """The tag CSV, with one example row per facet."""
        return ok(_template_payload(
            "tag_template_csv", "tag_import_template.csv"))

    @http.route("/api/v1/generators/import", type=API_TYPE, auth="user",
                methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def generator_import(self, **kw):
        """Upsert generators from a CSV. Body: `{content, filename?}`."""
        return _run_simple_import("import_generators_csv", str_arg("content"))

    @http.route("/api/v1/generators/template", type=API_TYPE, auth="user",
                methods=API_METHODS, csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def generator_template(self, **kw):
        """The generator CSV, with one filled example row."""
        return ok(_template_payload(
            "generator_template_csv", "generator_import_template.csv"))

    @http.route("/api/v1/tags/merge", type=API_TYPE, auth="user",
                methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def tag_merge(self, **kw):
        """Merge near-duplicate tags into a canonical one.

        Takes ids rather than names: two tags can display the same text after
        normalisation, and merging by name would pick one of them arbitrarily.
        """
        target_id = int_arg("target_id", 0)
        source_ids = id_list_arg("source_ids")
        if not target_id or not source_ids:
            return fail("invalid",
                        "target_id and source_ids are both required",
                        status=422)

        Tag = request.env["assessments.be.tag"]
        target = Tag.browse(target_id).exists()
        sources = Tag.browse(source_ids).exists()
        if not target or not sources:
            return fail("not_found", "No such tag", status=404)
        if target.id in sources.ids:
            return fail("invalid", "A tag cannot be merged into itself",
                        status=422)

        (target | sources).action_merge_tags()
        return ok({"merged": len(sources), "target": S.tag_row(target)})

    @http.route("/api/v1/tags/normalize", type=API_TYPE, auth="user",
                methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def tag_normalize(self, **kw):
        """Consolidate the tag vocabulary and re-extract the given generators.

        Lives on the PROMPT model, not the tag model: normalising is two
        stages - clean the shared vocabulary, then re-extract each selected
        generator against the cleaned version - and only a generator can do the
        second half.

        It calls an LLM, so it takes explicit `generator_ids` rather than
        defaulting to every generator in the database. A no-argument sweep here
        would be an unbounded spend triggered by one click.
        """
        ids = id_list_arg("generator_ids")
        if not ids:
            return fail("invalid",
                        "generator_ids is required - normalising re-extracts "
                        "each generator and calls the LLM",
                        status=422)

        records = request.env["assessments.be.prompt"].browse(ids).exists()
        for record in records:
            _refuse_if_deleted(record)
        if not records:
            return fail("not_found", "No such generator", status=404)

        records.action_normalize_tags()
        return ok({"normalized": len(records)})

    # Invitations

    @http.route("/api/v1/attempts/<int:evaluator_id>/resend",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def attempt_resend(self, evaluator_id, **kw):
        """Re-queue one candidate's invitation.

        The common case is a bounced address that has since been corrected, so
        a failed invite has to be retryable without reassigning the person and
        losing their attempt.
        """
        record = request.env["assessments.be.evaluator"].browse(
            evaluator_id).exists()
        if not record:
            return fail("not_found", "No such attempt", status=404)
        closed = _invitations_closed(record.assessment_id)
        if closed:
            return closed

        record.action_requeue_invitation()
        return ok(S.evaluator_admin_row(record))

    # ── D1: the operator's manual flag and internal remark ───────────────

    @http.route("/api/v1/attempts/<int:evaluator_id>/flag",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def attempt_flag(self, evaluator_id, **kw):
        """Flag ONE SITTING, and/or leave an internal remark on it.

        ON THE ATTEMPT, NOT THE PERSON. A concern is about a paper somebody sat
        on a day: flagging the person would make every assessment they sit
        afterwards arrive pre-suspected, with nowhere to record that the
        concern was about the other sitting. `assessments.be.evaluator` carries
        the stored, indexed `manual_flagged` column, so the roster still filters
        it server-side inside the 200-row clamp.

        TWO INDEPENDENT FEATURES ON ONE ROUTE, and the PATCH semantics are what
        keep them independent: only the keys PRESENT in the body are written.
        `{"flagged": true}` raises the flag and leaves any remark exactly as it
        was; `{"remark": "..."}` records the note and does not touch the flag.
        A route that wrote both on every call would silently blank the remark
        of anybody who ticked the flag from a UI that only sends its own field -
        the single most likely way this feature loses somebody's writing.

        NEITHER KEY PRESENT IS A 422, not a no-op 200. A body with nothing in
        it is a client bug, and answering 200 to it would tell the operator
        their remark was saved.

        `@require_manager`, NOT `@require_operator`. `require_operator`
        (`common.py`) is the read-only Manager rung; this is a write whose
        output justifies a decision about a person, so it belongs on the same
        rung as every other mutating route in this file. A read-only Manager
        SEES flags and cannot set them, which is what keeps requirement 3.8
        intact rather than widening it by accident.

        THE AUDIT LINE GOES ON THE ASSESSMENT. `assessments.be.evaluator` does
        not inherit `mail.thread`, so it has no `message_post` at all -
        `chatter_post` below already refuses attempt-level notes for exactly
        that reason. The dated entry therefore lands on the assessment the
        attempt belongs to and names the candidate, because that trail is
        shared by the whole cohort. Best effort: an action that succeeded and
        then failed to log is still an action that succeeded.
        """
        evaluator = request.env["assessments.be.evaluator"].browse(
            evaluator_id).exists()
        if not evaluator:
            return fail("not_found", "No such attempt", status=404)
        denied = record_read_guard(evaluator)
        if denied:
            return denied

        # PRESENCE, NOT VALUE, and checked against the raw body for both keys.
        #
        # NAMED `payload`, NOT `raw`, and that is not cosmetic: `tools/
        # contract_audit.py` recognises `<name>.get("key")` as a server read
        # only for a fixed set of receiver names, so a local alias called `raw`
        # made this route look like it IGNORED `remark`. It does not - but the
        # contract check said it did, and a reviewer acted on that and reported
        # a bug that was not there. A checker nobody trusts is worse than no
        # checker, so the variable takes a name the checker knows.
        #
        # `bool_arg` reads a MISSING `flagged` as False, so a body carrying only
        # a remark would silently CLEAR a standing flag if presence were not
        # tested first. The same asymmetry the other way: an absent `remark`
        # must leave the existing note alone, never blank it.
        payload = body()
        has_flag = "flagged" in payload and payload.get("flagged") is not None
        has_remark = "remark" in payload and payload.get("remark") is not None
        if not has_flag and not has_remark:
            return fail("invalid",
                        "Send flagged (true/false) and/or remark. An empty "
                        "body changes nothing, so it is a client bug rather "
                        "than a no-op.",
                        status=422)

        vals = {}

        if has_flag:
            # `bool_arg` rather than `bool()`, because `bool("false")` is True:
            # a JSON client that stringifies its booleans would RAISE a flag on
            # the exact request that meant to withdraw one. `bool_arg` reads
            # "false"/"0"/"no"/"off" as False, which is what the rest of this
            # API already promises.
            flagged = bool_arg("flagged")
            vals["manual_flagged"] = flagged
            # WHO AND WHEN, stamped on the raise and blanked on the clear. The
            # fields hold the CURRENT state; the chatter below holds the
            # history, so blanking them is lossless and leaving a stale
            # "raised by" beside an unflagged attempt would read as though the
            # flag still stood.
            vals["manual_flagged_by_id"] = (
                request.env.user.id if flagged else False)
            vals["manual_flagged_at"] = (
                fields.Datetime.now() if flagged else False)

        if has_remark:
            # LENGTH IS REFUSED, NOT TRUNCATED, and this route is deliberately
            # the exception to the file's usual `str_arg(max_len=...)` habit.
            #
            # `str_arg` truncates silently (`common.py`), which is right for a
            # search term - a clipped query returns fewer rows and the operator
            # sees that. It is wrong here: this remark exists so a decision
            # about a person can be justified months later, and a justification
            # whose tail was cut off without anybody being told is worse than
            # one that was refused. The operator can shorten it; they cannot
            # recover what the server dropped.
            remark = str(payload.get("remark") or "").strip()
            if len(remark) > MAX_FLAG_NOTE:
                return fail("invalid",
                            "The remark is %d characters; the limit is %d."
                            % (len(remark), MAX_FLAG_NOTE), status=422)
            vals["manual_remark"] = remark or False

        was = bool(evaluator.manual_flagged)
        evaluator.write(vals)

        # ONE LINE PER REAL CHANGE OF THE FLAG. A repeat call that converges on
        # the same state posts nothing, so a double-click does not fill the
        # assessment's chatter with identical entries.
        if has_flag and was != bool(evaluator.manual_flagged):
            self._log_attempt_flag(evaluator, bool(evaluator.manual_flagged))

        return ok({
            "attempt_id": evaluator.id,
            "candidate_flag": S.candidate_flag_block(evaluator),
        })

    @staticmethod
    def _log_attempt_flag(evaluator, flagged):
        """The audit line, on the ASSESSMENT's chatter.

        The attempt has no `mail.thread` of its own, so the entry names the
        candidate to stay readable on a shared trail. Wrapped, because
        `_log_activity` is already best-effort and this must not turn a
        successful flag into a 500 the operator cannot act on.
        """
        try:
            who = (evaluator.applicant_id.partner_name
                   or evaluator.applicant_id.display_name or "a candidate")
            evaluator.assessment_id._log_activity(
                (Markup("<b>Attempt flagged</b> - an operator flagged %s's "
                        "sitting of this assessment.")
                 if flagged else
                 Markup("<b>Attempt flag cleared</b> - an operator withdrew "
                        "the flag on %s's sitting.")) % who)
        except Exception:  # noqa: BLE001 - the trail is never load-bearing
            _logger.exception(
                "flag audit note failed for attempt %s", evaluator.id)

    @http.route("/api/v1/assessments/<int:assessment_id>/resend_all",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def assessment_resend_all(self, assessment_id, **kw):
        record = request.env["assessments.be"].browse(
            assessment_id).exists()
        if not record:
            return fail("not_found", "Assessment not found", status=404)
        closed = _invitations_closed(record)
        if closed:
            return closed

        record.action_requeue_all_invitations()
        return ok({"requeued": len(record.assessment_evaluator_ids)})

    # Settings

    #: Config parameters the settings screen may write, with their types.
    #: An allow-list because ir.config_parameter is global: an unrestricted
    #: setter would let this route rewrite any system parameter at all.
    #:
    #: Every key here is one the module actually reads back - `constants.py`,
    #: `res_config_settings.py` or `vertex.py`. Deliberately NOT included:
    #: `subjective_threshold`, which is a per-assessment field and belongs on
    #: the assessment record, not in global config.
    #: `assessments_be_v2.pass_threshold` was allow-listed here and read by
    #: NOTHING, so it is gone. The pass bar is the per-assessment
    #: `pass_threshold`; `default_pass_threshold` below only seeds new ones.
    SETTINGS = {
        "assessments_be_v2.default_pass_threshold": "int",
        "assessments_be_v2.score_outlier_sigma": "float",
        "assessments_be_v2.pii_retention_days": "int",
        "assessments_be_v2.daily_llm_cap_usd": "float",
        "assessments_be_v2.per_evaluator_llm_cap_usd": "float",
        # ---------------------------------------------------------------
        # Text settings, added so the app's Settings screen can EDIT what it
        # had only been able to display.
        #
        # Every key below already exists as a field on `res.config.settings`
        # and is already read by `services/vertex.py` or `s3_service.py`; the
        # module's own Odoo form renders the same set under "Vertex AI" and
        # "S3 Storage". Only the API could not write them, so pointing a
        # deployment at a different project or bucket meant a trip into the
        # Odoo back office - on a product whose whole premise is that the
        # Flutter client replaced it.
        #
        # `str` values are STRIPPED and written verbatim; a blank one clears
        # the parameter, which is how an override is removed so the default
        # takes over again.
        # ---------------------------------------------------------------
        "assessments_be_v2.vertex_project_id": "str",
        "assessments_be_v2.vertex_location": "str",
        "assessments_be_v2.vertex_model": "str",
        "assessments_be_v2.generation_model": "str",
        "assessments_be_v2.detection_model": "str",
        # Reads an image to confirm planted flaws are visible. Existed in the
        # resolver but on no form and no allow-list, so it could only be set by
        # writing the ir.config_parameter row by hand.
        "assessments_be_v2.verify_model": "str",
        "assessments_be_v2.scoring_model": "str",
        # Cheap text lane for extract_tags / consolidate_vocab / skill
        # labelling. Empty falls through to generation_model.
        "assessments_be_v2.utility_model": "str",
        # LOW / MEDIUM / HIGH, or empty for the model's own depth. Only affects
        # Gemini 3.x. Anything unrecognised is ignored rather than forwarded,
        # because a bad value here would 400 every call.
        "assessments_be_v2.thinking_level": "str",
        "assessments_be_v2.fallback_model": "str",
        "assessments_be_v2.image_model": "str",
        "assessments_be_v2.video_model": "str",
        "assessments_be_v2.video_location": "str",
        "assessments_be_v2.video_default_duration_s": "str",
        "assessments_be_v2.s3_bucket": "str",
        "assessments_be_v2.s3_region": "str",
        "assessments_be_v2.s3_access_key_id": "str",
        "assessments_be_v2.s3_folder": "str",
        "assessments_be_v2.s3_cdn_url": "str",
        "assessments_be_v2.s3_max_retries": "int",
        # Floored at 900s by `media_stream._presign_seconds`, so a value set
        # too low here cannot reintroduce the mid-exam 403 it exists to stop.
        "assessments_be_v2.media_presign_seconds": "int",
        # Where a password-reset email points. When unset it resolves through
        # `app_origins.client_app_origin` - configured, then the pairing table,
        # then a local client, then this host - so an unconfigured database
        # still mails a reachable link. See RESET_URL_PARAM in
        # controllers/api/auth.py for why this addon owns a parameter the
        # gateway already has one of.
        "assessments_be_v2.password_reset_url": "str",
        "assessments_be_v2.scoring_shards": "int",
        "assessments_be_v2.scoring_parallel_calls": "int",
        "assessments_be_v2.answers_flush_seconds": "int",
        # Whole-paper prefetch, advertised on `/state` and `/begin`
        # (candidate.py `_paper_prefetch`); off by default.
        "assessments_be_v2.paper_prefetch": "bool",
        # The question cache's Redis for a local or stage rig; production
        # sets REDIS_URL, which wins (services/question_cache.py).
        "assessments_be_v2.redis_url": "str",
        "assessments_be_v2.scoring_tick_limit": "int",
        "assessments_be_v2.scoring_batch_size": "int",
        "assessments_be_v2.llm_max_attempts": "int",
        # Operational knobs the Odoo form has always had and the API could not
        # write, so the console could show a deployment it could not steer.
        "assessments_be_v2.vertex_max_rpm": "int",
        "assessments_be_v2.media_redirect_to_s3": "bool",
        # advisory / lease (`_SETTING_CHOICES`); empty clears it to advisory.
        "assessments_be_v2.cron_lock_mode": "str",
    }

    #: WRITE-ONLY, and encrypted at rest by `services/secret_store`.
    #:
    #: These never come BACK from `/api/v1/settings` - it reports each as a
    #: boolean. Sending one replaces it; OMITTING the key leaves the stored
    #: value alone, which is what lets a Save from a form that shows "set"
    #: rather than the value itself not wipe the credential it cannot display.
    #: An explicit empty string clears it, so a credential can still be
    #: removed deliberately.
    SECRETS = (
        "assessments_be_v2.vertex_api_key",
        "assessments_be_v2.vertex_access_token",
        "assessments_be_v2.s3_secret_key",
    )

    @http.route("/api/v1/settings/update", type=API_TYPE, auth="user",
                methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def settings_update(self, **kw):
        """Write the settings named in the payload, all of them or none.

        VALIDATED IN FULL BEFORE THE FIRST WRITE. `fail()` RETURNS a response,
        it does not raise, so nothing rolls back the writes that came before
        it: validating inside the write loop meant a payload whose second key
        was bad left the first key committed while the caller was told 422 and
        showed the operator their old value. Dict order made it worse - which
        keys survived depended on the order of `SETTINGS`, not on anything the
        caller could see. Two passes make the refusal total.
        """
        icp = request.env["ir.config_parameter"].sudo()
        pending = []
        for key, kind in self.SETTINGS.items():
            short = key.split(".", 1)[1]
            value = arg(short, _MISSING)
            if value is _MISSING:
                continue
            if kind == "str":
                if not isinstance(value, str):
                    return fail("invalid", "%s must be text" % short,
                                status=422)
                text = value.strip()
                if len(text) > _MAX_SETTING_CHARS:
                    return fail(
                        "invalid",
                        "%s is over %d characters"
                        % (short, _MAX_SETTING_CHARS),
                        status=422)
                choices = _SETTING_CHOICES.get(key)
                # An empty string clears the override, which is how a caller
                # removes one - only a NON-empty value has to be on the list.
                if choices and text and text not in choices:
                    return fail(
                        "invalid",
                        "%s must be one of %s."
                        % (short, ", ".join(choices)),
                        status=422)
                pending.append((key, short, text))
                continue
            if kind == "bool":
                # STRICT, and it has to be. `ir.config_parameter` stores text,
                # and every falsy-looking string it can hold - "0", "False",
                # "" - is TRUTHY to a plain `bool()` read. A client that sent
                # the string "false" for an off switch would turn the setting
                # ON, which is the wrong direction for a flag that decides
                # whether media is served from S3. So only a real JSON boolean
                # is accepted, and it is stored as the "1"/"" pair Odoo's own
                # Boolean `config_parameter` writes and reads.
                if not isinstance(value, bool):
                    return fail("invalid",
                                "%s must be true or false" % short, status=422)
                pending.append((key, short, "1" if value else ""))
                continue
            number = _number(value)
            if number is None:
                return fail("invalid", "%s must be a number" % short,
                            status=422)
            if number < 0:
                return fail("invalid", "%s cannot be negative" % short,
                            status=422)
            if kind == "int":
                number = int(number)
            if key == DEFAULT_PASS_THRESHOLD_PARAM and not 1 <= number <= 100:
                return fail("invalid", "%s must be between 1 and 100." % short,
                            status=422)
            bounds = _SETTING_BOUNDS.get(key)
            # `number and ...` LETS 0 THROUGH, and 0 does not mean the same
            # thing on both sides of this route - which is why this comment is
            # longer than the line it explains.
            #
            #   * For the BOUNDED integers above (`llm_max_attempts`,
            #     `scoring_batch_size`, `scoring_shards`,
            #     `scoring_parallel_calls`) 0 means "unset, use the module
            #     default": their readers clamp a non-positive value straight
            #     back to the default (`services/scoring.py` `_max_attempts` /
            #     `_scoring_batch_size`, `assessment._scoring_shard_count` /
            #     `_scoring_parallel_calls_setting`). Refusing 0 here would
            #     make this route STRICTER than the Odoo form it is protecting,
            #     which accepts it.
            #   * For `daily_llm_cap_usd`, `per_evaluator_llm_cap_usd`,
            #     `score_outlier_sigma` and `vertex_max_rpm` 0 means DISABLED,
            #     exactly as their field help says - the guards are `if cap > 0`
            #     / `if sigma <= 0`, so a stored 0 turns the control OFF rather
            #     than restoring a default. They are named here so nobody reads
            #     "0 means use the module default" as a module-wide rule: a 0
            #     that reaches one of these four is the operator asking for no
            #     cap at all, and it is honoured.
            #
            # There is deliberately NO -1 sentinel to tell the two apart. It
            # would touch every `> 0` guard, both field helps, two Flutter
            # screens and the knowledge base, and would need a data migration
            # for every deployment already holding a considered value - all to
            # work around an Odoo core coercion that the `set_values` override
            # in `models/res_config_settings.py` now handles in one loop.
            if bounds and number and not (bounds[0] <= number <= bounds[1]):
                return fail(
                    "invalid",
                    "%s must be between %d and %d (or 0 for the default)."
                    % (short, *bounds),
                    status=422)
            pending.append((key, short, number))

        # Secrets validate in the same pass, so a bad one refuses the whole
        # payload rather than leaving half a credential rotated.
        secrets = []
        for key in self.SECRETS:
            short = key.split(".", 1)[1]
            value = arg(short, _MISSING)
            if value is _MISSING:
                continue
            if not isinstance(value, str):
                return fail("invalid", "%s must be text" % short, status=422)
            secrets.append((key, short, value.strip()))

        written = {}
        for key, short, value in pending:
            icp.set_param(key, value if isinstance(value, str) else str(value))
            # The Redis URL carries its password: like a secret, only whether
            # it is set goes back.
            written[short] = bool(value) if short == "redis_url" else value

        for key, short, value in secrets:
            # `set_secret` encrypts; an empty value is written through as an
            # empty parameter rather than encrypted, which is how a credential
            # gets deliberately removed.
            secret_store.set_secret(request.env, key, value)
            # The VALUE never goes back in the response. Only that it changed.
            written[short] = bool(value)

        return ok({"updated": written})

    @http.route("/api/v1/settings/service_account", type=API_TYPE,
                auth="user", methods=["POST"], csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def settings_service_account(self, **kw):
        """Replace the Vertex service-account JSON from an uploaded file.

        The counterpart of the `vertex_sa_upload` binary on the module's own
        settings form, which is the only place this could be done before: the
        API had no way to write a credential at all, so a deployment could be
        re-pointed at a new GCP project from the Odoo back office and from
        nowhere else.

        VALIDATED BEFORE IT IS STORED. A service-account JSON that does not
        parse, or that is some other kind of Google JSON (an OAuth client, a
        downloaded API key), is refused by name here rather than accepted and
        then failing later as an opaque 401 on the first generation run - at
        which point nothing on any screen says the file was the problem.

        Sending an empty `content` CLEARS the credential, so a rotated-out
        service account can be removed rather than only replaced.
        """
        raw = arg("content", "") or ""
        filename = (arg("filename", "") or "").strip()

        if not raw:
            secret_store.set_secret(
                request.env,
                "assessments_be_v2.vertex_service_account_json", "")
            request.env["ir.config_parameter"].sudo().set_param(
                "assessments_be_v2.vertex_service_account_filename", "")
            self._forget_minted_bearer()
            return ok({"cleared": True})

        # base64 like every other upload on this API, so the JSON rides in a
        # json2 envelope without quoting problems. Sized before it is decoded,
        # like the rest: a JSON key is ASCII, so bytes are characters.
        if len(raw) * 3 // 4 > _MAX_SETTING_CHARS:
            return fail("invalid",
                        "A service-account JSON is a few kilobytes; this is "
                        "about %d bytes." % (len(raw) * 3 // 4), status=422)
        try:
            text = base64.b64decode(raw).decode("utf-8")
        except (ValueError, binascii.Error, UnicodeDecodeError):
            return fail("invalid",
                        "That file is not UTF-8 text.", status=422)
        try:
            data = json.loads(text)
        except ValueError:
            return fail("invalid",
                        "That file is not valid JSON.", status=422)
        if not isinstance(data, dict):
            return fail("invalid",
                        "A service-account JSON is an object.", status=422)
        if data.get("type") != "service_account":
            kind = data.get("type") or "different kind of"
            return fail(
                "invalid",
                # "an authorized_user", not "a authorized_user". The type comes
                # out of the file, so the article cannot be baked into the
                # sentence - and this string is read by somebody who has just
                # picked the wrong download out of a folder, which is not the
                # moment to look sloppy about it.
                "That is %s %s file, not a service account. Download the key "
                "from IAM > Service Accounts > Keys."
                % ("an" if kind[:1].lower() in "aeiou" else "a", kind),
                status=422)
        missing = [f for f in ("client_email", "private_key", "project_id")
                   if not data.get(f)]
        if missing:
            return fail("invalid",
                        "This service-account JSON is missing %s."
                        % ", ".join(missing), status=422)

        icp = request.env["ir.config_parameter"].sudo()
        secret_store.set_secret(
            request.env,
            "assessments_be_v2.vertex_service_account_json", text)
        icp.set_param("assessments_be_v2.vertex_service_account_filename",
                      filename or "service-account.json")
        # The project the KEY belongs to, adopted only when nothing is set.
        # An operator who has deliberately pointed the module at a second
        # project keeps that choice; an empty one is filled in rather than
        # left for them to copy out of the file by hand.
        if not icp.get_param("assessments_be_v2.vertex_project_id"):
            icp.set_param("assessments_be_v2.vertex_project_id",
                          data["project_id"])
        self._forget_minted_bearer()

        return ok({
            "filename": filename or "service-account.json",
            "client_email": data["client_email"],
            "project_id": data["project_id"],
        })

    @staticmethod
    def _forget_minted_bearer():
        """Drop the cached OAuth bearer minted from the OLD key.

        A bearer outlives the key it was signed with by up to an hour, so
        without this a freshly uploaded service account appears to change
        nothing until the cache expires - and the operator, reasonably,
        concludes the upload did not take.
        """
        icp = request.env["ir.config_parameter"].sudo()
        icp.set_param("assessments_be_v2.vertex_minted_token", "")
        icp.set_param("assessments_be_v2.vertex_minted_token_expires", "")

    # ------------------------------------------------------------------
    # Exports
    # ------------------------------------------------------------------
    #
    # WHY BASE64 IN A JSON ENVELOPE
    # These routes are json2 like every other route here, so the CSV rides as
    # base64 under `content` - the same shape the generator resources already
    # use. Returning a redirect to an ir.attachment would work in a browser
    # and break every non-browser client, and it leaks a URL that outlives the
    # request. The client decodes and saves; nothing is persisted server-side.
    #
    # WHICH IS EXACTLY WHY THERE IS A CAP. The whole CSV is built in memory,
    # base64 inflates it by a third, and json.dumps copies it again - so one
    # request peaks at roughly three times the file. The service takes no
    # limit, and an assessment's answer count is a function of cohort size
    # times question count times the length of a written justification: none
    # of them bounded. Unbounded, a large export does not fail slowly, it
    # takes the worker out for every other request it was serving. A refusal
    # naming the size is recoverable; an OOM is not.

    def _export(self, fname, content):
        """Wrap a built CSV, refusing one too large to send safely.

        THE CEILING IS CHECKED AGAINST WHAT IS SENT, not against the raw file.
        The payload is base64 inside a JSON envelope, and base64 is 4/3 the
        size, so the bytes that cross the wire are ~1.37x the CSV. Checking the
        raw length let a 17 MB file pass a 20 MB limit and then ship 23.3 MB -
        which is not a refusal and not a download: the browser reports
        `ERR_CONTENT_LENGTH_MISMATCH`, the response having been cut short, and
        the client's own error text blames CORS because a truncated body and a
        refused origin look identical from there.

        Measured on real data (573 candidates x 35 questions = 20,055 answer
        rows, 888 bytes a row): 17.0 MB raw, 23.3 MB encoded. So the effective
        raw ceiling is MAX_EXPORT_BYTES * 3/4, and stating it that way is what
        makes the refusal honest - the operator is told the real limit rather
        than one the export can silently exceed.

        The message quotes the RAW size, because that is the number an operator
        can act on: it is the size of the file they asked for.
        """
        encoded = base64.b64encode(content)
        if len(encoded) > MAX_EXPORT_BYTES:
            # The raw size at which the ENCODED payload reaches the limit. Given
            # so the refusal names a target rather than only a verdict.
            raw_ceiling = (MAX_EXPORT_BYTES * 3) // 4
            return fail(
                "export_too_large",
                "This export is %.1f MB, over the %.1f MB limit for a single "
                "download. Export one candidate, or narrow the assessment."
                % (len(content) / 1048576.0, raw_ceiling / 1048576.0),
                status=413,
                bytes=len(content),
                encoded_bytes=len(encoded),
                limit=raw_ceiling)
        return ok({
            "filename": fname,
            "mimetype": "text/csv",
            "content": encoded.decode("ascii"),
        })

    @http.route("/api/v1/assessments/<int:assessment_id>/export/responses",
                type=API_TYPE, auth="user", methods=["GET", "POST"],
                csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def assessment_export_responses(self, assessment_id, **kw):
        """Every answer on this assessment, as CSV.

        The per-candidate scorecard rows are interleaved with their answers,
        exactly as the Odoo button produces them: same service, same columns.
        """
        record = request.env["assessments.be"].browse(
            assessment_id).exists()
        if not record:
            return fail("not_found", "Assessment not found", status=404)

        denied = record_read_guard(record)
        if denied:
            return denied

        # export_api, NOT export. `responses_csv`, `results_csv` and
        # `candidate_template_csv` all live in services/export_api.py;
        # services/export.py has `export_responses`/`export_results`,
        # which are a different shape. Every one of these four routes
        # imported the wrong module and answered 500 - the CSV exports
        # and the roster template have never worked from this API.
        from ...services import export_api as export_svc
        fname, content = export_svc.responses_csv(record)
        return self._export(fname, content)

    @http.route("/api/v1/assessments/<int:assessment_id>/export/results",
                type=API_TYPE, auth="user", methods=["GET", "POST"],
                csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def assessment_export_results(self, assessment_id, **kw):
        """The results sheet: one row per candidate, marks and verdict."""
        record = request.env["assessments.be"].browse(
            assessment_id).exists()
        if not record:
            return fail("not_found", "Assessment not found", status=404)

        denied = record_read_guard(record)
        if denied:
            return denied

        # export_api, NOT export. `responses_csv`, `results_csv` and
        # `candidate_template_csv` all live in services/export_api.py;
        # services/export.py has `export_responses`/`export_results`,
        # which are a different shape. Every one of these four routes
        # imported the wrong module and answered 500 - the CSV exports
        # and the roster template have never worked from this API.
        from ...services import export_api as export_svc
        fname, content = export_svc.results_csv(record)
        return self._export(fname, content)

    @http.route("/api/v1/attempts/<int:evaluator_id>/export/responses",
                type=API_TYPE, auth="user", methods=["GET", "POST"],
                csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def attempt_export_responses(self, evaluator_id, **kw):
        """One candidate's answers, as CSV."""
        record = request.env["assessments.be.evaluator"].browse(
            evaluator_id).exists()
        if not record:
            return fail("not_found", "No such attempt", status=404)

        denied = record_read_guard(record)
        if denied:
            return denied

        # export_api, NOT export. `responses_csv`, `results_csv` and
        # `candidate_template_csv` all live in services/export_api.py;
        # services/export.py has `export_responses`/`export_results`,
        # which are a different shape. Every one of these four routes
        # imported the wrong module and answered 500 - the CSV exports
        # and the roster template have never worked from this API.
        from ...services import export_api as export_svc
        fname, content = export_svc.responses_csv(
            record.assessment_id, evaluator=record)
        return self._export(fname, content)

    @http.route("/api/v1/candidates/template",
                type=API_TYPE, auth="user", methods=["GET", "POST"],
                csrf=False, cors="*")
    @api_endpoint
    @require_manager
    def candidate_import_template(self, **kw):
        """The CSV template the candidate importer expects.

        Not scoped to an assessment: the shape is the same everywhere, and
        making the caller name an assessment to learn the column headers would
        be arbitrary.
        """
        # export_api, NOT export. `responses_csv`, `results_csv` and
        # `candidate_template_csv` all live in services/export_api.py;
        # services/export.py has `export_responses`/`export_results`,
        # which are a different shape. Every one of these four routes
        # imported the wrong module and answered 500 - the CSV exports
        # and the roster template have never worked from this API.
        from ...services import export_api as export_svc
        fname, content = export_svc.candidate_template_csv()
        return ok({
            "filename": fname,
            "mimetype": "text/csv",
            "content": base64.b64encode(content).decode("ascii"),
        })

    @http.route("/api/v1/assessments/<int:assessment_id>/candidates/import",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def candidate_import_csv(self, assessment_id, **kw):
        """Upload a filled candidate CSV against one assessment.

        v2 handed out the template (`/api/v1/candidates/template`) but had no
        route to send one back, so a roster could only be built one applicant at
        a time - pro's importer was reachable from the Odoo form and nowhere
        else. The parsing, provisioning and roster sync are the MODEL's
        `action_import_candidates_csv`, unchanged: this only carries the bytes
        in and reports what it did.
        """
        assessment = request.env["assessments.be"].browse(assessment_id)
        assessment.check_access("write")
        payload = kw.get("content") or kw.get("file") or kw.get("csv")
        if not payload:
            return fail("invalid", "Send the CSV as base64 in `content`.",
                        status=400)
        refused = _too_large(payload, limit=_MAX_CANDIDATE_CSV_BYTES)
        if refused:
            return refused
        filename = kw.get("filename") or "candidates.csv"
        before = len(assessment.assessment_evaluator_ids)
        assessment.sudo().write({
            "candidate_csv_file": payload,
            "candidate_csv_filename": filename,
        })
        try:
            action = assessment.sudo().action_import_candidates_csv()
        except UserError as exc:
            # The importer raises UserError for a bad file (wrong columns,
            # oversized, undecodable, a bad row). That is caller error, not a
            # 500. `fail(code, message)`: this passed the message as the code,
            # so the app showed "400" instead of which rows were wrong. A
            # returned failure is committed, so the staged file is dropped too.
            request.env.cr.rollback()
            return fail("invalid", str(exc), status=400)
        note = ""
        if isinstance(action, dict):
            note = ((action.get("params") or {}).get("message")
                    or action.get("message") or "")
        assessment.invalidate_recordset()
        rows = assessment.assessment_evaluator_ids
        return ok({
            "assessment_id": assessment.id,
            "roster_before": before,
            "roster_after": len(rows),
            "added": len(rows) - before,
            "message": note,
            "candidates": [
                {"id": e.applicant_id.id,
                 "name": e.applicant_id.partner_name or "",
                 "email": e.candidate_email or "",
                 "state": e.state}
                for e in rows
            ],
        })

    # Chatter

    #: Same allow-list as the read side. A free `model` parameter would turn
    #: this into a write primitive against every table in the database.
    CHATTER_MODELS = {
        "assessment": "assessments.be",
        "generator": "assessments.be.prompt",
        "attempt": "assessments.be.evaluator",
    }

    @http.route("/api/v1/chatter/<string:kind>/<int:record_id>/post",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_staff
    def chatter_post(self, kind, record_id, **kw):
        """Post a message or log an internal note on a record.

        The read route existed from the start, so an operator could see the
        audit trail but never add to it - every comment had to be made in Odoo,
        which defeats the point of a standalone console.

        `note` (the default) writes `mail.mt_note`: internal, no subscriber
        email. `message` writes `mail.mt_comment`, which notifies followers -
        the same distinction Odoo's own "Log note" / "Send message" buttons
        make, and the reason the kind is explicit rather than inferred.
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
        # `browse().exists()` is a bare SELECT id: it enforces no ACL and no
        # ir.rule, and `message_post` below runs as the record's own thread
        # helper. Without this an Evaluator could append to - and so read the
        # id of - any assessment or generator their record rule hides.
        denied = record_read_guard(record)
        if denied:
            return denied

        # Not every record with a readable history can ACCEPT one.
        #
        # `assessments.be.evaluator` (an attempt) does not inherit
        # mail.thread: Odoo writes messages against it directly, so the read
        # route returns a real trail, but `message_post` does not exist and the
        # call died with a 500. Refusing here with a sentence beats a stack
        # trace, and beats a "Log note" button that always fails.
        if not hasattr(record, "message_post"):
            article = "An" if kind[:1].lower() in "aeiou" else "A"
            return fail(
                "not_supported",
                "%s %s keeps a history but cannot take new notes. Comment on "
                "the assessment instead." % (article, kind),
                status=422)

        body = (kw.get("body") or "").strip()
        if not body:
            return fail("bad_request", "A message needs a body.", status=400)

        # `post_kind`, NOT `kind`: the route already binds `<string:kind>` to the
        # RECORD kind, so a body field of the same name is swallowed by the path
        # param and never reaches `kw`. A probe sending kind="shout" was
        # accepted with a 200 and silently logged a note - an unread key is
        # silence, never a 400.
        post_kind = (kw.get("post_kind") or "note").strip()
        if post_kind not in ("note", "message"):
            return fail("bad_request",
                        "post_kind must be 'note' or 'message'.", status=400)
        subtype = "mail.mt_note" if post_kind == "note" else "mail.mt_comment"

        # Plain text in, escaped on the way to a HTML body field: a body that
        # renders whatever an operator typed is a stored-XSS hole on every
        # surface that displays the chatter, Odoo's included.
        safe = html_escape(body).replace("\n", "<br/>")

        # ATTACHMENTS. `message_post` takes [(filename, bytes)] and files them
        # against the message, which is what makes them show in Odoo's own
        # chatter as well - the two surfaces then agree, rather than this app
        # inventing a parallel notion of "attached".
        #
        # Each file is decoded here so a malformed upload is a 400 naming the
        # file, rather than a 500 from deep inside mail.thread.
        #
        # COUNTED AND SIZED BEFORE ANYTHING IS DECODED. The count used to run
        # after each decode and there was no size limit at all, so one request
        # could make the worker decode an unbounded pile of base64 in memory.
        pending = []
        for row in (arg("attachments") or []):
            if not isinstance(row, dict):
                continue
            name = str(row.get("name") or "attachment").strip()
            raw = str(row.get("content") or "")
            if raw.startswith("data:"):
                _, _, raw = raw.partition(",")
            if raw:
                pending.append((name, raw))
        if len(pending) > 10:
            return fail("too_many",
                        "Attach at most 10 files to one note.", status=422)
        files = []
        for name, raw in pending:
            refused = _too_large(raw, repr(name))
            if refused:
                return refused
            try:
                files.append((name, base64.b64decode(raw, validate=True)))
            except (ValueError, binascii.Error):
                return fail("bad_attachment",
                            "%r is not valid base64." % name, status=400)

        message = record.message_post(
            body=safe,
            subtype_xmlid=subtype,
            message_type="comment",
            attachments=files or None,
        )
        return ok(S.chatter_row(message))

    # Bank question media authoring

    @http.route("/api/v1/bank/<int:question_id>/studio_item/save",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def bank_studio_item_save(self, question_id, **kw):
        """Save an edited annotation item back onto the question it came from.

        THE OTHER HALF OF `.../studio_item`. That route hands the question to
        the annotation editor; this one takes the examiner's edits back. Its
        OWN PATH rather than POST on the read one, because the client posts
        every call it makes - a method split would turn "open the editor" into
        "rewrite the answer key".

        IN PLACE, per the product decision: no new Studio form and no second
        assessment. A corrected question that lived in a fresh record would
        leave the paper being fixed exactly as broken as it was, with the good
        version attached to nothing anybody sits.

        `require_manager` where the GET is `require_staff` - reading a key to
        review it and rewriting one a candidate is graded against are different
        privileges, and this rewrites the key.

        RETROACTIVE, like `bank_update`, and safe in the same way: a labelling
        answer is free text scored against `ideal_labels`, so correcting the key
        re-decides those answers on the next grade rather than orphaning an
        option row a response points at. That is the intended behaviour - it is
        why a wrong box is worth being able to move at all.
        """
        record = request.env["assessments.be.question"].with_context(
            active_test=False).browse(question_id).exists()
        if not record:
            return fail("not_found", "Question not found", status=404)
        _refuse_if_deleted(record)

        denied = record_read_guard(record)
        if denied:
            return denied

        item = arg("item")
        if not isinstance(item, dict):
            return fail("invalid", "item must be the edited annotation item",
                        status=422)

        problems = record.apply_studio_annotation_item(item)
        if problems:
            # 422, not 409: every refusal this can produce is something wrong
            # with the submitted item (no markers, an unkeyed point), which the
            # examiner fixes in the editor and sends again.
            return fail("refused", " ".join(problems), status=422)
        record.flush_recordset()
        return ok(S.bank_question_detail(record))

    @http.route("/api/v1/bank/<int:question_id>/detect",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def bank_question_detect(self, question_id, **kw):
        """Re-run UI element detection on a labelling question's image.

        Calls the image record's own action so the attempt counter, the
        annotated copy and the failure ceiling all behave exactly as they do
        in the backend. A UserError from that action is a refusal the operator
        needs to read, so it is surfaced as a 422 rather than a 500.
        """
        record = request.env["assessments.be.question"].browse(
            question_id).exists()
        if not record:
            return fail("not_found", "Question not found", status=404)
        _refuse_if_deleted(record)

        target = record.image_ids.filtered(lambda i: i.slot == "single")[:1]
        if not target:
            return fail("no_image",
                        "This question has no single-slot image to detect on.",
                        status=422)
        try:
            target.action_detect_now()
        except UserError as exc:
            return fail("refused", str(exc), status=422)
        return ok(S.bank_question_detail(record))

    @http.route("/api/v1/bank/<int:question_id>/capture",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def bank_question_capture(self, question_id, **kw):
        """Capture the live DOM at the image's source URL into a screenshot.

        ``source_url`` may be supplied to set it before capturing, which is
        the common case: the operator is pointing the question at a page.
        """
        record = request.env["assessments.be.question"].browse(
            question_id).exists()
        if not record:
            return fail("not_found", "Question not found", status=404)
        _refuse_if_deleted(record)

        target = record.image_ids.filtered(lambda i: i.slot == "single")[:1]
        if not target:
            return fail("no_image",
                        "This question has no single-slot image to capture "
                        "into.", status=422)

        url = str_arg("source_url", "").strip()
        if url:
            target.source_url = url
        try:
            target.action_capture_url()
        except UserError as exc:
            return fail("refused", str(exc), status=422)
        return ok(S.bank_question_detail(record))

    @http.route("/api/v1/bank/<int:question_id>/video",
                type=API_TYPE, auth="user", methods=["POST"], csrf=False,
                cors="*")
    @api_endpoint
    @require_manager
    def bank_question_apply_video(self, question_id, **kw):
        """Attach an uploaded clip to a slot on a bank question.

        Mirrors the backend's Upload Clip group: the binary is ingested to S3
        when configured and kept inline otherwise, and an existing clip in the
        same slot is replaced rather than duplicated.
        """
        record = request.env["assessments.be.question"].browse(
            question_id).exists()
        if not record:
            return fail("not_found", "Question not found", status=404)
        _refuse_if_deleted(record)

        content = str_arg("content", "")
        if not content:
            return fail("invalid", "content is required", status=422)
        # Accept a data URL as well as bare base64: a browser FileReader
        # produces the former, and silently storing the `data:...;base64,`
        # prefix as part of the payload corrupts the file.
        if content.startswith("data:"):
            _, _, content = content.partition(",")
        refused = _too_large(content, "That clip")
        if refused:
            return refused
        try:
            base64.b64decode(content, validate=True)
        except (binascii.Error, ValueError):
            return fail("invalid", "content is not valid base64", status=422)

        slot = (str_arg("slot", "reference") or "reference").strip().lower()
        record.upload_video = content
        record.upload_video_filename = str_arg("filename", "clip.mp4")
        record.upload_video_slot = slot
        try:
            record.action_apply_uploaded_video()
        except UserError as exc:
            return fail("refused", str(exc), status=422)
        return ok(S.bank_question_detail(record))
