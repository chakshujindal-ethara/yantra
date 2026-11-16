"""CSV builders that return bytes, for exports served over the JSON API.

Upstream's `assessments_be_v2.services.export` builds an `ir.attachment` and
returns an Odoo download action. An API client needs the bytes instead. Rather
than restate how a row is shaped, everything here reuses upstream's column
lists and row builders: two implementations of an export would drift, and the
export is the artefact people file against an audit.
"""

from odoo.addons.assessments_be_v2.services.export import (
    RESPONSES_COLUMNS,
    RESULTS_COLUMNS,
    _response_row,
    _summary_row,
    _write_csv,
    results_rows,
)


def responses_csv(assessment, evaluator=None):
    """The responses CSV as ``(filename, bytes)``.

    Whole assessment, or one candidate's when ``evaluator`` is given.
    """
    assessment.ensure_one()
    if evaluator is not None:
        responses = evaluator.response_ids
        suffix = (evaluator.applicant_id.partner_name or "candidate").replace(
            " ", "_")
        fname = f"{assessment.name}_{suffix}_responses.csv"
    else:
        responses = assessment.response_ids
        fname = f"{assessment.name}_responses.csv"
    ordered = responses.sorted(
        key=lambda r: (
            r.evaluator_id.partner_name or "",
            r.question_id.sequence or 0,
            r.id))
    rows = []
    if evaluator is not None:
        rows.append(_summary_row(evaluator))
        rows.extend(_response_row(r) for r in ordered)
    else:
        # One summary row per candidate, ahead of that candidate's answers, so
        # the file reads as a report rather than a flat dump.
        seen = set()
        ev_by_applicant = {
            ev.applicant_id.id: ev
            for ev in assessment.assessment_evaluator_ids}
        for r in ordered:
            app_id = r.evaluator_id.id
            if app_id not in seen:
                seen.add(app_id)
                ev = ev_by_applicant.get(app_id)
                if ev:
                    rows.append(_summary_row(ev))
            rows.append(_response_row(r))
    return fname, _write_csv(RESPONSES_COLUMNS, rows)


def results_csv(assessment):
    """The results CSV as ``(filename, bytes)``. See :func:`responses_csv`."""
    assessment.ensure_one()
    return (
        f"{assessment.name}_results.csv",
        _write_csv(RESULTS_COLUMNS, results_rows(assessment)),
    )


#: The candidate import template. One definition, so the file the API hands out
#: cannot drift from the one the importer expects - a template that disagrees
#: with the importer is worse than no template.
CANDIDATE_TEMPLATE_COLUMNS = ["name", "email"]

#: The example rows.
#:
#: `example.com` ON PURPOSE, and it is not cosmetic. These addresses used to be
#: `john.doe@gmail.com` and `jane.smith@gmail.com`, which are DELIVERABLE - an
#: operator who filled in their roster underneath and imported the file whole
#: would send a real exam invitation to two strangers' inboxes, and would find
#: out when one of them replied. example.com is reserved by RFC 2606 precisely
#: so it can never receive mail, so the same mistake now costs two junk rows an
#: admin can unassign.
#:
#: The names say what to do with the row rather than impersonating a person,
#: for the same reason: a row reading "John Doe" looks like data, and a row
#: reading "Replace this row" does not.
#: NO COMMAS IN THE SAMPLE TEXT. The importer splits on ',' without quote
#: handling, so a name containing one is written by csv.writer as a QUOTED
#: field and read back as two cells - the template would have tripped the very
#: "1 row(s) skipped" warning it exists to prevent.
CANDIDATE_TEMPLATE_SAMPLE = [
    ["Replace this row with your first candidate", "first@example.com"],
    ["Add one row per candidate", "second@example.com"],
]

#: UTF-8 byte order mark.
#:
#: Excel decides a CSV's encoding by sniffing, and without this it opens a
#: UTF-8 file as the system codepage - so a roster containing "Zoë" or any
#: non-ASCII name renders as mojibake, gets "corrected" by whoever is editing,
#: and is imported wrong. With the BOM, Excel and Numbers both read it as UTF-8
#: on the first try.
#:
#: The importer strips this on the way back in - both this three-byte form and
#: a decoded U+FEFF - so a template that has been round-tripped through a
#: spreadsheet still parses. That round trip is exactly how a BOM reached the
#: importer in the first place: the file the operator uploads is rarely the
#: file this function produced, it is that file after Excel has saved it.
_UTF8_BOM = b"\xef\xbb\xbf"


def candidate_template_csv():
    """The candidate import template as ``(filename, bytes)``.

    Written to be opened in a spreadsheet, edited, saved and uploaded - which
    is what actually happens to it - rather than merely to be syntactically
    valid on the way out.
    """
    rows = [dict(zip(CANDIDATE_TEMPLATE_COLUMNS, r))
            for r in CANDIDATE_TEMPLATE_SAMPLE]
    return (
        "candidate_import_template.csv",
        _UTF8_BOM + _write_csv(CANDIDATE_TEMPLATE_COLUMNS, rows),
    )
