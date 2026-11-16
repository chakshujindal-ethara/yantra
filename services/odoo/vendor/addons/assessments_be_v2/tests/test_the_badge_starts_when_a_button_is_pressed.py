# -*- coding: utf-8 -*-
"""swe-odoo-ui-1, -2, -3 and pm-ux-admin-10: the status badge starts when a
button is pressed, stops when nothing was asked for, and keeps unsaved edits.

1. IT STARTS. `display_notification`'s handler returns `params.next` and
   nothing else, so every queue button's notification carries a `next`
   (`act_window_close`) that reloads the form. The widget schedules from
   `onWillUpdateProps` too, not only `onWillStart`, so the reload that hands
   an already-mounted badge a busy record starts the poll.

2. IT STOPS. `pending` is the queue state AND the default `llm_state` of every
   evaluator, so the Candidates tab gates its badge on `scoring_requested`
   (`busy_if`); otherwise it polls everybody who has not sat the exam (132
   reads in 240 s, measured).

3. ITS RELOAD KEEPS UNSAVED EDITS. `_setData` without `keepChanges` empties
   `_changes`, so the settle does not call `root.load()` on a dirty record;
   it marks the badge stale instead.

The JS half is asserted against the asset source, as `test_the_badge_backs_off`
does for the same file: the module has no JS test runner and the defect IS the
code in that file.
"""
import os
import re
from uuid import uuid4

from lxml import etree

from odoo.tests.common import TransactionCase, tagged

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_JS = os.path.join(_ROOT, "static/src/fields/auto_refresh/auto_refresh.js")

#: The queue buttons whose notification must reload the form. Each is (model,
#: method); all of them flip a state the badge renders.
_QUEUE_ACTIONS = [
    ("assessments.be", "action_llm_score_all"),
    ("assessments.be", "action_llm_score_failed"),
    ("assessments.be", "action_kill_scoring"),
    ("assessments.be.evaluator", "action_queue_llm_score"),
    ("assessments.be.evaluator", "action_reset_failed_scoring"),
    ("assessments.be.prompt", "action_generate_from_sop"),
    ("assessments.be.prompt", "action_extract_tags"),
]


@tagged("-at_install", "post_install")
class TestTheBadgeStartsWhenAButtonIsPressed(TransactionCase):

    def setUp(self):
        super().setUp()
        with open(_JS, encoding="utf-8") as fh:
            self.js = fh.read()

    # ── 1. the notification reloads the form ───────────────────────────────

    def test_every_queue_action_asks_the_client_to_reload(self):
        """Source-level, because the alternative is driving seven buttons
        through a browser to assert one dict key. The key is the fix."""
        import inspect
        missing = []
        for model, method in _QUEUE_ACTIONS:
            src = inspect.getsource(getattr(type(self.env[model]), method))
            if '"next"' not in src:
                missing.append("%s.%s" % (model, method))
        self.assertFalse(
            missing,
            "these queue actions return a notification the web client cannot "
            "act on, so the form they were pressed from is never reloaded: %s"
            % ", ".join(missing))

    def test_the_reload_is_an_act_window_close(self):
        import inspect
        src = inspect.getsource(
            type(self.env["assessments.be"]).action_llm_score_all)
        self.assertIn('"next": {"type": "ir.actions.act_window_close"}', src)

    def test_the_notifications_no_longer_tell_the_admin_to_refresh(self):
        import inspect
        for model, method in _QUEUE_ACTIONS:
            src = inspect.getsource(getattr(type(self.env[model]), method))
            self.assertNotIn(
                "refresh to see", src,
                "%s.%s still asks for a manual refresh" % (model, method))

    def test_the_widget_reschedules_when_it_is_handed_a_new_record(self):
        self.assertIn("onWillUpdateProps", self.js)
        block = self.js.split("onWillUpdateProps(", 1)[1].split("});", 1)[0]
        self.assertIn("_maybeSchedule(next)", block,
                      "a reload that hands an already-mounted badge a busy "
                      "record must start the poll")
        # R5-01: `this.props` is still the OLD record inside the hook, so a
        # check made on it saw "idle" and never scheduled (0 reads in 20 s).
        self.assertNotIn("this.rawValue", block)
        self.assertIn("next.record.data[next.name]", block)
        schedule = self.js.split("\n    _maybeSchedule(", 1)[1].split(
            "\n    }\n", 1)[0]
        self.assertIn("this._isBusy(props)", schedule)
        self.assertIn("_delay = POLL_MS", block,
                      "a new run starts at the short interval, not at the "
                      "ceiling the previous one crept to")

    # ── 2. it is busy only when the work was asked for ─────────────────────

    def test_the_widget_can_be_gated_on_a_second_field(self):
        body = self.js.split("\n    _isBusy(props)", 1)[1].split("\n    }\n", 1)[0]
        self.assertIn("busyIf", body)
        self.assertIn("data[gate]", body)

    def test_the_candidates_tab_gates_on_scoring_requested(self):
        view = self.env.ref("assessments_be_v2.assessments_be_form")
        arch = etree.fromstring(
            self.env["assessments.be"].get_view(view.id, "form")["arch"])
        badges = arch.xpath("//field[@widget='be_auto_refresh']"
                            "[@name='llm_state']")
        self.assertTrue(badges, "the candidates roster lost its badge")
        for node in badges:
            self.assertIn("scoring_requested", node.get("options") or "",
                          "a `pending` evaluator nobody queued must not poll")
        self.assertTrue(
            arch.xpath("//field[@name='scoring_requested']"),
            "the gating field has to be in the arch for the widget to read it")

    def test_an_evaluator_nobody_queued_is_not_flagged_as_grading(self):
        """The data behind the gate: a fresh attempt is `pending` with
        `scoring_requested` unset, which is what makes the old busy set
        wrong for this list."""
        assessment = self.env["assessments.be"].create(
            {"name": "Poll %s" % uuid4().hex[:6]})
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Nobody Queued",
            "email_from": "nq_%s@example.com" % uuid4().hex[:8],
        })
        ev = self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        })
        self.assertEqual(ev.llm_state, "pending")
        self.assertFalse(ev.scoring_requested)

    # ── 3. the settle reload keeps unsaved edits ───────────────────────────

    def test_the_settle_does_not_reload_over_unsaved_edits(self):
        body = self.js.split("\n    async _poll()", 1)[1]
        settle = body.split("if (!this.busySet.has(serverVal)", 1)[1]
        guard = settle.split("rec.model.root.load()", 1)[0]
        self.assertIn("rec.model.root.dirty", guard,
                      "a settle must not throw away what the admin typed")
        self.assertTrue(
            re.search(r"state\.stale\s*=\s*true", guard),
            "and it has to say so, or the new status is simply hidden")
