# Yantra, the whole product

What the platform is for every person who uses it, surface by surface, and the contract the app and the
services meet on. Every builder reads this first. The engineering rules are in [DEVELOPING.md](DEVELOPING.md);
how to run it is in [USING.md](USING.md).

## 1. Three people, one app, six roles

| Role (Keycloak realm role) | Who | What they do in the app |
|---|---|---|
| `worker` | a contractor on the bench | explore pools, apply, sit the paper, finish onboarding, claim and work units, get paid, raise disputes and support tickets |
| `reviewer` | a worker trusted to judge others' work (always also `worker`, for pay) | claim review and audit tasks, record verdicts with reason codes |
| `ops` | an operator or reviewer-lead | run projects, batches and listings; screen applicants; answer flags, disputes and tickets; hold an account; read the money pages |
| `finance` | finance (usually also `ops`) | close, approve and pay the weekly window, the bank file, reconciliation; decide adjustments; watch margin |
| `admin` | the platform's operator | read and replay dead letters, read the job schedules |
| `client` | a lab or vendor buying work | see their projects' throughput, acceptance and quality, download deliveries, read invoice totals, send feedback |

One Flutter codebase serves all of them; the shell picks the destinations from the token's realm roles. A
person may hold several roles (a reviewer-lead is `ops`, `reviewer` and `worker`): the shell shows every
destination they may use, grouped by role. `admin` does not imply `ops` or `finance`; a pay window still needs
two different `finance` people.

## 2. Services (code modules) and who owns what

| Module | Schema | Owns |
|---|---|---|
| `market` | `market` | projects, batches, units, claims, submissions, worker read model (status, gates, availability), the delivery manifest, verdict log (a read model of every canonical verdict), client organisations and the client console |
| `talent` (new) | `talent` | listings (pools a worker can apply to), applications and offers, the onboarding checklist, the worker's eligibility event |
| `assess` (new) | `assess` | assessment papers, sittings, scoring, the certification event |
| `quality` | `quality` | review tasks, verdicts, flags, disputes, stats |
| `payout` | `payout` | earnings, pay windows, holds, adjustments (two-person), margin, the ops overview |
| `notify` | `notify` | inbox, email channel, support tickets |
| `tracker` (new) | `tracker` | activity sessions while a claim is open, 30-second samples, weekly hour caps, anomaly flags (an upheld flag holds payouts), screenshot references for a future desktop agent, the live-claim read model |
| `analytics` (new) | `analytics` | the event warehouse (every event, once), marts recomputed from it, the leadership numbers against their baselines, the rebuild drill; emits nothing |

All of `market`, `talent`, `assess`, `quality`, `notify`, `tracker`, `analytics` run in the `work` deployable;
`payout` in `money`.
The gateway routes `/v1/payout/*` to `money`, everything else to `work`.

## 3. Identity at the edge

The gateway sets three trusted headers. `X-Worker-Id` is the caller's subject. `X-Role` is the caller's realm
roles joined by commas, in a fixed order: `admin,ops,finance,reviewer,client,worker` (a plain worker has
`X-Role: worker`); the gateway always sends it, an empty string when the token carries no known role, so a missing
header never reads as "no role". `yantra_common.deps` offers one factory, `require_any(*roles, message=...)`, and
the guards built from it: `Ops`, `Finance` (finance only), `FinanceOrOps` (the money pages; Odoo's service account
holds `ops`), `Reviewer` (reviewer or ops), `Admin`, `AdminOrOps` (dead letters and jobs), `ClientRole` (client or
ops), `Worker` (worker or ops: an operator may walk the worker flow in the rig) and `Roles` (the set). Every worker
surface carries `Worker`: batches with their pay, claims, submissions, units, `workers/me` and availability,
listings, applications and offers, onboarding, briefs and sittings, my-work and disputes, the inbox and the email
channel. Review and audit claims, the held task and recording a verdict carry `Reviewer`. A `client`-only token is
refused all of them; support tickets stay open to any signed-in role.

| Route | Guard |
|---|---|
| `GET /v1/payout/windows`, `…/{id}`, `…/lines`, `GET …/reconcile`, `/reconciliation-runs`, `/margin`, `/overview`, `/rail`, `/attention`, `/accounts` (held), `/accounts/{id}`, `GET /adjustments`, `POST /adjustments` (propose) | `FinanceOrOps` |
| `POST /v1/payout/windows/close`, `…/approve`, `…/pay`, `…/lines/{id}/retry` and `/release`, `GET …/bank-file`, `POST …/bank-file/reconcile`, `POST …/reconcile`, `POST /adjustments/{id}/approve` and `/reject`, `POST /accounts/{id}/confirm` | `Finance` |
| `PUT` and `GET /v1/payout/accounts/me` (the worker's bank account) | `Worker` |
| `GET /v1/payout/statement` (the caller's own) | worker, reviewer or ops |
| `GET /v1/payout/statements/{window_id}/export` | worker, ops or finance (a worker gets their own line) |
| `POST /v1/payout/webhooks/razorpayx` | no caller: the gateway forwards it without a token; money checks the HMAC signature |
| `PUT /v1/payout/accounts/{id}/hold` | `Ops` (trust and safety) |
| `POST /v1/quality/reviews/claim`, `GET /reviews/active`, `GET /tasks/{id}`, `POST /tasks/{id}/review` | `Reviewer` |
| `GET /v1/<module>/dead-letters`, `POST …/{id}/replay`, `GET /v1/<module>/jobs` (market, talent, assess, quality, notify, payout) | `AdminOrOps` |

`X-Email` (percent-encoded) and `X-Email-Verified` (`true` or `false`) carry the token's email, absent when it has
none; the assess module passes them to Assessment v2, which binds a worker to an existing account by email only when
Keycloak verified it. A client cannot set them either.

`X-Name` is the caller's display name from the token (`name`, else `preferred_username`), cleaned, capped at 120
characters and percent-encoded UTF-8 (a header is ASCII; a name may be Devanagari); absent when the token has none.
A client cannot set it: only the gateway's own headers reach a service. Talent records each person on first sight
and announces `talent.person.seen.v1`; market and notify keep a `person` read model from it, so lists carry names
(`worker_name`, `author_name`) with one query. A worker's legal name (onboarding profile) replaces the token name for
good; erasure forgets it everywhere.

Sign-in. The app uses the authorization code flow with PKCE; the password grant is off on `yantra-app` outside the
local rig (the rig keeps it for the CLI and the app's direct login, through a username-and-password-only direct-grant
flow). The CLI signs in anywhere with `yantra login --device` (RFC 8628, PKCE). The browser flow `browser-mfa` asks
for a TOTP code from anyone holding the internal `mfa-required` role, which `ops`, `finance` and `admin` carry: their
first browser sign-in enrols an authenticator app (Keycloak's "Configure OTP" page); workers and clients are never
asked. `mfa-required` and Keycloak's own roles never reach a service (the gateway forwards known roles only). Access
tokens live 15 minutes, a session at most 24 hours, no offline tokens. Self-registration is on with email
verification; a new account holds `worker`. Brute-force detection locks an account for a growing interval after ten
failures (deployed realms).

Local realm users, all with password `yantra`: `ops1`, `ops2` (`ops`, `finance`), `worker1`..`worker3`
(`worker`, `reviewer`), `worker4`, `worker5` (`worker`), `client1`, `client2` (`client`, ids
`00000000-0000-4000-8000-0000000000c1`, `...c2`), `admin1` (`admin`, id `...00000000ad01`) and `noroles1` (no
application role, id `...00000000ad02`: what a fresh account sees before anyone grants it a role).

## 4. Screens

### 4.1 Worker

| Destination | What is on it |
|---|---|
| Home | four numbers, the "ready to work" checklist (onboarding + first certification), the live claim, open pools, offers waiting for an answer |
| Explore | every open listing as a card: title, domain chip, pay per accepted unit (range), commitment, slots left, "prequalified" when the worker already holds the gate, the worker's application state. Filters by domain and commitment. A listing opens its detail: description, requirements, what the steps are (form, paper, availability), the LLM policy and the sensitive-content note, a sticky apply card. |
| Applications | the worker's applications with their step checklist (n of m), offers with expiry countdown and accept/decline, history |
| Assessment (route) | the paper's brief (duration, question count and types, pass mark, attempts left, what proctoring asks for: camera, full screen, AI proctor, Safe Exam Browser), Start / Resume in the Assessment app (same tab, no second password), then back in Yantra the result (awaiting result and why, certified, not passed with attempts left; a retake is a fresh paper) |
| Onboarding (route) | grouped checklist: Profile (legal name, phone, city), Documents (agreement, DPDP consent), Identity (PAN, Aadhaar last four), Payment (the bank account, registered with the payout module and verified by the rail's penny drop: verifying, verified or failed with the reason; the name on the account must equal the legal name; payout policy acknowledgement); "n of 6", finish-later, what is still blocking the first claim |
| My work, Review, Earnings, Inbox, Profile | as today; Profile adds "Report a problem" (a support ticket with the screen auto-filled) and "My tickets" |
| Activity (card on Home and My work) | hours this week against the cap (a progress bar; "over the cap" when it is), the week's sessions (claim, started, active and idle minutes, how it ended); Profile carries "What we track" from `GET /v1/tracker/policy` |

### 4.2 Ops

| Destination | What is on it |
|---|---|
| Overview | the numbers: open units, live claims, review backlog and its oldest age, first-pass acceptance, payable now, margin to date; eligible/paused workers; attention list (flags open, disputes open, tickets open, batches under the floor, windows waiting for a second approval) |
| Projects | list with status, batches, units by stage; create (name, currency, cert gate, payload schema, answer schema, rubric version, margin floor, brief, LLM policy, sensitive flag, client org); detail with batches, verdict reasons, client feedback, a 30-day trend (published, accepted, first pass, margin; `GET /v1/analytics/projects/{id}/trend`); edit |
| Batch (route) | counts by status, live claims, create, import with the dry-run report (every bad line and why), publish (floor warning and the recorded approval), pause/resume/cancel, units table, the manifest and the delivery gate |
| Listings | list; create/edit (title, domain, summary, description, pay range, commitment, hours, slots, cert gate, paper, closes at, requirements, steps); applications pipeline per listing (applied → screening → offered → accepted), decide (offer/reject with a note) |
| Papers | assessment papers over Assessment v2: list (gate, v2 assessment, status, attempts, passed / total, awaiting release, pass rate), create by linking an assessment built in the Assessment admin or writing a quick one (one- and several-answer questions), publish (v2's launch gates), the paper (snapshot, cohorts, sittings with status, score, flags and held reason), release, rotate, sync now, "Open in Assessment admin" |
| Workers | the bench: every worker with status, gates, availability, onboarding state, held or not; set gates, hold/lift, offboard |
| Quality | flags to answer, disputes to decide, review queue by batch, acceptance and reason codes; an **Integrity** tab: tracker anomalies oldest first (kind, worker, detail in words, when), dismiss or uphold with a note (upholding puts a payout hold on the worker), each worker's sessions one click away; weekly caps per worker or project |
| Leadership (ops, finance, admin) | the four numbers against their baselines (days to staff a batch, idle bench cost a week, first-pass acceptance, cost per accepted unit), each with what it is made of and the page that explains it; gross margin per accepted unit per project; the watch list (pay windows on time, integrity cases per 1,000 eligible workers, incidents waiting); a 30-day trend; the baselines form (ops) |
| Finance | pay windows (close by hand or wait for the Saturday 00:05 IST close; lines with their hold reasons; approve as first and second finance person; pay: every payable line goes on the rail; each line's rail state (queued, processing, paid with the bank's UTR, failed or returned with the reason); retry a failed line or release it into the next window; under the bank-file rail, the NEFT/IMPS file and the upload of the bank's return file), reconciliation runs (earnings, lines, paid, what the rail moved; a run that does not balance opens a payment ticket), statements released after reconciliation, the rail's state, caps (per worker, per window), adjustments (propose a bonus or correction; a different finance person approves), margin per batch, holds |
| Support | tickets board (open, in progress, resolved) |
| Inbox, Profile | as the worker's |

### 4.3 Client

| Destination | What is on it |
|---|---|
| Overview | across the org's projects: units delivered, accepted, in progress, acceptance rate, rework billed to the client, next delivery |
| Projects | each project: batches with progress bars (available / in progress / in review / accepted), acceptance rate, reason codes on rework, rubric version, deliveries (manifests with digest and totals), invoice total to date (accepted × price + billable rework), feedback thread |
| Deliveries | every manifest of the org, downloadable |
| Profile | theme, sign out |

Prices are shown to clients and ops only. Pay is shown to workers and ops only. A worker never sees a
price; a client never sees a pay rate.

## 5. The contract: new endpoints

Every mutation needs the gateway's `Idempotency-Key`. Money and dates are strings as everywhere else.
Errors use the common envelope `{code, message, request_id}`.

### 5.1 market

| Method and path | Role | Body / result |
|---|---|---|
| `GET /v1/projects` | ops | `[ProjectSummary]`: `{id, name, currency, status, cert_gate, rubric_version, margin_floor, client_org_id, batch_count, units: {total, available, claimed, submitted, in_review, accepted, rejected, needs_edits}, created_at}` |
| `GET /v1/projects/{id}` | ops | `ProjectDetail`: ProjectSummary + `payload_schema, answer_schema, brief, llm_policy, sensitive, batches: [BatchSummary], reasons: [{reason_code, count, billable}], feedback: [{id, author_id, body, created_at}]` |
| `PATCH /v1/projects/{id}` | ops | any of `name, status (draft|active|closed), rubric_version, margin_floor, cert_gate, brief, llm_policy, sensitive, client_org_id, answer_schema` → ProjectDetail. A rubric bump appends to `rubric_log: [{version, note, at}]`. |
| `GET /v1/batches/{id}` | ops | `BatchSummary`: `{id, project_id, project_name, title, mode, status, unit_pay, unit_price, review_pay, currency, claim_ttl_minutes, rubric_version, floor_approved_by, published_at, units: {...counts as above}, live_claims, manifest: {id, digest, accepted_units, total_price, created_at} | null}` |
| `GET /v1/batches/{id}/units?status=&limit=50&offset=0` | ops | `{total, items: [{id, external_ref, status, assigned_worker_id, current_claim_id, created_at}]}` |
| `POST /v1/batches/{id}/pause`, `/resume`, `/cancel` | ops | → BatchSummary. Pause hides the batch from workers; in-flight claims may still be submitted. Cancel only with zero live claims: a claim in flight holds the batch row shared, so cancel runs strictly before it (the claim then finds the batch closed) or after it (and counts it). A submission on a cancelled batch is 409 `batch_cancelled`. |
| `GET /v1/workers?status=&gate=&q=&limit=50&offset=0` | ops | `{total, items: [WorkerRow]}`, `WorkerRow = {id, status, cert_gates, partner_ref, availability: {weekly_hours, paused_until} | null, updated_at}` |
| `GET /v1/workers/{id}` | ops | WorkerRow |
| `POST /v1/client-orgs` | ops | `{name}` → `{id, name, created_at}`; `GET /v1/client-orgs` → list with `members: [user_id]` |
| `PUT /v1/client-orgs/{id}/members/{user_id}` / `DELETE` | ops | membership |
| `GET /v1/client/overview` | client | `{orgs: [{id, name}], units: {...counts}, acceptance_rate, billable_rework, deliveries: n, invoice_total: {currency: amount}}` across the caller's orgs |
| `GET /v1/client/projects` | client | `[ClientProject]`: `{id, name, currency, status, rubric_version, units: {...counts}, acceptance_rate, invoice_total}` |
| `GET /v1/client/projects/{id}` | client | ClientProject + `batches: [{id, title, status, unit_price, units: {...}, manifest}], reasons: [...], deliveries: [manifest], feedback: [...]` |
| `POST /v1/client/projects/{id}/feedback` | client | `{body}` → feedback row |
| `GET /v1/client/batches/{id}/manifest` | client | the manifest (membership checked) |

Verdict log: market consumes `quality.verdict.accepted.v1` and `.rejected.v1` (it already does) and now also
writes `verdict_log(unit_id, batch_id, project_id, worker_id, verdict, reason_code, billable, at)`, which the
reason distributions and acceptance rates read.

Gates and eligibility: market consumes `assess.certified.v1` (adds the gate to the profile, creating the
profile as `unknown` if absent), `talent.offer.accepted.v1` (adds the listing's gate when the listing has
no paper) and `worker.eligible.v1` (sets status `eligible` when it was `unknown`). Odoo's `PUT /v1/workers/{id}` keeps working;
when it sends `cert_gates`, that list **replaces** the gates set by hand before (gates earned from a paper or an offer
always stay) and market emits `worker.gates.set.v1` with that list and a per-worker `seq`, so quality applies hand-sets
in order and replaces its own hand-set copy the same way. Nobody sets their own record (403 `self_action`).
Consent: market consumes `worker.consent.withdrawn.v1` (a new claim is 403 `consent_withdrawn`) and
`worker.consent.given.v1` (claims open again), applied in event time so a late, older event changes nothing.

#### Stored media, the deliverable, stuck work and the rest (market)

Object storage is MinIO in every environment (S3-compatible, signed with Signature Version 4). A unit's media live
under `projects/<project>/units/<upload>/<name>`; links are presigned for five minutes and never logged. Routes that
need storage answer 503 `storage_unconfigured` on a deployment without it.

| Method and path | Role | Body / result |
|---|---|---|
| `POST /v1/batches/{id}/payload-uploads` | ops | `{files: [{name, content_type: audio|image|video/*, application/pdf, text/plain, size_bytes ≤ 512 MiB}]}` (1..500) → `{uploads: [{name, key, ref, url, method: PUT, headers, expires_at, max_bytes}]}`; PUT the bytes to `url` with `headers`, then put `ref` (`s3://<bucket>/<key>`) in the import line's payload. `size_bytes` is exact: the URL is signed for that `content-length` and storage refuses a body of another size. `image/svg+xml` is refused (422). 409 `batch_not_draft` |
| `POST /v1/batches/{id}/units/import` | ops | as before; a payload string that looks like stored media (`s3://…`, `projects/…`) must name an object under this project (line error `payload: <field>: ref outside the project`); the first such key is kept on the unit |
| `GET /v1/units/{id}/payload-url` | worker holding a live claim on the unit, or ops | `{url, expires_at}`; 404 for anyone else and 404 `no_payload_object` when the unit has no media |
| `GET /v1/batches/{id}/deliverable` | ops | behind the manifest gate (409 `batch_held` first). Writes `units.jsonl` (one accepted unit per line: `external_ref, unit_id, payload, payload_ref, answer, rubric_version, submitted_at, rework: [{verdict, reason_code, billable, at}], payload_sha256, answer_sha256`) and `manifest.json` (the manifest, `lines_sha256`, `line_count`) to storage once, then presigns: `{manifest_id, batch_id, digest, jsonl: {url, expires_at, sha256, bytes, line_count}, manifest: {url, expires_at}}` |
| `GET /v1/client/batches/{id}/deliverable` | client (own org) | the same; 404 before the manifest exists or for another org's batch. Both answer 410 `batch_purged` once retention emptied the batch and no files were written before |
| `POST /v1/claims/{id}/release` | worker (own live claim) | → Claim `status: released`; the unit is available again (an assignment stays); `work.claim.released.v1`. 403 another worker's, 409 `claim_not_live` |
| `GET /v1/claims/expired` | admin, ops | stuck work: live claims past their time, oldest first, `[{claim_id, unit_id, external_ref, batch_id, batch_title, project_id, project_name, worker_id, worker_name, expires_at, minutes_overdue}]` |
| `POST /v1/claims/{id}/submission` | worker (own claim) | as before; a claim that is no longer live (released, expired by the job) is 409 `claim_not_live`, one past its time but not yet released 409 `claim_expired` |
| `POST /v1/batches/{id}/claims` | worker | as before; 403 `consent_withdrawn` while the worker's data-processing consent is withdrawn |
| `POST /v1/units/{id}/unassign` | admin, ops | `{assign_to: worker_id | null}` (body optional) → `{id, batch_id, status, assigned_worker_id, assigned_at, unassigned_by, unassigned_at}`: an available unit waiting for its assigned worker (a rework author who left or is held) goes back to the pool, or to `assign_to`; signed by the caller. 409 `unit_not_assigned`; 409 `assignment_required` in an assigned-mode batch without `assign_to` |
| `GET /v1/units/stuck-assigned?days=3` | admin, ops | available units waiting more than `days` for their assigned worker, longest first: `[{unit_id, external_ref, batch_id, batch_title, project_id, project_name, worker_id, worker_name, assigned_at, days_waiting}]` |
| `POST /v1/claims/{id}/release-expired` | admin, ops | one stuck claim back to the pool, signed by the caller; 409 `claim_not_expired` unless live and past its time |
| `POST /v1/claims/release-expired` | admin, ops | every stuck claim now (the expiry job does the same every 30 s), signed by the caller → `{released, more}` |
| `GET /v1/claims/released?days=7` | admin, ops | claims that ended without a submission, newest first: `[{claim_id, unit_id, batch_id, worker_id, worker_name, status: expired|released, expires_at, released_at, released_by (null: the expiry job), released_by_name}]` |
| `GET /v1/people?ids=a,b` | ops, finance, admin; client | `{<id>: {name, kind}}` for up to 200 ids; a client sees only members of their own orgs; unknown ids are left out |
| `GET /v1/workers/summary` | ops | `{total, unknown, eligible, active, suspended, offboarded, paused, held}` |
| `GET /v1/workers`, `/workers/{id}` | ops | WorkerRow gains `name` (from `talent.person.seen`), `onboarded` (past `unknown`), `held`, `hold_until` (from `payout.hold.set`) |
| `POST /v1/projects/{id}/feedback` | ops | `{body}` → FeedbackOut `{id, author_id, author_kind: staff, author_name, body, created_at}`; the client's notes are `author_kind: client`; both threads carry `author_name` |
| `PATCH /v1/batches/{id}` | ops | `{title?, due_at? (null clears)}` → BatchSummary; 409 on a cancelled batch. `due_at` may also be sent on create; BatchSummary and the client's batches carry `due_at` and `purged_at` |
| `POST/PATCH /v1/projects` | ops | `retention_days` (1..3650, default 180); a project moved to `closed` records `closed_at` (cleared when reopened) |
| `GET /v1/client/overview` | client | + `next_delivery: {batch_id, title, project_id, project_name, due_at, accepted, total} | null`: the open batch due first |
| `GET /v1/attention` | admin, ops | one view across the work modules: `expired_claims, batches_under_floor, stuck_assigned_units (waiting over 3 days), review_backlog, oldest_pending_at, flags_open, flags_overdue, disputes_open, expired_reviews, applications_screening, erasures_pending, erasures_due, tickets_open, tickets_in_progress, dead_letters: {<schema>: n}` (payout's share is on money) |

Retention: the daily `market_retention_purge` job (03:30 IST) empties a completed batch's unit payloads, answers and
manifest unit list, and deletes its stored media and deliverable, `retention_days` after delivery (after creation
for a cancelled batch). Counts, digests, totals and the verdict log stay, so invoices still add up; it emits
`work.batch.purged.v1` and quality drops its copies. A media object another batch's unit still names is kept. Each
batch is its own transaction (up to 500 a run): one that fails is rolled back, logged by id and retried the next day,
and the rest go on.

### 5.2 talent (new, `/v1/talent/...`)

| Method and path | Role | Body / result |
|---|---|---|
| `GET /v1/talent/listings` | worker | open listings: `[Listing + viewer: {prequalified, application_id, application_status}]` |
| `GET /v1/talent/listings/{id}` | worker | one, same shape (closed listings 404 for workers) |
| `POST /v1/talent/listings/{id}/applications` | worker | `{answers: {...}}` (the form step) → Application. 409 `already_applied`, 409 `listing_full`, 422 when a required question is missing |
| `GET /v1/talent/applications/me` | worker | `[Application]` |
| `POST /v1/talent/applications/{id}/withdraw` | worker | → Application |
| `POST /v1/talent/applications/{id}/offer` | worker | `{accept: true|false}` → Application; 409 `offer_expired`; accept emits `talent.offer.accepted.v1` and fills a slot |
| `GET /v1/talent/workers/me/onboarding` | worker | `Onboarding` |
| `PUT /v1/talent/workers/me/onboarding/{step}` | worker | step bodies below → Onboarding; completing the last step emits `worker.eligible.v1` |
| `POST /v1/talent/listings` | ops | ListingIn → Listing |
| `PATCH /v1/talent/listings/{id}` | ops | partial ListingIn (status `draft|open|closed` included) → Listing |
| `GET /v1/talent/listings?all=true` | ops | every listing with `applications: {applied, screening, offered, accepted, rejected}` counts |
| `GET /v1/talent/listings/{id}/applications?status=` | ops | `[Application + worker_id]` |
| `POST /v1/talent/applications/{id}/decide` | ops | `{decision: offer|reject, note, offer_days: 7}` → Application |
| `GET /v1/talent/onboarding?status=` | ops | `[{worker_id, complete, steps_done, updated_at}]` |
| `PUT /v1/talent/workers/me/onboarding/bank` | worker | moved: 409 `bank_moved {location: "/v1/payout/accounts/me"}`; the step completes when payout verifies the account |
| `PUT /v1/talent/workers/me/onboarding/consent` | worker | `{accepted: false}` withdraws consent: the step reopens, the worker is no longer eligible (`eligible_sent_at` cleared; `worker.eligible.v1` goes out again once the checklist is complete), `worker.consent.withdrawn.v1` (tracker ends the open session and refuses sessions, samples and screenshots with 403 `consent_withdrawn`; market and payout block claims and payouts). Consent given when there was none emits `worker.consent.given.v1` (every block lifts) |
| `POST /v1/talent/workers/me/documents/presign` | worker | `{kind: identity_front|identity_back|address_proof|signed_agreement, content_type: image/jpeg|image/png|application/pdf, size_bytes ≤ 10 MiB}` → `{key, url, method: PUT, headers, expires_at, max_bytes}`: the browser PUTs the file to storage with those headers |
| `PUT /v1/talent/workers/me/documents/{kind}` | worker | `{key, sha256, size_bytes}` → Document `{kind, sha256, size_bytes, content_type, uploaded_at}`; 422 `key_not_yours` (not under `workers/<me>/documents/<kind>/`), `object_missing`, `size_mismatch` (the object is deleted); a replacement deletes the old object |
| `GET /v1/talent/workers/me/documents` | worker | `[Document]` |
| `GET /v1/talent/workers/{id}/documents`, `GET …/{kind}/url` | ops | the list; a five-minute download link `{url, expires_at}` (issuing one is logged with the ids) |
| `PUT /v1/talent/people/me` | any | `{id, name, kind: worker|staff|client}`; the app calls it once per session so a staff or client name is known (404 when the token carries no name) |
| `GET /v1/talent/policies`, `GET /v1/talent/policies/{slug}?revision=` | any | the current version of every policy (or one, or an older revision): `Policy = {slug, version, revision, title, summary, sections: [{title, paragraphs: [str], bullets: [str]}], updated_at}`. Slugs: `contractor-agreement`, `dpdp-consent`, `pay-cycle`, `disputes`, `llm-use`, `conduct`, `tracking`, `glossary` |
| `PUT /v1/talent/policies/{slug}` | ops | `{title, summary, sections, label?}` → a new version (never an edit); `label` is what workers accept (the revision number when absent) |
| `POST /v1/talent/workers/me/erasure` | worker | 201 `Erasure {worker_id, status: requested|approved|done, requested_at, due_at, approved_at, approved_by, done_at}`, due 30 days later; 409 `erasure_pending` / `erasure_done`. Erased: name, phone, city, Aadhaar last four, the account-name digest, every application's `answers`, every object under `workers/<id>/` in storage (listed, so an upload never registered goes too); kept: ids, the PAN digest and last four, the agreement and consent records. On `worker.erasure.completed.v1` notify blanks the worker's tickets and email, tracker deletes their samples, screenshots and device ids, analytics replaces their id with a pseudonym |
| `GET /v1/talent/erasures?status=`, `POST /v1/talent/erasures/{worker_id}/approve` | ops | the list; approve brings it forward to the next hourly pass |
| `GET /v1/talent/attention` | ops | `{applications_screening, erasures_pending, erasures_due}` |

```
Listing = {id, title, domain, summary, description, pay_min, pay_max, pay_unit: "per_unit", currency,
           commitment: "task_based" | "part_time", hours_per_week, slots_total, slots_filled, cert_gate,
           paper_id, requirements: [str], questions: [{key, prompt, kind: "text"|"choice", options?, required}],
           llm_policy, sensitive, steps: [form|paper|availability], status, posted_at, closes_at, created_at,
           hired_this_week}
  steps: always `form`; `paper` exactly when the listing has a paper; `availability` when ops choose it (by default
         with a paper). hired_this_week: offers accepted in the last seven days.
Application = {id, listing_id, listing_title, worker_id, status: applied|assessment|screening|offered|accepted|
               declined|rejected|withdrawn|expired, steps: [{kind: form|paper|availability, status: pending|done|failed}],
               answers, note, offer_expires_at, decided_by, created_at, updated_at,
               worker_name (ops list), paper: {status: passed|failed, score, at, attempts_left?} | null}
Onboarding = {complete, eligible_sent_at, steps: [{key, status: pending|done, done_at, group}], agreement_version,
              consent_version, documents: [{kind, uploaded_at}], erasure: Erasure | null}
  keys and groups: profile (Profile), agreement (Documents), consent (Documents), identity (Identity), bank (Payment), payout_ack (Payment)
  bodies: profile {legal_name, phone, city}; agreement {accepted: true, version}; consent {accepted: bool,
          version?}; identity {pan, aadhaar_last4}; payout_ack {accepted: true}. The bank account is given to payout
          (`PUT /v1/payout/accounts/me`); talent marks `bank` done on `payout.account.verified.v1` when the
          account name equals the legal name.
  rules: PAN format ABCDE1234F; one PAN per person (409 pan_in_use, the PAN is stored as a keyed hash + last four);
         the agreement's `version` must be the current `contractor-agreement` version and a given consent version
         the current `dpdp-consent` one (422 policy_outdated with `latest`); once `bank` is done the legal name may
         not change away from the verified account name (422 name_mismatch); a verified account in another name
         leaves `bank` pending until the profile name matches; steps may be done in any order. Documents are not
         required to finish the `identity` step in Stage 1 (`documents` lets the app nudge).
```

Application flow: `applied` → if the listing has a paper and the worker lacks the gate: `assessment` (the
`paper` step is done when `assess.certified.v1` for that gate arrives, then `screening`); else `screening`
→ ops decides → `offered` (expires after `offer_days`) → `accepted` | `declined` | `expired`. `rejected` and
`withdrawn` end it. Every status change emits `talent.application.moved.v1` (the funnel). A failed sitting
(`assess.failed.v1`) is kept on the application as `paper`; with no attempts left the `paper` step shows `failed`.
Slots: `slots_filled` counts accepted; a full listing refuses new applications.
Prequalified: the worker already holds `cert_gate` (talent keeps a `worker_gate` read model from
`assess.certified.v1` and its own accepted offers).

### 5.3 assess (`/v1/assess/...`): Yantra's side of Assessment v2

The exam runs in Ethara's Assessment v2 (the `assessments_be_v2` Odoo addon and its Flutter app, the
*Assessment app*, on :8096 on the rig). Every v2 feature is available to a paper: all question types (one and several
answers, rubric-marked written answers, image A/B rating, image prompts and annotation, video prompts, Hindi/English
transcription), papers generated from a project SOP or built in Form Studio, proctoring (tab and copy-paste blocking,
full screen, webcam with the AI proctor and evidence snapshots in MinIO, Safe Exam Browser), LLM scoring, results
release, analytics. Yantra keeps the paper (the gate it certifies, the attempts, the release policy), the attempts
and the certification; `assess.certified.v1` and `assess.failed.v1` are unchanged.

v2 allows one attempt per person per assessment, so attempt *k* of every worker sits in *cohort k*: cohort 1 is the
paper's base assessment, cohort k a copy made when the first worker needs it (a fresh question draw). v2 closes an
assessment once its whole roster is submitted and released, so the next worker's launch opens another copy. A worker reaches
their exam through a one-time launch URL (a ticket valid two minutes, redeemed by the Assessment app): no second
password. Results are released in v2 (by ops in the Assessment admin or from Yantra); a paper whose policy is
`auto_objective` has its clean, objective-only attempts released by the adapter. **Yantra never certifies on an
unreleased result.**

| Method and path | Role | Body / result |
|---|---|---|
| `GET /v1/assess/engine/assessments?state=draft` | ops | `[{id, name, state, duration_minutes, pass_threshold (0..100), question_count, question_types}]`: assessments built in the Assessment admin that a paper may link |
| `POST /v1/assess/papers` | ops | `{gate, title, description, max_attempts (1..10), release_policy: manual\|auto_objective, assigned_ttl_days (1..90, default 14), source: {kind: "assessment", assessment_id} \| {kind: "quick", duration_minutes (2..600), pass_mark (0..1), questions: [{id, prompt, kind: single\|multi, options: [str] (2..20), answer: str \| [str]}]}}` → Paper. A linked assessment must still be a draft in v2 (409 `assessment_not_draft`) and unused by another paper (409 `assessment_in_use`); a quick paper is written into v2 (a generator, the questions imported and approved, an assessment) |
| `GET /v1/assess/papers`, `GET /v1/assess/papers/{id}` | ops | Paper `{id, gate, title, description, max_attempts, status: draft\|published\|retired, engine, engine_assessment_id, release_policy, assigned_ttl_days, generation, snapshot: {name, state, duration_minutes, pass_threshold, question_count, question_types, rules}, created_by, published_by, created_at, published_at, stats: {total, passed, pass_rate, awaiting_result, held}, cohorts: [{id, attempt_no, generation, engine_assessment_id, state}]}` (cohorts on the single read) |
| `POST /v1/assess/papers/{id}/publish` | ops | → Paper; refused with 422 `launch_blocked` naming every v2 launch gate that fails (all but the roster, which fills on launch) |
| `GET /v1/assess/papers/{id}/sittings` | ops | `[Sitting]` newest first (500 at most) |
| `POST /v1/assess/papers/{id}/release` | ops | `{sitting_ids?}` → `{released}`: releases in v2 the named sittings, or every one of this paper waiting for release; 409 `nothing_to_release`. The sync certifies within seconds |
| `POST /v1/assess/papers/{id}/rotate` | ops | → Paper: closes the running cohorts in v2 and bumps `generation`; the next launch of each attempt opens a fresh copy |
| `POST /v1/assess/sync` | ops | `{changed}`: a by-hand pass of the sync the `work` events process runs every 15 s |
| `POST /v1/assess/admin-launch` | ops, admin | `{next: "/assessments/7"}` → `{launch_url, expires_at}`: signs the operator into the Assessment admin at `next` (a path inside the app; 422 `invalid_next` otherwise) |
| `GET /v1/assess/papers/{id}/brief` | worker | `{id, gate, title, description, status, duration_minutes, pass_mark (0..1), question_count, question_types, proctoring: {webcam, ai_proctor, fullscreen, tab_switch, seb, ...}, attempts_used, attempts_left, certified, current: Sitting \| null}` (`current` is the open sitting, else the latest) |
| `POST /v1/assess/papers/{id}/launch` | worker | → `{launch_url, expires_at, sitting}`: puts the worker on their attempt's cohort and returns a one-time URL into their exam; open it in the same tab. An open sitting is resumed. 409 `result_pending` (submitted, waiting for its result), 409 `attempts_exhausted`, 409 `already_certified`, 409 `paper_retired`, 403 `paper_author` (the caller linked, wrote or published it), 409 `engine_refused` (v2 said no; `engine_code` names why), 503 `engine_unavailable` |
| `POST /v1/assess/launch-by-exam` | worker | `{exam_token}` → `{launch_url, expires_at}`: the Assessment app's "Continue with Yantra" (a lapsed session, or Safe Exam Browser opening the bare exam link) |
| `GET /v1/assess/sittings/me` | worker | `[Sitting + {paper_title, gate}]` newest first |

`Sitting = {id, paper_id, worker_id, attempt_no, status: assigned|in_progress|awaiting_result|passed|failed|void,
held_reason, result: pending|pass|fail, released, score (0..1, once released), deadline, started_at, submitted_at,
created_at, flags: {integrity_alert, violation_limit_breached}}`. `held_reason` says why a submitted attempt has no
result yet: `llm_scoring` (v2 is marking written answers), `needs_release` (a manual paper), `integrity_review`,
`violation_limit` or `subjective_answers` (an `auto_objective` paper held for a person to look), `release_refused`.
An assignment never started within `assigned_ttl_days` is taken off v2's roster and voided (a void sitting is not an
attempt). Quiz-era papers (before v2) are `retired`; their certifications stand and their finished sittings count.

Passing emits `assess.certified.v1 {worker_id, gate, paper_id, score}`; failing emits `assess.failed.v1` with
`attempts_left`.

### 5.4 quality additions

| Method and path | Role | Result |
|---|---|---|
| `GET /v1/quality/stats?batch_id=&project_id=` | ops | `{pending, claimed, in_audit, canonical, accepted, rejected, needs_edits, acceptance_rate, oldest_pending_at, reasons: [{reason_code, count, billable}], audit_disagreements}` (project filter via the batch ids passed as `batch_ids=a,b` since quality has no project table) |
| `GET /v1/quality/tasks?batch_id=&status=&limit=50&offset=0` | ops | `{total, items: [{id, unit_id, batch_id, worker_id, sampled_for_audit, status, reviewer_id, canonical_verdict, created_at, canonical_at}]}` |
| `GET /v1/quality/reviews/active`, `GET /v1/quality/tasks/{id}` | reviewer (holder) | the task with `payload` and `answer`, never the author's `worker_id` or `sampled_for_audit` (ops views only). Readable only while the caller holds the claim (review or audit) and still has the project's gate and, for sensitive work, the clearance: after the verdict, or by anyone else, 404; a holder who lost the gate or clearance gets 403 `clearance_revoked` and the task goes back to the queue (released with reason `revoked`) |
| `POST /v1/quality/reviews/claim?kind=` | reviewer (or ops) | as before, and only work the reviewer may take: never their own, a gated project's work only with its gate (from `assess.certified`, `talent.offer.accepted` or `worker.gates.set`), a sensitive project's only once ops cleared them. Nothing for them is 404 with `waiting_for_gate` and `waiting_for_clearance` counts (work for other gates is someone else's queue, not an error) |
| `POST /v1/quality/tasks/{id}/review` | reviewer | as before; after the claim ran out 409 `review_expired` and the task is back in the queue, whether or not the expiry job released it first (the caller's last claim on it ended by expiry); 403 `clearance_revoked` as above. The reason code must be an active code that applies to the verdict (422 with `codes`) |
| `POST /v1/quality/reviews/{id}/release` | reviewer (holder) | gives the task back without a verdict → TaskOut |
| `GET /v1/quality/tasks/{id}/payload-url` | reviewer (holder) | `{url, expires_at}` for the media the payload names, under the same read rule as the task; 404 `no_payload_object` |
| `PUT /v1/quality/reviewers/{worker_id}`, `GET` | ops | `{sensitive_cleared}` → `{worker_id, sensitive_cleared, gates, updated_at}`; never one's own (403 `self_action`) |
| `GET /v1/quality/reasons?all=` | any signed-in | the taxonomy in display order: `[{code, label, detail, billable, applies_to: [needs_edits|reject], sort, active}]`; `all=true` adds retired codes |
| `PUT /v1/quality/reasons/{code}` | ops | `{label, detail, billable, applies_to, sort, active}` adds or edits a code; retire with `active: false` (never deleted, so old verdicts keep their meaning). `billable` on a verdict now comes from this table |
| `GET /v1/quality/flags?overdue=` | ops | each flag carries `overdue` (unanswered after two days); `overdue=true` lists only those. `stats` adds `flags_open, flags_overdue` |
| `GET /v1/quality/reviews/expired` | admin, ops | stuck work: held reviews past their time `[{task_id, unit_id, batch_id, kind: review|audit, holder_id, claim_expires_at, minutes_overdue}]` |
| `POST /v1/quality/reviews/{id}/release-expired`, `POST /v1/quality/reviews/release-expired` | admin, ops | one stuck review back to its queue (409 `review_not_expired`), or all of them, signed by the caller |
| `GET /v1/quality/reviews/released?days=7` | admin, ops | `[{task_id, kind, holder_id, reason: expired|holder|revoked, released_by (null: the expiry job), expires_at, released_at}]` |

### 5.5 payout additions

| Method and path | Role | Result |
|---|---|---|
| `GET /v1/payout/overview` | finance, ops | `{payable_now: {currency: amount}, paid_total, held_total, open_window: {starts_at, ends_at, closes_in_seconds}, windows: {closed, approved, paying, paid}, margin_total, pending_adjustments}` |
| `POST /v1/payout/adjustments` | ops | `{worker_id, amount, currency, kind: bonus|correction, reason}` → Adjustment `{id, worker_id, amount, currency, kind, reason, status: pending|approved|rejected, proposed_by, decided_by, created_at, decided_at}`; 409 `same_person` for an adjustment to the caller's own pay |
| `GET /v1/payout/adjustments?status=` | ops | list |
| `POST /v1/payout/adjustments/{id}/approve` / `/reject` | ops | neither `proposed_by` nor the worker it pays (409 `same_person`); approve creates an earning `kind=adjust` (status payable; a negative correction is clamped at the worker's payable total) |
| `GET /v1/payout/accounts/{worker_id}` | finance, ops | `{account, totals: {payable, paid, held}, bank: BankAccount | null}` (never the number) |
| `PUT /v1/payout/accounts/me` | worker | `{account_name (letters, spaces and . ' - only, 2-120), account_number (9-18 digits), ifsc}` → BankAccount `{status: verifying|verified|failed, verification: penny_drop|none, account_name, account_last4, ifsc, registered_name_match, verified_at, failure_reason: invalid_account|name_mismatch|rail_error|null, awaiting_confirmation, confirmed_at}`. A penny drop that verifies the account but returns no registered name leaves `registered_name_match` null and `awaiting_confirmation` true: nothing is paid into it (lines held `account_unconfirmed`) until finance confirms it. The number is sealed (AES-256-GCM under `YANTRA_BANK_KEY`) and never returned. The same account again is a no-op; 409 `account_in_use` (another worker's number, also when two register it at once), 429 `validation_limit` (three penny drops a day), 503 `rail_unavailable`. Replacing a verified account holds payouts 72 hours (`bank_change`). The penny drop settles within a minute (poll job) and emits `payout.account.verified.v1` or `.rejected.v1`. |
| `GET /v1/payout/accounts/me` | worker | BankAccount; 404 before one is registered |
| `POST /v1/payout/accounts/{worker_id}/confirm` | finance | confirms an account `awaiting_confirmation` (who and when are recorded) → BankAccount; 409 `same_person` (one's own account), 409 `not_awaiting_confirmation`, 404 without an account |
| `GET /v1/payout/accounts?held=true&limit=&offset=` | finance, ops | `{total, items: [{worker_id, hold_reason, hold_until, first_paid_at}]}`: accounts on a live hold, and those held for withdrawn consent (`hold_reason: consent_withdrawn`, `hold_until` null) |
| `GET /v1/payout/windows/{id}` | finance, ops | Window `{id, starts_at, ends_at, currency, status: closed|approved|paying|paid, gross_total, held_total, paid_total, rail, rail_reference, paid_at, reconciled_at, cap_override_by, cap_override_reason, cap_override_at}` |
| `GET /v1/payout/windows/{id}/lines` | finance, ops | `[Line]` `{id, worker_id, gross, earning_count, status: payable|held|queued|processing|paid|failed|returned|released, hold_reason, attempts, rail, rail_reference, rail_status, utr, failure_reason, submitted_at, settled_at}`. Hold reasons: `integrity`, `bank_change`, `consent_withdrawn`, a reason set by hand, `account_unverified` (no verified bank account), `account_unconfirmed` (penny drop without a name, waiting for finance), `first_payout` (seven days), `over_cap` (one earning bigger than `YANTRA_PAYOUT_MAX_PER_WORKER` on its own). A worker over the per-worker cap is paid up to it (oldest earnings first) and the rest stays payable for the next window. A queued line that is not going out says why in `rail_status`: `held` (a live hold on the worker), `rail_mismatch` (queued on another rail), `account_missing` / `account_changed` (sent back by the bank file) |
| `POST /v1/payout/windows/close` | finance | `{currency, as_of?}` → Window. The `payout_window_close` job closes every currency in `YANTRA_PAYOUT_CURRENCIES` on Saturday 00:05 IST (the week ends Friday 23:59:59 IST; five minutes for clock skew) |
| `POST /v1/payout/windows/{id}/pay` | finance | optional body `{override_cap: bool, reason}`. An approved window → `paying`: every payable line is queued; each attempt `<line>:<attempt>` is both the rail's `reference_id` and its idempotency key; 409 `window_over_cap` above `YANTRA_PAYOUT_MAX_PER_WINDOW` unless `override_cap: true` with a `reason` (422 without one), recorded on the window with the caller. The dispatch job (15 s) sends the lines of workers not on a live hold, on the running rail only, the poll job (60 s) and the webhook settle them; the window is `paid` when no line is payable, in flight, failed or returned |
| `POST /v1/payout/windows/{id}/lines/{line_id}/retry` | finance | a failed or returned line → queued as a new attempt; 409 `line_not_failed`, `rail_mismatch` (the line is on another rail), `too_many_attempts` (999), `worker_held` (a live hold), `account_unverified`. A result about an earlier attempt never settles the new one. A payout the bank returns after it was paid moves its line `paid → returned` (earnings owed again, `payout.line.failed.v1`, a reconciliation delta) |
| `POST /v1/payout/windows/{id}/lines/{line_id}/release` | finance | a failed or returned line → `released`: its earnings are payable again and roll into the next close; the window's gross and held totals move with it |
| `GET /v1/payout/windows/{id}/bank-file` | finance | `text/csv` attachment, bank-file rail only (409 `rail_mismatch` otherwise): `reference,beneficiary_name,account_number,ifsc,amount,currency,narration`, one row per line in flight, paid into the account checked at dispatch. A line whose worker is now held or whose account is gone or changed goes back to the queue and is named in the `X-Skipped-Lines` header (`<line_id>:held|account_missing|account_changed`, comma-separated). A cell starting `= + - @`, tab or CR is prefixed with `'` (also in the statement export) |
| `POST /v1/payout/windows/{id}/bank-file/reconcile` | finance | body `text/csv` `reference,status (paid|failed|returned),utr,reason` → `{applied, skipped: [{row, reference, reason: unknown_reference|bad_status|already_settled}]}` |
| `GET /v1/payout/windows/{id}/reconcile` | finance, ops | the live numbers, not recorded: `{earnings_total, lines_total, paid_total, rail_total, delta, delta_rail, failed_lines, processing_lines, unpaid_earnings, balanced, reconciled_at}` |
| `POST /v1/payout/windows/{id}/reconcile` | finance | the same, recorded as a run (`run_id`); the first balanced run of a paid window sets `reconciled_at` (statements are released). An unbalanced run emits `payout.reconciliation.delta.v1`. Never adjusts. The `payout_reconcile` job runs every window of the last 90 days at 02:00 IST |
| `GET /v1/payout/reconciliation-runs?window_id=&balanced=` | finance, ops | recorded runs, newest first |
| `GET /v1/payout/statements/{window_id}/export?format=csv` | worker, finance, ops | `text/csv` attachment, only after the window reconciled (409 `not_reconciled`): a worker gets their own earnings in it (`window_starts, window_ends, line_status, utr, kind, unit_id, amount, currency, earned_at`; 404 without a line), finance and ops every line |
| `GET /v1/payout/rail` | finance, ops | `{rail: razorpayx|file|fake, supports_penny_drop, lines: {queued, processing, failed, returned}, accounts_verifying, last_dispatch_at, last_poll_at}` |
| `GET /v1/payout/attention` | finance, ops | `{windows_awaiting_second_approval, reconciliation_deltas, failed_lines, lines_blocked, erasures_pending, accounts_awaiting_confirmation, pending_adjustments, dead_letters: {payout}}` |
| `PUT /v1/payout/accounts/{worker_id}/hold` | ops | `{reason, until}` (`until` null lifts) → `{worker_id, first_paid_at, hold_until, hold_reason}`; 409 `same_person` on the caller's own account; a live `integrity` or `bank_change` hold is never shortened or lifted by hand (the response shows the hold that stands) |
| `POST /v1/payout/webhooks/razorpayx` | none | RazorpayX's webhook: HMAC-SHA256 of the raw body under `YANTRA_RAZORPAYX_WEBHOOK_SECRET` (at least 32 characters, checked at boot) in `X-Razorpay-Signature` (401 otherwise); `created_at` is required (422); the event is recorded once by what the signed body says (event, entity id, status; a replay answers `{duplicate: true}` whatever `X-Razorpay-Event-Id` it carries); events older than five minutes are recorded as stale and left to the poll job; news about another attempt of a line is recorded as `other_attempt` and not applied; 404 unless the rail is RazorpayX with a webhook secret |

The rail is chosen by `YANTRA_RAIL`: `razorpayx` (the real API; on the local rig a WireMock emulator of it, see
`deployment/local/wiremock/README.md`), `file` (NEFT/IMPS bulk file; no penny drop) or `fake` (tests). An upheld
tracker anomaly (`tracking.anomaly.upheld.v1`) puts an `integrity` hold on the worker's payouts for
`YANTRA_PAYOUT_INTEGRITY_HOLD_DAYS` (30) and emits `payout.hold.set.v1`; so does a hold set by hand.
`worker.consent.withdrawn.v1` holds the worker's payouts (`consent_withdrawn`, beside any other hold, no
`payout.hold.set.v1`: market reads the consent events itself) until `worker.consent.given.v1` (event time: an older
event arriving late changes nothing; consenting again never clears an integrity or bank-change hold); lifting a
hold by hand also releases it. After `worker.erasure.completed.v1` the bank account is deleted once no earning
of the worker is unpaid (payable, held, windowed or returned); until then it is counted in `erasures_pending`.

### 5.6 notify additions (support tickets)

| Method and path | Role | Result |
|---|---|---|
| `POST /v1/notify/tickets` | any | `{category: bug|payment|work|account|other, title (1..140), body (1..4000), screen (≤200), context: {...}}` → Ticket `{id, author_id, author_name, category, title, body, screen, status: open|in_progress|resolved, note, created_at, updated_at}`; 422 `too_large` when `context` has more than 50 keys or is over 16 KB as JSON |
| `GET /v1/notify/tickets/me` | any | own tickets |
| `GET /v1/notify/tickets?status=` | ops | all |
| `POST /v1/notify/tickets/{id}/status` | ops | `{status, note}` → Ticket |
| `GET /v1/notify/inbox/unread-count` | worker | `{unread}`: the badge's poll, one count on a partial index |
| `PUT /v1/notify/channel` | worker | `{email | null}` → Channel `{worker_id, email, email_verified_at, pending_email, verify_expires_at, verify_sent_at, verify_error, updated_at}`. `email` is the verified address, the only one mail goes to; a new address is `pending_email` and the email job mails it a six-digit code (valid 15 minutes, five tries); asking again for the same address sends a new code; `null` stops email at once. Addresses set before verification existed are pending |
| `POST /v1/notify/channel/verify` | worker | `{code: "123456"}` → Channel (the pending address becomes `email`); 422 `wrong_code` (with `attempts_left`), 409 `nothing_to_verify`, `code_expired`, `too_many_attempts` (ask for a new code with `PUT`) |
| `GET /v1/notify/attention` | ops | `{tickets_open, tickets_in_progress}` |

notify also turns payout's events into inbox rows (`bank_verified`, `bank_rejected` with the reason in plain words,
`payout_failed` / `payout_returned`), opens a `payment` ticket from the platform (author
`00000000-0000-4000-8000-00000000ffff`, screen `finance`) for every `payout.reconciliation.delta.v1`, and on
`worker.erasure.completed.v1` leaves one last inbox row, drops the worker's email (verified and pending) and blanks
the title, body, screen and context of every ticket they raised (`(erased)`; category, status and the operator's
note stay). The verification code is never stored: it is a keyed digest (`YANTRA_PII_KEY`) of a random nonce.

### 5.7 tracker (new, `/v1/tracker/...`)

| Method and path | Role | Body / result |
|---|---|---|
| `GET /v1/tracker/policy` | any signed-in | `{slug, title, summary, version, retention_days, default_cap_hours, sample_seconds, sections: [{title, paragraphs, bullets}]}`: what is collected, what is not, how it is used and kept |
| `POST /v1/tracker/sessions` | worker | `{claim_id?, source: web|desktop, device_hash}` → 201 Session; 409 `session_open` (with `session_id`: reuse it), 409 `claim_not_live` (the claim is someone else's, ended or lapsed; a claim the tracker has not seen yet is accepted), 403 `consent_withdrawn` (the worker withdrew the data-processing consent; the same 403 answers samples and screenshots) |
| `POST /v1/tracker/sessions/{id}/samples` | worker | `{samples: [{at, kind: active|idle|focus_lost, label?}]}` (1..500) → `{accepted, duplicates, over_cap, active_seconds, idle_seconds, week}`; 404 not yours, 409 `session_ended`, 422 `sample_out_of_range` (with `index`: before the session or more than 5 minutes ahead of the server) |
| `POST /v1/tracker/sessions/{id}/end` | worker | → Session (idempotent); emits `tracking.session.ended.v1` |
| `GET /v1/tracker/sessions/me?from=&to=` | worker | `{open_session_id, week: {starts_at, ends_at, active_seconds, idle_seconds, cap_hours, cap_source: worker|project|default, over_cap}, sessions: [Session]}` (this IST week by default; never 404) |
| `POST /v1/tracker/screenshots/presign` | worker | `{session_id, content_type: image/png|image/jpeg, size_bytes (1..5 MiB)}` → `{object_key, put_url, headers, expires_at}`: the PUT is signed for exactly `size_bytes` (the store refuses another size); 503 `storage_unconfigured` |
| `POST /v1/tracker/sessions/{id}/screenshots` | worker | `{object_key, size_bytes, taken_at}` → 201 `{id, session_id, object_key, content_type, taken_at, retention_until}` (never a URL); storage must hold the object at the declared size: 422 `object_missing`, `size_mismatch` (the object is deleted), `key_not_yours`, `taken_outside_session`; 409 `already_registered`; 503 `storage_unconfigured` |
| `GET /v1/tracker/sessions?worker_id=&from=&to=&limit=` | ops | `[Session]` newest first |
| `GET /v1/tracker/anomalies?status=open|dismissed|upheld` | ops | `[Anomaly]` oldest first, `Anomaly = {id, worker_id, session_id, kind, detail, week_start, status, note, decided_by, decided_at, created_at}` |
| `POST /v1/tracker/anomalies/{id}/dismiss`, `/uphold` | ops | `{note?}` → Anomaly; 409 `anomaly_decided`; 403 `self_action` (the anomaly is about the caller); uphold emits `tracking.anomaly.upheld.v1` |
| `GET /v1/tracker/caps`, `PUT /v1/tracker/caps/{worker|project}/{id}` | ops | `{weekly_cap_hours}` (0..168) → `{scope, scope_id, weekly_cap_hours, set_by, updated_at}` |

`Session = {id, worker_id, claim_id, project_id, source, started_at, ended_at, last_sample_at, active_seconds,
idle_seconds, over_cap_at, end_reason: client|stale|claim_ended|consent}`.

Rules. A sample's `at` is quantised to its 30-second bucket and keyed by (session, bucket): a batch sent twice
counts once, two samples in one bucket count once, active time cannot exceed the wall clock. The week is the ISO
week in IST (Monday 00:00). The cap is the worker's, else the project's, else `YANTRA_TRACKER_DEFAULT_CAP_HOURS`
(40); going over records one `over_cap` flag a week, marks the samples and emits `tracking.cap.exceeded.v1`; work
keeps being recorded (pay is per accepted unit, never per hour). The label `yantra-web` is stored as sent; any
other label only as its keyed digest; window titles are never accepted. A session with no sample for 15 minutes is
ended by the system (`stale`). Samples and screenshot references are purged after `YANTRA_TRACKER_RETENTION_DAYS`
(30), and the screenshot objects with them. Detectors, every five minutes: more than 20 active hours in any 24
(`impossible_activity`), samples more than ten minutes after the session's claim ended or lapsed
(`no_live_claim`), one device id on two or more workers' sessions in seven days (`duplicate_device`, one flag per
worker). `pattern` is reserved; no detector produces it yet. An upheld flag makes payout hold the worker.
Consent: on `worker.consent.withdrawn.v1` the worker's open session ends (`consent`) and nothing more is collected
(403 `consent_withdrawn`) until `worker.consent.given.v1`. Erasure: on `worker.erasure.completed.v1` the worker's
samples and screenshot references are deleted, their sessions' device id becomes `erased` (never a shared device)
and leaves their flags' detail; session totals and decided flags stay; every object under `tracker/<worker>/` goes
on the next hourly purge.

The web agent (the app's work screen). While a claim is open on the screen: start a session with the claim
(`409 session_open` → use the `session_id` it names); every 30 seconds record one sample: `active` when there was
pointer or keyboard input in the last 60 seconds, else `idle`, and `focus_lost` when the tab is hidden; flush every
30 seconds or at 500, with `Idempotency-Key: "<session_id>:<first at>"`; end the session on submit, on release,
on leaving the screen and when the claim expires. `device_hash` is a UUID made once and kept in
`localStorage["yantra.device"]`; a cleared storage or a second browser is a new device, so it catches only the
naive case of several accounts on one browser profile (the policy says so).

### 5.8 analytics (new, `/v1/analytics/...`)

| Method and path | Role | Result |
|---|---|---|
| `GET /v1/analytics/leadership?days=30` | ops, finance, admin | `{as_of, window_days, currency, baseline_set_at, numbers: [Tile×4], margin: [MarginRow], watch: [Tile×3]}` |
| `GET /v1/analytics/projects/{id}/trend?days=30` | ops, finance, admin | `{project_id, currency, days: [{day, published, claimed, submitted, accepted, rejected, first_pass_rate, pay, price, review_cost, margin}]}` zero-filled |
| `GET /v1/analytics/funnel?listing_id=&days=30` | ops, finance, admin | `{listing_id, window_days, stages_available, stages: {stage: n}, by_day: [{day, ...stages}]}` |
| `GET /v1/analytics/workforce?week=YYYY-MM-DD` | ops, finance, admin | `{week_start, workers: [{worker_id, active_hours, units_accepted, units_judged, acceptance_rate, earnings: {currency: amount}}], totals}` |
| `GET /v1/analytics/baselines` / `PUT` | read: ops, finance, admin; write: ops | the baseline row: `{currency, days_to_staff, idle_cost_weekly, first_pass_acceptance, cost_per_accepted_unit, idle_hourly_cost, idle_hours_per_week, staffing_workers, rail_fee_per_payout, levy_rate, payout_sla_days, note, set_by, set_at}`; every PUT is a new row (the history stays); 404 before the first |
| `GET /v1/analytics/rebuild` | ops, finance, admin | `{generation, status: idle|requested|running|done, mode, requested_by, requested_at, started_at, finished_at, events}` |
| `POST /v1/analytics/rebuild?mode=repair|purge` | admin | 202; 409 `rebuild_running`. The events process carries it out: marts and consumed ids emptied (`purge` also deletes warehouse rows the stream still holds), a fresh durable replays from sequence 1, done when it has nothing pending |
| `GET /v1/analytics/dead-letters`, `/jobs` | admin, ops | as every module |

`Tile = {key, label, value, baseline, unit: days|money|ratio|count|per_1000, better: lower|higher, currency, basis,
href, note}`; `href` is the app destination that explains the number (`projects`, `workers`, `quality`,
`finance`, `system`). `MarginRow = {project_id, currency, accepted, price, pay, review, audit, margin,
margin_per_unit, margin_fraction}`.

The numbers. **Days to staff**: per batch published in the window, days from publication until its K-th distinct
worker first claimed (K = the baseline's `staffing_workers`, or the batch's unit count when smaller); the median;
batches not there yet are `pending`. **Idle cost**: eligible workers (`worker.eligible.v1`) with no accepted unit
in seven days × `idle_hourly_cost` × `idle_hours_per_week` (what the idle bench would cost on a retainer; the bench
pays nothing for idle time). **First-pass acceptance**: units whose first verdict fell in the window, accepted
first time over all of them. **Cost per accepted unit**: (pay + review + audit + `rail_fee_per_payout` × payouts +
`levy_rate` × pay) ÷ accepted units, in the baseline's currency (rail fee and levy come from the baseline until an
event carries them). Margin mirrors payout's margin report: price and pay on an accept, review pay on every verdict,
review pay again for an audited one. Watch list: windows paid within `payout_sla_days` of their end; upheld
anomalies plus manual holds per 1,000 eligible workers; dead letters in the work deployable plus reconciliation
deltas. Days are IST dates. Marts are recomputed from the warehouse every five minutes for the days whose events
arrived since the last pass, never incremented, so a replay never double counts. The replay reaches back as far as
the stream keeps events (30 days); `repair` keeps every older warehouse row. Odoo's ledger (CDC) is not read: the
finance figures come from payout's events, which reconcile with Odoo through the bridge.

Personal data in the warehouse. A payload is stored minimised by an allowlist per event type
(`yantra_analytics/minimise.py`): ids, amounts, counts, statuses, codes and timestamps; never a name, a unit's
payload or answer, a document, a digest of personal data, bank details or free text (a manual hold's reason is
kept only as `has_reason`). A type not on the list keeps only its well-formed ids. On `worker.erasure.completed.v1`
the worker's id is replaced by a random pseudonym in every warehouse row (id column, payload, subject) and in the
worker-week mart, and every later event naming them lands under the same pseudonym: counts and marts stay whole,
nothing leads back to the person. Warehouse events older than `YANTRA_ANALYTICS_RETENTION_DAYS` (400) are deleted
daily at 03:15 IST; the marts keep the aggregates they hold (a rebuild after that recomputes only what is left).

## 6. New events (`yantra_contracts.events.v1`)

| Type | Emitted by | Payload |
|---|---|---|
| `assess.certified.v1` | assess | `worker_id, gate, paper_id, score` |
| `assess.failed.v1` | assess | `worker_id, gate, paper_id, score, attempts_left` |
| `talent.offer.accepted.v1` | talent | `application_id, listing_id, worker_id, gate` |
| `worker.eligible.v1` | talent | `worker_id, legal_name_hash, pan_last4` |
| `talent.application.decided.v1` | talent | `application_id, listing_id, worker_id, decision` (notify turns it into an inbox row) |
| `payout.adjustment.approved.v1` | payout | `adjustment_id, worker_id, amount, currency, kind` |
| `payout.account.verified.v1` | payout | `worker_id, account_name_hash, account_last4, ifsc, verification: penny_drop|none` (talent completes the `bank` step when the hash equals the legal name's) |
| `payout.account.rejected.v1` | payout | `worker_id, reason: invalid_account|name_mismatch|rail_error` (notify: an inbox row) |
| `payout.line.failed.v1` | payout | `window_id, line_id, worker_id, amount, currency, status: failed|returned, reason` (notify: an inbox row asking the worker to check their account) |
| `payout.reconciliation.delta.v1` | payout | `run_id, window_id, currency, earnings_total, lines_total, paid_total, rail_total, delta_lines, delta_rail, failed_lines, processing_lines` (notify: a payment ticket) |
| `payout.hold.set.v1` | payout | `worker_id, reason, until (null: lifted), source: manual|anomaly` |
| `payout.paid.v1` (added fields) | payout | `+ line_id, utr` |
| `talent.application.moved.v1` | talent | `application_id, listing_id, worker_id, from_status (null on apply), to_status` (every status change; the funnel) |
| `talent.person.seen.v1` | talent | `id, name (null: forget), kind: worker|staff|client` (market and notify keep names from it) |
| `worker.consent.withdrawn.v1` | talent | `worker_id` (tracker ends the open session and collects nothing more; market and payout block claims and payouts) |
| `worker.consent.given.v1` | talent | `worker_id`: consent given when there was none (the first time or after a withdrawal); every block a withdrawal put on lifts |
| `worker.erasure.requested.v1` | talent | `worker_id, due_at` |
| `worker.erasure.completed.v1` | talent | `worker_id` (notify drops the email and blanks the worker's tickets; tracker deletes samples, screenshots and device ids; analytics pseudonymises the worker; payout erases the bank account once every window holding the worker is paid) |
| `work.unit.published.v1` (added field) | market | `+ project_id` |
| `work.unit.claimed.v1` (added fields) | market | `+ batch_id, project_id` (tracker caps by project; analytics attributes claims) |
| `work.unit.submitted.v1` (added fields) | market | `+ project_id, cert_gate, sensitive` (who may review it; older events carry none and stay open to every reviewer) |
| `work.claim.released.v1` | market | `unit_id, claim_id, worker_id` (the worker gave the claim back) |
| `work.batch.purged.v1` | market | `batch_id, project_id, unit_count` (quality drops its copies of the batch's payloads and answers) |
| `worker.gates.set.v1` | market | `worker_id, gates, source: ops, seq` (the gates an operator or Odoo set; quality replaces its hand-set copy and keeps earned ones, and ignores an event whose `seq` is not above the last one it applied) |
| `tracking.session.ended.v1` | tracker | `session_id, worker_id, claim_id, project_id, source, started_at, ended_at, active_seconds, idle_seconds` |
| `tracking.cap.exceeded.v1` | tracker | `worker_id, session_id, week_start, cap_hours, active_seconds` (once a week per worker) |
| `tracking.anomaly.flagged.v1` | tracker | `anomaly_id, worker_id, session_id, kind, detail` |
| `tracking.anomaly.upheld.v1` | tracker | `anomaly_id, worker_id, session_id, kind, decided_by` (payout: an integrity hold) |

## 7. Design

The app keeps the Ethara portal tokens (`lib/core/theme/portal_tokens.dart`): neutral surfaces, magenta
only on the primary action, the active destination, focus and the brand mark; status through the four
semantic families with a dot or icon, never colour alone; Plus Jakarta Sans and DM Mono, bundled.

What it borrows from Mercor's worker and ops apps (public surfaces only):

- Listing cards: title, domain chip, pay per accepted unit as a range, commitment, "N slots left",
  "Prequalified" and "N hired this week" badges; open slots sort first; a closed listing points at the
  evergreen pool of the same domain instead of a dead end.
- Step checklists with numbered discs and "n of m"; steps complete once and reuse everywhere.
- The offer banner with a countdown; "expired equals declined".
- Grouped onboarding: Profile, Documents, Identity, Payment, with "what still blocks your first claim".
- The earnings page as a first-class page: filters, status pills, bank reference, statement export.
- Ops: pay and bill side by side on every batch; reason taxonomies served from the API; a queue page
  with "oldest waiting" on top; applications pipeline columns.

What it borrows from the Ethara social studio (`Social-Media-Agent-Main-Project-main/apps/web`):

- A sidebar whose groups carry a hint line under each label; the active item has a short accent bar at
  the rail's edge; a collapsed 64px rail that expands on hover or focus on screens between 960 and 1280px.
- A page head with a small uppercase kicker above the title ("WORK · HOME") and one subtitle line.
- KPI tiles that lift on hover and show an arrow when they open a page.
- A command palette on Cmd/Ctrl+K listing destinations and the page's actions.
- A tickets board (open, in progress, resolved) with a drawer per ticket.
- A brand loader (the mark with a breathing ring) for a page waiting on its first data; skeleton rows
  for a list inside a loaded page; toasts for outcomes.
- Empty states that say what to do next; error states that say what happened and offer retry.

Every screen: light and dark, 390px to 1440px, keyboard reachable, visible focus, AA contrast, loading,
empty and error states.
