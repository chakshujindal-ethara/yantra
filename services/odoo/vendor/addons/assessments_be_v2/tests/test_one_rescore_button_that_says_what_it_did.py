# -*- coding: utf-8 -*-
"""The candidate and answer screens tell the truth about re-scoring.

* swe-odoo-ui-9 / pm-ux-admin-9 - the attempt form has ONE re-score button
  (`action_rescore_individually`), labelled with the count of answers it would
  queue, hidden at zero, and Admin-only (it spends model calls); a released
  attempt gets the same button with a confirm.
* pm-ux-admin-3 - a queued re-score (`rescore_request_key`) is visible on both
  screens it is requested from, and the answer's button is withdrawn while one
  is queued.
* swe-api-models-9 - "Re-score This Answer" on a RELEASED attempt asks first:
  it spends a model call and can move a mark the candidate is looking at (the
  bulk requeue route demands `force: true` for the same reason).
* pm-ux-admin-6 - a failed re-grade, a capped deferral and a kill write their
  reason to `evaluator.llm_error`, which the attempt form and the roster show.
* pm-ux-admin-15 - the Kill confirm warns that it drops every queued
  individual re-score.
"""
from uuid import uuid4

from lxml import etree

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestOneRescoreButtonThatSaysWhatItDid(TransactionCase):

    def setUp(self):
        super().setUp()
        # The manager group, because `get_view` strips a `groups=` button the
        # reading user cannot press - and the whole point of this file is that
        # one of those buttons exists.
        self.env.user.group_ids |= self.env.ref(
            "assessments_be_v2.group_assessment_manager")
        self.assessment = self.env["assessments.be"].create(
            {"name": "Re %s" % uuid4().hex[:6]})
        self.question = self.env["assessments.be.question"].create({
            "name": "Written %s" % uuid4().hex[:6],
            "question_type": "subjective_rubric",
            "prompt": "Explain your reasoning.",
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Rescore Subject",
            "email_from": "rs_%s@example.com" % uuid4().hex[:8],
        })
        self.evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.assessment.id,
            "applicant_id": applicant.id,
            "state": "submitted",
        })
        self.answer = self.env["assessments.be.response"].create({
            "assessment_id": self.assessment.id,
            "assessment_evaluator_id": self.evaluator.id,
            "evaluator_id": applicant.id,
            "question_id": self.question.id,
            "state": "submitted",
            "justification": "some prose",
            "llm_state": "pending",
        })

    def _arch(self, xmlid, model, view_type="form"):
        view = self.env.ref("assessments_be_v2.%s" % xmlid)
        return etree.fromstring(
            self.env[model].get_view(view.id, view_type)["arch"])

    # ── one button, counted, hidden at zero ────────────────────────────────

    def test_the_attempt_form_offers_one_rescore_control_per_case(self):
        """Two buttons remain, and they are not the old pair: one is the
        plain click, the other is the SAME act on a released attempt, which
        needs a confirmation a static `confirm=` cannot make conditional.
        Exactly one of them is ever visible."""
        arch = self._arch("assessments_be_evaluator_form",
                          "assessments.be.evaluator")
        buttons = arch.xpath("//header//button"
                             "[@name='action_rescore_individually']")
        self.assertEqual(len(buttons), 2)
        plain = [b for b in buttons if not b.get("confirm")]
        confirming = [b for b in buttons if b.get("confirm")]
        self.assertEqual(len(plain), 1)
        self.assertEqual(len(confirming), 1)
        self.assertIn("or results_released", plain[0].get("invisible") or "")
        self.assertIn("not results_released",
                      confirming[0].get("invisible") or "")
        self.assertIn("rescore_confirm_released",
                      confirming[0].get("context") or "",
                      "without the flag the model refuses a released attempt "
                      "outright, so the confirmed click would do nothing")

    def test_that_button_is_manager_only_and_counted(self):
        # `groups=` is resolved away by `get_view`, so the gate is read from
        # the stored arch; everything else is read from the rendered one.
        raw = etree.fromstring(self.env.ref(
            "assessments_be_v2.assessments_be_evaluator_form").arch)
        for stored in raw.xpath("//header//button"
                                "[@name='action_rescore_individually']"):
            self.assertIn(
                "group_assessment_manager", stored.get("groups") or "",
                "a read-only manager was offered a spend button that fails "
                "on write")
        arch = self._arch("assessments_be_evaluator_form",
                          "assessments.be.evaluator")
        for button in arch.xpath("//header//button"
                                 "[@name='action_rescore_individually']"):
            self.assertTrue(button.xpath(".//field[@name='rescore_label']"))
            self.assertIn(
                "unresolved_answer_count", button.get("invisible") or "",
                "it must be gone when there is nothing it could do")

    def test_the_label_counts_the_answers_it_would_queue(self):
        self.evaluator.invalidate_recordset()
        self.assertEqual(self.evaluator.unresolved_answer_count, 1)
        self.assertEqual(self.evaluator.rescore_label, "Re-score 1 answer(s)")
        self.answer.write({"llm_state": "scored"})
        self.evaluator.invalidate_recordset()
        self.assertEqual(self.evaluator.unresolved_answer_count, 0,
                         "a fully scored attempt offers nothing to re-score")

    # ── a queued re-score is visible ───────────────────────────────────────

    def test_the_queued_count_is_readable_on_the_attempt(self):
        self.answer.write({"rescore_request_key": uuid4().hex})
        self.evaluator.invalidate_recordset()
        self.assertEqual(self.evaluator.rescore_queued_count, 1)

    def test_both_screens_show_that_a_rescore_is_queued(self):
        attempt = self._arch("assessments_be_evaluator_form",
                             "assessments.be.evaluator")
        self.assertTrue(
            attempt.xpath("//*[@invisible='rescore_queued_count == 0']"),
            "the attempt form says nothing about a queued re-score")
        answer = self._arch("assessments_be_response_form",
                            "assessments.be.response")
        self.assertIn(
            "rescore_request_key",
            etree.tostring(answer, encoding="unicode"),
            "the answer form says nothing about a queued re-score")

    def test_the_answer_button_is_withdrawn_while_one_is_queued(self):
        answer = self._arch("assessments_be_response_form",
                            "assessments.be.response")
        buttons = answer.xpath("//button[@name='action_rescore_this_answer']")
        self.assertTrue(buttons)
        for button in buttons:
            self.assertIn("rescore_request_key",
                          button.get("invisible") or "",
                          "pressing it again while one is queued tells the "
                          "admin nothing new")

    # ── a released mark is confirmed before it is re-scored ────────────────

    def test_rescoring_a_released_answer_asks_first(self):
        answer = self._arch("assessments_be_response_form",
                            "assessments.be.response")
        buttons = answer.xpath("//button[@name='action_rescore_this_answer']")
        confirming = [b for b in buttons if b.get("confirm")]
        self.assertTrue(
            confirming,
            "no button warns that this answer's mark has been released")
        button = confirming[0]
        self.assertIn("not attempt_released", button.get("invisible") or "",
                      "the warning belongs to the released case only")
        text = button.get("confirm")
        self.assertIn("model call", text,
                      "the confirm has to name the cost")
        self.assertIn("RELEASED", text)
        self.assertIn("rescore_confirm_released", button.get("context") or "",
                      "the confirmed click has to carry the model's flag or "
                      "it is refused for a released attempt")

    def test_the_answer_buttons_context_survives_the_hop(self):
        """`action_rescore_this_answer` is a one-line delegate to the attempt,
        so the button's `rescore_confirm_released` has to arrive there - that
        flag is what the model checks before re-grading a mark the candidate
        can already see. A `with_context` dropped anywhere on the way would
        turn a confirmed click into a refusal."""
        seen = {}
        Evaluator = type(self.env["assessments.be.evaluator"])
        original = Evaluator.action_rescore_individually

        def spy(evaluator, question_ids=None, *args, **kwargs):
            seen["flag"] = evaluator.env.context.get(
                "rescore_confirm_released")
            return original(evaluator, question_ids, *args, **kwargs)

        self.patch(Evaluator, "action_rescore_individually", spy)
        self.answer.with_context(
            rescore_confirm_released=True).action_rescore_this_answer()
        self.assertTrue(seen.get("flag"))

    def test_the_plain_button_is_hidden_once_results_are_released(self):
        answer = self._arch("assessments_be_response_form",
                            "assessments.be.response")
        plain = [b for b in
                 answer.xpath("//button[@name='action_rescore_this_answer']")
                 if not b.get("confirm")]
        self.assertEqual(len(plain), 1)
        self.assertIn("attempt_released", plain[0].get("invisible") or "")

    def test_the_answer_knows_whether_its_attempt_was_released(self):
        self.assertFalse(self.answer.attempt_released)
        self.evaluator.results_released = True
        self.answer.invalidate_recordset()
        self.assertTrue(self.answer.attempt_released)

    # ── the grader's own reason reaches a screen ───────────────────────────

    def test_the_attempt_form_shows_the_scoring_error(self):
        arch = self._arch("assessments_be_evaluator_form",
                          "assessments.be.evaluator")
        self.assertTrue(
            arch.xpath("//field[@name='llm_error']"),
            "the reason a re-grade failed or a candidate is waiting on the "
            "spend cap is written to llm_error and shown nowhere")

    def test_the_roster_can_show_the_scoring_error(self):
        arch = self._arch("assessments_be_form", "assessments.be")
        self.assertTrue(arch.xpath("//field[@name='llm_error']"))

    # ── the kill dialog warns about what it drops ──────────────────────────

    def test_the_kill_confirm_warns_that_queued_rescores_are_dropped(self):
        arch = self._arch("assessments_be_form", "assessments.be")
        button = arch.xpath("//button[@name='action_kill_scoring']")[0]
        self.assertIn("re-score", (button.get("confirm") or "").lower(),
                      "killing a run silently drops every queued individual "
                      "re-score; the dialog has to say so beforehand")

    def test_a_kill_really_does_drop_them(self):
        """The behaviour the warning describes, so the two cannot drift."""
        self.answer.write({"rescore_request_key": uuid4().hex})
        self.evaluator.write({"scoring_requested": True,
                              "llm_state": "pending"})
        self.assessment.action_kill_scoring()
        self.answer.invalidate_recordset()
        self.assertFalse(self.answer.rescore_request_key)
