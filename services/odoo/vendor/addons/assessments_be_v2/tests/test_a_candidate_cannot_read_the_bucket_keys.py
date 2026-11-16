# -*- coding: utf-8 -*-
"""An exam candidate cannot read the AWS keys, yet the module still finds them.

Candidates are internal users, and `s3.connector` (when that addon is installed)
stores the AWS keys in plain text. Its access rows are now Administration only;
this addon reads the record through sudo(), which must keep working.
"""
from uuid import uuid4

from odoo.exceptions import AccessError
from odoo.tests.common import TransactionCase, tagged

from ..services import s3_service


@tagged("-at_install", "post_install")
class TestACandidateCannotReadTheBucketKeys(TransactionCase):

    def setUp(self):
        super().setUp()
        if "s3.connector" not in self.env:
            self.skipTest("s3_connector is not installed on this database")
        email = "bucket_%s@example.com" % uuid4().hex[:8]
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Bucket Candidate", "email_from": email})
        self.env["assessments.be"].sudo()._ensure_candidate_user(applicant)
        self.candidate = applicant.sudo().be_candidate_user_id
        self.assertTrue(self.candidate)
        self.env["s3.connector"].sudo().create({
            "name": "fake-bucket",
            "aws_access_key_id": "AKIAFAKE000000000000",
            "aws_secret_access_key": "fake-secret-not-real",
        })

    def test_the_candidate_is_refused(self):
        env = self.env(user=self.candidate)
        with self.assertRaises(AccessError):
            env["s3.connector"].search_read([])

    def test_the_module_still_finds_the_connector(self):
        env = self.env(user=self.candidate)
        self.assertTrue(s3_service._connector(env))
