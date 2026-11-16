# -*- coding: utf-8 -*-
"""A PUBLISHED QUESTION IS A MARKABLE QUESTION - for every kind, not most.

THE RULE. Form Studio refuses to publish any question that cannot be scored.
Objective kinds already refused without their answer key ("no option is marked
correct"). The SUBJECTIVE kinds only WARNED, so a form could publish a written
question with no golden answer, a prompt task with no model prompt, or a 5-point
annotation with 1 point keyed.

THE COMPARISON IS THE ONE KIND THAT ASKS FIRST, and deliberately so.
`comparePair` keys its verdict on an option and marks it in code, so it is
scorable with no prose at all. Requiring a rationale unconditionally made the
kind unpublishable from Form Studio, which had no field that writes one.

So the examiner chooses with the designer's "Require justification" switch, and
publish makes that choice TRUE rather than trusting it: on demands a rationale,
off discards one. That is what lets the four downstream readers of
`official_reasoning` agree - the marks (`question._component_counts`), the judge
(`_image_ab_uses_llm`), the candidate's textarea
(`serializers.wants_justification`) and the submit gate. Both directions are
asserted below, including the state that must never publish: prose demanded with
no standard to mark it against.

WHY A WARNING WAS THE WRONG SHAPE for the kinds that keep the rule. The golden
answer IS the answer key for a question whose only answer is judged text. Without
one the judge marks against the prompt alone and invents the standard per
candidate - two candidates writing the same answer can be scored differently,
and nothing on the paper says why.

The annotation case was the sharpest. `_item_spec` refused only when EVERY marker
was unkeyed and warned otherwise, so a 5-point question with ONE golden answer
published happily - the other four points are marks no candidate can earn. The
examiner reads "5 points" and every candidate scores out of far less.

WHAT STILL PUBLISHES, asserted below so the rule cannot over-reach: the same
questions with their keys filled in.
"""
import json
import uuid

from odoo.tests.common import TransactionCase

IMG = "https://example.test/plate.png"


class TestPublishDemandsAKey(TransactionCase):

    def _publish(self, item):
        form = self.env["etp.studio.form"].create({
            "client_uid": uuid.uuid4().hex,
            "title": "Key rules %s" % uuid.uuid4().hex[:6],
            "structure_json": [{"id": "sec-1", "title": "Section one",
                                "items": [item]}],
        })
        return form, form.publish_to_assessment()

    def _item(self, kind, **extra):
        item = {"id": "item-1", "kind": kind,
                "title": "Question %s" % uuid.uuid4().hex[:6]}
        item.update(extra)
        return item

    def _refusal(self, result):
        return " | ".join(result.get("problems") or [])

    def _assert_refused(self, result, needle):
        joined = self._refusal(result)
        self.assertTrue(
            result.get("problems"),
            "the form published with an unmarkable question")
        self.assertIn(
            needle, joined,
            "the refusal must name what to fix so the examiner can find it; "
            "got %r" % (joined,))

    def _only_question(self, form):
        """The single question a one-item form published.

        Looked up by `source_ref`, the link `publish_to_assessment` writes, so
        this cannot accidentally pick up a question from another test's form.
        """
        questions = self.env["assessments.be.question"].search(
            [("source_ref", "like", "form:%s#" % form.client_uid)])
        self.assertEqual(
            len(questions), 1,
            "expected exactly one published question, got %d" % len(questions))
        return questions

    def _assert_published(self, result):
        self.assertFalse(
            result.get("problems"),
            "a properly keyed question must still publish; problems were %r"
            % (result.get("problems"),))

    # -- written answers ------------------------------------------------

    def test_a_written_question_needs_its_golden_answer(self):
        for kind in ("shortAnswer", "paragraph"):
            _form, result = self._publish(self._item(kind))
            self._assert_refused(result, "golden answer")

    def test_a_written_question_WITH_a_golden_answer_publishes(self):
        for kind in ("shortAnswer", "paragraph"):
            _form, result = self._publish(
                self._item(kind, golden_answer="The refund window is 30 days."))
            self._assert_published(result)

    # -- the comparison's justification ---------------------------------
    #
    # THE SWITCH DECIDES, and publish makes the switch true rather than
    # trusting it. "Require justification" on means a rationale MUST be
    # authored; off means any rationale is DISCARDED. That equivalence is what
    # lets `_component_counts`, `_image_ab_uses_llm` and the candidate's
    # textarea all keep reading `official_reasoning` and get the switch's
    # answer, so the four of them can never disagree.

    def _comparison(self, **extra):
        return self._item(
            "comparePair",
            media_url=IMG,
            media_url_b="https://example.test/plate-b.png",
            options=[{"id": "a", "label": "Left", "correct": True},
                     {"id": "b", "label": "Right"}],
            **extra)

    def test_a_comparison_publishes_on_its_verdict_alone(self):
        """A RATIONALE IS OPTIONAL FOR A COMPARISON, unlike every written kind
        above. The verdict is keyed on an option and marked in code, so the
        question is already scorable; the rationale buys a GRADED
        justification.

        This used to be an unconditional refusal, which made the kind
        unpublishable from Form Studio - the examiner was told to write
        something they had nowhere to write. It is only demanded now when the
        designer's switch asks for the box, which is the same screen that
        offers the field to satisfy it.
        """
        _form, result = self._publish(self._comparison())
        self._assert_published(result)

    def test_a_comparison_without_a_standard_is_worth_its_verdicts_only(self):
        """THE MARK MUST GO WITH THE GRADING. `image_ab` is in
        SUBJECTIVE_COMPONENT_TYPES, so it normally earns a justification mark
        on top of its verdict axes. With no `official_reasoning` there is
        nothing to grade against, so that mark must not exist either -
        otherwise the question is worth 2 with one half unearnable and every
        candidate silently loses it.
        """
        form, result = self._publish(self._comparison())
        self._assert_published(result)
        question = self._only_question(form)
        self.assertFalse(
            question.official_reasoning,
            "no rationale was authored, so none should be stored")
        marks, raw = question._component_counts()
        self.assertEqual(
            (marks, raw), (1, 1),
            "one keyed verdict axis and NO justification mark; got %s"
            % ((marks, raw),))

    def test_a_comparison_WITH_a_standard_still_earns_the_written_mark(self):
        """The other side of the same rule: ASKING for a justification and
        authoring its rationale must still buy the graded mark, exactly as
        before. The switch is what carries a rationale through publish now, so
        the graded shape is "on, with a standard" - see
        test_switching_the_justification_off_DISCARDS_a_stale_rationale for why
        a rationale alone can no longer be it."""
        form, result = self._publish(self._comparison(
            require_justification=True,
            golden_answer="Left is sharper and its lighting is consistent."))
        self._assert_published(result)
        question = self._only_question(form)
        self.assertTrue(question.official_reasoning)
        marks, raw = question._component_counts()
        self.assertEqual(
            (marks, raw), (2, 2),
            "one verdict axis PLUS the graded justification; got %s"
            % ((marks, raw),))

    # -- the switch ------------------------------------------------------

    def test_requiring_a_justification_demands_something_to_mark_it_against(
            self):
        """ASKING FOR PROSE WITH NO STANDARD IS THE ONE STATE THAT MUST NOT
        PUBLISH.

        The judge marks a candidate's justification AGAINST
        `official_reasoning`. With the switch on and no rationale, the box is
        shown, the candidate is required to fill it, a mark is charged for it -
        and there is nothing to mark it against, so the standard would be
        invented per candidate. That is exactly what an answer key exists to
        prevent, and it fails silently at scoring time rather than here.
        """
        _form, result = self._publish(
            self._comparison(require_justification=True))
        self._assert_refused(result, "answer rationale")

    def test_the_refusal_says_how_to_get_out_of_it_either_way(self):
        """A refusal must name BOTH exits, because either is legitimate: write
        the rationale, or turn the switch off and score the comparison on its
        verdict. Naming only the first reads as "this kind needs prose", which
        is what made the old unconditional gate a dead end.
        """
        _form, result = self._publish(
            self._comparison(require_justification=True))
        joined = self._refusal(result)
        self.assertIn("Require justification", joined)
        self.assertIn("verdict alone", joined)

    def test_requiring_a_justification_publishes_with_its_rationale(self):
        """Switch on WITH a rationale is the graded shape, and it must earn the
        justification mark - the candidate is required to write the box, so it
        has to be worth something."""
        form, result = self._publish(self._comparison(
            require_justification=True,
            golden_answer="Left is sharper and its lighting is consistent."))
        self._assert_published(result)
        question = self._only_question(form)
        self.assertTrue(question.official_reasoning)
        self.assertEqual(question._component_counts(), (2, 2))

    def test_switching_the_justification_off_DISCARDS_a_stale_rationale(self):
        """TURNING THE SWITCH OFF HAS TO ACTUALLY STOP THE GRADING.

        An examiner who asks for a justification, writes the rationale, then
        changes their mind leaves the text behind in the form document - the
        designer hides the field rather than wiping it, so the next publish
        still carries it. Storing it anyway would leave the question in the one
        state that cannot exist: no box on the candidate's screen, but a
        standard on the record - so `_component_counts` charges a mark for a
        box nobody was shown and every candidate loses it.

        Off means off, so the rationale is dropped at publish.
        """
        form, result = self._publish(self._comparison(
            require_justification=False,
            golden_answer="Left is sharper and its lighting is consistent."))
        self._assert_published(result)
        question = self._only_question(form)
        self.assertFalse(
            question.official_reasoning,
            "the switch is off, so the stale rationale must not be stored")
        self.assertEqual(
            question._component_counts(), (1, 1),
            "no box was asked for, so no mark may be charged for one")

    def test_the_switch_and_the_candidates_textarea_are_one_fact(self):
        """THE FOUR READERS MUST AGREE, and this is the assertion that pins it.

        The switch is stored nowhere: publish makes "a rationale exists" mean
        "the switch was on", and the marks, the judge, the candidate's textarea
        and the submit gate all derive the switch from that one field. If they
        ever disagree the candidate is shown a box worth nothing, or refused
        over a box they were never shown.
        """
        from odoo.addons.assessments_be_v2.controllers.api import serializers

        on_form, on_result = self._publish(self._comparison(
            require_justification=True,
            golden_answer="Left is sharper and its lighting is consistent."))
        self._assert_published(on_result)
        off_form, off_result = self._publish(
            self._comparison(require_justification=False))
        self._assert_published(off_result)

        on_question = self._only_question(on_form)
        off_question = self._only_question(off_form)

        self.assertTrue(serializers.wants_justification(on_question))
        self.assertFalse(serializers.wants_justification(off_question))
        # And the payload the candidate is actually served says the same.
        self.assertTrue(
            serializers.question_for_candidate(
                on_question, "tok", 1, 1)["requires_justification"])
        self.assertFalse(
            serializers.question_for_candidate(
                off_question, "tok", 1, 1)["requires_justification"])

    # -- annotation: EVERY point, not one of them -----------------------

    def _annotation(self, points, golden):
        return self._item(
            "imageAnnotation",
            media_url=IMG,
            regions=[{"n": n, "x": .1 * n, "y": .1 * n, "w": .05, "h": .05}
                     for n in range(1, points + 1)],
            golden_labels=golden,
        )

    def test_a_partly_keyed_annotation_is_refused(self):
        """The live shape this was written for: 5 points, 1 keyed. The other
        four are marks nobody can earn."""
        _form, result = self._publish(
            self._annotation(5, {"1": "Extra finger on the left hand"}))
        self._assert_refused(result, "every point needs a golden answer")
        # And it must SAY WHICH, or the examiner has to guess.
        joined = self._refusal(result)
        for n in ("2", "3", "4", "5"):
            self.assertIn(n, joined)

    def test_an_annotation_with_every_point_keyed_publishes(self):
        _form, result = self._publish(self._annotation(
            3, {"1": "Extra finger", "2": "Warped text", "3": "Shadow"}))
        self._assert_published(result)

    def test_a_wholly_unkeyed_annotation_is_still_refused(self):
        """The case that already worked, kept so the change is a tightening
        rather than a swap."""
        _form, result = self._publish(self._annotation(2, {}))
        self.assertTrue(result.get("problems"))

    # -- guard: the rule must not fire on kinds that carry no golden ----

    def test_an_objective_question_is_unaffected(self):
        """An mcq's key is its marked option; it has no golden answer and must
        not start demanding one."""
        _form, result = self._publish(self._item(
            "multipleChoice",
            options=[{"id": "a", "label": "Yes", "correct": True},
                     {"id": "b", "label": "No"}],
        ))
        self._assert_published(result)

    def test_a_content_block_is_unaffected(self):
        """A text block collects no answer, so it has nothing to key."""
        form = self.env["etp.studio.form"].create({
            "client_uid": uuid.uuid4().hex,
            "title": "Blocks %s" % uuid.uuid4().hex[:6],
            "structure_json": [{"id": "sec-1", "title": "Section one", "items": [
                {"id": "b1", "kind": "textBlock", "title": "Instructions",
                 "help": "Read this first."},
                {"id": "q1", "kind": "multipleChoice", "title": "Ready?",
                 "options": [{"id": "a", "label": "Yes", "correct": True},
                             {"id": "b", "label": "No"}]},
            ]}],
        })
        self._assert_published(form.publish_to_assessment())

    def test_the_scale_key_is_still_read_from_golden_answer(self):
        """A linear scale keys through `golden_answer` as a digit string - the
        cross-repo contract the client publishes both ways. The new refusals
        must not have disturbed it."""
        _form, result = self._publish(self._item(
            "linearScale", scale_min=1, scale_max=5, golden_answer="4"))
        self._assert_published(result)

    def test_a_scale_with_an_out_of_range_key_is_refused(self):
        _form, result = self._publish(self._item(
            "linearScale", scale_min=1, scale_max=5, golden_answer="9"))
        self.assertTrue(result.get("problems"))
