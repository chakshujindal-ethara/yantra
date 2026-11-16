# -*- coding: utf-8 -*-
"""ONE answer to "what may this account do here", and every gate asks it.

THE INVARIANT: this platform is for INTERNAL users. A portal account has no role
on it at all - not as a candidate, not as a viewer, not on the media routes. That
is a product rule, not an Odoo limitation.

THE BUG THAT MADE THIS NECESSARY. The invariant was spelled out independently at
four gates and they did not agree:

  * `admin_media` (x4 routes) asked `_is_internal()`. Correct while every
    candidate was a portal user; wrong the moment candidates became internal
    accounts, because from then on it admitted CANDIDATES to the admin media
    proxy and left `check_access` as the only thing between them and another
    cohort's question bank.
  * `exam_media._refused` admitted every internal user and only THEN compared
    identities. Candidates are internal, so the comparison was unreachable for
    every caller it was written for: candidate A signed in, holding candidate B's
    token, was admitted to B's exam media. Its docstring asserted "a caller who
    IS signed in as somebody else is still refused". It could not be.
  * `common.may_view_attempt` asked `has_group(GROUP_MANAGER)` - Admin only -
    which predates the read-only Manager rung and so excluded the exact role
    preview was written for.

Both halves are pinned here: the role function itself, and each gate that
consumes it. Pinning only the function would let a gate quietly stop calling it.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..constants import (
    GROUP_CANDIDATE, GROUP_MANAGER, GROUP_MANAGER_RESTRICTED,
    ROLE_CANDIDATE, ROLE_NONE, ROLE_STAFF,
)
from ..controllers import admin_media, exam_media


class _FakeRequest:
    """The slice of `odoo.http.request` these media routes touch."""

    def __init__(self, env):
        self.env = env

    def not_found(self):
        return _NOT_FOUND


_NOT_FOUND = object()


@tagged("-at_install", "post_install")
class TestAssessmentRoleLadder(TransactionCase):

    def setUp(self):
        super().setUp()
        self.Users = self.env["res.users"].sudo()

    # -- fixtures ---------------------------------------------------------

    def _user(self, *group_xmlids):
        """An account holding exactly the named groups and nothing else.

        `(6, 0, [...])` deliberately, not `(4, id)`: these fixtures are about
        what an account does NOT hold, so an additive write would let Odoo's
        default group set decide the answer instead of the test.
        """
        groups = [self.env.ref(x).id for x in group_xmlids]
        return self.Users.with_context(
            no_reset_password=True, mail_create_nosubscribe=True,
            mail_create_nolog=True, tracking_disable=True,
        ).create({
            "name": "Role fixture %s" % uuid4().hex[:6],
            "login": "role_%s@example.com" % uuid4().hex[:8],
            "group_ids": [(6, 0, groups)],
        })

    # -- group 1: the role function ---------------------------------------

    def test_the_public_user_has_no_role(self):
        public = self.env.ref("base.public_user")
        self.assertEqual(public._be_assessment_role(), ROLE_NONE)

    def test_a_portal_account_has_no_role(self):
        """THE PRODUCT RULE. Not "cannot hold the group" - has no role."""
        portal = self._user("base.group_portal")
        self.assertFalse(portal._is_internal(), "fixture check")
        self.assertEqual(portal._be_assessment_role(), ROLE_NONE)
        self.assertFalse(portal._be_is_staff())

    def test_an_internal_account_with_no_assessment_group_has_no_role(self):
        """"Assessment v2 Access = No" is what this asserts.

        This is the hole the ladder was built to close: candidate ability used to
        ride on `base.group_user`, which every employee in the instance holds, so
        "No" still let a person sit an exam.
        """
        employee = self._user("base.group_user")
        self.assertTrue(employee._is_internal(), "fixture check")
        self.assertEqual(employee._be_assessment_role(), ROLE_NONE)

    def test_the_candidate_group_makes_a_candidate(self):
        candidate = self._user(GROUP_CANDIDATE)
        self.assertTrue(candidate._is_internal(),
                        "Candidate implies base.group_user - candidates are "
                        "internal accounts on this platform")
        self.assertEqual(candidate._be_assessment_role(), ROLE_CANDIDATE)
        self.assertFalse(candidate._be_is_staff())

    def test_the_restricted_manager_is_staff(self):
        manager = self._user(GROUP_MANAGER_RESTRICTED)
        self.assertEqual(manager._be_assessment_role(), ROLE_STAFF)
        self.assertTrue(manager._be_is_staff())

    def test_an_admin_is_staff_without_the_ladder_being_enumerated(self):
        """Tested at the LOWEST rung on purpose.

        `has_group` resolves through `implied_ids` and Admin implies Manager, so
        the function never names Admin. A rung added above Manager later is staff
        for free - and a rung that forgets to imply Manager fails here.
        """
        admin = self._user(GROUP_MANAGER)
        self.assertEqual(admin._be_assessment_role(), ROLE_STAFF)

    def test_the_role_is_single_record(self):
        """A recordset answer would be a silent answer for the wrong row."""
        pair = self._user(GROUP_CANDIDATE) | self._user(GROUP_MANAGER)
        with self.assertRaises(ValueError):
            pair._be_assessment_role()

    # -- group 2: the admin media proxy asks for STAFF ---------------------

    def _admin_media_reaches_serve(self, user, route_name, *args):
        """(result, served) for one admin media route run as `user`.

        Calls `original_endpoint`, not the decorated attribute: `@http.route`
        wraps a `type="http"` endpoint in `route_wrapper`, which ends with
        `Response.load(result)` and would put the sentinel through werkzeug.
        """
        endpoint = getattr(
            admin_media.AssessmentsBeAdminMedia, route_name).original_endpoint
        controller = admin_media.AssessmentsBeAdminMedia()
        with patch.object(admin_media, "request",
                          _FakeRequest(self.env(user=user))), \
             patch.object(admin_media.AssessmentsBeAdminMedia,
                          "_serve_image", return_value="IMG") as img:
            result = endpoint(controller, *args)
        return result, img.called

    def test_a_candidate_is_refused_the_admin_media_proxy(self):
        """THE TIGHTENING. `_is_internal()` admitted candidates here, leaving
        `check_access` as the only guard between a candidate and another cohort's
        question bank."""
        question = self.env["assessments.be.question"].create({
            "name": "Q %s" % uuid4().hex[:6],
            "question_type": "image_label",
            "prompt": "Label it.",
        })
        image = self.env["assessments.be.question.image"].create({
            "question_id": question.id, "slot": "single", "label": "Plate",
        })
        candidate = self._user(GROUP_CANDIDATE)

        result, served = self._admin_media_reaches_serve(
            candidate, "serve_admin_question_image", image.id)

        self.assertIs(result, _NOT_FOUND,
                      "a candidate must not reach the ADMIN media proxy")
        self.assertFalse(served, "the gate must short-circuit, not discard")

    # -- group 3: exam media tells staff from candidate --------------------

    def _exam_refused(self, user, evaluator):
        controller = exam_media.AssessmentsBeExamMedia()
        with patch.object(exam_media, "request",
                          _FakeRequest(self.env(user=user))):
            return controller._refused(evaluator)

    def _attempt(self, candidate_user=None):
        """One roster row, optionally bound to `candidate_user`."""
        applicant = self.env["hr.applicant"].create({
            "partner_name": "Cand %s" % uuid4().hex[:6],
            "email_from": (candidate_user.login if candidate_user
                           else "cand_%s@example.com" % uuid4().hex[:6]),
            "be_candidate_user_id": candidate_user.id if candidate_user else False,
        })
        assessment = self.env["assessments.be"].create({
            "name": "Exam %s" % uuid4().hex[:6],
            "duration_minutes": 30,
        })
        return self.env["assessments.be.evaluator"].create({
            "assessment_id": assessment.id,
            "applicant_id": applicant.id,
            "access_token": str(uuid4()),
        })

    def test_a_public_caller_is_admitted_on_the_token(self):
        """LOAD-BEARING. An `<img>` tag carries no credential, and the Flutter
        client holds a bearer and no Odoo cookie - so a real candidate's own
        media requests arrive PUBLIC. Refusing here served black frames."""
        evaluator = self._attempt()
        self.assertFalse(
            self._exam_refused(self.env.ref("base.public_user"), evaluator))

    def test_staff_are_admitted_so_the_preview_works(self):
        evaluator = self._attempt()
        self.assertFalse(self._exam_refused(self._user(GROUP_MANAGER),
                                           evaluator))
        self.assertFalse(self._exam_refused(self._user(GROUP_MANAGER_RESTRICTED),
                                           evaluator))

    def test_the_bound_candidate_is_admitted(self):
        candidate = self._user(GROUP_CANDIDATE)
        evaluator = self._attempt(candidate_user=candidate)
        self.assertFalse(self._exam_refused(candidate, evaluator))

    def test_candidate_A_cannot_fetch_candidate_Bs_media(self):
        """THE DEAD CHECK, restored.

        Both are internal accounts, so the old `if _is_internal(): return False`
        admitted A to B's media outright and the identity comparison below it was
        unreachable code.
        """
        b = self._user(GROUP_CANDIDATE)
        a = self._user(GROUP_CANDIDATE)
        evaluator = self._attempt(candidate_user=b)

        self.assertTrue(
            self._exam_refused(a, evaluator),
            "candidate A holding candidate B's token must not reach B's exam "
            "media - this is the check that became unreachable when candidate "
            "accounts stopped being portal users")

    def test_a_portal_caller_is_refused_exam_media_outright(self):
        """Not even a token-bearing one. The platform is internal-only."""
        evaluator = self._attempt()
        self.assertTrue(self._exam_refused(self._user("base.group_portal"),
                                           evaluator))

    def test_an_internal_account_with_no_access_is_refused_exam_media(self):
        evaluator = self._attempt()
        self.assertTrue(self._exam_refused(self._user("base.group_user"),
                                           evaluator))

    # -- group 4: no gate re-derives the rule -----------------------------

    def test_no_gate_decides_this_for_itself(self):
        """The static invariant. Four copies is how they drifted.

        `_is_internal()` is still legitimate in two places, neither of them an
        access gate: `serializers` REPORTS it as a payload field, and
        `_deliver_invitation` uses it to decide whether to send a password-reset
        mail. Anything else CALLING it is a second definition of who may use this
        platform.

        PARSED, NOT GREPPED. A line filter cannot tell a call from prose, and
        every module here now discusses `_is_internal()` at length in its
        docstring explaining why it stopped calling it - so a text search reports
        the explanation as the offence. `ast` sees calls only.
        """
        import ast
        import inspect

        from ..controllers import admin_media as am
        from ..controllers import exam_media as em
        from ..controllers.api import common as api_common

        for module in (am, em, api_common):
            tree = ast.parse(inspect.getsource(module))
            called = {
                node.func.attr
                for node in ast.walk(tree)
                if isinstance(node, ast.Call)
                and isinstance(node.func, ast.Attribute)
            }
            self.assertNotIn(
                "_is_internal", called,
                "%s calls _is_internal() and so decides for itself what 'may "
                "use this platform' means. That is four copies again; ask "
                "_be_assessment_role() - see models/res_users.py."
                % module.__name__)
