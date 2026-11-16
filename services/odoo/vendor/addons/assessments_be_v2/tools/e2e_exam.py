#!/usr/bin/env python3
"""Part 2 of the product loop: schedule -> sit the exam -> score -> release.

    python3 tools/e2e_exam.py <generator_id>

Runs entirely through the SAME HTTP API the Flutter app uses, because the app
is the product. Driving the model layer directly would prove the module works
and say nothing about whether a screen can reach it.

Answers every question type the bank happens to hold, using the shape
`candidate.py::_record_response` actually requires:
  mcq / msq / image_ab -> selected_option_ids
  subjective_rubric / image_prompt / video_prompt -> justification text
  image_label -> label_<n> fields collected into JSON
"""

import json
import sys
import time
import urllib.error
import urllib.request

import _env

_env.require_local_or_explicit()

BASE = _env.API


def call(path, body=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer %s" % token
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        "%s%s" % (BASE, path), data=data, headers=headers,
        method="POST" if data is not None else "GET")
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return json.loads(raw)
        except ValueError:
            return {"ok": False, "error": {"code": "http_%s" % e.code,
                                           "message": raw[:200]}}
    except urllib.error.URLError as e:
        # The server being down is an OPERATOR problem, not a bug in this
        # script, and a 40-line urllib traceback buries that. Say it plainly
        # and stop - a restart mid-run used to produce a wall of stack frames
        # that read like the script had crashed.
        sys.exit(
            "\nCANNOT REACH %s (%s)\n"
            "The Odoo backend is not answering. Start it with:\n"
            "  cd /Users/cj/Developer/ops-ethara-backend && env -u PYTHONPATH \\\n"
            "    .venv/bin/python src/odoo-bin -c odoo.local.conf -d ethara_ops\n"
            % (BASE, getattr(e, "reason", e)))


def require_backend():
    """Fail fast, and legibly, when the backend is not answering.

    `login` runs before anything else, so a stopped or restarting Odoo lands
    there first - and an unguarded urlopen turns "the server is down" into a
    40-line urllib traceback that reads like this script crashed. Checking once
    up front means the operator sees one sentence and the fix.
    """
    try:
        urllib.request.urlopen("%s/web/login" % BASE, timeout=5)
    except Exception as exc:                                    # noqa: BLE001
        sys.exit(
            "\nCANNOT REACH %s (%s)\n"
            "The Odoo backend is not answering. Start it with:\n"
            "  cd /Users/cj/Developer/ops-ethara-backend && env -u PYTHONPATH \\\n"
            "    .venv/bin/python src/odoo-bin -c odoo.local.conf -d ethara_ops\n"
            % (BASE, getattr(exc, "reason", exc)))


def login(user="admin", pwd="admin"):
    body = ("login=%s&password=%s" % (user, pwd)).encode()
    req = urllib.request.Request(
        "%s/api/v1/auth_token" % BASE, data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())["data"]["access_token"]


def step(n, label):
    print("\n[%s] %s" % (n, label), flush=True)


def die(msg, payload=None):
    print("  FAILED: %s" % msg)
    if payload is not None:
        print("  %s" % json.dumps(payload)[:500])
    sys.exit(1)


gen = int(sys.argv[1]) if len(sys.argv) > 1 else 0
require_backend()
tok = login()

bank = call("/api/v1/bank", token=tok).get("data", [])
print("bank holds %d approved questions" % len(bank))
if not bank:
    die("bank is empty - run e2e_loop.py first")

ASM_NAME = "Forklift Safety - Induction E2E"
RESUME = int(sys.argv[2]) if len(sys.argv) > 2 else 0

step(1, "Create an assessment bound to the generator")
if not RESUME:
    # Auto-resume by NAME so a bare re-run does not pile up assessments. The
    # explicit id argument still wins when given. Without this, every run
    # created another "Forklift Safety - Induction E2E" in the user's database
    # and a run that died mid-launch left one stranded in draft.
    for a in (call("/api/v1/assessments", token=tok).get("data") or []):
        if a.get("name") == ASM_NAME:
            RESUME = a["id"]
            break

if RESUME:
    asm = RESUME
    d = call("/api/v1/assessments/%s" % asm, token=tok).get("data", {})
    print("  resuming assessment id=%s state=%s" % (asm, d.get("state")))
r = None if RESUME else call("/api/v1/assessments/create", {
    "name": ASM_NAME,
    "generator_id": gen,
    "question_limit": 0,          # 0 = serve every question in the bank
    "duration_minutes": 30,
    "results_release": "manual",  # prove the release gate, do not bypass it
    "subjective_threshold": 70.0,
}, tok)
if r is not None:
    if not r.get("ok"):
        die("assessment create", r)
    asm = r["data"]["id"]
    print("  assessment id=%s state=%s" % (asm, r["data"].get("state")))

step(2, "Assign a candidate")
r = {"ok": True, "data": {"resumed": True}} if RESUME else call("/api/v1/assessments/%s/assign" % asm, {
    "candidates": [{"name": "Priya Sharma", "email": _env.CANDIDATE_LOGIN}],
}, tok)
if not r.get("ok"):
    die("assign", r)
print("  assigned: %s" % json.dumps(r["data"])[:180])

step(3, "Launch (draws questions, provisions portal users, queues invites)")
# The route is a DRY RUN by default and reports all 7 gates at once, so an
# admin fixes everything in one pass instead of discovering problems one
# raise at a time. `confirm` is what actually starts it.
r = {"ok": True, "data": {"gates": [], "can_launch": True}} if RESUME \
    else call("/api/v1/assessments/%s/launch" % asm, {}, tok)
if not r.get("ok"):
    die("launch preflight", r)
for g in r["data"].get("gates", []):
    print("  gate %-22s %s%s" % (g["code"], "PASS" if g["passed"] else "FAIL",
                                 "" if g["passed"] else "  " + g.get("reason", "")))
if not r["data"].get("can_launch"):
    die("launch gates refuse")

if not RESUME:
    r = call("/api/v1/assessments/%s/launch" % asm, {"confirm": True}, tok)
    if not r.get("ok"):
        die("launch confirm", r)
    print("  launched=%s" % r["data"].get("launched"))
else:
    print("  already launched")

cands = call("/api/v1/assessments/%s/candidates" % asm, token=tok).get("data", [])
if not cands:
    die("launch produced no candidate rows")
cand = cands[0]
# The list no longer carries the exam link (bearer credential); a Manager
# reads it from the attempt detail, so this does too.
token = cand.get("access_token") or cand.get("token")
if not token:
    cand_detail = call("/api/v1/attempts/%s" % cand.get("id"),
                       token=tok).get("data") or {}
    token = cand_detail.get("access_token")
print("  candidate=%s attempt=%s token=%s"
      % (cand.get("applicant_name"), cand.get("id"),
         (token or "")[:12] + "..."))
if not token:
    die("no access token on the attempt - cannot sit the exam", cand)

step(4, "Sit the exam as the CANDIDATE (their own session + their token)")
# auth="user" on every exam route: the token says WHICH attempt, the session
# says WHO. A leaked token alone cannot sit somebody else's exam.
ctok = login(cand.get("email") or _env.CANDIDATE_LOGIN,
              _env.CANDIDATE_PASSWORD)
print("  signed in as the candidate, token len=%d" % len(ctok))
r = call("/api/v1/exam/%s/begin" % token, {}, ctok)
if not r.get("ok"):
    code = (r.get("error") or {}).get("code") or r.get("code")
    # An already-submitted attempt is the CORRECT refusal on a re-run, not a
    # failure of the loop. Treating it as fatal made this script report a red
    # exit for a database that was in exactly the state the script had put it
    # in, which is a false alarm that outlives the run and misleads later.
    if code == "attempt_locked":
        print("  already submitted - verifying the finished attempt instead")
        st = call("/api/v1/exam/%s/state" % token, token=ctok).get("data", {})
        res = st.get("result") or {}
        print("  outcome=%s released=%s marks=%s result=%s"
              % (st.get("outcome"), res.get("released"),
                 res.get("score_marks"), res.get("result")))
        if st.get("outcome") != "complete":
            die("a locked attempt should report outcome=complete", st)
        raise SystemExit(0)
    die("begin", r)

state = call("/api/v1/exam/%s/state" % token, token=ctok).get("data", {})
order = state.get("question_order") or []
print("  %d questions drawn, deadline=%s"
      % (len(order), state.get("deadline")))

answered = 0
for qid in order:
    q = call("/api/v1/exam/%s/state?question_id=%s" % (token, qid), token=ctok).get("data", {})
    item = q.get("question") or {}
    qtype = item.get("question_type") or ""

    payload = {"question_id": qid}
    if qtype in ("mcq", "msq", "image_ab"):
        # Pick the FIRST option of every dimension. Deliberately not the
        # correct one: a scoring pipeline that only works on right answers is
        # not proven, and a wrong answer exercises the same code path.
        picks = []
        for dim in item.get("dimensions") or []:
            opts = dim.get("options") or []
            if opts:
                picks.append(opts[0]["id"])
        if not picks:
            print("    skip q%s (%s): no options served" % (qid, qtype))
            continue
        # `selected_option_ids`, NOT `option_ids`. The route
        # (controllers/api/candidate.py:616) reads only the former, so every
        # objective answer this harness "recorded" was stored BLANK - and
        # because steps 6-8 below printed without asserting, it still exited 0.
        # It reported green while proving nothing about objective scoring.
        payload["selected_option_ids"] = picks
    elif qtype == "image_label":
        # `label_answers` as an OBJECT keyed by box number, and the numbers
        # come from `label_boxes`. Both halves were wrong: the route reads
        # only `label_answers` (`_collect_label_answers`, candidate.py:596) and
        # never a `label_<n>` scalar, and the envelope carries `label_boxes`
        # (`_label_boxes`, candidate.py:544) with no `label_slots` anywhere in
        # the module. So the payload was empty on arrival, `justification`
        # stayed "" through candidate.py:653-656, the subjective guard at :660
        # refused it, and every labelling question 422'd. The harness printed
        # the refusal without asserting and still exited 0 - so this question
        # type has never once been proven end to end.
        boxes = item.get("label_boxes") or []
        if not boxes:
            print("    skip q%s (%s): no label boxes served" % (qid, qtype))
            continue
        payload["label_answers"] = {
            str(n): "Component %s" % n for n in boxes
        }
    else:
        payload["justification"] = (
            "The operator must complete a documented pre-shift inspection, "
            "confirm the rated capacity on the data plate against the load, "
            "keep forks 100-150 mm above the floor while travelling, and "
            "sound the horn at every blind corner.")

    r = call("/api/v1/exam/%s/answer" % token, payload, ctok)
    if r.get("ok"):
        answered += 1
    else:
        print("    q%s (%s) refused: %s"
              % (qid, qtype, r.get("error", {}).get("message", "")[:90]))

print("  answered %d/%d" % (answered, len(order)))
# ASSERTED, not just printed. A harness whose middle step can record zero
# answers and still exit 0 is worse than no harness - that is exactly how the
# `option_ids` bug survived.
if answered < len(order):
    die("answering", {"error": {"message":
        "only %d of %d answers were accepted" % (answered, len(order))}})

step(5, "Submit the attempt")
r = call("/api/v1/exam/%s/submit" % token, {"force": True}, ctok)
if not r.get("ok"):
    die("submit", r)
print("  submitted: state=%s" % r["data"].get("state"))

step(6, "Queue subjective scoring and wait for the cron")
r = call("/api/v1/scoring/queue", {"assessment_id": asm}, tok)
print("  queued: %s" % ("ok" if r.get("ok") else r.get("error")))
if not r.get("ok"):
    die("scoring queue", r)

deadline = time.time() + 420
last = None
while time.time() < deadline:
    time.sleep(10)
    rows = call("/api/v1/assessments/%s/candidates" % asm, token=tok).get("data", [])
    if not rows:
        break
    ev = rows[0]
    now = (ev.get("llm_state"), ev.get("result"))
    if now != last:
        print("  llm_state=%s result=%s score=%s"
              % (ev.get("llm_state"), ev.get("result"),
                 ev.get("score_marks_display") or ev.get("score")), flush=True)
        last = now
    if ev.get("llm_state") in ("scored", "error", "not_needed"):
        break
else:
    die("scoring", {"error": {"message": "grading did not settle within 420s"}})
if last and last[0] == "error":
    die("scoring", {"error": {"message": "grading finished in state 'error'"}})

step(7, "Release results (the gate that reveals a score to a candidate)")
r = call("/api/v1/assessments/%s/release" % asm, {}, tok)
print("  released: %s" % ("ok" if r.get("ok") else r.get("error")))
if not r.get("ok"):
    die("release", r)

rows = call("/api/v1/assessments/%s/candidates" % asm, token=tok).get("data", [])
for ev in rows:
    print("  RESULT %s -> %s  marks=%s  llm=%s  released=%s"
          % (ev.get("applicant_name"), ev.get("result"),
             ev.get("score_marks_display") or ev.get("score"),
             ev.get("llm_state"), ev.get("results_released")))
    # The whole point of step 7: a release that does not release is a silent
    # failure of the last gate in the product.
    if not ev.get("results_released"):
        die("release", {"error": {"message":
            "%s still shows results_released=False after release"
            % ev.get("applicant_name")}})

step(8, "Read it back from the CANDIDATE surface")
me = call("/api/v1/exam/%s/state" % token, token=ctok).get("data", {})
res = me.get("result") or {}
print("  candidate sees: gate=%s released=%s status=%s label=%r"
      % (me.get("gate"), res.get("released"), res.get("status"),
         res.get("label")))
# INVARIANT 3 from the candidate's side: after release, the candidate's own
# surface must actually show the result. This never asserted, so a release that
# reached the admin row but not the candidate looked like success.
if not res.get("released"):
    die("candidate read-back",
        {"error": {"message": "candidate still sees released=False after "
                              "the admin release succeeded"}})

print("\nASSESSMENT=%s ANSWERED=%s" % (asm, answered))
print("ALL 8 STEPS PASSED")
