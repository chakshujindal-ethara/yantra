---
type: Architecture
title: Yantra System Architecture
description: End-to-end architecture for Ethara.AI's workforce platform — Odoo 19 CE core, microservices ring, Flutter frontend, Kubernetes/Crunchy PostgreSQL, sized for 20K onsite and 200K online workers.
tags: [architecture, odoo, microservices, kubernetes, flutter, postgresql]
status: draft
sources:
  - id: odoo-server
    resource: https://github.com/odoo/odoo/blob/19.0/odoo/services/server.py
    title: Odoo server process model (PreforkServer, GeventServer)
  - id: odoo-deploy
    resource: https://github.com/odoo/documentation/blob/19.0/content/administration/on_premise/deploy.rst
    title: Odoo official production deployment guide
  - id: queue-job
    resource: https://github.com/OCA/queue/blob/18.0/queue_job/README.rst
    title: OCA queue_job README (jobrunner constraints)
  - id: server-auth
    resource: https://github.com/OCA/server-auth
    title: OCA server-auth (auth_oidc, auth_jwt modules)
  - id: pgo
    resource: https://github.com/CrunchyData/postgres-operator
    title: Crunchy Postgres Operator (PGO v5)
  - id: task-assignee-fix
    resource: https://github.com/odoo/odoo/commit/952fa8225f29ff021b421e1add8736909dd3427f
    title: Odoo commit forbidding portal-user task assignment
---

# Overview

Yantra is a hub-and-spoke platform. Odoo 19 Community Edition is the hub — the system of record for people, money, assets, and projects. A ring of in-house microservices (git submodules under `services/`) handles everything Odoo cannot do at scale or does not do at all: the 200K-worker task marketplace, AI-driven vetting, multi-stage quality pipelines, multi-rail payouts, and push notifications. A single Flutter application (submodule, specs in `app/`) is the face of the platform for online workers and mobile-first onsite staff. The two workforces deliberately take different paths: onsite employees (20K) use Odoo's own backend UI; online workers (200K) exclusively use Flutter → API gateway → microservices, and their state is synchronized into Odoo asynchronously. This separation exists because Odoo's ORM, worker pool, and row-locking model have never been publicly proven at 200K-client concurrency, and the task-claim workload (bursty, contended writes) is precisely the workload Odoo handles worst.

# System Topology

```
                          ┌─────────────────────────────┐
                          │        Flutter App          │  app/ (submodule)
                          │  (workers + mobile staff)   │
                          └──────────────┬──────────────┘
                                         │ HTTPS / JWT (Keycloak-issued)
                          ┌──────────────▼──────────────┐
                          │     services/gateway         │  API gateway: authN/Z, rate
                          │  (REST/OpenAPI, idempotency,│  limits, idempotency keys,
                          │   backpressure, coalescing) │  retry absorption
                          └──┬───────┬───────┬──────┬───┘
             ┌───────────────┘       │       │      └───────────────┐
   ┌─────────▼────────┐   ┌──────────▼─────┐ ┌───────▼────────┐ ┌───▼──────────────┐
   │ services/market   │   │ services/quality│ │ services/payout │ │ services/assess   │
   │ task marketplace │   │ review/audit/  │ │ rails: Stripe  │ │ AI interview,    │
   │ claim, rate cards│   │ calibration,   │ │ Connect, Wise, │ │ assessments,     │
   │ queue fan-out    │   │ LLM-as-judge   │ │ Razorpay       │ │ anti-cheat       │
   └─────────┬────────┘   └──────────┬─────┘ └───────┬────────┘ └───┬──────────────┘
             │      own Postgres DBs (database-per-service)         │
             └───────────────┬───────┴───────────────┬──────────────┘
                             │  outbox events / REST │
                          ┌──▼───────────────────────▼──┐
                          │       services/odoo          │  Odoo 19 CE + OCA + ethara_*
                          │  system of record: HR,      │  addons; deployments: http,
                          │  finance, assets, projects  │  gevent, cron, jobrunner
                          └──────────────┬──────────────┘
                          ┌──────────────▼──────────────┐
                          │  PostgreSQL (Crunchy PGO)   │  Patroni HA, pgBackRest,
                          │  + pgBouncer + Redis + S3   │  transaction/session pools
                          └─────────────────────────────┘
   Cross-cutting: Keycloak (IdP) · NATS JetStream event bus · services/notify (FCM) ·
   services/tracker (activity ingestion) · services/analytics (CDC read models)
```

# Component Responsibilities

## Odoo Core (`services/odoo`)

Odoo 19 CE owns: employee master and org structure, contracts and onboarding state, attendance and leave, timesheets, recruitment ATS, eLearning and certifications, gamification, accounting (GL, AR/AP, India GST e-invoicing, TDS), expenses, analytic cost centers, projects and client billing, IT asset registry (maintenance), helpdesk (OCA), DMS and e-signature (OCA), approvals (OCA tier validation), and payroll (OCA engine plus in-house India statutory rules). The complete module selection is in [MODULES.md](MODULES.md). Custom in-house addons live in an `ethara_*` namespace inside this submodule.

Odoo runs as four distinct Kubernetes Deployment roles (details in [INFRASTRUCTURE.md](INFRASTRUCTURE.md)): HTTP workers (prefork, small pods of 2–4 workers for HPA granularity), a gevent/websocket deployment (port 8072, `/websocket` ingress path, no CPU-based HPA), cron workers (`--workers 0 --max-cron-threads N`, no ingress), and async job processing via `queue_job_cron_jobrunner` — chosen over the raw jobrunner because the raw runner requires a single-replica LISTEN/NOTIFY connection that is incompatible with transaction-mode pgBouncer and constitutes a single point of failure.[^queue-job]

## API Gateway (`services/gateway`)

The gateway is the only ingress for the Flutter app and for 200K online workers. It validates Keycloak-issued JWTs, enforces per-worker rate limits, implements the Idempotency-Key pattern (device-generated UUID per mutation, dedup table in Redis with unique-constraint fallback in Postgres), absorbs mobile retry storms from spotty gig-worker connectivity, and coalesces reads. It exposes a clean REST contract to Flutter that is fully decoupled from Odoo's RPC shape, so Odoo's API surface can evolve without a mobile release. Odoo is reached two ways: native `@http.route` controllers in the `ethara_api` addon (secured with OCA `auth_jwt` validators, i.e. `auth='jwt_<validator>'`) plus the JSON-2 external API for generic ORM access — both low-volume, synchronous, service-to-service — and the event bus for everything else. No additional REST framework is layered inside Odoo: with the gateway owning the public OpenAPI contract, OCA `fastapi`/`base_rest` would add porting risk without performance benefit (they share Odoo's workers and ORM anyway). Native XML-RPC is avoided for new work (deprecated for removal in Odoo 22).

## Task Marketplace (`services/market`)

This is the highest-risk, most custom component, because the gap is structural: Odoo hard-codes portal users out of `project.task.user_ids` (share=False domain, a deliberate security fix),[^task-assignee-fix] so portal workers can never be native task assignees. The marketplace service therefore owns its own work-unit model in its own database: batches fan out into claimable work units, workers browse available units with per-unit pay disclosed up front (rate cards tiered by geography, domain, and credential level), and claims are serialized with `SELECT … FOR UPDATE SKIP LOCKED` so two workers can never claim the same unit. Completion events are canonical signals — the single source of truth that drives quality review, worker payout accrual, and client invoicing (the Mercor architecture lesson). Aggregated results sync into Odoo asynchronously as analytic lines and vendor-bill inputs; individual claim traffic never touches Odoo.

## Quality Pipeline (`services/quality`)

Implements the Scale AI quality model: configurable multi-stage pipelines (attempt → review → consensus aggregation), a reviewer hierarchy with percentile-based promotion and demotion, seeded evaluation units silently scoring worker accuracy inside live batches, calibration batches gating production access, an LLM-as-judge auto-review layer ahead of human QA, per-worker trust/fit scoring, and a first-class dispute/appeals workflow (a known failure mode at Scale that Yantra explicitly designs against). Verdicts feed back into the marketplace (access gating) and payouts (release/hold).

## Vetting and Assessment (`services/assess`)

AI-conducted structured video/voice interviews with transcription and scoring, practice mode and bounded retakes (Mercor pattern); orchestrates Odoo's `survey` engine for structured written assessments and certification exams; integrates code-execution sandboxes for engineering roles; runs anti-cheat and anti-LLM detection over submissions. Results write back to Odoo candidate/employee skill records so recruitment matching (`hr_recruitment_skills`) and marketplace gating share one skills graph.

## Payouts (`services/payout`)

Multi-rail disbursement: Stripe Connect (primary global), Wise (fallback regions), Razorpay (India domestic), with weekly payout cadence, first-payout holds, optional fee-based instant payouts, and a real-time earnings dashboard feed for the Flutter app. The ledger of record is Odoo accounting: completion signals accrue into self-billed vendor bills (OCA `account_invoice_supplier_self_invoice` pattern) against each worker's `res.partner` vendor record, and payout execution reconciles against batch payments. TDS on contractor payouts is handled by Odoo's India withholding modules.

## Supporting Services

`services/notify` owns FCM server credentials and all push delivery (never inside Odoo); `services/tracker` ingests desktop/mobile time-tracker payloads (activity samples, optional screenshots to S3, idle detection) and links them to timesheet lines with anomaly/over-logging flags; `services/analytics` consumes Debezium CDC from the Odoo database strictly for read models and BI (never to drive business logic — a stalled replication slot on a multi-TB DB is a disk-filling hazard, and Odoo's schema churns on every module upgrade); an outbox-bridge inside `services/gateway` or standalone owns the NATS JetStream producer so no message-broker client ever runs inside the Odoo process.

# Integration Patterns

| Pattern | Rule |
|---|---|
| Events out of Odoo | `base_automation` webhook triggers + `queue_job` retry wrapper → outbox bridge → event bus. No Kafka/NATS client inside Odoo. |
| Calls into Odoo | Native `@http.route` controllers (`ethara_api`) secured by OCA `auth_jwt`; JSON-2 API for generic ORM access; no in-Odoo REST framework (`fastapi`/`base_rest`); XML-RPC forbidden for new work. |
| Worker mutations | Always: Flutter → gateway (idempotency key) → service DB → async buffered write into Odoo via queue. Never a synchronous 200K-client write path into Odoo tables. |
| Data ownership | Odoo is system of record for HR/finance/asset/project entities. Each service owns its bounded-context DB and syncs master data from Odoo events; services never write directly into Odoo's tables. |
| Contention handling | Gateway and services implement retry-with-backoff for Odoo `LockError`-class responses; hot rows (rosters, shared counters) are kept out of Odoo and inside service DBs. |
| CDC | Debezium → analytics read models only. Schema-history handling required across Odoo module upgrades. |

# Identity and Security

Keycloak is the single IdP. Onsite employees SSO into Odoo's backend via OCA `auth_oidc` (session-expiry edge cases with Keycloak are a known rough edge to be load-tested); online workers authenticate to the gateway with Keycloak JWTs — Odoo is never the token-validation chokepoint for 200K users. Inside Odoo, the three-tier user model is exploited deliberately: internal users (paid concept irrelevant on CE, but heavy backend users), portal users (200K workers get portal identities for the few Odoo-rendered surfaces they touch — payslips, certificates, documents), and public users (candidate-facing website). Every worker-facing Odoo model inherits `portal.mixin` and carries explicit `ir.rule` row-level scoping to `partner_id`; portal write access is granted only through deliberately scoped endpoints, never blanket ACLs. Workers are modeled as `hr.employee` records with `employee_type='freelance'` linked 1:1 to a `res.partner` vendor record (employee side drives skills/assignment/training; partner side drives payouts) — an in-house `ethara_workforce` addon keeps the pair in sync.

# In-House Build Register

These capabilities exist nowhere in Odoo CE or OCA and are built in-house (each mapped to its home in [MODULES.md](MODULES.md) or the service catalog above): task marketplace with portal claim semantics; screenshot/activity time-tracker ingestion; geofence enforcement on attendance (core stores coordinates but never validates them); software/SaaS license seat register; ITIL problem/change management and CMDB dependency graph; contractor onboarding orchestration (e-sign → employee + vendor partner + portal user in one flow); AI interview and LLM-as-judge scoring; Wise/Stripe-Connect payout execution; geography/domain rate cards, earnings-share referral engine, reviewer hierarchy, trust scoring, dispute workflow; WhatsApp messaging via Meta Cloud API; India statutory payroll rules (PF/ESI/PT/TDS/LWF salary structures) on top of the OCA payroll engine.

# Scale Engineering Summary

Capacity is engineered from Odoo's official formulas (workers = 2×CPU+1, ~6 concurrent heavy users per worker, RAM ≈ workers × (0.8×150MB + 0.2×1GB)): 20K internal users at 5–10% concurrency ⇒ 1,000–2,000 concurrent sessions ⇒ roughly 170–330 HTTP workers spread across 40–85 small pods. The 200K online workers are kept off Odoo's workers entirely by design. Sessions move to Redis (custom ~150-line `ir.http` override; no OCA-mature module exists), attachments move to S3 via OCA `fs_attachment`, and pgBouncer runs transaction-mode pooling for Odoo workers with the constraint chain `db_maxconn ≤ max_client_conn ≤ max_connections`. Full topology, PGO configuration, probe design, HPA strategy, and the zero-downtime-upgrade caveat live in [INFRASTRUCTURE.md](INFRASTRUCTURE.md). All numbers are hypotheses pending load tests that mirror the real internal/portal traffic split.

[^queue-job]: OCA queue_job README (jobrunner constraints)
[^task-assignee-fix]: Odoo commit forbidding portal-user task assignment
