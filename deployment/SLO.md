# Service levels (Stage 1)

What Yantra promises while the pilot runs, how each promise is measured, and what happens when the budget is
spent. Targets come from the plan's service-level table; the expressions use the metrics the services expose on
`/metrics` (the names are defined in `yantra_common.metrics`). Alert rules live in
`deployment/observability/alerts.yaml`.

| Promise | Target | Measured by |
|---|---|---|
| Gateway and work available | 99.5% of minutes in 30 days (99.9% from Stage 2) | `1 - (sum(rate(yantra_http_request_duration_seconds_count{process="gateway",status=~"5.."}[5m])) / sum(rate(yantra_http_request_duration_seconds_count{process="gateway"}[5m])))` above 0.99 for the minute, plus `up{job=~"gateway|work"}` |
| Claim latency | p99 under 500 ms at 500 concurrent workers | `histogram_quantile(0.99, sum by (le)(rate(yantra_http_request_duration_seconds_bucket{process="gateway",route=~"/v1/batches/{id}/claims"}[5m])))`; the claim-storm gate proves it before each release |
| Review queue age | 95% of submissions reviewed within 48 hours | `yantra_review_backlog_oldest_age_seconds < 172800` |
| Pay window on time | 100%: every week's window closed Saturday 00:05 IST and paid by its due date | `yantra_pay_window_last_closed_timestamp` within the last 7 days; window lines by status |
| Money is exact | Zero reconciliation delta | `yantra_pay_window_reconciliation_delta == 0` |
| Claims are exclusive | Zero double claims | `yantra_units_with_two_live_claims == 0` (a database invariant; the gauge proves it holds) |
| Exams undisturbed | Zero sittings disturbed by a deploy | Deploy freeze during every sitting (RUNBOOKS.md, "Deploy freezes") |

## Error budget

99.5% over 30 days is 3 h 36 min of unavailability. When the budget for the window is spent:

1. Feature releases pause; only fixes and reliability work ship until the 30-day window recovers.
2. The incident review names the cause and the guard (test, alert or runbook step) that would have caught it.
3. Any money or double-claim breach pauses releases at once, regardless of the budget, until reconciled.
