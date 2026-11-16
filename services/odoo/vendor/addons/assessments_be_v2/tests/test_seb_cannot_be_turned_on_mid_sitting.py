# -*- coding: utf-8 -*-
"""Safe Exam Browser cannot be turned on while candidates are sitting.

SEB review #14: turning "Require Safe Exam Browser" on mid-sitting put the
`seb_required` gate in front of candidates already answering in a normal
browser, with their clock still running. The model refuses it, so the API and
the Odoo form both obey; the API answers 409 `sitting_in_progress`, like
`/regenerate`. Turning it off stays allowed: it is the way out of a lockout.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.exceptions import UserError
from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import write as write_api
from ._paging_harness import call_route, status_of

ADMIN_GROUP = "assessments_be_v2.group_assessment_manager"


@tagged("-at_install", "post_install")
class TestSebCannotBeTurnedOnMidSitting(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(ADMIN_GROUP).id)]
        self.controller = write_api.EtpAssessmentApiWrite()
        generator = self.env["assessments.be.prompt"].create(
            {"name": "SEB on %s" % uuid4().hex[:6]})
        self.paper = self.env["assessments.be"].create({
            "name": "SEB on paper %s" % uuid4().hex[:6],
            "generator_id": generator.id, "duration_minutes": 30,
            "state": "in_progress",
        })

    def _sitting(self, state, **vals):
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Sitter %s" % uuid4().hex[:6],
            "email_from": "%s@example.com" % uuid4().hex[:10]})
        return self.env["assessments.be.evaluator"].create(dict({
            "assessment_id": self.paper.id, "applicant_id": applicant.id,
            "state": state}, **vals))

    def _update(self, **params):
        # A refusal rolls back; a test cursor may not.
        with patch.object(self.env.cr, "rollback", lambda: None):
            return call_route(write_api, self.controller, "assessment_update",
                              self.env, path={"assessment_id": self.paper.id},
                              **params)

    def test_turning_it_on_is_refused_while_someone_is_sitting(self):
        self._sitting("in_progress")

        out = self._update(rule_require_seb=True)
        self.assertEqual((status_of(out), out["error"]["code"]),
                         (409, "sitting_in_progress"), out)
        self.assertFalse(self.paper.rule_require_seb)

        with self.assertRaises(UserError) as refused:
            self.paper.write({"rule_require_seb": True})
        self.assertIn("sitting this paper", str(refused.exception))
        self.assertFalse(self.paper.rule_require_seb)

    def test_turning_it_off_is_allowed_while_someone_is_sitting(self):
        self.paper.rule_require_seb = True
        self._sitting("in_progress")

        out = self._update(rule_require_seb=False)

        self.assertEqual(status_of(out), 200, out)
        self.assertFalse(self.paper.rule_require_seb)

    def test_turning_it_on_is_allowed_with_nobody_sitting(self):
        self._sitting("pending")
        self._sitting("submitted", is_locked=True)

        out = self._update(rule_require_seb=True)

        self.assertEqual(status_of(out), 200, out)
        self.assertTrue(self.paper.rule_require_seb)
