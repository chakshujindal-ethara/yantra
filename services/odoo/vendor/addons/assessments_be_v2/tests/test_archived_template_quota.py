"""An archived task template cannot be committed to a run.

THE DEFECT. `_resolve_template_shapes` skips inactive templates - correct, an
archived template has no business generating. But nothing stopped an operator
SAVING a quota that pointed at one. The run then silently dropped that shape,
authored generic items in its place, and said so only in the post-run report:
after the spend, and after the Generate button had confidently offered
"Generate 2 questions".

Reproduced live on 2026-08-25: a quota of `{"template:16": 1}` against an
archived template produced 2 drafts with `source_template = NONE` and generic
axes, with no warning beforehand.

Also pins the sibling defect: changing the type picker must re-validate the
per-type quotas that picker authored, or they live on invisibly.
"""
import json

from odoo.tests.common import TransactionCase


class TestArchivedTemplateQuota(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Template = self.env["assessments.be.task.template"]
        self.Prompt = self.env["assessments.be.prompt"]

    def _template(self, name="A task", active=True):
        return self.Template.create({
            "name": name,
            "response": "compare_two",
            "active": active,
            "structure_json": [{"title": "S", "items": [
                {"kind": "multipleChoice", "title": "Which is better?",
                 "options": [{"label": "A"}, {"label": "B"}]},
            ]}],
        })

    # ---- the refusal -----------------------------------------------------
    def test_an_archived_template_is_named_not_just_rejected(self):
        """The operator needs to know WHICH task to restore."""
        from ..controllers.api.write import _archived_template_shapes

        tpl = self._template(name="Verify a single photo edit", active=False)

        out = _archived_template_shapes(
            self.env, {"template:%d" % tpl.id: 1})

        self.assertEqual(out, ["Verify a single photo edit"])

    def test_an_active_template_is_not_flagged(self):
        from ..controllers.api.write import _archived_template_shapes

        tpl = self._template(active=True)

        self.assertEqual(
            _archived_template_shapes(self.env, {"template:%d" % tpl.id: 2}),
            [])

    def test_a_deleted_template_is_flagged_by_shape(self):
        """Unusable for the same reason, and the shape is all we can name."""
        from ..controllers.api.write import _archived_template_shapes

        out = _archived_template_shapes(self.env, {"template:99999": 1})

        self.assertEqual(out, ["template:99999"])

    def test_type_quotas_are_ignored_by_the_archive_check(self):
        from ..controllers.api.write import _archived_template_shapes

        self.assertEqual(
            _archived_template_shapes(self.env, {"mcq": 3, "msq": 1}), [])

    def test_a_mix_reports_only_the_archived_one(self):
        from ..controllers.api.write import _archived_template_shapes

        live = self._template(name="Live task", active=True)
        dead = self._template(name="Dead task", active=False)

        out = _archived_template_shapes(self.env, {
            "template:%d" % live.id: 1,
            "template:%d" % dead.id: 1,
            "mcq": 2,
        })

        self.assertEqual(out, ["Dead task"])

    # ---- the stale-quota prune ------------------------------------------
    def test_clearing_the_allow_list_strands_no_type_quota(self):
        """The picker and the stored quota must not disagree.

        This is the arithmetic behind the "3 questions, nothing selected"
        report: `parse_shape_quotas` skipped its allow-list check entirely when
        the list was empty, so the count survived where the picker could not
        show it.
        """
        from ..constants import parse_shape_quotas

        stored = {"subjective_rubric": 1, "mcq": 2, "template:6": 1}

        self.assertEqual(
            parse_shape_quotas(stored, allowed_types=()),
            {"template:6": 1},
            "clearing every type must leave only the task quota")

    def test_narrowing_the_allow_list_drops_only_what_left(self):
        from ..constants import parse_shape_quotas

        self.assertEqual(
            parse_shape_quotas({"mcq": 2, "msq": 1}, allowed_types=("mcq",)),
            {"mcq": 2})
