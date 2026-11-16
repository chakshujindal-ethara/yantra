# -*- coding: utf-8 -*-
"""Question Bank Import wizard (CSV, authoring-harness JSON, native bank export
JSON) + the shared CSV column spec.

Multi-dimension questions use INDEXED columns dim1_label/dim1_options/dim1_correct
... dimN_*; values within a cell split on ``|``. dimensions_json / images_json power
columns are accepted for lossless round-trips of an export.
"""
import base64
import csv
import io
import json
import logging

from odoo import models, fields, api
from odoo.exceptions import UserError

from ..constants import (
    QUESTION_TYPE_CODES, QUESTION_TYPE_SHORT_LABELS, AB_DIMENSION_NAMES,
    AB_CHOICES, takes_one_answer)
from ..services import bank_json_template
from .simple_import import upload_text

_logger = logging.getLogger(__name__)

MAX_DIMS = 4
MAX_IMAGES = 3

CORE_COLUMNS = [
    "title", "question_type", "prompt", "description",
    "category", "skills", "difficulty", "time_minutes",
    "options", "correct_answer",
]
SUBJECTIVE_COLUMNS = ["rubric_json", "official_reasoning"]


def dimension_columns(n=MAX_DIMS):
    cols = []
    for i in range(1, n + 1):
        cols += [f"dim{i}_label", f"dim{i}_options", f"dim{i}_correct"]
    return cols


def image_columns(n=MAX_IMAGES):
    cols = []
    for i in range(1, n + 1):
        cols += [f"img{i}_slot", f"img{i}_label", f"img{i}_url"]
    return cols


def import_columns():
    return (CORE_COLUMNS + dimension_columns() + SUBJECTIVE_COLUMNS
            + image_columns())


def _split(cell, sep="|"):
    if not cell:
        return []
    return [p.strip() for p in str(cell).split(sep) if p.strip()]


# ── JSON shape detection, shared by the wizard and `POST /bank/import` ──
#
# ONE RULE, TWO DOORS. The file lane and the API's `payload` lane both ask
# these predicates, so the same JSON produces the same records whichever door
# it comes through: only a native export goes straight into the live bank.


def _looks_harness_question(item):
    return isinstance(item, dict) and (
        "fields" in item or ("instruction" in item and "id" in item))


def harness_payload(data):
    """``data`` if it is an authoring-harness run, else None.

    The harness emits questions.json (a list of {id, instruction, fields,
    assets}) or output.json ({questions:[...], solutions:{...}}). Fingerprinted
    on those shapes so it routes to `import_bank_harness` - review DRAFTS - and
    not to the CSV or native round-trip paths.
    """
    if isinstance(data, list) and data and _looks_harness_question(data[0]):
        return data
    if isinstance(data, dict) and isinstance(data.get("questions"), list) \
            and not data.get("assessments_be_bank"):
        questions = data["questions"]
        if questions and _looks_harness_question(questions[0]):
            return data
    return sectioned_payload(data)


# A whole test written as one file, the shape other test tools export and
# hand-written files use: {title, sections: [{title, questions: [{type, prompt,
# options, answer}]}]}. Read as a harness run, so it lands as review DRAFTS
# through the harness importer that both lanes already route to.
_SECTIONED_TYPES = {
    "mcq": "mcq", "mcq_single": "mcq", "single_choice": "mcq",
    "msq": "msq", "mcq_multi": "msq", "mcq_multiple": "msq",
    "multi_choice": "msq",
}


def sectioned_payload(data):
    """``data`` as a harness run if it is a sectioned test file, else None.

    A choice question whose answer is not one of its options refuses the whole
    file, naming the section and question, as a bad CSV row does. A `code`
    question answered by choice (`answerMode: mcq`) is a choice question with
    its snippet under the prompt. Test settings (time limit, pass mark,
    instructions) have no place in the bank and are not read.
    """
    sections = data.get("sections") if isinstance(data, dict) else None
    if not (isinstance(sections, list) and sections and all(
            isinstance(s, dict) and isinstance(s.get("questions"), list)
            for s in sections)):
        return None
    questions = []
    for s_no, section in enumerate(sections, start=1):
        for q_no, q in enumerate(section["questions"], start=1):
            where = "%s, question %d" % (
                section.get("title") or "Section %d" % s_no, q_no)
            if not isinstance(q, dict) or not str(q.get("prompt") or "").strip():
                raise UserError("%s has no prompt." % where)
            raw = str(q.get("type") or "").strip().lower()
            if raw == "code" and (q.get("answerMode") or "mcq") == "mcq":
                raw = "mcq"
            qtype = _SECTIONED_TYPES.get(raw, raw)
            if qtype == "mcq" and q.get("allowMultiple"):
                qtype = "msq"
            # Refused, not passed on: the harness importer turns a type it
            # does not know into a rubric question and drops the options and
            # the key without a word.
            if qtype not in QUESTION_TYPE_CODES:
                raise UserError(
                    "%s: type %r is not one the bank can hold. Use mcq_single,"
                    " mcq_multiple, code with answerMode mcq, or one of: %s."
                    % (where, q.get("type"), ", ".join(sorted(
                        QUESTION_TYPE_CODES))))
            prompt = str(q["prompt"]).strip()
            if q.get("promptCode"):
                prompt += "\n\n" + str(q["promptCode"]).strip()
            fields_def = {"question_type": qtype}
            if q.get("difficulty"):
                fields_def["difficulty"] = q["difficulty"]
            if qtype in ("mcq", "msq"):
                options = [str(o) for o in q.get("options") or []]
                answer = q.get("answers") or q.get("answer")
                wanted = [str(a) for a in (
                    answer if isinstance(answer, list) else [answer])
                    if a is not None]
                known = {o.strip().casefold() for o in options}
                missing = [a for a in wanted
                           if a.strip().casefold() not in known]
                if not wanted or missing or (qtype == "mcq" and len(wanted) > 1):
                    raise UserError(
                        "%s: the answer must be %s of its options, got %s."
                        % (where, "one" if qtype == "mcq" else "some",
                           ", ".join(map(repr, missing or wanted)) or "none"))
                fields_def["options"] = options
                fields_def["correct_answer"] = (
                    wanted if qtype == "msq" else wanted[0])
            questions.append({"id": "s%dq%d" % (s_no, q_no),
                              "instruction": prompt, "fields": fields_def})
    if not questions:
        raise UserError("The file has sections but no questions in them.")
    return {"title": str(data.get("title") or "").strip() or None,
            "questions": questions}


#: What a JSON upload of no known shape is told. It used to fall through to the
#: CSV parser and read "CSV must have at least a 'title' or 'prompt' column".
UNKNOWN_JSON_MESSAGE = (
    "This JSON is not a question format the importer knows. It reads a "
    'sectioned test ({"sections": [{"title", "questions": [{"type", "prompt", '
    '"options", "answer"}]}]}) or the authoring-harness shape (a list of '
    '{"id", "instruction", "fields"}, or {"questions": [...]}), both as review '
    'drafts, or a native bank export (the object carrying "assessments_be_bank"'
    "), which restores into the bank. A CSV from Download Template also works.")


def native_payload(data):
    """``data`` if it is a native round-trip export, else None.

    The `assessments_be_bank` sentinel is what `question._export_native`
    writes and nothing else does, which is why this format - and only this
    format - restores straight into the bank.
    """
    if isinstance(data, dict) and data.get("assessments_be_bank") \
            and isinstance(data.get("questions"), list):
        return data
    return None


class EtpAssessmentBankImportWizard(models.TransientModel):
    _name = "assessments.be.bank.import.wizard"
    _description = "Import Question Bank (CSV / JSON) into review drafts"

    data_file = fields.Binary(string="File")
    data_filename = fields.Char(string="Filename")
    question_count = fields.Integer(
        string="Questions in File", readonly=True,
        help="Parsed row / item count - refreshes when you attach a file.")
    generator_name = fields.Char(
        string="Batch Name",
        help="Name for the import batch (a generator record). Defaults to the "
             "filename.")
    detected_format = fields.Selection(
        [("csv", "CSV"), ("harness", "Authoring harness JSON"),
         ("native", "Native bank export JSON")],
        string="Detected Format", readonly=True,
        help="Read from the attached file. CSV and harness JSON arrive as "
             "review drafts; a native bank export restores into the bank.")

    #: ONE download control, as the console's single "Download Template": the
    #: flavour is a choice beside it, so the templates read as reference files
    #: rather than as rival import buttons.
    template_format = fields.Selection(
        [("csv", "CSV"),
         ("harness", "JSON (harness)"),
         ("native", "JSON (native bank export)")],
        string="Template", default="csv", required=True)
    template_columns = fields.Char(
        compute="_compute_template_columns", string="Columns",
        help="The columns the CSV template carries, in order.")
    size_limits = fields.Char(compute="_compute_template_columns")

    @api.depends("template_format")
    def _compute_template_columns(self):
        cols = ", ".join(import_columns())
        limits = "Max %d MB  ·  up to %s rows" % (
            self._MAX_CSV_BYTES // (1024 * 1024),
            "{:,}".format(self._MAX_CSV_ROWS))
        for rec in self:
            rec.template_columns = cols if rec.template_format == "csv" else ""
            rec.size_limits = limits

    def action_download_selected_template(self):
        """The one Download Template control, dispatching on the chosen
        flavour. Both underlying methods are unchanged and still reachable, so
        nothing a caller or a test relied on has moved."""
        self.ensure_one()
        if self.template_format == "csv":
            return self.action_download_template()
        return self.with_context(
            json_flavor=self.template_format).action_download_json_template()

    @api.onchange("data_file", "data_filename")
    def _onchange_count(self):
        for rec in self:
            rec.question_count = 0
            rec.detected_format = False
            if not rec.data_file:
                continue
            try:
                # SNIFFED IN `run_import`'s ORDER - harness, native, then CSV -
                # so the label the operator reads is the lane the click will
                # actually take (a native export goes into the live bank).
                data = rec._parse_json()
                harness = harness_payload(data)
                native = native_payload(data)
                if harness is not None:
                    rec.detected_format = "harness"
                    items = (harness.get("questions")
                             if isinstance(harness, dict) else harness)
                    rec.question_count = len(items or [])
                elif native is not None:
                    rec.detected_format = "native"
                    rec.question_count = len(native.get("questions") or [])
                elif not isinstance(data, (dict, list)):
                    rec.detected_format = "csv"
                    rec.question_count = len(rec._parse_rows())
                # Else JSON of no known shape: no format, as `run_import`
                # refuses it.
                if not rec.generator_name and rec.data_filename:
                    rec.generator_name = "Import: %s" % rec.data_filename
            except Exception as exc:  # noqa: BLE001 - onchange must not crash
                _logger.debug("Import preview parse failed: %s", exc)
                rec.question_count = 0

    def _decode(self):
        self.ensure_one()
        try:
            return base64.b64decode(self.data_file)
        except Exception:
            raise UserError("Could not decode the uploaded file.")

    def _parse_rows(self):
        self.ensure_one()
        raw = self._decode()
        return self._parse_csv(raw)

    # L-9: bound the CSV import. Without a cap, a huge upload creates one draft
    # record per row in a single web request - a worker-pinning / DB-bloat vector
    # even though import is admin-only. 5000 rows covers any realistic bank; the
    # raw-byte guard rejects a multi-hundred-MB file before it is even decoded.
    _MAX_CSV_BYTES = 25 * 1024 * 1024
    _MAX_CSV_ROWS = 5000

    def _parse_csv(self, raw):
        if len(raw) > self._MAX_CSV_BYTES:
            raise UserError(
                "CSV too large (%d bytes; max %dMB)."
                % (len(raw), self._MAX_CSV_BYTES // (1024 * 1024)))
        text = upload_text(raw)
        reader = csv.DictReader(io.StringIO(text))
        if not reader.fieldnames:
            raise UserError("CSV has no header row.")
        headers = {(h or "").strip().lower() for h in reader.fieldnames}
        if "title" not in headers and "prompt" not in headers:
            raise UserError(
                "CSV must have at least a 'title' or 'prompt' column. "
                "Use Download Template for the expected columns.")
        out = []
        for n, row in enumerate(reader, start=2):
            if len(out) >= self._MAX_CSV_ROWS:
                raise UserError(
                    "CSV has too many rows (max %d). Split the file into "
                    "smaller batches." % self._MAX_CSV_ROWS)
            row = {(k or "").strip().lower(): (v or "").strip()
                   for k, v in row.items() if k}
            if not any(row.values()):
                continue
            try:
                out.append(self._row_to_vals(row))
            except Exception as exc:  # noqa: BLE001
                raise UserError(f"Row {n}: {exc}")
        if not out:
            raise UserError("No data rows found in the CSV.")
        return out

    _JUNK_DIM_LABELS = ("you read the image?", "read the image", "did you read")

    @staticmethod
    def _is_junk_dim(spec):
        """A gate dimension is junk when its label is filler or it has <=1 option."""
        label = (spec.get("label") or "").strip().lower()
        opts = [o for o in (spec.get("options") or []) if str(o).strip()]
        if any(j in label for j in EtpAssessmentBankImportWizard._JUNK_DIM_LABELS):
            return True
        if len(opts) <= 1:
            return True
        return False

    def _row_to_vals(self, row):
        qtype = (row.get("question_type") or "mcq").strip()
        valid = dict(self.env["assessments.be.prompt.question"]
                     ._fields["question_type"].selection)
        if qtype not in valid:
            raise UserError(
                f"unknown question_type '{qtype}'. "
                f"Allowed: {', '.join(valid)}")

        dims = self._collect_indexed_dims(row)
        single_options = _split(row.get("options"))
        if not dims and single_options:
            stem = (row.get("dimension_label")
                    or row.get("description")
                    or row.get("prompt")
                    or "Answer")
            dims = [{
                "label": stem[:200],
                "options": single_options,
                "correct": _split(row.get("correct_answer")),
            }]
        if row.get("dimensions_json"):
            try:
                dims = json.loads(row["dimensions_json"])
            except (ValueError, TypeError):
                raise UserError("dimensions_json is not valid JSON.")
        if dims:
            dims = [d for d in dims if not self._is_junk_dim(d)]
        # A key that names no option was imported as a draft with "No answer
        # key"; it refuses the file like an unknown question_type does.
        normalize = self.env["assessments.be.prompt.question"]._normalize_correct
        for d in dims or ():
            options = d.get("options") or []
            wanted = d.get("correct") or []
            wanted = wanted if isinstance(wanted, list) else [wanted]
            if options and len(normalize(wanted, options)) < len(wanted):
                raise UserError(
                    "correct answer '%s' is not one of the options (%s)."
                    % (", ".join(map(str, wanted)),
                       ", ".join(map(str, options))))
            if (options and len(normalize(wanted, options)) > 1
                    and takes_one_answer(qtype, d.get("kind"))):
                raise UserError(
                    "'%s' marks %d correct answers (%s), but the candidate "
                    "picks one there. Keep one (several need question_type "
                    "msq)."
                    % (d.get("label") or "the answer", len(wanted),
                       ", ".join(map(str, wanted))))

        raw_title = (row.get("title") or "").strip()
        raw_prompt = (row.get("prompt") or "").strip()
        category = (row.get("category") or "").strip()
        stem = ""
        if qtype in ("mcq", "msq") and dims:
            stem = (dims[0].get("label") or "").strip()

        _GENERIC_PROMPTS = ("choose the correct option",
                            "choose the correct answer",
                            "select the correct option", "")
        prompt = raw_prompt
        if qtype in ("mcq", "msq") and stem and \
                raw_prompt.lower() in _GENERIC_PROMPTS:
            prompt = stem

        type_label = QUESTION_TYPE_SHORT_LABELS.get(
            qtype, qtype.replace("_", " ").title())

        def _weak_title(t):
            if not t or t == category:
                return True
            if t in ("Multiple Choice Question", "Image comparison",
                     "Untitled Question"):
                return True
            base = prompt or raw_prompt
            if base and (t == base or base.startswith(t) or len(t) > 80):
                return True
            return False

        if _weak_title(raw_title):
            title = ("%s %s" % (category, type_label)).strip() \
                if category else type_label
        else:
            title = raw_title

        vals = {
            "name": title[:200],
            "question_prompt": prompt or title,
            "description": row.get("description") or False,
            "question_type": qtype,
        }
        diff = (row.get("difficulty") or "").lower()
        if diff in ("easy", "medium", "hard"):
            vals["difficulty"] = diff
        try:
            vals["time_minutes"] = int(float(row.get("time_minutes") or 0))
        except (TypeError, ValueError):
            vals["time_minutes"] = 0

        if dims:
            vals["dimensions_json"] = json.dumps(dims, ensure_ascii=False)

        if row.get("rubric_json"):
            rubric_raw = row["rubric_json"].strip()
            try:
                json.loads(rubric_raw)
                vals["rubric_json"] = rubric_raw
            except (ValueError, TypeError):
                vals["rubric_json"] = json.dumps(
                    [{"label": title[:80], "pass_condition": rubric_raw}],
                    ensure_ascii=False)
        if row.get("official_reasoning"):
            vals["official_reasoning"] = row["official_reasoning"]

        images = self._collect_indexed_images(row)
        if row.get("images_json"):
            try:
                images = json.loads(row["images_json"])
            except (ValueError, TypeError):
                raise UserError("images_json is not valid JSON.")
        if images:
            vals["images_json"] = json.dumps(images, ensure_ascii=False)
        return vals

    @staticmethod
    def _collect_indexed_dims(row):
        idxs = set()
        for k in row:
            if k.startswith("dim") and ("_label" in k or "_options" in k
                                        or "_correct" in k):
                num = k[3:].split("_", 1)[0]
                if num.isdigit():
                    idxs.add(int(num))
        dims = []
        for i in sorted(idxs):
            options = _split(row.get(f"dim{i}_options"))
            if not options and not row.get(f"dim{i}_label"):
                continue
            dims.append({
                "label": row.get(f"dim{i}_label") or f"Dimension {i}",
                "options": options,
                "correct": _split(row.get(f"dim{i}_correct")),
            })
        return dims

    @staticmethod
    def _collect_indexed_images(row):
        idxs = set()
        for k in row:
            if k.startswith("img") and ("_url" in k or "_slot" in k
                                        or "_label" in k):
                num = k[3:].split("_", 1)[0]
                if num.isdigit():
                    idxs.add(int(num))
        images = []
        for i in sorted(idxs):
            url = row.get(f"img{i}_url")
            if not url:
                continue
            images.append({
                "slot": row.get(f"img{i}_slot") or False,
                "label": row.get(f"img{i}_label") or False,
                "url": url,
            })
        return images

    def _try_harness_payload(self):
        """The parsed authoring-harness run if the upload is one, else None."""
        return harness_payload(self._parse_json())

    def _try_native_payload(self):
        """The parsed native round-trip export if the upload is one, else None
        (so the CSV path runs)."""
        return native_payload(self._parse_json())

    def _parse_json(self):
        """The upload decoded as JSON, or None if it is not JSON at all.

        Not parseable → the CSV path runs. Logged at debug so a corrupt
        native-export upload is diagnosable (otherwise the admin sees a
        confusing "no CSV rows" error instead).
        """
        try:
            return json.loads(self._decode().decode("utf-8-sig"))
        except Exception as exc:  # noqa: BLE001
            _logger.debug("JSON parse failed, trying the CSV path: %s", exc)
            return None

    def action_import(self):
        """The Odoo button. Runs the import, then renders its result.

        THE WORK LIVES IN `run_import`, and this is the only place that turns
        the outcome into an `ir.actions.*` dict, so the JSON API
        (`POST /api/v1/bank/import`) reuses this importer EXACTLY rather than
        keeping a second parser that drifts from the template.
        """
        result = self.run_import()
        warns = result.get("warnings") or []
        # CLOSE AND SAY SO, like the app's sheet: `next` closes the dialog and
        # the opener's `onClose` reloads the list, so what arrived shows.
        return {
            "type": "ir.actions.client",
            "tag": "display_notification",
            "params": {
                "title": "Question Bank Imported",
                "message": result.get("message") or "",
                "type": "warning" if warns else "success",
                "sticky": bool(warns),
                "next": {"type": "ir.actions.act_window_close"},
            },
        }

    def run_import(self):
        """Import the attached file and SAY WHAT HAPPENED, as a plain dict.

        Returns `{format, generator_id, questions_created, warnings, message}`.
        `generator_id` is None for the round-trip format, which writes into the
        bank rather than onto a generator.

        Three formats, sniffed in this order - authoring-harness JSON, native
        round-trip JSON, then CSV - because only the first two carry a
        fingerprint and CSV is what anything else must be.
        """
        self.ensure_one()
        if not self.data_file:
            raise UserError("Please attach a file first.")
        harness = self._try_harness_payload()
        if harness is not None:
            res = self.env["assessments.be.bank.import"].import_bank_harness(
                harness,
                generator_name=(self.generator_name
                                or (isinstance(harness, dict)
                                    and harness.get("title"))
                                or ("Harness: %s" % (self.data_filename
                                                     or "run"))))
            warns = res.get("warnings") or []
            msg = "Imported %s draft question(s) into %r. Review them in " \
                "Pending Approvals." % (res.get("questions_created", 0),
                                        res.get("generator_name"))
            if warns:
                msg += " %d note(s) - see logs for asset follow-ups." % len(warns)
                for w in warns[:20]:
                    _logger.info("harness import: %s", w)
            return {
                "format": "harness",
                "generator_id": res.get("generator_id"),
                "questions_created": res.get("questions_created", 0),
                "warnings": warns,
                "message": msg,
            }
        native = self._try_native_payload()
        if native is not None:
            # THE LIVE BANK ONLY ON THE BUTTON THAT SAYS SO. Both footer
            # buttons call `action_import`; only "Restore into the bank" asks
            # first and sends this flag. Without it a stale `detected_format`
            # showed "Import as drafts" over a native file and restored it
            # with no confirm. The API route sends it: there the shape decides.
            if not self.env.context.get("confirm_native_restore"):
                raise UserError(
                    "This file is a native bank export: its questions go "
                    "straight into the live bank, not into Pending Approvals. "
                    "Attach the file again and use Restore into the bank.")
            res = self.env["assessments.be.bank.import"].import_bank_native(
                native)
            # SURFACE THE SKIPS. `import_bank_native` drops an item whose
            # question_type is not in the Selection rather than restamping it,
            # which is the right call - but reporting only `questions_created`
            # turned that into the silent loss the guard exists to prevent: an
            # operator re-importing a bank exported before a type was retired
            # read "Rebuilt 3 question(s)" and never learned 2 were dropped.
            # Mirrors the harness branch above.
            warns = res.get("warnings") or []
            msg = "Rebuilt %s question(s) from the round-trip export." \
                % res.get("questions_created", 0)
            if warns:
                msg += (" %d item(s) were SKIPPED - see the log for the "
                        "reason on each." % len(warns))
                for w in warns[:20]:
                    _logger.info("native import: %s", w)
            return {
                "format": "native",
                # The round-trip format writes into the BANK, not onto a
                # generator, so there is no record to open afterwards.
                "generator_id": None,
                "questions_created": res.get("questions_created", 0),
                "warnings": warns,
                "message": msg,
            }
        # JSON OF NO KNOWN SHAPE IS NOT A CSV. Read as one, its first line
        # (`{`) is the header row, and the refusal named CSV columns.
        if isinstance(self._parse_json(), (dict, list)):
            raise UserError(UNKNOWN_JSON_MESSAGE)
        rows = self._parse_rows()

        Prompt = self.env["assessments.be.prompt"]
        Draft = self.env["assessments.be.prompt.question"]

        batch_name = (self.generator_name
                      or ("Import: %s" % (self.data_filename or "bank")))[:120]
        prompt = Prompt.create({
            "name": batch_name,
            "state": "done",
            "source_text": "Imported via CSV (%s rows)." % len(rows),
            "last_extract_summary": "Imported %s draft question(s)." % len(rows),
        })

        # DRAFTS, NOT THE BANK. Every row waits in Pending Approvals, like the
        # JSON harness import and the app's "Import as drafts".
        created = 0
        for vals in rows:
            vals.pop("_source_ref", None)
            vals["prompt_id"] = prompt.id
            Draft.create(vals)
            created += 1

        return {
            "format": "csv",
            "generator_id": prompt.id,
            "questions_created": created,
            "warnings": [],
            "message": "Imported %s draft question(s) from CSV into %r. "
                       "Review them in Pending Approvals."
                       % (created, batch_name),
        }

    def action_download_template(self):
        content = build_template_csv()
        att = self.env["ir.attachment"].create({
            "name": "question_bank_import_template.csv",
            "type": "binary",
            "datas": base64.b64encode(content.encode("utf-8")).decode(),
            "mimetype": "text/csv",
            "res_model": self._name,
        })
        return {
            "type": "ir.actions.act_url",
            "url": f"/web/content/{att.id}?download=true",
            "target": "self",
        }

    def action_download_json_template(self):
        """The JSON counterpart of `action_download_template`.

        The flavour comes from the button's own context (`json_flavor`), so both
        buttons share this one method and neither can hand out a file the other
        surface does not. The bytes are `services/bank_json_template`'s, which is
        ALSO what `GET /api/v1/bank/template/json` returns - the download and the
        route are the same code, so they cannot drift.
        """
        self.ensure_one()
        flavor = self.env.context.get("json_flavor") or "harness"
        if flavor not in bank_json_template.FLAVORS:
            raise UserError(
                "Unknown JSON template %r. Expected one of %s."
                % (flavor, ", ".join(bank_json_template.FLAVORS)))
        filename, content = bank_json_template.template_json(
            flavor, env=self.env)
        att = self.env["ir.attachment"].create({
            "name": filename,
            "type": "binary",
            "datas": base64.b64encode(content).decode(),
            "mimetype": "application/json",
            "res_model": self._name,
        })
        return {
            "type": "ir.actions.act_url",
            "url": f"/web/content/{att.id}?download=true",
            "target": "self",
        }


def build_template_csv():
    cols = import_columns()
    buf = io.StringIO()
    w = csv.DictWriter(buf, fieldnames=cols, extrasaction="ignore")
    w.writeheader()
    for row in _template_rows():
        w.writerow(row)
    return buf.getvalue()


def _template_rows():
    """One dummy row per question type, exercising every relevant column."""
    return [
        {
            "title": "Capital of France",
            "question_type": "mcq",
            "prompt": "Which city is the capital of France?",
            "description": "Single correct answer.",
            "category": "Geography",
            "skills": "World Capitals",
            "difficulty": "easy",
            "time_minutes": "1",
            "options": "Paris|London|Berlin|Madrid",
            "correct_answer": "Paris",
        },
        {
            "title": "Prime numbers",
            "question_type": "msq",
            "prompt": "Select ALL prime numbers below.",
            "description": "One or more correct.",
            "category": "Mathematics",
            "skills": "Number Theory",
            "difficulty": "medium",
            "time_minutes": "2",
            "options": "2|3|4|9",
            "correct_answer": "2|3",
        },
        {
            "title": "Screenshot QA - Spotify",
            "question_type": "mcq",
            "prompt": "Review the screenshot and answer each check.",
            "description": "Several objective dimensions on one question.",
            "category": "Image Labelling",
            "skills": "App Identification|Box Coverage",
            "difficulty": "medium",
            "time_minutes": "3",
            "dim1_label": "Do you know this Application?",
            "dim1_options": "Yes|No",
            "dim1_correct": "Yes",
            "dim2_label": "Application",
            "dim2_options": "Spotify|Deezer|SoundCloud|Tidal",
            "dim2_correct": "Spotify",
            "dim3_label": "Are all interactive elements boxed?",
            "dim3_options": "Yes|No",
            "dim3_correct": "Yes",
            "dim4_label": "Next step",
            "dim4_options": "Proceed to labeling|Skip the image",
            "dim4_correct": "Proceed to labeling",
        },
        {
            "title": "Explain idempotency",
            "question_type": "subjective_rubric",
            "prompt": "Explain what idempotency means for a REST API and why "
                      "it matters.",
            "description": "Free-text answer, LLM-graded against the prompt.",
            "category": "Engineering",
            "skills": "API Design",
            "difficulty": "hard",
            "time_minutes": "8",
        },
        {
            "title": "Incident postmortem quality",
            "question_type": "subjective_rubric",
            "prompt": "Write a postmortem for the outage described above.",
            "description": "Free-text answer graded against a rubric.",
            "category": "Engineering",
            "skills": "Incident Response",
            "difficulty": "hard",
            "time_minutes": "15",
            "rubric_json": json.dumps([{
                "label": "Postmortem",
                "checklist": ["States root cause", "Lists impact",
                              "Has action items with owners"],
                "constraints": ["No blame of individuals"],
                "pass_condition": "Covers root cause, impact, and at least "
                                  "two concrete action items.",
            }], ensure_ascii=False),
        },
        {
            "title": "Compare two generated images",
            "question_type": "image_ab",
            "prompt": "Compare Response A and Response B against the prompt "
                      "across each axis.",
            "description": "Pick A / B / Both Good / Both Bad per axis; "
                           "justify your overall choice.",
            "category": "Image Eval",
            "skills": "Image Comparison",
            "difficulty": "hard",
            "time_minutes": "5",
            "dim1_label": AB_DIMENSION_NAMES["IF"],
            "dim1_options": "|".join(AB_CHOICES),
            "dim1_correct": "Response B",
            "dim2_label": AB_DIMENSION_NAMES["VQ"],
            "dim2_options": "|".join(AB_CHOICES),
            "dim2_correct": "Response B",
            "dim3_label": AB_DIMENSION_NAMES["LAI"],
            "dim3_options": "|".join(AB_CHOICES),
            "dim3_correct": "Both Good",
            "dim4_label": AB_DIMENSION_NAMES["OC"],
            "dim4_options": "|".join(AB_CHOICES),
            "dim4_correct": "Response B",
            "official_reasoning": "Response B shows the steam, stacked carpets "
                                  "and crowd the prompt asks for and is sharper.",
            "img1_slot": "a",
            "img1_label": "Response A",
            "img1_url": "https://picsum.photos/seed/respA/512",
            "img2_slot": "b",
            "img2_label": "Response B",
            "img2_url": "https://picsum.photos/seed/respB/512",
        },
        {
            "title": "Write the prompt for this image",
            "question_type": "image_prompt",
            "prompt": "Study the reference image, then write the text-to-image "
                      "prompt that would reproduce it.",
            "description": "Free-text prompt graded against an ideal prompt for "
                           "the required subject, style, and composition.",
            "category": "Image Eval",
            "skills": "Prompt Writing",
            "difficulty": "medium",
            "time_minutes": "6",
            "rubric_json": json.dumps({
                "ideal_prompt": "A photorealistic red vintage bicycle leaning "
                                "against a weathered blue door in golden-hour "
                                "light, shallow depth of field.",
                "mandatory_elements": ["red vintage bicycle", "blue door",
                                       "golden-hour light"],
                "penalty_rules": ["Penalise vague or generic prompts"],
                "scoring_guide": "Full marks when the prompt names the subject, "
                                 "style, lighting, and composition specifically.",
            }, ensure_ascii=False),
            "img1_slot": "reference",
            "img1_label": "Reference",
            "img1_url": "https://picsum.photos/seed/refbike/512",
        },
        {
            "title": "Label the UI screenshot",
            "question_type": "image_label",
            "prompt": "Identify the app, confirm the boxes, then label what "
                      "each numbered box does.",
            "description": "Objective gate checks + a free-text labelling "
                           "answer graded against a textual key.",
            "category": "Image Eval",
            "skills": "App Identification|Labelling",
            "difficulty": "medium",
            "time_minutes": "6",
            "dim1_label": "Do you know this Application?",
            "dim1_options": "Yes|No",
            "dim1_correct": "Yes",
            "dim2_label": "Application",
            "dim2_options": "Spotify|Deezer|SoundCloud|Tidal",
            "dim2_correct": "Spotify",
            "rubric_json": json.dumps({
                "ideal_labels": "Box 1 = search; Box 2 = play/pause; Box 3 = "
                                "library.",
                "mandatory_elements": ["search", "play", "library"],
                "penalty_rules": ["No mention of unrelated controls"],
                "scoring_guide": "Each numbered box is judged on its own; the "
                                 "share of boxes that clear the bar decides "
                                 "the single labelling mark.",
            }, ensure_ascii=False),
            "img1_slot": "single",
            "img1_label": "Screenshot",
            "img1_url": "https://picsum.photos/seed/ui/512",
        },
    ]
