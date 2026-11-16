---
type: Specification
title: Gateway Service
description: API gateway — the single ingress for Flutter and all 200K online workers.
tags: [gateway, api, service]
status: draft
---

# gateway

Single ingress for the Flutter app and all worker traffic. Submodule: `EtharaOrion/yantra-gateway` (Phase 0).

**Responsibilities.** Keycloak JWT validation (issuer/audience/expiry, key rotation); per-worker and per-endpoint rate limits; Idempotency-Key enforcement on every mutation (Redis dedup, Postgres unique-constraint fallback); retry-storm absorption and request coalescing; the public OpenAPI contract for Flutter (versioned, backward-compatible); routing to domain services; thin authenticated calls into Odoo (`ethara_api` native controllers via `auth_jwt`, JSON-2 for ORM reads) — never RPC pass-through.

**Owns.** Idempotency store, rate-limit counters, API contract versions. No domain data.

**Emits/consumes.** Emits nothing domain-level; consumes service health for load shedding.

**SLOs.** p99 added latency < 20ms; claim-storm survival (20K concurrent) with graceful backpressure (429 + Retry-After), zero duplicate mutations under retry flood.
