# -*- coding: utf-8 -*-
"""A whole test written as one JSON file imports into the bank as drafts.

12 Oct 2026: `questions_12th_oct.json` ({title, sections: [{title, questions:
[{type, prompt, options, answer}]}]}) was refused on Question Bank > Import
with "CSV must have at least a 'title' or 'prompt' column": JSON of no known
shape fell through to the CSV parser, which read `{` as the header row.
"""
import base64
import json

from odoo.exceptions import UserError
from odoo.tests.common import TransactionCase, tagged


def _test_file(**overrides):
    mcq = {"type": "mcq_single", "prompt": "Is a list mutable?", "marks": 1,
           "options": ["Yes", "No"], "answer": "Yes"}
    code = {"type": "code", "prompt": "Which command recovers the commits?",
            "language": "text", "answerMode": "mcq",
            "promptCode": "# a rebase dropped 3 commits",
            "options": ["git reflog", "git fsck"], "answers": ["git reflog"],
            "allowMultiple": False}
    mcq.update(overrides)
    return {"title": "Sectioned %s" % id(mcq), "timeLimitMinutes": 45,
            "sections": [{"title": "A. Python", "questions": [mcq]},
                         {"title": "B. Git", "questions": [code]}]}


@tagged("-at_install", "post_install")
class TestASectionedTestFileImportsAsDrafts(TransactionCase):

    def _run(self, data):
        raw = data if isinstance(data, str) else json.dumps(data)
        return self.env["assessments.be.bank.import.wizard"].create({
            "data_file": base64.b64encode(raw.encode()).decode(),
            "data_filename": "questions.json",
        }).run_import()

    def test_every_question_lands_as_a_draft_with_its_key(self):
        data = _test_file()
        result = self._run(data)
        self.assertEqual(result["format"], "harness")
        self.assertEqual(result["questions_created"], 2)
        drafts = self.env["assessments.be.prompt.question"].search(
            [("prompt_id", "=", result["generator_id"])], order="id")
        self.assertEqual(drafts.prompt_id.name, data["title"])
        self.assertEqual(drafts.mapped("question_type"), ["mcq", "mcq"])
        self.assertEqual(json.loads(drafts[0].correct_answer_json), "Yes")
        self.assertIn("# a rebase dropped 3 commits",
                      drafts[1].question_prompt,
                      "a code question keeps its snippet under the prompt")
        self.assertEqual(json.loads(drafts[1].options_json),
                         ["git reflog", "git fsck"])

    def test_an_answer_that_is_not_an_option_refuses_the_file(self):
        before = self.env["assessments.be.prompt.question"].search_count([])
        with self.assertRaisesRegex(UserError, "A. Python, question 1"):
            self._run(_test_file(answer="Maybe"))
        self.assertEqual(
            self.env["assessments.be.prompt.question"].search_count([]),
            before)

    def test_a_type_the_bank_cannot_hold_refuses_the_file(self):
        """Passed on, the harness importer made it a rubric question and
        dropped its options and key."""
        for qtype in ("true_false", ""):
            with self.assertRaisesRegex(UserError, "A. Python, question 1"):
                self._run(_test_file(type=qtype))

    def test_json_of_no_known_shape_is_not_read_as_a_csv(self):
        with self.assertRaises(UserError) as caught:
            self._run({"project": "P", "items": [{"q": "?"}]})
        self.assertNotIn("CSV must have", str(caught.exception))
        self.assertIn("sectioned test", str(caught.exception))
