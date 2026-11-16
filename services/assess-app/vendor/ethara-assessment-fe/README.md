# Assessment v2 - front end

The operator console and candidate portal for the Odoo **`assessments_be_v2`**
addon. A Flutter web app that talks to that addon's REST API and nothing else.

It holds **no business rules**. Every gate, score, threshold, retry and release
decision belongs to the module and is reached over `/api/v1/...`. This app
renders what the server says and sends what the operator does.

---

## Run it

```bash
flutter pub get

# Against a local Odoo. Nothing to pass: served on localhost, the app pairs
# itself with localhost:8069 / etp_local. See "Which backend it talks to".
flutter run -d chrome

# Against a remote backend from a local build, which the host cannot imply:
flutter run -d chrome --dart-define=API_BASE_URL=https://projects-stage.ethara.ai
```

Or build and serve behind the bundled proxy, which avoids CORS entirely:

```bash
flutter build web --release
python3 tool/dev_server.py 8200 7070     # app on :8200, proxies /api to :7070
```

### Which backend it talks to

**The app works this out for itself from the host it is served from.** Nothing
has to be configured for a normal deployment:

| Served from | Talks to | |
|---|---|---|
| `assessment.ethara.ai` | `https://projects.ethara.ai` | production |
| `assessment-stage.ethara.ai` | `https://projects-stage.ethara.ai` | stage |
| `localhost` / `127.0.0.1` | `http://localhost:8069` (db `etp_local`) | local |
| anything else | its own origin | seed data |

The table lives in `lib/assessment/data/environment.dart` and is mirrored by
`assessments_be_v2/services/app_origins.py` on the server. `make
test-env-parity` fails if the two drift.

This replaced a compile-time-only `API_BASE_URL`. Because Dart compiles that
define into `main.dart.js` as a string constant, the backend was a property of
the **build**, so an image promoted from stage to production kept calling stage —
and nothing on the server side looked wrong, because stage answered every
request correctly.

`make build-portable` produces the bundle that behaviour is for: no baked URL,
so one artefact serves every host.

### Overriding it

| Define | Meaning |
|---|---|
| `API_BASE_URL` | Pin the Odoo origin, ignoring the table. Empty = use the table. |
| `API_DB` | Odoo database. Only sent on the session-cookie login path. |

An explicit `API_BASE_URL` still wins, because it has to: `make serve-stage`
serves a stage bundle from `127.0.0.1:8201`, and the table would send that at
`localhost:8069`. Use it for a host in no table — a preview deploy, a bare IP,
or a local build aimed at a remote backend.

### Running against a backend

```bash
make serve                 # ENV=local by default
make serve ENV=stage       # or: make serve-stage
make serve ENV=prod        # or: make serve-prod
```

| ENV | Backend | Output | Port |
|---|---|---|---|
| `local` | `http://localhost:8069` | `build/web-local` | 8200 |
| `stage` | `https://projects-stage.ethara.ai` | `build/web-stage` | 8201 |
| `prod` | `https://projects.ethara.ai` | `build/web-prod` | 8202 |

All three can run at once — separate output directories, because a pinned bundle
carries its host and one shared `build/web` means a stage build silently
repoints the local app. Each build greps the finished bundle for the host it was
pinned to, so a build that kept a stale define fails loudly instead of looking
like a backend outage.

Override per invocation: `make serve ENV=stage STAGE_BASE_URL=https://other.host
STAGE_PORT=8300`, or bypass the table entirely with
`make build API_BASE_URL=https://one-off.host`.

Stage and production answer `/api/v1/auth_token`, so the app takes the gateway
(bearer) lane and `STAGE_DB`/`PROD_DB` are deliberately empty — `db` is only
sent on the `/api/v1/auth/session` fallback a 404 on the gateway selects.

**The port you serve on must be in the backend's allow-list.** 8200, 8201 and
8202 are in `LOCALHOST_ORIGINS` in `assessments_be_v2/models/ir_http.py`; a port
that is not there gets its credentialed request discarded by the browser while
the server log stays clean.

`tool/serve.py` is a static server with `Cache-Control: no-store` and no proxy,
so these are cross-origin setups and the backend's CORS allow-list has to name
the port you serve on.

---

## What the backend must provide

The module exposes **122 REST routes** under `/api/v1/`. They are grouped by what
they serve:

| Group | Routes | Purpose |
|---|---|---|
| `auth` | 6 | session, whoami, logout, change and reset a password |
| `generators` | 20 | SOP upload, skill extraction, question generation |
| `drafts` | 8 | the review queue: approve, reject, regenerate |
| `bank` | 15 | the approved question bank, import, templates |
| `assessments` | 18 | create, configure, launch, candidates, release |
| `attempts` | 7 | one candidate's sitting |
| `exam` | 7 | the candidate's own exam: begin, submit, answers |
| `me` | 3 | the candidate's own list, dashboard, analytics |
| `responses` / `scoring` | 5 | every answer, and its scoring state |
| `forms` | 10 | Form Studio: list, save, delete, publish, media, and the JSON import template |
| `task_templates` | 4 | reusable task definitions behind a generator |
| `tags`, `settings`, `ledger`, `budget`, `analytics`, `leaderboard`, `emails`, `chatter`, `candidates`, `users` | 19 | supporting surfaces |

### Invitation links

The module emails a candidate a link. By default it points at Odoo's own portal
(`/pro_assessment/<token>`), which renders QWeb templates - the one place the
backend genuinely couples a candidate to the Odoo UI. To send them here instead,
set an Odoo system parameter:

    assessments_be_v2.candidate_app_base_url = https://assess.example.com

The invitation then links to `https://assess.example.com/exam/<token>`, and this
app drives the whole sitting over `/api/v1/exam/<token>/...` - the same gates,
timer and scoring, with no Odoo UI in the candidate's path.

The **token is unchanged** either way: it is the assessment's own key, so both
front ends resolve the identical sitting and switching is a config change, not a
migration. This app also accepts a pasted `/pro_assessment/<token>` URL, so a
link issued before it existed still opens.

### The API is independent of Odoo's own UI

This was verified rather than assumed:

- **no `request.render`, no QWeb, no template** anywhere in `controllers/api/`
- the API controllers import only Odoo core (`http`, `fields`, `request`,
  exceptions) and their own `serializers` - nothing from the module's `views/`
  or `static/`
- the entire admin surface and the entire candidate surface were exercised
  **headlessly**, with no browser and no Odoo web session

The module's own backoffice views still exist and still work. They are simply
not on this app's path, so they can be ignored, or removed later, without
touching the API.

### The security boundary is the server's

A candidate token is **refused** on every operator route - `assessments`,
`generators`, `bank`, `ledger`, `settings` all answer
`{"ok": false, "error": {"code": "forbidden"}}`.

This matters for a standalone front end: the portal a user sees is decided by
`/api/v1/auth/me`, never by the client. A tampered client can change what is
drawn; it cannot change what the server will answer.

### Envelope

Success and refusal share one shape:

```jsonc
{"ok": true,  "data": ...}
{"ok": false, "error": {"code": "forbidden", "message": "..."}}
```

Wire format is `snake_case`. `ApiClient._call` unwraps `data` and raises
`ApiError` carrying the module's own sentence, so screens show the server's
words rather than a generic failure.

---

## Layout

```
lib/
  main.dart              app, theme mode, signed-in vs login
  session.dart           who is signed in; owns the one ApiClient
  login_screen.dart      sign-in, drawn in the app's own tokens
  app_shell.dart         sidebar, top bar, content area
  config.dart            app name (the API config lives with the client)
  core/theme/            PortalTokens + PortalType: the design system
  services/              csv + json export, file picker, token store,
                         prefs, proctor, reset URL - web + stub pairs
  assessment/            THE PRODUCT - 76 files
    data/                ApiClient: every route, one place
    domain/              models, enums, gates
    state/app_store.dart the single store
    screens/             admin/, member/, exam/
    widgets/             panels, grids, buttons, marks, feedback
```

**The sidebar is the destination list.** `operatorNav()` in
`lib/assessment/domain/nav_entries.dart` returns ten rows, drawn by `_Sidebar`
in `app_shell.dart` through `AssessmentSection.sidebarBuilder`: Dashboard and
Assessments ungrouped, then AUTHORING (Generators, Review Queue, Question Bank,
Tags, Form Studio), RESULTS (Responses) and PLATFORM (LLM Budget, Settings).

Two surfaces are deliberately NOT rows and the file says why: Account, reached
by clicking your own name in the card at the foot of the rail, and the per-call
spend log, one click from LLM Budget. A candidate gets two rows: My Assessments,
My Performance.

---

## Tests

```bash
make test        # both platforms
make verify      # + analyzer, build, and the live backend when reachable
make help        # everything else
```

Or directly:

```bash
flutter test                      # VM
flutter test --platform chrome    # the environment that actually ships
```

Green as of 2026-09-18: **VM 1,826 passed**, **Chrome 1,276 passed**, `dart
analyze lib/ test/` clean. The Chrome count is lower because tests that read the
source tree are `@TestOn('vm')` and skip there.

**Run both.** Compiled to JavaScript there is one numeric type, so `0.0 is int`
is `true` on the web and `false` on the VM. That difference silently truncated
every currency value on the LLM budget screen while the VM suite stayed green.
Tests that read the source tree are tagged `@TestOn('vm')` and skip cleanly
under Chrome.

Fixtures in `test/assessment/payloads/` are captured from a live backend and
committed. Refresh them when a serializer changes:

```bash
python3 tool/capture_payloads.py
```

They used to live in `/tmp`, which macOS clears - after a reboot the suite
checked nothing and still reported green.
