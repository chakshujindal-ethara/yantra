#!/usr/bin/env python3
"""Find the concurrency at which this deployment stops holding, before a cohort does.

WHY THIS EXISTS, and why the existing load test could not answer it. There was
already a `--load-test` in tools/e2e_cohort.py, and it says so in its own
docstring: "READS ONLY, on purpose." That makes it safe against a shared stage
database and useless for the question that matters. On 2026-09-03 the failure was
on the WRITE path - `/answer` was 86.6% of all database traffic (12.4M of 14.3M
queries in three hours) and 82 of 100 concurrent candidates failed. A read-only
harness cannot see that, cannot exercise the 503 shed, and cannot measure any of
the write reductions made since.

WHAT A RUNG ACTUALLY DOES. It sits real candidates through real HTTP against
`/api/v1/exam/...`: begin, answer every question, submit (what "answer" means
is the `--mode`, below). Not the ORM - an in-process harness shares the test's
own cursor and would report a healthy server no matter how few workers were
configured, which is precisely the misconfiguration that caused the outage
(`workers = 0`). The transport is the thing under test.

THE THREE THINGS THIS REFUSES TO DO QUIETLY
-------------------------------------------
1. **Report green on a load that never happened.** Every rung records the peak
   number of requests genuinely in flight. If the harness asked for 500 and the
   machine only ever had 40 outstanding, the rung is marked UNACHIEVED and does
   not count towards the knee - a laptop cannot generate a stage-sized load, and
   a number that came from a starved client is worse than no number. (A paced
   sitting - `--autosave-gap-s` above 0 with autosaves - is mostly thinking, so
   few requests overlap by design; those rungs count candidates concurrently
   mid-sitting instead.)
2. **Count a shed as a failure.** A 503 with `Retry-After` is the server
   working: it is the designed response to pool exhaustion, and treating it as
   an error would report a correctly-degrading deployment as a broken one. Sheds
   are counted and reported in their own column, and the knee is where SHEDS
   begin, which is the real capacity signal.
3. **Average away the tail.** A cohort experiences p99, not the mean. The mean
   is printed last and only for context.

THE KNEE is the first rung where either the error rate crosses `--max-error-pct`
or p95 crosses `--max-p95-ms`. That rung, minus one, is what this deployment
holds. Everything above it is what it does under stress, which is worth knowing
separately - so the ladder does not stop at the knee unless asked.

SCENARIOS (SNo 152), selected with `--scenario`:

    steady_state_1200  the planned production cohort; the rung that must pass
    cohort_5000        the stretch case; expected to find the knee, not to pass
    replay_20260903    100 concurrent on a 19-question paper - the exact shape
                       that produced 82 failures, kept as a regression

MODES (`--mode`), what a candidate does between questions:

    legacy       per question: `--autosaves-per-question` (k, default 3) posts
                 to /answer with nav="stay", spaced `--autosave-gap-s` (default
                 5s), then one /answer with nav="next". Ends with /submit.
                 This is today's client; the autosave is the most frequent
                 request the runner makes.
    writebehind  per question the answer is HELD LOCALLY, no autosave request.
                 Every `--flush-every-s` (default 60s of think-time, counted
                 from the first unsent answer) ONE /answers/batch carries
                 everything unsent. /answer nav="next" still carries the
                 current answer, exactly as the Flutter client does, and that
                 answer is then no longer unsent; the sitting ends with
                 /answers/batch {submit: true, force: false} instead of
                 /submit.
                 `--nav-without-answer` sends a bare navigation instead, for
                 a future server that accepts one (today's refuses it with 422
                 incomplete_answer).

WHAT EVERY REQUEST CARRIES, as the Flutter client sends it: `session_key` (one
random 32-hex key per simulated candidate) on begin, state, every save and the
submit; and on every saved answer `updated_at` (integer ms from the wall
clock, strictly increasing per candidate; an autosave is a new edit, the nav
carries the latest edit's stamp). The submit (or final batch) goes with
`force: false` and is repeated with `force: true` only on a 409
`incomplete_attempt`, the client's "Submit Anyway"; that 409 is counted as the
sitting's error. State is a POST, so its body can carry the key.

Both modes wait k x gap seconds per question (the candidate's think-time), so a
sitting lasts about questions x k x gap seconds and the modes differ only in
what they send. `--autosaves-per-question 0` removes the think-time and the
autosaves (the harness as it was before these modes).

REQUESTS PER CANDIDATE (the req/c column; Q = questions, k = autosaves per
question; a 503 retry adds one more request each time):

    legacy       1 begin + Q x (k + 1) + 1 state + 1 submit
    writebehind  1 begin + Q + F + 1 state + 1 final batch
                 F = periodic flushes. An answer is unsent only until its own
                 navigation, so F is 0 unless a question's think-time (k x
                 gap) reaches flush-every (then one per question). With
                 `--nav-without-answer` it is about Q x k x gap / flush-every.

ANSWER WRITES PER CANDIDATE (the wr/c column) = accepted autosaves + navs +
batches: Q x (k + 1) for legacy, Q + F + 1 for writebehind. The bat p95 column
is the latency of /answers/batch, the final submit batch included.

The next question comes from `next.question` in the /answer response (the same
envelope begin and state return), so a sitting sends no /state per
question; the one "state" request is the call after the last navigation.

A SITTING THAT STOPS SHORT IS A FAILURE. Its submit normally answers 409
`incomplete_attempt` (counted) before the forced repeat; beyond that the
harness compares the questions the server took (or refused) with the paper's
own size (`question.total`, falling back to `--questions`), and fewer is
counted as an error with code `truncated_sitting`, so a forced submit cannot
turn a short sitting into a pass. It is not a request, so req/c is unaffected.

`--dry-run` prints one candidate's plan (every request, with its think-time
offset, and the totals above) without touching the network or logging in.

USAGE

    # locally, small, to prove the harness itself works
    python3 load/ladder.py --assessment-id 12 --rungs 5,10,20

    # legacy vs write-behind at the same rungs (compare req/c and wr/c)
    python3 load/ladder.py --assessment-id 12 --rungs 20,40 --mode legacy
    python3 load/ladder.py --assessment-id 12 --rungs 20,40 --mode writebehind

    # what one candidate would send, no network
    python3 load/ladder.py --mode writebehind --questions 6 --dry-run

    # the real ladder, against stage
    ETP_BASE_URL=https://assessments.ethara.ai ETP_DB=... \
    python3 load/ladder.py --assessment-id 12 --scenario steady_state_1200

    # count what a run left behind; candidate rows stay for audit, archive
    # them from the back office when done
    python3 load/ladder.py --cleanup

Reads ETP_BASE_URL / ETP_DB / ETP_LOGIN / ETP_PASSWORD / ETP_CANDIDATE_PASSWORD.

RUN IT FROM A MACHINE THAT IS NOT THE SERVER. A client and a server competing
for the same cores measure the contention between them, not the server's
capacity - the numbers come out low and the cause looks like the server.
"""
import argparse
import json
import os
import secrets
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

# Every row this harness creates carries this prefix, which is what makes
# --cleanup exact rather than a guess. Deliberately distinct from e2e_cohort's.
PREFIX = "ZZLOAD"

# Seconds to wait before re-sending a shed answer. The server sends its own
# `Retry-After`; this is the floor used when a sitting retries in-flight.
RETRY_AFTER_HINT = 1.0

CTX = ssl.create_default_context()
_PRINT_LOCK = threading.Lock()

# ── scenarios (SNo 152) ─────────────────────────────────────────────────────
#
# Named rather than passed as numbers so a result can be quoted as "cohort_5000
# found the knee at 750" and mean the same thing to everyone next time.
SCENARIOS = {
    "steady_state_1200": {
        "rungs": [250, 500, 750, 1000, 1200],
        "questions": 20,
        "why": "the planned production cohort; every rung is expected to pass",
    },
    "cohort_5000": {
        "rungs": [250, 500, 750, 1000, 1500, 2500, 5000],
        "questions": 20,
        "why": "the stretch case; this one is meant to FIND the knee",
    },
    "replay_20260903": {
        "rungs": [100],
        "questions": 19,
        "why": "the exact shape of the outage: 100 concurrent, 19 questions",
    },
}


def log(msg):
    with _PRINT_LOCK:
        print(msg, flush=True)


# ── in-flight accounting, which is what makes a green result trustworthy ────

class Flight:
    """Counts requests genuinely outstanding, and the peak reached.

    A rung that asked for 500 workers but never had more than 40 requests in
    flight did not test 500 of anything: the client, the network or the
    ThreadPool was the limit. Without this the harness reports a comfortable
    p95 for a load it never applied, which is the single easiest way for a load
    test to lie.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self.current = 0
        self.peak = 0

    def __enter__(self):
        with self._lock:
            self.current += 1
            self.peak = max(self.peak, self.current)
        return self

    def __exit__(self, *exc):
        with self._lock:
            self.current -= 1
        return False


# ── transport ───────────────────────────────────────────────────────────────

def bearer(login, password):
    """A token for `login`, or None. FORM-ENCODED - a JSON body to this route
    authenticates nobody and returns a 200, which reads as success.

    HONOURS 503 + Retry-After, which it has to now that the server sheds
    properly. Provisioning runs against a box the previous rung may still be
    draining, so a share of these logins are correctly refused as "busy" - and
    a client that treats that as a hard failure silently shrinks the next
    cohort, which the ladder then reports as "provisioned only 47 of 50" and
    stops. That reads as a provisioning bug and is really the shed working.
    """
    body = urllib.parse.urlencode(
        {"login": login, "password": password, "db": DB}).encode()
    for attempt in range(4):
        req = urllib.request.Request(
            BASE + "/api/v1/auth_token", data=body,
            headers={"Content-Type": "application/x-www-form-urlencoded"})
        try:
            with urllib.request.urlopen(req, timeout=60, context=CTX) as r:
                return json.loads(r.read().decode())["data"]["access_token"]
        except urllib.error.HTTPError as exc:
            if exc.code != 503:
                return None
            # The server said how long to wait. Believe it.
            try:
                wait = float(exc.headers.get("Retry-After") or 2)
            except (TypeError, ValueError):
                wait = 2.0
            time.sleep(min(wait, 5) * (attempt + 1))
        except Exception:                                       # noqa: BLE001
            time.sleep(0.5 * (attempt + 1))
    return None


def api(tok, path, payload=None, timeout=120, flight=None, samples=None,
        label=None):
    """One JSON call, timed. Never raises: a caller must not have to tell
    "the request failed" from "the server said no" by catching.

    Returns (envelope, milliseconds, outcome) where outcome is one of
    ok / shed / refused / transport.
    """
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(
        BASE + path, data=data,
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer " + (tok or "")})
    t0 = time.monotonic()
    outcome, env = "ok", {}
    ctx = flight if flight is not None else _NULL_FLIGHT
    try:
        with ctx:
            with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
                env = json.loads(r.read().decode())
        if env.get("ok") is False:
            outcome = "refused"
    except urllib.error.HTTPError as exc:
        # A 503 IS THE SERVER WORKING. `controllers/api/common.py` answers pool
        # exhaustion with 503 + Retry-After rather than a 500, on purpose, so
        # counting it as an error would mark a correctly-degrading deployment
        # broken. It is the capacity signal, not a defect.
        outcome = "shed" if exc.code == 503 else "refused"
        try:
            env = json.loads(exc.read().decode())
        except Exception:                                       # noqa: BLE001
            env = {"ok": False, "error": {"code": "http_%d" % exc.code}}
    except Exception as exc:                                    # noqa: BLE001
        outcome = "transport"
        env = {"ok": False, "error": {"code": type(exc).__name__,
                                      "message": str(exc)[:160]}}
    ms = (time.monotonic() - t0) * 1000.0
    if samples is not None and label:
        samples.append((label, ms, outcome,
                        (env.get("error") or {}).get("code") or ""))
    return env, ms, outcome


class _NullFlight:
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


_NULL_FLIGHT = _NullFlight()


# ── one candidate's sitting: the unit of load ───────────────────────────────

def plan(mode, questions, autosaves, gap, flush_every,
         nav_without_answer=False):
    """The ordered steps of ONE sitting, as data: no network, no clock.

    `sit` executes exactly these steps and `--dry-run` prints them, so the
    printed plan cannot drift from what the harness sends. Time here is the
    candidate's THINK-TIME (the sleeps), not wall-clock: a write-behind flush
    is due once `flush_every` seconds of it have passed since the first unsent
    answer, checked after each think tick.

    Steps: ("begin",) ("sleep", s) ("autosave", q) ("nav", q) ("state",)
           ("flush", (q, ...)) ("final", (q, ...)) ("submit",)
    The tuples name who the plan expects to be sent; `sit` sends whatever it
    actually still holds, which differs only after a failed flush.
    """
    yield ("begin",)
    clock, since, held = 0.0, 0.0, []
    for q in range(questions):
        if mode == "writebehind":
            if not held:
                since = clock
            held.append(q)                     # typed, held locally, unsent
        for _ in range(autosaves):
            if gap:
                yield ("sleep", gap)
                clock += gap
            if mode == "legacy":
                yield ("autosave", q)
            elif held and clock - since >= flush_every:
                yield ("flush", tuple(held))
                held = []
        yield ("nav", q)
        if not nav_without_answer and q in held:   # the answer rode the nav
            held.remove(q)
    yield ("state",)                           # the last nav returns no question
    yield ("submit",) if mode == "legacy" else ("final", tuple(held))


def answer_fields(q):
    """A CORRECT-SHAPED answer to question `q`: `question_id` plus whatever its
    type needs. Not necessarily correct: the write cost is identical either
    way, and grading quality is not what a load test measures.
    """
    fields = {"question_id": q.get("id")}
    picks = []
    for dim in (q.get("dimensions") or []):
        options = dim.get("options") or []
        if options:
            picks.append(options[0]["id"])
    if picks:
        fields["selected_option_ids"] = picks
    # `requires_justification` questions are refused as incomplete without
    # prose, and a refusal is a cheap request - which would flatter the
    # numbers by replacing a real write with an early return.
    if q.get("requires_justification") or not picks:
        fields["justification"] = (
            "Under load-test conditions the candidate records the control "
            "step, verifies the guard is engaged, and signs the check.")
    return fields


def sit(person, questions, flight, samples, opts):
    """Run `plan(...)` for one candidate over real HTTP, as the candidate."""
    tok, root = person["bearer"], "/api/v1/exam/%s/" % person["exam_token"]
    carries = opts.mode == "legacy" or not opts.nav_without_answer
    dirty, fields, seen = {}, {}, set()   # dirty: held locally, not yet sent
    answered, rejected = set(), set()     # the server took / refused the answer
    worst, done, need_state, paper = "ok", False, False, None
    # WHAT THE REAL CLIENT SENDS. One `session_key` per tab on every exam call,
    # and on every saved answer an `updated_at` taken when it was edited:
    # integer ms from the wall clock, strictly increasing for the session (the
    # client's high-water mark). Without them the server's ordering guard and
    # its two stamp columns were never exercised under load.
    session = secrets.token_hex(16)
    stamps, last_ms = {}, 0

    def edited(qid):
        nonlocal last_ms
        last_ms = max(int(time.time() * 1000), last_ms + 1)
        stamps[qid] = last_ms

    def code(env):
        return ((env or {}).get("error") or {}).get("code")

    def call(path, payload, label, retries=0):
        payload = dict(payload or {}, session_key=session)
        env, _ms, out = api(tok, root + path, payload, flight=flight,
                            samples=samples, label=label)
        # A SHED IS NOT A LOST ANSWER, and a harness that treats it as one
        # measures itself. 503 + Retry-After means "not now"; the real client
        # comes back (the debounce re-sends on the next change, and
        # `finishExam` re-sends anything the server never acknowledged). Left
        # un-retried, every shed answer became an unanswered question and then
        # an `incomplete_attempt` at submit - which the ladder reported as a
        # server error rate. On the run of 2026-09-09 that was the ENTIRE error
        # column: 0 five-hundreds, 271 sheds, and a "3.0% error rate" that was
        # this loop giving up. A batch is idempotent, so it is retried too.
        for retry in range(retries):
            if out != "shed":
                break
            time.sleep(RETRY_AFTER_HINT * (retry + 1))
            env, _ms, out = api(tok, root + path, payload, flight=flight,
                                samples=samples, label=label)
        return env, out

    def arrive(state):
        """Take the question in `state` (an envelope: `{outcome, question:
        {...}, ...}`, what begin, state and `/answer`'s `next` all return) as
        the one in hand. False when there is none, or it is one this sitting
        has already seen."""
        nonlocal fields, paper
        q = (state or {}).get("question") or {}
        if not q.get("id") or q["id"] in seen:
            return False
        seen.add(q["id"])
        # How many questions the PAPER has, as the server counts them. This,
        # not `--questions`, is what a finished sitting is measured against.
        if paper is None and isinstance(q.get("total"), int) and q["total"] > 0:
            paper = q["total"]
        fields = answer_fields(q)
        edited(q["id"])
        if opts.mode == "writebehind":
            dirty[q["id"]] = fields
        return True

    def batch(submit, force=False):
        items = [{"question_id": f["question_id"],
                  "selected_option_ids": f.get("selected_option_ids", []),
                  "justification": f.get("justification", ""),
                  "label_answers": {},
                  "updated_at": stamps.get(f["question_id"])}
                 for f in dirty.values()]
        env, out = call("answers/batch",
                        {"answers": items, "submit": submit, "force": force},
                        "batch", retries=3)
        if out == "ok":
            dirty.clear()
            # A rejected item is a write that did not land, and it must show
            # as an error: swallowed, the batch would read as a cheap success
            # and the question would only surface later as an incomplete paper.
            # Recorded as a "reject" sample, which is not a request (see rung).
            for r in (env.get("data") or {}).get("results") or []:
                if r.get("accepted") is False:
                    rejected.add(r.get("question_id"))
                    samples.append(("reject", 0.0, "refused",
                                    str(r.get("reason") or "rejected")[:60]))
                elif r.get("accepted"):
                    answered.add(r.get("question_id"))
        return env, out

    for step in plan(opts.mode, questions, opts.autosaves_per_question,
                     opts.autosave_gap_s, opts.flush_every_s,
                     opts.nav_without_answer):
        kind = step[0]
        if done and kind in ("sleep", "autosave", "nav", "flush"):
            continue
        if kind == "begin":
            env, out = call("begin", {}, "begin")
            if out != "ok":
                return out
            state = env.get("data") or {}
            if not state.get("question"):
                env, _out = call("state", None, "state")
                state = env.get("data") or {}
            done = not arrive(state)
        elif kind == "sleep":
            time.sleep(step[1])
        elif kind == "autosave":
            # An autosave fires because the candidate typed: a new edit.
            edited(fields["question_id"])
            _env, out = call("answer", dict(
                fields, nav="stay", updated_at=stamps[fields["question_id"]]),
                "autosave", retries=3)
            if out != "ok":
                worst, done = out, True
        elif kind == "nav":
            # The answer rides the navigation, as the Flutter client does.
            # `--nav-without-answer` sends a bare one, which today's server
            # refuses (422 incomplete_answer).
            payload = (dict(fields, nav="next",
                            updated_at=stamps[fields["question_id"]])
                       if carries else
                       {"question_id": fields["question_id"], "nav": "next"})
            env, out = call("answer", payload, "answer", retries=3)
            if out != "ok":
                worst, done = out, True
                continue
            if carries:
                dirty.pop(fields["question_id"], None)
                answered.add(fields["question_id"])
            # THE ANSWER RESPONSE CARRIES `next`, AND `next` IS AN ENVELOPE.
            # `next` is the same `{outcome, assessment, ..., question: {id,
            # ...}}` that begin and state return (`_question_payload`), so the
            # question id sits at `next["question"]["id"]`, never at
            # `next["id"]`. Reading `question` off the answer response itself
            # found nothing after the first answer, and every candidate
            # answered exactly ONE question and then failed `submit` with
            # `incomplete_attempt`: a 33% error rate and a knee at 5
            # concurrent. It was measuring the harness.
            #
            # Reading `next["id"]` is the same mistake one level down: it is
            # always empty, so the loop either ends after question 1 or (the
            # old fallback) asks GET /state after EVERY answer. And a
            # write-behind sitting that ends after question 1 still ends with
            # `/answers/batch {submit, force}`, which hands in a one-question
            # paper and reports a clean pass. The end of `sit` therefore checks
            # the answers against the paper's own size.
            #
            # Kept as a comment rather than deleted because both failures
            # looked exactly like a capacity finding or, worse, a green rung.
            nxt = (env.get("data") or {}).get("next")
            if isinstance(nxt, dict) and nxt.get("question"):
                done = not arrive(nxt)
            elif isinstance(nxt, dict):
                # A shape this harness does not know: ask the server where
                # the candidate is, as a reloading runner would.
                env, out = call("state", None, "state")
                if out != "ok":
                    worst = out
                done = not arrive(env.get("data") or {})
            else:
                # `next: null` is the end of the paper (the response carries
                # the `review` instead) or a closed attempt; either way there
                # is no further question to go to.
                done, need_state = True, True
        elif kind == "flush":
            if dirty:
                batch(False)
        elif kind == "state":
            if need_state:
                call("state", None, "state")
        else:                                  # "final" or "submit"
            # ASKED FIRST, FORCED ONLY WHEN TOLD. The client submits with
            # `force: false`; only a 409 `incomplete_attempt` puts "Submit
            # Anyway" in front of the candidate, which re-sends `force: true`.
            # That 409 is the sitting's error (a paper handed in short), as
            # legacy's `/submit` always reported it.
            if kind == "final":
                env, out = batch(True)
                if code(env) == "incomplete_attempt":
                    worst = out
                    env, out = batch(True, force=True)
            else:
                env, out = call("submit", {"force": False}, "submit")
                if code(env) == "incomplete_attempt":
                    worst = out
                    env, out = call("submit", {"force": True}, "submit")
            if out != "ok" and worst == "ok":
                worst = out
    # A SITTING THAT STOPPED SHORT IS A FAILURE, WHATEVER THE LAST CALL SAID.
    # Both modes now submit with `force: false` first, so a short paper
    # normally shows as its 409 `incomplete_attempt` (and `worst` is set
    # there). This check stays for what that cannot see: an answer the server
    # never took although the submit passed (a final batch that re-sent it
    # was refused per item, or the paper is expired and settles anyway), which
    # would otherwise read as a clean, cheap pass. The yardstick is the paper's own size
    # as the server reported it (`question.total`), not `--questions`; the
    # server did or refused every answer in `answered | rejected`, and a
    # refusal already has its own error sample, so only the rest is new.
    # Skipped when the sitting already failed on a request: that has a code.
    # A SHED IS NOT SUCH A FAILURE (it is the server working, and has no code),
    # so a sitting whose navigation shed on every retry is still checked.
    missing = (paper or questions) - len(answered | rejected)
    if worst in ("ok", "shed") and missing > 0:
        samples.append(("truncated", 0.0, "refused", "truncated_sitting"))
        worst = "truncated_sitting"
    return worst


def dry_run(opts, questions):
    """Print one candidate's plan and its totals. No network, no login."""
    carries = opts.mode == "legacy" or not opts.nav_without_answer
    log("DRY RUN, no network: one candidate, mode=%s, %d questions, %d think "
        "ticks per question of %gs%s"
        % (opts.mode, questions, opts.autosaves_per_question,
           opts.autosave_gap_s,
           "" if opts.mode == "legacy" else
           ", flush every %gs%s" % (opts.flush_every_s,
                                    "" if carries else ", bare nav")))
    log("paths are relative to /api/v1/exam/<token>/; EVERY request carries "
        "session_key (one 32-hex key per candidate); every saved answer "
        "carries updated_at (integer ms, strictly increasing per candidate, "
        "from the wall clock)\n")
    clock, counts = 0.0, Counter()
    for step in plan(opts.mode, questions, opts.autosaves_per_question,
                     opts.autosave_gap_s, opts.flush_every_s,
                     opts.nav_without_answer):
        kind = step[0]
        if kind == "sleep":
            clock += step[1]
            continue
        counts[kind] += 1
        if kind == "begin":
            what = "POST begin          {session_key}"
        elif kind == "autosave":
            what = ("POST answer         nav=stay  q%d  {answer, updated_at "
                    "(new edit), session_key}" % (step[1] + 1))
        elif kind == "nav":
            what = "POST answer         nav=next  q%d  {%s, session_key}" % (
                step[1] + 1, "answer, updated_at" if carries
                else "no answer")
        elif kind == "state":
            what = ("POST state          {session_key}  (the last nav returns "
                    "the review)")
        elif kind == "submit":
            what = ("POST submit         {force: false, session_key}  (again "
                    "with force: true only on 409 incomplete_attempt)")
        else:
            what = ("POST answers/batch  %s  {answers[updated_at], submit: %s, "
                    "force: false, session_key}%s" % (
                        ",".join("q%d" % (q + 1) for q in step[1]) or "(none)",
                        "true" if kind == "final" else "false",
                        "  (again with force: true only on 409 "
                        "incomplete_attempt)" if kind == "final" else ""))
        log("t+%5.0fs  %s" % (clock, what))
    batches = counts["flush"] + counts["final"]
    writes = counts["autosave"] + counts["nav"] + batches
    log("\nthink time per candidate     : %.0fs" % clock)
    log("requests per candidate      : %d  (%s)" % (
        sum(counts.values()),
        ", ".join("%s %d" % (k, n) for k, n in counts.items())))
    log("answer writes per candidate : %d  (autosave %d + nav %d + batch %d)"
        % (writes, counts["autosave"], counts["nav"], batches))


# ── provisioning ────────────────────────────────────────────────────────────

def provision(admin, assessment_id, count):
    """Create `count` candidates on `assessment_id`, launch, and return them
    with a bearer and an exam token each.

    Chunked, because an assign payload of 5,000 candidates is itself a request
    big enough to fail for reasons that have nothing to do with capacity - and
    a provisioning failure that looks like a load failure wastes a whole run.
    """
    run = "%x" % (int(time.time()) & 0xFFFFFF)
    people = [{"name": "%s %s-%05d" % (PREFIX, run, i),
               "email": "%s.%s.%05d@example.com" % (PREFIX.lower(), run, i)}
              for i in range(count)]

    log("  provisioning %d candidates (run %s)" % (count, run))
    for i in range(0, len(people), 200):
        chunk = people[i:i + 200]
        env, _ms, out = api(admin, "/api/v1/assessments/%s/assign"
                            % assessment_id, {"candidates": chunk}, timeout=600)
        if out != "ok":
            log("  FATAL assign chunk %d: %s" % (i // 200, json.dumps(env)[:200]))
            return []

    # ASSIGN ALREADY LAUNCHES. Measured, not assumed: the assign response
    # carries `launched_attempts` and moves the assessment to `in_progress`, so
    # the explicit launch below is a no-op on the happy path and is REFUSED
    # with `launch_blocked` ("only a draft assessment can be launched") - which
    # is the route being correct, not a provisioning failure. Treating that
    # refusal as fatal is what made the first run of this harness report zero
    # candidates against a database that had provisioned all of them.
    env, _ms, out = api(admin, "/api/v1/assessments/%s/launch" % assessment_id,
                        {"confirm": True}, timeout=900)
    if out != "ok":
        code = (env.get("error") or {}).get("code") or ""
        state = ((env.get("data") or {}).get("assessment") or {}).get("state")
        if code != "launch_blocked":
            log("  FATAL launch: %s" % json.dumps(env)[:240])
            return []
        log("  launch declined (%s) - assign had already launched it%s"
            % (code, "" if not state else "; state=%s" % state))

    # PAGED UNTIL THIS RUN'S COHORT IS ACCOUNTED FOR, not one big page.
    #
    # The list paginates (default 40) and orders by `create_date desc`. A single
    # large page looked sufficient - the newest rows come first, and this run
    # just created them - but a rung provisions its whole cohort inside the same
    # SECOND, so `create_date` ties and the order within that second is not
    # stable. A few of the candidates just created sort behind older rows and
    # fall off the page. That is why the ladder kept reporting "provisioned only
    # 47 of 50" against a database that had all 50, and stopping - which reads
    # as a provisioning failure and is really a paging assumption.
    #
    # The assessment carries 557 candidates by now; asking for `count * 2` was
    # never going to cover it.
    wanted = {p["email"] for p in people}
    rows = {}
    offset, page = 0, 200
    while offset < 20000:
        env, _ms, _out = api(
            admin, "/api/v1/assessments/%s/candidates" % assessment_id,
            {"limit": page, "offset": offset}, timeout=900)
        batch = env.get("data") or []
        if not batch:
            break
        for r in batch:
            # THE EMAIL IS NESTED under `candidate`, not a top-level column. A
            # flat `r.get("email")` returns None for every row, which silently
            # keys the whole map on "" and hydrates nobody.
            cand = r.get("candidate") or {}
            email = cand.get("email") if isinstance(cand, dict) else None
            if email and email in wanted:
                rows[str(email)] = r
        if len(rows) >= len(wanted) or len(batch) < page:
            break
        offset += page

    # The exam token is a bearer credential and the LIST deliberately withholds
    # it; a manager reads it from the attempt detail, so this does too.
    def hydrate(p):
        row = rows.get(p["email"])
        if not row:
            return None
        # The exam token is a bearer credential, so the LIST withholds it by
        # design and only the attempt detail carries it.
        exam = row.get("access_token")
        if not exam:
            d, _ms, _o = api(admin, "/api/v1/attempts/%s" % row.get("id"), None)
            exam = (d.get("data") or {}).get("access_token")
        # RETRIED, because provisioning happens against a server that may
        # already be saturated by the previous rung's tail. A single failed
        # login silently shrank the cohort - the ladder then reported
        # "provisioned only 51 of 60" and stopped, which reads as a
        # provisioning bug and is really the pool being briefly full.
        # `bearer` now backs off on a 503 of its own, so one call is enough.
        tok = bearer(p["email"], CAND_PASSWORD)
        if not (exam and tok):
            return None
        return {"email": p["email"], "exam_token": exam, "bearer": tok}

    # HYDRATION IS ITSELF LOAD, and that is why it needs a second pass.
    #
    # Each candidate costs a login plus an attempt read, and doing 32 of those
    # at once against a box still draining the previous rung means a couple get
    # shed or time out. At 50 candidates that reliably left 47-49 ready, and the
    # ladder then refused the rung as short - reported as a provisioning bug and
    # really the server correctly pushing back. Verified at small scale: 12 of
    # 12 hydrate cleanly when nothing else is in flight.
    #
    # So: a wide first pass for speed, then the stragglers retried NARROWLY.
    # The rung still has to fill exactly - a rung that quietly ran at 49 when it
    # said 50 is the kind of number nobody can use later.
    def gather(subset, workers):
        got = []
        with ThreadPoolExecutor(max_workers=workers) as pool:
            for fut in as_completed([pool.submit(hydrate, p) for p in subset]):
                row = fut.result()
                if row:
                    got.append(row)
        return got

    ready = gather(people, 16)
    for attempt in range(3):
        if len(ready) >= count:
            break
        have = {r["email"] for r in ready}
        missing = [p for p in people if p["email"] not in have]
        log("  retrying %d candidate(s) that did not come up" % len(missing))
        time.sleep(1.5 * (attempt + 1))
        ready.extend(gather(missing, 4))
    log("  %d of %d candidates are ready to sit" % (len(ready), count))
    return ready


# ── the ladder ──────────────────────────────────────────────────────────────

def pct(sorted_ms, q):
    if not sorted_ms:
        return 0.0
    return sorted_ms[min(len(sorted_ms) - 1, int(len(sorted_ms) * q))]


def rung(people, width, questions, opts):
    """One rung. Returns a dict of what it measured."""
    flight, sitters, samples = Flight(), Flight(), []
    cohort = people[:width]
    started = time.monotonic()
    outcomes = Counter()

    def sitting(p):
        with sitters:               # counts candidates mid-sitting, see below
            return sit(p, questions, flight, samples, opts)

    with ThreadPoolExecutor(max_workers=width) as pool:
        futures = [pool.submit(sitting, p) for p in cohort]
        for fut in as_completed(futures):
            try:
                outcomes[fut.result()] += 1
            except Exception as exc:                            # noqa: BLE001
                outcomes["transport"] += 1
                samples.append(("sit", 0.0, "transport", type(exc).__name__))
    wall = time.monotonic() - started

    def took(label):
        return sorted(ms for lbl, ms, out, _c in samples
                      if lbl == label and out == "ok")

    # `answers` and p50/p95/p99 stay what they always were: the nav="next"
    # /answer calls. Autosaves and batches have their own latencies below.
    answers, autosaves, batches = took("answer"), took("autosave"), took("batch")
    # A "reject" sample is a batch item the server refused and a "truncated"
    # one is a sitting that stopped short (see `sit`): neither is a request, so
    # they count towards errors but not towards the request total.
    total = sum(1 for lbl, _m, _o, _c in samples
                if lbl not in ("reject", "truncated"))
    wrote = sum(1 for lbl, _m, out, _c in samples
                if out == "ok" and lbl in ("autosave", "answer", "batch"))
    sheds = sum(1 for _l, _m, out, _c in samples if out == "shed")
    bad = sum(1 for _l, _m, out, _c in samples
              if out in ("refused", "transport"))
    codes = Counter(c for _l, _m, out, c in samples
                    if out in ("refused", "transport") and c)
    # PACED SITTINGS ARE MOSTLY THINKING. With autosaves 5s apart, 1200
    # candidates keep only ~50 requests in flight at once, which the in-flight
    # test below would call "client starved" - a false UNACHIEVED. For a paced
    # rung the honest question is whether all the candidates really overlapped,
    # so it counts candidates mid-sitting instead.
    paced = opts.autosave_gap_s > 0 and opts.autosaves_per_question > 0
    reached = sitters.peak if paced else flight.peak
    n = len(cohort) or 1
    return {
        "width": width,
        "mode": opts.mode,
        "sat": len(cohort),
        "requests": total,
        "answers": len(answers),
        "wall": wall,
        "rps": total / wall if wall else 0.0,
        "p50": pct(answers, 0.50), "p95": pct(answers, 0.95),
        "p99": pct(answers, 0.99),
        "mean": statistics.fmean(answers) if answers else 0.0,
        "req_pc": total / n, "wr_pc": wrote / n,
        "bat_p95": pct(batches, 0.95),
        # The knee gate covers every write class, not just nav: in legacy mode
        # the autosave is most of the load and in write-behind the batch is the
        # heaviest request, so a green verdict must not ignore either.
        "gate_p95": max(pct(answers, 0.95), pct(autosaves, 0.95),
                        pct(batches, 0.95)),
        "gate_series": max((("answer", pct(answers, 0.95)),
                            ("autosave", pct(autosaves, 0.95)),
                            ("batch", pct(batches, 0.95))),
                           key=lambda s: s[1])[0],
        "sheds": sheds, "bad": bad,
        "err_pct": 100.0 * bad / total if total else 0.0,
        "peak_flight": flight.peak,
        "reached": reached,
        "unit": "sittings" if paced else "in flight",
        "achieved": reached >= max(2, int(width * 0.5)),
        "codes": codes,
        "outcomes": outcomes,
    }


def unfinished(r):
    """Sittings that ended on anything but ok or a shed (a shed is the server working)."""
    return sum(n for k, n in r["outcomes"].items() if k not in ("ok", "shed"))


def report(rows, max_err, max_p95):
    log("\n%-7s %-12s %-7s %-8s %8s %8s %8s %7s %7s %8s %7s %7s %8s  %s"
        % ("RUNG", "mode", "inflt", "answers", "p50", "p95", "p99", "shed",
           "err%", "req/s", "req/c", "wr/c", "bat p95", "VERDICT"))
    log("-" * 130)
    knee = None
    for r in rows:
        if not r["achieved"]:
            verdict = ("UNACHIEVED (client only reached %d %s)"
                       % (r["reached"], r["unit"]))
        elif r["err_pct"] > max_err:
            verdict = "FAIL errors > %.1f%%" % max_err
        elif 100.0 * unfinished(r) / max(1, sum(r["outcomes"].values())) > max_err:
            # Per SITTING, not per request: 4 of 40 candidates refused at
            # begin is 0.3% of requests but 10% of the cohort never sat.
            verdict = ("FAIL %d of %d sittings unfinished"
                       % (unfinished(r), sum(r["outcomes"].values())))
        elif r["gate_p95"] > max_p95:
            verdict = ("FAIL p95 > %dms (%s %.0f)"
                       % (max_p95, r["gate_series"], r["gate_p95"]))
        elif r["sheds"]:
            verdict = "HOLDS, shedding"
        else:
            verdict = "HOLDS"
        if knee is None and r["achieved"] and verdict.startswith("FAIL"):
            knee = r["width"]
        log("%-7d %-12s %-7d %-8d %8.0f %8.0f %8.0f %7d %7.1f %8.1f %7.1f "
            "%7.1f %8.0f  %s"
            % (r["width"], r["mode"], r["peak_flight"], r["answers"],
               r["p50"], r["p95"], r["p99"], r["sheds"], r["err_pct"],
               r["rps"], r["req_pc"], r["wr_pc"], r["bat_p95"], verdict))
        for code, n in r["codes"].most_common(4):
            log("        %-28s x%d" % (code, n))
    log("\nreq/c = requests per candidate; wr/c = answer writes per candidate "
        "(accepted autosaves + navs + batches); bat p95 = /answers/batch "
        "latency, the final submit batch included (0 = none sent). The knee "
        "p95 covers answer (the p95 column), autosave and batch, and a FAIL "
        "p95 verdict names the series that crossed and its value.")

    achieved = [r for r in rows if r["achieved"]]
    if not achieved:
        log("\nNO RUNG APPLIED ITS INTENDED LOAD. The client, not the server, "
            "was the limit - run this from a bigger box, or from several. "
            "Nothing here says anything about the server's capacity.")
        return 2
    if knee is None:
        log("\nNo knee inside this ladder: the highest rung that genuinely "
            "applied its load was %d and it held. The ceiling is above the "
            "range tested." % achieved[-1]["width"])
        return 0
    held = [r["width"] for r in achieved if r["width"] < knee]
    log("\nKNEE AT %d concurrent. This deployment holds %s."
        % (knee, ("up to %d" % held[-1]) if held else "nothing in this ladder"))
    log("A rung marked 'HOLDS, shedding' is NOT a failure: 503 + Retry-After "
        "is the designed response to pool exhaustion. It is the early warning "
        "that the next rung is the knee.")
    return 1


def cleanup(admin):
    log("Cleanup, prefix %s" % PREFIX)
    env, _ms, _o = api(admin, "/api/v1/assessments", {"limit": 400})
    n = 0
    for row in (env.get("data") or []):
        if str(row.get("name", "")).startswith(PREFIX):
            n += 1
    log("  %d assessments carry the prefix; candidate rows are left in place "
        "so a finished run stays auditable. Archive them from the back office "
        "when you are done reading the numbers." % n)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--assessment-id", type=int,
                    help="an existing, launchable assessment to sit")
    ap.add_argument("--scenario", choices=sorted(SCENARIOS),
                    help="a named gating scenario (SNo 152)")
    ap.add_argument("--rungs", help="explicit ladder, e.g. 5,10,20")
    ap.add_argument("--questions", type=int, default=20)
    ap.add_argument("--max-error-pct", type=float, default=1.0)
    ap.add_argument("--max-p95-ms", type=int, default=3000)
    ap.add_argument("--cleanup", action="store_true")
    ap.add_argument("--mode", choices=("legacy", "writebehind"),
                    default="legacy",
                    help="legacy: k autosaves (/answer nav=stay) then nav=next "
                         "per question, /submit at the end. writebehind: "
                         "answers held locally, one /answers/batch every "
                         "--flush-every-s, nav=next only navigates, final "
                         "/answers/batch {submit, force} (default: legacy)")
    ap.add_argument("--autosaves-per-question", type=int, default=3,
                    help="k: think ticks per question, each an autosave in "
                         "legacy mode (default 3; 0 = no think-time, no "
                         "autosaves)")
    ap.add_argument("--autosave-gap-s", type=float, default=5.0,
                    help="seconds of think-time per tick, both modes "
                         "(default 5)")
    ap.add_argument("--flush-every-s", type=float, default=60.0,
                    help="writebehind: think-seconds after the first unsent "
                         "answer before a batch is sent (default 60)")
    ap.add_argument("--nav-without-answer", action="store_true",
                    help="writebehind: send nav=next with NO answer in the "
                         "body, for a future server that accepts a bodyless "
                         "navigation (today's refuses it with 422 "
                         "incomplete_answer). Default: the answer rides the "
                         "nav, as the Flutter client does")
    ap.add_argument("--dry-run", action="store_true",
                    help="print one candidate's request plan and the "
                         "requests-per-candidate totals, then exit; no "
                         "network, no login")
    args = ap.parse_args()
    if min(args.autosaves_per_question, args.autosave_gap_s,
           args.flush_every_s) < 0:
        ap.error("--autosaves-per-question, --autosave-gap-s and "
                 "--flush-every-s cannot be negative")

    if args.dry_run:
        dry_run(args, SCENARIOS[args.scenario]["questions"]
                if args.scenario else args.questions)
        return 0

    log("target %s (db=%s) as %s" % (BASE, DB, LOGIN))
    admin = bearer(LOGIN, PASSWORD)
    if not admin:
        log("FATAL: could not authenticate %s" % LOGIN)
        return 2

    if args.cleanup:
        cleanup(admin)
        return 0

    if args.scenario:
        spec = SCENARIOS[args.scenario]
        rungs, questions = spec["rungs"], spec["questions"]
        log("scenario %s - %s" % (args.scenario, spec["why"]))
    elif args.rungs:
        rungs = [int(x) for x in args.rungs.split(",") if x.strip()]
        questions = args.questions
    else:
        log("give --scenario or --rungs (or --cleanup)")
        return 2

    if not args.assessment_id:
        log("give --assessment-id: the harness sits an EXISTING assessment "
            "rather than authoring one, so the paper under load is the paper "
            "you actually ship")
        return 2

    # EVERY RUNG GETS ITS OWN COHORT. An attempt can be sat exactly once - the
    # server locks it on submit, which is correct - so reusing candidates across
    # rungs returns `attempt_locked` for everyone who sat a lower rung. The
    # first version of this harness did that and reported a rising error rate
    # and a knee at 10, which read exactly like a capacity limit and was
    # entirely the harness re-sitting finished candidates.
    #
    # Provisioned per rung rather than all upfront so a ladder that stops early
    # has not already created candidates for rungs it never runs (cohort_5000
    # would otherwise provision 10,750 before the first request).
    rows = []
    for width in rungs:
        log("\nrung %d ..." % width)
        t0 = time.monotonic()
        people = provision(admin, args.assessment_id, width)
        setup = time.monotonic() - t0
        if len(people) < width:
            log("  provisioned only %d of %d - a short rung measures the wrong "
                "width, so the ladder stops here" % (len(people), width))
            break
        log("  cohort ready in %.1fs; sitting ..." % setup)
        r = rung(people, width, questions, args)
        rows.append(r)
        log("  %s: %d requests (%.1f per candidate, %.1f answer writes), %d "
            "answers, peak in flight %d, %.1f%% errors, %d shed"
            % (r["mode"], r["requests"], r["req_pc"], r["wr_pc"], r["answers"],
               r["peak_flight"], r["err_pct"], r["sheds"]))
    if not rows:
        log("no rung ran")
        return 2

    return report(rows, args.max_error_pct, args.max_p95_ms)


if __name__ == "__main__":
    sys.exit(main())
