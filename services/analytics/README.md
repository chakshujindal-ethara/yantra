# analytics

The read side: every event, once, and the numbers leadership reads. Schema `analytics`; runs in the `work`
deployable and emits nothing. The contract is `docs/PRODUCT.md` section 5.8.

## What is built

| Piece | What it does |
|---|---|
| Warehouse | `analytics.event`: one durable consumer on every subject (`analytics-all-g<n>`) stores each event once, keyed by its CloudEvent id, with the ids a mart groups by pulled out of the payload; any event type is kept as it is |
| Dimensions | `dim_batch` (project, currency and rates, from a batch's publication or its manifest) and `dim_unit` (a unit's batch, from any event naming both) |
| Marts | project by IST day (published, claimed, submitted, accepted, rejected, first pass, pay, price, review and audit cost, margin), funnel by listing and day (from `talent.application.moved.v1`), worker by week (tracked hours, accepts, earnings), quality by project and day (reasons, billable rework, audits), pay windows (paid on time or not). Recomputed every five minutes for the days whose events arrived since the cursor, never incremented, so a replay never double counts |
| Leadership | the four numbers against the latest baseline, margin per accepted unit per project (the same arithmetic as payout's margin report), the watch list; every tile says what it is made of and which page explains it |
| Baselines | insert-only; each PUT is a new row, so the history of what leadership compared against stays |
| Rebuild drill | an admin asks; the events process empties the marts and consumed ids, moves to the next durable generation (a replay from sequence 1) and records `done` once nothing is pending |

## What is deferred

- **Odoo CDC (Debezium).** The ledger is not read; finance figures come from payout's events, which reconcile with
  Odoo through the bridge. A cheap stand-in when wanted: an Odoo cron posting each paid window's ledger marks to a
  `POST /v1/analytics/ledger-marks` route (not built).
- **History beyond the stream.** The stream keeps 30 days, so a replay reaches back 30 days; `repair` keeps every
  older warehouse row. Archiving the stream (or raising its retention) is a separate decision.
- **Its own deployable.** It has its own schema, durable and tables, so moving it out is a new deployable and one
  gateway route; at Stage 1 volume it shares the `work` process.
- **Rail fees and the levy as events.** Until payout emits them, the baseline carries the rate per payout and the
  levy rate.
