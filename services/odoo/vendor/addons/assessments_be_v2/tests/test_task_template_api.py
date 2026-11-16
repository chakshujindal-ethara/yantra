"""Task-template routes: the envelope, and who is allowed to CALL them.

THE SECURITY PROPERTY. A template carries the answer key for every item it
describes, so a candidate must never read one. These tests CALL each route as a
user who is not an assessment manager and assert the route answers 403 - and
call it again as a manager to prove the same route is not simply refusing
everybody, which is the failure mode a refusal-only test cannot see.

WHY THIS FILE WAS REWRITTEN. The three tests that used to stand here read each
route's SOURCE TEXT with the stdlib `inspect` module and searched it for the
string `"@require_manager"`. That is not an authorization test. What the stdlib
returns is a RAW LINE SLICE, from the first decorator to the end of the body, so
commenting the decorator out (`# @require_manager`) leaves those characters
inside the returned string and the assertion still passes with the route wide
open to any authenticated user. Turning `require_manager` into a no-op
passthrough defeats it just as completely. It was an authorization test with
zero authorization coverage, on routes that write. Nothing here reads source any
more, and nothing here should: a grep for the stdlib source reader in this file
must come back empty.

WHAT "STAFF" MEANS TODAY. `require_staff` and `require_manager` check the SAME
group - see the note on `require_staff` in `controllers/api/common.py` - so the
read/write split is a record of intent, not a difference a caller can observe.
The old test asserted "reading the library should not need a manager", which was
a claim about a decorator's NAME and was untrue of its behaviour: reading needs
a manager. What is pinned here is the property that actually matters, that no
non-manager reaches any of these routes.

HOW THE ROUTES ARE DRIVEN. `TransactionCase` plus a request stub, calling the
shipped controller methods - the pattern `test_admin_can_see_exam_media`,
`test_candidate_identity` and `test_an_archived_paper_is_out_of_the_cohort` use.
An `HttpCase` would need a bearer-token dance this suite has no helper for, and
would be testing werkzeug rather than the guard.

NO TEST HERE MAY SPEND. `task_template_draft` bills per press, so the paid call
is displaced by a stand-in that fails the test if anything reaches it, and the
draft route is exercised with an incomplete payload: a manager gets as far as
its 400, a non-manager never gets past the 403.

The Manager group is referenced by XML ID only, never by its label - the label
is being changed, and that is not the behaviour under test.
"""
from unittest.mock import patch
from uuid import uuid4

from odoo.tests.common import TransactionCase, tagged

from ..controllers.api import common as api_common
from ..controllers.api import task_templates as api

MANAGER_GROUP = "assessments_be_v2.group_assessment_manager"


class _Req:
    """The three things these routes and their helpers read off `request`.

    `env` for the ORM in the route bodies, `params` for `body()`/`int_arg()`/
    `str_arg()`, and `make_json_response` because `fail()` builds its envelope
    through it - which is where the 403 and the error code come from.
    """

    def __init__(self, env, params):
        self.env = env
        self.params = params

    def make_json_response(self, payload, headers=None, status=200):
        return {"__status": status, "__headers": dict(headers or []),
                **payload}


@tagged("-at_install", "post_install")
class TestTaskTemplateApiGuards(TransactionCase):

    #: Every route on the controller. Adding one without adding it here is the
    #: gap the old source-reading test was trying to cover, and the reason the
    #: refusal tests below loop over a list rather than naming one route.
    ROUTES = ("task_templates_list", "task_template_save",
              "task_template_draft", "task_template_cancel_draft",
              "task_template_delete")

    def setUp(self):
        super().setUp()
        self.Template = self.env["assessments.be.task.template"]
        self.controller = api.AssessmentsBeTaskTemplateApi()
        self.manager_group = self.env.ref(MANAGER_GROUP)
        # The manager env is the test's own su env with the group added, as in
        # test_an_archived_paper_is_out_of_the_cohort: the positive case is
        # here to prove admission, and running it as a non-superuser would drag
        # unrelated ACLs into an authorization test.
        self.env.user.group_ids = [(4, self.manager_group.id)]
        self.staff = self._user_without_the_group("base.group_user")
        self.candidate = self._user_without_the_group("base.group_portal")

    # ------------------------------------------------------------------
    # Fixtures
    # ------------------------------------------------------------------
    def _user_without_the_group(self, group_xmlid):
        """A real user who is NOT an assessment manager.

        Two shapes matter. An INTERNAL user (`base.group_user`) is a colleague
        with a console login and no assessment role - the accidental reader. A
        PORTAL user is the shape candidates are provisioned as, and is the one
        the answer keys have to be kept from.

        The group is removed explicitly rather than merely left unset: whatever
        `base.default_user` happens to carry on the database under test must not
        be able to turn this fixture into a manager and make every refusal below
        pass for the wrong reason.
        """
        user = self.env["res.users"].create({
            "name": "No-role %s" % uuid4().hex[:6],
            "login": "norole_%s@example.com" % uuid4().hex[:8],
            # `group_ids` in Odoo 19; `groups_id` was renamed.
            "group_ids": [(6, 0, [self.env.ref(group_xmlid).id])],
        })
        user.write({"group_ids": [(3, self.manager_group.id)]})
        self.assertFalse(
            user.has_group(MANAGER_GROUP),
            "fixture check: this user must not be an assessment manager")
        return user

    def _template(self, **vals):
        values = {"name": "Shape %s" % uuid4().hex[:6],
                  "response": "single_choice"}
        values.update(vals)
        return self.Template.create(values)

    # ------------------------------------------------------------------
    # Harness
    # ------------------------------------------------------------------
    def _call(self, env, method, **body):
        """Call the shipped route with a request stub.

        Both module bindings are patched: `task_templates.request` is what the
        route bodies read, `common.request` is what the decorators, the argument
        readers and `fail()` read. One proxy in production, two names here.
        """
        fake = _Req(env, dict(body))
        with patch.object(api, "request", fake), \
                patch.object(api_common, "request", fake):
            return getattr(self.controller, method)()

    @staticmethod
    def _status(response):
        """`ok()`/`paged()` return a bare dict (HTTP 200); `fail()` carries its
        status through the stub's `make_json_response`."""
        return response.get("__status", 200)

    @staticmethod
    def _no_llm():
        """Displace the paid drafting call for the duration of a block.

        `task_template_draft` bills once per press. Every path exercised here
        stops before it, so anything that reaches it means a guard is broken -
        and a broken guard must cost nothing.
        """
        def _never(*args, **kwargs):
            raise AssertionError(
                "the paid drafting call was reached - a test must never spend")

        return patch.object(
            api.vertex, "draft_task_template_from_sop", _never)

    def _payload(self, route):
        """A payload well formed enough that a refusal can only be the guard
        talking - a 400 would prove nothing about who may call the route.

        `draft` is the exception and is sent EMPTY on purpose: a real
        `generator_id` is the one input that reaches the billed model call, so
        no path in this file supplies one. It then answers 400 to a manager and
        403 to everyone else, which is the distinction being measured.
        """
        if route == "task_template_save":
            return {"template": {"name": "Sneaked in %s" % uuid4().hex[:6],
                                 "response": "free_text", "structure": []}}
        if route == "task_template_delete":
            return {"id": self._template().id}
        return {}

    def _assert_refused(self, user, route, **body):
        response = self._call(self.env(user=user), route, **body)
        self.assertEqual(
            self._status(response), 403,
            "%s admitted %s, who is not an assessment manager: %r"
            % (route, user.login, response))
        self.assertEqual(
            response.get("error", {}).get("code"), "forbidden", response)
        return response

    # ------------------------------------------------------------------
    # Nobody without the group gets in
    # ------------------------------------------------------------------
    def test_every_route_on_the_controller_is_covered_here(self):
        """A new route must not be able to arrive unguarded and untested.

        Discovered from the routing metadata Odoo attaches to each endpoint
        (`original_routing`, set by `http.route`), which is the live registry
        data - not the file's text. Adding a fifth route fails this until it is
        listed in `ROUTES`, and listing it puts it through every refusal test
        below. This is what the deleted source-reading test was reaching for and
        could not do: a decorator can be commented out without changing one
        character of the source slice, but it cannot be commented out without
        changing this metadata.
        """
        routed = sorted(
            name
            for name, attr in vars(api.AssessmentsBeTaskTemplateApi).items()
            if callable(attr) and (hasattr(attr, "original_routing")
                                   or hasattr(attr, "routing")))

        self.assertEqual(
            routed, sorted(self.ROUTES),
            "the template controller's routes and the list this file checks "
            "have drifted; an unlisted route is an unchecked route")

    def test_an_internal_user_without_the_role_is_refused_every_route(self):
        """A console login is not an assessment role. All four routes, 403."""
        with self._no_llm():
            for route in self.ROUTES:
                self._assert_refused(self.staff, route, **self._payload(route))

    def test_a_candidate_is_refused_every_route(self):
        """THE ONE THAT MATTERS. A template holds the answer key for every item
        it describes, and candidates are provisioned as portal users."""
        with self._no_llm():
            for route in self.ROUTES:
                self._assert_refused(
                    self.candidate, route, **self._payload(route))

    def test_the_guard_fires_before_the_payload_is_even_read(self):
        """A refusal must not depend on the request being well formed.

        `task_template_draft` answers 400 on a missing `generator_id` once you
        are inside it, so 403 rather than 400 is what proves the gate ran first -
        and it is what keeps a non-manager's call from ever reaching the billed
        model call.
        """
        with self._no_llm():
            self._assert_refused(self.candidate, "task_template_draft")
            self._assert_refused(
                self.staff, "task_template_save", template="not a dict")

    def test_a_refused_write_changes_nothing(self):
        """403 is a claim about the database, not about the response body.

        A guard that answered 403 after doing the work would satisfy the status
        assertions above and still have let a candidate archive the library.
        """
        name = "Never saved %s" % uuid4().hex[:6]
        self._assert_refused(
            self.candidate, "task_template_save",
            template={"name": name, "response": "free_text"})
        self.assertEqual(
            self.Template.search_count([("name", "=", name)]), 0,
            "a refused save stored a template anyway")

        victim = self._template()
        self._assert_refused(self.candidate, "task_template_delete",
                             id=victim.id)
        victim.invalidate_recordset(["active"])
        self.assertTrue(
            victim.active,
            "a refused delete archived the template anyway")

    # ------------------------------------------------------------------
    # A manager IS admitted, or the tests above would pass on a dead route
    # ------------------------------------------------------------------
    def test_a_manager_can_read_the_library(self):
        """Narrowed by `search` to this test's own row, so the assertion does
        not depend on what else the database holds."""
        tpl = self._template()

        response = self._call(self.env, "task_templates_list", search=tpl.name)

        self.assertEqual(self._status(response), 200, response)
        self.assertTrue(response.get("ok"), response)
        self.assertEqual(
            [row["id"] for row in response["data"]], [tpl.id], response)

    def test_a_manager_can_save_a_template(self):
        """The write half. A route that 403s everybody would pass every
        refusal test in this file and fail here."""
        name = "Saved by a manager %s" % uuid4().hex[:6]

        response = self._call(
            self.env, "task_template_save",
            template={"name": name, "response": "single_choice",
                      "structure": [{"id": "s", "title": "S", "items": []}]})

        self.assertEqual(self._status(response), 200, response)
        stored = self.Template.search([("name", "=", name)])
        self.assertEqual(len(stored), 1, "the manager's save must persist")
        self.assertEqual(response["data"]["id"], stored.id)

    def test_a_manager_reaches_the_draft_route(self):
        """Admitted, then refused on its own terms: 400 for the missing
        `generator_id` rather than 403 for the caller.

        The generator is deliberately not sent. Sending one would make this the
        only test in the suite that bills for a model call, and the point being
        made - that the gate let the manager through - is made by the 400.
        """
        with self._no_llm():
            response = self._call(self.env, "task_template_draft")

        self.assertEqual(self._status(response), 400, response)
        self.assertEqual(
            response.get("error", {}).get("code"), "bad_request", response)

    def test_a_vertex_429_is_a_503_busy_not_a_500(self):
        """Prod 2026-09-29: `VertexQuotaError` escaped this route and the
        generic handler answered 500 "Unexpected server error". Nothing is
        billed: the paid call is replaced by one that answers 429."""
        generator = self.env["assessments.be.prompt"].create(
            {"name": "Gen %s" % uuid4().hex[:6]})
        quota = api.vertex.VertexQuotaError(
            "Vertex quota exhausted [429]: RESOURCE_EXHAUSTED")
        with patch.object(api.vertex, "draft_task_template_from_sop",
                          side_effect=quota):
            response = self._call(self.env, "task_template_draft",
                                  generator_id=generator.id)

        self.assertEqual(self._status(response), 503, response)
        self.assertEqual(response["error"]["code"], "busy", response)
        self.assertEqual(response["__headers"].get("Retry-After"), "60")
        self.assertEqual(response["retry_after"], 60)
        self.assertNotIn("—", response["error"]["message"])

    # ------------------------------------------------------------------
    # What delete means
    # ------------------------------------------------------------------
    def test_delete_archives_rather_than_unlinks(self):
        """A launched assessment may cite a template; its questions are frozen.

        Asserted on the ROW: same id, still there, out of the picker. The old
        version of this test looked for the string `active = False` in the
        route's source and would have passed on a route that did nothing at all.
        """
        tpl = self._template()
        tpl_id = tpl.id

        response = self._call(self.env, "task_template_delete", id=tpl_id)

        self.assertEqual(self._status(response), 200, response)
        self.assertTrue(response["data"]["archived"], response)
        tpl.invalidate_recordset(["active"])
        self.assertTrue(
            tpl.exists(), "archived, not destroyed - a cited template's "
                          "provenance has to survive")
        self.assertEqual(tpl.id, tpl_id, "the same row, not a replacement")
        self.assertFalse(tpl.active)
        self.assertNotIn(tpl_id, self.Template.search([]).ids)

    def test_archiving_an_already_archived_template_is_success(self):
        """The client retries on a flaky network and must be able to converge."""
        tpl = self._template()
        tpl.active = False

        response = self._call(self.env, "task_template_delete", id=tpl.id)

        self.assertEqual(self._status(response), 200, response)
        tpl.invalidate_recordset(["active"])
        self.assertFalse(
            tpl.active, "a retry must not put the template back in the picker")

    # ------------------------------------------------------------------
    # The envelope (already behavioural - kept as it was)
    # ------------------------------------------------------------------
    def test_the_row_carries_what_the_designer_needs(self):
        """`structure` must use the designer's own key so the screen can reuse it."""
        tpl = self.env["assessments.be.task.template"].create({
            "name": "Shape",
            "response": "single_choice",
            "structure_json": [{"id": "s", "title": "S", "items": []}],
        })

        row = api._row(tpl)

        for key in ("id", "name", "response", "question_type", "structure",
                    "item_count", "authored_by", "origin", "updated_at"):
            self.assertIn(key, row)
        self.assertEqual(row["question_type"], "mcq")
        self.assertIsNone(row["origin"],
                          "no origin SOP is normal, not an error")

    def test_an_archived_template_leaves_the_picker(self):
        tpl = self.env["assessments.be.task.template"].create({
            "name": "Gone", "response": "free_text"})
        tpl.active = False

        self.assertNotIn(
            tpl.id,
            self.env["assessments.be.task.template"].search([]).ids)
        self.assertTrue(tpl.exists(), "archived, not destroyed")
