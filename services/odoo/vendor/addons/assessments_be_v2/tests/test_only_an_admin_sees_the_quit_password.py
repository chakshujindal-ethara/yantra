# -*- coding: utf-8 -*-
"""Only an Admin receives a paper's Safe Exam Browser quit password.

The assessment detail is readable by the read-only Manager role
(`require_operator`), and it carried the password to them too - the one
secret that lets a candidate out of SEB. Every role but Admin now gets
`"seb_quit_password": null`, and the app hides Copy and Renew on null. The
field itself is Admin-only too, so the Odoo form and RPC cannot hand it out.
"""
from uuid import uuid4

from odoo.exceptions import AccessError
from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import admin as admin_api
from ._paging_harness import call_route, status_of

ADMIN_GROUP = "assessments_be_v2.group_assessment_manager"
MANAGER_GROUP = "assessments_be_v2.group_assessment_manager_restricted"


@tagged("-at_install", "post_install")
class TestOnlyAnAdminSeesTheQuitPassword(TransactionCase):

    def setUp(self):
        super().setUp()
        self.controller = admin_api.EtpAssessmentApiAdmin()
        self.paper = self.env["assessments.be"].create({
            "name": "SEB detail %s" % uuid4().hex[:6],
            "rule_require_seb": True})

    def _user(self, group):
        return self.env["res.users"].with_context(
            no_reset_password=True).create({
                "name": "Role %s" % uuid4().hex[:6],
                "login": "role_%s@example.com" % uuid4().hex[:8],
                "group_ids": [(6, 0, [self.env.ref("base.group_user").id,
                                      self.env.ref(group).id])],
            })

    def _detail(self, user):
        out = call_route(admin_api, self.controller, "assessment_detail",
                         self.env(user=user),
                         path={"assessment_id": self.paper.id})
        self.assertEqual(status_of(out), 200, out)
        return out["data"]

    def test_an_admin_gets_the_password(self):
        detail = self._detail(self._user(ADMIN_GROUP))
        self.assertEqual(detail["seb_quit_password"],
                         self.paper.seb_quit_password)

    def test_a_read_only_manager_gets_null(self):
        detail = self._detail(self._user(MANAGER_GROUP))
        self.assertIn("seb_quit_password", detail)
        self.assertIsNone(detail["seb_quit_password"])

    def test_a_read_only_manager_cannot_read_the_field(self):
        manager = self._user(MANAGER_GROUP)
        self.paper.invalidate_recordset()
        with self.assertRaises(AccessError):
            self.paper.with_user(manager).read(["seb_quit_password"])
        self.assertNotIn("seb_quit_password", self.env["assessments.be"]
                         .with_user(manager).fields_get())
