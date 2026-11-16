"""Delete every row the pipeline and audit probes created.

Markers: ZZPIPE (pipeline), ZZAUDIT (contract probe), ZZPROBE (paging proof).
The user's own data - the two real generators, the 21-question bank, the two
real assessments and the single real attempt - is never matched by these.

Deletes children before parents so a foreign key never blocks the sweep.
"""
import sys

sys.path.insert(0, "src")

import odoo  # noqa: E402
from odoo.tools import config  # noqa: E402

config.parse_config(["-c", "odoo.conf"])
dbname = config["db_name"]
if isinstance(dbname, (list, tuple)):
    dbname = dbname[0]

from odoo.modules.registry import Registry  # noqa: E402

MARKERS = ["ZZPIPE", "ZZAUDIT", "ZZPROBE"]
registry = Registry(dbname)
with registry.cursor() as cr:
    env = odoo.api.Environment(cr, odoo.SUPERUSER_ID, {})
    domain = ["|"] * (len(MARKERS) - 1) + [("name", "like", m) for m in MARKERS]

    Asm = env["assessments.be"].sudo()
    Gen = env["assessments.be.prompt"].sudo()
    Q = env["assessments.be.question"].sudo()

    assessments = Asm.search(domain)
    generators = Gen.search(domain)
    print(f"assessments : {len(assessments)}")
    print(f"generators  : {len(generators)}")

    attempts = env["assessments.be.evaluator"].sudo().search(
        [("assessment_id", "in", assessments.ids)])
    responses = env["assessments.be.response"].sudo().search(
        [("assessment_evaluator_id", "in", attempts.ids)])
    questions = Q.search([("generator_id", "in", generators.ids)])
    drafts = env["assessments.be.prompt.question"].sudo().search(
        [("prompt_id", "in", generators.ids)])
    resources = env["assessments.be.prompt.resource"].sudo().search(
        [("prompt_id", "in", generators.ids)])
    print(f"attempts    : {len(attempts)}")
    print(f"responses   : {len(responses)}")
    print(f"questions   : {len(questions)}")
    print(f"drafts      : {len(drafts)}")
    print(f"resources   : {len(resources)}")

    for label, records in (
        ("responses", responses), ("attempts", attempts),
        ("assessments", assessments), ("questions", questions),
        ("drafts", drafts), ("resources", resources),
        ("generators", generators),
    ):
        try:
            records.unlink()
        except Exception as exc:  # noqa: BLE001
            print(f"  {label}: {type(exc).__name__} {str(exc)[:90]}")

    # The probe applicants, which are hr.applicant rows not covered above.
    App = env["hr.applicant"].sudo().search(
        [("partner_name", "like", "ZZPIPE")])
    print(f"applicants  : {len(App)}")
    try:
        App.unlink()
    except Exception as exc:  # noqa: BLE001
        print(f"  applicants: {type(exc).__name__} {str(exc)[:90]}")

    cr.commit()

with registry.cursor() as cr2:
    env2 = odoo.api.Environment(cr2, odoo.SUPERUSER_ID, {})
    print()
    print("AFTER:")
    print("  generators :", env2["assessments.be.prompt"].sudo().search_count([]))
    print("  assessments:", env2["assessments.be"].sudo().search_count([]))
    print("  bank       :", env2["assessments.be.question"].sudo().search_count([]))
    print("  attempts   :", env2["assessments.be.evaluator"].sudo().search_count([]))
