# Developing Yantra

One repository, a ring of services as code modules, four deployables in Stage 1 (gateway, work, money, odoo)
plus the worker app. This page is the "how do I run and test it" for engineers. Using the product as an
operator, worker, reviewer or finance is in [USING.md](USING.md); the plan and the design live in `docs/final-nov-2/`.

## Layout

| Path | What |
|---|---|
| `packages/py-common` | settings, database session with timeouts, transactional outbox, event bus (NATS JetStream), relay, idempotent consumers with dead letters, the leased job scheduler (`scheduler`), dead-letter and job routers (`deadletters`), housekeeping (`prune`), sealing secrets at rest (`crypto`, AES-256-GCM), the shared PII helpers (`pii`), the in-image migration runner (`migrate`), domain errors, rate limit, HTTP boundary, test support |
| `packages/contracts` | versioned event schemas (`yantra_contracts.events.v1`) |
| `services/market` | the work-unit engine: projects, batches, units with frozen pay and price, claims, submissions, what a worker may browse, the delivery manifest and its gate, the verdict log, client organisations and the client console; consumes verdicts (`needs_edits` hands the unit back to its author, `reject` to the pool), certifications, accepted offers and eligibility |
| `services/talent` | the bench's front door: listings a worker applies to, applications and offers, the onboarding checklist (profile, agreement, DPDP consent, PAN, bank, payout acknowledgement; the PAN stored as an HMAC under `YANTRA_PII_KEY` plus its last four, the account number as its last four alone), the `worker.eligible` event |
| `services/assess` | assessment papers, timed sittings, scoring, the certification that grants a gate (`assess.certified`) |
| `services/quality` | review claims (never own work), the reviewer's copy of payload and answer, verdicts with reason codes, the 10% audit sample, the rubric-unclear flag; emits the canonical verdict |
| `services/payout` | earnings on the canonical accept, the Saturday-to-Friday IST pay window (closed by a job on Saturday 00:05 IST), holds (integrity, bank change, no verified account, first payout, over the per-worker cap), two finance approvals, the worker's bank account (sealed, verified by the rail's penny drop: `accounts.py`), paying a window line by line on a rail (`paying.py`; `rails/` holds RazorpayX, the bank file and a test fake), the RazorpayX webhook, reconciliation runs, the statement export, the margin report |
| `services/notify` | the worker's inbox, fed by verdict, payout, offer and adjustment events; an optional email channel delivered through SMTP after the event is stored; support tickets |
| `services/tracker` | activity sessions while a claim is open (30-second samples keyed by bucket, so a batch counts once), weekly hour caps, the anomaly detectors and flags an operator decides (an upheld one holds payouts), screenshot references for a future desktop agent, the live-claim read model; settings `YANTRA_TRACKER_*` |
| `services/analytics` | the event warehouse fed by one wildcard durable (`analytics-all-g<n>`), two small dimensions, marts recomputed from the warehouse (`marts.py`), the leadership numbers (`leadership.py`), the rebuild drill (`rebuild.py`, run by the events process) |
| `services/gateway` | Keycloak JWT validation, the shared rate limit and idempotency store in Redis, CORS for the app, routing to `work` and `money` |
| `services/odoo` | the Odoo 19 addon `yantra_bridge` (worker record, consent, eligibility push, vendor bills with TDS from paid windows, client invoice from the manifest) and its image |
| `deployables/work` | the `work` process: market, talent, assess, quality, notify, tracker and analytics on their own schemas; `yantra_work.events` relays their outboxes, runs their consumers and their jobs (expiries, email, housekeeping, the dead-letter alert) |
| `deployables/money` | the `money` process: payout alone, its own release train; `yantra_money.events` likewise |
| `app` | the one Flutter app (web, Android, iOS) for workers, operators and clients: Keycloak sign-in (redirect with PKCE, or the password form where the realm allows it); the shell picks destinations from the token's realm roles. Worker: home, explore and apply, applications and offers, onboarding, assessments, work, my work, review, earnings, inbox, profile. Ops: overview, projects and batches, listings, papers, workers, quality, finance, support. Client: overview, projects, deliveries. Ethara portal design tokens, light and dark; `docs/PRODUCT.md` is the contract |
| `tools/yantra-cli` | `yantra`: the command line for the rig, the `yantra smoke` end-to-end proof and `yantra seed` (a demo world for the screens) |
| `tools/claim-storm` | the load harness that gates the market step |
| `deployment/local` | `compose.yaml`: the whole rig; the Keycloak realm |

Each Python module owns one schema with its own Alembic migrations, an `outbox` table when it emits events, a
`consumed_event` table and a `dead_event` table (a message that failed every redelivery, or could not be decoded, lands there with the reason).
A module imports only `packages/*` and its own code. Events go through the module's outbox and NATS even when the
consumer runs in the same process; consumers are idempotent on the event id.

## Run the whole rig

```bash
services/assess-app/build.sh      # once, and after a change to the exam app: builds its bundle into dist/ (not in git)
docker compose -f deployment/local/compose.yaml up -d --build
```

One image (`Dockerfile`) serves every Python process; `app/Dockerfile` builds the Flutter web bundle; `services/odoo/Dockerfile` adds the addon to Odoo 19. `migrate` runs every module's migrations before the services start (`python -m yantra_common.migrate`, the same runner the Helm hook uses); `odoo-init` installs the addon and seeds the rig's settings once. Ports, users and URLs are in [USING.md](USING.md).

The work and money APIs trust the gateway's identity headers, so the base compose file publishes no host port for
them: only the gateway reaches them. Tools that must call them directly (the claim-storm harness) add the
development overlay, `-f deployment/local/compose.dev.yaml`, which publishes 8081 and 8082 on 127.0.0.1. The events
processes keep their host ports (8085, 8086): they serve health, readiness and metrics, never data. The gateway,
work and money containers report healthy only once `/ready` answers, and the gateway starts after both services.

### Database roles

Each deployable connects as its own Postgres role (`deployment/sql/roles.sql`): `yantra_work` reads and writes
market, talent, assess, quality, notify, tracker and analytics; `yantra_money` reads and writes payout; neither can
read the other's schemas or create objects. `yantra` owns every schema and is used only by migrations. On the rig
`deployment/local/postgres-init/20-roles.sh` creates the roles on a fresh volume with local passwords, so after
pulling this change run `down -v` once. On a managed database the owner runs `roles.sql` and sets the passwords from
the secret store; the chart's `database-url-work`, `database-url-money` and `database-url-migrate` secrets carry the
three URLs. Promoting a module to its own deployable means a new role and a new line in that file.

## Run the Python side on the host (fast iteration)

```bash
docker compose -f deployment/local/compose.yaml up -d postgres redis nats nats-test mailpit keycloak
uv sync --all-packages
export YANTRA_DATABASE_URL=postgresql+psycopg://yantra:yantra@localhost:5440/yantra
YANTRA_SERVICES_ROOT=services uv run python -m yantra_common.migrate
uv run uvicorn --factory yantra_work.app:default_app --port 8081 --reload    # market + talent + assess + quality + notify API
uv run uvicorn --factory yantra_money.app:default_app --port 8082 --reload   # payout API
YANTRA_SMTP_HOST=localhost YANTRA_SMTP_PORT=1026 uv run python -m yantra_work.events   # relays, consumers, jobs; /ready on :8085
YANTRA_EVENTS_PORT=8086 uv run python -m yantra_money.events
export YANTRA_GATEWAY_KEYCLOAK_ISSUER=http://localhost:8180/realms/yantra
export YANTRA_GATEWAY_ALLOWED_ORIGINS='["http://localhost:8095"]'
uv run uvicorn --factory yantra_gateway.app:default_app --port 8090
```

Settings use the `YANTRA_` prefix (`DATABASE_URL` required; `NATS_URL`, `RATE_LIMIT_PER_MINUTE`, `MAX_BODY_BYTES`,
`SMTP_HOST` (unset: no email leaves), `SMTP_PORT`, `MAIL_FROM`, `EVENTS_PORT` (the events process's `/health` and `/ready`, 8085; money runs on 8086), `SCHEDULER_CONCURRENCY` (jobs running at once per process, 2), `DB_POOL_SIZE` (10), `DB_MAX_OVERFLOW` (10) and `DB_POOL_TIMEOUT` (seconds a request waits for a connection, 10) have defaults (size the pool so that `processes x (DB_POOL_SIZE + DB_MAX_OVERFLOW) + reserve <= max_connections`: 4 x 20 + 20 = 100 for a deployed Postgres at its default; the rig's Postgres runs with `max_connections=300` because Keycloak, Odoo and every test session's per-module pools share it); `BANK_KEY` is the AES-256-GCM key that seals bank account numbers, written `<id>:<base64 of 32 bytes>` and checked at boot, with `BANK_KEY_PREVIOUS` holding the old key while values sealed under it are re-sealed (its default is for a developer's machine only, like the PII key; only the money processes hold it: with `REQUIRES_BANK_KEY=true`, set on them alone, a deployed one refuses to boot on the rig's key, and any deployed process that seals or opens a value without its own key is refused there); `AUDIT_KEY` keys the HMAC that picks the 10% audit sample from a unit id (its default is for the rig only: a deployed work events process refuses to boot on it or on one under 32 characters; changing it re-samples only tasks opened afterwards); `ASSESS_ENGINE` (`v2` or `fake`), `ASSESS_ODOO_URL`, `ASSESS_APP_URL`, `ASSESS_RETURN_URL`, `ASSESS_KEYCLOAK_TOKEN_URL`, `ASSESS_CLIENT_ID`, `ASSESS_CLIENT_SECRET`, `ASSESS_TIMEOUT_SECONDS` (10) and `ASSESS_SYNC_SECONDS` (15) point the assess module at Assessment v2 (see `services/assess/README.md`; `v2` needs the client secret, `fake` and the rig's secret are refused outside `local`); `OUTBOX_STUCK_SECONDS` (300) is how old an events process's oldest unpublished outbox row may get, with the backlog not shrinking between two probes, before its `/ready` turns 503; `PII_KEY` is the HMAC key under which
talent hashes a PAN and a legal name: it defaults to `local-dev-pii-key-change-me`, which is for a developer's
machine only, so every deployed environment sets its own secret and keeps it, since changing it orphans every
stored digest) and `YANTRA_GATEWAY_` for the gateway
(`KEYCLOAK_ISSUER` required; `KEYCLOAK_JWKS_URL` when the keys are fetched from an internal address, `AUDIENCE`,
`REDIS_URL`, `WORK_URL`, `MONEY_URL`, `RATE_LIMIT_PER_MINUTE`, `ALLOWED_ORIGINS` as a JSON list). The CLI reads
`YANTRA_GATEWAY_URL`, `YANTRA_KEYCLOAK_URL` and `YANTRA_SESSION_FILE`.

## Test

```bash
uv run pytest                     # every Python package; database tests run against fresh, migrated databases
uv run ruff check . && uv run ruff format --check . && uv run mypy   # mypy's paths: [tool.mypy] files in pyproject.toml
uv run pytest --cov --cov-report=term-missing   # the measured packages and the 97% floor are in pyproject.toml
(cd app && flutter analyze && flutter test)                                   # the worker app
docker compose -f services/odoo/compose.test.yaml up -d && \
  docker compose -f services/odoo/compose.test.yaml run --rm odoo odoo -d yantra_odoo_test -i yantra_bridge \
  --test-enable --test-tags=/yantra_bridge --stop-after-init; docker compose -f services/odoo/compose.test.yaml down -v
```

The Python tests need the rig's Postgres (5440), Redis (6390), Mailpit (1026/8026) and the **test** NATS on 4223:
the loop tests recreate the `YANTRA` stream, so they must never run against the rig's own NATS on 4222.
`services/odoo` is excluded from pytest; its tests run inside Odoo as above. Every test has a 15-minute deadline (`pytest-timeout`,
`timeout` in `pyproject.toml`) and the NATS loop scenarios a 10-minute one, so a stalled bus fails with the stacks
instead of hanging the run; parallel runs on one Postgres set `YANTRA_TEST_DB_SUFFIX`.

The end-to-end proof against the running rig: `uv run yantra smoke` (see USING.md).

## Observability

- **Metrics.** Every API process (gateway, work, money) serves `/metrics`: one histogram,
  `yantra_http_request_duration_seconds{process,method,route,status}`, labelled by route template (the gateway
  normalises its catch-all path: ids become `{id}`, unrouted 401/404 answers are `other`). Each events process serves
  `/metrics` on 8085/8086: a probe reads, at most every 15 s, the outbox backlog and age, dead letters, overdue jobs,
  and the deployable's invariants (units with two live claims, the oldest waiting review, pay-window lines by status,
  the last close, the latest reconciliation delta per window); the consumers count messages by outcome and their lag,
  the scheduler times every job, and the RazorpayX adapter counts its calls. All names live in
  `yantra_common/metrics.py`.
- **Alerts and dashboard.** `deployment/observability/alerts.yaml` holds the rules (each names its runbook section);
  `deployment/observability/grafana/dashboards/overview.json` is the one overview dashboard. Locally:
  `docker compose -f deployment/local/compose.yaml -f deployment/local/compose.observability.yaml up -d` adds
  Prometheus (http://localhost:9090) and Grafana (http://localhost:3000, anonymous viewer). Check rules after an edit:
  `docker run --rm -v "$PWD/deployment/observability:/obs:ro" --entrypoint promtool prom/prometheus:v2.55.1 check rules /obs/alerts.yaml`.
- **Logs.** `LOG_FORMAT=json` prints one JSON object per line (`ts`, `level`, `logger`, `msg`, `request_id` and any
  extra fields); `text` (the default) keeps key=value lines. Each process writes one access line per request
  (`yantra.access`: method, path, status, duration, the caller's subject id; never a query string or a body), so
  uvicorn runs with `--no-access-log`. The chart sets `json`; the rig keeps `text`.
- **Traces.** Off unless `OTEL_EXPORTER_OTLP_ENDPOINT` is set: then FastAPI, SQLAlchemy and the gateway's httpx
  clients emit spans over OTLP/HTTP (`OTEL_TRACES_SAMPLER` and friends apply). Health, readiness and metrics requests
  are not traced.
- **Errors.** Off unless `SENTRY_DSN` is set. Sentry gets `YANTRA_ENV` and `YANTRA_RELEASE` (the chart sets the image
  digest), never personal data: no request bodies, cookies, query strings, auth or name headers, no user block.

## The claim-storm gate

With the work service running on the host (raise the limiter for the harness), or in the rig with
`-f deployment/local/compose.dev.yaml` so 8081 is published:

```bash
YANTRA_RATE_LIMIT_PER_MINUTE=1000000 uv run uvicorn --factory yantra_work.app:default_app --port 8081 --workers 4
uv run python -m claim_storm --workers 500 --units 2000 --p99-ms 500
```

It passes only with every unit claimed once, zero double claims, p99 under the target and no errors.

## Identity

Only the gateway sees tokens. The services trust the headers the gateway sets: `X-Worker-Id` (the token's
`sub`), `X-Role` (the caller's realm roles, comma-separated in the order `admin,ops,finance,reviewer,client,worker`,
always sent and empty when the token holds none; Keycloak's own roles and the `mfa-required` marker are dropped),
`X-Name` (the token's `name` or `preferred_username`, percent-encoded; `yantra_common.people.Name` decodes it), and
`Idempotency-Key` (required by the gateway on every mutation, scoped to the caller, method and path, bound to a
sha256 of the body so a reused key with another body is 422 `idempotency_mismatch`, replayed from its store within
48 hours). `yantra_common.deps.require_any`
builds every guard (`Ops`, `Finance`, `FinanceOrOps`, `Reviewer`, `Admin`, `AdminOrOps`, `ClientRole`, `Worker`);
`docs/PRODUCT.md` §3 has the route table. Six realm roles exist: `worker`, `reviewer` (claims review and audit
tasks; a reviewer also holds `worker`, for pay), `ops`, `finance` (closes, approves and pays windows, decides
adjustments), `admin` (dead letters and jobs; implies neither `ops` nor `finance`) and `client` (a lab or vendor;
sees only the projects of the organisations it is a member of). A pay-window approval is recorded against the
caller's worker id, so two approvals are two `finance` people. Odoo calls the gateway as a service account (client
`yantra-odoo`, client-credentials grant, realm role `ops`), which keeps every read it needs. `work` and `money`
must never be reachable except through the gateway; in the local rig their ports are published only for the test
harnesses.

The realm is one production-shaped base, `deployment/keycloak/yantra-realm.json` (TLS required, 15-minute access
tokens and 24-hour sessions, no offline scope, brute-force detection, a password policy, self-registration with email
verification making a `worker`, the app client with PKCE and no password or device grant, refresh tokens that rotate
and are single use (`revokeRefreshToken`, `refreshTokenMaxReuse: 0`), the Odoo client
without a secret, and the `browser-mfa` flow: a conditional OTP form forced on the internal `mfa-required` role that
`ops`, `finance` and `admin` compose), plus one overlay per environment in `deployment/keycloak/overlays/`.
`uv run yantra realm-render` writes base + `local.json` to `deployment/local/keycloak/yantra-realm.json`, the file the
rig imports; CI runs `yantra realm-render --check`, so edit the base or the overlay, never the generated file. The
local overlay keeps fixed user ids, the password grant for the CLI and the app's direct login (through
`direct-grant-password`, a username-and-password-only flow, so a staff member who has enrolled OTP in the browser can
still run `yantra smoke`), the device grant on the app client for `yantra login --device`, Mailpit as SMTP and a plain
Odoo secret. `staging.json` adds a confidential `yantra-smoke` client (secret from the vault) for the CI smoke run;
`direct-grant-password` is bound to that client alone (its flow override, never the realm default) and admits only
holders of the staging-only `smoke` role, so a real staff member's password never skips their OTP through it. A realm change reaches the rig only on a fresh Keycloak database
(import runs once): `docker compose -f deployment/local/compose.yaml rm -sf keycloak`, drop and recreate the `keycloak`
database, `up -d keycloak`. To see the OTP enrolment, sign in to the app through **Continue with Keycloak** as `ops1`
or `admin1`: Keycloak shows "Configure OTP"; `worker1` goes straight through. `yantra login --device` signs the CLI in
on the rig through the browser instead of the password grant: it prints a URL and a code, and polls (RFC 8628 with PKCE) until the person approves
it in a browser, OTP included.

`YANTRA_ENV` (`local`, `staging`, `prod`; default `local`) turns on the deployed-environment guards: `settings()`
refuses to boot on a key or password this repository publishes (the PII key, the rig's bank keys on a money process, a
database password of `yantra`, `yantra_work` or `yantra_money`, the rig's MinIO and RazorpayX credentials in
`YANTRA_S3_*` and `YANTRA_RAZORPAYX_*`) and names the setting, never the value; the migrations read only
`YANTRA_DATABASE_URL` and run no such guard (the hook Job holds the owner's URL and nothing else); the gateway refuses `YANTRA_GATEWAY_ALLOW_INSECURE_JWKS` and
adds HSTS. Every JSON answer carries `nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`,
`Cache-Control: no-store` and a `default-src 'none'` CSP (`install_security_headers`); the gateway's `/ready` is 503
until Redis answers and the identity provider's keys have been fetched. The gateway's per-address limit keys on the TCP
peer, never on `X-Forwarded-For`: behind a load balancer set uvicorn's `FORWARDED_ALLOW_IPS` to the proxies'
addresses (comma-separated, CIDRs allowed) so the peer is the real client (the chart refuses to render staging or prod
without it). The app already speaks both grants: **Continue with
Keycloak** runs the authorization-code flow with PKCE (`lib/auth/pkce.dart`, `lib/auth/session.dart`; the verifier
waits in per-tab storage, the code is exchanged at the token endpoint, the URL is cleaned), and the password form is
shown only when the build sets `DIRECT_LOGIN=true` (the rig's compose does; a build that says nothing offers the redirect alone). Sign-out also
ends the Keycloak session through the logout endpoint, so the next redirect asks for credentials again.

## Personal data

What talent keeps and why, under the Digital Personal Data Protection Act, 2023 (DPDP):

| Data | Where | Kept as | Why |
|---|---|---|---|
| Legal name, phone, city | `talent.onboarding` | plaintext | identity, contact, the payout name check |
| PAN | `talent.onboarding` | keyed HMAC + last four (`YANTRA_PII_KEY`) | one PAN per person, tax |
| Aadhaar | `talent.onboarding` | last four digits only | identity |
| Bank account | `payout.bank_account` | sealed with `YANTRA_BANK_KEY`, last four, IFSC | paying the worker |
| Account-name digest | `talent.onboarding` | keyed HMAC | the bank step's name check |
| Documents | object storage `workers/<id>/documents/<kind>/<uuid>`; key, sha256, size in `talent.worker_document` | the file | identity checks |
| Display name | `person` in talent, market, notify | plaintext | names on lists |
| Email | `notify.channel` | plaintext; used only once verified by a six-digit code mailed to it (the code is never stored: a keyed digest of a nonce, 15 minutes, five tries) | notifications |
| Ticket text | `notify.ticket` title, body, screen, context (≤ 50 keys, ≤ 16 KB) | plaintext | support |
| Activity samples, screenshots, device id | `tracker.activity_sample`, `tracker.screenshot_ref`, object storage `tracker/<worker>/…`, `tracker.activity_session.device_hash` | as sent (a non-web label as a keyed digest) | the weekly cap, integrity flags; purged after `YANTRA_TRACKER_RETENTION_DAYS` (30) |
| Event warehouse | `analytics.event` | minimised payload (allowlist per type: ids, amounts, statuses, codes, times; no names, answers, documents, bank details or free text) | the leadership numbers; deleted after `YANTRA_ANALYTICS_RETENTION_DAYS` (400) |
| Unit payloads, answers, unit media, deliverables | `market.work_unit`, `market.submission`, quality's copy, object storage `projects/<id>/…` | as sent | the work itself; purged `retention_days` (default 180) after delivery by `market_retention_purge` |

Consent is purpose-bound and versioned (`onboarding.consent_version` is the `dpdp-consent` version read); the worker
withdraws it from Profile (`PUT …/onboarding/consent {accepted: false}`): processing stops except what a legal duty
needs (payout of accepted earnings, tax records), and `worker.consent.withdrawn.v1` tells the other modules. Talent
takes the worker off the eligible list (`eligible_sent_at` cleared); tracker ends the open session and refuses
sessions, samples and screenshots (403 `consent_withdrawn`); market and payout block claims and payouts. Consent
given again emits `worker.consent.given.v1` and every block lifts (`worker.eligible.v1` goes out again once the
checklist is complete).

Erasure: the worker asks (`POST /v1/talent/workers/me/erasure`); it is due 30 days later or at once when ops approve.
The hourly `talent_erasure` job deletes every object under `workers/<id>/` (listed, so an upload never registered
goes too) and the document rows, blanks name, phone, city, Aadhaar last four, the account-name digest and every
application's answers, forgets the display name everywhere (`talent.person.seen.v1` with no name) and emits
`worker.erasure.completed.v1`: notify leaves one last inbox row, drops the email and blanks the worker's ticket
text; tracker deletes their samples and screenshot references, sets their device ids to `erased` and deletes every
object under `tracker/<worker>/` on the next hourly purge; analytics replaces their id with a random pseudonym in
every warehouse row and mart (counts stay whole); payout erases the bank account once every window holding the
worker is paid. Kept on purpose: ids everywhere, ledger amounts, the PAN digest and
last four, the agreement and consent records (tax and payment law; the consent itself is evidence). A worker with
documents waits while storage is unconfigured: an erasure that left the files behind is not done. Ops then offboard
the worker (`PUT /v1/workers/{id}` status `offboarded`) and disable the Keycloak user. Events and logs carry ids
only; backups age out on their own schedule.

## Paying (the rail)

Payout reads its own settings (`yantra_payout.config.PayoutSettings`, all `YANTRA_`):

| Setting | Default | Meaning |
|---|---|---|
| `RAIL` | `fake` | `razorpayx`, `file` or `fake` (tests). `razorpayx` without the next three fails the process at boot |
| `RAZORPAYX_KEY_ID`, `RAZORPAYX_KEY_SECRET`, `RAZORPAYX_ACCOUNT_NUMBER` | none | the API key pair and the business account payouts leave from |
| `RAZORPAYX_BASE_URL` | `https://api.razorpay.com/v1` | the rig points it at WireMock |
| `RAZORPAYX_WEBHOOK_SECRET` | none | unset: the webhook route answers 404 and the poll job settles lines |
| `RAZORPAYX_RATE_LIMIT_PER_MINUTE`, `RAZORPAYX_TIMEOUT_SECONDS`, `RAZORPAYX_PAYOUT_MODE` | 300, 10, `IMPS` | the client-side limiter, the per-call timeout (3 s to connect), NEFT or IMPS |
| `BANK_KEY`, `BANK_KEY_PREVIOUS` | a local key | `<id>:<base64 of 32 bytes>`; seals account numbers; the previous key keeps old values opening during a rotation |
| `PAYOUT_CURRENCIES` | `["INR"]` | the windows the Saturday job closes |
| `PAYOUT_MAX_PER_WINDOW`, `PAYOUT_MAX_PER_WORKER` | 5,000,000, 200,000 | a window over the first cannot be paid (409); a line over the second is held `over_cap` |
| `PAYOUT_POLL_AFTER_SECONDS`, `PAYOUT_INTEGRITY_HOLD_DAYS`, `VALIDATIONS_PER_DAY`, `WEBHOOK_TOLERANCE_SECONDS` | 120, 30, 3, 300 | see the jobs table; the hold an upheld tracker anomaly sets; penny drops per worker per day; how old a webhook may be |

Money rules that keep a retry from paying twice: a line's idempotency key `<line>:<attempt>` is written when the line
is queued and reused for every call of that attempt; a timeout after `POST /payouts` is an unknown outcome, looked
up by `reference_id` before anything is sent again; only finance's retry mints a new attempt. Settling is
rank-ordered (a late `queued` never overwrites `paid`) and idempotent, so webhook order and redelivery do not
matter. A window with a failed line stays `paying`, so Odoo (which imports a window once, when it is `paid`) never
bills a partial window. NTP on every node is a deploy requirement: window edges use the process clock, earnings
the database clock.

## Jobs

Each events process runs a leased scheduler (`yantra_common.scheduler`) beside its relays and consumers. A job's
row lives in its module's `job_lease` table: when it runs next, its last run, result and error, and who holds it.
A replica runs a job only after winning that row in one UPDATE, so two replicas never run one pass at once. Rule:
a job is one bounded pass (a few hundred rows, SKIP LOCKED). Jobs run in worker threads, so a slow one (an SMTP
server that does not answer) never holds the relays. A failing job records its error and still moves to its next
slot. `GET /v1/<module>/jobs` (admin or ops) and the events process's `/ready` show the schedule; `/ready` is 503
when a job is three intervals late (an hour for a clock job), the loop has not turned in a minute, NATS is away, or an
outbox is stuck (`outbox_stuck`: its oldest unpublished row is past `YANTRA_OUTBOX_STUCK_SECONDS` and the backlog did
not shrink since the previous probe). The API processes' `/ready` is the database alone: a stale outbox shows there as
`outbox_stale` but never takes them out of their Service.

| Job | When | Lease | What |
|---|---|---|---|
| `market_claim_expiry` | every 30 s | `market` | releases claims past their TTL (up to ten passes of 500) so the worker can claim again |
| `quality_review_expiry` | every 30 s | `quality` | returns review and audit tasks whose hold lapsed to the queue |
| `talent_offer_expiry` | every 60 s | `talent` | expires offers past `offer_expires_at` |
| `assess_engine_sync` | every 15 s (`YANTRA_ASSESS_SYNC_SECONDS`) | `assess` | reads Assessment v2's attempts: certifies released passes, records fails, releases clean `auto_objective` attempts, voids stale assignments, refreshes snapshots |
| `notify_email` | every 3 s, only with `SMTP_HOST` | `notify` | sends the emails the inbox rows ask for |
| `<module>_prune` | daily 03:00 IST | each module | deletes outbox rows published over seven days ago and consumed ids over thirty |
| `market_retention_purge` | daily 03:30 IST | `market` | empties payloads, answers and the manifest unit list of batches past their project's `retention_days`, deletes their stored media and deliverable, emits `work.batch.purged.v1` (a batch with objects waits while storage is unconfigured) |
| `talent_erasure` | hourly | `talent` | erases the personal data of workers whose erasure is due (see Personal data) |
| `work_dead_letter_alert`, `payout_dead_letter_alert` | every 5 min | `market`, `payout` | one ERROR line per new dead letter |
| `payout_dispatch` | every 15 s | `payout` | sends queued lines to the rail (the line is marked `processing` and committed before the call; the idempotency key `<line>:<attempt>` was written when it was queued) |
| `payout_rail_poll` | every 60 s | `payout` | asks the rail about lines `processing` for over `YANTRA_PAYOUT_POLL_AFTER_SECONDS` (120; the rig 5): settles them, finds an unknown outcome by reference, or sends again with the same key |
| `payout_account_validation_poll` | every 60 s | `payout` | settles penny drops still `verifying` |
| `payout_window_close` | Saturday 00:05 IST | `payout` | closes last week's window in every `YANTRA_PAYOUT_CURRENCIES`; one already closed by hand is fine |
| `payout_reconcile` | daily 02:00 IST | `payout` | a recorded reconciliation run for every paying or paid window of the last 90 days |
| `tracker_stale_sessions` | every 60 s | `tracker` | ends open sessions with no sample for `YANTRA_TRACKER_STALE_MINUTES` (15) |
| `tracker_anomaly_scan` | every 5 min | `tracker` | runs the detectors (impossible activity, activity after the claim, a shared device) and flags what is new |
| `tracker_retention_purge` | hourly | `tracker` | deletes samples older than `YANTRA_TRACKER_RETENTION_DAYS` (30) and screenshot references (and objects) past theirs |
| `analytics_mart_refresh` | every 5 min | `analytics` | recomputes the marts for the days whose events arrived since the cursor (31 days per transaction) |

The analytics rebuild drill is not a job: the events process checks the `rebuild` control row every round and, when
an admin asked (`POST /v1/analytics/rebuild`), empties the marts, moves the wildcard consumer to the next durable
generation (which replays the stream from sequence 1) and records `done` once nothing is pending.

Dead letters: `GET /v1/<module>/dead-letters` lists them (never the payload); `POST
/v1/<module>/dead-letters/{id}/replay` runs the row's own handler again once the cause is fixed and clears the
row (`fresh: false` when another delivery got through meanwhile). The CLI has `yantra dead-letters <module>`,
`yantra dead-letter-replay <module> <id>` and `yantra jobs <module>`. The by-hand triggers stay:
`POST /v1/claims/release-expired`, `POST /v1/quality/reviews/release-expired`, `POST /v1/assess/sync`.

Stuck work: claims and review claims past their time are listed for admins and ops (`GET /v1/claims/expired`,
`GET /v1/quality/reviews/expired`) with one-call release per row or for all, each signed with the caller's id, and
`…/released?days=7` shows what the job and people released (CLI: `yantra stuck`, `yantra stuck-release <id|all>`).

## Object storage

MinIO everywhere (rig, kind, staging, prod), reached with Signature Version 4 from `yantra_common.storage` over
httpx: presigned PUT/GET for browsers, header-signed HEAD, PUT and multi-object DELETE for the services, three
jittered attempts then 503 `storage_unavailable`. Presigned links are signed for the host the browser reaches
(`YANTRA_S3_PUBLIC_ENDPOINT`), the rest for the internal one (`YANTRA_S3_ENDPOINT`); a clock more than fifteen
minutes off MinIO's breaks every signature. URLs are never logged. Settings: `YANTRA_S3_ENDPOINT` (unset: no
storage, the routes that need it answer 503 `storage_unconfigured`), `YANTRA_S3_PUBLIC_ENDPOINT`, `YANTRA_S3_BUCKET`
(yantra), `YANTRA_S3_REGION`, `YANTRA_S3_ACCESS_KEY`, `YANTRA_S3_SECRET_KEY`, `YANTRA_S3_PRESIGN_SECONDS` (300),
`YANTRA_S3_PATH_STYLE` (true), `YANTRA_S3_SSE_KMS_KEY_ID` (encrypt uploads under a key; MinIO needs KES for it).
Tests use `yantra_common.testing.FakeStorage`; the signer is pinned by the specification's published examples.
A presigned PUT given `size_bytes` (`presign_put(key, content_type, max_bytes, size_bytes=n)`) signs
`content-length: n`, so the store refuses a body of any other size; market's payload uploads pass the declared size.
A multi-object delete that answers 200 with per-key `<Error>` entries raises `storage_unavailable` naming the keys.
An upload that is presigned but never registered (no import line or document row names it) stays in the bucket. A
bucket lifecycle rule cannot tell such an orphan from a registered object (both live under `projects/*/units/` or
`workers/*/documents/`), so do not expire those prefixes by age; the cleanup is a sweep that lists them and deletes
keys no unit or document row names and older than a day. It is not built yet: until it is, orphans only cost space.
MinIO upstream no longer publishes images to Docker Hub: the rig and the chart pin Bitnami's build of the server.

## Worker-facing endpoints added for the app

| Path | What |
|---|---|
| `GET /v1/workers/me` | the worker as the market knows them: status (`unknown` before Odoo marks them eligible), certification gates, availability |
| `PUT /v1/workers/me/availability` | the weekly check-in: hours per week and an optional pause; a paused worker sees no batches and cannot claim (403 `availability_paused`) |
| `GET /v1/batches`, `GET /v1/claims/active` | now carry `project_name` and the project's `answer_schema`; the active claim carries a `batch` brief (never the price) |
| `POST /v1/claims/{id}/submission` | validates the answer against the project's `answer_schema` when one is set (422 `answer: <path>: <message>`); 409 `batch_cancelled` when the batch was cancelled underneath the claim |
| `GET /v1/quality/my-work` | the author's submissions: stage, canonical verdict, reason code, billable flag, reviewer note, dispute |
| `POST /v1/quality/tasks/{id}/dispute` | one dispute per task, by the author, within 14 days of the verdict; ops list and resolve under `/v1/quality/disputes` (never one on their own work or verdict: 403 `self_action`) |
| `GET /v1/payout/statement` | adds `account`, `windows` (the worker's pay-window lines), `weeks` (twelve IST pay weeks), `pending_next`, `next_window_closes_at` |

## Deploy

The chart, the Argo CD apps, the image policy and the scripts live in `deployment/` (its README has the layout
and the table of what the owner provisions; RUNBOOKS.md and SLO.md are the operating side).

```bash
deployment/scripts/helm-check.sh          # helm lint + template for local, staging and prod + kubeconform + promtool (Docker only)
deployment/scripts/container-smoke.sh     # build the python and app images, run them read-only as the chart does
deployment/scripts/kind-up.sh             # chart on a kind cluster, migrations as hooks, then yantra smoke (needs kind, kubectl, helm)
deployment/scripts/kind-down.sh
deployment/scripts/backup.sh              # the rig's databases, NATS stream, MinIO data and Odoo filestore into backups/<timestamp>
deployment/scripts/restore.sh backups/<timestamp>
```

CI (`.github/workflows/ci.yaml`) runs on every pull request, filtered by path: the Python job (ruff, format,
mypy, `pytest --cov` against Postgres, Redis, the test NATS and Mailpit from the compose file, a Trivy scan), the
Flutter job (analyze, test, web build), the Odoo addon's suite when `services/odoo` changes, `helm-check.sh`
when `deployment/` changes, and `container-smoke.sh` when an image's inputs change (all of them on a push to main;
the image build waits for every one). Run the same commands on your machine before pushing. A push to main also builds the python, app and odoo images, pushes them to
`ghcr.io/etharalabs/yantra/*`, signs them keylessly with cosign, attests an SPDX SBOM, scans them, and opens a
pull request writing their digests into `values-staging.yaml`; Argo CD deploys staging when it merges. Prod is a
hand-made pull request copying those digests into `values-prod.yaml`, then a manual sync outside the Friday
12:00 to Saturday 12:00 IST freeze. The app image still bakes the gateway and Keycloak URLs at build time, so it
is built for staging; promoting one app image to prod needs the runtime `config.json` (plan W8).

## What is not here yet

A RazorpayX sandbox run: the adapter is tested against a scripted fake server and run on the rig against the WireMock
emulator (`deployment/local/wiremock/`), which cannot sign webhooks, so the signed-webhook path is proven by tests
only; the acceptance step is one window paid in RazorpayX test mode with `YANTRA_RAZORPAYX_WEBHOOK_SECRET` set.
A re-seal job for `YANTRA_BANK_KEY` rotation (old values keep opening under `YANTRA_BANK_KEY_PREVIOUS`). Stripe (one
more adapter behind `yantra_payout.rails.Rail`). Push notifications and the app's offline
mutation queue. A log store on the rig (JSON logs are read with `jq`; a cluster ships stdout to its own). The alert
rules as a chart `PrometheusRule` (apply `deployment/observability/alerts.yaml` to the cluster's Prometheus by hand). Terraform for the cloud resources is not here: the chart takes
them as URLs and secrets (deployment/README.md lists them).
Finance posts the draft bills and invoices Odoo creates. See the plan's Stage 1 steps in `docs/final-nov-2/`.
