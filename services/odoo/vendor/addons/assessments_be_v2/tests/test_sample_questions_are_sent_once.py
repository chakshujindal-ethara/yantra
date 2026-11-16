"""A sample-questions file reaches the model ONCE.

WHY THIS EXISTS, AND WHY IT IS ITS OWN FILE. `test_golden_examples.py` pinned
exactly this property for golden examples, and its reasoning applies word for
word to sample questions - `_sample_doc_parts` sends them under their own
"SAMPLE QUESTIONS" heading, so `_sop_doc_parts` must not send them again. The
skip list simply never gained the second category, and nothing noticed, because
every test in that file asks about golden.

WHAT IT COST. A production generator could not run at all. Three SOP files
totalling 464 KB plus a 1.9 MB sample is ~617K tokens sent once - comfortably
inside Gemini's 1,048,576 ceiling. With the sample doubled it is ~1,115K, and
Vertex refuses the whole call with INVALID_ARGUMENT before any work happens. The
examiner trimmed the SOP from 3.3 MB to 440 KB and it still failed, because the
duplicate was always the larger half - and "Try Again" is deterministic, so the
run could never succeed.

The failure is silent in the way that matters: nothing in the request is
malformed, the file is simply in the payload twice, and the only symptom is a
raw Vertex error in the banner.

Golden examples have since become sample questions (one list, owner
2026-09-29; test_golden_questions_are_sample_questions), so the sample block is
the only one left beside the SOP.
"""
import base64
from unittest.mock import patch

from odoo.tests.common import TransactionCase
from odoo.tools import mute_logger

from ..services.vertex import _sample_doc_parts, _sop_doc_parts


SAMPLE_MD = """# Sample questions

1. Is the picture sharp and clear?  Yes
2. Does the picture have a watermark?  No
"""


class TestSampleQuestionsAreSentOnce(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Prompt = self.env["assessments.be.prompt"]
        self.Res = self.env["assessments.be.prompt.resource"]
        self.gen = self.Prompt.create({"name": "sample probe"})

    def _attach(self, name, category, body=SAMPLE_MD):
        return self.Res.create({
            "prompt_id": self.gen.id,
            "name": name,
            "category": category,
            "file": base64.b64encode(body.encode()).decode(),
        })

    def test_a_sample_file_is_not_also_sent_as_a_sop_document(self):
        """THE BUG. Paying twice is the cheap half; exceeding the model's input
        ceiling and failing every run is the expensive half."""
        self._attach("ig-entity.md", "sample")

        self.assertEqual(
            _sop_doc_parts(self.gen.resource_ids), [],
            "the sample file must not appear in the SOP block as well")

    def test_it_still_reaches_the_model_under_its_own_heading(self):
        """Excluding it from one block must not drop it from the request."""
        self._attach("ig-entity.md", "sample")

        parts = _sample_doc_parts(self.gen)

        self.assertEqual(len(parts), 1)
        self.assertIn("SAMPLE QUESTION FILE (ig-entity.md)", parts[0]["text"])
        self.assertIn("sharp and clear", parts[0]["text"])

    def test_the_sop_beside_it_is_unaffected(self):
        self._attach("the_sop.md", "sop", body="# The SOP\n\nDo the thing.")
        self._attach("ig-entity.md", "sample")

        sop_parts = _sop_doc_parts(self.gen.resource_ids)

        self.assertEqual(len(sop_parts), 1)
        self.assertIn("SOP DOCUMENT (the_sop.md)", sop_parts[0]["text"])

    def test_the_payload_carries_each_file_exactly_once(self):
        """The property stated over the WHOLE request rather than per helper.

        A future third block that forgets the same exclusion fails here even if
        both helpers above still look correct on their own.
        """
        self._attach("the_sop.md", "sop", body="# The SOP\n\nDo the thing.")
        self._attach("examples.md", "golden", body="# Worked\n\nA")
        self._attach("ig-entity.md", "sample")

        def as_text(part):
            """One part's content, however it travelled.

            An extracted part carries prose; an inline part carries base64 of
            the file. Decoding here is what lets the count below be about the
            DOCUMENT rather than about the encoding it happened to get.
            """
            if part.get("text"):
                return part["text"]
            data = (part.get("inlineData") or {}).get("data", "")
            try:
                return base64.b64decode(data).decode("utf-8", "replace")
            except Exception:  # noqa: BLE001 - a part we cannot read counts as none
                return ""

        blob = "".join(as_text(p)
                       for p in (_sop_doc_parts(self.gen.resource_ids)
                                 + _sample_doc_parts(self.gen)))

        for name, body in (("the_sop.md", "Do the thing"),
                           ("examples.md", "Worked"),
                           ("ig-entity.md", "sharp and clear")):
            self.assertEqual(
                blob.count(body), 1,
                "%s reached the model %d times, not once"
                % (name, blob.count(body)))


    @mute_logger("odoo.addons.assessments_be_v2.models.prompt")
    def test_a_docx_sample_reaches_the_model_as_TEXT(self):
        """THE REGRESSION THE DEDUPE CAUSED, and the reason every fixture in
        this file being `.md` was a problem rather than a detail.

        `_sop_doc_parts` was the only place that ran `_extract_text` on a sample,
        so excluding samples from it deleted the readable copy and left only the
        `inlineData` one. For a `.docx` those raw bytes are a ZIP container, and
        `_SOP_MIME_BY_EXT` has no `docx` entry, so it went out labelled
        `text/plain`: unreadable, and still billed.

        `.md` cannot catch it - it IS in the mime map, so it reads correctly
        either way.
        """
        res = self._attach("samples.docx", "sample")
        # `_extract_text` is the seam; the point is that it is CONSULTED, not
        # that this test can build a real docx.
        with patch.object(type(res), "_extract_text",
                          return_value=("Q1. Is it sharp?", None)):
            parts = _sample_doc_parts(self.gen)

        self.assertEqual(len(parts), 1)
        self.assertIn("text", parts[0],
                      "a text format must be extracted, not sent as base64")
        self.assertIn("Q1. Is it sharp?", parts[0]["text"])
        self.assertIn("samples.docx", parts[0]["text"])

    def test_a_pdf_sample_is_still_sent_inline(self):
        """Extraction is for TEXT formats. A PDF has no text part to make and
        Gemini reads it natively, so it must keep travelling as inlineData."""
        self._attach("samples.pdf", "sample", body="%PDF-1.4 fake")

        parts = _sample_doc_parts(self.gen)

        self.assertEqual(len(parts), 1)
        self.assertTrue(parts[0].get("inlineData"))

    def test_a_generator_holding_only_samples_can_still_generate(self):
        """The guard in `generate_questions_from_sop` used to be satisfied by a
        sample file, because `_sop_doc_parts` returned one. Excluding samples
        narrowed it silently, and a generator carrying only sample questions
        began refusing a run it had been doing.

        Asserted on the guard's own inputs rather than by calling the route,
        which would need a live Vertex.
        """
        self._attach("samples.md", "sample")

        self.assertEqual(_sop_doc_parts(self.gen.resource_ids), [])
        self.assertTrue(
            _sample_doc_parts(self.gen),
            "the sample is still sent - so 'nothing to generate from' is wrong")

    def test_no_category_is_sent_by_two_blocks(self):
        """Every category, against every block. The skip lists must partition.

        This is the check that would have caught it: `sample` was in the SOP
        block AND the sample block, and no test asked the question that way.
        """
        for category in ("sop", "reference", "sample", "golden", "vendor",
                         "client", "other"):
            self.gen.resource_ids.unlink()
            self._attach("f.md", category)

            blocks = {
                "sop": bool(_sop_doc_parts(self.gen.resource_ids)),
                "sample": bool(_sample_doc_parts(self.gen)),
            }
            self.assertLessEqual(
                sum(blocks.values()), 1,
                "%r is sent by more than one block: %s"
                % (category, [k for k, v in blocks.items() if v]))
