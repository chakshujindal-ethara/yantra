"""A paper the examiner grouped into sections must read as grouped.

THE DEFECT (SNo 51), and the half of it that was already fixed. Form Studio
authors a form as sections of items, and the publish path already respects that
for ORDER: `publish_to_assessment` sets `preserve_question_order` from the
author's own shuffle switch, and `test_form_shuffle_reaches_candidates` pins it.
So the questions arrive in the authored sequence.

What was missing is that **nothing ever told the candidate a section existed**.
`controllers/api/candidate.py` contained no mention of the word, and no field on
`assessments.be.question` carried one, so a form deliberately grouped into
"Before you start" / "On the floor" / "Escalation" reached the candidate as one
flat run of questions. The grouping was authored, stored, and honoured - and
invisible to the only person it was for. That is the reported "questions are not
appearing section-wise".

WHAT THESE TESTS ASSERT. The whole path, because a value that exists on the
question and never reaches the wire fixes nothing:

    form section title -> question.section_title -> the candidate's payload

THE EMPTY CASE IS PART OF THE CONTRACT. A question that did not come from a form
has no section, and the runner must render no heading rather than invent one -
so the field has to be reliably empty, not "Untitled section".
"""
from uuid import uuid4

from odoo.tests.common import tagged

from odoo.addons.assessments_be_v2.tests.test_authored_question_marks import (
    _FormBase,
)


@tagged("post_install", "-at_install")
class TestTheCandidateCanSeeWhichSectionTheyAreIn(_FormBase):

    def _choice(self, title):
        return self._item(
            "multipleChoice", title=title,
            options=self._opts(("Yes", True), ("No", False)))

    def _multi_section_form(self):
        """Three named sections, so ORDER and GROUPING are distinguishable.

        Two questions per section on purpose: with one each, a bug that simply
        echoed the question's own index would still line up.
        """
        return self.Form.create({
            "client_uid": "form-%s" % uuid4().hex[:6],
            "title": "Sectioned form %s" % uuid4().hex[:6],
            "structure_json": [
                {"title": "Before you start",
                 "items": [self._choice("Checks A1"), self._choice("Checks A2")]},
                {"title": "On the floor",
                 "items": [self._choice("Floor B1"), self._choice("Floor B2")]},
                {"title": "Escalation",
                 "items": [self._choice("Esc C1"), self._choice("Esc C2")]},
            ],
        })

    # ── the stamp ─────────────────────────────────────────────────────

    def test_each_question_carries_the_section_it_was_authored_under(self):
        form = self._multi_section_form()
        result = form.publish_to_assessment()
        self.assertIsNone(
            result.get("problems"),
            "the fixture must publish; problems were %r"
            % (result.get("problems"),))

        got = [(q.name, q.section_title)
               for q in self._questions_of(form)]
        self.assertEqual(
            got,
            [("Checks A1", "Before you start"),
             ("Checks A2", "Before you start"),
             ("Floor B1", "On the floor"),
             ("Floor B2", "On the floor"),
             ("Esc C1", "Escalation"),
             ("Esc C2", "Escalation")],
            "the section an examiner authored each question under did not "
            "survive publishing, so the candidate cannot be told which part of "
            "the paper they are in")

    def test_a_question_from_no_form_has_no_section(self):
        """An invented heading is worse than none.

        Every question in the bank that was generated rather than drawn has no
        section, and the runner keys off emptiness to decide whether to draw a
        heading at all.
        """
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Sectionless generator %s" % uuid4().hex[:6]})
        q = self.Question.create({
            "name": "Plain bank question",
            "question_type": "mcq",
            "prompt": "Pick one",
            "difficulty": "easy",
            "generator_id": generator.id,
        })
        self.assertFalse(
            q.section_title,
            "a question that came from no form must carry no section")

    def test_an_informational_block_reads_as_two_parts_not_one_sentence(self):
        """A textBlock's heading and its body must not run together.

        THE DEFECT, read off a real sitting. `_walk_section` folded an
        informational block into the next question's description by joining its
        `title` and `help` with a single SPACE, so the candidate read:

            "Read before answering This block carries no answer."

        - a heading and a sentence collapsed into one ungrammatical line, above
        the question it was meant to introduce. The carry list already separates
        one block from the NEXT with a blank line; the two halves of a single
        block now get the same treatment, so a block with both parts and two
        blocks with one part each render identically.
        """
        form = self.Form.create({
            "client_uid": "form-%s" % uuid4().hex[:6],
            "title": "Carry form %s" % uuid4().hex[:6],
            "structure_json": [{
                "title": "Only section",
                "items": [
                    {"id": "b1", "kind": "textBlock",
                     "title": "Read before answering",
                     "help": "This block carries no answer."},
                    self._choice("The question it rides on"),
                ],
            }],
        })
        result = form.publish_to_assessment()
        self.assertIsNone(result.get("problems"),
                          "problems: %r" % (result.get("problems"),))
        q = self._questions_of(form)[0]
        self.assertIn(
            "Read before answering\n\nThis block carries no answer.",
            q.description or "",
            "the block's heading and body were joined without a break, so the "
            "candidate reads them as one broken sentence. Got: %r"
            % (q.description,))

    # ── the wire ──────────────────────────────────────────────────────

    def test_the_section_reaches_the_candidate_payload(self):
        """THE ONE THAT MATTERS. A stored value nobody serves fixes nothing.

        Asserted against the same serializer the exam routes use, rather than
        against the record, because the reported defect is what the CANDIDATE
        sees.
        """
        from odoo.addons.assessments_be_v2.controllers.api import serializers

        form = self._multi_section_form()
        form.publish_to_assessment()
        questions = self._questions_of(form)

        payload = serializers.question_for_candidate(
            questions[2], token="tok", index=2, total=len(questions))
        self.assertEqual(
            payload.get("section_title"), "On the floor",
            "the exam payload does not carry the section, so the runner has "
            "nothing to render however well the publish path stored it")

    def test_the_payload_key_is_present_even_when_empty(self):
        """ALWAYS PRESENT, so the client never has to tell absent from empty.

        A key that appears only sometimes makes every consumer write the same
        defensive lookup, and one of them eventually gets it wrong.
        """
        from odoo.addons.assessments_be_v2.controllers.api import serializers

        generator = self.env["assessments.be.prompt"].create(
            {"name": "Sectionless generator %s" % uuid4().hex[:6]})
        q = self.Question.create({
            "name": "Plain bank question",
            "question_type": "mcq",
            "prompt": "Pick one",
            "difficulty": "easy",
            "generator_id": generator.id,
        })
        payload = serializers.question_for_candidate(
            q, token="tok", index=0, total=1)
        self.assertIn("section_title", payload)
        self.assertEqual(payload["section_title"], "")
