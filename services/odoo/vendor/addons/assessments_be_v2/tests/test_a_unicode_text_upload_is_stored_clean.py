# -*- coding: utf-8 -*-
"""A text upload with NUL bytes in it is stored, not answered with a 500.

THE PRODUCTION DEFECT (2026-09-29). `POST /api/v1/generators/108/resources`
500'd with "A string literal cannot contain NUL (0x00) characters" while
flushing `extracted_text`. `_extract_text` read every text file as UTF-8, and a
Windows "Unicode" save is UTF-16 with a BOM, so every other character came out
NUL - which Postgres refuses in any text column.

`simple_import.upload_text` decodes a UTF-16 BOM as UTF-16 and drops any NUL
left. The resource extractor and the CSV importers all read through it.
"""
import base64
import codecs
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import write as write_api
from ..models.simple_import import read_csv, upload_text
from ._paging_harness import call_route, status_of

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"
BODY = "name,display\nalpha,Alpha\n"
# What Notepad / Excel write for "Unicode": a BOM, then UTF-16.
UTF16_LE = codecs.BOM_UTF16_LE + BODY.encode("utf-16-le")
UTF16_BE = codecs.BOM_UTF16_BE + BODY.encode("utf-16-be")


@tagged("-at_install", "post_install")
class TestAUnicodeTextUploadIsStoredClean(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.generator = self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % uuid4().hex[:6]})

    def _resource(self, name, raw):
        resource = self.env["assessments.be.prompt.resource"].create({
            "prompt_id": self.generator.id, "name": name, "category": "sop",
            "file": base64.b64encode(raw)})
        self.env.flush_all()  # where production raised
        return resource

    def test_a_utf16_file_is_decoded_not_nul_riddled(self):
        for name, raw in (("sop.txt", UTF16_LE), ("sop.csv", UTF16_BE)):
            with self.subTest(name=name):
                resource = self._resource(name, raw)
                self.assertEqual(resource.extracted_text, BODY)
                self.assertFalse(resource.extraction_error)

    def test_a_stray_nul_is_dropped(self):
        resource = self._resource("notes.md", b"before\x00after")
        self.assertEqual(resource.extracted_text, "beforeafter")

    def test_the_route_answers_200_and_stores_clean_text(self):
        response = call_route(
            write_api, write_api.EtpAssessmentApiWrite(),
            "generator_resource_upload", self.env,
            path={"generator_id": self.generator.id}, name="export.csv",
            content=base64.b64encode(UTF16_LE).decode(), category="sop")
        self.env.flush_all()
        self.assertEqual(status_of(response), 200, response)
        self.assertEqual(self.generator.resource_ids.extracted_text, BODY)

    def test_the_csv_importers_read_the_same_file(self):
        self.assertEqual(read_csv(UTF16_LE, "name"),
                         [(2, {"name": "alpha", "display": "Alpha"})])
        # The candidate import refuses non-UTF-8 (fallback=None) and still
        # reads a UTF-16 file by its BOM; the others fall back to latin-1.
        self.assertEqual(upload_text(UTF16_BE, fallback=None), BODY)
        with self.assertRaises(UnicodeDecodeError):
            upload_text(b"caf\xe9", fallback=None)
        self.assertEqual(upload_text(b"caf\xe9"), "caf\xe9")
