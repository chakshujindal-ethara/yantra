"""W15: grade the selected answers with the NEW code, keeping no mark. Run from
the new checkout. Arms: new_uncached (the individual re-score path),
new_cached (the bulk path - uses question-group caches when the code and its
switch do; each row says whether `cachedContent` was sent), new_fallback (the
uncached path on the fallback model, or --model).

    .venv/bin/python custom_addons/assessments_be_v2/tools/calibration/run_new_arm.py \
        -c lane.conf -d calib_copy --arm new_uncached --ids calib/ids.json \
        --tricks calib/tricks.json --out calib/new_uncached.jsonl [--dry-run]
"""
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness  # noqa: E402

harness.cli_run(harness.NEW_ARMS, __doc__.splitlines()[0])
