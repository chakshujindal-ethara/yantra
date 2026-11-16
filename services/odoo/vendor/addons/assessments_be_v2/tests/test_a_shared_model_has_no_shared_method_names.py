# -*- coding: utf-8 -*-
"""Two addons on ONE model must not spell a member the same way.

THE DEFECT CLASS, for the third time in this codebase. Odoo composes a single
Python class per model out of every installed addon. Two methods with the same
name on the same model are therefore ONE method: whichever addon composes last
wins, the other is simply gone - and its `@api.constrains` / `@api.depends` /
`@api.onchange` trigger list goes with it. Nothing warns, nothing logs, and the
behaviour just stops. A field declared twice behaves the same way: the last
definition's `compute=` / `depends` is the one the ORM keeps.

It has now happened three times for real:

  1. `res.config.settings._check_llm_limits` - four settings range checks never
     ran on production for months. Renamed `_check_be_llm_limits`.
  2. `res.config.settings._onchange_vertex_sa_upload`,
     `_onchange_question_prompt_upload` and `_onchange_scoring_prompt_upload` -
     one addon's three Settings upload widgets stopped filling their text box as
     the file was picked. Renamed `_onchange_be_*` (the scoring one has since
     gone with the stored scoring prompt, W12). Less severe than (1) because
     `set_values` decodes the same uploads itself inside the Save transaction,
     so the upload still persisted; only the live in-form feedback was lost.
  3. `hr.applicant._compute_etp_result_donut_html` - see ALLOWED below. Found by
     this test's sweep, KNOWN AND STILL LIVE, deliberately not fixed yet.

WHY THIS TEST READS SOURCE INSTEAD OF ASKING THE REGISTRY, which is the whole
point and the reason the first two defects survived so long. A fresh suite
database installs `assessments_be_v2` ALONE - `etp_assessment_pro` is
uninstalled there, so only one definition of each name exists and the collision
cannot occur. The defect lives exclusively on a database carrying both, which
production is. Any test that inspects `self.env["res.config.settings"]` would
pass on a colliding name and prove nothing. So the sweep below parses both
addons' `models/` trees with `ast` and needs neither module installed.

IT DOES NEED `etp_assessment_pro` ON DISK, AND SAYS SO OUT LOUD. There used to
be a `self.skipTest(...)` here for the case where the pro tree is absent, which
reproduced in the guard the exact failure mode the guard exists to catch: a
green run that proves nothing. A missing comparand is now a FAILURE. If a
checkout or CI image genuinely has no `etp_assessment_pro`, that is a fact about
the image worth fixing, not worth hiding - and a red test is how you find out.
With no skip left, reverting any of the renames turns this red on ANY database.

WHAT IS ALLOWED TO BE SHARED, and why each entry earns it, is in `ALLOWED`.
Every entry carries its reason next to the name, because a bare list of strings
is an invitation to append one more and turn a red test green. Anything sharing
a name that is not in that dict fails, and an entry that has stopped colliding
also fails - that is how a fixed collision gets its entry deleted instead of
left behind as cover for the next one.

The last test drives the renamed onchange through the ORM's real `onchange()`
entry point - the one the web client calls - so it pins that the rename moved
the NAME only and the `@api.onchange` decorator still fires on the same field
and still fills the same target. A test that merely called the method by its new
name would pass even if the decorator had been dropped.
"""
import ast
import base64
import collections
import os

from odoo.tests.common import TransactionCase, tagged

_HERE = os.path.dirname(os.path.abspath(__file__))
OURS = os.path.normpath(os.path.join(_HERE, os.pardir, "models"))
PRO = os.path.normpath(os.path.join(
    _HERE, os.pardir, os.pardir, "etp_assessment_pro", "models"))

_Allowed = collections.namedtuple("_Allowed", "super_required why")

# The ONLY names both addons may spell the same way on a shared model. Keyed by
# (model, "method"|"field", name). Adding an entry here is a design decision
# that has to be argued in `why`, not a way to silence a red run.
ALLOWED = {
    ("res.config.settings", "method", "get_values"): _Allowed(
        super_required=True,
        why="CORRECT AND DELIBERATE. Odoo's own res.config.settings API - every "
            "addon is meant to override it, and both copies chain through "
            "super() (ours res_config_settings.py:525, pro's :279), so they "
            "stack rather than replace. Renaming ours would take our settings "
            "out of Odoo's read path entirely."),
    ("res.config.settings", "method", "set_values"): _Allowed(
        super_required=True,
        why="CORRECT AND DELIBERATE, same as get_values. Both chain through "
            "super() (ours res_config_settings.py:553, pro's :325)."),

    # --- KNOWN, TRACKED, NOT YET FIXED -------------------------------------
    # assessments_be_v2/models/hr_applicant.py:302 and
    # etp_assessment_pro/models/hr_applicant.py:130 are the SAME method on the
    # same model. Both `_inherit = "hr.applicant"` with no `_name`, so this is
    # one composed class. Neither calls super(). The bodies are identical apart
    # from the evaluator relation: ours reads `be_evaluator_ids` (and depends on
    # it), pro's reads `etp_evaluator_ids`.
    #
    # WHO WINS: neither addon depends on the other, and Odoo 19 orders loading
    # by (phase, depth, name) - see src/odoo/modules/module_graph.py:225. Both
    # sit at depth 11 (employee_extension, depth 10, dominates both dependency
    # lists), so the tiebreak is the module name: `assessments_be_v2` <
    # `etp_assessment_pro`, PRO COMPOSES LAST AND WINS.
    #
    # CONSEQUENCE ON PRODUCTION: the applicant form's Result Breakdown donut
    # counts only `etp_evaluator_ids`, so a candidate assessed through
    # assessments_be_v2 renders an empty grey ring - Pass 0 / Fail 0 /
    # Pending 0.
    #
    # THE FIX, when it is scheduled: rename ours to
    # `_compute_be_result_donut_html` / `be_result_donut_html` and repoint
    # assessments_be_v2/views/hr_applicant_views.xml:280. Held back from this
    # release because hr_applicant.py is otherwise untouched by it and a
    # computed-field rename drags a view change along with it. DELETING THESE
    # TWO ENTRIES IS WHAT CLOSING THAT TICKET LOOKS LIKE.
    ("hr.applicant", "method", "_compute_etp_result_donut_html"): _Allowed(
        super_required=False,
        why="KNOWN LIVE COLLISION, pro wins, our donut never computes. Tracked, "
            "fix deferred past this release - see the comment above."),
    ("hr.applicant", "field", "etp_result_donut_html"): _Allowed(
        super_required=False,
        why="KNOWN LIVE COLLISION, the field half of the entry above - the last "
            "declaration's compute= is the one the ORM keeps."),
}


def _sweep(models_dir):
    """{model: {"method": {name: node}, "field": {name: node}}} for an addon.

    Keyed by the model the class actually contributes to: `_name` when the class
    declares one (`_name` + `_inherit` is prototype inheritance - members are
    copied into the NEW model, they never land on the parent), otherwise every
    model in `_inherit`.
    """
    out = collections.defaultdict(lambda: {"method": {}, "field": {}})
    for filename in sorted(os.listdir(models_dir)):
        if not filename.endswith(".py"):
            continue
        with open(os.path.join(models_dir, filename), "r", encoding="utf-8") as fh:
            tree = ast.parse(fh.read())
        for node in ast.walk(tree):
            if not isinstance(node, ast.ClassDef):
                continue
            attrs = {}
            for stmt in node.body:
                if (isinstance(stmt, ast.Assign) and len(stmt.targets) == 1
                        and isinstance(stmt.targets[0], ast.Name)):
                    try:
                        attrs[stmt.targets[0].id] = ast.literal_eval(stmt.value)
                    except (ValueError, TypeError, SyntaxError):
                        pass
            if "_name" in attrs:
                models = [attrs["_name"]]
            elif "_inherit" in attrs:
                inherit = attrs["_inherit"]
                models = [inherit] if isinstance(inherit, str) else list(inherit)
            else:
                continue
            for model in models:
                for stmt in node.body:
                    if isinstance(stmt, ast.FunctionDef):
                        out[model]["method"][stmt.name] = stmt
                    elif (isinstance(stmt, ast.Assign)
                            and len(stmt.targets) == 1
                            and isinstance(stmt.targets[0], ast.Name)
                            and _is_field(stmt.value)):
                        out[model]["field"][stmt.targets[0].id] = stmt
    return out


def _is_field(value):
    return (isinstance(value, ast.Call)
            and isinstance(value.func, ast.Attribute)
            and isinstance(value.func.value, ast.Name)
            and value.func.value.id == "fields")


def _calls_super(node):
    return any(
        isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
        and isinstance(n.func.value, ast.Call)
        and isinstance(n.func.value.func, ast.Name)
        and n.func.value.func.id == "super"
        for n in ast.walk(node)
    )


@tagged("post_install", "-at_install")
class TestSharedModelMethodNames(TransactionCase):

    def test_the_two_addons_share_no_member_name(self):
        """Every model we extend, swept against etp_assessment_pro."""
        # NOT a skip. A missing comparand means this guard is not guarding, and
        # a guard that cannot run has to say so in red.
        self.assertTrue(os.path.isdir(PRO), (
            "etp_assessment_pro/models is not at %s, so the collision sweep has "
            "nothing to compare against and CANNOT PASS. This test deliberately "
            "does not skip: a silent green here is the exact failure mode it "
            "exists to catch. Restore the addon to the tree (it need not be "
            "installed - the sweep only reads source)." % PRO))

        ours, pro = _sweep(OURS), _sweep(PRO)
        # A parser regression that quietly matches nothing would also go green.
        for label, swept in (("assessments_be_v2", ours), ("etp_assessment_pro", pro)):
            for model in ("res.config.settings", "hr.applicant"):
                self.assertIn(model, swept,
                              "swept no %s classes out of %s - the sweep is broken"
                              % (model, label))

        colliding, checked = [], set()
        for model in sorted(set(ours) & set(pro)):
            for kind in ("method", "field"):
                for name in sorted(set(ours[model][kind]) & set(pro[model][kind])):
                    key = (model, kind, name)
                    checked.add(key)
                    if key not in ALLOWED:
                        colliding.append("%s.%s (%s)" % (model, name, kind))

        self.assertFalse(colliding, (
            "same-named %s in BOTH assessments_be_v2 and etp_assessment_pro: %s. "
            "Odoo composes one class per model, so one of each pair is discarded "
            "together with its @api.* trigger list and nothing warns. Give ours a "
            "`_be_` name. Do NOT add it to ALLOWED unless you can write the "
            "argument for why sharing is safe."
            % ("members" if len(colliding) > 1 else "member", ", ".join(colliding))))

        # An exemption has to earn itself: only a real super() call makes
        # sharing a name safe, so the list can never wave through a replacement.
        for key, allowed in sorted(ALLOWED.items()):
            model, kind, name = key
            if not allowed.super_required:
                continue
            for label, swept in (("assessments_be_v2", ours),
                                 ("etp_assessment_pro", pro)):
                node = swept[model][kind][name]
                self.assertTrue(_calls_super(node), (
                    "%s %s.%s is allowed to share its name ONLY because it "
                    "chains through super(), and it no longer does - it now "
                    "REPLACES the other addon's copy instead of stacking with "
                    "it. Allowed because: %s" % (label, model, name, allowed.why)))

        # A collision that has been fixed must lose its entry, otherwise the
        # list turns into a parking space for the next one.
        stale = sorted("%s.%s (%s)" % (m, n, k)
                       for (m, k, n) in set(ALLOWED) - checked)
        self.assertFalse(stale, (
            "ALLOWED still exempts %s, but they no longer collide. Delete the "
            "entries - carrying a dead exemption is how the next real collision "
            "gets waved through." % ", ".join(stale)))

    def test_our_onchange_names_carry_the_addon_prefix(self):
        """The rename itself, pinned. Red the moment someone drops `be_`."""
        ours = _sweep(OURS)["res.config.settings"]["method"]
        for name in ("_onchange_be_vertex_sa_upload",
                     "_onchange_be_question_prompt_upload",
                     "_be_decode_upload"):
            self.assertIn(name, ours, "%s was renamed away" % name)


@tagged("post_install", "-at_install")
class TestUploadOnchangeStillFires(TransactionCase):
    """The decorator, not the method name, is what wires the behaviour.

    Driven through `res.config.settings.onchange()` - the ORM entry point the
    web client itself calls - so the `@api.onchange` trigger list has to be
    intact for the target field to come back filled. Deleting the decorator, or
    changing which field it watches, turns this red even though the method is
    still there under its new name.
    """

    # (uploaded field, decoded-text field, filename field, payload)
    CASES = [
        ("assessments_be_vertex_sa_upload",
         "assessments_be_vertex_service_account_json",
         "assessments_be_vertex_service_account_filename",
         '{"type": "service_account", "project_id": "p"}'),
        ("assessments_be_question_prompt_upload",
         "assessments_be_question_prompt",
         "assessments_be_question_prompt_filename",
         "# question prompt\nwrite one question."),
    ]

    def test_picking_a_file_fills_the_text_box(self):
        settings = self.env["res.config.settings"]
        for upload_field, text_field, name_field, payload in self.CASES:
            with self.subTest(field=upload_field):
                raw = base64.b64encode(payload.encode("utf-8")).decode("ascii")
                spec = {f: {} for f in (upload_field, text_field, name_field)}
                result = settings.onchange(
                    {upload_field: raw, text_field: False, name_field: False},
                    [upload_field],
                    spec,
                )
                got = result.get("value", {})
                self.assertEqual(got.get(text_field), payload, (
                    "onchange on %s did not decode into %s - the @api.onchange "
                    "trigger is not wired" % (upload_field, text_field)))
                self.assertTrue(got.get(name_field),
                                "filename field left empty by the onchange")

    def test_a_non_utf8_upload_is_refused_not_silently_blanked(self):
        from odoo.exceptions import UserError
        settings = self.env["res.config.settings"]
        raw = base64.b64encode(b"\xff\xfe\x00binary").decode("ascii")
        with self.assertRaises(UserError):
            settings.onchange(
                {"assessments_be_vertex_sa_upload": raw},
                ["assessments_be_vertex_sa_upload"],
                {"assessments_be_vertex_sa_upload": {},
                 "assessments_be_vertex_service_account_json": {}},
            )
