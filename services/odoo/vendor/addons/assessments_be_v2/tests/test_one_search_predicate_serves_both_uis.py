# -*- coding: utf-8 -*-
"""The drift guard: Odoo's search view and the API must share one predicate.

D7 was not a search bug. It was two consumers of the same idea, written twice.
Odoo's evaluator search view carries a `filter_domain`; the Flutter Candidates
tab carried a Dart `toLowerCase().contains()`; the API carried nothing at all.
Nothing anywhere asserted that any two of the three agreed, so they did not have
to.

`_be_search_domain` makes the server side one expression. The XML cannot import
Python, so this file asserts the equality instead of sharing it - and an
asserted equality is the entire difference between this and the divergence that
caused the defect. If somebody edits the view's `filter_domain` and not the
model method, or the reverse, this fails.

THE ONE DELIBERATE DIFFERENCE, pinned at the bottom of this file: the Python
predicate ESCAPES `%` and `_` and the view cannot. Postgres reads both as
wildcards, Dart's `contains` reads them literally, and the API's job is to match
what a person typing into either UI expects - so the API takes the literal
reading. Odoo's own search bar keeps its wildcard behaviour, which is what an
Odoo user expects there. That difference is asserted rather than left to be
discovered.
"""
from uuid import uuid4

from lxml import etree

from odoo.tests.common import TransactionCase, tagged
from odoo.tools.safe_eval import safe_eval

SEARCH_VIEW = "assessments_be_v2.assessments_be_evaluator_search"


@tagged("-at_install", "post_install")
class TestOneSearchPredicate(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Evaluator = self.env["assessments.be.evaluator"]

    # ------------------------------------------------------------------
    # The predicate itself
    # ------------------------------------------------------------------
    def test_an_empty_term_produces_no_predicate(self):
        """An empty box must not narrow anything.

        `[]` and not `[(1, '=', 0)]`: a blank search is "no filter", and a route
        that returned nothing for a blank box would look broken on first paint.
        """
        for blank in (None, "", "   ", "\t\n"):
            self.assertEqual(
                self.Evaluator._be_search_domain(blank), [],
                "search=%r must produce no predicate" % blank)

    def test_the_predicate_is_exactly_the_or_of_the_two_ilikes(self):
        self.assertEqual(
            self.Evaluator._be_search_domain("aahan"),
            ["|", ("applicant_id", "ilike", "aahan"),
             ("candidate_email", "ilike", "aahan")])

    def test_the_term_is_trimmed(self):
        self.assertEqual(
            self.Evaluator._be_search_domain("  aahan  "),
            self.Evaluator._be_search_domain("aahan"))

    def test_the_wildcards_are_escaped(self):
        """`%` and `_` are matched literally, as Dart's `contains` does."""
        self.assertEqual(
            self.Evaluator._be_search_domain("100%"),
            ["|", ("applicant_id", "ilike", r"100\%"),
             ("candidate_email", "ilike", r"100\%")])
        self.assertEqual(
            self.Evaluator._be_search_domain("a_b"),
            ["|", ("applicant_id", "ilike", r"a\_b"),
             ("candidate_email", "ilike", r"a\_b")])

    def test_a_backslash_is_escaped_before_the_wildcards_are(self):
        """Order matters: escape `\\` first or the escapes get escaped again."""
        self.assertEqual(
            self.Evaluator._be_search_domain("a\\%b")[1][2], r"a\\\%b")

    def test_an_escaped_wildcard_matches_it_literally_in_the_database(self):
        """The escaping is asserted against Postgres, not just as a string.

        A `\\%` that Postgres did not honour would make this whole method a
        no-op with confident-looking unit tests behind it.
        """
        Applicant = self.env["hr.applicant"].with_context(
            tracking_disable=True, mail_create_nolog=True, mail_notrack=True)
        token = uuid4().hex[:8]
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % token})
        question = self.env["assessments.be.question"].create({
            "name": "Q %s" % token, "question_type": "subjective_rubric",
            "prompt": "Answer it.", "difficulty": "easy",
            "generator_id": generator.id})
        assessment = self.env["assessments.be"].create({
            "name": "Paper %s" % token, "generator_id": generator.id,
            "question_ids": [(6, 0, question.ids)]})
        literal, plain = Applicant.create([
            {"partner_name": "Pct 100%% Done %s" % token,
             "email_from": "pct.%s@example.com" % token},
            {"partner_name": "No Percent Here %s" % token,
             "email_from": "plain.%s@example.com" % token},
        ])
        attempts = self.Evaluator.create([
            {"assessment_id": assessment.id, "applicant_id": literal.id},
            {"assessment_id": assessment.id, "applicant_id": plain.id},
        ])
        scoped = [("assessment_id", "=", assessment.id)]
        # `100%` must select ONLY the row whose name contains a literal `%`.
        got = self.Evaluator.search(
            scoped + self.Evaluator._be_search_domain("100%"))
        self.assertEqual(got, attempts[0])
        # Unescaped, `100%` would be a wildcard and select nothing extra here,
        # so the discriminating term is a bare `%`: escaped it matches only the
        # literal row, unescaped it would match the whole cohort.
        got = self.Evaluator.search(
            scoped + self.Evaluator._be_search_domain("%"))
        self.assertEqual(
            got, attempts[0],
            "a bare '%%' selected %d of %d rows - the escape is not reaching "
            "Postgres, so every wildcard a user types is a full scan of the "
            "cohort" % (len(got), len(attempts)))

    # ------------------------------------------------------------------
    # The guard
    # ------------------------------------------------------------------
    def _view_filter_domain(self):
        """The raw `filter_domain` string off the shipped search view."""
        view = self.env.ref(SEARCH_VIEW)
        node = etree.fromstring(view.arch).xpath(
            "//field[@name='applicant_id'][@filter_domain]")
        self.assertTrue(
            node,
            "the evaluator search view no longer carries a filter_domain on "
            "applicant_id; the API's predicate now has nothing to agree with")
        return node[0].get("filter_domain")

    def test_the_view_and_the_model_produce_the_same_expression(self):
        """The guard. Any term without a wildcard in it, both sides, identical.

        Terms are drawn from the shapes that actually reach these boxes: the
        verified `aahan`, an email fragment, a surname, mixed case, a term with
        internal spaces.
        """
        raw = self._view_filter_domain()
        for term in ("aahan", "AAHAN", "Trikha", "@ethara.ai", "jaahanvi",
                     "aahan trikha", "1481"):
            self.assertEqual(
                safe_eval(raw, {"self": term}),
                self.Evaluator._be_search_domain(term),
                "the Odoo search view and _be_search_domain disagree on %r - "
                "the two UIs will diverge on it exactly as they did on D7"
                % term)

    def test_the_view_and_the_model_select_the_same_field_pair(self):
        """A structural check that survives the escaping difference.

        Asserted separately from the expression equality above so a future
        change to the escaping cannot quietly take the field pair with it.
        """
        raw = self._view_filter_domain()
        view_shape = [
            item if isinstance(item, str) else (item[0], item[1])
            for item in safe_eval(raw, {"self": "x"})]
        model_shape = [
            item if isinstance(item, str) else (item[0], item[1])
            for item in self.Evaluator._be_search_domain("100%")]
        self.assertEqual(
            view_shape, model_shape,
            "the view and the model no longer search the same fields with the "
            "same operator")

    def test_the_wildcard_difference_is_deliberate_and_only_the_wildcards(self):
        """The one place the two sides part company, pinned so it cannot spread.

        For a term containing `%` or `_` the API takes the literal reading and
        Odoo's search bar keeps the wildcard one. Everything else about the
        expression - the OR, the two fields, the `ilike` operator - stays
        identical.
        """
        raw = self._view_filter_domain()
        for term in ("100%", "a_b", "%"):
            view = safe_eval(raw, {"self": term})
            model = self.Evaluator._be_search_domain(term)
            self.assertNotEqual(
                view, model,
                "%r no longer differs between the two sides; if the escaping "
                "was removed, say so here rather than deleting the test" % term)
            self.assertEqual(
                [type(i) for i in view], [type(i) for i in model])
            self.assertEqual(
                [i[:2] for i in view if not isinstance(i, str)],
                [i[:2] for i in model if not isinstance(i, str)])
