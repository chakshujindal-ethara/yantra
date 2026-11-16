# -*- coding: utf-8 -*-
"""A-222: a typed-in candidate row needs a real email address.

The assign route checked only that name and email were non-empty and stored
`_norm_email(email) or email` - so a non-address was stored raw, and at launch
`_ensure_candidate_user` made it a portal login nobody can sign in to. The route
now refuses the request with 422 `invalid`, naming the bad rows, before it
writes anything. A valid row behaves exactly as before.

The candidate CSV import (Odoo button and `/candidates/import`) runs the same
check through `action_import_candidates_csv`: a bad row refuses the whole
file, and every row is checked before any applicant is created.
"""
import base64
from uuid import uuid4

from odoo.exceptions import UserError
from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import admin as api_admin
from ._paging_harness import call_route, status_of

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"


@tagged("-at_install", "post_install")
class TestATypedInCandidateNeedsARealAddress(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.paper = self.env["assessments.be"].create(
            {"name": "Assign %s" % uuid4().hex[:6], "duration_minutes": 30})
        self.good = "good.%s@example.com" % uuid4().hex[:8]

    def _assign(self, *rows):
        return call_route(
            api_admin, api_admin.EtpAssessmentApiAdmin(), "assessment_assign",
            self.env, path={"assessment_id": self.paper.id},
            candidates=[{"name": n, "email": e} for n, e in rows])

    def _applicants(self, email):
        return self.env["hr.applicant"].with_context(
            active_test=False).search([("email_from", "=", email)])

    def test_a_non_address_refuses_the_whole_request(self):
        refused = self._assign(("Good Person", self.good),
                               ("Bad Person", "not-an-email"))
        self.assertEqual(status_of(refused), 422, refused)
        self.assertEqual(refused["error"]["code"], "invalid")
        self.assertIn("row 2", refused["error"]["message"])
        self.assertIn("not-an-email", refused["error"]["message"])
        self.assertFalse(self._applicants("not-an-email"))
        self.assertFalse(self._applicants(self.good),
                         "half the request landed")
        self.assertFalse(self.env["res.users"].with_context(
            active_test=False).search([("login", "=", "not-an-email")]))
        self.assertFalse(self.paper.evaluator_ids)

        refused = self._assign(("x" * 201, self.good))
        self.assertEqual(status_of(refused), 422, refused)

        done = self._assign(("Good Person", self.good))
        self.assertEqual(status_of(done), 200, done)
        self.assertEqual(done["data"]["assigned_count"], 1)
        self.assertEqual(self.paper.evaluator_ids, self._applicants(self.good))

    def test_the_csv_import_refuses_the_same_rows(self):
        long_email = "long.%s@example.com" % uuid4().hex[:8]
        csv_text = ("name,email\nGood Person,%s\nBad Person,not-an-email\n"
                    "%s,%s\n" % (self.good, "x" * 300, long_email))
        self.paper.candidate_csv_file = base64.b64encode(csv_text.encode())
        with self.assertRaises(UserError) as caught:
            self.paper.action_import_candidates_csv()
        message = str(caught.exception)
        self.assertIn("Row 3: 'not-an-email' is not an email address", message)
        self.assertIn("Row 4: the name is longer than 200 characters", message)
        for email in (self.good, "not-an-email", long_email):
            self.assertFalse(self._applicants(email),
                             "%s was created by a refused import" % email)

        self.paper.candidate_csv_file = base64.b64encode(
            ("name,email\nGood Person,%s\n" % self.good).encode())
        self.paper.action_import_candidates_csv()
        self.assertEqual(self.paper.evaluator_ids, self._applicants(self.good))

    def test_messy_input_is_refused_not_repaired(self):
        """`email_normalize` pulls an address out of messy text, so "john
        smith@corp.com" was stored as smith@corp.com - somebody else. The
        whole input must be one plain address with a letters-only TLD."""
        bad = ("john smith@corp.com", "x@@y.com", "r4o bad@example",
               "bad@example", "r4a-bad@example.com3450", "r4a-cand4@@example")
        for email in bad:
            refused = self._assign(("Messy", email))
            self.assertEqual(status_of(refused), 422, (email, refused))
            self.assertEqual(refused["error"]["code"], "invalid")
            self.assertIn("row 1", refused["error"]["message"])
        self.paper.candidate_csv_file = base64.b64encode(
            ("name,email\n" + "".join("Messy,%s\n" % e for e in bad)
             ).encode())
        with self.assertRaises(UserError) as caught:
            self.paper.action_import_candidates_csv()
        for row in range(2, 2 + len(bad)):
            self.assertIn("Row %d:" % row, str(caught.exception))
        self.assertFalse(self.paper.evaluator_ids)
        # An applicant made some other way still cannot become a login.
        stray = self.env["hr.applicant"].create(
            {"partner_name": "Stray", "email_from": "r4a-cand4@@example"})
        with self.assertRaises(UserError):
            self.paper._ensure_candidate_user(stray)
        self.assertFalse(self.env["res.users"].with_context(
            active_test=False).search([("login", "=", "@example")]))
        self.assertEqual(status_of(self._assign(("Good", self.good))), 200)
