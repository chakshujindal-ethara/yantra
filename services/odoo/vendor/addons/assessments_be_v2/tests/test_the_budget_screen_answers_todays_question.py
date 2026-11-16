# -*- coding: utf-8 -*-
"""pm-ux-admin-5: Odoo's LLM Budget shows today's spend against the caps.

The dashboard was an all-time snapshot - total cost, tokens, requests, average
per request - with no period control and no reference to the daily or
per-candidate caps. So the one question an operator brings to it ("can we grade
this cohort today?") had no answer here, and a day on which the cap had stopped
every call rendered identically to a healthy one. The console leads its budget
screen with exactly these numbers.

Read through `vertex.spend_cap` and the usage ledger - the same sources
`vertex._check_spend` refuses calls with and `GET /api/v1/budget` reports - so
the screen and the gate cannot disagree. A local `get_param(..., "0")` here is
precisely the divergence that once had this dashboard reporting "no cap" while
the gate was refusing everything.
"""
from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestTheBudgetScreenAnswersTodaysQuestion(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Dash = self.env["assessments.be.llm.dashboard"]
        self.Usage = self.env["assessments.be.llm.usage"]
        self.env["ir.config_parameter"].sudo().set_param(
            "assessments_be_v2.daily_llm_cap_usd", "400")
        self.env["ir.config_parameter"].sudo().set_param(
            "assessments_be_v2.per_evaluator_llm_cap_usd", "20")

    def _spend(self, usd):
        self.Usage.sudo().create({
            "operation": "score_subjective",
            "model": "gemini-test",
            "cost_usd": usd,
        })

    def _open(self):
        fields_list = list(self.Dash._fields)
        return self.Dash.default_get(fields_list)

    def test_the_screen_reports_todays_spend_and_the_daily_cap(self):
        # Other rows on the database may have spent today too (RV6-01).
        before = self._open()["today_cost"]
        self._spend(30.0)
        values = self._open()
        today = values["today_cost"]
        self.assertAlmostEqual(today - before, 30.0, places=4)
        self.assertEqual(values["daily_cap"], 400.0)
        self.assertAlmostEqual(values["today_remaining"],
                               max(0.0, 400.0 - today), places=4)
        self.assertAlmostEqual(values["today_pct_of_cap"],
                               round(today / 400.0 * 100.0, 1), places=1)
        self.assertEqual(values["daily_cap_reached"], today >= 400.0)

    def test_it_says_when_the_cap_has_been_reached(self):
        self._spend(400.0)
        values = self._open()
        self.assertTrue(values["daily_cap_reached"])
        self.assertAlmostEqual(values["today_remaining"], 0.0, places=4)

    def test_the_per_candidate_cap_is_on_the_screen_too(self):
        self.assertEqual(self._open()["per_candidate_cap"], 20.0)

    def test_the_caps_come_from_the_same_resolver_the_gate_uses(self):
        """A cap of 0 disables the cap by contract, and must not render as
        "no money left"."""
        from odoo.addons.assessments_be_v2.services import vertex
        self.env["ir.config_parameter"].sudo().set_param(
            "assessments_be_v2.daily_llm_cap_usd", "0")
        values = self._open()
        self.assertEqual(
            values["daily_cap"],
            vertex.spend_cap(self.env, "daily_llm_cap_usd", 100.0))
        self.assertFalse(values["daily_cap_set"])
        self.assertFalse(values["daily_cap_reached"])

    def test_the_form_renders_the_today_panel(self):
        from lxml import etree
        view = self.env.ref(
            "assessments_be_v2.assessments_be_llm_dashboard_form")
        arch = etree.fromstring(self.Dash.get_view(view.id, "form")["arch"])
        for name in ("today_cost", "daily_cap", "today_remaining",
                     "today_pct_of_cap", "per_candidate_cap"):
            self.assertTrue(arch.xpath("//field[@name='%s']" % name),
                            "%s is computed and never shown" % name)
