# -*- coding: utf-8 -*-
"""The JSON template route, over real HTTP.

HttpCase, DELIBERATELY, against this suite's house style. Every other API test
here is a TransactionCase that asserts on the serializer or the model the route
delegates to, because that keeps the assertion about behaviour and the suite
fast. This file is the exception because the thing under test IS the transport:

`API_TYPE` is `json2`, and Odoo's `Json2Dispatcher` sets
`request.params = jsonrequest | args` (`odoo/http.py:2613`) - the JSON body
merged with the PATH parameters. THE QUERY STRING IS NOT IN THERE. A route that
reads `?flavor=` through `str_arg` alone therefore answers every request with its
default, with a 200 and no error anywhere; that is exactly what this route did on
its first pass, and it was found in a browser rather than by a test. No
in-process test can see it, so the guard has to speak HTTP.

`docs/ETP_KNOWLEDGE_BASE.md (4.1 The JSON question-bank import contract)` publishes the query-string form, which makes it a
contract rather than a convenience.
"""
import base64
import json

from odoo.tests import tagged
from odoo.tests.common import HttpCase

from ..services import bank_json_template as json_template

_URL = "/api/v1/bank/template/json"
_JSON = {"Content-Type": "application/json"}


@tagged("-at_install", "post_install")
class TestTheJsonTemplateRouteReadsItsFlavour(HttpCase):

    def _get(self, query=""):
        response = self.url_open(_URL + query, headers=_JSON, timeout=30)
        return response.status_code, response.json()

    def _content(self, payload):
        return base64.b64decode(payload["data"]["content"])

    def test_the_query_string_selects_the_flavour(self):
        """The published URL form. Both flavours, distinguished by their BYTES -
        the filename alone would not catch a route that labelled one and served
        the other."""
        self.authenticate("admin", "admin")

        expected = {
            flavor: json_template.template_json(flavor, env=self.env)
            for flavor in json_template.FLAVORS
        }
        for flavor, (filename, content) in expected.items():
            status, payload = self._get("?flavor=%s" % flavor)
            self.assertEqual(status, 200, payload)
            self.assertEqual(payload["data"]["filename"], filename)
            self.assertEqual(
                self._content(payload), content,
                "?flavor=%s did not return the %s template - the query string "
                "is not reaching the route" % (flavor, flavor))

        # And the two are actually different files, so the assertion above is
        # not passing on two copies of the same bytes.
        self.assertNotEqual(expected["harness"][1], expected["native"][1])

    def test_no_flavour_defaults_to_harness_and_a_wrong_one_is_named(self):
        self.authenticate("admin", "admin")

        status, payload = self._get()
        self.assertEqual(status, 200, payload)
        self.assertEqual(
            self._content(payload),
            json_template.harness_template_json()[1],
            "the default is the harness template - it is the path with no "
            "exporter, so it is the one an operator cannot get any other way")

        status, payload = self._get("?flavor=csv")
        self.assertEqual(
            status, 422,
            "an unknown flavour must be refused, not silently defaulted")
        self.assertIn("harness", json.dumps(payload),
                      "the refusal has to name the flavours that do exist")

    def test_the_body_form_still_works_for_a_json_caller(self):
        """A client that posts a JSON body must not have to move the parameter
        into the URL - `str_arg` is still read first."""
        self.authenticate("admin", "admin")

        response = self.url_open(
            _URL, headers=_JSON, timeout=30,
            data=json.dumps({"flavor": "native"}))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            self._content(response.json()),
            json_template.native_template_json(self.env)[1])

    def test_a_caller_without_admin_is_refused(self):
        """THE AUTH RUNG, asserted rather than assumed. `@require_manager` is the
        same gate `/api/v1/bank/template` (the CSV one) carries; a template
        publishes the import contract of an admin-only importer, so it must not
        be readable by someone who cannot call the importer."""
        password = "Str0ng-Test-Pass!"
        self.env["res.users"].sudo().create({
            "name": "No Rights",
            "login": "no-rights-template-test",
            "password": password,
            # `group_ids` on Odoo 19 - `groups_id` is the pre-19 name and would
            # be silently ignored, creating a user with NO groups at all, which
            # would refuse for the wrong reason.
            "group_ids": [(6, 0, [self.env.ref("base.group_user").id])],
        })
        self.authenticate("no-rights-template-test", password)

        status, payload = self._get("?flavor=harness")
        self.assertEqual(status, 403, payload)
