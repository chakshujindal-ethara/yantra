# -*- coding: utf-8 -*-
"""Defects the 2026-09-25 admin product test found, one test each.

Each test fails on the code before its fix. The candidate-side ones live in
`test_a_typed_in_candidate_needs_a_real_address` (messy addresses) and
`test_an_exam_must_be_begun_before_it_is_answered` (the skipped timer).
"""
import base64
from unittest.mock import patch
from uuid import uuid4

from freezegun import freeze_time
from lxml import etree

from odoo.exceptions import UserError, ValidationError
from odoo.tests.common import TransactionCase, tagged
from odoo.tools.safe_eval import safe_eval

from ..controllers.api import admin as api_admin
from ..controllers.api import common as api_common
from ..controllers.api import serializers as S
from ..controllers.api import write as W
from ._paging_harness import RequestStub, call_route, status_of

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"


@tagged("-at_install", "post_install")
class TestWhatTheAdminProductTestFound(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Found %s" % uuid4().hex[:6]})

    def _paper(self, **vals):
        return self.env["assessments.be"].create(dict({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id, "duration_minutes": 30,
        }, **vals))

    def _attempt(self, paper, **vals):
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % uuid4().hex[:4],
            "email_from": "%s@example.com" % uuid4().hex[:10]})
        return self.env["assessments.be.evaluator"].create(dict({
            "assessment_id": paper.id, "applicant_id": applicant.id,
        }, **vals))

    def _write(self, method, path=None, **params):
        return call_route(W, W.EtpAssessmentApiWrite(), method, self.env,
                          path=path, **params)

    # 2. A cancelled paper mailed its queued candidates.
    def test_a_cancelled_paper_mails_nobody(self):
        paper = self._paper(state="in_progress")
        ev = self._attempt(paper, invite_state="queued")
        paper.action_cancel()
        Mail = self.env["mail.mail"].sudo()
        before = Mail.search_count([("res_id", "=", ev.id),
                                    ("model", "=", ev._name)])
        with patch.object(self.env.cr, "commit", lambda: None):
            ev._cron_send_pending_invitations(batch=200)
        self.assertTrue(ev._deliver_invitation(), "a send was not refused")
        self.assertEqual(Mail.search_count([("res_id", "=", ev.id),
                                            ("model", "=", ev._name)]),
                         before, "a cancelled paper created a mail")
        self.assertEqual(ev.invite_state, "queued")
        with self.assertRaises(UserError):
            paper.action_requeue_all_invitations()
        out = self._write("attempt_resend", path={"evaluator_id": ev.id})
        self.assertEqual(status_of(out), 409, out)
        # 17: the whole-paper resend refuses the same way.
        out = self._write("assessment_resend_all",
                          path={"assessment_id": paper.id})
        self.assertEqual((status_of(out), out["error"]["code"]),
                         (409, "assessment_closed"), out)

    # 3. An unknown Selection value was a 500.
    def test_an_unknown_choice_is_a_422_naming_the_field(self):
        out = self._write("assessment_create", name="Bogus",
                          violation_action="bogus")
        self.assertEqual((status_of(out), out["error"]["code"]),
                         (422, "invalid"), out)
        self.assertEqual(out["field"], "violation_action")
        # 20: the labels, not the raw codes.
        self.assertIn("Log violation only", out["error"]["message"])
        self.assertNotIn("log_only", out["error"]["message"])
        paper = self._paper()
        for field in ("violation_action", "results_release"):
            out = self._write("assessment_update",
                              path={"assessment_id": paper.id},
                              **{field: "bogus"})
            self.assertEqual(status_of(out), 422, (field, out))
            self.assertEqual(out["field"], field)

    # 4. Release Results released a pending, never-submitted attempt.
    def test_release_skips_an_attempt_never_submitted(self):
        paper = self._paper(state="in_progress")
        pending = self._attempt(paper)
        submitted = self._attempt(paper, state="submitted")
        (pending | submitted).action_release_results()
        self.assertFalse(pending.results_released)
        self.assertTrue(submitted.results_released)

    # 5. A negative violation limit was stored.
    def test_a_negative_violation_limit_is_refused(self):
        out = self._write("assessment_create", name="Neg",
                          max_violations=-3)
        self.assertEqual((status_of(out), out["error"]["code"]),
                         (422, "invalid"), out)
        paper = self._paper()
        out = self._write("assessment_update",
                          path={"assessment_id": paper.id}, max_violations=-3)
        self.assertEqual(status_of(out), 422, out)
        with self.assertRaises(ValidationError):
            paper.max_violations = -3

    # 6. `badge` on a Boolean warned on every form load.
    def test_no_badge_widget_on_a_boolean(self):
        views = self.env["ir.ui.view"].search([
            ("model", "like", "assessments.be"), ("type", "!=", "qweb")])
        for view in views:
            for node in etree.fromstring(view.arch).iter("field"):
                if node.get("widget") != "badge":
                    continue
                parent = next((a for a in node.iterancestors("field")), None)
                model = (self.env[view.model]._fields[parent.get("name")]
                         .comodel_name if parent is not None else view.model)
                field = self.env[model]._fields[node.get("name")]
                self.assertNotEqual(field.type, "boolean",
                                    "%s: %s" % (view.xml_id, field.name))

    # 7. "That file is 25.0 MB. The limit is 25 MB." read as equal.
    def test_just_over_the_limit_never_reads_as_equal(self):
        fake = RequestStub(self.env, {})
        with patch.object(api_common, "request", fake):
            out = W._too_large("x" * (1398104), limit=1048576)
        self.assertIn("is 1.1 MB. The limit is 1.0 MB.",
                      out["error"]["message"])

    # 10. The dashboard counted held results as released outcomes.
    def test_the_dashboard_outcomes_are_released_ones(self):
        paper = self._paper(state="in_progress")
        released = self._attempt(paper, state="submitted")
        held = self._attempt(paper, state="submitted")
        released.results_released = True
        # `result` is a stored compute with no answers to derive "pass" from,
        # so it is set under the ORM once nothing is left to recompute.
        self.env.flush_all()
        self.env.cr.execute(
            "UPDATE assessments_be_evaluator SET result = 'pass' "
            "WHERE id IN %s", [(released | held)._ids])
        self.env.invalidate_all()
        data = call_route(api_admin, api_admin.EtpAssessmentApiAdmin(),
                          "analytics", self.env,
                          assessment_id=paper.id)["data"]
        totals = data["totals"]
        self.assertEqual((totals["decided"], totals["passed"],
                          totals["awaiting_result"]), (1, 1, 1), totals)
        self.assertEqual(data["by_assessment"][0]["decided"], 1)

    # 11. A key naming no option imported as a draft with "No answer key".
    def test_a_key_that_is_not_an_option_stops_the_import(self):
        csv_text = ("title,question_type,prompt,options,correct_answer\n"
                    "Good,mcq,Pick,A|B,A\nBad,mcq,Pick,A|B,Z\n")
        name = "Key %s" % uuid4().hex[:6]
        with self.assertRaises(UserError) as caught:
            self.env["assessments.be.bank.import.wizard"].create({
                "data_file": base64.b64encode(csv_text.encode()).decode(),
                "data_filename": "bank.csv", "generator_name": name,
            }).run_import()
        self.assertIn("Row 3", str(caught.exception))
        self.assertFalse(self.env["assessments.be.prompt"].search(
            [("name", "=", name)]).question_ids)

    # 12. The console's Owner column was always blank.
    def test_a_generator_row_names_its_owner(self):
        self.assertEqual(S.generator_row(self.generator)["owner"],
                         self.env.user.name)

    # 13. An archived draft could be launched.
    def test_an_archived_draft_is_not_launched(self):
        paper = self._paper()
        self._attempt(paper)
        paper.evaluator_ids = paper.assessment_evaluator_ids.applicant_id
        paper.active = False
        with self.assertRaises(UserError) as caught:
            paper.action_start()
        self.assertIn("archived", str(caught.exception))
        out = call_route(api_admin, api_admin.EtpAssessmentApiAdmin(),
                         "assessment_launch", self.env,
                         path={"assessment_id": paper.id})
        state = next(g for g in out["data"]["gates"]
                     if g["code"] == "state")
        self.assertFalse(state["passed"])
        # 20: one sentence, not "Assessment is in Draft - ... archived".
        self.assertEqual((state["label"], state["reason"]), (
            "The assessment is archived; restore it before launching", ""))

    # 14. The Reset to Draft note said the candidates were deleted.
    def test_the_reset_note_says_what_was_deleted(self):
        paper = self._paper(state="cancelled")
        self._attempt(paper)
        paper.evaluator_ids = paper.assessment_evaluator_ids.applicant_id
        paper.action_reset_draft()
        self.assertTrue(paper.evaluator_ids, "the roster was deleted")
        self.assertFalse(paper.assessment_evaluator_ids)
        note = paper.message_ids[:1].body
        self.assertIn("candidate list was kept", note)
        self.assertNotIn("all candidates", note)

    # 16. Whole-second times folded two tab switches 1.8s apart into one.
    def test_a_violation_18s_later_counts_and_a_double_fire_does_not(self):
        ev = self._attempt(self._paper(state="in_progress"))
        with freeze_time("2026-09-25 10:00:00.100000"):
            self.assertEqual(ev._record_violation("tab_switch"), 1)
        with freeze_time("2026-09-25 10:00:00.105000"):
            self.assertIsNone(ev._record_violation("tab_switch"),
                              "one physical action counted twice")
        with freeze_time("2026-09-25 10:00:01.900000"):
            self.assertEqual(ev._record_violation("tab_switch"), 2,
                             "a second tab switch 1.8s later was swallowed")

    # 18. Scoring buttons on papers with nothing to score, or archived.
    def test_the_scoring_buttons_show_only_with_work_to_do(self):
        arch = etree.fromstring(self.env.ref(
            "assessments_be_v2.assessments_be_form").arch)

        def hidden(button, **vals):
            expr = arch.xpath("//button[@name='%s']" % button)[0].get(
                "invisible")
            return safe_eval(expr, dict({
                "state": "in_progress", "active": True,
                "awaiting_scoring_count": 0, "scoring_failed_count": 0,
                "scoring_phase": "idle"}, **vals))

        for button, count in (("action_llm_score_all",
                               "awaiting_scoring_count"),
                              ("action_llm_score_failed",
                               "scoring_failed_count")):
            self.assertTrue(hidden(button), "%s with nothing to do" % button)
            self.assertFalse(hidden(button, **{count: 1}), button)
            self.assertTrue(hidden(button, **{count: 1, "active": False}),
                            "%s on an archived paper" % button)
            self.assertTrue(hidden(button, **{count: 1, "state": "cancelled"}))
        paper = self._paper(state="in_progress")
        self._attempt(paper, state="submitted", llm_state="failed")
        self.assertEqual(paper.scoring_failed_count, 1)

    # 19. A file of exactly the limit read 2 bytes over.
    def test_a_file_of_exactly_the_limit_is_accepted(self):
        fake = RequestStub(self.env, {})
        exact = base64.b64encode(b"x" * 1048576).decode()
        with patch.object(api_common, "request", fake):
            self.assertIsNone(W._too_large(exact, limit=1048576))
            self.assertTrue(W._too_large(
                base64.b64encode(b"x" * 1048577).decode(), limit=1048576))

    # 20. Wording the re-test flagged.
    def test_the_reworded_messages(self):
        paper = self._paper()
        paper.candidate_csv_file = base64.b64encode(
            b"name,email\nBad,not-an-email\n")
        with self.assertRaises(UserError) as caught:
            paper.action_import_candidates_csv()
        self.assertTrue(str(caught.exception).startswith("Nothing imported"))
        arch = self.env.ref("assessments_be_v2.assessments_be_form").arch
        box = etree.fromstring(arch).xpath(
            "//div[contains(@class, 'alert-warning')][contains(., 'Log only')]")[0]
        self.assertNotIn("threshold", "".join(box.itertext()))
        banner = self.env.ref(
            "assessments_be_v2.assessments_be_evaluator_form").arch
        self.assertIn("Violation:</strong>\xa0<field", banner)
