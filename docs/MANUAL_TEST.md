# Manual test: the whole product, by hand

A walk through every surface of Yantra on the local rig, one person at a time. Each step says who to sign in as,
what to do, and what you should see. Tick the box when it behaves; note anything that does not.

How to start the rig and reset it is in [USING.md](USING.md) §1 and §4. The automated checks (tests, smoke, gates) are
in [LAUNCH.md](LAUNCH.md); this page is for what a person sees.

## 0. Before you start

| What | Where | Sign in |
|---|---|---|
| The app | http://localhost:8095 | users below, password `yantra` |
| Test mail inbox (Mailpit) | http://localhost:8026 | none |
| Keycloak admin | http://localhost:8180 (realm `yantra`) | `admin` / `admin` |
| Grafana (dashboards) | http://localhost:3000 | none (viewer) |
| Assessment v2 (exam and admin) | http://localhost:8096 | opened from Yantra, already signed in |
| Odoo | http://localhost:8069 | `admin` / `admin` |

| User | Roles | Starts as (after `uv run yantra seed`) |
|---|---|---|
| `ops1`, `ops2` | operator + finance | two people, so two-person approvals can be tested |
| `worker1`, `worker2`, `worker3` | worker + reviewer | certified for transcription, bank accounts verified |
| `worker4` | worker | applied to the Hindi pool, assessment paper pending |
| `worker5` | worker | holds an offer on the Tamil pool |
| `client1` | client | member of "Acme Labs" |
| `client2` | client | no organisation |
| `admin1` | admin | System page, Leadership |
| `noroles1` | none | should see "no access" |

Tips:

- Use one browser profile per person (or private windows) so sessions don't mix.
- The rig signs in with a password form ("Use a password instead"). "Continue with Keycloak" is the real flow; for
  `ops1`, `ops2` and `admin1` it asks you to set up an authenticator app (two-factor) the first time.
- Background jobs run on timers: claim expiry every 30 s, payouts are sent every 15 s and checked every 60 s. Wait a
  minute before calling something broken.

## 1. Signing in

- [ ] Open http://localhost:8095/ops/projects while signed out → you land on the sign-in page; after signing in as
  `ops1` you are taken back to Projects.
- [ ] "Continue with Keycloak" as `ops1` → Keycloak asks you to set up two-factor (scan the QR code with any
  authenticator app) → you land in the operator console. As `worker1` the same flow asks for no code.
- [ ] Sign in as `noroles1` → a "no access" page with a Sign out button.
- [ ] Self-signup: on the Keycloak page choose "Register", use any email → the verification mail is in Mailpit →
  after verifying you are a worker with an empty Home.
- [ ] Refresh the page on any screen, and use the browser Back button → you stay where you were, inside the sidebar.

## 2. A new worker joins (worker4, then worker5)

- [ ] **Explore**: open listings show pay range, commitment, slots left, "hired this week"; filters work.
- [ ] Open the Hindi listing → requirements, the steps, the AI-use policy; your application shows "assessment".
- [ ] **Assessment (the real Assessment v2)**: the Hindi listing's step 2 and Home both offer "Take the paper" →
  the brief (time, pass mark, questions, attempts left, the proctoring rules) → "Start in Assessment" → the same tab
  opens the Assessment v2 exam at http://localhost:8096, already signed in as you (no password).
  - [ ] Read the rules, tick the box, Start → allow full screen. The clock runs, your name is watermarked, and
    switching tabs, copy-paste, right click or leaving full screen is recorded as a violation.
  - [ ] Answer the four questions (they are shuffled): two people talking over each other → "Tag the overlap and
    transcribe both"; verbatim → "Filler words", "Repeated words", "False starts"; a number in Hindi → "As the word,
    as spoken"; an unclear word → "[inaudible]". Review & Submit → Submit Assessment.
  - [ ] "Back to Yantra" → the paper page shows "Awaiting result", then within about 30 seconds "Certified with
    100%", and the attempt is listed.
  - [ ] A wrong answer below 75% shows "Not passed" with attempts left; a retake is a fresh paper with new questions.
- [ ] After passing, Applications shows the application moved on to screening.
- [ ] **Onboarding** (from Home): six steps in four groups.
  - [ ] Profile: legal name, phone, city.
  - [ ] Agreement and consent: the text comes from the server, with a version.
  - [ ] Identity: PAN (format ABCDE1234F) and the last four of Aadhaar; upload an identity document (jpg, png or pdf
    under 10 MB) → it shows as uploaded (the file lands in storage under `workers/`, see §10).
  - [ ] Bank: account name must equal the legal name; any 9–18 digit number and an IFSC like `HDFC0001234` →
    "Checking" → "Verified" within about a minute. An account number ending `0000` fails ("invalid account"); one
    ending `1111` fails on the name.
  - [ ] Payout acknowledgement → "6 of 6"; Home's readiness checklist is complete.
- [ ] As `worker5`: Applications shows an offer with a countdown → Accept → Explore shows the Tamil pool as yours.

## 3. A worker's day (worker1)

- [ ] **Home**: readiness complete, open batches with pay per unit, the week's activity hours.
- [ ] Claim a unit from "Week 45 clips" → the work page opens with a countdown and an audio player → press Play: a
  short tone plays.
- [ ] Type an answer, press Back → "Leave this unit?" → Stay. Refresh → the draft is still there.
- [ ] The note under the brief says activity is recorded while you work; "What we track" opens the tracking policy.
- [ ] "Release claim" → back on Home, the unit is free again. Claim again, fill the form, Submit → "Submitted".
- [ ] **My work**: the unit shows as waiting for review; later its verdict.
- [ ] **Earnings**: totals, weekly bars, pay windows with bank references once paid; filter by status; download a
  statement CSV for a reconciled window.
- [ ] **Inbox**: the bell's count rises on its own when a verdict arrives (within a minute).
- [ ] **Profile → Notifications**: set an email → "We sent a code" → find the 6-digit code in Mailpit → enter it →
  "Verified". A wrong code says how many tries are left.
- [ ] **Profile → Report a problem** (also the flag icon in the top bar on any page) → the page you were on is filled
  in → the ticket appears under "My tickets".
- [ ] **Profile → Your data**: withdraw consent (with a warning) → Earnings says payouts are held and how to lift it;
  claiming new work is refused with a plain explanation. "Give consent again" lifts both.
- [ ] "Delete my data" shows a due date (30 days). Do this last, on a worker you no longer need.

## 4. Reviewing (worker2)

- [ ] **Review** → "Next task" → the clip and the submitted answer side by side, with the rubric version.
- [ ] Accept one. Send one back with a reason (the reasons come from the server) → the author sees it in My work.
- [ ] A reviewer never gets their own work. When nothing is left the page says why (for example "N tasks wait for a
  certification you don't hold").

## 5. Running the work (ops1)

- [ ] **Overview**: tiles are clickable and lead to their page; the attention list (flags, disputes, tickets,
  batches under the margin floor, windows waiting for approval, stuck work).
- [ ] **Projects → New project**: name, currency, certification gate, schemas (use "Insert sample"), margin floor,
  retention days, client org → it opens with a 30-day trend.
- [ ] **New batch** (pay 28, price 60, review pay 6; set claim time to 1 minute for the stuck-work test in §8) →
  upload two small audio files → import a JSONL or CSV file → the dry run lists bad lines and why → Commit → Publish
  (a price under the margin floor asks for a recorded approval). Pause and resume.
- [ ] After the batch's units are accepted: **Deliverable** downloads a JSONL file and a manifest.
- [ ] **Listings**: create a listing with questions and steps → open it → click an applicant → the side sheet shows
  their answers, steps and paper result → Offer (or Reject with a note).
- [ ] **Papers**: the seeded "Transcription basics" paper shows its v2 assessment, attempts, passed and pass rate.
  New paper → "Quick paper" (single and multiple choice) or "Link an assessment" (any v2 assessment, with any
  question type) → Publish. Open a paper → its attempts, Release, Sync now.
- [ ] **Open in Assessment admin** (on a paper) → a new tab with the full Assessment v2 admin, already signed in:
  Dashboard, Assessments, Generators (papers from a project's SOP), Review Queue, Question Bank, Tags, Form Studio,
  Responses (with proctoring evidence), LLM Budget, Settings. Generating from an SOP and AI marking of written,
  image, video and transcription answers need a Google Vertex key (Settings → service account); without one,
  multiple-choice papers work end to end and AI-marked answers wait for marking.
- [ ] **Workers**: search, filter by gate → open a worker → names, documents (open one), bank status, set gates,
  sensitive-work clearance, hold until a date, tracked sessions.
- [ ] **Quality**: flags to answer, disputes to decide, the queue by batch, reason codes; **Integrity** tab shows the
  "same device" flag the seed set up for worker2 and worker3 (the scan runs every 5 minutes, so it appears up to 5
  minutes after seeding) → Uphold one (that worker's payouts are held) and
  Dismiss the other.
- [ ] **Support**: the board (open, in progress, resolved) → open a ticket → note and move it.
- [ ] **Settings**: create a client org and add a member; publish a new policy version (workers are asked to accept
  it again); edit a reason code; set a weekly hour cap; approve a pending erasure request.

## 6. Paying people (ops1 and ops2, finance)

- [ ] **Finance → Close window** (choose INR) → as `ops1` Approve → as `ops2` Approve (one person cannot approve
  twice) → Pay → lines move from queued to processing to paid within about a minute, each with a bank reference.
- [ ] A failing payout: as `ops1` propose a bonus of 40.13 for a worker, approve it as `ops2`, close and pay a
  window → that line fails ("insufficient funds") → Retry (fails again) → Release (it moves to the next window).
- [ ] **Reconcile** → balanced; the worker's statement can now be downloaded.
- [ ] **Bank file** (only on the file rail) and **Holds** tab: lift a hold; a bank account that came back without a
  name waits for "Confirm".
- [ ] A window over its cap offers "Pay over the cap" with a required reason.
- [ ] Nobody can approve their own bonus or lift their own hold.
- [ ] Odoo (http://localhost:8069): Yantra → pay windows → "Pull paid windows now" → each paid line becomes a
  draft vendor bill with a TDS line.

## 7. The client (client1)

- [ ] **Overview**: units delivered, acceptance rate, next delivery, invoice total. Prices only, never pay rates.
- [ ] **Projects** → a project: batches with progress bars, rework reasons, deliveries → download "Units" (JSONL)
  and "Manifest".
- [ ] Send feedback → as `ops1` reply on the project page → client1 sees the reply marked "Yantra".
- [ ] `client2` (no organisation) sees an empty console, not someone else's data.

## 8. Admin (admin1)

- [ ] **System → Stuck work**: claim a unit from the 1-minute batch (§5) and leave it → after a minute it is listed
  with minutes overdue → Release one; make two more and "Release all". "Released in the last 7 days" shows who
  released each (the scheduler, an operator, or the holder).
- [ ] **System → Dead letters** and **Jobs**: every job on schedule, none failing.
- [ ] **Leadership**: four numbers against baseline (days to staff, idle cost, first-pass acceptance, cost per
  accepted unit), margin per project, the watch list, the hiring funnel.

## 9. Everywhere

- [ ] Phone width (390 px, browser dev tools): drawer and bottom bar, no text cut off.
- [ ] Dark mode (Profile → Appearance, or the top-bar toggle).
- [ ] Keyboard only: Tab shows a visible ring; Cmd/Ctrl+K opens the palette with destinations and "On this page"
  actions.
- [ ] Turn the network off (dev tools → Offline) → "You're offline" banner; back on → it recovers.
- [ ] Amounts read ₹ with Indian grouping (₹12,50,000.00); pay-window dates say IST.
- [ ] Two tabs signed in as the same person stay signed in after 15 minutes (the sign-in refreshes itself).

## 10. Behind the scenes

- [ ] Grafana (http://localhost:3000) → Yantra overview: traffic, errors, latency, event lag, claims, pay window.
- [ ] Stored files (MinIO's web console is not part of this MinIO version; list them from the command line):
  uploaded clips under `projects/`, documents under `workers/`, deliverables under `projects/<id>/deliveries/`.

  ```
  docker compose -f deployment/local/compose.yaml exec -T minio sh -c \
    "mc alias set local http://localhost:9000 yantra yantra-local-secret >/dev/null && mc ls --recursive local/yantra"
  ```
- [ ] Mailpit: the email codes and notification mails.

## When something is off

Write down who you were signed in as, the page (the URL), what you did and what you saw; a screenshot helps. The
reference number in an error message (Reference: …) finds the request in the logs:
`docker compose -f deployment/local/compose.yaml logs work money gateway | grep <reference>`.
