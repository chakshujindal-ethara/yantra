# -*- coding: utf-8 -*-
"""A key nobody can earn never reaches the bank (R8, 14 Oct).

A candidate picks ONE option on an mcq or image_ab axis unless it is drawn as
checkboxes, and scoring is an exact-set match per axis, so two correct options
there score every candidate zero. Approval and every import lane let such a key
through. Now approval refuses it (Approve All skips it and says why), the CSV
and harness lanes refuse the file naming the row or item, and a native restore
skips the item with a warning - keeping each axis's `input_kind`, which it
used to drop.
"""
import base64
import json
from uuid import uuid4

from odoo.exceptions import UserError
from odoo.tests.common import TransactionCase, tagged

_OPTIONS = ["Paris", "Lyon", "Nice"]


@tagged("-at_install", "post_install")
class TestApprovalAndImportsRefuseAnUnearnableKey(TransactionCase):

    def setUp(self):
        super().setUp()
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Unearnable %s" % uuid4().hex[:6]})
        self.Draft = self.env["assessments.be.prompt.question"]

    def _draft(self, correct, kind="", question_type="mcq"):
        return self.Draft.create({
            "prompt_id": self.generator.id,
            "name": "Draft %s" % uuid4().hex[:6],
            "question_prompt": "Which city is the capital of France?",
            "question_type": question_type,
            "dimensions_json": json.dumps([{
                "label": "Capital", "options": _OPTIONS, "kind": kind,
                "correct": correct}]),
        })

    def test_approval_refuses_an_unearnable_key(self):
        bad = self._draft(["Paris", "Lyon"])
        with self.assertRaisesRegex(UserError, bad.name):
            bad.action_approve()
        self.assertEqual(bad.state, "draft")

        # Several on a checkboxes axis, or on an msq, are a fair key.
        ticks = self._draft(["Paris", "Lyon"], kind="checkboxes")
        msq = self._draft(["Paris", "Lyon"], question_type="msq")
        (ticks | msq).action_approve()
        self.assertEqual((ticks | msq).mapped("state"),
                         ["approved", "approved"])

        # Approve All skips it, names it, and banks the rest.
        bad_again = self._draft(["Paris", "Nice"])
        good = self._draft(["Paris"])
        result = self.generator.action_approve_all_drafts()
        self.assertEqual(good.state, "approved")
        self.assertEqual(bad_again.state, "draft")
        self.assertEqual(result["params"]["type"], "warning")
        self.assertTrue(self.env["mail.message"].search_count([
            ("model", "=", self.generator._name),
            ("res_id", "=", self.generator.id),
            ("body", "ilike", bad_again.name)]))

    def _wizard(self, raw, filename):
        return self.env["assessments.be.bank.import.wizard"].create({
            "data_file": base64.b64encode(raw.encode()).decode(),
            "data_filename": filename,
        })

    def test_every_import_lane_refuses_an_unearnable_key(self):
        Import = self.env["assessments.be.bank.import"]

        # CSV: the row is named.
        csv_text = ("title,question_type,prompt,options,correct_answer\n"
                    "Fine,msq,Pick the cities,Paris|Lyon|Nice,Paris|Lyon\n"
                    "Bad,mcq,Pick the capital,Paris|Lyon|Nice,Paris|Lyon\n")
        with self.assertRaisesRegex(UserError, "Row 3"):
            self._wizard(csv_text, "bank.csv").run_import()

        # Harness: two answers on an mcq, and an answer that is no option.
        def harness(correct):
            return [{"id": "q07", "instruction": "Pick the capital.",
                     "fields": {"question_type": "mcq", "options": _OPTIONS,
                                "correct_answer": correct}}]
        for correct in (["Paris", "Lyon"], "Marseille", ["Paris", "Marseille"]):
            with self.subTest(harness=correct), \
                    self.assertRaisesRegex(UserError, "item q07"):
                Import.import_bank_harness(harness(correct))
        fine = Import.import_bank_harness(harness(1))
        self.assertEqual(fine["questions_created"], 1)

        # Native: the item is skipped with a warning; the rest restore with
        # their axis kind.
        def dim(kind=""):
            return {"name": "Capital", "input_kind": kind, "options": [
                {"name": "Paris", "is_correct": True},
                {"name": "Lyon", "is_correct": True},
                {"name": "Nice", "is_correct": False}]}
        name = "Ticks %s" % uuid4().hex[:6]
        result = Import.import_bank_native({
            "assessments_be_bank": "1", "questions": [
                {"name": "Bad", "question_type": "mcq",
                 "prompt": "Pick", "dimensions": [dim()]},
                {"name": name, "question_type": "mcq",
                 "prompt": "Pick", "dimensions": [dim("checkboxes")]}]})
        self.assertEqual(result["questions_created"], 1)
        self.assertEqual(len(result["warnings"]), 1)
        self.assertIn("Bad", result["warnings"][0])
        restored = self.env["assessments.be.question"].search(
            [("name", "=", name)])
        self.assertEqual(restored.question_dimension_ids.input_kind,
                         "checkboxes")
