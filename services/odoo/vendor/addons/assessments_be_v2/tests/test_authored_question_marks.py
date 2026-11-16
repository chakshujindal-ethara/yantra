# -*- coding: utf-8 -*-
"""A question a HUMAN authored must be worth the marks it looks worth.

THE GAP. `question._component_counts()` is the paper's ruler, and
`test_component_marks.py` pins it hard - but only on questions the TEST builds.
Nothing pinned it on the Form Studio authoring lane
(`models/studio_form.publish_to_assessment`), so the translator could mint a
question worth less than it looks and every scoring test stayed green.

Three real defects lived in that gap, all of which FAIL SILENTLY - the paper
looks healthy and the cohort just reads as having got the question wrong:

  1. THE UNEARNABLE ANSWER KEY. Scoring matches a dimension's chosen set against
     its key set EXACTLY (`assessments.be.response._dimension_marks`), and a
     radio group submits ONE option - so a single-select item keyed with TWO
     correct options can never be equalled. It still counts in the denominator,
     and the launch gates pass (`_is_keyless` asks whether a key exists, not
     whether it is reachable). `_single_answer_or_problem` now refuses it at
     publish. Group 1, kind by kind, including the two kinds that must NOT be
     refused because they are genuinely multi-select.

  2. THE GRID KEY THAT VALIDATED AND THEN MARKED NOTHING. `choiceGrid` checked
     its per-row key with `str(...).strip()` but WROTE it from the raw value, so
     the two disagreed on anything needing coercion (integer `1` against columns
     ["1","2"], " Yes" against ["Yes","No"]). The row came out KEYLESS, dropping
     it from BOTH sides of the paper. Group 2 asserts every row publishes keyed.

  3. TWO LAUNCH GATES THAT DISAGREED. `models/assessment.action_start` treats an
     objective question with NO dimensions as keyless; the copy of `_is_keyless`
     behind `POST /api/v1/assessments/<id>/launch` kept an
     `if not dimensions: return False` exemption. The dry run reported
     `answer_keys` PASSING, the operator confirmed, and `action_start` raised a
     UserError the route does not render as a gate failure. Group 4.

ASSERTIONS END AT `_component_counts()` OR AT A REFUSAL, never at an intermediate
spec dict: a publish that produces the right spec and the wrong records is still
a wrong paper, so the cases read `question_dimension_ids`, their
`option_line_ids` and `is_correct`.

MEDIA NEVER LEAVES THE PROCESS. Fixtures point `media_url` at a
`/web/content/<id>` attachment, which `_fetch_media_b64` resolves against
`ir.attachment` directly. An http:// url would sit in `requests.get` for its 20
second timeout per image before falling back to a link.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.exceptions import UserError
from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.controllers.api import admin as admin_api
from odoo.addons.assessments_be_v2.controllers.api import common as api_common

# 1x1 PNG. Small enough to be inline, real enough for `ir.attachment` to hand
# back as image bytes.
_PNG_B64 = ("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8"
            "z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")


class _FormBase(TransactionCase):
    """Fixture factories for a Form Studio document and its publish.

    The item builders take the SAME key names `studio_form._item_spec` reads
    (`kind`, `options` with `label`/`correct`, `media_url`, `grid_key`,
    `rows`, `columns`, `golden_answer`, ...). They are deliberately thin: a
    builder that normalised anything would be testing itself rather than the
    translator.
    """

    def setUp(self):
        super().setUp()
        self.Form = self.env["etp.studio.form"]
        self.Question = self.env["assessments.be.question"]
        self.attachment = self.env["ir.attachment"].create({
            "name": "studio-media-%s.png" % uuid4().hex[:6],
            "datas": _PNG_B64,
        })
        self.media_url = "/web/content/%d" % self.attachment.id
        # A distinct second plate so an A/B pair is a genuine pair.
        self.attachment_b = self.env["ir.attachment"].create({
            "name": "studio-media-b-%s.png" % uuid4().hex[:6],
            "datas": _PNG_B64,
        })
        self.media_url_b = "/web/content/%d" % self.attachment_b.id

    # -- document ------------------------------------------------------

    def _form(self, *items):
        return self.Form.create({
            "client_uid": "form-%s" % uuid4().hex[:6],
            "title": "Studio form %s" % uuid4().hex[:6],
            "structure_json": [{"title": "Section one", "items": list(items)}],
        })

    def _publish(self, *items):
        """(form, result). The caller decides whether the result is a refusal."""
        form = self._form(*items)
        return form, form.publish_to_assessment()

    def _questions_of(self, form):
        """Every question this form minted, by the `source_ref` publish stamps.

        Searched by source_ref rather than by the result's `generator_id`,
        because a REFUSED publish returns no generator and the assertion that
        matters there is precisely that no question exists.
        """
        return self.Question.search(
            [("source_ref", "=like", "form:%s#%%" % form.client_uid)],
            order="sequence, id")

    # -- outcomes ------------------------------------------------------

    def _refused(self, form, result, *needles):
        """Assert the publish was refused, said why, and created nothing."""
        self.assertIn(
            "problems", result,
            "the publish should have been refused; it returned %r" % (result,))
        joined = " | ".join(result["problems"])
        for needle in needles:
            self.assertIn(
                needle, joined,
                "the refusal must name %r so the designer can find it; "
                "got %r" % (needle, joined))
        self.assertFalse(
            self._questions_of(form),
            "a refused publish must be all-or-nothing - no question may "
            "survive it")
        self.assertFalse(
            form.published,
            "a refused publish must leave the form unpublished")

    def _published_one(self, form, result):
        """Assert exactly one question was minted, and hand it back."""
        self.assertNotIn(
            "problems", result,
            "the fixture form must publish; problems were %r"
            % (result.get("problems"),))
        questions = self._questions_of(form)
        self.assertEqual(
            len(questions), 1,
            "one item must mint exactly one question, got %d" % len(questions))
        return questions

    # -- item builders -------------------------------------------------

    @staticmethod
    def _opts(*pairs):
        """`(label, correct)` pairs in the shape `_options_of` reads."""
        return [{"label": label, "correct": correct} for label, correct in pairs]

    @staticmethod
    def _item(kind, title=None, **extra):
        item = {
            "kind": kind,
            "id": "item-%s" % uuid4().hex[:6],
            "title": title or "Question %s" % uuid4().hex[:6],
        }
        item.update(extra)
        return item

    def _grid(self, kind, columns, grid_key, rows=("Row one", "Row two"),
              title=None):
        return self._item(kind, title=title, rows=list(rows),
                          columns=list(columns), grid_key=dict(grid_key))


# ----------------------------------------------------------------------
# Group 1 - a single-select key that names two correct answers is unearnable
# ----------------------------------------------------------------------
@tagged("-at_install", "post_install")
class TestSingleSelectKeysMustBeReachable(_FormBase):
    """The defect that silently cost every candidate a mark.

    A radio group submits ONE option. `_dimension_marks` compares the chosen
    set to the key set for equality, so a two-option key on a single-select
    item cannot be matched by any answer a candidate is able to give. The
    dimension is keyed, so `_keyed_dimension_count` counts it and the paper's
    denominator includes it. The result is a mark nobody in the cohort can
    ever earn, on a question that looks entirely normal in the bank, on the
    paper, and at every launch gate.

    The fix refuses it where it is still cheap to fix: at publish, with the
    designer looking at the item. These cases pin BOTH directions - refused
    where only one answer can be chosen, allowed where the widget genuinely
    takes several - because a guard that refuses real multi-select questions
    would be a worse bug than the one it replaced.
    """

    TWO_CORRECT = "unearnable"

    def test_a_multiple_choice_with_two_correct_options_is_refused(self):
        item = self._item("multipleChoice", title="Which metal is heaviest",
                          options=self._opts(("Lead", True), ("Gold", True),
                                             ("Tin", False)))
        form, result = self._publish(item)

        self._refused(form, result, "Which metal is heaviest",
                      self.TWO_CORRECT, "2 options are marked correct")

    def test_a_dropdown_with_two_correct_options_is_refused(self):
        item = self._item("dropdown", title="Pick the alloy",
                          options=self._opts(("Brass", True), ("Bronze", True),
                                             ("Copper", False)))
        form, result = self._publish(item)

        self._refused(form, result, "Pick the alloy", self.TWO_CORRECT)

    def test_a_single_correct_multiple_choice_still_publishes(self):
        """Guard the guard. If the fixture itself were unpublishable the two
        refusals above would pass for the wrong reason, so the identical item
        with ONE correct option has to come out the other side worth 1 mark."""
        item = self._item("multipleChoice", title="Which metal is heaviest",
                          options=self._opts(("Lead", False), ("Gold", True),
                                             ("Tin", False)))
        form, result = self._publish(item)

        question = self._published_one(form, result)
        self.assertEqual(question.question_type, "mcq")
        self.assertEqual(
            question._component_counts(), (1, 1),
            "one keyed dimension is one mark, and its raw is that mark")

    def test_checkboxes_with_two_correct_options_are_allowed(self):
        """The one shape where a two-option key is REACHABLE. A checkbox group
        submits a set, so the candidate can tick exactly the pair the key
        names - and `_dimension_marks` then matches. Refusing this would break
        real multi-select authoring."""
        item = self._item("checkboxes", title="Which two are noble gases",
                          options=self._opts(("Neon", True), ("Argon", True),
                                             ("Nitrogen", False)))
        form, result = self._publish(item)

        question = self._published_one(form, result)
        self.assertEqual(
            question.question_type, "msq",
            "checkboxes must publish as a multi-select question")
        self.assertEqual(
            question._component_counts(), (1, 1),
            "a multi-select question is ONE component however many options "
            "its key names - all-or-nothing lives inside the component")
        key = question.question_dimension_ids.option_line_ids.filtered(
            "is_correct")
        self.assertEqual(
            sorted(key.mapped("name")), ["Argon", "Neon"],
            "both correct options must survive the publish, or the key the "
            "candidate has to match is not the key the designer wrote")

    def test_an_image_question_that_is_not_multi_select_refuses_two_correct(self):
        """An `imageBlock` carrying options is a question about the picture,
        and `multi_select` is the flag that says which widget it gets. False
        means a radio group, so the same key is just as unearnable here."""
        item = self._item("imageBlock", title="What is wrong with this weld",
                          media_url=self.media_url, multi_select=False,
                          options=self._opts(("Porosity", True),
                                             ("Undercut", True),
                                             ("Clean", False)))
        form, result = self._publish(item)

        self._refused(form, result, "What is wrong with this weld",
                      self.TWO_CORRECT)

    def test_an_image_question_that_is_multi_select_allows_two_correct(self):
        item = self._item("imageBlock", title="What is wrong with this weld",
                          media_url=self.media_url, multi_select=True,
                          options=self._opts(("Porosity", True),
                                             ("Undercut", True),
                                             ("Clean", False)))
        form, result = self._publish(item)

        question = self._published_one(form, result)
        self.assertEqual(question.question_type, "msq")
        self.assertEqual(question._component_counts(), (1, 1))
        self.assertTrue(
            question.image_ids,
            "the picture the question is about must travel with it")

    def test_a_compare_pair_with_two_correct_verdicts_is_refused(self):
        """An A/B comparison commits to ONE verdict, so a two-verdict key is
        the same defect wearing different words. The refusal says "verdicts"
        rather than "options" because that is what the designer sees."""
        item = self._item("comparePair", title="Which render is better",
                          media_url=self.media_url,
                          media_url_b=self.media_url_b,
                          golden_answer="A has cleaner shadows.",
                          options=self._opts(("A is better", True),
                                             ("B is better", True),
                                             ("Equal", False)))
        form, result = self._publish(item)

        self._refused(form, result, "Which render is better",
                      self.TWO_CORRECT, "2 verdicts are marked correct")

    def test_a_one_option_choice_is_refused(self):
        """A single option is not a choice, it is a free mark. Every other
        authoring lane already refuses it (generation, the bank API, the bank
        importer); this one did not."""
        item = self._item("multipleChoice", title="The only answer",
                          options=self._opts(("Yes", True)))
        form, result = self._publish(item)

        self._refused(form, result, "The only answer",
                      "at least two options")

    def test_the_refusal_blocks_the_whole_form_not_just_the_bad_item(self):
        """Publishing is all-or-nothing by transaction. A form carrying one
        good item and one unearnable key must create NOTHING - a half
        published form would leave the designer with an assessment whose
        contents silently differ from the document they are looking at."""
        good = self._item("multipleChoice", title="A perfectly good question",
                          options=self._opts(("Right", True),
                                             ("Wrong", False)))
        bad = self._item("dropdown", title="The broken key",
                         options=self._opts(("One", True), ("Two", True)))
        form, result = self._publish(good, bad)

        self._refused(form, result, "The broken key", self.TWO_CORRECT)


# ----------------------------------------------------------------------
# Group 2 - a grid key that needed coercing used to key nothing
# ----------------------------------------------------------------------
@tagged("-at_install", "post_install")
class TestGridKeysSurviveCoercion(_FormBase):
    """A keyed grid must publish rows that are actually keyed.

    `grid_key` maps a row INDEX (as a string) to a column VALUE, and the
    designer's JSON is not obliged to hand that value over as an exact string
    match: a numbered column arrives as the integer `1`, a hand-typed value
    arrives as " Yes". The check normalised before comparing; the write did
    not. So the item passed validation and then marked nothing correct, and
    each affected row became a KEYLESS dimension - counted in neither the
    numerator nor the denominator, which is exactly right for a dimension the
    author never finished and exactly wrong for one they did.

    The visible symptom was a question that quietly shrank. The invisible one
    was worse: when every row was affected the question was worth 0, and the
    only thing that ever complained was `action_start`, telling the operator a
    grid they can see is keyed has no answer key.
    """

    def _assert_every_row_keyed(self, question, expected):
        """`expected` is row name -> the column that must be the key."""
        self.assertEqual(
            question._component_counts(), (len(expected), len(expected)),
            "a grid is worth one mark per ROW, and a row that lost its key "
            "drops out of the count entirely")
        by_row = {d.name: d for d in question.question_dimension_ids}
        self.assertEqual(
            sorted(by_row), sorted(expected),
            "every row must publish as its own dimension")
        for row, column in expected.items():
            keyed = by_row[row].option_line_ids.filtered("is_correct")
            self.assertEqual(
                len(keyed), 1,
                "row %r must have exactly one correct column, got %r"
                % (row, keyed.mapped("name")))
            self.assertEqual(
                keyed.name, column,
                "row %r must be keyed to column %r" % (row, column))

    def test_an_integer_grid_key_publishes_every_row_keyed(self):
        """The designer's key is `1`, the column is "1". Before the fix the
        check coerced and passed, the write compared `1 == "1"` and marked
        nothing, and the question came out worth 0 of its 2 marks."""
        item = self._grid("choiceGrid", columns=["1", "2"],
                          grid_key={"0": 1, "1": 2})
        form, result = self._publish(item)

        question = self._published_one(form, result)
        self.assertEqual(question.question_type, "mcq")
        self._assert_every_row_keyed(
            question, {"Row one": "1", "Row two": "2"})

    def test_a_whitespace_padded_grid_key_publishes_every_row_keyed(self):
        """The other half of the same disagreement: " Yes" against "Yes"."""
        item = self._grid("choiceGrid", columns=["Yes", "No"],
                          grid_key={"0": " Yes", "1": "No "})
        form, result = self._publish(item)

        question = self._published_one(form, result)
        self._assert_every_row_keyed(
            question, {"Row one": "Yes", "Row two": "No"})

    def test_one_coerced_row_does_not_shrink_the_question(self):
        """The quiet case. Three rows, one of them keyed with an integer: the
        old code published a question worth 2 marks that every screen and
        every report calls a 3 row grid. Nothing raised, nothing warned, and
        the row simply was not on the paper."""
        item = self._grid("choiceGrid", columns=["1", "2"],
                          rows=["Exact", "Coerced", "Also exact"],
                          grid_key={"0": "1", "1": 2, "2": "2"})
        form, result = self._publish(item)

        question = self._published_one(form, result)
        self._assert_every_row_keyed(
            question, {"Exact": "1", "Coerced": "2", "Also exact": "2"})

    def test_a_checkbox_grid_with_a_coerced_key_is_keyed_too(self):
        """`checkboxGrid` runs the same branch and publishes as `msq`, so it
        carried the identical defect and needs the identical guard."""
        item = self._grid("checkboxGrid", columns=["1", "2"],
                          grid_key={"0": 1, "1": " 2 "})
        form, result = self._publish(item)

        question = self._published_one(form, result)
        self.assertEqual(question.question_type, "msq")
        self._assert_every_row_keyed(
            question, {"Row one": "1", "Row two": "2"})

    # -- a checkbox grid row may key SEVERAL columns --------------------

    def _keyed_names(self, question, row):
        dim = question.question_dimension_ids.filtered(
            lambda d: d.name == row)
        self.assertEqual(len(dim), 1, "expected one dimension named %r" % row)
        return set(dim.option_line_ids.filtered("is_correct").mapped("name"))

    def test_a_checkbox_grid_row_can_key_several_columns(self):
        """THE ENHANCEMENT. A checkbox grid row is an MSQ.

        The respondent gets checkboxes and `_pick` accumulates several column
        ids for one row, so a row where two columns are both right had to be
        keyed to one of them - and a candidate ticking both scored 0, because
        the mark is an exact-set match (`response._dimension_marks`). The key
        is now a set per row.
        """
        item = self._grid(
            "checkboxGrid",
            columns=["People", "Cubicles", "Laptops"],
            rows=["Office", "Warehouse"],
            grid_key={"0": ["Cubicles", "Laptops"], "1": ["People"]})
        form, result = self._publish(item)

        question = self._published_one(form, result)
        self.assertEqual(question.question_type, "msq")
        self.assertEqual(
            self._keyed_names(question, "Office"), {"Cubicles", "Laptops"})
        self.assertEqual(
            self._keyed_names(question, "Warehouse"), {"People"})

    def test_a_multi_keyed_row_is_still_worth_exactly_one_mark(self):
        """Two keys on a row must not double what the row is worth.

        `_keyed_dimension_count` counts recordset truthiness, so one correct
        option and six both make the dimension one markable component. Asserted
        because the alternative - marks scaling with the size of the key - would
        silently re-weight every paper carrying one of these.
        """
        item = self._grid(
            "checkboxGrid",
            columns=["A", "B", "C"],
            rows=["Row one", "Row two"],
            grid_key={"0": ["A", "B", "C"], "1": ["B"]})
        form, result = self._publish(item)

        question = self._published_one(form, result)
        self.assertEqual(
            question._component_counts(), (2, 2),
            "two rows are two marks, whatever the size of each row's key")
        self.assertEqual(question._keyed_dimension_count(), 2)
        self.assertFalse(
            question._keyless_reason(),
            "a multi-keyed grid must pass the launch gate")

    def test_a_coerced_multi_key_is_normalised_per_entry(self):
        """The list form gets the same coercion the scalar form got.

        The whole reason `_grid_row_key` exists is that the check and the write
        once disagreed on coercion; a list must not reintroduce that by only
        stripping the first entry.
        """
        item = self._grid(
            "checkboxGrid", columns=["1", "2"], rows=["Row one", "Row two"],
            grid_key={"0": [1, " 2 "], "1": ["2"]})
        form, result = self._publish(item)

        question = self._published_one(form, result)
        self.assertEqual(self._keyed_names(question, "Row one"), {"1", "2"})

    def test_a_key_naming_a_missing_column_still_leaves_the_row_unkeyed(self):
        """Unknown labels drop out, and a row left with nothing is refused.

        The scalar form already behaved this way. The set form must not turn a
        wholly bogus key into a silently keyless row that publishes.
        """
        item = self._grid(
            "checkboxGrid", columns=["A", "B"], rows=["Good", "Bogus"],
            grid_key={"0": ["A"], "1": ["Nope", "Also nope"]})
        form, result = self._publish(item)

        self._refused(form, result, "rows without an answer key", "Bogus")

    def test_a_choice_grid_refuses_a_row_with_two_keys(self):
        """A radio grid cannot express a two-column key, so publish says so.

        `choiceGrid` shares the field and the branch. Radio buttons submit one
        option, so an exact-set match against a two-key row is unreachable -
        the same defect `_single_answer_or_problem` guards on every other
        single-select lane, which the grid branch never called.
        """
        item = self._grid(
            "choiceGrid", columns=["Pass", "Fail"], rows=["Sharp", "Colour"],
            grid_key={"0": ["Pass", "Fail"], "1": ["Fail"]})
        form, result = self._publish(item)

        self._refused(form, result, "ONE correct column", "Sharp")

    def test_a_choice_grid_still_accepts_a_one_element_list(self):
        """The client now always sends a list, including for the radio grid.

        So a one-element list is the ORDINARY case here, not an edge: refusing
        it would break every multiple-choice grid the designer saves.
        """
        item = self._grid(
            "choiceGrid", columns=["Pass", "Fail"],
            grid_key={"0": ["Pass"], "1": ["Fail"]})
        form, result = self._publish(item)

        question = self._published_one(form, result)
        self.assertEqual(question.question_type, "mcq")
        self._assert_every_row_keyed(
            question, {"Row one": "Pass", "Row two": "Fail"})

    def test_a_grid_key_naming_a_column_that_does_not_exist_is_still_refused(self):
        """Normalising must not turn the unkeyed check into a rubber stamp. A
        key pointing at a column the grid does not have is a genuine authoring
        fault and must still stop the publish, by row name."""
        item = self._grid("choiceGrid", columns=["Yes", "No"],
                          grid_key={"0": "Maybe", "1": "No"})
        form, result = self._publish(item)

        self._refused(form, result, "rows without an answer key", "Row one")


# ----------------------------------------------------------------------
# Group 3 - no Form Studio kind may mint a question worth nothing
# ----------------------------------------------------------------------
@tagged("-at_install", "post_install")
class TestEveryPublishedKindIsWorthAMark(_FormBase):
    """Whatever a designer builds, if it publishes it must be worth something.

    A question worth 0 marks is not neutral: it occupies the candidate's time
    and the paper's length while contributing to neither side of the score.
    Every one of the three defects above ended in exactly that state by a
    different route, so this case walks the whole kind table and pins the
    component count each kind is supposed to produce. A new kind added without
    a key, or an old one that stops keying its dimensions, fails here by name.

    The expected tuples are pinned rather than merely asserted non-zero. `>= 1`
    would pass a `choiceGrid` that published 1 of its 3 rows, which is the
    precise shape of defect 2.
    """

    def _kinds(self):
        """kind -> (item, expected question_type, expected component counts)."""
        return {
            "multipleChoice": (
                self._item("multipleChoice",
                           options=self._opts(("Alpha", True),
                                              ("Bravo", False))),
                "mcq", (1, 1)),
            "dropdown": (
                self._item("dropdown",
                           options=self._opts(("Alpha", True),
                                              ("Bravo", False))),
                "mcq", (1, 1)),
            "checkboxes": (
                self._item("checkboxes",
                           options=self._opts(("Alpha", True), ("Bravo", True),
                                              ("Charlie", False))),
                "msq", (1, 1)),
            "choiceGrid": (
                self._grid("choiceGrid", columns=["Yes", "No"],
                           grid_key={"0": "Yes", "1": "No"}),
                "mcq", (2, 2)),
            "checkboxGrid": (
                self._grid("checkboxGrid", columns=["Yes", "No"],
                           grid_key={"0": "Yes", "1": "No"}),
                "msq", (2, 2)),
            "linearScale": (
                self._item("linearScale", scale_min=1, scale_max=5,
                           scale_min_label="Never", scale_max_label="Always",
                           golden_answer="3"),
                "mcq", (1, 1)),
            "rating": (
                self._item("rating", rating_max=5, golden_answer="4"),
                "mcq", (1, 1)),
            "shortAnswer": (
                self._item("shortAnswer",
                           golden_answer="Because the seal had perished."),
                "subjective_rubric", (1, 1)),
            "paragraph": (
                self._item("paragraph",
                           golden_answer="Describe the shutdown sequence."),
                "subjective_rubric", (1, 1)),
            "imageBlock": (
                self._item("imageBlock", media_url=self.media_url,
                           options=self._opts(("Cracked", True),
                                              ("Sound", False))),
                "mcq", (1, 1)),
            "videoBlock": (
                self._item("videoBlock",
                           media_url="https://example.invalid/clip.mp4",
                           options=self._opts(("Too fast", True),
                                              ("Correct", False))),
                "mcq", (1, 1)),
            "imageAnnotation": (
                self._item("imageAnnotation", media_url=self.media_url,
                           annotation_count=3,
                           golden_labels={"1": "Inlet", "2": "Valve",
                                          "3": "Outlet"}),
                "image_label", (1, 1)),
            "comparePair": (
                self._item("comparePair", media_url=self.media_url,
                           media_url_b=self.media_url_b,
                           # Worth (2, 2) only WITH the justification asked
                           # for: publish discards a rationale the switch did
                           # not ask for, so the switch is half of the shape.
                           require_justification=True,
                           golden_answer="A holds detail in the shadows.",
                           options=self._opts(("A is better", True),
                                              ("B is better", False))),
                "image_ab", (2, 2)),
        }

    def test_every_publishing_kind_is_worth_at_least_one_mark(self):
        for kind, (item, qtype, counts) in self._kinds().items():
            with self.subTest(kind=kind):
                form, result = self._publish(item)
                question = self._published_one(form, result)
                self.assertEqual(
                    question.question_type, qtype,
                    "%s must publish as %s" % (kind, qtype))
                marks, raw = question._component_counts()
                self.assertGreaterEqual(
                    marks, 1,
                    "no Form Studio kind may mint a question worth 0 marks, "
                    "and %s did" % kind)
                self.assertEqual(
                    (marks, raw), counts,
                    "%s must be worth %r, got %r" % (kind, counts,
                                                     (marks, raw)))

    def test_an_objective_kind_keys_every_dimension_it_publishes(self):
        """The count above is derived from `_keyed_dimension_count`, so a kind
        could reach it while leaving an EXTRA dimension keyless beside the
        keyed one - present on the paper, impossible to score. No objective
        kind may publish a dimension with no correct option."""
        objective = ("multipleChoice", "dropdown", "checkboxes", "choiceGrid",
                     "checkboxGrid", "linearScale", "rating", "imageBlock",
                     "videoBlock", "comparePair")
        kinds = self._kinds()
        for kind in objective:
            with self.subTest(kind=kind):
                item, _qtype, _counts = kinds[kind]
                form, result = self._publish(item)
                question = self._published_one(form, result)
                self.assertTrue(question.question_dimension_ids)
                for dimension in question.question_dimension_ids:
                    self.assertTrue(
                        dimension.option_line_ids.filtered("is_correct"),
                        "%s published dimension %r with no correct option"
                        % (kind, dimension.name))

    def test_a_text_block_publishes_no_question_of_its_own(self):
        """`textBlock` is deliberately not a question. It must not mint one -
        and it must not be dropped either: it folds into the description of
        the question that follows it, which is the only reason a designer's
        instructions reach the candidate at all."""
        block = self._item("textBlock", title="Read this first",
                           help="The pump is running at half load.")
        question_item = self._item("multipleChoice", title="Is that safe",
                                   options=self._opts(("Yes", False),
                                                      ("No", True)))
        form, result = self._publish(block, question_item)

        question = self._published_one(form, result)
        self.assertEqual(
            question.name, "Is that safe",
            "the text block must not become a question of its own")
        self.assertIn(
            "The pump is running at half load.", question.description or "",
            "an informational block must ride on the next question rather "
            "than being dropped")
        self.assertEqual(question._component_counts(), (1, 1))

    def test_a_file_upload_is_refused_rather_than_published(self):
        """`fileUpload` has no counterpart in the exam runner, so it cannot be
        delivered. It does not publish a worthless question and it is not
        silently dropped either - it stops the publish and names itself, so
        the designer replaces it instead of discovering at launch that the
        item they authored is not on the paper."""
        upload = self._item("fileUpload", title="Attach your calculations")
        question_item = self._item("multipleChoice", title="Is that safe",
                                   options=self._opts(("Yes", False),
                                                      ("No", True)))
        form, result = self._publish(upload, question_item)

        self._refused(form, result, "Attach your calculations",
                      "file-upload questions cannot be delivered")

    def test_an_unsupported_kind_is_skipped_and_publishes_nothing(self):
        """An unknown kind is a warning, not a question. It must never fall
        through into a keyless record."""
        unknown = self._item("someFutureKind", title="Not a thing yet")
        question_item = self._item("multipleChoice", title="Is that safe",
                                   options=self._opts(("Yes", False),
                                                      ("No", True)))
        form, result = self._publish(unknown, question_item)

        question = self._published_one(form, result)
        self.assertEqual(question.name, "Is that safe")
        self.assertTrue(
            any("someFutureKind" in w for w in result["warnings"]),
            "the skipped kind must be reported, got %r" % (result["warnings"],))


# ----------------------------------------------------------------------
# Group 4 - the API launch gate must agree with the one that actually runs
# ----------------------------------------------------------------------
class _StubRequest:
    """The slice of `odoo.http.request` the launch route touches.

    `_launch_gates` reads `request.env` twice (the servable pool, and the
    retirement note's complement of it) and the decorators around the route
    read `request.env.user` and `request.params`. Nothing else in the dry-run
    path needs a real HTTP request, so a stub keeps this a TransactionCase -
    matching `test_api_invariants` and the rest of the house, where an
    HttpCase would buy a session and a port for no extra assertion.
    """

    def __init__(self, env, params=None):
        self.env = env
        self.params = dict(params or {})

    def make_json_response(self, payload, headers=None, status=200):
        # Only reached on a failure envelope, which the dry run does not
        # produce. Returning the payload keeps a surprise readable instead of
        # raising AttributeError from inside an exception handler.
        return {"ok": False, "status": status, "payload": payload}


@tagged("-at_install", "post_install")
class TestLaunchGatesAgreeOnAKeylessQuestion(TransactionCase):
    """Two copies of `_is_keyless`, one verdict.

    An objective question with NO dimensions at all scores 0 for every
    candidate: there is nothing on it to answer. `action_start`'s gate was
    fixed to say so; the mirror behind the launch dry run kept the old
    `if not dimensions: return False` exemption. The operator therefore saw
    `answer_keys` PASSING, pressed confirm, and got a UserError the route does
    not render as a gate failure - a gate that disagrees with the one that
    actually runs is worse than no gate, because it spends the operator's
    confidence before it wastes their time.

    Both halves are asserted here on the SAME assessment, in the same test
    where possible, because the property is agreement and neither half proves
    it alone.
    """

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Question = self.env["assessments.be.question"]
        self.QDim = self.env["assessments.be.question.dimension"]
        self.Generator = self.env["assessments.be.prompt"]
        # The route is gated on Manager. Granted from the GROUP side so this
        # does not depend on the name of the users-side m2m.
        self.env.ref("assessments_be_v2.group_assessment_manager").sudo().write(
            {"user_ids": [(4, self.env.user.id)]})

    # -- fixtures ------------------------------------------------------

    def _applicant(self):
        slug = uuid4().hex[:8]
        return self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % slug,
            "email_from": "cand_%s@example.com" % slug,
        })

    def _draft(self, keyed):
        """A draft that clears every gate EXCEPT, when `keyed` is False, the
        answer key one - so a failure there is unambiguous."""
        generator = self.Generator.create({"name": "Gen %s" % uuid4().hex[:6]})
        question = self.Question.create({
            "name": "Dimensionless %s" % uuid4().hex[:6],
            "question_type": "mcq",
            "prompt": "There is nothing here to answer.",
            "generator_id": generator.id,
        })
        if keyed:
            self.QDim.create({
                "question_id": question.id,
                "name": "Answer",
                "option_line_ids": [
                    (0, 0, {"name": name, "sequence": i * 10,
                            "is_correct": i == 0})
                    for i, name in enumerate(("Alpha", "Bravo"))],
            })
        assessment = self.Assessment.create({
            "name": "Launch %s" % uuid4().hex[:6],
            "generator_id": generator.id,
            "question_limit": 1,
            "duration_minutes": 30,
            "evaluator_ids": [(6, 0, [self._applicant().id])],
        })
        assessment._sync_roster_rows()
        assessment.invalidate_recordset()
        return assessment, question

    def _dry_run(self, assessment):
        """The route itself, dry, with `request` stubbed for both modules that
        read it: `admin` for the record lookup, `common` for the decorators
        and `bool_arg("confirm")`."""
        stub = _StubRequest(self.env, {"assessment_id": assessment.id})
        controller = admin_api.EtpAssessmentApiAdmin()
        with patch.object(admin_api, "request", stub), \
                patch.object(api_common, "request", stub):
            response = controller.assessment_launch(assessment.id)
        self.assertTrue(
            response.get("ok"),
            "the dry run must answer with a success envelope; got %r"
            % (response,))
        data = response["data"]
        self.assertFalse(
            data["launched"],
            "a dry run must never launch - `confirm` was not passed")
        return {gate["code"]: gate for gate in data["gates"]}, data

    # -- cases ---------------------------------------------------------

    def test_the_dry_run_fails_the_answer_key_gate_on_a_dimensionless_question(self):
        assessment, question = self._draft(keyed=False)

        gates, data = self._dry_run(assessment)

        self.assertTrue(
            gates["questions_available"]["passed"],
            "the pool gate must PASS, or the answer key gate below would be "
            "reporting 'cannot check' rather than a real verdict")
        self.assertFalse(
            gates["answer_keys"]["passed"],
            "an objective question with no dimensions has nothing to answer "
            "and scores 0 for every candidate; the dry run reported it as "
            "having an answer key")
        self.assertIn(
            question.name, gates["answer_keys"]["reason"],
            "the failing gate must name the question so the operator can fix "
            "it, got %r" % (gates["answer_keys"]["reason"],))
        self.assertFalse(
            data["can_launch"],
            "a failing gate must sink `can_launch`")

    def test_the_model_refuses_the_launch_the_dry_run_now_predicts(self):
        """The other half of the agreement. Before the fix this raised while
        the dry run said the paper was fine."""
        assessment, question = self._draft(keyed=False)

        with self.assertRaises(UserError) as caught:
            assessment.action_start()

        # ASSERTS THE PROPERTY, NOT THE PHRASING. This matched the literal
        # "no correct answer marked", which was the whole message when the gate
        # had one sentence for every fault. The rule now lives on the question
        # (`_keyless_reason`) and NAMES the specific fault per question, so this
        # fixture - an objective question with no dimensions at all - reads
        # "there is nothing on it to answer". What the test is actually for is
        # that `action_start` refuses for the ANSWER KEY reason rather than some
        # other gate, and that it names the question; both are checked directly.
        message = str(caught.exception)
        self.assertIn(
            "score 0 for every candidate", message,
            "action_start must refuse for the answer key reason, not some "
            "other gate; got %r" % (message,))
        self.assertIn(
            question._keyless_reason(), message,
            "the refusal must state the fault the operator has to fix; got %r"
            % (message,))
        self.assertIn(question.name, message)

    def test_a_keyed_question_passes_both_gates(self):
        """Guard the guard. If the fixture failed some unrelated gate, the two
        cases above would prove nothing about answer keys."""
        assessment, _question = self._draft(keyed=True)

        gates, data = self._dry_run(assessment)

        self.assertTrue(
            gates["answer_keys"]["passed"],
            "a properly keyed question must not trip the gate; reason was %r"
            % (gates["answer_keys"]["reason"],))
        self.assertTrue(
            data["can_launch"],
            "the fixture must otherwise be launchable, or the failures above "
            "cannot be attributed to the answer key; failing gates were %r"
            % ([g["code"] for g in data["gates"] if not g["passed"]],))

        assessment.action_start()
        assessment.invalidate_recordset()
        self.assertEqual(
            assessment.state, "in_progress",
            "the model must accept the launch its own dry run approved")
