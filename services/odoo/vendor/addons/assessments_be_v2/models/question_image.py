# -*- coding: utf-8 -*-
import base64
import datetime
import json
import logging

from odoo import api, models, fields
from odoo.exceptions import UserError

from ..constants import ADVISORY_LOCK_IMAGE_DETECT, DEFAULT_IMAGE_LABEL_COUNT
from ..services.locks import cron_lock

_logger = logging.getLogger(__name__)

_DETECT_MAX_ATTEMPTS = 3


class EtpAssessmentQuestionImage(models.Model):
    _name = "assessments.be.question.image"
    # Bumps the question's version on any change, label boxes included (the
    # question cache key).
    _inherit = ["assessments.be.question.cache.touch"]
    # The detect cron's retry counter; the only such field on any child.
    _cache_quiet_fields = frozenset({"detection_attempts"})
    _description = "Assessment Question Image"
    _order = "sequence, id"

    question_id = fields.Many2one(
        "assessments.be.question",
        string="Question",
        required=True,
        ondelete="cascade",
        # Every media question served reads its plates by this column.
        index=True,
    )
    question_type = fields.Selection(
        related="question_id.question_type",
        store=True,
        help="Mirror of the parent question type; gates which Slot selector "
             "is shown in the Image Evaluation list.")
    label = fields.Char(
        string="Label", required=True,
        help="Shown to the candidate, e.g. 'Response A', 'Reference', 'Output'.")
    slot = fields.Selection(
        [
            ("a", "Response A"),
            ("b", "Response B"),
            ("single", "Single"),
            ("reference", "Reference"),
            ("output", "Output"),
        ],
        string="Slot",
        required=True,
        default="single",
        help="image_ab uses A + B; image_prompt and image_label use Single / "
             "Reference / Output.",
    )
    slot_ab = fields.Selection(
        [("a", "Response A"), ("b", "Response B")],
        string="Slot",
        compute="_compute_slot_helpers",
        inverse="_inverse_slot_ab",
        help="image_ab slot selector; synced to the canonical slot field.")
    slot_text = fields.Selection(
        [("single", "Single"), ("reference", "Reference"), ("output", "Output")],
        string="Slot",
        compute="_compute_slot_helpers",
        inverse="_inverse_slot_text",
        help="image_prompt/image_label slot selector; synced to the canonical "
             "slot field.")
    image = fields.Binary(string="Image", attachment=True)
    image_url = fields.Char(
        string="Image URL",
        help="Optional external/S3 URL. When set, the portal serves this "
             "instead of the stored binary.")
    annotated_image = fields.Binary(
        string="Annotated Image", attachment=True,
        help="image_label: the source image with numbered red boxes drawn over "
             "each detected element (candidate-facing overlay).")
    annotated_image_url = fields.Char(
        string="Annotated Image URL",
        help="Optional external/S3 URL for the annotated overlay, preferred "
             "over the stored binary when set (mirrors image / image_url).")
    detections_json = fields.Text(
        string="Detections (JSON)", copy=False,
        help="image_label answer key: the label_key produced by detection, a "
             'JSON list of {"number","label","description","box_px"} entries '
             "keyed to the numbered boxes on the annotated image.")
    detection_attempts = fields.Integer(
        default=0, copy=False,
        help="How many times the detection cron has tried this image, so a "
             "repeatedly-failing detection flips out of the queue instead of "
             "retrying forever.")
    source_url = fields.Char(
        string="Source URL", copy=False,
        help="image_label: a LIVE web page URL, set on approve only when the "
             "approved picture is that page's capture. The detect cron captures "
             "it (Playwright + Chromium installed, and the generator has "
             "'Screenshot live websites' on or there is no generator); a failed "
             "or unusable capture (error/bot page) falls back to Gemini "
             "detection.")
    dom_manifest_json = fields.Text(
        string="DOM Manifest (JSON)", copy=False,
        help="Per-box construction facts captured from the live DOM (tag, role, "
             "name, text, href, box_css, in_shadow, boxed_via_label) - the "
             "ground truth the behavioural key was drafted from.")
    behavioural_key_json = fields.Text(
        string="Behavioural Key (JSON)", copy=False,
        help="image_label answer key: a JSON list of "
             '{"number","element","functionality"} grading the ACTION each '
             "numbered element performs, not its nominal name. Drafted from the "
             "DOM on a live capture, else carried from the draft's one box list "
             "on approve.")
    capture_viewport = fields.Char(
        string="Capture Viewport", copy=False,
        help="Viewport + device scale factor and the UTC capture timestamp "
             "(e.g. '1440x900@2x 2026-07-13T10:20:30Z') for staleness.")
    capture_config_json = fields.Text(
        string="Capture Config (JSON)", copy=False,
        help='image_label DOM-capture directives {"viewport":{"width","height"},'
             '"wait_ms":int,"dismiss":["<accept selector>"]} threaded into the '
             "live capture so the settle delay and cookie/consent dismissal run "
             "before the DOM is enumerated.")
    omit_spec_json = fields.Text(
        string="Omit Spec (JSON)", copy=False,
        help="image_label: an optional capture directive "
             '{"match_tag","match_type","match_text"} that leaves ONE matching '
             "interactive element deliberately unboxed, so the coverage gate "
             'answer is "No" by construction. The omitted element is recorded in '
             "omitted_element_json.")
    coverage_expected = fields.Selection(
        [("yes", "Yes"), ("no", "No")],
        string="Coverage Expected", copy=False,
        help='The correct answer to "is every interactive element on the page '
             'boxed?": "no" when a DOM capture deliberately omitted an element '
             '(omit_spec_json), else "yes". Consumed by scoring as the coverage '
             "gate ground truth.")
    omitted_element_json = fields.Text(
        string="Omitted Element (JSON)", copy=False,
        help="Ground truth for a deliberately-omitted interactive element "
             "(tag/type/role/aria/text/href/box_css/reason) recorded at capture "
             'time so the coverage gate answer is provably "No".')
    label_application = fields.Char(
        string="Label Application", copy=False,
        help="image_label DENSE: the app/site the screenshot depicts. Graded as "
             "one identification checklist point in the behavioural rubric.")
    label_boxes_json = fields.Text(
        string="Label Boxes (JSON)", copy=False,
        help="image_label geometry of the ONE box list "
             '[{number, box_2d, label, description}] (0-1000 grid), carried from '
             "the draft on approve: where vision placed the generator's named "
             "boxes, or its own detections. When it covers every key number the "
             "app draws these on the plain picture (services/labelling."
             "label_overlay) and the baked picture is not served.")
    label_expected_count = fields.Integer(
        string="Expected Labels", default=0, copy=False,
        help="image_label: how many boxes a COMPLETE answer labels, when the "
             "task asks for 'any THREE of these five'. The denominator scoring "
             "divides by, and the candidate's best N boxes are the N that "
             "count - labelling a fourth box can never cost them a mark. 0 "
             "means derive it from the key, i.e. every box in it, which is "
             "what every question authored before this field existed does and "
             "keeps doing. Clamped at score time to the number of boxes that "
             "actually exist: a template asking for 5 of a 3-box key must not "
             "invent a denominator the candidate cannot reach.")
    sequence = fields.Integer(default=10)
    image_admin_url = fields.Char(compute="_compute_admin_urls")
    annotated_admin_url = fields.Char(compute="_compute_admin_urls")

    @api.depends("image", "image_url", "annotated_image", "annotated_image_url",
                 "write_date")
    def _compute_admin_urls(self):
        for rec in self:
            base = "/assessments_be/admin_qimage/%s" % rec.id if rec.id else False
            ver = int(rec.write_date.timestamp()) if rec.id and rec.write_date else 0
            rec.image_admin_url = (
                "%s?v=%s" % (base, ver)
                if base and (rec.image or rec.image_url) else False)
            rec.annotated_admin_url = (
                "%s?annotated=1&v=%s" % (base, ver)
                if base and (rec.annotated_image or rec.annotated_image_url)
                else False)

    @api.depends("slot")
    def _compute_slot_helpers(self):
        for rec in self:
            rec.slot_ab = rec.slot if rec.slot in ("a", "b") else False
            rec.slot_text = (
                rec.slot if rec.slot in ("single", "reference", "output")
                else False)

    def _inverse_slot_ab(self):
        for rec in self:
            if rec.slot_ab:
                rec.slot = rec.slot_ab

    def _inverse_slot_text(self):
        for rec in self:
            if rec.slot_text:
                rec.slot = rec.slot_text

    @api.onchange("question_type")
    def _onchange_question_type_slot_default(self):
        for rec in self:
            if rec.question_type == "image_ab" and rec.slot not in ("a", "b"):
                rec.slot = "a"
            elif (rec.question_type == "image_prompt"
                  and rec.slot not in ("single", "reference", "output")):
                rec.slot = "reference"
            elif (rec.question_type == "image_label"
                  and rec.slot not in ("single", "reference", "output")):
                rec.slot = "single"

    def _source_image_bytes(self):
        self.ensure_one()
        if self.image_url:
            from ..services import image_ingest
            b64, _ctype = image_ingest.download_bytes(self.env, self.image_url)
            if b64:
                return base64.b64decode(b64)
        if self.image:
            data = self.image
            if isinstance(data, str):
                data = data.encode("ascii", errors="ignore")
            try:
                return base64.b64decode(data)
            except (ValueError, TypeError):
                return b""
        return b""

    def _store_capture(self, result, viewport=(1600, 1000), dsf=2):
        # detections_json must be written here: a non-empty value is the cron's
        # skip guard for this image.
        self.ensure_one()
        from ..services import image_ingest, dom_capture
        screenshot_b64 = base64.b64encode(result["screenshot_png"]).decode()
        annotated_b64 = base64.b64encode(result["annotated_png"]).decode()
        url, stored_b64 = image_ingest.ingest(
            self.env, None, "data:image/png;base64,%s" % annotated_b64,
            key_hint="domannot-%s" % self.id)
        vals = {
            "image": screenshot_b64,
            "dom_manifest_json": json.dumps(
                result.get("dom_manifest") or [], ensure_ascii=False),
            "behavioural_key_json": json.dumps(
                result.get("behavioural_key") or [], ensure_ascii=False),
            "detections_json": json.dumps(
                result.get("label_key") or [], ensure_ascii=False),
            "capture_viewport": dom_capture.viewport_stamp(viewport, dsf),
            "annotated_image": stored_b64 or annotated_b64,
            "coverage_expected": result.get("coverage_expected") or "yes",
            "omitted_element_json": json.dumps(
                result.get("omitted_element"), ensure_ascii=False)
            if result.get("omitted_element") else False,
        }
        if url:
            vals["annotated_image_url"] = url
        self.write(vals)

    def _omit_spec(self):
        self.ensure_one()
        raw = (self.omit_spec_json or "").strip()
        if not raw:
            return None
        try:
            spec = json.loads(raw)
        except (ValueError, TypeError):
            return None
        return spec if isinstance(spec, dict) and spec else None

    def _capture_config(self):
        self.ensure_one()
        raw = (self.capture_config_json or "").strip()
        if not raw:
            return {}
        try:
            cfg = json.loads(raw)
        except (ValueError, TypeError):
            return {}
        return cfg if isinstance(cfg, dict) else {}

    # ── The storage-boundary backstop ────────────────────────────────────
    #
    # EVERY cap in this module is applied at an individual call site: the
    # generation lane truncates, both detection lanes truncate, the approve-time
    # key application truncates. That is nine separate places that each have to
    # remember, and it is exactly why Form Studio's publish path went uncapped
    # for as long as it did - it was simply a writer that never opted in, and
    # nothing at the storage layer noticed.
    #
    # This is the invariant, enforced once, wherever the write comes from.
    #
    # WHY IT TRUNCATES RATHER THAN RAISES. A ValidationError here would fire on
    # any future write that merely TOUCHES an over-cap row written before this
    # guard existed - an unrelated field update, a cron pass, an admin opening
    # and saving the form - turning a historical data problem into a live
    # failure on an unrelated action. Truncating keeps the stored data correct
    # no matter who wrote it, and the warning names the caller so the real bug
    # is still visible rather than silently absorbed.
    #
    # THE THREE FIELDS ARE CUT TOGETHER, always. They are parallel views of one
    # box set, so trimming them independently is how a key listing 20 entries
    # ends up sitting beside 10 drawn boxes - which grades a candidate against
    # boxes they were never shown.
    _LABEL_BOX_FIELDS = ("detections_json", "label_boxes_json",
                         "behavioural_key_json")

    def _cap_label_box_fields(self, vals):
        """Trim any over-cap box list in `vals` to this image's ceiling."""
        self.ensure_one()
        if not any(f in vals for f in self._LABEL_BOX_FIELDS):
            return vals
        limit = self._label_box_cap()
        out = dict(vals)
        for fname in self._LABEL_BOX_FIELDS:
            raw = out.get(fname)
            if not raw or not isinstance(raw, str):
                continue
            try:
                parsed = json.loads(raw)
            except (ValueError, TypeError):
                continue
            if not isinstance(parsed, list) or len(parsed) <= limit:
                continue
            _logger.warning(
                "label box cap: %s on image %s carried %d entries, capped to "
                "%d. The lane that wrote this did not apply the cap itself.",
                fname, self.id or "(new)", len(parsed), limit)
            out[fname] = json.dumps(parsed[:limit], ensure_ascii=False)
        return out

    @api.model_create_multi
    def create(self, vals_list):
        """Cap AFTER the insert, not before it.

        The ceiling is resolved from `question_id.generator_id`, and on an
        unsaved record there is nothing to resolve it from - the cap helper
        needs a real row. So the record is created, then trimmed if it came in
        over. Form Studio's publish is exactly this shape: it hands
        `detections_json` straight to `create`, so a guard that only covered
        `write` would have missed the very lane this exists for.
        """
        records = super().create(vals_list)
        for rec in records:
            current = {f: rec[f] for f in rec._LABEL_BOX_FIELDS if rec[f]}
            if not current:
                continue
            capped = rec._cap_label_box_fields(current)
            changed = {k: v for k, v in capped.items() if v != current.get(k)}
            if changed:
                super(EtpAssessmentQuestionImage, rec).write(changed)
        return records

    def write(self, vals):
        if any(f in vals for f in self._LABEL_BOX_FIELDS):
            for rec in self:
                super(EtpAssessmentQuestionImage, rec).write(
                    rec._cap_label_box_fields(vals))
            return True
        return super().write(vals)

    def _label_box_cap(self):
        """How many numbered boxes this image may carry.

        The generator that authored the question is the authority and is checked
        FIRST, so an admin who lowers Image Labelling Count and re-detects gets
        the new ceiling on an old question. Only when there is no generator
        behind this image - a hand-authored bank question, a spreadsheet import,
        a Form Studio build, an image whose generator was deleted
        (`generator_id` is ondelete="set null") - do we fall back to the value
        frozen into the capture plan at generation time, and then to the module
        default. Never zero: a labelling question with no boxes is unanswerable.
        """
        self.ensure_one()
        gen = self.question_id.generator_id
        candidates = [gen.image_label_count if gen else 0,
                      self._capture_config().get("max_boxes")]
        for raw in candidates:
            try:
                n = int(raw)
            except (TypeError, ValueError):
                continue
            if n >= 1:
                return n
        return DEFAULT_IMAGE_LABEL_COUNT

    def _capture_kwargs(self):
        self.ensure_one()
        kwargs: dict = {"omit": self._omit_spec(),
                        "max_boxes": self._label_box_cap()}
        cfg = self._capture_config()
        vp = cfg.get("viewport")
        if isinstance(vp, dict):
            try:
                w, h = int(vp.get("width") or 0), int(vp.get("height") or 0)
            except (TypeError, ValueError):
                w = h = 0
            if w > 0 and h > 0:
                kwargs["viewport"] = (w, h)
        if isinstance(cfg.get("dismiss"), list):
            sels = [str(s) for s in cfg["dismiss"] if str(s).strip()]
            if sels:
                kwargs["dismiss"] = sels
        if cfg.get("wait_ms") is not None:
            try:
                kwargs["wait_ms"] = int(cfg["wait_ms"])
            except (TypeError, ValueError):
                pass
        return kwargs

    def _detect_and_annotate(self, ui=False):
        self.ensure_one()
        from ..services import dom_capture
        generator = self.question_id.generator_id
        # A live page only where the project asked for one (owner, 2026-09-29);
        # "Capture URL" stays the explicit way to take one by hand.
        live = not generator or generator.image_label_live_capture
        if self.source_url and live and dom_capture.PLAYWRIGHT_AVAILABLE:
            kwargs = self._capture_kwargs()
            try:
                result = dom_capture.capture_and_annotate(
                    self.source_url, **kwargs)
            except Exception:  # noqa: BLE001
                _logger.exception(
                    "DOM capture failed for image %s; falling back to the "
                    "synthetic render+detect path", self.id)
            else:
                unusable = dom_capture.unusable_reason(
                    result, cap=kwargs.get("max_boxes"))
                if not unusable:
                    self._store_capture(
                        result, viewport=kwargs.get("viewport", (1600, 1000)))
                    return True
                _logger.warning(
                    "DOM capture for image %s was unusable (%s); falling back "
                    "to the synthetic render+detect path", self.id, unusable)
        # DETECT-AFTER-RENDER (matches research renderers/ui.py 1:1). We do NOT
        # draw the generator's guessed `boxes` (the old _annotate_from_dense_map
        # short-circuit): those coordinates are authored by the TEXT model before
        # the screenshot exists, so they never align with what the IMAGE model
        # actually rendered - the cause of "labels at the wrong positions". The
        # only trustworthy boxes are (a) real DOM rects from a live page (handled
        # above) or (b) vision-detected controls in the ACTUAL rendered pixels
        # (below). One detection call per image is the correct cost/accuracy
        # trade - wrong boxes are worse than a saved quota call on an assessment.
        return self._annotate_from_bytes(
            self._source_image_bytes(), ui=ui, cap=self._label_box_cap())

    def _dense_detections(self):
        """Must stay in sync with prompt._dense_preview_dets, cap included: the
        draft preview a reviewer approved and the fallback a candidate is shown
        have to be the same picture."""
        self.ensure_one()
        raw = (self.label_boxes_json or "").strip()
        if not raw:
            return []
        try:
            geometry = json.loads(raw)
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
                    # Carried for the same reason as
                    # `prompt._dense_preview_dets`, which this must stay in sync
                    # with: the filter above drops unrenderable entries, so the
                    # surviving list is sparse and renumbering it by draw
                    # position would disagree with the stored key.
                    "number": g.get("number"),
                    "box_2d": list(g["box_2d"]),
                    "label": str(g.get("label") or "").strip(),
                    "description": str(g.get("description") or "").strip(),
                })
        return dets

    def _redraw_label_overlay(self):
        """Re-burn the numbered overlay from the geometry stored RIGHT NOW.

        THE BURNED-IN PICTURE MUST MATCH THE KEY WHEREVER IT IS SERVED:
        candidates see it when the question's one overlay is "baked"
        (`services/labelling.label_overlay`), admins on the bank. So an
        authoring edit that moved a box and updated
        only `detections_json` would leave the numeral painted in the OLD place
        while the key names the new one - "labels at the wrong positions", this
        time introduced by the examiner fixing them.

        VERTEX-FREE: the geometry is already stored, so this only draws. It costs no detection call, which is what
        makes it safe to run on every save.

        THE STORED NUMBERS ARE PASSED IN, AND THE STORED KEY IS NOT REWRITTEN.
        Both halves matter, and the first was missing at first:

          * `imaging.annotate_from_pixels` numbers 1..N BY POSITION unless the
            item carries its own `number`. That is correct for a detection lane,
            where the draw IS what assigns the numbers - but a stored key can be
            SPARSE (delete marker 2 and 1, 3, 5 remain, because marker numbers
            are stable for the question's life so a submitted answer can never
            point at a renumbered marker). Verified by experiment: without the
            number carried through, markers 1/3/5 were painted 1/2/3, so every
            candidate read a badge that meant a different region than the key
            they were graded against.

          * The returned key is DISCARDED. It carries `box_px` - pixels, which
            no client can draw with - so writing it back over `detections_json`
            would replace drawable `box_2d` geometry with something the exam
            cannot render. The stored detections stay authoritative; only the
            bitmap is replaced.
        """
        self.ensure_one()
        dets = []
        try:
            stored = json.loads(self.detections_json or "[]")
        except (ValueError, TypeError):
            stored = []
        for d in stored if isinstance(stored, list) else []:
            box = d.get("box_2d") if isinstance(d, dict) else None
            if isinstance(box, (list, tuple)) and len(box) == 4:
                dets.append({"number": d.get("number"),
                             "box_2d": list(box),
                             "label": str(d.get("label") or "").strip(),
                             "description": str(
                                 d.get("description") or "").strip()})
        if not dets:
            # Nothing drawable. The markers are baked into the source picture
            # (the count-only shape), so leaving the existing plate alone is
            # correct - clearing it would take the candidate's only view of
            # where the points are with it.
            return False
        raw = self._source_image_bytes()
        if not raw:
            return False
        from ..services import imaging, image_ingest
        try:
            annotated_png, _key = imaging.annotate_image(raw, dets)
        except Exception:  # noqa: BLE001 - a redraw must never fail the save
            _logger.exception(
                "label overlay redraw failed for image %s", self.id)
            return False
        annotated_b64 = base64.b64encode(annotated_png).decode()
        url, stored_b64 = image_ingest.ingest(
            self.env, None, "data:image/png;base64,%s" % annotated_b64,
            key_hint="labeledit-%s" % self.id)
        vals = {"annotated_image": stored_b64 or annotated_b64}
        # A stale URL beside fresh inline bytes is the same wrong-picture bug:
        # `annotated_admin_url` and the exam route both prefer whichever is
        # set, so the old object key has to go when no new one was stored.
        vals["annotated_image_url"] = url or False
        self.write(vals)
        return True

    def _annotate_from_dense_map(self):
        """Must stay Vertex-free: this fallback draws boxes from the stored map
        only, and runs ahead of detect to avoid burning image quota."""
        self.ensure_one()
        dets = self._dense_detections()
        if not dets:
            return False
        raw = self._source_image_bytes()
        if not raw:
            return False
        from ..services import imaging, image_ingest
        annotated_png, label_key = imaging.annotate_image(raw, dets)
        annotated_b64 = base64.b64encode(annotated_png).decode()
        url, stored_b64 = image_ingest.ingest(
            self.env, None, "data:image/png;base64,%s" % annotated_b64,
            key_hint="labeldense-%s" % self.id)
        vals = {
            "detections_json": json.dumps(label_key, ensure_ascii=False),
            "annotated_image": stored_b64 or annotated_b64,
        }
        if url:
            vals["annotated_image_url"] = url
        self.write(vals)
        return True

    @api.model
    def _annotate_bytes_core(self, raw, ui=False, usage_ctx=None,
                             key_hint="annot", cap=None):
        """Writes no record. One caller, `_annotate_from_bytes` (detect cron,
        Detect now, inline detect at approve); the draft render path places
        its own boxes (`prompt._place_label_boxes`).

        `cap` is passed IN rather than resolved here: this is an @api.model
        method, so the caller resolves the cap from its own generator."""
        if not raw:
            return None
        from ..services import vertex, imaging, image_ingest
        image_b64 = base64.b64encode(raw).decode()
        detections = vertex.detect_image_elements(
            self.env, image_b64, ui=ui, usage_ctx=usage_ctx, cap=cap)
        annotated_png, label_key = imaging.annotate_image(raw, detections)
        annotated_b64 = base64.b64encode(annotated_png).decode()
        url, stored_b64 = image_ingest.ingest(
            self.env, None, "data:image/png;base64,%s" % annotated_b64,
            key_hint=key_hint)
        return {
            "detections_json": json.dumps(label_key, ensure_ascii=False),
            "annotated_b64": annotated_b64,
            "stored_b64": stored_b64 or "",
            "annotated_url": url or "",
        }

    def _annotate_from_bytes(self, raw, ui=False, cap=None):
        self.ensure_one()
        core = self._annotate_bytes_core(
            raw, ui=ui,
            usage_ctx={"prompt_id": self.question_id.generator_id.id or False,
                       "note": (self.question_id.name or "")[:80]},
            key_hint="annot-%s" % self.id,
            cap=cap if cap is not None else self._label_box_cap())
        if not core:
            return False
        vals = {"detections_json": core["detections_json"]}
        if core["annotated_url"]:
            vals["annotated_image_url"] = core["annotated_url"]
        if core["stored_b64"]:
            vals["annotated_image"] = core["stored_b64"]
        self.write(vals)
        return True

    def _detect_inline(self, raw, ui=False, cap=None):
        """Takes bytes because a storage re-read fails on a DB copied without its
        filestore. Must swallow errors inside a savepoint (never fail the render)
        and must not touch detection_attempts: the cron retry budget stays intact.
        """
        self.ensure_one()
        if not raw:
            return False
        try:
            with self.env.cr.savepoint():
                return self._annotate_from_bytes(raw, ui=ui, cap=cap)
        except Exception:  # noqa: BLE001
            _logger.exception(
                "Inline detect failed for question image %s; leaving it for the "
                "detect cron to retry from storage", self.id)
            return False

    def _detection_ui(self):
        self.ensure_one()
        return self.question_id.detection_mode == "ui"

    def action_detect_now(self):
        self.ensure_one()
        if self.question_type != "image_label" or self.slot != "single":
            raise UserError(
                "Detection only applies to an Image - Annotation Single image.")
        if not (self.image or self.image_url):
            raise UserError("Upload a source image before detecting.")
        if self.detection_attempts >= _DETECT_MAX_ATTEMPTS:
            raise UserError(
                "This image has already failed detection %d times; fix the "
                "source image, then clear its attempts to retry."
                % _DETECT_MAX_ATTEMPTS)
        try:
            ok = self._detect_and_annotate(ui=self._detection_ui())
        except Exception as exc:  # noqa: BLE001
            _logger.exception("On-demand detect failed for image %s", self.id)
            self.detection_attempts += 1
            raise UserError("Detection failed: %s" % exc) from exc
        if not ok:
            self.detection_attempts += 1
            raise UserError("No source image to detect.")
        return True

    def action_capture_url(self):
        self.ensure_one()
        from ..services import dom_capture
        if not self.source_url:
            raise UserError(
                "Set a Source URL before capturing the live DOM.")
        if not dom_capture.PLAYWRIGHT_AVAILABLE:
            raise UserError(
                "Install playwright + chromium: "
                "pip install playwright && playwright install chromium")
        kwargs = self._capture_kwargs()
        try:
            result = dom_capture.capture_and_annotate(self.source_url, **kwargs)
        except Exception as exc:  # noqa: BLE001
            _logger.exception("URL capture failed for image %s", self.id)
            raise UserError("URL capture failed: %s" % exc) from exc
        self._store_capture(
            result, viewport=kwargs.get("viewport", (1600, 1000)))
        return True

    @api.model
    def _cron_detect_image_labels(self):
        # The lock must stay SESSION-level (`cron_lock`): a txn-level lock
        # would be released by the per-row commits below and let a second
        # worker double-detect.
        domain = [
            ("question_type", "=", "image_label"),
            ("slot", "=", "single"),
            ("detections_json", "in", (False, "")),
            ("detection_attempts", "<", _DETECT_MAX_ATTEMPTS),
            "|", "|", ("image", "!=", False), ("image_url", "!=", False),
            ("source_url", "!=", False),
        ]
        with cron_lock(self.env.cr, ADVISORY_LOCK_IMAGE_DETECT,
                       name="image_detect",
                       queued=lambda: self.search_count(domain)) as got:
            if not got:
                return
            images = self.search(domain, limit=2)
            if not images:
                return
            _logger.info(
                "etp_assessment detect cron: %d image_label image(s) to detect",
                len(images))
            # Imported here, not at the top: `prompt` loads after this module.
            from .prompt import _TRANSIENT_DB_ERRORS, _warn_lost_race
            done = 0
            for image in images:
                try:
                    with self.env.cr.savepoint():
                        found = image._detect_and_annotate(
                            ui=image._detection_ui())
                        if not found:
                            image.detection_attempts += 1
                    got.renew()
                    self.env.cr.commit()
                    # Counted only once committed, where a lost race surfaces.
                    if found:
                        done += 1
                except _TRANSIENT_DB_ERRORS as exc:
                    # The DB asking to try again, not a failed detection: no
                    # attempt burned, the next tick retries it.
                    self.env.cr.rollback()
                    _warn_lost_race(image, "Auto-detect for question image",
                                    exc)
                    continue
                except Exception:  # noqa: BLE001
                    self.env.cr.rollback()
                    _logger.exception(
                        "Auto-detect failed for question image %s", image.id)
                    image.detection_attempts += 1
                    got.renew()
                    self.env.cr.commit()
                    continue
            _logger.info(
                "etp_assessment detect cron: annotated %d/%d image(s)",
                done, len(images))
