# Picking up Yantra

Where Stage 1 stands, how to run it from a fresh clone, and where to start reading. The detail lives in the other
pages in this folder; this one is the map.

## What is here

Stage 1 of the plan, built end to end. One repository holds:

- **Python services**: market, talent, assess, quality, payout, notify, tracker and analytics. They run as two
  deployables, `work` and `money`, behind one gateway.
- **The Flutter web app**: worker, operator and client consoles by role, in the Social AI studio look.
- **The Odoo 19 bridges.**
- **Assessment v2**, vendored: the Odoo addon and the exam app.
- **Helm, Argo CD and CI.**

| Read | For |
|---|---|
| [PRODUCT.md](PRODUCT.md) | the contract: roles, screens, every endpoint and event |
| [DEVELOPING.md](DEVELOPING.md) | layout, settings, jobs, identity, tests, how to change things |
| [USING.md](USING.md) | starting the rig, the users, the CLI, the operator and finance flows |
| [MANUAL_TEST.md](MANUAL_TEST.md) | a by-hand walk through every screen, user by user |
| [LAUNCH.md](LAUNCH.md) | the Stage 1 gates with their figures, and what the rig cannot prove |
| [../deployment/README.md](../deployment/README.md) | the cluster: chart, Argo CD, secrets, and the owner's tasks |

## Run it from a fresh clone

Needs Docker Desktop with about 4 GB free, `uv`, and Flutter 3.44 with `python3` on the host.

```bash
services/assess-app/build.sh                                   # the exam app's bundle; dist/ is not in git
docker compose -f deployment/local/compose.yaml up -d --build  # first time: 5-10 minutes
uv sync --all-packages
uv run yantra seed                                             # demo data for every screen
uv run yantra smoke --with-storage                             # the whole loop; prints PASS
```

Then open http://localhost:8095. The users are `worker1`..`worker5`, `ops1`, `ops2`, `client1`, `client2`,
`admin1` and `noroles1`, all with password `yantra`. [USING.md](USING.md) §1 lists every port.

## State at handoff (16 Nov 2026)

Re-run on this date against the current tree:

| Check | Result |
|---|---|
| Python: `uv run pytest --cov` | all pass, 100% coverage (12,857 statements) |
| `ruff check`, `ruff format --check`, `mypy` (strict) | clean |
| App: `flutter analyze`, `flutter test` | clean, 686 pass |
| Exam app (vendored): `dart analyze`, `flutter test` | clean, 2,751 pass, 1 skipped |
| Odoo bridges inside Odoo 19 | 50 tests, 0 failed |
| `yantra vendor check`, `yantra realm-render --check` | current |
| `deployment/scripts/helm-check.sh` | chart, Argo CD apps and policies valid; alert rules pass |
| `yantra smoke --with-storage` on the rig | PASS |
| `yantra gate all` (ui, security, delivery-gate, money-parity, claim-storm) | all PASS except claim-storm latency; figures in [LAUNCH.md](LAUNCH.md) |

The restore drill was not re-run: it overwrites the rig's databases. It last passed on 5 Nov.

## Open items

- **Claim latency.** `yantra gate claim-storm` is correct at full load (0 double claims, 0 errors), but p99 is
  574 ms against a 500 ms target on a laptop VM (551 ms on 5 Nov). Rerun it on staging with autoscaling on.
- **Needs real infrastructure.** RazorpayX test mode, real email, image signing, the cluster install, Postgres
  point-in-time recovery and the production realm each need a step on staging. The steps are listed in
  [LAUNCH.md](LAUNCH.md) "Not proven on the rig".
- **The rig's password form skips two-factor.** "Use a password instead" on the sign-in page exists only on the local
  rig: it uses Keycloak's password grant, so staff sign in without a code. Staging and production turn it off
  (`DIRECT_LOGIN=false`, password grant off in the realm). To see the authenticator setup, sign in with "Continue with
  Keycloak".
- **Resetting an authenticator.** Deleting the entry from a phone app does not tell Keycloak, which keeps asking for a
  code. To get the QR code back, open the Keycloak admin (http://localhost:8180, realm `yantra`), go to Users, then
  the user, then Credentials, and delete the OTP credential.

## Ground rules

- **Vendored code** (Assessment v2's addon and exam app) is never edited in place. Add a numbered patch under its
  `vendor/patches`, then run `uv run yantra vendor sync …` and `uv run yantra vendor check`. See
  [../services/assess-app/README.md](../services/assess-app/README.md).
- **Tests run against the test NATS on port 4223**, never the rig's 4222. CI keeps Python coverage at 97% or more.
  Today it is 100%.
- **New UI uses the app's design tokens and widgets** (`app/lib/core/theme/portal_tokens.dart`,
  `app/lib/core/widgets/`), not colour literals.
