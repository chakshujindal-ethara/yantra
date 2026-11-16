"""Graded answers whose stored grading rules do not fit their question type.
READ-ONLY - writes nothing, ends in a rollback.

    env -u PYTHONPATH .venv/bin/python src/odoo-bin shell \
      -c odoo.conf -d <DB> --no-http --stop-after-init \
      < custom_addons/assessments_be_v2/tools/profile_mismatch_report.py

WHY. Before W12 the SOP title picked the grading rules ahead of the question
type, so e.g. a written answer under an SOP titled "Q7r" was graded by the
defect-labelling rules, and `llm_profile` stored what the model echoed back.
This lists every scored answer whose `llm_profile` is not one its type may use
(`scoring.rules_fit_type`), so the owner can pick which to re-score
individually. Run it on the prod copy, never on prod itself.
"""
import collections

from odoo.addons.assessments_be_v2.services import scoring as _scoring

rows = env["assessments.be.response"].sudo().search_read(
    [("llm_state", "=", "scored"), ("llm_profile", "!=", False)],
    ["id", "question_id", "question_type", "llm_profile", "llm_raw_100",
     "assessment_id", "llm_prompt_version"],
    order="assessment_id, id")
bad = [r for r in rows
       if not _scoring.rules_fit_type(r["question_type"], r["llm_profile"])]

print("=" * 68)
print("PROFILE MISMATCH REPORT  db=%s" % env.cr.dbname)
print("scored answers with a stored profile: %d   mismatched: %d"
      % (len(rows), len(bad)))
print("=" * 68)
by_kind = collections.Counter((r["question_type"], r["llm_profile"])
                              for r in bad)
for (qtype, profile), n in by_kind.most_common():
    print("%6d  %-18s graded as %s" % (n, qtype, profile))
if bad:
    print()
    print("answer_id,assessment_id,question_id,question_type,profile,raw_100,"
          "prompt_version")
    for r in bad:
        print("%s,%s,%s,%s,%s,%s,%s" % (
            r["id"], (r["assessment_id"] or [""])[0],
            (r["question_id"] or [""])[0], r["question_type"],
            '"%s"' % r["llm_profile"], r["llm_raw_100"],
            r["llm_prompt_version"] or ""))
env.cr.rollback()
