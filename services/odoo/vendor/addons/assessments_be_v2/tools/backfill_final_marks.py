"""Recompute every question mark under the COMPONENT scoring rule.

    env -u PYTHONPATH .venv/bin/python src/odoo-bin shell \
      -c odoo.conf --no-http --http-port=8199 \
      < custom_addons/assessments_be_v2/tools/backfill_final_marks.py

WHY THIS EXISTS. `final_mark` is a STORED compute, and Odoo recomputes a stored
compute when one of its dependencies moves - not when the method that produces
it is edited. The unit of scoring changed from the QUESTION to the COMPONENT, so
every row written under the old rule still holds the old number. Leaving them is
worse than it looks: the stale rows are not frozen, they flip one at a time the
next time a rescore or a threshold edit happens to touch a dependency, so the
same attempt reads differently on two different days for no visible reason.

WHAT IT WILL CHANGE - MOST ROWS, NOT A FEW. Under the old rule a question was
worth 1 and a multi-part one was all-or-nothing across its parts. Every question
is now worth one mark per component: each keyed sub-question, the graded written
answer, and a labelling box set. So a 3-part MCQ moves from 0-or-1 to 0-to-3, and
the paper's denominator grows with it. Scores move in BOTH directions: a
candidate who got two of three parts right gains, one who cleared a low bar on a
question whose parts were mostly wrong can lose.

WHAT THIS SCRIPT CANNOT DO. It recomputes; it does not re-grade. An `image_label`
answer scored before the per-box contract has no per-box raws on disk, and an
`image_ab` answer's stored `llm_raw_100` is the OLD 0.75/0.25 blend rather than
the justification alone. Those two types need the grader to look again - run
`action_regrade_for_component_scoring` on the affected assessments FIRST, let the
scoring cron drain, and then run this. Running it alone will leave those answers
recomputed from stale inputs.

IDEMPOTENT. Re-running recomputes the same values and reports nothing moved.
"""

Assessment = env["assessments.be"]

assessments = Assessment.search([])
print(f"Recomputing question marks across {len(assessments)} assessment(s)...")

moved = env["assessments.be.evaluator"]
failed = []
for assessment in assessments:
    try:
        # commit=True per assessment: this walks every response in the
        # database, and one transaction over all of them holds a lock on the
        # whole response table for the duration.
        moved |= assessment._recompute_question_marks(commit=True)
    except Exception as exc:                                    # noqa: BLE001
        # Recorded and carried on, so one bad assessment does not abandon the
        # rest unrecomputed.
        #
        # THE ROLLBACK ONLY REACHES THE UNCOMMITTED TAIL. `_recompute_question_marks`
        # commits per batch of responses - it has to, or one transaction holds a
        # lock on the whole response table - so a failure part-way through leaves
        # that assessment's earlier batches already written. That is safe rather
        # than tidy: the recompute is idempotent, so re-running this script after
        # fixing the cause finishes the job and reports the same totals. The
        # fractional-mark check at the bottom is what tells you it is unfinished.
        failed.append((assessment.id, f"{type(exc).__name__}: {exc}"))
        env.cr.rollback()

print(f"\n{len(moved)} attempt(s) changed verdict.")
for ev in moved.sorted("id"):
    released = "RELEASED" if ev.results_released else "unreleased"
    print(f"  attempt {ev.id:>6}  {ev.assessment_id.name!r}  "
          f"{ev.applicant_id.partner_name or '?'}  "
          f"-> {ev.result} ({ev.score_marks_display}, "
          f"{ev.score_percent}% vs {ev.pass_threshold}%)  [{released}]")

if failed:
    print(f"\n! {len(failed)} assessment(s) failed and were rolled back:")
    for assessment_id, message in failed:
        print(f"  assessment {assessment_id}: {message}")

# THE INVARIANT IS NO LONGER "every mark is 0 or 1" - that was the old rule, and
# asserting it now would report every correctly-recomputed multi-part question as
# a failure. What must still hold is that a mark is a whole number of components
# and never exceeds what its question is worth. A fractional mark, or one over
# its own ceiling, means a response was not reached - far more useful to be told
# here than to discover from a candidate's score months later.
env.cr.execute("""
    SELECT final_mark, final_max, count(*) FROM assessments_be_response
    WHERE final_mark <> trunc(final_mark)
       OR final_mark > final_max
       OR final_mark < 0
    GROUP BY final_mark, final_max ORDER BY final_mark
""")
bad_rows = env.cr.fetchall()
if bad_rows:
    print("\n! Marks that are not a whole number of components, or exceed what "
          "their question is worth - these rows were NOT recomputed:")
    for mark, out_of, count in bad_rows:
        print(f"  final_mark = {mark} of {out_of}: {count} row(s)")
else:
    print("\nEvery final_mark is a whole number of components, within its "
          "question's own total.")
