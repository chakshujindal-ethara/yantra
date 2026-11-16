"""The released count is reported, and reported from the server.

THE BUG THIS EXISTS FOR. Two separate readings of "how many are released"
were wrong at once, and both surfaced as the number 0 in front of an admin
who had just released real results:

  1. `POST /api/v1/assessments/<id>/release` answers `released_count`, and
     the Flutter toast read `d['released'] ?? d['count'] ?? 0`. Neither key
     exists, so the fallback fired on every success: "Released 0 result(s)".
  2. `assessment_row` sent `assigned_count`, `submitted_count` and
     `releasable_count` but NO released count, so the console counted it from
     the attempts it happened to hold. A row loaded from `/api/v1/assessments`
     carries no nested attempts, so a cold load of the list rendered
     "2/4 in - 0 released" beside submitted/assigned numbers that came from
     here. That is what made the state chip look like it contradicted the row.

Neither had a test. This pins the serializer contract - the key name AND the
number - so a rename on either side fails here rather than in a screenshot.

TransactionCase, not HttpCase, following the house style in
`test_api_invariants`: the assertion is about the payload the route builds,
not about transport.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.controllers.api import serializers as S


@tagged("-at_install", "post_install")
class TestReleasedCountContract(TransactionCase):
    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Evaluator = self.env["assessments.be.evaluator"]

    def _applicant(self, name):
        slug = "%s_%s" % (name.lower().replace(" ", "_"), uuid4().hex[:8])
        email = "%s@example.com" % slug
        return self.env["hr.applicant"].create({
            "partner_name": name,
            "email_from": email,
        })

    def _cohort(self, submitted=0, released=0, pending=0):
        """An assessment whose evaluators are in known states.

        `released` counts a SUBSET of `submitted`: releasing an attempt that
        was never submitted is not a state the product can reach.
        """
        assessment = self.Assessment.create({"name": "Rel %s" % uuid4().hex[:6]})
        made = []
        for i in range(submitted):
            ev = self.Evaluator.create({
                "assessment_id": assessment.id,
                "applicant_id": self._applicant("Sub %d" % i).id,
                "state": "submitted",
            })
            if i < released:
                ev.results_released = True
            made.append(ev)
        for i in range(pending):
            made.append(self.Evaluator.create({
                "assessment_id": assessment.id,
                "applicant_id": self._applicant("Pend %d" % i).id,
                "state": "pending",
            }))
        assessment.invalidate_recordset()
        return assessment

    def test_released_count_is_computed_from_submitted_and_released(self):
        a = self._cohort(submitted=4, released=3, pending=2)
        self.assertEqual(a.submitted_count, 4)
        self.assertEqual(a.released_count, 3)
        self.assertEqual(a.releasable_count, 1,
                         "releasable is the submitted rows NOT yet released")

    def test_released_and_releasable_partition_the_submitted_rows(self):
        """They must sum to submitted, or one of the two is double-counting."""
        a = self._cohort(submitted=5, released=2, pending=3)
        self.assertEqual(a.released_count + a.releasable_count,
                         a.submitted_count)

    def test_a_pending_candidate_is_never_counted_as_released(self):
        a = self._cohort(submitted=0, released=0, pending=4)
        self.assertEqual(a.released_count, 0)
        self.assertEqual(a.submitted_count, 0)

    def test_assessment_row_carries_released_count(self):
        """THE LIST-ROW CONTRACT.

        The console reads this key with a -1 "not sent" sentinel and falls
        back to counting local attempts. It holds none on this route, so an
        absent key here renders 0 released for every row.
        """
        a = self._cohort(submitted=4, released=3, pending=2)
        row = S.assessment_row(a)
        self.assertIn("released_count", row,
                      "the console cannot count this itself: a list row "
                      "carries no nested attempts")
        self.assertEqual(row["released_count"], 3)
        # Its neighbours, so a future edit cannot fix one by breaking another.
        self.assertEqual(row["submitted_count"], 4)
        self.assertEqual(row["releasable_count"], 1)
        self.assertEqual(row["assigned_count"], 6)

    def test_releasing_moves_a_row_from_releasable_to_released(self):
        a = self._cohort(submitted=3, released=0, pending=0)
        self.assertEqual(S.assessment_row(a)["released_count"], 0)
        self.assertEqual(S.assessment_row(a)["releasable_count"], 3)

        a.assessment_evaluator_ids.action_release_results()
        a.invalidate_recordset()

        row = S.assessment_row(a)
        self.assertEqual(row["released_count"], 3,
                         "the count the release toast reports must move")
        self.assertEqual(row["releasable_count"], 0)
