"""D1 - the manual flag belongs to ONE SITTING and does not follow the person.

The design decision this pins: the flag is a real stored column on
`assessments.be.evaluator`, not a related onto `hr.applicant`. The property
that matters is not "the field exists" but the INVERSE of the obvious one - a
concern raised while reviewing assessment 58 must NOT make the same person
arrive pre-suspected on assessment 60. A related field, a compute off the
applicant, or any copy-on-create would all define fine and fail exactly that.

Asserted directly rather than inferred from the field definition, because the
failure it prevents is silent: nothing errors when a flag bleeds across
attempts, a reviewer simply sees a red badge on a paper nobody complained
about and treats it as evidence.

The second property is that it is FILTERABLE server-side. The roster route
pages under a 200-row clamp, so a flag the client has to filter for itself is
the same defect (C2) the search work exists to remove.

The third is that flag and remark are INDEPENDENT: either can stand without
the other, so a note can be left without an accusation and a flag can be
raised without anybody being made to write a sentence first.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class _Cohort(TransactionCase):
    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.Generator = self.env["assessments.be.prompt"]
        self.Applicant = self.env["hr.applicant"]

    def _assessment(self, name="A"):
        gen = self.Generator.create({"name": "Gen %s" % uuid4().hex[:6]})
        return self.Assessment.create({
            "name": "%s %s" % (name, uuid4().hex[:6]),
            "generator_id": gen.id,
        })

    def _applicant(self, name):
        slug = "%s_%s" % (name.lower().replace(" ", "_"), uuid4().hex[:8])
        return self.Applicant.create({
            "partner_name": name,
            "email_from": "%s@example.com" % slug,
        })

    def _sit(self, assessment, applicant):
        return self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        })


class TestTheFlagStaysOnTheSittingItWasRaisedOn(_Cohort):

    def test_flagging_one_attempt_leaves_the_persons_other_attempts_clean(self):
        """THE reason D1 is attempt-level. Two assessments, one person."""
        a58, a60 = self._assessment("Q7r"), self._assessment("IG Entity")
        person = self._applicant("Aahan Trikha")
        on58, on60 = self._sit(a58, person), self._sit(a60, person)

        self.assertFalse(on58.manual_flagged)
        self.assertFalse(on60.manual_flagged)

        on58.write({"manual_flagged": True,
                    "manual_remark": "Impersonation suspected"})

        self.assertTrue(
            on58.manual_flagged,
            "the sitting the concern was raised on must carry it")
        on60.invalidate_recordset()
        self.assertFalse(
            on60.manual_flagged,
            "and the SAME PERSON on another assessment must not - a concern "
            "about one paper is not evidence about the next one they sit")
        self.assertFalse(
            on60.manual_remark,
            "the remark is about that sitting too, and must not be readable "
            "from an unrelated attempt")

    def test_the_remark_is_per_sitting_as_well(self):
        a58, a60 = self._assessment(), self._assessment()
        person = self._applicant("Two Papers")
        on58, on60 = self._sit(a58, person), self._sit(a60, person)

        on58.write({"manual_remark": "Left the room at 14:03."})
        on60.write({"manual_remark": "Sat the whole paper without incident."})

        self.assertEqual(on58.manual_remark, "Left the room at 14:03.")
        self.assertEqual(
            on60.manual_remark, "Sat the whole paper without incident.",
            "two sittings must be able to say two different things; a shared "
            "field would make the second write overwrite the first")

    def test_clearing_one_attempt_leaves_the_other_flagged(self):
        a58, a60 = self._assessment(), self._assessment()
        person = self._applicant("Jaahanvi")
        on58, on60 = self._sit(a58, person), self._sit(a60, person)
        on58.write({"manual_flagged": True})
        on60.write({"manual_flagged": True})

        on58.write({"manual_flagged": False})
        self.assertFalse(on58.manual_flagged)
        on60.invalidate_recordset()
        self.assertTrue(
            on60.manual_flagged,
            "withdrawing a concern about one paper must not silently withdraw "
            "a separate concern about another")

    def test_a_new_attempt_starts_clean_however_flagged_the_person_is(self):
        """The person's earlier paper is flagged, THEN they sit something new."""
        person = self._applicant("Late Arrival")
        old = self._sit(self._assessment(), person)
        old.write({"manual_flagged": True, "manual_remark": "prior concern"})

        fresh = self._sit(self._assessment(), person)
        self.assertFalse(
            fresh.manual_flagged,
            "an attempt created after an earlier flag must start clean, or "
            "the annotation would follow the person for ever with no way to "
            "say it was about the other sitting")
        self.assertFalse(fresh.manual_remark)

    def test_one_person_flagged_does_not_flag_the_cohort(self):
        a = self._assessment()
        flagged = self._sit(a, self._applicant("Flagged One"))
        clean = [self._sit(a, self._applicant("Clean %d" % i))
                 for i in range(3)]
        flagged.write({"manual_flagged": True})

        self.assertTrue(flagged.manual_flagged)
        for ev in clean:
            self.assertFalse(
                ev.manual_flagged,
                "a flag must not bleed across the cohort")

    def test_a_copied_attempt_carries_no_flag(self):
        """`copy=False` on all four, asserted rather than trusted.

        Duplicating an attempt is how the same person gets put onto a second
        paper, and a duplicate that arrived already flagged and already
        annotated would be the person-level bleed reintroduced through the
        back door.

        Copied ONTO ANOTHER ASSESSMENT, because a plain `copy()` trips the
        `(assessment_id, applicant_id)` uniqueness constraint - which is itself
        the reason a duplicate is always a different sitting.
        """
        ev = self._sit(self._assessment(), self._applicant("Duplicated"))
        ev.write({"manual_flagged": True, "manual_remark": "the original"})

        clone = ev.copy({"assessment_id": self._assessment().id})
        self.assertFalse(clone.manual_flagged)
        self.assertFalse(clone.manual_remark)
        self.assertFalse(clone.manual_flagged_by_id)
        self.assertFalse(clone.manual_flagged_at)


class TestTheFlagAndTheRemarkAreIndependent(_Cohort):
    """Two features that share a route, not one feature with two halves."""

    def test_a_remark_can_stand_with_no_flag(self):
        ev = self._sit(self._assessment(), self._applicant("Noted"))
        ev.write({"manual_remark": "Asked for a re-read of Q4."})

        self.assertFalse(
            ev.manual_flagged,
            "writing a note must not raise a flag - most notes are not "
            "accusations")
        self.assertEqual(ev.manual_remark, "Asked for a re-read of Q4.")

    def test_a_flag_can_stand_with_no_remark(self):
        ev = self._sit(self._assessment(), self._applicant("Bare"))
        ev.write({"manual_flagged": True})

        self.assertTrue(ev.manual_flagged)
        self.assertFalse(
            ev.manual_remark,
            "the flag carries no reason text of its own; demanding one is "
            "what leaves stale flags standing because nobody could phrase it")


class TestTheAdminPayloadShape(_Cohort):
    """What `candidate_flag_block` promises its two callers.

    Serializer-level rather than over HTTP, because the shape is the contract
    the console renders against and a route test would only exercise the one
    state the route happened to leave behind.
    """

    def setUp(self):
        super().setUp()
        from ..controllers.api import serializers as S
        self.S = S

    def test_an_untouched_attempt_reports_the_two_keys_and_stops(self):
        ev = self._sit(self._assessment(), self._applicant("Untouched"))
        self.assertEqual(
            self.S.candidate_flag_block(ev), {"flagged": False, "remark": ""},
            "provenance keys describe an act that never happened here, and "
            "empty ones invite a console to render 'Raised by  on '")

    def test_a_remark_with_no_flag_still_reports_the_remark(self):
        ev = self._sit(self._assessment(), self._applicant("Noted"))
        ev.write({"manual_remark": "Reported a crash at 11:20."})

        block = self.S.candidate_flag_block(ev)
        self.assertFalse(block["flagged"])
        self.assertEqual(
            block["remark"], "Reported a crash at 11:20.",
            "a note must not become invisible because nobody flagged the "
            "sitting it is about")

    def test_the_admin_row_carries_the_flag_beside_the_advisory_ones(self):
        ev = self._sit(self._assessment(), self._applicant("Rowed"))
        ev.write({"manual_flagged": True, "manual_remark": "why"})

        row = self.S.evaluator_admin_row(ev)
        self.assertTrue(row["flags"]["manual_flagged"])
        self.assertEqual(row["candidate_flag"]["remark"], "why")
        # BESIDE, never inside: the three machine signals keep their own
        # meaning, which is what `flagged_only` still selects.
        for key in ("integrity_alert", "score_outlier"):
            self.assertIn(key, row["flags"])

    def test_the_leaderboard_row_carries_no_flag_at_all(self):
        """It aggregates one person ACROSS assessments, where a per-sitting
        flag has no honest value - see the note in `leaderboard_row`."""
        person = self._applicant("Ranked")
        ev = self._sit(self._assessment(), person)
        ev.write({"manual_flagged": True, "manual_remark": "on one paper"})

        row = self.S.leaderboard_row(1, person, 1, 50.0, 50.0, 0)
        for key in ("candidate_flag", "candidate_flagged", "manual_flagged",
                    "manual_remark", "flagged", "remark"):
            self.assertNotIn(
                key, row,
                "%r on a cross-assessment row would read as an accusation "
                "about every paper the person sat" % key)


class TestTheFlagIsFilterableOnTheServer(_Cohort):
    """STORED, so the roster can narrow to it inside the 200-row clamp."""

    def test_the_field_is_a_real_column(self):
        field = self.Evaluator._fields["manual_flagged"]
        self.assertTrue(
            field.store,
            "an unstored or computed flag cannot be searched without a join "
            "the ORM will not push down, so the roster could not filter it")
        self.assertFalse(
            field.related,
            "a related would put one value behind every attempt the person "
            "has sat, which is the exact bleed this design removes")
        self.assertFalse(
            field.readonly,
            "it is written on the attempt itself, so the form can edit it")

    def test_a_search_domain_selects_only_the_flagged_rows(self):
        a = self._assessment()
        flagged = self._sit(a, self._applicant("Picked"))
        others = [self._sit(a, self._applicant("Other %d" % i))
                  for i in range(4)]
        flagged.write({"manual_flagged": True})

        found = self.Evaluator.search([
            ("assessment_id", "=", a.id), ("manual_flagged", "=", True)])
        self.assertEqual(
            found, flagged,
            "the domain must return exactly the flagged attempt")

        rest = self.Evaluator.search([
            ("assessment_id", "=", a.id), ("manual_flagged", "=", False)])
        self.assertEqual(set(rest.ids), {ev.id for ev in others})

    def test_search_count_is_honest_about_it(self):
        """`search_count` is what the roster's `total` comes from."""
        a = self._assessment()
        evs = [self._sit(a, self._applicant("P%d" % i)) for i in range(5)]
        for ev in evs[:2]:
            ev.write({"manual_flagged": True})

        self.assertEqual(
            self.Evaluator.search_count([
                ("assessment_id", "=", a.id),
                ("manual_flagged", "=", True)]), 2)


class TestTheAdvisoryFlagsAreUntouched(_Cohort):
    """Requirement 3.6 - the three machine flags keep computing on their own."""

    def test_a_manual_flag_changes_none_of_them(self):
        a = self._assessment()
        ev = self._sit(a, self._applicant("Independent"))
        before = (ev.integrity_alert, ev.score_outlier, ev.scoring_error_flag)

        ev.write({"manual_flagged": True, "manual_remark": "r"})
        ev.invalidate_recordset()

        self.assertEqual(
            (ev.integrity_alert, ev.score_outlier, ev.scoring_error_flag),
            before,
            "the manual flag is advisory and independent; it must not move "
            "any computed flag")
        self.assertTrue(ev.manual_flagged)


class TestManualAndAdvisoryFiltersStaySeparate(_Cohort):
    """Requirement 3.6 - `flagged_only` keeps meaning what it means today.

    The API builds `flagged_only` as an OR over the three AUTOMATIC advisory
    flags. Folding D1's manual flag into that chain would have been one line
    and would have silently widened every existing review-queue call; these
    assert the two predicates over the same cohort instead of trusting that
    nobody does it later.
    """

    def _domain_manual(self, assessment):
        return [("assessment_id", "=", assessment.id),
                ("manual_flagged", "=", True)]

    def _domain_advisory(self, assessment):
        return [("assessment_id", "=", assessment.id),
                "|", "|",
                ("integrity_alert", "=", True),
                ("score_outlier", "=", True),
                ("scoring_error_flag", "!=", False)]

    def test_a_manual_flag_never_enters_the_advisory_queue(self):
        a = self._assessment()
        manual = self._sit(a, self._applicant("Manually Flagged"))
        self._sit(a, self._applicant("Untouched"))
        manual.write({"manual_flagged": True,
                      "manual_remark": "operator concern"})

        advisory = self.Evaluator.search(self._domain_advisory(a))
        self.assertNotIn(
            manual, advisory,
            "an attempt an operator flagged by hand has tripped no machine "
            "signal, so the review queue must not grow by one")

        self.assertEqual(self.Evaluator.search(self._domain_manual(a)), manual)

    def test_the_two_can_be_intersected(self):
        """Both filters together is a question a reviewer actually asks."""
        a = self._assessment()
        both = self._sit(a, self._applicant("Both"))
        manual_only = self._sit(a, self._applicant("Manual Only"))
        both.write({"manual_flagged": True})
        manual_only.write({"manual_flagged": True})
        # An advisory signal on one of them, set the way the model computes it.
        both.write({"score_outlier": True})

        found = self.Evaluator.search(
            self._domain_manual(a) + self._domain_advisory(a)[1:])
        self.assertEqual(
            found, both,
            "AND-ing the two must select the attempt carrying both, and not "
            "the one carrying only a manual flag")
