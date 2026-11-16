import json

from odoo import models, fields, api, _

from odoo.exceptions import UserError

from ..constants import (
    QUESTION_TYPE_SELECTION, DIFFICULTY_SELECTION, IMAGE_QUESTION_TYPES,
    VIDEO_QUESTION_TYPES, DETECTION_MODE_SELECTION,
    SUBJECTIVE_COMPONENT_TYPES, LABELLING_COMPONENT_TYPES,
    TRANSCRIPTION_LANGUAGES, option_name_reveals_reasoning, text_has_source_reference,
)


class EtpAssessmentQuestion(models.Model):
    _name = "assessments.be.question"
    _description = "Assessment Question"
    _order = "sequence, id"

    section_title = fields.Char(
        string="Section",
        help="The Form Studio section this question was authored under. Shown "
             "to the candidate above the first question of each section, so a "
             "paper the examiner grouped deliberately reads as grouped. Empty "
             "for questions that did not come from a form, which render with "
             "no section heading at all rather than an invented one.")
    name = fields.Char(string="Title", required=True)
    sequence = fields.Integer(default=10)
    question_type = fields.Selection(
        QUESTION_TYPE_SELECTION,
        string="Question Type",
        required=True,
        default="mcq",
    )
    prompt = fields.Text(string="Prompt", required=True)
    description = fields.Text()
    # Not part of the key: it tells the exam which script the candidate types
    # (Devanagari with Hindi typing, or small English letters), so it is sent
    # to the candidate as a plain field.
    transcription_language = fields.Selection(
        TRANSCRIPTION_LANGUAGES, string="Transcription Language",
        help="Transcription questions only: the language the clip is "
             "transcribed in.")
    active = fields.Boolean(default=True)
    generator_id = fields.Many2one(
        "assessments.be.prompt", string="Generator",
        ondelete="set null", index=True,
    )
    # WHY THE BANK NEEDS THIS TOO, and not only the draft.
    #
    # `assessments.be.prompt.question` has carried `source_template_id` since
    # templates shipped, and every admin surface reading a DRAFT shows the
    # examiner's own task name because of it ("Verify a single photo edit"
    # rather than "Image A/B"). `action_approve` copied seventeen fields onto
    # the bank row and not this one, so the link died at the bank boundary: the
    # same question that read as its real task in the review queue reverted to
    # the rendering engine's name - "Labelling", "Image A/B" - the moment it was
    # approved, in the Question Bank, the assessment picker, Responses and every
    # attempt view.
    #
    # That is not only a label. A template is the unit an examiner authors,
    # reuses and fixes, so with no link back there is no way to ask which bank
    # questions a template produced - a template that quietly stopped working
    # looked identical to one that was never used.
    #
    # Nullable and set-null on delete, for the same reason the draft's copy is:
    # a question outlives the template it came from, and neither blocking the
    # delete nor cascading the question away is acceptable.
    source_template_id = fields.Many2one(
        "assessments.be.task.template", string="From task template",
        ondelete="set null", index=True, readonly=True, copy=False,
        help="The task template this question was authored from, carried over "
             "from the draft on approval.")
    # OUT OF THE BANK, BUT NOT OUT OF HISTORY.
    #
    # NOT `active`, and that distinction is the whole design. Odoo filters
    # archived records out of RELATIONAL READS, so archiving a question empties
    # it from `assessment.question_ids` - the paper that was built with it
    # quietly becomes a paper with one fewer question, which is the same damage
    # as deleting it and is precisely what retiring exists to avoid. (Proved by
    # `test_a_question_on_an_assessment_is_retired_not_erased`, which fails on
    # an `active`-based implementation.)
    #
    # So the record stays ACTIVE and carries this flag instead. The assessments
    # that use it still list it, the answers still attach to it, and scoring is
    # untouched; it is the BANK - the list, the search, and the question picker
    # a new assessment draws from - that filters it out. That is exactly "the
    # user will not be able to use those questions for further use" without
    # rewriting anything already recorded.
    retired = fields.Boolean(
        string="Retired From Bank", default=False, index=True,
        help="Taken out of the question bank. It cannot be found or chosen "
             "for a new assessment, but every assessment already using it "
             "keeps it, along with the answers candidates gave.",
    )
    # DELETED, NOT ERASED. Delete cannot unlink a question with history (see
    # `assessment_ids` below), so it used to land among the archived ones,
    # where Restore could bring it back. `deleted` sets it apart for good:
    # always written with `retired`, so every servability filter already skips
    # it; never restorable; its own list in the app. Papers, answers and scores
    # still point at the row, untouched.
    deleted = fields.Boolean(
        string="Deleted", default=False, index=True, copy=False,
        help="Deleted from the bank for good. Assessments already using it "
             "keep it, with every answer and score; it cannot be restored.",
    )

    @api.constrains("retired", "deleted")
    def _check_deleted_stays_retired(self):
        """Every bank, picker and launch filter reads `retired` alone, so a
        deleted question with `retired` cleared would be served again while
        the app lists it only under Deleted."""
        if self.filtered(lambda q: q.deleted and not q.retired):
            raise UserError(_("A deleted question cannot be put back in the "
                              "bank."))
    # THE INVERSE OF `assessments.be.question_ids`, over the same relation
    # table with the columns swapped. Odoo had no way back from a question to
    # the papers using it, so "what would deleting this break?" could only be
    # answered with a search per question - an N+1 the bank list would pay on
    # every row.
    #
    # Declaring the inverse does NOT create a table: `assessments_be_question_rel`
    # already exists, owned by upstream's `question_ids`. This side only names
    # the same relation with the columns swapped, so uninstalling drops the
    # field, never the relation upstream still uses.
    #
    # It is what the delete guard reads. A question any assessment points at is
    # HISTORY: `response.question_id` is ondelete="cascade", so unlinking such a
    # question destroys the answers to it and silently rewrites scores that were
    # already recorded, and the paper quietly loses a question. Those are
    # retired out of the bank instead of deleted.
    #
    # copy=False because m2m defaults to copy=True and Duplicate is available on
    # this model: without it, duplicating a bank question hands the copy every
    # assessment the original was used on, so a brand new draft question appears
    # on live papers it was never selected for - and the delete guard then reads
    # that borrowed history and refuses to delete it.
    assessment_ids = fields.Many2many(
        "assessments.be",
        "assessments_be_question_rel",
        "question_id",
        "assessment_id",
        string="Used In Assessments",
        copy=False,
    )

    # THE SKILL TAGS THIS QUESTION CARRIES.
    #
    # The vocabulary was extracted onto the GENERATOR and stopped there: a bank
    # of a hundred questions inherited nothing from the SOP that authored them,
    # so "which questions cover forklift pedestrian safety" had no answer that
    # did not start by asking which generator wrote them. The generator's own
    # `action_backfill_tags_to_questions` is what fills this in, and new
    # questions take a copy at approval time.
    #
    # A COPY, not a computed mirror of `generator_id.tag_ids`. A question is
    # approved once and then lives on its own: re-extracting a generator, or
    # deleting one (`generator_id` is `ondelete="set null"`), must not silently
    # re-tag or untag questions that are already in live assessments. It also
    # has to be editable by hand - a reviewer narrowing a question's coverage
    # is a real edit, and a computed field cannot hold it.
    tag_ids = fields.Many2many(
        "assessments.be.tag",
        "assessments_be_question_tag_rel",
        "question_id",
        "tag_id",
        string="Skill Tags",
        help="Canonical vocabulary this question covers. Inherited from the "
             "generator that authored it, and editable afterwards.",
    )

    question_dimension_ids = fields.One2many(
        "assessments.be.question.dimension",
        "question_id",
        string="Dimensions",
    )
    grading_json = fields.Text(string="Grading (raw)")
    subjective_rubric_json = fields.Text(string="Subjective Rubric (JSON)")
    meta_json = fields.Text(string="Meta (JSON)")
    covers_elements_json = fields.Text(
        string="Covers Elements (JSON)",
        help="Required-element ids this question exercises, carried from the "
             "draft on approve. Threaded to scoring so the judge grades SOP "
             "coverage against the project's real required_elements.")
    solution_json = fields.Text(
        string="Solution / Golden Answer (JSON)", copy=False,
        help="The golden answer (research solutions.answers), carried from the "
             "draft on approve. Fed to the subjective judge as the answer key "
             "it decomposes into golden claims before reading the worker.")
    solution_rationale = fields.Text(
        string="Solution Rationale", copy=False,
        help="How the golden answer is known (construction ground truth, the "
             "SOP's own rule, or derivation).")
    verification_json = fields.Text(
        string="Verification Record (JSON)", copy=False,
        help="image_ab construction verification carried from the draft on "
             "approve: which planted flaws were confirmed visible in the "
             "rendered assets. Fed to the judge in scoring Step 0 as the "
             "confirmed-flaw ground-truth record.")
    image_ids = fields.One2many(
        "assessments.be.question.image",
        "question_id",
        string="Images",
    )
    video_ids = fields.One2many(
        "assessments.be.question.video",
        "question_id",
        string="Videos",
    )
    upload_video = fields.Binary(
        string="Upload Clip", attachment=True,
        help="video_prompt: attach an mp4/webm, pick the slot, then use "
             "'Apply Uploaded Video' to store it as a question.video row.")
    upload_video_filename = fields.Char(string="Upload Clip Filename")
    upload_video_slot = fields.Selection(
        [("reference", "Reference"), ("output", "Output"), ("single", "Single")],
        string="Upload Slot", default="reference",
        help="Which clip the uploaded file becomes: Reference + Output for a "
             "video_prompt pair, Single for a lone clip.")
    official_reasoning = fields.Text(
        string="Official Reasoning",
        help="image_ab: the official rationale the LLM grades the candidate's "
             "justification against.")
    flaw_plan_json = fields.Text(
        string="Flaw Plan (JSON)",
        help="image_ab flaw-injection plan copied from the draft on approve: the "
             "worker/render prompts, planted flaws, and the construction_keys the "
             "answer key was derived from. NULL for pre-Phase-3 questions (guards "
             "no-op). The approve- and score-time key-drift guards hard-fail if "
             "the stored answer key ever diverges from these keys.")
    difficulty = fields.Selection(
        DIFFICULTY_SELECTION,
        string="Difficulty",
    )
    detection_mode = fields.Selection(
        DETECTION_MODE_SELECTION,
        string="Detection Mode",
        default="object",
        help="image_label: whether the source picture is a photo (detect "
             "objects) or a UI screenshot (detect clickable UI elements). "
             "Selects which detection prompt the annotation cron uses.")
    time_minutes = fields.Integer(string="Time (minutes)", default=0)
    has_subjective = fields.Boolean(
        compute="_compute_has_subjective", store=True
    )
    rubric_reviewed = fields.Boolean(
        string="Rubric Reviewed",
        default=False, copy=False,
        help="GOVERNANCE: tick when a human has reviewed this subjective "
             "question's grading rubric/answer key. The generator authors both "
             "the question AND its rubric, so an unreviewed rubric is a closed "
             "AI loop grading candidates. An assessment with 'Require Reviewed "
             "Rubric' on refuses to launch until every subjective question it "
             "serves is reviewed. Objective questions ignore this flag.")
    source_ref = fields.Char(string="Source Ref")

    answer_key_preview = fields.Html(
        string="Answer Key", compute="_compute_answer_key_preview",
        sanitize=False)
    has_answer_key = fields.Boolean(compute="_compute_answer_key_preview")
    has_valid_key = fields.Boolean(
        string="Answer Key OK", compute="_compute_has_valid_key", store=True,
        help="False when an objective (MCQ/MSQ) question has no correct option "
             "marked - it cannot be scored and needs a fix.")

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
    missing_media_warning = fields.Char(
        compute="_compute_missing_media_warning",
        help="Set when this image/video question is missing a picture or clip "
             "its type requires, so the exam guards will silently withhold it "
             "from every assessment. Surfaced in the form as a banner.")

    @api.depends("question_type", "image_ids.slot", "video_ids")
    def _compute_missing_media_warning(self):
        for rec in self:
            warning = False
            if not rec._has_required_images():
                slots = set(rec.image_ids.mapped("slot"))
                if rec.question_type == "image_ab":
                    missing = sorted({"a", "b"} - slots)
                    warning = (
                        "This A/B question is missing the %s image slot(s). "
                        % ", ".join(slot.upper() for slot in missing))
                else:
                    warning = "This image question has no image. "
            elif not rec._has_required_videos():
                warning = "This video question has no clip. "
            if warning:
                warning += ("It will be skipped by every assessment until you "
                            "add it.")
            rec.missing_media_warning = warning

    # `detections_json` is a dependency because `_label_box_count` now reads it -
    # it is the carrier the detect-after-render lane fills, and without it here
    # a question that gains its boxes from detection keeps a stale
    # `has_valid_key` until something else happens to touch the row.
    @api.depends("question_type",
                 "question_dimension_ids.option_line_ids.is_correct",
                 "image_ids.label_boxes_json", "image_ids.detections_json",
                 "subjective_rubric_json",
                 "solution_json")
    def _compute_has_valid_key(self):
        for rec in self:
            if rec.question_type in ("mcq", "msq"):
                has_correct = any(
                    qd.option_line_ids.filtered("is_correct")
                    for qd in rec.question_dimension_ids)
                rec.has_valid_key = bool(has_correct)
                continue
            if rec.question_type == "image_label":
                # A LABELLING QUESTION NEEDS SOMETHING TO LABEL.
                #
                # Every non-MCQ type used to be declared valid unconditionally,
                # so a labelling question that reached the bank with neither
                # numbered boxes nor an ideal-label key passed the servable
                # guard and could be attached to a live assessment: the
                # candidate sees a bare picture, and the grader has nothing to
                # mark against. Two such questions were sitting in the bank
                # (q290, q295) with has_valid_key=True.
                #
                # BOTH, NOT EITHER. This was `boxes OR key`, on the reasoning
                # that the defect lane stamps its markers at render time so the
                # key can legitimately arrive first. True of a DRAFT - and this
                # model is the BANK, where a row is approved and one attach away
                # from a candidate. Either half alone is a question nobody can
                # answer fairly:
                #
                #   * boxes, no key   -> the grader has nothing to mark against
                #   * key, no boxes   -> the candidate is shown a picture with no
                #                        numbers on it and asked to describe
                #                        boxes 1..N. Every one of those marks is
                #                        unearnable.
                #
                # The second was live: images 290, 295 and 306 carried keys
                # naming 1, 3 and 2 boxes with nothing drawn, and all three read
                # `has_valid_key=True`.
                #
                # QUARANTINE, NOT REJECTION, and that distinction is why this is
                # safe. A false value only clears `servable`, so the row cannot
                # be attached while it is broken; it is never deleted and never
                # edited. The detect cron still fills the boxes in after
                # approval, and because `image_ids.detections_json` is now a
                # dependency the flag flips back on its own the moment it does.
                rec.has_valid_key = bool(
                    rec._label_box_count() and rec._label_key_count())
                continue
            rec.has_valid_key = True

    def _label_box_count(self):
        """How many numbered boxes this labelling question can actually SERVE.

        COUNTS WHAT THE CANDIDATE ROUTE COUNTS, and that is the whole point of
        this method. It used to read `label_boxes_json` alone, which is only the
        FIRST of the two things serving looks at:
        `serializers.bank_label_boxes` prefers `label_boxes_json` and falls
        back to `detections_json` when the markers are baked into the picture
        and only their numbers are knowable. So an image whose boxes live only in
        `detections_json` - which is every image the detect-after-render lane
        produces - counted zero here and the question was quarantined despite
        being perfectly servable.

        The mirror error is worse and was live: image 305 carried 6 entries in
        `label_boxes_json` and 1 in `detections_json`, so this counted 6 while
        the candidate saw one marker.

        So: per image, take the count the serving path would arrive at. The two
        fields are `_LABEL_BOX_FIELDS` members and are documented there as
        "parallel views of one box set" kept in lockstep - when they disagree,
        the smaller one is what a candidate can actually see, and counting the
        larger one is how a question gets graded against boxes nobody was shown.
        """
        self.ensure_one()
        total = 0
        for image in self.image_ids:
            total += self._servable_box_count(image)
        return total

    @staticmethod
    def _servable_box_count(image):
        """The marker count `serializers.bank_label_boxes` would arrive at.

        MIRRORS THAT FUNCTION, IN ITS ORDER, and the mirroring is the point:
        anything else and the guard measures a different picture from the one the
        candidate is shown.

          1. a drawable `label_boxes_json` box needs a 4-element `box_2d`,
             because that is what the overlay renderer places. Present, it WINS -
             the boxes are drawn over the image and their count is what the
             candidate sees.
          2. otherwise the markers are baked into the picture and only their
             numbers are knowable, so the count comes from `detections_json`.

        Verified against the live rows this was written for: images 25/26/30/34
        carry an empty `label_boxes_json` beside 20, 20, 20 and 3 detections -
        the detect-after-render lane's normal output - and reading only the first
        field counted them all as zero and would have quarantined four sound
        questions. Image 29 is the mirror case, 6 drawable boxes beside 1
        detection: the overlay wins, so the candidate sees six and six is the
        honest count.
        """
        def _parsed(raw):
            raw = (raw or "").strip()
            if not raw:
                return None
            try:
                out = json.loads(raw)
            except (ValueError, TypeError):
                return None
            return out if isinstance(out, list) else None

        boxes = _parsed(image.label_boxes_json)
        if boxes:
            drawable = [b for b in boxes
                        if isinstance(b, dict)
                        and isinstance(b.get("box_2d"), list)
                        and len(b["box_2d"]) == 4]
            if drawable:
                return len(drawable)
        detections = _parsed(image.detections_json)
        if detections:
            # Counted by NUMBER, as serving does: a detection without one cannot
            # be pointed at, so it is not a marker a candidate can answer.
            numbers = {d["number"] for d in detections
                       if isinstance(d, dict)
                       and isinstance(d.get("number"), int)}
            if numbers:
                return len(numbers)
        # A `label_boxes_json` list whose entries carry no `box_2d` is still a
        # declared box set - the defect lane stamps geometry in later - so it
        # counts rather than reading as nothing at all.
        return len([b for b in (boxes or []) if isinstance(b, dict)])

    def _label_key_count(self):
        """How many ideal labels this labelling question's answer key names.

        Reads BOTH key carriers. `subjective_rubric_json` is the grader's key
        and `solution_json` the judge's golden answer; a labelling question can
        legitimately arrive with either, so requiring one field would flag a
        sound question as unscoreable.
        """
        self.ensure_one()
        for field_name in ("subjective_rubric_json", "solution_json"):
            raw = (getattr(self, field_name, "") or "").strip()
            if not raw:
                continue
            try:
                key = json.loads(raw)
            except (ValueError, TypeError):
                continue
            if not isinstance(key, dict):
                continue
            ideal = key.get("ideal_labels")
            if isinstance(ideal, dict):
                if ideal:
                    return len(ideal)
            elif isinstance(ideal, str):
                lines = [ln for ln in ideal.splitlines() if ln.strip()]
                if lines:
                    return len(lines)
            elif isinstance(ideal, list):
                if ideal:
                    return len(ideal)
        return 0

    @api.depends("question_type", "question_dimension_ids.option_line_ids.name")
    def _compute_has_revealing_option(self):
        for rec in self:
            flag = False
            if rec.question_type in ("mcq", "msq"):
                names = rec.question_dimension_ids.option_line_ids.mapped("name")
                flag = any(option_name_reveals_reasoning(n) for n in names)
            rec.has_revealing_option = flag

    @api.depends("prompt", "official_reasoning", "subjective_rubric_json",
                 "description", "question_dimension_ids.option_line_ids.name")
    def _compute_has_source_reference(self):
        for rec in self:
            opt_names = " ".join(
                rec.question_dimension_ids.option_line_ids.mapped("name"))
            rec.has_source_reference = text_has_source_reference(
                rec.prompt, rec.official_reasoning, rec.subjective_rubric_json,
                rec.description, opt_names)

    @api.depends("question_dimension_ids.option_line_ids.is_correct",
                 "question_dimension_ids.option_line_ids.name",
                 "question_dimension_ids.name",
                 "question_type", "image_ids.detections_json")
    def _compute_answer_key_preview(self):
        import html as _html
        for rec in self:
            blocks = []
            for qd in rec.question_dimension_ids.sorted("sequence"):
                chips = []
                for ol in qd.option_line_ids.sorted("sequence"):
                    is_c = ol.is_correct
                    cls = ("badge text-bg-success" if is_c
                           else "badge text-bg-light border")
                    mark = " \u2713" if is_c else ""
                    style = ("margin:3px;font-size:0.95rem;padding:0.45em 0.7em;"
                             "font-weight:%s") % ("600" if is_c else "400")
                    chips.append(
                        f'<span class="{cls}" style="{style}">'
                        f'{_html.escape(ol.name or "")}{mark}</span>')
                if not chips:
                    continue
                blocks.append(
                    '<div class="mb-2"><strong style="font-size:0.95rem">'
                    f'{_html.escape(qd.name or "")}</strong><br/>'
                    f'{"".join(chips)}</div>')
            # A labelling question's key is per-marker, not per-option: render it
            # as a readable numbered table instead of leaving the reviewer to
            # decode raw detections_json. This is the key a human must sign off
            # via `rubric_reviewed`, so it has to be legible.
            blocks.extend(rec._label_key_preview_blocks())
            rec.answer_key_preview = "".join(blocks) if blocks else False
            rec.has_answer_key = bool(blocks)

    def _label_key_preview_blocks(self):
        """HTML rows for the marker-keyed answer key of a labelling question."""
        self.ensure_one()
        import html as _html
        if self.question_type != "image_label":
            return []
        entries = []
        for img in self.image_ids:
            if img.slot != "single":
                continue
            try:
                data = json.loads(img.detections_json or "[]")
            except (TypeError, ValueError):
                continue
            if isinstance(data, list) and data:
                entries = data
                break
        if not entries:
            return []
        rows = []
        for det in entries:
            if not isinstance(det, dict):
                continue
            num = _html.escape(str(det.get("number", "")))
            label = _html.escape(str(det.get("label") or "").strip())
            rows.append(
                '<tr>'
                '<td style="padding:4px 10px 4px 0;vertical-align:top;'
                'white-space:nowrap"><span class="badge text-bg-danger">'
                f'{num}</span></td>'
                f'<td style="padding:4px 0;vertical-align:top">{label}</td>'
                '</tr>')
        if not rows:
            return []
        return [
            '<div class="mb-2"><strong style="font-size:0.95rem">'
            f'Expected answer per marker ({len(rows)})</strong>'
            '<table style="width:100%;margin-top:6px;font-size:0.92rem">'
            f'{"".join(rows)}</table></div>']

    @api.depends("subjective_rubric_json", "question_type")
    def _compute_has_subjective(self):
        for rec in self:
            text = (rec.subjective_rubric_json or "").strip()
            rec.has_subjective = bool(text and text not in ("[]", "{}")) or \
                rec.question_type == "subjective_rubric"

    def init(self):
        # Queued, not run here: `post_init` fires once every table of this
        # module is updated, and the repair also reads drafts and templates.
        self.pool.post_init(self._repair_generated_text)

    def _repair_generated_text(self):
        from ..services import vertex
        return vertex.repair_generated_question_text(self.env)

    def unlink(self):
        # Guard mid-flight deletion: at launch action_start writes the resolved
        # question set onto the assessment's question_ids M2M, and each candidate
        # holds a frozen question_order referencing these ids. Deleting a question
        # an in-progress assessment is still serving strands the candidate (a
        # denominator that counts an item they can never answer) and inflates the
        # score max. Refuse it; the admin should cancel/finish the assessment or
        # RETIRE the question instead - `action_retire_from_bank` below.
        #
        # Retire, NOT `active = False`, and the message below says "Archive"
        # because that is what the product calls retiring. This comment used to
        # name `active` and was wrong in the one place it mattered: archiving
        # empties the question out of `assessment.question_ids` (a plain m2m,
        # no `active_test` override), so the paper this guard exists to protect
        # loses a question anyway - the exact damage, by the other door.
        Assessment = self.env["assessments.be"].sudo()
        blocking = Assessment.with_context(active_test=False).search([
            ("state", "=", "in_progress"),
            ("question_ids", "in", self.ids),
        ])
        if blocking:
            used = blocking.mapped("question_ids").filtered(
                lambda q: q.id in self.ids)
            raise UserError(_(
                "Cannot delete %(n)s question(s) - live in assessment "
                "%(who)s. Archive instead.",
                n=len(used), who=", ".join(blocking.mapped("name")[:3])))
        return super().unlink()

    def action_retire_from_bank(self):
        """Take these questions out of the bank. The form's Archive button.

        THE SAFE HALF OF A PAIR THAT LOOKS INTERCHANGEABLE AND IS NOT. Odoo's
        own Archive writes `active = False`, which drops the question out of
        every `assessment.question_ids` that holds it - a plain m2m with no
        `active_test` override - so a paper already sat quietly becomes a paper
        with one fewer question. This writes `retired` instead: the record
        stays active, every assessment keeps listing it, every answer stays
        attached and scoring is untouched. It is the BANK - the list, the
        search and the picker a new assessment draws from - that filters it
        out. See the field's own rationale above.

        Same write as the API's /api/v1/bank/archive, so both surfaces put a
        question out of circulation by exactly one mechanism.
        """
        self.write({"retired": True})

    def action_restore_to_bank(self):
        """Put these questions back in the bank. The form's Restore button.

        The way back from `action_retire_from_bank`, and the reason retiring is
        safe to offer at all. Mirrors /api/v1/bank/<id>/restore, and like it
        refuses a deleted question: Delete is the one that does not come back.
        """
        if self.filtered("deleted"):
            raise UserError(_("A deleted question cannot be restored. Its "
                              "assessments, answers and scores are kept."))
        self.write({"retired": False})

    # ------------------------------------------------------------------
    # Form Studio, backwards: a question -> a designer item.
    #
    # `studio_form._item_spec` translates a designer item into a question, and
    # for `imageAnnotation` it emits geometry as `box_2d` on Gemini's 0-1000
    # grid, y-first (studio_form.py:701). That direction has always existed.
    # THE INVERSE DID NOT, and its absence is the whole of tracker SNo 168: the
    # annotation editor is built, wired and works - verified live on a real
    # plate, 8 boxes with a golden-answer panel - but a GENERATED draft could
    # not be opened in it, because nothing turned a question back into an item.
    # An examiner reviewing a generated labelling question could read the key
    # and not adjust a box.
    # ------------------------------------------------------------------

    def as_studio_annotation_item(self):
        """This labelling question as a Form Studio `imageAnnotation` item.

        Returns the item dict the designer's editor consumes, or None when this
        question is not a labelling question with a usable stimulus. The shape
        MUST match what `_item_spec` reads back, or a round trip would lose the
        boxes it just drew - `regions`, `golden_labels`, `annotation_count`,
        `media_url`, and the `title`/`help` pair.

        GEOMETRY IS THE EXACT INVERSE of the forward transform:

            forward:  box_2d = [y*1000, x*1000, (y+h)*1000, (x+w)*1000]
            here:     y = y0/1000, x = x0/1000, h = (y1-y0)/1000,
                      w = (x1-x0)/1000

        so a box drawn in the editor, published, and re-opened lands on the
        same pixels. `test_a_studio_round_trip_keeps_the_boxes` pins that by
        composing the two directions.

        WHERE THE BOXES COME FROM, and why order matters. `label_boxes_json` is
        the authored geometry and is preferred - but a question PUBLISHED FROM
        THE STUDIO carries none: measured on etp_local, question 9602 has
        `label_boxes_json` NULL and three `detections_json` entries each
        carrying `box_2d`. Reading only `label_boxes_json` would therefore fail
        on exactly the questions this feature exists for. `detections_json` is
        the fallback, and entries there without `box_2d` (the DOM-capture lane
        stores `box_px`, which is PIXELS and not comparable) contribute their
        NUMBER only - the editor can still label a marker it cannot redraw,
        which is the same reduction `serializers.bank_label_boxes` makes and
        for the same reason.
        """
        self.ensure_one()
        if self.question_type != "image_label":
            return None
        image = self.image_ids.filtered(lambda i: i.slot == "single")[:1]
        if not image:
            return None

        def _parsed(raw):
            try:
                out = json.loads(raw or "[]")
            except (TypeError, ValueError):
                return []
            return out if isinstance(out, list) else []

        # The labels an examiner typed, keyed by marker number. `solution_json`
        # is the same map the judge grades against; `{"ideal_labels": {...}}`
        # and a bare `{"1": "..."}` are both shapes in the wild, so both are
        # read rather than assuming the newer one.
        try:
            solution = json.loads(self.solution_json or "{}")
        except (TypeError, ValueError):
            solution = {}
        if not isinstance(solution, dict):
            solution = {}
        ideal = solution.get("ideal_labels")
        labels = {str(k): str(v) for k, v in
                  (ideal if isinstance(ideal, dict) else solution).items()
                  if isinstance(v, str)}

        regions = []
        seen = set()
        for source in (_parsed(image.label_boxes_json),
                       _parsed(image.detections_json)):
            for entry in source:
                if not isinstance(entry, dict):
                    continue
                number = entry.get("number")
                if not isinstance(number, int) or number <= 0:
                    continue
                if number in seen:
                    continue
                # A label on the box itself is the older shape and is still
                # authoritative when the solution map has nothing for it.
                if isinstance(entry.get("label"), str) and \
                        not labels.get(str(number)):
                    labels[str(number)] = entry["label"]
                box = entry.get("box_2d")
                if not (isinstance(box, list) and len(box) == 4):
                    # Marker with no drawable geometry: still a point to label.
                    seen.add(number)
                    continue
                try:
                    y0, x0, y1, x1 = (float(v) for v in box)
                except (TypeError, ValueError):
                    seen.add(number)
                    continue
                regions.append({
                    "n": number,
                    "y": y0 / 1000.0,
                    "x": x0 / 1000.0,
                    "h": max(0.0, (y1 - y0) / 1000.0),
                    "w": max(0.0, (x1 - x0) / 1000.0),
                })
                seen.add(number)
            if seen:
                # The first source that yielded anything wins outright. Merging
                # the two would put an authored box and a detected box for the
                # same marker on the plate twice.
                break

        if not seen:
            return None
        return {
            "kind": "imageAnnotation",
            "title": self.name or "",
            "help": self.prompt or "",
            "media_url": image.image_admin_url or image.image_url or "",
            "regions": sorted(regions, key=lambda r: r["n"]),
            # DERIVED FROM THE MARKERS, never carried across. A stale count is
            # exactly the mismatch seen live in the editor: `annotation_count`
            # 3 beside 8 regions, reading "3 / 8 keyed". Publish already
            # derives from `regions` (studio_form.py:641), so deriving here too
            # means the two can never disagree.
            "annotation_count": len(seen),
            "golden_labels": {k: v for k, v in labels.items()
                              if k.isdigit() and int(k) in seen},
            "required": True,
        }

    def studio_annotation_editor_payload(self):
        """Everything the Odoo annotation editor needs to OPEN this question.

        THE READ HALF OF THE ODOO WIDGET, and it WRAPS
        `as_studio_annotation_item` rather than re-deriving anything. The
        geometry transform lives in exactly one place, so the OWL editor and
        /api/v1/bank/<id>/studio_item cannot drift into disagreeing about where
        a box is - which would look like "the operator moved it" rather than the
        two readers it actually was.

        WHY IT EXISTS AT ALL, given that method already returns the item.
        `as_studio_annotation_item` answers one question - "is there anything to
        edit?" - and returns None for THREE different reasons an operator has to
        be told apart: this is not a labelling question, there is no image
        uploaded yet, and there is an image with no markers on it yet. The API
        route may collapse all three into a single 404 because its caller only
        decides whether to offer a button. A FIELD WIDGET IS ALREADY ON SCREEN
        and must say which one it is - and in the third case must still OPEN,
        because a plate with no boxes is precisely the plate an examiner needs to
        draw the first box on. Returning None there would leave the only
        graphical editor in Odoo unreachable for every question whose detection
        has not run (or has run and found nothing), i.e. the ones most in need of
        a hand-drawn key.

        ONE FLAT `markers` LIST, NOT `regions` + `golden_labels`.
        `as_studio_annotation_item` deliberately reports markers the client
        cannot draw - the DOM-capture lane stores `box_px`, which is PIXELS on
        the original bitmap and paints a degenerate box in the corner of a
        normalised overlay - inside `annotation_count` and `golden_labels` but
        NOT inside `regions`. Re-uniting those two halves in JavaScript would
        duplicate the union `apply_studio_annotation_item` computes on the way
        back in, and a second copy of that rule is a second chance to delete a
        marker on a no-op save (the failure that method's own comment records).
        So the union is computed HERE, once, and each entry says whether it is
        `drawable`; the widget renders what it is given and invents nothing.

        `unkeyed_markers` IS REPORTED, NOT SILENTLY SWALLOWED. A stored key can
        carry a marker with neither geometry nor a golden answer (malformed
        `box_2d`, a detection lane that wrote a number and nothing else). Such a
        marker has no representation in the item shape at all, so a save WILL
        drop it - and dropping a mark off a paper without saying so is the exact
        class of damage `apply_studio_annotation_item` refuses partial writes to
        avoid. The count travels to the widget so it can warn before the
        operator presses Save, and the raw JSON stays on the form to fix it in.

        Never raises. This feeds a form view: an exception here would replace
        the whole question form with an error dialog, on a screen whose other
        tabs are the operator's only way to repair the very data that broke it.
        """
        self.ensure_one()
        payload = {
            "ok": False,
            "reason": "",
            "question_id": self.id,
            "media_url": "",
            "markers": [],
            "annotation_count": 0,
            "unkeyed_markers": 0,
            "marker_cap": 0,
        }
        if self.question_type != "image_label":
            payload["reason"] = "not_labelling"
            return payload
        image = self.image_ids.filtered(lambda i: i.slot == "single")[:1]
        if not image:
            payload["reason"] = "no_image"
            return payload
        # `image_admin_url` is the ACL-checked /assessments_be/admin_qimage
        # proxy and is the ONLY one of the two an `<img>` in the back office can
        # rely on: a question whose bitmap has been offloaded has an `image_url`
        # pointing into private S3, which answers 403 to a browser. The raw URL
        # stays as the fallback for a row that carries a public URL and no
        # stored bytes, where the proxy computes to False.
        media = image.image_admin_url or image.image_url or ""
        if not media:
            payload["reason"] = "no_media"
            return payload
        payload.update({
            "ok": True,
            "media_url": media,
            "marker_cap": image._label_box_cap(),
        })

        item = self.as_studio_annotation_item()
        if not item:
            # An image with no key yet. OPEN AND EMPTY, deliberately - see the
            # docstring: this is the draw-the-first-box case, not a refusal.
            payload["reason"] = "no_markers"
            return payload

        payload["media_url"] = item["media_url"] or media
        by_number = {r["n"]: r for r in item["regions"]}
        labels = item["golden_labels"]
        # DRAWN **OR** KEYED, the same union `apply_studio_annotation_item`
        # applies on the way back. Deriving from `regions` alone would hide
        # every pixel-only marker from the operator and then delete it on save.
        numbers = sorted(
            set(by_number)
            | {int(k) for k in labels if str(k).strip().isdigit()})
        if not numbers:
            # Count-only shape: the numerals are baked into the picture and
            # there are no coordinates at all. 1..N is the only reading
            # available, and it is the same one `apply` falls back to.
            numbers = list(range(1, item["annotation_count"] + 1))
        for n in numbers:
            region = by_number.get(n)
            marker = {
                "n": n,
                "label": labels.get(str(n), ""),
                "drawable": region is not None,
            }
            if region is not None:
                marker.update({"x": region["x"], "y": region["y"],
                               "w": region["w"], "h": region["h"]})
            payload["markers"].append(marker)
        payload["annotation_count"] = item["annotation_count"]
        payload["unkeyed_markers"] = max(
            0, item["annotation_count"] - len(payload["markers"]))
        return payload

    def _stored_marker_count(self):
        """How many markers this question ACTUALLY carries today.

        The widest of the three stored views, because they are allowed to
        disagree while a question is being corrected and the safe reading is
        the largest: under-counting here would let a save delete the markers
        the count missed, which is the whole failure this guards.
        """
        self.ensure_one()
        image = self.image_ids.filtered(lambda i: i.slot == "single")[:1]
        if not image:
            return 0

        def _len(raw):
            try:
                parsed = json.loads(raw or "[]")
            except (TypeError, ValueError):
                return 0
            return len(parsed) if isinstance(parsed, (list, dict)) else 0

        try:
            rubric = json.loads(self.subjective_rubric_json or "{}") or {}
            keyed = rubric.get("ideal_labels")
            keyed = len(keyed) if isinstance(keyed, (list, dict)) else 0
        except (TypeError, ValueError):
            keyed = 0
        return max(_len(image.label_boxes_json), _len(image.detections_json),
                   keyed)

    def apply_studio_annotation_item(self, item):
        """Write an edited `imageAnnotation` item back onto THIS question.

        EDIT IN PLACE, no second record. The examiner opened a question in the
        annotation editor; saving publishes a new Studio form and a new
        assessment would leave the paper they are fixing untouched and the
        corrected copy attached to nothing anybody sits. So the geometry and
        the key land on the same question rows, and every assessment already
        holding this question is corrected by the one save.

        SAME SHAPE `_item_spec` PRODUCES, deliberately. The three stored views
        of one box set have to agree or a candidate is graded against boxes
        they were never shown, so all three are written from the same
        `numbers`:

            detections_json      what the overlay is drawn from, {number,
                                 label, box_2d}
            subjective_rubric_json  the grader's key, {"ideal_labels": {...}}
            solution_json        the judge's golden answer, the same map

        THE ANNOTATED PLATE IS RE-DRAWN, not left alone. The candidate is shown
        the burned-in overlay (`answer_layouts.dart` prefers `annotated_url`
        whenever the question has boxes), so a moved box that only updated
        `detections_json` would put the numbered badge in the OLD place on the
        picture and the new place in the key - the exact "labels at the wrong
        positions" failure, reintroduced from the authoring side. Drawn from
        the stored geometry with `imaging.annotate_image`, which costs no
        Vertex call.

        Returns a list of refusals, empty when the save went through. A
        refusal, never a silent partial write: half-applying an answer key is
        how a 5-point question ends up scored out of 2.
        """
        self.ensure_one()
        if self.question_type != "image_label":
            return ["Only a labelling question can be edited in the "
                    "annotation editor."]
        image = self.image_ids.filtered(lambda i: i.slot == "single")[:1]
        if not image:
            return ["This question has no image to mark up."]
        if not isinstance(item, dict):
            return ["The edited item was not readable."]

        regions = [r for r in (item.get("regions") or [])
                   if isinstance(r, dict)]
        drawn_numbers = sorted({int(r.get("n") or 0) for r in regions
                                if str(r.get("n") or "").strip().isdigit()
                                and int(r.get("n") or 0) > 0})

        # A MARKER EXISTS IF IT IS DRAWN **OR** KEYED - not only if it is drawn.
        #
        # `as_studio_annotation_item` deliberately reports markers the client
        # cannot draw: the DOM-capture lane stores `box_px` (PIXELS, not the
        # 0-1000 grid), so those entries come back inside `annotation_count` and
        # `golden_labels` but NOT inside `regions` - the same reduction
        # `serializers.bank_label_boxes` makes, because a client handed pixel
        # coordinates paints degenerate boxes in the corner of the image.
        #
        # Deriving the marker set from `regions` alone therefore DELETED those
        # markers on any save, including one where the examiner changed nothing.
        # Measured before this fix: a question with marker 1 drawable and marker
        # 2 pixel-only opened as `annotation_count` 2 with both labels keyed, and
        # a no-op save left it at 1 - a mark silently removed from the paper,
        # with its golden answer, by pressing Save.
        #
        # So the keyed numbers count too, and `annotation_count` still supplies
        # the count-only shape (markers baked into the picture, no coordinates at
        # all) - which is what the editor sends when `regions` is empty.
        keyed_numbers = sorted({
            int(k) for k in (item.get("golden_labels") or {})
            if str(k).strip().isdigit() and int(k) > 0
        })
        try:
            count = int(item.get("annotation_count") or 0)
        except (TypeError, ValueError):
            count = 0
        numbers = sorted(set(drawn_numbers) | set(keyed_numbers))
        if not numbers:
            numbers = list(range(1, count + 1))

        # A SAVE MAY NOT SHRINK THE PAPER BEHIND THE EXAMINER'S BACK.
        #
        # The clause above rescues a marker the CLIENT could not draw but could
        # still key. It cannot rescue one the client never received at all, and
        # that case is real: `as_studio_annotation_item` hands back only the
        # markers it can express, so a question whose geometry lives in
        # `box_px` and whose key the editor cannot map arrives with a fraction
        # of its markers. Sending that back is a faithful save of what was
        # shown and a silent deletion of everything that was not.
        #
        # Measured on question 1417 of a production-shaped database: 46 markers
        # and 349 keyed labels went in, the editor was handed 9, and a save it
        # reported no problem with left 9 markers and 9 labels. Thirty-seven
        # marks vanished off a paper candidates had already sat, and the
        # refusal list came back empty.
        #
        # So the reduction itself is the thing to refuse. `allow_marker_drop`
        # is the explicit escape hatch - a caller that genuinely means to
        # shorten the paper says so - and its absence is what makes the
        # DEFAULT safe. The editor never sends it, which is why the editor can
        # no longer do this by accident.
        # ONLY WHEN SOMETHING WAS HIDDEN FROM THE EDITOR, not on every
        # reduction. Deleting a marker is an ORDINARY edit - the operator drew
        # a box they no longer want - and refusing that would break the editor
        # to protect it. The dangerous reduction is the one where the markers
        # that vanish are the ones the editor was never shown, so the operator
        # could not have meant to delete them and cannot see that they went.
        #
        # `unopenable` is exactly that difference: the markers the question
        # holds minus the markers `studio_annotation_editor_payload` was able
        # to express. Zero of them means the editor saw the whole paper and
        # every change in front of it was deliberate.
        existing = self._stored_marker_count()
        openable = len(
            (self.studio_annotation_editor_payload() or {}).get("markers") or [])
        unopenable = max(0, existing - openable)
        if unopenable and len(numbers) < existing and not item.get(
                "allow_marker_drop"):
            return [
                "This would cut the paper from %d marker(s) to %d, and %d of "
                "them could not be opened in the editor - their coordinates "
                "are stored as pixels, which it cannot draw. Saving would "
                "delete those markers and their answer key without you ever "
                "having seen them. Re-run Detect Now to give every marker "
                "drawable coordinates, or correct the stored answer key "
                "directly." % (existing, len(numbers), unopenable)
            ]
        # THE CEILING IS APPLIED HERE TOO. `question_image.write` caps the
        # stored lists, but the key is built from `numbers` - so without the
        # same cut the rubric would name 30 labels beside 10 drawn boxes, the
        # mismatch `_cap_label_box_fields` exists to prevent.
        limit = image._label_box_cap()
        if len(numbers) > limit:
            numbers = numbers[:limit]
        if not numbers:
            return ["Draw at least one marker, or set how many annotations "
                    "the picture already carries."]

        labels = {str(k): str(v).strip()
                  for k, v in (item.get("golden_labels") or {}).items()
                  if isinstance(v, str)}
        missing = [str(n) for n in numbers if not labels.get(str(n))]
        if missing:
            # The same refusal `_item_spec` makes, and for the same reason: an
            # unkeyed point is a mark no candidate can earn, because the judge
            # has nothing to compare their description against.
            return ["Every point needs a golden answer - what a correct "
                    "description of it says. Missing: %s."
                    % ", ".join(missing)]

        by_number = {int(r["n"]): r for r in regions
                     if str(r.get("n") or "").strip().isdigit()
                     and int(r["n"]) > 0}
        detections = []
        for n in numbers:
            det = {"number": n, "label": labels.get(str(n), "")}
            r = by_number.get(n)
            if r is not None:
                try:
                    y, x = float(r["y"]), float(r["x"])
                    h, w = float(r["h"]), float(r["w"])
                    # box_2d is Gemini's 0-1000 space, y-first - the exact
                    # inverse of `as_studio_annotation_item`.
                    det["box_2d"] = [round(y * 1000), round(x * 1000),
                                     round((y + h) * 1000),
                                     round((x + w) * 1000)]
                except (KeyError, TypeError, ValueError):
                    pass
            detections.append(det)

        ideal = {str(n): labels.get(str(n), "") for n in numbers}
        title = str(item.get("title") or "").strip()
        help_text = str(item.get("help") or "").strip()

        # EDIT THE LABELS, KEEP THE REST OF THE KEY.
        #
        # `subjective_rubric_json` is a rubric OBJECT, not just the label map:
        # alongside `ideal_labels` a generated question can carry `decoys`,
        # `mandatory_elements`, `penalty_rules` and `scoring_guide`, and the
        # grader reads them (`scoring._image_label_key`). Measured on etp_walk2,
        # question 306 carries a real `decoys` list. Writing a bare
        # `{"ideal_labels": ...}` here would silently delete every sibling key,
        # so moving one box would quietly relax the whole rubric.
        #
        # Only the label map is replaced; anything else the key held survives.
        try:
            existing_rubric = json.loads(self.subjective_rubric_json or "{}")
        except (TypeError, ValueError):
            existing_rubric = {}
        if not isinstance(existing_rubric, dict):
            existing_rubric = {}
        rubric = dict(existing_rubric)
        rubric["ideal_labels"] = ideal

        question_vals = {
            "subjective_rubric_json": json.dumps(rubric, ensure_ascii=False),
            "solution_json": json.dumps(ideal, ensure_ascii=False),
        }
        # `detection_mode` IS NOT TOUCHED, and that is a correctness point, not
        # tidiness. It says whether the picture is a photo of defects or a UI
        # screenshot, and `media_stream.annotated_is_worker_safe` reads it to
        # decide whether the CANDIDATE may see the numbered overlay at all:
        # 'ui'/'dense' means the boxes sit on controls and reveal nothing, while
        # the default 'object' means the markers are drawn ON the defects and so
        # ARE the answer key (Finding L-2).
        #
        # An earlier version of this method wrote "object" unconditionally,
        # copying `_item_spec`, where it is correct because that lane is
        # CREATING a defect question. Here it would flip an existing UI question
        # to defect mode, and the exam would then stop serving its overlay - the
        # candidate would get an unmarked screenshot above numbered inputs
        # referring to regions they cannot see. Editing where a box sits must
        # never change what KIND of question it is.
        if title:
            question_vals["name"] = title[:200]
        if help_text:
            question_vals["prompt"] = help_text
        self.write(question_vals)

        image_vals = {"detections_json": json.dumps(detections,
                                                    ensure_ascii=False)}
        # `label_boxes_json` is the AUTHORED geometry and is what
        # `as_studio_annotation_item` reads FIRST, so an examiner who moves a box
        # has to see it there on re-open.
        #
        # IT IS ALWAYS WRITTEN, INCLUDING EMPTY. The first version only wrote it
        # when there was drawable geometry, which left a real trap: an examiner
        # who deletes every box and switches the question to the count-only shape
        # (markers baked into the picture, no coordinates) would leave the OLD
        # boxes sitting in `label_boxes_json` - and because the read prefers that
        # field, re-opening the editor would serve back the very boxes they just
        # removed, while the exam drew the new marker set. Clearing it makes the
        # stored geometry mean exactly what the examiner last saved.
        # THE WHOLE MARKER LIST, not just the drawable subset.
        #
        # `as_studio_annotation_item` prefers this field and STOPS as soon as it
        # yields anything, so a subset here is not a partial answer - it is the
        # whole answer, and every marker missing from it disappears on re-open.
        # Storing only the entries carrying `box_2d` therefore lost the
        # pixel-only markers (the DOM-capture lane's `box_px`) on the way back:
        # measured, a question with marker 1 drawable and marker 2 pixel-only
        # round-tripped from 2 markers to 1, even though the WRITE had stored
        # both correctly. The subset was the bug, one layer further on than it
        # looked.
        #
        # Parallel to `detections_json` by construction now, which is the
        # invariant the module already states for these fields: they are
        # "parallel views of ONE numbered list". Readers that want geometry
        # filter for `box_2d` themselves (`_dense_detections`,
        # `bank_label_boxes`), so a geometry-less entry costs them nothing, and
        # `_cap_label_box_fields` cuts both lists to the same length because they
        # are now the same length.
        image_vals["label_boxes_json"] = (
            json.dumps(detections, ensure_ascii=False) if detections else False)

        # THE BEHAVIOURAL KEY IS PER MARKER, so it cannot outlive a marker set.
        #
        # `behavioural_key_json` is the DOM lane's `[{number, element,
        # functionality}]` grading what each numbered box DOES, and
        # `scoring._image_label_behavioural_key` feeds it to the judge per
        # marker. Leaving it untouched after the markers changed grades a
        # candidate's answer for marker 4 against whatever marker 4 used to be -
        # or against a marker that no longer exists at all.
        #
        # Entries whose number survived are kept (their element is still that
        # element); entries for deleted markers are dropped. Trimming rather than
        # clearing, because re-deriving the behavioural key needs a DOM capture
        # this lane does not have, and discarding a still-valid entry would quietly
        # remove marks the candidate could earn.
        try:
            behavioural = json.loads(image.behavioural_key_json or "[]")
        except (TypeError, ValueError):
            behavioural = []
        if isinstance(behavioural, list) and behavioural:
            kept = [b for b in behavioural
                    if isinstance(b, dict) and b.get("number") in set(numbers)]
            if len(kept) != len(behavioural):
                image_vals["behavioural_key_json"] = (
                    json.dumps(kept, ensure_ascii=False) if kept else False)
        image.write(image_vals)
        image._redraw_label_overlay()
        return []

    def _keyed_dimension_count(self):
        """How many of this question's sub-questions are actually markable.

        A dimension with no correct option is KEYLESS: nothing can be right, so
        it is not a component and must count in neither the numerator nor the
        denominator. Counting it would silently mark every candidate wrong on a
        sub-question the author never finished, which reads as a candidate
        failure rather than the authoring fault it is.
        """
        self.ensure_one()
        return sum(
            1 for qd in self.question_dimension_ids
            if qd.option_line_ids.filtered("is_correct"))

    def _keyless_reason(self):
        """Why this question would score 0 for every candidate, or "".

        THE ONE VERDICT BOTH LAUNCH GATES ASK. `assessments.be.action_start` and
        the launch dry run behind /api/v1/assessments/<id>/launch_check each
        carried their own copy of this rule, and a test exists precisely because
        they had already drifted once (the mirror exempted a dimensionless
        objective question that `action_start` refused, so the operator saw the
        gate PASS and then hit a UserError the route does not render as a gate
        failure). Two copies cannot agree by inspection; one method can only be
        wrong in one place.

        TYPE-AGNOSTIC ON THE DIMENSION HALF, and that is the fix. Both copies
        asked `question_type not in ("mcq", "msq", "image_ab")` first and
        returned "not keyless" for everything else - so a question of any OTHER
        type whose axes were all unkeyed sailed through. That is not a
        hypothetical: 9 live bank rows carry axes with zero keyed options, all
        generated from a task template, and on assessment 140 a candidate
        answering six such axes correctly was scored 1/3 (33%, fail) because an
        unkeyed axis is not a component (`_keyed_dimension_count`) and never
        enters the denominator. A dimension is markable or it is not; what type
        it hangs off does not change that.

        THE TEST IS THE DENOMINATOR ITSELF, not a rule written alongside it.
        "Scores 0 for every candidate" means "is worth 0 marks", and
        `_component_counts` is the arithmetic the paper's denominator is already
        built from - so asking IT is the only way this gate cannot disagree with
        what the paper actually counts. An earlier version of this method
        reasoned separately ("has dimensions, none keyed -> keyless") and
        over-reached on 9 live bank rows: unkeyed axes on a `subjective_rubric`
        or `image_label` whose LLM-graded component is still worth 1 mark, so
        the question DOES score and refusing to launch would have cost the
        examiner usable papers.

        WHAT IS *NOT* FLAGGED, deliberately:
          * A subjective/labelling question with no per-option key -
            `subjective_rubric`, `image_prompt`, `video_prompt`, `image_label`
            are LLM-graded and earn their mark from their type.
          * A PARTIALLY keyed axis set. The keyed axes do score, so refusing to
            launch would be a tightening with a real cost. It stays visible as
            the "only X of Y" count in the draft/bank UI.

        An unkeyed axis beside a component that DOES score is still a real
        authoring fault - those marks silently do not exist - but it is a
        warning, not a reason to refuse a paper that grades.
        """
        self.ensure_one()
        marks, _raw = self._component_counts()
        if marks:
            return ""
        dims = self.question_dimension_ids
        if dims:
            return ("its %d sub-question(s) have no correct option marked"
                    % len(dims))
        return "there is nothing on it to answer"

    def _component_counts(self):
        """(marks, raw_marks) - what this question is worth, and how much of
        that carries a raw score.

        THE UNIT OF SCORING IS THE COMPONENT, NOT THE QUESTION. Every keyed
        sub-question is its own 1 mark, the LLM-graded free-text answer is its
        own 1 mark, and a labelling box set is one further mark (its boxes are
        normalised to 0-1 inside that single mark, never spread across the
        paper). So a 3-sub-question MCQ is worth 3, and an image_ab with four
        verdict axes plus a justification is worth 5.

        EVERY COMPONENT NOW CARRIES A RAW, so the two numbers are equal by
        construction. They used to differ: the objective half was excluded from
        the raw score's numerator AND denominator, on the argument that an
        objective raw only restates the mark beside it. True, but it made the
        headline unreadable - a 5-question paper with three MCQs reported
        "Raw score 1.40 / 2", a fraction of a paper nobody sat, next to a mark
        out of 5. A keyed dimension's raw is simply its mark, so the raw now
        spans the whole paper and can be read against the marks it sits beside.

        THE PAIR IS KEPT rather than collapsed to one number: `raw_marks` is
        what `raw_max` and the raw denominator mean, and callers unpack two
        values. Should a component type ever be introduced that genuinely has no
        raw, this is the one line that has to change.

        THIS LIVES ON THE QUESTION, NOT THE ANSWER, AND THAT IS THE POINT. The
        denominator is the paper's length, so it has to be computable for a
        question the candidate never opened - there may be no response row at
        all. Deriving it from the answer would shrink the paper to whatever was
        attempted and hand an abandoned question a free pass.
        """
        self.ensure_one()
        qtype = self.question_type or ""
        # image_ab IS THE ONE TYPE WHOSE SUBJECTIVE HALF IS OPTIONAL, so its
        # mark is conditional where every other type's is not.
        #
        # Its justification is graded against `official_reasoning`, and Form
        # Studio may now publish a comparison without one - the verdict is the
        # whole question there. With no standard there is nothing to grade, so
        # the MARK must not exist either: charging it would fail every
        # candidate on a component no judge can score, and the question would
        # report 1 of 2 with the missing half unearnable.
        #
        # This does NOT weaken the paper-length denominator. The rule stays
        # keyed on authoring, never on `needs_llm` or on what the candidate
        # did: a comparison WITH a standard costs its justification mark
        # whether or not the box was filled, exactly as before. Every other
        # subjective type keys grading on a rubric that is mandatory at
        # authoring time, so they stay unconditional.
        subjective = qtype in SUBJECTIVE_COMPONENT_TYPES and (
            qtype != "image_ab" or bool(self.official_reasoning))
        graded_marks = int(subjective) + int(
            qtype in LABELLING_COMPONENT_TYPES)
        marks = self._keyed_dimension_count() + graded_marks
        return marks, marks

    @staticmethod
    def _image_row_has_a_source(image):
        """True when this image row can actually be rendered.

        A ROW IS NOT A PICTURE. `assessments.be.question.image` carries an
        `image` binary and an `image_url`, and both are optional - a render that
        failed, a URL an examiner cleared, a row an import created and never
        attached anything to. So the row exists while there is nothing to draw.

        `annotated_image*` counts on its own: a UI-mode labelling question
        SERVES the overlay (see `media_stream.annotated_is_worker_safe`), so a
        row carrying only the overlay is renderable and refusing it would drop
        a question that works.

        `.strip()` because a cleared Char field commonly lands as spaces rather
        than NULL, and " " is not a URL.
        """
        return bool(
            image.image
            or (image.image_url or "").strip()
            or image.annotated_image
            or (image.annotated_image_url or "").strip())

    def _has_required_images(self):
        """False when this is an image question missing the picture(s) its type
        requires. The exam-selection/serving guards drop such questions so a
        candidate is never shown an image question with no image.

        ASKS FOR A SOURCE, NOT A ROW. This used to be `bool(self.image_ids)`,
        which an empty row satisfies - so an `image_prompt` whose render failed
        was drawn into a paper and the candidate was asked to write the prompt
        that would produce a picture they could not see, marked out of the same
        total as everybody else. Six callers share this guard and it is the only
        thing between such a question and a live exam: the launch draw
        (`assessment.py:764`), the launch gate and late-add pool
        (`api/admin.py:198,683,700,1036`) and the examiner's warning
        (`missing_media_warning`, `:250-266`).

        `image_ab` needed the same tightening for the same reason. It already
        required slots `a` and `b`, but only that they were NAMED - so two empty
        rows passed and the candidate was asked to choose between two blanks.
        Now each of the two slots must hold a row with a source.
        """
        self.ensure_one()
        if self.question_type not in IMAGE_QUESTION_TYPES:
            return True
        usable = self.image_ids.filtered(self._image_row_has_a_source)
        if self.question_type == "image_ab":
            return {"a", "b"}.issubset(set(usable.mapped("slot")))
        return bool(usable)

    def _has_required_videos(self):
        """False when a video question has no clip (the video twin of
        _has_required_images). The exam-selection guard drops such questions so
        a candidate is never shown a video question with no clip.

        SAME HOLE, SAME FIX. This was `bool(self.video_ids)`, so a clip row with
        neither `video_url` nor `video` bytes passed - the shape a failed Veo
        render leaves behind. `video_url` is what production stores and the
        Binary is a supported dev fallback, so either counts.
        """
        self.ensure_one()
        # A transcription question IS its clip: with none there is nothing to
        # type out.
        if (self.question_type not in VIDEO_QUESTION_TYPES
                and self.question_type != "transcription"):
            return True
        return bool(self.video_ids.filtered(
            lambda v: v.video or (v.video_url or "").strip()))

    def _unservable_reason(self):
        """Why the launch draw drops this question, in two or three words, or
        "" when it does not. The draw's own tests, in the draw's order."""
        self.ensure_one()
        if not self.active:
            return "archived"
        if self.retired:
            return "retired"
        if not self._has_required_images():
            return "no image"
        if not self._has_required_videos():
            return "no video"
        return ""

    def action_apply_uploaded_video(self):
        """Store the uploaded clip as a question.video row for upload_video_slot,
        replacing any existing clip in that slot. Mirrors the draft image
        uploader (action_apply_uploaded_image): the binary is ingested to S3 when
        configured (video_url), else kept on the record as a dev-only fallback."""
        self.ensure_one()
        if not self.upload_video:
            return self._bank_notify(
                "No File", "Attach a clip in 'Upload Clip' first.", "warning")
        from ..services import image_ingest
        slot = (self.upload_video_slot or "reference").strip().lower()
        raw_b64 = self.upload_video
        if isinstance(raw_b64, bytes):
            raw_b64 = raw_b64.decode("ascii", errors="ignore")
        filename = self.upload_video_filename or ""
        content_type = "video/webm" if filename.lower().endswith(".webm") \
            else "video/mp4"
        url, stored_b64 = image_ingest.ingest(
            self.env, None, raw_b64, content_type=content_type,
            key_hint="qvideo-%s-%s" % (self.id, slot))
        existing = self.video_ids.filtered(lambda v: v.slot == slot)
        existing.unlink()
        Video = self.env["assessments.be.question.video"]
        Video.create({
            "question_id": self.id,
            "slot": slot,
            "label": slot.title(),
            "video_url": url or False,
            "video": stored_b64 or False,
            "video_filename": filename or False,
            "sequence": {"reference": 10, "output": 20}.get(slot, 30),
        })
        self.write({"upload_video": False, "upload_video_filename": False})
        return self._bank_notify(
            "Video Uploaded", "Your clip now fills the %r slot." % slot)

    def action_offload_images_s3(self):
        from ..services import s3_service
        moved = 0
        for q in self:
            for img in q.image_ids:
                if img.image_url or not img.image:
                    continue
                url, _key = s3_service.upload_b64(
                    self.env, img.image,
                    key_hint="qimg-%s" % img.id, content_type="image/png")
                img.write({"image_url": url})
                moved += 1
        return {
            "type": "ir.actions.client",
            "tag": "display_notification",
            "params": {
                "title": "Images Offloaded",
                "message": "Pushed %s image(s) to S3." % moved,
                "type": "success" if moved else "warning",
                "sticky": False,
            },
        }

    def _image_brief_json(self):
        """Best-effort source of render briefs for a bank question: the
        originating draft's image_brief_json (kept after approval), else False."""
        self.ensure_one()
        Draft = self.env["assessments.be.prompt.question"]
        draft = Draft.search(
            [("approved_question_id", "=", self.id)], limit=1)
        if draft and draft.image_brief_json:
            return draft.image_brief_json
        return False

    def _bank_notify(self, title, message, kind="success"):
        return {
            "type": "ir.actions.client",
            "tag": "display_notification",
            "params": {"title": title, "message": message, "type": kind,
                       "sticky": kind in ("danger", "warning")},
        }

    def action_upload_question_image(self):
        """No-op placeholder: upload happens on the question.image row's Binary
        field in the form, not through a wizard. Kept for symmetry/help text."""
        return self._bank_notify(
            "Upload Image",
            "Edit an image row below and use its Image field to upload your "
            "own picture, or add a new image line.", "info")

    def action_detect_now(self):
        """Run image_label detection immediately on the Single source image
        (respecting detection_mode) instead of waiting for the 1-min cron.
        Delegates to the image row, which reuses the cron's attempt cap and
        surfaces Vertex failures as a friendly UserError."""
        self.ensure_one()
        if self.question_type != "image_label":
            raise UserError(
                "Detect Now is only available for Image - Annotation questions.")
        images = self.image_ids.filtered(
            lambda im: im.slot == "single" and (im.image or im.image_url))
        if not images:
            raise UserError(
                "Add a source image to the Single slot before detecting.")
        for img in images:
            img.action_detect_now()
        return self._bank_notify(
            "Detection Complete",
            "Detected elements and drew the numbered overlay.")

    def _export_payload(self):
        import json
        out = []
        for q in self:
            options = []
            correct_idx = []
            for qd in q.question_dimension_ids:
                for i, ol in enumerate(qd.option_line_ids.sorted("sequence")):
                    options.append(ol.name)
                    if ol.is_correct:
                        correct_idx.append(i)
            rubric = None
            if q.subjective_rubric_json:
                try:
                    rubric = json.loads(q.subjective_rubric_json)
                except (ValueError, TypeError):
                    rubric = q.subjective_rubric_json
            out.append({
                "id": q.id,
                "name": q.name,
                "generator": q.generator_id.name or "",
                "question_type": q.question_type,
                "difficulty": q.difficulty or "",
                "time_minutes": q.time_minutes,
                "prompt": q.prompt or "",
                "description": q.description or "",
                "options": options,
                "correct_answer": correct_idx[0] if len(correct_idx) == 1 else correct_idx,
                "rubric": rubric,
                "source_ref": q.source_ref or "",
            })
        return out

    def _export_native(self):
        """Lossless, round-trippable export: every field needed to rebuild the
        EXACT question (answer key with is_correct, official_reasoning, rubric,
        images) so ``import_bank_native`` reproduces it identically. Distinct from
        _export_payload, which is the lossy human/CSV view."""
        out = []
        # Deleted questions stay deleted: a round-trip import creates live rows.
        for q in self.filtered(lambda r: not r.deleted):
            dims = [{
                "name": qd.name or "",
                # The control the exam draws; the native import restores it.
                "input_kind": qd.input_kind or "",
                "options": [
                    {"name": ol.name or "", "is_correct": bool(ol.is_correct)}
                    for ol in qd.option_line_ids.sorted("sequence")],
            } for qd in q.question_dimension_ids.sorted("sequence")]
            images = [{
                "slot": im.slot or "single",
                "label": im.label or "",
                "image_url": im.image_url or "",
                "image_b64": im.image.decode() if im.image else "",
            } for im in q.image_ids.sorted("sequence")]
            out.append({
                "name": q.name or "",
                "prompt": q.prompt or "",
                "description": q.description or "",
                "question_type": q.question_type or "mcq",
                "difficulty": q.difficulty or "",
                "time_minutes": q.time_minutes or 0,
                "sequence": q.sequence or 10,
                "source_ref": q.source_ref or "",
                "official_reasoning": q.official_reasoning or "",
                "subjective_rubric_json": q.subjective_rubric_json or "",
                "grading_json": q.grading_json or "",
                "meta_json": q.meta_json or "",
                "generator": q.generator_id.name or "",
                "dimensions": dims,
                "images": images,
            })
        return out

    def action_export_native_json(self):
        """One-click LOSSLESS export for round-trip import (rebuilds identically)."""
        import json
        recs = self or self.search([])
        payload = json.dumps(
            {"assessments_be_bank": "1", "questions": recs._export_native()},
            indent=2, ensure_ascii=False)
        return recs._export_download_action(
            "question_bank_native.json", "application/json",
            payload.encode("utf-8"))

    def _export_download_action(self, filename, mimetype, content_bytes):
        att = self.env["ir.attachment"].create({
            "name": filename,
            "type": "binary",
            "datas": __import__("base64").b64encode(content_bytes).decode(),
            "mimetype": mimetype,
            "res_model": self._name,
        })
        return {
            "type": "ir.actions.act_url",
            "url": f"/web/content/{att.id}?download=true",
            "target": "self",
        }

    def action_export_json(self):
        import json
        recs = self or self.search([])
        payload = json.dumps(recs._export_payload(), indent=2, ensure_ascii=False)
        return recs._export_download_action(
            "question_bank.json", "application/json", payload.encode("utf-8"))

    def action_export_csv(self):
        import csv, io
        # Neutralize CSV formula injection: question name/prompt/options are
        # LLM-authored (a prompt-injected SOP could plant `=HYPERLINK(...)`),
        # and this bank CSV is opened by admins in Excel/Numbers. Prefix any
        # cell that starts with a formula lead char so it renders as text.
        _lead = ("=", "+", "-", "@", "\t", "\r")

        def _safe(v):
            if v is None:
                return ""
            if isinstance(v, (int, float)):
                return v
            s = str(v)
            return "'" + s if s and s[0] in _lead else s

        recs = self or self.search([])
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow(["id","name","generator","question_type","difficulty",
                    "time_minutes","prompt","description","options",
                    "correct_answer","rubric_pass_condition","source_ref"])
        for row in recs._export_payload():
            rubric = row["rubric"]
            pass_cond = ""
            if isinstance(rubric, list) and rubric:
                pass_cond = (rubric[0] or {}).get("pass_condition", "") if isinstance(rubric[0], dict) else ""
            elif isinstance(rubric, dict):
                pass_cond = rubric.get("pass_condition", "")
            w.writerow([_safe(row["id"]), _safe(row["name"]), _safe(row["generator"]),
                        _safe(row["question_type"]),
                        _safe(row["difficulty"]), _safe(row["time_minutes"]), _safe(row["prompt"]),
                        _safe(row["description"]), _safe(" | ".join(row["options"])),
                        _safe(row["correct_answer"]), _safe(pass_cond), _safe(row["source_ref"])])
        return recs._export_download_action(
            "question_bank.csv", "text/csv", buf.getvalue().encode("utf-8"))


class QuestionCacheTouch(models.AbstractModel):
    """A change to a question's dimension, option, image or video bumps the
    QUESTION's `write_date`.

    The question cache (services/question_cache.py) is keyed on that stamp,
    so an edited option or a re-detected label box must make a new key rather
    than serve the old content. Odoo stamps only the child row by itself.
    """
    _name = "assessments.be.question.cache.touch"
    _description = "Question child: bumps its question's version"

    #: How a child row reaches its question.
    _question_path = "question_id"
    #: Bookkeeping a candidate never sees (a retry counter): a write of only
    #: these leaves the question's version, and its cache key, alone.
    _cache_quiet_fields = frozenset()

    def _questions(self):
        return self.sudo().mapped(self._question_path)

    @api.model_create_multi
    def create(self, vals_list):
        records = super().create(vals_list)
        records._questions().write({})
        return records

    def write(self, vals):
        if not set(vals) - self._cache_quiet_fields:
            return super().write(vals)
        # Before AND after, so a row moved to another question bumps both.
        before = self._questions()
        result = super().write(vals)
        (before | self._questions()).exists().write({})
        return result

    def unlink(self):
        questions = self._questions()
        result = super().unlink()
        questions.exists().write({})
        return result
