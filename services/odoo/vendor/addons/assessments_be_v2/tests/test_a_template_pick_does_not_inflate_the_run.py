# -*- coding: utf-8 -*-
"""pm-ux-admin-1 and swe-odoo-ui-4: the generator states what it will cost.

Picking one question template on a generator that allows four question types
keeps "Questions to generate" at 1, in Odoo (the onchange) and through the API
(`_check_question_count`) alike: per-shape counts in `shape_quota_json` state
the mix, so neither console inflates or refuses the operator's own count.

The type floor still exists: it lives in `effective_generation_count`, which
is what generation asks the model for, and the form states that number instead
of writing it into the operator's field. With no per-shape counts, a count
below the number of ticked types is still nudged up and refused.

Removing a question type drops that type's count from `shape_quota_json` on
every write, in Odoo as in the API: a leftover count is invisible in the widget
but still sent to the model as a directive, and billed. A template's count
stays: a template names its own question type.
"""
import json
from uuid import uuid4

from odoo.exceptions import ValidationError
from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestATemplatePickDoesNotInflateTheRun(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Prompt = self.env["assessments.be.prompt"]
        self.Type = self.env["assessments.be.question.type"]
        self.types = self.Type.search([], limit=4)
        self.assertEqual(len(self.types), 4, "fixture needs 4 question types")

    def _generator(self, **vals):
        values = {"name": "Gen %s" % uuid4().hex[:6]}
        values.update(vals)
        return self.Prompt.create(values)

    def _template(self):
        return self.env["assessments.be.task.template"].create({
            "name": "Task %s" % uuid4().hex[:6],
        })

    # ── the count is not raised behind the operator's back ─────────────────

    def test_one_template_and_one_question_survives_the_onchange(self):
        gen = self._generator(
            allowed_question_type_ids=[(6, 0, self.types.ids)])
        tpl = self._template()
        gen.shape_quota_json = json.dumps({"template:%d" % tpl.id: 1})
        gen.sop_question_count = 1
        gen._onchange_min_questions_for_types()
        self.assertEqual(
            gen.sop_question_count, 1,
            "the chips state the shape mix; the count must follow them")

    def test_the_same_save_is_no_longer_refused(self):
        gen = self._generator(
            allowed_question_type_ids=[(6, 0, self.types.ids)])
        tpl = self._template()
        gen.write({
            "shape_quota_json": json.dumps({"template:%d" % tpl.id: 1}),
            "sop_question_count": 1,
        })
        self.assertEqual(gen.sop_question_count, 1)

    def test_the_type_floor_still_holds_with_no_per_shape_counts(self):
        """Nothing was loosened for the plain case: a bare count below the
        number of ticked types is still refused, and the onchange still
        nudges it up."""
        gen = self.Prompt.new({
            "name": "Gen floor",
            "allowed_question_type_ids": [(6, 0, self.types.ids)],
            "sop_question_count": 1,
        })
        gen._onchange_min_questions_for_types()
        self.assertEqual(gen.sop_question_count, 4)
        with self.assertRaises(ValidationError):
            self._generator(
                allowed_question_type_ids=[(6, 0, self.types.ids)],
                sop_question_count=2)

    # ── what the run will cost is on screen ────────────────────────────────

    def test_the_form_states_what_the_run_will_actually_generate(self):
        gen = self._generator(
            allowed_question_type_ids=[(6, 0, self.types.ids)])
        tpl = self._template()
        gen.write({
            "shape_quota_json": json.dumps({"template:%d" % tpl.id: 1}),
            "sop_question_count": 1,
        })
        gen.invalidate_recordset()
        # 1 template item + one coverage item for each of the 4 ticked types.
        self.assertEqual(gen.effective_question_count, 5)

    def test_the_stated_count_is_the_one_generation_uses(self):
        from odoo.addons.assessments_be_v2.constants import (
            effective_generation_count, parse_shape_quotas)
        gen = self._generator(
            allowed_question_type_ids=[(6, 0, self.types[:2].ids)],
            sop_question_count=9)
        gen.invalidate_recordset()
        self.assertEqual(
            gen.effective_question_count,
            effective_generation_count(
                gen.sop_question_count,
                parse_shape_quotas(gen.shape_quota_json),
                tuple(gen.allowed_question_type_ids.mapped("code"))))

    # ── leftovers do not ride along ────────────────────────────────────────

    def test_dropping_a_type_drops_its_leftover_count(self):
        code = self.types[0].code
        gen = self._generator(
            allowed_question_type_ids=[(6, 0, self.types.ids)])
        gen.write({"shape_quota_json": json.dumps({code: 2})})
        gen.write({
            "allowed_question_type_ids": [(6, 0, self.types[1:].ids)]})
        gen.invalidate_recordset()
        self.assertNotIn(
            '"%s"' % code, gen.shape_quota_json or "",
            "a count for a type the generator no longer allows is a "
            "directive nothing on screen shows and the run still pays for")

    def test_a_template_count_survives_a_type_change(self):
        tpl = self._template()
        key = "template:%d" % tpl.id
        gen = self._generator(
            allowed_question_type_ids=[(6, 0, self.types.ids)])
        gen.write({"shape_quota_json": json.dumps({key: 2})})
        gen.write({
            "allowed_question_type_ids": [(6, 0, self.types[:1].ids)]})
        gen.invalidate_recordset()
        self.assertIn(key, gen.shape_quota_json or "",
                      "a template names its own question type")
