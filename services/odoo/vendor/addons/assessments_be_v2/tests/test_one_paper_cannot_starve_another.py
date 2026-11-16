# -*- coding: utf-8 -*-
"""A big cohort must not stop a small one from being graded at all.

WHAT HAPPENED, on production, on 2026-09-18. Four assessments were queued for
subjective grading at once. `_scoring_shard_evaluators` ordered the whole queue
by evaluator id and took the lowest `scoring_tick_limit` of it, which is a
global FIFO with no fairness between papers. Evaluator ids ascend with the
roster, so the newest assessment held the highest ids:

    assessment 44   442 queued   ids  5446 -  6095
    assessment 45    26 queued   ids  6774 -  6799
    assessment 47    53 queued   ids  7478 -  7536
    assessment 57   217 queued   ids 11919 - 12619   <- 521 candidates behind

For two and a half hours every tick took twenty candidates from the oldest
cohort. 468 billable calls were made in that window and not one of them
belonged to assessment 57; `llm_attempts` was still 0 on all 433 of its
answers. It was not stuck, cancelled or failing - the crons were alive, spend
was $87 against a $400 cap, and no answer was in error - so an operator
watching that paper saw a queue that never moved behind a grader that was
demonstrably running.

The fix deals the tick across the assessments that have work instead of
sorting the queue flat. Nothing here calls Vertex: the selector is asserted
directly, because it runs before any billable call.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase


def clear_the_queue(env):
    """Take every candidate already queued in the database out of the lane's
    way, inside the test's transaction. A tick takes the oldest queued
    candidate in the WHOLE database, so a fixture is only the lane's work
    once nothing else is (RV6-01)."""
    env["assessments.be.evaluator"].search(
        [("scoring_requested", "=", True)]).write({"scoring_requested": False})
    env["assessments.be.response"].search(
        [("rescore_request_key", "!=", False)]).write(
        {"rescore_request_key": False})


class _Base(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Starvation fixture %s" % uuid4().hex[:6]})

    def _paper(self):
        return self.Assessment.create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id,
            "duration_minutes": 30,
        })

    def _queue(self, assessment, count):
        """`count` submitted candidates waiting for the grader.

        No responses: the drainer's domain selects on the ATTEMPT's `state`,
        `scoring_requested` and `llm_state`, so a response would only make the
        fixture slower. Created in order, which is what gives the first paper
        the lower ids - the whole shape of the bug.
        """
        made = self.Evaluator
        for _ in range(count):
            applicant = self.env["hr.applicant"].create({
                "partner_name": "Cand %s" % uuid4().hex[:6],
                "email_from": "cand_%s@example.com" % uuid4().hex[:8],
            })
            made |= self.Evaluator.create({
                "assessment_id": assessment.id,
                "applicant_id": applicant.id,
                "state": "submitted",
                "scoring_requested": True,
                "llm_state": "pending",
            })
        return made

    def _tick(self, limit, shard=0, shard_count=1):
        return self.Assessment._scoring_shard_evaluators(
            shard, shard_count, limit=limit)


class TestATickIsDealtNotSorted(_Base):

    def setUp(self):
        super().setUp()
        clear_the_queue(self.env)

    def test_the_newest_paper_is_reached_on_the_very_first_tick(self):
        """THE INCIDENT, in miniature.

        `big` is created first so it holds the lower ids, exactly as the
        445-candidate cohort did. Under the flat sort every one of the 20
        slots went to it and `small` waited for the whole thing to drain.
        """
        big = self._paper()
        self._queue(big, 25)
        small = self._paper()
        wanted = self._queue(small, 3)

        picked = self._tick(limit=20)

        self.assertEqual(len(picked), 20, "the tick still spends its budget")
        reached = picked.filtered(lambda e: e.assessment_id == small)
        self.assertEqual(
            len(reached), 3,
            "every candidate of the small paper must be reached on the first "
            "tick; under the old flat sort it got none of the 20 and stayed "
            "invisible behind 25 older ids")
        self.assertEqual(set(reached.ids), set(wanted.ids))

    def test_one_paper_alone_still_gets_the_whole_tick(self):
        """The fairness must not cost throughput when there is nothing to be
        fair to. A single queued cohort drains exactly as fast as before."""
        only = self._paper()
        self._queue(only, 30)

        picked = self._tick(limit=20)

        self.assertEqual(len(picked), 20)
        self.assertEqual(picked.mapped("assessment_id"), only)

    def test_a_tick_smaller_than_the_papers_still_reaches_each_one(self):
        """Three papers, a budget of 3: one each, not three from the oldest."""
        papers = [self._paper() for _ in range(3)]
        for paper in papers:
            self._queue(paper, 5)

        picked = self._tick(limit=3)

        self.assertEqual(len(picked), 3)
        self.assertEqual(
            len(set(picked.mapped("assessment_id").ids)), 3,
            "a budget of three across three queued papers is one each")

    def test_within_a_paper_it_is_still_oldest_first(self):
        """Fairness is BETWEEN papers only. Inside one, the order stays the id
        order it was handed, so the candidate who has waited longest is still
        graded first and a tick is still deterministic."""
        paper = self._paper()
        queued = self._queue(paper, 6)

        picked = self._tick(limit=3)

        self.assertEqual(picked.ids, sorted(queued.ids)[:3])

    def test_a_paper_with_nothing_queued_takes_no_slot(self):
        idle = self._paper()
        self._queue(idle, 4).write({"scoring_requested": False})
        busy = self._paper()
        self._queue(busy, 4)

        picked = self._tick(limit=4)

        self.assertEqual(picked.mapped("assessment_id"), busy)


class TestBothShardPathsAgree(_Base):
    """`shard_count <= 1` used to take a different branch with a different
    ORDER: the model's `create_date desc` (newest first) against the sharded
    path's `order="id"` (oldest first). One config value reversed the queue
    discipline, which is why this bug reproduced on a 4-shard production
    install and could not be reproduced on a 1-shard developer machine."""

    def test_sharding_partitions_the_queue_without_dropping_anybody(self):
        paper = self._paper()
        queued = self._queue(paper, 12)

        seen = self.Evaluator
        for shard in range(4):
            seen |= self._tick(limit=100, shard=shard, shard_count=4)

        self.assertEqual(
            set(seen.ids) & set(queued.ids), set(queued.ids),
            "every queued candidate is owned by exactly one shard, so the "
            "four shards together must cover the whole queue")

    def test_the_shards_never_hand_the_same_candidate_to_two_workers(self):
        paper = self._paper()
        self._queue(paper, 12)

        picks = [self._tick(limit=100, shard=s, shard_count=4).ids
                 for s in range(4)]

        flat = [ev for shard in picks for ev in shard]
        self.assertEqual(
            len(flat), len(set(flat)),
            "two shards grading one candidate is two bills for one answer")

    def test_one_shard_and_four_shards_start_from_the_same_end(self):
        """Both paths must be oldest-first. The single-shard branch used to be
        newest-first, so the same queue drained from opposite ends depending
        on a config value."""
        paper = self._paper()
        queued = self._queue(paper, 8)
        oldest = min(queued.ids)

        single = self._tick(limit=2, shard=0, shard_count=1)

        self.assertIn(
            oldest, single.ids,
            "the candidate who has waited longest is graded first, whatever "
            "`scoring_shards` is set to")
