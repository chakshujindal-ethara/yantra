# -*- coding: utf-8 -*-
"""PRE-DEPLOY GATE for 19.0.3.22.0. Read-only. Run before upgrading, not after.

WHAT THIS PREVENTS. Until this version, `res_config_settings._check_llm_limits`
was composed away by a method of the same name in `etp_assessment_pro` - same
model, no `super()` - so NONE of its range checks ran on any deployment
carrying both modules. Production carries both. Values outside the accepted
range could therefore be stored, and probably were.

This version renames ours to `_check_be_llm_limits`, so the checks start
running. That is the fix, and it has a sharp edge: `res.config.settings.execute()`
writes every field, so `default_get` loads a stored out-of-range value into the
transient record and the constraint fires on it. The result is that **the whole
Odoo Settings page stops saving** - including fields nothing to do with these -
and it cannot be repaired from that page, because saving is what is blocked.

Measured locally: with `scoring_shards` planted at 9, an otherwise empty
Settings save raised "Scoring Shards must be between 1 and 4".

So: run this FIRST. If it reports anything, fix those parameters before the
upgrade. Fixing them afterwards means editing `ir.config_parameter` directly.

    ./odoo-bin shell -c odoo.conf -d <db> \\
        < custom_addons/assessments_be_v2/tools/check_settings_in_range.py

It writes nothing and returns a non-empty report only when there is a problem.
"""
# `env` is provided by `odoo-bin shell`.

# THE FIELD SET AND THE BOUNDS ARE THE CONSTRAINT'S OWN, NOT A COPY OF THEM.
# This file used to carry its own table, and the copy drifted twice - in both
# directions:
#
#   TOO STRICT: it refused a stored 0, which `_check_be_llm_limits` coerces to
#   the field default and accepts, and it refused an rpm above an invented
#   10000 ceiling the constraint does not have. A gate whose entire output is
#   "fix this BEFORE upgrading" was holding deploys back on legal values and
#   sending operators to edit working configuration.
#
#   TOO NARROW: it checked four parameters while the constraint triggers on
#   seven. A stored negative `daily_llm_cap_usd`, `per_evaluator_llm_cap_usd`
#   or `score_outlier_sigma` passed the gate clean and then bricked the
#   Settings page after the upgrade - precisely the failure this file exists
#   to predict, in the three fields that cost money.
#
# So nothing is hand-listed here any more. The FIELDS come from the
# constraint's own `@api.constrains` trigger list, the parameter key and the
# screen label come off each field, and the numeric bounds come from
# `constants.SETTING_RANGES` - the same table the constraint and the write API
# read. Add a field to the constraint and this gate checks it without anyone
# remembering to come here, and
# `tests/test_one_list_of_legal_values_per_setting.py` fails if the gate's set
# and the constraint's trigger list ever differ again.
from odoo.addons.assessments_be_v2.constants import SETTING_RANGES

SETTINGS = env["res.config.settings"]

# (field, parameter key, label, low, high, default).
#
# `high` is None for the fields the constraint only refuses a NEGATIVE on: the
# two spend caps, the outlier sigma and the Vertex rate ceiling have no upper
# bound on the form, because a project's quota and a customer's budget can be
# any size. They get a "cannot be negative" check rather than an invented
# ceiling - inventing one is how this file once flagged a legitimate 20000 rpm.
#
# `default` is what a stored 0 resolves to for the bounded three, exactly as
# the constraint's `(value or default)` resolves it, so 0 is reported as "the
# field default applies" rather than as a problem.
CHECKS = []
for _name in SETTINGS._check_be_llm_limits._constrains:
    _field = SETTINGS._fields[_name]
    _key = getattr(_field, "config_parameter", False)
    if not _key:
        # Nothing stored in `ir.config_parameter`, so there is no pre-existing
        # value for the upgrade to trip over. The parity test says so out loud.
        continue
    _label = _field.string
    if _label.endswith(" (v2)"):
        _label = _label[:-5]
    _short = _key.split(".", 1)[1]
    if _short in SETTING_RANGES:
        _low, _high, _default = SETTING_RANGES[_short]
    else:
        _low, _high, _default = 0, None, None
    CHECKS.append((_name, _key, _label, _low, _high, _default))

ICP = env["ir.config_parameter"].sudo()

print("=" * 74)
print("Settings range check for assessments_be_v2 19.0.3.22.0")
print("=" * 74)

problems = []


def _value(key, label):
    """The stored number, or None when there is nothing to check."""
    raw = ICP.get_param(key)
    if raw in (None, "", False):
        print("  ok      %-34s not set (the field default applies)" % label)
        return None
    try:
        return float(raw)
    except (TypeError, ValueError):
        problems.append((key, raw, label, "is not a number"))
        print("  PROBLEM %-34s %r is not a number" % (label, raw))
        return None


for _name, key, label, low, high, default in CHECKS:
    value = _value(key, label)
    if value is None:
        continue
    if high is None:
        # NEGATIVE ONLY, and 0 IS A REAL SETTING here rather than "unset": it
        # disables the cap, the sigma flag or the rate limiter. The constraint
        # refuses nothing above 0, so there is no ceiling to check.
        if value < 0:
            problems.append((key, value, label, "cannot be negative"))
            print("  PROBLEM %-34s %s (cannot be negative; use 0 to disable "
                  "it)" % (label, value))
        else:
            print("  ok      %-34s %s" % (label, value))
    # 0 IS NOT OUT OF RANGE on the bounded three, it is "unset". The constraint
    # compares `(value or default)`, the write API lets 0 through for these
    # keys, and every settings save materialises "0" for a falsy numeric - so a
    # gate that flagged it would flag an ordinary deployment.
    elif value == 0:
        print("  ok      %-34s 0 (the field default of %s applies)"
              % (label, default))
    elif not (low <= value <= high):
        problems.append((key, value, label,
                         "must be between %s and %s" % (low, high)))
        print("  PROBLEM %-34s %s (must be between %s and %s)"
              % (label, value, low, high))
    else:
        print("  ok      %-34s %s" % (label, value))

print("-" * 74)
if not problems:
    print("Nothing out of range. The upgrade will not break the Settings page.")
else:
    print("%d parameter(s) would make the Settings page unsavable after the "
          "upgrade.\n" % len(problems))
    print("Fix them BEFORE upgrading. From the same shell:\n")
    for key, raw, label, why in problems:
        print("    env['ir.config_parameter'].sudo().set_param(%r, '<value>')"
              "   # %s: %s, currently %r" % (key, label, why, raw))
    print("\nThen re-run this check, then upgrade.")
