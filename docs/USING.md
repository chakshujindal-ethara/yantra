# Using Yantra on one machine

Everything in Stage 1 runs locally from one command. This page is the walk-through: start the rig, run the
proof, then use the product as the three people it serves (an operator, a worker, a reviewer) and as finance.

## 1. Start

Needs Docker Desktop, `uv` (`brew install uv`), Flutter 3.44 with `python3` on the host, and about 4 GB of free memory.

```bash
git clone git@github.com:EtharaLabs/yantra.git && cd yantra
services/assess-app/build.sh                                        # the exam app's web bundle (dist/ is not in git; the VM is too small to build it)
docker compose -f deployment/local/compose.yaml up -d --build      # first time: 5-10 minutes (Flutter and Odoo images)
uv sync --all-packages                                              # the CLI on the host
```

What comes up and where:

| Piece | URL | Sign in |
|---|---|---|
| The app (Flutter web; worker, operator and client consoles by role) | http://localhost:8095 | `worker1`..`worker5`, `ops1`, `ops2`, `client1`, `client2`, `admin1`, `noroles1` / `yantra` |
| Gateway (the only API clients use) | http://localhost:8090 | a Keycloak token |
| Keycloak (identity) | http://localhost:8180 | realm `yantra`; admin console `admin` / `admin` |
| Odoo (people and money, system of record) | http://localhost:8069 | `admin` / `admin` |
| Mailpit (every email the platform sends) | http://localhost:8026 | none |
| NATS monitor | http://localhost:8222 | none |
| Grafana (the Yantra overview dashboard; with the observability overlay, below) | http://localhost:3000 | anonymous viewer; `admin` / `admin` to edit |
| Prometheus (metrics and alert rules; same overlay) | http://localhost:9090 | none |

Metrics, alerts and the dashboard come up with one more file:
`docker compose -f deployment/local/compose.yaml -f deployment/local/compose.observability.yaml up -d`. The work and
money APIs have no host port (only the gateway may call them); `-f deployment/local/compose.dev.yaml` publishes them
for the load harness.

Every port is published on 127.0.0.1 only; nothing in the rig is reachable from the network. Users in the local realm: `ops1`, `ops2` (operators who also run finance: realm roles `ops` and `finance`), `worker1` to `worker3` (`worker` and `reviewer`), `worker4`, `worker5` (`worker`), `client1`, `client2` (`client`: a lab or vendor who sees only its own organisation's projects), `admin1` (`admin`: dead letters and job schedules) and `noroles1` (no application role), all with
password `yantra`. Their ids are fixed (`worker1` is `00000000-0000-4000-8000-000000000001`), so the steps below
are reproducible. Postgres is on 5440, Redis on 6390, the rig's NATS on 4222; a second NATS on 4223 exists only for
the test suite.

Sign-in on the rig. The app's password form (the rig builds it with `DIRECT_LOGIN=true`) and the CLI use the password
grant, with no second factor. **Continue with Keycloak** is the real flow: `ops1`, `ops2` and `admin1` are asked to
enrol an authenticator app on their first browser sign-in ("Configure OTP"; any TOTP app works) and for a code every
time after; workers and clients are not asked. Enrolling does not affect the password grant, so `yantra smoke` keeps
working. Anyone can create an account from the Keycloak sign-in page (**Register**): the new account is a `worker`
with no onboarding done (on the rig the email is not verified; Mailpit at http://localhost:8026 catches the mail a
deployed realm would send). `yantra login --device` signs the CLI in through the browser instead: open the printed URL,
confirm the code, sign in (the rig only: deployed realms turn the device grant off, and the staging smoke signs in
through its confidential `yantra-smoke` client).

`docker compose -f deployment/local/compose.yaml ps` shows every container; `down -v` wipes the data.

A worker's personal data. A worker asks for erasure from Profile (or `POST /v1/talent/workers/me/erasure`); it is
due in 30 days. Ops see the requests in `GET /v1/talent/erasures` and may approve one (`POST
/v1/talent/erasures/<worker_id>/approve`) to have it done within the hour. Then offboard the worker
(`PUT /v1/workers/<id>` with status `offboarded`) and disable the user in Keycloak (admin console, Users). Payment
and tax records stay; names, contact details and documents go. A changed policy text is a new version:
`PUT /v1/talent/policies/<slug>`; workers who accepted the old agreement are asked to accept the new one when they
next touch that step.

## 2. Prove it works

```bash
uv run yantra smoke
```

This logs in as five people and walks the whole loop through the gateway with real tokens: an operator seeds
workers, a project and a batch of three units; workers claim and submit (a second live claim is refused, a
retried key returns the same claim, the price is never shown to a worker); a reviewer accepts two units and
sends one back as the client's fault; money appears only on the canonical accept and the worker's inbox and
email follow; the delivery gate holds the batch on the one unit still open; finance closes a pay window, two
different finance people approve it, the window is paid line by line on the rail (on the rig, a WireMock stand-in
for RazorpayX), every paid line carries the bank's UTR, the window reconciles to the paisa and worker1's statement
can be exported. The workers' bank accounts are registered first and verified by the rail's penny drop within a
minute.
Then the unit sent back is redone by its author, accepted, and the delivery manifest is built. The last line is
`result PASS`. It can be run again any number of times; if a run is interrupted, a worker may keep a live claim
for up to its TTL (60 minutes), after which the next run succeeds again.

The Stage 1 launch gates are checks of their own, each printing PASS or FAIL with the figures that decided it
(results and dates in [LAUNCH.md](LAUNCH.md)). The load gates speak to the work and money services directly with
hundreds of synthetic workers, so start the rig with the development overlay first:

```bash
docker compose -f deployment/local/compose.yaml -f deployment/local/compose.dev.yaml up -d work money
uv run yantra gate all                      # claim-storm, money-parity, delivery-gate, security, ui
uv run yantra gate claim-storm --concurrency 32
uv run yantra gate money-parity --quick     # 10 workers and 100 units instead of 50 and 1,000
uv run yantra gate restore-drill --yes      # destructive: backs the rig up, restores it, runs the smoke
```

## 3. Use it

Every person uses the same app at http://localhost:8095; what it shows comes from the realm roles on the token
(a reviewer-lead who is both `ops` and `worker` gets both sets, grouped). `uv run yantra seed` fills a fresh rig
with a client organisation (client1 is a member), two projects with a published batch, an assessment paper, two
open listings, an applicant waiting on the paper, an offer waiting for its answer and a support ticket, so every
screen has something on it. Cmd/Ctrl+K opens a command palette on any page.

### The operator console (ops1, ops2)

| Destination | What is there |
|---|---|
| **Overview** | open units, live claims, review backlog with the oldest wait, first-pass acceptance, payable now, margin to date, the window's close; an attention list (flags, disputes, tickets, windows waiting for a second approval, batches under their floor) |
| **Projects** | every client project with its stage counts; create (schema, answer schema, rubric, margin floor, brief, LLM policy, sensitive flag, client organisation) and edit; a project shows batches with pay and bill side by side and the margin, reason codes on rework, the rubric log and client feedback; a batch has import with the dry-run report, publish (a floor breach asks who approved it), pause, resume, cancel, the units table and the delivery gate |
| **Listings** | pools workers apply to: title, domain, pay range, commitment, slots, the gate and the paper that opens it, the questions; the applications pipeline (applied, screening, offered, accepted) with offer and reject |
| **Papers** | assessment papers with their questions and answers; publish freezes them; sittings and pass rate |
| **Workers** | the bench: status, gates, availability, holds; set gates, change status, hold or lift |
| **Quality** | rubric flags to answer, disputes to decide, the review queue by stage with acceptance and reason codes |
| **Finance** | pay windows (close, lines, two approvals, pay on the rail, each line's state, retry or release a failed line, reconcile), adjustments proposed by one person and approved by another, the margin report |
| **Support** | tickets on a board: open, in progress, resolved |

### The client console (client1)

Overview across the organisation's projects (units accepted and in progress, acceptance rate, rework billed, deliveries, invoice total), each project with batch progress, reason codes on rework, the rubric version, deliveries (manifests with digest and totals) and a feedback thread. Clients see prices, never pay rates.

### The command line

The CLI remains the scriptable console. `yantra --help` lists every command; `--json` prints JSON.
Log in once per person; the session is kept in `~/.config/yantra/session.json`.

### As an operator (ops1)

```bash
uv run yantra login ops1 --password yantra
uv run yantra worker-set 00000000-0000-4000-8000-000000000001 --gates transcription    # worker1 may claim
uv run yantra project-create --name "Hindi transcription" --currency INR --cert-gate transcription \
  --margin-floor 0.3 --schema-json '{"type":"object","required":["text","language"],
  "properties":{"text":{"type":"string","minLength":1},"language":{"type":"string","enum":["hi","ta"]}}}'
uv run yantra batch-create <project_id> --title "Batch 1" --unit-pay 28 --unit-price 60 --review-pay 6
uv run yantra units-import <batch_id> --lines-file lines.json              # dry run: reports every bad line
uv run yantra units-import <batch_id> --lines-file lines.json --commit     # writes only when every line is good
uv run yantra batch-publish <batch_id>                                     # freezes pay and price on every unit
```

`lines.json` is a list of `{"external_ref": "...", "payload": {...}}` objects; the payload must match the
project's schema. `--answer-schema-json` on `project-create` is optional: when set, every submission's answer
must satisfy it (422 otherwise) and the app shows the schema on the batch. A batch under the project's margin floor publishes only with `--approved-by` and `--note`.

In Odoo the same worker is a record: Yantra > Workers > New (name, Keycloak subject, agreement, consent, bank
details, PAN, TDS rate, gates), then **Mark eligible**; Odoo pushes the eligibility to the gateway itself. The
local rig pre-seeds Odoo's settings (gateway, Keycloak client `yantra-odoo`); the admin user is in the Yantra
group already.

### As a worker (worker1)

Open http://localhost:8095. The sign-in page offers **Continue with Keycloak** (the browser goes to the identity
service and comes back signed in: authorization code with PKCE, the production path) and, in the local rig only,
**Use a password instead** (`worker1` / `yantra`). What the app then shows:

| Screen | What is there |
|---|---|
| **Home** | four numbers (pending for the next payout, units open to you, certifications, when the pay week closes), the live claim with its countdown, a "Ready to work" checklist (onboarding steps done of six, certifications) until the first claim is possible, offers waiting for an answer, and the open pools with the pay per accepted unit, the time per claim and the rubric version. **Claim a unit** opens the work screen. |
| **Explore** | every open listing as a card: domain, pay per accepted unit, commitment, slots left, "Prequalified" when you already hold the gate, where your application stands. A listing shows the requirements, the steps to apply (form, paper, availability), the LLM policy, and the apply form built from the listing's questions. |
| **Applications** | offers waiting for an answer (with their expiry), applications in progress with their step checklist and the paper to take, history; withdraw while screening. |
| **Onboarding** (from Home) | profile, agreement, DPDP consent, PAN and Aadhaar last four, bank account (the name must match the legal name) and the payout acknowledgement; "n of 6"; completing it makes you eligible. PAN and account numbers are kept as a hash and the last four digits only. |
| **Assessment** (from a listing or an application) | the paper's brief (duration, pass mark, attempts left), the timed sitting one question at a time with a countdown that submits at zero, the result and how many pools it unlocks. |
| **Work** | what you are given on the left, your answer on the right. When the project declares an answer schema the form is built from it (text, choices, numbers, yes/no, required fields) and the gateway validates the same schema on submit; otherwise free key/value fields or raw JSON. The countdown and **Submit** stay on screen. |
| **My work** | every unit you submitted: in review, accepted, needs edits or rejected, with the reason code, the reviewer's note, and whether the client caused it (billable rework, you are not at fault). A rejected or sent-back unit can be **disputed** once, within 14 days; a person decides and the decision is final. |
| **Review** | for reviewers: **Get next task** pulls the next submission (never your own), shows the payload and the answer side by side, and records accept, needs edits or reject with a reason code grouped by who is at fault; **Audit sample** pulls from the 10% audit queue. |
| **Earnings** | paid to date, what the next payout holds, what is in a closed window, holds; the last twelve pay weeks as bars; every pay window with its stage (closed, approved, paid, held) and bank reference; every earning; a CSV statement. |
| **Inbox** | verdicts, payouts and notices, grouped by day; tapping marks one read; the bell in the top bar counts the unread. |
| **Profile** | your status and certifications, the weekly availability check-in (hours per week, pause for a week, two weeks or a month: while paused you see no pools), the notification email (mail lands in Mailpit at http://localhost:8026), light or dark theme, the policies (pay cycle, disputes, LLM use, conduct, glossary), "Report a problem" (a support ticket the operators answer) and sign-out. |

The same from the terminal:

```bash
uv run yantra login worker1 --password yantra
uv run yantra me                                                    # profile, gates and availability (never 404)
uv run yantra availability --hours 20 [--paused-until 2026-11-10T00:00:00+05:30]   # weekly check-in; a pause hides every batch
uv run yantra batches
uv run yantra claim <batch_id>
uv run yantra unit <unit_id>
uv run yantra submit <claim_id> --answer-json '{"transcript": "..."}'
uv run yantra statement
uv run yantra inbox
```

### As a reviewer (worker2)

```bash
uv run yantra login worker2 --password yantra
uv run yantra review-claim                       # next task in queue order, never your own work
uv run yantra review-task <task_id>              # the unit's payload and the worker's answer
uv run yantra review-record <task_id> --verdict accept
uv run yantra review-record <task_id> --verdict needs_edits --reason client_glossary_change
uv run yantra review-claim --kind audit          # the 10% audit sample; the auditor's verdict wins
```

Reason codes: `guideline_miss`, `incomplete`, `wrong_language`, `low_quality` (the worker's), and
`client_glossary_change`, `client_ambiguous_instruction` (the client's: billable rework, the worker is not at fault).
A `needs_edits` verdict hands the unit back to its author (it reappears in their batches, theirs alone); a
`reject` returns it to the pool for anyone. Pay follows the accepted submission only.
`--rubric-unclear` with a note opens a flag that an operator answers (`yantra flags`, `yantra flag-answer`).

### As finance (ops1 and ops2)

```bash
uv run yantra login ops1 --password yantra
uv run yantra window-close --currency INR          # the last completed Saturday-to-Friday IST week
uv run yantra window-lines <window_id>             # one line per worker; held lines say why
uv run yantra window-approve <window_id>           # first approval (ops1 and ops2 hold the finance role)
uv run yantra login ops2 --password yantra && uv run yantra window-approve <window_id>   # a second person
uv run yantra window-pay <window_id>               # every payable line goes on the rail
uv run yantra rail-status                          # lines queued, processing, failed; when the jobs last ran
uv run yantra window-lines <window_id>             # each line: paid with its UTR, or failed with the reason
uv run yantra line-retry <window_id> <line_id>     # send a failed line again (a new attempt)
uv run yantra line-release <window_id> <line_id>   # or take it out: it rolls into the next window
uv run yantra reconcile <window_id>                # the live numbers; never adjusts
uv run yantra window-reconcile <window_id>         # a recorded run; the first balanced one releases statements
uv run yantra statement-export <window_id> --out statement.csv
uv run yantra margin                               # per batch: invoice, every cost line, margin
uv run yantra batch-manifest <batch_id>            # the delivery gate: 409 until every unit is accepted
```

A worker is paid only into a verified bank account: `yantra bank-account --name "Asha Rao" --number 123456789012
--ifsc HDFC0001234` (as the worker) registers it and the rail's penny drop verifies it within a minute; without
one the line is held `account_unverified`. A worker's first payout is held for seven days; `yantra hold
<worker_id> --reason integrity` holds one by hand, `yantra hold <worker_id>` lifts it. Held earnings roll into the
next window. The window closes on its own on Saturday 00:05 IST; `window-close` does it by hand.

The rig's rail is WireMock playing RazorpayX (http://localhost:8099/__admin/requests shows every call). Its
outcomes are decided by the input: an account number ending `0000` fails the penny drop, `1111` comes back with
another name; a line whose amount ends in `.13` paise fails (`insufficient_funds`), `.99` is returned
(`beneficiary_account_closed`); everything else is paid with a UTR. With `YANTRA_RAIL=file` the same window is
paid by bank file instead: `yantra bank-file <window_id> > payout.csv` for the bank, then the bank's return file
with `yantra bank-file-reconcile <window_id> --file returns.csv` (`reference,status,utr,reason`).

In Odoo, Yantra > Pay windows > **Pull paid windows now** (or the half-hourly cron) turns every paid line into a
draft vendor bill on the worker's partner with a TDS line at the worker's rate; the window shows
`reconciled` only when the bills equal the gateway's gross to the paisa. Yantra > Projects > batch > **Invoice
batch** draws the delivery manifest and creates the client invoice (accepted units × unit price).

### Activity and integrity (tracker)

While a claim is open on the work screen the app records one sample every 30 seconds (active, idle or away);
`GET /v1/tracker/policy` is what the worker reads about it. A worker sees their week with `yantra track-sessions`;
an operator sees anyone's with `--worker-id`. The detectors run every five minutes; `yantra seed` gives worker2
and worker3 one device id, so the next scan flags both:

```bash
uv run yantra login ops1 --password yantra
uv run yantra anomalies                                         # open flags, oldest first
uv run yantra anomaly-decide <anomaly_id> --outcome uphold --note "same household"   # holds the worker's payouts
uv run yantra anomaly-decide <anomaly_id> --outcome dismiss
```

Weekly caps: `PUT /v1/tracker/caps/worker/<id>` or `/project/<id>` with `{"weekly_cap_hours": "20"}` (default 40).

### Leadership numbers (analytics)

Every event lands in the analytics warehouse; the marts refresh every five minutes.

```bash
uv run yantra leadership                     # the four numbers against their baselines, margin per unit, the watch list
uv run yantra baselines-set --days-to-staff 6 --first-pass-acceptance 0.72 --idle-hourly-cost 150 --note "Q3"
uv run yantra jobs analytics                 # when the marts last refreshed
```

An admin replays the stream into a fresh consumer with `POST /v1/analytics/rebuild` (`?mode=purge` also drops the
warehouse rows the stream still holds); `GET /v1/analytics/rebuild` shows it running and then `done`.

### Stored media and stuck work

MinIO runs on the rig: the API on http://localhost:9000 (yantra / yantra-local-secret), bucket `yantra`. This MinIO
version has no web console (port 9001 answers nothing); list objects with
`docker compose -f deployment/local/compose.yaml exec -T minio sh -c "mc alias set local http://localhost:9000 yantra yantra-local-secret >/dev/null && mc ls --recursive local/yantra"`. `uv run yantra smoke --with-storage` adds a leg that uploads a clip through a
presigned link, imports it, opens it from a worker's claim and gives the claim back.

As admin1 or ops1: `uv run yantra stuck` lists claims and reviews past their time and what was released in the last
week; `uv run yantra stuck-release <claim id>` (or `--kind review <task id>`, or `all`) releases them now. The
expiry jobs release them within a minute anyway. `uv run yantra attention` is the ops attention list in one call;
`uv run yantra reasons`, `uv run yantra reviewer-set <worker id> --sensitive-cleared` and `uv run yantra
deliverable <batch id>` cover the reason taxonomy, sensitive clearance and a batch's files.

## 4. Stop, reset, update

```bash
docker compose -f deployment/local/compose.yaml stop                 # keep the data
docker compose -f deployment/local/compose.yaml down -v              # wipe everything
docker compose -f deployment/local/compose.yaml up -d --build        # after a code change: rebuild and restart
uv run yantra realm-render                                           # after editing deployment/keycloak/*: regenerate
```

A realm change reaches Keycloak only on a fresh database (the import runs once): `down -v`, or reset Keycloak alone
with `docker compose -f deployment/local/compose.yaml rm -sf keycloak`, then
`docker compose -f deployment/local/compose.yaml exec postgres psql -U yantra -d postgres -c 'DROP DATABASE keycloak'
-c 'CREATE DATABASE keycloak'` and `up -d keycloak`.

Tests and the engineering gate are in [DEVELOPING.md](DEVELOPING.md). What Stage 1 does not do yet is listed there too.
