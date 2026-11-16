# -*- coding: utf-8 -*-
"""C2: a search must run against the population, not a client-held sample.

THE DEFECT (D7). No attempt-listing route accepts a search term at all.
`_attempt_filters()` (`controllers/api/admin.py:402`) builds state, result,
released-only and flagged-only predicates and no name-or-email predicate, so a
`search` argument is not refused - it is SILENTLY IGNORED, which is worse,
because the caller gets a 200 and a full page back. The Flutter Candidates tab
therefore filters `AppStore.attempts` in Dart
(`assessment_detail_screen.dart:1854`), and after C1 that cache holds 2077 of
2538 attempts. Searching a corrupted sample is what rendered attempt 1481
(Jaahanvi, 13/19) twice on assessment 58 while Aahan Trikha's attempt 1723 was
never in the sample at all, and what answered "No candidate matches these
filters" on assessment 60 where both rows were missing.

`aahan` is the verified term and it is instructive: it matches "Aahan Trikha" as
a prefix and "Jaahanvi" in the MIDDLE of the word, because
`('applicant_id', 'ilike', term)` resolves through `hr.applicant`'s name search,
which is a substring match. A prefix-only search would have found one of the two
and looked like it worked.

WHAT THESE TESTS PIN. The API's id set for a term equals the id set the one
shared predicate selects over the whole population, and equals what Odoo's own
search view returns for the same term. Both are set equalities over the server
population, so neither can be satisfied by filtering a page.

THE STAGE REPRODUCTION IS NOT HERE. Task 3 also calls for a Playwright
observation against stage; that is a read-only browser check on a deployed
build, not something a unit test can carry, and it is recorded in the task notes
instead.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import admin as api_admin
from ._paging_harness import call_route

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"
SEARCH_VIEW = "assessments_be_v2.assessments_be_evaluator_search"

#: The verified term from the stage reproduction. Substring, not prefix.
TERM = "aahan"


@tagged("-at_install", "post_install")
class _Cohort(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.admin = api_admin.EtpAssessmentApiAdmin()
        self.Assessment = self.env["assessments.be"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Generator = self.env["assessments.be.prompt"]
        self.Question = self.env["assessments.be.question"]
        self.Applicant = self.env["hr.applicant"].with_context(
            tracking_disable=True, mail_create_nolog=True, mail_notrack=True)
        self.token = uuid4().hex[:8]
        self.assessment = self._assessment()
        self.people = self._people()
        self.cohort = self.Evaluator.create([{
            "assessment_id": self.assessment.id,
            "applicant_id": applicant.id,
        } for applicant in self.people])

    def _assessment(self):
        generator = self.Generator.create({"name": "Gen %s" % uuid4().hex[:6]})
        question = self.Question.create({
            "name": "Q %s" % uuid4().hex[:6],
            "question_type": "subjective_rubric",
            "prompt": "Answer it.",
            "difficulty": "easy",
            "generator_id": generator.id,
        })
        return self.Assessment.create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": generator.id,
            "question_ids": [(6, 0, question.ids)],
        })

    def _people(self):
        """The two verified matches, a distractor, and an email-only match.

        The email-only row is what makes this a test of the OR rather than of
        the name half alone - `candidate_email` is denormalised onto the
        evaluator precisely so an admin can find one person by address.
        """
        rows = [
            ("Aahan Trikha", "aahan.trikha"),
            ("Jaahanvi Sharma", "jaahanvi.sharma"),
            ("Someone Else", "someone.else"),
            ("Zainab Qureshi", "zz.aahan.by.email"),
        ]
        # Padding, so a route that ignores the term returns visibly too much
        # rather than coincidentally the right number of rows.
        rows += [("Filler %02d" % i, "filler.%02d" % i) for i in range(20)]
        return self.Applicant.create([{
            "partner_name": "%s %s" % (name, self.token),
            "email_from": "%s.%s@example.com" % (slug, self.token),
        } for name, slug in rows])

    # ------------------------------------------------------------------
    # The one predicate, spelled out here so the test does not depend on the
    # helper it is meant to validate existing yet.
    # ------------------------------------------------------------------
    def _expected_domain(self, term):
        return ["|", ("applicant_id", "ilike", term),
                ("candidate_email", "ilike", term)]

    def _expected_ids(self, term, scoped=True):
        domain = self._expected_domain(term)
        if scoped:
            domain = [("assessment_id", "=", self.assessment.id)] + domain
        return set(self.Evaluator.search(domain).ids)

    def _api_ids(self, method, path=None, **params):
        response = call_route(api_admin, self.admin, method, self.env,
                              path=path, limit=200, offset=0, **params)
        self.assertEqual(response.get("__status", 200), 200, response)
        return set(row["id"] for row in response["data"]), response["meta"]


class TestTheApiTakesASearchTerm(_Cohort):

    def test_the_term_matches_both_people_in_the_orm(self):
        """Fixture check: `aahan` really does select both, as it did on stage.

        Without this the tests below could pass by both sides returning nothing.
        """
        ids = self._expected_ids(TERM)
        names = self.Evaluator.browse(sorted(ids)).mapped(
            "applicant_id.partner_name")
        self.assertEqual(
            len(ids), 3,
            "expected Aahan Trikha, Jaahanvi Sharma and the email-only row; "
            "got %s" % sorted(names))
        self.assertTrue(any(n.startswith("Aahan Trikha") for n in names))
        self.assertTrue(any(n.startswith("Jaahanvi") for n in names))

    def test_the_roster_route_honours_search(self):
        """`/assessments/<id>/candidates?search=aahan`.

        The route the Candidates tab should call. On unfixed code the term is
        silently dropped and the whole cohort comes back.
        """
        expected = self._expected_ids(TERM)
        got, meta = self._api_ids(
            "assessment_candidates",
            path={"assessment_id": self.assessment.id}, search=TERM)
        self.assertEqual(
            got, expected,
            "the roster route returned %d rows for search=%r where the server "
            "population holds %d matches - the term was ignored, not applied"
            % (len(got), TERM, len(expected)))
        self.assertEqual(
            meta["total"], len(expected),
            "meta.total must count the SEARCHED population, or the client "
            "renders 'n of 572' over a filtered page")

    def test_the_global_route_honours_search(self):
        """`/attempts?search=aahan`, the route the client actually walks."""
        expected = self._expected_ids(TERM, scoped=False)
        got, meta = self._api_ids("attempt_list", search=TERM)
        self.assertEqual(got, expected)
        self.assertEqual(meta["total"], len(expected))

    def test_search_combines_with_the_existing_filters_as_an_and(self):
        """`flagged_only` is an OR-chain; the term must AND with it, not join it.

        A predicate appended INTO that OR-chain would widen the review queue to
        every searched candidate, which is the failure mode this asserts away.
        """
        expected = self._expected_ids(TERM) & set(
            self.Evaluator.search([
                ("assessment_id", "=", self.assessment.id),
                ("state", "=", "pending"),
            ]).ids)
        got, _meta = self._api_ids(
            "assessment_candidates",
            path={"assessment_id": self.assessment.id},
            search=TERM, state="pending")
        self.assertEqual(got, expected)

    def test_an_empty_term_changes_nothing(self):
        """A blank box must not narrow the listing to nothing."""
        whole = set(self.cohort.ids)
        for blank in ("", "   "):
            got, meta = self._api_ids(
                "assessment_candidates",
                path={"assessment_id": self.assessment.id}, search=blank)
            self.assertEqual(got, whole, "search=%r narrowed the roster" % blank)
            self.assertEqual(meta["total"], len(whole))

    def test_a_term_matching_nobody_returns_an_empty_page(self):
        got, meta = self._api_ids(
            "assessment_candidates",
            path={"assessment_id": self.assessment.id},
            search="no-such-person-%s" % uuid4().hex)
        self.assertEqual((got, meta["total"]), (set(), 0))


class TestOdooAndTheApiAgree(_Cohort):
    """Property 2's second half: the API and the Odoo list must return one set.

    Divergence between these two consumers is what produced D7, so it is
    asserted directly rather than assumed from both being "a search".
    """

    def _view_domain(self, term):
        """The search view's own `filter_domain`, with `self` bound to `term`.

        Read out of the shipped view's `arch` rather than retyped, so this test
        fails if the view's predicate changes and the API's does not.
        """
        from lxml import etree
        view = self.env.ref(SEARCH_VIEW)
        arch = etree.fromstring(view.arch)
        node = arch.xpath("//field[@name='applicant_id'][@filter_domain]")
        self.assertTrue(
            node, "the evaluator search view no longer carries a "
                  "filter_domain on applicant_id")
        from odoo.tools.safe_eval import safe_eval
        return safe_eval(node[0].get("filter_domain"), {"self": term})

    def test_the_api_returns_what_the_odoo_search_view_returns(self):
        expected = set(self.Evaluator.search(
            [("assessment_id", "=", self.assessment.id)]
            + self._view_domain(TERM)).ids)
        got, _meta = self._api_ids(
            "assessment_candidates",
            path={"assessment_id": self.assessment.id}, search=TERM)
        self.assertEqual(
            got, expected,
            "the API and the Odoo search view disagree on search=%r: the API "
            "returned %d rows, the view's own predicate selects %d"
            % (TERM, len(got), len(expected)))

    def test_they_agree_across_case_and_substring_variants(self):
        """Terms drawn from the fixture's own names, in every case shape.

        Case is where two `contains` implementations usually part company, and
        a mid-word substring is the shape that made `aahan` match "Jaahanvi".
        """
        terms = ["aahan", "AAHAN", "Aahan", "aAhAn", "trikha", "jaahanvi",
                 "@example.com", self.token, "zainab", "aahan.by.email"]
        for term in terms:
            expected = set(self.Evaluator.search(
                [("assessment_id", "=", self.assessment.id)]
                + self._view_domain(term)).ids)
            got, _meta = self._api_ids(
                "assessment_candidates",
                path={"assessment_id": self.assessment.id}, search=term)
            self.assertEqual(
                got, expected,
                "search=%r: API %d rows, Odoo view %d rows"
                % (term, len(got), len(expected)))


class TestSearchCommutesWithPaging(_Cohort):
    """Task 9.4 - search must not reintroduce the instability it was added to fix.

    A searched listing is still an offset-paged listing, and a narrowed domain is
    exactly the shape that used to hide C1: fewer rows means fewer pages means a
    smaller chance the planner flips algorithm. Asserted rather than assumed.
    """

    def _walk_searched(self, term, limit):
        from ._paging_harness import walk

        def page(page_limit, offset):
            return call_route(
                api_admin, self.admin, "assessment_candidates", self.env,
                path={"assessment_id": self.assessment.id},
                limit=page_limit, offset=offset, search=term)
        return walk(page, limit)

    def test_walking_a_searched_listing_yields_the_searched_population(self):
        for term in (TERM, "filler", self.token):
            expected = self._expected_ids(term)
            for limit in (1, 2, 5, 200):
                ids, _pages, meta = self._walk_searched(term, limit)
                self.assertEqual(
                    set(ids), expected,
                    "search=%r at limit=%d walked %d distinct of %d"
                    % (term, limit, len(set(ids)), len(expected)))
                self.assertEqual(len(ids), len(expected),
                                 "search=%r at limit=%d returned a duplicate"
                                 % (term, limit))
                self.assertEqual(meta["total"], len(expected))

    def test_searching_then_paging_equals_paging_then_filtering(self):
        """The commutation, stated as the client would experience it.

        Walking the SEARCHED listing must give the same set as walking the whole
        listing and applying the same predicate afterwards - i.e. moving the
        search from the client to the server changes no result. That equality is
        the whole claim of requirement 2.3.
        """
        from ._paging_harness import walk

        def whole(limit, offset):
            return call_route(
                api_admin, self.admin, "assessment_candidates", self.env,
                path={"assessment_id": self.assessment.id},
                limit=limit, offset=offset)

        walked, _pages, _meta = walk(whole, 7)
        for term in (TERM, "trikha", "filler"):
            server_side, _p, _m = self._walk_searched(term, 7)
            client_side = set(walked) & self._expected_ids(term)
            self.assertEqual(
                set(server_side), client_side,
                "search=%r: server-side search and client-side filtering of "
                "the full walk disagree" % term)

    def test_a_searched_page_costs_the_same_number_of_queries_as_a_plain_one(self):
        """No N+1: the predicate must not turn one page into per-row lookups.

        `('applicant_id', 'ilike', term)` resolves through `hr.applicant`'s name
        search, which is a SUBQUERY - one extra join, executed once. If it ever
        becomes a per-record resolution the page cost grows with the cohort and
        the two-second poll saturates the connection pool, which is the failure
        mode the 2026-09-03 incident already produced once.
        """
        def count_queries(**params):
            self.env.flush_all()
            self.env.invalidate_all()
            before = self.env.cr.sql_log_count if hasattr(
                self.env.cr, "sql_log_count") else None
            if before is None:
                self.skipTest("this Odoo build does not count queries")
            call_route(api_admin, self.admin, "assessment_candidates", self.env,
                       path={"assessment_id": self.assessment.id},
                       limit=200, offset=0, **params)
            return self.env.cr.sql_log_count - before

        plain = count_queries()
        searched = count_queries(search=TERM)
        self.assertLessEqual(
            searched, plain + 2,
            "a searched page issued %d queries against %d for an unsearched "
            "one - the predicate is being resolved per row" % (searched, plain))
