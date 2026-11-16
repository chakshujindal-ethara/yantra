# -*- coding: utf-8 -*-
"""CSV import for the two vocabularies the question importer does not cover:
TAGS and GENERATORS.

WHY THIS EXISTS. Questions had a real importer (`bank_import_wizard`) and these
two had Odoo's stock `base_import` - the generic list-view "Import records",
which maps arbitrary columns onto arbitrary fields. That is powerful and it is
not a contract: nothing outside Odoo can offer the same thing, so the Flutter
client had no import for either, and "the same file gives the same result in
both UIs" was not expressible. A named column spec is.

ONE PARSER, TWO SURFACES. The wizards below and the JSON API
(`POST /api/v1/tags/import`, `/api/v1/generators/import`) both call
`import_csv` here, so a file cannot behave differently depending on where it
was dropped. Stock `base_import` is untouched and remains available on the list
views for anyone who wants free-form field mapping.

UPSERT, NEVER DUPLICATE. Both entities are keyed on a name people re-type, and
an importer that appended would turn a corrected re-run into a second copy of
the vocabulary. A row that matches an existing record updates the columns it
names and leaves the rest alone.
"""
import base64
import codecs
import csv
import io
import logging

from odoo import models, fields, api
from odoo.exceptions import UserError

_logger = logging.getLogger(__name__)

# The same bounds the question importer uses, for the same reason: import is
# admin-only, but one request creating a record per row is still a
# worker-pinning vector, and the byte guard rejects an absurd upload before it
# is decoded.
MAX_CSV_BYTES = 25 * 1024 * 1024
MAX_CSV_ROWS = 5000

TAG_COLUMNS = ["name", "display", "prefix", "color"]
GENERATOR_COLUMNS = [
    "name", "sop_title", "sop_summary", "source_text",
    "sop_question_count", "image_label_count", "allowed_question_types",
]


def _decode(raw_b64):
    """Base64 in, bytes out. Accepts a `data:` prefix a browser FileReader adds.

    Takes str (the API's JSON body) or bytes (a wizard's Binary field).
    """
    text = raw_b64 or ""
    if isinstance(text, bytes):
        text = text.decode("ascii", "replace")
    text = text.strip()
    if text.startswith("data:"):
        text = text.split(",", 1)[-1]
    try:
        return base64.b64decode(text)
    except Exception:
        raise UserError("Could not decode the uploaded file.")


def upload_text(data, fallback="latin-1"):
    """Uploaded bytes - or text already extracted from them - as text a
    Postgres text column will store.

    Postgres refuses NUL in any text column, and the flush then 500s the whole
    request. The usual source is a Windows "Unicode" save: UTF-16 with a BOM,
    where read as UTF-8 every other byte is NUL. So a UTF-16 BOM is decoded as
    UTF-16, and any NUL left after decoding is dropped.

    ``fallback``: the codec for bytes that are not UTF-8 (with ``replace``);
    None re-raises the UnicodeDecodeError for a caller that refuses them.
    """
    if isinstance(data, bytes):
        if data[:2] in (codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE):
            data = data.decode("utf-16", errors="replace")
        else:
            try:
                data = data.decode("utf-8-sig")
            except UnicodeDecodeError:
                if not fallback:
                    raise
                data = data.decode(fallback, errors="replace")
    return data.replace("\x00", "")


def read_csv(raw, required_column):
    """Rows as lower-cased dicts, or a UserError naming what is wrong.

    `required_column` is the one column that makes the file recognisable. A
    header check up front is what turns "imported 0 rows" - which reads as an
    empty file - into "this is the wrong file".
    """
    if len(raw) > MAX_CSV_BYTES:
        raise UserError(
            "CSV too large (%d bytes; max %dMB)."
            % (len(raw), MAX_CSV_BYTES // (1024 * 1024)))
    # Not UTF-8: a file saved out of Excel on a Windows machine, read as
    # latin-1. Losing the import over one accented character would be absurd.
    text = upload_text(raw)
    reader = csv.DictReader(io.StringIO(text))
    if not reader.fieldnames:
        raise UserError("CSV has no header row.")
    headers = {(h or "").strip().lower() for h in reader.fieldnames}
    if required_column not in headers:
        raise UserError(
            "CSV must have a %r column. Use Download Template for the "
            "expected columns." % required_column)

    rows = []
    for n, row in enumerate(reader, start=2):
        if len(rows) >= MAX_CSV_ROWS:
            raise UserError(
                "CSV has too many rows (max %d). Split the file into smaller "
                "batches." % MAX_CSV_ROWS)
        clean = {(k or "").strip().lower(): (v or "").strip()
                 for k, v in row.items() if k}
        if not any(clean.values()):
            continue
        rows.append((n, clean))
    if not rows:
        raise UserError("No data rows found in the CSV.")
    return rows


def _split(cell, sep="|"):
    return [p.strip() for p in (cell or "").split(sep) if p.strip()]


def _as_int(value, default=0):
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return default


def build_template_csv(columns, rows):
    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=columns, extrasaction="ignore")
    writer.writeheader()
    for row in rows:
        writer.writerow(row)
    return buf.getvalue()


class AssessmentsBeSimpleImport(models.AbstractModel):
    _name = "assessments.be.simple.import"
    _description = "Tag and Generator CSV Importers"

    # ── Tags ─────────────────────────────────────────────────────────────

    @api.model
    def import_tags_csv(self, raw_b64):
        """Upsert tags from CSV. Returns `{created, updated, warnings, message}`.

        CANONICALISED THROUGH `_get_or_create`, not created directly. That is
        the same path the extraction LLM writes through, so an imported tag and
        an extracted one with the same meaning collapse onto one record instead
        of sitting beside each other as near-duplicates the ranker then treats
        as different concepts.
        """
        Tag = self.env["assessments.be.tag"].sudo()
        rows = read_csv(_decode(raw_b64), "name")

        created = updated = 0
        warnings = []
        for line, row in rows:
            name = row.get("name") or ""
            if not name:
                warnings.append("Row %d: no name, skipped." % line)
                continue
            canon = Tag._canonicalize(name)
            if not canon:
                warnings.append(
                    "Row %d: %r is not a usable tag key, skipped."
                    % (line, name))
                continue
            existing = Tag.search([("name", "=ilike", canon)], limit=1)
            Tag._get_or_create([{
                "key": canon,
                "display": row.get("display") or "",
            }])
            tag = Tag.search([("name", "=ilike", canon)], limit=1)
            if existing:
                updated += 1
            else:
                created += 1
            # Columns the canonical path does not set. Written only when the
            # row NAMES them, so a partial file cannot blank a field it never
            # mentioned.
            vals = {}
            if "prefix" in row and row["prefix"]:
                vals["prefix"] = row["prefix"]
            if "color" in row and row["color"]:
                vals["color"] = _as_int(row["color"])
            if "display" in row and row["display"]:
                vals["display"] = row["display"]
            if vals and tag:
                tag.write(vals)

        return {
            "created": created,
            "updated": updated,
            "warnings": warnings,
            "message": "Imported %d new tag(s), updated %d."
                       % (created, updated),
        }

    @api.model
    def tag_template_csv(self):
        return build_template_csv(TAG_COLUMNS, [
            {"name": "domain:ai-image-editing",
             "display": "AI Image Editing", "prefix": "domain", "color": "3"},
            {"name": "task:compare-two-images",
             "display": "Compare Two Images", "prefix": "task", "color": "5"},
        ])

    # ── Generators ───────────────────────────────────────────────────────

    @api.model
    def import_generators_csv(self, raw_b64):
        """Upsert generators from CSV. Returns `{created, updated, warnings,
        message, generator_ids}`.

        NO SOP DOCUMENT IS CREATED. A generator's SOP is a file, and a CSV cell
        cannot be one - `source_text` carries notes instead, which is the same
        thing `action_generate_from_sop` accepts when no document is attached.
        An imported generator is therefore ready to have its document uploaded,
        not ready to generate, and the message says so.
        """
        Prompt = self.env["assessments.be.prompt"].sudo()
        QType = self.env["assessments.be.question.type"].sudo()
        rows = read_csv(_decode(raw_b64), "name")

        created = updated = 0
        warnings = []
        touched = []
        for line, row in rows:
            name = (row.get("name") or "").strip()
            if not name:
                warnings.append("Row %d: no name, skipped." % line)
                continue

            vals = {}
            for column in ("sop_title", "sop_summary", "source_text"):
                if row.get(column):
                    vals[column] = row[column]
            if row.get("sop_question_count"):
                vals["sop_question_count"] = _as_int(row["sop_question_count"])
            if row.get("image_label_count"):
                count = _as_int(row["image_label_count"])
                # `_check_image_label_count` refuses anything under 1, and a
                # ValidationError mid-file would abort the whole import over
                # one typo. Naming the row and moving on is more use.
                if count < 1:
                    warnings.append(
                        "Row %d: image_label_count %r must be at least 1; "
                        "left at the default." % (line, row["image_label_count"]))
                else:
                    vals["image_label_count"] = count

            codes = _split(row.get("allowed_question_types"))
            if codes:
                types = QType.search([("code", "in", codes)])
                missing = sorted(set(codes) - set(types.mapped("code")))
                if missing:
                    warnings.append(
                        "Row %d: unknown question type(s) %s, ignored."
                        % (line, ", ".join(missing)))
                if types:
                    vals["allowed_question_type_ids"] = [(6, 0, types.ids)]

            existing = Prompt.search([("name", "=", name)], limit=1)
            if existing:
                existing.write(vals)
                touched.append(existing.id)
                updated += 1
            else:
                record = Prompt.create(dict(vals, name=name))
                touched.append(record.id)
                created += 1

        return {
            "created": created,
            "updated": updated,
            "generator_ids": touched,
            "warnings": warnings,
            "message": (
                "Imported %d new generator(s), updated %d. Attach an SOP "
                "document to each before generating." % (created, updated)),
        }

    @api.model
    def generator_template_csv(self):
        return build_template_csv(GENERATOR_COLUMNS, [{
            "name": "Image QC - Phase 1",
            "sop_title": "Phase 1 Video Quality Gate",
            "sop_summary": "Checks a clip against the Phase 1 gate.",
            "source_text": "Notes the model should read when no SOP file is "
                           "attached.",
            "sop_question_count": "10",
            "image_label_count": "12",
            "allowed_question_types": "mcq|msq|subjective_rubric",
        }])


class AssessmentsBeTagImportWizard(models.TransientModel):
    _name = "assessments.be.tag.import.wizard"
    _description = "Tag Vocabulary Import"

    data_file = fields.Binary(string="File")
    data_filename = fields.Char()

    def action_import(self):
        self.ensure_one()
        if not self.data_file:
            raise UserError("Please attach a file first.")
        result = self.env["assessments.be.simple.import"].import_tags_csv(
            self.data_file)
        return _notification("Tags Imported", result)

    def action_download_template(self):
        return _template_download(
            self.env, self._name, "tag_import_template.csv",
            self.env["assessments.be.simple.import"].tag_template_csv())


class AssessmentsBeGeneratorImportWizard(models.TransientModel):
    _name = "assessments.be.generator.import.wizard"
    _description = "Generator Import"

    data_file = fields.Binary(string="File")
    data_filename = fields.Char()

    def action_import(self):
        self.ensure_one()
        if not self.data_file:
            raise UserError("Please attach a file first.")
        result = self.env["assessments.be.simple.import"] \
            .import_generators_csv(self.data_file)
        return _notification("Generators Imported", result)

    def action_download_template(self):
        return _template_download(
            self.env, self._name, "generator_import_template.csv",
            self.env["assessments.be.simple.import"].generator_template_csv())


def _notification(title, result):
    """Report an import the way the question importer does.

    STICKY WHEN THERE ARE WARNINGS. A skipped row is the whole reason anyone
    reads this, and a toast that fades in four seconds is how "3 rows were
    ignored" turns into "why is that tag missing" a week later.
    """
    warnings = result.get("warnings") or []
    message = result.get("message") or ""
    if warnings:
        message += " %d row(s) need attention: %s" % (
            len(warnings), " | ".join(warnings[:5]))
        for warning in warnings:
            _logger.info("import: %s", warning)
    return {
        "type": "ir.actions.client",
        "tag": "display_notification",
        "params": {
            "title": title,
            "message": message,
            "type": "warning" if warnings else "success",
            "sticky": bool(warnings),
            # Close the dialog; the list that opened it reloads on close.
            "next": {"type": "ir.actions.act_window_close"},
        },
    }


def _template_download(env, res_model, filename, content):
    attachment = env["ir.attachment"].create({
        "name": filename,
        "type": "binary",
        "datas": base64.b64encode(content.encode("utf-8")).decode(),
        "mimetype": "text/csv",
        "res_model": res_model,
    })
    return {
        "type": "ir.actions.act_url",
        "url": "/web/content/%s?download=true" % attachment.id,
        "target": "self",
    }
