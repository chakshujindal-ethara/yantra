# -*- coding: utf-8 -*-
""""Same questions for everybody" is retired, and the count locks at launch.

ETP_PLANS_AND_STRATEGY.md §4.3 / §2.9 (W7). Every candidate
sits one shared set, whatever the stored `same_questions_for_all` says; the
column stays and no row is rewritten. The flag is off the API (an old client's
key is ignored, not refused) and off the detail payload. After launch a CHANGED
`question_limit` is refused with 422 `locked_after_launch`; the same value
passes, because older apps save the whole settings object.
"""
import json
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import common as api_common
from ..controllers.api import serializers as S
from ..controllers.api import write as write_api
from ..controllers.api.admin import EtpAssessmentApiAdmin

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"


class _Req:
    """What `assessment_update`/`assessment_create` read off `request` - same
    stub as `test_an_assessment_can_be_renamed_after_launch`."""

    def __init__(self, env, params):
        self.env = env
        self.params = params

    def make_json_response(self, payload, headers=None, status=200):
        return {"__status": status, **payload}


@tagged("-at_install", "post_install")
class TestEverybodySitsOneSharedSet(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.Assessment = self.env["assessments.be"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Shared set %s" % uuid4().hex[:6]})
        self.questions = self.env["assessments.be.question"]
        for n in range(10):
            q = self.env["assessments.be.question"].create({
                "name": "SS Q%d %s" % (n, uuid4().hex[:4]),
                "question_type": "mcq",
                "prompt": "Pick one.",
                "sequence": (n + 1) * 10,
                "generator_id": self.generator.id,
            })
            self.env["assessments.be.question.dimension"].create({
                "question_id": q.id,
                "name": "Answer",
                "option_line_ids": [
                    (0, 0, {"name": name, "sequence": i * 10,
                            "is_correct": i == 0})
                    for i, name in enumerate(("Alpha", "Bravo"))],
            })
            self.questions |= q

    # -- fixtures ---------------------------------------------------------

    def _applicant(self):
        return self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % uuid4().hex[:6],
            "email_from": "ss_%s@example.com" % uuid4().hex[:8],
        })

    def _assessment(self, **vals):
        return self.Assessment.create(dict({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "duration_minutes": 30,
            "question_limit": 4,
        }, **vals))

    @staticmethod
    def _paper(row):
        return json.loads(row.question_order or "[]")

    def _call(self, method, *args, **payload):
        fake = _Req(self.env, dict(payload))
        controller = write_api.EtpAssessmentApiWrite()
        with patch.object(write_api, "request", fake), \
                patch.object(api_common, "request", fake):
            return getattr(controller, method)(*args)

    @staticmethod
    def _status(response):
        return response.get("__status", 200)

    # -- launch -----------------------------------------------------------

    def test_launch_draws_one_shared_set_even_on_an_old_per_person_row(self):
        """A row still storing `same_questions_for_all = False` (as older
        assessments do) launches with ONE set for all, shuffled per person."""
        applicants = self.env["hr.applicant"]
        for _ in range(5):
            applicants |= self._applicant()
        asm = self._assessment(same_questions_for_all=False,
                               evaluator_ids=[(6, 0, applicants.ids)])

        asm.action_start()

        papers = [self._paper(r) for r in asm.assessment_evaluator_ids]
        self.assertEqual(len(papers), 5)
        self.assertEqual(len({frozenset(p) for p in papers}), 1,
                         "every candidate must sit the same 4 questions")
        self.assertEqual(len(papers[0]), 4)
        # 5 shuffles of 4 all landing on one order: (1/24)^4.
        self.assertGreater(len({tuple(p) for p in papers}), 1,
                           "order is still shuffled per candidate")
        self.assertFalse(asm.same_questions_for_all,
                         "the stored column is left exactly as it was")

    # -- late add ---------------------------------------------------------

    def test_a_late_candidate_copies_the_oldest_real_paper(self):
        """An old per-person cohort: two attempts with DIFFERENT papers. The
        late candidate copies the oldest one that holds a paper - a bare roster
        row and a broken "[]" attempt, though older, do not count."""
        asm = self._assessment(
            same_questions_for_all=False, state="in_progress",
            question_ids=[(6, 0, self.questions.ids)])
        ids = self.questions.ids
        first, second = ids[:4], ids[4:8]
        for order in ("[]", False, json.dumps(first), json.dumps(second)):
            self.Evaluator.create({
                "assessment_id": asm.id,
                "applicant_id": self._applicant().id,
                "question_order": order,
            })

        late = self._applicant()
        with patch.object(type(asm), "_ensure_candidate_user",
                          lambda self, applicant: None):
            provisioned, refused = \
                EtpAssessmentApiAdmin()._provision_late_candidates(asm, late)

        self.assertEqual(refused, [])
        self.assertEqual(len(provisioned), 1)
        self.assertEqual(
            sorted(self._paper(self.Evaluator.browse(provisioned[0]))),
            sorted(first),
            "the late candidate must sit the oldest real paper's questions")

    def test_a_late_batch_with_no_paper_to_copy_shares_one_draw(self):
        """Nobody holds a paper yet: the first late candidate's draw is the
        set the rest of the same batch copies."""
        asm = self._assessment(state="in_progress",
                               question_ids=[(6, 0, self.questions.ids)])
        batch = self.env["hr.applicant"]
        for _ in range(4):
            batch |= self._applicant()

        with patch.object(type(asm), "_ensure_candidate_user",
                          lambda self, applicant: None):
            provisioned, _refused = \
                EtpAssessmentApiAdmin()._provision_late_candidates(asm, batch)

        papers = [self._paper(r) for r in self.Evaluator.browse(provisioned)]
        self.assertEqual(len(papers), 4)
        self.assertEqual(len({frozenset(p) for p in papers}), 1)

    # -- the API ----------------------------------------------------------

    def test_the_flag_is_off_the_detail_payload(self):
        self.assertNotIn("same_questions_for_all",
                         S.assessment_detail(self._assessment()))

    def test_an_old_clients_key_is_ignored_on_create_and_update(self):
        created = self._call("assessment_create",
                             name="Old app %s" % uuid4().hex[:4],
                             same_questions_for_all=False)
        self.assertEqual(self._status(created), 200, created)
        self.assertNotIn("same_questions_for_all", created["data"])
        asm = self.Assessment.browse(created["data"]["id"])
        self.assertTrue(asm.same_questions_for_all,
                        "the key must not reach the column")

        # On a RUNNING assessment too: ignored, not a 409.
        asm.state = "in_progress"
        response = self._call("assessment_update", asm.id,
                              same_questions_for_all=False,
                              duration_minutes=45)
        self.assertEqual(self._status(response), 200, response)
        self.assertTrue(asm.same_questions_for_all)
        self.assertEqual(asm.duration_minutes, 45)

    def test_a_changed_count_is_refused_after_launch(self):
        for state in ("in_progress", "done", "cancelled"):
            asm = self._assessment(state=state)
            response = self._call("assessment_update", asm.id,
                                  question_limit=7)
            self.assertEqual(self._status(response), 422, response)
            self.assertEqual(response["error"]["code"], "locked_after_launch")
            self.assertEqual(asm.question_limit, 4, "nothing is written")

    def test_the_same_count_passes_after_launch(self):
        """Older apps send the whole settings object, count included."""
        asm = self._assessment(state="in_progress")
        response = self._call("assessment_update", asm.id,
                              question_limit=4, name="Renamed")
        self.assertEqual(self._status(response), 200, response)
        self.assertEqual(asm.name, "Renamed")

    def test_a_draft_count_still_changes(self):
        asm = self._assessment()
        response = self._call("assessment_update", asm.id, question_limit=7)
        self.assertEqual(self._status(response), 200, response)
        self.assertEqual(asm.question_limit, 7)

    # -- the Odoo form ----------------------------------------------------

    def test_the_odoo_form_drops_the_flag_and_locks_the_count(self):
        from lxml import etree
        view = self.env.ref("assessments_be_v2.assessments_be_form")
        arch = etree.fromstring(
            self.Assessment.get_view(view.id, "form")["arch"])
        self.assertFalse(arch.xpath("//field[@name='same_questions_for_all']"))
        limit = arch.xpath("//field[@name='question_limit']")
        self.assertTrue(limit)
        self.assertEqual(limit[0].get("readonly"), "state != 'draft'")
