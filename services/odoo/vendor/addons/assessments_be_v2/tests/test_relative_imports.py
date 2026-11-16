"""Every relative import in this addon must actually resolve.

THE DEFECT THIS CATCHES. `controllers/api/forms.py` imported the S3 helper as
`from ..services import s3_service`. That file is TWO packages deep
(`controllers.api`), so `..` resolves to `controllers` - and there is no
`controllers/services/`. The correct form is `...services`, which the very same
file already used on line 25 and which `controllers/api/admin.py` uses for the
identical import.

WHY IT SHIPPED. Both occurrences were FUNCTION-LOCAL imports. The module loads
fine, the addon installs fine, every test passes - and the ModuleNotFoundError
only fires when that endpoint is actually hit. On stage this meant every Form
Studio image returned:

    GET /api/v1/forms/media/form_studio/<key>.png  ->  500

with `ModuleNotFoundError: No module named
'odoo.addons.assessments_be_v2.controllers.services'` in the log. An operator
saw "Could not load that image URL" and no explanation.

A module-level import would have failed loudly at install. A function-local one
needs this test, which resolves every relative import in the addon the way
Python will, without executing anything.
"""
import ast
import os

from odoo.tests.common import TransactionCase


ADDON = "assessments_be_v2"


def _broken_relative_imports(root):
    """(path, lineno, statement) for each relative import that cannot resolve."""
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != "__pycache__"]
        for filename in filenames:
            if not filename.endswith(".py"):
                continue
            path = os.path.join(dirpath, filename)
            rel = os.path.relpath(path, root)
            # Package path of the module doing the importing.
            parts = [ADDON] + rel.split(os.sep)[:-1]
            try:
                tree = ast.parse(open(path, encoding="utf-8").read())
            except SyntaxError:                      # not ours to police here
                continue
            for node in ast.walk(tree):
                if not isinstance(node, ast.ImportFrom) or not node.level:
                    continue
                stmt = "from %s%s import ..." % ("." * node.level,
                                                 node.module or "")
                if node.level > len(parts):
                    out.append((rel, node.lineno, stmt))
                    continue
                # level=1 is the current package, level=2 one above, ...
                base = parts[:len(parts) - (node.level - 1)]
                target = base + ((node.module or "").split(".")
                                 if node.module else [])
                fs_path = (os.path.join(root, *target[1:])
                           if len(target) > 1 else root)
                if not (os.path.isdir(fs_path)
                        or os.path.isfile(fs_path + ".py")):
                    out.append((rel, node.lineno, stmt))
    return out


class TestRelativeImportsResolve(TransactionCase):

    def test_no_relative_import_points_outside_the_addon(self):
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

        broken = _broken_relative_imports(root)

        self.assertEqual(
            broken, [],
            "these relative imports do not resolve - a function-local one will "
            "500 at request time instead of failing at install:\n"
            + "\n".join("  %s:%d  %s" % b for b in broken))

    def test_the_checker_actually_detects_a_bad_import(self):
        """A checker that can never fail is worse than no checker."""
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            pkg = os.path.join(tmp, "controllers", "api")
            os.makedirs(pkg)
            with open(os.path.join(pkg, "x.py"), "w", encoding="utf-8") as fh:
                # Exactly the shape of the real defect.
                fh.write("def f():\n    from ..services import s3_service\n")

            found = _broken_relative_imports(tmp)

        self.assertEqual(len(found), 1, "the real defect shape must be caught")
        self.assertIn("services", found[0][2])
