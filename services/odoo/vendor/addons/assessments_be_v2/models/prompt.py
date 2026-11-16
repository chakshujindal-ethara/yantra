import json
import logging
from datetime import timedelta

from markupsafe import Markup, escape

from odoo import models, fields, api, _
from odoo.exceptions import AccessError, UserError, ValidationError

from ..constants import (
    QUESTION_TYPE_SELECTION, DIFFICULTY_SELECTION, IMAGE_QUESTION_TYPES,
    VIDEO_QUESTION_TYPES, DETECTION_MODE_SELECTION, IMAGE_RENDER_BATCH,
    NON_GENERATABLE_QUESTION_TYPES, DEFAULT_IMAGE_LABEL_COUNT,
    option_name_reveals_reasoning, text_has_source_reference,
    ADVISORY_LOCK_SKILL_EXTRACT, ADVISORY_LOCK_QUESTION_GEN,
    ADVISORY_LOCK_IMAGE_RENDER, ADVISORY_LOCK_TAG_EXTRACT,
    ADVISORY_LOCK_VIDEO_POLL,
    ab_construction_keys, ab_materialized_keys, ab_key_drift,
    ab_specs_from_construction_keys,
    parse_flaw_plan,
    parse_task_registry,
    parse_shape_quotas,
    effective_generation_count,
    takes_one_answer,
)
from ..services import similarity
from ..services.locks import cron_lock
from .simple_import import upload_text

_logger = logging.getLogger(__name__)

_SOP_GEN_FINALIZE_MAX_ATTEMPTS = 5

_TAG_EXTRACT_FINALIZE_MAX_ATTEMPTS = 5


def _preview_src_ok(src):
    """L-2: allow only safe image sources in admin-preview markup — http(s), our
    own relative controller paths (/...), or image data: URLs. Rejects
    javascript:/vbscript:/data-non-image and other schemes so an LLM- or
    admin-supplied spec can never inject an active-content URL, even if this
    markup is later refactored from <img src> to an href-bearing tag."""
    s = str(src or "").strip()
    if not s:
        return False
    low = s.lower()
    if low.startswith(("http://", "https://", "/")):
        return True
    if low.startswith("data:image/"):
        return True
    return False

_VIDEO_OP_MAX_ATTEMPTS = 3

# Postgres errors that mean "try again", NOT "this work failed". A cron that
# catches them alongside real errors will brand a perfectly healthy draft as a
# video failure - seen live: both Veo ops came back 'done' with clips staged,
# yet the draft was left showing "Could not check the clip generation status:
# could not serialize access due to concurrent update". Reuse Odoo's own list
# so we stay in step with what the framework itself considers retryable, plus
# the rest of the 40xxx "transaction rolled back" class the grading lanes
# already retry (`models/assessment.py`).
from psycopg2.errors import TransactionRollbackError as _TxRollback
try:
    from odoo.service.model import PG_CONCURRENCY_EXCEPTIONS_TO_RETRY as \
        _PG_RETRY
except ImportError:  # pragma: no cover - defensive, older/newer odoo layout
    from psycopg2 import errors as _pg_errors
    _PG_RETRY = (_pg_errors.SerializationFailure,
                 _pg_errors.DeadlockDetected,
                 _pg_errors.LockNotAvailable)
_TRANSIENT_DB_ERRORS = tuple(_PG_RETRY) + (_TxRollback,)

# What each draft's render wrote, by (database, draft id), so a lost commit can
# be written again instead of paid for again (`_cron_render_pending_images`).
# ponytail: process-local; lost with the worker, as before.
_STAGED_RENDERS = {}


def _warn_lost_race(record, what, exc):
    """WARNING for a cron that lost a transient DB race on ``record`` and left
    it for the next tick, naming the OTHER writer.

    Read on a fresh cursor, and read only: the cron's own was just rolled back,
    and `write_date` / `write_uid` are the only trace of who else wrote the
    row, which is what the next occurrence needs to be fixed at its source.
    """
    try:
        with record.env.registry.cursor() as cr:
            cr.execute(
                'SELECT write_date, write_uid FROM "%s" WHERE id = %%s'
                % record._table, (record.id,))
            write_date, write_uid = cr.fetchone() or (None, None)
    except Exception as read_exc:  # noqa: BLE001 - diagnostics only
        write_date = write_uid = "unreadable (%s)" % read_exc
    _logger.warning(
        "%s %s hit %s; left for the next tick, no attempt burned. The row "
        "was last written at %s by write_uid=%s.",
        what, record.id, type(exc).__name__, write_date, write_uid)


class EtpAssessmentPrompt(models.Model):
    _name = "assessments.be.prompt"
    _description = "Assessment Prompt (LLM Skill/Question Generator)"
    _inherit = ["mail.thread"]
    _order = "create_date desc"

    @api.ondelete(at_uninstall=False)
    def _unlink_except_used_by_assessment(self):
        """Name the blocker in one line instead of Postgres' generic dialog.

        ``assessments.be.generator_id`` is ondelete='restrict', so the raw
        failure reads "Another model is using the record you are trying to
        delete... 'Assessment' (assessments.be)" - it names the REFERRING
        model, never the generator the user actually clicked, and its
        "How about archiving?" hint used to be impossible because there was no
        active field. Both are fixed here.
        """
        Assessment = self.env["assessments.be"].sudo()
        used = Assessment.with_context(active_test=False).search([
            ("generator_id", "in", self.ids)])
        if not used:
            return
        raise UserError(_(
            "Cannot delete %(gen)s - used by assessment %(who)s. Archive it "
            "instead.",
            gen=", ".join((used.generator_id & self).mapped("name")[:3]),
            who=", ".join(used.mapped("name")[:3])))

    def _log_activity(self, body):
        """Post a timestamped audit line to each generator's chatter.

        message_post already stamps the author + date, so this is the single
        choke-point every user action routes through to keep the log uniform.
        Best-effort: an audit note must never sink the action that triggered it.
        """
        for rec in self:
            if not rec.id:
                continue
            try:
                rec.message_post(body=body, message_type="comment",
                                 subtype_xmlid="mail.mt_note")
            except Exception:  # noqa: BLE001 - logging is never load-bearing
                _logger.exception(
                    "Chatter audit post failed for generator %s", rec.id)

    name = fields.Char(string="Title", default="New Prompt", required=True)
    active = fields.Boolean(
        default=True,
        help="Untick to ARCHIVE this generator: it disappears from the "
             "default list but its drafts, questions and history are kept. "
             "Archiving is the safe alternative to deleting - a generator an "
             "assessment has already used cannot be deleted, because that "
             "would orphan the candidate results.")
    # DELETED, NOT ERASED: Delete on a generator an assessment uses. The row
    # has to stay (`assessment.generator_id` is ondelete="restrict"), so it is
    # marked here - inactive, out of Archived, never restorable - and its
    # papers, answers and scores are untouched. See `deleted` on the question.
    deleted = fields.Boolean(
        string="Deleted", default=False, index=True, copy=False,
        help="Deleted for good. Assessments built from it keep it, with "
             "every answer and score; it cannot be restored.")
    source_text = fields.Text(string="Additional Notes (optional)")
    @api.constrains("active", "deleted")
    def _check_deleted_stays_inactive(self):
        if self.filtered(lambda g: g.deleted and g.active):
            raise ValidationError(_("A deleted generator cannot be restored."))

    resource_ids = fields.One2many(
        "assessments.be.prompt.resource", "prompt_id",
        string="SOP / Resource Files",
    )
    reference_resource_ids = fields.One2many(
        "assessments.be.prompt.resource", "prompt_id",
        domain=[("category", "=", "reference")],
        string="Reference Files",
    )
    # Must stay computed: a sibling domain One2many cannot see the rows
    # _add_resource() appends to resource_ids until the record is saved.
    sop_resource_ids = fields.Many2many(
        "assessments.be.prompt.resource",
        compute="_compute_sop_resource_ids",
        string="SOP File(s)",
    )
    resource_count = fields.Integer(compute="_compute_resource_count")

    question_ids = fields.One2many(
        "assessments.be.prompt.question", "prompt_id", string="Draft Questions"
    )
    #: THE ONES STILL AWAITING A DECISION, which is what the "Question
    #: Drafts" tab lists: Approve Selected / Deny Selected act only on
    #: `state == 'draft'`, so decided rows do not belong under them.
    draft_question_ids = fields.One2many(
        "assessments.be.prompt.question", "prompt_id",
        string="Questions Awaiting Review",
        domain=[("state", "=", "draft")])
    state = fields.Selection(
        [
            ("draft", "Draft"),
            ("skills_ready", "Tags Extracted"),
            ("generating", "Generating"),
            ("done", "Done"),
        ],
        default="draft",
    )
    question_count = fields.Integer(compute="_compute_counts")
    approved_count = fields.Integer(compute="_compute_counts")
    draft_count = fields.Integer(
        compute="_compute_counts", string="Awaiting Review",
        help="Generated questions still in 'draft' - the ones the review "
             "banner and the Question Drafts tab are about.")
    effective_question_count = fields.Integer(
        string="This Run Will Generate",
        compute="_compute_effective_question_count",
        help="How many questions this run actually asks the model for, from "
             "the same function generation uses. It can exceed 'Questions to "
             "Generate': every allowed question type with no count of its own "
             "still earns one item, and the per-shape counts are a floor.")
    effective_question_label = fields.Char(
        compute="_compute_effective_question_count")
    last_extract_summary = fields.Char(readonly=True)
    sop_gen_state = fields.Selection(
        [("idle", "Idle"), ("queued", "Queued"), ("generating", "Generating"),
         ("finalizing", "Finalizing"),
         ("done", "Done"), ("failed", "Failed"),
         ("cancelled", "Cancelled")],
        default="idle", copy=False, string="SOP Generation",
        help="The SOP document is sent natively to the "
             "multimodal model which authors questions directly per the format "
             "in the SOP. Runs in the background (a cron does the slow call off "
             "the web request). 'finalizing' means the drafts are committed and "
             "only the status write remains — a killed worker resumes WITHOUT "
             "re-calling Vertex. 'cancelled' means an admin stopped the run; "
             "whatever drafts it had already written are kept.")
    sop_gen_error = fields.Char(
        string="SOP Generation Error", readonly=True, copy=False)
    # THE LATEST RUN'S WINDOW. Started is stamped when the cron picks the run
    # up; finished on every terminal state (done, failed, cancelled). The
    # progress route scopes this run's drafts and ledger rows by `started`.
    # NULL on runs from before these existed - no elapsed time, no run stats.
    sop_gen_started_at = fields.Datetime(
        string="Generation Started", readonly=True, copy=False)
    sop_gen_finished_at = fields.Datetime(
        string="Generation Finished", readonly=True, copy=False)

    # ── The kill switch ─────────────────────────────────────────────────────
    #
    # THERE IS NO PROCESS TO KILL. Generation runs inside an Odoo cron worker
    # (see `_cron_generate_from_sop`), not a thread or a job this request can
    # signal, so cancellation is COOPERATIVE: the API worker sets this flag and
    # commits, and the lanes that spend money read it back before each call and
    # stop. `services/vertex._check_cancelled` is the checkpoint, and it reads
    # this column on a FRESH cursor precisely because the cron worker's own
    # snapshot predates the commit that set it.
    #
    # WHAT IT CANNOT DO: the single Vertex request already in flight when Kill
    # is pressed completes and is billed (httpx read timeout is 180s). Every
    # call after it is refused. That is the honest boundary of this feature.
    sop_gen_cancel_requested = fields.Boolean(
        string="Cancellation Requested", default=False, copy=False,
        help="Set by Kill. Every LLM lane belonging to THIS generator refuses "
             "its next call while this is on, so a run stops spending within "
             "one call rather than at the end of the batch.")
    sop_gen_cancelled_at = fields.Datetime(
        string="Cancelled At", readonly=True, copy=False)
    sop_gen_report = fields.Char(
        string="Last Generation Result", readonly=True, copy=False,
        help="What the last run actually did: drafts created, items rejected "
             "and why. A run can succeed technically and yield nothing - the "
             "model returns items and validation throws them all out - and "
             "without this the only record of that was a server log line.")
    tag_ids = fields.Many2many("assessments.be.tag", string="SOP Tags")
    tag_extract_state = fields.Selection(
        [("idle", "Idle"), ("queued", "Queued"), ("generating", "Generating"),
         ("done", "Done"), ("failed", "Failed"),
         ("cancelled", "Cancelled")],
        default="idle", copy=False, string="Tag Extraction",
        help="Semantic tags characterizing the SOP's task are extracted by the "
             "LLM in the background (a cron does the slow call off the web "
             "request), mirroring SOP generation.")
    tag_extract_error = fields.Char(
        string="Tag Extraction Error", readonly=True, copy=False)
    # KILL for Extract skills (owner, 2026-09-29). Cooperative, like
    # `sop_gen_cancel_requested`: the one model call already on the wire
    # finishes and is billed, but its reply is not applied.
    tag_extract_cancel_requested = fields.Boolean(
        string="Tag Extraction Stop Requested", default=False, copy=False)
    # STOP for Draft from SOP, which runs inside the web request: a draft
    # started before this moment makes no further model call and its result
    # is refused. A timestamp, not a flag, so the draft request never has to
    # write this row (the cancel request would then race it).
    template_draft_cancelled_at = fields.Datetime(
        string="Template Draft Stopped At", readonly=True, copy=False)
    tag_extract_last_run = fields.Datetime(
        string="Tags Last Extracted", readonly=True, copy=False,
        help="When Extract Tags last completed. A re-run ends on 'Done' exactly "
             "as it started - without this timestamp the screen looked "
             "identical and the admin could not tell whether pressing the "
             "button again had done anything.")
    tags_json = fields.Text(
        string="Tags (raw LLM output)", readonly=True, copy=False,
        help="Raw JSON array returned by the tag-extraction call, kept for "
             "debugging; the canonicalized tags live in tag_ids.")
    # A PAID REPLY NOT YET FINALIZED, committed the moment Vertex answers
    # (`_keep_tag_reply`), so a finalize that loses every retry is finished on
    # the next tick from this instead of being paid for again. Cleared by the
    # finalize and by a new Extract Tags; NULL otherwise.
    tag_extract_reply = fields.Text(readonly=True, copy=False)
    metadata_json = fields.Text(
        string="SOP Metadata (research schema)", readonly=True, copy=False,
        help="The full grounded metadata object research's seed prompt emits: "
             "sop_title, summary, mapping, tags, skills, evidence, "
             "required_elements, covered_by_all, question_spec, gaps.")
    plain_tags = fields.Char(
        string="Plain Tags", readonly=True, copy=False,
        help="The 3-4 unprefixed defining-trait tags (research 'tags' artifact), "
             "distinct from the faceted mapping stored in tag_ids.")
    rating_scheme_json = fields.Text(
        string="SOP Rating Scheme (JSON)", readonly=True, copy=False,
        help="The rating scheme THIS SOP prescribes for comparison/choice "
             "questions: the exact dimensions a worker judges and the exact "
             "answer options each one offers, captured verbatim from the SOP "
             "during tag extraction. Question generation reads this so an "
             "A/B or multiple-choice item shows the SOP's OWN labels and "
             "options (e.g. 'Q1 Instruction Following' with YES/NO) instead "
             "of a generic Response A/B scale.")
    required_elements_json = fields.Text(
        string="Required Elements (JSON)", readonly=True, copy=False,
        help="Atomic yes/no SOP requirements [{id,statement,evidence}] the "
             "questions cover; load-bearing for scoring SOP-Coverage.")
    covered_by_all_json = fields.Text(
        string="Covered By All (JSON)", readonly=True, copy=False,
        help="Required-element ids every question exercises (the coverage "
             "baseline unioned with each question's covers_elements).")
    sop_title = fields.Char(
        string="SOP Title", readonly=True, copy=False,
        help="The project title the SOP intake recovered (metadata.sop_title).")
    sop_summary = fields.Text(
        string="SOP Summary", readonly=True, copy=False,
        help="Two or three plain sentences on what workers do (metadata.summary).")
    mapping_json = fields.Text(
        string="Faceted Mapping (JSON)", readonly=True, copy=False,
        help="The full faceted profile [facet:value] the intake extracted; "
             "reconciled into tag_ids so it drives the weighted-Jaccard ranking.")
    skills_json = fields.Text(
        string="Skills Registry (JSON)", readonly=True, copy=False,
        help="[{id,name,weight 1-5,evidence}] - the SOP's skills and their "
             "centrality weight, kept for ranking and reporting.")
    evidence_json = fields.Text(
        string="Evidence (JSON)", readonly=True, copy=False,
        help="[{id,quote,supports}] verbatim SOP quotes grounding every value. "
             "The audit trail proving each artifact traces to the SOP.")
    question_spec_json = fields.Text(
        string="Question Spec (JSON)", readonly=True, copy=False,
        help="The answer-field contract the intake derived (answer_type, "
             "answer_fields, assets_per_question, solution_shape, uses).")
    tasks_json = fields.Text(
        string="Task Registry (JSON)", readonly=True, copy=False,
        help="EVERY distinct task this SOP defines, primary first: "
             "[{key, display, one_sentence, subject_inputs, worker_output, "
             "answer_contract:{response, dimensions:[{label,options,evidence}], "
             "assets_per_question, justification, solution_shape}, evidence}]. "
             "This is what lets the platform assess a task shape it has never "
             "seen before: generation reads each task's OWN answer contract - "
             "including the SOP's own dimension labels and per-axis options - "
             "instead of forcing every item onto a generic Response A/B scale. "
             "canonical_task stays the PRIMARY entry and still drives ranking "
             "and the single task tag.")
    task_count = fields.Integer(
        string="Tasks Found", compute="_compute_task_count", store=True,
        help="How many distinct tasks the SOP defines. 1 for a single-task SOP; "
             "more when the SOP teaches several different jobs.")
    shape_quota_json = fields.Text(
        string="Per-Shape Counts (JSON)", copy=False,
        help="What the examiner asked for, per shape: "
             "{\"mcq\": 2, \"subjective_rubric\": 3, \"template:7\": 2}. A key is "
             "either a question type or a saved task template. Generation treats "
             "these as a FLOOR - the requested total rises to their sum rather "
             "than silently dropping one of the examiner's choices - and reports "
             "any shape it could not fill instead of padding with another shape.")
    sop_examples_json = fields.Text(
        string="SOP Examples (JSON)", readonly=True, copy=False,
        help="Examples mined from the SOP itself (worked example, sample "
             "response), the primary form/difficulty reference.")
    quality_criteria_json = fields.Text(
        string="Quality Criteria (JSON)", readonly=True, copy=False)
    failure_modes_json = fields.Text(
        string="Common Failure Modes (JSON)", readonly=True, copy=False)
    gaps_json = fields.Text(
        string="Gaps (JSON)", readonly=True, copy=False,
        help="Honesty log: rules that gave way on a thin SOP, silent fields.")
    conflicts_json = fields.Text(
        string="Conflicts (JSON)", readonly=True, copy=False,
        help="Recorded SOP-vs-example conflicts (never silently merged).")
    injection_flags_json = fields.Text(
        string="Injection Flags (JSON)", readonly=True, copy=False,
        help="SOP passages that tried to address the compiler as instructions.")
    similar_count = fields.Integer(
        string="Similar Generators", compute="_compute_similar_count",
        help="How many OTHER generators share enough weighted tags with this "
             "one to count as similar (shared-tag weight over the configured "
             "threshold). Drives the 'Similar' smart button.")
    # sanitize=False keeps the width:NN% inline style; every dynamic string in
    # _compute_similar_html MUST stay escape()d.
    similar_html = fields.Html(
        string="Similar Projects", sanitize=False, readonly=True,
        compute="_compute_similar_html",
        help="A ranked, presentation-only view of _similar_prompts(): how "
             "closely this SOP aligns with previous generators by weighted "
             "tag overlap, with an alignment % bar and the shared tags.")
    similarity_source_ids = fields.One2many(
        "assessments.be.similarity", "source_id",
        string="Similarity Rows",
        help="The persisted directed similarity pairs computed FROM this "
             "generator (source -> every other target): the same lexical / "
             "semantic / blended numbers as the ranking panel above, in a "
             "sortable, exportable grid. Populated by Compute (free) / "
             "Compute with AI.")
    # Do not remove: dropping the field drops its DB column (user data).
    sample_questions = fields.Text(
        string="Sample Questions (legacy text)",
        help="Deprecated: replaced by the Sample Questions file upload.")
    sample_questions_file = fields.Binary(
        string="Sample Questions File", attachment=True,
        help="Upload a sample-questions file (PDF/DOCX/MD/image) to match the "
             "format - optional. Sent natively to the model so images inside the "
             "file are read too. Leave empty to follow the format inside the SOP.")
    sample_questions_filename = fields.Char(string="Sample Questions Filename")
    sop_question_count = fields.Integer(
        string="Questions to Generate", default=0,
        help="0 = let the model decide from the SOP; otherwise a target count.")
    question_count_mode = fields.Selection(
        [("auto", "Auto - model decides"), ("fixed", "Set a number")],
        string="Questions to generate",
        compute="_compute_question_count_mode",
        inverse="_inverse_question_count_mode")
    image_label_count = fields.Integer(
        string="Image Labelling Count", default=DEFAULT_IMAGE_LABEL_COUNT,
        help="Maximum number of image label counts to allow in a question.")
    # OFF BY DEFAULT (owner, 2026-09-29): labelling pictures are AI-made unless a
    # project asks for real website screenshots (High Res Dense does).
    image_label_live_capture = fields.Boolean(
        string="Screenshot live websites", default=False,
        help="Image labelling questions use a screenshot of a real public "
             "website instead of an AI-made picture. If the page cannot be "
             "captured, an AI-made picture is used and the draft says so.")
    # Do not remove: dropping the field drops its DB column (user data), and the
    # 19.0.1.103.0 post-migrate reads it to seed allowed_question_type_ids.
    force_question_type = fields.Selection(
        QUESTION_TYPE_SELECTION, string="Force Question Type (legacy)",
        help="Deprecated: replaced by the Generate Only These Types allow-list.")
    allowed_question_type_ids = fields.Many2many(
        "assessments.be.question.type",
        relation="assessments_be_prompt_allowed_qtype_rel",
        column1="prompt_id", column2="qtype_id",
        string="Generate only these types",
        help="Allow-list: the generator may author ONLY these question types, "
             "choosing the best fit per item. Leave empty to let the model "
             "choose freely per the SOP.")
    select_all_types = fields.Boolean(
        string="Select all types", copy=False,
        help="Tick to load every question type at once; it resets immediately.")
    types_all_selected = fields.Boolean(compute="_compute_types_all_selected")
    quick_upload_file = fields.Binary(string="Upload SOP / Doc")
    quick_upload_filename = fields.Char()
    upload_sop_file = fields.Binary(string="Upload SOP")
    upload_sop_filename = fields.Char()
    upload_vendor_file = fields.Binary(string="Upload Vendor Doc")
    upload_vendor_filename = fields.Char()
    upload_client_file = fields.Binary(string="Upload Client Doc")
    upload_client_filename = fields.Char()
    upload_reference_file = fields.Binary(string="Upload Reference")
    upload_reference_filename = fields.Char()
    upload_sample_file = fields.Binary(string="Upload Sample Questions")
    upload_sample_filename = fields.Char()
    # The Skills & Templates tab's upload into the ONE sample-questions list
    # (golden questions are sample questions): it creates a `sample` resource,
    # exactly as `upload_sample_file` does.
    upload_golden_file = fields.Binary(
        string="Upload Sample Questions (Skills tab)")
    upload_golden_filename = fields.Char()
    # THIS generator's question templates, for the Skills & Templates page. A
    # plain One2many over the existing `origin_prompt_id` - no column.
    task_template_ids = fields.One2many(
        "assessments.be.task.template", "origin_prompt_id",
        string="Question Templates")
    has_sop_resource = fields.Boolean(
        string="Has SOP", compute="_compute_has_sop_resource",
        help="True once at least one SOP document is attached. Drives the "
             "mandatory-SOP indicator: the upload stays required until a SOP "
             "resource exists (the upload field itself clears after each file, "
             "so the requirement tracks the resource, not the transient field).")

    def _add_resource(self, data, filename, category):
        if not data:
            return
        self.resource_ids = [(0, 0, {
            "name": filename or "uploaded-file",
            "file": data,
            "category": category,
        })]

    @api.onchange("quick_upload_file")
    def _onchange_quick_upload_file(self):
        self._add_resource(
            self.quick_upload_file, self.quick_upload_filename, "other",
        )
        self.quick_upload_file = False
        self.quick_upload_filename = False

    @api.onchange("upload_sop_file")
    def _onchange_upload_sop(self):
        self._add_resource(
            self.upload_sop_file, self.upload_sop_filename, "sop",
        )
        self.upload_sop_file = False
        self.upload_sop_filename = False

    @api.onchange("upload_vendor_file")
    def _onchange_upload_vendor(self):
        self._add_resource(
            self.upload_vendor_file, self.upload_vendor_filename, "vendor",
        )
        self.upload_vendor_file = False
        self.upload_vendor_filename = False

    @api.onchange("upload_client_file")
    def _onchange_upload_client(self):
        self._add_resource(
            self.upload_client_file, self.upload_client_filename, "client",
        )
        self.upload_client_file = False
        self.upload_client_filename = False

    @api.onchange("upload_reference_file")
    def _onchange_upload_reference(self):
        self._add_resource(
            self.upload_reference_file, self.upload_reference_filename, "reference",
        )
        self.upload_reference_file = False
        self.upload_reference_filename = False

    @api.onchange("upload_sample_file")
    def _onchange_upload_sample(self):
        self._add_resource(
            self.upload_sample_file, self.upload_sample_filename, "sample",
        )
        self.upload_sample_file = False
        self.upload_sample_filename = False

    @api.onchange("upload_golden_file")
    def _onchange_upload_golden(self):
        self._add_resource(
            self.upload_golden_file, self.upload_golden_filename, "sample",
        )
        self.upload_golden_file = False
        self.upload_golden_filename = False

    # ── Question Templates (the Skills & Templates page) ────────────────

    def _require_assessment_admin(self):
        # The same rung the template API routes require (`require_manager`):
        # the read-only Manager role can open this form but must not spend or
        # author from it.
        if not self.env.user.has_group(
                "assessments_be_v2.group_assessment_manager"):
            raise AccessError("Assessment Admin access required.")

    def _task_template_form(self, context):
        return {
            "type": "ir.actions.act_window",
            "name": "Question Template",
            "res_model": "assessments.be.task.template",
            "view_mode": "form",
            "views": [[self.env.ref(
                "assessments_be_v2.assessments_be_task_template_form").id,
                "form"]],
            "target": "current",
            "context": context,
        }

    def action_new_task_template(self):
        """A blank template for this generator, authored by hand.

        IT OPENS WITH NO NAME, AND THAT IS THE POINT. `name` defaults to
        "Untitled task", and Odoo's `beforeUnload` urgent save has no dirty
        check for a NEW record (`record.js` `_save`), so a valid blank form
        would be saved as an active template - listed by every generator's
        quota picker - just by leaving the page. With no name the form is
        invalid, so the urgent save refuses before any RPC and nothing is
        created.
        """
        self.ensure_one()
        self._require_assessment_admin()
        return self._task_template_form({
            "default_name": False,
            "default_origin_prompt_id": self.id,
            "default_authored_by": "manual",
        })

    def action_draft_task_template(self):
        """Ask the model for a template from this SOP. SAVES NOTHING.

        One paid call. The draft opens as an UNSAVED template form - its values
        ride in as defaults - so closing it without Save leaves no record, as
        the app's editor does. Its Odoo button is hidden for now (S8): the
        draft arrives named, so leaving the page urgent-saves it.
        """
        self.ensure_one()
        self._require_assessment_admin()
        from ..services import vertex
        try:
            draft = vertex.draft_task_template_from_sop(
                self.env, self, usage_ctx={"user_id": self.env.user.id})
        except vertex.LLMRefusalError as exc:
            raise UserError(str(exc))
        context = {
            "default_origin_prompt_id": self.id,
            "default_authored_by": "llm_edited",
            "default_structure_json": draft.get("structure") or [],
        }
        for key in ("name", "instructions", "response", "media_brief"):
            if draft.get(key):
                context["default_%s" % key] = draft[key]
        return self._task_template_form(context)

    @api.depends("resource_ids", "resource_ids.category")
    def _compute_has_sop_resource(self):
        for rec in self:
            rec.has_sop_resource = any(
                r.category == "sop" for r in rec.resource_ids)

    @api.depends("question_ids", "question_ids.state")
    def _compute_counts(self):
        for rec in self:
            rec.question_count = len(rec.question_ids)
            rec.approved_count = len(
                rec.question_ids.filtered(lambda q: q.state == "approved")
            )
            rec.draft_count = len(
                rec.question_ids.filtered(lambda q: q.state == "draft")
            )

    @api.depends("resource_ids")
    def _compute_resource_count(self):
        for rec in self:
            rec.resource_count = len(rec.resource_ids)

    def _compiled_source_text(self):
        self.ensure_one()
        parts = []
        for res in self.resource_ids.sorted("sequence"):
            text = (res.extracted_text or "").strip()
            if text:
                parts.append(
                    "===== RESOURCE: %s =====\n%s" % (res.name or "file", text)
                )
            elif res.extraction_error:
                _logger.warning(
                    "Prompt %s: resource '%s' has no extracted text (%s)",
                    self.id, res.name, res.extraction_error,
                )
        if (self.source_text or "").strip():
            parts.append(
                "===== ADDITIONAL NOTES =====\n%s" % self.source_text.strip()
            )
        if not parts:
            raise UserError(
                "No source material. Upload at least one resource file "
                "(or add notes) before generating."
            )
        return "\n\n".join(parts)

    def _allowed_question_types(self):
        self.ensure_one()
        # Sort explicitly: an M2M written in the same transaction reads back in
        # link order, which would make the generation directive unstable.
        codes = list(dict.fromkeys(
            self.allowed_question_type_ids
                .sorted(lambda t: (t.sequence, t.id)).mapped("code")))
        if not codes and self.force_question_type:
            codes = [self.force_question_type]
        return tuple(codes)

    def _raise_count_to_type_floor(self):
        """The "at least one item per ticked type" nudge, only when nothing
        more specific has been asked for.

        THE CHIPS WIN OVER THE FLOOR. `shape_quota_json` is the examiner
        saying, per shape, exactly what they want; raising the stored count to
        the number of ticked types on top of that would silently rewrite
        their request. The coverage floor still applies in
        `effective_generation_count`, what generation asks the model for, and
        `effective_question_count` shows that number on the form.
        """
        self.ensure_one()
        if parse_shape_quotas(self.shape_quota_json):
            return
        n = len(self.allowed_question_type_ids)
        if self.sop_question_count and self.sop_question_count < n:
            self.sop_question_count = n

    @api.onchange("allowed_question_type_ids", "sop_question_count",
                  "shape_quota_json")
    def _onchange_min_questions_for_types(self):
        self._raise_count_to_type_floor()

    def _prune_type_quotas(self):
        """Drop per-TYPE counts for types this generator no longer allows.

        As the API does on every type-picker write (`write.py`
        `generator_update`). A leftover `"mcq": 2` is invisible in the picker
        but still summed into the count and sent to the model, so the run
        would author and bill two unrequested items. Same parser as the API and
        generation. Template shapes are never touched: a template names its
        own type.
        """
        for rec in self:
            stored = parse_shape_quotas(rec.shape_quota_json)
            if not stored:
                continue
            kept = parse_shape_quotas(
                stored,
                allowed_types=tuple(
                    rec.allowed_question_type_ids.mapped("code")))
            if kept != stored:
                rec.shape_quota_json = (
                    json.dumps(kept, ensure_ascii=False) if kept else "")

    @api.onchange("allowed_question_type_ids")
    def _onchange_prune_type_quotas(self):
        self._prune_type_quotas()

    def write(self, vals):
        res = super().write(vals)
        if "allowed_question_type_ids" in vals:
            # Only `shape_quota_json` is written back, so this cannot recurse.
            self._prune_type_quotas()
        return res

    @api.depends("sop_question_count", "shape_quota_json",
                 "allowed_question_type_ids")
    def _compute_effective_question_count(self):
        """What the run will actually ask the model for.

        Read through `effective_generation_count`, the same function
        `services/vertex` calls when it builds the directive, so the number on
        the form is the number that gets paid for. It is usually larger than
        "Questions to generate": every ticked type with no count of its own
        still earns one item (the coverage floor), and the per-shape counts are
        a floor rather than a share of the total.
        """
        for rec in self:
            n = rec.effective_question_count = effective_generation_count(
                rec.sop_question_count,
                parse_shape_quotas(rec.shape_quota_json),
                tuple(rec.allowed_question_type_ids.mapped("code")))
            if rec.sop_question_count:
                rec.effective_question_label = (
                    "This run will generate %d question(s)" % n)
            elif n:
                rec.effective_question_label = (
                    "Model decides - at least %d question(s)" % n)
            else:
                rec.effective_question_label = "Model decides"

    @api.onchange("select_all_types")
    def _onchange_select_all_types(self):
        if self.select_all_types:
            self.allowed_question_type_ids = self.env[
                "assessments.be.question.type"].search([])
            self.select_all_types = False
            self._raise_count_to_type_floor()

    @api.depends("resource_ids", "resource_ids.category")
    def _compute_sop_resource_ids(self):
        for rec in self:
            rec.sop_resource_ids = rec.resource_ids.filtered(
                lambda r: r.category == "sop")

    @api.depends("allowed_question_type_ids")
    def _compute_types_all_selected(self):
        total = self.env["assessments.be.question.type"].search_count([])
        for rec in self:
            rec.types_all_selected = bool(
                total and len(rec.allowed_question_type_ids) >= total)

    @api.depends("sop_question_count")
    def _compute_question_count_mode(self):
        for rec in self:
            rec.question_count_mode = "fixed" if rec.sop_question_count else "auto"

    def _inverse_question_count_mode(self):
        for rec in self:
            rec._apply_question_count_mode()

    @api.onchange("question_count_mode")
    def _onchange_question_count_mode(self):
        # The inverse only fires on write(), never on in-form NewId assignment.
        self._apply_question_count_mode()

    def _apply_question_count_mode(self):
        for rec in self:
            if rec.question_count_mode == "auto":
                rec.sop_question_count = 0
            elif not rec.sop_question_count:
                rec.sop_question_count = len(rec.allowed_question_type_ids) or 5

    @api.constrains("sop_question_count", "allowed_question_type_ids",
                    "shape_quota_json")
    def _check_question_count(self):
        for rec in self:
            if rec.sop_question_count < 0:
                raise ValidationError(
                    "Questions to Generate cannot be negative.")
            # Per-shape counts are an explicit request, so they are not
            # second-guessed against the type picker - see
            # `_raise_count_to_type_floor`. The coverage floor still applies at
            # generation time and is shown as "This run will generate N".
            if parse_shape_quotas(rec.shape_quota_json):
                continue
            n = len(rec.allowed_question_type_ids)
            if rec.sop_question_count and rec.sop_question_count < n:
                raise ValidationError(
                    "Questions to Generate (%d) is less than the %d selected "
                    "question types. Set it to at least %d, remove some types, "
                    "or set it to 0 to let the model decide the count."
                    % (rec.sop_question_count, n, n))

    @api.constrains("image_label_count")
    def _check_image_label_count(self):
        """At least 1. Zero is not "let the model decide" here.

        `sop_question_count` uses 0 for auto, so an operator carries that
        reading over. It cannot mean the same thing for this field: the count
        is also the DENOMINATOR a labelling answer is normalised by, so a 0
        would author a question with no boxes to answer and then divide by it.
        Rejected at the write path rather than clamped at read, so the bad
        value is never stored in the first place.
        """
        for rec in self:
            if rec.image_label_count < 1:
                raise ValidationError(
                    "Image Labelling Count must be at least 1 (got %d). It is "
                    "the maximum number of labelled boxes one image labelling "
                    "question may carry."
                    % rec.image_label_count)

    def action_generate_from_sop(self):
        self.ensure_one()
        if not self.resource_ids and not (self.source_text or "").strip():
            raise UserError(
                "Upload a SOP document (or add notes) before generating.")
        self.write({"sop_gen_state": "queued", "sop_gen_error": False,
                    "state": "generating"})
        # Start now, not at the next tick (see `_queue_tag_extract`).
        cron = self.env.ref("assessments_be_v2.ir_cron_generate_from_sop",
                            raise_if_not_found=False)
        if cron:
            cron.sudo()._trigger()
        if self.question_count_mode == "fixed" and self.sop_question_count:
            count_txt = "%d question(s)" % self.sop_question_count
        else:
            count_txt = "auto (model decides)"
        types_txt = ", ".join(
            self.allowed_question_type_ids.mapped("name")) or "any (model picks)"
        self._log_activity(Markup(
            "<b>Generate Questions</b> requested.<br/>"
            "Count: %s<br/>Allowed types: %s") % (count_txt, types_txt))
        return {
            "type": "ir.actions.client",
            "tag": "display_notification",
            "params": {
                "title": "Question Generation Queued",
                "message": "Reading your SOP in the background - draft questions "
                           "appear here within a minute or two; this page "
                           "updates on its own.",
                "type": "success", "sticky": False,
                # REFRESH THE FORM THE ADMIN IS LOOKING AT. Without a `next`
                # the record is never reloaded, so the form keeps the old state
                # and the `be_auto_refresh` badge (which polls only a record it
                # was handed busy) never starts. `act_window_close` is the one
                # action whose handler calls the button's `onClose`, which
                # reloads the view.
                "next": {"type": "ir.actions.act_window_close"},
            },
        }

    def _latest_run_draft_domain(self):
        """This generator's drafts from its latest run: created since the run
        started, or every draft on a run from before `sop_gen_started_at`.
        One definition for `/progress`'s counts and `retry_failed_images`, so
        the button's "(n)" is what it retries."""
        self.ensure_one()
        domain = [("prompt_id", "=", self.id)]
        if self.sop_gen_started_at:
            domain.append(("create_date", ">=", self.sop_gen_started_at))
        return domain

    # States a run can be killed FROM. `finalizing` is included even though the
    # spending is already over: the drafts are committed but the verdict is not
    # yet written, and an admin who pressed Kill deserves to see 'Cancelled'
    # rather than 'Done' on a run they stopped.
    CANCELLABLE_GEN_STATES = ("queued", "generating", "finalizing")

    def action_cancel_generation(self):
        """Kill this generator's question generation, and only this one's.

        WHAT IT ACTUALLY DOES. There is no process to signal - generation runs
        inside a cron worker - so this raises a flag and commits it. Every
        billable lane belonging to this generator reads that flag back before
        its next call (`services/vertex._check_cancelled`) and refuses, so a run
        stops within one call instead of at the end of its batch. The single
        request already on the wire completes and is billed; nothing after it
        is. `prompt_id` is what scopes it, so a second generator running at the
        same time is untouched.

        DRAFTS ARE KEPT. Whatever the run had already written stays in the
        review queue, where the admin can read it and discard it deliberately.
        The money that produced them is spent either way, and throwing the work
        away on their behalf is a decision that is not ours to make.

        Idempotent: pressing Kill on a run that has already stopped is a no-op
        that still reports success, because the admin's intent is satisfied.
        """
        self.ensure_one()
        if self.sop_gen_state not in self.CANCELLABLE_GEN_STATES:
            return False
        self.write({
            "sop_gen_cancel_requested": True,
            "sop_gen_cancelled_at": fields.Datetime.now(),
        })
        # A run sitting in `queued` has not spent anything and no worker holds
        # it, so settle it here rather than waiting a tick for a cron to notice
        # a flag on work it was never going to start.
        if self.sop_gen_state == "queued":
            self._settle_generation_cancelled(
                "the run was still queued, so nothing was spent")
        self._log_activity(Markup(
            "<b>Kill requested</b> - question generation will stop at the next "
            "LLM call. Draft questions already produced are kept."))
        return True

    def _settle_generation_cancelled(self, why=""):
        """Park a killed generator in `cancelled` and clear the flag.

        The flag is CLEARED here and nowhere else. Leaving it raised would make
        the generator permanently unable to generate: every future run would
        refuse at its first checkpoint, and the only symptom would be a run that
        produced nothing for no stated reason.
        """
        self.ensure_one()
        vals = {
            "sop_gen_state": "cancelled",
            "sop_gen_finished_at": fields.Datetime.now(),
            "sop_gen_cancel_requested": False,
            "sop_gen_error": False,
            "sop_gen_report": (
                "Cancelled by an admin%s. Draft questions already produced are "
                "kept." % (" - %s" % why if why else ""))[:1024],
        }
        if not self.sop_gen_cancelled_at:
            vals["sop_gen_cancelled_at"] = fields.Datetime.now()
        # `state` is the coarse lifecycle and was moved to 'generating' when the
        # run was requested. Put it back where it was so the stage bar does not
        # claim work is in flight after it has stopped.
        if self.state == "generating":
            vals["state"] = ("skills_ready"
                             if self.tag_extract_state == "done" else "draft")
        self.write(vals)
        self._cancel_pending_media()

    def _cancel_pending_media(self):
        """Stop the media work this generator has QUEUED but not yet paid for.

        WHY THIS IS PART OF A KILL. Question authoring is one LLM call; the
        expensive tail is what follows it - an image render per draft, and a Veo
        submission per clip, priced per second. Leaving those queued would mean
        Kill stopped the cheap half and let the costly half run on the next cron
        tick, which is the opposite of what the button is for.

        The DRAFTS ARE NOT TOUCHED. Only the media lifecycle moves, and only
        from a not-yet-started state - a picture already rendered has been paid
        for and stays exactly where it is. Every draft remains in the review
        queue for the admin to read and discard on purpose.
        """
        self.ensure_one()
        drafts = self.env["assessments.be.prompt.question"].search(
            [("prompt_id", "=", self.id)])
        pending_images = drafts.filtered(lambda d: d.image_state == "pending")
        if pending_images:
            pending_images.write({"image_state": "cancelled"})
        # 'generating' counts here as well as 'pending': a Veo op that has been
        # submitted is already billed, but polling it forever spends worker time
        # on a run nobody wants any more.
        pending_videos = drafts.filtered(
            lambda d: d.video_state in ("pending", "generating"))
        if pending_videos:
            pending_videos.write({"video_state": "cancelled"})

    #: A run left in `finalizing` this long lost every save of its drafts to
    #: other writes. It is no longer re-queued (that re-ran Vertex and
    #: duplicated drafts), so without this it would sit there until Kill.
    _FINALIZE_STUCK_AFTER = timedelta(minutes=15)

    def _settle_stuck_finalizing(self):
        """Close runs stuck in `finalizing` for 15 minutes.

        Drafts from the run exist -> the save did land: `done`. None -> the
        paid output is lost: `failed`, with an error telling the admin to
        generate again, so the page stops saying "Writing questions" forever.
        """
        cutoff = fields.Datetime.now() - self._FINALIZE_STUCK_AFTER
        Draft = self.env["assessments.be.prompt.question"].sudo()
        for prompt in self.search([("sop_gen_state", "=", "finalizing"),
                                   ("write_date", "<", cutoff)]):
            since = prompt.write_date
            # A run from before `sop_gen_started_at` existed has no start: its
            # drafts are the ones written in the hour before it stalled.
            # ponytail: an earlier run's drafts inside that hour also count.
            started = prompt.sop_gen_started_at or (since - timedelta(hours=1))
            landed = Draft.search_count(
                [("prompt_id", "=", prompt.id), ("create_date", ">=", started)])
            vals = {"sop_gen_finished_at": fields.Datetime.now()}
            if landed:
                vals["sop_gen_state"] = "done"
            else:
                vals.update(
                    sop_gen_state="failed",
                    sop_gen_error=(
                        "Saving the generated drafts kept colliding with "
                        "other changes. Press Generate questions again."))
            prompt.write(vals)
            _logger.warning(
                "etp_assessment SOP gen: prompt %s stuck in finalizing since "
                "%s settled as %s", prompt.id, since,
                vals.get("sop_gen_state"))
            self.env.cr.commit()

    @api.model
    def _cron_generate_from_sop(self):
        """Must commit before the slow Vertex call: managed Postgres reaps the
        idle-in-transaction connection ('cursor already closed')."""
        from ..services import vertex
        domain = [("sop_gen_state", "in", ("queued", "generating"))]
        with cron_lock(self.env.cr, ADVISORY_LOCK_QUESTION_GEN,
                       name="question_gen",
                       queued=lambda: self.search_count(domain)) as got:
            if not got:
                return
            self._settle_stuck_finalizing()
            prompts = self.search(domain, limit=2)
            if not prompts:
                return
            _logger.info(
                "etp_assessment SOP gen cron: %d prompt(s) to generate",
                len(prompts))
            for prompt in prompts:
                # Cheapest possible checkpoint: a generator killed while it sat
                # in the queue must never reach Vertex at all. The per-call
                # checkpoint inside the service would also catch it, but only
                # after the run had started and paid for its first call.
                if prompt.sop_gen_cancel_requested:
                    prompt._settle_generation_cancelled(
                        "stopped before the run started")
                    got.renew()
                    self.env.cr.commit()
                    continue
                prompt.write({"sop_gen_state": "generating",
                              "sop_gen_error": False,
                              "sop_gen_started_at": fields.Datetime.now(),
                              "sop_gen_finished_at": False})
                got.renew()
                self.env.cr.commit()
                try:
                    # `report` comes back describing what the run really did.
                    # Without it a zero-draft outcome is indistinguishable from
                    # a thin SOP, and this cron reported both as success.
                    report = {}
                    draft_ids = vertex.generate_questions_from_sop(
                        self.env, prompt,
                        count=prompt.sop_question_count or 0,
                        allowed_types=prompt._allowed_question_types(),
                        label_box_cap=(prompt.image_label_count
                                       or DEFAULT_IMAGE_LABEL_COUNT),
                        report=report)
                    # Commit the drafts before the contended state write, so a
                    # serialization retry there cannot lose them or re-run Vertex.
                    got.renew()
                    self.env.cr.commit()
                    # H-8: flip to 'finalizing' and COMMIT before the final
                    # status write. The drainer only selects queued/generating,
                    # so if the worker is killed between the draft commit and the
                    # 'done' write, the row is left 'finalizing' (needs an admin
                    # nudge) and is NEVER re-sent to Vertex — no duplicate drafts,
                    # no double spend.
                    prompt.write({"sop_gen_state": "finalizing"})
                    got.renew()
                    self.env.cr.commit()
                    self._finalize_sop_gen_state(
                        prompt, len(draft_ids), report=report)
                    # A zero-draft run is finalized as failed; its chatter
                    # line must say so, not "Generation complete".
                    if prompt.sop_gen_state == "failed":
                        prompt._log_activity(Markup(
                            "<b>Generation failed</b> - %s")
                            % prompt.sop_gen_error)
                    else:
                        prompt._log_activity(Markup(
                            "<b>Generation complete</b> - %d draft "
                            "question(s) authored from the SOP and ready for "
                            "review.%s")
                            % (len(draft_ids),
                               Markup("<br/>%s") % prompt.sop_gen_report
                               if prompt.sop_gen_report else ""))
                    prompt._wake_media_crons(draft_ids)
                    got.renew()
                    self.env.cr.commit()
                    _logger.info(
                        "etp_assessment SOP gen cron: prompt %s -> %d draft(s)",
                        prompt.id, len(draft_ids))
                except vertex.VertexCancelledError:
                    # NOT a failure and NOT re-queued. The rollback discards
                    # only this run's uncommitted work; every draft the run had
                    # already committed survives, which is the promise the
                    # button makes.
                    self.env.cr.rollback()
                    _logger.info(
                        "SOP generation for prompt %s was cancelled by an "
                        "admin; no further LLM calls were made.", prompt.id)
                    prompt._settle_generation_cancelled(
                        "stopped mid-run at an LLM checkpoint")
                    got.renew()
                    self.env.cr.commit()
                except vertex.VertexQuotaError:
                    self.env.cr.rollback()
                    _logger.warning(
                        "SOP generation for prompt %s hit Vertex quota (429); "
                        "re-queued for next tick.", prompt.id)
                    prompt.write({"sop_gen_state": "queued",
                                  "sop_gen_error": False})
                    got.renew()
                    self.env.cr.commit()
                except _TRANSIENT_DB_ERRORS as exc:
                    # A lost DB race (40001, deadlock, lock timeout) with the
                    # tag-extract cron writing the SAME prompt row (they hold
                    # different advisory locks, and Vertex's mid-generation
                    # writes to video_brief_json / metadata can lose). The DB
                    # asking to try again, not a failed run: left for the next
                    # tick. Any other DB error is a real failure, below.
                    self.env.cr.rollback()
                    _warn_lost_race(prompt, "SOP generation for prompt", exc)
                    # Re-queued only while the drafts are NOT committed. Once
                    # it is `finalizing` (H-8) a re-queue would re-run Vertex
                    # over drafts that already exist, so it is left alone.
                    if prompt.sop_gen_state == "generating":
                        prompt.write({"sop_gen_state": "queued",
                                      "sop_gen_error": False})
                        got.renew()
                        self.env.cr.commit()
                except Exception as exc:  # noqa: BLE001 - isolate per prompt
                    self.env.cr.rollback()
                    _logger.exception(
                        "SOP generation failed for prompt %s", prompt.id)
                    error = str(exc)[:300]
                    # `state` too, or the stage bar says Generating forever.
                    tagged = prompt.tag_extract_state == "done"
                    prompt.write({"sop_gen_state": "failed",
                                  "state": "skills_ready" if tagged
                                  else "draft",
                                  "sop_gen_error": error,
                                  "sop_gen_finished_at": fields.Datetime.now()})
                    prompt._log_activity(
                        Markup("<b>Generation failed</b> - %s") % error)
                    got.renew()
                    self.env.cr.commit()

    @api.model
    def _sop_gen_result_vals(self, draft_count, report=None, prompt=None):
        """The write a finished generation run deserves, as a plain dict.

        SPLIT OUT SO IT CAN BE TESTED. `_finalize_sop_gen_state` commits, which a
        TransactionCase forbids, so the decision that matters - is a run that
        produced nothing a success or a failure - was unreachable from a test.
        That is the decision this whole change is about, so it does not get to
        live inside a method the suite cannot call.
        """
        report = report if isinstance(report, dict) else {}
        rejected = int(report.get("rejected") or 0)
        reasons = [str(r) for r in (report.get("reasons") or [])]
        summary = "Generated %s draft(s) from SOP" % draft_count

        # A KILL THAT LANDS DURING FINALIZE STILL COUNTS. `finalizing` is a
        # one-way trap by design - the drainer never re-selects it, so the run
        # cannot be re-sent to Vertex - which means the right answer to a cancel
        # arriving here is to let the finalize complete and then record that it
        # was cancelled, NOT to unwind it into something re-runnable. The drafts
        # it produced are real and are kept; only the verdict changes.
        if prompt is not None and prompt.sop_gen_cancel_requested:
            return {
                "state": "skills_ready" if prompt.tag_extract_state == "done"
                         else "draft",
                "sop_gen_state": "cancelled",
                "sop_gen_finished_at": fields.Datetime.now(),
                "sop_gen_cancel_requested": False,
                "sop_gen_cancelled_at": fields.Datetime.now(),
                "last_extract_summary": summary,
                "sop_gen_report": (
                    "Cancelled by an admin. %s (kept for review)." % summary
                )[:1024],
                "sop_gen_error": False,
            }
        if rejected:
            summary += "; %s item(s) rejected" % rejected
        vals = {
            "state": "done",
            "sop_gen_state": "done",
            # Kept when the zero-yield branch below turns this into `failed`.
            "sop_gen_finished_at": fields.Datetime.now(),
            "last_extract_summary": summary,
            # Always rewritten, so last run's verdict cannot linger over this one.
            "sop_gen_report": (
                "%s. %s" % (summary, " | ".join(reasons)) if reasons
                else summary)[:1024],
            "sop_gen_error": False,
        }
        if not draft_count:
            # ZERO DRAFTS IS A FAILURE, whatever the reason.
            #
            # This used to read `if not draft_count and rejected:`, and the
            # producer hardcodes `"rejected": 0` - so the branch could not fire
            # in production. Every empty run wrote state=done, sop_gen_state=done,
            # sop_gen_error=False: the stage bar said Done, the success banner is
            # suppressed at zero questions so nothing was drawn at all, and the
            # examiner was left looking at an empty Question Drafts tab with no
            # statement anywhere that the run had failed. A run that called the
            # model, spent the budget and produced nothing is exactly the run
            # somebody has to be told about.
            vals["sop_gen_state"] = "failed"
            # Not 'done' either. The stage bar is the first thing read, and
            # "Done" over an empty drafts list is the claim that misled.
            vals["state"] = ("skills_ready" if prompt is not None
                             and prompt.tag_extract_state == "done" else "draft")
            returned = int(report.get("returned") or 0)
            if rejected:
                detail = ("The model returned %s item(s) and every one was "
                          "rejected." % (returned or rejected))
            elif returned:
                detail = ("The model returned %s item(s) and none of them could "
                          "be made into a draft." % returned)
            else:
                detail = ("The model returned nothing this run could read as a "
                          "question list.")
            vals["sop_gen_error"] = (
                "No draft questions were created. %s %s" % (
                    detail,
                    " | ".join(reasons) or "No reason was recorded."))[:1024]
        return vals

    def _finalize_sop_gen_state(self, prompt, draft_count, report=None):
        """Retry on a lost DB race (`_TRANSIENT_DB_ERRORS`): the tag-extract
        cron writes the same row under a different advisory lock. Never
        re-queue here — the drainer cannot tell
        'needs generation' from 'needs finalization', so it would re-run Vertex
        and duplicate the already-committed drafts.

        `report` is what `generate_questions_from_sop` observed. A run that spent
        money and produced NOTHING is recorded as a FAILURE with its reasons, not
        as 'done' — that pairing is how a whole batch could be rejected for one
        malformed answer key while the console showed a green tick and an
        examiner was left reading server logs to find out why.
        """
        import time
        vals = self._sop_gen_result_vals(draft_count, report, prompt)
        for attempt in range(_SOP_GEN_FINALIZE_MAX_ATTEMPTS):
            try:
                prompt.write(vals)
                self.env.cr.commit()
                return
            except _TRANSIENT_DB_ERRORS:
                if attempt == _SOP_GEN_FINALIZE_MAX_ATTEMPTS - 1:
                    raise
                self.env.cr.rollback()
                prompt.invalidate_recordset()
                _logger.warning(
                    "SOP gen finalize lost a DB race on prompt %s "
                    "(attempt %s/%s); rolled back the state write and retrying "
                    "with the drafts already committed.",
                    prompt.id, attempt + 1, _SOP_GEN_FINALIZE_MAX_ATTEMPTS)
                time.sleep(0.1 * (attempt + 1))

    def _wake_media_crons(self, draft_ids):
        """Start a finished run's renders as soon as a cron slot is free, not
        at the media crons' next 5-minute tick.

        Only the wake-up changes. Batch size and interval stay: the one cron
        slot per pod also runs scoring. An inactive cron is left alone. Never
        raises: the run is already `done`, and the periodic tick is the
        fallback, so a failed wake-up must not turn it into a failed run.
        """
        drafts = self.env["assessments.be.prompt.question"].browse(draft_ids)
        for xmlid, state in (("ir_cron_render_pending_images", "image_state"),
                             ("ir_cron_poll_video_ops", "video_state")):
            if not any(d[state] == "pending" for d in drafts):
                continue
            try:
                with self.env.cr.savepoint():
                    cron = self.env.ref("assessments_be_v2.%s" % xmlid,
                                        raise_if_not_found=False)
                    if cron and cron.sudo().active:
                        cron.sudo()._trigger()
            except Exception:  # noqa: BLE001 - the periodic tick is the fallback
                _logger.warning("Could not wake %s; it runs on its next tick.",
                                xmlid, exc_info=True)

    def _finalize_tag_extract_state(self, prompt, tags, raw):
        """Retry on a lost DB race: the SOP-gen cron writes the same row under
        a different advisory lock. Mirrors _finalize_sop_gen_state."""
        import time
        vals = {
            "tag_ids": [(6, 0, tags.ids)],
            "tags_json": raw or False,
            "tag_extract_reply": False,
            "tag_extract_state": "done",
            "tag_extract_error": False,
            "tag_extract_cancel_requested": False,
            "tag_extract_last_run": fields.Datetime.now(),
        }
        if prompt.state == "draft":
            # Only move FORWARD out of 'draft': a generator already
            # generating/done must not be dragged backwards by a re-run.
            vals["state"] = "skills_ready"
        for attempt in range(_TAG_EXTRACT_FINALIZE_MAX_ATTEMPTS):
            try:
                prompt.write(vals)
                self.env.cr.commit()
                # Mapping + ranking happen ONCE here, as part of extraction, and
                # AFTER the state commit so a ranking hiccup cannot lose the
                # tags; the helper is best-effort and swallows its own errors.
                try:
                    prompt._auto_rank_after_mapping(semantic=True)
                    self.env.cr.commit()
                except Exception as rank_exc:  # noqa: BLE001
                    self.env.cr.rollback()
                    _logger.warning(
                        "Tag extract: auto-rank failed for prompt %s (tags kept): %s",
                        prompt.id, rank_exc)
                return
            except _TRANSIENT_DB_ERRORS:
                if attempt == _TAG_EXTRACT_FINALIZE_MAX_ATTEMPTS - 1:
                    raise
                self.env.cr.rollback()
                prompt.invalidate_recordset()
                _logger.warning(
                    "Tag extract finalize lost a DB race on prompt %s "
                    "(attempt %s/%s); rolled back the state write and retrying "
                    "with the tags already committed.",
                    prompt.id, attempt + 1, _TAG_EXTRACT_FINALIZE_MAX_ATTEMPTS)
                time.sleep(0.1 * (attempt + 1))

    def _keep_tag_reply(self, raw):
        """Commit a paid tag reply the moment it arrives, before anything else
        in the run can lose a race and make the cron buy it again.

        On a fresh READ COMMITTED side cursor: its UPDATE waits out a
        concurrent writer where the cron's own snapshot, taken before the ~20s
        call, would fail with 40001. Safe only because nothing of this row is
        pending on the cron's cursor yet (called before a single field of the
        reply is written); the cron's transaction is then ended, so what it
        writes next starts from a snapshot that includes this.
        """
        self.ensure_one()
        from ..services import vertex
        if vertex._side_cursor_is_safe(self.env):
            with self.env.registry.cursor() as cr:
                cr.execute("SET TRANSACTION ISOLATION LEVEL READ COMMITTED")
                self.with_env(self.env(cr=cr, su=True)).write(
                    {"tag_extract_reply": raw})
                cr.commit()
        else:  # test mode: the caller's cursor, as `_write_ledger_row`
            self.tag_extract_reply = raw
        self.env.cr.commit()

    def _queue_tag_extract(self):
        """Queue tag extraction for these generators and wake the drainer cron.

        Extraction MUST NOT run inside the web request. Odoo serves requests at
        REPEATABLE READ, so a request's snapshot is fixed at its first query.
        The old inline path then did two incompatible things to the SAME row:

          1. wrote ``tag_extract_state`` on an INDEPENDENT cursor - a second
             connection, committing immediately - so that the status could
             survive the rollback Odoo performs when the handler raises
             UserError;
          2. ~20s later, once Vertex answered, wrote the tags through the ORM
             on the request's OWN cursor.

        By (2) the row already carried a committed version newer than the
        request's snapshot, so PostgreSQL had to abort the flush with 40001,
        "could not serialize access due to concurrent update". The request was
        losing a race against itself - which is exactly why an advisory lock
        could not help: a lock serialises one request against another, never a
        connection against a second connection opened by that same request.

        Moving the work to the cron removes the conflict at its root. The cron
        owns its transaction, so committing its own progress is legitimate
        there, and the request goes back to being short. ``_trigger()`` starts
        it within seconds; the cron's interval is only the safety net for a
        trigger lost with a killed worker.
        """
        if not self:
            return
        # A new press is a new read of the SOP, never a kept earlier reply.
        self.write({"tag_extract_state": "queued", "tag_extract_error": False,
                    "tag_extract_reply": False,
                    "tag_extract_cancel_requested": False})
        cron = self.env.ref("assessments_be_v2.ir_cron_extract_tags",
                            raise_if_not_found=False)
        if cron:
            # sudo: ir.cron is admin-only, but any generator manager may queue
            # their own extraction. _trigger() only records "run this soon".
            cron.sudo()._trigger()

    def action_approve_all_drafts(self):
        self.ensure_one()
        drafts = self.question_ids.filtered(lambda r: r.state == "draft")
        if not drafts:
            raise UserError("There are no pending drafts to approve.")
        # THE SAME GATE THE SINGLE-DRAFT PATH APPLIES.
        #
        # `/drafts/<id>/approve` refuses a draft carrying an authoring smell
        # unless the caller states they reviewed it (422
        # `warnings_unacknowledged`). This route reached `action_approve`, which
        # tests neither flag, so Approve All banked in bulk exactly what the
        # per-draft gate exists to hold back - and it was the obvious way around
        # that gate for anyone it had just stopped. A batch button is the last
        # place a per-item human judgement can be assumed, so these are HELD and
        # named rather than approved: they go through the review queue, one at a
        # time, where the acknowledgement is recorded against the draft.
        #
        # `acknowledge_warnings` in the context is the deliberate opt-out, for a
        # caller that has already done that review.
        held = []
        if not self.env.context.get("acknowledge_warnings"):
            flagged = drafts.filtered(
                lambda r: r.has_revealing_option or r.has_source_reference)
            drafts -= flagged
            for draft in flagged:
                why = ", ".join(reason for reason in (
                    "a distractor reveals the answer"
                    if draft.has_revealing_option else "",
                    "it cites the source document the candidate never sees"
                    if draft.has_source_reference else "",
                ) if reason)
                held.append((draft, "held for review - %s" % why))
        # Skip-and-continue: approve each draft in its own savepoint so one bad
        # draft (e.g. an image_ab whose planted flaw never rendered) cannot roll
        # back the good ones. action_approve suppresses its own chatter note; we
        # post a single rollup below. The accumulator is an empty slice of
        # `drafts` so it matches the draft model, never the generator's own model.
        approved = drafts.browse()
        # Seeded with the held drafts, so one rollup and one notice cover both
        # reasons a draft did not make it into the bank.
        failures = list(held)
        for draft in drafts:
            try:
                with self.env.cr.savepoint():
                    draft.with_context(skip_approval_log=True).action_approve()
                approved |= draft
            except (UserError, ValidationError) as exc:
                # savepoint rolled the failed draft back; its ORM cache may be
                # stale, so drop it before touching the record again.
                draft.invalidate_recordset()
                failures.append((draft, str(exc)))
        if approved:
            approved._log_drafts_to_generators(approved, "approved")
        if failures:
            detail = "\n".join(
                "- %s: %s" % (
                    (d.name or d.question_prompt or "draft"),
                    (msg or "").strip().splitlines()[0] if msg else "unknown error")
                for d, msg in failures)
            self._log_activity(Markup(
                "<b>%d draft(s) skipped during Approve All</b> "
                "(the other %d were approved):<br/>%s")
                % (len(failures), len(approved), escape(detail)))
            if not approved:
                # Nothing got through - surface the reasons instead of a silent
                # no-op so the admin knows why. "did not pass" rather than
                # "failed": a draft held for an unacknowledged warning did not
                # fail anything, it is waiting on a human.
                raise UserError(
                    "No drafts could be approved. None passed its approval "
                    "check:\n%s" % detail)
            return {
                "type": "ir.actions.client",
                "tag": "display_notification",
                "params": {
                    "title": "Approved with skips",
                    "message": "%d draft(s) approved; %d skipped (see the "
                               "generator log for why)."
                               % (len(approved), len(failures)),
                    "type": "warning", "sticky": False,
                },
            }
        return True

    def action_extract_tags(self):
        self.ensure_one()
        if not self.resource_ids and not (self.source_text or "").strip():
            raise UserError(
                "Upload a SOP document (or add notes) before extracting tags.")
        # Captured BEFORE queueing so the toast can tell a first extraction
        # from a re-run: a re-run ends on 'Done' exactly as it began, so
        # without this the screen looked unchanged and the button felt dead.
        was_rerun = bool(self.tag_extract_last_run)
        self._queue_tag_extract()
        self._log_activity(Markup(
            "<b>Extract Tags</b> requested - the SOP is being read in the "
            "background."))
        # The `next` below reloads the form, which hands the `be_auto_refresh`
        # badge the busy 'Queued' state it then polls until the cron settles.
        return {
            "type": "ir.actions.client",
            "tag": "display_notification",
            "params": {
                "title": "Re-extracting Tags" if was_rerun else "Extracting Tags",
                "message": "Reading the SOP for tags in the background - they "
                           "appear here automatically in a few seconds.",
                "type": "success", "sticky": False,
                # See `models/assessment.action_llm_score_all`.
                "next": {"type": "ir.actions.act_window_close"},
            },
        }

    def action_cancel_tag_extract(self):
        """Kill this generator's Extract skills run. Spends nothing.

        Queued: settled at once, nothing was spent. Running: flagged, and the
        cron checks the flag the moment the model answers - the reply already
        paid for is NOT applied, so the tags, rating scheme and knowledge
        profile stay as they were. Returns False when nothing was running.
        """
        self.ensure_one()
        if self.tag_extract_state == "queued":
            self._settle_tag_extract_cancelled()
        elif self.tag_extract_state == "generating":
            self.tag_extract_cancel_requested = True
        else:
            return False
        self._log_activity(Markup(
            "<b>Extract skills stopped</b> - the SOP reading was cancelled; "
            "the skills already on this generator are unchanged."))
        return True

    def _settle_tag_extract_cancelled(self):
        self.write({"tag_extract_state": "cancelled",
                    "tag_extract_error": False,
                    "tag_extract_reply": False,
                    "tag_extract_cancel_requested": False})

    @api.model
    def _cron_extract_tags(self):
        """Must commit before the slow Vertex call ('cursor already closed').
        Mirrors _cron_generate_from_sop."""
        from ..services import vertex
        domain = [("tag_extract_state", "in", ("queued", "generating"))]
        with cron_lock(self.env.cr, ADVISORY_LOCK_TAG_EXTRACT,
                       name="tag_extract",
                       queued=lambda: self.search_count(domain)) as got:
            if not got:
                return
            prompts = self.search(domain, limit=2)
            if not prompts:
                return
            _logger.info(
                "etp_assessment tag extract cron: %d prompt(s) to tag",
                len(prompts))
            for prompt in prompts:
                if prompt.tag_extract_cancel_requested:
                    prompt._settle_tag_extract_cancelled()
                    got.renew()
                    self.env.cr.commit()
                    continue
                prompt.write({"tag_extract_state": "generating",
                              "tag_extract_error": False})
                got.renew()
                self.env.cr.commit()

                def kept(raw, prompt=prompt):
                    # Kept first (it is paid for), then the STOP check, before
                    # a single field of the reply is written. The keep commits,
                    # so this read sees a Stop pressed during the call.
                    prompt._keep_tag_reply(raw)
                    prompt.invalidate_recordset(
                        ["tag_extract_cancel_requested"])
                    if prompt.tag_extract_cancel_requested:
                        raise vertex.VertexCancelledError(
                            "Extract skills was stopped by an admin; the "
                            "reply was not applied.")
                try:
                    # A reply kept by an earlier tick whose finalize lost
                    # every retry is finished from, not bought again.
                    names, raw = vertex.extract_tags_from_sop(
                        self.env, prompt,
                        raw=prompt.tag_extract_reply or None,
                        on_reply=kept)
                    tags = self.env["assessments.be.tag"]._get_or_create(
                        names)
                    # Commit the tags before the contended state write, so a
                    # serialization retry there cannot lose them or re-run Vertex.
                    got.renew()
                    self.env.cr.commit()
                    self._finalize_tag_extract_state(prompt, tags, raw)
                    _logger.info(
                        "etp_assessment tag extract cron: prompt %s -> %d tag(s)",
                        prompt.id, len(tags))
                except vertex.VertexCancelledError:
                    # Tag extraction is its own button, but it is the same
                    # generator's money and it reads the same flag - so a Kill
                    # that lands while this lane happens to be running stops it
                    # too, and records that rather than calling it a failure the
                    # admin should retry.
                    self.env.cr.rollback()
                    _logger.info(
                        "Tag extraction for prompt %s stopped: the generator "
                        "was cancelled.", prompt.id)
                    prompt._settle_tag_extract_cancelled()
                    got.renew()
                    self.env.cr.commit()
                except vertex.VertexQuotaError:
                    self.env.cr.rollback()
                    _logger.warning(
                        "Tag extraction for prompt %s hit Vertex quota (429); "
                        "re-queued for next tick.", prompt.id)
                    prompt.write({"tag_extract_state": "queued",
                                  "tag_extract_error": False})
                    got.renew()
                    self.env.cr.commit()
                except _TRANSIENT_DB_ERRORS as exc:
                    # A lost race on the prompt row (the SOP-gen cron writes it
                    # too), not a failed extraction: re-queued, like a 429.
                    self.env.cr.rollback()
                    _warn_lost_race(prompt, "Tag extraction for prompt", exc)
                    prompt.write({"tag_extract_state": "queued",
                                  "tag_extract_error": False})
                    got.renew()
                    self.env.cr.commit()
                except Exception as exc:  # noqa: BLE001 - isolate per prompt
                    self.env.cr.rollback()
                    _logger.exception(
                        "Tag extraction failed for prompt %s", prompt.id)
                    prompt.write({"tag_extract_state": "failed",
                                  "tag_extract_error": str(exc)[:300]})
                    got.renew()
                    self.env.cr.commit()

    def _similarity_min_pct(self):
        """The match % at/above which a generator counts as 'similar' (drives the
        smart-button count + View Similar). Default 40 = the same-family band
        floor (research bands: >=75 near-duplicate, 40-74 same-family). Override
        via ir.config_parameter ``assessments_be_v2.similar_min_pct``."""
        param = self.env["ir.config_parameter"].sudo().get_param(
            "assessments_be_v2.similar_min_pct")
        if param:
            try:
                return float(param)
            except (TypeError, ValueError):
                pass
        return float(similarity.BAND_SAME_FAMILY)

    def _similar_prompts(self, limit=5, min_pct=None):
        """Rank OTHER generators against this one, reading the PERSISTED
        ``assessments.be.similarity`` matrix rows (source=self -> target) as
        the single source of truth — so this leaderboard and the matrix table
        below it ALWAYS show the same numbers. Ranking is hybrid (0.30 lexical +
        0.70 semantic), computed once during tag extraction and refreshed by the
        "Re-run AI ranking" button; nothing here triggers a paid call.

        A target that has no persisted pair yet (a project added AFTER this SOP
        was last ranked) is shown with a live-lexical score and mode='lexical'
        so it still appears — the user re-runs AI ranking to blend it in. Returns
        dicts ``{prompt, score, pct, lexical_pct, semantic_pct, band, mode,
        shared, evidence, why}`` sorted by pct desc.
        """
        self.ensure_one()
        rec_id = self.id if isinstance(self.id, int) else self._origin.id
        if not isinstance(rec_id, int) or not rec_id:
            return []
        my_card = similarity.card_from_prompt(self)
        if not my_card["mapping"]:
            return []
        Sim = self.env["assessments.be.similarity"].sudo()
        # Persisted directed rows are authoritative (what the matrix renders).
        persisted = {
            r.target_id.id: r
            for r in Sim.search([("source_id", "=", rec_id)])}
        others = self.search([
            ("id", "!=", rec_id),
            ("mapping_json", "!=", False)])
        results = []
        for other in others:
            other_card = similarity.card_from_prompt(other)
            if not other_card["mapping"]:
                continue
            lex01, matched = similarity.lexical_score(my_card, other_card)
            bd = similarity.facet_breakdown(my_card, other_card)
            row = persisted.get(other.id)
            if row:
                # Mirror the stored matrix row exactly (keeps the two views in
                # lockstep). A hybrid row carries a real semantic number even
                # when it is 0 (a legitimate 'no by-meaning overlap').
                pct = row.overall
                lexical_pct = row.lexical
                is_hybrid = row.mode == "hybrid"
                semantic_pct = row.semantic if is_hybrid else None
                mode = row.mode
                # Band is always derived from the shown pct so it can never drift
                # from the number (a stored band is only a cache of this).
                band = similarity._band(pct)
                why = row.why or ""
            else:
                pct = round(lex01 * 100)
                lexical_pct = pct
                semantic_pct = None
                mode = "lexical"
                band = similarity._band(pct)
                why = ""
            if min_pct is not None and pct < min_pct:
                continue
            results.append({
                "prompt": other,
                "score": pct / 100.0,
                "pct": pct,
                "lexical_pct": lexical_pct,
                "semantic_pct": semantic_pct,
                "band": band,
                "mode": mode,
                "shared": matched,
                "evidence": similarity._evidence_line(bd),
                "why": why,
            })
        results.sort(key=lambda d: (d["pct"], d["lexical_pct"]), reverse=True)
        return results[:limit] if limit else results

    def _recompute_similarity(self, semantic=False):
        """Compute this generator's ranking against every other and PERSIST it as
        directed ``assessments.be.similarity`` rows (source=self -> target).
        ``semantic=False`` (default, FREE): lexical-only rows. ``semantic=True``
        (PAID, one model call): runs the by-meaning pass under prompts/mapping.md,
        blends 0.30/0.70, and — on a failure of all retries — degrades HONESTLY to
        lexical rows filed as ``mode='lexical-fallback'`` (never 'hybrid'). Stores
        BOTH directed pairs separately over successive runs; never averages, so a
        wide A->B vs B->A split reads as low confidence (research ODOO19 §10)."""
        self.ensure_one()
        rec_id = self.id if isinstance(self.id, int) else self._origin.id
        if not isinstance(rec_id, int) or not rec_id:
            raise UserError(_("Save the generator before computing similarity."))
        my_card = similarity.card_from_prompt(self)
        if not my_card["mapping"]:
            raise UserError(_(
                "This generator has no faceted SOP mapping yet — extract tags "
                "from the SOP first, then compute similarity."))
        others = self.search([
            ("id", "!=", rec_id), ("mapping_json", "!=", False)])
        library = []
        card_by_key = {}
        for other in others:
            card = similarity.card_from_prompt(other)
            if not card["mapping"]:
                continue
            card["project"] = str(other.id)      # stable echo key for the model
            library.append(card)
            card_by_key[str(other.id)] = other
        if not library:
            raise UserError(_(
                "No other generator has a faceted SOP mapping to compare against."))

        sem_scores, mode = {}, "lexical"
        if semantic:
            my_card_for_model = dict(my_card, project=str(rec_id))
            sem_scores, _extracted, _summary = similarity.semantic_rank(
                self.env, my_card_for_model, library,
                usage_ctx={"operation": "map_similarity",
                           "prompt_id": rec_id,
                           "note": self.name or "SOP mapping"})
            # Honest degradation: semantic requested but every retry failed.
            mode = "hybrid" if sem_scores else "lexical-fallback"

        Sim = self.env["assessments.be.similarity"].sudo()
        now = fields.Datetime.now()
        # Carry-forward: a lexical-only pass (or a target this run's model didn't
        # score) must NEVER erase a semantic score computed by an earlier paid
        # run — that was the bug that made the whole library decay to lexical
        # every time a new SOP was added. We reuse the persisted semantic and
        # re-blend, so an existing hybrid row stays hybrid.
        prior = {
            r.target_id.id: r
            for r in Sim.search([("source_id", "=", rec_id)])}
        for other in card_by_key.values():
            other_card = similarity.card_from_prompt(other)
            lex01, matched = similarity.lexical_score(my_card, other_card)
            s = sem_scores.get(str(other.id))
            prior_row = prior.get(other.id)
            # semantic source of truth: this run's fresh score, else the prior
            # persisted one (mode hybrid means the stored number is real, incl 0).
            if s is not None:
                sem01 = s["overall"]
                why = (s.get("note") or "") or (
                    prior_row.why if prior_row else "")
                have_semantic = True
            elif prior_row is not None and prior_row.mode == "hybrid":
                sem01 = (prior_row.semantic or 0) / 100.0
                why = prior_row.why or ""
                have_semantic = True
            else:
                sem01 = None
                why = prior_row.why if prior_row else ""
                have_semantic = False
            if have_semantic and sem01 is not None:
                final01 = similarity.blend(lex01, sem01)
                sem_pct = round(sem01 * 100)
                row_mode = "hybrid"
            else:
                final01 = lex01
                sem_pct = False
                row_mode = ("lexical-fallback"
                            if (semantic and not sem_scores) else "lexical")
            bd = similarity.facet_breakdown(my_card, other_card)
            pct = round(final01 * 100)
            vals = {
                "overall": pct,
                "lexical": round(lex01 * 100),
                "semantic": sem_pct,
                "band": similarity._band(pct),
                "mode": row_mode,
                "evidence": similarity._evidence_line(bd)[:255],
                "why": why,
                "computed_on": now,
            }
            if prior_row:
                prior_row.write(vals)
            else:
                Sim.create(dict(vals, source_id=rec_id, target_id=other.id))
        return True

    def _auto_rank_after_mapping(self, semantic=True):
        """Compute this generator's SOP ranking as part of the tag-extraction
        flow — hybrid (lexical + AI by-meaning), computed ONCE, not via a
        separate button. Runs the paid semantic pass for THIS generator, then
        refreshes every existing peer so the whole library's matrix stays
        hybrid and consistent as the set grows.

        Peer refresh preserves each peer's own semantic score (carry-forward in
        _recompute_similarity) so adding a new SOP re-blends the new column in
        WITHOUT decaying every peer back to lexical — the bug that made the
        library look 'lexical only' after each upload.

        Best-effort: a failure here must NEVER fail tag extraction. The paid pass
        already degrades to lexical internally on a model failure; any unexpected
        error is caught, logged, and swallowed so the SOP still ends up ranked.
        """
        self.ensure_one()
        rec_id = self.id if isinstance(self.id, int) else self._origin.id
        if not isinstance(rec_id, int) or not rec_id:
            return
        my_card = similarity.card_from_prompt(self)
        if not my_card["mapping"]:
            return
        # Peers with a mapping to compare against (and to refresh so their own
        # matrix row now includes THIS newly-mapped generator).
        peers = self.search([("id", "!=", rec_id), ("mapping_json", "!=", False)])
        try:
            self._recompute_similarity(semantic=semantic)
        except Exception as exc:  # noqa: BLE001 - never break tag extraction
            _logger.warning(
                "Auto-rank (self) failed for generator %s; leaving prior rows: %s",
                rec_id, exc)
            try:
                self._recompute_similarity(semantic=False)
            except Exception:  # noqa: BLE001
                return
        for peer in peers:
            try:
                # Carry-forward keeps the peer's prior semantic scores; a fresh
                # lexical pass re-blends them and adds the new generator's column.
                # Free (no model call) because the peer's other semantics persist;
                # only the brand-new pair (peer -> this SOP) starts lexical until
                # the user hits "Re-run AI ranking".
                peer._recompute_similarity(semantic=False)
            except Exception as exc:  # noqa: BLE001
                _logger.warning(
                    "Auto-rank (peer %s) refresh failed: %s", peer.id, exc)

    def action_compute_similarity_semantic(self):
        """PAID: full hybrid re-rank (lexical + AI by-meaning, blended 0.30/0.70)
        for the selected generator(s) against the whole library, then a
        carry-forward refresh of every peer so a newly-added project is blended
        into the library-wide matrix in one action."""
        peers = self.env["assessments.be.prompt"]
        for rec in self:
            rec._recompute_similarity(semantic=True)
            peers |= self.search([("id", "not in", self.ids),
                                   ("mapping_json", "!=", False)])
        for peer in peers:
            try:
                peer._recompute_similarity(semantic=False)
            except Exception as exc:  # noqa: BLE001
                _logger.warning(
                    "Re-run AI ranking peer %s refresh failed: %s", peer.id, exc)
        return self._similarity_notification(
            _("Hybrid ranking refreshed (lexical + AI by-meaning) across the "
              "library."))

    def _similarity_notification(self, message):
        # Ranking is recomputed INLINE, so chain a reload after the toast — the
        # leaderboard / matrix on the open form is otherwise stale until the
        # admin refreshes by hand (same inline-action problem as Extract Tags).
        # 'reload' (not 'soft_reload'): soft_reload restores the CACHED record.
        return {
            "type": "ir.actions.client",
            "tag": "display_notification",
            "params": {"title": _("SOP Similarity"), "message": message,
                       "type": "success", "sticky": False,
                       "next": {"type": "ir.actions.client",
                                "tag": "reload"}},
        }

    @api.depends("tasks_json")
    def _compute_task_count(self):
        for rec in self:
            rec.task_count = len(parse_task_registry(rec.tasks_json))

    @api.depends("mapping_json", "plain_tags")
    def _compute_similar_count(self):
        threshold = self._similarity_min_pct()
        for rec in self:
            if not rec.mapping_json:
                rec.similar_count = 0
                continue
            rec.similar_count = sum(
                1 for sim in rec._similar_prompts(limit=None)
                if sim["pct"] >= threshold)

    @staticmethod
    def _simrank_facet_class(facet):
        known = {"task", "domain", "skill", "modality", "output-format"}
        p = (facet or "").strip().lower()
        return "etp-simrank-tag--%s" % p if p in known else ""

    @staticmethod
    def _simrank_band_class(band):
        return "etp-simrank-band--%s" % (band or "").replace("-", "")

    def _simrank_empty(self, message):
        return Markup(
            '<div class="etp-simrank etp-simrank-empty">'
            '<i class="fa fa-project-diagram"></i>'
            '<span>{msg}</span></div>'
        ).format(msg=escape(message))

    @api.depends("mapping_json", "plain_tags")
    def _compute_similar_html(self):
        for rec in self:
            if not rec.id or not rec.mapping_json:
                rec.similar_html = rec._simrank_empty(
                    "Extract the SOP tags (faceted mapping) to see how this "
                    "project aligns with previous ones.")
                continue
            matches = rec._similar_prompts(limit=8)
            if not matches:
                rec.similar_html = rec._simrank_empty(
                    "No aligned projects yet - no other generator shares "
                    "this SOP's faceted mapping.")
                continue
            rows = Markup("")
            for i, match in enumerate(matches):
                other = match["prompt"]
                pct = max(0, min(100, match["pct"]))
                rank = i + 1
                rank_cls = " etp-simrank-rank--top" if rank <= 3 else ""
                # Shared entries are "facet:value" lexical evidence (e.g.
                # "domain:image-evaluation"); each becomes a pill coloured by
                # its facet.
                pills = Markup("")
                for shared in match["shared"][:6]:
                    facet = shared.split(":", 1)[0] if ":" in shared else ""
                    value = shared.split(":", 1)[1] if ":" in shared else shared
                    pills += Markup(
                        '<span class="etp-simrank-tag {cls}">{label}</span>'
                    ).format(
                        cls=rec._simrank_facet_class(facet),
                        label=escape(value))
                reason = match["why"] or match["evidence"]
                sem = ("" if match["semantic_pct"] is None
                       else " / sem %d%%" % match["semantic_pct"])
                rows += Markup(
                    '<div class="etp-simrank-row">'
                    '<span class="etp-simrank-rank{rank_cls}">{rank}</span>'
                    '<div class="etp-simrank-main">'
                    '<div class="etp-simrank-top">'
                    '<a class="etp-simrank-name" href="{href}">{name}</a>'
                    '<span class="etp-simrank-pct">{pct}%</span>'
                    '</div>'
                    '<div class="etp-simrank-bar">'
                    '<span class="etp-simrank-fill" style="width:{pct}%"></span>'
                    '</div>'
                    '<div class="etp-simrank-meta">'
                    '<span class="etp-simrank-badge {band_cls}">{band}</span>'
                    '<span class="etp-simrank-split">lex {lex}%{sem}</span>'
                    '</div>'
                    '<div class="etp-simrank-tags">{pills}</div>'
                    '<div class="etp-simrank-why">{reason}</div>'
                    '</div></div>'
                ).format(
                    rank_cls=rank_cls, rank=rank,
                    href=escape(
                        "/web#id=%d&model=assessments.be.prompt"
                        "&view_type=form" % other.id),
                    name=escape(other.name or "Untitled"),
                    pct=pct, band=escape(match["band"]),
                    band_cls=rec._simrank_band_class(match["band"]),
                    lex=match["lexical_pct"], sem=escape(sem),
                    pills=pills, reason=escape(reason))
            rec.similar_html = Markup(
                '<div class="etp-simrank">{}</div>').format(rows)

    def action_view_similar(self):
        self.ensure_one()
        threshold = self._similarity_min_pct()
        ids = [sim["prompt"].id
               for sim in self._similar_prompts(limit=None)
               if sim["pct"] >= threshold]
        return {
            "type": "ir.actions.act_window",
            "name": "Generators Similar to %s" % (self.name or ""),
            "res_model": "assessments.be.prompt",
            "domain": [("id", "in", ids)],
            "view_mode": "list,form",
            "views": [
                (self.env.ref(
                    "assessments_be_v2."
                    "assessments_be_prompt_similar_tree").id, "list"),
                (False, "form"),
            ],
            "target": "current",
            "help": (
                "<p class='o_view_nocontent_smiling_face'>No similar generators"
                "</p><p>Similarity ranks other generators by the hybrid "
                "0.30 lexical + 0.70 semantic overlap of the SOP's faceted "
                "mapping.</p>"),
        }

    def action_normalize_tags(self):
        """Fix the tag vocabulary AND evolve the shared knowledge base.

        Two stages, so the knowledge base gets BETTER every time a project is
        added and this is run:
          1. CONSOLIDATE the whole live vocabulary (LLM clusters true synonyms,
             merges drift onto one canonical key, and refreshes every readable
             display) — data-driven, no hardcoded synonym map.
          2. RE-EXTRACT the selected generators against that cleaned vocabulary,
             so their tags + knowledge profile snap onto the shared canonical
             values. Cleaner shared vocabulary -> the NEXT project's extraction
             converges on it too -> similarity ranking and future assessments
             keep improving as projects accumulate.
        """
        from ..services import vertex
        # Stage 1: consolidate the shared vocabulary (once, globally).
        consolidated = {}
        try:
            consolidated = vertex.consolidate_vocabulary(self.env)
        except vertex.VertexQuotaError:
            consolidated = {"error": "Vertex rate limit (429); tags re-extracted "
                                     "without a consolidation pass this time."}
        except Exception:  # noqa: BLE001 - consolidation is best-effort
            _logger.exception("Vocabulary consolidation failed")
            consolidated = {"error": "consolidation step failed (see logs)"}

        # Stage 2: re-extract the selected generators onto the cleaned vocabulary.
        targets = self.filtered(
            lambda p: p.resource_ids.filtered(lambda r: r.category == "sop")
            or (p.source_text or "").strip())
        skipped = len(self) - len(targets)
        targets._queue_tag_extract()
        for prompt in targets:
            prompt._log_activity(Markup(
                "<b>Normalize Tags</b> - queued for re-extraction onto the "
                "cleaned shared vocabulary."))

        parts = []
        if consolidated.get("merged_groups") or consolidated.get("displays_updated"):
            parts.append(
                "Vocabulary tidied: %d duplicate group(s) merged, %d tag(s) "
                "absorbed, %d readable name(s) refreshed."
                % (consolidated.get("merged_groups", 0),
                   consolidated.get("tags_absorbed", 0),
                   consolidated.get("displays_updated", 0)))
        elif consolidated.get("error"):
            parts.append(consolidated["error"])
        parts.append("%d generator(s) queued for re-extraction; their tags "
                     "refresh in the background." % len(targets))
        if skipped:
            parts.append("%d skipped (no SOP document)." % skipped)
        return {
            "type": "ir.actions.client",
            "tag": "display_notification",
            "params": {
                "title": "Tags Normalized & Knowledge Base Refreshed",
                "message": " ".join(parts),
                "type": "success",
                "sticky": False,
            },
        }

    @api.model
    def action_backfill_all_tags(self):
        """Queue tag EXTRACTION on every generator that has none yet.

        A maintenance sweep across the whole table, and `@api.model` because
        it deliberately ignores the recordset it is called on. It is NOT the
        per-generator action behind "Backfill onto questions" - that is
        [action_backfill_tags_to_questions] below, and the two were wired to
        the same route for a while, so the button applied nothing to any
        question and did not act on the generator it was pressed from.
        """
        prompts = self.search([
            ("tag_extract_state", "in", ("idle", "failed")),
            ("tag_ids", "=", False),
            ("resource_ids.category", "=", "sop"),
        ])
        prompts._queue_tag_extract()
        return {
            "type": "ir.actions.client",
            "tag": "display_notification",
            "params": {
                "title": "Tag Backfill Queued",
                "message": "%d generator(s) queued. The drainer works through "
                           "them a couple at a time, so a large backfill "
                           "settles over several minutes." % len(prompts),
                "type": "success", "sticky": False,
            },
        }

    def action_backfill_tags_to_questions(self):
        """Copy THIS generator's tags onto the questions it authored.

        Questions approved into the bank before extraction ran - or before
        `question.tag_ids` existed at all - carry nothing, so the bank cannot be
        searched by the very skills the SOP was read for.

        A UNION, never a replacement: a reviewer who narrowed a question's
        coverage by hand made a real editorial decision, and a maintenance sweep
        must not quietly undo it. That also makes the action idempotent, which
        is what lets it be a plain button.

        Retired questions are included on purpose - retirement takes a question
        out of the bank, not out of history, and it can be restored.

        No LLM call: a copy between two records that both already exist, so it
        is safe to press repeatedly and does not go through the extraction
        queue.
        """
        Question = self.env["assessments.be.question"]
        tagged = 0
        skipped_untagged = 0

        for prompt in self:
            if not prompt.tag_ids:
                # Nothing to copy. Counted rather than raised: a caller may
                # hold several generators and one of them having no vocabulary
                # is not a reason to refuse the others.
                skipped_untagged += 1
                continue
            questions = Question.with_context(active_test=False).search([
                ("generator_id", "=", prompt.id),
            ])
            for question in questions:
                missing = prompt.tag_ids - question.tag_ids
                if not missing:
                    continue
                question.tag_ids = [(4, tag.id) for tag in missing]
                tagged += 1

        # NARROW EACH QUESTION TO THE ONE SKILL IT TESTS.
        #
        # The copy above is deliberately a union - right for bank search, wrong
        # for scoring: with every skill on every question each category scores
        # the same and the strengths/weaknesses card cannot separate a
        # candidate's pre-shift-inspection from their load-handling. This narrows
        # `skill:` only, leaves the other facets alone, and leaves any question
        # it cannot label exactly as the copy left it.
        for prompt in self:
            try:
                # Imported here, not at module scope, matching every other call
                # site in this file - the service pulls httpx and the credential
                # stack, which the ORM does not need to load a view.
                from ..services import vertex
                narrowed = vertex.assign_question_skills(self.env, prompt)
                if narrowed:
                    prompt._log_activity(Markup(
                        "<b>Primary skill assigned</b> - %d question(s) narrowed "
                        "to the single skill they test." % narrowed))
            except Exception:  # noqa: BLE001 - tags are already safely copied
                _logger.exception(
                    "primary-skill assignment failed for prompt %s; the "
                    "backfilled union stands.", prompt.id)

        if tagged:
            for prompt in self:
                prompt._log_activity(Markup(
                    "<b>Backfill onto questions</b> - %d question(s) took this "
                    "project's %d skill tag(s)."
                    % (tagged, len(prompt.tag_ids))))

        if skipped_untagged and not tagged:
            message = ("This generator has no skill tags yet. Run Extract "
                       "skills first - there is nothing to copy.")
            tone = "warning"
        elif tagged:
            message = ("%d question(s) updated. Tags already present were "
                       "left alone." % tagged)
            tone = "success"
        else:
            message = "Every question already carries this project's tags."
            tone = "success"

        return {
            "type": "ir.actions.client",
            "tag": "display_notification",
            "params": {
                "title": "Backfill onto questions",
                "message": message,
                "type": tone,
                "sticky": False,
            },
        }


class EtpAssessmentPromptQuestion(models.Model):
    _name = "assessments.be.prompt.question"
    _description = "Prompt Draft Question"
    _order = "id"

    prompt_id = fields.Many2one(
        "assessments.be.prompt", required=True, ondelete="cascade"
    )
    name = fields.Char(string="Title", required=True)
    question_prompt = fields.Text(string="Question Prompt")
    description = fields.Text(
        string="Description",
        help="Optional candidate-facing description. NEVER put options or the "
             "correct answer here - those live in dimensions / the answer key.")
    time_minutes = fields.Integer(string="Time (minutes)", default=0)
    question_type = fields.Selection(
        QUESTION_TYPE_SELECTION,
        default="mcq",
    )
    medium_display = fields.Char(
        string="Medium", compute="_compute_medium_display",
        help="Image for the image question types (Side-by-side Comparison, "
             "Prompt Writing, Annotation) - the only ones that render a "
             "picture; Text otherwise. Derived from the question type.")
    has_revealing_option = fields.Boolean(
        compute="_compute_has_revealing_option",
        help="True when an objective option name embeds its rationale "
             "(\"Image B, because ...\"). Option names are shown to the "
             "candidate, so the rationale must live in the hidden answer key.")
    has_source_reference = fields.Boolean(
        compute="_compute_has_source_reference",
        help="True when the question or its answer key cites the source "
             "material the candidate never sees (\"according to the SOP\", "
             "\"Section 2.1\"). Items must be self-contained.")
    difficulty = fields.Selection(
        DIFFICULTY_SELECTION,
    )
    detection_mode = fields.Selection(
        DETECTION_MODE_SELECTION,
        string="Detection Mode",
        default="object",
        help="image_label: photo (detect objects) vs UI screenshot (detect "
             "clickable UI elements). Copied onto the bank question on approve "
             "so detection uses the right prompt.")
    options_json = fields.Text(string="Options (JSON)")
    correct_answer_json = fields.Text(string="Correct Answer (JSON)")
    # Generation-run tracking ("which questions came from which run I just
    # triggered"): gen_batch is stamped at create time by the SOP gen cron.
    gen_batch = fields.Char(
        string="Generation Run", readonly=True, copy=False, index=True,
        help="Timestamped id of the generation run that produced this draft, so "
             "you can see at a glance which batch each question came from.")
    gen_warnings = fields.Text(
        string="Generation Warnings", readonly=True, copy=False,
        help="Concerns raised about this draft: an unexpected question type, a "
             "reference to the source document, or an unmet shape check. The "
             "draft is kept - approve, edit or reject it.")
    source_template_id = fields.Many2one(
        "assessments.be.task.template", string="From task template",
        ondelete="set null", index=True, readonly=True, copy=False,
        help="The task template this draft was authored from, when the run "
             "asked for that shape. PROVENANCE: without it there is no way to "
             "tell which drafts a template actually produced, so a template "
             "that quietly stopped working looked identical to one that never "
             "ran. Nullable and set-null on delete - a draft outlives the "
             "template it came from.")
    gen_batch_label = fields.Char(
        string="Run", compute="_compute_gen_batch_label", store=True,
        help="Human-friendly label for the generation run (time of the run).")
    solution_json = fields.Text(
        string="Solution / Golden Answer (JSON)", readonly=True, copy=False,
        help="The most correct answer in an ideal worker's voice (research "
             "solutions.answers), stored as historic ground truth and fed to "
             "the subjective judge at score time so it decomposes golden claims "
             "before reading the worker answer.")
    solution_rationale = fields.Text(
        string="Solution Rationale", readonly=True, copy=False,
        help="How the golden answer is known (construction ground truth, the "
             "SOP's own rule, or derivation). Provenance for the answer key.")
    covers_elements_json = fields.Text(
        string="Covers Elements (JSON)",
        help="Required-element ids (from the SOP metadata) this question's "
             "scenario uniquely exercises. Research schema 1.5 coverage; "
             "threaded to scoring so SOP-Coverage grades against real elements.")
    dimensions_json = fields.Text(
        string="Dimensions (JSON)",
        help="General multi-dimension answer key: a JSON list of "
             '{"label", "options":[..], "correct":[..]} objects. Used by '
             "image_ab (and any multi-objective question). When present it "
             "supersedes options_json/correct_answer_json. ``correct`` entries "
             "may be option strings OR 0-based indices into ``options``.")
    rubric_json = fields.Text(string="Rubric (JSON)")
    behavioural_key_json = fields.Text(
        string="Behavioural Key (JSON)", copy=False,
        help="image_label answer key: a JSON list of {number, element, "
             "functionality} grading the ACTION each numbered box performs. "
             "Written at render from the ONE box list (named boxes placed by "
             "vision, else detections, else the live capture's own list) - the "
             "same list as label_boxes_json, the rubric and the golden answer. "
             "Copied onto the 'single' bank image on approve.")
    label_boxes_json = fields.Text(
        string="Label Boxes (JSON)", copy=False,
        help="image_label box geometry of the ONE box list: {number, box_2d, "
             "label, description} in the 0-1000 grid. Holds the generator's "
             "approximate box_2d until the render replaces it with where vision "
             "placed each box (a live capture stores its DOM manifest here). "
             "Drawn onto the bank image at approve.")
    defect_plan_json = fields.Text(
        string="Defect Plan (JSON)", copy=False,
        help="image_label DEFECT form (q7r): a JSON object {base_prompt, "
             "defects:[{marker, kind, op, spec, marker_xy, flaw}]}. The pipeline "
             "renders a CLEAN base image from base_prompt, then PLANTS each defect "
             "deterministically with PIL at a known pixel and stamps the numbered "
             "marker on the ACTUAL drawn region (defect_render.plant) so the answer "
             "key is true by construction and no marker lands on empty space.")
    coverage_expected = fields.Selection(
        [("yes", "Yes"), ("no", "No")],
        string="Coverage Expected", copy=False,
        help="image_label DENSE coverage gate ground truth: 'no' when the brief "
             "deliberately leaves one interactive element un-boxed, else 'yes'. "
             "Copied onto the bank image on approve.")
    omitted_element_json = fields.Text(
        string="Omitted Element (JSON)", copy=False,
        help="image_label DENSE: the deliberately un-boxed element backing a "
             "coverage:No gate, copied onto the bank image on approve.")
    label_application = fields.Char(
        string="Label Application", copy=False,
        help="image_label DENSE: the app/site the screenshot depicts, copied "
             "onto the bank image on approve and graded as one identification "
             "checklist point.")
    label_expected_count = fields.Integer(
        string="Expected Labels", default=0, copy=False,
        help="image_label: how many boxes a COMPLETE answer labels, carried "
             "off the task template's 'any THREE of these five' and copied "
             "onto the bank image on approve. It has to travel with the draft "
             "rather than be re-read from the template at approve time: a "
             "draft outlives the template it came from "
             "(source_template_id is ondelete='set null'), and an examiner "
             "retuning the count next month must not silently re-grade the "
             "questions already approved from it. 0 means derive it from the "
             "key, which is what every draft authored before this field "
             "existed does.")
    source_url = fields.Char(
        string="Source URL", copy=False,
        help="image_label LIVE-PAGE CAPTURE, only for a generator with "
             "'Screenshot live websites' on (dropped at draft build otherwise): "
             "a stable public page URL, screenshotted at render. If the capture "
             "fails or shows an error/bot page, the AI-made picture is used and "
             "the draft says so. Copied onto the 'single' bank image on approve "
             "only when the approved picture IS that capture.")
    capture_config_json = fields.Text(
        string="Capture Config (JSON)", copy=False,
        help='image_label capture directives {"viewport","wait_ms","dismiss"} '
             "copied onto the bank image on approve and threaded into the live "
             "capture (settle delay + cookie/consent dismissal).")
    omit_spec_json = fields.Text(
        string="Omit Spec (JSON)", copy=False,
        help="image_label capture directive that leaves ONE interactive element "
             'deliberately unboxed so the coverage answer is "No" by '
             "construction; copied onto the bank image on approve.")
    official_reasoning = fields.Text(
        string="Official Reasoning",
        help="image_ab: the official rationale the LLM grades the candidate's "
             "justification against.")
    flaw_plan_json = fields.Text(
        string="Flaw Plan (JSON)",
        help="image_ab flaw-injection plan: {faithful_side, worker_prompt, "
             "render_prompts:{a,b}, planted:{a,b}, construction_keys} (the older "
             "flawed_side/clean_prompt/flawed_prompt/injected_flaws shape is also "
             "accepted). The answer key is DERIVED from construction_keys "
             "(ground-truth by construction). "
             "Surfaced read-only so a reviewer can eyeball the FLAWED image "
             "against injected_flaws before approving; copied to the bank "
             "question on approve, where a key-drift guard hard-fails on any "
             "mismatch. Empty for non-flaw / pre-Phase-3 drafts (guards no-op).")
    verification_json = fields.Text(
        string="Flaw Verification (JSON)", copy=False,
        help="Phase-3 render QA for image_ab: per-side record of whether each "
             "planted flaw was VISIBLY confirmed in the rendered image and how "
             "many times that side was re-rendered. needs_review=true means a "
             "planted flaw never rendered after the bounded retries, so the "
             "construction key it backs is not justified by the pixels and "
             "approval is blocked until it is fixed. Empty when verification is "
             "disabled, unavailable (Vertex down / no creds), or the draft has "
             "no image_ab flaw plan.")
    images_json = fields.Text(
        string="Images (JSON)",
        # NOT PREFETCHED. This column holds RENDERED BASE64 IMAGES: measured on
        # both databases, 213 MB across 147 rows, averaging 3.8 MB a row with
        # the largest at 5.5 MB. Odoo prefetches every stored field of a
        # recordset on the first field read, so reading a draft's `name` -
        # nothing to do with images - dragged the whole 213 MB through the
        # cursor: timed at 32.8 SECONDS for the 86 rows of the review queue,
        # and `GET /api/v1/drafts` took 73 s cold for a payload that never
        # contains this field. Excluding it from the prefetch group means it is
        # fetched only when something genuinely reads it.
        prefetch=False,
        help='JSON list of {"slot","label","url" | "data"} image specs. URLs '
             "(or base64 data) are uploaded to S3 on approve when S3 is "
             "configured, else the URL is stored as-is / the binary kept on "
             "the record.")
    image_brief_json = fields.Text(
        string="Image Briefs (JSON)",
        help='JSON list of {"slot","label","prompt"} render briefs produced by '
             "the text model. The image model renders these on demand "
             "(Generate / Regenerate). Editable so Growth can tweak a brief "
             "before regenerating.")
    video_brief_json = fields.Text(
        string="Video Briefs (JSON)",
        help='video_prompt twin of image_brief_json: a JSON list of '
             '{"slot","label","prompt"} clip briefs (reference + output, or a '
             "single clip) authored by the text model. The clips are uploaded by "
             "an admin (Phase 1) or generated by Veo (Phase 3); nothing renders "
             "from these at generation time.")
    video_state = fields.Selection(
        [
            ("none", "No Video Needed"),
            ("pending", "Video Pending"),
            ("generating", "Generating"),
            ("rendered", "Video Rendered"),
            ("partial", "Partly Generated"),
            ("failed", "Generation Failed"),
            ("cancelled", "Generation Cancelled"),
        ],
        default="none", string="Video State", copy=False,
        help="video_prompt async Veo lifecycle: pending = briefs exist, waiting "
             "to submit (or Veo not configured, so the admin uploads clips); "
             "generating = Veo ops submitted, polling; rendered = every clip is "
             "back and staged; partial = at least one clip is back and viewable "
             "while another failed (retry only re-attempts the failed one); "
             "failed = no clip survived. The config gate keeps it 'pending' "
             "when Veo/creds are absent so the Phase-1 upload path fully works.")
    video_op_json = fields.Text(
        string="Video Op State (JSON)", copy=False,
        help="Per-slot Veo long-running op state: {slot: {op_name, state, "
             "attempts, label}}. Persisted before video_state flips to "
             "'generating' so a killed worker resumes without double-submitting "
             "an op (idempotency handle).")
    video_files_json = fields.Text(
        string="Video Files (JSON)", copy=False,
        help='video twin of images_json: a JSON list of {"slot","label","url"|'
             '"data"} clips staged by the poll cron, materialized to '
             "question.video rows on approve.")
    video_error = fields.Char(
        string="Video Error", copy=False,
        help="The error that failed the last Veo generation attempt, surfaced "
             "so a reviewer can fix the brief or fall back to upload.")
    video_error_short = fields.Char(
        string="Video Error (short)", compute="_compute_video_error_short",
        help="A few-word label for the failure, shown beside Retry Video "
             "Generation. The full text stays in video_error / the log.")
    image_state = fields.Selection(
        [
            ("none", "No Images Needed"),
            ("pending", "Images Pending"),
            ("rendered", "Images Rendered"),
            ("uploaded", "Image Uploaded"),
            ("failed", "Render Failed"),
            ("cancelled", "Render Cancelled"),
        ],
        default="none", string="Image State", copy=False,
        help="Lifecycle of this draft's images: pending = briefs exist but no "
             "picture yet; rendered = the image model produced them; uploaded "
             "= Growth supplied their own; failed = a render attempt failed; "
             "cancelled = an admin killed the generator before the render ran, "
             "so the draft is kept and its picture was never paid for.")
    image_error = fields.Char(
        string="Image Error", copy=False, readonly=True,
        help="Why the image could not be rendered when no retry can fix it "
             "(the AI model is not configured), shown on the review card.")
    image_render_attempts = fields.Integer(
        default=0, copy=False,
        help="How many times the render cron has tried this draft. A 429 quota "
             "hit does NOT count; only genuine partial/failed renders do, so a "
             "draft flips to 'failed' after the cap instead of retrying forever.")
    upload_image = fields.Binary(
        string="Upload Replacement Image", attachment=True,
        help="Upload your own image when a generated one is wrong. Pick the "
             "slot, attach the file, then use 'Apply Uploaded Image'.")
    upload_slot = fields.Char(
        string="Upload Slot", default="a",
        help="Which slot the uploaded image replaces (a / b for A/B, or "
             "single / reference / output for prompt-labelling).")
    state = fields.Selection(
        [
            ("draft", "Pending"),
            ("approved", "Approved"),
            ("denied", "Denied"),
        ],
        default="draft",
    )
    approved_question_id = fields.Many2one(
        "assessments.be.question", string="Bank Question", readonly=True
    )
    answer_dimension_ids = fields.One2many(
        "assessments.be.prompt.question.dimension", "draft_id",
        string="Answer Key")
    ak_ideal_answer = fields.Text(
        string="Ideal Answer", compute="_compute_answer_key_fields",
        inverse="_inverse_answer_key_fields",
        help="image_prompt/image_label: the ideal prompt or labels the candidate "
             "is graded against.")
    ak_mandatory_elements = fields.Text(
        string="Mandatory Elements", compute="_compute_answer_key_fields",
        inverse="_inverse_answer_key_fields",
        help="One per line. Elements the answer MUST contain.")
    ak_penalty_rules = fields.Text(
        string="Penalty Rules", compute="_compute_answer_key_fields",
        inverse="_inverse_answer_key_fields", help="One per line.")
    ak_scoring_guide = fields.Text(
        string="Scoring Guide", compute="_compute_answer_key_fields",
        inverse="_inverse_answer_key_fields")
    ak_checklist = fields.Text(
        string="Checklist", compute="_compute_answer_key_fields",
        inverse="_inverse_answer_key_fields",
        help="subjective_rubric: one required point per line.")
    ak_constraints = fields.Text(
        string="Constraints", compute="_compute_answer_key_fields",
        inverse="_inverse_answer_key_fields", help="One per line.")
    ak_pass_condition = fields.Text(
        string="Pass Condition", compute="_compute_answer_key_fields",
        inverse="_inverse_answer_key_fields")
    dimensions_preview = fields.Html(
        string="Answer Key Preview", compute="_compute_previews",
        sanitize=False)
    image_preview = fields.Html(
        string="Images", compute="_compute_previews", sanitize=False)
    # NOT on `_compute_previews`: see `_compute_has_images`. This flag is a LIST
    # field (a review-queue badge, and a key on every /api/v1/drafts row) while
    # the previews are form-view HTML, so sharing the compute charged the badge
    # the price of parsing 3.8 MB of base64 a row.
    has_images = fields.Boolean(compute="_compute_has_images")
    has_dimensions = fields.Boolean(compute="_compute_previews")
    video_preview = fields.Html(
        string="Video Clips", compute="_compute_video_preview", sanitize=False)
    has_video_clips = fields.Boolean(compute="_compute_video_preview")
    has_assets = fields.Boolean(
        string="Assets", compute="_compute_has_assets",
        help="This draft carries a rendered visual asset - an image OR a "
             "video clip.")
    generation_status = fields.Selection(
        [
            ("in_progress", "In Progress"),
            ("finished", "Finished"),
            ("failed", "Failed"),
        ],
        string="Generation Status", compute="_compute_generation_status",
        help="Whether this draft's ASSET generation finished. A text question "
             "needs no asset, so it is Finished as soon as it exists. An "
             "image/video draft is In Progress while a render or Veo op is "
             "outstanding, and Failed if one gave up past its attempt cap "
             "(use Retry Video Generation on the draft). Distinct from State, "
             "which is the review verdict (Pending / Approved / Denied).")
    image_summary = fields.Char(
        string="Image Files", compute="_compute_image_summary",
        help="Human-readable summary of the stored images (slot, label, size). "
             "The raw base64 image data is never shown in the UI.")

    @api.depends("has_images", "has_video_clips")
    def _compute_has_assets(self):
        for rec in self:
            rec.has_assets = bool(rec.has_images or rec.has_video_clips)

    @api.depends("image_state", "video_state")
    def _compute_generation_status(self):
        for rec in self:
            if rec.image_state == "failed" or rec.video_state == "failed":
                rec.generation_status = "failed"
            elif (rec.image_state == "pending"
                    or rec.video_state in ("pending", "generating")):
                rec.generation_status = "in_progress"
            else:
                # 'none' (no asset needed), 'rendered', 'partial' (usable clips
                # are staged; the reviewer decides whether to retry the rest)
                # or 'uploaded'.
                rec.generation_status = "finished"

    @api.depends("video_error", "video_op_json", "video_state")
    def _compute_video_error_short(self):
        """Collapse the failure to a glanceable label for the form.

        Prefer the raw PER-SLOT error over the composed draft-level summary:
        the summary is a full sentence built for the tooltip, so shortening it
        would just truncate prose, while the slot error is the actual API text
        the classifier is built to recognise.
        """
        from ..services import vertex
        for rec in self:
            if rec.video_state not in ("failed", "partial"):
                rec.video_error_short = False
                continue
            raw = ""
            for op in (rec._video_ops() or {}).values():
                if isinstance(op, dict) and op.get("state") == "failed" \
                        and op.get("error"):
                    raw = op["error"]
                    break
            rec.video_error_short = vertex.short_video_error(
                raw or rec.video_error or "")

    @api.depends("question_type", "approved_question_id.video_ids.media_kind")
    def _compute_medium_display(self):
        for rec in self:
            # Video was missing from this entirely, so every `video_prompt`
            # draft reported its medium as "Text" - on any client reading the
            # field - directly above a staged clip. Three media exist and
            # MEDIUM_SELECTION has named all three all along. A clip that is
            # audio (`question.video.media_kind`) reads "Audio".
            if rec.question_type in VIDEO_QUESTION_TYPES:
                kinds = set(rec.approved_question_id.video_ids.mapped(
                    "media_kind"))
                rec.medium_display = "Audio" if kinds == {"audio"} else "Video"
            elif rec.question_type in IMAGE_QUESTION_TYPES:
                rec.medium_display = "Image"
            else:
                rec.medium_display = "Text"

    @api.depends("gen_batch", "create_date")
    def _compute_gen_batch_label(self):
        """Human label for the generation run. Falls back to the create date so
        older drafts (no gen_batch) still group sensibly."""
        for rec in self:
            if rec.gen_batch:
                raw = rec.gen_batch
                try:
                    from datetime import datetime
                    dt = datetime.strptime(raw[:15], "%Y%m%d-%H%M%S")
                    rec.gen_batch_label = "Run " + dt.strftime("%b %d, %H:%M")
                except Exception:  # noqa: BLE001
                    rec.gen_batch_label = "Run " + raw
            elif rec.create_date:
                rec.gen_batch_label = "Run " + rec.create_date.strftime(
                    "%b %d, %H:%M")
            else:
                rec.gen_batch_label = "Run"

    @api.depends("question_type", "options_json",
                 "answer_dimension_ids.option_line_ids.name")
    def _compute_has_revealing_option(self):
        for rec in self:
            flag = False
            if rec.question_type in ("mcq", "msq"):
                names = rec.answer_dimension_ids.option_line_ids.mapped("name")
                if not names and rec.options_json:
                    try:
                        names = json.loads(rec.options_json) or []
                    except (ValueError, TypeError):
                        names = []
                flag = any(option_name_reveals_reasoning(n) for n in names)
            rec.has_revealing_option = flag

    @api.depends("question_prompt", "official_reasoning", "options_json",
                 "rubric_json", "answer_dimension_ids.option_line_ids.name")
    def _compute_has_source_reference(self):
        # The options as edited: a save rewrites the option rows, never
        # `options_json`, so the JSON is read only for a draft with no rows.
        for rec in self:
            names = rec.answer_dimension_ids.option_line_ids.mapped("name")
            rec.has_source_reference = text_has_source_reference(
                rec.question_prompt, rec.official_reasoning,
                " ".join(names) if names else rec.options_json,
                rec.rubric_json)

    @api.depends("images_json")
    def _compute_image_summary(self):
        import json as _json
        for rec in self:
            raw = (rec.images_json or "").strip()
            if not raw or raw in ("[]", "{}"):
                rec.image_summary = False
                continue
            try:
                specs = _json.loads(raw)
            except (ValueError, TypeError):
                rec.image_summary = "unparseable images_json"
                continue
            if isinstance(specs, dict):
                specs = [specs]
            parts = []
            for s in (specs or []):
                if not isinstance(s, dict):
                    continue
                src = s.get("data") or s.get("url") or ""
                if isinstance(src, str) and src.startswith("data:"):
                    kb = max(1, int(len(src) * 0.75 / 1024))
                    where = "rendered ~%dKB" % kb
                elif src:
                    where = "url"
                else:
                    where = "empty"
                parts.append("%s/%s [%s]" % (
                    s.get("slot") or "?", s.get("label") or "", where))
            rec.image_summary = "; ".join(parts) if parts else False

    @api.depends("images_json")
    def _compute_has_images(self):
        """Whether a draft carries an image spec, WITHOUT reading the specs.

        Split out of `_compute_previews`, which parses `images_json` to build
        an HTML gallery. That gallery is a form-view field; `has_images` is a
        LIST field - the review queue renders a badge from it and
        `GET /api/v1/drafts` puts it on every row. Sharing one compute made the
        cheap flag cost the expensive parse: measured at 126.9 SECONDS for the
        86 rows of the queue, because the column averages 3.8 MB of rendered
        base64 a row.

        The rule itself is unchanged - a spec counts when it carries one of the
        five source keys the gallery accepts - so this is the same answer for
        the same rows, verified equal on all 147 of them. What it no longer
        does is build an HTML `<figure>` per image, escape it, and resolve
        `_dimension_specs()` for the answer-key preview beside it. Measured:
        126.9 s to 2.7 s over the whole table.

        PUSHING THE TEST INTO POSTGRES WAS TRIED AND IS WORSE, which is why it
        is not here: `json_array_elements` over the column makes the server
        parse the same 213 MB, and it timed at 61.6 s against 2.7 s for this
        loop. The payload has to be read either way; the saving is in not
        rendering it.
        """
        for rec in self:
            rec.has_images = any(
                s.get("annotated_url") or s.get("annotated_data")
                or s.get("url") or s.get("src") or s.get("data")
                for s in rec._image_specs())

    @api.depends("dimensions_json", "options_json", "correct_answer_json",
                 "images_json", "question_type",
                 "answer_dimension_ids.label",
                 "answer_dimension_ids.sequence",
                 "answer_dimension_ids.option_line_ids.name",
                 "answer_dimension_ids.option_line_ids.is_correct")
    def _compute_previews(self):
        import html as _html
        for rec in self:
            specs = rec._dimension_specs()
            if specs:
                blocks = []
                for spec in specs:
                    correct = {c.strip().casefold() for c in spec["correct"]}
                    opts = []
                    for o in spec["options"]:
                        is_c = o.strip().casefold() in correct
                        cls = ("badge text-bg-success" if is_c
                               else "badge text-bg-light border")
                        mark = " \u2713" if is_c else ""
                        style = ("margin:3px;font-size:0.95rem;"
                                 "padding:0.45em 0.7em;font-weight:%s"
                                 % ("600" if is_c else "400"))
                        opts.append(
                            f'<span class="{cls}" style="{style}">'
                            f'{_html.escape(o)}{mark}</span>')
                    blocks.append(
                        f'<div class="mb-2"><strong style="font-size:0.95rem">'
                        f'{_html.escape(spec["label"])}</strong><br/>'
                        f'{"".join(opts)}</div>')
                rec.dimensions_preview = "".join(blocks)
                rec.has_dimensions = True
            else:
                rec.dimensions_preview = False
                rec.has_dimensions = False
            imgs = []
            raw = (rec.images_json or "").strip()
            if raw and raw not in ("[]", "{}"):
                try:
                    parsed = __import__("json").loads(raw)
                except (ValueError, TypeError):
                    parsed = []
                if isinstance(parsed, dict):
                    parsed = [parsed]
                for spec in (parsed or []):
                    if not isinstance(spec, dict):
                        continue
                    # Route the preview through the admin proxy (presigns private
                    # S3, streams inline base64) instead of embedding the raw spec
                    # URL - an offloaded draft image carries a private-bucket URL
                    # that 403s if the browser loads it directly (the video twin
                    # already serves via /admin_draft_qvideo for the same reason).
                    has_src = (spec.get("annotated_url") or spec.get("annotated_data")
                               or spec.get("url") or spec.get("src")
                               or spec.get("data"))
                    if not has_src or not isinstance(rec.id, int):
                        continue
                    slot = str(spec.get("slot") or "single")
                    src = "/assessments_be/admin_draft_qimage/%d/%s" % (
                        rec.id, _html.escape(slot))
                    label = _html.escape(str(
                        spec.get("label") or spec.get("slot") or ""))
                    imgs.append(
                        '<figure style="display:inline-block;margin:6px;'
                        'text-align:center">'
                        '<span class="etp-image-zoomable" tabindex="0" '
                        'role="button" aria-label="Zoom image" '
                        'title="Click to zoom">'
                        f'<img src="{_html.escape(src)}" '
                        'style="max-height:160px;max-width:220px;'
                        'border:1px solid #dee2e6;border-radius:4px"/>'
                        '</span>'
                        f'<figcaption class="text-muted small">{label}'
                        '</figcaption></figure>')
            rec.image_preview = "".join(imgs) if imgs else False

    @api.depends("video_files_json", "question_type")
    def _compute_video_preview(self):
        import html as _html
        for rec in self:
            blocks = []
            if rec.question_type == "video_prompt" and isinstance(rec.id, int):
                for f in rec._video_files():
                    slot = f.get("slot") or "single"
                    if not (f.get("url") or f.get("data")):
                        continue
                    label = _html.escape(str(f.get("label") or slot))
                    src = "/assessments_be/admin_draft_qvideo/%d/%s" % (
                        rec.id, _html.escape(str(slot)))
                    blocks.append(
                        '<figure style="display:inline-block;margin:6px;'
                        'text-align:center;vertical-align:top">'
                        '<video controls preload="metadata" '
                        'style="max-height:220px;max-width:320px;'
                        'border:1px solid #dee2e6;border-radius:4px" '
                        f'src="{src}"></video>'
                        f'<figcaption class="text-muted small">{label}'
                        '</figcaption></figure>')
            rec.video_preview = "".join(blocks) if blocks else False
            rec.has_video_clips = bool(blocks)

    _RUBRIC_STR_KEYS = (("ak_scoring_guide", "scoring_guide"),
                        ("ak_pass_condition", "pass_condition"))
    _RUBRIC_LIST_KEYS = (("ak_mandatory_elements", "mandatory_elements"),
                         ("ak_penalty_rules", "penalty_rules"),
                         ("ak_checklist", "checklist"),
                         ("ak_constraints", "constraints"))

    def _ideal_answer_key(self):
        self.ensure_one()
        # video_prompt too: the grader reads its reference as `ideal_prompt`,
        # and saving under any other name dropped the key it was generated with.
        if self.question_type in ("image_prompt", "video_prompt"):
            return "ideal_prompt"
        if self.question_type == "image_label":
            return "ideal_labels"
        return "ideal_answer"

    @api.depends("rubric_json", "question_type")
    def _compute_answer_key_fields(self):
        import json as _json
        for rec in self:
            try:
                data = _json.loads(rec.rubric_json or "{}")
                if not isinstance(data, dict):
                    data = {}
            except (ValueError, TypeError):
                data = {}
            # An `ideal_answer` saved under the old name still shows, and the
            # next save moves it to the right key.
            rec.ak_ideal_answer = (data.get(rec._ideal_answer_key())
                                   or data.get("ideal_answer") or False)
            for fname, key in rec._RUBRIC_STR_KEYS:
                rec[fname] = data.get(key) or False
            for fname, key in rec._RUBRIC_LIST_KEYS:
                val = data.get(key) or []
                if not isinstance(val, list):
                    val = [val]
                rec[fname] = "\n".join(str(x) for x in val) or False

    def _inverse_answer_key_fields(self):
        import json as _json
        for rec in self:
            try:
                data = _json.loads(rec.rubric_json or "{}")
                if not isinstance(data, dict):
                    data = {}
            except (ValueError, TypeError):
                data = {}
            ideal_key = rec._ideal_answer_key()
            for k in ("ideal_answer", "ideal_prompt", "ideal_labels"):
                if k != ideal_key:
                    data.pop(k, None)
            if (rec.ak_ideal_answer or "").strip():
                data[ideal_key] = rec.ak_ideal_answer
            else:
                data.pop(ideal_key, None)
            for fname, key in rec._RUBRIC_STR_KEYS:
                if (rec[fname] or "").strip():
                    data[key] = rec[fname]
                else:
                    data.pop(key, None)
            for fname, key in rec._RUBRIC_LIST_KEYS:
                items = [ln.strip() for ln in (rec[fname] or "").splitlines()
                         if ln.strip()]
                if items:
                    data[key] = items
                else:
                    data.pop(key, None)
            rec.rubric_json = _json.dumps(data, ensure_ascii=False) if data else False

    def action_approve(self):
        Question = self.env["assessments.be.question"]
        drafts = self.filtered(lambda r: r.state == "draft")
        # A deleted generator is final: nothing new goes into the bank from it.
        if drafts.filtered("prompt_id.deleted"):
            raise UserError(_("These drafts belong to a deleted generator and "
                              "cannot be approved."))
        # An import-only type has no generation/approval path: the
        # _materialize_* calls below never run for one, so approving such a draft
        # would publish a question with no media at all. NON_GENERATABLE_QUESTION_TYPES
        # is empty today, so this never fires - it is kept because the set is the
        # single switch that retires a type from generation, and a hand-edited or
        # legacy draft can carry a type the model itself can no longer emit
        # (constants.GENERATABLE_QUESTION_TYPE_CODES gates the model). Refuse loudly
        # rather than publishing a broken question.
        non_generatable = drafts.filtered(
            lambda r: r.question_type in NON_GENERATABLE_QUESTION_TYPES)
        if non_generatable:
            raise UserError(
                "%s is an import-only question format and cannot be approved "
                "from a generated draft - its media and answer key must come "
                "from an import. Change the type, or import the bank "
                "instead:\n%s"
                % (", ".join(sorted(set(non_generatable.mapped(
                    "question_type")))),
                   "\n".join("- %s" % (r.name or r.question_prompt or "draft")
                             for r in non_generatable)))
        if not self.env.context.get("skip_image_ready_guard"):
            not_ready = drafts.filtered(
                lambda r: r.question_type in IMAGE_QUESTION_TYPES
                and not r._current_images())
            if not_ready:
                raise UserError(
                    "These image questions have no image yet, so approving them "
                    "would publish a question with a missing picture. Wait for "
                    "rendering to finish (or upload an image), then approve:\n%s"
                    % "\n".join("- %s" % (r.name or r.question_prompt or "draft")
                                for r in not_ready))
            # THE SAME GUARD FOR VIDEO, which was missing entirely.
            #
            # Approving a video_prompt draft mid-render published a question
            # with zero question.video rows - the reviewer and the candidate
            # both saw "No video yet for this question." over an answer about
            # a clip nobody could watch, and nothing ever backfilled it because
            # materialisation only happens once, here, at approve time.
            # Shares `skip_image_ready_guard` deliberately: it is one
            # "publish media that is not ready" escape hatch, and a caller that
            # wants to bypass one has always meant both.
            no_clip = drafts.filtered(
                lambda r: r.question_type in VIDEO_QUESTION_TYPES
                and not r._current_videos())
            if no_clip:
                raise UserError(
                    "These video questions have no clip yet, so approving them "
                    "would publish a question with a missing video. Wait for "
                    "generation to finish (or upload a clip), then approve:\n%s"
                    % "\n".join("- %s" % (r.name or r.question_prompt or "draft")
                                for r in no_clip))
        # A KEY NOBODY CAN EARN. One pick per axis (unless msq or checkboxes)
        # against an exact-set match scores every candidate zero. Every lane
        # (generated, template, CSV, harness, sectioned) ends here.
        unearnable = drafts.filtered(lambda r: any(
            len(s["correct"]) > 1
            and takes_one_answer(r.question_type, s.get("kind"))
            for s in r._dimension_specs()))
        if unearnable:
            raise UserError(
                "These drafts mark more than one correct option on an axis "
                "where the candidate picks one, so nobody can earn the mark. "
                "Keep one correct option, or make the axis checkboxes:\n%s"
                % "\n".join("- %s" % (r.name or r.question_prompt or "draft")
                             for r in unearnable))
        for rec in drafts:
            if rec.question_type == "image_ab" and rec.verification_json:
                note = rec._flaw_render_review_note()
                if note:
                    # renderers/ab.py has NO hard verify gate: a planted flaw
                    # that did not visibly render does NOT block the question.
                    # The construction_keys are the by-construction ground
                    # truth; an unconfirmed pixel is an ADVISORY signal, not a
                    # veto. Logged, and verification_json.needs_review stays
                    # visible so a reviewer can eyeball / deny.
                    _logger.warning(
                        "etp_assessment image_ab flaw not visually confirmed for "
                        "%r (approving anyway; construction_keys stand): %s",
                        rec.name or "draft", note)
        for rec in drafts:
            vals = {
                "name": rec.name,
                "prompt": rec.question_prompt or rec.name,
                "question_type": rec.question_type or "mcq",
                "generator_id": rec.prompt_id.id,
                "difficulty": rec.difficulty or False,
                "detection_mode": rec.detection_mode or "object",
                "time_minutes": rec.time_minutes or 0,
                "description": rec.description or False,
                "subjective_rubric_json": rec.rubric_json or False,
                "official_reasoning": rec.official_reasoning or False,
                "flaw_plan_json": rec.flaw_plan_json or False,
                "covers_elements_json": rec.covers_elements_json or False,
                "solution_json": rec.solution_json or False,
                "solution_rationale": rec.solution_rationale or False,
                "verification_json": rec.verification_json or False,
                "source_ref": "gen:%s" % rec.prompt_id.name,
                # CARRY THE TEMPLATE LINK ACROSS THE BANK BOUNDARY.
                #
                # Seventeen fields were copied here and this one was not, so a
                # question that read as the examiner's own task in the review
                # queue ("Verify a single photo edit") reverted to the rendering
                # engine's name ("Image A/B", "Labelling") the moment it was
                # approved - in the Question Bank, the assessment picker,
                # Responses and every attempt view. Provenance died with it:
                # nothing could answer which bank questions a template produced.
                "source_template_id": rec.source_template_id.id or False,
                # APPROVING THE DRAFT IS THE SIGN-OFF.
                #
                # `rubric_reviewed` exists so that no AI-authored marking guide
                # grades a human until a person has read it. That person is the
                # reviewer standing here: they are looking at the rubric on the
                # review card when they approve, and approving is a deliberate
                # act on exactly that content. Asking them to press a SECOND
                # button afterwards recorded no additional judgement - it only
                # produced a bank full of questions flagged "unreviewed" that a
                # human had, in fact, just reviewed.
                #
                # Denying does not reach this line, so a rejected draft never
                # sets it. The flag and the launch gate that reads it both
                # stay: what changes is which action satisfies them.
                "rubric_reviewed": True,
            }
            q = Question.create(vals)
            # EXPAND WHATEVER AXES THE DRAFT ACTUALLY CARRIES, whatever its
            # type. This was a fixed type list, so a template-authored
            # subjective_rubric - six Yes/No checks drawn in Form Studio -
            # reached the bank with its axes still trapped in JSON and the
            # candidate got one free-text box. `_dimension_specs()` already
            # returns nothing when there is nothing to expand, so asking it is
            # both the test and the guard, and a new type needs no edit here.
            if rec._dimension_specs():
                rec._materialize_dimensions(q)
            if rec.question_type == "image_ab" and rec.flaw_plan_json:
                rec._assert_no_key_drift(q)
            if rec.question_type in ("image_ab", "image_prompt", "image_label"):
                rec._materialize_images(q)
            if rec.question_type in VIDEO_QUESTION_TYPES:
                rec._materialize_videos(q)
            if rec.question_type == "image_label":
                rec._apply_authored_label_key(q)
            rec.write({"state": "approved", "approved_question_id": q.id})
        # Batch approval (action_approve_all_drafts) posts ONE rollup for the
        # whole set and passes skip_approval_log so each per-draft call here does
        # not double-log the same event.
        if not self.env.context.get("skip_approval_log"):
            self._log_drafts_to_generators(drafts, "approved")
        return self._decision_notification(drafts, "Approved")

    def _decision_notification(self, acted, verb):
        """Say what Approve Selected / Deny Selected actually did.

        Both act only on `state == 'draft'`, so the skipped count is what tells
        the operator that rows were already decided rather than that the
        button is broken.
        """
        skipped = len(self) - len(acted)
        bits = ["%s %d question(s)." % (verb, len(acted))] if acted else []
        if skipped:
            bits.append("%d were already approved or denied and were left "
                        "alone." % skipped)
        return {
            "type": "ir.actions.client",
            "tag": "display_notification",
            "params": {
                "title": verb if acted else "Nothing to do",
                "message": " ".join(bits) or (
                    "Every question selected had already been approved or "
                    "denied. Nothing changed."),
                "type": "success" if acted else "warning",
                "sticky": False,
                # Reload the generator so the tab, the tally and the review
                # banner all agree with what just happened.
                "next": {"type": "ir.actions.act_window_close"},
            },
        }

    def _log_drafts_to_generators(self, drafts, verb):
        """Roll a per-draft approve/deny up to each parent generator's chatter.
        Drafts selected from the bank list can span several generators, so group
        by prompt_id and post one summary line per generator."""
        by_gen = {}
        for rec in drafts:
            if rec.prompt_id:
                by_gen.setdefault(rec.prompt_id, self.browse())
                by_gen[rec.prompt_id] |= rec
        for generator, recs in by_gen.items():
            titles = ", ".join(
                (r.name or r.question_prompt or "draft")[:60] for r in recs)
            generator._log_activity(Markup(
                "<b>%d draft(s) %s</b>: %s")
                % (len(recs), escape(verb), escape(titles)))

    def _assert_no_key_drift(self, bank_question):
        self.ensure_one()
        keys = ab_construction_keys(self.flaw_plan_json)
        if not keys:
            return
        # The plan's own dimension_labels are what named these dimensions in the
        # first place (via ab_specs_from_construction_keys), so they are what
        # reads the names back. Without them a SOP-numbered dimension stored as
        # "Q1 Instruction Aligned" never matched construction key "Q1" and this
        # guard failed EVERY such question.
        materialized = ab_materialized_keys(
            bank_question.question_dimension_ids, keys,
            parse_flaw_plan(self.flaw_plan_json).get("dimension_labels"))
        drift = ab_key_drift(materialized, keys)
        if drift:
            raise UserError(
                "Key drift: the materialized answer key for %r does not match "
                "its flaw-injection construction keys, so it is no longer "
                "ground-truth - refusing to approve.\n%s"
                % (self.name or "draft", "\n".join(drift)))

    def _flaw_render_review_note(self):
        """Return a human-readable note when a planted image_ab flaw was not
        visibly confirmed in the pixels, else ''. ADVISORY ONLY — the caller logs
        it and leaves verification_json.needs_review visible, but does NOT block
        approval. Research's renderers/ab.py has no verify gate at all; the
        construction_keys are the authored by-construction ground truth, so an
        unconfirmed pixel is a review hint, not a veto (previously this raised and
        dead-locked approval — the 'this should not happen' bug)."""
        self.ensure_one()
        import json as _json
        try:
            rec = _json.loads(self.verification_json or "{}")
        except (ValueError, TypeError):
            return ""
        if not isinstance(rec, dict) or not rec.get("needs_review"):
            return ""
        unconfirmed = []
        for slot, side in (rec.get("sides") or {}).items():
            if not isinstance(side, dict) or side.get("confirmed") \
                    or side.get("unavailable"):
                continue
            for v in side.get("verdicts") or []:
                if isinstance(v, dict) and not v.get("present"):
                    unconfirmed.append("%s: %s" % (slot, v.get("flaw") or "?"))
        return "\n".join(unconfirmed) or "(a planted flaw was not confirmed)"

    def _dimension_specs(self):
        self.ensure_one()
        if self.answer_dimension_ids:
            specs = []
            for d in self.answer_dimension_ids:
                options = [o.name for o in d.option_line_ids if o.name]
                if not options:
                    continue
                correct = [o.name for o in d.option_line_ids
                           if o.is_correct and o.name]
                specs.append({
                    "label": (d.label or self.name or "Answer")[:200],
                    "options": options,
                    "kind": d.input_kind or "",
                    "correct": correct,
                })
            if specs:
                return specs
        return self._specs_from_json()

    def _specs_from_json(self):
        import json as _json
        self.ensure_one()
        specs = []
        raw = (self.dimensions_json or "").strip()
        if raw and raw not in ("[]", "{}"):
            try:
                parsed = _json.loads(raw)
            except (ValueError, TypeError):
                parsed = None
            if isinstance(parsed, dict):
                parsed = [parsed]
            if isinstance(parsed, list):
                for d in parsed:
                    if not isinstance(d, dict):
                        continue
                    options = [str(o) for o in (d.get("options") or [])]
                    correct = self._normalize_correct(
                        d.get("correct"), options)
                    specs.append({
                        "label": (d.get("label") or d.get("key")
                                  or self.name or "Answer")[:200],
                        "options": options,
                        "kind": str(d.get("kind") or ""),
                        "correct": correct,
                    })
            if specs:
                return specs
        try:
            options = _json.loads(self.options_json or "[]")
        except (ValueError, TypeError):
            options = []
        if not isinstance(options, list) or not options:
            return specs
        options = [str(o) for o in options]
        try:
            correct = _json.loads(self.correct_answer_json or "null")
        except (ValueError, TypeError):
            correct = None
        specs.append({
            "label": (self.name or "Answer")[:200],
            "options": options,
            "correct": self._normalize_correct(correct, options),
        })
        return specs

    @staticmethod
    def _normalize_correct(correct, options):
        """String matching must stay ahead of index resolution: an option
        literally named "1" matches by value, not as index 1."""
        if correct is None:
            return []
        if not isinstance(correct, list):
            correct = [correct]
        out = []
        for c in correct:
            if isinstance(c, bool):
                continue
            if isinstance(c, int) and 0 <= c < len(options):
                out.append(options[c])
                continue
            cs = str(c)
            if cs in options:
                out.append(cs)
                continue
            matched = False
            for o in options:
                if o.strip().casefold() == cs.strip().casefold():
                    out.append(o)
                    matched = True
                    break
            if matched:
                continue
            cs_stripped = cs.strip()
            if cs_stripped.lstrip("-").isdigit():
                idx = int(cs_stripped)
                if 0 <= idx < len(options):
                    out.append(options[idx])
        return out

    def _sync_answer_relational_from_json(self):
        for rec in self:
            specs = rec._specs_from_json()
            commands = [(5, 0, 0)]
            for si, spec in enumerate(specs):
                correct = {c.strip().casefold() for c in spec["correct"]}
                opt_cmds = [
                    (0, 0, {"name": o, "sequence": (i + 1) * 10,
                            "is_correct": o.strip().casefold() in correct})
                    for i, o in enumerate(spec["options"])
                ]
                commands.append((0, 0, {
                    "label": spec["label"], "sequence": (si + 1) * 10,
                    "input_kind": spec.get("kind") or "",
                    "option_line_ids": opt_cmds,
                }))
            rec.answer_dimension_ids = commands

    def action_rebuild_answer_key_from_json(self):
        # RECOMPUTE AN A/B KEY FROM THE PLAN, don't re-read the stored JSON.
        #
        # `_sync_answer_relational_from_json` rebuilds the relational dimensions
        # from `dimensions_json` - which is the very field that carries a bad key,
        # so a rebuild faithfully reproduced the same unmarked dimension and the
        # button looked broken. For an image/video A/B the AUTHORED ground truth
        # is `flaw_plan_json.construction_keys`, so regenerate the specs from it
        # first and let the sync materialise those.
        #
        # This is what repairs drafts authored before the forced-choice fix: their
        # plan was always right, only the derived key was wrong.
        for rec in self:
            keys = ab_construction_keys(rec.flaw_plan_json)
            if not keys:
                continue
            plan = parse_flaw_plan(rec.flaw_plan_json)
            specs = ab_specs_from_construction_keys(
                keys, plan.get("dimension_options"),
                plan.get("dimension_labels"))
            if specs:
                rec.dimensions_json = json.dumps(specs, ensure_ascii=False)
        self._sync_answer_relational_from_json()
        return True

    @api.model_create_multi
    def create(self, vals_list):
        records = super().create(vals_list)
        for rec, vals in zip(records, vals_list):
            if rec.answer_dimension_ids:
                continue
            if (vals.get("dimensions_json") or vals.get("options_json")
                    or vals.get("correct_answer_json")):
                rec._sync_answer_relational_from_json()
        return records

    def write(self, vals):
        # Under `stage_render` (the render cron) every write is kept, the
        # nested label, capture and defect writes included, so a lost commit
        # can be written again whole (`_cron_render_pending_images`).
        if self.env.context.get("stage_render"):
            for rec in self:
                _STAGED_RENDERS.setdefault(
                    (self.env.cr.dbname, rec.id), {}).update(vals)
        return super().write(vals)

    @staticmethod
    def _key_matches_option(option, keys):
        """Resolve an answer key against an option label.

        The key is a RESTATEMENT of the option text, produced by the model in a
        separate field, so the two drift: a doubled article ("on a a white
        background"), a curly apostrophe, a trailing full stop. Exact equality
        then marks nothing correct and the question is unscoreable - every
        candidate is wrong whatever they pick.

        Normalise the punctuation and whitespace that carry no meaning, then
        compare. Anything beyond that (a genuinely different sentence) is a real
        mismatch and must stay one.
        """
        import re
        import unicodedata

        def norm(text):
            text = unicodedata.normalize("NFKC", text or "")
            text = text.replace("\u2019", "'").replace("\u2018", "'")
            text = text.replace("\u201c", '"').replace("\u201d", '"')
            text = text.replace("\u2013", "-").replace("\u2014", "-")
            text = re.sub(r"\s+", " ", text).strip().casefold()
            text = text.rstrip(".")
            # A repeated word ("a a", "the the") is a transcription slip, not a
            # different answer.
            text = re.sub(r"\b(\w+) \1\b", r"\1", text)
            return text

        target = norm(option)
        return any(norm(k) == target for k in keys)

    def _materialize_dimensions(self, bank_question):
        """Always create a PRIVATE dimension per question; never look one up by
        name. Questions sharing a label would inherit each other's options, and
        option text is related(store=True) to the master, so editing one master
        option rewrites every question that borrowed it."""
        self.ensure_one()
        QDim = self.env["assessments.be.question.dimension"]
        for spec in self._dimension_specs():
            options = spec["options"]
            if not options:
                continue
            label = spec["label"]
            raw_correct = list(spec["correct"] or [])
            QDim.create({
                "question_id": bank_question.id,
                "name": label,
                # Carry the authored control forward so the exam renders the
                # scale or grid the examiner drew, not a radio list.
                "input_kind": spec.get("kind") or "",
                "option_line_ids": [
                    (0, 0, {
                        "name": o,
                        "sequence": (i + 1) * 10,
                        "is_correct": self._key_matches_option(o, raw_correct),
                    })
                    for i, o in enumerate(options)
                ],
            })
            if not raw_correct:
                # A judgement axis (a 1..5 scale, a rating) has no objectively
                # correct value by design - the LLM judge grades it. Warning
                # about those trains people to ignore this line, so only an
                # OBJECTIVE question missing its key is worth flagging.
                if self.question_type in ("mcq", "msq"):
                    _logger.warning(
                        "Draft %s dim %r: objective question states no answer "
                        "key; every candidate scores zero on it.",
                        self.id, label)
                else:
                    _logger.debug(
                        "Draft %s dim %r: judgement axis, no key expected.",
                        self.id, label)
            elif not any(self._key_matches_option(o, raw_correct)
                         for o in options):
                # The key was stated but matches no option even after
                # normalising. Publishing this fails every candidate silently.
                _logger.warning(
                    "Draft %s dim %r: answer key %r matches none of %r; "
                    "published with no correct option.",
                    self.id, label, raw_correct, options)

    def _materialize_images(self, bank_question):
        import json as _json
        self.ensure_one()
        raw = (self.images_json or "").strip()
        if not raw or raw in ("[]", "{}"):
            return
        try:
            specs = _json.loads(raw)
        except (ValueError, TypeError):
            _logger.warning("Draft %s: images_json not parseable, skipped.",
                            self.id)
            return
        if isinstance(specs, dict):
            specs = [specs]
        if not isinstance(specs, list):
            return
        from ..services import image_ingest
        Image = self.env["assessments.be.question.image"]
        default_slot = "a" if bank_question.question_type == "image_ab" \
            else "single"
        valid_slots = {"a", "b", "single", "reference", "output"}
        slot_aliases = {
            "a": "a", "response a": "a", "resp a": "a", "image a": "a",
            "b": "b", "response b": "b", "resp b": "b", "image b": "b",
            "single": "single", "image": "single", "img": "single",
            "ref": "reference", "reference": "reference",
            "out": "output", "output": "output",
        }

        def _norm_slot(value):
            key = (value or "").strip().lower()
            if key in valid_slots:
                return key
            return slot_aliases.get(key, default_slot)

        for idx, spec in enumerate(specs):
            if not isinstance(spec, dict):
                continue
            slot = _norm_slot(spec.get("slot"))
            label = spec.get("label") or slot.title()
            vals = {
                "question_id": bank_question.id,
                "slot": slot,
                "label": label,
                "sequence": (idx + 1) * 10,
            }
            url, b64 = image_ingest.ingest(
                self.env, spec.get("url") or spec.get("src"),
                spec.get("data"),
                key_hint="qimg-%s-%s" % (bank_question.id, slot))
            if url:
                vals["image_url"] = url
            if b64:
                vals["image"] = b64
            image = Image.create(vals)
            if bank_question.question_type == "image_label" and slot == "single":
                # THE COUNT IS CARRIED HERE, not in _carry_label_capture or
                # _apply_authored_label_key, because this is the one line EVERY
                # labelling lane passes through. Those two each guard on a lane
                # of their own - a live source_url, or an authored dense key -
                # so a question built by the inline detect lane would have got
                # its boxes and not the count, and "any three of these five"
                # would have quietly graded as five again. Only written when
                # set, so a draft carrying 0 leaves the image's own default
                # alone and the denominator stays the key's own box count.
                if self.label_expected_count:
                    image.label_expected_count = self.label_expected_count
                self._carry_label_capture(image)
            self._carry_or_detect_label(bank_question, image, slot, spec)

    def _label_box_cap(self):
        """This draft's box ceiling, read off the generator that authored it.

        A draft always has a generator (`prompt_id` is required), so unlike the
        bank-image resolver this one never has to guess - the default is only
        reached when the field itself is empty, which the model constraint
        already refuses to store.
        """
        self.ensure_one()
        return self.prompt_id.image_label_count or DEFAULT_IMAGE_LABEL_COUNT

    @staticmethod
    def _cap_json_list(raw, limit, what, rec_id):
        """Truncate a JSON list field to `limit`, returning the JSON to store.

        The three label fields (`label_boxes_json`, `behavioural_key_json` and
        the rubric's per-box key) are parallel views of ONE numbered list, so
        they are capped through a single helper and always with the same limit:
        capping them independently is how a key ends up describing a box that
        was never drawn.
        """
        import json as _json
        raw = (raw or "").strip()
        if not raw:
            return raw
        try:
            parsed = _json.loads(raw)
        except (ValueError, TypeError):
            return raw
        if not isinstance(parsed, list) or len(parsed) <= limit:
            return raw
        _logger.warning(
            "etp_assessment label cap: %s on draft %s carried %d entries "
            "against a cap of %d - trimmed to %d so every label field describes "
            "the same boxes.", what, rec_id, len(parsed), limit, limit)
        return _json.dumps(parsed[:limit], ensure_ascii=False)

    def _carry_label_capture(self, image):
        """Copy the live-capture fields onto the bank image, only when the
        approved picture IS the capture. detections_json is left to
        `_carry_or_detect_label`, which carries the approved capture's boxes so
        the detect cron never re-shoots the page."""
        self.ensure_one()
        src = (self.source_url or "").strip()
        # Only when the approved picture IS the live page. An AI picture keeps
        # no URL on the bank image, or the detect cron would replace the
        # picture and its key after approval.
        if not src or not any(s.get("captured_from")
                              for s in self._image_specs()):
            return
        limit = self._label_box_cap()
        vals = {"source_url": src}
        if (self.capture_config_json or "").strip():
            vals["capture_config_json"] = self.capture_config_json
        if (self.omit_spec_json or "").strip():
            vals["omit_spec_json"] = self.omit_spec_json
        if self.coverage_expected:
            vals["coverage_expected"] = self.coverage_expected
        if (self.label_application or "").strip():
            vals["label_application"] = self.label_application
        # Carried, not re-derived, so both fields must be trimmed together with
        # the SAME limit - the capture that runs on the bank image later is
        # capped too, and a carried key longer than the boxes it describes would
        # outlive the very moment it was consistent.
        if (self.label_boxes_json or "").strip():
            vals["label_boxes_json"] = self._cap_json_list(
                self.label_boxes_json, limit, "label_boxes_json", self.id)
        if (self.behavioural_key_json or "").strip():
            vals["behavioural_key_json"] = self._cap_json_list(
                self.behavioural_key_json, limit, "behavioural_key_json", self.id)
        if (self.omitted_element_json or "").strip():
            vals["omitted_element_json"] = self.omitted_element_json
        image.write(vals)

    @staticmethod
    def _inline_image_bytes(spec):
        import base64 as _b64
        from ..services import image_ingest
        data = (spec.get("data") or "").strip()
        if not data:
            candidate = (spec.get("url") or spec.get("src") or "").strip()
            if candidate.startswith("data:"):
                data = candidate
        if not data:
            return b""
        payload, _ctype = image_ingest._strip_data_url(data)
        if not payload or not image_ingest._is_valid_b64(payload):
            return b""
        try:
            return _b64.b64decode(payload)
        except (ValueError, TypeError):
            return b""

    def _carry_or_detect_label(self, bank_question, image, slot, spec):
        self.ensure_one()
        if bank_question.question_type != "image_label" or slot != "single":
            return
        if (image.source_url or "").strip():
            # THE SCREENSHOT THE REVIEWER APPROVED is carried whole, so the
            # detect cron does not re-shoot a page that may have changed since,
            # or may now fail and leave a key with no boxes to point at.
            if (isinstance(spec, dict) and spec.get("captured_from")
                    and self._carry_render_detection(image, spec)):
                image.write({
                    "dom_manifest_json": self.label_boxes_json or "[]",
                    "capture_viewport": spec.get("capture_viewport") or "",
                })
            return
        if (self.behavioural_key_json or "").strip():
            return
        if self._carry_render_detection(image, spec):
            return
        raw = self._inline_image_bytes(spec)
        if not raw:
            return
        image._detect_inline(raw, ui=(bank_question.detection_mode == "ui"),
                             cap=self._label_box_cap())

    @staticmethod
    def _carry_render_detection(image, spec):
        if not isinstance(spec, dict):
            return False
        det = (spec.get("detections_json") or "").strip()
        if not det:
            return False
        from ..services import image_ingest
        vals = {"detections_json": det}
        annotated = (spec.get("annotated_data") or "").strip()
        if annotated:
            payload, _ctype = image_ingest._strip_data_url(annotated)
            if payload and image_ingest._is_valid_b64(payload):
                vals["annotated_image"] = payload
        if (spec.get("annotated_url") or "").strip():
            vals["annotated_image_url"] = spec["annotated_url"]
        image.write(vals)
        return True

    def _apply_authored_label_key(self, bank_question):
        """Sets detections_json, which makes the detect cron skip this image, so
        the authored key is never overwritten."""
        import json as _json
        import base64
        self.ensure_one()
        if not (self.behavioural_key_json or "").strip():
            return
        img = bank_question.image_ids.filtered(
            lambda i: i.slot == "single")[:1]
        if not img:
            return
        if (img.source_url or "").strip():
            return
        limit = self._label_box_cap()
        try:
            geometry = _json.loads(self.label_boxes_json or "[]")
        except (ValueError, TypeError):
            geometry = []
        # ONE truncation, THREE fields. detections_json (what gets drawn),
        # behavioural_key_json (what the reviewer sees) and label_boxes_json
        # (the geometry of record) are all cut to the same limit and in the same
        # order, because this method's whole job is to freeze an authored key
        # onto an image the detect cron will then refuse to touch - whatever
        # disagreement is written here is permanent.
        boxed = [
            g for g in geometry
            if isinstance(g, dict)
            and isinstance(g.get("box_2d"), (list, tuple))
            and len(g["box_2d"]) == 4]
        if len(boxed) > limit:
            _logger.warning(
                "etp_assessment authored label key: draft %s carried %d boxes "
                "against a cap of %d - kept the first %d across geometry, "
                "behavioural key and detections.",
                self.id, len(boxed), limit, limit)
            boxed = boxed[:limit]
        vals = {
            "behavioural_key_json": self._cap_json_list(
                self.behavioural_key_json, limit, "behavioural_key_json",
                self.id) or False,
            "coverage_expected": self.coverage_expected or "yes",
            "omitted_element_json": self.omitted_element_json or False,
            "label_application": self.label_application or False,
            "label_boxes_json": (
                _json.dumps(boxed, ensure_ascii=False) if boxed else False),
        }
        # THE AUTHORED NUMBER IS CARRIED, not re-derived from position.
        #
        # `boxed` DROPS entries whose geometry is malformed (no 4-element
        # `box_2d`), so it is legitimately sparse: authored markers 1, 2, 4 with
        # 3 unrenderable. Without the number, `imaging.annotate_from_pixels`
        # numbers what it draws 1..N by position, so the plate would be stamped
        # 1, 2, 3 and written back to `detections_json` that way - while
        # `behavioural_key_json`, the PARALLEL view of the same numbered list
        # written two lines above, still says 1, 2, 4. The grader reads the
        # behavioural key per marker
        # (`scoring._image_label_behavioural_key`), so marker 3's action would
        # be graded against the box authored as marker 4.
        #
        # This method's own comment says it: "whatever disagreement is written
        # here is permanent", because it also sets `detections_json`, which makes
        # the detect cron skip the image for ever.
        dets = [
            {"number": g.get("number"),
             "box_2d": g["box_2d"], "label": g.get("label") or "",
             "description": g.get("description") or ""}
            for g in boxed]
        raw = img._source_image_bytes()
        if raw and dets:
            from ..services import imaging, image_ingest
            annotated_png, label_key = imaging.annotate_image(raw, dets)
            annotated_b64 = base64.b64encode(annotated_png).decode()
            url, stored_b64 = image_ingest.ingest(
                self.env, None, "data:image/png;base64,%s" % annotated_b64,
                key_hint="labelauth-%s" % img.id)
            vals["detections_json"] = _json.dumps(
                label_key, ensure_ascii=False)
            vals["annotated_image"] = stored_b64 or annotated_b64
            if url:
                vals["annotated_image_url"] = url
        img.write(vals)

    def action_deny(self):
        drafts = self.filtered(lambda r: r.state == "draft")
        drafts.write({"state": "denied"})
        self._log_drafts_to_generators(drafts, "denied")
        return self._decision_notification(drafts, "Denied")

    def _briefs(self):
        import json as _json
        self.ensure_one()
        raw = (self.image_brief_json or "").strip()
        if not raw or raw in ("[]", "{}"):
            return []
        try:
            parsed = _json.loads(raw)
        except (ValueError, TypeError):
            return []
        if isinstance(parsed, dict):
            parsed = [parsed]
        return [b for b in parsed if isinstance(b, dict)] \
            if isinstance(parsed, list) else []

    def _current_images(self):
        import json as _json
        self.ensure_one()
        raw = (self.images_json or "").strip()
        if not raw or raw in ("[]", "{}"):
            return []
        try:
            parsed = _json.loads(raw)
        except (ValueError, TypeError):
            return []
        if isinstance(parsed, dict):
            parsed = [parsed]
        return [i for i in parsed if isinstance(i, dict)] \
            if isinstance(parsed, list) else []

    def _current_videos(self):
        """The clips staged for this draft, video twin of `_current_images`.

        WHY THIS EXISTS. `action_approve` refused an IMAGE question whose
        picture had not rendered yet, but had no equivalent check for video -
        the readiness helper simply did not exist. A `video_prompt` draft could
        therefore be approved while Veo was still generating: `_video_files()`
        returned [], `_materialize_videos` created no rows, and the published
        question read "No video yet for this question." forever, with the
        candidate answering about a clip they could not see.

        Delegates to `_video_files()` so the readiness check and the
        materialiser can never disagree about what counts as a staged clip.
        """
        self.ensure_one()
        return self._video_files()

    def _notify(self, title, message, kind="success", sticky=False):
        return {
            "type": "ir.actions.client",
            "tag": "display_notification",
            "params": {"title": title, "message": message,
                       "type": kind, "sticky": sticky},
        }

    def _verify_flaw_render_on(self):
        val = self.env["ir.config_parameter"].sudo().get_param(
            "assessments_be_v2.verify_flaw_render", "1")
        return str(val).strip().lower() not in ("0", "false", "no", "off", "")

    def _planted_flaws(self):
        self.ensure_one()
        plan = parse_flaw_plan(self.flaw_plan_json)
        planted = plan.get("planted") if isinstance(plan, dict) else None
        if not isinstance(planted, dict):
            return {}
        return {
            "a": [str(f) for f in (planted.get("a") or []) if str(f).strip()],
            "b": [str(f) for f in (planted.get("b") or []) if str(f).strip()],
        }

    def _dense_preview_dets(self):
        """Must stay in sync with question_image._dense_detections so the draft
        preview and the approved fallback draw the same boxes - including the
        cap, or the reviewer approves a preview with more boxes than the
        candidate is ever shown."""
        import json as _json
        self.ensure_one()
        raw = (self.label_boxes_json or "").strip()
        if not raw:
            return []
        try:
            geometry = _json.loads(raw)
        except (ValueError, TypeError):
            return []
        limit = self._label_box_cap()
        dets = []
        for g in geometry if isinstance(geometry, list) else []:
            if len(dets) >= limit:
                break
            if (isinstance(g, dict)
                    and isinstance(g.get("box_2d"), (list, tuple))
                    and len(g["box_2d"]) == 4):
                dets.append({
                    # The authored number, not the draw position. This list
                    # DROPS entries with malformed geometry, so it is
                    # legitimately sparse - and the preview a reviewer approves
                    # has to carry the same numbers as the key those boxes are
                    # graded against.
                    "number": g.get("number"),
                    "box_2d": list(g["box_2d"]),
                    "label": str(g.get("label") or "").strip(),
                    "description": str(g.get("description") or "").strip(),
                })
        return dets

    def _draw_dense_preview(self, images):
        import base64 as _b64
        import json as _json
        self.ensure_one()
        dets = self._dense_preview_dets()
        if not dets:
            return images
        from ..services import imaging
        for spec in images:
            if not isinstance(spec, dict):
                continue
            if (spec.get("slot") or "single") != "single":
                continue
            if (spec.get("annotated_data") or "").strip():
                continue
            raw = self._inline_image_bytes(spec)
            if not raw:
                continue
            try:
                annotated_png, label_key = imaging.annotate_image(raw, dets)
            except Exception:  # noqa: BLE001 - preview draw must never fail render
                _logger.exception(
                    "Dense preview draw failed for draft %s", self.id)
                continue
            spec["annotated_data"] = (
                "data:image/png;base64,%s"
                % _b64.b64encode(annotated_png).decode())
            spec["detections_json"] = _json.dumps(label_key, ensure_ascii=False)
        return images

    def _capture_source_url_on_render(self, images):
        import base64 as _b64
        import json as _json
        self.ensure_one()
        src = (self.source_url or "").strip()
        if not src:
            return False
        from ..services import dom_capture
        single = next((s for s in images if isinstance(s, dict)
                       and (s.get("slot") or "single") == "single"), None)
        if single is None:
            return False
        # WHY it failed rides on the spec, for the draft's warning.
        if not dom_capture.PLAYWRIGHT_AVAILABLE:
            single["capture_error"] = "the screenshot browser is not installed"
            return False
        # Keep in sync with question_image._capture_kwargs.
        kwargs = {"max_boxes": self._label_box_cap()}
        try:
            cfg = _json.loads(self.capture_config_json or "{}")
            if isinstance(cfg, dict):
                vp = cfg.get("viewport")
                if isinstance(vp, dict) and vp.get("width") and vp.get("height"):
                    kwargs["viewport"] = (int(vp["width"]), int(vp["height"]))
                if cfg.get("wait_ms"):
                    kwargs["wait_ms"] = int(cfg["wait_ms"])
                if cfg.get("dismiss"):
                    kwargs["dismiss"] = cfg["dismiss"]
        except (ValueError, TypeError):
            pass
        try:
            omit = _json.loads(self.omit_spec_json or "null")
            if isinstance(omit, dict) and omit:
                kwargs["omit"] = omit
        except (ValueError, TypeError):
            pass
        try:
            result = dom_capture.capture_and_annotate(src, **kwargs)
        except Exception as exc:  # noqa: BLE001 - capture must never break the render
            _logger.exception(
                "Render-time DOM capture failed for draft %s (%s)", self.id, src)
            single["capture_error"] = (
                "the page could not be opened: %s" % exc)[:300]
            return False
        unusable = dom_capture.unusable_reason(
            result, cap=kwargs.get("max_boxes"))
        if unusable:
            single["capture_error"] = unusable
            return False
        annotated_png = result.get("annotated_png")
        if not annotated_png:
            single["capture_error"] = "the numbered boxes could not be drawn"
            return False
        single.pop("capture_error", None)
        single["captured_from"] = src
        single["capture_viewport"] = dom_capture.viewport_stamp(
            kwargs.get("viewport", (1440, 900)))
        single["annotated_data"] = (
            "data:image/png;base64,%s"
            % _b64.b64encode(annotated_png).decode())
        base_png = result.get("screenshot_png")
        if base_png:
            single["data"] = (
                "data:image/png;base64,%s"
                % _b64.b64encode(base_png).decode())
        label_key = result.get("label_key")
        if label_key:
            single["detections_json"] = _json.dumps(
                label_key, ensure_ascii=False)
        vals = {"source_url": src}
        bkey = result.get("behavioural_key")
        if bkey:
            # The page's own list is the one list: key, rubric and golden
            # answer are rewritten from it, not left describing the fallback.
            vals.update(self._label_key_vals(
                [{"number": e["number"],
                  "element": str(e.get("element") or "").strip(),
                  "functionality": str(e.get("functionality") or "").strip()}
                 for e in bkey
                 if isinstance(e, dict) and isinstance(e.get("number"), int)],
                "captured"))
        manifest = result.get("dom_manifest")
        if manifest:
            vals["label_boxes_json"] = _json.dumps(
                manifest, ensure_ascii=False)
        if result.get("omitted_element"):
            vals["omitted_element_json"] = _json.dumps(
                result["omitted_element"], ensure_ascii=False)
        if result.get("coverage_expected"):
            vals["coverage_expected"] = result["coverage_expected"]
        try:
            self.write(vals)
        except Exception:  # noqa: BLE001 - never fail the render on a write
            _logger.exception(
                "Failed to persist capture key on draft %s", self.id)
        return True

    def _remap_answer_key(self, marker_map):
        """Re-key the defect answer key onto the RENDERED marker numbering.

        `defect_render.plant` drops any defect vision could not confirm and
        renumbers the survivors 1..N, returning `marker_map` = {original: new}.
        The answer key was authored BEFORE that gate ran (services/vertex.py
        :2234) and is still keyed by the model's original numbering, so without
        this remap the judge grades marker N against whatever defect used to
        hold that number -- and any per-marker rubric silently scores the wrong
        defect (D-1).

        BOTH KEY CARRIERS ARE REMAPPED, not just the rubric. `rubric_json` and
        `solution_json` are two serialisations of the same numbered markers read
        by two different consumers - the grader's per-marker key and the
        subjective judge's golden answer. Remapping only the rubric left them
        disagreeing: a draft whose 7 planned markers rendered as 2 kept a
        2-entry rubric (correct) beside a 7-entry solution (stale), and the
        judge then graded a candidate against five golden labels for markers
        that were never drawn on the image they answered. Observed on draft 200.

        Rules:
          * a marker-keyed entry is re-keyed to its new number;
          * a marker that did NOT render is dropped from the key (there is no
            marker on the image to answer);
          * non-numeric keys (`decoy`, `decoy_rule`, `scoring_guide`, ...) are
            NOT markers and pass through untouched;
          * an identity map rewrites nothing.
        """
        import json as _json
        self.ensure_one()
        if not isinstance(marker_map, dict) or not marker_map:
            return False

        # marker_map keys arrive as ints from the renderer but survive a JSON
        # round-trip as strings; normalise both sides before comparing.
        remap = {}
        for old, new in marker_map.items():
            try:
                remap[str(int(old))] = int(new)
            except (TypeError, ValueError):
                continue
        if not remap:
            return False
        identity = all(int(k) == v for k, v in remap.items())

        any_changed = False
        for carrier in ("rubric_json", "solution_json"):
            if self._remap_one_key_carrier(carrier, remap, identity):
                any_changed = True
        return any_changed

    def _remap_one_key_carrier(self, field_name, remap, identity):
        """Apply `remap` to one JSON answer-key field. Returns True if rewritten."""
        import json as _json
        raw = (getattr(self, field_name) or "").strip()
        if not raw or raw in ("{}", "[]"):
            return False
        try:
            key = _json.loads(raw)
        except (ValueError, TypeError):
            return False
        if not isinstance(key, dict) or not key:
            return False

        changed = False
        for field in ("ideal_labels", "answers", "labels", "markers"):
            sub = key.get(field)
            if not isinstance(sub, dict) or not sub:
                continue
            rebuilt, touched = {}, False
            for mk, val in sub.items():
                token = str(mk).strip()
                if not token.isdigit():
                    rebuilt[mk] = val          # decoy / decoy_rule / prose key
                    continue
                new_num = remap.get(token)
                if new_num is None:
                    touched = True             # defect never rendered -> drop
                    continue
                if str(new_num) != token:
                    touched = True
                rebuilt[str(new_num)] = val
            if touched:
                key[field] = {
                    k: rebuilt[k]
                    for k in sorted(rebuilt,
                                    key=lambda s: (not str(s).isdigit(),
                                                   int(s) if str(s).isdigit()
                                                   else 0, str(s)))}
                changed = True

        if not changed:
            if not identity:
                _logger.info(
                    "defect key remap: draft %s has no marker-keyed %s "
                    "to remap (map=%s)", self.id, field_name, remap)
            return False
        setattr(self, field_name, _json.dumps(key, ensure_ascii=False))
        _logger.info("defect key remap: draft %s %s re-keyed %s",
                     self.id, field_name, remap)
        return True

    def _warn_on_marker_shortfall(self, planned, rendered_key):
        """Flag a labelling draft whose markers did not survive verification.

        WHY THIS IS A WARNING AND NOT A REJECTION. The vision gate exists to
        stop a marker landing on empty space, so dropping an unconfirmed defect
        is correct behaviour, not a fault. What was wrong is that it happened
        SILENTLY: draft 200 planned seven entities, rendered two, and reached
        the review queue looking complete - a reviewer approving it would have
        published a question showing two markers whose scoring guide still spoke
        of "all 7 specified entities". A candidate cannot answer markers that
        were never drawn.

        So the draft keeps everything it has and says what happened. The admin
        approves, edits or denies; the pipeline does not decide for them.
        """
        self.ensure_one()
        drawn = len(rendered_key or [])
        notes = []
        if drawn == 0:
            notes.append(
                "None of the %d planned marker(s) could be confirmed on the "
                "rendered image, so the picture carries NO numbered boxes. A "
                "candidate would see nothing to label - regenerate or author "
                "the boxes by hand before approving." % planned)
        elif planned and drawn < planned:
            notes.append(
                "Only %d of %d planned marker(s) were confirmed on the image; "
                "the other %d were dropped and the answer key was trimmed to "
                "match. Check the question wording and any scoring guide still "
                "referring to %d items." % (drawn, planned, planned - drawn,
                                            planned))
        if not notes:
            return False
        existing = (self.gen_warnings or "").rstrip()
        added = "\n".join("- %s" % n for n in notes)
        self.gen_warnings = ("%s\n%s" % (existing, added)) if existing else added
        _logger.warning(
            "etp_assessment image_label: draft %s rendered %d of %d markers",
            self.id, drawn, planned)
        return True

    def _plant_defects_on_render(self, images):
        """DEFECT form (q7r) true-by-construction render — drop-2 base+edit+
        vision-ground flow. The rendered 'single' image is the CLEAN base; ONE
        combined image-to-image edit bakes every structural defect into the real
        pixels, then each defect's anchor is vision-grounded on the FINAL image and
        the marker stamped there only if the flaw is confirmed present. Unverified
        defects are dropped and the survivors renumbered 1..N, so no marker ever
        lands on empty space and the answer key can never reference a defect that
        didn't render.
        """
        import base64 as _b64
        import json as _json
        self.ensure_one()
        try:
            plan = _json.loads(self.defect_plan_json or "{}")
        except (ValueError, TypeError):
            plan = {}
        defects = plan.get("defects") if isinstance(plan, dict) else None
        if not isinstance(defects, list) or not defects:
            return images
        from ..services import defect_render, image_ingest, vertex

        # ctx exposes the two model callables the renderer needs, bound to our
        # Vertex service (kept out of the pure-PIL renderer so it stays testable).
        # usage_ctx threads the draft id so image-edit / locate spend is ledgered
        # and the H-5 budget caps are honoured on every billable call.
        _env = self.env
        # llm_usage.prompt_id FKs the GENERATOR (assessments.be.prompt), so
        # attribute spend to self.prompt_id (the generator), NOT self.id (this draft
        # question) — the latter FK-violates and poisons the render transaction.
        _uctx = {"prompt_id": self.prompt_id.id or False, "note": "defect-render"}

        class _DefectCtx:
            @staticmethod
            def edit_image(edit_prompt, ref_png_bytes):
                return vertex.edit_image(
                    _env, edit_prompt, ref_png_bytes, usage_ctx=dict(_uctx))

            @staticmethod
            def locate(image_png_bytes, anchor, flaw=""):
                return vertex.locate_defect(
                    _env, image_png_bytes, anchor, flaw, usage_ctx=dict(_uctx))

        ctx = _DefectCtx()
        for spec in images:
            if not isinstance(spec, dict):
                continue
            if (spec.get("slot") or "single") != "single":
                continue
            raw = self._inline_image_bytes(spec)
            if not raw:
                continue
            try:
                original_png, annotated_png, info = defect_render.plant(
                    raw, defects, ctx=ctx,
                    seed=abs(hash("draft-%s" % self.id)) % 100000)
            except Exception:  # noqa: BLE001 - injection must never fail the render
                _logger.exception(
                    "Defect injection failed for draft %s; leaving base image",
                    self.id)
                continue
            planted = info.get("defects") or []
            # Worker sees the ORIGINAL (defects present, no markers). The annotated
            # overlay + the planted key are the answer sheet the reviewer/scorer use.
            spec["data"] = ("data:image/png;base64,%s"
                            % _b64.b64encode(original_png).decode())
            spec["annotated_data"] = ("data:image/png;base64,%s"
                                      % _b64.b64encode(annotated_png).decode())
            # Persist the true-by-construction key as detections_json in the same
            # {number, label, description, box_px} shape the label UI/scoring read.
            # Markers are already renumbered 1..N (survivors only) by the renderer.
            key = [{"number": p["marker"],
                    "label": (p.get("flaw") or "")[:80],
                    "description": p.get("flaw") or "",
                    "box_px": [p["marker_xy"][0] - 20, p["marker_xy"][1] - 20,
                               p["marker_xy"][0] + 20, p["marker_xy"][1] + 20]}
                   for p in planted
                   if isinstance(p.get("marker_xy"), (list, tuple))
                   and len(p["marker_xy"]) == 2]
            spec["detections_json"] = _json.dumps(key, ensure_ascii=False)
            # D-1: the verify gate DROPS unrendered defects and RENUMBERS the
            # survivors 1..N, so the answer key authored at generation time
            # (services/vertex.py:2234, keyed by the model's ORIGINAL marker
            # numbers) no longer describes the markers on the image. Remap it
            # with the renderer's marker_map, or the judge grades marker N
            # against a different defect than the candidate was shown.
            self._remap_answer_key(info.get("marker_map"))
            # THE SHAPE GATE. Vision verification can drop most of a plan - draft
            # 200 planned 7 markers and rendered 2 - and a reviewer had no way to
            # see that from the queue: the draft looked finished and carried no
            # warning at all. That is the same failure mode as an answer key that
            # matches no option: a question a candidate cannot answer correctly,
            # published silently. So say it on the draft, where the reviewer
            # decides. Nothing is dropped - the admin approves or denies.
            self._warn_on_marker_shortfall(len(defects), key)
            try:
                url, _stored = image_ingest.ingest(
                    self.env, None, spec["annotated_data"],
                    key_hint="defect-%s-single" % self.id)
                if url:
                    spec["annotated_url"] = url
            except Exception:  # noqa: BLE001 - overlay storage is best-effort
                _logger.exception("defect overlay ingest failed on draft %s", self.id)
        return images

    def _detect_label_on_render(self, images):
        """ONE BOX LIST per labelling question (owner, 2026-09-29).

        The boxes drawn, the answer key, the rubric and the golden answer are
        all written from the SAME numbered list, made by ONE method:

        1. NAMED boxes (first): the generator named each element and what it
           does; one vision call finds each name on the rendered picture and
           the box goes there. The key stays the generator's.
        2. DETECTED boxes (fallback, only when 1 fails or finds fewer than
           half): vision picks the elements itself, and the key, rubric and
           golden answer are rebuilt from what it found.

        A live-page capture (a generator that asks for real websites) is its
        own list and is kept as-is. It used to be possible to get a detection
        pass baked into the picture while the key described the generator's
        boxes - two numberings, graded against one (prod q1170).
        """
        self.ensure_one()
        if self.question_type != "image_label" or not isinstance(images, list):
            return images
        # DEFECT form (q7r): a defect plan means the rendered image is the CLEAN
        # base; plant each defect and stamp the marker on the ACTUAL drawn region
        # (true by construction — no misplaced labels).
        if (self.defect_plan_json or "").strip():
            return self._plant_defects_on_render(images)
        if any(isinstance(s, dict) and s.get("captured_from") for s in images):
            return images   # the live page, numbered from its own controls
        for spec in images:
            if not isinstance(spec, dict):
                continue
            if (spec.get("slot") or "single") != "single":
                continue
            # Already placed on an earlier pass: never pay for it twice.
            if (spec.get("detections_json") or "").strip():
                continue
            raw = self._inline_image_bytes(spec)
            if not raw:
                continue
            try:
                with self.env.cr.savepoint():
                    boxes, source = self._place_label_boxes(raw)
                    if boxes:
                        self._apply_label_list(spec, raw, boxes, source)
            except Exception:  # noqa: BLE001 - placement must never fail render
                _logger.exception(
                    "Render-time label placement failed for draft %s; leaving "
                    "the image unboxed", self.id)
        drawn = any(isinstance(s, dict) and (s.get("detections_json") or "")
                    .strip() for s in images)
        if not drawn and self._named_label_boxes():
            self._warn_on_missing_boxes()
        return images

    def _named_label_boxes(self):
        """The generator's own numbered list: [{number, element, functionality}]."""
        import json as _json
        self.ensure_one()
        for field, name, what in (
                ("behavioural_key_json", "element", "functionality"),
                ("label_boxes_json", "label", "description")):
            try:
                rows = _json.loads(self[field] or "[]")
            except (ValueError, TypeError):
                rows = []
            named = [{"number": r["number"],
                      "element": str(r.get(name) or "").strip(),
                      "functionality": str(r.get(what) or "").strip()}
                     for r in (rows if isinstance(rows, list) else [])
                     if isinstance(r, dict) and isinstance(r.get("number"), int)
                     and str(r.get(name) or "").strip()]
            if named:
                return named[:self._label_box_cap()]
        return []

    def _place_label_boxes(self, raw):
        """(boxes, source): the one list, named first, detected as fallback."""
        import base64 as _b64
        import math
        from ..services import vertex
        self.ensure_one()
        b64 = _b64.b64encode(raw).decode()
        ctx = {"prompt_id": self.prompt_id.id or False,
               "note": (self.name or "")[:80]}
        named = self._named_label_boxes()
        why = ""
        if named:
            try:
                found = vertex.locate_label_elements(
                    self.env, b64, named, usage_ctx=ctx)
            except Exception as exc:  # noqa: BLE001 - fall back, never fail
                _logger.exception("Locating named boxes failed for draft %s",
                                  self.id)
                found, why = {}, "the vision call failed: %s" % exc
            placed = [dict(n, box_2d=found[n["number"]])
                      for n in named if n["number"] in found]
            if placed and len(placed) >= math.ceil(len(named) / 2):
                missing = [n for n in named if n["number"] not in found]
                if missing:
                    self._add_gen_warning(
                        "%d named box(es) were not on the picture and were "
                        "left out of the boxes and the answer key: %s."
                        % (len(missing), ", ".join(
                            "%d %s" % (n["number"], n["element"])
                            for n in missing)))
                return placed, "named"
            why = why or "only %d of %d named boxes were found on the picture" \
                % (len(placed), len(named))
        detections = vertex.detect_image_elements(
            self.env, b64, ui=self.detection_mode in ("ui", "dense"),
            usage_ctx=ctx, cap=self._label_box_cap())
        boxes = [{"number": i, "box_2d": d["box_2d"],
                  "element": d.get("label") or "",
                  "functionality": d.get("description") or d.get("label") or ""}
                 for i, d in enumerate(detections, start=1)]
        if boxes and named:
            self._add_gen_warning(
                "The generator's numbered boxes could not be placed on the "
                "picture (%s), so the boxes, answer key, rubric and golden "
                "answer were rebuilt from what vision found. Check the question "
                "text still fits." % why)
        return boxes, "detected"

    def _apply_label_list(self, spec, raw, boxes, source):
        """Draw the list and write it to EVERY carrier, so nothing can drift."""
        import base64 as _b64
        import json as _json
        from ..services import image_ingest, imaging
        self.ensure_one()
        dets = [{"number": b["number"], "box_2d": list(b["box_2d"]),
                 "label": b["element"], "description": b["functionality"]}
                for b in boxes]
        annotated_png, label_key = imaging.annotate_image(raw, dets)
        annotated_b64 = _b64.b64encode(annotated_png).decode()
        url, _stored = image_ingest.ingest(
            self.env, None, "data:image/png;base64,%s" % annotated_b64,
            key_hint="draftannot-%s-single" % self.id)
        spec["detections_json"] = _json.dumps(label_key, ensure_ascii=False)
        spec["annotated_data"] = "data:image/png;base64,%s" % annotated_b64
        if url:
            spec["annotated_url"] = url
        spec["boxes_from"] = source
        vals = self._label_key_vals(boxes, source)
        vals["label_boxes_json"] = _json.dumps(dets, ensure_ascii=False)
        self.write(vals)

    def _label_key_vals(self, boxes, source):
        """The answer key, rubric and golden answer, from the one box list."""
        import json as _json
        self.ensure_one()
        try:
            rubric = _json.loads(self.rubric_json or "{}")
        except (ValueError, TypeError):
            rubric = {}
        rubric = rubric if isinstance(rubric, dict) else {}
        rubric["ideal_labels"] = "\n".join(
            "%d. %s" % (b["number"], b["functionality"]) for b in boxes)
        if source != "named":
            # They described the generator's boxes, which this list replaced.
            rubric.pop("mandatory_elements", None)
            rubric.pop("penalty_rules", None)
        vals = {
            "behavioural_key_json": _json.dumps(
                [{"number": b["number"], "element": b["element"],
                  "functionality": b["functionality"]} for b in boxes],
                ensure_ascii=False),
            "rubric_json": _json.dumps(rubric, ensure_ascii=False),
            "solution_json": _json.dumps(
                {str(b["number"]): b["functionality"] for b in boxes},
                ensure_ascii=False),
        }
        if (self.label_expected_count or 0) > len(boxes):
            vals["label_expected_count"] = 0   # every box counts
        return vals

    def _add_gen_warning(self, note):
        existing = (self.gen_warnings or "").rstrip()
        if note not in existing:
            self.gen_warnings = (
                "%s\n- %s" % (existing, note)) if existing else "- %s" % note

    def _wants_live_capture(self):
        """A live website screenshot only for a generator that asks for one."""
        self.ensure_one()
        return bool(self.question_type == "image_label"
                    and (self.source_url or "").strip()
                    and not (self.defect_plan_json or "").strip()
                    and self.prompt_id.image_label_live_capture)

    def _warn_on_unverified_boxes(self, images):
        """Say so when a labelling question's boxes were never seen on the image.

        A box that vision confirmed sits on the thing it names. A box the text
        model guessed before any image existed sits wherever its rectangle
        happens to fall - on q303 that put "Cat picture" over a potted plant and
        ran "City skyline" off the frame. Both look identical in the review
        queue, so the difference has to be written down.

        WHY `detections_json` IS NOT THE TEST. `_draw_dense_preview` fills that
        field too, from the very guesses this warns about, so its presence says
        only "something was drawn", not "something was checked". The honest test
        is whether the drawn geometry is just the authored geometry rescaled: a
        detection finds its own rectangles and will not reproduce the model's to
        the pixel.

        Warned, not rejected: an approximately-boxed question is still worth an
        examiner's judgement, and the admin decides.
        """
        import json as _json
        self.ensure_one()
        if self.question_type != "image_label":
            return False
        authored = (self.label_boxes_json or "").strip()
        if not authored:
            return False
        try:
            guesses = _json.loads(authored)
        except (ValueError, TypeError):
            return False
        if not isinstance(guesses, list) or not guesses:
            return False

        drawn = []
        for spec in (images or []):
            if not isinstance(spec, dict):
                continue
            try:
                drawn += _json.loads(spec.get("detections_json") or "[]")
            except (ValueError, TypeError):
                continue
        if not drawn:
            # NOTHING DRAWN, BUT A KEY EXISTS. This used to return silently on
            # the grounds that "the detect cron will retry after approval" -
            # which is true, and is not the same as the reviewer being told. On
            # the live database images 290, 295 and 306 sit in exactly this
            # state: an empty box list beside an `ideal_labels` key naming 1, 3
            # and 2 boxes. A candidate is shown a picture with no numbers on it
            # and graded against boxes that were never drawn, and the queue said
            # nothing.
            #
            # Delegated rather than inlined so the two situations keep separate
            # wording: "the boxes are guesses" and "there are no boxes" are
            # different problems and an examiner acts on them differently.
            return self._warn_on_missing_boxes()

        if not self._boxes_are_authored_guesses(guesses, drawn):
            return False

        note = (
            "The numbered boxes on this image were NOT confirmed against the "
            "rendered picture - they are the generator's own estimate, so a "
            "number may sit on the wrong thing. Check each box before "
            "approving.")
        existing = (self.gen_warnings or "").rstrip()
        if note in existing:
            return False
        self.gen_warnings = (
            "%s\n- %s" % (existing, note)) if existing else "- %s" % note
        _logger.warning(
            "etp_assessment image_label: draft %s ships UNVERIFIED boxes "
            "(source_url=%r could not be captured)",
            self.id, (self.source_url or "")[:80])
        return True

    def _warn_on_missing_boxes(self):
        """Say so when a labelling question has an answer key but no boxes drawn.

        THE STATE THIS CATCHES, from the live database: `label_boxes_json` empty
        (or its detections empty) while the question's key names N boxes. The
        candidate is served a picture with no numbers on it, is asked to describe
        boxes 1..N, and is graded against a key for boxes that were never drawn.
        Every one of those marks is unearnable, and nothing in the review queue
        said so.

        Raised by `_detect_label_on_render` when neither the named placement nor
        the detection fallback drew a box. A WARNING, NOT A REFUSAL: the admin
        decides, and must not have the decision made silently on their behalf.
        Nothing fills the boxes in later - approval draws the generator's
        approximate box_2d and sets detections_json, so the detect cron skips
        the image.

        The companion guard is `question.has_valid_key`, which quarantines this
        shape from `servable` so it cannot reach a candidate while it lasts. Two
        halves of one fix: this one tells a person, that one stops the exam.
        """
        self.ensure_one()
        note = (
            "This labelling question carries an answer key but NO numbered "
            "boxes were drawn on its image, so a candidate would be asked to "
            "describe boxes they cannot see and could not earn those marks. "
            "Re-run detection or attach a working source image before "
            "approving.")
        existing = (self.gen_warnings or "").rstrip()
        if note in existing:
            return False
        self.gen_warnings = (
            "%s\n- %s" % (existing, note)) if existing else "- %s" % note
        _logger.warning(
            "etp_assessment image_label: draft %s has an answer key but no "
            "drawn boxes (source_url=%r)",
            self.id, (self.source_url or "")[:80])
        return True

    @staticmethod
    def _boxes_are_authored_guesses(guesses, drawn):
        """True when the drawn boxes are the authored ones rescaled, not detected.

        `_draw_dense_preview` maps each authored `box_2d` (a 0-1000 grid) onto
        the image with `round(v / 1000 * size)`, so every drawn `box_px` is a
        deterministic function of a guess. Vision detection finds its own
        rectangles and effectively never lands on all of them exactly. Same
        count plus every drawn box reproducible from a guess = not verified.
        """
        if len(guesses) != len(drawn):
            return False
        # ONE SET PER AXIS, because x and y are scaled by DIFFERENT factors on
        # any image that is not square: `_draw_dense_preview` maps x by the
        # width and y by the height. Collecting all four edges into a single set
        # therefore made a rescale of authored boxes look like detection the
        # moment the image was not square - measured, 6 guessed boxes on 1280x800
        # produced 4 distinct ratios, sailed past a `<= 2` test, and the
        # "these boxes were never checked" warning never fired. It stayed
        # invisible because every test fixture in this module uses a square 1024
        # image.
        x_ratios, y_ratios = set(), set()
        for g, d in zip(guesses, drawn):
            box2d = g.get("box_2d") if isinstance(g, dict) else None
            boxpx = d.get("box_px") if isinstance(d, dict) else None
            if not (isinstance(box2d, (list, tuple)) and len(box2d) == 4
                    and isinstance(boxpx, (list, tuple)) and len(boxpx) == 4):
                return False
            # box_2d is [ymin,xmin,ymax,xmax]; box_px is [l,t,r,b]. Paired with
            # the axis each edge belongs to, so a horizontal edge can never be
            # compared against a vertical scale.
            pairs = ((box2d[1], boxpx[0], x_ratios),   # xmin -> left
                     (box2d[0], boxpx[1], y_ratios),   # ymin -> top
                     (box2d[3], boxpx[2], x_ratios),   # xmax -> right
                     (box2d[2], boxpx[3], y_ratios))   # ymax -> bottom
            for grid, px, bucket in pairs:
                try:
                    grid, px = float(grid), float(px)
                except (TypeError, ValueError):
                    return False
                if grid <= 0:
                    continue
                bucket.add(round(px / grid, 2))
        # Each axis internally consistent means the drawing came straight from
        # the guesses. The allowance of 2 per axis is the rounding slack the
        # original carried, kept so a genuinely-rescaled set is not missed over a
        # half-pixel; it is now per axis rather than shared between them.
        return len(x_ratios) <= 2 and len(y_ratios) <= 2

    def _render_all_images(self):
        """Only stamp 'rendered' once every brief has an image, and always keep
        slots that already rendered: each render is paid for, so a retry must
        re-render only the missing slots."""
        import json as _json
        from ..services import vertex
        self.ensure_one()
        briefs = self._briefs()
        renderable = [b for b in briefs
                      if isinstance(b, dict) and b.get("prompt")]
        if not renderable:
            return False

        have = {img.get("slot"): img for img in self._current_images()
                if isinstance(img, dict) and (img.get("data") or img.get("url"))}
        todo = [b for b in renderable
                if (b.get("slot") or "single") not in have]
        # A LIVE SITE ONLY WHERE A PROJECT ASKS FOR ONE (owner, 2026-09-29):
        # a generator with "Screenshot live websites" on captures the page
        # before any AI picture is paid for. When the page cannot be captured
        # the AI picture is the fallback, and the draft says so.
        if self._wants_live_capture() and any(
                (b.get("slot") or "single") == "single" for b in todo):
            brief = next(b for b in todo
                         if (b.get("slot") or "single") == "single")
            spec = {"slot": "single", "label": brief.get("label") or ""}
            if (self._capture_source_url_on_render([spec])
                    and spec.get("data")):
                have["single"] = spec
                todo = [b for b in todo if b is not brief]
                if "could not be screenshotted" in (self.gen_warnings or ""):
                    self.gen_warnings = "\n".join(
                        line for line in self.gen_warnings.splitlines()
                        if "could not be screenshotted" not in line) or False
            else:
                reason = spec.get("capture_error") or "no screenshot came back"
                self._add_gen_warning(
                    "The live page %s could not be screenshotted (%s), so an "
                    "AI-made picture was used instead."
                    % ((self.source_url or "").strip()[:200], reason))
                _logger.warning(
                    "etp_assessment image_label: draft %s live capture of %r "
                    "failed, using an AI picture: %s", self.id,
                    (self.source_url or "")[:80], reason)
        if not todo:
            fresh = list(have.values())
            fresh = self._detect_label_on_render(fresh)
            self.write({
                "images_json": _json.dumps(fresh, ensure_ascii=False),
                "image_state": "rendered",
                "image_render_attempts": 0,
            })
            return True

        try:
            new_images = vertex.render_draft_images(
                self.env, todo,
                usage_ctx={"operation": "generate_image",
                           "prompt_id": self.prompt_id.id,
                           "note": self.name})
        except vertex.VertexNotConfiguredError as exc:
            # No attempt to spend: retrying cannot fix a missing setting. The
            # review card shows `image_error`, which names where to set it.
            self.write({"image_state": "failed", "image_error": str(exc)})
            return False
        except (vertex.VertexQuotaError, vertex.VertexBudgetError,
                vertex.VertexCancelledError) as exc:
            # A 429 or a spend cap: left pending, no attempt spent; a kill:
            # `cancelled`. Persist slots that rendered before it so they are
            # not re-paid (a kill between two slots kept none of the first).
            state = ("cancelled" if isinstance(exc, vertex.VertexCancelledError)
                     else "pending")
            salvaged = {**have}
            for img in (getattr(exc, "partial", None) or []):
                if isinstance(img, dict) and img.get("slot"):
                    salvaged[img["slot"]] = img
            if len(salvaged) > len(have):
                self.write({
                    "images_json": _json.dumps(
                        list(salvaged.values()), ensure_ascii=False),
                    "image_state": state,
                })
            else:
                self.write({"image_state": state})
            return False

        merged = {**have}
        for img in (new_images or []):
            if isinstance(img, dict) and img.get("slot"):
                merged[img["slot"]] = img
        images = list(merged.values())

        if len(images) >= len(renderable):
            verification = None
            if (self.question_type == "image_ab" and self.flaw_plan_json
                    and self._verify_flaw_render_on()):
                planted = self._planted_flaws()
                if planted.get("a") or planted.get("b"):
                    try:
                        images, verification = \
                            vertex.verify_and_regenerate_ab_images(
                                self.env, briefs, images, planted,
                                usage_ctx={"operation": "verify_planted_flaws",
                                           "prompt_id": self.prompt_id.id,
                                           "note": self.name})
                    except vertex.VertexQuotaError:
                        self.write({
                            "images_json": _json.dumps(
                                images, ensure_ascii=False),
                            "image_state": "pending",
                        })
                        return False
                    except Exception:  # noqa: BLE001 - never break generation
                        _logger.exception(
                            "etp_assessment flaw verification failed for draft "
                            "%s; storing rendered images unverified", self.id)
                        verification = None
            images = self._detect_label_on_render(images)
            vals = {
                "images_json": _json.dumps(images, ensure_ascii=False),
                "image_state": "rendered",
                "image_render_attempts": 0,
                "image_error": False,
            }
            if verification is not None:
                vals["verification_json"] = _json.dumps(
                    verification, ensure_ascii=False)
            self.write(vals)
            return True

        # Incomplete render (a slot came back empty, not a 429): persist what we
        # have so it is not re-paid.
        attempts = (self.image_render_attempts or 0) + 1
        vals = {
            "image_render_attempts": attempts,
            "image_state": "failed" if attempts >= 3 else "pending",
        }
        if len(images) > len(have):
            vals["images_json"] = _json.dumps(images, ensure_ascii=False)
        self.write(vals)
        return False

    @api.model
    def _cron_render_pending_images(self):
        """The advisory lock must stay SESSION-level: an xact lock would release
        at the first per-draft commit. Commit per draft so an Odoo cron-timeout
        kill cannot roll back — and re-pay for — images already rendered."""
        domain = [
            ("question_type", "in", list(IMAGE_QUESTION_TYPES)),
            ("image_state", "=", "pending"),
            ("image_brief_json", "!=", False),
            # Closes the window between Kill raising the flag and the run
            # settling. Without it this cron could pick up a killed
            # generator's drafts and start rendering them; the per-call
            # checkpoint in the service would still refuse, but only after
            # the draft had been claimed and marked failed for it.
            ("prompt_id.sop_gen_cancel_requested", "=", False),
        ]
        with cron_lock(self.env.cr, ADVISORY_LOCK_IMAGE_RENDER,
                       name="image_render",
                       queued=lambda: self.search_count(domain)) as got:
            if not got:
                return
            drafts = self.search(domain, limit=IMAGE_RENDER_BATCH)
            if not drafts:
                return
            _logger.info(
                "etp_assessment image cron: %d pending draft(s) to render",
                len(drafts))
            rendered = 0
            from ..services import vertex
            for draft in drafts:
                staged_key = (self.env.cr.dbname, draft.id)
                _STAGED_RENDERS.pop(staged_key, None)
                brief = draft.image_brief_json
                try:
                    with self.env.cr.savepoint():
                        done = draft.with_context(
                            stage_render=True)._render_all_images()
                    got.renew()
                    self.env.cr.commit()
                    # Counted only once committed: the savepoint's flush and the
                    # commit are where a lost race surfaces.
                    if done:
                        rendered += 1
                except vertex.VertexCancelledError:
                    # A kill is not a render failure. 'failed' is a state an
                    # admin is expected to retry from; this one they asked for.
                    self.env.cr.rollback()
                    _logger.info(
                        "Image render for draft %s stopped: its generator was "
                        "cancelled.", draft.id)
                    draft.write({"image_state": "cancelled"})
                    got.renew()
                    self.env.cr.commit()
                    continue
                except _TRANSIENT_DB_ERRORS as exc:
                    # The DB asking to try again, not a failed render. The
                    # render is paid for, so what it wrote is written again
                    # once; failing that, left `pending` (no attempt burned)
                    # for the next tick.
                    self.env.cr.rollback()
                    staged = _STAGED_RENDERS.pop(staged_key, None)
                    # Replayed only onto the row the render started from: an
                    # upload, cancel or new brief committed meanwhile wins.
                    if staged and draft.image_state == "pending" \
                            and draft.image_brief_json == brief:
                        try:
                            with self.env.cr.savepoint():
                                draft.write(staged)
                            got.renew()
                            self.env.cr.commit()
                            _logger.info(
                                "Image render for draft %s kept the paid "
                                "render through a lost race (%s).",
                                draft.id, type(exc).__name__)
                            if staged.get("image_state") == "rendered":
                                rendered += 1
                            continue
                        except Exception:  # noqa: BLE001 - the tick retries
                            self.env.cr.rollback()
                    _warn_lost_race(draft, "Image render for draft", exc)
                    continue
                except Exception:  # noqa: BLE001 - isolate per draft
                    self.env.cr.rollback()
                    _logger.exception(
                        "Auto-render failed for draft %s", draft.id)
                    draft.write({"image_state": "failed"})
                    got.renew()
                    self.env.cr.commit()
                    continue
                finally:
                    _STAGED_RENDERS.pop(staged_key, None)
            _logger.info(
                "etp_assessment image cron: rendered %d/%d draft(s)",
                rendered, len(drafts))
            # Chain the next batch while this one made progress. A 429 or a
            # failure waits for the 5-minute tick, so there is no hot loop.
            if rendered and self.search_count(domain):
                cron = self.env.ref(
                    "assessments_be_v2.ir_cron_render_pending_images",
                    raise_if_not_found=False)
                if cron:
                    cron.sudo()._trigger()

    def _video_briefs(self):
        import json as _json
        self.ensure_one()
        raw = (self.video_brief_json or "").strip()
        if not raw or raw in ("[]", "{}"):
            return []
        try:
            parsed = _json.loads(raw)
        except (ValueError, TypeError):
            return []
        if isinstance(parsed, dict):
            parsed = [parsed]
        if not isinstance(parsed, list):
            return []
        return [b for b in parsed
                if isinstance(b, dict) and (b.get("prompt") or "").strip()]

    def _video_ops(self):
        import json as _json
        self.ensure_one()
        try:
            ops = _json.loads(self.video_op_json or "{}")
        except (ValueError, TypeError):
            return {}
        return ops if isinstance(ops, dict) else {}

    def _video_files(self):
        import json as _json
        self.ensure_one()
        raw = (self.video_files_json or "").strip()
        if not raw or raw in ("[]", "{}"):
            return []
        try:
            parsed = _json.loads(raw)
        except (ValueError, TypeError):
            return []
        if isinstance(parsed, dict):
            parsed = [parsed]
        return [f for f in parsed if isinstance(f, dict)] \
            if isinstance(parsed, list) else []

    def _image_specs(self):
        """Parsed images_json as a list of dicts (image twin of _video_files).
        The draft-image preview route reads this to find a slot's staged spec."""
        import json as _json
        self.ensure_one()
        raw = (self.images_json or "").strip()
        if not raw or raw in ("[]", "{}"):
            return []
        try:
            parsed = _json.loads(raw)
        except (ValueError, TypeError):
            return []
        if isinstance(parsed, dict):
            parsed = [parsed]
        return [s for s in parsed if isinstance(s, dict)] \
            if isinstance(parsed, list) else []

    def _submit_video_ops(self):
        """A slot that already carries an op_name must never be re-submitted:
        the stored op_name is the idempotency handle against double-billing.

        A submit failure is captured PER SLOT rather than raised: letting it
        bubble aborted the loop, so one bad clip stopped its sibling from ever
        being submitted, and the caller replaced the real API text with a bare
        "submit failed" the reviewer could do nothing with.
        """
        import json as _json
        from ..services import vertex
        self.ensure_one()
        briefs = self._video_briefs()
        if not briefs:
            return False
        ops = self._video_ops()
        quota_hit = False
        for brief in briefs:
            slot = brief.get("slot") or "single"
            existing = ops.get(slot)
            if isinstance(existing, dict) and existing.get("op_name"):
                continue
            label = brief.get("label") or slot.title()
            try:
                op_name = vertex.submit_video_op(
                    self.env, brief, prompt_id=self.prompt_id.id or False)
            except vertex.VertexQuotaError:
                # Transient: leave the slot unsubmitted so the next tick
                # retries it. Never burn an attempt on a quota bounce.
                quota_hit = True
                break
            except Exception as exc:  # noqa: BLE001 - isolate per slot
                _logger.exception(
                    "Veo submit failed for draft %s slot %s", self.id, slot)
                prev = ops.get(slot)
                attempts = ((prev.get("attempts") or 0)
                            if isinstance(prev, dict) else 0) + 1
                ops[slot] = {
                    "op_name": False,
                    "state": "failed" if attempts >= _VIDEO_OP_MAX_ATTEMPTS
                             else "pending",
                    "attempts": attempts,
                    "label": label,
                    "error": str(exc)[:300],
                }
                continue
            ops[slot] = {"op_name": op_name, "state": "submitted",
                         "attempts": 0, "label": label, "error": False,
                         # The length Veo actually accepted (snapping/self-heal
                         # can move it), so the staged clip is described by its
                         # real duration rather than the requested one.
                         "duration_s": brief.get("applied_duration_s")
                                       or brief.get("duration_s") or False}
        slots = {b.get("slot") or "single" for b in briefs}
        all_submitted = all(
            isinstance(ops.get(s), dict) and ops[s].get("op_name")
            for s in slots)
        any_failed = any(
            isinstance(ops.get(s), dict) and ops[s].get("state") == "failed"
            for s in slots)
        # A slot that IS in flight must keep the draft in 'generating', even if
        # a sibling already failed: only 'generating' drafts get polled, so
        # settling to 'failed' here would strand an op we have already paid for
        # and never collect its clip.
        in_flight = any(
            isinstance(o, dict) and o.get("op_name")
            and o.get("state") not in ("done", "failed")
            for o in ops.values())
        vals = {"video_op_json": _json.dumps(ops, ensure_ascii=False)}
        if all_submitted or in_flight:
            vals["video_state"] = "generating"
            # Work is genuinely in progress, so a message describing the LAST
            # failure is stale - it would keep showing an old error against a
            # draft that is now generating fine.
            vals["video_error"] = False
        elif any_failed and not quota_hit:
            # Past the attempt cap on a real error - stop looping and tell the
            # reviewer what happened so they can fix the brief and retry. A clip
            # already staged from an earlier pass keeps this 'partial', so the
            # form still shows what we have.
            vals["video_state"] = "partial" if any(
                isinstance(f, dict) and (f.get("url") or f.get("data"))
                for f in self._video_files()) else "failed"
            vals["video_error"] = self._video_error_summary(ops)
        else:
            vals["video_state"] = "pending"
        self.write(vals)
        return all_submitted

    def _poll_video_ops(self):
        import json as _json
        from ..services import vertex, image_ingest
        self.ensure_one()
        ops = self._video_ops()
        if not ops:
            return False
        model = vertex._video_model(self.env)
        location = vertex._video_location(self.env)
        files = {f.get("slot"): f for f in self._video_files()
                 if isinstance(f, dict) and f.get("slot")}
        changed = False
        for slot, op in list(ops.items()):
            if not isinstance(op, dict) or op.get("state") == "done":
                continue
            op_name = op.get("op_name")
            if not op_name:
                continue
            try:
                result = vertex.fetch_video_op(
                    self.env, op_name, model=model, location=location,
                    prompt_id=self.prompt_id.id)
            except vertex.VertexQuotaError:
                continue
            except Exception as exc:  # noqa: BLE001 - bounded, per-op
                op["attempts"] = (op.get("attempts") or 0) + 1
                changed = True
                if op["attempts"] >= _VIDEO_OP_MAX_ATTEMPTS:
                    op["state"] = "failed"
                    # Keep the reason ON THE SLOT: with 2 clips, a single
                    # draft-level string cannot say WHICH one failed.
                    op["error"] = str(exc)[:300]
                continue
            if not result.get("done"):
                continue
            b64 = result.get("video_b64")
            gcs = result.get("gcs_uri")
            if result.get("error") or (not b64 and not gcs):
                op["attempts"] = (op.get("attempts") or 0) + 1
                changed = True
                if op["attempts"] >= _VIDEO_OP_MAX_ATTEMPTS:
                    op["state"] = "failed"
                    op["error"] = (result.get("error")
                                   or "op done but returned no video bytes/GCS uri")[:300]
                continue
            url, stored_b64 = (False, False)
            if b64:
                url, stored_b64 = image_ingest.ingest(
                    self.env, None, b64, content_type="video/mp4",
                    key_hint="qvideo-gen-%s-%s" % (self.id, slot))
            elif gcs:
                url = gcs
            files[slot] = {
                "slot": slot,
                "label": op.get("label") or slot.title(),
                "url": url or False,
                "data": ("data:video/mp4;base64,%s" % stored_b64)
                        if stored_b64 else False,
                # Whatever length Veo actually produced. We accept the clip
                # regardless of the number: a duration we did not ask for is
                # not a reason to bin a generated (and billed) asset.
                "duration_s": op.get("duration_s") or False,
            }
            op["state"] = "done"
            op["error"] = False
            changed = True
        vals = {}
        if changed:
            vals["video_op_json"] = _json.dumps(ops, ensure_ascii=False)
            vals["video_files_json"] = _json.dumps(
                list(files.values()), ensure_ascii=False)
        any_failed = any(isinstance(o, dict) and o.get("state") == "failed"
                         for o in ops.values())
        all_done = bool(ops) and all(
            isinstance(o, dict) and o.get("state") == "done"
            for o in ops.values())
        # Same rule as submit: never settle while a sibling op is still in
        # flight, or the poll cron stops looking at this draft and the clip we
        # already paid for is orphaned.
        in_flight = any(
            isinstance(o, dict) and o.get("op_name")
            and o.get("state") not in ("done", "failed")
            for o in ops.values())
        if all_done:
            vals["video_state"] = "rendered"
            vals["video_error"] = False
        elif any_failed and not in_flight:
            # Some clips may still have come back fine. Those are real, paid-for
            # assets: report 'partial' so the form SHOWS them (and the reviewer
            # can approve as-is) instead of a blanket 'failed' that reads as
            # "nothing survived".
            staged = any(
                isinstance(f, dict) and (f.get("url") or f.get("data"))
                for f in files.values())
            vals["video_state"] = "partial" if staged else "failed"
            vals["video_error"] = self._video_error_summary(ops)

        if vals:
            self.write(vals)
        # A clip that came back at a length we did not ask for is KEPT, so the
        # wording that describes it has to follow the asset. Do this after the
        # write so the realignment sees the freshly staged durations - and on
        # partial too, since the clips that did land are already viewable.
        if vals.get("video_state") in ("rendered", "partial"):
            applied = {slot: op.get("duration_s")
                       for slot, op in (ops or {}).items()
                       if isinstance(op, dict) and op.get("state") == "done"
                       and op.get("duration_s")}
            if applied:
                try:
                    self._align_video_answer_key(applied)
                except Exception:  # noqa: BLE001 - never lose a staged clip
                    _logger.exception(
                        "etp_assessment could not realign draft %s to the "
                        "rendered clip lengths", self.id)
        return vals.get("video_state") == "rendered"

    _DURATION_MENTION_TMPL = (
        r"\b%d\s*(?:s\b|sec\b|secs\b|second\b|seconds\b)")

    def _align_video_answer_key(self, applied):
        """Re-word any clip length the brief/answer key states but Veo changed.

        Veo only renders an enumerated set of lengths, so a 7s brief is
        submitted at 8s. If the brief text and the answer key keep SAYING
        "7 seconds", the published question is graded against a length the
        candidate never saw - the exact drift the reviewer is asked to check.
        Rewrite the stated number to the length actually rendered.

        ``applied`` maps slot -> real duration. Only slots whose length moved
        are touched, and only a number followed by a seconds unit is rewritten,
        so unrelated figures in the prose survive untouched.
        """
        import json as _json
        import re as _re
        self.ensure_one()
        briefs = self._video_briefs()
        if not briefs or not applied:
            return False

        moved = {}
        for brief in briefs:
            slot = brief.get("slot") or "single"
            new = applied.get(slot)
            try:
                old = int(brief.get("duration_s") or 0)
                new = int(new or 0)
            except (TypeError, ValueError):
                continue
            if old and new and old != new:
                moved[slot] = (old, new)
        if not moved:
            return False

        def _retime(text):
            out = text or ""
            for old, new in moved.values():
                out = _re.sub(self._DURATION_MENTION_TMPL % old,
                              "%d seconds" % new, out, flags=_re.IGNORECASE)
            return out

        # 1. The briefs themselves, so a retry re-submits the corrected text.
        for brief in briefs:
            slot = brief.get("slot") or "single"
            if slot in moved:
                brief["duration_s"] = moved[slot][1]
            brief["prompt"] = _retime(brief.get("prompt"))
        vals = {"video_brief_json": _json.dumps(briefs, ensure_ascii=False)}

        # 2. The answer key, which is what the candidate is graded against.
        try:
            key = _json.loads(self.rubric_json or "{}")
        except (ValueError, TypeError):
            key = {}
        if isinstance(key, dict) and key:
            for k, v in list(key.items()):
                if isinstance(v, str):
                    key[k] = _retime(v)
                elif isinstance(v, list):
                    key[k] = [_retime(x) if isinstance(x, str) else x
                              for x in v]
            vals["rubric_json"] = _json.dumps(key, ensure_ascii=False)

        # 3. The candidate-facing stem, if it quotes a length.
        if self.question_prompt:
            vals["question_prompt"] = _retime(self.question_prompt)
        self.write(vals)
        _logger.info(
            "etp_assessment realigned draft %s answer key to the clip lengths "
            "Veo actually rendered: %s", self.id,
            {s: "%ss->%ss" % v for s, v in moved.items()})
        return True

    def _video_failure_state(self):
        """'partial' when a usable clip is already staged, else 'failed'.

        A clip we already generated (and paid for) is still valuable when a
        LATER step blows up, so a failure must never downgrade the draft to a
        blanket 'failed' that hides the asset from the reviewer.
        """
        self.ensure_one()
        staged = any(
            isinstance(f, dict) and (f.get("url") or f.get("data"))
            for f in self._video_files())
        return "partial" if staged else "failed"

    def _video_error_summary(self, ops):
        """One reviewer-facing line per FAILED slot, naming the clip.

        A video_prompt draft usually has TWO clips (reference + output). When
        only one fails the other is already staged and viewable, so a bare
        "Video generation failed." is actively misleading - it reads as though
        the whole draft is dead. Name the failing clip(s) and translate the raw
        Veo string into something the reviewer can act on.
        """
        from ..services import vertex
        model = vertex._video_model(self.env)
        parts = []
        for slot in sorted(ops or {},
                           key=lambda s: {"reference": 0, "output": 1,
                                          "single": 2}.get(s, 3)):
            op = ops.get(slot)
            if not isinstance(op, dict) or op.get("state") != "failed":
                continue
            label = op.get("label") or slot.title()
            parts.append("%s clip: %s" % (
                label, vertex.humanize_video_error(op.get("error"), model)))
        if not parts:
            return "Video generation failed."
        done = sum(1 for o in (ops or {}).values()
                   if isinstance(o, dict) and o.get("state") == "done")
        head = ""
        if done:
            head = ("%d of %d clips generated fine; the rest failed. "
                    % (done, len(ops)))
        return (head + " | ".join(parts))[:1000]

    def action_retry_video_generation(self):
        """Re-attempt ONLY the clips that failed; keep the ones that worked.

        The stored ``op_name`` is the anti-double-bill idempotency handle, so a
        successful slot is left completely untouched (its clip stays staged and
        it is never re-billed). A failed slot has its op cleared, which is what
        makes ``_submit_video_ops`` willing to submit it again on the next cron
        tick.
        """
        import json as _json
        from ..services import vertex
        self.ensure_one()
        if self.question_type not in VIDEO_QUESTION_TYPES:
            return self._notify(
                "Not a Video Question",
                "Only a video question can regenerate clips.", "warning")
        briefs = self._video_briefs()
        if not briefs:
            return self._notify(
                "No Briefs",
                "This draft has no video briefs to generate from. Add a clip "
                "brief in Advanced (raw JSON), or upload the clips manually.",
                "warning")
        if not vertex.video_generation_available(self.env):
            return self._notify(
                "Veo Not Configured",
                "Video generation needs a Vertex service account (or access "
                "token) and a Veo model configured in Settings. Until then "
                "clips must be uploaded manually.", "warning")
        ops = self._video_ops()
        retried = [slot for slot, op in ops.items()
                   if not isinstance(op, dict) or op.get("state") == "failed"]
        kept = [slot for slot, op in ops.items()
                if isinstance(op, dict) and op.get("state") == "done"]
        if ops and not retried:
            # Only refuse when we positively know every slot is already done.
            # An EMPTY ops dict means nothing was ever submitted (e.g. the
            # submit itself blew up), which is exactly a case worth retrying.
            return self._notify(
                "Nothing to Retry",
                "Every clip on this draft already generated.", "warning")
        # Drop the failed slots' ops entirely: a cleared slot is exactly what
        # _submit_video_ops treats as "needs submitting".
        ops = {slot: op for slot, op in ops.items() if slot in kept}
        self.write({
            "video_op_json": _json.dumps(ops, ensure_ascii=False),
            "video_state": "pending",
            "video_error": False,
        })
        if kept:
            msg = ("Retrying %d failed clip(s); keeping the %d that already "
                   "generated. The clips are submitted on the next cron tick "
                   "(about 2 minutes)." % (len(retried), len(kept)))
        else:
            msg = ("Retrying %d clip(s). They are submitted on the next cron "
                   "tick (about 2 minutes)." % len(retried))
        return self._notify("Retry Queued", msg)

    def action_retry_image_render(self):
        """Put drafts whose image render failed back in the render queue.

        `images_json` is KEPT: `_render_all_images` renders only the slots with
        no picture yet, so a slot that already rendered is not paid for twice.
        The attempt counter restarts, or the cron's 3-strike rule would fail
        the draft again on its first incomplete render.
        """
        failed = self.filtered(lambda d: d.image_state == "failed")
        if not failed:
            return self._notify(
                "Nothing to Retry", "No image render failed here.", "warning")
        failed.write({"image_state": "pending", "image_render_attempts": 0,
                      "image_error": False})
        return self._notify(
            "Retry Queued",
            "Retrying the images of %d draft(s); images that already rendered "
            "are kept. The render cron takes %d draft(s) per run."
            % (len(failed), IMAGE_RENDER_BATCH))

    def _materialize_videos(self, bank_question):
        self.ensure_one()
        files = self._video_files()
        if not files:
            return
        from ..services import image_ingest
        Video = self.env["assessments.be.question.video"]
        seq = {"reference": 10, "output": 20, "single": 30}
        for f in files:
            slot = (f.get("slot") or "single").strip().lower()
            if slot not in ("reference", "output", "single"):
                slot = "single"
            url = f.get("url") or False
            b64 = False
            data = f.get("data")
            if not url and data:
                url, b64 = image_ingest.ingest(
                    self.env, None, data, content_type="video/mp4",
                    key_hint="qvideo-%s-%s" % (bank_question.id, slot))
            Video.create({
                "question_id": bank_question.id,
                "slot": slot,
                "label": f.get("label") or slot.title(),
                "video_url": url or False,
                "video": b64 or False,
                "duration_s": f.get("duration_s") or 0,
                "sequence": seq.get(slot, 30),
            })

    def _submit_pending_video_ops(self):
        from ..services import vertex
        if not vertex.video_generation_available(self.env):
            return
        drafts = self.search([
            ("question_type", "in", list(VIDEO_QUESTION_TYPES)),
            ("video_state", "=", "pending"),
            ("video_brief_json", "!=", False),
            # Veo is the most expensive call the module makes. A killed
            # generator must not reach it, however narrow the window.
            ("prompt_id.sop_gen_cancel_requested", "=", False),
        ], limit=2)
        for draft in drafts:
            try:
                with self.env.cr.savepoint():
                    draft._submit_video_ops()
                self.env.cr.commit()
            except _TRANSIENT_DB_ERRORS:
                # A serialization failure / deadlock / lock timeout is the DB
                # asking us to try again - it says NOTHING about the clips. The
                # next cron tick re-runs this draft, so leave its state alone
                # instead of branding a healthy draft as a video failure.
                self.env.cr.rollback()
                _logger.info(
                    "Video op submit for draft %s hit a transient DB "
                    "concurrency error; leaving state untouched for the next "
                    "tick", draft.id)
            except Exception as exc:  # noqa: BLE001 - isolate per draft
                self.env.cr.rollback()
                _logger.exception(
                    "Video op submit failed for draft %s", draft.id)
                draft.write({"video_state": draft._video_failure_state(),
                             "video_error": "Could not submit the clips to "
                                            "Veo: %s" % str(exc)[:300]})
                self.env.cr.commit()

    def _poll_generating_video_ops(self):
        # A killed generator's ops are already billed, but polling them keeps a
        # worker busy on a run nobody wants. `_cancel_pending_media` moves them
        # out of 'generating' at settle time; this clause covers the tick in
        # between.
        drafts = self.search([
            ("question_type", "in", list(VIDEO_QUESTION_TYPES)),
            ("video_state", "=", "generating"),
            ("prompt_id.sop_gen_cancel_requested", "=", False),
        ], limit=4)
        for draft in drafts:
            try:
                with self.env.cr.savepoint():
                    draft._poll_video_ops()
                self.env.cr.commit()
            except _TRANSIENT_DB_ERRORS:
                # Transient DB contention, not a Veo problem. The ops are
                # untouched and still pollable, so re-reading them next tick
                # collects the clips; writing a failure here would strand a
                # draft whose clips actually rendered fine.
                self.env.cr.rollback()
                _logger.info(
                    "Video op poll for draft %s hit a transient DB "
                    "concurrency error; will retry on the next tick",
                    draft.id)
            except Exception as exc:  # noqa: BLE001 - isolate per draft
                self.env.cr.rollback()
                _logger.exception(
                    "Video op poll failed for draft %s", draft.id)
                draft.write({"video_state": draft._video_failure_state(),
                             "video_error": "Could not check the clip "
                                            "generation status: %s"
                                            % str(exc)[:300]})
                self.env.cr.commit()

    @api.model
    def _cron_poll_video_ops(self):
        """The advisory lock must stay SESSION-level: an xact lock would release
        at the first per-draft commit."""
        with cron_lock(self.env.cr, ADVISORY_LOCK_VIDEO_POLL,
                       name="video_poll",
                       queued=lambda: self.search_count([
                           ("question_type", "in", list(VIDEO_QUESTION_TYPES)),
                           ("video_state", "in", ("pending", "generating")),
                           ("prompt_id.sop_gen_cancel_requested", "=", False),
                       ])) as got:
            if not got:
                return
            # The per-draft commits are inside these two; each renewal is
            # saved by the first of them.
            got.renew()
            self._submit_pending_video_ops()
            got.renew()
            self._poll_generating_video_ops()

    def action_apply_uploaded_image(self):
        import json as _json
        self.ensure_one()
        if not self.upload_image:
            return self._notify(
                "No File", "Attach an image in 'Upload Replacement Image' "
                "first.", "warning")
        slot = (self.upload_slot or "a").strip().lower()
        raw_b64 = self.upload_image
        if isinstance(raw_b64, bytes):
            raw_b64 = raw_b64.decode("ascii", errors="ignore")
        data_url = "data:image/png;base64,%s" % raw_b64
        kept = [i for i in self._current_images()
                if (i.get("slot") or "").lower() != slot]
        kept.append({"slot": slot, "label": slot.title(), "data": data_url})
        self.write({
            "images_json": _json.dumps(kept, ensure_ascii=False),
            "image_state": "uploaded",
            "image_error": False,
            "upload_image": False,
        })
        return self._notify(
            "Image Uploaded", "Your image now fills slot %r." % slot)


# Formats _extract_text() intentionally does NOT extract: they are passed to the
# multimodal model as inline document parts instead. Kept beside _extract_text so
# the two cannot drift apart - _compute_status reads this to avoid flagging them.
NATIVE_DOC_EXTENSIONS = ("pdf", "png", "jpg", "jpeg", "webp", "gif")


class EtpAssessmentPromptResource(models.Model):
    _name = "assessments.be.prompt.resource"
    _description = "Prompt Resource File"
    _order = "sequence, id"

    prompt_id = fields.Many2one(
        "assessments.be.prompt", required=True, ondelete="cascade"
    )
    sequence = fields.Integer(default=10)
    name = fields.Char(string="Filename")
    category = fields.Selection(
        [("sop", "SOP"), ("reference", "Reference"), ("sample", "Sample Questions"),
         ("golden", "Golden Examples"),
         ("vendor", "Vendor"), ("client", "Client"), ("other", "Other")],
        default="other", required=True, index=True,
        help="Sample Questions (also called golden questions): worked "
             "examples of this SOP's task. Generation matches their format; "
             "Draft from SOP reads them as the ground truth for shape. "
             "'Golden Examples' is the same list under its old name - kept "
             "for older rows, never written.",
    )
    file = fields.Binary(string="File", attachment=True, required=True)
    extracted_text = fields.Text(readonly=True)
    extraction_error = fields.Char(readonly=True)
    char_count = fields.Integer(
        compute="_compute_char_count", store=True
    )
    status = fields.Selection(
        [("pending", "Uploaded"), ("ready", "Ready"), ("native", "Sent natively"),
         ("failed", "Failed")],
        compute="_compute_status", string="Status",
        help="Ready = text extracted; Sent natively = PDF/image read directly by the "
             "multimodal model, so no text extraction is expected; Uploaded = stored, "
             "text not extracted yet; Failed = extraction error.")

    @api.depends("extracted_text")
    def _compute_char_count(self):
        for rec in self:
            rec.char_count = len(rec.extracted_text or "")

    @api.depends("extracted_text", "extraction_error", "file", "name")
    def _compute_status(self):
        for rec in self:
            ext = (rec.name or "").rsplit(".", 1)[-1].lower()
            if rec.extraction_error:
                rec.status = "failed"
            elif (rec.extracted_text or "").strip():
                rec.status = "ready"
            elif ext in NATIVE_DOC_EXTENSIONS:
                # _extract_text() deliberately returns empty-with-no-error for these:
                # they go to the model as inline document parts. Reporting them as
                # "pending" left a permanent amber dot on a perfectly good PDF.
                rec.status = "native"
            else:
                rec.status = "pending"

    @staticmethod
    def _extract_docx(raw):
        import io
        import re as _re
        import zipfile
        try:
            from defusedxml.ElementTree import fromstring as _xml_fromstring
        except ImportError as exc:
            # H-12: do NOT silently fall back to stdlib xml.etree — it is exposed
            # to billion-laughs entity expansion on an attacker .docx. defusedxml
            # is a declared manifest dependency; if it is missing, fail loudly.
            raise RuntimeError(
                "defusedxml is required to parse .docx uploads safely. "
                "Install it: pip install defusedxml") from exc

        ns = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
        with zipfile.ZipFile(io.BytesIO(raw)) as zf:
            # H-13: cap the UNCOMPRESSED size before reading. A ~10MB deflate
            # zip can hold a >10GB member (zip bomb) that OOMs the worker when
            # zf.read decompresses it whole. 40MB is far above any real SOP.
            _MAX_DOCX_XML = 40 * 1024 * 1024
            try:
                info = zf.getinfo("word/document.xml")
            except KeyError:
                raise ValueError("docx has no word/document.xml")
            if info.file_size > _MAX_DOCX_XML:
                raise ValueError(
                    "docx word/document.xml is %d bytes (> %d cap); refused as "
                    "a possible zip bomb." % (info.file_size, _MAX_DOCX_XML))
            xml_bytes = zf.read("word/document.xml")
        root = _xml_fromstring(xml_bytes)
        paragraphs = []
        for p in root.iter(f"{ns}p"):
            texts = [t.text or "" for t in p.iter(f"{ns}t")]
            line = "".join(texts).strip()
            if line:
                paragraphs.append(line)
        text = "\n".join(paragraphs)
        return _re.sub(r"\n{3,}", "\n\n", text)

    def _extract_text(self):
        self.ensure_one()
        import base64

        raw = base64.b64decode(self.file or b"")
        if not raw:
            return "", "Empty file."
        ext = (self.name or "").rsplit(".", 1)[-1].lower()
        try:
            # Through `upload_text` on every path: a NUL in `extracted_text`
            # 500s the upload at flush (a Windows "Unicode" .txt/.csv).
            if ext == "docx":
                return upload_text(self._extract_docx(raw)), False
            if ext in ("txt", "md", "markdown", "csv", "html", "htm", "json",
                       "xml"):
                text = upload_text(raw, fallback="utf-8")
                if ext in ("html", "htm"):
                    import re as _re
                    text = _re.sub(r"<[^>]+>", " ", text)
                    text = _re.sub(r"\s+", " ", text)
                return text, False
            if ext in NATIVE_DOC_EXTENSIONS:
                # Sent natively to the model by _sop_doc_parts: empty
                # extracted_text is expected here, not an error.
                return "", False
            return "", f"Unsupported file type '.{ext}'."
        except Exception as exc:
            _logger.exception("Resource extraction failed: %s", self.name)
            return "", str(exc)[:300]

    def _run_extraction(self):
        for rec in self:
            text, error = rec._extract_text()
            rec.write({
                "extracted_text": text or False,
                "extraction_error": error or False,
            })

    def init(self):
        # ONE LIST (owner, 2026-09-29): golden questions ARE sample questions.
        # Idempotent, so it is safe on every `-u`.
        self.env.cr.execute(
            "UPDATE assessments_be_prompt_resource SET category = 'sample' "
            "WHERE category = 'golden'")

    @api.model_create_multi
    def create(self, vals_list):
        for vals in vals_list:
            if vals.get("category") == "golden":  # an older client
                vals["category"] = "sample"
        records = super().create(vals_list)
        records._run_extraction()
        return records

    def write(self, vals):
        if vals.get("category") == "golden":
            vals = dict(vals, category="sample")
        res = super().write(vals)
        if "file" in vals or "name" in vals:
            self._run_extraction()
        return res
