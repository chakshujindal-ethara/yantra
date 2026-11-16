# -*- coding: utf-8 -*-
"""One refusal names EVERY candidate it refused, not just the first.

THE DEFECT THIS PINS, measured on production 2026-09-17. A 652-row roster was
imported for "Q7r + Grade & Fix Quality Sprint #3". 172 of those addresses
already belonged to portal accounts. `_sync_roster_rows` called
`_ensure_candidate_user` bare in a loop, so the FIRST of the 172 raised, the
transaction rolled back, and the operator was told about exactly one person:

    Khushi Arora cannot sit an assessment: the address
    khushi.arora2025@ethara.ai already belongs to a PORTAL account ...

Nothing imported. Fix that address, re-run, meet the next one - 172 round trips
to rediscover a list the very first run already held in memory. `action_start`
had the same bare call, so a roster that did import would then die one name at
a time at launch.

The refusal itself is correct and stays: a portal account is not converted into
a candidate automatically. What changes is that it is reported WHOLE.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.exceptions import UserError
from odoo.tests.common import TransactionCase, tagged
from odoo.tools import mute_logger

from ..constants import GROUP_CANDIDATE


@tagged("-at_install", "post_install")
class TestEveryBlockedCandidateIsNamedAtOnce(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Applicant = self.env["hr.applicant"].sudo()
        self.Users = self.env["res.users"].sudo()
        self.candidate_group = self.env.ref(GROUP_CANDIDATE)

    def _portal_applicant(self, name):
        address = "blocked_%s@example.com" % uuid4().hex[:8]
        self.Users.with_context(
            no_reset_password=True, mail_create_nosubscribe=True,
            mail_create_nolog=True, tracking_disable=True,
        ).create({
            "name": "Portal %s" % uuid4().hex[:6],
            "login": address,
            "group_ids": [(6, 0, [self.env.ref("base.group_portal").id])],
        })
        return address, self.Applicant.create(
            {"partner_name": name, "email_from": address})

    def _clean_applicant(self):
        return self.Applicant.create({
            "partner_name": "Fine Person",
            "email_from": "fine_%s@example.com" % uuid4().hex[:8],
        })

    def test_one_refusal_names_every_blocked_candidate(self):
        blocked = [self._portal_applicant("Blocked %d" % i) for i in range(3)]
        applicants = [a for _, a in blocked] + [self._clean_applicant()]

        with self.assertRaises(UserError) as caught:
            self.Assessment._be_provision_candidates(applicants)

        message = str(caught.exception)
        for address, _applicant in blocked:
            self.assertIn(
                address, message,
                "the refusal named only some of the blocked candidates - the "
                "operator has to re-run to discover the rest, which is the "
                "whole defect")
        for name in ("Blocked 0", "Blocked 1", "Blocked 2"):
            self.assertIn(name, message)
        self.assertIn("3 of 4", message, "the refusal does not state the scale")

    def test_a_cohort_with_no_portal_accounts_is_provisioned_silently(self):
        applicants = [self._clean_applicant() for _ in range(3)]

        self.Assessment._be_provision_candidates(applicants)

        for applicant in applicants:
            self.assertTrue(
                applicant.be_candidate_user_id,
                "a clean candidate was not provisioned")
            self.assertFalse(
                applicant.be_candidate_user_id.share,
                "a candidate provisioned by this platform must be internal")

    def test_nothing_is_provisioned_when_any_candidate_is_refused(self):
        """All-or-nothing, deliberately.

        A half-imported roster whose missing candidates cannot sign in is worse
        than a clean refusal: the assessment looks ready and the gap only
        surfaces when those people try to sit it.
        """
        _address, blocked = self._portal_applicant("Blocked Person")
        clean = self._clean_applicant()

        with self.assertRaises(UserError):
            self.Assessment._be_provision_candidates([clean, blocked])

        self.assertFalse(
            blocked.be_candidate_user_id,
            "the refused candidate was bound anyway")

    @mute_logger("odoo.addons.assessments_be_v2.models.assessment",
                 "odoo.sql_db")
    def test_one_database_error_does_not_blame_every_other_candidate(self):
        """THE REPORT-EVERYTHING LOOP HAD TO SURVIVE A DATABASE ERROR.

        Catching per candidate without a savepoint is the classic Odoo trap. A
        Python-level refusal is harmless, but a statement POSTGRES rejects - a
        deadlock, a serialization failure under the REPEATABLE READ this
        deployment runs, a constraint on the `res.users` create - aborts the
        whole transaction. Every ORM call in every later iteration then raises
        "current transaction is aborted", the handler catches that too, and
        each innocent candidate is appended to `blocked` carrying somebody
        else's error.

        So the very feature this method exists for - name all 172 at once
        instead of one per round trip - reported 651 fictitious refusals for
        one real one. One badly-timed row is worse than useless: it is a wrong
        list, and the operator cannot tell which name on it is the true cause.

        The failure is injected as real SQL rather than a Python exception
        because a Python exception does not reproduce it: only a statement the
        database refuses poisons the cursor, which is the whole point.
        """
        applicants = [self._clean_applicant() for _ in range(3)]
        doomed = applicants[0]
        Assessment = type(self.Assessment)
        provision = Assessment._ensure_candidate_user

        def _poison_the_cursor(model, applicant):
            if applicant.id == doomed.id:
                model.env.cr.execute("SELECT 1 / 0")
            return provision(model, applicant)

        with patch.object(Assessment, "_ensure_candidate_user",
                          _poison_the_cursor):
            with self.assertRaises(UserError) as caught:
                self.Assessment._be_provision_candidates(applicants)

        message = str(caught.exception)
        self.assertIn(
            "1 of 3", message,
            "one row failed; the refusal blamed the others for the aborted "
            "transaction its own failure caused")
        self.assertNotIn(
            "transaction is aborted", message,
            "the operator was handed Postgres' recovery message as though it "
            "were a candidate's problem")
