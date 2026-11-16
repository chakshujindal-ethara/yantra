---
type: Reference
title: Infrastructure and Deployment Topology
description: Kubernetes deployment design for Yantra — Crunchy Postgres Operator configuration, Odoo deployment roles, pooling, session/filestore externalization, capacity math, and scaling caveats for 20K onsite + 200K online users.
tags: [kubernetes, postgresql, crunchy, pgo, pgbouncer, scaling, devops]
status: draft
sources:
  - id: pgo
    resource: https://github.com/CrunchyData/postgres-operator
    title: Crunchy Postgres Operator (Apache-2.0)
  - id: pgo-pgbouncer
    resource: https://github.com/CrunchyData/postgres-operator/blob/main/internal/pgbouncer/config.md
    title: PGO pgBouncer defaults (pool_mode session)
  - id: percona-fork
    resource: https://docs.percona.com/percona-operator-for-postgresql/3.0.0/ReleaseNotes/Kubernetes-Operator-for-PostgreSQL-RN3.0.0.html
    title: Percona Operator for PostgreSQL 3.0.0 (hard fork of PGO)
  - id: queue-runner
    resource: https://github.com/OCA/queue/blob/b43b0454c0eb3d484c112e2a7af82b11a52d01d1/queue_job/jobrunner/runner.py
    title: queue_job jobrunner LISTEN/NOTIFY source
  - id: web-health
    resource: https://github.com/odoo/odoo/blob/18.0/addons/web/controllers/home.py
    title: Odoo /web/health controller
  - id: odoo-deploy
    resource: https://github.com/odoo/documentation/blob/19.0/content/administration/on_premise/deploy.rst
    title: Odoo production deployment guide (worker/RAM formulas)
---

# PostgreSQL: Crunchy Postgres Operator

Yantra runs PostgreSQL 17 on Kubernetes under the Crunchy Postgres Operator (PGO v5 `PostgresCluster` CRD): Patroni-based HA baked into each database pod, automatic failover with `-primary`/`-replicas`/`-ha` Services, pgBackRest backups, and optional pgBouncer sidecar pooling.[^pgo]

**Licensing caveat (decision-gating).** PGO's operator code and CRDs are Apache-2.0 and genuinely open, but Crunchy's official container images sit behind an authenticated registry whose developer-program terms restrict production use for larger organizations. Percona hard-forked the operator in May 2026 (Percona Operator for PostgreSQL v3.0.0, own CRD API group, fully open images; identical Patroni/pgBackRest/pgBouncer underpinnings).[^percona-fork] Yantra's position: use the Crunchy CRDs/operator with self-built Postgres images (upstream `postgres` + Patroni + pgBackRest), and treat Percona's fork as a documented, low-risk migration path (pgBackRest restore or standby-cluster method) if licensing pressure materializes.

**Cluster shape.** `instances[].replicas: 3` (primary + 2 replicas) with pod anti-affinity/topology spread across zones; fast-SSD StorageClass with online volume expansion (verify expansion support before committing — historic PGO versions required cluster rebuilds); `spec.patroni.dynamicConfiguration` for `shared_buffers`/`work_mem`/`max_connections` tuning; `spec.monitoring` enabling pgMonitor (postgres_exporter + Grafana dashboards + alert rules). Backups: two pgBackRest repos — local PVC for fast restore plus S3 for offsite retention — with delta/incremental schedules and PITR; DR-region standup bootstraps a new cluster directly from the S3 repo.

**Pooling — the Odoo-specific trap.** PGO's bundled pgBouncer defaults to `pool_mode = session`; it must be explicitly overridden to `transaction` for Odoo's worker traffic.[^pgo-pgbouncer] But the OCA `queue_job` raw jobrunner opens a persistent `LISTEN queue_job` connection, which transaction pooling silently breaks (the server connection can be handed to another client between LISTEN and NOTIFY).[^queue-runner] Yantra resolves this by (a) using `queue_job_cron_jobrunner` (cron-dispatched jobs, no LISTEN/NOTIFY, no single-replica constraint) as the default, and (b) if the raw jobrunner is ever needed, routing it directly to the `-primary` Service, bypassing pgBouncer. Sizing invariant: `Odoo db_maxconn ≤ pgBouncer max_client_conn ≤ Postgres max_connections`; violating it produces connection-refusal storms under load.

# Odoo Deployment Roles

| Deployment | Flags | Notes |
|---|---|---|
| `odoo-web` | `--workers 4` per pod | Prefork HTTP workers. Small pods (2–4 workers, ~3 CPU) so HPA scales in fine increments; CPU-based HPA is a sane default signal |
| `odoo-websocket` | gevent process, port 8072 | Single gevent process per pod; `/websocket` ingress path with a WebSocket-aware Envoy-based ingress (Envoy Gateway/Contour) and session affinity; I/O-bound — do not HPA on CPU; do not share health-check config with `odoo-web` |
| `odoo-cron` | `--workers 0 --max-cron-threads N` | No ingress. Isolates scheduled jobs from request latency |
| `odoo-jobs` | `queue_job_cron_jobrunner` | Async job execution via ir.cron dispatch; sidesteps the raw jobrunner's single-replica LISTEN/NOTIFY constraint entirely |

**Statelessness prerequisites.** Sessions move from filesystem to Redis via the in-house `ethara_session_redis` override (no OCA-mature module exists; app-store Redis-session modules are of unverified provenance and are not acceptable for an HR system). Attachments move to S3-compatible object storage via OCA `fs_attachment`. Without both, web pods require sticky sessions and shared filesystems — unacceptable at this scale.

**Probes.** Odoo ships `/web/health` (auth=none): use the bare route for liveness (no DB dependency) and `/web/health?db_server_status=1` for readiness (opens a cursor, returns 500 on DB unreachability) — exactly the liveness/readiness split Kubernetes expects.[^web-health]

**Helm.** Bitnami's Odoo chart is not a safe base (catalog deprecated behind a paid subscription since late 2025; pinned tags disappearing). Reference IMIO/helm-odoo structurally, but Yantra writes first-party charts per service, consistent with the submodule-per-service layout.

**Module upgrades.** `odoo -u` takes exclusive schema locks; zero-downtime Odoo schema migration is not a solved OSS problem. Pattern: run `-u` as a one-shot Kubernetes Job against a maintenance-mode instance, then cut traffic (blue-green at the app level); budget maintenance windows for schema-altering releases and keep an expand/contract discipline for in-house addon migrations.

# Capacity Model

From Odoo's official formulas (`workers = 2×CPU + 1`; 1 worker ≈ 6 concurrent heavy users; `RAM ≈ workers × (0.8×150MB + 0.2×1GB)`):[^odoo-deploy]

| Population | Assumption | Result |
|---|---|---|
| 20,000 onsite employees | 5–10% concurrency, heavy ORM usage | 1,000–2,000 concurrent sessions → ~170–330 HTTP workers → 40–85 `odoo-web` pods (4 workers/pod) → ~50–100GB aggregate RAM for Odoo alone |
| 200,000 online workers | Never hit Odoo workers directly | All traffic terminates at `services/gateway` and service DBs; Odoo receives only queue-buffered, serialized writes. Portal-rendered surfaces (payslips, certificates) are low-frequency reads weighted ~0.5 |
| pgBouncer | Weighted-user sizing | `default_pool_size` from blended activity weights (~30% true concurrency factor), validated by load test |

Known failure modes designed against: Postgres row-lock contention on hot rows at 1000+ concurrent writers (hot state lives in service DBs; gateway retries with backoff on Odoo `LockError`); `bus.bus`/websocket fragility behind non-WebSocket-aware ingress; SMTP relay capacity for 20K-employee transactional mail (self-hosted CE has no cap, but the relay must be sized); mail/cron queue starvation (isolated into dedicated deployments). No public Odoo reference exists at this scale — every number above is a load-test hypothesis, not a guarantee.

# CNCF Trail Map Alignment

Yantra adopts the CNCF Cloud Native Trail Map as its compliance frame; every step names the chosen project, its CNCF status, and where enforcement lives. CNCF-graduated or incubating projects are preferred at every layer where one fits; the two deliberate exceptions are Crunchy PGO (Kubernetes-native but not CNCF, chosen for Patroni/pgBackRest maturity with the Percona fork as exit) and Flutter (client-side, outside CNCF scope).

| Trail map step | Choice | CNCF status | Notes / enforcement |
|---|---|---|---|
| 1. Containerization | OCI images on containerd; self-built Postgres images | containerd graduated | Digest-pinned, no `latest`; Kyverno-enforced ([deployment/](deployment/)) |
| 2. CI/CD | GitHub Actions build/test/scan + Argo CD GitOps delivery | Argo graduated | Per-submodule pipelines; hub repo pointer bumps drive environment promotion |
| 3. Orchestration + app definition | Kubernetes + first-party Helm charts | Kubernetes, Helm graduated | Charts per service and per Odoo deployment role |
| 4. Observability + analysis | Prometheus + Grafana, OpenTelemetry traces/metrics/logs, Jaeger, Fluent Bit, pgMonitor, Sentry | Prometheus, OpenTelemetry, Jaeger, Fluentd graduated | Alert rules include replication-slot lag, queue depth, claim-latency SLOs |
| 5. Service proxy, discovery, mesh | Envoy-based ingress (Envoy Gateway/Contour) with WebSocket-aware routing; CoreDNS; Linkerd optional for mTLS if service count grows | Envoy, CoreDNS, Linkerd graduated | Odoo `/websocket` path needs WS upgrade + affinity on the websocket Deployment only |
| 6. Networking, policy, security | Cilium CNI; default-deny NetworkPolicies; Kyverno policy-as-code; Falco runtime detection; cert-manager TLS; external-secrets | Cilium, Kyverno (incubating), Falco, cert-manager graduated/incubating | Policy gates: no OEEL artifacts, resource limits mandatory, ns isolation between odoo and services data planes |
| 7. Distributed database + storage | PostgreSQL via Crunchy PGO; CSI storage classes; S3-compatible object store | Not CNCF (deliberate exception) | Patroni HA, pgBackRest PITR; Percona operator fork documented as migration path |
| 8. Streaming + messaging | NATS JetStream with CloudEvents envelopes; Debezium CDC for analytics read models | NATS incubating, CloudEvents graduated | Ratified over Kafka for operational simplicity; Kafka-via-Strimzi documented as the alternative if event-volume profile demands it |
| 9. Container registry + runtime | Harbor registry with Trivy scanning; containerd runtime | Harbor, containerd graduated | Admission refuses unscanned or unsigned images |
| 10. Software distribution | sigstore/cosign signing, Syft SBOMs, SLSA provenance attestations | sigstore ecosystem | Every chart pins digests; attestations verified at admission |

Identity spans the map: Keycloak (CNCF incubating) is the single IdP for staff OIDC, worker JWTs, and service-to-service auth. Application-level practices complete the posture: 12-factor configuration, `/web/health` liveness/readiness splits, HPA with role-appropriate signals, immutable infrastructure, and GitOps as the only production write path.

# Platform Services Topology

Each `services/*` submodule ships its own container, chart, and database (database-per-service; PGO can host multiple `PostgresCluster` resources or one cluster with multiple databases per service risk profile). The event bus (NATS JetStream, CloudEvents envelopes; ratified per CNCF alignment) carries outbox events from Odoo and inter-service messages; Debezium CDC from the Odoo cluster feeds `services/analytics` read models only, with schema-history handling across Odoo module upgrades and replication-slot monitoring (a stalled slot on a multi-TB DB fills disk). Keycloak, Redis, and the object store (S3-compatible) are shared platform infrastructure. Observability: Prometheus + Grafana (pgMonitor for Postgres), Sentry via OCA `sentry` for Odoo, OpenTelemetry across services and gateway.

[^pgo]: Crunchy Postgres Operator (Apache-2.0)
[^pgo-pgbouncer]: PGO pgBouncer defaults (pool_mode session)
[^percona-fork]: Percona Operator for PostgreSQL 3.0.0 (hard fork of PGO)
[^queue-runner]: queue_job jobrunner LISTEN/NOTIFY source
[^web-health]: Odoo /web/health controller
[^odoo-deploy]: Odoo production deployment guide (worker/RAM formulas)
