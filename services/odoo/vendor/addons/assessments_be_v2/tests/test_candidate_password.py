"""The default password a candidate account is provisioned with.

WHY THIS IS TESTED AT ALL. Upstream creates a candidate's portal user with no
`password` key, so the column is NULL and the account cannot authenticate by
password at all - the only way in was the signup link mailed by
`_deliver_invitation`. Seeding a known password makes the account usable the
moment it is assigned to a launched assessment, and that is the feature.

The seeding is guarded so it can only ever reach an account nobody has been
able to sign into: never an account with a password, never one that has been
used, never a staff account. Those guards are the entire safety argument for
handing out a shared, published default, so they are what these tests pin -
particularly `test_a_password_of_their_own_is_never_overwritten`, whose failure
mode is silent and severe: a candidate who changed their password would be put
back on the shared default the next time anything touched their applicant, and
nothing anywhere would say so.

TransactionCase rather than HttpCase, matching test_api_invariants: the
assertions are about the model the launch button delegates to, not about
transport.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.models.assessment_api import (
    CANDIDATE_PASSWORD_ENABLED_PARAM, CANDIDATE_PASSWORD_PARAM,
    DEFAULT_CANDIDATE_PASSWORD,
)


@tagged("-at_install", "post_install")
class TestCandidateDefaultPassword(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Assessment = self.env["assessments.be"]
        self.Applicant = self.env["hr.applicant"]
        self.Generator = self.env["assessments.be.prompt"]
        self.Question = self.env["assessments.be.question"]
        self.QDim = self.env["assessments.be.question.dimension"]
        self.Users = self.env["res.users"]

    # ------------------------------------------------------------------
    # Fixtures
    # ------------------------------------------------------------------
    def _email(self, slug="candidate"):
        return "%s_%s@example.com" % (slug, uuid4().hex[:8])

    def _bare_applicant(self, name="Asha Rao"):
        """An applicant with an email and NO portal user yet.

        The whole point: provisioning has to CREATE the user, which is the only
        path on which a password is seeded.
        """
        return self.Applicant.create({
            "partner_name": name,
            "email_from": self._email(name.split()[0].lower()),
        })

    def _mcq(self, generator, name):
        """An objective question with a real key, so launch is not blocked."""
        question = self.Question.create({
            "name": name,
            "question_type": "mcq",
            "prompt": "Pick the right one",
            "difficulty": "easy",
            "generator_id": generator.id,
        })
        self.QDim.create({
            "question_id": question.id,
            "name": "Dim %s" % name,
            "option_line_ids": [
                (0, 0, {"name": n, "sequence": i * 10, "is_correct": i == 0})
                for i, n in enumerate(("A", "B", "C"))
            ],
        })
        return question

    def _launchable(self, applicants):
        """A draft assessment that `action_start` will accept."""
        generator = self.Generator.create({"name": "Gen %s" % uuid4().hex[:6]})
        self._mcq(generator, "Q1")
        self._mcq(generator, "Q2")
        return self.Assessment.create({
            "name": "Launch %s" % uuid4().hex[:6],
            "generator_id": generator.id,
            "question_limit": 2,
            "duration_minutes": 30,
            "evaluator_ids": [(6, 0, applicants.ids)],
        })

    def _portal_user(self, email=None):
        """A portal user with no password, the way upstream provisions one."""
        portal = self.env.ref("base.group_portal")
        email = email or self._email()
        return self.Users.with_context(no_reset_password=True).create({
            "name": "Portal %s" % email,
            "login": email,
            "email": email,
            "group_ids": [(6, 0, [portal.id])],
        })

    # ------------------------------------------------------------------
    # Assertions about a password we cannot read back
    # ------------------------------------------------------------------
    def _hash(self, user):
        """The stored hash, read over SQL.

        `user.password` computes to '' for everybody - see
        `_candidate_has_password` - so an ORM read cannot tell an account with
        a password from one without, which is the exact distinction under test.
        """
        self.env.flush_all()
        self.env.cr.execute(
            "SELECT password FROM res_users WHERE id = %s", (user.id,))
        row = self.env.cr.fetchone()
        return (row[0] if row else None) or ""

    def _accepts(self, user, plaintext):
        """True when ``plaintext`` would actually sign this account in."""
        hashed = self._hash(user)
        if not hashed:
            return False
        valid, _ = user._crypt_context().verify_and_update(plaintext, hashed)
        return bool(valid)

    def _mark_signed_in(self, user):
        """Give the account a login history, the way a real sign-in does.

        `login_date` is `related='log_ids.create_date'`, so it cannot be set
        directly on a user with no log rows - `_update_last_login` creates one,
        and this does the same thing.
        """
        self.env["res.users.log"].with_user(user).sudo().create({})
        user.invalidate_recordset(["login_date"])

    # ------------------------------------------------------------------
    # The feature
    # ------------------------------------------------------------------
    def test_launching_gives_a_new_candidate_an_account_they_can_sign_into(self):
        """The headline case, driven through the real launch button."""
        applicant = self._bare_applicant()
        assessment = self._launchable(applicant)

        assessment.action_start()

        user = applicant.be_candidate_user_id
        self.assertTrue(
            user, "launching must provision a portal user for the candidate")
        self.assertTrue(
            self._accepts(user, DEFAULT_CANDIDATE_PASSWORD),
            "a candidate assigned to a launched assessment must be able to "
            "sign in; without a seeded password the account has no usable "
            "credential at all and depends entirely on an invitation email")

    def test_a_password_of_their_own_is_never_overwritten(self):
        """A second launch must not put a candidate back on the default.

        The severe one. `_ensure_candidate_user` runs on EVERY launch,
        including for candidates who already have accounts, so without the
        `_candidate_has_password` guard a candidate who had changed their
        password would be silently reset to a shared, published value - and
        the only trace would be that their own password stopped working.
        """
        applicant = self._bare_applicant()
        self._launchable(applicant).action_start()
        user = applicant.be_candidate_user_id
        user.sudo().write({"password": "TheirOwnPassw0rd"})

        # Assigned to a second assessment and launched again.
        self._launchable(applicant).action_start()

        self.assertTrue(
            self._accepts(user, "TheirOwnPassw0rd"),
            "the candidate's own password must survive a later launch")
        self.assertFalse(
            self._accepts(user, DEFAULT_CANDIDATE_PASSWORD),
            "the shared default must not be restored over a real password")

    def test_an_account_that_has_been_signed_into_is_left_alone(self):
        """Never hand a known password to an account already in use.

        A user with a login history but no password hash is not this feature's
        candidate - it is somebody whose credential lives elsewhere - and
        seeding one would be granting access, not restoring it.
        """
        user = self._portal_user()
        applicant = self.Applicant.create({
            "partner_name": "Returning",
            "email_from": user.login,
            "be_candidate_user_id": user.id,
        })
        self._mark_signed_in(user)
        self.assertTrue(user.login_date, "fixture must record a login")

        self.Assessment._ensure_candidate_user(applicant)

        self.assertEqual(
            self._hash(user), "",
            "an account that has been used must not be given a default "
            "password behind its owner's back")

    def test_a_staff_account_is_never_seeded(self):
        """An internal user keeps whatever credential it has.

        Staff ARE bound to their applicant now - an employee sitting an
        assessment is an ordinary case, and refusing the bind is what made the
        exam gate reject them. That makes this test load-bearing rather than
        defensive: seeding is refused on the account's own type, one level
        below the bind, so widening who gets bound cannot widen who gets a
        password. Handing an internal login a published password is the worst
        outcome in this file.
        """
        staff = self.Users.with_context(no_reset_password=True).create({
            "name": "Staff",
            "login": self._email("staff"),
            "group_ids": [(6, 0, [self.env.ref("base.group_user").id])],
        })
        applicant = self.Applicant.create({
            "partner_name": "Staff",
            "email_from": staff.login,
            "be_candidate_user_id": staff.id,
        })

        self.Assessment._ensure_candidate_user(applicant)

        self.assertEqual(
            self._hash(staff), "",
            "an internal user must never be given the candidate default")

    def test_binding_a_staff_account_still_never_seeds_a_password(self):
        """The same invariant, reached the way production now reaches it.

        `test_a_staff_account_is_never_seeded` pre-sets the bind, so
        provisioning returns "exists" and the seeding guard is never reached -
        it could be deleted with a green suite. Now that staff are bound by
        the normal path, this drives that path: bind happens, password does
        not.
        """
        staff = self.Users.with_context(no_reset_password=True).create({
            "name": "Staff",
            "login": self._email("staff"),
            "group_ids": [(6, 0, [self.env.ref("base.group_user").id])],
        })
        applicant = self.Applicant.create({
            "partner_name": "Staff",
            "email_from": staff.login,
        })

        result = self.Assessment._ensure_candidate_user(applicant)

        self.assertEqual(result, "linked")
        self.assertEqual(
            applicant.be_candidate_user_id, staff,
            "an employee candidate must be bound, or the exam gate refuses "
            "the person the invitation named")
        self.assertEqual(
            self._hash(staff), "",
            "binding a staff account must not hand it the published default")

    def test_seeding_refuses_an_account_it_did_not_create(self):
        """Pinned at the guard, not at the call site.

        The rule used to be "never an internal user", which protected staff by
        protecting a TYPE. Candidate accounts are internal now, so the type no
        longer separates a person being onboarded from a colleague who happens
        to be sitting an exam. Ownership does, and it protects strictly more:
        a portal account somebody else set up is now left alone too, which the
        type test never covered.
        """
        staff = self.Users.with_context(no_reset_password=True).create({
            "name": "Staff Direct",
            "login": self._email("staff"),
            "group_ids": [(6, 0, [self.env.ref("base.group_user").id])],
        })

        self.Assessment._seed_candidate_password(staff)

        self.assertEqual(
            self._hash(staff), "",
            "an account this module did not create must never be handed the "
            "published default")

    def test_a_new_candidate_account_is_internal_and_can_sign_in(self):
        """The two halves of the change that have to hold together.

        Candidate accounts are internal users now. The seeding guard used to
        refuse internal users outright, so making the switch without moving
        that guard to an ownership test would have produced exactly the account
        nobody notices is broken: created fine, listed fine, and impossible to
        sign into because it has no password at all.
        """
        applicant = self._bare_applicant("Nadia Khan")

        result = self.Assessment._ensure_candidate_user(applicant)
        user = applicant.be_candidate_user_id

        self.assertEqual(result, "created")
        self.assertTrue(
            user._is_internal(),
            "a candidate account is an internal user, not a portal one")
        self.assertNotEqual(
            self._hash(user), "",
            "a brand new candidate must be able to sign in")

    def test_a_deployment_can_choose_its_own_default(self):
        self.env["ir.config_parameter"].sudo().set_param(
            CANDIDATE_PASSWORD_PARAM, "SomethingElse#9")
        applicant = self._bare_applicant()

        self._launchable(applicant).action_start()

        user = applicant.be_candidate_user_id
        self.assertTrue(self._accepts(user, "SomethingElse#9"))
        self.assertFalse(self._accepts(user, DEFAULT_CANDIDATE_PASSWORD))

    def test_the_switch_turns_seeding_off(self):
        """The opt-out, for a deployment that wants signup links only."""
        self.env["ir.config_parameter"].sudo().set_param(
            CANDIDATE_PASSWORD_ENABLED_PARAM, "0")
        applicant = self._bare_applicant()

        self._launchable(applicant).action_start()

        user = applicant.be_candidate_user_id
        self.assertTrue(user, "provisioning itself must still happen")
        self.assertEqual(
            self._hash(user), "",
            "seeding must be disablable without disabling provisioning")

    def test_clearing_the_password_parameter_does_not_disable_seeding(self):
        """"0" is the off switch; an empty password is not.

        Odoo's `get_param` is `self._get_param(key) or default`, so a stored
        empty string reads back as the default and an operator who cleared the
        field would believe they had turned the feature off while every new
        candidate kept getting the shared password. Pinned because the failure
        is silent and points the wrong way.
        """
        self.env["ir.config_parameter"].sudo().set_param(
            CANDIDATE_PASSWORD_PARAM, "")
        applicant = self._bare_applicant()

        self._launchable(applicant).action_start()

        self.assertTrue(
            self._accepts(
                applicant.be_candidate_user_id, DEFAULT_CANDIDATE_PASSWORD),
            "clearing the value falls back to the default, as Odoo's own "
            "parameter semantics require - use the switch to disable")

    def test_the_switch_defaults_to_on_when_nobody_has_set_it(self):
        """Every existing database is in this state."""
        self.env["ir.config_parameter"].sudo().search(
            [("key", "=", CANDIDATE_PASSWORD_ENABLED_PARAM)]).unlink()
        applicant = self._bare_applicant()

        self._launchable(applicant).action_start()

        self.assertTrue(
            self._accepts(
                applicant.be_candidate_user_id, DEFAULT_CANDIDATE_PASSWORD))

    def test_provisioning_still_reports_what_it_did(self):
        """The seeding must not change `_ensure_candidate_user`'s contract.

        Callers branch on the returned status - `action_import_candidates_csv`
        counts "created"/"linked"/"exists"/"skipped" into the message it shows
        the operator - so an override that swallowed or altered it would report
        a roster import wrongly.
        """
        applicant = self._bare_applicant()
        self.assertEqual(
            self.Assessment._ensure_candidate_user(applicant), "created")
        self.assertEqual(
            self.Assessment._ensure_candidate_user(applicant), "exists")
