# -*- coding: utf-8 -*-
"""D1 - the attempt flag write route, its audit trail, and who may call it.

HttpCase rather than this suite's usual TransactionCase, for two reasons that
are both about transport. The rung the route sits on is enforced by a decorator
that reads `request.env.user`, and `flagged` has to be distinguishable from
ABSENT in the JSON body - neither is observable by calling a Python function.

Two properties matter here and neither is "the field changed".

PATCH SEMANTICS. The flag and the remark are independent features that share
one route, so only the keys PRESENT in the body may be written. A call that
sends only `flagged` must leave the remark exactly as it was, and a call that
sends only `remark` must not touch the flag. The failure this prevents is
silent and unrecoverable: a UI that posts its own field alone would otherwise
blank somebody's written justification the moment they ticked a box.

THE TRAIL. Every raise and every clear leaves a dated entry on the ASSESSMENT's
chatter naming the candidate, because `assessments.be.evaluator` carries no
`mail.thread` of its own.
"""
import json
from uuid import uuid4

from odoo.tests import tagged
from odoo.tests.common import HttpCase

_JSON = {"Content-Type": "application/json"}
_MANAGER = "assessments_be_v2.group_assessment_manager"
_RESTRICTED = "assessments_be_v2.group_assessment_manager_restricted"


@tagged("-at_install", "post_install")
class _FlagRoute(HttpCase):

    def setUp(self):
        super().setUp()
        self.Applicant = self.env["hr.applicant"].sudo()
        self.Assessment = self.env["assessments.be"].sudo()
        self.Evaluator = self.env["assessments.be.evaluator"].sudo()
        self.Generator = self.env["assessments.be.prompt"].sudo()
        self.Users = self.env["res.users"].sudo()

    def _applicant(self, name="Aahan Trikha"):
        slug = uuid4().hex[:8]
        return self.Applicant.create({
            "partner_name": name,
            "email_from": "%s_%s@example.com" % (name.split()[0].lower(), slug),
        })

    def _assessment(self):
        gen = self.Generator.create({"name": "Gen %s" % uuid4().hex[:6]})
        return self.Assessment.create({
            "name": "A %s" % uuid4().hex[:6],
            "generator_id": gen.id,
        })

    def _attempt(self, name="Aahan Trikha", assessment=None):
        assessment = assessment or self._assessment()
        return self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": self._applicant(name).id,
        })

    def _post(self, evaluator, payload):
        response = self.url_open(
            "/api/v1/attempts/%s/flag" % evaluator.id,
            data=json.dumps(payload), headers=_JSON, timeout=30)
        return response.status_code, response.json()

    def _notes(self, evaluator):
        """The ASSESSMENT's chatter, oldest first.

        The attempt has no `mail.thread`, so the trail lives one level up -
        which is also why each entry has to name the candidate.
        """
        return self.env["mail.message"].sudo().search([
            ("model", "=", "assessments.be"),
            ("res_id", "=", evaluator.assessment_id.id),
            ("message_type", "in", ["comment", "notification"]),
        ], order="id asc")

    def _user(self, *group_xmlids):
        groups = [self.env.ref(x).id for x in group_xmlids]
        login = "d1_%s@example.com" % uuid4().hex[:8]
        user = self.Users.with_context(
            no_reset_password=True, mail_create_nosubscribe=True,
            mail_create_nolog=True, tracking_disable=True,
        ).create({
            "name": "D1 fixture", "login": login, "password": login,
            "group_ids": [(6, 0, groups)],
        })
        return user, login


class TestRaisingAndClearing(_FlagRoute):

    def test_a_flag_needs_no_reason(self):
        """It is a bare boolean, and that is the design.

        Demanding a justification before a flag can be raised is what leaves
        stale flags standing - the operator cannot phrase the sentence, so the
        concern goes unrecorded. The remark exists for the sentence, and it is
        optional on purpose.
        """
        self.authenticate("admin", "admin")
        attempt = self._attempt()

        status, payload = self._post(attempt, {"flagged": True})
        self.assertEqual(status, 200, payload)
        self.assertTrue(attempt.manual_flagged)
        self.assertFalse(attempt.manual_remark)

    def test_clearing_works(self):
        self.authenticate("admin", "admin")
        attempt = self._attempt()
        self._post(attempt, {"flagged": True})

        status, payload = self._post(attempt, {"flagged": False})
        self.assertEqual(status, 200, payload)
        self.assertFalse(attempt.manual_flagged)
        self.assertFalse(
            attempt.manual_flagged_by_id,
            "a cleared flag must not leave a stale 'raised by' beside it")
        self.assertFalse(attempt.manual_flagged_at)

    def test_an_empty_body_is_refused(self):
        """Neither key present changes nothing, so answering 200 would lie."""
        self.authenticate("admin", "admin")
        attempt = self._attempt()

        status, payload = self._post(attempt, {})
        self.assertEqual(status, 422, payload)

    def test_an_absent_flagged_key_is_not_read_as_false(self):
        """A body carrying only a remark must not clear a standing flag."""
        self.authenticate("admin", "admin")
        attempt = self._attempt()
        self._post(attempt, {"flagged": True})

        status, payload = self._post(attempt, {"remark": "Just a note."})
        self.assertEqual(status, 200, payload)
        self.assertTrue(
            attempt.manual_flagged,
            "omitting `flagged` must leave the standing flag alone, not clear "
            "it by defaulting to False")
        self.assertEqual(attempt.manual_remark, "Just a note.")

    def test_raising_stamps_who_and_when(self):
        self.authenticate("admin", "admin")
        attempt = self._attempt()

        status, payload = self._post(attempt, {
            "flagged": True,
            "remark": "Webcam showed a second person at 14:03."})
        self.assertEqual(status, 200, payload)

        self.assertTrue(attempt.manual_flagged)
        self.assertIn("second person", attempt.manual_remark)
        self.assertTrue(attempt.manual_flagged_by_id, "who raised it is recorded")
        self.assertTrue(attempt.manual_flagged_at, "and when")

        block = payload["data"]["candidate_flag"]
        self.assertTrue(block["flagged"])
        self.assertEqual(block["remark"],
                         "Webcam showed a second person at 14:03.")
        self.assertTrue(block["by"], "the response names the operator")
        self.assertEqual(payload["data"]["attempt_id"], attempt.id)

    def test_the_remark_is_returned_in_full(self):
        """A truncated justification is worse than none."""
        self.authenticate("admin", "admin")
        attempt = self._attempt()
        remark = "A. " * 300

        self._post(attempt, {"flagged": True, "remark": remark})
        self.assertEqual(
            attempt.manual_remark, remark.strip(),
            "the remark is stored whole, not clipped to a preview length")

    def test_an_over_long_remark_is_REFUSED_not_clipped(self):
        """The single most important edge case on this route.

        `str_arg(max_len=...)` truncates silently, which is right for a search
        term and wrong for a justification: the operator would be told the
        remark was saved while the end of their reasoning was dropped, and they
        cannot recover what the server threw away. Refusing is recoverable;
        clipping is not.
        """
        self.authenticate("admin", "admin")
        attempt = self._attempt()

        status, payload = self._post(attempt, {
            "flagged": True, "remark": "x" * 5001})
        self.assertEqual(status, 422, payload)
        self.assertFalse(
            attempt.manual_flagged,
            "a refused call must not half-apply the flag")
        self.assertFalse(attempt.manual_remark)

    def test_text_at_exactly_the_limit_is_accepted(self):
        """The bound is inclusive, or the message would name a limit that
        does not work."""
        self.authenticate("admin", "admin")
        attempt = self._attempt()

        status, payload = self._post(attempt, {
            "flagged": True, "remark": "x" * 5000})
        self.assertEqual(status, 200, payload)
        self.assertEqual(len(attempt.manual_remark), 5000)

    def test_a_non_boolean_flagged_is_read_as_the_operator_meant_it(self):
        """A JSON client may send the string "true" rather than a bool.

        Asserted rather than assumed because the ONE thing this route must
        never do is read a malformed raise as a clear.
        """
        self.authenticate("admin", "admin")
        attempt = self._attempt()

        status, _ = self._post(attempt, {"flagged": "true"})
        self.assertEqual(status, 200)
        self.assertTrue(
            attempt.manual_flagged,
            "a truthy non-bool must raise, not silently clear")

        # AND THE OTHER DIRECTION, which is the dangerous one. `bool("false")`
        # is True in Python, so a naive read would RAISE a flag on the exact
        # request that meant to withdraw one.
        status, _ = self._post(attempt, {"flagged": "false"})
        self.assertEqual(status, 200)
        self.assertFalse(
            attempt.manual_flagged,
            'the string "false" must clear the flag, not raise it')

        for falsey in ("0", "no", "off", False):
            self._post(attempt, {"flagged": True})
            self.assertTrue(attempt.manual_flagged, "fixture check")
            self._post(attempt, {"flagged": falsey})
            self.assertFalse(
                attempt.manual_flagged,
                "%r must clear the flag" % (falsey,))


class TestTheFlagAndTheRemarkAreIndependentOverTheWire(_FlagRoute):
    """PATCH semantics: only the keys present in the body are written."""

    def test_setting_the_flag_leaves_an_existing_remark_alone(self):
        self.authenticate("admin", "admin")
        attempt = self._attempt()
        self._post(attempt, {"remark": "Asked for a re-read of Q4."})

        status, payload = self._post(attempt, {"flagged": True})
        self.assertEqual(status, 200, payload)
        self.assertEqual(
            attempt.manual_remark, "Asked for a re-read of Q4.",
            "ticking the flag must not blank a remark the operator wrote "
            "separately - that is somebody's writing, destroyed silently")

    def test_clearing_the_flag_leaves_the_remark_alone(self):
        """The remark is the record of WHY, so a clear must not erase it."""
        self.authenticate("admin", "admin")
        attempt = self._attempt()
        self._post(attempt, {"flagged": True, "remark": "Impersonation"})

        self._post(attempt, {"flagged": False})
        self.assertFalse(attempt.manual_flagged)
        self.assertEqual(
            attempt.manual_remark, "Impersonation",
            "withdrawing the flag is not the same act as withdrawing what was "
            "written about the sitting")

    def test_setting_the_remark_leaves_the_flag_alone(self):
        self.authenticate("admin", "admin")
        attempt = self._attempt()
        self._post(attempt, {"flagged": True})

        self._post(attempt, {"remark": "Follow-up: reviewed the recording."})
        self.assertTrue(
            attempt.manual_flagged,
            "appending detail to a flagged attempt must not clear the flag")

    def test_a_remark_can_be_left_with_no_flag_at_all(self):
        """Most notes are not accusations, and must not read as one."""
        self.authenticate("admin", "admin")
        attempt = self._attempt()

        status, payload = self._post(
            attempt, {"remark": "Candidate reported a browser crash at 11:20."})
        self.assertEqual(status, 200, payload)
        self.assertFalse(attempt.manual_flagged)
        self.assertEqual(
            attempt.manual_remark,
            "Candidate reported a browser crash at 11:20.")

        block = payload["data"]["candidate_flag"]
        self.assertFalse(block["flagged"])
        self.assertEqual(
            block["remark"], "Candidate reported a browser crash at 11:20.",
            "an unflagged attempt still reports its remark, or a note would "
            "become invisible the moment the flag beside it was withdrawn")

    def test_an_empty_remark_clears_the_remark_and_not_the_flag(self):
        self.authenticate("admin", "admin")
        attempt = self._attempt()
        self._post(attempt, {"flagged": True, "remark": "first draft"})

        status, _ = self._post(attempt, {"remark": ""})
        self.assertEqual(status, 200)
        self.assertFalse(attempt.manual_remark)
        self.assertTrue(
            attempt.manual_flagged,
            "editing the note down to nothing is not withdrawing the flag")


class TestTheFlagIsPerAttemptOverTheWire(_FlagRoute):
    """The route-level half of the design, not just the model's."""

    def test_flagging_one_attempt_leaves_the_persons_other_one_clean(self):
        self.authenticate("admin", "admin")
        person = self._applicant("Two Sittings")
        first = self.Evaluator.create({
            "assessment_id": self._assessment().id, "applicant_id": person.id})
        second = self.Evaluator.create({
            "assessment_id": self._assessment().id, "applicant_id": person.id})

        status, _ = self._post(first, {"flagged": True, "remark": "on this one"})
        self.assertEqual(status, 200)

        second.invalidate_recordset()
        self.assertFalse(
            second.manual_flagged,
            "the same person on another assessment must not arrive flagged")
        self.assertFalse(second.manual_remark)


class TestTheTrail(_FlagRoute):

    def test_a_raise_and_a_clear_are_two_entries(self):
        self.authenticate("admin", "admin")
        attempt = self._attempt("Trailed")
        before = len(self._notes(attempt))

        self._post(attempt, {"flagged": True, "remark": "Saw something odd."})
        self._post(attempt, {"flagged": False})

        notes = self._notes(attempt)[before:]
        self.assertEqual(
            len(notes), 2,
            "a raise and a clear are two events, not one state")
        self.assertIn("Attempt flagged", notes[0].body)
        self.assertIn("Attempt flag cleared", notes[1].body)

    def test_the_entry_names_the_candidate(self):
        """The trail is on the ASSESSMENT, shared by the whole cohort, so an
        entry that did not say who it was about would be unreadable."""
        self.authenticate("admin", "admin")
        attempt = self._attempt("Named Person")
        before = len(self._notes(attempt))

        self._post(attempt, {"flagged": True})

        notes = self._notes(attempt)[before:]
        self.assertTrue(notes, "the raise must be recorded")
        self.assertIn("Named Person", notes[-1].body)

    def test_a_repeat_raise_writes_no_second_entry(self):
        self.authenticate("admin", "admin")
        attempt = self._attempt()
        self._post(attempt, {"flagged": True})
        after_first = len(self._notes(attempt))

        status, _ = self._post(attempt, {"flagged": True})
        self.assertEqual(status, 200)
        self.assertEqual(
            len(self._notes(attempt)), after_first,
            "a double-click converges on the same state and writes no second "
            "identical entry")

    def test_a_remark_alone_is_not_a_flag_event(self):
        """The trail records the FLAG. A note is not an accusation, and
        posting one to the shared assessment chatter would put an operator's
        working comment in front of the whole cohort's history."""
        self.authenticate("admin", "admin")
        attempt = self._attempt()
        before = len(self._notes(attempt))

        self._post(attempt, {"remark": "Nothing untoward, noting it anyway."})
        self.assertEqual(len(self._notes(attempt)), before)

    def test_the_chatter_route_can_read_the_assessment_trail(self):
        """`/api/v1/chatter/assessment/<id>` - the trail in both UIs."""
        self.authenticate("admin", "admin")
        attempt = self._attempt("Readable Person")
        self._post(attempt, {"flagged": True})

        response = self.url_open(
            "/api/v1/chatter/assessment/%s" % attempt.assessment_id.id,
            data=json.dumps({}), headers=_JSON, timeout=30)
        self.assertEqual(response.status_code, 200)
        body = json.dumps(response.json())
        self.assertIn(
            "Readable Person", body,
            "the assessment kind must carry the flag entries, or the audit "
            "trail this feature depends on is written and unreadable")


class TestTheRungBoundary(_FlagRoute):
    """3.8 - a read-only Manager sees flags and cannot set them."""

    def test_a_read_only_manager_is_refused(self):
        user, login = self._user("base.group_user", _RESTRICTED)
        attempt = self._attempt()
        self.authenticate(login, login)

        response = self.url_open(
            "/api/v1/attempts/%s/flag" % attempt.id,
            data=json.dumps({"flagged": True}),
            headers=_JSON, timeout=30)
        self.assertIn(response.status_code, (401, 403), response.text)
        self.assertFalse(
            attempt.manual_flagged,
            "the read-only rung must not be able to flag anybody")

    def test_a_read_only_manager_cannot_write_a_remark_either(self):
        """The remark is the same write, on the same rung."""
        user, login = self._user("base.group_user", _RESTRICTED)
        attempt = self._attempt()
        self.authenticate(login, login)

        response = self.url_open(
            "/api/v1/attempts/%s/flag" % attempt.id,
            data=json.dumps({"remark": "not mine to write"}),
            headers=_JSON, timeout=30)
        self.assertIn(response.status_code, (401, 403), response.text)
        self.assertFalse(attempt.manual_remark)

    def test_an_admin_is_allowed(self):
        user, login = self._user("base.group_user", _MANAGER)
        attempt = self._attempt()
        self.authenticate(login, login)

        status, payload = self._post(attempt, {"flagged": True})
        self.assertEqual(status, 200, payload)
        self.assertTrue(attempt.manual_flagged)
        self.assertEqual(attempt.manual_flagged_by_id, user)

    def test_an_unknown_attempt_is_a_404(self):
        self.authenticate("admin", "admin")
        response = self.url_open(
            "/api/v1/attempts/999999999/flag",
            data=json.dumps({"flagged": True}),
            headers=_JSON, timeout=30)
        self.assertEqual(response.status_code, 404)
