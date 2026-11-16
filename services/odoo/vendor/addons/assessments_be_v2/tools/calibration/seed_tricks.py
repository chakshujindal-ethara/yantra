"""W15: ~20 trick answers on real questions - true-but-unlisted, invented
(not contradicting the key) and contradicting claims. Nothing is written: each
trick replaces a real answer's text only inside a rolled-back transaction, here
and again in every arm (`--tricks`). True-but-unlisted ones need a person who
has seen the media: fill in their `answer` before the arms run.

    .venv/bin/python custom_addons/assessments_be_v2/tools/calibration/seed_tricks.py \
        -c lane.conf -d calib_copy --assessments 126,843 --out calib/tricks.json
"""
import json
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness  # noqa: E402

p = harness.parser(__doc__.splitlines()[0])
p.add_argument("--assessments", type=harness.ids_arg, required=True)
p.add_argument("--count", type=int, default=20)
p.add_argument("--seed", type=int, default=7)
p.add_argument("--out", required=True)
args = p.parse_args()
if os.path.exists(args.out):
    sys.exit("%s exists; hand-written answers are never overwritten" % args.out)
with harness.odoo_env(args) as env:
    tricks = harness.build_tricks(env, args.assessments, args.count, args.seed)
with open(args.out, "w", encoding="utf-8") as fh:
    json.dump(tricks, fh, indent=1, ensure_ascii=False)
for t in tricks:
    print("%s  %-14s %-18s question %-6s host answer %-7s %s" % (
        t["key"], t["kind"], t["question_type"], t["question_id"],
        t["answer_id"], "ready" if t["answer"] else "WRITE BY HAND"))
print("%d trick(s) -> %s" % (len(tricks), args.out))
