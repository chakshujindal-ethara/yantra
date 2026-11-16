# -*- coding: utf-8 -*-
"""Renaming an option re-scores nothing; changing the key still does.

WHY. The bank editor sends the whole answer key back with every save. Every
answer's marks depend on `is_correct` through the question's dimensions, and
Odoo re-scores all of them on any write through that relation, or of
`is_correct`, changed or not: on a question sat 3,700 times mid-exam a one-word
rename took 50 s and Odoo's last serialization retry (12 Oct load test).
`write._sync_dimensions` now writes changed rows directly, and the option drops
an unchanged `is_correct`.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import serializers as S
from ..controllers.api import write as write_api
from . import test_a_question_is_served_from_the_cache as cache_test
from . import test_a_sitting_stays_inside_its_write_budget as budget
from ._paging_harness import call_route, status_of

_Budget = getattr(budget, "TestASittingStaysInsideItsWriteBudget")


@tagged("-at_install", "post_install")
class TestRenamingAnOptionRescoresNothing(TransactionCase):

    QUESTIONS = 2
    _question = _Budget._question
    _sitting = _Budget._sitting
    _call = _Budget._call
    _answer = _Budget._answer

    def setUp(self):
        super().setUp()
        cache_test._isolate(self)
        self.Assessment = self.env["assessments.be"]
        self.Question = self.env["assessments.be.question"]
        self.QDim = self.env["assessments.be.question.dimension"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Applicant = self.env["hr.applicant"]
        self.controller = _Budget._controller()
        self.session_key = uuid4().hex
        self.stamps = {}

    def _rescored(self):
        """Ids of responses whose key-dependent marks get recomputed."""
        Response = self.env["assessments.be.response"]
        names = {f.compute for f in Response._fields.values()
                 if f.compute and f.store and any(
                     "is_correct" in d for d in f.get_depends(Response)[0])}
        self.assertTrue(names, "no response field depends on the key")
        seen = set()
        cls = type(Response)
        for name in names:
            def spy(records, _original=getattr(cls, name)):
                seen.update(records.ids)
                return _original(records)
            spied = patch.object(cls, name, spy)
            spied.start()
            self.addCleanup(spied.stop)
        return seen

    def _save_key(self, question, edit):
        dims = S.bank_question_detail(question)["dimensions"]
        edit(dims[0]["options"])
        reply = call_route(write_api, write_api.EtpAssessmentApiWrite(),
                           "bank_update", self.env,
                           path={"question_id": question.id}, dimensions=dims)
        self.assertEqual(status_of(reply), 200, reply)
        self.env.flush_all()

    def test_a_rename_rescores_nothing_and_a_key_change_rescores(self):
        _assessment, evaluator, questions, user = self._sitting()
        self.assertTrue(self._call("exam_begin", evaluator, user)["ok"])
        question = questions[0]
        self.assertTrue(self._answer(evaluator, user, question)["ok"])
        response = self.env["assessments.be.response"].search([
            ("assessment_evaluator_id", "=", evaluator.id),
            ("question_id", "=", question.id)])
        self.assertTrue(response)
        self.env.user.group_ids = [(4, self.env.ref(
            "assessments_be_v2.group_assessment_manager").id)]
        self.env.flush_all()
        version = question.write_date
        rescored = self._rescored()

        def rename(options):
            options[0]["name"] = "Renamed"
        self._save_key(question, rename)
        option = question.question_dimension_ids[:1].option_line_ids[:1]
        self.assertEqual(option.name, "Renamed")
        self.assertNotIn(response.id, rescored, "a rename re-scored")
        self.assertGreaterEqual(question.write_date, version,
                                "the rename must still version the question")

        def flip(options):
            for i, o in enumerate(options):
                o["is_correct"] = i == 1
        self._save_key(question, flip)
        self.assertIn(response.id, rescored, "a key change did not re-score")
