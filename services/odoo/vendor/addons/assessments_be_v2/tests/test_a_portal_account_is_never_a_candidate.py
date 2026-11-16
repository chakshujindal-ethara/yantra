# -*- coding: utf-8 -*-
"""A portal account cannot sit an assessment, and is never converted into one.

THE PRODUCT RULE: this platform is for internal users. A portal account has no
access to it. New candidates are provisioned as internal accounts, and an
existing portal account is NOT promoted to internal to make it fit - that changes
what the account costs (a paid Odoo seat) and hands it the back office, which is
a decision for a person and not for a launch.

THE CRASH THIS CLOSES. `_ensure_candidate_user` matched an account by email and
bound it with no check on what KIND of account it was. Binding wrote
`be_candidate_user_id` and then granted `group_assessment_candidate`, which
implies `base.group_user` - and `res.users._check_disjoint_groups` forbids being
both portal and internal. The constraint is an `@api.constrains` on `group_ids`,
so it fires at FLUSH, not at write: the failure surfaced later in the transaction
as

    ValidationError: The user cannot have more than one user types.

with no mention of this candidate, this address, or this assessment. Launching an
assessment for a candidate whose email happened to belong to an existing portal
contact simply 500'd, and nobody could act on the message.

THE TWO PATHS ARE DIFFERENT AND BOTH ARE PINNED HERE. Reaching a portal account
by EMAIL MATCH is refused loudly, because it happens before anything is written
and the operator can still fix it. An applicant ALREADY BOUND to a portal account
is a legacy shape - there are 70 of them on stage, 68 on @ethara.ai addresses -
and must not raise: those rows keep their attempts, `_be_grant_candidate_group`
declines to write the group, and the API gate refuses them until somebody
converts the account deliberately. A launch must not die for the whole cohort
because one historical row is shaped wrongly.
"""
from uuid import uuid4

from odoo.exceptions import UserError, ValidationError
from odoo.tests.common import TransactionCase, tagged

from ..constants import GROUP_CANDIDATE


@tagged("-at_install", "post_install")
class TestAPortalAccountIsNeverACandidate(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Applicant = self.env["hr.applicant"].sudo()
        self.Users = self.env["res.users"].sudo()
        self.candidate_group = self.env.ref(GROUP_CANDIDATE)

    # -- fixtures ---------------------------------------------------------

    def _address(self):
        return "conflict_%s@example.com" % uuid4().hex[:8]

    def _account(self, login, group_xmlid):
        return self.Users.with_context(
            no_reset_password=True, mail_create_nosubscribe=True,
            mail_create_nolog=True, tracking_disable=True,
        ).create({
            "name": "Existing %s" % uuid4().hex[:6],
            "login": login,
            "group_ids": [(6, 0, [self.env.ref(group_xmlid).id])],
        })

    def _applicant(self, email, name="Conflicted Person"):
        return self.Applicant.create({
            "partner_name": name,
            "email_from": email,
        })

    # -- group 1: the email-match path refuses, loudly --------------------

    def test_binding_a_portal_account_by_email_is_refused(self):
        address = self._address()
        portal = self._account(address, "base.group_portal")
        applicant = self._applicant(address)

        with self.assertRaises(UserError) as caught:
            self.Assessment._ensure_candidate_user(applicant)

        message = str(caught.exception)
        self.assertIn(
            address, message,
            "the refusal must name the ADDRESS - it is the only handle the "
            "operator has on the problem; got %r" % (message,))
        self.assertIn(
            "internal", message.lower(),
            "and it must say why: the platform is internal-only; got %r"
            % (message,))
        self.assertIn(
            portal.login, message,
            "and name the offending account; got %r" % (message,))

    def test_the_refusal_states_the_resolution(self):
        """A refusal an operator cannot act on is just an outage with prose."""
        address = self._address()
        self._account(address, "base.group_portal")
        applicant = self._applicant(address)

        with self.assertRaises(UserError) as caught:
            self.Assessment._ensure_candidate_user(applicant)

        message = str(caught.exception).lower()
        self.assertIn("different address", message)
        self.assertIn("convert", message)

    def test_nothing_is_written_when_the_bind_is_refused(self):
        """Refusing AFTER a partial write would leave the row half-bound."""
        address = self._address()
        portal = self._account(address, "base.group_portal")
        applicant = self._applicant(address)
        before = set(portal.group_ids.ids)

        with self.assertRaises(UserError):
            self.Assessment._ensure_candidate_user(applicant)

        self.assertFalse(
            applicant.be_candidate_user_id,
            "the applicant must not be bound to a portal account")
        portal.invalidate_recordset()
        self.assertEqual(
            set(portal.group_ids.ids), before,
            "no group may be written to a portal account")
        self.assertNotIn(self.candidate_group, portal.all_group_ids)

    def test_the_portal_account_is_not_converted(self):
        """THE EXPLICIT INSTRUCTION. Not promoted, not switched, not touched."""
        address = self._address()
        portal = self._account(address, "base.group_portal")
        applicant = self._applicant(address)

        with self.assertRaises(UserError):
            self.Assessment._ensure_candidate_user(applicant)

        portal.invalidate_recordset()
        self.assertFalse(
            portal._is_internal(),
            "a portal account must still be a portal account afterwards")
        self.assertTrue(
            portal.has_group("base.group_portal"),
            "and must keep the group it had")

    def test_a_launch_refuses_rather_than_half_provisioning_a_cohort(self):
        """The real symptom: one badly-shaped address used to 500 the launch.

        It still stops the launch - that is correct, and it is what the operator
        needs to know before anybody is emailed - but now it says which person
        and which address, and the transaction is clean.
        """
        address = self._address()
        self._account(address, "base.group_portal")
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % uuid4().hex[:6]})
        question = self.env["assessments.be.question"].create({
            "name": "Q %s" % uuid4().hex[:6],
            "question_type": "mcq",
            "prompt": "Pick one.",
            "generator_id": generator.id,
        })
        self.env["assessments.be.question.dimension"].create({
            "question_id": question.id,
            "name": "Answer",
            "option_line_ids": [
                (0, 0, {"name": n, "sequence": i * 10, "is_correct": i == 0})
                for i, n in enumerate(("Alpha", "Bravo"))],
        })
        assessment = self.Assessment.create({
            "name": "Launch %s" % uuid4().hex[:6],
            "generator_id": generator.id,
            "duration_minutes": 30,
            "evaluator_ids": [(6, 0, [self._applicant(address).id])],
        })

        with self.assertRaises(UserError) as caught:
            assessment.action_start()

        self.assertIn(address, str(caught.exception))

    # -- group 2: an internal account is still bound normally --------------

    def test_an_internal_account_at_the_same_address_still_binds(self):
        """Guard the guard. If the check refused everything, the tests above
        would be proving nothing about portal accounts."""
        address = self._address()
        staff = self._account(address, "base.group_user")
        applicant = self._applicant(address)

        result = self.Assessment._ensure_candidate_user(applicant)

        self.assertEqual(result, "linked")
        self.assertEqual(applicant.be_candidate_user_id, staff)
        staff.invalidate_recordset()
        self.assertIn(
            self.candidate_group, staff.all_group_ids,
            "an internal account bound as a candidate gets the group")

    def test_a_brand_new_candidate_is_created_internal(self):
        """New candidates are internal accounts, by construction."""
        applicant = self._applicant(self._address(), name="Brand New")

        result = self.Assessment._ensure_candidate_user(applicant)
        user = applicant.be_candidate_user_id

        self.assertEqual(result, "created")
        self.assertTrue(
            user._is_internal(),
            "this platform provisions candidates as INTERNAL users")
        self.assertFalse(user.has_group("base.group_portal"))

    # -- group 3: a legacy portal bind must not break a launch -------------

    def test_an_already_bound_portal_account_does_not_raise(self):
        """The 70 rows on stage. They keep their bind and their attempts.

        Raising here would mean a launch dies for the whole cohort because one
        historical row is shaped wrongly - and there is nothing the operator
        could do inside that launch to fix it.
        """
        address = self._address()
        portal = self._account(address, "base.group_portal")
        applicant = self._applicant(address)
        # Bound directly, bypassing the guard, exactly as the legacy data is.
        applicant.write({"be_candidate_user_id": portal.id})

        self.assertEqual(
            self.Assessment._ensure_candidate_user(applicant), "exists",
            "the status callers branch on must not change")

    def test_the_group_is_still_not_written_to_a_legacy_portal_bind(self):
        """Not raising must not mean granting: the flush would fail instead."""
        address = self._address()
        portal = self._account(address, "base.group_portal")
        applicant = self._applicant(address)
        applicant.write({"be_candidate_user_id": portal.id})

        self.Assessment._ensure_candidate_user(applicant)
        # The constraint is deferred, so nothing above proves anything until the
        # transaction is flushed.
        self.env.flush_all()

        portal.invalidate_recordset()
        self.assertNotIn(self.candidate_group, portal.all_group_ids)
        self.assertFalse(portal._is_internal())

    def test_a_legacy_portal_bind_survives_a_flush(self):
        """Stated as its own case because the failure mode is a DEFERRED raise.

        A `try/except` around the group write would not have caught it, and a
        test that never flushes cannot see it.
        """
        address = self._address()
        portal = self._account(address, "base.group_portal")
        applicant = self._applicant(address)
        applicant.write({"be_candidate_user_id": portal.id})

        try:
            self.Assessment._ensure_candidate_user(applicant)
            self.env.flush_all()
        except ValidationError as exc:
            self.fail(
                "provisioning a legacy portal bind raised at flush: %s" % exc)
