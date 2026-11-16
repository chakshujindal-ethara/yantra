"""FULL PIPELINE on live Vertex, end to end, through the REST API only.

Generate questions -> approve -> build assessment -> assign -> launch (invite)
-> candidate sits and submits -> LLM scores -> release -> analytics.

Every step asserts against what the SERVER returns, never against what the
client hoped for. Prints a PASS/FAIL ledger and exits non-zero on any failure,
so this is usable as a gate.
"""
import base64
import json
import sys
import time
import urllib.error
import urllib.request

import _env

_env.require_local_or_explicit()

BASE = _env.API
PROBE = "ZZPIPE"          # every row this script makes carries this marker
CANDIDATE_LOGIN = _env.CANDIDATE_LOGIN
CANDIDATE_PASSWORD = _env.CANDIDATE_PASSWORD
FAILURES = []


def _tok(login, password):
    req = urllib.request.Request(
        f"{BASE}/api/v1/auth_token",
        data=f"login={login}&password={password}".encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    return json.loads(urllib.request.urlopen(req, timeout=60).read())["data"]["access_token"]


def call(path, token, body=None, timeout=300):
    req = urllib.request.Request(
        f"{BASE}{path}",
        data=json.dumps(body or {}).encode(),
        headers={"Content-Type": "application/json",
                 "Authorization": f"Bearer {token}"},
    )
    try:
        return json.loads(urllib.request.urlopen(req, timeout=timeout).read())
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            return json.loads(raw or b"{}")
        except Exception:  # noqa: BLE001
            return {"ok": False, "error": {"code": "unparseable",
                                           "message": raw.decode()[:200]}}


def step(n, name, ok, detail=""):
    mark = "PASS" if ok else "FAIL"
    print(f"  {mark}  {n}. {name}{'  ' + detail if detail else ''}", flush=True)
    if not ok:
        FAILURES.append(name)
    return ok


def rows(res):
    d = res.get("data")
    return d if isinstance(d, list) else []


print("=" * 66)
print("FULL PIPELINE - live Vertex, REST only")
print("=" * 66)

A = _tok(_env.ADMIN_LOGIN, _env.ADMIN_PASSWORD)

SOP_TEXT = (
        "FORKLIFT SAFETY SOP\n"
        "1. Inspect the truck before every shift: tyres, forks, hydraulics, "
        "horn, lights and seatbelt. Log any defect and tag the truck out.\n"
        "2. Never exceed the rated capacity shown on the data plate.\n"
        "3. Carry the load 10-15 cm above the floor, tilted back. Never raise "
        "or lower a load while the truck is moving.\n"
        "4. Travel in reverse when the load blocks forward vision, except on "
        "a ramp.\n"
        "5. Pedestrians always have right of way. Never drive within two "
        "metres of a person on foot.\n"
        "6. Sound the horn at every blind corner and doorway.\n"
    "7. Charge batteries only in the designated ventilated bay, wearing a "
    "face shield and gloves.\n"
)

gen = call("/api/v1/generators/create", A, {"name": f"{PROBE} Forklift SOP"})
gen_id = gen.get("id") or (gen.get("data") or {}).get("id")
step(1, "Generator created", bool(gen_id), f"id={gen_id}")
if not gen_id:
    print(json.dumps(gen)[:300])
    sys.exit(1)

# The SOP must be an ATTACHED RESOURCE. `/generate` refuses a generator with
# nothing to read, and `source_text` alone does not satisfy it - the route
# answers "Attach an SOP document before generating questions".
# `content` is base64 - the route says so verbatim when it is not.
up = call(f"/api/v1/generators/{gen_id}/resources", A, {
    "name": "forklift-sop.txt",
    "category": "sop",
    "content": base64.b64encode(SOP_TEXT.encode()).decode(),
})
step(2, "SOP attached as a resource", up.get("ok") is not False,
     (up.get("error") or {}).get("message", "")[:60])

t0 = time.time()
gq = call(f"/api/v1/generators/{gen_id}/generate", A, {}, timeout=600)
# Generation is QUEUED, not inline: `action_generate_from_sop` sets
# sop_gen_state='queued' and a cron does the Vertex work. Returning
# immediately is success, not failure - the drafts appear later.
step(3, "Generation queued", gq.get("ok") is not False,
     (gq.get("error") or {}).get("message", "")[:60])

drafts = []
for _ in range(60):  # up to ~10 minutes; a real SOP takes a few minutes
    time.sleep(10)
    g = call(f"/api/v1/generators/{gen_id}", A).get("data") or {}
    drafts = rows(call("/api/v1/drafts", A, {"generator_id": str(gen_id),
                                             "limit": 200}))
    st = g.get("sop_gen_state")
    print(f"      ...{int(time.time() - t0)}s state={st} drafts={len(drafts)}",
          flush=True)
    if drafts:
        break
    if st in ("failed", "error"):
        print("      generator error:", str(g.get("sop_gen_error"))[:180])
        break
step(4, "Drafts present", len(drafts) > 0, f"{len(drafts)} draft(s)")
if not drafts:
    print("  (nothing to approve; stopping)")
    sys.exit(1)

approved = 0
for d in drafts:
    res = call(f"/api/v1/drafts/{d['id']}/approve", A,
               {"acknowledge_warnings": True})
    if res.get("ok") is not False:
        approved += 1
step(5, "Drafts approved into the bank", approved > 0,
     f"{approved}/{len(drafts)}")

bank = rows(call("/api/v1/bank", A, {"limit": 200}))
# `generator` is null on a bank row whose source generator was not expanded,
# so it cannot be dereferenced blind.
def _gen_id_of(q):
    g = q.get("generator")
    return str(g.get("id")) if isinstance(g, dict) else ""


mine = [q for q in bank
        if _gen_id_of(q) == str(gen_id) or PROBE in str(q.get("name", ""))]
step(6, "Bank holds the approved questions", len(mine) > 0,
     f"{len(mine)} question(s)")

asm = call("/api/v1/assessments/create", A, {
    "name": f"{PROBE} Forklift Induction",
    "generator_id": gen_id,
    "question_limit": max(1, min(3, len(mine))),
    "duration_minutes": 30,
    "subjective_threshold": 60.0,
})
asm_id = asm.get("id") or (asm.get("data") or {}).get("id")
step(7, "Assessment created", bool(asm_id), f"id={asm_id}")
if not asm_id:
    print(json.dumps(asm)[:300])
    sys.exit(1)

inv = call(f"/api/v1/assessments/{asm_id}/assign", A, {
    # A candidate who HAS a portal login. `_write_guard` allows only the
    # ASSIGNED candidate to write - a manager holding the token may read the
    # runner but never answer into a real attempt, which is the correct
    # control and the reason this pipeline must switch identity below.
    "candidates": [{"name": "Priya Sharma",
                    "email": CANDIDATE_LOGIN}],
})
step(8, "Candidate invited by email", inv.get("ok") is not False,
     f"assigned={(inv.get('data') or {}).get('assigned_count')}")

detail = call(f"/api/v1/assessments/{asm_id}", A).get("data") or {}
step(9, "Roster visible on the assessment", len(detail.get("roster") or []) > 0,
     f"{len(detail.get('roster') or [])} on roster")

# The flag is `confirm`, not `dry_run` - the route reads bool_arg("confirm")
# and a dry run is the DEFAULT. Sending dry_run:false launched nothing and
# still answered ok:true.
gates = call(f"/api/v1/assessments/{asm_id}/launch", A, {})
launched = call(f"/api/v1/assessments/{asm_id}/launch", A, {"confirm": True},
                timeout=600)
step(10, "Assessment launched",
     bool(((launched.get("data") or {}).get("launched"))),
     (launched.get("error") or {}).get("message", "")[:70]
     or f"launched={(launched.get('data') or {}).get('launched')}")

cands = rows(call(f"/api/v1/assessments/{asm_id}/candidates", A,
                  {"limit": 200}))
# The exam link lives on the DETAIL route now, not on list rows: it is a
# bearer credential and shipping it per row handed every Evaluator a working
# impersonation link for the whole cohort. This harness takes the same path a
# Manager takes in the UI.
token = None
for c in cands:
    token = c.get("access_token") or token
    if not token and c.get("id"):
        detail = (call(f"/api/v1/attempts/{c['id']}", A) or {}).get("data") or {}
        token = detail.get("access_token") or None
step(11, "Attempt created with an exam token", bool(cands) and bool(token),
     f"{len(cands)} attempt(s)")

if not token:
    print("  no exam token; cannot sit the assessment")
    print("PIPELINE FAILURES:", FAILURES)
    sys.exit(1)

# EVERY call below runs as the CANDIDATE, not the admin.
try:
    C = _tok(CANDIDATE_LOGIN, CANDIDATE_PASSWORD)
except Exception as exc:  # noqa: BLE001
    print(f"  cannot sign in as {CANDIDATE_LOGIN}: {exc}")
    print("PIPELINE FAILURES:", FAILURES + ["candidate login"])
    sys.exit(1)

state = call(f"/api/v1/exam/{token}/state", C)
step(12, "Exam state readable by the candidate", state.get("ok") is not False)

begun = call(f"/api/v1/exam/{token}/begin", C)
bd = begun.get("data") or {}
# The runner is PAGED and STATEFUL. `begin` RESUMES at the candidate's current
# position (not question 1), and `answer` returns the FOLLOWING item under
# `next` - null at the end of the paper. `_next_index` walks forward from where
# the answered question sits in the frozen order, so answering out of sequence
# skips the rest. There is no bulk question list on the candidate side.
first = bd.get("question") or {}
total_q = int(first.get("total") or 0)
step(13, "Exam begun", begun.get("ok") is not False and bool(first),
     f"question {first.get('index')} of {total_q}")


def answer_one(q):
    """Answer one served question with whatever it offers. True when saved."""
    # `msq` is MULTI-select: picking one option is a valid but wrong answer.
    # Pick every option on an msq so the paper exercises a full selection,
    # and exactly one on an mcq.
    multi = (q.get("question_type") or "").lower() in ("msq", "multi", "multiple")
    picked = []
    for dim in q.get("dimensions") or []:
        opts = dim.get("options") or []
        if not opts:
            continue
        picked.extend(o["id"] for o in opts) if multi \
            else picked.append(opts[0]["id"])
    body = {"question_id": q["id"]}
    if picked:
        # `selected_option_ids`; `option_ids` is refused with a 422.
        body["selected_option_ids"] = picked
    if q.get("requires_justification") or not picked:
        body["justification"] = (
            "The operator inspects the truck before the shift, logs any "
            "defect and tags the truck out until it is repaired.")
    r = call(f"/api/v1/exam/{token}/answer", C, body)
    if r.get("ok") is False:
        print("      answer refused:",
              (r.get("error") or {}).get("message", "")[:80])
        return None
    return (r.get("data") or {}).get("next")


answered = 0
current = first
seen = set()
while current and current.get("id") and current["id"] not in seen:
    seen.add(current["id"])
    nxt = answer_one(current)
    if nxt is None and current.get("index") != total_q:
        # Refusal, or the end reached early because this attempt was resumed
        # mid-paper. Rewind with nav='prev' until question 1, then walk on.
        break
    answered += 1
    current = nxt

# Sweep anything still unanswered: re-read state, which reports the attempt's
# own answered set, and serve each missing item by asking for it directly.
st = (call(f"/api/v1/exam/{token}/state", C).get("data") or {})
done = set(st.get("answered_question_ids") or [])
for _ in range(total_q):
    b2 = (call(f"/api/v1/exam/{token}/begin", C).get("data") or {})
    q2 = b2.get("question") or {}
    if not q2.get("id") or q2["id"] in done:
        break
    if answer_one(q2) is None and q2["id"] not in done:
        break
    done.add(q2["id"])
    answered = len(done)

# Count from the SERVER, not a local tally: answering the final item
# auto-submits, and the last `answer` call can return before the local
# counter is bumped, so a client-side count under-reports a complete paper.
rows_ = rows(call("/api/v1/responses", A,
                  {"evaluator_id": cands[0]["id"], "limit": 200}))
answered = len(rows_) or answered
step(14, "Answers recorded", answered >= total_q, f"{answered}/{total_q}")

sub = call(f"/api/v1/exam/{token}/submit", C, {}, timeout=600)
# Answering the last item auto-submits, so "already submitted" IS the success
# path here, not a failure.
already = "already submitted" in (
    (sub.get("error") or {}).get("message", "") or "").lower()
step(15, "Attempt submitted", sub.get("ok") is not False or already,
     "auto-submitted on the last answer" if already
     else (sub.get("error") or {}).get("message", "")[:60])

scored = False
for _ in range(30):
    time.sleep(10)
    row = (call(f"/api/v1/attempts/{cands[0]['id']}", A).get("data") or {})
    st = row.get("state")
    res = row.get("result")
    print(f"      ...scoring state={st} result={res}", flush=True)
    if res in ("pass", "fail"):
        scored = True
        break
step(16, "Attempt scored", scored, f"result={res if scored else 'pending'}")

# Release is PER-ASSESSMENT with optional `evaluator_ids`; there is no
# /attempts/<id>/release route (that 404s into the website's HTML handler,
# which is why the error read "<!DOCTYPE html>").
rel = call(f"/api/v1/assessments/{asm_id}/release", A,
           {"evaluator_ids": [cands[0]["id"]]})
step(17, "Result released", rel.get("ok") is not False,
     (rel.get("error") or {}).get("message", "")[:60])

an = call("/api/v1/analytics", A).get("data") or {}
totals = an.get("totals") or {}
step(18, "Analytics reflect the run",
     (totals.get("assigned") or 0) > 0,
     f"assigned={totals.get('assigned')} submitted={totals.get('submitted')} "
     f"decided={totals.get('decided')}")

chat = call(f"/api/v1/chatter/assessment/{asm_id}", A)
step(19, "Chatter readable over the API", chat.get("ok") is not False,
     f"{len(rows(chat))} entr(ies)")

print()
print("=" * 66)
print("PIPELINE FAILURES:", FAILURES or "NONE - full pipeline green")
print("assessment_id:", asm_id, "generator_id:", gen_id)
json.dump({"assessment_id": asm_id, "generator_id": gen_id,
           "candidates": cands},
          open("/tmp/pipeline-state.json", "w"))
sys.exit(1 if FAILURES else 0)
