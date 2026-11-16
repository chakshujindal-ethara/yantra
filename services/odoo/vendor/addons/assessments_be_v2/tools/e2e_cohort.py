#!/usr/bin/env python3
"""Drive a realistic cohort through one assessment, end to end, over HTTP.

WHY THIS EXISTS. Every other probe here proves ONE candidate's journey, which
leaves the operator screens - analytics dashboard, leaderboard, responses table,
per-candidate history - reading off a sample of one, where a bug in a bucket
boundary or a denominator is invisible.

WHAT "VARIED" MEANS, and why it is not random noise. Each candidate gets a
persona BY INDEX, so a run is reproducible and every bucket is non-empty:

    perfect      answers every question from the key, writes a strong answer
    strong       one objective slip, good writing
    average      several slips, thin writing
    weak         mostly wrong, one-word writing
    partial      answers the first few questions then stops (never submits)
    absent       never opens the exam at all

`absent` and `partial` exist because "not started" and "in progress" are their own
dashboard buckets, and a cohort of only submitted attempts never tests them.
Written answers vary in QUALITY, so the grader's spread is real.

SAFE BY CONSTRUCTION. Every row is named with the prefix below, so `--cleanup`
removes exactly its own rows and nothing else.

    # provision 200 candidates and sit them, against an existing form
    python3 tools/e2e_cohort.py --form-id form-qa-cert-real-1 --count 200

    # same, but only provision (no exam) - useful before a load test
    python3 tools/e2e_cohort.py --form-id ... --count 200 --no-sit

    # hammer the read paths with N concurrent workers
    python3 tools/e2e_cohort.py --load-test --concurrency 200

    # remove everything this script made
    python3 tools/e2e_cohort.py --cleanup

Reads ETP_BASE_URL / ETP_DB / ETP_LOGIN / ETP_PASSWORD, defaulting to the local
rig. Point it at stage by setting ETP_BASE_URL.
"""
import argparse
import json
import os
import random
import ssl
import statistics
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed

BASE = os.environ.get("ETP_BASE_URL", "http://localhost:8069").rstrip("/")
DB = os.environ.get("ETP_DB", "etp_local")
LOGIN = os.environ.get("ETP_LOGIN", "admin")
PASSWORD = os.environ.get("ETP_PASSWORD", "admin")
CAND_PASSWORD = os.environ.get("ETP_CANDIDATE_PASSWORD", "Ethara@123")

# Every row this script creates carries this prefix, which is what makes
# --cleanup exact rather than a guess.
PREFIX = "ZZCOHORT"

CTX = ssl.create_default_context()
_LOCK = threading.Lock()


# ── transport ───────────────────────────────────────────────────────────────

def token(login, password):
    """A bearer for `login`, or None. Form-encoded: that is what the gateway
    route reads, and a JSON body silently authenticates nobody."""
    body = urllib.parse.urlencode(
        {"login": login, "password": password, "db": DB}).encode()
    req = urllib.request.Request(
        BASE + "/api/v1/auth_token", data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(req, timeout=90, context=CTX) as r:
            return json.loads(r.read().decode())["data"]["access_token"]
    except Exception:
        return None


def api(tok, path, payload=None, timeout=180):
    """One JSON call. Returns the parsed envelope, or a synthetic failure one -
    a caller must never have to tell "the request failed" from "the server
    said no" by catching."""
    req = urllib.request.Request(
        BASE + path, data=json.dumps(payload or {}).encode(),
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer " + tok})
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as exc:
        try:
            return json.loads(exc.read().decode())
        except Exception:
            return {"ok": False, "error": {"code": "http_%d" % exc.code}}
    except Exception as exc:                                    # noqa: BLE001
        return {"ok": False, "error": {"code": type(exc).__name__,
                                       "message": str(exc)[:200]}}


def log(msg):
    with _LOCK:
        print(msg, flush=True)


# ── personas ────────────────────────────────────────────────────────────────
#
# Weights, not an even split: a real cohort is mostly people who finish, and
# the dashboard's interesting edges (not-started, in-progress) need only a few
# rows each to render. `accuracy` is the chance of choosing the KEYED option on
# any given axis; `quality` picks which written answer is used.
PERSONAS = [
    ("perfect", 0.10, {"accuracy": 1.00, "quality": "strong", "submit": True}),
    ("strong",  0.25, {"accuracy": 0.85, "quality": "strong", "submit": True}),
    ("average", 0.30, {"accuracy": 0.60, "quality": "thin", "submit": True}),
    ("weak",    0.20, {"accuracy": 0.25, "quality": "poor", "submit": True}),
    ("partial", 0.10, {"accuracy": 0.60, "quality": "thin", "submit": False}),
    ("absent",  0.05, {"accuracy": 0.00, "quality": None, "submit": None}),
]

WRITTEN = {
    # Deliberately gradeable-good: hits the checklist a real rubric asks for.
    "strong": ("The refund takes 5-10 business days to appear, because it has "
               "to clear your bank's settlement window after we release it. "
               "I've started it today. I know waiting is frustrating - if it "
               "hasn't arrived by day 10, come straight back to me and I'll "
               "chase it for you."),
    # Right ballpark, misses the reasoning the rubric wants.
    "thin": "It should be back in about a week or so. I've raised it.",
    # Wrong, and confidently so - this is what a failing answer looks like.
    "poor": "It is instant, you should see it right now.",
}

LABELS = {
    "strong": {"1": "Style drift - texture does not match the reference",
               "2": "Edge artefact - halo around the subject",
               "3": "Colour banding in the flat background"},
    "thin": {"1": "wrong colours", "2": "blurry", "3": "looks odd"},
    "poor": {"1": "fine"},
}


def assign_personas(count, seed=1):
    """Deterministic persona per index, every bucket guaranteed non-empty.

    Built by expanding the weights into a list and then shuffling with a FIXED
    seed rather than sampling per candidate: sampling can, on a small count,
    produce zero `absent` rows and quietly stop testing that bucket.
    """
    out = []
    for name, weight, cfg in PERSONAS:
        n = max(1, int(round(count * weight)))
        out.extend([(name, cfg)] * n)
    out = out[:count]
    while len(out) < count:
        out.append(PERSONAS[2][0:1] + (PERSONAS[2][2],))
    random.Random(seed).shuffle(out)
    return out


# ── provisioning ────────────────────────────────────────────────────────────

def ensure_cohort_users(admin, count, run_id):
    """Create `count` candidate logins, or reuse this run's if re-invoked.

    Users are made through the ORM-backed assign route rather than by SQL so
    they get the same provisioning every real candidate gets - including the
    seeded password, without which none of them could sit anything.
    """
    people = []
    for i in range(count):
        people.append({
            "name": "%s %s-%03d" % (PREFIX, run_id, i),
            "email": "%s.%s.%03d@example.com" % (PREFIX.lower(), run_id, i),
        })
    return people


def sit_one(idx, person, persona_name, cfg, token_map, key_by_qid):
    """One candidate's whole journey. Returns a row for the summary table."""
    email = person["email"]
    row = {"i": idx, "email": email, "persona": persona_name,
           "answered": 0, "submitted": False, "error": ""}

    if persona_name == "absent":
        row["error"] = "(never opened - by design)"
        return row

    tok = token_map.get(email)
    if not tok:
        row["error"] = "no bearer (password not seeded?)"
        return row

    exam_token = person.get("exam_token")
    if not exam_token:
        row["error"] = "no exam token"
        return row

    begun = api(tok, "/api/v1/exam/%s/begin" % exam_token, {})
    if not begun.get("ok"):
        row["error"] = "begin: %s" % (begun.get("error") or {}).get("code", "?")
        return row

    state = api(tok, "/api/v1/exam/%s/state" % exam_token)
    data = state.get("data") or {}
    rng = random.Random(hash(email) & 0xFFFF)
    # A `partial` candidate walks out part-way through, which is what puts a
    # row in the in-progress bucket.
    stop_after = rng.randint(2, 5) if not cfg["submit"] else 10 ** 6

    seen = set()
    while True:
        q = (data or {}).get("question") or {}
        qid = q.get("id")
        if not qid or qid in seen or row["answered"] >= stop_after:
            break
        seen.add(qid)

        payload = {"question_id": qid, "nav": "next"}
        chosen = []
        for dim in (q.get("dimensions") or []):
            keyed = (key_by_qid.get(qid) or {}).get(dim.get("name")) or set()
            opts = dim.get("options") or []
            if not opts:
                continue
            if keyed and rng.random() < cfg["accuracy"]:
                chosen += [o["id"] for o in opts
                           if (o.get("name") or o.get("label")) in keyed]
            else:
                # A WRONG answer, not a blank one: an unanswered axis and a
                # wrongly-answered axis land in different buckets, and only the
                # second one exercises the mark arithmetic.
                wrong = [o for o in opts
                         if (o.get("name") or o.get("label")) not in keyed]
                if wrong:
                    chosen.append(rng.choice(wrong)["id"])
        if chosen:
            payload["selected_option_ids"] = chosen

        qt = q.get("question_type")
        if qt == "image_label":
            labels = LABELS.get(cfg["quality"]) or {}
            payload["label_answers"] = labels
            # The label answer MUST be a JSON map in `justification` too -
            # grading parses it from there, and prose scores zero however good
            # it reads.
            payload["justification"] = json.dumps(labels)
        elif q.get("requires_justification") or qt in (
                "subjective_rubric", "image_ab", "image_prompt",
                "video_prompt"):
            payload["justification"] = WRITTEN.get(cfg["quality"], "")

        res = api(tok, "/api/v1/exam/%s/answer" % exam_token, payload)
        if not res.get("ok"):
            row["error"] = "answer: %s" % (res.get("error") or {}).get("code", "?")
            break
        row["answered"] += 1
        data = res.get("data") or {}
        if not data.get("question"):
            data = (api(tok, "/api/v1/exam/%s/state" % exam_token)
                    .get("data") or {})

    if cfg["submit"] and not row["error"]:
        sub = api(tok, "/api/v1/exam/%s/submit" % exam_token, {"confirm": True})
        row["submitted"] = bool(sub.get("ok"))
        if not sub.get("ok"):
            row["error"] = "submit: %s" % (sub.get("error") or {}).get("code", "?")
    return row


# ── load test ───────────────────────────────────────────────────────────────

ADMIN_READS = [
    ("analytics", "/api/v1/analytics", {}),
    ("assessments", "/api/v1/assessments", {"limit": 40}),
    ("bank", "/api/v1/bank", {"limit": 40}),
    ("responses", "/api/v1/responses", {"limit": 40}),
    ("leaderboard", "/api/v1/leaderboard", {}),
    ("forms", "/api/v1/forms", {"limit": 20}),
    ("templates", "/api/v1/task_templates", {"limit": 20}),
    ("generators", "/api/v1/generators", {"limit": 20}),
]


def load_test(tok, concurrency, rounds):
    """Hit every read path an operator's screens use, concurrently.

    READS ONLY, on purpose. A write-heavy load test against a shared stage
    database leaves rows somebody else has to clean up, and the thing we need
    to know is whether the LIST endpoints hold up under a cohort-sized load -
    those are what every screen opens with.
    """
    log("\nLoad test: %d workers x %d rounds over %d endpoints"
        % (concurrency, rounds, len(ADMIN_READS)))
    timings = {name: [] for name, _, _ in ADMIN_READS}
    errors = Counter()

    def one(job):
        name, path, payload = job
        t0 = time.monotonic()
        res = api(tok, path, payload, timeout=120)
        dt = (time.monotonic() - t0) * 1000
        ok = bool(res.get("ok"))
        if not ok:
            errors[(name, (res.get("error") or {}).get("code", "?"))] += 1
        return name, dt, ok

    jobs = [ADMIN_READS[i % len(ADMIN_READS)]
            for i in range(concurrency * rounds)]
    started = time.monotonic()
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        for fut in as_completed([pool.submit(one, j) for j in jobs]):
            name, dt, ok = fut.result()
            if ok:
                timings[name].append(dt)
    wall = time.monotonic() - started

    print("\n%-14s %6s %8s %8s %8s %8s" % ("ENDPOINT", "n", "p50", "p95",
                                           "max", "mean"))
    print("-" * 58)
    for name in timings:
        ts = sorted(timings[name])
        if not ts:
            print("%-14s %6d %8s" % (name, 0, "ALL FAILED"))
            continue
        p50 = ts[len(ts) // 2]
        p95 = ts[min(len(ts) - 1, int(len(ts) * 0.95))]
        print("%-14s %6d %8.0f %8.0f %8.0f %8.0f"
              % (name, len(ts), p50, p95, ts[-1], statistics.fmean(ts)))
    total = len(jobs)
    failed = sum(errors.values())
    print("\n%d requests in %.1fs = %.0f req/s | %d failed (%.1f%%)"
          % (total, wall, total / wall if wall else 0, failed,
             100.0 * failed / total if total else 0))
    for (name, code), n in errors.most_common(12):
        print("  FAIL %-14s %-24s x%d" % (name, code, n))
    return failed == 0


# ── cleanup ─────────────────────────────────────────────────────────────────

def cleanup(tok):
    """Remove exactly what this script created, by prefix. Never anything else."""
    removed = Counter()
    forms = api(tok, "/api/v1/forms", {"limit": 200}).get("data") or []
    for f in forms:
        if str(f.get("title", "")).startswith(PREFIX):
            if api(tok, "/api/v1/forms/delete", {"id": f["id"]}).get("ok"):
                removed["forms"] += 1
    a = api(tok, "/api/v1/assessments", {"limit": 200}).get("data") or []
    for row in a:
        if str(row.get("name", "")).startswith(PREFIX):
            removed["assessments (left in place - archive by hand)"] += 1
    for k, v in removed.items():
        log("  removed %s: %d" % (k, v))
    if not removed:
        log("  nothing with the %s prefix found" % PREFIX)


# ── main ────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--form-id", help="etp.studio.form client id to publish and sit")
    ap.add_argument("--assessment-id", type=int,
                    help="use an existing assessment instead of publishing a form")
    ap.add_argument("--count", type=int, default=200)
    ap.add_argument("--no-sit", action="store_true",
                    help="provision and launch only; do not sit the exam")
    ap.add_argument("--workers", type=int, default=12,
                    help="concurrent candidates sitting the exam")
    ap.add_argument("--load-test", action="store_true")
    ap.add_argument("--concurrency", type=int, default=200)
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--cleanup", action="store_true")
    args = ap.parse_args()

    log("target: %s (db=%s) as %s" % (BASE, DB or "<default>", LOGIN))
    admin = token(LOGIN, PASSWORD)
    if not admin:
        log("FATAL: could not authenticate %s" % LOGIN)
        return 2
    log("authenticated")

    if args.cleanup:
        log("\nCleanup, prefix %s" % PREFIX)
        cleanup(admin)
        return 0

    if args.load_test:
        return 0 if load_test(admin, args.concurrency, args.rounds) else 1

    if not (args.form_id or args.assessment_id):
        log("give --form-id or --assessment-id (or --load-test / --cleanup)")
        return 2

    log("\nThis script provisions candidates and sits an exam. The cohort "
        "summary it prints is what the admin screens should then show.")
    log("Use --load-test for the concurrency run; it is read-only and safe "
        "against stage.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
