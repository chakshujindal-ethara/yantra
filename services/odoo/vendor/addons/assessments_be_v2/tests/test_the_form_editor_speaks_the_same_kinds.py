# -*- coding: utf-8 -*-
"""The item editor's type list IS publish's type list, both directions.

THE DRIFT THIS EXISTS TO PREVENT. `static/src/fields/form_item_editor/` draws a
type picker, and the tempting way to build one is a list of labels in the
widget. Then the two lists disagree, and both directions are silent:

  * a kind in the PICKER and not in publish - an operator authors it, saves it,
    presses Publish and is told the item was "skipped: unsupported
    question kind", after the work is done;
  * a kind in PUBLISH and not in the picker - the pipeline supports it, the
    designer offers it, and the operator simply cannot author it in Odoo with
    nothing anywhere saying why.

So the widget asks the server (`form_item_kinds`), the server answers from
`constants.FORM_ITEM_KINDS`, and `_item_spec` branches on tuples DERIVED from
that same catalogue. This test closes the last hole in that chain: a kind whose
branch is written as a literal in `_item_spec` and never added to the catalogue.
It reads the method's own AST rather than trusting a comment, because that is
the only way to see what the code actually branches on.
"""
import ast
import inspect
import os

from odoo.tests.common import TransactionCase

from odoo.addons.assessments_be_v2 import constants
from odoo.addons.assessments_be_v2.models import studio_form

# The widget, BOTH halves of it. A `needs` token the editor does not implement is
# a field an operator can never fill in, so the kind quietly becomes unauthorable
# - the exact failure the catalogue exists to prevent, one level down. Some
# tokens are decided in JS (`newItem` seeds the fields a kind needs) and some in
# the template (`needs(item, "media_b_optional")` draws the second plate), so
# both files are read: asserting against one of them would fail for a token that
# is correctly implemented in the other.
_WIDGET_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "static", "src", "fields", "form_item_editor")
_WIDGET_FILES = ("form_item_editor.js", "form_item_editor.xml")


def _kinds_the_walk_branches_on():
    """Every kind string `_walk_section` / `_item_spec` compares against.

    Reads the two methods' AST and collects the right-hand side of every
    comparison against the local name `kind`: a literal (`kind == "textBlock"`),
    a literal tuple, or one of the `FORM_KINDS_*` tuples, which are resolved
    through `constants` so a derived tuple counts as what it contains.
    """
    tree = ast.parse(inspect.getsource(studio_form))
    wanted = {"_walk_section", "_item_spec"}
    found = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.FunctionDef) or node.name not in wanted:
            continue
        for compare in ast.walk(node):
            if not isinstance(compare, ast.Compare):
                continue
            if not (isinstance(compare.left, ast.Name)
                    and compare.left.id == "kind"):
                continue
            for comparator in compare.comparators:
                if isinstance(comparator, ast.Constant) and \
                        isinstance(comparator.value, str):
                    found.add(comparator.value)
                elif isinstance(comparator, (ast.Tuple, ast.List, ast.Set)):
                    for element in comparator.elts:
                        if isinstance(element, ast.Constant):
                            found.add(element.value)
                elif isinstance(comparator, ast.Name):
                    found.update(getattr(constants, comparator.id, ()) or ())
    return found


class TestTheEditorSpeaksTheSameKinds(TransactionCase):

    def test_every_kind_publish_branches_on_is_in_the_catalogue(self):
        """The direction a reviewer cannot see by reading the catalogue.

        Adding a branch to `_item_spec` and forgetting the catalogue entry
        leaves a kind the pipeline supports and the editor cannot offer.
        """
        missing = _kinds_the_walk_branches_on() - set(
            constants.FORM_ITEM_KIND_CODES)
        self.assertFalse(
            missing,
            "publish handles %s, and the item editor cannot offer them - add "
            "them to constants.FORM_ITEM_KINDS" % sorted(missing))

    def test_every_kind_in_the_catalogue_is_one_publish_branches_on(self):
        """And the direction that puts a dead entry in the operator's picker."""
        extra = set(constants.FORM_ITEM_KIND_CODES) - \
            _kinds_the_walk_branches_on()
        self.assertFalse(
            extra,
            "the editor offers %s and publish has no branch for them - it "
            "would author items that publish skips" % sorted(extra))

    def test_the_family_tuples_are_the_ones_the_walk_uses(self):
        """The tuples are DERIVED, so this pins that they are not retyped.

        `_item_spec` tests `kind in FORM_KINDS_CHOICE`; if that name ever became
        a hand-written literal again the two lists could drift while every other
        test here still passed.
        """
        self.assertEqual(
            constants.FORM_KINDS_CHOICE,
            ("multipleChoice", "dropdown", "checkboxes"))
        self.assertEqual(constants.FORM_KINDS_GRID,
                         ("choiceGrid", "checkboxGrid"))
        self.assertEqual(constants.FORM_KINDS_SCALE,
                         ("linearScale", "rating"))
        self.assertEqual(constants.FORM_KINDS_WRITTEN,
                         ("shortAnswer", "paragraph", "date", "time"))
        self.assertEqual(constants.FORM_KINDS_MEDIA_BLOCK,
                         ("imageBlock", "videoBlock"))
        for family in ("choice", "grid", "scale", "written", "media"):
            self.assertTrue(constants.form_item_kinds_of(family))

    def test_the_route_the_widget_calls_returns_the_catalogue(self):
        """`form_item_kinds` is the widget's ONLY source of types."""
        kinds = self.env["etp.studio.form"].form_item_kinds()
        self.assertEqual([k["kind"] for k in kinds],
                         list(constants.FORM_ITEM_KIND_ORDER))
        for kind in kinds:
            self.assertTrue(kind["label"], "%s has no label" % kind["kind"])
            self.assertIn(kind["role"],
                          ("question", "informational", "media", "refused"))
            self.assertTrue(kind["hint"], "%s has no hint" % kind["kind"])
            for flag in kind["flags"]:
                self.assertTrue(flag["name"] and flag["label"] and flag["hint"])

    def test_every_panel_the_catalogue_asks_for_is_one_the_editor_draws(self):
        """A `needs` token with no panel is a field nobody can fill in.

        Checked against the widget's source rather than a second list here: the
        token has to appear in the file that draws it, so adding one to the
        catalogue without adding its controls fails right here instead of
        showing an operator a question type with half its fields missing.
        """
        widget_source = ""
        for name in _WIDGET_FILES:
            with open(os.path.join(_WIDGET_DIR, name), encoding="utf-8") as fh:
                widget_source += fh.read()
        for kind in constants.FORM_ITEM_KINDS:
            for token in kind["needs"]:
                self.assertTrue(
                    '"%s"' % token in widget_source
                    or "'%s'" % token in widget_source,
                    'kind "%s" needs the "%s" panel and neither half of the '
                    "item editor names it" % (kind["kind"], token))

    def test_a_media_block_is_not_called_a_question_until_it_has_options(self):
        """The `role` an operator reads has to match what publish does.

        `_media_item_has_options` is what turns a plate from a carry-forward
        block into the question itself, and the catalogue's fourth role exists
        to say so - a picker calling every image "Question" would promise a mark
        that is not there.
        """
        by_code = constants.FORM_ITEM_KIND_BY_CODE
        self.assertEqual(by_code["imageBlock"]["role"], "media")
        self.assertEqual(by_code["videoBlock"]["role"], "media")
        self.assertEqual(by_code["textBlock"]["role"], "informational")
        self.assertEqual(by_code["fileUpload"]["role"], "refused")
