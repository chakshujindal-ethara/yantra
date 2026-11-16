""""Answered" counts real answers only, and the upgrade recounts old rows.

THE DEFECT. Settlement writes an empty placeholder response
(`auto_submitted=True`, no lines) for every question left blank, and
`answered_count` counted every SUBMITTED row - so every handed-in paper read
answered = questions, on the admin candidate rows, the Results export and the
Odoo form alike. `assessments.be.response._is_answered` is now the one
definition (submitted, not a placeholder, not cleared, carrying content), and
`migrations/19.0.3.27.0/post-migrate.py` recounts every stored value.
"""
import importlib.util
import json
import os
from datetime import timedelta
from unittest.mock import patch
from uuid import uuid4

from odoo import fields
from odoo.tests.common import TransactionCase, tagged


def _load_migration():
    """The post-migrate module, by path (`migrations/` is not a package)."""
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = os.path.join(here, "migrations", "19.0.3.27.0", "post-migrate.py")
    spec = importlib.util.spec_from_file_location("be_v2_answered_mig", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@tagged("-at_install", "post_install")
class TestAnsweredMeansARealAnswer(TransactionCase):

    QUESTIONS = 4

    def setUp(self):
        super().setUp()
        self.Question = self.env["assessments.be.question"]
        self.Response = self.env["assessments.be.response"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Answered fixture %s" % uuid4().hex[:6]})
        self.controller = self._controller()

    @staticmethod
    def _controller():
        import inspect

        from odoo import http

        from ..controllers.api import candidate as candidate_api
        for _name, obj in vars(candidate_api).items():
            if (inspect.isclass(obj) and issubclass(obj, http.Controller)
                    and obj.__module__ == candidate_api.__name__
                    and hasattr(obj, "exam_answers_batch")):
                return obj()
        raise AssertionError("the candidate controller was not found")

    # ── fixtures (as test_a_paper_can_be_saved_in_one_batch) ──────────

    def _question(self, n):
        question = self.Question.create({
            "name": "Q%d %s" % (n, uuid4().hex[:4]),
            "question_type": "mcq",
            "prompt": "Pick one",
            "difficulty": "easy",
            "sequence": n * 10,
            "generator_id": self.generator.id,
        })
        self.env["assessments.be.question.dimension"].create({
            "question_id": question.id,
            "name": "Answer",
            "option_line_ids": [
                (0, 0, {"name": name, "sequence": j * 10,
                        "is_correct": j == 0})
                for j, name in enumerate(("Alpha", "Bravo"))
            ],
        })
        return question

    def _sitting(self):
        questions = self.Question.browse()
        for n in range(self.QUESTIONS):
            questions |= self._question(n)
        assessment = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, questions.ids)],
            "question_limit": self.QUESTIONS,
            "duration_minutes": 60,
            "state": "in_progress",
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Answered Sitter",
            "email_from": "%s@example.com" % uuid4().hex[:10],
        })
        evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
            "question_order": json.dumps(questions.ids),
            "access_token": uuid4().hex,
            "started_at": fields.Datetime.now(),
            "state": "in_progress",
        })
        assessment.sudo()._ensure_candidate_user(applicant)
        user = evaluator.sudo()._candidate_user()
        self.assertTrue(user, "no portal user: every call would be a 403")
        self.env.flush_all()
        return evaluator, questions, user

    def _call(self, route, evaluator, user, **params):
        from ..controllers.api import candidate as candidate_api
        from ..controllers.api import common as api_common

        class _Req:
            def __init__(self, env, params):
                self.env = env
                self.params = dict(params)
                self.httprequest = type(
                    "H", (), {"method": "POST", "headers": {}})()

            def make_json_response(self, payload, headers=None, status=200):
                return {"__status": status, **payload}

        self.env.cr._now = self.env.cr.now() + timedelta(seconds=1)
        fake = _Req(self.env(user=user), params)
        with patch.object(candidate_api, "request", fake), \
                patch.object(api_common, "request", fake):
            reply = getattr(self.controller, route)(
                evaluator.access_token, **fake.params)
        self.env.flush_all()
        return reply

    @staticmethod
    def _item(question):
        option = question.question_dimension_ids[:1].option_line_ids.filtered(
            "is_correct")[:1]
        return {"question_id": question.id,
                "selected_option_ids": option.ids}

    def _two_answered_and_handed_in(self):
        """Two of four answered through the batch, then a forced submit:
        settlement writes a placeholder for the other two."""
        evaluator, questions, user = self._sitting()
        reply = self._call(
            "exam_answers_batch", evaluator, user,
            answers=[self._item(q) for q in questions[:2]],
            submit=True, force=True)
        self.assertTrue(reply.get("ok"), reply)
        self.assertTrue(evaluator.is_locked)
        placeholders = self.Response.search([
            ("assessment_evaluator_id", "=", evaluator.id),
            ("auto_submitted", "=", True)])
        self.assertEqual(len(placeholders), 2,
                         "the fixture must carry placeholders to prove "
                         "anything")
        return evaluator, questions

    # ── the definition ────────────────────────────────────────────────

    def test_placeholders_are_not_answers_on_any_admin_count(self):
        from ..controllers.api import serializers as S
        from ..services import export

        evaluator, _questions = self._two_answered_and_handed_in()

        self.assertEqual(evaluator.answered_count, 2,
                         "a handed-in paper counted its placeholders")
        self.assertEqual(evaluator.total_questions, 4)
        self.assertEqual(S.evaluator_admin_row(evaluator)["answered_count"],
                         2)
        row = next(r for r in export.results_rows(evaluator.assessment_id)
                   if r["candidate"] == "Answered Sitter")
        self.assertEqual(row["answered_count"], 2)
        self.assertEqual(row["question_count"], 4)

    def test_is_answered_needs_a_real_submitted_answer(self):
        evaluator, questions = self._two_answered_and_handed_in()
        rows = {r.question_id: r for r in self.Response.search([
            ("assessment_evaluator_id", "=", evaluator.id)])}
        self.assertTrue(rows[questions[0]]._is_answered(), "an option")
        self.assertFalse(rows[questions[3]]._is_answered(), "placeholder")

        text = "The cup is level."
        self.assertTrue(self.Response.new(
            {"state": "submitted", "justification": text})._is_answered(),
            "text alone is an answer")
        for vals, why in (
                ({"state": "submitted", "justification": text,
                  "cleared": True}, "a cleared answer"),
                ({"state": "draft", "justification": text}, "a draft"),
                ({"state": "submitted"}, "a submitted row with no content"),
                ({"state": "submitted", "auto_submitted": True,
                  "justification": "[Submitted with unanswered questions]"},
                 "a placeholder"),
                ({"state": "submitted",
                  "justification": "[Auto-submitted: time expired]"},
                 "a legacy placeholder from before the flag existed")):
            with self.subTest(why=why):
                self.assertFalse(self.Response.new(vals)._is_answered(), why)

    # ── the migration ─────────────────────────────────────────────────

    def test_the_upgrade_recounts_every_stored_value_once(self):
        evaluator, _questions = self._two_answered_and_handed_in()
        # What the OLD compute stored: every submitted row.
        self.env.cr.execute(
            "UPDATE assessments_be_evaluator SET answered_count = 4 "
            "WHERE id = %s", (evaluator.id,))
        self.env.invalidate_all()
        self.assertEqual(evaluator.answered_count, 4)

        migration = _load_migration()

        def run():
            """The logged (attempts, changed) of one run."""
            with patch.object(migration, "_logger") as logger:
                migration.migrate(self.env.cr, "19.0.3.24.0")
            self.env.invalidate_all()
            return logger.info.call_args.args[2:]

        total, changed = run()
        self.assertEqual(evaluator.answered_count, 2)
        self.assertGreaterEqual(total, 1)
        self.assertGreaterEqual(changed, 1, "the stale value was not counted")
        self.assertEqual(run(), (total, 0), "a second run must change nothing")
        self.assertEqual(evaluator.answered_count, 2)

    def test_a_fresh_install_skips_the_recount(self):
        migration = _load_migration()
        with patch.object(migration, "_logger") as logger:
            migration.migrate(self.env.cr, None)
        logger.info.assert_not_called()
