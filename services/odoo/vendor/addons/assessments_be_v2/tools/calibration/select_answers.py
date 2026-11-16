"""W15 step 2, READ-ONLY: pick the answers every arm grades, stratified by
question type, deterministic by seed. (Not `select.py`: that name would shadow
Python's own `select` module for every script in this folder.)

    .venv/bin/python custom_addons/assessments_be_v2/tools/calibration/select_answers.py \
        -c lane.conf -d calib_copy --assessments 126,843 --sample 1000 \
        --seed 7 --out calib/ids.json

A smaller --sample with the same seed picks a subset: use it for the
200-answer fallback arm.
"""
import collections
import json
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness  # noqa: E402

p = harness.parser(__doc__.splitlines()[0])
p.add_argument("--assessments", type=harness.ids_arg, required=True)
p.add_argument("--sample", type=int, default=1000)
p.add_argument("--seed", type=int, default=7)
p.add_argument("--out", required=True)
args = p.parse_args()
with harness.odoo_env(args) as env:
    rows = harness.gradable_answers(env, args.assessments)
ids = harness.pick(rows, args.sample, args.seed)
chosen = set(ids)
by_type = collections.Counter(r[1] for r in rows if r[0] in chosen)
candidates = len({r[2] for r in rows if r[0] in chosen})
with open(args.out, "w", encoding="utf-8") as fh:
    json.dump({"assessments": args.assessments, "sample": args.sample,
               "seed": args.seed, "by_type": by_type, "ids": ids}, fh, indent=1)
print("%d of %d graded answers from %d candidate(s): %s -> %s" % (
    len(ids), len(rows), candidates, dict(sorted(by_type.items())), args.out))
