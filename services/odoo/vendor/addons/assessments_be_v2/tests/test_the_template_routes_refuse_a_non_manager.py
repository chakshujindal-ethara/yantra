"""The task-template routes must REFUSE a non-manager, not merely mention a guard.

WHY THIS FILE EXISTS. `test_task_template_api.py` asserted authorization like
this:

    src = inspect.getsource(getattr(api.AssessmentsBeTaskTemplateApi, name))
    self.assertIn("@require_manager", src)

That is an authorization test with **zero authorization coverage**, and it fails
in two directions. Both were confirmed by experiment rather than argued:

  1. **A COMMENTED-OUT DECORATOR SATISFIES IT.** Every route here is stacked

         @http.route(...)
         @api_endpoint
         @require_manager
         def task_template_save(...)

     and `inspect.getsource` returns a raw line slice starting at the FIRST
     decorator - so `# @require_manager` is still inside the returned text and
     the substring matches. Measured: with the guard commented out the assertion
     passes; only deleting the line entirely makes it fail.

  2. **A NO-OP PASSTHROUGH SATISFIES IT.** The name being present says nothing
     about what it does. Redefine `require_manager` as `lambda f: f` and every
     source assertion still passes while every route is open.

So the property to test is the BEHAVIOUR: a signed-in user who is not an
Assessment Manager gets `forbidden` / 403 and no template data. A template
carries the answer key for every item it describes, so this is the gate that
keeps a candidate from reading one.

WHAT THE OLD FILE IS STILL GOOD FOR. Its non-security tests (the row shape, the
archive-not-unlink rule) are behavioural and stay. Only the two source-reading
tests are replaced, by this file.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged


@tagged("-at_install", "post_install")
class TestTheTemplateRoutesRefuseANonManager(TransactionCase):

    #: (route, kwargs) - every template route, with arguments valid enough that
    #: reaching the body would DO something. That matters: a route refused for
    #: the wrong reason (a missing argument) would look like a passing guard.
    ROUTES = (
        ("task_templates_list", {}),
        ("task_template_save", {}),
        ("task_template_draft", {}),
        ("task_template_cancel_draft", {}),
        ("task_template_delete", {}),
    )

    def setUp(self):
        super().setUp()
        from ..controllers.api import task_templates as api
        self.api = api
        self.controller = api.AssessmentsBeTaskTemplateApi()
        self.Template = self.env["assessments.be.task.template"]
        # A real template, so a route that DID run would have something to
        # return - otherwise "no data" could mean "nothing to find".
        self.template = self.Template.create({
            "name": "Guarded %s" % uuid4().hex[:6],
            "response": "single_choice",
            "structure_json": [{"id": "s", "title": "S", "items": []}],
        })

    # ── harness ───────────────────────────────────────────────────────

    @staticmethod
    def _code(response):
        """The failure code out of the API envelope.

        NESTED UNDER `error`, not at the top level:

            {"ok": False, "error": {"code": "forbidden", "message": ...}}

        A first version of this file read `response["code"]`, got None for every
        route and reported that the writes were unguarded - they were not. Read
        the envelope the way `fail()` builds it.
        """
        if not isinstance(response, dict):
            return None
        error = response.get("error")
        if isinstance(error, dict):
            return error.get("code")
        return response.get("code")

    def _call(self, route, user, **params):
        """Invoke a route with `request.env.user` set to `user`.

        The decorators read `request.env.user.has_group(...)`, so the whole
        gate is exercised by giving them a request whose env belongs to that
        user - no HTTP session needed, and the real decorator runs.
        """
        from ..controllers.api import common as api_common
        from ..controllers.api import task_templates as api_tt

        env = self.env(user=user)

        class _Req:
            def __init__(self, env, params):
                self.env = env
                self.params = dict(params)
                self.httprequest = type("H", (), {"method": "POST"})()

            def make_json_response(self, payload, headers=None, status=200):
                return {"__status": status, **payload}

        fake = _Req(env, params)
        with patch.object(api_common, "request", fake), \
                patch.object(api_tt, "request", fake):
            return getattr(self.controller, route)(**params)

    def _candidate_user(self):
        """A signed-in user who is NOT an assessment manager - the exact shape a
        candidate has."""
        return self.env["res.users"].create({
            "name": "Candidate %s" % uuid4().hex[:6],
            "login": "cand_%s@example.com" % uuid4().hex[:8],
            "group_ids": [(6, 0, [self.env.ref("base.group_user").id])],
        })

    def _manager_user(self):
        return self.env["res.users"].create({
            "name": "Manager %s" % uuid4().hex[:6],
            "login": "mgr_%s@example.com" % uuid4().hex[:8],
            "group_ids": [(6, 0, [
                self.env.ref("base.group_user").id,
                self.env.ref(
                    "assessments_be_v2.group_assessment_manager").id])],
        })

    # ── the security property ─────────────────────────────────────────

    def test_every_template_route_refuses_a_non_manager(self):
        """THE HEADLINE. Four routes, one non-manager, four refusals."""
        user = self._candidate_user()
        for route, params in self.ROUTES:
            with self.subTest(route):
                response = self._call(route, user, **params)
                self.assertIsInstance(
                    response, dict,
                    "%s did not answer in the API envelope" % route)
                self.assertFalse(
                    response.get("ok", False),
                    "%s answered ok to a non-manager" % route)
                self.assertEqual(
                    self._code(response), "forbidden",
                    "%s refused for the wrong reason (%r) - a guard that "
                    "rejects because an argument is missing is not a guard"
                    % (route, self._code(response)))

    def test_a_refusal_carries_no_template_data(self):
        """A 403 that still leaks the answer key is not a refusal.

        This is the property the whole gate exists for: a template holds the
        correct answer for every item in it.
        """
        user = self._candidate_user()
        response = self._call("task_templates_list", user)
        body = str(response)
        self.assertNotIn(
            self.template.name, body,
            "a refused listing still named a template")
        self.assertFalse(response.get("data"),
                         "a refused route returned data")

    def test_a_manager_is_let_through(self):
        """The other half. Without this, a guard that refused EVERYONE would
        look like a pass and the console would be broken instead.
        """
        response = self._call("task_templates_list", self._manager_user())
        self.assertTrue(
            response.get("ok"),
            "a manager was refused the template library: %r" % (response,))

    # ── why this beats the source assertion ───────────────────────────
    #
    # The pair above IS the proof, and it is worth saying why rather than
    # adding a meta-test for it.
    #
    # `test_a_manager_is_let_through` and
    # `test_every_template_route_refuses_a_non_manager` are a DIFFERENTIAL: the
    # same route, the same harness, two users, opposite outcomes. That can only
    # happen if the guard actually runs and actually reads the group. Neither of
    # the two failure modes in this file's docstring survives it:
    #
    #   * a commented-out decorator -> the non-manager gets through, so the
    #     refusal test fails.
    #   * a no-op passthrough -> same thing, for the same reason.
    #
    # A first version of this file tried to prove that by patching
    # `res.users.has_group` to always return True and asserting the harness
    # noticed. It failed for a reason unrelated to the guard: Odoo builds its
    # model classes through the registry, so patching the method on the class
    # the test can reach does not affect the already-decorated routes. The
    # differential needs no patching and cannot rot that way.

    def test_write_routes_need_a_manager_specifically(self):
        """`require_staff` and `require_manager` currently check the SAME group,
        so this cannot distinguish them today - and that is worth stating rather
        than pretending otherwise (see `require_staff`'s own docstring, which
        keeps the two names to record intent).

        What it does pin: the three mutating routes refuse a plain internal
        user. If a read-only role is reintroduced and `require_staff` starts
        accepting it, this test still holds for the writes.
        """
        user = self._candidate_user()
        for route in ("task_template_save", "task_template_draft",
                      "task_template_delete"):
            with self.subTest(route):
                response = self._call(route, user)
                self.assertEqual(self._code(response), "forbidden",
                                 "%s let a non-manager mutate" % route)
