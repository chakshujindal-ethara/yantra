# -*- coding: utf-8 -*-
"""Golden questions ARE sample questions: one list per generator.

Owner decision, 2026-09-29. There were two lists - "Golden examples" (text
only, sent under a GOLDEN EXAMPLES heading) and "Sample questions" (any file,
sent under SAMPLE QUESTIONS) - for what the owner calls the same thing. Now:

  * every upload lands in `sample`, whatever tab it came from, any file type;
  * a row still carrying the old `golden` category is moved by `init()` on the
    next `-u` and read as a sample until then;
  * generation sends every file as a SAMPLE (format only) and no GOLDEN heading;
  * Draft from SOP reads the same list with its rule-9 golden treatment, a PDF
    or image travelling natively.

Replaces test_golden_examples.py, which pinned the two-list behaviour.
"""
import base64
from unittest.mock import patch

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import write as write_api
from ..services import vertex
from ..services.vertex import _sample_doc_parts, _sop_doc_parts
from ._paging_harness import call_route, status_of

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"
PDF = b"%PDF-1.4 fake"
EXAMPLE_MD = "# Worked example\n\n- Is the Picture Sharp and Clear?  Yes\n"


@tagged("-at_install", "post_install")
class TestGoldenQuestionsAreSampleQuestions(TransactionCase):

    def setUp(self):
        super().setUp()
        self.env.user.group_ids = [(4, self.env.ref(MANAGER_GROUP).id)]
        self.Res = self.env["assessments.be.prompt.resource"]
        self.gen = self.env["assessments.be.prompt"].create(
            {"name": "one list probe"})

    def _attach(self, name, category, body=EXAMPLE_MD):
        raw = body if isinstance(body, bytes) else body.encode()
        return self.Res.create({
            "prompt_id": self.gen.id, "name": name, "category": category,
            "file": base64.b64encode(raw).decode()})

    def _legacy_golden(self, name, body=EXAMPLE_MD):
        """A row written before the merge: only SQL can make one now."""
        res = self._attach(name, "sample", body)
        self.env.flush_all()
        self.env.cr.execute(
            "UPDATE assessments_be_prompt_resource SET category = 'golden' "
            "WHERE id = %s", (res.id,))
        res.invalidate_recordset()
        return res

    def _texts(self, parts):
        return "\n".join(p.get("text", "") for p in parts)

    # ── storage ──────────────────────────────────────────────────────────

    def test_a_pdf_uploaded_from_the_skills_tab_is_a_sample(self):
        """The Skills tab sent `golden` and was refused anything but text."""
        for category in ("golden", "sample"):
            with self.subTest(category=category):
                out = call_route(
                    write_api, write_api.EtpAssessmentApiWrite(),
                    "generator_resource_upload", self.env,
                    path={"generator_id": self.gen.id},
                    name="examples.pdf", category=category,
                    content=base64.b64encode(PDF).decode())

                self.assertEqual(status_of(out), 200, out)
                self.assertEqual(out["data"]["resource"]["category"],
                                 "sample")

    def test_the_odoo_form_upload_on_the_skills_tab_is_a_sample(self):
        form = self.env["assessments.be.prompt"].new({"name": "x"})
        form.upload_golden_file = base64.b64encode(PDF)
        form.upload_golden_filename = "examples.pdf"

        self.assertFalse(form._onchange_upload_golden(), "nothing is refused")
        self.assertEqual(form.resource_ids.mapped("category"), ["sample"])
        self.assertFalse(form.upload_golden_file)

    def test_no_new_golden_row_is_ever_written(self):
        res = self._attach("a.md", "golden")
        self.assertEqual(res.category, "sample")
        res.write({"category": "golden"})
        self.assertEqual(res.category, "sample")

    def test_init_moves_golden_rows_to_sample_idempotently(self):
        legacy = self._legacy_golden("old.md")
        sop = self._attach("the_sop.md", "sop")

        for _run in range(2):
            self.Res.init()
            self.env.cr.execute(
                "SELECT id, category FROM assessments_be_prompt_resource "
                "WHERE id IN %s", (tuple((legacy | sop).ids),))
            self.assertEqual(dict(self.env.cr.fetchall()),
                             {legacy.id: "sample", sop.id: "sop"})

    def test_golden_stays_a_legal_value_for_old_rows_and_clients(self):
        codes = {c for c, _l in self.Res._fields["category"].selection}
        self.assertIn("golden", codes)
        self.assertIn("golden", write_api._RESOURCE_CATEGORIES)

    def test_a_markdown_file_is_extracted(self):
        """`.markdown` passed the old golden gate and then failed extraction,
        so the row was silently dropped from every call."""
        res = self._attach("notes.markdown", "sample")

        self.assertFalse(res.extraction_error)
        self.assertIn("Sharp and Clear", res.extracted_text or "")
        self.assertEqual(res.status, "ready")

    # ── what the model is sent ───────────────────────────────────────────

    def test_generation_sends_every_file_as_a_sample_and_no_golden_heading(
            self):
        self._attach("the_sop.md", "sop", body="# The SOP\n\nDo the thing.")
        self._attach("new.md", "sample")
        self._legacy_golden("old.md")
        self._attach("scan.pdf", "sample", body=PDF)

        with patch.object(vertex, "_call_vertex", return_value="[]") as call:
            vertex.generate_questions_from_sop(self.env, self.gen, report={})

        parts = call.call_args_list[0].kwargs["user_parts"]
        text = self._texts(parts)
        self.assertNotIn("GOLDEN", text)
        self.assertIn("SAMPLE QUESTIONS (match this format)", text)
        self.assertIn("SAMPLE QUESTION FILE (new.md)", text)
        self.assertIn("SAMPLE QUESTION FILE (old.md)", text)
        self.assertEqual(
            sum(1 for p in parts if p.get("inlineData")), 1,
            "the PDF sample travels natively")

    def test_draft_from_sop_reads_the_same_list_with_rule_9(self):
        self._attach("the_sop.md", "sop", body="# The SOP\n\nDo the thing.")
        self._attach("new.md", "sample")
        self._attach("scan.pdf", "sample", body=PDF)

        with patch.object(vertex, "_call_vertex", return_value=(
                '{"name": "T", "response": "single_choice", "sections": []}'
        )) as call:
            vertex.draft_task_template_from_sop(self.env, self.gen)

        parts = call.call_args.kwargs["user_parts"]
        text = self._texts(parts)
        self.assertIn("GOLDEN EXAMPLE (new.md)", text)
        self.assertIn("9. GOLDEN EXAMPLES are worked examples", text)
        inline = [p["inlineData"] for p in parts if p.get("inlineData")]
        self.assertEqual([d["mimeType"] for d in inline], ["application/pdf"])
        self.assertEqual(base64.b64decode(inline[0]["data"]), PDF)

    def test_a_sample_is_never_also_sent_as_the_sop(self):
        self._legacy_golden("old.md")
        self._attach("new.md", "sample")

        self.assertEqual(_sop_doc_parts(self.gen.resource_ids), [])
        self.assertEqual(len(_sample_doc_parts(self.gen)), 2)
