# -*- coding: utf-8 -*-
"""Sorting the roster must not cost rows: a sorted walk is still a PARTITION.

THE SAME DEFECT AS C1, ONE COLUMN FURTHER ON. `tests/
test_a_paged_walk_returns_every_row_once.py` pins the property for the default
`create_date desc, id desc` listing and records what breaking it cost on stage:
`/api/v1/attempts` walked at limit=200 returned `total` 2538, 2538 rows, **2077
distinct** - 461 attempts never returned once, because offset paging re-runs the
sort per page and Postgres emits equal keys in whatever order the plan happens
to produce.

`create_date` was a BAD ordering key because a bulk invitation stamps every row
with one transaction timestamp. The nine columns the roster now sorts by are
worse, and not by accident:

    FLAG      `manual_flagged`     boolean  - ~700 of 711 rows share one key
    RELEASED  `results_released`   boolean  - the same, until results go out
    REMARKS   `manual_remark`      text     - NULL on nearly every row
    STATE     `state_rank`         integer  - three values over the cohort
    INVITE    `invite_state`       selection- one value for a whole launch
    RESULT    `result`             selection- `pending` until scoring finishes

A boolean over a cohort is not a sort key at all, it is a two-way partition; the
ORDER BY only becomes a total order once `id` is appended. So the assertion
below is the same one as C1's, quantified over every sortable column AND both
directions: walk the whole roster in pages, collect every id, and require the
count to equal `meta.total` with no id appearing twice.

THE FIXTURE IS BUILT FOR TIES ON PURPOSE. A cohort with 60 distinct scores and
60 distinct names would pass this file on unfixed code - the primary key would
already be a total order and the tiebreaker would never be reached. Every column
here is deliberately near-constant, which is what a real roster looks like on the
morning of an exam.

ALSO PINNED HERE, because each one is a way to ship the sort and still be wrong:

  * An unknown `sort` key - a client one deploy behind, or one naming a column
    that has been renamed - degrades to newest-first. It must never 4xx: losing
    the roster is a far worse answer than ignoring a sort.
  * A key that names a real stored field but is not an offered column
    (`access_token`, `create_date`) does the same. The allow-list is the guard,
    not the field's existence.
  * Ascending and descending are exact inverses. If they are not, one of the two
    is not the total order it claims to be.
  * STATE sorts by the lifecycle (Not started -> In progress -> Submitted) and
    not by the stored keys' alphabet, which would put `in_progress` first.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import admin as api_admin
from ._paging_harness import call_route, losses, walk

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"

#: Big enough that the page sizes below produce five to nine pages each, small
#: enough that 36 walks of it stay inside a couple of seconds.
COHORT = 60

#: Five names over sixty candidates. Namesakes are real on a large roster and
#: they are also the only way the CANDIDATE column's tiebreaker gets exercised.
NAMES = ("Aahan Trikha", "Kritika Kumari", "Harshal Bisht",
         "Aahan Trikha", "Priya Nair")


@tagged("-at_install", "post_install")
class _TiedCohort(TransactionCase):
    """A cohort whose every sortable column is near-constant."""

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Question = self.env["assessments.be.question"]
        self.Generator = self.env["assessments.be.prompt"]
        self.Applicant = self.env["hr.applicant"].with_context(
            tracking_disable=True, mail_create_nolog=True, mail_notrack=True)
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.controller = api_admin.EtpAssessmentApiAdmin()

    # ------------------------------------------------------------------
    # Fixtures
    # ------------------------------------------------------------------
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

    def _cohort(self, assessment, size=COHORT):
        """`size` attempts, every sortable column deliberately tied.

        THE VALUES ARE CYCLED, NOT BLOCKED. Assigning the first twenty rows
        `pending` and the last twenty `submitted` would make the sort order
        agree with the id order by construction, and a walk that lost rows
        could still come back looking sorted. Cycling decorrelates every column
        from the primary key, so a wrong order shows up as a wrong sequence.
        """
        stamp = uuid4().hex[:8]
        applicants = self.Applicant.create([{
            "partner_name": NAMES[i % len(NAMES)],
            "email_from": "cand.%04d.%s@example.com" % (i, stamp),
        } for i in range(size)])
        cohort = self.Evaluator.create([{
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        } for applicant in applicants])

        # Plain stored columns go through the ORM, so `state_rank` recomputes
        # from its `@api.depends("state")` exactly as it does in production.
        for i, record in enumerate(cohort):
            record.write({
                "state": ("pending", "in_progress", "submitted")[i % 3],
                "invite_state": "sent" if i % 7 == 0 else "none",
                "manual_flagged": i % 10 == 0,
                "results_released": i >= size - 3,
                "manual_remark": "Reviewed" if i % 15 == 0 else False,
            })

        # `answered_count`, `total_score` and `result` are COMPUTED stored
        # fields, so they are stamped in SQL rather than written - the same
        # thing `test_a_paged_walk_returns_every_row_once._stamp()` does to
        # `create_date`. Flush first so the ORM's own recompute (writing
        # `state` above invalidates `result`) lands BEFORE these values and
        # cannot overwrite them; invalidate after so the cache reads the column.
        self.env.flush_all()
        for i, record in enumerate(cohort):
            self.env.cr.execute(
                "UPDATE assessments_be_evaluator "
                "SET answered_count = %s, total_score = %s, result = %s "
                "WHERE id = %s",
                (i % 4, (i % 3) * 5,
                 ("pending", "pending", "pass", "fail")[i % 4], record.id))
        self.env.invalidate_all()
        return cohort

    # ------------------------------------------------------------------
    # Harness
    # ------------------------------------------------------------------
    def _roster_page(self, assessment_id, **params):
        def page(limit, offset):
            return call_route(
                api_admin, self.controller, "assessment_candidates", self.env,
                path={"assessment_id": assessment_id},
                limit=limit, offset=offset, **params)
        return page

    def _attempts_page(self, **params):
        def page(limit, offset):
            return call_route(
                api_admin, self.controller, "attempt_list", self.env,
                limit=limit, offset=offset, **params)
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


class TestEverySortedWalkReturnsEveryCandidateOnce(_TiedCohort):
    """The case this file exists for: the partition property, per column."""

    def test_the_fixture_really_is_tied(self):
        """Fixture check: without ties this file proves nothing.

        Every column must have far fewer distinct values than rows, or the
        primary sort is already close to a total order and the missing
        tiebreaker would never be reached - the tests below would then pass on
        code that loses rows in production.
        """
        cohort = self._cohort(self._assessment())
        for column, field in sorted(api_admin._SORTABLE.items()):
            values = {record[field] for record in cohort}
            self.assertLess(
                len(values), len(cohort) // 4,
                "%s (%s) has %d distinct values over %d rows, which is too "
                "close to unique to exercise the tiebreaker"
                % (column, field, len(values), len(cohort)))

    def test_every_column_and_direction_is_a_partition(self):
        """Nine columns, both directions, on the route the roster calls.

        On code without the forced `id` tiebreaker this is the walk that comes
        back with `total` rows and fewer than `total` distinct ones - the same
        counterexample as C1, reached through the sort instead of through
        `create_date`.
        """
        assessment = self._assessment()
        cohort = self._cohort(assessment)
        for column in sorted(api_admin._SORTABLE):
            for descending in (False, True):
                self._assert_partition(
                    self._roster_page(
                        assessment.id, sort=column, sort_desc=descending),
                    cohort.ids, 7,
                    "/candidates?sort=%s&sort_desc=%d" % (column, descending))

    def test_a_sorted_walk_does_not_depend_on_the_page_size(self):
        """Which candidates exist must not depend on the rows-per-page control.

        The sharpest form of the property: two walks of the same unchanged
        cohort under the same sort, at different page sizes, must agree on the
        row SET. A boolean column is the worst case, so FLAG is the one swept.
        """
        assessment = self._assessment()
        cohort = self._cohort(assessment)
        page = self._roster_page(assessment.id, sort="flag", sort_desc=True)
        for limit in (1, 7, 13, 40, 200):
            ids, _pages, _meta = walk(page, limit)
            self.assertEqual(
                set(ids), set(cohort.ids),
                "sort=flag at limit=%d lost %d of the %d-row cohort"
                % (limit, len(set(cohort.ids) - set(ids)), len(cohort)))

    def test_the_global_attempts_route_sorts_too(self):
        """Both routes come off `_attempt_page`, so both gained the sort.

        Asserted rather than assumed: the two routes have drifted before, and
        one helper serving both is the only reason this feature is one edit.
        """
        assessment = self._assessment()
        cohort = self._cohort(assessment)
        self._assert_partition(
            self._attempts_page(
                assessment_id=assessment.id, sort="score", sort_desc=True),
            cohort.ids, 13, "/attempts?sort=score")


class TestAnUnknownSortKeyKeepsTheRoster(_TiedCohort):
    """A sort nobody can serve must cost the sort, never the table."""

    def _newest_first(self, assessment, cohort):
        ids, _pages, _meta = walk(self._roster_page(assessment.id), 13)
        self.assertEqual(len(ids), len(cohort))
        return ids

    def test_an_unknown_key_falls_back_to_newest_first(self):
        assessment = self._assessment()
        cohort = self._cohort(assessment)
        reference = self._newest_first(assessment, cohort)
        for key in ("", "wat", "SCORE", "1; drop table"):
            ids, _pages, meta = walk(
                self._roster_page(assessment.id, sort=key), 13)
            self.assertEqual(
                meta["total"], len(cohort),
                "sort=%r changed how many candidates exist" % key)
            self.assertEqual(
                ids, reference,
                "sort=%r did not degrade to newest-first: %d of %d positions "
                "differ from the unsorted walk"
                % (key, sum(1 for a, b in zip(ids, reference) if a != b),
                   len(reference)))

    def test_a_real_field_that_is_not_an_offered_column_is_refused(self):
        """The allow-list is the guard, not the field's existence.

        `access_token` is a bearer credential and `create_date` is not a column
        the roster renders; both are stored fields `search(order=...)` would
        happily accept. Passing the client's string through is what would let
        either of them order the table.
        """
        assessment = self._assessment()
        cohort = self._cohort(assessment)
        reference = self._newest_first(assessment, cohort)
        for field in ("access_token", "create_date", "candidate_email"):
            self.assertNotIn(field, api_admin._SORTABLE)
            ids, _pages, _meta = walk(
                self._roster_page(assessment.id, sort=field), 13)
            self.assertEqual(
                ids, reference,
                "sort=%r reached search(order=...) instead of falling back"
                % field)


class TestAscendingAndDescendingAreInverses(_TiedCohort):
    """If the two directions are not exact mirrors, neither is a total order."""

    def test_each_column_reverses_exactly(self):
        assessment = self._assessment()
        self._cohort(assessment)
        for column in sorted(api_admin._SORTABLE):
            ascending, _p, _m = walk(
                self._roster_page(assessment.id, sort=column), 13)
            descending, _p, _m = walk(
                self._roster_page(
                    assessment.id, sort=column, sort_desc=True), 13)
            self.assertEqual(
                descending, list(reversed(ascending)),
                "sort=%s descending is not the reverse of ascending: %d of %d "
                "positions differ. With ties everywhere that means the id "
                "tiebreaker is missing from one direction or points the wrong "
                "way."
                % (column, sum(1 for a, b in zip(
                    descending, list(reversed(ascending))) if a != b),
                   len(ascending)))


class TestTheStateColumnSortsByLifecycle(_TiedCohort):
    """`state_rank`, and why the column does not sort on `state`."""

    LIFECYCLE = ("pending", "in_progress", "submitted")

    def test_the_rank_follows_the_selection_order(self):
        cohort = self._cohort(self._assessment())
        for position, key in enumerate(self.LIFECYCLE):
            for record in cohort.filtered(lambda r, k=key: r.state == k):
                self.assertEqual(
                    record.state_rank, position,
                    "state=%s ranked %d, expected %d"
                    % (key, record.state_rank, position))

    def test_changing_the_state_moves_the_row(self):
        """The `@api.depends` is what keeps the column honest after a submit."""
        cohort = self._cohort(self._assessment())
        record = cohort.filtered(lambda r: r.state == "pending")[0]
        record.write({"state": "submitted"})
        self.assertEqual(
            record.state_rank, 2,
            "a candidate who submitted still ranks as not-started, so the "
            "roster sorts them with the no-shows")

    def test_sorting_state_walks_the_lifecycle_and_not_the_alphabet(self):
        """`ORDER BY state` gives `in_progress, pending, submitted`.

        That is the defect: an operator sorting STATE to find who has not
        started gets the middle of the lifecycle first. The walk below must
        come back Not started -> In progress -> Submitted.
        """
        assessment = self._assessment()
        cohort = self._cohort(assessment)
        ids, _pages, _meta = walk(
            self._roster_page(assessment.id, sort="state"), 7)
        states = [record.state for record in self.Evaluator.browse(ids)]
        self.assertEqual(len(states), len(cohort))
        seen = [key for i, key in enumerate(states)
                if i == 0 or key != states[i - 1]]
        self.assertEqual(
            seen, list(self.LIFECYCLE),
            "sorting STATE ascending produced the blocks %s; the lifecycle "
            "order is %s (a repeated key here means the column is not sorted "
            "at all)" % (seen, list(self.LIFECYCLE)))
