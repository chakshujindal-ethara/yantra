# -*- coding: utf-8 -*-
"""The draft LIST row carries the flat answer key the editor edits.

THE DEFECT THIS LOCKS DOWN, reproduced in a real browser before the fix.

`showDraftEditor` is handed the CACHED LIST ROW - the review queue, the
generator's Drafts tab and the assessment preview sheet all pass the row they
already hold, never a detail fetch. The editor seeds its option rows from
`options` + `correct_answer`, and those two keys lived ONLY in `draft_detail`.

So Edit Draft on an mcq rendered Title, Question, Description, Time, Answer
rationale, Difficulty - and NO options section - over a draft whose four options
and answer key the review card was rendering correctly two inches above the
pencil that opened it. Measured in Chrome on draft 197: the sheet ended at
DIFFICULTY, straight into Cancel/Save.

Two consequences, the second worse than the first:
  * The reviewer cannot fix the one thing this editor exists for ("fix it here
    rather than denying and regenerating").
  * A save from that sheet posts an EMPTY option list over a good key.

This is the same argument `draft_row`'s own docstring already makes for
`dimensions` and `has_valid_key`: the client replaces its draft cache wholesale
on every refresh, so anything only the detail route carries is simply not there
when the editor opens.
"""
import json

from odoo.tests.common import TransactionCase

from odoo.addons.assessments_be_v2.controllers.api import serializers


class TestDraftRowCarriesItsFlatKey(TransactionCase):

    def _draft(self, qtype="mcq", options=None, correct=None):
        prompt = self.env["assessments.be.prompt"].create({"name": "Gen"})
        vals = {
            "prompt_id": prompt.id,
            "name": "Classifying a defect",
            "question_prompt": "Which statement describes this finding?",
            "question_type": qtype,
        }
        if options is not None:
            vals["options_json"] = json.dumps(options)
        if correct is not None:
            vals["correct_answer_json"] = json.dumps(correct)
        return self.env["assessments.be.prompt.question"].create(vals)

    def test_the_row_carries_the_options_the_editor_seeds_from(self):
        draft = self._draft(
            options=["Anatomy class", "Typography class", "Physics class"],
            correct="Anatomy class")
        row = serializers.draft_row(draft)
        self.assertEqual(
            row.get("options"),
            ["Anatomy class", "Typography class", "Physics class"],
            "the editor opens from the LIST row, so an absent `options` key is "
            "an Edit Draft sheet with no options section at all")
        self.assertEqual(row.get("correct_answer"), "Anatomy class")

    def test_an_msq_key_stays_a_LIST(self):
        """`correct_answer` is a bare string for mcq and a list for msq; the
        client normalises both, so the row must not flatten either shape."""
        draft = self._draft(qtype="msq",
                            options=["A", "B", "C"],
                            correct=["A", "C"])
        self.assertEqual(serializers.draft_row(draft)["correct_answer"],
                         ["A", "C"])

    def test_a_draft_with_no_flat_key_reports_empty_not_missing(self):
        """An image_ab keys a dimension tree, not a flat list. The keys must
        still be PRESENT and empty - the client tells "no options" from "[]",
        and a missing key would make it guess."""
        row = serializers.draft_row(self._draft(qtype="image_ab"))
        self.assertEqual(row["options"], [])
        self.assertIsNone(row["correct_answer"])

    def test_the_row_and_the_detail_agree_on_the_key(self):
        """The trap `draft_detail`'s own docstring warns about: a detail route
        that narrows a key the row got right. Asserted as agreement so neither
        side can drift."""
        draft = self._draft(options=["Yes", "No"], correct="Yes")
        row = serializers.draft_row(draft)
        detail = serializers.draft_detail(draft)
        self.assertEqual(row["options"], detail["options"])
        self.assertEqual(row["correct_answer"], detail["correct_answer"])
