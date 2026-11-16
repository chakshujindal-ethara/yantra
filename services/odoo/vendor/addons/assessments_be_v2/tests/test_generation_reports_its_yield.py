"""A paid run that produces nothing must not report success.

THE DEFECT. `_finalize_sop_gen_state` was a format string over `draft_count`
with no branch for zero, and `generate_questions_from_sop` returned a bare list.
So "the SOP yielded nothing", "five items came back and every one was thrown
out" and "five items came back and five were created" were the same event to
every layer above. An examiner ran generation, was charged, got an empty review
queue, a green "Done" pill and the words "Nothing generated yet" - and the
reasons existed only inside a `_logger.warning` on the server.

These tests pin the report, not the wording: what matters is that a zero-yield
run is recorded as a failure carrying its reason.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestGenerationReportsItsYield(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Prompt = self.env["assessments.be.prompt"]
        self.generator = self.Prompt.create(
            {"name": "Report %s" % uuid4().hex[:6]})

    def _finalize(self, draft_count, report):
        """The vals a finished run writes, applied to a real record.

        `_finalize_sop_gen_state` commits, and a TransactionCase forbids that -
        so the DECISION lives in `_sop_gen_result_vals` and this exercises that,
        then writes it. The assertions still read a real record with real field
        constraints: the Selection rejects a bogus state, the Char truncates.
        """
        self.generator.write(
            self.Prompt._sop_gen_result_vals(
                draft_count, report, self.generator))
        return self.generator

    # ------------------------------------------------------------------
    def test_everything_rejected_is_recorded_as_a_failure(self):
        """The reported incident: 5 items in, 5 rejected, 0 drafts, "Done"."""
        gen = self._finalize(0, {
            "returned": 5, "created": 0, "rejected": 5,
            "reasons": ["image_ab: construction_keys must include an Overall "
                        "Choice (OC) dimension (x5)"]})

        self.assertEqual(
            gen.sop_gen_state, "failed",
            "a run that spent money and created nothing reported 'done'")
        self.assertIn("Overall Choice", gen.sop_gen_error)
        self.assertIn(
            "5", gen.sop_gen_error,
            "the count is the first thing an examiner needs: was anything "
            "generated at all, or was it all thrown away")

    def test_a_partial_run_stays_done_but_says_what_it_dropped(self):
        gen = self._finalize(3, {
            "returned": 5, "created": 3, "rejected": 2,
            "reasons": ["mcq: mcq needs >=2 options (x2)"]})

        self.assertEqual(gen.sop_gen_state, "done")
        self.assertFalse(
            gen.sop_gen_error,
            "three usable drafts is not a failed run")
        self.assertIn("2", gen.sop_gen_report)
        self.assertIn("mcq", gen.sop_gen_report)

    def test_a_clean_run_reports_plainly_and_carries_no_error(self):
        gen = self._finalize(5, {
            "returned": 5, "created": 5, "rejected": 0, "reasons": []})

        self.assertEqual(gen.sop_gen_state, "done")
        self.assertFalse(gen.sop_gen_error)
        self.assertIn("5", gen.sop_gen_report)

    def test_an_empty_run_is_reported_as_a_failure(self):
        """EXPECTATION DELIBERATELY REVERSED.

        This used to assert that zero drafts with nothing rejected was a
        "thin SOP, not a defect", and stay `done`. That reading is what let the
        real incident look green: the producer hardcodes `"rejected": 0`, so
        the failure branch keyed on `rejected` could never fire, and EVERY
        empty run - unparseable response, truncated JSON, model returning an
        empty array - landed in this branch and reported success.

        An examiner who asked for ten questions and received none has had a
        failed run, whatever the cause. Reporting that plainly is what lets
        them retry; reporting "Done" is what sent them to the server logs.
        """
        gen = self._finalize(0, {
            "returned": 0, "created": 0, "rejected": 0, "reasons": []})

        self.assertEqual(gen.sop_gen_state, "failed")
        self.assertTrue(gen.sop_gen_error)
        self.assertNotEqual(
            gen.state, "done",
            "the stage bar is read before anything else; Done over an empty "
            "drafts list is the claim that misled")

    def test_an_unreadable_response_says_so_instead_of_reporting_done(self):
        """The shape the producer now emits when nothing parsed.

        `rejected` is 0 because nothing got far enough to be rejected - which
        is exactly why the old `and rejected` guard never fired.
        """
        gen = self._finalize(0, {
            "returned": 0, "created": 0, "rejected": 0, "no_items": True,
            "reasons": ["Could not parse JSON array from LLM response: "
                        "{\"metadata\": {\"mapping\": [..."]})

        self.assertEqual(gen.sop_gen_state, "failed")
        self.assertIn("parse", gen.sop_gen_error)

    def test_a_failed_run_falls_back_to_a_state_it_can_retry_from(self):
        """Tags were extracted, so the honest resting state is skills_ready."""
        self.generator.tag_extract_state = "done"

        gen = self._finalize(0, {"returned": 0, "created": 0, "rejected": 0,
                                 "reasons": []})

        self.assertEqual(gen.state, "skills_ready")

    def test_the_previous_runs_verdict_never_survives_the_next(self):
        self._finalize(0, {"returned": 5, "created": 0, "rejected": 5,
                           "reasons": ["image_ab: no OC (x5)"]})
        gen = self._finalize(4, {"returned": 4, "created": 4, "rejected": 0,
                                 "reasons": []})

        self.assertEqual(gen.sop_gen_state, "done")
        self.assertFalse(
            gen.sop_gen_error,
            "a stale error over a good run is worse than no error at all")
        self.assertNotIn("OC", gen.sop_gen_report)

    # ------------------------------------------------------------------
    def test_the_reason_summary_counts_repeats_instead_of_listing_them(self):
        """Five items failing one way is ONE fact. Printed five times it is
        noise, and the field it has to fit in is a Char."""
        from odoo.addons.assessments_be_v2.services.vertex import (
            _summarize_rejections)

        out = _summarize_rejections([
            ("image_ab", "needs OC"), ("image_ab", "needs OC"),
            ("image_ab", "needs OC"), ("mcq", "needs >=2 options")])

        self.assertEqual(out, ["image_ab: needs OC (x3)",
                               "mcq: needs >=2 options"])
