"""Re-canonicalise every generator's stored SOP rating scheme.

    env -u PYTHONPATH .venv/bin/python src/odoo-bin shell \
      -c odoo.conf --no-http --http-port=8199 \
      < custom_addons/assessments_be_v2/tools/backfill_rating_schemes.py

WHY THIS EXISTS. `rating_scheme_json` stored whatever the SOP called each
dimension, upper-cased and nothing more - so a SOP whose final axis reads
"Overall Preference" was persisted with the code `OVERALL PREFERENCE`. That code
is then handed to the generation model with the instruction to emit it verbatim
into `construction_keys`, and `validate_flaw_plan` requires an Overall Choice
(OC) dimension. Result: every image_ab item the model faithfully produced was
rejected, the generator reported "Done" with zero drafts, and the LLM call was
paid for. Deterministic, not flaky - it failed five items out of five, every
run, on any SOP that used its own wording for the overall axis.

The extractor now canonicalises on write. Schemes already on disk do not fix
themselves, so this walks them.

WHAT IT CHANGES. Only `rating_scheme_json`, and only two things inside it:

  * dimension `code` -> its canonical form ("OVERALL PREFERENCE" -> "OC",
    "INSTRUCTION FOLLOWING" -> "IF"). A dimension the platform has no code for
    keeps its own, exactly as before - the registry is self-extending.
  * dimension `options`, on preference_comparison schemes ONLY -> the platform's
    verdict vocabulary ("Image A" -> "Response A", "Tie" -> "Both Good"). An
    independent-questions scheme keeps YES/NO and friends untouched: those are
    not A/B picks and rewriting one would move an answer key.

`label` is never touched. The SOP's own wording is what a reviewer and a
candidate should read; only the machine value is canonicalised.

WHAT IT DOES NOT CHANGE. No question, draft or answer key is rewritten. Drafts
already authored under a non-canonical scheme are unaffected - re-run generation
on the generators listed below if you want items from them.

IDEMPOTENT. Re-running reports nothing moved.
"""
import json

from odoo.addons.assessments_be_v2.services import vertex

Prompt = env["assessments.be.prompt"]

generators = Prompt.search([("rating_scheme_json", "!=", False)])
print(f"Checking {len(generators)} generator(s) with a stored rating scheme...")

moved, failed = [], []
for gen in generators:
    try:
        raw = json.loads(gen.rating_scheme_json or "{}")
    except (ValueError, TypeError) as exc:
        failed.append((gen.id, gen.name, f"unparseable: {exc}"))
        continue
    # Straight back through the extractor's own normaliser, so this script and
    # the live write path can never drift apart on what "canonical" means.
    fixed = vertex._normalize_rating_scheme(raw)
    if not fixed:
        failed.append((gen.id, gen.name, "normalised to nothing; left alone"))
        continue
    before = {d.get("code") for d in (raw.get("dimensions") or [])}
    after = {d.get("code") for d in fixed["dimensions"]}
    new_json = json.dumps(fixed, ensure_ascii=False)
    if new_json == (gen.rating_scheme_json or "").strip():
        continue
    gen.write({"rating_scheme_json": new_json})
    moved.append((gen.id, gen.name, sorted(before - after), sorted(after - before)))

env.cr.commit()

print(f"\n{len(moved)} generator(s) re-canonicalised.")
for gen_id, name, was, now in moved:
    print(f"  generator {gen_id:>6}  {name!r}")
    if was or now:
        print(f"      codes {was or '[]'} -> {now or '[]'}")

if failed:
    print(f"\n! {len(failed)} generator(s) skipped:")
    for gen_id, name, why in failed:
        print(f"  generator {gen_id}: {name!r} - {why}")

# The invariant the change establishes: no stored scheme still carries a code
# that means Overall Choice without BEING Overall Choice. A survivor here is a
# generator whose next image_ab run would be rejected item for item.
suspects = []
for gen in Prompt.search([("rating_scheme_json", "!=", False)]):
    try:
        dims = (json.loads(gen.rating_scheme_json or "{}").get("dimensions")
                or [])
    except (ValueError, TypeError):
        continue
    for d in dims:
        code = str(d.get("code") or "")
        canon, _label = vertex.ab_normalize_dim_key(code)
        if canon != code.upper() and canon:
            suspects.append((gen.id, code, canon))

if suspects:
    print("\n! Codes that STILL do not match their canonical form:")
    for gen_id, code, canon in suspects:
        print(f"  generator {gen_id}: {code!r} should be {canon!r}")
else:
    print("\nEvery stored dimension code is canonical.")
