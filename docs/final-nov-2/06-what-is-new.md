# What this pack adds to the Yantra repository

The Yantra repository on GitHub (README, ARCHITECTURE, DESIGN, DATAMODEL, MODULES, INFRASTRUCTURE, REQUIREMENTS, ROADMAP) is the point of truth. It is a specification: a thorough architecture and data design for a 20K onsite and 200K online worker platform, written to competitor parity, with no code yet. This pack takes that specification and adds the parts needed to start building and earning against it. This page lists, item by item, what was kept, what was added, where a different choice is proposed, and what the repository already covered so that nothing here is claimed twice.

## Contents

1. The one-minute answer
2. What was kept from the repository, and why it stays the base
3. What was added: the business and the plan
4. What was added: the product and engineering design
5. Where this pack proposes a different choice
6. What the repository has that this pack deliberately defers
7. What the repository already had (credit where it is due)
8. The pack itself
9. By the numbers

---

## 1. The one-minute answer

The repository answers **"what should the platform be?"** at full scale: nine services, a complete data model, a six-phase roadmap to competitor parity. It does not answer **"what do we sell, to whom, at what margin, and what do we build in the first twelve weeks to prove it?"** That is what this pack adds.

| Question | Repository | This pack |
|---|---|---|
| What is sold, to whom, in what order | parity with four competitor platforms | managed per-unit delivery on a credentialed bench to environment vendors and labs; an environment factory as a later business line; hubs as channels |
| How money is made per unit | per-unit pay to workers; client invoicing through Odoo | a price frozen next to the pay, every cost line recorded at accept, a margin per batch, a floor with a recorded override, a quote formula for Stage 2 |
| What is built first | Phases 1 to 3 (the internal ERP), then Phases 4 to 6 (the marketplace) | a thin, working loop with real money in twelve weeks, while the ERP phases continue on the existing addons |
| How a stage is passed | per-phase verification criteria | the same discipline, plus a gate per step with a measurable number, the four business numbers, and kill criteria |
| What a worker is | a freelance employee record with a vendor partner | a bench member: skills with an evidence level, availability that goes stale, a return to the bench at project end, three verified people per seat, no recruiting without signed demand |
| India | GST, TDS, Razorpay as the India rail | Razorpay first, DPDP consent, the Social Security Code levy priced in, PAN plus penny drop, misclassification handled by output-based contracts |
| The team and the money to start | not covered | a squad of five to seven, a named DevOps owner, a finance lead, Stage 0 legal and commercial work, SOC 2 window opened early |

Everything else in the pack is either the repository's design restated for a reader who is new to it, or a drawing of it.

---

## 2. What was kept from the repository, and why it stays the base

| Kept as specified | Where it lives in the repository |
|---|---|
| Odoo 19 Community Edition only, OCA substitutes, no Enterprise code, licence obligations per module | MODULES, README |
| The hub-and-spoke shape: Odoo as the system of record, a ring of services, a single gateway, the Flutter app that only ever talks to the gateway | ARCHITECTURE, DESIGN |
| The nine service names and what each owns; database per service; ids rather than foreign keys across stores | ARCHITECTURE, DATAMODEL |
| Keycloak as the single identity provider; OIDC for staff, JWT for workers and services | ARCHITECTURE |
| NATS JetStream with CloudEvents; no broker client inside the Odoo process; outbox and queue-buffered writes into Odoo | ARCHITECTURE, DESIGN |
| Claims serialised with `SELECT ... FOR UPDATE SKIP LOCKED`; idempotency keys at the gateway; retry absorption | ARCHITECTURE, DATAMODEL |
| The canonical accept verdict as the only trigger for pay and billing; exactly-once money through the verdict id; the reconciliation invariant (rails equal ledger net of TDS) | DESIGN, DATAMODEL |
| Weekly pay window, first-payout hold, self-billed vendor bills with TDS in Odoo | ARCHITECTURE, DATAMODEL |
| Table and column names: worker_profile, client_project, rate_card, work_batch, work_unit, claim, submission, verdict, earning, payout_txn, pay_window | DATAMODEL |
| The Odoo deployment roles, the pgBouncer transaction-mode trap, the queue_job cron runner, Redis sessions, S3 attachments | INFRASTRUCTURE |
| The CNCF posture: Argo CD, Helm, Harbor, cosign, SBOM, Kyverno, OpenTelemetry | INFRASTRUCTURE |
| The 20K onsite and 200K online envelope as the design ceiling and the Phase 5 load test | README, ROADMAP |
| Phases 0 to 6 and their verification criteria | ROADMAP |

Why it stays the base: it is complete, internally consistent, and shared by leadership. Replacing it would cost months and produce a second document to reconcile. Building on it costs nothing and keeps one vocabulary.

---

## 3. What was added: the business and the plan

Nothing in this table exists in the repository documents. Each row says what was added and why it matters to the people paying for the build.

| Area | What this pack adds | Why |
|---|---|---|
| Who the customer is | environment vendors first, then labs; later, hubs as channels for surplus; hourly engagements only behind a non-Indian entity | the repository targets competitor parity in general; a build needs a first buyer with a known bottleneck |
| What is never built | a horizontal marketplace; recruiting ahead of signed demand; hourly pay by default; appraisals inside the tasking platform | the repository's 200K envelope reads as a target; this pack keeps it as a ceiling and stops the build from chasing it in year one |
| Year-one sizing | 1,000 to 3,000 registered, 300 to 500 concurrent, 5 to 20 claims per second, 1,000 to 20,000 units per batch, with the design response for each | the repository's capacity model sizes Odoo for 20K staff; nothing sized the marketplace for its first year |
| Stage 0 | the decision lock, baselines on live projects, five vendor and two lab interviews, counsel and chartered accountant opinions, the SOC 2 window, the bench flow on a spreadsheet | the repository's Phase 0 is infrastructure; the commercial and legal work that lets Stage 1 build against a real pilot had no home |
| Stage 1, the working loop | six steps in twelve weeks (foundations; identity, bench and onboarding; market core and review; money and margin; delivery and dogfood; the first paying pilot), each with what it delivers and a gate with a number | the repository runs Phases 1 to 3 before the marketplace; this pack puts real money through the loop first, in parallel with the ERP work |
| Stage 2 and Stage 3 | Talent, Performance and the internal Hub on demand; the environment factory as a conditional business line from month 8, with its own gate | the repository's Phase 6 is the AI layer; the factory and its quality gate are not in the roadmap |
| Decisions for leadership | 27 decisions, each with a default so the build can start before the meeting; three marked open | the repository's open-decisions table has five technical rows; the commercial ones (pay basis, legal model, rails, pricing, data ownership, positioning) were missing |
| Measures | the four business numbers (days to staff, idle cost, first-pass acceptance, cost per accepted unit), a north star (gross margin per accepted unit), platform measures per area | the repository verifies phases technically; nothing measured whether the business works |
| Kill criteria | six tests that stop or redirect the build (fewer than three vendor customers in two quarters, exclusivity premium below 2x, the bench not faster on the four numbers, and so on) | a plan without a stop rule runs on intent |
| Risks | 21 risks with a safeguard each, including the commercial ones: misclassification, reselling data not owned, recruiting that looks like a scam, margin read as pay cuts, tracking felt as surveillance | the repository's threat model is a security table; business and people risks were not covered |
| Alternatives considered | 23 decisions with the options weighed and why one was chosen | so a reader can disagree with a choice rather than with the whole plan |
| Team | a squad of five to seven for Stage 1 with roles, a named DevOps owner at two days a week, a finance lead, the ways of working | the repository does not size the team |
| Principles | ten rules, among them: the accept verdict is the only money event; no profit lever lowers contributor pay; rates are shown before work is accepted; identity is bound to the payout account | the first exists in the repository as a design rule; the rest are commitments to workers and clients that shape the product |

---

## 4. What was added: the product and engineering design

These are additions to the repository's design, not replacements. Column names follow the repository where a table already exists.

### 4.1 Money and margin

| Addition | What the repository has today | What this pack adds | Why |
|---|---|---|---|
| A sell-side price | `unit_pay` frozen at publish; client invoicing from timesheets and milestones | `unit_price` frozen next to `unit_pay` on the batch; the price card shows both before publish | without a frozen price, margin per batch cannot be known at accept time |
| Cost per unit | pay accrues per accepted unit | cost fields on the unit at accept: pay, review, audit, rail fee, levy; a cost ledger in payout | margin is invoice minus every cost line, per batch and project, reported weekly |
| Margin floor | not present | a batch below its floor cannot publish without a recorded approval (a warning, not a hard block, in Stage 1) | a hard block with no cost history would stop the dogfood batch |
| Quote formula | rate cards by geography, domain and credential | Stage 2: price equals expected cost divided by one minus the target margin, by quality tier and turnaround | pricing becomes a function of observed cost, not a negotiation |
| Levy | not present | the Social Security Code levy priced into every rate card as a line from day one | the rate is not yet notified; pricing it in now avoids a repricing later |
| Two-person approval | a weekly payout run | the finance lead plus one approver before any rail call; caps per window | no single person can move money |
| Delivery and invoice | invoice from Odoo | a delivery gate (every accepted unit validated against the batch schema; one bad line holds the batch), a manifest with counts, checksums, provenance and rubric versions, then the invoice | the invoice is tied to what was actually delivered |

### 4.2 Quality

| Addition | What the repository has today | What this pack adds | Why |
|---|---|---|---|
| Rubric version | structured rubric feedback on a verdict | `rubric_version` carried by every unit and every verdict; a new version when the client changes the glossary | a verdict can be defended against the rubric the worker actually saw |
| Reason codes | rejection reasons as free text in the event | a mandatory `reason_code` on every needs-edits and reject; client-caused codes marked billable | rework caused by the client is invoiced, not absorbed |
| Rubric unclear | not present | a flag with a note, routed to the TPM, answered within two days | the fastest way to find a bad rubric is the reviewer who is stuck on it |
| Stage 1 quality model | a multi-stage pipeline with LLM judge, consensus, hierarchy, disputes and calibration | single review plus a 10% audit sample; the auditor's verdict wins; the rest arrives in Stage 2 | the full pipeline needs a pool and cost history that do not exist before the first pilot |
| Reviewer never author | not stated | a rule in the claim query and a test for it | the cheapest fraud to prevent |

### 4.3 Bench and supply

| Addition | What the repository has today | What this pack adds | Why |
|---|---|---|---|
| The bench | an eligible worker profile with a tier and a trust score | a bench record in Odoo: skills with an evidence level, availability that goes stale after 14 days, past quality; a worker returns to the bench at project end at zero idle cost | the business sells a staffed bench, not a queue of applicants |
| Evidence level on skills | skills granted from assessments | claimed (resume), verified (assessment), proven (performance), never mixed in one field | a client is told which it is buying |
| Papers from the SOP | survey engine assessments | a paper generated from the project's standard operating procedure, proctored, with a certification tag that opens a category of work | the existing Assessment v2 engine already does this; it becomes the first `assess` contract |
| Recruiting rule | a public funnel | never recruit without signed demand; three verified people per committed seat; channels measured on cost per verified professional | verified people with no work churn and complain publicly |
| Identity bound to the payout account | KYC in `assess`; a rail account in `payout` | one bank account per worker; PAN plus penny drop; step-up authentication and a 72-hour hold after any account recovery; the first-contact rule (post the work, never a direct message) | the fraud and scam patterns seen on comparable platforms |
| Consent | not present | DPDP consent as an onboarding item; retention purge per project | India's data law applies to every worker record |

### 4.4 Services and repository

| Addition | What the repository has today | What this pack adds | Why |
|---|---|---|---|
| `hub` | not present | datasets, environments and models as versioned entries with cards, lineage to units and people, a rights field enforced in queries, entitlements with an exclusivity class, signed OCI delivery | the Stage 3 business line needs a place to hold what it sells |
| `runner` | a code sandbox for assessments | the environment quality gate: deterministic replay, a pass-rate band against a reference panel, a reward-hackability audit; a finding is a hard fail | a shipped hackable environment is the one defect a lab will not forgive |
| Shared packages | one submodule per service | `packages/contracts` (OpenAPI per service, CloudEvents schemas, generated Dart and Python clients) and `packages/py-common` (auth, tracing, outbox publisher, idempotency, fixtures) | the outbox and idempotency are written once, not per service |
| One-repository rules | contribution rules per submodule | eight rules that keep one repository from becoming one application: a service imports only packages, a contract change lands with its consumers in one pull request, affected-only CI, four things every service ships, an ADR per cross-service decision | the usual failure of a monorepo is named and fenced |
| Hot-path rules | hot rows kept out of Odoo | the claim path writes only unit and claim rows; no counters on worker or batch rows; no chatter per claim; task lists show no counts | the claim storm test passes by design, not by tuning |
| Scale triggers | a Phase 5 load test at 200K | the numbers that trigger extraction: more than about 3,000 concurrently active workers, p99 claim over 1 second at the load target, review contention with claims, a second rail or country | the ceiling test stays; year one is measured before anything is extracted |
| Files | S3 with `fs_attachment` | per-project prefixes, IAM roles, SSE-KMS, five-minute presigned links; bytes never cross Odoo or the gateway | client data confidentiality is a contract term |
| AI | LLM providers as an external system | Vertex Gemini through one client with a cost ledger and quota guards; no third-party proxy | the proxy was the breach vector in a reported incident |
| Operations | observability stack | alerts with thresholds (connections at 85%, backlog age over 48 hours, reconciliation delta of any size), a runbook per service before production, an on-call rota by the pilot | a service without a runbook does not deploy |

---

## 5. Where this pack proposes a different choice

Five places. Each stays a proposal until leadership accepts it; each is reversible, and the cost of reversing is stated.

| Proposal | The repository today | This pack proposes | Why | Cost to reverse |
|---|---|---|---|---|
| Order of work | Phases 1 to 3 (HRMS, Finance, ITMS) before Phases 4 to 6 (the marketplace) | a thin slice of Phases 0, 4 and 5 first, as a working loop with real money; Phases 1 to 3 continue in parallel on the existing addons | the loop proves the business model and pays for the rest; the ERP track does not depend on it | none; the phases are unchanged, only their order |
| Repository layout | one git submodule per service, eleven in all | fold the submodules into one repository as directories | a contract change and all its consumers land in one pull request; one CI; one place to read | a day of git history surgery per service if split again later |
| Payout rail | Stripe Connect primary, Wise fallback, Razorpay for India | Razorpay first; Stripe Connect when a non-Indian entity exists | the paying entity is Indian; a global rail needs a non-Indian entity and adds foreign exchange and misclassification exposure | the rail adapter interface is the same; adding Stripe later is one adapter |
| Two new services | nine services | add `hub` and `runner` | the Stage 3 business line needs them; neither touches the Stage 1 loop | not built until Stage 2; nothing to reverse in Stage 1 |
| Where assess runs in Stage 1 | `services/assess` as its own service | the Assessment v2 engine keeps running inside the Odoo image behind its own contract and route until Stage 2 | it already works there; moving it before the loop runs is cost without evidence | the contract is the service boundary from day one; extraction is a deployment change |

---

## 6. What the repository has that this pack deliberately defers

These are not disagreements. Each is in the repository's design and in this pack's later stages; the pack moves them out of the first twelve weeks and says why.

| Repository capability | When this pack builds it | Why not in Stage 1 |
|---|---|---|
| `tracker` (activity samples, screenshots, caps) | only if a client insists on hourly pay, and only behind a non-Indian entity | trackers are the evidence misclassification suits use; per-unit pay does not need one |
| Stripe Connect and Wise | when a non-Indian entity exists | no foreign workers or clients in year one |
| LLM-as-judge, consensus, reviewer hierarchy with percentile promotion, calibration gating, seeded gold | Stage 2 | they need a worker pool and cost history to calibrate against |
| Disputes and appeals | Stage 2 | a dispute reverses an earning as an adjustment line; the ledger must exist first |
| Trust score, tiers | Stage 2, per domain | a score with no history is noise |
| Referral earnings-share | not scheduled | no evidence it is wanted by the first customers |
| AI video interviews, semantic talent search, auto-match | Stage 3 | matching needs a pool to match across |
| `analytics` with Debezium CDC | Stage 3 | Odoo reports and the Performance views cover year one; a stalled replication slot is a risk with no payoff yet |
| Crunchy or Percona Postgres operator | Stage 3 | an operator needs a platform owner; a dedicated Postgres server with PITR covers year one |
| The 200K registered, 20K concurrent load test | kept as the ceiling test | year one runs at 3,000 and 500; the claim-storm harness runs at 1.5x the largest cohort from the first step |
| Client console with live acceptance and quality reports | Stage 2 | in Stage 1 the client gets a manifest, an invoice and a weekly report |
| Mobile app store release with FCM | Stage 2 | web first; the Flutter codebase makes mobile nearly free once the journeys exist |

---

## 7. What the repository already had (credit where it is due)

A reader of this pack could take the following for new ideas. They are not; they are the repository's, and this pack keeps them unchanged.

- The claim serialised with `SELECT ... FOR UPDATE SKIP LOCKED`, the idempotency key on every mutation with a Redis dedup and a Postgres fallback, and retry absorption at the gateway.
- The canonical accept verdict as the single trigger for worker pay and client billing, and the exactly-once rule that reuses the verdict id as the completion event id.
- The weekly pay window, the 7-day first-payout hold, holds before payout rather than clawbacks after, the self-billed vendor bill with TDS, and the nightly reconciliation that alerts and never auto-adjusts.
- The transactional outbox with at-least-once emit and consumer-side dedup, and the rule that no broker client runs inside the Odoo process.
- Hidden gold units, the firewall that keeps seed hashes away from workers, and a first-class dispute workflow.
- The data model: every table, typed column, constraint, index, partition and retention period, for every store.
- The two infrastructure traps: pgBouncer session mode against the queue_job runner, and the Crunchy image licensing with the Percona fork as the exit.
- Worker record rules in Odoo and penetration tests at every phase gate.

---

## 8. The pack itself

Beyond the content, the pack adds material the repository does not try to provide.

| Item | Count | Purpose |
|---|---|---|
| A plain-language guide | 11 sections, a glossary, 12 questions with answers | so a reader who has never seen the repository can follow a leadership discussion |
| Diagrams editable in draw.io | 14 | context, containers, build and release, deployment, the closed loop, four user flows, a sequence, the data model, events, the timeline, the factory; the repository's diagrams are Mermaid text |
| User flows with step tables and edge cases | 6 | worker, reviewer, ops and client, finance, the system view of one task, the factory |
| Tech stack with "what was not chosen" | 4 tables | every technology with its role, why, and the alternative rejected |
| Screen mockups | 13 | one screen per journey, with a walkthrough of what to test on each |
| Self-contained HTML | 1 file for everything, plus one per document | shareable without a repository checkout; light and dark mode |

---

## 9. By the numbers

| | Repository | This pack adds |
|---|---|---|
| Services | 9 | 2 proposed (hub, runner), 2 kept as scaffolds (tracker, analytics) |
| Delivery phases or stages | 6 phases, technical gates | 4 stages, 6 Stage 1 steps, each with a measured gate; Stage 0 commercial and legal work |
| Decisions for leadership | 5 technical | 27 with defaults, 3 open |
| Business measures and kill criteria | 0 | 4 business numbers, 1 north star, 8 measure areas, 6 kill tests |
| Risks | 8 security threats | 21 risks with safeguards, business and people included |
| Alternatives weighed | 1 (event bus) | 23 |
| New fields on the market and quality stores | | `unit_price`, cost fields per unit, `rubric_version`, `reason_code`, margin floor and approval, manifest |
| Proposals that change a repository choice | | 5, each reversible, each marked in the text |
