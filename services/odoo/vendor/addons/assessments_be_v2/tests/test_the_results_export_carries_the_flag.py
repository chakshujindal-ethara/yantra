# -*- coding: utf-8 -*-
"""D1 - the results CSV carries the operator's flag and remark.

The export is the surface a reviewer actually works from: results get pulled
into a spreadsheet, sorted, and mailed round, and a flag that lives only in the
console is a flag nobody sees at the moment a decision is made.

Two properties, and both are about the shape of the column rather than whether
it exists. `Flag` is "yes" OR EMPTY, never "no" - a column of two hundred "no"s
buries the four rows that matter, and empty sorts and filters to the bottom in
every spreadsheet. And the remark is exported whether or not the flag beside it
is raised, because a note without an accusation is a legitimate state and
dropping it would lose exactly the rows nobody re-reads.
"""
import csv
import io
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..services import export


@tagged("-at_install", "post_install")
class TestTheResultsExportCarriesTheFlag(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Generator = self.env["assessments.be.prompt"]
        self.Applicant = self.env["hr.applicant"]

    def _assessment(self):
        gen = self.Generator.create({"name": "Gen %s" % uuid4().hex[:6]})
        return self.Assessment.create({
            "name": "A %s" % uuid4().hex[:6],
            "generator_id": gen.id,
        })

    def _sit(self, assessment, name):
        slug = "%s_%s" % (name.lower().replace(" ", "_"), uuid4().hex[:8])
        applicant = self.Applicant.create({
            "partner_name": name,
            "email_from": "%s@example.com" % slug,
        })
        return self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        })

    def _rows_by_candidate(self, assessment):
        return {r["candidate"]: r for r in export.results_rows(assessment)}

    def test_the_columns_exist_and_are_last(self):
        """APPENDED, not inserted. Somebody's spreadsheet is already keyed to
        the existing column order, and inserting into the middle silently
        shifts every mapping they built. The time-analysis and roster columns
        were appended after these two, so they are pinned by POSITION (the 22nd
        and 23rd columns) rather than as the tail
        (`test_a_result_carries_its_time_and_pace` pins the later blocks)."""
        self.assertEqual(
            export.RESULTS_COLUMNS[21:23], ["Flagged", "Flag Remarks"])

    def test_a_flagged_row_says_yes_and_carries_the_remark(self):
        a = self._assessment()
        flagged = self._sit(a, "Flagged One")
        self._sit(a, "Clean One")
        flagged.write({
            "manual_flagged": True,
            "manual_remark": "Webcam showed a second person at 14:03."})

        rows = self._rows_by_candidate(a)
        self.assertEqual(rows["Flagged One"]["Flagged"], "yes")
        self.assertEqual(
            rows["Flagged One"]["Flag Remarks"],
            "Webcam showed a second person at 14:03.")

    def test_an_unflagged_row_is_EMPTY_not_no(self):
        a = self._assessment()
        self._sit(a, "Clean One")

        rows = self._rows_by_candidate(a)
        self.assertEqual(
            rows["Clean One"]["Flagged"], "",
            'an unflagged sitting exports an empty cell, not "no" - the flag '
            "is a rare exception and a full column of negatives hides it")
        self.assertEqual(rows["Clean One"]["Flag Remarks"], "")

    def test_a_remark_with_no_flag_is_still_exported(self):
        a = self._assessment()
        noted = self._sit(a, "Noted Only")
        noted.write({"manual_remark": "Reported a browser crash at 11:20."})

        rows = self._rows_by_candidate(a)
        self.assertEqual(rows["Noted Only"]["Flagged"], "")
        self.assertEqual(
            rows["Noted Only"]["Flag Remarks"],
            "Reported a browser crash at 11:20.",
            "the remark stands alone; exporting it only beside a flag would "
            "drop every note nobody escalated")

    def test_the_written_csv_carries_both_headers_and_the_values(self):
        """Through `_write_csv`, because `DictWriter(extrasaction='ignore')`
        drops any key that is not in the column list - a row populated with a
        name the header does not carry would vanish without an error."""
        a = self._assessment()
        flagged = self._sit(a, "Flagged One")
        self._sit(a, "Clean One")
        flagged.write({"manual_flagged": True,
                       "manual_remark": "Impersonation suspected."})

        content = export._write_csv(
            export.RESULTS_COLUMNS, export.results_rows(a)).decode("utf-8")
        parsed = list(csv.DictReader(io.StringIO(content)))
        by_name = {r["candidate"]: r for r in parsed}

        self.assertIn("Flagged", parsed[0])
        self.assertIn("Flag Remarks", parsed[0])
        self.assertEqual(by_name["Flagged One"]["Flagged"], "yes")
        self.assertEqual(by_name["Flagged One"]["Flag Remarks"],
                         "Impersonation suspected.")
        self.assertEqual(by_name["Clean One"]["Flagged"], "")
        self.assertEqual(by_name["Clean One"]["Flag Remarks"], "")

    def test_a_remark_that_looks_like_a_formula_is_neutralised(self):
        """CSV injection (CWE-1236). The remark is the only free text an
        operator types straight into this export, so it is the obvious way a
        `=HYPERLINK(...)` reaches somebody's spreadsheet."""
        a = self._assessment()
        ev = self._sit(a, "Formula")
        ev.write({"manual_remark": '=HYPERLINK("http://evil","click")'})

        content = export._write_csv(
            export.RESULTS_COLUMNS, export.results_rows(a)).decode("utf-8")
        row = list(csv.DictReader(io.StringIO(content)))[0]
        self.assertTrue(
            row["Flag Remarks"].startswith("'="),
            "the cell must be quoted so the sheet renders it as text")
