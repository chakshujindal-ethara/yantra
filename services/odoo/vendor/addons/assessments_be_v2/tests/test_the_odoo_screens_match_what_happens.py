# -*- coding: utf-8 -*-
"""Odoo buttons and labels say what they do.

S1 (G1-08, Q8), Q13 (G1-12, B4-04), S6 (R5-02, G4-14), S7 (G4-06, B4-24),
S8 (Q10, G4-07), N1 (G4-09), N7 (B4-11), N8 (G6-11, B4-17). The invitation
(S9, Q11) is in test_a_timed_out_question_is_not_an_answer.py and the badge
start (S15, R5-01) in test_the_badge_starts_when_a_button_is_pressed.py.
"""
import base64
import json
import os
from unittest.mock import patch
from uuid import uuid4

from lxml import etree

from odoo import tools
from odoo.tests.common import TransactionCase, tagged
from odoo.tools.safe_eval import safe_eval
from odoo.tools.view_validation import get_expression_field_names

from .test_individual_scoring_stays_individual import _Paper

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_EDITOR = os.path.join(_ROOT, "static/src/fields/form_item_editor")


def _arch(env, xmlid, model, view_type="form"):
    view = env.ref("assessments_be_v2.%s" % xmlid)
    return etree.fromstring(env[model].get_view(view.id, view_type)["arch"])


def _hidden(node, record):
    """Evaluate a button's `invisible` against the record, as the client does."""
    expr = node.get("invisible") or "False"
    names = sorted(get_expression_field_names(expr))
    values = record.read(names)[0] if names else {}
    return bool(safe_eval(expr, {n: values.get(n) for n in names}))


@tagged("-at_install", "post_install")
class TestScoringButtonsWaitForAStoppingKill(_Paper, TransactionCase):
    """S1: a click during 'stopping' was parked straight back to cancelled."""

    def setUp(self):
        super().setUp()
        # The re-score buttons are Admin-only, so the arch drops them otherwise.
        self.env.user.group_ids = [
            (4, self.env.ref("assessments_be_v2.group_assessment_manager").id)]
        self._pin_settings()
        self.paper.state = "in_progress"
        self.ev = self._candidate(2)
        self.answer = self.ev.response_ids[:1]
        # A second candidate the kill is still waiting on.
        self._candidate(1).write({"llm_state": "scoring",
                                  "scoring_requested": True})

    def _buttons(self, xmlid, model, method):
        nodes = _arch(self.env, xmlid, model).xpath(
            "//button[@name='%s']" % method)
        self.assertTrue(nodes, "%s lost its %s button" % (xmlid, method))
        return nodes

    def _set_stopping(self, stopping):
        self.paper.scoring_cancel_requested = stopping
        self.env.invalidate_all()
        self.assertEqual(self.paper.scoring_phase,
                         "stopping" if stopping else "scoring")

    def _assert_hidden_only_while_stopping(self, record, nodes):
        self._set_stopping(False)
        visible = [n for n in nodes if not _hidden(n, record)]
        self.assertTrue(visible, "the fixture must show the button first")
        self._set_stopping(True)
        for node in visible:
            self.assertTrue(_hidden(node, record),
                            "%s is offered while a kill is stopping"
                            % node.get("name"))

    def test_the_paper_header_hides_run_and_retry(self):
        # Retry shows only with a failed candidate to retry.
        self._candidate(1).write({"llm_state": "failed",
                                  "scoring_requested": False})
        for method in ("action_llm_score_all", "action_llm_score_failed"):
            self._assert_hidden_only_while_stopping(
                self.paper,
                self._buttons("assessments_be_form", "assessments.be", method))

    def test_the_attempt_form_hides_both_rescore_buttons(self):
        nodes = self._buttons("assessments_be_evaluator_form",
                              "assessments.be.evaluator",
                              "action_rescore_individually")
        self.assertEqual(len(nodes), 2)
        self._assert_hidden_only_while_stopping(self.ev, nodes)
        self.ev.results_released = True
        self._assert_hidden_only_while_stopping(self.ev, nodes)

    def test_the_answer_form_hides_both_rescore_buttons(self):
        nodes = self._buttons("assessments_be_response_form",
                              "assessments.be.response",
                              "action_rescore_this_answer")
        self.assertEqual(len(nodes), 2)
        self._assert_hidden_only_while_stopping(self.answer, nodes)
        self.ev.results_released = True
        self._assert_hidden_only_while_stopping(self.answer, nodes)


@tagged("-at_install", "post_install")
class TestTheOlderReleaseButtonsAsk(TransactionCase):
    """Q13: two Release buttons still released on one click."""

    def test_the_attempt_form_and_the_attempts_list_confirm(self):
        for xmlid, view_type in (("assessments_be_evaluator_form", "form"),
                                 ("assessments_be_evaluator_tree", "list")):
            arch = _arch(self.env, xmlid, "assessments.be.evaluator", view_type)
            buttons = arch.xpath("//button[@name='action_release_results']")
            self.assertTrue(buttons, xmlid)
            for button in buttons:
                self.assertIn("cannot be undone", button.get("confirm") or "",
                              "%s releases on one click" % xmlid)


@tagged("-at_install", "post_install")
class TestArchivingATemplateNeverBlocks(TransactionCase):
    """S6: archiving a generator's only pick raised a question-type error."""

    def setUp(self):
        super().setUp()
        self.Template = self.env["assessments.be.task.template"]
        self.types = self.env["assessments.be.question.type"].search([], limit=2)
        self.assertEqual(len(self.types), 2)

    def _template(self):
        return self.Template.create({
            "name": "Tpl %s" % uuid4().hex[:6],
            "structure_json": [{"title": "S", "items": [{
                "kind": "multipleChoice", "title": "Which?",
                "options": [{"label": "A"}, {"label": "B"}]}]}],
        })

    def _generator(self, quotas, count):
        return self.env["assessments.be.prompt"].create({
            "name": "Gen %s" % uuid4().hex[:6],
            "allowed_question_type_ids": [(6, 0, self.types.ids)],
            "shape_quota_json": json.dumps(
                {"template:%d" % t.id: n for t, n in quotas}),
            "sop_question_count": count,
        })

    def test_the_only_pick_goes_and_the_count_goes_back_to_auto(self):
        tpl = self._template()
        # What the chip widget and Flutter write: one pick x1, count 1.
        gen = self._generator([(tpl, 1)], 1)

        tpl.write({"active": False})

        self.assertFalse(gen.shape_quota_json)
        self.assertEqual(gen.sop_question_count, 0)
        self.assertEqual(gen.question_count_mode, "auto")
        self.assertIn("Questions to generate: Auto", self._note(gen, tpl),
                      "the generator's chatter says what changed")

    def _note(self, gen, tpl):
        notes = gen.message_ids.filtered(lambda m: tpl.name in (m.body or ""))
        self.assertEqual(len(notes), 1)
        return notes.body

    def test_a_pinned_count_follows_the_remaining_picks(self):
        dead, live = self._template(), self._template()
        gen = self._generator([(dead, 1), (live, 1)], 2)
        dead.write({"active": False})
        self.assertEqual(gen.sop_question_count, 1,
                         "the sum, not raised to the number of types")
        self.assertIn("Questions to generate: 1.", self._note(gen, dead))

    def test_auto_stays_auto(self):
        dead, live = self._template(), self._template()
        gen = self._generator([(dead, 2), (live, 3)], 0)
        dead.write({"active": False})
        self.assertEqual(gen.sop_question_count, 0)
        self.assertEqual(json.loads(gen.shape_quota_json),
                         {"template:%d" % live.id: 3})


@tagged("-at_install", "post_install")
class TestTheGeneratorBadge(TransactionCase):
    """S7: Auto read "This run will generate 0 question(s)"; S8: Draft from
    SOP is hidden for this push."""

    def _gen(self, count=0, types=0):
        return self.env["assessments.be.prompt"].create({
            "name": "Gen %s" % uuid4().hex[:6],
            "sop_question_count": count,
            "allowed_question_type_ids": [(6, 0, self.env[
                "assessments.be.question.type"].search([], limit=types).ids
                if types else [])],
        })

    def test_auto_says_the_model_decides(self):
        self.assertEqual(self._gen().effective_question_label, "Model decides")
        self.assertEqual(self._gen(types=2).effective_question_label,
                         "Model decides - at least 2 question(s)")

    def test_a_fixed_count_is_stated(self):
        self.assertEqual(self._gen(count=5).effective_question_label,
                         "This run will generate 5 question(s)")

    def test_the_form_renders_the_label(self):
        arch = _arch(self.env, "assessments_be_prompt_form",
                     "assessments.be.prompt")
        self.assertTrue(arch.xpath("//field[@name='effective_question_label']"))
        self.assertNotIn("This run will generate", etree.tostring(
            arch, encoding="unicode"), "the words come from the field")

    def test_draft_from_sop_is_hidden(self):
        self.env.user.group_ids = [
            (4, self.env.ref("assessments_be_v2.group_assessment_manager").id)]
        arch = _arch(self.env, "assessments_be_prompt_form",
                     "assessments.be.prompt")
        gen = self._gen()
        gen.resource_ids = [(0, 0, {"name": "sop.txt", "category": "sop",
                                    "file": base64.b64encode(b"SOP")})]
        self.assertTrue(gen.has_sop_resource)
        nodes = arch.xpath("//button[@name='action_draft_task_template']")
        self.assertTrue(nodes)
        for node in nodes:
            self.assertTrue(_hidden(node, gen))


@tagged("-at_install", "post_install")
class TestTheParallelCallsHelpAddsUp(TransactionCase):
    """N1: the help left out the split across lanes (said 12, code gave 3)."""

    def test_the_worked_examples_are_what_the_code_does(self):
        icp = self.env["ir.config_parameter"].sudo()
        icp.set_param("assessments_be_v2.scoring_parallel_calls", "4")
        icp.set_param("assessments_be_v2.scoring_shards", "4")
        help_text = self.env["res.config.settings"]._fields[
            "assessments_be_scoring_parallel_calls_effective"].help
        Assessment = self.env["assessments.be"]
        with patch.dict(tools.config._runtime_options, {"db_maxconn": 64}):
            self.assertEqual(Assessment._scoring_parallel_calls(), 3)
        self.assertIn("pool 64 with 4 lanes gives 3", help_text)
        with patch.dict(tools.config._runtime_options, {"db_maxconn": 600}):
            self.assertEqual(Assessment._scoring_parallel_calls(), 4)
        self.assertIn("pool 600 gives the full setting", help_text)


@tagged("-at_install", "post_install")
class TestTheImportDialogHasNoRepoPath(TransactionCase):
    """N7: the dialog pointed admins at a repo file they cannot open."""

    def test_no_docs_path(self):
        arch = etree.tostring(_arch(
            self.env, "assessments_be_bank_import_wizard_form",
            "assessments.be.bank.import.wizard"), encoding="unicode")
        self.assertNotIn("ETP_KNOWLEDGE_BASE", arch)
        self.assertNotIn("docs/", arch)


@tagged("-at_install", "post_install")
class TestFormStudioSaysPublished(TransactionCase):
    """N8: the read-only form said "edit it here", and "Sent" survived the
    rename to Publish."""

    def _read(self, name):
        with open(os.path.join(_EDITOR, name), encoding="utf-8") as fh:
            return fh.read()

    def test_the_edit_banner_is_off_on_a_read_only_form(self):
        js = self._read("form_item_editor.js")
        getter = js.split("get alreadySent()", 1)[1].split("\n    }", 1)[0]
        self.assertIn("!this.props.readonly", getter)

    def test_no_sent_vocabulary_is_left(self):
        text = self._read("form_item_editor.js") + self._read(
            "form_item_editor.xml")
        for old in ("would be sent", "Ready to send", "already been sent",
                    "cannot be sent yet", "can be sent, but", "Cannot be sent"):
            self.assertNotIn(old, text)
        columns = _arch(self.env, "etp_studio_form_tree", "etp.studio.form",
                        "list").xpath("//field[@name='published']")
        self.assertEqual(columns[0].get("string"), "Published")
        filters = _arch(self.env, "etp_studio_form_search", "etp.studio.form",
                        "search").xpath("//filter")
        self.assertFalse([f for f in filters if "Sent" in (f.get("string") or "")])
