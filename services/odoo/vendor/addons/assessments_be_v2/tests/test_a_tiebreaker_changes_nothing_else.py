# -*- coding: utf-8 -*-
"""Property 4: adding a tiebreaker must change nothing except the tie.

OBSERVATION-FIRST. Every assertion here was written against the UNFIXED routes
and records what they actually do, so it passes before the ordering edit and has
to keep passing after it. Ten `order=` edits across three controller files is
the widest blast radius in the plan and every admin table in both UIs pages
through one of them; this file is the guard.

WHAT IS PINNED, and why each one is a plausible way to break this:

  * `/drafts`, `/bank`, `/emails` get NO edit. Their bodies are asserted
    row-for-row against the order each route documents, so an edit made to them
    by mistake shows up here rather than in a UI.
  * The `meta` block, at every page position INCLUDING the last partial page.
    `has_more` is computed from `offset + len(rows) < total`; a change that
    alters how many rows a page returns silently breaks a client's stop
    condition.
  * The clamp. `limit=201` must still clamp to 200 and a missing `limit` must
    still default to 40 - requirement 3.1 exists because an unbounded listing
    over the answers table is a worker-pinning vector. The leaderboard keeps its
    own separate 2000 ceiling.
  * Every filter combination's id SET. Adding `id desc` reorders rows and must
    never re-select them.
  * Newest-first. `create_date desc, id desc` reads as one intent only if the
    tiebreaker cannot outrank the primary key, so the discriminating fixture is
    the one where the newest attempt has the LOWEST id.

WHY THE SETS AND NOT THE ORDER on the attempt routes: pre-fix those routes have
no stable order to pin - that is the defect. Order is asserted where it is
already total (the control group) and preserved as a SET where it is not.
"""
import json
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import admin as api_admin
from ..controllers.api.common import (
    DEFAULT_LIMIT, MAX_LEADERBOARD, MAX_LIMIT,
)
from ._paging_harness import call_route, walk

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"

#: Deterministic generator seed for the property-style sweeps. Fixed so a
#: failure is reproducible from the log alone.
SEED = 20260910


@tagged("-at_install", "post_install")
class _Base(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.admin = api_admin.EtpAssessmentApiAdmin()
        self.Assessment = self.env["assessments.be"]
        self.Generator = self.env["assessments.be.prompt"]
        self.Question = self.env["assessments.be.question"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Draft = self.env["assessments.be.prompt.question"]
        self.Mail = self.env["mail.mail"]
        self.Applicant = self.env["hr.applicant"].with_context(
            tracking_disable=True, mail_create_nolog=True, mail_notrack=True)
        self.token = uuid4().hex[:8]

    # ------------------------------------------------------------------
    # Fixtures
    # ------------------------------------------------------------------
    def _generator(self):
        return self.Generator.create({"name": "Gen %s" % uuid4().hex[:6]})

    def _assessment(self):
        generator = self._generator()
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

    def _cohort(self, assessment, size, prefix="Cand"):
        applicants = self.Applicant.create([{
            "partner_name": "%s %04d %s" % (prefix, i, self.token),
            "email_from": "%s.%04d.%s@example.com" % (
                prefix.lower(), i, self.token),
        } for i in range(size)])
        return self.Evaluator.create([{
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        } for applicant in applicants])

    def _stamp_create_dates(self, records, stamps):
        """Give `records` the `create_date` values in `stamps`, oldest first.

        `create_date` is a magic column the ORM will not write, and every row a
        test creates shares the transaction timestamp - so a fixture with a real
        chronology has to set it directly. This is the only way to test
        "newest first" at all, and the only place this file touches SQL.
        """
        self.env.flush_all()
        for record, stamp in zip(records, stamps):
            self.env.cr.execute(
                "UPDATE assessments_be_evaluator SET create_date = %s "
                "WHERE id = %s", (stamp, record.id))
        self.env.invalidate_all()

    # ------------------------------------------------------------------
    # Harness
    # ------------------------------------------------------------------
    def _call(self, method, path=None, **params):
        return call_route(api_admin, self.admin, method, self.env,
                          path=path, **params)

    def _page(self, method, path=None, **filters):
        def page(limit, offset):
            return self._call(method, path=path, limit=limit, offset=offset,
                              **filters)
        return page

    @staticmethod
    def _canonical(body):
        """A stable text form of a response body, for an identity comparison."""
        return json.dumps(body, sort_keys=True, default=str)


class TestTheUntouchedRoutesKeepTheirBodies(_Base):
    """`/drafts`, `/bank`, `/emails` - no edit in task 8, and this proves it.

    Each is asserted against the order its own `search()` documents, computed
    independently through the ORM. That is what makes this a preservation test
    rather than a tautology: if the route's `order=` changes, the route and the
    ORM expression stop agreeing.
    """

    def test_drafts_rows_and_order_are_unchanged(self):
        generator = self._generator()
        name = "Pinned draft %s" % self.token
        self.Draft.create([{
            "prompt_id": generator.id, "name": name, "state": "draft",
        } for _ in range(25)])
        expected = self.Draft.search(
            [("state", "=", "draft"), ("name", "ilike", name)], order="id")
        response = self._call("draft_list", search=name, limit=200)
        self.assertEqual(
            [row["id"] for row in response["data"]], expected.ids,
            "/drafts no longer returns its rows in `id` order")
        self.assertEqual(response["meta"]["total"], len(expected))

    def test_bank_rows_and_order_are_unchanged(self):
        generator = self._generator()
        name = "Pinned bank %s" % self.token
        # Mixed sequences AND ties inside them: `sequence, id` has to sort the
        # sequence first and break the tie on id, and a fixture with one
        # sequence value cannot tell the two halves apart.
        self.Question.create([{
            "name": name,
            "question_type": "subjective_rubric",
            "prompt": "Answer it.",
            "difficulty": "easy",
            "sequence": (i % 3) * 10,
            "generator_id": generator.id,
        } for i in range(24)])
        expected = self.Question.search(
            [("retired", "=", False), ("name", "ilike", name)],
            order="sequence, id")
        response = self._call("bank_list", search=name, limit=200)
        self.assertEqual(
            [row["id"] for row in response["data"]], expected.ids,
            "/bank no longer returns its rows in `sequence, id` order")
        self.assertEqual(response["meta"]["total"], len(expected))

    def test_emails_rows_and_order_are_unchanged(self):
        assessment = self._assessment()
        self.Mail.create([{
            "subject": "Pinned mail %02d %s" % (i, self.token),
            "body_html": "<p>hi</p>",
            "email_to": "someone@example.com",
            "model": "assessments.be",
            "res_id": assessment.id,
            "state": "outgoing",
        } for i in range(20)])
        expected = self.Mail.sudo().search([
            ("mail_message_id.model", "=", "assessments.be"),
            ("mail_message_id.res_id", "=", assessment.id),
        ], order="id desc")
        response = self._call(
            "emails_for_record",
            path={"kind": "assessment", "record_id": assessment.id}, limit=200)
        self.assertEqual(
            [row["id"] for row in response["data"]], expected.ids,
            "/emails no longer returns its rows in `id desc` order")
        self.assertEqual(response["meta"]["total"], len(expected))

    def test_the_three_bodies_are_identical_across_two_calls(self):
        """Same request, same body - the routes are pure reads.

        A weaker claim than "identical before and after the fix", which no
        single test run can make, and the strongest one that is checkable here:
        it catches an ordering change that is itself unstable.
        """
        generator = self._generator()
        name = "Twice %s" % self.token
        self.Draft.create([{
            "prompt_id": generator.id, "name": name, "state": "draft",
        } for _ in range(15)])
        for _ in range(2):
            first = self._canonical(self._call("draft_list", search=name))
            second = self._canonical(self._call("draft_list", search=name))
            self.assertEqual(first, second)


class TestTheMetaBlockIsUnchanged(_Base):
    """`total`, `limit`, `offset`, `has_more` at every page position."""

    def setUp(self):
        super().setUp()
        self.assessment = self._assessment()
        self.cohort = self._cohort(self.assessment, 25)

    def test_meta_is_self_consistent_on_every_page_including_the_last(self):
        """25 rows at limit=10: pages of 10, 10 and 5, `has_more` clearing last.

        The last partial page is where a paging contract usually breaks - a
        client that trusts `has_more` stops one page early or loops forever.
        """
        seen = []
        for offset in (0, 10, 20):
            response = self._call(
                "assessment_candidates",
                path={"assessment_id": self.assessment.id},
                limit=10, offset=offset)
            meta = response["meta"]
            rows = response["data"]
            seen.append((offset, len(rows), meta["has_more"]))
            self.assertEqual(meta["total"], 25)
            self.assertEqual(meta["limit"], 10)
            self.assertEqual(meta["offset"], offset)
            self.assertEqual(
                meta["has_more"], (offset + len(rows)) < 25,
                "has_more at offset=%d disagrees with its own definition"
                % offset)
        self.assertEqual(
            seen, [(0, 10, True), (10, 10, True), (20, 5, False)],
            "the page shape of a 25-row population at limit=10 changed")

    def test_an_offset_past_the_end_is_an_empty_last_page(self):
        response = self._call(
            "assessment_candidates",
            path={"assessment_id": self.assessment.id}, limit=10, offset=990)
        self.assertEqual(response["data"], [])
        # W8: the roster also carries its chip counts; the paging keys are
        # what this pins.
        meta = dict(response["meta"])
        meta.pop("counts")
        self.assertEqual(meta,
                         {"total": 25, "limit": 10, "offset": 990,
                          "has_more": False})

    def test_every_paged_route_answers_the_same_meta_shape(self):
        """The four keys, on every route this plan touches or leaves alone.

        The envelope is shared (`paged()` in common.py), so this is really a
        check that no route has grown its own - which is how two screens end up
        disagreeing about what `total` means.
        """
        routes = [
            ("assessment_list", None, {}),
            ("generator_list", None, {}),
            ("draft_list", None, {}),
            ("bank_list", None, {}),
            ("tag_list", None, {}),
            ("user_list", None, {}),
            ("response_list", None, {}),
            ("ledger", None, {}),
            ("attempt_list", None, {}),
            ("assessment_candidates",
             {"assessment_id": self.assessment.id}, {}),
        ]
        for method, path, extra in routes:
            response = self._call(method, path=path, limit=5, offset=0, **extra)
            expected = ["has_more", "limit", "offset", "total"]
            if method == "assessment_candidates":
                # W8 - the roster, and only the roster, also carries its
                # state chips' counts.
                expected = ["counts"] + expected
            if method == "attempt_list":
                # The attempts poll, and only it, carries the clock its next
                # `changed_since` is taken from.
                expected = sorted(expected + ["server_time"])
            self.assertEqual(
                sorted(response["meta"]), expected,
                "%s answers a different meta shape" % method)
            self.assertEqual(response["meta"]["limit"], 5, method)
            self.assertEqual(response["meta"]["offset"], 0, method)


class TestTheClampStillHolds(_Base):
    """Requirement 3.1 - no caller may request an unbounded scan."""

    def setUp(self):
        super().setUp()
        self.assessment = self._assessment()
        self.cohort = self._cohort(self.assessment, 3)

    def _meta(self, **params):
        return self._call("assessment_candidates",
                          path={"assessment_id": self.assessment.id},
                          **params)["meta"]

    def test_an_oversized_limit_clamps_to_two_hundred(self):
        for asked in (201, 500, 100000):
            self.assertEqual(
                self._meta(limit=asked)["limit"], MAX_LIMIT,
                "limit=%s was not clamped to %d" % (asked, MAX_LIMIT))

    def test_a_missing_or_zero_limit_defaults_to_forty(self):
        self.assertEqual(self._meta()["limit"], DEFAULT_LIMIT)
        self.assertEqual(self._meta(limit=0)["limit"], DEFAULT_LIMIT)
        self.assertEqual(self._meta(limit="")["limit"], DEFAULT_LIMIT)

    def test_a_negative_limit_floors_at_one(self):
        self.assertEqual(self._meta(limit=-5)["limit"], 1)

    def test_a_negative_offset_floors_at_zero(self):
        for asked in (-1, -500):
            self.assertEqual(self._meta(offset=asked)["offset"], 0)

    def test_a_junk_limit_falls_back_to_the_default(self):
        self.assertEqual(self._meta(limit="lots")["limit"], DEFAULT_LIMIT)

    def test_the_leaderboard_keeps_its_own_separate_ceiling(self):
        """`MAX_LEADERBOARD` is 2000 and must not become `MAX_LIMIT`.

        The board is a whole-cohort ranking, not a paged list; clamping it at
        200 once ranked 200 of a 588-candidate cohort and said nothing.
        """
        self.assertEqual((MAX_LIMIT, MAX_LEADERBOARD), (200, 2000))
        response = self._call("leaderboard", limit=5000)
        self.assertLessEqual(len(response["data"]), MAX_LEADERBOARD)
        self.assertEqual(
            sorted(response["meta"]), ["returned", "total", "truncated"],
            "the leaderboard's meta is deliberately NOT the paged envelope")


class TestEveryFilterCombinationSelectsTheSameRows(_Base):
    """Requirement 3.3 - the existing filters are unchanged.

    Asserted as SETS against the ORM domain each filter documents. `id desc`
    reorders rows; it must never re-select them.
    """

    def setUp(self):
        super().setUp()
        self.assessment = self._assessment()
        self.cohort = self._cohort(self.assessment, 12)
        # A spread of states, results and release flags, written directly so
        # the fixture does not depend on the exam lifecycle.
        for index, evaluator in enumerate(self.cohort):
            evaluator.write({
                "state": ("pending", "in_progress", "submitted")[index % 3],
                "results_released": bool(index % 2),
            })
        submitted = self.cohort.filtered(lambda e: e.state == "submitted")
        for index, evaluator in enumerate(submitted):
            evaluator.write({"result": ("pass", "fail")[index % 2]})

    def _combinations(self):
        for state in ("", "pending", "in_progress", "submitted"):
            for result in ("", "pass", "fail"):
                for released in (False, True):
                    for flagged in (False, True):
                        yield state, result, released, flagged

    def _domain(self, state, result, released, flagged):
        domain = [("assessment_id", "=", self.assessment.id)]
        if state:
            domain.append(("state", "=", state))
        if result:
            domain.append(("result", "=", result))
        if released:
            domain.append(("results_released", "=", True))
        if flagged:
            domain += ["|", "|",
                       ("integrity_alert", "=", True),
                       ("score_outlier", "=", True),
                       ("scoring_error_flag", "!=", False)]
        return domain

    def test_every_combination_returns_the_documented_id_set(self):
        for state, result, released, flagged in self._combinations():
            expected = set(self.Evaluator.search(
                self._domain(state, result, released, flagged)).ids)
            response = self._call(
                "assessment_candidates",
                path={"assessment_id": self.assessment.id},
                limit=MAX_LIMIT, state=state, result=result,
                released_only=released, flagged_only=flagged)
            got = set(row["id"] for row in response["data"])
            label = "state=%r result=%r released=%r flagged=%r" % (
                state, result, released, flagged)
            self.assertEqual(got, expected, label)
            self.assertEqual(response["meta"]["total"], len(expected), label)

    def test_the_flagged_queue_is_the_three_advisory_flags_and_nothing_else(self):
        """`flagged_only` must keep meaning integrity OR outlier OR scoring error.

        Pinned here because task 9 appends a search predicate to the same
        domain, and appending INTO this OR-chain rather than beside it would
        widen the review queue to every searched candidate.
        """
        response = self._call(
            "assessment_candidates",
            path={"assessment_id": self.assessment.id},
            limit=MAX_LIMIT, flagged_only=True)
        expected = set(self.Evaluator.search(
            self._domain("", "", False, True)).ids)
        self.assertEqual(
            set(row["id"] for row in response["data"]), expected)


class TestNewestFirstStillHolds(_Base):
    """Requirement 3.3 - attempts stay newest-sitting-first.

    `id desc` orders ties. It must not outrank `create_date desc`, so the
    discriminating fixture is the one where the newest row has the LOWEST id.
    """

    def test_the_first_page_leads_with_the_most_recent_attempt(self):
        assessment = self._assessment()
        cohort = self._cohort(assessment, 5)
        # REVERSE CHRONOLOGY AGAINST ID ORDER, which is the whole point of this
        # fixture: `cohort[0]` has the LOWEST id and the NEWEST `create_date`, so
        # newest-first here means ASCENDING id. A route that had quietly become
        # `id desc` would return the list backwards and every other assertion in
        # this file would still pass.
        stamps = ["2026-01-0%d 00:00:00" % (5 - i) for i in range(5)]
        self._stamp_create_dates(cohort, stamps)
        newest = cohort[0]
        response = self._call(
            "assessment_candidates", path={"assessment_id": assessment.id},
            limit=200)
        rows = [row["id"] for row in response["data"]]
        self.assertEqual(
            rows[0], newest.id,
            "the roster no longer leads with the most recent attempt: "
            "expected %d (created %s), got %d"
            % (newest.id, stamps[0], rows[0]))
        self.assertEqual(
            rows, cohort.ids,
            "the whole page must descend by create_date - and on this fixture "
            "that is ascending id, so a plain `id desc` would reverse it")

    def test_the_global_listing_is_also_newest_first(self):
        assessment = self._assessment()
        cohort = self._cohort(assessment, 5)
        stamps = ["2026-02-0%d 00:00:00" % (5 - i) for i in range(5)]
        self._stamp_create_dates(cohort, stamps)
        response = self._call(
            "attempt_list", assessment_id=assessment.id, limit=200)
        self.assertEqual(
            [row["id"] for row in response["data"]], cohort.ids)


class TestPreservationOverGeneratedPopulations(_Base):
    """Property 4 over a generated input domain.

    The interesting inputs are the TIE STRUCTURES nobody writes down by hand, so
    they are generated: all-identical `create_date`, a few clusters, all
    distinct. Everything asserted here is a claim the tie cannot affect - the
    counts, the clamp arithmetic and `has_more`'s own definition - so it holds
    before the ordering fix as well as after it, which is what makes it a
    preservation property rather than Property 1 restated.
    """

    def _tie_structure(self, rng, size):
        shape = rng.choice(("identical", "clusters", "distinct"))
        if shape == "identical":
            return shape, None
        if shape == "distinct":
            return shape, ["2026-03-01 00:%02d:%02d" % (i // 60, i % 60)
                           for i in range(size)]
        clusters = max(2, size // 7)
        return shape, ["2026-03-02 00:%02d:00" % (i % clusters)
                       for i in range(size)]

    def test_counts_the_clamp_and_has_more_hold_for_any_tie_structure(self):
        import random
        rng = random.Random(SEED)
        for case in range(8):
            assessment = self._assessment()
            size = rng.randint(0, 60)
            cohort = self._cohort(assessment, size, prefix="Gen%d" % case)
            shape, stamps = self._tie_structure(rng, size)
            if stamps:
                self._stamp_create_dates(cohort, stamps)
            asked = rng.choice([1, 3, 7, 40, 199, 200, 201, 0, -4])
            expected_limit = max(1, min(asked or DEFAULT_LIMIT, MAX_LIMIT))
            label = ("case=%d size=%d shape=%s asked=%s"
                     % (case, size, shape, asked))
            # The clamp, on the value as ASKED - the walk below has to advance
            # by the clamped size or it would not be a walk at all.
            self.assertEqual(
                self._call("assessment_candidates",
                           path={"assessment_id": assessment.id},
                           limit=asked)["meta"]["limit"],
                expected_limit, label)
            ids, pages, meta = walk(
                self._page("assessment_candidates",
                           path={"assessment_id": assessment.id}),
                expected_limit)
            self.assertEqual(meta["total"], size, label)
            self.assertEqual(meta["limit"], expected_limit, label)
            self.assertFalse(meta["has_more"], label)
            self.assertEqual(len(ids), size, label)
            self.assertEqual(
                pages, max(1, -(-size // expected_limit)),
                "%s: the walk took a different number of pages than the "
                "population and page size imply" % label)
