# -*- coding: utf-8 -*-
"""What is ticked on Selected Questions is what the candidate actually sits.

THE QUESTION THIS ANSWERS, asked directly: "ensure the actual ticked questions in
selected questions tab go forward in the actual assessment." Everything else
about the shortlist is presentation; this is the only part that decides what a
person is examined on, so it is pinned end to end rather than at the seam.

THE FOUR HOPS, and each one is a place the set could quietly change:

    question_ids  ->  action_start narrows the pool  ->  question_limit draws
                  ->  evaluator.question_order  ->  the exam route serves it

`question_order` is the one that matters: it is written ONCE, at launch, and read
on every subsequent request. So a shortlist that was right at the moment of
launch stays right for the life of the sitting, and a shortlist edited afterwards
cannot reach a candidate. Both halves are asserted.

THE EMPTY SHORTLIST IS NOT AN EMPTY PAPER. `action_start` reads it as "the whole
generator" (`if shortlist:` - falsy skips the narrowing entirely), and
`limit = rec.question_limit or len(available_questions)` then draws all of them.
That is deliberate and it is the state every assessment is created in, so it is
tested first. The client used to disagree: `Gates.launch` sized the paper off the
DRAWN questions, which are empty before launch, so a brand-new assessment
reported "Asked for 0 but only 0 are selected." and refused a launch the server
would have accepted. Fixed client-side in `effectiveQuestionCount`; this file
pins the server behaviour that fix had to mirror.
"""
from uuid import uuid4

from odoo.exceptions import UserError
from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestTheShortlistIsThePaper(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % uuid4().hex[:6]})
        # Six, so a shortlist can be a strict subset AND a limit can be a strict
        # subset of the shortlist - the two narrowings have to be separable or a
        # test cannot tell which one did the work.
        self.questions = self.env["assessments.be.question"]
        for i in range(1, 7):
            self.questions |= self._question("SL Q%d" % i)

    # -- fixtures ---------------------------------------------------------

    def _question(self, name):
        question = self.env["assessments.be.question"].create({
            "name": "%s %s" % (name, uuid4().hex[:4]),
            "question_type": "mcq",
            "prompt": "Pick one.",
            "generator_id": self.generator.id,
            # No `state`: that field is on the DRAFT model
            # (`assessments.be.prompt.question`). A row in the bank is approved
            # by construction - reaching the bank is what approval means.
        })
        self.env["assessments.be.question.dimension"].create({
            "question_id": question.id,
            "name": "Answer",
            "option_line_ids": [
                (0, 0, {"name": n, "sequence": i * 10, "is_correct": i == 0})
                for i, n in enumerate(("Alpha", "Bravo"))],
        })
        return question

    def _applicant(self):
        return self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % uuid4().hex[:6],
            "email_from": "sl_%s@example.com" % uuid4().hex[:8],
        })

    def _draft(self, shortlist=None, limit=0, candidates=1):
        """A launchable draft. `shortlist=None` leaves `question_ids` EMPTY."""
        applicants = self.env["hr.applicant"]
        for _ in range(candidates):
            applicants |= self._applicant()
        values = {
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "duration_minutes": 30,
            "question_limit": limit,
            "evaluator_ids": [(6, 0, applicants.ids)],
        }
        if shortlist is not None:
            values["question_ids"] = [(6, 0, shortlist.ids)]
        return self.Assessment.create(values)

    def _served(self, assessment):
        """The question ids frozen onto each attempt, as a set per candidate."""
        out = []
        for row in assessment.assessment_evaluator_ids:
            order = row.question_order
            if isinstance(order, str):
                import json
                order = json.loads(order or "[]")
            out.append({int(q) for q in (order or [])})
        return out

    # -- group 1: the empty shortlist means the whole generator ------------

    def test_an_untouched_draft_serves_the_whole_generator(self):
        """THE STATE EVERY ASSESSMENT IS CREATED IN, so it has to launch.

        `if shortlist:` is falsy here and the narrowing is skipped, then `limit`
        falls back to the length of what is available.
        """
        assessment = self._draft()
        self.assertFalse(assessment.question_ids, "fixture: nothing ticked")

        assessment.action_start()

        self.assertEqual(self._served(assessment), [set(self.questions.ids)])

    def test_an_untouched_draft_is_not_refused_for_having_no_shortlist(self):
        """The client used to refuse exactly this. The server never did."""
        assessment = self._draft()
        try:
            assessment.action_start()
        except UserError as exc:
            self.fail(
                "a draft with no shortlist must launch against the whole "
                "generator, not be refused: %s" % exc)

    # -- group 2: a shortlist is honoured, exactly -------------------------

    def test_the_ticked_questions_are_the_ones_served(self):
        """THE HEADLINE. Tick three of six; those three are the paper."""
        picked = self.questions[1] | self.questions[3] | self.questions[5]
        assessment = self._draft(shortlist=picked)

        assessment.action_start()

        self.assertEqual(
            self._served(assessment), [set(picked.ids)],
            "the paper must be the shortlist, neither a superset nor a sample "
            "of it")

    def test_an_unticked_question_never_reaches_a_candidate(self):
        """Stated from the other side, because that is the failure that matters:
        a question the operator took out must not be examinable."""
        picked = self.questions[0] | self.questions[1]
        excluded = self.questions - picked
        assessment = self._draft(shortlist=picked)

        assessment.action_start()

        served = self._served(assessment)[0]
        for question in excluded:
            self.assertNotIn(
                question.id, served,
                "%r was unticked and still went out" % question.name)

    def test_a_single_ticked_question_is_a_one_question_paper(self):
        """The smallest legal shortlist. An off-by-one in the narrowing shows up
        here and nowhere else."""
        picked = self.questions[2]
        assessment = self._draft(shortlist=picked)

        assessment.action_start()

        self.assertEqual(self._served(assessment), [{picked.id}])

    # -- group 3: the limit draws FROM the shortlist -----------------------

    def test_the_limit_draws_a_subset_of_the_shortlist(self):
        """Two narrowings, and the order between them is what is being pinned:
        the shortlist selects the eligible set, THEN the limit samples it."""
        picked = self.questions[0] | self.questions[2] | self.questions[4]
        assessment = self._draft(shortlist=picked, limit=2)

        assessment.action_start()

        served = self._served(assessment)[0]
        self.assertEqual(len(served), 2, "the limit decides the SIZE")
        self.assertTrue(
            served <= set(picked.ids),
            "and the shortlist decides the ELIGIBLE SET - a limit that sampled "
            "the whole generator would serve a question the operator excluded")

    def test_a_limit_larger_than_the_shortlist_is_refused_not_topped_up(self):
        """The dangerous alternative is silently making the paper up to size
        from questions that were excluded on purpose."""
        picked = self.questions[0] | self.questions[1]
        assessment = self._draft(shortlist=picked, limit=5)

        with self.assertRaises(UserError) as caught:
            assessment.action_start()

        message = str(caught.exception)
        self.assertIn("5", message, "say what was asked for")
        self.assertIn("2", message, "and what is actually available")

    def test_a_zero_limit_means_the_whole_shortlist(self):
        """0 is "no cap", not "no questions"."""
        picked = self.questions[1] | self.questions[2] | self.questions[3]
        assessment = self._draft(shortlist=picked, limit=0)

        assessment.action_start()

        self.assertEqual(self._served(assessment), [set(picked.ids)])

    # -- group 4: the paper is frozen at launch ---------------------------

    def test_editing_the_shortlist_after_launch_cannot_reach_a_candidate(self):
        """`question_order` is written once. This is what "the paper is fixed"
        means, and it is why the tab goes read-only rather than hiding."""
        picked = self.questions[0] | self.questions[1]
        assessment = self._draft(shortlist=picked)
        assessment.action_start()
        before = self._served(assessment)

        # Straight onto the field, bypassing whatever the API would refuse -
        # the guarantee has to hold at the DATA layer, not only at the route.
        assessment.sudo().write({"question_ids": [(6, 0, self.questions.ids)]})

        self.assertEqual(
            self._served(assessment), before,
            "a sitting already under way must not gain questions - the "
            "candidate agreed to the paper they were given")

    def test_every_candidate_on_a_shared_paper_gets_the_same_questions(self):
        """`same_questions_for_all` is the default, so three candidates must
        receive one identical set - not three independent draws."""
        picked = self.questions[0] | self.questions[2] | self.questions[4]
        assessment = self._draft(shortlist=picked, candidates=3)

        assessment.action_start()

        served = self._served(assessment)
        self.assertEqual(len(served), 3, "fixture: three attempts")
        self.assertEqual(
            served, [set(picked.ids)] * 3,
            "with one shared paper every candidate sits the same shortlist")

    # -- group 5: the shortlist cannot serve something unusable ------------

    def test_archiving_the_whole_shortlist_does_not_widen_the_paper(self):
        """THE BUG THIS FILE FOUND, stated as the damage rather than the message.

        Odoo applies the active filter to an x2many READ, so archiving every
        shortlisted question made `question_ids` read EMPTY - and empty means
        "the whole generator". A paper deliberately narrowed to two questions
        therefore widened to all six the moment somebody archived both, which the
        bank's Archive button does in one click. Silent, and in the direction
        that examines candidates on material nobody selected.
        """
        picked = self.questions[0] | self.questions[1]
        assessment = self._draft(shortlist=picked)
        picked.write({"active": False})

        with self.assertRaises(UserError):
            assessment.action_start()

        self.assertFalse(
            assessment.assessment_evaluator_ids,
            "refusing must leave NO attempt behind - a half-launched "
            "assessment is worse than one that would not start")

    def test_archiving_part_of_the_shortlist_serves_the_survivors(self):
        """The partial case, which must NOT be affected by the fix above.

        Some archived, some live: the live ones are the paper. Reading the
        shortlist with `active_test=False` keeps the archived ids visible as
        INTENT, and `narrowed` then drops them because they are not available -
        so the operator gets the questions that still work rather than a refusal.
        """
        picked = self.questions[0] | self.questions[1] | self.questions[2]
        assessment = self._draft(shortlist=picked)
        self.questions[0].write({"active": False})

        assessment.action_start()

        self.assertEqual(
            self._served(assessment),
            [{self.questions[1].id, self.questions[2].id}],
            "the two survivors are the paper - neither the archived one nor a "
            "top-up from outside the shortlist")

    def test_a_shortlist_of_only_unusable_questions_is_refused_clearly(self):
        """Retiring every shortlisted question leaves a paper that cannot be
        drawn. The refusal has to say what to do about it, because the operator
        cannot see from the tab that the rows have gone stale."""
        picked = self.questions[0] | self.questions[1]
        assessment = self._draft(shortlist=picked)
        picked.write({"active": False})

        with self.assertRaises(UserError) as caught:
            assessment.action_start()

        message = str(caught.exception).lower()
        self.assertIn("shortlist", message)
        self.assertIn(
            "selected questions", message,
            "name the tab - it is the only place the operator can act")
