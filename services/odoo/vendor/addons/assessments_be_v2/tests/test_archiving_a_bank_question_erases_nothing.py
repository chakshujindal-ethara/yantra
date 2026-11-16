# -*- coding: utf-8 -*-
"""Archive archives; only Delete may erase; Delete on history is final.

12 Oct 2026: the bank's Archive button called `bank/delete`, which erases every
selected question nothing points at. Archiving 146 questions on a local copy
erased 44 of them for good. `bank/archive` only flips `retired`, both ways.

Delete on a question with history cannot erase it without its answers and
scores, so it is marked `deleted`: out of the bank and out of Archived, with no
way back, and the paper using it untouched.
"""
from uuid import uuid4

from odoo.exceptions import UserError, ValidationError
from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import write as write_api
from ._paging_harness import call_route, status_of

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"


@tagged("-at_install", "post_install")
class TestArchivingABankQuestionErasesNothing(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.controller = write_api.EtpAssessmentApiWrite()
        # Unused by any paper, so `bank/delete` would erase it.
        self.question = self.env["assessments.be.question"].create({
            "name": "Unused %s" % uuid4().hex[:6],
            "question_type": "subjective_rubric",
            "prompt": "Describe",
        })

    def _archive(self, **body):
        return call_route(write_api, self.controller, "bank_archive_many",
                          self.env, ids=[self.question.id], **body)

    def test_an_unused_question_is_archived_not_erased(self):
        response = self._archive()
        self.assertEqual(status_of(response), 200, response)
        self.assertTrue(self.question.exists(), "archiving erased the row")
        self.assertTrue(self.question.retired)
        self.assertTrue(self.question.active,
                        "active=False would drop it out of built papers")

    def test_archive_false_restores(self):
        self._archive()
        self._archive(archive=False)
        self.assertFalse(self.question.retired)

    def test_no_ids_is_refused(self):
        response = call_route(write_api, self.controller, "bank_archive_many",
                              self.env, ids=[])
        self.assertEqual(status_of(response), 400)


@tagged("-at_install", "post_install")
class TestDeletingAQuestionWithHistoryKeepsItsResults(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.controller = write_api.EtpAssessmentApiWrite()
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % uuid4().hex[:6]})
        self.question = self.env["assessments.be.question"].create({
            "name": "Used %s" % uuid4().hex[:6],
            "question_type": "subjective_rubric",
            "prompt": "Describe",
            "generator_id": generator.id,
        })
        self.paper = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": generator.id,
            "duration_minutes": 30,
            "question_ids": [(4, self.question.id)],
        })

    def _route(self, method, **body):
        return call_route(write_api, self.controller, method, self.env,
                          **body)

    def test_delete_marks_it_deleted_and_the_paper_keeps_it(self):
        response = self._route("bank_delete_many", ids=[self.question.id])
        self.assertEqual(status_of(response), 200, response)
        self.assertTrue(self.question.exists())
        self.assertTrue(self.question.deleted)
        self.assertTrue(self.question.retired, "deleted must stay unservable")
        self.assertIn(self.question, self.paper.question_ids)

    def test_a_deleted_question_never_comes_back(self):
        self._route("bank_delete_many", ids=[self.question.id])
        refused = call_route(
            write_api, self.controller, "bank_restore", self.env,
            path={"question_id": self.question.id})
        self.assertEqual(status_of(refused), 409, refused)
        self._route("bank_archive_many", ids=[self.question.id],
                    archive=False)
        self.assertTrue(self.question.retired)
        with self.assertRaises(UserError):
            self.question.action_restore_to_bank()
        with self.assertRaises(UserError):
            self.question.retired = False

    def test_a_deleted_question_cannot_be_edited(self):
        self._route("bank_delete_many", ids=[self.question.id])
        refused = call_route(
            write_api, self.controller, "bank_update", self.env,
            path={"question_id": self.question.id}, name="Edited after delete")
        self.assertEqual(status_of(refused), 409, refused)
        self.assertNotEqual(self.question.name, "Edited after delete")

    def test_a_deleted_question_is_left_out_of_the_export(self):
        self._route("bank_delete_many", ids=[self.question.id])
        self.assertEqual(self.question._export_native(), [])

    def test_an_archived_question_deleted_later_moves_to_deleted(self):
        """Questions archived before Deleted existed take today's rule when
        someone presses Delete on them."""
        self.question.action_retire_from_bank()
        self._route("bank_delete_many", ids=[self.question.id])
        self.assertTrue(self.question.deleted)

    def test_archive_is_not_delete(self):
        self._route("bank_archive_many", ids=[self.question.id])
        self.assertTrue(self.question.retired)
        self.assertFalse(self.question.deleted)


@tagged("-at_install", "post_install")
class TestGeneratorsArchiveAndDeleteLikeTheBank(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.controller = write_api.EtpAssessmentApiWrite()
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % uuid4().hex[:6]})
        Question = self.env["assessments.be.question"]
        self.used, self.unused = (Question.create({
            "name": "%s %s" % (label, uuid4().hex[:6]),
            "question_type": "subjective_rubric",
            "prompt": "Describe",
            "generator_id": self.generator.id,
        }) for label in ("Used", "Unused"))
        self.paper = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "duration_minutes": 30,
            "question_ids": [(4, self.used.id)],
        })

    def _route(self, method, path=None, **body):
        return call_route(write_api, self.controller, method, self.env,
                          path=path, **body)

    def test_delete_on_a_used_generator_moves_it_to_deleted(self):
        response = self._route("generator_delete_many",
                               ids=[self.generator.id])
        self.assertEqual(status_of(response), 200, response)
        self.assertEqual(response["data"]["generators"][0]["outcome"], "kept")
        self.assertTrue(self.generator.exists())
        self.assertTrue(self.generator.deleted)
        self.assertFalse(self.generator.active)
        self.assertTrue(self.used.deleted, "its used question is Deleted")
        self.assertFalse(self.unused.exists(), "its unused one is erased")
        self.assertEqual(self.paper.generator_id, self.generator)
        self.assertIn(self.used, self.paper.question_ids)

    def test_a_deleted_generator_cannot_be_restored(self):
        self._route("generator_delete_many", ids=[self.generator.id])
        refused = self._route("generator_archive",
                              path={"generator_id": self.generator.id},
                              archive=False)
        self.assertEqual(status_of(refused), 409, refused)
        with self.assertRaises(ValidationError):
            self.generator.active = True

    def test_archive_stays_reversible_and_erases_nothing(self):
        self._route("generator_archive",
                    path={"generator_id": self.generator.id})
        self.assertFalse(self.generator.active)
        self.assertFalse(self.generator.deleted)
        self.assertTrue(self.unused.exists())
        self._route("generator_archive",
                    path={"generator_id": self.generator.id}, archive=False)
        self.assertTrue(self.generator.active)

    def test_a_deleted_generator_cannot_be_used_again(self):
        draft = self.env["assessments.be.prompt.question"].create({
            "prompt_id": self.generator.id,
            "name": "Leftover draft",
            "question_prompt": "Describe",
            "question_type": "subjective_rubric",
        })
        self._route("generator_delete_many", ids=[self.generator.id])
        refused = self._route("generator_generate",
                              path={"generator_id": self.generator.id})
        self.assertEqual(status_of(refused), 409, refused)
        name = self.generator.name
        renamed = self._route("generator_update",
                              path={"generator_id": self.generator.id},
                              name="Renamed after delete")
        self.assertEqual(status_of(renamed), 409, renamed)
        self.assertEqual(self.generator.name, name)
        with self.assertRaises(UserError):
            draft.action_approve()

    def test_a_deleted_generator_takes_nothing_new_but_can_be_stopped(self):
        draft = self.env["assessments.be.prompt.question"].create({
            "prompt_id": self.generator.id,
            "name": "Leftover draft",
            "question_prompt": "Describe",
            "question_type": "subjective_rubric",
        })
        self._route("generator_delete_many", ids=[self.generator.id])
        stop = self._route("generator_cancel_generation",
                           path={"generator_id": self.generator.id})
        self.assertNotEqual(status_of(stop), 409,
                            "stopping work must always be possible")
        edited = call_route(write_api, self.controller, "draft_update",
                            self.env, path={"draft_id": draft.id},
                            name="Edited after delete")
        self.assertEqual(status_of(edited), 409, edited)
        with self.assertRaises(UserError):
            self.env["assessments.be.bank.import"].import_bank_harness(
                {"questions": [{"id": "q1", "instruction": "x",
                                "fields": {}}]},
                generator_id=self.generator.id)
        paper = self._route("assessment_create", name="New paper",
                            generator_id=self.generator.id)
        self.assertEqual(status_of(paper), 409, paper)
