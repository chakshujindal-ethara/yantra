# -*- coding: utf-8 -*-
"""A-224: the chatter's attachments and a draft's image have a size ceiling.

Every other upload route refuses past `_MAX_UPLOAD_BYTES` (25 MB, 413
`too_large`). `chatter_post` decoded every attachment with no limit and counted
them only after decoding; `draft_apply_image` had no limit at all. Every
upload route now sizes from the encoded length before decoding
(`write._too_large`), and the chatter counts first.

The ceiling is patched down to 30 bytes so the test does not build 25 MB
strings; the check under test is the route's own comparison.
"""
import base64
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import write as write_api
from ._paging_harness import call_route, status_of

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"
BIG = base64.b64encode(b"x" * 60).decode()
SMALL = base64.b64encode(b"hello").decode()


@tagged("-at_install", "post_install")
class TestAnUploadIsSizedBeforeItIsDecoded(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.api = write_api.EtpAssessmentApiWrite()
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % uuid4().hex[:6]})
        self.paper = self.env["assessments.be"].create({
            "name": "Paper %s" % uuid4().hex[:6],
            "generator_id": self.generator.id})
        patcher = patch.object(write_api, "_MAX_UPLOAD_BYTES", 30)
        patcher.start()
        self.addCleanup(patcher.stop)

    def _post(self, attachments):
        return call_route(
            write_api, self.api, "chatter_post", self.env,
            path={"kind": "assessment", "record_id": self.paper.id,
                  "body": "See attached"},
            attachments=attachments)

    def test_the_chatter_counts_then_sizes_then_decodes(self):
        # 11 files that are not even base64: the count must refuse first.
        refused = self._post([{"name": "f%d" % i, "content": "!!!"}
                              for i in range(11)])
        self.assertEqual(status_of(refused), 422, refused)
        self.assertEqual(refused["error"]["code"], "too_many")

        refused = self._post([{"name": "big.bin", "content": BIG}])
        self.assertEqual(status_of(refused), 413, refused)
        self.assertEqual(refused["error"]["code"], "too_large")

        posted = self._post([{"name": "note.txt", "content": SMALL}])
        self.assertEqual(status_of(posted), 200, posted)
        message = self.env["mail.message"].browse(posted["data"]["id"])
        self.assertEqual(message.attachment_ids.mapped("raw"), [b"hello"])

    def test_a_draft_image_over_the_ceiling_is_refused(self):
        draft = self.env["assessments.be.prompt.question"].create({
            "prompt_id": self.generator.id, "name": "Draft", "state": "draft"})
        refused = call_route(
            write_api, self.api, "draft_apply_image", self.env,
            path={"draft_id": draft.id}, image=BIG, slot="a")
        self.assertEqual(status_of(refused), 413, refused)
        self.assertEqual(refused["error"]["code"], "too_large")
        self.assertFalse(draft.upload_image, "the oversize image was staged")

    def test_the_other_uploads_refuse_before_decoding(self):
        """A SOP resource and a bank clip, both of which decoded first. The
        payload is not even base64: a 413 proves nothing was decoded."""
        junk = "!" * 60
        question = self.env["assessments.be.question"].create({
            "name": "Clip %s" % uuid4().hex[:4], "question_type": "mcq",
            "prompt": "Watch", "generator_id": self.generator.id})
        for method, path, body in (
                ("generator_resource_upload",
                 {"generator_id": self.generator.id},
                 {"name": "sop.md", "content": junk}),
                ("bank_question_apply_video",
                 {"question_id": question.id}, {"content": junk})):
            refused = call_route(write_api, self.api, method, self.env,
                                 path=path, **body)
            self.assertEqual(status_of(refused), 413, (method, refused))
            self.assertEqual(refused["error"]["code"], "too_large")
