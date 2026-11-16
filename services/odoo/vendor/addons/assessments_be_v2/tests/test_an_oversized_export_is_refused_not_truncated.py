"""An export too big to send must be REFUSED, not truncated in flight.

THE DEFECT, reported from stage after the 573-candidate Form Studio run: pressing
Export Responses produced

    net::ERR_CONTENT_LENGTH_MISMATCH

six times over, and the app's own banner blamed CORS - "Could not reach the
server ... a route the running server does not know, or a CORS origin it has not
been told about". Neither was true. `ERR_CONTENT_LENGTH_MISMATCH` means the
server declared a Content-Length and then sent fewer bytes: the response was cut
short. The client cannot tell that apart from a refused origin, so it printed its
catch-all and sent everybody hunting the wrong thing.

THE CAUSE. `_export` checked the RAW csv against `MAX_EXPORT_BYTES` and then
shipped it base64-encoded inside a JSON envelope. Base64 is 4/3 the size, so the
bytes on the wire are ~1.37x the bytes that were checked:

    measured, 573 candidates x 35 questions = 20,055 answer rows at 888 B/row
        raw csv    17.0 MB   <- passes a 20 MB check
        base64     23.3 MB   <- what actually gets sent

So the export was admitted, built, encoded, and died in transit. The 20 MB
ceiling was really ~14.6 MB of CSV and nothing said so.

THE FIX checks the ENCODED length - the thing that is sent - and reports the raw
ceiling (`MAX_EXPORT_BYTES * 3/4`) so the refusal names a target an operator can
act on rather than a limit the export can silently exceed.

NOT FIXED HERE, and worth being explicit: the export is still built in memory
before it is measured, so a huge assessment still pays the build cost to be told
no. That is tracker SNo 150 ("stream the CSV exports or make them a job; move the
byte check off the post-hoc path") and it is a route-shape change. This is the
correctness half: a refusal instead of a broken download.
"""
import base64
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api.common import MAX_EXPORT_BYTES


@tagged("-at_install", "post_install")
class TestAnOversizedExportIsRefusedNotTruncated(TransactionCase):

    def setUp(self):
        super().setUp()
        self.controller = self._controller()

    @staticmethod
    def _controller():
        import inspect

        from odoo import http

        from ..controllers.api import write as write_api
        for _name, obj in vars(write_api).items():
            if (inspect.isclass(obj) and issubclass(obj, http.Controller)
                    and obj.__module__ == write_api.__name__
                    and hasattr(obj, "_export")):
                return obj()
        raise AssertionError("the write controller was not found")

    def _export(self, content):
        """Call the real `_export` with a fake request, as the routes do."""
        from ..controllers.api import common as api_common
        from ..controllers.api import write as write_api

        class _Req:
            def __init__(self, env):
                self.env = env
                self.params = {}

            def make_json_response(self, payload, headers=None, status=200):
                return {"__status": status, **payload}

        fake = _Req(self.env)
        with patch.object(api_common, "request", fake), \
                patch.object(write_api, "request", fake):
            return self.controller._export("export.csv", content)

    @staticmethod
    def _code(response):
        error = response.get("error")
        if isinstance(error, dict):
            return error.get("code")
        return response.get("code")

    # ── the boundary that was wrong ───────────────────────────────────

    def test_a_payload_that_only_fits_before_encoding_is_refused(self):
        """THE HEADLINE, and the exact size class that broke on stage.

        This CSV is under `MAX_EXPORT_BYTES` raw, so the old check admitted it -
        and over the limit once encoded, so it could never arrive. 17 MB raw
        against a 20 MB limit is precisely the 573-candidate export.
        """
        # Comfortably under the raw limit, comfortably over it encoded.
        raw = b"x" * int(MAX_EXPORT_BYTES * 0.85)
        self.assertLess(len(raw), MAX_EXPORT_BYTES,
                        "fixture: must pass the OLD raw check")
        self.assertGreater(len(base64.b64encode(raw)), MAX_EXPORT_BYTES,
                           "fixture: must exceed the limit once encoded")

        response = self._export(raw)

        self.assertEqual(
            self._code(response), "export_too_large",
            "an export that cannot be delivered was accepted - it will be "
            "truncated in flight and the browser will report "
            "ERR_CONTENT_LENGTH_MISMATCH")
        self.assertEqual(response.get("__status"), 413)

    def test_the_refusal_names_the_real_ceiling(self):
        """A limit the export can silently exceed is not a limit.

        The message must quote the RAW ceiling - what the operator's file may
        weigh - not `MAX_EXPORT_BYTES`, which is the wire budget and is 1.37x
        larger than any CSV that can use it.
        """
        raw = b"y" * int(MAX_EXPORT_BYTES * 0.9)
        response = self._export(raw)

        # `code` and `message` are nested under `error`; the **extra kwargs
        # `fail()` was given sit at the TOP level (`payload.update(extra)`).
        # Reading them from `error` returns None and reports a defect that is
        # not there - which is what a first version of this test did.
        error = response.get("error") or {}
        self.assertIn("MB", str(error.get("message", "")))
        raw_ceiling = (MAX_EXPORT_BYTES * 3) // 4
        self.assertEqual(
            response.get("limit"), raw_ceiling,
            "the refusal reports the wire budget as though it were the file "
            "limit, so an operator who trims to just under it is refused again")
        # Both figures are reported, so a caller can say why.
        self.assertEqual(response.get("bytes"), len(raw))
        self.assertGreater(response.get("encoded_bytes"), len(raw))

    # ── what must keep working ────────────────────────────────────────

    def test_an_ordinary_export_still_downloads(self):
        """The other half. A fix that refused everything would 'pass' the test
        above while breaking every export that works today.
        """
        raw = b"candidate,email,score\nAsha,asha@example.test,9\n"
        response = self._export(raw)

        self.assertTrue(response.get("ok"), "an ordinary export was refused")
        data = response.get("data") or {}
        self.assertEqual(data.get("filename"), "export.csv")
        self.assertEqual(data.get("mimetype"), "text/csv")
        self.assertEqual(
            base64.b64decode(data["content"]), raw,
            "the payload must round-trip exactly - an export that arrives "
            "corrupted is worse than one refused")

    def test_a_payload_that_fits_encoded_is_accepted(self):
        """The boundary from the other side: right up to the encoded limit is
        deliverable, and must not be refused.

        Without this the check could tighten to something arbitrary and nobody
        would notice until an export that used to work stopped.
        """
        # 70% of the wire budget once encoded - safely deliverable.
        raw = b"z" * int(MAX_EXPORT_BYTES * 0.70 * 3 / 4)
        self.assertLess(len(base64.b64encode(raw)), MAX_EXPORT_BYTES,
                        "fixture: must fit once encoded")

        response = self._export(raw)

        self.assertTrue(
            response.get("ok"),
            "an export that fits on the wire was refused")

    def test_an_empty_export_is_not_an_error(self):
        """A cohort with no answers yet produces a header-only file. That is a
        valid download, not a failure."""
        response = self._export(b"candidate,email,score\n")
        self.assertTrue(response.get("ok"))
