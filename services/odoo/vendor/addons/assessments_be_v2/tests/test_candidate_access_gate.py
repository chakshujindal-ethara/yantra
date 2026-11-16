# -*- coding: utf-8 -*-
"""Sitting an assessment requires the Candidate group, and nothing else grants it.

THE DEFECT. Nothing on the candidate path checked a group at all. `auth="user"`
means only "not the public user" (base/models/ir_http.py), and authorisation was
the exam token plus an integer identity match - `request.env.user.id ==
evaluator._candidate_user().id`. Candidate ability therefore rode on
`base.group_user`, which EVERY internal employee in the instance holds, so a
person whose "Assessment v2 Access" was set to No still sat exams. The privilege
existed, was visible on the user form, and decided nothing.

THE TEST THAT DID NOT EXIST, AND IS THE WHOLE REASON THAT SHIPPED, is
`test_an_employee_without_the_group_is_refused`: a signed-in user who is
correctly resolved as this attempt's candidate but holds no assessment group.
Every previous test in this suite built candidates with `base.group_user` or
`base.group_portal` and asserted they were ADMITTED, which was the intended
behaviour at the time - so the suite pinned the hole shut.

The other half is the grant. A gate nobody can pass is an outage, so
`_ensure_candidate_user` is asserted to grant the group at BOTH of its binding
points - the account it creates and the pre-existing account it links - and to
grant it ADDITIVELY, because an Admin who also sits an assessment must not be
demoted to Candidate by their own provisioning.

GROUPS ARE REFERENCED BY XMLID ONLY, through the constants the guards
themselves read. The labels moved in 19.0.3.17.0: "Manager" is now the READ-ONLY
role and "Admin" is the full-power one, while the full-power xmlid is still
`group_assessment_manager`. A test that said "Manager" would now be asserting
about the wrong role.

TransactionCase with a stubbed `request`, matching `test_candidate_identity` and
`test_an_empty_paper_is_broken_not_finished`: what changed is a branch in the
controller, not transport, and an HttpCase here would be testing werkzeug.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.exceptions import UserError
from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import candidate as cand_api
from ..controllers.api import common as CM


class _StubRequest:
    """The slice of `odoo.http.request` the candidate surface touches.

    `make_json_response` is what `common.fail` builds its non-200 envelope with,
    so the stub has to keep the STATUS as well as the body: 403-versus-200 is the
    whole assertion in half these tests, and a stub that returned only the
    payload would make a refusal indistinguishable from a success.
    """

    def __init__(self, env, params=None):
        self.env = env
        self.params = params or {}

    def make_json_response(self, payload, headers=None, status=200):
        return _StubResponse(payload, status)


class _StubResponse:
    """`status_code` is named as werkzeug names it, so the assertions read the
    same as they would against a real response."""

    def __init__(self, payload, status):
        self.payload = payload
        self.status_code = status

    def __repr__(self):
        return "<%s %r>" % (self.status_code, self.payload)


@tagged("-at_install", "post_install")
class TestCandidateAccessGate(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Applicant = self.env["hr.applicant"]
        self.Users = self.env["res.users"]
        self.Assessment = self.env["assessments.be"]
        self.Evaluator = self.env["assessments.be.evaluator"]
        self.controller = cand_api.EtpAssessmentApiCandidate()
        self.candidate_group = self.env.ref(CM.GROUP_CANDIDATE)

    # ------------------------------------------------------------------
    # Fixtures
    # ------------------------------------------------------------------
    def _email(self, slug="cand"):
        return "%s_%s@example.com" % (slug, uuid4().hex[:8])

    def _user(self, *group_xmlids, login=None):
        login = login or self._email()
        groups = [self.env.ref(x).id for x in group_xmlids]
        return self.Users.with_context(no_reset_password=True).create({
            "name": "User %s" % login,
            "login": login,
            "email": login,
            "group_ids": [(6, 0, groups)],
        })

    def _applicant(self, email, name="Asha Rao"):
        return self.Applicant.create({
            "partner_name": name,
            "email_from": email,
        })

    def _bound_attempt(self, user):
        """An attempt whose assigned candidate IS ``user``.

        Bound explicitly, so `is_assigned_candidate` resolves through the field
        the gate actually reads rather than through the address fallback.
        """
        applicant = self._applicant(user.login, name=user.name)
        applicant.be_candidate_user_id = user.id
        # Launched: a draft paper's token resolves to nothing at all.
        assessment = self.Assessment.create({
            "name": "Gate %s" % uuid4().hex[:6],
            "duration_minutes": 30, "state": "in_progress",
        })
        return self.Evaluator.create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
        })

    def _as(self, user, fn, params=None):
        """Run ``fn`` with `request` stubbed as ``user``.

        BOTH module bindings are patched. `candidate.request` is what the route
        bodies read; `common.request` is what `require_candidate`, `fail`,
        `is_assigned_candidate` and `resolve_applicant` read. They are the same
        proxy in production and two distinct names at import time, so patching
        one and not the other tests half the path.
        """
        stub = _StubRequest(self.env(user=user), params)
        with patch.object(cand_api, "request", stub), \
                patch.object(CM, "request", stub):
            return fn()

    def _write_guard_as(self, user, evaluator):
        # `begun=False`, as `/begin` calls it: these fixtures are never
        # started, and the gate under test is who may sit, not when.
        return self._as(user, lambda: self.controller._write_guard(
            evaluator, begun=False))

    def _assert_forbidden(self, response, message):
        self.assertIsNotNone(response, message)
        self.assertEqual(response.status_code, 403, message)
        self.assertEqual(response.payload["error"]["code"], "forbidden",
                         message)

    # ------------------------------------------------------------------
    # Guard the guard
    # ------------------------------------------------------------------
    def test_the_fixture_really_is_the_assigned_candidate(self):
        """Without this, the refusal below could be an identity failure.

        `_write_guard` returns 403 for a wrong candidate too - a different code,
        but the same status - so the fixture has to prove the identity check
        PASSES before the group check can be credited with the refusal.
        """
        user = self._user("base.group_user")
        evaluator = self._bound_attempt(user)

        self.assertEqual(
            evaluator._candidate_user(), user,
            "fixture: the gate must resolve this attempt to this user")
        self.assertFalse(
            user.has_group(CM.GROUP_CANDIDATE),
            "fixture: an ordinary employee must NOT hold the candidate group - "
            "if they do, the privilege is being granted by something else and "
            "the gate is decorative")

    # ------------------------------------------------------------------
    # THE HEADLINE: no group, no exam
    # ------------------------------------------------------------------
    def test_an_employee_without_the_group_is_refused(self):
        """"Assessment v2 Access = No" must actually mean no.

        This user is an employee (`base.group_user`, which every employee holds)
        and IS the candidate this attempt belongs to. Before 19.0.3.17.0 they
        passed every check on the write path and sat the exam.
        """
        user = self._user("base.group_user")
        evaluator = self._bound_attempt(user)

        response = self._write_guard_as(user, evaluator)

        self._assert_forbidden(
            response,
            "an employee with no assessment access still reached the exam "
            "write path: %r" % (response,))

    def test_the_same_person_passes_once_the_group_is_granted(self):
        """The positive control for the test above.

        Without this, `test_an_employee_without_the_group_is_refused` would also
        pass if the guard refused EVERYBODY - which is the more dangerous bug of
        the two, because it locks out every real candidate.
        """
        user = self._user("base.group_user")
        evaluator = self._bound_attempt(user)
        user.write({"group_ids": [(4, self.candidate_group.id)]})

        self.assertIsNone(
            self._write_guard_as(user, evaluator),
            "a candidate holding the candidate group must pass every gate")

    def test_an_admin_and_a_manager_both_pass_by_implication(self):
        """Neither role needs a separate grant.

        `has_group` resolves through `implied_ids`: Admin implies Manager implies
        Candidate. Asserted on both, and asserted to hold the group only
        TRANSITIVELY - a fixture that granted it directly would prove nothing
        about the ladder, which is what every other guard in the addon relies on.
        """
        for xmlid in (CM.GROUP_MANAGER, CM.GROUP_MANAGER_RESTRICTED):
            with self.subTest(group=xmlid):
                user = self._user(xmlid)
                evaluator = self._bound_attempt(user)

                self.assertNotIn(
                    self.candidate_group, user.group_ids,
                    "fixture: %s must not hold the candidate group directly, "
                    "or this is not testing implication" % xmlid)
                self.assertIn(
                    self.candidate_group, user.all_group_ids,
                    "%s must imply the candidate group" % xmlid)
                self.assertIsNone(
                    self._write_guard_as(user, evaluator),
                    "%s must reach the candidate surface without a separate "
                    "grant" % xmlid)

    # ------------------------------------------------------------------
    # /exam/<token>/state is auth="public" and must stay that way
    # ------------------------------------------------------------------
    def test_an_anonymous_caller_still_gets_the_login_gate(self):
        """A 403 here would be a regression for every candidate.

        `/state` is the route that TELLS an unauthenticated visitor to sign in;
        `login_required` is what puts the login screen in front of somebody who
        followed their invitation link, or whose session expired mid-exam.
        Refusing them instead would read as "your account is disabled".
        """
        candidate = self._user("base.group_user")
        candidate.write({"group_ids": [(4, self.candidate_group.id)]})
        evaluator = self._bound_attempt(candidate)
        public = self.env.ref("base.public_user")

        response = self._as(
            public, lambda: self.controller.exam_state(evaluator.access_token))

        self.assertTrue(
            isinstance(response, dict) and response.get("ok"),
            "an anonymous caller must get the gate envelope, not a refusal: "
            "%r" % (response,))
        self.assertEqual(response["data"]["outcome"], "login_required")

    def test_a_signed_in_caller_without_the_group_is_refused_on_state(self):
        """The other half of the same branch.

        Anonymous is told to sign in; SIGNED IN and not entitled is refused. The
        group check therefore has to sit between the public check and
        `may_view_attempt`, whose `wrong_candidate` payload names the invited
        candidate and their address - which an unentitled account must not read.
        """
        candidate = self._user("base.group_user")
        candidate.write({"group_ids": [(4, self.candidate_group.id)]})
        evaluator = self._bound_attempt(candidate)
        stranger = self._user("base.group_user")

        response = self._as(
            stranger,
            lambda: self.controller.exam_state(evaluator.access_token))

        self._assert_forbidden(
            response,
            "a signed-in account with no assessment access read an exam "
            "state: %r" % (response,))

    # ------------------------------------------------------------------
    # The /me/* routes
    # ------------------------------------------------------------------
    def test_the_my_assessments_route_refuses_an_ungrouped_user(self):
        """It used to answer 200 with an empty list to every employee."""
        user = self._user("base.group_user")

        response = self._as(user, self.controller.my_assessments)

        self._assert_forbidden(
            response, "an ungrouped employee reached /me/assessments: "
                      "%r" % (response,))

    def test_the_my_assessments_route_admits_a_candidate(self):
        """And the same account passes with the group, listing its own attempt."""
        user = self._user("base.group_user")
        user.write({"group_ids": [(4, self.candidate_group.id)]})
        self._bound_attempt(user)

        response = self._as(user, self.controller.my_assessments)

        self.assertTrue(
            isinstance(response, dict) and response.get("ok"),
            "a candidate must be able to list their own attempts: "
            "%r" % (response,))

    # ------------------------------------------------------------------
    # Provisioning grants the group at every binding point
    # ------------------------------------------------------------------
    def test_provisioning_grants_the_group_when_it_creates_the_account(self):
        applicant = self._applicant(self._email("fresh"), name="Fresh Start")

        self.assertEqual(
            self.Assessment._ensure_candidate_user(applicant), "created")

        user = applicant.be_candidate_user_id
        self.assertTrue(user, "provisioning must bind the account it made")
        self.assertIn(
            self.candidate_group, user.group_ids,
            "a freshly provisioned candidate must hold the candidate group")
        self.assertTrue(
            user._is_internal(),
            "the candidate group implies base.group_user, so the seat model is "
            "unchanged")

    def test_provisioning_grants_the_group_when_it_binds_an_existing_account(
            self):
        """THE PATH THAT HAD NO GROUP WRITE AT ALL.

        A pre-existing account was bound at `be_candidate_user_id` and given
        nothing. That is the ordinary case: an employee sitting an assessment,
        and anyone assigned from the user directory.
        """
        staff = self._user("base.group_user", login=self._email("staff"))
        applicant = self._applicant(staff.login, name="Staff Person")

        self.assertEqual(
            self.Assessment._ensure_candidate_user(applicant), "linked",
            "the status callers branch on must not change")

        self.assertEqual(applicant.be_candidate_user_id, staff)
        self.assertIn(
            self.candidate_group, staff.group_ids,
            "binding somebody as a candidate is the moment they become one, so "
            "it must grant the group")

    def test_provisioning_grants_the_group_to_an_already_bound_applicant(self):
        """The Assign-candidates picker's window.

        `_be_ensure_applicant_for_user` binds the applicant BEFORE the roster
        row exists, so launch reaches `_ensure_candidate_user` with the answer
        already "exists". An early return there leaves that candidate ungrouped
        and locked out of the exam they were just assigned.
        """
        user = self._user("base.group_user", login=self._email("picked"))
        applicant, created = self.Applicant._be_ensure_applicant_for_user(user)
        self.assertTrue(created and applicant.be_candidate_user_id == user,
                        "fixture: the picker must bind before launch")

        self.assertEqual(
            self.Assessment._ensure_candidate_user(applicant), "exists",
            "the status callers branch on must not change")

        self.assertIn(
            self.candidate_group, user.group_ids,
            "an already-bound candidate must still be granted the group")

    def test_the_grant_is_additive_and_never_demotes_an_admin(self):
        """`(4, id)`, not `(6, 0, [...])`.

        An operator who also sits an assessment is a real shape - it is how
        every launch gets smoke-tested - and a replace here would strip their
        Admin group and lock them out of the back office.
        """
        admin_group = self.env.ref(CM.GROUP_MANAGER)
        operator = self._user(CM.GROUP_MANAGER, login=self._email("operator"))
        applicant = self._applicant(operator.login, name="Operator Sitting")

        self.assertEqual(
            self.Assessment._ensure_candidate_user(applicant), "linked")

        self.assertIn(
            admin_group, operator.group_ids,
            "provisioning demoted an admin who was also a candidate")
        self.assertTrue(
            operator.has_group(CM.GROUP_MANAGER),
            "the admin must still satisfy every admin route guard")

    def test_a_portal_account_is_refused_rather_than_bound(self):
        """POLICY CHANGE, and this test used to assert the superseded one.

        It previously expected `"linked"`: bind the portal account, decline the
        group, log it, carry on. That left a candidate with a roster row, an
        invitation and a token, who was then refused at their own exam door - the
        silent-failure shape this whole area was being fixed for.

        The rule now is that this platform is INTERNAL-ONLY and a portal account
        is not a candidate. Reaching one by email match is refused before
        anything is written, while the operator can still act: the address is in
        the message and the launch has not emailed anybody.

        NOT CONVERTED. Promoting the account would change what it costs (a paid
        Odoo seat) and hand it the back office. That is a decision for a person.

        The separate legacy case - an applicant ALREADY bound to a portal account
        - deliberately does NOT raise, because a launch must not die for a whole
        cohort over one historical row. That is pinned in
        `test_a_portal_account_is_never_a_candidate.py`.
        """
        portal = self._user("base.group_portal", login=self._email("legacy"))
        applicant = self._applicant(portal.login, name="Legacy Portal")

        with self.assertRaises(UserError) as caught:
            self.Assessment._ensure_candidate_user(applicant)

        self.assertIn(portal.login, str(caught.exception))
        self.assertFalse(
            applicant.be_candidate_user_id,
            "nothing may be bound when the account is refused")
        portal.invalidate_recordset()
        self.assertNotIn(
            self.candidate_group, portal.all_group_ids,
            "a portal account cannot hold a group implying base.group_user")
        self.assertFalse(
            portal._is_internal(),
            "provisioning must not silently convert a portal account into a "
            "paid internal seat")
