# assess

Yantra's side of **Ethara's Assessment v2**. The exam (every question type, the timer, autosave, proctoring with the
AI proctor and evidence, LLM scoring, results release) runs in v2: the `assessments_be_v2` Odoo addon, vendored into
Yantra's Odoo image, and its Flutter app (the *Assessment app*, :8096 on the rig). This module keeps what Yantra needs
around it: the paper (the gate it certifies, the attempts a worker gets, how results are released), each worker's
attempts, and the certification that grants the gate. The contract is `docs/PRODUCT.md` §5.3.

- **Papers.** Ops link a paper to an assessment built in the Assessment admin (SOP-generated, Form Studio, any
  question type, any proctoring) or write a quick one here (one- and several-answer questions; it goes in through
  v2's bank CSV import, then approve-all, then a draft assessment), then publish it once v2's launch gates pass.
- **Launch.** A worker's launch provisions them in v2 (keyed on their Keycloak subject, through the
  `yantra_assess_bridge` addon), puts them on the cohort of their attempt number (v2 allows one attempt per person per
  assessment, so attempt k sits in cohort k, a copy made when first needed; v2 closes a cohort once everyone on it
  is released, and the next launch opens another copy), and returns a one-time URL that signs
  them into their exam: no second password.
- **Sync.** The `assess_engine_sync` job (every `YANTRA_ASSESS_SYNC_SECONDS`, 15) reads v2's attempts changed since
  its cursor, moves sittings along, releases clean objective attempts on `auto_objective` papers, withdraws
  assignments nobody started within `assigned_ttl_days`, and refreshes paper snapshots every 5 minutes. A released
  pass writes the certification and emits `assess.certified.v1`; a released fail emits `assess.failed.v1`. Yantra
  never certifies on an unreleased result.

## Layout

| Path | What |
|---|---|
| `yantra_assess/engine/__init__.py` | the `Engine` protocol, its value types, `select_engine` |
| `yantra_assess/engine/v2.py` | v2 over HTTP: Keycloak client credentials for the bridge, the service user's v2 token for v2's `/api/v1`; reads retried, writes not |
| `yantra_assess/engine/fake.py` | an in-process engine with v2's rules, for tests (refused outside `YANTRA_ENV=local`) |
| `yantra_assess/config.py` | `YANTRA_ASSESS_*` and their boot guards |
| `yantra_assess/service.py` | papers, launch, release, rotate, the sync |
| `yantra_assess/router.py` | the routes of §5.3 |
| `migrations/versions/0004_assess_engine_v2.py` | the engine columns, cohorts, the worker link, the sync cursor; quiz-era papers retired |

## Settings

| `YANTRA_ASSESS_…` | Rig value | Meaning |
|---|---|---|
| `ENGINE` | `v2` | `v2` or `fake` (tests; refused outside `YANTRA_ENV=local`) |
| `ODOO_URL` | `http://odoo:8069` | where the work process reaches Odoo |
| `APP_URL` | `http://localhost:8096` | the Assessment app (the fake engine's launch URLs) |
| `RETURN_URL` | `http://localhost:8095` | the Yantra app the Assessment app sends the worker back to |
| `KEYCLOAK_TOKEN_URL` | `http://keycloak:8080/realms/yantra/protocol/openid-connect/token` | client credentials for `yantra-assess` |
| `CLIENT_ID` / `CLIENT_SECRET` | `yantra-assess` / the local secret | required with `v2`; the rig's secret is refused outside `local` |
| `TIMEOUT_SECONDS` | `10` | per call to Keycloak and Odoo |
| `SYNC_SECONDS` | `15` | the sync's period |

The gateway forwards the token's email (`X-Email`, `X-Email-Verified`) so the bridge can bind the worker to an
existing v2 account only when Keycloak verified the address.
