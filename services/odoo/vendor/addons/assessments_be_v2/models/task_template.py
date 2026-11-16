"""Reusable task templates: the shape of a task, saved once and generated from.

WHY. An SOP describes a task in prose. The generator reads that prose and infers
a shape, which is right often enough to be useful and wrong often enough to cost
a review cycle. A template lets the admin state the shape ONCE - these axes,
these options, this many assets, a justification or not - and then ask for N
items in exactly that shape.

REUSE, DON'T REBUILD. The Form Studio already models "a structured set of
questions with an answer key" (`etp.studio.form`) and already maps every designer
item onto a question spec (`studio_form._item_spec`). A template stores the same
`structure_json` and borrows that mapping, so the designer, its validation and
its media handling all work unchanged.

NOT `publish_to_assessment`. That path mints a fresh generator plus a draft
assessment per publish, because a published form IS an exam. A template is an
INPUT to generation, so it deliberately does not go near it.
"""
import json
import logging

from odoo import models, fields, api, _
from odoo.exceptions import ValidationError

from ..constants import (
    FORM_KINDS_MEDIA_BLOCK,
    GENERATABLE_QUESTION_TYPE_ORDER,
    TASK_PRIMITIVE_TO_QUESTION_TYPE,
    TASK_RESPONSE_PRIMITIVES,
    parse_shape_quotas,
    parse_task_registry,
)

_logger = logging.getLogger(__name__)

#: What each response primitive is called on screen - the app's own labels
#: (`task_template_editor.dart` kResponsePrimitives). Labels only: the stored
#: values are unchanged.
RESPONSE_LABELS = {
    "single_choice": "Pick one option",
    "multi_choice": "Pick any number of options",
    "free_text": "Write an answer",
    "compare_two": "Compare two candidates",
    "annotate_image": "Mark points on an image",
    "author_prompt": "Write a prompt for an image",
    "author_video_prompt": "Write a prompt for a clip",
    "describe_media": "Describe an image or clip",
}

#: Which answer-key fields each primitive uses, as the app's editor decides it.
#: The form shows only these, and an Odoo save clears the rest - left behind,
#: a previous primitive's key would still reach generation.
RUBRIC_PRIMITIVES = ("free_text", "describe_media")
ANNOTATION_PRIMITIVES = ("annotate_image",)
MEDIA_BRIEF_PRIMITIVES = (
    "compare_two", "author_prompt", "author_video_prompt", "annotate_image")

_CHOICE_KINDS = ("multipleChoice", "checkboxes", "dropdown")
_GRID_KINDS = ("choiceGrid", "checkboxGrid")


def unused_answer_key_blanks(response):
    """Blank values for the answer-key fields `response` does not use."""
    blanks = {}
    if response not in RUBRIC_PRIMITIVES:
        blanks.update(rubric_criteria="", rubric_pass_condition="",
                      rubric_constraints="")
    if response not in ANNOTATION_PRIMITIVES:
        blanks.update(annotation_targets="", annotation_expected_count=0)
    if response not in MEDIA_BRIEF_PRIMITIVES:
        blanks["media_brief"] = ""
    return blanks


class AssessmentsBeTaskTemplate(models.Model):
    _name = "assessments.be.task.template"
    _description = "Reusable task template for question generation"
    _order = "write_date desc, id desc"

    name = fields.Char(
        required=True, default="Untitled task",
        help="What the admin picks in the Task to generate dropdown.")
    structure_json = fields.Json(
        default=list,
        help="The Form Studio structure for this task, same shape "
             "etp.studio.form.structure_json holds. Reusing that shape is what "
             "lets the existing designer author a template.")
    instructions = fields.Text(
        default="",
        help="What the model is told this shape means, in the admin's own "
             "words. Appended to the generation directive for items of this "
             "task, never shown to a candidate.")

    # A template's own answer contract. Same vocabulary as the SOP task
    # registry, so a template and an extracted task are interchangeable inputs
    # to generation - one code path, not two.
    response = fields.Selection(
        selection=[(p, RESPONSE_LABELS.get(p) or p.replace("_", " ").title())
                   for p in TASK_RESPONSE_PRIMITIVES],
        default="single_choice", required=True,
        help="The response primitive a candidate performs. These are CLOSED: a "
             "new project brings new axes and options (data), never a new "
             "primitive (code).")
    question_type = fields.Char(
        compute="_compute_question_type", store=True,
        help="The stored question type this template's primitive maps to. "
             "Computed, never chosen: the primitive is the admin-facing idea "
             "and TASK_PRIMITIVE_TO_QUESTION_TYPE is the single mapping.")

    origin_prompt_id = fields.Many2one(
        "assessments.be.prompt", string="Origin SOP",
        ondelete="set null", index=True,
        help="The generator whose SOP this template was authored against, so "
             "the library list is legible. NULLABLE ON PURPOSE: a template "
             "outlives its generator - a non-null FK here would either block "
             "deleting a generator or cascade away the admin's library.")

    authored_by = fields.Selection(
        [("manual", "Written by hand"),
         ("llm_edited", "Drafted by the model, edited by a human")],
        default="manual", required=True,
        help="Provenance. An LLM draft is only ever saved after a human edits "
             "it, so there is no 'llm' value: unedited drafts are not saved.")

    active = fields.Boolean(
        default=True,
        help="Archive rather than delete. A launched assessment may cite a "
             "template, and its questions are already frozen.")

    # ---- Per-primitive answer-key data -------------------------------------
    # A template used to carry axes+options only, which is exactly what an A/B
    # item needs and almost nothing of what the other primitives need. Their
    # answer keys were therefore invented by the model with no examiner input,
    # so the key was not provable by construction and there was nothing for a
    # quality pass to tune. Each field below is the examiner's own statement of
    # the key for one family of primitives; all are optional, so an existing
    # template keeps working untouched.
    rubric_criteria = fields.Text(
        default="",
        help="One gradable criterion per line, for a written answer. These "
             "become the rubric CHECKLIST the grader marks against, instead of "
             "the model inventing its own. Used by Write an answer / Describe "
             "an image or clip.")
    rubric_pass_condition = fields.Char(
        default="",
        help="What a passing answer must do, in the examiner's words. The "
             "grader needs this to decide a mark rather than guess one.")
    rubric_constraints = fields.Text(
        default="",
        help="Limits the answer must respect (length, tone, what to avoid). "
             "Optional; blank means the type's own default applies.")

    annotation_targets = fields.Text(
        default="",
        help="One expected annotation per line - what the candidate must mark "
             "on the image. These become the answer key's ideal labels, so "
             "coverage and precision are graded against the examiner's list "
             "instead of one the model made up. Used by Mark points on an image.")
    annotation_expected_count = fields.Integer(
        default=0,
        help="How many marks a complete answer has. 0 means derive it from the "
             "target list. Stated separately because a task can ask for 'any "
             "three of these five'.")

    media_brief = fields.Text(
        default="",
        help="What the generated image or clip must show, in the examiner's "
             "words. Anchors the stimulus so every generated item is a "
             "variation on the same task rather than a different one. Used by "
             "Write a prompt / Describe an image or clip.")

    item_count = fields.Integer(
        compute="_compute_item_count", store=True,
        help="How many questions this template's structure describes.")

    usable_count = fields.Integer(
        compute="_compute_usable_count", store=True,
        help="How many of this template's questions would actually GENERATE. "
             "Lower than item_count when a question fails its type's answer-key "
             "contract - most often a choice question with no correct option "
             "marked, which the designer allows saving so a half-authored "
             "template is not lost.")

    # ---- What the generator page shows on each template row --------------
    # The app's badges, as text so a list can draw them. Computed, never
    # stored: no columns.
    draft_badge = fields.Char(compute="_compute_badges")
    usable_badge = fields.Char(compute="_compute_badges")
    fix_badge = fields.Char(compute="_compute_badges")
    run_badge = fields.Char(compute="_compute_badges")
    shape_line = fields.Char(string="Shape", compute="_compute_badges")

    generate_problems = fields.Text(
        string="Fix before generating", compute="_compute_generate_problems",
        help="What stops part of this template generating, one per line - "
             "the app editor's own checks. Shown, never enforced: a "
             "half-authored template saves.")

    @api.depends("authored_by", "item_count", "usable_count",
                 "shape_warnings", "structure_json",
                 "origin_prompt_id.shape_quota_json")
    def _compute_badges(self):
        for rec in self:
            rec.draft_badge = ("Model draft, edited"
                               if rec.authored_by == "llm_edited" else "")
            if rec.item_count and not rec.usable_count:
                rec.usable_badge = "Generates nothing"
            elif rec.usable_count < rec.item_count:
                rec.usable_badge = "Only %d of %d usable" % (
                    rec.usable_count, rec.item_count)
            else:
                rec.usable_badge = ""
            warns = [w for w in (rec.shape_warnings or "").split("\n") if w]
            rec.fix_badge = ("" if not warns else "Needs attention"
                             if len(warns) == 1
                             else "%d things to fix" % len(warns))
            used = 0
            if rec.origin_prompt_id and isinstance(rec.id, int):
                used = parse_shape_quotas(
                    rec.origin_prompt_id.shape_quota_json).get(
                        "template:%d" % rec.id, 0)
            rec.run_badge = "\u00d7 %d this run" % used if used else ""
            rec.shape_line = rec.shape_summary() if rec.id else ""

    @api.depends("name", "structure_json")
    def _compute_generate_problems(self):
        for rec in self:
            out = []
            if not (rec.name or "").strip():
                out.append("Give the task a name.")
            items = rec._items()
            if not items:
                out.append("Add at least one question.")
            for item in items:
                title = str(item.get("title") or "").strip()
                title = '"%s"' % title if title else "an untitled question"
                kind = str(item.get("kind") or "")
                labelled = [o for o in (item.get("options") or [])
                            if str((o.get("label") if isinstance(o, dict)
                                    else o) or "").strip()]
                if kind in _CHOICE_KINDS and len(labelled) < 2:
                    out.append("%s needs at least two options." % title)
                elif kind in _GRID_KINDS and not (
                        item.get("rows") and item.get("columns")):
                    out.append(
                        "%s needs at least one row and one column." % title)
                elif kind == "comparePair" and len(labelled) < 2:
                    out.append(
                        "%s needs at least two verdict options." % title)
            rec.generate_problems = "\n".join(out)

    def web_save(self, vals, specification, next_id=None):
        """An admin's save in Odoo clears the answer-key fields the chosen
        response does not use, as the app's editor does on its own save.

        HERE AND NOT IN `write`: this is the form's save and nothing else, so
        the API route, archiving and internal writes are unaffected.
        """
        response = vals.get("response") or (
            self[:1].response if self else None) or "single_choice"
        vals = dict(vals, **unused_answer_key_blanks(response))
        return super().web_save(vals, specification, next_id=next_id)

    def write(self, vals):
        archiving = "active" in vals and not vals["active"]
        gone = self.filtered("active") if archiving else self.browse()
        res = super().write(vals)
        if gone:
            gone._drop_from_generator_counts()
        return res

    def _drop_from_generator_counts(self):
        """Archiving a template takes it out of every generator's counts.

        Left behind, the count would still inflate the run's total and the app
        would refuse every later count edit ("These tasks are archived").
        Un-archiving does not put the counts back.

        The questions count follows what is left: a pinned count becomes the
        sum of the remaining picks, Auto stays Auto, and no picks left means
        Auto - a leftover count would fail the type check (R5-02).
        """
        Prompt = self.env["assessments.be.prompt"].with_context(
            active_test=False)
        for rec in self:
            key = "template:%d" % rec.id
            for gen in Prompt.search(
                    [("shape_quota_json", "like", '"%s"' % key)]):
                quotas = parse_shape_quotas(gen.shape_quota_json)
                if key not in quotas:
                    continue
                quotas.pop(key)
                vals = {"shape_quota_json": (
                    json.dumps(quotas, ensure_ascii=False) if quotas else "")}
                if not quotas:
                    vals["sop_question_count"] = 0
                elif gen.sop_question_count:
                    vals["sop_question_count"] = sum(quotas.values())
                gen.write(vals)
                count = gen.sop_question_count
                gen._log_activity(
                    'Question template "%s" was archived and removed from '
                    "this generator. Questions to generate: %s."
                    % (rec.name, count or "Auto (model decides)"))

    def action_open_template(self):
        """Edit, from a generator's Question Templates list."""
        self.ensure_one()
        return {
            "type": "ir.actions.act_window",
            "name": "Question Template",
            "res_model": self._name,
            "res_id": self.id,
            "view_mode": "form",
            "views": [[self.env.ref(
                "assessments_be_v2.assessments_be_task_template_form").id,
                "form"]],
            "target": "current",
        }

    @api.depends("response")
    def _compute_question_type(self):
        for rec in self:
            rec.question_type = TASK_PRIMITIVE_TO_QUESTION_TYPE.get(
                rec.response) or ""

    # ------------------------------------------------------------------
    # WHAT IS WRONG WITH THIS TEMPLATE, KEPT ON THE RECORD.
    #
    # These checks ran once, at DRAFT time, and were surfaced as a toast. A
    # toast lasts three seconds and belongs to the tab that saw it: dismiss it,
    # reload, or open the template tomorrow, and every warning is gone. The
    # template then looks identical to a correct one - same name, same counts,
    # no badge - which is exactly the state `usable_count` was introduced to
    # stop being invisible.
    #
    # COMPUTED, NOT STORED-BY-THE-DRAFTER, so it cannot go stale: an examiner
    # who fixes the brief clears the warning by fixing it, and one who edits a
    # good template into a broken one earns the warning without another LLM
    # call. `store=True` only so a list view can read it without recomputing
    # every row.
    # ------------------------------------------------------------------
    shape_warnings = fields.Text(
        compute="_compute_shape_warnings", store=True,
        help="What would go wrong if this template were generated from, one "
             "per line. Empty when nothing is wrong. Recomputed on every edit, "
             "so fixing the cause clears the warning.")

    has_shape_warnings = fields.Boolean(
        compute="_compute_shape_warnings", store=True,
        help="True when this template would generate something the examiner "
             "probably did not mean. Does NOT block generation - which shape "
             "is right is a judgement, and refusing here would hide the "
             "problem behind a disabled button.")

    @api.depends("response", "media_brief", "structure_json",
                 "origin_prompt_id")
    def _compute_shape_warnings(self):
        # Imported here rather than at module scope: `services.vertex` reaches
        # for Vertex credentials on some paths, and a model import runs at
        # registry build time on every database.
        from ..services import vertex
        for rec in self:
            tasks = parse_task_registry(
                getattr(rec.origin_prompt_id, "tasks_json", "") or "")
            lines = vertex.draft_shape_warnings(
                tasks, rec.structure_json or [], rec.response or "",
                (rec.media_brief or "").strip())
            rec.shape_warnings = "\n".join(lines)
            rec.has_shape_warnings = bool(lines)

    @api.depends("structure_json")
    def _compute_item_count(self):
        for rec in self:
            rec.item_count = len(rec._items())

    @api.depends("structure_json", "response")
    def _compute_usable_count(self):
        """How many items the generator can actually reproduce as a shape.

        COUNTS AUTHORED ITEMS, not publish-validated ones. An earlier version
        called `to_question_specs()`, which borrows Form Studio's PUBLISH
        validator - and publishing requires an answer key per item. A reusable
        template deliberately has none (the key belongs to each generated
        instance), so that version reported four of six live templates as
        broken when the only thing "wrong" with them was being templates.

        What genuinely CANNOT be generated from is an item with no usable
        shape at all: a choice question with fewer than two options, or an
        item with no title. Those are counted out; a missing answer key is
        not, because supplying it is generation's job.
        """
        for rec in self:
            usable = 0
            for item in rec._items():
                title = str(item.get("title") or "").strip()
                if not title:
                    continue
                kind = str(item.get("kind") or "")
                options = rec._option_labels(item)
                if options and len(options) < 2:
                    # Half-drawn pickable item: one choice is not a question.
                    continue
                if kind in ("multipleChoice", "dropdown", "checkboxes") \
                        and len(options) < 2:
                    continue
                usable += 1
            rec.usable_count = usable

    @api.constrains("structure_json")
    def _check_structure(self):
        """A structure must be a list of sections, as the designer writes it.

        An EMPTY structure is valid: a template is saved part-way through
        authoring, and refusing that would make the designer unable to save a new
        template before its first question exists. Note Odoo's Json field hands
        back `False` (not `[]`) for an empty value, so this tests falsiness
        rather than comparing against a list of empty literals.
        """
        for rec in self:
            struct = rec.structure_json
            if not struct:
                continue
            if not isinstance(struct, list):
                raise ValidationError(_(
                    "A task template's structure must be a list of sections."))

    @api.constrains("response")
    def _check_response_maps_to_a_type(self):
        """A primitive with no question type would author unservable items."""
        for rec in self:
            if rec.response and rec.response not in TASK_PRIMITIVE_TO_QUESTION_TYPE:
                raise ValidationError(_(
                    "The response primitive %(p)s has no question type.",
                    p=rec.response))

    def _items(self):
        """Every item across every section, in designer order."""
        self.ensure_one()
        out = []
        for section in (self.structure_json or []):
            if not isinstance(section, dict):
                continue
            for item in (section.get("items") or []):
                if isinstance(item, dict):
                    out.append(item)
        return out

    def to_question_specs(self):
        """This template's items as question specs, via the Form Studio mapping.

        Borrowing `_item_spec` is the point: the designer, its answer-key
        validation and its option handling are already correct and already
        tested, so a template cannot drift from what the designer produces.

        Returns (specs, problems, warnings). Problems mean the template cannot
        be generated from as-is; the caller surfaces them rather than silently
        authoring a broken shape.
        """
        self.ensure_one()
        Form = self.env["etp.studio.form"]
        specs, problems, warnings = [], [], []
        for section in (self.structure_json or []):
            if not isinstance(section, dict):
                continue
            # `_walk_section` carries informational blocks onto the next real
            # question and handles nested items, exactly as a publish does.
            carry = {"text": [], "images": [], "videos": []}
            Form._walk_section(section, specs, problems, warnings, carry)
        return specs, problems, warnings

    @staticmethod
    def _option_labels(item):
        """The option labels an authored item offers, in order. [] when none.

        An item is choice-shaped because it CARRIES CHOICES, not because its
        kind is on a list. Form Studio writes options the same way for every
        pickable kind, so reading them is enough for multipleChoice, dropdown,
        checkboxes, linearScale and rating alike - and for whatever Form Studio
        adds next, with no edit here.
        """
        out = []
        for opt in (item.get("options") or []):
            if isinstance(opt, dict):
                label = str(opt.get("label") or "").strip()
            else:
                label = str(opt or "").strip()
            if label:
                out.append(label)
        if out:
            return out

        # A scale, a rating and a grid are choice-shaped too - they just carry
        # their choices in a different field. Form Studio writes a scale as
        # scale_min/scale_max, a rating as rating_max and a grid's shared
        # choices as `columns` (form_models.dart toJson). Reading only
        # `options` dropped all four to zero axes, so the kinds vanished from
        # the contract even though the designer drew them.
        cols = []
        for col in (item.get("columns") or []):
            if isinstance(col, dict):
                label = str(col.get("label") or "").strip()
            else:
                label = str(col or "").strip()
            if label:
                cols.append(label)
        if cols:
            return cols

        lo = item.get("scale_min")
        hi = item.get("scale_max")
        if hi is None and item.get("rating_max") is not None:
            lo, hi = 1, item.get("rating_max")
        if hi is None:
            return out
        try:
            lo = int(1 if lo is None else lo)
            hi = int(hi)
        except (TypeError, ValueError):
            return out
        if hi > lo and (hi - lo) <= 20:
            return [str(n) for n in range(lo, hi + 1)]
        return out

    @staticmethod
    def _authored_key(item, options, row=None):
        """The option labels the EXAMINER marked correct on this item. [] if none.

        WHY THIS EXISTS. A template's axes reached the generator as a shape with
        no key, on the reasoning that "the key belongs to each generated
        instance" - true when the model invents the stimulus AND the answer, and
        false for the axes an examiner keyed by hand. Six authored Yes/No checks
        with Yes marked correct produced bank rows whose axes had ZERO keyed
        options: measured on assessment 140, a candidate answered all six
        correctly and was scored 1/3 (33%, fail), because an axis with no keyed
        option is not a component and never entered the denominator.

        Returns LABELS, not indices, for the same reason
        `_reconcile_axes_with_options` does: a label survives a re-ordering and
        an index does not.

        THE FOUR CARRIERS Form Studio writes a key into (form_models.dart
        `toJson`), all read here so no keyed kind is silently skipped:
          * `options[].correct`  - choice kinds (one or many marked)
          * `grid_key`           - grid rows, row index -> correct column
                                   label(s). A LIST for a checkbox grid, whose
                                   row is an MSQ; a bare string for a radio grid
                                   and for anything authored before checkbox
                                   grids went multi-select.
          * `scale_golden`       - a linearScale's correct point
          * `rating_golden`      - a rating's correct star count
        A scale/rating key is stored as a NUMBER and its axis options are the
        stringified points (see `_option_labels`), so it is matched as text
        against those labels - never used as a position.
        """
        labels = [str(o) for o in (options or [])]

        # A grid: the key is per ROW, so a row that was not keyed contributes
        # nothing even when its siblings were.
        #
        # EVERY keyed column, not the first. This read `str(want or "").strip()`
        # and returned a one-element list, which for a checkbox grid's list-form
        # key stringified the list itself ("['A', 'B']"), matched no label, and
        # left the row silently keyless. Same defect class as
        # `generated_question_mapper._fillGrid`: this editor and the designer
        # host the same sheet, so a key shape one understands and the other does
        # not is lost on the next save.
        if row is not None:
            raw = item.get("grid_key")
            if not isinstance(raw, dict):
                return []
            want = raw.get(str(row))
            if want is None:
                want = raw.get(row)
            wanted = want if isinstance(want, (list, tuple, set)) else [want]
            wanted = {str(w).strip() for w in wanted if str(w or "").strip()}
            return [lbl for lbl in labels if lbl in wanted]

        out = [
            str(opt.get("label") or "").strip()
            for opt in (item.get("options") or [])
            if isinstance(opt, dict) and opt.get("correct") is True
            and str(opt.get("label") or "").strip()
        ]
        if out:
            return [x for x in out if x in labels]

        # A scale point / star count, matched against the option labels it was
        # expanded into rather than indexed into them.
        #
        # `golden_answer` IS THE THIRD PLACE TO LOOK, and it is not optional.
        # `studio_form._item_spec` reads every kind's key from `golden_answer`,
        # so the client publishes a scale/rating key BOTH as the typed field and
        # as that digit string - and a form written before the typed pickers
        # existed, or one round-tripped through the server, carries it ONLY
        # there. Reading just the typed fields would silently drop the key for
        # those forms, which is the same defect this method exists to fix.
        for field in ("scale_golden", "rating_golden", "golden_answer"):
            val = item.get(field)
            if val is None or isinstance(val, bool):
                continue
            text = str(val).strip()
            if text in labels:
                return [text]
        return []

    @staticmethod
    def _row_labels(item):
        """A grid item's row labels. [] when the item is not a grid.

        A grid asks the SAME options of SEVERAL rows, so each row is its own
        axis - that is what the examiner drew and what a grader must mark.
        """
        out = []
        for row in (item.get("rows") or []):
            if isinstance(row, dict):
                label = str(row.get("label") or "").strip()
            else:
                label = str(row or "").strip()
            if label:
                out.append(label)
        return out

    def _axes(self):
        """The choice-shaped items, as {label, options, kind, correct}.

        [] when there are none.

        Only choice-shaped items are axes; a free-text item is part of the
        RESPONSE (the justification a candidate writes), not a dimension to
        rate. The authored item TITLE is the axis name and its option labels
        are the axis options - that is what the examiner wrote, and what the
        SOP calls them, so it is what the generator must be told.

        SHAPE DECIDES, NOT KIND. This tested `kind in (multipleChoice, dropdown,
        checkboxes)`, so a linearScale, rating or grid drawn in Form Studio
        reached the generator as ZERO axes and vanished - Q7R's 1-5 rating
        among them. Anything carrying two or more options is an axis, and a
        grid contributes one axis PER ROW.

        THE EXAMINER'S KEY TRAVELS WITH THE SHAPE. `correct` carries whatever
        options were marked correct in the designer (see `_authored_key`), and
        is `[]` for an axis nobody keyed - which is the ordinary case for a
        reusable template and stays the model's to answer. Carrying it is what
        makes an authored axis scoreable; without it the axis reached the bank
        with no keyed option, so it was not a component and its marks did not
        exist.
        """
        self.ensure_one()
        axes = []
        for item in self._items():
            options = self._option_labels(item)
            if len(options) < 2:
                continue
            title = str(item.get("title") or "").strip()
            kind = str(item.get("kind") or "").strip()
            # An image/video block's "Allow several answers" is a checkboxes
            # axis: it takes several correct options, and the exam draws ticks.
            if kind in FORM_KINDS_MEDIA_BLOCK and item.get("multi_select"):
                kind = "checkboxes"
            rows = self._row_labels(item)
            if rows:
                for i, row in enumerate(rows):
                    label = "%s - %s" % (title, row) if title else row
                    axes.append({
                        "label": label, "options": options, "kind": kind,
                        "correct": self._authored_key(item, options, row=i),
                    })
            elif title:
                axes.append({
                    "label": title, "options": options, "kind": kind,
                    "correct": self._authored_key(item, options),
                })
        return axes

    @staticmethod
    def _lines(text):
        """Non-blank lines of a textarea, trimmed. [] when empty."""
        return [ln.strip() for ln in (text or "").splitlines() if ln.strip()]

    def answer_contract(self):
        """This template as an answer contract, in the SOP-registry vocabulary.

        A template and an extracted SOP task are then the SAME kind of thing to
        the generator, which is what keeps the quota mechanism single-pathed.

        READS THE AUTHORED STRUCTURE, NOT `to_question_specs()`. That method
        borrows Form Studio's PUBLISH validator, which is the wrong instrument
        here: publishing REQUIRES an answer key per item, and a reusable
        template deliberately has none (the key belongs to each GENERATED
        instance). Using it discarded every axis as a "problem", so the T2I
        template handed the model a contract with ZERO dimensions and the model
        wrote a generic "compare both images on all dimensions" item.

        PER-PRIMITIVE, NOT ONE A/B SHAPE. Axes+options is exactly what an A/B
        item needs and almost nothing of what the others need, so every other
        primitive's answer key used to be invented by the model with no examiner
        input - not provable by construction, and nothing for a quality pass to
        tune. Each branch below contributes the key data ITS question type's
        validator actually demands (see services/vertex.py
        `_validate_question_item`).
        """
        self.ensure_one()
        contract = {"response": self.response}
        axes = self._axes()
        if axes:
            contract["dimensions"] = [dict(a, evidence="") for a in axes]
            # PER-AXIS OPTIONS, KEYED BY AXIS NAME. `validate_flaw_plan` makes an
            # Overall Choice mandatory for a plain A/B, and exempts a plan that
            # supplies `dimension_options` (an independent-evaluation task - a
            # fixed set of questions about ONE artifact, e.g. three Yes/No
            # checks - has no single overall pick). That exemption could only
            # ever be triggered by SOP prose: a hand-authored template emitted
            # `dimensions` alone, so an examiner whose task had no overall-
            # preference axis had their OWN axes rejected for a missing OC.
            # Emitting the map here is what lets a template state a non-A/B
            # shape and be believed.
            contract["dimension_options"] = {
                a["label"]: a["options"] for a in axes}
        if self.instructions:
            contract["solution_shape"] = self.instructions.strip()

        # A written answer is graded against a rubric. Without the examiner's
        # own criteria the model invents them per item, so two items of the
        # "same" task are marked to different standards.
        criteria = self._lines(self.rubric_criteria)
        pass_condition = (self.rubric_pass_condition or "").strip()
        constraints = (self.rubric_constraints or "").strip()
        if criteria or pass_condition or constraints:
            rubric = {}
            if criteria:
                rubric["checklist"] = criteria
            if pass_condition:
                rubric["pass_condition"] = pass_condition
            if constraints:
                rubric["constraints"] = constraints
            contract["rubric"] = rubric

        # What the candidate must mark, so coverage/precision are graded
        # against the examiner's list rather than one the model made up.
        targets = self._lines(self.annotation_targets)
        if targets:
            contract["annotation_targets"] = targets
            contract["annotation_expected_count"] = (
                self.annotation_expected_count or len(targets))
        elif self.annotation_expected_count:
            contract["annotation_expected_count"] = self.annotation_expected_count

        # Anchors the stimulus so every generated item is a variation on the
        # same task rather than a different one.
        if (self.media_brief or "").strip():
            contract["media_brief"] = self.media_brief.strip()
        return contract

    def as_task(self):
        """The template shaped like a task-registry entry, for the generator."""
        self.ensure_one()
        return {
            "key": "template:%d" % self.id,
            "display": self.name or "Untitled task",
            "one_sentence": (self.instructions or "").strip()[:200],
            "subject_inputs": "",
            "worker_output": "",
            "answer_contract": self.answer_contract(),
            "evidence": "",
        }

    def shape_summary(self):
        """One line naming what this template actually asks, for a picker list
        where the SAVED NAME is not enough to tell templates apart.

        The recurring case: drafting a template from an image_ab SOP always
        proposes the name "Compare AI-Generated Images" (it is what the model
        calls that shape), so an operator with three drafts from three SOPs saw
        three identical rows and could tell them apart only by question count.
        This reads the same axis data `answer_contract()` already computes and
        states it as prose: the judged question's own wording, its option count,
        and how many more follow - the thing that is actually different between
        two "Compare AI-Generated Images" templates.

        PREFERS A KEYED QUESTION over document order. Most A/B templates end
        with a free-text justification item, and in several live templates that
        paragraph sorts FIRST - so reading `specs[0]` blindly summarised two
        different templates as "Justification" and "Provide a to-the-point
        justification for your choices.", which says nothing about what either
        one judges. The question carrying dimensions IS the distinguishing
        one; the justification is boilerplate every such template shares.
        """
        self.ensure_one()
        contract = self.answer_contract()
        dims = contract.get("dimensions") or []
        items = self._items()
        if not items:
            return "No questions yet"
        if not dims:
            first = str(items[0].get("title") or "").strip()
            return first[:57] + "..." if len(first) > 60 else (
                first or "No questions yet")
        title = dims[0]["label"]
        bits = [title if len(title) <= 60 else title[:57] + "..."]
        bits.append("%d options" % len(dims[0]["options"]))
        extra = len(items) - 1
        if extra > 0:
            bits.append("+%d more question%s" % (extra, "" if extra == 1 else "s"))
        return " · ".join(bits)
