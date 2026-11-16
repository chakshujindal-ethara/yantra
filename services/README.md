---
type: Specification
title: Services Overview
description: Index of Yantra backend microservices — one git submodule per service, each with its own database, API, and event contracts.
tags: [microservices, services, specification]
status: draft
---

# Services

Each service is a separate git submodule with its own bounded context, database, container, and Helm chart (chart lives in [deployment/](../deployment/)). Hard rules from [ARCHITECTURE.md](../ARCHITECTURE.md): database-per-service (ids, not cross-DB foreign keys), no service writes into another service's store or into Odoo's tables, all cross-service communication via published APIs or the event bus, all mutating endpoints honor idempotency keys. Call flows, ER diagrams, and state machines for every service are in DESIGN.md.

| Service | Submodule (planned) | Responsibility |
|---|---|---|
| [gateway/](gateway/) | `EtharaOrion/yantra-gateway` | Single ingress for Flutter + workers: JWT validation, rate limits, idempotency, backpressure, public OpenAPI contract |
| [market/](market/) | `EtharaOrion/yantra-market` | Task marketplace: batches, work units, contended claims, rate cards, contract types |
| [quality/](quality/) | `EtharaOrion/yantra-quality` | Review pipelines, reviewer hierarchy, calibration, seeded evals, LLM-as-judge, trust scores, disputes |
| [assess/](assess/) | `EtharaOrion/yantra-assess` | AI interviews, structured assessments, code sandbox, anti-cheat, KYC/identity verification |
| [payout/](payout/) | `EtharaOrion/yantra-payout` | Earnings ledger, multi-rail disbursement (Stripe Connect/Wise/Razorpay), referral accruals, ledger reconciliation |
| [notify/](notify/) | `EtharaOrion/yantra-notify` | FCM push, email, SMS, WhatsApp (Meta Cloud API) — sole owner of messaging credentials |
| [tracker/](tracker/) | `EtharaOrion/yantra-tracker` | Time-tracker ingestion: activity samples, screenshots (S3), caps, anomaly detection |
| [analytics/](analytics/) | `EtharaOrion/yantra-analytics` | Debezium CDC read models, BI marts, executive dashboards |
| [odoo/](odoo/) | `EtharaOrion/yantra-odoo` | Odoo 19 CE + OCA aggregation + `ethara_*` addons — the system of record (see [MODULES.md](../MODULES.md)) |
