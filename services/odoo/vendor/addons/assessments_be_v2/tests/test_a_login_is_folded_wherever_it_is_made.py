# -*- coding: utf-8 -*-
"""An email-shaped login is stored lower-case, whoever creates the account.

ODOO'S LOGIN LOOKUP IS CASE-SENSITIVE. A candidate provisioned as
`Asha.Rao@Corp.com` cannot sign in by typing `asha.rao@corp.com`, and nothing
about the account looks wrong from the admin side - it exists, it is active, the
password is right. The candidate is told their credentials are incorrect,
forever, and the only route the message suggests is "Forgot password", which
cannot help.

WHY THE FIX IS ON `create` AND NOT ON THE WRITER. `etp_assessment_pro` builds
candidate accounts with the raw `email_from` as the login. It is installed on
production and under a standing do-not-edit rule, so a fix confined to this
addon's own provisioning would have left the live defect exactly where it was.
`res.users.create` is the one point every writer passes through - this addon,
pro, the auth gateway, a hand-made account in Settings - and inheritance stacks
regardless of module load order, which matters because this addon deliberately
does not depend on pro.
"""
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestALoginIsFoldedWhereverItIsMade(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Users = self.env["res.users"].sudo()
        self.portal = self.env.ref("base.group_portal")

    def _create(self, login):
        return self.Users.create({
            "name": "T %s" % login,
            "login": login,
            "password": "Testpass123",
            "group_ids": [(6, 0, [self.portal.id])],
        })

    def test_a_mixed_case_address_is_stored_folded(self):
        slug = uuid4().hex[:8]

        user = self._create("Asha.Rao.%s@Corp.com" % slug)

        self.assertEqual(user.login, "asha.rao.%s@corp.com" % slug)

    def test_surrounding_space_goes_too(self):
        """A CSV import is the usual source of both faults at once."""
        slug = uuid4().hex[:8]

        user = self._create("  Padded.%s@Corp.com  " % slug)

        self.assertEqual(user.login, "padded.%s@corp.com" % slug)

    def test_a_login_that_is_not_an_address_is_left_alone(self):
        """A service account is not an email and its case may be meaningful.
        Folding everything would be a wider change than the defect."""
        slug = uuid4().hex[:8].upper()

        user = self.Users.create({
            "name": "Svc %s" % slug,
            "login": "__SVC_%s__" % slug,
            "password": "Testpass123",
        })

        self.assertEqual(user.login, "__SVC_%s__" % slug)

    def test_an_already_folded_login_is_unchanged(self):
        slug = uuid4().hex[:8]

        user = self._create("plain.%s@corp.com" % slug)

        self.assertEqual(user.login, "plain.%s@corp.com" % slug)

    def test_a_batch_create_folds_every_row(self):
        """`@api.model_create_multi` - a loop that folded only `vals_list[0]`
        would pass every single-record test in this file."""
        slug = uuid4().hex[:8]

        users = self.Users.create([
            {"name": "A", "login": "A.One.%s@Corp.com" % slug,
             "password": "Testpass123"},
            {"name": "B", "login": "B.Two.%s@Corp.com" % slug,
             "password": "Testpass123"},
        ])

        self.assertEqual(
            sorted(users.mapped("login")),
            ["a.one.%s@corp.com" % slug, "b.two.%s@corp.com" % slug])

    def test_a_rename_is_deliberately_not_folded(self):
        """`write` is left alone on purpose: renaming a login is rare and done
        by an administrator looking at what they typed. Silently rewriting a
        deliberate edit is a different kind of surprise from the one being
        fixed, and the defect is account CREATION."""
        slug = uuid4().hex[:8]
        user = self._create("before.%s@corp.com" % slug)

        user.write({"login": "After.%s@Corp.com" % slug})

        self.assertEqual(user.login, "After.%s@Corp.com" % slug)

    def test_the_provisioning_path_still_binds_the_account_it_made(self):
        """The fold must not break the search that looks the account back up.
        `_ensure_candidate_user` matches on `=ilike`, so a folded login is
        still found from the applicant's raw address - if it were `=`, this
        addon would create a second account on every launch."""
        slug = uuid4().hex[:8]
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % slug,
            "email_from": "Cand.%s@Corp.com" % slug,
        })
        assessment = self.env["assessments.be"].create({
            "name": "Fold %s" % slug,
            "duration_minutes": 30,
        })

        first = assessment.sudo()._ensure_candidate_user(applicant)
        applicant.invalidate_recordset()
        second = assessment.sudo()._ensure_candidate_user(applicant)

        self.assertEqual(first, "created")
        self.assertEqual(
            second, "exists",
            "a second call must find the account the first one made, not "
            "create another - that is what a case-sensitive lookup against a "
            "folded login would do")
        self.assertEqual(
            applicant.be_candidate_user_id.login,
            "cand.%s@corp.com" % slug)
