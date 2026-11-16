# Capacity harness (SNo 151-153)

`ladder.py` sits real candidates through the real HTTP API at increasing
concurrency and reports the rung at which this deployment stops holding.

## Why this replaced the old load test

`tools/e2e_cohort.py --load-test` says it in its own docstring: **"READS ONLY,
on purpose."** That makes it safe against a shared database and unable to answer
the only question that matters. The 2026-09-03 failure was on the **write** path
— `/answer` was 86.6% of all database traffic (12.4M of 14.3M queries in three
hours) and 82 of 100 concurrent candidates failed. A read-only harness cannot see
that, cannot exercise the 503 shed, and cannot measure any write reduction.

`tools/e2e_cohort.py` also has a second problem worth knowing: its `sit_one`,
`assign_personas` and `ensure_cohort_users` are **defined but never called** —
`main()` parses `--form-id/--count/--workers` and then prints a message and
returns. Only `--load-test` and `--cleanup` do anything.

## Running it

```bash
# locally, small, to prove the harness works
python3 load/ladder.py --assessment-id <id> --rungs 5,10,20

# the real ladder, against stage
ETP_BASE_URL=https://assessments.ethara.ai ETP_DB=<db> \
ETP_LOGIN=<admin> ETP_PASSWORD=<pw> \
python3 load/ladder.py --assessment-id <id> --scenario steady_state_1200
```

**Run it from a machine that is not the server.** A client and server competing
for the same cores measure the contention between them, and the cause looks like
the server.

Scenarios (SNo 152): `steady_state_1200` (must pass), `cohort_5000` (expected to
find the knee), `replay_20260903` (100 concurrent × 19 questions — the outage
shape, kept as a regression).

## What it refuses to do quietly

1. **Report green on a load that never happened.** Each rung records peak
   requests genuinely in flight; a rung that asked for 500 and only reached 40 is
   marked `UNACHIEVED` and excluded from the knee.
2. **Count a shed as a failure.** 503 + `Retry-After` is the designed response to
   pool exhaustion; it is reported in its own column.
3. **Average away the tail.** p50/p95/p99 are reported; the mean is context only.

## Comparing legacy vs write-behind

`--mode` decides what a candidate sends while answering. Both modes think for
the same time per question (`--autosaves-per-question` ticks of
`--autosave-gap-s` seconds, default 3 x 5 s), so only the requests differ.

- `legacy`: per question, k autosaves (`/answer`, `nav="stay"`), then
  `/answer` with `nav="next"`; `/submit` at the end. Today's client.
- `writebehind`: no autosave requests; the answer is held locally and one
  `/answers/batch` goes out every `--flush-every-s` (default 60 s of
  think-time) with everything still unsent. `/answer` with `nav="next"` still
  carries the current answer, as the Flutter client does, so an answer is
  unsent only until its own navigation. The sitting ends with
  `/answers/batch {submit: true, force: false}` instead of `/submit`.

Both modes send what the Flutter client sends:

- `session_key` (one random 32-hex key per simulated candidate) on `begin`,
  `state` (a POST, so it has a body), every save and the submit;
- on every saved answer `updated_at`: integer ms from the wall clock, strictly
  increasing per candidate. An autosave is a new edit with a new stamp, the
  nav carries the latest edit's stamp, and each batch item carries its own;
- the submit (legacy `/submit`, writebehind's final batch) with
  `force: false`, repeated with `force: true` only on a 409
  `incomplete_attempt` (the client's "Submit Anyway"). That 409 is counted as
  the sitting's error.

```bash
# same assessment, same rungs, same machine, back to back
python3 load/ladder.py --assessment-id <id> --rungs 20,40,60 --mode legacy
python3 load/ladder.py --assessment-id <id> --rungs 20,40,60 --mode writebehind

# what one candidate sends, no network and no login
python3 load/ladder.py --mode writebehind --questions 6 --dry-run
```

`--nav-without-answer` sends a bodyless `nav="next"` instead, for a future
server that accepts one. Today's refuses it (HTTP 422 `incomplete_answer`), so
that run fails on the first question and lists the code under the rung.

Four extra columns per rung: `mode`, `req/c` (requests per candidate, every
retry counted), `wr/c` (answer writes per candidate: accepted autosaves + navs +
batches) and `bat p95` (latency of `/answers/batch`, the final submit batch
included). `--help` gives the formulas. A batch item the server refuses shows
as an error, so a write-behind run cannot look cheap by dropping answers. A
`FAIL p95` verdict names the series that crossed (`answer`, `autosave` or
`batch`) and its value; the `p95` column is the `answer` series only.

What a good result looks like, for 20 questions at the defaults:

| mode | req/c | wr/c |
|------|------:|-----:|
| legacy | 83 | 80 |
| writebehind | 23 | 21 |

Navigation writes still count as answer writes; the saving is the 60 autosaves
turning into at most a handful of batches (here only the final one).

- **wr/c falls by roughly the autosave share.** Autosaves are k of every k + 1
  answer writes (75% at k = 3); the final batch adds one back, so expect about
  74% off (21 vs 80).
- **The periodic batch needs a slow candidate.** An answer is unsent only until
  its own navigation, so a flush fires only when a question's think-time
  (k x gap, 15 s here) reaches `--flush-every-s`. To exercise it, raise the
  gap: `--autosave-gap-s 25` (75 s per question) gives one flush per question,
  43 req/c and 41 wr/c, a rung of 1500 s of think-time per candidate.
- **err% does not rise** and no `incomplete_attempt`, `incomplete_answer` or
  `truncated_sitting` appears under a rung (see the next section).
- **bat p95 stays under `--max-p95-ms`** and the same order as the `/answer`
  p95. The final batch also settles the attempt, so somewhat higher is normal;
  several times higher means the batch route is the new bottleneck.
- **The knee moves up, or holds with lower p95 and fewer sheds.** If wr/c fell
  and the knee did not move, the autosave was not what limited this deployment.

A sitting now lasts about questions x k x gap seconds (300 s at the defaults),
and a paced rung is judged achieved by the number of candidates sitting at
once, not by requests in flight, which think-time keeps low by design. The
baseline table below was taken with the old back-to-back flow, which is
`--autosaves-per-question 0` (but see the request count below).

### A sitting that stops short fails

The submit goes with `force: false` first, so a short paper normally shows as
its 409 `incomplete_attempt`, counted before the forced repeat (which answers
200). A candidate that quit after question 1 must never look like a clean,
cheap pass, so in addition every
sitting is checked against the paper's own size (`question.total` from the
server, falling back to `--questions`): fewer questions taken or refused than
that is counted as an error with code `truncated_sitting`, in both modes. It
shows under the rung and in err%, but is not a request, so req/c is unchanged.
`--questions` smaller than the paper fails every candidate this way, on purpose.
A sitting whose navigation was shed on every retry is checked the same way: a
shed is not an error, but the candidate that gave up after it did not finish.

### Request count and the 2026-09-09 baseline

The next question is read from `next.question` in the `/answer` response, which
is the same envelope begin and state return. The previous version looked for
`next.id`, never found it, and sent one `GET /state` after every answer: 42
requests per candidate on a 20-question paper (1 begin + 20 answers + 20 state +
1 submit), checked by running that version against a stub shaped like the real
routes. Now there is one `/state` (a POST carrying `session_key`), after the
last navigation, so legacy at
`--autosaves-per-question 0` sends Q + 3 (23 for 20 questions).

So a new legacy run no longer matches the baseline below request for request:
subtract Q - 1 requests per candidate (19 at Q = 20) from the old figure, and
do not compare the old `req/s` with a new run's. The
`answers` column and the latency columns are the same series as before, but the
server now does less read work at each rung, so a re-run may show somewhat lower
latency. For a like-for-like comparison, re-run the baseline rungs with
`--mode legacy --autosaves-per-question 0` rather than reusing the table.

## Local baseline, 2026-09-09

`etp_fix0909`, threaded (`workers=0`), `db_maxconn=32`, 20-question paper,
client and server on the same laptop. **These are not stage numbers** — they
bound the harness, not the product.

| rung | answers | p50 | p95 | p99 | err% | req/s | verdict |
|-----:|--------:|----:|----:|----:|-----:|------:|---------|
| 20 | 400 | 217 | 271 | 292 | 0.0 | 115 | HOLDS |
| 40 | 640 | 324 | 387 | 428 | 0.6 | 116 | HOLDS |
| 60 | 504 | 273 | 362 | 557 | 5.5 | 116 | **FAIL** |

Knee at 60; holds to 40. Throughput is **flat at ~116 req/s** across every rung
while latency grows linearly with width — the signature of a serialised server,
which is exactly what `workers = 0` is. `odoo.conf` in this repo sets no
`workers` value at all, so that is the default a fresh rig gets.

## The finding that matters most

Every error at every rung was `psycopg2.pool.PoolError: The Connection Pool Is
Full`, returned as **HTTP 500 — not the 503 shed**. The shed in
`controllers/api/common.py` catches `PoolError` raised *inside* an endpoint. The
common case is exhaustion while acquiring the request's own cursor, in
`http.py:2230` `_serve_db()`, **before any route is dispatched** — so the
decorator never runs.

Consequences:

- **`/assessments_be/health` returned 500 under load.** Every Odoo route on a
  database request takes a cursor regardless of whether its handler uses one, so
  a liveness probe fails exactly when it must stay green. Do **not** wire
  container liveness to it — use a TCP check or terminate liveness at the proxy.
  `controllers/health.py` now says so; its previous docstring claimed the
  opposite and was wrong.
- **The real fix is capacity, not a cleverer probe.** Size `db_maxconn` to the
  worker count and keep Postgres `max_connections` above
  `workers × db_maxconn`. An app-level shed cannot cover a connection that was
  never acquired.

Prefork (`--workers=N`) **crashes silently on macOS** — workers bind the port,
die per request with no traceback, and respawn. Linux/Docker is unaffected; it
is why the local baseline above is threaded.
