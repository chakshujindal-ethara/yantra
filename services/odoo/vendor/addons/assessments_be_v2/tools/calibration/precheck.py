"""W15 step 1, READ-ONLY: which instructions graded the prod copy, which
question types it holds, and the profile-mismatch report. Run from the NEW
checkout (the mismatch report needs its rules table).

    .venv/bin/python custom_addons/assessments_be_v2/tools/calibration/precheck.py \
        -c lane.conf -d calib_copy [--assessments 126,843]

Exit 1 when any graded answer's prompt version is not bundled:34c42d2f -
resolve that before the push (docs/ETP_PLANS_AND_STRATEGY.md §5.6).
"""
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness  # noqa: E402

p = harness.parser(__doc__.splitlines()[0])
p.add_argument("--assessments", type=harness.ids_arg,
               help="limit to these assessment ids")
args = p.parse_args()
with harness.odoo_env(args) as env:
    found = harness.precheck(env, args.assessments)
    print("graded answers by prompt version (expected %s):"
          % harness.EXPECTED_PROMPT_VERSION)
    for version, n in sorted(found["versions"].items(), key=lambda v: -v[1]):
        print("  %7d  %-24s%s" % (n, version or "(empty)",
                                  "  <- FLAG" if version in found["flagged"]
                                  else ""))
    print("question types graded:")
    for qtype, n in sorted(found["types"].items()):
        print("  %7d  %s" % (n, qtype))
    harness.mismatch_report(env)
    verdicts = harness.verdict_scan(env, args.assessments)
    print("verdicts naming grading mechanics (candidates now see verdicts): "
          "%d of %d" % (len(verdicts["hits"]), verdicts["checked"]))
    for rid, verdict in list(verdicts["hits"].items())[:10]:
        print("  answer %d: %s" % (rid, verdict[:120]))
sys.exit(1 if found["flagged"] else 0)
