---
type: Playbook
title: Delivery Roadmap
description: Phased implementation plan for Yantra — from infrastructure scaffold to full marketplace parity — with per-phase scope, dependencies, and verification criteria.
tags: [roadmap, phases, delivery, planning]
status: draft
---

# Principles

Each phase is a shippable increment with explicit verification gates. Phases 1–3 make Yantra the internal ERP for 20K onsite staff; phases 4–6 build the 200K-worker marketplace to competitor parity. Workstreams inside a phase parallelize across submodules (`services/*`, `app/`, `ethara_*` addons); phases themselves are sequential only where a hard dependency exists. Every phase ends with load/regression evidence, not intent.

# Phase 0 — Foundation (infrastructure scaffold)

Scope: Kubernetes cluster + Crunchy PGO `PostgresCluster` (3-replica HA, pgBackRest to PVC+S3, pgMonitor); self-built Postgres images (licensing posture per [INFRASTRUCTURE.md](INFRASTRUCTURE.md)); CNCF baseline per the trail map in [INFRASTRUCTURE.md](INFRASTRUCTURE.md) — Cilium CNI + default-deny NetworkPolicies, Envoy Gateway ingress, CoreDNS, Harbor + containerd, Argo CD GitOps, Kyverno policies, cert-manager, external-secrets, Falco, sigstore signing with SBOM/SLSA; Keycloak, Redis, object store, NATS JetStream (CloudEvents); `services/odoo` submodule scaffold — Odoo 19 CE + OCA aggregation (repos pinned by commit), first-party Helm charts for the four Odoo deployment roles; `ethara_session_redis` + `fs_attachment` S3 filestore (statelessness prerequisites); CI for submodules; `services/gateway` skeleton with Keycloak JWT validation and idempotency middleware; `app/` Flutter scaffold with auth flow.

Verify: HA failover drill (kill primary, <30s recovery); pgBackRest PITR restore drill; Odoo pods pass liveness/readiness on `/web/health`; horizontal scale of `odoo-web` from 2→10 pods with sessions surviving pod kills; OIDC login round-trip.

# Phase 1 — Core HRMS (onsite workforce)

Scope: `hr`, org structure, `hr_contract`, `hr_attendance` + `ethara_attendance_geo` (geofenced check-in incl. kiosk + Flutter check-in), `hr_holidays` (+public holidays), `hr_skills`, `hr_homeworking`, `hr_presence`, onboarding/offboarding activity plans wired to IT provisioning webhooks, `base_tier_validation` approval chains, `auth_oidc` SSO for staff, `web_responsive`, `auditlog`, employee document vault (`hr_employee_document`, `dms`).

Verify: end-to-end hire→onboard→attend→leave→exit flow; geofence rejection test (check-in outside radius blocked/flagged); import of full 20K-employee dataset with per-page backend latency <1s at simulated 1K concurrent sessions.

# Phase 2 — Finance Core

Scope: `account` + India GST (`l10n_in`, `l10n_in_edi` IRN e-invoicing, e-way bills), TDS/TCS withholding, analytic plans (department/project/client cost centers), `hr_expense` + expense tier validation, OCA financial reporting (`account_financial_report`, `mis_builder`, `account_budget_oca`), asset management (`account_asset_management`) for laptops/equipment, bank reconciliation (`account_reconcile_oca`), payment providers (Razorpay, Stripe inbound), `ethara_gst_returns` (GSTR-1/3B export), payroll engine (OCA `payroll`) + `ethara_l10n_in_payroll` statutory rules, payslip portal delivery.

Verify: GST e-invoice IRN round-trip against NIC sandbox; a full month-end close on seeded data; parallel payroll run for 20K employees within batch window (queue_job channels); TDS computation matches CA-validated fixtures; GSTR export accepted by portal validator.

# Phase 3 — ITMS and Operations

Scope: `maintenance` + OCA extensions as ITAM (equipment registry, employee assignment, preventive plans), `ethara_itms` (CMDB dependency graph, assignment history, BYOD flags, `itms.problem`, `itms.change.request` with tier-validation routing), `ethara_license` seat register, `helpdesk_mgmt` + SLA + portal intake for IT tickets, `purchase_request` IT requisitions, `document_page` wiki for runbooks, `repair`, `project` for internal delivery work, `sale_project`/`sale_timesheet` client billing, `subscription_oca` recurring client contracts, `fieldservice` if field dispatch is needed.

Verify: laptop lifecycle (procure→assign→incident→repair→reassign→retire) fully audit-trailed; ticket SLA breach alerts fire; change request cannot reach "approved" without required tiers; license register renewal reminders fire; client invoice generated from approved timesheets and milestones.

# Phase 4 — Online Workforce Foundation

Scope: public candidate funnel (`website_hr_recruitment`), assessment integration (`survey` + `hr_recruitment_survey`), `website_slides` training academy + certifications + `hr_skills_slides` skill grants, `gamification` + `website_profile` reputation, `website_forum` community; `ethara_workforce` contractor onboarding orchestration (gated checklist: ID/background → `sign_oca` contract → tax form → payment setup → employee+vendor+portal identity); `ethara_portal` worker portal surfaces; portal timesheets (`hr_timesheet_portal`); `services/assess` v1 (structured assessments, code sandbox, anti-LLM detection); `services/notify` (FCM + email/SMS); Flutter app v1 (apply→assess→onboard→learn journeys).

Verify: synthetic cohort of 10K applicants flows funnel→certification→work-eligible without manual intervention; onboarding gate provably blocks work before checklist completion; portal user can see only their own records (record-rule penetration tests); push notification delivery round-trip.

# Phase 5 — Task Marketplace and Payments (Mercor/Scale parity core)

Scope: `services/market` (work-unit model, batch fan-out, claim API with `FOR UPDATE SKIP LOCKED`, rate cards by geography/domain/credential, per-unit pay disclosure, hourly + deliverable contract types); `services/tracker` (desktop/mobile activity agent ingestion, screenshots to S3, caps and anomaly flags) + `ethara_tracker_link`; `services/quality` v1 (attempt→review pipelines, reviewer hierarchy, seeded evaluation units, calibration gating, dispute workflow); `services/payout` (Stripe Connect, Wise, Razorpay rails; weekly cadence; first-payout hold; instant payout; earnings dashboard) reconciling into Odoo self-billed vendor bills with TDS; `ethara_referral` earnings-share engine; completion-signal → ledger → client-invoice pipeline; Flutter task/claim/earnings experiences.

Verify: load test 200K registered / 20K concurrent claim storm — zero double-claims, p99 claim latency within SLO, Odoo untouched by claim path; payout dry-run reconciles to the paisa against ledger; dispute flow reverses a rejected unit end-to-end; referral accrual caps enforced.

# Phase 6 — AI Layer and Intelligence

Scope: `services/assess` v2 (AI video interviews with transcription/scoring, practice mode, retake policy); `services/quality` v2 (LLM-as-judge auto-review, multi-agent adjudication, trust/fit scoring, dataset-level quality scores); semantic talent search and auto-match/instant offers; `services/analytics` (Debezium CDC read models, executive dashboards via `mis_builder` + BI, MRR/utilization analytics); WhatsApp bridge; workforce-ops tooling (pods, PIP tracking, area-manager consoles).

Verify: AI interview score correlation vs human-panel baseline on a calibration set; LLM-judge first-pass acceptance benchmarked against human audit sample; CDC lag and replication-slot alerts proven under module-upgrade schema churn; exec dashboard reconciles with GL.

# Standing Workstreams

Security (quarterly penetration tests focused on portal record rules and gateway auth), load testing before every phase gate (the 20K/200K scale has no public precedent — internal evidence is the only evidence), Odoo/OCA version upkeep (pin-and-review cadence, expand/contract migration discipline), and documentation (this OKF bundle updated every phase; `log.md` maintained).

# Open Decisions

| Decision | Options | Owner gate |
|---|---|---|
| Event bus | **Ratified: NATS JetStream + CloudEvents** (CNCF alignment); Kafka-via-Strimzi remains the documented fallback if event-volume profile demands it | Phase 0 (revisit only on load-test evidence) |
| Crunchy vs Percona operator | Crunchy CRDs + self-built images vs Percona fork wholesale | Phase 0 |
| Time-tracker client | Build in-house desktop agent vs integrate Insightful/Hubstaff-class vendor | Phase 5 |
| Appraisals | OCA appraisal port vs `ethara_appraisal` custom | Phase 1–2 |
| Code-assessment sandbox | Self-hosted (Judge0-class) vs SaaS (HackerRank/Codility API) | Phase 4 |
