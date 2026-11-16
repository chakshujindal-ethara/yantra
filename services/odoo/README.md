---
type: Specification
title: Odoo Service
description: The system of record — Odoo 19 CE, OCA aggregation, and the ethara_* addon suite.
tags: [odoo, erp, system-of-record, service]
status: draft
---

# odoo

The system of record. In Stage 1 this directory holds the `yantra_bridge` addon and the Odoo image (see "Stage 1 bridge" below); the full `ethara_*` suite described here is the target state. Full module selection and license compliance: [MODULES.md](../../MODULES.md).

**Contents.** Odoo 19.0 CE pinned by commit; OCA repos aggregated and pinned by commit (gitaggregate-style manifest); the in-house `ethara_*` addon suite (workforce onboarding orchestration, geofenced attendance, India payroll rules, GST returns, ITMS/ITIL layer, license register, shifts, referrals, portal surfaces, native `@http.route` API controllers with `auth_jwt`, Redis sessions, tracker linkage); configuration for the four deployment roles (web/websocket/cron/jobs per [INFRASTRUCTURE.md](../../INFRASTRUCTURE.md)).

**Owns.** HR master data, contracts, attendance, leave, skills, payroll, full accounting ledger (GST/TDS), analytic cost centers, projects and client billing, IT assets, helpdesk, DMS/e-sign, approvals, eLearning/certifications, gamification (DESIGN.md §5.1).

**Boundary rules.** No Enterprise (OEEL-1) code — hard CI gate; no broker clients in-process (outbox via `base_automation` + `queue_job`); inbound service calls only through `ethara_api` controllers and JSON-2; 200K-worker traffic never reaches these workers; portal-facing models require `portal.mixin` + explicit `ir.rule` scoping.

**Emits.** `worker.lifecycle`, `hr.sync` topics via outbox. **Consumes.** `work.units`, `quality.verdicts`, `payments` — queue-buffered into ledger and HR records.

**SLOs.** Backend p95 page latency at 1–2K concurrent internal sessions; payroll batch window for 20K employees; month-end close integrity; upgrade Jobs within maintenance windows.

## Stage 1 bridge (`addons/yantra_bridge`)

The first Odoo-side piece of Yantra: Odoo is the system of record for people and money, the Python services own
work and earnings, and the gateway sits between them. `yantra_bridge` (Odoo 19 CE, depends on `account` and
`contacts`) does four things:

| Piece | Model(s) | What it does |
|---|---|---|
| Worker record | `yantra.worker`, `yantra.cert.gate` | name, contact, auto-created supplier partner, Keycloak subject (UUID, unique), agreement and DPDP consent timestamps, payout setup (the full account number lives only on the partner's `res.partner.bank`; the worker shows the last 4), PAN, TDS rate, certification gates. "Mark eligible" refuses with a `UserError` naming the missing field; on success it pushes `PUT /v1/workers/{sub}` with `{status, cert_gates, partner_ref}` **before** writing the status, so a refused push leaves the record in draft. Activate / Suspend / Offboard push the same way. |
| Paid pay windows | `yantra.pay.window`, `yantra.pay.window.line` | cron "Yantra: pull paid windows" (every 30 min, also in the list's action menu): `GET /v1/payout/windows?status=paid`, then `.../{id}/lines` for each window not yet imported. Each `payable`/`paid` line becomes one draft vendor bill (`account.move`, `in_invoice`) on the worker's partner; a line whose Keycloak subject has no worker goes to `needs_worker` (count shown on the window) and is retried on every run; `held` lines are never billed. A line maps to at most one bill (`bill_id`, unique gateway line id), so re-running never bills twice. |
| TDS | `account.move.line.yantra_is_tds` | the bill has the earnings line `Yantra earnings window <starts>–<ends>` = gross and a **negative line** `TDS @ <rate>%` = −round_half_up(gross × rate / 100, 2), so the bill's total is the net the worker receives. Chosen over a negative `account.tax` because the withholding is a per-worker rate stored on the worker, not a company tax table, and a plain line keeps the bill readable and auditable without a tax configuration per rate. Both lines carry no taxes (`tax_ids` cleared) so the chart's default purchase tax never leaks in. |
| Reconciliation | `yantra.pay.window.reconciled` | `gross_total` from the gateway vs the sum of the earnings lines of the bills; `reconciled` is true only when every non-held line is billed **and** the two totals agree to the paisa (`float_compare`, 2 digits). |
| Client invoices | `yantra.client.project`, `yantra.batch` | "Invoice batch" calls `GET /v1/batches/{id}/manifest`; a 409 `batch_held` becomes a `UserError` carrying the message and every extra count in the error body; a 200 creates one draft customer invoice with one line `accepted_units × unit_price` in the manifest currency (refused if the manifest's `total_price` disagrees). The invoice id is stored; a second click opens it without calling the gateway. |

Plumbing: `gateway_client.GatewayClient` (requests; connect 3 s, read 10 s; one retry with jitter on 429/503
honouring `Retry-After`, capped at 30 s; Keycloak client-credentials token cached per process and refreshed 30 s
early; one `Idempotency-Key` (uuid4) per logical action; never logs tokens, secrets or bodies). Models log one
line at the boundary with Odoo ids, the Keycloak subject, HTTP status, error code and `request_id`. Access is
limited to the group **Yantra / Operations** (`yantra_bridge.group_yantra_ops`, implies Internal User) through
`ir.model.access` and one `ir.rule` per model.

### Settings (`ir.config_parameter`)

| Key | Meaning |
|---|---|
| `yantra.gateway_url` | gateway base URL, e.g. `http://gateway:8090` |
| `yantra.keycloak_url` | Keycloak base URL, e.g. `http://keycloak:8180`; the realm is `yantra` |
| `yantra.keycloak_client_id` | confidential client, `yantra-odoo` |
| `yantra.keycloak_client_secret` | its secret (password widget, never logged) |
| `yantra.default_tds_rate` | default TDS % for new workers |

All five are on Settings > Yantra (visible to the Operations group). The cron logs one info line and does nothing
while any of the first four is empty.

### Compose snippet for `deployment/local/compose.yaml`

The shared `postgres` service already runs as `yantra`/`yantra`; Odoo creates the `odoo` database itself on the
first `-i` run (the role is the superuser of that container).

```yaml
  odoo:
    build: ../../services/odoo
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      HOST: postgres
      USER: yantra
      PASSWORD: yantra
    command: ["odoo", "--db-filter=^odoo$"]
    ports:
      - "8069:8069"
    volumes:
      - odoodata:/var/lib/odoo
      - ../../services/odoo/addons:/mnt/yantra-addons:ro   # optional: live addon edits without a rebuild
```

plus `odoodata:` under `volumes:`. The Keycloak client secret for `yantra-odoo` is whatever the realm export in
`keycloak_auth/` assigns; it goes into the `yantra.keycloak_client_secret` setting (not an env var, so the
container never carries it).

### First login

1. `docker compose -f deployment/local/compose.yaml run --rm odoo odoo -d odoo -i yantra_bridge --stop-after-init`
   (creates the database and installs `account`, `contacts`, `yantra_bridge`), then `docker compose ... up -d odoo`.
2. Open http://localhost:8069, log in `admin`/`admin`, Settings > Users > Administrator > add **Yantra / Operations**.
3. Settings > Invoicing: pick a fiscal localization (India, `l10n_in`, for TDS reporting; the tests use the generic
   chart). Without a chart there is no purchase journal and the cron raises a clear `UserError`.
4. Settings > Yantra: gateway URL `http://gateway:8090` (or `http://host.docker.internal:8090` when the gateway runs
   on the host), Keycloak URL, client id `yantra-odoo`, the secret, the default TDS rate. Save.
5. Yantra > Configuration > Certification gates: add the gate codes the market expects.
6. Yantra > Workers > New: name, email, Keycloak subject (the user's `sub` in the realm), agreement and consent
   timestamps, bank details (the account number is written to the partner's bank account), PAN, gates. **Mark
   eligible** pushes the worker to the gateway; the status bar moves to Eligible.
7. Pay windows appear after the first paid window (cron every 30 min or "Pull paid windows now"); bills are drafts
   under Invoicing > Vendors > Bills for the two-person approval. Client projects and batches are created by hand
   with their gateway ids; "Invoice batch" draws the manifest.

### Testing

```bash
docker compose -f services/odoo/compose.test.yaml build odoo                  # always: the addons are baked in
docker compose -f services/odoo/compose.test.yaml up -d --wait postgres       # odoo :8169, postgres :5441
docker compose -f services/odoo/compose.test.yaml run --rm odoo odoo -d yantra_odoo_test \
    -i yantra_bridge,yantra_assess_bridge --test-enable \
    --test-tags=/yantra_bridge,/yantra_assess_bridge --stop-after-init
docker compose -f services/odoo/compose.test.yaml down -v
```

The vendored Assessment v2 suite (about 3,100 tests, run on every vendor bump) is in the header of
`compose.test.yaml`. Three of its tests need Ethara's `etp_assessment_pro` on disk and refuse to skip; they fail
here by design.

Odoo 19 installs without demo data by default (`--without-demo` is now a boolean flag). The tests
(`tests/`, tagged `post_install`) load the generic chart of accounts and replace the client's `requests` session
with a fake routed by `(method, path)`; nothing reaches the network.

### Limitations

- Bills and invoices are left in draft on purpose (two-person approval, posting and payment are the finance step);
  nothing is posted or reconciled against bank statements.
- TDS is a plain negative line, not a withholding tax: no TDS section/ledger reporting until `l10n_in` TDS is wired.
- Currency: windows and manifests carry a currency code; an inactive currency (e.g. INR on a fresh USD company) is
  activated on first use, and the company currency is not changed.
- Single company; the cron bills in the cron user's company.
- `batch_held` has no agreed shape for its pending counts; the addon shows every extra key of the error body
  (`pending=3; rejected=1`).
- Payout now pays line by line through a rail (see `services/payout/README.md`). A window becomes `paid` only when
  every non-held line is `paid` or `released`, so the cron never imports a partly paid window. A `released` line
  (finance gave up on a failed payout) leaves the window: its earnings return to payable for the next close, and
  the window's `gross_total` drops by that amount, so the `reconciled` comparison still holds. Lines carry new
  keys (`utr`, `rail_reference`, `attempts`, `failure_reason`); the addon ignores them. The Odoo service account
  holds `ops`, which can read windows but cannot approve or pay them (that needs `finance`).
- No inbound events: the gateway never calls Odoo; everything is pull or push from Odoo.
- The Keycloak realm name is fixed to `yantra`.

## Assessment v2 (vendored) and `addons/yantra_assess_bridge`

The image carries Ethara's Assessment v2 (`assessments_be_v2`) and its token gateway (`api_auth_gateway`) under
`vendor/addons`, copied from `ethara-etp` at the commit in `vendor/VENDOR.toml`. Never edit the copies: add a
numbered patch under `vendor/patches`, then `uv run yantra vendor sync services/odoo/vendor/VENDOR.toml --from
assessments_be_v2=<checkout> --from api_auth_gateway=<checkout>`; CI runs `uv run yantra vendor check`.

| Patch | Why |
|---|---|
| `0001-drop-employee-extension` | v2 does not use `employee_extension`; depending on it pulls in Ethara's recruitment stack and PyTorch OCR |
| `0002-s3-endpoint` | MinIO: an internal endpoint with path addressing for the server, the public endpoint for browser signatures |

`yantra_assess_bridge` lets Yantra drive v2 without passwords. Yantra's adapter (`yantra_assess`, engine `v2`)
proves itself with a Keycloak client-credentials token for `yantra-assess`, then:

- `POST /api/v1/yantra/service/token`: a 15-minute v2 bearer for v2's own admin routes (create, assign, launch,
  attempts, release);
- `POST /api/v1/yantra/service/people`: binds a Keycloak subject to an internal user plus `hr.applicant` (by
  subject; by email only when Keycloak verified it; never a portal account);
- `POST /api/v1/yantra/service/tickets`: a one-time launch ticket (sha256 stored, single use, 120 s) and
  `<assess app>/yantra/launch#ticket=...`;
- `POST /api/v1/yantra/launch/redeem` (public, called by the exam app): ticket to a v2 bearer that lasts until the
  attempt's deadline plus 30 minutes (12 hours at most).

v2's own invitation mail is suppressed for Yantra-bound people (Yantra tells them). `init.sh` seeds every setting:
MinIO, Redis db 2, Mailpit, the exam app's origin, the bridge's issuer, JWKS URL and return origins, and the Vertex
service account when `YANTRA_VERTEX_SA_JSON_FILE` is set. Without Vertex, papers come from a CSV bank and objective
questions mark themselves; SOP paper generation, LLM marking and image/video generation need it.

Yantra's addons live at `/mnt/yantra-addons`, not `/mnt/extra-addons`: the official image declares that path a
`VOLUME`, and compose keeps an anonymous volume's old content across recreates, so a rebuilt addon never arrived.
