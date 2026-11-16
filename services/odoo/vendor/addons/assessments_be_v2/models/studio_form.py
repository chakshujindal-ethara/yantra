# -*- coding: utf-8 -*-
"""Form Studio's storage: one row per designed form.

Forms have no upstream (`etp_assessment_pro`) counterpart, so the storage
lives where the API lives.

WHY A DOCUMENT, NOT A SCHEMA: the designer edits a whole form at once and the
client already speaks one JSON shape for it (sections → items → options).
Only Publish reads inside a section, and it materialises bank questions from
the document (the same draft→materialise step the question bank uses), so
normalising it into four tables would buy nothing. The document is the single
source of truth and cannot drift from the designer.
Storing structured payloads as JSON text is established practice in the base
module (``question_order``, ``options_json``, ``dimensions_json``).
"""
import json
import logging
import re
from urllib.parse import urlparse

import requests

from odoo import api, fields, models
from odoo.exceptions import UserError, ValidationError

from ..constants import (
    AUDIO_MIME_BY_EXT, DEFAULT_IMAGE_LABEL_COUNT, FORM_ITEM_KINDS,
    FORM_KINDS_CHOICE, FORM_KINDS_GRID, FORM_KINDS_MEDIA_BLOCK,
    FORM_KINDS_SCALE, FORM_KINDS_WRITTEN, TRANSCRIPTION_RUBRIC,
    clean_clip_answers,
)
from ..services import net_guard

_logger = logging.getLogger(__name__)

# A form document is prose and option labels. Half a megabyte is an order of
# magnitude above any real form; past it, the payload is not a form.
MAX_STRUCTURE_BYTES = 512 * 1024

# Public video HOSTS, which serve a player page rather than bytes.
#
# Anchored on the whole host, like every other host test in this addon: a
# substring check for "youtube.com" also matches `youtube.com.evil.test`. These
# only classify a URL (video vs image), they authorise no fetch - but a
# misclassification here decides whether publish tries to download the URL at
# all, so the same discipline applies.
_EMBED_VIDEO_HOSTS = re.compile(
    r"^(?:www\.|m\.|player\.)?(?:youtube\.com|youtu\.be|vimeo\.com)$",
    re.I)


# Hosts that serve VIDEO BYTES for a share link the designer rewrote.
#
# `drive.usercontent.google.com` is where a Drive clip's bytes actually live -
# the designer turns a `/file/d/<id>/view` link into
# `.../download?id=<id>&export=view`, which answers `video/mp4` with
# `accept-ranges: bytes` so a `<video>` element can seek it.
#
# NOTE WHAT IS DELIBERATELY ABSENT: `lh3.googleusercontent.com`. That host
# answers `image/jpeg` for a video file too - a poster thumbnail - so it is an
# IMAGE host by content type whatever the underlying file is, and listing it
# here would file a still under `videos`. The designer picks the host per kind;
# this test only has to recognise the choice it made.
_VIDEO_CONTENT_HOSTS = re.compile(
    r"^drive\.usercontent\.google\.com$", re.I)


def _is_video_content_host(url):
    """True when [url] is a rewritten share link that serves video bytes.

    Anchored on the whole host, like every other host test here: a substring
    check for "drive.usercontent.google.com" also matches
    `drive.usercontent.google.com.evil.test`.
    """
    try:
        host = (urlparse((url or "").strip()).hostname or "").lower()
    except ValueError:
        return False
    return bool(host) and bool(_VIDEO_CONTENT_HOSTS.match(host))


def _is_embed_video_host(url):
    """True when [url] is a YouTube or Vimeo link.

    Mirrors `publicVideoEmbedRef` in `video_plate.dart`, which the client uses
    to decide the same thing. Deliberately looser than that function: it only
    asks whether the HOST is an embed host, not whether a video id can be
    parsed out, because a link this cannot parse is still not an image and must
    never be fetched as one.
    """
    try:
        host = (urlparse((url or "").strip()).hostname or "").lower()
    except ValueError:
        return False
    return bool(host) and bool(_EMBED_VIDEO_HOSTS.match(host))


class EtpStudioForm(models.Model):
    _name = "etp.studio.form"
    _description = "Form Studio form"
    _rec_name = "title"
    _order = "write_date desc, id desc"

    # The CLIENT's identifier, minted when the form is first created in the
    # designer and stable for the form's whole life. The API upserts on it,
    # which is what makes a save idempotent: replaying the same save (flaky
    # network, double tap) lands on the same row instead of minting twins.
    client_uid = fields.Char(required=True, index=True, copy=False)

    title = fields.Char(required=True, default="Untitled form")
    description = fields.Text(default="")

    # WHAT AN OPERATOR CALLS THIS FORM, when that differs from what a
    # respondent reads.
    #
    # `title` is the heading at the top of the form - candidate-facing copy,
    # written for the person answering ("Quality Assessment: IG Entity Image").
    # `internal_name` is the label the people RUNNING the assessment need in a
    # list of two hundred rows ("Q7r cohort 3 - retake"). The designer seeds it
    # from `title`, because the two are usually the same string; this field
    # exists for the times they must not be, and changing it must not touch the
    # heading a candidate sees.
    #
    # NULLABLE, AND THAT IS THE ENTIRE STATE. Empty already means "not
    # overridden", so there is no companion `internal_name_set` boolean and
    # there must not be one: a flag can disagree with the value it describes -
    # set with an empty name, or clear with a name in it - and then every
    # reader has to decide which of the two to believe. `display_title` below
    # is that decision, made once.
    internal_name = fields.Char(
        help="What operators call this form in lists. Publishing names the "
             "assessment and the question pool from it, so it is the string "
             "someone will search for afterwards. Leave it empty to use the "
             "title respondents read.")

    display_title = fields.Char(
        compute="_compute_display_title",
        help="The operator-facing name: the internal name when one was given, "
             "otherwise the respondent-facing title.")

    @api.depends("internal_name", "title")
    def _compute_display_title(self):
        """ONE fallback expression for the whole server, not one per reader.

        Both publish consumers and every admin-facing serialisation read this,
        so no call site can keep a fallback chain that forgets
        `internal_name`.

        NOT STORED: it derives from two columns of the row a reader already
        holds, so a stored copy could only go stale.
        """
        for rec in self:
            rec.display_title = (
                rec.internal_name or rec.title or "Untitled form")

    # The sections array exactly as the client sent it. A jsonb column so
    # Postgres validates and can query inside it; the ORM hands it back as a
    # native Python list, so `sections()` needs no json.loads.
    structure_json = fields.Json(default=list)

    # Set by `publish_to_assessment`. Publish stays repeatable: each press
    # makes a new draft assessment.
    published = fields.Boolean(default=False)
    #: HOW MANY QUESTIONS PUBLISHING MINTS, shown beside the Publish button as
    #: the console's confirm sheet does. Read from `_walk_document`, the same
    #: walk publish runs, so the number on the form is the number created. A
    #: form that cannot be published yet reports 0 rather than guessing.
    publish_question_count = fields.Integer(
        string="Questions When Published",
        compute="_compute_publish_question_count")

    @api.depends("structure_json")
    def _compute_publish_question_count(self):
        for rec in self:
            try:
                specs, problems, _warnings = rec._walk_document(rec.sections())
            except Exception:           # noqa: BLE001 - display only
                rec.publish_question_count = 0
                continue
            rec.publish_question_count = 0 if problems else len(specs)

    # FORM-WIDE question shuffle, authored in the designer's Form settings.
    #
    # WHY IT IS A FIELD AND NOT PART OF `structure_json`: it is a property of
    # the FORM, not of any section, and `publish_to_assessment` has to read it
    # without walking the document.
    #
    # DEFAULT FALSE IS THE OLD BEHAVIOUR. A Form Studio form publishes with
    # `preserve_question_order = True` precisely because the author grouped
    # their questions into sections on purpose - see `publish_to_assessment`.
    # This flag is how an author says "not this one": turning it on hands the
    # order back to `action_start`'s per-candidate shuffle, the same mechanism
    # a generated assessment has always used.
    shuffle_questions = fields.Boolean(
        default=False,
        help="Serve this form's questions in a random order, per candidate. "
             "Off (the default) keeps the order the sections were authored in.")

    @api.constrains("client_uid")
    def _check_uid_unique(self):
        for rec in self:
            if not rec.client_uid.strip():
                raise ValidationError("A form needs a client id.")
            if self.search_count(
                [("client_uid", "=", rec.client_uid), ("id", "!=", rec.id)]
            ):
                raise ValidationError(
                    "A form with this client id already exists."
                )

    @api.constrains("structure_json")
    def _check_structure(self):
        for rec in self:
            parsed = rec.structure_json or []
            if not isinstance(parsed, list):
                raise ValidationError(
                    "The form document must be a list of sections."
                )
            # Size is still bounded - a jsonb column has no free lunch. The
            # measurement is shared with `validate_structure`, so the editor
            # can warn about the ceiling before a save hits this.
            if self._structure_too_large(parsed):
                raise ValidationError("The form document is too large.")

    def sections(self):
        """The sections array. A Json field returns it already parsed; the
        guard keeps a read from ever 500-ing on a legacy/odd value."""
        self.ensure_one()
        parsed = self.structure_json
        return parsed if isinstance(parsed, list) else []

    # ------------------------------------------------------------------
    # Publish: materialise the form into the exam pipeline.
    #
    # The collection phase is NOT a parallel pipeline. A published form
    # becomes real bank questions under a dedicated generator plus a draft
    # assessment on that generator - from there the EXISTING machinery does
    # everything: assign, launch (tokens + invites), the candidate exam
    # runner, objective auto-scoring against `is_correct`, the LLM judge
    # against rubric/golden fields, manual release. Nothing here re-invents
    # delivery or scoring; it only translates the document.
    # ------------------------------------------------------------------

    def action_publish(self):
        """The BACK-OFFICE publish button.

        A thin adapter, deliberately: `publish_to_assessment` below owns the
        whole translation and this only changes how its answer is delivered.
        Reimplementing any of it here would fork the validation, and the API
        route and the button would then be able to disagree about whether a
        form is publishable - the exact failure the house rule in
        `controllers/api/write.py` exists to prevent.

        The two return shapes differ because the callers do. The route returns
        `{"problems": [...]}` as a 422 body; a view button has to RAISE, or
        Odoo commits the transaction and shows a success toast over a form that
        was refused.
        """
        self.ensure_one()
        result = self.publish_to_assessment()
        problems = result.get("problems")
        if problems:
            raise UserError(
                "This form is not ready to publish:\n- " + "\n- ".join(problems))

        # STRAIGHT TO THE DRAFT ASSESSMENT. Publishing is a step in a longer
        # task - the operator's next act is always to assign candidates - so
        # landing them on the thing they must now edit beats a toast naming a
        # record they then have to go and find.
        warnings = result.get("warnings") or []
        action = {
            "type": "ir.actions.act_window",
            "res_model": "assessments.be",
            "res_id": result.get("assessment_id"),
            "view_mode": "form",
            # Spelled out: as a notification's `next` below, this reaches the
            # client without the server clean-up that derives `views` from
            # `view_mode`, and the client cannot open an act_window without it.
            "views": [(False, "form")],
            "target": "current",
            "context": dict(
                self.env.context,
                etp_publish_warnings="\n".join(warnings),
            ),
        }
        if not warnings:
            return action
        # SAID OUT LOUD, as Flutter's Publish does: a warning is something
        # the candidate will not see (an image that failed to download). A
        # sticky notice first, then on to the draft assessment via `next`.
        return {
            "type": "ir.actions.client",
            "tag": "display_notification",
            "params": {
                "title": "Published, with %d warning(s)" % len(warnings),
                # One line: the notification escapes and collapses newlines.
                "message": "; ".join(warnings),
                "type": "warning",
                "sticky": True,
                "next": action,
            },
        }

    def publish_to_assessment(self):
        """Convert this form into bank questions + a draft assessment.

        Returns ``{"problems": [...]}`` when the form cannot be published
        as-is (nothing is created), else ``{"assessment_id", "generator_id",
        "questions_created", "warnings"}``. All-or-nothing by transaction:
        any failure mid-create rolls the whole publish back.
        """
        self.ensure_one()
        specs, problems, warnings = self._walk_document(self.sections())
        if problems:
            return {"problems": problems}

        generator = self._create_generator()
        Question = self.env["assessments.be.question"]
        QDim = self.env["assessments.be.question.dimension"]
        Image = self.env["assessments.be.question.image"]
        Video = self.env["assessments.be.question.video"]

        question_ids = []
        for i, spec in enumerate(specs):
            q = Question.create({
                "name": spec["name"][:200],
                "prompt": spec["prompt"],
                "description": spec.get("description") or False,
                "question_type": spec["question_type"],
                "sequence": (i + 1) * 10,
                "generator_id": generator.id,
                "source_ref": "form:%s#%s" % (self.client_uid,
                                              spec.get("item_id") or ""),
                "section_title": spec.get("section_title") or False,
                # The examiner authored the key by hand; publishing IS the
                # sign-off, exactly as draft approval is for generated items.
                "rubric_reviewed": True,
                "subjective_rubric_json":
                    json.dumps(spec["rubric"]) if spec.get("rubric")
                    else False,
                "solution_json":
                    json.dumps(spec["solution"])
                    if spec.get("solution") not in (None, "") else False,
                "official_reasoning": spec.get("official_reasoning") or False,
                "detection_mode": spec.get("detection_mode") or False,
                "transcription_language":
                    spec.get("transcription_language") or False,
            })
            for dim in spec.get("dims") or []:
                QDim.create({
                    "question_id": q.id,
                    "name": dim["name"][:200],
                    # The designer kind `_walk_section` stamped on this axis, so
                    # the exam renders the authored control. Empty stays empty -
                    # that is the documented "plain single-choice axis" default.
                    "input_kind": dim.get("kind") or "",
                    "option_line_ids": [
                        (0, 0, {"name": o["name"],
                                "sequence": (j + 1) * 10,
                                "is_correct": bool(o["is_correct"])})
                        for j, o in enumerate(dim["options"])],
                })
            for j, img in enumerate(spec.get("images") or []):
                vals = {
                    "question_id": q.id,
                    "slot": img.get("slot") or "single",
                    "label": (img.get("label") or "Image")[:200],
                    "sequence": (j + 1) * 10,
                }
                b64, warn = self._fetch_media_b64(img["url"])
                if b64:
                    vals["image"] = b64
                else:
                    # Keep the reference rather than lose the picture; the
                    # media route falls back to redirecting to this URL.
                    vals["image_url"] = img["url"]
                    if warn:
                        warnings.append(warn)
                if img.get("detections") is not None:
                    vals["detections_json"] = json.dumps(img["detections"])
                Image.create(vals)
            for j, vid in enumerate(spec.get("videos") or []):
                Video.create({
                    "question_id": q.id,
                    "slot": vid.get("slot") or "single",
                    "label": (vid.get("label") or "Video")[:200],
                    "sequence": (j + 1) * 10,
                    "video_url": vid["url"],
                })
            question_ids.append(q.id)

        assessment = self.env["assessments.be"].create({
            # THE OPERATOR-FACING NAME, not the respondent-facing heading.
            # Nobody sitting the exam ever reads an assessment's `name`; the
            # people who assign, launch and release it read nothing else, and
            # they find it by whatever they called the form. So the internal
            # name wins here when there is one, which is exactly what
            # `display_title` resolves.
            "name": self.display_title,
            "generator_id": generator.id,
            # The COUNT and the SELECTION, filled in rather than left for
            # launch: the app's Configuration tab and launch gates read them
            # ("0 = whole pool" is a server convention the client does not
            # model, so 0 read as "asked for 0 questions" and blocked the
            # launch). The creator can still lower the count on the draft;
            # launch draws that many from this pool.
            "question_limit": len(question_ids),
            "question_ids": [(6, 0, question_ids)],
            # The author grouped these into sections and arranged them on
            # purpose, so by DEFAULT action_start's per-candidate shuffle would
            # throw that structure away and serve a random order instead.
            #
            # Unless the author asked for exactly that. `shuffle_questions` is
            # the designer's own "Shuffle question order" switch: turning it on
            # hands the order back to `action_start`, which draws and shuffles
            # per candidate - the same mechanism a generated assessment uses -
            # so two candidates sitting this form see different orders.
            "preserve_question_order": not self.shuffle_questions,
            # Off and the subjective answers starve silently - the scoring
            # cron only drains evaluators whose scoring_requested was set on
            # submit, and that flag is only set when this is on.
            "llm_auto_score": True,
        })
        self.published = True
        return {
            "assessment_id": assessment.id,
            "generator_id": generator.id,
            "questions_created": len(question_ids),
            "warnings": warnings,
        }

    # ------------------------------------------------------------------
    # The BACK-OFFICE ITEM EDITOR's server half.
    #
    # `static/src/fields/form_item_editor/` renders this document in Odoo
    # (read-only there: the console's Form Studio edits it). Both methods
    # below exist so that widget is a VIEW over the rules in this file rather
    # than a second implementation of them: an editor that decided for itself
    # which kinds exist, or when a form is publishable, would drift from
    # publish at the next change here.
    # ------------------------------------------------------------------

    @api.model
    def form_item_kinds(self):
        """The kind catalogue the editor draws its type picker from.

        Straight out of `constants.FORM_ITEM_KINDS`, which is the same list
        `_item_spec` branches on - see the comment there for why the tuples are
        derived rather than retyped. Returned whole (label, family, role, the
        panels each kind needs, the hint) so the widget holds no opinion of its
        own about what a kind is.
        """
        return [dict(kind) for kind in FORM_ITEM_KINDS]

    @api.model
    def validate_structure(self, sections):
        """What publish would refuse this document for - WITHOUT publishing.

        Returns::

            {"problems": [...],          # the form cannot be published
             "warnings": [...],          # it can, but something was dropped
             "questions": int,           # how many questions it would deliver
             "items": [{"section": i, "item": j,
                        "problems": [...], "warnings": [...]}]}

        THE SAME WALK, NOT A SECOND COPY OF THE RULES. `_walk_document` below
        is what `publish_to_assessment` runs, so every message here is the
        message Publish would raise. The editor calls it to put each problem
        (a missing answer key, say) under the item that has it.

        NOTHING IS CREATED AND NOTHING IS FETCHED. The walk only translates the
        document; the generator, the questions and `_fetch_media_b64` all
        belong to the create half of publish, which this never reaches. That is
        also why it is safe to run on every keystroke - and why an unsaved
        document can be checked: `@api.model`, so the caller passes the sections
        it is holding rather than a record id.

        PER-ITEM ATTRIBUTION IS DONE BY RE-WALKING ONE ITEM AT A TIME, not by
        parsing the messages. `_walk_section` builds each message from the
        item's own title and its section's (`_where`), so a document-level list
        cannot be split back apart reliably - two items sharing a title produce
        the same prefix. Walking a one-item section instead gives that item's
        own problems exactly, and it is honest about cross-item effects: the
        only ones are the informational carry (which raises no problem) and the
        form-level "no question can be delivered", which stays at form level
        where it belongs. The section TITLE is kept on the synthetic section so
        the message reads identically to the one publish would emit.
        """
        document = sections if isinstance(sections, list) else []
        specs, problems, warnings = self._walk_document(document)

        # The size ceiling, surfaced BEFORE the save rather than as a
        # ValidationError over the top of an editor full of work. Same helper
        # the constraint uses, so the two cannot disagree about the limit.
        if self._structure_too_large(document):
            problems.append(
                "The form document is too large (over %d KB). Remove some "
                "items, or shorten the text." % (MAX_STRUCTURE_BYTES // 1024))

        items = []
        for section_index, section in enumerate(document):
            if not isinstance(section, dict):
                continue
            title = str(section.get("title") or "")
            for item_index, item in enumerate(section.get("items") or []):
                if not isinstance(item, dict):
                    continue
                one_problems, one_warnings = [], []
                # THE ITEM'S REAL POSITION, so a one-item re-walk produces the
                # same sentence the document walk did. Without it every
                # blank-titled item would attribute as "question 1".
                self._walk_section(
                    {"title": title, "items": [item]}, [],
                    one_problems, one_warnings,
                    {"text": [], "images": [], "videos": []},
                    first_position=item_index + 1)
                if one_problems or one_warnings:
                    items.append({"section": section_index,
                                  "item": item_index,
                                  "problems": one_problems,
                                  "warnings": one_warnings})
        return {"problems": problems, "warnings": warnings,
                "questions": len(specs), "items": items}

    # -- section walk ---------------------------------------------------

    def _walk_document(self, sections):
        """Translate a whole form document into question specs.

        Returns ``(specs, problems, warnings)``. Split out of
        `publish_to_assessment` so `validate_structure` can run the identical
        walk without creating anything - a dry run that shares the rules by
        being the same code, not by copying them.

        DELIBERATELY NOT `ensure_one`-GUARDED, and the walk reads no field of
        `self` except `client_uid` in one log line, which is simply empty on an
        empty recordset. `assessments.be.task.template._preview_specs` already
        calls `_walk_section` that way for the same reason, and the editor
        validates documents that have not been saved to any row yet.
        """
        specs, problems, warnings = [], [], []

        # Informational blocks travel with the NEXT question, across section
        # boundaries too: an "Instructions" section holding only text blocks
        # lands on the first real question instead of being dropped.
        carry = {"text": [], "images": [], "videos": []}
        for section in sections:
            if not isinstance(section, dict):
                continue
            self._walk_section(section, specs, problems, warnings, carry)
        if any(carry.values()):
            if specs:
                self._attach_carry(specs[-1], carry)
            else:
                warnings.append(
                    "The form's informational blocks were not delivered - "
                    "no question exists to carry them.")

        if not specs:
            problems.append(
                "The form has no question that can be delivered as an exam.")
        return specs, problems, warnings

    @staticmethod
    def _structure_too_large(parsed):
        """True when [parsed] exceeds the column's size ceiling.

        ONE measurement for the constraint and for the editor's pre-flight
        check: a widget that measured it its own way would let an operator keep
        typing right up to a save that then refuses the whole document.
        """
        try:
            return len(json.dumps(parsed).encode("utf-8")) > MAX_STRUCTURE_BYTES
        except (TypeError, ValueError):
            # Unserialisable is not "too large" - `_check_structure` is not the
            # place that error belongs, and jsonb will refuse it anyway.
            return False

    def _walk_section(self, section, specs, problems, warnings, carry,
                      first_position=1):
        """Translate one section, folding informational blocks into their
        neighbouring questions so no authored content is dropped.

        ``carry`` accumulates blocks awaiting the next question and crosses
        section boundaries: an instructions-only section rides on the first
        question that follows it. Blocks trailing a section that DID produce
        questions attach to that section's last question instead - an
        illustration under the final question belongs to it, not to whatever
        the next section opens with.
        """
        sec_title = str(section.get("title") or "").strip()
        first_in_section = len(specs)

        for offset, item in enumerate(section.get("items") or []):
            if not isinstance(item, dict):
                continue
            kind = str(item.get("kind") or "")
            # POSITION IN THE WHOLE SECTION, not in this walk. `validate_structure`
            # re-walks each item ALONE to attribute its problems, so a position
            # counted from the loop would be 1 every time and the per-item
            # message would stop matching the one publish emits - which the
            # method's own docstring promises it does.
            where = self._where(item, sec_title, first_position + offset)

            if kind == "textBlock":
                # A BLANK LINE BETWEEN THE TWO, not a space. `title` is the
                # block's heading and `help` is its body; joining them with a
                # single space ran them into one broken sentence, which the
                # candidate reads verbatim above the question:
                #
                #   "Read before answering This block carries no answer."
                #
                # Separated, it reads as the heading and paragraph the examiner
                # authored. The same "\n\n" the carry list already uses to
                # separate one block from the next, so a block with both parts
                # and two blocks with one part each render identically.
                text = "\n\n".join(s for s in (
                    str(item.get("title") or "").strip(),
                    str(item.get("help") or "").strip()) if s)
                if text:
                    carry["text"].append(text)
                continue
            # A media block with NO options is still purely informational and
            # folds into the next question, as always. One WITH options is
            # itself the question now - the candidate answers about the clip
            # or image right there, instead of it silently riding along on
            # whatever question happens to follow it. Falls through to
            # `_item_spec` below rather than `continue`-ing into carry.
            if (kind in FORM_KINDS_MEDIA_BLOCK
                    and not self._media_item_has_options(item)):
                url = str(item.get("media_url") or "").strip()
                if not url:
                    continue
                label = str(item.get("title") or "").strip()
                if self._item_media_is_video(item, url, kind):
                    carry["videos"].append({"url": url, "label": label})
                else:
                    carry["images"].append({"url": url, "label": label})
                continue
            if kind == "fileUpload":
                problems.append(
                    "%s: file-upload questions cannot be delivered in the "
                    "exam pipeline - remove it or replace it with a text "
                    "question." % where)
                continue

            spec = self._item_spec(item, kind, where, problems, warnings)
            if spec is None:
                continue
            # STAMP THE DESIGNER'S KIND ONTO EVERY AXIS THIS ITEM PRODUCED.
            #
            # `assessments.be.question.dimension.input_kind` is what the exam
            # screen reads to render the control the examiner actually drew - a
            # 1..5 scale as buttons, a checkbox group as checkboxes - instead of
            # collapsing every axis to radios. Only the GENERATION path ever set
            # it (models/prompt.py, from the template's own item kind), so a form
            # published from the designer arrived with every `input_kind` empty:
            # an examiner drew a linear scale, previewed a linear scale in Form
            # Studio, and the candidate was served a radio list. Verified on
            # stage - all 15 kinds published with `input_kind` None.
            #
            # Stamped HERE, once, from the kind `_walk_section` already has in
            # hand, rather than in each of `_item_spec`'s five `dims=[...]`
            # returns: a new kind then inherits this automatically instead of
            # being one forgotten literal away from rendering as radios.
            # `setdefault` so a spec that deliberately names its own axis kind
            # keeps it.
            for dim in spec.get("dims") or []:
                dim.setdefault("kind", kind)
            # THE SECTION THE EXAMINER PUT THIS UNDER. Stamped here for the same
            # reason `kind` is: this is the one place that still knows it.
            # Sections already decide ORDER (`preserve_question_order`), but the
            # candidate was never told a section existed - so a paper grouped
            # into "Before you start" / "On the floor" / "Escalation" arrived as
            # one flat run of questions, and the grouping the examiner authored
            # was invisible to the only person it was for.
            spec.setdefault("section_title", sec_title)
            self._attach_carry(spec, carry, lead=True)
            specs.append(spec)

        if any(carry.values()) and len(specs) > first_in_section:
            self._attach_carry(specs[-1], carry)

    @staticmethod
    def _attach_carry(spec, carry, lead=False):
        """Fold accumulated informational blocks into one question spec.

        ``lead`` puts the text ABOVE the question's own help (a heading read
        before answering); trailing attachment appends below it.
        """
        if carry["text"]:
            extra = "\n\n".join(carry["text"])
            own = spec.get("description") or ""
            spec["description"] = (
                extra + ("\n\n" + own if own else "") if lead
                else (own + "\n\n" + extra if own else extra))
        if carry["images"]:
            # AFTER the question's own media, and never in `single` for a
            # labelling question - `_label_boxes` reads the FIRST single
            # image and must find the marked plate there.
            slot = ("output" if spec["question_type"] == "image_label"
                    else "single")
            spec.setdefault("images", []).extend(
                dict(im, slot=slot) for im in carry["images"])
        if carry["videos"]:
            spec.setdefault("videos", []).extend(carry["videos"])
        carry["text"], carry["images"], carry["videos"] = [], [], []

    def _item_spec(self, item, kind, where, problems, warnings):
        """One item -> one question spec, or None (with a problem/warning)."""
        title = str(item.get("title") or "").strip() or "Untitled question"
        base = {
            "item_id": str(item.get("id") or ""),
            "name": title,
            "prompt": title,
            "description": str(item.get("help") or "").strip(),
        }
        golden = str(item.get("golden_answer") or "").strip()

        if kind in FORM_KINDS_CHOICE:
            options = self._options_of(item, where, problems)
            if options is None:
                return None
            if not any(o["is_correct"] for o in options):
                problems.append(
                    "%s: no option is marked correct - set the answer key "
                    "in the designer." % where)
                return None
            if kind != "checkboxes" and not self._single_answer_or_problem(
                    options, where, problems):
                return None
            if item.get("allow_other"):
                warnings.append(
                    '%s: the "Other" free-text option is not deliverable in '
                    "an exam and was dropped." % where)
            return dict(base,
                        question_type="mcq" if kind != "checkboxes"
                        else "msq",
                        dims=[{"name": "Answer", "options": options}])

        if kind in FORM_KINDS_GRID:
            rows = [str(r) for r in (item.get("rows") or []) if str(r)]
            cols = [str(c) for c in (item.get("columns") or []) if str(c)]
            key = item.get("grid_key") or {}
            if not rows or not cols:
                problems.append("%s: the grid has no rows or no columns."
                                % where)
                return None
            # NORMALISE ONCE, THEN USE THE SAME VALUE FOR BOTH JOBS.
            #
            # The check below used `str(...).strip()` while the write used the
            # RAW value, so the two disagreed on anything that needed coercing:
            # a designer key of `1` against columns ["1","2"], or " Yes" against
            # ["Yes","No"], passed the unkeyed check and then matched no column,
            # marking nothing correct. That row's dimension is then keyless, so
            # it silently drops out of BOTH sides of the paper and the question
            # quietly shrinks; when every row is affected the question is worth
            # nothing and only `action_start` catches it, with a message about a
            # missing key on a grid the designer can see is keyed.
            #
            # A ROW'S KEY IS A SET, because a checkbox grid row is an MSQ.
            # `checkboxGrid` renders checkboxes and `_pick` accumulates several
            # column ids for one row, so a single-valued key could not express
            # what the candidate is able to answer: a row where both Cubicles
            # and Laptops are right had to be keyed to one of them, and a
            # candidate ticking both scored 0 (the mark is an exact-set match -
            # see `response._dimension_marks`). `choiceGrid` is radio buttons
            # and stays single-valued, enforced below rather than by the shape.
            multi = kind == "checkboxGrid"
            keyed = {i: self._grid_row_key(key.get(str(i)), cols)
                     for i, _r in enumerate(rows)}
            unkeyed = [r for i, r in enumerate(rows) if not keyed[i]]
            if unkeyed:
                problems.append(
                    "%s: rows without an answer key: %s." %
                    (where, ", ".join(unkeyed)))
                return None
            if not multi:
                over = [r for i, r in enumerate(rows) if len(keyed[i]) > 1]
                if over:
                    problems.append(
                        "%s: a multiple-choice grid takes ONE correct column "
                        "per row - these have more than one: %s. Use a checkbox "
                        "grid if a row really has several right answers."
                        % (where, ", ".join(over)))
                    return None
            dims = [{"name": r,
                     "options": [{"name": c, "is_correct": c in keyed[i]}
                                 for c in cols]}
                    for i, r in enumerate(rows)]
            return dict(base,
                        question_type="mcq" if kind == "choiceGrid"
                        else "msq",
                        dims=dims)

        if kind in FORM_KINDS_SCALE:
            if kind == "linearScale":
                mn = int(item.get("scale_min") or 1)
                mx = int(item.get("scale_max") or 5)
                lo = str(item.get("scale_min_label") or "").strip()
                hi = str(item.get("scale_max_label") or "").strip()
                if lo or hi:
                    legend = "Scale: %s = %s, %s = %s" % (
                        mn, lo or mn, mx, hi or mx)
                    base["description"] = (
                        base["description"] + "\n\n" + legend
                        if base["description"] else legend)
            else:
                mn, mx = 1, int(item.get("rating_max") or 5)
            if not golden.isdigit() or not mn <= int(golden) <= mx:
                problems.append(
                    "%s: set the correct value (%s-%s) as the golden answer "
                    "so the scale can be scored." % (where, mn, mx))
                return None
            options = [{"name": str(v), "is_correct": str(v) == golden}
                       for v in range(mn, mx + 1)]
            return dict(base, question_type="mcq",
                        dims=[{"name": "Answer", "options": options}])

        if kind in FORM_KINDS_WRITTEN:
            if kind in ("date", "time"):
                warnings.append(
                    "%s: delivered as a free-text question (the exam runner "
                    "has no %s picker)." % (where, kind))
            # A GOLDEN ANSWER IS MANDATORY, not advisory.
            #
            # This was a warning, so a written question could be published with
            # no written standard and the judge graded it "against the prompt
            # alone" - i.e. it invented the standard per candidate. That is the
            # one thing an answer key exists to prevent: two candidates giving
            # the same answer could be marked differently, and nothing on the
            # paper would say why. Every objective kind already REFUSED to
            # publish without its key; the subjective kinds now match.
            if not golden:
                problems.append(
                    "%s: write the golden answer - the model answer the judge "
                    "marks against. Without it the standard is invented per "
                    "candidate." % where)
                return None
            rubric = {"ideal_answer": golden} if golden else None
            return dict(base, question_type="subjective_rubric",
                        rubric=rubric, solution=golden or None)

        # Reached only when `_walk_section` found this media block HAS
        # options - `_media_item_has_options` gated that. Same options/
        # answer-key shape as multipleChoice/checkboxes, just with the
        # question's own single image or video attached instead of an
        # option list alone.
        if kind in FORM_KINDS_MEDIA_BLOCK:
            url = str(item.get("media_url") or "").strip()
            if not url:
                problems.append("%s: the question has no media." % where)
                return None
            options = self._options_of(item, where, problems)
            if options is None:
                return None
            if not any(o["is_correct"] for o in options):
                problems.append(
                    "%s: no option is marked correct - set the answer key "
                    "in the designer." % where)
                return None
            if not item.get("multi_select") and not \
                    self._single_answer_or_problem(options, where, problems):
                return None
            is_video = self._item_media_is_video(item, url, kind)
            media_key = "videos" if is_video else "images"
            return dict(
                base,
                question_type="msq" if item.get("multi_select") else "mcq",
                dims=[{"name": "Answer", "options": options}],
                **{media_key: [{"slot": "single", "url": url,
                                "label": title}]})

        if kind == "comparePair":
            url_a = str(item.get("media_url") or "").strip()
            url_b = str(item.get("media_url_b") or "").strip()
            if not url_a or not url_b:
                problems.append(
                    "%s: an A/B comparison needs both images." % where)
                return None
            options = self._options_of(item, where, problems)
            if options is None:
                return None
            if not any(o["is_correct"] for o in options):
                problems.append(
                    "%s: mark the correct verdict so the comparison can be "
                    "scored." % where)
                return None
            if not self._single_answer_or_problem(
                    options, where, problems, noun="verdict"):
                return None
            # WHETHER THE JUSTIFICATION IS PART OF THE QUESTION IS THE
            # EXAMINER'S CALL, and this is where that call is enforced.
            #
            # A comparison is scorable on its VERDICT alone: the candidate
            # picks a side, that side is keyed on an option, and it is marked
            # in code. So the written half is genuinely optional, unlike the
            # written kinds above where the golden answer IS the only answer
            # key. The designer's "Require justification" switch says which
            # shape this question is, and publish makes that true rather than
            # trusting it:
            #
            # * ON  -> a rationale MUST be authored. It is what the judge marks
            #   the candidate's prose against (`prompts/scoring.md`), so an
            #   empty one would have the standard invented per candidate -
            #   exactly what an answer key exists to prevent. Refused here,
            #   where the examiner can still fix it.
            # * OFF -> `official_reasoning` is FORCED EMPTY, even if the item
            #   still carries text from before the switch was turned off.
            #   Leaving a stale standard behind would keep grading a box the
            #   candidate is no longer even shown.
            #
            # That makes "the switch is on" and "this question has a written
            # standard" the SAME FACT, which is what lets everything
            # downstream keep reading `official_reasoning` and get the
            # switch's answer: the marks (`question._component_counts`), the
            # judge (`response._image_ab_uses_llm`), the candidate's textarea
            # (`serializers.question_for_candidate`) and the submit gate.
            # One fact, one place it is decided, so they cannot disagree.
            if bool(item.get("require_justification")):
                if not golden:
                    problems.append(
                        "%s: the comparison asks for a justification, so write "
                        "the answer rationale the judge marks it against - or "
                        'turn "Require justification" off to score the '
                        "comparison on its verdict alone." % where)
                    return None
            else:
                golden = ""
            return dict(base, question_type="image_ab",
                        dims=[{"name": "Overall Choice",
                               "options": options}],
                        official_reasoning=golden or None,
                        images=[{"slot": "a", "url": url_a, "label": "A"},
                                {"slot": "b", "url": url_b, "label": "B"}])

        if kind == "imageAnnotation":
            url = str(item.get("media_url") or "").strip()
            if not url:
                problems.append("%s: the annotation question has no image."
                                % where)
                return None
            regions = [r for r in (item.get("regions") or [])
                       if isinstance(r, dict)]
            numbers = sorted({int(r.get("n") or 0) for r in regions
                              if int(r.get("n") or 0) > 0}) \
                or list(range(1, int(item.get("annotation_count") or 0) + 1))
            # CAP THE BOXES, HERE, BEFORE ANYTHING IS DERIVED FROM THEM.
            #
            # This was the one authoring lane with no ceiling at all: a form
            # carrying 30 regions produced 30 boxes, 30 answer-key entries and
            # 30 typing fields, whatever the labelling cap said. Worse, it was
            # PERMANENT - the spec below writes a non-empty `detections_json`,
            # which makes the detect cron skip the image, so the one place that
            # would have applied a cap never ran on it.
            #
            # The cut is made once, on `numbers`, because `labels`, `detections`
            # and `ideal` are all derived from it below; capping any of them
            # separately is how a key listing 30 entries ends up beside 10 boxes.
            #
            # The ceiling is the module default rather than a generator's own
            # `image_label_count`, because the generator does not exist yet at
            # this point - `_create_generator` runs after the specs are built,
            # and it pins the SAME number so the two can never disagree.
            if len(numbers) > DEFAULT_IMAGE_LABEL_COUNT:
                _logger.warning(
                    "form %s item %s: %d annotation region(s) exceed the "
                    "labelling cap of %d; keeping the first %d.",
                    self.client_uid, item.get("id") or "?", len(numbers),
                    DEFAULT_IMAGE_LABEL_COUNT, DEFAULT_IMAGE_LABEL_COUNT)
                numbers = numbers[:DEFAULT_IMAGE_LABEL_COUNT]
            if not numbers:
                problems.append(
                    "%s: set an annotation count or draw markers on the "
                    "image." % where)
                return None
            labels = {str(k): str(v).strip()
                      for k, v in (item.get("golden_labels") or {}).items()}
            # EVERY POINT NEEDS ITS OWN GOLDEN ANSWER, not just one of them.
            #
            # This refused only when ALL the markers were unkeyed and warned
            # otherwise, so a 5-point question with 1 key published happily - and
            # the four unkeyed points are marks no candidate can earn, because
            # the judge has nothing to compare their description against. The
            # examiner sees "5 points" and a score out of far less than five.
            missing = [str(n) for n in numbers if not labels.get(str(n))]
            if missing:
                problems.append(
                    "%s: every point needs a golden answer - what a correct "
                    "description of it says. Missing: %s."
                    % (where, ", ".join(missing)))
                return None
            by_number = {int(r["n"]): r for r in regions
                         if int(r.get("n") or 0) > 0}
            detections = []
            for n in numbers:
                det = {"number": n, "label": labels.get(str(n), "")}
                r = by_number.get(n)
                if r is not None:
                    try:
                        y, x = float(r["y"]), float(r["x"])
                        h, w = float(r["h"]), float(r["w"])
                        # box_2d is Gemini's 0-1000 space, y-first.
                        det["box_2d"] = [round(y * 1000), round(x * 1000),
                                         round((y + h) * 1000),
                                         round((x + w) * 1000)]
                    except (KeyError, TypeError, ValueError):
                        pass
                detections.append(det)
            ideal = {str(n): labels.get(str(n), "") for n in numbers}
            return dict(base, question_type="image_label",
                        detection_mode="object",
                        rubric={"ideal_labels": ideal},
                        solution=ideal,
                        images=[{"slot": "single", "url": url,
                                 "label": title, "detections": detections}])

        if kind == "promptWriting":
            # PROMPT WRITING -> image_prompt | video_prompt.
            #
            # ONE designer kind serves both stored types, because they differ
            # only in the medium the prompt has to produce - the same reason
            # `TASK_PRIMITIVE_TO_QUESTION_TYPE` needed two primitives but the
            # harness needs no third engine. The medium is READ from the URL
            # (`_looks_like_video`), never asked: the designer already tells an
            # image block from a video one that way, and a picker the author
            # could set against the actual file would only ever disagree with
            # the renderer.
            #
            # BEFORE THIS BRANCH EXISTED, `image_prompt` and `video_prompt`
            # were authorable ONLY from a task template - the designer had no
            # kind that produced them, so a Form Studio form could never carry
            # a prompt-writing question at all even though the exam runner has
            # rendered both for as long as they have existed.
            url = str(item.get("media_url") or "").strip()
            url_b = str(item.get("media_url_b") or "").strip()
            if not url:
                problems.append(
                    "%s: a prompt-writing question needs the image or clip "
                    "the candidate writes a prompt for." % where)
                return None
            # Mandatory, same reasoning as every other written kind: the golden
            # prompt IS this question's answer key, and without it the judge has
            # only the stimulus to mark against.
            if not golden:
                problems.append(
                    "%s: write the golden prompt - the model prompt the judge "
                    "marks each candidate's attempt against." % where)
                return None

            # The MEDIUM follows the first plate. A pair whose two halves
            # disagree (a still reference for a clip output) is a real
            # authoring shape - the type follows the OUTPUT in that case,
            # because that is what the prompt has to produce.
            deciding = url_b or url
            # The item's probed kind describes `media_url`; when a transform
            # pair names a separate OUTPUT url, that url is what the type has to
            # follow, so the recorded kind only speaks for the single-plate
            # form.
            is_video = (self._looks_like_video(deciding) if url_b
                        else self._item_media_is_video(item, url, kind))
            media_key = "videos" if is_video else "images"

            # Slots mirror what `_ImagePromptLayout`/`_VideoPromptLayout`
            # already read: one `single` plate for the from-scratch form, a
            # `reference` -> `output` pair for the transform form.
            if url_b:
                media = [{"slot": "reference", "url": url,
                          "label": "Reference"},
                         {"slot": "output", "url": url_b, "label": "Output"}]
            else:
                media = [{"slot": "single", "url": url, "label": title}]

            spec = dict(base, question_type=(
                "video_prompt" if is_video else "image_prompt"))
            # The written prompt is graded against the golden one, in the same
            # rubric shape every other subjective type uses.
            if golden:
                spec["rubric"] = {"ideal_answer": golden}
                spec["solution"] = golden
            # OPTIONAL rating axes. Unlike every other option-carrying kind an
            # empty list is the normal case here, so no options is not a
            # problem - the prompt itself is the answer. When the author DID
            # add axes they are keyed like any other choice.
            options = [{"name": str(o.get("label") or "").strip(),
                        "is_correct": bool(o.get("correct"))}
                       for o in (item.get("options") or [])
                       if isinstance(o, dict)
                       and str(o.get("label") or "").strip()]
            if options:
                if len(options) < 2:
                    problems.append(
                        "%s: a rating axis needs at least two options - one "
                        "option is not a choice. Remove it, or add another."
                        % where)
                    return None
                if not any(o["is_correct"] for o in options):
                    problems.append(
                        "%s: the rating axis has no correct option - mark one "
                        "so it can be scored, or remove the axis." % where)
                    return None
                if not self._single_answer_or_problem(
                        options, where, problems):
                    return None
                spec["dims"] = [{"name": "Rating", "options": options}]
            spec[media_key] = media
            return spec

        if kind == "transcription":
            # TRANSCRIPTION -> one question that owns its clip, keyed by what
            # a person heard in it: the text plus the whole-audio category,
            # the sound characteristics and the speakers (Strix's client
            # conventions). Marked by the judge against that key with the
            # client's critical/minor rule (constants.TRANSCRIPTION_RUBRIC).
            url = str(item.get("media_url") or "").strip()
            if not url:
                problems.append(
                    "%s: add the clip the candidate transcribes." % where)
                return None
            clip = clean_clip_answers(item.get("golden_clip"))
            # Any category but None means the clip is not transcribed, so an
            # empty transcription is the right key there - and text typed
            # against such a category is dropped, as the guide says.
            transcribed = clip["category"] == "none"
            if transcribed and not golden:
                problems.append(
                    "%s: write the correct transcription - what is said in "
                    "the clip, in spoken form. The judge marks every "
                    "candidate against it." % where)
                return None
            # The client's QC rule: numbers are words, as said (`\d` covers
            # Devanagari digits too).
            if transcribed and re.search(r"\d", golden):
                problems.append(
                    "%s: write every number as words, as it is said (पाँच सौ, "
                    "not 500). A digit in a transcription is a critical "
                    "mistake." % where)
                return None
            language = str(item.get("transcription_language") or "hi")
            return dict(
                base, question_type="transcription",
                transcription_language=(
                    language if language in ("hi", "en") else "hi"),
                rubric=TRANSCRIPTION_RUBRIC,
                solution={"transcription": golden if transcribed else "",
                          "category": clip["category"],
                          "characteristics": clip["characteristics"],
                          "speakers": clip["speakers"]},
                videos=[{"slot": "single", "url": url, "label": title}])

        warnings.append('%s: unsupported question kind "%s" was skipped.'
                        % (where, kind))
        return None

    # -- small helpers --------------------------------------------------

    @staticmethod
    def _where(item, sec_title, position=0):
        """How a refusal names the item it is about.

        THE POSITION IS THE FALLBACK, NOT AN ADDITION. An authored form names
        its questions, and `"Which control stops the line fastest?" (section
        "Lockout")` is the sentence an examiner can act on - prefixing it with a
        number would be noise.

        A BLANK title is the case that needed fixing, and the import template
        made it the normal one: it ships fifteen items with `title: ""`, so
        every line of the publish refusal read `"Untitled question" (section
        "2. Choices, grids and scales")`. Four of those against seven blank
        items is a checklist the author cannot act on - they can see WHAT is
        missing and not WHERE. `question 4` is the item's position in its
        section, which is exactly how the designer lists them.
        """
        title = str(item.get("title") or "").strip()
        if not title:
            title = "question %d" % position if position else "Untitled question"
            named = "%s (section \"%s\")" % (title, sec_title) if sec_title \
                else title
            return named
        return ('"%s" (section "%s")' % (title, sec_title)) if sec_title \
            else '"%s"' % title

    @staticmethod
    def _options_of(item, where, problems):
        options = [{"name": str(o.get("label") or "").strip(),
                    "is_correct": bool(o.get("correct"))}
                   for o in (item.get("options") or [])
                   if isinstance(o, dict)
                   and str(o.get("label") or "").strip()]
        if not options:
            problems.append("%s: the question has no options." % where)
            return None
        if len(options) < 2:
            # EVERY OTHER AUTHORING LANE REFUSES THIS and this one did not:
            # generation (`vertex._validate_question_item`), the bank API
            # (`write.py`) and the bank importer all require at least two.
            # A one-option choice is not a question, it is a free mark.
            problems.append(
                "%s: a choice question needs at least two options - one "
                "option is not a choice." % where)
            return None
        return options

    @staticmethod
    def _grid_row_key(raw, cols):
        """One grid row's answer key as a SET of column labels it names.

        Accepts either shape the designer may send: a bare string (every form
        authored before checkbox grids became multi-select) or a list. Both are
        coerced with `str(...).strip()` and then filtered against `cols`, so a
        key naming a column that no longer exists drops out and the row reads as
        unkeyed - which is what the caller refuses on. That filter is the whole
        reason coercion happens HERE rather than at each use site: the check and
        the write have to agree on the value, and they did not before.

        Order is not preserved and does not matter: the caller iterates `cols`
        to build the options, so the stored order is the column order.
        """
        values = raw if isinstance(raw, (list, tuple, set)) else [raw]
        wanted = {str(v).strip() for v in values if str(v).strip()}
        return {c for c in cols if c in wanted}

    @staticmethod
    def _single_answer_or_problem(options, where, problems, noun="option"):
        """Refuse a single-select answer key that names more than one correct.

        THIS IS THE ONE THAT SILENTLY COSTS CANDIDATES MARKS. Scoring matches a
        dimension's chosen set against its key set EXACTLY
        (`assessments.be.response._dimension_marks`). A radio group can only
        ever submit ONE option, so a two-correct key can never be equalled: the
        dimension is keyed, so it counts in the paper's denominator, and every
        candidate loses that mark with nothing to show why.

        No launch gate catches it either - `_is_keyless` asks whether a key
        exists, not whether it is reachable. So the paper looks healthy and the
        cohort just reads as having got the question wrong.

        Every other lane already refuses it; this one was the gap.
        """
        correct = [o for o in options if o["is_correct"]]
        if len(correct) > 1:
            problems.append(
                "%s: %d %ss are marked correct, but only one answer can be "
                "chosen here - a candidate could never match that key, so the "
                "mark would be unearnable. Mark one, or make it a "
                "multi-select question." % (where, len(correct), noun))
            return False
        return True

    @staticmethod
    def _item_media_is_video(item, url, kind=None):
        """Whether this item's media is a clip, per the item FIRST.

        WHY THE ITEM AND NOT THE URL. One Google Drive link
        (`/file/d/<id>/view`) serves an image or a video with no way to tell
        which from the string, so `_looks_like_video` cannot answer for it and
        used to guess "image" - which is how a Drive clip reached a candidate as
        a dead 0:00 player, its bytes fetched into the question's image field.

        The designer probes the content type when the examiner pastes a share
        link and records the answer as `media_kind` on the item, so THAT is the
        authority whenever it is present. `videoBlock` still wins outright - the
        examiner declared the medium by choosing the block - and
        `_looks_like_video` remains the fallback for every item authored before
        `media_kind` existed, which is why it keeps its own host and extension
        tests rather than delegating here.

        Anything other than the two known values is ignored rather than trusted:
        an unrecognised `media_kind` falls through to the url test instead of
        deciding by accident.

        NOTE WHAT IS DELIBERATELY ABSENT: an `imageBlock` short-circuit. That
        kind is the designer's DEFAULT media block, not a declaration of medium,
        so an examiner drops a YouTube link into one routinely and it must still
        publish as a clip. Only `videoBlock` is a statement of intent.
        """
        if kind == "videoBlock":
            return True
        # AUDIO IS A CLIP HERE: it lands on `question.video` exactly as a video
        # does (`question.video.media_kind` tells the two apart), and fetching
        # an mp3 into an image field is the same dead plate as a fetched clip.
        is_clip = (EtpStudioForm._looks_like_video(url)
                   or EtpStudioForm._looks_like_audio(url))
        declared = str((item or {}).get("media_kind") or "").strip().lower()
        if declared in ("video", "audio", "image"):
            # A PROBED KIND STILL LOSES TO A URL THAT SAYS OTHERWISE. The probe
            # records what one host served at paste time; `_looks_like_video`
            # recognises a YouTube or Vimeo link, which no probe of ours can
            # fetch at all. Trusting a stale "image" over an embed host is how a
            # YouTube link in an `imageBlock` got its viewer PAGE stored as a
            # picture - see
            # `test_an_imageBlock_carrying_a_youtube_link_publishes_as_a_clip_too`.
            return is_clip or declared != "image"
        return is_clip

    @staticmethod
    def _looks_like_video(url):
        """True when [url] is a clip rather than a still.

        MIRRORS `mediaKindOf` IN THE CLIENT (`video_plate.dart`), and the two
        must keep agreeing: the designer decides by this test which preview to
        draw, and publish decides by this test whether a question stores a
        `video_url` or fetches image bytes. A disagreement means a clip renders
        in the designer and publishes as a picture.

        TWO SHAPES THE OLD EXTENSION-ONLY TEST GOT WRONG, both of them
        completely ordinary:

          * A YOUTUBE OR VIMEO LINK, which has no extension at all. It was
            filed under `images`, and `_fetch_media_b64` then fetched the
            viewer PAGE and stored ~1 MB of HTML in the question's image field
            with no warning to anyone. The candidate got a dead plate for a
            clip the examiner had every reason to think was attached.
          * `https://cdn.example.com/clip.mp4?sig=...`, whose extension is
            hidden behind the query string every signed CDN URL carries.

        AND A THIRD, WHICH REACHED A CANDIDATE AS A DEAD 0:00 PLAYER. A Google
        Drive link has NO extension and is on no embed host, so a Drive clip was
        filed under `images` and its bytes fetched into the question's image
        field. `_is_video_content_host` closes it for the download host the
        designer rewrites to. It cannot be closed for a raw
        `drive.google.com/file/d/<id>/view` link, because that ONE url serves
        both media - which is exactly why the designer probes the content type
        when the examiner pastes it, and why `media_kind` on the item (below) is
        the authority when it is present.
        """
        raw = (url or "").strip()
        if not raw:
            return False
        if _is_embed_video_host(raw):
            return True
        if _is_video_content_host(raw):
            return True
        # The extension off the PATH, so a query or fragment cannot hide it.
        path = urlparse(raw).path or raw
        return path.rsplit(".", 1)[-1].lower() in ("mp4", "webm", "mov")

    @staticmethod
    def _looks_like_audio(url):
        """True when [url] (or a bare filename) is an audio file.

        The extension test of `_looks_like_video`, over `AUDIO_MIME_BY_EXT`,
        read off the PATH so a signed URL's query cannot hide it. No host test:
        no embed host serves audio alone.
        """
        raw = (url or "").strip()
        if not raw:
            return False
        path = urlparse(raw).path or raw
        return path.rsplit(".", 1)[-1].lower() in AUDIO_MIME_BY_EXT

    @staticmethod
    def _media_item_has_options(item):
        """True once the author has typed at least one real option label on
        an imageBlock/videoBlock item - the signal that turns it from a
        decorative carry-forward block into its own answerable question."""
        return any(
            isinstance(o, dict) and str(o.get("label") or "").strip()
            for o in (item.get("options") or []))

    def _create_generator(self):
        """A dedicated pool per publish: `action_start` draws every active
        question of the generator, so the generator must hold exactly this
        form's questions and nothing else. Re-publishing mints a fresh pair
        rather than mutating a pool a launched assessment already froze."""
        Prompt = self.env["assessments.be.prompt"]
        # `display_title`, for the same reason the assessment uses it: the pool
        # is an operator artefact end to end - it appears in the generator list
        # and in every question's provenance - so it must carry the name the
        # operator knows the form by.
        base = ("Form: %s" % self.display_title)[:110]
        name, n = base, 1
        while Prompt.search_count([("name", "=", name)]):
            n += 1
            name = "%s (%s)" % (base, n)
        return Prompt.create({
            "name": name,
            "state": "done",
            "source_text": "Published from Form Studio form %s."
                           % self.client_uid,
            # Pinned explicitly, not left to the field default, so the number
            # the annotation specs were already truncated to is VISIBLE on the
            # generator an operator opens afterwards. The two must agree: the
            # specs are built before this record exists, so they cap against
            # the same constant.
            "image_label_count": DEFAULT_IMAGE_LABEL_COUNT,
        })

    def _fetch_media_b64(self, url):
        """Resolve a designer media URL to base64 bytes, best-effort.

        The bytes land on the question image record itself, the storage every
        consumer already handles: the token-scoped exam route streams it to
        the candidate (grading is text-only and sends no media).
        Returns ``(b64_or_False, warning_or_None)``.

        BEST-EFFORT MEANS THE LINK SURVIVES A FAILURE, never that junk is
        stored. Returning ``(False, warning)`` makes the caller keep
        ``image_url`` and surface the warning to the examiner, which is a
        working question with an external dependency. Storing the wrong bytes
        (a viewer page, a sign-in redirect) would be a BROKEN question that
        reports success.
        """
        import base64

        try:
            # Our OWN media store, under whatever `/api/vN` prefix this bundle
            # was built with - the client builds this path from `kApiPrefix`,
            # so pinning `/api/v1` here sent an `/api/v2` bundle's uploads down
            # the network branch below to be re-fetched over HTTP.
            local = re.match(r"^/api/v\d+/forms/media/(.+)$", url)
            if local:
                raw = self._fetch_s3_object(local.group(1))
                if raw:
                    return base64.b64encode(raw).decode("ascii"), None
            elif url.startswith("/web/content/"):
                att_id = int(url.split("/")[3].split("?")[0])
                att = self.env["ir.attachment"].sudo().browse(att_id)
                if att.exists() and att.datas:
                    return att.datas.decode("ascii") \
                        if isinstance(att.datas, bytes) else att.datas, None
            else:
                fetch_url = url
                relative = url.startswith("/")
                if relative:
                    # ODOO'S OWN ORIGIN, not the client's.
                    #
                    # This read `candidate_app_base_url` first - the FLUTTER
                    # CLIENT's host - and every relative path that reaches here
                    # is an Odoo route. The two shapes with their own branch
                    # above (`/api/vN/forms/media/...` off S3, `/web/content/...`
                    # off the attachment store) never get this far, so what is
                    # left is `/web/image/<id>`, `/assessments_be/...` and the
                    # like. Joined onto `https://assessment.ethara.ai` those hit
                    # the client's static bundle, whose nginx answers
                    # `try_files $uri $uri/ /index.html` (`nginx.conf:48` in the
                    # front-end repo) with 200 text/html, and the content-type
                    # gate below then refuses the media naming a host that never
                    # served it.
                    #
                    # Latent rather than live only because that parameter has
                    # never been set on a real deployment - which is exactly the
                    # kind of bug that fires the day an operator follows the
                    # documentation.
                    #
                    # This is also what makes the SSRF note below true as
                    # written: the origin joined on is now OURS.
                    icp = self.env["ir.config_parameter"].sudo()
                    origin = (icp.get_param("web.base.url") or "").rstrip("/")
                    fetch_url = origin + url
                # AN EXAMINER'S PASTED URL REACHES THIS `requests.get`, so an
                # absolute one is checked first. Without it a manager could name
                # `169.254.169.254` and have publish fetch the instance
                # metadata service - the same SSRF the media importer's
                # allow-list exists to prevent, on a route that had no guard at
                # all. Through the addon's own `net_guard`, which resolves the
                # host and refuses private, loopback, link-local and metadata
                # addresses, rather than a second home-grown check.
                #
                # ONLY THE ABSOLUTE CASE. A relative path is joined against OUR
                # configured origin, which the examiner does not control and
                # which is legitimately `localhost:8069` in local development -
                # guarding that would refuse our own media.
                if not relative and not net_guard.is_safe_url(fetch_url):
                    return False, (
                        "Media at %s is not a public web address, so it was "
                        "not copied. Upload the file instead." % url)
                resp = requests.get(fetch_url, timeout=20)
                if not resp.ok:
                    return False, (
                        "Media at %s answered %s - the question keeps a link "
                        "to it instead." % (url, resp.status_code))
                # THE CONTENT TYPE IS THE CHECK THAT MATTERS. A share page, a
                # sign-in redirect and a YouTube watch page all answer 200 with
                # HTML, so `resp.ok` alone let a web page be stored as a
                # question's image with no warning to anybody. Naming the type
                # we got is also what makes the warning actionable.
                ctype = (resp.headers.get("Content-Type") or "").split(";")[0] \
                    .strip().lower()
                if not (ctype.startswith("image/")
                        or ctype.startswith("video/")):
                    return False, (
                        "Media at %s is not an image or a video (it answered "
                        "%s), so it was not copied. If that is a share page, "
                        "copy the file into this app or upload it."
                        % (url, ctype or "no content type"))
                if len(resp.content) <= 100 * 1024 * 1024:
                    return base64.b64encode(resp.content).decode("ascii"), \
                        None
        except Exception as exc:  # noqa: BLE001 - publish must not 500 on media
            _logger.warning("form publish: media fetch failed for %s: %s",
                            url, exc)
        return False, ("Media at %s could not be copied - the question "
                       "keeps a link to it instead." % url)

    def _fetch_s3_object(self, key):
        """Read back an object `form_media_upload` stored, for publish.

        SAME STORAGE ORDER AS THE UPLOAD/PROXY ROUTES, and it has to stay that
        way: this reads back a key those routes just wrote, so a disagreement
        about WHERE means publish silently falls back to a link-only
        `image_url` for every question carrying media. That is exactly the bug
        06f0c663b fixed, from the other direction.

        Both sides now read this addon's own `assessments_be_v2.s3_*` settings
        - the ones the Settings screen, the settings API and `tools/s3_setup.py`
        actually write. Reading `etp_assessment_pro.s3_*` matched the upload
        only for as long as a deployment happened to carry the pro keys; on one
        configured through this addon's own UI, neither side worked.

        The connector lookup is membership-tested because `s3_connector` is not
        in this addon's `depends`: a bare `env["s3.connector"]` raises KeyError
        where that addon is absent, which killed publish before it reached S3.
        """
        # ONE resolved target, shared with the upload and the serve routes.
        # Resolving connector-vs-module settings here independently is exactly
        # how a read ended up looking in a different bucket from the write -
        # see `s3_service.storage_target`.
        from ..services import s3_service
        cli, bucket = s3_service.storage_target(self.env)
        if cli is None or not bucket:
            return None
        obj = cli.get_object(Bucket=bucket, Key=key)
        return obj["Body"].read(100 * 1024 * 1024 + 1)
