"""A late-added candidate must not silently sit a SHORTER paper.

A short paper is scored over a different denominator from the cohort it is
ranked against. `action_start` refuses to launch when the pool cannot fill
`question_limit`; `_provision_late_candidates` refuses the late candidate in
the same case, and when a question the cohort sat has since gone (S13).

The pool shrinks under a running assessment: `available` is filtered by
`q.active and q._has_required_images() and q._has_required_videos()`, so
archiving a question, or an S3 lifecycle rule emptying a plate, removes it from
the draw.

REPORTED, NOT RAISED. A late add is a bulk operation, called from
`_assessment_assign` AFTER the roster rows are written; raising would lose that
work for every candidate in the batch. The refused candidate gets no attempt
and the operator is told why.

Every candidate copies the shared set the cohort sat (`same_questions_for_all`
is retired and no longer read). An intact shared set proceeds even when it is
shorter than `question_limit`: the peers sat exactly that.
"""
import json
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import HttpCase, TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestALateCandidateGetsAFullPaper(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Question = self.env["assessments.be.question"]
        self.QDim = self.env["assessments.be.question.dimension"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Applicant = self.env["hr.applicant"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Late paper fixture %s" % uuid4().hex[:6]})
        self.controller = self._controller()

    @staticmethod
    def _controller():
        import inspect

        from odoo import http

        from ..controllers.api import admin as admin_api
        for _name, obj in vars(admin_api).items():
            if (inspect.isclass(obj) and issubclass(obj, http.Controller)
                    and obj.__module__ == admin_api.__name__
                    and hasattr(obj, "_provision_late_candidates")):
                return obj()
        raise AssertionError("the admin controller was not found")

    def _question(self, n):
        q = self.Question.create({
            "name": "Q%d %s" % (n, uuid4().hex[:4]),
            "question_type": "mcq",
            "prompt": "Pick one",
            "difficulty": "easy",
            "sequence": n * 10,
            "generator_id": self.generator.id,
        })
        self.QDim.create({
            "question_id": q.id,
            "name": "Answer",
            "option_line_ids": [
                (0, 0, {"name": name, "sequence": j * 10,
                        "is_correct": j == 0})
                for j, name in enumerate(("Alpha", "Bravo"))
            ],
        })
        return q

    def _running_assessment(self, questions, limit, **vals):
        """An assessment already in progress, holding `questions` as its
        launched snapshot. `question_limit` is what each paper should be."""
        return self.Assessment.create(dict({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "question_ids": [(6, 0, questions.ids)],
            "question_limit": limit,
            "state": "in_progress",
        }, **vals))

    def _applicant(self, name):
        return self.Applicant.create({
            "partner_name": name,
            "email_from": "%s@example.com" % uuid4().hex[:10],
        })

    def _provision(self, assessment, applicants):
        """Call the real method. `_ensure_candidate_user` is patched out: it
        creates portal logins and sends nothing here, and this test is about the
        DRAW, not provisioning."""
        with patch.object(type(assessment), "_ensure_candidate_user",
                          lambda self, applicant: None):
            provisioned, self.refused = \
                self.controller._provision_late_candidates(
                    assessment, applicants)
        return provisioned

    # ── the defect ────────────────────────────────────────────────────

    def test_a_short_pool_does_not_yield_a_short_paper(self):
        """THE HEADLINE. 20 asked for, 12 available.

        Before the fix this returned an attempt holding 12 questions. The
        candidate sits a 12-question exam and is ranked against people who sat
        20.
        """
        questions = self.Question.browse()
        for n in range(12):
            questions |= self._question(n)
        assessment = self._running_assessment(questions, limit=20)
        applicant = self._applicant("Late Arrival")

        provisioned = self._provision(assessment, applicant)

        self.assertEqual(
            provisioned, [],
            "a candidate was provisioned from a pool of 12 for a 20-question "
            "paper - they sit a shorter exam than the cohort, silently")
        row = self.Evaluator.search([
            ("assessment_id", "=", assessment.id),
            ("applicant_id", "=", applicant.id)])
        self.assertFalse(
            row.filtered(lambda e: e.question_order),
            "no attempt should carry a short question_order")
        # SKIPPING QUIETLY WOULD BE ITS OWN BUG. The candidate is on the roster,
        # so if nothing says why they have no attempt the operator finds out when
        # the candidate reports a blank exam.
        self.assertEqual(len(self.refused), 1,
                         "the refusal must be reported, not silent")
        self.assertEqual(self.refused[0]["applicant_id"], applicant.id)
        self.assertIn("20", self.refused[0]["reason"])
        self.assertIn("12", self.refused[0]["reason"])

    def test_a_full_pool_still_provisions(self):
        """The other half, and the one a blanket refusal would break: when the
        pool can supply the paper, the late candidate is provisioned as before.
        """
        questions = self.Question.browse()
        for n in range(20):
            questions |= self._question(n)
        assessment = self._running_assessment(questions, limit=20)
        applicant = self._applicant("Late But Fine")

        provisioned = self._provision(assessment, applicant)

        self.assertEqual(len(provisioned), 1, "a full pool must provision")
        row = self.Evaluator.browse(provisioned[0])
        self.assertEqual(
            len(json.loads(row.question_order or "[]")), 20,
            "the late candidate must get the full paper")

    def test_no_question_limit_means_the_whole_pool_is_the_paper(self):
        """`question_limit = 0` means "everything", exactly as launch reads it
        (`limit = rec.question_limit or len(available_questions)`). There is no
        shortfall to detect, so this must still provision."""
        questions = self.Question.browse()
        for n in range(7):
            questions |= self._question(n)
        assessment = self._running_assessment(questions, limit=0)
        applicant = self._applicant("No Limit Set")

        provisioned = self._provision(assessment, applicant)

        self.assertEqual(len(provisioned), 1)
        row = self.Evaluator.browse(provisioned[0])
        self.assertEqual(
            len(json.loads(row.question_order or "[]")), 7,
            "with no limit the whole pool is the paper")

    def test_the_shared_set_wins_even_when_it_is_short(self):
        """THE CARVE-OUT, and it is load-bearing.

        The shared set IS the cohort's instrument. If the peers sat 3
        questions, a late arrival must sit those 3; refusing here would lock
        out every late candidate on a paper whose pool is shorter than
        `question_limit`. (The retired flag is set only as an old row would
        store it; nothing reads it.)
        """
        questions = self.Question.browse()
        for n in range(3):
            questions |= self._question(n)
        assessment = self._running_assessment(
            questions, limit=20, same_questions_for_all=True)
        # A peer who already sat the shared set.
        peer = self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": self._applicant("Original Peer").id,
            "question_order": json.dumps(questions.ids),
        })
        self.assertTrue(peer.question_order)

        applicant = self._applicant("Joins The Shared Set")
        provisioned = self._provision(assessment, applicant)

        self.assertEqual(
            len(provisioned), 1,
            "a shared-set assessment must still take a late candidate")
        self.assertEqual(self.refused, [],
                         "the shared set must not be refused for being short")
        row = self.Evaluator.browse(provisioned[0])
        # COMPARED AS A SET, not a list. `preserve_question_order` is off here,
        # so `random.shuffle` runs on the drawn list and a different ORDER is
        # correct - each candidate gets their own sequence, which is the
        # anti-collusion property. What the shared set guarantees is the same
        # QUESTIONS, and that is what this asserts.
        self.assertEqual(
            sorted(json.loads(row.question_order or "[]")),
            sorted(questions.ids),
            "the late candidate must sit exactly the questions the cohort sat")

    def test_an_already_provisioned_candidate_is_untouched(self):
        """Idempotence: re-running assign must not redraw a paper somebody may
        already be sitting."""
        questions = self.Question.browse()
        for n in range(20):
            questions |= self._question(n)
        assessment = self._running_assessment(questions, limit=20)
        applicant = self._applicant("Already Sitting")
        original = json.dumps(questions.ids[:20])
        row = self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
            "question_order": original,
        })

        provisioned = self._provision(assessment, applicant)

        self.assertEqual(provisioned, [], "no re-provision")
        self.assertEqual(row.question_order, original,
                         "an existing draw must not be rewritten")

    def test_one_refusal_does_not_block_the_rest_of_the_batch(self):
        """A bulk assign of a mixed batch.

        The method takes a LIST. Raising on a shortfall would abort the whole
        assign transaction - including the roster rows written before this runs -
        so a candidate who cannot be given a full paper must be skipped while
        everybody else is provisioned. With a short pool that means NOBODY is
        provisioned, but the call must still return cleanly rather than raise.
        """
        questions = self.Question.browse()
        for n in range(5):
            questions |= self._question(n)
        assessment = self._running_assessment(questions, limit=20)
        batch = self.Applicant.browse()
        for i in range(3):
            batch |= self._applicant("Batch %d" % i)

        provisioned = self._provision(assessment, batch)

        self.assertEqual(
            provisioned, [],
            "a 5-question pool cannot fill a 20-question paper for anybody")
        # And it returned rather than raising - reaching this line is the test.
        self.assertEqual(
            self.Evaluator.search_count([
                ("assessment_id", "=", assessment.id),
                ("question_order", "!=", False)]), 0)

    # ── S13 (G4-19, R4-04, G4-13): the shared set changed after launch ──

    def _late_on_a_sat_paper(self, questions, limit, sat):
        assessment = self._running_assessment(questions, limit=limit)
        self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": self._applicant("Launch Peer").id,
            "question_order": json.dumps(sat.ids),
        })
        applicant = self._applicant("Late After A Change")
        return assessment, applicant, self._provision(assessment, applicant)

    def test_a_question_archived_from_the_sat_set_refuses_the_late_add(self):
        questions = self.Question.browse()
        for n in range(4):
            questions |= self._question(n)
        gone = questions[:2]
        gone.write({"active": False})

        assessment, applicant, provisioned = self._late_on_a_sat_paper(
            questions, 4, questions)

        self.assertEqual(provisioned, [], "a 2-question copy of a 4-question "
                         "paper was provisioned")
        self.assertEqual(len(self.refused), 1)
        reason = self.refused[0]["reason"]
        self.assertEqual(self.refused[0]["applicant_id"], applicant.id)
        for q in gone:
            self.assertIn(str(q.id), reason)
        self.assertFalse(self.Evaluator.search_count([
            ("assessment_id", "=", assessment.id),
            ("applicant_id", "=", applicant.id),
            ("question_order", "!=", False)]))
        self.assertIn("not provisioned", assessment.message_ids[:1].body)

    def test_a_pool_shrinking_outside_the_sat_set_still_provisions(self):
        questions = self.Question.browse()
        for n in range(6):
            questions |= self._question(n)
        questions[-1].write({"active": False})

        _assessment, _applicant, provisioned = self._late_on_a_sat_paper(
            questions, 4, questions[:4])

        self.assertEqual(self.refused, [])
        self.assertEqual(sorted(json.loads(
            self.Evaluator.browse(provisioned).question_order)),
            sorted(questions[:4].ids))

    def test_the_chatter_states_the_questions_actually_given(self):
        """G4-13: it printed the limit, not the paper."""
        questions = self.Question.browse()
        for n in range(5):
            questions |= self._question(n)

        assessment, _applicant, provisioned = self._late_on_a_sat_paper(
            questions, 5, questions[:3])

        self.assertEqual(len(provisioned), 1)
        self.assertIn("with 3 question(s) each",
                      assessment.message_ids[:1].body)


@tagged("-at_install", "post_install")
class TestAssigningToARunningPaperNeverCrashes(HttpCase):
    """The provisioning's early exits returned a bare [] that the assign route
    unpacks into (launched, refused): a 500 after the roster was written."""

    def setUp(self):
        super().setUp()
        self.authenticate("admin", "admin")
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Empty pool %s" % uuid4().hex[:6]})
        self.paper = self.env["assessments.be"].create({
            "name": "Running %s" % uuid4().hex[:6],
            "generator_id": generator.id,
            "state": "in_progress"})
        self.applicant = self.env["hr.applicant"].create({
            "partner_name": "Late Arrival",
            "email_from": "%s@example.com" % uuid4().hex[:10]})

    def _assign(self):
        response = self.url_open(
            "/api/v1/assessments/%s/assign" % self.paper.id,
            data=json.dumps({"applicant_ids": [self.applicant.id]}),
            headers={"Content-Type": "application/json"}, timeout=30)
        return response.status_code, response.json()

    def test_an_empty_pool(self):
        status, payload = self._assign()
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload["data"]["assigned_count"], 1)
        self.assertEqual(payload["data"]["launched_attempts"], [])

    def test_no_new_applicant(self):
        self.paper.evaluator_ids = [(4, self.applicant.id)]
        status, payload = self._assign()
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload["data"]["already_assigned"], 1)
