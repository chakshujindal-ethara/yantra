# -*- coding: utf-8 -*-
"""Q20: the pass threshold is its own per-assessment setting.

Subjective threshold = the cut-off each subjective answer / labelling box
clears. Pass threshold = the cut-off on the candidate's total (score_percent).
A new assessment is seeded from the Settings default; an assessment made
before the field (NULL) keeps passing on its subjective threshold.

The fixture answers are 10 written answers, 7 at raw 75 and 3 at raw 40, so
with a subjective threshold of 60 the candidate's total is exactly 70%.
"""
from odoo.exceptions import ValidationError
from odoo.tests.common import TransactionCase, tagged

from ..constants import DEFAULT_PASS_THRESHOLD_PARAM
from ..controllers.api import admin as admin_api
from ..controllers.api import serializers as S
from ..controllers.api import write as write_api
from ._paging_harness import call_route, status_of
from .test_a_running_lane_keeps_what_it_holds import a_lane_is_running
from .test_individual_scoring_stays_individual import _Paper

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"
SEVENTY_PERCENT = {i: (75 if i < 7 else 40) for i in range(10)}


class _Base(_Paper, TransactionCase):

    def setUp(self):
        super().setUp()
        self.icp = self.env["ir.config_parameter"].sudo()
        self.icp.set_param(DEFAULT_PASS_THRESHOLD_PARAM, "70")
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self._pin_settings()

    def _sitting(self, subjective, pass_threshold):
        self.paper.write({"subjective_threshold": subjective,
                          "pass_threshold": pass_threshold})
        return self._candidate(10, scored=SEVENTY_PERCENT)

    def _made_before_q20(self, paper):
        """What -u leaves on an existing row: the new column NULL."""
        self.env.flush_all()
        self.env.cr.execute(
            "UPDATE assessments_be SET pass_threshold = NULL WHERE id = %s",
            [paper.id])
        paper.invalidate_recordset(["pass_threshold"])
        return paper


@tagged("-at_install", "post_install")
class TestTheDefaultSeedsOnlyNewAssessments(_Base):

    def test_a_new_assessment_starts_at_the_default(self):
        self.icp.set_param(DEFAULT_PASS_THRESHOLD_PARAM, "80")
        self.assertEqual(self._new_paper().pass_threshold, 80.0)

    def test_an_unset_default_is_70(self):
        self.icp.search([("key", "=", DEFAULT_PASS_THRESHOLD_PARAM)]).unlink()
        self.assertEqual(self._new_paper().pass_threshold, 70.0)

    def test_changing_the_default_leaves_existing_assessments_alone(self):
        self.icp.set_param(DEFAULT_PASS_THRESHOLD_PARAM, "80")
        seeded = self._new_paper()
        old = self._made_before_q20(self._new_paper())

        self.icp.set_param(DEFAULT_PASS_THRESHOLD_PARAM, "55")

        self.assertEqual(seeded.pass_threshold, 80.0)
        self.assertEqual(old.pass_threshold, 0.0)
        self.assertEqual(self._new_paper().pass_threshold, 55.0)

    def test_a_copy_keeps_the_source_value(self):
        self.paper.pass_threshold = 85
        self.icp.set_param(DEFAULT_PASS_THRESHOLD_PARAM, "55")
        self.assertEqual(self.paper.copy().pass_threshold, 85.0)
        old = self._made_before_q20(self._new_paper())
        self.assertEqual(old.copy().pass_threshold, 0.0,
                         "a not-set source stays not set")


@tagged("-at_install", "post_install")
class TestThePassThresholdDecidesTheTotal(_Base):

    def test_a_not_set_assessment_passes_on_its_subjective_threshold(self):
        self.paper.subjective_threshold = 60
        self._made_before_q20(self.paper)
        ev = self._candidate(10, scored=SEVENTY_PERCENT)

        self.assertEqual(ev.score_percent, 70.0)
        self.assertEqual(ev.pass_threshold, 60.0)
        self.assertEqual(ev.result, "pass")
        self.assertEqual(S.assessment_row(self.paper)["pass_threshold"], 60.0)

    def test_the_two_thresholds_act_independently(self):
        ev = self._sitting(subjective=60, pass_threshold=80)
        self.assertEqual(ev.score_percent, 70.0,
                         "subjective 60 still decides each answer's mark")
        self.assertEqual(ev.pass_threshold, 80.0)
        self.assertEqual(ev.result, "fail")

    def test_editing_it_re_decides_without_re_grading(self):
        ev = self._sitting(subjective=60, pass_threshold=80)
        raws = ev.response_ids.mapped("llm_raw_100")
        self.assertEqual(ev.result, "fail")

        self.paper.pass_threshold = 65

        self.assertEqual(ev.pass_threshold, 65.0)
        self.assertEqual(ev.result, "pass")
        self.assertEqual(ev.response_ids.mapped("llm_raw_100"), raws)
        self.assertEqual(set(ev.response_ids.mapped("llm_state")), {"scored"})

    def test_an_edit_waits_for_a_running_lane(self):
        idle = self._candidate(1, scored={0: 80})
        busy = self._candidate(1, scored={0: 70}, requested=True)
        busy.llm_state = "scoring"
        with a_lane_is_running(self.env):
            self.paper.pass_threshold = 55.0
        self.assertTrue(self.paper.threshold_recompute_pending)
        self.assertEqual(idle.pass_threshold, 55.0,
                         "the stored bar still follows through its depends")

    def test_outside_1_to_100_is_refused(self):
        self.paper.pass_threshold = 75
        for bad in (0, False, 0.5, 101, -5):
            with self.assertRaisesRegex(ValidationError, "between 1 and 100"):
                self.paper.pass_threshold = bad
                self.env.flush_all()
            with self.assertRaisesRegex(ValidationError, "between 1 and 100"):
                self.env["assessments.be"].create(
                    {"name": "Zero", "pass_threshold": bad})
        self.assertEqual(self.paper.pass_threshold, 75.0)

    def test_a_not_set_row_stays_null_through_other_edits(self):
        old = self._made_before_q20(self.paper)
        old.write({"name": "Renamed", "subjective_threshold": 65})
        self.env.flush_all()
        self.env.cr.execute(
            "SELECT pass_threshold IS NULL FROM assessments_be WHERE id = %s",
            [old.id])
        self.assertTrue(self.env.cr.fetchone()[0])


@tagged("-at_install", "post_install")
class TestThePassThresholdOnTheApi(_Base):

    def _update(self, paper, **body):
        return call_route(write_api, write_api.EtpAssessmentApiWrite(),
                          "assessment_update", self.env,
                          path={"assessment_id": paper.id}, **body)

    def test_the_payload_sends_the_effective_value(self):
        self.paper.write({"subjective_threshold": 60, "pass_threshold": 85})
        self.assertEqual(S.assessment_row(self.paper)["pass_threshold"], 85.0)
        self.assertEqual(
            S.assessment_detail(self.paper)["pass_threshold"], 85.0)
        self._made_before_q20(self.paper)
        self.assertEqual(
            S.assessment_detail(self.paper)["pass_threshold"], 60.0)

    def test_the_update_route_sets_it_even_after_launch(self):
        self.paper.state = "in_progress"
        response = self._update(self.paper, pass_threshold=82)
        self.assertEqual(status_of(response), 200, response)
        self.assertEqual(self.paper.pass_threshold, 82.0)
        self.assertEqual(response["data"]["pass_threshold"], 82.0)

    def test_the_create_route_refuses_outside_1_to_100(self):
        for bad in (0, 101, -1):
            response = call_route(
                write_api, write_api.EtpAssessmentApiWrite(),
                "assessment_create", self.env, name="Made", pass_threshold=bad)
            self.assertEqual(status_of(response), 422, response)
            self.assertEqual(response["error"]["code"], "invalid")
        response = call_route(
            write_api, write_api.EtpAssessmentApiWrite(),
            "assessment_create", self.env, name="Made", pass_threshold=64)
        self.assertEqual(status_of(response), 200, response)
        self.assertEqual(response["data"]["pass_threshold"], 64.0)

    def test_the_update_route_refuses_outside_1_to_100(self):
        self.paper.pass_threshold = 75
        for bad in (0, 101, -1):
            response = self._update(self.paper, pass_threshold=bad)
            self.assertEqual(status_of(response), 422, response)
            self.assertEqual(response["error"]["code"], "invalid")
        self.assertEqual(self.paper.pass_threshold, 75.0)

    def test_a_non_number_is_refused_not_ignored(self):
        """`_picked` dropped "abc" and answered 200 with nothing saved."""
        self.paper.pass_threshold = 75
        for bad in ("abc", "70%", True, [70]):
            response = self._update(self.paper, pass_threshold=bad)
            self.assertEqual(status_of(response), 422, (bad, response))
            self.assertEqual(response["error"]["code"], "invalid")
            self.assertIn("must be a number", response["error"]["message"])
        self.assertEqual(self.paper.pass_threshold, 75.0)
        for unset in (None, ""):
            response = self._update(self.paper, pass_threshold=unset)
            self.assertEqual(status_of(response), 200, response)
            self.assertEqual(self.paper.pass_threshold, 75.0,
                             "null is 'not sent', as before")
        response = self._update(self.paper, pass_threshold=70)
        self.assertEqual(status_of(response), 200, response)
        self.assertEqual(self.paper.pass_threshold, 70.0)


@tagged("-at_install", "post_install")
class TestTheDefaultPassThresholdSetting(_Base):

    def _update(self, **body):
        return call_route(write_api, write_api.EtpAssessmentApiWrite(),
                          "settings_update", self.env, **body)

    def _read(self):
        return call_route(admin_api, admin_api.EtpAssessmentApiAdmin(),
                          "settings", self.env)["data"]

    def test_the_api_reads_and_writes_it(self):
        self.assertEqual(self._read()["scoring"]["default_pass_threshold"], 70)
        response = self._update(default_pass_threshold=85)
        self.assertEqual(status_of(response), 200, response)
        self.assertEqual(self._read()["scoring"]["default_pass_threshold"], 85)
        self.assertEqual(self._new_paper().pass_threshold, 85.0)

    def test_the_api_refuses_outside_1_to_100(self):
        for bad in (0, 101, -3):
            response = self._update(default_pass_threshold=bad)
            self.assertEqual(status_of(response), 422, response)
        self.assertEqual(self.icp.get_param(DEFAULT_PASS_THRESHOLD_PARAM), "70")

    def test_odoo_settings_writes_it_and_refuses_0(self):
        self.env["res.config.settings"].create(
            {"assessments_be_default_pass_threshold": 65}).execute()
        self.assertEqual(self.icp.get_param(DEFAULT_PASS_THRESHOLD_PARAM), "65")
        with self.assertRaises(ValidationError):
            self.env["res.config.settings"].create(
                {"assessments_be_default_pass_threshold": 0})

    def test_a_bad_stored_default_still_opens_and_saves_as_70(self):
        for raw in ("abc", "0", "150"):
            self.icp.set_param(DEFAULT_PASS_THRESHOLD_PARAM, raw)
            settings = self.env["res.config.settings"].create({})
            self.assertEqual(settings.assessments_be_default_pass_threshold, 70)
            settings.execute()
            self.assertEqual(
                self.icp.get_param(DEFAULT_PASS_THRESHOLD_PARAM), "70")


@tagged("-at_install", "post_install")
class TestTheOdooFormShowsTheRealBar(_Base):

    def test_a_not_set_paper_names_the_bar_it_uses(self):
        self.paper.subjective_threshold = 60
        old = self._made_before_q20(self.paper)
        self.assertEqual(old.pass_threshold_note,
                         "Not set - uses the subjective threshold: 60%")
        old.pass_threshold = 72
        self.assertFalse(old.pass_threshold_note)

    def test_the_form_renders_the_note_beside_the_field(self):
        view = self.env.ref("assessments_be_v2.assessments_be_form")
        arch = self.env["assessments.be"].get_view(view.id, "form")["arch"]
        self.assertIn('name="pass_threshold"', arch)
        self.assertIn('name="pass_threshold_note"', arch)
