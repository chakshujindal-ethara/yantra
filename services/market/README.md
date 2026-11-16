---
type: Specification
title: Market Service
description: Task marketplace — work-unit fan-out, contended claims, rate cards, contract types.
tags: [marketplace, tasks, service]
status: draft
---

# market

The task marketplace — the highest-risk custom component (Odoo portal users cannot be task assignees; see ARCHITECTURE.md). Submodule: `EtharaOrion/yantra-market` (Phase 5).

**Responsibilities.** Batch → work-unit fan-out; claimable unit listing filtered by worker skills/certifications/trust tier; contended claim serialization (`SELECT … FOR UPDATE SKIP LOCKED`, idempotency-key unique constraint, claim deadlines with auto-release); rate cards tiered by geography × domain × credential with per-unit pay disclosure before acceptance; hourly and deliverable contract types; client console (batch funding, progress, Expert-Match-style worker invites); work-unit state machine (DESIGN.md §6.1).

**Owns.** `worker_profile` (partner_ref → Odoo), `work_batch`, `work_unit`, `claim`, `rate_card`/`rate_tier`, `cert_gate` (DESIGN.md §5.2).

**Emits.** `work.units` topic (published/claimed/submitted/completed/rejected). **Consumes.** `worker.lifecycle` (eligibility/suspension), `quality.verdicts` (completion, trust gates).

**SLOs.** Zero double-claims under 20K-concurrent storm; p99 claim latency budget set at Phase 5 load test; completion events exactly-once into the payments pipeline.
