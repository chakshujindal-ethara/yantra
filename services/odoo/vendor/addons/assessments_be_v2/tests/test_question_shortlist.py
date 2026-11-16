# -*- coding: utf-8 -*-
"""SHORTLISTING: an operator narrows which of a generator's questions a paper
draws, without editing the generator.

THE TWO DEFECTS THIS CLOSES, both silent.

  1. `assessment_detail` sent only `question_ids` ("questions"), and nothing
     writes that field until `action_start`. So the Selected Questions tab on a
     DRAFT listed nothing at all over a generator holding twenty, and no client
     could name a single question the draft would draw. `assessment_pool` now
     sends the CHOICE beside the pick.

  2. `action_start` overwrote `question_ids` with the whole servable pool. A
     shortlist stored on the draft was therefore discarded at launch and the
     cohort sat every question - the exact opposite of what the operator asked
     for, with no error and no log line. It now NARROWS to the shortlist.

The property under test is AGREEMENT between three readers of the same field -
the serializer that shows the ticks, `action_start` which draws the paper, and
`_launch_gates` which promises in advance that it can. All three read an empty
`question_ids` as "the whole generator", and a test that pinned only one of them
would not notice the other two drifting.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.exceptions import UserError
from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.controllers.api import admin as admin_api
from odoo.addons.assessments_be_v2.controllers.api import common as api_common
from odoo.addons.assessments_be_v2.controllers.api import serializers as S


class _StubRequest:
    """The slice of `odoo.http.request` the launch dry run touches.

    Same stub as `test_authored_question_marks`, and for the same reason: the
    dry run needs `request.env` and `request.params` and nothing else, so this
    stays a TransactionCase rather than buying a session and a port.
    """

    def __init__(self, env, params=None):
        self.env = env
        self.params = dict(params or {})

    def make_json_response(self, payload, headers=None, status=200):
        return {"ok": False, "status": status, "payload": payload}


@tagged("-at_install", "post_install")
class TestQuestionShortlist(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Question = self.env["assessments.be.question"]
        self.QDim = self.env["assessments.be.question.dimension"]
        self.Generator = self.env["assessments.be.prompt"]
        # The launch route is gated on the Admin group. Granted from the GROUP
        # side so this does not depend on the name of the users-side m2m.
        self.env.ref(
            "assessments_be_v2.group_assessment_manager"
        ).sudo().write({"user_ids": [(4, self.env.user.id)]})

    # -- fixtures ---------------------------------------------------------

    def _applicant(self):
        slug = uuid4().hex[:8]
        return self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % slug,
            "email_from": "cand_%s@example.com" % slug,
        })

    def _question(self, generator, name):
        """A KEYED mcq, so no fixture ever trips the answer-key gate and a
        failure below can only be about the shortlist."""
        question = self.Question.create({
            "name": name,
            "question_type": "mcq",
            "prompt": "Pick one.",
            "generator_id": generator.id,
        })
        self.QDim.create({
            "question_id": question.id,
            "name": "Answer",
            "option_line_ids": [
                (0, 0, {"name": opt, "sequence": i * 10, "is_correct": i == 0})
                for i, opt in enumerate(("Alpha", "Bravo"))
            ],
        })
        return question

    def _draft(self, count=4, limit=0):
        generator = self.Generator.create({"name": "Gen %s" % uuid4().hex[:6]})
        questions = self.Question.browse()
        for i in range(count):
            questions |= self._question(generator, "Q%d %s" % (i, uuid4().hex[:4]))
        assessment = self.Assessment.create({
            "name": "Shortlist %s" % uuid4().hex[:6],
            "generator_id": generator.id,
            "question_limit": limit,
            "duration_minutes": 30,
            "evaluator_ids": [(6, 0, [self._applicant().id])],
        })
        assessment._sync_roster_rows()
        assessment.invalidate_recordset()
        return assessment, questions

    def _pool(self, assessment):
        """{name: in_use} out of the serializer, which is what the tab reads."""
        return {
            row["name"]: row["in_use"]
            for row in S.assessment_detail(assessment)["pool"]
        }

    def _gates(self, assessment):
        stub = _StubRequest(self.env, {"assessment_id": assessment.id})
        controller = admin_api.EtpAssessmentApiAdmin()
        with patch.object(admin_api, "request", stub), \
                patch.object(api_common, "request", stub):
            response = controller.assessment_launch(assessment.id)
        self.assertTrue(response.get("ok"), "dry run must answer ok; got %r"
                        % (response,))
        self.assertFalse(response["data"]["launched"],
                         "a dry run must never launch - `confirm` was not passed")
        return {g["code"]: g for g in response["data"]["gates"]}

    # -- group 1: the serializer shows the CHOICE, not only the pick -------

    def test_a_draft_pool_lists_the_generator_even_with_nothing_selected(self):
        """The bug outright: `question_ids` is empty on a draft, so the tab used
        to render an empty list over a generator holding four questions."""
        assessment, questions = self._draft()
        self.assertFalse(
            assessment.question_ids,
            "the fixture must start with no selection, or this proves nothing")
        detail = S.assessment_detail(assessment)
        self.assertEqual(
            detail["questions"], [],
            "`questions` is the PICK and is genuinely empty before launch - "
            "this test exists because that was the only key being sent")
        self.assertEqual(
            sorted(self._pool(assessment)), sorted(questions.mapped("name")),
            "the pool must be the generator's servable set")

    def test_an_empty_selection_reads_as_every_question_in_use(self):
        """"Nothing shortlisted" means the whole generator, not an empty paper -
        the same reading `action_start` applies. Anything else would show every
        row greyed out on a draft nobody had touched."""
        assessment, _questions = self._draft()
        self.assertTrue(
            all(self._pool(assessment).values()),
            "an untouched draft must come back fully in use")

    def test_a_shortlist_is_reflected_tick_for_tick(self):
        assessment, questions = self._draft()
        keep = questions[:2]
        assessment.write({"question_ids": [(6, 0, keep.ids)]})
        pool = self._pool(assessment)
        self.assertEqual(
            {name for name, on in pool.items() if on},
            set(keep.mapped("name")),
            "exactly the shortlisted questions must be ticked")
        self.assertEqual(
            len(pool), 4,
            "an EXCLUDED question must stay listed - hiding it leaves no way "
            "to put it back")

    def test_a_shortlisted_question_that_left_the_pool_stays_visible(self):
        """Retiring a ticked question drops it from the generator search. Left
        there, it would vanish from the tab while remaining in `question_ids`,
        and the launch would draw a paper the operator was never shown."""
        assessment, questions = self._draft()
        assessment.write({"question_ids": [(6, 0, questions.ids)]})
        questions[0].write({"retired": True})
        pool = self._pool(assessment)
        self.assertIn(
            questions[0].name, pool,
            "a retired but still-shortlisted question must stay on the tab")
        self.assertTrue(pool[questions[0].name])

    def test_with_no_generator_the_pool_is_whatever_is_selected(self):
        """No generator, no choice to offer. The tab falls back to the selection
        rather than inventing one - and on a fresh draft that is empty, which is
        what the tab's own empty state is written for."""
        assessment = self.Assessment.create({
            "name": "Bare %s" % uuid4().hex[:6],
            "duration_minutes": 30,
        })
        self.assertEqual(S.assessment_detail(assessment)["pool"], [])

    def test_once_launched_an_excluded_question_is_still_listed_unticked(self):
        """A LAUNCHED PAPER SHOWS WHAT IT DECLINED TO DRAW.

        Reported from production: 9 questions in the generator, the operator
        un-ticked one and launched with 8. The tab then listed 8 rows and the
        ninth was gone - indistinguishable from a question that never existed,
        on the one screen whose whole job is to record which questions this
        paper draws and which it does not.

        The excluded row stays, unticked. The client renders every tick inert
        once launched, so this exposes a record and not a control."""
        assessment, questions = self._draft(limit=2)
        assessment.write({"question_ids": [(6, 0, questions[:3].ids)]})
        assessment.action_start()
        assessment.invalidate_recordset()
        pool = self._pool(assessment)

        self.assertEqual(
            sorted(pool), sorted(questions.mapped("name")),
            "every question the generator offered must still be listed after "
            "launch, not only the ones that were drawn")
        for q in questions[:3]:
            self.assertTrue(
                pool[q.name],
                "a question this paper draws must read as in use")
        for q in questions[3:]:
            self.assertFalse(
                pool[q.name],
                "a question the operator excluded must read as NOT in use "
                "rather than disappearing from the tab")

    # -- group 2: the launch DRAWS the shortlist ---------------------------

    def test_launch_narrows_question_ids_to_the_shortlist(self):
        """THE DEFECT. `action_start` wrote the whole servable pool over
        `question_ids`, so a shortlist of two out of four was discarded and the
        cohort sat all four."""
        assessment, questions = self._draft(limit=0)
        keep = questions[:2]
        assessment.write({"question_ids": [(6, 0, keep.ids)]})
        assessment.action_start()
        assessment.invalidate_recordset()
        self.assertEqual(
            set(assessment.question_ids.ids), set(keep.ids),
            "the launched paper must be the shortlist, not the generator")

    def test_every_candidate_draws_only_shortlisted_questions(self):
        """The field is one thing; what a candidate is actually served is
        another. `question_order` is the frozen per-candidate paper."""
        import json
        assessment, questions = self._draft(limit=0)
        keep = questions[:2]
        assessment.write({"question_ids": [(6, 0, keep.ids)]})
        assessment.action_start()
        assessment.invalidate_recordset()
        for row in assessment.assessment_evaluator_ids:
            order = set(json.loads(row.question_order or "[]"))
            self.assertTrue(
                order,
                "a launched candidate must have a paper")
            self.assertFalse(
                order - set(keep.ids),
                "a candidate was served a question the operator excluded: %r"
                % (sorted(order - set(keep.ids)),))

    def test_an_empty_shortlist_still_draws_the_whole_generator(self):
        """The serializer's default and the launch must agree, or the screen
        ticks one set and the launch draws another."""
        assessment, questions = self._draft(limit=0)
        assessment.action_start()
        assessment.invalidate_recordset()
        self.assertEqual(
            set(assessment.question_ids.ids), set(questions.ids))

    def test_a_limit_above_the_shortlist_is_refused(self):
        """Four in the generator, two shortlisted, four requested. Before the
        narrowing this launched and quietly served the excluded pair."""
        assessment, questions = self._draft(limit=4)
        assessment.write({"question_ids": [(6, 0, questions[:2].ids)]})
        with self.assertRaises(UserError) as caught:
            assessment.action_start()
        self.assertIn("only 2 available", str(caught.exception))

    def test_a_shortlist_with_nothing_usable_left_is_named_as_the_blocker(self):
        """Attributing this to the generator sends the operator to fix the wrong
        screen: the generator is full, and every servable question in it was
        excluded or retired by hand."""
        assessment, questions = self._draft(limit=0)
        assessment.write({"question_ids": [(6, 0, questions[:1].ids)]})
        questions[0].write({"retired": True})
        with self.assertRaises(UserError) as caught:
            assessment.action_start()
        message = str(caught.exception)
        self.assertIn("shortlisted", message,
                      "the refusal must name the shortlist, got %r" % (message,))
        self.assertIn("Selected Questions", message,
                      "and say which screen to fix it on, got %r" % (message,))

    def test_an_excluded_keyless_question_no_longer_blocks_the_launch(self):
        """The narrowing has to happen BEFORE the answer-key gate. A broken
        question the operator had already taken out of the paper used to sink
        the launch of a paper it was not in."""
        assessment, questions = self._draft(limit=0)
        broken = self.Question.create({
            "name": "Keyless %s" % uuid4().hex[:4],
            "question_type": "mcq",
            "prompt": "There is nothing here to answer.",
            "generator_id": assessment.generator_id.id,
        })
        self.assertTrue(
            broken._keyless_reason(),
            "the fixture must really be keyless, or this proves nothing")
        assessment.write({"question_ids": [(6, 0, questions.ids)]})
        assessment.action_start()
        assessment.invalidate_recordset()
        self.assertNotIn(broken.id, assessment.question_ids.ids)

    # -- group 3: the dry run must not promise what the launch refuses ----

    def test_the_dry_run_counts_the_shortlist_not_the_generator(self):
        """A gate that disagrees with the launch is worse than no gate: it
        spends the operator's confidence before it wastes their time."""
        assessment, questions = self._draft(limit=4)
        assessment.write({"question_ids": [(6, 0, questions[:2].ids)]})
        gates = self._gates(assessment)
        self.assertFalse(
            gates["question_limit"]["passed"],
            "four requested against a shortlist of two must FAIL the gate; "
            "reason was %r" % (gates["question_limit"]["reason"],))
        self.assertIn("shortlist", gates["question_limit"]["reason"])
        # The other half of the agreement, on the same record.
        with self.assertRaises(UserError):
            assessment.action_start()

    def test_a_shortlist_that_fits_passes_every_gate(self):
        """Guard the guard. If the fixture failed some unrelated gate, the case
        above would prove nothing about the shortlist."""
        assessment, questions = self._draft(limit=2)
        assessment.write({"question_ids": [(6, 0, questions[:2].ids)]})
        gates = self._gates(assessment)
        failing = [code for code, g in gates.items() if not g["passed"]]
        self.assertEqual(
            failing, [],
            "a shortlist of two with a limit of two must be launchable; these "
            "gates failed: %r" % ([gates[c]["reason"] for c in failing],))
        assessment.action_start()

    def test_the_dry_run_names_the_shortlist_when_nothing_in_it_is_usable(self):
        assessment, questions = self._draft(limit=0)
        assessment.write({"question_ids": [(6, 0, questions[:1].ids)]})
        questions[0].write({"retired": True})
        gates = self._gates(assessment)
        self.assertFalse(gates["questions_available"]["passed"])
        self.assertIn("shortlisted", gates["questions_available"]["reason"])
