"""A Yantra person in Assessment v2: found by Keycloak subject, bound by verified email only, never a portal account
or one bound to someone else, and given the right v2 group."""

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.yantra_assess_bridge.models.res_users import IdentityConflict

SUB_A = "00000000-0000-4000-8000-0000000000a1"
SUB_B = "00000000-0000-4000-8000-0000000000b2"


@tagged("post_install", "-at_install")
class TestPeople(TransactionCase):
    def ensure(self, sub=SUB_A, email="asha@yantra.local", verified=True, name="Asha Rao", kind="worker"):
        return self.env["res.users"]._yantra_ensure_person(sub, email=email, verified=verified, name=name, kind=kind)

    def test_a_new_person_becomes_an_internal_candidate_with_an_applicant_and_no_password(self):
        user, applicant = self.ensure()
        self.assertEqual(user.login, "asha@yantra.local")
        self.assertEqual(user.yantra_keycloak_sub, SUB_A)
        self.assertFalse(user.share, "v2 takes internal users only")
        self.assertTrue(user.has_group("assessments_be_v2.group_assessment_candidate"))
        self.assertFalse(user.has_group("assessments_be_v2.group_assessment_manager"))
        self.assertEqual(applicant.be_candidate_user_id, user)
        self.env.cr.execute("SELECT COALESCE(password, '') FROM res_users WHERE id = %s", (user.id,))
        self.assertEqual(self.env.cr.fetchone()[0], "", "nobody gets a password")

    def test_the_subject_is_the_key_so_a_second_call_finds_the_same_person(self):
        first, applicant = self.ensure()
        again, applicant_again = self.ensure(name="Asha R.")
        self.assertEqual(first, again)
        self.assertEqual(applicant, applicant_again)
        self.assertEqual(again.name, "Asha R.")

    def test_an_unverified_email_never_binds_and_gets_an_unreachable_login(self):
        user, _ = self.ensure(email="someone@corp.example", verified=False)
        self.assertEqual(user.login, f"{SUB_A}@users.yantra.invalid")

    def test_a_verified_email_binds_an_existing_internal_account(self):
        existing = self.env["res.users"].with_context(no_reset_password=True).create(
            {"name": "Asha", "login": "asha@yantra.local", "email": "asha@yantra.local"}
        )
        user, _ = self.ensure()
        self.assertEqual(user, existing)
        self.assertEqual(existing.yantra_keycloak_sub, SUB_A)

    def test_a_portal_account_or_one_bound_to_someone_else_is_refused(self):
        self.env["res.users"].with_context(no_reset_password=True).create(
            {
                "name": "Portal",
                "login": "portal@yantra.local",
                "email": "portal@yantra.local",
                "group_ids": [(6, 0, [self.env.ref("base.group_portal").id])],
            }
        )
        with self.assertRaises(IdentityConflict) as e:
            self.ensure(email="portal@yantra.local")
        self.assertEqual(e.exception.code, "portal_account")
        self.ensure(sub=SUB_B, email="taken@yantra.local")
        with self.assertRaises(IdentityConflict) as e:
            self.ensure(sub=SUB_A, email="taken@yantra.local")
        self.assertEqual(e.exception.code, "identity_conflict")

    def test_a_verified_email_change_moves_the_login_but_never_onto_another_account(self):
        user, _ = self.ensure()
        moved, _ = self.ensure(email="asha.rao@yantra.local")
        self.assertEqual(moved, user)
        self.assertEqual(user.login, "asha.rao@yantra.local")
        self.ensure(sub=SUB_B, email="b@yantra.local")
        with self.assertRaises(IdentityConflict) as e:
            self.ensure(email="b@yantra.local")
        self.assertEqual(e.exception.code, "identity_conflict")

    def test_staff_are_v2_admins_and_a_bad_subject_is_refused(self):
        staff, _ = self.ensure(sub=SUB_B, email="ops1@yantra.local", kind="staff")
        self.assertTrue(staff.has_group("assessments_be_v2.group_assessment_manager"))
        with self.assertRaises(IdentityConflict) as e:
            self.ensure(sub="not a subject")
        self.assertEqual(e.exception.code, "invalid_subject")

    def test_an_archived_person_is_reactivated(self):
        user, _ = self.ensure()
        user.active = False
        again, _ = self.ensure()
        self.assertTrue(again.active)
