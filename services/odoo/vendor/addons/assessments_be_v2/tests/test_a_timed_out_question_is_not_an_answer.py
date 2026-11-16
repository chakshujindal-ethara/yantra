# -*- coding: utf-8 -*-
"""What the clock took away is not the candidate's answer (audit
pm-ux-candidate-1 / -2), and the invitation says what sitting it invites you to
(pm-ux-candidate-16).

WHEN AN ATTEMPT SETTLES, `_auto_submit_expired` writes one Response per
unanswered question carrying "[Auto-submitted: time expired]" in
`justification`, state `submitted`, score 0. The released answer sheet must
not print that bracketed system string back as "Your answer", nor label such
an mcq/msq row "Incorrect": a question the clock took away was never seen.
"""
from datetime import datetime
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import serializers as S


@tagged("-at_install", "post_install")
class TestATimedOutQuestionIsNotAnAnswer(TransactionCase):

    def setUp(self):
        super().setUp()
        self.paper = self.env["assessments.be"].create(
            {"name": "Timed out %s" % uuid4().hex[:6]})
        self.applicant = self.env["hr.applicant"].create(
            {"partner_name": "Asha %s" % uuid4().hex[:4]})
        self.evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.paper.id,
            "applicant_id": self.applicant.id,
            "state": "submitted",
        })

    def _row(self, question, response):
        return S.released_answer_review_row(1, question, response, "tok")

    def _answer(self, question, **vals):
        return self.env["assessments.be.response"].create(dict({
            "assessment_id": self.paper.id,
            "assessment_evaluator_id": self.evaluator.id,
            "evaluator_id": self.applicant.id,
            "question_id": question.id,
            "state": "submitted",
        }, **vals))

    def _written(self):
        return self.env["assessments.be.question"].create({
            "name": "Explain %s" % uuid4().hex[:4],
            "question_type": "subjective_rubric",
            "prompt": "Explain the failure.",
        })

    def _mcq(self):
        question = self.env["assessments.be.question"].create({
            "name": "Pick %s" % uuid4().hex[:4],
            "question_type": "mcq",
            "prompt": "Choose one.",
        })
        self.env["assessments.be.question.dimension"].create({
            "question_id": question.id, "name": "Answer",
            "option_line_ids": [
                (0, 0, {"name": "Yes", "is_correct": True}),
                (0, 0, {"name": "No", "is_correct": False}),
            ]})
        question.invalidate_recordset()
        return question

    def test_the_placeholder_is_not_printed_back_as_their_answer(self):
        question = self._written()
        placeholder = self._answer(
            question, justification="[Auto-submitted: time expired]",
            auto_submitted=True, llm_state="not_needed")

        row = self._row(question, placeholder)

        self.assertEqual(
            row["justification"], "",
            "the client renders any non-empty justification under 'Your "
            "answer'; the system's own placeholder must not appear there")
        self.assertEqual(row["verdict"], "Not answered")
        self.assertEqual(row["kind"], "info")

    def test_a_real_written_answer_is_untouched(self):
        question = self._written()
        answer = self._answer(
            question, justification="The weld is cracked at the toe.")

        row = self._row(question, answer)

        self.assertEqual(row["justification"],
                         "The weld is cracked at the toe.")

    def test_a_question_the_clock_took_away_is_not_marked_incorrect(self):
        question = self._mcq()
        placeholder = self._answer(
            question, auto_submitted=True, llm_state="not_needed")

        row = self._row(question, placeholder)

        self.assertEqual(
            row["verdict"], "Not answered",
            "an expiry placeholder IS a response with score 0, so it used to "
            "fall through to the final else and read 'Incorrect'")
        self.assertEqual(row["kind"], "info",
                         "'fail' paints it red beside the correct answer")

    def test_a_genuinely_wrong_choice_is_still_incorrect(self):
        question = self._mcq()
        wrong = self._answer(question, llm_state="not_needed")

        row = self._row(question, wrong)

        self.assertEqual(row["verdict"], "Incorrect")
        self.assertEqual(row["kind"], "fail")


@tagged("-at_install", "post_install")
class TestTheInvitationSaysWhatItInvitesYouTo(TransactionCase):
    """The invitation states the window (IST) and the time limit, and names
    neither the question generator nor "Odoo credentials". It shows no pass
    mark and no proctoring rules (owner, 2026-09-29): the candidate app shows
    the rules on the start screen."""

    def _rendered(self, **paper_vals):
        paper = self.env["assessments.be"].create(dict({
            "name": "Invited %s" % uuid4().hex[:6],
            "duration_minutes": 45,
            "subjective_threshold": 50,
            "pass_threshold": 60,
        }, **paper_vals))
        applicant = self.env["hr.applicant"].create(
            {"partner_name": "Asha", "email_from": "asha@example.com"})
        evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": paper.id, "applicant_id": applicant.id})
        self.paper, self.evaluator = paper, evaluator
        return self._field("body_html")

    def _field(self, name):
        template = self.env.ref(
            "assessments_be_v2.mail_template_candidate_invitation")
        return template._render_field(
            name, self.evaluator.ids)[self.evaluator.id]

    def test_it_renders_and_speaks_to_the_candidate(self):
        body = self._rendered()

        self.assertIn("45", body, "the time limit is the thing they plan around")
        self.assertIn("Ethara account", body)
        self.assertNotIn("Odoo credentials", body)
        self.assertNotIn("Question Generator", body,
                         "an internal authoring artifact")

    def test_it_lists_no_proctoring_rules(self):
        body = self._rendered(
            rule_webcam=True, rule_fullscreen=True, rule_block_tab_switch=True,
            rule_block_copy_paste=True, rule_block_right_click=True,
            rule_block_devtools=True, rule_watermark=True,
            violation_action="log_only", max_violations=5)
        for text in ("proctored", "camera", "fullscreen", "right-click",
                     "developer tools", "Violation limit breached"):
            self.assertNotIn(text, body)

    # ── S9 / Q11 (G2-11, G2-12, F3-23, B5-13) ─────────────────────────────

    def test_the_window_is_in_ist(self):
        body = self._rendered(start_date=datetime(2099, 9, 23, 11, 22, 28),
                              end_date=datetime(2099, 9, 25, 12, 22, 28))
        self.assertIn("23 Sep 2099, 4:52 PM</span> IST", body)
        self.assertIn("25 Sep 2099, 5:52 PM</span> IST", body)
        self.assertNotIn("UTC", body)

    def test_it_does_not_show_the_pass_mark(self):
        body = self._rendered(subjective_threshold=55, pass_threshold=80)
        self.assertNotIn("Pass mark", body)
        self.assertNotIn("80</span>%", body)
        self.assertNotIn("55</span>%", body)

    def test_the_clock_starts_on_start_assessment(self):
        body = self._rendered()
        self.assertIn("<b>Before you start:</b> The clock starts when you "
                      "press Start Assessment", body)
        self.assertNotIn("when you open the assessment", body)

    def test_first_timers_are_told_to_set_a_password(self):
        self.assertIn("First time? Use Default password provided by host or "
                      "Forgot password to set one.", self._rendered())

    def test_it_comes_from_no_reply_and_replies_go_to_the_creator(self):
        self._rendered()
        self.paper.create_uid.partner_id.email = "maker_%s@example.com" % (
            uuid4().hex[:6])
        self.assertEqual(self._field("email_from"), "no-reply@ethara.ai")
        self.assertEqual(self._field("reply_to"),
                         self.paper.create_uid.email_formatted)
        self.assertIn(self.paper.create_uid.email, self._field("reply_to"))
