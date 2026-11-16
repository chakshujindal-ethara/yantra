# deployment

How Yantra runs outside a laptop, and the local rig it is proven on.

| Path | What |
|---|---|
| `local/` | the whole Stage 1 rig on one machine: `compose.yaml` (infrastructure, Keycloak with the realm in `keycloak/`, migrations, the Python processes, the app, Odoo). See `docs/USING.md` |
| `helm/yantra/` | one chart for every environment: gateway, work and money (API and events processes), two migration hook Jobs, the app, NetworkPolicies, Ingress, HPAs and PDBs, ServiceMonitors, ExternalSecrets, optional Odoo. `values-local.yaml` (kind), `values-staging.yaml`, `values-prod.yaml` |
| `argocd/` | `project.yaml` (the `yantra` AppProject with the Friday pay-window freeze on prod), `root.yaml` (app of apps), `apps/staging.yaml` (auto-sync from main), `apps/prod.yaml` (manual sync) |
| `policies/` | Kyverno `verify-images.yaml`: only images signed keylessly by this repository's CI on main run in the Yantra namespaces |
| `kind/` | the kind cluster and its stand-in infrastructure (Postgres, Redis, NATS, Keycloak) for `scripts/kind-up.sh` |
| `scripts/` | `helm-check.sh` (lint, render, validate, promtool on the alerts; CI runs it), `container-smoke.sh` (the images run read-only as the chart runs them; CI runs it), `kind-up.sh` / `kind-down.sh` (install the chart on kind and run `yantra smoke`), `backup.sh` / `restore.sh` (the rig's backup and restore drill) |
| `observability/` | `prometheus.yaml` (the rig's scrape targets), `alerts.yaml` (every alert rule, each naming its runbook), `grafana/` (provisioning and the overview dashboard). Locally: `local/compose.observability.yaml` |
| `sql/` | `roles.sql`: one least-privilege Postgres role per deployable (`yantra_work`, `yantra_money`); migrations run as the owner `yantra` |
| `RUNBOOKS.md` | what to do when claims stick, a pay window stalls, a webhook or the rail fails, NATS backs up, dead letters appear; connection headroom; the restore drill; deploy freezes |
| `SLO.md` | the Stage 1 service levels, how each is measured, the error-budget rule |

## Environments

| | local (compose) | kind | staging | prod |
|---|---|---|---|---|
| Manifests | `local/compose.yaml` | chart + `values-local.yaml` | chart + `values-staging.yaml` | chart + `values-prod.yaml` |
| Images | built on the machine | built and `kind load`ed | GHCR, by digest, written by the promotion PR | GHCR, by digest, copied from staging by hand |
| Secrets | in the compose file (local only) | plain Secrets from values (local only) | External Secrets from the store | External Secrets from the store |
| Deploy | `docker compose up -d --build` | `scripts/kind-up.sh` | Argo CD auto-sync on merge | Argo CD manual sync, outside the freeze |

The chart refuses to render plain Secrets for any `env` but `local`, refuses an image without a digest or tag,
a gateway without a Keycloak issuer, and, outside `local`, an app without `app.keycloakOrigin` or a release without
`config.FORWARDED_ALLOW_IPS`. Only `/v1` and `/health` of the gateway are routed by the Ingress (bodies up to
`ingress.apiBodySize`, 10m); `/ready` and `/metrics` stay inside the cluster. The files host has its own Ingress
(`ingress.filesBodySize`, 600m, request buffering off) for presigned uploads. With an HPA on, a Deployment renders no
`replicas`, so Argo CD never undoes a scale. Prometheus reaches work, money and the events processes only from pods
matching `monitoring.prometheusSelector` in the monitoring namespace; a NetworkPolicy cannot narrow that to the
`/metrics` path (it shares the HTTP port), so keep the selector tight.

## What the owner provisions

Nothing below can be created or verified from this repository without cloud credentials.

| Item | What to do | Where the chart picks it up |
|---|---|---|
| Namespaces | `yantra-staging`, `yantra-prod` (Argo CD creates them with `pod-security.kubernetes.io/enforce=restricted`) | `argocd/apps/*.yaml` |
| Ingress and TLS | an ingress controller (class `nginx` by default) and a cert-manager `ClusterIssuer` | `ingress.className`, `ingress.clusterIssuer`; `config.FORWARDED_ALLOW_IPS` = the controller's pod CIDR (required: the chart will not render staging or prod without it) |
| Postgres | managed, HA, point-in-time recovery with 14 days of WAL (recovery point 15 minutes); databases `yantra`, `keycloak`, `odoo`; the owner role `yantra` for migrations, then `sql/roles.sql` run once as that owner, then passwords for `yantra_work` and `yantra_money` | secrets `database-url-migrate`, `database-url-work`, `database-url-money` |
| Redis | managed, for the gateway's rate limit and idempotency store | secret `redis-url` |
| NATS JetStream | three nodes, file storage | `config.YANTRA_NATS_URL` |
| Object storage | MinIO (the MinIO operator in prod; the chart's single-node `minio.enabled` for staging and kind), one bucket per environment, versioning off (erasure deletes by key), server-side encryption on, CORS for the app origin | `config.YANTRA_S3_*`, secrets `s3-access-key`, `s3-secret-key` |
| Keycloak | the realm imported, SMTP set, the `yantra-odoo` client secret copied into the store | `python.gateway.env.YANTRA_GATEWAY_KEYCLOAK_ISSUER`, `app.keycloakOrigin`, secret `keycloak-odoo-client-secret` |
| External Secrets | the operator and a `ClusterSecretStore` named `yantra-secrets`; keys under `yantra/<env>/<key>` | `secrets.storeRef`, `secrets.remotePrefix` |
| Application secrets | `pii-key`, `audit-key` and `bank-key` (32+ random bytes each; `pii-key` and `bank-key` kept forever: changing them orphans stored digests and sealed account numbers; only money pods get `bank-key`), `sentry-dsn`, the three `razorpayx-*` keys | `secrets.keys` |
| RazorpayX | business account (prod), test mode (staging), the webhook pointing at `https://api.<domain>/v1/payout/webhooks/razorpayx` | `config.YANTRA_RAZORPAYX_ACCOUNT_NUMBER`; prod refuses to boot without it |
| Argo CD | `kubectl apply -f deployment/argocd/project.yaml -f deployment/argocd/root.yaml`; repository credentials | — |
| Kyverno | installed; `kubectl apply -f deployment/policies/verify-images.yaml` | — |
| GHCR and CI | package permissions for the repository; repository variables `STAGING_GATEWAY_URL`, `STAGING_KEYCLOAK_URL` | `.github/workflows/ci.yaml` |
| Observability | Prometheus Operator (for ServiceMonitors; its pods labelled to match `monitoring.prometheusSelector`) loading `observability/alerts.yaml` as a `PrometheusRule`, Grafana with `observability/grafana/dashboards/overview.json` imported, a log store reading the pods' JSON stdout, an OTLP collector, a Sentry project | `monitoring.serviceMonitor`, `config.OTEL_EXPORTER_OTLP_ENDPOINT`, secret `sentry-dsn` |
| Drills | the monthly restore into staging; quarterly secret rotation | `RUNBOOKS.md` |

## Backup and restore drill

`scripts/backup.sh` dumps the Postgres roles and the `yantra`, `keycloak` and `odoo` databases (custom format),
the NATS `YANTRA` stream, the MinIO data (`minio.tar.gz`: unit media, documents, deliverables) and the Odoo
filestore (`odoo-filestore.tar.gz`) into `backups/<timestamp>/` (gitignored). `scripts/restore.sh <dir>` stops
every writer and MinIO, recreates each database from its dump, restores the stream and both volumes, starts the rig
and runs `yantra smoke`. MinIO is archived while it runs: stop the writers first for an exact copy.
Measured on the compose rig:

| Date (IST) | Step | Took | Result |
|---|---|---|---|
| 4 Nov 2026 17:44 | `backup.sh` (roles, `yantra` 108 KB, `keycloak` 216 KB, `odoo` 3.5 MB, NATS stream 12 KB) | 2.8 s | complete |
| 4 Nov 2026 17:46 | `yantra.dump` restored into a scratch database `yantra_drill` beside the live one | 1 s | row counts equal in all five checked tables (`market.work_unit` 22, `payout.earning` 14, `talent.listing` 4, `quality.review_task` 8, `notify.notification` 16); scratch database dropped |
| 5 Nov 2026 12:48 | `backup.sh` with the two volumes (roles, `yantra` 4.8 MB, `keycloak` 224 KB, `odoo` 3.4 MB, NATS 1.2 MB, MinIO 28 KB with the bucket's objects, Odoo filestore 832 KB) | 4 s | complete; archives list the bucket's unit media and the filestore |
| not yet run | full `restore.sh` on the rig (stop writers, recreate databases, restore the stream, `yantra smoke`) | — | deferred: the shared rig was mid-rebuild by another lane; run it once the rebuilt rig is healthy and record the time here |

On the rig the recovery point is the time since the last `backup.sh`; deployed environments get 15 minutes or
better from managed Postgres point-in-time recovery, which is the owner's to enable and drill monthly.
