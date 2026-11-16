# -*- coding: utf-8 -*-
"""The Form Studio import template, and the two drifts it exists to prevent.

The template is a STRUCTURE - one empty item of every element kind, with every
slot an author can write present and blank - so the usual "the template imports
itself" assertion its question-bank sibling makes
(`test_import_parity.py::test_the_harness_json_template_imports_itself`) is the
wrong shape here: an unfilled template is deliberately NOT publishable. The
property that replaces it is stronger and is pinned below: publishing an
unfilled template names every slot still blank, item by item, in the operator's
own words. That is what turns "it does not publish" from a defect into the
feature.

The two drifts:

* a kind added to `constants.FORM_ITEM_KINDS` and not to the template, which
  would leave an element nobody can discover from the file the product hands out;
* a `needs` token added to the catalogue with no seeder, which would ship an item
  missing a slot and say nothing.

Both fail here rather than shipping.
"""
import base64
import json

from odoo.tests import tagged
from odoo.tests.common import HttpCase, TransactionCase

from ..constants import FORM_ITEM_KIND_BY_CODE, FORM_ITEM_KINDS
from ..models.studio_form import MAX_STRUCTURE_BYTES
from ..services import form_json_template as template


def _items_by_kind(payload):
    """``{kind: (section_index, item_index, item)}`` over the whole document."""
    found = {}
    for section_index, section in enumerate(payload["sections"]):
        for item_index, item in enumerate(section["items"]):
            found[item["kind"]] = (section_index, item_index, item)
    return found


class TestTheFormTemplateCoversTheCatalogue(TransactionCase):

    def setUp(self):
        super().setUp()
        self.payload = template.template_payload()
        self.by_kind = _items_by_kind(self.payload)

    def test_every_catalogue_kind_is_templated_or_skipped_by_name(self):
        """The coverage guard. A kind added to `constants.FORM_ITEM_KINDS` is in
        the template or in `SKIPPED_KINDS` - never merely absent, because an
        element missing from the template is an element an author importing a
        file cannot discover exists."""
        for kind in FORM_ITEM_KINDS:
            code = kind["kind"]
            if code in template.SKIPPED_KINDS:
                self.assertNotIn(
                    code, self.by_kind,
                    "%r is in SKIPPED_KINDS and in the template - it cannot be "
                    "both" % code)
                continue
            self.assertIn(
                code, self.by_kind,
                "%r is in the kind catalogue but not in the import template. "
                "Add it, or name it in services/form_json_template."
                "SKIPPED_KINDS with the reason." % code)

    def test_the_template_carries_no_kind_the_catalogue_does_not_have(self):
        catalogue = {kind["kind"] for kind in FORM_ITEM_KINDS}
        self.assertEqual(set(self.by_kind) - catalogue, set())

    def test_every_needs_token_seeds_at_least_one_key(self):
        """The seeding guard.

        `multi_key` is the one token that legitimately writes nothing - it names
        a RULE (several options may be marked correct), not a panel - so it is
        named here rather than left to a blanket exemption.
        """
        base = {"kind", "title", "help", "_note"}
        for kind in FORM_ITEM_KINDS:
            if kind["kind"] in template.SKIPPED_KINDS:
                continue
            for token in kind.get("needs") or ():
                if token == "multi_key":
                    continue
                bare = template.blank_item(dict(kind, needs=()))
                seeded = template.blank_item(dict(kind, needs=(token,)))
                self.assertTrue(
                    set(seeded) - set(bare) - base,
                    "the `needs` token %r on kind %r seeds no key - add a "
                    "seeder for it in services/form_json_template._SLOTS"
                    % (token, kind["kind"]))

    def test_an_unknown_needs_token_is_refused_by_name(self):
        """Refusing beats seeding nothing: a token that silently did nothing
        would ship a kind with a slot missing and no test could see it."""
        with self.assertRaises(ValueError) as caught:
            template.blank_item(
                {"kind": "madeUp", "hint": "", "needs": ("no_such_token",),
                 "flags": ()})
        self.assertIn("no_such_token", str(caught.exception))
        self.assertIn("madeUp", str(caught.exception))

    def test_a_family_no_section_claims_is_refused_by_name(self):
        """The same guard one level up: a kind in a NEW family would otherwise
        vanish from the template while every per-kind check still passed."""
        original = template._SECTIONS
        try:
            template._SECTIONS = (
                {"title": "only choices", "description": "",
                 "families": ("choice",)},
            )
            with self.assertRaises(ValueError) as caught:
                template.template_payload()
            self.assertIn("written", str(caught.exception))
        finally:
            template._SECTIONS = original

    def test_no_dead_flag_is_offered(self):
        """`allow_other` is a real flag on the three choice kinds and publish
        DROPS it with a warning (`studio_form._item_spec`), so a template naming
        it would teach a field that cannot survive."""
        for _kind, (_s, _i, item) in self.by_kind.items():
            self.assertNotIn("allow_other", item)

    def test_every_declared_flag_is_seeded_or_named_dead(self):
        """The flag guard, the sibling of the `needs` one above.

        A flag is the ONE part of an item the back-office editor never seeds -
        `newItem` writes no flag key at all, the switch writes it on the first
        toggle - so the template is the only place an author reading JSON can
        discover one exists. A flag added to `constants.FORM_ITEM_KINDS` would
        otherwise miss the template in silence.
        """
        for kind in FORM_ITEM_KINDS:
            code = kind["kind"]
            if code in template.SKIPPED_KINDS:
                continue
            item = self.by_kind[code][2]
            for flag in kind.get("flags") or ():
                name = flag["name"]
                if name in template._DEAD_FLAGS:
                    self.assertNotIn(
                        name, item,
                        "%r on kind %r is in _DEAD_FLAGS and in the template - "
                        "it cannot be both" % (name, code))
                    continue
                self.assertIn(
                    name, item,
                    "the flag %r on kind %r is not seeded in the template - "
                    "seed it in services/form_json_template.blank_item, or "
                    "name it in _DEAD_FLAGS with the reason" % (name, code))
                self.assertIs(
                    item[name], False,
                    "the flag %r on kind %r is seeded ON - a template is every "
                    "slot BLANK, and a switch pre-set is a decision made for "
                    "the author" % (name, code))

    def test_the_golden_key_is_spelled_the_way_publish_reads_it(self):
        """`scale_golden` / `rating_golden` are the Flutter designer's typed
        fields and `studio_form` never reads either - it reads `golden_answer`
        for every kind whose `needs` carry a golden token, the two scales
        included. A template spelling it the other way would hand out a file
        that is refused with the value plainly in it."""
        for code in ("linearScale", "rating"):
            item = self.by_kind[code][2]
            self.assertIn("golden_answer", item)
            self.assertNotIn("scale_golden", item)
            self.assertNotIn("rating_golden", item)

    def test_the_note_is_the_catalogue_hint(self):
        """ONE HOME for the guidance. The sentence beside each kind in
        `constants.py` is what the Odoo editor already shows; carrying it in the
        item means the file documents itself and there is no second copy to fall
        behind. `_note` rather than `help` because it must reach the AUTHOR and
        nobody else - see the next test."""
        hints = {kind["kind"]: kind["hint"] for kind in FORM_ITEM_KINDS}
        for code, (_s, _i, item) in self.by_kind.items():
            self.assertEqual(item["_note"], hints[code])

    def test_no_templated_item_carries_candidate_facing_text(self):
        """`help` IS THE CANDIDATE'S TEXT, not a comment field. `_item_spec`
        publishes it as the question's `description` and a `textBlock`'s becomes
        the next question's lead text, so anything seeded there is read by the
        person sitting the exam. Every slot in a template is blank, and `help`
        is not an exception to that."""
        for code, (_s, _i, item) in self.by_kind.items():
            self.assertEqual(
                item["help"], "",
                "%r ships a non-empty `help` - it would be published to the "
                "candidate verbatim, and `validate_structure` never inspects "
                "`help`, so Publish would not catch it" % code)

    def test_the_document_is_shaped_the_way_the_importer_reads_it(self):
        self.assertIsInstance(self.payload["sections"], list)
        self.assertTrue(self.payload["sections"])
        for section in self.payload["sections"]:
            self.assertIsInstance(section["items"], list)
            self.assertTrue(section["items"])
        # Keys the file cannot influence are left out: the importer re-mints
        # every id, forces `published` false and resets `updated_at`.
        for absent in ("id", "published", "updated_at"):
            self.assertNotIn(absent, self.payload)

    def test_the_template_is_well_under_the_document_ceiling(self):
        """512 KB is the cap the client checks before it even decodes. A
        template anywhere near it would be unreadable long before it was
        refused, so this asserts an order of magnitude of headroom rather than
        the limit itself."""
        _filename, raw = template.template_json()
        self.assertLess(len(raw), MAX_STRUCTURE_BYTES // 10)

    def test_the_bytes_are_stable_across_calls(self):
        self.assertEqual(template.template_json(), template.template_json())


class TestPublishingAnUnfilledTemplateNamesEveryGap(TransactionCase):
    """THE PROPERTY THAT REPLACES "the template imports itself".

    The template is a structure, so it is not publishable as downloaded - and
    the way an author learns what to fill in is to press Publish and read the
    refusal. `validate_structure` is the same walk publish runs, so what it says
    here is exactly what the Publish button would have said.
    """

    #: A fragment of each kind's own refusal, so this test fails if the message
    #: an author actually reads stops matching the gap they actually have.
    EXPECTED = {
        "shortAnswer": "write the golden answer",
        "paragraph": "write the golden answer",
        "multipleChoice": "has no options",
        "dropdown": "has no options",
        "checkboxes": "has no options",
        "choiceGrid": "no rows or no columns",
        "checkboxGrid": "no rows or no columns",
        "linearScale": "set the correct value",
        "rating": "set the correct value",
        "comparePair": "needs both images",
        "imageAnnotation": "has no image",
        "promptWriting": "needs the image or clip",
        "transcription": "add the clip the candidate transcribes",
    }

    #: The three that report NOTHING, and why each is correct to stay quiet.
    #: Named rather than left to a "some items have no problems" shrug, because
    #: the reason differs per kind and two of them are a real trap for an author.
    SILENT = {
        "textBlock": "informational: it carries prose and never becomes a "
                     "question, so it has no key to be missing",
        "imageBlock": "role `media`: a plate with no OPTION LABEL is "
                      "informational, and one with no url is dropped - so a "
                      "blank one is not yet a question to complain about",
        "videoBlock": "same as imageBlock",
    }

    def setUp(self):
        super().setUp()
        self.payload = template.template_payload()
        self.by_kind = _items_by_kind(self.payload)
        self.result = self.env["etp.studio.form"].validate_structure(
            self.payload["sections"])
        self.per_item = {
            (entry["section"], entry["item"]): entry
            for entry in self.result["items"]
        }

    def test_every_expected_kind_names_its_own_gap(self):
        for code, fragment in self.EXPECTED.items():
            section_index, item_index, _item = self.by_kind[code]
            entry = self.per_item.get((section_index, item_index))
            self.assertIsNotNone(
                entry, "%s reported nothing - an author filling the template "
                       "in would never be told what it needs" % code)
            joined = " ".join(entry["problems"])
            self.assertIn(
                fragment, joined,
                "%s was refused, but not in the words that tell the author "
                "what to do: %r" % (code, joined))

    def test_the_silent_kinds_are_silent_for_the_stated_reason(self):
        for code, why in self.SILENT.items():
            section_index, item_index, _item = self.by_kind[code]
            entry = self.per_item.get((section_index, item_index))
            self.assertIsNone(
                entry,
                "%s now reports a problem, but the template documents it as "
                "silent because %s - one of the two has to change" % (code, why))

    def test_every_templated_kind_is_accounted_for(self):
        """No kind may be in neither table. A kind added to the template without
        a row here would be untested, which is how the message an author reads
        drifts away from the gap they have."""
        self.assertEqual(
            set(self.by_kind),
            set(self.EXPECTED) | set(self.SILENT))

    def test_the_form_as_a_whole_says_it_cannot_be_sent(self):
        self.assertIn(
            "The form has no question that can be delivered as an exam.",
            self.result["problems"])
        self.assertEqual(self.result["questions"], 0)

    def test_no_kind_is_refused_for_a_reason_the_author_cannot_fix(self):
        """Every problem the unfilled template raises must be a MISSING SLOT,
        not an unsupported kind. `'unsupported question kind'` here would mean
        the template is handing out something publish cannot take at all."""
        everything = " ".join(
            self.result["problems"] + self.result["warnings"]
            + [line for entry in self.result["items"]
               for line in entry["problems"] + entry["warnings"]])
        self.assertNotIn("unsupported question kind", everything)
        self.assertNotIn("cannot be delivered in the exam pipeline", everything)

    def test_no_authoring_guidance_survives_the_publish_walk(self):
        """THE LEAK `help` USED TO BE. The catalogue `hint` is written for the
        AUTHOR ("Write the model answer. The judge marks each candidate against
        it..."); the template used to seed it into `help`, which `_item_spec`
        publishes as the question's `description` and `_attach_carry` folds into
        the next question's lead text. A candidate would have read it.

        Asserted in two places because neither alone is enough. The unfilled
        template's MESSAGES cannot see it - `validate_structure` builds every
        message from the item's title (`_where`) and never inspects `help`,
        which is exactly why Publish stayed silent about the leak. So the second
        half runs the same walk (`_walk_document`, what both publish and
        `validate_structure` use) over two template items filled in just enough
        to become one deliverable question, and reads the spec the candidate
        would be served. A `textBlock` above a `shortAnswer` covers both routes
        in: the carried block and the question's own help.
        """
        hints = [kind["hint"] for kind in FORM_ITEM_KINDS if kind["hint"]]
        everything = " ".join(
            self.result["problems"] + self.result["warnings"]
            + [line for entry in self.result["items"]
               for line in entry["problems"] + entry["warnings"]])
        for hint in hints:
            self.assertNotIn(hint, everything)

        block = template.blank_item(FORM_ITEM_KIND_BY_CODE["textBlock"])
        question = dict(
            template.blank_item(FORM_ITEM_KIND_BY_CODE["shortAnswer"]),
            title="A question the author wrote", golden_answer="the key")
        specs, problems, _warnings = self.env["etp.studio.form"]._walk_document(
            [{"title": "Section", "items": [block, question]}])
        self.assertEqual(problems, [], "the two filled items must publish")
        self.assertEqual(len(specs), 1)
        self.assertEqual(
            specs[0]["description"], "",
            "authoring guidance reached the candidate's question text - "
            "`help` is published, so the catalogue hint belongs in `_note`")


@tagged("-at_install", "post_install")
class TestTheFormTemplateRoute(HttpCase):
    """The route hands out the render, to a Manager, and to nobody below."""

    URL = "/api/v1/forms/template/json"

    def test_it_serves_exactly_what_the_service_renders(self):
        self.authenticate("admin", "admin")
        response = self.url_open(
            self.URL, headers={"Content-Type": "application/json"}, timeout=30)
        self.assertEqual(response.status_code, 200, response.text)
        payload = response.json()["data"]

        filename, content = template.template_json()
        self.assertEqual(payload["filename"], filename)
        self.assertEqual(payload["mimetype"], "application/json")
        self.assertEqual(base64.b64decode(payload["content"]), content)
        # And it is JSON the client can actually decode, not just bytes.
        json.loads(base64.b64decode(payload["content"]).decode("utf-8"))

    def test_a_caller_without_admin_is_refused(self):
        """THE AUTH RUNG, asserted rather than assumed. `@require_manager` is
        the same gate `/api/v1/forms/save` carries; this template publishes the
        import contract of an Admin-only authoring surface, so leaving it more
        open than the route it teaches would hand the field list to someone who
        cannot call it. Shaped after the question-bank sibling
        (`test_bank_json_template_route.py`), because it is the same rung."""
        password = "Str0ng-Test-Pass!"
        self.env["res.users"].sudo().create({
            "name": "No Rights",
            "login": "no-rights-form-template-test",
            "password": password,
            # `group_ids` on Odoo 19 - `groups_id` is the pre-19 name and would
            # be silently ignored, creating a user with NO groups at all, which
            # would refuse for the wrong reason.
            "group_ids": [(6, 0, [self.env.ref("base.group_user").id])],
        })
        self.authenticate("no-rights-form-template-test", password)

        response = self.url_open(
            self.URL, headers={"Content-Type": "application/json"}, timeout=30)
        self.assertEqual(response.status_code, 403, response.text)


class TestABlankItemIsNamedByItsPosition(TransactionCase):
    """A refusal has to say WHICH item, and the template made every title blank.

    Found in a browser, not in a test: importing the unfilled template and
    pressing Publish produced four lines that all began `"Untitled question"
    (section "2. Choices, grids and scales")` against seven blank items in that
    section. The author could see what was missing and not where, which is most
    of the value of the checklist gone.
    """

    def setUp(self):
        super().setUp()
        self.payload = template.template_payload()
        self.form = self.env["etp.studio.form"]

    def test_the_refusals_name_different_items(self):
        result = self.form.validate_structure(self.payload["sections"])
        prefixes = [entry["problems"][0].split(":")[0]
                    for entry in result["items"] if entry["problems"]]
        self.assertTrue(prefixes)
        self.assertEqual(
            len(prefixes), len(set(prefixes)),
            "two refusals name the same item, so the author cannot tell them "
            "apart: %s" % sorted(prefixes))
        for prefix in prefixes:
            self.assertNotIn("Untitled question", prefix)
            self.assertIn("question ", prefix)

    def test_a_named_item_is_still_named_not_numbered(self):
        """The position is the FALLBACK. An authored title must not be replaced
        by, or prefixed with, a number - that would be noise on every form that
        is not a blank template."""
        sections = [{"title": "Lockout", "items": [
            {"kind": "shortAnswer", "title": "Name the first step."},
        ]}]
        result = self.form.validate_structure(sections)
        message = result["items"][0]["problems"][0]
        self.assertIn('"Name the first step." (section "Lockout")', message)
        self.assertNotIn("question 1", message)

    def test_per_item_attribution_matches_the_document_walk(self):
        """`validate_structure` re-walks each item ALONE to attribute its
        problems, and its docstring promises the sentence reads identically to
        publish's. A position counted from that one-item walk would be 1 every
        time, so this is the assertion that keeps the two in step."""
        result = self.form.validate_structure(self.payload["sections"])
        for entry in result["items"]:
            # The position the message claims, read back out of it.
            for problem in entry["problems"]:
                claimed = problem.split(" (section")[0].replace("question ", "")
                self.assertEqual(
                    claimed, str(entry["item"] + 1),
                    "the one-item re-walk numbered %r as %s, but it is item %d "
                    "of its section - publish would have said something else"
                    % (problem[:60], claimed, entry["item"] + 1))
