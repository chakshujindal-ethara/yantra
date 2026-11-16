---
type: Changelog
title: Changelog
description: Chronological history of changes to the Yantra knowledge bundle and platform specifications.
tags: [changelog, history]
status: stable
---

# Changelog

All notable changes to the Yantra knowledge bundle are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) conventions adapted to an OKF knowledge repository; entries are grouped by date, newest first.

## 2026-09-10

### Added

* Established the Yantra OKF v0.2 knowledge bundle at repository root.
* [README.md](README.md) — platform overview, core decisions (Odoo 19 CE only, Flutter frontend, microservices, Crunchy PGO), repository layout, and bundle index.
* [ARCHITECTURE.md](ARCHITECTURE.md) — hub-and-spoke topology, service catalog, integration patterns, identity/security model, in-house build register, scale posture.
* [MODULES.md](MODULES.md) — exhaustive Odoo 19 CE module matrix, OCA substitutions for all Enterprise gaps, and the ethara_* addon suite (verified against odoo/odoo 19.0 and OCA 19.0 branches on 2026-09-10).
* [REQUIREMENTS.md](REQUIREMENTS.md) — capability union of Mercor, Scale AI (Outlier/Remotasks), Multimango (TELUS Digital), and Handshake/Handshake AI, mapped to Yantra components.
* [INFRASTRUCTURE.md](INFRASTRUCTURE.md) — Crunchy PGO configuration (incl. Percona-fork licensing posture and the pgBouncer/queue_job pooling trap), Odoo Kubernetes deployment roles, capacity model for 20K onsite + 200K online users.
* [ROADMAP.md](ROADMAP.md) — six delivery phases with verification gates, standing workstreams, and open decisions.
* [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md), [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md) — open-source community standards.

### Added (data model)

* [DATAMODEL.md](DATAMODEL.md) — implementation-grade ER specification: full schemas for market, quality, assess, payout, notify, tracker, gateway, and analytics stores (typed columns, CHECK enumerations, partial unique indexes, partitioning and retention, roles/grants) plus field-level specs for the `ethara_*` Odoo models and the cross-store reference map. DESIGN.md section 5 downgraded to orientation.

### Infrastructure

* Created and seeded eleven git submodule repositories under EtharaOrion (`yantra-app`, `yantra-gateway`, `yantra-market`, `yantra-quality`, `yantra-assess`, `yantra-payout`, `yantra-notify`, `yantra-tracker`, `yantra-analytics`, `yantra-odoo`, `yantra-deployment`), each carrying its specification README; wired all eleven into the hub via relative-URL submodules (`.gitmodules`).
* Added `.github/CODEOWNERS` (teams-only, placeholder slugs) and `images/hero.svg` placeholder hero art pending human mascot election.

### Changed

* README rebuilt as the public showcase per the ENGRAM contract register (../trinity): centered hero block (mascot election pending), abstract, worked hard-problem example, contributions, related-work matrix, canonical evidence-status section, threat model, reproduction, conversion sections; ASCII-only bytes enforced.
* CNCF Cloud Native Trail Map alignment added to [INFRASTRUCTURE.md](INFRASTRUCTURE.md) with per-step project choices and enforcement points; [deployment/](deployment/) spec remapped to CNCF tooling (Argo CD, Harbor, Cilium, Kyverno, Falco, cert-manager, sigstore, OpenTelemetry, Envoy Gateway, CoreDNS).
* Event bus ratified: NATS JetStream with CloudEvents envelopes (CNCF); Kafka-via-Strimzi documented as fallback. Ingress standardized on Envoy Gateway (WebSocket-aware).
* [DESIGN.md](DESIGN.md) added: C4 context/container HLD, ER diagrams for all data stores, service-layer sequence flows, event topology, state machines, deployment view.
* Structure: `service/` renamed to `services/`; `deployment/` (DevSecOps) added; specifications authored for `app/`, all nine services, and deployment — each maps to a planned git submodule under EtharaOrion.
* OCA rest-framework (`fastapi`) removed from the module plan in favor of native `@http.route` controllers + `auth_jwt` + JSON-2, since the external gateway owns the public REST contract.
* Version and license compliance section added to [MODULES.md](MODULES.md): Odoo 19.0 verification methodology, OEEL-1 exclusion, LGPL-3/AGPL-3 obligations for `ethara_*` addons.
* Bundle index subsumed into [README.md](README.md), then relocated to `data/` as OKF reserved files (`data/index.md`, `data/log.md`); root concept docs remain the human-readable artifacts.
