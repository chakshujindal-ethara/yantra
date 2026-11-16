# -*- coding: utf-8 -*-
"""The item editor's red lines ARE publish's refusals, live and per item.

WHAT THIS PINS. `etp.studio.form.validate_structure` is what the back-office
item editor calls as an operator works. It exists so the editor can show why a
form cannot be sent WITHOUT owning a single rule of its own: it runs
`_walk_document`, the same walk `publish_to_assessment` runs, and creates
nothing. If those two ever answer differently, the editor becomes a liar in one
of two ways - a form it calls ready that Send refuses, or a red line under an
item that would have published fine - and an operator has no way to tell which
of the two screens to believe.

So every test here compares the two ANSWERS rather than checking a message it
typed itself. The messages are deliberately not asserted verbatim: they belong
to `_item_spec`, which is free to reword them, and a copy of the wording here
would only pin the copy.

THE SECOND HALF pins the SHAPE the editor writes. The widget seeds a new item
with the fields its kind needs, keys a checkbox grid row as a LIST and a radio
grid row as a STRING, and stores an annotation's golden answers keyed by the
string form of each point number. Those choices are only correct if publish
reads them, so the last test builds one form in exactly that shape - one item of
every deliverable kind - and publishes it.
"""
import json
import uuid
from unittest.mock import patch

from odoo.tests.common import TransactionCase

from odoo.addons.assessments_be_v2.models import studio_form as studio_form_mod
from odoo.addons.assessments_be_v2.services import s3_service


class _Forms(TransactionCase):

    def _form(self, sections):
        return self.env["etp.studio.form"].create({
            "client_uid": uuid.uuid4().hex,
            "title": "Editor probe %s" % uuid.uuid4().hex[:6],
            "structure_json": sections,
        })

    def _section(self, *items, **kw):
        return {"id": uuid.uuid4().hex[:8],
                "title": kw.get("title", "Section one"),
                "items": list(items)}

    def _item(self, kind, title="A question", **extra):
        return dict({"id": uuid.uuid4().hex[:8], "kind": kind,
                     "title": title, "help": ""}, **extra)

    def _options(self, *pairs):
        """The option shape the editor writes: id, label, correct."""
        return [{"id": uuid.uuid4().hex[:6], "label": label,
                 "correct": correct} for label, correct in pairs]

    def _check(self, sections):
        return self.env["etp.studio.form"].validate_structure(sections)


class TestValidationIsPublishWithoutTheCreate(_Forms):

    # The broken shapes an operator actually produces mid-authoring. Each one
    # is refused by a DIFFERENT branch of `_item_spec`, so the parity assertion
    # below covers the whole method rather than one message.
    def _broken_items(self):
        return [
            # a choice with no answer key
            self._item("multipleChoice",
                       options=self._options(("Yes", False), ("No", False))),
            # a choice with one option, which is not a choice
            self._item("dropdown", options=self._options(("Only", True))),
            # two correct on a single-answer kind: unearnable, never mismarked
            self._item("multipleChoice",
                       options=self._options(("Yes", True), ("Also", True))),
            # a written kind with no golden answer
            self._item("paragraph"),
            # a scale whose key is outside its own range
            self._item("linearScale", scale_min=1, scale_max=5,
                       golden_answer="9"),
            # a grid with no key on one row
            self._item("choiceGrid", rows=["One", "Two"],
                       columns=["A", "B"], grid_key={"0": "A"}),
            # a radio grid row keyed twice
            self._item("choiceGrid", rows=["One"], columns=["A", "B"],
                       grid_key={"0": ["A", "B"]}),
            # a comparison missing its second plate
            self._item("comparePair", media_url="/tmp/a.png",
                       options=self._options(("A", True), ("B", False))),
            # an annotation point with no golden answer
            self._item("imageAnnotation", media_url="/tmp/p.png",
                       annotation_count=2, golden_labels={"1": "Only this"}),
            # prompt writing with no golden prompt
            self._item("promptWriting", media_url="/tmp/p.png"),
            # the one kind publish refuses outright
            self._item("fileUpload"),
        ]

    def test_it_reports_exactly_what_publish_refuses(self):
        """One assertion per broken shape, both answers from the server."""
        for item in self._broken_items():
            sections = [self._section(item)]
            form = self._form(sections)
            refused = form.publish_to_assessment()
            checked = self._check(sections)

            self.assertTrue(
                refused.get("problems"),
                "%s should be unpublishable" % item["kind"])
            self.assertEqual(
                checked["problems"], refused["problems"],
                "the editor and Send to Candidates disagree about %s"
                % item["kind"])

    def test_a_form_publish_accepts_is_a_form_the_editor_calls_ready(self):
        sections = [self._section(self._item(
            "multipleChoice",
            options=self._options(("Yes", True), ("No", False))))]
        checked = self._check(sections)

        self.assertEqual(checked["problems"], [])
        self.assertEqual(checked["questions"], 1)
        self.assertEqual(self._form(sections).publish_to_assessment()
                         .get("problems"), None)

    def test_checking_a_form_creates_nothing(self):
        """The whole reason it is safe to run on every edit.

        `publish_to_assessment` mints a generator, a question per item and a
        draft assessment. A validation that shared that half of the method would
        litter the bank with a pool per keystroke.
        """
        before = self._bank_counts()
        self._check([self._section(self._item(
            "multipleChoice",
            options=self._options(("Yes", True), ("No", False))))])
        self.assertEqual(self._bank_counts(), before)

    def _bank_counts(self):
        return (self.env["assessments.be.question"].search_count([]),
                self.env["assessments.be.prompt"].search_count([]),
                self.env["assessments.be"].search_count([]))

    def test_an_empty_form_is_refused_the_same_way_by_both(self):
        self.assertEqual(
            self._check([])["problems"],
            self._form([]).publish_to_assessment()["problems"])

    def test_junk_instead_of_a_document_does_not_raise(self):
        """The editor sends what the record holds, and a jsonb column can hold
        anything the API put there. A 500 here would take the whole tab down."""
        for junk in (None, {}, "sections", 7, [None, "x", 3]):
            self.assertTrue(self._check(junk)["problems"])

    def test_the_size_ceiling_is_reported_before_the_save_refuses_it(self):
        """`_check_structure` raises on write; that lands on top of an editor
        full of work with no way to see which item to cut. The editor asks
        first, using the same measurement."""
        big = [self._section(self._item(
            "paragraph", golden_answer="x" * 600 * 1024))]
        problems = self._check(big)["problems"]
        self.assertTrue(any("too large" in p for p in problems), problems)

    def test_a_warning_is_not_a_problem(self):
        """A date question publishes - as free text - and says so. Reporting
        that as a problem would block a form that is fine."""
        sections = [self._section(self._item("date", golden_answer="2026-01-01"))]
        checked = self._check(sections)

        self.assertEqual(checked["problems"], [])
        self.assertEqual(checked["questions"], 1)
        self.assertTrue(checked["warnings"])
        self.assertEqual(
            checked["warnings"],
            self._form(sections).publish_to_assessment()["warnings"])


class TestEachProblemNamesItsOwnItem(_Forms):
    """Per-item attribution, which is what makes the editor usable at all.

    The route's flat list is fine for a toast; an editor has to underline the
    item that is wrong. `validate_structure` walks each item alone to get that,
    so the messages stay the server's and the mapping stays exact.
    """

    def _document(self):
        good = self._item("multipleChoice", title="Good",
                          options=self._options(("Yes", True), ("No", False)))
        bad = self._item("paragraph", title="Bad")
        worse = self._item("dropdown", title="Worse",
                           options=self._options(("Only", True)))
        return [self._section(good, bad, title="First"),
                self._section(worse, title="Second")]

    def test_it_says_which_section_and_which_item(self):
        rows = self._check(self._document())["items"]
        addressed = {(row["section"], row["item"]) for row in rows}

        self.assertEqual(addressed, {(0, 1), (1, 0)},
                         "only the two broken items may be flagged")

    def test_each_row_carries_the_message_publish_would_have_given(self):
        checked = self._check(self._document())
        for row in checked["items"]:
            for problem in row["problems"]:
                self.assertIn(problem, checked["problems"])

    def test_the_message_names_the_item_and_its_section(self):
        """The prefix is what the editor strips back off to sit the message
        under the right box - see `shortProblem` in the widget."""
        rows = self._check(self._document())["items"]
        first = [r for r in rows if r["section"] == 0][0]
        self.assertTrue(
            first["problems"][0].startswith('"Bad" (section "First")'),
            first["problems"][0])

    def test_a_form_level_problem_belongs_to_no_item(self):
        """"The form has no question" is not any one item's fault, and an
        editor that filed it under one would underline an innocent card."""
        checked = self._check([self._section(
            self._item("textBlock", title="Instructions", help="Read this."))])

        self.assertTrue(checked["problems"])
        self.assertEqual([r for r in checked["items"] if r["problems"]], [])

    def test_an_unknown_kind_is_a_warning_on_its_own_item(self):
        """A form authored by a NEWER designer than this Odoo still opens, and
        the item that this build cannot deliver is the one that says so."""
        checked = self._check([self._section(
            self._item("multipleChoice", title="Fine",
                       options=self._options(("Yes", True), ("No", False))),
            self._item("hologram", title="From the future"))])

        rows = [r for r in checked["items"] if r["warnings"]]
        self.assertEqual([r["item"] for r in rows], [1])
        self.assertIn("hologram", rows[0]["warnings"][0])


class TestTheEditorWritesAShapePublishReads(_Forms):
    """The document the widget produces, published end to end.

    Every field name and value shape below is one the OWL editor writes:
    `{id, label, correct}` options, a radio grid row keyed as a STRING and a
    checkbox grid row as a LIST, an annotation's golden answers keyed by the
    string form of the point number, `media_kind` stamped from the upload's own
    content type. A mismatch in any of them is invisible in the browser - the
    editor would look right and the form would refuse to publish, or worse,
    publish with a silently empty answer key.
    """

    def _every_kind(self):
        return [
            self._section(
                self._item("textBlock", title="Read this",
                           help="Informational only."),
                self._item("multipleChoice", title="Pick one",
                           options=self._options(("Yes", True), ("No", False))),
                self._item("dropdown", title="Choose one",
                           options=self._options(("A", True), ("B", False))),
                self._item("checkboxes", title="Pick every right one",
                           options=self._options(("A", True), ("B", True),
                                                 ("C", False))),
                self._item("choiceGrid", title="One column per row",
                           rows=["Row one", "Row two"],
                           columns=["Left", "Right"],
                           grid_key={"0": "Left", "1": "Right"}),
                self._item("checkboxGrid", title="Several per row",
                           rows=["Row one", "Row two"],
                           columns=["Left", "Right"],
                           grid_key={"0": ["Left", "Right"], "1": ["Left"]}),
                title="Objective"),
            self._section(
                self._item("linearScale", title="How severe?",
                           scale_min=1, scale_max=5,
                           scale_min_label="Trivial", scale_max_label="Grave",
                           golden_answer="5"),
                self._item("rating", title="How urgent?",
                           rating_max=5, golden_answer="4"),
                self._item("shortAnswer", title="Name the first step",
                           golden_answer="Isolate the energy source."),
                self._item("paragraph", title="Explain why",
                           golden_answer="Because the cause can be fixed "
                                         "before anybody is hurt."),
                self._item("date", title="When is it due?",
                           golden_answer="2026-01-01"),
                self._item("time", title="When does the shift start?",
                           golden_answer="06:00"),
                title="Written"),
            self._section(
                self._item("imageBlock", title="What is wrong here?",
                           media_url="/api/v1/forms/media/form_studio/a.png",
                           media_kind="image",
                           options=self._options(("Blocked walkway", True),
                                                 ("Nothing", False))),
                self._item("videoBlock", title="What happens at 0:12?",
                           media_url="/api/v1/forms/media/form_studio/a.mp4",
                           media_kind="video", multi_select=True,
                           options=self._options(("A trip hazard", True),
                                                 ("A near miss", True),
                                                 ("Nothing", False))),
                self._item("comparePair", title="Which layout is safer?",
                           media_url="/api/v1/forms/media/form_studio/a.png",
                           media_url_b="/api/v1/forms/media/form_studio/b.png",
                           require_justification=True,
                           golden_answer="B keeps the walkway clear.",
                           options=self._options(("B is safer", True),
                                                 ("A is safer", False))),
                self._item("imageAnnotation", title="Name each defect",
                           media_url="/api/v1/forms/media/form_studio/p.png",
                           media_kind="image", annotation_count=2,
                           golden_labels={"1": "Missing guard",
                                          "2": "Trailing cable"}),
                self._item("promptWriting", title="Write the prompt",
                           media_url="/api/v1/forms/media/form_studio/t.png",
                           media_kind="image",
                           golden_answer="A wide shot of a clean aisle."),
                title="Media"),
        ]

    def _publish(self, sections):
        """Publish with BOTH media lanes closed off.

        `_fetch_media_b64` either reads our own S3 objects back or fetches the
        url over HTTP, and neither belongs in a test about the document's shape
        - one would depend on a configured bucket and the other on the network.
        Closing them makes publish keep `image_url` and carry a warning, which
        is the documented best-effort behaviour; `requests.get` is replaced by a
        detonator rather than a stub so an escape is a failure, not a slow test.
        """
        def never(*args, **kwargs):
            raise AssertionError("publish must not fetch media here")

        with patch.object(studio_form_mod.requests, "get", never), \
                patch.object(s3_service, "storage_target",
                             lambda env: (None, None)):
            return self._form(sections).publish_to_assessment()

    def test_one_item_of_every_deliverable_kind_publishes(self):
        sections = self._every_kind()
        checked = self._check(sections)
        self.assertEqual(checked["problems"], [], checked["problems"])

        result = self._publish(sections)
        self.assertIsNone(result.get("problems"), result.get("problems"))
        # The textBlock is informational and folds into the next question, so
        # every OTHER item is one question - and that is also the number the
        # editor's toolbar promised.
        expected = sum(len(s["items"]) for s in sections) - 1
        self.assertEqual(result["questions_created"], expected)
        self.assertEqual(checked["questions"], expected)

    def test_the_checkbox_grid_row_keyed_as_a_list_marks_both_columns(self):
        """The editor writes a list for a checkbox grid row precisely because a
        row where two columns are right cannot be said any other way. If publish
        read only the first, a candidate ticking both would score zero."""
        result = self._publish(self._every_kind())
        questions = self.env["assessments.be.question"].browse(
            self.env["assessments.be"].browse(
                result["assessment_id"]).question_ids.ids)
        grid = questions.filtered(lambda q: q.prompt == "Several per row")
        first_row = grid.question_dimension_ids.filtered(
            lambda d: d.name == "Row one")

        self.assertEqual(
            sorted(first_row.option_line_ids.filtered("is_correct")
                   .mapped("name")),
            ["Left", "Right"])

    def test_the_annotation_key_reaches_the_question_intact(self):
        """Keyed by the STRING form of the point number, which is what
        `_item_spec` looks up. A number key would read as no key at all."""
        result = self._publish(self._every_kind())
        question = self.env["assessments.be"].browse(
            result["assessment_id"]).question_ids.filtered(
                lambda q: q.question_type == "image_label")

        self.assertEqual(json.loads(question.solution_json),
                         {"1": "Missing guard", "2": "Trailing cable"})
