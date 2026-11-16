# -*- coding: utf-8 -*-
"""An admin previewing a candidate's paper must be able to see its pictures.

THE DEFECT. `/assessments_be/exam/qimage/<token>/<id>` is `auth="public"` and
scoped by the token in its path, and `_refused()` turned away any signed-in
user who was not this evaluator's candidate. That reads as a sensible guard and
was not one, because `models/ir_http._auth_method_public` adopts a bearer on
this prefix too: an admin previewing the paper arrived as THEMSELVES, not as
public, and was refused.

The symptom is what made it hard to report. The same URL in an `<img>` tag -
which sends no credential at all - worked, while any fetch that carried one
404ed. Media appeared or vanished depending on how the browser happened to
request it, and nothing in either log said so.

Refusing them protected nothing: `controllers/admin_media.py` serves the exact
same bytes to the exact same people, gated on the exact test now used here to
admit them.

`_refused` reads `request.env.user`, so these tests give it a request. A
TransactionCase has none of its own, and the alternative - a full HttpCase -
would be testing werkzeug rather than the branch that changed.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase

from ..controllers import exam_media


class _FakeRequest:
    """The one attribute `_refused` reads."""

    def __init__(self, env):
        self.env = env


class TestAdminCanSeeExamMedia(TransactionCase):

    def setUp(self):
        super().setUp()
        assessment = self.env["assessments.be"].create(
            {"name": "Preview %s" % uuid4().hex[:6]})
        self.applicant = self.env["hr.applicant"].create({
            "partner_name": "Candidate %s" % uuid4().hex[:6],
            "email_from": "cand_%s@example.com" % uuid4().hex[:8],
        })
        self.evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id,
            "applicant_id": self.applicant.id,
        })
        self.controller = exam_media.AssessmentsBeExamMedia()

    def _refused_as(self, user):
        with patch.object(exam_media, "request",
                          _FakeRequest(self.env(user=user))):
            return self.controller._refused(self.evaluator)

    def test_an_internal_user_is_admitted(self):
        """THE regression: anyone who may open `admin_qimage` may open this."""
        admin = self.env.ref("base.user_admin")
        self.assertTrue(admin._is_internal(), "fixture check")

        self.assertFalse(
            self._refused_as(admin),
            "an admin previewing a candidate's paper was refused every "
            "picture on it, while the same URL in an <img> tag worked")

    def test_a_public_caller_is_still_admitted_on_the_token(self):
        """The candidate's own browser, which sends no credential at all."""
        public = self.env.ref("base.public_user")

        self.assertFalse(self._refused_as(public))

    def test_another_candidate_is_still_refused(self):
        """The guard that had to survive the fix.

        Widening this to "any signed-in user" would let one candidate read
        another's paper by holding their token, which is what the original
        check was for. A portal user is the shape that matters: candidates are
        provisioned as non-internal accounts.
        """
        portal = [(6, 0, [self.env.ref("base.group_portal").id])]
        intruder = self.env["res.users"].create({
            "name": "Other candidate",
            "login": "intruder_%s@example.com" % uuid4().hex[:8],
            # `group_ids` in Odoo 19; `groups_id` was renamed.
            "group_ids": portal,
        })
        self.assertFalse(intruder._is_internal(), "fixture check")

        # `_refused` compares against the evaluator's OWN candidate account,
        # and `bool(candidate) and ...` means NO account admits everybody. An
        # evaluator only gets one at launch, so the fixture has to mint it or
        # this test passes for the wrong reason.
        self.env["res.users"].create({
            "name": self.applicant.partner_name,
            "login": self.applicant.email_from,
            "group_ids": portal,
        })
        self.applicant.invalidate_recordset()
        self.assertTrue(
            self.evaluator._candidate_user(),
            "fixture check: the evaluator must resolve to a candidate user")

        self.assertTrue(
            self._refused_as(intruder),
            "a portal user who is not this candidate must not read their paper")
