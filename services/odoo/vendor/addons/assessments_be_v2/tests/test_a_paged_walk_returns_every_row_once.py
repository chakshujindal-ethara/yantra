# -*- coding: utf-8 -*-
"""C1: an offset-paged listing must be a PARTITION of its population.

THE DEFECT (D2/D7). `_attempt_page()` pages with `order="create_date desc"`
and no unique tiebreaker. Odoo stamps `create_date` from `cr.now()`, which is
the TRANSACTION timestamp - so every row a bulk invitation writes shares one
identical value to the microsecond. Postgres has no obligation to order equal
keys consistently between two executions of the same query, and it does not:
`LIMIT n OFFSET k` is planned as a bounded top-N heapsort while `n + k` is below
the row count and as an unbounded quicksort once it is not, and the two
algorithms emit ties in different orders. Offset paging over that re-runs the
sort per page, so a row can land on two pages and another on none.

Measured on stage, walking `/api/v1/attempts` at limit=200 exactly as
`app_store.dart:1033 _loadAttempts()` does: `total` 2538, 2538 rows collected
across 13 pages, **2077 distinct**, 461 attempts never returned once. The row
COUNT was right and the rows were wrong, which is why this went unnoticed - the
client then filtered that corrupted sample locally and rendered one candidate
twice while never seeing another (D7).

WHAT THESE TESTS PIN. The property, not the mechanism: for any page size, the
concatenation of every page from offset 0 to `total` contains each row of the
population exactly once, and its length equals `meta.total`. A tiebreaker is one
way to satisfy that; the test does not care which way.

THE PAGE SIZE IS PART OF THE INPUT DOMAIN, which is why the walks below are
repeated across several. The planner only flips algorithm at particular
`(rows, limit, offset)` combinations, so a single page size can hide the defect
completely: on a 500-row cohort limit=50 loses rows and limit=200 does not.
That is a property of the plan, not evidence the route is sound - the same route
at production scale lost 461.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import admin as api_admin
from ._paging_harness import call_route, losses, walk

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"

#: One assessment, this many attempts, all created in ONE `create()` call.
#: 500 is the smallest round number that reproduces the loss at the page sizes
#: below while keeping the fixture inside a couple of seconds.
COHORT = 500


@tagged("-at_install", "post_install")
class _Cohort(TransactionCase):
    """A bulk-invited cohort: every attempt shares one `create_date`."""

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Question = self.env["assessments.be.question"]
        self.Generator = self.env["assessments.be.prompt"]
        self.Applicant = self.env["hr.applicant"].with_context(
            tracking_disable=True, mail_create_nolog=True, mail_notrack=True)
        self.env.user.group_ids = [
            (4, self.env.ref(MANAGER_GROUP).id)]
        self.controller = api_admin.EtpAssessmentApiAdmin()

    # ------------------------------------------------------------------
    # Fixtures
    # ------------------------------------------------------------------
    def _assessment(self, name=None):
        generator = self.Generator.create({"name": "Gen %s" % uuid4().hex[:6]})
        question = self.Question.create({
            "name": "Q %s" % uuid4().hex[:6],
            "question_type": "subjective_rubric",
            "prompt": "Answer it.",
            "difficulty": "easy",
            "generator_id": generator.id,
        })
        return self.Assessment.create({
            "name": name or "Paper %s" % uuid4().hex[:6],
            "generator_id": generator.id,
            "question_ids": [(6, 0, question.ids)],
        })

    def _cohort(self, assessment, size, prefix="Cand"):
        """`size` attempts on `assessment`, written in ONE create() call.

        ONE CALL IS THE BUG CONDITION. Odoo's `cr.now()` is memoised for the
        transaction, so a single `create()` of N rows stamps N identical
        `create_date` values - exactly the shape a bulk invitation writes and
        exactly what `order="create_date desc"` cannot break apart.
        """
        stamp = uuid4().hex[:8]
        applicants = self.Applicant.create([{
            "partner_name": "%s %04d %s" % (prefix, i, stamp),
            "email_from": "%s.%04d.%s@example.com" % (
                prefix.lower(), i, stamp),
        } for i in range(size)])
        evaluators = self.Evaluator.create([{
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        } for applicant in applicants])
        return evaluators

    # ------------------------------------------------------------------
    # Harness
    # ------------------------------------------------------------------
    def _roster_page(self, assessment_id):
        def page(limit, offset):
            return call_route(
                api_admin, self.controller, "assessment_candidates", self.env,
                path={"assessment_id": assessment_id},
                limit=limit, offset=offset)
        return page

    def _attempts_page(self, **filters):
        def page(limit, offset):
            return call_route(
                api_admin, self.controller, "attempt_list", self.env,
                limit=limit, offset=offset, **filters)
        return page

    def _assert_partition(self, page_call, population_ids, limit, label):
        ids, pages, meta = walk(page_call, limit)
        duplicated, missing = losses(ids, population_ids)
        self.assertEqual(
            meta["total"], len(population_ids),
            "%s: search_count itself is wrong, which is a different bug"
            % label)
        self.assertEqual(
            (len(set(ids)), duplicated, missing),
            (len(population_ids), [], []),
            "%s at limit=%d: %d pages returned %d rows, %d distinct, "
            "%d short of meta.total=%d. Returned more than once: %s. "
            "Never returned: %s"
            % (label, limit, pages, len(ids), len(set(ids)),
               len(population_ids) - len(set(ids)), meta["total"],
               duplicated[:12], missing[:12]))
        return ids


class TestTheRosterWalkKeepsEveryCandidate(_Cohort):
    """Test 1 - the direct C1 counterexample, on the per-assessment roster."""

    def test_the_cohort_has_one_create_date_which_is_the_bug_condition(self):
        """Fixture check: the ordering key really is non-unique.

        Without this the walk tests below could pass for the wrong reason - a
        fixture that accidentally spread `create_date` across rows would make
        `create_date desc` a total order and prove nothing.
        """
        assessment = self._assessment()
        cohort = self._cohort(assessment, 50)
        stamps = {ev.create_date for ev in cohort}
        self.assertEqual(
            len(stamps), 1,
            "the fixture is meant to be a bulk invitation: one transaction, "
            "one create_date, %d distinct values found" % len(stamps))

    def test_the_roster_walk_returns_every_candidate_exactly_once(self):
        """Walk `/api/v1/assessments/<id>/candidates` at limit=50.

        The route the Candidates tab should be reading. On unfixed code the walk
        collects `total` rows and fewer than `total` distinct ones.
        """
        assessment = self._assessment()
        cohort = self._cohort(assessment, COHORT)
        self._assert_partition(
            self._roster_page(assessment.id), cohort.ids, 50,
            "/assessments/<id>/candidates")

    def test_the_roster_walk_does_not_depend_on_the_page_size(self):
        """The population an operator sees must not be chosen by the page size.

        A corollary of Property 1 and the sharpest form of the counterexample:
        two walks of the same unchanged data at different page sizes must agree
        on the set of rows, whatever order they arrive in.
        """
        assessment = self._assessment()
        cohort = self._cohort(assessment, COHORT)
        page = self._roster_page(assessment.id)
        seen = {}
        for limit in (7, 40, 50, 100, 200):
            ids, _pages, _meta = walk(page, limit)
            seen[limit] = set(ids)
        reference = seen[200]
        for limit, got in sorted(seen.items()):
            self.assertEqual(
                got, reference,
                "limit=%d saw %d rows and limit=200 saw %d: the two walks "
                "disagree by %d rows, so which candidates exist depends on the "
                "page size the client happened to pick"
                % (limit, len(got), len(reference),
                   len(got ^ reference)))
            self.assertEqual(
                got, set(cohort.ids),
                "limit=%d lost %d of the %d-row cohort"
                % (limit, len(set(cohort.ids) - got), len(cohort)))


class TestTheGlobalWalkKeepsEveryAttempt(_Cohort):
    """Test 2 - the walk the Flutter client actually performs."""

    def test_the_global_walk_collects_meta_total_distinct_attempts(self):
        """`/api/v1/attempts` at limit=200, the client's own page size.

        `app_store.dart:1033 _loadAttempts()` pages this route at 200 and holds
        the result as `AppStore.attempts`, which every admin KPI and (today) the
        Candidates tab read. `distinct == meta.total` is the contract that walk
        depends on and the one stage broke: 2538 total, 2077 distinct.
        """
        # THE BARE LISTING IS NOT SCOPED, so the population is whatever the
        # database already holds plus this fixture. Snapshotted rather than
        # assumed empty: the test database carries committed rows from module
        # data, and `meta.total` counting them is correct behaviour, not drift.
        already = set(self.Evaluator.search([]).ids)
        first = self._assessment("Q7r + Grade & Fix %s" % uuid4().hex[:4])
        second = self._assessment("IG Entity %s" % uuid4().hex[:4])
        cohort = self._cohort(first, COHORT // 2, prefix="First")
        cohort |= self._cohort(second, COHORT // 2, prefix="Second")
        self._assert_partition(
            self._attempts_page(), sorted(already | set(cohort.ids)), 200,
            "/attempts")

    def test_the_global_walk_is_a_partition_at_every_page_size(self):
        """Property 1 over a swept page size, one assessment_id filter applied.

        `assessment_id` is the filter the client sends when it wants one
        cohort, so the property has to hold with a domain narrowing applied and
        not only on the bare listing.
        """
        assessment = self._assessment()
        cohort = self._cohort(assessment, 240)
        other = self._assessment()
        self._cohort(other, 60, prefix="Other")
        for limit in (1, 5, 20, 50, 200):
            self._assert_partition(
                self._attempts_page(assessment_id=assessment.id),
                cohort.ids, limit,
                "/attempts?assessment_id=%d" % assessment.id)

    def test_walking_twice_returns_the_same_sequence(self):
        """Two identical walks of unchanged data must agree row for row.

        Stronger than the set property and the one an operator experiences: a
        refresh that reshuffles the table has told them the data changed when it
        did not.
        """
        assessment = self._assessment()
        self._cohort(assessment, COHORT)
        page = self._roster_page(assessment.id)
        first, _p, _m = walk(page, 50)
        second, _p, _m = walk(page, 50)
        self.assertEqual(
            first, second,
            "two walks of the same unchanged cohort returned different "
            "sequences: %d positions differ"
            % sum(1 for a, b in zip(first, second) if a != b))


class TestThePropertyOverTheWholeGeneratedDomain(_Cohort):
    """Task 8.5's widened property: random cohorts, tie structures, page sizes.

    Task 1 scoped the generator to the all-identical `create_date` case so the
    first counterexample would be deterministic and reproducible. With a total
    order in place the property can be quantified over the whole input domain,
    and the tie STRUCTURE is the axis that matters: all-identical is one bulk
    invitation, clustered is several, all-distinct is a roster filled in by hand
    over weeks. Only the first shape is what anyone would have written by hand.
    """

    #: Fixed so a failure is reproducible from the log alone.
    SEED = 20260910

    def _stamp(self, cohort, stamps):
        self.env.flush_all()
        for record, stamp in zip(cohort, stamps):
            self.env.cr.execute(
                "UPDATE assessments_be_evaluator SET create_date = %s "
                "WHERE id = %s", (stamp, record.id))
        self.env.invalidate_all()

    def _tie_structure(self, rng, size):
        shape = rng.choice(("identical", "clusters", "distinct"))
        if shape == "identical":
            return shape, None
        if shape == "distinct":
            return shape, ["2026-04-01 00:%02d:%02d" % (i // 60, i % 60)
                           for i in range(size)]
        clusters = max(2, size // 5)
        return shape, ["2026-04-02 00:%02d:00" % (i % clusters)
                       for i in range(size)]

    def test_the_partition_holds_for_any_cohort_tie_shape_and_page_size(self):
        import random
        rng = random.Random(self.SEED)
        for case in range(10):
            assessment = self._assessment()
            size = rng.randint(1, 150)
            cohort = self._cohort(assessment, size, prefix="Prop%d" % case)
            shape, stamps = self._tie_structure(rng, size)
            if stamps:
                self._stamp(cohort, stamps)
            limit = rng.randint(1, 200)
            label = "case=%d size=%d shape=%s limit=%d" % (
                case, size, shape, limit)
            ids, _pages, meta = walk(self._roster_page(assessment.id), limit)
            duplicated, missing = losses(ids, cohort.ids)
            self.assertEqual(
                (len(set(ids)), duplicated, missing),
                (size, [], []),
                "%s: %d distinct of %d (duplicated %s, missing %s)"
                % (label, len(set(ids)), size, duplicated[:8], missing[:8]))
            self.assertEqual(meta["total"], size, label)

    def test_the_walked_sequence_is_monotonic_under_the_stated_order(self):
        """The concatenation of every page descends by `(create_date, id)`.

        The set property says no row is lost. This says the pages JOIN UP: a
        client that concatenates them holds one correctly ordered list rather
        than several correctly ordered fragments, which is what a table renders.
        """
        assessment = self._assessment()
        cohort = self._cohort(assessment, 120)
        # A clustered tie structure, so the assertion exercises both halves of
        # the composite: equal dates broken by id, unequal dates by date.
        self._stamp(cohort, ["2026-05-%02d 00:00:00" % (1 + (i % 8))
                             for i in range(120)])
        for limit in (1, 7, 40, 200):
            ids, _pages, _meta = walk(self._roster_page(assessment.id), limit)
            rows = self.Evaluator.browse(ids)
            keys = [(row.create_date, row.id) for row in rows]
            # The break position is computed with a default: `assertEqual`'s
            # message argument is evaluated BEFORE the comparison, so a bare
            # `next(...)` here raises StopIteration on the passing case and turns
            # a green test into an error.
            first_break = next(
                (i for i in range(1, len(keys)) if keys[i] > keys[i - 1]), None)
            self.assertEqual(
                keys, sorted(keys, reverse=True),
                "at limit=%d the concatenated pages are not descending by "
                "(create_date, id) - the first break is at position %s"
                % (limit, first_break))

    def test_two_walks_at_different_page_sizes_return_the_same_sequence(self):
        """Not merely the same SET - the same ORDER.

        A total order makes this assertable, and it is the property an operator
        actually relies on: changing the rows-per-page control must re-slice the
        same list, not reshuffle it.
        """
        assessment = self._assessment()
        self._cohort(assessment, 130)
        page = self._roster_page(assessment.id)
        reference, _p, _m = walk(page, 200)
        for limit in (1, 3, 17, 100):
            ids, _p, _m = walk(page, limit)
            self.assertEqual(
                ids, reference,
                "limit=%d produced a different row ORDER than limit=200"
                % limit)


class TestThePagingIndex(_Cohort):
    """Task 8.4 - the index `init()` creates, and its idempotence.

    `init()` runs on every module upgrade, so a DDL statement in it that is not
    idempotent turns the second upgrade into a hard failure.
    """

    INDEX = "assessments_be_evaluator_page_idx"

    def _index_row(self):
        self.env.cr.execute(
            """
            SELECT c.relname, i.indisvalid, pg_get_indexdef(i.indexrelid)
              FROM pg_class c
              JOIN pg_index i ON i.indexrelid = c.oid
             WHERE c.relname = %s
            """, (self.INDEX,))
        return self.env.cr.fetchone()

    def test_the_index_exists_and_is_valid(self):
        row = self._index_row()
        self.assertTrue(
            row, "%s is missing; every roster page is back to sorting the "
                 "whole cohort" % self.INDEX)
        self.assertTrue(row[1], "%s exists but is INVALID" % self.INDEX)

    def test_the_index_covers_the_columns_the_page_query_orders_by(self):
        """The definition, not merely the name.

        An index on the right table with the wrong column order would satisfy a
        name check and do nothing for the query.
        """
        definition = self._index_row()[2].lower()
        for expected in ("assessment_id", "create_date desc", "id desc"):
            self.assertIn(
                expected, definition,
                "%s no longer covers %r: %s"
                % (self.INDEX, expected, definition))
        self.assertLess(
            definition.index("assessment_id"),
            definition.index("create_date"),
            "assessment_id must lead, or the equality cannot be pushed into "
            "the index scan")

    def test_calling_init_again_is_a_no_op(self):
        """The second upgrade must not fail on an index that already exists."""
        before = self._index_row()
        self.Evaluator.init()
        self.Evaluator.init()
        self.assertEqual(self._index_row(), before)

    #: The exact SQL `_attempt_page` emits for the roster route, read off
    #: `Evaluator._search(...).select()` rather than guessed.
    PAGE_SQL = (
        'SELECT "assessments_be_evaluator"."id" '
        'FROM "assessments_be_evaluator" '
        'WHERE "assessments_be_evaluator"."assessment_id" IN (%s) '
        'ORDER BY "assessments_be_evaluator"."create_date" DESC, '
        '"assessments_be_evaluator"."id" DESC LIMIT 200 OFFSET 200')

    def test_the_index_can_serve_the_page_query_without_a_sort(self):
        """The claim worth pinning: this index CAN answer the shipped query.

        NOT "the planner will choose it", which is false at any size a test
        fixture or today's production data reaches. Measured with
        EXPLAIN (ANALYZE) on the exact SQL below, in a populated transaction:

            cohort / table     WITH the index               WITHOUT
            400 / 400          Seq Scan + Sort (ignored)    identical
            507 / 2,538        Bitmap + quicksort (ignored) identical
            10,000 / 50,000    Index Only Scan, NO Sort     Bitmap + top-N sort
                               0.16 ms                      4.24 ms  (26x)

        Below the crossover a bitmap scan of a few hundred rows plus a quicksort
        genuinely is cheaper and the planner is right to prefer it. The COST
        comparison is also not assertable here: this test database carries ~3,050
        heap pages against a handful of live rows after thousands of rolled-back
        transactions, and `ANALYZE` inside a transaction cannot correct
        `relpages`, so every index-scan estimate in it is inflated by orders of
        magnitude. A test that asserted a cost would be measuring the bloat.

        What IS size-independent, and is the thing that would silently make this
        index dead forever, is whether the composite can satisfy
        `ORDER BY create_date DESC, id DESC` at all with `assessment_id` pinned -
        i.e. whether the `DESC`/`DESC` mix and the column order are right.
        `enable_sort = off` makes the planner prefer any ordered path that
        exists; if the index can serve the ordering it appears with no Sort node,
        and if it cannot the plan still sorts. That is the assertion.
        """
        assessment = self._assessment()
        self._cohort(assessment, 200)
        self.env.flush_all()
        # Stats inside the transaction, or the planner sizes the cohort from an
        # empty pg_class and its choice says nothing about this index.
        self.env.cr.execute("ANALYZE assessments_be_evaluator")
        # `SET LOCAL` is scoped to the TRANSACTION, and Odoo runs every test in
        # this class inside one - a savepoint rollback does not undo it. Reset
        # explicitly so this test cannot change how a later one is planned.
        self.env.cr.execute("SET LOCAL enable_sort = off")
        try:
            self.env.cr.execute("EXPLAIN " + self.PAGE_SQL, (assessment.id,))
            plan = "\n".join(line[0] for line in self.env.cr.fetchall())
        finally:
            self.env.cr.execute("SET LOCAL enable_sort = on")
        self.assertIn(
            self.INDEX, plan,
            "%s cannot serve the ordering `_attempt_page` asks for even when "
            "sorting is discouraged, so it is dead weight at every table "
            "size:\n%s" % (self.INDEX, plan))
        self.assertNotIn(
            "Sort", plan,
            "%s was used and the plan STILL sorts, so the ORDER BY is not "
            "satisfied by the index scan - the column order or a DESC is "
            "wrong:\n%s" % (self.INDEX, plan))
