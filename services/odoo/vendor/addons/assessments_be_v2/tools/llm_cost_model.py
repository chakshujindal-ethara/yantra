#!/usr/bin/env python3
"""Cohort cost model for the assessment pipeline.

Token counts are MEASURED from `assessments_be_llm_usage` on etp_local
(72 billed calls, 2026-08-13..26), not estimated from prompt sizes. Prices are
list rates verified 2026-09-16 against Vertex AI and the Gemini API. Re-run
after a price change; `--measure` re-derives the token model from a live DB.

    python3 llm_cost_model.py --candidates 5000
    python3 llm_cost_model.py --validate
    python3 llm_cost_model.py --measure "host=localhost port=5433 dbname=etp_local"

`--measure` prints calls, average tokens in / out / thinking, the thinking
and cached shares, average latency and cost per ledger operation, then the
scoring fit.
"""
import argparse

# --- Prices, USD per 1M tokens. Verified 2026-09-16. ------------------------
# Vertex Global == Gemini Developer API list price (confirmed table-to-table).
# Non-global Vertex endpoints add +10% on GA Gemini 3+; this module pins
# Gemini to "global" (constants.py:570), so it pays list.
TEXT = {
    "gemini-3.1-pro-preview":     {"in": 2.00, "out": 12.00, "long_in": 4.00, "long_out": 18.00},
    "gemini-3.8-flash":           {"in": 0.75, "out": 3.75},   # intro; $1.50/$7.50 from 2027-01-01
    "gemini-3.1-flash-lite":      {"in": 0.25, "out": 1.50},
    "gemini-2.5-flash-lite":      {"in": 0.10, "out": 0.40},
    "glm-5.3-flash (z.ai)":       {"in": 0.15, "out": 0.50},
    "glm-5.3-flash (openrouter)": {"in": 0.10, "out": 0.333},
}
IMAGE = {          # USD per generated image, 1K tier. Tokens bill ON TOP.
    "gemini-3-pro-image": 0.134,
    "gemini-3.1-flash-image": 0.067,
    "gemini-3.1-flash-lite-image": 0.034,
}
# USD per second at 720p, (with audio, video only). Veo has NO batch tier.
# The module hardcodes `generateAudio: True` (services/vertex.py:1627) and
# nothing in scoring reads audio, so the right-hand column is reachable today
# by editing one line.
VIDEO = {
    "veo-3.1-generate-001":      (0.40, 0.20),
    "veo-3.1-fast-generate-001": (0.10, 0.08),
    "veo-3.1-lite-generate-001": (0.05, 0.03),
}
LONG_CONTEXT_THRESHOLD = 200_000
BATCH_DISCOUNT = 0.50          # Gemini Batch API; image models too, NOT Veo.

# --- Measured call model ----------------------------------------------------
# Linear fit over ledger rows tagged `submission(n)`:
#   n=1 -> 4,735 in / 976 billed out    (20 calls)
#   n=2 -> 4,808 in / 547 billed out    (1 call)
#   n=5 -> 13,151 in / 4,904 billed out (3 calls)
# "billed out" = tokens_out + thoughts_tokens; thinking bills at the OUTPUT
# rate and is 63.8% of scoring's billed output.
SCORING_FIXED_IN = 2_631         # system prompt + envelope, per call
SCORING_PER_RESPONSE_IN = 2_104  # item JSON + attached images, per response
SCORING_PER_RESPONSE_OUT = 982   # visible output + thinking, per response
SCORING_BATCH = 8                # assessments_be_v2.scoring_batch_size default

R_PER_CANDIDATE = 16.17          # measured mean LLM-eligible responses (5..45)
CALLS_PER_CANDIDATE = 2.33       # measured mean of ceil(R/8) per evaluator

# Gemini 3.x bills a FLAT token count per image, independent of pixel size, set
# only by `media_resolution`. The module never sets it, and "unspecified"
# resolves to `high` for images -- so every PNG today costs 1120 tokens.
# Measured response mix: 51 image_label (1 img), 36 image_ab (2 img), 10 rubric.
MEDIA_RESOLUTION_TOKENS = {"high (today)": 1120, "medium": 560, "low": 280}
IMAGES_PER_RESPONSE = (51 * 1 + 36 * 2) / 97.0   # = 1.27 measured mean
SCORING_ITEM_JSON_IN = 684       # 2104 - 1.27*1120; the non-image remainder

# Authoring, measured means per call
AUTHORING = {
    "generate_questions":   {"n": 6, "in": 18_241, "out": 3_784 + 2_195},
    "extract_tags":         {"n": 7, "in": 9_147,  "out": 1_442 + 2_215},
    "map_similarity":       {"n": 5, "in": 2_174,  "out": 612},
    "consolidate_vocab":    {"n": 1, "in": 441,    "out": 130 + 1_159},
    "verify_planted_flaws": {"n": 9, "in": 1_329,  "out": 92 + 1_476},
}
IMAGE_CALL_IN, IMAGE_CALL_OUT = 136, 1_120 + 351   # measured, on top of the fee


def token_cost(price, tokens_in, tokens_out):
    if tokens_in > LONG_CONTEXT_THRESHOLD and "long_in" in price:
        rate_in, rate_out = price["long_in"], price["long_out"]
    else:
        rate_in, rate_out = price["in"], price["out"]
    return (tokens_in * rate_in + tokens_out * rate_out) / 1_000_000.0


def scoring_cohort(candidates, r_per_candidate=R_PER_CANDIDATE,
                   calls_per_candidate=CALLS_PER_CANDIDATE):
    """Per-CALL tokens and the call count for one cohort.

    The long-context tier is a property of a single request, so tokens must stay
    per-call all the way to `token_cost`. Summing the cohort first and pricing
    the total crosses 200K trivially and silently doubles every rate.
    """
    calls = candidates * calls_per_candidate
    per_call_responses = r_per_candidate / calls_per_candidate
    tin = SCORING_FIXED_IN + per_call_responses * SCORING_PER_RESPONSE_IN
    tout = per_call_responses * SCORING_PER_RESPONSE_OUT
    return calls, tin, tout


def authoring_run(price):
    """USD for one generator run, priced per call for the same reason."""
    return sum(t["n"] * token_cost(price, t["in"], t["out"])
               for t in AUTHORING.values())


def validate():
    """Anchor the model against individual billed ledger rows."""
    pro = TEXT["gemini-3.1-pro-preview"]
    checks = [
        ("ledger id 72 (submission(5))",
         token_cost(pro, 17460, 2447 + 1273), 0.07956),
        ("ledger id 62 (submission(5))",
         token_cost(pro, 14417, 1579 + 3438), 0.08904),
        ("ledger id 81 (submission(1))",
         token_cost(pro, 6505, 400 + 391), 0.02250),
        ("generate_image mean",
         IMAGE["gemini-3-pro-image"] + token_cost(pro, 136, 1471), 0.15190),
        ("verify_planted_flaws mean",
         token_cost(pro, 1329, 92 + 1476), 0.02147),
    ]
    bad = 0
    for label, got, want in checks:
        good = abs(got - want) < 5e-5
        bad += not good
        print(f"  {'PASS' if good else 'FAIL'}  {label:<32} "
              f"${got:.5f} vs ${want:.5f}")
    calls, tin, _ = scoring_cohort(5000)
    for label, cond in [
        ("per-call input below 200K long-context tier", tin < LONG_CONTEXT_THRESHOLD),
        ("cohort call count == 5000 x calls/candidate",
         abs(calls - 5000 * CALLS_PER_CANDIDATE) < 1),
        ("image slope reconciles with Google's 1120/img rule",
         abs(SCORING_ITEM_JSON_IN + IMAGES_PER_RESPONSE * 1120
             - SCORING_PER_RESPONSE_IN) < 1),
    ]:
        bad += not cond
        print(f"  {'PASS' if cond else 'FAIL'}  {label}")
    print(f"\n  {'ALL CHECKS PASS' if not bad else str(bad) + ' FAILURES'}")
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidates", type=int, default=5000)
    ap.add_argument("--validate", action="store_true")
    ap.add_argument("--measure", metavar="DSN")
    args = ap.parse_args()

    if args.validate:
        raise SystemExit(1 if validate() else 0)
    if args.measure:
        return remeasure(args.measure)

    n = args.candidates
    calls, tin, tout = scoring_cohort(n)
    print(f"SCORING - cohort of {n:,} candidates")
    print(f"  R per candidate     {R_PER_CANDIDATE} responses (measured mean)")
    print(f"  calls               {calls:,.0f}  ({CALLS_PER_CANDIDATE} per candidate)")
    print(f"  per call            {tin:,.0f} in / {tout:,.0f} billed out")
    print(f"  cohort totals       {calls*tin/1e6:,.1f}M in / {calls*tout/1e6:,.1f}M out"
          f"  (64% of output is thinking)\n")
    base, rows = None, []
    for name, price in TEXT.items():
        c = token_cost(price, tin, tout) * calls
        base = base if base is not None else c
        rows.append((name, c, base / c, c * BATCH_DISCOUNT))
    w = max(len(r[0]) for r in rows)
    print(f"  {'model':<{w}}  {'cohort':>10}  {'saving':>7}  {'+batch 50%':>11}")
    for name, c, mult, batched in rows:
        mark = "  <- current" if c == base else ""
        print(f"  {name:<{w}}  ${c:>9,.2f}  {mult:>6.1f}x  ${batched:>10,.2f}{mark}")

    print(f"\nAUTHORING - one generator run "
          f"({sum(t['n'] for t in AUTHORING.values())} calls)")
    for name, price in TEXT.items():
        print(f"  {name:<28} ${authoring_run(price):>7.4f}")

    print("\nIMAGE - per generated image (flat fee + measured token cost)")
    for name, fee in IMAGE.items():
        tok = token_cost(TEXT["gemini-3.1-pro-preview"] if "pro" in name
                         else TEXT["gemini-3.1-flash-lite"],
                         IMAGE_CALL_IN, IMAGE_CALL_OUT)
        print(f"  {name:<30} ${fee:.4f} + ${tok:.4f} = ${fee+tok:.4f}")

    print("\nMEDIA_RESOLUTION - images are 67% of scoring INPUT tokens, but")
    print("  output dominates the bill, so the saving is small. image_ab grades")
    print("  by comparing two renders for planted defects - do not drop the tier")
    print("  without benchmarking that task.")
    for tier, tok in MEDIA_RESOLUTION_TOKENS.items():
        per_resp = SCORING_ITEM_JSON_IN + IMAGES_PER_RESPONSE * tok
        ti = SCORING_FIXED_IN + (R_PER_CANDIDATE / CALLS_PER_CANDIDATE) * per_resp
        to = (R_PER_CANDIDATE / CALLS_PER_CANDIDATE) * SCORING_PER_RESPONSE_OUT
        print(f"  {tier:<14} {tok:>5} tok/img   "
              f"pro ${token_cost(TEXT['gemini-3.1-pro-preview'], ti, to)*calls:>9,.2f}   "
              f"flash-lite ${token_cost(TEXT['gemini-3.1-flash-lite'], ti, to)*calls:>8,.2f}")

    print("\nVIDEO - per question (2 clips x 8s @ 720p).  No batch tier exists.")
    print(f"  {'model':<28} {'with audio':>11} {'video only':>11}")
    for name, (with_audio, silent) in VIDEO.items():
        print(f"  {name:<28} ${with_audio*16:>10.2f} ${silent*16:>10.2f}")


# Per operation, billed rows only (a refused call has no tokens). Latency is
# read through to_jsonb so the query also runs on a database that predates
# the `latency_ms` column; 0 (not measured) is left out of the average.
OPERATIONS_SQL = """
  SELECT operation, COUNT(*), COALESCE(AVG(tokens_in), 0),
         COALESCE(AVG(tokens_out), 0), COALESCE(AVG(thoughts_tokens), 0),
         SUM(thoughts_tokens)::float / NULLIF(SUM(tokens_out + thoughts_tokens), 0),
         SUM(cached_tokens)::float / NULLIF(SUM(tokens_in), 0),
         COALESCE(AVG(NULLIF((to_jsonb(u)->>'latency_ms')::int, 0)), 0),
         COALESCE(SUM(cost_usd), 0)
  FROM assessments_be_llm_usage u
  WHERE tokens_in > 0
  GROUP BY operation ORDER BY SUM(cost_usd) DESC
"""


def operations_table(cur):
    """Where the money and the time go, one line per ledger operation."""
    cur.execute(OPERATIONS_SQL)
    rows = cur.fetchall()
    print(f"  {'operation':<26} {'calls':>6} {'avg in':>8} {'avg out':>8} "
          f"{'avg think':>9} {'think%':>6} {'cached%':>7} {'avg s':>6} {'cost':>9}")
    for op, n, tin, tout, think, tshare, cshare, ms, cost in rows:
        print(f"  {op:<26} {n:>6} {tin:>8,.0f} {tout:>8,.0f} {think:>9,.0f} "
              f"{(tshare or 0) * 100:>5.0f}% {(cshare or 0) * 100:>6.0f}% "
              f"{(ms or 0) / 1000:>6.1f} ${cost:>8.4f}")
    if not rows:
        print("  (no billed calls in this ledger)")
    print("  avg s = mean wall time of the calls that recorded one (0.0: none did)\n")


def remeasure(dsn):
    """Re-derive the scoring token model from a live ledger, after the
    per-operation breakdown."""
    import psycopg2
    with psycopg2.connect(dsn) as conn, conn.cursor() as cur:
        operations_table(cur)
    q = """
      SELECT note, COUNT(*), AVG(tokens_in), AVG(tokens_out + thoughts_tokens)
      FROM assessments_be_llm_usage
      WHERE operation='score_subjective' AND note LIKE 'submission(%%'
      GROUP BY note ORDER BY note
    """
    with psycopg2.connect(dsn) as conn, conn.cursor() as cur:
        cur.execute(q)
        pts = []
        for note, cnt, ain, aout in cur.fetchall():
            n = int(note[note.index("(") + 1:note.index(")")])
            pts.append((n, float(ain), float(aout), cnt))
            print(f"  submission({n}): {cnt} calls, {ain:,.0f} in, {aout:,.0f} out")
    if len(pts) < 2:
        return print("need at least two distinct batch sizes to fit")
    lo, hi = min(pts), max(pts)
    per_in = (hi[1] - lo[1]) / (hi[0] - lo[0])
    per_out = (hi[2] - lo[2]) / (hi[0] - lo[0])
    print(f"\n  SCORING_PER_RESPONSE_IN  = {per_in:,.0f}")
    print(f"  SCORING_PER_RESPONSE_OUT = {per_out:,.0f}")
    print(f"  SCORING_FIXED_IN         = {lo[1] - per_in * lo[0]:,.0f}")


if __name__ == "__main__":
    main()
