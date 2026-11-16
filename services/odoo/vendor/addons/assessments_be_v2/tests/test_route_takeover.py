# -*- coding: utf-8 -*-
"""This addon owns the candidate portal paths it shares with upstream.

THE INCIDENT THIS PINS. `assessments_be_v2` forked the QWeb candidate portal
and kept its paths VERBATIM, so nine routes are declared byte-identically by
both this addon and `etp_assessment_pro`:

    /pro_assessment/<token>  (+ /begin /submit /review /answers /finish
                              /violation)
    /my/pro_assessments      /my/pro_dashboard

That is deliberate - invitation links already in candidates' inboxes have to
keep working - but it IS a collision, and for a while `__manifest__.py` claimed
the opposite ("there are no route collisions with upstream"). Anyone reading
the manifest to decide whether the two addons could coexist would have
concluded the surfaces were disjoint and skipped the check entirely.

WHY THE OWNERSHIP HOLDS, AND WHY THAT IS FRAGILE. Both are independent
`http.Controller` subclasses, so Odoo does not merge them; each registers its
own werkzeug rule. Insertion order is `mods = sorted(installed)`, and the
matcher returns the first rule it finds - so "assessments_be_v2" <
"etp_assessment_pro" is the entire reason this addon wins. That is an ordering
detail of two unrelated systems, resting on an alphabetical accident. It needs
a test, not a comment.

`test_no_upstream_routes` could never have caught this: it only checks that
media payloads point at routes this addon serves. It says nothing about who
answers a path both addons declare.

THE PAGES BEHIND THESE PATHS ARE NOW GONE, AND THIS FILE MATTERS MORE FOR IT.
The forked QWeb runner has been retired; `controllers/legacy_redirects.py`
declares the same nine paths and answers each with a redirect into the Flutter
client. Nothing in this file asserted that the endpoint RENDERED anything - only
which module the matcher dispatches into - so every assertion below is unchanged
and still exactly the property that has to hold.

It is also now the test that guards the retirement itself. Deleting the routes
outright, rather than replacing them with redirects, would hand all nine to
upstream SILENTLY: HTTP 200 with upstream's page, resolving a v2 token against
`etp_assessment_pro_evaluator` where it does not exist, rendering "invalid link"
with nothing in the log to correlate. That is precisely what
`test_v2_owns_every_candidate_route` fails on.

WHY TWO OF THE THREE TESTS READ SOURCE INSTEAD OF THE ROUTING MAP. A fresh
suite database installs `assessments_be_v2` ALONE - `etp_assessment_pro` is
uninstalled there, so its controllers are never imported and its rules never
reach `ir.http.routing_map()`. The two set-comparison tests below used to
`skipTest` on that, which reproduced in the guard the exact failure mode the
guard exists to catch: a green run that proves nothing. They almost certainly
never ran in CI. They now parse both addons' `controllers/` trees with `ast`
and need neither module installed, so they run on every database.

They lose nothing by it. What they assert - "which rule strings do the two
addons both DECLARE" - is a property of the source. Dispatch, the property that
genuinely needs a live routing map, is asserted by
`test_v2_owns_every_candidate_route`, which is unchanged and has always run.

IT DOES NEED `etp_assessment_pro` ON DISK, AND SAYS SO OUT LOUD. A missing
comparand is a FAILURE, not a skip. If a checkout or CI image has no
`etp_assessment_pro`, that is a fact about the image worth fixing, not worth
hiding.
"""
import ast
import os

from odoo.tests.common import TransactionCase, tagged

#: The nine paths both addons declare. Concrete URLs, because the point is to
#: exercise DISPATCH - which rule the matcher actually returns when two are
#: registered - not to compare rule strings, which would prove only that both
#: exist.
TAKEOVER_URLS = (
    ("/pro_assessment/tok-ownership-probe", "GET"),
    ("/pro_assessment/tok-ownership-probe/begin", "POST"),
    ("/pro_assessment/tok-ownership-probe/submit", "POST"),
    ("/pro_assessment/tok-ownership-probe/review", "GET"),
    ("/pro_assessment/tok-ownership-probe/answers", "GET"),
    ("/pro_assessment/tok-ownership-probe/finish", "POST"),
    ("/pro_assessment/tok-ownership-probe/violation", "POST"),
    ("/my/pro_assessments", "GET"),
    ("/my/pro_dashboard", "GET"),
)

#: The rule strings behind them, for the set comparison below.
EXPECTED_SHARED = {
    "/pro_assessment/<string:token>",
    "/pro_assessment/<string:token>/begin",
    "/pro_assessment/<string:token>/submit",
    "/pro_assessment/<string:token>/review",
    "/pro_assessment/<string:token>/answers",
    "/pro_assessment/<string:token>/finish",
    "/pro_assessment/<string:token>/violation",
    "/my/pro_assessments",
    "/my/pro_dashboard",
}

UPSTREAM = "etp_assessment_pro"

_HERE = os.path.dirname(os.path.abspath(__file__))
OUR_CONTROLLERS = os.path.normpath(os.path.join(_HERE, os.pardir, "controllers"))
PRO_CONTROLLERS = os.path.normpath(os.path.join(
    _HERE, os.pardir, os.pardir, UPSTREAM, "controllers"))


def _declared_routes(root):
    """Every rule string an addon's controllers declare, read from source.

    `@http.route` takes either a literal or a list of literals, in both addons
    (checked: no computed route strings anywhere in either tree). A non-literal
    appearing later would be silently invisible here, so it raises instead.
    """
    rules = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != "__pycache__"]
        for filename in sorted(filenames):
            if not filename.endswith(".py"):
                continue
            path = os.path.join(dirpath, filename)
            with open(path, encoding="utf-8") as handle:
                tree = ast.parse(handle.read(), path)
            for node in ast.walk(tree):
                if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    continue
                for dec in node.decorator_list:
                    if not isinstance(dec, ast.Call):
                        continue
                    func = dec.func
                    name = (func.attr if isinstance(func, ast.Attribute)
                            else getattr(func, "id", ""))
                    if name != "route":
                        continue
                    args = list(dec.args) + [
                        kw.value for kw in dec.keywords if kw.arg == "route"]
                    for arg in args:
                        items = (arg.elts
                                 if isinstance(arg, (ast.List, ast.Tuple, ast.Set))
                                 else [arg])
                        for item in items:
                            if not (isinstance(item, ast.Constant)
                                    and isinstance(item.value, str)):
                                raise AssertionError(
                                    "%s:%d declares a route from a non-literal; "
                                    "this sweep cannot see it. Inline the string "
                                    "or teach _declared_routes to resolve it."
                                    % (path, node.lineno))
                            rules[item.value] = "%s:%d" % (path, node.lineno)
    return rules


@tagged("-at_install", "post_install")
class TestRouteTakeover(TransactionCase):

    def _declared_rules(self):
        """Rule strings DECLARED by this addon and by upstream, from source.

        Not from the routing map: upstream is uninstalled on a fresh test
        database, so its rules are simply absent there. See the module
        docstring.
        """
        self.assertTrue(
            os.path.isdir(PRO_CONTROLLERS),
            "%s is not on disk at %s, so there is nothing to compare against "
            "and this guard would assert nothing. That is a fact about this "
            "checkout or CI image, not a reason to pass."
            % (UPSTREAM, PRO_CONTROLLERS))
        return (set(_declared_routes(OUR_CONTROLLERS)),
                set(_declared_routes(PRO_CONTROLLERS)))

    def test_v2_owns_every_candidate_route(self):
        """Whoever the matcher picks, it must be us - on all nine.

        Runs whether or not upstream is installed: with it absent there is a
        single registrant and this still asserts the routes exist and are ours,
        which is the other way this can regress.
        """
        adapter = self.env["ir.http"].routing_map().bind("localhost")
        for url, method in TAKEOVER_URLS:
            endpoint, _args = adapter.match(url, method=method)
            mod = getattr(
                getattr(endpoint, "func", endpoint), "__module__", "") or ""
            self.assertIn(
                "assessments_be_v2", mod,
                "%s %s dispatches into %r, not this addon. Candidates "
                "following an invitation link would land on upstream's portal, "
                "which resolves tokens against its own evaluator table."
                % (method, url, mod))

    def test_collision_set_never_grows(self):
        """A NEW shared path is a decision, and has to be made deliberately.

        The nine below were forked on purpose. A tenth appearing silently means
        someone added a route without noticing upstream already serves it, and
        which addon answers it would then be decided by module-name ordering.
        """
        ours, theirs = self._declared_rules()
        shared = ours & theirs
        unexpected = shared - EXPECTED_SHARED
        self.assertFalse(
            unexpected,
            "new route collision(s) with %s: %s. Either rename the route, or "
            "add it to EXPECTED_SHARED and say in __manifest__.py why this "
            "addon should win it." % (UPSTREAM, sorted(unexpected)))

    def test_every_expected_shared_path_is_still_shared(self):
        """Guard the guard.

        If upstream stops declaring these, `test_collision_set_never_grows`
        keeps passing while asserting nothing at all - so assert the premise
        rather than letting it rot into a no-op.
        """
        ours, theirs = self._declared_rules()
        self.assertEqual(
            EXPECTED_SHARED - ours, set(),
            "this addon no longer declares path(s) it is meant to own")
        self.assertEqual(
            EXPECTED_SHARED - theirs, set(),
            "upstream no longer declares path(s) this test assumes are "
            "contested; if upstream's portal is gone, this file and the "
            "manifest's takeover note can both be simplified")
