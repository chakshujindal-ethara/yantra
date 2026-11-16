"""W15: grade the selected answers with TODAY's code, keeping no mark. Run it
from the BASELINE checkout (today's prod code: its instructions, item fields
and attached media), twice (--run 1, --run 2) for the model's own wobble.
Needs only this folder, not the new module. The baseline checkout is
19.0.3.22.0 (prompt `bundled:34c42d2f`, the version the harness expects),
nothing else: `git archive 0d09cdfb5 src custom_addons | tar -x -C <dir>`.
Pin the sha: HEAD is the new code once 19.0.3.23.0 is committed.

    cd <baseline checkout>
    .venv/bin/python <this folder>/run_baseline_arm.py -c lane.conf \
        -d calib_copy --run 1 --ids calib/ids.json --tricks calib/tricks.json \
        --out calib/baseline_1.jsonl [--dry-run]
"""
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness  # noqa: E402

harness.cli_run((harness.BASELINE_ARM,), __doc__.splitlines()[0])
