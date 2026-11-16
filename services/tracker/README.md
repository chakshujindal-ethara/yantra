# tracker

What a worker's screen does while a claim is open, and the integrity checks built on it. Schema `tracker`; runs in
the `work` deployable. The contract is `docs/PRODUCT.md` section 5.7.

## What is built

| Piece | What it does |
|---|---|
| Sessions | one open session per worker (a partial unique index), started on a live claim or none; ended by the worker, by the stale job after 15 minutes without a sample, or because the claim ended |
| Samples | one per 30 seconds: `active`, `idle` or `focus_lost`; keyed by (session, bucket start), so a batch sent twice counts once and active time never exceeds the wall clock; the label `yantra-web` kept, any other only as a keyed digest; window titles never accepted |
| Weekly caps | per worker, per project, or the default (40 hours); the IST week from Monday 00:00; going over flags once a week and emits `tracking.cap.exceeded.v1`; work keeps being recorded |
| Detectors | every five minutes: more than 20 active hours in 24 (`impossible_activity`), samples more than ten minutes after the session's claim ended or lapsed (`no_live_claim`), one device id on several workers in seven days (`duplicate_device`) |
| Flags | one open flag per worker and kind; an operator dismisses or upholds with a note; upholding emits `tracking.anomaly.upheld.v1` and payout puts an integrity hold on the worker |
| Screenshot references | presigned upload to object storage under `tracker/<worker>/<session>/`, registered with its time; the API never serves the object |
| Live claims | a read model of market's `claimed`, `expired`, `released` and `submitted` events |
| Retention | samples after 30 days, screenshot references (and their objects) after theirs, hourly |
| Policy | `GET /v1/tracker/policy`: what is collected, what is not, how it is used and how long it is kept |

## What is deferred

- **A desktop agent.** The web app cannot see other windows or take screenshots, and does neither. The
  screenshot API and the hashed-label rule exist for a desktop agent; none is built. Shipping one needs a new
  version of the policy that workers accept first.
- **The `pattern` detector.** The kind is reserved in the check constraint; nothing produces it yet.
- **The Odoo timesheet link** (`ethara_tracker_link`). Pay is per accepted unit, so no timesheet is needed in Stage 1.
- **Partitioning `activity_sample` by month.** The 30-day purge keeps the table bounded at Stage 1 volume.
- **A stronger device signal.** `device_hash` is a random id the browser keeps; a cleared storage or a second
  browser is a new device, so it catches only several accounts on one browser profile.
