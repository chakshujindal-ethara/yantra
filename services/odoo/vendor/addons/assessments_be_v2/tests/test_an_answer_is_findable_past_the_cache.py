# -*- coding: utf-8 -*-
"""D2 - `/api/v1/responses` can be searched, so an answer past row 400 exists.

THE DEFECT THIS CLOSES. The Responses screen walked `/api/v1/responses` at
`maxPages: 2` - 400 of 31,462 rows measured on stage - and filtered them in
memory, because the route accepted no search term at all. An operator looking
for a candidate whose answers sat past row 400 got "no matches" over a table
that held them, and nothing on screen distinguished that from the candidate
having answered nothing.

WHAT IS AND IS NOT SERVER-SIDE, asserted here so the boundary is a decision
rather than an accident. The three axes Odoo's own response search view offers -
assessment, candidate, question - move to the server. The RENDERED, REDACTED
answer text does not: it is built client-side by applying this platform's
redaction rules, and a second copy of those rules on the server is the
duplication that produced the original defect. The client unions the server's
rows into its cache rather than replacing it, so answer-text search keeps
working over the rows in hand.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class _Answers(TransactionCase):
    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Response = self.env["assessments.be.response"]
        self.Question = self.env["assessments.be.question"]
        self.Generator = self.env["assessments.be.prompt"]
        self.Applicant = self.env["hr.applicant"]

    def _assessment(self, name):
        gen = self.Generator.create({"name": "Gen %s" % uuid4().hex[:6]})
        return self.Assessment.create({
            "name": name, "generator_id": gen.id})

    def _applicant(self, name):
        return self.Applicant.create({
            "partner_name": name,
            "email_from": "%s@example.com" % uuid4().hex[:8],
        })

    def _question(self, name):
        gen = self.Generator.create({"name": "Gen %s" % uuid4().hex[:6]})
        return self.Question.create({
            "name": name, "question_type": "subjective_rubric",
            "prompt": "Say something", "difficulty": "easy",
            "generator_id": gen.id,
        })

    def _answer(self, assessment, applicant, question, text):
        ev = self.Evaluator.create({
            "assessment_id": assessment.id, "applicant_id": applicant.id})
        return self.Response.create({
            "assessment_id": assessment.id,
            "assessment_evaluator_id": ev.id,
            "evaluator_id": applicant.id,
            "question_id": question.id,
            "justification": text,
        })

    def _domain(self, term):
        return self.Response._be_search_domain(term)

    def _find(self, term, extra=None):
        return self.Response.search((extra or []) + self._domain(term))


class TestTheThreeAxesReachTheWholeTable(_Answers):

    def test_a_candidate_name_finds_their_answers(self):
        a = self._assessment("Q7r %s" % uuid4().hex[:6])
        q = self._question("Describe the defect")
        wanted = self._answer(a, self._applicant("Aahan Trikha"), q, "mine")
        other = self._answer(a, self._applicant("Someone Else"), q, "theirs")

        found = self._find("aahan", [("assessment_id", "=", a.id)])
        self.assertIn(wanted, found)
        self.assertNotIn(other, found)

    def test_it_is_a_substring_and_not_a_prefix(self):
        """The `aahan` case: it must select Jaahanvi too."""
        a = self._assessment("IG %s" % uuid4().hex[:6])
        q = self._question("Describe the defect")
        trikha = self._answer(a, self._applicant("Aahan Trikha"), q, "x")
        jaahanvi = self._answer(a, self._applicant("Jaahanvi"), q, "y")

        found = self._find("aahan", [("assessment_id", "=", a.id)])
        self.assertEqual(set(found.ids), {trikha.id, jaahanvi.id})

    def test_an_assessment_title_finds_its_answers(self):
        tag = uuid4().hex[:8]
        mine = self._assessment("Forklift %s" % tag)
        other = self._assessment("Unrelated %s" % uuid4().hex[:8])
        q = self._question("Describe the defect")
        person = self._applicant("Someone")
        wanted = self._answer(mine, person, q, "x")
        unwanted = self._answer(other, person, q, "y")

        found = self._find(tag)
        self.assertIn(wanted, found)
        self.assertNotIn(unwanted, found)

    def test_a_question_name_finds_its_answers(self):
        a = self._assessment("A %s" % uuid4().hex[:6])
        tag = uuid4().hex[:8]
        wanted = self._answer(
            a, self._applicant("P"), self._question("Torque %s" % tag), "x")
        unwanted = self._answer(
            a, self._applicant("Q"), self._question("Other"), "y")

        found = self._find(tag)
        self.assertIn(wanted, found)
        self.assertNotIn(unwanted, found)

    def test_an_empty_term_selects_nothing_extra(self):
        self.assertEqual(self._domain(""), [])
        self.assertEqual(self._domain("   "), [])
        self.assertEqual(self._domain(None), [])


class TestTheBoundaryIsDeliberate(_Answers):
    """The answer TEXT is not searchable here, and that is the design."""

    def test_the_answer_text_is_not_an_axis(self):
        a = self._assessment("A %s" % uuid4().hex[:6])
        q = self._question("Describe the defect")
        needle = uuid4().hex[:10]
        answer = self._answer(a, self._applicant("P"), q, "contains %s" % needle)

        self.assertNotIn(
            answer, self._find(needle),
            "the server must NOT match raw answer text. The screen shows the "
            "REDACTED rendering, and a server that searched the raw text would "
            "let anyone confirm the contents of an anonymised attempt by "
            "guessing at them - the erasure undone by a search box")

    def test_the_predicate_names_exactly_three_fields(self):
        """A fourth axis added here silently changes what an operator's term
        means on a screen whose label says which half reaches what."""
        fields = {t[0] for t in self._domain("x") if isinstance(t, tuple)}
        self.assertEqual(
            fields, {"assessment_id", "evaluator_id", "question_id"})

    def test_wildcards_are_escaped(self):
        """A typed `%` means a literal `%`, as it does on the evaluator."""
        a = self._assessment("A %s" % uuid4().hex[:6])
        q = self._question("Describe the defect")
        literal = self._answer(a, self._applicant("50%% Complete"), q, "x")
        other = self._answer(a, self._applicant("Nothing Alike"), q, "y")

        found = self._find("50%", [("assessment_id", "=", a.id)])
        self.assertIn(literal, found)
        self.assertNotIn(
            other, found,
            "an unescaped % would be a wildcard and match everybody")


class TestSearchComposesWithTheExistingFilters(_Answers):

    def test_it_ands_rather_than_widens(self):
        """The predicate is appended LAST and as its own OR-group, so it
        narrows the filters above it instead of joining their chain."""
        mine = self._assessment("Mine %s" % uuid4().hex[:6])
        other = self._assessment("Other %s" % uuid4().hex[:6])
        q = self._question("Describe the defect")
        person = self._applicant("Aahan Trikha")
        here = self._answer(mine, person, q, "x")
        there = self._answer(other, person, q, "y")

        found = self._find("aahan", [("assessment_id", "=", mine.id)])
        self.assertIn(here, found)
        self.assertNotIn(
            there, found,
            "the same person's answer on ANOTHER assessment must not be "
            "pulled back in - that would be the search widening the filter")
