# -*- coding: utf-8 -*-
"""The audit emitter produces one parseable line, carries no secret, and is
incapable of taking a sitting down with it.

WHY THIS FILE EXISTS. `services/audit.py` is called from the middle of the exam
runner - between reading a candidate's answer and storing it. Everything it
touches is cheap and cached, but "cheap and cached" is an assumption about the
ORM, not a guarantee: a record deleted under us, a value json cannot serialize,
or a future field rename all raise from inside the emitter. If any of those
propagated, an observability line would cost a candidate their answer, which is
strictly worse than having no line at all.

So there are exactly three properties worth a test, and they are the three
below: the line PARSES (a dashboard consumes it with `| json`, so a line that
is not valid JSON is not a degraded feature, it is no feature), the line
CARRIES NO CAPABILITY OR PII (the exam token is a bearer credential - anyone
holding it can sit the paper - and Loki is read by more people than the
database is), and a FAILURE INSIDE THE EMITTER IS SWALLOWED.
"""
import json
import logging
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from odoo.addons.assessments_be_v2.services import audit

AUDIT_LOGGER = "odoo.addons.assessments_be_v2.services.audit"


class _Exploding:
    """Stands in for an attempt whose row has gone. Reading anything about it
    raises, which is the shape of every realistic emitter failure."""

    @property
    def id(self):
        raise RuntimeError("row vanished mid-request")


@tagged("-at_install", "post_install")
class TestAuditLine(TransactionCase):

    def setUp(self):
        super().setUp()
        generator = self.env["assessments.be.prompt"].create({"name": "Gen"})
        self.assessment = self.env["assessments.be"].create({
            "name": "Audit probe",
            "generator_id": generator.id,
            "duration_minutes": 30,
        })
        self.applicant = self.env["hr.applicant"].create({
            "partner_name": "Audit Probe",
            "email_from": "auditprobe_%s@example.com" % uuid4().hex[:8],
        })
        self.evaluator = self.env["assessments.be.evaluator"].create({
            "assessment_id": self.assessment.id,
            "applicant_id": self.applicant.id,
        })

    def _emit(self, *args, **kwargs):
        """Emit once and hand back (raw line, parsed payload).

        `level=logging.INFO`, NEVER `level="INFO"`. Odoo runs
        `logging.addLevelName(25, "INFO")` for its RUNBOT level (netsvc.py),
        which overwrites the name->level map, so `getLevelName("INFO")` returns
        25 inside any Odoo process. `assertLogs(level="INFO")` therefore asks
        for >= 25 and silently drops every real `_logger.info` record at 20 -
        which is exactly how this assertion failed against a working emitter.
        """
        with self.assertLogs(AUDIT_LOGGER, level=logging.INFO) as caught:
            audit.emit(*args, **kwargs)
        self.assertEqual(len(caught.output), 1,
                         "one event must be exactly one line")
        line = caught.output[0]
        _, _, body = line.partition(audit.PREFIX)
        self.assertTrue(body, "the line must carry the %r grep anchor"
                              % audit.PREFIX)
        return line, json.loads(body)

    # ------------------------------------------------------------------
    # It emits
    # ------------------------------------------------------------------
    def test_an_event_is_one_parseable_json_line_with_the_ids_on_it(self):
        line, rec = self._emit(
            "exam.answer", self.evaluator, outcome="saved",
            t0=audit.start(), question=41, nav="stay")

        self.assertNotIn("\n", line, "a multi-line record is not greppable")
        self.assertEqual(rec["ev"], "exam.answer")
        self.assertEqual(rec["outcome"], "saved")
        self.assertEqual(rec["attempt"], self.evaluator.id)
        self.assertEqual(rec["assess"], self.assessment.id)
        self.assertEqual(rec["cand"], self.applicant.id)
        self.assertEqual(rec["question"], 41)
        self.assertEqual(rec["nav"], "stay")
        self.assertEqual(rec["pod"], audit.POD)
        self.assertIsInstance(rec["ts"], int)
        self.assertGreaterEqual(rec["ms"], 0)

    def test_an_error_signature_is_bounded_and_names_its_type(self):
        _, rec = self._emit("api.error", outcome="server_error",
                            error=ValueError("x" * 500))
        self.assertTrue(rec["err"].startswith("ValueError: "))
        self.assertLessEqual(len(rec["err"]), audit.MAX_ERR)

    # ------------------------------------------------------------------
    # It leaks nothing
    # ------------------------------------------------------------------
    def test_the_line_carries_neither_the_exam_token_nor_the_candidate(self):
        """The token is a bearer credential and the email is PII. Ids only."""
        line, rec = self._emit("exam.begin", self.evaluator,
                               outcome="started")
        self.assertTrue(self.evaluator.access_token, "no token to leak")
        self.assertNotIn(self.evaluator.access_token, line)
        self.assertNotIn(self.applicant.email_from, line)
        self.assertNotIn(self.applicant.partner_name, line)
        self.assertNotIn("justification", rec)

    # ------------------------------------------------------------------
    # It cannot break the sitting
    # ------------------------------------------------------------------
    def test_a_failure_inside_the_emitter_is_swallowed_not_raised(self):
        """The whole point of the file. Nothing here may reach the caller."""
        # A record that raises on attribute access - a row deleted under us.
        self.assertIsNone(audit.emit("exam.answer", _Exploding()))
        # A value json cannot serialize even with `default=str`. Unserializable
        # extras are the other way a caller breaks this by accident.
        circular = {}
        circular["self"] = circular
        self.assertIsNone(audit.emit("exam.answer", self.evaluator,
                                     blob=circular))

    def test_a_swallowed_failure_emits_no_info_line(self):
        """A broken emitter is broken on EVERY request, so it must not shout -
        a warning per answer save is the flood this feature exists to avoid."""
        with self.assertNoLogs(AUDIT_LOGGER, level=logging.INFO):
            audit.emit("exam.answer", _Exploding())
