---
type: Specification
title: Flutter Application
description: Specification for the Yantra Flutter app — the single client for online workers and mobile-first onsite staff.
tags: [flutter, mobile, app, specification]
status: draft
---

# Flutter Application

Single Flutter codebase (mobile + web) serving two personas: online workers (200K — apply, assess, onboard, learn, claim tasks, track earnings) and onsite staff (20K — attendance check-in, leave, expenses, approvals on the go). The app is a git submodule (`EtharaOrion/yantra-app`, wired at Phase 0); this directory holds its specification.

# Architectural Rules

1. **Gateway-only networking.** The app talks exclusively to `services/gateway` over REST/OpenAPI with Keycloak-issued JWTs. It never calls Odoo RPC, never embeds Odoo session semantics, and never talks to domain services directly — the gateway contract is the only API dependency, so backend evolution never forces an app release.
2. **Offline-first mutations.** Local store (Drift/SQLite) is the source of truth for user actions; every mutation enters a durable local queue with a device-generated UUID that becomes the Idempotency-Key on sync (exponential backoff, connectivity-flap safe). Attendance check-in is the canonical example: geotagged events queue locally and sync without double-recording (see DESIGN.md §3.3).
3. **Push via FCM.** `firebase_messaging` client-side; all sends originate from `services/notify` — no FCM credentials or send logic anywhere else.
4. **No secrets in the app.** Tokens are short-lived Keycloak JWTs with refresh; certificate pinning against the gateway; screenshots/PII handled per [SECURITY.md](../SECURITY.md).

# Primary Journeys

| Persona | Journeys |
|---|---|
| Candidate → Worker | Apply → AI interview/assessments → offer → gated onboarding checklist (KYC, contract e-sign, tax form, payout setup) → training academy → certification |
| Active worker | Browse tasks (per-unit pay disclosed) → claim → work → submit → feedback/disputes → earnings dashboard → instant/weekly payouts → referrals → leaderboards |
| Onsite staff | Geofenced check-in/out → leave requests → expense capture → approvals → payslips → helpdesk tickets → org directory |

# Verification Baseline

Journey-level integration tests against a gateway contract mock; offline-queue property tests (no lost/duplicated mutation under flap simulation); p95 cold-start and claim-flow latency budgets defined before Phase 4 exit (see [ROADMAP.md](../ROADMAP.md)).

# Local run

The Stage 1 worker app lives in this directory as a plain Flutter project (`yantra_app`, org `ai.ethara`,
platforms web, android, ios). Dependencies: `http`, `shared_preferences`, `uuid`, `crypto` (the PKCE challenge),
`web` (the sign-in redirect and per-tab storage on the web); all pinned, no code generation.

```bash
cd app
flutter pub get
flutter run -d chrome --web-port 8095 \
  --dart-define=GATEWAY_URL=http://localhost:8090 \
  --dart-define=KEYCLOAK_URL=http://localhost:8180 \
  --dart-define=DIRECT_LOGIN=true
```

The two URLs have those defaults. Sign in with **Continue with Keycloak** (authorization code with PKCE against
realm `yantra`, public client `yantra-app`, redirect back to the app's origin) or, with `DIRECT_LOGIN=true` (the
rig's compose passes it; a build that says nothing offers only the redirect), with the password form:
`worker1`..`worker5` / `yantra`.

**Layout.** `lib/screens/shell.dart` is the chrome: the destinations come from the token's realm roles
(`Destination.visibleTo` over the six known roles `admin`, `ops`, `finance`, `reviewer`, `client`, `worker`;
Review needs `reviewer`, Finance needs `finance`; a token with none of them gets `no_access_screen.dart` and
loads nothing), a 240px sidebar with label and hint per destination
and the account footer at 960px and wider, a top bar with the page title, the command palette (Cmd/Ctrl+K), the
theme toggle and the inbox bell, and below 960px a drawer plus a bottom bar for the primary role's five.
`lib/core/widgets/` holds the primitives every screen is built from (`PortalPage` with kicker, `PortalCard`,
`KpiTile`, `ChecklistRow`, `ProgressRow`, `WeeklyBars`, `Skeleton`, `PortalTable`, `Pager`, `FilterChips`,
`Toolbar`, `StepList`, `ProgressBar`, `StackedBar`, `Countdown`, `BrandLoader`, `toast`, `confirm`, `Fact`,
`PortalTappable` (every non-button tap target: click cursor, Enter/Space, a 2px focus ring, a button node for
screen readers), and the console helpers in `stage_bar`, `form_sheet`, `side_sheet`, `mono_box`, `action_dialog`);
`lib/core/money.dart` the one money formatter (`₹12,50,000.00` for INR, the symbol and Western grouping for
USD/EUR/GBP, the code otherwise) and `payRange`; `lib/core/network_status.dart` the offline/unreachable state
behind the shell's banner;
`lib/core/format.dart` the date and duration words. Screens: worker (home, explore, listing, applications,
onboarding, assessment, work, my work, review, earnings, inbox, profile, policies), `ops/` (overview, projects,
project, batch, listings, listing detail, papers, paper, workers, worker, quality, finance, support) and `client/`
(overview, projects, project, deliveries). The API contract every screen is built to is `docs/PRODUCT.md`.

**Theme.** The app paints the Ethara portal theme: `lib/core/theme/portal_tokens.dart` is a copy of the
portal's design tokens (`PortalTokens.light` / `.dark`: magenta accent `0xFFB800B8` light, `0xFFC552BC` dark,
neutral surfaces, borders, text and the four status families), and `lib/core/theme/app_theme.dart` turns
them into `ThemeData` (`AppTheme.light` / `.dark`, picked by `ThemeMode.system`) plus the `StatusChip` /
`StatusBanner` helpers and `AppTheme.mono` for ids and JSON. Fonts are bundled under `assets/fonts/`
(SIL OFL, licences beside them): Plus Jakarta Sans as one variable file (weights go through
`FontVariation`, use `AppTheme.weight`) for text and DM Mono (400/500) for ids, codes and JSON.
Magenta is an accent only: CTAs, the active nav item and focus rings; status never uses it. Four light
tokens are deliberately darker or lighter than the portal canon so text meets WCAG AA 4.5:1 everywhere
(`textSecondary`, `textMuted`, `primarySubtle`, `selected`, plus the dark `textMuted`; see the comments in
`portal_tokens.dart`); every screen test checks text contrast and labelled tap targets (`expectAccessible`).

**Web shell.** `web/icons/mark.svg` is the brand mark (magenta rounded square, white Y); the PNG icons and
`web/favicon.png` are rendered from the same geometry by `uv run --no-project --with pillow==11.0.0 python
tool/render_icons.py`. `web/index.html` shows the mark as a splash until Flutter's first frame; the manifest is
role-neutral and allows any orientation.

## Tests, lint, build

```bash
flutter analyze                     # zero issues expected
flutter test                        # unit + widget tests against a scripted MockClient backend
flutter build web --release --dart-define=GATEWAY_URL=http://localhost:8090 --dart-define=KEYCLOAK_URL=http://localhost:8180 --dart-define=DIRECT_LOGIN=true
```

## Docker / compose

`app/Dockerfile` builds the web bundle with `ghcr.io/cirruslabs/flutter:stable` and serves it from
`nginxinc/nginx-unprivileged:1.27-alpine` (uid 101, port 8080, read-only root filesystem friendly) with an SPA fallback
to `index.html`, gzip, and cache rules (`index.html` and the unhashed JS/JSON, the fonts (the icon font is tree-shaken
per build) and the icons revalidate every load; CanvasKit is cached a day). The build passes `--no-web-resources-cdn`, so
CanvasKit is served from the image rather than Google's CDN; only the engine's fallback glyphs come from
`fonts.gstatic.com`.

Every response carries security headers (`nosniff`, `X-Frame-Options: DENY`, a referrer policy, a permissions policy
and a content security policy). The entrypoint renders them into `/tmp/yantra-config/headers.conf`, because the CSP
names the origins the page may talk to: `GATEWAY_URL`, `KEYCLOAK_URL` and `STORAGE_URL` (the browser-facing object
storage endpoint, where presigned media plays from and uploads go). Scripts are limited to `'self'` plus
`'wasm-unsafe-eval'` for CanvasKit. HSTS is the ingress's job, where TLS ends.

Configuration is read at start, so one image serves every environment: `docker/40-yantra-config.sh` runs in
nginx's entrypoint and writes `/config.json` from `GATEWAY_URL`, `KEYCLOAK_URL` and `DIRECT_LOGIN` when any is
set; the app reads that file first (`AppConfig.load`) and falls back to the values baked in at build time
(`--dart-define`, the same three names) for anything it leaves out. `DIRECT_LOGIN` defaults to `false`
(redirect sign-in only); the rig's compose sets `true`.

The gateway must allow the app's origin (CORS), and Keycloak's `yantra-app` client needs the origin in its Web
Origins and `<origin>/auth/callback` among its redirect URIs (the local realm allows `http://localhost:8095/*`).

## Routes

The router is `go_router` (`lib/app_router.dart`), path URLs (no `#`), so a link, a refresh or the browser's
back button keeps the page. Every destination is a branch of one `StatefulShellRoute`: branches stay alive (a
list keeps its scroll and filters), and detail pages open inside their branch, so the sidebar stays and the
detail shows a breadcrumb with a back arrow (`DetailFrame`).

| Path | Page |
|---|---|
| `/login`, `/auth/callback`, `/no-access` | sign-in, the Keycloak redirect's way back, a token with no Yantra role |
| `/work/home` (`/onboarding`, `/unit/<claimId>`) | Home; onboarding; the live unit |
| `/work/explore/<listingId>` | a listing |
| `/work/applications` (`/onboarding`, `/assessment/<paperId>`) | applications; onboarding; a paper |
| `/work/my-work`, `/work/review`, `/work/earnings` | worker pages |
| `/ops/overview`, `/ops/projects/<id>/batches/<batchId>`, `/ops/listings/<id>`, `/ops/papers/<id>`, `/ops/workers/<id>`, `/ops/quality`, `/ops/finance/windows/<id>`, `/ops/support` | operator pages |
| `/ops/leadership`, `/ops/system`, `/ops/settings` | leadership numbers; stuck work, dead letters, jobs; client organisations |
| `/client/overview`, `/client/projects/<id>`, `/client/deliveries` | client pages |
| `/inbox`, `/profile/policies/<slug>` | everyone |

Redirects follow the session: signed out goes to `/login` and, after sign-in, back to the page it was going to
(kept in per-tab storage so it survives the Keycloak redirect); a page the roles do not allow, or an unknown
path, goes to the person's first page; a token without a Yantra role sees `/no-access`. A detail opened from a
list carries what the list already read (`extra`); opened from a link, it reads its data by id.

Shared pieces screens use: `AppScope.people` + `NameOf` (names for ids, one batched `GET /v1/people` per
frame), `AppScope.downloader` (save a file), `AppScope.files` (the file chooser), `AppScope.uploader` (PUT to a
presigned object-storage URL), `AppScope.drafts` (work kept on the device), `PortalPage(commands:)` (actions in
the Cmd/Ctrl+K palette), `Poller` (every minute while the tab is visible; the bell uses it).

## How it talks to the gateway

- `lib/api/gateway_client.dart`: one `GatewayClient` over an injected `http.Client` and a `TokenProvider`.
  Adds `Authorization: Bearer`, `Idempotency-Key` on every POST/PUT, parses the error envelope
  `{code, message, request_id}` into `ApiException` (with `Retry-After` as a `Duration`).
  401 -> one refresh then retry, else sign out. 409 `request_in_flight` -> wait 1 s, same key, up to 3 times.
- `lib/core/action_keys.dart`: one UUID per user action, kept for retries of that action, dropped on success.
- `lib/auth/session.dart`: the `Session` (`ChangeNotifier`), password + refresh grants, lazy refresh 30 s
  before expiry, persisted in `shared_preferences`.
- `lib/api/repositories.dart`: `WorkRepository`, `ReviewRepository`, `PayoutRepository`, `NotifyRepository`.
- Screens under `lib/screens/`: login, home (open batches + claim), work (payload, answer form, countdown,
  submit), review, earnings, inbox (+ notification email).

## Stage 1 limitations

- **Tokens live in `shared_preferences`** (localStorage on web), not secure storage. This is deliberate on the
  web: the cross-tab refresh-token rotation in `Session` needs one store every tab sees (sessionStorage would
  sign the person out in each new tab), and `flutter_secure_storage` has no web equivalent. Short access tokens
  and the realm's session limits bound the exposure.
- **No offline queue.** The spec's durable mutation queue is not built; every action is online and retried
  by the worker tapping again (the idempotency key is kept for that retry).
- **Web only is exercised.** Android and iOS folders are generated but untested.
- **Timed pages keep their draft on this device only.** The unit's answer and the sitting's answers are saved
  locally every second and come back on resume; another browser does not see them.
- **Switching destinations keeps a detail page alive.** Leaving a unit or a sitting for another destination asks
  first (the clock keeps running) but the page stays in its branch, as it was.
- **Claim TTL countdown** uses the device clock against `expires_at`; a skewed clock shows a wrong figure.
- `GET /v1/batches` and `GET /v1/claims/active` are consumed as specified by the lead; they are not in
  `services/market/yantra_market/router.py` at the time of writing.
