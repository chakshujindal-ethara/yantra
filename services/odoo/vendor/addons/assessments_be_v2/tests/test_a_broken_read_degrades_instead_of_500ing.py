# -*- coding: utf-8 -*-
"""Two reads that used to fail loudly and say nothing useful.

G11 - an attachment whose filestore file is gone raised `FileNotFoundError` out
of `_to_http_stream`'s unguarded `os.stat`, and the web controller catches only
`UserError`, so it escaped as a 500. 1,054 such rows exist on production and
they produced 2,483 tracebacks and 5 hard 500s during the 753-candidate run.

G13 - `exam_media` answered five different faults with the same bare 404 and no
log line anywhere. A candidate saw a broken image mid-exam and support had
nothing to work from.

Neither changes what the caller receives. The placeholder and the 404 are the
correct answers; what was missing was surviving the first and explaining the
second.
"""
import os
from types import SimpleNamespace
from unittest.mock import patch
from uuid import uuid4

from odoo.exceptions import UserError
from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestAMissingFilestoreFileDoesNotRaise(TransactionCase):

    def _attachment(self):
        return self.env["ir.attachment"].create({
            "name": "guard-%s.png" % uuid4().hex[:6],
            "res_model": "res.partner",
            "res_id": self.env.user.partner_id.id,
            "raw": b"\x89PNG\r\n\x1a\n" + b"x" * 64,
        })

    def test_a_present_file_is_served_normally(self):
        """The guard must not fire on a healthy row, or every avatar in the
        instance becomes a placeholder.

        Driven through `_to_http_stream` under a real-shaped `request`, because
        that is the only configuration in which the guard runs at all: with
        `request` patched to None the whole branch is skipped and the test
        proves nothing about it.
        """
        attachment = self._attachment()
        if not attachment.store_fname:
            self.skipTest("this database stores attachments in the column")

        class _Req:
            db = self.env.cr.dbname

        # BOTH MODULES, because core's own `_to_http_stream` reaches for
        # `request.db` too and its `request` is a different binding of the same
        # proxy - unbound outside a real request, which is not the failure this
        # test is about.
        with patch("odoo.addons.assessments_be_v2.models.ir_attachment.request",
                   _Req()), \
                patch("odoo.addons.base.models.ir_attachment.request", _Req()):
            stream = attachment._to_http_stream()

        self.assertEqual(stream.type, "path",
                         "a healthy filestore row must still stream off disk")
        self.assertGreater(stream.size, 0)

    def test_a_missing_file_raises_the_error_the_caller_handles(self):
        attachment = self._attachment()
        if not attachment.store_fname:
            self.skipTest("this database stores attachments in the column")
        path = os.path.join(attachment._filestore(), attachment.store_fname)
        if os.path.exists(path):
            os.remove(path)

        class _Req:
            db = self.env.cr.dbname

        with patch("odoo.addons.assessments_be_v2.models.ir_attachment.request",
                   _Req()):
            with self.assertRaises(UserError):
                attachment._to_http_stream()

    def test_a_row_with_no_store_fname_is_left_alone(self):
        """`location = db` rows have no file to check and must not be touched.

        THE COLUMN IS CLEARED WITH SQL ON PURPOSE. `ir.attachment.write` pops
        `store_fname` out of its vals, so `attachment.store_fname = False` is a
        silent no-op that leaves a perfectly healthy filestore row behind - the
        row this test is named for was never being built.

        NOTHING IS SWALLOWED HERE EITHER. The failure this guards against is a
        crash on a row with no file (`safe_join(..., False)` raises TypeError,
        which `binary.py` does not catch and the candidate sees as a 500), so a
        bare `except Exception` would hide the one outcome worth detecting.
        """
        attachment = self._attachment()
        attachment.flush_recordset()
        self.env.cr.execute(
            "UPDATE ir_attachment SET store_fname = NULL WHERE id = %s",
            (attachment.id,))
        attachment.invalidate_recordset()
        self.assertFalse(attachment.store_fname)

        class _Req:
            db = self.env.cr.dbname

        with patch("odoo.addons.assessments_be_v2.models.ir_attachment.request",
                   _Req()):
            # Reaches super() rather than raising: there is no file to miss.
            stream = attachment._to_http_stream()

        self.assertEqual(
            stream.type, "data",
            "a row with no file must reach core untouched, not be refused for "
            "a missing file it never had")


@tagged("-at_install", "post_install")
class TestAnExamMedia404SaysWhyInTheLog(TransactionCase):
    """The response is unchanged; the diagnosis is what was added."""

    def _controller(self):
        from ..controllers import exam_media
        return exam_media.EtpExamMedia() if hasattr(
            exam_media, "EtpExamMedia") else None

    def test_the_helper_logs_a_reason_and_still_answers_404(self):
        from ..controllers import exam_media

        controller = None
        for name, obj in vars(exam_media).items():
            if isinstance(obj, type) and hasattr(obj, "_missing"):
                controller = obj
                break
        self.assertIsNotNone(controller, "the media controller was not found")

        class _Req:
            # `request` is a werkzeug LocalProxy, and letting mock autospec it
            # outside a request context evaluates the proxy and raises.
            @staticmethod
            def not_found():
                return "404"

        with patch.object(exam_media, "request", _Req()), \
                self.assertLogs(
                    "odoo.addons.assessments_be_v2.controllers.exam_media",
                    level="WARNING") as logged:
            answer = controller._missing("token does not resolve", "image", 7)

        self.assertEqual(answer, "404", "the wire answer must not change")
        line = "\n".join(logged.output)
        self.assertIn("token does not resolve", line)
        self.assertIn("kind=image", line)
        self.assertIn("id=7", line)

    def test_the_two_refusals_are_told_apart_in_the_log(self):
        """`_refused` reads IDENTITY ONLY - no state, no deadline, no expiry -
        so the single reason both of its refusing branches used to be given,
        "attempt is not live for this candidate", named a condition this module
        cannot detect at all. Support chasing it found a perfectly live attempt
        with 24 minutes left. Worse, it gave a candidate fetching ANOTHER
        candidate's paper the same label as a portal account wandering onto the
        route - the one security-relevant fault of the five, unalertable
        because it shared a string with a benign one.
        """
        from ..constants import ROLE_CANDIDATE, ROLE_NONE, ROLE_STAFF
        from ..controllers import exam_media

        controller = exam_media.AssessmentsBeExamMedia()

        class _User:
            def __init__(self, uid, public=False, role=ROLE_CANDIDATE):
                self.id, self._public, self._role = uid, public, role

            def _is_public(self):
                return self._public

            def _be_assessment_role(self):
                return self._role

        class _Evaluator:
            def __init__(self, owner):
                self._owner = owner

            def _candidate_user(self):
                return self._owner

        owner = _User(11)
        attempt = _Evaluator(owner)

        def _refused_as(user):
            with patch.object(
                    exam_media, "request",
                    SimpleNamespace(env=SimpleNamespace(user=user))):
                return controller._refused(attempt)

        self.assertFalse(_refused_as(owner),
                         "the candidate sitting this attempt must be let in")
        self.assertFalse(_refused_as(_User(12, role=ROLE_STAFF)),
                         "staff previewing a paper must be let in")
        self.assertFalse(_refused_as(_User(13, public=True)),
                         "an `<img>` tag carries no credential and is admitted "
                         "on the token")

        intruder = _refused_as(_User(12))
        no_role = _refused_as(_User(14, role=ROLE_NONE))

        self.assertTrue(intruder, "another candidate must still be refused")
        self.assertTrue(no_role, "a portal account must still be refused")
        self.assertNotEqual(
            intruder, no_role,
            "a candidate reading another candidate\'s paper and a portal "
            "account must not answer with one indistinguishable log line")
        for reason in (intruder, no_role):
            self.assertNotIn(
                "live", str(reason),
                "nothing in `_refused` tests whether the attempt is live, so "
                "no reason it gives may claim to: %r" % (reason,))

    def test_the_token_is_never_logged(self):
        """It is a live exam credential: anyone holding it can fetch that
        candidate's paper. `_missing` takes the evaluator, never the token, so
        no future caller can pass one in by accident."""
        import inspect

        from ..controllers import exam_media

        controller = None
        for name, obj in vars(exam_media).items():
            if isinstance(obj, type) and hasattr(obj, "_missing"):
                controller = obj
                break
        signature = inspect.signature(controller._missing)

        self.assertNotIn(
            "token", signature.parameters,
            "the reason logger must not be able to receive a token")
