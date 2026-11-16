# Launch readiness

## Stage 1 gates

The plan's Stage 1 gates as checks anyone can rerun on the rig: `uv run yantra gate <name>` (or `all`), each
printing PASS or FAIL with the figures that decided it; `--json` for machine output. How to run them is in
[USING.md](USING.md) §2. The load gates (claim-storm, money-parity, delivery-gate) talk to the work and money services
directly with synthetic workers, so the rig must run with `deployment/local/compose.dev.yaml`.

### Baseline, before review fixes (5 Nov 2026)

Run on the local rig after the M4 rebuild, before the review fixes landed. The restore drill was not run (backup and
restore are being extended to MinIO and the Odoo filestore first).

| Gate | Command | Result | Figures |
|---|---|---|---|
| ui | `yantra gate ui` | PASS | 200; nosniff, frame DENY, referrer policy and CSP present; scripts `'self'` + `'wasm-unsafe-eval'` only; `config.json` names the gateway; 81 screenshots of the browser walks (m1 6, m2 1, m3 70, m4 4) |
| delivery-gate | `yantra gate delivery-gate` | PASS | manifest refused 409 `batch_held` while a unit was out; the unit went back to its author; after the redo 3 accepted units, the JSONL from MinIO has 3 lines, its sha256 equals the recorded one, manifest digests agree |
| security | `yantra gate security` | PASS | 17 checks, 0 failed: cross-worker unit and media link 404; presigned link works (200) and a tampered one is refused (403); a released claim's link 404; client token on a worker route 403, on another organisation's project 404, claiming a review 403; admin approving a window 403; no, garbage and forged tokens 401; idempotent replay returns the same ticket; the same key with another body 422 `idempotency_mismatch`; unsigned webhook 404 (no webhook secret on the rig, so the path does not exist); 30 of 630 burst calls answered 429 with Retry-After |
| claim-storm | `yantra gate claim-storm` (500 workers, 2,000 units, 64 in flight) | **FAIL** | 2,000 units claimed once, 0 double claims; p50 337 ms, p95 30,213 ms, p99 30,314 ms; 137 claim and 80 submit 500s (`QueuePool limit of size 5 overflow 5 reached, connection timed out, timeout 30.00`), 58 409 `one_live_claim` after a failed submit; 80 claims left live |
| claim-storm | `yantra gate claim-storm --concurrency 32` | PASS | 2,000 claimed once, 0 double claims, p50 171, p95 280, p99 360 ms, 81 claims/s, no errors |
| claim-storm | `yantra gate claim-storm --concurrency 10` | PASS | 2,000 claimed once, 0 double claims, p50 51, p95 88, p99 107 ms, 85 claims/s, no errors |
| money-parity | `yantra gate money-parity --quick` (10 workers, 100 units) | **FAIL** (aborted) | 0 of 100 units reached a review within 15 min: no review task appeared because the market outbox held 9,573 unpublished events (oldest 17 min) after the claim-storm runs, draining at about 200 a minute (3.3 events/s); the work API's `/ready` answered 503 for the same reason |
| restore-drill | not run | — | waits for backup/restore to cover MinIO and the Odoo filestore |

What the two failures say:

- **Database pool.** Each API process opens at most 10 connections (`make_engine`: pool 5, overflow 5, fixed in code).
  More than about 32 requests in flight queue for a connection and time out after 30 s. The claim path itself is
  sound: no double claim in any run, and p99 stays under the 500 ms target while requests fit the pool. Fix: make the
  pool size a setting sized to the process's threadpool and the Postgres connection budget (and PgBouncer in the
  cluster), then rerun at 64 in flight.
- **Event relay throughput.** The work events process publishes about 3 events a second from the market outbox. A
  2,000-unit storm writes about 4,000 events (claimed, submitted), so quality sees the last submission roughly 20
  minutes later; three storm runs left a 47-minute backlog that starved money-parity. Fix: relay in larger batches and
  off the sequential consumer round (or in its own task), then rerun money-parity at 50 workers and 1,000 units.

### After the review fixes (5 Nov 2026)

Run on a rig rebuilt from empty volumes (`down -v`, then `up --build` with `compose.observability.yaml` and
`compose.dev.yaml`), after `yantra seed`.

| Gate | Command | Result | Figures |
|---|---|---|---|
| ui | `yantra gate ui` | PASS | 200; every security header present; scripts `'self'` + `'wasm-unsafe-eval'` only; `config.json` names the gateway |
| security | `yantra gate security` | PASS | 16 checks, 0 failed (cross-worker reads, media links, client and admin role checks, tokens, idempotency, rate limit) |
| delivery-gate | `yantra gate delivery-gate` | PASS | 409 `batch_held` while a unit was out; redo back to its author; 3 accepted units = 3 JSONL lines from MinIO; sha256 and manifest digests match |
| money-parity | `yantra gate money-parity` (50 workers, 1,000 units) | PASS | 1,000 accepted, 101 audited; earnings = window lines = paid by the rail = 12,202.00; reconciliation balanced, both deltas 0.00; invoice 25,000.00; margin 12,798.00 equals invoice minus every cost line; no errors |
| claim-storm | `yantra gate claim-storm` (500 workers, 2,000 units, 64 in flight) | FAIL (latency only) | 2,000 claimed exactly once, 0 double claims, 2,000 submitted, 0 errors; p50 343, p95 481, p99 551 ms against the 500 ms p99 target; 80 claims/s |
| restore-drill | `yantra gate restore-drill --yes` | PASS | backup 3.7 s (every database, the event stream, MinIO objects, the Odoo filestore); restore + smoke 114.6 s against the 4 h target; smoke PASS after restore |

The claim path is correct at full load; the p99 miss is capacity. The rig runs one uvicorn process for the work API
on a 4-core laptop VM next to about twenty other containers. In the cluster the work API scales out by replicas
(HPA); rerun this gate on staging before the pilot.

What this pass fixed, found by the gates:

- **Database pools** were smaller than the requests a process serves at once (uvicorn runs up to 40): the rig now
  uses 30 + 20 per process, the chart 20 + 20; the rig's Postgres runs with `max_connections=300` because Keycloak,
  Odoo and the test suite share it.
- **Event consumers** were served one after another, each idle one waiting half a second, so a busy consumer got
  about 3 events a second; a round now serves every consumer at once (each keeps its own order). The money-parity
  review backlog went from timing out after 15 minutes to clearing within the run.
- **The restore** failed when tar tried to set the mode of a volume's root-owned mount point; only that error is now
  tolerated.
- **Two app tabs** refreshing their sign-in together: refresh tokens are single use, so the loser was refused and
  could sign out before the winner's new token reached the shared store; a refused refresh now re-reads the store
  three times over about a second before signing out.
- **The smoke** now verifies worker1's email through the code in Mailpit (mail goes only to verified addresses) and
  copes with a fresh rig that has no channel yet.

### Re-run at handoff (16 Nov 2026)

This run used the rig as it stood after the Assessment v2 integration and the studio look, with `compose.dev.yaml`
for the load gates. The restore drill was not re-run.

| Gate | Result | Figures |
|---|---|---|
| ui | PASS | 200; no header missing; scripts `'self'` only; `config.json` names the gateway |
| security | PASS | 16 checks, 0 failed |
| delivery-gate | PASS | 409 `batch_held`; redo back to its author; 3 accepted = 3 JSONL lines; sha256 and manifest digests match |
| money-parity | PASS | 1,000 accepted, 88 audited; earnings = window lines = paid by the rail = 12,176.00; reconciliation balanced, deltas 0.00; margin 12,824.00 matches |
| claim-storm | FAIL (latency only) | 2,000 claimed once, 0 double claims, 0 errors; p50 356, p95 493, p99 574 ms against 500; 76.8 claims/s |

Also on that day: Python suite 100% coverage (12,857 statements); ruff, mypy, realm and vendor checks clean; app
686 tests; exam app 2,751 tests; Odoo bridges 50 tests, 0 failed; helm-check valid; `yantra smoke --with-storage` PASS.

## Other checks on 5 Nov

| Check | Result |
|---|---|
| Python suite, `uv run pytest --cov` | all pass, 100% coverage (11,887 statements) |
| `ruff check`, `ruff format --check`, `mypy` (strict, 254 files) | clean |
| Flutter: `flutter analyze`, `flutter test` | clean, 664 pass |
| `yantra smoke --with-storage` on the rebuilt rig | PASS (paid 108.00 through the RazorpayX emulator; MinIO upload and download) |
| `yantra realm-render --check` | realm current |
| `deployment/scripts/helm-check.sh` | local 36, staging 53, prod 48 resources valid; Argo CD and policies valid; promtool rules and unit tests pass |

## Not proven on the rig

Each needs real credentials or infrastructure; the command or step that proves it:

| Item | How to prove it |
|---|---|
| RazorpayX live test mode | set `YANTRA_RAIL=razorpayx` with sandbox keys and a 32+ character webhook secret on staging; run `yantra smoke` |
| Email to real inboxes | point `SMTP_HOST` at the provider on staging; verify an address from the app |
| Image push, cosign signature, SBOM | first push to `main`; `cosign verify` as in `deployment/README.md` |
| Kubernetes install | `deployment/scripts/kind-up.sh` locally (needs kind, kubectl, helm), then staging through Argo CD |
| Managed Postgres point-in-time recovery | enable PITR (14 days) and run the monthly restore drill into staging |
| Keycloak production realm | import the rendered staging/prod realm; enrol TOTP for ops, finance and admin |
| Claim latency target | rerun `yantra gate claim-storm` on staging with the HPA on |

