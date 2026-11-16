# -*- coding: utf-8 -*-
"""A setting's legal values are decided ONCE, and every surface reads that one
decision.

TWO DEFECTS OF THE SAME SHAPE, both of them a second hand-written copy of a
rule that already existed somewhere else.

  1. THE SELECTION THE API DID NOT KNOW ABOUT. `assessments_be_thinking_level`
     is a Selection over "" / LOW / MEDIUM / HIGH, but `_SETTING_CHOICES` in
     `controllers/api/write.py` listed only `video_default_duration_s`. The
     Settings screen now edits the thinking level through a FREE-TEXT box, so
     a lowercase "medium" - which the runtime resolver accepts and upper-cases,
     and which the field's own help invites - saved 200 and sat in
     `ir.config_parameter` as a value the Selection cannot map. The next open
     of Odoo Settings, FOR ANY APP, raises `Wrong value for
     res.config.settings.assessments_be_thinking_level: 'medium'` and the
     Settings page is unusable for the whole database until somebody edits the
     parameter row by hand. Nothing at runtime misbehaves in the meantime,
     which is exactly why it sits there undetected.

  2. THE PRE-DEPLOY GATE THAT DISAGREED WITH THE CONSTRAINT IT MODELS.
     `tools/check_settings_in_range.py` is run BEFORE an upgrade and its whole
     output is a prediction: "N parameter(s) would make the Settings page
     unsavable after the upgrade. Fix them BEFORE upgrading." It carried its
     own copy of the bounds and the copy had drifted - it refused a stored 0,
     which `_check_be_llm_limits` coerces to the field default and accepts, and
     it refused an rpm above an invented 10000 ceiling that the constraint does
     not have. A gate that holds a deploy back on legal values gets ignored,
     and then it is not a gate.

     It had ALSO drifted the other way, which is the dangerous direction: it
     hand-listed four parameters while `@api.constrains` triggers on seven, so
     a stored negative `daily_llm_cap_usd`, `per_evaluator_llm_cap_usd` or
     `score_outlier_sigma` passed clean and bricked the Settings page after
     the upgrade anyway. The gate's field set is now the constraint's own
     trigger list, and `test_the_gate_checks_exactly_what_the_constraint_triggers_on`
     fails the moment the two differ again.

Both are now read from one place: `model_catalog.THINKING_LEVELS` for the
levels, `constants.SETTING_RANGES` for the ranges and `_check_be_llm_limits`
itself for the set of fields the gate must cover.

The gate is executed here rather than paraphrased. It is a shell script with
no functions - `odoo-bin shell` hands it `env` - so the test compiles the
shipped file and runs it against the test cursor with stdout captured. A test
that re-implemented its table would keep passing after somebody edited it.
"""
import contextlib
import io
import os

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.constants import SETTING_RANGES
from odoo.addons.assessments_be_v2.services.model_catalog import THINKING_LEVELS

from ..controllers.api import write as write_api
from ._paging_harness import call_route, status_of

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"
THINKING_KEY = "assessments_be_v2.thinking_level"
GATE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), os.pardir, "tools",
    "check_settings_in_range.py")


class _Base(TransactionCase):

    def setUp(self):
        super().setUp()
        self.icp = self.env["ir.config_parameter"].sudo()
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.controller = write_api.EtpAssessmentApiWrite()

    def _update(self, **body):
        return call_route(
            write_api, self.controller, "settings_update", self.env, **body)


@tagged("-at_install", "post_install")
class TestASelectionSettingCannotBeStoredOutsideItsSelection(_Base):
    """The console may only write values the Odoo field can read back."""

    def _selection(self):
        field = self.env["res.config.settings"]._fields[
            "assessments_be_thinking_level"]
        return [value for value, _label in field.selection]

    def test_the_field_and_the_api_offer_the_same_levels(self):
        """THE DRIFT GUARD. A fifth level added to the form must not be
        refused by the route, and a value the route blesses must be one the
        form can display - which is the whole failure below."""
        self.assertEqual(
            tuple(v for v in self._selection() if v), THINKING_LEVELS,
            "the Selection on res.config.settings and THINKING_LEVELS have "
            "drifted apart")
        self.assertIn(
            "", self._selection(),
            "the empty choice is how an override is cleared")

    def test_the_orm_really_does_refuse_an_unlisted_value(self):
        """GUARD THE GUARD: without this, the test below could be pinning a
        refusal that protects against nothing."""
        field = self.env["res.config.settings"]._fields[
            "assessments_be_thinking_level"]
        with self.assertRaises(ValueError):
            field.convert_to_cache("medium", self.env["res.config.settings"])

    def test_a_value_outside_the_selection_is_refused_at_the_door(self):
        """422 and NOTHING STORED. Lowercase, because that is what the help
        text ("LOW, MEDIUM or HIGH") and the screen's hint invite."""
        self.icp.set_param(THINKING_KEY, "HIGH")

        response = self._update(thinking_level="medium")

        self.assertEqual(status_of(response), 422, response)
        self.assertEqual(response["error"]["code"], "invalid")
        self.assertEqual(
            self.icp.get_param(THINKING_KEY), "HIGH",
            "a refused payload must leave the stored value alone")

    def test_a_typo_is_refused_rather_than_stored_and_ignored(self):
        response = self._update(thinking_level="HIGN")

        self.assertEqual(status_of(response), 422, response)
        self.assertIn(
            THINKING_KEY.split(".", 1)[1], response["error"]["message"])

    def test_whatever_is_stored_is_always_a_value_the_form_can_render(self):
        """The invariant the 422 exists for, stated as the property itself."""
        for attempt in ("medium", "HIGN", "low", "MINIMAL", "7"):
            self._update(thinking_level=attempt)
        self.assertIn(
            self.icp.get_param(THINKING_KEY, ""), self._selection(),
            "a stored level outside the Selection breaks the Odoo Settings "
            "page for every app in the database")

    def test_a_legal_level_is_accepted_and_stored(self):
        response = self._update(thinking_level="MEDIUM")

        self.assertEqual(status_of(response), 200, response)
        self.assertEqual(self.icp.get_param(THINKING_KEY), "MEDIUM")

    def test_an_empty_value_still_clears_the_override(self):
        """The fourth choice on the field: "Model default (recommended)"."""
        self.icp.set_param(THINKING_KEY, "HIGH")

        response = self._update(thinking_level="")

        self.assertEqual(status_of(response), 200, response)
        self.assertEqual(self.icp.get_param(THINKING_KEY, ""), "")

    def test_the_video_duration_choice_still_behaves(self):
        """The entry that was already there, so the new one cannot have
        changed the branch for everybody else."""
        self.assertEqual(
            status_of(self._update(video_default_duration_s="7")), 422)
        self.assertEqual(
            status_of(self._update(video_default_duration_s="8")), 200)


@tagged("-at_install", "post_install")
class TestThePreDeployGatePredictsTheConstraint(_Base):
    """Every value the gate flags must be one the Settings form really refuses,
    and every value it passes must be one the form really accepts."""

    RPM = "assessments_be_v2.vertex_max_rpm"
    DAILY_CAP = "assessments_be_v2.daily_llm_cap_usd"
    EVALUATOR_CAP = "assessments_be_v2.per_evaluator_llm_cap_usd"
    SIGMA = "assessments_be_v2.score_outlier_sigma"

    def _constrained_fields(self):
        """The constraint's own trigger list - the gate's single source."""
        return self.env["res.config.settings"]._check_be_llm_limits._constrains

    def setUp(self):
        super().setUp()
        # Every key the gate reads, planted at a known-good value, so a
        # deployment's own configuration cannot decide these assertions. Taken
        # from the constraint's trigger list rather than a list of keys written
        # out here, so a newly constrained field is planted - and therefore
        # really exercised below - without anyone editing this method.
        settings = self.env["res.config.settings"]
        for name in self._constrained_fields():
            key = getattr(settings._fields[name], "config_parameter", False)
            if not key:
                continue
            short = key.split(".", 1)[1]
            # The bounded three get their own default; 0 is legal and means
            # "disabled" on every negative-only field.
            self.icp.set_param(
                key,
                str(SETTING_RANGES[short][2]) if short in SETTING_RANGES
                else "0")

    def _gate(self, namespace=None):
        """Run the shipped pre-deploy script and return everything it printed.

        `namespace` is the dict the script executes in, so a test can read the
        gate's own `CHECKS` back out instead of inferring its field set from
        printed text.
        """
        with open(GATE) as handle:
            source = handle.read()
        namespace = {} if namespace is None else namespace
        namespace["env"] = self.env
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            exec(compile(source, GATE, "exec"), namespace)
        return out.getvalue()

    def _reported(self):
        """The parameter keys the gate names in its `set_param` remediation.

        Sharper than `assertIn("PROBLEM", ...)`: it says WHICH parameter was
        flagged, so a test cannot pass on somebody else's problem.
        """
        return {line.split("set_param(\'")[1].split("\'")[0]
                for line in self._gate().splitlines()
                if "set_param(" in line}

    def _form_accepts(self, **values):
        """Whether a real Settings save takes the value, constraint and all.

        Inside a savepoint, so a refusal leaves the planted parameters exactly
        as the gate is about to read them.
        """
        try:
            with self.env.cr.savepoint():
                self.env["res.config.settings"].create(values).execute()
        except Exception:
            return False
        return True

    def test_a_clean_deployment_reports_nothing(self):
        self.assertNotIn("PROBLEM", self._gate())

    def test_a_stored_zero_is_not_a_problem_because_the_form_accepts_it(self):
        """The false alarm that held a deploy back. 0 means "use the default"
        on all three, and every Settings save materialises it for a falsy
        numeric - so this is an ordinary deployment, not a broken one."""
        for key in SETTING_RANGES:
            self.icp.set_param("assessments_be_v2.%s" % key, "0")

        self.assertTrue(
            self._form_accepts(assessments_be_scoring_shards=0,
                               assessments_be_scoring_batch_size=0,
                               assessments_be_llm_max_attempts=0),
            "the constraint accepts 0 - so a gate that flags it is wrong "
            "about the thing it claims to predict")
        self.assertNotIn("PROBLEM", self._gate())

    def test_an_rpm_above_ten_thousand_is_not_a_problem(self):
        """The invented ceiling. The constraint refuses a negative and
        nothing else, because a project's quota can be any size."""
        self.icp.set_param(self.RPM, "20000")

        self.assertTrue(
            self._form_accepts(assessments_be_vertex_max_rpm=20000))
        self.assertNotIn("PROBLEM", self._gate())

    def test_a_negative_rpm_is_still_reported(self):
        self.icp.set_param(self.RPM, "-1")

        self.assertFalse(
            self._form_accepts(assessments_be_vertex_max_rpm=-1))
        self.assertIn("PROBLEM", self._gate())

    def test_a_genuinely_out_of_range_value_is_still_reported(self):
        """THE CONTROL. The gate must still catch what it was written for -
        the measured case, `scoring_shards` planted at 9."""
        self.icp.set_param("assessments_be_v2.scoring_shards", "9")

        self.assertFalse(
            self._form_accepts(assessments_be_scoring_shards=9))
        self.assertIn("PROBLEM", self._gate())

    def test_a_non_numeric_value_is_still_reported(self):
        self.icp.set_param("assessments_be_v2.scoring_batch_size", "eight")

        self.assertIn("PROBLEM", self._gate())

    def test_the_gate_checks_exactly_what_the_constraint_triggers_on(self):
        """THE ASSERTION THAT MAKES THIS PERMANENT.

        The gate is a PREDICTION of `_check_be_llm_limits`, and it was a
        narrower one than the thing it predicted: the constraint triggers on
        seven fields, the gate hand-listed four. A stored negative
        `daily_llm_cap_usd`, `per_evaluator_llm_cap_usd` or
        `score_outlier_sigma` therefore passed the gate clean and then bricked
        the whole Odoo Settings page after the upgrade - the exact failure the
        gate was written to prevent, in the fields that cost money.

        The gate now builds `CHECKS` from `_constrains` itself, so this cannot
        be satisfied by hand-adding three more entries to a second list, which
        is how the drift happened the first time. It fails if somebody
        reintroduces a hand-written set, or adds a constrained field that
        stores nothing in `ir.config_parameter` for the gate to read.
        """
        namespace = {}
        self._gate(namespace)

        checks = namespace.get("CHECKS")
        self.assertIsNotNone(
            checks,
            "the gate no longer publishes the field set it checks, so nothing "
            "can hold it level with the constraint")
        self.assertEqual(
            {name for name, _key, _label, _low, _high, _default in checks},
            set(self._constrained_fields()),
            "the pre-deploy gate and the constraint it predicts have drifted - "
            "every field in @api.constrains must be one the gate reads")

    def test_a_negative_spend_cap_or_sigma_is_reported(self):
        """THE GAP THAT PARITY CLOSES, one field at a time.

        `vertex.spend_cap` returns a stored negative verbatim and both budget
        gates read `cap > 0`, so -100 does not lower the cap, it removes it.
        The form refuses it now; the gate has to say so BEFORE the upgrade,
        because afterwards Settings cannot be saved at all.
        """
        for key, field in (
                (self.DAILY_CAP, "assessments_be_daily_llm_cap_usd"),
                (self.EVALUATOR_CAP,
                 "assessments_be_per_evaluator_llm_cap_usd"),
                (self.SIGMA, "assessments_be_score_outlier_sigma")):
            with self.subTest(setting=key):
                self.icp.set_param(key, "-1")

                self.assertFalse(
                    self._form_accepts(**{field: -1}),
                    "%s must be refused by the form, or the gate is "
                    "predicting nothing" % field)
                self.assertIn(
                    key, self._reported(),
                    "%s stored negative would brick the Settings page after "
                    "the upgrade and the gate did not name it" % key)

                self.icp.set_param(key, "0")

    def test_a_legal_cap_or_sigma_including_zero_is_not_reported(self):
        """A GATE THAT CRIES WOLF GETS IGNORED, and this one already did once.

        0 is not "unset" on these three, it is a deliberate setting - the cap
        or the outlier flag is DISABLED - and there is no upper bound to
        exceed, because a customer's budget can be any size. An invented
        ceiling here is what once flagged a legitimate 20000 rpm.
        """
        for key, field, value in (
                (self.DAILY_CAP, "assessments_be_daily_llm_cap_usd", 0),
                (self.DAILY_CAP, "assessments_be_daily_llm_cap_usd", 25000),
                (self.EVALUATOR_CAP,
                 "assessments_be_per_evaluator_llm_cap_usd", 0),
                (self.SIGMA, "assessments_be_score_outlier_sigma", 0),
                (self.SIGMA, "assessments_be_score_outlier_sigma", 4.5)):
            with self.subTest(setting=key, value=value):
                self.icp.set_param(key, str(value))

                self.assertTrue(
                    self._form_accepts(**{field: value}),
                    "the form accepts %s=%s - a gate that flags it is wrong "
                    "about the thing it claims to predict" % (field, value))
                self.assertNotIn(key, self._reported())

    def test_the_write_api_bounds_come_from_the_same_table(self):
        """The third copy. The route refuses at the door on these numbers, so
        a drift here is a route stricter or looser than the form it protects."""
        for key, (low, high, _default) in SETTING_RANGES.items():
            with self.subTest(setting=key):
                self.assertEqual(
                    write_api._SETTING_BOUNDS["assessments_be_v2.%s" % key],
                    (low, high))
