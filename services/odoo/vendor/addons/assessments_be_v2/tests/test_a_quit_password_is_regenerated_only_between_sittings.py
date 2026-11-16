# -*- coding: utf-8 -*-
"""R3: an admin can renew a paper's Safe Exam Browser quit password.

The password is the invigilators' way out of SEB, so an admin must be able to
find it and, when it has gone round, replace it. Its hash is inside every .seb
a candidate already downloaded, so a new one locks out anyone sitting the
paper: the route refuses while an attempt is in progress, and the old password
goes to the chatter for a candidate who opened SEB but has not started.

The same rule holds on the model, so the Odoo form cannot change it mid-sitting
either, and `/update` no longer takes the field at all. A generated password is
four groups of four from 32 symbols that cannot be misread (80 bits); one an
admin types needs at least 12 characters.
"""
from uuid import uuid4

from odoo.exceptions import UserError, ValidationError
from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import write as write_api
from ..services import seb
from ._paging_harness import call_route, status_of

#: Four groups of four, lowercase, without i, l, o or u.
FORMAT = r"^[0-9a-hjkmnp-tv-z]{4}(-[0-9a-hjkmnp-tv-z]{4}){3}$"

ADMIN_GROUP = "assessments_be_v2.group_assessment_manager"
MANAGER_GROUP = "assessments_be_v2.group_assessment_manager_restricted"
ROUTE = "assessment_seb_quit_password_regenerate"


@tagged("-at_install", "post_install")
class TestAQuitPasswordIsRegeneratedOnlyBetweenSittings(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(ADMIN_GROUP).id)]
        self.controller = write_api.EtpAssessmentApiWrite()
        generator = self.env["assessments.be.prompt"].create(
            {"name": "SEB pw %s" % uuid4().hex[:6]})
        self.paper = self.env["assessments.be"].create({
            "name": "SEB paper %s" % uuid4().hex[:6],
            "generator_id": generator.id, "duration_minutes": 30,
            "state": "in_progress", "rule_require_seb": True,
        })

    def _regenerate(self, env=None, paper=None):
        return call_route(write_api, self.controller, ROUTE, env or self.env,
                          path={"assessment_id": (paper or self.paper).id})

    def _sitting(self, state):
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Sitter %s" % uuid4().hex[:6],
            "email_from": "%s@example.com" % uuid4().hex[:10]})
        return self.env["assessments.be.evaluator"].create({
            "assessment_id": self.paper.id, "applicant_id": applicant.id,
            "state": state})

    def test_a_new_password_replaces_the_old_and_the_chatter_keeps_it(self):
        old = self.paper.seb_quit_password
        self._sitting("pending")
        out = self._regenerate()

        self.assertEqual(status_of(out), 200, out)
        new = self.paper.seb_quit_password
        self.assertRegex(new, FORMAT)
        self.assertNotEqual(new, old)
        self.assertEqual(out["data"]["seb_quit_password"], new,
                         "the reply is the paper's detail, new password in it")
        self.assertTrue(self.env["mail.message"].search_count([
            ("model", "=", "assessments.be"), ("res_id", "=", self.paper.id),
            ("body", "ilike", old)]),
            "the old password must stay findable for a candidate who opened "
            "SEB before the change")

    def test_refused_while_someone_is_sitting(self):
        old = self.paper.seb_quit_password
        sitting = self._sitting("in_progress")
        out = self._regenerate()

        self.assertEqual((status_of(out), out["error"]["code"]),
                         (409, "sitting_in_progress"), out)
        self.assertEqual(self.paper.seb_quit_password, old)

        sitting.write({"state": "submitted", "is_locked": True})
        self.assertEqual(status_of(self._regenerate()), 200)
        self.assertNotEqual(self.paper.seb_quit_password, old)

    def test_only_an_admin_can_regenerate(self):
        old = self.paper.seb_quit_password
        manager = self.env["res.users"].with_context(
            no_reset_password=True).create({
                "name": "Read-only manager",
                "login": "ro_%s@example.com" % uuid4().hex[:8],
                "group_ids": [(6, 0, [self.env.ref("base.group_user").id,
                                      self.env.ref(MANAGER_GROUP).id])],
            })
        out = self._regenerate(env=self.env(user=manager))

        self.assertEqual(status_of(out), 403, out)
        self.assertEqual(self.paper.seb_quit_password, old)

    def test_an_unknown_paper_is_not_found(self):
        missing = self.env["assessments.be"].browse(10 ** 9)
        self.assertEqual(status_of(self._regenerate(paper=missing)), 404)

    def test_the_update_route_does_not_take_it(self):
        """`/update` bypassed the between-sittings rule of `/regenerate`."""
        old = self.paper.seb_quit_password
        self._sitting("in_progress")
        out = call_route(write_api, self.controller, "assessment_update",
                         self.env, path={"assessment_id": self.paper.id},
                         seb_quit_password="typed-by-hand-1234")

        self.assertEqual(self.paper.seb_quit_password, old, out)

    def test_the_odoo_form_cannot_change_it_mid_sitting(self):
        old = self.paper.seb_quit_password
        sitting = self._sitting("in_progress")
        with self.assertRaises(UserError) as refused:
            self.paper.write({"seb_quit_password": "typed-by-hand-1234"})
        self.assertIn("sitting this paper", str(refused.exception))
        self.assertEqual(self.paper.seb_quit_password, old)

        self.paper.write({"seb_quit_password": old})   # no change: allowed
        sitting.write({"state": "submitted", "is_locked": True})
        self.paper.write({"seb_quit_password": "typed-by-hand-1234"})
        self.assertEqual(self.paper.seb_quit_password, "typed-by-hand-1234")

    def test_a_generated_password_is_80_bits_and_typeable(self):
        drawn = {seb.new_quit_password() for _ in range(50)}
        self.assertEqual(len(drawn), 50)
        for password in drawn:
            self.assertRegex(password, FORMAT)
        self.assertEqual(len(seb.QUIT_PASSWORD_ALPHABET), 32)
        self.assertEqual(len(set(seb.QUIT_PASSWORD_ALPHABET)), 32)

    def test_a_typed_password_needs_twelve_characters(self):
        with self.assertRaises(ValidationError):
            self.paper.write({"seb_quit_password": "1"})
            self.env.flush_all()
        self.paper.write({"seb_quit_password": "twelve-chars"})
        self.env.flush_all()
        self.assertEqual(self.paper.seb_quit_password, "twelve-chars")

    def test_a_new_paper_needs_a_long_password_only_with_seb_on(self):
        """Typed on the Odoo form at create: no constraint covers it now."""
        vals = {"name": "SEB new %s" % uuid4().hex[:6],
                "generator_id": self.paper.generator_id.id,
                "duration_minutes": 30, "seb_quit_password": "short"}
        with self.assertRaises(ValidationError):
            self.env["assessments.be"].create(
                dict(vals, rule_require_seb=True))
        self.assertEqual(
            self.env["assessments.be"].create(vals).seb_quit_password, "short")

    def test_a_short_legacy_password_does_not_block_other_saves(self):
        """Older apps save the whole settings object, `rule_require_seb`
        included and unchanged. The minimum then refused every save of a
        paper holding an older short password, and mid-sitting the password
        cannot be changed to clear it."""
        self._sitting("in_progress")
        self.env.flush_all()
        self.env.cr.execute("UPDATE assessments_be SET seb_quit_password = "
                            "'short' WHERE id = %s", (self.paper.id,))
        self.paper.invalidate_recordset()

        out = call_route(write_api, self.controller, "assessment_update",
                         self.env, path={"assessment_id": self.paper.id},
                         rule_require_seb=True, max_violations=4)
        self.paper.write({"seb_quit_password": "short"})   # unchanged too
        self.env.flush_all()

        self.assertEqual(status_of(out), 200, out)
        self.assertEqual(self.paper.max_violations, 4)

    def test_a_short_legacy_password_does_not_block_turning_seb_off(self):
        self.env.flush_all()
        self.env.cr.execute("UPDATE assessments_be SET seb_quit_password = '1' "
                            "WHERE id = %s", (self.paper.id,))
        self.paper.invalidate_recordset()
        self.paper.write({"rule_require_seb": False})
        self.env.flush_all()
        self.assertFalse(self.paper.rule_require_seb)
        with self.assertRaises(ValidationError):
            self.paper.write({"rule_require_seb": True})
            self.env.flush_all()
