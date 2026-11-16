# -*- coding: utf-8 -*-
"""`/api/v1/attempts/<id>/evidence` lists an attempt's AI proctoring snapshots.

The app names each upload `<epoch_ms>_<rule>.jpg` under the attempt's own
prefix (`services/evidence.py`), so the route reads time and rule back off the
name, lists newest first, and signs a 15-minute GET for each. Only staff may
read it: a candidate is refused like on every other admin route.

S3 is stubbed (`storage_target`), as in
`test_a_browser_upload_is_scoped_to_its_prefix`.
"""
from datetime import datetime, timezone
from unittest.mock import MagicMock, patch
from uuid import uuid4

from botocore.exceptions import ClientError

from odoo import fields
from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import admin as admin_api
from ..controllers.api import write as write_api
from ..services import evidence, s3_service
from ._paging_harness import call_route, status_of
from .test_archive_suspends_and_delete_destroys import _write_controller

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"


@tagged("-at_install", "post_install")
class TestAnAdminSeesProctoringEvidence(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.env["ir.config_parameter"].sudo().set_param(
            "assessments_be_v2.s3_folder", "etp_assessment")
        self.controller = admin_api.EtpAssessmentApiAdmin()
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Ev %s" % uuid4().hex[:6]})
        paper = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": generator.id,
            "rule_webcam": True, "rule_ai_proctor": True,
        })
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Snapped",
            "email_from": "%s@example.com" % uuid4().hex[:10]})
        self.evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": paper.id, "applicant_id": applicant.id,
            "access_token": uuid4().hex,
        })
        paper.sudo()._ensure_candidate_user(applicant)
        self.candidate = self.evaluator.sudo()._candidate_user()
        self.prefix = "etp_assessment/proctoring/%s/%s/" % (
            self.env.cr.dbname, self.evaluator.id)

    def _client(self, *pages):
        cli = MagicMock()
        cli.list_objects_v2.side_effect = list(pages)
        cli.generate_presigned_url.side_effect = (
            lambda op, Params, ExpiresIn:
            "https://signed/%s?ttl=%s" % (Params["Key"], ExpiresIn))
        return cli

    def _evidence(self, cli, bucket="module-bucket", user=None):
        env = self.env(user=user) if user else self.env
        with patch.object(s3_service, "storage_target",
                          return_value=(cli, bucket)):
            return call_route(admin_api, self.controller, "attempt_evidence",
                              env, path={"evaluator_id": self.evaluator.id})

    def test_items_are_parsed_signed_and_newest_first(self):
        """Newest by S3's LastModified, not by the time the client wrote into
        the name: `no_face` claims to be newer than `phone` and is not."""
        p = self.prefix

        def obj(name, size, minute):
            return {"Key": p + name, "Size": size,
                    "LastModified": datetime(2025, 10, 6, 11, minute,
                                             tzinfo=timezone.utc)}

        cli = self._client(
            {"Contents": [obj("1759750000000_phone.jpg", 10, 32),
                          obj("1759750005000_no_face.jpg", 20, 31)],
             "IsTruncated": True, "NextContinuationToken": "t1"},
            {"Contents": [obj("1759749990000_more_than_one_face.jpg", 30, 30),
                          obj("1759750009000_bad rule!.jpg", 40, 33),
                          obj("snapshot.jpg", 50, 29)],
             "IsTruncated": False})
        out = self._evidence(cli)
        self.assertEqual(status_of(out), 200, out)
        data = out["data"]
        self.assertEqual(data["prefix"], self.prefix)
        self.assertEqual(data["count"], 5)
        self.assertEqual(
            [(i["rule"], i["at"], i["size"]) for i in data["items"]], [
                ("", "2025-10-06T11:26:49Z", 40),
                ("phone", "2025-10-06T11:26:40Z", 10),
                ("no_face", "2025-10-06T11:26:45Z", 20),
                ("more_than_one_face", "2025-10-06T11:26:30Z", 30),
                ("", None, 50),
            ])
        for item in data["items"]:
            self.assertTrue(item["key"].startswith(self.prefix))
            self.assertEqual(item["url"],
                             "https://signed/%s?ttl=900" % item["key"])
        first, second = cli.list_objects_v2.call_args_list
        self.assertEqual(first.kwargs, {"Bucket": "module-bucket",
                                        "Prefix": self.prefix})
        self.assertEqual(second.kwargs["ContinuationToken"], "t1")

    def test_a_candidate_is_refused(self):
        cli = self._client()
        out = self._evidence(cli, user=self.candidate)
        self.assertEqual(status_of(out), 403, out)
        cli.list_objects_v2.assert_not_called()

    def test_no_storage_is_an_empty_list_that_says_so_and_never_calls_boto(
            self):
        """A blank bucket is a normal state: 200, not a failed listing."""
        with patch.object(evidence, "_pages") as pages:
            out = self._evidence(None, bucket=None)
        self.assertEqual(status_of(out), 200, out)
        self.assertEqual(out["data"]["items"], [])
        self.assertEqual(out["data"]["count"], 0)
        self.assertEqual(out["data"]["storage"], "not_configured")
        pages.assert_not_called()

    def test_a_storage_error_is_a_502_not_a_500(self):
        cli = MagicMock()
        cli.list_objects_v2.side_effect = ClientError(
            {"Error": {"Code": "AccessDenied", "Message": "no"}},
            "ListObjectsV2")
        out = self._evidence(cli)
        self.assertEqual(status_of(out), 502, out)
        self.assertEqual(out["error"]["code"], "s3_failed")

    def test_an_unknown_attempt_is_404(self):
        out = call_route(admin_api, self.controller, "attempt_evidence",
                         self.env, path={"evaluator_id": 0})
        self.assertEqual(status_of(out), 404, out)

    def test_listing_stops_at_five_pages(self):
        cli = MagicMock()
        cli.list_objects_v2.return_value = {
            "Contents": [], "IsTruncated": True, "NextContinuationToken": "t"}
        self.assertEqual(status_of(self._evidence(cli)), 200)
        self.assertEqual(cli.list_objects_v2.call_count, 5)

    # -- erasure ----------------------------------------------------------

    def _erase(self, cli):
        with patch.object(s3_service, "storage_target",
                          return_value=(cli, "module-bucket")):
            return call_route(admin_api, self.controller, "attempt_erase",
                              self.env, path={"evaluator_id": self.evaluator.id})

    def test_erasing_deletes_every_listed_snapshot(self):
        p = self.prefix
        cli = self._client(
            {"Contents": [{"Key": p + "1_phone.jpg"}, {"Key": p + "2_phone.jpg"}],
             "IsTruncated": True, "NextContinuationToken": "t1"},
            {"Contents": [{"Key": p + "3_no_face.jpg"}], "IsTruncated": False})
        cli.delete_objects.return_value = {}
        self.assertEqual(status_of(self._erase(cli)), 200)
        self.assertTrue(self.evaluator.pii_anonymized)
        self.assertEqual(
            [c.kwargs for c in cli.delete_objects.call_args_list], [
                {"Bucket": "module-bucket", "Delete": {"Objects": [
                    {"Key": p + "1_phone.jpg"}, {"Key": p + "2_phone.jpg"}],
                    "Quiet": True}},
                {"Bucket": "module-bucket", "Delete": {"Objects": [
                    {"Key": p + "3_no_face.jpg"}], "Quiet": True}},
            ])
        self.assertEqual(cli.list_objects_v2.call_args_list[0].kwargs,
                         {"Bucket": "module-bucket", "Prefix": p})

    def test_an_s3_error_never_stops_the_erasure(self):
        cli = self._client({"Contents": [{"Key": self.prefix + "1_phone.jpg"}],
                            "IsTruncated": False})
        cli.delete_objects.side_effect = ClientError(
            {"Error": {"Code": "AccessDenied", "Message": "no"}},
            "DeleteObjects")
        with self.assertLogs(evidence._logger, "WARNING"):
            out = self._erase(cli)
        self.assertEqual(status_of(out), 200, out)
        self.assertTrue(self.evaluator.pii_anonymized)

    def test_an_erased_attempt_lists_nothing(self):
        cli = self._client({"Contents": [], "IsTruncated": False})
        cli.delete_objects.return_value = {}
        self._erase(cli)
        after = self._client()
        out = self._evidence(after)
        self.assertEqual(status_of(out), 200, out)
        self.assertEqual((out["data"]["items"], out["data"]["count"]), ([], 0))
        after.list_objects_v2.assert_not_called()
        after.generate_presigned_url.assert_not_called()

    # -- deleting the paper ---------------------------------------------

    def _paper_with_attempts(self):
        """The paper, archived (step one of the delete), with two STARTED
        attempts and one that never began. Returns the paper and the two
        started attempts' full prefixes."""
        paper = self.evaluator.assessment_id
        paper.active = False
        second = self.env["assessments.be.evaluator"].create({
            "assessment_id": paper.id,
            "applicant_id": self.env["hr.applicant"].create({
                "partner_name": "Second",
                "email_from": "%s@example.com" % uuid4().hex[:10]}).id,
            "access_token": uuid4().hex,
        })
        self.env["assessments.be.evaluator"].create({
            "assessment_id": paper.id,
            "applicant_id": self.env["hr.applicant"].create({
                "partner_name": "Never began",
                "email_from": "%s@example.com" % uuid4().hex[:10]}).id,
            "access_token": uuid4().hex,
        })
        started = self.evaluator | second
        started.write({"started_at": fields.Datetime.now()})
        return paper, {"etp_assessment/proctoring/%s/%s/" % (
            self.env.cr.dbname, ev.id) for ev in started}

    def _delete_paper(self, paper, cli):
        with patch.object(s3_service, "storage_target",
                          return_value=(cli, "module-bucket")):
            return call_route(
                write_api, _write_controller(), "assessment_delete", self.env,
                path={"assessment_id": paper.id}, confirm_name=paper.name)

    @staticmethod
    def _bucket_with_one_snapshot_per_prefix():
        cli = MagicMock()
        cli.list_objects_v2.side_effect = lambda Bucket, Prefix, **kw: {
            "Contents": [{"Key": Prefix + "1_phone.jpg"}],
            "IsTruncated": False}
        cli.delete_objects.return_value = {}
        return cli

    def test_deleting_a_paper_purges_every_started_attempts_snapshots(self):
        paper, prefixes = self._paper_with_attempts()
        paper_id = paper.id
        cli = self._bucket_with_one_snapshot_per_prefix()
        out = self._delete_paper(paper, cli)
        self.assertEqual(status_of(out), 200, out)
        self.assertFalse(self.env["assessments.be"].with_context(
            active_test=False).browse(paper_id).exists())
        purged = [c.kwargs["Delete"]["Objects"][0]["Key"]
                  for c in cli.delete_objects.call_args_list]
        self.assertEqual(
            sorted(purged), sorted(p + "1_phone.jpg" for p in prefixes),
            "both started attempts, and not the one that never began")

    def test_an_s3_error_never_stops_the_paper_delete(self):
        paper, _prefixes = self._paper_with_attempts()
        paper_id = paper.id
        cli = self._bucket_with_one_snapshot_per_prefix()
        cli.delete_objects.side_effect = ClientError(
            {"Error": {"Code": "AccessDenied", "Message": "no"}},
            "DeleteObjects")
        with self.assertLogs(evidence._logger, "WARNING"):
            out = self._delete_paper(paper, cli)
        self.assertEqual(status_of(out), 200, out)
        self.assertFalse(self.env["assessments.be"].with_context(
            active_test=False).browse(paper_id).exists())
