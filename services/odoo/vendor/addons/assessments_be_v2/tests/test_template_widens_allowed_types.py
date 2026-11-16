"""A chosen template's own type must be usable, without a second manual step.

THE LIVE INCIDENT THIS PINS. An operator set `Questions to generate = 10`,
`MCQ x 3`, and a saved A/B template `x 2` - but left "Allowed question types"
at just `MCQ` (the template picker and the type picker are two different
controls, and nothing forced them to agree). The run produced 10/10 MCQ and
0 from the template: every item the model wrote for the template's shape
(`image_ab`) resolved to a type outside `allowed` and was discarded before
validation ever ran, so the template's quota could never be met no matter what
the model returned - and NOTHING on screen said so.

`_widen_allowed_for_templates` is the fix: picking a template already declares
intent to generate that shape, so its own question type is added to `allowed`
automatically. This is a pure function on plain data - no Vertex call, no DB
row beyond what a bare dict needs - so this file needs no mocking at all.
"""
from odoo.tests.common import TransactionCase

from ..services.vertex import _widen_allowed_for_templates


def _spec(question_type):
    return {"name": "T", "question_type": question_type, "instructions": ""}


class TestTemplateWidensAllowed(TransactionCase):

    def test_the_reported_incident_exactly(self):
        """allowed=('mcq',), template maps to image_ab -> image_ab must join."""
        allowed = ("mcq",)
        template_specs = {"template:5": _spec("image_ab")}

        widened = _widen_allowed_for_templates(allowed, template_specs)

        self.assertEqual(widened, ("mcq", "image_ab"))

    def test_a_template_whose_type_is_already_allowed_changes_nothing(self):
        allowed = ("mcq", "image_ab")
        template_specs = {"template:5": _spec("image_ab")}

        self.assertEqual(
            _widen_allowed_for_templates(allowed, template_specs), allowed)

    def test_auto_mode_is_never_narrowed(self):
        """THE REGRESSION THIS MUST NOT CAUSE.

        An empty `allowed` means Auto - the model chooses freely. Widening an
        empty tuple would flip Auto into "only this template's type", silently
        narrowing every free-choice item in the run for every generator that
        has never touched Advanced Options.
        """
        template_specs = {"template:5": _spec("image_ab")}

        self.assertEqual(_widen_allowed_for_templates((), template_specs), ())

    def test_multiple_templates_each_contribute_their_type(self):
        allowed = ("mcq",)
        template_specs = {
            "template:5": _spec("image_ab"),
            "template:7": _spec("image_label"),
        }

        widened = _widen_allowed_for_templates(allowed, template_specs)

        self.assertEqual(set(widened), {"mcq", "image_ab", "image_label"})

    def test_the_same_type_from_two_templates_is_not_duplicated(self):
        allowed = ("mcq",)
        template_specs = {
            "template:5": _spec("image_ab"),
            "template:6": _spec("image_ab"),
        }

        widened = _widen_allowed_for_templates(allowed, template_specs)

        self.assertEqual(widened.count("image_ab"), 1)

    def test_no_templates_at_all_changes_nothing(self):
        allowed = ("mcq", "subjective_rubric")

        self.assertEqual(_widen_allowed_for_templates(allowed, {}), allowed)

    def test_a_template_with_no_resolvable_type_is_ignored(self):
        """An unresolved template was already dropped from quotas upstream;
        this must not crash on a spec missing its question_type."""
        allowed = ("mcq",)
        template_specs = {"template:5": {"name": "T", "instructions": ""}}

        self.assertEqual(
            _widen_allowed_for_templates(allowed, template_specs), allowed)
