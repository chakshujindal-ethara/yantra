# Runbooks

One section per thing that goes wrong in Stage 1, written for the person on call. Commands assume the compose
rig (`docker compose -f deployment/local/compose.yaml`) or, in a cluster, `kubectl -n yantra-<env>` with the
release named `yantra`. CLI commands are `uv run yantra <command>` signed in as an operator (`yantra login`).

Alerts (`deployment/observability/alerts.yaml`) and where to start:

| Alert | Section |
|---|---|
| GatewayLatencyP99, Http5xxRatio, TargetDown | [Gateway slow or failing](#gateway-slow-or-failing) |
| DoubleLiveClaims, JobOverdue | [Stuck claims](#stuck-claims) |
| ReviewBacklogAge | [Review backlog](#review-backlog) |
| ReconciliationDelta, PayWindowNotClosed | [Stalled pay window](#stalled-pay-window) |
| FailedPayouts, RailUnreachable, PayoutLinesStuck | [Rail outage](#rail-outage) |
| ConsumerLag, OutboxStale | [NATS backlog](#nats-backlog) |
| DeadLetters, JobFailing | [Dead letters](#dead-letters) |
| PgConnections | [Connection headroom](#connection-headroom) |

The Grafana overview (http://localhost:3000 on the rig) shows every number these alerts read.

## Gateway slow or failing

1. Which process: the dashboard's "Slowest routes p99" and "Requests per second" panels split by process and route;
   `curl -s localhost:8090/ready` says whether Redis or the signing keys are the problem.
2. A 5xx from the gateway with code `upstream_unavailable` means work or money is down or slow: check their
   containers or pods (`docker compose ps`; `kubectl get pods`) and their `/ready` (503 `database_unavailable`
   when their database is away; `outbox_stale: true` is reported there but never fails readiness).
3. One slow route: find its request ids in the JSON logs (`docker compose logs work | jq 'select(.duration_ms > 1000)'`)
   and, with tracing on, open the trace for that request id's span.
4. TargetDown: the process is not answering `/metrics` at all; restart it and read its last log lines.

## Review backlog

1. `uv run yantra stuck` lists review claims past their time; release them (`yantra stuck-release`) so the queue moves.
2. A queue that waits on certification or clearance: `POST /v1/quality/reviews/claim` answers 404 with
   `waiting_for_gate` and `waiting_for_clearance` counts. Certify more reviewers (`PUT /v1/workers/{id}` with the
   gate) or clear one for sensitive work (`yantra reviewer-set <worker> --sensitive-cleared`).
3. Not enough reviewers at all: raise the batch's review pay or move reviewers from another project, and tell the
   client the delivery date at risk.

## Stuck claims

Symptom: workers report "you already have a live claim" with nothing on screen; `units claimed` stays high.

1. Claims past their time limit are released by the `market_claim_expiry` job every 30 s. Check it ran:
   `curl -s <work-events>:8085/ready | jq .jobs.market_claim_expiry` (in a cluster, port-forward
   `svc/yantra-work-events 8085`). `overdue: true` or a `last_error` means the events process is wedged.
2. Release by hand: `uv run yantra release-expired` (or `POST /v1/claims/release-expired`).
3. If the events process is unhealthy, restart it (`kubectl rollout restart deploy/yantra-work-events`); the job
   lease is a row with a deadline, so a restart never runs a job twice at once.

## Stalled pay window

Symptom: Saturday morning and no closed window, or a closed window that never reaches `paid`.

1. Close: the `payout_window_close` job runs Saturday 00:05 IST. `uv run yantra windows` shows the week. If it
   is missing, close by hand: `uv run yantra window-close --currency INR`.
2. Approvals: two different people with the `finance` role. `uv run yantra windows` shows the count.
3. Paying: a window in `paying` has lines in `queued`/`processing`/`failed`. `uv run yantra rail-status`;
   retry a failed line once the worker's account is verified (`line-retry`), or release it to the next window
   (`line-release`). A window becomes `paid` only when every non-held line is paid or released, so Odoo never
   bills a partial window.
4. Never edit window or line rows in the database; reconciliation would flag it and so would the auditors.

## Failed webhook

Symptom: lines stay `processing` long after RazorpayX shows them processed.

1. The `payout_rail_poll` job (every 60 s) is the backstop: it fetches every line `processing` for more than
   2 minutes. If lines still sit there, check its `last_error` on money-events `/ready`.
2. A 401 in the gateway log for `/v1/payout/webhooks/razorpayx` means the webhook secret in RazorpayX and in
   the secret store (`razorpayx-webhook-secret`) differ. Fix the store; the poll job settles lines meanwhile.
3. Duplicate deliveries are harmless (deduplicated on the event id); stale ones (older than 5 minutes) are
   recorded and ignored, and the poll job settles their lines.

## Rail outage

Symptom: `RailUnreachable` (more than half the rail calls time out, cannot connect or get a 429/5xx) or
`PayoutLinesStuck` (lines queued or processing for 30 minutes); lines stay `queued`. Queued lines never count as
failed, so `FailedPayouts` stays quiet during an outage. The calls by outcome:

```promql
sum by (outcome) (rate(yantra_rail_calls_total{rail="razorpayx"}[5m]))
# outcome: ok | timeout | unreachable | retry (429 or 5xx) | refused (a 4xx: a bad request, not an outage)
```

1. Queued lines wait; nothing is lost and nothing is paid twice (the idempotency key is fixed per attempt).
2. If the outage outlasts the pay-day promise, switch the window to the bank file: set `YANTRA_RAIL=file` for
   money and money-events, then `uv run yantra bank-file <window>`, upload it to the bank, and upload the
   bank's return file with `bank-file-reconcile`. Switch back once RazorpayX recovers.

## NATS backlog

Symptom: `ConsumerLag` or `OutboxStale` alerts; screens lag behind actions.

1. `/ready` on work, money and both events processes shows `outbox_unpublished` per schema. An events process
   whose oldest unpublished row is older than `YANTRA_OUTBOX_STUCK_SECONDS` (300) and whose backlog did not shrink
   since the previous probe answers 503 `outbox_stuck` (its relay is wedged: restart it). The API processes only
   report `outbox_stale`; their readiness is the database alone, so a NATS outage never empties their Services.
2. `docker run --rm --network yantra-local_default natsio/nats-box:0.14.5 nats -s nats://nats:4222 consumer
   report YANTRA` shows pending messages per durable.
3. A consumer stuck on one message: after 20 deliveries it goes to that module's dead letters (next section).
4. If the events process is down, restart it; outbox rows are published in order once it is back.

## Dead letters

Symptom: `DeadLetters` or `JobFailing` alert.

1. List: `uv run yantra dead-letters <module>` (market, talent, assess, quality, notify, tracker, analytics,
   payout); each row has the consumer, the event type and the reason (never the payload).
2. Fix the cause (a deploy, a data fix through the product), then replay:
   `uv run yantra dead-letter-replay <module> <id>`. Replay is idempotent: an event already consumed is just
   removed from the list.
3. `JobFailing`: the job's `last_error` is on its events process's `/ready` (`jobs.<name>.last_error`). The
   failure counter only exists from a job's first failure, so the alert fires on any rise within 15 minutes or on
   a counter that appeared at 2 or more inside that window.

## Connection headroom

Before a large batch or a cohort onboarding:

1. Every database pod (work and money, API and events) holds up to `YANTRA_DB_POOL_SIZE + YANTRA_DB_MAX_OVERFLOW`
   connections (the chart sets 20 + 20, the compose rig 30 + 20: an API pod serves up to 40 requests at once, and a smaller pool makes them wait for a connection). Budget = `sum over deployments(replicas x
   (pool + overflow)) + 10 for migrations and ops`.
2. Keep the budget under 85% of `max_connections` (the `PgConnections` alert fires above that). With
   PgBouncer in transaction mode in front, the budget is against PgBouncer's pool instead.
3. Raise HPA maximums only after the budget allows it.

## Restore drill

Monthly on staging (managed Postgres point-in-time restore into a new instance, repoint the secrets, run
`yantra smoke`), and on the rig whenever the backup scripts change:

```bash
deployment/scripts/backup.sh                       # prints backups/<timestamp>
deployment/scripts/restore.sh backups/<timestamp>  # restores, restarts and runs yantra smoke
```

Targets: recovery point 15 minutes, recovery time 4 hours (Stage 1). Measured on the compose rig:

| Date (IST) | Backup | Restore | Smoke | Data |
|---|---|---|---|---|
| 4 Nov 2026 | 2.8 s (4 databases + stream, 3.8 MB) | 1 s for `yantra` into a scratch database | not run (full `restore.sh` deferred) | row counts equal in the five checked tables |

Add a row after every drill (deployment/README.md has the detail).

## Deploy freezes

No deploys to prod:

- Friday 12:00 to Saturday 12:00 IST (the pay window closes and is paid). Argo CD enforces it with a deny sync
  window on `yantra-prod` (`deployment/argocd/project.yaml`).
- During any exam sitting window announced by ops, and inside any batch's last 24 hours before its due date.
  These are procedural: the release owner checks the ops calendar before syncing.

An incident fix during a freeze needs the on-call lead's approval and is synced by hand in the Argo CD UI.
