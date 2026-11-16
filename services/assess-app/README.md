# assess-app

Assessment v2's exam app (Ethara's `ethara-assessment-fe`, Flutter web, MIT; patch 0006 adds Plus Jakarta Sans and
DM Mono, SIL OFL 1.1), vendored with Yantra patches and
served by nginx with the API proxied to Odoo on the same origin. Local rig: http://localhost:8096.

- `vendor/`: the upstream copy at the commit in `vendor/VENDOR.toml`, plus `vendor/patches/` (never edit the copy;
  `uv run yantra vendor sync services/assess-app/vendor/VENDOR.toml --from ethara-assessment-fe=<checkout>`).
- `build.sh`: builds the bundle into `dist/` (Flutter 3.44.8, python3, rsync). It builds a scratch copy, so the
  proctoring models it fetches never show as vendor drift.
- `Dockerfile.prebuilt`: the rig's image from `dist/` (the VM is too small for the Flutter build).
  `Dockerfile`: the full build, used by CI.
- `nginx.conf`: SPA fallback; `/api/`, `/assessments_be/`, `/web/content/` to `${ODOO_UPSTREAM}`; a 404 for the
  routes Yantra never serves (sign-up, the token gateway's password routes, password change and reset).
- `docker/18-assess-config.sh`: renders the security headers. The CSP allows this origin, the hashes of
  `index.html`'s inline scripts (`tool/csp_hashes.py`, computed at build), `STORAGE_URL`, and YouTube and Vimeo.

| Patch | What |
|---|---|
| `0001-same-origin-api` | `API_BASE_URL=same-origin` resolves to the page's own origin |
| `0002-yantra-launch-helpers` | reads `/yantra/launch#ticket=…`, keeps and vets the way back to Yantra |
| `0003-redeem-launch-ticket` | `ApiClient.redeemLaunchTicket` and `Session.launch`; refusals point back to Yantra |
| `0004-launch-on-start` | a launch link signs in with its ticket, wipes it from the address bar, opens the sitting |
| `0005-back-to-yantra` | "Back to Yantra" on every gate and after submit; "Continue with Yantra" on sign-in |
| `0006-studio-look` | Yantra's studio look: the studio palette on the portal tokens, the two faces bundled (Jakarta as static weights), pill gradient primary `Btn`, 18px panels, the board and blooms behind the shell, the gradient chip on the active nav item |

Tests: `cd vendor/ethara-assessment-fe && flutter test` (the Yantra ones are in `test/yantra/`).

`YANTRA_APP_URL` is compiled in (the rig's build uses http://localhost:8095). CI images leave it empty, so a staging
image promoted to prod never points at staging. The server still checks every return URL, but there is no
"Continue with Yantra" button on the sign-in form. Making it runtime config is a follow-up.
