# -*- coding: utf-8 -*-
"""The LLM spend caps, pinned on the two things that went wrong at once.

WHY THIS FILE EXISTS.

  1. FOUR SURFACES ANSWERED "what is the cap" AND THREE OF THEM DISAGREED.
     With both `ir.config_parameter` rows absent - which is how prod was found
     on 2026-09-17 - `vertex._check_budget` refused calls at the module default
     of $100/day while `/api/v1/budget` reported `cap_usd: 0, capped: false`
     and the Flutter Settings screen prefilled 0.00. The stall was recoverable;
     the screen an operator checks to find out WHY the grading stopped was not
     honest, which is what made it an incident. Worse than the display: the
     Flutter governance panel posts all four of its keys back on any Save, so
     one Save of a form prefilled with 0.00 genuinely disabled the cap.

  2. THE ODOO FORM COULD NOT EXPRESS THE 0 ITS OWN HELP PROMISED. Core coerces
     a falsy numeric to False (`res_config.py:340`) and `set_param(False)`
     unlinks the row, so "0 disables the daily cap" typed into the widget that
     documents it deleted the setting and restored $100/day on the next read.

THE ASSERTION THAT MATTERS IN THE FIRST GROUP IS AGREEMENT, NOT A VALUE. If a
future default moves, these tests must still pass; if one surface starts
resolving the key for itself again, they must not.

Nothing here calls Vertex. The budget gate is asserted directly, because the
whole point of it is to run BEFORE the billable request.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.exceptions import UserError
from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.constants import (
    DEFAULT_DAILY_LLM_CAP_USD,
    DEFAULT_PER_EVALUATOR_LLM_CAP_USD,
    SCORE_OUTLIER_SIGMA_DEFAULT,
)
from odoo.addons.assessments_be_v2.controllers.api import admin as admin_api
from odoo.addons.assessments_be_v2.controllers.api import common as api_common

from ..services import vertex


class _StubRequest:
    """The slice of `odoo.http.request` these two read routes touch.

    Same stub as `test_question_shortlist`, and for the same reason: both
    routes need `request.env` and nothing else, so this stays a
    TransactionCase rather than buying a session and a port.
    """

    def __init__(self, env, params=None):
        self.env = env
        self.params = dict(params or {})

    def make_json_response(self, payload, headers=None, status=200):
        return {"ok": False, "status": status, "payload": payload}


class _Base(TransactionCase):

    DAILY = "assessments_be_v2.daily_llm_cap_usd"
    PER_EVALUATOR = "assessments_be_v2.per_evaluator_llm_cap_usd"

    def setUp(self):
        super().setUp()
        self.icp = self.env["ir.config_parameter"].sudo()
        self.Usage = self.env["assessments.be.llm.usage"].sudo()
        # Both read routes are group-gated; Admin implies the read-only
        # Manager, so one grant serves `require_manager` and `require_operator`.
        self.env.ref(
            "assessments_be_v2.group_assessment_manager"
        ).sudo().write({"user_ids": [(4, self.env.user.id)]})
        # The rate ceiling shares `spend_cap` and runs first inside
        # `_check_budget`. Neutralised so a deployment that happens to have one
        # configured cannot make a budget assertion fail for a rate reason.
        self.icp.set_param("assessments_be_v2.vertex_max_rpm", "")

    def _forget(self, *keys):
        """Delete the parameter rows outright - ABSENT, not 0.

        That is the state prod was in, and it is the state every fresh
        database starts in, so it is the one the surfaces have to agree about.
        """
        self.icp.search([("key", "in", list(keys))]).unlink()

    def _route(self, name):
        """Call one read route and return its `data`, as the app receives it."""
        stub = _StubRequest(self.env)
        controller = admin_api.EtpAssessmentApiAdmin()
        with patch.object(admin_api, "request", stub), \
                patch.object(api_common, "request", stub):
            response = getattr(controller, name)()
        self.assertTrue(
            response.get("ok"),
            "/%s refused the call; got %r" % (name, response))
        return response["data"]

    def _spend(self, amount):
        """One ledger row for today, which is what the gate sums."""
        return self.Usage.create({
            "operation": "score_subjective",
            "model": "gemini-3-pro",
            "cost_usd": amount,
            "note": "cap fixture %s" % uuid4().hex[:6],
        })

    def _save_settings(self, **values):
        """A real Odoo Settings save - `set_values` and all, not a set_param.

        The defect is IN that path: anything that writes the parameter
        directly proves nothing about it.
        """
        self.env["res.config.settings"].create(values).execute()


@tagged("-at_install", "post_install")
class TestEverySurfaceAgreesOnTheCap(_Base):
    """CAP-2 + CAP-3: the gate, the LLM Budget dashboard and the Settings
    screen must return ONE number per cap, whatever that number is."""

    def setUp(self):
        super().setUp()
        self._forget(self.DAILY, self.PER_EVALUATOR)

    def _three_readings(self):
        budget = self._route("budget")
        settings = self._route("settings")["governance"]
        return {
            "daily": (
                vertex.spend_cap(
                    self.env, "daily_llm_cap_usd", DEFAULT_DAILY_LLM_CAP_USD),
                budget["today"]["cap_usd"],
                settings["daily_llm_cap_usd"],
            ),
            "per_evaluator": (
                vertex.spend_cap(
                    self.env, "per_evaluator_llm_cap_usd",
                    DEFAULT_PER_EVALUATOR_LLM_CAP_USD),
                budget["per_evaluator_cap_usd"],
                settings["per_evaluator_llm_cap_usd"],
            ),
        }

    def test_with_no_row_at_all_the_three_surfaces_report_one_number(self):
        """The prod state. Before the fix this was 100.0 / 0.0 / 0.0."""
        for cap, (gate, dashboard, screen) in self._three_readings().items():
            with self.subTest(cap=cap):
                self.assertEqual(
                    dashboard, gate,
                    "the LLM Budget dashboard reports a cap the gate is not "
                    "enforcing")
                self.assertEqual(
                    screen, gate,
                    "the Settings screen prefills a cap the gate is not "
                    "enforcing - and that prefill is re-saved on any Save")

    def test_an_absent_row_resolves_to_the_armed_default_not_to_zero(self):
        """Agreement on 0 would be agreement on a lie: the gate is ON."""
        readings = self._three_readings()
        self.assertEqual(readings["daily"][0], DEFAULT_DAILY_LLM_CAP_USD)
        self.assertEqual(
            readings["per_evaluator"][0], DEFAULT_PER_EVALUATOR_LLM_CAP_USD)
        for cap, values in readings.items():
            with self.subTest(cap=cap):
                self.assertTrue(
                    all(v > 0 for v in values),
                    "an absent row means 'not configured', and the gate "
                    "refuses calls against the module default - so no surface "
                    "may report 'no cap'")

    def test_a_configured_cap_is_the_same_number_on_all_three(self):
        """The other direction: a stored value overrides the default once."""
        self.icp.set_param(self.DAILY, "250")
        self.icp.set_param(self.PER_EVALUATOR, "7.5")

        readings = self._three_readings()

        self.assertEqual(readings["daily"], (250.0, 250.0, 250.0))
        self.assertEqual(readings["per_evaluator"], (7.5, 7.5, 7.5))

    def test_the_dashboard_flags_a_breach_the_gate_would_refuse(self):
        """`capped` is computed from the cap, so it moved with the bug too."""
        self.icp.set_param(self.DAILY, "10")
        self._spend(12.0)

        today = self._route("budget")["today"]

        self.assertTrue(today["capped"])
        self.assertEqual(today["remaining_usd"], 0.0)
        with self.assertRaises(vertex.VertexBudgetError):
            vertex._check_budget(self.env, {})


@tagged("-at_install", "post_install")
class TestZeroSurvivesTheSaveAndDisablesTheCap(_Base):
    """CAP-1 + CAP-4: the Odoo form can express the 0 its help promises."""

    def test_saving_zero_leaves_a_row_that_says_zero(self):
        """EXISTS with "0" - not absent. Absent is what the bug produced, and
        absent reads back as the $100 default."""
        self._forget(self.DAILY)

        self._save_settings(assessments_be_daily_llm_cap_usd=0.0)

        row = self.icp.search([("key", "=", self.DAILY)])
        self.assertTrue(
            row, "the parameter row was deleted by the save, which is the "
                 "defect: the next read falls back to the field default")
        self.assertEqual(row.value, "0")

    def test_the_gate_reads_that_zero_as_zero(self):
        self._save_settings(assessments_be_daily_llm_cap_usd=0.0)

        self.assertEqual(
            vertex.spend_cap(
                self.env, "daily_llm_cap_usd", DEFAULT_DAILY_LLM_CAP_USD),
            0.0)

    def test_a_guarded_call_is_not_refused_once_the_cap_is_zero(self):
        """The contract in the field help: 0 DISABLES the cap.

        Spend is put well past the module default first, so passing this can
        only mean the 0 is in force - not that there was nothing to refuse.
        """
        self._spend(DEFAULT_DAILY_LLM_CAP_USD * 1.5)
        self._save_settings(assessments_be_daily_llm_cap_usd=0.0)

        # No exception is the assertion.
        vertex._check_budget(self.env, {})

    def test_the_same_spend_is_refused_while_the_cap_is_merely_unset(self):
        """The control. Without it, the test above passes on a broken gate."""
        self._forget(self.DAILY)
        self._spend(DEFAULT_DAILY_LLM_CAP_USD * 1.5)

        with self.assertRaises(vertex.VertexBudgetError):
            vertex._check_budget(self.env, {})

    def test_zero_is_reported_as_zero_by_both_screens(self):
        self._save_settings(assessments_be_daily_llm_cap_usd=0.0)

        self.assertEqual(self._route("budget")["today"]["cap_usd"], 0.0)
        self.assertEqual(
            self._route("settings")["governance"]["daily_llm_cap_usd"], 0.0)

    def test_score_outlier_sigma_has_the_same_bug_and_the_same_fix(self):
        """CAP-4. It is covered because the fix loops the classified fields
        instead of naming the two caps - so it needed no second edit, and a
        third field with a "0 disables" help will need none either."""
        key = "assessments_be_v2.score_outlier_sigma"
        self._forget(key)

        self._save_settings(assessments_be_score_outlier_sigma=0.0)

        row = self.icp.search([("key", "=", key)])
        self.assertTrue(row, "outlier flagging cannot be turned off from the "
                             "form its help documents")
        self.assertEqual(row.value, "0")

    def test_a_non_zero_save_still_stores_the_number(self):
        """The loop must not flatten real values on its way past them."""
        self._save_settings(assessments_be_daily_llm_cap_usd=250.0)

        self.assertEqual(
            vertex.spend_cap(
                self.env, "daily_llm_cap_usd", DEFAULT_DAILY_LLM_CAP_USD),
            250.0)


@tagged("-at_install", "post_install")
class TestTheOutlierSigmaIsReportedLikeTheTwoCaps(_Base):
    """CAP-5: the THIRD governance key, on the footing the two caps now have.

    It was the one left resolving itself: `/api/v1/settings` reported 0.0 for
    an absent row while `models/assessment.py` resolved the same absent row to
    `SCORE_OUTLIER_SIGMA_DEFAULT`. That is the same shape as the cap incident
    and it ends the same way - the governance panel posts all four keys back
    on any Save, so an admin who opened Settings to change the retention days
    saved `score_outlier_sigma = 0` and turned the integrity review net off
    for every cohort, having never touched the field.
    """

    SIGMA = "assessments_be_v2.score_outlier_sigma"

    def _reported(self):
        return self._route("settings")["governance"]["score_outlier_sigma"]

    def test_an_absent_row_reports_the_sigma_the_runtime_will_use(self):
        """The prod state. Before the fix this was 0.0 against a runtime 2.0."""
        self._forget(self.SIGMA)

        self.assertEqual(self._reported(), SCORE_OUTLIER_SIGMA_DEFAULT)

    def test_a_stored_zero_is_still_reported_as_zero(self):
        """The other direction, and the reason this is not a blanket default:
        a stored 0 is the operator asking for no net, and it must show."""
        self.icp.set_param(self.SIGMA, "0")

        self.assertEqual(self._reported(), 0.0)

    def test_a_configured_sigma_is_reported_verbatim(self):
        self.icp.set_param(self.SIGMA, "3.5")

        self.assertEqual(self._reported(), 3.5)


@tagged("-at_install", "post_install")
class TestTheOdooFormRefusesANegativeCap(_Base):
    """A negative does not LOWER a cap, it REMOVES it.

    `vertex.spend_cap` returns a stored negative verbatim and both budget
    gates read `cap > 0`, so -100 in the daily cap disables the H-5 protection
    entirely and `/api/v1/budget` then reports `capped: false` - which reads as
    "no cap configured" rather than "your cap is broken". The JSON API has
    refused a negative since it could write these keys; the Odoo form accepted
    one, so the only guarded surface was the one an admin does not use.
    """

    def test_a_negative_daily_cap_is_refused(self):
        with self.assertRaises(UserError):
            self._save_settings(assessments_be_daily_llm_cap_usd=-100.0)

    def test_a_negative_per_candidate_cap_is_refused(self):
        with self.assertRaises(UserError):
            self._save_settings(
                assessments_be_per_evaluator_llm_cap_usd=-5.0)

    def test_a_negative_outlier_sigma_is_refused(self):
        """Same `<= 0` guard, same silent disable."""
        with self.assertRaises(UserError):
            self._save_settings(assessments_be_score_outlier_sigma=-2.0)

    def test_zero_is_still_accepted_on_all_three(self):
        """THE CONTROL. 0 is the documented way to turn each one off, so a
        guard that refused it would break the contract it is protecting."""
        self._save_settings(
            assessments_be_daily_llm_cap_usd=0.0,
            assessments_be_per_evaluator_llm_cap_usd=0.0,
            assessments_be_score_outlier_sigma=0.0)

        self.assertEqual(
            vertex.spend_cap(
                self.env, "daily_llm_cap_usd", DEFAULT_DAILY_LLM_CAP_USD),
            0.0)


@tagged("-at_install", "post_install")
class TestTheSchedulerKnobsReportWhatTheGraderWillUse(_Base):
    """P4: `scoring_batch_size` and `llm_max_attempts` on `/api/v1/settings`.

    A stored "0" is a real state here, not only a missing row: the write API
    blesses 0 as "use the module default", and after the CAP-1 fix any settings
    save materialises "0" for a falsy numeric. The runtime coerces both cases
    back to 8 and 3 (`services/scoring.py`), so the screen has to as well - a
    fix that only handled the missing row would still render 0 on this DB.
    """

    BATCH = "assessments_be_v2.scoring_batch_size"
    ATTEMPTS = "assessments_be_v2.llm_max_attempts"

    def _reported(self):
        return self._route("settings")["scoring"]

    def test_a_stored_zero_reports_the_module_default(self):
        self.icp.set_param(self.BATCH, "0")
        self.icp.set_param(self.ATTEMPTS, "0")

        scoring = self._reported()

        self.assertEqual(scoring["batch_size"], 8)
        self.assertEqual(scoring["llm_max_attempts"], 3)

    def test_an_absent_row_reports_the_module_default(self):
        self._forget(self.BATCH, self.ATTEMPTS)

        scoring = self._reported()

        self.assertEqual(scoring["batch_size"], 8)
        self.assertEqual(scoring["llm_max_attempts"], 3)

    def test_a_configured_value_is_reported_verbatim(self):
        self.icp.set_param(self.BATCH, "12")
        self.icp.set_param(self.ATTEMPTS, "5")

        scoring = self._reported()

        self.assertEqual(scoring["batch_size"], 12)
        self.assertEqual(scoring["llm_max_attempts"], 5)

    def test_the_cron_lock_mode_is_reported_as_the_crons_run_it(self):
        """The console can set it (`write.py::SETTINGS`), so it can show it:
        advisory when unset or unknown, which is what `cron_lock` runs."""
        mode = "assessments_be_v2.cron_lock_mode"
        self._forget(mode)
        self.assertEqual(self._reported()["cron_lock_mode"], "advisory")
        self.icp.set_param(mode, "lease")
        self.assertEqual(self._reported()["cron_lock_mode"], "lease")
        self.icp.set_param(mode, "Lease")
        self.assertEqual(self._reported()["cron_lock_mode"], "advisory")

    def test_paper_prefetch_is_reported_as_the_exam_routes_read_it(self):
        """Writable through `/settings/update`, so shown, with the reader
        `/state` and `/begin` use: off when absent or empty, on for the
        API's "1" and the Odoo form's "True"."""
        key = "assessments_be_v2.paper_prefetch"

        def shown():
            return self._route("settings")["exam"]["paper_prefetch"]

        self._forget(key)
        self.assertIs(shown(), False)
        for on in ("1", "True"):
            self.icp.set_param(key, on)
            self.assertIs(shown(), True, on)
        self.icp.set_param(key, "")
        self.assertIs(shown(), False)

    def test_answers_flush_seconds_is_reported_as_the_exam_routes_read_it(self):
        """The app's Settings screen edits it (BR-D4), so the read route reports
        it with the reader `/state` and `/begin` advertise: 60 when unset, 0
        or junk, clamped to 15-300, a value in range as stored. The box posts
        it back on Save, so it must never read as anything else."""
        key = "assessments_be_v2.answers_flush_seconds"

        def shown():
            return self._route("settings")["exam"]["answers_flush_seconds"]

        self._forget(key)
        self.assertEqual(shown(), 60)
        for stored, expected in (("0", 60), ("junk", 60), ("5", 15),
                                 ("900", 300), ("120", 120)):
            self.icp.set_param(key, stored)
            self.assertEqual(shown(), expected, stored)

    def test_both_exam_settings_save_with_the_odoo_form_rules(self):
        """The write route takes what the Odoo form takes and nothing else:
        the interval in 15-300 (0 = default), the switch as a real boolean.
        Read back through the settings route the app's boxes seed from."""
        from ..controllers.api import write as write_api
        from ._paging_harness import call_route, status_of

        def update(**values):
            return status_of(call_route(
                write_api, write_api.EtpAssessmentApiWrite(),
                "settings_update", self.env, **values))

        self.assertEqual(update(answers_flush_seconds=120), 200)
        self.assertEqual(update(paper_prefetch=True), 200)
        exam = self._route("settings")["exam"]
        self.assertEqual(exam["answers_flush_seconds"], 120)
        self.assertIs(exam["paper_prefetch"], True)

        for bad in ({"answers_flush_seconds": 10},
                    {"answers_flush_seconds": 301},
                    {"paper_prefetch": "false"}):
            self.assertEqual(update(**bad), 422, bad)
        exam = self._route("settings")["exam"]
        self.assertEqual(exam["answers_flush_seconds"], 120)
        self.assertIs(exam["paper_prefetch"], True)

        self.assertEqual(update(paper_prefetch=False), 200)
        self.assertIs(self._route("settings")["exam"]["paper_prefetch"], False)
